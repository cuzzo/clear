# frozen_string_literal: true

require "set"
require_relative "syntax"

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

    def self.scan(files)
      files.flat_map do |file|
        Syntax.parse(file, parser: "tree_sitter").local_methods.map do |method|
          method_summary(method)
        end
      end
    end

    private_class_method def self.method_summary(method)
      MethodSummary.new(
        id: method.id,
        owner: method.owner,
        name: method.name,
        file: method.file,
        line: method.line,
        span: method.span,
        node: method.node,
        statements: method.statements.map { |statement| statement_summary(statement) },
        boundaries: method.boundaries.map { |boundary| boundary_summary(boundary) }
      )
    end

    private_class_method def self.statement_summary(statement)
      Statement.new(
        index: statement.index,
        line: statement.line,
        end_line: statement.end_line,
        span: statement.span,
        source: statement.source,
        reads: statement.reads.to_set,
        writes: statement.writes.to_set,
        dependencies: statement.dependencies,
        co_uses: statement.co_uses
      )
    end

    private_class_method def self.boundary_summary(boundary)
      Boundary.new(
        before_index: boundary.before_index,
        after_index: boundary.after_index,
        line: boundary.line,
        kind: boundary.kind,
        text: boundary.text
      )
    end
  end
end
