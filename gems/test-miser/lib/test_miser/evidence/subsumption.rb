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

    class FrontierRanking < T::Struct
      extend T::Sig

      const :test_id, String
      const :frontier_unique_kills, T::Array[String]
      const :cohort_new_frontier_detection, T::Array[String]

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "test_id" => test_id,
          "frontier_unique_kills" => frontier_unique_kills,
          "cohort_new_frontier_detection" => cohort_new_frontier_detection,
        }
      end
    end

    class SubsumptionAnalysis < T::Struct
      extend T::Sig

      const :equivalent_groups, T::Array[EquivalentMutantGroup]
      const :relations, T::Array[SubsumptionRelation]
      const :frontier_mutants, T::Array[String]
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
            "frontier_mutants" => frontier_mutants,
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
        unless @corpus.complete?
          return SubsumptionAnalysis.new(
            equivalent_groups: [],
            relations: [],
            frontier_mutants: [],
            rankings: rankings_for([], contributions),
            corpus_complete: @corpus.complete,
            unknown_reason: @corpus.completeness_reason,
          )
        end

        groups = equivalent_groups
        relations = subsumption_relations
        frontier = frontier_mutants(groups, relations)
        SubsumptionAnalysis.new(
          equivalent_groups: groups,
          relations: relations,
          frontier_mutants: frontier,
          rankings: rankings_for(frontier, contributions),
          corpus_complete: @corpus.complete,
          unknown_reason: nil,
        )
      end

      private

      sig { returns(T::Array[EquivalentMutantGroup]) }
      def equivalent_groups
        @corpus.mutants
          .reject { |mutant| mutant.killed_by.empty? }
          .group_by(&:killed_by)
          .values
          .select { |group| group.length > 1 }
          .map do |group|
            EquivalentMutantGroup.new(
              mutant_ids: group.map(&:id).sort.freeze,
              killer_tests: T.must(group.first).killed_by,
            )
          end
          .sort_by { |group| T.must(group.mutant_ids.first) }
          .freeze
      end

      sig { returns(T::Array[SubsumptionRelation]) }
      def subsumption_relations
        @corpus.mutants.flat_map do |harder|
          next [] if harder.killed_by.empty?

          @corpus.mutants.filter_map do |easier|
            next if harder.id == easier.id || easier.killed_by.empty?
            next unless strict_subset?(harder.killed_by, easier.killed_by)

            SubsumptionRelation.new(
              subsuming_mutant_id: harder.id,
              subsumed_mutant_id: easier.id,
              killer_tests: harder.killed_by,
            )
          end
        end.sort_by { |relation| [relation.subsuming_mutant_id, relation.subsumed_mutant_id] }.freeze
      end

      sig do
        params(
          groups: T::Array[EquivalentMutantGroup],
          relations: T::Array[SubsumptionRelation],
        ).returns(T::Array[String])
      end
      def frontier_mutants(groups, relations)
        representatives = groups.flat_map { |group| group.mutant_ids.drop(1) }
        subsumed = relations.map(&:subsumed_mutant_id)
        @corpus.mutants.map(&:id).select do |mutant_id|
          next false if @corpus.mutants.find { |mutant| mutant.id == mutant_id }&.killed_by&.empty?
          !representatives.include?(mutant_id) && !subsumed.include?(mutant_id)
        end.sort.freeze
      end

      sig do
        params(
          frontier: T::Array[String],
          contributions: T.nilable(ContributionAnalysis),
        ).returns(T::Array[FrontierRanking])
      end
      def rankings_for(frontier, contributions)
        return [] if contributions.nil?

        cohort = contributions.cohort
        contributions.test_contributions.map do |contribution|
          FrontierRanking.new(
            test_id: contribution.test_id,
            frontier_unique_kills: (contribution.unique_kills & frontier).sort.freeze,
            cohort_new_frontier_detection: if cohort
                                             (cohort.new_detection & frontier).sort.freeze
                                           else
                                             [].freeze
                                           end,
          )
        end.freeze
      end

      sig { params(left: T::Array[String], right: T::Array[String]).returns(T::Boolean) }
      def strict_subset?(left, right)
        left.length < right.length && left.all? { |value| right.include?(value) }
      end
    end
  end
end
