# typed: strict
# mir_checker.rb -- Post-lowering MIR verification.
#
# THE INVARIANTS THIS CHECKER ENFORCES (and nothing else):
#
#   INV-ALLOC-CLEANUP: Every MIR::AllocMark has at least one matching
#     MIR::Cleanup or MIR::ErrCleanup for the same binding name, and
#     the allocators match, unless a MIR::TransferMark records that
#     ownership left the current scope. (HPT_LEAK is the leak-without-alloc
#     case.)
#
#   INV-CLEANUP-ALLOC: Every MIR::Cleanup or MIR::ErrCleanup has a
#     matching MIR::AllocMark. A cleanup with no alloc is a compiler bug.
#
#   INV-ALLOCATOR-MATCH: The allocator in AllocMark (:heap/:frame) must
#     match the allocator in the cleanup_entry of the corresponding
#     Cleanup/ErrCleanup. Mismatch = freeing heap memory with the frame
#     allocator or vice versa -> runtime crash.
#
#   INV-HPT-LEAK: A heap-returning call result used in statement position
#     (not bound to a variable) is an unconditional leak.
#
#   INV-EXPLICIT-OWNERSHIP: Any stdlib-backed node that transfers
#     ownership must declare the concrete binding names in
  #     typed ownership operands. Registry metadata says the call shape
#     can consume; the contract says this lowered call does consume `x`.
#     Each consumed binding must have a matching MIR::TransferMark.
#
#   INV-ALLOC-METADATA-MATCH: When a structural registry/indexed operation uses an allocator
#     (:alloc/:key_alloc/:val_alloc), that allocator must match the
#     container binding's AllocMark allocator. Frame data stored in a
#     heap container becomes a dangling pointer after frame rewind.
#
#   INV-ALLOCATOR-CLOSED-SET: MIR allocator facts are closed to :heap
#     and :frame. Any other symbol means a downstream pass is carrying
#     placement side-channel state instead of finalized placement.
#
#   INV-ALLOC-MARK-TYPE: Every MIR::AllocMark must carry a concrete
#     Type payload. Allocation cleanup safety depends on the checker
#     knowing what owns heap memory; nil or :Untyped means lowering
#     emitted an unverifiable ownership fact.
#
#   INV-FRAME-REWIND: Every loop body that frame-allocates must contain
#     a restoreLoopMark defer to prevent unbounded frame arena growth.
#
#   INV-COPY-CLEANUP: A Cleanup paired with an AllocMark whose type_info is
#     a primitive or Id<T> (with no sync/rc capability) is a compiler bug:
#     value types that never own heap memory must not receive cleanup nodes.
#
#   INV-CLEANUP-REQUIRED-FINALIZER: Any AllocMark whose concrete Type says
#     the binding needs cleanup must have a Cleanup, ErrCleanup, TransferMark,
#     or other structural finalizer. This closes the gap where frame
#     allocations were considered arena-rewound even when the value itself
#     owns cleanup-bearing internals.
#
#   INV-CROSS-FRAME-PARAM-ALLOC: When an allocator-bearing structural op targets a parameter
#     that was pointer-passed into this function (MUTABLE collection param
#     or any param whose Zig type is `*T`), its resolved allocator must
#     NOT be `:frame`. Frame allocations are bounded by THIS function's
#     mark/restore; the parameter's lifetime extends past that mark, so
#     a frame alloc for it produces a buffer that dies before its owner.
#     Cross-frame UAF — caught here even if mir_lowering's allocator-
#     routing in `resolve_alloc_sym` regresses. Defense in depth on top
#     of escape_analysis.rb's Condition 9 promotion. See test 380.
#
# THE MOMENT this checker adds logic outside these invariants, it is no
# longer a gatekeeper -- it is ad-hoc patch code that gives false confidence.
# Every new check must be justified by one of these invariants.
#
# Structural encoding (no flag inspection):
#   MIR::Cleanup    -> always-defer cleanup (freed on both success and error)
#   MIR::ErrCleanup -> errdefer-only cleanup (freed only on error; success
#                      path transfers ownership to caller/container/callee)
#   MIR::TransferMark -> no local cleanup because ownership was moved out of
#                        this scope on every successful path. Must pair with
#                        a matching AllocMark.
#
# Which type is emitted is determined by the lowering pass, not the checker.
# The checker does NOT inspect flags or tags -- it reads the node type.
#
# Other ownership checks run pre-lowering:
#   UseAfterMoveChecker  -- use-after-move (Rule 1)
#   BorrowChecker        -- MOVE_WHILE_BORROWED, ALIAS_VIOLATION

require "sorbet-runtime"
require "set"

require_relative "../ast/type"
require_relative "../ast/diagnostic_registry"
require_relative "../semantic/pass_state"
require_relative "../semantic/ownership_identity"
require_relative "placement"

class MIRChecker
  extend T::Sig
  PlaceId = OwnershipIdentity::PlaceId

  AggregateExpr = T.type_alias {
    T.nilable(T.any(MIR::Emittable, String, Symbol, Integer, Float, T::Boolean))
  }

  OWNERSHIP_FIELD_NAMES = T.let(
    Set[:alloc, :allocs, :cleanup_entry, :ownership_contract, :owned_return, :owned_result_alloc, :callable_contract, :target_var],
    T::Set[Symbol],
  )

  LINEAR_STATEMENT_NODE_TYPES = T.let([
    MIR::AllocMark, MIR::AssertRaisesCheck, MIR::AssertStmt, MIR::BatchWindowFlush, MIR::BatchWindowPush,
    MIR::BgBlock, MIR::BreakStmt, MIR::CatchWrapper, MIR::Cleanup,
    MIR::Comment, MIR::ContinueStmt, MIR::DeferStmt, MIR::DestructureSet, MIR::DiscardOwned,
    MIR::DebugOnly, MIR::DoBlock, MIR::EnumDef, MIR::ErrCleanup, MIR::ErrDeferStmt,
    MIR::ExprStmt, MIR::FallibleLockBinding, MIR::FieldCleanupMark, MIR::FnDef, MIR::ForStmt,
    MIR::FrameRestore, MIR::FrameSave, MIR::FsmB1Body, MIR::FsmGenericBody,
    MIR::FsmIoBody, MIR::IfBindStmt, MIR::IfChain, MIR::IfStmt,
    MIR::Import, MIR::CExternFnDecl, MIR::CExternStructDef,
    MIR::IndexInsert, MIR::Let, MIR::ModuleNamespace, MIR::MoveMark,
    MIR::MutualThunkTrampoline, MIR::Noop, MIR::OwnedBorrow,
    MIR::OwnedCreate, MIR::OwnedDestroy, MIR::OwnedReturn,
    MIR::OwnedStore, MIR::OwnedTransfer, MIR::Panic, MIR::Pipeline,
    MIR::PolymorphicFlowSignal, MIR::PolymorphicMutate, MIR::PolymorphicMutateFlow, MIR::PubConst,
    MIR::ReassignMark, MIR::ReassignWithCleanup,
    MIR::ReturnMark, MIR::ReturnStmt, MIR::ScopeBlock, MIR::Set,
    MIR::ShardConcurrentEach, MIR::ShardedMapPut, MIR::SnapshotMultiTxn, MIR::SnapshotRead,
    MIR::SnapshotTransaction, MIR::Sort, MIR::SortedLockAcquire, MIR::StreamSpawn, MIR::StreamYield,
    MIR::StructDef, MIR::Suppress, MIR::SwitchStmt, MIR::TestDef,
    MIR::TestPreamble,
    MIR::ThunkTrampoline, MIR::TransferMark, MIR::TypeAlias,
    MIR::UnionMatchStmt, MIR::UnionTypeDef, MIR::WhileStmt, MIR::WithMatchDispatch,
  ].freeze, T::Array[T::Class[T.anything]])

  LINEAR_FRAME_ESCAPING_TRANSFER_TARGETS = T.let(
    Set[:return, :external_param, :capture, :field_store, :aggregate_store].freeze,
    T::Set[Symbol],
  )

  class LinearOwnershipState
    extend T::Sig

    sig { returns(T::Set[String]) }
    attr_reader :owned
    sig { returns(T::Set[String]) }
    attr_reader :released
    sig { returns(T::Set[String]) }
    attr_reader :maybe_released
    sig { returns(T::Set[String]) }
    attr_reader :cleanup_finalizers
    sig { returns(T::Set[String]) }
    attr_reader :guarded_finalizers
    sig { returns(T::Set[String]) }
    attr_reader :err_finalizers
    sig { returns(T::Set[String]) }
    attr_reader :pending_return_transfers
    sig { returns(T::Set[String]) }
    attr_reader :pending_block_transfers
    sig { returns(T::Hash[String, Symbol]) }
    attr_reader :alloc_kinds
    sig { returns(T::Hash[String, Symbol]) }
    attr_reader :alloc_scopes
    sig { returns(T::Set[String]) }
    attr_reader :move_marks
    sig { returns(T::Boolean) }
    attr_accessor :terminated

    sig { void }
    def initialize
      @owned = T.let(Set.new, T::Set[String])
      @released = T.let(Set.new, T::Set[String])
      @maybe_released = T.let(Set.new, T::Set[String])
      @cleanup_finalizers = T.let(Set.new, T::Set[String])
      @guarded_finalizers = T.let(Set.new, T::Set[String])
      @err_finalizers = T.let(Set.new, T::Set[String])
      @pending_return_transfers = T.let(Set.new, T::Set[String])
      @pending_block_transfers = T.let(Set.new, T::Set[String])
      @alloc_kinds = T.let({}, T::Hash[String, Symbol])
      @alloc_scopes = T.let({}, T::Hash[String, Symbol])
      @move_marks = T.let(Set.new, T::Set[String])
      @terminated = T.let(false, T::Boolean)
    end

    sig { returns(LinearOwnershipState) }
    def copy
      other = LinearOwnershipState.new
      other.owned.merge(@owned)
      other.released.merge(@released)
      other.maybe_released.merge(@maybe_released)
      other.cleanup_finalizers.merge(@cleanup_finalizers)
      other.guarded_finalizers.merge(@guarded_finalizers)
      other.err_finalizers.merge(@err_finalizers)
      other.pending_return_transfers.merge(@pending_return_transfers)
      other.pending_block_transfers.merge(@pending_block_transfers)
      other.alloc_kinds.merge!(@alloc_kinds)
      other.alloc_scopes.merge!(@alloc_scopes)
      other.move_marks.merge(@move_marks)
      other.terminated = @terminated
      other
    end

    sig { params(other: LinearOwnershipState).returns(T::Boolean) }
    def same_state?(other)
      snapshot.same_state?(other.snapshot)
    end

    sig { returns(String) }
    def summary
      snapshot.summary
    end

    sig { returns(LinearOwnershipSnapshot) }
    def snapshot
      LinearOwnershipSnapshot.from_state(self)
    end
  end

  class LinearOwnershipSnapshot
    extend T::Sig

    sig do
      params(
        owned: T::Set[MIRChecker::PlaceId],
        released: T::Set[MIRChecker::PlaceId],
        maybe_released: T::Set[MIRChecker::PlaceId],
        cleanup_finalizers: T::Set[MIRChecker::PlaceId],
        guarded_finalizers: T::Set[MIRChecker::PlaceId],
        err_finalizers: T::Set[MIRChecker::PlaceId],
        pending_return_transfers: T::Set[MIRChecker::PlaceId],
        pending_block_transfers: T::Set[MIRChecker::PlaceId],
        alloc_kinds: T::Hash[MIRChecker::PlaceId, Symbol]
      ).void
    end
    def initialize(
      owned:,
      released:,
      maybe_released:,
      cleanup_finalizers:,
      guarded_finalizers:,
      err_finalizers:,
      pending_return_transfers:,
      pending_block_transfers:,
      alloc_kinds:
    )
      @owned = T.let(owned.freeze, T::Set[MIRChecker::PlaceId])
      @released = T.let(released.freeze, T::Set[MIRChecker::PlaceId])
      @maybe_released = T.let(maybe_released.freeze, T::Set[MIRChecker::PlaceId])
      @cleanup_finalizers = T.let(cleanup_finalizers.freeze, T::Set[MIRChecker::PlaceId])
      @guarded_finalizers = T.let(guarded_finalizers.freeze, T::Set[MIRChecker::PlaceId])
      @err_finalizers = T.let(err_finalizers.freeze, T::Set[MIRChecker::PlaceId])
      @pending_return_transfers = T.let(pending_return_transfers.freeze, T::Set[MIRChecker::PlaceId])
      @pending_block_transfers = T.let(pending_block_transfers.freeze, T::Set[MIRChecker::PlaceId])
      @alloc_kinds = T.let(alloc_kinds.freeze, T::Hash[MIRChecker::PlaceId, Symbol])
    end

    sig { params(state: LinearOwnershipState).returns(LinearOwnershipSnapshot) }
    def self.from_state(state)
      new(
        owned: place_set(state.owned),
        released: place_set(state.released),
        maybe_released: place_set(state.maybe_released),
        cleanup_finalizers: place_set(state.cleanup_finalizers),
        guarded_finalizers: place_set(state.guarded_finalizers),
        err_finalizers: place_set(state.err_finalizers),
        pending_return_transfers: place_set(state.pending_return_transfers),
        pending_block_transfers: place_set(state.pending_block_transfers),
        alloc_kinds: place_hash(state.alloc_kinds),
      )
    end

    sig { returns(T::Set[PlaceId]) }
    def owned
      @owned
    end

    sig { returns(T::Hash[PlaceId, Symbol]) }
    def alloc_kinds
      @alloc_kinds
    end

    sig { params(other: LinearOwnershipSnapshot).returns(T::Boolean) }
    def same_state?(other)
      @owned == other.owned &&
        @released == other.released &&
        @maybe_released == other.maybe_released &&
        @cleanup_finalizers == other.cleanup_finalizers &&
        @guarded_finalizers == other.guarded_finalizers &&
        @err_finalizers == other.err_finalizers &&
        @pending_return_transfers == other.pending_return_transfers &&
        @pending_block_transfers == other.pending_block_transfers &&
        @alloc_kinds == other.alloc_kinds
    end

    sig { returns(String) }
    def summary
      [
        "owned=#{format_places(@owned)}",
        "released=#{format_places(@released)}",
        "maybe=#{format_places(@maybe_released)}",
        "cleanup=#{format_places(@cleanup_finalizers)}",
        "guarded=#{format_places(@guarded_finalizers)}",
        "err=#{format_places(@err_finalizers)}",
        "return=#{format_places(@pending_return_transfers)}",
        "block=#{format_places(@pending_block_transfers)}",
        "alloc=#{@alloc_kinds.map { |place, alloc| "#{place.path}:#{alloc}" }.sort.join(",")}",
      ].join(" ")
    end

    protected

    sig { returns(T::Set[PlaceId]) }
    attr_reader :released, :maybe_released, :cleanup_finalizers,
      :guarded_finalizers, :err_finalizers, :pending_return_transfers,
      :pending_block_transfers

    private

    sig { params(names: T::Set[String]).returns(T::Set[PlaceId]) }
    def self.place_set(names)
      out = T.let(Set.new, T::Set[PlaceId])
      names.each { |name| out.add(PlaceId.from_path(name)) }
      out
    end

    sig { params(allocs: T::Hash[String, Symbol]).returns(T::Hash[PlaceId, Symbol]) }
    def self.place_hash(allocs)
      out = T.let({}, T::Hash[PlaceId, Symbol])
      allocs.each { |name, alloc| out[PlaceId.from_path(name)] = alloc }
      out
    end

    sig { params(places: T::Set[PlaceId]).returns(String) }
    def format_places(places)
      places.map(&:path).sort.join(",")
    end
  end

  attr_reader :errors

  AllocMarksByName = T.type_alias { T::Hash[String, T::Array[MIR::AllocMark]] }
  CleanupMarksByName = T.type_alias { T::Hash[String, T::Array[T.any(MIR::Cleanup, MIR::ErrCleanup)]] }
  NameSet = T.type_alias { T::Set[String] }
  AllocatorMetadataCarrier = T.type_alias { T.any(MIR::RegistryCall, MIR::IndexedStore, MIR::ShardedMapPut, MIR::ShardedMapGet) }
  AllocatorMetadataSource = T.type_alias { T.any(MIR::Node, MIR::CallableContract) }
  RegistryOwnershipNode = T.type_alias { T.any(MIR::RegistryCall, MIR::IndexedStore) }
  OwnershipSurfaceNode = T.type_alias { T.any(MIR::RegistryCall, MIR::IndexedStore, MIR::ShardedMapPut, MIR::ReassignWithCleanup) }

  class InlineStoredAllocCheck < T::Struct
    extend T::Sig

    const :label, Symbol
    const :alloc, T.nilable(Symbol)
  end

  sig { params(fn_name: T.nilable(String), schema_lookup: T.nilable(Type::SchemaLookup)).void }
  def initialize(fn_name: nil, schema_lookup: nil)
    @fn_name = fn_name
    @schema_lookup = T.let(schema_lookup, T.nilable(Type::SchemaLookup))
    @errors = T.let([], T::Array[String])
  end

  # `strict` is retained for call-site compatibility only. MIR ownership
  # checks are always strict: an unhoisted allocation or provenance placement
  # side channel is a compiler bug, not an optional lint.
  sig { params(fn_def: MIR::FnDef, strict: T::Boolean).returns(T::Array[String]) }
  def check_fn!(fn_def, strict: false)
    @fn_name = fn_def.name
    @errors = []
    nodes = T.let(MIR.nodes(fn_def.body), T::Array[MIR::Node])

    allocs = T.let({}, AllocMarksByName)
    cleanups = T.let({}, CleanupMarksByName)
    err_cleanups = T.let({}, CleanupMarksByName)
    transfers = T.let(Set.new, NameSet)
    return_transfers = T.let(Set.new, NameSet)
    errdefer_destroy_names = T.let(Set.new, NameSet)
    hpt_leaks = T.let([], T::Array[String])
    owned_return_lets = T.let([], T::Array[MIR::Let])
    owned_result_lets = T.let([], T::Array[MIR::Let])
    allocator_metadata_nodes = T.let([], T::Array[MIR::Node])
    allocator_metadata_node_ids = T.let({}, T::Hash[Integer, T::Boolean])
    structural_ownership_nodes = T.let([], T::Array[MIR::Node])
    ownership_fact_nodes = T.let([], T::Array[MIR::Node])

    nodes.each do |node|
      if node.respond_to?(:ownership_consumption) &&
         node.ownership_consumption.is_a?(MIR::OwnershipConsumptionFact)
        structural_ownership_nodes << node
      end
      if allocator_metadata_node?(node) && !allocator_metadata_node_ids.key?(node.object_id)
        allocator_metadata_nodes << node
        allocator_metadata_node_ids[node.object_id] = true
      end

      case node
      when MIR::OwnedCreate, MIR::OwnedDestroy, MIR::OwnedTransfer, MIR::OwnedBorrow, MIR::OwnedStore, MIR::OwnedReturn
        ownership_fact_nodes << node
        if node.is_a?(MIR::OwnedTransfer)
          transfers << node.name.to_s
          return_transfers << node.name.to_s if node.target == :return
        end
      when MIR::AllocMark
        (allocs[node.name] ||= []) << node
      when MIR::Cleanup, MIR::ErrCleanup
        (cleanups[node.name] ||= []) << node
        (err_cleanups[node.name] ||= []) << node if node.is_a?(MIR::ErrCleanup)
      when MIR::TransferMark
        name = node.name.to_s
        transfers << name
        return_transfers << name if node.target == :return
      when MIR::ErrDeferStmt
        # @boxed field temps use ErrDeferStmt(DestroyPtr) instead of ErrCleanup.
        # Track their names so ALLOC_WITHOUT_CLEANUP does not false-positive on them.
        body = node.body
        ptr = body.ptr if body.is_a?(MIR::DestroyPtr)
        if ptr.is_a?(MIR::Ident)
          errdefer_destroy_names << ptr.name
        end
      when MIR::Let
        owned_return_lets << node if owned_return_init?(node.init)
        owned_result_lets << node if expr_owned_result_alloc(node.init)
      when MIR::ExprStmt
        scan_expr_for_hpt_leak!(node.expr, hpt_leaks)
      when MIR::LambdaExpr
        if node.fn_def
          sub = MIRChecker.new(schema_lookup: @schema_lookup)
          @errors.concat(sub.check_fn!(node.fn_def, strict: strict))
        end
      end
    end

    hpt_leaks.each { |e| @errors << e }
    verify_allocator_closed_set!(allocs, cleanups, allocator_metadata_nodes)
    verify_alloc_marks_typed!(allocs)
    verify_owned_return_alloc_marks!(owned_return_lets, allocs)
    verify_owned_result_alloc_marks!(owned_result_lets, allocs)
    verify_allocator_metadata_contracts!(allocator_metadata_nodes, allocs, fn_def)
    verify_cross_frame_param_alloc!(allocator_metadata_nodes, fn_def)
    verify_err_cleanup_transfers!(err_cleanups, transfers)
    verify_return_transfers_heap!(return_transfers, allocs)
    verify_cleanup_sources_own_values!(fn_def.body || [], cleanups, err_cleanups)
    verify_if_bind_capture_cleanup_ownership!(nodes)
    verify_no_structural_rc_handle_copies!(nodes)
    verify_allocating_lets_marked!(nodes, allocs)
    verify_aggregate_owned_children!(fn_def.body, allocs)
    verify_alloc_cleanup_match!(allocs, cleanups, errdefer_destroy_names, transfers)
    verify_cleanup_required_finalizers!(allocs, cleanups, errdefer_destroy_names, transfers)
    verify_ownership_consumption_operands!(structural_ownership_nodes)
    verify_call_contracts!(nodes, transfers, allocs)
    verify_structural_ownership_contracts!(structural_ownership_nodes, transfers, allocs)
    verify_explicit_ownership_contracts!(nodes, transfers, allocs)
    verify_ownership_surfaces_finalized!(nodes, ownership_fact_nodes)
    verify_execution_boundary_facts!(nodes)
    verify_frame_rewind!(fn_def.body || [])
    verify_allocator_metadata_targets!(allocator_metadata_nodes)
    verify_unhoisted_allocs!(fn_def.body)
    verify_heap_create_single_indirection!(nodes)
    verify_move_mark_scope!(fn_def.body)
    verify_linear_ownership!(fn_def.body)

    @errors
  end

  sig { params(return_transfers: NameSet, allocs: AllocMarksByName).void }
  def verify_return_transfers_heap!(return_transfers, allocs)
    return_transfers.each do |name|
      marks = allocs[name]
      unless marks && !marks.empty?
        @errors << error(:RETURN_TRANSFER_WITHOUT_ALLOC, name,
          "return ownership transfer has no MIR::AllocMark")
        next
      end
      next if marks.all? { |mark| MIR::Placement.heap?(mark.alloc) }

      @errors << error(:RETURN_TRANSFER_FRAME_ALLOC, name,
        "return ownership transfer is backed by :frame allocation; escaping owned returns must be heap")
    end
  end

  sig { params(allocs: AllocMarksByName).void }
  def verify_alloc_marks_typed!(allocs)
    allocs.each do |name, marks|
      marks.each do |mark|
        next unless mark.type_info.untyped?

        @errors << error(:ALLOC_MARK_TYPE_MISSING, name,
          "MIR::AllocMark must carry a concrete Type so MIRChecker can prove cleanup/ownership safety")
      end
    end
  end

  sig { params(nodes: T::Array[MIR::Node], transfers: NameSet, allocs: AllocMarksByName).void }
  def verify_structural_ownership_contracts!(nodes, transfers, allocs)
    nodes.uniq.each do |node|
      consumed = structural_consumed_names(node)
      next if consumed.empty?

      sink_alloc = if node.is_a?(MIR::ReassignWithCleanup)
        node.alloc
      elsif node.respond_to?(:resolved_allocs) && T.unsafe(node).resolved_allocs.is_a?(MIR::InlineAllocMetadata)
        T.unsafe(node).resolved_allocs.value_alloc
      end

      consumed.each do |name|
        next unless allocs.key?(name)

        unless transfers.include?(name)
          @errors << error(:OWNERSHIP_CONTRACT_WITHOUT_TRANSFER, name,
            "structural ownership sink consumes '#{name}' but no MIR::TransferMark exists for that binding")
        end

        mark = allocs[name]&.first
        next unless mark && sink_alloc
        next if mark.alloc == sink_alloc

        @errors << error(:AGGREGATE_CHILD_ALLOC_MISMATCH, name,
          "structural ownership sink consumes :#{mark.alloc} binding '#{name}' into :#{sink_alloc} sink; " \
          "owned transfer allocator is incoherent")
      end
    end
  end

  sig { params(nodes: T::Array[MIR::Node]).void }
  def verify_ownership_consumption_operands!(nodes)
    nodes.uniq.each do |node|
      fact = node.respond_to?(:ownership_consumption) ? node.ownership_consumption : nil
      unless fact.is_a?(MIR::OwnershipConsumptionFact)
        @errors << error(:OWNERSHIP_CONSUMPTION_FACT_MISSING, ownership_node_name(node),
          "ownership-consuming MIR node has no MIR::OwnershipConsumptionFact")
        next
      end
      if fact.operands.empty?
        @errors << error(:OWNERSHIP_CONSUMPTION_OPERAND_MISSING, ownership_node_name(node),
          "ownership-consuming MIR node has no operand provenance")
        next
      end
      fact.operands.each do |operand|
        next if operand.kind == :non_owning
        next unless operand.borrowed

        @errors << error(:OWNERSHIP_CONSUMPTION_BORROWED_OPERAND, operand.name || fact.source,
          "ownership-consuming MIR node tries to consume borrowed operand from #{operand.source}")
      end
    end
    nil
  end

  sig { params(node: MIR::Node).returns(T::Array[String]) }
  def structural_consumed_names(node)
    fact = node.respond_to?(:ownership_consumption) ? node.ownership_consumption : nil
    return ownership_consumption_operand_names(fact) if fact.is_a?(MIR::OwnershipConsumptionFact)
    return [] unless stdlib_takes_ownership?(node)

    value = node.respond_to?(:value) ? T.unsafe(node).value : nil
    return [value.name.to_s] if value.is_a?(MIR::Ident)
    if allocating_expr?(value)
      @errors << error(:IMPLICIT_OWNERSHIP_TRANSFER, ownership_node_name(node),
        "structural ownership sink takes a value, but the source owner is not a named MIR binding")
    end
    []
  end

  sig { params(fact: MIR::OwnershipConsumptionFact).returns(T::Array[String]) }
  def ownership_consumption_operand_names(fact)
    fact.operands.filter_map(&:name).map(&:to_s).reject(&:empty?).uniq
  end

  sig { params(body: T::Array[MIR::Node]).void }
  def verify_linear_ownership!(body)
    final_state = check_linear_stmts!(body, LinearOwnershipState.new)
    final_state.pending_return_transfers.each do |name|
      @errors << error(:OWNERSHIP_UNVERIFIED_PATH, name,
        "TransferMark(:return) was emitted but no ReturnStmt consumed that ownership transfer")
    end
    nil
  end

  sig { params(stmts: T::Array[MIR::Node], state: LinearOwnershipState).returns(LinearOwnershipState) }
  def check_linear_stmts!(stmts, state)
    stmts.each do |stmt|
      break if state.terminated
      check_linear_stmt!(stmt, state)
    end
    state
  end

  sig { params(stmt: T.nilable(MIR::Node), state: LinearOwnershipState).void }
  def check_linear_stmt!(stmt, state)
    return unless stmt
    unless stmt.is_a?(MIR::Stmt)
      check_linear_expr_uses!(stmt, state) if stmt.is_a?(MIR::Emittable)
      return
    end
    unless LINEAR_STATEMENT_NODE_TYPES.include?(stmt.class)
      @errors << error(:LINEAR_STMT_NOT_REGISTERED, stmt.class.name.to_s,
        "MIR statement is not registered with MIRChecker linear ownership traversal")
      return
    end

    case stmt
    when MIR::AllocMark
      linear_alloc!(stmt, state)
    when MIR::Cleanup
      linear_register_cleanup!(stmt.name.to_s, stmt.cleanup_entry.has_moved_guard?, state)
    when MIR::ErrCleanup
      linear_register_err_cleanup!(stmt.name.to_s, state)
    when MIR::TransferMark
      linear_transfer!(stmt.name.to_s, stmt.target, stmt.target_alloc, state)
    when MIR::MoveMark
      linear_move_mark!(stmt.name.to_s, state)
    when MIR::OwnedCreate, MIR::OwnedBorrow, MIR::OwnedStore,
         MIR::OwnedTransfer, MIR::OwnedReturn, MIR::OwnedDestroy,
         MIR::ReassignMark, MIR::FieldCleanupMark, MIR::ReturnMark
      # Legacy and fact nodes are validated by the ownership-fact passes.
      nil
    when MIR::Panic
      state.terminated = true
    when MIR::ReturnStmt
      return_reads = state.pending_return_transfers.dup
      linear_expr_consumed_names(stmt.value).each { |name| return_reads.add(name) }
      check_linear_expr_uses!(stmt.value, state, return_reads)
      returned_names = linear_expr_ident_names(stmt.value)
      verify_guarded_transfers_moved!(state.pending_return_transfers, state, :return)
      state.pending_return_transfers.each { |name| linear_release!(name, :return, nil, state) }
      state.pending_return_transfers.each do |name|
        next if returned_names.include?(name)
        @errors << error(:OWNERSHIP_UNVERIFIED_PATH, name,
          "TransferMark(:return) does not match the returned expression")
      end
      state.pending_return_transfers.clear
      state.terminated = true
    when MIR::BreakStmt
      block_reads = state.pending_block_transfers.dup
      linear_expr_consumed_names(stmt.value).each { |name| block_reads.add(name) }
      check_linear_expr_uses!(stmt.value, state, block_reads)
      break_names = linear_expr_ident_names(stmt.value)
      verify_guarded_transfers_moved!(state.pending_block_transfers, state, :block_result)
      state.pending_block_transfers.each { |name| linear_release!(name, :block_result, nil, state) }
      state.pending_block_transfers.each do |name|
        next if break_names.include?(name)
        @errors << error(:OWNERSHIP_UNVERIFIED_PATH, name,
          "TransferMark(:block_result) does not match the block break expression")
      end
      state.pending_block_transfers.clear
    else
      manual_traversal = stmt.is_a?(MIR::DeferStmt) || stmt.is_a?(MIR::ErrDeferStmt) ||
        stmt.is_a?(MIR::StructDef) ||
        stmt.is_a?(MIR::FsmB1Body) || stmt.is_a?(MIR::FsmGenericBody) || stmt.is_a?(MIR::FsmIoBody)
      if stmt.body_slots.empty? && !manual_traversal
        check_linear_expr_uses!(stmt, state)
        return
      end
    end

    case stmt
    when MIR::IfStmt
      check_linear_expr_uses!(stmt.cond, state)
      check_linear_branch_join!(stmt.then_body, stmt.else_body || [], state, "if")
    when MIR::IfBindStmt
      stmt.bindings&.each do |binding|
        expr = binding.is_a?(Hash) ? binding[:expr] : nil
        check_linear_expr_uses!(expr, state)
      end
      check_linear_branch_join!(stmt.then_body, stmt.else_body || [], state, "if-bind")
    when MIR::WhileStmt
      check_linear_expr_uses!(stmt.cond, state)
      body_state = check_linear_stmts!(stmt.body, state.copy)
      projected = state.copy
      linear_exit_scope!(projected, body_state, "while")
      linear_require_same_state!(state, projected, "while")
    when MIR::ForStmt
      check_linear_expr_uses!(stmt.iter, state)
      body_state = check_linear_stmts!(stmt.body, state.copy)
      projected = state.copy
      linear_exit_scope!(projected, body_state, "for")
      linear_require_same_state!(state, projected, "for")
    when MIR::ScopeBlock, MIR::BlockExpr
      inner = check_linear_stmts!(stmt.body, state.copy)
      linear_exit_scope!(state, inner, "scope")
    when MIR::DebugOnly
      check_linear_stmts!(stmt.body, state.copy)
    when MIR::SwitchStmt, MIR::UnionMatchStmt
      check_linear_expr_uses!(stmt.subject, state)
      states = T.let([], T::Array[LinearOwnershipState])
      stmt.arms&.each { |arm| states << linear_project_branch_state(check_linear_stmts!(arm.body, state.copy), state, "match") }
      states << linear_project_branch_state(check_linear_stmts!(stmt.default_body || [], state.copy), state, "match")
      linear_merge_branch_states!(states, state, "match")
    when MIR::IfChain
      states = T.let([], T::Array[LinearOwnershipState])
      stmt.branches&.each do |branch|
        check_linear_expr_uses!(branch.cond, state)
        states << linear_project_branch_state(check_linear_stmts!(branch.body, state.copy), state, "if-chain")
      end
      states << linear_project_branch_state(check_linear_stmts!(stmt.default_body || [], state.copy), state, "if-chain")
      linear_merge_branch_states!(states, state, "if-chain")
    when MIR::DeferStmt, MIR::ErrDeferStmt
      body = stmt.body
      if body.is_a?(Array)
        check_linear_stmts!(body, state)
      else
        check_linear_stmt!(body, state)
      end
    when MIR::StreamSpawn, MIR::FnDef, MIR::TestDef
      check_linear_stmts!(stmt.body, LinearOwnershipState.new)
    when MIR::SnapshotRead, MIR::SnapshotTransaction, MIR::SnapshotMultiTxn
      inner = check_linear_stmts!(stmt.body, state.copy)
      linear_exit_scope!(state, inner, stmt.class.name.to_s)
    when MIR::PolymorphicMutate
      inner = check_linear_stmts!(stmt.body, state.copy)
      linear_exit_scope!(state, inner, "polymorphic-mutate")
    when MIR::PolymorphicMutateFlow
      check_linear_expr_uses!(stmt.guard_cond, state)
      states = T.let([], T::Array[LinearOwnershipState])
      states << linear_project_branch_state(check_linear_stmts!(stmt.body, state.copy), state, "polymorphic-mutate-flow")
      states << linear_project_branch_state(check_linear_stmts!(stmt.guard_fail_body || [], state.copy), state, "polymorphic-mutate-flow")
      linear_merge_branch_states!(states, state, "polymorphic-mutate-flow")
    when MIR::WithMatchDispatch
      states = T.let([], T::Array[LinearOwnershipState])
      stmt.arms&.each { |arm| states << linear_project_branch_state(check_linear_stmts!(arm.body, state.copy), state, "with-match") }
      linear_merge_branch_states!(states, state, "with-match")
    when MIR::BgBlock
      check_linear_stmts!(stmt.run_body, LinearOwnershipState.new)
    when MIR::DoBlock
      stmt.branch_bodies&.each { |body| check_linear_stmts!(body, LinearOwnershipState.new) }
    when MIR::CatchWrapper
      stmt.clause_bodies&.each { |body| check_linear_stmts!(body, state.copy) }
    when MIR::StructDef
      stmt.methods&.each { |method| check_linear_stmt!(method, LinearOwnershipState.new) if method.is_a?(MIR::FnDef) }
    when MIR::FsmB1Body
      body_stmts = stmt.ctx_struct.run_body.body_stmts.filter_map do |body_stmt|
        body_stmt if body_stmt.is_a?(MIR::Emittable)
      end
      check_linear_stmts!(body_stmts, LinearOwnershipState.new)
    when MIR::FsmGenericBody, MIR::FsmIoBody
      nil
    when MIR::Comment, MIR::ContinueStmt, MIR::EnumDef, MIR::FrameRestore,
         MIR::FrameSave, MIR::Import, MIR::CExternFnDecl, MIR::CExternStructDef,
         MIR::MutualThunkTrampoline, MIR::Noop,
         MIR::PubConst, MIR::Suppress, MIR::ThunkTrampoline, MIR::TypeAlias,
         MIR::TestPreamble, MIR::UnionTypeDef
      nil
    end
    nil
  end

  sig { params(mark: MIR::AllocMark, state: LinearOwnershipState).void }
  def linear_alloc!(mark, state)
    name = mark.name.to_s
    if state.owned.include?(name) && !state.released.include?(name)
      @errors << error(:OWNERSHIP_UNVERIFIED_PATH, name,
        "AllocMark appears while prior ownership for the same binding is still active")
    end
    state.owned.add(name)
    state.alloc_kinds[name] = mark.alloc
    state.alloc_scopes[name] = mark.scope if mark.scope.is_a?(Symbol)
    state.released.delete(name)
    state.maybe_released.delete(name)
    state.cleanup_finalizers.delete(name)
    state.guarded_finalizers.delete(name)
    state.err_finalizers.delete(name)
    state.pending_return_transfers.delete(name)
    state.pending_block_transfers.delete(name)
    nil
  end

  sig { params(name: String, guarded: T::Boolean, state: LinearOwnershipState).void }
  def linear_register_cleanup!(name, guarded, state)
    linear_register_finalizer!(name, "Cleanup", state.cleanup_finalizers, state)
    state.guarded_finalizers.add(name) if guarded
    nil
  end

  sig { params(name: String, state: LinearOwnershipState).void }
  def linear_register_err_cleanup!(name, state)
    linear_register_finalizer!(name, "ErrCleanup", state.err_finalizers, state)
    nil
  end

  sig { params(name: String, kind: String, finalizers: T::Set[String], state: LinearOwnershipState).void }
  def linear_register_finalizer!(name, kind, finalizers, state)
    if state.released.include?(name)
      @errors << error(:OWNERSHIP_DOUBLE_RELEASE, name,
        "#{kind} registered after ownership for this binding was already transferred")
    end
    if state.cleanup_finalizers.include?(name) || state.err_finalizers.include?(name)
      @errors << error(:OWNERSHIP_DOUBLE_FINALIZER, name,
        "multiple cleanup strategies registered for one owned binding")
    end
    finalizers.add(name)
    nil
  end

  sig { params(name: String, target: Symbol, target_alloc: T.nilable(Symbol), state: LinearOwnershipState).void }
  def linear_transfer!(name, target, target_alloc, state)
    if target == :return
      state.pending_return_transfers.add(name)
      return
    end
    if target == :block_result
      state.pending_block_transfers.add(name)
      return
    end
    if state.cleanup_finalizers.include?(name) && !state.guarded_finalizers.include?(name)
      @errors << error(:OWNERSHIP_DOUBLE_RELEASE, name,
        "TransferMark and unguarded Cleanup both own the success-path release")
    end
    linear_release!(name, target, target_alloc, state)
    nil
  end

  sig { params(name: String, state: LinearOwnershipState).void }
  def linear_move_mark!(name, state)
    return if state.released.include?(name) ||
              state.pending_return_transfers.include?(name) ||
              state.pending_block_transfers.include?(name)

    @errors << error(:OWNERSHIP_IMPLICIT_MOVE, name,
      "MoveMark suppresses cleanup but no matching TransferMark was seen first")
    nil
  ensure
    state.move_marks.add(name)
  end

  sig { params(names: T::Set[String], state: LinearOwnershipState, target: Symbol).void }
  def verify_guarded_transfers_moved!(names, state, target)
    names.each do |name|
      next unless state.guarded_finalizers.include?(name)
      next if state.move_marks.include?(name)

      @errors << error(:OWNERSHIP_IMPLICIT_MOVE, name,
        "TransferMark(:#{target}) moves a guarded cleanup binding without MIR::MoveMark")
    end
    nil
  end

  sig { params(name: String, target: Symbol, target_alloc: T.nilable(Symbol), state: LinearOwnershipState).void }
  def linear_release!(name, target, target_alloc, state)
    unless state.owned.include?(name)
      @errors << error(:TRANSFER_WITHOUT_ALLOC, name,
        "ownership release to #{target.inspect} has no active AllocMark")
      return
    end
    if target == :owned_sink && target_alloc.nil?
      @errors << error(:IMPLICIT_OWNERSHIP_TRANSFER, name,
        "TransferMark(:owned_sink) must carry target_alloc so MIRChecker can prove whether ownership escapes")
    end
    if state.alloc_kinds[name] == :frame && escaping_transfer_target?(target, target_alloc)
      @errors << error(:FRAME_ALLOC_ESCAPES, name,
        "frame-allocated ownership is transferred to #{target.inspect}; escaping owned values must be heap")
    end
    if state.released.include?(name)
      @errors << error(:OWNERSHIP_DOUBLE_RELEASE, name,
        "binding ownership is released more than once")
      return
    end
    state.released.add(name)
    state.maybe_released.delete(name)
    nil
  end

  sig { params(target: Symbol, target_alloc: T.nilable(Symbol)).returns(T::Boolean) }
  def escaping_transfer_target?(target, target_alloc)
    return MIR::Placement.explicit_heap?(target_alloc) if target == :owned_sink

    LINEAR_FRAME_ESCAPING_TRANSFER_TARGETS.include?(target)
  end

  sig { params(then_body: T::Array[MIR::Node], else_body: T::Array[MIR::Node], state: LinearOwnershipState, label: String).void }
  def check_linear_branch_join!(then_body, else_body, state, label)
    then_state = check_linear_stmts!(then_body, state.copy)
    else_state = check_linear_stmts!(else_body, state.copy)
    projected_then = linear_project_branch_state(then_state, state, label)
    projected_else = linear_project_branch_state(else_state, state, label)
    linear_merge_branch_states!([projected_then, projected_else], state, label)
    nil
  end

  sig { params(branch_state: LinearOwnershipState, outer_state: LinearOwnershipState, label: String).returns(LinearOwnershipState) }
  def linear_project_branch_state(branch_state, outer_state, label)
    projected = branch_state.copy
    prune_scope_locals!(outer_state, projected, label)
    projected
  end

  sig { params(states: T::Array[LinearOwnershipState], into: LinearOwnershipState, label: String).void }
  def linear_merge_branch_states!(states, into, label)
    return if states.empty?
    live_states = states.reject(&:terminated)
    if live_states.empty?
      into.terminated = true
      return
    end
    first = T.must(live_states.first)
    normalize_guarded_conditional_releases!(live_states)
    live_states.drop(1).each do |state|
      next if state.same_state?(first)
      @errors << error(:OWNERSHIP_UNVERIFIED_PATH, label,
        "control-flow branches rejoin with different ownership state: " \
        "#{first.summary} vs #{state.summary}")
    end
    copy_linear_state!(first, into)
    nil
  end

  sig { params(states: T::Array[LinearOwnershipState]).void }
  def normalize_guarded_conditional_releases!(states)
    return if states.empty?
    names = T.let(Set.new, T::Set[String])
    states.each { |state| names.merge(state.released) }
    states.each { |state| names.merge(state.maybe_released) }
    names.each do |name|
      released_count = states.count { |state| state.released.include?(name) || state.maybe_released.include?(name) }
      next if released_count == 0 || released_count == states.length
      next unless states.all? { |state| state.guarded_finalizers.include?(name) }

      states.each do |state|
        state.released.delete(name)
        state.maybe_released.add(name)
      end
    end
    nil
  end

  sig { params(expected: LinearOwnershipState, actual: LinearOwnershipState, label: String).void }
  def linear_require_same_state!(expected, actual, label)
    return if expected.same_state?(actual)

    @errors << error(:OWNERSHIP_UNVERIFIED_PATH, label,
      "nested control flow changes ownership state in a way MIRChecker cannot prove: " \
      "#{expected.summary} vs #{actual.summary}")
    nil
  end

  sig { params(outer: LinearOwnershipState, inner: LinearOwnershipState, label: String).void }
  def linear_exit_scope!(outer, inner, label)
    projected = inner.copy
    prune_scope_locals!(outer, projected, label)
    copy_linear_state!(projected, outer)
    nil
  end

  sig { params(outer: LinearOwnershipState, projected: LinearOwnershipState, label: String).void }
  def prune_scope_locals!(outer, projected, label)
    local_names = projected.owned - outer.owned
    local_names.each do |name|
      unless projected.released.include?(name) ||
             projected.cleanup_finalizers.include?(name) ||
             projected.err_finalizers.include?(name) ||
             projected.alloc_kinds[name] == :frame
        @errors << error(:OWNERSHIP_UNVERIFIED_PATH, label,
          "scope-local owned binding '#{name}' exits without cleanup or transfer")
      end
      projected.owned.delete(name)
      projected.released.delete(name)
      projected.cleanup_finalizers.delete(name)
      projected.guarded_finalizers.delete(name)
      projected.err_finalizers.delete(name)
      projected.pending_return_transfers.delete(name)
      projected.pending_block_transfers.delete(name)
      projected.maybe_released.delete(name)
      projected.alloc_kinds.delete(name)
      projected.alloc_scopes.delete(name)
    end
    nil
  end

  sig { params(source: LinearOwnershipState, target: LinearOwnershipState).void }
  def copy_linear_state!(source, target)
    target.owned.replace(source.owned)
    target.released.replace(source.released)
    target.maybe_released.replace(source.maybe_released)
    target.cleanup_finalizers.replace(source.cleanup_finalizers)
    target.guarded_finalizers.replace(source.guarded_finalizers)
    target.err_finalizers.replace(source.err_finalizers)
    target.pending_return_transfers.replace(source.pending_return_transfers)
    target.pending_block_transfers.replace(source.pending_block_transfers)
    target.alloc_kinds.replace(source.alloc_kinds)
    target.alloc_scopes.replace(source.alloc_scopes)
    target.terminated = source.terminated
    nil
  end

  sig { params(expr: T.nilable(MIR::Node), state: LinearOwnershipState, transfer_reads: T::Set[String]).void }
  def check_linear_expr_uses!(expr, state, transfer_reads = Set.new)
    consuming_reads = T.let(transfer_reads.dup, T::Set[String])
    linear_expr_consumed_names(expr).each { |name| consuming_reads.add(name) }
    if expr.is_a?(MIR::Pipeline)
      check_linear_expr_uses!(expr.inner, state, consuming_reads)
      return
    end
    if expr.is_a?(MIR::BlockExpr)
      inner = check_linear_stmts!(expr.body, state.copy)
      linear_exit_scope!(state, inner, "block-expr")
      return
    end
    linear_expr_ident_names(expr).each do |name|
      next if consuming_reads.include?(name)
      next unless state.released.include?(name) || state.maybe_released.include?(name)
      @errors << error(:OWNERSHIP_USE_AFTER_TRANSFER, name,
        "binding read after ownership was transferred")
    end
    check_nested_linear_expr_bodies!(expr, state)
    nil
  end

  sig { params(expr: T.nilable(MIR::Node), state: LinearOwnershipState).void }
  def check_nested_linear_expr_bodies!(expr, state)
    return unless expr.is_a?(MIR::Emittable)

    expr.child_exprs.each do |sub|
      if sub.is_a?(MIR::BlockExpr)
        inner = check_linear_stmts!(sub.body, state.copy)
        linear_exit_scope!(state, inner, "block-expr")
      else
        check_nested_linear_expr_bodies!(sub, state)
      end
    end
    nil
  end

  sig { params(expr: T.nilable(MIR::Node)).returns(T::Set[String]) }
  def linear_expr_consumed_names(expr)
    names = T.let(Set.new, T::Set[String])
    walk_mir_node(expr) do |node|
      if node.is_a?(MIR::StructInit) || node.is_a?(MIR::ArrayInit)
        collect_linear_expr_ident_names(node, names)
      end
      next unless node.is_a?(MIR::Call) || node.is_a?(MIR::RuntimeCall) || node.is_a?(MIR::TailCall) || node.is_a?(MIR::MethodCall)

      callable = node.is_a?(MIR::RuntimeCall) ? node.spec.callable_contract : node.callable_contract
      callable&.ownership_contract&.owned_operand_names&.each { |name| names.add(name.to_s) }
    end
    names
  end

  sig { params(expr: T.nilable(MIR::Node)).returns(T::Set[String]) }
  def linear_expr_ident_names(expr)
    names = T.let(Set.new, T::Set[String])
    collect_linear_expr_ident_names(expr, names)
    names
  end

  sig { params(expr: T.nilable(MIR::Node), names: T::Set[String]).void }
  def collect_linear_expr_ident_names(expr, names)
    return unless expr
    case expr
    when MIR::Ident
      names.add(expr.name.to_s)
      return
    when MIR::BlockExpr
      return
    end
    expr.child_exprs.each { |sub| collect_linear_expr_ident_names(sub, names) } if expr.is_a?(MIR::Emittable)
    nil
  end

  # INV-MOVEMARK-GUARD-SCOPE: MoveMark lowers to `name_moved = true`; that
  # variable only exists if a same-or-outer lexical body emitted a guarded
  # Cleanup/ErrCleanup for the binding earlier in the same scope. This rejects
  # ownership markers leaked out of nested returns/loops before Zig codegen can
  # see an undeclared `_moved` variable.
  sig { params(body: T::Array[MIR::Node], visible: NameSet).void }
  def verify_move_mark_scope!(body, visible = Set.new)
    body.each do |stmt|
      case stmt
      when MIR::Cleanup, MIR::ErrCleanup
        visible.add(stmt.name.to_s) if stmt.cleanup_entry.has_moved_guard?
      when MIR::MoveMark
        unless visible.include?(stmt.name.to_s)
          @errors << error(:MOVEMARK_WITHOUT_GUARD, stmt.name,
            "MIR::MoveMark has no visible guarded Cleanup/ErrCleanup; ownership marker escaped its lexical owner")
        end
      when MIR::IfStmt, MIR::IfBindStmt
        verify_move_mark_scope!(stmt.then_body, visible.dup)
        verify_move_mark_scope!(stmt.else_body || [], visible.dup)
      when MIR::WhileStmt, MIR::ForStmt, MIR::ScopeBlock, MIR::BlockExpr,
           MIR::SnapshotRead, MIR::SnapshotTransaction, MIR::SnapshotMultiTxn
        verify_move_mark_scope!(stmt.body, visible.dup)
      when MIR::SwitchStmt, MIR::UnionMatchStmt
        stmt.arms&.each { |a| verify_move_mark_scope!(a.body, visible.dup) }
        verify_move_mark_scope!(stmt.default_body || [], visible.dup)
      when MIR::IfChain
        stmt.branches&.each { |b| verify_move_mark_scope!(b.body, visible.dup) }
        verify_move_mark_scope!(stmt.default_body || [], visible.dup)
      when MIR::BgBlock
        verify_move_mark_scope!(stmt.run_body, visible.dup)
      when MIR::DoBlock
        stmt.branch_bodies&.each { |b| verify_move_mark_scope!(b, visible.dup) }
      when MIR::CatchWrapper
        stmt.clause_bodies&.each { |b| verify_move_mark_scope!(b, visible.dup) }
      when MIR::WithMatchDispatch
        stmt.arms&.each { |a| verify_move_mark_scope!(a.body, visible.dup) }
      end
    end
  end

  # INV-ERRCLEANUP-TRANSFER: ErrCleanup means "clean this binding only on the
  # error path because success transfers ownership". Success transfer must be
  # represented by TransferMark; otherwise the compiler is relying on context
  # folklore and the checker cannot distinguish a valid move from a leak.
  sig { params(err_cleanups: CleanupMarksByName, transfers: NameSet).void }
  def verify_err_cleanup_transfers!(err_cleanups, transfers)
    err_cleanups.each_key do |name|
      next if transfers.include?(name)
      @errors << error(:ERRCLEANUP_WITHOUT_TRANSFER, name,
        "MIR::ErrCleanup requires a matching MIR::TransferMark; success-path owner is implicit")
    end
  end

  # INV-ALLOCATING-LET-MARKED: a top-level Let init is the only legal place
  # for an allocating MIR expression, but "legal expression position" is not
  # ownership tracking. The binding must still have an AllocMark so cleanup or
  # transfer can be verified by name.
  sig { params(nodes: T::Array[MIR::Node], allocs: AllocMarksByName).void }
  def verify_allocating_lets_marked!(nodes, allocs)
    nodes.each do |node|
      next unless node.is_a?(MIR::Let)
      next unless allocating_expr?(node.init)
      next if allocs.key?(node.name)
      @errors << error(:ALLOCATING_LET_WITHOUT_ALLOC, node.name,
        "heap-allocating Let init has no MIR::AllocMark; ownership is implicit")
    end
    nil
  end

  # INV-AGGREGATE-OWNERSHIP: an aggregate that owns recursive data must have a
  # single allocator story. If an owned temp is inserted into a frame aggregate
  # while the temp was allocated on heap, the aggregate cleanup cannot
  # authoritatively free its children. Lowering must either materialize the
  # child in the aggregate allocator or make the aggregate heap-owned.
  sig { params(body: T::Array[MIR::Node], allocs: AllocMarksByName).void }
  def verify_aggregate_owned_children!(body, allocs)
    alloc_by_name = T.let({}, T::Hash[String, Symbol])
    allocs.each do |name, marks|
      mark = marks.first
      alloc_by_name[name] = mark.alloc if mark && VALID_ALLOCATORS.include?(mark.alloc)
    end
    check_aggregate_stmts!(body, alloc_by_name)
  end

  sig { params(stmts: T::Array[MIR::Node], alloc_by_name: T::Hash[String, Symbol]).void }
  def check_aggregate_stmts!(stmts, alloc_by_name)
    stmts.each do |stmt|
      case stmt
      when MIR::Let
        check_aggregate_expr!(stmt.init, alloc_by_name[stmt.name], alloc_by_name)
      when MIR::Set, MIR::DestructureSet, MIR::ReturnStmt, MIR::BreakStmt
        check_aggregate_expr!(stmt.value, nil, alloc_by_name)
      when MIR::ReassignWithCleanup
        check_reassign_cleanup_alloc!(stmt, alloc_by_name)
        check_aggregate_expr!(stmt.value, stmt.alloc, alloc_by_name)
      when MIR::ExprStmt, MIR::DiscardOwned
        check_aggregate_expr!(stmt.expr, nil, alloc_by_name)
      when MIR::IfStmt
        check_aggregate_expr!(stmt.cond, nil, alloc_by_name)
        check_aggregate_stmts!(stmt.then_body, alloc_by_name)
        check_aggregate_stmts!(stmt.else_body || [], alloc_by_name)
      when MIR::WhileStmt
        check_aggregate_expr!(stmt.cond, nil, alloc_by_name)
        check_aggregate_stmts!(stmt.body, alloc_by_name)
      when MIR::ForStmt
        check_aggregate_expr!(stmt.iter, nil, alloc_by_name)
        check_aggregate_stmts!(stmt.body, alloc_by_name)
      when MIR::ScopeBlock, MIR::BlockExpr
        check_aggregate_stmts!(stmt.body, alloc_by_name)
      when MIR::SwitchStmt, MIR::UnionMatchStmt
        check_aggregate_expr!(stmt.subject, nil, alloc_by_name)
        stmt.arms&.each { |a| check_aggregate_stmts!(a.body, alloc_by_name) }
        check_aggregate_stmts!(stmt.default_body || [], alloc_by_name)
      when MIR::IfChain
        stmt.branches&.each do |b|
          check_aggregate_expr!(b.cond, nil, alloc_by_name)
          check_aggregate_stmts!(b.body, alloc_by_name)
        end
        check_aggregate_stmts!(stmt.default_body || [], alloc_by_name)
      end
    end
  end

  sig { params(stmt: MIR::ReassignWithCleanup, alloc_by_name: T::Hash[String, Symbol]).void }
  def check_reassign_cleanup_alloc!(stmt, alloc_by_name)
    target_alloc = alloc_by_name[stmt.name.to_s]
    return unless target_alloc
    return if target_alloc == stmt.alloc

    @errors << error(:ALLOC_CLEANUP_MISMATCH, stmt.name.to_s,
      "MIR::ReassignWithCleanup frees old value with :#{stmt.alloc}, " \
      "but #{stmt.name} was allocated with :#{target_alloc}")
  end

  sig { params(expr: AggregateExpr, owner_alloc: T.nilable(Symbol), alloc_by_name: T::Hash[String, Symbol]).void }
  def check_aggregate_expr!(expr, owner_alloc, alloc_by_name)
    return unless expr
    case expr
    when MIR::Cast
      check_aggregate_expr!(expr.expr, owner_alloc, alloc_by_name)
    when MIR::MakeList
      list_alloc = expr.alloc
      expr.items&.each { |item| check_aggregate_expr!(item, list_alloc, alloc_by_name) }
    when MIR::StructInit
      expr.fields&.each do |field|
        field_alloc = MIR.struct_init_field_alloc(field) || owner_alloc
        check_aggregate_expr!(MIR.struct_init_field_value(field), field_alloc, alloc_by_name)
      end
    when MIR::ArrayInit
      expr.items&.each { |item| check_aggregate_expr!(item, owner_alloc, alloc_by_name) }
    when MIR::DeepCopy, MIR::RcRetain, MIR::RcDowngrade, MIR::WeakUpgrade
      # These read their source and produce a distinct handle/value; the
      # source binding itself is not inserted into the destination aggregate.
      return
    when MIR::Ident
      child_alloc = alloc_by_name[expr.name]
      return unless child_alloc && owner_alloc
      return if child_alloc == owner_alloc
      @errors << error(:AGGREGATE_CHILD_ALLOC_MISMATCH, expr.name,
        "owned child is :#{child_alloc} but aggregate owner is :#{owner_alloc}; " \
        "nested ownership placement is implicit/incoherent")
    else
      expr.child_exprs.each { |sub| check_aggregate_expr!(sub, nil, alloc_by_name) } if expr.is_a?(MIR::Emittable)
    end
    nil
  end

  # INV-INDIRECT-SINGLE-BOX: a HeapCreate is exactly one indirection
  # (`HeapCreate(T)` -> `*T`), so its cell type must never itself be a
  # pointer. A `*`-typed cell is a `**U` double box -> UAF on read.
  sig { params(nodes: T::Array[MIR::Node]).void }
  def verify_heap_create_single_indirection!(nodes)
    each_heap_create(nodes) do |hc|
      zt = hc.zig_type
      next unless zt.is_a?(String) && zt.lstrip.start_with?("*")
      @errors << error(:INDIRECT_DOUBLE_BOX, @fn_name,
        "HeapCreate cell type is `#{zt}` (already a pointer) — boxing it yields a double indirection")
    end
    nil
  end

  sig { params(nodes: T::Array[MIR::Node], blk: T.proc.params(arg0: MIR::HeapCreate).void).void }
  def each_heap_create(nodes, &blk)
    nodes.each do |node|
      yield node if node.is_a?(MIR::HeapCreate)
    end
    nil
  end

  sig { params(program: MIR::Program, strict: T::Boolean).returns(T::Array[String]) }
  def check_program!(program, strict: false)
    MIRPassState.require!(program, :mir_lowered, consumer: "MIRChecker")
    all_errors = T.let(ownership_registry_errors, T::Array[String])
    program.items.each do |item|
      if item.is_a?(MIR::FnDef)
        all_errors.concat(check_fn!(item, strict: strict))
      elsif item.is_a?(MIR::ModuleNamespace)
        (item.items || []).each do |child|
          all_errors.concat(check_fn!(child, strict: strict)) if child.is_a?(MIR::FnDef)
        end
      end
    end
    MIRPassState.for!(program).mark!(:mir_checked) if all_errors.empty?
    all_errors
  end

  sig { returns(T::Array[String]) }
  def ownership_registry_errors
    missing = T.let([], T::Array[String])
    unhandled_stmts = T.let([], T::Array[String])
    MIR.constants.each do |const_name|
      value = MIR.const_get(const_name)
      next unless value.is_a?(Class)
      next unless value < Struct
      next unless value < MIR::Emittable

      klass = value
      if klass < MIR::Stmt && !LINEAR_STATEMENT_NODE_TYPES.include?(klass)
        unhandled_stmts << T.must(klass.name)
      end
      next if MIR::OWNERSHIP_SIGNIFICANT_NODE_TYPES.include?(klass)
      next if MIR::OWNERSHIP_SIGNIFICANT_NODE_NAMES.include?(T.must(klass.name))

      members = T.cast(T.unsafe(klass).members, T::Array[Symbol])
      next if (members & OWNERSHIP_FIELD_NAMES.to_a).empty?

      missing << T.must(klass.name)
    end
    errors = T.let([], T::Array[String])
    unhandled_stmts.sort.each do |name|
      errors << "[LINEAR_STMT_NOT_REGISTERED] #{name} -- MIR statement is absent " \
        "from MIRChecker::LINEAR_STATEMENT_NODE_TYPES"
    end

    missing.sort.each do |name|
      errors << "[OWNERSHIP_NODE_NOT_REGISTERED] #{name} -- MIR node has ownership-significant fields " \
        "but is absent from MIR::OWNERSHIP_SIGNIFICANT_NODE_TYPES"
    end
    errors
  end

  sig { params(init: T.nilable(MIR::Node)).returns(T::Boolean) }
  def owned_return_init?(init)
    return true if init.is_a?(MIR::Call) && init.owned_return?

    if init.is_a?(MIR::InlineBc) || init.is_a?(MIR::RegistryCall)
      return false unless stdlib_owned_return?(init)
      # Receiver-dependent (Proc-resolved) returns -- collection
      # intrinsics like pool.insert/get -- are not a static owned-
      # return declaration; their ownership is governed by
      # allocates/borrows, handled elsewhere. Only a static return
      # type counts here (matches pre-FS behavior, which read only
      # the static `:return` key).
      sig = FunctionSignature.unwrap(T.unsafe(init).stdlib_def)
      return false unless sig&.fixed_return?
      ret = sig.return_type
      return !ret.void?
    end
    false
  end

  # INV-CLEANUP-SOURCE-OWNS: Cleanup is legal only for a binding whose
  # initializer creates ownership or receives ownership through an explicit
  # structural transfer. Borrowed views (IndexGet/GetField/match payloads)
  # may have recursive types, but cleaning them frees their owner.
  sig do
    params(
      body: T::Array[MIR::Node],
      cleanups: CleanupMarksByName,
      err_cleanups: CleanupMarksByName,
    ).void
  end
  def verify_cleanup_sources_own_values!(body, cleanups, err_cleanups)
    return if cleanups.empty? && err_cleanups.empty?

    verify_cleanup_sources_in_scope!(body)
  end

  sig { params(body: T::Array[MIR::Node]).void }
  def verify_cleanup_sources_in_scope!(body)
    lets = T.let({}, T::Hash[String, MIR::Let])
    body.each do |node|
      next unless node.is_a?(MIR::Emittable)

      lets[node.name.to_s] = node if node.is_a?(MIR::Let)
      if node.is_a?(MIR::Cleanup) || node.is_a?(MIR::ErrCleanup)
        let = lets[node.name.to_s]
        if let && !cleanup_source_owns_value?(let, node)
          @errors << error(:OWNERSHIP_CLEANUP_FOR_BORROW, node.name,
            "Cleanup was emitted for a binding initialized from a borrowed/non-owning expression; " \
            "MIRChecker cannot prove this binding owns memory")
        end
      end
      node.body_slots.each { |slot| verify_cleanup_sources_in_scope!(slot.body) }
    end
    nil
  end

  # IF/WHILE optional captures are lexical bindings rather than MIR::Let
  # nodes, so the ordinary cleanup-source proof cannot see their initializer.
  # Lowering carries the annotator's ownership decision on each binding; any
  # cleanup attached to a borrowed capture is a compiler-generated RC UAF.
  sig { params(nodes: T::Array[MIR::Node]).void }
  def verify_if_bind_capture_cleanup_ownership!(nodes)
    nodes.each do |node|
      next unless node.is_a?(MIR::IfBindStmt)

      cleanup_names = node.then_body.filter_map do |stmt|
        stmt.name.to_s if stmt.is_a?(MIR::Cleanup) || stmt.is_a?(MIR::ErrCleanup)
      end.to_set
      node.bindings.each do |binding|
        next unless binding.is_a?(Hash)
        capture = binding[:capture].to_s
        next unless cleanup_names.include?(capture)
        next if binding[:owns_capture] == true

        @errors << error(:OWNERSHIP_CLEANUP_FOR_BORROW, capture,
          "optional capture cleanup requires owns_capture=true; borrowed collection/field/local captures must remain owned by their source")
      end
    end
    nil
  end

  # Rc/Arc handles are duplicated only by retain/upgrade operations. A direct
  # DeepCopy would structurally copy ctrl/data pointers and fabricate an owner
  # that was never counted. Nested aggregates remain legal because runtime
  # dupeValue recursively dispatches RC fields through retainOne.
  sig { params(nodes: T::Array[MIR::Node]).void }
  def verify_no_structural_rc_handle_copies!(nodes)
    nodes.each do |node|
      next unless node.is_a?(MIR::DeepCopy)
      zig_type = node.zig_type.to_s
      zig_type = T.must(zig_type[1..]) if zig_type.start_with?("?")
      direct_ref_handle = ["CheatLib.Rc(", "CheatLib.Arc(", "CheatLib.WeakRc(", "CheatLib.WeakArc("].any? do |prefix|
        zig_type.start_with?(prefix)
      end
      next unless direct_ref_handle

      @errors << error(:OWNERSHIP_STRUCTURAL_RC_COPY, node.zig_type,
        "reference-counted handles must be retained, upgraded, or downgraded; MIR::DeepCopy may not structurally duplicate an Rc/Arc handle")
    end
    nil
  end

  sig { params(node: MIR::Let, cleanup: T.any(MIR::Cleanup, MIR::ErrCleanup)).returns(T::Boolean) }
  def cleanup_source_owns_value?(node, cleanup)
    init = ownership_source_expr(node.init)
    return true if cleanup.cleanup_entry.match_as?
    return true if allocating_expr?(init)
    return true if value_constructor_expr?(init)
    return true if init.is_a?(MIR::ForeignOwnedUnwrap)
    return true if MIR::OwnershipEffect.of(init).produces_owned
    return true if owned_return_init?(init)
    return true if expr_owned_result_alloc(init)
    return true if structural_consumed_names(node).any?
    node_fact = node.ownership_consumption
    return true if node_fact.is_a?(MIR::OwnershipConsumptionFact) &&
                   node_fact.operands.any? { |operand|
                     name = operand.name
                     !name.nil? && !name.empty?
                   }
    init_fact = init.respond_to?(:ownership_consumption) ? init.ownership_consumption : nil
    return true if init_fact.is_a?(MIR::OwnershipConsumptionFact) &&
                   init_fact.operands.any? { |operand|
                     name = operand.name
                     !name.nil? && !name.empty?
                   }

    false
  end

  sig { params(node: T.nilable(MIR::Node)).returns(T::Boolean) }
  def value_constructor_expr?(node)
    return true if node.is_a?(MIR::StructInit) || node.is_a?(MIR::TupleLiteral) ||
      node.is_a?(MIR::ArrayInit) || node.is_a?(MIR::ArrayDefaultInit)
    if node.is_a?(MIR::BlockExpr)
      terminal = node.body.reverse.find do |item|
        item.is_a?(MIR::BreakStmt) && item.label == node.label
      end
      return value_constructor_expr?(terminal.value) if terminal.is_a?(MIR::BreakStmt) && terminal.value
      return false
    end
    return false unless node.is_a?(MIR::MethodCall) && ["create", "createBound"].include?(node.method)

    receiver = node.receiver
    (receiver.is_a?(MIR::Call) &&
      ["CheatLib.NodeStore", "CheatLib.SharedNodeStore"].include?(receiver.callee)) == true
  end

  sig { params(node: MIR::Node).returns(MIR::Node) }
  def ownership_source_expr(node)
    current = T.let(node, MIR::Node)
    while current.respond_to?(:expr) &&
        (current.is_a?(MIR::Cast) || current.is_a?(MIR::TryExpr))
      current = T.cast(T.unsafe(current).expr, MIR::Node)
    end
    current
  end

  sig { params(node: MIR::Node).returns(T::Boolean) }
  def stdlib_owned_return?(node)
    sig = FunctionSignature.unwrap(T.unsafe(node).stdlib_def)
    return false unless sig

    ret_type = sig.return_type
    return true if ret_type.resource?
    return false unless sig.emits_allocating?
    return true if sig.heap_return_alloc?
    metadata = allocator_metadata_for(node)
    return false unless metadata

    metadata.any_heap?
  end

  sig { params(node: MIR::Node).returns(T::Boolean) }
  def stdlib_owned_fixed_return?(node)
    sig = node.respond_to?(:stdlib_def) ? FunctionSignature.unwrap(T.unsafe(node).stdlib_def) : nil
    return false unless sig

    stdlib_owned_return?(node) && sig.fixed_return?
  end

  sig { params(lets: T::Array[MIR::Let], allocs: AllocMarksByName).void }
  def verify_owned_return_alloc_marks!(lets, allocs)
    lets.each do |let|
      marks = allocs[let.name]
      unless marks
        @errors << error(:OWNED_RETURN_WITHOUT_ALLOC, let.name,
          "owned-return initializer is heap-provenance but no MIR::AllocMark exists")
        next
      end

      mark_allocs = marks.map { |mark| T.unsafe(mark).alloc }
      if mark_allocs.any? { |alloc| MIR::Placement.frame?(alloc) }
        @errors << error(:OWNED_RETURN_ALLOC_NOT_HEAP, let.name,
          "owned-return initializer is heap-provenance but MIR::AllocMark uses :frame")
      end
    end
  end

  sig { params(init: T.nilable(MIR::Node)).returns(T.nilable(Symbol)) }
  def expr_owned_result_alloc(init)
    effect = MIR::OwnershipEffect.of(init)
    return nil unless effect.requires_hoist

    effect.alloc
  end

  sig { params(lets: T::Array[MIR::Let], allocs: AllocMarksByName).void }
  def verify_owned_result_alloc_marks!(lets, allocs)
    lets.each do |let|
      expected_alloc = expr_owned_result_alloc(let.init)
      next unless expected_alloc

      marks = allocs[let.name]
      unless marks && !marks.empty?
        @errors << error(:OWNED_RESULT_WITHOUT_ALLOC, let.name,
          "owned-result initializer has no MIR::AllocMark; ownership is implicit")
        next
      end

      bad_mark = marks.find { |mark| mark.alloc != expected_alloc }
      next unless bad_mark

      @errors << error(:OWNED_RESULT_ALLOC_MISMATCH, let.name,
        "owned-result initializer produces :#{expected_alloc} storage but MIR::AllocMark uses :#{bad_mark.alloc}")
    end
    nil
  end

  # ===================================================================
  # FSM structural validation
  # ===================================================================
  #
  # Verifies the cleanup-placement decisions baked into a stackless
  # FSM body before its rendered Zig text reaches the emitter. The
  # FSM lowering produces a `MIR::FsmStructure` alongside the Zig
  # text; this method runs over the structure and raises on any
  # violation of the FSM-specific invariants below. Called from
  # `mir_lowering.rb` immediately after `emit_fsm_io_bg_code` returns,
  # so a violation aborts the whole compile rather than producing
  # silently-incorrect Zig output.
  #
  # INV-FSM-CAPTURE-FINALIZE
  #   Every entry in `structure.captures` must have
  #   `cleanup_at == :finalize`. Captures (heap-dupe'd into the FSM
  #   ctx at spawn) may be read by ANY step; placing their `defer
  #   free()` inside an earlier step fires the cleanup before later
  #   steps run, leaving freed pointers in ctx fields. This is
  #   exactly the UAF that shipped in the readFile/writeFile commit.
  #
  # INV-FSM-CAPTURE-CLEANUP-PRESENT
  #   Every capture must appear in `structure.finalize_cleanups`. A
  #   capture with NO cleanup leaks the heap-dupe.
  #
  # INV-FSM-STEP-READS-LIVE
  #   For each step S and each name read in S, the name must either
  #   (a) be in `finalize_cleanups` (lives until FSM end), or
  #   (b) have its cleanup in a step >= S (still alive when S reads).
  #   A name read in step S whose cleanup lives in step T < S is a
  #   cross-step UAF.
  #
  # INV-FSM-RESULT-NO-FINALIZED-ALIAS
  #   The BG body's terminal result expression must not alias a
  #   state field that is freed at FSM finalize. Aliasing happens
  #   when a terminal result local aliases a finalized field and is
  #   then assigned directly into inner.result. The slice escapes the FSM but its
  #   backing memory dies when the finalize defer fires — the
  #   consumer reads a dangling pointer. Detected by the lowering
  #   (see emit_fsm_io_bg_code) and recorded as
  #   `structure.result_aliases_finalized`.
  #
  # Raises FsmStructureError on the first violation, with a message
  # naming the binding and the bad step index. Future invariants get
  # added here, NOT in the rendering code.
  class FsmStructureError < StandardError; end
  VALID_FSM_DESTROY_SOURCES = T.let(
    [:capture, :fresh_heap, :body, :owned_result].freeze,
    T::Array[Symbol],
  )
  VALID_FSM_UNLOCK_METHODS = T.let(%w[unlock unlockShared].freeze, T::Array[String])

  sig { params(structure: T.nilable(MIR::FsmStructure), source: T.nilable(AST::Node)).returns(NilClass) }
  def self.check_fsm_structure!(structure, source: nil)
    return unless structure
    captures = T.cast(structure.captures || [], T::Array[MIR::FsmCaptureFact])
    finalize_cleanups = structure.finalize_cleanups || []
    steps = T.cast(structure.steps || [], T::Array[MIR::FsmStepFact])

    # INV-FSM-CAPTURE-FINALIZE
    captures.each do |cap|
      unless cap.cleanup_at == :finalize
        raise FsmStructureError, format_fsm_error(
          "INV-FSM-CAPTURE-FINALIZE",
          "capture '#{cap.name}' has cleanup_at=#{cap.cleanup_at.inspect}; " \
          "captures may be read by any step and MUST cleanup at FSM finalize. " \
          "Cleanup placed in an earlier step fires before later steps run -> UAF.",
          source,
        )
      end
    end

    # INV-FSM-CAPTURE-CLEANUP-PRESENT
    captures.each do |cap|
      unless finalize_cleanups.include?(cap.name)
        raise FsmStructureError, format_fsm_error(
          "INV-FSM-CAPTURE-CLEANUP-PRESENT",
          "capture '#{cap.name}' has no entry in finalize_cleanups; " \
          "the heap-dupe at spawn would leak.",
          source,
        )
      end
    end

    check_fsm_destroy_actions!(
      structure.destroy_actions,
      finalize_cleanups,
      structure.ctx_id.is_a?(Integer) ? structure.ctx_id : nil,
      source,
    )

    # INV-FSM-STEP-READS-LIVE
    cleanup_step_index = {}
    steps.each do |step|
      step.cleanups.each { |name| cleanup_step_index[name] = step.index }
    end
    steps.each do |step|
      step.reads.each do |name|
        next if finalize_cleanups.include?(name)  # lives until end
        cleanup_step = cleanup_step_index[name]
        next if cleanup_step.nil?                  # no cleanup recorded -> separate invariant
        next if cleanup_step >= step.index
        raise FsmStructureError, format_fsm_error(
          "INV-FSM-STEP-READS-LIVE",
          "step #{step.index} reads '#{name}' but its cleanup was placed in " \
          "step #{cleanup_step} (earlier). The defer fires before step #{step.index} " \
          "runs -> cross-step UAF.",
          source,
        )
      end
    end

    # INV-FSM-RESULT-NO-FINALIZED-ALIAS
    if structure.respond_to?(:result_aliases_finalized) && structure.result_aliases_finalized
      aliased = structure.result_aliases_finalized
      raise FsmStructureError, format_fsm_error(
        "INV-FSM-RESULT-NO-FINALIZED-ALIAS",
        "BG body's terminal expression aliases finalized state field '#{aliased}' " \
        "via the bound local. The slice would escape the FSM via inner.result, but " \
        "its backing memory is freed when the finalize defer fires at end of last " \
        "step -> consumer reads a dangling pointer. Either compute a fresh value " \
        "from the bound local before returning (e.g. wrap in a function call that " \
        "returns a value type), or drop the FSM templates for this stdlib so the " \
        "stackful escape-promotion path handles ownership.",
        source,
      )
    end

    # INV-FSM-TRANSFER-GUARD-WRITTEN
    # A captured ctx field consumed inside the FSM must write its ctx-owned
    # move guard before transferring ownership. Otherwise destroyTask still
    # cleans the field and the consumer cleans it again.
    required_guards = structure.respond_to?(:required_move_guards) ? structure.required_move_guards : []
    guard_writes = structure.respond_to?(:move_guard_writes) ? structure.move_guard_writes : []
    required_guards.each do |name|
      next if guard_writes.include?(name)

      raise FsmStructureError, format_fsm_error(
        "INV-FSM-TRANSFER-GUARD-WRITTEN",
        "captured ctx field '#{name}' is transferred out of the FSM but no " \
        "`#{name}_moved = true` write is present in the FSM structure. " \
        "destroyTask would run the finalizer after ownership moved -> double free.",
        source,
      )
    end

    # INV-FSM-OWNED-RESULT-TRANSFER
    # Owned BG results cross the scheduler boundary through inner.result. The
    # structure must expose a result ownership fact so future result shapes do
    # not silently fall back to raw Zig assignment.
    if structure.respond_to?(:owned_result_required) && structure.owned_result_required
      facts = structure.respond_to?(:ownership_facts) ? structure.ownership_facts : []
      result_facts = facts.select { |fact| fact.target == :result }
      unless result_facts.any?
        raise FsmStructureError, format_fsm_error(
          "INV-FSM-OWNED-RESULT-TRANSFER",
          "FSM BG returns an owned result but the structure has no result " \
          "ownership fact. Raw inner.result assignment is unverifiable.",
          source,
        )
      end
      result_facts.each do |fact|
        next unless fact.move_guarded
        next if guard_writes.include?(fact.name)

        raise FsmStructureError, format_fsm_error(
          "INV-FSM-OWNED-RESULT-GUARD-WRITTEN",
          "FSM BG transfers owned result '#{fact.name}' but no matching move " \
          "guard write is present. The segment-local cleanup would free the " \
          "value before the promise consumer receives it.",
          source,
        )
      end
    end

    nil
  end

  sig do
    params(
      actions: T::Array[MIR::FsmDestroyAction],
      finalize_cleanups: T::Array[String],
      ctx_id: T.nilable(Integer),
      source: T.nilable(AST::Node),
    ).void
  end
  def self.check_fsm_destroy_actions!(actions, finalize_cleanups, ctx_id, source)
    return if actions.empty? && finalize_cleanups.empty?
    unless ctx_id
      raise FsmStructureError, format_fsm_error(
        "INV-FSM-DESTROY-CTX-ID",
        "FSM finalization records exist but ctx_id is missing; destroyTask " \
        "targets cannot be verified.",
        source,
      )
    end

    cleanup_names = actions.filter_map { |action|
      action.cleanup_name
    }
    finalize_cleanups.each do |name|
      next if cleanup_names.include?(name)

      raise FsmStructureError, format_fsm_error(
        "INV-FSM-FINALIZE-ACTION-PRESENT",
        "finalize cleanup '#{name}' has no structural destroy action.",
        source,
      )
    end

    actions.each do |action|
      case action
      when MIR::FsmDestroyCleanup
        check_fsm_destroy_cleanup_action!(action, finalize_cleanups, ctx_id, source)
      when MIR::FsmDestroyStmt
        check_fsm_destroy_stmt_action!(action, finalize_cleanups, ctx_id, source)
      when MIR::FsmDestroyLockRelease
        check_fsm_destroy_lock_action!(action, ctx_id, source)
      end
    end
  end

  sig do
    params(
      action: MIR::FsmDestroyCleanup,
      finalize_cleanups: T::Array[String],
      ctx_id: Integer,
      source: T.nilable(AST::Node),
    ).void
  end
  def self.check_fsm_destroy_cleanup_action!(action, finalize_cleanups, ctx_id, source)
    unless VALID_FSM_DESTROY_SOURCES.include?(action.source_kind)
      raise FsmStructureError, format_fsm_error(
        "INV-FSM-DESTROY-SOURCE",
        "destroy cleanup '#{action.name}' has unknown source #{action.source_kind.inspect}.",
        source,
      )
    end

    expected_target = "__ctx_#{ctx_id}.#{action.name}"
    target_text = fsm_destroy_expr_label(action.target)
    unless fsm_ctx_field_target?(action.target, ctx_id, action.name)
      raise FsmStructureError, format_fsm_error(
        "INV-FSM-DESTROY-TARGET",
        "destroy cleanup '#{action.name}' targets #{target_text.inspect}; " \
        "expected #{expected_target.inspect}.",
        source,
      )
    end

    unless finalize_cleanups.include?(action.name)
      raise FsmStructureError, format_fsm_error(
        "INV-FSM-DESTROY-FINALIZE-LIST",
        "destroy cleanup '#{action.name}' is not listed in finalize_cleanups.",
        source,
      )
    end

    entry = action.cleanup_entry
    unless entry.needs_cleanup?
      raise FsmStructureError, format_fsm_error(
        "INV-FSM-DESTROY-CLEANUP-ENTRY",
        "destroy cleanup '#{action.name}' has a no-cleanup entry.",
        source,
      )
    end

    unless [:heap, :frame].include?(entry.alloc)
      raise FsmStructureError, format_fsm_error(
        "INV-FSM-DESTROY-ALLOC",
        "destroy cleanup '#{action.name}' uses invalid allocator #{entry.alloc.inspect}.",
        source,
      )
    end

    if entry.kind == :resource
      close_plan = entry.resource_close_plan
      unless close_plan && !close_plan.empty?
        raise FsmStructureError, format_fsm_error(
          "INV-FSM-DESTROY-RESOURCE-PLAN",
          "resource cleanup '#{action.name}' must carry at least one close action.",
          source,
        )
      end
    end

    check_fsm_destroy_optional_expr!("guard", action.name, action.guard, source)
    check_fsm_destroy_optional_expr!("allocator", action.name, action.allocator, source)
  end

  sig do
    params(
      action: MIR::FsmDestroyStmt,
      finalize_cleanups: T::Array[String],
      ctx_id: Integer,
      source: T.nilable(AST::Node),
    ).void
  end
  def self.check_fsm_destroy_stmt_action!(action, finalize_cleanups, ctx_id, source)
    unless VALID_FSM_DESTROY_SOURCES.include?(action.source_kind)
      raise FsmStructureError, format_fsm_error(
        "INV-FSM-DESTROY-SOURCE",
        "destroy statement '#{action.name}' has unknown source #{action.source_kind.inspect}.",
        source,
      )
    end

    expected_target = "__ctx_#{ctx_id}.#{action.name}"
    unless action.ctx_cleanup_target_name == expected_target
      raise FsmStructureError, format_fsm_error(
        "INV-FSM-DESTROY-TARGET",
        "destroy statement '#{action.name}' targets #{action.ctx_cleanup_target_name.inspect}; " \
        "expected #{expected_target.inspect}.",
        source,
      )
    end

    unless finalize_cleanups.include?(action.name)
      raise FsmStructureError, format_fsm_error(
        "INV-FSM-DESTROY-FINALIZE-LIST",
        "destroy statement '#{action.name}' is not listed in finalize_cleanups.",
        source,
      )
    end
  end

  sig { params(action: MIR::FsmDestroyLockRelease, ctx_id: Integer, source: T.nilable(AST::Node)).void }
  def self.check_fsm_destroy_lock_action!(action, ctx_id, source)
    unless action.ctx_id == ctx_id
      raise FsmStructureError, format_fsm_error(
        "INV-FSM-DESTROY-LOCK-TARGET",
        "lock destroy action '#{action.name}' targets ctx #{action.ctx_id}, expected ctx #{ctx_id}.",
        source,
      )
    end

    unless action.guard_index >= 0
      raise FsmStructureError, format_fsm_error(
        "INV-FSM-DESTROY-LOCK-GUARD",
        "lock destroy action '#{action.name}' uses invalid guard index #{action.guard_index.inspect}.",
        source,
      )
    end

    unless VALID_FSM_UNLOCK_METHODS.include?(action.unlock_method)
      raise FsmStructureError, format_fsm_error(
        "INV-FSM-DESTROY-LOCK-METHOD",
        "lock destroy action '#{action.name}' uses unknown unlock method #{action.unlock_method.inspect}.",
        source,
      )
    end
  end

  sig { params(kind: String, name: String, value: T.nilable(MIR::Emittable), source: T.nilable(AST::Node)).void }
  def self.check_fsm_destroy_optional_expr!(kind, name, value, source)
    return unless value

    check_fsm_destroy_required_expr!(kind, name, value, source)
  end

  sig { params(kind: String, name: String, value: MIR::Emittable, source: T.nilable(AST::Node)).void }
  def self.check_fsm_destroy_required_expr!(kind, name, value, source)
    unless fsm_destroy_field_path?(value)
      raise FsmStructureError, format_fsm_error(
        "INV-FSM-DESTROY-ZIG-FIELD",
        "destroy #{kind} for '#{name}' must be a single expression field, got #{fsm_destroy_expr_label(value).inspect}.",
        source,
      )
    end
  end

  sig { params(expr: MIR::Emittable).returns(T::Boolean) }
  def self.fsm_destroy_field_path?(expr)
    !fsm_destroy_expr_path(expr).nil?
  end

  sig { params(expr: MIR::Emittable).returns(String) }
  def self.fsm_destroy_expr_label(expr)
    fsm_destroy_expr_path(expr) || expr.class.name.to_s
  end

  sig { params(expr: MIR::Emittable).returns(T.nilable(String)) }
  def self.fsm_destroy_expr_path(expr)
    case expr
    when MIR::Ident
      segment = expr.name.to_s
      fsm_destroy_field_segment?(segment) ? segment : nil
    when MIR::FieldGet
      object = expr.object
      return nil unless object.is_a?(MIR::Emittable)

      object_path = fsm_destroy_expr_path(object)
      field = expr.field.to_s
      return nil unless object_path && fsm_destroy_field_segment?(field)

      "#{object_path}.#{field}"
    else
      nil
    end
  end

  sig { params(segment: String).returns(T::Boolean) }
  def self.fsm_destroy_field_segment?(segment)
    return false if segment.empty?

    bytes = T.let(segment.bytes, T::Array[Integer])
    first = bytes.fetch(0)
    return false unless fsm_destroy_field_segment_head_byte?(first)

    bytes.drop(1).all? { |byte| fsm_destroy_field_segment_tail_byte?(byte) }
  end

  sig { params(byte: Integer).returns(T::Boolean) }
  def self.fsm_destroy_field_segment_head_byte?(byte)
    byte == 95 || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
  end

  sig { params(byte: Integer).returns(T::Boolean) }
  def self.fsm_destroy_field_segment_tail_byte?(byte)
    fsm_destroy_field_segment_head_byte?(byte) || (byte >= 48 && byte <= 57)
  end

  sig { params(expr: MIR::Emittable, ctx_id: Integer, field: String).returns(T::Boolean) }
  def self.fsm_ctx_field_target?(expr, ctx_id, field)
    return false unless expr.is_a?(MIR::FieldGet)
    return false unless expr.field.to_s == field

    object = expr.object
    object.is_a?(MIR::Ident) && object.name.to_s == "__ctx_#{ctx_id}"
  end

  sig { params(invariant: String, message: String, source: T.nilable(AST::Node)).returns(String) }
  def self.format_fsm_error(invariant, message, source)
    loc = source&.line ? " at line #{source.line}" : ""
    "[FSM checker]#{loc} #{invariant}: #{message}"
  end

  private

  VALID_ALLOCATORS = T.let([:heap, :frame].freeze, T::Array[Symbol])
  VALID_ALLOC_SCOPES = T.let([:heap, :function, :iteration].freeze, T::Array[Symbol])

  sig { params(node: MIR::Node).returns(T::Boolean) }
  def allocator_metadata_node?(node)
    metadata = allocator_metadata_for(node)
    metadata.is_a?(MIR::InlineAllocMetadata) && !metadata.empty?
  end

  sig { params(node: AllocatorMetadataSource).returns(T.nilable(MIR::InlineAllocMetadata)) }
  def allocator_metadata_for(node)
    carrier = allocator_metadata_carrier(node)
    case carrier
    when MIR::RegistryCall, MIR::IndexedStore
      carrier.allocs
    when MIR::ShardedMapPut, MIR::ShardedMapGet
      carrier.resolved_allocs
    end
  end

  sig { params(node: AllocatorMetadataSource).returns(T.nilable(AllocatorMetadataCarrier)) }
  def allocator_metadata_carrier(node)
    case node
    when MIR::RegistryCall, MIR::IndexedStore, MIR::ShardedMapPut, MIR::ShardedMapGet
      node
    end
  end

  sig { params(node: AllocatorMetadataSource).returns(T.nilable(String)) }
  def allocator_metadata_target(node)
    carrier = allocator_metadata_carrier(node)
    case carrier
    when MIR::RegistryCall
      target = carrier.target_var
      return target.to_s if target && !target.to_s.empty?
    when MIR::IndexedStore, MIR::ShardedMapPut
      target = carrier.target_var
      return target.to_s if target && !target.to_s.empty?
      target_expr = carrier.target
      return target_expr.name.to_s if target_expr.is_a?(MIR::Ident)
    when MIR::ShardedMapGet
      target_expr = carrier.target
      return target_expr.name.to_s if target_expr.is_a?(MIR::Ident)
    end
    nil
  end

  sig { params(node: AllocatorMetadataSource).returns(String) }
  def allocator_metadata_label(node)
    target = allocator_metadata_target(node)
    return target if target

    reason = node.is_a?(MIR::RegistryCall) ? node.reason : nil
    reason ? reason.to_s : node.class.name.to_s
  end

  sig do
    params(
      allocs: AllocMarksByName,
      cleanups: CleanupMarksByName,
      metadata_nodes: T::Array[MIR::Node],
    ).void
  end
  def verify_allocator_closed_set!(allocs, cleanups, metadata_nodes)
    allocs.each do |name, marks|
      marks.each do |mark|
        next if VALID_ALLOCATORS.include?(mark.alloc)
        @errors << error(:INVALID_ALLOCATOR_MARK, name,
          "AllocMark uses #{mark.alloc.inspect}; MIR allocator facts must be :heap or :frame")
      end
    end

    allocs.each do |name, marks|
      marks.each do |mark|
        scope = mark.respond_to?(:scope) ? mark.scope : nil
        next if VALID_ALLOC_SCOPES.include?(scope)
        @errors << error(:INVALID_ALLOCATOR_MARK, name,
          "AllocMark has scope #{scope.inspect}; MIR allocation lifetime must be :heap, :function, or :iteration")
      end
    end

    cleanups.each do |name, nodes|
      nodes.each do |cleanup|
        alloc = cleanup.cleanup_entry.alloc
        next if VALID_ALLOCATORS.include?(alloc)
        @errors << error(:INVALID_ALLOCATOR_MARK, name,
          "#{cleanup.class.name} uses #{alloc.inspect}; MIR cleanup allocators must be :heap or :frame")
      end
    end

    metadata_nodes.each do |node|
      metadata = allocator_metadata_for(node)
      next unless metadata && !metadata.empty?
      metadata.each do |alloc_key, alloc|
        next if VALID_ALLOCATORS.include?(alloc)
        @errors << error(:INVALID_ALLOCATOR_MARK, allocator_metadata_label(node),
          "allocator metadata #{alloc_key} uses #{alloc.inspect}; MIR allocator metadata must be :heap or :frame")
      end
    end
  end

  # INV-ALLOC-METADATA-TARGET: allocator-bearing structural nodes must name the
  # binding or receiver whose placement they consume. Without that target, the checker
  # cannot compare allocator use to authoritative placement and lowering can
  # smuggle local guesses through codegen.
  sig { params(metadata_nodes: T::Array[MIR::Node]).void }
  def verify_allocator_metadata_targets!(metadata_nodes)
    metadata_nodes.each do |node|
      metadata = allocator_metadata_for(node)
      next unless metadata && !metadata.empty?
      target = allocator_metadata_target(node)
      next if target && !target.to_s.empty?

      @errors << error(:INLINE_ALLOC_WITHOUT_TARGET, allocator_metadata_label(node),
        "#{node.class.name} has allocator metadata #{metadata.inspect} but no target binding; " \
        "allocator use is not checker-verifiable against binding placement")
    end
  end

  # Tree walker -- yields every node in the MIR tree.
  sig { params(stmts: T.nilable(MIR::NodeRoot), block: T.proc.params(arg0: MIR::Node).void).void }
  def walk_mir(stmts, &block)
    MIR.each_node(stmts, &block)
    nil
  end

  sig { params(node: T.nilable(MIR::NodeRoot), block: T.proc.params(arg0: MIR::Node).void).void }
  def walk_mir_node(node, &block)
    return unless node.is_a?(MIR::Emittable) || node.is_a?(Array)

    MIR.each_node(node, &block)
    nil
  end

  sig { params(expr: T.nilable(MIR::NodeRoot), block: T.proc.params(arg0: MIR::Node).void).void }
  def walk_mir_expr(expr, &block)
    walk_mir_node(expr, &block)
    nil
  end

  # HPT_LEAK: heap-returning call result discarded.
  sig { params(node: T.nilable(MIR::Node), leaks: T::Array[String]).returns(NilClass) }
  def scan_expr_for_hpt_leak!(node, leaks)
    return unless node

    MIR.each_surface_node(node) do |expr|
      effect = MIR::OwnershipEffect.of(expr)
      if effect.produces_owned
        leaks << error(:HPT_LEAK, ownership_effect_label(expr),
          "owned-result expression not bound to variable (leak)")
        next
      end

      if stdlib_owned_fixed_return?(expr)
        sig = FunctionSignature.unwrap(T.unsafe(expr).stdlib_def)
        ret = T.must(sig).return_type
        unless ret.void?
          leaks << error(:HPT_LEAK, ownership_effect_label(expr),
            "stdlib call with allocates:true result not bound to variable (leak)")
        end
      end
    end
    nil
  end

  sig { params(node: MIR::Node).returns(String) }
  def ownership_effect_label(node)
    case node
    when MIR::Call
      node.callee.to_s
    when MIR::MethodCall
      node.method.to_s
    when MIR::RegistryCall
      node.reason
    else
      node.class.name.to_s
    end
  end

  # INLINE_ALLOC_MISMATCH: structural operation allocator must match container.
  #
  # Checks ALL allocator params (:alloc, :key_alloc, :val_alloc) against the
  # container's AllocMark. A frame-allocated key/value stored in a heap
  # container becomes a dangling pointer after frame rewind.
  sig { params(metadata_nodes: T::Array[MIR::Node], allocs: AllocMarksByName, fn_def: MIR::FnDef).void }
  def verify_allocator_metadata_contracts!(metadata_nodes, allocs, fn_def)
    param_names = T.let(fn_def.params.each_with_object(Set.new) do |param, names|
      name = param.name.to_s
      names << name
      # Mutable by-value parameters lower as a pointer named `_m_<name>` plus
      # a local shadow named `<name>`. Structural operations are attributed to
      # that source-level shadow, which is still parameter-owned and therefore
      # does not require a local AllocMark.
      names << name.delete_prefix("_m_") if name.start_with?("_m_")
    end, T::Set[String])
    metadata_nodes.each do |node|
      alloc_metadata = allocator_metadata_for(node)
      next unless alloc_metadata && !alloc_metadata.empty?
      target = allocator_metadata_target(node)
      next unless target && !target.to_s.empty?

      requires_target_alloc = alloc_metadata.requires_target_alloc?
      unless allocs.key?(target)
        next if param_names.include?(target.to_s)
        next unless requires_target_alloc
        @errors << error(:INLINE_ALLOC_WITHOUT_ALLOCMARK, target,
          "#{node.class.name} has allocator metadata #{alloc_metadata.inspect} for '#{target}' but no MIR::AllocMark")
        next
      end

      container_alloc = T.must(T.must(allocs[target]).first).alloc

      # Check primary allocator.
      if alloc_metadata.primary
        op_alloc = alloc_metadata.primary
        if op_alloc != container_alloc
          @errors << error(:INLINE_ALLOC_MISMATCH, target,
            "operation uses :#{op_alloc} but container '#{target}' is :#{container_alloc}")
        end
      end

      # Check key/value allocators: frame-allocated stored data in a heap
      # container = use-after-free when the frame rewinds.
      [
        InlineStoredAllocCheck.new(label: :key_alloc, alloc: alloc_metadata.key_alloc),
        InlineStoredAllocCheck.new(label: :val_alloc, alloc: alloc_metadata.value_alloc),
      ].each do |stored|
        stored_alloc = stored.alloc
        next unless stored_alloc
        if MIR::Placement.explicit_frame?(stored_alloc) && MIR::Placement.explicit_heap?(container_alloc)
          @errors << error(:INLINE_ALLOC_MISMATCH, target,
            "#{stored.label} is :frame but container '#{target}' is :heap " \
            "(stored data will dangle after frame rewind)")
        end
      end
    end
  end

  # CROSS_FRAME_PARAM_ALLOC: an allocator-bearing structural op targeting a pointer-passed
  # parameter must not use the `:frame` allocator. Pointer-passed params
  # (MUTABLE collection / `*T` Zig type) carry a lifetime that extends
  # past the current function's mark/restore -- a frame allocation here
  # would die before the binding it serves, producing a cross-frame UAF.
  #
  # Independently re-derives "is this param pointer-passed?" from the
  # MIR-level Zig type (prefix `*`) so the check is decoupled from
  # mir_lowering's function-context collection-param set. Defense in depth:
  # if lowering's `resolve_alloc_sym` or escape_analysis's Condition 9
  # ever regresses, this catches the resulting bad MIR before codegen.
  sig { params(metadata_nodes: T::Array[MIR::Node], fn_def: MIR::FnDef).void }
  def verify_cross_frame_param_alloc!(metadata_nodes, fn_def)
    return if fn_def.params.nil? || fn_def.params.empty?

    # `pointer_passed` flag is set on MIR::Param at lowering time. Collection
    # params lower to `anytype` (polymorphic) so we can't read pointer-pass
    # status from the Zig type string alone — the lowering tags it explicitly.
    pointer_passed = fn_def.params.each_with_object(Set.new) do |p, set|
      set << p.name.to_s if p.respond_to?(:pointer_passed) && p.pointer_passed
    end
    return if pointer_passed.empty?

    metadata_nodes.each do |node|
      metadata = allocator_metadata_for(node)
      next unless metadata && !metadata.empty?
      target = allocator_metadata_target(node).to_s
      next unless pointer_passed.include?(target)

      metadata.each do |alloc_key, alloc_sym|
        next unless alloc_sym == :frame
        @errors << error(:CROSS_FRAME_PARAM_ALLOC, target,
          "operation #{alloc_key} is :frame but '#{target}' is a pointer-passed " \
          "parameter (lifetime extends past this function's frame mark; " \
          "buffer would dangle on return). Use :heap.")
      end
    end
  end

  # ALLOC_CLEANUP_MISMATCH: allocator at AllocMark must match allocator in Cleanup.
  #
  # Every binding has a single allocator for its entire lifetime (INV-1). If the
  # allocator used to create a value (:heap/:frame on AllocMark) differs from the
  # allocator used to free it (:alloc in cleanup_entry), the generated Zig will
  # call heapAlloc().free() on frame memory or vice versa -> runtime crash.
  #
  # Only checks bindings that have BOTH an AllocMark and a Cleanup. Bindings with
  # only a Cleanup indicate a missing AllocMark -- every locally-allocated binding
  # (including TAKES params via insert_takes_drops! and heap carry vars via
  # insert_drop!) must have a corresponding AllocMark. A Cleanup with no AllocMark
  # is a compiler bug: the allocation event is invisible to the checker, so
  # ALLOC_CLEANUP_MISMATCH cannot fire even if the allocators diverge.
  sig { params(allocs: AllocMarksByName, cleanups: CleanupMarksByName, errdefer_destroy_names: NameSet, transfers: NameSet).void }
  def verify_alloc_cleanup_match!(allocs, cleanups, errdefer_destroy_names = Set.new, transfers = Set.new)
    allocs.each do |name, alloc_marks|
      next unless cleanups.key?(name)

      alloc_sym   = T.must(alloc_marks.first).alloc
      cleanup_sym = T.must(T.must(cleanups[name]).first).cleanup_entry.alloc

      if alloc_sym != cleanup_sym
        @errors << error(:ALLOC_CLEANUP_MISMATCH, name,
          "allocated with :#{alloc_sym} but cleanup uses :#{cleanup_sym}")
      end

      # INV-COPY-CLEANUP: primitives and Id<T> (value types that can never own
      # heap memory) must not get a Cleanup node. If they do, needs_explicit_cleanup?
      # or visit_CopyNode missed the gate.
      if (ti = T.must(alloc_marks.first).type_info)
        no_caps = !ti.any_sync? && !ti.multiowned? && !ti.shared? && !ti.heap_ptr?
        if no_caps && (ti.primitive? || ti.id_handle?)
          @errors << error(:COPY_CLEANUP, name,
            "cleanup emitted for value type #{ti} (primitive or Id<T>) that can never " \
            "own heap memory -- needs_explicit_cleanup? or visit_CopyNode missed the gate")
        end
      end
    end

    # CLEANUP_WITHOUT_ALLOC: every binding with a Cleanup must also have an
    # AllocMark. A missing AllocMark means the allocation event was not emitted
    # (compiler bug in MIRPass/insert_drop!/insert_takes_drops!) -- the checker
    # cannot verify allocator consistency for this binding.
    cleanups.each do |name, _cleanup_nodes|
      next if allocs.key?(name)
      @errors << error(:CLEANUP_WITHOUT_ALLOC, name,
        "MIR::Cleanup present but no MIR::AllocMark (allocation event missing from MIR)")
    end

    # TRANSFER_WITHOUT_ALLOC: a transfer marker is only meaningful if the value
    # it transfers had an allocation event. Otherwise TransferMark can mask an
    # untracked ownership path.
    transfers.each do |name|
      next if allocs.key?(name)
      @errors << error(:TRANSFER_WITHOUT_ALLOC, name,
        "MIR::TransferMark present but no MIR::AllocMark (transfer event missing allocation source)")
    end

    # ALLOC_WITHOUT_CLEANUP: every HEAP AllocMark must have a Cleanup, ErrCleanup,
    # ErrDeferStmt(DestroyPtr), or explicit TransferMark. Frame allocations are
    # freed by the arena rewind and do not require an explicit cleanup node.
    # Exception: @boxed field temps use ErrDeferStmt(DestroyPtr) (errdefer_destroy_names).
    allocs.each do |name, alloc_marks|
      next if cleanups.key?(name)
      next if errdefer_destroy_names.include?(name)
      next if transfers.include?(name)
      next if alloc_marks.all? { |m| MIR::Placement.frame?(m.alloc) }
      @errors << error(:ALLOC_WITHOUT_CLEANUP, name,
        "AllocMark with no Cleanup, ErrCleanup, ErrDeferStmt(DestroyPtr), or TransferMark -- leaked allocation")
    end
    nil
  end

  # CLEANUP_REQUIRED_WITHOUT_FINALIZER: `ALLOC_WITHOUT_CLEANUP` deliberately
  # allows frame AllocMarks with no Cleanup because plain frame allocations are
  # arena-rewound. That is not enough for values whose Type owns cleanup-bearing
  # internals (collections, resources, RC handles, sync wrappers, recursive
  # cleanup shapes). For those, a checker-visible finalizer or transfer is
  # required regardless of allocator.
  sig do
    params(
      allocs: AllocMarksByName,
      cleanups: CleanupMarksByName,
      errdefer_destroy_names: NameSet,
      transfers: NameSet,
    ).void
  end
  def verify_cleanup_required_finalizers!(allocs, cleanups, errdefer_destroy_names, transfers)
    allocs.each do |name, marks|
      next if cleanups.key?(name)
      next if errdefer_destroy_names.include?(name)
      next if transfers.include?(name)

      required_mark = marks.find { |mark| alloc_mark_type_requires_finalizer?(mark) }
      next unless required_mark

      @errors << error(:CLEANUP_REQUIRED_WITHOUT_FINALIZER, name,
        "AllocMark type #{required_mark.type_info} requires cleanup, but no Cleanup, ErrCleanup, " \
        "ErrDeferStmt(DestroyPtr), or TransferMark closes the ownership path")
    end
    nil
  end

  sig { params(mark: MIR::AllocMark).returns(T::Boolean) }
  def alloc_mark_type_requires_finalizer?(mark)
    ti = mark.type_info
    return false if ti.untyped?
    return false if ti.rodata? || ti.borrowed_reference?

    ti.needs_cleanup?(@schema_lookup)
  rescue StandardError
    false
  end

  sig { params(nodes: T::Array[MIR::Node], transfers: T::Set[String], allocs: AllocMarksByName).void }
  def verify_call_contracts!(nodes, transfers, allocs)
    nodes.each do |node|
      case node
      when MIR::Call
        verify_callable_contract!(node.callable_contract, node.callee.to_s, "MIR::Call", transfers, allocs)
      when MIR::RuntimeCall
        verify_callable_contract!(node.spec.callable_contract, node.spec.callee, "MIR::RuntimeCall", transfers, allocs)
      when MIR::TailCall
        verify_callable_contract!(node.callable_contract, node.callee.to_s, "MIR::TailCall", transfers, allocs)
      when MIR::MethodCall
        verify_callable_contract!(node.callable_contract, node.method.to_s, "MIR::MethodCall", transfers, allocs)
      end
    end
    nil
  end

  sig { params(contract: T.nilable(MIR::CallableContract), label: String, node_kind: String, transfers: NameSet, allocs: AllocMarksByName).void }
  def verify_callable_contract!(contract, label, node_kind, transfers, allocs)
    unless contract.is_a?(MIR::CallableContract)
      @errors << error(:MIR_CALL_NO_CONTRACT, label,
        "#{node_kind} has no typed callable/effect contract; argument ownership is unverifiable")
      return
    end

    sig = contract.signature
    unless sig.is_a?(FunctionSignature)
      @errors << error(:MIR_CALL_NO_CONTRACT, label,
        "#{node_kind} callable contract does not carry a FunctionSignature")
      return
    end

    ownership = contract.ownership_contract
    unless ownership.is_a?(MIR::OwnershipContract)
      @errors << error(:IMPLICIT_OWNERSHIP_TRANSFER, label,
        "#{node_kind} callable contract has no typed ownership contract")
      return
    end

    if sig.params.length < contract.checked_arg_count
      @errors << error(:MIR_CALL_NO_CONTRACT, label,
        "#{node_kind} callable contract covers #{sig.params.length} params but callsite has #{contract.checked_arg_count} args")
    end

    if function_signature_takes_ownership?(sig, contract.checked_arg_count) && !ownership.covers_consuming_params
      @errors << error(:IMPLICIT_OWNERSHIP_TRANSFER, label,
        "#{node_kind} target declares TAKES/consuming params but concrete consumed bindings are absent")
    end

    verify_ownership_contract_operands!(
      ownership,
      "#{node_kind} ownership_contract",
      transfers,
      require_operands: function_signature_takes_ownership?(sig, contract.checked_arg_count),
    )
    check_consumed_allocators_match_sink!(contract, ownership.owned_operand_names, allocs)
    nil
  end

  sig { params(contract: MIR::OwnershipContract, label: String, transfers: T::Set[String], require_operands: T::Boolean).void }
  def verify_ownership_contract_operands!(contract, label, transfers, require_operands: false)
    if contract.operands.empty?
      if require_operands
        @errors << error(:OWNERSHIP_CONSUMPTION_OPERAND_MISSING, label,
          "#{label} covers a consuming call but has no operand provenance")
      end
      return
    end

    contract.operands.each do |operand|
      next if operand.kind == :non_owning

      if operand.borrowed
        if require_operands
          @errors << error(:OWNERSHIP_CONSUMPTION_BORROWED_OPERAND, operand.name || label,
            "#{label} tries to consume borrowed operand from #{operand.source}")
        end
        next
      end

      name = operand.name
      if name.nil? || name.empty?
        @errors << error(:OWNERSHIP_CONSUMPTION_OPERAND_MISSING, label,
          "#{label} has an ownership operand with no tracked binding")
        next
      end

      unless transfers.include?(name)
        @errors << error(:OWNERSHIP_CONTRACT_WITHOUT_TRANSFER, name,
          "#{label} consumes '#{name}' but no MIR::TransferMark exists for that binding")
      end
    end
    nil
  end

  sig { params(sig: FunctionSignature, checked_arg_count: Integer).returns(T::Boolean) }
  def function_signature_takes_ownership?(sig, checked_arg_count)
    sig.params.first(checked_arg_count).any? { |p| p.respond_to?(:takes) && p.takes }
  end

  # INV-EXPLICIT-OWNERSHIP: registry metadata says a call shape can transfer
  # ownership; the ownership_contract says which concrete lowered bindings are
  # consumed at this callsite. Without that binding list, TransferMark/Cleanup
  # verification cannot prove leak/double-free safety.
  sig { params(nodes: T::Array[MIR::Node], transfers: NameSet, allocs: AllocMarksByName).void }
  def verify_explicit_ownership_contracts!(nodes, transfers, allocs)
    nodes.each do |node|
      next unless node.respond_to?(:ownership_contract)
      contract = T.unsafe(node).ownership_contract
      next unless stdlib_takes_ownership?(node) || contract.is_a?(MIR::OwnershipContract) && !contract.empty?

      unless contract.is_a?(MIR::OwnershipContract)
        @errors << error(:IMPLICIT_OWNERSHIP_TRANSFER, ownership_node_name(node),
          "ownership_contract must be MIR::OwnershipContract; Hash/nil contracts make ownership unverifiable")
        next
      end

      consumes = ownership_contract_consumes(contract)
      if stdlib_takes_ownership?(node) && !ownership_contract_present?(contract)
        @errors << error(:IMPLICIT_OWNERSHIP_TRANSFER, ownership_node_name(node),
          "stdlib_def declares a TAKES/consuming parameter but ownership_contract is absent; " \
          "MIRChecker cannot prove whether this call consumes an owned binding")
      end

      verify_ownership_contract_operands!(
        contract,
        "ownership_contract",
        transfers,
        require_operands: stdlib_takes_ownership?(node),
      )
      check_consumed_allocators_match_sink!(node, consumes, allocs)
    end
    nil
  end

  # INV-FINALIZED-OWNERSHIP-SURFACE: by the time MIRChecker runs, ownership
  # must be represented by the closed Owned* fact surface. Node-specific fields
  # like RegistryCall#allocs, Call#owned_return, MethodCall#owned_result_alloc, or
  # callable/stdlib TAKES side channels are lowering inputs only. If they remain
  # authoritative here, the checker is forced to infer ownership through many
  # unrelated protocols and memory bugs can slip through opaque code.
  sig { params(nodes: T::Array[MIR::Node], facts: T::Array[MIR::Node]).void }
  def verify_ownership_surfaces_finalized!(nodes, facts)
    facts_seen = !facts.empty?
    fact_sources = T.let(Set.new, T::Set[String])
    facts.each do |fact|
      source = ownership_fact_source(fact)
      fact_sources.add(source) if source
    end
    nodes.each do |node|
      case node
      when MIR::Call
        next unless node.owned_return? || callable_contract_consumes?(node.callable_contract)
        next if facts_seen && ownership_fact_covers_node?(fact_sources, node)

        @errors << error(:OWNERSHIP_FACT_REQUIRED, node.callee.to_s,
          "MIR::Call carries ownership through owned_return/callable_contract. " \
          "Finalize call ownership into OwnedCreate/OwnedTransfer/OwnedReturn facts.")
      when MIR::RuntimeCall
        next unless node.owned_return? || callable_contract_consumes?(node.spec.callable_contract)
        next if facts_seen && ownership_fact_covers_node?(fact_sources, node)

        @errors << error(:OWNERSHIP_FACT_REQUIRED, node.spec.callee,
          "MIR::RuntimeCall carries ownership through owned_return/callable_contract. " \
          "Finalize call ownership into OwnedCreate/OwnedTransfer/OwnedReturn facts.")
      when MIR::MethodCall
        next unless node.owned_result_alloc || callable_contract_consumes?(node.callable_contract)
        next if facts_seen && ownership_fact_covers_node?(fact_sources, node)

        @errors << error(:OWNERSHIP_FACT_REQUIRED, node.method.to_s,
          "MIR::MethodCall carries ownership through owned_result_alloc/callable_contract. " \
          "Finalize method ownership into OwnedCreate/OwnedTransfer/OwnedStore facts.")
      when MIR::RegistryCall, MIR::IndexedStore
        next unless registry_ownership_side_channel?(node)
        next if stdlib_takes_ownership?(node) && ownership_surface_has_no_owned_operands?(node)
        next if facts_seen && ownership_fact_covers_node?(fact_sources, node)

        @errors << error(:OWNERSHIP_FACT_REQUIRED, ownership_node_name(node),
          "#{node.class.name} carries allocator or ownership effects through registry metadata. " \
          "Finalize it into Owned* facts before MIRChecker.")
      when MIR::ShardedMapPut, MIR::ReassignWithCleanup
        next unless stdlib_takes_ownership?(node)
        next if ownership_consumption_has_no_owned_operands?(node)
        next if facts_seen && ownership_fact_covers_node?(fact_sources, node)

        @errors << error(:OWNERSHIP_FACT_REQUIRED, ownership_node_name(node),
          "#{node.class.name} consumes or replaces owned data through node-specific fields. " \
          "Finalize the store/reassign into OwnedStore/OwnedTransfer/OwnedDestroy facts.")
      when MIR::BgBlock
        next if facts_seen && ownership_fact_covers_node?(fact_sources, node)

        @errors << error(:OWNERSHIP_FACT_REQUIRED, ownership_node_name(node),
          "MIR::BgBlock creates/captures promise-owned state across an execution boundary. " \
          "Finalize BG ownership into OwnedCreate/OwnedTransfer/OwnedReturn/OwnedDestroy facts.")
      end
    end
    nil
  end

  sig { params(nodes: T::Array[MIR::Node]).void }
  def verify_execution_boundary_facts!(nodes)
    nodes.each do |node|
      case node
      when MIR::BgBlock
        verify_execution_boundary_fact!(node.boundary_fact, "MIR::BgBlock")
        if (!node.run_body || node.run_body.empty?) && !node.fsm_structure
          @errors << error(:BOUNDARY_FACT_REQUIRED, "MIR::BgBlock",
            "FSM-consumed BG body has no typed FsmStructure; rendered execution-boundary code is unverifiable")
        end
        MIRChecker.check_fsm_structure!(node.fsm_structure) if node.fsm_structure
      when MIR::StreamSpawn
        verify_execution_boundary_fact!(node.boundary_fact, "MIR::StreamSpawn")
      when MIR::DoBlock
        facts = node.boundary_facts
        unless facts.is_a?(Array) && facts.all? { |f| f.is_a?(MIR::ExecutionBoundaryFact) }
          @errors << error(:BOUNDARY_FACT_REQUIRED, "MIR::DoBlock",
            "MIR::DoBlock has no typed ExecutionBoundaryFact array for its branches")
          next
        end
        expected = node.branch_bodies&.length || 0
        if facts.length != expected
          @errors << error(:BOUNDARY_FACT_REQUIRED, "MIR::DoBlock",
            "MIR::DoBlock has #{facts.length} boundary facts for #{expected} branch bodies")
        end
        facts.each do |fact|
          verify_execution_boundary_fact!(fact, "MIR::DoBlock")
        end
      end
    end
    nil
  end

  sig { params(fact: T.nilable(MIR::ExecutionBoundaryFact), label: String).void }
  def verify_execution_boundary_fact!(fact, label)
    unless fact
      @errors << error(:BOUNDARY_FACT_REQUIRED, label,
        "#{label} has no typed ExecutionBoundaryFact")
      return
    end

    unless [:bg, :bg_stream, :do_branch, :stream_spawn].include?(fact.kind)
      @errors << error(:BOUNDARY_FACT_REQUIRED, label,
        "#{label} has invalid boundary kind #{fact.kind.inspect}")
    end
    unless [:local, :pinned, :parallel].include?(fact.dispatch)
      @errors << error(:BOUNDARY_FACT_REQUIRED, label,
        "#{label} has invalid boundary dispatch #{fact.dispatch.inspect}")
    end

    fact.captures.each do |capture|
      next unless fact.dispatch == :parallel
      next if capture.parallel_safe

      reason = capture.forbidden_reason || :not_parallel_safe
      @errors << error(:BOUNDARY_CAPTURE_NOT_PARALLEL_SAFE, capture.name,
        "capture '#{capture.name}' is not safe for @parallel dispatch " \
        "(storage=#{capture.storage.inspect}, sync=#{capture.sync.inspect}, reason=#{reason.inspect})")
    end
    nil
  end

  sig { params(contract: T.nilable(MIR::CallableContract)).returns(T::Boolean) }
  def callable_contract_consumes?(contract)
    return false unless contract.is_a?(MIR::CallableContract)
    !ownership_contract_consumes(contract.ownership_contract).empty?
  end

  sig { params(node: RegistryOwnershipNode).returns(T::Boolean) }
  def registry_ownership_side_channel?(node)
    sig = FunctionSignature.unwrap(node.stdlib_def)
    if stdlib_takes_ownership?(node)
      return false if ownership_surface_has_no_owned_operands?(node)
      return true
    end

    contract = node.ownership_contract
    return true if contract.is_a?(MIR::OwnershipContract) && !contract.empty?
    return true if node.respond_to?(:owned_result_alloc) && T.unsafe(node).owned_result_alloc

    return false if node.mutating_receiver_allocator_op?

    return false unless sig

    sig.emits_allocating? == true && sig.return_type.void?
  end

  sig { params(fact_sources: T::Set[String], node: MIR::Node).returns(T::Boolean) }
  def ownership_fact_covers_node?(fact_sources, node)
    if node.respond_to?(:ownership_consumption) &&
       node.ownership_consumption.is_a?(MIR::OwnershipConsumptionFact)
      return true
    end

    fact_sources.include?(ownership_node_name(node))
  end

  sig { params(fact: MIR::Node).returns(T.nilable(String)) }
  def ownership_fact_source(fact)
    case fact
    when MIR::OwnedCreate, MIR::OwnedDestroy, MIR::OwnedTransfer,
         MIR::OwnedBorrow, MIR::OwnedStore, MIR::OwnedReturn
      fact.source.to_s
    else
      nil
    end
  end

  sig { params(node: AllocatorMetadataSource, consumes: T::Array[String], allocs: AllocMarksByName).void }
  def check_consumed_allocators_match_sink!(node, consumes, allocs)
    return if consumes.empty?
    sink_alloc = allocator_metadata_for(node)&.sink_alloc
    return unless sink_alloc

    consumes.each do |name|
      mark = allocs[name]&.first
      next unless mark
      next if mark.alloc == sink_alloc
      @errors << error(:AGGREGATE_CHILD_ALLOC_MISMATCH, name,
        "ownership_contract consumes :#{mark.alloc} binding '#{name}' into :#{sink_alloc} sink; " \
        "owned transfer allocator is incoherent")
    end
  end

  sig { params(node: MIR::Node).returns(T::Boolean) }
  def ownership_consumption_has_no_owned_operands?(node)
    fact = node.ownership_consumption
    return false unless fact.is_a?(MIR::OwnershipConsumptionFact)

    fact.operands.none? { |operand| operand.kind == :owned_binding && operand.name }
  end

  sig { params(node: OwnershipSurfaceNode).returns(T::Boolean) }
  def ownership_contract_has_no_owned_operands?(node)
    contract = case node
    when MIR::RegistryCall, MIR::IndexedStore
      node.ownership_contract
    end
    return false unless contract.is_a?(MIR::OwnershipContract)

    contract.operands.none? { |operand| operand.kind == :owned_binding && operand.name }
  end

  sig { params(node: OwnershipSurfaceNode).returns(T::Boolean) }
  def ownership_surface_has_no_owned_operands?(node)
    ownership_consumption_has_no_owned_operands?(node) ||
      ownership_contract_has_no_owned_operands?(node)
  end

  sig { params(node: MIR::Node).returns(T::Boolean) }
  def stdlib_takes_ownership?(node)
    return true if node.is_a?(MIR::ReassignWithCleanup)

    sig = node.respond_to?(:stdlib_def) ? T.unsafe(node).stdlib_def : nil
    return false unless sig
    params = sig.respond_to?(:params) ? sig.params : nil
    return true if params.respond_to?(:any?) && params.any? { |p| p.respond_to?(:takes) && p.takes }

    sig.takes_ownership?
  end

  sig { params(contract: MIR::OwnershipContract).returns(T::Array[String]) }
  def ownership_contract_consumes(contract)
    contract.owned_operand_names
  end

  sig { params(contract: MIR::OwnershipContract).returns(T::Boolean) }
  def ownership_contract_present?(contract)
    !contract.empty? || contract.covers_consuming_params
  end

  sig { params(node: MIR::Node).returns(String) }
  def ownership_node_name(node)
    return ownership_node_name(node.expr) if node.is_a?(MIR::Cast) || node.is_a?(MIR::TryExpr)
    target = case node
             when MIR::RegistryCall, MIR::IndexedStore, MIR::ShardedMapPut
               node.target_var
             end
    return target.to_s if target
    return node.spec.callee if node.is_a?(MIR::RuntimeCall)
    return node.callee.to_s if node.is_a?(MIR::Call) || node.is_a?(MIR::TailCall)
    return node.method.to_s if node.is_a?(MIR::MethodCall)
    return "MIR::BgBlock" if node.is_a?(MIR::BgBlock)
    return "MIR::StreamSpawn" if node.is_a?(MIR::StreamSpawn)
    reason = case node
             when MIR::RegistryCall, MIR::Noop then node.reason
             end
    reason ? reason.to_s : node.class.name.to_s
  end

  # FRAME_NO_REWIND: every iteration-scoped frame allocation must be inside a
  # loop restore, and every restored loop may contain only iteration-scoped
  # frame allocations.
  #
  # Post-lowering check: walks the MIR tree looking for loops that contain
  # frame AllocMarks or allocator-bearing frame expressions but lack mark_per_iter.
  # Without per-iteration rewind, frame arena grows unboundedly across iterations.
  sig { params(body: T::Array[MIR::Node]).void }
  def verify_frame_rewind!(body)
    each_frame_rewind_node(body) do |stmt|
      next unless stmt.is_a?(MIR::WhileStmt) || stmt.is_a?(MIR::ForStmt)

        # Structural check: verify the actual DeferStmt(restoreLoopMark) is present,
        # not a flag. This catches lowerer bugs where mark_per_iter is set but the
        # defer was not emitted, and unifies the check with the actual MIR structure.
        has_restore = body_has_loop_restore?(stmt.body)
        if !stmt.tight && !has_restore
          if body_has_iteration_frame_alloc?(stmt.body)
            @errors << error(:FRAME_NO_REWIND, @fn_name,
              "loop body has iteration-scoped frame allocations but no restoreLoopMark defer")
          end
        elsif has_restore
          if body_has_non_iteration_frame_alloc?(stmt.body)
            @errors << error(:FRAME_NO_REWIND, @fn_name,
              "loop restore encloses frame allocations not scoped to one iteration")
          end
        end
    end
  end

  sig { params(root: T.nilable(MIR::NodeRoot), block: T.proc.params(arg0: MIR::Node).void).void }
  def each_frame_rewind_node(root, &block)
    MIR.each_node_until(root, ->(node) { frame_rewind_boundary?(node) }, &block)
  end

  sig { params(node: MIR::Node).returns(T::Boolean) }
  def frame_rewind_boundary?(node)
    node.is_a?(MIR::BgBlock) || node.is_a?(MIR::LambdaExpr)
  end

  # Does this statement list contain a per-iteration loop restore?
  sig { params(stmts: T::Array[MIR::Node]).returns(T::Boolean) }
  def body_has_loop_restore?(stmts)
    found = T.let(false, T::Boolean)
    each_loop_local_node(stmts) do |node|
      next unless node.is_a?(MIR::DeferStmt)
      body = node.body
      found = true if body.is_a?(MIR::MethodCall) && body.method == "restoreLoopMark"
    end
    found
  end

  # Does this statement list contain iteration-scoped frame allocations,
  # recursing into branch/block nodes but stopping at nested loop and
  # fiber/lambda boundaries.
  sig { params(stmts: T.nilable(MIR::NodeRoot)).returns(T::Boolean) }
  def body_has_iteration_frame_alloc?(stmts)
    body_has_frame_alloc_scope?(stmts) { |scope| scope == :iteration }
  end

  sig { params(stmts: T.nilable(MIR::NodeRoot)).returns(T::Boolean) }
  def body_has_non_iteration_frame_alloc?(stmts)
    body_has_frame_alloc_scope?(stmts) { |scope| scope != :iteration }
  end

  # Does this statement list contain frame allocations matching a scope
  # predicate, recursing into all
  # branch/block nodes (IfStmt, SwitchStmt, IfChain, ScopeBlock, BlockExpr)
  # but stopping at nested loop and fiber/lambda boundaries.
  # Mirrors the same traversal used by check_loop_rewind! so both methods
  # see the same nodes -- no special-cased paths.
  sig { params(stmts: T.nilable(MIR::NodeRoot), block: T.proc.params(arg0: Symbol).returns(T::Boolean)).returns(T::Boolean) }
  def body_has_frame_alloc_scope?(stmts, &block)
    found = T.let(false, T::Boolean)
    each_loop_local_node(stmts) do |node|
      next unless node.is_a?(MIR::AllocMark)
      alloc = node.alloc
      next unless MIR::Placement.frame?(alloc)

      scope = T.unsafe(node).scope
      scope = scope.is_a?(Symbol) ? scope : :unknown
      found ||= block.call(scope)
    end
    found
  end

  sig { params(root: T.nilable(MIR::NodeRoot), block: T.proc.params(arg0: MIR::Node).void).void }
  def each_loop_local_node(root, &block)
    MIR.each_node_until(root, ->(node) { loop_local_boundary?(node) }, &block)
  end

  sig { params(node: MIR::Node).returns(T::Boolean) }
  def loop_local_boundary?(node)
    node.is_a?(MIR::WhileStmt) || node.is_a?(MIR::ForStmt) ||
      node.is_a?(MIR::BgBlock) || node.is_a?(MIR::LambdaExpr)
  end

  # Does this MIR expression node perform a frame allocation?
  # Backing-store mutations (mutates_receiver) are excluded: they extend an
  # existing container's backing store under that container's own allocator.
  # The container's outer-scope rewind handles cleanup — per-iteration rewind
  # would corrupt accumulated data. Only NEW ephemeral objects need loop marks.
  sig { params(expr: T.nilable(MIR::Node)).returns(T::Boolean) }
  def expr_has_frame_alloc?(expr)
    return false unless expr
    metadata = allocator_metadata_for(expr)
    if metadata && !metadata.empty?
      return false if expr.respond_to?(:mutating_receiver_allocator_op?) &&
                      T.unsafe(expr).mutating_receiver_allocator_op?
      return metadata.any_frame?
    end

    case expr
    when MIR::DupeSlice, MIR::ConcatStr, MIR::HeapCreate, MIR::AllocSlice,
         MIR::ContainerInit, MIR::MakeList, MIR::DeepCopy, MIR::CapWrap
      MIR::Placement.frame?(expr.alloc)
    else
      false
    end
  end

  # Format an MIR-checker error string. The on-the-wire shape is
  # preserved (`[KIND] fn::name -- msg`) so anyone reading checker
  # output keeps their muscle memory. The kind, however, MUST be
  # registered in DiagnosticRegistry — that's the unification point.
  # Adding a new MIR check now requires adding a registry entry,
  # which means `clear explain <CODE>` documents it for free.
  sig { params(kind: Symbol, name: T.nilable(T.any(String, Symbol)), msg: String).returns(String) }
  def error(kind, name, msg)
    unless DiagnosticRegistry.known?(kind)
      raise "Internal Compiler Error: unregistered MIR diagnostic code :#{kind}. " \
            "Add an entry in src/ast/diagnostic_registry.rb (category: :mir)."
    end
    "[#{kind}] #{@fn_name}::#{name} -- #{msg}"
  end

  # ================================================================
  # UNHOISTED_ALLOC -- every allocating expression must be a Let init
  # ================================================================
  #
  # INV-H: every MIR node that allocates memory must appear as the direct
  # init of a MIR::Let.  If an allocating expression appears in argument,
  # return, field-value, or any other sub-expression position it has no
  # AllocMark, so the checker cannot verify its lifetime, allocator
  # consistency, or cleanup.
  #
  # Allocating result types:
  #   HeapCreate, owned-return Call, non-mutating allocator-bearing registry calls,
  #   DupeSlice, HeapCreate, ConcatStr, AllocSlice, MakeList, CapWrap,
  #   SharePromote,
  #   DeepCopy (strategy != :passthrough), ContainerInit (alloc != nil)

  sig { params(body: T::Array[MIR::Node]).returns(T::Array[MIR::Node]) }
  def verify_unhoisted_allocs!(body)
    check_stmts_for_unhoisted(body)
    body
  end

  sig { params(stmts: T::Array[MIR::Node]).void }
  def check_stmts_for_unhoisted(stmts)
    stmts.each { |s| check_stmt_for_unhoisted(s) }
  end

  sig { params(node: T.nilable(MIR::Node)).void }
  def check_stmt_for_unhoisted(node)
    return unless node.is_a?(MIR::Emittable)

    case node
    when MIR::Let
      check_owned_expr_position_for_unhoisted(node.init, "Let initializer")
    when MIR::ReassignWithCleanup
      check_owned_expr_position_for_unhoisted(node.value, "ReassignWithCleanup value")
    when MIR::DiscardOwned
      check_owned_expr_position_for_unhoisted(node.expr, "DiscardOwned expression")
    when MIR::IfBindStmt
      node.bindings&.each do |binding|
        next unless binding.is_a?(Hash)
        expr = binding[:expr]
        capture = binding[:capture]
        if capture && binder_capture_cleanup?(node.then_body, capture.to_s)
          check_owned_expr_position_for_unhoisted(expr, "IfBind capture")
        else
          check_expr_for_unhoisted(expr)
        end
      end
      node.body_slots.each { |slot| check_stmts_for_unhoisted(slot.body) }
      return
    when MIR::WhileStmt
      if node.capture && (binder_capture_cleanup?(node.body, node.capture.to_s) || block_expr_transfers_result?(node.cond))
        check_owned_expr_position_for_unhoisted(node.cond, "While capture")
      else
        check_expr_for_unhoisted(node.cond)
      end
      check_expr_for_unhoisted(node.update) if node.update
      node.body_slots.each { |slot| check_stmts_for_unhoisted(slot.body) }
      return
    else
      node.child_exprs.each { |expr| check_expr_for_unhoisted(expr) }
    end
    node.body_slots.each { |slot| check_stmts_for_unhoisted(slot.body) }
    nil
  end

  sig { params(body: T::Array[MIR::Node], name: String).returns(T::Boolean) }
  def binder_capture_cleanup?(body, name)
    body.any? { |stmt| stmt.is_a?(MIR::Cleanup) && stmt.name.to_s == name }
  end

  sig { params(expr: MIR::Emittable).returns(T::Boolean) }
  def block_expr_transfers_result?(expr)
    return false unless expr.is_a?(MIR::BlockExpr)

    expr.body.any? { |stmt| stmt.is_a?(MIR::TransferMark) && stmt.target == :block_result }
  end

  sig { params(expr: T.nilable(MIR::Node), context: String).void }
  def check_owned_expr_position_for_unhoisted(expr, context)
    return unless expr
    check_expr_sources_for_unhoisted(expr, context, owned_position: true)
  end

  # Check expr for allocating nodes outside an explicit ownership-binding
  # position. Direct owned positions are verified by
  # `check_owned_expr_position_for_unhoisted`, not by node-provided exemptions.
  sig { params(expr: T.nilable(MIR::Node)).void }
  def check_expr_for_unhoisted(expr)
    return unless expr
    check_expr_sources_for_unhoisted(expr, "expression", owned_position: false)
  end

  sig { params(expr: T.nilable(MIR::Node), context: String, owned_position: T::Boolean).void }
  def check_expr_sources_for_unhoisted(expr, context, owned_position:)
    return unless expr
    unless expr.is_a?(MIR::Emittable)
      return
    end

    if allocating_expr?(expr)
      unless owned_position
        kind = expr.class.name.split("::").last
        @errors << error(:UNHOISTED_ALLOC, @fn_name,
          "#{kind} in non-Let-init position (must be hoisted to a named variable)")
        return  # one error per site -- don't recurse into nested allocs
      end
    end

    owned_sources = T.let(expr.owned_position_source_exprs.to_set, T::Set[MIR::Emittable])
    expr.child_exprs.each do |child|
      check_expr_sources_for_unhoisted(child, context, owned_position: owned_sources.include?(child))
    end
    expr.body_slots.each { |slot| check_stmts_for_unhoisted(slot.body) }
    nil
  end

  sig { params(expr: T.nilable(MIR::Node)).returns(T::Boolean) }
  def allocating_expr?(expr)
    effect = MIR::OwnershipEffect.of(expr)
    effect.produces_owned && effect.requires_hoist && (!effect.alloc || VALID_ALLOCATORS.include?(effect.alloc))
  end

  private :check_linear_expr_uses!,
    :check_aggregate_expr!,
    :check_aggregate_stmts!,
    :check_linear_branch_join!,
    :check_linear_stmt!,
    :check_linear_stmts!,
    :check_nested_linear_expr_bodies!,
    :check_reassign_cleanup_alloc!,
    :cleanup_source_owns_value?,
    :linear_alloc!,
    :linear_merge_branch_states!,
    :linear_move_mark!,
    :linear_register_cleanup!,
    :linear_register_err_cleanup!,
    :linear_register_finalizer!,
    :linear_release!,
    :linear_require_same_state!,
    :linear_transfer!,
    :prune_scope_locals!,
    :alloc_mark_type_requires_finalizer?,
    :stdlib_owned_fixed_return?,
    :structural_consumed_names,
    :verify_aggregate_owned_children!,
    :verify_alloc_marks_typed!,
    :verify_allocating_lets_marked!,
    :verify_cleanup_required_finalizers!,
    :verify_if_bind_capture_cleanup_ownership!,
    :verify_no_structural_rc_handle_copies!,
    :verify_cleanup_sources_in_scope!,
    :verify_cleanup_sources_own_values!,
    :verify_err_cleanup_transfers!,
    :verify_guarded_transfers_moved!,
    :verify_heap_create_single_indirection!,
    :verify_linear_ownership!,
    :verify_move_mark_scope!,
    :verify_owned_result_alloc_marks!,
    :verify_owned_return_alloc_marks!,
    :verify_ownership_consumption_operands!,
    :verify_return_transfers_heap!,
    :verify_structural_ownership_contracts!
  private :collect_linear_expr_ident_names
  private :copy_linear_state!
  private :each_heap_create
  private :escaping_transfer_target?
  private :linear_exit_scope!
  private :normalize_guarded_conditional_releases!
  private :owned_return_init?
  private :ownership_consumption_operand_names
  private :ownership_registry_errors
  private :ownership_source_expr
  private :stdlib_owned_return?
  private :value_constructor_expr?

end
