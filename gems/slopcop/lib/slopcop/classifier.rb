# frozen_string_literal: true

require_relative "../../../boobytrap/lib/boobytrap/coverage_data"

module SlopCop
  # Classifies every never-taken branch arm in a target file into ONE
  # actionable category. AST-structural, never a regex over the arm
  # line. General -- no project lexicon baked in (see ffi_boundary:).
  #
  # Categories (not all gaps are equal):
  #   :type_norm  arm/decision guards a type/nil check (is_a?/kind_of?/
  #               nil?/respond_to?/safe-nav). Likely dead if runtime
  #               contracts were stricter.
  #   :dead       no sibling arm of the decision is ever taken in the
  #               supplied coverage. Audit as unexercised code: it may
  #               be a missing test, or dead only if static reachability
  #               tools agree.
  #   :defensive  live decision, inert/pinned polarity (empty else,
  #               nil, invariant-guaranteed). Accept.
  #   :ffi        a caller-declared external/boundary method -> needs
  #               an integration test.
  #   :diagnostic arm raises or calls caller-declared diagnostic
  #               helpers -> invalid-input only.
  #   :genuine    live, reachable, input-determined, none of the above.
  #               The real gap. Ranked by fix-churn downstream.
  module Classifier
    # The gem ships NO project lexicon -- it is general. The consuming
    # project supplies its external/boundary method names via
    # `ffi_boundary:` (CLEAR passes its set from the CLI). Empty here
    # by design.
    DIAGNOSTIC_MIDS = %i[raise fail abort].freeze

    Arm = Struct.new(:file, :defn, :line, :category, :source, keyword_init: true)

    module_function

    def merged_branches(resultset, abspath, root: nil)
      coverage_for(resultset, abspath, root: root)&.branches || {}
    end

    # -> [Arm, ...] for every dark arm in abspath.
    def classify_file(resultset, abspath, ffi_boundary: [], diagnostic_mids: [], root: nil)
      file_coverage = coverage_for(resultset, abspath, root: root)
      if tree_sitter_coverage_file?(abspath, file_coverage)
        return classify_simplecov_branch_file(
          abspath,
          file_coverage,
          ffi_boundary: ffi_boundary,
          diagnostic_mids: diagnostic_mids
        ) if file_coverage.branch_coverage?

        return classify_line_coverage_file(
          abspath,
          file_coverage,
          ffi_boundary: ffi_boundary,
          diagnostic_mids: diagnostic_mids
        )
      end

      return classify_static_file(abspath,
                                  ffi_boundary: ffi_boundary,
                                  diagnostic_mids: diagnostic_mids) if tree_sitter_source?(abspath)

      []
    end

    def coverage_for(resultset, abspath, root: nil)
      return nil unless resultset

      root ||= File.dirname(abspath)
      coverage_dataset(resultset, root: root)[abspath]
    rescue StandardError
      nil
    end

    def coverage_dataset(resultset, root:)
      @coverage_cache ||= {}
      key = [File.expand_path(resultset), File.expand_path(root)]
      @coverage_cache[key] ||= Boobytrap::CoverageData.load(resultset, root: root)
    end

    def classify_static_file(abspath, ffi_boundary: [], diagnostic_mids: [])
      return [] unless load_decomplex_syntax
      return [] unless Decomplex::Syntax.supported_source?(abspath, parser: "tree_sitter")

      doc = Decomplex::Syntax.parse(abspath, parser: "tree_sitter")
      doc.branch_arms.filter_map do |arm|
        cat = categorize_text(
          arm.function,
          arm.kind,
          arm.body,
          true,
          arm.predicate,
          ffi_boundary,
          diagnostic_mids
        )
        next if cat.nil?

        Arm.new(file: abspath, defn: arm.function, line: arm.line,
                category: cat, source: :tree_sitter_static)
      end
    rescue LoadError, StandardError
      []
    end

    def classify_line_coverage_file(abspath, file_coverage, ffi_boundary: [], diagnostic_mids: [])
      return [] unless load_decomplex_syntax
      return [] unless Decomplex::Syntax.supported_source?(abspath, parser: "tree_sitter")

      doc = Decomplex::Syntax.parse(abspath, parser: "tree_sitter")
      covered_arms = Boobytrap::CoverageData.branch_arm_coverage(file_coverage, doc.branch_arms)
      groups = covered_arms.group_by do |arm_cov|
        arm = arm_cov.arm
        [arm.kind, arm.decision_line, arm.decision_span]
      end

      covered_arms.filter_map do |arm_cov|
        next if arm_cov.covered

        arm = arm_cov.arm
        group = groups.fetch([arm.kind, arm.decision_line, arm.decision_span], [])
        sibling_taken = group.any?(&:covered)
        cat = categorize_text(
          arm.function,
          arm.kind,
          arm.body,
          sibling_taken,
          arm.predicate,
          ffi_boundary,
          diagnostic_mids
        )
        next if cat.nil?

        Arm.new(file: abspath, defn: arm.function, line: arm.line,
                category: cat, source: arm_cov.source)
      end
    rescue LoadError, StandardError
      []
    end

    def classify_simplecov_branch_file(abspath, file_coverage, ffi_boundary: [], diagnostic_mids: [])
      return [] unless load_decomplex_syntax
      return [] unless Decomplex::Syntax.supported_source?(abspath, parser: "tree_sitter")

      doc = Decomplex::Syntax.parse(abspath, parser: "tree_sitter")
      covered_arms = simplecov_branch_arm_coverage(file_coverage, doc.branch_arms)
      groups = covered_arms.group_by do |arm_cov|
        arm = arm_cov.arm
        [arm.kind, arm.decision_line, arm.decision_span]
      end

      covered_arms.filter_map do |arm_cov|
        next if arm_cov.covered

        arm = arm_cov.arm
        group = groups.fetch([arm.kind, arm.decision_line, arm.decision_span], [])
        sibling_taken = group.any?(&:covered)
        cat = categorize_text(
          arm.function,
          arm.kind,
          arm.body,
          sibling_taken,
          arm.predicate,
          ffi_boundary,
          diagnostic_mids
        )
        next if cat.nil?

        Arm.new(file: abspath, defn: arm.function, line: arm.line,
                category: cat, source: :coverage)
      end
    rescue LoadError, StandardError
      []
    end

    def simplecov_branch_arm_coverage(file_coverage, branch_arms)
      file_coverage.branches.flat_map do |parent_key, arms|
        parent = coverage_tuple(parent_key)
        arms.flat_map do |arm_key, hits|
          tuple = coverage_tuple(arm_key)
          next [] unless tuple

          matching_branch_arms(branch_arms, parent, tuple).map do |arm|
            Boobytrap::CoverageData::ArmCoverage.new(
              arm: arm,
              covered: hits.to_i.positive?,
              hits: hits.to_i,
              executable_lines: [arm.line],
              source: :coverage
            )
          end
        end
      end
    end

    def matching_branch_arms(branch_arms, parent, tuple)
      candidates = branch_arms.select { |arm| same_span?(arm.span, tuple[:span]) }
      if candidates.empty?
        candidates = branch_arms.select { |arm| span_contains?(arm.span, tuple[:span]) }
      end
      if candidates.empty?
        candidates = branch_arms.select do |arm|
          arm.line.to_i == tuple[:span][0] && arm.member.to_s == tuple[:kind].to_s
        end
      end
      if parent && candidates.size > 1
        decision_span = parent[:span]
        narrowed = candidates.select do |arm|
          same_span?(arm.decision_span, decision_span) || arm.decision_line.to_i == decision_span[0]
        end
        candidates = narrowed unless narrowed.empty?
      end
      candidates
    end

    def coverage_tuple(value)
      fields = value.to_s.gsub(/[\[\]\":]/, "").split(",").map(&:strip)
      return nil if fields.size < 6

      {
        kind: fields[0].delete_prefix(":"),
        id: fields[1],
        span: fields[-4, 4].map(&:to_i)
      }
    end

    def same_span?(left, right)
      Array(left).map(&:to_i) == Array(right).map(&:to_i)
    end

    def span_contains?(outer, inner)
      outer = Array(outer).map(&:to_i)
      inner = Array(inner).map(&:to_i)
      return false unless outer.size == 4 && inner.size == 4

      starts_before = outer[0] < inner[0] || (outer[0] == inner[0] && outer[1] <= inner[1])
      ends_after = outer[2] > inner[2] || (outer[2] == inner[2] && outer[3] >= inner[3])
      starts_before && ends_after
    end

    def tree_sitter_source?(abspath)
      return false unless load_decomplex_syntax
      return false unless Decomplex::Syntax.supported_source?(abspath, parser: "tree_sitter")

      true
    rescue LoadError, StandardError
      false
    end

    def tree_sitter_coverage_file?(abspath, file_coverage)
      return false unless file_coverage&.line_coverage? || file_coverage&.branch_arm_coverage? || file_coverage&.branch_coverage?

      tree_sitter_source?(abspath)
    end

    def tree_sitter?
      ENV.fetch("DECOMPLEX_PARSER", "tree_sitter").to_s.tr("-", "_") == "tree_sitter"
    end

    def categorize_text(method, pkind, body, sibling_taken, predicate = nil,
                        ffi_boundary = [], diagnostic_mids = [])
      return :ffi if ffi_boundary.include?(method)
      return :diagnostic if diagnostic_text?(body, diagnostic_mids)
      return :type_norm if type_guard_text?(predicate) || type_guard_text?(body, allow_literal_nil: false)
      return :dead unless sibling_taken
      return :defensive if trivial_text?(body)

      if %i[case if unless ternary while until for loop].include?(pkind)
        :genuine
      else
        :defensive
      end
    end

    def diagnostic_text?(text, diagnostic_mids = [])
      names = DIAGNOSTIC_MIDS.map(&:to_s) + diagnostic_mids.map(&:to_s)
      source = text.to_s
      names.any? { |name| source.match?(/(?:\A|[^\w!?])#{Regexp.escape(name)}[!?]?(?:\s*\(|\b)/) } ||
        source.match?(/\b(?:panic|unreachable|throw)\b/) ||
        source.match?(/\breturn\s+error[.\w]*/)
    end

    def type_guard_text?(text, allow_literal_nil: true)
      source = text.to_s
      (allow_literal_nil && source.match?(/\b(?:nil|null|none|undefined)\b/i)) ||
        source.match?(/(?:\A|[^\w!?])(?:is_a\?|kind_of\?|instance_of\?|respond_to\?|isinstance|typeof|typeid)(?:\s*\(|\b)/) ||
        source.match?(/&\./) ||
        source.match?(/@typeInfo\b/) ||
        source.match?(/\bkind\s*(?:==|!=)/)
    end

    def trivial_text?(text)
      stripped = text.to_s.strip
      return true if stripped.empty?

      stripped.match?(/\A(?:nil|null|None|undefined|true|false|0|1|break|continue|unreachable)\s*;?\z/) ||
        stripped.match?(/\Areturn\s+(?:nil|null|None|undefined|true|false|0|1)\s*;?\z/)
    end

    def load_decomplex_syntax
      return true if defined?(Decomplex::Syntax)

      require "decomplex/syntax"
      true
    rescue LoadError
      sibling = File.expand_path("../../../decomplex/lib/decomplex/syntax", __dir__)
      return false unless File.file?("#{sibling}.rb")

      require sibling
      true
    end
  end
end
