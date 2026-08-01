# frozen_string_literal: true

require "set"

# The values the collector's value domain is held to. Deliberately a single
# ordered sequence rather than independent cases: a collection's shape is
# remembered against the classes it was carrying, so the answer to a later
# question depends on the earlier ones. Reordering this list changes the
# expected answers, which is why the recorded fixture is regenerated whenever
# it changes rather than edited.
module ValueDomainCorpus
  Point = Struct.new(:x, :y)
  Nested = Struct.new(:point, :tags)
  Solo = Struct.new(:only)

  module Strategy; end

  LEAVES = [1, 2.0, "s", :sym, nil, true, false, 2**70].freeze

  # A deterministic random sweep, kept for widening the corpus by hand when a
  # new derivation rule lands. It is not part of the recorded fixture: 600 of
  # these were 1.2 MB of JSON to cover four behaviours the curated cases above
  # now name outright, and a named case says which behaviour it is protecting.
  #
  #   ValueDomainCorpus.generated(Random.new(seed), depth)
  def self.generated(random, depth)
    return LEAVES[random.rand(LEAVES.length)] if depth <= 0

    case random.rand(6)
    when 0 then Array.new(random.rand(4)) { generated(random, depth - 1) }
    when 1 then Array.new(random.rand(25)) { generated(random, depth - 1) }
    when 2 then Array.new(random.rand(4)) { [generated(random, 0), generated(random, depth - 1)] }.to_h
    when 3 then Set.new(Array.new(random.rand(4)) { generated(random, depth - 1) })
    when 4 then Array.new(random.rand(25)) { [generated(random, 0), generated(random, depth - 1)] }.to_h
    else LEAVES[random.rand(LEAVES.length)]
    end
  end

  def self.curated
    anonymous = Class.new
    [
      ["nil", nil], ["true", true], ["false", false], ["integer", 1],
      ["bignum", 2**80], ["float", 1.5], ["string", "text"], ["symbol", :symbol],
      ["range", (1..3)], ["object", Object.new],
      ["class", String], ["module", Strategy], ["interface", Comparable],
      ["anonymous class", anonymous], ["anonymous module", Module.new],
      ["anonymous error", Class.new(StandardError)],
      ["empty array", []], ["integer array", [1, 2, 3]], ["string array", %w[a b]],
      ["mixed array", [1, "two", :three]], ["oversampled array", (1..50).to_a],
      ["oversampled strings", (1..50).map(&:to_s)],
      ["nested array", [[1], [2]]], ["array of hashes", [{ "a" => 1 }]],
      ["nil array", [nil, nil]],
      ["empty hash", {}], ["string hash", { "a" => 1, "b" => 2 }],
      ["symbol hash", { a: "x" }], ["mixed hash", { "a" => 1, b: "two" }],
      ["nested hash", { "outer" => { "inner" => 1 } }],
      ["hash of arrays", { "list" => [1, 2] }],
      ["oversampled hash", (1..50).to_h { |i| [i.to_s, i] }],
      ["empty set", Set.new], ["integer set", Set[1, 2]], ["string set", Set["a", "b"]],
      ["mixed set", Set[1, "two"]], ["nested set", Set[[1], [2]]],
      ["record", Point.new(1, 2)], ["record of strings", Point.new("a", "b")],
      ["nested record", Nested.new(Point.new(1, 2), %w[x y])],
      ["record with empties", Nested.new(nil, {})],
      ["single field record", Solo.new(nil)],
      ["array of records", [Point.new(1, 2)]],
      ["hash of records", { "point" => Point.new(1, 2) }],
      ["set of records", Set[Point.new(1, 2)]],
      # A second collection of the same record class reuses the first one's
      # remembered layout, whatever this one is actually carrying.
      ["reused record layout", [Point.new("a", "b")]],
      ["reused record layout again", [Point.new(nil, nil)]],
      # Depth and oversampling, which a shallow case cannot reach: the deriver
      # walks a fixed number of levels and samples a fixed number of elements,
      # and both limits have a side either way.
      ["deep array", [[["a", 1.0, nil]]]],
      ["deep set", Set[[[false, true, 1.0]]]],
      ["oversampled nested array", Array.new(30) { |i| [i, i.to_s] }],
      ["oversampled deep array", Array.new(30) { |i| [[i, { "k" => i }]] }],
      ["oversampled hash of nested", (1..30).to_h { |i| [i.to_s, [i, [i]]] }],
      # Longer than the sample and already disagreeing within it: a tuple whose
      # length is only known to be at least the sample.
      ["long mixed array", Array.new(30) { |i| i.even? ? i : i.to_s }],
    ]
  end

  def self.each_value
    return to_enum(:each_value) unless block_given?

    curated.each { |label, value| yield label, value }
  end
end
