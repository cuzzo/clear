# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require_relative "../lib/boobytrap"

class PythonCoverageCovTest < Minitest::Test
  def test_python_coverage_parsing
    Dir.mktmpdir do |dir|
      file = "#{dir}/coverage.json"
      src = "#{dir}/src.py"
      File.write(src, "def a(): pass\n")
      
      data = {
        "meta" => {
          "version" => "7.6.4",
          "timestamp" => "2024-10-31T00:00:00",
          "branch_coverage" => true,
          "show_contexts" => false
        },
        "files" => {
          src => {
            "executed_lines" => [1],
            "summary" => {
              "covered_lines" => 1,
              "num_statements" => 1,
              "percent_covered" => 100.0,
              "percent_covered_display" => "100",
              "missing_lines" => 0,
              "excluded_lines" => 0,
              "num_branches" => 0,
              "num_partial_branches" => 0,
              "covered_branches" => 0,
              "missing_branches" => 0
            },
            "missing_lines" => [],
            "excluded_lines" => [],
            "executed_branches" => [
              [1, 2]
            ],
            "missing_branches" => [
              [1, -1]
            ]
          }
        }
      }
      
      File.write(file, JSON.dump(data))
      
      provider = Boobytrap::CoverageProviders::Python
      assert provider.coverage_py_json?(data)
      assert provider.handles_file?(file)
      
      dataset = provider.load(file, root: dir)
      assert dataset
    end
  end

  def test_normalize_arcs
    provider = Boobytrap::CoverageProviders::Python
    arcs = provider.send(:normalize_arcs, [[1, 2], [0, 1], ["3", "4"], [1]])
    assert_equal [[1, 2], [3, 4]], arcs
  end

  def test_line_in_span
    provider = Boobytrap::CoverageProviders::Python
    assert provider.send(:line_in_span?, 2, [1, 0, 3, 0])
    refute provider.send(:line_in_span?, 4, [1, 0, 3, 0])
    refute provider.send(:line_in_span?, 2, [1, 0])
  end

  def test_arm_hits
    provider = Boobytrap::CoverageProviders::Python
    arm = {"decision_line" => 1, "arm_span" => [2, 0, 3, 0]}
    
    # Executed
    assert_equal 1, provider.send(:arm_hits, arm, [[1, 2]], [[1, 4]])
    
    # Missing
    assert_equal 0, provider.send(:arm_hits, arm, [[1, 5]], [[1, 2]])
    
    # Neither
    assert_nil provider.send(:arm_hits, arm, [[1, 5]], [[1, 4]])
  end
end
