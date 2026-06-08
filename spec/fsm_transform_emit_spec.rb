require "rspec"
require_relative "../src/mir/fsm_transform/emit"
require_relative "../src/mir/fsm_transform/segments"

RSpec.describe FsmTransform::Emit do
  it "maps profile dispatch ids and emits task-site comments" do
    expect(described_class.profile_dispatch_id(:local)).to eq(1)
    expect(described_class.profile_dispatch_id(:parallel)).to eq(2)
    expect(described_class.profile_dispatch_id(:shared)).to eq(3)
    expect(described_class.profile_dispatch_id(:unexpected)).to eq(1)

    ctx = { profile_site_id: 11, profile_line: 22, profile_column: 5 }
    expect(described_class.bg_profile_site_comment(ctx, :parallel, :fsm))
      .to eq("// CLEAR_PROFILE_TASK_SITE id=11 kind=BG line=22 column=5 dispatch=parallel form=fsm")
  end

  it "filters non-renderable structure sources and normalizes ctx ownership fact names" do
    ident = MIR::Ident.new("value")

    expect(described_class.fsm_structure_source_array(["raw;", ident, Object.new]))
      .to eq(["raw;", ident])
    expect(described_class.fsm_fact_guard_name("__ctx_12")).to eq("")
    expect(described_class.fsm_fact_guard_name("__ctx_12.payload")).to eq("payload")
    expect(described_class.promoted_fsm_field_name("payload_L3_moved", ["payload"]))
      .to eq("payload_moved")
  end

  it "accepts zig_text conditions and rejects unresolved condition ASTs" do
    cond = Struct.new(:zig_text).new("has_work")
    tail = FsmTransform::Segments::CondBranch.new(cond, 2, 3)
    lowered = described_class.build_dispatch_tail({ index: 1, tail: tail, descriptor: nil }, 0, [], 7)

    expect(lowered).to be_a(MIR::FsmTailCondJump)
    expect(lowered.cond_zig).to eq("has_work")

    bad_tail = FsmTransform::Segments::CondBranch.new(Object.new, 2, 3)
    expect {
      described_class.build_dispatch_tail({ index: 1, tail: bad_tail, descriptor: nil }, 0, [], 7)
    }.to raise_error(ArgumentError, /CondBranch tail's cond_ast/)
  end

  it "rejects unsupported suspend descriptor tails" do
    descriptor = MIR::SuspendDescriptor.new(
      [], [], MIR::FsmTailDone.new(nil), [], nil, nil, false
    )
    tail = FsmTransform::Segments::NextSuspend.new(Object.new, nil)

    expect {
      described_class.build_dispatch_tail({ index: 4, tail: tail, descriptor: descriptor }, 0, [], 7)
    }.to raise_error(ArgumentError, /Unsupported descriptor tail/)
  end

  it "lifts promoted ctx cleanups into destroyTask lines" do
    ctx = { fsm_destroy_actions: [] }
    kept = MIR::ExprStmt.new(MIR::Lit.new("keep()"), false)
    entry = CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: false)
    body = [MIR::Cleanup.new("payload_L2", entry), kept]

    rewritten = described_class.lift_ctx_cleanups_to_destroy!(
      body, ["payload"], "__ctx_8", ctx)

    expect(rewritten).to eq([kept])
    action = ctx[:fsm_destroy_actions].first
    expect(action).to be_a(MIR::FsmDestroyCleanup)
    expect(action.name).to eq("payload")
    expect(action.target_zig).to eq("__ctx_8.payload")
    expect(action.cleanup_entry).to eq(entry)
  end

  it "orders lock releases before capture and body cleanups" do
    cleanup_entry = CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: false)
    ctx = { fsm_destroy_actions: [] }
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
    spec = {
      index: 1,
      prologue_stmts: [],
      body_stmts: [],
      tail: tail,
      fn_name: nil,
      rt_suppress: "",
    }
    ctx = {
      id: 7,
      bg_rt: "__rt_bg7",
      captured: { "lock" => :stub },
      pointer_captures: Set.new,
      rt_name: "rt",
    }

    expanded = described_class.expand_lock_segment(spec, ctx, {}, lowering, 20)

    expect(expanded[:extra_fields]).to include("__lock_held_0: bool = false,")
    action = described_class.fsm_destroy_actions(ctx).first
    expect(action).to be_a(MIR::FsmDestroyLockRelease)
    expect(action.guard_field).to eq("__lock_held_0")
    expect(action.lock_ref_zig).to eq("__ctx_7.lock")
    expect(action.unlock_method).to eq("unlock")
  end
end
