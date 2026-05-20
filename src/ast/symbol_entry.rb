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
# CLEAR has one lifetime mechanism on a binding: `lifetime`. The model
# answers a single question at every use site: "where is this binding
# allowed to escape to?". Three shapes:
#
#   nil               -- no lifetime constraint; the binding can escape
#                        anywhere (the default for ordinary local
#                        declarations).
#   :current_scope    -- the binding is anchored to its declaring
#                        scope and cannot leave it. Replaces the
#                        previous `non_escaping = true` flag. Used by
#                        WITH aliases (EXCLUSIVE / VIEW / RESTRICT /
#                        BORROWED / SNAPSHOT) and `@observable`
#                        bindings.
#   { sources: [SymbolEntry, ...] }
#                     -- the binding's lifetime is the INTERSECTION of
#                        every source's lifetime. The destination of
#                        an escape (struct field assign, list append,
#                        RETURN, BG capture, etc.) must be inside the
#                        scope of EVERY entry in `sources`. Two
#                        producers:
#
#                          (a) `RETURNS foo:T` — the returned value
#                              gets `{ sources: [foo] }`. Whatever
#                              foo's lifetime is, the returned value
#                              inherits it. If foo itself has a tied
#                              lifetime, the chain is followed.
#                          BG / DO / CONCURRENT capture —
#                              the spawned handle gets `{ sources:
#                              [each captured @shared:atomic / borrow
#                              binding] }`. The handle is free to
#                              flow into any same-scope or shorter
#                              destination, but cannot outlive the
#                              shortest-lived capture.
#
# `non_escaping` survives as a backward-compat alias on top of
# `lifetime == :current_scope`. All v0.1 call sites that wrote
# `sym.non_escaping = true` keep working; they now write through the
# unified field. Reading `sym.non_escaping` returns whether the
# lifetime is exactly `:current_scope` — a tied lifetime
# (`{ sources: [...] }`) is NOT non-escaping in the v0.1 sense (the
# binding CAN escape, just not past every source's scope), so the
# alias correctly returns false there.
#
# Helper: `lifetime_sources` returns the Array of source SymbolEntries
# regardless of shape (`[]` for nil / :current_scope, the source list
# for tied). Walkers consume that uniform list and compare each
# source's declaring scope against the destination.
require "sorbet-runtime"
# `type=` calls `Type.new` unconditionally (a hard, non-lazy dependency),
# so Type must be loaded with this file. type.rb -> function_signature.rb
# -> intrinsic_emit/function_return; none require scope/symbol_entry, so
# this is acyclic and also makes FunctionSignature available for
# `fn_signature`'s typed return. (Scope is the one true cycle — see @scope.)
require_relative "type"

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
                :lifetime,       # nil | :current_scope | { source: SymbolEntry }
                :borrowed_alias, # true only for BORROWED/RESTRICT aliases — fiber capture is stack-UAF
                :sync_families,  # Set of families when bound by REQUIRES disjunction
                :layout,         # nil | :indirect — heap-pinned cell with stable address
                :mutable_ref_target, # This binding is passed to a MUTABLE parameter by reference.
                                     # Forces Zig `var` storage so &binding yields *T, not *const T.
                :poly_borrow_target, # address is taken at a universal-polymorphic call site;
                                     # forces mutable Zig storage so the callee can write back.
                :init_contents_heap  # true when the binding's init expression's heap-bearing
                                     # fields are all in heap_provenance already (e.g. struct
                                     # lit with COPY'd strings). PromotionClassifier reads
                                     # this to skip redundant return-time promote. Single
                                     # writer: annotator at bind-time. See docs/agents/
                                     # provenance-collapse.md.

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
    @sync == :atomic
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
    @sync == :locked
  end

  sig { returns(T::Boolean) }
  def local?
    @sync == :local
  end

  sig { returns(T::Boolean) }
  def write_locked?
    @sync == :write_locked
  end

  # Binding is Rc/Arc-stored. `storage == :shared || storage == :multiowned`
  # was reinvented inline across the annotator/MIR seam (decomplex
  # Missing-Abstraction). Storage axis -- distinct from Type#any_rc?
  # (ownership axis).
  sig { returns(T::Boolean) }
  def rc_stored?
    @storage == :shared || @storage == :multiowned
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

  # Provenance predicates — SIMP-13. Symbol#storage is the canonical source,
  # but during a multi-stage transition some late ti.provenance writes haven't
  # yet been mirrored to sym.storage. Until those propagation gaps close
  # (SIMP-13f.2), check sym.type.provenance as a fallback. When complete, the
  # fallback line gets deleted in SIMP-13f.5.
  sig { returns(T::Boolean) }
  def heap_provenance?
    return true if @storage == :heap
    @type.is_a?(Type) && @type.respond_to?(:heap_provenance?) && @type.heap_provenance?
  end

  sig { returns(T::Boolean) }
  def frame_provenance?
    return true if @storage == :frame
    @type.is_a?(Type) && @type.respond_to?(:frame_provenance?) && @type.frame_provenance?
  end

  sig { returns(T::Boolean) }
  def rodata_provenance?
    return true if @storage == :rodata
    @type.is_a?(Type) && @type.respond_to?(:rodata_provenance?) && @type.rodata_provenance?
  end

  sig { returns(T::Boolean) }
  def borrow_provenance?
    return true if @storage == :borrow
    @type.is_a?(Type) && @type.respond_to?(:borrow_provenance?) && @type.borrow_provenance?
  end

  sig { returns(T::Boolean) }
  def non_escaping
    @lifetime == :current_scope
  end

  sig { params(value: T::Boolean).void }
  def non_escaping=(value)
    if value
      @lifetime = :current_scope
    elsif @lifetime == :current_scope
      @lifetime = nil
    end
  end

  # Uniform accessor for the source list regardless of the lifetime's shape.
  # Walkers (escape checker, BG-capture lifetime
  # propagation, RETURN value validation) iterate this without needing
  # to case on the lifetime variant. Returns:
  #
  #   nil               -> []      (unconstrained — no sources to check)
  #   :current_scope    -> [self]  (the binding's own SymbolEntry
  #                                 stands in as the source; declaring
  #                                 scope is the limit)
  #   { sources: [...] } -> the source list verbatim
  sig { returns(T::Array[T.untyped]) }
  def lifetime_sources
    case @lifetime
    when nil           then []
    when :current_scope then [self]
    else
      @lifetime.is_a?(Hash) && @lifetime[:sources].is_a?(Array) ? @lifetime[:sources] : []
    end
  end

  # Build a tied lifetime from source SymbolEntries. Empty / nil input returns
  # nil so callers can pass collected captures through without a guard.
  sig { params(sources: T.nilable(T::Array[SymbolEntry])).returns(T.nilable(T::Hash[Symbol, T::Array[SymbolEntry]])) }
  def self.tied_lifetime(sources)
    return nil if sources.nil? || sources.empty?
    { sources: sources.uniq }
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
    @lifetime = T.let(nil, T.untyped)
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
  end
end
