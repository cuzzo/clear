# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/boobytrap"

class LineageRiskCovTest < Minitest::Test
  def test_load_rescue_errors
    Boobytrap::LineageRisk.stub :system, ->(*args) { raise SystemCallError.new("stubbed error", 1) } do
      res = Boobytrap::LineageRisk.load("dummy.json", repo: Dir.pwd)
      assert_equal :absent, res[:status]
    end
  end

  def test_exposure_profile
    unit = Boobytrap::LineageRisk::Unit.new(
      id: "1", name: "A", kind: "F", file: "a.rb",
      total_events: 1, changes: 1, moves: 0, fixes: 0, risk_score: 1.0,
      current_distinct_tests: 5, current_test_types: ["unit", "integration"],
      current_mutant_verified_tests: 0, current_mutant_killed_tests: 0,
      last_test_exposure_at: 10, latest_fix_at: 5, latest_change_at: 5,
      fixes_after_test_exposure: 0, changes_after_test_exposure: 0
    )
    
    # diverse named coverage
    assert_equal "diverse named coverage (lineage)", Boobytrap::LineageRisk.exposure_profile(unit)
    
    # named coverage
    unit = Boobytrap::LineageRisk::Unit.new(
      id: "1", name: "A", kind: "F", file: "a.rb",
      total_events: 1, changes: 1, moves: 0, fixes: 0, risk_score: 1.0,
      current_distinct_tests: 2, current_test_types: ["unit"],
      current_mutant_verified_tests: 0, current_mutant_killed_tests: 0,
      last_test_exposure_at: 10, latest_fix_at: 5, latest_change_at: 5,
      fixes_after_test_exposure: 0, changes_after_test_exposure: 0
    )
    assert_equal "named coverage (lineage)", Boobytrap::LineageRisk.exposure_profile(unit)
    
    # thin named coverage
    unit = Boobytrap::LineageRisk::Unit.new(
      id: "1", name: "A", kind: "F", file: "a.rb",
      total_events: 1, changes: 1, moves: 0, fixes: 0, risk_score: 1.0,
      current_distinct_tests: 1, current_test_types: ["unit"],
      current_mutant_verified_tests: 0, current_mutant_killed_tests: 0,
      last_test_exposure_at: 10, latest_fix_at: 5, latest_change_at: 5,
      fixes_after_test_exposure: 0, changes_after_test_exposure: 0
    )
    assert_equal "thin named coverage (lineage)", Boobytrap::LineageRisk.exposure_profile(unit)
  end

  def test_exposure_multiplier
    unit = Boobytrap::LineageRisk::Unit.new(
      id: "1", name: "A", kind: "F", file: "a.rb",
      total_events: 1, changes: 1, moves: 0, fixes: 0, risk_score: 1.0,
      current_distinct_tests: 5, current_test_types: ["unit", "integration"],
      current_mutant_verified_tests: 0, current_mutant_killed_tests: 0,
      last_test_exposure_at: 10, latest_fix_at: 5, latest_change_at: 5,
      fixes_after_test_exposure: 0, changes_after_test_exposure: 0
    )
    
    # 0.75 multiplier for >= 5 tests and >= 2 types
    assert_equal 0.75, Boobytrap::LineageRisk.exposure_multiplier(unit, active: true, complexity: 1, history: 0, coverage_gap: 0)
    
    # 0.88 for >= 2 tests
    unit = Boobytrap::LineageRisk::Unit.new(
      id: "1", name: "A", kind: "F", file: "a.rb",
      total_events: 1, changes: 1, moves: 0, fixes: 0, risk_score: 1.0,
      current_distinct_tests: 2, current_test_types: ["unit"],
      current_mutant_verified_tests: 0, current_mutant_killed_tests: 0,
      last_test_exposure_at: 10, latest_fix_at: 5, latest_change_at: 5,
      fixes_after_test_exposure: 0, changes_after_test_exposure: 0
    )
    assert_equal 0.88, Boobytrap::LineageRisk.exposure_multiplier(unit, active: true, complexity: 1, history: 0, coverage_gap: 0)
    
    # 0.97 for high risk shape but thin coverage
    unit = Boobytrap::LineageRisk::Unit.new(
      id: "1", name: "A", kind: "F", file: "a.rb",
      total_events: 1, changes: 1, moves: 0, fixes: 0, risk_score: 1.0,
      current_distinct_tests: 1, current_test_types: ["unit"],
      current_mutant_verified_tests: 0, current_mutant_killed_tests: 0,
      last_test_exposure_at: 10, latest_fix_at: 5, latest_change_at: 5,
      fixes_after_test_exposure: 0, changes_after_test_exposure: 0
    )
    assert_equal 0.97, Boobytrap::LineageRisk.exposure_multiplier(unit, active: true, complexity: 10, history: 0, coverage_gap: 0)
  end
end
