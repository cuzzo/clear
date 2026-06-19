# frozen_string_literal: true

class TemporalOrderExample
  def one
    @a = 1
  end

  def two
    @a = 2
    @b = 3
  end

  def three
    @b = 4
  end

  def reader
    @a
  end
end
