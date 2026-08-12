# typed: strict
# Typed entry stored in a Scope binding table.
# Each entry tracks a variable/function binding with its type, storage, and metadata.
# Back-references its owning Scope via `scope` for state operations.
#
# Mutation contract (read before adding a post-annotation mutator):
#
# Most fields are scope-local (live, moved, borrowed_alias, valid, read,
# lifetime). Mutating them on a nested-scope copy is correct.
#
# Storage-axis fields (storage, sync, type, capabilities) are function-global.
# `Scope.dup` creates a parent-linked child scope and materializes branch-local
# copies only through `Scope#entry_for_write`. Any pass that mutates a
# storage-axis field on a parameter (e.g. `EscapeAnalysis.propagate_caller_sync!`)
# MUST mutate `param.symbol` (the function-level entry), and any consumer that
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
# `type=` calls `Type.new` unconditionally (a hard, non-lazy dependency).
# FunctionSignature is also a hard dependency of the typed SymbolEntry API.
# Load its implementation here so isolated tooling such as Mutant can evaluate
# these signatures without relying on a broader compiler require order.
require_relative "type"
require_relative "param"
require_relative "../annotator/helpers/function_signature"
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

  @next_binding_id = T.let(0, Integer)
  TypeInput = T.type_alias { T.nilable(T.any(Type::TypeInput, FunctionSignature)) }
  RegInput = T.type_alias { T.nilable(T.any(AST::Node, String, Symbol)) }
  LifetimeSourceInput = T.type_alias { T.any(SymbolEntry, Symbol) }
  LifetimeInput = T.type_alias { T.nilable(T.any(Symbol, T::Array[LifetimeSourceInput], T::Hash[Symbol, T::Array[LifetimeSourceInput]])) }

  class BindingFlowFacts < T::Struct
    prop :non_escaping, T::Boolean, default: false
    prop :borrowed_alias, T::Boolean, default: false
    prop :valid, T::Boolean, default: true
    prop :invalid_reason, T.nilable(String), default: nil
    prop :read, T::Boolean, default: false
    prop :mutated, T::Boolean, default: false
    prop :mutable_ref_target, T::Boolean, default: false
    prop :poly_borrow_target, T::Boolean, default: false
    prop :init_contents_heap, T::Boolean, default: false
  end

  class BindingLifecycleFacts < T::Struct
    prop :type, Type
    prop :storage, Symbol
    # Deterministic body-local identity assigned by annotation. Lifecycle and
    # ownership products use this instead of Ruby object identity so a clean,
    # incremental, or worker parse addresses the same source binding.
    prop :semantic_place_id, T.nilable(Integer), default: nil
    prop :sync, T.nilable(Symbol), default: nil
    prop :layout, T.nilable(Symbol), default: nil
    prop :resource, T.nilable(T::Boolean), default: nil
    prop :close_plan, T.nilable(Schemas::ResourceClosePlan), default: nil
    prop :ownership_kind, T.nilable(Symbol), default: nil
    prop :takes, T::Boolean, default: false
    prop :is_param, T::Boolean, default: false
    prop :link_source, T.nilable(Symbol), default: nil
    prop :async_result_shape, T.nilable(AsyncResultShape), default: nil
    # A mutable C ABI out parameter initialized this binding with an owned
    # resource handle. Unwrapping the optional transfers that ownership to the
    # resulting resource binding; ordinary optional unwraps remain borrows.
    prop :foreign_out_owner, T::Boolean, default: false
    # Successful payload of an owning optional/fallible expression. Zig's
    # value capture does not provide a writable source slot, so moving this
    # payload would leave the enclosing optional cleanup owning the same data.
    prop :owned_optional_capture, T::Boolean, default: false
    # Keep-analysis (retained identity v4): this param's value flows into an
    # identity destination, so its ABI is the family's handle and every call
    # edge consumes a CallEdgeOwnershipPlan derived from the caller's
    # declared model. nil = not kept.
    prop :kept_identity, T.nilable(KeptIdentityContract), default: nil
    # Retained-identity v5 parameter carrier contract: :polymorphic (default,
    # carrier-preserving), :unique (exclusively owned, enables COPY), :shared
    # (requires a retained-identity family). Written once at param binding.
    prop :carrier_contract, Symbol, default: :polymorphic
    # True when this binding's CARRIER is statically unknown -- an
    # unconstrained TAKES parameter, or a local directly aliasing one. COPY
    # (which needs independent identity) is rejected on such bindings; the
    # default :polymorphic contract on an ordinary local does NOT set this.
    prop :carrier_polymorphic, T::Boolean, default: false
  end

  sig { returns(RegInput) }
  attr_accessor :reg

  attr_accessor :mutable, :rebindable,
                :size, :capabilities,
                :scope,          # Back-reference to owning Scope (set by Scope#declare)
                :scope_depth,    # declaring scope depth (0 = root)
                :reassigned,     # direct binding assignment (not field/index mutation)
                :param_decl_token, # for is_param entries: the VAR_ID token at the
                                   # param's position in the function signature.
                                   # Used by build_declare_mutable_fix to point an
                                   # auto-fix at the parameter when the body
                                   # mutates it without `MUTABLE`.
                :sync_families   # Set of families when bound by REQUIRES disjunction

  sig { returns(BindingLifecycleFacts) }
  attr_reader :lifecycle

  sig { returns(T.nilable(AsyncResultShape)) }
  def async_result_shape = lifecycle.async_result_shape

  sig { params(value: T.nilable(AsyncResultShape)).void }
  def async_result_shape=(value)
    @lifecycle.async_result_shape = value
  end

  sig { returns(Type) }
  def type = lifecycle.type

  sig { returns(Symbol) }
  def storage = lifecycle.storage

  sig { params(value: Symbol).void }
  def storage=(value)
    @lifecycle.storage = value
  end

  sig { returns(T.nilable(Symbol)) }
  def sync = lifecycle.sync

  sig { params(value: T.nilable(Symbol)).void }
  def sync=(value)
    @lifecycle.sync = value
  end

  sig { returns(T.nilable(Symbol)) }
  def layout = lifecycle.layout

  sig { params(value: T.nilable(Symbol)).void }
  def layout=(value)
    @lifecycle.layout = value
  end

  sig { returns(T.nilable(T::Boolean)) }
  def resource = lifecycle.resource

  sig { params(value: T.nilable(T::Boolean)).void }
  def resource=(value)
    @lifecycle.resource = value
  end

  sig { returns(T.nilable(Schemas::ResourceClosePlan)) }
  def close_plan = lifecycle.close_plan

  sig { params(value: T.nilable(Schemas::ResourceClosePlan)).void }
  def close_plan=(value)
    @lifecycle.close_plan = value
  end

  sig { returns(T.nilable(Symbol)) }
  def ownership_kind = lifecycle.ownership_kind

  sig { params(value: T.nilable(Symbol)).void }
  def ownership_kind=(value)
    @lifecycle.ownership_kind = value
  end

  sig { returns(T::Boolean) }
  def takes = lifecycle.takes

  sig { params(value: T::Boolean).void }
  def takes=(value)
    @lifecycle.takes = value
  end

  sig { returns(T::Boolean) }
  def is_param = lifecycle.is_param

  sig { params(value: T::Boolean).void }
  def is_param=(value)
    @lifecycle.is_param = value
  end

  sig { returns(T.nilable(KeptIdentityContract)) }
  def kept_identity = lifecycle.kept_identity

  sig { params(value: T.nilable(KeptIdentityContract)).void }
  def kept_identity=(value)
    @lifecycle.kept_identity = value
  end

  sig { returns(Symbol) }
  def carrier_contract = lifecycle.carrier_contract

  sig { params(value: Symbol).void }
  def carrier_contract=(value)
    @lifecycle.carrier_contract = value
  end

  sig { returns(T::Boolean) }
  def carrier_polymorphic = lifecycle.carrier_polymorphic

  sig { params(value: T::Boolean).void }
  def carrier_polymorphic=(value)
    @lifecycle.carrier_polymorphic = value
  end

  sig { returns(T.nilable(Symbol)) }
  def link_source = lifecycle.link_source

  sig { params(value: T.nilable(Symbol)).void }
  def link_source=(value)
    @lifecycle.link_source = value
  end

  sig { returns(T::Boolean) }
  def foreign_out_owner = lifecycle.foreign_out_owner

  sig { params(value: T::Boolean).void }
  def foreign_out_owner=(value)
    @lifecycle.foreign_out_owner = value
  end

  sig { returns(T::Boolean) }
  def owned_optional_capture = lifecycle.owned_optional_capture

  sig { params(value: T::Boolean).void }
  def owned_optional_capture=(value)
    @lifecycle.owned_optional_capture = value
  end

  sig { returns(T.nilable(Integer)) }
  def semantic_place_id
    @lifecycle.semantic_place_id
  end

  sig { params(value: Integer).void }
  def adopt_semantic_place_id!(value)
    return unless @lifecycle.semantic_place_id.nil?

    @lifecycle.semantic_place_id = value
  end

  sig { returns(T::Boolean) }
  def non_escaping = flow_facts.non_escaping

  sig { returns(T::Boolean) }
  def borrowed_alias = flow_facts.borrowed_alias

  sig { returns(T::Boolean) }
  def valid = flow_facts.valid

  sig { returns(T.nilable(String)) }
  def invalid_reason = flow_facts.invalid_reason

  sig { returns(T::Boolean) }
  def read = flow_facts.read

  sig { returns(T::Boolean) }
  def mutated = flow_facts.mutated

  sig { returns(T::Boolean) }
  def mutable_ref_target = flow_facts.mutable_ref_target

  sig { returns(T::Boolean) }
  def poly_borrow_target = flow_facts.poly_borrow_target

  sig { returns(T::Boolean) }
  def init_contents_heap = flow_facts.init_contents_heap

  sig { returns(T::Array[SymbolEntry]) }
  attr_reader :lifetime

  sig { returns(Integer) }
  attr_reader :binding_id

  # The declaration identity used by cross-routine semantic facts. A capture
  # gets a fresh local SymbolEntry, but it still denotes the captured outer
  # binding. Keeping that relationship on the symbol prevents analyses from
  # reconstructing it by walking syntax or comparing names.
  sig { returns(Integer) }
  attr_reader :ownership_binding_id

  sig { params(source: SymbolEntry).void }
  def inherit_ownership_identity!(source)
    @ownership_binding_id = source.ownership_binding_id
  end

  sig { params(value: LifetimeInput).void }
  def lifetime=(value)
    @lifetime = normalize_lifetime(value)
    @flow.non_escaping = lifetime_self_only?
  end

  sig { returns(T::Boolean) }
  def lifetime_self_only?
    return false unless @lifetime.length == 1

    source = @lifetime.first
    return false unless source

    source.binding_id == @binding_id
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
    function_type = type.function_type
    return nil unless function_type

    signature = function_type.source_signature
    return nil unless signature

    T.cast(signature, FunctionSignature)
  end

  # Backward-compat alias for `lifetime == :current_scope`.
  # Pre-existing callers (capabilities.rb's WITH-alias declarations,
  # annotator visit_*, escape_analysis) read and write this; both paths
  # delegate to `lifetime` so there's a single source of truth.
  # Mirror of Type#atomic?. Was reinvented inline as `sym.sync == :atomic`
  # across the annotator seam (decomplex #1 Reification-Miss).
  sig { returns(T::Boolean) }
  def atomic?
    self.class.atomic_sync?(sync)
  end

  sig { params(sync: T.nilable(Symbol)).returns(T::Boolean) }
  def self.atomic_sync?(sync)
    sync_matches?(sync, :atomic)
  end

  # Mirror of Type#indirect? / Type#atomic_ptr?. The AtomicPtr pair
  # `sym.sync == :atomic && sym.layout == :indirect` was reinvented inline.
  sig { returns(T::Boolean) }
  def indirect?
    layout == :indirect
  end

  sig { returns(T::Boolean) }
  def atomic_ptr?
    atomic? && indirect?
  end

  # Mirror of Type#locked? / Type#local? -- `sym.sync == :locked` /
  # `sym.sync == :local` reinvented inline (decomplex Reification-Miss).
  sig { returns(T::Boolean) }
  def locked?
    self.class.locked_sync?(sync)
  end

  sig { returns(T::Boolean) }
  def local?
    self.class.local_sync?(sync)
  end

  sig { returns(T::Boolean) }
  def write_locked?
    self.class.write_locked_sync?(sync)
  end

  sig { returns(T::Boolean) }
  def declared_sync_contract?
    return true unless sync.nil?

    families = sync_families
    return false unless families.is_a?(Set)

    !T.must(families).empty?
  end

  private

  sig { returns(T::Boolean) }
  def lock_sync?
    locked? || write_locked?
  end

  public

  sig { returns(T::Boolean) }
  def sync_or_shared_storage?
    lock_sync? || rc_stored? || local_storage?
  end

  sig { returns(T::Boolean) }
  def boxed_capture_storage?
    lock_sync? || local_storage?
  end

  sig { returns(T::Boolean) }
  def affine_locked_capture?
    lock_sync? && !rc_stored?
  end

  sig { returns(T::Boolean) }
  def with_match_capability_family?
    !sync.nil? || rc_stored? || local_storage? || heap_storage?
  end

  sig { returns(T::Boolean) }
  def plain_local_family?
    sync.nil? && (storage == :stack || heap_storage?)
  end

  sig { params(live: T::Boolean).returns(T::Boolean) }
  def capture_move_required?(live)
    live && (ownership_kind == :resource || ownership_kind == :affine ||
      type.needs_escape_promotion?)
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
    self.class.rc_storage?(storage)
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
    return nil unless PROVENANCE_STORAGE.include?(storage)
    storage
  end

  # Provenance predicates — SIMP-13f. Symbol#storage is the canonical source.
  sig { returns(T::Boolean) }
  def heap_storage?
    self.class.heap_storage_value?(storage)
  end

  sig { returns(T::Boolean) }
  def frame_provenance?
    self.class.frame_storage_value?(storage)
  end

  sig { returns(T::Boolean) }
  def rodata_provenance?
    storage == :rodata
  end

  sig { returns(T::Boolean) }
  def borrow_provenance?
    storage == :borrow
  end

  private

  sig { returns(T::Boolean) }
  def local_storage?
    self.class.local_storage_value?(storage)
  end

  public

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

  sig { params(reason: String).void }
  def invalidate!(reason)
    @flow.valid = false
    @flow.invalid_reason = reason
  end

  sig { void }
  def mark_read!
    @flow.read = true
    reg = @reg
    if reg
      case reg
      when AST::VarDecl
        reg.var_used = true
      when AST::Assignment
        reg.var_used = true
      when AST::DestructureTarget
        reg.var_used = true
      when AST::DestructuringAssignment
        reg.var_used = true
      when AST::BindExpr
        reg.var_used = true
      end
    end
  end

  sig { params(touch_declaration: T::Boolean).void }
  def mark_mutated!(touch_declaration: false)
    @flow.mutated = true
    reg = @reg
    if touch_declaration && reg
      case reg
      when AST::VarDecl
        reg.var_mutated = true
      when AST::Assignment
        reg.var_mutated = true
      when AST::DestructureTarget
        reg.var_mutated = true
      when AST::DestructuringAssignment
        reg.var_mutated = true
      when AST::BindExpr
        reg.var_mutated = true
      end
    end
  end

  sig { void }
  def mark_mutated_via_reference!
    @flow.mutated = true
    @flow.mutable_ref_target = true
  end

  sig { void }
  def mark_poly_borrow_target!
    @flow.poly_borrow_target = true
  end

  sig { void }
  def mark_init_contents_heap!
    @flow.init_contents_heap = true
  end

  sig { void }
  def mark_non_escaping!
    self.lifetime = [self]
  end

  sig { void }
  def clear_non_escaping!
    return unless non_escaping
    self.lifetime = []
  end

  sig { void }
  def mark_borrowed_alias!
    @flow.borrowed_alias = true
  end

  sig { void }
  def mark_owned_optional_capture!
    @lifecycle.owned_optional_capture = true
  end

  sig { params(original: SymbolEntry).void }
  def initialize_copy(original)
    super
    @lifecycle = original.lifecycle
    @flow = original.flow_snapshot
    @lifetime = original.lifetime.dup
  end

  sig { returns(BindingFlowFacts) }
  def flow_facts
    @flow
  end
  protected :flow_facts

  sig { returns(BindingFlowFacts) }
  def flow_snapshot
    BindingFlowFacts.new(
      non_escaping: @flow.non_escaping,
      borrowed_alias: @flow.borrowed_alias,
      valid: @flow.valid,
      invalid_reason: @flow.invalid_reason,
      read: @flow.read,
      mutated: @flow.mutated,
      mutable_ref_target: @flow.mutable_ref_target,
      poly_borrow_target: @flow.poly_borrow_target,
      init_contents_heap: @flow.init_contents_heap
    )
  end
  protected :flow_snapshot

  sig { returns(T::Array[SymbolEntry]) }
  def lifetime_sources
    @lifetime
  end

  # Build a tied lifetime from source SymbolEntries. Empty input returns the
  # unconstrained lifetime.
  sig { params(sources: T::Array[SymbolEntry]).returns(T::Array[SymbolEntry]) }
  def self.tied_lifetime(sources)
    sources.uniq
  end

  sig { params(reg: RegInput, type: TypeInput, mutable: T::Boolean, storage: Symbol, sync: T.nilable(Symbol), layout: T.nilable(Symbol), rebindable: T::Boolean, size: Integer, capabilities: T::Set[Symbol], valid: T::Boolean, invalid_reason: T.nilable(String), resource: T.nilable(T::Boolean), close_plan: T.nilable(Schemas::ResourceClosePlan)).void }
  # ruby-to-clear: fallible
  def initialize(reg:, type:, mutable:, storage:, sync: nil, layout: nil, rebindable: false,
                 size: 0, capabilities: Set.new,
                 valid: true, invalid_reason: nil, resource: nil, close_plan: nil)
    @binding_id = T.let(self.class.next_binding_id, Integer)
    @ownership_binding_id = T.let(@binding_id, Integer)
    @reg = reg
    @lifecycle = T.let(
      BindingLifecycleFacts.new(
        type: self.class.normalize_type_input(type),
        storage: storage,
        sync: sync,
        layout: layout,
        resource: resource,
        close_plan: close_plan,
      ),
      BindingLifecycleFacts
    )
    @mutable = T.let(mutable, T::Boolean)
    @rebindable = T.let(rebindable, T::Boolean)
    @reassigned = T.let(false, T::Boolean)
    @size = T.let(size, Integer)
    @capabilities = T.let(capabilities, T::Set[Symbol])
    @lifetime = T.let([], T::Array[SymbolEntry])
    @flow = T.let(BindingFlowFacts.new(valid: valid, invalid_reason: invalid_reason), BindingFlowFacts)
    @sync_families = T.let(nil, T.nilable(T::Set[Symbol]))
    @scope = T.let(nil, T.nilable(Scope))
    @scope_depth = T.let(nil, T.nilable(Integer))
    @param_decl_token = T.let(nil, T.nilable(Lexer::Token))
  end

  # The laundering seam input is a real bounded union, not untyped:
  # a legacy Symbol tag, a String type name, a Type, a function
  # binding's FunctionSignature, or nil (unresolved). Normalized to a
  # single Type. The runtime sig now enforces the accepted domain --
  # anything outside it is a compiler bug, surfaced here.
  sig { params(val: TypeInput).void }
  # ruby-to-clear: fallible
  def type=(val)
    @lifecycle.type = self.class.normalize_type_input(val)
  end

  private

  sig { params(value: TypeInput).returns(Type) }
  # ruby-to-clear: fallible
  def self.normalize_type_input(value)
    return Type.new(:Untyped) if value.nil?
    return type_from_function_signature(value) if value.is_a?(FunctionSignature)

    Type.new(value)
  end

  sig { params(signature: FunctionSignature).returns(Type) }
  def self.type_from_function_signature(signature)
    param_types = signature.params.map(&:type)
    Type.function_type_from_parts(param_types, signature.return_type, signature.reentrant, signature,
      :clear, signature.params.map { |param| param.mutable == true })
  end

  sig { returns(Integer) }
  def self.next_binding_id
    id = @next_binding_id
    @next_binding_id += 1
    id
  end

  sig { params(value: LifetimeInput).returns(T::Array[SymbolEntry]) }
  def normalize_lifetime(value)
    if value.is_a?(Symbol)
      return [self] if value == :current_scope
    end

    sources = T.let([], T::Array[LifetimeSourceInput])
    if value.is_a?(Hash)
      sources = value[:sources] || []
    elsif value.is_a?(Array)
      sources = value
    elsif value
      sources = [value]
    end

    normalized = T.let([], T::Array[SymbolEntry])
    sources.each do |source|
      unless source.is_a?(SymbolEntry)
        raise TypeError, "SymbolEntry#lifetime sources must be SymbolEntry instances"
      end
      normalized << source
    end
    normalized.uniq
  end
end
