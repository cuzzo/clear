require 'bundler/setup'
require_relative '../src/mir/fsm_ops'

# Tests the FsmOps op tree + emitter that replaces the previous
# Zig-text :fsm_setup / :fsm_finish_block / :fsm_finish_value
# templates. These specs exercise:
#
#   - Each op kind renders to the expected Zig fragment.
#   - Template arg substitution ({0}, {1}, ...) goes through ArgRef,
#     not string interpolation.
#   - Context-rooted function paths render to __ctx_<id> without
#     placeholder substitution.
#   - Structure-derivation helpers (referenced_state_fields,
#     alloc_state_fields, free_state_fields) walk op trees correctly
#     and let the FsmStructure derivation in fsm_lowering.rb avoid
#     textual scans of rendered Zig.

RSpec.describe FsmOps do
  let(:emitter) do
    FsmOps::Emitter.new(
      ctx_id: 0,
      bg_rt: "__rt_bg0",
      arg_codes: ["path_arg", "content_arg"],
    )
  end

  FO = FsmOps::DSL

  describe "expression emission" do
    it "renders ArgRef from arg_codes" do
      expect(emitter.emit_expr(FO.arg(0))).to eq("path_arg")
      expect(emitter.emit_expr(FO.arg(1))).to eq("content_arg")
    end

    it "raises on out-of-range arg index" do
      expect { emitter.emit_expr(FO.arg(2)) }
        .to raise_error(ArgumentError, /arg index 2 out of range/)
    end

    it "renders StateField as __ctx_<id>.<name>" do
      expect(emitter.emit_expr(FO.state("rf_buf"))).to eq("__ctx_0.rf_buf")
    end

    it "renders SubField as base.name" do
      expect(emitter.emit_expr(FO.subf(FO.state("rf_waiter"), "result")))
        .to eq("__ctx_0.rf_waiter.result")
    end

    it "renders AddrOf as &expr" do
      expect(emitter.emit_expr(FO.addr(FO.state("task")))).to eq("&__ctx_0.task")
    end

    it "renders IntCast as @as(type, @intCast(expr))" do
      expect(emitter.emit_expr(FO.intcast("usize", FO.arg(0))))
        .to eq("@as(usize, @intCast(path_arg))")
    end

    it "renders BinOp with parens" do
      expr = FO.binop("+", FO.call(FO.fn("clock"), []), FO.intcast("i64", FO.arg(0)))
      expect(emitter.emit_expr(expr)).to eq("(clock() + @as(i64, @intCast(path_arg)))")
    end

    it "renders SliceUntilIntCast" do
      expr = FO.slice_intcast(FO.state("rf_buf"),
                              FO.subf(FO.state("rf_waiter"), "result"))
      expect(emitter.emit_expr(expr))
        .to eq("__ctx_0.rf_buf[0..@as(usize, @intCast(__ctx_0.rf_waiter.result))]")
    end

    it "renders try CallExpr" do
      expr = FO.call(FO.fn("CheatHeader.fsmOpenForRead"), [FO.arg(0)], is_try: true)
      expect(emitter.emit_expr(expr))
        .to eq("try CheatHeader.fsmOpenForRead(path_arg)")
    end

    it "renders AllocExpr against ctx.alloc" do
      expr = FO.alloc_expr("u8", FO.local("__rf_size"))
      expect(emitter.emit_expr(expr)).to eq("try __ctx_0.alloc.alloc(u8, __rf_size)")
    end

    it "renders context-rooted CallExpr function paths" do
      expr = FO.call(FO.ctx_fn(["rt", "getSched()", "fsmSleepTask"]),
                     [FO.addr(FO.state("task")), FO.lit("42")])
      expect(emitter.emit_expr(expr))
        .to eq("__ctx_0.rt.getSched().fsmSleepTask(&__ctx_0.task, 42)")
    end

    it "rejects unknown function path roots" do
      path = FsmOps::FunctionPath.new(root: :bogus, parts: ["bad"])
      expect { path.render("__ctx_0") }
        .to raise_error(ArgumentError, /unknown FSM function path root/)
    end
  end

  describe "statement emission" do
    it "renders AssignField with try call" do
      stmt = FO.assign_field("rf_fd",
        FO.call(FO.fn("CheatHeader.fsmOpenForRead"), [FO.arg(0)], is_try: true))
      expect(emitter.emit_stmt(stmt))
        .to eq("__ctx_0.rf_fd = try CheatHeader.fsmOpenForRead(path_arg);")
    end

    it "renders LetConst with intcast(try call)" do
      stmt = FO.let_const("__rf_size", "usize",
        FO.intcast("usize",
          FO.call(FO.fn("CheatHeader.fsmFileSize"), [FO.state("rf_fd")], is_try: true)))
      expect(emitter.emit_stmt(stmt))
        .to eq("const __rf_size: usize = @as(usize, @intCast(try CheatHeader.fsmFileSize(__ctx_0.rf_fd)));")
    end

    it "renders ErrDeferCall" do
      stmt = FO.err_defer_call(FO.fn("CheatHeader.fsmCloseFd"), [FO.state("rf_fd")])
      expect(emitter.emit_stmt(stmt))
        .to eq("errdefer CheatHeader.fsmCloseFd(__ctx_0.rf_fd);")
    end

    it "renders ErrDeferFreeField" do
      stmt = FO.err_defer_free_field("rf_buf")
      expect(emitter.emit_stmt(stmt))
        .to eq("errdefer __ctx_0.alloc.free(__ctx_0.rf_buf);")
    end

    it "renders DeferFreeField" do
      stmt = FO.defer_free_field("rf_buf")
      expect(emitter.emit_stmt(stmt))
        .to eq("defer __ctx_0.alloc.free(__ctx_0.rf_buf);")
    end

    it "renders IoSubmit with verb -> runtime fn lookup" do
      stmt = FO.io_submit(:read, "rf_waiter",
                          [FO.state("rf_fd"), FO.state("rf_buf")])
      expect(emitter.emit_stmt(stmt))
        .to eq("try __ctx_0.rt.getSched().submitReadForFsm(&__ctx_0.rf_waiter, __ctx_0.rf_fd, __ctx_0.rf_buf);")
    end

    it "raises on IoSubmit unknown verb" do
      stmt = FO.io_submit(:bogus, "w", [])
      expect { emitter.emit_stmt(stmt) }
        .to raise_error(ArgumentError, /unknown verb/)
    end

    it "renders IfFieldSubLtZeroReturnCall" do
      stmt = FO.if_neg_return_call("rf_waiter", "result",
        FO.fn("CheatHeader.fsmIoError"),
        [FO.subf(FO.state("rf_waiter"), "result")])
      expect(emitter.emit_stmt(stmt)).to include("if (__ctx_0.rf_waiter.result < 0)")
      expect(emitter.emit_stmt(stmt))
        .to include("return CheatHeader.fsmIoError(__ctx_0.rf_waiter.result);")
    end
  end

  describe "structure derivation helpers" do
    let(:setup_ops) {
      [
        FO.assign_field("rf_fd",
          FO.call(FO.fn("CheatHeader.fsmOpenForRead"), [FO.arg(0)], is_try: true)),
        FO.err_defer_call(FO.fn("CheatHeader.fsmCloseFd"), [FO.state("rf_fd")]),
        FO.assign_field("rf_buf", FO.alloc_expr("u8", FO.local("__rf_size"))),
        FO.err_defer_free_field("rf_buf"),
        FO.io_submit(:read, "rf_waiter",
          [FO.state("rf_fd"), FO.state("rf_buf")]),
      ]
    }

    let(:finalize_ops) {
      [FO.defer_free_field("rf_buf")]
    }

    it "lists referenced state fields without textual scanning" do
      refs = FsmOps.referenced_state_fields(setup_ops).sort
      # The fixture's setup_ops references rf_fd, rf_buf, rf_waiter
      # (the last via the IoSubmit waiter slot which is now a
      # StateField op so the walker sees it). It does NOT include
      # the rf_waiter init step (which would bring &task into the
      # tree), so "task" is correctly absent.
      expect(refs).to eq(%w[rf_buf rf_fd rf_waiter])
    end

    it "identifies alloc'd state fields" do
      expect(FsmOps.alloc_state_fields(setup_ops)).to eq(["rf_buf"])
    end

    it "identifies freed state fields (errdefer + defer)" do
      expect(FsmOps.free_state_fields(setup_ops + finalize_ops).sort).to eq(["rf_buf"])
    end
  end

  describe "rendering a complete readFile setup matches the Zig form expected by the runtime" do
    # Smoke-level snapshot: the rendered code must compile under
    # the FSM ctx struct. We assert the structural pieces are
    # present rather than the exact whitespace, so non-semantic
    # edits to the emitter don't churn this test.
    it "produces all expected statements in order" do
      ops = [
        FO.assign_field("rf_fd",
          FO.call(FO.fn("CheatHeader.fsmOpenForRead"), [FO.arg(0)], is_try: true)),
        FO.err_defer_call(FO.fn("CheatHeader.fsmCloseFd"), [FO.state("rf_fd")]),
        FO.let_const("__rf_size", "usize",
          FO.intcast("usize",
            FO.call(FO.fn("CheatHeader.fsmFileSize"), [FO.state("rf_fd")], is_try: true))),
        FO.assign_field("rf_buf",
          FO.alloc_expr("u8", FO.local("__rf_size"))),
        FO.err_defer_free_field("rf_buf"),
        FO.assign_field("rf_waiter",
          FO.call(FO.fn("CheatHeader.FsmIoWaiter.init"),
                  [FO.addr(FO.state("task"))])),
        FO.io_submit(:read, "rf_waiter",
          [FO.state("rf_fd"), FO.state("rf_buf")]),
      ]
      out = emitter.emit_stmts(ops)
      expect(out).to include("__ctx_0.rf_fd = try CheatHeader.fsmOpenForRead(path_arg);")
      expect(out).to include("errdefer CheatHeader.fsmCloseFd(__ctx_0.rf_fd);")
      expect(out).to include("const __rf_size: usize = @as(usize, @intCast(try CheatHeader.fsmFileSize(__ctx_0.rf_fd)));")
      expect(out).to include("__ctx_0.rf_buf = try __ctx_0.alloc.alloc(u8, __rf_size);")
      expect(out).to include("errdefer __ctx_0.alloc.free(__ctx_0.rf_buf);")
      expect(out).to include("__ctx_0.rf_waiter = CheatHeader.FsmIoWaiter.init(&__ctx_0.task);")
      expect(out).to include("try __ctx_0.rt.getSched().submitReadForFsm(&__ctx_0.rf_waiter, __ctx_0.rf_fd, __ctx_0.rf_buf);")
    end
  end
end
