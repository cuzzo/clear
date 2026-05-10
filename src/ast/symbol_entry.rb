# typed: true
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
# Lifetime model (Atomics M2.1 unification — see docs/agents/atomics.md §8):
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
#                          (b) BG / DO / CONCURRENT capture (M2.3) —
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

class SymbolEntry
    extend T::Sig

  attr_accessor :reg, :type, :mutable, :storage, :sync, :rebindable,
                :size, :capabilities, :valid,
                :mutated,        # set by mark_var_mutated when the binding
                                 # is reassigned, field/index-assigned, or
                                 # passed to a mutates_receiver method.
                                 # Lives on the SymbolEntry (not just the
                                 # decl node) so WITH aliases — which have
                                 # no `reg` — also record their mutation.
                :invalid_reason, :resource, :close_zig, :read,
                :scope,          # Back-reference to owning Scope (set by Scope#declare)
                :scope_depth,    # Atomics M2.6: declaring scope depth (0 = root)
                :ownership_kind, # :value, :collection, :affine, :resource, :rc, :sync
                :takes,          # true if parameter declared with TAKES (callee owns)
                :is_param,       # true when entry was declared as a function parameter
                :param_decl_token, # for is_param entries: the VAR_ID token at the
                                   # param's position in the function signature.
                                   # Used by build_declare_mutable_fix to point an
                                   # auto-fix at the parameter when the body
                                   # mutates it without `MUTABLE`.
                :link_source,    # :shared or :multiowned — tracks which strong ref @link was created from
                :lifetime,       # Atomics M2.1: nil | :current_scope | { source: SymbolEntry }
                :borrowed_alias, # true only for BORROWED/RESTRICT aliases — fiber capture is stack-UAF
                :sync_families,  # Set of families when bound by REQUIRES disjunction (ATOMICS M1.6.5)
                :layout,         # AtomicPtr M3.1: nil | :indirect — heap-pinned cell with stable address
                :mutable_ref_target, # This binding is passed to a MUTABLE parameter by reference.
                                     # Forces Zig `var` storage so &binding yields *T, not *const T.
                :poly_borrow_target  # True-Sync-Polymorphism Gate 3: this binding has its address taken
                                     # at a universally-polymorphic call site. Forces the var_decl
                                     # to emit `var` (mutable Zig storage) so &binding yields *T, not
                                     # *const T -- otherwise the polymorphic body's mutation can't
                                     # write through to the caller's binding.

  # Atomics M2.1: backward-compat alias for `lifetime == :current_scope`.
  # Pre-existing callers (capabilities.rb's WITH-alias declarations,
  # annotator visit_*, escape_analysis) read and write this; both paths
  # delegate to `lifetime` so there's a single source of truth.
  sig { returns(T::Boolean) }
  def non_escaping
    @lifetime == :current_scope
  end

  sig { params(value: T::Boolean).returns(T.nilable(Symbol)) }
  def non_escaping=(value)
    if value
      @lifetime = :current_scope
    elsif @lifetime == :current_scope
      @lifetime = nil
    end
  end

  # Atomics M2.1: uniform accessor for the source list regardless of
  # the lifetime's shape. Walkers (escape checker, BG-capture lifetime
  # propagation, RETURN value validation) iterate this without needing
  # to case on the lifetime variant. Returns:
  #
  #   nil               -> []      (unconstrained — no sources to check)
  #   :current_scope    -> [self]  (the binding's own SymbolEntry
  #                                 stands in as the source; declaring
  #                                 scope is the limit)
  #   { sources: [...] } -> the source list verbatim
  sig { returns(Array) }
  def lifetime_sources
    case @lifetime
    when nil           then []
    when :current_scope then [self]
    else
      @lifetime.is_a?(Hash) && @lifetime[:sources].is_a?(Array) ? @lifetime[:sources] : []
    end
  end

  # Atomics M2.1 (M2.3 producer): build a tied lifetime from a non-
  # empty Array of source SymbolEntries. Empty / nil input returns nil
  # (unconstrained), so callers can pass through the result of
  # collecting captured bindings without a guard.
  sig { params(sources: T.nilable(T::Array[SymbolEntry])).returns(T.nilable(Hash)) }
  def self.tied_lifetime(sources)
    return nil if sources.nil? || sources.empty?
    { sources: sources.uniq }
  end

  sig { params(reg: T.untyped, type: T.untyped, mutable: T.untyped, storage: Symbol, sync: T.nilable(Symbol), layout: T.nilable(Symbol), rebindable: T::Boolean, size: Integer, capabilities: T::Set[Symbol], valid: T::Boolean, invalid_reason: T.nilable(String), resource: T.nilable(T::Boolean), close_zig: T.nilable(String)).void }
  def initialize(reg:, type:, mutable:, storage:, sync: nil, layout: nil, rebindable: false,
                 size: 0, capabilities: Set.new,
                 valid: true, invalid_reason: nil, resource: nil, close_zig: nil)
    @reg = reg
    @type = type
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
    @lifetime = nil
  end
end
