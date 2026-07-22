# typed: strict
# frozen_string_literal: true

require "json"
require "sorbet-runtime"
require_relative "contribution"
require_relative "completeness"
require_relative "subsumption"
require_relative "stability"
require_relative "counterfactual"
require_relative "oracle"

module TestMiser
  module Evidence
    class EvidenceGate < T::Struct
      extend T::Sig

      const :completeness, EvidenceCompleteness
      const :cost_comparable, T::Boolean

      sig { params(contributions: ContributionAnalysis, cost_comparable: T::Boolean).returns(EvidenceGate) }
      def self.for(contributions, cost_comparable: true)
        new(completeness: contributions.completeness, cost_comparable: cost_comparable)
      end

      sig { returns(T::Boolean) }
      def corpus_complete?
        completeness.complete?
      end

      sig { params(finding: FindingKind).returns(T::Boolean) }
      def allows_contribution_finding?(finding)
        corpus_complete? || finding == FindingKind::UnknownIncompleteAttribution
      end

      sig { params(stability: T.nilable(StabilityAnalysis)).returns(T::Boolean) }
      def allows_stability?(stability)
        stability&.matrix_complete == true
      end

      sig { params(result: OracleSensitivity).returns(T::Boolean) }
      def allows_oracle?(result)
        result.complete && result.control_verified
      end

      sig { params(counterfactual: T.nilable(CounterfactualResult)).returns(T::Boolean) }
      def allows_counterfactual?(counterfactual)
        !counterfactual.nil? && counterfactual.status != CounterfactualStatus::Inconclusive
      end

      sig { params(subsumption: SubsumptionAnalysis).returns(T::Boolean) }
      def allows_subsumption?(subsumption)
        corpus_complete? && subsumption.subsumption_complete
      end

      sig { returns(T::Boolean) }
      def allows_cost?
        corpus_complete? && cost_comparable
      end
    end

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
        PersistsWithoutOracle = new("PERSISTS_WITHOUT_ORACLE")
        MutationRedundant = new("MUTATION_REDUNDANT")
        MutationDominated = new("MUTATION_DOMINATED")
        EqualKillSet = new("EQUAL_KILL_SET")
        CoveredWeakOracle = new("COVERED_WEAK_ORACLE")
        OutOfMutationScope = new("OUT_OF_MUTATION_SCOPE")
        HighCostNoMarginalDetection = new("HIGH_COST_NO_MARGINAL_DETECTION")
        Unknown = new("UNKNOWN")
        UnknownIncompleteAttribution = new("UNKNOWN_INCOMPLETE_ATTRIBUTION")
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
          "detects_reverted_change" => detects_reverted_change,
          "oracle_dependent_kill_ratio" => oracle_dependent_kill_ratio,
          "runtime_ms" => runtime_ms,
          "completeness" => completeness,
        }
      end
    end

    class CohortEvidenceVector < T::Struct
      extend T::Sig

      const :test_ids, T::Array[String]
      const :baseline_test_ids, T::Array[String]
      const :new_detection, T::Array[String]
      const :frontier_new_detection, T::Array[String]
      const :internally_redundant_test_ids, T::Array[String]
      const :counterfactual_test_ids, T::Array[String]

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "test_ids" => test_ids,
          "baseline_test_ids" => baseline_test_ids,
          "new_detection" => new_detection,
          "frontier_new_detection" => frontier_new_detection,
          "internally_redundant_test_ids" => internally_redundant_test_ids,
          "counterfactual_test_ids" => counterfactual_test_ids,
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
      const :cohort, T.nilable(CohortEvidenceVector)
      const :scope, EvidenceScope
      const :vectors, T::Array[EvidenceVector]
      const :findings, T::Array[ReviewFinding]
      const :test_locations, T::Hash[String, T::Hash[String, T.untyped]], default: {}

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "schema" => "test-quality-evidence/v1",
          "contribution" => contribution.to_h,
          "subsumption" => subsumption.to_h,
          "stability" => stability&.to_h,
          "counterfactual" => counterfactual&.to_h,
          "oracle_sensitivity" => oracle_sensitivity&.to_h,
          "cohort" => cohort&.to_h,
          "scope" => scope.to_h,
          "vectors" => vectors.map(&:to_h),
          "findings" => findings.map(&:to_h),
          "test_locations" => test_locations,
        }.compact
      end

      sig { returns(String) }
      def json
        JSON.pretty_generate(to_h)
      end

      sig { returns(String) }
      def markdown
        lines = [
          "# TestMiser evidence",
          "",
          "Scope: `#{scope.fingerprint}` (#{scope.revision})",
          "",
          "| Finding | Test | Reason |",
          "| --- | --- | --- |",
        ]
        findings.each do |finding|
          lines << "| `#{finding.kind.serialize}` | `#{finding.test_id || 'cohort'}` | #{finding.reason.gsub('|', '\\|')} |"
        end
        lines << "" if findings.empty?
        lines << (findings.empty? ? "No evidence findings." : "#{findings.length} evidence finding(s).")
        lines.join("\n")
      end

      sig { returns(String) }
      def sarif
        rules = findings.map(&:kind).uniq.map do |kind|
          {"id" => "test-miser.evidence.#{kind.serialize.downcase}", "shortDescription" => {"text" => kind.serialize}}
        end
        results = findings.map do |finding|
          result = {
            "ruleId" => "test-miser.evidence.#{finding.kind.serialize.downcase}",
            "level" => sarif_level(finding.kind),
            "message" => {"text" => finding.reason},
            "properties" => {"testId" => finding.test_id, "evidence" => finding.evidence}.compact,
          }
          test_id = finding.test_id
          location = test_id.nil? ? nil : test_locations[test_id]
          if location && location["uri"]
            result["locations"] = [{
              "physicalLocation" => {
                "artifactLocation" => {"uri" => location["uri"]},
                "region" => {"startLine" => location.fetch("line", 1)},
              },
            }]
          end
          result
        end
        JSON.pretty_generate(
          "$schema" => "https://json.schemastore.org/sarif-2.1.0.json",
          "version" => "2.1.0",
          "runs" => [{
            "tool" => {"driver" => {"name" => "test-miser", "rules" => rules}},
            "properties" => {"format" => "test-miser.evidence.sarif.v1", "scope" => scope.to_h},
            "results" => results,
          }],
        )
      end

      sig { params(kind: ReviewFindingKind).returns(String) }
      def sarif_level(kind)
        case kind
        when ReviewFindingKind::AddsUniqueKills,
             ReviewFindingKind::AddsStableUniqueKills,
             ReviewFindingKind::AddsGroupDetection,
             ReviewFindingKind::AddsSubsumingMutantDetection,
             ReviewFindingKind::ProvesRevertedChange,
             ReviewFindingKind::StrengthensExistingOracle
          "note"
        when ReviewFindingKind::Unknown, ReviewFindingKind::UnknownIncompleteAttribution
          "note"
        else
          "warning"
        end
      end
    end

    class ReportBuilder
      extend T::Sig

      sig { params(corpus: Corpus, scope: T.nilable(EvidenceScope), revision: String, repository: T.nilable(String)).void }
      def initialize(corpus, scope: nil, revision: "unknown", repository: nil)
        @corpus = corpus
        @scope = T.let(scope || corpus.evidence_scope(revision: revision, repository: repository), EvidenceScope)
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
          cost_comparable: T::Boolean,
        ).returns(EvidenceReport)
      end
      def build(
        contributions:, subsumption:, stability: nil, counterfactual: nil,
        oracle_sensitivity: nil, counterfactual_test_ids: [], runtimes: {}, high_cost_ms: 1_000.0, cost_comparable: true
      )
        validate_scopes!(
          contributions: contributions,
          subsumption: subsumption,
          stability: stability,
          counterfactual: counterfactual,
          oracle_sensitivity: oracle_sensitivity,
        )
        gate = EvidenceGate.for(contributions, cost_comparable: cost_comparable)
        cohort = build_cohort_vector(
          contributions: contributions,
          subsumption: subsumption,
          counterfactual_test_ids: counterfactual_test_ids,
        )
        vectors = build_vectors(
          contributions: contributions,
          subsumption: subsumption,
          stability: stability,
          counterfactual: counterfactual,
          oracle_sensitivity: oracle_sensitivity,
          counterfactual_test_ids: counterfactual_test_ids,
          runtimes: runtimes,
          cohort: cohort,
          gate: gate,
        )
        findings = build_findings(
          contributions: contributions,
          subsumption: subsumption,
          stability: stability,
          counterfactual: counterfactual,
          oracle_sensitivity: oracle_sensitivity,
          counterfactual_test_ids: counterfactual_test_ids,
          cohort: cohort,
          vectors: vectors,
          high_cost_ms: high_cost_ms,
          gate: gate,
        )
        EvidenceReport.new(
          contribution: contributions,
          subsumption: subsumption,
          stability: stability,
          counterfactual: counterfactual,
          oracle_sensitivity: oracle_sensitivity,
          cohort: cohort,
          vectors: vectors,
          findings: findings,
          scope: @scope,
          test_locations: @corpus.tests.filter_map do |test|
            next if test.source_file.nil?

            [test.id, {"uri" => test.source_file, "line" => test.source_line || 1}]
          end.to_h,
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
          cohort: T.nilable(CohortEvidenceVector),
          gate: EvidenceGate,
        ).returns(T::Array[EvidenceVector])
      end
      def build_vectors(contributions:, subsumption:, stability:, counterfactual:, oracle_sensitivity:, counterfactual_test_ids:, runtimes:, cohort:, gate:)
        frontier = subsumption.rankings.to_h { |ranking| [ranking.test_id, ranking] }
        stable = stability&.stable_unique_kills&.to_h { |row| [row.test_id, row.stable_unique_kills] } || {}
        oracle = oracle_sensitivity&.results&.group_by(&:test_id) || {}
        contributions.test_contributions.map do |contribution|
          oracle_rows = oracle.fetch(contribution.test_id, [])
          original = oracle_rows.sum { |row| row.original_kills.length }
          dependent = oracle_rows.sum { |row| row.oracle_dependent_kills.length }
          oracle_complete = !oracle_rows.empty? && oracle_rows.all? { |row| gate.allows_oracle?(row) }
          ranking = frontier[contribution.test_id]
          EvidenceVector.new(
            test_id: contribution.test_id,
            unique_kills: contribution.unique_kills.length,
            stable_unique_kills: stable.fetch(contribution.test_id, []).length,
            frontier_unique_kills: ranking&.frontier_unique_kills&.length || 0,
            detects_reverted_change: gate.allows_counterfactual?(counterfactual) ? counterfactual_value(counterfactual, counterfactual_test_ids, contribution.test_id, cohort) : nil,
            oracle_dependent_kill_ratio: oracle_complete && !original.zero? ? dependent.to_f / original : nil,
            runtime_ms: runtimes[contribution.test_id],
            completeness: contributions.completeness.label,
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
          cohort: T.nilable(CohortEvidenceVector),
          vectors: T::Array[EvidenceVector],
          high_cost_ms: Float,
          gate: EvidenceGate,
        ).returns(T::Array[ReviewFinding])
      end
      def build_findings(contributions:, subsumption:, stability:, counterfactual:, oracle_sensitivity:, counterfactual_test_ids:, cohort:, vectors:, high_cost_ms:, gate:)
        findings = contributions.test_contributions.flat_map do |contribution|
          contribution_findings(contribution, gate)
        end
        findings.concat(cohort_findings(contributions, cohort, gate))
        findings.concat(equal_kill_findings(contributions, gate))
        findings.concat(subsumption_findings(subsumption, gate))
        findings.concat(stability_findings(stability, gate))
        findings.concat(oracle_findings(oracle_sensitivity, gate))
        findings.concat(counterfactual_findings(counterfactual, counterfactual_test_ids, cohort, gate))
        findings.concat(cost_findings(vectors, high_cost_ms, gate))
        findings.sort_by { |finding| [finding.test_id.to_s, finding.kind.serialize] }.freeze
      end

      sig { params(contribution: TestContribution, gate: EvidenceGate).returns(T::Array[ReviewFinding]) }
      def contribution_findings(contribution, gate)
        evidence = {
          "unique_kills" => contribution.unique_kills,
          "covered_mutants" => contribution.covered_mutants,
          "killed_mutants" => contribution.killed_mutants,
        }
        contribution.findings.filter_map do |finding|
          next unless gate.allows_contribution_finding?(finding)

          kind = case finding
                 when FindingKind::AddsUniqueKills then ReviewFindingKind::AddsUniqueKills
                 when FindingKind::MutationRedundant then ReviewFindingKind::MutationRedundant
                 when FindingKind::MutationDominated then ReviewFindingKind::MutationDominated
                 when FindingKind::CoveredWeakOracle then ReviewFindingKind::CoveredWeakOracle
                 when FindingKind::OutOfMutationScope then ReviewFindingKind::OutOfMutationScope
                 when FindingKind::UnknownIncompleteAttribution then ReviewFindingKind::UnknownIncompleteAttribution
                 else nil
                 end
          next if kind.nil?

          ReviewFinding.new(kind: kind, test_id: contribution.test_id, reason: finding.serialize, evidence: evidence)
        end
      end

      sig { params(contributions: ContributionAnalysis, gate: EvidenceGate).returns(T::Array[ReviewFinding]) }
      def equal_kill_findings(contributions, gate)
        return [] unless gate.corpus_complete?

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

      sig { params(contributions: ContributionAnalysis, cohort_vector: T.nilable(CohortEvidenceVector), gate: EvidenceGate).returns(T::Array[ReviewFinding]) }
      def cohort_findings(contributions, cohort_vector, gate)
        cohort = contributions.cohort
        return [] if cohort.nil? || cohort_vector.nil? || !gate.corpus_complete?

        cohort.findings.filter_map do |finding|
          next unless finding == FindingKind::AddsGroupDetection

          ReviewFinding.new(
            kind: ReviewFindingKind::AddsGroupDetection,
            test_id: nil,
            reason: "the selected cohort detects mutants not killed by the baseline; cohort members may be internally redundant",
            evidence: cohort_vector.to_h,
          )
        end
      end

      sig { params(subsumption: SubsumptionAnalysis, gate: EvidenceGate).returns(T::Array[ReviewFinding]) }
      def subsumption_findings(subsumption, gate)
        return [] unless gate.allows_subsumption?(subsumption)

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

      sig do
        params(stability: T.nilable(StabilityAnalysis), gate: EvidenceGate).returns(T::Array[ReviewFinding])
      end
      def stability_findings(stability, gate)
        return [] unless gate.allows_stability?(stability)

        stable_analysis = T.must(stability)
        stable_analysis.stable_unique_kills.filter_map do |row|
          next if row.stable_unique_kills.empty?

          ReviewFinding.new(
            kind: ReviewFindingKind::AddsStableUniqueKills,
            test_id: row.test_id,
            reason: "three or more consistent trials identify unique mutant kills",
            evidence: {"stable_unique_kills" => row.stable_unique_kills, "threshold" => stable_analysis.threshold},
          )
        end
      end

      sig { params(oracle: T.nilable(OracleSensitivityAnalysis), gate: EvidenceGate).returns(T::Array[ReviewFinding]) }
      def oracle_findings(oracle, gate)
        return [] if oracle.nil?

        oracle.results.flat_map do |result|
          next [] unless gate.allows_oracle?(result)

          rows = []
          unless result.oracle_dependent_kills.empty?
            rows << ReviewFinding.new(
              kind: ReviewFindingKind::StrengthensExistingOracle,
              test_id: result.test_id,
              reason: "mutant kills disappear when this oracle is disabled",
              evidence: {"oracle_id" => result.oracle_id, "oracle_dependent_kills" => result.oracle_dependent_kills},
            )
          end
            unless result.persists_without_oracle.empty?
              rows << ReviewFinding.new(
              kind: ReviewFindingKind::PersistsWithoutOracle,
              test_id: result.test_id,
              reason: "mutant kills persist when this oracle is disabled",
              evidence: {"oracle_id" => result.oracle_id, "persists_without_oracle" => result.persists_without_oracle},
            )
          end
          rows
        end
      end

      sig do
        params(
          counterfactual: T.nilable(CounterfactualResult),
          test_ids: T::Array[String],
          cohort: T.nilable(CohortEvidenceVector),
          gate: EvidenceGate,
        ).returns(T::Array[ReviewFinding])
      end
      def counterfactual_findings(counterfactual, test_ids, cohort, gate)
        return [] if counterfactual.nil? || test_ids.empty?
        return [] unless gate.allows_counterfactual?(counterfactual)

        kind = if counterfactual.status == CounterfactualStatus::ProvesRevertedChange
                 counterfactual.baseline_detects_reversal ? ReviewFindingKind::DuplicatesChangeDetection : ReviewFindingKind::ProvesRevertedChange
               else
                 ReviewFindingKind::DoesNotDetectRevertedChange
               end
        unless cohort_group_scope?(test_ids, cohort)
          return test_ids.map do |test_id|
            ReviewFinding.new(kind: kind, test_id: test_id, reason: counterfactual.reason, evidence: counterfactual.to_h)
          end
        end

        [ReviewFinding.new(
          kind: kind,
          test_id: nil,
          reason: "the supplied cohort command result applies to the cohort as a group: #{counterfactual.reason}",
          evidence: counterfactual.to_h.merge(
            "scope" => "cohort",
            "test_ids" => T.must(cohort).test_ids,
          ),
        )]
      end

      sig do
        params(
          vectors: T::Array[EvidenceVector],
          threshold: Float,
          gate: EvidenceGate,
        ).returns(T::Array[ReviewFinding])
      end
      def cost_findings(vectors, threshold, gate)
        return [] unless gate.allows_cost?

        vectors.filter_map do |vector|
          next if vector.runtime_ms.nil? || T.must(vector.runtime_ms) < threshold
          next unless vector.unique_kills.zero? && vector.stable_unique_kills.zero?

          ReviewFinding.new(
            kind: ReviewFindingKind::HighCostNoMarginalDetection,
            test_id: vector.test_id,
            reason: "runtime is high without observed marginal mutation detection",
            evidence: vector.to_h,
          )
        end
      end

      sig do
        params(
          counterfactual: T.nilable(CounterfactualResult),
          test_ids: T::Array[String],
          test_id: String,
          cohort: T.nilable(CohortEvidenceVector),
        ).returns(T.nilable(T::Boolean))
      end
      def counterfactual_value(counterfactual, test_ids, test_id, cohort)
        return nil if cohort_group_scope?(test_ids, cohort)
        return nil unless counterfactual && test_ids.include?(test_id)
        return nil if counterfactual.status == CounterfactualStatus::Inconclusive

        counterfactual.status == CounterfactualStatus::ProvesRevertedChange
      end

      sig { params(test_ids: T::Array[String], cohort: T.nilable(CohortEvidenceVector)).returns(T::Boolean) }
      def cohort_group_scope?(test_ids, cohort)
        !cohort.nil? && test_ids.length > 1 && (test_ids - cohort.test_ids).empty?
      end

      sig do
        params(
          contributions: ContributionAnalysis,
          subsumption: SubsumptionAnalysis,
          counterfactual_test_ids: T::Array[String],
        ).returns(T.nilable(CohortEvidenceVector))
      end
      def build_cohort_vector(contributions:, subsumption:, counterfactual_test_ids:)
        cohort = contributions.cohort
        return nil if cohort.nil?

        members = contributions.test_contributions.select { |contribution| cohort.test_ids.include?(contribution.test_id) }
        baseline_kills = contributions.test_contributions
          .select { |contribution| cohort.baseline_test_ids.include?(contribution.test_id) }
          .flat_map(&:killed_mutants)
          .uniq
        internally_redundant = if contributions.completeness.complete?
                                 members.filter_map do |member|
                                   other_kills = members
                                     .reject { |other| other.test_id == member.test_id }
                                     .flat_map(&:killed_mutants)
                                   remaining_detection = (other_kills - baseline_kills).uniq
                                   member.test_id if (cohort.new_detection - remaining_detection).empty?
                                 end.sort.freeze
                               else
                                 [].freeze
                               end
        CohortEvidenceVector.new(
          test_ids: cohort.test_ids,
          baseline_test_ids: cohort.baseline_test_ids,
          new_detection: cohort.new_detection,
          frontier_new_detection: subsumption.cohort_new_frontier_detection,
          internally_redundant_test_ids: internally_redundant,
          counterfactual_test_ids: counterfactual_test_ids,
        )
      end

      sig do
        params(
          contributions: ContributionAnalysis,
          subsumption: SubsumptionAnalysis,
          stability: T.nilable(StabilityAnalysis),
          counterfactual: T.nilable(CounterfactualResult),
          oracle_sensitivity: T.nilable(OracleSensitivityAnalysis),
        ).void
      end
      def validate_scopes!(contributions:, subsumption:, stability:, counterfactual:, oracle_sensitivity:)
        artifacts = {
          "contribution" => contributions,
          "subsumption" => subsumption,
          "stability" => stability,
          "counterfactual" => counterfactual,
          "oracle_sensitivity" => oracle_sensitivity,
        }
        artifacts.each do |name, artifact|
          next if artifact.nil?

          artifact_scope = T.unsafe(artifact).scope
          if artifact_scope.nil?
            raise EvidenceScopeMismatch, "#{name} evidence has no scope identity"
          end
          next if @scope.compatible?(artifact_scope)

          raise EvidenceScopeMismatch, "#{name} evidence scope does not match the report corpus"
        end
      end

    end
  end
end
