# typed: strict
# frozen_string_literal: true

require "set"
require "sorbet-runtime"
require_relative "completeness"
require_relative "scope"

module TestMiser
  module Evidence
    class InvalidCohort < ArgumentError; end

    class FindingKind < T::Enum
      enums do
        AddsUniqueKills = new("ADDS_UNIQUE_KILLS")
        AddsGroupDetection = new("ADDS_GROUP_DETECTION")
        MutationRedundant = new("MUTATION_REDUNDANT")
        MutationDominated = new("MUTATION_DOMINATED")
        CoveredWeakOracle = new("COVERED_WEAK_ORACLE")
        OutOfMutationScope = new("OUT_OF_MUTATION_SCOPE")
        UnknownIncompleteAttribution = new("UNKNOWN_INCOMPLETE_ATTRIBUTION")
      end
    end

    class TestObservation < T::Struct
      extend T::Sig

      const :id, String
      const :name, String
      const :covered_mutants, T::Array[String]
      const :killed_mutants, T::Array[String]
      const :source_file, T.nilable(String), default: nil
      const :source_line, T.nilable(Integer), default: nil

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "test_id" => id,
          "test_name" => name,
          "covered_mutants" => covered_mutants,
          "killed_mutants" => killed_mutants,
          "source_file" => source_file,
          "source_line" => source_line,
        }.compact
      end
    end

    class MutantObservation < T::Struct
      extend T::Sig

      const :id, String
      const :covered_by, T::Array[String]
      const :killed_by, T::Array[String]

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "mutant_id" => id,
          "covered_by" => covered_by,
          "killed_by" => killed_by,
        }
      end
    end

    class Corpus < T::Struct
      extend T::Sig

      const :tests, T::Array[TestObservation]
      const :mutants, T::Array[MutantObservation]
      const :complete, T.nilable(T::Boolean)
      const :incomplete_reason, T.nilable(String), default: nil

      sig { params(report: T.untyped).returns(Corpus) }
      def self.from_report(report)
        tests = report.tests.map do |test|
          source_file = test.respond_to?(:file) ? test.file : nil
          source_file = nil if source_file.to_s.empty? || source_file.to_s == "(unknown)"
          source_line = test.respond_to?(:line) ? test.line : nil
          TestObservation.new(
            id: test.id.to_s,
            name: test.name.to_s,
            covered_mutants: [],
            killed_mutants: [],
            source_file: source_file&.to_s,
            source_line: source_line,
          )
        end
        observations = tests.to_h { |test| [test.id, test] }

        mutants = report.mutants.map do |mutant|
          covered_by = sorted_strings(mutant.covered_by)
          killed_by = sorted_strings(mutant.killed_by)
          covered_by = (covered_by | killed_by).sort
          killed_by.each do |test_id|
            observations.fetch(test_id).killed_mutants << mutant.id.to_s
          end
          covered_by.each do |test_id|
            observations.fetch(test_id).covered_mutants << mutant.id.to_s
          end
          MutantObservation.new(id: mutant.id.to_s, covered_by: covered_by, killed_by: killed_by)
        end

        normalized_tests = observations.values.map do |test|
          TestObservation.new(
            id: test.id,
            name: test.name,
            covered_mutants: test.covered_mutants.uniq.sort.freeze,
            killed_mutants: test.killed_mutants.uniq.sort.freeze,
            source_file: test.source_file,
            source_line: test.source_line,
          )
        end.sort_by(&:id).freeze
        Corpus.new(
          tests: normalized_tests,
          mutants: mutants.sort_by(&:id).freeze,
          complete: report.corpus_complete,
          incomplete_reason: incomplete_reason_for(report.corpus_complete),
        )
      end

      sig { returns(T::Boolean) }
      def complete?
        completeness.complete?
      end

      sig { returns(EvidenceCompleteness) }
      def completeness
        EvidenceCompleteness.new(status: complete, reason: completeness_reason)
      end

      sig { returns(T.nilable(String)) }
      def completeness_reason
        return nil if complete == true
        return incomplete_reason unless incomplete_reason.nil?

        complete == false ? "mutation corpus or attribution is incomplete" : "corpus completeness is unknown"
      end

      sig do
        params(revision: String, selection_scope: String, repository: T.nilable(String)).returns(EvidenceScope)
      end
      def evidence_scope(revision: "unknown", selection_scope: "all", repository: nil)
        EvidenceScope.from_parts(
          revision: revision,
          selection_scope: selection_scope,
          mutants: mutants.map(&:to_h),
          test_ids: tests.map(&:id),
          repository: repository,
        )
      end

      class << self
        extend T::Sig

        private

        sig { params(values: T.untyped).returns(T::Array[String]) }
        def sorted_strings(values)
          Array(values).map(&:to_s).reject(&:empty?).uniq.sort
        end

        sig { params(complete: T.nilable(T::Boolean)).returns(T.nilable(String)) }
        def incomplete_reason_for(complete)
          return nil if complete == true

          complete == false ? "mutation corpus or attribution is incomplete" : "corpus completeness is unknown"
        end
      end
    end

    class TestContribution < T::Struct
      extend T::Sig

      const :test_id, String
      const :covered_mutants, T::Array[String]
      const :killed_mutants, T::Array[String]
      const :unique_kills, T::Array[String]
      const :dominated_by, T::Array[String]
      const :findings, T::Array[FindingKind]

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "test_id" => test_id,
          "covered_mutants" => covered_mutants,
          "killed_mutants" => killed_mutants,
          "unique_kills" => unique_kills,
          "dominated_by" => dominated_by,
          "findings" => findings.map(&:serialize),
        }
      end
    end

    class CohortContribution < T::Struct
      extend T::Sig

      const :test_ids, T::Array[String]
      const :baseline_test_ids, T::Array[String]
      const :new_detection, T::Array[String]
      const :findings, T::Array[FindingKind]

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "test_ids" => test_ids,
          "baseline_test_ids" => baseline_test_ids,
          "new_detection" => new_detection,
          "findings" => findings.map(&:serialize),
        }
      end
    end

    class ContributionAnalysis < T::Struct
      extend T::Sig

      const :test_contributions, T::Array[TestContribution]
      const :cohort, T.nilable(CohortContribution)
      const :mutant_count, Integer
      const :corpus_complete, T.nilable(T::Boolean)
      const :unknown_reason, T.nilable(String)
      const :completeness, EvidenceCompleteness
      const :scope, T.nilable(EvidenceScope), default: nil

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "schema" => "test-quality-evidence/contribution-v1",
          "summary" => {
            "tests" => test_contributions.length,
            "mutants" => mutant_count,
            "corpus_complete" => corpus_complete,
            "evidence_completeness" => completeness.to_h,
            "scope" => scope&.to_h,
            "tests_with_unique_kills" => test_contributions.count { |test| !test.unique_kills.empty? },
            "cohort_new_detection" => cohort&.new_detection || [],
            "unknown_reason" => unknown_reason,
          },
          "tests" => test_contributions.map(&:to_h),
          "cohort" => cohort&.to_h,
        }
      end
    end

    class ContributionAnalyzer
      extend T::Sig

      sig { params(corpus: Corpus, scope: T.nilable(EvidenceScope), revision: String, repository: T.nilable(String)).void }
      def initialize(corpus, scope: nil, revision: "unknown", repository: nil)
        @corpus = corpus
        @scope = T.let(scope || corpus.evidence_scope(revision: revision, repository: repository), EvidenceScope)
      end

      sig do
        params(
          new_test_ids: T::Array[String],
          baseline_test_ids: T::Array[String],
        ).returns(ContributionAnalysis)
      end
      def analyze(new_test_ids: [], baseline_test_ids: [])
        unique_kills = unique_kills_by_test
        contributions = @corpus.tests.map do |test|
          test_unique_kills = unique_kills.fetch(test.id)
          TestContribution.new(
            test_id: test.id,
            covered_mutants: test.covered_mutants,
            killed_mutants: test.killed_mutants,
            unique_kills: test_unique_kills,
            dominated_by: [],
            findings: findings_for(test, test_unique_kills),
          )
        end

        covered_sets = @corpus.tests.to_h { |test| [test.id, test.covered_mutants.to_set] }
        killed_sets = @corpus.tests.to_h { |test| [test.id, test.killed_mutants.to_set] }
        contributions = contributions.map do |contribution|
          dominated_by = dominated_by_for(contribution, contributions, covered_sets, killed_sets)
          findings = contribution.findings
          findings = (findings + [FindingKind::MutationDominated]).uniq unless dominated_by.empty?
          TestContribution.new(
            test_id: contribution.test_id,
            covered_mutants: contribution.covered_mutants,
            killed_mutants: contribution.killed_mutants,
            unique_kills: contribution.unique_kills,
            dominated_by: dominated_by,
            findings: findings.freeze,
          )
        end.freeze

        cohort = if new_test_ids.empty? && baseline_test_ids.empty?
                   nil
                 else
                   cohort_for(new_test_ids, baseline_test_ids)
                 end
        ContributionAnalysis.new(
          test_contributions: contributions,
          cohort: cohort,
          mutant_count: @corpus.mutants.length,
          corpus_complete: @corpus.complete,
          unknown_reason: @corpus.completeness_reason,
          completeness: @corpus.completeness,
          scope: @scope,
        )
      end

      private

      sig { returns(T::Hash[String, T::Array[String]]) }
      def unique_kills_by_test
        unique = T.let({}, T::Hash[String, T::Array[String]])
        @corpus.tests.each { |test| unique[test.id] = T.let([], T::Array[String]) }
        return unique.transform_values(&:freeze).freeze unless @corpus.completeness.complete?

        @corpus.mutants.each do |mutant|
          next unless mutant.killed_by.length == 1

          test_id = T.must(mutant.killed_by.first)
          next unless unique.key?(test_id)

          unique.fetch(test_id) << mutant.id
        end
        unique.transform_values { |mutant_ids| mutant_ids.sort.freeze }.freeze
      end

      sig { params(test: TestObservation, unique_kills: T::Array[String]).returns(T::Array[FindingKind]) }
      def findings_for(test, unique_kills)
        return [FindingKind::UnknownIncompleteAttribution] unless @corpus.completeness.complete?
        return [FindingKind::AddsUniqueKills] unless unique_kills.empty?
        return [FindingKind::MutationRedundant] unless test.killed_mutants.empty?
        return [FindingKind::CoveredWeakOracle] unless test.covered_mutants.empty?

        [FindingKind::OutOfMutationScope]
      end

      sig do
        params(
          contribution: TestContribution,
          all_contributions: T::Array[TestContribution],
          covered_sets: T::Hash[String, T::Set[String]],
          killed_sets: T::Hash[String, T::Set[String]],
        ).returns(T::Array[String])
      end
      def dominated_by_for(contribution, all_contributions, covered_sets, killed_sets)
        return [] unless @corpus.completeness.complete?
        return [] unless contribution.unique_kills.empty?
        # A test outside the observed mutation scope has no evidence-bearing
        # set relationship.  Empty sets are subsets of every set, so allowing
        # them here would falsely mark unrelated tests as dominated.
        return [] if contribution.covered_mutants.empty? && contribution.killed_mutants.empty?

        covered = covered_sets.fetch(contribution.test_id)
        killed = killed_sets.fetch(contribution.test_id)
        candidate = all_contributions.filter_map do |other|
          next if other.test_id == contribution.test_id
          other_covered = covered_sets.fetch(other.test_id)
          other_killed = killed_sets.fetch(other.test_id)
          next unless subset_set?(covered, other_covered)
          next unless subset_set?(killed, other_killed)
          next unless covered.length < other_covered.length || killed.length < other_killed.length

          other.test_id
        end
        candidate.sort.freeze
      end

      sig { params(new_test_ids: T::Array[String], baseline_test_ids: T::Array[String]).returns(CohortContribution) }
      def cohort_for(new_test_ids, baseline_test_ids)
        normalized_new = new_test_ids.uniq.sort.freeze
        normalized_baseline = baseline_test_ids.uniq.sort.freeze
        validate_cohort_ids!(normalized_new, normalized_baseline)
        new_kills = kills_for(normalized_new)
        baseline_kills = kills_for(normalized_baseline)
        new_detection = @corpus.completeness.complete? ? (new_kills - baseline_kills).sort.freeze : [].freeze
        findings = if !@corpus.completeness.complete?
                     [FindingKind::UnknownIncompleteAttribution]
                   elsif new_detection.empty?
                     []
                   else
                     [FindingKind::AddsGroupDetection]
                   end
        CohortContribution.new(
          test_ids: normalized_new,
          baseline_test_ids: normalized_baseline,
          new_detection: new_detection,
          findings: findings.freeze,
        )
      end

      sig { params(new_test_ids: T::Array[String], baseline_test_ids: T::Array[String]).void }
      def validate_cohort_ids!(new_test_ids, baseline_test_ids)
        known_test_ids = @corpus.tests.map(&:id)
        unknown = (new_test_ids + baseline_test_ids).uniq.reject { |test_id| known_test_ids.include?(test_id) }
        unless unknown.empty?
          raise InvalidCohort, "cohort names unknown tests: #{unknown.sort.join(", ")}"
        end

        overlap = (new_test_ids & baseline_test_ids).sort
        return if overlap.empty?

        raise InvalidCohort, "cohort tests overlap baseline tests: #{overlap.join(", ")}"
      end

      sig { params(test_ids: T::Array[String]).returns(T::Set[String]) }
      def kills_for(test_ids)
        @corpus.tests.select { |test| test_ids.include?(test.id) }
          .flat_map(&:killed_mutants).to_set
      end

      sig { params(left: T::Set[String], right: T::Set[String]).returns(T::Boolean) }
      def subset_set?(left, right)
        left.all? { |value| right.include?(value) }
      end
    end
  end
end
