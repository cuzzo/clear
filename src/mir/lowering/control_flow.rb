# typed: strict
require "sorbet-runtime"

module MIRLoweringControlFlow
    extend T::Sig
    extend T::Helpers

  requires_ancestor { MIRLowering }

  class MatchLoweringFacts < T::Struct
    const :expr_label, T.nilable(String)
    const :subject, T.untyped
    const :is_union, T::Boolean
    const :is_int_match, T::Boolean
    const :is_enum_match, T::Boolean
    const :expr_type_sym, T.untyped
  end

  sig { params(cond: T.untyped, pending: T::Array[T.untyped]).returns(T.untyped) }
  def loop_condition_expr(cond, pending)
    return cond if pending.empty?

    @block_expr_counter = T.let(@block_expr_counter, T.untyped)
    @block_expr_counter += 1
    label = "__while_cond_#{@block_expr_counter}"
    MIR::BlockExpr.new(label, pending + [MIR::BreakStmt.new(label, cond)])
  end

  sig { params(node: AST::IfStatement).returns(T.untyped) }
  def lower_if(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @block_expr_counter = T.let(@block_expr_counter, T.untyped)
    @enum_schemas = T.let(@enum_schemas, T.untyped)
    cond, cond_pending = lower_head { lower(node.condition) }
    if node.expr_mode
      @block_expr_counter += 1
      label = "__if_#{@block_expr_counter}"
      then_body = lower_body_with_break(node.then_branch, label)
      else_body = lower_body_with_break(node.else_branch || [], label)
      block = MIR::BlockExpr.new(label, [MIR::IfStmt.new(cond, then_body, else_body)])
      return with_pending(cond_pending, block)
    end

    then_body = lower_body(node.then_branch)
    else_body = (node.else_branch && !node.else_branch.empty?) ? lower_body(node.else_branch) : nil
    with_pending(cond_pending, MIR::IfStmt.new(cond, then_body, else_body))
  end

  sig { params(node: AST::IfBind).returns(MIR::IfBindStmt) }
  def lower_if_bind(node)
    T.bind(self, MIRLowering) rescue nil
    mir_bindings = node.bindings.map do |b|
      { expr: lower(b.expr), capture: b.name }
    end
    then_body = lower_body(node.then_branch)

    # RESOLVE bindings acquire a new strong ref that must be released.
    # Prepend `defer CheatLib.rc/arcRelease(T, alloc, capture)` to the then-body.
    node.bindings.each_with_index do |b, i|
      mir_expr = mir_bindings[i][:expr]
      next unless mir_expr.is_a?(MIR::WeakUpgrade)
      release_func = mir_expr.func == "weakArcUpgrade" ? "arcRelease" : "rcRelease"
      alloc_expr = MIR::MethodCall.new(MIR::Ident.new(@rt_name), "heapAlloc", [], false, MIR::CallableContract.no_ownership(0))
      release_call = MIR::Call.new(
        "CheatLib.#{release_func}",
        [MIR::Ident.new(mir_expr.zig_base), alloc_expr, MIR::Ident.new(b.name)],
        false,
        false,
        MIR::CallableContract.no_ownership(3)
      )
      then_body = [MIR::DeferStmt.new(release_call)] + T.must(then_body)
    end

    else_body = (node.else_branch && !node.else_branch.empty?) ? lower_body(node.else_branch) : nil
    MIR::IfBindStmt.new(mir_bindings, then_body, else_body)
  end

  # Single-source frame-arena marker injection for every loop shape
  # (lower_while / lower_while_bind / lower_for_each / lower_for_range).
  # When mark_per_iter is set by EscapeGraph (frame allocs that survive
  # past the iteration end would otherwise grow the arena unbounded),
  # prepend a saveLoopMark/restoreLoopMark pair so each iteration rewinds
  # to the pre-body high-water mark. `after_mark` is interposed between
  # the marker pair and the body (lower_for_range uses it for the
  # iteration-variable decl).
  sig { params(body: T.untyped, mark_per_iter: T.untyped, tight: T.untyped, after_mark: T::Array[T.untyped]).returns(T.untyped) }
  def prepend_loop_mark(body, mark_per_iter:, tight:, after_mark: [])
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @current_fn_has_rt = T.let(@current_fn_has_rt, T.untyped)
    @loop_mark_counter = T.let(@loop_mark_counter, T.untyped)
    @rt_name = T.let(@rt_name, T.untyped)
    suffix = after_mark + body
    needs_mark = mark_per_iter || lowered_loop_body_needs_mark?(suffix)
    return suffix unless !tight && needs_mark && @current_fn_has_rt
    rt = MIR::Ident.new(@rt_name)
    @loop_mark_counter = (@loop_mark_counter || 0) + 1
    mark_var = "__loop_mark_#{@loop_mark_counter}"
    save = MIR::Let.new(mark_var, MIR::MethodCall.new(rt, "saveLoopMark", [], false, MIR::CallableContract.no_ownership(0)), false, nil, nil)
    restore = MIR::DeferStmt.new(MIR::MethodCall.new(rt, "restoreLoopMark", [MIR::Ident.new(mark_var)], false, MIR::CallableContract.no_ownership(1)))
    [save, restore] + suffix
  end

  sig { params(body: T::Array[T.untyped]).returns(T::Boolean) }
  def lowered_loop_body_needs_mark?(body)
    lowered_loop_body_has_frame_scope?(body) { |scope| scope == :iteration }
  end

  sig { params(stmts: T.nilable(T::Array[T.untyped]), block: T.proc.params(arg0: Symbol).returns(T::Boolean)).returns(T::Boolean) }
  def lowered_loop_body_has_frame_scope?(stmts, &block)
    return false unless stmts.is_a?(Array)
    stmts.any? do |s|
      case s
      when MIR::AllocMark
        next false unless s.alloc == :frame
        scope = T.unsafe(s).scope
        block.call(scope.is_a?(Symbol) ? scope : :unknown)
      when MIR::IfStmt
        lowered_loop_body_has_frame_scope?(s.then_body, &block) || lowered_loop_body_has_frame_scope?(s.else_body, &block)
      when MIR::ScopeBlock, MIR::BlockExpr
        lowered_loop_body_has_frame_scope?(s.body, &block)
      when MIR::SwitchStmt
        s.arms.any? { |a| lowered_loop_body_has_frame_scope?(a[:body], &block) } ||
          lowered_loop_body_has_frame_scope?(s.default_body, &block)
      when MIR::IfChain
        s.branches.any? { |b| lowered_loop_body_has_frame_scope?(b[:body], &block) } ||
          lowered_loop_body_has_frame_scope?(s.default_body, &block)
      when MIR::SnapshotRead, MIR::SnapshotTransaction, MIR::SnapshotMultiTxn
        lowered_loop_body_has_frame_scope?(s.body, &block)
      when MIR::WithMatchDispatch
        s.arms.any? { |a| lowered_loop_body_has_frame_scope?(a[:body], &block) }
      else
        false
      end
    end
  end

  sig { params(stmts: T.nilable(T::Array[T.untyped])).void }
  def stamp_loop_frame_allocs_iteration!(stmts)
    return unless stmts.is_a?(Array)
    stmts.each do |s|
      case s
      when MIR::AllocMark
        s.scope = :iteration if s.alloc == :frame
      when MIR::IfStmt
        stamp_loop_frame_allocs_iteration!(s.then_body)
        stamp_loop_frame_allocs_iteration!(s.else_body)
      when MIR::ScopeBlock, MIR::BlockExpr
        stamp_loop_frame_allocs_iteration!(s.body)
      when MIR::SwitchStmt
        s.arms&.each { |a| stamp_loop_frame_allocs_iteration!(a[:body]) }
        stamp_loop_frame_allocs_iteration!(s.default_body)
      when MIR::IfChain
        s.branches&.each { |b| stamp_loop_frame_allocs_iteration!(b[:body]) }
        stamp_loop_frame_allocs_iteration!(s.default_body)
      when MIR::SnapshotRead, MIR::SnapshotTransaction, MIR::SnapshotMultiTxn
        stamp_loop_frame_allocs_iteration!(s.body)
      when MIR::WithMatchDispatch
        s.arms&.each { |a| stamp_loop_frame_allocs_iteration!(a[:body]) }
      end
    end
    nil
  end

  sig { params(node: AST::WhileLoop).returns(T.untyped) }
  def lower_while(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @current_fn_has_rt = T.let(@current_fn_has_rt, T.untyped)
    @rt_name = T.let(@rt_name, T.untyped)
    rt = MIR::Ident.new(@rt_name)
    cond, cond_pending = lower_head { lower(node.condition) }
    b = node.do_branch
    body = b.is_a?(Array) ? lower_body(b) : []
    stamp_loop_frame_allocs_iteration!(body)

    body = prepend_loop_mark(body, mark_per_iter: node.mark_per_iter, tight: node.tight)

    # Yield check at end of loop body (skip when last stmt is unconditional exit)
    if !node.tight && @current_fn_has_rt && !loop_body_exits?(body)
      body << MIR::ExprStmt.new(MIR::MethodCall.new(rt, "checkYield", [], false, MIR::CallableContract.no_ownership(0)), false)
    end

    MIR::WhileStmt.new(loop_condition_expr(cond, cond_pending), body, nil, nil, node.mark_per_iter, !!node.tight)
  end

  sig { params(node: AST::WhileBindLoop).returns(T.untyped) }
  def lower_while_bind(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @current_fn_has_rt = T.let(@current_fn_has_rt, T.untyped)
    @rt_name = T.let(@rt_name, T.untyped)
    rt = MIR::Ident.new(@rt_name)
    cond, cond_pending = lower_head { lower(node.condition) }
    body = lower_body(node.do_branch)
    stamp_loop_frame_allocs_iteration!(body)

    # RESOLVE captures acquire a strong ref each iteration — release at end of body.
    if cond.is_a?(MIR::WeakUpgrade)
      release_func = cond.func == "weakArcUpgrade" ? "arcRelease" : "rcRelease"
      alloc_expr = MIR::MethodCall.new(rt, "heapAlloc", [], false, MIR::CallableContract.no_ownership(0))
      release_call = MIR::Call.new(
        "CheatLib.#{release_func}",
        [MIR::Ident.new(cond.zig_base), alloc_expr, MIR::Ident.new(node.binding_name)],
        false,
        false,
        MIR::CallableContract.no_ownership(3)
      )
      body = [MIR::DeferStmt.new(release_call)] + T.must(body)
    end

    body = prepend_loop_mark(body, mark_per_iter: node.mark_per_iter, tight: node.tight)

    if !node.tight && @current_fn_has_rt && !loop_body_exits?(body)
      body << MIR::ExprStmt.new(MIR::MethodCall.new(rt, "checkYield", [], false, MIR::CallableContract.no_ownership(0)), false)
    end

    MIR::WhileStmt.new(loop_condition_expr(cond, cond_pending), body, node.binding_name, nil, node.mark_per_iter, false)
  end

  # Returns true when the last reachable statement in a loop body is an
  # unconditional exit (break/continue/return), making any trailing code unreachable.
  sig { params(body: T::Array[T.untyped]).returns(T::Boolean) }
  def loop_body_exits?(body)
    T.bind(self, MIRLowering) rescue nil
    return false unless body.is_a?(Array) && !body.empty?
    body.last.is_a?(MIR::BreakStmt) || body.last.is_a?(MIR::ContinueStmt) || body.last.is_a?(MIR::ReturnStmt)
  end

  sig { params(node: AST::ForEach).returns(T.untyped) }
  def lower_for_each(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @current_fn_has_rt = T.let(@current_fn_has_rt, T.untyped)
    @current_fn_param_names = T.let(@current_fn_param_names, T.untyped)
    @for_counter = T.let(@for_counter, T.untyped)
    @rt_name = T.let(@rt_name, T.untyped)
    @schema_lookup = T.let(@schema_lookup, T.untyped)
    @struct_schemas = T.let(@struct_schemas, T.untyped)
    @tmp_counter = T.let(@tmp_counter, T.untyped)
    var = zig_safe_name(node.var_name)
    body = lower_body(node.body)
    stamp_loop_frame_allocs_iteration!(body)
    rt = MIR::Ident.new(@rt_name)
    coll = lower(node.collection)
    coll_type = node.collection.full_type
    ct = coll_type.is_a?(Type) ? coll_type : Type.new(coll_type)
    collection_setup = T.let([], T::Array[T.untyped])
    if for_each_owned_collection_source?(coll)
      @tmp_counter = T.let(@tmp_counter, T.untyped)
      @tmp_counter += 1
      source_name = "__for_src_#{@tmp_counter}"
      source_alloc = for_each_owned_collection_source_alloc(coll, ct)
      entry = CleanupEntry.build(:uniform, alloc: source_alloc, has_moved_guard: false, zig_type: ct.zig_type)
      mark = MIR::AllocMark.new(source_name, source_alloc, ct)
      mark.scope = source_alloc == :heap ? :heap : :iteration
      coll.target_var = source_name if coll.is_a?(MIR::InlineZig)
      collection_setup << mark
      collection_setup << MIR::Let.new(source_name, coll, false, nil, nil)
      collection_setup << MIR::Cleanup.new(source_name, entry)
      coll = MIR::Ident.new(source_name)
    end
    is_mutable = node.is_mutable == true
    mark_per_iter = node.respond_to?(:mark_per_iter) ? node.mark_per_iter : nil
    tight = node.respond_to?(:tight) && node.tight

    body = prepend_loop_mark(body, mark_per_iter: mark_per_iter, tight: tight)

    # Yield check at end of body
    if @current_fn_has_rt
      body << MIR::ExprStmt.new(MIR::MethodCall.new(rt, "checkYield", [], false, MIR::CallableContract.no_ownership(0)), false)
    end

    loop_stmt = T.let(nil, T.untyped)
    if ct.map?
      @for_counter = (@for_counter || 0) + 1
      iter_var = "__kit_#{@for_counter}"
      # { var iter = coll.keyIterator(); while (iter.next()) |var| { body } }
      iter_init = MIR::Let.new(iter_var, MIR::MethodCall.new(coll, "keyIterator", [], false, MIR::CallableContract.no_ownership(0)), true, nil, nil)
      while_stmt = MIR::WhileStmt.new(
        MIR::MethodCall.new(MIR::Ident.new(iter_var), "next", [], false, MIR::CallableContract.no_ownership(0)),
        body, var, nil, mark_per_iter, tight
      )
      loop_stmt = MIR::ScopeBlock.new([iter_init, while_stmt])
    elsif ct.pool?
      # Pool: iterate over slots, skip dead entries.
      # Emits: for (pool.slots) |*__pslot_N| { if (!__pslot_N.alive) continue; const var = __pslot_N.value; body }
      @for_counter = (@for_counter || 0) + 1
      slot_var = "__pslot_#{@for_counter}"
      slot_ident = MIR::Ident.new(slot_var)
      slots_iter = MIR::FieldGet.new(coll, "slots")
      skip_dead = MIR::IfStmt.new(
        MIR::UnaryOp.new("!", MIR::FieldGet.new(slot_ident, "alive")),
        [MIR::ContinueStmt.new(nil)],
        nil
      )
      value_bind = MIR::Let.new(var, MIR::FieldGet.new(slot_ident, "value"), false, nil, nil)
      full_body = [skip_dead, value_bind] + body
      loop_stmt = MIR::ForStmt.new(slots_iter, "*#{slot_var}", full_body, nil, mark_per_iter, tight)
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
    elsif ct.set_collection?
      # Set: iterate via keyIterator(). next() returns ?*T so we deref in the body.
      @for_counter = (@for_counter || 0) + 1
      iter_var  = "__kit_#{@for_counter}"
      ptr_var   = "__kptr_#{@for_counter}"
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
                 @current_fn_param_names&.include?(node.collection.name)
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
      elsif is_field_access && ct.array? && (ct.dynamic? || ct.list_collection?)
        coll
      else
        MIR::AddressOf.new(coll)
      end
      # Pointer capture (|*var|) is only needed when iterating structs with mutable field
      # access. For primitive/enum/union element types, value capture (|var|) is correct
      # because primitives are Copy types and can't be meaningfully mutated in-place.
      capture = if is_mutable
        elem = ct.element_type
        elem_sym = elem.is_a?(Type) ? elem.resolved : elem
        (elem_sym && @struct_schemas.key?(elem_sym)) ? "*#{var}" : var
      else
        var
      end
      loop_stmt = MIR::ForStmt.new(iter, capture, body, nil, mark_per_iter, tight)
    end
    collection_setup.empty? ? loop_stmt : MIR::ScopeBlock.new(collection_setup + [loop_stmt])
  end

  sig { params(mir: T.untyped).returns(T::Boolean) }
  def for_each_owned_collection_source?(mir)
    return for_each_owned_collection_source?(mir.expr) if mir.is_a?(MIR::Cast) || mir.is_a?(MIR::TryExpr)
    return true if mir.is_a?(MIR::Call) && mir.owned_return?
    T.unsafe(self).mir_allocates?(mir)
  end

  sig { params(mir: T.untyped, type_info: Type).returns(Symbol) }
  def for_each_owned_collection_source_alloc(mir, type_info)
    return for_each_owned_collection_source_alloc(mir.expr, type_info) if mir.is_a?(MIR::Cast) || mir.is_a?(MIR::TryExpr)
    return :heap if mir.is_a?(MIR::Call) && mir.owned_return?
    owned_alloc = T.unsafe(self).mir_owned_alloc(mir)
    return owned_alloc if owned_alloc.is_a?(Symbol)

    type_info.cleanup_allocator(@schema_lookup)
  end

  sig { params(node: AST::ForRange).returns(MIR::ScopeBlock) }
  def lower_for_range(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @current_fn_has_rt = T.let(@current_fn_has_rt, T.untyped)
    @for_counter = T.let(@for_counter, T.untyped)
    @rt_name = T.let(@rt_name, T.untyped)
    start_val = lower(node.start_expr)
    end_val = lower(node.end_expr)
    var = zig_safe_name(node.var_name)
    body = lower_body(node.body)
    stamp_loop_frame_allocs_iteration!(body)
    rt = MIR::Ident.new(@rt_name)
    cmp = node.inclusive ? "<=" : "<"
    @for_counter = (@for_counter || 0) + 1
    iter_var = "__for_#{@for_counter}"

    # Prologue: const var: i64 = iter; _ = &var;
    var_decl = MIR::Let.new(var, MIR::Ident.new(iter_var), false, "i64", "_ = &#{var};")

    body = prepend_loop_mark(body, mark_per_iter: node.mark_per_iter, tight: node.tight, after_mark: [var_decl])

    # Yield check
    if !node.tight && @current_fn_has_rt
      body << MIR::ExprStmt.new(MIR::MethodCall.new(rt, "checkYield", [], false, MIR::CallableContract.no_ownership(0)), false)
    end

    # Update: iter += 1
    update = MIR::Set.new(MIR::Ident.new(iter_var), MIR::BinOp.new("+", MIR::Ident.new(iter_var), MIR::Lit.new("1")))

    # Condition: iter cmp end
    cond = MIR::BinOp.new(cmp, MIR::Ident.new(iter_var), end_val)

    # Wrapping block: { var __for: i64 = start; while (...) : (...) { body } }
    iter_init = MIR::Let.new(iter_var, start_val, true, "i64", nil)
    tight = node.respond_to?(:tight) && node.tight
    while_stmt = MIR::WhileStmt.new(cond, body, nil, update, node.respond_to?(:mark_per_iter) ? node.mark_per_iter : nil, tight)
    MIR::ScopeBlock.new([iter_init, while_stmt])
  end

  sig { params(node: AST::MatchStatement).returns(T.untyped) }
  def lower_match(node)
    T.bind(self, MIRLowering) rescue nil
    facts = match_lowering_facts(node)
    expr_label = facts.expr_label
    subject = facts.subject
    is_union = facts.is_union

    if facts.is_int_match || facts.is_enum_match
      result = lower_switch_match(node, facts)
    else
      # If-chain for unions, strings, and complex patterns
      tag_eq = ->(v) { MIR::BinOp.new("==", MIR::Call.new("std.meta.activeTag", [subject], false), MIR::Ident.new(".#{v}")) }
      union_bindings = ->(c, v, is_mutable) {
        if c.binding
          payload = MIR::FieldGet.new(subject, v.to_s)
          payload = MIR::Deref.new(payload) if c.indirect_payload_as
          [MIR::Let.new(c.binding, payload, is_mutable, nil, "_ = &#{c.binding};")]
        elsif c.destructure
          c.destructure.fields.filter_map do |f|
            next if f.wildcard?
            next unless f.bind?
            field = MIR::FieldGet.new(MIR::FieldGet.new(subject, v.to_s), f.name.to_s)
            MIR::Let.new(f.name.to_s, field, false, nil, "_ = &#{f.name};")
          end
        else
          []
        end
      }
      branches = node.cases.flat_map { |c|
        body = lower_match_branch(c.body, expr_label)
        body = hoist_unhoisted_return_allocs(body, c.body)
        # WHEN-arms are subject-independent guard expressions, even on
        # union subjects. Dispatch them BEFORE the union/string/eq
        # paths or the union path will treat c.value (a Bool expr)
        # as a variant tag and emit `tag == .true`-style invalid Zig.
        if c.kind == :when
          [{ cond: lower(c.value), body: body }]
        elsif is_union
          variant = case c.value
                    when AST::GetField then c.value.field
                    when AST::MethodCall then c.value.name
                    # PURE: fallback case value for union/string match is a literal or identifier.
                    else emit_expr(lower(c.value))
                    end
          extra_variants = (c.extra_values || []).map { |ev|
            case ev
            when AST::GetField then ev.field
            when AST::MethodCall then ev.name
            end
          }.compact
          arm_variants = [variant, *extra_variants]
          is_mutable = node.expr.is_a?(AST::Identifier) && node.expr.was_moved
          # Multi-arm with AS / destructure: the binding/destructure
          # reads `subject.<variant>`, which Zig safety-checks against
          # the active tag at runtime. `subject.A` is a UB read when
          # the active variant is B, even if A and B have identical
          # payload types. Expand into one branch per variant — body
          # cloned, each branch binding the matched variant's payload.
          # NOTE: body.dup is shallow. MIR nodes are immutable Structs,
          # so sharing references inside the array is safe; if any
          # downstream pass starts mutating MIR nodes in place this
          # invariant must be revisited.
          if (c.binding || c.destructure) && arm_variants.length > 1
            arm_variants.map { |v|
              { cond: tag_eq.call(v), body: union_bindings.call(c, v, is_mutable) + body.dup }
            }
          else
            body = union_bindings.call(c, variant, is_mutable) + T.must(body) if c.binding || c.destructure
            cond = arm_variants.map { |v| tag_eq.call(v) }.reduce { |acc, x| MIR::BinOp.new("or", acc, x) }
            [{ cond: cond, body: body }]
          end
        else
          cond = if node.string_match
            head_eql = emit_builtin(:strEql, [subject, lower(c.value)])
            (c.extra_values || []).reduce(head_eql) do |acc, ev|
              MIR::BinOp.new("or", acc, emit_builtin(:strEql, [subject, lower(ev)]))
            end
          elsif c.kind == :struct_pattern
            pat = c.value
            cond_parts, bind_stmts = lower_struct_pattern(subject, pat)
            body = bind_stmts + body if bind_stmts.any?
            if cond_parts.empty?
              MIR::Lit.new("true")
            else
              cond_parts.reduce { |acc, part| MIR::BinOp.new("and", acc, part) }
            end
          elsif c.kind == :when
            # WHEN guard: condition IS the guard expression, not subject == guard
            lower(c.value)
          else
            head_eq = MIR::BinOp.new("==", subject, lower(c.value))
            (c.extra_values || []).reduce(head_eq) do |acc, ev|
              MIR::BinOp.new("or", acc, MIR::BinOp.new("==", subject, lower(ev)))
            end
          end
          [{ cond: cond, body: body }]
        end
      }
      default = (node.default_case && !node.default_case.empty?) ? lower_match_branch(node.default_case, expr_label) : nil
      default = hoist_unhoisted_return_allocs(default, node.default_case) if default
      result = MIR::IfChain.new(branches, default)
    end

    expr_label ? MIR::BlockExpr.new(expr_label, [result]) : result
  end

  sig { params(node: AST::MatchStatement).returns(MatchLoweringFacts) }
  def match_lowering_facts(node)
    T.bind(self, MIRLowering) rescue nil
    @block_expr_counter = T.let(@block_expr_counter, T.untyped)
    @enum_schemas = T.let(@enum_schemas, T.untyped)
    @union_schemas = T.let(@union_schemas, T.untyped)
    expr_label = if node.expr_mode
      @block_expr_counter += 1
      "__match_#{@block_expr_counter}"
    end
    subject = lower(node.expr)
    union_lookup = begin
      t = Type.new(node.expr.resolved_type || :Any)
      t.generic_instance? ? t.generic_base : t.resolved
    end
    is_union = !!@union_schemas&.key?(union_lookup)
    expr_type = node.expr.resolved_type
    expr_type_sym = expr_type.is_a?(Type) ? expr_type.resolved : expr_type
    is_int_match = !!(!is_union && !node.string_match &&
      (expr_type == :Int64 || expr_type == :Int32 || expr_type == :Int16 || expr_type == :Int8 ||
       (expr_type.is_a?(Type) && expr_type.integer?)) &&
      node.cases.all? { |c| c.kind != :when && c.kind != :struct_pattern &&
                            [c.value, *(c.extra_values || [])].all? { |p|
                              p.is_a?(AST::Literal) && (p.type == :INT64 || p.type == :NUMBER)
                            } })
    is_enum_match = !!(!is_union && !node.string_match && @enum_schemas&.key?(expr_type_sym) &&
      node.cases.all? { |c| c.kind != :when && c.kind != :struct_pattern &&
                            [c.value, *(c.extra_values || [])].all? { |p| p.is_a?(AST::GetField) } })
    MatchLoweringFacts.new(
      expr_label: expr_label,
      subject: subject,
      is_union: is_union,
      is_int_match: is_int_match,
      is_enum_match: is_enum_match,
      expr_type_sym: expr_type_sym
    )
  end

  sig { params(stmts: T::Array[T.untyped], expr_label: T.nilable(String)).returns(T::Array[T.untyped]) }
  def lower_match_branch(stmts, expr_label)
    T.bind(self, MIRLowering) rescue nil
    T.must(expr_label ? lower_body_with_break(stmts, expr_label) : lower_body(stmts))
  end

  sig { params(node: AST::MatchStatement, facts: MatchLoweringFacts).returns(MIR::SwitchStmt) }
  def lower_switch_match(node, facts)
    T.bind(self, MIRLowering) rescue nil
    @enum_schemas = T.let(@enum_schemas, T.untyped)
    arms = node.cases.map { |c|
      body = lower_match_branch(c.body, facts.expr_label)
      # Multi-pattern arm: emit `.A, .B, .C` (Zig switch supports
      # comma-separated prongs natively; the body is shared).
      head_pat = if facts.is_enum_match
        ".#{c.value.field}"
      else
        emit_expr(lower(c.value))
      end
      extras_pats = (c.extra_values || []).map { |ev|
        if facts.is_enum_match
          ".#{ev.field}"
        else
          emit_expr(lower(ev))
        end
      }
      pattern = ([head_pat] + extras_pats).join(", ")
      { pattern: pattern, body: body }
    }
    default = (node.default_case && !node.default_case.empty?) ? lower_match_branch(node.default_case, facts.expr_label) : nil
    # Int switches always need else => {} in Zig (Zig 0.16 requires exhaustive switch)
    default ||= [] if facts.is_int_match
    # Non-exhaustive enum match without DEFAULT needs else => {} to satisfy Zig
    if facts.is_enum_match && !default
      all_variants = @enum_schemas[facts.expr_type_sym]&.map(&:to_s)&.sort || []
      covered = node.cases.flat_map { |c|
        [c.value.field.to_s, *((c.extra_values || []).map { |ev| ev.field.to_s })]
      }.sort
      default = [] unless covered == all_variants
    end
    MIR::SwitchStmt.new(facts.subject, arms, default)
  end

  sig { params(body: T.nilable(T::Array[T.untyped]), ast_stmts: T.untyped).returns(T.nilable(T::Array[T.untyped])) }
  def hoist_unhoisted_return_allocs(body, ast_stmts)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @tmp_counter = T.let(@tmp_counter, T.untyped)
    return body unless body
    returns = T.let([], T::Array[T.untyped])
    Array(ast_stmts).each { |s| returns << s.value if s.is_a?(AST::ReturnNode) && s.value }
    ret_i = T.let(0, Integer)

    body.flat_map do |stmt|
      unless stmt.is_a?(MIR::ReturnStmt) && stmt.value && mir_allocates?(stmt.value)
        ret_i += 1 if stmt.is_a?(MIR::ReturnStmt)
        next [stmt]
      end

      ast_value = returns[ret_i]
      ret_i += 1
      @tmp_counter += 1
      name = "__tmp_#{@tmp_counter}"
      entry = hoist_cleanup_entry(stmt.value, ast_value)
      mark = MIR::AllocMark.new(name, :heap, nil)
      mark.scope = :heap
      out = T.let([
        mark,
        MIR::Let.new(name, stmt.value, false, nil, nil)
      ], T::Array[T.untyped])
      out << MIR::ErrCleanup.new(name, entry) if entry
      out << MIR::TransferMark.new(name, :return) if entry
      out << MIR::ReturnStmt.new(MIR::Ident.new(name))
      out
    end
  end

  sig { params(node: AST::ReturnNode).returns(T.untyped) }
  def lower_return(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @current_fn_tail_call = T.let(@current_fn_tail_call, T.untyped)
    @current_fn_zig_name = T.let(@current_fn_zig_name, T.untyped)
    @debug_mode = T.let(@debug_mode, T.untyped)
    @pending_stmts = T.let(@pending_stmts, T.untyped)
    @rt_name = T.let(@rt_name, T.untyped)
    @current_fn_heap_carry_return = T.let(@current_fn_heap_carry_return, T.untyped)
    @current_fn_param_names = T.let(@current_fn_param_names, T.untyped)
    @current_fn_takes_param_names = T.let(@current_fn_takes_param_names, T.untyped)
    @schema_lookup = T.let(@schema_lookup, T.untyped)
    # The return expression's allocating sub-nodes inherit the function's
    # finalized return placement -- the return slot is their "binding".
    pending_start = @pending_stmts.length
    ret_alloc = return_destination_alloc(node)
    value = node.value ? with_decl_alloc(ret_alloc) do
      lowered = lower(node.value)
      place_value_for_destination(lowered, node.value, ret_alloc, node.value.full_type)
    end : nil
    rt_name = @rt_name

    # If the return value is a hoisted temp, convert its Cleanup to ErrCleanup:
    # the caller takes ownership on success, so we only clean up on error.
    # Borrow-position temps (intermediates, not the return value) keep regular
    # Cleanup (defer) -- they are freed normally when the function exits.
    returned_names = returned_binding_names(node.value)
    returned_names.merge(collect_moved_arg_roots(node))
    returned_names.merge(collect_stdlib_consumed_roots(node))
    converted_return_cleanup_names = T.let(Set.new, T::Set[String])
    if value.is_a?(MIR::Ident)
      returned_names << value.name
    end
    if node.value.is_a?(AST::StructLit) || node.value.is_a?(AST::UnionVariantLit)
      returned_names.merge(mir_ident_names(value))
    end

    if @current_fn_return_payload_zig&.start_with?("*") &&
       value && !value.is_a?(MIR::HeapCreate) && !value.is_a?(MIR::Call) &&
       !return_value_already_payload_pointer?(node.value)
      bare_ret = @current_fn_return_payload_zig.sub(/\A\*/, "")
      value = MIR::HeapCreate.new(bare_ret, value, :heap, "ret")
    end

    if @current_fn_heap_carry_return && node.value && value &&
       !value.is_a?(MIR::Ident) &&
       !return_transfers_heap_binding?(node.value) &&
       !mir_allocates?(value) && !(value.is_a?(MIR::Call) && value.owned_return?)
      ret_type = Type.from_node(node.value)
      ret_type = ret_type.payload_type if ret_type&.error_union?
      value = place_value_for_destination(value, node.value, :heap, ret_type) if escaping_value_alloc(ret_type) == :heap
    end

    if @current_fn_heap_carry_return && node.value && value.is_a?(MIR::Ident) &&
       @current_fn_param_names&.include?(value.name) &&
       !@current_fn_takes_param_names&.include?(value.name)
      ret_type = Type.from_node(node.value)
      ret_type = ret_type.payload_type if ret_type&.error_union?
      if ret_type&.recursive_cleanup_shape?(@schema_lookup)
        value = MIR::DeepCopy.new(value, ret_type.zig_type, nil, :full_value, :heap)
      end
    end

    # Tail call optimization: convert self-recursive return to @call(.always_tail, ...)
    # Disabled in debug mode (stage2 Zig backend doesn't support always_tail reliably)
    if @current_fn_tail_call && !@debug_mode && value.is_a?(MIR::Call) && value.callee == @current_fn_zig_name
      return MIR::ReturnStmt.new(MIR::TailCall.new(value.callee, value.args, value.callable_contract))
    end

    # Rc/Arc return of a local cleanup binding transfers that binding's
    # existing strong ref. Borrowed/non-local identifiers still retain.
    if node.value && rc_retain_needed?(node.value) && !return_transfers_heap_binding?(node.value)
      ret = MIR::ReturnStmt.new(make_rc_retain(node.value))
      marks = returned_transfer_marks(value, returned_names, converted_return_cleanup_names)
      return marks + [ret] unless marks.empty?
      ret
    else
      # Hoist allocating expressions (DeepCopy, ConcatStr, Cast wrapping these,
      # etc.) to a named Let so the checker sees it in Let-init position.
      # ErrCleanup: the caller takes ownership on success.
      # Skip Call nodes: they are not flagged by UNHOISTED_ALLOC and the test
      # contract requires heap-returning calls to remain inline (no __tmp wrap).
      value = hoist_alloc(value, node.value, err_cleanup: true, transfer_on_success: false) if value && !value.is_a?(MIR::Call)
      ret = MIR::ReturnStmt.new(value)
      marks = returned_transfer_marks(value, returned_names, converted_return_cleanup_names)
      return marks + [ret] unless marks.empty?
      ret
    end
  end

  # ================================================================
  # Helpers
  # ================================================================

  sig { params(ast_node: T.untyped).returns(T::Boolean) }
  def return_transfers_heap_binding?(ast_node)
    node = T.let(ast_node, T.untyped)
    node = node.value while node.is_a?(AST::Cast) || node.is_a?(AST::MoveNode)
    root = AST.root_identifier(node) rescue nil
    @current_bindings = T.let(@current_bindings, T.untyped)
    entry = root ? @current_bindings[root.name] : nil
    return entry.needs_cleanup? && entry.alloc == :heap if entry&.present?

    !!(root && @current_fn_takes_param_names&.include?(root.name.to_s) && root.symbol&.heap_storage?)
  end

  sig { params(ast_node: T.untyped).returns(T::Boolean) }
  def return_value_already_payload_pointer?(ast_node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @current_fn_return_payload_zig = T.let(@current_fn_return_payload_zig, T.untyped)
    return false unless ast_node && @current_fn_return_payload_zig
    ti = Type.from_node!(ast_node, context: "return payload pointer")
    ti.zig_type == @current_fn_return_payload_zig
  rescue StandardError
    false
  end

  sig { params(expr: T.untyped).returns(T::Set[String]) }
  def returned_binding_names(expr)
    T.bind(self, MIRLowering) rescue nil
    names = T.let(Set.new, T::Set[String])
    collect_returned_binding_names(expr, names)
    names
  end

  sig { params(body: T.nilable(T::Array[T.untyped])).returns(T::Set[String]) }
  def collect_fn_returned_names(body)
    T.bind(self, MIRLowering) rescue nil
    names = T.let(Set.new, T::Set[String])
    return names unless body
    AST.walk_body(body) do |node|
      collect_returned_binding_names(node.value, names) if node.is_a?(AST::ReturnNode)
    end
    names
  end

  sig { params(expr: T.untyped, names: T::Set[String]).void }
  def collect_returned_binding_names(expr, names)
    T.bind(self, MIRLowering) rescue nil
    return unless expr
    case expr
    when AST::Identifier
      name = zig_safe_name(expr.name)
      names << name if name
    when AST::MoveNode, AST::ShareNode
      collect_returned_binding_names(expr.value, names)
    when AST::CopyNode, AST::CloneNode, AST::FreezeNode
      return
    when AST::StructLit, AST::UnionVariantLit
      expr.fields.each_value { |v| collect_returned_binding_names(v, names) }
    when AST::ListLit
      expr.items.each { |v| collect_returned_binding_names(v, names) }
    when AST::BinaryOp
      collect_returned_binding_names(expr.left, names) if expr.op == :OR_RESCUE
    when AST::GetField, AST::GetIndex
      collect_returned_binding_names(expr.target, names)
    end
    nil
  end

  # Check if an AST FuncCall/MethodCall returns a heap-allocated value.
  sig { params(node: T.untyped).returns(T::Boolean) }
  def call_heap_storage?(node)
    T.bind(self, MIRLowering) rescue nil
    !!(node.is_a?(AST::Locatable) && node.heap_storage?)
  end

  sig { params(sig_obj: T.untyped).returns(T::Boolean) }
  def callee_returns_heap_string?(sig_obj)
    T.bind(self, MIRLowering) rescue nil
    return false unless sig_obj && sig_obj.respond_to?(:return_type)
    return false if sig_obj.respond_to?(:return_lifetime) && !sig_obj.return_lifetime.empty?
    ti = Type.new(sig_obj.return_type)
    ti = ti.payload_type || ti if ti.error_union?
    ti.string? && !ti.symbol? && !ti.raw?
  rescue StandardError
    false
  end

  # Returns true if a MIR::Call node returns a non-Copy union type that needs
  # a cleanup defer when used as a temporary in a non-TAKES argument position.
  # heap_storage? misses these: unions like Value are stack-sized but own heap
  # memory (via @indirect fields). When returned inline as a non-TAKES argument,
  # they must be hoisted to a named let with a defer.
  sig { params(expr: T.untyped, ast_node: T.untyped).returns(T::Boolean) }
  def call_union_return_needs_hoist?(expr, ast_node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @union_schemas = T.let(@union_schemas, T.untyped)
    return false unless expr.is_a?(MIR::Call)
    ti = Type.from_node(ast_node)
    return false unless ti
    ti = ti.payload_type || ti if ti.error_union?
    is_heap = (ast_node.is_a?(AST::Locatable) && ast_node.heap_storage?) || ti.heap?
    return false if is_heap  # already handled by mir_allocates?
    @union_schemas&.key?(ti.resolved)    # user-defined unions may own heap fields
  end

  # Detect call-site auto-borrow for universal polymorphism. Plain T args
  # need `&arg`; wrapped/sync args are already pointer-like or unwrapped by
  # the polymorphic helper.
  sig { params(arg_node: T.untyped, callee_sig: T.untyped, idx: Integer).returns(T::Boolean) }
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
    return false if sym.sync || sym.rc_stored? ||
                    sym.local_storage? || sym.heap_storage?
    # Only auto-borrow MUTABLE plain T: an immutable plain T can't be
    # mutated through any path so & buys us nothing (and would be a
    # pessimization).
    return false unless sym.respond_to?(:mutable) && sym.mutable
    true
  end

  sig { params(name: String).returns(T::Boolean) }
  def callee_needs_rt?(name)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @fn_sigs = T.let(@fn_sigs, T.untyped)
    return true if false || name.to_s.empty?
    sig = @fn_sigs&.dig(name) || @fn_sigs&.dig(name.to_sym) || @fn_sigs&.dig(name.to_s)
    sig ? (sig.needs_rt.nil? ? true : sig.needs_rt) : true
  end

  # Lower a StructPattern into (conditions, binding_stmts).
  # conditions: Array of Zig boolean fragments ("subject.x == 10")
  # binding_stmts: Array of MIR nodes (const decls for :bind fields)

end
