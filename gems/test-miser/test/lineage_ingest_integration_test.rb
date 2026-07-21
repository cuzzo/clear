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
  LINEAGE_BIN = File.expand_path("../../lineage/target/release/lineage", __dir__)
  INGEST_TOOL = File.expand_path("../../lineage/tools/ingest_mutation_corpus.rb", __dir__)

  def test_materialized_corpus_ingests_mutants_and_weak_tests
    skip "lineage binary missing; build gems/lineage first" unless File.executable?(LINEAGE_BIN)
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

      db = File.join(repo, "lineage.db")
      run!([LINEAGE_BIN, "init", "--db", db], repo)
      run!([LINEAGE_BIN, "build", "--db", db, "--repo", repo], repo)
      out = run!(["ruby", INGEST_TOOL, "--db=#{db}", "--repo=#{repo}",
                  "--materialized=#{materialized}", "--lineage-bin=#{LINEAGE_BIN}"], repo)

      assert_includes out, "exposure_events=3"
      assert_includes out, "ingested 1 mutant-facts file(s) at commit #{commit}"

      rows = SQLite3::Database.new(db).execute(
        "SELECT source, rule_id, path, run_format FROM sarif_findings"
      )
      assert_equal [["test-miser", "test-miser.zero-kill", "src/worker_test.rb", "test-miser.report.sarif.v1"]], rows

      exposure = SQLite3::Database.new(db).execute("SELECT COUNT(*) FROM test_exposure_events").first.first
      assert_equal 3, exposure
    end
  end

  private

  def run!(command, chdir)
    stdout, stderr, status = Open3.capture3(*command, chdir: chdir)
    assert status.success?, "#{command.join(" ")} failed: #{stderr}\n#{stdout}"
    stdout
  end
end
