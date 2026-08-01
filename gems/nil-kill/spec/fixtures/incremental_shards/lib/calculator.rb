# frozen_string_literal: true

class ShardCalculator
  def double(value)
    value * 2
  end

  def triple(value)
    value * 3
  end

  def unused(value)
    value - 1
  end
end
