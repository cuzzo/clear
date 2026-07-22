# frozen_string_literal: true

require_relative "language_provider"
require_relative "fact_mine_provider_helper"

module SlopCop
  module Constraints
    module CsharpProvider
      module_function

      EXCLUDED_DIRS = %w[.git bin obj packages node_modules tmp dist tests test].freeze

      # Every category below is detected by FactMine's tree-sitter query
      # (gems/fact-mine/src/syntax/csharp_hazards.scm), the same source of
      # truth Lineage's own hazard ingestion uses.
      SYSTEMS_HAZARD_CATEGORIES = [
        { hazard_type: "csharp_concurrency" },
        { hazard_type: "csharp_unsafe_memory" }
      ].freeze

      def rules
        [
          {
            "id" => "slopcop-csharp-concurrency-uncovered",
            "name" => "C# concurrency coverage missing",
            "shortDescription" => { "text" => "C# concurrency site lacks concurrency coverage evidence" },
            "fullDescription" => {
              "text" => "A changed C# task, thread, lock, or concurrent collection site was not reached by concurrency coverage evidence."
            },
            "defaultConfiguration" => { "level" => "warning" }
          },
          {
            "id" => "slopcop-csharp-unsafe-uncovered",
            "name" => "C# unsafe coverage missing",
            "shortDescription" => { "text" => "C# unsafe/native-memory site lacks unsafe coverage evidence" },
            "fullDescription" => {
              "text" => "A changed C# unsafe, native-memory, pointer, or Marshal site was not reached by unsafe coverage evidence."
            },
            "defaultConfiguration" => { "level" => "warning" }
          },
          {
            "id" => "slopcop-csharp-metaprogramming-uncovered",
            "name" => "C# metaprogramming coverage missing",
            "shortDescription" => { "text" => "C# reflection or callback site lacks test-tracing coverage evidence" },
            "fullDescription" => {
              "text" => "A changed C# reflection, dynamic, or callback invocation site was not reached by test-tracing coverage evidence."
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
          {
            hazard_type: ["csharp_callback_invocation", "csharp_metaprogramming"]
          }
        ]
        hazards = FactMineProviderHelper.scan_multi_hazards_via_fact_mine(
          paths, repo: repo, language_extension: ".cs", categories: categories
        )
        hazards.uniq { |h| [h[:path], h[:line], h[:hazard_type]] }.sort_by { |h| [h[:path], h[:line]] }
      end

      def source_path?(path)
        path.end_with?(".cs") && !LanguageProvider.excluded_path?(path, dirs: EXCLUDED_DIRS)
      end

      def rule_id_for(required_evidence)
        return "slopcop-csharp-metaprogramming-uncovered" if required_evidence == "nil-kill"

        required_evidence == "concurrency" ? "slopcop-csharp-concurrency-uncovered" : "slopcop-csharp-unsafe-uncovered"
      end

    end
  end
end
