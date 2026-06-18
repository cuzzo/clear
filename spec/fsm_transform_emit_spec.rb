require "rspec"
require_relative "../src/mir/fsm_transform" unless defined?(FsmTransform::PromotedLocalFact)
require_relative "../src/mir/fsm_transform/emit" unless defined?(FsmTransform::Emit::ExpandedLockSegment)
require_relative "../src/mir/fsm_transform/segments" unless defined?(FsmTransform::Segments::SplitResult)
require_relative "../src/backends/fsm_wrapper_emitter" unless defined?(FsmWrapperEmitter)

RSpec.describe FsmTransform::Emit do
  def fsm_body_items(stmts)
    stmts.map do |stmt|
      FsmTransform::Emit.fsm_body_mir_item(stmt)
    end
  end

  def ctx_field(ctx, field)
    MIR::FieldGet.new(MIR::Ident.new(ctx), field)
  end

  def ctx_decl(name, type_zig, default_value = nil)
    MIR::ContextFieldDecl.new(name: name, type_zig: type_zig, default_value: default_value)
  end

  def render_expr(expr)
    MIREmitter.new.emit(expr)
  end

  def fsm_lowering_double(&block)
    klass = Class.new do
      include FsmTransform::LoweringProtocol
    end
    klass.class_eval(&block) if block
    klass.new
  end

  def tok(value = "x")
    Lexer::Token.new(:IDENT, value, 1, 1)
  end

  def fsm_ctx(overrides = {})
    raw = {
      id: 1,
      bg_rt: "__rt_bg1",
      blk_label: "__bg1",
      ctx_type: "__BgCtx1",
      promise_zig: "CheatHeader.Promise(void)",
      capture_fields: [],
      alloc_var: "__alloc_1",
      promise_var: "__promise_1",
      ctx_var: "__ctx_1_ptr",
      rt_name: "rt",
      promoted_decls: [],
      capture_inits: [],
      captured: {},
      capture_close_plans: {},
      pointer_captures: Set.new,
      capture_finalizers: [],
      is_void: true,
      pin_mode: false,
      parallel: false,
      extra_ctx_fields: [],
      recursive_promoted_names: [],
      fresh_heap_cleanup_names: [],
      arena_init_flag: false,
      profile_site_id: nil,
      profile_line: nil,
      profile_column: nil,
      destroy_actions: [],
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
      capture_finalizers: raw.fetch(:capture_finalizers),
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
      destroy_actions: raw.fetch(:destroy_actions),
    )
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
      facts: attrs.fetch(:facts, FsmTransform::Emit::FsmSegmentFacts.empty),
    )
  end

  it "maps profile dispatch ids and emits task-site comments" do
    expect(described_class.send(:profile_dispatch_id, :local)).to eq(1)
    expect(described_class.send(:profile_dispatch_id, :parallel)).to eq(2)
    expect(described_class.send(:profile_dispatch_id, :shared)).to eq(3)
    expect(described_class.send(:profile_dispatch_id, :unexpected)).to eq(1)

    ctx = fsm_ctx(profile_site_id: 11, profile_line: 22, profile_column: 5)
    expect(described_class.send(:bg_profile_site_comment, ctx, :parallel, :fsm))
      .to eq("// CLEAR_PROFILE_TASK_SITE id=11 kind=BG line=22 column=5 dispatch=parallel form=fsm")
  end

  it "exposes typed context cloning" do
    ctx = fsm_ctx(id: 12, bg_rt: "__rt_bg12", captured: { "payload" => :stub })

    expect(ctx.id).to eq(12)
    expect(ctx.bg_rt).to eq("__rt_bg12")
    expect(ctx.captured.keys).to eq(["payload"])
    expect(ctx.captured.fetch("payload")).to be_a(Type)

    updated = ctx.with_extra_ctx_fields([ctx_decl("payload", "i64", MIR::Lit.new("0"))])
    expect(updated.extra_ctx_fields.first.name).to eq("payload")
    expect(updated.extra_ctx_fields.first.type_zig).to eq("i64")
    expect(updated.extra_ctx_fields.first.default_value.value).to eq("0")
    expect(updated.id).to eq(12)
  end

  it "detects runtime binding use structurally instead of from rendered text" do
    runtime_use = MIR::ExprStmt.new(
      MIR::FieldGet.new(MIR::Ident.new("__rt_bg12"), "arena_mode"),
      false,
    )
    string_only = MIR::ExprStmt.new(MIR::Lit.new("__rt_bg12"), false)

    expect(described_class.send(:mir_nodes_reference_ident?, [runtime_use], "__rt_bg12")).to eq(true)
    expect(described_class.send(:mir_nodes_reference_ident?, [string_only], "__rt_bg12")).to eq(false)
  end

  it "returns nil for an empty unified FSM and skips fn-less inert segments" do
    expect(described_class.send(:build_fsm_unified, fsm_ctx, [], [], fsm_lowering_double)).to be_nil

    lowering = fsm_lowering_double do
      def capture_inits_fsm(_capture_inits)
        ""
      end
    end
    result = described_class.send(
      :build_fsm_unified,
      fsm_ctx,
      [fsm_spec(index: 0, body_stmts: [], tail: FsmTransform::Segments::Done.new(nil))],
      [],
      lowering,
    )

    expect(result).to be_a(MIR::FsmLoweringResult)
    expect(FsmWrapperEmitter.render(result.body)).not_to include("fn runSeg0")
  end

  it "returns resume targets only for tails that resume into another segment" do
    expect(described_class.send(:tail_resume_target, FsmTransform::Segments::Done.new(nil))).to be_nil
    expect(described_class.send(:tail_resume_target, FsmTransform::Segments::Goto.new(5))).to be_nil
    expect(described_class.send(:tail_resume_target, FsmTransform::Segments::IoSuspend.new(nil, nil, "io", 6))).to eq(6)
    expect(described_class.send(:tail_resume_target, FsmTransform::Segments::NextSuspend.new(nil, "next", 7))).to eq(7)
    expect(described_class.send(:tail_resume_target, FsmTransform::Segments::LockSuspend.new(nil, :cap, [], 8, 9))).to eq(9)
    expect(described_class.send(:tail_resume_target, MIR::FsmTailJump.new(10))).to eq(10)
    expect(described_class.send(:tail_resume_target, MIR::FsmTailYield.new(11, "WaitForIo"))).to eq(11)
    expect(described_class.send(:tail_resume_target, MIR::FsmTailRegisterYield.new(12, MIR::Ident.new("ready"), "WaitForPromise"))).to eq(12)
    expect(described_class.send(:tail_resume_target, MIR::FsmTailCondJump.new(MIR::Ident.new("ok"), 13, 14))).to be_nil
  end

  it "deduplicates context fields by name while preserving first definitions and anonymous fields" do
    first_step = ctx_decl("step", "u8", MIR::Lit.new("0"))
    duplicate_step = ctx_decl("step", "usize", MIR::Lit.new("99"))
    first_extra = ctx_decl("extra", "i64", MIR::Lit.new("1"))
    duplicate_extra = ctx_decl("extra", "i64", MIR::Lit.new("2"))
    anonymous_a = ctx_decl("", "bool", MIR::Lit.new("false"))
    anonymous_b = ctx_decl("", "u1", MIR::Lit.new("1"))

    deduped = described_class.send(:dedupe_context_fields, [
      first_step, duplicate_step, anonymous_a, first_extra, duplicate_extra, anonymous_b,
    ])

    expect(deduped).to eq([first_step, anonymous_a, first_extra, anonymous_b])
  end

  it "builds recursive capture maps from captures, live vars, conservative promotions, and named suspend results" do
    liveness = FsmTransform::Liveness::Result.new({
      "live" => FsmTransform::Liveness::CrossSegmentVarFact.new(
        type_info: Type.new(:Int64),
        first_def_seg: 0,
        last_use_seg: 2,
      ),
    })
    segments = [
      FsmTransform::Segments::Segment.new(0, [], FsmTransform::Segments::Goto.new(1)),
      FsmTransform::Segments::Segment.new(1, [], FsmTransform::Segments::IoSuspend.new(nil, nil, "io_result", 2)),
      FsmTransform::Segments::Segment.new(2, [], FsmTransform::Segments::NextSuspend.new(nil, "_", 3)),
      FsmTransform::Segments::Segment.new(3, [], FsmTransform::Segments::NextSuspend.new(nil, nil, 4)),
      FsmTransform::Segments::Segment.new(4, [], FsmTransform::Segments::Done.new(nil)),
    ]
    ctx = fsm_ctx(
      id: 42,
      captured: { "cap" => :stub },
      recursive_promoted_names: ["recursive", "live"],
    )

    capture_map = described_class.send(:build_recursive_capture_map, ctx, segments, liveness)

    expect(capture_map).to eq(
      "cap" => "__ctx_42.cap",
      "live" => "__ctx_42.live",
      "recursive" => "__ctx_42.recursive",
      "io_result" => "__ctx_42.io_result",
    )
  end

  it "rebuilds recursive destroy actions from capture cleanup facts and clears stale actions" do
    stale = MIR::FsmDestroyStmt.new(
      source_kind: :capture,
      name: "stale",
      stmt: MIR::ExprStmt.new(MIR::Lit.new("stale()"), false),
    )
    finalizer = MIR::RcRelease.new(ctx_field("__ctx_42", "finalized"), "Handle", "release", MIR::Ident.new("alloc"))
    close_plan = Schemas::ResourceClosePlan.method("close")
    ctx = fsm_ctx(
      id: 42,
      captured: { "plain" => :stub, "resource" => :stub },
      capture_close_plans: { "resource" => close_plan },
      fresh_heap_cleanup_names: ["fresh_copy"],
      capture_finalizers: [finalizer],
      destroy_actions: [stale],
    )

    described_class.send(:register_recursive_destroy_actions!, ctx)

    expect(ctx.destroy_actions.map(&:name)).to eq(["resource", "fresh_copy", "finalized"])
    resource_action = ctx.destroy_actions[0]
    fresh_action = ctx.destroy_actions[1]
    finalizer_action = ctx.destroy_actions[2]
    expect(resource_action).to be_a(MIR::FsmDestroyCleanup)
    expect(resource_action.source_kind).to eq(:capture)
    expect(MIREmitter.new.emit(resource_action.target)).to eq("__ctx_42.resource")
    expect(resource_action.cleanup_entry.kind).to eq(:resource)
    expect(resource_action.cleanup_entry.alloc).to eq(:heap)
    expect(resource_action.cleanup_entry.has_moved_guard?).to be(false)
    expect(resource_action.cleanup_entry.resource_close_plan).to be(close_plan)
    expect(fresh_action).to be_a(MIR::FsmDestroyCleanup)
    expect(fresh_action.source_kind).to eq(:fresh_heap)
    expect(MIREmitter.new.emit(fresh_action.target)).to eq("__ctx_42.fresh_copy")
    expect(fresh_action.cleanup_entry.kind).to eq(:uniform)
    expect(fresh_action.cleanup_entry.alloc).to eq(:heap)
    expect(fresh_action.cleanup_entry.has_moved_guard?).to be(true)
    expect(MIREmitter.new.emit(fresh_action.allocator)).to eq("__ctx_42.alloc")
    expect(finalizer_action).to be_a(MIR::FsmDestroyStmt)
    expect(finalizer_action.source_kind).to eq(:capture)
    expect(finalizer_action.stmt).to be(finalizer)
    expect(finalizer_action.ctx_cleanup_target_name).to eq("__ctx_42.finalized")
  end

  it "derives segment facts from MIR roots and prefers materialized structure roots" do
    payload_ref = MIR::FieldGet.new(MIR::Ident.new("__ctx_12"), "payload")
    moved_ref = MIR::FieldGet.new(MIR::Ident.new("__ctx_12"), "payload_moved")
    result_ref = MIR::FieldGet.new(
      MIR::FieldGet.new(MIR::Ident.new("__ctx_12"), "inner"),
      "result",
    )
    descriptor = MIR::SuspendDescriptor.new(
      [MIR::ExprStmt.new(payload_ref, false)],
      [MIR::Set.new(moved_ref, MIR::Lit.new("true"), false)],
      MIR::FsmTailYield.new(1, "WaitForIo"),
      [],
      nil,
      nil,
      false,
    )
    spec = fsm_spec(
      index: 0,
      body_stmts: [MIR::MoveMark.new("__ctx_12.fake")],
      structure_stmts: [
        MIR::TransferMark.new("__ctx_12.payload", :return, :heap),
        MIR::MoveMark.new("__ctx_12.payload"),
        MIR::Set.new(result_ref, payload_ref, false),
      ],
      tail: FsmTransform::Segments::Done.new(nil),
      descriptor: descriptor,
      fsm_result_transfer_facts: [
        MIR::FsmResultTransferFact.new(
          name: "__ctx_12.payload",
          target_alloc: :heap,
          move_guarded: true,
        ),
      ],
    )

    facts = described_class.send(:build_fsm_segment_facts, spec, 12, ["payload"])

    expect(facts.ctx_reads).to include("payload", "payload_moved", "inner")
    expect(facts.required_move_guards).to eq(["payload"])
    expect(facts.move_guard_writes).to include("payload", "__ctx_12.payload")
    expect(facts.move_guard_writes).not_to include("fake")
    expect(facts.result_names).to eq(["payload"])
    expect(facts.ownership_facts.map(&:name)).to eq(["payload"])
    expect(described_class.send(:fsm_fact_guard_name, "__ctx_12")).to eq("")
    expect(described_class.send(:fsm_fact_guard_name, "__ctx_12.payload")).to eq("payload")
    expect(described_class.send(:promoted_fsm_field_name, "payload_L3_moved", ["payload"]))
      .to eq("payload_moved")
  end

  it "keeps structural FSM body items visible to safety fact collection" do
    structural_guard = FsmTransform::Emit.fsm_body_mir_item(
      MIR::MoveMark.new("__ctx_12.payload")
    )

    expect(structural_guard.fact_node).to be_a(MIR::MoveMark)
    expect(structural_guard.emit_value).to be_a(MIR::MoveMark)
    expect(FsmTransform::Emit.fsm_body_mir_nodes([structural_guard]))
      .to eq([structural_guard.fact_node])
  end

  it "builds FSM structure from materialized segment facts" do
    cleanup_entry = CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: true)
    action = MIR::FsmDestroyCleanup.new(
      source_kind: :capture,
      name: "payload",
      target: ctx_field("__ctx_33", "payload"),
      cleanup_entry: cleanup_entry,
    )
    fact = MIR::FsmOwnershipFact.new(
      name: "payload",
      target: :result,
      target_alloc: :heap,
      move_guarded: true,
    )
    spec = fsm_spec(
      index: 0,
      body_stmts: [MIR::ExprStmt.new(MIR::Lit.new("ignored()"), false)],
      tail: FsmTransform::Segments::Done.new(nil),
      facts: FsmTransform::Emit::FsmSegmentFacts.new(
        ctx_reads: ["payload"],
        required_move_guards: ["payload"],
        move_guard_writes: ["payload"],
        result_names: ["payload"],
        ownership_facts: [fact],
      ),
    )

    structure = described_class.send(
      :build_fsm_structure,
      fsm_ctx(id: 33, captured: { "payload" => :stub }),
      [spec],
      [action],
      33,
    )

    step = T.must(structure.steps.first)
    capture = T.must(structure.captures.first)
    expect(step).to be_a(MIR::FsmStepFact)
    expect(step.index).to eq(0)
    expect(step.reads).to eq(["payload"])
    expect(step.cleanups).to eq([])
    expect(capture).to be_a(MIR::FsmCaptureFact)
    expect(capture.name).to eq("payload")
    expect(capture.cleanup_at).to eq(:finalize)
    expect(structure.required_move_guards).to eq(["payload"])
    expect(structure.move_guard_writes).to eq(["payload"])
    expect(structure.ownership_facts).to eq([fact])
  end

  it "accepts structural MIR conditions and rejects unresolved condition ASTs" do
    cond = MIR::Ident.new("has_work")
    tail = FsmTransform::Segments::CondBranch.new(cond, 2, 3)
    spec = fsm_spec(index: 1, tail: tail, descriptor: nil)
    lowered = described_class.send(:build_dispatch_tail, spec)

    expect(lowered).to be_a(MIR::FsmTailCondJump)
    expect(lowered.condition).to eq(cond)

    bad_tail = FsmTransform::Segments::CondBranch.new(Object.new, 2, 3)
    expect {
      described_class.send(:build_dispatch_tail, fsm_spec(index: 1, tail: bad_tail, descriptor: nil))
    }.to raise_error(ArgumentError, /CondBranch tail condition must be structural MIR/)
  end

  it "rejects unsupported suspend descriptor tails" do
    descriptor = MIR::SuspendDescriptor.new(
      [], [], MIR::FsmTailDone.new(nil), [], nil, nil, false
    )
    tail = FsmTransform::Segments::NextSuspend.new(Object.new, nil)

    expect {
      described_class.send(:build_dispatch_tail, fsm_spec(index: 4, tail: tail, descriptor: descriptor))
    }.to raise_error(ArgumentError, /Unsupported descriptor tail/)
  end

  it "rejects suspend tails that have not been resolved to descriptors" do
    tail = FsmTransform::Segments::NextSuspend.new(Object.new, nil)

    expect {
      described_class.send(:build_dispatch_tail, fsm_spec(index: 4, tail: tail, descriptor: nil))
    }.to raise_error(ArgumentError, /has no descriptor/)
  end

  it "wraps suspend descriptor resolution in the fiber lowering context" do
    descriptor = MIR::SuspendDescriptor.new(
      [], [], MIR::FsmTailYield.new(3, "WaitForLock"), [], nil, nil, false
    )
    lowering = fsm_lowering_double do
      attr_reader :calls

      def initialize
        @calls = []
      end

      def with_bg_fiber_body_context(pointer_captures)
        @calls << [:bg, pointer_captures]
        yield
      end

      def with_fiber_capture_map(capture_map, rt_override:)
        @calls << [:capture, capture_map, rt_override]
        yield
      end
    end
    allow(FsmTransform::SuspendResolvers).to receive(:resolve).and_return(descriptor)
    ctx = fsm_ctx(bg_rt: "__rt_bg3", pointer_captures: Set["payload"])
    segment = FsmTransform::Segments::Segment.new(
      2, [], FsmTransform::Segments::NextSuspend.new(Object.new, "payload", 4)
    )

    result = described_class.send(:build_segment_descriptor,
      segment, ctx, lowering, { "payload" => "__ctx_3.payload" }, sp_idx: 9
    )

    expect(result).to eq(descriptor)
    expect(lowering.calls).to eq([
      [:bg, Set["payload"]],
      [:capture, { "payload" => "__ctx_3.payload" }, "__rt_bg3"],
    ])
    expect(FsmTransform::SuspendResolvers).to have_received(:resolve)
      .with(segment, ctx, lowering, susp_idx: 9)
  end

  it "lifts promoted ctx cleanups into destroyTask lines" do
    ctx = fsm_ctx(id: 8)
    kept = MIR::ExprStmt.new(MIR::Lit.new("keep()"), false)
    entry = CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: false)
    body = [MIR::Cleanup.new("payload_L2", entry), kept]

    rewritten = described_class.send(
      :lift_ctx_cleanups_to_destroy!,
      body, ["payload"], "__ctx_8", ctx)

    expect(rewritten).to eq([kept])
    action = described_class.send(:fsm_destroy_actions, ctx).first
    expect(action).to be_a(MIR::FsmDestroyCleanup)
    expect(action.name).to eq("payload")
    expect(render_expr(action.target)).to eq("__ctx_8.payload")
    expect(action.cleanup_entry).to eq(entry)
  end

  it "orders lock releases before capture and body cleanups" do
    cleanup_entry = CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: false)
    ctx = fsm_ctx
    described_class.send(:fsm_destroy_actions, ctx) << MIR::FsmDestroyCleanup.new(
      source_kind: :body,
      name: "body",
      target: ctx_field("__ctx_1", "body"),
      cleanup_entry: cleanup_entry,
    )
    described_class.send(:fsm_destroy_actions, ctx) << MIR::FsmDestroyLockRelease.new(
      name: "__ctx_1.lock_a",
      ctx_id: 1,
      guard_index: 0,
      lock_ref: ctx_field("__ctx_1", "lock_a"),
      unlock_method: "unlock",
    )
    described_class.send(:fsm_destroy_actions, ctx) << MIR::FsmDestroyCleanup.new(
      source_kind: :capture,
      name: "cap",
      target: ctx_field("__ctx_1", "cap"),
      cleanup_entry: cleanup_entry,
    )
    described_class.send(:fsm_destroy_actions, ctx) << MIR::FsmDestroyLockRelease.new(
      name: "__ctx_1.lock_b",
      ctx_id: 1,
      guard_index: 1,
      lock_ref: ctx_field("__ctx_1", "lock_b"),
      unlock_method: "unlock",
    )

    ordered = described_class.send(:ordered_fsm_destroy_actions, ctx)

    expect(ordered.map(&:name)).to eq(["__ctx_1.lock_b", "__ctx_1.lock_a", "cap", "body"])
  end

  it "builds parallel FSM spawn setup with heap allocation" do
    ctx = fsm_ctx(
      id: 8,
      ctx_var: "__ctx_8_ptr",
      rt_name: "rt",
      parallel: true,
      pin_mode: false,
      capture_inits: [MIR::StructInitField.new(name: :payload, value: MIR::Ident.new("payload"))],
    )

    setup = described_class.send(:build_spawn_setup, ctx)

    expect(FsmWrapperEmitter.send(:render_fsm_spawn_call, setup.spawn_call))
      .to eq("try CheatHeader.spawnFsmBest(__ctx_8_ptr.task);")
    expect(MIREmitter.new.emit(setup.alloc_expr)).to eq("rt.heapAlloc()")
    expect(FsmWrapperEmitter.send(:render_struct_init_fields, setup.ctx_init_fields, MIREmitter.new))
      .to include(".payload = payload,")
  end

  it "registers structural lock release actions while expanding lock segments" do
    lowering = fsm_lowering_double do
      def fsm_cap_metadata(_cap, _with_node, id, _captured)
        {
          try_method: "tryLockForFsm",
          unlock_method: "unlock",
          lock_field_ref: "__ctx_#{id}.lock",
          alias_name: "lock",
          alias_data_ref: "(__ctx_#{id}.lock.data)",
          retries: 0,
        }
      end

      def default_fsm_lock_error_arm_split(_id)
        Struct.new(:body_stmts, :exit_kind).new([], :goto_post)
      end
    end
    with_node = Struct.new(:lock_error_clause).new(nil)
    tail = FsmTransform::Segments::LockSuspend.new(with_node, :cap, [], 9, 10)
    spec = fsm_spec(
      index: 1,
      prologue_stmts: [],
      body_stmts: [],
      tail: tail,
      fn_name: nil,
      suppress_runtime_ref: false,
    )
    ctx = fsm_ctx(
      id: 7,
      bg_rt: "__rt_bg7",
      captured: { "lock" => :stub },
      pointer_captures: Set.new,
      rt_name: "rt",
    )

    expanded = described_class.send(:expand_lock_segment, spec, ctx, {}, lowering, 20)

    held_field = expanded.extra_fields.find { |field| field.name == "__lock_held_0" }
    expect(held_field&.type_zig).to eq("bool")
    expect(held_field&.default_value&.value).to eq("false")
    action = described_class.send(:fsm_destroy_actions, ctx).first
    expect(action).to be_a(MIR::FsmDestroyLockRelease)
    expect(action.guard_field).to eq("__lock_held_0")
    expect(action.ctx_id).to eq(7)
    expect(action.guard_index).to eq(0)
    expect(render_expr(action.lock_ref)).to eq("__ctx_7.lock")
    expect(action.unlock_method).to eq("unlock")
  end

  it "expands prior-lock releases and explicit lock error arms structurally" do
    error_clause = Object.new
    lowering = fsm_lowering_double do
      attr_reader :error_calls

      def initialize
        @error_calls = []
      end

      def fsm_cap_metadata(cap, _with_node, id, _captured)
        {
          try_method: "tryLockForFsm",
          unlock_method: "unlock#{cap}",
          lock_field_ref: "__ctx_#{id}.lock_#{cap}",
          alias_name: "lock",
          alias_data_ref: "(__ctx_#{id}.lock_#{cap}.data)",
          retries: 1,
        }
      end

      def emit_fsm_lock_error_arm_split(clause:, ctx_id:, with_node:, capture_map:, pointer_captures:, bg_rt:)
        @error_calls << [clause, ctx_id, with_node, capture_map, pointer_captures, bg_rt]
        Struct.new(:body_stmts, :exit_kind).new(
          [MIR::ExprStmt.new(MIR::Lit.new("handleLockError()"), false)],
          :done,
        )
      end
    end
    with_node = Struct.new(:lock_error_clause).new(error_clause)
    tail = FsmTransform::Segments::LockSuspend.new(with_node, :current, [:prior], 9, 10, 1, [0])
    spec = fsm_spec(
      index: 1,
      body_stmts: [MIR::ExprStmt.new(MIR::Lit.new("beforeLock()"), false)],
      tail: tail,
      fn_name: "runLock",
    )
    ctx = fsm_ctx(id: 7, bg_rt: "__rt_bg7", captured: { "lock" => :stub }, pointer_captures: Set["lock"])

    expanded = described_class.send(:expand_lock_segment,
      spec, ctx, { "lock" => "__ctx_7.lock" }, lowering, 20
    )

    fail_spec = expanded.appended_specs[2]
    fail_pre_body = FsmWrapperEmitter.render_stmt_array(fail_spec.pre_body_stmts, "__rt_bg7")
    expect(expanded.lock_try_spec.fn_name).to eq("runLock")
    expect(fail_pre_body).to include("__ctx_7.__lock_held_0 = false;")
    expect(fail_pre_body).to include("__ctx_7.lock_prior.unlockprior();")
    expect(fail_pre_body).to include("handleLockError();")
    expect(fail_spec.tail).to be_a(FsmTransform::Segments::Done)
    retry_field = expanded.extra_fields.find { |field| field.name == "retry_count" }
    expect(retry_field&.type_zig).to eq("u32")
    expect(retry_field&.default_value&.value).to eq("0")
    held_field = expanded.extra_fields.find { |field| field.name == "__lock_held_1" }
    expect(held_field&.type_zig).to eq("bool")
    expect(lowering.error_calls.first).to eq([
      error_clause,
      7,
      with_node,
      { "lock" => "__ctx_7.lock" },
      Set["lock"],
      "__rt_bg7",
    ])
  end

  it "applies lock expansion through recursive FSM build" do
    lowering = fsm_lowering_double do
      def capture_inits_fsm(_capture_inits)
        ""
      end

      def fsm_cap_metadata(_cap, _with_node, id, _captured)
        {
          try_method: "tryLockForFsm",
          unlock_method: "unlock",
          lock_field_ref: "__ctx_#{id}.lock",
          alias_name: "lock",
          alias_data_ref: "(__ctx_#{id}.lock.data)",
          retries: 0,
        }
      end

      def default_fsm_lock_error_arm_split(_id)
        Struct.new(:body_stmts, :exit_kind).new([], :goto_post)
      end
    end
    with_node = Struct.new(:lock_error_clause).new(nil)
    segment_list = FsmTransform::RecursiveSplitter::SegmentList.new(
      segments: [
        FsmTransform::Segments::Segment.new(
          0,
          [],
          FsmTransform::Segments::LockSuspend.new(with_node, :cap, [], 1, 1),
        ),
        FsmTransform::Segments::Segment.new(
          1,
          [],
          FsmTransform::Segments::Done.new(nil),
        ),
      ],
      synthetic_fields: [],
      alias_overrides_by_index: {},
    )
    ctx = fsm_ctx(id: 9, bg_rt: "__rt_bg9", captured: { "lock" => :stub })

    result = described_class.build_recursive(
      ctx, segment_list, FsmTransform::Liveness::Result.new({}), lowering
    )

    expect(result).to be_a(MIR::FsmLoweringResult)
    expect(FsmWrapperEmitter.render(result.body)).to include("__lock_held_0: bool = false,")
    expect(result.structure.destroy_actions.first).to be_a(MIR::FsmDestroyLockRelease)
    expect(result.structure.destroy_actions.first.guard_field).to eq("__lock_held_0")
  end

  it "returns nil for an empty recursive segment list" do
    segment_list = FsmTransform::RecursiveSplitter::SegmentList.new(
      segments: [],
      synthetic_fields: [],
      alias_overrides_by_index: {},
    )

    expect(described_class.build_recursive(
      fsm_ctx,
      segment_list,
      FsmTransform::Liveness::Result.new({}),
      fsm_lowering_double,
    )).to be_nil
  end

  it "builds recursive FSM structure from captures, liveness, synthetic fields, and AST lowering" do
    lowering = fsm_lowering_double do
      attr_reader :capture_maps, :lower_calls, :contexts

      def initialize
        @capture_maps = []
        @lower_calls = []
        @contexts = []
        @last_facts = []
      end

      def with_fsm_segment_lowering_context(**kwargs)
        @contexts << kwargs
        yield
      end

      def with_fiber_capture_map(capture_map, rt_override:)
        @capture_maps << [capture_map, rt_override]
        yield
      end

      def lower_finalized_fsm_step_mir(ast_stmts, no_result:, ctx_id: nil)
        @lower_calls << [ast_stmts.map(&:class), ast_stmts.map(&:name), no_result, ctx_id]
        @last_facts = [
          MIR::FsmResultTransferFact.new(name: "fact_only", target_alloc: :frame, move_guarded: false),
        ]
        if no_result
          [
            MIR::Let.new("keep", MIR::Ident.new("input"), true, Type.new(:Int64), nil),
          ]
        else
          [
            MIR::Set.new(
              MIR::FieldGet.new(MIR::FieldGet.new(MIR::Ident.new("__ctx_3"), "inner"), "result"),
              MIR::Ident.new("keep"),
              false,
            ),
          ]
        end
      end

      def last_fsm_result_transfer_facts
        @last_facts
      end
    end
    ast_stmt = AST::Identifier.new(tok("input"), "input")
    segment_list = FsmTransform::RecursiveSplitter::SegmentList.new(
      segments: [
        FsmTransform::Segments::Segment.new(
          0,
          [MIR::Comment.new("mir prelude"), ast_stmt],
          FsmTransform::Segments::Goto.new(1),
        ),
        FsmTransform::Segments::Segment.new(
          1,
          [ast_stmt],
          FsmTransform::Segments::Goto.new(2),
        ),
        FsmTransform::Segments::Segment.new(
          2,
          [ast_stmt],
          FsmTransform::Segments::Done.new(nil),
        ),
      ],
      synthetic_fields: [ctx_decl("synthetic", "bool", MIR::Lit.new("false"))],
      alias_overrides_by_index: {
        1 => { "input" => "__ctx_3.alias_input" },
      },
    )
    liveness = FsmTransform::Liveness::Result.new({
      "keep" => FsmTransform::Liveness::CrossSegmentVarFact.new(
        type_info: Type.new(:Int64),
        first_def_seg: 0,
        last_use_seg: 1,
      ),
      "hidden" => FsmTransform::Liveness::CrossSegmentVarFact.new(
        type_info: Type.new(:String),
        first_def_seg: 0,
        last_use_seg: 2,
      ),
    })
    ctx = fsm_ctx(
      id: 3,
      bg_rt: "__rt_bg3",
      ctx_type: "__BgCtx3",
      captured: { "cap" => :stub },
      capture_fields: [ctx_decl("cap", "[]const u8")],
      capture_close_plans: { "cap" => Schemas::ResourceClosePlan.method("close") },
      fresh_heap_cleanup_names: ["fresh"],
      recursive_promoted_names: ["hidden", "hidden", "solo_recursive"],
      pointer_captures: Set["ptr"],
      arena_init_flag: true,
      is_void: false,
      extra_ctx_fields: [ctx_decl("extra", "i64", MIR::Lit.new("1"))],
    )

    result = T.must(described_class.build_recursive(ctx, segment_list, liveness, lowering))
    body = result.body
    ctx_struct = body.ctx_struct

    expect(lowering.capture_maps).to include([
      hash_including(
        "cap" => "__ctx_3.cap",
        "keep" => "__ctx_3.keep",
        "hidden" => "__ctx_3.hidden",
        "solo_recursive" => "__ctx_3.solo_recursive",
      ),
      "__rt_bg3",
    ])
    expect(lowering.capture_maps).to include([
      hash_including(
        "input" => "__ctx_3.alias_input",
        "keep" => "__ctx_3.keep",
      ),
      "__rt_bg3",
    ])
    expect(lowering.lower_calls).to eq([
      [[AST::Identifier], ["input"], true, nil],
      [[AST::Identifier], ["input"], false, 3],
      [[AST::Identifier], ["input"], false, 3],
    ])
    expect(lowering.contexts.map { |lower_ctx| lower_ctx[:pointer_captures] }).to eq([Set["ptr"], Set["ptr"], Set["ptr"]])
    expect(lowering.contexts.first[:inherited_alloc_names]).to include("__ctx_3.cap")
    expect(lowering.contexts.first[:inherited_guard_names]).to include("__ctx_3.cap")
    expect(lowering.contexts.first[:owned_result_guards]).to eq({})

    expect(ctx_struct.extra_field_decls.map(&:name)).to include("step", "extra", "synthetic")
    expect(ctx_struct.promoted_field_decls.map(&:name)).to include("keep", "keep_moved", "hidden_moved", "solo_recursive_moved")
    expect(ctx_struct.promoted_field_decls.map(&:name)).not_to include("hidden", "solo_recursive")
    keep_decl = ctx_struct.promoted_field_decls.find { |decl| decl.name == "keep" }
    hidden_guard = ctx_struct.promoted_field_decls.find { |decl| decl.name == "hidden_moved" }
    expect(keep_decl&.type_zig).to eq("i64")
    expect(keep_decl&.default_value).to be_a(MIR::Undef)
    expect(hidden_guard&.type_zig).to eq("bool")
    expect(hidden_guard&.default_value&.value).to eq("false")
    expect(ctx_struct.promoted_field_decls.map(&:name).count("hidden_moved")).to eq(1)
    expect(ctx_struct.member_fns.map(&:fn_name)).to eq(["runSeg0", "runSeg1", "runSeg2"])
    arena_stmt = ctx_struct.member_fns.first.body_stmts.first
    expect(arena_stmt).to be_a(MIR::Set)
    expect(MIREmitter.new.emit(arena_stmt.target)).to eq("__rt_bg3.arena_mode")
    expect(arena_stmt.value.value).to eq("true")
    expect(arena_stmt.needs_field_cleanup).to be(false)
    expect(ctx_struct.member_fns.first.body_stmts).to include(an_object_having_attributes(text: "mir prelude"))
    expect(ctx_struct.member_fns.first.suppress_runtime_ref).to be(false)
    expect(ctx_struct.member_fns.last.suppress_runtime_ref).to be(true)
    expect(result.structure.destroy_actions.map(&:name)).to include("cap", "fresh")
    fact_only = result.structure.ownership_facts.find { |fact| fact.name == "fact_only" }
    expect(fact_only&.target_alloc).to eq(:frame)
    expect(fact_only&.move_guarded).to be(false)
  end

  it "appends the void result without an arena prologue for void recursive FSMs" do
    segment_list = FsmTransform::RecursiveSplitter::SegmentList.new(
      segments: [
        FsmTransform::Segments::Segment.new(
          0,
          [],
          FsmTransform::Segments::Done.new(nil),
        ),
      ],
      synthetic_fields: [],
      alias_overrides_by_index: {},
    )

    result = T.must(described_class.build_recursive(
      fsm_ctx(id: 8, bg_rt: "__rt_bg8", is_void: true, arena_init_flag: false),
      segment_list,
      FsmTransform::Liveness::Result.new({}),
      fsm_lowering_double,
    ))

    body_stmts = result.body.ctx_struct.member_fns.first.body_stmts
    expect(body_stmts.length).to eq(1)
    void_assign = body_stmts.first
    expect(void_assign).to be_a(MIR::Set)
    expect(MIREmitter.new.emit(void_assign.target)).to eq("__ctx_8.inner.result")
    expect(void_assign.value).to be_a(MIR::VoidLiteral)
    expect(void_assign.needs_field_cleanup).to be(false)
  end

  it "rejects recursive MIR segments that retain cross-segment cleanup defers" do
    cleanup = MIR::Cleanup.new(
      "keep",
      CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: false),
    )
    segment_list = FsmTransform::RecursiveSplitter::SegmentList.new(
      segments: [
        FsmTransform::Segments::Segment.new(
          0,
          [cleanup],
          FsmTransform::Segments::Done.new(nil),
        ),
      ],
      synthetic_fields: [],
      alias_overrides_by_index: {},
    )
    liveness = FsmTransform::Liveness::Result.new({
      "keep" => FsmTransform::Liveness::CrossSegmentVarFact.new(
        type_info: Type.new(:String),
        first_def_seg: 0,
        last_use_seg: 0,
      ),
    })

    expect {
      described_class.build_recursive(fsm_ctx(id: 11), segment_list, liveness, fsm_lowering_double)
    }.to raise_error(/FSM cleanup invariant violated: seg 0 emits cleanup for 'keep'/)
  end

  it "returns nil when recursive AST segment lowering fails" do
    lowering = fsm_lowering_double do
      def with_fsm_segment_lowering_context(**_kwargs)
        yield
      end

      def with_fiber_capture_map(_capture_map, rt_override:)
        yield
      end

      def lower_finalized_fsm_step_mir(_ast_stmts, no_result:, ctx_id: nil)
        _ = no_result
        _ = ctx_id
        nil
      end

      def last_fsm_result_transfer_facts
        []
      end
    end
    segment_list = FsmTransform::RecursiveSplitter::SegmentList.new(
      segments: [
        FsmTransform::Segments::Segment.new(
          0,
          [AST::Identifier.new(tok("input"), "input")],
          FsmTransform::Segments::Done.new(nil),
        ),
      ],
      synthetic_fields: [],
      alias_overrides_by_index: {},
    )

    expect(described_class.build_recursive(
      fsm_ctx(id: 12),
      segment_list,
      FsmTransform::Liveness::Result.new({}),
      lowering,
    )).to be_nil
  end

  it "threads owned suspend result guards through recursive NEXT lowering" do
    lowering = fsm_lowering_double do
      attr_reader :contexts, :capture_maps, :bg_pointer_captures

      def initialize
        @contexts = []
        @capture_maps = []
        @bg_pointer_captures = []
        @last_facts = []
      end

      def with_bg_fiber_body_context(pointer_captures)
        @bg_pointer_captures << pointer_captures
        yield
      end

      def with_fsm_segment_lowering_context(**kwargs)
        @contexts << kwargs
        yield
      end

      def with_fiber_capture_map(capture_map, rt_override:)
        @capture_maps << [capture_map, rt_override]
        yield
      end

      def lower(_node)
        MIR::Ident.new("future")
      end

      def lower_finalized_fsm_step_mir(ast_stmts, no_result:, ctx_id: nil)
        @last_facts = []
        [
          MIR::ExprStmt.new(
            MIR::Lit.new("#{ast_stmts.first.name}:#{no_result}:#{ctx_id || 0}"),
            false,
          ),
        ]
      end

      def last_fsm_result_transfer_facts
        @last_facts
      end

      def mir_schema_lookup
        nil
      end
    end
    promise = AST::Identifier.new(tok("future"), "future")
    promise.full_type = Type.new(:"~String")
    use_answer = AST::Identifier.new(tok("answer"), "answer")
    segment_list = FsmTransform::RecursiveSplitter::SegmentList.new(
      segments: [
        FsmTransform::Segments::Segment.new(
          0,
          [],
          FsmTransform::Segments::NextSuspend.new(promise, "answer", 1),
        ),
        FsmTransform::Segments::Segment.new(
          1,
          [use_answer],
          FsmTransform::Segments::Done.new(nil),
        ),
      ],
      synthetic_fields: [],
      alias_overrides_by_index: {},
    )

    result = T.must(described_class.build_recursive(
      fsm_ctx(id: 10, bg_rt: "__rt_bg10", pointer_captures: Set["future"], is_void: false),
      segment_list,
      FsmTransform::Liveness::Result.new({}),
      lowering,
    ))

    ctx_struct = result.body.ctx_struct
    expect(lowering.bg_pointer_captures).to eq([Set["future"]])
    expect(lowering.contexts.first[:pointer_captures]).to eq(Set["future"])
    expect(lowering.contexts.first[:owned_result_guards]).to eq("answer" => "__owned_answer_init")
    expect(lowering.capture_maps.last.first).to include("answer" => "__ctx_10.answer")
    expect(ctx_struct.extra_field_decls.map(&:name)).to include("sp_1", "answer", "__owned_answer_init")
    expect(ctx_struct.promoted_field_decls.map(&:name)).not_to include("answer")
    destroy_action = result.structure.destroy_actions.find { |action| action.respond_to?(:name) && action.name == "answer" }
    expect(destroy_action).to be_a(MIR::FsmDestroyCleanup)
    expect(MIREmitter.new.emit(destroy_action.guard)).to eq("__ctx_10.__owned_answer_init")
  end

  it "routes top-level FSM transform through a typed emit context" do
    bg_block = Struct.new(:body, :fsm_suspend_points).new([], [])
    segment_list = FsmTransform::RecursiveSplitter::SegmentList.new(
      segments: [
        FsmTransform::Segments::Segment.new(0, [], FsmTransform::Segments::Done.new(nil)),
      ],
      synthetic_fields: [],
      alias_overrides_by_index: {},
    )
    lowering = fsm_lowering_double do
      def with_fiber_capture_map(_capture_map, rt_override:)
        yield
      end
    end
    ctx = {
      id: 4,
      bg_rt: "__rt_bg4",
      blk_label: "__bg4",
      ctx_type: "__BgCtx4",
      promise_zig: "CheatHeader.Promise(void)",
      capture_fields: [],
      alloc_var: "__alloc_4",
      promise_var: "__promise_4",
      ctx_var: "__ctx_4_ptr",
      rt_name: "rt",
      promoted_decls: [],
      capture_inits: [],
      captured: {},
      capture_close_plans: {},
      pointer_captures: Set.new,
      is_void: true,
      pin_mode: false,
      parallel: false,
      extra_ctx_fields: [ctx_decl("existing", "i64", MIR::Lit.new("0"))],
    }
    structure = MIR::FsmStructure.new([], [], [], [], 4, nil)
    body = MIR::FsmGenericBody.new(
      "__bg4",
      MIR::FsmGenericCtxStruct.new("__BgCtx4", "CheatHeader.Promise(void)", [], [], [], [], MIR::FsmDispatch.new(4, [], false), []),
      MIR::FsmSpawnSetup.new(
        "__alloc_4",
        MIR::MethodCall.new(MIR::Ident.new("rt"), "heapAlloc", [], false),
        "__promise_4",
        "CheatHeader.Promise(void)",
        [],
        "__ctx_4_ptr",
        "__BgCtx4",
        [],
        MIR::FsmSpawnCall.new(target: :best, ctx_var: "__ctx_4_ptr"),
        "rt",
        0,
        0,
        nil,
      ),
    )
    result = MIR::FsmLoweringResult.new(body: body, structure: structure)

    allow(FsmTransform::RecursiveSplitter).to receive(:split).and_return(segment_list)
    allow(FsmTransform::Liveness).to receive(:analyze)
      .and_return(FsmTransform::Liveness::Result.new({}))
    allow(FsmTransform::Emit).to receive(:build_recursive).and_return(result)

    expect(FsmTransform.transform(bg_block, ctx, lowering)).to eq(result)
    expect(FsmTransform::Emit).to have_received(:build_recursive) do |emit_ctx, rec_segs, _liveness, used_lowering|
      expect(emit_ctx).to be_a(FsmTransform::Emit::FsmEmitContext)
      expect(emit_ctx.extra_ctx_fields.first.name).to eq("existing")
      expect(emit_ctx.extra_ctx_fields.first.type_zig).to eq("i64")
      expect(emit_ctx.extra_ctx_fields.first.default_value.value).to eq("0")
      expect(emit_ctx.recursive_promoted_names).to eq([])
      expect(rec_segs).to eq(segment_list)
      expect(used_lowering).to eq(lowering)
    end
  end

  it "rejects legacy string FSM context data at the transform boundary" do
    field = ctx_decl("payload", "i64", MIR::Lit.new("0"))
    init = MIR::StructInitField.new(name: :payload, value: MIR::Ident.new("payload"))
    stmt = MIR::ExprStmt.new(MIR::Lit.new("0"), false)

    expect(FsmTransform.coerce_context_fields(nil)).to eq([])
    expect(FsmTransform.coerce_context_fields([[field]])).to eq([field])
    expect(FsmTransform.coerce_context_inits(nil)).to eq([])
    expect(FsmTransform.coerce_context_inits([[init]])).to eq([init])
    expect(FsmTransform.coerce_promoted_decls(nil)).to eq([])
    expect(FsmTransform.coerce_promoted_decls([[stmt]])).to eq([stmt])

    expect { FsmTransform.coerce_context_fields("payload: i64 = 0,") }
      .to raise_error(TypeError, /ContextFieldDecl/)
    expect { FsmTransform.coerce_context_field("payload: i64 = 0,") }
      .to raise_error(TypeError, /ContextFieldDecl/)
    expect { FsmTransform.coerce_context_inits(".payload = payload,") }
      .to raise_error(TypeError, /StructInitField/)
    expect { FsmTransform.coerce_context_inits(["bad"]) }
      .to raise_error(TypeError, /StructInitField/)
    expect { FsmTransform.coerce_promoted_decls("const x = 0;") }
      .to raise_error(TypeError, /Emittable/)
    expect { FsmTransform.coerce_promoted_decls(["bad"]) }
      .to raise_error(TypeError, /Emittable/)
  end

  it "collects conservative promoted locals as typed facts" do
    first_acc = AST::VarDecl.new(tok("acc"), "acc", Type.new(:Int64), nil, true)
    duplicate_acc = AST::VarDecl.new(tok("acc"), "acc", Type.new(:String), nil, true)
    promise = AST::Identifier.new(tok("p"), "p")
    next_result = AST::BindExpr.new(tok("r"), "r", Type.new(:Int64), AST::NextExpr.new(tok("NEXT"), promise))
    next_result.mode = :decl
    first_acc.full_type = Type.new(:Int64)
    duplicate_acc.full_type = Type.new(:String)
    next_result.full_type = Type.new(:Int64)

    facts = FsmTransform.send(:collect_body_locals, [first_acc, duplicate_acc, next_result])

    expect(facts).to all(be_a(FsmTransform::PromotedLocalFact))
    expect(facts.map(&:name)).to eq(["acc", "r"])
    expect(facts.first.type_zig).to eq("i64")
    expect(facts.first.is_suspend_result).to eq(false)
    expect(facts.last.type_zig).to eq("i64")
    expect(facts.last.is_suspend_result).to eq(true)
  end
end
