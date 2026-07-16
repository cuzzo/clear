# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/espalier/big_o_gap_impact"

class BigOGapImpactTest < Minitest::Test
  def test_propagates_direct_root_to_all_incomplete_callers
    results = {
      "root" => result(unknowns: ["callback.call"], gaps: ["unmodeled_typed_operation"]),
      "caller" => result,
      "top" => result,
      "complete" => result(complete: true)
    }
    calls = [
      { source: "caller", target: "root" },
      { source: "top", target: "caller" },
      { source: "complete", target: "root" },
      { source: "root", target: nil, semantic_symbol: "compiler dependency symbol" }
    ]

    report = Espalier::BigOGapImpact.analyze(results: results, calls: calls)

    assert_equal 3, report[:incomplete_functions]
    assert_equal 1, report[:direct_root_functions]
    assert_equal 2, report[:propagated_only_functions]
    assert_equal 1, report[:unique_unknown_operations]
    assert_equal 0, report[:untraced_incomplete_functions]
    assert_equal 3, report[:roots].first[:affected_incomplete_functions]
    assert_includes report[:roots].first[:categories], "external_symbol_cost_missing"
    assert_includes report[:roots].first[:categories], "normalized_cost_fact_missing"
  end

  def test_reports_untraced_incomplete_function_without_inventing_a_root
    report = Espalier::BigOGapImpact.analyze(
      results: { "gap" => result },
      calls: []
    )

    assert_equal 0, report[:direct_root_functions]
    assert_equal 1, report[:untraced_incomplete_functions]
  end

  private

  def result(complete: false, unknowns: [], gaps: [])
    {
      complete: complete,
      unknowns: unknowns,
      unknown_operation_evidence: unknowns.to_h { |name| [name, {}] },
      evidence_gaps: gaps,
      path: "sample",
      line: 1,
      owner: "Owner",
      name: "method"
    }
  end
end
