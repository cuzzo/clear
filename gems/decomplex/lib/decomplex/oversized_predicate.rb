# frozen_string_literal: true

require_relative "ast"

module Decomplex
  # Flags boolean predicates with too many independent condition atoms.
  #
  # The intent is not "shorter code"; it is to surface places where a
  # long inline predicate probably wants an existing domain helper or a
  # newly named predicate. Nested parentheses still count because Ruby's
  # AST preserves the same AND/OR tree either way.
  class OversizedPredicate
    LIMIT = 3
    PREDICATE_NODES = %i[IF WHILE UNTIL].freeze

    def self.scan(files, limit: LIMIT)
      findings = []
      files.each do |file|
        root, lines = Ast.parse(file)
        new(file, lines, limit).tap do |scanner|
          scanner.walk(root, [])
          findings.concat(scanner.findings)
        end
      end
      Result.new(findings)
    end

    Result = Struct.new(:findings)

    attr_reader :findings

    def initialize(file, lines, limit)
      @file = file
      @lines = lines
      @limit = limit
      @findings = []
    end

    def walk(node, defstack)
      return unless Ast.node?(node)

      defstack = Ast.def_push(node, defstack)
      record_predicate(node, defstack)
      node.children.each { |child| walk(child, defstack) }
    end

    private

    def record_predicate(node, defstack)
      return unless PREDICATE_NODES.include?(node.type)
      return if predicate_helper?(defstack.last)

      cond = node.children[0]
      return unless Ast.node?(cond)

      atoms = condition_atoms(cond)
      return unless atoms.size > @limit

      defn = defstack.last || "<top>"
      at = "#{@file}:#{defn}:#{node.first_lineno}"
      @findings << {
        at: at,
        count: atoms.size,
        predicate: Ast.slice(cond, @lines),
        atoms: atoms.map { |atom| Ast.slice(atom, @lines) },
        spans: { at => [node.first_lineno, node.first_column, node.last_lineno, node.last_column] },
      }
    end

    def condition_atoms(node)
      return [] unless Ast.node?(node)

      case node.type
      when :AND, :OR
        node.children.flat_map { |child| condition_atoms(child) }
      when :NOT
        condition_atoms(node.children[0])
      else
        [node]
      end
    end

    def predicate_helper?(name)
      name.to_s.end_with?("?")
    end
  end
end
