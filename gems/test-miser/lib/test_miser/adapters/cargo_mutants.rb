# frozen_string_literal: true

require "find"
require "json"

module TestMiser
  module Adapters
    class CargoMutants
      TEST_RESULT = /^test (?<name>.+) \.\.\. (?<status>ok|FAILED|ignored)$/

      def initialize(output_dir:, root: Dir.pwd, path_prefix: nil, selected_components: [])
        @output_dir = File.expand_path(output_dir)
        @root = File.expand_path(root)
        @path_prefix = path_prefix&.sub(%r{/+\z}, "")
        @selected_components = selected_components
      end

      def call
        payload = JSON.parse(File.read(File.join(@output_dir, "outcomes.json")))
        outcomes = payload.fetch("outcomes")
        baseline = outcomes.find { |outcome| outcome["scenario"] == "Baseline" }
        raise InvalidReport, "cargo-mutants output has no successful baseline" unless baseline && baseline["summary"] == "Success"

        test_names = test_results(baseline).keys.sort
        locations = locate_tests(test_names)
        mutant_outcomes = outcomes.reject { |outcome| outcome["scenario"] == "Baseline" }
        complete = mutant_outcomes.all? { |outcome| outcome.dig("scenario", "Mutant") }
        run_to_complete = mutant_outcomes.all? { |outcome| no_fail_fast?(outcome) }
        attribution_complete = complete && run_to_complete &&
          mutant_outcomes.none? { |outcome| outcome["summary"] == "Timeout" } &&
          mutant_outcomes.none? { |outcome| unattributed_kill?(outcome) }

        {
          "schema" => "mutant-facts/v1",
          "source" => "cargo-mutants",
          "language" => "rust",
          "mutation_kind" => "stochastic",
          "subjects" => subjects(mutant_outcomes),
          "tests" => test_names.map do |name|
            location = locations[name] || {}
            {
              "id" => test_id(name), "name" => name,
              "file" => prefixed(location[:file]), "line" => location[:line]
            }.compact
          end,
          "mutants" => mutant_outcomes.map { |outcome| mutant(outcome) },
          "test_miser" => {
            "complete" => complete,
            "attribution_complete" => attribution_complete,
            "run_to_complete" => run_to_complete,
            "selected_components" => @selected_components
          }
        }
      rescue JSON::ParserError => error
        raise InvalidReport, "invalid cargo-mutants outcomes.json: #{error.message}"
      end

      private

      def mutant(outcome)
        details = outcome.fetch("scenario").fetch("Mutant")
        failures = test_results(outcome).select { |_name, status| status == "FAILED" }.keys
        {
          "id" => details.fetch("name"),
          "file" => prefixed(details.fetch("file")),
          "method" => details.dig("function", "function_name"),
          "kind" => details["genre"],
          "outcome" => normalize_outcome(outcome.fetch("summary")),
          "line" => details.dig("span", "start", "line"),
          "column" => details.dig("span", "start", "column"),
          "covered_by" => [],
          "killed_by" => failures.sort.map { |name| test_id(name) }
        }.compact
      end

      def subjects(outcomes)
        outcomes.group_by do |outcome|
          details = outcome.dig("scenario", "Mutant") || {}
          [details["file"], details.dig("function", "function_name")]
        end.filter_map do |(file, method), rows|
          next unless file && method

          killed = rows.count { |row| row["summary"] == "CaughtMutant" }
          {
            "file" => prefixed(file),
            "method" => method,
            "mutations" => rows.length,
            "killed" => killed,
            "alive" => rows.count { |row| row["summary"] == "MissedMutant" },
            "kill_rate" => rows.empty? ? 100.0 : (killed.fdiv(rows.length) * 100.0).round(2),
            "mutation_kind" => "stochastic",
            "gate_status" => "advisory"
          }
        end
      end

      def test_results(outcome)
        log_path = outcome["log_path"]
        return {} unless log_path

        File.readlines(File.join(@output_dir, log_path), chomp: true).each_with_object({}) do |line, results|
          match = TEST_RESULT.match(line)
          results[match[:name]] = match[:status] if match
        end
      end

      def no_fail_fast?(outcome)
        outcome.fetch("phase_results", []).select { |phase| phase["phase"] == "Test" }.all? do |phase|
          phase.fetch("argv", []).include?("--no-fail-fast")
        end
      end

      def unattributed_kill?(outcome)
        outcome["summary"] == "CaughtMutant" &&
          test_results(outcome).none? { |_name, status| status == "FAILED" }
      end

      def locate_tests(names)
        wanted = names.to_h { |name| [name.split("::").last, name] }
        locations = {}
        Find.find(@root) do |path|
          if File.directory?(path)
            Find.prune if %w[.git target].include?(File.basename(path))
            next
          end
          next unless path.end_with?(".rs")

          File.foreach(path).with_index(1) do |line, line_number|
            wanted.each do |leaf, full_name|
              next unless line.match?(/\bfn\s+#{Regexp.escape(leaf)}\b/)

              locations[full_name] ||= { file: path.delete_prefix("#{@root}/"), line: line_number }
            end
          end
        end
        locations
      end

      def test_id(name)
        "rust:#{name}"
      end

      def prefixed(path)
        return path unless path && @path_prefix

        "#{@path_prefix}/#{path.sub(%r{\A\./}, '')}"
      end

      def normalize_outcome(summary)
        {
          "CaughtMutant" => "killed",
          "MissedMutant" => "survived",
          "Timeout" => "timeout",
          "Unviable" => "unviable"
        }.fetch(summary, summary.to_s.downcase)
      end
    end
  end
end
