require 'bundler/setup'
require_relative '../src/mir/fsm_ops'
require_relative '../src/backends/mir_emitter'

# Tests the FsmOps op tree that replaces the previous Zig-text
# :fsm_setup / :fsm_finish_block / :fsm_finish_value templates.
# Production uses exactly one path: FsmOps::Lowerer builds MIR nodes,
# then the normal MIREmitter renders those nodes at the final edge.
RSpec.describe FsmOps do
  FO = FsmOps::DSL

  let(:lowerer) do
    FsmOps::Lowerer.new(
      ctx_id: 0,
      bg_rt: "__rt_bg0",
      arg_mirs: [MIR::Ident.new("path_arg"), MIR::Ident.new("content_arg")],
    )
  end

  let(:emitter) { MIREmitter.new }

  def render_expr(expr)
    emitter.emit(lowerer.lower_expr(expr))
  end

  def render_stmt(stmt)
    emitter.emit(lowerer.lower_stmts([stmt]).first)
  end

  describe "expression lowering" do
    it "lowers ArgRef from arg MIR nodes" do
      expect(lowerer.lower_expr(FO.arg(0))).to eq(MIR::Ident.new("path_arg"))
      expect(lowerer.lower_expr(FO.arg(1))).to eq(MIR::Ident.new("content_arg"))
    end

    it "raises on out-of-range arg index" do
      expect { lowerer.lower_expr(FO.arg(2)) }
        .to raise_error(ArgumentError, /arg index 2 out of range/)
    end

    it "lowers StateField and SubField structurally" do
      expect(render_expr(FO.state("rf_buf"))).to eq("__ctx_0.rf_buf")
      expect(render_expr(FO.subf(FO.state("rf_waiter"), "result")))
        .to eq("__ctx_0.rf_waiter.result")
    end

    it "lowers AddrOf structurally" do
      expect(render_expr(FO.addr(FO.state("task")))).to eq("&__ctx_0.task")
    end

    it "lowers IntCast through normal MIR calls" do
      expect(render_expr(FO.intcast("usize", FO.arg(0))))
        .to eq("@as(usize, @intCast(path_arg))")
    end

    it "lowers BinOp with typed children" do
      expr = FO.binop("+", FO.call(FO.fn("clock"), []), FO.intcast("i64", FO.arg(0)))
      expect(render_expr(expr)).to eq("(clock() + @as(i64, @intCast(path_arg)))")
    end

    it "lowers SliceUntilIntCast into MIR::SliceExpr" do
      expr = FO.slice_intcast(FO.state("rf_buf"),
                              FO.subf(FO.state("rf_waiter"), "result"))
      mir = lowerer.lower_expr(expr)

      expect(mir).to be_a(MIR::SliceExpr)
      expect(emitter.emit(mir))
        .to eq("__ctx_0.rf_buf[0..@as(usize, @intCast(__ctx_0.rf_waiter.result))]")
    end

    it "lowers try CallExpr" do
      expr = FO.call(FO.fn("CheatHeader.fsmOpenForRead"), [FO.arg(0)], is_try: true)
      expect(render_expr(expr)).to eq("try CheatHeader.fsmOpenForRead(path_arg)")
    end

    it "lowers AllocExpr against ctx.alloc" do
      expr = FO.alloc_expr("u8", FO.local("__rf_size"))
      expect(render_expr(expr)).to eq("try __ctx_0.alloc.alloc(u8, __rf_size)")
    end

    it "lowers context-rooted CallExpr function paths" do
      expr = FO.call(FO.ctx_fn(["rt", "getSched()", "fsmSleepTask"]),
                     [FO.addr(FO.state("task")), FO.arg(0)])
      expect(render_expr(expr))
        .to eq("__ctx_0.rt.getSched().fsmSleepTask(&__ctx_0.task, path_arg)")
    end

    it "rejects unknown expression ops" do
      expect { lowerer.lower_expr(Object.new) }
        .to raise_error(ArgumentError, /unknown expression op/)
    end

    it "rejects unknown function path roots" do
      path = FsmOps::FunctionPath.new(root: :bogus, parts: ["bad"])
      expect { path.render("__ctx_0") }
        .to raise_error(ArgumentError, /unknown FSM function path root/)
    end
  end

  describe "statement lowering" do
    it "lowers AssignField with try call" do
      stmt = FO.assign_field("rf_fd",
        FO.call(FO.fn("CheatHeader.fsmOpenForRead"), [FO.arg(0)], is_try: true))
      expect(render_stmt(stmt))
        .to eq("__ctx_0.rf_fd = try CheatHeader.fsmOpenForRead(path_arg);")
    end

    it "lowers LetConst with intcast(try call)" do
      stmt = FO.let_const("__rf_size", "usize",
        FO.intcast("usize",
          FO.call(FO.fn("CheatHeader.fsmFileSize"), [FO.state("rf_fd")], is_try: true)))
      expect(render_stmt(stmt))
        .to eq("const __rf_size: usize = @as(usize, @intCast(try CheatHeader.fsmFileSize(__ctx_0.rf_fd)));")
    end

    it "lowers ErrDeferCall" do
      stmt = FO.err_defer_call(FO.fn("CheatHeader.fsmCloseFd"), [FO.state("rf_fd")])
      expect(render_stmt(stmt))
        .to eq("errdefer CheatHeader.fsmCloseFd(__ctx_0.rf_fd);")
    end

    it "lowers ErrDeferFreeField" do
      stmt = FO.err_defer_free_field("rf_buf")
      expect(render_stmt(stmt))
        .to eq("errdefer __ctx_0.alloc.free(__ctx_0.rf_buf);")
    end

    it "lowers DeferFreeField" do
      stmt = FO.defer_free_field("rf_buf")
      expect(render_stmt(stmt))
        .to eq("defer __ctx_0.alloc.free(__ctx_0.rf_buf);")
    end

    it "lowers IoSubmit with verb lookup" do
      stmt = FO.io_submit(:read, "rf_waiter",
                          [FO.state("rf_fd"), FO.state("rf_buf")])
      expect(render_stmt(stmt))
        .to eq("try __ctx_0.rt.getSched().submitReadForFsm(&__ctx_0.rf_waiter, __ctx_0.rf_fd, __ctx_0.rf_buf);")
    end

    it "raises on IoSubmit unknown verb" do
      stmt = FO.io_submit(:bogus, "w", [])
      expect { lowerer.lower_stmts([stmt]) }
        .to raise_error(ArgumentError, /unknown verb/)
    end

    it "lowers IfFieldSubLtZeroReturnCall" do
      stmt = FO.if_neg_return_call("rf_waiter", "result",
        FO.fn("CheatHeader.fsmIoError"),
        [FO.subf(FO.state("rf_waiter"), "result")])
      out = render_stmt(stmt)
      expect(out).to include("if ((__ctx_0.rf_waiter.result < 0))")
      expect(out).to include("return CheatHeader.fsmIoError(__ctx_0.rf_waiter.result);")
    end

    it "lowers try statement calls and rejects unknown statement ops" do
      stmt = FsmOps::StmtCall.new(FO.fn("CheatHeader.tick"), [FO.arg(0)], true)
      expect(render_stmt(stmt)).to eq("try CheatHeader.tick(path_arg);")

      expect { lowerer.send(:lower_stmt, Object.new) }
        .to raise_error(ArgumentError, /unknown statement op/)
    end
  end

  describe "state field declarations" do
    it "stores structural default MIR, not initializer Zig text" do
      decl = FsmOps::StateFieldDecl.new(
        name: "rf_waiter",
        zig_type: "CheatHeader.FsmIoWaiter",
        default_value: MIR::Undef.new(nil),
      )

      expect(decl.name).to eq("rf_waiter")
      expect(decl.zig_type).to eq("CheatHeader.FsmIoWaiter")
      expect(decl.default_value).to eq(MIR::Undef.new(nil))
      expect(decl).not_to respond_to(:init_zig)
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
      expect(refs).to eq(%w[rf_buf rf_fd rf_waiter])
    end

    it "identifies alloc'd state fields" do
      expect(FsmOps.alloc_state_fields(setup_ops)).to eq(["rf_buf"])
    end

    it "identifies freed state fields (errdefer + defer)" do
      expect(FsmOps.free_state_fields(setup_ops + finalize_ops).sort).to eq(["rf_buf"])
    end
  end

  describe "complete readFile setup lowering" do
    it "produces all expected statements through the normal MIR emitter" do
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
      out = lowerer.lower_stmts(ops).map { |stmt| emitter.emit(stmt) }.join("\n")
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
