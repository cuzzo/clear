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
    assert_equal Evidence::OracleMutationKind::DisableOracle, plans.fetch(0).mutation
    assert_equal Evidence::OracleMutationKind::NegateBoolean, Evidence::OracleMutationPlanner.control_plan(fact("control", kind: Evidence::OracleKind::Equality))&.mutation
    assert_empty plans.select { |plan| plan.mutation == Evidence::OracleMutationKind::RemoveInvocation }
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
      execution_results: facts.facts.map { |oracle| execution_result(oracle.oracle_id) },
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

  def test_oracle_artifacts_reject_mismatched_scope_identity
    scope = Evidence::EvidenceScope.new(
      revision: "rev-current", selection_scope: "all", mutant_corpus_fingerprint: "mutants", test_set_identity: "tests",
    )
    fact_value = fact("o1", kind: Evidence::OracleKind::Equality)

    assert_raises(Evidence::EvidenceScopeMismatch) do
      Evidence::OracleSensitivityAnalyzer.analyze(
        facts: Evidence::OracleFacts.new(facts: [fact_value], metadata: {"revision" => "rev-stale"}),
        original_kills: {}, disabled_trials: [], rewrites: [], scope: scope,
      )
    end
    assert_raises(Evidence::EvidenceScopeMismatch) do
      Evidence::OracleSensitivityAnalyzer.analyze(
        facts: Evidence::OracleFacts.new(facts: [fact_value], metadata: {"scope" => {"fingerprint" => "stale"}}),
        original_kills: {}, disabled_trials: [], rewrites: [], scope: scope,
      )
    end
    assert_raises(Evidence::InvalidOracleFacts) do
      Evidence::OracleSensitivityAnalyzer.analyze(
        facts: Evidence::OracleFacts.new(facts: [fact_value], metadata: {"scope" => "stale"}),
        original_kills: {}, disabled_trials: [], rewrites: [], scope: scope,
      )
    end
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
    runner = factmine_fixture_runner
    source_path = File.expand_path("fixtures/collector/setup.rb", __dir__)
    test_id = "minitest:TestMiserCollectorFixtureTest#test_true_a"
    facts = Evidence::FactMineOracleFactProvider.new(binary: "unused", runner: runner).facts(
      test_id: test_id, source_path: source_path, language: "ruby",
    )
    assert_equal 1, facts.length
    assert facts.all? { |oracle| oracle.oracle_kind == Evidence::OracleKind::Equality }
    rspec_path = File.expand_path("fixtures/rspec_collector/spec/example_spec.rb", __dir__)
    rspec_test_id = "rspec:0:#{rspec_path}:8/TestMiserRspecFixture recognizes a positive value"
    rspec_facts = Evidence::FactMineOracleFactProvider.new(binary: "unused", runner: runner).facts(
      test_id: rspec_test_id, source_path: rspec_path, language: "ruby",
    )
    assert_equal 1, rspec_facts.length
    assert_equal Evidence::OracleKind::Equality, rspec_facts.fetch(0).oracle_kind
    assert_equal 5, rspec_facts.fetch(0).oracle_span.start_column
    assert_equal 52, rspec_facts.fetch(0).oracle_span.end_column
    java_path = File.expand_path("../examples/java/src/test/java/dev/testmiser/ClassifierTest.java", __dir__)
    java_facts = Evidence::FactMineOracleFactProvider.new(binary: "unused", runner: runner).facts(
      test_id: "junit:ClassifierTest#positivePrimary", source_path: java_path, language: "java",
    )
    assert_equal 1, java_facts.length
    assert_equal Evidence::OracleKind::Equality, java_facts.fetch(0).oracle_kind
    tree_facts = Evidence::TreeSitterOracleFactProvider.new(tree_sitter: FakeTreeSitterBinding).facts(
      test_id: test_id, source_path: source_path, language: "ruby",
    )
    assert_equal 1, tree_facts.length
    assert tree_facts.all? { |oracle| oracle.framework == "minitest" }
    rspec_tree_facts = Evidence::TreeSitterOracleFactProvider.new(tree_sitter: FakeTreeSitterBinding).facts(
      test_id: rspec_test_id, source_path: rspec_path, language: "ruby",
    )
    assert_equal 1, rspec_tree_facts.length
    assert_equal 5, rspec_tree_facts.fetch(0).oracle_span.start_column
    assert_equal 52, rspec_tree_facts.fetch(0).oracle_span.end_column
    source = "assert_equal 1, 1\n"
    fact_value = Evidence::OracleFact.new(
      oracle_id: "ruby", test_id: "t1", oracle_kind: Evidence::OracleKind::Equality,
      oracle_span: Evidence::SourceSpan.new(start_line: 1, start_column: 1, end_line: 1, end_column: source.bytesize + 1),
      framework: "minitest", confidence: 1.0,
    )
    plan = Evidence::OracleMutationPlanner.control_plan(fact_value)
    rewritten, rewrite_result = Evidence::ConservativeOracleRewriteAdapter.new.rewrite(
      fact: fact_value, plan: T.must(plan), source: source, language: "ruby",
    )
    assert_equal "refute_equal 1, 1\n", rewritten
    assert rewrite_result.applied
  end

  def test_framework_detection_rejects_production_lookalikes
    source = "class Production\n  def equalize(value)\n    value\n  end\nend\n"
    assert_nil Evidence::OracleFramework.detect(source, "ruby")
    assert_nil Evidence::OracleFramework.kind("minitest", "equalize")
    assert_nil Evidence::OracleFramework.kind("rspec", "expectation")
  end

  def test_python_tree_sitter_attribution_requires_the_requested_test
    provider = Evidence::TreeSitterOracleFactProvider.new
    source = "import pytest\n\ndef test_value():\n    assert calculate()\n\ndef test_other():\n    assert other()\n"
    assert provider.send(:source_test_contains?, "pytest:module::test_value", source, 4, "pytest")
    assert provider.send(:source_test_contains?, "pytest:test_value", source, 4, "pytest")
    refute provider.send(:source_test_contains?, "pytest:module::test_missing", source, 4, "pytest")
    refute provider.send(:source_test_contains?, "pytest:module::test_value", source, 7, "pytest")
    java_source = "class ExampleTest {\n  @Test void first() { assertEquals(1, value()); }\n  @Test void second() { assertEquals(2, other()); }\n}\n"
    assert provider.send(:source_test_contains?, "junit:ExampleTest#first", java_source, 2, "junit")
    refute provider.send(:source_test_contains?, "junit:ExampleTest#first", java_source, 3, "junit")
  end

  def test_framework_detection_and_call_tables_are_language_specific
    assert_equal "unittest", Evidence::OracleFramework.detect("import unittest\nclass T(unittest.TestCase): pass", "python")
    assert_equal "pytest", Evidence::OracleFramework.detect("import pytest\ndef test_value(): pass", "python")
    assert_equal "junit", Evidence::OracleFramework.detect("import org.junit.Test; @Test void value() {}", "java")
    assert_equal "jest", Evidence::OracleFramework.detect("import { expect } from '@jest/globals'", "javascript")
    assert_equal Evidence::OracleKind::Equality, Evidence::OracleFramework.kind(
      "unittest", {"message" => "assertEqual", "receiver" => "self", "owner" => "ExampleTestCase"},
    )
    assert_equal Evidence::OracleKind::Equality, Evidence::OracleFramework.kind(
      "jest", {"message" => "toEqual", "receiver" => "expect(actual)", "owner" => "example.test"},
    )
    assert_equal Evidence::OracleKind::Equality, Evidence::OracleFramework.kind(
      "junit", {"message" => "assertEquals", "receiver" => "Assert", "owner" => "ExampleTest"},
    )
    assert_equal Evidence::OracleKind::Equality, Evidence::OracleFramework.kind(
      "junit", {"message" => "assertEquals", "receiver" => "org.junit.jupiter.api.Assertions", "owner" => "ExampleTest"},
    )
    assert_equal Evidence::OracleKind::ExceptionExpectation, Evidence::OracleFramework.kind(
      "pytest", {"message" => "raises", "receiver" => "pytest", "owner" => "module"},
    )
    assert_nil Evidence::OracleFramework.kind(
      "jest", {"message" => "toEqual", "receiver" => "Production.expect", "owner" => "example.test"},
    )
    assert_nil Evidence::OracleFramework.kind(
      "rspec", {"message" => "eq", "receiver" => "Production.expect", "owner" => "example_spec"},
    )
    assert_nil Evidence::OracleFramework.kind("jest", "toEqual")
    assert_nil Evidence::OracleFramework.kind("rspec", "expect")
    assert_nil Evidence::OracleFramework.kind("pytest", "assert")
    assert_nil Evidence::OracleFramework.kind("unknown", "assert_equal")
  end

  def test_framework_specific_adapters_cover_supported_languages
    adapter = Evidence::ConservativeOracleRewriteAdapter.new
    {
      ["ruby", "minitest", "assert_same actual, expected"] => "refute_same actual, expected",
     ["ruby", "rspec", "expect(actual).to eq(expected)"] => "expect(actual).to_not eq(expected)",
      ["python", "unittest", "self.assertEqual(actual, expected)"] => "self.assertNotEqual(actual, expected)",
      ["python", "pytest", "assert actual == expected"] => "assert not (actual == expected)",
      ["javascript", "jest", "expect(actual).toEqual(expected)"] => "expect(actual).not.toEqual(expected)",
      ["java", "junit", "assertEquals(actual, expected)"] => "assertNotEquals(actual, expected)",
      ["ruby", "minitest", "assert actual"] => "refute actual",
      ["ruby", "minitest", "refute actual"] => "assert actual",
      ["ruby", "rspec", "expect(actual).to eql(expected)"] => "expect(actual).to_not eql(expected)",
      ["python", "unittest", "self.assertTrue(actual)"] => "self.assertFalse(actual)",
      ["python", "unittest", "self.assertFalse(actual)"] => "self.assertTrue(actual)",
      ["java", "junit", "assertTrue(actual)"] => "assertFalse(actual)",
      ["java", "junit", "assertFalse(actual)"] => "assertTrue(actual)",
    }.each do |(language, framework, source), expected|
      fact_value = source_fact(framework, source)
      plan = Evidence::OracleMutationPlan.new(
        oracle_id: fact_value.oracle_id, mutation: Evidence::OracleMutationKind::NegateBoolean,
        recognized: true, reason: "fixture",
      )
      rewritten, result = adapter.rewrite(fact: fact_value, plan: plan, source: source, language: language)
      assert_equal expected, rewritten
      assert result.applied
    end

    [["javascript", "jest", "[actual, expected]", "expect(actual).toEqual(expected)"],
     ["java", "junit", "{ Object __test_miser_arg_0 = (expected); Object __test_miser_arg_1 = (actual); }", "assertEquals(expected, actual)"],].each do |language, framework, expected, source|
      fact_value = source_fact(framework, source)
      plan = Evidence::OracleMutationPlanner.plan(fact_value).first
      rewritten, result = adapter.rewrite(fact: fact_value, plan: plan, source: source, language: language)
      assert_equal expected, rewritten
      assert result.applied
    end

    [["ruby", "rspec", "begin actual; expected end", "expect(actual).to eq(expected)"],
     ["python", "pytest", "actual", "assert actual"],
     ["python", "unittest", "actual", "self.assertTrue(actual)"],
     ["javascript", "jest", "[actual, expected]", "expect(actual).toBe(expected)"],
     ["java", "junit", "{ Object __test_miser_arg_0 = (actual); }", "assertTrue(actual)"],].each do |language, framework, expected, source|
      fact_value = source_fact(framework, source)
      plan = Evidence::OracleMutationPlanner.plan(fact_value).first
      rewritten, result = adapter.rewrite(fact: fact_value, plan: plan, source: source, language: language)
      assert_equal expected, rewritten
      assert result.applied
    end

    [["ruby", "minitest", "assert actual", "actual"],
     ["ruby", "minitest", "assert_nil actual", "actual"],
     ["ruby", "minitest", "refute_nil actual", "actual"],
     ["ruby", "minitest", "refute actual", "actual"],
     ["python", "unittest", "self.assertFalse(actual)", "actual"],
     ["java", "junit", "assertFalse(actual)", "{ Object __test_miser_arg_0 = (actual); }"],].each do |language, framework, source, expected|
      fact_value = source_fact(framework, source)
      plan = Evidence::OracleMutationPlanner.plan(fact_value).first
      rewritten, result = adapter.rewrite(fact: fact_value, plan: plan, source: source, language: language)
      assert_equal expected, rewritten
      assert result.applied
    end

    unsupported = Evidence::OracleMutationPlan.new(
      oracle_id: "unsupported", mutation: Evidence::OracleMutationKind::PerturbExpected,
      recognized: true, reason: "fixture",
    )
    rewritten, result = adapter.rewrite(
      fact: source_fact("minitest", "assert_equal 1, 1", expected: true), plan: unsupported,
      source: "assert_equal 1, 1", language: "ruby",
    )
    assert_equal "assert_equal 1, 1", rewritten
    refute result.applied
    assert_includes result.reason, "no conservative adapter"
  end

  def test_factmine_rejects_assertion_names_on_non_framework_receivers
    Dir.mktmpdir do |directory|
      source_path = File.join(directory, "example_test.rb")
      File.write(source_path, "class ExampleTest < Minitest::Test; end\n")
      runner = Object.new
      def runner.capture3(*_args)
        payload = {
          "documents" => [{"calls" => [
            {"message" => "assert_equal", "receiver" => "self", "owner" => "ExampleTest", "function" => "test_value", "span" => [1, 0, 1, 10]},
            {"message" => "assert_equal", "receiver" => "Production.new", "owner" => "ExampleTest", "function" => "test_value", "span" => [1, 0, 1, 10]},
            {"message" => "equalize", "receiver" => "self", "owner" => "ExampleTest", "function" => "test_value", "span" => [1, 0, 1, 10]},
          ]}],
        }
        [JSON.generate(payload), "", Evidence::CommandResult.new(status: 0, stdout: "", stderr: "")]
      end

      facts = Evidence::FactMineOracleFactProvider.new(binary: "unused", runner: runner).facts(
        test_id: "minitest:ExampleTest#test_value", source_path: source_path, language: "ruby",
      )
      assert_equal 1, facts.length
      assert_equal Evidence::OracleKind::Equality, facts.fetch(0).oracle_kind
    end
  end

  def test_disable_oracle_has_only_framework_specific_rewrites
    fact_value = fact("o1", kind: Evidence::OracleKind::Equality)
    plan = Evidence::OracleMutationPlanner.plan(fact_value).first
    source = "assert_equal 1, 1\n"
    fact_value = Evidence::OracleFact.new(
      oracle_id: fact_value.oracle_id, test_id: fact_value.test_id, oracle_kind: fact_value.oracle_kind,
      oracle_span: Evidence::SourceSpan.new(start_line: 1, start_column: 1, end_line: 1, end_column: source.bytesize + 1),
      framework: "minitest", confidence: fact_value.confidence,
    )
    rewritten, result = Evidence::ConservativeOracleRewriteAdapter.new.rewrite(
      fact: fact_value, plan: plan, source: source, language: "ruby",
    )
    assert_equal "begin 1; 1 end", rewritten
    assert result.applied

    unrecognized = Evidence::OracleMutationPlan.new(
      oracle_id: "o1", mutation: Evidence::OracleMutationKind::DisableOracle, recognized: false, reason: "fixture",
    )
    rewritten, result = Evidence::ConservativeOracleRewriteAdapter.new.rewrite(
      fact: fact_value, plan: unrecognized, source: source, language: "ruby",
    )
    assert_equal source, rewritten
    refute result.applied

    invalid_span_fact = source_fact("minitest", source)
    invalid_span_fact = Evidence::OracleFact.new(
      oracle_id: invalid_span_fact.oracle_id, test_id: invalid_span_fact.test_id, oracle_kind: invalid_span_fact.oracle_kind,
      oracle_span: Evidence::SourceSpan.new(start_line: 99, start_column: 1, end_line: 99, end_column: 2),
      framework: invalid_span_fact.framework, confidence: invalid_span_fact.confidence,
    )
    rewritten, result = Evidence::ConservativeOracleRewriteAdapter.new.rewrite(
      fact: invalid_span_fact, plan: plan, source: source, language: "ruby",
    )
    assert_equal source, rewritten
    refute result.applied

    unknown = fact_value.with(framework: "custom")
    rewritten, result = Evidence::ConservativeOracleRewriteAdapter.new.rewrite(
      fact: unknown, plan: plan, source: source, language: "ruby",
    )
    assert_equal source, rewritten
    refute result.applied
    assert_includes result.reason, "no safe oracle-disabling adapter"

    source = "assert_equal expected, calculate()\n"
    fact_value = source_fact("minitest", source)
    rewritten, result = Evidence::ConservativeOracleRewriteAdapter.new.rewrite(
      fact: fact_value, plan: plan, source: source, language: "ruby",
    )
    assert_includes rewritten, "calculate()"
    assert result.applied

    source = "assert_equal \"é\", calculate(1 < 2, \"x,y\")\n"
    fact_value = source_fact("minitest", source)
    rewritten, result = Evidence::ConservativeOracleRewriteAdapter.new.rewrite(
      fact: fact_value, plan: plan, source: source, language: "ruby",
    )
    assert_equal "begin \"é\"; calculate(1 < 2, \"x,y\") end", rewritten
    assert result.applied

    source = "assert_equal \"x,y\", calculate()\n"
    fact_value = source_fact("minitest", source)
    rewritten, result = Evidence::ConservativeOracleRewriteAdapter.new.rewrite(
      fact: fact_value, plan: plan, source: source, language: "ruby",
    )
    assert_equal "begin \"x,y\"; calculate() end", rewritten
    assert result.applied
  end

  def test_artifact_parser_covers_rows_and_rejects_invalid_offsets
    assert_equal 1, Evidence::OracleFacts.from_rows([fact_payload]).facts.length
    invalid = fact_payload
    invalid["oracle_span"]["start_offset"] = -1
    assert_raises(Evidence::InvalidOracleFacts) { Evidence::OracleFacts.from_rows([invalid]) }

    invalid = fact_payload
    invalid["oracle_span"]["start_offset"] = 3
    invalid["oracle_span"]["end_offset"] = 2
    assert_raises(Evidence::InvalidOracleFacts) { Evidence::OracleFacts.from_rows([invalid]) }

    invalid = fact_payload
    invalid["oracle_span"]["start_offset"] = 0
    invalid["oracle_span"].delete("end_offset")
    assert_raises(Evidence::InvalidOracleFacts) { Evidence::OracleFacts.from_rows([invalid]) }

    invalid = fact_payload
    invalid["oracle_span"] = "not-a-span"
    assert_raises(Evidence::InvalidOracleFacts) { Evidence::OracleFacts.from_rows([invalid]) }
    invalid = fact_payload
    invalid["oracle_span"]["end_line"] = 0
    assert_raises(Evidence::InvalidOracleFacts) { Evidence::OracleFacts.from_rows([invalid]) }
  end

  def test_factmine_rejects_invalid_json
    runner = Object.new
    def runner.capture3(*_args)
      ["not-json", "", Evidence::CommandResult.new(status: 0, stdout: "", stderr: "")]
    end
    path = File.expand_path("fixtures/collector/setup.rb", __dir__)
    assert_raises(Evidence::InvalidOracleFacts) do
      Evidence::FactMineOracleFactProvider.new(binary: "unused", runner: runner).facts(
        test_id: "minitest:TestMiserCollectorFixtureTest#test_true_a", source_path: path, language: "ruby",
      )
    end
  end

  def test_execution_rejects_dirty_repository_before_running_commands
    request = Evidence::OracleExecutionRequest.new(
      repository: File.expand_path("../../..", __dir__), source_path: "gems/test-miser/test/fixtures/collector/setup.rb",
      test_command: ["true"], test_id: "t1", fact: fact("o1", kind: Evidence::OracleKind::Equality),
      plan: Evidence::OracleMutationPlanner.plan(fact("o1", kind: Evidence::OracleKind::Equality)).first,
      language: "ruby",
    )
    assert_raises(Evidence::InvalidOracleFacts) { Evidence::OracleExecutionRunner.new.run(request) }
  end

  def test_revision_snapshot_resolves_identity_and_rejects_unsafe_source_paths
    Dir.mktmpdir do |parent|
      repository = File.join(parent, "repository")
      FileUtils.mkdir_p(repository)
      File.write(File.join(repository, "test.rb"), "assert_equal 1, 1\n")
      File.write(File.join(parent, "outside.rb"), "outside\n")
      File.symlink("../outside.rb", File.join(repository, "escape.rb"))
      Dir.chdir(repository) do
        system("git init -q && git config user.email t@t && git config user.name t && git add -A && git commit -qm init", exception: true)
      end
      resolved = nil
      Evidence::OracleRevisionSnapshot.with(repository: repository, revision: "HEAD", source_path: "test.rb") do |source_path, revision|
        resolved = revision
        assert_equal "assert_equal 1, 1\n", File.read(source_path)
      end
      assert_match(/\A[0-9a-f]{40,64}\z/, resolved)
      assert_raises(Evidence::RevisionResolutionError) do
        Evidence::OracleRevisionSnapshot.with(repository: repository, revision: resolved, source_path: "../outside.rb") { |_path, _revision| flunk "unsafe path was accepted" }
      end
      assert_raises(Evidence::RevisionResolutionError) do
        Evidence::OracleRevisionSnapshot.with(repository: repository, revision: resolved, source_path: "/tmp/outside.rb") { |_path, _revision| flunk "absolute path was accepted" }
      end
      assert_raises(Evidence::RevisionResolutionError) do
        Evidence::OracleRevisionSnapshot.with(repository: repository, revision: resolved, source_path: "escape.rb") { |_path, _revision| flunk "escaping symlink was accepted" }
      end
    end
  end

  def test_execution_uses_the_requested_revision_instead_of_a_dirty_worktree_source
    Dir.mktmpdir do |repository|
      File.write(File.join(repository, "test.rb"), "assert_equal 1, 1\n")
      Dir.chdir(repository) do
        system("git init -q && git config user.email t@t && git config user.name t", exception: true)
        system("git add -A && git commit -qm init", exception: true)
      end
      revision = Dir.chdir(repository) { `git rev-parse HEAD`.strip }
      File.write(File.join(repository, "test.rb"), "assert_equal 2, 2\n")
      fact_value = Evidence::OracleFact.new(
        oracle_id: "o1", test_id: "t1", oracle_kind: Evidence::OracleKind::Snapshot,
        oracle_span: Evidence::SourceSpan.new(start_line: 1, start_column: 1, end_line: 1, end_column: 18),
        framework: "minitest", confidence: 1.0,
      )
      adapter = RevisionRecordingAdapter.new
      request = Evidence::OracleExecutionRequest.new(
        repository: repository, revision: revision, source_path: "test.rb", test_command: ["control"],
        test_id: "t1", fact: fact_value, plan: Evidence::OracleMutationPlanner.plan(fact_value).first,
        language: "ruby", allow_dirty: true,
      )

      Evidence::OracleExecutionRunner.new(command_runner: OracleFakeRunner.new, adapter: adapter).run(request)
      assert_equal 1, adapter.sources.length
      assert_includes adapter.sources.fetch(0), "assert_equal 1, 1"
      refute_includes adapter.sources.fetch(0), "assert_equal 2, 2"
    end
  end

  def test_repeated_oracle_trials_require_a_complete_stable_matrix
    fact_value = fact("o1", kind: Evidence::OracleKind::Equality)
    rows = (1..3).map do |index|
      trial("t1", "o1", "m1", killed: false, trial_id: "run-#{index}", trial: index)
    end
    result = Evidence::OracleSensitivityAnalyzer.analyze(
      facts: Evidence::OracleFacts.new(facts: [fact_value]), original_kills: {"t1" => ["m1"]},
      disabled_trials: rows, rewrites: [rewrite("o1", recognized: true, applied: true)],
      trial_ids: rows.map(&:trial_id), min_trials: 3, execution_results: [execution_result("o1")],
    ).results.fetch(0)
    assert result.complete
    assert result.stable
    assert_equal 3, result.observed_trials
    assert_equal ["m1"], result.oracle_dependent_kills

    flaky = rows.first.with(killed: true)
    flaky_result = Evidence::OracleSensitivityAnalyzer.analyze(
      facts: Evidence::OracleFacts.new(facts: [fact_value]), original_kills: {"t1" => ["m1"]},
      disabled_trials: [flaky, *rows.drop(1)], rewrites: [rewrite("o1", recognized: true, applied: true)],
      trial_ids: rows.map(&:trial_id), min_trials: 3, execution_results: [execution_result("o1")],
    ).results.fetch(0)
    refute flaky_result.complete
    assert_equal "oracle-disabled results are flaky", flaky_result.unknown_reason
  end

  def test_unverified_control_cannot_produce_oracle_findings
    fact_value = fact("o1", kind: Evidence::OracleKind::Equality)
    result = Evidence::OracleSensitivityAnalyzer.analyze(
      facts: Evidence::OracleFacts.new(facts: [fact_value]),
      original_kills: {"t1" => ["m1"]},
      disabled_trials: [trial("t1", "o1", "m1", killed: false, trial_id: "run-1")],
      rewrites: [rewrite("o1", recognized: true, applied: true)],
      trial_ids: ["run-1"], min_trials: 1,
      execution_results: [execution_result("o1", control_verified: false)],
    ).results.fetch(0)

    refute result.complete
    refute result.control_verified
    assert_equal "oracle control experiment did not fail on correct production code", result.unknown_reason
    assert_empty result.oracle_dependent_kills
    assert_empty result.persists_without_oracle
  end

  def test_non_assertion_trial_outcomes_are_incomplete
    fact_value = fact("o1", kind: Evidence::OracleKind::Equality)
    result = Evidence::OracleSensitivityAnalyzer.analyze(
      facts: Evidence::OracleFacts.new(facts: [fact_value]),
      original_kills: {"t1" => ["m1"]},
      disabled_trials: [trial(
        "t1", "o1", "m1", killed: false, executed: false, trial_id: "run-1", outcome: Evidence::TestOutcome::TimedOut,
      )],
      rewrites: [rewrite("o1", recognized: true, applied: true)],
      trial_ids: ["run-1"], min_trials: 1,
      execution_results: [execution_result("o1")],
    ).results.fetch(0)

    refute result.complete
    assert_equal "oracle-disabled trials did not execute", result.unknown_reason
    assert_empty result.oracle_dependent_kills

    result = Evidence::OracleSensitivityAnalyzer.analyze(
      facts: Evidence::OracleFacts.new(facts: [fact_value]),
      original_kills: {"t1" => ["m1"]},
      disabled_trials: [trial(
        "t1", "o1", "m1", killed: false, executed: true, trial_id: "run-1", outcome: Evidence::TestOutcome::Crash,
      )],
      rewrites: [rewrite("o1", recognized: true, applied: true)],
      trial_ids: ["run-1"], min_trials: 1,
      execution_results: [execution_result("o1")],
    ).results.fetch(0)
    refute result.complete
    assert_equal "oracle-disabled trials had a non-assertion outcome", result.unknown_reason
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
      assert_equal Evidence::OracleMutationKind::DisableOracle, result.disabled_rewrite.mutation
      assert_equal Evidence::TestOutcome::Passed, result.disabled_control_outcome
      assert_equal Evidence::OracleMutationKind::NegateBoolean, result.control_rewrite&.mutation
      assert_equal Evidence::TestOutcome::AssertionFailure, result.control_outcome
      assert result.control_verified?
      assert_equal 3, result.disabled_trials.length
      assert result.disabled_trials.all?(&:executed)
      refute_includes result.to_h, "rewrite"
      assert_equal 3, result.to_h.fetch("disabled_trials").length
    end
  end

  def test_oracle_execution_runs_real_minitest_and_rspec_fixtures
    {
      "minitest" => {
        source: <<~RUBY,
          require "minitest/autorun"

          class ExampleTest < Minitest::Test
            def test_value
              assert_equal 2, calculate()
            end

            private

            def calculate
              2
            end
          end
        RUBY
        framework: "minitest",
      },
      "rspec" => {
        source: <<~RUBY,
          require "rspec/autorun"

          RSpec.describe "Example" do
            it "calculates" do
              expect(calculate()).to eq(2)
            end

            def calculate
              2
            end
          end
        RUBY
        framework: "rspec",
      },
    }.each do |framework, fixture|
      Dir.mktmpdir("test-miser-#{framework}-oracle-") do |repository|
        source = fixture.fetch(:source)
        File.write(File.join(repository, "test.rb"), source)
        Dir.chdir(repository) do
          system("git init -q && git config user.email t@t && git config user.name t && git add test.rb && git commit -qm fixture", exception: true)
        end
        line = source.lines.index { |text| text.include?(framework == "minitest" ? "assert_equal" : "expect(calculate())") } + 1
        call = framework == "minitest" ? "assert_equal 2, calculate()" : "expect(calculate()).to eq(2)"
        fact_value = Evidence::OracleFact.new(
          oracle_id: "#{framework}-e2e", test_id: "t1", oracle_kind: Evidence::OracleKind::Equality,
          oracle_span: oracle_source_span(source, line, call), framework: fixture.fetch(:framework), confidence: 1.0,
        )
        result = Evidence::OracleExecutionRunner.new.run(
          Evidence::OracleExecutionRequest.new(
            repository: repository, source_path: "test.rb", test_command: ["ruby", "test.rb"],
            mutant_commands: {"m1" => ["ruby", "test.rb"]}, test_id: "t1", fact: fact_value,
            plan: Evidence::OracleMutationPlanner.plan(fact_value).fetch(0), language: "ruby", trial_count: 1,
          ),
        )
        assert_equal Evidence::TestOutcome::Passed, result.baseline_outcome, framework
        assert_equal Evidence::TestOutcome::Passed, result.disabled_control_outcome, framework
        assert_equal Evidence::TestOutcome::AssertionFailure, result.control_outcome, framework
        assert result.control_verified?, framework
        assert_equal 1, result.disabled_trials.length, framework
      end
    end
  end

  def test_oracle_execution_runs_real_pytest_junit_and_jest_fixtures
    jest_bin = ENV["TEST_MISER_JEST_BIN"] || File.expand_path("../../../node_modules/.bin/jest", __dir__)
    fixtures = {
      "pytest" => {
        language: "python", source_path: "test_example.py",
        source: <<~PYTHON,
          from source import calculate

          def test_value():
              assert calculate() == 2
        PYTHON
        support: {"source.py" => "def calculate():\n    return 2\n"},
        call: "assert calculate() == 2", line: 4, framework: "pytest", kind: Evidence::OracleKind::Truthiness,
        command: ["python3", "-m", "pytest", "test_example.py", "-q"],
        available: -> { command_succeeds?("python3", "-c", "import pytest") },
      },
      "jest" => {
        language: "javascript", source_path: "test.test.js",
        source: <<~JAVASCRIPT,
          const { calculate } = require("./source");

          test("value", () => {
            expect(calculate()).toBe(2);
          });
        JAVASCRIPT
        support: {
          "source.js" => "function calculate() { return 2; }\nmodule.exports = { calculate };\n",
          "package.json" => "{\"jest\":{}}\n",
        },
        call: "expect(calculate()).toBe(2)", line: 4, framework: "jest", kind: Evidence::OracleKind::Identity,
        command: [jest_bin, "test.test.js", "--runInBand"],
        available: -> { File.executable?(jest_bin) },
      },
      "junit" => {
        language: "java", source_path: "src/test/java/CalculatorTest.java",
        source: <<~JAVA,
          import static org.junit.jupiter.api.Assertions.assertEquals;
          import static org.junit.jupiter.api.Assertions.assertNotEquals;
          import org.junit.jupiter.api.Test;

          class CalculatorTest {
            @Test void value() {
              assertEquals(2, Calculator.calculate());
            }
          }
        JAVA
        support: {
          "pom.xml" => <<~XML,
            <project xmlns="http://maven.apache.org/POM/4.0.0">
              <modelVersion>4.0.0</modelVersion>
              <groupId>test.miser</groupId><artifactId>oracle-fixture</artifactId><version>1.0</version>
              <properties><maven.compiler.release>17</maven.compiler.release></properties>
              <dependencies>
                <dependency><groupId>org.junit.jupiter</groupId><artifactId>junit-jupiter</artifactId><version>5.11.0</version><scope>test</scope></dependency>
              </dependencies>
              <build><plugins><plugin><groupId>org.apache.maven.plugins</groupId><artifactId>maven-surefire-plugin</artifactId><version>3.5.2</version></plugin></plugins></build>
            </project>
          XML
          "src/main/java/Calculator.java" => "class Calculator { static int calculate() { return 2; } }\n",
        },
        call: "assertEquals(2, Calculator.calculate())", line: 6, framework: "junit", kind: Evidence::OracleKind::Equality,
        command: ["mvn", "-q", "-Dtest=CalculatorTest", "test"],
        available: -> { command_succeeds?("mvn", "-v") },
      },
    }
    executed = []
    fixtures.each do |framework, fixture|
      next unless fixture.fetch(:available).call

      executed << framework
      Dir.mktmpdir("test-miser-#{framework}-oracle-") do |repository|
        fixture.fetch(:support).each do |path, contents|
          destination = File.join(repository, path)
          FileUtils.mkdir_p(File.dirname(destination))
          File.write(destination, contents)
        end
        source_path = File.join(repository, fixture.fetch(:source_path))
        FileUtils.mkdir_p(File.dirname(source_path))
        File.write(source_path, fixture.fetch(:source))
        Dir.chdir(repository) do
          system("git init -q && git config user.email t@t && git config user.name t && git add -A && git commit -qm fixture", exception: true)
        end
        fact_value = Evidence::OracleFact.new(
          oracle_id: "#{framework}-e2e", test_id: "#{fixture.fetch(:framework)}:CalculatorTest#value",
          oracle_kind: fixture.fetch(:kind), oracle_span: oracle_source_span(fixture.fetch(:source), fixture.fetch(:line), fixture.fetch(:call)),
          framework: fixture.fetch(:framework), confidence: 1.0,
        )
        result = Evidence::OracleExecutionRunner.new.run(
          Evidence::OracleExecutionRequest.new(
            repository: repository, source_path: fixture.fetch(:source_path), test_command: fixture.fetch(:command),
            mutant_commands: {"m1" => fixture.fetch(:command)}, test_id: fact_value.test_id, fact: fact_value,
            plan: Evidence::OracleMutationPlanner.plan(fact_value).fetch(0), language: fixture.fetch(:language), trial_count: 1,
          ),
        )
        assert_equal Evidence::TestOutcome::Passed, result.baseline_outcome, "#{framework}: #{result.to_h.inspect}"
        assert_equal Evidence::TestOutcome::Passed, result.disabled_control_outcome, framework
        assert_equal Evidence::TestOutcome::AssertionFailure, result.control_outcome, framework
        assert result.control_verified?, framework
        assert_equal 1, result.disabled_trials.length, framework
      end
    end
    skip "pytest, JUnit, and Jest runtimes are unavailable" if executed.empty?
  end

  private

  def command_succeeds?(*command)
    _stdout, _stderr, status = Open3.capture3(*command)
    status.success?
  rescue Errno::ENOENT
    false
  end

  def factmine_fixture_runner
    runner = Object.new
    runner.define_singleton_method(:capture3) do |_binary, _command, _language_flag, language, source_path|
      calls = if source_path.end_with?("collector/setup.rb")
        [
          {"message" => "assert_equal", "receiver" => "self", "owner" => "TestMiserCollectorFixtureTest", "function" => "test_true_a", "span" => [9, 4, 9, 58]},
          {"message" => "assert_equal", "receiver" => "self", "owner" => "TestMiserCollectorFixtureTest", "function" => "test_true_b", "span" => [13, 4, 13, 58]},
        ]
      elsif source_path.end_with?("example_spec.rb")
        [
          {"message" => "expect", "receiver" => "self", "owner" => "example_spec", "function" => "(top-level)", "line" => 9, "span" => [9, 4, 9, 34]},
          {"message" => "eq", "receiver" => "self", "owner" => "example_spec", "function" => "(top-level)", "line" => 9, "span" => [9, 38, 9, 51]},
          {"message" => "eq", "receiver" => "self", "owner" => "example_spec", "function" => "(top-level)", "line" => 13, "span" => [13, 38, 13, 51]},
        ]
      else
        [
          {"message" => "assertEquals", "receiver" => "self", "owner" => "ClassifierTest", "function" => "positivePrimary", "span" => [9, 35, 9, 83]},
          {"message" => "assertEquals", "receiver" => "self", "owner" => "ClassifierTest", "function" => "positiveDuplicate", "span" => [10, 37, 10, 85]},
        ]
      end
      [JSON.generate("documents" => [{"calls" => calls}]), "", Evidence::CommandResult.new(status: 0, stdout: "", stderr: "")]
    end
    runner
  end

  class FakeTreeNode
    Point = Struct.new(:row, :column)
    attr_reader :kind, :text, :children, :start_point, :end_point, :start_byte, :end_byte

    def initialize(kind:, text:, start_point:, end_point:, start_byte:, end_byte:, fields: {}, children: [])
      @kind = kind
      @text = text
      @start_point = Point.new(*start_point)
      @end_point = Point.new(*end_point)
      @start_byte = start_byte
      @end_byte = end_byte
      @fields = fields
      @children = children
    end

    def child_by_field_name(name)
      @fields[name]
    end
  end

  class FakeTree
    attr_reader :root_node

    def initialize(root_node)
      @root_node = root_node
    end
  end

  class FakeTreeSitterBinding
    class << self
      def languages
        @languages ||= []
      end

      def register_language(language, _grammar)
        languages << language unless languages.include?(language)
      end
    end

    class Parser
      attr_accessor :language

      def parse(source)
        lines = source.lines
        line_index = lines.index { |line| line.include?("assert_equal") || line.include?("expect(") }
        line_index ||= 0
        line = lines.fetch(line_index)
        column = line.index(/(?:assert_equal|expect\()/) || 0
        text = line.strip
        start_byte = lines.first(line_index).sum(&:bytesize) + column
        end_byte = start_byte + text.bytesize
        identifier_text = text.start_with?("expect") ? "eq" : "assert_equal"
        matcher = FakeTreeNode.new(
          kind: "call", text: text, start_point: [line_index, column], end_point: [line_index, column + text.bytesize],
          start_byte: start_byte, end_byte: end_byte,
          fields: {"method" => FakeTreeNode.new(kind: "identifier", text: identifier_text, start_point: [line_index, column], end_point: [line_index, column], start_byte: start_byte, end_byte: start_byte),
                   "receiver" => text.start_with?("expect") ? FakeTreeNode.new(kind: "call", text: "expect(...)", start_point: [line_index, column], end_point: [line_index, column], start_byte: start_byte, end_byte: start_byte) : nil},
          children: [],
        )
        if text.start_with?("expect")
          expect_end = start_byte + text.index(")") + 1
          expect = FakeTreeNode.new(
            kind: "call", text: text[0...text.index(")") + 1], start_point: [line_index, column], end_point: [line_index, column + text.index(")") + 1],
            start_byte: start_byte, end_byte: expect_end,
            fields: {"method" => FakeTreeNode.new(kind: "identifier", text: "expect", start_point: [line_index, column], end_point: [line_index, column], start_byte: start_byte, end_byte: start_byte)},
            children: [],
          )
          FakeTree.new(FakeTreeNode.new(kind: "root", text: source, start_point: [0, 0], end_point: [lines.length, 0], start_byte: 0, end_byte: source.bytesize, children: [expect, matcher]))
        else
          FakeTree.new(FakeTreeNode.new(kind: "root", text: source, start_point: [0, 0], end_point: [lines.length, 0], start_byte: 0, end_byte: source.bytesize, children: [matcher]))
        end
      end
    end
  end

  def span
    Evidence::SourceSpan.new(start_line: 1, start_column: 1, end_line: 1, end_column: 8, start_offset: 0, end_offset: 7)
  end

  def oracle_source_span(source, line, text)
    line_text = source.lines.fetch(line - 1)
    column = line_text.index(text)
    raise "fixture oracle text missing" if column.nil?

    start_offset = source.lines.first(line - 1).sum(&:bytesize) + column
    Evidence::SourceSpan.new(
      start_line: line, start_column: column + 1, end_line: line, end_column: column + text.bytesize + 1,
      start_offset: start_offset, end_offset: start_offset + text.bytesize,
    )
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

  def source_fact(framework, source, expected: false)
    span = Evidence::SourceSpan.new(
      start_line: 1, start_column: 1, end_line: 1, end_column: source.bytesize + 1,
      start_offset: 0, end_offset: source.bytesize,
    )
    Evidence::OracleFact.new(
      oracle_id: "source-#{framework}", test_id: "t1", oracle_kind: Evidence::OracleKind::Equality,
      oracle_span: span, expected_span: expected ? span : nil,
      framework: framework, confidence: 1.0,
    )
  end

  def execution_result(oracle_id, control_verified: true)
    {
      "disabled_rewrite" => {"oracle_id" => oracle_id, "applied" => true},
      "control_rewrite" => {"applied" => true},
      "control_outcome" => control_verified ? "ASSERTION_FAILURE" : "PASSED",
      "control_verified" => control_verified,
    }
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

  def trial(test_id, oracle_id, mutant_id, killed:, executed: true, trial: 0, trial_id: "legacy", outcome: nil)
    Evidence::OracleTrial.new(
      test_id: test_id,
      oracle_id: oracle_id,
      mutant_id: mutant_id,
      killed: killed,
      executed: executed,
      trial: trial,
      trial_id: trial_id,
      outcome: outcome,
    )
  end

  class OracleFakeRunner
    include Evidence::CommandRunner

    def run(command, chdir:, limits:)
      case command.first
      when "baseline"
        Evidence::CommandResult.new(status: 0, stdout: "", stderr: "")
      when "control"
        source_path = File.file?(File.join(chdir, "lib/test.rb")) ? "lib/test.rb" : "test.rb"
        source = File.read(File.join(chdir, source_path))
        if source.include?("refute_equal")
          Evidence::CommandResult.new(status: 1, stdout: "", stderr: "Minitest::Assertion")
        else
          Evidence::CommandResult.new(status: 0, stdout: "", stderr: "")
        end
      when "mutant"
        Evidence::CommandResult.new(status: 1, stdout: "", stderr: "Minitest::Assertion")
      else
        Evidence::CommandResult.new(status: 1, stdout: "", stderr: "Minitest::Assertion")
      end
    end
  end

  class RevisionRecordingAdapter
    include Evidence::OracleRewriteAdapter

    attr_reader :sources

    def initialize
      @sources = []
    end

    def rewrite(fact:, plan:, source:, language:)
      @sources << source
      [source, Evidence::OracleRewrite.new(
        oracle_id: fact.oracle_id, mutation: plan.mutation, recognized: true, applied: true, reason: "fixture",
      )]
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
