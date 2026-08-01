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

  def test_source_method_requires_an_executable_normalization_complete_body
    assert Espalier::ComplexitySummary.source_method_proven?(
      {"source_export_eligible" => true},
      quality,
      []
    )
    refute Espalier::ComplexitySummary.source_method_proven?({}, quality, [])
    refute Espalier::ComplexitySummary.source_method_proven?(
      {"source_export_eligible" => false},
      quality,
      []
    )
    refute Espalier::ComplexitySummary.source_method_proven?(
      {"source_export_eligible" => true, "callback_params" => []},
      quality(bound_qualities: ["upper_bound_parametric_callback_once"]),
      []
    )
    assert Espalier::ComplexitySummary.source_method_proven?(
      {"source_export_eligible" => true, "callback_params" => ["callback"]},
      quality(bound_qualities: ["upper_bound_parametric_callback_once"]),
      []
    )
  end

  def test_symbol_relocation_is_explicit_and_fail_closed
    assert_equal(
      "semanticdb maven jdk 21 java/lang/String#length().",
      Espalier::ComplexitySummary.relocate_symbol(
        "semanticdb maven temporary/java.base 21 java/lang/String#length().",
        from: "semanticdb maven temporary/java.base 21 ",
        to: "semanticdb maven jdk 21 "
      )
    )
    assert_raises(ArgumentError) do
      Espalier::ComplexitySummary.relocate_symbol(
        "semanticdb maven other 21 java/lang/String#length().",
        from: "semanticdb maven temporary/java.base 21 ",
        to: "semanticdb maven jdk 21 "
      )
    end
    assert_raises(ArgumentError) do
      Espalier::ComplexitySummary.relocate_symbol("symbol", from: "symbol")
    end
  end

  def test_exact_symbol_bridge_preserves_one_to_many_declaration_identities
    row = {"time" => "O(1)", "space" => "O(1)"}
    bridged = Espalier::ComplexitySummary.bridge_symbol_rows(
      [["implementation Math.exp", row], ["implementation absent", row]],
      symbol_map: {
        "implementation Math.exp" => ["runtime Math#exp", "runtime Math.exp"]
      }
    )

    assert_equal(
      [["runtime Math#exp", row], ["runtime Math.exp", row]],
      bridged
    )
  end

  def test_symbol_bridge_and_prefix_relocation_share_one_generic_transform
    row = {"time" => "O(N)", "space" => "O(1)"}
    assert_equal(
      [["consumer pkg fn", row]],
      Espalier::ComplexitySummary.bridge_symbol_rows(
        [["producer pkg fn", row]],
        prefix_from: "producer ",
        prefix_to: "consumer "
      )
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

  def test_uses_post_scip_completeness_instead_of_stale_adapter_call_gaps
    facts = [
      {
        "call_contexts" => [
          {"message" => "PrintDefaults", "evidence_gap" => "unresolved_receiver_type"}
        ]
      }
    ]

    assert Espalier::ComplexitySummary.source_proven?(quality, facts)
    refute Espalier::ComplexitySummary.source_method_proven?(
      {"source_export_eligible" => false},
      quality,
      facts
    )
  end

  def test_candidate_export_requires_explicit_downstream_closure
    refute Espalier::ComplexitySummary.consumer_closed_candidate_set?({
      "candidate_targets" => ["implementation"]
    })
    assert Espalier::ComplexitySummary.consumer_closed_candidate_set?({
      "candidate_targets" => ["implementation"],
      "consumer_closed_candidate_set" => true
    })
  end
end
