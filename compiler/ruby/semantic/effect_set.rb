# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require 'set'

# Phase 3 effect lattice for CLEAR's concurrency model.
#
# The closed set of inferrable effects (per docs/agents/refactorability.md):
#
#     :yield          — may suspend the fiber (BG / NEXT / MAY_YIELD call)
#     :alloc_heap     — may allocate from the heap
#     :io             — may do I/O (file / network / system call / FFI)
#     :fail           — may return an error (try / ?)
#
# Plus one author-written constraint:
#
#     :fast_path      — function may not have any blocking effect; verified
#                       against the inferred set.
#
# Lock acquisition is NOT a separate effect. REQUIRES carries the per-arg
# sync constraint at the signature level; WITH MATCH carries the per-family
# body. Effects cover the orthogonal axes only.
#
# EffectSet is intentionally tiny and stateless. Pass instances by value;
# operations return new sets. Same value, same set — `==` works.
class EffectSet
    extend T::Sig

  # The ?-form contention/blocking effects use readable spellings. Legacy
  # spellings are accepted as aliases but are not produced by the inferer.
  KNOWN = T.let(%i[
    yield alloc_heap io fail
    contention blocking
    contends_maybe blocks_maybe
    contention? blocking?
  ].to_set.freeze, T::Set[Symbol])

  sig { returns(T::Set[Symbol]) }
  attr_reader :effects

  sig { params(effects: T.untyped).void }
  def initialize(effects = nil)
    eff = effects ? Set.new(effects) : Set.new
    eff.each do |e|
      unless KNOWN.include?(e)
        raise ArgumentError, "Unknown effect: #{e.inspect}. Valid: #{KNOWN.to_a}"
      end
    end
    @effects = T.let(eff.freeze, T::Set[Symbol])
  end

  sig { params(effect: Symbol).returns(T::Boolean) }
  def include?(effect)
    @effects.include?(effect)
  end

  sig { returns(T::Boolean) }
  def empty?
    @effects.empty?
  end

  sig { params(other: EffectSet).returns(EffectSet) }
  def union(other)
    EffectSet.new(@effects | other.effects)
  end

  sig { params(other: EffectSet).returns(T::Boolean) }
  def ==(other)
    other.is_a?(EffectSet) && @effects == other.effects
  end
  alias eql? ==

  sig { returns(Integer) }
  def hash
    # Set#hash is not a CLEAR collection intrinsic. A bitset over this closed
    # lattice preserves the only Hash contract that matters here: equal effect
    # sets always produce equal hashes.
    value = 0
    value |= 1 if @effects.include?(:yield)
    value |= 2 if @effects.include?(:alloc_heap)
    value |= 4 if @effects.include?(:io)
    value |= 8 if @effects.include?(:fail)
    value |= 16 if @effects.include?(:contention)
    value |= 32 if @effects.include?(:blocking)
    value |= 64 if @effects.include?(:contends_maybe)
    value |= 128 if @effects.include?(:blocks_maybe)
    value |= 256 if @effects.include?(:contention?)
    value |= 512 if @effects.include?(:blocking?)
    value
  end

  # Human-readable summary used by the formatter. Effects are rendered in a
  # stable order so signatures are deterministic.
  EFFECT_ORDER = T.let(%i[
    yield alloc_heap io fail
    contention contends_maybe contention?
    blocking blocks_maybe blocking?
  ].freeze, T::Array[Symbol])

  sig { returns(T::Array[Symbol]) }
  def to_a
    ordered = T.let([], T::Array[Symbol])
    EFFECT_ORDER.each { |effect| ordered << effect if @effects.include?(effect) }
    ordered
  end

  sig { returns(String) }
  def to_s
    "EffectSet(#{to_a.join(', ')})"
  end

  sig { returns(String) }
  def inspect
    to_s
  end
end
