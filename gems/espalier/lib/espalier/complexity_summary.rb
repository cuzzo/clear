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

    def source_proven?(quality, complexity_facts)
      return false unless quality
      return false unless quality[:big_o_complete] == true
      return false unless quality[:big_o_space_complete] == true

      qualities = Array(quality[:big_o_bound_qualities]).map(&:to_s)
      return false if qualities.any? do |bound_quality|
        FORBIDDEN_QUALITY_FRAGMENTS.any? { |fragment| bound_quality.include?(fragment) }
      end

      Array(complexity_facts).none? do |fact|
        Array(fact["call_contexts"]).any? do |context|
          !context["evidence_gap"].to_s.empty?
        end
      end
    end
  end
end
