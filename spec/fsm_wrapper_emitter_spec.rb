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
    MIR::FsmStep.new(idx, ctx_id, "__rt_bg0", "_ = &__rt_bg0;", body_lines)
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

  def ctx_struct(state_decls: [], step0_body: [], step1_body: [])
    MIR::FsmCtxStruct.new(
      "__BgCtx0",
      "CheatLib.Promise(i64)",
      "needle: []const u8,",
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
      "rt.heapAlloc()",
      "__bg0_promise",
      "CheatLib.Promise(i64)",
      "",  # promoted_decls_zig
      "__bg0_ctx",
      "__BgCtx0",
      ".task = undefined,\n.rt = rt,\n.inner = __bg0_promise.inner,\n.alloc = __bg0_alloc,",
      "try CheatHeader.spawnFsmBest(__bg0_ctx.task);",
      "rt",
    )
  end

  def body(blk_label: "__bg0", **kw)
    MIR::FsmIoBody.new(blk_label, ctx_struct(**kw), spawn_setup)
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
      lines = [
        "__ctx_0.rf_fd = try open(__ctx_0.path);",
        "errdefer close(__ctx_0.rf_fd);",
      ]
      out = FsmWrapperEmitter.render(body(step0_body: lines))
      expect(out).to include("__ctx_0.rf_fd = try open(__ctx_0.path);")
      expect(out).to include("errdefer close(__ctx_0.rf_fd);")
    end

    it "skips empty body lines without leaving stray blanks" do
      lines = ["", "real_stmt();", ""]
      out = FsmWrapperEmitter.render(body(step0_body: lines))
      expect(out).to include("real_stmt();")
      # No two adjacent blank lines from the skipped entries.
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
    end

    it "interpolates step-0 error cleanup into the catch arm" do
      ctx = ctx_struct
      ctx.resume_fn = resume_fn(0,
        ["__ctx_0.alloc.free(__ctx_0.needle);"])
      bod = MIR::FsmIoBody.new("__bg0", ctx, spawn_setup)
      out = FsmWrapperEmitter.render(bod)
      expect(out).to match(/if \((?:@This\(\)\.)?runStep0.+\) \|_\| \{\} else \|err\| \{[\s\S]*?__ctx_0\.alloc\.free\(__ctx_0\.needle\);[\s\S]*?return \.\{ \.Done = \{\} \};/)
    end
  end

  describe "step body as MIR statements" do
    it "renders MIR::Let in body_stmts via the standard MIR emitter" do
      bind = MIR::Let.new(
        "content",
        MIR::RawZig.new("__ctx_0.rf_buf[0..10]", :fsm_bound_expr, nil, nil),
        false, nil, nil,
      )
      out = FsmWrapperEmitter.render(body(step1_body: [bind]))
      expect(out).to include("const content = __ctx_0.rf_buf[0..10];")
    end

    it "renders MIR::RawZig in body_stmts" do
      stmt = MIR::RawZig.new("foo();", :fsm_pre_stmts, nil, nil)
      out = FsmWrapperEmitter.render(body(step0_body: [stmt]))
      expect(out).to include("foo();")
    end

    it "accepts plain strings as a transitional escape hatch" do
      out = FsmWrapperEmitter.render(body(step0_body: ["plain_zig();"]))
      expect(out).to include("plain_zig();")
    end

    it "skips empty / nil emissions without leaving stray blanks" do
      stmts = [
        MIR::RawZig.new("", :fsm_pre_stmts, nil, nil),
        MIR::RawZig.new("real();", :fsm_pre_stmts, nil, nil),
        nil,
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
      expect(out).to include("const __bg0_ctx = try __bg0_alloc.create(__BgCtx0);")
      expect(out).to include("errdefer __bg0_alloc.destroy(__bg0_ctx);")
      expect(out).to include("__bg0_ctx.* = .{")
      expect(out).to include(".rt = rt,")
      expect(out).to include(".inner = __bg0_promise.inner,")
      expect(out).to include("const __bg0_ctx_task = try CheatHeader.allocFsmTask(rt, &__BgCtx0.resumeFn);")
      expect(out).to include("__bg0_ctx_task.ctx = __bg0_ctx;")
      expect(out).to include("__bg0_ctx.task = __bg0_ctx_task;")
      expect(out).to include("try CheatHeader.spawnFsmBest(__bg0_ctx.task);")
      expect(out).to include("break :__bg0 __bg0_promise;")
    end
  end
end
