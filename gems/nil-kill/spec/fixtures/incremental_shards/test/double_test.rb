# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/calculator"

class ShardDoubleTest < Minitest::Test
  def test_double
    assert_equal 8, ShardCalculator.new.double(4)
  end
end
