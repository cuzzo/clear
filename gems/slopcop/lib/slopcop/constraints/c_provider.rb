# frozen_string_literal: true

require_relative "fact_mine_provider_helper"
require_relative "language_provider"

module SlopCop
  module Constraints
    module CProvider
      module_function

      EXCLUDED_DIRS = %w[.git vendor third_party node_modules build cmake-build-debug cmake-build-release tmp dist tests test].freeze

      # Every category below is detected by FactMine's tree-sitter query
      # (gems/fact-mine/src/syntax/c_hazards.scm), the same source of truth
      # Lineage's own hazard ingestion uses.
      SYSTEMS_HAZARD_CATEGORIES = [
        { hazard_type: "c_tsan_concurrency", required_evidence: "tsan", label: "C atomic/thread/lock site" },
        { hazard_type: "c_asan_raw_memory_api", required_evidence: "asan", label: "C raw-memory or unchecked buffer API" },
        { hazard_type: "c_lsan_lifetime", required_evidence: "lsan", label: "C allocation/free lifetime site" },
        { hazard_type: "c_ubsan_arithmetic", required_evidence: "ubsan", label: "C divide/modulo/shift arithmetic site" },
        { hazard_type: "c_ubsan_cast", required_evidence: "ubsan", label: "C pointer/integer cast site" }
      ].freeze

      def rules
        evidence_rule("tsan", "C TSan coverage missing", "C shared-concurrency site lacks TSan coverage evidence") +
          evidence_rule("asan", "C ASan coverage missing", "C raw-memory site lacks ASan coverage evidence") +
          evidence_rule("lsan", "C LSan coverage missing", "C allocation/lifetime site lacks LSan coverage evidence") +
          evidence_rule("ubsan", "C UBSan coverage missing", "C undefined-behavior site lacks UBSan coverage evidence") +
          [
            {
              "id" => "slopcop-c-callback-uncovered",
              "name" => "C callback coverage missing",
              "shortDescription" => { "text" => "C function-pointer invocation lacks test-tracing coverage evidence" },
              "fullDescription" => {
                "text" => "A changed C function-pointer invocation site was not reached by test-tracing coverage evidence."
              },
              "defaultConfiguration" => { "level" => "warning" }
            }
          ]
      end

      def evidence_rule(evidence, name, short)
        [
          {
            "id" => "slopcop-c-#{evidence}-uncovered",
            "name" => name,
            "shortDescription" => { "text" => short },
            "fullDescription" => {
              "text" => "A changed C #{evidence.upcase} hazard was not reached by #{evidence.upcase} coverage evidence."
            },
            "defaultConfiguration" => { "level" => "warning" }
          }
        ]
      end

      def findings(repo:, additions:, evidence:)
        LanguageProvider.findings(self, repo: repo, additions: additions, evidence: evidence)
      end

      def scan_hazards(repo:, paths: nil)
        categories = SYSTEMS_HAZARD_CATEGORIES + [
          { hazard_type: "c_callback_invocation", required_evidence: "nil-kill", label: "C function-pointer invocation site" }
        ]
        hazards = FactMineProviderHelper.scan_multi_hazards_via_fact_mine(
          paths, repo: repo, language_extension: [".c", ".h"], categories: categories
        )
        hazards.uniq { |h| [h[:path], h[:line], h[:hazard_type]] }.sort_by { |h| [h[:path], h[:line]] }
      end

      def source_path?(path)
        (path.end_with?(".c") || path.end_with?(".h")) &&
          !LanguageProvider.excluded_path?(path, dirs: EXCLUDED_DIRS)
      end

      def rule_id_for(required_evidence)
        return "slopcop-c-callback-uncovered" if required_evidence == "nil-kill"

        "slopcop-c-#{required_evidence}-uncovered"
      end

    end
  end
end
