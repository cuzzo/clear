# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "fileutils"
require "open3"
require "tmpdir"

# Round-trip for the checkpoint -> ledger path described in
# docs/agents/lineage-sync.md: a materialized mutation corpus (per-suite
# mutant-facts/v1 plus the combined Weak Tests SARIF) ingests into lineage.db
# through gems/lineage/tools/ingest_mutation_corpus.rb.
class LineageIngestIntegrationTest < Minitest::Test
  LINEAGE_BIN = File.expand_path("../../gigasail/target/release/giga", __dir__)
  INGEST_TOOL = File.expand_path("../../gigasail/tools/ingest_mutation_corpus.rb", __dir__)

  def test_materialized_corpus_ingests_mutants_and_weak_tests
    skip "lineage binary missing; build gems/gigasail first" unless File.executable?(LINEAGE_BIN)
    begin
      require "sqlite3"
    rescue LoadError
      skip "sqlite3 gem unavailable"
    end

    Dir.mktmpdir do |root|
      repo = File.join(root, "repo")
      materialized = File.join(root, "materialized")
      FileUtils.mkdir_p([File.join(repo, "src"), materialized])

      Dir.chdir(repo) do
        system("git init -q && git config user.email t@t && git config user.name t", exception: true)
        File.write("src/worker.rb", "class Worker\n  def run\n    1\n  end\nend\n")
        File.write("src/worker_test.rb", "def test_run; end\n")
        system("git add -A && git commit -qm init", exception: true)
      end
      commit = Dir.chdir(repo) { `git rev-parse HEAD`.strip }

      File.write(File.join(materialized, "mutant-facts-abc123.json"), JSON.generate(
        "schema" => "mutant-facts/v1",
        "source" => "test-miser-corpus",
        "language" => "ruby",
        "mutation_kind" => "stochastic",
        "subjects" => [{
          "file" => "src/worker.rb", "method" => "Worker#run",
          "kill_rate" => 50.0, "mutations" => 2, "killed" => 1, "alive" => 1
        }],
        "tests" => [{ "id" => "test:test_run", "name" => "test_run", "file" => "src/worker_test.rb" }],
        "mutants" => [
          { "id" => "src/worker.rb:1", "covered_by" => ["test:test_run"], "killed_by" => ["test:test_run"] },
          { "id" => "src/worker.rb:2", "covered_by" => ["test:test_run"], "killed_by" => [] }
        ],
        "test_miser" => {
          "complete" => true, "attribution_complete" => true, "run_to_complete" => true,
          "commit" => commit, "suite" => "ruby:demo"
        }
      ))
      File.write(File.join(materialized, "weak-tests.sarif"), JSON.generate(
        "$schema" => "https://json.schemastore.org/sarif-2.1.0.json",
        "version" => "2.1.0",
        "runs" => [{
          "tool" => { "driver" => { "name" => "test-miser", "rules" => [{ "id" => "test-miser.zero-kill" }] } },
          "properties" => { "format" => "test-miser.report.sarif.v1" },
          "results" => [{
            "ruleId" => "test-miser.zero-kill", "level" => "warning",
            "message" => { "text" => "test kills no mutants" },
            "locations" => [{
              "physicalLocation" => {
                "artifactLocation" => { "uri" => "src/worker_test.rb" },
                "region" => { "startLine" => 1 }
              }
            }]
          }]
        }]
      ))
      File.write(File.join(materialized, "evidence.sarif"), JSON.generate(
        "$schema" => "https://json.schemastore.org/sarif-2.1.0.json",
        "version" => "2.1.0",
        "runs" => [{
          "tool" => { "driver" => { "name" => "test-miser", "rules" => [{ "id" => "test-miser.evidence.persists_without_oracle" }] } },
          "properties" => { "format" => "test-miser.evidence.sarif.v1" },
          "results" => [{
            "ruleId" => "test-miser.evidence.persists_without_oracle", "level" => "warning",
            "message" => { "text" => "kill persists without this oracle" },
            "locations" => [{ "physicalLocation" => { "artifactLocation" => { "uri" => "src/worker_test.rb" }, "region" => { "startLine" => 1 } } }]
          }]
        }]
      ))

      db = File.join(repo, "gigasail.db")
      run!([LINEAGE_BIN, "init", "--db", db], repo)
      run!([LINEAGE_BIN, "build", "--db", db, "--repo", repo], repo)
      out = run!(["ruby", INGEST_TOOL, "--db=#{db}", "--repo=#{repo}",
                  "--materialized=#{materialized}", "--giga-bin=#{LINEAGE_BIN}"], repo)

      assert_includes out, "exposure_events=3"
      assert_includes out, "ingested 1 mutant-facts file(s) at commit #{commit}"

      rows = SQLite3::Database.new(db).execute(
        "SELECT source, rule_id, path, run_format FROM sarif_findings"
      ).sort
      assert_equal [
        ["test-miser", "test-miser.zero-kill", "src/worker_test.rb", "test-miser.report.sarif.v1"],
        ["test-miser-evidence", "test-miser.evidence.persists_without_oracle", "src/worker_test.rb", "test-miser.evidence.sarif.v1"],
      ], rows

      exposure = SQLite3::Database.new(db).execute("SELECT COUNT(*) FROM test_exposure_events").first.first
      assert_equal 3, exposure
    end
  end

  # Real bug: two mutant-facts files carrying different test_miser.commit
  # values used to silently ingest under whichever commit sorted first,
  # then tag the combined weak-tests.sarif against that same, possibly
  # wrong, commit for every suite - corrupting the ledger's history with no
  # visible error.
  def test_mixed_commit_facts_files_are_rejected_not_silently_merged
    skip "lineage binary missing; build gems/gigasail first" unless File.executable?(LINEAGE_BIN)

    Dir.mktmpdir do |root|
      materialized = File.join(root, "materialized")
      FileUtils.mkdir_p(materialized)
      db = File.join(root, "gigasail.db")

      write_mutant_facts(materialized, "abc111", suite: "ruby:one")
      write_mutant_facts(materialized, "def222", suite: "ruby:two")
      write_weak_tests_sarif(materialized)

      stdout, stderr, status = Open3.capture3(
        "ruby", INGEST_TOOL, "--db=#{db}", "--repo=#{root}",
        "--materialized=#{materialized}", "--giga-bin=#{LINEAGE_BIN}"
      )

      refute status.success?, "expected mixed-commit ingestion to fail, got: #{stdout}"
      assert_includes stderr + stdout, "multiple commits"
    end
  end

  # Real bug: a materialized directory missing weak-tests.sarif only
  # printed a warning and otherwise completed successfully, so an
  # explicitly requested ingestion of an incomplete corpus looked
  # indistinguishable from a full, successful one.
  def test_missing_weak_tests_sarif_fails_loudly_rather_than_warning
    skip "lineage binary missing; build gems/gigasail first" unless File.executable?(LINEAGE_BIN)

    Dir.mktmpdir do |root|
      repo = File.join(root, "repo")
      materialized = File.join(root, "materialized")
      FileUtils.mkdir_p([File.join(repo, "src"), materialized])

      Dir.chdir(repo) do
        system("git init -q && git config user.email t@t && git config user.name t", exception: true)
        File.write("src/worker.rb", "class Worker\n  def run\n    1\n  end\nend\n")
        File.write("src/worker_test.rb", "def test_run; end\n")
        system("git add -A && git commit -qm init", exception: true)
      end
      commit = Dir.chdir(repo) { `git rev-parse HEAD`.strip }
      db = File.join(repo, "gigasail.db")

      write_mutant_facts(materialized, commit, suite: "ruby:one")

      run!([LINEAGE_BIN, "init", "--db", db], repo)
      run!([LINEAGE_BIN, "build", "--db", db, "--repo", repo], repo)
      stdout, stderr, status = Open3.capture3(
        "ruby", INGEST_TOOL, "--db=#{db}", "--repo=#{repo}",
        "--materialized=#{materialized}", "--giga-bin=#{LINEAGE_BIN}"
      )

      refute status.success?, "expected a missing weak-tests.sarif to fail, got: #{stdout}"
      assert_includes stderr + stdout, "weak-tests.sarif missing"
    end
  end

  private

  def write_mutant_facts(directory, commit, suite:)
    File.write(File.join(directory, "mutant-facts-#{commit}.json"), JSON.generate(
      "schema" => "mutant-facts/v1",
      "source" => "test-miser-corpus",
      "language" => "ruby",
      "mutation_kind" => "stochastic",
      "subjects" => [{
        "file" => "src/worker.rb", "method" => "Worker#run",
        "kill_rate" => 50.0, "mutations" => 2, "killed" => 1, "alive" => 1
      }],
      "tests" => [{ "id" => "test:test_run", "name" => "test_run", "file" => "src/worker_test.rb" }],
      "mutants" => [
        { "id" => "src/worker.rb:1", "covered_by" => ["test:test_run"], "killed_by" => ["test:test_run"] },
        { "id" => "src/worker.rb:2", "covered_by" => ["test:test_run"], "killed_by" => [] }
      ],
      "test_miser" => {
        "complete" => true, "attribution_complete" => true, "run_to_complete" => true,
        "commit" => commit, "suite" => suite
      }
    ))
  end

  def write_weak_tests_sarif(directory)
    File.write(File.join(directory, "weak-tests.sarif"), JSON.generate(
      "$schema" => "https://json.schemastore.org/sarif-2.1.0.json",
      "version" => "2.1.0",
      "runs" => [{
        "tool" => { "driver" => { "name" => "test-miser", "rules" => [{ "id" => "test-miser.zero-kill" }] } },
        "properties" => { "format" => "test-miser.report.sarif.v1" },
        "results" => [{
          "ruleId" => "test-miser.zero-kill", "level" => "warning",
          "message" => { "text" => "test kills no mutants" },
          "locations" => [{
            "physicalLocation" => {
              "artifactLocation" => { "uri" => "src/worker_test.rb" },
              "region" => { "startLine" => 1 }
            }
          }]
        }]
      }]
    ))
    File.write(File.join(directory, "evidence.sarif"), JSON.generate(
      "$schema" => "https://json.schemastore.org/sarif-2.1.0.json",
      "version" => "2.1.0",
      "runs" => [{
        "tool" => { "driver" => { "name" => "test-miser", "rules" => [{ "id" => "test-miser.evidence.unknown" }] } },
        "properties" => { "format" => "test-miser.evidence.sarif.v1" },
        "results" => []
      }]
    ))
  end

  def run!(command, chdir)
    stdout, stderr, status = Open3.capture3(*command, chdir: chdir)
    assert status.success?, "#{command.join(" ")} failed: #{stderr}\n#{stdout}"
    stdout
  end
end
