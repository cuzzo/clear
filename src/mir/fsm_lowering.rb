# typed: strict
require "sorbet-runtime"
require_relative '../ast/type'
require_relative 'fsm_ops'
require_relative 'fsm_wrapper_emitter'

# FSM lowering support helpers. Mixed into MIRLowering as a module
# so the helpers share the lowering's ambient state
# (@do_capture_map, @pending_stmts, @current_bg_pointer_captures,
# @rt_name) and core helpers (lower, emit_expr,
# with_fiber_capture_map, hoist_alloc, ...).
#
# Top-level FSM emission lives in src/mir/fsm_transform.rb +
# src/mir/fsm_transform/{recursive_splitter,emit,suspend_resolvers,
# liveness}.rb -- this file holds only what those need from the
# rest of the lowering pipeline:
#
#   capture_inits_fsm                  -- ctx struct init helper
#   lower_step_stmts / emit_step_stmts -- AST stmt list -> MIR -> Zig
#                                          text (consults
#                                          @do_capture_map)
#   render_mir_list                    -- shared MIREmitter wrapper
#   promote_fsm_decls_to_fields        -- regex rewrite of `var X = ...`
#                                          to `__ctx.X = ...` for
#                                          conservatively-promoted
#                                          body locals
#   fsm_cap_metadata                   -- per-cap lock-acquire metadata
#                                          (try_method, alias_data_ref,
#                                          retries) used by
#                                          Emit.expand_lock_segment
#   emit_fsm_lock_error_arm_split      -- ON-clause error-arm body
#                                          renderer for the
#                                          FsmTailRetryOrError fail step
#   default_fsm_lock_error_arm_split   -- default error-arm body when
#                                          no ON clause is present
module FsmLowering
    extend T::Sig

  # The stackful capture_inits string starts with `.inner = ..., .alloc = ...`
  # followed by user captures. For FSM we pre-set those fields with their
  # explicit values in the struct-literal, so extract just the capture
  # portion (everything after the alloc init).
  sig { params(capture_inits: String).returns(String) }
  def capture_inits_fsm(capture_inits)
    T.bind(self, MIRLowering) rescue nil
    # Drop leading ".inner = X.inner, .alloc = Y, " portion.
    parts = capture_inits.split(", ").drop(2)
    parts.empty? ? "" : parts.join(", ") + ","
  end
  sig { params(code: String, promoted_names: T::Array[String], ctx_var: String).returns(String) }
  def promote_fsm_decls_to_fields(code, promoted_names, ctx_var)
    T.bind(self, MIRLowering) rescue nil
    return code if promoted_names.empty?
    out = code.dup
    promoted_names.each do |name|
      esc = Regexp.escape(name)
      local_name = "#{esc}(?:_L\\d+)?"
      out = out.gsub(/(^|\n)(\s*)(?:const|var)\s+#{local_name}\s*(?::\s*[^=]+)?=\s*/) do
        "#{$1}#{$2}#{ctx_var}.#{name} = "
      end
      out = out.gsub(/\b#{esc}_L\d+\b/, "#{ctx_var}.#{name}")
      out = out.gsub(/@TypeOf\(\s*#{esc}\s*\)/, "@TypeOf(#{ctx_var}.#{name})")
      out = out.gsub(/&#{esc}\b/, "&#{ctx_var}.#{name}")
      out = out.gsub(/\s*_\s*=\s*&?#{esc}\s*;/, "")
    end
    out
  end

  # Lower a list of statements and produce Zig text. If no_result is
  # true, all stmts are emitted as intermediates. Otherwise the last
  # stmt may set `__ctx_N.inner.result = ...;` (for non-void result
  # types). Mirrors the inner loop of lower_bg_block but exposed as a
  # helper so Phase B2 can call it twice (once for pre-stmts, once for
  # post-stmts).
  # Lower a list of step statements to MIR. Returns:
  #   no_result: true  -> [MIR::Stmt]
  #   no_result: false -> [pre: [MIR::Stmt], result: [MIR::Stmt]]
  #
  # The "result" segment for value-producing FSM steps is the
  # final expression's MIR plus any pending hoists, wrapped in a
  # typed MIR::Set assignment to ctx.inner.result. The strip-try
  # rewrite is applied to the lowered MIR via the existing
  # `strip_try` helper.\n  #\n  # `lower_step_stmts` produces MIR statements; `emit_step_stmts`
  # below renders the same MIR to Zig text via MIREmitter. The
  # recursive emit path uses emit_step_stmts.
  sig { params(stmts: T::Array[T.untyped], no_result: T::Boolean, ctx_id: T.nilable(Integer)).returns(T::Array[T.untyped]) }
  def lower_step_stmts(stmts, no_result:, ctx_id: nil)
    T.bind(self, MIRLowering) rescue {}
    flat_steps = []
    stmts.each do |stmt|
      if stmt.is_a?(AST::ThenChain)
        stmt.steps.each { |s| flat_steps << s }
      else
        flat_steps << { expr: stmt, binding: nil }
      end
    end

    if no_result
      out = []
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

      result_mir = []
      if last_step
        expr_type = last_step[:expr].full_type!
        expr_t = expr_type.is_a?(Type) ? expr_type : (Type.new(expr_type) rescue nil)
        result_alloc = escaping_value_alloc(expr_t)
        last_mir = with_decl_alloc(result_alloc) { lower(last_step[:expr]) }
        last_mir = place_value_for_destination(last_mir, last_step[:expr], result_alloc, expr_t) if last_mir
        last_mir = hoist_alloc(last_mir, last_step[:expr], err_cleanup: true) if last_mir && mir_allocates?(last_mir)
        last_pending = flush_pending
        result_mir.concat(last_pending)

        last_is_assign = last_step[:expr].is_a?(AST::Assignment)
        is_step_void = ast_void_type?(expr_type)

        if last_is_assign || is_step_void
          stmt_mir = wrap_step_as_stmt({ expr: last_step[:expr], binding: nil }, last_mir)
          result_mir << stmt_mir if stmt_mir
        elsif last_mir
          # Synthetic: __ctx_<id>.inner.result = <expr-without-try>;
          # As MIR: target is a typed FieldGet path, value is the
          # lowered expression with try stripped (since the
          # surrounding `inner.result = X` doesn't propagate errors;
          # the call expression's inner errors stay as anyerror!T
          # values stored in the result field). Both branches now
          # emit MIR::Set against the same typed target -- no
          # RawZig in the FSM-IO post-result line.
          ctx_ident = MIR::Ident.new("__ctx_#{ctx_id}")
          target = MIR::FieldGet.new(
            MIR::FieldGet.new(ctx_ident, "inner"),
            "result",
          )
          # The fiber's tail value is escape-placed on the heap like any
          # other escaping binding; the promise stores it directly and
          # the consumer (NEXT) owns and frees it. No per-promise
          # allocator, no dupe.
          result_mir << MIR::Set.new(target, strip_try(last_mir), false)
          result_mir.concat(fsm_result_transfer_marks(last_mir, last_step[:expr]))
          if last_step[:expr].is_a?(AST::Identifier)
            guard_map = instance_variable_get(:@current_fsm_owned_result_guards) rescue nil
            guard_name = guard_map&.[](last_step[:expr].name.to_s)
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

      [pre_mir, result_mir]
    end
  end

  sig { params(result_mir: T.untyped, ast_node: T.untyped).returns(T::Array[T.untyped]) }
  def fsm_result_transfer_marks(result_mir, ast_node)
    T.bind(self, MIRLowering) rescue nil
    @fn_name_rename_map = T.let(@fn_name_rename_map, T.untyped)
    @current_bindings = T.let(@current_bindings, T.untyped)
    @guarded_cleanup_names = T.let(@guarded_cleanup_names, T.untyped)
    marks = T.let([], T::Array[T.untyped])
    consumed = collect_mir_consumed_roots(result_mir)
    consumed.concat(fsm_ast_result_consumed_roots(ast_node))
    consumed.each do |name|
      safe = zig_safe_name(name.to_s)
      safe = @fn_name_rename_map[safe] if @fn_name_rename_map&.key?(safe)
      entry = @current_bindings[name.to_s] || @current_bindings[safe.to_s] || CleanupEntry::NONE
      next unless entry.present?
      marks << MIR::TransferMark.new(safe.to_s, :owned_sink, entry.alloc)
      if entry.has_moved_guard? || @guarded_cleanup_names&.[](safe.to_s)
        marks << MIR::MoveMark.new(safe.to_s)
      end
    end
    marks
  end

  sig { params(node: T.untyped).returns(T::Array[String]) }
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
      names << node.name.to_s if AST.moved?(node)
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
    @current_bindings = T.let(@current_bindings, T.untyped)
    ti = node.full_type!(context: "FSM owned transfer identifier")
    return false unless T.unsafe(self).ownership_tracked_transfer_type?(ti)
    entry = @current_bindings[node.name.to_s] || CleanupEntry::NONE
    (entry.present? && entry.alloc == :heap) || node.symbol&.heap_storage? == true
  end

  # Lower one step expression into a list of MIR statements
  # (pending hoists + the wrapped main statement). Returns nil
  # when the underlying lowering fails (e.g. the AST node has no
  # MIR equivalent yet).
  sig { params(step: T::Hash[Symbol, T.untyped]).returns(T.nilable(T::Array[T.untyped])) }
  def lower_one_step_to_mir(step)
    T.bind(self, MIRLowering) rescue nil
    mir = lower(step[:expr])
    return nil if mir.nil?
    pending = flush_pending
    # `lower_var_decl` may return an Array (e.g. [AllocMark, Let,
    # Cleanup]) for cleanup-needing bindings. After the FreshHeapCopy
    # capture wiring on master's BG path, this also arrives inside
    # FSM-lowered bodies. Each element is its own statement; the
    # binding (if any) is already absorbed into the MIR::Let inside
    # the array.
    if mir.is_a?(Array)
      return pending + mir.compact
    end
    main = wrap_step_as_stmt(step, mir)
    return pending if main.nil?
    pending + [main]
  end

  # Wrap an expression-shaped MIR node as a statement-shaped node
  # using the step's binding metadata + the AST node's type info
  # to decide between MIR::Let, MIR::ExprStmt(discard), and
  # MIR::ExprStmt(value-as-statement). Statement-shaped nodes
  # (MIR::Let, MIR::Set, MIR::IfStmt, MIR::BgBlock, ...) pass
  # through unchanged.
  sig { params(step: T::Hash[Symbol, T.untyped], mir: T.untyped).returns(T.untyped) }
  def wrap_step_as_stmt(step, mir)
    T.bind(self, MIRLowering) rescue nil
    return nil if mir.nil?
    if step[:binding]
      return MIR::Let.new(step[:binding], mir, false, nil, nil)
    end
    return mir if mir.respond_to?(:stmt?) && mir.stmt?
    expr_type = step[:expr].full_type!
    is_void_step = ast_void_type?(expr_type)
    MIR::ExprStmt.new(mir, !is_void_step)
  end

  # Text-shaped facade over lower_step_stmts. Lowers stmts to MIR
  # then renders each through MIREmitter. Returns a Zig string for
  # no_result: true, or a [pre, result] tuple otherwise (where
  # `result` is the trailing `__ctx.inner.result = <expr>;`
  # assignment ready for splicing into the dispatch).
  sig { params(stmts: T::Array[T.untyped], no_result: T::Boolean, ctx_id: T.nilable(Integer)).returns(T.untyped) }
  def emit_step_stmts(stmts, no_result:, ctx_id: nil)
    T.bind(self, MIRLowering) rescue {}
    result = lower_step_stmts(stmts, no_result: no_result, ctx_id: ctx_id)
    if no_result
      render_mir_list(result)
    else
      [render_mir_list(result[0]), render_mir_list(result[1])]
    end
  end
  sig { params(mir_list: T::Array[T.untyped]).returns(String) }
  def render_mir_list(mir_list)
    T.bind(self, MIRLowering) rescue nil
    return "" if false || mir_list.empty?
    @_emitter = T.let(@_emitter, T.nilable(MIREmitter))
    @_emitter ||= begin
      require_relative "mir_emitter"
      MIREmitter.new
    end
    @rt_name = T.let(@rt_name, T.nilable(String))
    @_emitter.rt_name = @rt_name || "rt"
    # `lower_var_decl` may return an Array of MIR nodes (e.g.
    # [AllocMark, Let, Cleanup]) for cleanup-needing bindings. After
    # the FreshHeapCopy capture wiring on master's BG path, this also
    # arrives inside FSM-lowered fiber bodies (test 258 / 273 etc.).
    # Flatten one level so each emit sees a single MIR node.
    mir_list.flatten(1).filter_map { |n|
      out = @_emitter.emit(n)
      next nil if out.nil? || out.strip.empty?
      stripped = out.strip
      out = out + ";" if stripped.start_with?("try ") && !stripped.end_with?(";", "}")
      out
    }.join("\n            ")
  end
  # Resolve ONE capability's lock-acquire metadata. Returns
  # { try_method, unlock_method, lock_field_ref, alias_name,
  #   alias_data_ref, retries, lock_kind, cap } or nil if `cap`
  # isn't a lock-suspending capability or its target isn't a BG
  # capture. Consumed by FsmTransform::Emit.expand_lock_segment
  # (per-cap fan-out) for both single-cap and multi-cap WITH.
  sig { params(cap: AST::Capability, with_node: AST::WithBlock, ctx_id: Integer, captured: T::Hash[String, Type]).returns(T.nilable(T::Hash[Symbol, T::Hash[Symbol, T.untyped]])) }
  def fsm_cap_metadata(cap, with_node, ctx_id, captured)
    T.bind(self, MIRLowering) rescue nil
    return nil unless cap[:capability] == :EXCLUSIVE ||
                      cap[:capability] == :write_locked_read

    var_node = cap[:var_node]
    return nil unless var_node.is_a?(AST::Identifier)
    lock_var_name = var_node.name
    alias_name = cap[:alias] || lock_var_name
    return nil unless captured.key?(lock_var_name)

    resolved = cap[:resolved_type]
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
                         (resolved&.sync == :locked || resolved&.sync == :write_locked)
    lock_kind = if cap[:capability] == :write_locked_read
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

    retries = (with_node.lock_error_clause &&
               with_node.lock_error_clause[:retries]) || 0

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
  # Render the lock_error_clause action as a body + exit kind for
  # the FsmTailRetryOrError fail step. Returns:
  #   { body_zig: String, exit_kind: :done | :goto_post }
  #
  #   :done       -> fail-step segment uses Segments::Done as its
  #                  tail (sets inner.result + wg.done + destroy +
  #                  return Done). Body sets inner.result for
  #                  raise/exit/default.
  #   :goto_post  -> fail-step segment Gotos to the post-WITH
  #                  segment. Body is empty for :pass, the user
  #                  block for :block.
  sig { params(clause: T::Hash[Symbol, T.untyped], ctx_id: Integer, with_node: AST::WithBlock, capture_map: T::Hash[String, String], pointer_captures: T::Set[T.untyped], bg_rt: String, rt_name: String).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  def emit_fsm_lock_error_arm_split(clause:, ctx_id:, with_node:,
                                    capture_map:, pointer_captures:, bg_rt:,
                                    rt_name:)
    T.bind(self, MIRLowering) rescue nil
    line = with_node.token&.line.to_s
    case clause[:action]
    when :raise
      body = <<~ZIG.chomp
        __ctx_#{ctx_id}.rt.setError(.Transient, @intFromEnum(ErrorName.LockTimeout), "lock acquire failed", #{line});
        __ctx_#{ctx_id}.inner.result = error.CheatError;
      ZIG
      { body_zig: body, exit_kind: :done }
    when :exit
      msg_zig = with_fiber_capture_map(capture_map, rt_override: bg_rt) do
        emit_expr(lower(clause[:message]))
      end
      return nil if msg_zig.nil?
      body = <<~ZIG.chomp
        __ctx_#{ctx_id}.rt.setError(.Transient, @intFromEnum(ErrorName.LockTimeout), #{msg_zig}, #{line});
        __ctx_#{ctx_id}.inner.result = error.CheatError;
      ZIG
      { body_zig: body, exit_kind: :done }
    when :pass
      { body_zig: "", exit_kind: :goto_post }
    when :block
      @current_bg_pointer_captures = T.let(@current_bg_pointer_captures, T.nilable(T::Set[T.untyped]))
      prev_bg_ptr_caps = @current_bg_pointer_captures
      @current_bg_pointer_captures = pointer_captures
      @pending_stmts = T.let(@pending_stmts, T.nilable(T::Array[T.untyped]))
      prev_fiber_pending = @pending_stmts
      @pending_stmts = []
      block_code = with_fiber_capture_map(capture_map, rt_override: bg_rt) do
        emit_step_stmts(clause[:body] || [], no_result: true)
      end
      @pending_stmts = prev_fiber_pending
      @current_bg_pointer_captures = prev_bg_ptr_caps
      return nil if block_code.nil?
      { body_zig: block_code, exit_kind: :goto_post }
    else
      nil
    end
  end

  # Default error arm body when no clause is present: surface as a
  # generic LockError (body sets inner.result; exit_kind = :done).
  sig { params(id: Integer).returns(T::Hash[Symbol, T.untyped]) }
  def default_fsm_lock_error_arm_split(id)
    T.bind(self, MIRLowering) rescue nil
    {
      body_zig: "__ctx_#{id}.inner.result = error.LockError;",
      exit_kind: :done,
    }
  end
end
