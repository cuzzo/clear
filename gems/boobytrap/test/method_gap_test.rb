# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/boobytrap"

class MethodGapTest < Minitest::Test
  def with_env(key, value)
    old = ENV[key]
    value.nil? ? ENV.delete(key) : ENV[key] = value
    yield
  ensure
    old.nil? ? ENV.delete(key) : ENV[key] = old
  end

  def test_ranks_mostly_dark_stateful_methods
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/src")
      file = "#{dir}/src/compiler.rb"
      File.write(file, <<~RUBY)
        class Compiler
          def dark_stateful(x)
            @state = x
            if x
              @count += 1
            else
              @items << x
            end
            @state
          end

          def covered
            1
            2
            3
            4
            5
          end
        end
      RUBY
      lines = Array.new(18)
      [2, 3, 11, 12, 13, 14, 15, 16, 17].each { |i| lines[i - 1] = 1 }
      [4, 5, 6, 7, 8, 9].each { |i| lines[i - 1] = 0 }
      rs = {
        "RSpec" => { "coverage" => {
          file => {
            "lines" => lines,
            "branches" => {
              "[:if,0,4,0,8,3]" => {
                "[:then,1,5,0,6,10]" => 0,
                "[:else,2,7,0,8,10]" => 0
              }
            }
          }
        } }
      }
      path = "#{dir}/.resultset.json"
      File.write(path, JSON.dump(rs))

      score = Boobytrap::DecomplexRisk::Score.new(
        score: 7,
        findings: 3,
        detectors: ["False Simplicity", "Neglected Updates"]
      )
      rows = Boobytrap::MethodGap.from_resultset(
        path,
        root: dir,
        decomplex_scores: { ["src/compiler.rb", "dark_stateful"] => score }
      )
      dark = rows.find { |r| r.name == "dark_stateful" }

      assert_equal "src/compiler.rb", dark.file
      assert_equal 7, dark.executable_lines
      assert_equal 2, dark.covered_lines
      assert_equal 5, dark.missed_lines
      assert_equal 3, dark.state_writes
      assert_equal 2, dark.uncovered_branches
      assert_equal 7, dark.decomplex_score
      assert_equal 3, dark.decomplex_findings
      assert_equal ["False Simplicity", "Neglected Updates"], dark.decomplex_detectors
      assert_operator dark.risk, :>, 0
      refute_includes dark.members, :complexity
      refute rows.any? { |r| r.name == "covered" }
    end
  end

  def test_tree_sitter_static_zig_method_gaps_when_coverage_is_absent
    grammar = ENV["DECOMPLEX_TS_ZIG_PATH"]
    skip "set DECOMPLEX_TS_ZIG_PATH to run Zig Tree-sitter static test" unless grammar && File.file?(grammar)

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/src")
      file = "#{dir}/src/worker.zig"
      File.write(file, <<~ZIG)
        const Worker = struct {
            count: i32 = 0,

            fn run(self: *Worker, x: i32) bool {
                if (x > 0) {
                    self.count += 1;
                    return true;
                } else {
                    return false;
                }
                switch (x) {
                    1 => return true,
                    2 => return false,
                    else => return false,
                }
            }
        };
      ZIG

      score = Boobytrap::DecomplexRisk::Score.new(
        score: 5,
        findings: 2,
        detectors: ["State-Based Branch Density"]
      )

      with_env("DECOMPLEX_PARSER", "tree_sitter") do
        rows = Boobytrap::MethodGap.from_static(
          ["src/worker.zig"],
          root: dir,
          decomplex_scores: { ["src/worker.zig", "run"] => score }
        )
        run = rows.find { |row| row.name == "run" }

        refute_nil run
        assert_equal "src/worker.zig", run.file
        assert_equal 1.0, run.line_gap
        assert_operator run.executable_lines, :>=, 5
        assert_operator run.uncovered_branches, :>=, 2
        assert_operator run.state_writes, :>=, 1
        assert_equal 5, run.decomplex_score
      end
    end
  end

  def test_kcov_cobertura_zig_method_gaps
    grammar = ENV["DECOMPLEX_TS_ZIG_PATH"]
    skip "set DECOMPLEX_TS_ZIG_PATH to run Zig Tree-sitter kcov test" unless grammar && File.file?(grammar)

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/src")
      file = "#{dir}/src/worker.zig"
      File.write(file, <<~ZIG)
        const Worker = struct {
            count: i32 = 0,

            fn run(self: *Worker, x: i32) bool {
                if (x > 0) {
                    return true;
                } else {
                    self.count += 1;
                    return false;
                }
            }
        };
      ZIG
      coverage = "#{dir}/cobertura.xml"
      File.write(coverage, <<~XML)
        <?xml version="1.0" ?>
        <coverage>
          <sources><source>#{dir}</source></sources>
          <packages><package name=""><classes>
            <class name="worker" filename="src/worker.zig">
              <lines>
                <line number="4" hits="1"/>
                <line number="5" hits="1"/>
                <line number="6" hits="1"/>
                <line number="8" hits="0"/>
                <line number="9" hits="0"/>
              </lines>
            </class>
          </classes></package></packages>
        </coverage>
      XML

      with_env("DECOMPLEX_PARSER", "tree_sitter") do
        rows = Boobytrap::MethodGap.from_resultset(coverage, root: dir, min_lines: 1)
        run = rows.find { |row| row.name == "run" }

        refute_nil run
        assert_equal "src/worker.zig", run.file
        assert_operator run.covered_lines, :>, 0
        assert_operator run.missed_lines, :>, 0
        assert_operator run.uncovered_branches, :>=, 1
        assert_operator run.line_gap, :>, 0.0
      end
    end
  end

  def test_nil_kill_branch_coverage_zig_method_dark_branches
    grammar = ENV["DECOMPLEX_TS_ZIG_PATH"]
    skip "set DECOMPLEX_TS_ZIG_PATH to run Zig native branch coverage test" unless grammar && File.file?(grammar)

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/src")
      File.write("#{dir}/src/worker.zig", <<~ZIG)
        const Worker = struct {
            count: i32 = 0,

            fn run(self: *Worker, x: i32) bool {
                if (x > 0) {
                    return true;
                } else {
                    self.count += 1;
                    return false;
                }
            }
        };
      ZIG
      catalog = Boobytrap::CoverageData.branch_catalog(["src/worker.zig"], root: dir)
      file = catalog.fetch("files").first
      file["lines"] = { "4" => 1, "5" => 1, "6" => 1, "8" => 0, "9" => 0 }
      file["arms"] = file.fetch("arms").map do |arm|
        arm.merge("hits" => (arm["label"] == "then" ? 1 : 0))
      end
      coverage = "#{dir}/branch-coverage.json"
      File.write(coverage, JSON.dump(catalog.merge("format" => "nil-kill.branch-coverage")))

      with_env("DECOMPLEX_PARSER", nil) do
        rows = Boobytrap::MethodGap.from_resultset(coverage, root: dir, min_lines: 1)
        run = rows.find { |row| row.name == "run" }

        refute_nil run
        assert_equal "src/worker.zig", run.file
        assert_operator run.covered_lines, :>, 0
        assert_operator run.missed_lines, :>, 0
        assert_equal 1, run.uncovered_branches
      end
    end
  end

  def test_coverage_py_json_python_method_dark_branches
    grammar = ENV["DECOMPLEX_TS_PYTHON_PATH"]
    skip "set DECOMPLEX_TS_PYTHON_PATH to run Python branch coverage test" unless grammar && File.file?(grammar)

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/src")
      File.write("#{dir}/src/worker.py", <<~PY)
        def choose(x):
            value = 0
            if x:
                value = 1
            else:
                value = 2
            return value
      PY
      coverage = "#{dir}/coverage.json"
      File.write(coverage, JSON.dump(
        "meta" => { "format" => 2, "branch_coverage" => true },
        "files" => {
          "src/worker.py" => {
            "executed_lines" => [1, 2, 3, 4, 7],
            "missing_lines" => [6],
            "executed_branches" => [[3, 4]],
            "missing_branches" => [[3, 6]]
          }
        }
      ))

      with_env("DECOMPLEX_PARSER", nil) do
        rows = Boobytrap::MethodGap.from_resultset(coverage, root: dir, min_lines: 1)
        choose = rows.find { |row| row.name == "choose" }

        refute_nil choose
        assert_equal "src/worker.py", choose.file
        assert_operator choose.covered_lines, :>, 0
        assert_operator choose.missed_lines, :>, 0
        assert_equal 1, choose.uncovered_branches
      end
    end
  end
end
