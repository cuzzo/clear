require 'bundler/setup'
require 'set'
require_relative '../src/mir/fsm_transform/emit'
require_relative '../src/mir/fsm_transform/liveness'
require_relative '../src/mir/fsm_transform/recursive_splitter'

# Tests for the FSM cleanup invariant: in any FSM-eligible BG body,
# `defer NAME.<method>(...)` may NEVER appear in a segment fn where
# NAME is a cross-segment ctx field. Such a defer would fire when
# its runSegN returns -- before the BG body has finished -- so the
# cleanup must be lifted to destroyTask via fsm_destroy_lines.
#
# Pre-fix history: capture cleanups WERE emitted as defers in seg
# 0's prologue (commit predating 4df184d8). Captures are
# cross-segment by definition, so the deinit fired before the body
# even ran -- silent use-after-free that compiled cleanly because
# Pass 3 (the MIR Checker) verifies cleanup pairing on a single-fn
# model and never sees Pass 4's segment splitting.
#
# This invariant closes the hole at the Pass 4 boundary: the FSM
# transform asserts before rendering that no forbidden cleanup node
# slipped through.

RSpec.describe FsmTransform::Emit do
  let(:liveness_double) {
    Class.new {
      def initialize(names) ; @names = names ; end
      def cross_segment_vars ; @names.to_h { |n| [n, nil] } ; end
    }
  }

  def fake_seg(idx)
    s = Object.new
    s.define_singleton_method(:index) { idx }
    s
  end

  def cleanup(name)
    MIR::Cleanup.new(name, CleanupEntry.new)
  end

  def err_cleanup(name)
    MIR::ErrCleanup.new(name, CleanupEntry.new)
  end

  describe "#check_fsm_cleanup_invariant!" do
    it "passes when no defers appear" do
      seg_codes = [[], []]
      expect {
        FsmTransform::Emit.check_fsm_cleanup_invariant!(
          seg_codes, [fake_seg(0), fake_seg(1)],
          liveness_double.new([]), {}, []
        )
      }.not_to raise_error
    end

    it "passes when a defer targets a segment-local var (not in any ctx set)" do
      # `tmp` is purely segment-local; defer on tmp is fine because
      # tmp lives entirely within this runSegN.
      seg_codes = [[cleanup("tmp")]]
      expect {
        FsmTransform::Emit.check_fsm_cleanup_invariant!(
          seg_codes, [fake_seg(0)],
          liveness_double.new([]), {}, []
        )
      }.not_to raise_error
    end

    it "raises when a defer targets a cross-segment liveness var" do
      seg_codes = [[cleanup("list")]]
      expect {
        FsmTransform::Emit.check_fsm_cleanup_invariant!(
          seg_codes, [fake_seg(0)],
          liveness_double.new(["list"]), {}, []
        )
      }.to raise_error(/cross-segment ctx field/)
    end

    it "raises when a defer targets a captured value" do
      # The historical bug: capture cleanup emitted as defer in
      # seg 0's prologue. The defer fires when seg 0 returns
      # (before the body completes) so the captured collection is
      # deinit'd while the body still references it.
      seg_codes = [[cleanup("s")]]
      captured = { "s" => :stub }
      expect {
        FsmTransform::Emit.check_fsm_cleanup_invariant!(
          seg_codes, [fake_seg(0)],
          liveness_double.new([]), captured, []
        )
      }.to raise_error(/cross-segment ctx field/)
    end

    it "raises when an errdefer targets a cross-segment var" do
      seg_codes = [[err_cleanup("X")]]
      expect {
        FsmTransform::Emit.check_fsm_cleanup_invariant!(
          seg_codes, [fake_seg(0)],
          liveness_double.new(["X"]), {}, []
        )
      }.to raise_error(/cross-segment ctx field/)
    end

    it "raises when a defer targets a conservatively-promoted local" do
      seg_codes = [[cleanup("promoted")]]
      expect {
        FsmTransform::Emit.check_fsm_cleanup_invariant!(
          seg_codes, [fake_seg(0)],
          liveness_double.new([]), {}, ["promoted"]
        )
      }.to raise_error(/cross-segment ctx field/)
    end

    it "names the offending segment in the error message" do
      seg_codes = [[], [cleanup("s")]]
      expect {
        FsmTransform::Emit.check_fsm_cleanup_invariant!(
          seg_codes, [fake_seg(0), fake_seg(7)],
          liveness_double.new([]), { "s" => :stub }, []
        )
      }.to raise_error(/seg 7 /)
    end
  end

  describe ".build_recursive cleanup registration" do
    it "routes resource capture close code through destroyTask" do
      lowering = Class.new {
        def capture_inits_fsm(_capture_inits)
          ""
        end
      }.new
      segment_list = FsmTransform::RecursiveSplitter::SegmentList.new(
        segments: [
          FsmTransform::Segments::Segment.new(
            0, [], FsmTransform::Segments::Done.new(nil)
          ),
        ],
        synthetic_fields: [],
        alias_overrides_by_index: {},
      )
      ctx = {
        id: 3,
        bg_rt: "__rt_bg3",
        captured: { "resource" => :stub },
        capture_close_zig: { "resource" => "rt.close({0})" },
        pointer_captures: Set.new,
        is_void: true,
        ctx_type: "__BgCtx3",
        promise_zig: "CheatHeader.Promise(void)",
        capture_fields: "resource: i32 = 0,\n",
        blk_label: "__bg3",
        rt_name: "rt",
        ctx_var: "__ctx_3_ptr",
        promise_var: "__promise_3",
        alloc_var: "__alloc_3",
        capture_inits: [],
        promoted_decls: "",
        pin_mode: false,
        parallel: false,
        extra_ctx_fields: [],
        recursive_promoted_names: [],
        fresh_heap_cleanup_names: [],
        fresh_heap_cleanups: "",
      }

      result = FsmTransform::Emit.build_recursive(
        ctx, segment_list, FsmTransform::Liveness::Result.new({}), lowering)

      expect(result).to be_a(MIR::FsmLoweringResult)
      expect(result.code).to include("__ctx_3.rt.close(__ctx_3.resource);")
      expect(result.structure.captures).to include(name: "resource", cleanup_at: :finalize)
    end

    it "registers owned suspend result cleanup once" do
      descriptor = MIR::SuspendDescriptor.new(
        [], [], MIR::FsmTailYield.new(1, "next"), [],
        "payload", "[]const u8", true,
      )
      ctx = {}

      FsmTransform::Emit.send(:register_owned_suspend_result_cleanups!,
        [{ descriptor: descriptor }, { descriptor: descriptor }], ctx, 7)

      lines = ctx.fetch(:fsm_destroy_lines)
      expect(lines.length).to eq(1)
      expect(lines.first.kind).to eq(:body)
      expect(lines.first.name).to eq("payload")
      expect(lines.first.zig).to include("__ctx_7.__owned_payload_init")
      expect(lines.first.zig).to include("__ctx_7.payload")
    end

    it "collects guard fields for cleanup-bearing suspend results" do
      promise = AST::Identifier.new(nil, "p")
      promise.full_type = Type.new(:"~String")
      segment = FsmTransform::Segments::Segment.new(
        0,
        [],
        FsmTransform::Segments::NextSuspend.new(promise, "payload", 1),
      )

      guards = FsmTransform::Emit.send(:fsm_owned_result_guards, [segment], Object.new)

      expect(guards).to eq("payload" => "__owned_payload_init")
    end
  end
end
