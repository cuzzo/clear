# typed: strict
# frozen_string_literal: true

require "digest"
require "set"
require "sorbet-runtime"

require_relative "../ast/lexer"
require_relative "../ast/parser"

module Incremental
  # A stable, source-only description of one root function.  No annotated AST
  # object is retained: reparsing a revision can never accidentally reuse
  # mutable semantic stamps from the preceding revision.
  class FunctionItem < T::Struct
    const :key, String
    const :name, String
    const :start_offset, Integer
    const :end_offset, Integer
    const :start_line, Integer
    const :end_line, Integer
    const :exact_fingerprint, String
    const :interface_fingerprint, String
    const :called_functions, T::Set[String], factory: -> { Set.new }
  end

  class SourceCatalog
    extend T::Sig

    sig { returns(String) }
    attr_reader :source, :module_path, :non_function_fingerprint

    sig { returns(T::Array[FunctionItem]) }
    attr_reader :functions

    sig { returns(T::Set[String]) }
    attr_reader :non_function_calls

    sig do
      params(
        source: String,
        module_path: String,
        functions: T::Array[FunctionItem],
        non_function_fingerprint: String,
        non_function_calls: T::Set[String],
      ).void
    end
    def initialize(source:, module_path:, functions:, non_function_fingerprint:, non_function_calls:)
      @source = source
      @module_path = module_path
      @functions = T.let(functions.freeze, T::Array[FunctionItem])
      @non_function_fingerprint = non_function_fingerprint
      @non_function_calls = T.let(non_function_calls.freeze, T::Set[String])
    end

    sig { params(source: String, module_path: String).returns(SourceCatalog) }
    def self.build(source, module_path:)
      budget = FrontendResourceBudget.new
      tokens = Lexer.new(source, file: module_path, budget: budget).tokenize
      program = ClearParser.new(tokens, source, budget: budget).parse
      function_nodes = program.statements.grep(AST::FunctionDef)
      names = function_nodes.map(&:name).to_set

      functions = function_nodes.map do |node|
        range = node.source_range
        exact_source = source.byteslice(range.start_offset...range.end_offset) || ""
        first_body_offset = node.body.filter_map do |stmt|
          stmt.source_range.start_offset if stmt.respond_to?(:source_range)
        end.min
        interface_end = first_body_offset || range.end_offset
        interface_source = source.byteslice(range.start_offset...interface_end) || ""
        calls = T.let(Set.new, T::Set[String])
        AST.each_locatable(node.body, descend_functions: false) do |child|
          next unless child.is_a?(AST::FuncCall)
          calls.add(child.name.to_s) if names.include?(child.name.to_s)
        end

        FunctionItem.new(
          key: stable_key(module_path, node.name),
          name: node.name,
          start_offset: range.start_offset,
          end_offset: range.end_offset,
          start_line: range.start_line,
          end_line: range.end_line,
          exact_fingerprint: digest(exact_source),
          interface_fingerprint: token_fingerprint(interface_source),
          called_functions: calls,
        )
      end

      non_function_calls = T.let(Set.new, T::Set[String])
      (program.statements - function_nodes).each do |statement|
        AST.each_locatable(statement, descend_functions: true) do |child|
          next unless child.is_a?(AST::FuncCall)
          non_function_calls.add(child.name.to_s) if names.include?(child.name.to_s)
        end
      end

      new(
        source: source,
        module_path: module_path,
        functions: functions,
        non_function_fingerprint: digest(without_functions(source, functions)),
        non_function_calls: non_function_calls,
      )
    end

    sig { params(name: String).returns(T.nilable(FunctionItem)) }
    def fetch(name)
      @functions.find { |item| item.name == name }
    end

    sig { returns(T::Hash[String, FunctionItem]) }
    def by_name
      @functions.to_h { |item| [item.name, item] }
    end

    sig { params(changed_name: String).returns(String) }
    def isolated_source(changed_name)
      isolated_source_for(dependency_closure(changed_name))
    end

    sig { params(names: T::Set[String]).returns(String) }
    def isolated_source_for(names)
      mask = @functions.reject { |item| names.include?(item.name) }
      self.class.mask_functions(@source, mask)
    end

    sig { params(name: String).returns(T::Set[String]) }
    def dependency_closure(name)
      pending = T.let([name], T::Array[String])
      found = T.let(Set.new, T::Set[String])
      until pending.empty?
        current = T.must(pending.pop)
        next unless found.add?(current)

        item = fetch(current)
        pending.concat(item.called_functions.to_a) if item
      end
      found
    end

    sig { params(name: String).returns(T::Boolean) }
    def called_by_user_function?(name)
      @non_function_calls.include?(name) || @functions.any? do |item|
        item.name != name && item.called_functions.include?(name)
      end
    end

    class << self
      extend T::Sig

      # Replace bytes, not characters, so lexer byte offsets remain valid even
      # when a removed function contains UTF-8.  Newlines are retained to keep
      # all source-line comments and diagnostics stable.
      sig { params(source: String, functions: T::Array[FunctionItem]).returns(String) }
      def mask_functions(source, functions)
        bytes = source.b.bytes
        functions.each do |item|
          (item.start_offset...item.end_offset).each do |offset|
            byte = bytes[offset]
            bytes[offset] = 0x20 unless byte == 0x0A || byte == 0x0D
          end
        end
        bytes.pack("C*").force_encoding(source.encoding)
      end

      private

      sig { params(source: String, functions: T::Array[FunctionItem]).returns(String) }
      def without_functions(source, functions)
        cursor = 0
        pieces = T.let([], T::Array[String])
        functions.sort_by(&:start_offset).each do |item|
          pieces << (source.byteslice(cursor...item.start_offset) || "")
          cursor = item.end_offset
        end
        pieces << (source.byteslice(cursor..-1) || "")
        pieces.join
      end

      sig { params(module_path: String, name: String).returns(String) }
      def stable_key(module_path, name)
        digest("#{File.expand_path(module_path)}\0function\0#{name}")
      end

      sig { params(value: String).returns(String) }
      def digest(value)
        Digest::SHA256.hexdigest(value)
      end

      sig { params(source: String).returns(String) }
      def token_fingerprint(source)
        payload = Lexer.new(source).tokenize.reject { |token| token.type == :EOF }.map do |token|
          "#{token.type}\0#{token.value.class.name}\0#{token.value}"
        end.join("\0")
        digest(payload)
      end
    end
  end
end
