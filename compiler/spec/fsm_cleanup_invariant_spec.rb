require 'bundler/setup'
require 'set'
require_relative '../ruby/mir/fsm_transform/emit' unless defined?(FsmTransform::Emit::ExpandedLockSegment)
require_relative '../ruby/mir/fsm_transform' unless defined?(FsmTransform::PromotedLocalFact)
require_relative '../ruby/mir/fsm_transform/liveness' unless defined?(FsmTransform::Liveness::CrossSegmentVarFact)
require_relative '../ruby/mir/fsm_transform/recursive_splitter' unless defined?(FsmTransform::RecursiveSplitter::UnsupportedShape)
require_relative '../ruby/backends/fsm_wrapper_emitter' unless defined?(FsmWrapperEmitter)

# Tests for the FSM cleanup invariant: in any FSM-eligible BG body,
# `defer NAME.<method>(...)` may NEVER appear in a segment fn where
# NAME is a cross-segment ctx field. Such a defer would fire when
# its runSegN returns -- before the BG body has finished -- so the
# cleanup must be lifted to destroyTask via fsm_destroy_actions.
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
  def fsm_body_items(stmts)
    stmts.map do |stmt|
      FsmTransform::Emit.fsm_body_mir_item(stmt)
    end
  end

  def render_expr(expr)
    MIREmitter.new.emit(expr)
  end

  def ctx_decl(name, type_zig, default_value = nil)
    MIR::ContextFieldDecl.new(name: name, type_zig: type_zig, default_value: default_value)
  end

  def liveness_result(names)
    FsmTransform::Liveness::Result.new(
      names.to_h do |name|
        [name, FsmTransform::Liveness::CrossSegmentVarFact.new(
          type_info: nil,
          first_def_seg: 0,
          last_use_seg: 1,
        )]
      end
    )
  end

  def fake_seg(idx)
    FsmTransform::Segments::Segment.new(idx, [], FsmTransform::Segments::Done.new(nil))
  end

  def fsm_lowering_double(&block)
    klass = Class.new do
      include FsmTransform::LoweringProtocol
    end
    klass.class_eval(&block) if block
    klass.new
  end

  def cleanup(name)
    MIR::Cleanup.new(name, CleanupEntry.new)
  end

  def err_cleanup(name)
    MIR::ErrCleanup.new(name, CleanupEntry.new)
  end

  def fsm_ctx(overrides = {})
    raw = {
      id: 1,
      bg_rt: "__rt_bg1",
      captured: {},
      capture_close_plans: {},
      pointer_captures: Set.new,
      is_void: true,
      ctx_type: "__BgCtx1",
      promise_zig: "CheatHeader.Promise(void)",
      capture_fields: [],
      blk_label: "__bg1",
      rt_name: "rt",
      ctx_var: "__ctx_1_ptr",
      promise_var: "__promise_1",
      alloc_var: "__alloc_1",
      capture_inits: [],
      promoted_decls: [],
      pin_mode: false,
      parallel: false,
      extra_ctx_fields: [],
      recursive_promoted_names: [],
      fresh_heap_cleanup_names: [],
      arena_init_flag: false,
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
      extra_ctx_fields: raw.fetch(:extra_ctx_fields),
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

  def fsm_spec(attrs)
    FsmTransform::Emit::FsmSegmentSpec.new(
      index: attrs.fetch(:index),
      body_stmts: fsm_body_items(attrs.fetch(:body_stmts, [])),
      tail: attrs.fetch(:tail),
      descriptor: attrs[:descriptor],
    )
  end

  describe "#check_fsm_cleanup_invariant!" do
    it "passes when no defers appear" do
      seg_codes = [[], []]
      expect {
        FsmTransform::Emit.send(:check_fsm_cleanup_invariant!,
          seg_codes, [fake_seg(0), fake_seg(1)],
          liveness_result([]), {}, []
        )
      }.not_to raise_error
    end

    it "passes when a defer targets a segment-local var (not in any ctx set)" do
      # `tmp` is purely segment-local; defer on tmp is fine because
      # tmp lives entirely within this runSegN.
      seg_codes = [[cleanup("tmp")]]
      expect {
        FsmTransform::Emit.send(:check_fsm_cleanup_invariant!,
          seg_codes, [fake_seg(0)],
          liveness_result([]), {}, []
        )
      }.not_to raise_error
    end

    it "raises when a defer targets a cross-segment liveness var" do
      seg_codes = [[cleanup("list")]]
      expect {
        FsmTransform::Emit.send(:check_fsm_cleanup_invariant!,
          seg_codes, [fake_seg(0)],
          liveness_result(["list"]), {}, []
        )
      }.to raise_error(/cross-segment ctx field/)
    end

    it "raises when a defer targets a captured value" do
      # The historical bug: capture cleanup emitted as defer in
      # seg 0's prologue. The defer fires when seg 0 returns
      # (before the body completes) so the captured collection is
      # deinit'd while the body still references it.
      seg_codes = [[cleanup("s")]]
      captured = { "s" => Type.new(:Any) }
      expect {
        FsmTransform::Emit.send(:check_fsm_cleanup_invariant!,
          seg_codes, [fake_seg(0)],
          liveness_result([]), captured, []
        )
      }.to raise_error(/cross-segment ctx field/)
    end

    it "raises when an errdefer targets a cross-segment var" do
      seg_codes = [[err_cleanup("X")]]
      expect {
        FsmTransform::Emit.send(:check_fsm_cleanup_invariant!,
          seg_codes, [fake_seg(0)],
          liveness_result(["X"]), {}, []
        )
      }.to raise_error(/cross-segment ctx field/)
    end

    it "raises when a defer targets a conservatively-promoted local" do
      seg_codes = [[cleanup("promoted")]]
      expect {
        FsmTransform::Emit.send(:check_fsm_cleanup_invariant!,
          seg_codes, [fake_seg(0)],
          liveness_result([]), {}, ["promoted"]
        )
      }.to raise_error(/cross-segment ctx field/)
    end

    it "names the offending segment in the error message" do
      seg_codes = [[], [cleanup("s")]]
      expect {
        FsmTransform::Emit.send(:check_fsm_cleanup_invariant!,
          seg_codes, [fake_seg(0), fake_seg(7)],
          liveness_result([]), { "s" => Type.new(:Any) }, []
        )
      }.to raise_error(/seg 7 /)
    end
  end

  describe ".build_recursive cleanup registration" do
    it "routes resource capture close code through destroyTask" do
      lowering = fsm_lowering_double do
        def capture_inits_fsm(_capture_inits)
          ""
        end
      end
      segment_list = FsmTransform::RecursiveSplitter::SegmentList.new(
        segments: [
          FsmTransform::Segments::Segment.new(
            0, [], FsmTransform::Segments::Done.new(nil)
          ),
        ],
        synthetic_fields: [],
        alias_overrides_by_index: {},
      )
      ctx = fsm_ctx(
        id: 3,
        bg_rt: "__rt_bg3",
        captured: { "resource" => :stub },
        capture_close_plans: { "resource" => Schemas::ResourceClosePlan.function("CheatLib.closeResource") },
        pointer_captures: Set.new,
        is_void: true,
        ctx_type: "__BgCtx3",
        promise_zig: "CheatHeader.Promise(void)",
        capture_fields: [ctx_decl("resource", "i32", MIR::Lit.new("0"))],
        blk_label: "__bg3",
        rt_name: "rt",
        ctx_var: "__ctx_3_ptr",
        promise_var: "__promise_3",
        alloc_var: "__alloc_3",
        capture_inits: [],
        promoted_decls: [],
        pin_mode: false,
        parallel: false,
        extra_ctx_fields: [],
        recursive_promoted_names: [],
        fresh_heap_cleanup_names: [],
      )

      result = FsmTransform::Emit.build_recursive(
        ctx, segment_list, FsmTransform::Liveness::Result.new({}), lowering)

      expect(result).to be_a(MIR::FsmLoweringResult)
      expect(FsmWrapperEmitter.render(result.body)).to include("CheatLib.closeResource(__ctx_3.resource);")
      capture = T.must(result.structure.captures.find { |fact| fact.name == "resource" })
      expect(capture.cleanup_at).to eq(:finalize)
      action = result.structure.destroy_actions.find { |entry| entry.is_a?(MIR::FsmDestroyCleanup) }
      expect(action.source_kind).to eq(:capture)
      expect(render_expr(action.target)).to eq("__ctx_3.resource")
      expect(action.cleanup_entry.kind).to eq(:resource)
      expect(action.cleanup_entry.resource_close_plan&.actions&.map(&:name)).to eq(["CheatLib.closeResource"])
    end

    it "routes FreshHeapCopy capture cleanup through structural destroyTask actions" do
      lowering = fsm_lowering_double do
        def capture_inits_fsm(_capture_inits)
          ""
        end
      end
      segment_list = FsmTransform::RecursiveSplitter::SegmentList.new(
        segments: [
          FsmTransform::Segments::Segment.new(
            0, [], FsmTransform::Segments::Done.new(nil)
          ),
        ],
        synthetic_fields: [],
        alias_overrides_by_index: {},
      )
      ctx = fsm_ctx(
        id: 4,
        bg_rt: "__rt_bg4",
        captured: { "owned" => :stub },
        capture_close_plans: {},
        pointer_captures: Set.new,
        is_void: true,
        ctx_type: "__BgCtx4",
        promise_zig: "CheatHeader.Promise(void)",
        capture_fields: [
          ctx_decl("owned", "i32", MIR::Lit.new("0")),
          ctx_decl("owned_moved", "bool", MIR::Lit.new("false")),
        ],
        blk_label: "__bg4",
        rt_name: "rt",
        ctx_var: "__ctx_4_ptr",
        promise_var: "__promise_4",
        alloc_var: "__alloc_4",
        capture_inits: [],
        promoted_decls: [],
        pin_mode: false,
        parallel: false,
        extra_ctx_fields: [],
        recursive_promoted_names: [],
        fresh_heap_cleanup_names: ["owned"],
      )

      result = FsmTransform::Emit.build_recursive(
        ctx, segment_list, FsmTransform::Liveness::Result.new({}), lowering)

      expect(result).to be_a(MIR::FsmLoweringResult)
      expect(FsmWrapperEmitter.render(result.body)).to include(
        "if (!__ctx_4.owned_moved) CheatLib.cleanup(@TypeOf(__ctx_4.owned), __ctx_4.alloc, &__ctx_4.owned);"
      )
      action = result.structure.destroy_actions.find { |entry|
        entry.is_a?(MIR::FsmDestroyCleanup) && entry.name == "owned"
      }
      expect(action.source_kind).to eq(:fresh_heap)
      expect(render_expr(action.allocator)).to eq("__ctx_4.alloc")
    end

    it "passes destroy-action ctx fields into segment ownership lowering" do
      lowering = fsm_lowering_double do
        attr_reader :contexts

        def initialize
          @contexts = []
        end

        def capture_inits_fsm(_capture_inits)
          ""
        end

        def with_fsm_segment_lowering_context(pointer_captures:, inherited_alloc_names:, inherited_guard_names:, owned_result_guards:)
          @contexts << {
            pointer_captures: pointer_captures,
            inherited_alloc_names: inherited_alloc_names,
            inherited_guard_names: inherited_guard_names,
            owned_result_guards: owned_result_guards,
          }
          yield
        end

        def with_fiber_capture_map(_capture_map, rt_override:)
          yield
        end

        def lower_finalized_fsm_step_mir(_stmts, no_result:, ctx_id: nil)
          [MIR::ExprStmt.new(MIR::Lit.new("work()"), false)]
        end

        def last_fsm_result_transfer_facts
          []
        end
      end
      expr = AST::Literal.new(nil, :NUMBER, 1, nil)
      expr.full_type = :Int64
      segment_list = FsmTransform::RecursiveSplitter::SegmentList.new(
        segments: [
          FsmTransform::Segments::Segment.new(
            0, [expr], FsmTransform::Segments::Done.new(nil)
          ),
        ],
        synthetic_fields: [],
        alias_overrides_by_index: {},
      )
      ctx = fsm_ctx(
        id: 6,
        bg_rt: "__rt_bg6",
        captured: { "owned" => :stub },
        capture_close_plans: {},
        pointer_captures: Set.new,
        is_void: true,
        ctx_type: "__BgCtx6",
        promise_zig: "CheatHeader.Promise(void)",
        capture_fields: [
          ctx_decl("owned", "i32", MIR::Lit.new("0")),
          ctx_decl("owned_moved", "bool", MIR::Lit.new("false")),
        ],
        blk_label: "__bg6",
        rt_name: "rt",
        ctx_var: "__ctx_6_ptr",
        promise_var: "__promise_6",
        alloc_var: "__alloc_6",
        capture_inits: [],
        promoted_decls: [],
        pin_mode: false,
        parallel: false,
        extra_ctx_fields: [],
        recursive_promoted_names: [],
        fresh_heap_cleanup_names: ["owned"],
      )

      result = FsmTransform::Emit.build_recursive(
        ctx, segment_list, FsmTransform::Liveness::Result.new({}), lowering)

      expect(result).to be_a(MIR::FsmLoweringResult)
      inherited = lowering.contexts.first[:inherited_alloc_names]
      expect(inherited).to include("__ctx_6.owned")
    end

    it "registers owned suspend result cleanup once" do
      descriptor = MIR::SuspendDescriptor.new(
        [], [], MIR::FsmTailYield.new(1, "next"), [],
        "payload", "[]const u8", true,
      )
      ctx = fsm_ctx(id: 7)

      FsmTransform::Emit.send(:register_owned_suspend_result_cleanups!,
        [
          fsm_spec(index: 0, tail: FsmTransform::Segments::NextSuspend.new(Object.new, nil), descriptor: descriptor),
          fsm_spec(index: 1, tail: FsmTransform::Segments::NextSuspend.new(Object.new, nil), descriptor: descriptor),
        ], ctx, 7)

      actions = FsmTransform::Emit.send(:fsm_destroy_actions, ctx)
      expect(actions.length).to eq(1)
      action = actions.first
      expect(action).to be_a(MIR::FsmDestroyCleanup)
      expect(action.source_kind).to eq(:owned_result)
      expect(action.name).to eq("payload")
      expect(render_expr(action.guard)).to eq("__ctx_7.__owned_payload_init")
      expect(render_expr(action.target)).to eq("__ctx_7.payload")
    end

    it "collects guard fields for cleanup-bearing suspend results" do
      promise = AST::Identifier.new(nil, "p")
      promise.full_type = Type.new(:"~String")
      segment = FsmTransform::Segments::Segment.new(
        0,
        [],
        FsmTransform::Segments::NextSuspend.new(promise, "payload", 1),
      )

      guards = FsmTransform::Emit.send(:fsm_owned_result_guards, [segment], fsm_lowering_double)

      expect(guards).to eq("payload" => "__owned_payload_init")
    end

    it "lowers non-void Done segments with result capture enabled" do
      lowering = fsm_lowering_double do
        attr_reader :calls

        def initialize
          @calls = []
        end

        def capture_inits_fsm(_capture_inits)
          ""
        end

        def with_fiber_capture_map(_capture_map, rt_override:)
          yield
        end

        def with_fsm_segment_lowering_context(pointer_captures:, inherited_alloc_names:, inherited_guard_names:, owned_result_guards:)
          @calls << {
            pointer_captures: pointer_captures,
            inherited_alloc_names: inherited_alloc_names,
            inherited_guard_names: inherited_guard_names,
            owned_result_guards: owned_result_guards,
          }
          yield
        end

        def lower_finalized_fsm_step_mir(stmts, no_result:, ctx_id: nil)
          @calls << { stmts: stmts, no_result: no_result, ctx_id: ctx_id }
          [MIR::ExprStmt.new(MIR::Lit.new("loweredResult()"), false)]
        end

        def last_fsm_result_transfer_facts
          []
        end
      end
      result_expr = AST::Literal.new(nil, :NUMBER, 1, nil)
      result_expr.full_type = :Int64
      segment_list = FsmTransform::RecursiveSplitter::SegmentList.new(
        segments: [
          FsmTransform::Segments::Segment.new(
            0, [result_expr], FsmTransform::Segments::Done.new(nil)
          ),
        ],
        synthetic_fields: [],
        alias_overrides_by_index: {},
      )
      ctx = fsm_ctx(
        id: 5,
        bg_rt: "__rt_bg5",
        captured: {},
        capture_close_plans: {},
        pointer_captures: Set.new,
        is_void: false,
        ctx_type: "__BgCtx5",
        promise_zig: "CheatHeader.Promise(i64)",
        capture_fields: [],
        blk_label: "__bg5",
        rt_name: "rt",
        ctx_var: "__ctx_5_ptr",
        promise_var: "__promise_5",
        alloc_var: "__alloc_5",
        capture_inits: [],
        promoted_decls: [],
        pin_mode: false,
        parallel: false,
        extra_ctx_fields: [],
        recursive_promoted_names: [],
        fresh_heap_cleanup_names: [],
      )

      result = FsmTransform::Emit.build_recursive(
        ctx, segment_list, FsmTransform::Liveness::Result.new({}), lowering)

      expect(result).to be_a(MIR::FsmLoweringResult)
      lower_call = lowering.calls.find { |call| call.key?(:stmts) }
      expect(lower_call).to include(no_result: false, ctx_id: 5)
    end
  end
end
