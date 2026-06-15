# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require "coverage"
require "fileutils"
require_relative "../lib/slopcop"

class RollupTest < Minitest::Test
  def test_rollup_categorizes_and_surfaces_genuine_with_churn_overlay
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/src")
      src = <<~RB
        def shape(x, n)
          return 0 if x.is_a?(String)
          case n
          when 1 then 10
          when 2 then 20
          else 30
          end
        end
        shape(7, 1)
      RB
      path = "#{dir}/src/m.rb"
      File.write(path, src)
      # real git repo so boobytrap churn is computable (no fix commit ->
      # churn 0, score 0, but the genuine bucket still lists).
      system("git", "-C", dir, "init", "-q", out: File::NULL, err: File::NULL)
      system("git", "-C", dir, "config", "user.email", "t@t")
      system("git", "-C", dir, "config", "user.name", "t")
      system("git", "-C", dir, "add", "-A", out: File::NULL, err: File::NULL)
      system("git", "-C", dir, "commit", "-qm", "add", out: File::NULL, err: File::NULL)

      Coverage.start(branches: true)
      load path
      res = Coverage.result
      rs = { "T" => { "coverage" => { path => { "branches" => res.dig(path, :branches) } } } }
      rsf = "#{dir}/.resultset.json"
      File.write(rsf, JSON.dump(rs))

      out = SlopCop::Rollup.run(files: ["src/m.rb"], repo: dir, resultset: rsf)
      assert out[:per_file].key?("src/m.rb")
      fh = out[:per_file]["src/m.rb"]
      assert fh[:total].positive?, "should find dark arms"
      assert(fh[:counts][:type_norm].positive?, "the never-String is_a? guard")
      assert_equal fh[:total], fh[:counts].values.sum, "every arm categorized"
      assert_equal out[:grand], out[:totals].values.sum
      dark_arms = out[:dark_arms].select { |arm| arm[:file] == "src/m.rb" }
      assert_equal fh[:total], dark_arms.size
      assert dark_arms.all? { |arm| arm[:message].start_with?("dark arm: ") }
      json = JSON.parse(SlopCop::Report.new(files: ["src/m.rb"], repo: dir, resultset: rsf).to_json)
      assert_equal "slopcop.report.v1", json.fetch("format")
      refute_empty json.fetch("dark_arms")
      assert json.fetch("dark_arms").all? { |arm| arm.fetch("message").start_with?("dark arm: ") }

      report = SlopCop::Report.new(files: ["src/m.rb"], repo: dir, resultset: rsf)
      sarif = JSON.parse(report.to_sarif)
      run = sarif.fetch("runs").first
      assert_equal "2.1.0", sarif.fetch("version")
      assert_equal "SlopCop", run.dig("tool", "driver", "name")
      assert_equal "slopcop.report.sarif.v1", run.dig("properties", "format")
      assert run.dig("tool", "driver", "rules").any? { |rule| rule.fetch("id") == "slopcop.genuine-gap" }
      result = run.fetch("results").first
      refute_nil result
      assert_equal "slopcop.genuine-gap", result.fetch("ruleId")
      assert_equal "src/m.rb", result.dig("locations", 0, "physicalLocation", "artifactLocation", "uri")
      assert_operator result.dig("locations", 0, "physicalLocation", "region", "startLine"), :>=, 1
      assert result.fetch("partialFingerprints").fetch("slopcopGenuineGap")

      overlay = SlopCop::DarkArmOverlay.build(files: ["src/m.rb"], repo: dir, resultset: rsf)
      assert_equal "slopcop.dark-arms.v1", overlay.fetch("format")
      refute_empty overlay.fetch("dark_arms")
      assert overlay.fetch("dark_arms").all? { |arm| arm.fetch("category").start_with?("dark arm: ") }
    end
  end

  def test_missing_file_is_skipped_not_crashed
    Dir.mktmpdir do |dir|
      system("git", "-C", dir, "init", "-q", out: File::NULL, err: File::NULL)
      File.write("#{dir}/rs.json", JSON.dump({ "T" => { "coverage" => {} } }))
      out = SlopCop::Rollup.run(files: ["nope.rb"], repo: dir,
                                  resultset: "#{dir}/rs.json")
      assert_empty out[:per_file]
      assert_empty out[:top_gaps]
    end
  end
end
