require "rspec"
require "set"
require_relative "../src/ast/ast"
require_relative "../src/ast/lexer"
require_relative "../src/ast/type"
require_relative "../src/ast/symbol_entry"
require_relative "../src/ast/std_lib"
require_relative "../src/mir/control_flow"
require_relative "../src/mir/mir"
require_relative "../src/mir/pre_mir_type_check"
require_relative "../src/backends/importer"
require_relative "../src/semantic/concurrency_checks"
require_relative "../src/mir/mir_lowering"
require_relative "../src/semantic/escape_analysis"
require_relative "../src/mir/fiber_ctx_builder"

RSpec.describe "MIR gap-burn characterization" do
  let(:tok) { Lexer::Token.new(:VAR_ID, "x", 1, 1) }

  def call_site_fact(call, id: 1)
    Semantic::CallSiteFact.new(
      id: Semantic::CallSiteId.new(value: id),
      node: call,
      callee_name: call.name,
      args: call.args,
      fn_var_call: call.fn_var_call == true,
      propagates_failure: true,
    )
  end

  def registry_call(reason, sig, allocs: nil, target_var: nil, ownership_contract: MIR::OwnershipContract.empty)
    MIR::RegistryCall.new(
      entry: sig,
      args: [],
      reason: reason,
      ownership_contract: ownership_contract,
      allocs: allocs,
      target_var: target_var,
    )
  end

  it "keeps production MIR lowering free of raw Zig template constructors" do
    production_files = Dir.glob(File.expand_path("../src/**/*.rb", __dir__)).reject { |path|
      path.include?("/mir_emitter.rb") || path.include?("/fsm_wrapper_emitter.rb")
    }
    offenders = production_files.flat_map do |path|
      text = File.read(path)
      [
        ["InlineZig.new", text.include?("InlineZig.new")],
        ["MIR::InlineZig", text.include?("MIR::InlineZig")],
        ["MIR::RawBc", text.include?("MIR::RawBc")],
        ["ZigTemplate", text.include?("ZigTemplate")],
        ["SyntheticZig", text.include?("SyntheticZig")],
        ["lower_to_zig", text.include?("lower_to_zig")],
        ["fsm_body_opaque", text.include?("fsm_body_opaque")],
        ["resume_fn_zig", text.include?("resume_fn_zig")],
        ["register_zig", text.include?("register_zig")],
        ["cond_zig", text.include?("cond_zig")],
        ["target_zig", text.include?("target_zig")],
        ["guard_zig", text.include?("guard_zig")],
        ["allocator_zig", text.include?("allocator_zig")],
        ["lock_ref_zig", text.include?("lock_ref_zig")],
        ["rt_suppress_zig", text.include?("rt_suppress_zig")],
        ["with_capability_source_zig", text.include?("with_capability_source_zig")],
        ["with_match_probe_for_family", text.include?("with_match_probe_for_family")],
        ["with_match_arm_prelude", text.include?("with_match_arm_prelude")],
        ["with_match_unwrap_value", text.include?("with_match_unwrap_value")],
        ["emit_expr lower rendering", text.match?(/emit_expr\(\s*lower\(/)],
        ["raw string emitter passthrough", text.match?(/when String\s+then\s+node/)],
        ["raw DeferStmt body", text.match?(/MIR::DeferStmt\.new\(\s*["']/)],
        ["raw ErrDeferStmt body", text.match?(/MIR::ErrDeferStmt\.new\(\s*["']/)],
        ["raw BgBlock code", text.match?(/MIR::BgBlock\.new\(\s*["']/)],
        ["raw DoBlock code", text.match?(/MIR::DoBlock\.new\(\s*["']/)],
        ["rendered FsmLoweringResult code", text.include?("FsmLoweringResult.new(code:")],
        ["compound Zig MIR literal", text.match?(/MIR::Lit\.new\(\s*["'](?:@|\.?\{|\.empty|undefined|error\.|std\.|CheatLib\.|CheatHeader\.|Runtime\.)/)],
        ["compound Zig MIR identifier", text.match?(/MIR::Ident\.new\(\s*["'](?:@|\.|error\.|std\.|CheatLib\.|CheatHeader\.|Runtime\.)/)],
      ].filter_map { |label, present| "#{path}: #{label}" if present }
    end

    expect(offenders).to eq([])
  end

  it "does not clean up borrowed capture values" do
    borrowed = Type.new(:String)
    borrowed.mark_borrowed_reference!

    expect(FiberCtxBuilder.needs_capture_value_cleanup?(borrowed)).to be(false)
  end

  it "builds promoted and fresh-copy fiber capture specs" do
    promoted_analysis = CapabilityHelper::CaptureAnalysis.new(
      captures: { "name" => Type.new(:String) },
      strategies: {},
      pointer_captures: Set.new,
      capture_symbols: {},
    )
    promoted = FiberCtxBuilder.build(
      promoted_analysis,
      body_access_prefix: "ctx",
      promoted_names: { "name" => "__promoted_name" },
    )

    expect(promoted.specs.first.field_type_zig).to eq("[]const u8")
    expect(promoted.specs.first.init_value_mir).to eq(MIR::Ident.new("__promoted_name"))
    expect(promoted.specs.first.cleanup_plan.none?).to eq(true)

    fresh_analysis = CapabilityHelper::CaptureAnalysis.new(
      captures: { "owned" => Type.new(:String) },
      strategies: {
        "owned" => CaptureStrategy::FreshHeapCopy.new(
          zig_type: "[]const u8",
          ctx_init_name: "owned",
          alloc_sym: :heap
        )
      },
      pointer_captures: Set.new,
      capture_symbols: {},
    )
    fresh = FiberCtxBuilder.build(
      fresh_analysis,
      body_access_prefix: "ctx",
      fresh_heap_alloc: "rt.heapAlloc()",
      fresh_heap_id: 7,
    )

    expect(fresh.has_fresh_heap_copy?).to eq(true)
    expect(fresh.specs.first.setup_mir.map(&:class)).to include(MIR::Let, MIR::ErrDeferStmt)
    expect(fresh.specs.first.cleanup_plan.captured_value?).to eq(true)
    expect(fresh.specs.first.cleanup_mir_for("ctx")).to be_a(MIR::DeferStmt)

    atomic_type = Type.new(:Int64)
    atomic_sym = SymbolEntry.new(reg: "cell", type: atomic_type, mutable: true, storage: :heap, sync: :atomic)
    expect(FiberCtxBuilder.needs_capture_value_cleanup?(atomic_type, nil, atomic_sym)).to eq(true)

    atomic_analysis = CapabilityHelper::CaptureAnalysis.new(
      captures: { "cell" => atomic_type },
      strategies: {
        "cell" => CaptureStrategy::FreshHeapCopy.new(
          zig_type: "i64",
          ctx_init_name: "cell",
          alloc_sym: :heap
        )
      },
      pointer_captures: Set.new,
      capture_symbols: { "cell" => atomic_sym },
    )
    atomic = FiberCtxBuilder.build(
      atomic_analysis,
      body_access_prefix: "ctx",
      fresh_heap_alloc: "__alloc",
      fresh_heap_id: 9,
    )

    expect(atomic.specs.first.setup_mir.map(&:class)).to include(MIR::Let, MIR::ErrDeferStmt)
    expect(atomic.specs.first.cleanup_plan.captured_value?).to eq(true)
  end

  it "builds rc, move, pointer-local, and default fiber capture specs structurally" do
    expect(FiberCtxBuilder::CaptureRcKind::Rc.retain_func).to eq("rcRetain")
    expect(FiberCtxBuilder::CaptureRcKind::Arc.release_func).to eq("arcRelease")

    shared_type = Type.new(:Widget)
    shared_type.apply_reference_ownership!(:shared)
    shared_sym = SymbolEntry.new(reg: "shared", type: shared_type, mutable: false, storage: :shared)
    rc_analysis = CapabilityHelper::CaptureAnalysis.new(
      captures: { "shared" => shared_type },
      strategies: {
        "shared" => CaptureStrategy::RcClone.new(zig_type: "Widget", ctx_init_name: "shared"),
      },
      pointer_captures: Set.new,
      capture_symbols: { "shared" => shared_sym },
    )
    rc = FiberCtxBuilder.build(rc_analysis, body_access_prefix: "ctx", fresh_heap_id: 3)
    expect(rc.specs.first.setup_mir.first.init.callee).to eq("CheatLib.arcRetain")
    rc_cleanup = T.must(rc.specs.first.cleanup_mir_for("ctx")).body
    expect(rc_cleanup.func).to eq("arcRelease")
    expect(MIREmitter.new.emit(rc_cleanup.alloc)).to eq("ctx.alloc")
    rc_finalizer = T.must(rc.specs.first.finalizer_mir_for("ctx"))
    expect(MIREmitter.new.emit(rc_finalizer.alloc)).to eq("ctx.alloc")

    moved_analysis = CapabilityHelper::CaptureAnalysis.new(
      captures: { "owned" => Type.new(:String), "count" => Type.new(:Int64) },
      strategies: {
        "owned" => CaptureStrategy::MoveInto.new(zig_type: "[]const u8", ctx_init_name: "owned", source_name: "owned"),
        "count" => CaptureStrategy::MoveInto.new(zig_type: "i64", ctx_init_name: "count", source_name: "count"),
      },
      pointer_captures: Set.new,
      capture_symbols: {},
    )
    moved = FiberCtxBuilder.build(moved_analysis, body_access_prefix: "ctx")
    owned_spec = moved.specs.find { |spec| spec.name == "owned" }
    count_spec = moved.specs.find { |spec| spec.name == "count" }
    expect(owned_spec.cleanup_plan.kind).to eq(FiberCtxBuilder::CaptureCleanupKind::UniformValue)
    expect(owned_spec.cleanup_mir_for("ctx")).to be_a(MIR::DeferStmt)
    expect(count_spec.cleanup_plan.none?).to eq(true)
    expect(count_spec.cleanup_mir_for("ctx")).to be_nil

    local_pointer_analysis = CapabilityHelper::CaptureAnalysis.new(
      captures: { "pool" => Type.new(:Pool) },
      strategies: {},
      pointer_captures: Set["pool"],
      capture_symbols: { "pool" => SymbolEntry.new(reg: "pool", type: Type.new(:Pool), mutable: true, storage: :heap) },
    )
    pointer = FiberCtxBuilder.build(local_pointer_analysis, body_access_prefix: "ctx")
    expect(pointer.specs.first.field_type_zig).to eq("@TypeOf(&pool)")
    expect(pointer.specs.first.init_value_mir).to eq(MIR::AddressOf.new(MIR::Ident.new("pool")))

    default_analysis = CapabilityHelper::CaptureAnalysis.new(
      captures: { "plain" => Type.new(:Int64) },
      strategies: {},
      pointer_captures: Set.new,
      capture_symbols: {},
    )
    plain = FiberCtxBuilder.build(default_analysis, body_access_prefix: "ctx")
    expect(plain.specs.first.field_type_zig).to eq("@TypeOf(plain)")
  end

  it "builds capture ownership mirrors and typed FSM transform hashes" do
    helper = Class.new { include MIRLoweringConcurrency }.new
    cap_spec = FiberCtxBuilder::CaptureSpec.new(
      name: "owned",
      field_type_zig: "@TypeOf(owned)",
      init_value_mir: MIR::Ident.new("owned"),
      setup_mir: [],
      cleanup_plan: FiberCtxBuilder::CaptureCleanupPlan.new(
        kind: FiberCtxBuilder::CaptureCleanupKind::UniformValue,
        mirror_type: Type.new(:String),
      ),
    )
    caps = FiberCtxBuilder::Result.new(specs: [cap_spec], capture_map: {}, capture_symbols: {})
    analysis = CapabilityHelper::CaptureAnalysis.new(captures: { "owned" => Type.new(:String) })

    mirrors = helper.capture_ownership_mirror_nodes(caps, analysis, "ctx")
    expect(mirrors).to include(an_instance_of(MIR::AllocMark), an_instance_of(MIR::Cleanup))
    expect(helper.capture_ownership_mirror_nodes(
      caps,
      analysis,
      "ctx",
      { "owned" => Schemas::ResourceClosePlan.method("close") },
    )).to eq([])
    expect(helper.capture_moved_guard_fields([cap_spec]).first.default_value.value).to eq("false")

    node = AST::BgBlock.new(tok, [], nil, nil, false, false, true, false)
    names = MIRLoweringConcurrency::BgLoweringNames.new(
      id: 9,
      ctx_type: "__BgCtx9",
      alloc_var: "__alloc",
      promise_var: "__promise",
      ctx_var: "__ctx",
      blk_label: "__bg9",
      bg_rt: "__rt_bg9",
    )
    types = MIRLoweringConcurrency::BgTypePlan.new(
      async_shape: AsyncResultShape.promise(Type.new(:Void)),
      inner_type: Type.new(:Void),
      inner_zig: "void",
      promise_zig: "CheatHeader.Promise(void)",
      is_void: true,
    )
    capture = MIRLoweringConcurrency::BgCaptureMaterialization.new(
      caps: caps,
      capture_fields: [MIR::ContextFieldDecl.new(name: "owned", type_zig: "[]const u8")],
      capture_inits: [MIR::StructInitField.new(name: :owned, value: MIR::Ident.new("owned"))],
      fresh_heap_cleanup_names: ["owned"],
      capture_frees: [],
      promoted_decls: [],
    )
    body = MIRLoweringConcurrency::BgBodyMaterialization.new(run_body: [])
    task_config = MIR::TaskConfigPlan.new(stack_variant: "Standard")
    scheduler = MIRLoweringConcurrency::BgSchedulerPlan.new(
      pin_mode: false,
      site_id: 11,
      site_line: 12,
      site_col: 13,
      dispatch: :local,
      profiled_task_cfg: task_config,
      spawn_call: MIR::FiberSpawnCall.new(target: :local, ctx_type: "__BgCtx9", ctx_var: "__ctx", task_config: task_config),
      profile_site: MIR::ProfileTaskSite.new(site_id: 11, line: 12, column: 13, dispatch: :local, form: :bg),
      arena_init: nil,
    )
    ctx = MIRLoweringConcurrency::BgFsmTransformContext.new(
      node: node,
      names: names,
      types: types,
      capture: capture,
      body: body,
      scheduler: scheduler,
      captured: { "owned" => Type.new(:String) },
      capture_close_plans: {},
      pointer_captures: Set.new,
      rt_name: "rt",
    )

    hash = ctx.to_transform_hash
    expect(hash[:capture_fields]).to eq(capture.capture_fields)
    expect(hash[:fresh_heap_cleanup_names]).to eq(["owned"])
    expect(hash[:arena_init_flag]).to eq(true)
  end

  it "captures pointer parameters by value in fiber contexts" do
    sym = SymbolEntry.new(reg: "pool", type: Type.new(:Pool), mutable: false, storage: :heap)
    sym.is_param = true
    analysis = CapabilityHelper::CaptureAnalysis.new(
      captures: { "pool" => Type.new(:Pool) },
      strategies: {},
      pointer_captures: Set["pool"],
      capture_symbols: { "pool" => sym },
    )

    result = FiberCtxBuilder.build(analysis, body_access_prefix: "ctx")

    expect(result.specs.first.field_type_zig).to eq("@TypeOf(pool)")
    expect(result.specs.first.init_value_mir).to eq(MIR::Ident.new("pool"))
  end

  it "initializes FunctionState collections explicitly" do
    state = MIRLoweringFunctions::FunctionState.new

    expect(state.binding_types).to eq({})
    expect(state.current_binding_types).to eq({})
    expect(state.lowered_guarded_cleanup_names).to eq(Set.new)
    expect(state.lowered_guarded_cleanup_names).to eq(Set.new)
  end

  it "keeps MIR lowering schema lookup keyed by typed names" do
    schemas = MIRLoweringSchemas.new(
      struct_schemas: {},
      enum_schemas: {},
      union_schemas: {},
    )
    variants = [:Ok, "Err"]

    schemas.register_enum("Result", variants)

    expect(schemas.lookup("Result")).to eq(variants)
    expect(schemas.lookup(:Result)).to eq(variants)
  end

  it "requires MIR lowering construction to flow through typed input" do
    sig = FunctionSignature.new(params: [], return_type: Type.new(:Int64))
    input = MIRLoweringInput.new(fn_sigs: { "answer" => sig }, target: :bc, debug_mode: true)
    low = MIRLowering.new(input: input)

    expect(low.lowering_input).to eq(input)
    expect(low.send(:fn_sig_for, "answer")).to eq(sig)
    expect(low.send(:bc_target?)).to eq(true)
    expect(low.send(:program_state).debug_mode).to eq(true)
  end

  it "keeps default MIR lowering input buckets independent" do
    left = MIRLoweringInput.new
    right = MIRLoweringInput.new

    left.fn_sigs["left"] = FunctionSignature.new(params: [], return_type: Type.new(:Int64))
    left.struct_schemas[:OnlyLeft] = Schemas::StructSchema.new(fields: {})

    expect(right.fn_sigs).to eq({})
    expect(right.struct_schemas).to eq({})
  end

  it "assigns stable typed lowered ids for ownership finalization" do
    low = lowering
    node = MIR::Let.new("kept", MIR::Lit.new("1"), false, Type.new(:Int64), nil)

    first_id = low.send(:ensure_lowered_node_id, node)
    low.send(:mark_ownership_finalized_node!, node)

    expect(first_id).to be_a(MIR::LoweredNodeId)
    expect(first_id).to eq(MIR::LoweredNodeId.new(value: first_id.value))
    expect(first_id.eql?(MIR::LoweredNodeId.new(value: first_id.value))).to eq(true)
    expect(low.send(:ensure_lowered_node_id, node)).to eq(first_id)
    expect(node.lowered_node_id).to eq(first_id)
    expect(low.send(:ownership_finalized_node?, node)).to eq(true)
  end

  it "keeps typed MIR struct-init fields readable through legacy keys" do
    field = MIR::StructInitField.new(name: "item", value: MIR::Ident.new("value"), alloc: :heap)

    expect(field[:name]).to eq("item")
    expect(field[:value]).to eq(MIR::Ident.new("value"))
    expect(field[:alloc]).to eq(:heap)
  end

  it "classifies callable ownership effects from typed facts" do
    none = MIR::OwnershipEffect.from_callable_facts(
      emits_allocating: false,
      heap_return_alloc: false,
      fixed_void_without_alloc_metadata: false,
      mutates_receiver_without_heap_return: false,
      result_owns: nil,
      result_type: nil,
      alloc: nil,
      target_var: nil
    )
    expect(none.produces_owned).to eq(false)

    rejected = MIR::OwnershipEffect.from_callable_facts(
      emits_allocating: true,
      heap_return_alloc: true,
      fixed_void_without_alloc_metadata: false,
      mutates_receiver_without_heap_return: false,
      result_owns: false,
      result_type: Type.new(:String),
      alloc: :heap,
      target_var: "out"
    )
    expect(rejected.produces_owned).to eq(false)

    owned = MIR::OwnershipEffect.from_callable_facts(
      emits_allocating: true,
      heap_return_alloc: true,
      fixed_void_without_alloc_metadata: false,
      mutates_receiver_without_heap_return: false,
      result_owns: true,
      result_type: Type.new(:String),
      alloc: :heap,
      target_var: "out"
    )
    expect(owned).to have_attributes(produces_owned: true, alloc: :heap, target_var: "out")
  end

  it "derives aggregate and block ownership effects through the typed fact API" do
    heap_child = MIR::DupeSlice.new(MIR::Lit.new("\"owned\""), :heap)
    inert_child = MIR::Lit.new("0")

    aggregate = MIR::OwnershipEffect.from_children([heap_child, inert_child])

    expect(MIR::OwnershipEffect.of(nil)).to eq(MIR::OwnershipEffect.none)
    expect(MIR::OwnershipEffect.hoistable_owned_result?(heap_child)).to eq(true)
    expect(aggregate).to have_attributes(produces_owned: true, alloc: :heap, cleanup_kind: :uniform)

    block_effect = MIR::OwnershipEffect.from_block_body([
      MIR::Let.new("tmp", heap_child, false, Type.new(:String), nil),
      MIR::AllocMark.new("tmp", :heap, Type.new(:String), :heap),
      MIR::TransferMark.new("tmp", :block_result, :heap),
      MIR::BreakStmt.new("__blk", MIR::Ident.new("tmp")),
    ], result_type: Type.new(:String))

    expect(block_effect).to have_attributes(
      produces_owned: true,
      alloc: :heap,
      cleanup_kind: :heap_string,
      target_var: "tmp",
    )
  end

  it "treats sharded map allocator metadata as store consumption, not an owned result" do
    low = lowering
    sig = FunctionSignature.new(
      params: [],
      return_type: Type.new(:Void),
      intrinsic: true,
      emit: IntrinsicEmit.new(zig: "put({0})", allocates: true, mutates_receiver: true)
    )
    put = MIR::ShardedMapPut.new(
      MIR::Ident.new("map"),
      MIR::Lit.new("\"k\""),
      MIR::Ident.new("owned_value"),
      nil,
      nil,
      :string_map,
      sig,
      nil,
      Type.new(:String),
      { alloc: :heap },
      :zig,
      "map",
    )
    put.ownership_consumption = MIR::OwnershipConsumptionFact.new(
      operands: [MIR::OwnershipOperandFact.owned_binding("owned_value", Type.new(:String), "spec", :heap)],
      target: :owned_sink,
      target_alloc: :heap,
      source: "spec",
      covers_consuming_params: true,
    )
    facts = T.let([], T::Array[MIRLowering::OwnershipFact])

    expect(put.has_alloc_metadata?).to eq(true)
    expect(put.mutating_receiver_allocator_op?).to eq(true)
    expect(low.send(:ownership_fact_targets_for_node, put)).to eq([])
    expect { low.send(:append_ownership_facts_for_mir_node!, facts, put) }.not_to raise_error
    expect(facts).to include(an_instance_of(MIR::OwnedStore), an_instance_of(MIR::OwnedTransfer))
    expect(facts.none? { |fact| fact.is_a?(MIR::OwnedCreate) }).to eq(true)
  end

  it "uses typed extern trampoline return types for owned result facts" do
    low = lowering
    sig = FunctionSignature.new(
      params: [],
      return_type: Type.new(:String),
      intrinsic: true,
      emit: IntrinsicEmit.new(zig: "makeString()", allocates: true, return_alloc: :heap)
    )
    trampoline = MIR::ExternTrampoline.new(
      id: 1,
      callee_name: "makeString",
      alloc_kind: :heap,
      return_type: Type.new(:String),
      stdlib_def: sig,
    )
    facts = T.let([], T::Array[MIRLowering::OwnershipFact])

    expect(low.send(:mir_alloc_mark_type_info, trampoline, nil, context: "spec")).to eq(Type.new(:String))
    expect { low.send(:append_ownership_facts_for_mir_node!, facts, MIR::Let.new("s", trampoline, false, nil, nil)) }.not_to raise_error
    expect(facts).to include(an_instance_of(MIR::OwnedCreate))
    expect(facts.grep(MIR::OwnedCreate).first.type_info).to eq(Type.new(:String))
  end

  it "derives ownership effects for fallback expressions without node-local rediscovery" do
    heap_left = MIR::DupeSlice.new(MIR::Lit.new("\"left\""), :heap)
    heap_right = MIR::DupeSlice.new(MIR::Lit.new("\"right\""), :heap)
    frame_right = MIR::DupeSlice.new(MIR::Lit.new("\"frame\""), :frame)

    expect(MIR::OwnershipEffect.from_required_branch_pair(
      MIR::OwnershipEffect.of(heap_left),
      MIR::OwnershipEffect.of(heap_right),
    ).alloc).to eq(:heap)
    expect(MIR::OwnershipEffect.from_required_branch_pair(
      MIR::OwnershipEffect.of(heap_left),
      MIR::OwnershipEffect.of(frame_right),
    ).produces_owned).to eq(false)
    expect(MIR::OwnershipEffect.from_try_fallback(
      MIR::OwnershipEffect.of(heap_left),
      MIR::OwnershipEffect.none,
      result_type: Type.new(:String),
      fallback_is_literal: true,
      left_never_success: false,
    ).alloc).to eq(:heap)
  end

  it "uses value-comparable typed body ids for finalized lowered bodies" do
    low = lowering
    body = [MIR::Noop.new("kept")]

    body_id = low.send(:lowered_body_id, body)
    equivalent = MIR::LoweredBodyId.new(node_ids: body_id.node_ids.map { |node_id| MIR::LoweredNodeId.new(value: node_id.value) })

    expect(equivalent).to eq(body_id)
    expect(Set[body_id]).to include(equivalent)

    low.send(:mark_ownership_finalized_body!, body)
    expect(low.send(:ownership_finalized_body?, body)).to eq(true)
  end

  it "uses typed generated ids for lowered temporaries and block-like entities" do
    counters = MIRLoweringCounters.new

    tmp_id = counters.next_tmp_id
    block_id = counters.next_block_expr_id
    tmp_equivalent = MIRLoweringGeneratedId.new(kind: MIRLoweringCounterKind::Tmp, value: 1)

    expect(tmp_id).to eq(tmp_equivalent)
    expect(Set[tmp_id]).to include(tmp_equivalent)
    expect("__tmp_#{tmp_id}").to eq("__tmp_1")
    expect(block_id.kind).to eq(MIRLoweringCounterKind::BlockExpr)
    expect(block_id.value).to eq(1)
    expect(counters.next_stream_literal_id.value).to eq(0)
  end

  it "keeps pipeline observable ids numeric at the pipeline host boundary" do
    low = lowering

    expect(low.next_pipeline_observable_id).to eq(0)
    expect(low.next_pipeline_observable_id).to eq(1)
  end

  it "constructs MIR body packets separately from ownership finalization" do
    low = lowering
    stmt = AST::PassStmt.new(tok)

    construction = low.send(:construct_lowered_body, [stmt])
    expect(construction).to be_a(MIRLowering::LoweredBodyConstruction)
    expect(construction.packets).not_to be_empty
    expect(construction.finalization_context.out).to eq([])

    finalized = low.send(:finalize_lowered_body_construction!, construction)
    expect(finalized).not_to be_empty
    expect(low.send(:ownership_finalized_body?, finalized)).to eq(true)
    expect(finalized.filter_map { |node| node.lowered_node_id if node.is_a?(MIR::Emittable) }).not_to be_empty
  end

  it "represents transfer-only lowered statements as marks without a packet flag" do
    low = lowering
    low.function_state.current_bindings = {
      "owned" => CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: false),
    }
    move = AST::MoveNode.new(tok, id("owned", type: :String, storage: :heap))
    state = low.send(:initial_ownership_finalization_context)

    packet = low.send(:lowered_stmt_packet, state, move)

    expect(packet.mir).to eq([])
    expect(packet.stmt_transfer_marks).to include(an_instance_of(MIR::TransferMark))
    expect(packet.source_line).to be_nil

    finalized = low.send(:finalize_lowered_body_construction!,
      MIRLowering::LoweredBodyConstruction.new(packets: [packet], finalization_context: state))
    expect(finalized).not_to include(an_instance_of(MIR::Comment))
    expect(finalized).to include(an_instance_of(MIR::TransferMark))
  end

  it "treats malformed capture type objects as non-cleanup defensive fallbacks" do
    bad_type = Object.new
    bad_type.define_singleton_method(:to_s) { raise "bad capture type" }

    expect(FiberCtxBuilder.needs_move_capture_cleanup?(bad_type)).to eq(false)
    expect(FiberCtxBuilder.needs_capture_value_cleanup?(bad_type)).to eq(false)
  end

  def fn(body, params: [], return_type: :Void)
    AST::FunctionDef.new(tok, "main", params, [], return_type, nil, body, [], nil, :private, [], false)
  end

  def id(name, type: :String, storage: :frame)
    node = AST::Identifier.new(tok, name)
    node.full_type = type
    node.symbol = SymbolEntry.new(reg: name, type: type, mutable: false, storage: storage)
    node
  end

  def lit(value = "x", type: :String)
    node = AST::Literal.new(tok, type == :String ? :STRING : :NUMBER, value, nil)
    node.full_type = type
    node
  end

  def param(name, type: :String, takes: false)
    p = AST::Param.new(name: name, type: type, default: nil, mutable: false, takes: takes, comptime: false,
      name_token: tok, required: nil, sync: nil)
    p.takes = takes
    p.symbol = SymbolEntry.new(reg: name, type: type, mutable: false, storage: :heap)
    p.symbol.is_param = true
    p.symbol.takes = takes
    p
  end

  def owner_state(*names)
    OwnershipDataflow.state_from_names(
      names.to_h do |name|
        [name, OwnershipDataflow::OwnerEntry.new(state: OwnershipDataflow::OWNED, allocator: :heap, needs_cleanup: true)]
      end,
    )
  end

  def owner_entry(state, name)
    state[OwnershipDataflow::PlaceId.from_path(name)]
  end

  def cleanup_facts(bindings)
    CleanupClassifier::FrozenCleanupFacts.from_bindings(bindings)
  end

  def lowering
    MIRLowering.new
  end

  def structural_bg_plan
    MIR::FsmB1Body.new(
      "__bg_fixture",
      MIR::FsmB1CtxStruct.new(
        "__BgFixtureCtx",
        "CheatLib.Promise(void)",
        [],
        MIR::FsmStep.new(0, 0, "__rt_fixture", false, []),
      ),
      MIR::FsmSpawnSetup.new(
        "__bg_fixture_alloc",
        MIR::MethodCall.new(MIR::Ident.new("rt"), "heapAlloc", [], false),
        "__bg_fixture_promise",
        "CheatLib.Promise(void)",
        [],
        "__bg_fixture_ctx",
        "__BgFixtureCtx",
        [],
        MIR::FsmSpawnCall.new(target: :best, ctx_var: "__bg_fixture_ctx"),
        "rt",
        0,
        0,
        nil,
      ),
    )
  end

  it "covers MIR node and ownership helper edges" do
    nested = MIR::BlockExpr.new("__surface_stop", [MIR::ExprStmt.new(MIR::Ident.new("inside"), false)])
    surface = MIR.surface_nodes([
      MIR::ExprStmt.new(MIR::Ident.new("surface"), false),
      nested,
    ])
    expect(surface).to include(nested)
    expect(surface.grep(MIR::Ident).map(&:name)).to eq(["surface"])

    expect { MIR::InlineAllocMetadata.from(Object.new) }.to raise_error(TypeError, /allocator metadata/)
    expect { MIR::InlineAllocMetadata.from(alloc: "heap") }.to raise_error(TypeError, /allocator metadata/)
    allocs = MIR::InlineAllocMetadata.new(alloc: :frame, key_alloc: :heap)
    expect(allocs.any_frame?).to be(true)
    expect(allocs.to_h).to eq({ alloc: :frame, key_alloc: :heap })
    placement = MIR::Placement::BindingFact.new(
      name: "slot",
      type_info: Type.new(:String),
      storage: :frame,
      alloc: :frame,
      scope: :iteration,
      heap_return: false,
      escape_reason: nil,
    )
    expect(placement.frame?).to eq(true)
    expect(MIR::Placement.explicit_heap?(:heap)).to eq(true)
    expect(MIR::Placement.explicit_heap?(nil)).to eq(false)
    expect(MIR::Placement.explicit_frame?(:frame)).to eq(true)
    expect(MIR::Placement.explicit_frame?(nil)).to eq(false)

    heap_cleanup = CleanupEntry.build(:uniform, alloc: :heap)
    frame_cleanup = heap_cleanup.with_alloc(:frame)
    expect(heap_cleanup.heap?).to eq(true)
    expect(heap_cleanup.frame?).to eq(false)
    expect(frame_cleanup.heap?).to eq(false)
    expect(frame_cleanup.frame?).to eq(true)

    program = MIR::Program.new([])
    state = MIRPassState.new
    program.mir_pass_state = state
    expect(program.mir_pass_state).to eq(state)

    branch_body = [MIR::ExprStmt.new(MIR::Ident.new("branch"), false)]
    if_chain = MIR::IfChain.new(
      [MIR::IfChainBranch.new(cond: MIR::Ident.new("cond"), body: branch_body)],
      [MIR::ExprStmt.new(MIR::Ident.new("default"), false)],
    )
    expect(if_chain.child_exprs.map(&:name)).to eq(["cond"])
    if_slots = if_chain.body_slots
    expect(if_slots.map(&:name)).to eq([:branches_0, :default_body])
    replacement_branch = [MIR::ExprStmt.new(MIR::Ident.new("replacement"), false)]
    if_slots.first.replace(replacement_branch)
    expect(if_chain.branches.first.body).to eq(replacement_branch)
    if_slots.last.replace([])
    expect(if_chain.default_body).to eq([])

    contract = MIR::OwnershipContract.consume_operands([
      MIR::OwnershipOperandFact.owned_binding("owned", Type.new(:String), "coverage", :heap),
    ])
    raw = registry_call("coverage", FunctionSignature.borrowing_intrinsic, ownership_contract: contract)
    expect(raw.explicit_ownership_contract).to eq(contract)
    expect(raw.ownership_contract.owned_operand_names).to eq(["owned"])

    stream = MIR::StreamSpawn.new({}, [])
    expect(stream.boundary_fact).to be_nil
    boundary = MIR::ExecutionBoundaryFact.new(kind: :stream, dispatch: :parallel, captures: [])
    stream.boundary_fact = boundary
    expect(stream.boundary_fact).to eq(boundary)

    structure = MIR::FsmStructure.new([], [], [], [], nil, nil)
    body = MIR::FsmB1Body.new(
      "__bg",
      MIR::FsmB1CtxStruct.new("__Ctx", "CheatLib.Promise(void)", [], MIR::FsmStep.new(0, 0, "__rt", false, [])),
      MIR::FsmSpawnSetup.new(
        "__alloc",
        MIR::MethodCall.new(MIR::Ident.new("rt"), "heapAlloc", [], false),
        "__promise",
        "CheatLib.Promise(void)",
        [],
        "__ctx",
        "__Ctx",
        [],
        MIR::FsmSpawnCall.new(target: :best, ctx_var: "__ctx"),
        "rt",
        0,
        0,
        nil,
      ),
    )
    lowered = MIR::FsmLoweringResult.new(body: body, structure: structure)
    expect(lowered.body).to eq(body)

    dispatch_arm = MIR::WithMatchArm.new(
      family: :LOCKED,
      guard_var: "__guard",
      body: [MIR::ExprStmt.new(MIR::Ident.new("locked"), false)],
    )
    dispatch = MIR::WithMatchDispatch.new(MIR::Ident.new("cell"), "alias", false, "rt", [dispatch_arm])
    dispatch_slots = dispatch.body_slots
    expect(dispatch_slots.map(&:name)).to eq([:arms_0])
    replacement_dispatch = [MIR::ExprStmt.new(MIR::Ident.new("unlocked"), false)]
    dispatch_slots.first.replace(replacement_dispatch)
    expect(dispatch.arms.first.body).to eq(replacement_dispatch)

    callable_contract = MIR::CallableContract.no_ownership(1)
    method_call = MIR::MethodCall.new(
      MIR::Ident.new("receiver"),
      "next",
      [MIR::Lit.new("1")],
      true,
      callable_contract,
      :heap,
    )
    method_call.result_type = Type.new(:String)
    unwrapped_call = method_call.without_try
    expect(unwrapped_call.try_wrap).to be(false)
    expect(unwrapped_call.receiver).to eq(method_call.receiver)
    expect(unwrapped_call.callable_contract).to eq(callable_contract)
    expect(unwrapped_call.owned_result_alloc).to eq(:heap)
    expect(T.must(unwrapped_call.result_type).resolved).to eq(:String)

    owned_left = MIR::DupeSlice.new(MIR::Lit.new("\"left\""), :heap)
    owned_right = MIR::DupeSlice.new(MIR::Lit.new("\"right\""), :heap)
    expect(MIR::Cast.new(owned_left, "[]const u8", :as).without_try).to equal(owned_left)
    expect(MIR::TryCatch.new(owned_left, owned_right, "err").ownership_effect.alloc).to eq(:heap)
    expect(MIR::Orelse.new(owned_left, owned_right).ownership_effect.alloc).to eq(:heap)

    heap_return_sig = FunctionSignature.intrinsic_contract(
      return_type: Type.new(:"!?String"),
      return_alloc: :heap,
    )
    inline = registry_call("coverage", heap_return_sig, allocs: MIR.inline_alloc_metadata(alloc: :heap))
    inline_effect = inline.ownership_effect
    expect(inline_effect.produces_owned).to be(true)
    expect(inline_effect.alloc).to eq(:heap)
  end

  it "uses an opaque ctx field type for unsupported FSM foreach local promotion" do
    collection = id("source", type: :Any)
    each_stmt = AST::ForEach.new(tok, "item", collection, [], nil, false)

    fact = FsmTransform.send(:foreach_local_entry, each_stmt)
    expect(fact).to be_a(FsmTransform::PromotedLocalFact)
    expect(T.must(fact).name).to eq("item")
    expect(T.must(fact).type_zig).to eq("anyopaque")
    expect(T.must(fact).is_suspend_result).to eq(false)
  end

  it "uses typed intrinsic contracts for loop frame and receiver escape facts" do
    frame_alloc_sig = FunctionSignature.new(
      params: [],
      return_type: Type.new(:String),
      intrinsic: true,
      emit: IntrinsicEmit.new(allocates: true, alloc: :frame)
    )
    allocating_call = AST::FuncCall.new(tok, "make_frame_value", [])
    allocating_call.full_type = Type.new(:String)
    allocating_call.matched_signature = frame_alloc_sig

    expect(LoopFrameAnalysis.expression_allocates_frame_value?(allocating_call, {})).to be(true)

    receiver_type = Type.new(:"Int64[]", collection: :list)
    receiver = id("outer_items", type: receiver_type, storage: :frame)
    mutating_sig = FunctionSignature.new(
      params: [param("self", type: receiver_type)],
      return_type: Type.new(:Void),
      intrinsic: true,
      emit: IntrinsicEmit.new(allocates: true, mutates_receiver: true)
    )
    mutating_call = AST::MethodCall.new(tok, receiver, "append", [])
    mutating_call.full_type = Type.new(:Void)
    mutating_call.matched_signature = mutating_sig
    unmatched_call = AST::MethodCall.new(tok, receiver, "unknown", [])
    unmatched_call.full_type = Type.new(:Void)
    pure_sig = FunctionSignature.new(
      params: [param("self", type: receiver_type)],
      return_type: Type.new(:Void),
      intrinsic: true,
      emit: IntrinsicEmit.new
    )
    pure_call = AST::MethodCall.new(tok, receiver, "length", [])
    pure_call.full_type = Type.new(:Void)
    pure_call.matched_signature = pure_sig

    expect(LoopFrameAnalysis.outer_mutating_receiver_call?(unmatched_call, Set.new)).to be(false)
    expect(LoopFrameAnalysis.outer_mutating_receiver_call?(mutating_call, Set.new)).to be(true)
    expect(LoopFrameAnalysis.outer_mutating_receiver_call?(mutating_call, Set["outer_items"])).to be(false)
    expect(LoopFrameAnalysis.outer_frame_receiver_alloc?([unmatched_call], Set.new)).to be(false)
    expect(LoopFrameAnalysis.outer_frame_receiver_alloc?([pure_call], Set.new)).to be(false)
    expect(LoopFrameAnalysis.outer_frame_receiver_alloc?([mutating_call], Set.new)).to be(true)

    EscapeAnalysis.send(:mark_receiver_allocations_in_loop!, [unmatched_call])
    expect(T.must(receiver.symbol).heap_storage?).to be(false)
    EscapeAnalysis.send(:mark_receiver_allocations_in_loop!, [pure_call])
    expect(T.must(receiver.symbol).heap_storage?).to be(false)
    EscapeAnalysis.send(:mark_receiver_allocations_in_loop!, [mutating_call])

    expect(T.must(receiver.symbol).heap_storage?).to be(true)

    param_receiver = id("param_items", type: receiver_type, storage: :frame)
    T.must(param_receiver.symbol).is_param = true
    param_call = AST::MethodCall.new(tok, param_receiver, "append", [])
    param_call.full_type = Type.new(:Void)
    param_call.matched_signature = mutating_sig

    EscapeAnalysis.send(:mark_param_receiver_allocations_heap!, [param_call])

    expect(T.must(param_receiver.symbol).heap_storage?).to be(true)
  end

  it "fails missing intrinsic metadata before lowering registry calls" do
    call = AST::FuncCall.new(tok, "notRegistered", [])
    call.full_type = Type.new(:Void)
    call.zig_pattern = "notRegistered()"

    expect { lowering.send(:lower_intrinsic, call) }
      .to raise_error(/lower_intrinsic: missing stdlib signature for notRegistered/)
  end

  it "covers missing runtime metadata paths for MIR pass and InlineBc emission" do
    pass = MIRPass.new(fn_nodes: {}, schema_lookup: ->(_name) { nil })
    plain_call = AST::FuncCall.new(tok, "plain", [])
    plain_sig = FunctionSignature.intrinsic_contract
    plain_call.matched_signature = plain_sig
    runtime_call = AST::FuncCall.new(tok, "runtime", [])
    runtime_sig = FunctionSignature.new(params: [], return_type: Type.new(:Void), intrinsic: true, needs_rt: true)
    runtime_call.matched_signature = runtime_sig
    missing_call = AST::FuncCall.new(tok, "missing", [])

    expect(pass.send(:ast_call_needs_rt?, missing_call)).to be(false)
    expect(pass.send(:ast_call_needs_rt?, plain_call)).to be(false)
    expect(pass.send(:ast_call_needs_rt?, runtime_call)).to be(true)
    expect { MIREmitter.new.emit(MIR::InlineBc.new(:missing, [], nil)) }
      .to raise_error(/emit_inline_bc_as_zig: node has no stdlib_def/)
  end

  def ownership_finalization_context(out: [], guarded_cleanup_names: Set.new, alloc_marks: {}, body_alloc_mark_names: Set.new)
    MIRLowering::OwnershipFinalizationContext.new(
      inherited_alloc_names: Set.new,
      out: out,
      guarded_cleanup_names: guarded_cleanup_names,
      alloc_marks: alloc_marks,
      body_alloc_mark_names: body_alloc_mark_names,
      transfer_mark_names: Set.new,
      body_transfer_mark_names: Set.new,
      move_mark_names: out.filter_map { |node| node.name.to_s if node.is_a?(MIR::MoveMark) }.to_set,
      cleanup_by_name: {},
    )
  end

  it "builds CFG edges for every structured body form in one pass" do
    one = lit(1, type: :Int64)
    if_stmt = AST::IfStatement.new(tok, one, [AST::BreakNode.new(tok)], [AST::ContinueNode.new(tok)], nil, nil)
    while_stmt = AST::WhileLoop.new(tok, one, [AST::BreakNode.new(tok)], nil)
    range_stmt = AST::ForRange.new(tok, "i", one, one, false, [AST::ContinueNode.new(tok)], nil, nil)
    each_stmt = AST::ForEach.new(tok, "v", id("items"), [AST::BreakNode.new(tok)], nil, false)
    match_case = AST::MatchCase.new(kind: :literal, value: one, body: [AST::BreakNode.new(tok)])
    match_stmt = AST::MatchStatement.new(tok, id("tag", type: :Int64), [match_case], [AST::ContinueNode.new(tok)], nil, nil, false, false)
    with_stmt = AST::WithBlock.new(tok, [], [AST::BreakNode.new(tok)], nil)
    do_stmt = AST::DoBlock.new(tok, [AST::DoBranch.new(body: [AST::BreakNode.new(tok)], pinned: false, stack_size: nil)])
    bg_stmt = AST::BgBlock.new(tok, [AST::ReturnNode.new(tok, nil)], nil, nil, false, false, nil, false)
    call = AST::FuncCall.new(tok, "fails", [])

    graph = FunctionCFG.build(fn([if_stmt, while_stmt, range_stmt, each_stmt, match_stmt, with_stmt, do_stmt, bg_stmt, call, AST::Raise.new(tok, :System, nil, nil)]),
      can_fail_fns: Set["fails"])

    expect(graph.blocks.length).to be > 12
    expect(graph.entry.successors).not_to be_empty
    expect(graph.exit_block.predecessors).not_to be_empty
  end

  it "summarizes cleanup decision facts in one body traversal" do
    subject = id("payload")
    takes_match = AST::MatchStatement.new(
      tok, subject,
      [AST::MatchCase.new(kind: :literal, value: lit(1, type: :Int64), body: [])],
      nil, nil, nil, false, true
    )
    borrowed_match = AST::MatchStatement.new(
      tok, id("borrowed"),
      [AST::MatchCase.new(kind: :literal, value: lit(2, type: :Int64), body: [])],
      nil, nil, nil, false, false
    )
    non_identifier_match = AST::MatchStatement.new(
      tok, AST::StructLit.new(tok, "Box", [], nil),
      [AST::MatchCase.new(kind: :literal, value: lit(3, type: :Int64), body: [])],
      nil, nil, nil, false, true
    )
    loop_decl = AST::VarDecl.new(tok, "inside_loop", nil, lit(1, type: :Int64), false)
    outside_decl = AST::VarDecl.new(tok, "outside_loop", nil, lit(1, type: :Int64), false)
    loop = AST::WhileLoop.new(tok, lit(true, type: :Bool), [loop_decl], nil)
    fn_node = fn([takes_match, borrowed_match, non_identifier_match, outside_decl, loop])
    dataflow = OwnershipDataflow.new(FunctionCFG.build(fn_node), fn_node)

    facts = dataflow.send(:cleanup_decision_facts, fn_node.body)

    expect(facts.match_takes_vars).to eq(Set["payload"])
    expect(facts.loop_declared_names).to eq(Set["inside_loop"])
  end

  it "covers small ownership dataflow helper edges" do
    block = BasicBlock.new(42)
    terminal = AST::ReturnNode.new(tok, nil)
    block.stmts << AST::PassStmt.new(tok) << terminal
    expect(block.terminator).to eq(terminal)

    owner = OwnershipDataflow::OwnerEntry.new(
      state: OwnershipDataflow::OWNED,
      allocator: :heap,
      needs_cleanup: true,
    )
    expect(owner).to eq(OwnershipDataflow::OWNED)
    expect(owner).not_to eq(Object.new)
    expect(owner.hash).to eq(OwnershipDataflow::OWNED.hash)

    dataflow = OwnershipDataflow.new(FunctionCFG.build(fn([])), fn([]), schema_lookup: nil)
    decl = AST::VarDecl.new(tok, "owned", nil, id("source", storage: :heap), false)
    expect(dataflow.send(:linear_scope_decl_always_moves?, [decl], "owned")).to eq(false)
    expect(dataflow.send(:linear_scope_decl_always_moves?, [AST::PassStmt.new(tok)], "missing")).to eq(false)

    raw_state = owner_state("raw")
    dataflow.send(:mark_moved!, raw_state, OwnershipDataflow::PlaceId.from_path("raw"))
    expect(owner_entry(raw_state, "raw").state).to eq(OwnershipDataflow::MOVED)

    moved = id("moved", storage: :heap)
    moved.was_moved = true
    expect(dataflow.send(:collect_binding_move_places, AST::MoveNode.new(tok, moved), owner_state("moved")).map(&:path)).to eq(["moved"])

    untyped_field = AST::GetField.new(tok, id("root", storage: :heap), "payload")
    expect(dataflow.send(:owning_field_move?, untyped_field)).to eq(false)

    bg = AST::BgBlock.new(tok, [], nil, nil, false, false, nil, false)
    bg.capture_analysis = double(resource_captures: Set["captured"], captures: { "captured" => true }, move_mark_names: Set.new)
    call = AST::FuncCall.new(tok, "spawn", [bg])
    expect(dataflow.send(:stmt_moves_name?, call, "captured")).to eq(true)
  end

  it "builds typed MIR ownership preparation plans before mutating function bodies" do
    main_fn = fn([])
    fallible_fn = fn([])
    fallible_fn.name = "fallible"
    fallible_fn.can_fail = true
    pass = MIRPass.new(fn_nodes: { "main" => main_fn, "fallible" => fallible_fn }, schema_lookup: ->(_name) { nil })

    entry = CleanupEntry.build(:uniform, alloc: :heap)
    pass.cleanup_bindings["main"] = { "owned" => entry }
    plan = pass.send(:ownership_preparation_plan, main_fn)

    expect(plan.function).to eq(main_fn)
    expect(plan.bindings).to eq("owned" => entry)
    expect(plan.cleanup_facts.entry_for("owned")).to eq(entry)
    expect(plan.cleanup_bindings?).to eq(true)
    expect(plan.can_fail_fns).to eq(Set["fallible"])

    empty = pass.send(:ownership_preparation_plan, fallible_fn)
    expect(empty.cleanup_bindings?).to eq(false)
  end

  it "single-sources MIR result types for hoist cleanup planning" do
    low = lowering
    string_sig = FunctionSignature.new(params: [], return_type: Type.new(:String))
    contract = MIR::CallableContract.new(string_sig, MIR::OwnershipContract.empty, 0)
    call = MIR::Call.new("make", [], false, true, contract)
    expect(low.mir_explicit_result_type(call).resolved).to eq(:String)

    call.result_type = Type.new(:Int64)
    expect(low.mir_explicit_result_type(call).resolved).to eq(:Int64)

    inline = registry_call("test", string_sig)
    expect(low.mir_explicit_result_type(inline).resolved).to eq(:String)
  end

  it "covers MIR pass runtime, cleanup-stamping, and consumption helper edges" do
    pass = MIRPass.new(fn_nodes: {}, schema_lookup: ->(_name) { nil })

    bg = AST::BgBlock.new(tok, [], nil, nil, false, false, nil, false)
    expect(pass.send(:ast_node_lowers_through_runtime?, bg)).to eq(true)

    snapshot_with = AST::WithBlock.new(tok, [], [], nil)
    snapshot_with.snapshot_mode = :transaction
    expect(pass.send(:with_block_lowers_through_runtime?, snapshot_with)).to eq(true)

    view_with = AST::WithBlock.new(tok, [], [], nil)
    view_with.view_kind = :materialized_view
    expect(pass.send(:with_block_lowers_through_runtime?, view_with)).to eq(true)

    poly_with = AST::WithBlock.new(tok, [], [], nil)
    poly_with.universal_poly = true
    expect(pass.send(:with_block_lowers_through_runtime?, poly_with)).to eq(true)

    plain_with = AST::WithBlock.new(tok, [], [], nil)
    expect(pass.send(:with_block_lowers_through_runtime?, plain_with)).to eq(false)

    raise_with = AST::WithBlock.new(tok, [], [], nil)
    raise_with.lock_error_clause = AST::ErrorClause.new(selectors: [], action: :raise, retries: nil, token: tok)
    expect(pass.send(:with_block_lowers_through_runtime?, raise_with)).to eq(true)
    expect(pass.send(:ast_node_lowers_through_runtime?, raise_with)).to eq(true)

    bubble_clause = AST::ErrorClause.new(selectors: [], action: :pass, retries: nil, token: tok)
    bubble_clause.bubble_types = [:Timeout]
    bubble_with = AST::WithBlock.new(tok, [], [], nil)
    bubble_with.lock_error_clause = bubble_clause
    expect(pass.send(:with_block_lowers_through_runtime?, bubble_with)).to eq(true)

    moved_return = AST::MoveNode.new(tok, id("returned", type: :String))
    expect(pass.send(:unwrap_return_expr, moved_return).name).to eq("returned")
    rescued_return = AST::BinaryOp.new(tok, id("fallible", type: :String), :OR_RESCUE, lit("fallback"))
    expect(pass.send(:unwrap_return_expr, rescued_return).name).to eq("fallible")

    guarded = CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: false)
    borrow_fn = fn([id("body", type: :String)])
    pass.cleanup_bindings[borrow_fn.name] = { "body" => guarded }
    allow(BorrowChecker).to receive(:check).and_return(["borrowed move"])
    expect { pass.send(:transform_function!, borrow_fn) }.to raise_error(/\[Borrow Error\] borrowed move/)

    captured_bg = AST::BgBlock.new(tok, [AST::PassStmt.new(tok)], nil, nil, false, false, nil, false)
    captured_bg.capture_analysis = double(captures: { "outer" => true })
    pass.send(:recurse_branches!, captured_bg, MIRPass::WalkCtx.new(cleanup_facts: cleanup_facts({
      "outer" => CleanupEntry.build(:uniform, alloc: :heap),
      "inner" => CleanupEntry.build(:uniform, alloc: :heap),
    })))
    expect(captured_bg.body.first).to be_a(AST::PassStmt)

    bindings = {
      "owner" => CleanupEntry.build(:uniform, alloc: :heap),
      "moved" => CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: true),
    }
    names = Set.new
    owner_field = AST::GetField.new(tok, id("owner", type: :String, storage: :heap), "payload")
    owner_field.full_type = Type.new(:Payload, layout: :indirect)
    facts = cleanup_facts(bindings)
    pass.send(:walk_consumed, owner_field, names, facts)
    expect(names).to include("owner")
    expect(bindings["owner"].has_moved_guard?).to eq(true)

    plain_field = AST::GetField.new(tok, id("moved", type: :String, storage: :heap), "plain")
    plain_field.full_type = Type.new(:Int64)
    pass.send(:walk_consumed, AST::MoveNode.new(tok, plain_field), names, facts)
    returned_struct = AST::StructLit.new(tok, "Box", { "value" => id("moved", type: :String, storage: :heap) }, :heap, [])
    pass.send(:walk_consumed, AST::ReturnNode.new(tok, returned_struct), names, facts)
    expect(names).to include("moved")

    expect(pass.send(:owning_field_move?, AST::GetField.new(tok, id("bad", type: :String), "missing_type"))).to eq(false)

    subject = id("subject", type: :String, storage: :heap)
    subject.was_moved = true
    destructured = AST::StructPattern.new(tok, [], false)
    destructured.full_type = Type.new(:String)
    match_case = AST::MatchCase.new(kind: :literal, value: lit(1, type: :Int64),
      body: [], binding: "payload", destructure: destructured)
    match = AST::MatchStatement.new(tok, subject, [match_case], nil, nil, nil, false, true)
    match_bindings = {
      "subject" => CleanupEntry.build(:uniform, alloc: :heap),
      "payload" => CleanupEntry.build(:uniform, alloc: :heap),
    }
    pass.send(:stamp_match_as_cleanup!, match, cleanup_facts(match_bindings))
    expect(match_case.body).to include(an_instance_of(MIR::SuppressCleanup), an_instance_of(MIR::AllocMark), an_instance_of(MIR::Drop))

    while_bind = AST::WhileBindLoop.new(tok, id("maybe", type: :"?String"), "item", tok, [], nil)
    pass.send(:stamp_while_bind_cleanup!, while_bind, cleanup_facts({
      "item" => CleanupEntry.build(:uniform, alloc: :heap),
    }))
    expect(while_bind.do_branch).to include(an_instance_of(MIR::AllocMark), an_instance_of(MIR::Drop))

    if_binding = AST::Binding.new(
      expr: id("maybe", type: :"?String"),
      name: "bound",
      name_token: tok,
      unwrapped_type: Type.new(:String),
      symbol: nil,
      capture: nil,
    )
    if_bind = AST::IfBind.new(tok, [if_binding], [], nil)
    pass.send(:stamp_if_bind_cleanup!, if_bind, cleanup_facts({
      "bound" => CleanupEntry.build(:uniform, alloc: :heap),
    }))
    expect(if_bind.then_branch).to include(an_instance_of(MIR::AllocMark), an_instance_of(MIR::Drop))

    escaped_move = pass.send(:collect_escaping_ids, AST::MoveNode.new(tok, id("escaped", type: :String)))
    expect(escaped_move.map(&:name)).to eq(["escaped"])
  end

  it "covers pre-MIR type boundary survey and ICE formatting paths" do
    untyped_decls = 31.times.map { |i| AST::VarDecl.new(tok, "missing_#{i}", nil, lit(i, type: :Int64), false) }
    program = AST::Program.new(tok, untyped_decls)
    program.full_type = Type.new(:Void)
    MIRPassState::ORDER.take_while { |stage| stage != :premir_type_checked }.each { |stage| MIRPassState.for!(program).mark!(stage) }

    expect {
      PreMirTypeCheck.verify!(program)
    }.to raise_error(PreMirTypeCheck::InternalTypeResolutionError) { |error|
      expect(error.message).to include("31 AST node(s)")
      expect(error.message).to include("VarDecl @ 1:1")
      expect(error.message).to include("... (+1 more)")
    }

    survey_program = AST::Program.new(tok, [AST::VarDecl.new(tok, "survey", nil, lit(1, type: :Int64), false)])
    survey_program.full_type = Type.new(:Void)
    MIRPassState::ORDER.take_while { |stage| stage != :premir_type_checked }.each { |stage| MIRPassState.for!(survey_program).mark!(stage) }
    old_survey = ENV["PREMIR_SURVEY"]
    begin
      ENV["PREMIR_SURVEY"] = "1"
      expect {
        PreMirTypeCheck.verify!(survey_program)
      }.to output(/pre-mir-survey.*VarDecl/m).to_stderr
    ensure
      ENV["PREMIR_SURVEY"] = old_survey
    end

    violations = []
    bad_identifier = AST::Identifier.new(tok, "untyped_hash_value")
    PreMirTypeCheck.send(:walk, { nested: [bad_identifier, Type.new(:String), nil, 1, true, "leaf"] }, violations, {})
    expect(violations).to include(hash_including(cls: "Identifier", loc: "1:1"))
  end

  it "detects linear moves inside nested lexical bodies" do
    dataflow = OwnershipDataflow.new(FunctionCFG.build(fn([])), fn([]), schema_lookup: nil)
    decl = AST::VarDecl.new(tok, "owned", nil, id("source", storage: :heap), false)
    moved = AST::MoveNode.new(tok, id("owned", storage: :heap))
    nested = AST::IfStatement.new(tok, lit(true, type: :Bool), [decl, moved], nil, nil, nil)

    expect(dataflow.send(:linear_scope_decl_always_moves?, [nested], "owned")).to eq(true)
  end

  it "checks complex GIVE reads and raises cleanup decision ownership errors" do
    box_type = Type.new(:Box, layout: :indirect)
    decl_value = AST::StructLit.new(tok, "Box", {}, :heap, [])
    decl_value.full_type = box_type
    decl = AST::VarDecl.new(tok, "owned", box_type, decl_value, false)
    decl.full_type = box_type
    decl.symbol = SymbolEntry.new(reg: "owned", type: box_type, mutable: false, storage: :heap)

    move = AST::MoveNode.new(tok, id("owned", type: box_type, storage: :heap))
    later_read = AST::ReturnNode.new(tok, id("owned", type: box_type, storage: :heap))
    fn_node = fn([decl, move, later_read])
    dataflow = OwnershipDataflow.analyze(fn_node, schema_lookup: nil)
    cleanup = { "owned" => CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: false) }

    expect { dataflow.cleanup_decisions!(fn_node, cleanup_facts(cleanup)) }.to raise_error(/Ownership Error/)

    checker = UseAfterMoveChecker.new(fn([]), OwnershipDataflow.new(FunctionCFG.build(fn([])), fn([])))
    moved_state = OwnershipDataflow.state_from_names(
      "dead" => OwnershipDataflow::OwnerEntry.new(state: OwnershipDataflow::MOVED, allocator: :heap, needs_cleanup: true),
    )
    complex_stmt_move = AST::MoveNode.new(tok, AST::GetField.new(tok, id("dead", storage: :heap), "field"))
    checker.send(:check_stmt_reads, complex_stmt_move, moved_state)
    complex_expr_move = AST::MoveNode.new(tok, AST::GetField.new(tok, id("dead", storage: :heap), "field"))
    checker.send(:check_reads_in_expr, complex_expr_move, moved_state)

    expect(checker.errors.join).to include("dead")
  end

  it "tracks ownership transfers for statement categories through one dataflow object" do
    value = id("owned")
    moved_value = id("moved", storage: :heap)
    moved_value.was_moved = true
    call = AST::FuncCall.new(tok, "consume", [moved_value])
    bg = AST::BgBlock.new(tok, [], nil, nil, false, false, nil, false)
    bg.capture_analysis = double(resource_captures: Set["captured"], move_mark_names: Set["given"])
    each_stmt = AST::ForEach.new(tok, "loop_item", id("items"), [], nil, false)
    each_stmt.full_type = Type.new(:Box, layout: :indirect)

    dataflow = OwnershipDataflow.new(FunctionCFG.build(fn([])), fn([]), schema_lookup: nil)
    state = owner_state("owned", "moved", "captured", "given", "items")
    if_stmt = AST::IfStatement.new(tok, id("cond", type: :Bool), [], nil, nil, nil)
    while_stmt = AST::WhileLoop.new(tok, id("keep_going", type: :Bool), [], nil)
    match_stmt = AST::MatchStatement.new(tok, id("tag", type: :Int64), [], nil, nil, nil, false, false)
    range_stmt = AST::ForRange.new(tok, "range_item", lit(0, type: :Int64), lit(1, type: :Int64), false, [], nil, nil)

    decl = AST::VarDecl.new(tok, "declared", nil, value, false)
    decl.full_type = Type.new(:Box, layout: :indirect)
    dataflow.send(:transfer_stmt, decl, state)
    dataflow.send(:transfer_stmt, AST::Assignment.new(tok, id("slot"), AST::MoveNode.new(tok, id("owned"))), state)
    dataflow.send(:transfer_stmt, call, state)
    dataflow.send(:transfer_stmt, each_stmt, state)
    dataflow.send(:transfer_stmt, bg, state)

    expect(owner_entry(state, "declared").state).to eq(OwnershipDataflow::OWNED)
    expect(owner_entry(state, "owned").state).to eq(OwnershipDataflow::MOVED)
    expect(owner_entry(state, "moved").state).to eq(OwnershipDataflow::MOVED)
    expect(owner_entry(state, "captured").state).to eq(OwnershipDataflow::MOVED)
    expect(owner_entry(state, "loop_item").state).to eq(OwnershipDataflow::OWNED)

    expect(dataflow.send(:control_header_transfer, if_stmt).condition).to be(if_stmt.condition)
    expect(dataflow.send(:control_header_transfer, while_stmt).condition).to be(while_stmt.condition)
    expect(dataflow.send(:control_header_transfer, match_stmt).condition).to be(match_stmt.expr)
    expect(dataflow.send(:control_header_transfer, each_stmt).loop_name).to eq("loop_item")
    expect(dataflow.send(:control_header_transfer, range_stmt).loop_name).to eq("range_item")
    expect(dataflow.send(:control_header_transfer, AST::WithBlock.new(tok, [], nil, nil))).to be_nil
  end

  it "exercises escape return and call heap facts without source fuzz" do
    p = param("source", type: :String)
    ret_fn = fn([], params: [p], return_type: :String)
    escaped = id("local", type: :String, storage: :heap)
    expect(EscapeAnalysis.send(:owning_return_needs_heap_placement?, ret_fn, escaped, nil)).to eq(true)

    borrowed_fn = fn([], params: [p], return_type: :String)
    borrowed_fn.return_lifetime = [p]
    expect(EscapeAnalysis.send(:borrowed_return?, borrowed_fn, id("source", type: :String))).to eq(true)

    implicit_fn = fn([], params: [p], return_type: nil)
    implicit_facts = EscapeAnalysis.send(:function_facts, implicit_fn)
    EscapeAnalysis.send(:mark_heap_return!, implicit_facts, id("local", type: :String, storage: :heap))
    expect(implicit_fn.heap_carry_return).to eq(true)
    expect(implicit_fn.heap_carry_return_vars).to include("local")

    callee = fn([AST::ReturnNode.new(tok, id("made", type: :String))], return_type: :String)
    callee.heap_carry_return = true
    call = AST::FuncCall.new(tok, "callee", [])
    expect(EscapeAnalysis.send(:call_result_is_heap?, call, { "callee" => callee }, nil)).to eq(true)

    sig = FunctionSignature.new(params: [], return_type: Type.new(:String), heap_carry_return: true)
    foreign = AST::FuncCall.new(tok, "foreign", [])
    foreign.matched_signature = sig
    expect(EscapeAnalysis.send(:call_result_is_heap?, foreign, {}, nil)).to eq(true)
  end

  it "records typed escape placement facts for promoted return bindings" do
    local_type = Type.new(:String)
    decl = AST::VarDecl.new(tok, "local", local_type, lit("owned", type: :String), false)
    entry = SymbolEntry.new(reg: decl, type: local_type, mutable: false, storage: :frame)
    decl.symbol = entry
    decl.full_type = local_type

    returned = id("local", type: local_type, storage: :frame)
    returned.symbol = entry
    ret = AST::ReturnNode.new(tok, returned)
    analyzed_fn = fn([decl, ret], return_type: local_type)
    summaries = {
      "main" => Annotator::Phases::FunctionBodySummary.new(
        name: "main",
        callees: Set.new,
        propagating_callees: Set.new,
        has_fnptr_call: false,
        raises_directly: false,
        return_nodes: [ret],
        binding_nodes: [decl],
      )
    }

    result = EscapeAnalysis.apply_with_facts!({ "main" => analyzed_fn }, nil, summaries)

    expect(entry.storage).to eq(:heap)
    expect(result.heap_fns).to include("main")
    fact = result.placements.placements.find { |placement| placement.symbol_name == "local" }
    expect(fact).to have_attributes(
      fn_name: "main",
      binding_id: entry.binding_id,
      reason: :owning_return
    )
    expect(fact.binding).to have_attributes(name: "local", binding_id: entry.binding_id)
    expect(fact.binding.to_s).to eq("local##{entry.binding_id}")
  end

  it "uses hoist binding facts to propagate returned aggregate ownership to sources" do
    local_type = Type.new(:String)
    source_decl = AST::VarDecl.new(tok, "source", local_type, lit("owned", type: :String), false)
    source_entry = SymbolEntry.new(reg: source_decl, type: local_type, mutable: false, storage: :frame)
    source_decl.symbol = source_entry
    source_decl.full_type = local_type

    source_ref = id("source", type: local_type, storage: :frame)
    source_ref.symbol = source_entry
    aggregate = AST::StructLit.new(tok, "Box", { "field" => source_ref }, :stack, nil)
    aggregate.full_type = local_type

    hoist_decl = AST::VarDecl.new(tok, "__hoist_1", local_type, aggregate, false)
    hoist_entry = SymbolEntry.new(reg: hoist_decl, type: local_type, mutable: false, storage: :frame)
    hoist_decl.symbol = hoist_entry
    hoist_decl.full_type = local_type

    returned = id("__hoist_1", type: local_type, storage: :frame)
    returned.symbol = hoist_entry
    ret = AST::ReturnNode.new(tok, returned)
    analyzed_fn = fn([source_decl, hoist_decl, ret], return_type: local_type)
    summaries = {
      "main" => Annotator::Phases::FunctionBodySummary.new(
        name: "main",
        callees: Set.new,
        propagating_callees: Set.new,
        has_fnptr_call: false,
        raises_directly: false,
        return_nodes: [ret],
        binding_nodes: [source_decl],
      )
    }

    EscapeAnalysis.apply_with_facts!({ "main" => analyzed_fn }, nil, summaries, { "main" => [hoist_decl] })

    expect(hoist_entry.storage).to eq(:heap)
    expect(source_entry.storage).to eq(:heap)
  end

  it "uses recorded body escape nodes for binding-result heap placement" do
    local_type = Type.new(:String)
    callee = fn([], return_type: local_type)
    callee.heap_carry_return = true
    call = AST::FuncCall.new(tok, "callee", [])
    decl = AST::VarDecl.new(tok, "made", local_type, call, false)
    entry = SymbolEntry.new(reg: decl, type: local_type, mutable: false, storage: :frame)
    decl.symbol = entry
    decl.full_type = local_type
    main = fn([decl], return_type: :Void)
    summaries = {
      "main" => Annotator::Phases::FunctionBodySummary.new(
        name: "main",
        callees: Set["callee"],
        propagating_callees: Set["callee"],
        has_fnptr_call: false,
        raises_directly: false,
        call_site_facts: [call_site_fact(call)],
        binding_nodes: [decl],
        escape_nodes: [decl, call],
      ),
      "callee" => Annotator::Phases::FunctionBodySummary.new(
        name: "callee",
        callees: Set.new,
        propagating_callees: Set.new,
        has_fnptr_call: false,
        raises_directly: false,
      )
    }

    result = EscapeAnalysis.apply_with_facts!({ "main" => main, "callee" => callee }, nil, summaries)

    expect(entry.storage).to eq(:heap)
    fact = result.placements.placements.find { |placement| placement.symbol_name == "made" }
    expect(fact).to have_attributes(fn_name: "main", reason: :escape_sink)
  end

  it "retains escape placement facts on MIRPass as a phase artifact" do
    local_type = Type.new(:String)
    decl = AST::VarDecl.new(tok, "local", local_type, lit("owned", type: :String), false)
    entry = SymbolEntry.new(reg: decl, type: local_type, mutable: false, storage: :frame)
    decl.symbol = entry
    decl.full_type = local_type
    returned = id("local", type: local_type, storage: :frame)
    returned.symbol = entry
    analyzed_fn = fn([decl, AST::ReturnNode.new(tok, returned)], return_type: local_type)
    program = AST::Program.new(tok, [analyzed_fn])
    MIRPassState::ORDER.take_while { |stage| stage != :escape_analyzed }.each do |stage|
      MIRPassState.for!(program).mark!(stage)
    end
    pass = MIRPass.new(fn_nodes: { "main" => analyzed_fn }, schema_lookup: ->(_name) { nil })

    pass.transform!(program)

    facts = pass.escape_placement_facts.placements
    expect(facts.map(&:symbol_name)).to include("local")
    expect(facts.map(&:reason)).to include(:owning_return)
  end

  it "finalizes rt for heap-carrying string payload alias returns" do
    pass = MIRPass.new(fn_nodes: {}, schema_lookup: ->(_name) { nil })
    alias_fn = fn([AST::ReturnNode.new(tok, id("payload", type: Type.new(:String)))], return_type: Type.new(:String))
    alias_fn.heap_carry_return = true

    expect(pass.send(:return_path_needs_allocator?, alias_fn)).to eq(true)

    taken = param("owned", type: Type.new(:String), takes: true)
    transfer_fn = fn([AST::ReturnNode.new(tok, id("owned", type: Type.new(:String)))], params: [taken], return_type: Type.new(:String))
    transfer_fn.heap_carry_return = true

    expect(pass.send(:return_path_needs_allocator?, transfer_fn)).to eq(false)
  end

  it "treats heap-carry return signatures as owned despite return lifetime metadata" do
    sig = FunctionSignature.new(
      params: [param("v", type: Type.new(:Value))],
      return_type: Type.new(:String),
      return_lifetime: ["v"],
      heap_carry_return: true,
      heap_carry_return_vars: Set["s"]
    )

    low = MIRLowering.new(input: MIRLoweringInput.new(fn_sigs: { "getStr" => sig }))
    call = AST::FuncCall.new(tok, "getStr", [id("v", type: Type.new(:Value))])
    call.full_type = Type.new(:String)
    call.matched_signature = sig

    expect(low.send(:call_owned_return?, call)).to eq(true)
  end

  it "exercises lowering placement and sink plans directly" do
    low = lowering
    string_ast = lit("s", type: :String)
    or_ast = AST::BinaryOp.new(tok, lit("a", type: :String), :OR, lit("b", type: :String))
    or_ast.full_type = :String

    expect(low.send(:destination_placement_plan, MIR::Ident.new("s"), string_ast, :heap, Type.new(:String)).action).to eq(:string)
    expect(low.send(:destination_placement_plan, MIR::Cast.new(MIR::Ident.new("s"), "[]const u8", nil), or_ast, :heap, Type.new(:String)).action).to eq(:cast_wrapped_or)

    dupe = low.send(:materialize_owned_sink_value, MIR::Ident.new("s"), string_ast, :heap, Type.new(:String))
    expect(dupe).to be_a(MIR::DupeSlice)

    copy = AST::CopyNode.new(tok, string_ast)
    copied = low.send(:materialize_owned_sink_value, MIR::Ident.new("s"), copy, :heap, Type.new(:String))
    expect(copied).to be_a(MIR::Ident)
  end

  it "collects allocator facts from nested catch-body reassignments" do
    low = lowering
    heap_value = id("heap_value", storage: :heap)
    frame_value = id("frame_value", storage: :frame)
    ignored_value = lit("ro")

    bind_assign = AST::BindExpr.new(tok, "slot", nil, heap_value)
    bind_assign.mode = :assign
    ident_assign = AST::Assignment.new(tok, id("other"), frame_value)
    string_assign = AST::Assignment.new(tok, "not_a_target_identifier", heap_value)
    if_stmt = AST::IfStatement.new(tok, lit(1, type: :Int64), [bind_assign], [ident_assign], nil, nil)
    match_case = AST::MatchCase.new(kind: :literal, value: lit("E"), body: [string_assign])
    default_bind = AST::BindExpr.new(tok, "ignored", nil, ignored_value)
    default_bind.mode = :assign
    match_stmt = AST::MatchStatement.new(tok, id("tag"), [match_case], [default_bind], nil, nil, false, false)

    fun = fn([], return_type: :String)
    fun.catch_clauses = [AST::CatchClause.new(body: [if_stmt, match_stmt])]
    fun.default_catch = [AST::Assignment.new(tok, id("fallback"), heap_value)]

    facts = low.send(:collect_catch_reassigns, fun)

    expect(facts.map { |fact| [fact.name, fact.alloc] }).to contain_exactly(
      ["slot", :heap],
      ["other", :frame],
      ["fallback", :heap],
    )
  end

  it "keeps default catch lowering bodies typed for checker visibility" do
    low = lowering
    fun = fn([], return_type: Type.new(:Void))
    fun.default_catch = [AST::PassStmt.new(tok)]

    low.define_singleton_method(:lower_body) { |_body| [MIR::Suppress.new("default_body")] }
    plan = low.send(:build_catch_clauses, fun, false)

    expect(plan.clauses).to eq([])
    expect(plan.default_body).to eq([MIR::Suppress.new("default_body")])
    expect(plan.default_action).to eq(MIR::CatchDefaultAction::Body)
    expect(plan.snapshot_type).to be_nil
  end

  it "covers lowering coercion and implicit allocation facts as typed facts" do
    low = lowering

    untyped = lit(1, type: :Int64)
    untyped.full_type = :Untyped
    untyped.coerced_type = :Float64
    expect(low.send(:apply_lowered_coercion, MIR::Ident.new("n"), untyped)).to be_a(MIR::Ident)

    fixed_stack = AST::ListLit.new(tok, [lit(1, type: :Int64)], :stack)
    fixed_stack.full_type = :"Int64[]"
    fixed_stack.coerced_type = :"Int64[3]"
    expect(low.send(:apply_lowered_coercion, MIR::Ident.new("xs"), fixed_stack)).to be_a(MIR::Ident)

    coerced = lit(1, type: :Int64)
    coerced.coerced_type = :Float64
    cast = low.send(:apply_lowered_coercion, MIR::Ident.new("n"), coerced)
    expect(cast).to be_a(MIR::Cast)

    same = lit(1, type: :Int64)
    same.coerced_type = :Int64
    expect(low.send(:apply_lowered_coercion, MIR::Ident.new("n"), same)).to be_a(MIR::Ident)

    plain = MIR::Let.new("tmp", MIR::DupeSlice.new(MIR::Ident.new("s"), :heap), false, Type.new("[]const u8"), nil)
    fact = low.send(:implicit_allocating_result_fact, plain, ownership_finalization_context)
    expect(fact.name).to eq("tmp")
    expect(fact.ownership_effect.target_var).to eq("tmp")

    wrapped_alloc = MIR::Let.new("wrapped", MIR::Cast.new(MIR::DupeSlice.new(MIR::Ident.new("s"), :heap), "[]const u8", nil), false, Type.new("[]const u8"), nil)
    expect(low.send(:implicit_allocating_result_fact, wrapped_alloc, ownership_finalization_context).ownership_effect.target_var).to eq("wrapped")

    marked = MIR::Let.new("marked", MIR::DupeSlice.new(MIR::Ident.new("s"), :heap), false, Type.new("[]const u8"), nil)
    mark = MIR::AllocMark.new("marked", :heap, Type.new(:String), :function)
    expect(low.send(:implicit_allocating_result_fact, marked,
      ownership_finalization_context(alloc_marks: { "marked" => mark }))).to be_nil
  end

  it "covers lowering ownership source predicates without lowering syntax" do
    low = lowering
    moved = id("moved", storage: :heap)
    moved.was_moved = true
    expect(low.send(:owner_transfer_node?, moved)).to eq(true)

    indirect_field = AST::GetField.new(tok, id("root", storage: :heap), "ptr")
    indirect_t = Type.new(:String)
    indirect_t.layout = :indirect
    indirect_field.full_type = indirect_t
    expect(low.send(:owner_transfer_node?, indirect_field)).to eq(true)

    source = lit("s", type: :String)
    direct = Type.new(:String)
    direct.layout = :indirect
    expect(low.send(:destination_placement_plan, MIR::Ident.new("p"), source, :heap, direct).action).to eq(:heap_indirect)
    expect(low.send(:destination_placement_plan, MIR::HeapCreate.new("[]const u8", MIR::Ident.new("s"), :heap), source, :heap, direct).action).not_to eq(:heap_indirect)

    shared = id("rc", type: :String, storage: :heap)
    rc_type = Type.new(:Payload)
    rc_type.ownership = :shared
    shared.full_type = rc_type
    expect(low.send(:rc_retain_needed?, shared)).to eq(true)

    atomic = id("atomic", type: :String, storage: :heap)
    atomic_type = Type.new(:String)
    atomic_type.ownership = :shared
    atomic_type.sync = :atomic
    atomic_type.layout = :indirect
    atomic.full_type = atomic_type
    expect(low.send(:rc_retain_needed?, atomic)).to eq(false)

    low.capability_state.rc_unwrap_map = { "rc" => "__rc" }
    expect(low.send(:rc_retain_needed?, shared)).to eq(false)
  end

  it "covers simple MIR lowering dispatch arms and formatting facts" do
    low = lowering

    expect(low.lower(AST::DefaultLit.new(tok))).to be_a(MIR::DefaultValue)
    expect(low.lower(AST::Copy.new(tok, lit(7, type: :Int64)))).to be_a(MIR::Lit)
    expect(low.lower(MIR::Return.new(tok, ["escaped"]))).to be_a(MIR::ReturnMark)
    expect(low.lower(AST::ThrowNode.new(tok, nil))).to be_a(MIR::ReturnStmt)
    expect(low.lower(AST::DieNode.new(tok, 2))).to be_a(MIR::ExprStmt)
    expect(low.lower(AST::ShareNode.new(tok, id("shared", storage: :heap)))).to be_a(MIR::CapWrap)
    freeze = low.lower(AST::FreezeNode.new(tok, id("frozen", type: :String, storage: :heap)))
    expect(freeze).to be_a(MIR::FreezeExpr)
    expect(freeze.alloc).to eq(:heap)
    expect(low.lower(AST::Slice.new(tok, id("items", type: :"Int64[]"), lit(0, type: :Int64), lit(1, type: :Int64)))).to be_a(MIR::SliceExpr)
    expect(low.lower(AST::OrRaise.new(tok))).to be_a(MIR::FieldGet)
    expect(low.lower(AST::OrBreak.new(tok))).to be_a(MIR::BreakStmt)
    expect(low.lower(AST::OrPass.new(tok))).to be_a(MIR::DefaultValue)
    expect(low.lower(AST::OrPrune.new(tok))).to be_a(MIR::DefaultValue)
    expect(low.lower(AST::OrExit.new(tok, :Runtime, nil, nil))).to be_a(MIR::ScopeBlock)
    expect(low.lower(AST::AssertRaises.new(tok, :Runtime, nil, lit(1, type: :Int64)))).to be_a(MIR::AssertRaisesCheck)
    expect { low.lower(AST::ThenChain.new(tok, [])) }.to raise_error(/ThenChain should be flattened/)
    expect(low.send(:ast_void_type?, Type.new(:Int64))).to eq(false)
    expect(low.send(:zig_format_for_type, Type.new(:String))).to eq("{s}")
    expect(low.send(:zig_format_for_type, Type.new(:"Byte[4]"))).to eq("{s}")
    expect(low.send(:zig_format_for_type, Type.new(:Int64))).to eq("{d}")
    expect(low.send(:zig_format_for_type, Type.new(:Bool))).to eq("{}")
    expect(low.send(:zig_format_for_type, Type.new(:Any))).to eq("{any}")
    expect(low.send(:callee_can_fail?, "")).to eq(true)
    expect(low.send(:callee_can_fail?, "missing")).to eq(true)

    prog = AST::Program.new(tok, [])
    MIRPassState::ORDER.take_while { |stage| stage != :mir_lowered }.each { |stage| MIRPassState.for!(prog).mark!(stage) }
    expect(low.lower(prog)).to be_a(MIR::Program)
  end

  it "covers test lowering assert-raises and stub helper edges" do
    low = lowering

    assert_named = AST::AssertRaises.new(tok, :Runtime, :NotFound, lit(1, type: :Int64))
    assert_named.full_type = Type.new(:Void)
    expect(MIREmitter.new.emit(low.lower(assert_named))).to include("matchesName(@intFromEnum(ErrorName.NotFound))")

    refs = Set.new
    low.send(:collect_identifier_refs,
      [id("outer", type: :String), [id("inner", type: :String)], "leaf"],
      { "outer" => true, "inner" => true },
      refs)
    expect(refs).to eq(Set["outer", "inner"])

    mapped = id("mapped", type: :String)
    low.function_state.decl_zig_name_map = { mapped.symbol.reg.object_id => "mapped_L1" }
    expect(low.send(:stub_local_idents, mapped)).to eq(["mapped_L1"])
    low.function_state.decl_zig_name_map = {}
    low.function_state.fn_name_rename_map = { "renamed" => "renamed_L2" }
    expect(low.send(:stub_local_idents, id("renamed", type: :String))).to eq(["renamed_L2"])

    low.instance_variable_set(:@active_stubs, {
      "getData" => { kind: :returns, var: "__stub_getData" },
      "nextData" => { kind: :sequence, var: "__stub_nextData" },
      "makeData" => { kind: :with, var: "__stub_makeData" },
    })
    ret_stub = low.send(:stub_intercept_for, "getData", nil, [mapped])
    expect(ret_stub).to be_a(MIR::BlockExpr)
    expect(ret_stub.body).to include(an_instance_of(MIR::Suppress), an_instance_of(MIR::BreakStmt))

    seq_stub = low.send(:stub_intercept_for, "nextData", nil, [])
    expect(seq_stub).to be_a(MIR::BlockExpr)
    expect(seq_stub.body).to include(an_instance_of(MIR::Let), an_instance_of(MIR::Set), an_instance_of(MIR::BreakStmt))

    with_stub = low.send(:stub_intercept_for, "makeData", nil, [lit("arg", type: :String)])
    expect(with_stub).to be_a(MIR::Call)
    expect(with_stub.args.first.name).to eq("rt")

    list_values = AST::ListLit.new(tok, [lit("a", type: :String), lit("b", type: :String)], :stack)
    sequence_list = low.send(:lower_stub_decl, AST::StubDecl.new(tok, "seqList", :sequence, list_values))
    expect(sequence_list).to all(be_a(MIR::Let))

    sequence_scalar = low.send(:lower_stub_decl, AST::StubDecl.new(tok, "seqScalar", :sequence, lit("single", type: :String)))
    expect(sequence_scalar.first.init.items.length).to eq(1)

    with_decl = low.send(:lower_stub_decl, AST::StubDecl.new(tok, "withFn", :with, lit("body", type: :String)))
    expect(with_decl).to be_a(MIR::Let)

    expect {
      low.send(:lower_stub_decl, AST::StubDecl.new(tok, "badFn", :unknown, lit("x", type: :String)))
    }.to raise_error(/unhandled StubDecl kind/)
  end

  it "covers top-ranked MIR helper branch variants without new source fixtures" do
    low = lowering

    same = lit(1, type: :Int64)
    same.coerced_type = :Int64
    expect(low.send(:apply_lowered_coercion, MIR::Ident.new("n"), same)).to be_a(MIR::Ident)

    guarded = CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: false)
    drop = MIR::Drop.new(tok, "unguarded")
    drop.cleanup_entry = guarded
    expect(low.lower(drop)).to be_a(MIR::Cleanup)

    expect(low.send(:symbol_storage_for_node, nil)).to be_nil
    expect(low.send(:placement_for_node, id("plain", storage: :heap))).to eq(:heap)
    expect(low.send(:resolve_alloc_sym, :frame)).to eq(:frame)
    expect(low.send(:resolve_alloc_sym, :unknown)).to eq(:heap)
    expect(low.send(:extract_root_var_name, id("root"))).to eq("root")

    nil_lowering = Class.new(MIRLowering) do
      def lower(_stmt) = nil
    end.new
    expect(nil_lowering.send(:lowered_stmt_packet, ownership_finalization_context, AST::PassStmt.new(tok))).to be_nil
    expect(low.send(:lower_body_with_break, [], "__label")).to eq([])
    expect(low.send(:emit_stmts_zig, [MIR::Noop.new("skip")])).to eq("")

    borrowed = MIR::OwnershipOperandFact.borrowed_access("b", Type.new(:String), "src", :frame)
    owned = MIR::OwnershipOperandFact.owned_binding("o", Type.new(:String), "src", :frame)
    non = MIR::OwnershipOperandFact.non_owning(Type.new(:String), "src")
    retargeted = low.send(:retarget_ownership_operands, [borrowed, owned, non], :heap)
    expect(retargeted[0].borrowed).to eq(true)
    expect(retargeted[0].target_alloc).to eq(:heap)
    expect(retargeted[1].name).to eq("o")
    expect(retargeted[1].target_alloc).to eq(:heap)
    expect(retargeted[2].name).to be_nil
  end

  it "covers owned sink materialization actions as a compact dispatch matrix" do
    low = lowering
    value = MIR::Ident.new("v")
    ast = id("v", type: :String, storage: :frame)

    expect(low.send(:materialize_owned_sink_value, value, nil, :heap)).to be(value)

    plans = [
      MIRLowering::OwnedSinkPlan.new(action: :deep_copy, target_alloc: :heap, zig_type: "[]const u8", copy_mode: :full_value, source_slice_view: true),
      MIRLowering::OwnedSinkPlan.new(action: :rc_retain, target_alloc: :heap, zig_type: "Payload", copy_mode: nil, rc_func: "arcRetain"),
      MIRLowering::OwnedSinkPlan.new(action: :dupe_union, target_alloc: :heap, zig_type: "Choice", copy_mode: nil),
      MIRLowering::OwnedSinkPlan.new(action: :unknown, target_alloc: :heap, zig_type: nil, copy_mode: nil),
    ]

    plans.each do |plan|
      singleton = Class.new(MIRLowering) do
        define_method(:owned_sink_plan) { |_value, _ast_node, _sink_alloc, _sink_type = nil| plan }
        def emit_builtin(name, args)
          sig = FunctionSignature.new(params: [], return_type: Type.new(:String), intrinsic: true)
          MIR::RegistryCall.new(entry: sig, args: args.map { |arg| MIR::RegistryCallArg.new(expr: arg) }, reason: name.to_s)
        end
      end.new
      result = singleton.send(:materialize_owned_sink_value, value, ast, :heap, Type.new(:String))
      case plan.action
      when :deep_copy
        expect(result).to be_a(MIR::DeepCopy)
        expect(result.source).to be_a(MIR::ItemsAccess)
      when :rc_retain
        expect(result).to be_a(MIR::RcRetain)
      when :dupe_union
        expect(result).to be_a(MIR::RegistryCall)
      else
        expect(result).to be(value)
      end
    end
  end

  it "covers remaining high-rank MIR lowering helper variants compactly" do
    low = lowering

    destination_plan = MIRLowering::DestinationPlacementPlan.new(
      action: :keep,
      type_info: nil,
      dest_alloc: :heap,
    )
    expect(destination_plan.heap?).to eq(true)
    expect(destination_plan.place(low, MIR::Ident.new("kept"), id("kept"))).to be_a(MIR::Ident)

    cast_plan_lowering = Class.new(MIRLowering) do
      def place_value_for_destination(_mir, _ast_node, _dest_alloc, _type_info)
        MIR::Ident.new("placed")
      end
    end.new
    cast_plan = MIRLowering::DestinationPlacementPlan.new(
      action: :cast_wrapped_or,
      type_info: Type.new(:String),
      dest_alloc: :heap,
    )
    cast_result = cast_plan.place(
      cast_plan_lowering,
      MIR::Cast.new(MIR::Ident.new("raw"), "[]const u8", :as),
      id("raw"),
    )
    expect(cast_result).to be_a(MIR::Cast)
    expect(cast_result.expr.name).to eq("placed")

    try_plan = MIRLowering::DestinationPlacementPlan.new(
      action: :owned_try_catch,
      type_info: Type.new(:String),
      dest_alloc: :heap,
    )
    expect(try_plan.place(
      low,
      MIR::TryCatch.new(MIR::DupeSlice.new(MIR::Ident.new("fallible"), :heap), MIR::Ident.new("fallback"), nil),
      id("fallible"),
    )).to be_a(MIR::TryCatch)

    string_or_plan = MIRLowering::DestinationPlacementPlan.new(
      action: :string_or,
      type_info: Type.new(:String),
      dest_alloc: :heap,
    )
    string_or_ast = AST::BinaryOp.new(tok, id("left", type: :String), :OR_RESCUE, lit("right", type: :String))
    string_or_ast.full_type = Type.new(:String)
    expect(string_or_plan.place(low, MIR::Ident.new("left"), string_or_ast)).to be_a(MIR::DupeSlice)

    bad_plan = MIRLowering::DestinationPlacementPlan.new(action: :bad, type_info: nil, dest_alloc: nil)
    expect { bad_plan.place(low, MIR::Ident.new("x"), id("x")) }.to raise_error(/unknown destination placement action/)

    stdlib_alloc = FunctionSignature.new(
      params: [],
      return_type: Type.new(:String),
      intrinsic: true,
      emit: IntrinsicEmit.new(allocates: true, return_alloc: :heap, mutates_receiver: true)
    )
    mutating_alloc = registry_call("test", stdlib_alloc, allocs: MIR.inline_alloc_metadata(alloc: :heap))
    expect(low.send(:implicit_allocating_result_fact,
      MIR::Let.new("receiver", mutating_alloc, false, Type.new(:String), nil), ownership_finalization_context)).to be_nil

    nested_alloc = Struct.new(:child) do
      include MIR::Expr
      def child_exprs = [child]
      def ownership_source_exprs = [child]
      def ownership_effect = MIR::OwnershipEffect.none
    end.new(MIR::DupeSlice.new(MIR::Ident.new("s"), :heap))
    nested_fact = low.send(:implicit_allocating_result_fact,
      MIR::Let.new("nested", nested_alloc, false, Type.new(:String), nil), ownership_finalization_context)
    expect(nested_fact.ownership_effect.target_var).to eq("nested")

    discarded_call = AST::FuncCall.new(tok, "make", [])
    discarded_call.full_type = Type.new(:String)
    discarded, hoisted_discard = low.send(:materialize_statement_discard,
      discarded_call, MIR::DupeSlice.new(MIR::Ident.new("made"), :heap))
    expect(hoisted_discard).to eq(true)
    expect(discarded).to be_a(MIR::ScopeBlock)
    expect(discarded.body).to include(an_instance_of(MIR::AllocMark), an_instance_of(MIR::Let), an_instance_of(MIR::Cleanup))

    discarded_or = AST::BinaryOp.new(tok, id("fallible", type: Type.new(:"!String")), :OR_RESCUE, AST::OrPass.new(tok))
    discarded_or.full_type = Type.new(:String)
    try_call = MIR::Call.new("run", [], false, true, nil)
    try_call.result_type = Type.new(:String)
    try_catch = MIR::TryCatch.new(try_call, MIR::DefaultValue.new(kind: :string_empty), nil)
    try_catch.result_type = Type.new(:String)
    discarded_try, hoisted_try = low.send(:materialize_statement_discard, discarded_or, try_catch)
    expect(hoisted_try).to eq(true)
    try_let = T.cast(discarded_try, MIR::ScopeBlock).body.grep(MIR::Let).first
    expect(try_let.init).to be_a(MIR::TryCatch)
    try_catch_fallback = T.cast(try_let.init, MIR::TryCatch).catch_body
    expect(try_catch_fallback).to be_a(MIR::BlockExpr)
    expect(T.cast(try_catch_fallback, MIR::BlockExpr).body.grep(MIR::Let).first.init).to be_a(MIR::DupeSlice)
    expect(MIR::OwnershipEffect.of(try_let.init).produces_owned).to eq(true)

    discarded_optional = AST::BinaryOp.new(tok, id("maybe", type: Type.new(:"?String")), :OR_RESCUE, lit("fallback", type: :String))
    discarded_optional.full_type = Type.new(:String)
    optional_call = MIR::Call.new("maybe", [], false, true, nil)
    optional_call.result_type = Type.new(:String)
    orelse = MIR::Orelse.new(optional_call, MIR::DefaultValue.new(kind: :string_empty))
    orelse.result_type = Type.new(:String)
    discarded_orelse, hoisted_orelse = low.send(:materialize_statement_discard, discarded_optional, orelse)
    expect(hoisted_orelse).to eq(true)
    orelse_init = T.cast(discarded_orelse, MIR::ScopeBlock).body.grep(MIR::Let).first.init
    expect(orelse_init).to be_a(MIR::IfOptional)
    expect(MIR::OwnershipEffect.of(orelse_init).produces_owned).to eq(true)

    if_bind = MIR::IfBindStmt.new([
      { capture: nil, expr: MIR::Ident.new("a") },
      { capture: "b", expr: nil },
    ], [], nil)
    expect(low.send(:if_bind_ownership_fact_targets, if_bind)).to eq([])

    low.function_state.current_bindings = {}
    bg_missing_body = AST::BgBlock.new(tok, [id("other")], nil, nil, false, false, nil, false)
    bg_missing_body.capture_analysis = double(move_mark_names: Set["missing"])
    expect(low.send(:ownership_transfers_for_stmt, bg_missing_body, Set.new)).to eq([])

    bg_missing_entry = AST::BgBlock.new(tok, [id("given")], nil, nil, false, false, nil, false)
    bg_missing_entry.capture_analysis = double(move_mark_names: Set["given"])
    expect(low.send(:collect_bg_capture_transfer_roots, bg_missing_entry)).to eq([])
    low.function_state.current_bindings = { "given" => CleanupEntry.build(:uniform, alloc: :heap) }
    low.function_state.fn_name_rename_map = { "given" => "renamed_given" }
    expect(low.send(:ownership_transfers_for_stmt, bg_missing_entry, Set.new).first.name).to eq("renamed_given")
    missing_entry_low = Class.new(MIRLowering) do
      def collect_bg_capture_transfer_roots(_stmt) = ["missing_entry"]
    end.new
    missing_entry_low.function_state.current_bindings = {}
    expect(missing_entry_low.send(:ownership_transfers_for_stmt, bg_missing_entry, Set.new)).to eq([])

    empty_target_lowering = Class.new(MIRLowering) do
      def ownership_transfer_operands_for_node(_node, _existing = [])
        [MIRLowering::OwnershipTransferTarget.new(name: "", target: :owned_sink, target_alloc: :heap)]
      end
    end.new
    expect(empty_target_lowering.send(:ownership_transfers_for_node,
      MIR::ExprStmt.new(MIR::Ident.new("x"), false),
      ownership_finalization_context)).to eq([])

    low.function_state.current_bindings = {}
    expect(low.send(:ownership_consumed_name_operands, ["hidden"], "src", :heap)).to eq([])
    visibility_low = lowering
    visibility_low.function_state.current_bindings = {}
    visibility_low.function_state.lowered_alloc_names = Set.new
    expect(visibility_low.send(:owned_binding_visible?, "hidden")).to eq(false)

    prog = AST::Program.new(tok, [])
    MIRPassState::ORDER.take_while { |stage| stage != :mir_lowered }.each { |stage| MIRPassState.for!(prog).mark!(stage) }
    debug_program = low.send(:lower_program, prog, use_debug_allocator: true)
    expect(debug_program.items).to include(an_object_having_attributes(name: "USE_DEBUG_ALLOCATOR"))

    require_prog = AST::Program.new(tok, [AST::RequireNode.new(tok, "math", "math", :package)])
    MIRPassState::ORDER.take_while { |stage| stage != :mir_lowered }.each { |stage| MIRPassState.for!(require_prog).mark!(stage) }
    expect(low.lower(require_prog).items).to include(an_instance_of(MIR::Import))
    require_module = AST::Program.new(tok, [AST::RequireNode.new(tok, "math", "math", :package)])
    MIRPassState::ORDER.take_while { |stage| stage != :mir_lowered }.each { |stage| MIRPassState.for!(require_module).mark!(stage) }
    expect(low.send(:lower_module, require_module)[:items]).to include(an_instance_of(MIR::Import))

    imported_fn = fn([], return_type: :Void)
    imported_fn.name = "helper"
    imported_fn.visibility = :pub
    imported_fn.needs_rt = false
    imported_fn.can_fail = false
    imported_mod = ModuleImporter::CompiledModule.new(
      AST::Program.new(tok, [imported_fn]),
      nil,
      "pub fn helper() void {}",
      "/tmp",
      nil,
      nil,
      nil,
      nil,
      nil,
    )
    importer = ModuleImporter.new(base_dir: "/tmp")
    importer.define_singleton_method(:compile_file) { |_path, caller_dir:| imported_mod }
    bc_require_low = MIRLowering.new(input: MIRLoweringInput.new(importer: importer, source_dir: "/tmp", target: :bc))
    required = bc_require_low.lower(AST::RequireNode.new(tok, "helper.cht", "helper", :local))
    expect(required).to include(an_instance_of(MIR::FnDef))
    expect(required).not_to include(an_instance_of(MIR::ModuleNamespace))

    items = []
    low.send(:append_lowered_items!, MIRLowering::LoweredItemTarget.new(items: items, line: 7), nil)
    expect(items).to eq([])

    fn_sig = FunctionSignature.new(params: [], return_type: Type.new(:Void))
    expect(low.send(:mir_cast, MIR::Ident.new("fn"), Type.new(fn_sig), Type.new(:Any))).to be_a(MIR::Cast)
    expect(low.send(:mir_cast, MIR::Ident.new("err"), Type.new(:Int64), Type.new(:"!String"))).to be_a(MIR::Cast)
    expect(low.send(:mir_cast, MIR::Ident.new("i"), Type.new(:Float64), Type.new(:Int64)).expr.method).to eq(:intFromFloat)
    expect(low.send(:mir_cast, MIR::Ident.new("f"), Type.new(:Float32), Type.new(:Float64)).expr.method).to eq(:floatCast)
    expect(low.send(:ast_void_type?, nil)).to eq(true)
    expect(low.send(:implicit_allocating_result_fact, MIR::Ident.new("not_let"), ownership_finalization_context)).to be_nil
    borrowed_field = AST::GetField.new(tok, id("owner", type: :String, storage: :heap), "field")
    borrowed_field.full_type = Type.new(:String)
    expect(low.send(:return_destination_alloc, AST::ReturnNode.new(tok, borrowed_field))).to eq(:heap)

    generic_field = AST::StructField.new(type: :Int64, default: lit(1, type: :Int64))
    generic_struct = AST::StructDef.new(tok, "Box", { value: generic_field }, :pub, ["T"])
    expect(low.lower(generic_struct)).to be_a(MIR::FnDef)

    inline_variant = Schemas::InlineStructVariant.new(fields: { value: :String })
    generic_union = AST::UnionDef.new(tok, "Choice", { Item: inline_variant }, :pub)
    generic_union.type_params = ["T"]
    expect(low.lower(generic_union)).to all(satisfy { |node| node.is_a?(MIR::StructDef) || node.is_a?(MIR::FnDef) })
    default = low.send(:lower_field_default, AST::DefaultLit.new(tok))
    expect(default).to be_a(MIR::DefaultValue)
    expect(T.cast(default, MIR::DefaultValue).kind).to eq(:aggregate_empty)

    expect(low.send(:lower_direct_length, AST::FuncCall.new(tok, "len", []))).to be_nil
    missing_ast_mod = ModuleImporter::CompiledModule.new(
      nil,
      nil,
      nil,
      nil,
      nil,
      nil,
      nil,
      nil,
      nil,
      [MIR::StructDef.new("Hidden", [], nil, :pub)],
    )
    expect(low.send(:visible_type_items, missing_ast_mod)).to eq([])
    ptr_type = Type.new(:Payload)
    ptr_type.layout = :indirect
    expect(low.send(:bare_zig_type, ptr_type)).not_to start_with("*")

    rc_type = Type.new(:Payload)
    rc_type.ownership = :shared
    rc_ast = id("rc_value", type: rc_type, storage: :frame)
    expect(low.send(:owned_sink_plan, MIR::Ident.new("rc_value"), rc_ast, :heap, rc_type).action).to eq(:rc_retain)
    multi_type = Type.new(:Payload)
    multi_type.ownership = :multiowned
    multi_ast = id("multi_value", type: multi_type, storage: :frame)
    expect(low.send(:owned_sink_plan, MIR::Ident.new("multi_value"), multi_ast, :heap, multi_type).rc_func).to eq("rcRetain")

    borrowed_union_low = Class.new(MIRLowering) do
      def owned_sink_source_fact(_value, _ast_node, _sink_alloc, _ti)
        MIRLowering::OwnedSinkSourceFact.new(
          source_alloc: nil,
          moved_without_copy: false,
          owned_parameter: false,
          needs_heap_create: false,
          same_alloc_verifiable: false,
          same_alloc_transfer_source: false,
          transfer_without_local_cleanup: false,
          already_owned_value: false,
          existing_owned_source: false,
          borrowed_union_sink: true,
        )
      end
    end.new
    expect(borrowed_union_low.send(:owned_sink_plan, MIR::Ident.new("borrowed_union"), id("borrowed_union", type: :Int64), :heap, Type.new(:Int64)).action).to eq(:dupe_union)
    copyable_union_low = MIRLowering.new(input: MIRLoweringInput.new(union_schemas: {
      Tiny: Schemas::UnionSchema.new(variants: { Num: :Int64 }),
    }))
    borrowed_tiny = id("tiny", type: :Tiny, storage: :borrow)
    expect(copyable_union_low.send(:borrowed_union_sink_source?, borrowed_tiny, borrowed_tiny, Type.new(:Tiny))).to eq(false)
    heap_union_low = MIRLowering.new(input: MIRLoweringInput.new(union_schemas: {
      Big: Schemas::UnionSchema.new(variants: { Text: :String }),
    }))
    borrowed_big = id("big", type: :Big, storage: :borrow)
    expect(heap_union_low.send(:borrowed_union_sink_source?, borrowed_big, borrowed_big, Type.new(:Big))).to eq(true)
  end

  it "covers hardened MIR hoist helper fallbacks directly" do
    low = lowering

    expect(MIRHoistFacts.container_borrow_expr?(nil)).to eq(false)
    borrow_left = id("borrowed_left", storage: :heap)
    borrow_left.container_borrow = true
    expect(MIRHoistFacts.container_borrow_expr?(AST::BinaryOp.new(tok, borrow_left, :OR, lit("fallback")))).to eq(true)
    expect(low.send(:mir_allocates?, Object.new)).to eq(false)
    expect(low.send(:hoist_alloc, MIR::Ident.new("plain"), nil)).to be_a(MIR::Ident)
    passthrough = Object.new
    expect(low.send(:hoist_alloc, passthrough, nil)).to be(passthrough)

    pipeline_ast = lit("pipeline", type: :String)
    typed_pipeline = MIR::Pipeline.new(pipeline_ast, nil, nil, [], nil, nil)
    expect(low.send(:mir_alloc_mark_type_info, typed_pipeline).resolved).to eq(:String)

    inner_pipeline = MIR::Pipeline.new(nil, MIR::DupeSlice.new(MIR::Ident.new("s"), :heap), nil, [], nil, nil)
    expect(low.send(:mir_alloc_mark_type_info, inner_pipeline).resolved).to eq(:String)

    untyped_pipeline = MIR::Pipeline.new(nil, MIR::Ident.new("s"), nil, [], nil, nil)
    expect { low.send(:mir_alloc_mark_type_info, untyped_pipeline) }.to raise_error(/Pipeline has no typed result/)

    owned_stmt = MIR::ExprStmt.new(MIR::DupeSlice.new(MIR::Ident.new("s"), :heap), false)
    expect(low.send(:normalize_allocating_mir_stmt!, owned_stmt)).not_to be_empty
    expect(low.send(:normalize_stmt_child_exprs!, Object.new)).to eq([])
    expect(low.send(:normalize_stmt_child_exprs!, MIR::ExprStmt.new(MIR::Ident.new("plain"), false))).to eq([])

    old_child = MIR::Ident.new("old")
    new_child = MIR::Ident.new("new")
    array_parent = MIR::ArrayInit.new("i64", nil, [[old_child]])
    low.send(:replace_mir_expr_child!, array_parent, old_child, new_child)
    expect(array_parent.items.first.first).to be(new_child)

    hash_parent = MIR::StructInit.new("Box", { nested: { value: old_child } })
    low.send(:replace_mir_expr_child!, hash_parent, old_child, new_child)
    expect(hash_parent.fields[:nested][:value]).to be(new_child)

    expect(low.send(:replace_mir_expr_in_value!, [MIR::Ident.new("other")], old_child, new_child)).to eq(false)
    expect(low.send(:replace_mir_expr_in_value!, { nested: [MIR::Ident.new("other")] }, old_child, new_child)).to eq(false)
    expect(low.send(:replace_mir_expr_in_value!, { nested: [old_child] }, old_child, new_child)).to eq(true)

    mixed_parent = MIR::StructInit.new("Box", { misses: [MIR::Ident.new("other")], hit: old_child })
    low.send(:replace_mir_expr_child!, mixed_parent, old_child, new_child)
    expect(mixed_parent.fields[:hit]).to be(new_child)
    array_miss = MIR::ArrayInit.new("i64", nil, [MIR::Ident.new("other")])
    low.send(:replace_mir_expr_child!, array_miss, old_child, new_child)
    expect(array_miss.items.first.name).to eq("other")
    hash_miss = MIR::StructInit.new("Box", { miss: MIR::Ident.new("other") })
    low.send(:replace_mir_expr_child!, hash_miss, old_child, new_child)
    expect(hash_miss.fields[:miss].name).to eq("other")

    call = MIR::Call.new("make", [], false, true)
    call.result_type = Type.new(:String)
    expect(low.send(:cleanup_entry_for_ownership_effect, call, alloc: :heap).kind).to eq(:uniform)
    untyped_call = MIR::Call.new("make", [], false, true)
    expect { low.send(:cleanup_entry_for_ownership_effect, untyped_call, alloc: :heap) }.to raise_error(/no typed cleanup result/)

    expect(low.send(:mir_ident_names, Object.new)).to eq([])
    expect(low.send(:mir_ident_names, MIR::ArrayInit.new("i64", nil, [MIR::Ident.new("a"), MIR::Ident.new("b")]))).to eq(["a", "b"])
  end

  it "covers AST hoist escape and temp-placement edges" do
    string_concat = lambda do |left = "a", right = "b"|
      expr = AST::BinaryOp.new(tok, lit(left), :ADD, lit(right))
      expr.full_type = Type.new(:String)
      expr.string_concat = true
      expr
    end

    list = AST::ListLit.new(tok, [string_concat.call], :heap)
    list.full_type = Type.new(:"String[]", collection: :list)
    list_hoists = []
    counter = Hoist::HoistCounter.new
    expect(counter.next_name).to eq("__hoist_1")
    Hoist.send(:hoist_concats_within!, list, list_hoists, counter)
    expect(list.items.first).to be_a(AST::Identifier)
    expect(list_hoists.first.name).to eq("__hoist_2")

    heap_needed = string_concat.call("c", "d")
    heap_needed.needs_heap_create = true
    indirect_replacement = Hoist.send(:make_temp!, heap_needed, [], "__hoist_1")
    expect(indirect_replacement.needs_heap_create).to eq(true)

    owner = id("owner", type: Type.new(:Box, location: :heap), storage: :heap)
    field = AST::GetField.new(tok, owner, "name")
    field.full_type = Type.new(:String)
    borrow_hoists = []
    borrowed_replacement = Hoist.send(:make_temp!, field, borrow_hoists, "__hoist_1", moved: false)
    expect(borrowed_replacement.symbol.storage).to eq(:borrow)

    borrowed_left = id("maybe_owned", storage: :heap)
    borrowed_left.container_borrow = true
    fallback = AST::BinaryOp.new(tok, borrowed_left, :OR_RESCUE, lit("fallback"))
    fallback.full_type = Type.new(:String)
    expect(Hoist.send(:owned_fallback_temp?, fallback, nil)).to eq(true)
    fallback_hoists = []
    Hoist.send(:make_temp!, fallback, fallback_hoists, "__hoist_1")
    expect(fallback_hoists.first.symbol.storage).to eq(:heap)

    collection_type = Type.new(:"Box[]", collection: :list)
    collection = id("boxes", type: collection_type, storage: :heap)
    stored_concat = string_concat.call("e", "f")
    store_call = AST::MethodCall.new(tok, collection, "append", [stored_concat])
    store_sig = FunctionSignature.new(
      params: [param("self", type: collection_type), param("value", type: Type.new(:Box), takes: true)],
      return_type: Type.new(:Void),
      emit: IntrinsicEmit.new(mutates_receiver: true)
    )
    store_call.matched_signature = store_sig
    store_hoists = []
    Hoist.send(:collect_stmt_hoists!, store_call, store_hoists, Hoist::HoistCounter.new, nil)
    expect(store_call.args.first).to be_a(AST::Identifier)
    expect(store_hoists.first.value).to be(stored_concat)

    yielded_concat = string_concat.call("g", "h")
    yield_expr = AST::YieldExpr.new(tok, yielded_concat)
    yield_hoists = []
    Hoist.send(:collect_stmt_hoists!, yield_expr, yield_hoists, Hoist::HoistCounter.new, nil)
    expect(yield_expr.expr).to be_a(AST::Identifier)
    expect(yield_hoists.first.value).to be(yielded_concat)

    decl_sym = SymbolEntry.new(reg: AST::VarDecl.new(tok, "local", nil, lit("v"), false), type: :String, mutable: false, storage: :heap)
    decl_sym.reg.symbol = decl_sym
    expect(AST.declaration_symbol(decl_sym)).to be(decl_sym)
    expect(AST.declaration_symbol(nil)).to be_nil
  end

  it "covers MIR hoist type and cleanup inference edges" do
    low = lowering

    untyped_owned = MIR::Call.new("make", [], false, true)
    expect(low.send(:owned_call_result_requires_cleanup?, untyped_owned)).to eq(true)

    owned_string = MIR::Call.new("make", [], false, true)
    owned_string.result_type = Type.new(:String)
    expect(low.send(:owned_call_result_requires_cleanup?, owned_string)).to eq(true)

    fallible_owned = MIR::Call.new("fallibleString", [], false, true)
    fallible_owned.result_type = Type.new(:String)
    try_owned = MIR::TryExpr.new(fallible_owned)
    prefix, ident = low.send(:normalize_allocating_used_expr, try_owned)
    try_let = prefix.grep(MIR::Let).find { |let| let.name == ident.name }
    expect(try_let.init).to be_a(MIR::TryExpr)
    expect(try_let.init.expr).to equal(fallible_owned)
    expect(prefix.grep(MIR::Let).none? { |let| let.init.equal?(fallible_owned) }).to eq(true)

    contract_sig = FunctionSignature.new(params: [], return_type: Type.new(:String))
    contract = MIR::CallableContract.new(contract_sig, MIR::OwnershipContract.empty, 0)
    contract_call = MIR::Call.new("contract_make", [], false, false, contract)
    expect(low.send(:typed_cleanup_entry_for_mir_result, contract_call).kind).to eq(:heap_string)

    expect(low.send(:mir_alloc_mark_type_info, MIR::AllocSlice.new("i64", MIR::Lit.new("4"), :heap)).resolved).to eq(:"i64[]")

    typed_bg = MIR::BgBlock.new(structural_bg_plan, {}, [], nil)
    typed_bg.result_type = Type.new(:String)
    expect(low.send(:mir_alloc_mark_type_info, typed_bg).resolved).to eq(:String)
    expect { low.send(:mir_alloc_mark_type_info, MIR::BgBlock.new(structural_bg_plan, {}, [], nil)) }.to raise_error(/BgBlock has no result type/)

    typed_try = MIR::TryCatch.new(MIR::Ident.new("fallible"), MIR::Lit.new("fallback"), nil)
    typed_try.result_type = Type.new(:String)
    expect(low.send(:mir_alloc_mark_type_info, typed_try).resolved).to eq(:String)
    expect { low.send(:mir_alloc_mark_type_info, MIR::TryCatch.new(MIR::Ident.new("fallible"), MIR::Lit.new("fallback"), nil)) }.to raise_error(/TryCatch has no result type/)

    typed_block = MIR::BlockExpr.new("__typed", [MIR::BreakStmt.new("__typed", MIR::Ident.new("x"))])
    typed_block.result_type = Type.new(:String)
    expect(low.send(:mir_alloc_mark_type_info, typed_block).resolved).to eq(:String)

    mark_only_block = MIR::BlockExpr.new("__marked", [
      MIR::AllocMark.new("tmp", :heap, Type.new(:String)),
      MIR::BreakStmt.new("__marked", MIR::Ident.new("unused")),
    ])
    expect(low.send(:block_expr_result_type, mark_only_block).resolved).to eq(:String)

    heap_string_block = MIR::BlockExpr.new("__owned_string", [
      MIR::BreakStmt.new("__owned_string", MIR::DupeSlice.new(MIR::Ident.new("s"), :heap)),
    ])
    expect(low.send(:mir_alloc_mark_type_info, heap_string_block).resolved).to eq(:String)

    untyped_block = MIR::BlockExpr.new("__untyped", [MIR::BreakStmt.new("__untyped", MIR::Ident.new("plain"))])
    expect { low.send(:mir_alloc_mark_type_info, untyped_block) }.to raise_error(/BlockExpr has no result type/)
    expect { low.send(:mir_alloc_mark_type_info, MIR::Orelse.new(MIR::Ident.new("a"), MIR::Ident.new("b"))) }.to raise_error(/no typed allocation result/)
    expect { low.send(:mir_alloc_mark_type_info, MIR::Ident.new("plain")) }.to raise_error(/unhandled allocating MIR node/)

    nested = MIR::IfStmt.new(MIR::Ident.new("cond"), [
      MIR::ExprStmt.new(MIR::DupeSlice.new(MIR::Ident.new("s"), :heap), false),
    ], nil)
    low.send(:normalize_nested_mir_bodies!, nested)
    expect(nested.then_body.first).to be_a(MIR::AllocMark)

    local_cap = MIR::CapWrap.new(MIR::Ident.new("value"), "Counter", :local, nil, nil, nil, :heap)
    expect(low.send(:hoist_cleanup_entry, local_cap, nil)[:zig_type]).to eq("*Counter")
    expect(low.send(:hoist_cleanup_entry, MIR::FreezeExpr.new(MIR::Ident.new("value"), "Counter"), nil).kind).to eq(:frozen)
    expect { low.send(:hoist_cleanup_entry, MIR::Ident.new("plain"), nil) }.to raise_error(/unhandled allocating MIR node/)

    expect(low.send(:cleanup_entry_for_ownership_effect, MIR::DupeSlice.new(MIR::Ident.new("s"), :heap), alloc: :heap).kind).to eq(:heap_string)
    expect(low.send(:cleanup_entry_for_ownership_effect, MIR::FreezeExpr.new(MIR::Ident.new("value"), "Counter"), alloc: :heap).kind).to eq(:frozen)

    transferred_block = MIR::BlockExpr.new("__transferred", [
      MIR::Let.new("owned", MIR::DupeSlice.new(MIR::Ident.new("s"), :heap), false, Type.new(:String), nil),
      MIR::AllocMark.new("owned", :heap, Type.new(:String)),
      MIR::TransferMark.new("owned", :block_result, :heap),
      MIR::BreakStmt.new("__transferred", MIR::Ident.new("owned")),
    ])
    expect(low.send(:cleanup_entry_for_ownership_effect, transferred_block, alloc: :heap).kind).to eq(:heap_string)
  end

  it "covers remaining hoist branch edges" do
    string_concat = lambda do |left = "a", right = "b"|
      expr = AST::BinaryOp.new(tok, lit(left), :ADD, lit(right))
      expr.full_type = Type.new(:String)
      expr.string_concat = true
      expr
    end

    bg_stream = AST::BgStreamBlock.new(tok, [AST::PassStmt.new(tok)], nil, nil)
    expect(Hoist.child_bodies(bg_stream)).to eq([bg_stream.body])

    struct_lit = AST::StructLit.new(tok, "Box", { "name" => string_concat.call("s", "t") }, :heap, [])
    struct_hoists = []
    Hoist.send(:hoist_concats_within!, struct_lit, struct_hoists, Hoist::HoistCounter.new)
    expect(struct_lit.fields["name"]).to be_a(AST::Identifier)

    nested_list = AST::ListLit.new(tok, [lit("plain")], :heap)
    Hoist.send(:hoist_concats_within!, nested_list, [], Hoist::HoistCounter.new)

    low = lowering
    wrapped = MIR::Cast.new(MIR::DupeSlice.new(MIR::Ident.new("s"), :heap), "[]const u8", :as)
    expect(low.send(:mir_alloc_mark_type_info, wrapped).resolved).to eq(:String)

    cleanup_entry = CleanupEntry.build(:heap_string, alloc: :heap, has_moved_guard: true)
    if_bind = MIR::IfBindStmt.new([
      { expr: MIR::DupeSlice.new(MIR::Ident.new("maybe"), :heap), capture: "captured" },
    ], [MIR::Cleanup.new("captured", cleanup_entry)], nil)
    prefix = low.send(:normalize_allocating_mir_stmt!, if_bind)
    normalized_name = if_bind.bindings.first[:expr].name
    expect(prefix).not_to be_empty
    expect(if_bind.then_body.first).to be_a(MIR::TransferMark)
    expect(if_bind.then_body.first.name).to eq(normalized_name)
    expect(if_bind.else_body.first).to be_a(MIR::TransferMark)

    existing_transfer = MIR::IfBindStmt.new([], [MIR::TransferMark.new("kept", :owned_sink, :heap)], nil)
    expect(low.send(:if_bind_transfer_present?, existing_transfer, "kept")).to eq(true)

    if_chain = MIR::IfChain.new([MIR::IfChainBranch.new(cond: MIR::DupeSlice.new(MIR::Ident.new("cond"), :heap), body: [])], nil)
    chain_prefix = low.send(:normalize_allocating_mir_stmt!, if_chain)
    expect(chain_prefix).not_to be_empty
    expect(if_chain.branches.first.cond).to be_a(MIR::Ident)

    expect(low.send(:normalized_alloc_wrapper_alias?, MIR::Cast.new(MIR::Ident.new("aliased"), "[]const u8", :as))).to eq(true)
    expect(low.send(:normalized_alloc_wrapper_alias?, MIR::TryExpr.new(MIR::Ident.new("aliased")))).to eq(false)

    inline_sig = FunctionSignature.new(params: [], return_type: Type.new(:"String[]", collection: :list))
    inline = registry_call("test", inline_sig)
    expect(low.send(:typed_cleanup_entry_for_mir_result, inline).kind).to eq(:uniform)

    rc = MIR::RcRetain.new(MIR::Ident.new("rc"), "Counter", "rcRetain")
    expect(low.send(:cleanup_entry_for_ownership_effect, rc, alloc: :heap).kind).to eq(:rc)
  end

  it "covers capability lowering helper edge branches" do
    low = lowering
    low.runtime_state.rt_name = "rt"
    low.define_singleton_method(:lower) do |node|
      if node.respond_to?(:name)
        MIR::Ident.new(node.name.to_s)
      else
        MIR::Ident.new("value")
      end
    end
    low.define_singleton_method(:emit_expr) do |node|
      node.is_a?(MIR::Ident) ? node.name : node.to_s
    end
    low.define_singleton_method(:lower_body) do |_body|
      [MIR::ExprStmt.new(MIR::Ident.new("body"), false)]
    end
    low.define_singleton_method(:emit_stmts_zig) do |_stmts|
      "body();"
    end

    root = id("root", type: Type.new(:Counter), storage: :heap)
	    field = AST::GetField.new(tok, root, "lock")
	    field.full_type = Type.new(:Counter, ownership: :shared, sync: :locked)
	    field_cap = capability_transition(capability: :EXCLUSIVE, var_node: field, resolved_type: field.full_type)
	    expect(field_cap.target_label).to eq("lock")
	    expect(field_cap.sync).to eq(:locked)
	    expect(field_cap.storage).to eq(:shared)
    expect(low.send(:with_cap_zig_target, field, "lock")).to eq("root.lock")

    with_node = AST::WithBlock.new(tok, [], [], nil)
    attach_capability_plan!(with_node)
    local_var = id("local_value", type: Type.new(:Counter), storage: :heap)
    local_cap = capability_transition(capability: :RESTRICT, var_node: local_var, alias: "alias_value", alias_mutable: false, resolved_type: Type.new(:Counter))
    local_context = MIRLoweringCapabilities::WithCapabilityBindingContext.new(
      node: with_node,
      cap: local_cap,
      var_node: local_var,
      var_name: "local_value",
      alias_name: "alias_value",
      resolved_type: Type.new(:Counter),
      var_sync: :local,
      var_storage: :heap,
      zig_var: "local_value",
      clause: nil,
      with_label: nil,
      needs_sort: false,
      rt_name: "rt",
    )
    restrict_binding = low.send(:restrict_capability_binding, local_context)
    expect(restrict_binding).to eq([
      MIR::Let.new("alias_value", MIR::Ident.new("local_value"), false, nil, nil),
    ])

    view_var = id("view_source", type: Type.new(:Box), storage: :heap)
    view_cap = capability_transition(capability: :VIEW, var_node: view_var, alias: "view_alias", resolved_type: Type.new(:Box))
    view_context = MIRLoweringCapabilities::WithCapabilityBindingContext.new(
      node: with_node,
      cap: view_cap,
      var_node: view_var,
      var_name: "view_source",
      alias_name: "view_alias",
      resolved_type: Type.new(:Box),
      var_sync: :versioned,
      var_storage: :heap,
      zig_var: "view_source",
      clause: nil,
      with_label: nil,
      needs_sort: false,
      rt_name: "rt",
    )
    view_binding = low.send(:view_capability_binding, view_context)
    expect(view_binding).to include(an_instance_of(MIR::DeferStmt))
    expect(view_binding.grep(MIR::DeferStmt).first.body.method).to eq("release")
    expect(view_binding).to include(an_instance_of(MIR::IfStmt))

    snapshot_node = AST::WithBlock.new(tok, [], [], nil)
    snapshot_node.snapshot_mode = :read
    emitter = MIREmitter.new
    expect(emitter.send(:emit_with_match_probe, :VERSIONED, "cell", true)).to include("compareAndPublish")
    expect(emitter.send(:emit_with_match_probe, :VERSIONED, "cell", false)).to eq("@hasDecl(CheatLib.WithMatchInner(@TypeOf(cell)), \"Inner\")")
    expect(emitter.send(:emit_with_match_probe, :ATOMIC, "cell", true)).to include("compareAndPublish")
    expect(emitter.send(:emit_with_match_probe, :ATOMIC, "cell", false)).to include("cmpxchgStrong")
    expect { emitter.send(:emit_with_match_probe, :ACTOR, "cell", false) }.to raise_error(/no probe/)

    match_cell = id("cell", type: Type.new(:Counter, sync: :locked), storage: :heap)
    match_node = AST::WithBlock.new(tok, [
      AST::Capability.new(capability: :EXCLUSIVE, var_node: match_cell, alias: "guarded")
    ], [], nil)
    match_node.arms = [
      { family: :LOCKED, body: [AST::PassStmt.new(tok)] },
      { family: :VERSIONED, body: [AST::PassStmt.new(tok)] },
    ]
    attach_capability_plan!(match_node)
    low.define_singleton_method(:lower_body) { |_body| [MIR::Noop.new] }

    match_dispatch = low.send(:lower_with_match_block, match_node).body.first
    expect(match_dispatch).to be_a(MIR::WithMatchDispatch)
    expect(match_dispatch.cell).to eq(MIR::Ident.new("cell"))
    expect(match_dispatch.alias_name).to eq("guarded")
    expect(match_dispatch.arms.map(&:family)).to eq([:LOCKED, :VERSIONED])
    expect(match_dispatch.arms.first.guard_var).to start_with("__guarded_match_")

    expect(low.send(:ast_contains_return?, { nested: [AST::ReturnNode.new(tok, nil)] })).to eq(true)
    expect(low.send(:ast_contains_return?, fn([AST::ReturnNode.new(tok, nil)]))).to eq(false)

    guard_clause = AST::ErrorClause.new(selectors: [], action: :unknown, retries: nil, token: tok)
    guard_clause.matched_types = [:GuardFail]
    guard_node = AST::WithBlock.new(tok, [], [], nil)
    guard_node.lock_error_clause = guard_clause
    attach_capability_plan!(guard_node)
    expect(low.send(:guard_fail_flow_body, guard_node)).to eq([])

    pre_fn = fn([])
    pre_fn.pre_clauses = [{ expr: id("ok", type: :Bool), source: "" }]
    pre_lowered = low.send(:lower_pre_clauses, pre_fn)
    pre_body = pre_lowered.first.then_body
    expect(pre_body.first.expr).to be_a(MIR::MethodCall)
    expect(pre_body.first.expr.receiver).to eq(MIR::Ident.new("rt"))
    expect(pre_body.first.expr.method).to eq("setError")
    expect(pre_body.first.expr.args[2].value).to include("precondition failed")
    expect(pre_body.last.value).to eq(MIR::FieldGet.new(MIR::Ident.new("error"), "CheatError"))

    unknown_clause = AST::ErrorClause.new(selectors: [], action: :unknown, retries: nil, token: tok)
    expect { low.send(:lock_failure_action, unknown_clause, "__with", with_node) }.to raise_error(/unknown lock action/)
  end

  it "covers concurrency lowering defensive and diagnostic branches" do
    low = lowering

    mirror = MIR::AllocMark.new("__ctx_3.owned", :heap, Type.new(:String), :heap)
    expect(low.send(:capture_ownership_mirror_node?, mirror, "__ctx_3")).to eq(true)

    refused = {
      "ptr" => CaptureStrategy::Refuse.new(reason: :pointer_passed_without_transfer, owner_name: "ptr"),
      "pool" => CaptureStrategy::Refuse.new(reason: :pool_borrow_without_transfer, owner_name: "pool"),
      "slice" => CaptureStrategy::Refuse.new(reason: :array_borrow_without_transfer, owner_name: "slice"),
      "heap" => CaptureStrategy::Refuse.new(reason: :heap_backed_without_transfer, owner_name: "heap"),
      "mystery" => CaptureStrategy::Refuse.new(reason: :unknown_capture_shape, owner_name: "mystery"),
    }
    bg = AST::BgBlock.new(tok, [], nil, nil, false, false, nil, false)
    bg.capture_analysis = CapabilityHelper::CaptureAnalysis.new(strategies: refused)

    expect {
      low.send(:enforce_bg_capture_strategies!, bg, {})
    }.to raise_error(RuntimeError) { |error|
      message = error.message
      expect(message).to include("'ptr' is @pool/@map/HashMap")
      expect(message).to include("'pool' is @pool")
      expect(message).to include("'slice' is a slice borrow")
      expect(message).to include("'heap' is heap-backed")
      expect(message).to include("'mystery' cannot be safely captured (unknown_capture_shape)")
    }

    expect {
      low.send(:fsm_bg_block_from_transform!, bg, "raw zig", {}, double)
    }.to raise_error(/FSM lowering must return MIR::FsmLoweringResult/)
  end

  it "covers hardened MIR ownership finalization fallbacks directly" do
    low = lowering

    already_finalized = MIR::Let.new("kept", MIR::Lit.new("1"), false, Type.new(:Int64), nil)
    already_state = ownership_finalization_context
    low.send(:mark_ownership_finalized_node!, already_finalized)
    low.send(:append_ownership_finalized_node!, already_state, already_finalized, [], 4, 2)
    expect(already_state.out).to eq([already_finalized])

    already_mark = MIR::TransferMark.new("kept", :owned_sink, :heap)
    already_mark_state = ownership_finalization_context
    low.send(:mark_ownership_finalized_node!, already_mark)
    low.send(:append_transfer_marks_to_body!, already_mark_state, [already_mark], 4, 2)
    expect(already_mark_state.out).to eq([already_mark])

    append_state = ownership_finalization_context
    finalized_for_append = MIR::TransferMark.new("done", :return, :heap)
    low.send(:mark_ownership_finalized_node!, finalized_for_append)
    low.send(:append_transfer_marks!, [finalized_for_append], append_state)
    expect(append_state.out).to eq([finalized_for_append])

    expect(low.send(:alloc_mark_present?, [MIR::AllocMark.new("owned", :heap, Type.new(:String))], "owned")).to eq(true)
    expect(low.send(:transfer_mark_present?, [MIR::TransferMark.new("owned", :return, :heap)], "owned")).to eq(true)
    borrowed = MIR::OwnedBorrow.new("borrowed", "source")
    expect(low.send(:dedupe_ownership_facts, [borrowed, borrowed])).to eq([borrowed])

    cap_state = ownership_finalization_context(body_alloc_mark_names: Set["cap_src"])
    cap = MIR::CapWrap.new(MIR::Ident.new("cap_src"), "Box", :own_only, nil, nil, "arcCreate", :heap)
    targets = low.send(:ownership_transfer_operands_for_node, cap, cap_state)
    expect(targets.map { |target| [target.name, target.target, target.target_alloc] })
      .to eq([["cap_src", :owned_sink, :heap]])

    facts = []
    low.send(:append_ownership_facts_for_owned_result!,
      facts, "promise", MIR::BgBlock.new(structural_bg_plan, {}, [], nil), Type.new(:String))
    expect(facts.first).to be_a(MIR::OwnedReturn)
    expect(facts.first.name).to eq("promise")

    state = ownership_finalization_context(
      out: [MIR::MoveMark.new("owned")],
      guarded_cleanup_names: Set["owned"],
    )
    low.send(:append_move_guard_for_transfer_mark!, MIR::TransferMark.new("owned", :owned_sink, :heap), state)
    expect(state.out.count { |stmt| stmt.is_a?(MIR::MoveMark) && stmt.name == "owned" }).to eq(1)
    unmarked_state = ownership_finalization_context(guarded_cleanup_names: Set["owned"])
    low.send(:append_move_guard_for_transfer_mark!, MIR::TransferMark.new("owned", :owned_sink, :heap), unmarked_state)
    expect(unmarked_state.out).to include(an_instance_of(MIR::MoveMark))

    guarded_entry = CleanupEntry.build(:heap_string, alloc: :heap, has_moved_guard: true)
    nested_return = MIR::IfChain.new([
      MIR::IfChainBranch.new(
        cond: MIR::Lit.new("cond"),
        body: [
          MIR::TransferMark.new("returned", :return, :heap),
          MIR::ReturnStmt.new(MIR::Ident.new("returned")),
        ],
      ),
    ], nil)
    finalized = low.send(:append_ownership_transfers_for_mir_body, [
      MIR::AllocMark.new("returned", :heap, Type.new(:String)),
      MIR::Let.new("returned", MIR::DupeSlice.new(MIR::Lit.new("\"x\""), :heap), false, Type.new(:String), nil),
      MIR::Cleanup.new("returned", guarded_entry),
      nested_return,
    ])
    finalized_return = T.must(finalized.find { |node| node.is_a?(MIR::IfChain) })
    finalized_branch = T.must(finalized_return.branches).first
    expect(finalized_branch.body.any? { |node| node.is_a?(MIR::MoveMark) && node.name == "returned" }).to eq(true)

    fact = MIR::OwnershipConsumptionFact.new(
      operands: [MIR::OwnershipOperandFact.owned_binding("x", Type.new(:String), "spec", :heap)],
      target: :owned_sink,
      target_alloc: :heap,
      source: "spec",
      covers_consuming_params: true,
    )
    expr = MIR::Call.new("consume", [], false, false)
    expr.ownership_consumption = fact
    expect(low.send(:ownership_consumption_for_node, MIR::Ident.new("plain"))).to be_nil
    expect(low.send(:ownership_consumption_for_node, expr)).to be(fact)
    expect(low.send(:ownership_consumption_for_node, MIR::ExprStmt.new(expr, false))).to be(fact)
    expect(low.send(:ownership_contract_for_node, Object.new)).to be_nil
    expect(low.send(:ownership_contract_for_node, MIR::Call.new("plain", [], false, false))).to be_nil

    expect(low.send(:ownership_consumer_requires_fact?, MIR::Ident.new("plain"))).to eq(false)
    expect(low.send(:ownership_consumer_requires_fact?, registry_call("spec", FunctionSignature.borrowing_intrinsic))).to eq(false)
    no_params_sig = FunctionSignature.new(params: [], return_type: Type.new(:Void), intrinsic: true)
    expect(low.send(:ownership_consumer_requires_fact?, registry_call("spec", no_params_sig))).to eq(false)
    taking_sig = FunctionSignature.new(params: [param("taken", takes: true)], return_type: Type.new(:Void))
    expect(low.send(:ownership_consumer_requires_fact?, registry_call("spec", taking_sig))).to eq(true)
    non_taking_sig = FunctionSignature.new(params: [param("kept")], return_type: Type.new(:Void))
    expect(low.send(:ownership_consumer_requires_fact?, registry_call("spec", non_taking_sig))).to eq(false)

    try_catch = MIR::TryCatch.new(MIR::Ident.new("fallible"), MIR::Ident.new("fallback"), nil)
    expect(low.send(:place_owned_try_catch_for_destination, try_catch, Type.new(:String), :heap)).to be_a(MIR::TryCatch)
    plain_try_catch = MIR::TryCatch.new(MIR::Ident.new("fallible"), MIR::Ident.new("fallback"), nil)
    expect(low.send(:place_owned_try_catch_for_destination, plain_try_catch, Type.new(:Int64), :heap)).to be_a(MIR::TryCatch)
    mismatch_try_catch = MIR::TryCatch.new(
      MIR::DupeSlice.new(MIR::Ident.new("source"), :frame),
      MIR::Ident.new("fallback"),
      nil,
    )
    placed_try_catch = low.send(:place_owned_try_catch_for_destination, mismatch_try_catch, Type.new(:String), :heap)
    expect(placed_try_catch).to be_a(MIR::BlockExpr)
    expect(placed_try_catch.body).to include(an_instance_of(MIR::AllocMark))
    expect(placed_try_catch.body.last).to be_a(MIR::BreakStmt)

    low.function_state.current_bindings = {}
    low.function_state.lowered_alloc_names = Set["lowered"]
    expect(low.send(:ownership_consumed_name_operands, ["lowered"], "spec", :heap).first.name).to eq("lowered")
    low.function_state.lowered_alloc_names = Set.new
    expect(low.send(:ownership_consumed_name_operands, ["hidden"], "spec", :heap)).to eq([])
    expect(low.send(:ownership_operand_type, lit("typed", type: :String), "spec").resolved).to eq(:String)

    low.function_state.current_bindings = {}
    low.function_state.pending_stmts = [MIR::AllocMark.new("pending", :heap, Type.new(:String))]
    expect(low.send(:owned_binding_visible?, "pending")).to eq(true)
    low.function_state.pending_stmts = []
    low.function_state.lowered_alloc_names = Set.new
    expect(low.send(:owned_binding_visible?, "missing")).to eq(false)

    expect(low.send(:borrowed_ownership_ast?, nil)).to eq(false)
    indexed_read = AST::GetIndex.new(tok, id("items"), lit(0, type: :Int64))
    expect(low.send(:borrowed_ownership_ast?, indexed_read)).to eq(true)
    expect(low.send(:borrowed_ownership_ast?, AST::CopyNode.new(tok, indexed_read))).to eq(false)
    borrowed = id("borrowed", storage: :heap)
    borrowed.container_borrow = true
    expect(low.send(:borrowed_ownership_ast?, borrowed)).to eq(true)
    expect(low.send(:borrowed_ownership_ast?, lit("x", type: :String))).to eq(false)

    missing_owned_operand = low.send(
      :ownership_operands_for_sink_value,
      MIR::Call.new("make", [], false, false),
      lit("hidden", type: :String),
      Type.new(:String),
      "spec",
      :heap,
      require_visible_owned: true,
    )
    expect(missing_owned_operand.first.borrowed).to eq(true)
    expect(missing_owned_operand.first.source).to include("missing owned binding")

    type_root = id("TypeName")
    type_root.token = Lexer::Token.new(:TYPE_ID, "TypeName", 1, 1)
    type_field = AST::GetField.new(tok, type_root, "field")
    type_field.full_type = Type.new(:Int64)
    expect(low.send(:borrowed_ownership_ast?, type_field)).to eq(false)
    literal_field = AST::GetField.new(tok, lit("root", type: :String), "field")
    literal_field.full_type = Type.new(:Int64)
    expect(low.send(:borrowed_ownership_ast?, literal_field)).to eq(false)
    owner_field = AST::GetField.new(tok, id("owner", storage: :heap), "field")
    owner_field.full_type = Type.new(:Int64)
    expect(low.send(:borrowed_ownership_ast?, owner_field)).to eq(true)

    expect(low.send(:ownership_operands_for_sink_value,
      MIR::Ident.new("borrowed"), owner_field,
      Type.new(:String), "spec", :heap, require_visible_owned: true).first.borrowed).to eq(true)
    expect(low.send(:ownership_operands_for_sink_value,
      MIR::Ident.new("missing"), lit("missing", type: :String),
      Type.new(:String), "spec", :heap, require_visible_owned: false)).to eq([])
    rooted = id("rooted", type: :String)
    low.function_state.current_bindings = {
      "rooted" => CleanupEntry.build(:uniform, alloc: :heap),
    }
    rooted_operand = low.send(:ownership_operands_for_sink_value,
      MIR::Ident.new("other"), rooted,
      Type.new(:String), "spec", :heap, require_visible_owned: false)
    expect(rooted_operand.first.name).to eq("rooted")
    no_fact_call = MIR::Call.new("read", [], false, false)
    expect(low.send(:ownership_operands_for_sink_value,
      no_fact_call, lit("missing", type: :String),
      Type.new(:String), "spec", :heap, require_visible_owned: false)).to eq([])

    expect(low.send(:strip_try, MIR::Ident.new("plain")).name).to eq("plain")
    expect(low.send(:strip_try, MIR::Call.new("fallible", [], true, false)).try_wrap).to eq(false)
  end

  it "covers ownership transfer collection through AST structural children" do
    dataflow = OwnershipDataflow.new(FunctionCFG.build(fn([])), fn([]), schema_lookup: nil)
    state = owner_state("a", "b", "c", "d", "e", "f", "g")

    struct_lit = AST::StructLit.new(tok, "Box", { "a" => id("a", storage: :heap) }, :heap, [])
    list_lit = AST::ListLit.new(tok, [id("b", storage: :heap)], :heap)
    type_ident = id("Maybe")
    type_ident.token = Lexer::Token.new(:TYPE_ID, "Maybe", 1, 1)
    union_ctor = AST::MethodCall.new(tok, type_ident, "Some", [id("c", storage: :heap)])
    share = AST::ShareNode.new(tok, id("d", storage: :heap))
    cap = AST::CapabilityWrap.new(tok, id("e", storage: :heap), :shared)
    get = AST::GetField.new(tok, id("f", storage: :heap), "payload")
    indirect = Type.new(:String)
    indirect.layout = :indirect
    get.full_type = indirect

    consumed = dataflow.send(:collect_binding_move_places,
      AST::ListLit.new(tok, [struct_lit, list_lit, union_ctor, share, cap, get, AST::CopyNode.new(tok, id("g", storage: :heap))], :heap),
      state).map(&:path)

    expect(consumed).to include("a", "b", "c", "d", "e", "f")
    expect(consumed).not_to include("g")
  end

  it "covers ownership read checks and shard allocation facts" do
    fn_node = fn([])
    checker = UseAfterMoveChecker.new(fn_node, OwnershipDataflow.new(FunctionCFG.build(fn_node), fn_node))
    moved_state = OwnershipDataflow.state_from_names(
      "dead" => OwnershipDataflow::OwnerEntry.new(state: OwnershipDataflow::MOVED, allocator: :heap, needs_cleanup: true),
    )
    checker.send(:check_identifier_read, "dead", moved_state, tok)
    checker.send(:check_identifier_read, "unknown", moved_state, tok)
    expect(checker.errors.join).to include("USE_AFTER_MOVE")

    shared = id("shared", storage: :heap)
    shared_type = Type.new(:String)
    shared_type.ownership = :shared
    shared.full_type = shared_type
    checker.send(:check_share_reads, AST::ShareNode.new(tok, shared), OwnershipDataflow.state_from_names("shared" => owner_entry(moved_state, "dead")))
    checker.send(:check_share_reads, AST::ShareNode.new(tok, AST::CopyNode.new(tok, shared)), OwnershipDataflow.state_from_names("shared" => owner_entry(moved_state, "dead")))
    checker.send(:check_share_reads, AST::ShareNode.new(tok, AST::BinaryOp.new(tok, shared, :ADD, lit("x"))), OwnershipDataflow.state_from_names("shared" => owner_entry(moved_state, "dead")))
    plain = id("plain", storage: :heap)
    checker.send(:check_share_reads, AST::ShareNode.new(tok, plain), OwnershipDataflow.state_from_names("plain" => owner_entry(moved_state, "dead")))
    expect(checker.errors.join).to include("shared")

    call = AST::FuncCall.new(tok, "allocates", [])
    call.full_type = :String
    fn_node = fn([])
    fn_node.uses_frame = true
    expect(LoopFrameAnalysis.key_allocates_frame?(call, { "allocates" => fn_node })).to eq(true)

    frame_list = AST::ListLit.new(tok, [], :frame)
    frame_list.full_type = Type.new(:"Int64[]")
    expect(LoopFrameAnalysis.key_allocates_frame?(frame_list, {})).to eq(true)
  end

  it "covers bg capture transfer helpers through expression children" do
    dataflow = OwnershipDataflow.new(FunctionCFG.build(fn([])), fn([]), schema_lookup: nil)
    state = owner_state("captured", "given")
    bg = AST::BgBlock.new(tok, [AST::MoveNode.new(tok, id("given", storage: :heap))], nil, nil, false, false, nil, false)
    bg.capture_analysis = double(resource_captures: Set["captured"], captures: { "captured" => true }, move_mark_names: Set["given"])
    call = AST::FuncCall.new(tok, "enqueue", [bg])

    expect(dataflow.send(:collect_bg_capture_places_in_args, call, state).map(&:path)).to include("captured", "given")

    missing = AST::BgBlock.new(tok, [], nil, nil, false, false, nil, false)
    missing.capture_analysis = double(resource_captures: Set["missing"], captures: {}, move_mark_names: Set["also_missing"])
    expect(dataflow.send(:collect_bg_capture_places_in_args, AST::FuncCall.new(tok, "enqueue", [missing]), state)).to eq([])
  end

  it "covers FSM result-transfer roots, marks, and owned-result guard clearing" do
    low = lowering
    box_type = Type.new(:Box, layout: :indirect)
    owned = id("owned", type: box_type, storage: :heap)
    nested = id("nested", type: box_type, storage: :heap)
    listed = id("listed", type: box_type, storage: :heap)

    low.function_state.current_bindings = {
      "owned" => CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: false),
      "nested" => CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: false),
      "listed" => CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: false),
    }
    low.define_singleton_method(:ownership_tracked_transfer_type?) { |_type| true }

    expect(low.send(:fsm_ast_result_consumed_roots, AST::MoveNode.new(tok, owned))).to eq(["owned"])
    expect(low.send(:fsm_ast_result_consumed_roots, AST::MoveNode.new(tok, AST::GetField.new(tok, owned, "field")))).to eq([])

    struct_lit = AST::StructLit.new(tok, "Box", {
      "field" => AST::MoveNode.new(tok, nested),
      "copy" => AST::CopyNode.new(tok, id("copied", type: box_type, storage: :heap)),
    }, :heap, [])
    expect(low.send(:fsm_ast_result_consumed_roots, struct_lit)).to eq(["nested"])

    list_lit = AST::ListLit.new(tok, [
      AST::MoveNode.new(tok, listed),
      AST::CopyNode.new(tok, id("copied_list", type: box_type, storage: :heap)),
    ], :heap)
    expect(low.send(:fsm_ast_result_consumed_roots, list_lit)).to eq(["listed"])

    marks = low.send(:fsm_result_transfer_marks, MIR::Ident.new("owned"), owned)
    expect(marks).not_to be_empty

    low.define_singleton_method(:escaping_value_alloc) { |_type| :heap }
    low.define_singleton_method(:with_decl_alloc) { |_alloc, &blk| blk.call }
    low.define_singleton_method(:lower) { |_node| MIR::Ident.new("owned") }
    low.define_singleton_method(:place_value_for_destination) { |mir, *_args| mir }
    low.define_singleton_method(:mir_allocates?) { |_mir| false }
    low.define_singleton_method(:flush_pending) { [] }
    low.define_singleton_method(:ast_void_type?) { |_type| false }
    low.define_singleton_method(:with_ownership_consumption) { |mir, *_args, **_kwargs| mir }
    low.capture_state.current_fsm_owned_result_guards = { "owned" => "owned_moved" }

    lowered = low.send(:lower_step_stmts, [owned], no_result: false, ctx_id: 9)
    expect(lowered).to include(
      an_object_having_attributes(
        target: an_object_having_attributes(field: "owned_moved"),
        value: an_object_having_attributes(value: "false"),
      ),
    )
  end

  it "covers escape heap return and argument-return dependency facts" do
    p = param("value", type: :String)
    heap_arg = id("arg", type: :String, storage: :heap)
    heap_arg.full_type.mark_heap_allocated!

    expect(EscapeAnalysis.send(:heap_return_from_args?, [heap_arg], [p], Set["value"], Type.new(:String), nil)).to eq(true)
    expect(EscapeAnalysis.send(:heap_return_from_args?, [lit("x", type: :String)], [p], Set["missing"], Type.new(:String), nil)).to eq(true)
    int_param = param("n", type: :Int64)
    expect(EscapeAnalysis.send(:heap_return_from_args?, [lit(1, type: :Int64)], [int_param], Set["n"], Type.new(:Int64), nil)).to eq(false)
    expect(EscapeAnalysis.send(:heap_return_from_args?, [], [], nil, Type.new(:String), nil)).to be_nil

    callee_return = AST::ReturnNode.new(tok, id("made", type: :String, storage: :heap))
    callee = fn([callee_return], return_type: :String)
    callee_summary = Annotator::Phases::FunctionBodySummary.new(
      name: "callee",
      callees: Set.new,
      propagating_callees: Set.new,
      has_fnptr_call: false,
      raises_directly: false,
      return_nodes: [callee_return],
    )
    callee_facts = EscapeAnalysis.send(:function_facts, callee, callee_summary)
    expect(EscapeAnalysis.send(:function_facts_have_owned_return_value?, callee_facts, nil)).to eq(true)
    return_value = id("returned", type: :String, storage: :heap)
    ret = AST::ReturnNode.new(tok, return_value)
    probe = fn([ret], return_type: :String)
    facts = EscapeAnalysis.send(:function_facts, probe, Annotator::Phases::FunctionBodySummary.new(
      name: probe.name,
      callees: Set.new,
      propagating_callees: Set.new,
      has_fnptr_call: false,
      raises_directly: false,
      return_nodes: [ret],
    ))
    expect(facts.fn.name).to eq(probe.name)
    expect(facts.return_values).to eq([return_value])
    expect(EscapeAnalysis.send(:function_facts_have_heap_return_binding?, facts)).to eq(true)

    borrowed = fn([], params: [p], return_type: :String)
    borrowed.return_lifetime = :wildcard
    expect(EscapeAnalysis.send(:borrowed_return?, borrowed, id("value", type: :String))).to eq(true)
  end

  it "covers MIR expression type substitution and fallback type decisions" do
    low = lowering
    expect(SymbolEntry.new(reg: "locked", type: Type.new(:String), mutable: true, storage: :stack, sync: :locked).sync_or_shared_storage?).to eq(true)

    source = Type.new(:T, sync: :locked, layout: :indirect)
    replaced = low.send(:substitute_mir_type, source, { T: :String })
    expect(replaced.resolved).to eq(:String)
    expect(replaced.sync).to eq(:locked)
    expect(replaced.layout).to eq(:indirect)

    generic = low.send(:substitute_mir_type, Type.new(:"Pair<T>"), { T: :String })
    expect(generic.resolved).to eq(:"Pair<String>")

    array = low.send(:substitute_mir_type, Type.new(:"T[]"), { T: :Int64 })
    expect(array.resolved).to eq(:"Int64[]")

    fixed_array = low.send(:substitute_mir_type, Type.new(:"T[4]"), { T: :String })
    expect(fixed_array.resolved).to eq(:"String[4]")

    optional = low.send(:substitute_mir_type, Type.new(:"?T"), { T: :String })
    expect(optional.resolved).to eq(:"?String")

    fallible = low.send(:substitute_mir_type, Type.new(:"!T"), { T: :String })
    expect(fallible.resolved).to eq(:"!String")

    tense = low.send(:substitute_mir_type, Type.new(:"~T[]"), { T: :Int64 })
    expect(tense.resolved).to eq(:"~Int64[]")
    unchanged_tense = Type.new(:"~String")
    expect(low.send(:substitute_mir_type, unchanged_tense, { T: :Int64 })).to equal(unchanged_tense)

    left = id("fallible", type: Type.new(:"!String"))
    op = AST::BinaryOp.new(tok, left, :OR_RESCUE, lit("fallback", type: :String))
    op.full_type = Type.new(:String)
    expect(low.send(:or_fallback_expected_type, op).resolved).to eq(:String)

    idx = AST::GetIndex.new(tok, id("items", type: Type.new(:"String[]")), lit(0, type: :Int64))
    idx.full_type = Type.new(:Untyped)
    expect(low.send(:copy_source_type_info, idx).resolved).to eq(:String)
    untyped_idx = AST::GetIndex.new(tok, id("unknown_items", type: Type.new(:Any)), lit(0, type: :Int64))
    untyped_idx.full_type = Type.new(:Any)
    untyped_idx.define_singleton_method(:typed?) { false }
    expect(low.send(:copy_source_type_info, untyped_idx).resolved).to eq(:Any)

    frame_source = SymbolEntry.new(reg: "source", type: Type.new(:String), mutable: false, storage: :frame)
    lifetime_view = id("view", type: :String, storage: :stack)
    lifetime_view.symbol.lifetime = [frame_source]
    expect(low.send(:placement_for_node, lifetime_view)).to eq(:frame)
  end

	  it "materializes unhoisted owned return values before returning identifiers" do
	    low = lowering
	    ast_return = AST::ReturnNode.new(tok, lit("made", type: :String))
	    call = MIR::Call.new("makeString", [MIR::Ident.new("rt")], false, true)

    lowered = low.send(:hoist_unhoisted_return_allocs, [MIR::ReturnStmt.new(call)], [ast_return])

    expect(lowered.grep(MIR::AllocMark).first.name).to start_with("__tmp_")
    expect(lowered.grep(MIR::Let).first.init).to equal(call)
	    expect(lowered.last.value).to be_a(MIR::Ident)
	  end

	  it "moves cleanup-bearing return transfers before ownership finalization" do
	    low = lowering
	    low.function_state.current_bindings = {
	      "owned" => CleanupEntry.build(:heap_string, alloc: :heap, has_moved_guard: false),
	    }
	    returned = id("owned", type: Type.new(:String), storage: :heap)
	    plan = low.send(:return_lowering_plan, AST::ReturnNode.new(tok, returned))
	    stmts = low.send(:return_with_transfer_marks, plan, MIR::Ident.new("owned"), MIR::ReturnStmt.new(MIR::Ident.new("owned")))

	    expect(stmts.map(&:class)).to eq([MIR::TransferMark, MIR::MoveMark, MIR::ReturnStmt])
	  end

  it "covers non-switch match lowering branches that switch lowering intentionally bypasses" do
    low = lowering
    subject = id("point", type: :Point)
    x_field = AST::PatternField.new(name: "x", value: :bind, name_token: tok)
    y_field = AST::PatternField.new(name: "y", value: lit(3, type: :Int64), name_token: tok)
    pattern = AST::StructPattern.new(tok, [x_field, y_field], false)
    case_node = AST::MatchCase.new(kind: :struct_pattern, value: pattern, body: [lit(1, type: :Int64)])
    match = AST::MatchStatement.new(tok, subject, [case_node], nil, nil, nil, false, nil)
    match.full_type = :Void

    result = low.lower(match)
    expect(result).to be_a(MIR::IfChain)
    expect(result.branches.first.body.grep(MIR::Let).map(&:name)).to include("x")
    expect(result.branches.first.cond).to be_a(MIR::BinOp)

    low.define_singleton_method(:emit_builtin) { |name, args| MIR::Call.new(name.to_s, args, false, false) }
    string_case = AST::MatchCase.new(
      kind: :eq,
      value: lit("start", type: :String),
      extra_values: [lit("stop", type: :String)],
      body: [lit(2, type: :Int64)]
    )
    string_match = AST::MatchStatement.new(tok, id("cmd", type: :String), [string_case], nil, nil, nil, false, nil)
    string_match.string_match = true
    string_match.full_type = :Void
    expect(low.lower(string_match).branches.first.cond.op).to eq("or")

    union_low = MIRLowering.new(input: MIRLoweringInput.new(union_schemas: { Result: Schemas::UnionSchema.new(variants: { Ok: :Int64, Err: :Int64, Warn: :Int64 }) }))
    union_subject = id("result", type: :Result)
    ok = AST::GetField.new(tok, id("Result"), "Ok")
    err = AST::MethodCall.new(tok, id("Result"), "Err", [])
    warn = AST::MethodCall.new(tok, id("Result"), "Warn", [])
    destructure = AST::StructPattern.new(tok, [
      AST::PatternField.new(name: "value", value: :bind, name_token: tok),
      AST::PatternField.new(name: "ignored", value: :wildcard, name_token: tok),
    ], true)
    guard_true = AST::Literal.new(tok, :BOOLEAN, true, nil)
    guard_true.full_type = :Boolean
    union_cases = [
      AST::MatchCase.new(kind: :eq, value: ok, extra_values: [err], binding: "payload", body: [lit(3, type: :Int64)]),
      AST::MatchCase.new(kind: :eq, value: warn, destructure: destructure, body: [lit(4, type: :Int64)]),
      AST::MatchCase.new(kind: :when, value: guard_true, body: [lit(5, type: :Int64)]),
    ]
    union_match = AST::MatchStatement.new(tok, union_subject, union_cases, nil, nil, nil, false, nil)
    union_match.full_type = :Void
    union_result = union_low.lower(union_match)
    expect(union_result).to be_a(MIR::IfChain)
    expect(union_result.branches.flat_map { |b| b.body.grep(MIR::Let).map(&:name) }).to include("payload", "value")

    switch_union_match = AST::MatchStatement.new(
      tok,
      union_subject,
      [AST::MatchCase.new(kind: :eq, value: warn, destructure: destructure, body: [lit(7, type: :Int64)])],
      nil,
      nil,
      nil,
      false,
      nil
    )
    switch_union_match.full_type = :Void
    switch_result = union_low.lower(switch_union_match)
    expect(switch_result).to be_a(MIR::UnionMatchStmt)
    expect(switch_result.arms.flat_map { |arm| arm.body.grep(MIR::Let).map(&:name) }).to include("value")

    generic_case = AST::MatchCase.new(kind: :eq, value: id("A", type: :Any),
      extra_values: [id("B", type: :Any)], body: [lit(6, type: :Int64)])
    generic_match = AST::MatchStatement.new(tok, id("subject", type: :Any), [generic_case], nil, nil, nil, false, nil)
    generic_match.full_type = :Void
    expect(low.lower(generic_match).branches.first.cond.op).to eq("or")
  end

  it "covers control-flow loop, match, and return-transfer edge branches" do
    low = lowering

    branch_mark = MIR::AllocMark.new("branch_owned", :frame, Type.new(:String), nil)
    default_mark = MIR::AllocMark.new("default_owned", :frame, Type.new(:String), nil)
    match_mark = MIR::AllocMark.new("match_owned", :frame, Type.new(:String), nil)
    if_chain = MIR::IfChain.new([MIR::IfChainBranch.new(cond: MIR::Lit.new("true"), body: [branch_mark])], [default_mark])
    with_match = MIR::WithMatchDispatch.new(
      MIR::Ident.new("cell"),
      "alias",
      false,
      "rt",
      [MIR::WithMatchArm.new(family: :LOCKED, guard_var: "__guard", body: [match_mark])],
    )
    low.send(:stamp_loop_frame_alloc_scopes!, [if_chain, with_match], :iteration)
    expect([branch_mark.scope, default_mark.scope, match_mark.scope]).to all(eq(:iteration))

    inf_stream_type = Type.new(:"~Int64[INF]")
    foreach_node = AST::ForEach.new(tok, "item", id("stream", type: inf_stream_type), [], nil, false)
    foreach_plan = MIRLoweringControlFlow::ForEachPlan.new(
      var: "item",
      body: [],
      rt: MIR::Ident.new("rt"),
      collection: MIR::Ident.new("stream"),
      collection_type: inf_stream_type,
      collection_setup: [],
      mutable: false,
      mark_per_iter: nil,
      tight: false,
    )
    inf_loop = low.send(:for_each_loop_stmt, foreach_node, foreach_plan)
    expect(inf_loop).to be_a(MIR::WhileStmt)
    expect(inf_loop.cond.method).to eq("nextOrNull")

    guard = AST::Literal.new(tok, :BOOLEAN, true, nil)
    guard.full_type = :Bool
    guard_case = AST::MatchCase.new(kind: :when, value: guard, body: [lit(1, type: :Int64)])
    guard_match = AST::MatchStatement.new(tok, id("plain", type: :Any), [guard_case], nil, nil, nil, false, nil)
    guard_match.full_type = :Void
    expect(low.lower(guard_match).branches.first.cond).to be_a(MIR::Lit)

    union_low = MIRLowering.new(input: MIRLoweringInput.new(union_schemas: { Result: Schemas::UnionSchema.new(variants: { Ok: :Int64, Fallback: :Int64 }) }))
    union_subject = id("result", type: :Result)
    literal_variant = id("Fallback", type: :Any)
    fallback_case = AST::MatchCase.new(kind: :eq, value: literal_variant, body: [lit(2, type: :Int64)])
    fallback_guard = AST::MatchCase.new(kind: :when, value: guard, body: [lit(3, type: :Int64)])
    fallback_match = AST::MatchStatement.new(tok, union_subject, [fallback_case, fallback_guard], nil, nil, nil, false, nil)
    fallback_match.full_type = :Void
    fallback_result = union_low.lower(fallback_match)
    expect(fallback_result.branches.first.cond.right).to be_a(MIR::EnumTag)
    expect(fallback_result.branches.first.cond.right.variant).to eq("Fallback")

    method_variant = AST::MethodCall.new(tok, id("Result"), "Ok", [])
    variant_case = AST::MatchCase.new(kind: :eq, value: method_variant, body: [])
    expect(low.send(:union_match_case_variants, variant_case)).to eq(["Ok"])

    malformed_return_value = Object.new
    malformed_return_value.define_singleton_method(:full_type) { nil }
    low.define_singleton_method(:current_function_return_payload_zig) { "*Payload" }
    expect(low.send(:return_value_already_payload_pointer?, malformed_return_value)).to eq(false)

    low.function_state.current_bindings = {
      "borrowed" => CleanupEntry.no_cleanup(alloc: :frame, scope: :function),
    }
    expect(low.send(:returned_no_cleanup_binding?, "borrowed")).to eq(true)

    unfinished_sig = FunctionSignature.new(params: [], return_type: Type.new(:Void))
    late_low = MIRLowering.new(input: MIRLoweringInput.new(fn_sigs: { "late" => unfinished_sig }))
    expect {
      late_low.send(:callee_needs_rt?, "late")
    }.to raise_error(/missing finalized needs_rt metadata/)
  end

  it "covers heap-destination OR placement without flattening branch ownership" do
    low = lowering
    left = id("maybe", type: Type.new(:"?String"), storage: :frame)
    right = id("fallback", type: :String, storage: :frame)
    op = AST::BinaryOp.new(tok, left, :OR_RESCUE, right)
    op.full_type = Type.new(:String)

    optional_placed = low.send(:place_string_or_for_heap_destination, MIR::Orelse.new(MIR::Ident.new("maybe"), MIR::Ident.new("fallback")), op)
    expect(optional_placed).to be_a(MIR::DupeSlice)

    fallible_left = id("fallible", type: Type.new(:"!String"), storage: :frame)
    fallible = AST::BinaryOp.new(tok, fallible_left, :OR_RESCUE, right)
    fallible.full_type = Type.new(:String)
    low.define_singleton_method(:heap_owned_result?) { |_mir, ast| ast.equal?(fallible_left) }
    placed = low.send(:place_string_or_for_heap_destination,
      MIR::TryCatch.new(MIR::Ident.new("fallible"), MIR::Ident.new("fallback"), nil),
      fallible)

    expect(placed).to be_a(MIR::TryCatch)
    expect(placed.expr).to be_a(MIR::Ident)
    expect(placed.catch_body).to be_a(MIR::BlockExpr)
    expect(placed.catch_body.body.grep(MIR::Let).first.init).to be_a(MIR::DupeSlice)
  end

  it "covers hoist container-borrow and deep-copy type decisions" do
    low = MIRLowering.new(input: MIRLoweringInput.new(union_schemas: { Result: Schemas::UnionSchema.new(variants: { Ok: :String }) }))
    borrowed = id("borrowed", type: :Result, storage: :heap)
    borrowed.container_borrow = true
    expr = MIR::Ident.new("borrowed")
    captured = nil
    low.define_singleton_method(:hoist_alloc) do |copied, ast_node, err_cleanup: false, **_|
      captured = [copied, ast_node, err_cleanup]
      MIR::Ident.new("__tmp_copy")
    end

    out = low.send(:copy_container_borrow_if_needed, expr, borrowed)
    expect(out.name).to eq("__tmp_copy")
    expect(captured[0]).to be_a(MIR::DeepCopy)
    expect(captured[2]).to eq(true)

    passthrough = low.send(:copy_container_borrow_if_needed, expr, id("plain", type: :String))
    expect(passthrough).to equal(expr)

    explicit = MIR::DeepCopy.new(MIR::Ident.new("x"), "[]const u8", nil, :full_value, :heap)
    expect(low.send(:deep_copy_zig_type, explicit, nil)).to eq("[]const u8")
    inferred_ast = id("owned", type: Type.new(:String, location: :heap))
    inferred = MIR::DeepCopy.new(MIR::Ident.new("owned"), nil, nil, :full_value, :heap)
    expect(low.send(:deep_copy_zig_type, inferred, inferred_ast)).to eq("[]const u8")
  end

  it "covers expression literal, operator, field, and OR edge branches" do
    low = MIRLowering.new(input: MIRLoweringInput.new(union_schemas: { Result: Schemas::UnionSchema.new(variants: { Ok: :String, Done: nil }) }))
    low.define_singleton_method(:emit_builtin) do |name, args|
      sig = FunctionSignature.new(params: [], return_type: Type.new(:String), intrinsic: true)
      MIR::RegistryCall.new(entry: sig, args: args.map { |arg| MIR::RegistryCallArg.new(expr: arg) }, reason: name.to_s)
    end

    nul = AST::Literal.new(tok, :STRING, "a\0b", nil)
    expect(low.send(:lower_literal, nul).value).to eq('"a\x00b"')

    bitwise = AST::UnaryOp.new(tok, :BITWISE_NOT, lit(1, type: :Int64))
    expect(low.send(:lower_unary_op, bitwise).op).to eq("~")
    expect { low.send(:lower_unary_op, AST::UnaryOp.new(tok, :UNKNOWN, lit(1, type: :Int64))) }.to raise_error(/unknown unary op/)

    left_sym = lit("a", type: Type.new(:String, sync: :symbol))
    right_sym = lit("b", type: Type.new(:String, sync: :symbol))
    sym_neq = AST::BinaryOp.new(tok, left_sym, :NEQ, right_sym)
    expect(low.send(:lower_binary_op, sym_neq)).to be_a(MIR::UnaryOp)
    sym_plan = low.send(:binary_operation_plan, sym_neq)
    expect(sym_plan.kind).to eq(:symbol_comparison)

    %i[LT LTE GT GTE].each do |op|
      cmp = AST::BinaryOp.new(tok, lit("a"), op, lit("b"))
      expect(low.send(:lower_binary_op, cmp)).to be_a(MIR::BinOp)
      expect(low.send(:binary_operation_plan, cmp).kind).to eq(:string_comparison)
    end

    unit = AST::GetField.new(tok, id("Result"), "Done")
    unit.full_type = Type.new(:Result)
    result_value = id("result", type: :Result)
    unit_eq = AST::BinaryOp.new(tok, unit, :EQ, result_value)
    lowered_unit_eq = low.send(:lower_binary_op, unit_eq)
    expect(lowered_unit_eq.right).to be_a(MIR::EnumTag)
    expect(lowered_unit_eq.right.variant).to eq("Done")
    expect(low.send(:binary_operation_plan, unit_eq).kind).to eq(:unit_variant_comparison)
    rhs_unit_eq = AST::BinaryOp.new(tok, result_value, :EQ, unit)
    rhs_plan = low.send(:binary_operation_plan, rhs_unit_eq)
    expect(rhs_plan.kind).to eq(:unit_variant_comparison)
    expect(rhs_plan.tag_source).to eq(:left)

    union_eq = AST::BinaryOp.new(tok, result_value, :EQ, id("other", type: :Result))
    expect { low.send(:lower_binary_op, union_eq) }.to raise_error(/BinaryOp EQ on union 'Result'/)
    expect(low.send(:binary_operation_plan, union_eq).kind).to eq(:union_equality_error)

    float_pow = AST::BinaryOp.new(tok, lit(2.0, type: :Float64), :POW, lit(3.0, type: :Float64))
    pow_plan = low.send(:binary_operation_plan, float_pow)
    expect(pow_plan.kind).to eq(:pow)
    expect(pow_plan.type_arg).to eq("f64")
    expect(low.send(:emit_binary_operation_plan, pow_plan).callee).to eq("std.math.pow")

    low.define_singleton_method(:place_value_for_destination) do |_value, *_args|
      MIR::Ident.new("__placed")
    end
    or_rescue = AST::BinaryOp.new(tok, lit("fallback"), :OR_RESCUE, lit("fallback"))
    or_rescue.full_type = Type.new(:String)
    expect(low.send(:string_comparison_operand, MIR::Ident.new("value"), or_rescue).name).to eq("__placed")

    low.define_singleton_method(:pipeline_host) do
      Object.new.tap { |host| host.define_singleton_method(:lower_pipeline) { |_node| nil } }
    end
    smooth = AST::BinaryOp.new(tok, lit(1, type: :Int64), :SMOOTH, AST::WhereOp.new(tok, lit(true, type: :Bool)))
    smooth.full_type = Type.new(:Int64)
    expect { low.send(:lower_complex_smooth, smooth) }.to raise_error(/legacy pipeline fallback has been removed/)

    plan = low.send(:field_access_plan, AST::GetField.new(tok, result_value, "Ok"), MIR::Ident.new("result"))
    expect(plan.value).to be_a(MIR::UnionVariantGet)

    [AST::OrExit.new(tok, :Runtime, nil, nil), AST::OrPass.new(tok), AST::OrBreak.new(tok)].each do |right|
      node = AST::BinaryOp.new(tok, id("plain", type: :Int64), :OR_RESCUE, right)
      node.full_type = Type.new(:Int64)
      expect(low.send(:lower_or_rescue, node)).to be_a(MIR::Ident)
    end

    fallback = AST::BinaryOp.new(tok, id("plain", type: :Int64), :OR_RESCUE, lit(2, type: :Int64))
    fallback.full_type = Type.new(:Int64)
    expect(low.send(:or_fallback_expected_type, fallback).resolved).to eq(:Int64)

    any_fallback = AST::BinaryOp.new(tok, id("any_value", type: :Any), :OR_RESCUE, lit("fallback"))
    any_fallback.full_type = Type.new(:String)
    expect(low.send(:or_fallback_expected_type, any_fallback).resolved).to eq(:String)

    call = AST::FuncCall.new(tok, "fallible", [])
    call.full_type = Type.new(:Any)
    call.error_union_type = :"!String"
    error_fallback = AST::BinaryOp.new(tok, call, :OR_RESCUE, lit("fallback"))
    error_fallback.full_type = Type.new(:String)
    expect(low.send(:or_fallback_expected_type, error_fallback).resolved).to eq(:String)

    ex = AST::OrExit.new(tok, nil, :MvccConflict, nil)
    facts = low.send(:or_exit_facts, ex, 11)
    expect(facts.kind).to eq(AST.kind_of_type(:MvccConflict).to_s)
    expect(facts.name_id).to eq(AST.id_of_type(:MvccConflict))

    string_or = AST::BinaryOp.new(tok, id("left", type: :String), :OR_RESCUE, lit("right"))
    string_or.full_type = Type.new(:String)
    placed_or = low.send(:place_string_or_for_heap_destination,
      MIR::Orelse.new(MIR::Ident.new("left"), MIR::Ident.new("right")),
      string_or)
    expect(placed_or).to be_a(MIR::Orelse)

    pointer_copy = MIR::DeepCopy.new(MIR::Ident.new("source"), "*Payload", nil, :full_value, :heap)
    expect(low.send(:alloc_mark_type_info, pointer_copy, id("owned", type: :String), "ptr").heap_ptr?).to eq(true)
    indirect_info = low.send(:alloc_mark_type_info, pointer_copy, id("value", type: :Int64), "ptr")
    expect(indirect_info.indirect?).to eq(true)

    expect(low.lower(MIR::SuppressCleanup.new(tok, "not_guarded"))).to eq([])
    unknown_node = Class.new(Struct.new(:token)) do
      include AST::Locatable
    end.new(tok)
    expect { low.lower(unknown_node) }.to raise_error(/MIRLowering: unhandled node type/)

    guarded_entry = CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: true)
    expect(low.send(:emitted_guarded_cleanup_for_name?,
      [MIR::Cleanup.new("owned", guarded_entry)], "owned")).to eq(true)

    nested_bg = AST::BgBlock.new(tok, [id("moved", type: :String)], nil, nil, false, false, nil, false)
    nested_bg.body = [AST::MoveNode.new(tok, id("nested_moved", type: :String))]
    expect(low.send(:collect_explicit_move_roots, nested_bg)).to include("nested_moved")

    stream_stmt = AST::BgStreamBlock.new(tok, [], nil, nil)
    expect(low.send(:bg_stream_boundary_stmt?, stream_stmt)).to eq(true)

    call_arg = id("arg", type: :String)
    call_arg.was_moved = true
    call_stmt = AST::FuncCall.new(tok, "consume", [call_arg])
    scanner = low.send(:ownership_scanner)
    expect(scanner.send(:arg_is_call_argument?, call_stmt, call_arg)).to eq(true)
    expect(low.send(:collect_moved_arg_roots, call_stmt)).to eq([])
    facts_low = Class.new(MIRLowering) do
      def stdlib_call_ownership_facts(_call)
        MIRLoweringFunctions::CallOwnershipFacts.new(takes_indices: Set.new, consumed_names: ["arg"])
      end
    end.new
    expect(facts_low.send(:collect_stdlib_consumed_roots, call_stmt)).to eq(["arg"])
    real_call = AST::FuncCall.new(tok, "consume", [id("taken", type: :String)])
    real_call.matched_stdlib_def = FunctionSignature.new(
      params: [param("taken", takes: true)],
      return_type: Type.new(:Void),
    )
    low.function_state.current_bindings = {
      "taken" => CleanupEntry.build(:uniform, alloc: :heap),
    }
    expect(low.send(:stdlib_call_ownership_facts, real_call).takes?(0)).to eq(true)
    expect(scanner.send(:nested_ownership_scope?, stream_stmt)).to eq(true)
    expect(low.send(:consumed_binding_root, AST::GetField.new(tok, id("owner", type: :String), "field"))).to eq("owner")
    expect(low.send(:discard_owned_zig_type, lit(1, type: :Int64), CleanupEntry.build(:uniform, alloc: :heap))).to eq("i64")
    expect(low.send(:root_receiver_node,
      AST::Slice.new(tok, AST::GetIndex.new(tok, id("items", type: :String), lit(0, type: :Int64)), nil, nil)).name).to eq("items")

    bc_or_exit = MIRLowering.new(input: MIRLoweringInput.new(target: :bc)).send(:lower_or_exit, AST::OrExit.new(tok, :Runtime, nil, lit("stop")))
    expect(bc_or_exit.body.first.expr).to be_a(MIR::OrExitBcRewrite)

    type_ast = AST::Program.new(tok, [
      AST::StructDef.new(tok, "PublicType", {}, :pub, nil),
      AST::StructDef.new(tok, "PackageType", {}, nil, nil),
      AST::UnionDef.new(tok, "Choice", { Pair: Schemas::InlineStructVariant.new(fields: {}) }, :pub),
    ])
    type_mod = ModuleImporter::CompiledModule.new(type_ast, nil, nil, nil, nil, nil, nil, nil, nil, [])
    expect(low.send(:visible_imported_type_names, type_mod, same_dir: true)).to include("PublicType", "PackageType", "Choice", "Choice_Pair")
    task_config = MIR::TaskConfigPlan.new(stack_variant: "Standard")
    shared_spawn = low.send(:fiber_spawn_call_plan, "rt", "Ctx", "ctx", task_config, :shared)
    default_spawn = low.send(:fiber_spawn_call_plan, "rt", "Ctx", "ctx", task_config, :unknown)
    expect(MIREmitter.new.send(:emit_fiber_spawn_call, shared_spawn)).to include("spawnPinned")
    expect(MIREmitter.new.send(:emit_fiber_spawn_call, default_spawn)).to include("spawnBest")

    nested_fn = fn([id("inner")])
    names = low.send(:collect_identifier_names, [id("outer"), nested_fn])
    expect(names).to include("outer")
    expect(names).not_to include("inner")

    builtin_bc = MIRLowering.new(input: MIRLoweringInput.new(target: :bc)).send(:emit_builtin, :intAdd, [MIR::Lit.new("1"), MIR::Lit.new("2")])
    expect(builtin_bc).to be_a(MIR::InlineBc)
    expect(low.send(:bare_zig_type, Type.new(:String))).to eq("[]const u8")
    expect(low.send(:try_catch_with_provenance,
      MIR::Ident.new("fallible"),
      MIR::Ident.new("fallback"),
      nil,
      fallback: lit("fallback", type: :String)).result_type.resolved).to eq(:String)
    cleanup_entry = low.send(:pipeline_owned_cleanup_entry, MIR::DupeSlice.new(MIR::Ident.new("s"), :heap), lit("s"))
    expect(cleanup_entry).to be_a(CleanupEntry)
    low.function_state.current_bindings = {
      "owned_value" => CleanupEntry.build(:uniform, alloc: :heap),
    }
    index_insert = MIR::IndexInsert.new(
      MIR::Ident.new("map"),
      MIR::Lit.new("\"k\""),
      MIR::Ident.new("owned_value"),
      "u8",
      "i64",
      :heap,
    )
    owned_insert = low.send(:pipeline_index_insert_with_ownership,
      index_insert, MIR::Ident.new("owned_value"), true, target_alloc: :heap)
    expect(owned_insert.ownership_consumption.operands.first.name).to eq("owned_value")
    expect(low.send(:emit_stmts_zig, [MIR::Ident.new("expr")], indent: "  ")).to eq("  expr;")
  end

  it "covers expression collection, struct, union, and memory edge branches" do
    low = MIRLowering.new(input: MIRLoweringInput.new(struct_schemas: {
      Box: Schemas::StructSchema.new(fields: {
        "value" => AST::StructField.new(type: :T, default: nil, borrowed: false),
      }, type_params: [:T]),
    }, union_schemas: {
      Choice: Schemas::UnionSchema.new(variants: {
        Payload: :String,
        Empty: nil,
      }),
    }))
    low.define_singleton_method(:emit_builtin) do |name, args|
      sig = FunctionSignature.new(params: [], return_type: Type.new(:String), intrinsic: true)
      MIR::RegistryCall.new(entry: sig, args: args.map { |arg| MIR::RegistryCallArg.new(expr: arg) }, reason: name.to_s)
    end
    low.define_singleton_method(:hoist_alloc) do |expr, *_args, **_kwargs|
      expr
    end
    low.define_singleton_method(:with_ownership_consumption) do |node, *_args, **_kwargs|
      node
    end

    unknown_deinit = Schemas::InlineStructDeinitEntry.new(
      field: "value",
      kind: :external,
      zig_type: nil,
      elem_zig_type: nil,
    )
    inline_unknown = Schemas::InlineStructVariant.new(
      fields: { value: :Int64 },
      deinit_entries: [unknown_deinit],
    )
    unknown_union = AST::UnionDef.new(tok, "UnknownCleanup", { Item: inline_unknown }, :pub)
    unknown_nodes = low.lower(unknown_union)
    helper_struct = unknown_nodes.find { |node| node.is_a?(MIR::StructDef) && node.name == "UnknownCleanup_Item" }
    expect(helper_struct.methods).to be_nil

    map_type = Type.new("HashMap<String, String>", shard_count: 4)
    map_ast = id("sharded", type: map_type, storage: :heap)
    plan = MIRLoweringExpressions::IndexAccessPlan.new(
      target: MIR::Ident.new("sharded"),
      index: MIR::Ident.new("key"),
      optional: false,
      optional_source: nil,
      target_ast: map_ast,
      type_info: map_type,
      target_name: "sharded",
      needs_mut_ref: false,
    )
    low.shard_context = { map: "sharded", idx: "__idx", key: "__key" }
    old_shard_template = INDEX_OPS[:string_map][:get][:shard_direct_zig]
    begin
      INDEX_OPS[:string_map][:get][:shard_direct_zig] = "{target}.getDirect({shard_idx}, {shard_alloc}, {shard_key})"
      shard_get = low.send(:index_access_value, plan)
      expect(shard_get).to be_a(MIR::ShardedMapGet)
      expect(shard_get.shard_idx.name).to eq("__idx")
      expect(shard_get.template_kind).to eq(:shard_direct_zig)
      expect(shard_get.resolved_allocs.shard_alloc).to be_nil
    ensure
      INDEX_OPS[:string_map][:get][:shard_direct_zig] = old_shard_template
    end

    old_get = INDEX_OPS[:string_map][:get]
    begin
      INDEX_OPS[:string_map][:get] = nil
      expect {
        low.send(:index_access_value, plan)
      }.to raise_error(RuntimeError, /indexed access: missing registry signature for string_map/)
    ensure
      INDEX_OPS[:string_map][:get] = old_get
    end

    set_type = Type.new(:"Int64[]", collection: :set)
    set_plan = MIRLoweringExpressions::IndexAccessPlan.new(
      target: MIR::Ident.new("set"),
      index: MIR::Ident.new("item"),
      optional: false,
      optional_source: nil,
      target_ast: id("set", type: set_type),
      type_info: set_type,
      target_name: nil,
      needs_mut_ref: false,
    )
    expect(low.send(:index_collection_value, MIR::Ident.new("set"), MIR::Ident.new("item"), set_plan)).to be_a(MIR::RegistryCall)

    blank_schema = Schemas::StructSchema.new(fields: {}, type_params: [])
    expect(low.send(:struct_lit_field_types, AST::StructLit.new(tok, "Missing", {}, nil, []))).to eq({})
    low.replace_mir_schema_lookup!(->(_name) { blank_schema })
    expect(low.send(:struct_lit_field_types, AST::StructLit.new(tok, "Blank", {}, nil, []))).to eq({})

    low = MIRLowering.new(input: MIRLoweringInput.new(struct_schemas: {
      Box: Schemas::StructSchema.new(fields: {
        "value" => AST::StructField.new(type: :T, default: nil, borrowed: false),
      }, type_params: [:T]),
    }, union_schemas: {
      Choice: Schemas::UnionSchema.new(variants: { Payload: :String }),
    }))
    low.define_singleton_method(:emit_builtin) do |name, args|
      sig = FunctionSignature.new(params: [], return_type: Type.new(:String), intrinsic: true)
      MIR::RegistryCall.new(entry: sig, args: args.map { |arg| MIR::RegistryCallArg.new(expr: arg) }, reason: name.to_s)
    end
    low.define_singleton_method(:lower) do |node|
      node.respond_to?(:name) ? MIR::Ident.new(node.name.to_s) : MIR::Ident.new("value")
    end
    low.define_singleton_method(:hoist_alloc) { |expr, *_args, **_kwargs| expr }
    low.define_singleton_method(:with_ownership_consumption) { |node, *_args, **_kwargs| node }
    low.define_singleton_method(:with_ownership_consumption_for_value) { |node, *_args, **_kwargs| node }
    low.define_singleton_method(:move_mark_field!) { |_node| nil }
    low.define_singleton_method(:rc_retain_needed?) { |_node| false }
    low.define_singleton_method(:mir_owned_alloc) { |_node| :frame }

    generic = AST::StructLit.new(tok, "Box", { "value" => lit("s") }, :heap, [:String])
    generic.full_type = Type.new(:Box)
    field_types = low.send(:struct_lit_field_types, generic)
    expect(field_types["value"].resolved).to eq(:String)

    list_type = Type.new(:"Int64[]", collection: :list)
    low.replace_mir_schema_lookup!(->(name) {
      next nil unless name == :Box

      Schemas::StructSchema.new(fields: {
        "value" => AST::StructField.new(type: list_type, default: nil, borrowed: false),
      })
    })
    collection_copy = AST::CopyNode.new(tok, id("items", type: list_type))
    collection_copy.full_type = list_type
    aggregate = AST::StructLit.new(tok, "Box", { "value" => collection_copy }, :heap, [])
    aggregate.full_type = Type.new(:Box)
    lowered_aggregate = low.send(:lower_struct_lit, aggregate)
    expect(lowered_aggregate.fields.first[:value]).to be_a(MIR::DeepCopy)

    recursive_type = Type.new(:NeedsCopy)
    low.replace_mir_schema_lookup!(->(name) {
      next nil unless name == :Box

      Schemas::StructSchema.new(fields: {
        "value" => AST::StructField.new(type: recursive_type, default: nil, borrowed: false),
      })
    })
    field_node = id("nested", type: recursive_type, storage: :frame)
    recursive_lit = AST::StructLit.new(tok, "Box", { "value" => field_node }, :heap, [])
    recursive_lit.full_type = Type.new(:Box)
    low.define_singleton_method(:recursive_field_copy_required?) { |_ft, _node, _field_alloc, _sink_alloc| true }
    recursive_lowered = low.send(:lower_struct_lit, recursive_lit)
    expect(recursive_lowered.fields.first[:value]).to be_a(MIR::DeepCopy)

    indirect_value = id("indirect", type: :IndirectPayload, storage: :frame)
    indirect_value.needs_heap_create = true
    indirect_lit = AST::StructLit.new(tok, "Box", { "value" => indirect_value }, :heap, [])
    indirect_lit.full_type = Type.new(:Box)
    low.define_singleton_method(:recursive_field_copy_required?) { |_ft, _node, _field_alloc, _sink_alloc| false }
    indirect_lowered = low.send(:lower_struct_lit, indirect_lit)
    expect(indirect_lowered).to be_a(MIR::BlockExpr)
    expect(indirect_lowered.body).to include(an_instance_of(MIR::AllocMark), an_instance_of(MIR::BreakStmt))

    single_payload = AST::UnionVariantLit.new(tok, "Choice", "Payload", { "value" => lit("s") }, :heap)
    expect(low.send(:union_variant_lit_field_types, single_payload)["value"].resolved).to eq(:String)
    multi_payload = AST::UnionVariantLit.new(tok, "Choice", "Payload", { "a" => lit("s"), "b" => lit("t") }, :heap)
    expect(low.send(:union_variant_lit_field_types, multi_payload)).to eq({})
    unknown_payload = AST::UnionVariantLit.new(tok, "Choice", "Missing", {}, :heap)
    expect(low.send(:union_variant_lit_field_types, unknown_payload)).to eq({})

    malformed_array_type = Type.new(:"Int64[]")
    def malformed_array_type.element_type = raise "bad element type"
    expect(low.send(:slice_element_zig_type, malformed_array_type)).to be_nil

    rc_type = Type.new(:Payload, ownership: :shared)
    expect(low.send(:lower_copy, AST::CopyNode.new(tok, id("rc", type: rc_type, storage: :heap)))).to be_a(MIR::RcRetain)
    opt_type = Type.new(:"?String", location: :heap)
    expect(low.send(:lower_copy, AST::CopyNode.new(tok, id("opt", type: opt_type, storage: :heap)))).to be_a(MIR::DeepCopy)
    list_type = Type.new(:"Int64[]", collection: :list)
    low.function_state.current_expected_type = list_type
    expect(low.send(:lower_copy, AST::CopyNode.new(tok, id("list", type: list_type, storage: :heap))).zig_type).to eq(list_type.zig_type)
    scalar_copy = AST::CopyNode.new(tok, id("scalar", type: :Int64, storage: :frame))
    expect(low.send(:lower_copy, scalar_copy).zig_type).to eq(list_type.zig_type)

    sym_source = id("sym_source", type: :Untyped, storage: :heap)
    sym_source.symbol.type = Type.new(:String)
    expect(low.send(:copy_source_type_info, sym_source).resolved).to eq(:String)
    fallback_source = Object.new
    fallback_source.define_singleton_method(:full_type) { Type.new(:Bool) }
    expect(low.send(:copy_source_type_info, fallback_source).resolved).to eq(:Bool)

    expect { low.send(:lower_clone, AST::CloneNode.new(tok, id("plain", type: :String))) }.to raise_error(/unsupported type/)
    moved_field = AST::MoveNode.new(tok, AST::GetField.new(tok, id("root", type: :Box), "value"))
    expect(low.send(:lower_move, moved_field)).to be_a(MIR::Ident)

    cap = AST::CapabilityWrap.new(tok, id("plain", type: :Int64), nil, nil, nil)
    cap.full_type = Type.new(:Int64)
    expect(low.send(:lower_cap_wrap, cap).strategy).to eq(:passthrough)
  end

  it "covers extracted MIR lowering state-owner helper branches" do
    low = lowering

    old_pointer_captures = Set["old"]
    old_pending = [MIR::ExprStmt.new(MIR::Ident.new("keep"), false)]
    low.capture_state.current_bg_pointer_captures = old_pointer_captures
    low.function_state.pending_stmts = old_pending
    seen_pointer_captures = nil
    seen_pending = nil
    low.define_singleton_method(:lower_finalized_fsm_step_mir) do |_body, no_result: false|
      seen_pointer_captures = capture_state.current_bg_pointer_captures
      seen_pending = function_state.pending_stmts
      no_result ?
        [MIR::ExprStmt.new(MIR::Lit.new("handled_block()"), false)] :
        [MIR::ExprStmt.new(MIR::Lit.new("handled_expr()"), false)]
    end
    low.define_singleton_method(:with_fiber_capture_map) { |_map, rt_override: nil, &blk| blk.call }
    block_clause = AST::ErrorClause.new(selectors: [], action: :block, retries: nil, token: tok,
      body: [AST::PassStmt.new(tok)])
    with_node = AST::WithBlock.new(tok, [], [], nil)
    split = low.send(:emit_fsm_lock_error_arm_split,
      clause: block_clause,
      ctx_id: 4,
      with_node: with_node,
      capture_map: { "cap" => "__ctx_4.cap" },
      pointer_captures: Set["fresh"],
      bg_rt: "__rt_bg")

    expect(split.exit_kind).to eq(:goto_post)
    expect(split.body_stmts.length).to eq(1)
    expect(split.body_stmts.first).to be_a(MIR::ExprStmt)
    expect(MIREmitter.new.emit(split.body_stmts.first)).to eq("handled_block();")
    expect(seen_pointer_captures).to eq(Set["fresh"])
    expect(seen_pending).to eq([])
    expect(low.capture_state.current_bg_pointer_captures).to eq(old_pointer_captures)
    expect(low.function_state.pending_stmts).to eq(old_pending)

    versioned_prelude = MIREmitter.new.send(
      :emit_with_match_prelude,
      MIR::WithMatchArm.new(family: :VERSIONED, guard_var: "__guard", body: []),
      "cell",
      "alias",
      "rt",
      false,
    )
    expect(versioned_prelude).to include(".read(").and include("const alias")

    guard_exit_clause = AST::ErrorClause.new(selectors: [], action: :exit, retries: nil, token: tok,
      message: lit("guard timeout"))
    guard_exit_clause.matched_types = [:GuardFail]
    with_node.lock_error_clause = guard_exit_clause
    guard_exit_body = low.send(:guard_fail_flow_body, with_node)
    expect(guard_exit_body).to include(
      an_instance_of(MIR::ExprStmt),
      an_instance_of(MIR::PolymorphicFlowSignal),
    )
    expect(guard_exit_body.first.expr.args[2]).to eq(low.lower(guard_exit_clause.message))

    exit_clause = AST::ErrorClause.new(selectors: [], action: :exit, retries: nil, token: tok,
      message: lit("timeout"))
    exit_body = low.send(:error_action_stmts, exit_clause, "__with", with_node, :GuardFail, "guard failed")
    expect(exit_body).to contain_exactly(an_instance_of(MIR::ExprStmt), an_instance_of(MIR::ReturnStmt))

    block_body = low.send(:error_action_stmts, block_clause, "__with", with_node, :GuardFail, "guard failed")
    expect(block_body).to include(an_instance_of(MIR::Noop), an_instance_of(MIR::BreakStmt))

    unknown_clause = AST::ErrorClause.new(selectors: [], action: :unknown, retries: nil, token: tok)
    expect {
      low.send(:error_action_stmts, unknown_clause, "__with", with_node, :GuardFail, "guard failed")
    }.to raise_error(/unknown lock action/)

    observable_source = id("running", type: Type.new(:"~String", observable: true))
    next_node = AST::NextExpr.new(tok, observable_source)
    next_node.full_type = Type.new(:String)
    lowered_next = low.send(:lower_next_expr, next_node, :frame)
    expect(lowered_next).to be_a(MIR::BlockExpr)
    expect(lowered_next.label).to start_with("__obs_next_string_")
    expect(lowered_next.body).to include(an_instance_of(MIR::ExprStmt), an_instance_of(MIR::BreakStmt))

    pool_type = Type.new(:"Int64[]", collection: :pool)
    pool_plan = MIRLoweringControlFlow::ForEachPlan.new(
      var: "item",
      body: [MIR::ExprStmt.new(MIR::Ident.new("use_item"), false)],
      rt: MIR::Ident.new("rt"),
      collection: MIR::Ident.new("pool"),
      collection_type: pool_type,
      collection_setup: [],
      mutable: false,
      mark_per_iter: nil,
      tight: false,
    )
    pool_loop = low.send(:for_each_loop_stmt, AST::ForEach.new(tok, "item", id("pool", type: pool_type), [], nil, false), pool_plan)
    expect(pool_loop).to be_a(MIR::ForStmt)
    expect(pool_loop.capture).to match(/\*__pslot_\d+/)
    expect(pool_loop.body.first).to be_a(MIR::IfStmt)
    expect(low.send(:for_each_owned_collection_source_alloc, MIR::Ident.new("items"), Type.new(:String))).to be_a(Symbol)

    default_low = lowering
    default_low.define_singleton_method(:lower_match_branch) do |_body, _label|
      [MIR::ExprStmt.new(MIR::Ident.new("default"), false)]
    end
    default_low.define_singleton_method(:hoist_unhoisted_return_allocs) { |body, _body_ast| body }
    default_body = default_low.send(:lower_match_default_body, [AST::PassStmt.new(tok)], "__match")
    expect(default_body.first).to be_a(MIR::ExprStmt)

    fallback_access = AST::GetField.new(tok, id("owner", type: :Box, storage: :heap), "name")
    fallback_access.full_type = Type.new(:String)
    low.function_state.current_decl_alloc = :frame
    materialized = low.send(:materialize_or_fallback_value, MIR::Ident.new("owner.name"), fallback_access)
    expect(materialized).to be_a(MIR::Ident)
    expect(low.function_state.pending_stmts).to include(an_instance_of(MIR::AllocMark))

    heap_trampoline = MIR::ExternTrampoline.new(
      id: 91,
      callee_name: "native",
      module_alias: nil,
      comptime_args: [],
      runtime_args: [],
      alloc_kind: :heap,
      return_type: Type.new(:Void),
      stdlib_def: FunctionSignature.intrinsic_contract(return_type: Type.new(:Void)),
    )
    frame_trampoline = MIR::ExternTrampoline.new(
      id: 92,
      callee_name: "native",
      module_alias: nil,
      comptime_args: [],
      runtime_args: [],
      alloc_kind: :frame,
      return_type: Type.new(:Void),
      stdlib_def: FunctionSignature.intrinsic_contract(return_type: Type.new(:Void)),
    )
    emitter = MIREmitter.new
    expect(emitter.emit(heap_trampoline)).to include(".alloc = rt.heapAlloc()")
    expect(emitter.emit(frame_trampoline)).to include(".alloc = rt.frameAlloc()")
  end

  it "covers function lowering helper edge branches" do
    legacy_ownership = MIRLoweringFunctions::CallOwnershipFacts.new(
      takes_indices: Set[0],
      consumed_names: ["owned"],
    )
    expect(legacy_ownership.operands.first.name).to eq("owned")

    stdlib_facts = MIRLoweringFunctions::StdlibCallFacts.new(
      args: [],
      ownership: legacy_ownership,
    )
    expect(stdlib_facts.takes?(0)).to eq(false)

    frame_ret = Type.new(:FrameBox, location: :frame)
    frame_fn = fn([], return_type: frame_ret)
    frame_fn.needs_rt = false
    frame_fn.can_fail = false
    lowered_frame_fn = lowering.send(:lower_function_def, frame_fn)
    expect(lowered_frame_fn).to be_a(MIR::FnDef)
    expect(lowered_frame_fn.ret_type).to eq("FrameBox")

    expect {
      lowering.send(:finalized_needs_rt!, fn([]))
    }.to raise_error(/missing finalized needs_rt metadata/)

    post_low = lowering
    post_low.define_singleton_method(:emit_expr) { |_mir| "inner()" }
    post_low.define_singleton_method(:emit_stmts_zig) { |_stmts, **_kwargs| "checks();" }
    post_fn = fn([], return_type: :Void)
    outer = post_low.send(:build_post_outer_fn, post_fn, [], "void", false, :private, [])
    expect(outer.body.first).to be_a(MIR::ExprStmt)
    expect(outer.body.any? { |node| node.is_a?(MIR::DebugOnly) }).to eq(false)

    borrowed_arg = AST::GetField.new(tok, id("owner", type: :Box), "field")
    borrowed_arg.full_type = Type.new(:String)
    takes_param = param("value", type: :String, takes: true)
    call_sig = FunctionSignature.new(params: [takes_param], return_type: Type.new(:Void))
    contract = lowering.send(:callable_contract_for_lowered_args, call_sig, [borrowed_arg], [MIR::Ident.new("owner_field")])
    expect(contract.ownership_contract.operands.first.borrowed).to eq(true)

    mismatch_sig = FunctionSignature.new(params: [param("a"), param("b")], return_type: Type.new(:Void), arg_spec: [:a, :b])
    mismatch_call = AST::FuncCall.new(tok, "badIntrinsic", [lit(1, type: :Int64)])
    mismatch_call.matched_stdlib_def = mismatch_sig
    expect {
      lowering.send(:stdlib_call_facts, mismatch_call)
    }.to raise_error(/signature has 2 params for 1 args/)

    method_sig = FunctionSignature.new(
      params: [param("self", type: :Counter)],
      return_type: Type.new(:Int64),
      needs_rt: false,
      can_fail: false
    )
    method_low = MIRLowering.new(input: MIRLoweringInput.new(fn_sigs: { "get" => method_sig }))
    method_call = AST::MethodCall.new(tok, id("counter", type: :Counter), "get", [])
    method_call.full_type = Type.new(:Int64)
    method_call.generic_type_args = [:String]
    method_result = method_low.send(:lower_method_call, method_call)
    expect(method_result.args.first.name).to eq("[]const u8")

    any_call = AST::FuncCall.new(tok, "returns_from_arg", [id("source", type: :Int64)])
    any_call.full_type = Type.new(:Any)
    carry_sig = FunctionSignature.new(params: [param("source", type: :Int64)], return_type: Type.new(:String))
    expect(method_low.send(:call_owned_return?, any_call)).to eq(false)
    method_low.send(:program_state).fn_sigs = { "returns_from_arg" => carry_sig }
    expect(method_low.send(:call_owned_return?, any_call)).to eq(false)

    carry_sig_with_source = FunctionSignature.new(
      params: [param("source", type: :Int64)],
      return_type: Type.new(:String),
      heap_carry_return_vars: Set["source"]
    )
    expect(method_low.send(:call_owned_return_from_args?, any_call, carry_sig_with_source)).to eq(true)
    carry_int_sig = FunctionSignature.new(
      params: [param("source", type: :Int64)],
      return_type: Type.new(:Int64),
      heap_carry_return_vars: Set["source"]
    )
    expect(method_low.send(:call_owned_return_from_args?, any_call, carry_int_sig)).to eq(false)

    nested_if = Struct.new(:then_body, :else_body).new([], [AST::ReturnNode.new(tok, lit(1, type: :Int64))])
    expect(method_low.send(:function_body_has_value_return?, [nested_if])).to eq(true)

    macro_map = AST::FuncCall.new(tok, "map", [])
    macro_map.zig_pattern = :macro_map
    expect { method_low.send(:lower_intrinsic, macro_map) }.to raise_error(/macro_map/)
    unknown_intrinsic = AST::FuncCall.new(tok, "mystery", [])
    unknown_intrinsic.zig_pattern = :mystery
    expect { method_low.send(:lower_intrinsic, unknown_intrinsic) }.to raise_error(/unhandled symbol intrinsic/)

    intrinsic_low = lowering
    intrinsic_low.define_singleton_method(:lower) { |node| node.respond_to?(:name) ? MIR::Ident.new(node.name.to_s) : MIR::Ident.new("arg") }
    intrinsic_low.define_singleton_method(:emit_expr) { |node| node.respond_to?(:name) ? node.name : "arg" }
    intrinsic_low.define_singleton_method(:stdlib_call_facts) do |_node|
      MIRLoweringFunctions::StdlibCallFacts.new(
        args: [],
        ownership: MIRLoweringFunctions::CallOwnershipFacts.new(takes_indices: Set[0], consumed_names: []),
      )
    end
    intrinsic_low.define_singleton_method(:materialize_stdlib_arguments) do |mir_args, _stdlib, _ownership, _sink, _val_alloc|
      MIRLoweringFunctions::StdlibArgumentMaterialization.new(
        mir_args: mir_args,
        consumed_names: ["taken"],
        consumed_operands: [],
        val_alloc_placeholder: nil,
      )
    end
    intrinsic = AST::FuncCall.new(tok, "consume", [id("taken", type: :String, storage: :heap)])
    intrinsic.zig_pattern = "consume({0})"
    intrinsic.full_type = Type.new(:Void)
    intrinsic.matched_stdlib_def = FunctionSignature.intrinsic_contract(return_type: Type.new(:Void))
    intrinsic_out = intrinsic_low.send(:lower_intrinsic, intrinsic)
    expect(intrinsic_out.ownership_contract.operands.first.name).to eq("taken")

    extern_low = lowering
    type_arg = id("T", type: :Type)
    value_arg = id("value", type: :Int64)
    extern_call = AST::FuncCall.new(tok, "native", [type_arg, value_arg])
    extern_call.extern_effects = { alloc: :heap }
    extern_call.module_alias = "c.lib"
    direct = extern_low.send(:lower_extern_direct_call, extern_call)
    expect(direct.args[1]).to be_a(MIR::MethodCall)
    expect(direct.callee).to eq("c_lib.native")

    trampoline_sig = FunctionSignature.new(params: [param("value", type: :Int64)], return_type: Type.new(:Int64))
    extern_low.send(:program_state).fn_sigs = { "native" => trampoline_sig }
    trampoline = AST::FuncCall.new(tok, "native", [value_arg])
    trampoline.full_type = Type.new(:Int64)
    trampoline_out = extern_low.send(:build_extern_trampoline_call, trampoline)
    expect(trampoline_out).to be_a(MIR::ExternTrampoline)
    expect(MIREmitter.new.emit(trampoline_out)).to include("a0: i64")

    module_sig = FunctionSignature.new(params: [param("port", type: :Int64)], return_type: Type.new(:Void), module_alias: "http")
    extern_low.send(:program_state).fn_sigs = { "startTestServer" => module_sig }
    module_call = AST::FuncCall.new(tok, "startTestServer", [lit(19_876, type: :Int64)])
    module_call.full_type = Type.new(:Void)
    module_call.module_alias = "http"
    module_out = extern_low.send(:build_extern_trampoline_call, module_call)
    expect(module_out).to be_a(MIR::ExternTrampoline)
    expect(MIREmitter.new.emit(module_out)).to include("a0: i64")

    lambda_sig = FunctionSignature.new(params: [], return_type: Type.new(:Int64))
    lambda_node = AST::LambdaLit.new(tok, [], ["raw_capture"], lit(1, type: :Int64), nil, nil)
    lambda_node.full_type = Type.new(lambda_sig)
    lambda_out = lowering.send(:lower_lambda, lambda_node)
    expect(lambda_out.captures).to eq(["raw_capture"])
  end

  it "covers literal lowering edge branches" do
    list_low = lowering
    list_type = Type.new(:"Box[]", collection: :list)
    elem_type = Type.new(:Box)
    list_low.define_singleton_method(:list_literal_plan) do |_node|
      MIRLoweringLiterals::ListLiteralPlan.new(
        type_info: list_type,
        alloc: :heap,
        element_type: elem_type,
        element_zig: "Box",
        element_needs_owned_storage: true,
      )
    end
    list_low.define_singleton_method(:lower) { |_node| MIR::Ident.new("item") }
    list_low.define_singleton_method(:place_value_for_destination) { |value, *_args| value }
    list_low.define_singleton_method(:materialize_owned_sink_value) { |value, *_args| value }
    list_low.define_singleton_method(:mir_owned_alloc) { |_value| :frame }
    list_low.define_singleton_method(:ast_expr_produces_heap?) { |_node| false }
    list_low.define_singleton_method(:hoist_alloc) { |value, *_args, **_kwargs| value }
    list_low.define_singleton_method(:with_ownership_consumption) { |node, *_args, **_kwargs| node }
    list_node = AST::ListLit.new(tok, [id("box", type: :Box)], :heap)
    list_node.full_type = list_type
    list_result = list_low.send(:lower_list_lit, list_node)
    expect(list_result.items.first).to be_a(MIR::DeepCopy)

    hash_low = lowering
    hash_low.define_singleton_method(:with_ownership_consumption) { |node, *_args, **_kwargs| node }

    striped_string = Type.new("HashMap<Int64>", ownership: :shared, sync: :locked, shard_count: 4)
    nonempty_striped = AST::HashLit.new(tok, { lit("k") => lit(1, type: :Int64) }, :heap)
    nonempty_striped.full_type = striped_string
    nonempty_striped_result = hash_low.send(:lower_hash_lit, nonempty_striped)
    striped_wrapped = nonempty_striped_result.body.grep(MIR::Let).find { |stmt| stmt.name == "__hm_wrapped" }
    expect(striped_wrapped.init).to be_a(MIR::CapWrap)

    striped_numeric = Type.new("HashMap<Int64, Int64>", ownership: :shared, sync: :locked, shard_count: 4)
    empty_striped = AST::HashLit.new(tok, {}, :heap)
    empty_striped.full_type = striped_numeric
    empty_striped_result = hash_low.send(:lower_hash_lit, empty_striped)
    expect(empty_striped_result).to be_a(MIR::CapWrap)
    expect(empty_striped_result.inner.fields).to eq([])

    shared_numeric = Type.new("HashMap<Int64, Int64>", ownership: :shared)
    empty_shared = AST::HashLit.new(tok, {}, :heap)
    empty_shared.full_type = shared_numeric
    empty_shared_result = hash_low.send(:lower_hash_lit, empty_shared)
    expect(empty_shared_result).to be_a(MIR::CapWrap)
    expect(empty_shared_result.inner.fields).to eq([])

    nonempty_shared = AST::HashLit.new(tok, { lit(1, type: :Int64) => lit(2, type: :Int64) }, :heap)
    nonempty_shared.full_type = shared_numeric
    nonempty_result = hash_low.send(:lower_hash_lit, nonempty_shared)
    expect(nonempty_result).to be_a(MIR::BlockExpr)
    wrapped_let = nonempty_result.body.grep(MIR::Let).find { |stmt| stmt.name == "__hm_wrapped" }
    expect(wrapped_let.init).to be_a(MIR::CapWrap)
    expect(wrapped_let.init.inner.name).to eq("__hm")
    expect(nonempty_result.body.last.value.name).to eq("__hm_wrapped")

    scalar_typed_list = AST::ListLit.new(tok, [], :heap)
    scalar_typed_list.full_type = Type.new(:Int64)
    scalar_plan = lowering.send(:list_literal_plan, scalar_typed_list)
    expect(scalar_plan.element_type).to be_nil
    expect(scalar_plan.element_zig).to eq("u8")

    bounded_stream = AST::ListLit.new(tok, [lit(1, type: :Int64), lit(2, type: :Int64)], :heap)
    bounded_stream.full_type = Type.new(:"~Int64[2]")
    bc_stream = MIRLowering.new(input: MIRLoweringInput.new(target: :bc)).send(:lower_list_lit, bounded_stream)
    expect(bc_stream).to be_a(MIR::MakeList)
    expect(bc_stream.elem_type).to eq("__bc_stream__")
    expect(bc_stream.alloc).to eq(:frame)
  end

  it "covers variable lowering edge branches" do
    facts_for = lambda do |ft:, binding_entry: CleanupEntry::NONE, heap_return_var: false, decl_alloc: :heap, generic_id: false, has_mir_drop: false, source_owned_binding: false|
      MIRLoweringVariables::VarDeclFacts.new(
        ft: ft,
        binding_entry: binding_entry,
        has_mir_drop: has_mir_drop,
        actually_mutated: false,
        forced_var: false,
        keyword_mutable: false,
        annotation: nil,
        heap_return_var: heap_return_var,
        decl_alloc: decl_alloc,
        init_ownership_effect: MIR::OwnershipEffect.none,
        source_owned_binding: source_owned_binding,
        has_caps: false,
        bare_zig: ft.bare_data_type.zig_type,
        generic_id: generic_id,
      )
    end

    decl = AST::VarDecl.new(tok, "owned", nil, lit(1, type: :Int64), false)
    decl.full_type = Type.new(:Int64)
    decl.symbol = SymbolEntry.new(reg: "owned", type: Type.new(:Int64), mutable: false, storage: :frame)

    low = lowering
    placement = low.send(:binding_placement_fact, decl, Type.new(:Int64), CleanupEntry::NONE, true, false)
    expect(placement.alloc).to eq(:frame)

    inner = MIR::Ident.new("inner")
    expect(low.send(:compose_capability_wrap, inner, "Counter", Type.new(:Counter, sync: :locked), :heap).strategy).to eq(:sync_only)
    expect(low.send(:compose_capability_wrap, inner, "Counter", Type.new(:Counter, ownership: :shared), :heap).strategy).to eq(:own_only)
    expect(low.send(:compose_capability_wrap, inner, "Counter", Type.new(:Counter), :heap)).to be(inner)

    frame_sig = FunctionSignature.new(params: [], return_type: Type.new(:String), intrinsic: true, emit: IntrinsicEmit.new(allocates: true))
    inline = registry_call("edge", frame_sig, allocs: MIR.inline_alloc_metadata(alloc: :frame))
    low.send(:stamp_var_decl_init_target!, inline, "owned", :heap)
    expect(inline.target_var).to eq("owned")
    expect(inline.allocs.primary).to eq(:heap)

    allocating_sig = FunctionSignature.new(params: [], return_type: Type.new(:String), emit: IntrinsicEmit.new(allocates: true))
    transfer_init = registry_call("edge", allocating_sig, allocs: MIR.inline_alloc_metadata(alloc: :heap))
    transfer_entry = CleanupEntry.no_cleanup(alloc: :heap, scope: :heap)
    transfer_let = MIR::Let.new("owned", transfer_init, false, Type.new(:String), nil)
    packet = low.send(
      :var_decl_materialization_plan,
      decl,
      facts_for.call(ft: Type.new(:String), binding_entry: transfer_entry, decl_alloc: :heap),
      "owned",
      transfer_init,
      transfer_let,
    )
    expect(packet.statements.map(&:class)).to eq([MIR::AllocMark, MIR::Let])

    source_low = lowering
    source_low.function_state.current_bindings = {
      "src" => CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: true),
    }
    source_low.define_singleton_method(:lower) { |node| MIR::Ident.new(node.name.to_s) }
    source_low.define_singleton_method(:with_ownership_consumption_for_value) { |node, *_args, **_kwargs| node }
    source_decl = AST::VarDecl.new(tok, "dst", nil, id("src", type: Type.new(:Payload, ownership: :shared), storage: :heap), false)
    source_decl.full_type = Type.new(:Int64)
    source_decl.symbol = SymbolEntry.new(reg: "dst", type: Type.new(:Int64), mutable: false, storage: :frame)
    source_facts = facts_for.call(ft: Type.new(:Payload), source_owned_binding: true)
    expect(source_low.send(:var_decl_source_transfer_required?, source_decl, source_facts, MIR::OwnershipEffect.none)).to eq(true)
    expect(source_low.send(:var_decl_source_transfer_required?, source_decl, source_facts, MIR::OwnershipEffect.owned(alloc: :heap))).to eq(true)
    source_decl.container_borrow = true
    expect(source_low.send(:var_decl_source_transfer_required?, source_decl, source_facts, MIR::OwnershipEffect.none)).to eq(false)
    source_decl.container_borrow = false
    source_decl.symbol = SymbolEntry.new(reg: "dst", type: Type.new(:Int64), mutable: false, storage: :borrow)
    expect(source_low.send(:var_decl_source_borrowed?, source_decl)).to eq(true)
    source_decl.symbol = SymbolEntry.new(reg: "dst", type: Type.new(:Int64), mutable: false, storage: :frame)
    expect(source_low.send(:var_decl_source_transfer_required?, source_decl, facts_for.call(ft: Type.new(:Payload)), MIR::OwnershipEffect.owned(alloc: :heap))).to eq(false)
    source_nodes = source_low.send(:lower_var_decl, source_decl)
    expect(source_nodes).to include(a_kind_of(MIR::Let))

    cleanup_facts = facts_for.call(ft: Type.new(:String), decl_alloc: :heap, has_mir_drop: true)
    moved_string = id("moved_string", type: :String, storage: :heap)
    moved_string.was_moved = true
    expect(low.send(:ensure_cleanup_binding_owns_string_init, MIR::Ident.new("moved_string"), cleanup_facts, moved_string)).to be_a(MIR::Ident)
    expect(low.send(:ensure_cleanup_binding_owns_string_init, MIR::Ident.new("borrowed_string"), cleanup_facts, lit("s"))).to be_a(MIR::DupeSlice)

    list_copy_low = lowering
    list_copy_low.define_singleton_method(:lower) { |node| MIR::Ident.new(node.name.to_s) }
    copied_list_type = Type.new(:"Box[]", collection: :list)
    copied_source = id("copied_source", type: copied_list_type, storage: :heap)
    copied_value = AST::CopyNode.new(tok, copied_source)
    copied_value.full_type = copied_list_type
    copied_decl = AST::VarDecl.new(tok, "copied", nil, copied_value, false)
    copied_decl.full_type = copied_list_type
    copied = list_copy_low.send(:lower_var_decl_init, copied_decl, copied_list_type, copied_list_type.bare_data_type.zig_type, false, :heap)
    expect(copied).to be_a(MIR::DeepCopy)

    owner_mark_low = lowering
    owner_mark_low.function_state.current_bindings = {
      "root" => CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: true),
    }
    root = id("root", type: :Box, storage: :heap)
    moved_field = AST::GetField.new(tok, root, "child")
    moved_field.full_type = Type.new(:Payload)
    moved_field.indirect_field = true
    field_move_decl = AST::VarDecl.new(tok, "child", nil, moved_field, false)
    field_move_decl.full_type = Type.new(:Payload)
    marks = owner_mark_low.send(:field_owner_move_marks, field_move_decl)
    expect(marks.map(&:class)).to eq([MIR::TransferMark, MIR::MoveMark])

    heap_reassign_low = lowering
    heap_reassign_low.define_singleton_method(:current_function_heap_carry_return_var?) { |name| name == "ret" }
    heap_reassign_low.define_singleton_method(:lower) { |_node| MIR::Ident.new("next_value") }
    heap_reassign_low.define_singleton_method(:place_value_for_destination) { |value, *_args| value }
    heap_reassign_low.define_singleton_method(:copy_container_borrow_if_needed) { |value, *_args| value }
    heap_reassign_low.define_singleton_method(:stamp_allocating_result_target!) { |_value, *_args, **_kwargs| nil }
    heap_reassign_low.define_singleton_method(:mir_allocates?) { |_value| false }
    heap_reassign_low.define_singleton_method(:with_ownership_consumption_for_value) { |node, *_args, **_kwargs| node }
    reassign = AST::BindExpr.new(tok, "ret", nil, id("next_value", type: :String, storage: :heap))
    reassign.mode = :assign
    reassign.full_type = Type.new(:String)
    reassign_result = heap_reassign_low.send(:lower_bind_expr, reassign)
    expect(reassign_result).to be_a(MIR::ReassignWithCleanup)
    expect(reassign_result.zig_type).to eq("[]const u8")
    expect(reassign_result.alloc).to eq(:heap)

    field_low = lowering
    field_low.define_singleton_method(:lower) do |node|
      case node
      when AST::GetField
        MIR::FieldGet.new(MIR::Ident.new(node.target.name.to_s), node.field.to_s)
      when AST::Identifier
        MIR::Ident.new(node.name.to_s)
      else
        MIR::Ident.new("value")
      end
    end
    field_low.define_singleton_method(:copy_container_borrow_if_needed) { |value, *_args| value }
    field_low.define_singleton_method(:with_ownership_consumption_for_value) { |node, *_args, **_kwargs| node }
    owner = id("box", type: :Box, storage: :heap)
    field = AST::GetField.new(tok, owner, "payload")
    field.full_type = Type.new(:Payload, ownership: :shared)
    field_assign = AST::Assignment.new(tok, field, id("payload", type: Type.new(:Payload, ownership: :shared), storage: :heap))
    field_assign.full_type = Type.new(:Payload, ownership: :shared)
    expect(field_low.send(:lower_assignment, field_assign).needs_field_cleanup).to eq(true)

    direct_low = lowering
    direct_low.define_singleton_method(:lower) do |node|
      case node
      when AST::Identifier
        MIR::Ident.new(node.name.to_s)
      when AST::Literal
        MIR::Lit.new(node.value.to_s)
      else
        MIR::Ident.new("idx")
      end
    end
    direct_low.define_singleton_method(:materialize_owned_sink_value) do |_value, *_args|
      MIR::Call.new("makeOwned", [], false, true)
    end
    direct_low.define_singleton_method(:mir_allocates?) { |value| value.is_a?(MIR::Call) }
    direct_low.define_singleton_method(:hoist_alloc) { |_value, *_args, **_kwargs| MIR::Ident.new("__hoisted") }
    direct_low.define_singleton_method(:with_ownership_consumption_for_value) { |node, *_args, **_kwargs| node }
    target = id("items", type: Type.new(:"Payload[]", collection: :list), storage: :heap)
    index = lit(0, type: :Int64)
    indexed = AST::GetIndex.new(tok, target, index)
    owned_value = id("owned_payload", type: Type.new(:Payload, ownership: :shared), storage: :heap)
    indexed_assign = AST::Assignment.new(tok, indexed, owned_value)
    indexed_assign.full_type = Type.new(:Payload, ownership: :shared)
    indexed_result = direct_low.send(:lower_direct_indexed_set, indexed_assign, cast_index: false)
    expect(indexed_result.value.name).to eq("__hoisted")

    map_low = lowering
    map_low.define_singleton_method(:lower) do |node|
      node.is_a?(AST::Identifier) ? MIR::Ident.new(node.name.to_s) : MIR::Ident.new("value")
    end
    map_low.define_singleton_method(:materialize_owned_sink_value) { |value, *_args| value }
    map_low.define_singleton_method(:hoist_alloc) { |value, *_args, **_kwargs| value }
    map_low.define_singleton_method(:with_ownership_consumption_for_value) { |node, *_args, **_kwargs| node }
    map_target = id("m", type: Type.new("HashMap<Int64>"), storage: :heap)
    map_index = AST::GetIndex.new(tok, map_target, lit("key"))
    map_assign = AST::Assignment.new(tok, map_index, lit(1, type: :Int64))
    map_assign.full_type = Type.new(:Int64)
    concat_key = MIR::ConcatStr.new([MIR::Ident.new("part")], :heap, "rt")
    map_put = map_low.send(
      :lower_map_indexed_assignment,
      map_assign,
      map_target,
      Type.new("HashMap<Int64>"),
      MIR::Ident.new("m"),
      concat_key,
      :string_map,
      IntrinsicRegistry.fs(INDEX_OPS[:string_map][:set], :string_map_set),
    )
    expect(map_put.key.alloc).to eq(:frame)

    auto_low = lowering
    auto_low.define_singleton_method(:auto_lock_assignment_value) { |_node, _alloc_sym| MIR::Ident.new("new_value") }
    auto_low.define_singleton_method(:flush_pending) { [] }
    auto_low.define_singleton_method(:append_ownership_transfers_for_mir_body) { |stmts| stmts }
    auto_low.define_singleton_method(:with_ownership_consumption_for_value) { |node, *_args, **_kwargs| node }
    auto_low.define_singleton_method(:placement_for_node) { |_node| :heap }
    always_field = AST::GetField.new(tok, id("cell", type: Type.new(:Cell, sync: :always_mutable), storage: :heap), "value")
    always_field.full_type = Type.new(:Int64)
    always_assign = AST::Assignment.new(tok, always_field, lit(1, type: :Int64))
    always_assign.full_type = Type.new(:Int64)
    always_assign.auto_lock = AST::AutoLockPlan.new(var: "cell", sync: :always_mutable)
    expect(auto_low.send(:lower_auto_lock_assignment, always_assign)).to be_a(MIR::Set)

    locked_field = AST::GetField.new(tok, id("locked_cell", type: Type.new(:Cell, sync: :locked), storage: :heap), "value")
    locked_field.full_type = Type.new(:Int64)
    locked_assign = AST::Assignment.new(tok, locked_field, lit(2, type: :Int64))
    locked_assign.full_type = Type.new(:Int64)
    locked_assign.auto_lock = AST::AutoLockPlan.new(var: "locked_cell", sync: :locked)
    expect(auto_low.send(:lower_auto_lock_assignment, locked_assign)).to be_a(MIR::ScopeBlock)
  end

  it "covers reentrant lock checks across WITH-held params" do
    held_param = param("c", type: Type.new(:Counter))
    call_arg = id("c", type: Type.new(:Counter))
    call = AST::FuncCall.new(tok, "touch", [call_arg])
    with_block = AST::WithBlock.new(tok, [{ capability: :EXCLUSIVE, var_node: call_arg }], [call], nil)
    attach_capability_plan!(with_block)
    fn_node = fn([with_block], params: [held_param])

    callee_param = param("x", type: Type.new(:Counter))
    callee_sig = FunctionSignature.new(params: [callee_param], return_type: Type.new(:Void), requires: { "x" => Set[:LOCKED] })
    errors = []

    ConcurrencyChecks.send(
      :check_reentrant!,
      fn_node,
      [with_block],
      { with_block.object_id => [call] },
      ->(name) { name == "touch" ? callee_sig : nil },
      ->(_node, msg) { errors << msg }
    )

    expect(errors.join).to include("Reentrant lock acquisition")
    expect(errors.join).to include("already held")
  end
end
