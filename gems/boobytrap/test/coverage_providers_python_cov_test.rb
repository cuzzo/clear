# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/boobytrap"

class CoverageProvidersPythonCovTest < Minitest::Test
  def test_handles_file_rescue
    provider = Boobytrap::CoverageProviders::Python
    assert_equal false, provider.handles_file?("nonexistent.json")
    
    Dir.mktmpdir do |dir|
      file = "#{dir}/bad.json"
      File.write(file, "{bad json}")
      assert_equal false, provider.handles_file?(file)
    end
  end

  def test_coverage_py_json_fallback
    provider = Boobytrap::CoverageProviders::Python
    
    data1 = {
      "files" => {
        "a.py" => { "executed_lines" => [1] }
      }
    }
    assert_equal true, provider.send(:coverage_py_json?, data1)
    
    data2 = {
      "files" => {
        "a.py" => { "executed_branches" => [] }
      }
    }
    assert_equal true, provider.send(:coverage_py_json?, data2)
    
    data3 = {
      "files" => {
        "a.py" => { "missing_branches" => [] }
      }
    }
    assert_equal true, provider.send(:coverage_py_json?, data3)
    
    data4 = {
      "files" => {
        "a.py" => { "other" => 1 }
      }
    }
    assert_equal false, provider.send(:coverage_py_json?, data4)
  end

  def test_normalize_lines_missing
    provider = Boobytrap::CoverageProviders::Python
    entry = { "missing_lines" => [2] }
    lines = provider.send(:normalize_lines, entry)
    assert_equal [nil, 0], lines
    
    entry = { "executed_lines" => [2], "missing_lines" => [2] }
    lines = provider.send(:normalize_lines, entry)
    assert_equal [nil, 1], lines # missing doesn't overwrite
  end

  def test_native_branch_arms
    provider = Boobytrap::CoverageProviders::Python
    
    assert_equal [], provider.send(:native_branch_arms, "a.py", { "executed_branches" => [[1,2]], "missing_branches" => [] }, root: "/")
    
    Boobytrap::CoverageData.stub :load_decomplex_syntax, true do
      catalog = { "arms" => [ { "line" => 1 } ] }
      Boobytrap::CoverageData.stub :branch_catalog_file, catalog do
        provider.stub :arm_hits, 1 do
          Boobytrap::CoverageData.stub :normalize_native_branch_arm, ->(arm) { arm } do
            res = provider.send(:native_branch_arms, "a.py", { "executed_branches" => [[1,2]] }, root: "/")
            assert_equal 1, res.length
            assert_equal 1, res.first["hits"]
          end
        end
        
        provider.stub :arm_hits, nil do
          res = provider.send(:native_branch_arms, "a.py", { "executed_branches" => [[1,2]] }, root: "/")
          assert_equal [], res
        end
      end
      
      Boobytrap::CoverageData.stub :branch_catalog_file, ->(*) { raise StandardError } do
        res = provider.send(:native_branch_arms, "a.py", { "executed_branches" => [[1,2]] }, root: "/")
        assert_equal [], res
      end
    end
  end
end
