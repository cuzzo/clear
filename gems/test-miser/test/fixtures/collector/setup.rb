# frozen_string_literal: true

require "mutant/integration/minitest"
require_relative "target"

class TestMiserCollectorFixtureTest < Minitest::Test
  cover "TestMiserCollectorFixture#classify"

  def test_true_a
    assert_equal :yes, TestMiserCollectorFixture.new.classify(true)
  end

  def test_true_b
    assert_equal :yes, TestMiserCollectorFixture.new.classify(true)
  end

  def test_does_not_exercise_method
    assert_respond_to TestMiserCollectorFixture.new, :classify
  end
end
