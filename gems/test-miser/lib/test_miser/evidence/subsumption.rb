# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

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
          },
          "equivalent_mutants" => equivalent_groups.map(&:to_h),
          "relations" => relations.map(&:to_h),
          "rankings" => rankings.map(&:to_h),
        }
      end
    end

    class SubsumptionAnalyzer
      extend T::Sig

      sig { params(corpus: Corpus).void }
      def initialize(corpus)
        @corpus = corpus
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
          )
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
        )
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

        ordered.each_with_index do |target, target_index|
          immediate_subsumers = []
          (target_index - 1).downto(0) do |candidate_index|
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
