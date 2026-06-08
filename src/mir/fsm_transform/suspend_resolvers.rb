# typed: strict
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
require_relative "context"

module FsmTransform
  module SuspendResolvers
    extend T::Sig
    module_function

    # Public entry. `seg` is a Segments::Segment whose tail is one of
    # the *Suspend variants. Returns MIR::SuspendDescriptor.
    #
    # `ctx` carries the typed FSM emit context, including id and bg runtime.
    # `lowering` provides .lower(ast_node) and is used inside the
    # caller's capture-map context (set up via with_fiber_capture_map).
    sig { params(seg: T.untyped, ctx: Emit::FsmEmitContext, lowering: T.untyped, susp_idx: T.nilable(Integer)).returns(MIR::SuspendDescriptor) }
    def resolve(seg, ctx, lowering, susp_idx: nil)
      T.bind(self, T.untyped) rescue nil
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
    #   ctx_field_decls: typed FSM ctx field declarations
    #   result_var / result_zig_type: from the call's return type +
    #                                   the bound name in the body stmt
    sig { params(io_tail: T.untyped, ctx: Emit::FsmEmitContext, lowering: T.untyped).returns(MIR::SuspendDescriptor) }
    def resolve_io(io_tail, ctx, lowering)
      T.bind(self, T.untyped) rescue nil
      stdlib_def = io_tail.stdlib_def
      raise ArgumentError, "IoSuspend missing stdlib_def" unless stdlib_def

      id = ctx.id
      bg_rt = ctx.bg_rt

      em             = stdlib_def.emit
      setup_ops      = em&.fsm_setup || []
      finish_block   = em&.fsm_finish_block || []
      finish_value   = em&.fsm_finish_value
      state_decls    = em&.fsm_state_decls || []
      state_finalize = em&.fsm_state_finalize || []

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
      result_needs_cleanup = false
      ctx_field_decls = state_decls.map { |decl| state_field_decl(decl) }
      if finish_value_mir && result_var && result_var != "_"
        ft = Type.from_node!(io_tail.call_node, context: "FSM IO tail result")
        result_zig_type = ft ? Type.new(ft).zig_type : nil
        raise ArgumentError, "FSM IO result #{result_var} missing Zig type" unless result_zig_type

        ctx_ident = MIR::Ident.new("__ctx_#{id}")
        ctx_field_decls << ctx_field_decl(result_var, result_zig_type, MIR::Undef.new(nil))
        bind_stmts << MIR::Set.new(
          MIR::FieldGet.new(ctx_ident, result_var),
          finish_value_mir,
          false,
        )
        result_needs_cleanup = ownership_bearing_result_type?(ft, lowering)
      elsif finish_value_mir
        bind_stmts << MIR::ExprStmt.new(finish_value_mir, true)
      end

      if result_var && result_zig_type && result_needs_cleanup
        ctx_ident = MIR::Ident.new("__ctx_#{id}")
        ctx_field_decls << fsm_owned_guard_decl(result_var)
        bind_stmts << MIR::Set.new(
          MIR::FieldGet.new(ctx_ident, fsm_owned_guard_name(result_var)),
          MIR::Lit.new("true"),
          false,
        )
      end

      MIR::SuspendDescriptor.new(
        setup_mir,
        bind_stmts,
        MIR::FsmTailYield.new(nil, "WaitForLock"),
        ctx_field_decls,
        result_var,
        result_zig_type,
        result_needs_cleanup,
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
    # The bind path is structural MIR around Promise.finishFsmNext().
    # The dispatch arm already registered/yielded or observed count==0,
    # so finishFsmNext consumes the settled result and destroys Inner
    # without blocking the scheduler thread.
    sig { params(next_tail: T.untyped, ctx: Emit::FsmEmitContext, lowering: T.untyped, susp_idx: Integer).returns(MIR::SuspendDescriptor) }
    def resolve_next(next_tail, ctx, lowering, susp_idx:)
      T.bind(self, T.untyped) rescue nil
      id = ctx.id
      sp_field = "sp_#{susp_idx}"
      promise_expr_mir = lowering.lower(next_tail.promise_ast)
      ctx_ident = MIR::Ident.new("__ctx_#{id}")

      setup_stmts = [
        MIR::Set.new(MIR::FieldGet.new(ctx_ident, sp_field), promise_expr_mir, false),
      ]
      captured_promise_guard_name = T.let(nil, T.nilable(String))
      captured_names = ctx.captured.keys.map(&:to_s)
      promise_root = AST.root_identifier(next_tail.promise_ast) rescue nil
      if promise_root && captured_names.include?(promise_root.name.to_s)
        captured_promise_guard_name = "#{promise_root.name}_moved"
        setup_stmts << MIR::Set.new(
          MIR::FieldGet.new(ctx_ident, captured_promise_guard_name),
          MIR::Lit.new("true"),
          false,
        )
      end

      # `task` is a `*FsmTask` (slab-allocated by allocFsmTask; ctx
      # holds the pointer), so pass directly — no `&` wrapper.
      register_expr = MIR::MethodCall.new(
        MIR::FieldGet.new(
          MIR::FieldGet.new(
            MIR::FieldGet.new(ctx_ident, sp_field),
            "inner",
          ),
          "wg",
        ),
        "registerFsmWaiter",
        [MIR::FieldGet.new(ctx_ident, "task")],
        false,
      )
      tail = MIR::FsmTailRegisterYield.new(nil, register_expr, "WaitForLock")

      result_var = next_tail.result_var
      promise_ft = Type.from_node!(next_tail.promise_ast, context: "FSM NEXT tail promise")
      sp_zig = Type.new(promise_ft).zig_type
      inner_type_info = T.let(nil, T.nilable(Type))
      promise_type = Type.new(promise_ft)
      inner_zig =
        if promise_type.future? && promise_type.tense_type
          inner_type_info = Type.new(promise_type.tense_type)
          inner_type_info.zig_type
        else
          nil
        end
      result_needs_cleanup = ownership_bearing_result_type?(inner_type_info, lowering)

      finish_call = MIR::MethodCall.new(
        MIR::FieldGet.new(ctx_ident, sp_field),
        "finishFsmNext",
        [],
        false,
      )
      err_name = "__err_#{susp_idx}"
      finish_expr = MIR::TryCatch.new(
        finish_call,
        MIR::ScopeBlock.new([MIR::ReturnStmt.new(MIR::Ident.new(err_name))]),
        err_name,
      )
      finish_expr.result_type = inner_type_info if inner_type_info
      bind_stmts =
        if result_var
          res_name = "__res_#{susp_idx}"
          stmts = [
            MIR::Let.new(res_name, finish_expr, false, Type.new(inner_zig), nil),
            MIR::Set.new(MIR::FieldGet.new(ctx_ident, result_var), MIR::Ident.new(res_name), false),
          ]
          if result_needs_cleanup
            stmts << MIR::Set.new(
              MIR::FieldGet.new(ctx_ident, fsm_owned_guard_name(result_var)),
              MIR::Lit.new("true"),
              false,
            )
          end
          stmts
        else
          [MIR::ExprStmt.new(finish_expr, true)]
        end

      ctx_field_decls = [ctx_field_decl(sp_field, sp_zig, MIR::Undef.new(nil))]
      if captured_promise_guard_name
        ctx_field_decls << ctx_field_decl(captured_promise_guard_name, "bool", MIR::Lit.new("false"))
      end
      if result_var && inner_zig
        ctx_field_decls << ctx_field_decl(result_var, inner_zig, MIR::Undef.new(nil))
        ctx_field_decls << fsm_owned_guard_decl(result_var) if result_needs_cleanup
      end

      MIR::SuspendDescriptor.new(
        setup_stmts,
        bind_stmts,
        tail,
        ctx_field_decls,
        result_var,
        inner_zig,
        result_needs_cleanup,
      )
    end

    sig { params(name: String).returns(String) }
    def fsm_owned_guard_name(name)
      "__owned_#{name}_init"
    end

    sig { params(name: String).returns(MIR::ContextFieldDecl) }
    def fsm_owned_guard_decl(name)
      ctx_field_decl(fsm_owned_guard_name(name), "bool", MIR::Lit.new("false"))
    end

    sig { params(name: String, type_zig: String, default_value: T.nilable(MIR::Emittable)).returns(MIR::ContextFieldDecl) }
    def ctx_field_decl(name, type_zig, default_value)
      MIR::ContextFieldDecl.new(name: name, type_zig: type_zig, default_value: default_value)
    end

    sig { params(decl: T.untyped).returns(MIR::ContextFieldDecl) }
    def state_field_decl(decl)
      init = decl.respond_to?(:init_zig) ? decl.init_zig.to_s : "undefined"
      ctx_field_decl(
        decl.name.to_s,
        decl.zig_type.to_s,
        init == "undefined" ? MIR::Undef.new(nil) : MIR::Lit.new(init),
      )
    end

    sig { params(type_info: T.nilable(Type), lowering: T.untyped).returns(T::Boolean) }
    def ownership_bearing_result_type?(type_info, lowering)
      return false unless type_info
      schema_lookup = lowering.respond_to?(:mir_schema_lookup) ? lowering.mir_schema_lookup : nil
      type_info.string? || type_info.heap_ptr? || type_info.collection_value? ||
        type_info.recursive_cleanup_shape?(schema_lookup)
    rescue StandardError
      false
    end
  end
end
