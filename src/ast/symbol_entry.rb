# typed: strict
# Typed scope entry for Scope.locals.
# Each entry tracks a variable/function binding with its type, storage, and metadata.
# Back-references its owning Scope via `scope` for state operations.
#
# Mutation contract (read before adding a post-annotation mutator):
#
# Most fields are scope-local (live, moved, borrowed_alias, valid, read,
# lifetime). Mutating them on a nested-scope copy is correct.
#
# Storage-axis fields (storage, sync, type, capabilities) are
# function-global. After annotation, `Scope.dup` has produced one entry
# per nested scope that captured the binding. Any pass that mutates a
# storage-axis field on a parameter (e.g.
# `EscapeAnalysis.propagate_caller_sync!`) MUST mutate
# `param[:symbol]` (the function-level entry), and any consumer that
# reads from a captured SymbolEntry reference must refresh through
# `Scope.live_param_syms(fn)` first. See the doc comment on
# `Scope#initialize_copy` for the full rationale.
#
# Lifetime model:
#
# CLEAR has one lifetime mechanism on a binding: `lifetime`. It is always a
# non-nil Array of source SymbolEntries. Empty means no lifetime constraint.
# `[self]` means the binding is anchored to its declaring scope and cannot
# leave it. Any other sources mean the binding may escape only as far as every
# source can escape. Readers never inspect nil/scalar/hash variants; they ask
# whether the array is empty and then iterate it.
require "sorbet-runtime"
# `type=` calls `Type.new` unconditionally (a hard, non-lazy dependency),
# so Type must be loaded with this file. type.rb -> function_signature.rb
# -> intrinsic_emit/function_return; none require scope/symbol_entry, so
# this is acyclic and also makes FunctionSignature available for
# `fn_signature`'s typed return. (Scope is the one true cycle — see @scope.)
require_relative "type"
require_relative "async_result_shape"

# Scope and SymbolEntry are a mutual back-reference: scope.rb requires
# this file, so this file cannot require scope.rb. `# typed: strict`
# forces every ivar through the eager `T.let`, which needs `Scope`
# resolvable at first `SymbolEntry.new`. This guarded forward
# declaration is a pure no-op in the real load path (scope.rb defines
# Scope first); loaded in isolation it creates the bare constant that
# scope.rb later reopens (same constant, not a shadow), so `@scope`
# can be typed `T.nilable(Scope)` without restructuring the cycle.
class Scope; end unless defined?(Scope)

class SymbolEntry
    extend T::Sig

  attr_accessor :reg, :mutable, :storage, :sync, :rebindable,
                :size, :capabilities, :valid,
                :mutated,        # set by mark_var_mutated when the binding
                                 # is reassigned, field/index-assigned, or
                                 # passed to a mutates_receiver method.
                                 # Lives on the SymbolEntry (not just the
                                 # decl node) so WITH aliases — which have
                                 # no `reg` — also record their mutation.
                :invalid_reason, :resource, :close_zig, :read,
                :scope,          # Back-reference to owning Scope (set by Scope#declare)
                :scope_depth,    # declaring scope depth (0 = root)
                :ownership_kind, # :value, :collection, :affine, :resource, :rc, :sync
                :takes,          # true if parameter declared with TAKES (callee owns)
                :is_param,       # true when entry was declared as a function parameter
                :param_decl_token, # for is_param entries: the VAR_ID token at the
                                   # param's position in the function signature.
                                   # Used by build_declare_mutable_fix to point an
                                   # auto-fix at the parameter when the body
                                   # mutates it without `MUTABLE`.
                :link_source,    # :shared or :multiowned — tracks which strong ref @link was created from
                :borrowed_alias, # true only for BORROWED/RESTRICT aliases — fiber capture is stack-UAF
                :sync_families,  # Set of families when bound by REQUIRES disjunction
                :layout,         # nil | :indirect — heap-pinned cell with stable address
                :mutable_ref_target, # This binding is passed to a MUTABLE parameter by reference.
                                     # Forces Zig `var` storage so &binding yields *T, not *const T.
                :poly_borrow_target, # address is taken at a universal-polymorphic call site;
                                     # forces mutable Zig storage so the callee can write back.
                :init_contents_heap  # true when the binding's init expression's heap-bearing
                                     # fields are already reflected in storage (e.g. struct
                                     # lit with COPY'd strings). Legacy field; not an escape decision.
                                     # Escape placement is symbol.storage. See docs/agents/
                                     # provenance-collapse.md.

  # Explicit async handle shape for bindings whose surface Type cannot
  # distinguish Promise<List<T>> from List<Promise<T>>.
  sig { returns(T.nilable(AsyncResultShape)) }
  attr_accessor :async_result_shape

  # The binding's type. Single coercing seam: every input is laundered
  # to a Type so no reader needs a Symbol/Type/FunctionSignature/nil
  # discriminator. A function binding is a Type whose @raw is its
  # FunctionSignature (Type#fn_type?); a legacy bare Symbol becomes
  # Type.new(sym); an unresolved binding becomes Type.new(:Untyped) so
  # the pre-MIR invariant can catch it. Mirrors FunctionSignature#return_type=.
  sig { returns(Type) }
  attr_reader :type

  # The laundering seam input is a real bounded union, not untyped:
  # a legacy Symbol tag, a String type name, a Type, a function
  # binding's FunctionSignature, or nil (unresolved). Normalized to a
  # single Type. The runtime sig now enforces the accepted domain --
  # anything outside it is a compiler bug, surfaced here.
  sig { params(val: T.any(Symbol, String, Type, FunctionSignature, NilClass)).void }
  def type=(val)
    @type = val.nil? ? Type.new(:Untyped) : (val.is_a?(Type) ? val : Type.new(val))
  end

  sig { returns(T::Array[SymbolEntry]) }
  attr_reader :lifetime

  sig { params(value: T.untyped).void }
  def lifetime=(value)
    @lifetime = normalize_lifetime(value)
  end

  # A function binding is a Type whose @raw is its FunctionSignature
  # (Type#fn_type?). Readers that need the signature unwrap through
  # here so no site re-derives the Symbol/Type/FunctionSignature split.
  # The sig block is lazy (built on first call, by which point the full
  # compiler — including FunctionSignature — is loaded), so referencing
  # the constant here is safe despite the type.rb<->function_signature
  # require ordering.
  sig { returns(T.nilable(FunctionSignature)) }
  def fn_signature
    @type.fn_type? ? @type.raw : nil
  end

  # Backward-compat alias for `lifetime == :current_scope`.
  # Pre-existing callers (capabilities.rb's WITH-alias declarations,
  # annotator visit_*, escape_analysis) read and write this; both paths
  # delegate to `lifetime` so there's a single source of truth.
  # Mirror of Type#atomic?. Was reinvented inline as `sym.sync == :atomic`
  # across the annotator seam (decomplex #1 Reification-Miss).
  sig { returns(T::Boolean) }
  def atomic?
    self.class.atomic_sync?(@sync)
  end

  sig { params(sync: T.nilable(Symbol)).returns(T::Boolean) }
  def self.atomic_sync?(sync)
    sync_matches?(sync, :atomic)
  end

  # Mirror of Type#indirect? / Type#atomic_ptr?. The AtomicPtr pair
  # `sym.sync == :atomic && sym.layout == :indirect` was reinvented inline.
  sig { returns(T::Boolean) }
  def indirect?
    @layout == :indirect
  end

  sig { returns(T::Boolean) }
  def atomic_ptr?
    atomic? && indirect?
  end

  # Mirror of Type#locked? / Type#local? -- `sym.sync == :locked` /
  # `sym.sync == :local` reinvented inline (decomplex Reification-Miss).
  sig { returns(T::Boolean) }
  def locked?
    self.class.locked_sync?(@sync)
  end

  sig { returns(T::Boolean) }
  def local?
    self.class.local_sync?(@sync)
  end

  sig { returns(T::Boolean) }
  def write_locked?
    self.class.write_locked_sync?(@sync)
  end

  sig { params(sync: T.nilable(Symbol)).returns(T::Boolean) }
  def self.locked_sync?(sync)
    sync_matches?(sync, :locked)
  end

  sig { params(sync: T.nilable(Symbol)).returns(T::Boolean) }
  def self.write_locked_sync?(sync)
    sync_matches?(sync, :write_locked)
  end

  sig { params(sync: T.nilable(Symbol)).returns(T::Boolean) }
  def self.versioned_sync?(sync)
    sync_matches?(sync, :versioned)
  end

  sig { params(sync: T.nilable(Symbol)).returns(T::Boolean) }
  def self.local_sync?(sync)
    sync_matches?(sync, :local)
  end

  sig { params(sync: T.nilable(Symbol)).returns(T::Boolean) }
  def self.always_mutable_sync?(sync)
    sync_matches?(sync, :always_mutable)
  end

  sig { params(sync: T.nilable(Symbol)).returns(T::Boolean) }
  def self.locked_family_sync?(sync)
    locked_sync?(sync) || write_locked_sync?(sync)
  end

  sig { params(sync: T.nilable(Symbol)).returns(T::Boolean) }
  def self.cleanup_sync?(sync)
    locked_sync?(sync) || write_locked_sync?(sync) || always_mutable_sync?(sync) || versioned_sync?(sync)
  end

  sig { params(sync: T.nilable(Symbol), expected: Symbol).returns(T::Boolean) }
  def self.sync_matches?(sync, expected)
    sync == expected
  end

  # Binding is Rc/Arc-stored. `storage == :shared || storage == :multiowned`
  # was reinvented inline across the annotator/MIR seam (decomplex
  # Missing-Abstraction). Storage axis -- distinct from Type#any_rc?
  # (ownership axis).
  sig { returns(T::Boolean) }
  def rc_stored?
    self.class.rc_storage?(@storage)
  end

  sig { params(storage: T.nilable(Symbol)).returns(T::Boolean) }
  def self.rc_storage?(storage)
    storage == :shared || storage == :multiowned
  end

  # Canonical "where does this binding's data live?" accessor — SIMP-13b.
  # Returns the storage axis filtered to provenance values
  # (:heap, :frame, :rodata, :borrow) so callers replacing
  # `type.provenance` get an equivalent answer. Storage modes that aren't
  # provenance (:multiowned, :shared, :link, :local, :frozen) → nil
  # because Type#provenance also returned nil for those.
  PROVENANCE_STORAGE = T.let(
    [:heap, :frame, :rodata, :borrow, :stack].freeze,
    T::Array[Symbol]
  )
  sig { returns(T.nilable(Symbol)) }
  def provenance
    return nil unless PROVENANCE_STORAGE.include?(@storage)
    @storage
  end

  # Provenance predicates — SIMP-13f. Symbol#storage is the canonical source.
  sig { returns(T::Boolean) }
  def heap_storage?
    self.class.heap_storage_value?(@storage)
  end

  sig { returns(T::Boolean) }
  def frame_provenance?
    self.class.frame_storage_value?(@storage)
  end

  sig { returns(T::Boolean) }
  def rodata_provenance?
    @storage == :rodata
  end

  sig { returns(T::Boolean) }
  def borrow_provenance?
    @storage == :borrow
  end

  sig { returns(T::Boolean) }
  def local_storage?
    self.class.local_storage_value?(@storage)
  end

  sig { params(storage: T.nilable(Symbol)).returns(T::Boolean) }
  def self.heap_storage_value?(storage)
    storage == :heap
  end

  sig { params(storage: T.nilable(Symbol)).returns(T::Boolean) }
  def self.frame_storage_value?(storage)
    storage == :frame
  end

  sig { params(storage: T.nilable(Symbol)).returns(T::Boolean) }
  def self.local_storage_value?(storage)
    storage == :local
  end

  sig { returns(T::Boolean) }
  def non_escaping
    @lifetime.length == 1 && @lifetime.first.equal?(self)
  end

  sig { params(value: T::Boolean).void }
  def non_escaping=(value)
    if value
      @lifetime = [self]
    elsif non_escaping
      @lifetime = []
    end
  end

  sig { returns(T::Array[SymbolEntry]) }
  def lifetime_sources
    @lifetime
  end

  # Build a tied lifetime from source SymbolEntries. Empty / nil input returns
  # the unconstrained lifetime.
  sig { params(sources: T.nilable(T::Array[SymbolEntry])).returns(T::Array[SymbolEntry]) }
  def self.tied_lifetime(sources)
    return [] if sources.nil? || sources.empty?
    sources.uniq
  end

  sig { params(reg: T.untyped, type: T.untyped, mutable: T.untyped, storage: Symbol, sync: T.nilable(Symbol), layout: T.nilable(Symbol), rebindable: T::Boolean, size: Integer, capabilities: T::Set[Symbol], valid: T::Boolean, invalid_reason: T.nilable(String), resource: T.nilable(T::Boolean), close_zig: T.nilable(String)).void }
  def initialize(reg:, type:, mutable:, storage:, sync: nil, layout: nil, rebindable: false,
                 size: 0, capabilities: Set.new,
                 valid: true, invalid_reason: nil, resource: nil, close_zig: nil)
    @reg = reg
    @type = T.let(Type.new(:Untyped), Type)
    self.type = type
    @mutable = mutable
    @storage = storage
    @sync = sync
    @layout = layout
    @rebindable = rebindable
    @size = size
    @capabilities = capabilities
    @valid = valid
    @invalid_reason = invalid_reason
    @resource = resource
    @close_zig = close_zig
    @lifetime = T.let([], T::Array[SymbolEntry])
    @borrowed_alias = T.let(false, T::Boolean)
    @sync_families = T.let(nil, T.untyped)
    @mutable_ref_target = T.let(false, T::Boolean)
    @poly_borrow_target = T.let(false, T::Boolean)
    @mutated = T.let(false, T::Boolean)
    @read = T.let(false, T::Boolean)
    @scope = T.let(nil, T.nilable(Scope))
    @scope_depth = T.let(nil, T.nilable(Integer))
    @ownership_kind = T.let(nil, T.nilable(Symbol))
    @takes = T.let(false, T::Boolean)
    @is_param = T.let(false, T::Boolean)
    @param_decl_token = T.let(nil, T.untyped)
    @link_source = T.let(nil, T.nilable(Symbol))
    @init_contents_heap = T.let(false, T::Boolean)
    @async_result_shape = T.let(nil, T.nilable(AsyncResultShape))
  end

  private

  sig { params(value: T.untyped).returns(T::Array[SymbolEntry]) }
  def normalize_lifetime(value)
    return [] if value.nil?
    return [self] if value == :current_scope

    sources = if value.is_a?(Hash)
      value[:sources]
    else
      value
    end
    return [] if sources.nil?

    Array(sources).map do |source|
      unless source.is_a?(SymbolEntry)
        raise TypeError, "SymbolEntry#lifetime sources must be SymbolEntry instances"
      end
      source
    end.uniq
  end
end
