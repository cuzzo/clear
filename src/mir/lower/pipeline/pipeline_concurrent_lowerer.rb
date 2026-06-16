# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "../../../ast/ast"
require_relative "../../../ast/symbol_entry"
require_relative "../../../ast/type"
require_relative "../../mir"
require_relative "../../cleanup_entry"
require_relative "../../fiber_ctx_builder"

PipelineConcurrentResult = T.type_alias { T.any(MIR::BlockExpr, MIR::ForStmt, MIR::ScopeBlock, MIR::ShardConcurrentEach) }
PipelineShardDirectContext = T.type_alias { T.nilable(T::Hash[Symbol, String]) }

class PipelineConcurrentBcExpression < T::Struct
  const :policy, Symbol
  const :expr, AST::Node
end

class PipelineConcurrentSourceKind < T::Enum
  enums do
    ShardEach = new("shard_each")
    BcMaterialized = new("bc_materialized")
    BoundedStream = new("bounded_stream")
    RuntimeStream = new("runtime_stream")
    RuntimeList = new("runtime_list")
  end
end

class PipelineConcurrentTerminalKind < T::Enum
  enums do
    Select = new("select")
    Where = new("where")
    Each = new("each")
    Count = new("count")
    Sum = new("sum")
    Average = new("average")
    Min = new("min")
    Max = new("max")
    Unsupported = new("unsupported")
  end
end

class PipelineConcurrentCallbackBodyKind < T::Enum
  enums do
    Expr = new("expr")
    Each = new("each")
  end
end

class PipelineConcurrentReduceKind < T::Enum
  enums do
    Sum = new("sum")
    Average = new("average")
    Min = new("min")
    Max = new("max")
  end
end

class PipelineConcurrentPlan < T::Struct
  const :source_kind, PipelineConcurrentSourceKind
  const :terminal_kind, PipelineConcurrentTerminalKind
  const :lhs, AST::Node
  const :real_lhs, AST::Node
  const :smooth_node, AST::BinaryOp
  const :conc_op, AST::ConcurrentOp
  const :inner, AST::Node
  const :binding_name, T.nilable(String)
  const :shard_context, T.nilable(AST::PipelineShardContext)
  const :bc_expression, T.nilable(PipelineConcurrentBcExpression)
  const :list_each_mutates_placeholder, T::Boolean
end

class PipelineConcurrentAllocationFact < T::Struct
  const :alloc, Symbol
  const :mark, MIR::AllocMark
  const :cleanup_entry, T.nilable(CleanupEntry)
end

class PipelineConcurrentHeadResult < T::Struct
  const :value, MIR::Node
  const :pending, T::Array[MIR::Emittable]
end

class PipelineConcurrentCallback < T::Struct
  const :id, Integer
  const :ctx_name, String
  const :ctx_def, MIR::StructDef
  const :ctx_var, String
  const :ctx_let, MIR::Let
  const :pre_ctx_stmts, T::Array[MIR::Emittable]
  const :post_ctx_stmts, T::Array[MIR::Emittable]
  const :apply_ident, MIR::Emittable
  const :context_arg, MIR::AddressOf
  const :context_stmts, T::Array[MIR::Emittable]
end

class PipelineConcurrentInvocation < T::Struct
  extend T::Sig

  const :id, Integer
  const :apply_ident, MIR::Emittable
  const :context_arg, MIR::AddressOf
  const :context_stmts, T::Array[MIR::Emittable]
  const :worker_count, MIR::Emittable
  const :batch_size, MIR::Emittable
  const :parallel, MIR::Emittable
  const :task_config, MIR::Emittable
  const :bounded_runtime_args, T::Array[MIR::Emittable]

  sig { params(source_pointer: MIR::Emittable, alive_filter: MIR::Emittable).returns(T::Array[MIR::Emittable]) }
  def sharded_each_args(source_pointer, alive_filter)
    [
      apply_ident,
      MIR::Ident.new("rt"),
      source_pointer,
      alive_filter,
      task_config,
      context_arg,
    ]
  end

  sig { params(source_pointer: MIR::Emittable).returns(T::Array[MIR::Emittable]) }
  def bounded_each_args(source_pointer)
    [
      apply_ident,
      MIR::Ident.new("rt"),
      source_pointer,
      *bounded_runtime_args,
    ]
  end

  sig { params(source_pointer: MIR::Emittable, alloc: Symbol).returns(T::Array[MIR::Emittable]) }
  def bounded_allocating_args(source_pointer, alloc)
    [
      apply_ident,
      MIR::AllocatorRef.new(alloc),
      MIR::Ident.new("rt"),
      source_pointer,
      *bounded_runtime_args,
    ]
  end

  sig { params(source_pointer: MIR::Emittable, capacity: MIR::Emittable, alloc: Symbol, is_inf: MIR::Emittable).returns(T::Array[MIR::Emittable]) }
  def stream_allocating_args(source_pointer, capacity, alloc, is_inf)
    [
      apply_ident,
      is_inf,
      MIR::AllocatorRef.new(alloc),
      MIR::Ident.new("rt"),
      source_pointer,
      worker_count,
      capacity,
      batch_size,
      parallel,
      task_config,
      context_arg,
    ]
  end

  sig { params(source_pointer: MIR::Emittable, capacity: MIR::Emittable, alloc: Symbol, is_inf: MIR::Emittable).returns(T::Array[MIR::Emittable]) }
  def stream_each_args(source_pointer, capacity, alloc, is_inf)
    [
      apply_ident,
      is_inf,
      MIR::AllocatorRef.new(alloc),
      MIR::Ident.new("rt"),
      source_pointer,
      worker_count,
      capacity,
      batch_size,
      parallel,
      task_config,
      context_arg,
    ]
  end

  sig { params(before_context: T::Array[MIR::Emittable], after_context: T::Array[MIR::Emittable]).returns(T::Array[MIR::Emittable]) }
  def scoped_body(before_context:, after_context:)
    [
      *before_context,
      *context_stmts,
      *after_context,
    ]
  end
end

class PipelineConcurrentSourcePointer < T::Struct
  const :setup, T::Array[MIR::Emittable]
  const :pointer, MIR::Emittable
end

class PipelineConcurrentLowerer < T::Struct
  extend T::Sig
  const :bc_target, T.proc.returns(T::Boolean)
  const :visit_mir, T.proc.params(node: AST::Node).returns(MIR::Node)
  const :visit_mir_with_placeholder, T.proc.params(node: AST::Node, placeholder: String).returns(MIR::Node)
  const :visit_body_with_placeholder, T.proc.params(body_stmts: T::Array[AST::Node], placeholder: String).returns(T::Array[MIR::Emittable])
  const :lower_head_with_placeholder, T.proc.params(node: AST::Node, placeholder: String).returns(PipelineConcurrentHeadResult)
  const :callback_expr_mir, T.proc.params(expr: AST::Node, placeholder: String, capture_map: T::Hash[String, String], capture_symbols: T::Hash[String, SymbolEntry], rt_override: String).returns(MIR::Node)
  const :callback_body_mir, T.proc.params(body_stmts: T::Array[AST::Node], placeholder: String, capture_map: T::Hash[String, String], capture_symbols: T::Hash[String, SymbolEntry], rt_override: String).returns(T::Array[MIR::Emittable])
  const :callback_body_mir_with_shard, T.proc.params(body_stmts: T::Array[AST::Node], placeholder: String, capture_map: T::Hash[String, String], capture_symbols: T::Hash[String, SymbolEntry], rt_override: String, shard_context: PipelineShardDirectContext).returns(T::Array[MIR::Emittable])
  const :pipeline_alloc_mark_fact, T.proc.params(value: MIR::Node, name: String, fallback_alloc: Symbol, type_info: Type, ast_node: AST::Node, accept_owned_call: T::Boolean, include_cleanup: T::Boolean).returns(T.nilable(PipelineConcurrentAllocationFact))
  const :append_ownership_transfers, T.proc.params(body: T::Array[MIR::Emittable]).returns(T::Array[MIR::Emittable])
  const :pipeline_block, T.proc.params(list_node: AST::Node, blk: T.proc.params(items: String, label: String).returns(T::Array[MIR::Emittable])).returns(MIR::BlockExpr)
  const :transpile_type, T.proc.params(type_name: String).returns(String)
  const :pipeline_alloc, T.proc.params(smooth_node: AST::BinaryOp).returns(Symbol)
  const :pipeline_result_alloc, T.proc.returns(Symbol)
  const :source_setup, T.proc.params(lhs: AST::Node).returns(T::Array[MIR::Emittable])
  const :emit_builtin, T.proc.params(name: Symbol, args: T::Array[MIR::Emittable]).returns(MIR::Node)
  const :lower_mir, T.proc.params(node: AST::Node).returns(MIR::Node)
  const :next_label, T.proc.returns(String)
  const :typed_block_expr, T.proc.params(label: String, body: T::Array[MIR::Emittable], result_type: Type).returns(MIR::BlockExpr)
  const :task_config_variant, T.proc.params(size_name: T.nilable(Symbol)).returns(String)
  const :guarded_cleanup_name, T.proc.params(name: String).returns(T::Boolean)
  const :do_rt_name, T.proc.returns(String)
  const :agg_min_sentinel_mir, T.proc.params(zig_type: String).returns(MIR::TypeSentinel)
  const :agg_max_sentinel_mir, T.proc.params(zig_type: String, result_type: Type).returns(T.any(MIR::Lit, MIR::TypeSentinel))
  const :lower_select, T.proc.params(lhs: AST::Node, smooth_node: AST::BinaryOp, inner_expr: AST::Node).returns(PipelineConcurrentResult)
  const :lower_where, T.proc.params(lhs: AST::Node, smooth_node: AST::BinaryOp, inner_expr: AST::Node).returns(PipelineConcurrentResult)
  const :lower_each, T.proc.params(lhs: AST::Node, smooth_node: AST::BinaryOp, inner: AST::EachOp).returns(PipelineConcurrentResult)
  const :lower_sum, T.proc.params(lhs: AST::Node, smooth_node: AST::BinaryOp, inner: AST::SumOp).returns(PipelineConcurrentResult)
  const :lower_count, T.proc.params(lhs: AST::Node, smooth_node: AST::BinaryOp, inner: AST::CountOp).returns(PipelineConcurrentResult)
  const :lower_min, T.proc.params(lhs: AST::Node, smooth_node: AST::BinaryOp, inner: AST::MinOp).returns(PipelineConcurrentResult)
  const :lower_max, T.proc.params(lhs: AST::Node, smooth_node: AST::BinaryOp, inner: AST::MaxOp).returns(PipelineConcurrentResult)
  const :lower_average, T.proc.params(lhs: AST::Node, smooth_node: AST::BinaryOp, inner: AST::AverageOp).returns(PipelineConcurrentResult)
  const :with_optional_named_binding, T.proc.params(clear_name: T.nilable(String), zig_var: String, blk: T.proc.returns(PipelineConcurrentResult)).returns(PipelineConcurrentResult)
  sig { params(smooth_node: AST::BinaryOp, conc_op: AST::ConcurrentOp).returns(PipelineConcurrentResult) }
  def lower(smooth_node, conc_op)
    lower_plan(concurrent_plan(smooth_node, conc_op))
  end

  private

  sig { params(smooth_node: AST::BinaryOp, conc_op: AST::ConcurrentOp).returns(PipelineConcurrentPlan) }
  def concurrent_plan(smooth_node, conc_op)
    lhs = T.cast(smooth_node.left, AST::Node)
    inner = T.cast(conc_op.op, AST::Node)
    binding_name, real_lhs = unwrap_binding_source(lhs)
    lhs_type = lhs.full_type!
    real_lhs_type = real_lhs.full_type!
    terminal_kind = concurrent_terminal_kind(inner)
    source_kind = concurrent_source_kind(lhs, real_lhs, lhs_type, real_lhs_type, conc_op)
    unsupported_concurrent_shape!(lhs, lhs_type, inner) unless source_kind

    PipelineConcurrentPlan.new(
      source_kind: source_kind,
      terminal_kind: terminal_kind,
      lhs: lhs,
      real_lhs: real_lhs,
      smooth_node: smooth_node,
      conc_op: conc_op,
      inner: inner,
      binding_name: binding_name,
      shard_context: shard_context(conc_op),
      bc_expression: bc_expression_for(terminal_kind, inner),
      list_each_mutates_placeholder: list_each_mutates_placeholder?(source_kind, terminal_kind, inner),
    )
  end

  sig { params(plan: PipelineConcurrentPlan).returns(PipelineConcurrentResult) }
  def lower_plan(plan)
    lower_source_plan(plan.source_kind, plan)
  end

  sig { params(source_kind: PipelineConcurrentSourceKind, plan: PipelineConcurrentPlan).returns(PipelineConcurrentResult) }
  def lower_source_plan(source_kind, plan)
    case source_kind
    when PipelineConcurrentSourceKind::ShardEach
      lower_shard_concurrent_each(plan.lhs, plan.conc_op, plan.smooth_node)
    when PipelineConcurrentSourceKind::BcMaterialized
      lower_bc_plan(plan)
    when PipelineConcurrentSourceKind::BoundedStream
      lower_bounded_stream_plan(plan)
    when PipelineConcurrentSourceKind::RuntimeStream
      lower_stream_plan(plan)
    when PipelineConcurrentSourceKind::RuntimeList
      lower_list_plan(plan)
    end
  end

  sig do
    params(
      lhs: AST::Node,
      real_lhs: AST::Node,
      lhs_type: Type,
      real_lhs_type: Type,
      conc_op: AST::ConcurrentOp,
    ).returns(T.nilable(PipelineConcurrentSourceKind))
  end
  def concurrent_source_kind(lhs, real_lhs, lhs_type, real_lhs_type, conc_op)
    return PipelineConcurrentSourceKind::ShardEach if shard_context(conc_op)
    return PipelineConcurrentSourceKind::BcMaterialized if self.bc_target.call && !stream_type?(lhs_type)
    return PipelineConcurrentSourceKind::BoundedStream if bounded_identifier_stream?(lhs)
    return PipelineConcurrentSourceKind::RuntimeStream if runtime_stream_source?(lhs, lhs_type)
    if !self.bc_target.call && (range_runtime_source?(real_lhs) || list_runtime_source?(real_lhs_type))
      return PipelineConcurrentSourceKind::RuntimeList
    end

    nil
  end

  sig { params(inner: AST::Node).returns(PipelineConcurrentTerminalKind) }
  def concurrent_terminal_kind(inner)
    case inner
    when AST::SelectOp then PipelineConcurrentTerminalKind::Select
    when AST::WhereOp then PipelineConcurrentTerminalKind::Where
    when AST::EachOp then PipelineConcurrentTerminalKind::Each
    when AST::CountOp then PipelineConcurrentTerminalKind::Count
    when AST::SumOp then PipelineConcurrentTerminalKind::Sum
    when AST::AverageOp then PipelineConcurrentTerminalKind::Average
    when AST::MinOp then PipelineConcurrentTerminalKind::Min
    when AST::MaxOp then PipelineConcurrentTerminalKind::Max
    else PipelineConcurrentTerminalKind::Unsupported
    end
  end

  sig { params(terminal_kind: PipelineConcurrentTerminalKind, inner: AST::Node).returns(T.nilable(PipelineConcurrentBcExpression)) }
  def bc_expression_for(terminal_kind, inner)
    case terminal_kind
    when PipelineConcurrentTerminalKind::Select
      bc_error_policy(T.cast(inner, AST::SelectOp).expression)
    when PipelineConcurrentTerminalKind::Where
      bc_error_policy(T.cast(inner, AST::WhereOp).expression)
    else
      nil
    end
  end

  sig { params(source_kind: PipelineConcurrentSourceKind, terminal_kind: PipelineConcurrentTerminalKind, inner: AST::Node).returns(T::Boolean) }
  def list_each_mutates_placeholder?(source_kind, terminal_kind, inner)
    return false unless source_kind == PipelineConcurrentSourceKind::RuntimeList
    return false unless terminal_kind == PipelineConcurrentTerminalKind::Each

    each_body_mutates_placeholder?(T.cast(inner, AST::EachOp).body)
  end

  sig { params(lhs: AST::Node, lhs_type: Type, inner: AST::Node).returns(T.noreturn) }
  def unsupported_concurrent_shape!(lhs, lhs_type, inner)
    raise "lower_concurrent: unsupported non-legacy CONCURRENT shape lhs=#{lhs.class} lhs_type=#{lhs_type.class} op=#{inner.class}"
  end

  public

  sig { params(list_node: AST::Node, each_op: AST::EachOp).returns(MIR::ScopeBlock) }
  def lower_sharded_each(list_node, each_op)
    lhs_type = list_node.full_type!
    item_t = Type.new(T.must(lhs_type.element_type).resolved)
    shard_count = T.must(lhs_type.shard_count)

    conc = AST::ConcurrentOp.new(each_op.token, each_op, {})
    AST.stamp_synthetic_type!(conc, each_op.full_type!(context: "sharded EACH result"), context: "synthetic AST type")
    cb = build_bounded_concurrent_callback_pointer(conc, item_t)
    invoke = bounded_invocation(conc, cb)

    source_mir = self.visit_mir.call(list_node)
    setup = if list_node.is_a?(AST::Identifier)
      [MIR::Let.new("__sh_each_src", MIR::AddressOf.new(source_mir), false, nil, nil)]
    else
      [
        MIR::Let.new("__sh_each_val", source_mir, true, nil, "_ = &__sh_each_val;"),
        MIR::Let.new("__sh_each_src", MIR::AddressOf.new(MIR::Ident.new("__sh_each_val")), false, nil, nil)
      ]
    end

    helper = lhs_type.pool? ? :concurrentShardedPoolEachInPlace : :concurrentShardedListEachInPlace
    call = self.emit_builtin.call(helper, [
      MIR::Ident.new(item_t.zig_type),
      MIR::Lit.new(shard_count.to_s),
      *invoke.sharded_each_args(MIR::Ident.new("__sh_each_src"), MIR::Lit.new("false")),
    ])

    MIR::ScopeBlock.new(invoke.scoped_body(
      before_context: [],
      after_context: [
        *setup,
      MIR::ExprStmt.new(call, false)
      ],
    ))
  end

  private

  sig { params(lhs: AST::Node, conc_op: AST::ConcurrentOp, smooth_node: AST::BinaryOp).returns(PipelineConcurrentResult) }
  def lower_shard_concurrent_each(lhs, conc_op, smooth_node)
    ctx = T.must(shard_context(conc_op))
    each_op = T.cast(conc_op.op, AST::EachOp)
    range_node = ctx.auto_detected ? T.cast(lhs, AST::RangeLit) : T.cast(T.cast(lhs, AST::BinaryOp).left, AST::RangeLit)

    id = self.numeric_label_id(self.next_label.call)
    idx_var = "__sh#{id}_i"
    key_var = "__sh#{id}_key"

    start_mir = self.visit_mir.call(T.cast(range_node.start, AST::Node))
    finish_mir = self.visit_mir.call(T.cast(range_node.finish, AST::Node))
    return lower_shard_concurrent_each_zig(ctx, each_op, conc_op, range_node, id, idx_var, key_var, start_mir, finish_mir) unless self.bc_target.call

    end_mir = finish_mir
    end_expr = range_node.inclusive ? MIR::BinOp.new("+", end_mir, MIR::Lit.new("1")) : end_mir

    head = self.lower_head_with_placeholder.call(ctx.key_expr, idx_var)
    body_mir = self.visit_body_with_placeholder.call(each_op.body, key_var)

    inner = T.let([], T::Array[MIR::Emittable])
    if ctx.key_allocates_frame
      inner.concat(shard_loop_mark_pair("__sh#{id}_loop_mark", self.do_rt_name.call))
    end
    inner.concat(head.pending)
    fact = self.pipeline_alloc_mark_fact.call(
      head.value,
      key_var,
      :heap,
      Type.from_node!(ctx.key_expr, context: "SHARD key binding"),
      ctx.key_expr,
      true,
      true,
    )
    if fact
      inner << fact.mark
      inner << MIR::Let.new(key_var, head.value, false, nil, nil)
      inner << MIR::Cleanup.new(key_var, fact.cleanup_entry) if fact.cleanup_entry
    else
      inner << MIR::Let.new(key_var, head.value, false, nil, nil)
    end
    inner.concat(body_mir)

    MIR::ForStmt.new(
      MIR::IterRange.new(start_mir, end_expr, :i64),
      idx_var,
      self.append_ownership_transfers.call(inner),
      nil,
    )
  end

  sig do
    params(
      ctx: AST::PipelineShardContext,
      each_op: AST::EachOp,
      conc_op: AST::ConcurrentOp,
      range_node: AST::RangeLit,
      id: Integer,
      idx_var: String,
      key_var: String,
      start_mir: MIR::Node,
      finish_mir: MIR::Node,
    ).returns(MIR::ShardConcurrentEach)
  end
  def lower_shard_concurrent_each_zig(ctx, each_op, conc_op, range_node, id, idx_var, key_var, start_mir, finish_mir)
    map_node = T.cast(ctx.map_var, AST::Identifier)
    map_var_name = map_node.name.to_s
    map_type = Type.from_node!(map_node, context: "SHARD target map")
    shard_count = ctx.shard_count || map_type.shard_count
    raise "SHARD target missing shard_count" unless shard_count

    key_type = shard_key_type(map_type)
    head = self.lower_head_with_placeholder.call(ctx.key_expr, idx_var)
    key_setup = T.let(head.pending.dup, T::Array[MIR::Emittable])
    key_cleanup = T.let([], T::Array[MIR::Emittable])
    key_fact = self.pipeline_alloc_mark_fact.call(
      head.value,
      key_var,
      :heap,
      Type.from_node!(ctx.key_expr, context: "SHARD key binding"),
      ctx.key_expr,
      true,
      true,
    )
    if key_fact
      key_setup << key_fact.mark
      key_cleanup << MIR::Cleanup.new(key_var, key_fact.cleanup_entry) if key_fact.cleanup_entry
    end
    producer_key_body = self.append_ownership_transfers.call([
      *key_setup,
      MIR::Let.new(key_var, head.value, false, key_type, nil),
      *key_cleanup,
    ])
    caps = FiberCtxBuilder.build(conc_op.capture_analysis, body_access_prefix: "ctx")
    capture_map = shard_capture_map(map_var_name, caps)
    body_mir = self.callback_body_mir_with_shard.call(
      each_op.body,
      key_var,
      capture_map,
      caps.capture_symbols,
      "__rt",
      shard_direct_context(map_var_name, key_var),
    )

    MIR::ShardConcurrentEach.new(
      id: id,
      map_expr: self.visit_mir.call(map_node),
      map_var_name: map_var_name,
      map_type: map_type,
      key_type: key_type,
      shard_count: shard_count,
      start_expr: start_mir,
      finish_expr: finish_mir,
      inclusive: range_node.inclusive,
      capacity_expr: stream_concurrent_capacity_mir(conc_op, MIR::Lit.new(shard_count.to_s)),
      batch_size_expr: bounded_concurrent_batch_mir(conc_op),
      task_config_variant: shard_task_config_variant(conc_op),
      producer_key_body: producer_key_body,
      capture_fields: shard_capture_fields(caps),
      capture_inits: shard_capture_inits(caps),
      capture_setup: shard_capture_setup(caps),
      body: self.append_ownership_transfers.call(body_mir),
      key_allocates_frame: ctx.key_allocates_frame,
      body_allocates_frame: ctx.body_allocates_frame,
    )
  end

  sig { params(lhs: AST::Node, inner_expr: AST::Node, smooth_node: AST::BinaryOp).returns(MIR::BlockExpr) }
  def lower_bc_concurrent_select_prune(lhs, inner_expr, smooth_node)
    res_zig = self.transpile_type.call(T.must(smooth_node.full_type!.element_type).resolved.to_s)
    alloc = self.pipeline_alloc.call(smooth_node)
    expr_mir = self.visit_mir_with_placeholder.call(inner_expr, "it")

    self.pipeline_block.call(lhs, lambda do |items, label|
      [
        MIR::Let.new("res_list",
          MIR::MakeList.new(res_zig, [], alloc), true, nil, nil),
        MIR::ForStmt.new(MIR::Ident.new(items), "it", [
          MIR::Let.new("__cv", expr_mir, false, nil, nil),
          MIR::IfStmt.new(MIR::UnaryOp.new("!",
            MIR::InlineBc.new(:is_error, [MIR::Ident.new("__cv")], { bc: true })), [
            MIR::ExprStmt.new(MIR::MethodCall.new(
              MIR::Ident.new("res_list"), "append",
              [MIR::AllocatorRef.new(alloc), MIR::Ident.new("__cv")], true,
              MIR::CallableContract.no_ownership(2)), nil)
          ], nil)
        ], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("res_list"))
      ]
    end)
  end

  sig { params(lhs: AST::Node, inner_expr: AST::Node, smooth_node: AST::BinaryOp).returns(MIR::BlockExpr) }
  def lower_bc_concurrent_where_prune(lhs, inner_expr, smooth_node)
    elem_type = T.must(lhs.full_type!.element_type).resolved.to_s
    elem_zig = self.transpile_type.call(elem_type)
    alloc = self.pipeline_alloc.call(smooth_node)
    pred_mir = self.visit_mir_with_placeholder.call(inner_expr, "it")

    self.pipeline_block.call(lhs, lambda do |items, label|
      [
        MIR::Let.new("res_list",
          MIR::MakeList.new(elem_zig, [], alloc), true, nil, nil),
        MIR::ForStmt.new(MIR::Ident.new(items), "it", [
          MIR::Let.new("__cv", pred_mir, false, nil, nil),
          MIR::IfStmt.new(MIR::BinOp.new("and",
            MIR::UnaryOp.new("!",
              MIR::InlineBc.new(:is_error, [MIR::Ident.new("__cv")], { bc: true })),
            MIR::Ident.new("__cv")), [
            MIR::ExprStmt.new(MIR::MethodCall.new(
              MIR::Ident.new("res_list"), "append",
              [MIR::AllocatorRef.new(alloc), MIR::Ident.new("it")], true,
              MIR::CallableContract.no_ownership(2)), nil)
          ], nil)
        ], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("res_list"))
      ]
    end)
  end

  sig { params(plan: PipelineConcurrentPlan).returns(PipelineConcurrentResult) }
  def lower_bounded_stream_plan(plan)
    lhs = T.cast(plan.lhs, AST::Identifier)
    lower_bounded_stream_terminal_plan(plan.terminal_kind, lhs, plan)
  end

  sig { params(terminal_kind: PipelineConcurrentTerminalKind, lhs: AST::Identifier, plan: PipelineConcurrentPlan).returns(PipelineConcurrentResult) }
  def lower_bounded_stream_terminal_plan(terminal_kind, lhs, plan)
    case terminal_kind
    when PipelineConcurrentTerminalKind::Select
      lower_concurrent_bounded_select(lhs, plan.conc_op, T.cast(plan.inner, AST::SelectOp))
    when PipelineConcurrentTerminalKind::Where
      lower_concurrent_bounded_where(lhs, plan.conc_op, T.cast(plan.inner, AST::WhereOp))
    when PipelineConcurrentTerminalKind::Each
      lower_concurrent_bounded_each(lhs, plan.conc_op, T.cast(plan.inner, AST::EachOp))
    else
      raise "CONCURRENT over bounded streams only supports SELECT/WHERE/EACH"
    end
  end

  sig { params(conc_op: AST::ConcurrentOp).returns(MIR::Emittable) }
  def bounded_concurrent_worker_count_mir(conc_op)
    workers = concurrent_option(conc_op, "workers")
    return self.visit_mir.call(workers) if workers

    MIR::RuntimeCall.new(MIR::RuntimeCalls.thread_count_spec, [])
  end

  sig { params(conc_op: AST::ConcurrentOp).returns(MIR::Cast) }
  def bounded_concurrent_worker_count_for_call_mir(conc_op)
    MIR::Cast.new(bounded_concurrent_worker_count_mir(conc_op), nil, :intCast)
  end

  sig { params(conc_op: AST::ConcurrentOp).returns(MIR::Emittable) }
  def bounded_concurrent_parallel_mir(conc_op)
    par = concurrent_option(conc_op, "parallel")
    par ? self.visit_mir.call(par) : MIR::Lit.new("false")
  end

  sig { params(conc_op: AST::ConcurrentOp).returns(MIR::Emittable) }
  def bounded_concurrent_batch_mir(conc_op)
    batch = concurrent_option(conc_op, "batch")
    return MIR::Lit.new("1") unless batch

    MIR::Cast.new(self.visit_mir.call(batch), nil, :intCast)
  end

  sig { params(conc_op: AST::ConcurrentOp).returns(MIR::StructInit) }
  def bounded_concurrent_task_cfg_mir(conc_op)
    size_node = concurrent_option(conc_op, "size")
    size_name = size_node.is_a?(AST::Identifier) ? size_node.name.downcase.to_sym : nil
    MIR::StructInit.new(nil, [
      MIR.named_field("stack_size", MIR::EnumTag.new(variant: self.task_config_variant.call(size_name))),
    ])
  end

  sig { params(conc_op: AST::ConcurrentOp, item_type: Type, return_type: T.any(Type, Symbol), body_kind: PipelineConcurrentCallbackBodyKind).returns(PipelineConcurrentCallback) }
  def build_bounded_concurrent_callback(conc_op, item_type, return_type, body_kind)
    id = self.numeric_label_id(self.next_label.call)
    ctx_name = "__BoundedConcurrentCtx#{id}"
    caps = FiberCtxBuilder.build(conc_op.capture_analysis, body_access_prefix: "ctx")
    specs = caps.specs
    capture_map = caps.capture_map
    capture_symbols = caps.capture_symbols

    fields = specs.map { |s| capture_field_def(s, capture_symbols) }
    raw_ctx = MIR::Param.new("raw_ctx", "?*anyopaque", false)
    params = T.let([
      MIR::Param.new("__rt", "*Runtime", false),
      raw_ctx,
      MIR::Param.new("__item", Type.new(item_type).zig_type, false),
    ], T::Array[MIR::Param])

    body = callback_prelude(specs)
    if self.bc_target.call
      specs.each do |spec|
        body << MIR::Let.new(spec.name,
          MIR::FieldGet.new(MIR::Ident.new("ctx"), spec.name),
          true, nil, nil)
      end
    end

    ret_type = Type.new(return_type)
    body.concat(callback_body(conc_op, body_kind, ret_type, capture_map, capture_symbols))

    fn = MIR::FnDef.new("apply", params, ret_type.zig_type, body, nil, true, nil)
    callback_record(id, ctx_name, fields, fn, specs)
  end

  sig { params(lhs: AST::Identifier, _id: Integer).returns(PipelineConcurrentSourcePointer) }
  def bounded_stream_items_setup(lhs, _id)
    source = self.visit_mir.call(lhs)
    PipelineConcurrentSourcePointer.new(
      setup: [],
      pointer: MIR::AddressOf.new(MIR::FieldGet.new(source, "items")),
    )
  end

  sig { params(lhs: AST::Identifier).returns(T::Array[MIR::Emittable]) }
  def bounded_stream_source_move(lhs)
    name = lhs.name.to_s
    return [] unless self.guarded_cleanup_name.call(name)

    MIR::OwnershipTransferPlan.new(
      name: name,
      target: :owned_sink,
      target_alloc: :heap,
      move_guarded: true,
    ).marks
  end

  sig do
    params(
      label: String,
      result_var: String,
      result_type: Type,
      source: PipelineConcurrentSourcePointer,
      call: MIR::Emittable,
      source_move: T::Array[MIR::Emittable],
    ).returns(T::Array[MIR::Emittable])
  end
  def bounded_result_break_stmts(label, result_var, result_type, source, call, source_move)
    return [*source.setup, MIR::BreakStmt.new(label, call)] if source_move.empty?

    [
      *source.setup,
      MIR::Let.new(result_var, call, false, result_type, nil),
      *source_move,
      MIR::BreakStmt.new(label, MIR::Ident.new(result_var)),
    ]
  end

  sig { params(lhs: AST::Identifier, conc_op: AST::ConcurrentOp, inner: AST::SelectOp).returns(MIR::BlockExpr) }
  def lower_concurrent_bounded_select(lhs, conc_op, inner)
    item_t = T.must(lhs.full_type!.stream_element_type)
    result_t = Type.new(inner.expression.full_type!)
    invoke = bounded_expr_invocation(conc_op, item_t, result_t)
    source = bounded_stream_items_setup(lhs, invoke.id)
    source_move = bounded_stream_source_move(lhs)

    call = self.emit_builtin.call(:concurrentBoundedSelect, [
      MIR::Ident.new(item_t.zig_type),
      MIR::Ident.new(result_t.zig_type),
      MIR::Lit.new(lhs.full_type!.stream_capacity.to_s),
      *invoke.bounded_allocating_args(source.pointer, self.pipeline_result_alloc.call),
    ])

    label = self.next_label.call
    result_type = Type.from_node!(conc_op, context: "bounded concurrent SELECT result")
    self.typed_block_expr.call(label, invoke.scoped_body(
      before_context: [],
      after_context: bounded_result_break_stmts(label, "__bounded_select_result_#{numeric_label_id(label)}",
        result_type, source, call, source_move),
    ), result_type)
  end

  sig { params(lhs: AST::Identifier, conc_op: AST::ConcurrentOp, _inner: AST::WhereOp).returns(MIR::BlockExpr) }
  def lower_concurrent_bounded_where(lhs, conc_op, _inner)
    item_t = T.must(lhs.full_type!.stream_element_type)
    invoke = bounded_expr_invocation(conc_op, item_t, Type.new(:Bool))
    source = bounded_stream_items_setup(lhs, invoke.id)
    source_move = bounded_stream_source_move(lhs)

    call = self.emit_builtin.call(:concurrentBoundedWhere, [
      MIR::Ident.new(item_t.zig_type),
      MIR::Lit.new(lhs.full_type!.stream_capacity.to_s),
      *invoke.bounded_allocating_args(source.pointer, self.pipeline_result_alloc.call),
    ])

    label = self.next_label.call
    result_type = Type.from_node!(conc_op, context: "bounded concurrent WHERE result")
    self.typed_block_expr.call(label, invoke.scoped_body(
      before_context: [],
      after_context: bounded_result_break_stmts(label, "__bounded_where_result_#{numeric_label_id(label)}",
        result_type, source, call, source_move),
    ), result_type)
  end

  sig { params(lhs: AST::Identifier, conc_op: AST::ConcurrentOp, _inner: AST::EachOp).returns(MIR::ScopeBlock) }
  def lower_concurrent_bounded_each(lhs, conc_op, _inner)
    item_t = T.must(lhs.full_type!.stream_element_type)
    invoke = bounded_each_invocation(conc_op, item_t)
    source = bounded_stream_items_setup(lhs, invoke.id)
    source_move = bounded_stream_source_move(lhs)

    call = self.emit_builtin.call(:concurrentBoundedEach, [
      MIR::Ident.new(item_t.zig_type),
      MIR::Lit.new(lhs.full_type!.stream_capacity.to_s),
      *invoke.bounded_each_args(source.pointer),
    ])

    MIR::ScopeBlock.new(invoke.scoped_body(
      before_context: [],
	      after_context: [
	        *source.setup,
	        MIR::ExprStmt.new(call, false),
	        *source_move,
	      ],
	    ))
	  end

  sig { params(plan: PipelineConcurrentPlan).returns(PipelineConcurrentResult) }
  def lower_bc_plan(plan)
    work = lambda do
      lower_bc_terminal_plan(plan.terminal_kind, plan)
    end

    lower_with_optional_binding(plan.binding_name, "it", work)
  end

  sig { params(binding_name: T.nilable(String), item_name: String, work: T.proc.returns(PipelineConcurrentResult)).returns(PipelineConcurrentResult) }
  def lower_with_optional_binding(binding_name, item_name, work)
    return self.with_optional_named_binding.call(binding_name, item_name, work) if binding_name

    work.call
  end

  sig { params(terminal_kind: PipelineConcurrentTerminalKind, plan: PipelineConcurrentPlan).returns(PipelineConcurrentResult) }
  def lower_bc_terminal_plan(terminal_kind, plan)
    case terminal_kind
    when PipelineConcurrentTerminalKind::Select
      expr = T.must(plan.bc_expression)
      lower_bc_select_expression(expr.policy, expr, plan)
    when PipelineConcurrentTerminalKind::Where
      expr = T.must(plan.bc_expression)
      lower_bc_where_expression(expr.policy, expr, plan)
    when PipelineConcurrentTerminalKind::Each
      self.lower_each.call(plan.real_lhs, plan.smooth_node, T.cast(plan.inner, AST::EachOp))
    when PipelineConcurrentTerminalKind::Sum
      self.lower_sum.call(plan.real_lhs, plan.smooth_node, T.cast(plan.inner, AST::SumOp))
    when PipelineConcurrentTerminalKind::Count
      self.lower_count.call(plan.real_lhs, plan.smooth_node, T.cast(plan.inner, AST::CountOp))
    when PipelineConcurrentTerminalKind::Min
      self.lower_min.call(plan.real_lhs, plan.smooth_node, T.cast(plan.inner, AST::MinOp))
    when PipelineConcurrentTerminalKind::Max
      self.lower_max.call(plan.real_lhs, plan.smooth_node, T.cast(plan.inner, AST::MaxOp))
    when PipelineConcurrentTerminalKind::Average
      self.lower_average.call(plan.real_lhs, plan.smooth_node, T.cast(plan.inner, AST::AverageOp))
    else
      raise "lower_concurrent_bc: unsupported inner op #{plan.inner.class}"
    end
  end

  sig { params(policy: Symbol, expr: PipelineConcurrentBcExpression, plan: PipelineConcurrentPlan).returns(PipelineConcurrentResult) }
  def lower_bc_select_expression(policy, expr, plan)
    return lower_bc_concurrent_select_prune(plan.real_lhs, expr.expr, plan.smooth_node) if policy == :prune

    self.lower_select.call(plan.real_lhs, plan.smooth_node, expr.expr)
  end

  sig { params(policy: Symbol, expr: PipelineConcurrentBcExpression, plan: PipelineConcurrentPlan).returns(PipelineConcurrentResult) }
  def lower_bc_where_expression(policy, expr, plan)
    return lower_bc_concurrent_where_prune(plan.real_lhs, expr.expr, plan.smooth_node) if policy == :prune

    self.lower_where.call(plan.real_lhs, plan.smooth_node, expr.expr)
  end

  sig { params(expr: AST::Node).returns(PipelineConcurrentBcExpression) }
  def bc_error_policy(expr)
    return default_bc_expression(expr) unless expr.is_a?(AST::BinaryOp) && expr.op == :OR_RESCUE

    policy = bc_rescue_policy(T.cast(expr.right, AST::Node))
    return default_bc_expression(expr) unless policy

    PipelineConcurrentBcExpression.new(policy: policy, expr: T.cast(expr.left, AST::Node))
  end

  sig { params(expr: AST::Node).returns(PipelineConcurrentBcExpression) }
  def default_bc_expression(expr)
    PipelineConcurrentBcExpression.new(policy: :default, expr: expr)
  end

  sig { params(expr: AST::Node).returns(T.nilable(Symbol)) }
  def bc_rescue_policy(expr)
    case expr
    when AST::OrPrune then :prune
    when AST::OrRaise then :raise
    end
  end

  sig { params(plan: PipelineConcurrentPlan).returns(PipelineConcurrentResult) }
  def lower_stream_plan(plan)
    lhs = T.cast(plan.lhs, AST::Identifier)
    lower_stream_terminal_plan(plan.terminal_kind, lhs, plan)
  end

  sig { params(terminal_kind: PipelineConcurrentTerminalKind, lhs: AST::Identifier, plan: PipelineConcurrentPlan).returns(PipelineConcurrentResult) }
  def lower_stream_terminal_plan(terminal_kind, lhs, plan)
    case terminal_kind
    when PipelineConcurrentTerminalKind::Select
      lower_concurrent_stream_select(lhs, plan.conc_op, T.cast(plan.inner, AST::SelectOp))
    when PipelineConcurrentTerminalKind::Where
      lower_concurrent_stream_where(lhs, plan.conc_op, T.cast(plan.inner, AST::WhereOp))
    when PipelineConcurrentTerminalKind::Each
      lower_concurrent_stream_each(lhs, plan.conc_op, T.cast(plan.inner, AST::EachOp))
    else
      unsupported_concurrent_shape!(plan.lhs, plan.lhs.full_type!, plan.inner)
    end
  end

  sig { params(plan: PipelineConcurrentPlan).returns(PipelineConcurrentResult) }
  def lower_list_plan(plan)
    work = lambda do
      lower_list_terminal_plan(plan.terminal_kind, plan)
    end

    lower_with_optional_binding(plan.binding_name, "__item", work)
  end

  sig { params(terminal_kind: PipelineConcurrentTerminalKind, plan: PipelineConcurrentPlan).returns(PipelineConcurrentResult) }
  def lower_list_terminal_plan(terminal_kind, plan)
    case terminal_kind
    when PipelineConcurrentTerminalKind::Select
      lower_concurrent_list_select(plan.real_lhs, plan.conc_op, T.cast(plan.inner, AST::SelectOp))
    when PipelineConcurrentTerminalKind::Where
      lower_concurrent_list_where(plan.real_lhs, plan.conc_op, T.cast(plan.inner, AST::WhereOp))
    when PipelineConcurrentTerminalKind::Count
      lower_concurrent_list_count(plan.real_lhs, plan.conc_op, T.cast(plan.inner, AST::CountOp))
    when PipelineConcurrentTerminalKind::Sum, PipelineConcurrentTerminalKind::Average,
         PipelineConcurrentTerminalKind::Min, PipelineConcurrentTerminalKind::Max
      lower_concurrent_list_reduce(plan.real_lhs, plan.conc_op, T.cast(plan.inner, T.any(AST::AverageOp, AST::MaxOp, AST::MinOp, AST::SumOp)), plan.smooth_node)
    when PipelineConcurrentTerminalKind::Each
      each_op = T.cast(plan.inner, AST::EachOp)
      lower_list_each_terminal(plan.list_each_mutates_placeholder, plan.real_lhs, plan.conc_op, each_op)
    else
      raise "lower_concurrent: unsupported list CONCURRENT op #{plan.inner.class}"
    end
  end

  sig { params(mutates_placeholder: T::Boolean, lhs: AST::Node, conc_op: AST::ConcurrentOp, each_op: AST::EachOp).returns(MIR::ScopeBlock) }
  def lower_list_each_terminal(mutates_placeholder, lhs, conc_op, each_op)
    return lower_concurrent_list_each_in_place(lhs, conc_op, each_op) if mutates_placeholder

    lower_concurrent_list_each(lhs, conc_op, each_op)
  end

  sig { params(lhs: AST::Node, lhs_type: Type).returns(T::Boolean) }
  def runtime_stream_source?(lhs, lhs_type)
    return false if lhs.is_a?(AST::RangeLit)

    lhs_type.dynamic_stream? || lhs_type.open_stream? || lhs_type.inf_stream?
  end

  sig { params(lhs_ti: Type).returns(Type) }
  def stream_concurrent_element_type(lhs_ti)
    if lhs_ti.inf_stream?
      T.must(lhs_ti.inf_stream_element_type)
    elsif lhs_ti.open_stream?
      T.must(lhs_ti.open_stream_element_type)
    else
      Type.new(T.must(lhs_ti.tense_type.element_type).resolved)
    end
  end

  sig { params(lhs: AST::Identifier, id: Integer).returns(PipelineConcurrentSourcePointer) }
  def stream_concurrent_source_setup_mir(lhs, id)
    src = self.visit_mir.call(lhs)
    PipelineConcurrentSourcePointer.new(setup: [], pointer: MIR::AddressOf.new(src))
  end

  sig { params(conc_op: AST::ConcurrentOp, worker_count: MIR::Emittable).returns(MIR::Expr) }
  def stream_concurrent_capacity_mir(conc_op, worker_count)
    cap_node = concurrent_option(conc_op, "capacity")
    return MIR::DefaultStreamCapacity.new(worker_count) unless cap_node

    MIR::Cast.new(self.lower_mir.call(cap_node), nil, :intCast)
  end

  sig { params(lhs: AST::Identifier, conc_op: AST::ConcurrentOp, inner: AST::SelectOp).returns(MIR::BlockExpr) }
  def lower_concurrent_stream_select(lhs, conc_op, inner)
    lhs_ti = lhs.full_type!
    item_t = stream_concurrent_element_type(lhs_ti)
    result_t = Type.new(inner.expression.full_type!)
    invoke = bounded_expr_invocation(conc_op, item_t, result_t)
    source = stream_concurrent_source_setup_mir(lhs, invoke.id)
    n_workers_mir = bounded_concurrent_worker_count_mir(conc_op)
    capacity = stream_concurrent_capacity_mir(conc_op, n_workers_mir)

    call = self.emit_builtin.call(:concurrentStreamSelect, [
      MIR::Ident.new(item_t.zig_type),
      MIR::Ident.new(result_t.zig_type),
      *invoke.stream_allocating_args(
        source.pointer,
        capacity,
        self.pipeline_result_alloc.call,
        MIR::Lit.new(lhs_ti.inf_stream? ? "true" : "false"),
      ),
    ])

    label = self.next_label.call
    self.typed_block_expr.call(label, invoke.scoped_body(
      before_context: [],
      after_context: [
        *source.setup,
        MIR::BreakStmt.new(label, call),
      ],
    ), Type.from_node!(conc_op, context: "stream concurrent SELECT result"))
  end

  sig { params(lhs: AST::Identifier, conc_op: AST::ConcurrentOp, inner: AST::WhereOp).returns(MIR::BlockExpr) }
  def lower_concurrent_stream_where(lhs, conc_op, inner)
    lhs_ti = lhs.full_type!
    item_t = stream_concurrent_element_type(lhs_ti)
    invoke = bounded_expr_invocation(conc_op, item_t, Type.new(:Bool))
    source = stream_concurrent_source_setup_mir(lhs, invoke.id)
    n_workers_mir = bounded_concurrent_worker_count_mir(conc_op)
    capacity = stream_concurrent_capacity_mir(conc_op, n_workers_mir)

    call = self.emit_builtin.call(:concurrentStreamWhere, [
      MIR::Ident.new(item_t.zig_type),
      *invoke.stream_allocating_args(
        source.pointer,
        capacity,
        self.pipeline_result_alloc.call,
        MIR::Lit.new(lhs_ti.inf_stream? ? "true" : "false"),
      ),
    ])

    label = self.next_label.call
    self.typed_block_expr.call(label, invoke.scoped_body(
      before_context: [],
      after_context: [
        *source.setup,
        MIR::BreakStmt.new(label, call),
      ],
    ), Type.from_node!(conc_op, context: "stream concurrent WHERE result"))
  end

  sig { params(lhs: AST::Identifier, conc_op: AST::ConcurrentOp, inner: AST::EachOp).returns(MIR::ScopeBlock) }
  def lower_concurrent_stream_each(lhs, conc_op, inner)
    lhs_ti = lhs.full_type!
    item_t = stream_concurrent_element_type(lhs_ti)
    invoke = bounded_each_invocation(conc_op, item_t)
    source = stream_concurrent_source_setup_mir(lhs, invoke.id)
    n_workers_mir = bounded_concurrent_worker_count_mir(conc_op)
    capacity = stream_concurrent_capacity_mir(conc_op, n_workers_mir)

    call = self.emit_builtin.call(:concurrentStreamEach, [
      MIR::Ident.new(item_t.zig_type),
      *invoke.stream_each_args(
        source.pointer,
        capacity,
        self.pipeline_result_alloc.call,
        MIR::Lit.new(lhs_ti.inf_stream? ? "true" : "false"),
      ),
    ])

    MIR::ScopeBlock.new(invoke.scoped_body(
      before_context: [],
      after_context: [
        *source.setup,
        MIR::ExprStmt.new(call, false),
      ],
    ))
  end

  sig { params(lhs: AST::Node).returns(Type) }
  def concurrent_list_item_type(lhs)
    if lhs.is_a?(AST::RangeLit)
      elem = lhs.full_type!.tense_type&.element_type&.resolved ||
        T.cast(lhs.start, AST::Node).full_type!
      return Type.new(elem)
    end

    Type.new(T.must(lhs.full_type!.element_type).resolved)
  end

  sig { params(lhs: AST::Node, conc_op: AST::ConcurrentOp, inner: AST::SelectOp).returns(MIR::BlockExpr) }
  def lower_concurrent_list_select(lhs, conc_op, inner)
    item_t = concurrent_list_item_type(lhs)
    result_t = Type.new(inner.expression.full_type!)
    invoke = bounded_expr_invocation(conc_op, item_t, result_t)
    setup_stmts = self.source_setup.call(lhs)

    call = self.emit_builtin.call(:concurrentListSelect, [
      MIR::Ident.new(item_t.zig_type),
      MIR::Ident.new(result_t.zig_type),
      *invoke.bounded_allocating_args(MIR::Ident.new("pipe_items"), self.pipeline_result_alloc.call),
    ])

    label = self.next_label.call
    self.typed_block_expr.call(label, invoke.scoped_body(
      before_context: setup_stmts,
      after_context: [MIR::BreakStmt.new(label, call)],
    ), Type.from_node!(conc_op, context: "list concurrent SELECT result"))
  end

  sig { params(lhs: AST::Node, conc_op: AST::ConcurrentOp, inner: AST::WhereOp).returns(MIR::BlockExpr) }
  def lower_concurrent_list_where(lhs, conc_op, inner)
    item_t = concurrent_list_item_type(lhs)
    invoke = bounded_expr_invocation(conc_op, item_t, Type.new(:Bool))
    setup_stmts = self.source_setup.call(lhs)

    call = self.emit_builtin.call(:concurrentListWhere, [
      MIR::Ident.new(item_t.zig_type),
      *invoke.bounded_allocating_args(MIR::Ident.new("pipe_items"), self.pipeline_result_alloc.call),
    ])

    label = self.next_label.call
    self.typed_block_expr.call(label, invoke.scoped_body(
      before_context: setup_stmts,
      after_context: [MIR::BreakStmt.new(label, call)],
    ), Type.from_node!(conc_op, context: "list concurrent WHERE result"))
  end

  sig { params(lhs: AST::Node, conc_op: AST::ConcurrentOp, inner: AST::CountOp).returns(MIR::BlockExpr) }
  def lower_concurrent_list_count(lhs, conc_op, inner)
    item_t = concurrent_list_item_type(lhs)
    invoke = bounded_expr_invocation(conc_op, item_t, Type.new(:Bool))
    setup_stmts = self.source_setup.call(lhs)

    call = self.emit_builtin.call(:concurrentListCount, [
      MIR::Ident.new(item_t.zig_type),
      *invoke.bounded_each_args(MIR::Ident.new("pipe_items")),
    ])

    label = self.next_label.call
    self.typed_block_expr.call(label, invoke.scoped_body(
      before_context: setup_stmts,
      after_context: [MIR::BreakStmt.new(label, call)],
    ), Type.from_node!(conc_op, context: "list concurrent COUNT result"))
  end

  sig { params(lhs: AST::Node, conc_op: AST::ConcurrentOp, inner: T.any(AST::AverageOp, AST::MaxOp, AST::MinOp, AST::SumOp), smooth_node: AST::BinaryOp).returns(MIR::BlockExpr) }
  def lower_concurrent_list_reduce(lhs, conc_op, inner, smooth_node)
    item_t = concurrent_list_item_type(lhs)
    result_t = Type.new(smooth_node.full_type!)
    result_zig = result_t.zig_type
    kind = list_reduce_kind(inner)
    initial = list_reduce_initial(kind, result_zig, result_t)
    invoke = bounded_expr_invocation(conc_op, item_t, result_t)
    setup_stmts = self.source_setup.call(lhs)

    call = self.emit_builtin.call(:concurrentListReduce, [
      MIR::Ident.new(item_t.zig_type),
      MIR::Ident.new(result_zig),
      *invoke.bounded_each_args(MIR::Ident.new("pipe_items")),
      initial,
      MIR::EnumTag.new(variant: kind.serialize),
    ])

    label = self.next_label.call
    self.typed_block_expr.call(label, invoke.scoped_body(
      before_context: setup_stmts,
      after_context: [MIR::BreakStmt.new(label, call)],
    ), result_t)
  end

  sig { params(lhs: AST::Node, conc_op: AST::ConcurrentOp, inner: AST::EachOp).returns(MIR::ScopeBlock) }
  def lower_concurrent_list_each(lhs, conc_op, inner)
    item_t = concurrent_list_item_type(lhs)
    invoke = bounded_each_invocation(conc_op, item_t)
    setup_stmts = self.source_setup.call(lhs)

    call = self.emit_builtin.call(:concurrentListEach, [
      MIR::Ident.new(item_t.zig_type),
      *invoke.bounded_each_args(MIR::Ident.new("pipe_items")),
    ])

    MIR::ScopeBlock.new(invoke.scoped_body(
      before_context: setup_stmts,
      after_context: [MIR::ExprStmt.new(call, false)],
    ))
  end

  sig { params(lhs: AST::Node, conc_op: AST::ConcurrentOp, inner: AST::EachOp).returns(MIR::ScopeBlock) }
  def lower_concurrent_list_each_in_place(lhs, conc_op, inner)
    item_t = concurrent_list_item_type(lhs)
    invoke = bounded_pointer_invocation(conc_op, item_t)
    setup_stmts = self.source_setup.call(lhs)

    call = self.emit_builtin.call(:concurrentListEachInPlace, [
      MIR::Ident.new(item_t.zig_type),
      *invoke.bounded_each_args(MIR::ConstCast.new(MIR::Ident.new("pipe_items"))),
    ])

    MIR::ScopeBlock.new(invoke.scoped_body(
      before_context: setup_stmts,
      after_context: [MIR::ExprStmt.new(call, false)],
    ))
  end

  sig { params(conc_op: AST::ConcurrentOp, item_type: Type).returns(PipelineConcurrentCallback) }
  def build_bounded_concurrent_callback_pointer(conc_op, item_type)
    id = self.numeric_label_id(self.next_label.call)
    ctx_name = "__BoundedConcurrentCtx#{id}"
    caps = FiberCtxBuilder.build(conc_op.capture_analysis, body_access_prefix: "ctx")
    specs = caps.specs
    capture_map = caps.capture_map
    capture_symbols = caps.capture_symbols

    fields = specs.map { |s| capture_field_def(s, capture_symbols) }
    raw_ctx = MIR::Param.new("raw_ctx", "?*anyopaque", false)
    params = T.let([
      MIR::Param.new("__rt", "*Runtime", false),
      raw_ctx,
      MIR::Param.new("__item", "*#{Type.new(item_type).zig_type}", false),
    ], T::Array[MIR::Param])

    body = callback_prelude(specs)
    body.concat(self.callback_body_mir.call(
      T.cast(conc_op.op, AST::EachOp).body,
      "__item",
      capture_map,
      capture_symbols,
      "__rt",
    ))
    body << MIR::ReturnStmt.new(nil)

    fn = MIR::FnDef.new("apply", params, "void", body, nil, true, nil)
    callback_record(id, ctx_name, fields, fn, specs)
  end

  sig { params(lhs: AST::Node).returns([T.nilable(String), AST::Node]) }
  def unwrap_binding_source(lhs)
    if lhs.is_a?(AST::BinaryOp) && lhs.op == :BIND_VAR
      [T.cast(lhs.right, AST::Identifier).name, T.cast(lhs.left, AST::Node)]
    else
      [nil, lhs]
    end
  end

  sig { params(lhs: AST::Node).returns(T::Boolean) }
  def bounded_identifier_stream?(lhs)
    !lhs.is_a?(AST::RangeLit) && lhs.is_a?(AST::Identifier) && lhs.full_type!.bounded_stream?
  end

  sig { params(type_info: Type).returns(T::Boolean) }
  def stream_type?(type_info)
    type_info.dynamic_stream? || type_info.bounded_stream? ||
      type_info.open_stream? || type_info.inf_stream?
  end

  sig { params(lhs: AST::Node).returns(T::Boolean) }
  def range_runtime_source?(lhs)
    lhs.is_a?(AST::RangeLit)
  end

  sig { params(lhs_type: Type).returns(T::Boolean) }
  def list_runtime_source?(lhs_type)
    return false if stream_type?(lhs_type)

    !lhs_type.element_type.nil?
  end

  sig { params(conc_op: AST::ConcurrentOp).returns(T.nilable(AST::PipelineShardContext)) }
  def shard_context(conc_op)
    T.cast(conc_op.shard_context, T.nilable(AST::PipelineShardContext))
  end

  sig { params(map_type: Type).returns(Type) }
  def shard_key_type(map_type)
    return map_type.key_type if map_type.numeric_map?

    Type.new(:String)
  end

  sig { params(map_var_name: String, caps: FiberCtxBuilder::Result).returns(T::Hash[String, String]) }
  def shard_capture_map(map_var_name, caps)
    caps.capture_map.merge(map_var_name => "ctx.__shard_map.*")
  end

  sig { params(map_var_name: String, key_var: String).returns(T::Hash[Symbol, String]) }
  def shard_direct_context(map_var_name, key_var)
    {
      map: map_var_name,
      idx: "ctx.shard",
      key: key_var,
      hash: "0",
    }
  end

  sig { params(caps: FiberCtxBuilder::Result).returns(T::Array[MIR::ContextFieldDecl]) }
  def shard_capture_fields(caps)
    caps.specs.flat_map do |spec|
      fields = T.let([
        MIR::ContextFieldDecl.new(name: spec.name, type_zig: spec.field_type_zig),
      ], T::Array[MIR::ContextFieldDecl])
      if spec.needs_moved_guard?
        fields << MIR::ContextFieldDecl.new(
          name: "#{spec.name}_moved",
          type_zig: "bool",
          default_value: MIR::Lit.new("false"),
        )
      end
      fields
    end
  end

  sig { params(caps: FiberCtxBuilder::Result).returns(T::Array[MIR::StructInitField]) }
  def shard_capture_inits(caps)
    caps.specs.map { |spec| MIR::StructInitField.new(name: spec.name, value: spec.init_value_mir) }
  end

  sig { params(caps: FiberCtxBuilder::Result).returns(T::Array[MIR::Emittable]) }
  def shard_capture_setup(caps)
    caps.specs.flat_map(&:setup_mir)
  end

  sig { params(conc_op: AST::ConcurrentOp).returns(String) }
  def shard_task_config_variant(conc_op)
    size_node = concurrent_option(conc_op, "size")
    size_name = size_node.is_a?(AST::Identifier) ? size_node.name.downcase.to_sym : nil
    self.task_config_variant.call(size_name)
  end

  sig { params(conc_op: AST::ConcurrentOp, key: String).returns(T.nilable(AST::Node)) }
  def concurrent_option(conc_op, key)
    T.cast(conc_op.options[key], T.nilable(AST::Node))
  end

  sig { params(var: String, rt: String).returns(T::Array[MIR::Emittable]) }
  def shard_loop_mark_pair(var, rt)
    rt_ident = MIR::Ident.new(rt)
    [
      MIR::Let.new(var, MIR::MethodCall.new(rt_ident, "saveLoopMark", [], false, MIR::CallableContract.no_ownership(0)), false, nil, nil),
      MIR::DeferStmt.new(MIR::MethodCall.new(rt_ident, "restoreLoopMark", [MIR::Ident.new(var)], false, MIR::CallableContract.no_ownership(1))),
    ]
  end

  sig { params(conc_op: AST::ConcurrentOp, cb: PipelineConcurrentCallback).returns(PipelineConcurrentInvocation) }
  def bounded_invocation(conc_op, cb)
    worker_count = bounded_concurrent_worker_count_for_call_mir(conc_op)
    batch_size = bounded_concurrent_batch_mir(conc_op)
    parallel = bounded_concurrent_parallel_mir(conc_op)
    task_config = bounded_concurrent_task_cfg_mir(conc_op)
    PipelineConcurrentInvocation.new(
      id: cb.id,
      apply_ident: cb.apply_ident,
      context_arg: cb.context_arg,
      context_stmts: cb.context_stmts,
      worker_count: worker_count,
      batch_size: batch_size,
      parallel: parallel,
      task_config: task_config,
      bounded_runtime_args: [
        worker_count,
        batch_size,
        parallel,
        task_config,
        cb.context_arg,
      ],
    )
  end

  sig { params(conc_op: AST::ConcurrentOp, item_type: Type, return_type: T.any(Type, Symbol)).returns(PipelineConcurrentInvocation) }
  def bounded_expr_invocation(conc_op, item_type, return_type)
    bounded_invocation(conc_op, build_bounded_concurrent_callback(conc_op, item_type, return_type, PipelineConcurrentCallbackBodyKind::Expr))
  end

  sig { params(conc_op: AST::ConcurrentOp, item_type: Type).returns(PipelineConcurrentInvocation) }
  def bounded_each_invocation(conc_op, item_type)
    bounded_invocation(conc_op, build_bounded_concurrent_callback(conc_op, item_type, :Void, PipelineConcurrentCallbackBodyKind::Each))
  end

  sig { params(conc_op: AST::ConcurrentOp, item_type: Type).returns(PipelineConcurrentInvocation) }
  def bounded_pointer_invocation(conc_op, item_type)
    bounded_invocation(conc_op, build_bounded_concurrent_callback_pointer(conc_op, item_type))
  end

  sig { params(spec: FiberCtxBuilder::CaptureSpec, capture_symbols: T::Hash[String, SymbolEntry]).returns(MIR::FieldDef) }
  def capture_field_def(spec, capture_symbols)
    field = MIR::FieldDef.new(spec.name, spec.field_type_zig, nil)
    sym = capture_symbols[spec.name]
    field.boxed_capture = struct_name_hint_for_sym(sym) || true if sym&.boxed_capture_storage?
    field
  end

  sig { params(sym: T.nilable(SymbolEntry)).returns(T.nilable(String)) }
  def struct_name_hint_for_sym(sym)
    return nil unless sym

    bare = sym.type.bare_data_type
    return bare.to_s if bare && bare.respond_to?(:struct?) && bare.struct?

    nil
  end

  sig { params(specs: T::Array[FiberCtxBuilder::CaptureSpec]).returns(T::Array[MIR::Emittable]) }
  def callback_prelude(specs)
    body = T.let([MIR::Suppress.new("__rt")], T::Array[MIR::Emittable])
    if specs.empty?
      body << MIR::Suppress.new("raw_ctx")
    else
      ctx_cast = MIR::PointerCast.new(MIR::OptionalUnwrap.new(MIR::Ident.new("raw_ctx")), "*@This()")
      body << MIR::Let.new("ctx", ctx_cast, false, nil, nil)
    end
    body
  end

  sig { params(conc_op: AST::ConcurrentOp, body_kind: PipelineConcurrentCallbackBodyKind, ret_type: Type, capture_map: T::Hash[String, String], capture_symbols: T::Hash[String, SymbolEntry]).returns(T::Array[MIR::Emittable]) }
  def callback_body(conc_op, body_kind, ret_type, capture_map, capture_symbols)
    case body_kind
    when PipelineConcurrentCallbackBodyKind::Expr
      expr_node = callback_expression(conc_op)
      expr_mir = self.callback_expr_mir.call(expr_node, "__item", capture_map, capture_symbols, "__rt")
      expr_mir.try_wrap = false if expr_mir.is_a?(MIR::Call) || expr_mir.is_a?(MIR::MethodCall)
      expr_type = expr_node.full_type!
      if expr_type && Type.new(expr_type).integer? && ret_type.float?
        expr_mir = MIR::Cast.new(MIR::Cast.new(expr_mir, nil, :floatFromInt), ret_type.zig_type, :as)
      end
      [MIR::ReturnStmt.new(expr_mir)]
    when PipelineConcurrentCallbackBodyKind::Each
      [
        *self.callback_body_mir.call(
          T.cast(conc_op.op, AST::EachOp).body,
          "__item",
          capture_map,
          capture_symbols,
          "__rt",
        ),
        MIR::ReturnStmt.new(nil),
      ]
    else
      raise "unknown bounded concurrent callback kind #{body_kind.inspect}"
    end
  end

  sig { params(conc_op: AST::ConcurrentOp).returns(AST::Node) }
  def callback_expression(conc_op)
    op = conc_op.op
    case op
    when AST::AverageOp, AST::CountOp, AST::MaxOp, AST::MinOp, AST::SelectOp, AST::SumOp, AST::WhereOp
      T.cast(op.expression, AST::Node)
    else
      raise "concurrent callback expression expected expression op, got #{op.class}"
    end
  end

  sig { params(label: String).returns(Integer) }
  def numeric_label_id(label)
    label.delete("^0-9").to_i
  end

  sig { params(id: Integer, ctx_name: String, fields: T::Array[MIR::FieldDef], fn: MIR::FnDef, specs: T::Array[FiberCtxBuilder::CaptureSpec]).returns(PipelineConcurrentCallback) }
  def callback_record(id, ctx_name, fields, fn, specs)
    callback_fields = fields + [MIR::FieldDef.new("alloc", "std.mem.Allocator", nil)]
    ctx_init = MIR::StructInit.new(ctx_name, specs.map { |s|
      MIR::StructInitField.new(name: s.name, value: s.init_value_mir)
    } + [
      MIR::StructInitField.new(
        name: :alloc,
        value: MIR::MethodCall.new(
          MIR::Ident.new(self.do_rt_name.call),
          "heapAlloc",
          [],
          false,
          MIR::CallableContract.no_ownership(0),
        ),
      ),
    ])
    ctx_var = "__bounded_conc_ctx_#{id}"
    ctx_def = MIR::StructDef.new(ctx_name, callback_fields, [fn], nil)
    ctx_let = MIR::Let.new(ctx_var, ctx_init, true, nil, "_ = &#{ctx_var};")
    pre_ctx_stmts = specs.flat_map { |spec|
      setup = spec.setup_mir
      setup.is_a?(Array) ? setup : [setup].compact
    }
    post_ctx_stmts = specs.filter_map { |s| s.cleanup_mir_for(ctx_var) }
    PipelineConcurrentCallback.new(
      id: id,
      ctx_name: ctx_name,
      ctx_def: ctx_def,
      ctx_var: ctx_var,
      ctx_let: ctx_let,
      pre_ctx_stmts: pre_ctx_stmts,
      post_ctx_stmts: post_ctx_stmts,
      apply_ident: MIR::FieldGet.new(MIR::Ident.new(ctx_name), "apply"),
      context_arg: MIR::AddressOf.new(MIR::Ident.new(ctx_var)),
      context_stmts: [
        ctx_def,
        *pre_ctx_stmts,
        ctx_let,
        *post_ctx_stmts,
      ],
    )
  end

  sig { params(kind: PipelineConcurrentReduceKind, result_zig: String, result_type: Type).returns(MIR::Emittable) }
  def list_reduce_initial(kind, result_zig, result_type)
    case kind
    when PipelineConcurrentReduceKind::Sum then MIR::Lit.new("0")
    when PipelineConcurrentReduceKind::Average then MIR::Lit.new("0.0")
    when PipelineConcurrentReduceKind::Min then self.agg_min_sentinel_mir.call(result_zig)
    when PipelineConcurrentReduceKind::Max then self.agg_max_sentinel_mir.call(result_zig, result_type)
    else T.absurd(kind)
    end
  end

  sig { params(inner: T.any(AST::AverageOp, AST::MaxOp, AST::MinOp, AST::SumOp)).returns(PipelineConcurrentReduceKind) }
  def list_reduce_kind(inner)
    case inner
    when AST::SumOp then PipelineConcurrentReduceKind::Sum
    when AST::AverageOp then PipelineConcurrentReduceKind::Average
    when AST::MinOp then PipelineConcurrentReduceKind::Min
    when AST::MaxOp then PipelineConcurrentReduceKind::Max
    else T.absurd(inner)
    end
  end

  sig { params(body_stmts: T::Array[AST::Node]).returns(T::Boolean) }
  def each_body_mutates_placeholder?(body_stmts)
    body_stmts.any? { |stmt| assignment_targets_placeholder?(stmt) }
  end

  AssignmentTargetScanNode = T.type_alias { T.any(AST::Node, Struct) }

  sig { params(node: AssignmentTargetScanNode).returns(T::Boolean) }
  def assignment_targets_placeholder?(node)
    return target_rooted_at_placeholder?(T.cast(node.name, AST::Node)) if node.is_a?(AST::Assignment)

    if node.is_a?(Struct)
      node.members.any? do |member|
        next false if [:token, :location].include?(member)

        value = node[member]
        if value.is_a?(Array)
          value.any? { |child| child.is_a?(Struct) && assignment_targets_placeholder?(child) }
        elsif value.is_a?(Struct)
          assignment_targets_placeholder?(value)
        else
          false
        end
      end
    else
      false
    end
  end

  sig { params(target: AST::Node).returns(T::Boolean) }
  def target_rooted_at_placeholder?(target)
    AST.root_identifier(target)&.name == "_"
  end
end
