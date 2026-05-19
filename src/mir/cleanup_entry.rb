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
# Field universe (all optional except kind/alloc/needs_cleanup/
# has_moved_guard, which `build` always sets):
#   needs_cleanup alloc kind has_moved_guard match_as
#   resource_close_zig rc_variant rc_release_func rc_alloc base_zig
#   needs_release_fields elem_needs_cleanup sync inner via_pointer
#   source_kind zig_type elem_zig_type is_fixed
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
    e[:kind] = kind
    e[:has_moved_guard] = has_moved_guard
    extra.each { |k, v| e[k] = v }
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

  sig { returns(T::Boolean) }
  def needs_cleanup? = self[:needs_cleanup] == true

  sig { returns(T::Boolean) }
  def has_moved_guard? = self[:has_moved_guard] == true

  sig { returns(T::Boolean) }
  def match_as? = self[:match_as] == true

  sig { returns(T.nilable(String)) }
  def zig_type = self[:zig_type]

  sig { returns(T.nilable(String)) }
  def elem_zig_type = self[:elem_zig_type]
end
