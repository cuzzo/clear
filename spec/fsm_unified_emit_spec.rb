require 'bundler/setup'
require 'set'
require_relative '../src/mir/mir'
require_relative '../src/mir/fsm_ops'
require_relative '../src/mir/fsm_wrapper_emitter'
require_relative '../src/mir/fsm_transform/segments'
require_relative '../src/mir/fsm_transform/suspend_resolvers'
require_relative '../src/mir/fsm_transform/emit'

# Tests for FsmTransform::Emit.build_fsm_unified -- the kind-agnostic,
# shape-agnostic FSM emitter that produces FsmGenericBody from a list
# of segment specs + per-suspend SuspendDescriptors.
#
# These specs exercise the ASSEMBLY logic only: the caller is
# expected to have already lowered segment stmts to MIR and resolved
# descriptors via SuspendResolvers. The unified emit's job is to
# concatenate setup/bind into the right segment bodies, build the
# dispatch from segment tails, and wrap in FsmGenericBody.

RSpec.describe "FsmTransform::Emit.build_fsm_unified" do
  def fsm_code(result)
    expect(result).to be_a(MIR::FsmLoweringResult)
    result.code
  end

  let(:lowering_double) {
    Class.new {
      def capture_inits_fsm(_); ""; end
    }.new
  }

  let(:base_ctx) {
    {
      id: 0,
      bg_rt: "__rt_bg0",
      blk_label: "__bg0",
      ctx_type: "__BgCtx0",
      promise_zig: "CheatLib.Promise(i64)",
      capture_fields: "",
      alloc_var: "__bg0_alloc",
      promise_var: "__bg0_promise",
      ctx_var: "__bg0_ctx",
      rt_name: "rt",
      pin_mode: false,
      promoted_decls: "",
      capture_inits: "",
    }
  }

  describe "two-segment IO shape (B2-IO)" do
    # Build the descriptor by hand to exercise the assembly without
    # depending on the IO resolver. Setup = a single ExprStmt; bind
    # = an empty MIR set against ctx.inner.result; tail = Yield.
    let(:descriptor) {
      MIR::SuspendDescriptor.new(
        # setup_stmts
        [MIR::ExprStmt.new(MIR::Lit.new("registerWaiter()"), false)],
        # bind_stmts
        [MIR::ExprStmt.new(MIR::Lit.new("__waiter.result"), false)],
        # tail
        MIR::FsmTailYield.new(nil, "WaitForLock"),
        # ctx_field_decls
        ["rf_fd: i32 = -1,"],
        # result_var
        nil,
        # result_zig_type
        nil,
        # result_needs_cleanup
        false,
      )
    }

    let(:segment_specs) {
      [
        {
          index:      0,
          body_stmts: [MIR::ExprStmt.new(MIR::Lit.new("preStmt()"), false)],
          tail:       FsmTransform::Segments::IoSuspend.new(
                        Struct.new(:args).new([]), {}, nil),
          descriptor: descriptor,
          fn_name:    "runStep0",
        },
        {
          index:      1,
          body_stmts: [MIR::ExprStmt.new(MIR::Lit.new("postStmt()"), false)],
          tail:       FsmTransform::Segments::Done.new(nil),
          descriptor: nil,
          fn_name:    "runStep1",
        },
      ]
    }

    it "produces rendered Zig text" do
      out = fsm_code(FsmTransform::Emit.build_fsm_unified(
        base_ctx, segment_specs, [], lowering_double))
      expect(out).to include("__bg0: {")
    end

    it "concatenates the descriptor's setup_stmts onto seg 0's body" do
      out = fsm_code(FsmTransform::Emit.build_fsm_unified(
        base_ctx, segment_specs, [], lowering_double))
      runstep0 = out[/fn runStep0.*?fn runStep1/m]
      expect(runstep0).to include("preStmt()")
      expect(runstep0).to include("registerWaiter()")
    end

    it "concatenates the descriptor's bind_stmts onto seg 1's body" do
      out = fsm_code(FsmTransform::Emit.build_fsm_unified(
        base_ctx, segment_specs, [], lowering_double))
      runstep1 = out[/fn runStep1.*?fn resumeFn/m]
      expect(runstep1).to include("__waiter.result")
      expect(runstep1).to include("postStmt()")
    end

    it "places suspend ctx_field_decls in the ctx struct" do
      out = fsm_code(FsmTransform::Emit.build_fsm_unified(
        base_ctx, segment_specs, [], lowering_double))
      expect(out).to include("rf_fd: i32 = -1,")
    end

    it "emits dispatch with FsmTailYield and FsmTailDone" do
      out = fsm_code(FsmTransform::Emit.build_fsm_unified(
        base_ctx, segment_specs, [], lowering_double))
      # Arm 0 yields WaitForLock with step=1.
      expect(out).to match(/0 => \{[\s\S]*?step = 1;[\s\S]*?return \.\{ \.WaitForLock = \{\} \}/)
      # Arm 1 emits Done.
      expect(out).to match(/1 => \{[\s\S]*?return \.\{ \.Done = \{\} \}/)
    end
  end

  describe "three-segment NEXT-CHAIN shape" do
    # Two consecutive NEXTs -> 3 segments. Both use FsmTailRegisterYield.
    let(:descr) {
      lambda do |sp_field|
        MIR::SuspendDescriptor.new(
          [MIR::ExprStmt.new(MIR::Lit.new("setup_#{sp_field}()"), false)],
          [MIR::ExprStmt.new(MIR::Lit.new("bind_#{sp_field}()"), false)],
          MIR::FsmTailRegisterYield.new(nil, "register_#{sp_field}()", "WaitForLock"),
          ["#{sp_field}: P = undefined,"],
          nil,
          nil,
          false,
        )
      end
    }

    let(:segment_specs) {
      [
        {
          index: 0, body_stmts: [], descriptor: descr.call("sp_1"), fn_name: "runSeg0",
          tail: FsmTransform::Segments::NextSuspend.new(Object.new, nil),
        },
        {
          index: 1, body_stmts: [], descriptor: descr.call("sp_2"), fn_name: "runSeg1",
          tail: FsmTransform::Segments::NextSuspend.new(Object.new, nil),
        },
        {
          index: 2, body_stmts: [], descriptor: nil, fn_name: "runSeg2",
          tail: FsmTransform::Segments::Done.new(nil),
        },
      ]
    }

    it "emits N+1 dispatch arms with RegisterYield tails on the suspends" do
      out = fsm_code(FsmTransform::Emit.build_fsm_unified(
        base_ctx, segment_specs, [], lowering_double))
      expect(out).to include("if (register_sp_1())")
      expect(out).to include("if (register_sp_2())")
      expect(out).to include("0 => {")
      expect(out).to include("1 => {")
      expect(out).to include("2 => {")
    end

    it "places each suspend's ctx_field_decls in the ctx struct" do
      out = fsm_code(FsmTransform::Emit.build_fsm_unified(
        base_ctx, segment_specs, [], lowering_double))
      expect(out).to include("sp_1: P = undefined,")
      expect(out).to include("sp_2: P = undefined,")
    end
  end

  describe "loop graph (B2-LOOP)" do
    let(:descriptor) {
      MIR::SuspendDescriptor.new(
        [MIR::ExprStmt.new(MIR::Lit.new("setupNext()"), false)],
        [MIR::ExprStmt.new(MIR::Lit.new("bindNext()"), false)],
        MIR::FsmTailRegisterYield.new(nil, "registerWaiter()", "WaitForLock"),
        ["sp: P = undefined,"],
        nil,
        nil,
        false,
      )
    }

    let(:segment_specs) {
      [
        # 0: pre -> Goto(1)
        {
          index: 0, body_stmts: [MIR::ExprStmt.new(MIR::Lit.new("runPre()"), false)],
          tail: FsmTransform::Segments::Goto.new(1),
          descriptor: nil, fn_name: "runPre",
        },
        # 1: cond -> CondBranch(cond, 2, 4)
        {
          index: 1, body_stmts: [],
          tail: FsmTransform::Segments::CondBranch.new(double_with_zig("hasNext"), 2, 4),
          descriptor: nil, fn_name: "runCond",
        },
        # 2: loop_pre -> NextSuspend
        {
          index: 2, body_stmts: [MIR::ExprStmt.new(MIR::Lit.new("runLoopPre()"), false)],
          tail: FsmTransform::Segments::NextSuspend.new(Object.new, nil),
          descriptor: descriptor, fn_name: "runLoopPre",
        },
        # 3: loop_post -> LoopBack(1)
        {
          index: 3, body_stmts: [MIR::ExprStmt.new(MIR::Lit.new("runLoopPost()"), false)],
          tail: FsmTransform::Segments::LoopBack.new(1),
          descriptor: nil, fn_name: "runLoopPost",
        },
        # 4: post -> Done
        {
          index: 4, body_stmts: [MIR::ExprStmt.new(MIR::Lit.new("runPost()"), false)],
          tail: FsmTransform::Segments::Done.new(nil),
          descriptor: nil, fn_name: "runPost",
        },
      ]
    }

    def double_with_zig(zig)
      Struct.new(:cond_zig).new(zig)
    end

    it "emits CondJump for the cond head and LoopBack for the back-edge" do
      out = fsm_code(FsmTransform::Emit.build_fsm_unified(
        base_ctx, segment_specs, [], lowering_double))
      # arm 1 is the cond branch
      expect(out).to match(/1 => \{[\s\S]*?if \(hasNext\)/)
      # arm 3 jumps back to step 1
      expect(out).to match(/3 => \{[\s\S]*?step = 1;/)
    end

    it "concatenates bind_stmts onto runLoopPost (after suspend)" do
      out = fsm_code(FsmTransform::Emit.build_fsm_unified(
        base_ctx, segment_specs, [], lowering_double))
      runlooppost = out[/fn runLoopPost.*?fn runPost/m]
      expect(runlooppost).to include("bindNext()")
      expect(runlooppost).to include("runLoopPost()")
    end
  end
end
