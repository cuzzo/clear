# frozen_string_literal: true

require_relative "formatter"

class IncrementalCalculator
  def total(values)
    values.map { |value| value * 2 }.sum
  end

  def label(value)
    IncrementalFormatter.render(value)
  end
end
