# typed: strict
require "sorbet-runtime"

module MIRLoweringControlFlow
    extend T::Sig
    extend T::Helpers

  requires_ancestor { MIRLowering }

  MatchBody = T.type_alias { T::Array[MIR::Emittable] }
  MatchDefaultBody = T.type_alias { T::Array[AST::Node] }
  IfBindAliasAllocMap = T.type_alias { T::Hash[String, T.nilable(Symbol)] }
  IfBindAliasOwnerMap = T.type_alias { T::Hash[String, String] }
  MatchTypeKey = T.type_alias { Symbol }

  class MatchLoweringFacts < T::Struct
    const :expr_label, T.nilable(String)
    const :subject, MIR::Node
    const :is_union, T::Boolean
    const :is_int_match, T::Boolean
    const :is_enum_match, T::Boolean
    const :expr_type_sym, MatchTypeKey
  end

  class UnionMatchArmPlan < T::Struct
    const :variant, String
    const :body, MatchBody
    const :payload_name, T.nilable(String)
  end

  class ForEachPlan < T::Struct
    const :var, String
    const :body, T::Array[MIR::Node]
    const :rt, MIR::Ident
    const :collection, MIR::Node
    const :collection_type, Type
    const :collection_setup, T::Array[MIR::Node]
    const :mutable, T::Boolean
    const :mark_per_iter, T.nilable(T::Boolean)
    const :tight, T::Boolean
  end

  class ForRangePlan < T::Struct
    const :var, String
    const :start_value, MIR::Node
    const :end_value, MIR::Node
    const :body, T::Array[MIR::Node]
    const :rt, MIR::Ident
    const :comparison, String
    const :iter_var, String
    const :mark_per_iter, T.nilable(T::Boolean)
    const :tight, T::Boolean
  end

  class ReturnOwnershipPlan < T::Struct
    extend T::Sig

    prop :value, T.nilable(MIR::Node)
    const :explicit_return_names, T::Set[String]
    const :moved_root_names, T::Set[String]
    const :consumed_root_names, T::Set[String]
	    const :direct_value_names, T::Set[String]
	    const :converted_cleanup_names, T::Set[String]
	    const :transfer_required_names, T::Set[String]
	    const :move_guard_required_names, T::Set[String]

    sig { returns(T::Set[String]) }
    def returned_names
      out = T.let(Set.new, T::Set[String])
      explicit_return_names.each { |name| out << name }
      moved_root_names.each { |name| out << name }
      consumed_root_names.each { |name| out << name }
      direct_value_names.each { |name| out << name }
      out
    end

    sig { params(value_names: T::Set[String], visible_guarded_names: T::Set[String]).returns(T::Array[MIR::Stmt]) }
    def transfer_marks_for(value_names, visible_guarded_names)
      names = T.let(Set.new, T::Set[String])
      value_names.each { |name| names << name }
      converted_cleanup_names.each { |name| names << name }

      names
        .select do |name|
          transfer_required_names.include?(name) ||
            converted_cleanup_names.include?(name) ||
            visible_guarded_names.include?(name)
        end
        .flat_map do |name|
          MIR::OwnershipTransferPlan.new(
	            name: name,
	            target: :return,
	            target_alloc: nil,
	            move_guarded: visible_guarded_names.include?(name) || move_guard_required_names.include?(name),
	          ).marks
	        end
	    end
  end

  sig { params(cond: MIR::Node, pending: T::Array[MIR::Node]).returns(MIR::Node) }
  def loop_condition_expr(cond, pending)
    T.bind(self, MIRLowering) rescue nil
    return cond if pending.empty?

    label = "__while_cond_#{lowering_counters.next_block_expr_id}"
    body = T.let([], T::Array[MIR::Node])
    pending.each do |stmt|
      body << stmt
      body.concat(ownership_facts_for_mir_surface(stmt))
    end
    MIR::BlockExpr.new(label, body + [MIR::BreakStmt.new(label, cond)])
  end

  sig { params(ast_node: AST::Node, transfers_to_capture: T::Boolean).returns(MIR::Node) }
  def lower_control_condition(ast_node, transfers_to_capture: false)
    lowerer = T.unsafe(self)
    lowered = lowerer.lower(ast_node)
    if lowerer.mir_allocates?(lowered)
      lowerer.hoist_alloc(lowered, ast_node, err_cleanup: transfers_to_capture)
    else
      lowered
    end
  end

  sig { params(node: AST::IfStatement).returns(MIR::Node) }
  def lower_if(node)
    T.bind(self, MIRLowering) rescue nil
    if node.condition.is_a?(AST::IsA) && node.condition.runtime_variant_name
      return lower_runtime_is_a_if(node, node.condition)
    end

    cond, cond_pending = lower_head { lower_control_condition(node.condition) }
    if node.expr_mode
      label = "__if_#{lowering_counters.next_block_expr_id}"
      then_body = lower_body_with_break(node.then_branch, label)
      else_body = lower_body_with_break(node.else_branch || [], label)
      if_stmt = MIR::IfStmt.new(cond, then_body, else_body)
      if_stmt.comptime = !!node.comptime
      block = MIR::BlockExpr.new(label, [if_stmt])
      return with_pending(cond_pending, block)
    end

    then_body = lower_body(node.then_branch)
    else_body = (node.else_branch && !node.else_branch.empty?) ? lower_body(node.else_branch) : nil
    if_stmt = MIR::IfStmt.new(cond, then_body, else_body)
    if_stmt.comptime = !!node.comptime
    with_pending(cond_pending, if_stmt)
  end

  sig { params(node: AST::IfStatement, condition: AST::IsA).returns(MIR::Node) }
  def lower_runtime_is_a_if(node, condition)
    T.bind(self, MIRLowering) rescue nil

    subject, subject_pending = lower_head { lower_control_condition(condition.left) }
    variant = T.must(condition.runtime_variant_name)
    cond = union_tag_condition(T.cast(subject, MIR::Emittable), variant)
    payload_bindings = runtime_is_a_payload_bindings(condition, T.cast(subject, MIR::Emittable), variant)

    if node.expr_mode
      label = "__if_#{lowering_counters.next_block_expr_id}"
      then_body = payload_bindings + lower_body_with_break(node.then_branch, label)
      else_body = lower_body_with_break(node.else_branch || [], label)
      block = MIR::BlockExpr.new(label, [MIR::IfStmt.new(cond, then_body, else_body)])
      return with_pending(subject_pending, block)
    end

    then_body = payload_bindings + lower_body(node.then_branch)
    else_body = (node.else_branch && !node.else_branch.empty?) ? lower_body(node.else_branch) : nil
    with_pending(subject_pending, MIR::IfStmt.new(cond, then_body, else_body))
  end

  sig { params(condition: AST::IsA, subject: MIR::Emittable, variant: String).returns(MatchBody) }
  def runtime_is_a_payload_bindings(condition, subject, variant)
    binding = condition.binding
    return [] unless binding

    payload = T.let(MIR::UnionPayloadGet.new(subject, variant), MIR::Emittable)
    payload = MIR::Deref.new(payload) if condition.runtime_indirect_payload_as
    is_mutable = condition.left.is_a?(AST::Identifier) && condition.left.was_moved == true
    [MIR::Let.new(binding, payload, is_mutable, nil, "_ = &#{binding};")]
  end

  sig { params(node: AST::IfBind).returns(MIR::IfBindStmt) }
  def lower_if_bind(node)
    T.bind(self, MIRLowering) rescue nil
    capture_markers = T.let([], T::Array[MIR::Stmt])
    mir_bindings = node.bindings.map do |b|
      expr, pending = lower_head do
        if mutable_struct_list_bind?(b.expr)
          index = T.cast(b.expr, AST::GetIndex)
          target = lower(index.target)
          # Collection parameters are pointer-shaped in the Zig ABI already.
          # Taking their address here produces **ArrayList and breaks the
          # optional mutable-element lookup. Locals still need their address.
          target = MIR::AddressOf.new(target) unless collection_param_receiver?(index.target)
          emit_builtin(:getAtPtrOpt, [target, lower(index.index)])
        else
          lower_control_condition(b.expr, transfers_to_capture: true)
        end
      end
      if (capture_cleanup = bind_capture_cleanup(b.expr))
        capture_name = b.name.to_s
        capture_type = Type.from_node!(b.expr)
        capture_markers << MIR::AllocMark.new(capture_name, :heap, capture_type, :function)
        capture_markers << MIR::Cleanup.new(capture_name, capture_cleanup)
      end
      {
        expr: b.predicate == :is_ok ? strip_try(loop_condition_expr(expr, pending)) : loop_condition_expr(expr, pending),
        capture: b.name,
        node_ref: Type.from_node!(b.expr).node_reference?,
        owns_capture: AST.capture_expr_owns_result?(b.expr),
        predicate: b.predicate,
      }
    end
    lowered_then = with_if_bind_alias_maps(node) { lower_body(node.then_branch) }
    # CleanupClassifier/MIRPass stamps production IF-bind bodies with the
    # capture AllocMark + Drop pair. Keep the fallback for directly-constructed
    # ASTs used by lowering clients, but never emit a second owner for the same
    # capture when the stamped pair is already present.
    existing_capture_names = lowered_then.filter_map do |stmt|
      stmt.name.to_s if stmt.is_a?(MIR::AllocMark)
    end.to_set
    capture_markers = capture_markers.reject do |stmt|
      stmt.respond_to?(:name) && existing_capture_names.include?(T.unsafe(stmt).name.to_s)
    end
    then_body = capture_markers + lowered_then

    else_body = (node.else_branch && !node.else_branch.empty?) ? lower_body(node.else_branch) : nil
    MIR::IfBindStmt.new(mir_bindings, then_body, else_body)
  end

  sig { params(expr: AST::Node).returns(T::Boolean) }
  def mutable_struct_list_bind?(expr)
    return false unless expr.is_a?(AST::GetIndex)

    receiver = expr.target.full_type!(context: "IF list binding receiver")
    result = expr.full_type!(context: "IF list binding result")
    inner = result.optional? ? T.must(result.wrapped_type) : result
    (receiver.list_collection? && inner.struct? && !inner.collection? && !inner.node_reference? &&
      !inner.link? && !inner.any_rc?) == true
  end

  sig { params(target: AST::Node).returns(T::Boolean) }
  def collection_param_receiver?(target)
    target.is_a?(AST::Identifier) && T.unsafe(self).__send__(:current_function_collection_param?, target.name)
  end

  sig do
    type_parameters(:Result)
      .params(node: AST::IfBind, blk: T.proc.returns(T.type_parameter(:Result)))
      .returns(T.type_parameter(:Result))
  end
  def with_if_bind_alias_maps(node, &blk)
    T.bind(self, MIRLowering) rescue nil
    prev_alias_alloc = capability_state.with_alias_alloc_map
    prev_alias_owner = capability_state.with_alias_owner_map
    alias_alloc_map = T.let((prev_alias_alloc || {}).dup, IfBindAliasAllocMap)
    alias_owner_map = T.let((prev_alias_owner || {}).dup, IfBindAliasOwnerMap)

    node.bindings.each do |binding|
      owner = extract_root_var_name(binding.expr)
      next unless owner

      alias_name = binding.name.to_s
      alias_owner_map[alias_name] = owner
      alias_alloc_map[alias_name] = placement_for_node(binding.expr)
    end

    capability_state.with_alias_alloc_map = alias_alloc_map
    capability_state.with_alias_owner_map = alias_owner_map
    blk.call
  ensure
    T.bind(self, MIRLowering) rescue nil
    capability_state.with_alias_alloc_map = prev_alias_alloc
    capability_state.with_alias_owner_map = prev_alias_owner
  end

  sig { params(expr: AST::Node).returns(T.nilable(CleanupEntry)) }
  def bind_capture_cleanup(expr)
    # Variable, field, and index optional access borrows from an existing
    # owner. Calls and explicit ownership-producing wrappers create a fresh
    # successful payload whose capture must be released at block exit.
    return nil unless AST.capture_expr_owns_result?(expr)

    ti = Type.from_node!(expr)
    ti = ti.success_type || ti
    return nil unless ti.any_rc? || (ti.optional? && ti.wrapped_type&.any_rc?)

    CleanupEntry.build(:rc, alloc: :heap, has_moved_guard: false)
  end

  # Single-source frame-arena marker injection for every loop shape
  # (lower_while / lower_while_bind / lower_for_each / lower_for_range).
  # When mark_per_iter is set by escape analysis (frame allocs that survive
  # past the iteration end would otherwise grow the arena unbounded),
  # prepend a saveLoopMark/restoreLoopMark pair so each iteration rewinds
  # to the pre-body high-water mark. `after_mark` is interposed between
  # the marker pair and the body (lower_for_range uses it for the
  # iteration-variable decl).
  sig { params(body: T::Array[MIR::Node], mark_per_iter: T.nilable(T::Boolean), tight: T::Boolean, after_mark: T::Array[MIR::Node]).returns(T::Array[MIR::Node]) }
  def prepend_loop_mark(body, mark_per_iter:, tight:, after_mark: [])
    T.bind(self, MIRLowering) rescue nil
    suffix = after_mark + body
    needs_mark = mark_per_iter == true
    return suffix unless !tight && needs_mark && current_function_has_rt?
    rt = MIR::Ident.new(runtime_binding_name)
    mark_var = "__loop_mark_#{lowering_counters.next_loop_mark_id}"
    save = MIR::Let.new(mark_var, MIR::MethodCall.new(rt, "saveLoopMark", [], false, MIR::CallableContract.no_ownership(0)), false, nil, nil)
    restore = MIR::DeferStmt.new(MIR::MethodCall.new(rt, "restoreLoopMark", [MIR::Ident.new(mark_var)], false, MIR::CallableContract.no_ownership(1)))
    [save, restore] + suffix
  end

  sig { params(stmts: T::Array[MIR::Node], scope: Symbol).void }
  def stamp_loop_frame_alloc_scopes!(stmts, scope)
    stmts.each do |s|
      case s
      when MIR::AllocMark
        s.scope = scope if MIR::Placement.frame?(s.alloc)
      when MIR::IfStmt, MIR::IfBindStmt
        stamp_loop_frame_alloc_scopes!(s.then_body, scope)
        stamp_loop_frame_alloc_scopes!(s.else_body, scope) if s.else_body
      when MIR::ScopeBlock, MIR::BlockExpr, MIR::SnapshotRead, MIR::SnapshotTransaction, MIR::SnapshotMultiTxn
        stamp_loop_frame_alloc_scopes!(s.body, scope)
      when MIR::SwitchStmt
        s.arms&.each { |a| stamp_loop_frame_alloc_scopes!(a.body, scope) }
        stamp_loop_frame_alloc_scopes!(s.default_body, scope) if s.default_body
      when MIR::IfChain
        s.branches&.each { |b| stamp_loop_frame_alloc_scopes!(b.body, scope) }
        stamp_loop_frame_alloc_scopes!(s.default_body, scope) if s.default_body
      when MIR::WithMatchDispatch
        s.arms&.each { |a| stamp_loop_frame_alloc_scopes!(a.body, scope) }
      end
    end
    nil
  end

  sig { params(stmts: T::Array[MIR::Node], mark_per_iter: T.nilable(T::Boolean)).void }
  def finalize_loop_frame_alloc_scopes!(stmts, mark_per_iter)
    stamp_loop_frame_alloc_scopes!(stmts, mark_per_iter == true ? :iteration : :function)
  end

  sig { params(node: AST::WhileLoop).returns(MIR::WhileStmt) }
  def lower_while(node)
    T.bind(self, MIRLowering) rescue nil
    rt = MIR::Ident.new(runtime_binding_name)
    cond, cond_pending = lower_head { lower_control_condition(node.condition) }
    b = node.do_branch
    body = b.is_a?(Array) ? lower_body(b) : []
    finalize_loop_frame_alloc_scopes!(body, node.mark_per_iter)

    tight = node.tight == true
    body = prepend_loop_mark(body, mark_per_iter: node.mark_per_iter, tight: tight)

    # Yield check at end of loop body (skip when last stmt is unconditional exit)
    if !tight && current_function_has_rt? && !loop_body_exits?(body)
      body << MIR::ExprStmt.new(MIR::MethodCall.new(rt, "checkYield", [], false, MIR::CallableContract.no_ownership(0)), false)
    end

    MIR::WhileStmt.new(loop_condition_expr(cond, cond_pending), body, nil, nil, node.mark_per_iter, tight)
  end

  sig { params(node: AST::WhileBindLoop).returns(MIR::WhileStmt) }
  def lower_while_bind(node)
    T.bind(self, MIRLowering) rescue nil
    rt = MIR::Ident.new(runtime_binding_name)
    cond, cond_pending = lower_head { lower_control_condition(node.condition, transfers_to_capture: true) }
    body = lower_body(node.do_branch)
    if (capture_cleanup = bind_capture_cleanup(node.condition))
      capture_name = node.binding_name.to_s
      capture_type = Type.from_node!(node.condition)
      unless body.any? { |stmt| stmt.is_a?(MIR::AllocMark) && stmt.name.to_s == capture_name }
        body = [
          MIR::AllocMark.new(capture_name, :heap, capture_type, :iteration),
          MIR::Cleanup.new(capture_name, capture_cleanup),
        ] + body
      end
    end
    finalize_loop_frame_alloc_scopes!(body, node.mark_per_iter)

    tight = node.tight == true
    body = prepend_loop_mark(body, mark_per_iter: node.mark_per_iter, tight: tight)

    if !tight && current_function_has_rt? && !loop_body_exits?(body)
      body << MIR::ExprStmt.new(MIR::MethodCall.new(rt, "checkYield", [], false, MIR::CallableContract.no_ownership(0)), false)
    end

    MIR::WhileStmt.new(loop_condition_expr(cond, cond_pending), body, node.binding_name, nil, node.mark_per_iter, tight)
  end

  # Returns true when the last reachable statement in a loop body is an
  # unconditional exit (break/continue/return), making any trailing code unreachable.
  sig { params(body: T::Array[MIR::Node]).returns(T::Boolean) }
  def loop_body_exits?(body)
    T.bind(self, MIRLowering) rescue nil
    return false unless body.is_a?(Array) && !body.empty?
    body.last.is_a?(MIR::BreakStmt) || body.last.is_a?(MIR::ContinueStmt) || body.last.is_a?(MIR::ReturnStmt)
  end

  sig { params(node: AST::ForEach).returns(MIR::Node) }
  def lower_for_each(node)
    T.bind(self, MIRLowering) rescue nil
    plan = for_each_plan(node)

    loop_stmt = for_each_loop_stmt(node, plan)
    plan.collection_setup.empty? ? loop_stmt : MIR::ScopeBlock.new(plan.collection_setup + [loop_stmt])
  end

  sig { params(node: AST::ForEach).returns(ForEachPlan) }
  def for_each_plan(node)
    T.bind(self, MIRLowering) rescue nil
    var = zig_safe_name(node.var_name)
    body = lower_body(node.body)
    finalize_loop_frame_alloc_scopes!(body, node.mark_per_iter)
    rt = MIR::Ident.new(runtime_binding_name)
    coll = lower(node.collection)
    coll_type = node.collection.full_type!
    ct = coll_type.is_a?(Type) ? coll_type : Type.new(coll_type)
    collection_setup = T.let([], T::Array[MIR::Node])
    if for_each_owned_collection_source?(coll)
      source_name = "__for_src_#{lowering_counters.next_tmp_id}"
      source_alloc = for_each_owned_collection_source_alloc(coll, ct)
      entry = CleanupEntry.build(:uniform, alloc: source_alloc, has_moved_guard: false, zig_type: ct.zig_type)
      collection_setup.concat(MIR::BindingMaterialization.new(
        name: source_name,
        expr: T.cast(coll, MIR::Node),
        alloc: source_alloc,
        type_info: ct,
        mutable: false,
        cleanup_entry: entry
      ).statements)
      coll = MIR::Ident.new(source_name)
    end
    is_mutable = node.is_mutable == true
    mark_per_iter = node.mark_per_iter == true ? true : nil
    tight = node.tight == true

    body = prepend_loop_mark(body, mark_per_iter: mark_per_iter, tight: tight)

    # Yield check at end of body
    if current_function_has_rt? && !loop_body_exits?(body)
      body << MIR::ExprStmt.new(MIR::MethodCall.new(rt, "checkYield", [], false, MIR::CallableContract.no_ownership(0)), false)
    end
    ForEachPlan.new(
      var: var,
      body: body,
      rt: rt,
      collection: coll,
      collection_type: ct,
      collection_setup: collection_setup,
      mutable: is_mutable,
      mark_per_iter: mark_per_iter,
      tight: tight,
    )
  end

  sig { params(node: AST::ForEach, plan: ForEachPlan).returns(MIR::Node) }
  def for_each_loop_stmt(node, plan)
    T.bind(self, MIRLowering) rescue nil
    var = plan.var
    body = plan.body
    coll = plan.collection
    ct = plan.collection_type
    mark_per_iter = plan.mark_per_iter
    tight = plan.tight
    loop_stmt = T.let(nil, T.nilable(MIR::Node))
    if ct.map?
      for_id = lowering_counters.next_for_loop_id
      iter_var = "__kit_#{for_id}"
      key_ptr = "__key_ptr_#{for_id}"
      # { var iter = coll.keyIterator(); while (iter.next()) |var| { body } }
      iter_init = MIR::Let.new(iter_var, MIR::MethodCall.new(coll, "keyIterator", [], false, MIR::CallableContract.no_ownership(0)), true, nil, nil)
      key_bind = MIR::Let.new(var, MIR::Deref.new(MIR::Ident.new(key_ptr)), false, nil, nil)
      while_stmt = MIR::WhileStmt.new(
        MIR::MethodCall.new(MIR::Ident.new(iter_var), "next", [], false, MIR::CallableContract.no_ownership(0)),
        [key_bind] + body, key_ptr, nil, mark_per_iter, tight
      )
      loop_stmt = MIR::ScopeBlock.new([iter_init, while_stmt])
    elsif ct.pool?
      # Pool payload and liveness metadata are separate sidecars. Iterate
      # physical indices, skip vacant entries, then read the direct payload.
      slot_var = "__pslot_idx_#{lowering_counters.next_for_loop_id}"
      slot_ident = MIR::Ident.new(slot_var)
      slots_iter = MIR::IterRange.new(
        MIR::Lit.new("0"),
        MIR::Cast.new(MIR::FieldGet.new(coll, "capacity"), "usize", :intCast),
        :usize)
      skip_dead = MIR::IfStmt.new(
        MIR::UnaryOp.new("!", MIR::MethodCall.new(coll, "isAliveIndex", [slot_ident], false, MIR::CallableContract.no_ownership(1))),
        [MIR::ContinueStmt.new(nil)],
        nil
      )
      value_bind = MIR::Let.new(var,
        MIR::IndexGet.new(MIR::FieldGet.new(coll, "values"), slot_ident),
        false, nil, nil)
      full_body = [skip_dead, value_bind] + body
      loop_stmt = MIR::ForStmt.new(slots_iter, slot_var, full_body, nil, mark_per_iter, tight)
    elsif ct.dynamic_stream? || ct.open_stream?
      # Finite/open stream (~T[] / ~?T[]): next() returns ?T; while-loop with optional capture.
      loop_stmt = MIR::WhileStmt.new(
        MIR::MethodCall.new(coll, "next", [], true, MIR::CallableContract.no_ownership(0)),
        body, var, nil, mark_per_iter, tight)
    elsif ct.bounded_stream?
      # Bounded stream (~T[N]): next() returns T (panics when exhausted).
      # Use nextOrNull() so the while-loop optional-capture pattern works.
      # defer deinit drains any unconsumed promises on early exit.
      defer_deinit = MIR::DeferStmt.new(MIR::MethodCall.new(coll, "deinit", [], false, MIR::CallableContract.no_ownership(0)))
      loop_stmt = MIR::ScopeBlock.new([
        defer_deinit,
        MIR::WhileStmt.new(
          MIR::MethodCall.new(coll, "nextOrNull", [], true, MIR::CallableContract.no_ownership(0)),
          body, var, nil, mark_per_iter, tight)
      ])
    elsif ct.inf_stream?
      # Infinite stream (~T[INF]): nextOrNull() returns ?T, null only when stream is
      # closed.  A LIMIT stage in the body breaks the loop after N items.
      # No extra defer needed: the variable-scope `defer name.deinit()` (emitted by
      # the variable's cleanup entry) signals the generator to stop at function exit.
      loop_stmt = MIR::WhileStmt.new(
        MIR::MethodCall.new(coll, "nextOrNull", [], true, MIR::CallableContract.no_ownership(0)),
        body, var, nil, mark_per_iter, tight)
    elsif ct.soa? && (ct.list_collection? || ct.fixed_soa?)
      idx_var = "__soa_idx_#{lowering_counters.next_for_loop_id}"
      iter_init = MIR::Let.new(idx_var, MIR::Lit.new("0"), true, Type.new("i64"), nil)
      value_bind = MIR::Let.new(
        var,
        MIR::MethodCall.new(coll, "get", [MIR::Cast.new(MIR::Ident.new(idx_var), "usize", :intCast)], false, MIR::CallableContract.no_ownership(1)),
        false,
        nil,
        nil
      )
      cond = MIR::BinOp.new("<", MIR::Ident.new(idx_var), MIR::MethodCall.new(coll, "length", [], false, MIR::CallableContract.no_ownership(0)))
      update = MIR::Set.new(MIR::Ident.new(idx_var), MIR::BinOp.new("+", MIR::Ident.new(idx_var), MIR::Lit.new("1")))
      loop_stmt = MIR::ScopeBlock.new([
        iter_init,
        MIR::WhileStmt.new(cond, [value_bind] + body, nil, update, mark_per_iter, tight)
      ])
    elsif ct.set_collection?
      # Set: iterate via keyIterator(). next() returns ?*T so we deref in the body.
      for_id = lowering_counters.next_for_loop_id
      iter_var  = "__kit_#{for_id}"
      ptr_var   = "__kptr_#{for_id}"
      iter_init = MIR::Let.new(iter_var, MIR::MethodCall.new(coll, "keyIterator", [], false, MIR::CallableContract.no_ownership(0)), true, nil, nil)
      deref     = MIR::Let.new(var, MIR::FieldGet.new(MIR::Ident.new(ptr_var), "*"), false, nil, nil)
      full_body = [deref, MIR::Suppress.new(var)] + body
      while_stmt = MIR::WhileStmt.new(
        MIR::MethodCall.new(MIR::Ident.new(iter_var), "next", [], false, MIR::CallableContract.no_ownership(0)),
        full_body, ptr_var, nil, mark_per_iter, tight
      )
      loop_stmt = MIR::ScopeBlock.new([iter_init, while_stmt])
    else
      is_field_access = node.collection.is_a?(AST::GetField)
      is_param = node.collection.is_a?(AST::Identifier) &&
                 current_function_param_name?(node.collection.name)
      # list_collection? covers T[N]@list (fixed capacity ArrayList) in addition to
      # T[]@list (dynamic). Both map to std.ArrayListUnmanaged and require .items.
      is_arraylist = (ct.list_collection? || (ct.array? && ct.dynamic?)) &&
                     !ct.string? && !is_param && !is_field_access
      iter = if is_arraylist
        MIR::ListItems.new(coll)
      elsif is_param
        # @list params are anytype — could be ArrayList (TAKES) or slice (borrow,
        # via .items at call site). MIR::ItemsAccess(safe: true) emits a comptime
        # @hasField check that resolves to xs.items or xs at compile time, with
        # zero runtime overhead. Defer container shape to the runtime/comptime
        # layer instead of re-deriving from "is this a param?".
        MIR::ItemsAccess.new(coll, true)
      elsif is_field_access && ct.dynamic_field_array?
        coll
      else
        MIR::AddressOf.new(coll)
      end
      # Pointer capture (|*var|) is only needed when iterating structs with mutable field
      # access. For primitive/enum/union element types, value capture (|var|) is correct
      # because primitives are Copy types and can't be meaningfully mutated in-place.
      capture = if plan.mutable
        elem = ct.element_type
        elem_sym = elem&.resolved
        (elem_sym && struct_schemas.key?(elem_sym)) ? "*#{var}" : var
      else
        var
      end
      loop_stmt = MIR::ForStmt.new(iter, capture, body, nil, mark_per_iter, tight)
    end
    loop_stmt
  end

  sig { params(mir: MIR::Node).returns(T::Boolean) }
  def for_each_owned_collection_source?(mir)
    return for_each_owned_collection_source?(mir.expr) if mir.is_a?(MIR::Cast) || mir.is_a?(MIR::TryExpr)
    return true if mir.is_a?(MIR::Call) && mir.owned_return?
    T.unsafe(self).__send__(:mir_allocates?, mir)
  end

  sig { params(mir: MIR::Node, type_info: Type).returns(Symbol) }
  def for_each_owned_collection_source_alloc(mir, type_info)
    T.bind(self, MIRLowering) rescue nil
    return for_each_owned_collection_source_alloc(mir.expr, type_info) if mir.is_a?(MIR::Cast) || mir.is_a?(MIR::TryExpr)
    return :heap if mir.is_a?(MIR::Call) && mir.owned_return?
    owned_alloc = mir_owned_alloc(mir)
    return owned_alloc if owned_alloc

    type_info.cleanup_allocator(T.unsafe(mir_schema_lookup))
  end

  sig { params(node: AST::ForRange).returns(MIR::ScopeBlock) }
  def lower_for_range(node)
    T.bind(self, MIRLowering) rescue nil
    plan = for_range_plan(node)

    var_decl = MIR::Let.new(plan.var, MIR::Ident.new(plan.iter_var), false, Type.new("i64"), "_ = &#{plan.var};")
    body = prepend_loop_mark(plan.body, mark_per_iter: plan.mark_per_iter, tight: plan.tight, after_mark: [var_decl])
    if !plan.tight && current_function_has_rt? && !loop_body_exits?(body)
      body << MIR::ExprStmt.new(MIR::MethodCall.new(plan.rt, "checkYield", [], false, MIR::CallableContract.no_ownership(0)), false)
    end

    update = MIR::Set.new(MIR::Ident.new(plan.iter_var), MIR::BinOp.new("+", MIR::Ident.new(plan.iter_var), MIR::Lit.new("1")))
    cond = MIR::BinOp.new(plan.comparison, MIR::Ident.new(plan.iter_var), plan.end_value)
    iter_init = MIR::Let.new(plan.iter_var, plan.start_value, true, Type.new("i64"), nil)
    while_stmt = MIR::WhileStmt.new(cond, body, nil, update, plan.mark_per_iter, plan.tight)
    MIR::ScopeBlock.new([iter_init, while_stmt])
  end

  sig { params(node: AST::ForRange).returns(ForRangePlan) }
  def for_range_plan(node)
    T.bind(self, MIRLowering) rescue nil
    start_val = lower(node.start_expr)
    end_val = lower(node.end_expr)
    var = zig_safe_name(node.var_name)
    body = lower_body(node.body)
    finalize_loop_frame_alloc_scopes!(body, node.mark_per_iter)
    rt = MIR::Ident.new(runtime_binding_name)
    cmp = node.inclusive ? "<=" : "<"
    iter_var = "__for_#{lowering_counters.next_for_loop_id}"
    ForRangePlan.new(
      var: var,
      start_value: start_val,
      end_value: end_val,
      body: body,
      rt: rt,
      comparison: cmp,
      iter_var: iter_var,
      mark_per_iter: node.mark_per_iter == true ? true : nil,
      tight: node.tight == true,
    )
  end

  sig { params(node: AST::MatchStatement).returns(MIR::Node) }
  def lower_match(node)
    T.bind(self, MIRLowering) rescue nil
    facts = match_lowering_facts(node)
    expr_label = facts.expr_label
    subject = facts.subject
    is_union = facts.is_union

    if facts.is_int_match || facts.is_enum_match
      result = lower_switch_match(node, facts)
    elsif is_union && union_match_switchable?(node)
      result = lower_union_match(node, facts)
    else
      result = lower_if_chain_match(node, facts)
    end

    expr_label ? MIR::BlockExpr.new(expr_label, [result]) : result
  end

  sig { params(node: AST::MatchStatement, facts: MatchLoweringFacts).returns(MIR::IfChain) }
  def lower_if_chain_match(node, facts)
    branches = node.cases.flat_map { |match_case| if_chain_match_case_branches(node, match_case, facts) }
    MIR::IfChain.new(branches, lower_match_default_body(node.default_case, facts.expr_label))
  end

  sig { params(node: AST::MatchStatement, match_case: AST::MatchCase, facts: MatchLoweringFacts).returns(T::Array[MIR::IfChainBranch]) }
  def if_chain_match_case_branches(node, match_case, facts)
    T.bind(self, MIRLowering) rescue nil
    body = hoisted_match_case_body(match_case, facts.expr_label)
    return [if_chain_branch(T.cast(lower(match_case.value), MIR::Emittable), body)] if match_case.kind == :when
    return union_if_chain_match_case(node, match_case, facts.subject, body) if facts.is_union

    value_if_chain_match_case(node, match_case, facts.subject, body)
  end

  sig { params(match_case: AST::MatchCase, expr_label: T.nilable(String)).returns(MatchBody) }
  def hoisted_match_case_body(match_case, expr_label)
    body = lower_match_branch(match_case.body, expr_label)
    hoist_unhoisted_return_allocs(body, match_case.body)
  end

  sig { params(cond: MIR::Emittable, body: MatchBody).returns(MIR::IfChainBranch) }
  def if_chain_branch(cond, body)
    MIR::IfChainBranch.new(cond: cond, body: body)
  end

  sig { params(node: AST::MatchStatement, match_case: AST::MatchCase, subject: MIR::Emittable, body: MatchBody).returns(T::Array[MIR::IfChainBranch]) }
  def union_if_chain_match_case(node, match_case, subject, body)
    variants = union_match_case_variants(match_case)
    is_mutable = node.expr.is_a?(AST::Identifier) && node.expr.was_moved == true
    has_payload_binding = !!(match_case.binding || match_case.destructure)

    if has_payload_binding && variants.length > 1
      return variants.map do |variant|
        if_chain_branch(
          union_tag_condition(subject, variant),
          union_if_chain_payload_bindings(match_case, subject, variant, is_mutable) + body.dup,
        )
      end
    end

    branch_body = has_payload_binding ? union_if_chain_payload_bindings(match_case, subject, variants.first || "", is_mutable) + body : body
    [if_chain_branch(disjoin_match_conditions(variants.map { |variant| union_tag_condition(subject, variant) }), branch_body)]
  end

  sig { params(match_case: AST::MatchCase, subject: MIR::Emittable, variant: String, is_mutable: T::Boolean).returns(MatchBody) }
  def union_if_chain_payload_bindings(match_case, subject, variant, is_mutable)
    payload = T.let(MIR::UnionPayloadGet.new(subject, variant.to_s), MIR::Emittable)
    payload = MIR::Deref.new(payload) if match_case.indirect_payload_as
    if match_case.binding
      return [MIR::Let.new(T.must(match_case.binding), payload, is_mutable, nil, "_ = &#{match_case.binding};")]
    end

    destructure = match_case.destructure
    return [] unless destructure

    destructure.fields.filter_map do |field|
      next if field.wildcard?
      next unless field.bind?

      MIR::Let.new(field.name.to_s, MIR::FieldGet.new(payload, field.name.to_s), false, nil, "_ = &#{field.name};")
    end
  end

  sig { params(subject: MIR::Emittable, variant: String).returns(MIR::BinOp) }
  def union_tag_condition(subject, variant)
    T.bind(self, MIRLowering) rescue nil
    MIR::BinOp.new("==", active_tag_call(subject), MIR::EnumTag.new(variant: variant))
  end

  sig { params(node: AST::MatchStatement, match_case: AST::MatchCase, subject: MIR::Emittable, body: MatchBody).returns(T::Array[MIR::IfChainBranch]) }
  def value_if_chain_match_case(node, match_case, subject, body)
    T.bind(self, MIRLowering) rescue nil
    if node.string_match
      return [if_chain_branch(string_match_condition(subject, match_case), body)]
    end
    if match_case.kind == :struct_pattern
      pattern = T.cast(match_case.value, AST::StructPattern)
      subject_ident = T.cast(subject, MIR::Ident)
      cond_parts, bind_stmts = lower_struct_pattern(subject_ident, pattern)
      branch_body = bind_stmts + body
      return [if_chain_branch(conjoin_match_conditions(cond_parts), branch_body)]
    end

    [if_chain_branch(equality_match_condition(subject, match_case), body)]
  end

  sig { params(subject: MIR::Emittable, match_case: AST::MatchCase).returns(MIR::Emittable) }
  def string_match_condition(subject, match_case)
    T.bind(self, MIRLowering) rescue nil
    conditions = [match_case.value, *match_case.extra_values].map do |value|
      emit_builtin(:strEql, [subject, lower(value)])
    end
    disjoin_match_conditions(conditions)
  end

  sig { params(subject: MIR::Emittable, match_case: AST::MatchCase).returns(MIR::Emittable) }
  def equality_match_condition(subject, match_case)
    T.bind(self, MIRLowering) rescue nil
    conditions = [match_case.value, *match_case.extra_values].map do |value|
      MIR::BinOp.new("==", subject, lower(value))
    end
    disjoin_match_conditions(conditions)
  end

  sig { params(conditions: T::Array[MIR::Emittable]).returns(MIR::Emittable) }
  def disjoin_match_conditions(conditions)
    conditions.reduce { |acc, condition| MIR::BinOp.new("or", acc, condition) } || MIR::Lit.new("false")
  end

  sig { params(conditions: T::Array[MIR::Emittable]).returns(MIR::Emittable) }
  def conjoin_match_conditions(conditions)
    conditions.reduce { |acc, condition| MIR::BinOp.new("and", acc, condition) } || MIR::Lit.new("true")
  end

  sig { params(default_case: T.nilable(MatchDefaultBody), expr_label: T.nilable(String)).returns(T.nilable(MatchBody)) }
  def lower_match_default_body(default_case, expr_label)
    return nil unless default_case && !default_case.empty?

    body = lower_match_branch(default_case, expr_label)
    hoist_unhoisted_return_allocs(body, default_case)
  end

  sig { params(node: AST::MatchStatement).returns(T::Boolean) }
  def union_match_switchable?(node)
    node.cases.all? { |c| c.kind == :eq }
  end

  sig { params(node: AST::MatchStatement).returns(MatchLoweringFacts) }
  def match_lowering_facts(node)
    T.bind(self, MIRLowering) rescue nil
    expr_label = if node.expr_mode
      "__match_#{lowering_counters.next_block_expr_id}"
    end
    subject = lower(node.expr)
    union_lookup = begin
      t = Type.new(node.expr.resolved_type || :Any)
      t.generic_instance? ? t.generic_base : t.resolved
    end
    is_union = union_schemas.key?(union_lookup)
    expr_type = node.expr.resolved_type
    expr_type_sym = expr_type.is_a?(Type) ? expr_type.resolved : expr_type
    is_int_match = !!(!is_union && !node.string_match &&
      (expr_type == :Int64 || expr_type == :Int32 || expr_type == :Int16 || expr_type == :Int8 ||
       (expr_type.is_a?(Type) && expr_type.integer?)) &&
      node.cases.all? { |c| c.kind != :when && c.kind != :struct_pattern &&
                            [c.value, *(c.extra_values || [])].all? { |p|
                              p.is_a?(AST::Literal) && (p.type == :INT64 || p.type == :NUMBER)
                            } })
    is_enum_match = !!(!is_union && !node.string_match && expr_type_sym && enum_schemas.key?(expr_type_sym) &&
      node.cases.all? { |c| c.kind != :when && c.kind != :struct_pattern &&
                            [c.value, *(c.extra_values || [])].all? { |p| p.is_a?(AST::GetField) } })
    MatchLoweringFacts.new(
      expr_label: expr_label,
      subject: subject,
      is_union: is_union,
      is_int_match: is_int_match,
      is_enum_match: is_enum_match,
      expr_type_sym: T.cast(is_union ? union_lookup : expr_type_sym, Symbol)
    )
  end

  sig { params(stmts: T::Array[AST::Node], expr_label: T.nilable(String)).returns(MatchBody) }
  def lower_match_branch(stmts, expr_label)
    T.bind(self, MIRLowering) rescue nil
    expr_label ? lower_body_with_break(stmts, expr_label) : lower_body(stmts)
  end

  sig { params(node: AST::MatchStatement, facts: MatchLoweringFacts).returns(MIR::UnionMatchStmt) }
  def lower_union_match(node, facts)
    arms = node.cases.flat_map { |c| union_match_arm_plans(c, node, facts.expr_label) }
    default = union_match_default_body(node, facts, arms)
    default = hoist_unhoisted_return_allocs(default, node.default_case || []) if default
    MIR::UnionMatchStmt.new(facts.subject, arms.map { |arm|
      MIR::UnionMatchArm.new(variant: arm.variant, payload: arm.payload_name, body: arm.body)
    }, default)
  end

  sig { params(node: AST::MatchStatement, facts: MatchLoweringFacts, arms: T::Array[UnionMatchArmPlan]).returns(T.nilable(MatchBody)) }
  def union_match_default_body(node, facts, arms)
    T.bind(self, MIRLowering) rescue nil
    schema = union_schemas[facts.expr_type_sym]
    all_variants = schema&.variants&.keys&.map(&:to_s)&.sort || []
    covered = arms.map(&:variant).map(&:to_s).sort
    return nil if covered == all_variants
    return lower_match_branch(node.default_case, facts.expr_label) if node.default_case && !node.default_case.empty?

    []
  end

  sig { params(c: AST::MatchCase, node: AST::MatchStatement, expr_label: T.nilable(String)).returns(T::Array[UnionMatchArmPlan]) }
  def union_match_arm_plans(c, node, expr_label)
    T.bind(self, MIRLowering) rescue nil
    variants = union_match_case_variants(c)
    body = lower_match_branch(c.body, expr_label)
    body = hoist_unhoisted_return_allocs(body, c.body)
    return variants.map { |variant| UnionMatchArmPlan.new(variant: variant, body: body, payload_name: nil) } unless c.binding || c.destructure

    variants.map do |variant|
      payload_name = "__match_payload_#{lowering_counters.next_tmp_id}"
      arm_body = union_match_payload_bindings(c, payload_name, node) + body.dup
      UnionMatchArmPlan.new(variant: variant, body: arm_body, payload_name: payload_name)
    end
  end

  sig { params(c: AST::MatchCase).returns(T::Array[String]) }
  def union_match_case_variants(c)
    T.bind(self, MIRLowering) rescue nil
    [c.value, *(c.extra_values || [])].filter_map do |value|
      union_match_variant_name(value)
    end
  end

  sig { params(value: AST::Node).returns(String) }
  def union_match_variant_name(value)
    case value
    when AST::GetField
      value.field.to_s
    when AST::MethodCall, AST::Identifier
      value.name.to_s
    else
      Kernel.raise "union MATCH variant must be a named variant, got #{value.class}"
    end
  end

  sig { params(c: AST::MatchCase, payload_name: String, node: AST::MatchStatement).returns(MatchBody) }
  def union_match_payload_bindings(c, payload_name, node)
    is_mutable = node.expr.is_a?(AST::Identifier) && node.expr.was_moved == true
    payload = MIR::Ident.new(payload_name)
    payload = MIR::Deref.new(payload) if c.indirect_payload_as
    if c.binding
      binding = T.must(c.binding)
      return [MIR::Let.new(binding, payload, is_mutable, nil, "_ = &#{binding};")]
    end

    destructure = c.destructure
    return [] unless destructure

    destructure.fields.filter_map do |f|
      next if f.wildcard?
      next unless f.bind?
      MIR::Let.new(f.name.to_s, MIR::FieldGet.new(payload, f.name.to_s), false, nil, "_ = &#{f.name};")
    end
  end

  sig { params(node: AST::MatchStatement, facts: MatchLoweringFacts).returns(MIR::SwitchStmt) }
  def lower_switch_match(node, facts)
    T.bind(self, MIRLowering) rescue nil
    arms = node.cases.map { |c|
      body = lower_match_branch(c.body, facts.expr_label)
      patterns = T.let([switch_match_pattern(c.value, facts.is_enum_match)], T::Array[MIR::SwitchPattern])
      (c.extra_values || []).each do |ev|
        patterns << switch_match_pattern(ev, facts.is_enum_match)
      end
      MIR::SwitchArm.new(patterns: patterns, body: body)
    }
    default = (node.default_case && !node.default_case.empty?) ? lower_match_branch(node.default_case, facts.expr_label) : nil
    # Int switches always need else => {} in Zig (Zig 0.16 requires exhaustive switch)
    default ||= [] if facts.is_int_match
    # Non-exhaustive enum match without DEFAULT needs else => {} to satisfy Zig.
    # Exhaustive enum switches cannot include an `else` prong in Zig 0.16, even
    # when the source used PARTIAL MATCH with an unreachable DEFAULT.
    if facts.is_enum_match
      all_variants = enum_schemas[facts.expr_type_sym]&.map(&:to_s)&.sort || []
      covered = node.cases.flat_map { |c|
        [c.value.field.to_s, *((c.extra_values || []).map { |ev| ev.field.to_s })]
      }.sort
      exhaustive = covered == all_variants
      default = nil if default && exhaustive
      default = [] if !default && !exhaustive
    end
    MIR::SwitchStmt.new(facts.subject, arms, default)
  end

  sig { params(value: AST::Node, is_enum_match: T::Boolean).returns(MIR::SwitchPattern) }
  def switch_match_pattern(value, is_enum_match)
    T.bind(self, MIRLowering) rescue nil
    return MIR::EnumSwitchPattern.new(variant: T.cast(value, AST::GetField).field.to_s) if is_enum_match

    lower(value)
  end

  sig { params(body: T::Array[MIR::Emittable], ast_stmts: T::Array[AST::Node]).returns(T::Array[MIR::Emittable]) }
  def hoist_unhoisted_return_allocs(body, ast_stmts)
    T.bind(self, MIRLowering) rescue nil
    returns = T.let([], T::Array[AST::Node])
    ast_stmts.each { |s| returns << s.value if s.is_a?(AST::ReturnNode) && s.value }
    ret_i = T.let(0, Integer)

    body.flat_map do |stmt|
      unless stmt.is_a?(MIR::ReturnStmt) && stmt.value && mir_allocates?(stmt.value)
        ret_i += 1 if stmt.is_a?(MIR::ReturnStmt)
        next [stmt]
      end

      ast_value = returns[ret_i]
      ret_i += 1
      name = "__tmp_#{lowering_counters.next_tmp_id}"
      entry = hoist_cleanup_entry(stmt.value, ast_value)
      materialized = MIR::BindingMaterialization.new(
        name: name,
        expr: T.cast(stmt.value, MIR::Node),
        alloc: :heap,
        type_info: mir_alloc_mark_type_info(stmt.value, ast_value, context: "unhoisted return allocation"),
        mutable: false,
        cleanup_entry: entry,
        cleanup_mode: entry ? :err : :normal,
        scope: :heap
      )
      out = T.let(materialized.statements, T::Array[MIR::Stmt])
      if entry
        plan = synthetic_return_ownership_plan(name)
        out.concat(plan.transfer_marks_for(Set[name], function_state.lowered_guarded_cleanup_names))
      end
      out << MIR::ReturnStmt.new(MIR::Ident.new(name))
      out
    end
  end

  sig { params(node: AST::ReturnNode).returns(MIR::NodeRoot) }
  def lower_return(node)
    T.bind(self, MIRLowering) rescue nil
    plan = return_lowering_plan(node)
    value = finalize_return_value(node, plan.value)

    # Tail call optimization: convert self-recursive return to @call(.always_tail, ...)
    # Disabled in debug mode (stage2 Zig backend doesn't support always_tail reliably)
    if value.is_a?(MIR::Call) && tail_call_return?(value)
      return MIR::ReturnStmt.new(MIR::TailCall.new(value.callee, value.args, value.callable_contract))
    end

    # Rc/Arc return of a local cleanup binding transfers that binding's
    # existing strong ref. Borrowed/non-local identifiers still retain.
    if node.value && rc_retain_needed?(node.value) && !return_transfers_heap_binding?(node.value)
      retained = hoist_alloc(make_rc_retain(node.value), node.value, err_cleanup: true)
      return return_with_transfer_marks(plan, retained, MIR::ReturnStmt.new(retained))
    else
      # Hoist allocating expressions to a named Let so the checker sees the
      # allocation in the only verifier-visible ownership position.
      # ErrCleanup: the caller takes ownership on success.
      value = hoist_alloc(value, node.value, err_cleanup: true, transfer_on_success: false) if value && !value.is_a?(MIR::Ident)
      return return_with_transfer_marks(plan, value, MIR::ReturnStmt.new(value))
    end
  end

  sig { params(node: AST::ReturnNode, value: T.nilable(MIR::Node)).returns(T.nilable(MIR::Node)) }
  def finalize_return_value(node, value)
    value = return_payload_pointer_value(node, value)
    value = heap_carry_return_value(node, value)
    heap_carry_recursive_param_value(node, value)
  end

  sig { params(node: AST::ReturnNode, value: T.nilable(MIR::Node)).returns(T.nilable(MIR::Node)) }
  def return_payload_pointer_value(node, value)
    T.bind(self, MIRLowering) rescue nil
    payload_zig = current_function_return_payload_zig
    return value unless payload_zig&.start_with?("*")
    return value unless value
    return value if value.is_a?(MIR::HeapCreate) || value.is_a?(MIR::Call)
    return value if return_value_already_payload_pointer?(node.value)

	    bare_ret = payload_zig.delete_prefix("*")
    with_ownership_consumption(
      MIR::HeapCreate.new(bare_ret, value, :heap, "ret"),
      mir_ident_names(value),
      "MIR::HeapCreate",
      target_alloc: :heap,
    )
  end

  sig { params(node: AST::ReturnNode, value: T.nilable(MIR::Node)).returns(T.nilable(MIR::Node)) }
  def heap_carry_return_value(node, value)
    T.bind(self, MIRLowering) rescue nil
    return value unless current_function_heap_carry_return? && node.value && value
    return value if value.is_a?(MIR::Ident)
    return value if return_transfers_heap_binding?(node.value)
    return value if mir_allocates?(value) || (value.is_a?(MIR::Call) && value.owned_return?)

    ret_type = Type.from_node!(node.value, context: "heap carry return placement")
    ret_type = ret_type.success_type || ret_type
    escaping_value_alloc(ret_type) == :heap ? place_value_for_destination(value, node.value, :heap, ret_type) : value
  end

  sig { params(node: AST::ReturnNode, value: T.nilable(MIR::Node)).returns(T.nilable(MIR::Node)) }
  def heap_carry_recursive_param_value(node, value)
    T.bind(self, MIRLowering) rescue nil
    return value unless current_function_heap_carry_return? && node.value && value.is_a?(MIR::Ident)
    return value unless current_function_param_name?(value.name)
    return value if current_function_takes_param_name?(value.name)

    ret_type = Type.from_node!(node.value, context: "heap carry recursive return")
    ret_type = ret_type.success_type || ret_type
    ret_type.recursive_cleanup_shape?(T.unsafe(mir_schema_lookup)) ? MIR::DeepCopy.new(value, ret_type.zig_type, nil, :full_value, :heap) : value
  end

  sig { params(value: T.nilable(MIR::Node)).returns(T::Boolean) }
  def tail_call_return?(value)
    T.bind(self, MIRLowering) rescue nil
    !!(current_function_tail_call? && !program_state.debug_mode && value.is_a?(MIR::Call) && value.callee == current_function_zig_name)
  end

  sig { params(plan: ReturnOwnershipPlan, value: T.nilable(MIR::Node), ret: MIR::ReturnStmt).returns(MIR::NodeRoot) }
  def return_with_transfer_marks(plan, value, ret)
    T.bind(self, MIRLowering) rescue nil
    names = plan.returned_names
    if value.is_a?(MIR::Ident)
      names = names.include?(value.name.to_s) ? names.dup : Set[value.name.to_s]
    elsif value
      value_names = mir_ident_names(value).to_set
      names = value_names unless value_names.empty?
    end
    marks = plan.transfer_marks_for(names, function_state.lowered_guarded_cleanup_names)
    if value.is_a?(MIR::Ident) && marks.empty? && returned_hoist_binding?(value.name.to_s)
      marks = MIR::OwnershipTransferPlan.new(
        name: value.name.to_s,
        target: :return,
        target_alloc: nil,
        move_guarded: lowered_guarded_cleanup_name?(value.name.to_s),
      ).marks
    end
    marks.empty? ? ret : marks + [ret]
  end

  sig { params(name: String).returns(ReturnOwnershipPlan) }
  def synthetic_return_ownership_plan(name)
    names = T.let(Set[name], T::Set[String])
    ReturnOwnershipPlan.new(
      value: MIR::Ident.new(name),
      explicit_return_names: Set.new,
      moved_root_names: Set.new,
      consumed_root_names: Set.new,
	      direct_value_names: names,
	      converted_cleanup_names: Set.new,
	      transfer_required_names: names,
	      move_guard_required_names: names,
	    )
	  end

  sig { params(node: AST::ReturnNode).returns(ReturnOwnershipPlan) }
  def return_lowering_plan(node)
    T.bind(self, MIRLowering) rescue nil
    ret_alloc = return_destination_alloc(node)
    value = node.value ? with_decl_alloc(ret_alloc) do
      destination_type = return_value_destination_type(node)
      lowered = with_expected_type(destination_type) { lower(node.value) }
      place_value_for_destination(lowered, node.value, ret_alloc, destination_type)
    end : nil

    explicit_return_names = T.let(
      node.value && !aggregate_return_literal?(node.value) ? returned_binding_names(node.value) : Set.new,
      T::Set[String],
    )
    moved_root_names = T.let(Set.new, T::Set[String])
    consumed_root_names = T.let(Set.new, T::Set[String])
    direct_value_names = T.let(Set.new, T::Set[String])
    if value.is_a?(MIR::Ident)
      direct_value_names << value.name
    end
    returned_names = T.let(Set.new, T::Set[String])
    [explicit_return_names, moved_root_names, consumed_root_names, direct_value_names].each do |set|
      set.each { |name| returned_names << name }
	    end
	    transfer_required_names = return_transfer_required_names(returned_names)
	    move_guard_required_names = return_move_guard_required_names(returned_names)
	    ReturnOwnershipPlan.new(
	      value: value,
	      explicit_return_names: explicit_return_names,
	      moved_root_names: moved_root_names,
	      consumed_root_names: consumed_root_names,
	      direct_value_names: direct_value_names,
	      converted_cleanup_names: Set.new,
	      transfer_required_names: transfer_required_names,
	      move_guard_required_names: move_guard_required_names,
	    )
	  end

  # ================================================================
  # Helpers
  # ================================================================

  sig { params(expr: AST::Node).returns(T::Boolean) }
  def aggregate_return_literal?(expr)
    node = T.let(expr, AST::Node)
    node = node.value while node.is_a?(AST::Cast)
    node.is_a?(AST::StructLit) || node.is_a?(AST::UnionVariantLit) || node.is_a?(AST::ListLit)
  end

  sig { params(ast_node: AST::Node).returns(T::Boolean) }
  def return_transfers_heap_binding?(ast_node)
    T.bind(self, MIRLowering) rescue nil
    node = T.let(ast_node, AST::Node)
    node = node.value while node.is_a?(AST::Cast) || node.is_a?(AST::MoveNode)
    return false if node.is_a?(AST::GetField) || node.is_a?(AST::GetIndex)

    root = AST.root_identifier(node) rescue nil
    entry = root ? function_state.bindings[root.name] : nil
    return entry.needs_cleanup? && entry.heap? if entry&.present?

    !!(root && current_function_takes_param_name?(root.name.to_s) && root.symbol&.heap_storage?)
  end

  sig { params(node: AST::ReturnNode).returns(T.nilable(Type)) }
  def return_destination_type(node)
    T.bind(self, MIRLowering) rescue nil
    ti = current_function_return_type
    ti&.success_type
  end

  sig { params(node: AST::ReturnNode).returns(T.nilable(Type)) }
  def return_value_destination_type(node)
    declared = return_destination_type(node)
    return declared unless node.value

    value_type = Type.from_node!(node.value, context: "return destination value")
    return value_type if value_type.collection?

    declared
  end

  sig { params(ast_node: T.nilable(AST::Node)).returns(T::Boolean) }
  def return_value_already_payload_pointer?(ast_node)
    T.bind(self, MIRLowering) rescue nil
    payload_zig = current_function_return_payload_zig
    return false unless ast_node && payload_zig
    ti = Type.from_node!(ast_node, context: "return payload pointer")
    ti.zig_type == payload_zig
  rescue StandardError
    false
  end

  sig { params(expr: AST::Node).returns(T::Set[String]) }
  def returned_binding_names(expr)
    T.bind(self, MIRLowering) rescue nil
    names = T.let(Set.new, T::Set[String])
    collect_returned_binding_names(expr, names)
    names
  end

  sig { params(names: T::Set[String]).returns(T::Set[String]) }
	  def return_transfer_required_names(names)
	    out = T.let(Set.new, T::Set[String])
	    names.each do |name|
	      if return_transfer_required?(name)
	        out << name
      end
	    end
	    out
	  end

	  sig { params(names: T::Set[String]).returns(T::Set[String]) }
	  def return_move_guard_required_names(names)
	    out = T.let(Set.new, T::Set[String])
	    names.each do |name|
	      out << name if return_move_guard_required?(name)
	    end
	    out
	  end

  sig { params(name: String).returns(T::Boolean) }
	  def return_transfer_required?(name)
	    T.bind(self, MIRLowering) rescue nil
	    pipeline_guarded_cleanup_name?(name) || returned_hoist_binding?(name) ||
	      returned_takes_param?(name) || returned_owned_binding?(name)
	  end

	  sig { params(name: String).returns(T::Boolean) }
	  def return_move_guard_required?(name)
	    T.bind(self, MIRLowering) rescue nil
	    return true if pipeline_guarded_cleanup_name?(name)
	    return true if lowered_guarded_cleanup_name?(name)

	    entry = function_state.bindings[name]
	    !!(entry&.needs_cleanup?)
	  end

  sig { params(name: String).returns(T::Boolean) }
  def returned_takes_param?(name)
    T.bind(self, MIRLowering) rescue nil
    entry = function_state.bindings[name]
    return false unless entry && entry[:source_kind] == :takes_param

    ti = function_state.binding_types[name]
    !ti || ownership_tracked_transfer_type?(ti)
  end

  sig { params(name: String).returns(T::Boolean) }
  def returned_hoist_binding?(name)
    T.bind(self, MIRLowering) rescue nil
    return false unless name.start_with?("__hoist_")
    # Fallible borrowed results are also hoisted, but have no allocation to
    # transfer. Generic owned values can have an AllocMark without a concrete
    # destructor, so use the structural allocation fact rather than cleanup
    # presence to distinguish the two.
    function_state.lowered_alloc_names.include?(name)
  end

  sig { params(name: String).returns(T::Boolean) }
  def returned_owned_binding?(name)
    T.bind(self, MIRLowering) rescue nil
    entry = function_state.bindings[name]
    return false if entry && !entry.needs_cleanup?

    ti = function_state.binding_types[name]
    return false if ti && !ownership_tracked_transfer_type?(ti)

    return true if owned_binding_visible?(name)

    !!(entry&.needs_cleanup?)
  end

  sig { params(name: String).returns(T::Boolean) }
  def returned_no_cleanup_binding?(name)
    T.bind(self, MIRLowering) rescue nil
    entry = function_state.bindings[name]
    !!(entry && entry.present? && !entry.needs_cleanup?)
  end

  sig { params(body: AST::RawBody).returns(T::Set[String]) }
  def collect_fn_returned_names(body)
    T.bind(self, MIRLowering) rescue nil
    names = T.let(Set.new, T::Set[String])
    AST.walk_body(body) do |node|
      collect_returned_binding_names(node.value, names) if node.is_a?(AST::ReturnNode)
    end
    names
  end

  sig { params(expr: T.nilable(AST::Node), names: T::Set[String]).void }
  def collect_returned_binding_names(expr, names)
    T.bind(self, MIRLowering) rescue nil
    return unless expr
    case expr
    when AST::Identifier
      decl = expr.symbol&.reg
      name = (decl && function_state.decl_zig_names[decl.object_id]) || zig_safe_name(expr.name)
      names << name if name
    when AST::Cast, AST::MoveNode, AST::ShareNode
      collect_returned_binding_names(expr.value, names)
    when AST::CopyNode, AST::CloneNode, AST::FreezeNode
      return
    when AST::StructLit, AST::UnionVariantLit
      expr.fields.each_value { |v| collect_returned_binding_names(v, names) }
    when AST::ListLit
      expr.items.each { |v| collect_returned_binding_names(v, names) }
    when AST::BinaryOp
      if expr.op == :OR_ELSE
        collect_returned_binding_names(expr.left, names)
        collect_returned_binding_names(expr.right, names)
      end
    end
    nil
  end

  # Returns true if a MIR::Call node returns a non-Copy union type that needs
  # a cleanup defer when used as a temporary in a non-TAKES argument position.
  # heap_storage? misses these: unions like Value are stack-sized but own heap
  # memory (via @indirect fields). When returned inline as a non-TAKES argument,
  # they must be hoisted to a named let with a defer.
  sig { params(expr: MIR::Node, ast_node: AST::Node).returns(T::Boolean) }
  def call_union_return_needs_hoist?(expr, ast_node)
    T.bind(self, MIRLowering) rescue nil
    return false unless expr.is_a?(MIR::Call)
    return false unless ast_node.is_a?(AST::Locatable)
    ti = ast_node.full_type!(context: "union return hoist")
    ti = ti.success_type || ti
    is_heap = (ast_node.is_a?(AST::Locatable) && ast_node.heap_storage?) || ti.heap?
    return false if is_heap  # already handled by mir_allocates?
    !!(union_schemas.key?(ti.resolved) && ownership_bearing_type?(ti))
  end

  # Detect call-site auto-borrow for universal polymorphism. Plain T args
  # need `&arg`; wrapped/sync args are already pointer-like or unwrapped by
  # the polymorphic helper.
  sig { params(arg_node: AST::Node, callee_sig: T.nilable(FunctionSignature), idx: Integer).returns(T::Boolean) }
  def universal_poly_arg_needs_addr?(arg_node, callee_sig, idx)
    T.bind(self, MIRLowering) rescue nil
    return false unless callee_sig.is_a?(FunctionSignature)
    return false unless callee_sig.requires
    param = callee_sig.params[idx]
    return false unless param
    pname = param.name.to_s
    fams = callee_sig.requires[pname]
    # Universal poly: REQUIRES key present AND the family-set is empty.
    return false unless fams && fams.empty?
    # The arg must be a plain (no-sync, no-Arc, no-pointer) struct
    # binding so & flips it into *T territory. Identifier lookup gives
    # us the SymbolEntry; bail if anything's missing.
    return false unless arg_node.is_a?(AST::Identifier)
    sym = arg_node.symbol
    return false unless sym
    # Skip if the binding is already pointer-shaped or sync-wrapped --
    # the helper handles those via comptime dispatch.
    return false if sym.with_match_capability_family?
    # Only auto-borrow MUTABLE plain T: an immutable plain T can't be
    # mutated through any path so & buys us nothing (and would be a
    # pessimization).
    return false unless sym.respond_to?(:mutable) && sym.mutable
    true
  end

  sig { params(name: String).returns(T::Boolean) }
  def callee_needs_rt?(name)
    T.bind(self, MIRLowering) rescue nil
    return true if false || name.to_s.empty?
    sig = fn_sig_for(name)
    return true unless sig
    return sig.needs_rt == true || sig.emits_allocating? if sig.intrinsic
    unless sig.needs_rt == true || sig.needs_rt == false
      raise "callee #{name} missing finalized needs_rt metadata before MIR lowering"
    end
    T.must(sig.needs_rt)
  end

  # Lower a StructPattern into (conditions, binding_stmts).
  # conditions: Array of Zig boolean fragments ("subject.x == 10")
  # binding_stmts: Array of MIR nodes (const decls for :bind fields)

  private :finalize_return_value,
    :return_transfer_required?
  private :aggregate_return_literal?
  private :collect_returned_binding_names
  private :conjoin_match_conditions
  private :equality_match_condition
  private :finalize_loop_frame_alloc_scopes!
  private :for_each_loop_stmt
  private :for_each_owned_collection_source?
  private :for_each_owned_collection_source_alloc
  private :for_each_plan
  private :for_range_plan
  private :heap_carry_recursive_param_value
  private :heap_carry_return_value
  private :hoist_unhoisted_return_allocs
  private :hoisted_match_case_body
  private :if_chain_match_case_branches
  private :loop_body_exits?
  private :lower_control_condition
  private :lower_if_chain_match
  private :lower_match_branch
  private :lower_match_default_body
  private :lower_switch_match
  private :lower_union_match
  private :match_lowering_facts
  private :prepend_loop_mark
  private :return_destination_type
  private :return_lowering_plan
  private :return_move_guard_required?
  private :return_move_guard_required_names
  private :return_payload_pointer_value
  private :return_transfer_required_names
  private :return_transfers_heap_binding?
  private :return_value_already_payload_pointer?
  private :return_value_destination_type
  private :return_with_transfer_marks
  private :returned_binding_names
  private :returned_hoist_binding?
  private :returned_owned_binding?
  private :returned_takes_param?
  private :stamp_loop_frame_alloc_scopes!
  private :string_match_condition
  private :switch_match_pattern
  private :synthetic_return_ownership_plan
  private :tail_call_return?
  private :union_if_chain_match_case
  private :union_if_chain_payload_bindings
  private :union_match_arm_plans
  private :union_match_default_body
  private :union_match_payload_bindings
  private :union_match_switchable?
  private :union_match_variant_name
  private :union_tag_condition
  private :value_if_chain_match_case
  private :with_if_bind_alias_maps

end
