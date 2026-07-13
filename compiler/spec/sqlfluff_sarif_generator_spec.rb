# frozen_string_literal: true
# typed: false

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

RSpec.describe "SQLFluff SARIF generation" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:generator) { File.join(root, "tools/generate_sqlfluff_sarif.rb") }

  it "keeps parser failures blocking and reports configured lint rules as warnings" do
    Dir.mktmpdir("sqlfluff-sarif-spec") do |dir|
      repo = File.join(dir, "repo")
      out_dir = File.join(dir, "out")
      fake_bin = File.join(dir, "fake-sqlfluff")
      argv_log = File.join(dir, "argv.json")
      FileUtils.mkdir_p(File.join(repo, "sql"))
      File.write(File.join(repo, ".sqlfluff"), "[sqlfluff]\ndialect = sqlite\n")
      File.write(fake_bin, <<~RUBY)
        #!/usr/bin/env ruby
        require "json"
        File.write(ENV.fetch("SQLFLUFF_ARGV_LOG"), JSON.generate(ARGV))
        puts JSON.generate({
          "version" => "2.1.0",
          "runs" => [{
            "tool" => { "driver" => { "name" => "SQLFluff", "rules" => [
              { "id" => "PRS", "defaultConfiguration" => { "level" => "error" } },
              { "id" => "AM09", "defaultConfiguration" => { "level" => "error" } }
            ] } },
            "results" => [
              { "ruleId" => "PRS", "level" => "error", "message" => { "text" => "cannot parse" } },
              {
                "ruleId" => "AM09",
                "level" => "error",
                "message" => { "text" => "unordered limit" },
                "locations" => [{ "physicalLocation" => {
                  "artifactLocation" => { "uri" => File.join(Dir.pwd, "sql", "query.sql") }
                } }]
              }
            ]
          }]
        })
        exit 1
      RUBY
      FileUtils.chmod("u+x", fake_bin)

      _stdout, stderr, status = Open3.capture3(
        { "SQLFLUFF_ARGV_LOG" => argv_log },
        RbConfig.ruby,
        generator,
        "--repo=#{repo}",
        "--out-dir=#{out_dir}",
        "--config=.sqlfluff",
        "--sql-path=sql",
        "--sqlfluff-bin=#{fake_bin}"
      )
      expect(status).to be_success, stderr
      expect(JSON.parse(File.read(argv_log))).to include("--config", "--format", "sarif")

      run = JSON.parse(File.read(File.join(out_dir, "sqlfluff.sarif"))).fetch("runs").first
      expect(run.fetch("results").map { |result| [result.fetch("ruleId"), result.fetch("level")] })
        .to eq([["PRS", "error"], ["AM09", "warning"]])
      expect(run.dig("tool", "driver", "rules").to_h { |rule| [rule.fetch("id"), rule.dig("defaultConfiguration", "level")] })
        .to eq("PRS" => "error", "AM09" => "warning")
      expect(run.dig("properties", "blockingRules")).to include("LXR", "PRS", "TMP")
      expect(run.dig("results", 1, "locations", 0, "physicalLocation", "artifactLocation", "uri"))
        .to eq("sql/query.sql")
    end
  end

  it "fails rather than treating a SQLFluff invocation error as a clean scan" do
    Dir.mktmpdir("sqlfluff-sarif-spec") do |dir|
      repo = File.join(dir, "repo")
      fake_bin = File.join(dir, "broken-sqlfluff")
      FileUtils.mkdir_p(File.join(repo, "sql"))
      File.write(File.join(repo, ".sqlfluff"), "[sqlfluff]\ndialect = sqlite\n")
      File.write(fake_bin, "#!/usr/bin/env ruby\nwarn 'bad config'\nexit 2\n")
      FileUtils.chmod("u+x", fake_bin)

      _stdout, stderr, status = Open3.capture3(
        RbConfig.ruby,
        generator,
        "--repo=#{repo}",
        "--out-dir=#{File.join(dir, 'out')}",
        "--config=.sqlfluff",
        "--sql-path=sql",
        "--sqlfluff-bin=#{fake_bin}"
      )
      expect(status).not_to be_success
      expect(stderr).to include("SQLFluff failed (exit 2)", "bad config")
    end
  end
end
