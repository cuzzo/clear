# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/espalier"

class ComplexitySummaryTest < Minitest::Test
  def quality(bound_qualities: [], complete: true, space_complete: true, variables: [])
    {
      big_o_complete: complete,
      big_o_space_complete: space_complete,
      big_o_bound_qualities: bound_qualities,
      big_o_variables: variables
    }
  end

  def parameter_domain
    {symbol: "N", domain_id: "param:Owner#fn:items", source_kind: "parameter"}
  end

  def callback_domain
    {symbol: "C", domain_id: "cost:items.map", source_kind: "callback_cost"}
  end

  # A call whose cost was parametric before its callback was substituted leaves
  # that quality behind on the method. What the method publishes is the bound,
  # and the bound may name nothing a caller has to supply: a closure written at
  # the call site is analyzed where it stands, and its cost is already inside
  # the expression. Reading the constituent call's quality instead of the bound
  # withholds a fully resolved bound from every consumer of the summary.
  def test_a_substituted_callback_leaves_a_bound_the_caller_can_use
    resolved = quality(
      bound_qualities: ["upper_bound_parametric_callback_once"],
      variables: [parameter_domain]
    )
    assert Espalier::ComplexitySummary.source_method_proven?(
      {"source_export_eligible" => true, "callback_params" => []},
      resolved,
      []
    )
  end

  # A bound that still names a cost nobody supplied is genuinely parametric,
  # and stays unpublishable unless the declaration names the parameter a caller
  # would discharge it with.
  def test_a_bound_that_still_names_an_unsupplied_cost_is_withheld
    parametric = quality(
      bound_qualities: ["upper_bound_parametric_callback_once"],
      variables: [parameter_domain, callback_domain]
    )
    refute Espalier::ComplexitySummary.source_method_proven?(
      {"source_export_eligible" => true, "callback_params" => []},
      parametric,
      []
    )
    assert Espalier::ComplexitySummary.source_method_proven?(
      {"source_export_eligible" => true, "callback_params" => ["callback"]},
      parametric,
      []
    )
  end

  # Time and space are proven separately and consumed separately. A consumer
  # pricing time needs the time bound; withholding a proven time bound because
  # the space bound is still open publishes nothing about either, and every
  # caller of that declaration loses the one bound that was proven.
  def test_a_proven_time_bound_does_not_wait_on_the_space_bound
    assert Espalier::ComplexitySummary.source_proven?(
      quality(space_complete: false),
      []
    )
    refute Espalier::ComplexitySummary.source_proven?(
      quality(complete: false),
      []
    )
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
      quality(
        bound_qualities: ["upper_bound_parametric_callback_once"],
        variables: [callback_domain]
      ),
      []
    )
    assert Espalier::ComplexitySummary.source_method_proven?(
      {"source_export_eligible" => true, "callback_params" => ["callback"]},
      quality(
        bound_qualities: ["upper_bound_parametric_callback_once"],
        variables: [callback_domain]
      ),
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

  def test_rejects_incomplete_or_manual_model_derived_bounds
    refute Espalier::ComplexitySummary.source_proven?(quality(complete: false), [])

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
