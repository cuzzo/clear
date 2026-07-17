# frozen_string_literal: true

module Espalier
  # Language-neutral proof accounting for function-level Big-O results.
  #
  # This deliberately classifies evidence rather than complexity expressions:
  # emitting O(N) is not progress unless its proof obligations are discharged
  # or explicitly represented by a trusted/modelled contract.
  module BigOProofMetrics
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
