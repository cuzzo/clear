require 'bundler/setup'
require_relative '../src/mir/mir'
require_relative '../src/mir/fsm_ops'
require_relative '../src/mir/fsm_wrapper_emitter'

# Tests for the FSM-IO state-machine wrapper renderer that
# replaces the heredoc previously inlined in
# src/mir/fsm_lowering.rb#emit_fsm_io_bg_code.
#
# The renderer is mechanical: it walks an MIR::FsmIoBody tree
# (FsmCtxStruct + FsmStep + FsmDispatch + FsmSpawnSetup) and
# concatenates the result. NO decisions in the renderer; the
# lowering owns alloc kind, spawn fn, capture cleanup placement,
# etc., and writes them as fields on the body. These specs verify
# that the structural pieces appear at the right places and that
# the output is a syntactically valid FSM body shape.

RSpec.describe FsmWrapperEmitter do
  # Helper builders so each spec can construct a minimal valid body
  # without rebuilding the whole state-machine fixture every time.
  def step(idx, ctx_id, body_lines = [])
    MIR::FsmStep.new(idx, ctx_id, "__rt_bg0", true, body_lines)
  end

  def resume_fn(ctx_id, err_cleanup = nil)
    MIR::FsmDispatch.new(
      ctx_id,
      [
        MIR::FsmStateArm.new(0, nil, nil, "runStep0", err_cleanup,
                             MIR::FsmTailYield.new(1, "WaitForLock")),
        MIR::FsmStateArm.new(1, nil, nil, "runStep1", nil,
                             MIR::FsmTailDone.new(nil)),
      ],
      true,
    )
  end

  def ctx_field(ctx, field)
    MIR::FieldGet.new(MIR::Ident.new(ctx), field)
  end

  def heap_alloc_expr
    MIR::MethodCall.new(MIR::Ident.new("rt"), "heapAlloc", [], false)
  end

  def ctx_init_fields(promise_var, alloc_var, extra = [])
    [
      MIR::StructInitField.new(name: :task, value: MIR::Ident.new("undefined")),
      MIR::StructInitField.new(name: :rt, value: MIR::Ident.new("rt")),
      MIR::StructInitField.new(name: :inner, value: ctx_field(promise_var, "inner")),
      MIR::StructInitField.new(name: :alloc, value: MIR::Ident.new(alloc_var)),
    ] + extra
  end

  def best_spawn(ctx_var)
    MIR::FsmSpawnCall.new(target: :best, ctx_var: ctx_var)
  end

  def ctx_struct(state_decls: [], step0_body: [], step1_body: [])
    MIR::FsmCtxStruct.new(
      "__BgCtx0",
      "CheatLib.Promise(i64)",
      [MIR::ContextFieldDecl.new(name: "needle", type_zig: "[]const u8")],
      state_decls,
      [],
      step(0, 0, step0_body),
      step(1, 0, step1_body),
      resume_fn(0),
    )
  end

  def spawn_setup
    MIR::FsmSpawnSetup.new(
      "__bg0_alloc",
      heap_alloc_expr,
      "__bg0_promise",
      "CheatLib.Promise(i64)",
      [],
      "__bg0_ctx",
      "__BgCtx0",
      ctx_init_fields("__bg0_promise", "__bg0_alloc"),
      best_spawn("__bg0_ctx"),
      "rt",
    )
  end

  def body(blk_label: "__bg0", **kw)
    MIR::FsmIoBody.new(blk_label, ctx_struct(**kw), spawn_setup)
  end

  def b1_body
    MIR::FsmB1Body.new(
      "__bg_b1",
      MIR::FsmB1CtxStruct.new(
        "__BgB1Ctx",
        "CheatLib.Promise(i64)",
        [MIR::ContextFieldDecl.new(name: "value", type_zig: "i64")],
        MIR::FsmStep.new(0, 0, "__rt_b1", true, [
          MIR::Set.new(
            MIR::FieldGet.new(ctx_field("__ctx_0", "inner"), "result"),
            ctx_field("__ctx_0", "value"),
            false,
          ),
        ]),
      ),
      MIR::FsmSpawnSetup.new(
        "__bg_b1_alloc",
        heap_alloc_expr,
        "__bg_b1_promise",
        "CheatLib.Promise(i64)",
        [],
        "__bg_b1_ctx",
        "__BgB1Ctx",
        ctx_init_fields(
          "__bg_b1_promise",
          "__bg_b1_alloc",
          [MIR::StructInitField.new(name: :value, value: MIR::Lit.new("42"))],
        ),
        best_spawn("__bg_b1_ctx"),
        "rt",
      ),
    )
  end

  describe "outer block structure" do
    it "wraps the entire emission in a labeled block" do
      out = FsmWrapperEmitter.render(body)
      expect(out).to start_with("__bg0: {")
      expect(out).to end_with("}")
      expect(out).to include("break :__bg0 __bg0_promise;")
    end

    it "rejects non-FsmIoBody inputs" do
      expect { FsmWrapperEmitter.render("oops") }.to raise_error(ArgumentError)
    end
  end

  describe "B1 pure-compute body" do
    it "emits a single runBody and fixed resume function" do
      out = FsmWrapperEmitter.render(b1_body)

      expect(out).to start_with("__bg_b1: {")
      expect(out).to include("fn runBody(__ctx_0: *@This()) anyerror!void {")
      expect(out).to include("__ctx_0.inner.result = __ctx_0.value;")
      expect(out).to include("if (runBody(__ctx_0)) |_| {} else |err|")
      expect(out).to include("return .{ .Done = {} };")
      expect(out).to include("break :__bg_b1 __bg_b1_promise;")
    end
  end

  describe "ctx struct decl" do
    it "emits the fixed-prefix fields (task, rt, inner, alloc)" do
      out = FsmWrapperEmitter.render(body)
      expect(out).to include("task: *CheatHeader.FsmTask,")
      expect(out).to include("rt: *Runtime,")
      expect(out).to include("inner: *CheatLib.Promise(i64).Inner,")
      expect(out).to include("alloc: std.mem.Allocator,")
    end

    it "emits the step counter" do
      expect(FsmWrapperEmitter.render(body)).to include("step: u8 = 0,")
    end

    it "renders state decls via FsmOps::StateFieldDecl#render" do
      decls = [
        FsmOps::StateFieldDecl.new("rf_fd", "i32", "-1"),
        FsmOps::StateFieldDecl.new("rf_buf", "[]u8", "&[_]u8{}"),
      ]
      out = FsmWrapperEmitter.render(body(state_decls: decls))
      expect(out).to include("rf_fd: i32 = -1,")
      expect(out).to include("rf_buf: []u8 = &[_]u8{},")
    end

    it "emits captures field block" do
      out = FsmWrapperEmitter.render(body)
      expect(out).to include("needle: []const u8,")
    end
  end

  describe "step bodies" do
    it "emits runStep0 and runStep1 with the bg_rt binding" do
      out = FsmWrapperEmitter.render(body)
      expect(out).to include("fn runStep0(__ctx_0: *@This()) anyerror!void {")
      expect(out).to include("fn runStep1(__ctx_0: *@This()) anyerror!void {")
      expect(out).to include("const __rt_bg0 = __ctx_0.rt;")
    end

    it "interleaves body lines into the step function" do
      stmts = [
        MIR::Set.new(
          ctx_field("__ctx_0", "rf_fd"),
          MIR::Call.new("open", [ctx_field("__ctx_0", "path")], true),
          false,
        ),
        MIR::ExprStmt.new(MIR::Call.new("close", [ctx_field("__ctx_0", "rf_fd")], false), false),
      ]
      out = FsmWrapperEmitter.render(body(step0_body: stmts))
      expect(out).to include("__ctx_0.rf_fd = try open(__ctx_0.path);")
      expect(out).to include("close(__ctx_0.rf_fd);")
    end

    it "skips verification-only body nodes without leaving stray blanks" do
      stmts = [
        MIR::AllocMark.new("tmp", :heap, Type.new(:String), :function),
        MIR::ExprStmt.new(MIR::Call.new("real_stmt", [], false), false),
      ]
      out = FsmWrapperEmitter.render(body(step0_body: stmts))
      expect(out).to include("real_stmt();")
      expect(out).not_to match(/\n\s*\n\s*\n/)
    end
  end

  describe "resumeFn dispatch" do
    it "emits the fixed dispatch shape" do
      out = FsmWrapperEmitter.render(body)
      expect(out).to include("@ptrCast(@alignCast(__fsm_task.ctx.?))")
      expect(out).to include("switch (__ctx_0.step)")
      expect(out).to include("return .{ .WaitForLock = {} };")
      expect(out).to include("return .{ .Done = {} };")
      expect(out).to include("__ctx_0.inner.wg.done();")
      # Destroy is now the scheduler's job (via FsmTask.destroy_fn);
      # the resume fn must NOT free ctx, or dispatchOnce reads
      # task.status from freed memory. The destroyTask member fn
      # is rendered separately on the ctx struct.
      expect(out).to include("fn destroyTask(")
      expect(out).to include(".destroy_fn = &__BgCtx0.destroyTask")
      expect(out).to include("CheatHeader.freeFsmCtx(@This(), __fsm_task, __ctx_0)")
    end

    it "interpolates step-0 error cleanup into the catch arm" do
      ctx = ctx_struct
      ctx.resume_fn = resume_fn(0,
        [
          MIR::ExprStmt.new(
            MIR::MethodCall.new(
              MIR::FieldGet.new(MIR::Ident.new("__ctx_0"), "alloc"),
              "free",
              [MIR::FieldGet.new(MIR::Ident.new("__ctx_0"), "needle")],
              false,
            ),
            false,
          ),
        ])
      bod = MIR::FsmIoBody.new("__bg0", ctx, spawn_setup)
      out = FsmWrapperEmitter.render(bod)
      expect(out).to match(/if \((?:@This\(\)\.)?runStep0.+\) \|_\| \{\} else \|err\| \{[\s\S]*?__ctx_0\.alloc\.free\(__ctx_0\.needle\);[\s\S]*?return \.\{ \.Done = \{\} \};/)
    end

    it "renders dispatch pre-body skip arms" do
      dispatch = MIR::FsmDispatch.new(
        4,
        [
          MIR::FsmStateArm.new(
            0,
            MIR::FsmTailCondSkip.new(MIR::FieldGet.new(MIR::Ident.new("__ctx_4"), "skip"), 2),
            nil,
            nil,
            nil,
            MIR::FsmTailJump.new(1),
          ),
        ],
        true,
      )

      out = FsmWrapperEmitter.render_dispatch(dispatch)

      expect(out).to include("if (__ctx_4.skip) {")
      expect(out).to include("__ctx_4.step = 2;")
      expect(out).to include("continue :__sw;")
    end

    it "rejects unknown dispatch tails" do
      expect { FsmWrapperEmitter.render_tail(Object.new, 0) }
        .to raise_error(ArgumentError, /unknown tail/)
    end
  end

  describe "generic FSM body" do
    it "rejects legacy raw resume function text" do
      generic_ctx = MIR::FsmGenericCtxStruct.new(
        "__BgRawCtx",
        "CheatLib.Promise(i64)",
        [],
        [],
        [],
        [],
        "fn resumeFn(_: *CheatHeader.FsmTask) CheatHeader.YieldReason { return .{ .Done = {} }; }",
        nil,
      )
      generic_body = MIR::FsmGenericBody.new("__bg_raw", generic_ctx, spawn_setup)

      expect { FsmWrapperEmitter.render(generic_body) }
        .to raise_error(ArgumentError, /requires MIR::FsmDispatch/)
    end

    it "renders generic destroyTask actions from structural records" do
      cleanup_entry = CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: true)
      actions = [
        MIR::FsmDestroyLockRelease.new(
          name: "__ctx_2.lock",
          guard_field: "__lock_held_0",
          lock_ref: ctx_field("__ctx_2", "lock"),
          unlock_method: "unlock",
        ),
        MIR::FsmDestroyCleanup.new(
          source_kind: :fresh_heap,
          name: "owned",
          target: ctx_field("__ctx_2", "owned"),
          cleanup_entry: cleanup_entry,
          allocator: ctx_field("__ctx_2", "alloc"),
        ),
      ]
      generic_ctx = MIR::FsmGenericCtxStruct.new(
        "__BgGenericCtx",
        "CheatLib.Promise(i64)",
        [],
        [],
        [],
        [],
        resume_fn(2),
        actions,
      )
      generic_body = MIR::FsmGenericBody.new("__bg_generic", generic_ctx, spawn_setup)

      out = FsmWrapperEmitter.render(generic_body)

      expect(out).to include("if (__ctx_2.__lock_held_0) __ctx_2.lock.unlock();")
      expect(out).to include(
        "if (!__ctx_2.owned_moved) CheatLib.cleanup(@TypeOf(__ctx_2.owned), __ctx_2.alloc, &__ctx_2.owned);"
      )
    end

    it "wraps guarded destroy cleanup actions, including multi-line cleanups" do
      rc_entry = CleanupEntry.build(
        :rc,
        alloc: :heap,
        has_moved_guard: false,
        rc_alloc: :heap,
        base_zig: "User",
        needs_release_fields: true,
      )
      actions = [
        MIR::FsmDestroyCleanup.new(
          source_kind: :owned_result,
          name: "single",
          target: ctx_field("__ctx_3", "single"),
          cleanup_entry: CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: false),
          guard: ctx_field("__ctx_3", "single_ready"),
        ),
        MIR::FsmDestroyCleanup.new(
          source_kind: :owned_result,
          name: "owner",
          target: ctx_field("__ctx_3", "owner"),
          cleanup_entry: rc_entry,
          guard: ctx_field("__ctx_3", "owner_ready"),
        ),
      ]
      generic_ctx = MIR::FsmGenericCtxStruct.new(
        "__BgGuardCtx",
        "CheatLib.Promise(i64)",
        [],
        [],
        [],
        [],
        resume_fn(3),
        actions,
      )
      generic_body = MIR::FsmGenericBody.new("__bg_guard", generic_ctx, spawn_setup)

      out = FsmWrapperEmitter.render(generic_body)

      expect(out).to include(
        "if (__ctx_3.single_ready) CheatLib.cleanup(@TypeOf(__ctx_3.single), __ctx_3.rt.heapAlloc(), &__ctx_3.single);"
      )
      expect(out).to include("if (__ctx_3.owner_ready) {\n")
      expect(out).to include("CheatLib.releaseFields(User, __ctx_3.rt.heapAlloc(), __ctx_3.owner.ctrl.data.*);")
    end
  end

  describe "step body as MIR statements" do
    it "renders MIR::Let in body_stmts via the standard MIR emitter" do
      bind = MIR::Let.new(
        "content",
        MIR::FieldGet.new(MIR::Ident.new("__ctx_0"), "rf_buf"),
        false, nil, nil,
      )
      out = FsmWrapperEmitter.render(body(step1_body: [bind]))
      expect(out).to include("const content = __ctx_0.rf_buf;")
    end

    it "rejects plain string body_stmts" do
      expect { FsmWrapperEmitter.render(body(step0_body: ["foo();"])) }
        .to raise_error(ArgumentError, /structural MIR/)
    end

    it "skips verification-only MIR emissions without leaving stray blanks" do
      stmts = [
        MIR::AllocMark.new("tmp", :heap, Type.new(:String), :function),
        MIR::ExprStmt.new(MIR::Call.new("real", [], false), false),
      ]
      out = FsmWrapperEmitter.render(body(step0_body: stmts))
      expect(out).to include("real();")
      expect(out).not_to match(/\n\s*\n\s*\n/)
    end
  end

  describe "spawn setup" do
    it "emits alloc / promise spawn / ctx alloc / init / task / spawn / break" do
      out = FsmWrapperEmitter.render(body)
      expect(out).to include("const __bg0_alloc = rt.heapAlloc();")
      expect(out).to include("const __bg0_promise = try CheatLib.Promise(i64).spawn(__bg0_alloc, rt.getSched());")
      expect(out).to include("const __bg0_ctx_task = try CheatHeader.allocFsmTask(rt, &__BgCtx0.resumeFn);")
      expect(out).to include("const __bg0_ctx = try CheatHeader.allocFsmCtx(__BgCtx0, rt, __bg0_ctx_task);")
      expect(out).to include("errdefer CheatHeader.freeFsmCtx(__BgCtx0, __bg0_ctx_task, __bg0_ctx);")
      expect(out).to include("__bg0_ctx.* = .{")
      expect(out).to include(".rt = rt,")
      expect(out).to include(".inner = __bg0_promise.inner,")
      expect(out).to include("__bg0_ctx_task.ctx = __bg0_ctx;")
      expect(out).to include("__bg0_ctx.task = __bg0_ctx_task;")
      expect(out).to include("try CheatHeader.spawnFsmBest(__bg0_ctx.task);")
      expect(out).to include("break :__bg0 __bg0_promise;")
    end
  end
end
