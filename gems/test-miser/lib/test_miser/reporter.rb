# frozen_string_literal: true

require "json"

module TestMiser
  class Reporter
    MUTANT_SAMPLE_LIMIT = 10

    def initialize(analysis)
      @analysis = analysis
    end

    def json
      JSON.pretty_generate(@analysis.to_h)
    end

    def markdown
      summary = @analysis.to_h.fetch(:summary)
      lines = [
        "# Test Miser Report",
        "",
        "Mutation findings are audit candidates, not proof that a test is redundant.",
        "",
        corpus_notice,
        "## Summary",
        "",
        "- Tests: #{summary.fetch(:tests)}",
        "- Mutants: #{summary.fetch(:mutants)}",
        "- Tests that kill no mutants: #{summary.fetch(:tests_that_kill_no_mutants)}",
        "- Possibly redundant groups: #{summary.fetch(:possibly_redundant_groups)}",
        "- Tests in possibly redundant groups: #{summary.fetch(:tests_in_possibly_redundant_groups)}",
        "",
        zero_kill_section,
        "",
        redundant_section
      ]
      lines.join("\n")
    end

    private

    def corpus_notice
      return "" unless @analysis.corpus_complete == false

      "This report is an incomplete Test Miser corpus. Audit findings are withheld.\n"
    end

    def zero_kill_section
      lines = ["## Tests That Kill No Mutants", ""]
      if @analysis.zero_kill_tests.empty?
        lines << "None."
        return lines.join("\n")
      end

      lines << "| test | covered mutants | evaluation |"
      lines << "|---|---:|---|"
      @analysis.zero_kill_tests.each do |result|
        evaluation = result.covered_mutants.empty? ? "not mutation-covered" : "covered but killed none"
        lines << "| `#{escape(result.test.name)}` | #{result.covered_mutants.length} | #{evaluation} |"
      end
      lines.join("\n")
    end

    def redundant_section
      lines = ["## POSSIBLY REDUNDANT Test Groups", ""]
      if @analysis.redundant_groups.empty?
        lines << "None."
        return lines.join("\n")
      end

      @analysis.redundant_groups.each_with_index do |group, index|
        lines << "### Group #{index + 1}: #{group.tests.length} tests, #{group.killed_mutants.length} identical kills"
        lines << ""
        group.tests.each { |test| lines << "- `#{escape(test.name)}`" }
        lines << ""
        sorted_mutants = group.killed_mutants.to_a.sort
        sample = sorted_mutants.first(MUTANT_SAMPLE_LIMIT).map { |id| "`#{escape(id)}`" }.join(", ")
        omitted = sorted_mutants.length - MUTANT_SAMPLE_LIMIT
        suffix = omitted.positive? ? " (and #{omitted} more; see the JSON report)" : ""
        lines << "Killed mutant sample: #{sample}#{suffix}"
        lines << ""
      end
      lines.join("\n").rstrip
    end

    def escape(value)
      value.to_s.gsub("`", "\\`").gsub("|", "\\|")
    end
  end
end
