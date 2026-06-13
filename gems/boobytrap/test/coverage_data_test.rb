# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/boobytrap"

class CoverageDataTest < Minitest::Test
  def with_env(key, value)
    old = ENV[key]
    value.nil? ? ENV.delete(key) : ENV[key] = value
    yield
  ensure
    old.nil? ? ENV.delete(key) : ENV[key] = old
  end

  def test_loads_simplecov_resultset_and_merges_entries
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/src")
      file = "#{dir}/src/a.rb"
      File.write(file, "def a\n  1\nend\n")
      resultset = {
        "one" => { "coverage" => {
          file => {
            "lines" => [1, 0, nil],
            "branches" => {
              "[:if,0,1,0,1,9]" => { "[:then,1,1,0,1,4]" => 0 }
            }
          }
        } },
        "two" => { "coverage" => {
          file => {
            "lines" => [2, nil, nil],
            "branches" => {
              "[:if,0,1,0,1,9]" => { "[:then,1,1,0,1,4]" => 5 }
            }
          }
        } }
      }
      path = "#{dir}/.resultset.json"
      File.write(path, JSON.dump(resultset))

      dataset = Boobytrap::CoverageData.load(path, root: dir)
      coverage = dataset[file]

      assert_equal "SimpleCov", dataset.label
      assert_equal ["src/a.rb"], dataset.covered_files(root: dir)
      assert_equal 3, coverage.line_hits(1)
      assert_equal 0, coverage.line_hits(2)
      assert_equal 5, coverage.branches["[:if,0,1,0,1,9]"]["[:then,1,1,0,1,4]"]
    end
  end

  def test_loads_kcov_cobertura_from_directory
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/src")
      FileUtils.mkdir_p("#{dir}/coverage/kcov-merged")
      file = "#{dir}/src/a.zig"
      File.write(file, "fn a() void {\n    return;\n}\n")
      File.write("#{dir}/coverage/kcov-merged/cobertura.xml", <<~XML)
        <?xml version="1.0" ?>
        <coverage>
          <sources>
            <source>#{dir}</source>
          </sources>
          <packages>
            <package name="">
              <classes>
                <class name="a" filename="src/a.zig">
                  <lines>
                    <line number="1" hits="1"/>
                    <line number="2" hits="0"/>
                  </lines>
                </class>
              </classes>
            </package>
          </packages>
        </coverage>
      XML

      dataset = Boobytrap::CoverageData.load("#{dir}/coverage", root: dir)
      coverage = dataset[file]

      assert_equal "kcov Cobertura", dataset.label
      assert_equal ["src/a.zig"], dataset.covered_files(root: dir)
      assert_equal 1, coverage.line_hits(1)
      assert_equal 0, coverage.line_hits(2)
    end
  end

  def test_loads_nil_kill_branch_coverage_json
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/src")
      file = "#{dir}/src/a.zig"
      File.write(file, "fn a(x: bool) bool { return x; }\n")
      path = "#{dir}/branch-coverage.json"
      File.write(path, JSON.dump(
        "schema_version" => 1,
        "format" => "nil-kill.branch-coverage",
        "root" => dir,
        "files" => [
          {
            "path" => "src/a.zig",
            "language" => "zig",
            "lines" => { "1" => 1 },
            "arms" => [
              {
                "branch_id" => "b1",
                "arm_id" => "a1",
                "kind" => "if",
                "label" => "then",
                "decision_span" => [1, 0, 1, 20],
                "arm_span" => [1, 12, 1, 18],
                "hits" => 0
              }
            ]
          }
        ]
      ))

      dataset = Boobytrap::CoverageData.load(path, root: dir)
      coverage = dataset[file]

      assert_equal "Nil-Kill branch coverage", dataset.label
      assert_equal ["src/a.zig"], dataset.covered_files(root: dir)
      assert coverage.branch_arm_coverage?
      assert_equal 1, coverage.line_hits(1)
      assert_equal :native_branch, Boobytrap::CoverageData.branch_source(coverage.format)
      assert_equal "a1", coverage.branch_arms.first.arm_id
      assert_equal 0, coverage.branch_arms.first.hits
    end
  end

  def test_builds_zig_branch_catalog_when_tree_sitter_grammar_is_available
    grammar = ENV["DECOMPLEX_TS_ZIG_PATH"]
    skip "set DECOMPLEX_TS_ZIG_PATH to run Zig branch catalog test" unless grammar && File.file?(grammar)

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/src")
      File.write("#{dir}/src/worker.zig", <<~ZIG)
        fn run(x: i32) bool {
            if (x > 0) {
                return true;
            } else {
                return false;
            }
        }
      ZIG

      catalog = with_env("DECOMPLEX_PARSER", "tree_sitter") do
        Boobytrap::CoverageData.branch_catalog(["src/worker.zig"], root: dir)
      end
      file = catalog.fetch("files").first

      assert_equal "nil-kill.branch-catalog", catalog["format"]
      assert_equal "src/worker.zig", file["path"]
      assert_equal "zig", file["language"]
      assert_operator file.fetch("arms").size, :>=, 2
      assert file.fetch("arms").all? { |arm| arm["arm_id"].to_s.include?("\0") }
    end
  end

  def test_loads_kcov_codecov_with_summary_path_map
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/zig/runtime")
      FileUtils.mkdir_p("#{dir}/coverage")
      file = "#{dir}/zig/runtime/a.zig"
      File.write(file, "fn a() void {\n    return;\n}\n")
      File.write("#{dir}/coverage/coverage.json", JSON.dump(
        "files" => [{ "file" => file, "covered_lines" => "1", "total_lines" => "2" }]
      ))
      File.write("#{dir}/coverage/codecov.json", JSON.dump(
        "coverage" => { "runtime/a.zig" => { "1" => 1, "2" => 0 } }
      ))

      dataset = Boobytrap::CoverageData.load("#{dir}/coverage/codecov.json", root: dir)
      coverage = dataset[file]

      assert_equal "kcov codecov", dataset.label
      assert_equal ["zig/runtime/a.zig"], dataset.covered_files(root: dir)
      assert_equal 1, coverage.line_hits(1)
      assert_equal 0, coverage.line_hits(2)
    end
  end
end
