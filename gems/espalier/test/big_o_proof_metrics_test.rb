# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/espalier/big_o_proof_metrics"

class BigOProofMetricsTest < Minitest::Test
  Metrics = Espalier::BigOProofMetrics

  def test_requested_categories_and_buckets_are_mutually_exclusive
    rows = [
      quality,
      quality(qualities: ["upper_bound_exact_target"]),
      quality(qualities: ["upper_bound_modeled_world"], assumptions: ["closed implementation set"]),
      quality(qualities: ["upper_bound_closed_candidate_max"], assumptions: ["closed implementation set"]),
      quality(qualities: ["upper_bound_parametric_callback_once"]),
      quality(qualities: ["upper_bound_acyclic_project_scc"], assumptions: ["acyclic input"]),
      quality(qualities: ["upper_bound_external_latency_excluded"], assumptions: ["computational cost"]),
      quality(complete: false),
      quality(complete: false, proof_status: "demonstrated_unknowable")
    ]

    summary = Metrics.summarize(rows)

    assert_equal 9, summary[:functions]
    assert_equal [1, 5, 1, 2], summary[:categories].values.map { |row| row[:count] }
    assert_equal [1, 1, 1, 1, 1, 1, 1, 1, 1], summary[:buckets].values.map { |row| row[:count] }
    assert_equal 9, summary[:categories].values.sum { |row| row[:count] }
    assert_equal 9, summary[:buckets].values.sum { |row| row[:count] }
  end

  def test_incomplete_result_outranks_conditional_bound_expression
    row = quality(
      complete: false,
      qualities: ["upper_bound_acyclic_project_scc", "upper_bound_modeled_world"],
      assumptions: ["acyclic input"]
    )

    assert_equal :unknown, Metrics.classify(row)
    assert_equal :incomplete, Metrics.bucket(row)
  end

  def test_complete_scc_bound_is_likely_while_progress_proof_remains_visible
    row = quality(
      qualities: ["upper_bound_acyclic_project_scc"],
      assumptions: ["finite acyclic input"]
    )

    assert_equal :known_likely, Metrics.classify(row)
    assert_equal :recursive_progress, Metrics.bucket(row)
  end

  def test_external_latency_scope_outranks_exact_target_in_underlying_bucket
    row = quality(
      qualities: ["upper_bound_exact_target", "upper_bound_external_latency_excluded"],
      assumptions: ["computational cost only"]
    )

    assert_equal :known_likely, Metrics.classify(row)
    assert_equal :external_latency, Metrics.bucket(row)
  end

  def test_string_keyed_quality_is_supported
    row = {
      "big_o_complete" => true,
      "big_o_bound_qualities" => [],
      "big_o_assumptions" => []
    }

    assert_equal :known_provably, Metrics.classify(row)
    assert_equal :analyzer_result, Metrics.bucket(row)
  end

  private

  def quality(complete: true, qualities: [], assumptions: [], proof_status: nil)
    {
      big_o_complete: complete,
      big_o_bound_qualities: qualities,
      big_o_assumptions: assumptions,
      big_o_proof_status: proof_status
    }
  end
end
