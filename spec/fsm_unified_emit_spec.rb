require 'bundler/setup'
require 'set'
require_relative '../src/mir/mir'
require_relative '../src/mir/fsm_ops'
require_relative '../src/mir/fsm_transform'
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
  def fsm_body_items(stmts)
    stmts.map do |stmt|
      FsmTransform::Emit.fsm_body_mir_item(stmt)
    end
  end

  def fsm_code(result)
    expect(result).to be_a(MIR::FsmLoweringResult)
    FsmWrapperEmitter.render(result.body)
  end

  def ctx_decl(name, type_zig, default_value = MIR::Undef.new(nil))
    MIR::ContextFieldDecl.new(name: name, type_zig: type_zig, default_value: default_value)
  end

  def fsm_spec(attrs)
    FsmTransform::Emit::FsmSegmentSpec.new(
      index: attrs.fetch(:index),
      prologue_stmts: fsm_body_items(attrs.fetch(:prologue_stmts, [])),
      body_stmts: fsm_body_items(attrs.fetch(:body_stmts, [])),
      structure_stmts: attrs.fetch(:structure_stmts, []),
      tail: attrs.fetch(:tail),
      descriptor: attrs[:descriptor],
      fsm_result_transfer_facts: attrs.fetch(:fsm_result_transfer_facts, []),
      fn_name: attrs[:fn_name],
      suppress_runtime_ref: attrs.fetch(:suppress_runtime_ref, false),
      err_cleanups: attrs.fetch(:err_cleanups, []),
      pre_body_skip: attrs[:pre_body_skip],
      pre_body_stmts: attrs[:pre_body_stmts] || [],
      extra_prologue_stmts: attrs[:extra_prologue_stmts] || [],
    )
  end

  def fsm_specs(attrs)
    attrs.map { |spec| fsm_spec(spec) }
  end

  def build_unified(ctx, specs, promoted_field_decls, lowering)
    FsmTransform::Emit.build_fsm_unified(
      ctx, fsm_specs(specs), promoted_field_decls, lowering)
  end

  let(:lowering_double) {
    Class.new {
      def capture_inits_fsm(_); ""; end
    }.new
  }

  let(:base_ctx) {
    FsmTransform::Emit::FsmEmitContext.new(
      id: 0,
      bg_rt: "__rt_bg0",
      blk_label: "__bg0",
      ctx_type: "__BgCtx0",
      promise_zig: "CheatLib.Promise(i64)",
      capture_fields: [],
      alloc_var: "__bg0_alloc",
      promise_var: "__bg0_promise",
      ctx_var: "__bg0_ctx",
      rt_name: "rt",
      pin_mode: false,
      promoted_decls: [],
      capture_inits: [],
      captured: {},
      capture_close_zig: {},
      pointer_captures: Set.new,
      extra_ctx_fields: [],
      recursive_promoted_names: [],
      fresh_heap_cleanup_names: [],
      arena_init_flag: false,
      is_void: false,
      parallel: false,
      profile_site_id: nil,
      profile_line: nil,
      profile_column: nil,
    )
  }

  it "rejects unexpanded lock tails in dispatch assembly" do
    spec = {
      index:      0,
      body_stmts: [],
      tail:       FsmTransform::Segments::LockSuspend.new(nil, {}, [], 0, 1),
      descriptor: nil,
    }

    expect {
      typed_spec = fsm_spec(spec)
      FsmTransform::Emit.build_dispatch_tail(typed_spec, 0, [typed_spec], 0)
    }.to raise_error(ArgumentError, /Unsupported segment tail/)
  end

  it "routes descriptor binds through prebuilt MIR jump tail next_step values" do
    descriptor = MIR::SuspendDescriptor.new(
      [],
      [MIR::ExprStmt.new(MIR::Lit.new("bindLegacy()"), false)],
      MIR::FsmTailYield.new(2, "WaitForLock"),
      [],
      nil,
      nil,
      false,
    )
    segment_specs = [
      {
        index: 0,
        body_stmts: [MIR::ExprStmt.new(MIR::Lit.new("beforeLegacy()"), false)],
        tail: MIR::FsmTailJump.new(2),
        descriptor: descriptor,
        fn_name: "runLegacy0",
      },
      {
        index: 2,
        body_stmts: [MIR::ExprStmt.new(MIR::Lit.new("afterLegacy()"), false)],
        tail: MIR::FsmTailDone.new(nil),
        descriptor: nil,
        fn_name: "runLegacy2",
      },
    ]

    out = fsm_code(build_unified(base_ctx, segment_specs, [], lowering_double))

    run_after = out[/fn runLegacy2.*?fn resumeFn/m]
    expect(run_after).to include("bindLegacy()")
    expect(run_after).to include("afterLegacy()")
  end

  it "runs incoming descriptor binds before structural lock-try tails" do
    descriptor = MIR::SuspendDescriptor.new(
      [MIR::ExprStmt.new(MIR::Lit.new("setupNext()"), false)],
      [MIR::ExprStmt.new(MIR::Lit.new("finishNext()"), false)],
      MIR::FsmTailRegisterYield.new(nil, MIR::Call.new("registerNext", [], false), "WaitForLock"),
      [ctx_decl("sp_1", "P")],
      nil,
      nil,
      false,
    )
    segment_specs = [
      {
        index: 0,
        body_stmts: [],
        tail: FsmTransform::Segments::NextSuspend.new(Object.new, nil, 2),
        descriptor: descriptor,
        fn_name: "runSeg0",
      },
      {
        index: 2,
        body_stmts: [],
        tail: MIR::FsmTailLockTry.new("tryLockForFsm", "__ctx_0.lock", 3, 4, 5),
        descriptor: nil,
        fn_name: nil,
      },
    ]

    out = fsm_code(build_unified(base_ctx, segment_specs, [], lowering_double))

    expect(out).to include("fn runSeg2")
    expect(out).to include("finishNext()")
    expect(out).to match(/2 => \{[\s\S]*@This\(\)\.runSeg2\(__ctx_0\)[\s\S]*const __lock_r = __ctx_0\.lock\.tryLockForFsm/)
  end

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
        [ctx_decl("rf_fd", "i32", MIR::Lit.new("-1"))],
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
      out = fsm_code(build_unified(base_ctx, segment_specs, [], lowering_double))
      expect(out).to include("__bg0: {")
    end

    it "concatenates the descriptor's setup_stmts onto seg 0's body" do
      out = fsm_code(build_unified(base_ctx, segment_specs, [], lowering_double))
      runstep0 = out[/fn runStep0.*?fn runStep1/m]
      expect(runstep0).to include("preStmt()")
      expect(runstep0).to include("registerWaiter()")
    end

    it "concatenates the descriptor's bind_stmts onto seg 1's body" do
      out = fsm_code(build_unified(base_ctx, segment_specs, [], lowering_double))
      runstep1 = out[/fn runStep1.*?fn resumeFn/m]
      expect(runstep1).to include("__waiter.result")
      expect(runstep1).to include("postStmt()")
    end

    it "places suspend ctx_field_decls in the ctx struct" do
      out = fsm_code(build_unified(base_ctx, segment_specs, [], lowering_double))
      expect(out).to include("rf_fd: i32 = -1,")
    end

    it "emits dispatch with FsmTailYield and FsmTailDone" do
      out = fsm_code(build_unified(base_ctx, segment_specs, [], lowering_double))
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
          MIR::FsmTailRegisterYield.new(nil, MIR::Call.new("register_#{sp_field}", [], false), "WaitForLock"),
          [ctx_decl(sp_field, "P")],
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
      out = fsm_code(build_unified(base_ctx, segment_specs, [], lowering_double))
      expect(out).to include("if (register_sp_1())")
      expect(out).to include("if (register_sp_2())")
      expect(out).to include("0 => {")
      expect(out).to include("1 => {")
      expect(out).to include("2 => {")
    end

    it "places each suspend's ctx_field_decls in the ctx struct" do
      out = fsm_code(build_unified(base_ctx, segment_specs, [], lowering_double))
      expect(out).to include("sp_1: P = undefined,")
      expect(out).to include("sp_2: P = undefined,")
    end
  end

  describe "loop graph (B2-LOOP)" do
    let(:descriptor) {
      MIR::SuspendDescriptor.new(
        [MIR::ExprStmt.new(MIR::Lit.new("setupNext()"), false)],
        [MIR::ExprStmt.new(MIR::Lit.new("bindNext()"), false)],
        MIR::FsmTailRegisterYield.new(nil, MIR::Call.new("registerWaiter", [], false), "WaitForLock"),
        [ctx_decl("sp", "P")],
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
      MIR::Ident.new(zig)
    end

    it "emits CondJump for the cond head and LoopBack for the back-edge" do
      out = fsm_code(build_unified(base_ctx, segment_specs, [], lowering_double))
      # arm 1 is the cond branch
      expect(out).to match(/1 => \{[\s\S]*?if \(hasNext\)/)
      # arm 3 jumps back to step 1
      expect(out).to match(/3 => \{[\s\S]*?step = 1;/)
    end

    it "concatenates bind_stmts onto runLoopPost (after suspend)" do
      out = fsm_code(build_unified(base_ctx, segment_specs, [], lowering_double))
      runlooppost = out[/fn runLoopPost.*?fn runPost/m]
      expect(runlooppost).to include("bindNext()")
      expect(runlooppost).to include("runLoopPost()")
    end
  end
end
