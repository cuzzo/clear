# frozen_string_literal: true

require_relative "finding"
require_relative "fact_mine_provider_helper"

module SlopCop
  module Constraints
    module GoProvider
      module_function

      # Every category below is detected by FactMine's tree-sitter query
      # (gems/fact-mine/src/syntax/go_hazards.scm), the same source of
      # truth Lineage's own hazard ingestion uses - not reimplemented here
      # as a second, independent string-needle classifier that can drift
      # from it.
      SYSTEMS_HAZARD_CATEGORIES = [
        { hazard_type: "go_race_goroutine" },
        { hazard_type: "go_race_atomic" },
        { hazard_type: "go_race_lock" },
        { hazard_type: "go_concurrency_waitgroup" },
        { hazard_type: "go_concurrency_channel" },
        { hazard_type: "go_reflection" }
      ].freeze

      def rules
        [
          {
            "id" => "slopcop-go-race-uncovered",
            "name" => "Go race coverage missing",
            "shortDescription" => { "text" => "Go shared-concurrency site lacks race coverage evidence" },
            "fullDescription" => {
              "text" => "A changed Go goroutine, atomic, lock, or sync primitive was not reached by race coverage."
            },
            "defaultConfiguration" => { "level" => "warning" }
          },
          {
            "id" => "slopcop-go-concurrency-uncovered",
            "name" => "Go concurrency coverage missing",
            "shortDescription" => { "text" => "Go channel/wait site lacks concurrency coverage evidence" },
            "fullDescription" => {
              "text" => "A changed Go channel or wait-group site was not reached by concurrency coverage."
            },
            "defaultConfiguration" => { "level" => "warning" }
          },
          {
            "id" => "slopcop-go-callback-uncovered",
            "name" => "Go callback coverage missing",
            "shortDescription" => { "text" => "Go callback invocation lacks test-tracing coverage evidence" },
            "fullDescription" => {
              "text" => "A changed Go callback or function-value invocation site was not reached by test-tracing coverage evidence."
            },
            "defaultConfiguration" => { "level" => "warning" }
          }
        ]
      end

      def findings(repo:, additions:, evidence:)
        repo = File.expand_path(repo)
        changed_files = additions.keys.select { |path| source_path?(path) }
        return [] if changed_files.empty?

        hazards = FactMineProviderHelper.scan_multi_hazards_via_fact_mine(
          changed_files, repo: repo, language_extension: ".go", categories: all_categories
        )

        hazards.each_with_object([]) do |hazard, out|
          path = hazard[:path]
          lines = additions[path]
          next unless lines&.include?(hazard[:line])
          next unless hazard.fetch(:report_required, true)

          if hazard.fetch(:coverage_required, true)
            next if covered?(evidence, hazard)
            message = "changed #{hazard[:label]} has no #{hazard[:required_evidence]} coverage evidence"
          else
            message = "changed #{hazard[:label]} requires review; #{hazard[:evidence_claim]} evidence cannot satisfy this hazard"
          end

          out << Finding.new(
            path: path,
            line: hazard[:line],
            rule_id: rule_id_for(hazard[:required_evidence]),
            message: message,
            source: hazard[:source],
            hazard_type: hazard[:hazard_type],
            required_evidence: hazard[:required_evidence],
            severity: "warning"
          )
        end
      end

      def source_path?(path)
        path.end_with?(".go") && !path.end_with?("_test.go") && !path.split("/").include?("vendor")
      end

      def scan_hazards(repo:, paths: nil)
        repo = File.expand_path(repo)
        # scan_multi_hazards_via_fact_mine globs by extension alone when no
        # explicit file list is given - it doesn't know this provider also
        # excludes _test.go and vendor/, so that filtering must happen here
        # and an explicit (possibly empty) list passed through either way.
        files = if paths && !Array(paths).empty?
                  Array(paths).select { |path| source_path?(path) }
                else
                  Dir.chdir(repo) { Dir["**/*.go"] }.select { |path| source_path?(path) }
                end
        return [] if files.empty?

        hazards = FactMineProviderHelper.scan_multi_hazards_via_fact_mine(
          files, repo: repo, language_extension: ".go", categories: all_categories
        )
        hazards.uniq { |h| [h[:path], h[:line], h[:hazard_type]] }
               .sort_by { |site| [site[:path], site[:line], site[:hazard_type]] }
      end

      def all_categories
        SYSTEMS_HAZARD_CATEGORIES + [
          { hazard_type: "go_callback_invocation" }
        ]
      end

      def covered?(evidence, hazard)
        evidence_type = hazard[:required_evidence]
        return false unless evidence.known_type?(evidence_type)

        evidence.line_covered?(evidence_type, hazard[:path], hazard[:line])
      end

      def rule_id_for(required_evidence)
        return "slopcop-go-callback-uncovered" if required_evidence == "nil-kill"

        required_evidence == "race" ? "slopcop-go-race-uncovered" : "slopcop-go-concurrency-uncovered"
      end
    end
  end
end
