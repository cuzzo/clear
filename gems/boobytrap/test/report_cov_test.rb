# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/boobytrap"

class ReportCovTest < Minitest::Test
  def test_apply_mutation_risk
    # We will mock the row and facts
    facts = Minitest::Mock.new
    facts.expect :active?, true
    
    fact = Minitest::Mock.new
    fact.expect :summary, "summary"
    fact.expect :kill_rate, 0.5
    fact.expect :gate_status, "gate"
    facts.expect :status_for, fact, ["a.rb", "m1"]

    row = Minitest::Mock.new
    row.expect :file, "a.rb"
    row.expect :name, "m1"
    row.expect :verification_status=, nil, ["summary"]
    row.expect :mutation_kill_rate=, nil, [0.5]
    row.expect :mutation_gate_status=, nil, ["gate"]
    row.expect :line_gap, 0
    row.expect :risk_profile=, nil, [String]
    row.expect :line_gap, 0
    row.expect :verification_multiplier=, nil, [Numeric]
    row.expect :risk, 10.0
    row.expect :verification_multiplier, 1.25
    row.expect :risk=, nil, [12.5]

    report = Boobytrap::Report.allocate
    report.instance_variable_set(:@mutation_facts, facts)

    Boobytrap::MutationFacts.stub :profile, "profile" do
      Boobytrap::MutationFacts.stub :risk_multiplier, 1.25 do
        report.send(:apply_mutation_risk!, row, 5, 0.5)
      end
    end
    
    row.verify
    facts.verify
    fact.verify
  end

  def test_apply_test_exposure_risk
    facts = Minitest::Mock.new
    facts.expect :active?, true
    
    fact = Minitest::Mock.new
    fact.expect :summary, "summary"
    fact.expect :distinct_test_count, 1
    fact.expect :tested_line_count, 1
    fact.expect :tested_branch_count, 1
    fact.expect :mutant_verified_test_count, 1
    fact.expect :mutant_killed_test_count, 1

    facts.expect :status_for, fact, ["a.rb", "m1"], **{first_line: 1, last_line: 10}

    row = Minitest::Mock.new
    row.expect :file, "a.rb"
    row.expect :name, "m1"
    row.expect :first_line, 1
    row.expect :last_line, 10
    row.expect :test_exposure_status=, nil, ["summary"]
    row.expect :test_exposure_profile=, nil, [String]
    row.expect :distinct_test_count=, nil, [1]
    row.expect :tested_line_count=, nil, [1]
    row.expect :tested_branch_count=, nil, [1]
    row.expect :mutant_verified_test_count=, nil, [1]
    row.expect :mutant_killed_test_count=, nil, [1]
    row.expect :test_exposure_multiplier=, nil, [Numeric]
    row.expect :line_gap, 0
    row.expect :test_exposure_multiplier, 1.25
    row.expect :risk, 10.0
    row.expect :risk=, nil, [12.5]

    report = Boobytrap::Report.allocate
    report.instance_variable_set(:@test_exposure_facts, facts)

    Boobytrap::TestExposureFacts.stub :profile, "profile" do
      Boobytrap::TestExposureFacts.stub :risk_multiplier, 1.25 do
        report.send(:apply_test_exposure_risk!, row, 5, 0.5)
      end
    end
    
    row.verify
    facts.verify
  end

  def test_normalize_scope_path
    report = Boobytrap::Report.allocate
    report.instance_variable_set(:@repo, "/repo")
    
    assert_equal "", report.send(:normalize_scope_path, "")
    assert_equal "a", report.send(:normalize_scope_path, "./a/")
    assert_equal "a", report.send(:normalize_scope_path, "\\repo\\a") # Since expand_path will use cwd, hard to test absolute properly without full setup.
  end

  def test_coverage_mode
    report = Boobytrap::Report.allocate
    
    cov = Minitest::Mock.new
    cov.expect :empty?, false
    cov.expect :label, "cov"
    Boobytrap::DecomplexRisk.stub :tree_sitter?, true do
      assert_equal "cov + tree-sitter static fallback", report.send(:coverage_mode, cov, ["a"], [])
    end
    cov.verify

    cov = Minitest::Mock.new
    cov.expect :empty?, false
    cov.expect :label, "cov"
    Boobytrap::DecomplexRisk.stub :tree_sitter?, true do
      assert_equal "cov", report.send(:coverage_mode, cov, [], [])
    end
    cov.verify
    
    cov = Minitest::Mock.new
    cov.expect :empty?, true
    Boobytrap::DecomplexRisk.stub :tree_sitter?, true do
      assert_equal "tree-sitter static fallback", report.send(:coverage_mode, cov, ["a"], [])
    end
    cov.verify
    
    cov = Minitest::Mock.new
    cov.expect :empty?, true
    Boobytrap::DecomplexRisk.stub :tree_sitter?, false do
      assert_equal "absent", report.send(:coverage_mode, cov, ["a"], [])
    end
    cov.verify
    
    cov = Minitest::Mock.new
    cov.expect :empty?, true
    Boobytrap::DecomplexRisk.stub :tree_sitter?, false do
      assert_equal "unknown", report.send(:coverage_mode, cov, ["a"], ["gap"])
    end
    cov.verify
  end

  def test_source_files_in_scope_fallback
    report = Boobytrap::Report.allocate
    report.instance_variable_set(:@repo, Dir.tmpdir)
    report.instance_variable_set(:@files, [])
    
    IO.stub :popen, ->(*args, &block) { raise StandardError } do
      Dir.chdir(Dir.tmpdir) do
        File.write("a.rb", "def a; end")
      end
      
      report.stub :in_scope?, true do
        report.stub :source_file?, true do
          files = report.send(:current_source_files)
          assert files.include?("a.rb")
        end
      end
    end
  end
end
