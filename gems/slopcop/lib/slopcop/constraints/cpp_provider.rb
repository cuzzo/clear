# frozen_string_literal: true

require_relative "language_provider"
require_relative "fact_mine_provider_helper"

module SlopCop
  module Constraints
    module CppProvider
      module_function

      EXCLUDED_DIRS = %w[.git vendor third_party node_modules build cmake-build-debug cmake-build-release tmp dist tests test].freeze
      EXTENSIONS = %w[.cc .cpp .cxx .hh .hpp .hxx].freeze

      # Every category below is detected by FactMine's tree-sitter query
      # (gems/fact-mine/src/syntax/cpp_hazards.scm), the same source of
      # truth Lineage's own hazard ingestion uses.
      SYSTEMS_HAZARD_CATEGORIES = [
        { hazard_type: "cpp_tsan_concurrency" },
        { hazard_type: "cpp_asan_raw_memory_api" },
        { hazard_type: "cpp_asan_pointer_or_cast" },
        { hazard_type: "cpp_lsan_lifetime" },
        { hazard_type: "cpp_ubsan_arithmetic" },
        { hazard_type: "cpp_ubsan_cast" },
        { hazard_type: "cpp_dynamic_loading" }
      ].freeze

      def rules
        evidence_rule("tsan", "C++ TSan coverage missing", "C++ shared-concurrency site lacks TSan coverage evidence") +
          evidence_rule("asan", "C++ ASan coverage missing", "C++ raw-memory site lacks ASan coverage evidence") +
          evidence_rule("lsan", "C++ LSan coverage missing", "C++ allocation/lifetime site lacks LSan coverage evidence") +
          evidence_rule("ubsan", "C++ UBSan coverage missing", "C++ undefined-behavior site lacks UBSan coverage evidence") +
          [
            {
              "id" => "slopcop-cpp-callback-uncovered",
              "name" => "C++ callback coverage missing",
              "shortDescription" => { "text" => "C++ function-pointer invocation lacks test-tracing coverage evidence" },
              "fullDescription" => {
                "text" => "A changed C++ function-pointer or callable invocation site was not reached by test-tracing coverage evidence."
              },
              "defaultConfiguration" => { "level" => "warning" }
            }
          ]
      end

      def evidence_rule(evidence, name, short)
        [
          {
            "id" => "slopcop-cpp-#{evidence}-uncovered",
            "name" => name,
            "shortDescription" => { "text" => short },
            "fullDescription" => {
              "text" => "A changed C++ #{evidence.upcase} hazard was not reached by #{evidence.upcase} coverage evidence."
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
          { hazard_type: "cpp_callback_invocation" }
        ]
        hazards = FactMineProviderHelper.scan_multi_hazards_via_fact_mine(
          paths, repo: repo, language_extension: EXTENSIONS, categories: categories
        )
        hazards.uniq { |h| [h[:path], h[:line], h[:hazard_type]] }.sort_by { |h| [h[:path], h[:line]] }
      end

      def source_path?(path)
        EXTENSIONS.any? { |extension| path.end_with?(extension) } &&
          !LanguageProvider.excluded_path?(path, dirs: EXCLUDED_DIRS)
      end

      def rule_id_for(required_evidence)
        return "slopcop-cpp-callback-uncovered" if required_evidence == "nil-kill"

        "slopcop-cpp-#{required_evidence}-uncovered"
      end

    end
  end
end
