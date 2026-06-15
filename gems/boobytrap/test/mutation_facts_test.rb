# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/boobytrap/mutation_facts"

class MutationFactsTest < Minitest::Test
  def test_loads_owner_method_and_bare_method_aliases
    Dir.mktmpdir do |dir|
      path = File.join(dir, "mutant.json")
      File.write(path, JSON.dump(
        "schema" => "mutant-facts/v1",
        "subjects" => [
          {
            "file" => "src/worker.rb",
            "method" => "Worker#call",
            "kill_rate" => "12.5%",
            "gate_status" => "advisory"
          }
        ]
      ))

      facts = Boobytrap::MutationFacts.load(path, root: dir)
      by_owner = facts.lookup("src/worker.rb", "Worker#call")
      by_name = facts.lookup("src/worker.rb", "call")

      assert facts.active?
      assert_equal by_owner, by_name
      assert_equal 12.5, by_name.kill_rate
      assert by_name.weak?
    end
  end

  def test_empirical_profile_marks_complex_churned_weakly_verified_code
    fact = Boobytrap::MutationFacts::Fact.new(
      file: "src/worker.rb",
      method: "call",
      kill_rate: 10.0,
      gate_status: "advisory"
    )

    profile = Boobytrap::MutationFacts.profile(
      fact,
      active: true,
      complexity: 7,
      history: 0.9,
      coverage_gap: 1.0
    )
    multiplier = Boobytrap::MutationFacts.risk_multiplier(
      fact,
      active: true,
      complexity: 7,
      history: 0.9,
      coverage_gap: 1.0
    )

    assert_equal "lurking disaster", profile
    assert_operator multiplier, :>, 1.0
  end
end
