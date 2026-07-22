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
    stability = complete_stability(corpus)
    counterfactual = counterfactual(Evidence::CounterfactualStatus::ProvesRevertedChange, baseline_status: 0, scope: corpus.evidence_scope)
    oracle = oracle_analysis(scope: corpus.evidence_scope)

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
    assert_includes kinds, "PERSISTS_WITHOUT_ORACLE"
    assert_includes kinds, "MUTATION_REDUNDANT"
    assert_includes kinds, "EQUAL_KILL_SET"
    assert_includes kinds, "MUTATION_DOMINATED"
    assert_includes kinds, "COVERED_WEAK_ORACLE"
    assert_includes kinds, "OUT_OF_MUTATION_SCOPE"
    assert_includes kinds, "HIGH_COST_NO_MARGINAL_DETECTION"
    assert_equal report.json, JSON.pretty_generate(report.to_h)
    assert_includes report.markdown, "# TestMiser evidence"
    assert_includes report.markdown, "PERSISTS_WITHOUT_ORACLE"
    sarif = JSON.parse(report.sarif)
    assert_equal "2.1.0", sarif.fetch("version")
    assert_equal "test-miser.evidence.sarif.v1", sarif.fetch("runs").fetch(0).fetch("properties").fetch("format")
    assert sarif.fetch("runs").fetch(0).fetch("results").any?
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
      counterfactual: counterfactual(Evidence::CounterfactualStatus::DoesNotDetectRevertedChange, scope: corpus.evidence_scope),
      counterfactual_test_ids: ["t2"],
      runtimes: {"t1" => 1.0},
      high_cost_ms: 10.0,
    )
    inconclusive = Evidence::ReportBuilder.new(corpus).build(
      contributions: contributions,
      subsumption: subsumption,
      counterfactual: counterfactual(Evidence::CounterfactualStatus::Inconclusive, scope: corpus.evidence_scope),
      counterfactual_test_ids: ["t2"],
    )

    assert_includes does_not_detect.findings.map { |finding| finding.kind }, Evidence::ReviewFindingKind::DoesNotDetectRevertedChange
    refute_includes does_not_detect.findings.map { |finding| finding.kind }, Evidence::ReviewFindingKind::HighCostNoMarginalDetection
    refute inconclusive.vectors.find { |vector| vector.test_id == "t2" }&.detects_reverted_change
  end

  def test_sarif_uses_note_for_positive_findings_and_real_test_locations
    corpus = Evidence::Corpus.new(
      tests: [
        Evidence::TestObservation.new(
          id: "t1", name: "ExampleTest#test_value", covered_mutants: ["m1"], killed_mutants: ["m1"],
          source_file: "test/example_test.rb", source_line: 12,
        ),
      ],
      mutants: [mutant("m1", ["t1"], ["t1"])],
      complete: true,
    )
    contributions = Evidence::ContributionAnalyzer.new(corpus).analyze(new_test_ids: ["t1"])
    subsumption = Evidence::SubsumptionAnalyzer.new(corpus).analyze(contributions: contributions)
    report = Evidence::ReportBuilder.new(corpus).build(contributions: contributions, subsumption: subsumption)
    result = JSON.parse(report.sarif).dig("runs", 0, "results").find { |row| row["ruleId"].end_with?("adds_unique_kills") }

    assert_equal "note", result.fetch("level")
    assert_equal "test/example_test.rb", result.dig("locations", 0, "physicalLocation", "artifactLocation", "uri")
    assert_equal 12, result.dig("locations", 0, "physicalLocation", "region", "startLine")
  end

  def test_cohort_frontier_detection_does_not_contaminate_unrelated_cost_findings
    corpus = Evidence::Corpus.new(
      tests: [
        observation("new", ["m1"], ["m1"]),
        observation("baseline", ["m2"], ["m2"]),
        observation("unrelated", ["m3"], []),
      ],
      mutants: [
        mutant("m1", ["new"], ["new"]),
        mutant("m2", ["baseline"], ["baseline"]),
        mutant("m3", ["unrelated"], []),
      ],
      complete: true,
    )
    contributions = Evidence::ContributionAnalyzer.new(corpus).analyze(
      new_test_ids: ["new"],
      baseline_test_ids: ["baseline"],
    )
    subsumption = Evidence::SubsumptionAnalyzer.new(corpus).analyze(contributions: contributions)
    report = Evidence::ReportBuilder.new(corpus).build(
      contributions: contributions,
      subsumption: subsumption,
      runtimes: {"unrelated" => 2_000.0},
      high_cost_ms: 1_000.0,
    )

    assert_equal ["m1"], report.cohort&.new_detection
    assert_equal ["m1"], report.cohort&.frontier_new_detection
    unrelated = report.vectors.find { |vector| vector.test_id == "unrelated" }
    refute unrelated&.to_h&.key?("cohort_new_detection")
    assert_equal ["unrelated"], report.findings
      .select { |finding| finding.kind == Evidence::ReviewFindingKind::HighCostNoMarginalDetection }
      .map(&:test_id)
  end

  def test_cohort_redundancy_stays_at_cohort_scope_and_does_not_hide_member_cost
    corpus = Evidence::Corpus.new(
      tests: [
        observation("new1", ["m1"], ["m1"]),
        observation("new2", ["m1"], ["m1"]),
        observation("baseline", [], []),
      ],
      mutants: [mutant("m1", ["new1", "new2"], ["new1", "new2"])],
      complete: true,
    )
    contributions = Evidence::ContributionAnalyzer.new(corpus).analyze(
      new_test_ids: %w[new1 new2],
      baseline_test_ids: ["baseline"],
    )
    subsumption = Evidence::SubsumptionAnalyzer.new(corpus).analyze(contributions: contributions)
    report = Evidence::ReportBuilder.new(corpus).build(
      contributions: contributions,
      subsumption: subsumption,
      counterfactual: counterfactual(Evidence::CounterfactualStatus::ProvesRevertedChange, baseline_status: 0, scope: corpus.evidence_scope),
      counterfactual_test_ids: %w[new1 new2],
      runtimes: {"new1" => 2_000.0, "new2" => 2_000.0},
      high_cost_ms: 1_000.0,
    )

    assert_equal %w[new1 new2], report.cohort&.internally_redundant_test_ids
    assert_equal %w[new1 new2], report.cohort&.counterfactual_test_ids
    assert report.findings.any? { |finding| finding.kind == Evidence::ReviewFindingKind::AddsGroupDetection && finding.test_id.nil? }
    assert_equal %w[new1 new2], report.findings
      .select { |finding| finding.kind == Evidence::ReviewFindingKind::HighCostNoMarginalDetection }
      .map(&:test_id).sort
    assert report.findings.any? do |finding|
      finding.kind == Evidence::ReviewFindingKind::ProvesRevertedChange && finding.test_id.nil? &&
        finding.evidence.fetch("scope") == "cohort"
    end
    assert report.vectors.all? { |vector| vector.detects_reverted_change.nil? }
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
      stability = Evidence::StabilityAnalyzer.new(corpus).analyze(
        3.times.map { |trial| Evidence::KillTrial.new(test_id: "t1", mutant_id: "m1", killed: true, trial: trial) },
      )
      report = Evidence::ReportBuilder.new(corpus).build(
        contributions: contributions,
        subsumption: subsumption,
        stability: stability,
        runtimes: {"t1" => 2_000.0},
        high_cost_ms: 1.0,
      )

      assert_equal complete == false ? "incomplete" : "unknown", report.vectors.fetch(0).completeness
      assert_equal 0, report.vectors.fetch(0).unique_kills
      assert_includes report.findings.map { |finding| finding.kind }, Evidence::ReviewFindingKind::UnknownIncompleteAttribution
      assert_includes report.findings.map { |finding| finding.kind }, Evidence::ReviewFindingKind::AddsStableUniqueKills
      refute_includes report.findings.map { |finding| finding.kind }, Evidence::ReviewFindingKind::HighCostNoMarginalDetection
    end
  end

  def test_scoped_gates_allow_independent_evidence_on_incomplete_mutation_corpus
    corpus = Evidence::Corpus.new(
      tests: [observation("t1", ["m1"], ["m1"])],
      mutants: [mutant("m1", ["t1"], ["t1"])],
      complete: false,
      incomplete_reason: "missing attribution",
    )
    contributions = Evidence::ContributionAnalyzer.new(corpus).analyze
    subsumption = Evidence::SubsumptionAnalyzer.new(corpus).analyze(contributions: contributions)
    report = Evidence::ReportBuilder.new(corpus).build(
      contributions: contributions,
      subsumption: subsumption,
      counterfactual: counterfactual(Evidence::CounterfactualStatus::ProvesRevertedChange, baseline_status: 0, scope: corpus.evidence_scope),
      oracle_sensitivity: oracle_analysis(scope: corpus.evidence_scope),
      counterfactual_test_ids: ["t1"],
      runtimes: {"t1" => 2_000.0},
      high_cost_ms: 1.0,
    )

    assert_includes report.findings.map { |finding| finding.kind }, Evidence::ReviewFindingKind::ProvesRevertedChange
    assert_includes report.findings.map { |finding| finding.kind }, Evidence::ReviewFindingKind::StrengthensExistingOracle
    assert_equal true, report.vectors.fetch(0).detects_reverted_change
    assert_in_delta 0.5, report.vectors.fetch(0).oracle_dependent_kill_ratio, 0.001
    assert_equal({"status" => "incomplete", "complete" => false, "reason" => "missing attribution"},
                 contributions.completeness.to_h)
  end

  def test_unverified_oracle_control_is_not_published_as_strengthening_evidence
    corpus = complete_corpus
    contributions = Evidence::ContributionAnalyzer.new(corpus).analyze
    subsumption = Evidence::SubsumptionAnalyzer.new(corpus).analyze(contributions: contributions)
    oracle = oracle_analysis(scope: corpus.evidence_scope, control_verified: false)
    report = Evidence::ReportBuilder.new(corpus).build(
      contributions: contributions, subsumption: subsumption, oracle_sensitivity: oracle,
    )

    refute_includes report.findings.map(&:kind), Evidence::ReviewFindingKind::StrengthensExistingOracle
    assert_nil report.vectors.find { |vector| vector.test_id == "t1" }&.oracle_dependent_kill_ratio
  end

  def test_high_cost_findings_require_comparable_runtime_measurements
    corpus = complete_corpus
    contributions = Evidence::ContributionAnalyzer.new(corpus).analyze
    subsumption = Evidence::SubsumptionAnalyzer.new(corpus).analyze(contributions: contributions)
    report = Evidence::ReportBuilder.new(corpus).build(
      contributions: contributions,
      subsumption: subsumption,
      runtimes: {"t4" => 2_000.0},
      high_cost_ms: 1.0,
      cost_comparable: false,
    )

    refute_includes report.findings.map { |finding| finding.kind }, Evidence::ReviewFindingKind::HighCostNoMarginalDetection
    assert_equal 2_000.0, report.vectors.find { |vector| vector.test_id == "t4" }&.runtime_ms
  end

  def test_report_rejects_artifacts_from_a_different_revision
    corpus = complete_corpus
    current_scope = corpus.evidence_scope(revision: "rev-current")
    stale_scope = corpus.evidence_scope(revision: "rev-stale")
    contributions = Evidence::ContributionAnalyzer.new(corpus, scope: current_scope).analyze
    stale_subsumption = Evidence::SubsumptionAnalyzer.new(corpus, scope: stale_scope).analyze

    assert_raises(Evidence::EvidenceScopeMismatch) do
      Evidence::ReportBuilder.new(corpus, scope: current_scope).build(
        contributions: contributions,
        subsumption: stale_subsumption,
      )
    end

    assert_raises(Evidence::EvidenceScopeMismatch) do
      Evidence::ReportBuilder.new(corpus).build(
        contributions: Evidence::ContributionAnalyzer.new(corpus).analyze,
        subsumption: Evidence::SubsumptionAnalyzer.new(corpus).analyze,
        counterfactual: counterfactual(Evidence::CounterfactualStatus::Inconclusive),
      )
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

  def counterfactual(status, baseline_status: nil, scope: nil)
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
      scope: scope,
      reason: "fixture result",
    )
  end

  def complete_stability(corpus)
    outcomes = {
      ["t1", "m1"] => true, ["t1", "m2"] => true, ["t1", "m3"] => false,
      ["t2", "m1"] => true, ["t2", "m2"] => false, ["t2", "m3"] => false,
      ["t3", "m1"] => false, ["t3", "m2"] => false, ["t3", "m3"] => false,
      ["t4", "m1"] => false, ["t4", "m2"] => false, ["t4", "m3"] => false,
      ["t5", "m1"] => true, ["t5", "m2"] => false, ["t5", "m3"] => false,
    }
    trials = outcomes.flat_map do |(test_id, mutant_id), killed|
      3.times.map do |trial|
        Evidence::KillTrial.new(test_id: test_id, mutant_id: mutant_id, killed: killed, trial: trial)
      end
    end
    Evidence::StabilityAnalyzer.new(corpus).analyze(trials)
  end

  def oracle_analysis(scope: nil, control_verified: true)
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
      execution_results: [{
        "disabled_rewrite" => {"oracle_id" => "o1", "applied" => true},
        "control_rewrite" => {"applied" => true},
        "control_outcome" => control_verified ? "ASSERTION_FAILURE" : "PASSED",
        "control_verified" => control_verified,
      }],
      scope: scope,
    )
  end

  def observation(id, covered, killed)
    Evidence::TestObservation.new(id: id, name: id, covered_mutants: covered, killed_mutants: killed)
  end

  def mutant(id, covered, killed)
    Evidence::MutantObservation.new(id: id, covered_by: covered, killed_by: killed)
  end
end
