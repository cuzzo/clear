# typed: strict
require "sorbet-runtime"
require_relative '../ast/type'
require_relative '../semantic/capability_plan'
require_relative 'fsm_ops'
require_relative 'fsm_transform/lowering_protocol'

# FSM lowering support helpers. Mixed into MIRLowering as a module
# so the helpers share the lowering's explicit function/capture state and
# core helpers (lower,
# with_fiber_capture_map, hoist_alloc, ...).
#
# Top-level FSM emission lives in src/mir/fsm_transform.rb +
# src/mir/fsm_transform/{recursive_splitter,emit,suspend_resolvers,
# liveness}.rb -- this file holds only what those need from the
# rest of the lowering pipeline:
#
#   lower_step_stmts                   -- AST stmt list -> MIR
#                                          (consults capture_state.do_capture_map)
#   fsm_cap_metadata                   -- per-cap lock-acquire metadata
#                                          (try_method, alias_data_ref,
#                                          retries) used by
#                                          Emit.expand_lock_segment
#   emit_fsm_lock_error_arm_split      -- ON-clause error-arm MIR
#                                          planner for the
#                                          FsmTailRetryOrError fail step
#   default_fsm_lock_error_arm_split   -- default error-arm MIR when
#                                          no ON clause is present
module FsmLowering
    extend T::Sig
  include FsmTransform::LoweringProtocol
  include Kernel

  FsmCapMetadataValue = T.type_alias { T.any(String, Integer, Symbol, CapabilityPlan::CapabilityTransition) }
  FsmCapMetadata = T.type_alias { T::Hash[Symbol, FsmCapMetadataValue] }
  FsmAstResultNode = T.type_alias { T.nilable(T.any(AST::Node, AST::RawBody)) }
  FsmCapturedMap = T.type_alias { T::Hash[String, Type] }
  class FsmLockErrorArmSplit < T::Struct
    const :body_stmts, T::Array[MIR::Node]
    const :exit_kind, Symbol
  end

  sig { returns(T::Hash[String, String]) }
  def fsm_fn_name_rename_map
    T.bind(self, MIRLowering) rescue nil
    function_state.fn_name_rename_map
  end

  sig { returns(T::Hash[String, CleanupEntry]) }
  def fsm_current_bindings
    T.bind(self, MIRLowering) rescue nil
    function_state.current_bindings
  end

  sig { returns(T::Hash[String, T::Boolean]) }
  def fsm_guarded_cleanup_names
    T.bind(self, MIRLowering) rescue nil
    function_state.guarded_cleanup_names
  end

  sig { params(name: String).returns(String) }
  def fsm_zig_safe_name(name)
    T.cast(T.unsafe(self).__send__(:zig_safe_name, name), String)
  end

  # Lower a list of statements and produce Zig text. If no_result is
  # true, all stmts are emitted as intermediates. Otherwise the last
  # stmt may set `__ctx_N.inner.result = ...;` (for non-void result
  # types). Mirrors the inner loop of lower_bg_block but exposed as a
  # helper so Phase B2 can call it twice (once for pre-stmts, once for
  # Lower a list of step statements to one logical MIR body. Value-producing
  # FSM segments keep the final result assignment in the same body as the
  # statements that created the value, so ownership finalization sees the
  # cleanup and the transfer together.
  #
  # The "result" segment for value-producing FSM steps is the
  # final expression's MIR plus any pending hoists, wrapped in a
  # typed MIR::Set assignment to ctx.inner.result. The strip-try
  # rewrite is applied to the lowered MIR via the existing
  # `strip_try` helper.
  sig { params(stmts: T::Array[AST::Node], no_result: T::Boolean, ctx_id: T.nilable(Integer)).returns(T::Array[MIR::Emittable]) }
  def lower_step_stmts(stmts, no_result:, ctx_id: nil)
    T.bind(self, MIRLowering) rescue {}
    flat_steps = T.let([], T::Array[AST::ThenStep])
    stmts.each do |stmt|
      if stmt.is_a?(AST::ThenChain)
        stmt.steps.each { |s| flat_steps << s }
      else
        flat_steps << AST::ThenStep.new(expr: stmt, binding: nil)
      end
    end

    if no_result
      out = T.let([], T::Array[MIR::Emittable])
      flat_steps.each do |step|
        chunk = lower_one_step_to_mir(step)
        out.concat(chunk) if chunk
      end
      out
    else
      last_step = flat_steps.pop
      pre_mir = []
      flat_steps.each do |step|
        chunk = lower_one_step_to_mir(step)
        pre_mir.concat(chunk) if chunk
      end

      result_mir = T.let([], T::Array[MIR::Emittable])
      if last_step
        expr_type = last_step.expr.full_type!
        expr_t = expr_type.is_a?(Type) ? expr_type : Type.new(expr_type)
        result_alloc = escaping_value_alloc(expr_t)
        raw_last_mir = with_decl_alloc(result_alloc) { lower(last_step.expr) }
        last_mir = T.let(raw_last_mir.is_a?(MIR::Emittable) ? raw_last_mir : nil, T.nilable(MIR::Node))
        last_mir = place_value_for_destination(last_mir, last_step.expr, result_alloc, expr_t) if last_mir
        last_mir = hoist_alloc(last_mir, last_step.expr, err_cleanup: true) if last_mir && mir_allocates?(last_mir)
        last_pending = flush_pending
        result_mir.concat(last_pending)

        last_is_assign = last_step.expr.is_a?(AST::Assignment)
        is_step_void = ast_void_type?(expr_type)

        if last_mir && (last_is_assign || is_step_void)
          stmt_mir = wrap_step_as_stmt(AST::ThenStep.new(expr: last_step.expr, binding: nil), last_mir)
          result_mir << stmt_mir if stmt_mir
        elsif last_mir
          # Synthetic: __ctx_<id>.inner.result = <expr-without-try>;
          # As MIR: target is a typed FieldGet path, value is the
          # lowered expression with try stripped (since the
          # surrounding `inner.result = X` doesn't propagate errors;
          # the call expression's inner errors stay as anyerror!T
          # values stored in the result field). Both branches now
          # emit MIR::Set against the same typed target -- no
          # opaque Zig text in the FSM-IO post-result line.
          ctx_ident = MIR::Ident.new("__ctx_#{ctx_id}")
          target = MIR::FieldGet.new(
            MIR::FieldGet.new(ctx_ident, "inner"),
            "result",
          )
          # The fiber's tail value is escape-placed on the heap like any
          # other escaping binding; the promise stores it directly and
          # the consumer (NEXT) owns and frees it. No per-promise
          # allocator, no dupe.
          result_value = coerce_fsm_result_value(strip_try(last_mir), expr_t)
          result_set = MIR::Set.new(target, result_value, false)
          transfer_facts = fsm_result_transfer_facts(last_mir, last_step.expr)
          capture_state.last_fsm_result_transfer_facts.concat(transfer_facts)
          guard_fsm_result_cleanup!(result_mir, transfer_facts)
          transfer_names = transfer_facts.map(&:name).uniq
          if transfer_names.any?
            result_set = with_ownership_consumption(
              result_set,
              transfer_names,
              "fsm_result",
              :owned_sink,
              target_alloc: uniform_fsm_result_target_alloc(transfer_facts),
            )
          end
          result_mir << result_set
          result_mir.concat(transfer_facts.flat_map(&:marks))
          last_expr = last_step.expr
          if last_expr.is_a?(AST::Identifier)
            guard_map = capture_state.current_fsm_owned_result_guards
            guard_name = guard_map[last_expr.name.to_s]
            if guard_name
              result_mir << MIR::Set.new(
                MIR::FieldGet.new(ctx_ident, guard_name),
                MIR::Lit.new("false"),
                false,
              )
            end
          end
        end
      end

      guarded_result = last_step ? guard_shared_node_statement(last_step.expr, result_mir) : result_mir
      pre_mir + guarded_result
    end
  end

  sig { params(facts: T::Array[MIR::FsmResultTransferFact]).returns(T.nilable(Symbol)) }
  def uniform_fsm_result_target_alloc(facts)
    allocs = facts.map(&:target_alloc).uniq
    allocs.length == 1 ? allocs.first : nil
  end

  sig { params(value: MIR::Node, result_type: Type).returns(MIR::Node) }
  def coerce_fsm_result_value(value, result_type)
    return value unless result_type.integer?
    return value if value.is_a?(MIR::Cast)

    MIR::Cast.new(value, result_type.zig_type, :intCast)
  end

  sig { params(body: T::Array[MIR::Node], facts: T::Array[MIR::FsmResultTransferFact]).void }
  def guard_fsm_result_cleanup!(body, facts)
    rename_map = fsm_fn_name_rename_map
    guarded_cleanup_names = fsm_guarded_cleanup_names
    facts.each do |fact|
      next unless fact.move_guarded
      body.each do |node|
        next unless node.is_a?(MIR::Cleanup) || node.is_a?(MIR::ErrCleanup)
        node_name = node.name.to_s
        rendered_name = rename_map.fetch(node_name, node_name)
        next unless node_name == fact.name || rendered_name == fact.name

        node.cleanup_entry.mark_moved_guard!
        guarded_cleanup_names[fact.name] = true
      end
    end
    nil
  end

  sig { params(result_mir: MIR::Node, ast_node: AST::Node).returns(T::Array[MIR::Stmt]) }
  def fsm_result_transfer_marks(result_mir, ast_node)
    fsm_result_transfer_facts(result_mir, ast_node).flat_map(&:marks)
  end

  sig { params(result_mir: MIR::Node, ast_node: AST::Node).returns(T::Array[MIR::FsmResultTransferFact]) }
  def fsm_result_transfer_facts(result_mir, ast_node)
    rename_map = fsm_fn_name_rename_map
    bindings = fsm_current_bindings
    guarded_cleanup_names = fsm_guarded_cleanup_names
    facts = T.let([], T::Array[MIR::FsmResultTransferFact])
    result_owner = T.let(result_mir, MIR::Node)
    loop do
      case result_owner
      when MIR::TryExpr, MIR::Cast
        result_owner = result_owner.expr
      else
        break
      end
    end
    result_type = Type.from_node!(ast_node, context: "FSM result owner")
    if result_owner.is_a?(MIR::Ident) && T.unsafe(self).ownership_tracked_transfer_type?(result_type)
      owner_name = result_owner.name.to_s
      owner_name = rename_map.fetch(owner_name, owner_name)
      mir_entry = bindings[result_owner.name.to_s] || bindings[owner_name] || CleanupEntry::NONE
      if mir_entry.present?
        mir_entry.mark_moved_guard!
        guarded_cleanup_names[owner_name] = true
      end
      facts << MIR::FsmResultTransferFact.new(
        name: owner_name,
        target_alloc: mir_entry.present? ? mir_entry.alloc : :heap,
        move_guarded: true,
      )
      return facts
    end
    consumed = fsm_ast_result_consumed_roots(ast_node)
    consumed.each do |name|
      safe = fsm_zig_safe_name(name.to_s)
      safe = rename_map.fetch(safe, safe)
      binding_entry = bindings[name.to_s] || bindings[safe.to_s] || CleanupEntry::NONE
      next unless binding_entry.present?
      guarded = binding_entry.has_moved_guard? || guarded_cleanup_names[safe.to_s] == true
      facts << MIR::FsmResultTransferFact.new(
        name: safe.to_s,
        target_alloc: binding_entry.alloc,
        move_guarded: guarded,
      )
    end
    facts
  end

  sig { params(node: FsmAstResultNode).returns(T::Array[String]) }
  def fsm_ast_result_consumed_roots(node)
    names = T.let([], T::Array[String])
    case node
    when AST::MoveNode
      if node.value.is_a?(AST::Identifier)
        names << node.value.name.to_s
      else
        names.concat(fsm_ast_result_consumed_roots(node.value))
      end
    when AST::Identifier
      names << node.name.to_s if AST.moved?(node) || fsm_owned_transfer_identifier?(node)
    when AST::StructLit, AST::UnionVariantLit
      node.fields&.each_value do |value|
        next if value.is_a?(AST::CopyNode)
        if value.is_a?(AST::Identifier)
          names << value.name.to_s if fsm_owned_transfer_identifier?(value)
        else
          names.concat(fsm_ast_result_consumed_roots(value))
        end
      end
    when AST::ListLit
      node.items&.each do |item|
        next if item.is_a?(AST::CopyNode)
        names.concat(fsm_ast_result_consumed_roots(item))
      end
    end
    names.uniq
  end

  sig { params(node: AST::Identifier).returns(T::Boolean) }
  def fsm_owned_transfer_identifier?(node)
    rename_map = fsm_fn_name_rename_map
    bindings = fsm_current_bindings
    ti = node.full_type!(context: "FSM owned transfer identifier")
    return false unless T.unsafe(self).ownership_tracked_transfer_type?(ti)
    safe = fsm_zig_safe_name(node.name.to_s)
    safe = rename_map.fetch(safe, safe)
    entry = bindings[node.name.to_s] || bindings[safe.to_s] || CleanupEntry::NONE
    (entry.present? && entry.heap?) || node.symbol&.heap_storage? == true
  end

  # Lower one step expression into a list of MIR statements
  # (pending hoists + the wrapped main statement). Returns nil
  # when the underlying lowering fails (e.g. the AST node has no
  # MIR equivalent yet).
  sig { params(step: AST::ThenStep).returns(T::Array[MIR::Emittable]) }
  def lower_one_step_to_mir(step)
    T.bind(self, MIRLowering) rescue nil
    mir = lower(step.expr)
    return [] if mir.nil?
    pending = flush_pending
    # `lower_var_decl` may return an Array (e.g. [AllocMark, Let,
    # Cleanup]) for cleanup-needing bindings. After the FreshHeapCopy
    # capture wiring on master's BG path, this also arrives inside
    # FSM-lowered bodies. Each element is its own statement; the
    # binding (if any) is already absorbed into the MIR::Let inside
    # the array.
    if mir.is_a?(Array)
      return guard_shared_node_statement(step.expr, pending + mir.compact)
    end
    return [] unless mir.is_a?(MIR::Emittable)

    main = wrap_step_as_stmt(step, mir)
    return pending if main.nil?
    guard_shared_node_statement(step.expr, pending + [main])
  end

  # Wrap an expression-shaped MIR node as a statement-shaped node
  # using the step's binding metadata + the AST node's type info
  # to decide between MIR::Let, MIR::ExprStmt(discard), and
  # MIR::ExprStmt(value-as-statement). Statement-shaped nodes
  # (MIR::Let, MIR::Set, MIR::IfStmt, MIR::BgBlock, ...) pass
  # through unchanged.
  sig { params(step: AST::ThenStep, mir: MIR::Emittable).returns(T.nilable(MIR::Emittable)) }
  def wrap_step_as_stmt(step, mir)
    T.bind(self, MIRLowering) rescue nil
    binding = step.binding
    if binding
      return MIR::Let.new(binding, mir, false, nil, nil)
    end
    return mir if mir.stmt?
    expr_type = step.expr.full_type!
    is_void_step = ast_void_type?(expr_type)
    MIR::ExprStmt.new(mir, !is_void_step)
  end

  sig { params(stmts: T::Array[AST::Node], no_result: T::Boolean, ctx_id: T.nilable(Integer)).returns(T::Array[MIR::Node]) }
  def lower_finalized_fsm_step_mir(stmts, no_result:, ctx_id: nil)
    T.bind(self, MIRLowering) rescue {}
    capture_state.last_fsm_result_transfer_facts = []
    result = lower_step_stmts(stmts, no_result: no_result, ctx_id: ctx_id)
    inherited_allocs = capture_state.current_fsm_inherited_alloc_names
    inherited_guards = capture_state.current_fsm_inherited_guarded_names
    append_ownership_transfers_for_mir_body(result, inherited_allocs, inherited_guards)
  end

  sig { returns(T::Array[MIR::FsmResultTransferFact]) }
  def last_fsm_result_transfer_facts
    T.bind(self, MIRLowering)
    capture_state.last_fsm_result_transfer_facts
  end

  sig do
    type_parameters(:Result)
      .params(
        pointer_captures: T::Set[String],
        inherited_alloc_names: T::Set[String],
        inherited_guard_names: T::Set[String],
        owned_result_guards: T::Hash[String, String],
        blk: T.proc.returns(T.type_parameter(:Result)),
      )
      .returns(T.type_parameter(:Result))
  end
  def with_fsm_segment_lowering_context(pointer_captures:, inherited_alloc_names:, inherited_guard_names:, owned_result_guards:, &blk)
    T.bind(self, MIRLowering)
    prev_result_guards = capture_state.current_fsm_owned_result_guards
    prev_alloc_names = capture_state.current_fsm_inherited_alloc_names
    prev_guard_names = capture_state.current_fsm_inherited_guarded_names

    begin
      capture_state.current_fsm_inherited_alloc_names = inherited_alloc_names
      capture_state.current_fsm_inherited_guarded_names = inherited_guard_names
      capture_state.current_fsm_owned_result_guards = owned_result_guards
      with_bg_fiber_body_context(pointer_captures, &blk)
    ensure
      capture_state.current_fsm_owned_result_guards = prev_result_guards
      capture_state.current_fsm_inherited_guarded_names = prev_guard_names
      capture_state.current_fsm_inherited_alloc_names = prev_alloc_names
    end
  end

  # Resolve ONE capability's lock-acquire metadata. Returns
  # { try_method, unlock_method, lock_field_ref, alias_name,
  #   alias_data_ref, retries, lock_kind, cap } or nil if `cap`
  # isn't a lock-suspending capability or its target isn't a BG
  # capture. Consumed by FsmTransform::Emit.expand_lock_segment
  # (per-cap fan-out) for both single-cap and multi-cap WITH.
  sig { params(cap: CapabilityPlan::CapabilityTransition, with_node: AST::WithBlock, ctx_id: Integer, captured: FsmCapturedMap).returns(T.nilable(FsmCapMetadata)) }
  def fsm_cap_metadata(cap, with_node, ctx_id, captured)
    T.bind(self, MIRLowering) rescue nil
    return nil unless cap.capability == :EXCLUSIVE ||
                      cap.capability == :write_locked_read

    var_node = cap.var_node
    return nil unless var_node.is_a?(AST::Identifier)
    lock_var_name = var_node.name
    alias_name = cap.alias_name
    return nil unless captured.key?(lock_var_name)

    resolved = cap.resolved_type
    any_rc       = resolved&.any_rc?
    write_locked = resolved&.write_locked?
    # A polymorphic LOCKED param (REQUIRES c: LOCKED on a `c: T`
    # signature) carries sync=:locked but ownership=:affine — its
    # runtime type may still be Arc(Locked(T)) or Rc(Locked(T)),
    # depending on the caller. The bare base_field path would emit
    # `c.tryLockForFsm()` against the Arc, which has no such method.
    # Probe via comptime @hasField so the same FSM body works for
    # bare and Arc/Rc-wrapped callers.
    is_param = var_node.symbol&.is_param
    polymorphic_locked = is_param && !any_rc &&
                         (!!resolved&.locked? || !!resolved&.write_locked?)
    lock_kind = if cap.capability == :write_locked_read
                  :rwlock_read
                elsif write_locked
                  :rwlock_write
                else
                  :mutex_excl
                end

    base_field     = "__ctx_#{ctx_id}.#{lock_var_name}"
    lock_field_ref = if any_rc
                       "#{base_field}.ctrl.data.*"
                     elsif polymorphic_locked
                       "(if (comptime @hasField(@TypeOf(#{base_field}), \"ctrl\")) #{base_field}.ctrl.data.* else #{base_field})"
                     else
                       base_field
                     end
    alias_data_ref = "(#{lock_field_ref}.data)"

    try_method, unlock_method = case lock_kind
                                when :rwlock_write then ["tryWriteLockForFsm", "unlock"]
                                when :rwlock_read  then ["tryReadLockForFsm",  "unlockShared"]
                                else                    ["tryLockForFsm",      "unlock"]
                                end

    retries = with_node.lock_error_clause&.retries || 0

    {
      cap:            cap,
      lock_kind:      lock_kind,
      try_method:     try_method,
      unlock_method:  unlock_method,
      lock_field_ref: lock_field_ref,
      alias_name:     alias_name,
      alias_data_ref: alias_data_ref,
      retries:        retries,
    }
  end
  # Plan the lock_error_clause action as MIR statements + exit kind for
  # the FsmTailRetryOrError fail step. Returns:
  #   { body_stmts: [MIR::Node], exit_kind: :done | :goto_post }
  #
  #   :done       -> fail-step segment uses Segments::Done as its
  #                  tail (sets inner.result + wg.done + destroy +
  #                  return Done). Body sets inner.result for
  #                  raise/exit/default.
  #   :goto_post  -> fail-step segment Gotos to the post-WITH
  #                  segment. Body is empty for :pass, the user
  #                  block for :block.
  sig { params(clause: AST::ErrorClause, ctx_id: Integer, with_node: AST::WithBlock, capture_map: T::Hash[String, String], pointer_captures: T::Set[String], bg_rt: String).returns(T.nilable(FsmLockErrorArmSplit)) }
  def emit_fsm_lock_error_arm_split(clause:, ctx_id:, with_node:,
                                    capture_map:, pointer_captures:, bg_rt:)
    T.bind(self, MIRLowering) rescue nil
    line = with_node.token&.line.to_s
    case clause.action
    when AST::ErrorActionKind::Raise
      FsmLockErrorArmSplit.new(
        body_stmts: lock_error_done_stmts(
          ctx_id,
          MIR::Lit.new('"lock acquire failed"'),
          line,
          "error.CheatError",
        ),
        exit_kind: :done,
      )
    when AST::ErrorActionKind::Exit
      message_mir = with_fiber_capture_map(capture_map, rt_override: bg_rt) do
        lower(T.must(clause.message))
      end
      return nil unless message_mir.is_a?(MIR::Emittable)
      FsmLockErrorArmSplit.new(
        body_stmts: lock_error_done_stmts(
          ctx_id,
          message_mir,
          line,
          "error.CheatError",
        ),
        exit_kind: :done,
      )
    when AST::ErrorActionKind::Pass
      FsmLockErrorArmSplit.new(body_stmts: [], exit_kind: :goto_post)
    when AST::ErrorActionKind::Block
      prev_bg_ptr_caps = capture_state.current_bg_pointer_captures
      prev_fiber_pending = function_state.pending_stmts
      block_mir = begin
        capture_state.current_bg_pointer_captures = pointer_captures
        function_state.pending_stmts = []
        with_fiber_capture_map(capture_map, rt_override: bg_rt) do
          lower_finalized_fsm_step_mir(clause.body, no_result: true)
        end
      ensure
        function_state.pending_stmts = prev_fiber_pending
        capture_state.current_bg_pointer_captures = prev_bg_ptr_caps
      end
      FsmLockErrorArmSplit.new(body_stmts: block_mir, exit_kind: :goto_post)
    else
      nil
    end
  end

  sig { params(ctx_id: Integer, message: MIR::Node, line: String, result_zig: String).returns(T::Array[MIR::Node]) }
  def lock_error_done_stmts(ctx_id, message, line, result_zig)
    [
      lock_error_set_error_stmt(ctx_id, message, line),
      lock_error_result_set(ctx_id, result_zig),
    ]
  end

  sig { params(ctx_id: Integer, message: MIR::Node, line: String).returns(MIR::ExprStmt) }
  def lock_error_set_error_stmt(ctx_id, message, line)
    MIR::ExprStmt.new(
      MIR::MethodCall.new(
        MIR::FieldGet.new(MIR::Ident.new("__ctx_#{ctx_id}"), "rt"),
        "setError",
        [
          MIR::EnumTag.new(variant: "Transient"),
          MIR::EnumOrdinal.new(MIR::FieldGet.new(MIR::Ident.new("ErrorName"), "LockTimeout")),
          message,
          MIR::Lit.new(line),
        ],
        false,
      ),
      false,
    )
  end

  sig { params(ctx_id: Integer, result_zig: String).returns(MIR::Set) }
  def lock_error_result_set(ctx_id, result_zig)
    result_name = result_zig.delete_prefix("error.")
    MIR::Set.new(
      MIR::FieldGet.new(
        MIR::FieldGet.new(MIR::Ident.new("__ctx_#{ctx_id}"), "inner"),
        "result",
      ),
      MIR::FieldGet.new(MIR::Ident.new("error"), result_name),
      false,
    )
  end

  # Default error arm MIR when no clause is present: surface as a
  # generic LockError (body sets inner.result; exit_kind = :done).
  sig { params(id: Integer).returns(FsmLockErrorArmSplit) }
  def default_fsm_lock_error_arm_split(id)
    T.bind(self, MIRLowering) rescue nil
    FsmLockErrorArmSplit.new(
      body_stmts: [lock_error_result_set(id, "error.LockError")],
      exit_kind: :done,
    )
  end

  private :fsm_owned_transfer_identifier?,
    :guard_fsm_result_cleanup!
  private :coerce_fsm_result_value
  private :fsm_ast_result_consumed_roots
  private :lock_error_done_stmts
  private :lock_error_set_error_stmt
  private :lower_one_step_to_mir
  private :lower_step_stmts
  private :uniform_fsm_result_target_alloc

end
