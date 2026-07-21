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

    class MatrixCheck < T::Struct
      const :complete, T::Boolean
      const :unknown_reason, T.nilable(String)
    end

    class StabilityAnalysis < T::Struct
      extend T::Sig

      const :attributions, T::Array[StableTestAttribution]
      const :stable_unique_kills, T::Array[StableUniqueKills]
      const :threshold, Integer
      const :observed_trials, Integer
      const :trial_ids, T::Array[Integer]
      const :selected_test_ids, T::Array[String]
      const :selected_mutant_ids, T::Array[String]
      const :matrix_complete, T::Boolean
      const :unknown_reason, T.nilable(String)

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "schema" => "test-quality-evidence/stability-v1",
          "summary" => {
            "threshold" => threshold,
            "observed_trials" => observed_trials,
            "trial_ids" => trial_ids,
            "matrix_complete" => matrix_complete,
            "stable_unique_kills" => stable_unique_kills.sum { |row| row.stable_unique_kills.length },
            "unstable_kills" => attributions.sum { |row| row.unstable_kills.length },
            "unknown_reason" => unknown_reason,
          },
          "selected_test_ids" => selected_test_ids,
          "selected_mutant_ids" => selected_mutant_ids,
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

      sig do
        params(
          trials: T::Array[KillTrial],
          test_ids: T.nilable(T::Array[String]),
          mutant_ids: T.nilable(T::Array[String]),
          trial_ids: T.nilable(T::Array[Integer]),
        ).returns(StabilityAnalysis)
      end
      def analyze(trials, test_ids: nil, mutant_ids: nil, trial_ids: nil)
        selected_test_ids = (test_ids || @corpus.tests.map(&:id)).uniq.sort.freeze
        selected_mutant_ids = (mutant_ids || @corpus.mutants.map(&:id)).uniq.sort.freeze
        selected_trial_ids = (trial_ids || trials.map(&:trial)).uniq.sort.freeze
        observations, duplicate_observations = normalized_observations(
          trials,
          selected_test_ids,
          selected_mutant_ids,
          selected_trial_ids,
        )
        matrix = matrix_check(
          selected_test_ids,
          selected_mutant_ids,
          selected_trial_ids,
          observations,
          duplicate_observations,
        )
        selected_tests = @corpus.tests.select { |test| selected_test_ids.include?(test.id) }
        attributions = selected_tests.map do |test|
          StableTestAttribution.new(
            test_id: test.id,
            stable_kills: matrix.complete ? stable_kills_for(test.id, observations) : [],
            unstable_kills: unstable_kills_for(test.id, observations),
            observations: observations_for(test.id, observations),
          )
        end.freeze
        stable_unique = if matrix.complete
                          attributions.map do |attribution|
                            other_stable = attributions.reject { |other| other.test_id == attribution.test_id }
                              .flat_map(&:stable_kills)
                            StableUniqueKills.new(
                              test_id: attribution.test_id,
                              stable_unique_kills: (attribution.stable_kills - other_stable).sort.freeze,
                            )
                          end
                        else
                          selected_tests.map { |test| StableUniqueKills.new(test_id: test.id, stable_unique_kills: []) }
                        end.freeze
        StabilityAnalysis.new(
          attributions: attributions,
          stable_unique_kills: stable_unique,
          threshold: @threshold,
          observed_trials: selected_trial_ids.length,
          trial_ids: selected_trial_ids,
          selected_test_ids: selected_test_ids,
          selected_mutant_ids: selected_mutant_ids,
          matrix_complete: matrix.complete,
          unknown_reason: matrix.unknown_reason,
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

      sig do
        params(
          trials: T::Array[KillTrial],
          test_ids: T::Array[String],
          mutant_ids: T::Array[String],
          trial_ids: T::Array[Integer],
        ).returns([T::Hash[[String, String], T::Array[T::Boolean]], T::Boolean])
      end
      def normalized_observations(trials, test_ids, mutant_ids, trial_ids)
        relevant = trials.select do |trial|
          test_ids.include?(trial.test_id) && mutant_ids.include?(trial.mutant_id) && trial_ids.include?(trial.trial)
        end
        by_pair = relevant.group_by { |trial| [trial.test_id, trial.mutant_id] }
        duplicate = by_pair.any? do |_key, rows|
          rows.group_by(&:trial).any? { |_trial_id, same_trial| same_trial.length > 1 }
        end
        observations = by_pair.transform_values do |rows|
          rows.group_by(&:trial).sort_by { |trial_id, _rows| trial_id }
            .map { |_trial_id, same_trial| T.must(same_trial.first).killed }
        end
        [observations, duplicate]
      end

      sig do
        params(
          test_ids: T::Array[String],
          mutant_ids: T::Array[String],
          trial_ids: T::Array[Integer],
          observations: T::Hash[[String, String], T::Array[T::Boolean]],
          duplicate_observations: T::Boolean,
        ).returns(MatrixCheck)
      end
      def matrix_check(test_ids, mutant_ids, trial_ids, observations, duplicate_observations)
        return MatrixCheck.new(complete: false, unknown_reason: @corpus.completeness_reason) unless @corpus.completeness.complete?
        return MatrixCheck.new(complete: false, unknown_reason: "stability matrix has no selected tests or mutants") if test_ids.empty? || mutant_ids.empty?
        return MatrixCheck.new(complete: false, unknown_reason: "stability matrix has fewer trial IDs than its consistency threshold") if trial_ids.length < @threshold
        return MatrixCheck.new(complete: false, unknown_reason: "stability matrix contains duplicate trial observations") if duplicate_observations

        known_tests = @corpus.tests.map(&:id)
        known_mutants = @corpus.mutants.map(&:id)
        return MatrixCheck.new(complete: false, unknown_reason: "stability matrix names an unknown test or mutant") unless (test_ids - known_tests).empty? && (mutant_ids - known_mutants).empty?

        complete = test_ids.all? do |test_id|
          mutant_ids.all? do |mutant_id|
            observations.fetch([test_id, mutant_id], []).length == trial_ids.length
          end
        end
        return MatrixCheck.new(complete: false, unknown_reason: "stability matrix is missing test × mutant × trial observations") unless complete

        MatrixCheck.new(complete: true, unknown_reason: nil)
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

          mutant_ids = (contribution.covered_mutants | contribution.killed_mutants).sort.freeze
          RerunCandidate.new(
            test_id: contribution.test_id,
            mutant_ids: mutant_ids,
            reason: reasons.map(&:serialize).join(","),
          )
        end.sort_by(&:test_id).freeze
      end
    end
  end
end
