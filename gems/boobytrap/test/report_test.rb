# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require "fileutils"
require_relative "../lib/boobytrap"

class ReportTest < Minitest::Test
  def git(dir, *args, date: nil)
    env = {}
    if date
      env["GIT_AUTHOR_DATE"] = date
      env["GIT_COMMITTER_DATE"] = date
    end
    system(env, "git", "-C", dir, *args,
           out: File::NULL, err: File::NULL) or raise "git #{args.inspect}"
  end

  def build_repo(dir)
    git(dir, "init", "-q")
    git(dir, "config", "user.email", "t@t")
    git(dir, "config", "user.name", "t")
    FileUtils.mkdir_p("#{dir}/src")
    File.write("#{dir}/src/hot.rb", "def a; end\n")
    File.write("#{dir}/src/calm.rb", "def b; end\n")
    git(dir, "add", "-A")
    git(dir, "commit", "-qm", "Add initial code", date: "2020-01-01T00:00:00")
    File.write("#{dir}/src/hot.rb", "def a; 1; end\n")
    git(dir, "add", "-A")
    git(dir, "commit", "-qm", "Fix alloc leak in hot path",
        date: "2024-01-01T00:00:00")
  end

  def resultset(dir)
    rs = { "RSpec" => { "coverage" => {
      "#{dir}/src/hot.rb" => { "branches" => {
        "[:if,0,1,0,1,9]" => { "[:then,1,1,0,1,4]" => 0,
                               "[:else,2,1,5,1,9]" => 0 }
      } }
    } } }
    path = "#{dir}/.resultset.json"
    File.write(path, JSON.dump(rs))
    path
  end

  def test_end_to_end_report_ranks_the_fixed_uncovered_file
    Dir.mktmpdir do |dir|
      build_repo(dir)
      rs = resultset(dir)
      md = Boobytrap::Report.new(repo: dir, resultset: rs).to_markdown

      assert_includes md, "# Boobytrap Report"
      assert_includes md, "never a verdict"
      assert_includes md, "## Hotspots (1)"
      # hot.rb: only fix touches it (fix_norm 1.0), both arms uncovered
      # (gap 1.0) => hotspot 1.0; calm.rb never fixed => not ranked.
      assert_includes md, "`src/hot.rb`"
      refute_includes md, "`src/calm.rb`"
      assert_match(/\| 1 \| `src\/hot\.rb` \| 1\.0 /, md)
    end
  end

  def test_missing_resultset_degrades_to_fix_only
    Dir.mktmpdir do |dir|
      build_repo(dir)
      md = Boobytrap::Report.new(repo: dir, resultset: "#{dir}/nope.json").to_markdown
      assert_includes md, "ABSENT (fix-churn only)"
      # hot.rb has fixes but no coverage => fixed-but-unmeasured
      assert_includes md, "## Fixed But Unmeasured (1)"
      assert_includes md, "`src/hot.rb`"
    end
  end

  def test_only_filters_ranking_to_the_scoped_path
    Dir.mktmpdir do |dir|
      git(dir, "init", "-q")
      git(dir, "config", "user.email", "t@t")
      git(dir, "config", "user.name", "t")
      FileUtils.mkdir_p("#{dir}/src")
      FileUtils.mkdir_p("#{dir}/lib")
      File.write("#{dir}/src/in.rb", "1\n")
      File.write("#{dir}/lib/out.rb", "1\n")
      git(dir, "add", "-A")
      git(dir, "commit", "-qm", "Fix both in and out", date: "2024-01-01T00:00:00")
      rs = { "RSpec" => { "coverage" => {
        "#{dir}/src/in.rb" => { "branches" => {
          "[:if,0,1,0,1,9]" => { "[:then,1,1,0,1,4]" => 0 } } },
        "#{dir}/lib/out.rb" => { "branches" => {
          "[:if,0,1,0,1,9]" => { "[:then,1,1,0,1,4]" => 0 } } }
      } } }
      path = "#{dir}/.resultset.json"
      File.write(path, JSON.dump(rs))

      full = Boobytrap::Report.new(repo: dir, resultset: path).to_markdown
      assert_includes full, "`src/in.rb`"
      assert_includes full, "`lib/out.rb`"

      scoped = Boobytrap::Report.new(repo: dir, resultset: path,
                                    only: ["src/"]).to_markdown
      assert_includes scoped, "`src/in.rb`"
      refute_includes scoped, "`lib/out.rb`"
      assert_includes scoped, "Scope: `src/`"
    end
  end

  def test_deleted_files_are_not_reported_as_unmeasured
    Dir.mktmpdir do |dir|
      git(dir, "init", "-q")
      git(dir, "config", "user.email", "t@t")
      git(dir, "config", "user.name", "t")
      FileUtils.mkdir_p("#{dir}/src")
      File.write("#{dir}/src/deleted.rb", "def gone; end\n")
      git(dir, "add", "-A")
      git(dir, "commit", "-qm", "Add deleted file", date: "2020-01-01T00:00:00")
      File.write("#{dir}/src/deleted.rb", "def gone; 1; end\n")
      git(dir, "add", "-A")
      git(dir, "commit", "-qm", "Fix deleted file", date: "2024-01-01T00:00:00")
      FileUtils.rm("#{dir}/src/deleted.rb")
      git(dir, "add", "-A")
      git(dir, "commit", "-qm", "Remove deleted file", date: "2024-02-01T00:00:00")

      md = Boobytrap::Report.new(repo: dir, resultset: "#{dir}/none.json").to_markdown
      assert_includes md, "## Fixed But Unmeasured (0)"
      refute_includes md, "`src/deleted.rb`"
    end
  end

  def test_no_fix_commits_yields_no_hotspots
    Dir.mktmpdir do |dir|
      git(dir, "init", "-q")
      git(dir, "config", "user.email", "t@t")
      git(dir, "config", "user.name", "t")
      File.write("#{dir}/x.rb", "1\n")
      git(dir, "add", "-A")
      git(dir, "commit", "-qm", "Add x only")
      md = Boobytrap::Report.new(repo: dir, resultset: "#{dir}/none.json").to_markdown
      assert_includes md, "## Hotspots (0)"
      assert_includes md, "No hotspots"
    end
  end

  def test_report_flags_state_based_branch_hotspots_and_fix_blast_radius
    Dir.mktmpdir do |dir|
      git(dir, "init", "-q")
      git(dir, "config", "user.email", "t@t")
      git(dir, "config", "user.name", "t")
      FileUtils.mkdir_p("#{dir}/src")
      File.write("#{dir}/src/hot.rb", <<~RUBY)
        class Checkout
          def stateful(order)
            if @enabled
              charge(order.total)
            end
            if order.paid?
              ship
            end
            done
          end
        end
      RUBY
      File.write("#{dir}/src/peer.rb", "def peer; 1; end\n")
      git(dir, "add", "-A")
      git(dir, "commit", "-qm", "Add checkout", date: "2020-01-01T00:00:00")
      File.write("#{dir}/src/hot.rb", File.read("#{dir}/src/hot.rb") + "\n# fix\n")
      File.write("#{dir}/src/peer.rb", "def peer; 2; end\n")
      git(dir, "add", "-A")
      git(dir, "commit", "-qm", "Fix checkout state bug", date: "2024-01-01T00:00:00")

      lines = Array.new(12)
      [1, 2, 3, 5, 6, 8, 9].each { |i| lines[i - 1] = 1 }
      [4, 7].each { |i| lines[i - 1] = 0 }
      rs = {
        "RSpec" => { "coverage" => {
          "#{dir}/src/hot.rb" => {
            "lines" => lines,
            "branches" => {
              "[:if,0,3,0,5,7]" => {
                "[:then,1,4,2,4,21]" => 0,
                "[:else,2,3,0,5,7]" => 1
              },
              "[:if,3,6,0,8,7]" => {
                "[:then,4,7,2,7,10]" => 0,
                "[:else,5,6,0,8,7]" => 1
              }
            }
          },
          "#{dir}/src/peer.rb" => {
            "lines" => [1],
            "branches" => {}
          }
        } }
      }
      path = "#{dir}/.resultset.json"
      File.write(path, JSON.dump(rs))

      md = Boobytrap::Report.new(repo: dir, resultset: path).to_markdown

      assert_includes md, "## State-Based Branch Hotspots"
      assert_includes md, "`src/hot.rb:stateful`"
      assert_includes md, "@enabled"
      assert_includes md, "order.paid?"
      assert_includes md, "## Multi-File Fix Blast Radius"
      assert_includes md, "`src/hot.rb`"
      assert_includes md, "src/peer.rb"
      assert_includes md, "Highest state-based branch hotspot"
      assert_includes md, "Highest multi-file fix blast radius"
    end
  end

  def test_report_includes_lineage_overlay_when_supplied
    Dir.mktmpdir do |dir|
      build_repo(dir)
      rs = resultset(dir)
      lineage = "#{dir}/lineage.sqlite"
      File.write(lineage, "placeholder")
      cmd = "#{dir}/lineage-json"
      File.write(cmd, <<~RUBY)
        #!/usr/bin/env ruby
        require "json"
        puts JSON.dump([
          {
            "id" => "u1",
            "name" => "a",
            "kind" => "function",
            "original_path" => "src/hot.rb",
            "total_events" => 3,
            "changes" => 1,
            "moves" => 1,
            "fixes" => 1,
            "risk_score" => 4.0
          }
        ])
      RUBY
      File.chmod(0o755, cmd)

      md = Boobytrap::Report.new(
        repo: dir,
        resultset: rs,
        lineage: lineage,
        lineage_command: cmd
      ).to_markdown

      assert_includes md, "## Lineage Unit Risk (1)"
      assert_includes md, "`src/hot.rb` `a`"
      assert_includes md, "Highest lineage unit risk"
      assert_includes md, "Lineage DB: lineage.sqlite"
    end
  end

  def test_report_includes_named_test_exposure_when_supplied
    Dir.mktmpdir do |dir|
      git(dir, "init", "-q")
      git(dir, "config", "user.email", "t@t")
      git(dir, "config", "user.name", "t")
      FileUtils.mkdir_p("#{dir}/src")
      file = "#{dir}/src/hot.rb"
      File.write(file, <<~RUBY)
        class Hot
          def risky(x)
            total = x.to_i
            if x
              total += 1
            else
              total -= 1
            end
            total *= 2
            total + 3
          end
        end
      RUBY
      git(dir, "add", "-A")
      git(dir, "commit", "-qm", "Add hot", date: "2020-01-01T00:00:00")
      File.write(file, File.read(file) + "\n# fix\n")
      git(dir, "add", "-A")
      git(dir, "commit", "-qm", "Fix hot regression", date: "2024-01-01T00:00:00")

      lines = Array.new(12)
      [2].each { |i| lines[i - 1] = 1 }
      [3, 4, 5, 6, 7, 8, 9, 10].each { |i| lines[i - 1] = 0 }
      rs = {
        "RSpec" => { "coverage" => {
          file => {
            "lines" => lines,
            "branches" => {
              "[:if,0,3,0,7,3]" => {
                "[:then,1,4,0,5,10]" => 0,
                "[:else,2,6,0,7,10]" => 0
              }
            }
          }
        } }
      }
      coverage = "#{dir}/.resultset.json"
      File.write(coverage, JSON.dump(rs))
      exposure = "#{dir}/test-exposure.json"
      File.write(exposure, JSON.dump(
        "schema" => "test-exposure/v1",
        "hits" => [
          {
            "file" => "src/hot.rb",
            "function" => "risky",
            "line" => 4,
            "branch_id" => "b1",
            "test_id" => "spec/hot_spec.rb:1",
            "test_type" => "unit",
            "mutation_status" => "killed"
          },
          {
            "file" => "src/hot.rb",
            "function" => "risky",
            "line" => 6,
            "branch_id" => "b2",
            "test_id" => "spec/hot_spec.rb:2",
            "test_type" => "integration",
            "mutation_status" => "killed"
          }
        ]
      ))

      md = Boobytrap::Report.new(
        repo: dir,
        resultset: coverage,
        test_exposure: exposure
      ).to_markdown

      assert_includes md, "tests"
      assert_includes md, "2 tests; integration=1/unit=1; mutant killed 2/2"
      assert_includes md, "mutation-killed exposure"
      assert_includes md, "Test exposure facts: test-exposure.json"
      assert_includes md, "tests=2 tests"
    end
  end
end
