# frozen_string_literal: true

require "minitest/autorun"
require_relative "../sarif_result_cap"

class SarifResultCapTest < Minitest::Test
  def result(rule, tier, index, level: "note")
    {
      "ruleId" => rule,
      "level" => level,
      "message" => { "text" => "#{rule}-#{index}" },
      "properties" => { "tier" => tier },
    }
  end

  def test_prolific_rule_cannot_crowd_out_other_detectors
    results = 100.times.map { |index| result("decomplex.noisy", 1, index, level: "warning") }
    results.concat(10.times.map { |index| result("decomplex.medium", 2, index) })
    results.concat(5.times.map { |index| result("decomplex.small", 3, index) })

    selected, stats = SarifResultCap.select(results, 12)
    counts = SarifResultCap.rule_counts(selected)

    assert_equal 12, selected.length
    assert_equal %w[decomplex.medium decomplex.noisy decomplex.small], counts.keys.sort
    assert_operator counts.fetch("decomplex.noisy"), :>, counts.fetch("decomplex.small")
    assert_equal 115, stats.fetch("original_by_rule").values.sum
    assert_equal 103, stats.fetch("truncated_by_rule").values.sum
  end

  def test_warning_precedes_note_within_the_same_tier_and_rule
    results = [
      result("decomplex.one", 1, 0),
      result("decomplex.one", 1, 1, level: "warning"),
      result("decomplex.two", 1, 2),
    ]

    selected, = SarifResultCap.select(results, 2)
    one = selected.find { |row| row["ruleId"] == "decomplex.one" }
    assert_equal "warning", one.fetch("level")
  end

  def test_does_not_reorder_or_copy_when_under_limit
    results = [result("decomplex.one", 1, 0), result("decomplex.two", 2, 1)]
    selected, stats = SarifResultCap.select(results, 10)
    assert_same results, selected
    assert_equal({ "decomplex.one" => 1, "decomplex.two" => 1 }, stats.fetch("retained_by_rule"))
  end
end
