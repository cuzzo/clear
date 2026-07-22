# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tempfile"
require "tmpdir"
require_relative "../lib/test_miser/evidence/oracle"

class EvidenceOracleTest < Minitest::Test
  Evidence = TestMiser::Evidence

  def test_normalized_facts_round_trip_through_versioned_artifact_and_provider
    artifact = Evidence::OracleFacts.new(
      facts: [fact("o1", kind: Evidence::OracleKind::Equality, source_file: "test.rb")],
      metadata: {"language" => "ruby"},
    )
    path = Tempfile.new(["oracle-facts", ".json"])
    path.close

    artifact.write(path.path)
    loaded = Evidence::OracleFacts.load(path.path)
    provider = Evidence::StaticOracleFactProvider.new(loaded)

    assert_equal artifact.to_h, loaded.to_h
    assert_equal ["o1"], provider.facts(test_id: "t1", source_path: "test.rb", language: "ruby").map(&:oracle_id)
    assert_empty provider.facts(test_id: "t1", source_path: "other.rb", language: "ruby")
    assert_empty provider.facts(test_id: "other", source_path: "test.rb", language: "ruby")
    assert_equal ["EQUALITY"], loaded.to_h.fetch("facts").map { |row| row.fetch("oracle_kind") }
  ensure
    path&.unlink
  end

  def test_planner_recognizes_supported_families_and_marks_unknown_as_unsupported
    supported = [
      Evidence::OracleKind::Equality,
      Evidence::OracleKind::Identity,
      Evidence::OracleKind::Truthiness,
      Evidence::OracleKind::NullCheck,
      Evidence::OracleKind::ExceptionExpectation,
      Evidence::OracleKind::Snapshot,
      Evidence::OracleKind::MockVerification,
      Evidence::OracleKind::Property,
      Evidence::OracleKind::CompileFailure,
      Evidence::OracleKind::SubprocessOutput,
    ]
    plans = supported.flat_map.with_index do |kind, index|
      Evidence::OracleMutationPlanner.plan(fact("o#{index}", kind: kind))
    end
    unknown = Evidence::OracleMutationPlanner.plan(fact("unknown", kind: Evidence::OracleKind::Unknown))

    assert plans.all?(&:recognized)
    assert_equal Evidence::OracleMutationKind::NegateBoolean, plans.fetch(0).mutation
    assert_equal Evidence::OracleMutationKind::RemoveInvocation, plans.find { |plan| plan.oracle_id == "o4" }&.mutation
    assert_equal Evidence::OracleMutationKind::BroadenException, plans.find { |plan| plan.oracle_id == "o4" && plan.mutation == Evidence::OracleMutationKind::BroadenException }&.mutation
    assert_equal [Evidence::OracleMutationKind::DisableOracle], unknown.map(&:mutation)
    refute unknown.fetch(0).recognized
    assert_includes unknown.fetch(0).to_h.fetch("reason"), "unsupported"
  end

  def test_sensitivity_separates_dependent_and_persistent_kills
    facts = Evidence::OracleFacts.new(facts: [
      fact("o1", kind: Evidence::OracleKind::Equality, test_id: "t1"),
      fact("o2", kind: Evidence::OracleKind::Truthiness, test_id: "t2"),
      fact("o3", kind: Evidence::OracleKind::Snapshot, test_id: "t3"),
      fact("o4", kind: Evidence::OracleKind::MockVerification, test_id: "t4"),
      fact("o5", kind: Evidence::OracleKind::Property, test_id: "t5"),
      fact("o6", kind: Evidence::OracleKind::Unknown, test_id: "t6"),
    ])
    rewrites = [
      rewrite("o1", recognized: true, applied: true),
      rewrite("o2", recognized: false, applied: false),
      rewrite("o3", recognized: true, applied: false),
      rewrite("o4", recognized: true, applied: true),
      rewrite("o5", recognized: true, applied: true),
      rewrite("o6", recognized: true, applied: true),
    ]
    trials = [
      trial("t1", "o1", "m1", killed: false),
      trial("t1", "o1", "m2", killed: true),
      trial("t1", "o1", "unrelated", killed: true),
      trial("other", "o1", "m1", killed: true),
      trial("t2", "o2", "m3", killed: false),
      trial("t3", "o3", "m4", killed: false),
      trial("t5", "o5", "m5", killed: true),
      trial("t5", "o5", "m6", killed: false),
      trial("t5", "o5", "m5", killed: true, executed: false),
    ]

    analysis = Evidence::OracleSensitivityAnalyzer.analyze(
      facts: facts,
      original_kills: {"t1" => %w[m1 m2], "t2" => ["m3"], "t3" => ["m4"], "t4" => ["m7"], "t5" => %w[m5 m6], "t6" => []},
      disabled_trials: trials,
      rewrites: rewrites,
    )
    o1 = analysis.results.find { |result| result.oracle_id == "o1" }
    o2 = analysis.results.find { |result| result.oracle_id == "o2" }
    o3 = analysis.results.find { |result| result.oracle_id == "o3" }
    o4 = analysis.results.find { |result| result.oracle_id == "o4" }
    o5 = analysis.results.find { |result| result.oracle_id == "o5" }
    o6 = analysis.results.find { |result| result.oracle_id == "o6" }

    assert_equal ["m1"], o1&.oracle_dependent_kills
    assert_equal ["m2"], o1&.persists_without_oracle
    assert o1&.complete
    assert_equal "oracle rewrite was not recognized", o2&.unknown_reason
    assert_equal "oracle rewrite could not be applied", o3&.unknown_reason
    assert_equal "oracle-disabled attribution is incomplete", o4&.unknown_reason
    assert_equal "oracle-disabled trials did not execute", o5&.unknown_reason
    assert o6&.complete
    assert_equal 2, analysis.to_h.fetch("summary").fetch("complete_oracles")
    assert_equal "test-quality-evidence/oracle-sensitivity-v1", analysis.to_h.fetch("schema")
    assert_equal({
      "test_id" => "t1", "oracle_id" => "o1", "mutant_id" => "m1", "killed" => false, "executed" => true
    }, trials.fetch(0).to_h)
  end

  def test_missing_rewrite_is_unknown_and_invalid_artifacts_are_rejected
    fact_value = fact("o1", kind: Evidence::OracleKind::Equality, test_id: "t1")
    facts = Evidence::OracleFacts.new(facts: [fact_value])
    result = Evidence::OracleSensitivityAnalyzer.analyze(
      facts: facts,
      original_kills: {"t1" => ["m1"]},
      disabled_trials: [trial("t1", "o1", "m1", killed: false)],
      rewrites: [],
    ).results.fetch(0)
    assert_equal "no safe oracle rewrite was supplied", result.unknown_reason
    assert_equal({"oracle_id" => "o1", "mutation" => "NEGATE_BOOLEAN", "recognized" => true,
                  "applied" => true, "reason" => "adapter applied"}, rewrite("o1", recognized: true, applied: true).to_h)

    invalid_json = Tempfile.new(["bad-oracle", ".json"])
    invalid_json.write("not-json")
    invalid_json.close
    assert_raises(Evidence::InvalidOracleFacts) { Evidence::OracleFacts.load(invalid_json.path) }
    invalid_json.unlink

    invalid_schema = Tempfile.new(["bad-oracle-schema", ".json"])
    invalid_schema.write('{"schema":"old","facts":[]}')
    invalid_schema.close
    assert_raises(Evidence::InvalidOracleFacts) { Evidence::OracleFacts.load(invalid_schema.path) }
    invalid_schema.unlink

    invalid_row = Tempfile.new(["bad-oracle-row", ".json"])
    invalid_row.write('{"schema":"test-quality-oracle-facts/v1","facts":[1]}')
    invalid_row.close
    assert_raises(Evidence::InvalidOracleFacts) { Evidence::OracleFacts.load(invalid_row.path) }
    invalid_row.unlink
  end

  def test_invalid_spans_and_confidence_are_rejected_at_the_artifact_boundary
    invalid_span = fact_payload
    invalid_span["oracle_span"]["start_line"] = 0
    assert_invalid_fact(invalid_span)

    reversed_span = fact_payload
    reversed_span["oracle_span"]["end_column"] = 0
    assert_invalid_fact(reversed_span)

    invalid_confidence = fact_payload
    invalid_confidence["confidence"] = 1.1
    assert_invalid_fact(invalid_confidence)
  end

  def test_missing_original_kills_are_incomplete
    fact_value = fact("o1", kind: Evidence::OracleKind::Equality, test_id: "t1")
    missing_original = Evidence::OracleSensitivityAnalyzer.analyze(
      facts: Evidence::OracleFacts.new(facts: [fact_value]),
      original_kills: {},
      disabled_trials: [],
      rewrites: [rewrite("o1", recognized: true, applied: true)],
    ).results.fetch(0)

    refute missing_original.complete
    assert_equal "original kill attribution is missing", missing_original.unknown_reason
  end

  def test_duplicate_fact_and_rewrite_ids_are_rejected
    duplicate = fact("same", kind: Evidence::OracleKind::Equality)
    assert_raises(Evidence::InvalidOracleFacts) { Evidence::OracleFacts.new(facts: [duplicate, duplicate]).validate_unique_ids! }

    assert_raises(Evidence::InvalidOracleFacts) do
      Evidence::OracleSensitivityAnalyzer.analyze(
        facts: Evidence::OracleFacts.new(facts: [duplicate]), original_kills: {"t1" => ["m1"]},
        disabled_trials: [trial("t1", "same", "m1", killed: false)], rewrites: [rewrite("same", recognized: true, applied: true), rewrite("same", recognized: true, applied: true)],
      )
    end
  end

  def test_factmine_provider_and_conservative_ruby_rewrite_are_executable
    binary = File.expand_path("../../fact-mine/target/release/fact-mine-rust", __dir__)
    skip "FactMine binary missing" unless File.executable?(binary)

    source_path = File.expand_path("fixtures/collector/setup.rb", __dir__)
    facts = Evidence::FactMineOracleFactProvider.new(binary: binary).facts(
      test_id: "t1", source_path: source_path, language: "ruby",
    )
    assert_equal 2, facts.length
    assert facts.all? { |oracle| oracle.oracle_kind == Evidence::OracleKind::Equality }
    grammar = ENV["DECOMPLEX_TS_RUBY_PATH"]
    skip "Tree-sitter Ruby grammar missing" unless grammar && File.file?(grammar)
    tree_facts = Evidence::TreeSitterOracleFactProvider.new.facts(
      test_id: "t1", source_path: source_path, language: "ruby",
    )
    assert_equal 2, tree_facts.length
    assert tree_facts.all? { |oracle| oracle.framework == "tree-sitter:ruby" }

    source = "assert_equal 1, 1\n"
    fact_value = Evidence::OracleFact.new(
      oracle_id: "ruby", test_id: "t1", oracle_kind: Evidence::OracleKind::Equality,
      oracle_span: Evidence::SourceSpan.new(start_line: 1, start_column: 1, end_line: 1, end_column: source.bytesize + 1),
      framework: "minitest", confidence: 1.0,
    )
    plan = Evidence::OracleMutationPlanner.plan(fact_value).first
    rewritten, rewrite_result = Evidence::ConservativeOracleRewriteAdapter.new.rewrite(
      fact: fact_value, plan: plan, source: source, language: "ruby",
    )
    assert_equal "refute_equal 1, 1\n", rewritten
    assert rewrite_result.applied
  end

  def test_repeated_oracle_trials_require_a_complete_stable_matrix
    fact_value = fact("o1", kind: Evidence::OracleKind::Equality)
    rows = (1..3).map do |index|
      trial("t1", "o1", "m1", killed: false, trial_id: "run-#{index}", trial: index)
    end
    result = Evidence::OracleSensitivityAnalyzer.analyze(
      facts: Evidence::OracleFacts.new(facts: [fact_value]), original_kills: {"t1" => ["m1"]},
      disabled_trials: rows, rewrites: [rewrite("o1", recognized: true, applied: true)],
      trial_ids: rows.map(&:trial_id), min_trials: 3,
    ).results.fetch(0)
    assert result.complete
    assert result.stable
    assert_equal 3, result.observed_trials
    assert_equal ["m1"], result.oracle_dependent_kills

    flaky = rows.first.with(killed: true)
    flaky_result = Evidence::OracleSensitivityAnalyzer.analyze(
      facts: Evidence::OracleFacts.new(facts: [fact_value]), original_kills: {"t1" => ["m1"]},
      disabled_trials: [flaky, *rows.drop(1)], rewrites: [rewrite("o1", recognized: true, applied: true)],
      trial_ids: rows.map(&:trial_id), min_trials: 3,
    ).results.fetch(0)
    refute flaky_result.complete
    assert_equal "oracle-disabled results are flaky", flaky_result.unknown_reason
  end

  def test_oracle_execution_requires_mutated_oracle_control_failure
    Dir.mktmpdir do |repository|
      FileUtils.mkdir_p(File.join(repository, "lib"))
      File.write(File.join(repository, "lib/test.rb"), "assert_equal 1, 1\n")
      Dir.chdir(repository) do
        system("git init -q && git config user.email t@t && git config user.name t", exception: true)
        system("git add -A && git commit -qm init", exception: true)
      end
      revision = Dir.chdir(repository) { `git rev-parse HEAD`.strip }
      fact_value = Evidence::OracleFact.new(
        oracle_id: "o1", test_id: "t1", oracle_kind: Evidence::OracleKind::Equality,
        oracle_span: Evidence::SourceSpan.new(start_line: 1, start_column: 1, end_line: 1, end_column: 18),
        framework: "minitest", confidence: 1.0,
      )
      request = Evidence::OracleExecutionRequest.new(
        repository: repository, revision: revision, source_path: "lib/test.rb", test_command: ["control"],
        baseline_test_command: ["baseline"], mutant_commands: {"m1" => ["mutant"]}, test_id: "t1", fact: fact_value,
        plan: Evidence::OracleMutationPlanner.plan(fact_value).first, language: "ruby", trial_count: 3,
      )
      result = Evidence::OracleExecutionRunner.new(command_runner: OracleFakeRunner.new).run(request)
      assert_equal Evidence::TestOutcome::Passed, result.baseline_outcome
      assert_equal Evidence::TestOutcome::AssertionFailure, result.control_outcome
      assert_equal 3, result.trials.length
      assert result.trials.all?(&:executed)
    end
  end

  private

  def span
    Evidence::SourceSpan.new(start_line: 1, start_column: 1, end_line: 1, end_column: 8, start_offset: 0, end_offset: 7)
  end

  def fact(id, kind:, test_id: "t1", source_file: nil)
    Evidence::OracleFact.new(
      oracle_id: id,
      test_id: test_id,
      oracle_kind: kind,
      oracle_span: span,
      expected_span: span,
      actual_span: span,
      framework: "fixture",
      confidence: 0.99,
      source_file: source_file,
    )
  end

  def rewrite(id, recognized:, applied:)
    Evidence::OracleRewrite.new(
      oracle_id: id,
      mutation: Evidence::OracleMutationKind::NegateBoolean,
      recognized: recognized,
      applied: applied,
      reason: "adapter applied",
    )
  end

  def trial(test_id, oracle_id, mutant_id, killed:, executed: true, trial: 0, trial_id: "legacy")
    Evidence::OracleTrial.new(
      test_id: test_id,
      oracle_id: oracle_id,
      mutant_id: mutant_id,
      killed: killed,
      executed: executed,
      trial: trial,
      trial_id: trial_id,
    )
  end

  class OracleFakeRunner
    include Evidence::CommandRunner

    def run(command, chdir:, limits:)
      case command.first
      when "baseline"
        Evidence::CommandResult.new(status: 0, stdout: "", stderr: "")
      else
        Evidence::CommandResult.new(status: 1, stdout: "", stderr: "Minitest::Assertion")
      end
    end
  end

  def fact_payload
    {
      "oracle_id" => "o1",
      "test_id" => "t1",
      "oracle_kind" => "EQUALITY",
      "oracle_span" => {
        "start_line" => 1,
        "start_column" => 1,
        "end_line" => 1,
        "end_column" => 8,
      },
      "framework" => "fixture",
      "confidence" => 0.99,
    }
  end

  def assert_invalid_fact(payload)
    path = Tempfile.new(["invalid-oracle-fact", ".json"])
    path.write(JSON.generate("schema" => "test-quality-oracle-facts/v1", "facts" => [payload]))
    path.close
    assert_raises(Evidence::InvalidOracleFacts) { Evidence::OracleFacts.load(path.path) }
  ensure
    path&.unlink
  end
end
