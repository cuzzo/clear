# frozen_string_literal: true

require_relative "language_provider"
require_relative "fact_mine_provider_helper"

module SlopCop
  module Constraints
    module JavascriptProvider
      module_function

      EXCLUDED_DIRS = %w[node_modules tmp dist test tests examples].freeze

      def rules
        [
          {
            "id" => "slopcop-javascript-metaprogramming-uncovered",
            "name" => "JavaScript metaprogramming coverage missing",
            "shortDescription" => { "text" => "JavaScript metaprogramming site lacks test-tracing coverage evidence" },
            "fullDescription" => {
              "text" => "A changed JavaScript metaprogramming, Proxy, Reflect, or eval site was not reached by Nil-Kill / test-tracing coverage evidence."
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
          language_extension: ".js",
          hazard_type_filter: "javascript_metaprogramming",
          required_evidence: "nil-kill",
          label: "JavaScript metaprogramming site"
        )
      end

      def source_path?(path)
        path.end_with?(".js") && !LanguageProvider.excluded_path?(path, dirs: EXCLUDED_DIRS)
      end

      def rule_id_for(required_evidence)
        "slopcop-javascript-metaprogramming-uncovered"
      end
    end
  end
end
