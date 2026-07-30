# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/espalier"

# Minimal reproductions of loop/call pricing defects, each paired with the case
# that must NOT move. The committed SCIP index is required: without it the
# stdlib calls resolve to no cost and none of these shapes reproduce.
class BigOGoLoopCostsTest < Minitest::Test
  ROOT = File.expand_path("fixtures/big_o_go", __dir__)

  EXPECTED = {
    "EscapeByReturn" => "O(N)",
    "EscapeByBreak" => "O(N)",
    "JoinEveryIteration" => "O(N^2)",
    "PartitionedElementCost" => "O(N)",
    "PartitionedUnderFixedLoop" => "O(N)",
    "ConstantArgumentWrite" => "O(N)",
    "VariableArgumentWrite" => "O(N)"
  }.freeze

  def test_loop_and_call_pricing
    evidence = Espalier::StaticEvidence.build(
      [File.join(ROOT, "go_loop_costs.go")],
      root: ROOT,
      scip_indexes: [File.join(ROOT, "index.scip")]
    )
    manifest = Espalier::Aggregator.new.aggregate(Espalier::StaticEvidence.project_modules(evidence))
    actual = manifest.flat_map { |owner| owner.fetch(:functions) }
                     .to_h { |function| [function.fetch(:name), function.fetch(:quality_metrics).fetch(:big_o)] }

    EXPECTED.each do |name, bound|
      assert_equal bound, actual[name], name
    end
  end
end
