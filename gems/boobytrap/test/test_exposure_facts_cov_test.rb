# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/boobytrap"

class TestExposureFactsCovTest < Minitest::Test
  def test_profile
    fact = Minitest::Mock.new
    fact.expect :distinct_test_count, 5
    fact.expect :mutant_killed_test_count, 0
    fact.expect :test_type_counts, {"unit" => 3, "integration" => 2}
    assert_equal "diverse named coverage", Boobytrap::TestExposureFacts.profile(fact, active: true)

    fact2 = Minitest::Mock.new
    fact2.expect :distinct_test_count, 2
    fact2.expect :mutant_killed_test_count, 0
    fact2.expect :test_type_counts, {"unit" => 2}
    fact2.expect :distinct_test_count, 2
    assert_equal "named coverage", Boobytrap::TestExposureFacts.profile(fact2, active: true)

    fact3 = Minitest::Mock.new
    fact3.expect :distinct_test_count, 1
    fact3.expect :mutant_killed_test_count, 0
    fact3.expect :test_type_counts, {"unit" => 1}
    fact3.expect :distinct_test_count, 1
    assert_equal "thin named coverage", Boobytrap::TestExposureFacts.profile(fact3, active: true)
  end

  def test_load_rescue
    Boobytrap::TestExposureFacts.stub :system, ->(*args) { raise SystemCallError.new("stub", 1) } do
      # Actually load only reads file
      Boobytrap::TestExposureFacts.stub :normalize_file, ->(*args) { raise SystemCallError.new("stub", 1) } do
        Dir.mktmpdir do |dir|
          file = "#{dir}/a.json"
          File.write(file, '{"files": [{"file": "a.rb"}]}')
          res = Boobytrap::TestExposureFacts.load(file, root: dir)
          assert res
        end
      end
    end
  end

  def test_add_file_entry
    index = Boobytrap::TestExposureFacts.empty(active: true)
    entry = {
      "file" => "src/a.rb",
      "functions" => [{"name" => "f1", "tests" => [{"id" => "1"}]}],
      "lines" => [{"line" => 1, "tests" => [{"id" => "1"}]}],
      "branches" => [{"id" => "b1", "line" => 1, "tests" => [{"id" => "1"}]}]
    }
    
    Boobytrap::TestExposureFacts.send(:add_file_entry!, index, entry, root: "/root")
    
    assert_equal 1, index.method_facts.size
    assert_equal 1, index.line_facts.size
    assert_equal 1, index.branch_facts.size
  end
end
