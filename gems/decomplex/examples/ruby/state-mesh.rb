# frozen_string_literal: true

class StateMeshExample
  def initialize
    @a = 1
    @b = 2
  end

  def writer
    @a = 3
  end

  def reader
    @a + @b
  end

  def a_alias
    @a
  end
end
