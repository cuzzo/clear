require 'bundler/setup'
require 'set'
require_relative '../src/ast/lexer'
require_relative '../src/ast/parser'
require_relative '../src/ast/type'
require_relative '../src/mir/mir'
require_relative '../src/mir/fsm_ops'
require_relative '../src/mir/fsm_transform/segments'
require_relative '../src/mir/fsm_transform'
require_relative '../src/mir/fsm_transform/suspend_resolvers'
require_relative '../src/annotator/helpers/intrinsic_registry'

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

  def fsm_ctx(overrides = {})
    raw = {
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
      promoted_decls: [],
      capture_inits: [],
      captured: {},
      capture_close_plans: {},
      pointer_captures: Set.new,
      extra_ctx_fields: [],
      recursive_promoted_names: [],
      fresh_heap_cleanup_names: [],
      arena_init_flag: false,
      is_void: false,
      pin_mode: false,
      parallel: false,
      profile_site_id: nil,
      profile_line: nil,
      profile_column: nil,
    }.merge(overrides)
    FsmTransform::Emit::FsmEmitContext.new(
      id: raw.fetch(:id),
      bg_rt: raw.fetch(:bg_rt),
      blk_label: raw.fetch(:blk_label),
      ctx_type: raw.fetch(:ctx_type),
      promise_zig: raw.fetch(:promise_zig),
      capture_fields: FsmTransform.coerce_context_fields(raw.fetch(:capture_fields)),
      alloc_var: raw.fetch(:alloc_var),
      promise_var: raw.fetch(:promise_var),
      ctx_var: raw.fetch(:ctx_var),
      rt_name: raw.fetch(:rt_name),
      promoted_decls: FsmTransform.coerce_promoted_decls(raw.fetch(:promoted_decls)),
      capture_inits: FsmTransform.coerce_context_inits(raw.fetch(:capture_inits)),
      captured: raw.fetch(:captured),
      capture_close_plans: raw.fetch(:capture_close_plans),
      pointer_captures: raw.fetch(:pointer_captures),
      extra_ctx_fields: FsmTransform.coerce_context_fields(raw.fetch(:extra_ctx_fields)),
      recursive_promoted_names: raw.fetch(:recursive_promoted_names),
      fresh_heap_cleanup_names: raw.fetch(:fresh_heap_cleanup_names),
      arena_init_flag: raw.fetch(:arena_init_flag),
      is_void: raw.fetch(:is_void),
      pin_mode: raw.fetch(:pin_mode),
      parallel: raw.fetch(:parallel),
      profile_site_id: raw.fetch(:profile_site_id),
      profile_line: raw.fetch(:profile_line),
      profile_column: raw.fetch(:profile_column),
    )
  end

  def field_named(fields, name)
    fields.find { |field| field.name == name }
  end

  let(:ctx) { fsm_ctx }

  describe "resolve_io" do
    # Build a fake stdlib_def with a sleep-like fsm_setup template.
    # Production stamps go through IntrinsicRegistry.fs -> a typed
    # FunctionSignature; this unit test constructs the same shape.
    let(:stdlib_def) {
      IntrinsicRegistry.fs({
        suspends: true,
        fsm_setup: [
          FsmOps::StmtCall.new(
            FsmOps::FunctionPath.context(["rt", "getSched()", "fsmSleepTask"]),
            [
              FsmOps::AddrOf.new(FsmOps::SubField.new(FsmOps::StateField.new("task"), "task")),
              FsmOps::ArgRef.new(0),
            ],
            true,
          ),
        ],
        fsm_state_decls: [
          FsmOps::StateFieldDecl.new(name: "rf_fd", zig_type: "i32", default_value: MIR::Lit.new("-1")),
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
      field = field_named(d.ctx_field_decls, "rf_fd")
      expect(field&.type_zig).to eq("i32")
      expect(field&.default_value&.value).to eq("-1")
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

    it "consumes finish values when IO has no bound result variable" do
      finish_value_def = IntrinsicRegistry.fs({
        suspends: true,
        fsm_setup: [],
        fsm_finish_value: FsmOps::LocalRef.new("__finished"),
      })
      tail = FsmTransform::Segments::IoSuspend.new(call_node, finish_value_def, nil)

      d = FsmTransform::SuspendResolvers.resolve(
        FsmTransform::Segments::Segment.new(0, [], tail), ctx, lowering)

      expect(d.bind_stmts).to contain_exactly(an_instance_of(MIR::ExprStmt))
      expect(d.bind_stmts.first.expr).to eq(MIR::Ident.new("__finished"))
    end

    it "binds IO result values into the FSM context" do
      finish_value_def = IntrinsicRegistry.fs({
        suspends: true,
        fsm_setup: [],
        fsm_finish_value: FsmOps::LocalRef.new("__finished"),
      })
      value_call = Struct.new(:args, :receiver, :matched_stdlib_def, :full_type).new(
        [], nil, finish_value_def, :String
      )
      tail = FsmTransform::Segments::IoSuspend.new(value_call, finish_value_def, "content")

      d = FsmTransform::SuspendResolvers.resolve(
        FsmTransform::Segments::Segment.new(0, [], tail), ctx, lowering)

      field = field_named(d.ctx_field_decls, "content")
      expect(field&.type_zig).to eq("[]const u8")
      expect(field&.default_value).to be_a(MIR::Undef)
      expect(d.result_needs_cleanup).to eq(true)
      expect(d.bind_stmts).to include(an_instance_of(MIR::Set))
      set = d.bind_stmts.grep(MIR::Set).first
      expect(set.target).to be_a(MIR::FieldGet)
      expect(set.target.field).to eq("content")
    end

    it "does not add owned-result cleanup for IO finish values that alias finalized state" do
      read_def = IntrinsicRegistry.fs({
        suspends: true,
        fsm_setup: [],
        fsm_finish_value: FsmOps::SliceUntilIntCast.new(
          FsmOps::StateField.new("rf_buf"),
          FsmOps::SubField.new(FsmOps::StateField.new("rf_waiter"), "result"),
        ),
        fsm_state_finalize: [FsmOps::DeferFreeField.new("rf_buf")],
      })
      value_call = Struct.new(:args, :receiver, :matched_stdlib_def, :full_type).new(
        [], nil, read_def, :String
      )
      tail = FsmTransform::Segments::IoSuspend.new(value_call, read_def, "content")

      d = FsmTransform::SuspendResolvers.resolve(
        FsmTransform::Segments::Segment.new(0, [], tail), ctx, lowering)

      expect(d.result_needs_cleanup).to eq(false)
      expect(field_named(d.ctx_field_decls, "__owned_content_init")).to be_nil
      guard_writes = d.bind_stmts.grep(MIR::Set).select { |stmt|
        stmt.target.is_a?(MIR::FieldGet) && stmt.target.field == "__owned_content_init"
      }
      expect(guard_writes).to be_empty
    end
  end

  describe "resolve_next" do
    # Fake AST::Identifier as the promise expr. The resolver lowers
    # via lowering.lower(); our double returns the input unchanged.
    let(:promise_ast) {
      ast = Object.new
      def ast.full_type; Type.new(:"~Int64"); end
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
      expect(d.tail.register_expr).to be_a(MIR::MethodCall)
      expect(MIREmitter.new.emit(d.tail.register_expr)).to include("registerFsmWaiter")
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
      field = d.ctx_field_decls.first
      expect(field.name).to eq("sp_1")
      expect(field.type_zig).to include("CheatLib.Promise")
      expect(field.default_value).to be_a(MIR::Undef)
    end

    it "reports the bound result_var" do
      d = FsmTransform::SuspendResolvers.resolve(
        FsmTransform::Segments::Segment.new(0, [], next_tail_with_var),
        ctx, lowering, susp_idx: 1)
      expect(d.result_var).to eq("x")
    end

    it "binds NEXT results with structured MIR" do
      d = FsmTransform::SuspendResolvers.resolve(
        FsmTransform::Segments::Segment.new(0, [], next_tail_with_var),
        ctx, lowering, susp_idx: 1)
      expect(d.bind_stmts).to contain_exactly(
        an_instance_of(MIR::Let),
        an_instance_of(MIR::Set),
      )
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

    it "handles malformed non-promise NEXT types as a defensive fallback" do
      plain_ast = Object.new
      def plain_ast.full_type; Type.new(:Int64); end

      d = FsmTransform::SuspendResolvers.resolve(
        FsmTransform::Segments::Segment.new(
          0, [], FsmTransform::Segments::NextSuspend.new(plain_ast, nil)
        ),
        ctx, lowering, susp_idx: 2)

      expect(d.result_zig_type).to be_nil
      expect(d.bind_stmts).to contain_exactly(an_instance_of(MIR::ExprStmt))
    end

    it "tracks cleanup-bearing NEXT results with owned-result guards" do
      string_promise = Object.new
      def string_promise.full_type; Type.new(:"~String"); end

      d = FsmTransform::SuspendResolvers.resolve(
        FsmTransform::Segments::Segment.new(
          0, [], FsmTransform::Segments::NextSuspend.new(string_promise, "payload")
        ),
        ctx, lowering, susp_idx: 3)

      expect(d.result_needs_cleanup).to eq(true)
      guard = field_named(d.ctx_field_decls, "__owned_payload_init")
      expect(guard&.type_zig).to eq("bool")
      expect(guard&.default_value&.value).to eq("false")
      expect(d.bind_stmts).to include(
        an_object_having_attributes(
          target: an_object_having_attributes(field: "__owned_payload_init"),
          value: an_object_having_attributes(value: "true"),
        ),
      )
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

    it "treats type predicate failures as non-cleanup defensive fallbacks" do
      bad_type = Type.new(:String)
      bad_type.define_singleton_method(:string?) { raise "bad type" }

      expect(FsmTransform::SuspendResolvers.ownership_bearing_result_type?(bad_type, lowering))
        .to eq(false)
    end
  end
end
