# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/boobytrap"

class DecomplexRiskTest < Minitest::Test
  def test_uses_decomplex_convergence_score
    assert Boobytrap::DecomplexRisk.load_decomplex

    sections = [
      ["Tier One", 1, [{ at: "src/compiler.rb:compile:10" }]],
      ["Tier Three", 3, [{ sites: ["src/compiler.rb:compile:20"] }]]
    ]

    score = Boobytrap::DecomplexRisk.from_sections(sections, root: Dir.pwd)
                                      .fetch(["src/compiler.rb", "compile"])

    assert_equal 4, score.score
    assert_equal 2, score.findings
    assert_equal ["Tier One", "Tier Three"], score.detectors
  end
end
