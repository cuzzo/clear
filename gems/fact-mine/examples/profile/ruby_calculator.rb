class Calculator
  attr_accessor :total

  def add(value)
    @total = (@total || 0) + value
  end

  def result
    @total
  end
end