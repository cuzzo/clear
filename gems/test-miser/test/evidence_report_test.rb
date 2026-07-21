# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/test_miser/evidence/report"

class EvidenceReportTest < Minitest::Test
  Evidence = TestMiser::Evidence

  def test_builds_vectors_and_composable_findings_without_a_scalar_score
    corpus = complete_corpus
    contributions = Evidence::ContributionAnalyzer.new(corpus).analyze(
      new_test_ids: %w[t2 t5],
      baseline_test_ids: ["t3"],
    )
    subsumption = Evidence::SubsumptionAnalyzer.new(corpus).analyze(contributions: contributions)
    stability = Evidence::StabilityAnalyzer.new(corpus).analyze(
      3.times.map { |trial| Evidence::KillTrial.new(test_id: "t1", mutant_id: "m2", killed: true, trial: trial) },
    )
    counterfactual = counterfactual(Evidence::CounterfactualStatus::ProvesRevertedChange, baseline_status: 0)
    oracle = oracle_analysis

    report = Evidence::ReportBuilder.new(corpus).build(
      contributions: contributions,
      subsumption: subsumption,
      stability: stability,
      counterfactual: counterfactual,
      oracle_sensitivity: oracle,
      counterfactual_test_ids: ["t1"],
      runtimes: {"t2" => 2_000.0, "t3" => 2_000.0},
      high_cost_ms: 1_000.0,
    )
    kinds = report.findings.map { |finding| finding.kind.serialize }
    t1 = report.vectors.find { |vector| vector.test_id == "t1" }

    assert_equal "test-quality-evidence/v1", report.to_h.fetch("schema")
    assert_equal 1, t1&.unique_kills
    assert_equal 1, t1&.stable_unique_kills
    assert_equal 1, t1&.frontier_unique_kills
    assert_equal true, t1&.detects_reverted_change
    assert_in_delta 0.5, t1&.oracle_dependent_kill_ratio, 0.001
    assert_includes kinds, "ADDS_UNIQUE_KILLS"
    assert_includes kinds, "ADDS_STABLE_UNIQUE_KILLS"
    assert_includes kinds, "ADDS_SUBSUMING_MUTANT_DETECTION"
    assert_includes kinds, "ADDS_GROUP_DETECTION"
    assert_includes kinds, "PROVES_REVERTED_CHANGE"
    assert_includes kinds, "STRENGTHENS_EXISTING_ORACLE"
    assert_includes kinds, "INCIDENTAL_MUTANT_KILLS"
    assert_includes kinds, "EQUAL_KILL_SET"
    assert_includes kinds, "MUTATION_DOMINATED"
    assert_includes kinds, "COVERED_WEAK_ORACLE"
    assert_includes kinds, "OUT_OF_MUTATION_SCOPE"
    assert_includes kinds, "HIGH_COST_NO_MARGINAL_DETECTION"
    assert_equal report.json, JSON.pretty_generate(report.to_h)
    assert_equal ["t2", "t3"], report.findings.select { |finding| finding.kind == Evidence::ReviewFindingKind::HighCostNoMarginalDetection }.map(&:test_id).sort
    assert_equal({"test_id" => "t2", "runtime_ms" => 2_000.0}, Evidence::CostObservation.new(test_id: "t2", runtime_ms: 2_000.0).to_h)
  end

  def test_does_not_detect_and_inconclusive_counterfactuals_do_not_overstate_evidence
    corpus = complete_corpus
    contributions = Evidence::ContributionAnalyzer.new(corpus).analyze
    subsumption = Evidence::SubsumptionAnalyzer.new(corpus).analyze(contributions: contributions)
    does_not_detect = Evidence::ReportBuilder.new(corpus).build(
      contributions: contributions,
      subsumption: subsumption,
      counterfactual: counterfactual(Evidence::CounterfactualStatus::DoesNotDetectRevertedChange),
      counterfactual_test_ids: ["t2"],
      runtimes: {"t1" => 1.0},
      high_cost_ms: 10.0,
    )
    inconclusive = Evidence::ReportBuilder.new(corpus).build(
      contributions: contributions,
      subsumption: subsumption,
      counterfactual: counterfactual(Evidence::CounterfactualStatus::Inconclusive),
      counterfactual_test_ids: ["t2"],
    )

    assert_includes does_not_detect.findings.map { |finding| finding.kind }, Evidence::ReviewFindingKind::DoesNotDetectRevertedChange
    refute_includes does_not_detect.findings.map { |finding| finding.kind }, Evidence::ReviewFindingKind::HighCostNoMarginalDetection
    refute inconclusive.vectors.find { |vector| vector.test_id == "t2" }&.detects_reverted_change
  end

  def test_incomplete_and_unknown_corpus_completeness_is_preserved_in_vectors
    [false, nil].each do |complete|
      corpus = Evidence::Corpus.new(
        tests: [observation("t1", %w[m1], %w[m1])],
        mutants: [mutant("m1", %w[t1], %w[t1])],
        complete: complete,
      )
      contributions = Evidence::ContributionAnalyzer.new(corpus).analyze
      subsumption = Evidence::SubsumptionAnalyzer.new(corpus).analyze(contributions: contributions)
      report = Evidence::ReportBuilder.new(corpus).build(contributions: contributions, subsumption: subsumption)

      assert_equal complete == false ? "incomplete" : "unknown", report.vectors.fetch(0).completeness
      assert_equal 0, report.vectors.fetch(0).unique_kills
    end
  end

  private

  def complete_corpus
    Evidence::Corpus.new(
      tests: [
        observation("t1", %w[m1 m2], %w[m1 m2]),
        observation("t2", %w[m1], %w[m1]),
        observation("t3", %w[m3], []),
        observation("t4", [], []),
        observation("t5", %w[m1], %w[m1]),
      ],
      mutants: [
        mutant("m1", %w[t1 t2 t5], %w[t1 t2 t5]),
        mutant("m2", %w[t1], %w[t1]),
        mutant("m3", %w[t3], []),
      ],
      complete: true,
    )
  end

  def counterfactual(status, baseline_status: nil)
    command = Evidence::CommandResult.new(status: 0, stdout: "", stderr: "")
    baseline = baseline_status.nil? ? nil : Evidence::CommandResult.new(status: baseline_status, stdout: "", stderr: "")
    Evidence::CounterfactualResult.new(
      status: status,
      head: command,
      worktree: command,
      reverse_patch: command,
      build: command,
      new_tests: status == Evidence::CounterfactualStatus::DoesNotDetectRevertedChange ? command : Evidence::CommandResult.new(status: 1, stdout: "", stderr: ""),
      baseline_tests: baseline,
      baseline_detects_reversal: baseline.nil? ? nil : !baseline.success?,
      reason: "fixture result",
    )
  end

  def oracle_analysis
    fact = Evidence::OracleFact.new(
      oracle_id: "o1",
      test_id: "t1",
      oracle_kind: Evidence::OracleKind::Equality,
      oracle_span: Evidence::SourceSpan.new(start_line: 1, start_column: 1, end_line: 1, end_column: 2),
      framework: "fixture",
      confidence: 1.0,
    )
    Evidence::OracleSensitivityAnalyzer.analyze(
      facts: Evidence::OracleFacts.new(facts: [fact]),
      original_kills: {"t1" => %w[m1 m2]},
      disabled_trials: [
        Evidence::OracleTrial.new(test_id: "t1", oracle_id: "o1", mutant_id: "m1", killed: false, executed: true),
        Evidence::OracleTrial.new(test_id: "t1", oracle_id: "o1", mutant_id: "m2", killed: true, executed: true),
      ],
      rewrites: [Evidence::OracleRewrite.new(
        oracle_id: "o1", mutation: Evidence::OracleMutationKind::DisableOracle,
        recognized: true, applied: true, reason: "fixture",
      )],
    )
  end

  def observation(id, covered, killed)
    Evidence::TestObservation.new(id: id, name: id, covered_mutants: covered, killed_mutants: killed)
  end

  def mutant(id, covered, killed)
    Evidence::MutantObservation.new(id: id, covered_by: covered, killed_by: killed)
  end
end
