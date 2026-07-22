# frozen_string_literal: true

require "json"
require "fileutils"
require "minitest/autorun"
require "tmpdir"
require "open3"
require "sqlite3"

class CrossGemContractIntegrationTest < Minitest::Test
  def setup
    @fact_mine_bin = File.expand_path("../../fact-mine/target/release/fact-mine-rust", __dir__)
    @espalier_bin = File.expand_path("../../espalier/exe/espalier", __dir__)
    @lineage_bin = File.expand_path("../../lineage/target/release/lineage", __dir__)
    @slopcop_bin = File.expand_path("../exe/slopcop", __dir__)

    # Ensure all binaries exist
    [@fact_mine_bin, @espalier_bin, @lineage_bin, @slopcop_bin].each do |bin|
      unless File.executable?(bin)
        flunk "Required integration test binary not found or not executable: #{bin}. Build the workspace before running integration tests."
      end
    end
  end

  def test_end_to_end_pipeline_cross_gem_contract
    Dir.mktmpdir do |repo_dir|
      # 1. Setup git repo and initial commit
      git_run(repo_dir, "init")
      git_run(repo_dir, "config user.name 'Test User'")
      git_run(repo_dir, "config user.email 'test@example.com'")
      
      initial_file = File.join(repo_dir, "README.md")
      File.write(initial_file, "# Dummy Repo\n")
      git_run(repo_dir, "add README.md")
      git_run(repo_dir, "commit -m 'Initial commit'")

      # 2. Add mixed-language files containing hazards
      src_dir = File.join(repo_dir, "src")
      FileUtils.mkdir_p(src_dir)

      ruby_file_path = File.join(src_dir, "app.rb")
      File.write(ruby_file_path, <<~RUBY)
        def handle_event(cb)
          cb.call
        end
      RUBY

      c_file_path = File.join(src_dir, "utils.c")
      File.write(c_file_path, <<~C)
        #include <stdlib.h>
        void* allocate(int size) {
            return malloc(size);
        }
      C

      git_run(repo_dir, "add src/")
      git_run(repo_dir, "commit -m 'Add app.rb and utils.c with hazards'")
      
      commit_sha = git_run(repo_dir, "rev-parse HEAD").strip
      refute_empty commit_sha

      # --- Test Contract Scenario 1: Running with Relative Paths in Repo Cwd ---
      Dir.chdir(repo_dir) do
        # Run Espalier to output architecture artifact
        arch_json_path = "architecture_rel.json"
        cmd = [@espalier_bin, "-f", "architecture", "-o", arch_json_path, "src/app.rb", "src/utils.c"]
        run_cmd!(cmd)
        assert File.file?(arch_json_path)

        arch_doc = JSON.parse(File.read(arch_json_path))
        
        # Verify corpus languages and correctness
        assert_equal ["ruby", "c"].sort, Array(arch_doc.dig("corpus", "languages")).sort
        
        # Verify both C and Ruby hazards were found
        hazards = arch_doc["hazards"]
        assert_equal 2, hazards.size
        ruby_hazard = hazards.find { |h| h["path"] == "src/app.rb" }
        c_hazard = hazards.find { |h| h["path"] == "src/utils.c" }
        refute_nil ruby_hazard
        refute_nil c_hazard
        assert_equal "ruby_callback_invocation", ruby_hazard["hazard_type"]
        assert_equal "c_lsan_lifetime", c_hazard["hazard_type"]

        # Run Lineage ingestion
        db_path = "lineage_rel.db"
        run_cmd!([@lineage_bin, "init", "--db", db_path])
        run_cmd!([@lineage_bin, "ingest-architecture", "--db", db_path, "--input", arch_json_path])

        # Verify ingested unit hazards in SQLite db
        db = SQLite3::Database.new(db_path)
        rows = db.execute("SELECT path, language, required_evidence, hazard_type FROM unit_hazards ORDER BY path")
        assert_equal 2, rows.size
        
        # Check path normalized relative to repo
        assert_equal ["src/app.rb", "ruby", "nil-kill", "ruby_callback_invocation"], rows[0]
        assert_equal ["src/utils.c", "c", "lsan", "c_lsan_lifetime"], rows[1]

        # Run SlopCop findings check
        sarif_out = "slopcop_rel.sarif"
        run_cmd!([@slopcop_bin, "constraints", "--repo=.", "--base=HEAD~1", "--head=HEAD", "--sarif=#{sarif_out}"])
        assert File.file?(sarif_out)

        sarif_doc = JSON.parse(File.read(sarif_out))
        results = sarif_doc.dig("runs", 0, "results")
        assert_equal 2, results.size

        # Ingest SARIF findings into Lineage
        run_cmd!([@lineage_bin, "ingest-sarif", "--db", db_path, "--repo=.", "--input", sarif_out, "--source", "slopcop", "--commit", commit_sha, "--replace"])

        # Verify ingested findings in Lineage SQLite db
        findings_rows = db.execute("SELECT path, rule_id, start_line FROM sarif_findings ORDER BY path")
        assert_equal 2, findings_rows.size
        assert_equal ["src/app.rb", "slopcop-ruby-metaprogramming-uncovered", 2], findings_rows[0]
        assert_equal ["src/utils.c", "slopcop-c-lsan-uncovered", 3], findings_rows[1]
      end

      # --- Test Contract Scenario 2: Running with Absolute Inputs and Different Working Directory ---
      Dir.mktmpdir do |external_dir|
        Dir.chdir(external_dir) do
          arch_json_path = File.join(external_dir, "architecture_abs.json")
          abs_ruby_file = File.join(repo_dir, "src/app.rb")
          abs_c_file = File.join(repo_dir, "src/utils.c")

          # Run Espalier using absolute paths
          cmd = [@espalier_bin, "-f", "architecture", "-o", arch_json_path, abs_ruby_file, abs_c_file]
          run_cmd!(cmd)
          assert File.file?(arch_json_path)

          arch_doc = JSON.parse(File.read(arch_json_path))
          assert_equal ["ruby", "c"].sort, Array(arch_doc.dig("corpus", "languages")).sort

          # Paths in the architecture artifact should be normalized repository-relative if repository is resolved,
          # or preserved relative to corpus root.
          # Verify both hazards are present
          hazards = arch_doc["hazards"]
          assert_equal 2, hazards.size

          # Run Lineage ingestion using absolute database path
          db_path = File.join(external_dir, "lineage_abs.db")
          run_cmd!([@lineage_bin, "init", "--db", db_path])
          
          # Run ingest architecture pointing lineage to the repo directory
          run_cmd!([@lineage_bin, "ingest-architecture", "--db", db_path, "--input", arch_json_path])

          db = SQLite3::Database.new(db_path)
          rows = db.execute("SELECT path, language, required_evidence, hazard_type FROM unit_hazards ORDER BY path")
          assert_equal 2, rows.size

          # Run SlopCop pointing to the repo using absolute --repo path
          sarif_out = File.join(external_dir, "slopcop_abs.sarif")
          run_cmd!([@slopcop_bin, "constraints", "--repo=#{repo_dir}", "--base=HEAD~1", "--head=HEAD", "--sarif=#{sarif_out}"])
          assert File.file?(sarif_out)

          # Ingest absolute-repo SARIF into Lineage
          run_cmd!([@lineage_bin, "ingest-sarif", "--db", db_path, "--repo=#{repo_dir}", "--input", sarif_out, "--source", "slopcop", "--commit", commit_sha, "--replace"])

          findings_rows = db.execute("SELECT path, rule_id, start_line FROM sarif_findings ORDER BY path")
          assert_equal 2, findings_rows.size
          assert_equal ["src/app.rb", "slopcop-ruby-metaprogramming-uncovered", 2], findings_rows[0]
          assert_equal ["src/utils.c", "slopcop-c-lsan-uncovered", 3], findings_rows[1]
        end
      end
    end
  end

  private

  def git_run(dir, command)
    stdout, stderr, status = Open3.capture3("git #{command}", chdir: dir)
    unless status.success?
      flunk "git command failed: git #{command}\nstderr: #{stderr}"
    end
    stdout
  end

  def run_cmd!(cmd)
    stdout, stderr, status = Open3.capture3(*cmd)
    unless status.success?
      flunk "command failed: #{cmd.join(' ')}\nstderr: #{stderr}\nstdout: #{stdout}"
    end
    stdout
  end
end
