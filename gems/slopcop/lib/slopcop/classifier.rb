# frozen_string_literal: true

require_relative "../../../boobytrap/lib/boobytrap/coverage_data"

module SlopCop
  # Classifies every never-taken branch arm in a target file into ONE
  # actionable category. Parser-structural, with language text
  # patterns supplied by Decomplex::Syntax lexicons. General -- no
  # project lexicon baked in (see ffi_boundary:).
  #
  # Categories (not all gaps are equal):
  #   :type_norm  arm/decision guards a language-profile type/null
  #               check. Likely dead if runtime contracts were stricter.
  #   :dead       no sibling arm of the decision is ever taken in the
  #               supplied coverage. Audit as unexercised code: it may
  #               be a missing test, or dead only if static reachability
  #               tools agree.
  #   :defensive  live decision, inert/pinned polarity (empty else,
  #               nil, invariant-guaranteed). Accept.
  #   :ffi        a caller-declared external/boundary method -> needs
  #               an integration test.
  #   :diagnostic arm emits a language diagnostic or calls
  #               caller-declared diagnostic helpers ->
  #               invalid-input only.
  #   :genuine    live, reachable, input-determined, none of the above.
  #               The real gap. Ranked by fix-churn downstream.
  module Classifier
    # The gem ships NO project lexicon -- it is general. The consuming
    # project supplies its external/boundary method names via
    # `ffi_boundary:` (CLEAR passes its set from the CLI). Empty here
    # by design.
    Arm = Struct.new(:file, :defn, :line, :span, :decision_span, :category, :source, keyword_init: true)

    module_function

    def merged_branches(resultset, abspath, root: nil)
      coverage_for(resultset, abspath, root: root)&.branches || {}
    end

    # -> [Arm, ...] for every dark arm in abspath.
    def classify_file(resultset, abspath, ffi_boundary: [], diagnostic_mids: [], root: nil)
      file_coverage = coverage_for(resultset, abspath, root: root)
      if tree_sitter_coverage_file?(abspath, file_coverage)
        return classify_coverage_file(
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
      lexicon = Decomplex::Syntax.language_lexicon(doc.language)
      doc.branch_arms.filter_map do |arm|
        cat = categorize_text(
          arm.function,
          arm.kind,
          arm.body,
          true,
          arm.predicate,
          ffi_boundary,
          diagnostic_mids,
          lexicon: lexicon
        )
        next if cat.nil?

        Arm.new(file: abspath, defn: arm.function, line: arm.line,
                span: arm.span, decision_span: arm.decision_span,
                category: cat, source: :tree_sitter_static)
      end
    rescue LoadError, StandardError
      []
    end

    def classify_coverage_file(abspath, file_coverage, ffi_boundary: [], diagnostic_mids: [])
      return [] unless load_decomplex_syntax
      return [] unless Decomplex::Syntax.supported_source?(abspath, parser: "tree_sitter")

      doc = Decomplex::Syntax.parse(abspath, parser: "tree_sitter")
      lexicon = Decomplex::Syntax.language_lexicon(doc.language)
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
          diagnostic_mids,
          lexicon: lexicon
        )
        next if cat.nil?

        Arm.new(file: abspath, defn: arm.function, line: arm.line,
                span: arm.span, decision_span: arm.decision_span,
                category: cat, source: arm_cov.source)
      end
    rescue LoadError, StandardError
      []
    end

    def tree_sitter_source?(abspath)
      return false unless load_decomplex_syntax
      return false unless Decomplex::Syntax.supported_source?(abspath, parser: "tree_sitter")

      true
    rescue LoadError, StandardError
      false
    end

    def tree_sitter_coverage_file?(abspath, file_coverage)
      return false unless file_coverage&.branch_arm_coverage? || file_coverage&.branch_coverage?

      tree_sitter_source?(abspath)
    end

    def tree_sitter?
      ENV.fetch("DECOMPLEX_PARSER", "tree_sitter").to_s.tr("-", "_") == "tree_sitter"
    end

    def categorize_text(method, pkind, body, sibling_taken, predicate = nil,
                        ffi_boundary = [], diagnostic_mids = [],
                        language: :ruby, lexicon: nil)
      lexicon ||= classification_lexicon(language)
      return :ffi if ffi_boundary.include?(method)
      return :diagnostic if diagnostic_text?(body, diagnostic_mids, lexicon: lexicon)
      return :type_norm if type_guard_text?(predicate, lexicon: lexicon) ||
                           type_guard_text?(body, allow_literal_nil: false, lexicon: lexicon)
      return :dead unless sibling_taken
      return :defensive if trivial_text?(body, lexicon: lexicon)

      if %i[case if unless ternary while until for loop].include?(pkind)
        :genuine
      else
        :defensive
      end
    end

    def diagnostic_text?(text, diagnostic_mids = [], language: :ruby, lexicon: nil)
      (lexicon || classification_lexicon(language)).diagnostic?(
        text,
        extra_names: diagnostic_mids
      )
    end

    def type_guard_text?(text, allow_literal_nil: true, language: :ruby, lexicon: nil)
      (lexicon || classification_lexicon(language)).type_guard?(
        text,
        allow_literal_nil: allow_literal_nil
      )
    end

    def trivial_text?(text, language: :ruby, lexicon: nil)
      (lexicon || classification_lexicon(language)).trivial?(text)
    end

    def classification_lexicon(language)
      return Decomplex::Syntax.language_lexicon(language) if load_decomplex_syntax &&
                                                             Decomplex::Syntax.respond_to?(:language_lexicon)

      raise LoadError, "SlopCop classification requires Decomplex::Syntax language lexicons"
    end

    def load_decomplex_syntax
      return true if defined?(Decomplex::Syntax)

      sibling = File.expand_path("../../../decomplex/lib/decomplex/syntax", __dir__)
      if File.file?("#{sibling}.rb")
        require sibling
        return true
      end

      require "decomplex/syntax"
      true
    rescue LoadError
      false
    end
  end
end
