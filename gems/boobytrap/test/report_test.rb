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
end
