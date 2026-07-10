# frozen_string_literal: true

module RubyToClear
  module Analysis
    module Reporter
      GATES = %w[g0 g1 g2 g3 g4].freeze

      module_function

      def aggregate(units)
        total_loc = units.sum { |unit| unit.fetch("source_loc") }
        gates = GATES.to_h do |gate|
          passed = units.select { |unit| unit.dig("gates", gate) == "pass" }
          unknown = units.count { |unit| unit.dig("gates", gate) == "unknown" }
          passed_loc = passed.sum { |unit| unit.fetch("source_loc") }
          [gate, {
            "passed_files" => passed.length,
            "total_files" => units.length,
            "file_percent" => percent(passed.length, units.length),
            "passed_source_loc" => passed_loc,
            "total_source_loc" => total_loc,
            "source_loc_percent" => percent(passed_loc, total_loc),
            "unknown_files" => unknown
          }]
        end

        failures = units.filter_map { |unit| unit["failure"]&.fetch("code", nil) }.tally.sort.to_h
        fingerprints = units.filter_map do |unit|
          failure = unit["failure"]
          [failure["code"], failure["fingerprint"]] if failure
        end.tally.sort_by { |(_key, count)| -count }.to_h

        {
          "files" => units.length,
          "source_loc" => total_loc,
          "gates" => gates,
          "failure_codes" => failures,
          "failure_fingerprints" => fingerprints.map do |(code, fingerprint), count|
            { "code" => code, "fingerprint" => fingerprint, "count" => count }
          end,
          "autofix_assisted_files" => units.count { |unit| unit.dig("autofix", "g4") == "pass" },
          "autofix" => {
            "attempted_files" => units.count { |unit| unit.dig("autofix", "fix") },
            "completed_files" => units.count { |unit| unit.dig("autofix", "fix") == "pass" },
            "failed_files" => units.count { |unit| unit.dig("autofix", "fix") == "fail" },
            "changed_files" => units.count { |unit| unit.dig("autofix", "changed") == true }
          },
          "behavior_oracles" => {
            "configured_units" => units.count { |unit| unit.dig("gates", "g5") != "not_configured" },
            "verified_units" => units.count { |unit| unit.dig("gates", "g5") == "pass" }
          }
        }
      end

      def node_metrics(units)
        encountered = Hash.new(0)
        handler_present = Hash.new(0)
        compile_exercised = Hash.new(0)

        units.each do |unit|
          unit.fetch("prism_nodes", {}).each do |name, count|
            encountered[name] += count
            handler_present[name] += count if unit.dig("gates", "g1") == "pass"
            compile_exercised[name] += count if unit.dig("gates", "g4") == "pass"
          end
        end

        encountered.keys.sort.to_h do |name|
          [name, {
            "encountered" => encountered[name],
            "handler_present" => handler_present[name],
            "compile_exercised" => compile_exercised[name],
            "behavior_verified" => 0
          }]
        end
      end

      def markdown(report)
        aggregate = report.fetch("aggregate")
        out = ["# True Clean Transpilation Report", ""]
        out << "- revision: `#{report.fetch("revision")}`"
        out << "- manifest: `#{report.fetch("manifest_sha256")}`"
        out << "- corpus: #{aggregate.fetch("files")} files, #{aggregate.fetch("source_loc")} nonblank Ruby source LoC"
        out << "- artifacts: `#{report.fetch("artifact_root")}`"
        out << ""
        out << "## Gates"
        out << ""
        out << "| Gate | Files | File % | Source LoC | LoC % | Unknown |"
        out << "| --- | ---: | ---: | ---: | ---: | ---: |"
        Reporter::GATES.each do |gate|
          row = aggregate.dig("gates", gate)
          out << "| #{gate.upcase} | #{row["passed_files"]}/#{row["total_files"]} | #{format("%.2f", row["file_percent"])}% | #{row["passed_source_loc"]}/#{row["total_source_loc"]} | #{format("%.2f", row["source_loc_percent"])}% | #{row["unknown_files"]} |"
        end
        out << ""
        out << "Clean transpilation means raw G1-G4 success. Autofix-assisted results are separate."
        out << ""
        out << "- raw build-clean files: #{aggregate.dig("gates", "g4", "passed_files")}"
        out << "- autofix-assisted build-clean files: #{aggregate.fetch("autofix_assisted_files")}"
        out << "- autofix completed files: #{aggregate.dig("autofix", "completed_files")}/#{aggregate.dig("autofix", "attempted_files")} (#{aggregate.dig("autofix", "failed_files")} fixer crashes)"
        out << "- autofix changed files: #{aggregate.dig("autofix", "changed_files")}"
        out << "- behavior oracles: #{aggregate.dig("behavior_oracles", "verified_units")}/#{aggregate.dig("behavior_oracles", "configured_units")} configured units verified"
        out << ""
        out << "## Failure Codes"
        out << ""
        if aggregate.fetch("failure_codes").empty?
          out << "No failures."
        else
          aggregate.fetch("failure_codes").each { |code, count| out << "- `#{code}`: #{count}" }
        end
        out << ""
        out << "## Top Failure Fingerprints"
        out << ""
        aggregate.fetch("failure_fingerprints").first(20).each do |item|
          out << "- #{item["count"]} x `#{item["code"]}`: #{item["fingerprint"]}"
        end
        out << ""
        out << "## Units"
        out << ""
        out << "| Unit | LoC | G1 | G2 | G3 | G4 | Failure | Autofix G4 |"
        out << "| --- | ---: | --- | --- | --- | --- | --- | --- |"
        report.fetch("units").each do |unit|
          out << "| `#{unit["source"]}` | #{unit["source_loc"]} | #{unit.dig("gates", "g1")} | #{unit.dig("gates", "g2")} | #{unit.dig("gates", "g3")} | #{unit.dig("gates", "g4")} | #{unit.dig("failure", "code") || ""} | #{unit.dig("autofix", "g4") || "not_run"} |"
        end
        out.join("\n") + "\n"
      end

      def percent(numerator, denominator)
        return 0.0 if denominator.zero?

        (100.0 * numerator / denominator).round(4)
      end
    end
  end
end
