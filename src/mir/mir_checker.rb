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
#   INV-INLINE-CONTRACT: InlineZig/RawZig nodes that call CheatLib.*
#     functions with ownership effects must declare stdlib_def so the
#     checker can see those effects. Without it, the node is opaque.
#
#   INV-EXPLICIT-OWNERSHIP: Any stdlib/RawZig node that transfers
#     ownership must declare the concrete binding names in
#     ownership_contract.consumes. Registry metadata says the call shape
#     can consume; the contract says this lowered call does consume `x`.
#     Each consumed binding must have a matching MIR::TransferMark.
#
#   INV-INLINE-ALLOC-MATCH: When an InlineZig operation uses an allocator
#     (:alloc/:key_alloc/:val_alloc), that allocator must match the
#     container binding's AllocMark allocator. Frame data stored in a
#     heap container becomes a dangling pointer after frame rewind.
#
#   INV-ALLOCATOR-CLOSED-SET: MIR allocator facts are closed to :heap
#     and :frame. Any other symbol means a downstream pass is carrying
#     placement side-channel state instead of finalized placement.
#
#   INV-FRAME-REWIND: Every loop body that frame-allocates must contain
#     a restoreLoopMark defer to prevent unbounded frame arena growth.
#
#   INV-COPY-CLEANUP: A Cleanup paired with an AllocMark whose type_info is
#     a primitive or Id<T> (with no sync/rc capability) is a compiler bug:
#     value types that never own heap memory must not receive cleanup nodes.
#
#   INV-CROSS-FRAME-PARAM-ALLOC: When an InlineZig op targets a parameter
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
require_relative "pass_state"

class MIRChecker
    extend T::Sig

  OWNERSHIP_FIELD_NAMES = T.let(
    Set[:alloc, :allocs, :cleanup_entry, :ownership_contract, :owned_return, :owned_result_alloc, :callable_contract, :target_var],
    T::Set[Symbol],
  )

  LINEAR_STATEMENT_NODE_TYPES = T.let([
    MIR::AllocMark, MIR::AssertStmt, MIR::BatchWindowFlush, MIR::BatchWindowPush,
    MIR::BgBlock, MIR::BreakStmt, MIR::CatchWrapper, MIR::Cleanup,
    MIR::Comment, MIR::ContinueStmt, MIR::DeferStmt, MIR::DiscardOwned,
    MIR::DoBlock, MIR::EnumDef, MIR::ErrCleanup, MIR::ErrDeferStmt,
    MIR::ExprStmt, MIR::FieldCleanupMark, MIR::FnDef, MIR::ForStmt,
    MIR::FrameRestore, MIR::FrameSave, MIR::FsmB1Body, MIR::FsmGenericBody,
    MIR::FsmIoBody, MIR::IfBindStmt, MIR::IfChain, MIR::IfStmt,
    MIR::Import, MIR::IndexInsert, MIR::Let, MIR::MoveMark,
    MIR::MutualThunkTrampoline, MIR::Noop, MIR::OwnedBorrow,
    MIR::OwnedCreate, MIR::OwnedDestroy, MIR::OwnedReturn,
    MIR::OwnedStore, MIR::OwnedTransfer, MIR::Panic, MIR::Pipeline,
    MIR::PolymorphicMutate, MIR::PolymorphicMutateFlow, MIR::PubConst,
    MIR::RawBc, MIR::RawZig, MIR::ReassignMark, MIR::ReassignWithCleanup,
    MIR::ReturnMark, MIR::ReturnStmt, MIR::ScopeBlock, MIR::Set,
    MIR::ShardedMapPut, MIR::SnapshotMultiTxn, MIR::SnapshotRead,
    MIR::SnapshotTransaction, MIR::Sort, MIR::StreamSpawn, MIR::StreamYield,
    MIR::StructDef, MIR::Suppress, MIR::SwitchStmt, MIR::TestDef,
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

    sig { returns(T::Array[String]) }
    def snapshot
      [
        "owned=#{@owned.to_a.sort.join(",")}",
        "released=#{@released.to_a.sort.join(",")}",
        "maybe=#{@maybe_released.to_a.sort.join(",")}",
        "cleanup=#{@cleanup_finalizers.to_a.sort.join(",")}",
        "guarded=#{@guarded_finalizers.to_a.sort.join(",")}",
        "err=#{@err_finalizers.to_a.sort.join(",")}",
        "return=#{@pending_return_transfers.to_a.sort.join(",")}",
        "block=#{@pending_block_transfers.to_a.sort.join(",")}",
        "alloc=#{@alloc_kinds.map { |k, v| "#{k}:#{v}" }.sort.join(",")}",
      ]
    end
  end

  attr_reader :errors

  AllocMarksByName = T.type_alias { T::Hash[String, T::Array[MIR::AllocMark]] }
  CleanupMarksByName = T.type_alias { T::Hash[String, T::Array[T.any(MIR::Cleanup, MIR::ErrCleanup)]] }
  NameSet = T.type_alias { T::Set[String] }

  sig { params(fn_name: T.untyped).void }
  def initialize(fn_name: nil)
    @fn_name = fn_name
    @errors = T.let([], T::Array[T.untyped])
  end

  # `strict` is retained for call-site compatibility only. MIR ownership
  # checks are always strict: an unhoisted allocation or provenance placement
  # side channel is a compiler bug, not an optional lint.
  sig { params(fn_def: MIR::FnDef, strict: T::Boolean).returns(T::Array[String]) }
  def check_fn!(fn_def, strict: false)
    @fn_name = fn_def.name
    @errors = []

    allocs = T.let({}, AllocMarksByName)
    cleanups = T.let({}, CleanupMarksByName)
    err_cleanups = T.let({}, CleanupMarksByName)
    transfers = T.let(Set.new, NameSet)
    return_transfers = T.let(Set.new, NameSet)
    errdefer_destroy_names = T.let(Set.new, NameSet)
    hpt_leaks = []
    owned_return_lets = []
    owned_result_lets = []
    inline_alloc_nodes = []
    all_zig_nodes = []  # InlineZig + RawZig -- both scanned for CheatLib contracts
    structural_ownership_nodes = []
    ownership_fact_nodes = []

    walk_mir(fn_def.body) do |node|
      if node.respond_to?(:ownership_consumption) &&
         node.ownership_consumption.is_a?(MIR::OwnershipConsumptionFact)
        structural_ownership_nodes << node
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
        # @indirect field temps use ErrDeferStmt(DestroyPtr) instead of ErrCleanup.
        # Track their names so ALLOC_WITHOUT_CLEANUP does not false-positive on them.
        if node.body.is_a?(MIR::DestroyPtr) && node.body.ptr.is_a?(MIR::Ident)
          errdefer_destroy_names << node.body.ptr.name
        end
      when MIR::Let
        owned_return_lets << node if owned_return_init?(node.init)
        owned_result_lets << node if expr_owned_result_alloc(node.init)
        if node.init.is_a?(MIR::InlineZig) && node.init.allocs
          inline_alloc_nodes << node.init
        end
        all_zig_nodes << node.init if node.init.is_a?(MIR::InlineZig)
      when MIR::ExprStmt
        scan_expr_for_hpt_leak!(node.expr, hpt_leaks)
        if node.expr.is_a?(MIR::InlineZig) && node.expr.allocs
          inline_alloc_nodes << node.expr
        end
        all_zig_nodes << node.expr if node.expr.is_a?(MIR::InlineZig)
      when MIR::DiscardOwned
        if node.expr.is_a?(MIR::InlineZig) && node.expr.allocs
          inline_alloc_nodes << node.expr
        end
        all_zig_nodes << node.expr if node.expr.is_a?(MIR::InlineZig)
      when MIR::InlineZig
        if node.allocs && !inline_alloc_nodes.include?(node)
          inline_alloc_nodes << node
        end
        all_zig_nodes << node unless all_zig_nodes.include?(node)
      when MIR::RawZig
        all_zig_nodes << node unless all_zig_nodes.include?(node)
      when MIR::LambdaExpr
        if node.fn_def
          sub = MIRChecker.new
          @errors.concat(sub.check_fn!(node.fn_def, strict: strict))
        end
      end
    end

    hpt_leaks.each { |e| @errors << e }
    verify_allocator_closed_set!(allocs, cleanups, inline_alloc_nodes)
    verify_owned_return_alloc_marks!(owned_return_lets, allocs)
    verify_owned_result_alloc_marks!(owned_result_lets, allocs)
    verify_inline_alloc_contracts!(inline_alloc_nodes, allocs, fn_def)
    verify_cross_frame_param_alloc!(inline_alloc_nodes, fn_def)
    verify_err_cleanup_transfers!(err_cleanups, transfers)
    verify_return_transfers_heap!(return_transfers, allocs)
    verify_allocating_lets_marked!(fn_def.body, allocs)
    verify_aggregate_owned_children!(fn_def.body, allocs)
    verify_alloc_cleanup_match!(allocs, cleanups, errdefer_destroy_names, transfers)
    verify_zig_contracts!(all_zig_nodes)
    verify_call_contracts!(fn_def.body, transfers, allocs)
    verify_structural_ownership_contracts!(structural_ownership_nodes, transfers, allocs)
    verify_explicit_ownership_contracts!(all_zig_nodes, transfers, allocs)
    verify_ownership_surfaces_finalized!(fn_def.body, ownership_fact_nodes)
    verify_execution_boundary_facts!(fn_def.body)
    verify_frame_rewind!(fn_def.body)
    verify_inline_alloc_targets!(inline_alloc_nodes)
    verify_unhoisted_allocs!(fn_def.body)
    verify_heap_create_single_indirection!(fn_def.body)
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
      next if marks.all? { |mark| mark.alloc == :heap }

      @errors << error(:RETURN_TRANSFER_FRAME_ALLOC, name,
        "return ownership transfer is backed by :frame allocation; escaping owned returns must be heap")
    end
  end

  sig { params(nodes: T::Array[T.untyped], transfers: T::Set[T.untyped], allocs: T::Hash[String, T::Array[T.untyped]]).void }
  def verify_structural_ownership_contracts!(nodes, transfers, allocs)
    nodes.uniq.each do |node|
      consumed = structural_consumed_names(node)
      next if consumed.empty?

      sink_alloc = if node.is_a?(MIR::ReassignWithCleanup)
        node.alloc
      elsif node.respond_to?(:resolved_allocs) && node.resolved_allocs.is_a?(Hash)
        node.resolved_allocs[:val_alloc]
      end

      consumed.each do |name|
        next unless allocs.key?(name)

        unless transfers.include?(name)
          @errors << error(:OWNERSHIP_CONTRACT_WITHOUT_TRANSFER, name,
            "structural ownership sink consumes '#{name}' but no MIR::TransferMark exists for that binding")
        end

        mark = allocs[name]&.first
        next unless mark&.alloc.is_a?(Symbol) && sink_alloc.is_a?(Symbol)
        next if mark.alloc == sink_alloc

        @errors << error(:AGGREGATE_CHILD_ALLOC_MISMATCH, name,
          "structural ownership sink consumes :#{mark.alloc} binding '#{name}' into :#{sink_alloc} sink; " \
          "owned transfer allocator is incoherent")
      end
    end
  end

  sig { params(node: T.untyped).returns(T::Array[String]) }
  def structural_consumed_names(node)
    fact = node.respond_to?(:ownership_consumption) ? node.ownership_consumption : nil
    return fact.names.map(&:to_s).uniq if fact.is_a?(MIR::OwnershipConsumptionFact)
    return [] unless stdlib_takes_ownership?(node)

    value = node.respond_to?(:value) ? node.value : nil
    return [value.name.to_s] if value.is_a?(MIR::Ident)
    if allocating_expr?(value)
      @errors << error(:IMPLICIT_OWNERSHIP_TRANSFER, ownership_node_name(node),
        "structural ownership sink takes a value, but the source owner is not a named MIR binding")
    end
    []
  end

  sig { params(body: T::Array[T.untyped]).void }
  def verify_linear_ownership!(body)
    final_state = check_linear_stmts!(body, LinearOwnershipState.new)
    final_state.pending_return_transfers.each do |name|
      @errors << error(:OWNERSHIP_UNVERIFIED_PATH, name,
        "TransferMark(:return) was emitted but no ReturnStmt consumed that ownership transfer")
    end
    nil
  end

  sig { params(stmts: T.nilable(T::Array[T.untyped]), state: LinearOwnershipState).returns(LinearOwnershipState) }
  def check_linear_stmts!(stmts, state)
    return state unless stmts.is_a?(Array)

    stmts.each do |stmt|
      break if state.terminated
      check_linear_stmt!(stmt, state)
    end
    state
  end

  sig { params(stmt: T.untyped, state: LinearOwnershipState).void }
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
    when MIR::Let
      check_linear_expr_uses!(stmt.init, state)
    when MIR::Set
      check_linear_expr_uses!(stmt.target, state)
      check_linear_expr_uses!(stmt.value, state)
    when MIR::ReassignWithCleanup
      check_linear_expr_uses!(stmt.value, state)
    when MIR::ExprStmt
      check_linear_expr_uses!(stmt.expr, state)
    when MIR::AssertStmt
      check_linear_expr_uses!(stmt.cond, state)
    when MIR::DiscardOwned
      check_linear_expr_uses!(stmt.expr, state)
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
    when MIR::IfStmt
      check_linear_expr_uses!(stmt.cond, state)
      check_linear_branch_join!(stmt.then_body, stmt.else_body, state, "if")
    when MIR::IfBindStmt
      stmt.bindings&.each do |binding|
        expr = binding.is_a?(Hash) ? binding[:expr] : nil
        check_linear_expr_uses!(expr, state)
      end
      check_linear_branch_join!(stmt.then_body, stmt.else_body, state, "if-bind")
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
    when MIR::SwitchStmt, MIR::UnionMatchStmt
      check_linear_expr_uses!(stmt.subject, state)
      states = T.let([], T::Array[LinearOwnershipState])
      stmt.arms&.each { |arm| states << linear_project_branch_state(check_linear_stmts!(arm[:body], state.copy), state, "match") }
      states << linear_project_branch_state(check_linear_stmts!(stmt.default_body, state.copy), state, "match")
      linear_merge_branch_states!(states, state, "match")
    when MIR::IfChain
      states = T.let([], T::Array[LinearOwnershipState])
      stmt.branches&.each do |branch|
        check_linear_expr_uses!(branch[:cond], state)
        states << linear_project_branch_state(check_linear_stmts!(branch[:body], state.copy), state, "if-chain")
      end
      states << linear_project_branch_state(check_linear_stmts!(stmt.default_body, state.copy), state, "if-chain")
      linear_merge_branch_states!(states, state, "if-chain")
    when MIR::DeferStmt
      check_linear_stmt!(stmt.body, state)
    when MIR::ErrDeferStmt
      check_linear_stmt!(stmt.body, state)
    when MIR::BatchWindowPush
      check_linear_expr_uses!(stmt.item_expr, state)
      check_linear_expr_uses!(stmt.value_expr, state)
    when MIR::BatchWindowFlush
      check_linear_expr_uses!(stmt.value_expr, state)
    when MIR::IndexInsert
      check_linear_expr_uses!(stmt.map, state)
      check_linear_expr_uses!(stmt.key_expr, state)
      check_linear_expr_uses!(stmt.value_expr, state)
    when MIR::ShardedMapPut
      check_linear_expr_uses!(stmt.target, state)
      check_linear_expr_uses!(stmt.key, state)
      check_linear_expr_uses!(stmt.value, state)
      check_linear_expr_uses!(stmt.shard_idx, state)
      check_linear_expr_uses!(stmt.shard_key, state)
    when MIR::Sort
      check_linear_expr_uses!(stmt.items_expr, state)
      check_linear_expr_uses!(stmt.key_a, state)
      check_linear_expr_uses!(stmt.key_b, state)
    when MIR::StreamYield
      check_linear_expr_uses!(stmt.value, state)
    when MIR::StreamSpawn
      check_linear_stmts!(stmt.body, LinearOwnershipState.new)
    when MIR::Pipeline
      check_linear_expr_uses!(stmt.inner, state)
    when MIR::RawBc
      stmt.args&.each { |arg| check_linear_expr_uses!(arg, state) }
      check_linear_expr_uses!(stmt, state)
    when MIR::RawZig
      check_linear_expr_uses!(stmt, state)
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
      states << linear_project_branch_state(check_linear_stmts!(stmt.guard_fail_body, state.copy), state, "polymorphic-mutate-flow")
      linear_merge_branch_states!(states, state, "polymorphic-mutate-flow")
    when MIR::WithMatchDispatch
      states = T.let([], T::Array[LinearOwnershipState])
      stmt.arms&.each { |arm| states << linear_project_branch_state(check_linear_stmts!(arm[:body], state.copy), state, "with-match") }
      linear_merge_branch_states!(states, state, "with-match")
    when MIR::BgBlock
      check_linear_stmts!(stmt.run_body, LinearOwnershipState.new)
    when MIR::DoBlock
      stmt.branch_bodies&.each { |body| check_linear_stmts!(body, LinearOwnershipState.new) }
    when MIR::CatchWrapper
      stmt.clause_bodies&.each { |body| check_linear_stmts!(body, state.copy) }
    when MIR::FnDef
      check_linear_stmts!(stmt.body, LinearOwnershipState.new)
    when MIR::TestDef
      check_linear_stmts!(stmt.body, LinearOwnershipState.new)
    when MIR::StructDef
      stmt.methods&.each { |method| check_linear_stmt!(method, LinearOwnershipState.new) if method.is_a?(MIR::FnDef) }
    when MIR::FsmB1Body, MIR::FsmGenericBody, MIR::FsmIoBody
      ctx = stmt.ctx_struct
      check_linear_stmts!(ctx.run_body, LinearOwnershipState.new) if ctx.respond_to?(:run_body)
    when MIR::Panic
      state.terminated = true
    when MIR::Comment, MIR::ContinueStmt, MIR::EnumDef, MIR::FrameRestore,
         MIR::FrameSave, MIR::Import, MIR::MutualThunkTrampoline, MIR::Noop,
         MIR::PubConst, MIR::Suppress, MIR::ThunkTrampoline, MIR::TypeAlias,
         MIR::UnionTypeDef
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
    state.alloc_kinds[name] = mark.alloc if mark.alloc.is_a?(Symbol)
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
    if state.released.include?(name)
      @errors << error(:OWNERSHIP_DOUBLE_RELEASE, name,
        "Cleanup registered after ownership for this binding was already transferred")
    end
    if state.cleanup_finalizers.include?(name) || state.err_finalizers.include?(name)
      @errors << error(:OWNERSHIP_DOUBLE_FINALIZER, name,
        "multiple cleanup strategies registered for one owned binding")
    end
    state.cleanup_finalizers.add(name)
    state.guarded_finalizers.add(name) if guarded
    nil
  end

  sig { params(name: String, state: LinearOwnershipState).void }
  def linear_register_err_cleanup!(name, state)
    if state.released.include?(name)
      @errors << error(:OWNERSHIP_DOUBLE_RELEASE, name,
        "ErrCleanup registered after ownership for this binding was already transferred")
    end
    if state.cleanup_finalizers.include?(name) || state.err_finalizers.include?(name)
      @errors << error(:OWNERSHIP_DOUBLE_FINALIZER, name,
        "multiple cleanup strategies registered for one owned binding")
    end
    state.err_finalizers.add(name)
    nil
  end

  sig { params(name: String, target: T.untyped, target_alloc: T.untyped, state: LinearOwnershipState).void }
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

  sig { params(name: String, target: T.untyped, target_alloc: T.untyped, state: LinearOwnershipState).void }
  def linear_release!(name, target, target_alloc, state)
    unless state.owned.include?(name)
      @errors << error(:TRANSFER_WITHOUT_ALLOC, name,
        "ownership release to #{target.inspect} has no active AllocMark")
      return
    end
    if target == :owned_sink && !target_alloc.is_a?(Symbol)
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

  sig { params(target: T.untyped, target_alloc: T.untyped).returns(T::Boolean) }
  def escaping_transfer_target?(target, target_alloc)
    return false unless target.is_a?(Symbol)
    return target_alloc == :heap if target == :owned_sink

    LINEAR_FRAME_ESCAPING_TRANSFER_TARGETS.include?(target)
  end

  sig { params(then_body: T.nilable(T::Array[T.untyped]), else_body: T.nilable(T::Array[T.untyped]), state: LinearOwnershipState, label: String).void }
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
    projected = outer_state.copy
    linear_exit_scope!(projected, branch_state, label)
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
      next if state.snapshot == first.snapshot
      @errors << error(:OWNERSHIP_UNVERIFIED_PATH, label,
        "control-flow branches rejoin with different ownership state: " \
        "#{first.snapshot.join(" ")} vs #{state.snapshot.join(" ")}")
    end
    copy_linear_state!(first, into)
    nil
  end

  sig { params(states: T::Array[LinearOwnershipState]).void }
  def normalize_guarded_conditional_releases!(states)
    return if states.empty?
    names = T.let(Set.new, T::Set[String])
    states.each { |state| names.merge(state.released) }
    names.each do |name|
      released_count = states.count { |state| state.released.include?(name) }
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
    return if expected.snapshot == actual.snapshot

    @errors << error(:OWNERSHIP_UNVERIFIED_PATH, label,
      "nested control flow changes ownership state in a way MIRChecker cannot prove: " \
      "#{expected.snapshot.join(" ")} vs #{actual.snapshot.join(" ")}")
    nil
  end

  sig { params(outer: LinearOwnershipState, inner: LinearOwnershipState, label: String).void }
  def linear_exit_scope!(outer, inner, label)
    projected = inner.copy
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
    copy_linear_state!(projected, outer)
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

  sig { params(expr: T.untyped, state: LinearOwnershipState, transfer_reads: T::Set[String]).void }
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
    nil
  end

  sig { params(expr: T.untyped).returns(T::Set[String]) }
  def linear_expr_consumed_names(expr)
    names = T.let(Set.new, T::Set[String])
    walk_mir_node(expr) do |node|
      contract = node.respond_to?(:ownership_contract) ? node.ownership_contract : nil
      if contract.is_a?(MIR::OwnershipContract)
        contract.consumes.each { |name| names.add(name.to_s) }
      end
      if node.is_a?(MIR::StructInit) || node.is_a?(MIR::ArrayInit)
        collect_linear_expr_ident_names(node, names)
      end
      callable = node.respond_to?(:callable_contract) ? node.callable_contract : nil
      next unless callable.is_a?(MIR::CallableContract)
      callable.ownership_contract.consumes.each { |name| names.add(name.to_s) }
    end
    names
  end

  sig { params(expr: T.untyped).returns(T::Set[String]) }
  def linear_expr_ident_names(expr)
    names = T.let(Set.new, T::Set[String])
    collect_linear_expr_ident_names(expr, names)
    names
  end

  sig { params(expr: T.untyped, names: T::Set[String]).void }
  def collect_linear_expr_ident_names(expr, names)
    return unless expr
    case expr
    when MIR::Ident
      names.add(expr.name.to_s)
      return
    when MIR::InlineZig, MIR::RawZig, MIR::BlockExpr
      return
    end
    each_sub_expr(expr) { |sub| collect_linear_expr_ident_names(sub, names) }
    nil
  end

  # INV-MOVEMARK-GUARD-SCOPE: MoveMark lowers to `name_moved = true`; that
  # variable only exists if a same-or-outer lexical body emitted a guarded
  # Cleanup/ErrCleanup for the binding earlier in the same scope. This rejects
  # ownership markers leaked out of nested returns/loops before Zig codegen can
  # see an undeclared `_moved` variable.
  sig { params(body: T.nilable(T::Array[T.untyped]), visible: T::Set[String]).returns(T.nilable(T::Array[T.untyped])) }
  def verify_move_mark_scope!(body, visible = Set.new)
    return unless body.is_a?(Array)
    body.each do |stmt|
      case stmt
      when MIR::Cleanup, MIR::ErrCleanup
        visible.add(stmt.name.to_s) if stmt.cleanup_entry.has_moved_guard?
      when MIR::MoveMark
        unless visible.include?(stmt.name.to_s)
          @errors << error(:MOVEMARK_WITHOUT_GUARD, stmt.name,
            "MIR::MoveMark has no visible guarded Cleanup/ErrCleanup; ownership marker escaped its lexical owner")
        end
      when MIR::IfStmt
        verify_move_mark_scope!(stmt.then_body, visible.dup)
        verify_move_mark_scope!(stmt.else_body, visible.dup)
      when MIR::IfBindStmt
        verify_move_mark_scope!(stmt.then_body, visible.dup)
        verify_move_mark_scope!(stmt.else_body, visible.dup)
      when MIR::WhileStmt, MIR::ForStmt
        verify_move_mark_scope!(stmt.body, visible.dup)
      when MIR::ScopeBlock, MIR::BlockExpr
        verify_move_mark_scope!(stmt.body, visible.dup)
      when MIR::SwitchStmt, MIR::UnionMatchStmt
        stmt.arms&.each { |a| verify_move_mark_scope!(a[:body], visible.dup) }
        verify_move_mark_scope!(stmt.default_body, visible.dup)
      when MIR::IfChain
        stmt.branches&.each { |b| verify_move_mark_scope!(b[:body], visible.dup) }
        verify_move_mark_scope!(stmt.default_body, visible.dup)
      when MIR::BgBlock
        verify_move_mark_scope!(stmt.run_body, visible.dup)
      when MIR::DoBlock
        stmt.branch_bodies&.each { |b| verify_move_mark_scope!(b, visible.dup) }
      when MIR::CatchWrapper
        stmt.clause_bodies&.each { |b| verify_move_mark_scope!(b, visible.dup) }
      when MIR::SnapshotRead, MIR::SnapshotTransaction, MIR::SnapshotMultiTxn
        verify_move_mark_scope!(stmt.body, visible.dup)
      when MIR::WithMatchDispatch
        stmt.arms&.each { |a| verify_move_mark_scope!(a[:body], visible.dup) }
      end
    end
    nil
  end

  # INV-ERRCLEANUP-TRANSFER: ErrCleanup means "clean this binding only on the
  # error path because success transfers ownership". Success transfer must be
  # represented by TransferMark; otherwise the compiler is relying on context
  # folklore and the checker cannot distinguish a valid move from a leak.
  sig { params(err_cleanups: T::Hash[String, T::Array[T.untyped]], transfers: T::Set[T.untyped]).returns(T.nilable(T::Array[T.untyped])) }
  def verify_err_cleanup_transfers!(err_cleanups, transfers)
    err_cleanups.each_key do |name|
      next if transfers.include?(name)
      @errors << error(:ERRCLEANUP_WITHOUT_TRANSFER, name,
        "MIR::ErrCleanup requires a matching MIR::TransferMark; success-path owner is implicit")
    end
    nil
  end

  # INV-ALLOCATING-LET-MARKED: a top-level Let init is the only legal place
  # for an allocating MIR expression, but "legal expression position" is not
  # ownership tracking. The binding must still have an AllocMark so cleanup or
  # transfer can be verified by name.
  sig { params(body: T.nilable(T::Array[T.untyped]), allocs: T::Hash[String, T::Array[T.untyped]]).returns(T.nilable(T::Array[T.untyped])) }
  def verify_allocating_lets_marked!(body, allocs)
    walk_mir(body) do |node|
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
  sig { params(body: T.nilable(T::Array[T.untyped]), allocs: T::Hash[String, T::Array[T.untyped]]).returns(T.nilable(T::Array[T.untyped])) }
  def verify_aggregate_owned_children!(body, allocs)
    return unless body.is_a?(Array)
    alloc_by_name = T.let({}, T::Hash[String, Symbol])
    allocs.each do |name, marks|
      mark = marks.first
      alloc_by_name[name] = mark.alloc if mark && VALID_ALLOCATORS.include?(mark.alloc)
    end
    check_aggregate_stmts!(body, alloc_by_name)
  end

  sig { params(stmts: T.nilable(T::Array[T.untyped]), alloc_by_name: T::Hash[String, Symbol]).returns(T.nilable(T::Array[T.untyped])) }
  def check_aggregate_stmts!(stmts, alloc_by_name)
    return unless stmts.is_a?(Array)
    stmts.each do |stmt|
      case stmt
      when MIR::Let
        check_aggregate_expr!(stmt.init, alloc_by_name[stmt.name], alloc_by_name)
      when MIR::Set
        check_aggregate_expr!(stmt.value, nil, alloc_by_name)
      when MIR::ReassignWithCleanup
        check_aggregate_expr!(stmt.value, stmt.alloc, alloc_by_name)
      when MIR::ReturnStmt, MIR::BreakStmt
        check_aggregate_expr!(stmt.value, nil, alloc_by_name)
      when MIR::ExprStmt
        check_aggregate_expr!(stmt.expr, nil, alloc_by_name)
      when MIR::DiscardOwned
        check_aggregate_expr!(stmt.expr, nil, alloc_by_name)
      when MIR::IfStmt
        check_aggregate_expr!(stmt.cond, nil, alloc_by_name)
        check_aggregate_stmts!(stmt.then_body, alloc_by_name)
        check_aggregate_stmts!(stmt.else_body, alloc_by_name)
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
        stmt.arms&.each { |a| check_aggregate_stmts!(a[:body], alloc_by_name) }
        check_aggregate_stmts!(stmt.default_body, alloc_by_name)
      when MIR::IfChain
        stmt.branches&.each do |b|
          check_aggregate_expr!(b[:cond], nil, alloc_by_name)
          check_aggregate_stmts!(b[:body], alloc_by_name)
        end
        check_aggregate_stmts!(stmt.default_body, alloc_by_name)
      end
    end
  end

  sig { params(expr: T.untyped, owner_alloc: T.nilable(Symbol), alloc_by_name: T::Hash[String, Symbol]).returns(T.nilable(T::Array[T.untyped])) }
  def check_aggregate_expr!(expr, owner_alloc, alloc_by_name)
    return unless expr
    case expr
    when MIR::Cast
      check_aggregate_expr!(expr.expr, owner_alloc, alloc_by_name)
    when MIR::MakeList
      list_alloc = expr.alloc.is_a?(Symbol) ? expr.alloc : owner_alloc
      expr.items&.each { |item| check_aggregate_expr!(item, list_alloc, alloc_by_name) }
    when MIR::StructInit
      expr.fields&.each do |field|
        field_alloc = field[:alloc].is_a?(Symbol) ? field[:alloc] : owner_alloc
        check_aggregate_expr!(field[:value], field_alloc, alloc_by_name)
      end
    when MIR::ArrayInit
      expr.items&.each { |item| check_aggregate_expr!(item, owner_alloc, alloc_by_name) }
    when MIR::DeepCopy
      # DeepCopy reads its source and produces a fresh owned value in its own
      # allocator; the source is not inserted into the destination aggregate.
      return
    when MIR::RcRetain
      # Retain reads an Arc/Rc source and produces a new owned handle; the
      # source binding itself is not inserted into the aggregate.
      return
    when MIR::RcDowngrade, MIR::WeakUpgrade
      # Weak-link operations read their source handles and produce a distinct
      # handle; they do not insert the source binding into the aggregate.
      return
    when MIR::Ident
      child_alloc = alloc_by_name[expr.name]
      return unless child_alloc && owner_alloc
      return if child_alloc == owner_alloc
      @errors << error(:AGGREGATE_CHILD_ALLOC_MISMATCH, expr.name,
        "owned child is :#{child_alloc} but aggregate owner is :#{owner_alloc}; " \
        "nested ownership placement is implicit/incoherent")
    else
      each_sub_expr(expr) { |sub| check_aggregate_expr!(sub, nil, alloc_by_name) }
    end
    nil
  end

  # INV-INDIRECT-SINGLE-BOX: a HeapCreate is exactly one indirection
  # (`HeapCreate(T)` -> `*T`), so its cell type must never itself be a
  # pointer. A `*`-typed cell is a `**U` double box -> UAF on read.
  sig { params(body: T.nilable(T::Array[T.untyped])).returns(T.nilable(T::Array[T.untyped])) }
  def verify_heap_create_single_indirection!(body)
    each_heap_create(body) do |hc|
      zt = hc.zig_type
      next unless zt.is_a?(String) && zt.lstrip.start_with?("*")
      @errors << error(:INDIRECT_DOUBLE_BOX, @fn_name,
        "HeapCreate cell type is `#{zt}` (already a pointer) — boxing it yields a double indirection")
    end
  end

  sig { params(stmts: T.nilable(T::Array[T.untyped]), blk: T.untyped).returns(T.untyped) }
  def each_heap_create(stmts, &blk)
    walk_mir(stmts) do |node|
      [node.respond_to?(:init) ? node.init : nil,
       node.respond_to?(:expr) ? node.expr : nil,
       node.respond_to?(:value) ? node.value : nil].each do |root|
        deep_each_expr(root) { |e| yield e if e.is_a?(MIR::HeapCreate) }
      end
    end
  end

  sig { params(expr: T.untyped, blk: T.untyped).returns(T.untyped) }
  def deep_each_expr(expr, &blk)
    return unless expr
    yield expr
    each_sub_expr(expr) { |sub| deep_each_expr(sub, &blk) }
  end

  sig { params(program: MIR::Program, strict: T::Boolean).returns(T::Array[String]) }
  def check_program!(program, strict: false)
    MIRPassState.require!(program, :mir_lowered, consumer: "MIRChecker")
    all_errors = T.let(ownership_registry_errors, T::Array[String])
    program.items.each do |item|
      next unless item.is_a?(MIR::FnDef)
      all_errors.concat(check_fn!(item, strict: strict))
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

  sig { params(init: T.untyped).returns(T::Boolean) }
  def owned_return_init?(init)
    return true if init.is_a?(MIR::Call) && init.owned_return?

    if init.is_a?(MIR::InlineZig) || init.is_a?(MIR::RawZig)
      return false unless stdlib_owned_return?(init)
      # Receiver-dependent (Proc-resolved) returns -- collection
      # intrinsics like pool.insert/get -- are not a static owned-
      # return declaration; their ownership is governed by
      # allocates/borrows, handled elsewhere. Only a static return
      # type counts here (matches pre-FS behavior, which read only
      # the static `:return` key).
      return false unless init.stdlib_def.fixed_return?
      ret = init.stdlib_def.return_type
      return !ret.void?
    end
    false
  end

  sig { params(node: T.untyped).returns(T::Boolean) }
  def stdlib_owned_return?(node)
    return false unless node.stdlib_def&.emits_allocating?
    return true if node.stdlib_def&.heap_return_alloc?
    return false unless node.is_a?(MIR::InlineZig)

    allocs = node.allocs
    !!(allocs.is_a?(Hash) && allocs.values.any? { |v| v == :heap })
  end

  sig { params(lets: T::Array[MIR::Let], allocs: T::Hash[String, T::Array[T.untyped]]).returns(T.nilable(T::Array[T.untyped])) }
  def verify_owned_return_alloc_marks!(lets, allocs)
    lets.each do |let|
      marks = allocs[let.name]
      unless marks
        @errors << error(:OWNED_RETURN_WITHOUT_ALLOC, let.name,
          "owned-return initializer is heap-provenance but no MIR::AllocMark exists")
        next
      end

      if marks.any? { |m| m.alloc == :frame }
        @errors << error(:OWNED_RETURN_ALLOC_NOT_HEAP, let.name,
          "owned-return initializer is heap-provenance but MIR::AllocMark uses :frame")
      end
    end
  end

  sig { params(init: T.untyped).returns(T.nilable(Symbol)) }
  def expr_owned_result_alloc(init)
    return nil unless init && init.respond_to?(:ownership_effect)
    init.ownership_effect.alloc
  end

  sig { params(lets: T::Array[MIR::Let], allocs: T::Hash[String, T::Array[T.untyped]]).returns(T.nilable(T::Array[T.untyped])) }
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
  #   when (a) bind_line declares a local whose RHS references a
  #   finalized field, AND (b) post_result_line assigns that local
  #   directly into inner.result. The slice escapes the FSM but its
  #   backing memory dies when the finalize defer fires — the
  #   consumer reads a dangling pointer. Detected by the lowering
  #   (see emit_fsm_io_bg_code) and recorded as
  #   `structure.result_aliases_finalized`.
  #
  # Raises FsmStructureError on the first violation, with a message
  # naming the binding and the bad step index. Future invariants get
  # added here, NOT in the rendering code.
  class FsmStructureError < StandardError; end

  sig { params(structure: T.nilable(MIR::FsmStructure), source: T.untyped).returns(NilClass) }
  def self.check_fsm_structure!(structure, source: nil)
    return unless structure
    captures = structure.captures || []
    finalize_cleanups = structure.finalize_cleanups || []
    steps = structure.steps || []

    # INV-FSM-CAPTURE-FINALIZE
    captures.each do |cap|
      unless cap[:cleanup_at] == :finalize
        raise FsmStructureError, format_fsm_error(
          "INV-FSM-CAPTURE-FINALIZE",
          "capture '#{cap[:name]}' has cleanup_at=#{cap[:cleanup_at].inspect}; " \
          "captures may be read by any step and MUST cleanup at FSM finalize. " \
          "Cleanup placed in an earlier step fires before later steps run -> UAF.",
          source,
        )
      end
    end

    # INV-FSM-CAPTURE-CLEANUP-PRESENT
    captures.each do |cap|
      unless finalize_cleanups.include?(cap[:name])
        raise FsmStructureError, format_fsm_error(
          "INV-FSM-CAPTURE-CLEANUP-PRESENT",
          "capture '#{cap[:name]}' has no entry in finalize_cleanups; " \
          "the heap-dupe at spawn would leak.",
          source,
        )
      end
    end

    # INV-FSM-STEP-READS-LIVE
    cleanup_step_index = {}
    steps.each do |step|
      (step[:cleanups] || []).each { |name| cleanup_step_index[name] = step[:index] }
    end
    steps.each do |step|
      (step[:reads] || []).each do |name|
        next if finalize_cleanups.include?(name)  # lives until end
        cleanup_step = cleanup_step_index[name]
        next if cleanup_step.nil?                  # no cleanup recorded -> separate invariant
        next if cleanup_step >= step[:index]
        raise FsmStructureError, format_fsm_error(
          "INV-FSM-STEP-READS-LIVE",
          "step #{step[:index]} reads '#{name}' but its cleanup was placed in " \
          "step #{cleanup_step} (earlier). The defer fires before step #{step[:index]} " \
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

    nil
  end

  sig { params(invariant: String, message: String, source: NilClass).returns(String) }
  def self.format_fsm_error(invariant, message, source)
    loc = source&.line ? " at line #{source.line}" : ""
    "[FSM checker]#{loc} #{invariant}: #{message}"
  end

  private

  VALID_ALLOCATORS = T.let([:heap, :frame].freeze, T::Array[Symbol])
  VALID_ALLOC_SCOPES = T.let([:heap, :function, :iteration].freeze, T::Array[Symbol])

  sig do
    params(
      allocs: T::Hash[String, T::Array[T.untyped]],
      cleanups: T::Hash[String, T::Array[T.untyped]],
      inline_nodes: T::Array[T.untyped],
    ).returns(T.nilable(T::Array[T.untyped]))
  end
  def verify_allocator_closed_set!(allocs, cleanups, inline_nodes)
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

    inline_nodes.each do |node|
      next unless node.allocs
      node.allocs.each do |alloc_key, alloc|
        next if VALID_ALLOCATORS.include?(alloc)
        @errors << error(:INVALID_ALLOCATOR_MARK, node.target_var || node.reason || "inline_zig",
          "InlineZig #{alloc_key} uses #{alloc.inspect}; MIR allocator metadata must be :heap or :frame")
      end
    end
  end

  # INV-INLINE-TARGET: allocator-bearing InlineZig must name the binding or
  # receiver whose placement it consumes. Without that target, the checker
  # cannot compare allocator use to authoritative placement and lowering can
  # smuggle local guesses through codegen.
  sig { params(inline_nodes: T::Array[T.anything]).returns(T.nilable(T::Array[T.anything])) }
  def verify_inline_alloc_targets!(inline_nodes)
    inline_nodes.each do |node|
      unsafe_node = T.unsafe(node)
      next unless unsafe_node.allocs && !unsafe_node.allocs.empty?
      next if unsafe_node.target_var && !unsafe_node.target_var.to_s.empty?

      @errors << error(:INLINE_ALLOC_WITHOUT_TARGET, unsafe_node.reason || "inline_zig",
        "InlineZig has allocator metadata #{unsafe_node.allocs.inspect} but no target_var; " \
        "allocator use is not checker-verifiable against binding placement")
    end
  end

  # Tree walker -- yields every node in the MIR tree.
  sig { params(stmts: T.nilable(T::Array[T.untyped]), block: T.untyped).returns(T.nilable(T::Array[T.untyped])) }
  def walk_mir(stmts, &block)
    return unless stmts.is_a?(Array)
    stmts.each { |s| walk_mir_node(s, &block) }
  end

  sig { params(node: T.untyped, block: T.untyped).returns(T.nilable(T::Array[T.untyped])) }
  def walk_mir_node(node, &block)
    if node.is_a?(Array)
      node.each { |child| walk_mir_node(child, &block) }
      return
    end
    return unless node.is_a?(MIR::Emittable)

    yield node
    node.child_exprs.each { |child| walk_mir_node(child, &block) }
    node.body_slots.each { |slot| walk_mir(slot.body, &block) }
    if node.is_a?(MIR::Pipeline)
      walk_mir_node(node.inner, &block)
    end
    nil
  end

  sig { params(expr: T.untyped, block: T.untyped).void }
  def walk_mir_expr(expr, &block)
    walk_mir_node(expr, &block)
    nil
  end

  # HPT_LEAK: heap-returning call result discarded.
  sig { params(node: T.untyped, leaks: T::Array[String]).returns(T.nilable(T::Array[T.untyped])) }
  def scan_expr_for_hpt_leak!(node, leaks)
    return unless node
    effect = node.respond_to?(:ownership_effect) ? node.ownership_effect : MIR::OwnershipEffect.none
    if effect.produces_owned
      leaks << error(:HPT_LEAK, ownership_effect_label(node),
        "owned-result expression not bound to variable (leak)")
    elsif (node.is_a?(MIR::InlineZig) || node.is_a?(MIR::RawZig)) && stdlib_owned_return?(node) &&
       node.stdlib_def.fixed_return?
      ret = node.stdlib_def.return_type
      unless ret.void?
        label = node.is_a?(MIR::RawZig) ? "RawZig block" : "stdlib call"
        leaks << error(:HPT_LEAK, node.reason,
          "#{label} with allocates:true result not bound to variable (leak)")
      end
    end
    if node.is_a?(MIR::Call) && node.args
      node.args.each { |a| scan_expr_for_hpt_leak!(a, leaks) }
    elsif node.is_a?(MIR::MethodCall)
      scan_expr_for_hpt_leak!(node.receiver, leaks)
      node.args.each { |a| scan_expr_for_hpt_leak!(a, leaks) }
    end
  end

  sig { params(node: T.untyped).returns(String) }
  def ownership_effect_label(node)
    case node
    when MIR::Call
      node.callee.to_s
    when MIR::MethodCall
      node.method.to_s
    when MIR::InlineZig, MIR::RawZig
      node.reason.to_s
    else
      node.class.name.to_s
    end
  end

  # INLINE_ALLOC_MISMATCH: InlineZig operation allocator must match container.
  #
  # Checks ALL allocator params (:alloc, :key_alloc, :val_alloc) against the
  # container's AllocMark. A frame-allocated key/value stored in a heap
  # container becomes a dangling pointer after frame rewind.
  sig { params(inline_nodes: T::Array[T.untyped], allocs: T::Hash[String, T::Array[T.untyped]], fn_def: MIR::FnDef).returns(T::Array[T.untyped]) }
  def verify_inline_alloc_contracts!(inline_nodes, allocs, fn_def)
    param_names = T.let(fn_def.params.map { |param| param.name.to_s }.to_set, T::Set[String])
    inline_nodes.each do |iz|
      next unless iz.allocs
      target = iz.target_var
      next unless target && !target.to_s.empty?

      requires_target_alloc = iz.allocs.key?(:alloc) || iz.allocs.key?(:key_alloc)
      unless allocs.key?(target)
        next if param_names.include?(target.to_s)
        next unless requires_target_alloc
        @errors << error(:INLINE_ALLOC_WITHOUT_ALLOCMARK, target,
          "InlineZig has allocator metadata #{iz.allocs.inspect} for '#{target}' but no MIR::AllocMark")
        next
      end

      container_alloc = T.must(allocs[target]).first.alloc

      # Check primary allocator.
      if iz.allocs.key?(:alloc)
        op_alloc = iz.allocs[:alloc]
        if op_alloc != container_alloc
          @errors << error(:INLINE_ALLOC_MISMATCH, target,
            "operation uses :#{op_alloc} but container '#{target}' is :#{container_alloc}")
        end
      end

      # Check key/value allocators: frame-allocated stored data in a heap
      # container = use-after-free when the frame rewinds.
      [:key_alloc, :val_alloc].each do |alloc_key|
        next unless iz.allocs.key?(alloc_key)
        stored_alloc = iz.allocs[alloc_key]
        if stored_alloc == :frame && container_alloc == :heap
          @errors << error(:INLINE_ALLOC_MISMATCH, target,
            "#{alloc_key} is :frame but container '#{target}' is :heap " \
            "(stored data will dangle after frame rewind)")
        end
      end
    end
  end

  # CROSS_FRAME_PARAM_ALLOC: an InlineZig op targeting a pointer-passed
  # parameter must not use the `:frame` allocator. Pointer-passed params
  # (MUTABLE collection / `*T` Zig type) carry a lifetime that extends
  # past the current function's mark/restore -- a frame allocation here
  # would die before the binding it serves, producing a cross-frame UAF.
  #
  # Independently re-derives "is this param pointer-passed?" from the
  # MIR-level Zig type (prefix `*`) so the check is decoupled from
  # mir_lowering's `@current_fn_collection_params` set. Defense in depth:
  # if lowering's `resolve_alloc_sym` or escape_analysis's Condition 9
  # ever regresses, this catches the resulting bad MIR before codegen.
  sig { params(inline_nodes: T::Array[T.untyped], fn_def: MIR::FnDef).returns(T.nilable(T::Array[T.untyped])) }
  def verify_cross_frame_param_alloc!(inline_nodes, fn_def)
    return if fn_def.params.nil? || fn_def.params.empty?

    # `pointer_passed` flag is set on MIR::Param at lowering time. Collection
    # params lower to `anytype` (polymorphic) so we can't read pointer-pass
    # status from the Zig type string alone — the lowering tags it explicitly.
    pointer_passed = fn_def.params.each_with_object(Set.new) do |p, set|
      set << p.name.to_s if p.respond_to?(:pointer_passed) && p.pointer_passed
    end
    return if pointer_passed.empty?

    inline_nodes.each do |iz|
      next unless iz.allocs
      target = iz.target_var.to_s
      next unless pointer_passed.include?(target)

      iz.allocs.each do |alloc_key, alloc_sym|
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
  sig { params(allocs: T::Hash[String, T::Array[T.untyped]], cleanups: T::Hash[String, T::Array[T.untyped]], errdefer_destroy_names: T::Set[T.untyped], transfers: T::Set[T.untyped]).returns(T::Hash[String, T::Array[T.untyped]]) }
  def verify_alloc_cleanup_match!(allocs, cleanups, errdefer_destroy_names = Set.new, transfers = Set.new)
    allocs.each do |name, alloc_marks|
      next unless cleanups.key?(name)

      alloc_sym   = alloc_marks.first.alloc
      cleanup_sym = T.must(cleanups[name]).first.cleanup_entry.alloc

      if alloc_sym != cleanup_sym
        @errors << error(:ALLOC_CLEANUP_MISMATCH, name,
          "allocated with :#{alloc_sym} but cleanup uses :#{cleanup_sym}")
      end

      # INV-COPY-CLEANUP: primitives and Id<T> (value types that can never own
      # heap memory) must not get a Cleanup node. If they do, needs_explicit_cleanup?
      # or visit_CopyNode missed the gate.
      if (ti = alloc_marks.first.full_type)
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
    # Exception: @indirect field temps use ErrDeferStmt(DestroyPtr) (errdefer_destroy_names).
    allocs.each do |name, alloc_marks|
      next if cleanups.key?(name)
      next if errdefer_destroy_names.include?(name)
      next if transfers.include?(name)
      next if alloc_marks.all? { |m| m.alloc == :frame }
      @errors << error(:ALLOC_WITHOUT_CLEANUP, name,
        "AllocMark with no Cleanup, ErrCleanup, ErrDeferStmt(DestroyPtr), or TransferMark -- leaked allocation")
    end
  end

  # NO_CONTRACT: InlineZig/RawZig must have verifier-visible semantics.
  #
  # RawZig is always opaque. InlineZig is acceptable only when it carries a
  # stdlib_def/FunctionSignature contract that declares ownership effects. An
  # empty ownership_contract is not proof of purity; it is only meaningful after
  # the callable contract says whether ownership can move.
  sig { params(zig_nodes: T::Array[T.untyped]).returns(T::Array[T.untyped]) }
  def verify_zig_contracts!(zig_nodes)
    zig_nodes.each do |node|
      if node.is_a?(MIR::RawZig)
        @errors << error(:RAW_NO_CONTRACT, node.reason || "raw_zig",
          "RawZig is opaque to MIRChecker; decompose into structural MIR")
        next
      end

      if opaque_zig_allocator_ownership?(node)
        @errors << error(:OPAQUE_ZIG_OWNERSHIP, node.reason || "inline_zig",
          "InlineZig performs allocator ownership operations inside opaque code; decompose into structural MIR")
      end

      next if node.stdlib_def
      @errors << error(:INLINE_NO_CONTRACT, node.reason || "inline_zig",
        "InlineZig has no stdlib_def/FunctionSignature; ownership effects are unverifiable")
    end
  end

  sig { params(node: MIR::InlineZig).returns(T::Boolean) }
  def opaque_zig_allocator_ownership?(node)
    code = node.code.to_s
    code.match?(/\b(?:heapAlloc|getSched\(\)\.allocator|allocator)\s*\(\)?\s*\.(?:alloc|dupe|create|destroy|free|deinit)\b/) ||
      code.match?(/\b(?:alloc|dupe|create|destroy|free|deinit)\s*\(/)
  end

  sig { params(body: T::Array[T.untyped], transfers: T::Set[T.untyped], allocs: T::Hash[String, T::Array[T.untyped]]).void }
  def verify_call_contracts!(body, transfers, allocs)
    walk_mir(body) do |node|
      case node
      when MIR::Call
        verify_callable_contract!(node.callable_contract, node.callee.to_s, "MIR::Call", transfers, allocs)
      when MIR::TailCall
        verify_callable_contract!(node.callable_contract, node.callee.to_s, "MIR::TailCall", transfers, allocs)
      when MIR::MethodCall
        verify_callable_contract!(node.callable_contract, node.method.to_s, "MIR::MethodCall", transfers, allocs)
      end
    end
    nil
  end

  sig { params(contract: T.untyped, label: String, node_kind: String, transfers: T::Set[T.untyped], allocs: T::Hash[String, T::Array[T.untyped]]).void }
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

    ownership.consumes.each do |name|
      unless transfers.include?(name)
        @errors << error(:OWNERSHIP_CONTRACT_WITHOUT_TRANSFER, name,
          "#{node_kind} ownership_contract consumes '#{name}' but no MIR::TransferMark exists for that binding")
      end
    end
    check_consumed_allocators_match_sink!(contract, ownership.consumes, allocs)
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
  sig { params(zig_nodes: T::Array[T.untyped], transfers: T::Set[T.untyped], allocs: T::Hash[String, T::Array[T.untyped]]).returns(T.nilable(T::Array[T.untyped])) }
  def verify_explicit_ownership_contracts!(zig_nodes, transfers, allocs)
    zig_nodes.each do |node|
      next unless node.is_a?(MIR::InlineZig) || node.is_a?(MIR::RawZig)

      unless node.ownership_contract.is_a?(MIR::OwnershipContract)
        @errors << error(:IMPLICIT_OWNERSHIP_TRANSFER, ownership_node_name(node),
          "ownership_contract must be MIR::OwnershipContract; Hash/nil contracts make ownership unverifiable")
        next
      end

      consumes = ownership_contract_consumes(node.ownership_contract)
      if stdlib_takes_ownership?(node) && !ownership_contract_present?(node.ownership_contract)
        @errors << error(:IMPLICIT_OWNERSHIP_TRANSFER, ownership_node_name(node),
          "stdlib_def declares a TAKES/consuming parameter but ownership_contract is absent; " \
          "MIRChecker cannot prove whether this call consumes an owned binding")
      end

      consumes.each do |name|
        unless transfers.include?(name)
          @errors << error(:OWNERSHIP_CONTRACT_WITHOUT_TRANSFER, name,
            "ownership_contract consumes '#{name}' but no MIR::TransferMark exists for that binding")
        end

        next unless copying_consumed_binding?(node, name)
        @errors << error(:OWNERSHIP_TRANSFER_COPIED, name,
          "ownership_contract consumes '#{name}', but emitted Zig deep-copies it; " \
          "copying and consuming are different ownership events")
      end

      check_consumed_allocators_match_sink!(node, consumes, allocs)
    end
    nil
  end

  # INV-FINALIZED-OWNERSHIP-SURFACE: by the time MIRChecker runs, ownership
  # must be represented by the closed Owned* fact surface. Node-specific fields
  # like InlineZig#allocs, Call#owned_return, MethodCall#owned_result_alloc, or
  # callable/stdlib TAKES side channels are lowering inputs only. If they remain
  # authoritative here, the checker is forced to infer ownership through many
  # unrelated protocols and memory bugs can slip through opaque code.
  sig { params(body: T::Array[T.untyped], facts: T::Array[T.untyped]).void }
  def verify_ownership_surfaces_finalized!(body, facts)
    facts_seen = !facts.empty?
    walk_mir(body) do |node|
      case node
      when MIR::InlineZig
        next unless inline_ownership_side_channel?(node)
        next if facts_seen && ownership_fact_covers_node?(facts, node)

        @errors << error(:OWNERSHIP_FACT_REQUIRED, ownership_node_name(node),
          "InlineZig carries allocator/ownership effects through stdlib_def, allocs, " \
          "or ownership_contract. Finalize it into Owned* facts or decompose it into structural MIR.")
      when MIR::Call
        next unless node.owned_return? || callable_contract_consumes?(node.callable_contract)
        next if facts_seen && ownership_fact_covers_node?(facts, node)

        @errors << error(:OWNERSHIP_FACT_REQUIRED, node.callee.to_s,
          "MIR::Call carries ownership through owned_return/callable_contract. " \
          "Finalize call ownership into OwnedCreate/OwnedTransfer/OwnedReturn facts.")
      when MIR::MethodCall
        next unless node.owned_result_alloc.is_a?(Symbol) || callable_contract_consumes?(node.callable_contract)
        next if facts_seen && ownership_fact_covers_node?(facts, node)

        @errors << error(:OWNERSHIP_FACT_REQUIRED, node.method.to_s,
          "MIR::MethodCall carries ownership through owned_result_alloc/callable_contract. " \
          "Finalize method ownership into OwnedCreate/OwnedTransfer/OwnedStore facts.")
      when MIR::ShardedMapPut, MIR::ReassignWithCleanup
        next unless stdlib_takes_ownership?(node)
        next if facts_seen && ownership_fact_covers_node?(facts, node)

        @errors << error(:OWNERSHIP_FACT_REQUIRED, ownership_node_name(node),
          "#{node.class.name} consumes or replaces owned data through node-specific fields. " \
          "Finalize the store/reassign into OwnedStore/OwnedTransfer/OwnedDestroy facts.")
      when MIR::BgBlock
        next if facts_seen && ownership_fact_covers_node?(facts, node)

        @errors << error(:OWNERSHIP_FACT_REQUIRED, ownership_node_name(node),
          "MIR::BgBlock creates/captures promise-owned state across an execution boundary. " \
          "Finalize BG ownership into OwnedCreate/OwnedTransfer/OwnedReturn/OwnedDestroy facts.")
      end
    end
    nil
  end

  sig { params(body: T::Array[T.untyped]).void }
  def verify_execution_boundary_facts!(body)
    walk_mir(body) do |node|
      case node
      when MIR::BgBlock
        verify_execution_boundary_fact!(node.boundary_fact, "MIR::BgBlock")
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

  sig { params(node: MIR::InlineZig).returns(T::Boolean) }
  def inline_ownership_side_channel?(node)
    return true if node.allocs && !node.allocs.empty?
    return true if node.stdlib_def&.emits_allocating?
    return false if stdlib_consumption_covered_without_owned_values?(node)
    return true if stdlib_takes_ownership?(node)
    return false unless node.ownership_contract.is_a?(MIR::OwnershipContract)

    !node.ownership_contract.consumes.empty? || !node.ownership_contract.produces.empty?
  end

  sig { params(node: MIR::InlineZig).returns(T::Boolean) }
  def stdlib_consumption_covered_without_owned_values?(node)
    return false unless stdlib_takes_ownership?(node)

    contract = node.ownership_contract
    return false unless contract.is_a?(MIR::OwnershipContract)
    return false unless contract.covers_consuming_params

    contract.consumes.empty? && contract.produces.empty? && contract.borrows.empty?
  end

  sig { params(contract: T.untyped).returns(T::Boolean) }
  def callable_contract_consumes?(contract)
    return false unless contract.is_a?(MIR::CallableContract)
    !contract.ownership_contract.consumes.empty?
  end

  sig { params(facts: T::Array[T.untyped], node: T.untyped).returns(T::Boolean) }
  def ownership_fact_covers_node?(facts, node)
    if node.respond_to?(:ownership_consumption) &&
       node.ownership_consumption.is_a?(MIR::OwnershipConsumptionFact)
      return true
    end

    source = ownership_node_name(node)
    facts.any? do |fact|
      fact.respond_to?(:source) && fact.source.to_s == source
    end
  end

  sig { params(node: T.untyped, consumes: T::Array[String], allocs: T::Hash[String, T::Array[T.untyped]]).void }
  def check_consumed_allocators_match_sink!(node, consumes, allocs)
    return if consumes.empty?
    return unless node.respond_to?(:allocs) && node.allocs.is_a?(Hash)
    sink_alloc = node.allocs[:val_alloc] || node.allocs[:alloc]
    return unless sink_alloc.is_a?(Symbol)

    consumes.each do |name|
      mark = allocs[name]&.first
      next unless mark&.alloc.is_a?(Symbol)
      next if mark.alloc == sink_alloc
      @errors << error(:AGGREGATE_CHILD_ALLOC_MISMATCH, name,
        "ownership_contract consumes :#{mark.alloc} binding '#{name}' into :#{sink_alloc} sink; " \
        "owned transfer allocator is incoherent")
    end
  end

  sig { params(node: T.untyped).returns(T::Boolean) }
  def stdlib_takes_ownership?(node)
    return true if node.is_a?(MIR::ReassignWithCleanup)

    sig = node.respond_to?(:stdlib_def) ? node.stdlib_def : nil
    return false unless sig
    params = sig.respond_to?(:params) ? sig.params : nil
    return true if params.respond_to?(:any?) && params.any? { |p| p.respond_to?(:takes) && p.takes }

    sig.takes_ownership?
  end

  sig { params(contract: MIR::OwnershipContract).returns(T::Array[String]) }
  def ownership_contract_consumes(contract)
    contract.consumes
  end

  sig { params(contract: MIR::OwnershipContract).returns(T::Boolean) }
  def ownership_contract_present?(contract)
    !contract.empty? || contract.covers_consuming_params
  end

  sig { params(node: T.untyped).returns(String) }
  def ownership_node_name(node)
    return ownership_node_name(node.expr) if node.is_a?(MIR::Cast) || node.is_a?(MIR::TryExpr)
    target = node.respond_to?(:target_var) ? node.target_var : nil
    return target.to_s if target
    return node.callee.to_s if node.is_a?(MIR::Call) || node.is_a?(MIR::TailCall)
    return node.method.to_s if node.is_a?(MIR::MethodCall)
    return "MIR::BgBlock" if node.is_a?(MIR::BgBlock)
    return "MIR::StreamSpawn" if node.is_a?(MIR::StreamSpawn)
    reason = node.respond_to?(:reason) ? node.reason : nil
    reason ? reason.to_s : node.class.name.to_s
  end

  sig { params(node: T.untyped, name: String).returns(T::Boolean) }
  def copying_consumed_binding?(node, name)
    return false unless node.respond_to?(:code) && node.code.is_a?(String)
    escaped = Regexp.escape(name)
    !!(node.code.match?(/CheatLib\.dupe(?:Value|UnionValue)?\(.*\b#{escaped}\b/m) ||
       node.code.match?(/\.dupe\(.*\b#{escaped}\b/m))
  end

  # FRAME_NO_REWIND: every iteration-scoped frame allocation must be inside a
  # loop restore, and every restored loop may contain only iteration-scoped
  # frame allocations.
  #
  # Post-lowering check: walks the MIR tree looking for loops that contain
  # frame AllocMarks or InlineZig with frame allocs but lack mark_per_iter.
  # Without per-iteration rewind, frame arena grows unboundedly across iterations.
  sig { params(body: T::Array[T.untyped]).returns(T.nilable(T::Array[T.untyped])) }
  def verify_frame_rewind!(body)
    return unless body.is_a?(Array)
    check_loop_rewind!(body)
  end

  sig { params(stmts: T.nilable(T::Array[T.untyped])).returns(T.nilable(T::Array[T.untyped])) }
  def check_loop_rewind!(stmts)
    return unless stmts.is_a?(Array)
    stmts.each do |stmt|
      case stmt
      when MIR::WhileStmt, MIR::ForStmt
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
        check_loop_rewind!(stmt.body)

      when MIR::IfStmt
        check_loop_rewind!(stmt.then_body)
        check_loop_rewind!(stmt.else_body)
      when MIR::ScopeBlock, MIR::BlockExpr
        check_loop_rewind!(stmt.body)
      when MIR::SwitchStmt, MIR::UnionMatchStmt
        stmt.arms&.each { |a| check_loop_rewind!(a[:body]) }
        check_loop_rewind!(stmt.default_body)
      when MIR::IfChain
        stmt.branches&.each { |b| check_loop_rewind!(b[:body]) }
        check_loop_rewind!(stmt.default_body)
      when MIR::SnapshotRead, MIR::SnapshotTransaction, MIR::SnapshotMultiTxn
        check_loop_rewind!(stmt.body)
      when MIR::WithMatchDispatch
        stmt.arms&.each { |a| check_loop_rewind!(a[:body]) }
      end
    end
  end

  # Does this statement list contain a per-iteration loop restore?
  # Looks for DeferStmt(MethodCall("restoreLoopMark")) -- the actual structure
  # emitted by the lowerer when mark_per_iter is true.
  # Uses the same traversal rules as body_has_frame_alloc? and check_loop_rewind!:
  # recurse into branches/blocks, stop at nested loops (they have their own restore).
  sig { params(stmts: T.nilable(T::Array[T.untyped])).returns(T::Boolean) }
  def body_has_loop_restore?(stmts)
    return false unless stmts.is_a?(Array)
    stmts.any? do |s|
      case s
      when MIR::DeferStmt
        s.body.is_a?(MIR::MethodCall) && s.body.method == "restoreLoopMark"
      when MIR::IfStmt
        body_has_loop_restore?(s.then_body) || body_has_loop_restore?(s.else_body)
      when MIR::ScopeBlock, MIR::BlockExpr
        body_has_loop_restore?(s.body)
      when MIR::SwitchStmt, MIR::UnionMatchStmt
        (s.arms&.any? { |a| body_has_loop_restore?(a[:body]) }) ||
          body_has_loop_restore?(s.default_body)
      when MIR::IfChain
        (s.branches&.any? { |b| body_has_loop_restore?(b[:body]) }) ||
          body_has_loop_restore?(s.default_body)
      when MIR::SnapshotRead, MIR::SnapshotTransaction, MIR::SnapshotMultiTxn
        body_has_loop_restore?(s.body)
      when MIR::WithMatchDispatch
        s.arms&.any? { |a| body_has_loop_restore?(a[:body]) }
      # MIR::WhileStmt, MIR::ForStmt: stop -- nested loops checked independently
      else
        false
      end
    end
  end

  # Does this statement list contain iteration-scoped frame allocations,
  # recursing into branch/block nodes but stopping at nested loop and
  # fiber/lambda boundaries.
  sig { params(stmts: T.nilable(T::Array[T.untyped])).returns(T::Boolean) }
  def body_has_iteration_frame_alloc?(stmts)
    body_has_frame_alloc_scope?(stmts) { |scope| scope == :iteration }
  end

  sig { params(stmts: T.nilable(T::Array[T.untyped])).returns(T::Boolean) }
  def body_has_non_iteration_frame_alloc?(stmts)
    body_has_frame_alloc_scope?(stmts) { |scope| scope != :iteration }
  end

  # Does this statement list contain frame allocations matching a scope
  # predicate, recursing into all
  # branch/block nodes (IfStmt, SwitchStmt, IfChain, ScopeBlock, BlockExpr)
  # but stopping at nested loop and fiber/lambda boundaries.
  # Mirrors the same traversal used by check_loop_rewind! so both methods
  # see the same nodes -- no special-cased paths.
  sig { params(stmts: T.nilable(T::Array[T.untyped]), block: T.proc.params(arg0: Symbol).returns(T::Boolean)).returns(T::Boolean) }
  def body_has_frame_alloc_scope?(stmts, &block)
    return false unless stmts.is_a?(Array)
    stmts.any? do |s|
      case s
      when MIR::AllocMark
        next false unless s.alloc == :frame
        scope = T.unsafe(s).scope
        scope = scope.is_a?(Symbol) ? scope : :unknown
        block.call(scope)
      when MIR::IfStmt
        body_has_frame_alloc_scope?(s.then_body, &block) || body_has_frame_alloc_scope?(s.else_body, &block)
      when MIR::ScopeBlock, MIR::BlockExpr
        body_has_frame_alloc_scope?(s.body, &block)
      when MIR::SwitchStmt, MIR::UnionMatchStmt
        s.arms.any? { |a| body_has_frame_alloc_scope?(a[:body], &block) } ||
          body_has_frame_alloc_scope?(s.default_body, &block)
      when MIR::IfChain
        s.branches.any? { |b| body_has_frame_alloc_scope?(b[:body], &block) } ||
          body_has_frame_alloc_scope?(s.default_body, &block)
      when MIR::SnapshotRead, MIR::SnapshotTransaction, MIR::SnapshotMultiTxn
        body_has_frame_alloc_scope?(s.body, &block)
      when MIR::WithMatchDispatch
        s.arms.any? { |a| body_has_frame_alloc_scope?(a[:body], &block) }
      # MIR::WhileStmt, MIR::ForStmt: stop -- nested loops are checked independently
      # MIR::BgBlock, MIR::LambdaExpr: stop -- separate fiber/function frame scopes
      else
        false
      end
    end
  end

  # Does this MIR expression node perform a frame allocation?
  # Backing-store mutations (mutates_receiver) are excluded: they extend an
  # existing container's backing store under that container's own allocator.
  # The container's outer-scope rewind handles cleanup — per-iteration rewind
  # would corrupt accumulated data. Only NEW ephemeral objects need loop marks.
  sig { params(expr: T.untyped).returns(T.nilable(T::Boolean)) }
  def expr_has_frame_alloc?(expr)
    return false unless expr
    case expr
    when MIR::InlineZig
      return false if expr.stdlib_def&.mutates_receiver?
      expr.allocs&.any? { |_k, v| v == :frame }
    when MIR::DupeSlice, MIR::ConcatStr, MIR::HeapCreate, MIR::AllocSlice,
         MIR::ContainerInit, MIR::MakeList, MIR::DeepCopy, MIR::CapWrap
      expr.alloc == :frame
    when MIR::RawZig
      expr.code.is_a?(String) && expr.code.include?("frameAlloc()")
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
  sig { params(kind: Symbol, name: String, msg: String).returns(String) }
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
  #   HeapCreate, owned-return Call, non-mutating allocator-bearing InlineZig,
  #   DupeSlice, HeapCreate, ConcatStr, AllocSlice, MakeList, CapWrap,
  #   SharePromote,
  #   DeepCopy (strategy != :passthrough), ContainerInit (alloc != nil)

  sig { params(body: T::Array[T.untyped]).returns(T::Array[T.untyped]) }
  def verify_unhoisted_allocs!(body)
    T.must(check_stmts_for_unhoisted(body))
  end

  sig { params(stmts: T.nilable(T::Array[T.untyped])).returns(T.nilable(T::Array[T.untyped])) }
  def check_stmts_for_unhoisted(stmts)
    return unless stmts.is_a?(Array)
    stmts.each { |s| check_stmt_for_unhoisted(s) }
  end

  sig { params(node: T.untyped).returns(T.nilable(T::Array[T.untyped])) }
  def check_stmt_for_unhoisted(node)
    return unless node
    case node
    when MIR::Let
      # init is the one allowed position for an allocating expression.
      # Recurse into sub-expressions of init (nested allocs still flagged).
      check_expr_for_unhoisted(node.init, allow_top: true)
    when MIR::Set
      check_expr_for_unhoisted(node.target, allow_top: false)
      # Set.value: the receiving variable's Cleanup covers the allocation.
      check_expr_for_unhoisted(node.value, allow_top: true)
    when MIR::ReassignWithCleanup
      # ReassignWithCleanup.value: the emitter wraps this in `const __new_x = value;`
      # inside a block, so it IS in a named binding. The variable's Cleanup covers it.
      check_expr_for_unhoisted(node.value, allow_top: true)
    when MIR::ExprStmt
      check_expr_for_unhoisted(node.expr, allow_top: false)
    when MIR::DiscardOwned
      check_expr_for_unhoisted(node.expr, allow_top: true)
    when MIR::ReturnStmt
      check_expr_for_unhoisted(node.value, allow_top: false)
    when MIR::BreakStmt
      check_expr_for_unhoisted(node.value, allow_top: false)
    when MIR::IfStmt
      check_expr_for_unhoisted(node.cond, allow_top: false)
      check_stmts_for_unhoisted(node.then_body)
      check_stmts_for_unhoisted(node.else_body)
    when MIR::IfBindStmt
      node.bindings&.each { |binding| check_expr_for_unhoisted(binding[:expr], allow_top: true) }
      check_stmts_for_unhoisted(node.then_body)
      check_stmts_for_unhoisted(node.else_body)
    when MIR::WhileStmt
      check_expr_for_unhoisted(node.cond, allow_top: node.capture ? true : false)
      check_stmts_for_unhoisted(node.body)
    when MIR::ForStmt
      check_expr_for_unhoisted(node.iter, allow_top: false)
      check_stmts_for_unhoisted(node.body)
    when MIR::ScopeBlock, MIR::BlockExpr
      check_stmts_for_unhoisted(node.body)
    when MIR::SwitchStmt, MIR::UnionMatchStmt
      check_expr_for_unhoisted(node.subject, allow_top: false)
      node.arms&.each { |a| check_stmts_for_unhoisted(a[:body]) }
      check_stmts_for_unhoisted(node.default_body)
    when MIR::IfChain
      node.branches&.each do |b|
        check_expr_for_unhoisted(b[:cond], allow_top: false)
        check_stmts_for_unhoisted(b[:body])
      end
      check_stmts_for_unhoisted(node.default_body)
    when MIR::DeferStmt    then check_stmt_for_unhoisted(node.body)
    when MIR::ErrDeferStmt then check_stmt_for_unhoisted(node.body)
    when MIR::BatchWindowPush
      check_expr_for_unhoisted(node.item_expr, allow_top: false)
      check_expr_for_unhoisted(node.value_expr, allow_top: false)
    when MIR::BatchWindowFlush
      check_expr_for_unhoisted(node.value_expr, allow_top: false)
    when MIR::SnapshotRead, MIR::SnapshotTransaction, MIR::SnapshotMultiTxn
      check_stmts_for_unhoisted(node.body)
    when MIR::WithMatchDispatch
      node.arms&.each { |a| check_stmts_for_unhoisted(a[:body]) }
    when MIR::FnDef
      check_stmts_for_unhoisted(node.body)
    end
  end

  # Check expr for allocating nodes in non-Let-init position.
  # allow_top: true  => expr itself may be an allocating node (it IS the Let.init)
  # allow_top: false => flag expr if it is an allocating node
  # In both cases, recurse into sub-expressions with allow_top: false.
  sig { params(expr: T.untyped, allow_top: T::Boolean).returns(T.nilable(T::Array[T.untyped])) }
  def check_expr_for_unhoisted(expr, allow_top:)
    return unless expr
    # Cast is a transparent wrapper (no allocation itself). Propagate allow_top so
    # an allocating expr (e.g. MakeList) inside a Cast in Let-init position is not
    # flagged. lower() wraps MakeList in Cast for element-type coercions.
    if expr.is_a?(MIR::Cast)
      check_expr_for_unhoisted(expr.expr, allow_top: allow_top)
      return
    end
    if expr.is_a?(MIR::TryExpr)
      check_expr_for_unhoisted(expr.expr, allow_top: allow_top)
      return
    end
    if expr.is_a?(MIR::TryCatch)
      check_expr_for_unhoisted(expr.expr, allow_top: allow_top)
      check_expr_for_unhoisted(expr.catch_body, allow_top: allow_top)
      return
    end
    if expr.is_a?(MIR::Orelse)
      check_expr_for_unhoisted(expr.expr, allow_top: allow_top)
      check_expr_for_unhoisted(expr.fallback, allow_top: allow_top)
      return
    end
    if expr.is_a?(MIR::IfOptional)
      check_expr_for_unhoisted(expr.optional, allow_top: false)
      check_expr_for_unhoisted(expr.then_expr, allow_top: allow_top)
      check_expr_for_unhoisted(expr.else_expr, allow_top: allow_top)
      return
    end
    if expr.is_a?(MIR::Pipeline)
      if !allow_top && allocating_expr?(expr)
        @errors << error(:UNHOISTED_ALLOC, @fn_name,
          "Pipeline in non-Let-init position (must be hoisted to a named variable)")
        return
      end
      check_expr_for_unhoisted(expr.inner, allow_top: allow_top)
      return
    end
    # CapWrap composes a sync/ownership layer around an inner data-shape
    # allocation. The outer CapWrap is the alloc-tracked node (AllocMark);
    # the inner ContainerInit's lifetime is owned by the wrapper. Treat
    # CapWrap.inner as if it were in Let-init position so the inner
    # ContainerInit is not flagged as unhoisted.
    if expr.is_a?(MIR::CapWrap)
      # Top-level CapWrap is also subject to the allow_top check.
      if !allow_top && allocating_expr?(expr)
        @errors << error(:UNHOISTED_ALLOC, @fn_name,
          "CapWrap in non-Let-init position (must be hoisted to a named variable)")
        return
      end
      check_expr_for_unhoisted(expr.inner, allow_top: true) if expr.inner
      return
    end
    if !allow_top && allocating_expr?(expr)
      kind = expr.class.name.split("::").last
      @errors << error(:UNHOISTED_ALLOC, @fn_name,
        "#{kind} in non-Let-init position (must be hoisted to a named variable)")
      return  # one error per site -- don't recurse into nested allocs
    end
    each_sub_expr(expr) { |sub| check_expr_for_unhoisted(sub, allow_top: false) }
    nil
  end

  sig { params(expr: T.untyped).returns(T::Boolean) }
  # MIR result nodes whose `allocates?` decision is just "has finalized
  # allocator placement". Heap allocations need cleanup/transfer; frame
  # allocations need loop-rewind proof. Either way, unnamed nested allocation is
  # unverifiable.
  ALLOC_PLACED_MIR_CLASSES = [
    MIR::DupeSlice, MIR::AllocSlice, MIR::MakeList, MIR::ConcatStr,
    MIR::CapWrap, MIR::SharePromote, MIR::ContainerInit,
  ].freeze

  def allocating_expr?(expr)
    return false unless expr && expr.respond_to?(:ownership_effect)
    effect = expr.ownership_effect
    effect.produces_owned && (!effect.alloc || VALID_ALLOCATORS.include?(effect.alloc))
  end

  # Yield each immediate sub-expression of expr.
  # Stops at opaque boundaries (RawZig, InlineZig, BgBlock).
  # BlockExpr bodies are walked separately by check_stmts_for_unhoisted.
  sig { params(expr: T.untyped, blk: T.untyped).void }
  def each_sub_expr(expr, &blk)
    return unless expr.is_a?(MIR::Emittable)
    expr.child_exprs.each { |child| yield child }
    nil
  end
end
