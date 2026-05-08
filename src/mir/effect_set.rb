# typed: true
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

  # True-Sync-Polymorphism (#327): the ?-form contention/blocking
  # effects are now spelled `contends_maybe` / `blocks_maybe` for
  # readability. The legacy spellings (`contention?`, `blocking?`)
  # are accepted as aliases for backward compatibility but are not
  # produced by the inferer anymore.
  KNOWN = %i[
    yield alloc_heap io fail
    contention blocking
    contends_maybe blocks_maybe
    contention? blocking?
  ].to_set.freeze

  attr_reader :effects

  def initialize(effects = nil)
    eff = effects ? Set.new(effects) : Set.new
    eff.each do |e|
      unless KNOWN.include?(e)
        raise ArgumentError, "Unknown effect: #{e.inspect}. Valid: #{KNOWN.to_a}"
      end
    end
    @effects = eff.freeze
  end

  def self.empty
    @empty ||= new
  end

  sig { params(effect: T.untyped).returns(T::Boolean) }
  def include?(effect)
    @effects.include?(effect)
  end

  def empty?
    @effects.empty?
  end

  sig { params(other: T.untyped).returns(EffectSet) }
  def union(other)
    EffectSet.new(@effects | other.effects)
  end

  sig { params(other: T.untyped).returns(T::Boolean) }
  def ==(other)
    other.is_a?(EffectSet) && @effects == other.effects
  end
  alias eql? ==

  def hash
    @effects.hash
  end

  # Human-readable summary used by the formatter (P4.2). Effects are
  # rendered in a stable order so signatures are deterministic.
  EFFECT_ORDER = %i[
    yield alloc_heap io fail
    contention contends_maybe contention?
    blocking blocks_maybe blocking?
  ].freeze

  sig { returns(Array) }
  def to_a
    EFFECT_ORDER.select { |e| @effects.include?(e) }
  end

  def to_s
    "EffectSet(#{to_a.join(', ')})"
  end
  alias inspect to_s
end
