# frozen_string_literal: true

require "set"
require_relative "local_flow"

module Decomplex
  # Function-level cohesion metric. It adapts LCOM to one method by building
  # a conservative local-variable interaction graph and ranking methods with
  # multiple independent data-flow components.
  class FunctionLCOM
    DEFAULT_MIN_COMPONENTS = 2
    DEFAULT_MIN_LOCALS = 5
    DEFAULT_MIN_STATEMENTS = 5
    DEFAULT_MIN_SCORE = 40

    Component = Struct.new(:vars, :statements, keyword_init: true)

    def self.scan(
      files,
      min_components: DEFAULT_MIN_COMPONENTS,
      min_locals: DEFAULT_MIN_LOCALS,
      min_statements: DEFAULT_MIN_STATEMENTS,
      min_score: DEFAULT_MIN_SCORE
    )
      new(
        LocalFlow.scan(files),
        min_components: min_components,
        min_locals: min_locals,
        min_statements: min_statements,
        min_score: min_score
      ).findings
    end

    def initialize(summaries, min_components:, min_locals:, min_statements:, min_score:)
      @summaries = summaries
      @min_components = min_components.to_i
      @min_locals = min_locals.to_i
      @min_statements = min_statements.to_i
      @min_score = min_score.to_i
    end

    def findings
      @summaries.filter_map { |summary| finding_for(summary) }
                .sort_by { |finding| [-finding[:score], finding[:file], finding[:line]] }
    end

    private

    def finding_for(summary)
      return nil if summary.statements.size < @min_statements

      full_components = substantial_components(components(summary.statements), summary.statements)
      pre_components = substantial_components(components(pre_terminal_statements(summary)), pre_terminal_statements(summary))
      local_count = local_names(summary.statements).size
      return nil if local_count < @min_locals

      terminal_join = terminal_join?(summary, pre_components)
      report_components = full_components
      mode = :disjoint
      if full_components.size < @min_components && terminal_join && pre_components.size >= @min_components
        report_components = pre_components
        mode = :late_join
      end
      return nil if report_components.size < @min_components

      score = score_for(report_components, local_count, summary.statements.size, terminal_join)
      return nil if score < @min_score

      {
        file: summary.file,
        defn: summary.name,
        owner: summary.owner,
        method: summary.name,
        line: summary.line,
        at: "#{summary.file}:#{summary.name}:#{summary.line}",
        score: score,
        mode: mode,
        components: report_components.size,
        locals: local_count,
        statements: summary.statements.size,
        terminal_join: terminal_join,
        component_vars: report_components.map { |component| component.vars.sort },
        component_lines: report_components.map { |component| component.statements.map(&:line).uniq.sort },
        spans: { "#{summary.file}:#{summary.name}:#{summary.line}" => summary.span },
      }
    end

    def pre_terminal_statements(summary)
      return [] if summary.statements.size <= 1

      summary.statements[0...-1]
    end

    def terminal_join?(summary, pre_components)
      terminal = summary.statements.last
      return false unless terminal

      component_index = {}
      pre_components.each_with_index do |component, index|
        component.vars.each { |name| component_index[name] = index }
      end
      terminal_vars = touched_vars(terminal)
      terminal_vars.map { |name| component_index[name] }.compact.uniq.size >= @min_components
    end

    def score_for(components, local_count, statement_count, terminal_join)
      (components.size * 10) + local_count + statement_count + (terminal_join ? 5 : 0)
    end

    def substantial_components(raw_components, statements)
      raw_components.filter_map do |vars|
        touched = statements.select { |statement| (touched_vars(statement) & vars).any? }
        next if vars.size < 2 || touched.size < 2

        Component.new(vars: vars.to_a.sort.to_set, statements: touched)
      end
    end

    def components(statements)
      vars = local_names(statements)
      edges = graph_edges(statements)
      adjacency = vars.to_h { |name| [name, Set.new] }
      edges.each do |left, right|
        next if left == right

        adjacency[left] << right
        adjacency[right] << left
      end

      visited = Set.new
      vars.filter_map do |name|
        next if visited.include?(name)

        component = Set.new
        stack = [name]
        until stack.empty?
          current = stack.pop
          next if visited.include?(current)

          visited << current
          component << current
          adjacency[current].each { |neighbor| stack << neighbor unless visited.include?(neighbor) }
        end
        component
      end
    end

    def graph_edges(statements)
      statements.flat_map do |statement|
        statement.dependencies + statement.co_uses
      end
    end

    def local_names(statements)
      statements.each_with_object(Set.new) do |statement, names|
        names.merge(touched_vars(statement))
      end
    end

    def touched_vars(statement)
      statement.reads | statement.writes
    end
  end
end
