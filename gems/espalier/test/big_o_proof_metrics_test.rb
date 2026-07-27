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

  def test_coverage_gate_uses_only_production_and_reports_proof_tiers
    rows = [
      row("go", quality, kind: "top"),
      row("go", quality(qualities: ["upper_bound_parametric_callback_once"]), kind: "lambda"),
      row("rust", quality(complete: false), kind: "instance"),
      row("java", quality, role: "test", kind: "instance")
    ]

    report = Metrics.coverage_gate(
      rows,
      minimum_percent: 60,
      call_coverage: {
        "eligible_call_sites" => 10,
        "exact_project_targets" => 4,
        "modeled_without_project_target" => 5,
        "semantically_accounted_call_sites" => 9,
        "unresolved_call_sites" => 1
      }
    )

    assert report[:passed]
    assert_equal 3, report.dig(:coverage, :functions)
    assert_equal 2, report.dig(:coverage, :mapped)
    assert_equal 66.67, report.dig(:coverage, :mapped_percent)
    assert_equal 1, report.dig(:coverage, :proof, :buckets, :parametric, :count)
    assert_equal 2, report.dig(:by_language, "go", :functions)
    refute report[:by_language].key?("java")
    assert_equal 90.0, report.dig(:call_soundness, :semantically_accounted_percent)
  end

  def test_coverage_gate_fails_closed_for_raw_executable_calls
    report = Metrics.coverage_gate(
      [row("c", quality)],
      call_coverage: { raw_calls_not_normalized_inside_function: 1 }
    )

    refute report[:passed]
    assert_includes report[:failures], "1 executable raw calls were not normalized"
  end

  def test_coverage_gate_can_exclude_lambdas_by_explicit_policy
    rows = [
      row("rust", quality, kind: "top"),
      row("rust", quality(complete: false), kind: "lambda")
    ]

    report = Metrics.coverage_gate(rows, include_lambdas: false)

    assert report[:passed]
    assert_equal 1, report.dig(:coverage, :functions)
    refute report.dig(:policy, :include_lambdas)
  end

  def test_coverage_gate_rejects_invalid_minimum
    error = assert_raises(ArgumentError) { Metrics.coverage_gate([], minimum_percent: 101) }
    assert_match(/between 0 and 100/, error.message)
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

  def row(language, quality, role: "production", kind: "top")
    { language: language, source_role: role, kind: kind, quality: quality }
  end
end
