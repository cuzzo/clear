# frozen_string_literal: true

require "set"
require_relative "ast"

module Decomplex
  # Conservative intra-procedural local data-flow support for function-level
  # design metrics. It models top-level method statements, local reads/writes,
  # simple def-use edges, variable live ranges, and blank/comment boundaries.
  class LocalFlow
    MethodSummary = Struct.new(
      :id, :owner, :name, :file, :line, :span, :node, :statements, :boundaries, keyword_init: true
    )
    Statement = Struct.new(
      :index, :line, :end_line, :span, :source, :reads, :writes, :dependencies, :co_uses,
      keyword_init: true
    )
    Boundary = Struct.new(
      :before_index, :after_index, :line, :kind, :text, keyword_init: true
    )

    OWNER_TYPES = %i[CLASS MODULE].freeze
    METHOD_TYPES = %i[DEFN DEFS].freeze
    SKIP_NESTED_TYPES = %i[CLASS MODULE DEFN DEFS LAMBDA].freeze
    LOCAL_READ_TYPES = %i[LVAR DVAR].freeze
    LOCAL_WRITE_TYPES = %i[LASGN DASGN].freeze

    def self.scan(files)
      files.flat_map do |file|
        root, lines = Ast.parse(file)
        new(file, lines).scan(root)
      end
    end

    def initialize(file, lines)
      @file = file
      @lines = lines
    end

    def scan(root)
      out = []
      collect_methods(root, [], out)
      out
    end

    private

    def collect_methods(node, owners, out)
      return unless Ast.node?(node)

      if OWNER_TYPES.include?(node.type)
        owner = full_owner_name(owners, node)
        owner_methods(node).each { |method| out << method_summary(method, owner) }
        collect_nested_owners(node, owners + [owner_segment(node)], out)
      elsif METHOD_TYPES.include?(node.type) && owners.empty?
        out << method_summary(node, "(top-level)")
      else
        node.children.each { |child| collect_methods(child, owners, out) }
      end
    end

    def collect_nested_owners(node, owners, out)
      return unless Ast.node?(node)
      return if METHOD_TYPES.include?(node.type)

      node.children.each do |child|
        next unless Ast.node?(child)

        if OWNER_TYPES.include?(child.type)
          collect_methods(child, owners, out)
        else
          collect_nested_owners(child, owners, out)
        end
      end
    end

    def method_summary(node, owner)
      statements = Ast.body_stmts(node).each_with_index.map do |stmt, index|
        statement_summary(stmt, index)
      end
      MethodSummary.new(
        id: "#{owner}##{method_name(node)}",
        owner: owner,
        name: method_name(node),
        file: @file,
        line: node.first_lineno,
        span: [node.first_lineno, node.first_column, node.last_lineno, node.last_column],
        node: node,
        statements: statements,
        boundaries: structural_boundaries(statements)
      )
    end

    def statement_summary(node, index)
      Statement.new(
        index: index,
        line: node.first_lineno,
        end_line: node.last_lineno,
        span: [node.first_lineno, node.first_column, node.last_lineno, node.last_column],
        source: Ast.slice(node, @lines),
        reads: local_reads(node).to_set,
        writes: local_writes(node).to_set,
        dependencies: assignment_dependencies(node),
        co_uses: co_use_edges(node)
      )
    end

    def structural_boundaries(statements)
      statements.each_cons(2).filter_map do |left, right|
        boundary = source_boundary(left.end_line + 1, right.line - 1)
        next unless boundary

        Boundary.new(
          before_index: left.index,
          after_index: right.index,
          line: boundary[:line],
          kind: boundary[:kind],
          text: boundary[:text]
        )
      end
    end

    def source_boundary(first_line, last_line)
      return nil if first_line > last_line

      blank = nil
      (first_line..last_line).each do |line_number|
        text = @lines[line_number - 1].to_s
        stripped = text.strip
        if stripped.start_with?("#")
          return {
            line: line_number,
            kind: :comment,
            text: stripped,
          }
        end
        blank ||= { line: line_number, kind: :blank, text: stripped } if stripped.empty?
      end
      blank
    end

    def owner_methods(owner_node)
      body = owner_body(owner_node)
      return [] unless Ast.node?(body)

      owner_statements(body).flat_map do |stmt|
        next [] unless Ast.node?(stmt)

        if METHOD_TYPES.include?(stmt.type)
          [stmt]
        elsif visibility_call?(stmt)
          inline_methods(stmt)
        else
          []
        end
      end
    end

    def inline_methods(stmt)
      args = stmt.children[1]
      return [] unless Ast.node?(args)

      args.children.compact.select { |arg| Ast.node?(arg) && METHOD_TYPES.include?(arg.type) }
    end

    def owner_body(owner_node)
      scope = owner_node.children[owner_node.type == :CLASS ? 2 : 1]
      return nil unless Ast.node?(scope) && scope.type == :SCOPE

      scope.children[2]
    end

    def owner_statements(body)
      body.type == :BLOCK ? body.children.compact : [body]
    end

    def visibility_call?(node)
      node.type == :FCALL && %i[public protected private].include?(node.children[0])
    end

    def method_name(node)
      if node.type == :DEFS
        receiver = node.children[0]
        prefix = Ast.node?(receiver) && receiver.type == :SELF ? "self" : Ast.slice(receiver, @lines)
        "#{prefix}.#{node.children[1]}"
      else
        node.children[0].to_s
      end
    end

    def full_owner_name(owners, node)
      (owners + [owner_segment(node)]).join("::")
    end

    def owner_segment(node)
      text = Ast.slice(node.children[0], @lines)
      text.empty? ? "(anonymous)" : text
    end

    def local_reads(node)
      reads = []
      walk_local(node) do |child|
        reads << child.children[0].to_s if LOCAL_READ_TYPES.include?(child.type)
      end
      reads
    end

    def local_writes(node)
      writes = []
      walk_local(node) do |child|
        writes << child.children[0].to_s if LOCAL_WRITE_TYPES.include?(child.type)
      end
      writes
    end

    def assignment_dependencies(node)
      deps = []
      walk_local(node) do |child|
        next unless LOCAL_WRITE_TYPES.include?(child.type)

        lhs = child.children[0].to_s
        rhs = child.children[1]
        local_reads(rhs).uniq.each { |read| deps << [lhs, read] unless lhs == read }
      end
      deps.uniq
    end

    def co_use_edges(node)
      local_reads(node).uniq.combination(2).map { |left, right| [left, right] }
    end

    def walk_local(node, &block)
      return unless Ast.node?(node)
      return if SKIP_NESTED_TYPES.include?(node.type)

      yield node
      node.children.each { |child| walk_local(child, &block) }
    end
  end
end
