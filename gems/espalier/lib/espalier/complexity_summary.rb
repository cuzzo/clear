# frozen_string_literal: true

module Espalier
  # Proof boundary for reusable complexity summaries. A source profile can be
  # complete because a reviewed/manual external model closed one of its calls;
  # exporting that result would merely copy the registry into a generated file.
  # Reusable summaries therefore admit only bounds proven from analyzed bodies,
  # exact analyzed targets, CFG/DFG structure, and compiler-provided candidate
  # sets.
  module ComplexitySummary
    FORBIDDEN_QUALITY_FRAGMENTS = %w[
      declared_receiver
      external_latency
      modeled_world
      unknown_cardinality
    ].freeze

    module_function

    def relocate_symbol(symbol, from: nil, to: nil)
      return symbol if from.nil? && to.nil?
      raise ArgumentError, "symbol relocation requires both source and destination prefixes" if from.nil? || to.nil?
      raise ArgumentError, "symbol does not start with the declared source prefix: #{symbol}" unless symbol.start_with?(from)

      "#{to}#{symbol.delete_prefix(from)}"
    end

    def source_method_proven?(method, quality, complexity_facts)
      return false unless method["source_export_eligible"] == true
      return false unless source_proven?(quality, complexity_facts)

      return false if undischarged_cost?(quality) && Array(method["callback_params"]).empty?

      true
    end

    # Whether the bound this method publishes still names a cost its caller did
    # not supply. A call priced parametrically before its callback was
    # substituted leaves that quality behind on the method, but a closure
    # written at the call site is analyzed where it stands and its cost is
    # already inside the expression. What a consumer can use is decided by the
    # bound, so the bound's own domains decide it - not the history of the
    # calls that built it.
    def undischarged_cost?(quality)
      Array(quality[:big_o_variables]).any? do |domain|
        (domain["source_kind"] || domain[:source_kind]).to_s.end_with?("_cost")
      end
    end

    def consumer_closed_candidate_set?(call)
      call["consumer_closed_candidate_set"] == true
    end

    def source_proven?(quality, _complexity_facts)
      return false unless quality
      return false unless quality[:big_o_complete] == true

      qualities = Array(quality[:big_o_bound_qualities]).map(&:to_s)
      return false if qualities.any? do |bound_quality|
        FORBIDDEN_QUALITY_FRAGMENTS.any? { |fragment| bound_quality.include?(fragment) }
      end

      # Complexity facts are captured before SCIP resolves canonical calls, so
      # their adapter-level evidence_gap fields can be stale. The aggregate
      # completeness result above is computed after canonical call enrichment.
      # Parser-normalization loss is guarded independently by FactMine marking
      # the overlapping method source_export_eligible=false.
      true
    end
  end
end
