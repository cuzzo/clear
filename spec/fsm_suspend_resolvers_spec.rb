require 'bundler/setup'
require 'set'
require_relative '../src/ast/lexer'
require_relative '../src/ast/parser'
require_relative '../src/ast/type'
require_relative '../src/mir/mir'
require_relative '../src/mir/fsm_ops'
require_relative '../src/mir/fsm_transform/segments'
require_relative '../src/mir/fsm_transform/suspend_resolvers'
require_relative '../src/annotator-helpers/intrinsic_registry'

# Tests for FsmTransform::SuspendResolvers, the per-suspend-kind
# resolvers that turn a Segments::*Suspend tail into a
# kind-agnostic MIR::SuspendDescriptor consumed by the unified
# FSM emit (under construction).

RSpec.describe FsmTransform::SuspendResolvers do
  # Minimal lowering double: implements .lower() by returning the
  # input unchanged (resolvers don't introspect the lowered form,
  # they just embed it as MIR; identity is enough for shape tests).
  let(:lowering) {
    Class.new {
      def lower(node); node; end
    }.new
  }

  let(:ctx) { { id: 0, bg_rt: "__rt_bg0" } }

  describe "resolve_io" do
    # Build a fake stdlib_def with a sleep-like fsm_setup template.
    # Production stamps go through IntrinsicRegistry.fs -> a typed
    # FunctionSignature; this unit test constructs the same shape.
    let(:stdlib_def) {
      IntrinsicRegistry.fs({
        suspends: true,
        fsm_setup: [
          FsmOps::StmtCall.new(
            "__FSM_CTX.rt.getSched().fsmSleepTask",
            [
              FsmOps::AddrOf.new(FsmOps::SubField.new(FsmOps::StateField.new("task"), "task")),
              FsmOps::ArgRef.new(0),
            ],
            true,
          ),
        ],
        fsm_state_decls: [
          FsmOps::StateFieldDecl.new("rf_fd", "i32", "-1"),
        ],
      })
    }

    let(:call_node) {
      Struct.new(:args, :receiver, :matched_stdlib_def, :full_type).new(
        [Struct.new(:value).new(100)], nil, stdlib_def, :Void)
    }

    let(:io_tail) {
      FsmTransform::Segments::IoSuspend.new(call_node, stdlib_def, nil)
    }

    it "produces a SuspendDescriptor" do
      d = FsmTransform::SuspendResolvers.resolve(
        FsmTransform::Segments::Segment.new(0, [], io_tail), ctx, lowering)
      expect(d).to be_a(MIR::SuspendDescriptor)
    end

    it "lowers the fsm_setup template into setup_stmts (typed MIR)" do
      d = FsmTransform::SuspendResolvers.resolve(
        FsmTransform::Segments::Segment.new(0, [], io_tail), ctx, lowering)
      expect(d.setup_stmts).not_to be_empty
      expect(d.setup_stmts.first).to be_a(MIR::ExprStmt)
    end

    it "renders fsm_state_decls into ctx_field_decls" do
      d = FsmTransform::SuspendResolvers.resolve(
        FsmTransform::Segments::Segment.new(0, [], io_tail), ctx, lowering)
      expect(d.ctx_field_decls).to include(/rf_fd: i32 = -1/)
    end

    it "uses FsmTailYield(WaitForLock) -- IO always yields after setup" do
      d = FsmTransform::SuspendResolvers.resolve(
        FsmTransform::Segments::Segment.new(0, [], io_tail), ctx, lowering)
      expect(d.tail).to be_a(MIR::FsmTailYield)
      expect(d.tail.yield_reason).to eq("WaitForLock")
    end

    it "raises when stdlib_def is missing" do
      bad_tail = FsmTransform::Segments::IoSuspend.new(call_node, nil, nil)
      expect {
        FsmTransform::SuspendResolvers.resolve(
          FsmTransform::Segments::Segment.new(0, [], bad_tail), ctx, lowering)
      }.to raise_error(ArgumentError, /missing stdlib_def/)
    end
  end

  describe "resolve_next" do
    # Fake AST::Identifier as the promise expr. The resolver lowers
    # via lowering.lower(); our double returns the input unchanged.
    let(:promise_ast) {
      ast = Object.new
      def ast.full_type; nil; end
      ast
    }

    let(:next_tail_with_var) {
      FsmTransform::Segments::NextSuspend.new(promise_ast, "x")
    }
    let(:next_tail_bare) {
      FsmTransform::Segments::NextSuspend.new(promise_ast, nil)
    }

    it "uses FsmTailRegisterYield (NEXT registers on Promise.wg)" do
      d = FsmTransform::SuspendResolvers.resolve(
        FsmTransform::Segments::Segment.new(0, [], next_tail_with_var),
        ctx, lowering, susp_idx: 1)
      expect(d.tail).to be_a(MIR::FsmTailRegisterYield)
      expect(d.tail.register_zig).to include("registerFsmWaiter")
      expect(d.tail.yield_reason).to eq("WaitForLock")
    end

    it "stashes the promise expr into ctx.sp_<K> in setup_stmts" do
      d = FsmTransform::SuspendResolvers.resolve(
        FsmTransform::Segments::Segment.new(0, [], next_tail_with_var),
        ctx, lowering, susp_idx: 1)
      expect(d.setup_stmts.first).to be_a(MIR::Set)
      target = d.setup_stmts.first.target
      expect(target).to be_a(MIR::FieldGet)
      expect(target.field).to eq("sp_1")
    end

    it "declares a Promise field in ctx_field_decls" do
      d = FsmTransform::SuspendResolvers.resolve(
        FsmTransform::Segments::Segment.new(0, [], next_tail_with_var),
        ctx, lowering, susp_idx: 1)
      expect(d.ctx_field_decls.first).to match(/sp_1:.*= undefined/)
    end

    it "reports the bound result_var" do
      d = FsmTransform::SuspendResolvers.resolve(
        FsmTransform::Segments::Segment.new(0, [], next_tail_with_var),
        ctx, lowering, susp_idx: 1)
      expect(d.result_var).to eq("x")
    end

    it "binds NEXT results with structured MIR instead of RawZig" do
      d = FsmTransform::SuspendResolvers.resolve(
        FsmTransform::Segments::Segment.new(0, [], next_tail_with_var),
        ctx, lowering, susp_idx: 1)
      expect(d.bind_stmts).to contain_exactly(
        an_instance_of(MIR::Let),
        an_instance_of(MIR::Set),
      )
      expect(d.bind_stmts).not_to include(an_instance_of(MIR::RawZig))
      expect(d.bind_stmts.first.init).to be_a(MIR::TryCatch)
      expect(d.bind_stmts.first.init.expr).to be_a(MIR::MethodCall)
      expect(d.bind_stmts.first.init.expr.method).to eq("finishFsmNext")
    end

    it "leaves result_var nil for bare NEXT" do
      d = FsmTransform::SuspendResolvers.resolve(
        FsmTransform::Segments::Segment.new(0, [], next_tail_bare),
        ctx, lowering, susp_idx: 1)
      expect(d.result_var).to be_nil
    end

    it "still consumes bare NEXT with structured MIR" do
      d = FsmTransform::SuspendResolvers.resolve(
        FsmTransform::Segments::Segment.new(0, [], next_tail_bare),
        ctx, lowering, susp_idx: 1)
      expect(d.bind_stmts).to contain_exactly(an_instance_of(MIR::ExprStmt))
      expect(d.bind_stmts.first.expr).to be_a(MIR::TryCatch)
      expect(d.bind_stmts.first.expr.expr.method).to eq("finishFsmNext")
    end
  end

  describe "resolve dispatch" do
    it "raises for an unknown suspend kind" do
      bad_tail = Struct.new(:_).new(nil)
      expect {
        FsmTransform::SuspendResolvers.resolve(
          FsmTransform::Segments::Segment.new(0, [], bad_tail),
          ctx, lowering)
      }.to raise_error(ArgumentError, /no resolver for/)
    end
  end
end
