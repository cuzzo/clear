# frozen_string_literal: true

require_relative "language_provider"
require_relative "fact_mine_provider_helper"

module SlopCop
  module Constraints
    module JavaProvider
      module_function

      EXCLUDED_DIRS = %w[target node_modules tmp dist test tests examples].freeze

      def rules
        [
          {
            "id" => "slopcop-java-metaprogramming-uncovered",
            "name" => "Java metaprogramming coverage missing",
            "shortDescription" => { "text" => "Java metaprogramming site lacks test-tracing coverage evidence" },
            "fullDescription" => {
              "text" => "A changed Java reflection or dynamic proxy site was not reached by Nil-Kill / test-tracing coverage evidence."
            },
            "defaultConfiguration" => { "level" => "warning" }
          }
        ]
      end

      def findings(repo:, additions:, evidence:)
        FactMineProviderHelper.findings_via_fact_mine(self, repo: repo, additions: additions, evidence: evidence)
      end

      def scan_hazards(repo:, paths: nil)
        FactMineProviderHelper.scan_hazards_via_fact_mine(
          paths,
          repo: repo,
          language_extension: ".java",
          hazard_type_filter: ["java_metaprogramming", "java_callback_invocation"],
          required_evidence: "nil-kill",
          label: "Java metaprogramming site"
        )
      end

      def source_path?(path)
        path.end_with?(".java") && !LanguageProvider.excluded_path?(path, dirs: EXCLUDED_DIRS)
      end

      def rule_id_for(required_evidence)
        "slopcop-java-metaprogramming-uncovered"
      end
    end
  end
end
