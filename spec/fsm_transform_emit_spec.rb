require "rspec"
require_relative "../src/mir/fsm_transform"
require_relative "../src/mir/fsm_transform/emit"
require_relative "../src/mir/fsm_transform/segments"

RSpec.describe FsmTransform::Emit do
  def fsm_ctx(overrides = {})
    FsmTransform::Emit::FsmEmitContext.from_hash({
      id: 1,
      bg_rt: "__rt_bg1",
      blk_label: "__bg1",
      ctx_type: "__BgCtx1",
      promise_zig: "CheatHeader.Promise(void)",
      capture_fields: "",
      alloc_var: "__alloc_1",
      promise_var: "__promise_1",
      ctx_var: "__ctx_1_ptr",
      rt_name: "rt",
      promoted_decls: "",
      capture_inits: "",
      captured: {},
      capture_close_zig: {},
      pointer_captures: Set.new,
      is_void: true,
      pin_mode: false,
      parallel: false,
    }.merge(overrides))
  end

  def fsm_spec(attrs)
    FsmTransform::Emit::FsmSegmentSpec.new(
      index: attrs.fetch(:index),
      prologue_stmts: attrs.fetch(:prologue_stmts, []),
      body_stmts: attrs.fetch(:body_stmts, []),
      structure_stmts: attrs.fetch(:structure_stmts, []),
      tail: attrs.fetch(:tail),
      descriptor: attrs[:descriptor],
      fsm_result_transfer_facts: attrs.fetch(:fsm_result_transfer_facts, []),
      fn_name: attrs[:fn_name],
      rt_suppress: attrs.fetch(:rt_suppress, ""),
      facts: attrs.fetch(:facts, FsmTransform::Emit::FsmSegmentFacts.empty),
    )
  end

  it "maps profile dispatch ids and emits task-site comments" do
    expect(described_class.profile_dispatch_id(:local)).to eq(1)
    expect(described_class.profile_dispatch_id(:parallel)).to eq(2)
    expect(described_class.profile_dispatch_id(:shared)).to eq(3)
    expect(described_class.profile_dispatch_id(:unexpected)).to eq(1)

    ctx = fsm_ctx(profile_site_id: 11, profile_line: 22, profile_column: 5)
    expect(described_class.bg_profile_site_comment(ctx, :parallel, :fsm))
      .to eq("// CLEAR_PROFILE_TASK_SITE id=11 kind=BG line=22 column=5 dispatch=parallel form=fsm")
  end

  it "exposes typed context compatibility reads and cloning" do
    ctx = fsm_ctx(id: 12, bg_rt: "__rt_bg12", captured: { "payload" => :stub })

    expect(ctx[:id]).to eq(12)
    expect(ctx[:bg_rt]).to eq("__rt_bg12")
    expect(ctx[:captured]).to eq("payload" => :stub)
    expect(ctx[:missing]).to be_nil

    updated = ctx.with_extra_ctx_fields(["payload: i64 = 0,"])
    expect(updated.extra_ctx_fields).to eq(["payload: i64 = 0,"])
    expect(updated.id).to eq(12)
  end

  it "returns nil for an empty unified FSM and skips fn-less inert segments" do
    expect(described_class.build_fsm_unified(fsm_ctx, [], [], Object.new)).to be_nil

    lowering = Class.new {
      def capture_inits_fsm(_capture_inits)
        ""
      end
    }.new
    result = described_class.build_fsm_unified(
      fsm_ctx,
      [fsm_spec(index: 0, body_stmts: [], tail: FsmTransform::Segments::Done.new(nil))],
      [],
      lowering,
    )

    expect(result).to be_a(MIR::FsmLoweringResult)
    expect(result.code).not_to include("fn runSeg0")
  end

  it "returns no resume target for terminal segment tails" do
    expect(described_class.tail_resume_target(FsmTransform::Segments::Done.new(nil))).to be_nil
  end

  it "derives segment facts from MIR roots and ignores rendered body text" do
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
      body_stmts: ["__ctx_12.fake_moved = true;"],
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

    facts = described_class.build_fsm_segment_facts(spec, 12, ["payload"])

    expect(facts.ctx_reads).to include("payload", "payload_moved", "inner")
    expect(facts.required_move_guards).to eq(["payload"])
    expect(facts.move_guard_writes).to include("payload", "__ctx_12.payload")
    expect(facts.move_guard_writes).not_to include("fake")
    expect(facts.result_names).to eq(["payload"])
    expect(facts.ownership_facts.map(&:name)).to eq(["payload"])
    expect(described_class.fsm_fact_guard_name("__ctx_12")).to eq("")
    expect(described_class.fsm_fact_guard_name("__ctx_12.payload")).to eq("payload")
    expect(described_class.promoted_fsm_field_name("payload_L3_moved", ["payload"]))
      .to eq("payload_moved")
  end

  it "builds FSM structure from materialized segment facts" do
    cleanup_entry = CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: true)
    action = MIR::FsmDestroyCleanup.new(
      source_kind: :capture,
      name: "payload",
      target_zig: "__ctx_33.payload",
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
      body_stmts: ["__ctx_33.ignored = true;"],
      tail: FsmTransform::Segments::Done.new(nil),
      facts: FsmTransform::Emit::FsmSegmentFacts.new(
        ctx_reads: ["payload"],
        required_move_guards: ["payload"],
        move_guard_writes: ["payload"],
        result_names: ["payload"],
        ownership_facts: [fact],
      ),
    )

    structure = described_class.build_fsm_structure(
      fsm_ctx(id: 33, captured: { "payload" => :stub }),
      [spec],
      [action],
      33,
    )

    expect(structure.steps).to eq([{ index: 0, reads: ["payload"], cleanups: [] }])
    expect(structure.captures).to eq([{ name: "payload", cleanup_at: :finalize }])
    expect(structure.required_move_guards).to eq(["payload"])
    expect(structure.move_guard_writes).to eq(["payload"])
    expect(structure.ownership_facts).to eq([fact])
  end

  it "accepts zig_text conditions and rejects unresolved condition ASTs" do
    cond = Struct.new(:zig_text).new("has_work")
    tail = FsmTransform::Segments::CondBranch.new(cond, 2, 3)
    spec = fsm_spec(index: 1, tail: tail, descriptor: nil)
    lowered = described_class.build_dispatch_tail(spec, 0, [], 7)

    expect(lowered).to be_a(MIR::FsmTailCondJump)
    expect(lowered.cond_zig).to eq("has_work")

    bad_tail = FsmTransform::Segments::CondBranch.new(Object.new, 2, 3)
    expect {
      described_class.build_dispatch_tail(fsm_spec(index: 1, tail: bad_tail, descriptor: nil), 0, [], 7)
    }.to raise_error(ArgumentError, /CondBranch tail's cond_ast/)
  end

  it "rejects unsupported suspend descriptor tails" do
    descriptor = MIR::SuspendDescriptor.new(
      [], [], MIR::FsmTailDone.new(nil), [], nil, nil, false
    )
    tail = FsmTransform::Segments::NextSuspend.new(Object.new, nil)

    expect {
      described_class.build_dispatch_tail(fsm_spec(index: 4, tail: tail, descriptor: descriptor), 0, [], 7)
    }.to raise_error(ArgumentError, /Unsupported descriptor tail/)
  end

  it "rejects suspend tails that have not been resolved to descriptors" do
    tail = FsmTransform::Segments::NextSuspend.new(Object.new, nil)

    expect {
      described_class.build_dispatch_tail(fsm_spec(index: 4, tail: tail, descriptor: nil), 0, [], 7)
    }.to raise_error(ArgumentError, /has no descriptor/)
  end

  it "wraps suspend descriptor resolution in the fiber lowering context" do
    descriptor = MIR::SuspendDescriptor.new(
      [], [], MIR::FsmTailYield.new(3, "WaitForLock"), [], nil, nil, false
    )
    lowering = Class.new {
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
    }.new
    allow(FsmTransform::SuspendResolvers).to receive(:resolve).and_return(descriptor)
    ctx = fsm_ctx(bg_rt: "__rt_bg3", pointer_captures: Set["payload"])
    segment = FsmTransform::Segments::Segment.new(
      2, [], FsmTransform::Segments::NextSuspend.new(Object.new, "payload", 4)
    )

    result = described_class.build_segment_descriptor(
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

    rewritten = described_class.lift_ctx_cleanups_to_destroy!(
      body, ["payload"], "__ctx_8", ctx)

    expect(rewritten).to eq([kept])
    action = described_class.fsm_destroy_actions(ctx).first
    expect(action).to be_a(MIR::FsmDestroyCleanup)
    expect(action.name).to eq("payload")
    expect(action.target_zig).to eq("__ctx_8.payload")
    expect(action.cleanup_entry).to eq(entry)
  end

  it "orders lock releases before capture and body cleanups" do
    cleanup_entry = CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: false)
    ctx = fsm_ctx
    described_class.fsm_destroy_actions(ctx) << MIR::FsmDestroyCleanup.new(
      source_kind: :body,
      name: "body",
      target_zig: "__ctx_1.body",
      cleanup_entry: cleanup_entry,
    )
    described_class.fsm_destroy_actions(ctx) << MIR::FsmDestroyLockRelease.new(
      name: "__ctx_1.lock_a",
      guard_field: "__lock_held_0",
      lock_ref_zig: "__ctx_1.lock_a",
      unlock_method: "unlock",
    )
    described_class.fsm_destroy_actions(ctx) << MIR::FsmDestroyCleanup.new(
      source_kind: :capture,
      name: "cap",
      target_zig: "__ctx_1.cap",
      cleanup_entry: cleanup_entry,
    )
    described_class.fsm_destroy_actions(ctx) << MIR::FsmDestroyLockRelease.new(
      name: "__ctx_1.lock_b",
      guard_field: "__lock_held_1",
      lock_ref_zig: "__ctx_1.lock_b",
      unlock_method: "unlock",
    )

    ordered = described_class.ordered_fsm_destroy_actions(ctx)

    expect(ordered.map(&:name)).to eq(["__ctx_1.lock_b", "__ctx_1.lock_a", "cap", "body"])
  end

  it "builds parallel FSM spawn setup with heap allocation" do
    lowering = Class.new {
      def capture_inits_fsm(capture_inits)
        capture_inits
      end
    }.new
    ctx = fsm_ctx(
      id: 8,
      ctx_var: "__ctx_8_ptr",
      rt_name: "rt",
      parallel: true,
      pin_mode: false,
      capture_inits: ".payload = payload,",
    )

    setup = described_class.build_spawn_setup(ctx, lowering)

    expect(setup.spawn_call_zig).to eq("try CheatHeader.spawnFsmBest(__ctx_8_ptr.task);")
    expect(setup.alloc_expr_zig).to eq("rt.heapAlloc()")
    expect(setup.ctx_init_zig).to include(".payload = payload,")
  end

  it "registers structural lock release actions while expanding lock segments" do
    lowering = Class.new {
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
        Struct.new(:body_zig, :exit_kind).new("", :goto_post)
      end
    }.new
    with_node = Struct.new(:lock_error_clause).new(nil)
    tail = FsmTransform::Segments::LockSuspend.new(with_node, :cap, [], 9, 10)
    spec = fsm_spec(
      index: 1,
      prologue_stmts: [],
      body_stmts: [],
      tail: tail,
      fn_name: nil,
      rt_suppress: "",
    )
    ctx = fsm_ctx(
      id: 7,
      bg_rt: "__rt_bg7",
      captured: { "lock" => :stub },
      pointer_captures: Set.new,
      rt_name: "rt",
    )

    expanded = described_class.expand_lock_segment(spec, ctx, {}, lowering, 20)

    expect(expanded.extra_fields).to include("__lock_held_0: bool = false,")
    action = described_class.fsm_destroy_actions(ctx).first
    expect(action).to be_a(MIR::FsmDestroyLockRelease)
    expect(action.guard_field).to eq("__lock_held_0")
    expect(action.lock_ref_zig).to eq("__ctx_7.lock")
    expect(action.unlock_method).to eq("unlock")
  end

  it "expands prior-lock releases and explicit lock error arms structurally" do
    error_clause = Object.new
    lowering = Class.new {
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

      def emit_fsm_lock_error_arm_split(clause:, ctx_id:, with_node:, capture_map:, pointer_captures:, bg_rt:, rt_name:)
        @error_calls << [clause, ctx_id, with_node, capture_map, pointer_captures, bg_rt, rt_name]
        Struct.new(:body_zig, :exit_kind).new("handleLockError();", :done)
      end
    }.new
    with_node = Struct.new(:lock_error_clause).new(error_clause)
    tail = FsmTransform::Segments::LockSuspend.new(with_node, :current, [:prior], 9, 10)
    spec = fsm_spec(
      index: 1,
      body_stmts: [MIR::ExprStmt.new(MIR::Lit.new("beforeLock()"), false)],
      tail: tail,
      fn_name: "runLock",
    )
    ctx = fsm_ctx(id: 7, bg_rt: "__rt_bg7", captured: { "lock" => :stub }, pointer_captures: Set["lock"])

    expanded = described_class.expand_lock_segment(
      spec, ctx, { "lock" => "__ctx_7.lock" }, lowering, 20
    )

    fail_spec = expanded.appended_specs[2]
    expect(expanded.lock_try_spec.fn_name).to eq("runLock")
    expect(fail_spec.pre_body_zig).to include("__ctx_7.__lock_held_0 = false;")
    expect(fail_spec.pre_body_zig).to include("__ctx_7.lock_prior.unlockprior();")
    expect(fail_spec.pre_body_zig).to include("handleLockError();")
    expect(fail_spec.tail).to be_a(FsmTransform::Segments::Done)
    expect(expanded.extra_fields).to include("retry_count: u32 = 0,")
    expect(lowering.error_calls.first).to eq([
      error_clause,
      7,
      with_node,
      { "lock" => "__ctx_7.lock" },
      Set["lock"],
      "__rt_bg7",
      "rt",
    ])
  end

  it "applies lock expansion through recursive FSM build" do
    lowering = Class.new {
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
        Struct.new(:body_zig, :exit_kind).new("", :goto_post)
      end
    }.new
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
    expect(result.code).to include("__lock_held_0: bool = false,")
    expect(result.structure.destroy_actions.first).to be_a(MIR::FsmDestroyLockRelease)
    expect(result.structure.destroy_actions.first.guard_field).to eq("__lock_held_0")
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
    lowering = Class.new {
      def with_fiber_capture_map(_capture_map, rt_override:)
        yield
      end
    }.new
    ctx = {
      id: 4,
      bg_rt: "__rt_bg4",
      blk_label: "__bg4",
      ctx_type: "__BgCtx4",
      promise_zig: "CheatHeader.Promise(void)",
      capture_fields: "",
      alloc_var: "__alloc_4",
      promise_var: "__promise_4",
      ctx_var: "__ctx_4_ptr",
      rt_name: "rt",
      promoted_decls: "",
      capture_inits: "",
      captured: {},
      capture_close_zig: {},
      pointer_captures: Set.new,
      is_void: true,
      pin_mode: false,
      parallel: false,
      extra_ctx_fields: ["existing: i64 = 0,"],
    }
    structure = MIR::FsmStructure.new([], [], [], [], 4, nil)
    result = MIR::FsmLoweringResult.new(code: "code", structure: structure)

    allow(FsmTransform::RecursiveSplitter).to receive(:split).and_return(segment_list)
    allow(FsmTransform::Liveness).to receive(:analyze)
      .and_return(FsmTransform::Liveness::Result.new({}))
    allow(FsmTransform::Emit).to receive(:build_recursive).and_return(result)

    expect(FsmTransform.transform(bg_block, ctx, lowering)).to eq(result)
    expect(FsmTransform::Emit).to have_received(:build_recursive) do |emit_ctx, rec_segs, _liveness, used_lowering|
      expect(emit_ctx).to be_a(FsmTransform::Emit::FsmEmitContext)
      expect(emit_ctx.extra_ctx_fields).to eq(["existing: i64 = 0,"])
      expect(emit_ctx.recursive_promoted_names).to eq([])
      expect(rec_segs).to eq(segment_list)
      expect(used_lowering).to eq(lowering)
    end
  end
end
