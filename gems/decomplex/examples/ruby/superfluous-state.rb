# frozen_string_literal: true

class SuperfluousStateExample
  # 1. dead_state: written but never read.
  def write_dead
    @dead_state = 42
  end

  # 2. intra_method: written and read within the same method.
  def use_intra
    @intra_state = 100
    @intra_state + 5
  end

  # 3. adjacent_call: written in one method, read in another, called in sequence.
  def write_adjacent
    @adjacent_state = 200
  end

  def read_adjacent
    @adjacent_state
  end

  def run_sequence
    write_adjacent
    read_adjacent
  end

  # 4. Ordinary encapsulated state: cross-method reads alone do not prove that
  # the field is a derived cache or can be eliminated.
  def write_cache
    @cache_state = 300
  end

  def read_cache_one
    @cache_state
  end

  def read_cache_two
    @cache_state
  end
end
