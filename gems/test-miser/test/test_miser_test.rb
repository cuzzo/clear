# frozen_string_literal: true

require "json"
require "fileutils"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "../lib/test_miser"
require_relative "../lib/test_miser/mutant_collector"
require_relative "../lib/test_miser/mutant_report_merger"
require_relative "../lib/test_miser/subject_inventory"

class TestMiserTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/espalier-mutation-report.json", __dir__)

  def setup
    @analysis = TestMiser::Analyzer.new(TestMiser::MutationReport.load_files([FIXTURE])).analyze
  end

  def test_flags_tests_that_kill_no_mutants
    rows = @analysis.zero_kill_tests.to_h { |result| [result.test.id, result] }

    assert_equal %w[alias:no-kill alias:not-covered], rows.keys.sort
    assert_equal 1, rows.fetch("alias:no-kill").covered_mutants.length
    assert_empty rows.fetch("alias:not-covered").covered_mutants
  end

  def test_groups_exact_nonempty_kill_sets
    groups = @analysis.redundant_groups

    assert_equal [3, 2], groups.map { |group| group.tests.length }
    assert_equal %w[gap:untraced-a gap:untraced-b gap:untraced-c], groups.first.tests.map(&:id)
    assert_equal 2, groups.first.killed_mutants.length
    assert_equal %w[gap:direct gap:transitive], groups.last.tests.map(&:id)
    assert_equal 1, groups.last.killed_mutants.length
  end

  def test_does_not_group_empty_kill_sets_as_redundant
    grouped_ids = @analysis.redundant_groups.flat_map { |group| group.tests.map(&:id) }

    refute_includes grouped_ids, "alias:no-kill"
    refute_includes grouped_ids, "alias:not-covered"
  end

  def test_emits_machine_readable_summary
    payload = JSON.parse(TestMiser::Reporter.new(@analysis).json)

    assert_equal "test-miser/v1", payload.fetch("schema")
    assert_equal 8, payload.dig("summary", "tests")
    assert_equal 5, payload.dig("summary", "mutants")
    assert_equal 2, payload.dig("summary", "tests_that_kill_no_mutants")
    assert_equal 2, payload.dig("summary", "possibly_redundant_groups")
  end

  def test_consumes_native_mutant_facts_and_emits_lineage_sarif
    payload = {
      "schema" => "mutant-facts/v1",
      "source" => "probe",
      "language" => "ruby",
      "subjects" => [{ "file" => "lib/example.rb", "method" => "Example#value" }],
      "tests" => [
        { "id" => "test:a", "name" => "ExampleTest#test_a", "file" => "test/example_test.rb", "line" => 12 },
        { "id" => "test:b", "name" => "ExampleTest#test_b", "file" => "test/example_test.rb", "line" => 18 }
      ],
      "mutants" => [{
        "id" => "lib/example.rb:1", "file" => "lib/example.rb", "outcome" => "killed",
        "covered_by" => ["test:a", "test:b"], "killed_by" => ["test:a"]
      }],
      "test_miser" => { "complete" => true, "attribution_complete" => true }
    }

    report = TestMiser::MutationReport.new(payload)
    sarif = JSON.parse(TestMiser::Reporter.new(TestMiser::Analyzer.new(report).analyze).sarif)
    result = sarif.dig("runs", 0, "results", 0)

    assert_equal true, report.corpus_complete
    assert_equal "test-miser.zero-kill", result.fetch("ruleId")
    assert_equal "test:b", result.dig("properties", "testId")
    assert_equal "test/example_test.rb", result.dig("locations", 0, "physicalLocation", "artifactLocation", "uri")
    assert_equal 18, result.dig("locations", 0, "physicalLocation", "region", "startLine")
    assert_equal "test-miser.report.sarif.v1", sarif.dig("runs", 0, "properties", "format")
  end

  def test_infer_finds_missing_test_line_from_source
    Dir.mktmpdir("test-miser-location") do |dir|
      path = File.join(dir, "test/example_test.rb")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "class ExampleTest\n  def test_value\n  end\nend\n")
      report = TestMiser::MutationReport.from_records(
        [TestMiser::Test.new(id: "test:value", name: "ExampleTest#test_value", file: "test/example_test.rb")],
        [],
        corpus_metadata: { "complete" => true }
      )

      resolved = TestMiser::LocationResolver.new(root: dir).call(report)

      assert_equal 2, resolved.tests.first.line
    end
  end

  def test_markdown_distinguishes_uncovered_from_covered_zero_kill_tests
    markdown = TestMiser::Reporter.new(@analysis).markdown

    assert_includes markdown, "## Tests That Kill No Mutants"
    assert_includes markdown, "AliasRecommendationsTest#test_reference_kind"
    assert_includes markdown, "covered but killed none"
    assert_includes markdown, "AliasRecommendationsTest#test_empty_input"
    assert_includes markdown, "not mutation-covered"
    assert_includes markdown, "### Group 1: 3 tests, 2 identical kills"
    assert_includes markdown, "Killed mutant sample:"
  end

  def test_merges_sharded_reports
    payload = JSON.parse(File.read(FIXTURE))
    first = Marshal.load(Marshal.dump(payload))
    second = Marshal.load(Marshal.dump(payload))
    first["files"].delete("gems/espalier/lib/espalier/alias_recommendations.rb")
    second["files"].delete("gems/espalier/lib/espalier/big_o_gap_impact.rb")

    Dir.mktmpdir("test-miser-shards") do |dir|
      first_path = File.join(dir, "first.json")
      second_path = File.join(dir, "second.json")
      File.write(first_path, JSON.generate(first))
      File.write(second_path, JSON.generate(second))

      report = TestMiser::MutationReport.load_files([first_path, second_path])

      assert_equal 5, report.mutants.length
      assert_equal 8, report.tests.length
    end
  end

  def test_merges_distinct_complete_component_corpora
    payloads = %w[first second].each_with_index.map do |name, index|
      {
        "schemaVersion" => "2.0",
        "files" => {
          "lib/#{name}.rb" => {
            "mutants" => [{ "id" => index.to_s, "coveredBy" => [], "killedBy" => [] }]
          }
        },
        "testFiles" => {},
        "testMiser" => {
          "corpusFingerprint" => name,
          "expectedMutants" => 1,
          "complete" => true,
          "runToComplete" => true,
          "attributionMode" => "audit-candidate-elimination",
          "killSetsComplete" => false,
          "subjectExpressions" => ["Example##{name}"],
          "mutationCompatibleSubjects" => ["Example##{name}"]
        }
      }
    end

    merged = TestMiser::MutantReportMerger.call(payloads)

    assert_equal true, merged.dig("testMiser", "complete")
    assert_equal 2, merged.dig("testMiser", "expectedMutants")
    assert_equal 2, merged.dig("testMiser", "componentCorpora")
    assert_equal true, merged.dig("testMiser", "runToComplete")
    assert_equal "audit-candidate-elimination", merged.dig("testMiser", "attributionMode")
    assert_equal false, merged.dig("testMiser", "killSetsComplete")
    assert_equal 2, merged.fetch("files").values.sum { |file| file.fetch("mutants").length }
  end

  def test_subject_inventory_does_not_duplicate_module_function_copy
    fixture = File.expand_path("fixtures/collector/module_target", __dir__)
    require fixture

    entries = TestMiser::SubjectInventory.new(
      namespace: "TestMiserModuleFunctionFixture",
      roots: [File.dirname(fixture)]
    ).call

    assert_equal ["TestMiserModuleFunctionFixture#classify"], entries.map(&:expression)
  end

  def test_rejects_non_mutation_testing_elements_input
    error = assert_raises(TestMiser::InvalidReport) do
      TestMiser::MutationReport.new({ "subjects" => [] }, source: "bad.json")
    end

    assert_includes error.message, "bad.json"
  end

  def test_cli_reports_the_espalier_fixture
    executable = File.expand_path("../exe/test-miser", __dir__)
    stdout, stderr, status = Open3.capture3("ruby", executable, "--format", "json", FIXTURE)

    assert status.success?, stderr
    assert_equal 2, JSON.parse(stdout).dig("summary", "tests_that_kill_no_mutants")
  end

  def test_cli_infer_defaults_to_sarif_and_scans_test_source
    executable = File.expand_path("../exe/test-miser", __dir__)
    Dir.mktmpdir("test-miser-infer") do |dir|
      FileUtils.mkdir_p(File.join(dir, "test"))
      File.write(File.join(dir, "test/example_test.rb"), "def test_empty\nend\n")
      facts = {
        "schema" => "mutant-facts/v1",
        "subjects" => [{ "file" => "lib/example.rb", "method" => "Example#run" }],
        "tests" => [{ "id" => "test:empty", "name" => "ExampleTest#test_empty", "file" => "test/example_test.rb" }],
        "mutants" => [{ "id" => "m1", "file" => "lib/example.rb", "covered_by" => [], "killed_by" => [] }],
        "test_miser" => { "complete" => true, "attribution_complete" => true, "run_to_complete" => true }
      }
      facts_path = File.join(dir, "mutant-facts.json")
      File.write(facts_path, JSON.generate(facts))

      stdout, stderr, status = Open3.capture3(
        "ruby", executable, "infer", "--root", dir, facts_path
      )
      sarif = JSON.parse(stdout)

      assert status.success?, stderr
      assert_equal "2.1.0", sarif.fetch("version")
      assert_equal 1, sarif.dig("runs", 0, "results", 0, "locations", 0, "physicalLocation", "region", "startLine")
    end
  end

  def test_mutant_collector_records_individual_killers
    executable = File.expand_path("../exe/test-miser-mutant", __dir__)
    setup = File.expand_path("fixtures/collector/setup", __dir__)

    Dir.mktmpdir("test-miser-collector") do |dir|
      report_path = File.join(dir, "mutants.json")
      _stdout, stderr, status = Open3.capture3(
        "bundle", "exec", "ruby", executable,
        "-r", setup,
        "--run-to-complete",
        "-o", report_path,
        "TestMiserCollectorFixture#classify"
      )

      assert status.success?, stderr
      report = TestMiser::MutationReport.load_files([report_path])
      analysis = TestMiser::Analyzer.new(report).analyze

      assert_equal true, report.corpus_complete
      assert_equal ["minitest:TestMiserCollectorFixtureTest#test_does_not_exercise_method"],
        analysis.zero_kill_tests.map { |result| result.test.id }
      assert_equal 1, analysis.redundant_groups.length
      assert_equal 2, analysis.redundant_groups.first.tests.length
      assert_operator analysis.redundant_groups.first.killed_mutants.length, :>, 0

      _stdout, resume_stderr, resume_status = Open3.capture3(
        "bundle", "exec", "ruby", executable,
        "-r", setup,
        "--run-to-complete",
        "--jobs", "2",
        "--resume",
        "-o", report_path,
        "TestMiserCollectorFixture#classify"
      )
      assert resume_status.success?, resume_stderr
      assert_equal 2, Dir["#{report_path}.shards/*.json"].length
    end
  end

  def test_mutant_collector_withholds_audit_without_run_to_complete
    executable = File.expand_path("../exe/test-miser-mutant", __dir__)
    setup = File.expand_path("fixtures/collector/setup", __dir__)

    Dir.mktmpdir("test-miser-standard-mutant") do |dir|
      report_path = File.join(dir, "mutants.json")
      _stdout, stderr, status = Open3.capture3(
        "bundle", "exec", "ruby", executable,
        "-r", setup,
        "-o", report_path,
        "TestMiserCollectorFixture#classify"
      )

      assert status.success?, stderr
      payload = JSON.parse(File.read(report_path))
      assert_equal false, payload.dig("testMiser", "runToComplete")
      assert_equal false, payload.dig("testMiser", "complete")
      assert payload.fetch("files").values.flat_map { |file| file.fetch("mutants") }
        .any? { |mutant| mutant.fetch("status") == "Killed" && mutant.fetch("killedBy").empty? }
    end
  end

  def test_mutant_collector_refreshes_module_function_copy
    executable = File.expand_path("../exe/test-miser-mutant", __dir__)
    setup = File.expand_path("fixtures/collector/module_setup", __dir__)

    Dir.mktmpdir("test-miser-module-function") do |dir|
      report_path = File.join(dir, "mutants.json")
      _stdout, stderr, status = Open3.capture3(
        "bundle", "exec", "ruby", executable,
        "-r", setup,
        "--run-to-complete",
        "-o", report_path,
        "TestMiserModuleFunctionFixture#classify"
      )

      assert status.success?, stderr
      payload = JSON.parse(File.read(report_path))
      mutants = payload.fetch("files").values.flat_map { |file| file.fetch("mutants") }

      assert mutants.any? { |mutant| mutant.fetch("status") == "Killed" }
      assert mutants.any? { |mutant| !mutant.fetch("killedBy").empty? }
    end
  end

  def test_mutant_collector_removes_isolated_test_scratch_files
    collector = TestMiser::MutantCollector.allocate
    leaked_path = nil

    collector.__send__(:with_scratch_directory) do
      leaked_path = File.join(Dir.tmpdir, "mutation-disabled-cleanup")
      File.write(leaked_path, "temporary mutant output")
    end

    refute File.exist?(leaked_path)
  end

  def test_mutant_timeout_kills_external_descendants
    Dir.mktmpdir("test-miser-process-group") do |dir|
      marker = File.join(dir, "orphan-survived")
      isolation = ::Mutant::Isolation::Fork.new(world: ::Mutant::WORLD)
      result = isolation.call(0.05) do
        system(RbConfig.ruby, "-e", "sleep 0.5; File.write(ARGV.fetch(0), 'alive')", marker)
      end

      sleep 0.7
      assert result.timeout
      refute File.exist?(marker)
    end
  end

  def test_run_to_complete_attributes_a_per_test_timeout
    test = Struct.new(:id).new("minitest:HangingTest#test_hangs")
    test_case = Object.new
    test_case.define_singleton_method(:call) { |_reporter| sleep 0.1 }
    integration = Object.new
    integration.define_singleton_method(:all_tests_index) { { test => test_case } }

    result = TestMiser::RunToCompleteMinitest.call(integration, [test], timeout: 0.01)

    assert_equal false, result.fetch("passed")
    assert_equal [test.id], result.fetch("killedBy")
  end

  def test_incomplete_generated_corpus_withholds_findings
    payload = JSON.parse(File.read(FIXTURE))
    payload["testMiser"] = {
      "corpusFingerprint" => "partial",
      "expectedMutants" => 6,
      "complete" => false
    }

    analysis = TestMiser::Analyzer.new(TestMiser::MutationReport.new(payload)).analyze

    assert_equal false, analysis.corpus_complete
    assert_empty analysis.zero_kill_tests
    assert_empty analysis.redundant_groups
    assert_includes TestMiser::Reporter.new(analysis).markdown, "Audit findings are withheld"
  end

  def test_infection_adapter_merges_junit_inventory_and_all_killers
    Dir.mktmpdir("test-miser-infection") do |dir|
      html = File.join(dir, "infection.html")
      junit = File.join(dir, "junit.xml")
      report = {
        "files" => { "src/value.php" => { "mutants" => [{
          "id" => "m1", "status" => "Killed", "killedBy" => %w[a b], "coveredBy" => %w[a b]
        }] } },
        "testFiles" => { "tests/ValueTest.php" => { "tests" => [
          { "id" => "a", "name" => "ValueTest::testPrimary" },
          { "id" => "b", "name" => "ValueTest::testDuplicate" }
        ] } }
      }
      File.write(html, "<script>app.report = #{JSON.generate(report)}\n;</script>")
      File.write(junit, <<~XML)
        <testsuites><testsuite>
          <testcase name="testSmoke" class="ValueTest" file="#{dir}/tests/ValueTest.php" line="4"/>
          <testcase name="testPrimary" class="ValueTest" file="#{dir}/tests/ValueTest.php" line="8"/>
          <testcase name="testDuplicate" class="ValueTest" file="#{dir}/tests/ValueTest.php" line="12"/>
        </testsuite></testsuites>
      XML

      payload = TestMiser::Adapters::Infection.new(report: html, junit: junit, root: dir).call
      analysis = TestMiser::Analyzer.new(TestMiser::MutationReport.new(payload)).analyze

      assert_equal ["ValueTest::testSmoke"], analysis.zero_kill_tests.map { |row| row.test.name }
      assert_equal %w[ValueTest::testDuplicate ValueTest::testPrimary],
        analysis.redundant_groups.first.tests.map(&:name).sort
    end
  end

  def test_mull_gtest_adapter_reads_standard_sqlite_output
    Dir.mktmpdir("test-miser-mull") do |dir|
      database_path = File.join(dir, "mull.sqlite")
      database = SQLite3::Database.new(database_path)
      database.execute <<~SQL
        CREATE TABLE mutant (
          mutant_id TEXT, mutator TEXT, filename TEXT, directory TEXT,
          line_number INT, column_number INT, end_line_number INT, end_column_number INT,
          execution_status INT, exit_status INT, duration INT, stdout TEXT, stderr TEXT,
          mutation_replacement TEXT
        )
      SQL
      output = "[  FAILED  ] Classifier.Primary (0 ms)\n[  FAILED  ] Classifier.Duplicate (0 ms)\n"
      database.execute(
        "INSERT INTO mutant VALUES (?, ?, ?, '', 2, 1, 2, 2, 1, 1, 1, ?, '', '<')",
        ["m1", "cxx_gt_to_le", "src/classifier.cpp", output]
      )
      database.close
      gtest = File.join(dir, "gtest.json")
      File.write(gtest, JSON.generate("testsuites" => [{ "name" => "Classifier", "testsuite" => [
        { "name" => "Smoke", "file" => "test.cpp", "line" => 1 },
        { "name" => "Primary", "file" => "test.cpp", "line" => 2 },
        { "name" => "Duplicate", "file" => "test.cpp", "line" => 3 }
      ] }]))

      payload = TestMiser::Adapters::MullGtest.new(
        database: database_path, gtest_json: gtest, root: dir
      ).call
      analysis = TestMiser::Analyzer.new(TestMiser::MutationReport.new(payload)).analyze

      assert_equal ["Classifier.Smoke"], analysis.zero_kill_tests.map { |row| row.test.name }
      assert_equal 1, analysis.redundant_groups.length
    end
  end

  def test_muter_adapter_verifies_every_xctest_completed
    Dir.mktmpdir("test-miser-muter") do |dir|
      FileUtils.mkdir_p(File.join(dir, "Tests/ClassifierTests"))
      File.write(File.join(dir, "Tests/ClassifierTests/ClassifierTests.swift"), <<~SWIFT)
        func testSmoke() {}
        func testPrimary() {}
        func testDuplicate() {}
      SWIFT
      logs = File.join(dir, "logs/run")
      FileUtils.mkdir_p(logs)
      baseline = %w[testSmoke testPrimary testDuplicate].map do |name|
        "Test Case 'ClassifierTests.#{name}' passed (0.0 seconds)"
      end.join("\n")
      failures = baseline.sub("testPrimary' passed", "testPrimary' failed")
        .sub("testDuplicate' passed", "testDuplicate' failed")
      File.write(File.join(logs, "baseline run.log"), baseline)
      File.write(File.join(logs, "RelationalOperatorReplacement @ Classifier.swift-2-4.log"), failures)
      report_path = File.join(dir, "muter.json")
      File.write(report_path, JSON.generate("fileReports" => [{
        "fileName" => "Classifier.swift",
        "appliedOperators" => [{
          "testSuiteOutcome" => "failed",
          "mutationPoint" => {
            "mutationOperatorId" => "RelationalOperatorReplacement",
            "position" => { "line" => 2, "column" => 4 }
          }
        }]
      }]))

      payload = TestMiser::Adapters::Muter.new(report: report_path, logs: File.join(dir, "logs"), root: dir).call
      analysis = TestMiser::Analyzer.new(TestMiser::MutationReport.new(payload)).analyze

      assert_equal true, analysis.corpus_complete
      assert_equal ["ClassifierTests.testSmoke"], analysis.zero_kill_tests.map { |row| row.test.name }
      assert_equal 1, analysis.redundant_groups.length
    end
  end
end
