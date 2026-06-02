require 'bundler/setup'
require 'set'
require_relative '../src/mir/fsm_transform/emit'

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
end
