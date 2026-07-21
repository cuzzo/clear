# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/test_miser/evidence/contribution"
require_relative "../lib/test_miser/evidence/subsumption"
require_relative "../lib/test_miser/evidence/stability"

class EvidenceSubsumptionStabilityTest < Minitest::Test
  Evidence = TestMiser::Evidence

  def test_dynamic_subsumption_equivalence_and_frontier_ranking
    corpus = Evidence::Corpus.new(
      tests: [
        observation("t1", %w[m1 m2 m3 m4], %w[m1 m2 m3 m4]),
        observation("t2", %w[m2 m4], %w[m2 m4]),
        observation("t3", %w[m4], %w[m4]),
      ],
      mutants: [
        mutant("m1", %w[t1], %w[t1]),
        mutant("m2", %w[t1 t2], %w[t1 t2]),
        mutant("m3", %w[t1], %w[t1]),
        mutant("m4", %w[t1 t2 t3], %w[t1 t2 t3]),
        mutant("m5", %w[t1], []),
      ],
      complete: true,
    )
    contributions = Evidence::ContributionAnalyzer.new(corpus).analyze(
      new_test_ids: ["t1"],
      baseline_test_ids: ["t2"],
    )

    analysis = Evidence::SubsumptionAnalyzer.new(corpus).analyze(contributions: contributions)

    assert_equal [["m1", "m3"]], analysis.equivalent_groups.map(&:mutant_ids)
    assert_includes analysis.relations.map { |relation| [relation.subsuming_mutant_id, relation.subsumed_mutant_id] },
      ["m1", "m2"]
    assert_includes analysis.relations.map { |relation| [relation.subsuming_mutant_id, relation.subsumed_mutant_id] },
      ["m2", "m4"]
    assert_equal ["m1"], analysis.frontier_mutants

    t1 = analysis.rankings.find { |ranking| ranking.test_id == "t1" }
    t2 = analysis.rankings.find { |ranking| ranking.test_id == "t2" }
    assert_equal ["m1"], t1&.frontier_unique_kills
    assert_equal ["m1"], t1&.cohort_new_frontier_detection
    assert_empty t2&.frontier_unique_kills
    assert_empty t2&.cohort_new_frontier_detection
    assert_empty analysis.rankings.find { |ranking| ranking.test_id == "t3" }&.cohort_new_frontier_detection
    assert_equal "test-quality-evidence/subsumption-v1", analysis.to_h.fetch("schema")
    assert_equal ["m1", "t1"], [analysis.to_h.fetch("summary").fetch("frontier_mutants").first,
                                    analysis.to_h.fetch("equivalent_mutants").first.fetch("killer_tests").first]
  end

  def test_incomplete_subsumption_is_unknown_and_can_omit_rankings
    corpus = Evidence::Corpus.new(
      tests: [observation("t1", %w[m1], %w[m1])],
      mutants: [mutant("m1", %w[t1], %w[t1])],
      complete: false,
      incomplete_reason: "missing shard",
    )
    contributions = Evidence::ContributionAnalyzer.new(corpus).analyze

    with_contributions = Evidence::SubsumptionAnalyzer.new(corpus).analyze(contributions: contributions)
    without_contributions = Evidence::SubsumptionAnalyzer.new(corpus).analyze

    assert_empty with_contributions.equivalent_groups
    assert_empty with_contributions.relations
    assert_empty with_contributions.frontier_mutants
    assert_equal [[]], with_contributions.rankings.map(&:frontier_unique_kills)
    assert_equal [], without_contributions.rankings
    assert_equal "missing shard", with_contributions.unknown_reason
  end

  def test_stability_requires_three_consistent_observations_and_retains_trials
    corpus = Evidence::Corpus.new(
      tests: [observation("t1", %w[m1 m2 m3], %w[m1 m2 m3]), observation("t2", %w[m1 m3], %w[m1 m3])],
      mutants: [mutant("m1", %w[t1 t2], %w[t1 t2]), mutant("m2", %w[t1], %w[t1]), mutant("m3", %w[t1 t2], %w[t1 t2])],
      complete: true,
    )
    outcomes = {
      ["t1", "m1"] => true,
      ["t2", "m1"] => true,
      ["t1", "m2"] => true,
      ["t2", "m2"] => false,
      ["t1", "m3"] => [true, false, true],
      ["t2", "m3"] => [true, false, true],
    }
    trials = outcomes.flat_map do |(test_id, mutant_id), outcome|
      3.times.map do |trial|
        killed = outcome.is_a?(Array) ? outcome.fetch(trial) : outcome
        Evidence::KillTrial.new(test_id: test_id, mutant_id: mutant_id, killed: killed, trial: trial)
      end
    end

    analysis = Evidence::StabilityAnalyzer.new(corpus).analyze(trials)
    t1 = analysis.attributions.find { |attribution| attribution.test_id == "t1" }
    t2 = analysis.attributions.find { |attribution| attribution.test_id == "t2" }

    assert_equal %w[m1 m2], t1&.stable_kills
    assert_equal ["m3"], t1&.unstable_kills
    assert_equal %w[m1], t2&.stable_kills
    assert_equal ["m3"], t2&.unstable_kills
    assert analysis.matrix_complete
    assert_equal ["m2"], analysis.stable_unique_kills.find { |row| row.test_id == "t1" }&.stable_unique_kills
    assert_empty analysis.stable_unique_kills.find { |row| row.test_id == "t2" }&.stable_unique_kills
    assert_equal 3, analysis.observed_trials
    assert_equal [0, 1, 2], analysis.trial_ids
    assert_equal [true, true, true], t1&.observations&.fetch("m1")
    assert_equal "test-quality-evidence/stability-v1", analysis.to_h.fetch("schema")
    assert_equal 1, Evidence::StabilityAnalyzer.new(corpus, threshold: 1).analyze([]).threshold
    assert_raises(ArgumentError) { Evidence::StabilityAnalyzer.new(corpus, threshold: 0) }

    duplicate = Evidence::StabilityAnalyzer.new(corpus).analyze(
      trials + [Evidence::KillTrial.new(test_id: "t1", mutant_id: "m2", killed: true, trial: 0)],
    )
    refute duplicate.matrix_complete
    assert_empty duplicate.stable_unique_kills.find { |row| row.test_id == "t1" }&.stable_unique_kills
    assert_equal "stability matrix contains duplicate trial observations", duplicate.unknown_reason
    assert_equal 3, duplicate.observed_trials

    partial_corpus = Evidence::Corpus.new(
      tests: corpus.tests,
      mutants: corpus.mutants,
      complete: false,
      incomplete_reason: "partial corpus",
    )
    partial = Evidence::StabilityAnalyzer.new(partial_corpus).analyze(trials)
    refute partial.matrix_complete
    assert_empty partial.stable_unique_kills.flat_map(&:stable_unique_kills)
    assert_equal "partial corpus", partial.unknown_reason

    short = Evidence::StabilityAnalyzer.new(corpus).analyze(trials, trial_ids: [0, 1])
    assert_equal "stability matrix has fewer trial IDs than its consistency threshold", short.unknown_reason
    missing = Evidence::StabilityAnalyzer.new(corpus).analyze(trials[1..], mutant_ids: ["m1"])
    assert_equal "stability matrix is missing test × mutant × trial observations", missing.unknown_reason
    unknown = Evidence::StabilityAnalyzer.new(corpus).analyze(trials, test_ids: ["missing"])
    assert_equal "stability matrix names an unknown test or mutant", unknown.unknown_reason
    empty = Evidence::StabilityAnalyzer.new(corpus).analyze(trials, test_ids: [])
    assert_equal "stability matrix has no selected tests or mutants", empty.unknown_reason
  end

  def test_scheduler_selects_weak_redundant_and_dominated_tests
    corpus = Evidence::Corpus.new(
      tests: [
        observation("duplicate", %w[m1], %w[m1]),
        observation("stronger", %w[m1 m2], %w[m1 m2]),
        observation("weak", %w[m3], []),
        observation("out", [], []),
      ],
      mutants: [mutant("m1", %w[duplicate stronger], %w[duplicate stronger]), mutant("m2", %w[stronger], %w[stronger]), mutant("m3", %w[weak], [])],
      complete: true,
    )

    candidates = Evidence::RerunScheduler.schedule(Evidence::ContributionAnalyzer.new(corpus).analyze)

    assert_equal %w[duplicate weak], candidates.map(&:test_id)
    assert_equal ["m1"], candidates.fetch(0).mutant_ids
    assert_includes candidates.fetch(0).reason, "MUTATION_REDUNDANT"
    assert_equal({"test_id" => "weak", "mutant_ids" => ["m3"], "reason" => "COVERED_WEAK_ORACLE"}, candidates.fetch(1).to_h)
  end

  private

  def observation(id, covered, killed)
    Evidence::TestObservation.new(id: id, name: id, covered_mutants: covered, killed_mutants: killed)
  end

  def mutant(id, covered, killed)
    Evidence::MutantObservation.new(id: id, covered_by: covered, killed_by: killed)
  end
end
