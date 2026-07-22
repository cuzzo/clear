# typed: strict
# frozen_string_literal: true

require "set"
require "sorbet-runtime"
require_relative "scope"

module TestMiser
  module Evidence
    class EquivalentMutantGroup < T::Struct
      extend T::Sig

      const :mutant_ids, T::Array[String]
      const :killer_tests, T::Array[String]

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {"mutant_ids" => mutant_ids, "killer_tests" => killer_tests}
      end
    end

    class SubsumptionRelation < T::Struct
      extend T::Sig

      const :subsuming_mutant_id, String
      const :subsumed_mutant_id, String
      const :killer_tests, T::Array[String]

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "subsuming_mutant_id" => subsuming_mutant_id,
          "subsumed_mutant_id" => subsumed_mutant_id,
          "killer_tests" => killer_tests,
        }
      end
    end

    class SubsumptionBudgetExceeded < StandardError; end

    class IndexedKillSet < T::Struct
      extend T::Sig

      const :mutant_ids, T::Array[String]
      const :killer_tests, T::Array[String]
      const :mask, Integer
      const :cardinality, Integer
    end

    class FrontierRanking < T::Struct
      extend T::Sig

      const :test_id, String
      const :frontier_unique_kills, T::Array[String]

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "test_id" => test_id,
          "frontier_unique_kills" => frontier_unique_kills,
        }
      end
    end

    class SubsumptionAnalysis < T::Struct
      extend T::Sig

      const :equivalent_groups, T::Array[EquivalentMutantGroup]
      const :relations, T::Array[SubsumptionRelation]
      const :frontier_mutants, T::Array[String]
      const :cohort_new_frontier_detection, T::Array[String]
      const :rankings, T::Array[FrontierRanking]
      const :corpus_complete, T.nilable(T::Boolean)
      const :unknown_reason, T.nilable(String)
      const :scope, T.nilable(EvidenceScope), default: nil
      const :subsumption_complete, T::Boolean, default: true

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "schema" => "test-quality-evidence/subsumption-v1",
          "summary" => {
            "equivalent_groups" => equivalent_groups.length,
            "subsumption_relations" => relations.length,
            "relation_scope" => "immediate",
            "frontier_mutants" => frontier_mutants,
            "cohort_new_frontier_detection" => cohort_new_frontier_detection,
            "corpus_complete" => corpus_complete,
            "unknown_reason" => unknown_reason,
            "subsumption_complete" => subsumption_complete,
            "scope" => scope&.to_h,
          },
          "equivalent_mutants" => equivalent_groups.map(&:to_h),
          "relations" => relations.map(&:to_h),
          "rankings" => rankings.map(&:to_h),
        }
      end
    end

    class SubsumptionAnalyzer
      extend T::Sig

      DEFAULT_MAX_DISTINCT_KILL_SETS = T.let(50_000, Integer)
      DEFAULT_MAX_RELATION_CHECKS = T.let(5_000_000, Integer)

      sig do
        params(
          corpus: Corpus,
          scope: T.nilable(EvidenceScope),
          revision: String,
          repository: T.nilable(String),
          max_distinct_kill_sets: Integer,
          max_relation_checks: Integer,
        ).void
      end
      def initialize(
        corpus,
        scope: nil,
        revision: "unknown",
        repository: nil,
        max_distinct_kill_sets: DEFAULT_MAX_DISTINCT_KILL_SETS,
        max_relation_checks: DEFAULT_MAX_RELATION_CHECKS
      )
        raise ArgumentError, "max_distinct_kill_sets must be positive" unless max_distinct_kill_sets.positive?
        raise ArgumentError, "max_relation_checks must be positive" unless max_relation_checks.positive?

        @corpus = corpus
        @scope = T.let(scope || corpus.evidence_scope(revision: revision, repository: repository), EvidenceScope)
        @max_distinct_kill_sets = max_distinct_kill_sets
        @max_relation_checks = max_relation_checks
      end

      sig { params(contributions: T.nilable(ContributionAnalysis)).returns(SubsumptionAnalysis) }
      def analyze(contributions: nil)
        unless @corpus.completeness.complete?
          return SubsumptionAnalysis.new(
            equivalent_groups: [],
            relations: [],
            frontier_mutants: [],
            cohort_new_frontier_detection: [],
            rankings: rankings_for([], contributions),
            corpus_complete: @corpus.complete,
            unknown_reason: @corpus.completeness_reason,
            scope: contributions&.scope || @scope,
          )
        end

        if distinct_kill_set_count > @max_distinct_kill_sets
          return limited_analysis(contributions, "subsumption distinct kill-set budget exceeded")
        end

        kill_sets = indexed_kill_sets
        groups = equivalent_groups(kill_sets)
        relations = subsumption_relations(kill_sets)
        frontier = frontier_mutants(kill_sets, relations)
        SubsumptionAnalysis.new(
          equivalent_groups: groups,
          relations: relations,
          frontier_mutants: frontier,
          cohort_new_frontier_detection: cohort_frontier_detection(frontier, contributions),
          rankings: rankings_for(frontier, contributions),
          corpus_complete: @corpus.complete,
          unknown_reason: nil,
          scope: contributions&.scope || @scope,
        )
      rescue SubsumptionBudgetExceeded => error
        limited_analysis(contributions, error.message)
      end

      private

      sig { params(kill_sets: T::Array[IndexedKillSet]).returns(T::Array[EquivalentMutantGroup]) }
      def equivalent_groups(kill_sets)
        kill_sets.filter_map do |kill_set|
          next if kill_set.mutant_ids.length < 2

          EquivalentMutantGroup.new(
            mutant_ids: kill_set.mutant_ids,
            killer_tests: kill_set.killer_tests,
          )
        end.sort_by { |group| T.must(group.mutant_ids.first) }.freeze
      end

      sig { params(kill_sets: T::Array[IndexedKillSet]).returns(T::Array[SubsumptionRelation]) }
      def subsumption_relations(kill_sets)
        ordered = kill_sets.sort_by { |kill_set| [kill_set.cardinality, T.must(kill_set.mutant_ids.first)] }
        relations = []
        relation_checks = T.let(0, Integer)

        ordered.each_with_index do |target, target_index|
          immediate_subsumers = []
          (target_index - 1).downto(0) do |candidate_index|
            relation_checks += 1
            raise SubsumptionBudgetExceeded, "subsumption relation-check budget exceeded" if relation_checks > @max_relation_checks

            candidate = T.must(ordered[candidate_index])
            next unless candidate.cardinality < target.cardinality
            next unless subset_mask?(candidate.mask, target.mask)
            # Candidates are visited from the largest sets down.  If an
            # already-selected candidate contains this one, the relation is
            # transitive and need not be materialized.
            next if immediate_subsumers.any? { |middle| subset_mask?(candidate.mask, middle.mask) }

            immediate_subsumers << candidate
          end

          immediate_subsumers.each do |source|
            relations << SubsumptionRelation.new(
              subsuming_mutant_id: source.mutant_ids.fetch(0),
              subsumed_mutant_id: target.mutant_ids.fetch(0),
              killer_tests: source.killer_tests,
            )
          end
        end

        relations.sort_by { |relation| [relation.subsuming_mutant_id, relation.subsumed_mutant_id] }.freeze
      end

      sig do
        params(
          kill_sets: T::Array[IndexedKillSet],
          relations: T::Array[SubsumptionRelation],
        ).returns(T::Array[String])
      end
      def frontier_mutants(kill_sets, relations)
        subsumed = relations.to_h { |relation| [relation.subsumed_mutant_id, true] }
        kill_sets.filter_map do |kill_set|
          representative = T.must(kill_set.mutant_ids.first)
          representative unless subsumed.key?(representative)
        end.sort.freeze
      end

      sig { returns(T::Array[IndexedKillSet]) }
      def indexed_kill_sets
        test_bits = test_bit_index
        groups = @corpus.mutants.group_by { |mutant| mutant.killed_by.uniq.sort }
        groups.filter_map do |killer_tests, mutants|
          next if killer_tests.empty?

          mask = killer_tests.reduce(0) do |value, test_id|
            value | test_bits.fetch(test_id)
          end
          IndexedKillSet.new(
            mutant_ids: mutants.map(&:id).sort.freeze,
            killer_tests: killer_tests.freeze,
            mask: mask,
            cardinality: killer_tests.length,
          )
        end.sort_by { |kill_set| T.must(kill_set.mutant_ids.first) }.freeze
      end

      sig { returns(Integer) }
      def distinct_kill_set_count
        @corpus.mutants.map { |mutant| mutant.killed_by.uniq.sort }.uniq.length
      end

      sig { params(contributions: T.nilable(ContributionAnalysis), reason: String).returns(SubsumptionAnalysis) }
      def limited_analysis(contributions, reason)
        SubsumptionAnalysis.new(
          equivalent_groups: [],
          relations: [],
          frontier_mutants: [],
          cohort_new_frontier_detection: [],
          rankings: rankings_for([], contributions),
          corpus_complete: @corpus.complete,
          unknown_reason: reason,
          scope: contributions&.scope || @scope,
          subsumption_complete: false,
        )
      end

      sig { returns(T::Hash[String, Integer]) }
      def test_bit_index
        test_ids = (@corpus.tests.map(&:id) + @corpus.mutants.flat_map(&:killed_by)).uniq.sort
        test_ids.each_with_index.to_h { |test_id, index| [test_id, 1 << index] }
      end

      sig { params(left: Integer, right: Integer).returns(T::Boolean) }
      def subset_mask?(left, right)
        (left & ~right).zero?
      end

      sig do
        params(
          frontier: T::Array[String],
          contributions: T.nilable(ContributionAnalysis),
        ).returns(T::Array[FrontierRanking])
      end
      def rankings_for(frontier, contributions)
        return [] if contributions.nil?

        contributions.test_contributions.map do |contribution|
          FrontierRanking.new(
            test_id: contribution.test_id,
            frontier_unique_kills: (contribution.unique_kills & frontier).sort.freeze,
          )
        end.freeze
      end

      sig do
        params(
          frontier: T::Array[String],
          contributions: T.nilable(ContributionAnalysis),
        ).returns(T::Array[String])
      end
      def cohort_frontier_detection(frontier, contributions)
        cohort = contributions&.cohort
        return [].freeze if cohort.nil?

        (cohort.new_detection & frontier).sort.freeze
      end

    end
  end
end
