# frozen_string_literal: true

require_relative "local_flow"

module Decomplex
  # Derived-state def-use staleness (intra-procedural, the design
  # boundary's "single-method reaching-defs", no whole-program flow).
  #
  # Plague: redundant state that drifts. `b = f(a)` makes b a derived
  # copy of a. If a is then reassigned later in the same method but b
  # is NOT recomputed, every later use of b is stale.
  class DerivedState
    Asgn = Struct.new(:name, :deps, :line, :span, :statement_index, keyword_init: true)

    def self.scan(files)
      LocalFlow.scan(files).flat_map do |method|
        analyze(method.file, method.name, assignments(method))
      end.sort_by { |h| -h[:gap] }
    end

    def self.assignments(method)
      method.statements.flat_map do |statement|
        statement.writes.map do |name|
          Asgn.new(
            name: name,
            deps: dependencies_for(statement, name),
            line: statement.line,
            span: statement.span,
            statement_index: statement.index
          )
        end
      end
    end

    def self.dependencies_for(statement, name)
      statement.dependencies.filter_map do |left, right|
        right.to_s if left.to_s == name.to_s
      end.uniq
    end

    def self.analyze(file, defn, asgns)
      out = []
      asgns.each_with_index do |b, i|
        next if b.deps.empty?

        b.deps.each do |a|
          next if a == b.name

          reasn = asgns[(i + 1)..].find do |x|
            x.name == a && x.statement_index > b.statement_index
          end
          next unless reasn

          recomputed = asgns[(i + 1)..].any? do |x|
            x.name == b.name && x.statement_index >= reasn.statement_index
          end
          next if recomputed

          out << {
            file: file, defn: defn,
            derived: b.name, source: a,
            derived_at: b.line, source_reassigned_at: reasn.line,
            gap: reasn.line - b.line,
            at: "#{file}:#{defn}:#{b.line}",
            spans: { "#{file}:#{defn}:#{b.line}" => b.span }
          }
        end
      end
      out
    end
  end
end
