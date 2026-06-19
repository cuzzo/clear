# frozen_string_literal: true

require "set"
require_relative "local_flow"
require_relative "syntax"

module Decomplex
  # Finds locals that are initialized substantially before their first use
  # while unrelated work happens in between. The smell is not "long variable
  # lifetime" by itself; it is a dormant local inside a non-trivial method,
  # which often means setup happened too early or a phase boundary is trapped
  # inside one scope.
  class LocalityDrag
    DEFAULT_MIN_UNRELATED_STATEMENTS = 4
    DEFAULT_MIN_GAP_LINES = 8
    DEFAULT_MIN_LOCAL_COMPLEXITY = 12.0
    DEFAULT_MIN_SCORE = 60
    DEFAULT_MAX_FINDINGS_PER_METHOD = 3

    SOURCE_LOCATION_LOCAL_PATTERN =
      /(?:\A|_)(?:tok|token|span|source|source_code|line|column|col|pos|idx|index|loc|location)(?:\z|_)/i

    def self.scan(
      files,
      min_unrelated_statements: DEFAULT_MIN_UNRELATED_STATEMENTS,
      min_gap_lines: DEFAULT_MIN_GAP_LINES,
      min_local_complexity: DEFAULT_MIN_LOCAL_COMPLEXITY,
      min_score: DEFAULT_MIN_SCORE,
      max_findings_per_method: DEFAULT_MAX_FINDINGS_PER_METHOD
    )
      summaries = LocalFlow.scan(files)
      complexity_scores = Array(files).each_with_object({}) do |file, scores|
        document = Syntax.parse(file, parser: "tree_sitter")
        scores.merge!(document.local_complexity_scores)
      end
      new(
        summaries,
        complexity_scores: complexity_scores,
        min_unrelated_statements: min_unrelated_statements,
        min_gap_lines: min_gap_lines,
        min_local_complexity: min_local_complexity,
        min_score: min_score,
        max_findings_per_method: max_findings_per_method
      ).findings
    end

    def initialize(
      summaries,
      complexity_scores:,
      min_unrelated_statements:,
      min_gap_lines:,
      min_local_complexity:,
      min_score:,
      max_findings_per_method:
    )
      @summaries = summaries
      @min_unrelated_statements = min_unrelated_statements.to_i
      @min_gap_lines = min_gap_lines.to_i
      @min_local_complexity = min_local_complexity.to_f
      @min_score = min_score.to_i
      @max_findings_per_method = max_findings_per_method.to_i
      @complexity_scores = complexity_scores
    end

    def findings
      @summaries.flat_map { |summary| findings_for(summary) }
                .sort_by do |finding|
                  [-finding[:score], -finding[:unrelated_statements],
                   -finding[:gap_lines], finding[:file], finding[:line]]
                end
    end

    private

    def findings_for(summary)
      return [] if summary.statements.size < @min_unrelated_statements + 2

      local_complexity = @complexity_scores.fetch(summary.id, { score: 0.0 })[:score].to_f
      return [] if local_complexity < @min_local_complexity

      findings = summary.statements.each_with_index.flat_map do |statement, index|
        statement.writes.map do |name|
          finding_for_write(summary, local_complexity, statement, index, name)
        end.compact
      end

      findings.sort_by { |finding| [-finding[:score], finding[:defined_at], finding[:variable]] }
              .first(@max_findings_per_method)
    end

    def finding_for_write(summary, local_complexity, statement, index, name)
      return nil if ignorable_local?(name)

      use_index = first_read_before_rewrite(summary.statements, index, name)
      return nil unless use_index
      return nil if same_prefix_staging_batch?(summary.statements, use_index, name)

      gap = summary.statements[(index + 1)...use_index] || []
      return nil if gap.empty?

      related, unrelated = classify_gap_statements(name, statement, gap)
      substantive_unrelated = unrelated.reject { |stmt| trivial_initializer?(stmt) }
      return nil if substantive_unrelated.size < @min_unrelated_statements

      use_statement = summary.statements[use_index]
      gap_lines = use_statement.line - statement.line
      return nil if gap_lines < @min_gap_lines && boundary_crossings(summary, index, use_index).empty?

      score = score_for(
        variable: name,
        unrelated: substantive_unrelated,
        related: related,
        gap_lines: gap_lines,
        boundaries: boundary_crossings(summary, index, use_index),
        local_complexity: local_complexity,
        read_count: read_count_after_write(summary.statements, index, name)
      )
      return nil if score < @min_score

      at = "#{summary.file}:#{summary.name}:#{statement.line}"
      {
        at: at,
        file: summary.file,
        owner: summary.owner,
        defn: summary.name,
        method: summary.name,
        line: statement.line,
        variable: name,
        defined_at: statement.line,
        used_at: use_statement.line,
        gap_lines: gap_lines,
        gap_statements: gap.size,
        unrelated_statements: substantive_unrelated.size,
        setup_statements: unrelated.size - substantive_unrelated.size,
        related_statements: related.size,
        boundary_crossings: boundary_crossings(summary, index, use_index).size,
        local_complexity: round(local_complexity),
        score: score,
        definition_deps: definition_deps(statement, name).sort,
        use_reads: use_statement.reads.to_a.sort,
        examples: substantive_unrelated.first(3).map { |stmt| example_for(stmt) },
        boundaries: boundary_crossings(summary, index, use_index).map { |boundary| boundary_for(boundary) },
        reason: reason_for(
          name,
          substantive_unrelated,
          gap_lines,
          boundary_crossings(summary, index, use_index),
          local_complexity
        ),
        spans: { at => summary.span },
      }
    end

    def first_read_before_rewrite(statements, index, name)
      statements[(index + 1)..]&.each_with_index do |statement, offset|
        return nil if statement.writes.include?(name)
        return index + 1 + offset if statement.reads.include?(name)
      end
      nil
    end

    def read_count_after_write(statements, index, name)
      statements[(index + 1)..].to_a.count { |statement| statement.reads.include?(name) }
    end

    def classify_gap_statements(name, definition, gap)
      related_names = Set[name]
      related_names.merge(definition_deps(definition, name))

      related = []
      unrelated = []
      gap.each do |statement|
        new_related = derived_from_related(statement, related_names)
        touches_related = !(touched_vars(statement) & related_names).empty?
        if touches_related || !new_related.empty?
          related << statement
          related_names.merge(new_related)
        else
          unrelated << statement
        end
      end

      [related, unrelated]
    end

    def definition_deps(statement, name)
      statement.dependencies.filter_map { |lhs, rhs| rhs if lhs == name }.to_set
    end

    def derived_from_related(statement, related_names)
      statement.dependencies.each_with_object(Set.new) do |(lhs, rhs), out|
        out << lhs if related_names.include?(rhs)
      end
    end

    def touched_vars(statement)
      statement.reads | statement.writes
    end

    def boundary_crossings(summary, definition_index, use_index)
      summary.boundaries.select do |boundary|
        boundary.before_index >= definition_index && boundary.after_index <= use_index
      end
    end

    def score_for(variable:, unrelated:, related:, gap_lines:, boundaries:, local_complexity:, read_count:)
      score = (unrelated.size * 5) +
              [gap_lines, 30].min +
              (boundaries.size * 8) +
              [local_complexity, 25.0].min.round
      score += 5 if read_count == 1
      score -= 8 if benign_local?(variable)
      score -= related.size * 2
      score
    end

    def ignorable_local?(name)
      name.to_s.start_with?("_") || source_location_local?(name)
    end

    def same_prefix_staging_batch?(statements, use_index, name)
      prefix = staging_prefix(name)
      return false unless prefix

      staged_names = statements[0...use_index].flat_map { |statement| statement.writes.to_a }.uniq.select do |candidate|
        candidate.start_with?("#{prefix}_")
      end
      return false if staged_names.size < 4

      use_reads = statements[use_index].reads
      (staged_names & use_reads.to_a).size >= 4
    end

    def trivial_initializer?(statement)
      return false unless statement.writes.any?
      return false unless statement.reads.empty?

      source = statement.source.to_s.strip
      source.match?(/\A\w+\s*=\s*(?:\{\}|\[\]|nil|false|true|0|T\.let\((?:nil|false|true|0)\b)/)
    end

    def staging_prefix(name)
      parts = name.to_s.split("_", 2)
      return nil unless parts.size == 2
      return nil if parts.first.length < 3

      parts.first
    end

    def benign_local?(name)
      source_location_local?(name)
    end

    def source_location_local?(name)
      name.to_s.match?(SOURCE_LOCATION_LOCAL_PATTERN)
    end

    def example_for(statement)
      source = statement.source.to_s.lines.first.to_s.strip
      source = source[0, 96] + "..." if source.length > 99
      { line: statement.line, source: source }
    end

    def boundary_for(boundary)
      marker = boundary.text.to_s.empty? ? boundary.kind.to_s : boundary.text.to_s
      { line: boundary.line, marker: marker }
    end

    def reason_for(variable, unrelated, gap_lines, boundaries, local_complexity)
      parts = [
        "`#{variable}` is initialized #{gap_lines} line(s) before first use",
        "#{unrelated.size} unrelated intervening statement(s)",
      ]
      parts << "#{boundaries.size} structural boundary crossing(s)" if boundaries.any?
      parts << "method local complexity #{round(local_complexity)}"
      parts.join("; ")
    end

    def round(value)
      (value * 10).round / 10.0
    end
  end
end
