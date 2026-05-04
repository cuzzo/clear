# fsm_transform/suspend_resolvers.rb -- per-suspend-kind resolvers.
#
# Each resolver turns a Segments::*Suspend tail into a uniform
# MIR::SuspendDescriptor that the unified FSM emit consumes without
# branching on suspend kind. New suspend kinds (TCP, channel, etc.)
# add a new entry here -- never a new emit function.
#
# Resolvers are pure data transforms: they take the segment tail +
# loweing context (capture map, ctx_id, bg_rt) and produce MIR. They
# do NOT inspect the dispatch shape (loop / linear / if-branch);
# that's the splitter's responsibility.

require_relative "../mir"

module FsmTransform
  module SuspendResolvers
    module_function

    # Public entry. `seg` is a Segments::Segment whose tail is one of
    # the *Suspend variants. Returns MIR::SuspendDescriptor.
    #
    # `ctx` is a hash with at least: :id (numeric ctx id), :bg_rt
    # (e.g. "__rt_bg0").
    # `lowering` provides .lower(ast_node) and is used inside the
    # caller's capture-map context (set up via with_fiber_capture_map).
    def resolve(seg, ctx, lowering, susp_idx: nil)
      case seg.tail
      when Segments::IoSuspend
        resolve_io(seg.tail, ctx, lowering)
      when Segments::NextSuspend
        resolve_next(seg.tail, ctx, lowering, susp_idx: susp_idx || (seg.index + 1))
      else
        raise ArgumentError,
          "SuspendResolvers: no resolver for #{seg.tail.class}. " \
          "Add a resolve_<kind> branch when introducing a new suspend kind."
      end
    end

    # ---- IO ----------------------------------------------------------------
    #
    # Extract setup / bind / state from the stdlib_def's FSM templates.
    # Produces:
    #   setup_stmts: fsm_setup template lowered via FsmOps::Lowerer
    #   bind_stmts:  fsm_state_finalize + fsm_finish_block + (if any
    #                bound result) MIR::Set against the resumed local
    #                from fsm_finish_value
    #   tail:        FsmTailYield(next, "WaitForLock")
    #   ctx_field_decls: rendered fsm_state_decls
    #   result_var / result_zig_type: from the call's return type +
    #                                   the bound name in the body stmt
    def resolve_io(io_tail, ctx, lowering)
      stdlib_def = io_tail.stdlib_def
      raise ArgumentError, "IoSuspend missing stdlib_def" unless stdlib_def

      id = ctx[:id]
      bg_rt = ctx[:bg_rt]

      setup_ops      = stdlib_def[:fsm_setup] || []
      finish_block   = stdlib_def[:fsm_finish_block] || []
      finish_value   = stdlib_def[:fsm_finish_value]
      state_decls    = stdlib_def[:fsm_state_decls] || []
      state_finalize = stdlib_def[:fsm_state_finalize] || []

      # Lower call args via the surrounding capture-map context.
      arg_mirs = (io_tail.call_node.respond_to?(:args) ?
                    (io_tail.call_node.args || []) : []).map { |a| lowering.lower(a) }

      lowerer = FsmOps::Lowerer.new(ctx_id: id, bg_rt: bg_rt, arg_mirs: arg_mirs)
      setup_mir         = lowerer.lower_stmts(setup_ops)
      state_finalize_m  = lowerer.lower_stmts(state_finalize)
      finish_block_mir  = lowerer.lower_stmts(finish_block)
      finish_value_mir  = finish_value ? lowerer.lower_expr(finish_value) : nil

      bind_stmts = []
      bind_stmts.concat(state_finalize_m)
      bind_stmts.concat(finish_block_mir)
      result_var = io_tail.result_var
      result_zig_type = nil
      if finish_value_mir && result_var && result_var != "_"
        bind_stmts << MIR::Let.new(result_var, finish_value_mir, false, nil, nil)
        ft = io_tail.call_node.respond_to?(:full_type) ? io_tail.call_node.full_type : nil
        result_zig_type = ft ? Type.new(ft).zig_type : nil
      elsif finish_value_mir
        bind_stmts << MIR::ExprStmt.new(finish_value_mir, true)
      end

      ctx_field_decls = state_decls.map(&:render)

      MIR::SuspendDescriptor.new(
        setup_mir,
        bind_stmts,
        MIR::FsmTailYield.new(nil, "WaitForLock"),
        ctx_field_decls,
        result_var,
        result_zig_type,
      )
    end

    # ---- NEXT --------------------------------------------------------------
    #
    # NEXT awaits a Promise(T). The protocol:
    #   setup: ctx.sp_<K> = <promise_expr>
    #   tail:  if (ctx.sp_<K>.inner.wg.registerFsmWaiter(&task))
    #            { step = K+1; return WaitForLock; }
    #          step = K+1; continue;
    #   bind:  if (ctx.sp_<K>.inner.result) |__res_K|
    #            { result_var = __res_K }       -- or _ = __res_K
    #          else |__err_K|
    #            { ctx.sp_<K>.alloc.destroy(ctx.sp_<K>.inner);
    #              ctx.inner.result = __err_K;
    #              ctx.inner.wg.done();
    #              ctx.alloc.destroy(ctx);
    #              return Done; }
    #          ctx.sp_<K>.alloc.destroy(ctx.sp_<K>.inner);
    #
    # The bind block contains a Done-return on error. That's still
    # MIR (a sequence of statements ending in IfStmt/ReturnStmt-shaped
    # actions); the unified emit doesn't need to know it might "exit
    # early" -- the err path returns from runStepK+1 directly via the
    # error union, picked up by the dispatch arm's err handler. So we
    # can simplify: wrap the err path as `return error.<...>` and let
    # the dispatch arm propagate it.
    #
    # The simpler bind:
    #   const __res_K = ctx.sp_<K>.inner.result catch |__err| {
    #      ctx.sp_<K>.alloc.destroy(ctx.sp_<K>.inner);
    #      return __err;
    #   };
    #   ctx.sp_<K>.alloc.destroy(ctx.sp_<K>.inner);
    #   <result_var> = __res_K;   // or _ = __res_K
    #
    # Same semantics, simpler MIR. We carry it as RawZig-equivalent
    # text inside MIR::ExprStmt via MIR::Lit for now -- subsequent
    # work will make this fully MIR-shaped (catch is already a MIR
    # expression form).
    def resolve_next(next_tail, ctx, lowering, susp_idx:)
      id = ctx[:id]
      sp_field = "sp_#{susp_idx}"
      promise_expr_mir = lowering.lower(next_tail.promise_ast)
      ctx_ident = MIR::Ident.new("__ctx_#{id}")

      setup_stmts = [
        MIR::Set.new(MIR::FieldGet.new(ctx_ident, sp_field), promise_expr_mir, false),
      ]

      # `task` is a `*FsmTask` (slab-allocated by allocFsmTask; ctx
      # holds the pointer), so pass directly — no `&` wrapper.
      register_zig =
        "__ctx_#{id}.#{sp_field}.inner.wg.registerFsmWaiter(__ctx_#{id}.task)"
      tail = MIR::FsmTailRegisterYield.new(nil, register_zig, "WaitForLock")

      # Bind block as MIR Lit-wrapped Zig. Migrating to fully MIR
      # IfStmt + ReturnStmt is a small follow-up; the current shape
      # matches what build_next_chain_resume_fn used to inline.
      result_var = next_tail.result_var
      bind_lhs =
        if result_var
          "__ctx_#{id}.#{result_var} = __res_#{susp_idx};"
        else
          "_ = __res_#{susp_idx};"
        end
      bind_zig = <<~ZIG.chomp
        if (__ctx_#{id}.#{sp_field}.inner.result) |__res_#{susp_idx}| {
            #{bind_lhs}
        } else |__err_#{susp_idx}| {
            __ctx_#{id}.#{sp_field}.alloc.destroy(__ctx_#{id}.#{sp_field}.inner);
            return __err_#{susp_idx};
        }
        __ctx_#{id}.#{sp_field}.alloc.destroy(__ctx_#{id}.#{sp_field}.inner);
      ZIG
      bind_stmts = [MIR::RawZig.new(bind_zig, "fsm_next_bind", nil, nil)]

      promise_ft = next_tail.promise_ast.respond_to?(:full_type) ?
                     next_tail.promise_ast.full_type : nil
      sp_zig = promise_ft ? Type.new(promise_ft).zig_type : "anyopaque"
      inner_zig =
        if promise_ft && (pt = Type.new(promise_ft)).respond_to?(:tense_type) && pt.tense_type
          Type.new(pt.tense_type).zig_type
        else
          nil
        end

      ctx_field_decls = ["#{sp_field}: #{sp_zig} = undefined,"]
      if result_var && inner_zig
        ctx_field_decls << "#{result_var}: #{inner_zig} = undefined,"
      end

      MIR::SuspendDescriptor.new(
        setup_stmts,
        bind_stmts,
        tail,
        ctx_field_decls,
        result_var,
        inner_zig,
      )
    end
  end
end
