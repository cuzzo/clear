# frozen_string_literal: true

module TestMiserModuleFunctionFixture
  module_function

  def classify(value)
    value ? :yes : :no
  end
end
