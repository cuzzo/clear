# typed: strict
# frozen_string_literal: true

require "json"
require "sorbet-runtime"

module TestMiser
  module Evidence
    class InvalidOracleFacts < ArgumentError; end

    class SourceSpan < T::Struct
      extend T::Sig

      const :start_line, Integer
      const :start_column, Integer
      const :end_line, Integer
      const :end_column, Integer
      const :start_offset, T.nilable(Integer), default: nil
      const :end_offset, T.nilable(Integer), default: nil

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "start_line" => start_line,
          "start_column" => start_column,
          "end_line" => end_line,
          "end_column" => end_column,
          "start_offset" => start_offset,
          "end_offset" => end_offset,
        }.compact
      end
    end

    class OracleKind < T::Enum
      enums do
        Equality = new("EQUALITY")
        Identity = new("IDENTITY")
        Truthiness = new("TRUTHINESS")
        NullCheck = new("NULL_CHECK")
        ExceptionExpectation = new("EXCEPTION_EXPECTATION")
        Snapshot = new("SNAPSHOT")
        MockVerification = new("MOCK_VERIFICATION")
        Property = new("PROPERTY")
        CompileFailure = new("COMPILE_FAILURE")
        SubprocessOutput = new("SUBPROCESS_OUTPUT")
        Unknown = new("UNKNOWN")
      end
    end

    class OracleFact < T::Struct
      extend T::Sig

      const :oracle_id, String
      const :test_id, String
      const :oracle_kind, OracleKind
      const :oracle_span, SourceSpan
      const :expected_span, T.nilable(SourceSpan), default: nil
      const :actual_span, T.nilable(SourceSpan), default: nil
      const :framework, String
      const :confidence, Float
      const :source_file, T.nilable(String), default: nil

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "oracle_id" => oracle_id,
          "test_id" => test_id,
          "oracle_kind" => oracle_kind.serialize,
          "oracle_span" => oracle_span.to_h,
          "expected_span" => expected_span&.to_h,
          "actual_span" => actual_span&.to_h,
          "framework" => framework,
          "confidence" => confidence,
          "source_file" => source_file,
        }.compact
      end
    end

    class OracleFacts < T::Struct
      extend T::Sig

      const :facts, T::Array[OracleFact]
      const :metadata, T::Hash[String, T.untyped], default: {}

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {"schema" => "test-quality-oracle-facts/v1", "facts" => facts.map(&:to_h), "metadata" => metadata}
      end

      sig { params(path: String).returns(OracleFacts) }
      def self.load(path)
        payload = JSON.parse(File.read(path))
        unless payload["schema"] == "test-quality-oracle-facts/v1" && payload["facts"].is_a?(Array)
          raise InvalidOracleFacts, "#{path}: expected test-quality-oracle-facts/v1"
        end

        new(
          facts: payload.fetch("facts").map { |row| parse_fact(row) }.freeze,
          metadata: payload.fetch("metadata", {}),
        )
      rescue JSON::ParserError => error
        raise InvalidOracleFacts, "#{path}: invalid JSON: #{error.message}"
      end

      sig { params(path: String).void }
      def write(path)
        File.write(path, "#{JSON.pretty_generate(to_h)}\n")
      end

      class << self
        extend T::Sig

        private

        sig { params(row: T.untyped).returns(OracleFact) }
        def parse_fact(row)
          unless row.is_a?(Hash)
            raise InvalidOracleFacts, "oracle fact must be an object"
          end

          OracleFact.new(
            oracle_id: String(row.fetch("oracle_id")),
            test_id: String(row.fetch("test_id")),
            oracle_kind: OracleKind.deserialize(String(row.fetch("oracle_kind"))),
            oracle_span: parse_span(row.fetch("oracle_span")),
            expected_span: optional_span(row["expected_span"]),
            actual_span: optional_span(row["actual_span"]),
            framework: String(row.fetch("framework")),
            confidence: Float(row.fetch("confidence")),
            source_file: row["source_file"]&.to_s,
          )
        rescue KeyError, TypeError, ArgumentError => error
          raise InvalidOracleFacts, "invalid oracle fact: #{error.message}"
        end

        sig { params(row: T.untyped).returns(SourceSpan) }
        def parse_span(row)
          unless row.is_a?(Hash)
            raise InvalidOracleFacts, "oracle span must be an object"
          end

          SourceSpan.new(
            start_line: Integer(row.fetch("start_line")),
            start_column: Integer(row.fetch("start_column")),
            end_line: Integer(row.fetch("end_line")),
            end_column: Integer(row.fetch("end_column")),
            start_offset: optional_integer(row["start_offset"]),
            end_offset: optional_integer(row["end_offset"]),
          )
        end

        sig { params(value: T.untyped).returns(T.nilable(SourceSpan)) }
        def optional_span(value)
          return nil if value.nil?

          parse_span(value)
        end

        sig { params(value: T.untyped).returns(T.nilable(Integer)) }
        def optional_integer(value)
          return nil if value.nil?

          Integer(value)
        end
      end
    end

    module OracleFactProvider
      extend T::Sig
      extend T::Helpers
      interface!

      sig do
        abstract.params(test_id: String, source_path: String, language: String).returns(T::Array[OracleFact])
      end
      def facts(test_id:, source_path:, language:)
      end
    end

    class StaticOracleFactProvider
      extend T::Sig
      include OracleFactProvider

      sig { params(artifact: OracleFacts).void }
      def initialize(artifact)
        @artifact = artifact
      end

      sig do
        override.params(test_id: String, source_path: String, language: String).returns(T::Array[OracleFact])
      end
      def facts(test_id:, source_path:, language:)
        @artifact.facts.select do |fact|
          fact.test_id == test_id && (fact.source_file.nil? || fact.source_file == source_path)
        end
      end
    end

    class OracleMutationKind < T::Enum
      enums do
        DisableOracle = new("DISABLE_ORACLE")
        NegateBoolean = new("NEGATE_BOOLEAN")
        PerturbExpected = new("PERTURB_EXPECTED")
        RemoveInvocation = new("REMOVE_INVOCATION")
        BroadenException = new("BROADEN_EXCEPTION")
        RemoveVerification = new("REMOVE_VERIFICATION")
        PerturbSnapshot = new("PERTURB_SNAPSHOT")
      end
    end

    class OracleMutationPlan < T::Struct
      extend T::Sig

      const :oracle_id, String
      const :mutation, OracleMutationKind
      const :recognized, T::Boolean
      const :reason, String

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "oracle_id" => oracle_id,
          "mutation" => mutation.serialize,
          "recognized" => recognized,
          "reason" => reason,
        }
      end
    end

    class OracleRewrite < T::Struct
      extend T::Sig

      const :oracle_id, String
      const :mutation, OracleMutationKind
      const :recognized, T::Boolean
      const :applied, T::Boolean
      const :reason, String

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "oracle_id" => oracle_id,
          "mutation" => mutation.serialize,
          "recognized" => recognized,
          "applied" => applied,
          "reason" => reason,
        }
      end
    end

    class OracleMutationPlanner
      extend T::Sig

      PLANS = T.let({
        OracleKind::Equality => [OracleMutationKind::NegateBoolean, OracleMutationKind::PerturbExpected],
        OracleKind::Identity => [OracleMutationKind::NegateBoolean],
        OracleKind::Truthiness => [OracleMutationKind::NegateBoolean],
        OracleKind::NullCheck => [OracleMutationKind::NegateBoolean],
        OracleKind::ExceptionExpectation => [OracleMutationKind::RemoveInvocation, OracleMutationKind::BroadenException],
        OracleKind::Snapshot => [OracleMutationKind::PerturbSnapshot],
        OracleKind::MockVerification => [OracleMutationKind::RemoveVerification],
        OracleKind::Property => [OracleMutationKind::NegateBoolean],
        OracleKind::CompileFailure => [OracleMutationKind::PerturbExpected],
        OracleKind::SubprocessOutput => [OracleMutationKind::PerturbExpected],
      }.freeze, T::Hash[OracleKind, T::Array[OracleMutationKind]])

      sig { params(fact: OracleFact).returns(T::Array[OracleMutationPlan]) }
      def self.plan(fact)
        mutations = PLANS.fetch(fact.oracle_kind, [])
        return [OracleMutationPlan.new(
          oracle_id: fact.oracle_id,
          mutation: OracleMutationKind::DisableOracle,
          recognized: false,
          reason: "oracle kind is unsupported by the conservative planner",
        )] if mutations.empty?

        mutations.map do |mutation|
          OracleMutationPlan.new(
            oracle_id: fact.oracle_id,
            mutation: mutation,
            recognized: true,
            reason: "safe transformation requires the framework adapter",
          )
        end.freeze
      end
    end

    class OracleTrial < T::Struct
      extend T::Sig

      const :test_id, String
      const :oracle_id, String
      const :mutant_id, String
      const :killed, T::Boolean
      const :executed, T::Boolean

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "test_id" => test_id,
          "oracle_id" => oracle_id,
          "mutant_id" => mutant_id,
          "killed" => killed,
          "executed" => executed,
        }
      end
    end

    class OracleSensitivity < T::Struct
      extend T::Sig

      const :test_id, String
      const :oracle_id, String
      const :original_kills, T::Array[String]
      const :oracle_dependent_kills, T::Array[String]
      const :incidental_kills, T::Array[String]
      const :complete, T::Boolean
      const :unknown_reason, T.nilable(String)

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "test_id" => test_id,
          "oracle_id" => oracle_id,
          "original_kills" => original_kills,
          "oracle_dependent_kills" => oracle_dependent_kills,
          "incidental_kills" => incidental_kills,
          "complete" => complete,
          "unknown_reason" => unknown_reason,
        }
      end
    end

    class OracleSensitivityAnalysis < T::Struct
      extend T::Sig

      const :results, T::Array[OracleSensitivity]

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "schema" => "test-quality-evidence/oracle-sensitivity-v1",
          "summary" => {
            "oracles" => results.length,
            "complete_oracles" => results.count(&:complete),
            "oracle_dependent_kills" => results.sum { |result| result.oracle_dependent_kills.length },
            "incidental_kills" => results.sum { |result| result.incidental_kills.length },
          },
          "oracles" => results.map(&:to_h),
        }
      end
    end

    class OracleSensitivityAnalyzer
      extend T::Sig

      sig do
        params(
          facts: OracleFacts,
          original_kills: T::Hash[String, T::Array[String]],
          disabled_trials: T::Array[OracleTrial],
          rewrites: T::Array[OracleRewrite],
        ).returns(OracleSensitivityAnalysis)
      end
      def self.analyze(facts:, original_kills:, disabled_trials:, rewrites:)
        rewrite_by_id = rewrites.to_h { |rewrite| [rewrite.oracle_id, rewrite] }
        results = facts.facts.map do |fact|
          original = original_kills.fetch(fact.test_id, []).uniq.sort
          rewrite = rewrite_by_id[fact.oracle_id]
          trials = disabled_trials.select do |trial|
            trial.test_id == fact.test_id && trial.oracle_id == fact.oracle_id && original.include?(trial.mutant_id)
          end
          result_for(fact, original, trials, rewrite)
        end.freeze
        OracleSensitivityAnalysis.new(results: results)
      end

      class << self
        extend T::Sig

        private

        sig do
          params(
            fact: OracleFact,
            original: T::Array[String],
            trials: T::Array[OracleTrial],
            rewrite: T.nilable(OracleRewrite),
          ).returns(OracleSensitivity)
        end
        def result_for(fact, original, trials, rewrite)
          reason = rewrite_reason(rewrite)
          reason ||= trial_reason(original, trials)
          complete = reason.nil?
          disabled_kills = trials.select(&:killed).map(&:mutant_id).uniq.sort
          OracleSensitivity.new(
            test_id: fact.test_id,
            oracle_id: fact.oracle_id,
            original_kills: original,
            oracle_dependent_kills: complete ? (original - disabled_kills).sort.freeze : [].freeze,
            incidental_kills: complete ? (original & disabled_kills).sort.freeze : [].freeze,
            complete: complete,
            unknown_reason: reason,
          )
        end

        sig { params(rewrite: T.nilable(OracleRewrite)).returns(T.nilable(String)) }
        def rewrite_reason(rewrite)
          return "no safe oracle rewrite was supplied" if rewrite.nil?
          return "oracle rewrite was not recognized" unless rewrite.recognized
          return "oracle rewrite could not be applied" unless rewrite.applied

          nil
        end

        sig { params(original: T::Array[String], trials: T::Array[OracleTrial]).returns(T.nilable(String)) }
        def trial_reason(original, trials)
          return "oracle-disabled trials did not execute" unless trials.all?(&:executed)
          return "oracle-disabled attribution is incomplete" unless original.all? { |mutant_id| trials.any? { |trial| trial.mutant_id == mutant_id } }

          nil
        end
      end
    end
  end
end
