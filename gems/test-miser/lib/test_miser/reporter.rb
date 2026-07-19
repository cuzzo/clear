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

    def sarif
      JSON.pretty_generate(
        "$schema" => "https://json.schemastore.org/sarif-2.1.0.json",
        "version" => "2.1.0",
        "runs" => [{
          "tool" => { "driver" => sarif_driver },
          "properties" => { "format" => "test-miser.report.sarif.v1" },
          "results" => sarif_results
        }]
      )
    end

    private

    def sarif_driver
      {
        "name" => "Test Miser",
        "semanticVersion" => TestMiser::VERSION,
        "informationUri" => "https://github.com/cuzzo/clear/tree/master/gems/test-miser",
        "rules" => [
          sarif_rule("test-miser.zero-kill", "Test kills no mutants"),
          sarif_rule("test-miser.possibly-redundant", "Tests have identical mutant kill sets")
        ]
      }
    end

    def sarif_rule(id, text)
      { "id" => id, "shortDescription" => { "text" => text }, "defaultConfiguration" => { "level" => "warning" } }
    end

    def sarif_results
      return [] if @analysis.corpus_complete == false

      zero = @analysis.zero_kill_tests.filter_map do |result|
        sarif_result(
          result.test,
          "test-miser.zero-kill",
          "#{result.test.name} kills no mutants",
          "zero-kill",
          "coveredMutantCount" => result.covered_mutants.length,
          "killedMutantCount" => 0
        )
      end
      redundant = @analysis.redundant_groups.each_with_index.flat_map do |group, index|
        group.tests.filter_map do |test|
          sarif_result(
            test,
            "test-miser.possibly-redundant",
            "#{test.name} is POSSIBLY REDUNDANT with #{group.tests.length - 1} other test(s)",
            "possibly-redundant",
            "groupId" => "group-#{index + 1}",
            "groupSize" => group.tests.length,
            "killedMutantCount" => group.killed_mutants.length,
            "peerTests" => group.tests.reject { |peer| peer.id == test.id }.map(&:name)
          )
        end
      end
      zero + redundant
    end

    def sarif_result(test, rule_id, message, kind, details)
      return nil unless test.file

      properties = {
        "category" => "weak-test",
        "kind" => kind,
        "testId" => test.id,
        "testName" => test.name,
        "testFile" => test.file,
        "testLine" => test.line
      }.merge(details).compact
      {
        "ruleId" => rule_id,
        "level" => "warning",
        "message" => { "text" => message },
        "locations" => [{
          "physicalLocation" => {
            "artifactLocation" => { "uri" => test.file },
            "region" => { "startLine" => test.line || 1 }
          }
        }],
        "partialFingerprints" => { "testMiser/v1" => "#{rule_id}:#{test.id}" },
        "properties" => properties
      }
    end

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
