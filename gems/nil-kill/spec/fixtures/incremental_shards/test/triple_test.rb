# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/calculator"

class ShardTripleTest < Minitest::Test
  def test_triple
    assert_equal 9, ShardCalculator.new.triple(3)
  end
end
