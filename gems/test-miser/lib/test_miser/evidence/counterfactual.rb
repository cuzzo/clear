# typed: strict
# frozen_string_literal: true

require "digest"
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
      const :timed_out, T::Boolean, default: false
      const :output_truncated, T::Boolean, default: false

      sig { returns(T::Boolean) }
      def success?
        executed && status.zero? && !timed_out && !output_truncated
      end

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "status" => status,
          "stdout" => stdout,
          "stderr" => stderr,
          "executed" => executed,
          "timed_out" => timed_out,
          "output_truncated" => output_truncated,
        }
      end
    end

    class CommandLimits < T::Struct
      const :timeout_seconds, Float, default: 60.0
      const :max_output_bytes, Integer, default: 1_048_576
      const :cpu_seconds, T.nilable(Integer), default: nil
      const :memory_bytes, T.nilable(Integer), default: nil
    end

    module CommandRunner
      extend T::Sig
      extend T::Helpers
      interface!

      sig do
        abstract.params(
          command: T::Array[String],
          chdir: String,
          limits: CommandLimits,
        ).returns(CommandResult)
      end
      def run(command, chdir:, limits:)
      end
    end

    class CapturedOutput < T::Struct
      const :text, String
      const :truncated, T::Boolean
    end

    class ProcessCommandRunner
      extend T::Sig
      include CommandRunner

      TERMINATION_GRACE_SECONDS = T.let(0.1, Float)
      PIPE_CLEANUP_GRACE_SECONDS = T.let(0.1, Float)

      sig do
        override.params(
          command: T::Array[String],
          chdir: String,
          limits: CommandLimits,
        ).returns(CommandResult)
      end
      def run(command, chdir:, limits:)
        raise ArgumentError, "timeout_seconds must be positive" unless limits.timeout_seconds.positive?
        raise ArgumentError, "max_output_bytes must be positive" unless limits.max_output_bytes.positive?

        options = {chdir: chdir, pgroup: true}
        options[:rlimit_cpu] = limits.cpu_seconds unless limits.cpu_seconds.nil?
        options[:rlimit_as] = limits.memory_bytes unless limits.memory_bytes.nil?
        stdin, stdout, stderr, wait_thread = T.unsafe(Open3).popen3(*command, **options)
        stdin.close
        stdout_thread = Thread.new { capture_output(stdout, limits.max_output_bytes) }
        stderr_thread = Thread.new { capture_output(stderr, limits.max_output_bytes) }
        timed_out = false
        status = wait_for_exit(wait_thread, limits.timeout_seconds)
        if status.nil?
          timed_out = true
          signal_process_group(wait_thread, "TERM")
          status = wait_for_exit(wait_thread, TERMINATION_GRACE_SECONDS)
        end
        if status.nil?
          signal_process_group(wait_thread, "KILL")
          status = wait_for_exit(wait_thread, TERMINATION_GRACE_SECONDS)
        end
        captured_stdout = finish_capture(stdout_thread, stdout)
        captured_stderr = finish_capture(stderr_thread, stderr)
        CommandResult.new(
          status: status&.exitstatus || 1,
          stdout: captured_stdout.text,
          stderr: captured_stderr.text,
          timed_out: timed_out,
          output_truncated: captured_stdout.truncated || captured_stderr.truncated,
        )
      rescue StandardError
        raise
      ensure
        close_io(stdout)
        close_io(stderr)
        close_io(stdin)
        cleanup_thread(stdout_thread)
        cleanup_thread(stderr_thread)
        cleanup_process(wait_thread)
      end

      private

      sig { params(io: IO, limit: Integer).returns(CapturedOutput) }
      def capture_output(io, limit)
        output = T.let(+"", String)
        truncated = T.let(false, T::Boolean)
        loop do
          chunk = io.readpartial([4_096, limit - output.bytesize + 1].max)
          if output.bytesize + chunk.bytesize > limit
            output << chunk.byteslice(0, limit - output.bytesize).to_s
            truncated = true
            break
          end
          output << chunk
        end
        CapturedOutput.new(text: output, truncated: truncated)
      rescue EOFError, IOError
        CapturedOutput.new(text: T.must(output), truncated: T.must(truncated))
      ensure
        io.close unless io.closed?
      end

      sig { params(wait_thread: Thread, timeout_seconds: Float).returns(T.nilable(Process::Status)) }
      def wait_for_exit(wait_thread, timeout_seconds)
        return nil unless wait_thread.join(timeout_seconds)

        T.cast(wait_thread.value, Process::Status)
      end

      sig { params(thread: Thread, io: IO).returns(CapturedOutput) }
      def finish_capture(thread, io)
        return T.cast(thread.value, CapturedOutput) if thread.join(PIPE_CLEANUP_GRACE_SECONDS)

        close_io(io)
        thread.kill
        thread.join(PIPE_CLEANUP_GRACE_SECONDS)
        CapturedOutput.new(text: "", truncated: true)
      rescue StandardError
        close_io(io)
        cleanup_thread(thread)
        CapturedOutput.new(text: "", truncated: true)
      end

      sig { params(wait_thread: Thread, signal: String).void }
      def signal_process_group(wait_thread, signal)
        Process.kill(signal, -T.unsafe(wait_thread).pid)
      rescue Errno::ESRCH
        nil
      end

      sig { params(thread: T.nilable(Thread)).void }
      def cleanup_thread(thread)
        return if thread.nil? || !thread.alive?

        thread.kill
        thread.join(PIPE_CLEANUP_GRACE_SECONDS)
      rescue StandardError
        nil
      end

      sig { params(wait_thread: T.nilable(Thread)).void }
      def cleanup_process(wait_thread)
        return if wait_thread.nil? || !wait_thread.alive?

        signal_process_group(wait_thread, "TERM")
        return if wait_thread.join(TERMINATION_GRACE_SECONDS)

        signal_process_group(wait_thread, "KILL")
        wait_thread.join(TERMINATION_GRACE_SECONDS)
      rescue StandardError
        nil
      end

      sig { params(io: T.nilable(IO)).void }
      def close_io(io)
        return if io.nil? || io.closed?

        io.close
      rescue IOError
        nil
      end
    end

    class TestOutcome < T::Enum
      enums do
        Passed = new("PASSED")
        AssertionFailure = new("ASSERTION_FAILURE")
        Crash = new("CRASH")
        TimedOut = new("TIMED_OUT")
        ResourceLimited = new("RESOURCE_LIMITED")
        InfrastructureFailure = new("INFRASTRUCTURE_FAILURE")
        UnknownFailure = new("UNKNOWN_FAILURE")
      end
    end

    module TestResultParser
      extend T::Sig
      extend T::Helpers
      interface!

      sig { abstract.params(result: CommandResult).returns(TestOutcome) }
      def parse(result)
      end
    end

    class DefaultTestResultParser
      extend T::Sig
      include TestResultParser

      ASSERTION_MARKERS = T.let(
        /(?:Minitest::Assertion|RSpec::Expectations::ExpectationNotMetError|AssertionError:|^Failure:|^Expected:)/,
        Regexp,
      )
      CRASH_MARKERS = T.let(/(?:Segmentation fault|NoMethodError|Traceback \(most recent call last\))/, Regexp)

      sig { override.params(result: CommandResult).returns(TestOutcome) }
      def parse(result)
        return TestOutcome::InfrastructureFailure unless result.executed
        return TestOutcome::TimedOut if result.timed_out
        return TestOutcome::ResourceLimited if result.output_truncated
        return TestOutcome::Passed if result.status.zero?

        output = "#{result.stdout}\n#{result.stderr}"
        return TestOutcome::AssertionFailure if output.match?(ASSERTION_MARKERS)
        return TestOutcome::Crash if output.match?(CRASH_MARKERS)

        TestOutcome::UnknownFailure
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
      const :baseline_head_command, T.nilable(T::Array[String]), default: nil
      const :baseline_test_command, T.nilable(T::Array[String]), default: nil
      const :revision, String, default: "HEAD"
      const :test_result_parser, TestResultParser, factory: -> { DefaultTestResultParser.new }
      const :limits, CommandLimits, factory: -> { CommandLimits.new }
      const :allow_dirty, T::Boolean, default: false
    end

    class CounterfactualProvenance < T::Struct
      extend T::Sig

      const :repository, String
      const :requested_revision, String
      const :resolved_revision, T.nilable(String)
      const :production_patch_path, String
      const :production_patch_sha256, T.nilable(String)
      const :clean_worktree, T::Boolean
      const :worktree_path, T.nilable(String)

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "repository" => repository,
          "requested_revision" => requested_revision,
          "resolved_revision" => resolved_revision,
          "production_patch_path" => production_patch_path,
          "production_patch_sha256" => production_patch_sha256,
          "clean_worktree" => clean_worktree,
          "worktree_path" => worktree_path,
        }.compact
      end
    end

    class CounterfactualResult < T::Struct
      extend T::Sig

      const :status, CounterfactualStatus
      const :head, CommandResult
      const :repository_status, CommandResult, default: CommandResult.new(status: 125, stdout: "", stderr: "not run", executed: false)
      const :revision_resolution, CommandResult, default: CommandResult.new(status: 125, stdout: "", stderr: "not run", executed: false)
      const :baseline_head, T.nilable(CommandResult), default: nil
      const :worktree, T.nilable(CommandResult)
      const :reverse_patch, T.nilable(CommandResult)
      const :build, T.nilable(CommandResult)
      const :new_tests, T.nilable(CommandResult)
      const :baseline_tests, T.nilable(CommandResult)
      const :baseline_detects_reversal, T.nilable(T::Boolean)
      const :provenance, T.nilable(CounterfactualProvenance), default: nil
      const :reason, String

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "schema" => "test-quality-evidence/counterfactual-v1",
          "status" => status.serialize,
          "repository_status" => repository_status.to_h,
          "revision_resolution" => revision_resolution.to_h,
          "baseline_head" => baseline_head&.to_h,
          "head" => head.to_h,
          "worktree" => worktree&.to_h,
          "reverse_patch" => reverse_patch&.to_h,
          "build" => build&.to_h,
          "new_tests" => new_tests&.to_h,
          "baseline_tests" => baseline_tests&.to_h,
          "baseline_detects_reversal" => baseline_detects_reversal,
          "provenance" => provenance&.to_h,
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
        patch_path = File.expand_path(@request.production_patch_path, @request.repository)
        patch_sha256 = patch_digest(patch_path)
        provenance = provenance_for(
          patch_path: patch_path,
          patch_sha256: patch_sha256,
          resolved_revision: nil,
          clean_worktree: false,
          worktree_path: nil,
        )
        not_run = not_executed_result("not run")
        return inconclusive(
          head: not_run,
          provenance: provenance,
          reason: "production patch does not exist or could not be hashed",
        ) if patch_sha256.nil?

        repository_status = safe_run(
          ["git", "status", "--porcelain=v1", "--untracked-files=all"],
          @request.repository,
        )
        provenance = provenance_for(
          patch_path: patch_path,
          patch_sha256: patch_sha256,
          resolved_revision: nil,
          clean_worktree: repository_status.success? && repository_status.stdout.empty?,
          worktree_path: nil,
        )
        return inconclusive(
          head: not_run,
          repository_status: repository_status,
          provenance: provenance,
          reason: "repository worktree status could not be determined",
        ) unless repository_status.executed && repository_status.success?
        if !@request.allow_dirty && !repository_status.stdout.empty?
          return inconclusive(
            head: not_run,
            repository_status: repository_status,
            provenance: provenance,
            reason: "repository worktree is not clean",
          )
        end

        revision_resolution = safe_run(
          ["git", "rev-parse", "--verify", "#{@request.revision}^{commit}"],
          @request.repository,
        )
        return inconclusive(
          head: not_run,
          repository_status: repository_status,
          revision_resolution: revision_resolution,
          provenance: provenance,
          reason: "requested revision could not be resolved",
        ) unless revision_resolution.success?

        resolved_revision = revision_resolution.stdout.strip
        provenance = provenance_for(
          patch_path: patch_path,
          patch_sha256: patch_sha256,
          resolved_revision: resolved_revision,
          clean_worktree: repository_status.stdout.empty?,
          worktree_path: nil,
        )
        head = safe_run(@request.head_command, @request.repository)
        head_outcome = parse_result(head)
        return inconclusive(
          head: head,
          repository_status: repository_status,
          revision_resolution: revision_resolution,
          provenance: provenance,
          reason: "current selected-test result was #{head_outcome.serialize}, not PASSED",
        ) unless head_outcome == TestOutcome::Passed

        baseline_head = nil
        unless @request.baseline_test_command.nil?
          if @request.baseline_head_command.nil?
            return inconclusive(
              head: head,
              repository_status: repository_status,
              revision_resolution: revision_resolution,
              provenance: provenance,
              reason: "baseline tests were not verified on the unreversed source",
            )
          end
          baseline_head = safe_run(T.must(@request.baseline_head_command), @request.repository)
          baseline_head_outcome = parse_result(baseline_head)
          return inconclusive(
            head: head,
            repository_status: repository_status,
            revision_resolution: revision_resolution,
            baseline_head: baseline_head,
            provenance: provenance,
            reason: "current baseline-test result was #{baseline_head_outcome.serialize}, not PASSED",
          ) unless baseline_head_outcome == TestOutcome::Passed
        end

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
          provenance = provenance_for(
            patch_path: patch_path,
            patch_sha256: patch_sha256,
            resolved_revision: resolved_revision,
            clean_worktree: repository_status.stdout.empty?,
            worktree_path: worktree_path,
          )
          return inconclusive(
            head: head,
            repository_status: repository_status,
            revision_resolution: revision_resolution,
            baseline_head: baseline_head,
            worktree: worktree,
            provenance: provenance,
            reason: "isolated worktree could not be created",
          ) unless worktree.success?

          reverse_patch = safe_run(
            ["git", "apply", "--reverse", "--whitespace=nowarn", patch_path],
            worktree_path,
          )
          return inconclusive(
            head: head,
            repository_status: repository_status,
            revision_resolution: revision_resolution,
            baseline_head: baseline_head,
            worktree: worktree,
            reverse_patch: reverse_patch,
            provenance: provenance,
            reason: "production patch could not be reversed",
          ) unless reverse_patch.success?

          build = safe_run(@request.build_command, worktree_path)
          return inconclusive(
            head: head,
            repository_status: repository_status,
            revision_resolution: revision_resolution,
            baseline_head: baseline_head,
            worktree: worktree,
            reverse_patch: reverse_patch,
            build: build,
            provenance: provenance,
            reason: "reversed source does not build",
          ) unless build.success?

          new_tests = safe_run(@request.new_test_command, worktree_path)
          new_outcome = parse_result(new_tests)
          return inconclusive(
            head: head,
            repository_status: repository_status,
            revision_resolution: revision_resolution,
            baseline_head: baseline_head,
            worktree: worktree,
            reverse_patch: reverse_patch,
            build: build,
            new_tests: new_tests,
            provenance: provenance,
            reason: "reversed new-test result was #{new_outcome.serialize}, not an expected assertion failure or pass",
          ) unless [TestOutcome::Passed, TestOutcome::AssertionFailure].include?(new_outcome)

          unless @request.baseline_test_command.nil?
            baseline_tests = safe_run(T.must(@request.baseline_test_command), worktree_path)
            baseline_outcome = parse_result(baseline_tests)
            return inconclusive(
              head: head,
              repository_status: repository_status,
              revision_resolution: revision_resolution,
              baseline_head: baseline_head,
              worktree: worktree,
              reverse_patch: reverse_patch,
              build: build,
              new_tests: new_tests,
              baseline_tests: baseline_tests,
              provenance: provenance,
              reason: "reversed baseline-test result was #{baseline_outcome.serialize}, not PASSED or an expected assertion failure",
            ) unless [TestOutcome::Passed, TestOutcome::AssertionFailure].include?(baseline_outcome)
          end

          result_status = new_outcome == TestOutcome::Passed ?
            CounterfactualStatus::DoesNotDetectRevertedChange : CounterfactualStatus::ProvesRevertedChange
          CounterfactualResult.new(
            status: result_status,
            head: head,
            repository_status: repository_status,
            revision_resolution: revision_resolution,
            baseline_head: baseline_head,
            worktree: worktree,
            reverse_patch: reverse_patch,
            build: build,
            new_tests: new_tests,
            baseline_tests: baseline_tests,
            baseline_detects_reversal: baseline_tests.nil? ? nil : parse_result(baseline_tests) == TestOutcome::AssertionFailure,
            provenance: provenance,
            reason: new_outcome == TestOutcome::Passed ? "new tests pass after the production change is reversed" :
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
        @runner.run(command, chdir: chdir, limits: @request.limits)
      rescue StandardError => error
        CommandResult.new(status: 127, stdout: "", stderr: error.message, executed: false)
      end

      sig { params(result: CommandResult).returns(TestOutcome) }
      def parse_result(result)
        @request.test_result_parser.parse(result)
      rescue StandardError
        TestOutcome::InfrastructureFailure
      end

      sig { params(path: String).returns(T.nilable(String)) }
      def patch_digest(path)
        Digest::SHA256.file(path).hexdigest
      rescue SystemCallError
        nil
      end

      sig { params(reason: String).returns(CommandResult) }
      def not_executed_result(reason)
        CommandResult.new(status: 125, stdout: "", stderr: reason, executed: false)
      end

      sig do
        params(
          patch_path: String,
          patch_sha256: T.nilable(String),
          resolved_revision: T.nilable(String),
          clean_worktree: T::Boolean,
          worktree_path: T.nilable(String),
        ).returns(CounterfactualProvenance)
      end
      def provenance_for(patch_path:, patch_sha256:, resolved_revision:, clean_worktree:, worktree_path:)
        CounterfactualProvenance.new(
          repository: @request.repository,
          requested_revision: @request.revision,
          resolved_revision: resolved_revision,
          production_patch_path: patch_path,
          production_patch_sha256: patch_sha256,
          clean_worktree: clean_worktree,
          worktree_path: worktree_path,
        )
      end

      sig do
        params(
          head: CommandResult,
          reason: String,
          repository_status: CommandResult,
          revision_resolution: CommandResult,
          baseline_head: T.nilable(CommandResult),
          worktree: T.nilable(CommandResult),
          reverse_patch: T.nilable(CommandResult),
          build: T.nilable(CommandResult),
          new_tests: T.nilable(CommandResult),
          baseline_tests: T.nilable(CommandResult),
          provenance: T.nilable(CounterfactualProvenance),
        ).returns(CounterfactualResult)
      end
      def inconclusive(
        head:, reason:, repository_status: not_executed_result("not run"),
        revision_resolution: not_executed_result("not run"), baseline_head: nil,
        worktree: nil, reverse_patch: nil, build: nil, new_tests: nil, baseline_tests: nil, provenance: nil
      )
        CounterfactualResult.new(
          status: CounterfactualStatus::Inconclusive,
          head: head,
          repository_status: repository_status,
          revision_resolution: revision_resolution,
          baseline_head: baseline_head,
          worktree: worktree,
          reverse_patch: reverse_patch,
          build: build,
          new_tests: new_tests,
          baseline_tests: baseline_tests,
          baseline_detects_reversal: nil,
          provenance: provenance,
          reason: reason,
        )
      end
    end
  end
end
