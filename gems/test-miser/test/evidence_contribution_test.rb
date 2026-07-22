# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/test_miser/evidence/contribution"

class EvidenceContributionTest < Minitest::Test
  Evidence = TestMiser::Evidence

  def test_marginal_contribution_dominance_and_scope_findings
    corpus = Evidence::Corpus.new(
      tests: [
        observation("t1", covered: %w[m1], killed: %w[m1]),
        observation("t2", covered: %w[m1 m2], killed: %w[m1 m2]),
        observation("t3", covered: %w[m3], killed: []),
        observation("t4", covered: [], killed: []),
        observation("t5", covered: %w[m1], killed: %w[m1]),
      ],
      mutants: [
        mutant("m1", covered: %w[t1 t2 t5], killed: %w[t1 t2 t5]),
        mutant("m2", covered: %w[t2], killed: %w[t2]),
        mutant("m3", covered: %w[t3], killed: []),
      ],
      complete: true,
    )

    analysis = Evidence::ContributionAnalyzer.new(corpus).analyze(
      new_test_ids: %w[t1 t5],
      baseline_test_ids: %w[t3],
    )

    t1 = analysis.test_contributions.find { |test| test.test_id == "t1" }
    t2 = analysis.test_contributions.find { |test| test.test_id == "t2" }
    t3 = analysis.test_contributions.find { |test| test.test_id == "t3" }
    t4 = analysis.test_contributions.find { |test| test.test_id == "t4" }

    assert_empty t1.unique_kills
    assert_includes t1.findings, Evidence::FindingKind::MutationRedundant
    assert_includes t1.dominated_by, "t2"
    assert_equal %w[m2], t2.unique_kills
    assert_includes t2.findings, Evidence::FindingKind::AddsUniqueKills
    assert_empty t2.dominated_by
    assert_includes t3.findings, Evidence::FindingKind::CoveredWeakOracle
    assert_includes t4.findings, Evidence::FindingKind::OutOfMutationScope

    refute_nil analysis.cohort
    assert_equal %w[m1], analysis.cohort&.new_detection
    assert_equal [Evidence::FindingKind::AddsGroupDetection], analysis.cohort&.findings
    assert_equal "test-quality-evidence/contribution-v1", analysis.to_h.fetch("schema")
  end

  def test_incomplete_corpus_with_false_and_unknown_completeness_withholds_strong_findings
    incomplete = Evidence::Corpus.new(
      tests: [observation("t1", covered: %w[m1], killed: %w[m1])],
      mutants: [mutant("m1", covered: %w[t1], killed: %w[t1])],
      complete: false,
      incomplete_reason: "partial shard",
    )
    unknown = Evidence::Corpus.new(
      tests: [observation("t1", covered: %w[m1], killed: %w[m1])],
      mutants: [mutant("m1", covered: %w[t1], killed: %w[t1])],
      complete: nil,
    )

    [incomplete, unknown].each do |corpus|
      analysis = Evidence::ContributionAnalyzer.new(corpus).analyze(
        new_test_ids: ["t1"],
        baseline_test_ids: [],
      )
      contribution = analysis.test_contributions.fetch(0)

      assert_empty contribution.unique_kills
      assert_empty contribution.dominated_by
      assert_equal [Evidence::FindingKind::UnknownIncompleteAttribution], contribution.findings
      assert_equal [Evidence::FindingKind::UnknownIncompleteAttribution], analysis.cohort&.findings
      refute_nil analysis.unknown_reason
    end
  end

  def test_out_of_mutation_scope_test_is_not_dominated_by_a_covered_test
    corpus = Evidence::Corpus.new(
      tests: [
        observation("out_of_scope", covered: [], killed: []),
        observation("covered", covered: ["m1"], killed: []),
      ],
      mutants: [mutant("m1", covered: ["covered"], killed: [])],
      complete: true,
    )

    analysis = Evidence::ContributionAnalyzer.new(corpus).analyze
    out_of_scope = analysis.test_contributions.find { |test| test.test_id == "out_of_scope" }

    assert_equal [Evidence::FindingKind::OutOfMutationScope], out_of_scope&.findings
    assert_empty out_of_scope&.dominated_by
  end

  def test_cohort_rejects_unknown_and_overlapping_test_ids
    corpus = Evidence::Corpus.new(
      tests: [observation("new", covered: [], killed: []), observation("baseline", covered: [], killed: [])],
      mutants: [],
      complete: true,
    )
    analyzer = Evidence::ContributionAnalyzer.new(corpus)

    assert_raises(Evidence::InvalidCohort) do
      analyzer.analyze(new_test_ids: ["missing"], baseline_test_ids: [])
    end
    assert_raises(Evidence::InvalidCohort) do
      analyzer.analyze(new_test_ids: ["new"], baseline_test_ids: ["new"])
    end
  end

  def test_report_adapter_normalizes_sets_and_referenced_tests
    test = Struct.new(:id, :name).new("t1", "one")
    mutant = Struct.new(:id, :covered_by, :killed_by).new("m1", ["t1"], Set.new(["t1"]))
    report = Struct.new(:tests, :mutants, :corpus_complete).new([test], [mutant], nil)

    corpus = Evidence::Corpus.from_report(report)

    assert_equal ["m1"], corpus.tests.fetch(0).covered_mutants
    assert_equal ["m1"], corpus.tests.fetch(0).killed_mutants
    assert_equal ["t1"], corpus.mutants.fetch(0).covered_by
    assert_equal ["t1"], corpus.mutants.fetch(0).killed_by
    refute corpus.complete?
    assert_equal "corpus completeness is unknown", corpus.incomplete_reason
    assert_equal({
      "test_id" => "t1",
      "test_name" => "one",
      "covered_mutants" => ["m1"],
      "killed_mutants" => ["m1"],
    }, corpus.tests.fetch(0).to_h)
  end

  private

  def observation(id, covered:, killed:)
    Evidence::TestObservation.new(
      id: id,
      name: id,
      covered_mutants: covered,
      killed_mutants: killed,
    )
  end

  def mutant(id, covered:, killed:)
    Evidence::MutantObservation.new(id: id, covered_by: covered, killed_by: killed)
  end
end
