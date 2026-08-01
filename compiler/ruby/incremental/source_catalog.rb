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
          # Retained identity v4: keep-analysis infers a param's handle ABI
          # from body shapes (struct-literal stores and call-argument
          # positions of param identifiers), so those shapes are interface,
          # not implementation - a body-only edit that changes them must
          # invalidate callers.
          interface_fingerprint: token_fingerprint(
            interface_source + retention_shape_source(node)
          ),
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
        non_function_fingerprint: digest(non_function_tokens(tokens, functions)),
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
        # Compiler sources are UTF-8. CLEAR strings do not carry a mutable
        # encoding tag, so keep the Ruby host result aligned with that
        # contract instead of deriving a dynamic encoding from the input.
        bytes.pack("C*").force_encoding(Encoding::UTF_8)
      end

      private

      # Fingerprint the TOKENS outside function bodies, not the raw bytes.
      # Digesting the source made a comment or a reflowed line read as a
      # semantic change, which dropped the whole file off the incremental fast
      # path -- the common edit during development. The lexer has already run
      # by this point, so the token stream costs nothing extra, and it carries
      # exactly what the compiler acts on.
      sig { params(tokens: T::Array[Lexer::Token], functions: T::Array[FunctionItem]).returns(String) }
      def non_function_tokens(tokens, functions)
        ranges = functions.map { |item| [item.start_offset, item.end_offset] }
        parts = T.let([], T::Array[String])
        tokens.each do |token|
          offset = token.start_offset
          next if offset && ranges.any? { |from, to| offset >= from && offset < to }

          parts << "#{token.type}\u0000#{token.value}"
        end
        parts.join("\u0001")
      end

      sig { params(module_path: String, name: String).returns(String) }
      def stable_key(module_path, name)
        digest("#{File.expand_path(module_path)}\0function\0#{name}")
      end

      sig { params(value: String).returns(String) }
      def digest(value)
        Digest::SHA256.hexdigest(value)
      end

      # Retained identity v4: the body shapes keep-analysis reads participate
      # in the interface fingerprint - see the FunctionItem construction
      # above. Each arm mirrors its semantic deriver EXACTLY (same unwraps,
      # same bare-identifier requirement); a looser capture here would let a
      # body edit flip the derived ABI without changing the fingerprint:
      # - struct-literal fields and field assignments feed
      #   Lifetimes#keep_param_identity!, which unwraps OR_ELSE (keeping the
      #   provided identity) but treats COPY/GIVE wrappers as not-kept;
      # - call args feed KeepAnalysis transitive propagation, which fires on
      #   bare identifiers only.
      sig { params(node: AST::FunctionDef).returns(String) }
      def retention_shape_source(node)
        param_names = node.params.map { |p| p.name.to_s }.to_set
        shape = T.let([], T::Array[String])
        AST.each_locatable(node.body, descend_functions: false) do |child|
          case child
          when AST::StructLit
            child.fields.each do |field_name, value|
              inner = unwrap_keep_value(value)
              next unless inner.is_a?(AST::Identifier) && param_names.include?(inner.name)
              shape << "#{child.name}.#{field_name}<-#{inner.name}"
            end
          when AST::Assignment
            target = child.name
            next unless target.is_a?(AST::GetField)
            inner = unwrap_keep_value(child.value)
            next unless inner.is_a?(AST::Identifier) && param_names.include?(inner.name)
            shape << "#{target.field}=<-#{inner.name}"
          when AST::FuncCall
            child.args.each_with_index do |arg, idx|
              next unless arg.is_a?(AST::Identifier) && param_names.include?(arg.name)
              shape << "#{child.name}(#{idx})<-#{arg.name}"
            end
          end
        end
        shape.sort.join(";")
      end

      sig { params(value: AST::Node).returns(AST::Node) }
      def unwrap_keep_value(value)
        return unwrap_keep_value(value.left) if value.is_a?(AST::BinaryOp) && value.op == :OR_ELSE

        value
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
