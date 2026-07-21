# typed: strict
# frozen_string_literal: true

require "json"
require "sorbet-runtime"
require_relative "contribution"
require_relative "subsumption"
require_relative "stability"
require_relative "counterfactual"
require_relative "oracle"

module TestMiser
  module Evidence
    class ReviewFindingKind < T::Enum
      enums do
        AddsUniqueKills = new("ADDS_UNIQUE_KILLS")
        AddsStableUniqueKills = new("ADDS_STABLE_UNIQUE_KILLS")
        AddsGroupDetection = new("ADDS_GROUP_DETECTION")
        AddsSubsumingMutantDetection = new("ADDS_SUBSUMING_MUTANT_DETECTION")
        ProvesRevertedChange = new("PROVES_REVERTED_CHANGE")
        DoesNotDetectRevertedChange = new("DOES_NOT_DETECT_REVERTED_CHANGE")
        DuplicatesChangeDetection = new("DUPLICATES_CHANGE_DETECTION")
        StrengthensExistingOracle = new("STRENGTHENS_EXISTING_ORACLE")
        IncidentalMutantKills = new("INCIDENTAL_MUTANT_KILLS")
        MutationDominated = new("MUTATION_DOMINATED")
        EqualKillSet = new("EQUAL_KILL_SET")
        CoveredWeakOracle = new("COVERED_WEAK_ORACLE")
        OutOfMutationScope = new("OUT_OF_MUTATION_SCOPE")
        HighCostNoMarginalDetection = new("HIGH_COST_NO_MARGINAL_DETECTION")
        Unknown = new("UNKNOWN")
      end
    end

    class CostObservation < T::Struct
      extend T::Sig

      const :test_id, String
      const :runtime_ms, Float

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {"test_id" => test_id, "runtime_ms" => runtime_ms}
      end
    end

    class EvidenceVector < T::Struct
      extend T::Sig

      const :test_id, String
      const :unique_kills, Integer
      const :stable_unique_kills, Integer
      const :frontier_unique_kills, Integer
      const :cohort_new_detection, Integer
      const :detects_reverted_change, T.nilable(T::Boolean)
      const :oracle_dependent_kill_ratio, T.nilable(Float)
      const :runtime_ms, T.nilable(Float)
      const :completeness, String

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "test_id" => test_id,
          "unique_kills" => unique_kills,
          "stable_unique_kills" => stable_unique_kills,
          "frontier_unique_kills" => frontier_unique_kills,
          "cohort_new_detection" => cohort_new_detection,
          "detects_reverted_change" => detects_reverted_change,
          "oracle_dependent_kill_ratio" => oracle_dependent_kill_ratio,
          "runtime_ms" => runtime_ms,
          "completeness" => completeness,
        }
      end
    end

    class ReviewFinding < T::Struct
      extend T::Sig

      const :kind, ReviewFindingKind
      const :test_id, T.nilable(String)
      const :reason, String
      const :evidence, T::Hash[String, T.untyped]

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "kind" => kind.serialize,
          "test_id" => test_id,
          "reason" => reason,
          "evidence" => evidence,
        }.compact
      end
    end

    class EvidenceReport < T::Struct
      extend T::Sig

      const :contribution, ContributionAnalysis
      const :subsumption, SubsumptionAnalysis
      const :stability, T.nilable(StabilityAnalysis)
      const :counterfactual, T.nilable(CounterfactualResult)
      const :oracle_sensitivity, T.nilable(OracleSensitivityAnalysis)
      const :vectors, T::Array[EvidenceVector]
      const :findings, T::Array[ReviewFinding]

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "schema" => "test-quality-evidence/v1",
          "contribution" => contribution.to_h,
          "subsumption" => subsumption.to_h,
          "stability" => stability&.to_h,
          "counterfactual" => counterfactual&.to_h,
          "oracle_sensitivity" => oracle_sensitivity&.to_h,
          "vectors" => vectors.map(&:to_h),
          "findings" => findings.map(&:to_h),
        }.compact
      end

      sig { returns(String) }
      def json
        JSON.pretty_generate(to_h)
      end
    end

    class ReportBuilder
      extend T::Sig

      sig { params(corpus: Corpus).void }
      def initialize(corpus)
        @corpus = corpus
      end

      sig do
        params(
          contributions: ContributionAnalysis,
          subsumption: SubsumptionAnalysis,
          stability: T.nilable(StabilityAnalysis),
          counterfactual: T.nilable(CounterfactualResult),
          oracle_sensitivity: T.nilable(OracleSensitivityAnalysis),
          counterfactual_test_ids: T::Array[String],
          runtimes: T::Hash[String, Float],
          high_cost_ms: Float,
        ).returns(EvidenceReport)
      end
      def build(
        contributions:, subsumption:, stability: nil, counterfactual: nil,
        oracle_sensitivity: nil, counterfactual_test_ids: [], runtimes: {}, high_cost_ms: 1_000.0
      )
        vectors = build_vectors(
          contributions: contributions,
          subsumption: subsumption,
          stability: stability,
          counterfactual: counterfactual,
          oracle_sensitivity: oracle_sensitivity,
          counterfactual_test_ids: counterfactual_test_ids,
          runtimes: runtimes,
        )
        findings = build_findings(
          contributions: contributions,
          subsumption: subsumption,
          stability: stability,
          counterfactual: counterfactual,
          oracle_sensitivity: oracle_sensitivity,
          counterfactual_test_ids: counterfactual_test_ids,
          vectors: vectors,
          high_cost_ms: high_cost_ms,
        )
        EvidenceReport.new(
          contribution: contributions,
          subsumption: subsumption,
          stability: stability,
          counterfactual: counterfactual,
          oracle_sensitivity: oracle_sensitivity,
          vectors: vectors,
          findings: findings,
        )
      end

      private

      sig do
        params(
          contributions: ContributionAnalysis,
          subsumption: SubsumptionAnalysis,
          stability: T.nilable(StabilityAnalysis),
          counterfactual: T.nilable(CounterfactualResult),
          oracle_sensitivity: T.nilable(OracleSensitivityAnalysis),
          counterfactual_test_ids: T::Array[String],
          runtimes: T::Hash[String, Float],
        ).returns(T::Array[EvidenceVector])
      end
      def build_vectors(contributions:, subsumption:, stability:, counterfactual:, oracle_sensitivity:, counterfactual_test_ids:, runtimes:)
        frontier = subsumption.rankings.to_h { |ranking| [ranking.test_id, ranking] }
        stable = stability&.stable_unique_kills&.to_h { |row| [row.test_id, row.stable_unique_kills] } || {}
        oracle = oracle_sensitivity&.results&.group_by(&:test_id) || {}
        contributions.test_contributions.map do |contribution|
          oracle_rows = oracle.fetch(contribution.test_id, [])
          original = oracle_rows.sum { |row| row.original_kills.length }
          dependent = oracle_rows.sum { |row| row.oracle_dependent_kills.length }
          ranking = frontier[contribution.test_id]
          EvidenceVector.new(
            test_id: contribution.test_id,
            unique_kills: contribution.unique_kills.length,
            stable_unique_kills: stable.fetch(contribution.test_id, []).length,
            frontier_unique_kills: ranking&.frontier_unique_kills&.length || 0,
            cohort_new_detection: ranking&.cohort_new_frontier_detection&.length || 0,
            detects_reverted_change: counterfactual_value(counterfactual, counterfactual_test_ids, contribution.test_id),
            oracle_dependent_kill_ratio: original.zero? ? nil : dependent.to_f / original,
            runtime_ms: runtimes[contribution.test_id],
            completeness: completeness_label(contributions.corpus_complete),
          )
        end.freeze
      end

      sig do
        params(
          contributions: ContributionAnalysis,
          subsumption: SubsumptionAnalysis,
          stability: T.nilable(StabilityAnalysis),
          counterfactual: T.nilable(CounterfactualResult),
          oracle_sensitivity: T.nilable(OracleSensitivityAnalysis),
          counterfactual_test_ids: T::Array[String],
          vectors: T::Array[EvidenceVector],
          high_cost_ms: Float,
        ).returns(T::Array[ReviewFinding])
      end
      def build_findings(contributions:, subsumption:, stability:, counterfactual:, oracle_sensitivity:, counterfactual_test_ids:, vectors:, high_cost_ms:)
        findings = contributions.test_contributions.flat_map do |contribution|
          contribution_findings(contribution)
        end
        findings.concat(cohort_findings(contributions))
        findings.concat(equal_kill_findings(contributions))
        findings.concat(subsumption_findings(subsumption))
        findings.concat(stability_findings(stability))
        findings.concat(oracle_findings(oracle_sensitivity))
        findings.concat(counterfactual_findings(counterfactual, counterfactual_test_ids))
        findings.concat(cost_findings(vectors, high_cost_ms))
        findings.sort_by { |finding| [finding.test_id.to_s, finding.kind.serialize] }.freeze
      end

      sig { params(contribution: TestContribution).returns(T::Array[ReviewFinding]) }
      def contribution_findings(contribution)
        evidence = {
          "unique_kills" => contribution.unique_kills,
          "covered_mutants" => contribution.covered_mutants,
          "killed_mutants" => contribution.killed_mutants,
        }
        contribution.findings.filter_map do |finding|
          kind = case finding
                 when FindingKind::AddsUniqueKills then ReviewFindingKind::AddsUniqueKills
                 when FindingKind::MutationDominated then ReviewFindingKind::MutationDominated
                 when FindingKind::CoveredWeakOracle then ReviewFindingKind::CoveredWeakOracle
                 when FindingKind::OutOfMutationScope then ReviewFindingKind::OutOfMutationScope
                 else nil
                 end
          next if kind.nil?

          ReviewFinding.new(kind: kind, test_id: contribution.test_id, reason: finding.serialize, evidence: evidence)
        end
      end

      sig { params(contributions: ContributionAnalysis).returns(T::Array[ReviewFinding]) }
      def equal_kill_findings(contributions)
        return [] unless contributions.corpus_complete == true

        contributions.test_contributions
          .reject { |contribution| contribution.killed_mutants.empty? }
          .group_by(&:killed_mutants)
          .values
          .select { |group| group.length > 1 }
          .flat_map do |group|
            peers = group.map(&:test_id).sort.freeze
            group.map do |contribution|
              ReviewFinding.new(
                kind: ReviewFindingKind::EqualKillSet,
                test_id: contribution.test_id,
                reason: "tests have identical non-empty mutant kill sets",
                evidence: {"peer_tests" => peers, "killed_mutants" => contribution.killed_mutants},
              )
            end
          end
      end

      sig { params(contributions: ContributionAnalysis).returns(T::Array[ReviewFinding]) }
      def cohort_findings(contributions)
        cohort = contributions.cohort
        return [] if cohort.nil?

        cohort.findings.filter_map do |finding|
          next unless finding == FindingKind::AddsGroupDetection

          ReviewFinding.new(
            kind: ReviewFindingKind::AddsGroupDetection,
            test_id: nil,
            reason: "the selected cohort detects mutants not killed by the baseline",
            evidence: {
              "test_ids" => cohort.test_ids,
              "baseline_test_ids" => cohort.baseline_test_ids,
              "new_detection" => cohort.new_detection,
            },
          )
        end
      end

      sig { params(subsumption: SubsumptionAnalysis).returns(T::Array[ReviewFinding]) }
      def subsumption_findings(subsumption)
        subsumption.rankings.filter_map do |ranking|
          next if ranking.frontier_unique_kills.empty?

          ReviewFinding.new(
            kind: ReviewFindingKind::AddsSubsumingMutantDetection,
            test_id: ranking.test_id,
            reason: "test uniquely detects mutants on the dynamic subsumption frontier",
            evidence: {"frontier_unique_kills" => ranking.frontier_unique_kills},
          )
        end
      end

      sig { params(stability: T.nilable(StabilityAnalysis)).returns(T::Array[ReviewFinding]) }
      def stability_findings(stability)
        return [] if stability.nil?

        stability.stable_unique_kills.filter_map do |row|
          next if row.stable_unique_kills.empty?

          ReviewFinding.new(
            kind: ReviewFindingKind::AddsStableUniqueKills,
            test_id: row.test_id,
            reason: "three or more consistent trials identify unique mutant kills",
            evidence: {"stable_unique_kills" => row.stable_unique_kills, "threshold" => stability.threshold},
          )
        end
      end

      sig { params(oracle: T.nilable(OracleSensitivityAnalysis)).returns(T::Array[ReviewFinding]) }
      def oracle_findings(oracle)
        return [] if oracle.nil?

        oracle.results.flat_map do |result|
          rows = []
          unless result.oracle_dependent_kills.empty?
            rows << ReviewFinding.new(
              kind: ReviewFindingKind::StrengthensExistingOracle,
              test_id: result.test_id,
              reason: "mutant kills disappear when this oracle is disabled",
              evidence: {"oracle_id" => result.oracle_id, "oracle_dependent_kills" => result.oracle_dependent_kills},
            )
          end
          unless result.incidental_kills.empty?
            rows << ReviewFinding.new(
              kind: ReviewFindingKind::IncidentalMutantKills,
              test_id: result.test_id,
              reason: "mutant kills persist when this oracle is disabled",
              evidence: {"oracle_id" => result.oracle_id, "incidental_kills" => result.incidental_kills},
            )
          end
          rows
        end
      end

      sig do
        params(counterfactual: T.nilable(CounterfactualResult), test_ids: T::Array[String]).returns(T::Array[ReviewFinding])
      end
      def counterfactual_findings(counterfactual, test_ids)
        return [] if counterfactual.nil? || test_ids.empty?
        return [] if counterfactual.status == CounterfactualStatus::Inconclusive

        kind = if counterfactual.status == CounterfactualStatus::ProvesRevertedChange
                 counterfactual.baseline_detects_reversal ? ReviewFindingKind::DuplicatesChangeDetection : ReviewFindingKind::ProvesRevertedChange
               else
                 ReviewFindingKind::DoesNotDetectRevertedChange
               end
        test_ids.map do |test_id|
          ReviewFinding.new(kind: kind, test_id: test_id, reason: counterfactual.reason, evidence: counterfactual.to_h)
        end
      end

      sig { params(vectors: T::Array[EvidenceVector], threshold: Float).returns(T::Array[ReviewFinding]) }
      def cost_findings(vectors, threshold)
        vectors.filter_map do |vector|
          next if vector.runtime_ms.nil? || T.must(vector.runtime_ms) < threshold
          next unless vector.unique_kills.zero? && vector.stable_unique_kills.zero? && vector.cohort_new_detection.zero?

          ReviewFinding.new(
            kind: ReviewFindingKind::HighCostNoMarginalDetection,
            test_id: vector.test_id,
            reason: "runtime is high without observed marginal mutation detection",
            evidence: vector.to_h,
          )
        end
      end

      sig { params(counterfactual: T.nilable(CounterfactualResult), test_ids: T::Array[String], test_id: String).returns(T.nilable(T::Boolean)) }
      def counterfactual_value(counterfactual, test_ids, test_id)
        return nil unless counterfactual && test_ids.include?(test_id)
        return nil if counterfactual.status == CounterfactualStatus::Inconclusive

        counterfactual.status == CounterfactualStatus::ProvesRevertedChange
      end

      sig { params(complete: T.nilable(T::Boolean)).returns(String) }
      def completeness_label(complete)
        return "complete" if complete == true
        return "incomplete" if complete == false

        "unknown"
      end
    end
  end
end
