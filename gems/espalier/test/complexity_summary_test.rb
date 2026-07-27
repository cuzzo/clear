# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/espalier"

class ComplexitySummaryTest < Minitest::Test
  def quality(bound_qualities: [], complete: true, space_complete: true)
    {
      big_o_complete: complete,
      big_o_space_complete: space_complete,
      big_o_bound_qualities: bound_qualities
    }
  end

  def test_accepts_analyzed_structure_and_exact_analyzed_targets
    assert Espalier::ComplexitySummary.source_proven?(quality, [])
    assert Espalier::ComplexitySummary.source_proven?(
      quality(bound_qualities: ["upper_bound_exact_target"]),
      []
    )
  end

  def test_rejects_incomplete_or_manual_model_derived_bounds
    refute Espalier::ComplexitySummary.source_proven?(quality(complete: false), [])
    refute Espalier::ComplexitySummary.source_proven?(quality(space_complete: false), [])

    %w[
      upper_bound_declared_receiver
      upper_bound_compiler_declared_receiver
      upper_bound_external_latency_excluded
      upper_bound_modeled_world
      upper_bound_unknown_cardinality_relation
    ].each do |bound_quality|
      refute Espalier::ComplexitySummary.source_proven?(
        quality(bound_qualities: [bound_quality]),
        []
      )
    end
  end

  def test_rejects_unclosed_call_evidence_even_when_aggregate_claims_complete
    facts = [
      {
        "call_contexts" => [
          {"message" => "PrintDefaults", "evidence_gap" => "unresolved_receiver_type"}
        ]
      }
    ]

    refute Espalier::ComplexitySummary.source_proven?(quality, facts)
  end
end
