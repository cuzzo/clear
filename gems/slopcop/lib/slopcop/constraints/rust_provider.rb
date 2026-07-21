# frozen_string_literal: true

require_relative "fact_mine_provider_helper"
require_relative "language_provider"
module SlopCop
  module Constraints
    module RustProvider
      module_function

      EXCLUDED_DIRS = %w[target vendor node_modules tmp dist tests benches examples].freeze

      # Every category below is detected by FactMine's tree-sitter query
      # (gems/fact-mine/src/syntax/rust_hazards.scm), the same source of
      # truth Lineage's own hazard ingestion uses - not reimplemented here
      # as a second, independent regex/needle classifier that can drift
      # from it (see gems/lineage/src/db/hazard.rs's fixed
      # "unsafe_block" contains "lock" misclassification for exactly the
      # kind of drift two implementations of "detect this hazard" invite).
      SYSTEMS_HAZARD_CATEGORIES = [
        { hazard_type: "rust_loom_atomic", required_evidence: "loom", label: "atomic or memory-ordering site" },
        { hazard_type: "rust_loom_concurrency", required_evidence: "loom", label: "thread/lock/shared-concurrency site" },
        { hazard_type: "rust_unsafe_fn", required_evidence: "miri", label: "unsafe function" },
        { hazard_type: "rust_unsafe_impl", required_evidence: "miri", label: "unsafe impl" },
        { hazard_type: "rust_unsafe_block", required_evidence: "miri", label: "unsafe block" },
        { hazard_type: "rust_unsafe_operation", required_evidence: "miri", label: "unsafe operation inside unsafe context" }
      ].freeze

      def rules
        [
          {
            "id" => "slopcop-rust-loom-uncovered",
            "name" => "Rust Loom coverage missing",
            "shortDescription" => { "text" => "Rust concurrency site lacks Loom coverage evidence" },
            "fullDescription" => {
              "text" => "A changed Rust atomic, lock, thread, or shared-concurrency site was not reached by Loom coverage evidence."
            },
            "defaultConfiguration" => { "level" => "warning" }
          },
          {
            "id" => "slopcop-rust-miri-uncovered",
            "name" => "Rust unsafe coverage missing",
            "shortDescription" => { "text" => "Rust unsafe site lacks Miri/unsafe coverage evidence" },
            "fullDescription" => {
              "text" => "A changed Rust unsafe block, unsafe declaration, or unsafe operation was not reached by Miri-style evidence."
            },
            "defaultConfiguration" => { "level" => "warning" }
          },
          {
            "id" => "slopcop-rust-callback-uncovered",
            "name" => "Rust callback coverage missing",
            "shortDescription" => { "text" => "Rust callback site lacks Nil-Kill coverage evidence" },
            "fullDescription" => {
              "text" => "A changed Rust callback or function pointer invocation site was not reached by Nil-Kill coverage evidence."
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
          { hazard_type: "rust_callback_invocation", required_evidence: "nil-kill", label: "Rust callback invocation site" }
        ]
        hazards = FactMineProviderHelper.scan_multi_hazards_via_fact_mine(
          paths, repo: repo, language_extension: ".rs", categories: categories
        )
        hazards.uniq { |h| [h[:path], h[:line], h[:hazard_type]] }.sort_by { |h| [h[:path], h[:line]] }
      end

      def source_path?(path)
        path.end_with?(".rs") && !LanguageProvider.excluded_path?(path, dirs: EXCLUDED_DIRS)
      end

      def rule_id_for(required_evidence)
        if required_evidence == "nil-kill"
          "slopcop-rust-callback-uncovered"
        elsif required_evidence == "loom"
          "slopcop-rust-loom-uncovered"
        else
          "slopcop-rust-miri-uncovered"
        end
      end

    end
  end
end
