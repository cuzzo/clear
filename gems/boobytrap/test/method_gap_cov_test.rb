# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/boobytrap"

class MethodGapCovTest < Minitest::Test
  def test_merge_coverage
    data = {
      "res1" => {
        "coverage" => {
          "/a.rb" => {
            "lines" => [nil, 1, 0],
            "branches" => {
              "if" => { "then" => 1, "else" => 0 }
            }
          }
        }
      },
      "res2" => {
        "coverage" => {
          "/a.rb" => {
            "lines" => [0, 1, 1],
            "branches" => {
              "if" => { "then" => 0, "else" => 1 }
            }
          }
        }
      }
    }
    
    merged = Boobytrap::MethodGap.send(:merge_coverage, data)
    assert_equal 1, merged.size
    assert_equal [0, 2, 1], merged["/a.rb"]["lines"]
    assert_equal 1, merged["/a.rb"]["branches"]["if"]["then"]
    assert_equal 1, merged["/a.rb"]["branches"]["if"]["else"]
  end

  def test_covered_files
    Dir.mktmpdir do |dir|
      file = "#{dir}/.resultset.json"
      File.write("#{dir}/a.rb", "def a; end")
      File.write(file, %Q({"RSpec": {"coverage": {"#{dir}/a.rb": {"lines": [1]}}}}))
      
      files = Boobytrap::MethodGap.covered_files(file, root: dir)
      assert_equal ["a.rb"], files
    end
  end

  def test_tree_sitter_branch_misses_by_line
    cov = Minitest::Mock.new
    cov.expect :branch_arm_coverage?, false
    
    assert_equal({}, Boobytrap::MethodGap.send(:tree_sitter_branch_misses_by_line, "a.rb", cov))
    
    cov.verify
    
    cov = Minitest::Mock.new
    cov.expect :branch_arm_coverage?, true
    Boobytrap::MethodGap.stub :tree_sitter_source_for_coverage?, false do
      assert_equal({}, Boobytrap::MethodGap.send(:tree_sitter_branch_misses_by_line, "a.rb", cov))
    end
    cov.verify

    cov = Minitest::Mock.new
    cov.expect :branch_arm_coverage?, true
    Boobytrap::MethodGap.stub :tree_sitter_source_for_coverage?, true do
      doc = Minitest::Mock.new
      doc.expect :branch_arms, []
      Decomplex::Syntax.stub :parse, doc do
        Boobytrap::CoverageData.stub :dark_branch_misses_by_line, { 1 => 1 } do
          res = Boobytrap::MethodGap.send(:tree_sitter_branch_misses_by_line, "a.rb", cov)
          assert_equal({ 1 => 1 }, res)
        end
      end
      doc.verify
    end
    cov.verify
  end

  def test_method_ranges_for_file
    Decomplex::Syntax::Document.class_eval do
      def function_defs; end
    end
    begin
      Boobytrap::MethodGap.stub :tree_sitter_source_for_coverage?, true do
        doc = Minitest::Mock.new
        fn = Minitest::Mock.new
        fn.expect :span, [1, 0, 3, 0]
        fn.expect :span, [1, 0, 3, 0]
        fn.expect :name, "test_fn"
        doc.expect :function_defs, [fn]
        
        Decomplex::Syntax.stub :parse, doc do
          res = Boobytrap::MethodGap.send(:method_ranges_for_file, "a.rb", ["def test_fn", "end"])
          assert_equal 1, res.length
          assert_equal 1, res.first[:first_line]
          assert_equal 3, res.first[:last_line]
          assert_equal "test_fn", res.first[:name]
        end
        
        fn.verify
        doc.verify
      end
    ensure
      Decomplex::Syntax::Document.class_eval do
        remove_method :function_defs if method_defined?(:function_defs)
      end
    end
  end
end
