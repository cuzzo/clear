# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"
require_relative "../lib/test_miser/evidence/counterfactual"

class EvidenceCounterfactualTest < Minitest::Test
  Evidence = TestMiser::Evidence
  FIXTURE_ROOT = File.expand_path("fixtures/counterfactual", __dir__)
  PATCH_FIXTURE = File.join(FIXTURE_ROOT, "ruby", "production.patch")

  def test_assertion_failure_proves_only_when_the_result_parser_recognizes_it
    fake = FakeRunner.new([
      result(0), result(0, "#{'a' * 40}\n"), result(0), result(0), result(0), result(0), result(0),
      result(1, "Failure: expected new behavior"), result(0),
    ])
    result_value = runner(fake).run

    assert_equal Evidence::CounterfactualStatus::ProvesRevertedChange, result_value.status
    assert_equal false, result_value.baseline_detects_reversal
    assert_equal "new tests fail after the production change is reversed", result_value.reason
    assert_equal true, result_value.provenance&.clean_worktree
    assert_equal "a" * 40, result_value.provenance&.resolved_revision
    assert_equal File.expand_path(PATCH_FIXTURE), result_value.provenance&.production_patch_path
    refute_empty result_value.provenance&.production_patch_sha256.to_s
    assert_equal ["git", "worktree", "add", "--detach"], fake.commands.find { |command, _| command[0, 2] == ["git", "worktree"] }.first.first(4)
    assert_equal ["git", "worktree", "remove", "--force"], fake.commands.last.first.first(4)
    head_command = fake.commands.find { |command, _chdir| command == ["bundle", "exec", "test", "new"] }
    refute_equal Dir.tmpdir, head_command[1]
    assert_equal "test-quality-evidence/counterfactual-v1", result_value.to_h.fetch("schema")
  end

  def test_nonzero_unknown_failure_is_inconclusive_not_proof
    fake = FakeRunner.new([
      result(0), result(0), result(0), result(0), result(0), result(0), result(0),
      result(1, "unrelated command failure"),
    ])

    result_value = runner(fake).run

    assert_equal Evidence::CounterfactualStatus::Inconclusive, result_value.status
    assert_includes result_value.reason, "UNKNOWN_FAILURE"
  end

  def test_non_detecting_new_tests_and_detecting_baseline_are_distinguished
    fake = FakeRunner.new([
      result(0), result(0), result(0), result(0), result(0), result(0), result(0),
      result(0), result(1, "Failure: baseline detects the reversal"),
    ])

    result_value = runner(fake).run

    assert_equal Evidence::CounterfactualStatus::DoesNotDetectRevertedChange, result_value.status
    assert_equal true, result_value.baseline_detects_reversal
    assert_equal "new tests pass after the production change is reversed", result_value.reason
  end

  def test_baseline_must_pass_on_head_before_counterfactual_execution
    fake = FakeRunner.new([result(0), result(0), result(0), result(1, "Failure: baseline already fails")])

    result_value = runner(fake).run

    assert_equal Evidence::CounterfactualStatus::Inconclusive, result_value.status
    assert_equal "requested-revision selected-test result was ASSERTION_FAILURE, not PASSED", result_value.reason
    assert result_value.worktree&.success?
  end

  def test_baseline_command_without_head_verification_is_inconclusive
    request = request_for(baseline_head_command: nil)
    fake = FakeRunner.new([result(0), result(0), result(0)])

    result_value = Evidence::CounterfactualRunner.new(request, runner: fake).run

    assert_equal Evidence::CounterfactualStatus::Inconclusive, result_value.status
    assert_equal "baseline tests were not verified on the requested revision before reversal", result_value.reason
  end

  def test_head_reverse_build_timeout_and_infrastructure_failures_are_inconclusive
    head_fake = FakeRunner.new([result(0), result(0), result(0), result(1, "Failure: head")])
    head_result = Evidence::CounterfactualRunner.new(request_for, runner: head_fake).run
    assert_equal Evidence::CounterfactualStatus::Inconclusive, head_result.status
    assert_includes head_result.reason, "ASSERTION_FAILURE"

    reverse_fake = FakeRunner.new([result(0), result(0), result(0), result(0), result(0), result(1, "cannot apply")])
    reverse_result = Evidence::CounterfactualRunner.new(request_for, runner: reverse_fake).run
    assert_equal "production patch could not be reversed", reverse_result.reason

    build_fake = FakeRunner.new([result(0), result(0), result(0), result(0), result(0), result(0), result(1, "compile error")])
    build_result = Evidence::CounterfactualRunner.new(request_for, runner: build_fake).run
    assert_equal "reversed source does not build", build_result.reason

    timeout_fake = FakeRunner.new([result(0), result(0), result(0), result(0), result(0), result(0), result(0), result(1, "timeout", timed_out: true)])
    timeout_result = Evidence::CounterfactualRunner.new(request_for, runner: timeout_fake).run
    assert_includes timeout_result.reason, "TIMED_OUT"

    infrastructure_fake = FakeRunner.new([result(0), result(0), result(0), result(0), result(0), result(0), result(0), :raise])
    infrastructure_result = Evidence::CounterfactualRunner.new(request_for, runner: infrastructure_fake).run
    assert_includes infrastructure_result.reason, "INFRASTRUCTURE_FAILURE"
  end

  def test_missing_patch_and_dirty_worktree_are_inconclusive
    missing = Evidence::CounterfactualRequest.new(
      repository: Dir.tmpdir,
      production_patch_path: "does-not-exist.patch",
      head_command: ["true"],
      build_command: ["true"],
      new_test_command: ["true"],
    )
    missing_result = Evidence::CounterfactualRunner.new(missing, runner: FakeRunner.new([])).run
    assert_equal Evidence::CounterfactualStatus::Inconclusive, missing_result.status
    assert_includes missing_result.reason, "patch"

    dirty_fake = FakeRunner.new([result(0, " M lib/source.rb\n")])
    dirty_result = Evidence::CounterfactualRunner.new(request_for, runner: dirty_fake).run
    assert_equal Evidence::CounterfactualStatus::Inconclusive, dirty_result.status
    assert_equal "repository worktree is not clean", dirty_result.reason
  end

  def test_process_runner_enforces_timeout_and_output_bounds
    process = Evidence::ProcessCommandRunner.new
    timed_out = process.run(
      ["ruby", "-e", "sleep 1"],
      chdir: Dir.pwd,
      limits: Evidence::CommandLimits.new(timeout_seconds: 0.05, max_output_bytes: 100),
    )
    assert timed_out.timed_out
    refute timed_out.success?

    truncated = process.run(
      ["ruby", "-e", "STDOUT.write('x' * 100)"],
      chdir: Dir.pwd,
      limits: Evidence::CommandLimits.new(timeout_seconds: 2.0, max_output_bytes: 10),
    )
    assert truncated.output_truncated
    assert_operator truncated.stdout.bytesize, :<=, 10
    refute truncated.success?
  end

  def test_process_runner_kills_term_ignoring_process_within_hard_bound
    process = Evidence::ProcessCommandRunner.new
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    timed_out = process.run(
      ["ruby", "-e", 'Signal.trap("TERM", "IGNORE"); sleep 10'],
      chdir: Dir.pwd,
      limits: Evidence::CommandLimits.new(timeout_seconds: 0.05, max_output_bytes: 100),
    )
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

    assert timed_out.timed_out
    refute timed_out.success?
    assert_operator elapsed, :<, 1.0
  end

  def test_real_ruby_and_python_fixture_repositories_prove_the_reversed_change
    {
      "ruby" => {
        executable: "ruby",
        test: ["ruby", "test/new_test.rb"],
        baseline: ["ruby", "test/baseline_test.rb"],
        build: ["ruby", "-c", "lib/calculator.rb"],
      },
      "python" => {
        executable: "python3",
        test: ["python3", "test/new_test.py"],
        baseline: ["python3", "test/baseline_test.py"],
        build: ["python3", "-m", "py_compile", "lib/calculator.py"],
      },
    }.each do |language, commands|
      repository = fixture_repository(language)
      request = Evidence::CounterfactualRequest.new(
        repository: repository,
        production_patch_path: File.join(repository, "production.patch"),
        head_command: commands.fetch(:test),
        baseline_head_command: commands.fetch(:baseline),
        build_command: commands.fetch(:build),
        new_test_command: commands.fetch(:test),
        baseline_test_command: commands.fetch(:baseline),
        limits: Evidence::CommandLimits.new(timeout_seconds: 5.0, max_output_bytes: 100_000),
      )

      result_value = Evidence::CounterfactualRunner.new(request).run

      assert_equal Evidence::CounterfactualStatus::ProvesRevertedChange, result_value.status, language
      assert_equal false, result_value.baseline_detects_reversal, language
      assert_equal true, result_value.provenance&.clean_worktree, language
    ensure
      FileUtils.remove_entry(repository) if repository && File.directory?(repository)
    end
  end

  def test_command_result_and_parser_are_explicit_typed_boundaries
    parser = Evidence::DefaultTestResultParser.new
    assert_equal Evidence::TestOutcome::Passed, parser.parse(result(0))
    assert_equal Evidence::TestOutcome::AssertionFailure, parser.parse(result(1, "Failure: expected"))
    assert_equal Evidence::TestOutcome::AssertionFailure, parser.parse(result(1, "E       assert 1 == 2"))
    assert_equal Evidence::TestOutcome::AssertionFailure, parser.parse(result(1, "AssertionFailedError: expected <2> but was <1>"))
    assert_equal Evidence::TestOutcome::Crash, parser.parse(result(1, "NoMethodError"))
    assert_equal Evidence::TestOutcome::TimedOut, parser.parse(result(1, "", timed_out: true))
    assert_equal Evidence::TestOutcome::ResourceLimited, parser.parse(result(1, "", output_truncated: true))
    assert_equal Evidence::TestOutcome::InfrastructureFailure, parser.parse(result(1, "", executed: false))
    refute Evidence::CommandResult.new(status: 0, stdout: "", stderr: "", executed: false).success?
  end

  private

  def request_for(baseline_head_command: ["bundle", "exec", "test", "baseline"])
    Evidence::CounterfactualRequest.new(
      repository: Dir.tmpdir,
      production_patch_path: PATCH_FIXTURE,
      head_command: ["bundle", "exec", "test", "new"],
      baseline_head_command: baseline_head_command,
      build_command: ["bundle", "exec", "build"],
      new_test_command: ["bundle", "exec", "test", "new"],
      baseline_test_command: ["bundle", "exec", "test", "baseline"],
    )
  end

  def runner(fake)
    Evidence::CounterfactualRunner.new(request_for, runner: fake)
  end

  def result(status, output = "", timed_out: false, output_truncated: false, executed: true)
    Evidence::CommandResult.new(
      status: status,
      stdout: output,
      stderr: status.zero? ? "" : output,
      timed_out: timed_out,
      output_truncated: output_truncated,
      executed: executed,
    )
  end

  def fixture_repository(language)
    source = File.join(FIXTURE_ROOT, language)
    repository = Dir.mktmpdir("test-miser-#{language}-repository-")
    FileUtils.cp_r(File.join(source, "."), repository)
    run_git(repository, "init", "-q")
    run_git(repository, "add", ".")
    run_git(repository, "-c", "user.name=Test Miser", "-c", "user.email=test-miser@example.test", "commit", "-qm", "fixture")
    repository
  end

  def run_git(repository, *args)
    _stdout, stderr, status = Open3.capture3("git", *args, chdir: repository)
    raise stderr unless status.success?
  end

  class FakeRunner
    include Evidence::CommandRunner

    attr_reader :commands

    def initialize(results)
      @results = results
      @commands = []
    end

    def run(command, chdir:, limits:)
      @commands << [command, chdir, limits]
      result = @results.shift || Evidence::CommandResult.new(status: 0, stdout: "", stderr: "")
      raise "runner unavailable" if result == :raise

      if command[0, 3] == ["git", "rev-parse", "--verify"] && result.stdout.empty?
        result = result.with(stdout: "#{'a' * 40}\n")
      end

      result
    end
  end
end
