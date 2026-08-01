# frozen_string_literal: true

module Espalier
  # Language-neutral proof accounting for function-level Big-O results.
  #
  # This deliberately classifies evidence rather than complexity expressions:
  # emitting O(N) is not progress unless its proof obligations are discharged
  # or explicitly represented by a trusted/modelled contract.
  module BigOProofMetrics
    DEFAULT_MINIMUM_PERCENT = 85.0

    CATEGORY_LABELS = {
      known_provably: "Known provably, no assumptions",
      known_likely: "Known likely/trusted/model-derived",
      known_candidate_max: "Known likely — maximum over closed implementation candidates",
      unknown: "Unknown / further proof required"
    }.freeze

    BUCKET_LABELS = {
      analyzer_result: "No-assumption analyzer result",
      exact_or_declared: "Exact/declared registry result",
      modeled_world: "Modeled-world result without SCC assumption",
      closed_candidate_max: "Maximum over closed implementation candidates",
      parametric: "Analyzer-proven parametric callback/reflection bound",
      recursive_progress: "SCC/progress proof missing",
      external_latency: "External-latency model",
      incomplete: "Currently incomplete",
      unknowable: "Demonstrated unknowable"
    }.freeze

    RECURSIVE_QUALITIES = %w[
      upper_bound_acyclic_project_scc
      upper_bound_recursive_multiplicity
      upper_bound_structural_descent
    ].freeze
    MODELED_QUALITY = "upper_bound_modeled_world"
    CLOSED_CANDIDATE_MAX_QUALITY = "upper_bound_closed_candidate_max"
    EXTERNAL_LATENCY_QUALITY = "upper_bound_external_latency_excluded"
    PARAMETRIC_QUALITY_PREFIX = "upper_bound_parametric_"

    module_function

    def classify(quality)
      return :unknown if demonstrated_unknowable?(quality)
      return :unknown unless complete?(quality)
      return :known_candidate_max if qualities(quality).include?(CLOSED_CANDIDATE_MAX_QUALITY)
      return :known_provably if qualities(quality).empty? && assumptions(quality).empty?

      # A complete SCC result with an explicit progress/acyclicity assumption
      # is not analyzer-proven, but neither is its bound unknown. Preserve the
      # outstanding proof in the underlying recursive_progress bucket while
      # reporting the usable conditional upper bound as known-likely.
      :known_likely
    end

    def bucket(quality)
      return :unknowable if demonstrated_unknowable?(quality)
      return :incomplete unless complete?(quality)
      return :recursive_progress if recursive_quality?(quality)
      return :analyzer_result if qualities(quality).empty? && assumptions(quality).empty?
      return :parametric if qualities(quality).any? { |value| value.start_with?(PARAMETRIC_QUALITY_PREFIX) }
      return :closed_candidate_max if qualities(quality).include?(CLOSED_CANDIDATE_MAX_QUALITY)
      return :modeled_world if qualities(quality).include?(MODELED_QUALITY)
      return :external_latency if qualities(quality).include?(EXTERNAL_LATENCY_QUALITY)

      :exact_or_declared
    end

    def summarize(qualities)
      rows = Array(qualities)
      {
        functions: rows.length,
        categories: ordered_counts(rows, CATEGORY_LABELS, method(:classify)),
        buckets: ordered_counts(rows, BUCKET_LABELS, method(:bucket))
      }
    end

    # Build the machine-readable coverage contract used by CI and corpus
    # measurements. +rows+ deliberately carries scope metadata alongside the
    # quality hash so a caller cannot accidentally mix tests, benchmarks, or
    # generated functions into the production denominator.
    #
    # Raw call normalization is a soundness precondition rather than another
    # coverage percentage: an executable call that never reached normalized
    # facts can make an otherwise "complete" function look constant. Until
    # FactMine can account for every such call, the gate must fail closed.
    def coverage_gate(rows, call_coverage: {}, minimum_percent: DEFAULT_MINIMUM_PERCENT,
                      include_lambdas: true)
      minimum = Float(minimum_percent)
      raise ArgumentError, "minimum_percent must be between 0 and 100" unless minimum.between?(0.0, 100.0)

      scoped = Array(rows).select do |row|
        fetch(row, :source_role).to_s == "production" &&
          (include_lambdas || fetch(row, :kind).to_s != "lambda")
      end
      by_language = scoped.group_by { |row| fetch(row, :language).to_s }
                          .sort.to_h do |language, language_rows|
        [language.empty? ? "unknown" : language, coverage_summary(language_rows)]
      end
      summary = coverage_summary(scoped)
      raw_gaps = fetch(call_coverage, :raw_calls_not_normalized_inside_function).to_i
      failures = []
      failures << "no production functions were measured" if summary[:functions].zero?
      if summary[:mapped_percent] < minimum
        failures << format(
          "production Big-O coverage %.2f%% is below %.2f%%",
          summary[:mapped_percent],
          minimum
        )
      end
      if raw_gaps.positive?
        failures << "#{raw_gaps} executable raw calls were not normalized"
      end

      {
        schema: "espalier.big-o-coverage-gate.v1",
        policy: {
          source_roles: ["production"],
          include_lambdas: include_lambdas,
          minimum_percent: minimum,
          raw_call_normalization: "fail_closed"
        },
        passed: failures.empty?,
        failures: failures,
        coverage: summary,
        by_language: by_language,
        call_soundness: call_soundness(call_coverage)
      }
    end

    def complete?(quality)
      fetch(quality, :big_o_complete) == true
    end

    def demonstrated_unknowable?(quality)
      fetch(quality, :big_o_proof_status).to_s == "demonstrated_unknowable"
    end

    def recursive_quality?(quality)
      !(qualities(quality) & RECURSIVE_QUALITIES).empty?
    end

    def qualities(quality)
      Array(fetch(quality, :big_o_bound_qualities)).map(&:to_s)
    end

    def assumptions(quality)
      Array(fetch(quality, :big_o_assumptions)).map(&:to_s)
    end

    def coverage_summary(rows)
      qualities = Array(rows).map { |row| fetch(row, :quality) || row }
      proof = summarize(qualities)
      mapped = qualities.count { |quality| classify(quality) != :unknown }
      total = qualities.length
      {
        functions: total,
        mapped: mapped,
        incomplete: total - mapped,
        mapped_percent: percentage(mapped, total),
        proof: proof
      }
    end
    private_class_method :coverage_summary

    def call_soundness(coverage)
      eligible = fetch(coverage, :eligible_call_sites).to_i
      accounted = fetch(coverage, :semantically_accounted_call_sites).to_i
      {
        scope: "entire_fact_mine_profile",
        eligible_call_sites: eligible,
        exact_project_targets: fetch(coverage, :exact_project_targets).to_i,
        modeled_without_project_target: fetch(coverage, :modeled_without_project_target).to_i,
        semantically_accounted_call_sites: accounted,
        semantically_accounted_percent: percentage(accounted, eligible),
        unresolved_call_sites: fetch(coverage, :unresolved_call_sites).to_i,
        raw_parser_call_sites: fetch(coverage, :raw_parser_call_sites).to_i,
        raw_calls_not_normalized: fetch(coverage, :raw_calls_not_normalized).to_i,
        raw_calls_not_normalized_inside_function:
          fetch(coverage, :raw_calls_not_normalized_inside_function).to_i,
        normalized_calls_without_raw_span: fetch(coverage, :normalized_calls_without_raw_span).to_i
      }
    end
    private_class_method :call_soundness

    def percentage(numerator, denominator)
      denominator.zero? ? 0.0 : (numerator * 100.0 / denominator).round(2)
    end
    private_class_method :percentage

    def fetch(hash, key)
      return nil unless hash.respond_to?(:key?)
      return hash[key] if hash.key?(key)

      hash[key.to_s]
    end

    def ordered_counts(rows, labels, classifier)
      counts = rows.map { |quality| classifier.call(quality) }.tally
      labels.to_h do |key, label|
        [key, { label: label, count: counts.fetch(key, 0) }]
      end
    end
    private_class_method :ordered_counts, :fetch
  end
end
