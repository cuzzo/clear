# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/test_miser/evidence/counterfactual"

class EvidenceCounterfactualTest < Minitest::Test
  Evidence = TestMiser::Evidence

  def test_proves_reverted_change_and_records_baseline_comparison
    fake = FakeRunner.new([
      result(0, "head"),
      result(0, "worktree"),
      result(0, "reverse"),
      result(0, "build"),
      result(1, "new test failed"),
      result(0, "baseline passed"),
    ])
    result_value = runner(fake).run

    assert_equal Evidence::CounterfactualStatus::ProvesRevertedChange, result_value.status
    assert result_value.head.success?
    assert_equal false, result_value.baseline_detects_reversal
    assert_equal "new tests fail after the production change is reversed", result_value.reason
    assert_equal ["git", "worktree", "add", "--detach"], fake.commands.fetch(1).first.first(4)
    assert_equal ["git", "worktree", "remove", "--force"], fake.commands.last.first.first(4)
    assert_equal "test-quality-evidence/counterfactual-v1", result_value.to_h.fetch("schema")
  end

  def test_non_detecting_new_tests_and_detecting_baseline_are_distinguished
    fake = FakeRunner.new([
      result(0), result(0), result(0), result(0), result(0), result(1),
    ])

    result_value = runner(fake).run

    assert_equal Evidence::CounterfactualStatus::DoesNotDetectRevertedChange, result_value.status
    assert_equal true, result_value.baseline_detects_reversal
    assert_equal "new tests pass after the production change is reversed", result_value.reason
  end

  def test_head_failure_is_inconclusive_without_creating_a_worktree
    fake = FakeRunner.new([result(1, "head failed")])

    result_value = runner(fake).run

    assert_equal Evidence::CounterfactualStatus::Inconclusive, result_value.status
    assert_nil result_value.worktree
    assert_nil result_value.reverse_patch
    assert_equal "selected tests do not pass on the current source", result_value.reason
    assert_equal 1, fake.commands.length
  end

  def test_reverse_and_build_failures_are_inconclusive
    reverse_fake = FakeRunner.new([result(0), result(0), result(1, "cannot apply")])
    reverse_result = runner(reverse_fake).run
    assert_equal Evidence::CounterfactualStatus::Inconclusive, reverse_result.status
    assert_equal "production patch could not be reversed", reverse_result.reason
    refute_nil reverse_result.reverse_patch

    build_fake = FakeRunner.new([result(0), result(0), result(0), result(1, "compile error")])
    build_result = runner(build_fake).run
    assert_equal Evidence::CounterfactualStatus::Inconclusive, build_result.status
    assert_equal "reversed source does not build", build_result.reason
    refute_nil build_result.build
  end

  def test_command_failures_to_execute_are_inconclusive_and_cleanup_is_best_effort
    fake = FakeRunner.new([result(0), result(0), result(0), result(0), :raise])

    result_value = runner(fake).run

    assert_equal Evidence::CounterfactualStatus::Inconclusive, result_value.status
    assert_equal "new-test command could not execute", result_value.reason
    refute result_value.new_tests&.executed
    assert_equal 6, fake.commands.length
  end

  def test_process_command_runner_and_command_result_are_typed_boundaries
    command_result = Evidence::ProcessCommandRunner.new.run(["ruby", "-e", "STDOUT.write('ok')"], chdir: Dir.pwd)

    assert command_result.success?
    assert_equal "ok", command_result.stdout
    refute Evidence::CommandResult.new(status: 0, stdout: "", stderr: "", executed: false).success?
    assert_equal false, Evidence::CommandResult.new(status: 1, stdout: "", stderr: "").success?
  end

  private

  def runner(fake)
    Evidence::CounterfactualRunner.new(
      Evidence::CounterfactualRequest.new(
        repository: Dir.tmpdir,
        production_patch_path: "production.patch",
        head_command: ["bundle", "exec", "test", "new"],
        build_command: ["bundle", "exec", "build"],
        new_test_command: ["bundle", "exec", "test", "new"],
        baseline_test_command: ["bundle", "exec", "test", "baseline"],
      ),
      runner: fake,
    )
  end

  def result(status, output = "")
    Evidence::CommandResult.new(status: status, stdout: output, stderr: status.zero? ? "" : output)
  end

  class FakeRunner
    include Evidence::CommandRunner

    attr_reader :commands

    def initialize(results)
      @results = results
      @commands = []
    end

    def run(command, chdir:)
      @commands << [command, chdir]
      result = @results.shift || Evidence::CommandResult.new(status: 0, stdout: "", stderr: "")
      raise "runner unavailable" if result == :raise

      result
    end
  end
end
