# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module TestMiser
  module Evidence
    class KillTrial < T::Struct
      extend T::Sig

      const :test_id, String
      const :mutant_id, String
      const :killed, T::Boolean
      const :trial, Integer

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "test_id" => test_id,
          "mutant_id" => mutant_id,
          "killed" => killed,
          "trial" => trial,
        }
      end
    end

    class StableTestAttribution < T::Struct
      extend T::Sig

      const :test_id, String
      const :stable_kills, T::Array[String]
      const :unstable_kills, T::Array[String]
      const :observations, T::Hash[String, T::Array[T::Boolean]]

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "test_id" => test_id,
          "stable_kills" => stable_kills,
          "unstable_kills" => unstable_kills,
          "observations" => observations,
        }
      end
    end

    class StableUniqueKills < T::Struct
      extend T::Sig

      const :test_id, String
      const :stable_unique_kills, T::Array[String]

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {"test_id" => test_id, "stable_unique_kills" => stable_unique_kills}
      end
    end

    class StabilityAnalysis < T::Struct
      extend T::Sig

      const :attributions, T::Array[StableTestAttribution]
      const :stable_unique_kills, T::Array[StableUniqueKills]
      const :threshold, Integer
      const :observed_trials, Integer

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "schema" => "test-quality-evidence/stability-v1",
          "summary" => {
            "threshold" => threshold,
            "observed_trials" => observed_trials,
            "stable_unique_kills" => stable_unique_kills.sum { |row| row.stable_unique_kills.length },
            "unstable_kills" => attributions.sum { |row| row.unstable_kills.length },
          },
          "tests" => attributions.map(&:to_h),
          "stable_unique_kills" => stable_unique_kills.map(&:to_h),
        }
      end
    end

    class StabilityAnalyzer
      extend T::Sig

      sig { params(corpus: Corpus, threshold: Integer).void }
      def initialize(corpus, threshold: 3)
        raise ArgumentError, "threshold must be positive" unless threshold.positive?

        @corpus = corpus
        @threshold = threshold
      end

      sig { params(trials: T::Array[KillTrial]).returns(StabilityAnalysis) }
      def analyze(trials)
        observations = trials.group_by { |trial| [trial.test_id, trial.mutant_id] }
          .transform_values { |rows| rows.sort_by(&:trial).map(&:killed) }
        attributions = @corpus.tests.map do |test|
          StableTestAttribution.new(
            test_id: test.id,
            stable_kills: stable_kills_for(test.id, observations),
            unstable_kills: unstable_kills_for(test.id, observations),
            observations: observations_for(test.id, observations),
          )
        end.freeze
        stable_unique = attributions.map do |attribution|
          other_stable = attributions.reject { |other| other.test_id == attribution.test_id }
            .flat_map(&:stable_kills)
          StableUniqueKills.new(
            test_id: attribution.test_id,
            stable_unique_kills: (attribution.stable_kills - other_stable).sort.freeze,
          )
        end.freeze
        StabilityAnalysis.new(
          attributions: attributions,
          stable_unique_kills: stable_unique,
          threshold: @threshold,
          observed_trials: trials.length,
        )
      end

      private

      sig do
        params(
          test_id: String,
          observations: T::Hash[[String, String], T::Array[T::Boolean]],
        ).returns(T::Array[String])
      end
      def stable_kills_for(test_id, observations)
        observations.filter_map do |(observed_test, mutant_id), outcomes|
          next unless observed_test == test_id
          next unless outcomes.length >= @threshold && outcomes.all?

          mutant_id
        end.sort.freeze
      end

      sig do
        params(
          test_id: String,
          observations: T::Hash[[String, String], T::Array[T::Boolean]],
        ).returns(T::Array[String])
      end
      def unstable_kills_for(test_id, observations)
        observations.filter_map do |(observed_test, mutant_id), outcomes|
          next unless observed_test == test_id
          next unless outcomes.any?
          next if outcomes.length >= @threshold && outcomes.all?

          mutant_id
        end.sort.freeze
      end

      sig do
        params(
          test_id: String,
          observations: T::Hash[[String, String], T::Array[T::Boolean]],
        ).returns(T::Hash[String, T::Array[T::Boolean]])
      end
      def observations_for(test_id, observations)
        observations.filter_map do |(observed_test, mutant_id), outcomes|
          [mutant_id, outcomes] if observed_test == test_id
        end.to_h
      end
    end

    class RerunCandidate < T::Struct
      extend T::Sig

      const :test_id, String
      const :mutant_ids, T::Array[String]
      const :reason, String

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {"test_id" => test_id, "mutant_ids" => mutant_ids, "reason" => reason}
      end
    end

    class RerunScheduler
      extend T::Sig

      sig { params(analysis: ContributionAnalysis).returns(T::Array[RerunCandidate]) }
      def self.schedule(analysis)
        analysis.test_contributions.filter_map do |contribution|
          reasons = contribution.findings.select do |finding|
            [FindingKind::MutationRedundant, FindingKind::MutationDominated,
             FindingKind::CoveredWeakOracle].include?(finding)
          end
          reasons = [] if contribution.covered_mutants.empty?
          next if reasons.empty?

          RerunCandidate.new(
            test_id: contribution.test_id,
            mutant_ids: contribution.killed_mutants,
            reason: reasons.map(&:serialize).join(","),
          )
        end.sort_by(&:test_id).freeze
      end
    end
  end
end
