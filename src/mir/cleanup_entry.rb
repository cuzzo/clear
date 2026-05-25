# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

# CleanupEntry -- one binding's cleanup recipe, produced by
# CleanupClassifier and consumed by MIRLowering / MIREmitter.
#
# Was a loose `T::Hash[Symbol, T.untyped]`. It is now a typed value
# object that still subclasses Hash, so every existing `entry[:kind]`,
# `entry[:alloc] = ...`, `entry.dup`, `entry.dig(:alloc)`,
# `binding_entry && binding_entry[:needs_cleanup]` site keeps working
# byte-identically while the contract is tightened (single constructor,
# typed accessors, typed sigs). Reader burn-down (`[:k]` -> `.k`) and
# the non-nil contract land in later EPIC-66 slices.
#
# Field universe (all optional except kind/alloc/scope/needs_cleanup/
# has_moved_guard, which `build` always sets):
#   needs_cleanup alloc scope kind has_moved_guard match_as
#   resource_close_zig rc_alloc base_zig needs_release_fields
#   elem_needs_cleanup sync inner via_pointer source_kind
class CleanupEntry < Hash
  extend T::Sig
  extend T::Generic

  K = type_member { { fixed: Symbol } }
  V = type_member { { fixed: T.untyped } }
  Elem = type_member(:out) { { fixed: T.untyped } }

  # Canonical constructor. `entry()` in CleanupClassifier delegates here.
  sig do
    params(kind: Symbol, alloc: Symbol, has_moved_guard: T::Boolean,
           extra: T.untyped).returns(CleanupEntry)
  end
  def self.build(kind, alloc: :heap, has_moved_guard: true, **extra)
    e = new
    e[:needs_cleanup] = true
    e[:alloc] = alloc
    e[:scope] = alloc == :heap ? :heap : :function
    e[:kind] = kind
    e[:has_moved_guard] = has_moved_guard
    extra.each { |k, v| e[k] = v }
    e
  end

  sig { params(alloc: Symbol, scope: Symbol).returns(CleanupEntry) }
  def self.no_cleanup(alloc:, scope:)
    e = new
    e[:needs_cleanup] = false
    e[:alloc] = alloc
    e[:scope] = scope
    e[:kind] = :none
    e[:has_moved_guard] = false
    e
  end

  # Wrap a literal Hash (the few non-`build` construction sites:
  # MATCH-AS payload bindings, MIRLowering synthetic drop entries).
  sig { params(h: T::Hash[Symbol, T.untyped]).returns(CleanupEntry) }
  def self.from(h)
    e = new
    h.each { |k, v| e[k] = v }
    e
  end

  sig { returns(Symbol) }
  def kind = T.cast(self[:kind], Symbol)

  sig { returns(Symbol) }
  def alloc = T.cast(self[:alloc], Symbol)

  sig { returns(Symbol) }
  def scope = T.cast(self[:scope], Symbol)

  # Total presence predicates -- safe on the NONE sentinel.
  # `present?` is true only for a real classifier-produced entry;
  # NONE replaces the old `nil` "this binding needs no cleanup".
  sig { returns(T::Boolean) }
  def none? = equal?(NONE)

  sig { returns(T::Boolean) }
  def present? = !equal?(NONE)

  sig { returns(T::Boolean) }
  def needs_cleanup? = self[:needs_cleanup] == true

  sig { returns(T::Boolean) }
  def has_moved_guard? = self[:has_moved_guard] == true

  sig { returns(T::Boolean) }
  def match_as? = self[:match_as] == true

  sig { returns(T::Boolean) }
  def via_pointer? = self[:via_pointer] == true

  sig { returns(T::Boolean) }
  def needs_release_fields? = self[:needs_release_fields] == true

  sig { params(alloc: Symbol).returns(CleanupEntry) }
  def with_alloc(alloc)
    updated = dup
    updated[:alloc] = alloc
    updated[:scope] = alloc == :heap ? :heap : updated.scope
    updated
  end

  sig { returns(CleanupEntry) }
  def with_moved_guard
    updated = dup
    updated[:has_moved_guard] = true
    updated
  end

  sig { returns(T.nilable(Symbol)) }
  def rc_alloc = self[:rc_alloc]

  sig { returns(T.nilable(String)) }
  def base_zig = self[:base_zig]

  sig { returns(T.nilable(String)) }
  def resource_close_zig = self[:resource_close_zig]

  # The non-nil sentinel for "this binding needs no cleanup".
  # Replaces the old `nil` returned by an absent cleanup_bindings lookup.
  # `needs_cleanup?` is false and it carries no :alloc/:kind, so every
  # consumer guard (`.needs_cleanup?`, `.present?`, alloc/kind checks)
  # yields exactly what `nil` did -- without the nil-guard.
  NONE = T.let(new.freeze, CleanupEntry)
end
