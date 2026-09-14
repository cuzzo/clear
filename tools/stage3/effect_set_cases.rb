# frozen_string_literal: true

# Shared corpus for the effect_set byte-compatibility check, so the Ruby oracle
# and the CLEAR harness are driven by exactly the same inputs.
module EffectSetCases
  KNOWN = %i[yield alloc_heap io fail contention blocking contends_maybe blocks_maybe].freeze

  # Singles, pairs, a triple and the full set -- enough to exercise ordering,
  # the hash bitmask, union and equality without generating thousands of cases.
  def self.sets
    base = [[]]
    base += KNOWN.map { |e| [e] }
    base += KNOWN.combination(2).to_a
    base << %i[yield io fail]
    base << KNOWN.dup
    base
  end

  def self.pairs
    s = sets
    s.first(6).product(s.first(6))
  end
end
