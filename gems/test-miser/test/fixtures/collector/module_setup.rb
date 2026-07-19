# frozen_string_literal: true

require "mutant/integration/minitest"
require_relative "module_target"

class TestMiserModuleFunctionFixtureTest < Minitest::Test
  cover "TestMiserModuleFunctionFixture#classify"

  def test_true
    assert_equal :yes, TestMiserModuleFunctionFixture.classify(true)
  end
end
