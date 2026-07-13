# frozen_string_literal: true
# typed: false

require "json"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

RSpec.describe "SQL-COV SARIF generation" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:generator) { File.join(root, "tools/generate_sql_cov_sarif.rb") }

  it "uploads only native advisory hazards and reports unresolved facts" do
    Dir.mktmpdir("sql-cov-sarif-spec") do |dir|
      repo = File.join(dir, "repo")
      sql_dir = File.join(repo, "gems/lineage/sql/storage")
      out_dir = File.join(dir, "out")
      fake_bin = File.join(dir, "fake-sql-cov")
      argv_log = File.join(dir, "argv.json")
      FileUtils.mkdir_p(sql_dir)
      File.write(File.join(sql_dir, "init_schema.sql"), "CREATE TABLE users(id INTEGER);\n")
      File.write(File.join(sql_dir, "query.sql"), "SELECT id FROM users;\n")
      File.write(fake_bin, <<~RUBY)
        #!/usr/bin/env ruby
        require "json"
        File.write(ENV.fetch("SQL_COV_ARGV_LOG"), JSON.generate(ARGV))
        puts JSON.generate({
          "runs" => [{
            "tool" => { "driver" => { "rules" => [{
              "id" => "SQL001",
              "defaultConfiguration" => { "level" => "error" }
            }] } },
            "results" => [{
              "ruleId" => "SQL001",
              "level" => "error",
              "message" => { "text" => "nullable comparison" },
              "locations" => [{ "physicalLocation" => {
                "artifactLocation" => { "uri" => "temporary.sql" },
                "region" => { "startLine" => 1 }
              } }],
              "properties" => { "schemaValidated" => true, "tier" => "T1" }
            }],
            "properties" => {
              "unresolvedSchemaFacts" => ["a derived column is unresolved"]
            }
          }]
        })
      RUBY
      FileUtils.chmod("u+x", fake_bin)

      _stdout, stderr, status = Open3.capture3(
        { "SQL_COV_ARGV_LOG" => argv_log },
        RbConfig.ruby,
        generator,
        "--repo=#{repo}",
        "--out-dir=#{out_dir}",
        "--setup=gems/lineage/sql/storage/init_schema.sql",
        "--sql-cov-bin=#{fake_bin}"
      )
      expect(status).to be_success, stderr

      expect(JSON.parse(File.read(argv_log))).not_to include("--sqlfluff")
      sarif = JSON.parse(File.read(File.join(out_dir, "sql-cov.sarif")))
      run = sarif.fetch("runs").first
      expect(run.fetch("results").map { |result| result.fetch("level") }).to eq(["warning"])
      expect(run.dig("tool", "driver", "rules", 0, "defaultConfiguration", "level")).to eq("warning")
      expect(run.dig("properties", "scannedFiles")).to eq(1)
      expect(run.dig("properties", "skippedNonQueryFiles")).to be_empty
      expect(run.dig("results", 0, "locations", 0, "physicalLocation", "artifactLocation", "uri"))
        .to eq("gems/lineage/sql/storage/query.sql")

      markdown = File.read(File.join(out_dir, "sql-cov.md"))
      expect(markdown).to include("1 unresolved schema facts")
      expect(markdown).to include("analyzer-completeness gaps, not SQL findings")
      expect(markdown).to include("a derived column is unresolved")
    end
  end

  it "normalizes generated identifiers, skips non-query SQL, and fails on scan errors" do
    Dir.mktmpdir("sql-cov-sarif-spec") do |dir|
      repo = File.join(dir, "repo")
      sql_dir = File.join(repo, "gems/lineage/sql/storage")
      out_dir = File.join(dir, "out")
      fake_bin = File.join(dir, "fake-sql-cov")
      input_log = File.join(dir, "input.sql")
      FileUtils.mkdir_p(sql_dir)
      File.write(File.join(sql_dir, "init_schema.sql"), "CREATE TABLE users(id INTEGER);\n")
      File.write(File.join(sql_dir, "configure.sql"), "-- setup\nPRAGMA foreign_keys = ON;\n")
      File.write(File.join(sql_dir, "generated.sql"), "UPDATE users SET {column} = 1;\n")
      File.write(fake_bin, <<~RUBY)
        #!/usr/bin/env ruby
        require "json"
        input = ARGV.fetch(ARGV.index("--input") + 1)
        File.write(ENV.fetch("SQL_COV_INPUT_LOG"), File.read(input))
        puts JSON.generate({ "runs" => [{
          "tool" => { "driver" => { "rules" => [] } },
          "results" => [],
          "properties" => { "unresolvedSchemaFacts" => [] }
        }] })
      RUBY
      FileUtils.chmod("u+x", fake_bin)

      _stdout, stderr, status = Open3.capture3(
        { "SQL_COV_INPUT_LOG" => input_log },
        RbConfig.ruby,
        generator,
        "--repo=#{repo}",
        "--out-dir=#{out_dir}",
        "--setup=gems/lineage/sql/storage/init_schema.sql",
        "--sql-cov-bin=#{fake_bin}"
      )
      expect(status).to be_success, stderr
      expect(File.read(input_log)).to include("SET current_line_cov = 1")

      run = JSON.parse(File.read(File.join(out_dir, "sql-cov.sarif"))).fetch("runs").first
      expect(run.dig("properties", "scannedFiles")).to eq(1)
      expect(run.dig("properties", "skippedNonQueryFiles"))
        .to eq(["gems/lineage/sql/storage/configure.sql"])

      File.write(fake_bin, "#!/usr/bin/env ruby\nwarn 'cannot scan'\nexit 2\n")
      _stdout, stderr, status = Open3.capture3(
        RbConfig.ruby,
        generator,
        "--repo=#{repo}",
        "--out-dir=#{out_dir}",
        "--setup=gems/lineage/sql/storage/init_schema.sql",
        "--sql-cov-bin=#{fake_bin}"
      )
      expect(status).not_to be_success
      expect(stderr).to include("SQL-COV failed to scan 1 files", "cannot scan")
    end
  end
end
