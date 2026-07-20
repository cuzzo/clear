# typed: strict
require "sorbet-runtime"
require_relative "../mir_checker"

module MIRLoweringConcurrency
    extend T::Sig
    extend T::Helpers

  requires_ancestor { MIRLowering }

  BgTransformValue = T.type_alias do
    T.nilable(T.any(
      AST::BgBlock,
      String,
      Integer,
      Symbol,
      T::Boolean,
      AsyncResultShape,
      T::Hash[String, Type],
      T::Hash[String, Schemas::ResourceClosePlan],
      T::Set[String],
      T::Array[MIR::ContextFieldDecl],
      T::Array[MIR::StructInitField],
      T::Array[String],
      T::Array[MIR::CaptureCleanupAction],
      T::Array[MIR::Emittable],
    ))
  end

  class NextExprPlan < T::Struct
    extend T::Sig

    const :source_kind, Symbol
    const :promise_type, Type
    const :async_result_shape, T.nilable(AsyncResultShape)
    const :result_type, Type
    const :result_alloc, T.nilable(Symbol)
    const :inner, MIR::Node

    sig { returns(T::Boolean) }
    def promise_list?
      source_kind == :promise_list
    end

    sig { returns(T::Boolean) }
    def observable_list?
      source_kind == :observable_list
    end

    sig { returns(T::Boolean) }
    def observable_string?
      source_kind == :observable_string
    end
  end

  class BgLoweringNames < T::Struct
    const :id, Integer
    const :ctx_type, String
    const :alloc_var, String
    const :promise_var, String
    const :ctx_var, String
    const :blk_label, String
    const :bg_rt, String
  end

  class BgTypePlan < T::Struct
    const :async_shape, AsyncResultShape
    const :inner_type, Type
    const :inner_zig, String
    const :promise_zig, String
    const :is_void, T::Boolean
  end

  class BgBodyMaterialization < T::Struct
    const :run_body, T::Array[MIR::Node]
    const :emit_body, T::Array[MIR::Node], default: []
  end

  class BgBodyStep < T::Struct
    const :expr, AST::Node
    const :binding, T.nilable(String)
  end

  class BgCaptureMaterialization < T::Struct
    const :caps, FiberCtxBuilder::Result
    const :capture_fields, T::Array[MIR::ContextFieldDecl]
    const :capture_inits, T::Array[MIR::StructInitField]
    const :fresh_heap_cleanup_names, T::Array[String]
    const :capture_frees, T::Array[MIR::CaptureCleanupAction]
    const :capture_finalizers, T::Array[MIR::Emittable], factory: -> { [] }
    const :promoted_decls, T::Array[MIR::Emittable]
  end

  class BgSchedulerPlan < T::Struct
    const :pin_mode, T.nilable(T.any(T::Boolean, Symbol))
    const :site_id, Integer
    const :site_line, Integer
    const :site_col, Integer
    const :dispatch, T.any(Symbol, T::Boolean)
    const :profiled_task_cfg, MIR::TaskConfigPlan
    const :spawn_call, MIR::FiberSpawnCall
    const :profile_site, MIR::ProfileTaskSite
    const :arena_init, T.nilable(MIR::Node)
  end

  class BgFsmTransformContext < T::Struct
    extend T::Sig

    const :node, AST::BgBlock
    const :names, BgLoweringNames
    const :types, BgTypePlan
    const :capture, BgCaptureMaterialization
    const :body, BgBodyMaterialization
    const :scheduler, BgSchedulerPlan
    const :captured, T::Hash[String, Type]
    const :capture_close_plans, T::Hash[String, Schemas::ResourceClosePlan]
    const :pointer_captures, T::Set[String]
    const :rt_name, String

    sig { returns(T::Hash[Symbol, BgTransformValue]) }
    def to_transform_hash
      result = T.let({}, T::Hash[Symbol, BgTransformValue])
      result[:node] = node
      result[:blk_label] = names.blk_label
      result[:ctx_type] = names.ctx_type
      result[:promise_zig] = types.promise_zig
      result[:async_result_shape] = types.async_shape
      result[:id] = names.id
      result[:bg_rt] = names.bg_rt
      result[:capture_fields] = capture.capture_fields
      result[:captured] = captured
      result[:capture_close_plans] = capture_close_plans
      result[:pointer_captures] = pointer_captures
      result[:capture_frees] = capture.capture_frees
      result[:capture_finalizers] = capture.capture_finalizers
      result[:fresh_heap_cleanup_names] = capture.fresh_heap_cleanup_names
      result[:is_void] = types.is_void
      result[:alloc_var] = names.alloc_var
      result[:promise_var] = names.promise_var
      result[:ctx_var] = names.ctx_var
      result[:promoted_decls] = capture.promoted_decls
      result[:capture_inits] = capture.capture_inits
      result[:rt_name] = rt_name
      result[:pin_mode] = scheduler.pin_mode
      result[:parallel] = node.parallel == true
      result[:profile_site_id] = scheduler.site_id
      result[:profile_line] = scheduler.site_line
      result[:profile_column] = scheduler.site_col
      result[:inner_zig] = types.inner_zig
      result[:arena_init_flag] = node.arena_mode == true
      result
    end

  end

  sig { params(parallel: T.nilable(T::Boolean), pinned: T.nilable(T.any(T::Boolean, Symbol))).returns(Symbol) }
  def execution_boundary_dispatch(parallel, pinned)
    return :parallel if parallel
    return :pinned if pinned

    :local
  end

  sig { params(kind: Symbol, dispatch: Symbol, analysis: T.nilable(CapabilityHelper::CaptureAnalysis)).returns(MIR::ExecutionBoundaryFact) }
  def execution_boundary_fact(kind, dispatch, analysis)
    symbols = T.let(analysis ? analysis.capture_symbols : {}, T::Hash[String, SymbolEntry])
    captured = T.let(analysis ? analysis.captures : {}, T::Hash[String, Type])
    names = T.let((symbols.keys + captured.keys).map(&:to_s).uniq.sort, T::Array[String])
    MIR::ExecutionBoundaryFact.new(
      kind: kind,
      dispatch: dispatch,
      captures: names.map { |name| boundary_capture_fact(name, symbols[name], captured[name]) },
    )
  end

  sig do
    type_parameters(:Result)
      .params(
        pointer_captures: T::Set[String],
        blk: T.proc.returns(T.type_parameter(:Result)),
      )
      .returns(T.type_parameter(:Result))
  end
  def with_bg_fiber_body_context(pointer_captures, &blk)
    T.bind(self, MIRLowering) rescue nil
    prev_bg_ptr_caps = capture_state.current_bg_pointer_captures
    prev_fiber_pending = function_state.pending_stmts
    capture_state.current_bg_pointer_captures = pointer_captures
    function_state.pending_stmts = []
    blk.call
  ensure
    T.bind(self, MIRLowering) rescue nil
    function_state.pending_stmts = T.must(prev_fiber_pending)
    capture_state.current_bg_pointer_captures = prev_bg_ptr_caps
  end

  sig do
    type_parameters(:Result)
      .params(
        local_stream: String,
        is_inf: T::Boolean,
        close_label: T.nilable(String),
        blk: T.proc.returns(T.type_parameter(:Result)),
      )
      .returns(T.type_parameter(:Result))
  end
  def with_stream_body_context(local_stream, is_inf, close_label: nil, &blk)
    T.bind(self, MIRLowering) rescue nil
    prev_stream_local = capture_state.current_stream_local
    prev_stream_is_inf = capture_state.current_stream_is_inf
    prev_close_label = capture_state.current_stream_close_label
    capture_state.current_stream_local = local_stream
    capture_state.current_stream_is_inf = is_inf
    capture_state.current_stream_close_label = close_label
    blk.call
  ensure
    T.bind(self, MIRLowering) rescue nil
    capture_state.current_stream_local = prev_stream_local
    capture_state.current_stream_is_inf = prev_stream_is_inf
    capture_state.current_stream_close_label = prev_close_label
  end

  sig { params(caps: FiberCtxBuilder::Result, analysis: T.nilable(CapabilityHelper::CaptureAnalysis), receiver: String, close_plans: T::Hash[String, Schemas::ResourceClosePlan]).returns(T::Array[MIR::Stmt]) }
  def capture_ownership_mirror_nodes(caps, analysis, receiver, close_plans = {})
    captured = T.let(analysis ? analysis.captures : {}, T::Hash[String, Type])
    caps.specs.filter_map do |spec|
      next nil unless spec.needs_moved_guard?
      next nil if close_plans.key?(spec.name)

      raw_type = captured[spec.name]
      type_info = raw_type.is_a?(Type) ? Type.new(raw_type) : Type.new(raw_type || :Any)
      next nil if type_info.resource?
      type_info = spec.cleanup_mirror_type || type_info
      name = "#{receiver}.#{spec.name}"
      entry = CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: true)
      mark = MIR::AllocMark.new(name, :heap, type_info, :heap)
      MIR::MaterializationPacket.markers(mark, MIR::Cleanup.new(name, entry)).statements
    end.flatten
  end

  sig { params(specs: T::Array[FiberCtxBuilder::CaptureSpec]).returns(T::Array[MIR::ContextFieldDecl]) }
  def capture_moved_guard_fields(specs)
    specs.filter_map do |spec|
      next nil unless spec.needs_moved_guard?

      MIR::ContextFieldDecl.new(
        name: "#{spec.name}_moved",
        type_zig: "bool",
        default_value: MIR::Lit.new("false"),
      )
    end
  end

  sig { params(name: String, type_zig: String).returns(MIR::ContextFieldDecl) }
  def context_field_decl(name, type_zig)
    MIR::ContextFieldDecl.new(name: name, type_zig: type_zig)
  end

  sig { params(name: T.any(String, Symbol), value: MIR::Emittable).returns(MIR::StructInitField) }
  def context_init_field(name, value)
    MIR::StructInitField.new(name: name, value: value)
  end

  sig { params(specs: T::Array[FiberCtxBuilder::CaptureSpec]).returns(T::Array[MIR::Emittable]) }
  def capture_setup_stmts(specs)
    specs.flat_map do |spec|
      spec.setup_mir
    end
  end

  sig { params(specs: T::Array[FiberCtxBuilder::CaptureSpec], receiver: String).returns(T::Array[MIR::Emittable]) }
  def capture_cleanup_stmts(specs, receiver)
    specs.filter_map { |spec| spec.cleanup_mir_for(receiver) }
  end

  sig { params(analysis: T.nilable(CapabilityHelper::CaptureAnalysis), base: T::Hash[String, String]).returns(T::Hash[String, String]) }
  def fiber_capture_source_overrides(analysis, base = {})
    T.bind(self, MIRLowering) rescue nil
    out = base.dup
    return out unless analysis

    analysis.capture_symbols.each do |name, sym|
      decl = sym&.reg
      mapped = decl ? function_state.decl_zig_names[decl.object_id] : nil
      out[name.to_s] ||= mapped if mapped
    end
    out
  end

  sig { params(body: T::Array[MIR::Node]).returns(T::Array[MIR::Node]) }
  def finalized_boundary_body_for_emit(body)
    T.bind(self, MIRLowering) rescue nil
    prev_alloc_names = function_state.lowered_alloc_names
    prev_guarded_names = function_state.lowered_guarded_cleanup_names
    append_ownership_transfers_for_mir_body(body)
  ensure
    T.bind(self, MIRLowering) rescue nil
    function_state.lowered_alloc_names = T.must(prev_alloc_names)
    function_state.lowered_guarded_cleanup_names = T.must(prev_guarded_names)
  end

  sig { params(node: MIR::Node, receiver: String).returns(T::Boolean) }
  def capture_ownership_mirror_node?(node, receiver)
    return false unless node.is_a?(MIR::AllocMark) || node.is_a?(MIR::Cleanup) || node.is_a?(MIR::ErrCleanup)

    node.name.to_s.start_with?("#{receiver}.")
  end

  sig { params(name: String, symbol: T.nilable(SymbolEntry), captured_type: T.nilable(Type)).returns(MIR::BoundaryCaptureFact) }
  def boundary_capture_fact(name, symbol, captured_type)
    storage = boundary_capture_storage(symbol, captured_type)
    sync = captured_type&.sync || symbol&.sync
    ownership = captured_type&.ownership || symbol&.ownership_kind
    forbidden = boundary_capture_forbidden_reason(symbol, captured_type)
    MIR::BoundaryCaptureFact.new(
      name: name,
      storage: storage,
      sync: sync,
      ownership: ownership,
      parallel_safe: forbidden.nil?,
      scheduler_affine: boundary_capture_scheduler_affine?(symbol, captured_type),
      requires_pinned: boundary_capture_requires_pinned?(symbol, captured_type),
      forbidden_reason: forbidden,
    )
  end

  sig { params(symbol: T.nilable(SymbolEntry), captured_type: T.nilable(Type)).returns(T.nilable(Symbol)) }
  def boundary_capture_forbidden_reason(symbol, captured_type)
    T.bind(self, MIRLowering) rescue nil

    return nil unless symbol || captured_type
    return :local_scheduler_affinity if boundary_capture_local?(symbol, captured_type)
    return :non_atomic_rc if boundary_capture_multiowned_rc?(symbol, captured_type)
    return nil if boundary_capture_shared_arc?(symbol, captured_type)
    return :affine_locked if boundary_capture_locked?(symbol, captured_type)
    return :affine_write_locked if boundary_capture_write_locked?(symbol, captured_type)
    return :affine_versioned if boundary_capture_versioned?(symbol, captured_type)

    type_info = captured_type || symbol&.type
    return type_info.parallel_boundary_forbidden_reason(T.cast(mir_schema_lookup, Type::SchemaLookup)) if type_info

    nil
  end

  sig { params(symbol: T.nilable(SymbolEntry), captured_type: T.nilable(Type)).returns(T::Boolean) }
  def boundary_capture_scheduler_affine?(symbol, captured_type)
    return false unless symbol || captured_type
    return true if boundary_capture_local?(symbol, captured_type)
    return false if boundary_capture_shared_arc?(symbol, captured_type)

    boundary_capture_locked?(symbol, captured_type) ||
      boundary_capture_write_locked?(symbol, captured_type) ||
      boundary_capture_versioned?(symbol, captured_type)
  end

  sig { params(symbol: T.nilable(SymbolEntry), captured_type: T.nilable(Type)).returns(T::Boolean) }
  def boundary_capture_requires_pinned?(symbol, captured_type)
    boundary_capture_scheduler_affine?(symbol, captured_type) ||
      boundary_capture_multiowned_rc?(symbol, captured_type)
  end

  sig { params(symbol: T.nilable(SymbolEntry), captured_type: T.nilable(Type)).returns(T::Boolean) }
  def boundary_capture_shared_arc?(symbol, captured_type)
    return true if captured_type&.shared?
    return false unless symbol

    type_info = symbol.type
    return true if type_info.respond_to?(:shared?) && type_info.shared?

    symbol.storage == :shared
  end

  sig { params(symbol: T.nilable(SymbolEntry), captured_type: T.nilable(Type)).returns(T::Boolean) }
  def boundary_capture_multiowned_rc?(symbol, captured_type)
    return true if captured_type&.multiowned?
    return false unless symbol

    type_info = symbol.type
    return true if type_info.respond_to?(:multiowned?) && type_info.multiowned?

    symbol.storage == :multiowned
  end

  sig { params(symbol: T.nilable(SymbolEntry), captured_type: T.nilable(Type)).returns(T.nilable(Symbol)) }
  def boundary_capture_storage(symbol, captured_type)
    return :shared if boundary_capture_shared_arc?(symbol, captured_type)
    return :multiowned if boundary_capture_multiowned_rc?(symbol, captured_type)
    return symbol&.storage
  end

  sig { params(symbol: T.nilable(SymbolEntry), captured_type: T.nilable(Type)).returns(T::Boolean) }
  def boundary_capture_local?(symbol, captured_type)
    !!(captured_type&.local? || symbol&.local?)
  end

  sig { params(symbol: T.nilable(SymbolEntry), captured_type: T.nilable(Type)).returns(T::Boolean) }
  def boundary_capture_locked?(symbol, captured_type)
    !!(captured_type&.locked? || symbol&.locked?)
  end

  sig { params(symbol: T.nilable(SymbolEntry), captured_type: T.nilable(Type)).returns(T::Boolean) }
  def boundary_capture_write_locked?(symbol, captured_type)
    !!(captured_type&.write_locked? || symbol&.write_locked?)
  end

  sig { params(symbol: T.nilable(SymbolEntry), captured_type: T.nilable(Type)).returns(T::Boolean) }
  def boundary_capture_versioned?(symbol, captured_type)
    !!(captured_type&.versioned? || SymbolEntry.versioned_sync?(symbol&.sync))
  end

  sig { params(node: AST::DoBlock).returns(MIR::DoBlock) }
  def lower_do_block(node)
    T.bind(self, MIRLowering) rescue nil
    id = lowering_counters.next_do_block_id
    n = node.branches.length
    wg_var = "__do#{id}_wg"

    all_branch_bodies = []
    boundary_facts = T.let([], T::Array[MIR::ExecutionBoundaryFact])
    branch_plans = node.branches.each_with_index.map { |branch, i|
      ctx_type = "__DoBranchCtx#{id}_#{i}"
      ctx_var = "__do#{id}_ctx#{i}"
      analysis = branch.capture_analysis
      pinned = branch.pinned
      if analysis
        AST.each_capture_analysis(branch.body) do |nested|
          next if nested.equal?(analysis)
          nested = T.cast(nested, CapabilityHelper::CaptureAnalysis)
          T.cast(analysis, CapabilityHelper::CaptureAnalysis).merge_nested!(nested)
        end
      end
      boundary_facts << execution_boundary_fact(
        :do_branch,
        execution_boundary_dispatch(branch.parallel, pinned),
        T.cast(analysis, T.nilable(CapabilityHelper::CaptureAnalysis)),
      )

      # Capture handling delegated to FiberCtxBuilder -- same builder
      # BG/BG STREAM/CONCURRENT use. DO branches use "ctx" as the body
      # access prefix (no per-id suffix).
      caps = FiberCtxBuilder.build(analysis,
                                   body_access_prefix: "ctx",
                                   fresh_heap_id: (id.value * 1000) + i,
                                   source_overrides: fiber_capture_source_overrides(analysis),
                                   schema_lookup: mir_schema_lookup)

      capture_fields = [context_field_decl("alloc", "std.mem.Allocator")] +
                       caps.specs.map { |s| context_field_decl(s.name, s.field_type_zig) } +
                       capture_moved_guard_fields(caps.specs)
      capture_inits = [
        context_init_field(:wg, MIR::AddressOf.new(MIR::Ident.new(wg_var))),
        context_init_field(:alloc, MIR::MethodCall.new(
          MIR::Ident.new(runtime_binding_name),
          "heapAlloc",
          [],
          false,
          MIR::CallableContract.no_ownership(0),
        )),
      ] + caps.specs.map { |s| context_init_field(s.name, s.init_value_mir) }
      capture_pre_decls = capture_setup_stmts(caps.specs)

      # Lower branch body to MIR nodes, finalize ownership once, then emit from
      # that same finalized body. Branch-local allocating temporaries must not
      # be hidden inside already-rendered Zig.
      branch_mir = T.let(nil, T.untyped)
      with_fiber_capture_map(caps.capture_map,
                             capture_symbols: caps.capture_symbols,
                             rt_override: "__rt") do
        body_stmts = branch.body.flat_map { |e|
          mir = lower(e)
          pending = flush_pending
          nodes = mir.is_a?(Array) ? mir.compact : do_branch_stmt_nodes(e, mir)
          pending + nodes.compact
        }
        body_stmts = capture_cleanup_stmts(caps.specs, "ctx") + body_stmts
        branch_mir = finalized_boundary_body_for_emit(body_stmts)
      end
      all_branch_bodies << (branch_mir || [])

      task_cfg = task_config_plan(branch.stack_size, branch.computed_stack_tier)
      spawn_call = do_branch_spawn_call_plan(wg_var, ctx_type, ctx_var, task_cfg, pinned == true)

      MIR::DoBranchPlan.new(
        ctx_type: ctx_type,
        ctx_var: ctx_var,
        wg_var: wg_var,
        raw_rt_name: "__raw_rt_do#{id}_#{i}",
        raw_args_name: "__raw_args_do#{id}_#{i}",
        capture_fields: capture_fields,
        capture_inits: capture_inits,
        capture_pre_decls: capture_pre_decls,
        body: branch_mir || [],
        spawn_call: spawn_call,
      )
    }

    do_block = MIR::DoBlock.new(MIR::DoBlockPlan.new(wg_var: wg_var, branches: branch_plans), all_branch_bodies)
    do_block.boundary_facts = boundary_facts
    do_block
  end

  sig { params(expr: AST::Node, mir: MIR::Node).returns(T::Array[MIR::Node]) }
  def do_branch_stmt_nodes(expr, mir)
    T.bind(self, MIRLowering) rescue nil
    if mir.is_a?(MIR::BgBlock)
      name = "__discard_bg_#{lowering_counters.next_tmp_id}"
      next_contract = MIR::CallableContract.new(
        MIR::CallableContract.no_ownership(0).signature,
        MIR::OwnershipContract.consume_operands([
          MIR::OwnershipOperandFact.owned_binding(name, Type.new(:Any), "DO branch BG discard", :heap),
        ]),
        0,
      )
      return [
        MIR::Let.new(name, mir, false, nil, nil),
        MIR::ExprStmt.new(
          MIR::MethodCall.new(MIR::Ident.new(name), "next", [], true, next_contract),
          true,
        ),
      ]
    end

    [T.must(wrap_step_as_stmt(AST::ThenStep.new(expr: expr, binding: nil), mir))]
  end

  sig { params(node: AST::BgBlock).returns(MIR::BgBlock) }
  def lower_bg_block(node)
    T.bind(self, MIRLowering) rescue nil
    id = lowering_counters.next_background_block_id
    names = bg_lowering_names(id)
    types = bg_type_plan(node)
    analysis = node.capture_analysis
    captured = T.let(analysis ? analysis.captures : {}, T::Hash[String, Type])
    capture_close_plans = T.let(analysis ? analysis.close_plans : {}, T::Hash[String, Schemas::ResourceClosePlan])
    pointer_captures = T.let(analysis ? analysis.pointer_captures : Set.new, T::Set[String])
    rt_name = runtime_binding_name

    enforce_bg_capture_strategies!(node, captured)
    capture = bg_capture_materialization(
      names, analysis, captured, capture_close_plans, pointer_captures
    )
    body = bg_body_materialization(
      node, capture.caps, analysis, pointer_captures,
      names.bg_rt, id, types.is_void, types.inner_type, capture_close_plans
    )
    scheduler = bg_scheduler_plan(node, names, rt_name)

    if bg_uses_fsm_transform?(node)
      ctx = BgFsmTransformContext.new(
        node: node,
        names: names,
        types: types,
        capture: capture,
        body: body,
        scheduler: scheduler,
        captured: captured,
        capture_close_plans: capture_close_plans,
        pointer_captures: pointer_captures,
        rt_name: rt_name,
      )
      transform_result = FsmTransform.transform(node, ctx.to_transform_hash, self)
      return fsm_bg_block_from_transform!(node, transform_result, captured, analysis) if transform_result
    end

    emit_stackful_bg_block(node, names, types, capture, body, scheduler, rt_name, captured, analysis)
  end

  sig { params(id: MIRLoweringGeneratedId).returns(BgLoweringNames) }
  def bg_lowering_names(id)
    raw_id = id.value
    BgLoweringNames.new(
      id: raw_id,
      ctx_type: "__BgCtx#{raw_id}",
      alloc_var: "__bg#{raw_id}_alloc",
      promise_var: "__bg#{raw_id}_promise",
      ctx_var: "__bg#{raw_id}_ctx",
      blk_label: "__bg#{raw_id}",
      bg_rt: "__rt_bg#{raw_id}",
    )
  end

  sig { params(node: AST::BgBlock).returns(BgTypePlan) }
  def bg_type_plan(node)
    tense_t = Type.new(node.full_type!)
    async_shape = T.cast(T.unsafe(node).async_result_shape, T.nilable(AsyncResultShape)) ||
                  AsyncResultShape.promise(tense_t.tense_type, shared: tense_t.shared_promise?)
    inner_t = Type.new(async_shape.payload_type)
    inner_zig = inner_t.nested_zig_type
    BgTypePlan.new(
      async_shape: async_shape,
      inner_type: inner_t,
      inner_zig: inner_zig,
      promise_zig: async_shape.handle_zig_type,
      is_void: inner_zig == "void",
    )
  end

  sig do
    params(
      names: BgLoweringNames,
      analysis: T.nilable(CapabilityHelper::CaptureAnalysis),
      captured: T::Hash[String, Type],
      capture_close_plans: T::Hash[String, Schemas::ResourceClosePlan],
      pointer_captures: T::Set[String],
    ).returns(BgCaptureMaterialization)
  end
  def bg_capture_materialization(names, analysis, captured, capture_close_plans, pointer_captures)
    T.bind(self, MIRLowering) rescue nil
    promoted_names = T.let({}, T::Hash[String, String])
    outer_capture_map = fiber_capture_source_overrides(analysis, capture_state.do_capture_map || {})
    capture_analysis = analysis || CapabilityHelper::CaptureAnalysis.new(
      captures: captured,
      pointer_captures: pointer_captures,
    )
    caps = FiberCtxBuilder.build(capture_analysis,
                                 body_access_prefix: "__ctx_#{names.id}",
                                 promoted_names: promoted_names,
                                 fresh_heap_alloc: names.alloc_var,
                                 fresh_heap_id: names.id,
                                 source_overrides: outer_capture_map,
                                 schema_lookup: mir_schema_lookup)

    # If this BG sits inside an outer fiber/FSM whose capture_map
    # rewrites the surrounding scope's identifiers (e.g. an outer
    # FSM-NEXT chain stores cross-suspend values in __ctx_OUTER.X),
    # the bare-name init AND the @TypeOf(...) field type below must
    # use that rewritten reference too — the outer name is no longer
    # in scope at the spawn site, only the rewritten one is.
    # FreshHeapCopy dupes already point to a local generated above the
    # spawn, so they don't need rewriting.
    capture_fields = caps.specs.map { |s|
      ftype = if s.requires_setup? || promoted_names[s.name] || outer_capture_map[s.name].nil?
                s.field_type_zig
              else
                # @TypeOf(<outer_ref>) so the field type resolves under the
                # rewritten scope (e.g. @TypeOf(__ctx_0.x) instead of
                # @TypeOf(x)).
                s.field_type_zig.sub("(#{s.name})", "(#{outer_capture_map[s.name]})")
      end
      context_field_decl(s.name, ftype)
    }
    capture_fields = capture_fields + capture_moved_guard_fields(caps.specs)
    capture_inits = [
      context_init_field(:inner, MIR::FieldGet.new(MIR::Ident.new(names.promise_var), "inner")),
      context_init_field(:alloc, MIR::Ident.new(names.alloc_var)),
    ] + caps.specs.map { |s|
      outer_ref = outer_capture_map[s.name]
      init_val = if s.requires_setup? || promoted_names[s.name] || outer_ref.nil? ||
                    pointer_captures.include?(s.name)
                   s.init_value_mir
                 else
                   MIR::Ident.new(outer_ref)
                 end
      context_init_field(s.name, init_val)
    }
    setup_stmts = capture_setup_stmts(caps.specs)
    fresh_heap_cleanup_names = caps.specs.filter_map do |spec|
      next nil if capture_close_plans.key?(spec.name)

      spec.needs_moved_guard? ? spec.name : nil
    end
    capture_finalizers = caps.specs.filter_map do |spec|
      # A specialized close plan and the generic capture finalizer are two
      # representations of the same ownership obligation. Emitting both makes
      # destroyTask deinit the captured container twice.
      next nil if capture_close_plans.key?(spec.name)

      spec.finalizer_mir_for("__ctx_#{names.id}")
    end
    capture_frees = captured.filter_map { |name, _|
      close_plan = capture_close_plans[name]
      if close_plan
        MIR::CaptureCleanupAction.new(
          target: MIR::FieldGet.new(MIR::Ident.new("__ctx_#{names.id}"), name.to_s),
          cleanup_entry: CleanupEntry.build(
            :resource,
            alloc: :heap,
            has_moved_guard: false,
            resource_close_plan: close_plan,
          ),
        )
      end
    }

    BgCaptureMaterialization.new(
      caps: caps,
      capture_fields: capture_fields,
      capture_inits: capture_inits,
      fresh_heap_cleanup_names: fresh_heap_cleanup_names,
      capture_frees: capture_frees,
      capture_finalizers: capture_finalizers,
      promoted_decls: setup_stmts,
    )
  end

  sig { params(stack_size: T.nilable(Symbol), computed_tier: T.nilable(Symbol)).returns(MIR::TaskConfigPlan) }
  def task_config_plan(stack_size, computed_tier)
    lowerer = T.cast(self, MIRLowering)
    MIR::TaskConfigPlan.new(stack_variant: lowerer.task_config_variant(stack_size, computed_tier))
  end

  sig { params(base: MIR::TaskConfigPlan, site_id: Integer, dispatch: T.any(Symbol, T::Boolean)).returns(MIR::TaskConfigPlan) }
  def profiled_task_config_plan(base, site_id, dispatch)
    MIR::TaskConfigPlan.new(
      stack_variant: base.stack_variant,
      profile_site_id: site_id,
      profile_dispatch_id: profile_dispatch_numeric_id(dispatch),
    )
  end

  sig { params(dispatch: T.any(Symbol, T::Boolean)).returns(Integer) }
  def profile_dispatch_numeric_id(dispatch)
    case dispatch
    when :parallel then 2
    when :shared then 3
    else 1
    end
  end

  sig { params(rt_name: String, ctx_type: String, ctx_var: String, task_config: MIR::TaskConfigPlan, pin_mode: T.nilable(T.any(Symbol, T::Boolean))).returns(MIR::FiberSpawnCall) }
  def fiber_spawn_call_plan(rt_name, ctx_type, ctx_var, task_config, pin_mode)
    target = case pin_mode
             when :local, true then :runtime_submit
             when :shared then :pinned
             else :best
             end
    MIR::FiberSpawnCall.new(
      target: target,
      runtime_name: rt_name,
      ctx_type: ctx_type,
      ctx_var: ctx_var,
      task_config: task_config,
    )
  end

  sig { params(wg_var: String, ctx_type: String, ctx_var: String, task_config: MIR::TaskConfigPlan, pinned: T::Boolean).returns(MIR::FiberSpawnCall) }
  def do_branch_spawn_call_plan(wg_var, ctx_type, ctx_var, task_config, pinned)
    MIR::FiberSpawnCall.new(
      target: pinned ? :wait_group_submit : :best,
      wait_group_name: pinned ? wg_var : nil,
      ctx_type: ctx_type,
      ctx_var: ctx_var,
      task_config: task_config,
      pass_ctx_by_address: true,
    )
  end

  sig { params(dispatch: T.any(Symbol, T::Boolean)).returns(Symbol) }
  def profile_dispatch_symbol(dispatch)
    case dispatch
    when :parallel then :parallel
    when :shared then :shared
    else :local
    end
  end

  sig { params(node: AST::BgBlock, names: BgLoweringNames, rt_name: String).returns(BgSchedulerPlan) }
  def bg_scheduler_plan(node, names, rt_name)
    T.bind(self, MIRLowering) rescue nil
    task_cfg = task_config_plan(node.stack_size, node.computed_stack_tier)
    pin_mode = node.pinned
    site_id = names.id + 1
    site_line = node.token&.line || 0
    site_col = node.token&.column || 0
    dispatch = node.parallel ? :parallel : ((pin_mode == false || pin_mode.nil?) ? :local : pin_mode)
    profiled_task_cfg = profiled_task_config_plan(task_cfg, site_id, dispatch)
    BgSchedulerPlan.new(
      pin_mode: pin_mode,
      site_id: site_id,
      site_line: site_line,
      site_col: site_col,
      dispatch: dispatch,
      profiled_task_cfg: profiled_task_cfg,
      spawn_call: fiber_spawn_call_plan(rt_name, names.ctx_type, names.ctx_var, profiled_task_cfg, dispatch),
      profile_site: MIR::ProfileTaskSite.new(
        site_id: site_id,
        line: site_line,
        column: site_col,
        dispatch: profile_dispatch_symbol(dispatch),
        form: :stack,
      ),
      arena_init: node.arena_mode ? MIR::Set.new(MIR::FieldGet.new(MIR::Ident.new(names.bg_rt), "arena_mode"), MIR::Lit.new("true"), false) : nil,
    )
  end

  sig { params(node: AST::BgBlock).returns(T::Boolean) }
  def bg_uses_fsm_transform?(node)
    T.bind(self, MIRLowering)
    target_is_bc = !!bc_target?
    !!(node.spawn_form == :fsm && !target_is_bc)
  end

  sig do
    params(
      node: AST::BgBlock,
      names: BgLoweringNames,
      types: BgTypePlan,
      capture: BgCaptureMaterialization,
      body: BgBodyMaterialization,
      scheduler: BgSchedulerPlan,
      rt_name: String,
      captured: T::Hash[String, Type],
      analysis: T.nilable(CapabilityHelper::CaptureAnalysis),
    ).returns(MIR::BgBlock)
  end
  def emit_stackful_bg_block(node, names, types, capture, body, scheduler, rt_name, captured, analysis)
    plan = MIR::BgStackfulPlan.new(
      id: names.id,
      ctx_type: names.ctx_type,
      alloc_var: names.alloc_var,
      promise_var: names.promise_var,
      ctx_var: names.ctx_var,
      blk_label: names.blk_label,
      bg_rt: names.bg_rt,
      rt_name: rt_name,
      promise_zig: types.promise_zig,
      is_void: types.is_void,
      capture_fields: capture.capture_fields,
      capture_inits: capture.capture_inits,
      capture_frees: capture.capture_frees,
      promoted_decls: capture.promoted_decls,
      profile_site: scheduler.profile_site,
      arena_init: scheduler.arena_init,
      spawn_call: scheduler.spawn_call,
      alloc_expr: bg_alloc_expr(node, rt_name),
      run_body: body.emit_body.empty? ? body.run_body : body.emit_body,
    )
    bg = MIR::BgBlock.new(plan, captured, body.run_body)
    bg.result_type = Type.new(node.full_type!)
    bg.boundary_fact = execution_boundary_fact(
      :bg,
      execution_boundary_dispatch(node.parallel, node.pinned),
      analysis,
    )
    bg
  end

  sig { params(node: AST::BgBlock, rt_name: String).returns(MIR::Emittable) }
  def bg_alloc_expr(node, rt_name)
    receiver = MIR::Ident.new(rt_name)
    if node.pinned == true || node.pinned == :local
      sched = MIR::MethodCall.new(receiver, "getSched", [], false, MIR::CallableContract.no_ownership(0))
      return MIR::FieldGet.new(sched, "allocator")
    end

    MIR::MethodCall.new(receiver, "heapAlloc", [], false, MIR::CallableContract.no_ownership(0))
  end

  sig do
    params(
      node: AST::BgBlock,
      caps: FiberCtxBuilder::Result,
      analysis: T.nilable(CapabilityHelper::CaptureAnalysis),
      pointer_captures: T::Set[String],
      bg_rt: String,
      id: MIRLoweringGeneratedId,
      is_void: T::Boolean,
      inner_t: Type,
      capture_close_plans: T::Hash[String, Schemas::ResourceClosePlan],
    ).returns(BgBodyMaterialization)
  end
  def bg_body_materialization(node, caps, analysis, pointer_captures, bg_rt, id, is_void, inner_t, capture_close_plans)
    T.bind(self, MIRLowering) rescue nil
    run_body = T.let([], T::Array[MIR::Node])
    emit_body = T.let([], T::Array[MIR::Node])
    with_bg_fiber_body_context(pointer_captures) do
      with_fiber_capture_map(caps.capture_map,
                             capture_symbols: caps.capture_symbols,
                             rt_override: bg_rt) do
        lowered = lower_bg_body_steps(node, id, is_void, inner_t)
        run_body = finalized_boundary_body_for_emit(
          capture_ownership_mirror_nodes(caps, analysis, "__ctx_#{id}", capture_close_plans) +
            capture_cleanup_stmts(caps.specs, "__ctx_#{id}") +
            lowered.run_body
        )
        emit_body = run_body.reject { |mir| capture_ownership_mirror_node?(mir, "__ctx_#{id}") }
      end
    end
    BgBodyMaterialization.new(run_body: run_body, emit_body: emit_body)
  end

  sig { params(node: AST::BgBlock).returns(T::Array[BgBodyStep]) }
  def bg_body_steps(node)
    steps = T.let([], T::Array[BgBodyStep])
    node.body.each do |stmt|
      if stmt.is_a?(AST::ThenChain)
        stmt.steps.each { |step| steps << BgBodyStep.new(expr: step.expr, binding: step.binding) }
      else
        steps << BgBodyStep.new(expr: stmt, binding: nil)
      end
    end
    steps
  end

  sig { params(node: AST::BgBlock, id: MIRLoweringGeneratedId, is_void: T::Boolean, inner_t: Type).returns(BgBodyMaterialization) }
  def lower_bg_body_steps(node, id, is_void, inner_t)
    steps = bg_body_steps(node)
    last_step = steps.pop
    body_mir = T.let([], T::Array[MIR::Node])
    steps.each { |step| lower_bg_pre_step(step, body_mir) }
    lower_bg_result_step(last_step, body_mir, id, is_void, inner_t)
    BgBodyMaterialization.new(run_body: body_mir, emit_body: body_mir)
  end

  sig { params(step: BgBodyStep, body_mir: T::Array[MIR::Node]).void }
  def lower_bg_pre_step(step, body_mir)
    T.bind(self, MIRLowering) rescue nil
    mir = lower(step.expr)
    binding = step.binding
    mir = finalize_bg_discard_expr(step.expr, T.cast(mir, MIR::NodeRoot)) unless binding
    step_pending = flush_pending
    mir_nodes = bg_mir_nodes(mir)
    produced = if binding
      step_pending + [MIR::Let.new(binding, T.must(mir_nodes.last), false, nil, nil)]
    else
      step_pending + mir_nodes
    end
    body_mir.concat(guard_bg_shared_node_statement(step.expr, produced))
    nil
  end

  sig { params(step: T.nilable(BgBodyStep), body_mir: T::Array[MIR::Node], id: MIRLoweringGeneratedId, is_void: T::Boolean, inner_t: Type).void }
  def lower_bg_result_step(step, body_mir, id, is_void, inner_t)
    return unless step

    if is_void || step.expr.is_a?(AST::Assignment)
      lower_bg_statement_result(step, body_mir)
      return
    end

    lower_bg_value_result(step, body_mir, id, inner_t)
  end

  sig { params(step: BgBodyStep, body_mir: T::Array[MIR::Node]).void }
  def lower_bg_statement_result(step, body_mir)
    T.bind(self, MIRLowering) rescue nil
    last_mir = T.cast(finalize_bg_discard_expr(step.expr, T.cast(lower(step.expr), MIR::NodeRoot)), MIR::Node)
    last_pending = flush_pending
    body_mir.concat(guard_bg_shared_node_statement(step.expr, last_pending + [last_mir]))
    nil
  end

  sig { params(expr: AST::Node, mir: MIR::NodeRoot).returns(MIR::NodeRoot) }
  def finalize_bg_discard_expr(expr, mir)
    T.bind(self, MIRLowering) rescue nil
    finalized, hoisted_discard = materialize_statement_discard(expr, mir)
    return finalized unless discard_expr_stmt?(expr, finalized) && !hoisted_discard

    MIR::ExprStmt.new(T.cast(finalized, MIR::Node), true)
  end

  sig { params(step: BgBodyStep, body_mir: T::Array[MIR::Node], id: MIRLoweringGeneratedId, inner_t: Type).void }
  def lower_bg_value_result(step, body_mir, id, inner_t)
    T.bind(self, MIRLowering) rescue nil
    result_alloc = escaping_value_alloc(inner_t)
    last_mir = T.cast(with_decl_alloc(result_alloc) { lower(step.expr) }, MIR::Node)
    last_mir = place_value_for_destination(last_mir, step.expr, result_alloc, inner_t)
    last_mir = hoist_alloc(last_mir, step.expr, err_cleanup: true) if mir_allocates?(last_mir)
    last_pending = flush_pending
    result_target = MIR::FieldGet.new(MIR::FieldGet.new(MIR::Ident.new("__ctx_#{id}"), "inner"), "result")
    shape = AsyncResultShape.promise(inner_t)
    stored_value = async_payload_storage_value(last_mir, shape)
    produced = last_pending + ownership_marks_for_transferred_temp(last_mir, target_alloc: :heap) +
      [MIR::Set.new(result_target, stored_value)]
    body_mir.concat(guard_bg_shared_node_statement(step.expr, produced))
    nil
  end

  # Unit-level lowering helpers extend this module without the complete
  # MIRLowering object. Production lowering always supplies the guard method.
  sig { params(stmt: AST::Node, nodes: T::Array[MIR::Node]).returns(T::Array[MIR::Node]) }
  def guard_bg_shared_node_statement(stmt, nodes)
    T.bind(self, MIRLowering) rescue nil

    return nodes unless T.unsafe(self).respond_to?(:guard_shared_node_statement, true)

    guard_shared_node_statement(stmt, nodes)
  end

  sig { params(mir: T.any(MIR::Node, T::Array[MIR::Node])).returns(T::Array[MIR::Node]) }
  def bg_mir_nodes(mir)
    mir.is_a?(Array) ? mir.compact : [mir]
  end

  # Raise a CLEAR-level diagnostic if any capture classifies as Refuse.
  # This is the rule enforcement step — refusing at lowering time stops
  # the dangling-pointer family of bugs (docs/agents/vm-bugs.md) from
  # producing silent UAFs. Users must write GIVE / COPY / CLONE inside
  # the BG body to transfer ownership, or wrap the container in
  # @shared:locked / @multiowned for shared access.
  sig { params(node: T.any(AST::BgBlock, AST::BgStreamBlock), _captured: T::Hash[String, Type]).void }
  def enforce_bg_capture_strategies!(node, _captured)
    T.bind(self, MIRLowering) rescue nil
    strategies = node.capture_analysis ? node.capture_analysis.strategies : {}
    refused = strategies.select do |_name, strategy|
      strategy.is_a?(CaptureStrategy::Refuse)
    end
    return if refused.empty?
    lines = refused.map do |name, strat|
      hint = case strat.reason
             when :pointer_passed_without_transfer
               "'#{name}' is @pool/@map/HashMap — wrap in @shared:locked, or GIVE/COPY inside the BG body."
             when :list_borrow_without_transfer
               "'#{name}' is @list — GIVE inside the BG body to transfer ownership, or COPY to deep-copy."
             when :pool_borrow_without_transfer
               "'#{name}' is @pool — wrap in @shared:locked, or GIVE inside the BG body."
             when :array_borrow_without_transfer
               "'#{name}' is a slice borrow — COPY inside the BG body for a fresh heap copy."
             when :heap_backed_without_transfer
               "'#{name}' is heap-backed — GIVE/COPY inside the BG body, or use @multiowned/@shared."
             else
               "'#{name}' cannot be safely captured (#{strat.reason})."
             end
      "  - #{hint}"
    end
    raise "BG block captures values that cannot safely cross the fiber boundary:\n" +
          lines.join("\n") +
          "\n(See docs/agents/vm-bugs.md for the ownership rules.)"
  end

  sig do
    params(
      node: AST::BgBlock,
      transform_result: MIR::FsmLoweringResult,
      captured: T::Hash[String, Type],
      analysis: T.nilable(CapabilityHelper::CaptureAnalysis),
    ).returns(MIR::BgBlock)
  end
  def fsm_bg_block_from_transform!(node, transform_result, captured, analysis)
    T.bind(self, MIRLowering) rescue nil

    unless transform_result.is_a?(MIR::FsmLoweringResult)
      Kernel.raise "FSM lowering must return MIR::FsmLoweringResult; rendered Zig without typed FSM structure is unverifiable"
    end
    fsm_structure = transform_result.structure
    result_type = Type.from_node!(node, context: "FSM BG result").tense_type
    fsm_structure.owned_result_required =
      !!(result_type && ownership_tracked_transfer_type?(result_type))
    MIRChecker.check_fsm_structure!(fsm_structure, source: node)
    # The fiber body is consumed into the FSM state machine. Exposing it again
    # through run_body would double-walk ownership and manufacture diagnostics.
    bg = MIR::BgBlock.new(transform_result.body, captured, [], fsm_structure)
    bg.result_type = Type.new(node.full_type!)
    bg.boundary_fact = execution_boundary_fact(
      :bg,
      execution_boundary_dispatch(node.parallel, node.pinned),
      analysis,
    )
    bg
  end

  sig { params(node: AST::BgStreamBlock).returns(T.any(MIR::BgBlock, MIR::BlockExpr, MIR::InlineBc, MIR::StreamSpawn)) }
  def lower_bg_stream_block(node)
    T.bind(self, MIRLowering) rescue nil
    id = lowering_counters.next_stream_generator_id

    expected_t = Type.from_node(function_state.current_expected_type)
    tense_t = bg_stream_expected_type?(expected_t) ? T.must(expected_t) : Type.new(node.full_type!)
    is_inf = tense_t.inf_stream?
    stream_zig = if tense_t.dynamic_stream?
      element_t = T.must(tense_t.tense_type.element_type)
      "CheatLib.Stream(#{element_t.nested_zig_type})"
    else
      tense_t.zig_type
    end

    ctx_type = "__SgCtx#{id}"
    alloc_var = "__sg#{id}_alloc"
    stream_var = "__sg#{id}_stream"
    ctx_var = "__sg#{id}_ctx"
    blk_label = "__sg#{id}"
    local_stream = "__sg#{id}_local"

    # BC backend: there are no real coroutines, so model the stream as
    # an eager List materialization. Run the body inline; YIELD becomes
    # `__sg<id>_local.push(x)` which we rewrite to list-append in the
    # bc_emitter, and NEXT pops the head of the list. This works for all
    # finite streams. For ~T[INF] (`WHILE TRUE`-driven generators) the
    # eager path would loop forever, so we emit a producer-fiber +
    # rendezvous-channel form (MIR::StreamSpawn / MIR::StreamYield)
    # that the bc_emitter compiles to STREAM_SPAWN + STREAM_YIELD opcodes.
    if bc_target?
      run_body = with_stream_body_context(local_stream, is_inf, close_label: is_inf ? nil : blk_label) do
        node.body.map { |expr| lower(expr) }
      end

      if is_inf
        # Real producer fiber. The captures handed to FiberCtxBuilder
        # become the fiber's captures; bc_emitter prepends the channel
        # handle as arg 0 inside STREAM_SPAWN and inside the producer
        # frame the channel binds to a synthetic slot consumed by
        # MIR::StreamYield via lower_yield.
        captures_map = node.capture_analysis ? node.capture_analysis.captures : {}
        spawn = MIR::StreamSpawn.new(captures_map, run_body)
        spawn.boundary_fact = execution_boundary_fact(:stream_spawn, :local, node.capture_analysis)
        return spawn
      end

      block = MIR::BlockExpr.new(blk_label, [
        MIR::Let.new(local_stream, MIR::MakeList.new("anytype", [], :frame), true, Type.new("anytype"), nil),
        *run_body,
        MIR::BreakStmt.new(blk_label, MIR::Ident.new(local_stream))
      ])
      # @split: wrap the materialized list in a Value.SplitStream so the
      # value carries a per-handle cursor. CLONE on a split stream then
      # produces an independent handle pointing at the same buffer.
      if tense_t.split_open_stream?
        return MIR::InlineBc.new(:split_stream_new, [block], { tag: :split_stream })
      end
      return block
    end

    analysis = node.capture_analysis
    rt_name = runtime_binding_name
    enforce_bg_capture_strategies!(node, analysis ? analysis.captures : {})

    # Capture handling delegated to FiberCtxBuilder -- same builder
    # BG/DO/CONCURRENT use. BG STREAM's site-specific extras are the
    # control fields (stream_inner / alloc) and "ctx" body prefix.
    promoted_names = T.let({}, T::Hash[String, String])
    caps = FiberCtxBuilder.build(analysis,
                                 body_access_prefix: "ctx",
                                 promoted_names: promoted_names,
                                 fresh_heap_alloc: alloc_var,
                                 fresh_heap_id: id.value,
                                 source_overrides: fiber_capture_source_overrides(analysis),
                                 schema_lookup: mir_schema_lookup)

    capture_fields = caps.specs.map { |s| context_field_decl(s.name, s.field_type_zig) } +
                     capture_moved_guard_fields(caps.specs)
    capture_inits = [
      context_init_field(:stream_inner, MIR::FieldGet.new(MIR::Ident.new(stream_var), "inner")),
      context_init_field(:alloc, MIR::Ident.new(alloc_var)),
    ] + caps.specs.map { |s| context_init_field(s.name, s.init_value_mir) }

    # Lower stream body to MIR nodes. The checker sees the full body,
    # including verifier-only ownership mirrors; the emitter body filters
    # those mirrors at the final rendering edge.
    stream_run_body = T.let(nil, T.untyped)
    stream_emit_body = T.let([], T::Array[MIR::Node])
    stream_capture_cleanups = capture_cleanup_stmts(caps.specs, "ctx")
    inherited_capture_names = caps.specs.filter_map { |spec| spec.needs_moved_guard? ? "ctx.#{spec.name}" : nil }.to_set
    prev_stream_inherited_allocs = capture_state.current_fsm_inherited_alloc_names
    with_stream_body_context(local_stream, is_inf) do
      begin
        capture_state.current_fsm_inherited_alloc_names = inherited_capture_names
        with_fiber_capture_map(caps.capture_map,
                               capture_symbols: caps.capture_symbols,
                               rt_override: "__rt") do
          body_mir = node.body.flat_map { |expr|
            mir = lower(expr)
            pending = flush_pending
            mir_nodes = mir.is_a?(Array) ? mir.compact : [mir]
            pending + mir_nodes
          }
          stream_run_body = finalized_boundary_body_for_emit(
            capture_ownership_mirror_nodes(caps, analysis, "ctx") +
              stream_capture_cleanups +
              body_mir
          )
          stream_emit_body = stream_run_body.reject { |mir|
            capture_ownership_mirror_node?(mir, "ctx") || stream_capture_cleanups.include?(mir)
          }
        end
      ensure
        capture_state.current_fsm_inherited_alloc_names = prev_stream_inherited_allocs
      end
    end

    promoted_decls = capture_setup_stmts(caps.specs)

    task_cfg = task_config_plan(node.stack_size, node.computed_stack_tier)
    spawn_call = fiber_spawn_call_plan(rt_name, ctx_type, ctx_var, task_cfg, :local)

    plan = MIR::BgStreamPlan.new(
      id: id.value,
      ctx_type: ctx_type,
      alloc_var: alloc_var,
      stream_var: stream_var,
      ctx_var: ctx_var,
      blk_label: blk_label,
      stream_zig: stream_zig,
      local_stream: local_stream,
      capture_fields: capture_fields,
      capture_inits: capture_inits,
      promoted_decls: promoted_decls,
      capture_cleanups: stream_capture_cleanups,
      body: stream_emit_body,
      spawn_call: spawn_call,
      rt_name: rt_name,
    )
    bg = MIR::BgBlock.new(plan, analysis ? analysis.captures : {}, stream_run_body || [])
    bg.result_type = Type.new(tense_t)
    bg.boundary_fact = execution_boundary_fact(:bg_stream, :local, analysis)
    bg
  end

  sig { params(node: AST::YieldExpr).returns(MIR::Emittable) }
  def lower_yield(node)
    T.bind(self, MIRLowering) rescue nil
    stream_local = capture_state.current_stream_local || "__stream_local"
    lowered = with_decl_alloc(:heap) do
      value = lower(node.expr)
      place_value_for_destination(value, node.expr, :heap, node.expr.full_type!)
    end
    lowered = hoist_alloc(lowered, node.expr, err_cleanup: true) if mir_allocates?(lowered)
    transfer_marks = ownership_marks_for_transferred_temp(lowered, target_alloc: :heap)
    # BC inf-stream path: emit MIR::StreamYield so the bc_emitter routes
    # to the rendezvous-channel STREAM_YIELD opcode. The Zig backend
    # never reaches this branch (it sets current_stream_is_inf only for
    # the materializing path; target check guards against confusion).
    if bc_target? && capture_state.current_stream_is_inf
      stream_yield = MIR::StreamYield.new(lowered)
      return transfer_marks.empty? ? stream_yield : MIR::ScopeBlock.new([*transfer_marks, stream_yield])
    end
    # The yielded value is a hoisted, escape-placed binding (Hoist lifts
    # anonymous YIELD operands; escape analysis marks it heap because it
    # escapes the fiber). The stream owns it; the consumer frees it. No
    # dupe -- one allocation, placed by escape analysis.
    base_contract = MIR::CallableContract.no_ownership(1)
    push_contract = if transfer_marks.empty? || !lowered.is_a?(MIR::Ident)
      base_contract
    else
      operand = MIR::OwnershipOperandFact.owned_binding(
        lowered.name.to_s,
        Type.from_node!(node.expr, context: "YIELD ownership transfer"),
        "stream YIELD push",
        :heap,
      )
      MIR::CallableContract.new(
        base_contract.signature,
        MIR::OwnershipContract.consume_operands([operand]),
        1,
      )
    end
    push = MIR::MethodCall.new(MIR::Ident.new(stream_local), "push", [lowered], true, push_contract)
    # YIELD transfers ownership to the stream at the push boundary. InfStream
    # owns and cleans the value even if push returns StreamClosed, so the local
    # error cleanup must be disarmed before the fallible call.
    transfer_marks.empty? ? push : MIR::ScopeBlock.new([*transfer_marks, MIR::ExprStmt.new(push, false)])
  end

  sig { params(_node: AST::CloseStream).returns(MIR::Node) }
  def lower_close_stream(_node)
    T.bind(self, MIRLowering) rescue nil
    stream_local = capture_state.current_stream_local || "__stream_local"
    close = MIR::ExprStmt.new(
      MIR::MethodCall.new(MIR::Ident.new(stream_local), "close", [], false,
        MIR::CallableContract.no_ownership(0)),
      false,
    )
    label = capture_state.current_stream_close_label
    if bc_target? && label
      return MIR::ScopeBlock.new([close, MIR::BreakStmt.new(label, MIR::Ident.new(stream_local))])
    end

    MIR::ScopeBlock.new([close, MIR::ReturnStmt.new(nil)])
  end

  sig { params(promise_type: Type, result_type: Type, fallback_alloc: Symbol).returns(T.nilable(Symbol)) }
  def next_result_owned_alloc(promise_type, result_type, fallback_alloc)
    T.bind(self, MIRLowering) rescue nil
    return fallback_alloc if promise_type.promise_list?
    return fallback_alloc if promise_type.observable_array_future?
    return :heap if promise_type.observable? && ownership_bearing_type?(result_type)
    return :heap if ownership_bearing_type?(result_type)
    nil
  end

  sig { params(node: AST::NextExpr, alloc_sym: Symbol).returns(NextExprPlan) }
  def next_expr_plan(node, alloc_sym)
    T.bind(self, MIRLowering) rescue nil
    promise_type = Type.new(node.expr.full_type!)
    result_type = node.full_type!(context: "NEXT result")
    async_shape = node.expr.is_a?(AST::Identifier) ? node.expr.symbol&.async_result_shape : nil
    tense_plan = T.cast(node.tense_plan, T.nilable(TenseOperationPlan))
    scalar_future = async_shape&.promise? || promise_type.single_future? || promise_type.shared_promise?
    if scalar_future && async_shape.nil?
      async_shape = AsyncResultShape.promise(
        promise_type.tense_type,
        shared: promise_type.shared_promise?,
      )
    end
    if scalar_future && (!tense_plan || tense_plan.operation != TenseOperationKind::Next)
      raise "scalar NEXT lowering requires its annotation-produced TenseOperationPlan"
    end
    source_kind = if promise_type.promise_list? && async_shape.nil?
      :promise_list
    elsif tense_plan
      case tense_plan.backend_form
      when TenseBackendForm::SharedPromiseNext then :shared_promise
      when TenseBackendForm::ObservableStringNext then :observable_string
      else :plain
      end
    elsif promise_type.observable_array_future?
      :observable_list
    elsif promise_type.observable? && observable_next_string?(promise_type)
      :observable_string
    else
      :plain
    end
    NextExprPlan.new(
      source_kind: source_kind,
      promise_type: promise_type,
      async_result_shape: async_shape,
      result_type: result_type,
      result_alloc: next_result_owned_alloc(promise_type, result_type, alloc_sym),
      inner: T.cast(lower(node.expr), MIR::Node),
    )
  end

  sig { params(promise_type: Type).returns(T::Boolean) }
  def observable_next_string?(promise_type)
    tt = promise_type.tense_type
    wt = tt&.optional? ? tt.wrapped_type : tt
    !!wt&.string?
  end

  sig { params(type_info: T.nilable(Type)).returns(T::Boolean) }
  def bg_stream_expected_type?(type_info)
    return false unless type_info

    type_info.inf_stream? || type_info.open_stream? || type_info.bounded_stream?
  end

  sig { params(node: AST::NextExpr, alloc_sym: Symbol).returns(MIR::Node) }
  def lower_next_expr(node, alloc_sym = :frame)
    T.bind(self, MIRLowering) rescue nil
    plan = next_expr_plan(node, alloc_sym)
    promise_type = plan.promise_type
    result_t = plan.result_type

    if plan.promise_list?
      # NEXT on ~T[]@list: iterate the promise list, await each promise, collect results.
      # alloc_sym determines whether results are heap- or frame-allocated. The
      # emitter relocates ownership-bearing Promise payloads from their BG heap
      # allocator into this aggregate allocator before appending them.
      promise_list_inner = plan.inner

      # In BC the BG runtime spawns real fibers via BG_SPAWN and stashes
      # their futures in `futureTable`; the list elements are
      # Pair("__future__", id) markers, not yet-resolved values. Route
      # through MethodCall("next") so the bc_emitter emits AWAIT, which
      # the runner extends to walk Value.List (await each item, build
      # result list).
      if bc_target?
        call = MIR::MethodCall.new(promise_list_inner, "next", [], true, MIR::CallableContract.no_ownership(0), alloc_sym)
        call.result_type = Type.new(result_t)
        return call
      end

      item_shape = AsyncResultShape.promise_list_item(promise_type)
      tmp_id = lowering_counters.next_tmp_id
      promise_list_label = "__next_all_#{tmp_id}"
      results_var = "__next_results_#{tmp_id}"
      return MIR::NextPromiseList.new(
        list_expr: promise_list_inner,
        async_shape: item_shape,
        label: promise_list_label,
        results_var: results_var,
        alloc: alloc_sym,
        result_type: result_t,
      )
    end

    # Collection observable (`~T[]@set:observable`): NEXT yields an owned
    # ArrayListUnmanaged(T) via `materializeNext(alloc)` rather than a
    # snapshot handle, so user code (`final = NEXT running`) gets
    # something it can iterate without explicit `.release()`. The
    # materialized list is placed by the receiving binding's allocator
    # (alloc_sym) -- one allocator per binding, like every other value.
    if plan.observable_list?
      observable_list_inner = plan.inner
      # The materialized list inherits the receiving binding's placement
      # alloc_sym is the
      # fallback when NEXT is lowered outside a binding.
      call = MIR::MethodCall.new(observable_list_inner, "materializeNext",
        [MIR::AllocatorRef.new(alloc_sym)], true, MIR::CallableContract.no_ownership(1), alloc_sym)
      call.result_type = Type.new(result_t)
      return call
    end

    if plan.observable_string?
      observable_string_inner = plan.inner
      observable_string_label = "__obs_next_string_#{lowering_counters.next_tmp_id}"
      materialize = MIR::MethodCall.new(observable_string_inner, "materialize", [MIR::AllocatorRef.new(:heap)], true,
        MIR::CallableContract.no_ownership(1), :heap)
      materialize.result_type = Type.new(result_t)
      block = MIR::BlockExpr.new(observable_string_label, [
        MIR::ExprStmt.new(MIR::MethodCall.new(observable_string_inner, "wait", [], false,
          MIR::CallableContract.no_ownership(0)), nil),
        MIR::BreakStmt.new(observable_string_label, materialize),
      ])
      block.result_type = Type.new(result_t)
      return block
    end

    receiver = plan.inner
    if promise_type.stream? && !receiver.is_a?(MIR::Ident)
      receiver_tmp_id = lowering_counters.next_tmp_id
      label = "__next_recv_#{receiver_tmp_id}"
      temp = "__next_source_#{receiver_tmp_id}"
      block = MIR::BlockExpr.new(label, [
        MIR::Let.new(temp, receiver, true, nil, nil),
        MIR::BreakStmt.new(label,
          MIR::MethodCall.new(MIR::Ident.new(temp), result_t.stream_step? ? "nextStep" : "next", [], true,
            MIR::CallableContract.no_ownership(0), plan.result_alloc)),
      ])
      block.result_type = Type.new(result_t)
      return block
    end

    next_method = result_t.stream_step? ? "nextStep" : "next"
    boxed_fallible = !bc_target? && plan.async_result_shape&.boxes_fallible_payload? == true
    call = MIR::MethodCall.new(
      receiver,
      next_method,
      [],
      !boxed_fallible,
      MIR::CallableContract.no_ownership(0),
      plan.result_alloc,
    )
    return call unless boxed_fallible

    unwrapped_transport = MIR::TryExpr.new(call)
    MIR::AsyncPayloadTake.new(source: unwrapped_transport, result_type: Type.new(result_t))
  end

  private :boundary_capture_requires_pinned?,
    :emit_stackful_bg_block,
    :fsm_bg_block_from_transform!

  private :bg_alloc_expr
  private :bg_body_materialization
  private :bg_body_steps
  private :bg_capture_materialization
  private :bg_lowering_names
  private :bg_mir_nodes
  private :bg_scheduler_plan
  private :bg_stream_expected_type?
  private :bg_type_plan
  private :bg_uses_fsm_transform?
  private :boundary_capture_fact
  private :boundary_capture_forbidden_reason
  private :boundary_capture_local?
  private :boundary_capture_locked?
  private :boundary_capture_multiowned_rc?
  private :boundary_capture_scheduler_affine?
  private :boundary_capture_shared_arc?
  private :boundary_capture_storage
  private :boundary_capture_versioned?
  private :boundary_capture_write_locked?
  private :capture_ownership_mirror_node?
  private :do_branch_spawn_call_plan
  private :do_branch_stmt_nodes
  private :enforce_bg_capture_strategies!
  private :execution_boundary_fact
  private :finalize_bg_discard_expr
  private :lower_bg_body_steps
  private :lower_bg_pre_step
  private :lower_bg_result_step
  private :lower_bg_statement_result
  private :lower_bg_value_result
  private :next_expr_plan
  private :next_result_owned_alloc
  private :observable_next_string?
  private :profile_dispatch_numeric_id
  private :profile_dispatch_symbol
  private :profiled_task_config_plan
  private :with_stream_body_context

end
