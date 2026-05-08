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
# (pre_stmts, post_stmts, post_result_line, ...) is still rendered
# Zig text at this layer -- it lands in FsmStep.body_lines as
# pre-joined strings. Migrating those to MIR is a Phase-4
# transpiler concern; the wrapper itself is now structural.

require_relative "mir"
require_relative "mir_emitter"

module FsmWrapperEmitter
  module_function

  # Entry point. Render an MIR::FsmIoBody and return the Zig text.
  # The MIREmitter is the standard Phase-4 transpiler that handles
  # every MIR statement / expression type. Each FsmStep's body_stmts
  # is a list of MIR nodes (or transitional Strings); we feed each
  # through `mir_emitter.emit` to produce Zig text, then concatenate
  # with indentation. NO renderer-specific knowledge of statement
  # types -- the emitter is the single source of truth.
  def render(body)
    case body
    when MIR::FsmIoBody      then render_io_body(body)
    when MIR::FsmB1Body      then render_b1_body(body)
    when MIR::FsmGenericBody then render_generic_body(body)
    else
      raise ArgumentError, "FsmWrapperEmitter expected an FsmBody node, got #{body.class}"
    end
  end

  def render_io_body(body)
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
  def render_b1_body(body)
    mir_emitter = MIREmitter.new
    parts = []
    parts << "#{body.blk_label}: {"
    parts << render_b1_ctx_struct(body.ctx_struct, mir_emitter)
    parts << render_ctx_size_gate(body.ctx_struct.type_name)
    parts << render_spawn_setup(body.spawn_setup, body.blk_label)
    parts << "}"
    parts.join("\n")
  end

  def render_b1_ctx_struct(s, mir_emitter)
    parts = []
    parts << "    const #{s.type_name} = struct {"
    parts << "        task: *CheatHeader.FsmTask,"
    parts << "        rt: *Runtime,"
    parts << "        inner: *#{s.promise_zig}.Inner,"
    parts << "        alloc: std.mem.Allocator,"
    parts << "        #{s.captures_decl_zig}" unless empty?(s.captures_decl_zig)
    parts << ""
    parts << render_run_body(s.run_body, mir_emitter)
    parts << ""
    parts << render_b1_resume_fn(s.run_body.ctx_id)
    parts << ""
    parts << render_destroy_task(s.run_body.ctx_id)
    parts << "    };"
    parts.join("\n")
  end

  def render_run_body(step, mir_emitter)
    rendered = (step.body_stmts || []).filter_map do |stmt|
      out = mir_emitter.emit(stmt)
      next nil if out.nil? || out.strip.empty?
      out
    end
    body = rendered.map { |l| indent_block(l, 12) }.join("\n")
    [
      "        fn runBody(__ctx_#{step.ctx_id}: *@This()) anyerror!void {",
      "            const #{step.bg_rt} = __ctx_#{step.ctx_id}.rt;",
      ("            #{step.rt_suppress_zig}" unless empty?(step.rt_suppress_zig)),
      (body unless body.empty?),
      "        }",
    ].compact.join("\n")
  end

  def render_b1_resume_fn(ctx_id)
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
  # extra_zig is optional cleanup that runs BEFORE freeFsmCtx
  # (e.g. WITH+suspend-in-CS releases any locks still held on the
  # err path).
  def render_destroy_task(ctx_id, extra_zig = nil)
    extra =
      if extra_zig && !empty?(extra_zig)
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

  def render_ctx_size_gate(type_name)
    <<~ZIG.chomp.lines.map { |l| "    #{l}" }.join.chomp
      comptime {
          if (@sizeOf(#{type_name}) > 256) {
              @compileError("FSM context is larger than 256 bytes; use @stack on this BG block to force a compiler-sized stackful fiber.");
          }
      }
    ZIG
  end

  # ----- struct decl with member fns ----------------------------------------

  def render_ctx_struct(s, mir_emitter)
    parts = []
    parts << "    const #{s.type_name} = struct {"
    parts << "        task: *CheatHeader.FsmTask,"
    parts << "        rt: *Runtime,"
    parts << "        inner: *#{s.promise_zig}.Inner,"
    parts << "        alloc: std.mem.Allocator,"
    parts << "        #{s.captures_decl_zig}" unless empty?(s.captures_decl_zig)
    parts << "        step: u8 = 0,"
    s.state_decls.each { |d| parts << "        #{d.render}" }
    s.promoted_field_decls.each { |line| parts << "        #{line}" }
    parts << ""
    parts << render_step(s.step0, mir_emitter)
    parts << ""
    parts << render_step(s.step1, mir_emitter)
    parts << ""
    parts << indent_block(render_dispatch(s.resume_fn), 8)
    parts << ""
    parts << render_destroy_task(s.resume_fn.ctx_id)
    parts << "    };"
    parts.join("\n")
  end

  # ----- one runStepN function ----------------------------------------------
  #
  # body_stmts is a list of MIR statement nodes (or Strings during
  # the transition). Each is fed through MIREmitter.emit to produce
  # the Zig fragment for that statement. We skip emissions that
  # come back empty / nil so verification-only nodes (AllocMark,
  # ReturnMark, ...) don't leave blank lines in the output.

  def render_step(step, mir_emitter)
    rendered = (step.body_stmts || []).filter_map do |stmt|
      out = mir_emitter.emit(stmt)
      next nil if out.nil? || out.strip.empty?
      out
    end
    body = rendered.map { |l| indent_block(l, 12) }.join("\n")

    [
      "        fn runStep#{step.index}(__ctx_#{step.ctx_id}: *@This()) anyerror!void {",
      "            const #{step.bg_rt} = __ctx_#{step.ctx_id}.rt;",
      ("            #{step.rt_suppress_zig}" unless empty?(step.rt_suppress_zig)),
      (body unless body.empty?),
      "        }",
    ].compact.join("\n")
  end

  # Render an err-cleanup list (per-arm direct cleanups in the err
  # handler, typically capture frees in the B2-IO step-0 catch).
  # Each entry is an MIR statement (typically MIR::ExprStmt(MIR::
  # MethodCall(...))); we route each through a fresh MIREmitter
  # so the same Phase-4 path renders these as renders the arm
  # bodies. Accepts a String fallback for transitional callers.
  def render_resume_fn_cleanups(cleanups)
    return "" if cleanups.nil?
    return cleanups if cleanups.is_a?(String)  # transitional fallback
    return "" if cleanups.empty?
    emitter = MIREmitter.new
    cleanups.filter_map { |stmt|
      out = emitter.emit(stmt)
      next nil if out.nil? || out.strip.empty?
      out
    }.join("\n")
  end

  # ----- generic body (LOOP / WITH / NEXT-CHAIN) ---------------------------

  def render_generic_body(body)
    mir_emitter = MIREmitter.new
    parts = []
    parts << "#{body.blk_label}: {"
    parts << render_generic_ctx_struct(body.ctx_struct, mir_emitter)
    parts << render_ctx_size_gate(body.ctx_struct.type_name)
    parts << render_spawn_setup(body.spawn_setup, body.blk_label)
    parts << "}"
    parts.join("\n")
  end

  def render_generic_ctx_struct(s, mir_emitter)
    parts = []
    parts << "    const #{s.type_name} = struct {"
    parts << "        task: *CheatHeader.FsmTask,"
    parts << "        rt: *Runtime,"
    parts << "        inner: *#{s.promise_zig}.Inner,"
    parts << "        alloc: std.mem.Allocator,"
    parts << "        #{s.captures_decl_zig}" unless empty?(s.captures_decl_zig)
    (s.extra_field_decls || []).each do |line|
      next if empty?(line)
      parts << "        #{line}"
    end
    (s.promoted_field_decls || []).each do |line|
      next if empty?(line)
      parts << "        #{line}"
    end
    parts << ""
    (s.member_fns || []).each do |fn|
      parts << render_member_fn(fn, mir_emitter)
      parts << ""
    end
    if s.resume_fn_zig.is_a?(MIR::FsmDispatch)
      parts << indent_block(render_dispatch(s.resume_fn_zig), 8)
      parts << ""
      parts << render_destroy_task(s.resume_fn_zig.ctx_id, s.destroy_extra_zig)
    elsif !empty?(s.resume_fn_zig)
      parts << indent_block(s.resume_fn_zig, 8)
    end
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
  def render_dispatch(d)
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

  def render_dispatch_arm(arm, ctx_id)
    body_lines = []
    if arm.pre_body_skip
      body_lines << "if (#{arm.pre_body_skip.cond_zig}) {"
      body_lines << "    __ctx_#{ctx_id}.step = #{arm.pre_body_skip.skip_step};"
      body_lines << "    continue :__sw;"
      body_lines << "}"
    end
    body_lines << arm.pre_body_zig if arm.pre_body_zig && !empty?(arm.pre_body_zig)
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
  def arm_uses_continue?(arm)
    return true if arm.pre_body_skip
    case arm.tail
    when MIR::FsmTailJump, MIR::FsmTailRegisterYield, MIR::FsmTailCondJump,
         MIR::FsmTailLockTry, MIR::FsmTailWokenCheck, MIR::FsmTailRetryOrError
      true
    else
      false
    end
  end

  def render_tail(t, ctx_id)
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
        "if (#{t.register_zig}) {",
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
        "if (#{t.cond_zig}) {",
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

  def render_member_fn(fn, mir_emitter)
    rendered = (fn.body_stmts || []).filter_map do |stmt|
      out = mir_emitter.emit(stmt)
      next nil if out.nil? || out.strip.empty?
      out
    end
    body = rendered.map { |l| indent_block(l, 12) }.join("\n")

    [
      "        fn #{fn.fn_name}(__ctx_#{fn.ctx_id}: *@This()) anyerror!void {",
      "            const #{fn.bg_rt} = __ctx_#{fn.ctx_id}.rt;",
      ("            #{fn.rt_suppress_zig}" unless empty?(fn.rt_suppress_zig)),
      (indent_block(fn.extra_prologue_zig, 12) unless empty?(fn.extra_prologue_zig)),
      (body unless body.empty?),
      "        }",
    ].compact.join("\n")
  end

  # ----- post-struct alloc + spawn + break ----------------------------------

  def render_spawn_setup(s, blk_label)
    parts = []
    parts << "    #{s.profile_site_comment}" if s.respond_to?(:profile_site_comment) && !empty?(s.profile_site_comment)
    parts << "    const #{s.alloc_var} = #{s.alloc_expr_zig};"
    parts << "    const #{s.promise_var} = try #{s.promise_zig}.spawn(#{s.alloc_var}, #{s.rt_name}.getSched());"
    parts << indent_block(s.promoted_decls_zig, 4) unless empty?(s.promoted_decls_zig)
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
    parts << indent_block(s.ctx_init_zig, 8)
    parts << "    };"
    parts << "    #{s.ctx_var}.task = #{s.ctx_var}_task;"
    # Allocate a per-task Runtime shell. EBR is resolved at dispatch time
    # through Runtime.currentEbr(), so FSMs running on worker schedulers use
    # the active scheduler thread's registered EBR slot instead of the
    # spawning runtime's fallback slot.
    parts << "    #{s.ctx_var}.rt = try CheatHeader.allocFsmTaskRuntime(#{s.ctx_var}_task, #{s.rt_name});"
    parts << "    #{s.spawn_call_zig}"
    parts << "    break :#{blk_label} #{s.promise_var};"
    parts.join("\n")
  end

  # ----- helpers ------------------------------------------------------------

  def empty?(s)
    s.nil? || s.strip.empty?
  end

  # Re-indent every line of `text` by `n` spaces. Preserves blank
  # lines as truly blank (no trailing whitespace) so the rendered
  # Zig stays readable when diff'd.
  def indent_block(text, n)
    return "" if empty?(text)
    pad = " " * n
    text.to_s.lines.map { |l|
      stripped = l.chomp("\n")
      stripped.strip.empty? ? "" : pad + stripped
    }.join("\n")
  end
end
