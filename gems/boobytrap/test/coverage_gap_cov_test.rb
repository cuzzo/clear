# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/boobytrap"

class CoverageGapCovTest < Minitest::Test
  def test_from_static
    Dir.mktmpdir do |dir|
      src_dir = File.join(dir, "src")
      FileUtils.mkdir_p(src_dir)
      file = File.join(src_dir, "a.rb")
      File.write(file, "def a; if true; 1; else; 2; end; end\n")
      
      Boobytrap::DecomplexRisk.stub :tree_sitter?, true do
        Boobytrap::DecomplexRisk.stub :load_decomplex_syntax, true do
          gaps = Boobytrap::CoverageGap.from_static(["src/a.rb"], root: dir)
          assert gaps["src/a.rb"]
          assert_equal 1.0, gaps["src/a.rb"].gap
        end
      end
    end
  end

  def test_native_branch_gap
    coverage_mock = Minitest::Mock.new
    coverage_mock.expect :branch_arm_coverage?, true
    coverage_mock.expect :branch_arm_coverage?, true
    
    arm_mock1 = Minitest::Mock.new
    arm_mock1.expect :covered, true
    arm_mock2 = Minitest::Mock.new
    arm_mock2.expect :covered, false
    
    doc_mock = Minitest::Mock.new
    doc_mock.expect :branch_arms, [arm_mock1, arm_mock2]
    
    Boobytrap::DecomplexRisk.stub :load_decomplex_syntax, true do
      Boobytrap::DecomplexRisk.stub :tree_sitter_supported_source?, true do
        Decomplex::Syntax.stub :parse, doc_mock do
          Boobytrap::CoverageData.stub :branch_arm_coverage, [arm_mock1, arm_mock2] do
            gap = Boobytrap::CoverageGap.native_branch_gap("src/a.rb", coverage_mock)
            assert gap
            assert_equal 2, gap.total
            assert_equal 1, gap.uncovered
            assert_in_delta 0.5, gap.gap, 0.01
          end
        end
      end
    end
  end
end
