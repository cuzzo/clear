require "rspec"
require_relative "../src/mir/fsm_transform/emit"

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
    lowering = Class.new {
      def with_fiber_capture_map(_capture_map, rt_override:)
        yield
      end

      def render_fsm_destroy_cleanup(target, _entry)
        "cleanup(#{target})"
      end
    }.new
    ctx = { fsm_destroy_lines: [] }
    kept = MIR::ExprStmt.new(MIR::Lit.new("keep()"), false)
    body = [MIR::Cleanup.new("payload_L2", CleanupEntry.new), kept]

    rewritten = described_class.lift_ctx_cleanups_to_destroy!(
      body, ["payload"], "__ctx_8", ctx, lowering)

    expect(rewritten).to eq([kept])
    expect(ctx[:fsm_destroy_lines].first.name).to eq("payload")
    expect(ctx[:fsm_destroy_lines].first.zig).to eq("cleanup(__ctx_8.payload)")
  end
end
