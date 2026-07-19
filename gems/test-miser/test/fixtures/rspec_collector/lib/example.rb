# frozen_string_literal: true

class TestMiserRspecFixture
  def classify(value)
    value.positive? ? :positive : :nonpositive
  end
end
