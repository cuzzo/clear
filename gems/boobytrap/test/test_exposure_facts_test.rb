# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/boobytrap/test_exposure_facts"

class TestExposureFactsTest < Minitest::Test
  def test_loads_flat_hits_and_nested_line_branch_hits
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test-exposure.json")
      File.write(path, JSON.dump(
        "schema" => "test-exposure/v1",
        "hits" => [
          {
            "file" => "src/worker.rb",
            "function" => "Worker#call",
            "line" => 10,
            "branch_id" => "b1",
            "test_id" => "spec/worker_spec.rb:1",
            "test_type" => "unit",
            "mutation_status" => "killed"
          }
        ],
        "files" => [
          {
            "file" => "src/worker.rb",
            "lines" => [
              {
                "line" => 11,
                "tests" => [
                  { "id" => "spec/integration_spec.rb:3", "type" => "integration" }
                ]
              }
            ],
            "branches" => [
              {
                "branch_id" => "b2",
                "line" => 12,
                "tests" => [
                  {
                    "id" => "spec/worker_spec.rb:2",
                    "type" => "unit",
                    "mutation_status" => "survived"
                  }
                ]
              }
            ]
          }
        ]
      ))

      facts = Boobytrap::TestExposureFacts.load(path, root: dir)
      fact = facts.status_for(
        "src/worker.rb",
        "call",
        first_line: 10,
        last_line: 12
      )

      assert facts.active?
      assert_equal 3, fact.distinct_test_count
      assert_equal 2, fact.tested_line_count
      assert_equal 2, fact.tested_branch_count
      assert_equal 2, fact.mutant_verified_test_count
      assert_equal 1, fact.mutant_killed_test_count
      assert_equal({ "integration" => 1, "unit" => 2 }, fact.test_type_counts)
      assert_includes fact.summary, "3 tests"
      assert_includes fact.summary, "mutant killed 1/2"
    end
  end

  def test_killed_mutants_reduce_risk_more_than_plain_hits
    killed = Boobytrap::TestExposureFacts::Fact.new(file: "src/x.rb", method: "call")
    3.times do |index|
      killed.add_function_hit(
        Boobytrap::TestExposureFacts::Hit.new(
          test_id: "spec/x_spec.rb:#{index}",
          test_type: "unit",
          mutation_status: "killed"
        )
      )
    end
    plain = Boobytrap::TestExposureFacts::Fact.new(file: "src/x.rb", method: "call")
    plain.add_function_hit(
      Boobytrap::TestExposureFacts::Hit.new(
        test_id: "spec/x_spec.rb:1",
        test_type: "unit",
        mutation_status: ""
      )
    )

    killed_multiplier = Boobytrap::TestExposureFacts.risk_multiplier(
      killed,
      active: true,
      complexity: 7,
      history: 0.8,
      coverage_gap: 1.0
    )
    plain_multiplier = Boobytrap::TestExposureFacts.risk_multiplier(
      plain,
      active: true,
      complexity: 7,
      history: 0.8,
      coverage_gap: 1.0
    )

    assert_operator killed_multiplier, :<, plain_multiplier
    assert_equal "mutation-killed exposure",
                 Boobytrap::TestExposureFacts.profile(killed, active: true)
  end
end
