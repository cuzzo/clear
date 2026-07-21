# typed: strict
# frozen_string_literal: true

require "open3"
require "sorbet-runtime"
require "tmpdir"

module TestMiser
  module Evidence
    class CommandResult < T::Struct
      extend T::Sig

      const :status, Integer
      const :stdout, String
      const :stderr, String
      const :executed, T::Boolean, default: true

      sig { returns(T::Boolean) }
      def success?
        executed && status.zero?
      end

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {"status" => status, "stdout" => stdout, "stderr" => stderr, "executed" => executed}
      end
    end

    module CommandRunner
      extend T::Sig
      extend T::Helpers
      interface!

      sig { abstract.params(command: T::Array[String], chdir: String).returns(CommandResult) }
      def run(command, chdir:)
      end
    end

    class ProcessCommandRunner
      extend T::Sig
      include CommandRunner

      sig { override.params(command: T::Array[String], chdir: String).returns(CommandResult) }
      def run(command, chdir:)
        stdout, stderr, status = T.unsafe(Open3).capture3(*command, chdir: chdir)
        CommandResult.new(status: status.exitstatus || 1, stdout: stdout, stderr: stderr)
      end
    end

    class CounterfactualStatus < T::Enum
      enums do
        ProvesRevertedChange = new("PROVES_REVERTED_CHANGE")
        DoesNotDetectRevertedChange = new("DOES_NOT_DETECT_REVERTED_CHANGE")
        Inconclusive = new("INCONCLUSIVE")
      end
    end

    class CounterfactualRequest < T::Struct
      const :repository, String
      const :production_patch_path, String
      const :head_command, T::Array[String]
      const :build_command, T::Array[String]
      const :new_test_command, T::Array[String]
      const :baseline_test_command, T.nilable(T::Array[String]), default: nil
      const :revision, String, default: "HEAD"
    end

    class CounterfactualResult < T::Struct
      extend T::Sig

      const :status, CounterfactualStatus
      const :head, CommandResult
      const :worktree, T.nilable(CommandResult)
      const :reverse_patch, T.nilable(CommandResult)
      const :build, T.nilable(CommandResult)
      const :new_tests, T.nilable(CommandResult)
      const :baseline_tests, T.nilable(CommandResult)
      const :baseline_detects_reversal, T.nilable(T::Boolean)
      const :reason, String

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "schema" => "test-quality-evidence/counterfactual-v1",
          "status" => status.serialize,
          "head" => head.to_h,
          "worktree" => worktree&.to_h,
          "reverse_patch" => reverse_patch&.to_h,
          "build" => build&.to_h,
          "new_tests" => new_tests&.to_h,
          "baseline_tests" => baseline_tests&.to_h,
          "baseline_detects_reversal" => baseline_detects_reversal,
          "reason" => reason,
        }
      end
    end

    class CounterfactualRunner
      extend T::Sig

      sig { params(request: CounterfactualRequest, runner: CommandRunner).void }
      def initialize(request, runner: ProcessCommandRunner.new)
        @request = request
        @runner = runner
        @temporary_root = T.let(nil, T.nilable(String))
      end

      sig { returns(CounterfactualResult) }
      def run
        head = safe_run(@request.head_command, @request.repository)
        return inconclusive(head: head, reason: "selected tests do not pass on the current source") unless head.success?

        worktree = nil
        reverse_patch = nil
        build = nil
        new_tests = nil
        baseline_tests = nil
        worktree_path = nil
        begin
          worktree_path = temporary_worktree_path
          worktree = safe_run(
            ["git", "worktree", "add", "--detach", worktree_path, @request.revision],
            @request.repository,
          )
          return inconclusive(head: head, worktree: worktree, reason: "isolated worktree could not be created") unless worktree.success?

          patch_path = File.expand_path(@request.production_patch_path, @request.repository)
          reverse_patch = safe_run(
            ["git", "apply", "--reverse", "--whitespace=nowarn", patch_path],
            worktree_path,
          )
          return inconclusive(
            head: head,
            worktree: worktree,
            reverse_patch: reverse_patch,
            reason: "production patch could not be reversed",
          ) unless reverse_patch.success?

          build = safe_run(@request.build_command, worktree_path)
          return inconclusive(
            head: head,
            worktree: worktree,
            reverse_patch: reverse_patch,
            build: build,
            reason: "reversed source does not build",
          ) unless build.success?

          new_tests = safe_run(@request.new_test_command, worktree_path)
          return inconclusive(
            head: head,
            worktree: worktree,
            reverse_patch: reverse_patch,
            build: build,
            new_tests: new_tests,
            reason: "new-test command could not execute",
          ) unless new_tests.executed

          unless @request.baseline_test_command.nil?
            baseline_tests = safe_run(T.must(@request.baseline_test_command), worktree_path)
            return inconclusive(
              head: head,
              worktree: worktree,
              reverse_patch: reverse_patch,
              build: build,
              new_tests: new_tests,
              baseline_tests: baseline_tests,
              reason: "baseline-test command could not execute",
            ) unless baseline_tests.executed
          end

          result_status = new_tests.success? ?
            CounterfactualStatus::DoesNotDetectRevertedChange :
            CounterfactualStatus::ProvesRevertedChange
          CounterfactualResult.new(
            status: result_status,
            head: head,
            worktree: worktree,
            reverse_patch: reverse_patch,
            build: build,
            new_tests: new_tests,
            baseline_tests: baseline_tests,
            baseline_detects_reversal: baseline_tests.nil? ? nil : !baseline_tests.success?,
            reason: new_tests.success? ? "new tests pass after the production change is reversed" :
              "new tests fail after the production change is reversed",
          )
        ensure
          safe_run(["git", "worktree", "remove", "--force", worktree_path], @request.repository) if worktree_path
          cleanup_temporary_root
        end
      end

      private

      sig { returns(String) }
      def temporary_worktree_path
        @temporary_root = Dir.mktmpdir("test-miser-counterfactual-")
        File.join(@temporary_root, "worktree")
      end

      sig { void }
      def cleanup_temporary_root
        root = @temporary_root
        return if root.nil?

        Dir.rmdir(root)
      rescue SystemCallError
        nil
      ensure
        @temporary_root = nil
      end

      sig { params(command: T::Array[String], chdir: String).returns(CommandResult) }
      def safe_run(command, chdir)
        @runner.run(command, chdir: chdir)
      rescue StandardError => error
        CommandResult.new(status: 127, stdout: "", stderr: error.message, executed: false)
      end

      sig do
        params(
          head: CommandResult,
          reason: String,
          worktree: T.nilable(CommandResult),
          reverse_patch: T.nilable(CommandResult),
          build: T.nilable(CommandResult),
          new_tests: T.nilable(CommandResult),
          baseline_tests: T.nilable(CommandResult),
        ).returns(CounterfactualResult)
      end
      def inconclusive(head:, reason:, worktree: nil, reverse_patch: nil, build: nil, new_tests: nil, baseline_tests: nil)
        CounterfactualResult.new(
          status: CounterfactualStatus::Inconclusive,
          head: head,
          worktree: worktree,
          reverse_patch: reverse_patch,
          build: build,
          new_tests: new_tests,
          baseline_tests: baseline_tests,
          baseline_detects_reversal: nil,
          reason: reason,
        )
      end
    end
  end
end
