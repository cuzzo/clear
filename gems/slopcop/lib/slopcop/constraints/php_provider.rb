# frozen_string_literal: true

require_relative "language_provider"
require_relative "fact_mine_provider_helper"

module SlopCop
  module Constraints
    module PhpProvider
      module_function

      EXCLUDED_DIRS = %w[vendor node_modules tmp dist test tests examples].freeze

      def rules
        [
          {
            "id" => "slopcop-php-metaprogramming-uncovered",
            "name" => "PHP metaprogramming coverage missing",
            "shortDescription" => { "text" => "PHP metaprogramming site lacks test-tracing coverage evidence" },
            "fullDescription" => {
              "text" => "A changed PHP dynamic call or reflection site was not reached by Nil-Kill / test-tracing coverage evidence."
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
          language_extension: ".php",
          hazard_type_filter: ["php_metaprogramming", "php_callback_invocation"],
        )
      end

      def source_path?(path)
        path.end_with?(".php") && !LanguageProvider.excluded_path?(path, dirs: EXCLUDED_DIRS)
      end

      def rule_id_for(required_evidence)
        "slopcop-php-metaprogramming-uncovered"
      end
    end
  end
end
