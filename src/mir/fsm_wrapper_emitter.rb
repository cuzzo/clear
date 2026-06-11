# typed: strict
# fsm_wrapper_emitter.rb -- Renders MIR::FsmIoBody trees to Zig.
#
# The lowering pass (src/mir/fsm_lowering.rb#emit_fsm_io_bg_code) used
# to inline the entire state-machine wrapper as a single Zig heredoc.
# Every structural decision -- where the resumeFn lives, what the
# step-0 catch arm looks like, how ctx is allocated and spawned --
# was buried inside string interpolation, invisible to the MIR
# checker.
#
# Now the lowering builds a tree of MIR::FsmIoBody / FsmCtxStruct /
# FsmStep / FsmDispatch / FsmSpawnSetup nodes. This module walks
# that tree and produces the equivalent Zig. Single dispatch on
# node class. NO decisions: every alloc kind, spawn fn, error-path
# cleanup is already encoded in node fields by the lowering --
# the renderer reads them and concatenates.
#
# The Zig fragments interpolated below (struct/fn keywords, the
# resumeFn switch dispatch, break :label syntax) are the FIXED
# protocol contract for FSM Phase B2-IO bodies. They are not
# decisions; they are the abstraction itself. Adding a third step
# or changing the dispatch shape is a protocol change, not a
# template tweak.
#
# Body content that comes from the surrounding fiber-body lowering
# is carried as MIR nodes and rendered here by MIREmitter. The wrapper
# may emit fixed Zig templates, but it must not accept pre-rendered
# body or field strings from MIR.

require_relative "mir"
require_relative "mir_emitter"
require_relative "fsm_ops"

module FsmWrapperEmitter
  extend T::Sig
  module_function

  # Entry point. Render an MIR::FsmIoBody and return the Zig text.
  # The MIREmitter is the standard Phase-4 transpiler that handles
  # every MIR statement / expression type. Each FsmStep's body_stmts
  # is a list of MIR nodes; we feed each
  # through `mir_emitter.emit` to produce Zig text, then concatenate
  # with indentation. NO renderer-specific knowledge of statement
  # types -- the emitter is the single source of truth.
  sig { params(body: T.untyped).returns(String) }
  def render(body)
    T.bind(self, T.untyped) rescue nil
    case body
    when MIR::FsmIoBody      then render_io_body(body)
    when MIR::FsmB1Body      then render_b1_body(body)
    when MIR::FsmGenericBody then render_generic_body(body)
    else
      raise ArgumentError, "FsmWrapperEmitter expected an FsmBody node, got #{body.class}"
    end
  end

  sig { params(body: T.untyped).returns(String) }
  def render_io_body(body)
    T.bind(self, T.untyped) rescue nil
    mir_emitter = MIREmitter.new
    parts = []
    parts << "#{body.blk_label}: {"
    parts << render_ctx_struct(body.ctx_struct, mir_emitter)
    parts << render_ctx_size_gate(body.ctx_struct.type_name)
    parts << render_spawn_setup(body.spawn_setup, body.blk_label)
    parts << "}"
    parts.join("\n")
  end

  # FSM Phase B1 (pure-compute) wrapper. Single member fn
  # `runBody` (anyerror!void) plus a fixed-shape resumeFn that
  # calls it once, propagates errors into inner.result, and
  # returns Done. No switch / no suspend.
  sig { params(body: T.untyped).returns(String) }
  def render_b1_body(body)
    T.bind(self, T.untyped) rescue nil
    mir_emitter = MIREmitter.new
    parts = []
    parts << "#{body.blk_label}: {"
    parts << render_b1_ctx_struct(body.ctx_struct, mir_emitter)
    parts << render_ctx_size_gate(body.ctx_struct.type_name)
    parts << render_spawn_setup(body.spawn_setup, body.blk_label)
    parts << "}"
    parts.join("\n")
  end

  sig { params(s: T.untyped, mir_emitter: MIREmitter).returns(String) }
  def render_b1_ctx_struct(s, mir_emitter)
    T.bind(self, T.untyped) rescue nil
    parts = []
    parts << "    const #{s.type_name} = struct {"
    parts << "        task: *CheatHeader.FsmTask,"
    parts << "        rt: *Runtime,"
    parts << "        inner: *#{s.promise_zig}.Inner,"
    parts << "        alloc: std.mem.Allocator,"
    capture_fields = render_context_field_decls(s.capture_fields, mir_emitter)
    parts << indent_block(capture_fields, 8) unless empty?(capture_fields)
    parts << ""
    parts << render_run_body(s.run_body, mir_emitter)
    parts << ""
    parts << render_b1_resume_fn(s.run_body.ctx_id)
    parts << ""
    parts << render_destroy_task(s.run_body.ctx_id, [], mir_emitter)
    parts << "    };"
    parts.join("\n")
  end

  sig { params(step: T.untyped, mir_emitter: MIREmitter).returns(String) }
  def render_run_body(step, mir_emitter)
    T.bind(self, T.untyped) rescue nil
    rendered = with_rt_name(mir_emitter, step.bg_rt) do
      render_body_items(step.body_stmts || [], mir_emitter)
    end
    body = rendered.map { |l| indent_block(l, 12) }.join("\n")
    [
      "        fn runBody(__ctx_#{step.ctx_id}: *@This()) anyerror!void {",
      "            const #{step.bg_rt} = __ctx_#{step.ctx_id}.rt;",
      ("            _ = &#{step.bg_rt};" if step.suppress_runtime_ref),
      (body unless body.empty?),
      "        }",
    ].compact.join("\n")
  end

  sig { params(ctx_id: T.untyped).returns(String) }
  def render_b1_resume_fn(ctx_id)
    T.bind(self, T.untyped) rescue nil
    <<~ZIG.chomp.lines.map { |l| "        #{l}" }.join.chomp
      fn resumeFn(__fsm_task: *CheatHeader.FsmTask) CheatHeader.YieldReason {
          const __ctx_#{ctx_id}: *@This() = @ptrCast(@alignCast(__fsm_task.ctx.?));
          if (runBody(__ctx_#{ctx_id})) |_| {} else |err| {
              __ctx_#{ctx_id}.inner.result = err;
          }
          __ctx_#{ctx_id}.inner.wg.done();
          return .{ .Done = {} };
      }
    ZIG
  end

  # Per-ctx-type destroy callback installed on FsmTask.destroy_fn.
  # The scheduler's drainFsmQueue calls this AFTER dispatchOnce
  # writes task.status = .Finished, so the ctx (and the FsmTask
  # embedded in it) lives long enough for the status write before
  # being freed here.
  #
  # destroy_actions are structural cleanup/release operations that run
  # BEFORE freeFsmCtx (e.g. capture cleanup and WITH+suspend-in-CS locks).
  sig { params(ctx_id: Integer, destroy_actions: T::Array[MIR::FsmDestroyAction], mir_emitter: MIREmitter).returns(String) }
  def render_destroy_task(ctx_id, destroy_actions, mir_emitter)
    T.bind(self, T.untyped) rescue nil
    extra_zig = render_destroy_actions(ctx_id, destroy_actions, mir_emitter)
    extra =
      if !empty?(extra_zig)
        extra_zig.lines.map { |l| "    #{l.chomp}" }.join("\n") + "\n"
      else
        ""
      end
    <<~ZIG.chomp.lines.map { |l| "        #{l}" }.join.chomp
      fn destroyTask(__fsm_task: *CheatHeader.FsmTask) void {
          const __ctx_#{ctx_id}: *@This() = @ptrCast(@alignCast(__fsm_task.ctx.?));
      #{extra}    CheatHeader.freeFsmCtx(@This(), __fsm_task, __ctx_#{ctx_id});
      }
    ZIG
  end

  sig { params(type_name: T.untyped).returns(String) }
  def render_ctx_size_gate(type_name)
    T.bind(self, T.untyped) rescue nil
    <<~ZIG.chomp.lines.map { |l| "    #{l}" }.join.chomp
      comptime {
          if (@sizeOf(#{type_name}) > 256) {
              @compileError("FSM context is larger than 256 bytes; use @stack on this BG block to force a compiler-sized stackful fiber.");
          }
      }
    ZIG
  end

  # ----- struct decl with member fns ----------------------------------------

  sig { params(s: T.untyped, mir_emitter: MIREmitter).returns(String) }
  def render_ctx_struct(s, mir_emitter)
    T.bind(self, T.untyped) rescue nil
    parts = []
    parts << "    const #{s.type_name} = struct {"
    parts << "        task: *CheatHeader.FsmTask,"
    parts << "        rt: *Runtime,"
    parts << "        inner: *#{s.promise_zig}.Inner,"
    parts << "        alloc: std.mem.Allocator,"
    capture_fields = render_context_field_decls(s.capture_fields, mir_emitter)
    parts << indent_block(capture_fields, 8) unless empty?(capture_fields)
    parts << "        step: u8 = 0,"
    state_fields = render_fsm_state_field_decls(s.state_decls || [], mir_emitter)
    parts << indent_block(state_fields, 8) unless empty?(state_fields)
    s.promoted_field_decls.each { |line| parts << "        #{line}" }
    parts << ""
    parts << render_step(s.step0, mir_emitter)
    parts << ""
    parts << render_step(s.step1, mir_emitter)
    parts << ""
    parts << indent_block(render_dispatch(s.resume_fn), 8)
    parts << ""
    parts << render_destroy_task(s.resume_fn.ctx_id, [], mir_emitter)
    parts << "    };"
    parts.join("\n")
  end

  # ----- one runStepN function ----------------------------------------------
  #
  # body_stmts is a list of MIR statement nodes. Each is fed through
  # MIREmitter.emit to produce the Zig fragment for that statement.
  # We skip emissions that come back empty / nil so verification-only
  # nodes (AllocMark, ReturnMark, ...) don't leave blank lines.

  sig { params(step: T.untyped, mir_emitter: MIREmitter).returns(String) }
  def render_step(step, mir_emitter)
    T.bind(self, T.untyped) rescue nil
    rendered = with_rt_name(mir_emitter, step.bg_rt) do
      render_body_items(step.body_stmts || [], mir_emitter)
    end
    body = rendered.map { |l| indent_block(l, 12) }.join("\n")

    [
      "        fn runStep#{step.index}(__ctx_#{step.ctx_id}: *@This()) anyerror!void {",
      "            const #{step.bg_rt} = __ctx_#{step.ctx_id}.rt;",
      ("            _ = &#{step.bg_rt};" if step.suppress_runtime_ref),
      (body unless body.empty?),
      "        }",
    ].compact.join("\n")
  end

  # Render an err-cleanup list (per-arm direct cleanups in the err
  # handler, typically capture frees in the B2-IO step-0 catch).
  # Each entry is an MIR statement (typically MIR::ExprStmt(MIR::
  # MethodCall(...))); we route each through a fresh MIREmitter
  # so the same Phase-4 path renders these as renders the arm
  # bodies.
  sig { params(cleanups: T.nilable(T::Array[MIR::Emittable])).returns(String) }
  def render_resume_fn_cleanups(cleanups)
    T.bind(self, T.untyped) rescue nil
    return "" if cleanups.nil?
    return "" if cleanups.empty?
    emitter = MIREmitter.new
    cleanups.filter_map { |stmt|
      out = emitter.emit(stmt)
      next nil if out.nil? || out.strip.empty?
      out
    }.join("\n")
  end

  # ----- generic body (LOOP / WITH / NEXT-CHAIN) ---------------------------

  sig { params(body: T.untyped).returns(String) }
  def render_generic_body(body)
    T.bind(self, T.untyped) rescue nil
    mir_emitter = MIREmitter.new
    parts = []
    parts << "#{body.blk_label}: {"
    parts << render_generic_ctx_struct(body.ctx_struct, mir_emitter)
    parts << render_ctx_size_gate(body.ctx_struct.type_name)
    parts << render_spawn_setup(body.spawn_setup, body.blk_label)
    parts << "}"
    parts.join("\n")
  end

  sig { params(s: MIR::FsmGenericCtxStruct, mir_emitter: MIREmitter).returns(String) }
  def render_generic_ctx_struct(s, mir_emitter)
    T.bind(self, T.untyped) rescue nil
    parts = []
    parts << "    const #{s.type_name} = struct {"
    parts << "        task: *CheatHeader.FsmTask,"
    parts << "        rt: *Runtime,"
    parts << "        inner: *#{s.promise_zig}.Inner,"
    parts << "        alloc: std.mem.Allocator,"
    capture_fields = render_context_field_decls(s.capture_fields, mir_emitter)
    parts << indent_block(capture_fields, 8) unless empty?(capture_fields)
    extra_fields = render_context_field_decls(s.extra_field_decls || [], mir_emitter)
    parts << indent_block(extra_fields, 8) unless empty?(extra_fields)
    promoted_fields = render_context_field_decls(s.promoted_field_decls || [], mir_emitter)
    parts << indent_block(promoted_fields, 8) unless empty?(promoted_fields)
    parts << ""
    (s.member_fns || []).each do |fn|
      parts << render_member_fn(fn, mir_emitter)
      parts << ""
    end
    unless s.dispatch.is_a?(MIR::FsmDispatch)
      raise ArgumentError, "generic FSM ctx requires MIR::FsmDispatch"
    end
    parts << indent_block(render_dispatch(s.dispatch), 8)
    parts << ""
    parts << render_destroy_task(s.dispatch.ctx_id, s.destroy_actions || [], mir_emitter)
    parts << "    };"
    parts.join("\n")
  end

  # ---- structured dispatch (FsmDispatch) ---------------------------
  #
  # Renders a `fn resumeFn(...)` whose body is a switch on
  # __ctx_<id>.step, optionally wrapped in `__sw: while (true)` for
  # shapes that use Jump / CondJump / RegisterYield tails (any of
  # which can transition to another arm without re-entering
  # resumeFn). The output matches what the legacy build_*_resume_fn
  # helpers used to construct as raw Zig strings -- byte-for-byte
  # equivalent for shapes that have been migrated to FsmDispatch.
  sig { params(d: T.untyped).returns(String) }
  def render_dispatch(d)
    T.bind(self, T.untyped) rescue nil
    arms_zig = d.arms.map { |arm| render_dispatch_arm(arm, d.ctx_id) }.join("\n")
    needs_loop_label = d.arms.any? { |a| arm_uses_continue?(a) }

    inner =
      if needs_loop_label
        [
          "__sw: while (true) {",
          "    switch (__ctx_#{d.ctx_id}.step) {",
          arms_zig,
          "        else => unreachable,",
          "    }",
          "}",
        ].join("\n")
      else
        [
          "switch (__ctx_#{d.ctx_id}.step) {",
          arms_zig,
          "    else => unreachable,",
          "}",
        ].join("\n")
      end

    [
      "fn resumeFn(__fsm_task: *CheatHeader.FsmTask) CheatHeader.YieldReason {",
      "    const __ctx_#{d.ctx_id}: *@This() = @ptrCast(@alignCast(__fsm_task.ctx.?));",
      indent_block(inner, 4),
      "}",
    ].join("\n")
  end

  sig { params(arm: T.untyped, ctx_id: T.untyped).returns(String) }
  def render_dispatch_arm(arm, ctx_id)
    T.bind(self, T.untyped) rescue nil
    body_lines = []
    if arm.pre_body_skip
      body_lines << "if (#{render_fsm_expr(arm.pre_body_skip.condition)}) {"
      body_lines << "    __ctx_#{ctx_id}.step = #{arm.pre_body_skip.skip_step};"
      body_lines << "    continue :__sw;"
      body_lines << "}"
    end
    pre_body = render_stmt_array(arm.pre_body_stmts || [], "rt")
    body_lines << pre_body unless pre_body.empty?
    if arm.body_fn_name
      tail_kind = arm.tail.respond_to?(:kind) ? arm.tail.kind : nil
      arm_cleanups = render_resume_fn_cleanups(arm.err_cleanups)
      err_action =
        if tail_kind == :done && empty?(arm_cleanups)
          # Final arm with no per-arm err cleanups: legacy form
          # swallows err to inner.result without destroy/Done early
          # -- the tail's Done emit handles destroy.
          [
            "if (@This().#{arm.body_fn_name}(__ctx_#{ctx_id})) |_| {} else |err| {",
            "    __ctx_#{ctx_id}.inner.result = err;",
            "}",
          ]
        else
          # Standard form: per-arm cleanups (if any) followed by
          # store-err / wg.done / Done. The destroy is handled by
          # the scheduler via FsmTask.destroy_fn AFTER dispatchOnce
          # has finished writing task.status -- closes the prior
          # use-after-free where dispatchOnce read task.status from
          # ctx that resumeFn had just freed.
          inner = []
          inner << indent_block(arm_cleanups, 4) unless empty?(arm_cleanups)
          inner << "    __ctx_#{ctx_id}.inner.result = err;"
          inner << "    __ctx_#{ctx_id}.inner.wg.done();"
          inner << "    return .{ .Done = {} };"
          ["if (@This().#{arm.body_fn_name}(__ctx_#{ctx_id})) |_| {} else |err| {"] +
            inner + ["}"]
        end
      body_lines.concat(err_action)
    end
    body_lines << render_tail(arm.tail, ctx_id)
    body = body_lines.compact.reject(&:empty?).join("\n")

    [
      "    #{arm.index} => {",
      indent_block(body, 8),
      "    },",
    ].join("\n")
  end

  # Does this arm emit a `continue :__sw` (in tail or pre_body_skip)?
  # Determines whether the dispatch needs a `__sw:` labeled loop.
  sig { params(arm: T.untyped).returns(T::Boolean) }
  def arm_uses_continue?(arm)
    T.bind(self, T.untyped) rescue nil
    return true if arm.pre_body_skip
    case arm.tail
    when MIR::FsmTailJump, MIR::FsmTailRegisterYield, MIR::FsmTailCondJump,
         MIR::FsmTailLockTry, MIR::FsmTailWokenCheck, MIR::FsmTailRetryOrError
      true
    else
      false
    end
  end

  sig { params(t: T.untyped, ctx_id: T.untyped).returns(String) }
  def render_tail(t, ctx_id)
    T.bind(self, T.untyped) rescue nil
    case t
    when MIR::FsmTailDone
      # destroy(ctx) is handled by the scheduler via
      # FsmTask.destroy_fn AFTER dispatchOnce finishes writing
      # task.status; the resume fn must NOT free ctx here, or the
      # scheduler reads task.status from freed memory.
      [
        "__ctx_#{ctx_id}.inner.wg.done();",
        "return .{ .Done = {} };",
      ].join("\n")
    when MIR::FsmTailYield
      [
        "__ctx_#{ctx_id}.step = #{t.next_step};",
        "return .{ .#{t.yield_reason} = {} };",
      ].join("\n")
    when MIR::FsmTailRegisterYield
      [
        "if (#{render_fsm_expr(t.register_expr)}) {",
        "    __ctx_#{ctx_id}.step = #{t.next_step};",
        "    return .{ .#{t.yield_reason} = {} };",
        "}",
        "__ctx_#{ctx_id}.step = #{t.next_step};",
        "continue :__sw;",
      ].join("\n")
    when MIR::FsmTailJump
      [
        "__ctx_#{ctx_id}.step = #{t.next_step};",
        "continue :__sw;",
      ].join("\n")
    when MIR::FsmTailCondJump
      [
        "if (#{render_fsm_expr(t.condition)}) {",
        "    __ctx_#{ctx_id}.step = #{t.then_step};",
        "    continue :__sw;",
        "}",
        "__ctx_#{ctx_id}.step = #{t.else_step};",
        "continue :__sw;",
      ].join("\n")
    when MIR::FsmTailLockTry
      [
        "const __lock_r = #{t.lock_field_ref}.#{t.try_method}(",
        "    __ctx_#{ctx_id}.task,",
        "    &__ctx_#{ctx_id}.lock_waiter,",
        "    __ctx_#{ctx_id}.rt.getSched(),",
        ");",
        "switch (__lock_r) {",
        "    .Acquired => {",
        "        __ctx_#{ctx_id}.step = #{t.ok_step};",
        "        continue :__sw;",
        "    },",
        "    .Registered => {",
        "        __ctx_#{ctx_id}.step = #{t.wait_step};",
        "        return .{ .WaitForLock = {} };",
        "    },",
        "    .Error => {",
        "        __ctx_#{ctx_id}.step = #{t.error_step};",
        "        continue :__sw;",
        "    },",
        "}",
      ].join("\n")
    when MIR::FsmTailWokenCheck
      [
        "const __lerr = __ctx_#{ctx_id}.task.lock_error;",
        "__ctx_#{ctx_id}.task.lock_error = .None;",
        "if (__lerr == .None) {",
        "    __ctx_#{ctx_id}.step = #{t.ok_step};",
        "    continue :__sw;",
        "}",
        "__ctx_#{ctx_id}.step = #{t.error_step};",
        "continue :__sw;",
      ].join("\n")
    when MIR::FsmTailRetryOrError
      if t.retries > 0
        [
          "if (__ctx_#{ctx_id}.retry_count < #{t.retries}) {",
          "    __ctx_#{ctx_id}.retry_count += 1;",
          "    __ctx_#{ctx_id}.step = #{t.retry_step};",
          "    continue :__sw;",
          "}",
          "__ctx_#{ctx_id}.step = #{t.fail_step};",
          "continue :__sw;",
        ].join("\n")
      else
        [
          "__ctx_#{ctx_id}.step = #{t.fail_step};",
          "continue :__sw;",
        ].join("\n")
      end
    else
      raise ArgumentError, "render_tail: unknown tail #{t.class}"
    end
  end

  sig { params(fn: T.untyped, mir_emitter: MIREmitter).returns(String) }
  def render_member_fn(fn, mir_emitter)
    T.bind(self, T.untyped) rescue nil
    rendered = with_rt_name(mir_emitter, fn.bg_rt) do
      render_body_items(fn.body_stmts || [], mir_emitter)
    end
    body = rendered.map { |l| indent_block(l, 12) }.join("\n")
    extra_prologue = with_rt_name(mir_emitter, fn.bg_rt) do
      render_stmt_array(fn.extra_prologue_stmts || [], fn.bg_rt)
    end

    [
      "        fn #{fn.fn_name}(__ctx_#{fn.ctx_id}: *@This()) anyerror!void {",
      "            const #{fn.bg_rt} = __ctx_#{fn.ctx_id}.rt;",
      ("            _ = &#{fn.bg_rt};" if fn.suppress_runtime_ref),
      (indent_block(extra_prologue, 12) unless extra_prologue.empty?),
      (body unless body.empty?),
      "        }",
    ].compact.join("\n")
  end

  # ----- post-struct alloc + spawn + break ----------------------------------

  sig { params(s: MIR::FsmSpawnSetup, blk_label: T.untyped).returns(String) }
  def render_spawn_setup(s, blk_label)
    T.bind(self, T.untyped) rescue nil
    mir_emitter = MIREmitter.new
    parts = []
    parts << "    #{mir_emitter.emit_profile_task_site(s.profile_site)}" if s.respond_to?(:profile_site) && s.profile_site
    alloc_expr = mir_emitter.emit(s.alloc_expr)
    parts << "    const #{s.alloc_var} = #{alloc_expr};"
    parts << "    const #{s.promise_var} = try #{s.promise_zig}.spawn(#{s.alloc_var}, #{s.rt_name}.getSched());"
    promoted_decls = (s.promoted_decls || []).filter_map do |stmt|
      out = mir_emitter.emit(stmt)
      next nil if out.nil? || out.strip.empty?

      out
    end.join("\n")
    parts << indent_block(promoted_decls, 4) unless empty?(promoted_decls)
    # Allocate the FsmTask from the scheduler's fsm_task_slab so
    # detectCycleFsm can pin it during chain walks (mirrors stackful
    # Task slab + Option-(C) protocol). The task's `ctx` field is the
    # forward pointer used by resumeFn / destroyTask to recover *Ctx.
    parts << "    const #{s.ctx_var}_task = try CheatHeader.allocFsmTask(#{s.rt_name}, &#{s.ctx_type}.resumeFn);"
    parts << "    errdefer #{s.rt_name}.getSched().fsm_task_slab.destroy(#{s.ctx_var}_task);"
    parts << "    const #{s.ctx_var} = try CheatHeader.allocFsmCtx(#{s.ctx_type}, #{s.rt_name}, #{s.ctx_var}_task);"
    parts << "    errdefer CheatHeader.freeFsmCtx(#{s.ctx_type}, #{s.ctx_var}_task, #{s.ctx_var});"
    parts << "    #{s.ctx_var}_task.ctx = #{s.ctx_var};"
    # Wire the destroy callback so the scheduler frees ctx after
    # dispatchOnce finishes writing task.status (the resume fn no
    # longer destroys ctx inline -- closes a UAF window). The
    # scheduler returns the FsmTask slot to fsm_task_slab AFTER
    # destroy_fn runs.
    parts << "    #{s.ctx_var}_task.destroy_fn = &#{s.ctx_type}.destroyTask;"
    if s.respond_to?(:profile_site_id) && s.profile_site_id
      parts << "    #{s.ctx_var}_task.profile_site_id = #{s.profile_site_id};"
      parts << "    #{s.ctx_var}_task.profile_dispatch = #{s.profile_dispatch_id};"
    end
    parts << "    #{s.ctx_var}.* = .{"
    parts << indent_block(render_struct_init_fields(s.ctx_init_fields, mir_emitter), 8)
    parts << "    };"
    parts << "    #{s.ctx_var}.task = #{s.ctx_var}_task;"
    # Allocate a per-task Runtime shell. EBR is resolved at dispatch time
    # through Runtime.currentEbr(), so FSMs running on worker schedulers use
    # the active scheduler thread's registered EBR slot instead of the
    # spawning runtime's fallback slot.
    parts << "    #{s.ctx_var}.rt = try CheatHeader.allocFsmTaskRuntime(#{s.ctx_var}_task, #{s.rt_name});"
    parts << "    #{render_fsm_spawn_call(s.spawn_call)}"
    parts << "    break :#{blk_label} #{s.promise_var};"
    parts.join("\n")
  end

  # ----- helpers ------------------------------------------------------------

  sig { params(s: T.untyped).returns(T::Boolean) }
  def empty?(s)
    T.bind(self, T.untyped) rescue nil
    s.nil? || s.strip.empty?
  end

  sig { params(stmts: T::Array[MIR::Node], rt_name: String).returns(String) }
  def render_stmt_array(stmts, rt_name)
    return "" if stmts.empty?

    emitter = MIREmitter.new
    with_rt_name(emitter, rt_name) do
      render_body_items(stmts, emitter).join("\n")
    end.to_s
  end

  sig { params(stmts: T::Array[MIR::Emittable], mir_emitter: MIREmitter).returns(T::Array[String]) }
  def render_body_items(stmts, mir_emitter)
    stmts.filter_map do |stmt|
      unless stmt.is_a?(MIR::Emittable)
        Kernel.raise ArgumentError, "FSM body item must be structural MIR, got #{stmt.class}"
      end

      out = mir_emitter.emit(stmt)
      next nil if out.nil? || out.strip.empty?

      out
    end
  end

  sig { params(expr: MIR::Emittable).returns(String) }
  def render_fsm_expr(expr)
    out = MIREmitter.new.emit(expr)
    Kernel.raise ArgumentError, "FSM expression rendered empty" if out.nil? || out.strip.empty?

    out
  end

  sig { params(fields: T::Array[MIR::ContextFieldDecl], mir_emitter: MIREmitter).returns(String) }
  def render_context_field_decls(fields, mir_emitter)
    fields.map do |field|
      default = field.default_value ? " = #{mir_emitter.emit(T.must(field.default_value))}" : ""
      "#{field.name}: #{field.type_zig}#{default},"
    end.join("\n")
  end

  sig { params(fields: T::Array[FsmOps::StateFieldDecl], mir_emitter: MIREmitter).returns(String) }
  def render_fsm_state_field_decls(fields, mir_emitter)
    fields.map do |field|
      default = mir_emitter.emit(field.default_value)
      "#{field.name}: #{field.zig_type} = #{default},"
    end.join("\n")
  end

  sig { params(fields: T::Array[MIR::StructInitField], mir_emitter: MIREmitter).returns(String) }
  def render_struct_init_fields(fields, mir_emitter)
    fields.map do |field|
      ".#{field.name} = #{mir_emitter.emit(field.value)},"
    end.join("\n")
  end

  sig { params(call: MIR::FsmSpawnCall).returns(String) }
  def render_fsm_spawn_call(call)
    case call.target
    when :runtime_submit
      runtime_name = call.runtime_name || Kernel.raise("FsmSpawnCall runtime_name required")
      "try #{runtime_name}.getSched().submitFsmSpawn(#{call.ctx_var}.task);"
    when :best
      "try CheatHeader.spawnFsmBest(#{call.ctx_var}.task);"
    else
      Kernel.raise "unknown FsmSpawnCall target #{call.target.inspect}"
    end
  end

  sig { params(ctx_id: Integer, destroy_actions: T::Array[MIR::FsmDestroyAction], mir_emitter: MIREmitter).returns(String) }
  def render_destroy_actions(ctx_id, destroy_actions, mir_emitter)
    return "" if destroy_actions.empty?

    T.cast(with_rt_name(mir_emitter, "__ctx_#{ctx_id}.rt") do
      destroy_actions.map do |action|
        case action
        when MIR::FsmDestroyCleanup
          render_destroy_cleanup_action(action, mir_emitter)
        when MIR::FsmDestroyStmt
          render_destroy_stmt_action(action, mir_emitter)
        when MIR::FsmDestroyLockRelease
          render_destroy_lock_action(ctx_id, action, mir_emitter)
        end
      end.compact.join("\n")
    end, String)
  end

  sig { params(action: MIR::FsmDestroyCleanup, mir_emitter: MIREmitter).returns(String) }
  def render_destroy_cleanup_action(action, mir_emitter)
    allocator = action.allocator ? mir_emitter.emit(T.must(action.allocator)) : nil
    cleanup = mir_emitter.emit_direct_cleanup(
      T.must(mir_emitter.emit(action.target)),
      action.cleanup_entry,
      alloc_override: allocator,
    )
    guard = action.guard ? mir_emitter.emit(T.must(action.guard)) : nil
    return cleanup if guard.nil? || guard.strip.empty?

    if cleanup.include?("\n")
      "if (#{guard}) {\n#{indent_block(cleanup, 4)}\n}"
    else
      "if (#{guard}) #{cleanup}"
    end
  end

  sig { params(action: MIR::FsmDestroyStmt, mir_emitter: MIREmitter).returns(String) }
  def render_destroy_stmt_action(action, mir_emitter)
    stmt = T.must(mir_emitter.emit(action.stmt)).strip
    stmt.end_with?(";", "}") ? stmt : "#{stmt};"
  end

  sig { params(ctx_id: Integer, action: MIR::FsmDestroyLockRelease, mir_emitter: MIREmitter).returns(String) }
  def render_destroy_lock_action(ctx_id, action, mir_emitter)
    "if (__ctx_#{ctx_id}.#{action.guard_field}) #{mir_emitter.emit(action.lock_ref)}.#{action.unlock_method}();"
  end

  sig { params(mir_emitter: MIREmitter, rt_name: String, blk: T.proc.returns(Object)).returns(Object) }
  def with_rt_name(mir_emitter, rt_name, &blk)
    previous = T.let("rt", String)
    previous = mir_emitter.rt_name
    mir_emitter.rt_name = rt_name
    blk.call
  ensure
    mir_emitter.rt_name = T.must(previous)
  end

  # Re-indent every line of `text` by `n` spaces. Preserves blank
  # lines as truly blank (no trailing whitespace) so the rendered
  # Zig stays readable when diff'd.
  sig { params(text: T.untyped, n: Integer).returns(String) }
  def indent_block(text, n)
    T.bind(self, T.untyped) rescue nil
    return "" if empty?(text)
    pad = " " * n
    text.to_s.lines.map { |l|
      stripped = l.chomp("\n")
      stripped.strip.empty? ? "" : pad + stripped
    }.join("\n")
  end
  private :arm_uses_continue?
  private :empty?
  private :indent_block
  private :render_b1_body
  private :render_b1_ctx_struct
  private :render_b1_resume_fn
  private :render_body_items
  private :render_ctx_struct
  private :render_destroy_actions
  private :render_destroy_cleanup_action
  private :render_destroy_lock_action
  private :render_destroy_stmt_action
  private :render_destroy_task
  private :render_dispatch
  private :render_dispatch_arm
  private :render_fsm_spawn_call
  private :render_fsm_state_field_decls
  private :render_generic_body
  private :render_generic_ctx_struct
  private :render_io_body
  private :render_member_fn
  private :render_resume_fn_cleanups
  private :render_run_body
  private :render_spawn_setup
  private :render_step
  private :render_struct_init_fields
  private :render_tail
  private_class_method :arm_uses_continue?
  private_class_method :empty?
  private_class_method :indent_block
  private_class_method :render_b1_body
  private_class_method :render_b1_ctx_struct
  private_class_method :render_b1_resume_fn
  private_class_method :render_body_items
  private_class_method :render_ctx_struct
  private_class_method :render_destroy_actions
  private_class_method :render_destroy_cleanup_action
  private_class_method :render_destroy_lock_action
  private_class_method :render_destroy_stmt_action
  private_class_method :render_destroy_task
  private_class_method :render_dispatch
  private_class_method :render_dispatch_arm
  private_class_method :render_fsm_spawn_call
  private_class_method :render_fsm_state_field_decls
  private_class_method :render_generic_body
  private_class_method :render_generic_ctx_struct
  private_class_method :render_io_body
  private_class_method :render_member_fn
  private_class_method :render_resume_fn_cleanups
  private_class_method :render_run_body
  private_class_method :render_spawn_setup
  private_class_method :render_step
  private_class_method :render_struct_init_fields
  private_class_method :render_tail

end
