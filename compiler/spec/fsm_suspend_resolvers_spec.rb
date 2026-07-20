require 'bundler/setup'
require 'set'
require_relative '../ruby/ast/lexer' unless defined?(Lexer)
require_relative '../ruby/ast/parser' unless defined?(ClearParser)
require_relative '../ruby/ast/type' unless defined?(Type)
require_relative '../ruby/mir/mir' unless defined?(MIR::StdlibDefFsCoercion)
require_relative '../ruby/mir/fsm_ops' unless defined?(FsmOps::Lowerer)
require_relative '../ruby/backends/mir_emitter' unless defined?(MIREmitter)
require_relative '../ruby/mir/fsm_transform/segments' unless defined?(FsmTransform::Segments::SplitResult)
require_relative '../ruby/mir/fsm_transform' unless defined?(FsmTransform::PromotedLocalFact)
require_relative '../ruby/mir/fsm_transform/suspend_resolvers' unless defined?(FsmTransform::SuspendResolvers)
require_relative '../ruby/annotator/helpers/intrinsic_registry' unless defined?(IntrinsicRegistry)

# Tests for FsmTransform::SuspendResolvers, the per-suspend-kind
# resolvers that turn a Segments::*Suspend tail into a
# kind-agnostic MIR::SuspendDescriptor consumed by the unified
# FSM emit (under construction).

RSpec.describe FsmTransform::SuspendResolvers do
  # Minimal lowering double: maps the AST-like fixtures to the same
  # structural MIR nodes the production lowerer supplies.
  let(:lowering) {
    Class.new {
      include FsmTransform::LoweringProtocol

      def lower(node)
        return MIR::Ident.new(node.name) if node.is_a?(AST::Identifier)
        return MIR::Lit.new(node.value.to_s) if node.respond_to?(:value)

        MIR::Ident.new("__fixture")
      end
    }.new
  }

  def fsm_ctx(overrides = {})
    raw = {
      id: 0,
      bg_rt: "__rt_bg0",
      blk_label: "__bg0",
      ctx_type: "__BgCtx0",
      promise_zig: "CheatLib.Promise(i64)",
      async_result_shape: AsyncResultShape.promise(Type.new(:Int64)),
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
    captured = raw.fetch(:captured).transform_values do |type|
      type.is_a?(Type) ? type : Type.new(:Any)
    end
    FsmTransform::Emit::FsmEmitContext.new(
      id: raw.fetch(:id),
      bg_rt: raw.fetch(:bg_rt),
      blk_label: raw.fetch(:blk_label),
      ctx_type: raw.fetch(:ctx_type),
      promise_zig: raw.fetch(:promise_zig),
      async_result_shape: raw.fetch(:async_result_shape),
      capture_fields: FsmTransform.coerce_context_fields(raw.fetch(:capture_fields)),
      alloc_var: raw.fetch(:alloc_var),
      promise_var: raw.fetch(:promise_var),
      ctx_var: raw.fetch(:ctx_var),
      rt_name: raw.fetch(:rt_name),
      promoted_decls: FsmTransform.coerce_promoted_decls(raw.fetch(:promoted_decls)),
      capture_inits: FsmTransform.coerce_context_inits(raw.fetch(:capture_inits)),
      captured: captured,
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

  def typed_identifier(name, type)
    AST::Identifier.new(nil, name).tap { |node| node.full_type = type }
  end

  def field_get_path(expr)
    path = []
    current = expr
    while current.is_a?(MIR::FieldGet)
      path.unshift(current.field)
      current = current.object
    end
    path.unshift(current.name) if current.is_a?(MIR::Ident)
    path
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
      AST::FuncCall.new(nil, "sleep", [AST::Literal.new(100, :Int64)]).tap do |call|
        call.full_type = :Void
      end
    }

    let(:io_tail) {
      FsmTransform::Segments::IoSuspend.new(call_node, stdlib_def, nil)
    }

    it "produces a SuspendDescriptor" do
      d = FsmTransform::SuspendResolvers.resolve(
        FsmTransform::Segments::Segment.new(0, [], io_tail), ctx, lowering)
      expect(d).to be_a(MIR::SuspendDescriptor)
    end

    it "leaves IO bind/result data empty when there is no finish value" do
      d = FsmTransform::SuspendResolvers.resolve(
        FsmTransform::Segments::Segment.new(0, [], io_tail), ctx, lowering)

      expect(d.bind_stmts).to be_empty
      expect(d.result_var).to be_nil
      expect(d.result_zig_type).to be_nil
      expect(d.result_needs_cleanup).to eq(false)
    end

    it "accepts function calls with no arguments" do
      no_args_def = IntrinsicRegistry.fs({ suspends: true, fsm_setup: [] })
      no_args_call = AST::FuncCall.new(nil, "yield_now", []).tap { |call| call.full_type = :Void }
      tail = FsmTransform::Segments::IoSuspend.new(no_args_call, no_args_def, nil)

      d = FsmTransform::SuspendResolvers.resolve(
        FsmTransform::Segments::Segment.new(0, [], tail), ctx, lowering)

      expect(d.setup_stmts).to be_empty
      expect(d.bind_stmts).to be_empty
    end

    it "accepts method calls with no arguments" do
      no_args_def = IntrinsicRegistry.fs({ suspends: true, fsm_setup: [] })
      receiver = typed_identifier("stream", :Stream)
      no_args_call = AST::MethodCall.new(nil, receiver, "flush", [])
      no_args_call.full_type = :Void
      tail = FsmTransform::Segments::IoSuspend.new(no_args_call, no_args_def, nil)

      d = FsmTransform::SuspendResolvers.resolve(
        FsmTransform::Segments::Segment.new(0, [], tail), ctx, lowering)

      expect(d.setup_stmts).to be_empty
      expect(d.bind_stmts).to be_empty
    end

    it "treats stdlib entries without emit metadata as empty IO templates" do
      no_emit_def = Struct.new(:emit).new(nil)
      call = Struct.new(:args, :receiver, :matched_stdlib_def, :full_type).new(
        [], nil, no_emit_def, :Void
      )
      tail = FsmTransform::Segments::IoSuspend.new(call, no_emit_def, nil)

      d = FsmTransform::SuspendResolvers.resolve(
        FsmTransform::Segments::Segment.new(0, [], tail), ctx, lowering)

      expect(d.setup_stmts).to be_empty
      expect(d.bind_stmts).to be_empty
      expect(d.ctx_field_decls).to be_empty
      expect(d.tail.yield_reason).to eq("WaitForLock")
    end

    it "lowers the fsm_setup template into setup_stmts (typed MIR)" do
      d = FsmTransform::SuspendResolvers.resolve(
        FsmTransform::Segments::Segment.new(0, [], io_tail), ctx, lowering)
      expect(d.setup_stmts).not_to be_empty
      expect(d.setup_stmts.first).to be_a(MIR::ExprStmt)
    end

    it "lowers IO call arguments before substituting ArgRef setup templates" do
      arg_source = Object.new
      arg_mir = MIR::Lit.new("321")
      lowering_spy = Class.new {
        include FsmTransform::LoweringProtocol

        attr_reader :seen
        define_method(:initialize) { |value| @value = value }
        define_method(:lower) { |node| @seen = node; @value }
      }.new(arg_mir)
      arg_def = IntrinsicRegistry.fs({
        suspends: true,
        fsm_setup: [
          FsmOps::AssignField.new("arg_copy", FsmOps::ArgRef.new(0)),
        ],
      })
      value_call = Struct.new(:args, :receiver, :matched_stdlib_def, :full_type).new(
        [arg_source], nil, arg_def, :Void
      )
      tail = FsmTransform::Segments::IoSuspend.new(value_call, arg_def, nil)

      d = FsmTransform::SuspendResolvers.resolve(
        FsmTransform::Segments::Segment.new(0, [], tail), ctx, lowering_spy)

      expect(lowering_spy.seen).to equal(arg_source)
      expect(d.setup_stmts).to contain_exactly(an_instance_of(MIR::Set))
      expect(d.setup_stmts.first.target).to eq(MIR::FieldGet.new(MIR::Ident.new("__ctx_0"), "arg_copy"))
      expect(d.setup_stmts.first.value).to eq(arg_mir)
      expect(d.setup_stmts.first.needs_field_cleanup).to eq(false)
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
      expect(d.bind_stmts.first.discard).to eq(true)
      expect(d.result_var).to be_nil
      expect(d.result_zig_type).to be_nil
      expect(d.result_needs_cleanup).to eq(false)
      expect(field_named(d.ctx_field_decls, "_")).to be_nil
    end

    it "treats underscore IO results as discarded finish values" do
      finish_value_def = IntrinsicRegistry.fs({
        suspends: true,
        fsm_setup: [],
        fsm_finish_value: FsmOps::LocalRef.new("__finished"),
      })
      value_call = Struct.new(:args, :receiver, :matched_stdlib_def, :full_type).new(
        [], nil, finish_value_def, :String
      )
      tail = FsmTransform::Segments::IoSuspend.new(value_call, finish_value_def, "_")

      d = FsmTransform::SuspendResolvers.resolve(
        FsmTransform::Segments::Segment.new(0, [], tail), ctx, lowering)

      expect(d.bind_stmts).to contain_exactly(an_instance_of(MIR::ExprStmt))
      expect(d.bind_stmts.first.expr).to eq(MIR::Ident.new("__finished"))
      expect(d.bind_stmts.first.discard).to eq(true)
      expect(d.result_var).to eq("_")
      expect(d.result_zig_type).to be_nil
      expect(d.result_needs_cleanup).to eq(false)
      expect(field_named(d.ctx_field_decls, "_")).to be_nil
      expect(field_named(d.ctx_field_decls, "__owned___init")).to be_nil
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
      expect(set.target).to eq(MIR::FieldGet.new(MIR::Ident.new("__ctx_0"), "content"))
      expect(set.target).to be_a(MIR::FieldGet)
      expect(set.target.field).to eq("content")
      expect(set.value).to eq(MIR::Ident.new("__finished"))
      expect(d.result_var).to eq("content")
      expect(d.result_zig_type).to eq("[]const u8")
    end

    it "emits IO bind statements in finalize, finish-block, result-bind order" do
      read_def = IntrinsicRegistry.fs({
        suspends: true,
        fsm_setup: [],
        fsm_state_finalize: [
          FsmOps::AssignField.new("done", FsmOps::LocalRef.new("__done")),
        ],
        fsm_finish_block: [
          FsmOps::AssignField.new("post", FsmOps::LocalRef.new("__post")),
        ],
        fsm_finish_value: FsmOps::LocalRef.new("__finished"),
      })
      value_call = Struct.new(:args, :receiver, :matched_stdlib_def, :full_type).new(
        [], nil, read_def, :Int64
      )
      tail = FsmTransform::Segments::IoSuspend.new(value_call, read_def, "count")

      d = FsmTransform::SuspendResolvers.resolve(
        FsmTransform::Segments::Segment.new(0, [], tail), ctx, lowering)

      expect(d.result_needs_cleanup).to eq(false)
      expect(d.result_zig_type).to eq("i64")
      expect(d.bind_stmts.map { |stmt| field_get_path(stmt.target).last }).to eq(%w[done post count])
      expect(d.bind_stmts.map(&:needs_field_cleanup)).to eq([false, false, false])
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

    it "sets the owned-result guard when IO result cleanup is required" do
      read_def = IntrinsicRegistry.fs({
        suspends: true,
        fsm_setup: [],
        fsm_finish_value: FsmOps::LocalRef.new("__finished"),
      })
      value_call = Struct.new(:args, :receiver, :matched_stdlib_def, :full_type).new(
        [], nil, read_def, :String
      )
      tail = FsmTransform::Segments::IoSuspend.new(value_call, read_def, "content")

      d = FsmTransform::SuspendResolvers.resolve(
        FsmTransform::Segments::Segment.new(0, [], tail), ctx, lowering)

      guard_field = field_named(d.ctx_field_decls, "__owned_content_init")
      expect(guard_field&.type_zig).to eq("bool")
      expect(guard_field&.default_value).to eq(MIR::Lit.new("false"))
      guard_write = d.bind_stmts.grep(MIR::Set).find { |stmt|
        stmt.target.is_a?(MIR::FieldGet) && stmt.target.field == "__owned_content_init"
      }
      expect(guard_write&.target).to eq(MIR::FieldGet.new(MIR::Ident.new("__ctx_0"), "__owned_content_init"))
      expect(guard_write&.value).to eq(MIR::Lit.new("true"))
      expect(guard_write&.needs_field_cleanup).to eq(false)
    end
  end

  describe "resolve_next" do
    # Fake AST::Identifier as the promise expr. The resolver lowers
    # it through the same AST -> structural MIR boundary as production.
    let(:promise_ast) {
      typed_identifier("promise", :"~Int64")
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
      expect(field_get_path(d.tail.register_expr.receiver)).to eq(%w[__ctx_0 sp_1 inner wg])
      expect(d.tail.register_expr.method).to eq("registerFsmWaiter")
      expect(d.tail.register_expr.args).to eq([MIR::FieldGet.new(MIR::Ident.new("__ctx_0"), "task")])
      expect(d.tail.register_expr.try_wrap).to eq(false)
      expect(d.tail.next_step).to be_nil
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
      expect(d.setup_stmts.first.value).to eq(MIR::Ident.new("promise"))
      expect(d.setup_stmts.first.needs_field_cleanup).to eq(false)
    end

    it "stores the lowered promise expression, not the source AST node" do
      lowered = MIR::Ident.new("__promise_mir")
      lowering_spy = Class.new {
        include FsmTransform::LoweringProtocol

        attr_reader :seen
        define_method(:initialize) { |value| @value = value }
        define_method(:lower) { |node| @seen = node; @value }
      }.new(lowered)

      d = FsmTransform::SuspendResolvers.resolve(
        FsmTransform::Segments::Segment.new(0, [], next_tail_with_var),
        ctx, lowering_spy, susp_idx: 1)

      expect(lowering_spy.seen).to equal(promise_ast)
      expect(d.setup_stmts.first.value).to eq(lowered)
    end

    it "declares a Promise field in ctx_field_decls" do
      d = FsmTransform::SuspendResolvers.resolve(
        FsmTransform::Segments::Segment.new(0, [], next_tail_with_var),
        ctx, lowering, susp_idx: 1)
      field = d.ctx_field_decls.first
      expect(field.name).to eq("sp_1")
      expect(field.type_zig).to include("CheatLib.Promise")
      expect(field.default_value).to be_a(MIR::Undef)
      expect(d.result_zig_type).to eq("i64")
      expect(d.result_needs_cleanup).to eq(false)
      expect(field_named(d.ctx_field_decls, "x")&.default_value).to be_a(MIR::Undef)
      expect(field_named(d.ctx_field_decls, "__owned_x_init")).to be_nil
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
      expect(field_get_path(d.bind_stmts.first.init.expr.receiver)).to eq(%w[__ctx_0 sp_1])
      expect(d.bind_stmts.first.init.expr.args).to eq([])
      expect(d.bind_stmts.first.init.expr.try_wrap).to eq(false)
      expect(d.bind_stmts.first.name).to eq("__res_1")
      expect(d.bind_stmts.first.mutable).to eq(false)
      expect(d.bind_stmts.first.annotation.zig_type).to eq("i64")
      expect(d.bind_stmts.first.init.capture).to eq("__err_1")
      expect(d.bind_stmts.first.init.result_type.zig_type).to eq("i64")
      expect(d.bind_stmts.first.init.catch_body.body).to eq([
        MIR::ReturnStmt.new(MIR::Ident.new("__err_1")),
      ])
      expect(d.bind_stmts.last.target).to eq(MIR::FieldGet.new(MIR::Ident.new("__ctx_0"), "x"))
      expect(d.bind_stmts.last.value).to eq(MIR::Ident.new("__res_1"))
      expect(d.bind_stmts.last.needs_field_cleanup).to eq(false)
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
      expect(d.bind_stmts.first.discard).to eq(true)
      expect(d.result_zig_type).to eq("i64")
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
      expect(field_named(d.ctx_field_decls, "payload")&.type_zig).to eq("[]const u8")
      expect(field_named(d.ctx_field_decls, "payload")&.default_value).to be_a(MIR::Undef)
      guard = field_named(d.ctx_field_decls, "__owned_payload_init")
      expect(guard&.type_zig).to eq("bool")
      expect(guard&.default_value&.value).to eq("false")
      guard_write = d.bind_stmts.find { |stmt|
        stmt.is_a?(MIR::Set) && stmt.target == MIR::FieldGet.new(MIR::Ident.new("__ctx_0"), "__owned_payload_init")
      }
      expect(guard_write&.value).to eq(MIR::Lit.new("true"))
      expect(guard_write&.needs_field_cleanup).to eq(false)
    end

    it "uses the segment index plus one when susp_idx is not supplied" do
      d = FsmTransform::SuspendResolvers.resolve(
        FsmTransform::Segments::Segment.new(4, [], next_tail_with_var),
        ctx, lowering)

      expect(field_named(d.ctx_field_decls, "sp_5")&.type_zig).to include("CheatLib.Promise")
      expect(d.setup_stmts.first.target).to eq(MIR::FieldGet.new(MIR::Ident.new("__ctx_0"), "sp_5"))
      expect(d.bind_stmts.first.name).to eq("__res_5")
      expect(d.bind_stmts.first.init.capture).to eq("__err_5")
    end

    it "uses an explicit susp_idx instead of deriving one from the segment index" do
      d = FsmTransform::SuspendResolvers.resolve(
        FsmTransform::Segments::Segment.new(4, [], next_tail_with_var),
        ctx, lowering, susp_idx: 9)

      expect(field_named(d.ctx_field_decls, "sp_9")&.type_zig).to include("CheatLib.Promise")
      expect(field_named(d.ctx_field_decls, "sp_5")).to be_nil
      expect(d.setup_stmts.first.target).to eq(MIR::FieldGet.new(MIR::Ident.new("__ctx_0"), "sp_9"))
      expect(d.bind_stmts.first.name).to eq("__res_9")
      expect(d.bind_stmts.first.init.capture).to eq("__err_9")
    end

    it "tracks captured promise moves with a context guard" do
      promise = typed_identifier("promise", :"~String")
      captured_ctx = fsm_ctx(captured: { "promise" => Object.new })

      d = FsmTransform::SuspendResolvers.resolve(
        FsmTransform::Segments::Segment.new(
          0, [], FsmTransform::Segments::NextSuspend.new(promise, "payload")
        ),
        captured_ctx, lowering, susp_idx: 6)

      expect(d.setup_stmts.length).to eq(2)
      expect(d.setup_stmts.last.target).to eq(MIR::FieldGet.new(MIR::Ident.new("__ctx_0"), "promise_moved"))
      expect(d.setup_stmts.last.value).to eq(MIR::Lit.new("true"))
      expect(d.setup_stmts.last.needs_field_cleanup).to eq(false)
      guard = field_named(d.ctx_field_decls, "promise_moved")
      expect(guard&.type_zig).to eq("bool")
      expect(guard&.default_value).to eq(MIR::Lit.new("false"))
    end

    it "does not add a captured-promise guard for uncaptured roots" do
      promise = typed_identifier("uncaptured", :"~String")
      captured_ctx = fsm_ctx(captured: { "other" => Object.new })

      d = FsmTransform::SuspendResolvers.resolve(
        FsmTransform::Segments::Segment.new(
          0, [], FsmTransform::Segments::NextSuspend.new(promise, "payload")
        ),
        captured_ctx, lowering, susp_idx: 7)

      expect(d.setup_stmts.length).to eq(1)
      expect(field_named(d.ctx_field_decls, "uncaptured_moved")).to be_nil
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

    it "classifies direct ownership-bearing result families" do
      expect(FsmTransform::SuspendResolvers.ownership_bearing_result_type?(Type.new(:String), lowering))
        .to eq(true)
      expect(FsmTransform::SuspendResolvers.ownership_bearing_result_type?(Type.new("Counter", layout: :indirect), lowering))
        .to eq(true)
      expect(FsmTransform::SuspendResolvers.ownership_bearing_result_type?(Type.new(:"Int64[]"), lowering))
        .to eq(true)
      expect(FsmTransform::SuspendResolvers.ownership_bearing_result_type?(Type.new(:Int64), lowering))
        .to eq(false)
      expect(FsmTransform::SuspendResolvers.ownership_bearing_result_type?(nil, lowering))
        .to eq(false)
    end
  end
end
