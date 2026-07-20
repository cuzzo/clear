# frozen_string_literal: true

require_relative "language_provider"
require_relative "fact_mine_provider_helper"

module SlopCop
  module Constraints
    module PythonProvider
      module_function

      EXCLUDED_DIRS = %w[venv .venv node_modules tmp dist test tests examples].freeze

      def rules
        [
          {
            "id" => "slopcop-python-metaprogramming-uncovered",
            "name" => "Python metaprogramming coverage missing",
            "shortDescription" => { "text" => "Python metaprogramming site lacks test-tracing coverage evidence" },
            "fullDescription" => {
              "text" => "A changed Python metaprogramming, magic attribute, or exec/eval site was not reached by Nil-Kill / test-tracing coverage evidence."
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
          language_extension: ".py",
          hazard_type_filter: "python_metaprogramming",
          required_evidence: "nil-kill",
          label: "Python metaprogramming site"
        )
      end

      def source_path?(path)
        path.end_with?(".py") && !LanguageProvider.excluded_path?(path, dirs: EXCLUDED_DIRS)
      end

      def rule_id_for(required_evidence)
        "slopcop-python-metaprogramming-uncovered"
      end
    end
  end
end
