# frozen_string_literal: true

require "json"
require "fileutils"
require "minitest/autorun"
require "open3"
require "pathname"
require "rbconfig"
require "tmpdir"
require_relative "../lib/test_miser"
require_relative "../lib/test_miser/mutant_collector"
require_relative "../lib/test_miser/mutant_report_merger"
require_relative "../lib/test_miser/subject_inventory"
require_relative "../../../tools/test_miser_ci_plan"

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
      shard_paths = Dir["#{report_path}.shards/*.json"]
      assert_equal 2, shard_paths.length

      merged_path = File.join(dir, "merged.json")
      merge_executable = File.expand_path("../exe/test-miser-merge", __dir__)
      _stdout, merge_stderr, merge_status = Open3.capture3(
        "bundle", "exec", "ruby", merge_executable,
        "-o", merged_path,
        *shard_paths
      )
      assert merge_status.success?, merge_stderr
      assert_equal true, JSON.parse(File.read(merged_path)).dig("testMiser", "complete")
    end
  end

  def test_mutant_collector_applies_since_and_marks_pr_scope_non_auditable
    executable = File.expand_path("../exe/test-miser-mutant", __dir__)
    setup = File.expand_path("fixtures/collector/setup", __dir__)

    Dir.mktmpdir("test-miser-since") do |dir|
      report_path = File.join(dir, "mutants.json")
      _stdout, stderr, status = Open3.capture3(
        "bundle", "exec", "ruby", executable,
        "-r", setup,
        "--run-to-complete",
        "--since", "HEAD",
        "--jobs", "2",
        "-o", report_path,
        "TestMiserCollectorFixture#classify"
      )

      assert status.success?, stderr
      payload = JSON.parse(File.read(report_path))
      assert_equal 0, payload.dig("testMiser", "expectedMutants")
      assert_equal "pr", payload.dig("testMiser", "selectionScope")
      assert_equal "HEAD", payload.dig("testMiser", "sinceRevision")
      assert_equal [], payload.dig("testMiser", "matchedSubjects")
      assert_equal true, payload.dig("testMiser", "complete")
      assert_equal 2, Dir["#{report_path}.shards/*.json"].length

      report = TestMiser::MutationReport.new(payload)
      analysis = TestMiser::Analyzer.new(report).analyze
      assert_equal false, report.corpus_complete
      assert_empty analysis.zero_kill_tests
      assert_empty analysis.redundant_groups
    end
  end

  def test_mutation_corpus_bootstrap_is_complete_compressed_and_self_contained
    Dir.mktmpdir("test-miser-corpus") do |dir|
      ruby_inventory = write_json(dir, "ruby-inventory.json", ruby_inventory_payload)
      zig_inventory = write_json(dir, "zig-inventory.json", zig_inventory_payload)
      ruby_report = write_json(dir, "ruby-report.json", ruby_report_payload)
      zig_report = write_json(dir, "zig-report.json", zig_report_payload)
      output = File.join(dir, "mutation-corpus.json.zst")
      delta = File.join(dir, "mutation-delta.json.zst")
      manifest = File.join(dir, "manifest.json")
      lineage = File.join(dir, "lineage")

      corpus = TestMiser::MutationCorpus.update(
        repository: "example/repo",
        commit: "head-1",
        parent_commit: "base-0",
        inventories: { "ruby:example" => ruby_inventory, "zig:example" => zig_inventory },
        reports: { "ruby:example" => [ruby_report], "zig:example" => [zig_report] },
        required_suites: %w[ruby:example zig:example]
      )
      manifest_payload = corpus.write(output: output, delta: delta, manifest: manifest, materialize: lineage)
      verified = TestMiser::MutationCorpus.verify!(corpus_path: output, manifest_path: manifest)

      assert_equal true, verified.fetch("complete")
      assert_equal 3, verified.fetch("components").length
      assert_equal "head-1", verified.fetch("commit")
      assert_operator File.size(output), :<, TestMiser::CanonicalJSON.generate(verified).bytesize
      facts = Dir[File.join(lineage, "mutant-facts-*.json")].map { |path| JSON.parse(File.read(path)) }
      assert_equal %w[ruby zig], facts.map { |payload| payload.fetch("language") }.sort
      assert_equal 2, manifest_payload.dig("lineage", "mutant_facts").length
      assert_equal %w[lineage/evidence.sarif lineage/weak-tests.sarif], manifest_payload.dig("lineage", "sarif")
      assert File.file?(File.join(lineage, "weak-tests.sarif"))
      assert File.file?(File.join(lineage, "evidence.sarif"))

      materialized = File.join(dir, manifest_payload.dig("lineage", "mutant_facts").first)
      File.open(materialized, "a") { |file| file.write("tampered") }
      error = assert_raises(TestMiser::CorpusError) do
        TestMiser::MutationCorpus.verify!(corpus_path: output, manifest_path: manifest)
      end
      assert_includes error.message, "member size mismatch"
    end
  end

  def test_mutation_corpus_incrementally_replaces_exact_components
    Dir.mktmpdir("test-miser-corpus-update") do |dir|
      ruby_inventory = write_json(dir, "ruby-inventory.json", ruby_inventory_payload)
      zig_inventory = write_json(dir, "zig-inventory.json", zig_inventory_payload)
      ruby_report = write_json(dir, "ruby-report.json", ruby_report_payload)
      zig_report = write_json(dir, "zig-report.json", zig_report_payload)
      base = TestMiser::MutationCorpus.update(
        repository: "example/repo",
        commit: "base",
        parent_commit: "older",
        inventories: { "ruby:example" => ruby_inventory, "zig:example" => zig_inventory },
        reports: { "ruby:example" => [ruby_report], "zig:example" => [zig_report] },
        required_suites: %w[ruby:example zig:example]
      ).payload

      changed_inventory = ruby_inventory_payload
      changed_inventory["subjects"] = [
        changed_inventory.fetch("subjects").first,
        { "expression" => "Example#third", "file" => "lib/example.rb", "line" => 9 }
      ]
      changed_report = ruby_report_payload
      changed_report["testMiser"]["selectionScope"] = "pr"
      changed_report["testMiser"]["matchedSubjects"] = ["Example#first", "Example#third"]
      changed_report["files"]["lib/example.rb"]["mutants"] = [{
        "id" => "evil:Example#third:lib/example.rb:9:new",
        "subject" => "Example#third", "line" => 9, "status" => "Killed",
        "coveredBy" => ["test:one"], "killedBy" => ["test:one"]
      }]
      inventory_path = write_json(dir, "changed-inventory.json", changed_inventory)
      report_path = write_json(dir, "changed-report.json", changed_report)
      updated = TestMiser::MutationCorpus.update(
        repository: "example/repo",
        commit: "head",
        parent_commit: "base",
        base: base,
        inventories: { "ruby:example" => inventory_path },
        reports: { "ruby:example" => [report_path] },
        required_suites: %w[ruby:example zig:example]
      )

      ruby_components = updated.payload.fetch("components").values
        .select { |component| component["suite"] == "ruby:example" }
      assert_equal %w[Example#first Example#third], ruby_components.map { |component| component["identity"] }.sort
      assert_equal 1, updated.delta.fetch("remove_components").length
      assert_equal "base", updated.delta.dig("base", "commit")
      assert_equal "head", updated.delta.dig("head", "commit")
      assert_equal true, updated.payload.fetch("complete")
    end
  end

  def test_mutation_corpus_accepts_one_native_report_for_multiple_selected_files
    Dir.mktmpdir("test-miser-multi-file-facts") do |dir|
      inventory = write_json(dir, "inventory.json", {
        "schemaVersion" => "test-miser-component-inventory/v1",
        "subjects" => [{ "source" => "src/first.rs" }, { "source" => "src/empty.rs" }]
      })
      facts = zig_report_payload
      facts["language"] = "rust"
      facts["subjects"][0]["file"] = "src/first.rs"
      facts["mutants"][0]["file"] = "src/first.rs"
      facts["test_miser"]["selected_components"] = ["src/first.rs", "src/empty.rs"]
      report = write_json(dir, "facts.json", facts)

      corpus = TestMiser::MutationCorpus.update(
        repository: "example/repo", commit: "head", parent_commit: "base",
        inventories: { "rust:example" => inventory },
        reports: { "rust:example" => [report] }, required_suites: ["rust:example"]
      ).payload

      components = corpus.fetch("components").values
      assert_equal %w[src/empty.rs src/first.rs], components.map { |row| row.fetch("identity") }.sort
      assert_empty components.find { |row| row["identity"] == "src/empty.rs" }.fetch("mutants")
    end
  end

  def test_github_artifact_store_treats_missing_or_expired_exact_base_as_cache_miss
    status = Struct.new(:success?).new(true)
    calls = []
    runner = lambda do |*argv|
      calls << argv
      [JSON.generate("artifacts" => [{
        "id" => 7, "name" => "test-miser-corpus-base", "expired" => true
      }]), "", status]
    end
    store = TestMiser::GithubArtifactStore.new(repository: "example/repo", runner: runner)

    result = store.restore(commit: "base", output: "/unused")

    assert_equal false, result.found
    assert_equal 1, calls.length
    assert_includes calls.first.last, "name=test-miser-corpus-base"
  end

  def test_mutation_corpus_rejects_a_non_parent_base
    Dir.mktmpdir("test-miser-wrong-base") do |dir|
      ruby_inventory = write_json(dir, "ruby-inventory.json", ruby_inventory_payload)
      ruby_report = write_json(dir, "ruby-report.json", ruby_report_payload)
      base = TestMiser::MutationCorpus.update(
        repository: "example/repo", commit: "base", parent_commit: "older",
        inventories: { "ruby:example" => ruby_inventory },
        reports: { "ruby:example" => [ruby_report] }, required_suites: ["ruby:example"]
      ).payload

      error = assert_raises(TestMiser::CorpusError) do
        TestMiser::MutationCorpus.update(
          repository: "example/repo", commit: "head", parent_commit: "different",
          base: base, required_suites: ["ruby:example"]
        )
      end
      assert_includes error.message, "does not equal parent"
    end
  end

  def test_ci_plan_dynamically_shards_changed_ruby_and_zig_subjects
    Dir.mktmpdir("test-miser-ci-plan") do |dir|
      FileUtils.mkdir_p(File.join(dir, "gems/espalier/lib"))
      FileUtils.mkdir_p(File.join(dir, "gems/zig-mutants"))
      FileUtils.mkdir_p(File.join(dir, "zig/runtime"))
      File.write(File.join(dir, "gems/espalier/lib/value.rb"), "VALUE = 1\n")
      File.write(File.join(dir, "zig/runtime/value.zig"), "pub const value = 1;\n")
      File.write(File.join(dir, "zig/runtime/value-test.zig"), "test \"value\" {}\n")
      File.write(File.join(dir, "gems/zig-mutants/subjects.json"), JSON.generate(
        "subjects" => [{
          "source" => "zig/runtime/value.zig",
          "test_command" => "cd zig && zig build test -Dtest-file=value-test.zig -j1",
          "timeout_seconds" => 30
        }]
      ))
      FileUtils.mkdir_p(File.join(dir, "gems/test-miser/config"))
      File.write(File.join(dir, "gems/test-miser/config/ci-suites.json"), JSON.generate(
        "schema" => "test-miser-ci-suites/v1",
        "ruby" => [{
          "id" => "espalier", "suite" => "ruby:espalier",
          "source_root" => "gems/espalier/lib", "test_root" => "gems/espalier/test",
          "namespace" => "Espalier", "require" => "espalier", "integration" => "minitest"
        }],
        "rust" => [], "go" => []
      ))
      assert system("git", "init", "-q", chdir: dir)
      assert system("git", "config", "user.email", "test@example.com", chdir: dir)
      assert system("git", "config", "user.name", "Test", chdir: dir)
      assert system("git", "add", ".", chdir: dir)
      assert system("git", "commit", "-qm", "baseline", chdir: dir)

      File.write(File.join(dir, "gems/espalier/lib/value.rb"), "VALUE = 2\nOTHER = 3\n")
      File.write(File.join(dir, "zig/runtime/value.zig"), "pub const value = 2;\n")
      File.write(File.join(dir, "zig/runtime/value-test.zig"), "test \"changed value\" {}\n")
      plan = TestMiserCIPlan::Planner.new(
        root: dir,
        base: "HEAD",
        zig_manifest: "gems/zig-mutants/subjects.json",
        lines_per_shard: 1,
        max_ruby_jobs: 3,
        max_zig_jobs: 3
      ).call

      assert_equal true, plan.dig("ruby", "run")
      assert_equal "diff", plan.dig("ruby", "matrix", "include", 0, "mode")
      assert_operator plan.dig("ruby", "matrix", "include").length, :>=, 1
      assert_equal true, plan.dig("zig", "run")
      assert_equal "full", plan.dig("zig", "matrix", "include", 0, "mode")
      assert_operator plan.dig("zig", "matrix", "include").length, :>, 1

      canonical = TestMiserCIPlan::Planner.new(
        root: dir,
        base: "HEAD",
        zig_manifest: "gems/zig-mutants/subjects.json",
        lines_per_shard: 1,
        max_ruby_jobs: 3,
        max_zig_jobs: 3,
        canonical: true,
        force_full: true
      ).call
      assert canonical.dig("ruby", "matrix", "include").all? { |row| row["mode"] == "full" }
      assert_operator canonical.dig("ruby", "matrix", "include").length, :>=, 1
      assert_equal 1, canonical.dig("zig", "matrix", "include").length
      assert_equal "full", canonical.dig("zig", "matrix", "include", 0, "mode")
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

  def test_rspec_collector_runs_every_selected_example
    executable = File.expand_path("../exe/test-miser-mutant", __dir__)
    fixture = File.expand_path("fixtures/rspec_collector", __dir__)
    spec_path = Pathname.new(File.join(fixture, "spec")).relative_path_from(Pathname.pwd).to_s
    report_path = File.join(fixture, "mutants.json")
    _stdout, stderr, status = Open3.capture3(
      "bundle", "exec", "ruby", executable,
      "-I", File.join(fixture, "lib"),
      "-r", "example",
      "--integration", "rspec",
      "--integration-argument", spec_path,
      "--run-to-complete",
      "-o", report_path,
      "TestMiserRspecFixture#classify"
    )

    assert status.success?, stderr
    payload = JSON.parse(File.read(report_path))
    killed = payload.fetch("files").values.flat_map { |file| file.fetch("mutants") }
      .select { |mutant| mutant.fetch("status") == "Killed" }
    assert killed.any? { |mutant| mutant.fetch("killedBy").length == 2 }
    tests = payload.fetch("testFiles").fetch(File.join(spec_path, "example_spec.rb")).fetch("tests")
    assert_equal [8, 12, 16], tests.map { |test| test.fetch("line") }
    assert_equal "TestMiserRspecFixture recognizes a positive value", tests.first.fetch("name")
    assert_equal true, payload.dig("testMiser", "complete")
  ensure
    File.delete(report_path) if report_path && File.exist?(report_path)
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

  private

  def write_json(directory, name, payload)
    path = File.join(directory, name)
    File.write(path, JSON.generate(payload))
    path
  end

  def ruby_inventory_payload
    {
      "schemaVersion" => "test-miser-subject-inventory/v1",
      "subjects" => [
        { "expression" => "Example#first", "file" => "lib/example.rb", "line" => 2 },
        { "expression" => "Example#second", "file" => "lib/example.rb", "line" => 6 }
      ]
    }
  end

  def zig_inventory_payload
    {
      "subjects" => [{ "source" => "src/example.zig", "test_command" => "zig build test" }]
    }
  end

  def ruby_report_payload
    mutants = %w[first second].each_with_index.map do |name, index|
      {
        "id" => "evil:Example##{name}:lib/example.rb:#{index * 4 + 2}:digest-#{name}",
        "subject" => "Example##{name}",
        "line" => index * 4 + 2,
        "status" => "Killed",
        "coveredBy" => ["test:one"],
        "killedBy" => ["test:one"]
      }
    end
    {
      "schemaVersion" => "2.0",
      "files" => { "lib/example.rb" => { "mutants" => mutants } },
      "testFiles" => {
        "test/example_test.rb" => {
          "tests" => [{ "id" => "test:one", "name" => "ExampleTest#test_one", "line" => 3 }]
        }
      },
      "testMiser" => {
        "selectionScope" => "full", "matchedSubjects" => %w[Example#first Example#second],
        "complete" => true, "runToComplete" => true
      }
    }
  end

  def zig_report_payload
    {
      "schema" => "mutant-facts/v1",
      "source" => "zig-mutants",
      "language" => "zig",
      "subjects" => [{
        "file" => "src/example.zig", "method" => "value", "mutations" => 1,
        "killed" => 1, "alive" => 0, "kill_rate" => 100.0
      }],
      "tests" => [{ "id" => "zig:test:value", "name" => "value", "file" => "src/example_test.zig", "line" => 1 }],
      "mutants" => [{
        "id" => "zig-1", "file" => "src/example.zig", "method" => "value",
        "outcome" => "killed", "line" => 2,
        "covered_by" => ["zig:test:value"], "killed_by" => ["zig:test:value"]
      }],
      "test_miser" => { "complete" => true, "attribution_complete" => true, "run_to_complete" => true }
    }
  end

  public

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

  def test_cargo_mutants_adapter_rejects_a_kill_without_a_named_failed_test
    Dir.mktmpdir("test-miser-cargo-mutants") do |dir|
      baseline_log = File.join(dir, "baseline.log")
      mutant_log = File.join(dir, "mutant.log")
      File.write(baseline_log, "test classifier::primary ... ok\n")
      File.write(mutant_log, "test classifier::primary ... ok\n")
      File.write(File.join(dir, "outcomes.json"), JSON.generate("outcomes" => [
        { "scenario" => "Baseline", "summary" => "Success", "log_path" => "baseline.log" },
        {
          "scenario" => { "Mutant" => {
            "name" => "replace comparison", "file" => "src/lib.rs", "genre" => "comparison",
            "function" => { "function_name" => "classify" },
            "span" => { "start" => { "line" => 2, "column" => 1 } }
          } },
          "summary" => "CaughtMutant", "log_path" => "mutant.log",
          "phase_results" => [{ "phase" => "Test", "argv" => ["cargo", "test", "--no-fail-fast"] }]
        }
      ]))

      payload = TestMiser::Adapters::CargoMutants.new(output_dir: dir, root: dir).call

      assert_equal false, payload.dig("test_miser", "attribution_complete")
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
