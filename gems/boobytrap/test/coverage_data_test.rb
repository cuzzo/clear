# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/boobytrap"

class CoverageDataTest < Minitest::Test
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
