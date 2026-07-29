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

    # Apply an exact implementation-to-consumer bridge.  A source body may
    # deliberately implement more than one public declaration (for example a
    # class method and an equivalent module function), so a bridge value is
    # one-or-many rather than a lossy one-to-one map.  Keeping this operation
    # here makes bridges equally available to every producer language; a
    # language-owned bridge generator need only prove its identities.
    #
    # Rows without a bridge target are intentionally omitted.  Publishing a
    # source identity into a consumer summary would evade the cross-indexer
    # identity proof that the bridge is meant to establish.
    def bridge_symbol_rows(rows, symbol_map: nil, prefix_from: nil, prefix_to: nil)
      rows.flat_map do |symbol, row|
        targets = if symbol_map
                    Array(symbol_map[symbol])
                  else
                    [relocate_symbol(symbol, from: prefix_from, to: prefix_to)]
                  end
        targets.compact.map { |target| [target, row] }
      end
    end

    def source_method_proven?(method, quality, complexity_facts)
      return false unless method["source_export_eligible"] == true
      return false unless source_proven?(quality, complexity_facts)

      qualities = Array(quality[:big_o_bound_qualities]).map(&:to_s)
      return false if qualities.any? { |bound| bound.include?("parametric_callback") } &&
        Array(method["callback_params"]).empty?

      true
    end

    def consumer_closed_candidate_set?(call)
      call["consumer_closed_candidate_set"] == true
    end

    def source_proven?(quality, _complexity_facts)
      return false unless quality
      return false unless quality[:big_o_complete] == true
      return false unless quality[:big_o_space_complete] == true

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
