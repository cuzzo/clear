# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/boobytrap"

class MutationFactsCovTest < Minitest::Test
  def test_risk_multiplier
    fact_strong = Minitest::Mock.new
    fact_strong.expect :strong?, true
    fact_strong.expect :moderate?, false
    
    fact_weak = Minitest::Mock.new
    fact_weak.expect :strong?, false
    fact_weak.expect :moderate?, false
    
    # 0.9 if strong && high complexity && high history
    assert_equal 0.9, Boobytrap::MutationFacts.risk_multiplier(fact_strong, active: true, complexity: 5, history: 0.5, coverage_gap: 0)
    
    fact_strong = Minitest::Mock.new
    fact_strong.expect :strong?, true
    fact_strong.expect :moderate?, false
    # 0.75 if strong but not both high
    assert_equal 0.75, Boobytrap::MutationFacts.risk_multiplier(fact_strong, active: true, complexity: 1, history: 0, coverage_gap: 0)
    
    fact_moderate = Minitest::Mock.new
    fact_moderate.expect :strong?, false
    fact_moderate.expect :moderate?, true
    # 1.1 if moderate
    assert_equal 1.1, Boobytrap::MutationFacts.risk_multiplier(fact_moderate, active: true, complexity: 1, history: 0, coverage_gap: 0)
    
    # weak
    fact_weak1 = Minitest::Mock.new
    fact_weak1.expect :strong?, false
    fact_weak1.expect :moderate?, false
    assert_equal 1.9, Boobytrap::MutationFacts.risk_multiplier(fact_weak1, active: true, complexity: 5, history: 0.5, coverage_gap: 0.8)
    
    fact_weak2 = Minitest::Mock.new
    fact_weak2.expect :strong?, false
    fact_weak2.expect :moderate?, false
    assert_equal 1.7, Boobytrap::MutationFacts.risk_multiplier(fact_weak2, active: true, complexity: 5, history: 0.5, coverage_gap: 0)
    
    fact_weak3 = Minitest::Mock.new
    fact_weak3.expect :strong?, false
    fact_weak3.expect :moderate?, false
    assert_equal 1.45, Boobytrap::MutationFacts.risk_multiplier(fact_weak3, active: true, complexity: 5, history: 0, coverage_gap: 0)
    
    fact_weak4 = Minitest::Mock.new
    fact_weak4.expect :strong?, false
    fact_weak4.expect :moderate?, false
    assert_equal 1.25, Boobytrap::MutationFacts.risk_multiplier(fact_weak4, active: true, complexity: 1, history: 0, coverage_gap: 0)
  end

  def test_profile
    fact_weak = Minitest::Mock.new
    fact_weak.expect :weak?, true
    fact_weak.expect :strong?, false
    fact_weak.expect :moderate?, false
    assert_equal "lurking disaster", Boobytrap::MutationFacts.profile(fact_weak, active: true, complexity: 5, history: 0.5, coverage_gap: 0.8)
    
    fact_strong = Minitest::Mock.new
    fact_strong.expect :weak?, false
    fact_strong.expect :strong?, true
    assert_equal "hardened veteran", Boobytrap::MutationFacts.profile(fact_strong, active: true, complexity: 5, history: 0.5, coverage_gap: 0)
    
    fact_weak2 = Minitest::Mock.new
    fact_weak2.expect :weak?, true
    fact_weak2.expect :strong?, false
    fact_weak2.expect :weak?, true
    assert_equal "fragile newcomer", Boobytrap::MutationFacts.profile(fact_weak2, active: true, complexity: 1, history: 0.5, coverage_gap: 0)
    
    fact_weak3 = Minitest::Mock.new
    fact_weak3.expect :weak?, true
    fact_weak3.expect :strong?, false
    fact_weak3.expect :weak?, true
    fact_weak3.expect :weak?, true
    assert_equal "weak verification", Boobytrap::MutationFacts.profile(fact_weak3, active: true, complexity: 1, history: 0, coverage_gap: 0)
    
    fact_mod = Minitest::Mock.new
    fact_mod.expect :weak?, false
    fact_mod.expect :strong?, false
    fact_mod.expect :weak?, false
    fact_mod.expect :weak?, false
    fact_mod.expect :moderate?, true
    assert_equal "partial verification", Boobytrap::MutationFacts.profile(fact_mod, active: true, complexity: 1, history: 0, coverage_gap: 0)
    
    fact_other = Minitest::Mock.new
    fact_other.expect :weak?, false
    fact_other.expect :strong?, false
    fact_other.expect :weak?, false
    fact_other.expect :weak?, false
    fact_other.expect :moderate?, false
    assert_equal "load-bearing tests", Boobytrap::MutationFacts.profile(fact_other, active: true, complexity: 1, history: 0, coverage_gap: 0)
  end

  def test_fact_weak_and_summary
    f1 = Boobytrap::MutationFacts::Fact.new(kill_rate: nil, gate_status: "passing")
    assert f1.weak?
    assert_equal "no mutation / passing", f1.summary

    f2 = Boobytrap::MutationFacts::Fact.new(kill_rate: 50.0, gate_status: "passing")
    assert f2.weak?
    assert_equal "50.0% killed / passing", f2.summary

    f3 = Boobytrap::MutationFacts::Fact.new(kill_rate: 80.0, gate_status: "advisory")
    assert f3.weak?
    assert_equal "80.0% killed / advisory", f3.summary
    
    f4 = Boobytrap::MutationFacts::Fact.new(kill_rate: 80.0, gate_status: nil)
    assert_equal "80.0% killed / unknown gate", f4.summary
  end

  def test_index_fallbacks
    facts = {}
    idx = Boobytrap::MutationFacts::Index.new(facts: facts, active: true, label: "test")
    
    assert idx.empty?
    
    # Fallback to file default
    facts[["a.rb", "*"]] = Boobytrap::MutationFacts::Fact.new(kill_rate: 100.0)
    assert_equal 100.0, idx.lookup("a.rb", "m1").kill_rate
    
    # Fallback to global default
    facts.clear
    facts[["\0global", "m1"]] = Boobytrap::MutationFacts::Fact.new(kill_rate: 90.0)
    assert_equal 90.0, idx.lookup("a.rb", "m1").kill_rate
    
    # Status for active
    facts.clear
    assert_equal "missing", idx.status_for("a.rb", "m1").gate_status
  end

  def test_load_exceptions
    Boobytrap::MutationFacts.stub :empty, "empty_idx" do
      assert_equal "empty_idx", Boobytrap::MutationFacts.load("nonexistent.json", root: "/")
    end
    
    require 'tmpdir'
    Dir.mktmpdir do |dir|
      file = "#{dir}/bad.json"
      File.write(file, "{bad json}")
      Boobytrap::MutationFacts.stub :empty, "empty_idx" do
        assert_equal "empty_idx", Boobytrap::MutationFacts.load(file, root: "/")
      end
    end
  end

  def test_parse_kill_rate
    assert_nil Boobytrap::MutationFacts.parse_kill_rate(nil)
    assert_nil Boobytrap::MutationFacts.parse_kill_rate("bad")
  end
end
