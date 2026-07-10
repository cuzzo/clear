# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "../../../ast/ast"
require_relative "../../../ast/type"
require_relative "../../lowering/schema_registry"
require_relative "../../mir"

PipelineBcIterRange = T.type_alias { [MIR::IterRange, T.nilable(String)] }
PipelineRangeSkipHook = T.type_alias { T.proc.params(item_var: String).returns(T::Array[MIR::Emittable]) }
PipelineRangeTypeInput = T.type_alias { T.any(Type, Symbol, String) }
PipelineDefaultObservableFoldOp = T.type_alias { T.any(AST::AllOp, AST::AnyOp, AST::AverageOp, AST::CountOp, AST::FindOp, AST::MaxOp, AST::MinOp, AST::SumOp) }

class PipelinePublishSpec < T::Struct
  extend T::Sig

  const :publish_method, String
  const :expr, Symbol
  const :gate, Symbol
  const :transfers_item_on_success, T::Boolean

  sig { params(raw: Type::ObservablePublishSpec).returns(PipelinePublishSpec) }
  def self.from(raw)
    expr = raw.expr
    gate = raw.gate
    PipelinePublishSpec.new(
      publish_method: raw.publish_method,
      expr: expr,
      gate: gate,
      transfers_item_on_success: expr == :item && gate == :pred,
    )
  end
end

class PipelineRangeChain < T::Struct
  const :source, AST::Node
  const :stages, T::Array[AST::Node]
end

class PipelineLazyRangePrefix < T::Struct
  extend T::Sig

  const :range_let, T.nilable(MIR::Let)
  const :source_name, String
  const :outer_stmts, T::Array[MIR::Emittable]
  const :stage_stmts, T::Array[MIR::Emittable]
  const :item_var, String
  const :initial_capture, String
  const :item_used, T::Boolean
  const :elem_zig, String
  const :next_method, String

  sig { returns(T::Array[MIR::Emittable]) }
  def setup_stmts
    stmts = T.let([], T::Array[MIR::Emittable])
    source_setup = range_let
    stmts << source_setup if source_setup
    stmts.concat(outer_stmts)
    stmts
  end

  sig { returns(T::Array[MIR::Emittable]) }
  def outer_setup_stmts
    outer_stmts
  end

  sig { params(body_stmts: T::Array[MIR::Emittable]).returns(T::Array[MIR::Emittable]) }
  def stage_body(body_stmts)
    stage_stmts + body_stmts
  end

  sig { returns(MIR::MethodCall) }
  def next_call
    MIR::MethodCall.new(MIR::Ident.new(source_name), next_method, [], true, MIR::CallableContract.no_ownership(0))
  end

  sig { returns(MIR::DeferStmt) }
  def deinit_stmt
    MIR::DeferStmt.new(MIR::MethodCall.new(MIR::Ident.new(source_name), "deinit", [], false, MIR::CallableContract.no_ownership(0)))
  end

  sig { params(iter: T.nilable(MIR::Emittable), body_stmts: T::Array[MIR::Emittable], capture_name: T.nilable(String)).returns(T.any(MIR::ForStmt, MIR::WhileStmt)) }
  def loop_stmt(iter, body_stmts, capture_name: initial_capture)
    body = stage_body(body_stmts)
    if iter
      MIR::ForStmt.new(iter, capture_name, body, nil)
    else
      MIR::WhileStmt.new(next_call, body, T.must(capture_name), nil, nil, nil)
    end
  end
  private :next_call
  private :stage_body

end

class PipelineRangeFoldNames < T::Struct
  extend T::Sig

  const :acc, String
  const :cnt, String
  const :sum, String
  const :val, String
  const :found, String
  const :result, String

  sig { params(label: String, bc_target: T::Boolean).returns(PipelineRangeFoldNames) }
  def self.for_label(label, bc_target)
    suffix = bc_target ? "_#{label.sub('__pblk', 'b')}" : ""
    PipelineRangeFoldNames.new(
      acc: "__fold_acc#{suffix}",
      cnt: "__fold_cnt#{suffix}",
      sum: "__fold_sum#{suffix}",
      val: "__fold_val#{suffix}",
      found: "__fold_found#{suffix}",
      result: "__fold_result#{suffix}",
    )
  end
end

class PipelineRangeFoldPlan < T::Struct
  const :acc_init_stmts, T::Array[MIR::Emittable]
  const :loop_acc_stmts, T::Array[MIR::Emittable]
  const :post_loop_stmts, T::Array[MIR::Emittable]
  const :result_expr, MIR::Emittable
end

class PipelineRangeLoopIter < T::Struct
  const :iter, MIR::Emittable
  const :capture_name, T.nilable(String)
end

class PipelineRangeLowerer
  extend T::Sig

  module Host
    extend T::Sig
    extend T::Helpers

    interface!

    sig { abstract.params(node: AST::Node).returns(MIR::Node) }
    def range_visit_mir(node); end

    sig { abstract.params(node: AST::Node, placeholder: T.nilable(String), acc: T.nilable(String)).returns(MIR::Node) }
    def range_visit_mir_with_context(node, placeholder:, acc: nil); end

    sig { abstract.params(body_stmts: T::Array[AST::Node], placeholder: String).returns(T::Array[MIR::Emittable]) }
    def range_visit_pipeline_body_mir(body_stmts, placeholder:); end

    sig { abstract.params(body_stmts: T::Array[AST::Node]).returns(T::Boolean) }
    def range_ast_stmts_use_placeholder?(body_stmts); end

    sig { abstract.returns(T::Boolean) }
    def range_bc_target?; end

    sig { abstract.returns(String) }
    def range_next_label; end

    sig { abstract.params(type_info: PipelineRangeTypeInput).returns(String) }
    def range_transpile_type(type_info); end

    sig { abstract.returns(MIRLoweringSchemas::SchemaLookup) }
    def range_schema_lookup; end

    sig { abstract.returns(String) }
    def range_runtime_name; end

    sig { abstract.returns(Integer) }
    def range_next_observable_id; end

    sig { abstract.returns(String) }
    def range_task_config_variant; end
  end

  class RuntimeHost
    extend T::Sig

    include PipelineRangeLowerer::Host

    sig do
      params(
        visit_mir: T.proc.params(node: AST::Node).returns(MIR::Node),
        visit_mir_with_context: T.proc.params(node: AST::Node, placeholder: T.nilable(String), acc: T.nilable(String)).returns(MIR::Node),
        visit_pipeline_body_mir: T.proc.params(body_stmts: T::Array[AST::Node], placeholder: String).returns(T::Array[MIR::Emittable]),
        ast_stmts_use_placeholder: T.proc.params(body_stmts: T::Array[AST::Node]).returns(T::Boolean),
        bc_target: T.proc.returns(T::Boolean),
        next_label: T.proc.returns(String),
        transpile_type: T.proc.params(type_info: PipelineRangeTypeInput).returns(String),
        schema_lookup: T.proc.returns(MIRLoweringSchemas::SchemaLookup),
        runtime_name: T.proc.returns(String),
        next_observable_id: T.proc.returns(Integer),
        task_config_variant: T.proc.returns(String),
      ).void
    end
    def initialize(visit_mir:, visit_mir_with_context:, visit_pipeline_body_mir:,
                   ast_stmts_use_placeholder:, bc_target:, next_label:,
                   transpile_type:, schema_lookup:, runtime_name:, next_observable_id:,
                   task_config_variant:)
      @visit_mir = T.let(visit_mir, T.proc.params(node: AST::Node).returns(MIR::Node))
      @visit_mir_with_context = T.let(visit_mir_with_context,
        T.proc.params(node: AST::Node, placeholder: T.nilable(String), acc: T.nilable(String)).returns(MIR::Node))
      @visit_pipeline_body_mir = T.let(visit_pipeline_body_mir,
        T.proc.params(body_stmts: T::Array[AST::Node], placeholder: String).returns(T::Array[MIR::Emittable]))
      @ast_stmts_use_placeholder = T.let(ast_stmts_use_placeholder,
        T.proc.params(body_stmts: T::Array[AST::Node]).returns(T::Boolean))
      @bc_target = T.let(bc_target, T.proc.returns(T::Boolean))
      @next_label = T.let(next_label, T.proc.returns(String))
      @transpile_type = T.let(transpile_type, T.proc.params(type_info: PipelineRangeTypeInput).returns(String))
      @schema_lookup = T.let(schema_lookup, T.proc.returns(MIRLoweringSchemas::SchemaLookup))
      @runtime_name = T.let(runtime_name, T.proc.returns(String))
      @next_observable_id = T.let(next_observable_id, T.proc.returns(Integer))
      @task_config_variant = T.let(task_config_variant, T.proc.returns(String))
    end

    sig { override.params(node: AST::Node).returns(MIR::Node) }
    def range_visit_mir(node)
      @visit_mir.call(node)
    end

    sig { override.params(node: AST::Node, placeholder: T.nilable(String), acc: T.nilable(String)).returns(MIR::Node) }
    def range_visit_mir_with_context(node, placeholder:, acc: nil)
      @visit_mir_with_context.call(node, placeholder, acc)
    end

    sig { override.params(body_stmts: T::Array[AST::Node], placeholder: String).returns(T::Array[MIR::Emittable]) }
    def range_visit_pipeline_body_mir(body_stmts, placeholder:)
      @visit_pipeline_body_mir.call(body_stmts, placeholder)
    end

    sig { override.params(body_stmts: T::Array[AST::Node]).returns(T::Boolean) }
    def range_ast_stmts_use_placeholder?(body_stmts)
      @ast_stmts_use_placeholder.call(body_stmts)
    end

    sig { override.returns(T::Boolean) }
    def range_bc_target?
      @bc_target.call
    end

    sig { override.returns(String) }
    def range_next_label
      @next_label.call
    end

    sig { override.params(type_info: PipelineRangeTypeInput).returns(String) }
    def range_transpile_type(type_info)
      @transpile_type.call(type_info)
    end

    sig { override.returns(MIRLoweringSchemas::SchemaLookup) }
    def range_schema_lookup
      @schema_lookup.call
    end

    sig { override.returns(String) }
    def range_runtime_name
      @runtime_name.call
    end

    sig { override.returns(Integer) }
    def range_next_observable_id
      @next_observable_id.call
    end

    sig { override.returns(String) }
    def range_task_config_variant
      @task_config_variant.call
    end
  end

  sig { params(host: PipelineRangeLowerer::Host).void }
  def initialize(host:)
    @host = T.let(host, PipelineRangeLowerer::Host)
  end

  sig { params(node: AST::Node).returns(T::Boolean) }
  def finite_stream_source_node?(node)
    node.is_a?(AST::RangeLit) || node.full_type!.dynamic_stream? ||
      node.full_type!.open_stream? ||
      node.full_type!.bounded_stream? || node.full_type!.inf_stream?
  end

  sig { params(node: AST::Node).returns(T.nilable(PipelineRangeChain)) }
  def unwrap_range_chain(node)
    return PipelineRangeChain.new(source: node, stages: []) if finite_stream_source_node?(node)
    return nil unless node.is_a?(AST::BinaryOp) && node.smooth?

    stages = T.let([], T::Array[AST::Node])
    cursor = T.let(node, AST::Node)
    while cursor.is_a?(AST::BinaryOp) && cursor.smooth?
      rhs = cursor.right
      if AST.pipeline_fusible_stage?(rhs)
        stages.unshift(rhs)
        cursor = cursor.left
      else
        return nil
      end
    end
    return nil unless finite_stream_source_node?(cursor)

    PipelineRangeChain.new(source: cursor, stages: stages)
  end

  sig { params(source_node: AST::Node, stages: T::Array[AST::Node], on_skip: T.nilable(PipelineRangeSkipHook)).returns(PipelineLazyRangePrefix) }
  def build_lazy_range_prefix(source_node, stages, on_skip: nil)
    source_ti = source_node.full_type!
    elem_t = source_ti.runtime_stream_storage_element_type || range_literal_element_type(source_node)
    elem_zig = elem_t.zig_type

    initial_capture = "__each_item"
    item_var = T.let(initial_capture, String)
    item_counter = 0
    item_used = T.let(false, T::Boolean)
    outer_stmts = T.let([], T::Array[MIR::Emittable])
    stage_stmts = T.let([], T::Array[MIR::Emittable])

    stages.each do |stage|
      case stage
      when AST::SelectOp
        item_used = true
        item_counter += 1
        next_item = "__each_item_#{item_counter}"
        expr_mir = @host.range_visit_mir_with_context(stage.expression, placeholder: item_var)
        stage_stmts << MIR::Let.new(next_item, expr_mir, false, nil, nil)
        item_var = next_item

      when AST::WhereOp
        item_used = true if item_var == initial_capture
        pred_mir = @host.range_visit_mir_with_context(stage.expression, placeholder: item_var)
        skip_stmts = on_skip ? [*on_skip.call(item_var), MIR::ContinueStmt.new(nil)] : [MIR::ContinueStmt.new(nil)]
        stage_stmts << MIR::IfStmt.new(MIR::UnaryOp.new("!", pred_mir), skip_stmts, nil)

      when AST::TakeWhileOp
        item_used = true if item_var == initial_capture
        pred_mir = @host.range_visit_mir_with_context(stage.expression, placeholder: item_var)
        skip_stmts = on_skip ? [*on_skip.call(item_var), MIR::BreakStmt.new(nil, nil)] : [MIR::BreakStmt.new(nil, nil)]
        stage_stmts << MIR::IfStmt.new(MIR::UnaryOp.new("!", pred_mir), skip_stmts, nil)

      when AST::LimitOp
        item_counter += 1
        cvar = "__limit_cnt_#{item_counter}"
        cnt_var = "__limit_max_#{item_counter}"
        cnt_mir = @host.range_visit_mir(stage.count)
        outer_stmts << MIR::Let.new(cvar, MIR::Cast.new(MIR::Lit.new("0"), "i64", :as), true, nil, nil)
        outer_stmts << MIR::Let.new(cnt_var, cnt_mir, false, nil, nil)
        stage_stmts << MIR::IfStmt.new(
          MIR::BinOp.new(">=", MIR::Ident.new(cvar), MIR::Ident.new(cnt_var)),
          [MIR::BreakStmt.new(nil, nil)], nil)
        stage_stmts << MIR::Set.new(
          MIR::Ident.new(cvar), MIR::BinOp.new("+", MIR::Ident.new(cvar), MIR::Lit.new("1")))

      when AST::SkipOp
        item_counter += 1
        cvar = "__skip_cnt_#{item_counter}"
        cnt_var = "__skip_max_#{item_counter}"
        cnt_mir = @host.range_visit_mir(stage.count)
        outer_stmts << MIR::Let.new(cvar, MIR::Cast.new(MIR::Lit.new("0"), "i64", :as), true, nil, nil)
        outer_stmts << MIR::Let.new(cnt_var, cnt_mir, false, nil, nil)
        stage_stmts << MIR::IfStmt.new(
          MIR::BinOp.new("<", MIR::Ident.new(cvar), MIR::Ident.new(cnt_var)),
          [MIR::Set.new(MIR::Ident.new(cvar),
             MIR::BinOp.new("+", MIR::Ident.new(cvar), MIR::Lit.new("1"))),
           MIR::ContinueStmt.new(nil)], nil)

      when AST::TapOp
        item_used = true if item_var == initial_capture
        stage_stmts.concat(@host.range_visit_pipeline_body_mir(stage.body, placeholder: item_var))
      end
    end

    is_var_stream = source_node.is_a?(AST::Identifier) &&
      (source_ti.dynamic_stream? || source_ti.open_stream? ||
       source_ti.bounded_stream? || source_ti.inf_stream?)
    source_name = is_var_stream ? source_node.name.to_s : "__range_src"
    range_let = is_var_stream ? nil :
      MIR::Let.new("__range_src", @host.range_visit_mir(source_node), true, nil, "_ = &__range_src;")

    next_method = (source_ti.bounded_stream? || source_ti.inf_stream?) ? "nextOrNull" : "next"

    PipelineLazyRangePrefix.new(range_let: range_let, source_name: source_name,
      outer_stmts: outer_stmts, stage_stmts: stage_stmts,
      item_var: item_var, initial_capture: initial_capture, item_used: item_used,
      elem_zig: elem_zig, next_method: next_method)
  end

  sig { params(source_node: AST::Node).returns(Type) }
  def range_literal_element_type(source_node)
    start_ft = source_node.is_a?(AST::RangeLit) ? source_node.start.full_type!(context: "lazy range start") : Type.new(:Int64)
    Type.new(start_ft)
  end

  sig { params(range_lit: AST::Node, stages: T::Array[AST::Node], each_op: AST::EachOp).returns(MIR::ScopeBlock) }
  def lower_each_range(range_lit, stages, each_op)
    prefix = build_lazy_range_prefix(range_lit, stages)
    item_var = prefix.item_var
    initial_capture = prefix.initial_capture
    item_used = prefix.item_used

    body_mir = @host.range_visit_pipeline_body_mir(each_op.body, placeholder: item_var)

    body_uses_initial = (item_var == initial_capture) && @host.range_ast_stmts_use_placeholder?(each_op.body)
    item_used ||= body_uses_initial
    capture_name = item_used ? initial_capture : "_"

    source_ti = range_lit.full_type!
    defer_deinit = source_ti.bounded_stream? ? prefix.deinit_stmt : nil

    bc_iter = bc_loop_iter(range_lit, source_ti, capture_name == "_" ? "_" : initial_capture)
    if bc_iter
      return MIR::ScopeBlock.new([
        *prefix.outer_setup_stmts,
        prefix.loop_stmt(bc_iter.iter, body_mir, capture_name: bc_iter.capture_name)
      ])
    end

    MIR::ScopeBlock.new([
      *prefix.setup_stmts,
      *([defer_deinit].compact),
      prefix.loop_stmt(nil, body_mir, capture_name: capture_name)
    ])
  end

  sig { params(range_lit: AST::RangeLit, capture_name: T.nilable(String)).returns(PipelineBcIterRange) }
  def bc_for_iter_range(range_lit, capture_name)
    start_mir = @host.range_visit_mir(range_lit.start)
    end_mir = @host.range_visit_mir(range_lit.finish)
    end_expr = range_lit.inclusive ?
      MIR::BinOp.new("+", end_mir, MIR::Lit.new("1")) : end_mir
    [MIR::IterRange.new(start_mir, end_expr, :i64), capture_name]
  end

  PIPELINE_ALLOC_REF_DEF = T.let(FunctionSignature.borrowing_intrinsic, FunctionSignature)
  OBSERVABLE_FOLD_OP_CLASSES = T.let({
    sum: AST::SumOp,
    count: AST::CountOp,
    avg: AST::AverageOp,
    max: AST::MaxOp,
    min: AST::MinOp,
    any: AST::AnyOp,
    all: AST::AllOp,
    find: AST::FindOp,
  }.freeze, T::Hash[Symbol, T::Class[T.anything]])
  PUBLISH_SPEC = T.let(Type.observable_terminals.each_with_object({}) { |(sym, entry), h|
    h[sym] = PipelinePublishSpec.from(T.must(entry.publish)) if entry.publish
  }.freeze, T::Hash[Symbol, PipelinePublishSpec])
  FOLD_OP_OBSERVABLE_TERMINAL = T.let(Type.observable_terminals.each_with_object({}) { |(sym, entry), h|
    tag = entry.ast_class
    unless tag.nil?
      klass = OBSERVABLE_FOLD_OP_CLASSES[T.must(tag)]
      h[T.must(klass)] = sym unless klass.nil?
    end
  }.freeze, T::Hash[T::Class[T.anything], Symbol])

  sig { params(expr_ast: AST::Node, item_var: String, acc_zig: String).returns(MIR::Node) }
  def numeric_fold_expr_typed(expr_ast, item_var, acc_zig)
    expr_mir = @host.range_visit_mir_with_context(expr_ast, placeholder: item_var)
    expr_type = expr_ast.full_type!
    expr_is_int = Type.new(expr_type).integer?
    acc_is_float = acc_zig == "f64" || acc_zig == "f32"
    if expr_is_int && acc_is_float
      MIR::Cast.new(MIR::Cast.new(expr_mir, nil, :floatFromInt), acc_zig, :as)
    else
      expr_mir
    end
  end

  sig { params(range_lit: AST::Node, stages: T::Array[AST::Node], fold_op: PipelineDefaultObservableFoldOp, smooth_node: AST::BinaryOp).returns(MIR::BlockExpr) }
  def lower_range_fold(range_lit, stages, fold_op, smooth_node)
    prefix = build_lazy_range_prefix(range_lit, stages)
    label = @host.range_next_label

    if smooth_node.observable_dest
      terminal = FOLD_OP_OBSERVABLE_TERMINAL[fold_op.class]
      if terminal.nil?
        raise CompilerError.new(
          smooth_node.token,
          "lower_range_fold: observable_dest set but no terminal registered for #{fold_op.class.name}",
          nil,
        )
      end
      return lower_range_fold_observable_default(
        prefix, fold_op, smooth_node, label, range_lit, terminal: terminal,
      )
    end

    names = PipelineRangeFoldNames.for_label(label, @host.range_bc_target?)
    plan = scalar_fold_plan(prefix, fold_op, smooth_node, names)
    range_accumulating_block(range_lit, prefix, label, plan, prefix.initial_capture)
  end

  sig { params(range_lit: AST::Node, stages: T::Array[AST::Node], reduce_op: AST::ReduceOp, smooth_node: T.nilable(AST::BinaryOp)).returns(MIR::BlockExpr) }
  def lower_range_reduce(range_lit, stages, reduce_op, smooth_node = nil)
    prefix = build_lazy_range_prefix(range_lit, stages)
    item_var = prefix.item_var

    if smooth_node&.observable_dest
      label = @host.range_next_label
      return lower_range_reduce_observable(prefix, reduce_op, smooth_node, label, range_lit)
    end

    label = @host.range_next_label
    acc_zig = @host.range_transpile_type(reduce_op.full_type!.to_s)
    init_mir = @host.range_visit_mir(reduce_op.initial_value)
    expr_mir = @host.range_visit_mir_with_context(reduce_op.expression, placeholder: item_var, acc: "acc")
    plan = PipelineRangeFoldPlan.new(
      acc_init_stmts: [MIR::Let.new("acc", init_mir, true, Type.new(acc_zig), nil)],
      loop_acc_stmts: [MIR::Set.new(MIR::Ident.new("acc"), expr_mir)],
      post_loop_stmts: [],
      result_expr: MIR::Ident.new("acc"),
    )
    range_accumulating_block(range_lit, prefix, label, plan, prefix.initial_capture)
  end

  sig { params(prefix: PipelineLazyRangePrefix, fold_op: PipelineDefaultObservableFoldOp, smooth_node: AST::BinaryOp, names: PipelineRangeFoldNames).returns(PipelineRangeFoldPlan) }
  def scalar_fold_plan(prefix, fold_op, smooth_node, names)
    case fold_op
    when AST::CountOp
      count_fold_plan(prefix, fold_op, names)
    when AST::SumOp
      sum_fold_plan(prefix, fold_op, smooth_node, names)
    when AST::AverageOp
      average_fold_plan(prefix, fold_op, names)
    when AST::MinOp
      min_fold_plan(prefix, fold_op, smooth_node, names)
    when AST::MaxOp
      max_fold_plan(prefix, fold_op, smooth_node, names)
    when AST::AnyOp
      any_fold_plan(prefix, fold_op, names)
    when AST::AllOp
      all_fold_plan(prefix, fold_op, names)
    when AST::FindOp
      find_fold_plan(prefix, fold_op, smooth_node, names)
    end
  end

  sig { params(prefix: PipelineLazyRangePrefix, fold_op: AST::CountOp, names: PipelineRangeFoldNames).returns(PipelineRangeFoldPlan) }
  def count_fold_plan(prefix, fold_op, names)
    pred_mir = @host.range_visit_mir_with_context(fold_op.expression, placeholder: prefix.item_var)
    PipelineRangeFoldPlan.new(
      acc_init_stmts: [MIR::Let.new(names.acc, MIR::Lit.new("0"), true, Type.new("i64"), nil)],
      loop_acc_stmts: [MIR::IfStmt.new(pred_mir, [
        MIR::Set.new(MIR::Ident.new(names.acc),
          MIR::BinOp.new("+", MIR::Ident.new(names.acc), MIR::Lit.new("1"))),
      ], nil)],
      post_loop_stmts: [],
      result_expr: MIR::Ident.new(names.acc),
    )
  end

  sig { params(prefix: PipelineLazyRangePrefix, fold_op: AST::SumOp, smooth_node: AST::BinaryOp, names: PipelineRangeFoldNames).returns(PipelineRangeFoldPlan) }
  def sum_fold_plan(prefix, fold_op, smooth_node, names)
    acc_zig = @host.range_transpile_type(smooth_node.full_type!.to_s)
    expr_mir = numeric_fold_expr_typed(fold_op.expression, prefix.item_var, acc_zig)
    PipelineRangeFoldPlan.new(
      acc_init_stmts: [MIR::Let.new(names.acc, MIR::Lit.new("0"), true, Type.new(acc_zig), nil)],
      loop_acc_stmts: [MIR::Set.new(MIR::Ident.new(names.acc),
        MIR::BinOp.new("+", MIR::Ident.new(names.acc), expr_mir))],
      post_loop_stmts: [],
      result_expr: MIR::Ident.new(names.acc),
    )
  end

  sig { params(prefix: PipelineLazyRangePrefix, fold_op: AST::AverageOp, names: PipelineRangeFoldNames).returns(PipelineRangeFoldPlan) }
  def average_fold_plan(prefix, fold_op, names)
    expr_f64 = numeric_fold_expr_typed(fold_op.expression, prefix.item_var, "f64")
    PipelineRangeFoldPlan.new(
      acc_init_stmts: [
        MIR::Let.new(names.sum, MIR::Lit.new("0"), true, Type.new("f64"), nil),
        MIR::Let.new(names.cnt, MIR::Lit.new("0"), true, Type.new("i64"), nil),
      ],
      loop_acc_stmts: [
        MIR::Set.new(MIR::Ident.new(names.sum),
          MIR::BinOp.new("+", MIR::Ident.new(names.sum), expr_f64)),
        MIR::Set.new(MIR::Ident.new(names.cnt),
          MIR::BinOp.new("+", MIR::Ident.new(names.cnt), MIR::Lit.new("1"))),
      ],
      post_loop_stmts: [],
      result_expr: MIR::Conditional.new(
        MIR::BinOp.new("==", MIR::Ident.new(names.cnt), MIR::Lit.new("0")),
        MIR::Cast.new(MIR::Lit.new("0"), "f64", :as),
        MIR::BinOp.new("/", MIR::Ident.new(names.sum),
          MIR::Cast.new(MIR::Cast.new(MIR::Ident.new(names.cnt), nil, :floatFromInt), "f64", :as))),
    )
  end

  sig { params(prefix: PipelineLazyRangePrefix, fold_op: AST::MinOp, smooth_node: AST::BinaryOp, names: PipelineRangeFoldNames).returns(PipelineRangeFoldPlan) }
  def min_fold_plan(prefix, fold_op, smooth_node, names)
    min_max_fold_plan(prefix, fold_op.expression, smooth_node, names, sentinel: :max,
      compare_op: "<", empty_message: "MIN applied to empty sequence")
  end

  sig { params(prefix: PipelineLazyRangePrefix, fold_op: AST::MaxOp, smooth_node: AST::BinaryOp, names: PipelineRangeFoldNames).returns(PipelineRangeFoldPlan) }
  def max_fold_plan(prefix, fold_op, smooth_node, names)
    min_max_fold_plan(prefix, fold_op.expression, smooth_node, names, sentinel: :min,
      compare_op: ">", empty_message: "MAX applied to empty sequence")
  end

  sig { params(prefix: PipelineLazyRangePrefix, expr_ast: AST::Node, smooth_node: AST::BinaryOp, names: PipelineRangeFoldNames, sentinel: Symbol, compare_op: String, empty_message: String).returns(PipelineRangeFoldPlan) }
  def min_max_fold_plan(prefix, expr_ast, smooth_node, names, sentinel:, compare_op:, empty_message:)
    acc_zig = @host.range_transpile_type(smooth_node.full_type!.to_s)
    expr_mir = numeric_fold_expr_typed(expr_ast, prefix.item_var, acc_zig)
    PipelineRangeFoldPlan.new(
      acc_init_stmts: [
        MIR::Let.new(names.acc, MIR::TypeSentinel.new(sentinel, acc_zig), true, Type.new(acc_zig), nil),
        MIR::Let.new(names.found, MIR::Lit.new("false"), true, nil, nil),
      ],
      loop_acc_stmts: [
        MIR::Let.new(names.val, expr_mir, false, nil, nil),
        MIR::IfStmt.new(
          MIR::BinOp.new(compare_op, MIR::Ident.new(names.val), MIR::Ident.new(names.acc)),
          [
            MIR::Set.new(MIR::Ident.new(names.acc), MIR::Ident.new(names.val)),
            MIR::Set.new(MIR::Ident.new(names.found), MIR::Lit.new("true")),
          ],
          nil,
        ),
      ],
      post_loop_stmts: [
        MIR::IfStmt.new(
          MIR::UnaryOp.new("!", MIR::Ident.new(names.found)),
          [MIR::Panic.new(empty_message)],
          nil,
        ),
      ],
      result_expr: MIR::Ident.new(names.acc),
    )
  end

  sig { params(prefix: PipelineLazyRangePrefix, fold_op: AST::AnyOp, names: PipelineRangeFoldNames).returns(PipelineRangeFoldPlan) }
  def any_fold_plan(prefix, fold_op, names)
    pred_mir = @host.range_visit_mir_with_context(fold_op.expression, placeholder: prefix.item_var)
    PipelineRangeFoldPlan.new(
      acc_init_stmts: [MIR::Let.new(names.acc, MIR::Lit.new("false"), true, nil, nil)],
      loop_acc_stmts: [MIR::IfStmt.new(pred_mir, [
        MIR::Set.new(MIR::Ident.new(names.acc), MIR::Lit.new("true")),
        MIR::BreakStmt.new(nil, nil),
      ], nil)],
      post_loop_stmts: [],
      result_expr: MIR::Ident.new(names.acc),
    )
  end

  sig { params(prefix: PipelineLazyRangePrefix, fold_op: AST::AllOp, names: PipelineRangeFoldNames).returns(PipelineRangeFoldPlan) }
  def all_fold_plan(prefix, fold_op, names)
    pred_mir = @host.range_visit_mir_with_context(fold_op.expression, placeholder: prefix.item_var)
    PipelineRangeFoldPlan.new(
      acc_init_stmts: [MIR::Let.new(names.acc, MIR::Lit.new("true"), true, nil, nil)],
      loop_acc_stmts: [MIR::IfStmt.new(MIR::UnaryOp.new("!", pred_mir), [
        MIR::Set.new(MIR::Ident.new(names.acc), MIR::Lit.new("false")),
        MIR::BreakStmt.new(nil, nil),
      ], nil)],
      post_loop_stmts: [],
      result_expr: MIR::Ident.new(names.acc),
    )
  end

  sig { params(prefix: PipelineLazyRangePrefix, fold_op: AST::FindOp, smooth_node: AST::BinaryOp, names: PipelineRangeFoldNames).returns(PipelineRangeFoldPlan) }
  def find_fold_plan(prefix, fold_op, smooth_node, names)
    result_ft = Type.new(smooth_node.full_type!)
    find_zig = if result_ft.optional?
      @host.range_transpile_type(T.must(result_ft.wrapped_type).resolved.to_s)
    else
      prefix.elem_zig
    end
    pred_mir = @host.range_visit_mir_with_context(fold_op.expression, placeholder: prefix.item_var)
    PipelineRangeFoldPlan.new(
      acc_init_stmts: [
        MIR::Let.new(names.result, MIR::Undef.new(nil), true, Type.new(find_zig), nil),
        MIR::Let.new(names.found, MIR::Lit.new("false"), true, nil, nil),
      ],
      loop_acc_stmts: [MIR::IfStmt.new(pred_mir, [
        MIR::Set.new(MIR::Ident.new(names.result), MIR::Ident.new(prefix.item_var)),
        MIR::Set.new(MIR::Ident.new(names.found), MIR::Lit.new("true")),
        MIR::BreakStmt.new(nil, nil),
      ], nil)],
      post_loop_stmts: [],
      result_expr: MIR::Conditional.new(
        MIR::Ident.new(names.found),
        MIR::Cast.new(MIR::Ident.new(names.result), "?#{find_zig}", :as),
        MIR::Lit.new("null")),
    )
  end

  sig { params(range_lit: AST::Node, prefix: PipelineLazyRangePrefix, label: String, plan: PipelineRangeFoldPlan, capture_name: String).returns(MIR::BlockExpr) }
  def range_accumulating_block(range_lit, prefix, label, plan, capture_name)
    source_ti = range_lit.full_type!
    defer_deinit = source_ti.bounded_stream? ? prefix.deinit_stmt : nil

    bc_iter = bc_loop_iter(range_lit, source_ti, capture_name)
    if bc_iter
      return MIR::BlockExpr.new(label, [
        *prefix.outer_setup_stmts,
        *plan.acc_init_stmts,
        prefix.loop_stmt(bc_iter.iter, plan.loop_acc_stmts, capture_name: bc_iter.capture_name),
        *plan.post_loop_stmts,
        MIR::BreakStmt.new(label, plan.result_expr),
      ])
    end

    MIR::BlockExpr.new(label, [
      *prefix.setup_stmts,
      *plan.acc_init_stmts,
      *([defer_deinit].compact),
      prefix.loop_stmt(nil, plan.loop_acc_stmts, capture_name: capture_name),
      *plan.post_loop_stmts,
      MIR::BreakStmt.new(label, plan.result_expr),
    ])
  end

  sig { params(p: PipelineLazyRangePrefix, smooth_node: AST::BinaryOp, label: String, source_node: AST::Node, acc_alloc_expr: MIR::Emittable, publish_stmts: T::Array[MIR::Emittable], observable_id: T.nilable(Integer)).returns(MIR::BlockExpr) }
  def lower_range_fold_observable(p, smooth_node, label, source_node,
                                  acc_alloc_expr:, publish_stmts:, observable_id: nil)
    source_name = p.source_name
    obs_type = Type.from_node!(smooth_node, context: "observable accumulator")
    rt_name = @host.range_runtime_name

    wg_init = MIR::HeapCreate.new(
      "CheatHeader.WaitGroup",
      MIR::Call.new("CheatHeader.WaitGroup.init", [
        MIR::MethodCall.new(MIR::Ident.new(rt_name), "getSched", [], false, MIR::CallableContract.no_ownership(0)),
      ], false, false, MIR::CallableContract.no_ownership(1)),
      :heap,
      "__obs_wg_alloc"
    )
    obs_wg_anyopaque = MIR::Cast.new(
      MIR::Call.new("@ptrCast", [MIR::Ident.new("__obs_wg")], false, false, MIR::CallableContract.no_ownership(1)),
      "*anyopaque",
      :as,
    )
    set_completion_contract = MIR::CallableContract.new(
      FunctionSignature.new(params: [
        AST::Param.new(name: "ctx", type: Type.new(:Any)),
        AST::Param.new(name: "done", type: Type.new(:Any)),
        AST::Param.new(name: "wait", type: Type.new(:Any)),
        AST::Param.new(name: "destroy", type: Type.new(:Any)),
      ], return_type: Type.new(:Void)),
      MIR::OwnershipContract.consume_operands([
        MIR::OwnershipOperandFact.owned_binding("__obs_wg", Type.new(:"CheatHeader.WaitGroup", layout: :indirect), "observable completion", :heap),
      ]),
      4,
    )
    set_completion = MIR::MethodCall.new(MIR::Ident.new("__obs_acc"), "setCompletion", [
      obs_wg_anyopaque,
      MIR::FieldGet.new(MIR::Ident.new("CheatHeader"), "obsWgDone"),
      MIR::FieldGet.new(MIR::Ident.new("CheatHeader"), "obsWgWait"),
      MIR::FieldGet.new(MIR::Ident.new("CheatHeader"), "obsWgDestroy"),
    ], false, set_completion_contract)
    acc_init_stmts = [
      *p.setup_stmts,
      MIR::AllocMark.new("__obs_acc", :heap, obs_type, :heap),
      MIR::Let.new("__obs_acc", acc_alloc_expr, false, obs_type, nil),
      MIR::AllocMark.new("__obs_wg", :heap, Type.new(:"CheatHeader.WaitGroup", layout: :indirect), :heap),
      MIR::Let.new("__obs_wg", wg_init, false, Type.new("*CheatHeader.WaitGroup"), nil),
      MIR::ExprStmt.new(MIR::MethodCall.new(MIR::Ident.new("__obs_wg"), "add", [MIR::Lit.new("1")], false,
        MIR::CallableContract.no_ownership(1)), nil),
      MIR::ExprStmt.new(set_completion, nil),
    ]

    body_mir = [p.loop_stmt(nil, [
      *observable_stream_item_alloc_marks(p.item_var, source_node),
      *publish_stmts,
    ])]
    fid = observable_id || @host.range_next_observable_id
    spawn = MIR::ObservableConsumerSpawn.new(
      id: fid,
      acc_name: "__obs_acc",
      source_name: source_name,
      acc_type: obs_type,
      runtime_name: rt_name,
      task_config_variant: @host.range_task_config_variant,
      stdlib_def: PIPELINE_ALLOC_REF_DEF,
      ownership_contract: MIR::OwnershipContract.consume_operands([
        MIR::OwnershipOperandFact.owned_binding(source_name, Type.new(:Any), "observable consumer spawn", :heap),
      ]),
      body: body_mir,
    )

    MIR::BlockExpr.new(label, [
      *acc_init_stmts,
      MIR::ExprStmt.new(spawn, nil),
      MIR::BreakStmt.new(label, MIR::Ident.new("__obs_acc"))
    ])
  end

  sig { params(p: PipelineLazyRangePrefix, fold_op: PipelineDefaultObservableFoldOp, smooth_node: AST::BinaryOp, label: String, source_node: AST::Node, terminal: Symbol).returns(MIR::BlockExpr) }
  def lower_range_fold_observable_default(p, fold_op, smooth_node, label, source_node, terminal:)
    spec = PUBLISH_SPEC.fetch(terminal)
    source_elem = source_node.full_type!(context: "observable pipeline source").tense_type&.element_type
    item = p.item_var
    inner_recv = MIR::FieldGet.new(MIR::Ident.new("__obs_acc"), "inner")

    arg = case spec.expr
    when :typed
      inner_zig = @host.range_transpile_type(smooth_node.full_type!.tense_type)
      [numeric_fold_expr_typed(fold_op.expression, item, inner_zig)]
    when :f64
      [numeric_fold_expr_typed(fold_op.expression, item, "f64")]
    when :pred
      [@host.range_visit_mir_with_context(fold_op.expression, placeholder: item)]
    when :item
      [MIR::Ident.new(item)]
    when :none
      []
    else
      raise "unsupported observable publish expr #{spec.expr}"
    end

    callable_contract = if spec.transfers_item_on_success && source_elem && pipeline_element_owns_heap?(source_elem)
      MIR::CallableContract.new(
        FunctionSignature.new(params: [
          AST::Param.new(name: "item", type: source_elem, takes: true),
        ], return_type: Type.new(:Void)),
        MIR::OwnershipContract.consume_operands([
          MIR::OwnershipOperandFact.owned_binding(item.to_s, source_elem, "observable publish item", :heap),
        ]),
        1,
      )
    else
      MIR::CallableContract.no_ownership(arg.length)
    end
    call = MIR::ExprStmt.new(
      MIR::MethodCall.new(inner_recv, spec.publish_method, arg, false, callable_contract), nil)

    item_cleanup = consumed_stream_item_cleanup(item, source_node)
    publish = case spec.gate
    when :always
      [call, *item_cleanup]
    when :pred
      pred_mir = @host.range_visit_mir_with_context(fold_op.expression, placeholder: item)
      if spec.transfers_item_on_success
        [MIR::IfStmt.new(pred_mir, [call], item_cleanup)]
      else
        [MIR::IfStmt.new(pred_mir, [call], nil), *item_cleanup]
      end
    else
      raise "unsupported observable publish gate #{spec.gate}"
    end

    lower_range_fold_observable(p, smooth_node, label, source_node,
      acc_alloc_expr: default_obs_alloc_expr(smooth_node),
      publish_stmts: publish)
  end

  sig { params(type_info: Type).returns(T::Boolean) }
  def pipeline_element_owns_heap?(type_info)
    type_info.string? ||
      type_info.heap_ptr? ||
      type_info.recursive_cleanup_shape?(@host.range_schema_lookup) ||
      type_info.needs_explicit_cleanup?(:heap, @host.range_schema_lookup)
  end

  sig { params(range_lit: AST::Node, source_ti: Type, capture_name: T.nilable(String)).returns(T.nilable(PipelineRangeLoopIter)) }
  def bc_loop_iter(range_lit, source_ti, capture_name)
    return nil unless @host.range_bc_target?

    if range_lit.is_a?(AST::RangeLit)
      iter, cap = bc_for_iter_range(range_lit, capture_name)
      return PipelineRangeLoopIter.new(iter: iter, capture_name: cap)
    end

    return nil unless range_lit.is_a?(AST::Identifier) && source_ti.runtime_stream?

    PipelineRangeLoopIter.new(
      iter: @host.range_visit_mir(range_lit),
      capture_name: capture_name,
    )
  end

  sig { params(item_var: String, source_node: AST::Node).returns(T::Array[MIR::Emittable]) }
  def observable_stream_item_alloc_marks(item_var, source_node)
    src_t = source_node.full_type!(context: "observable pipeline source item")
    elem_t = src_t.tense_type&.element_type
    return [] unless elem_t && pipeline_element_owns_heap?(elem_t)

    [MIR::AllocMark.new(item_var, :heap, elem_t, :heap)]
  end

  sig { params(item_var: String, source_node: AST::Node).returns(T::Array[MIR::Emittable]) }
  def consumed_stream_item_cleanup(item_var, source_node)
    src_t = source_node.full_type!(context: "pipeline source cleanup")
    elem_t = src_t.tense_type&.element_type
    return [] unless elem_t && pipeline_element_owns_heap?(elem_t)

    contract = MIR::CallableContract.new(
      FunctionSignature.new(params: [
        AST::Param.new(name: "__type", type: Type.new(:Any)),
        AST::Param.new(name: "__alloc", type: Type.new(:Any)),
        AST::Param.new(name: "__ptr", type: Type.new(:Any)),
      ], return_type: Type.new(:Void)),
      MIR::OwnershipContract.consume_operands([
        MIR::OwnershipOperandFact.owned_binding(item_var, elem_t, "pipeline item cleanup", :heap),
      ]),
      3,
    )
    [MIR::ExprStmt.new(
      MIR::Call.new("CheatLib.cleanup", [
        MIR::TypeOf.new(MIR::Ident.new(item_var)),
        MIR::AllocatorRef.new(:heap),
        MIR::AddressOf.new(MIR::Ident.new(item_var)),
      ], false, false, contract),
      nil,
    )]
  end

  sig { params(p: PipelineLazyRangePrefix, reduce_op: AST::ReduceOp, smooth_node: AST::BinaryOp, label: String, source_node: AST::Node).returns(MIR::BlockExpr) }
  def lower_range_reduce_observable(p, reduce_op, smooth_node, label, source_node)
    inner_zig = @host.range_transpile_type(smooth_node.full_type!.tense_type)
    init_mir = @host.range_visit_mir(reduce_op.initial_value)
    fid = @host.range_next_observable_id
    curr_var = "__obs_reduce_curr_#{fid}"
    next_var = "__obs_reduce_next_#{fid}"
    actual_var = "__obs_reduce_actual_#{fid}"
    blk_label = "__obs_reduce_blk_#{fid}"
    item_var = p.item_var
    body_mir = @host.range_visit_mir_with_context(reduce_op.expression, placeholder: item_var, acc: curr_var)

    inner_recv = MIR::FieldGet.new(MIR::Ident.new("__obs_acc"), "inner")
    publish = [MIR::ExprStmt.new(MIR::BlockExpr.new(blk_label, [
      MIR::Let.new(curr_var,
        MIR::MethodCall.new(inner_recv, "view", [], false, MIR::CallableContract.no_ownership(0)),
        true, nil, nil),
      MIR::WhileStmt.new(MIR::Lit.new("true"), [
        MIR::Let.new(next_var, body_mir, false, nil, nil),
        MIR::IfBindStmt.new([
          MIR.if_binding(
            MIR::MethodCall.new(inner_recv, "tryCommit", [
              MIR::Ident.new(curr_var),
              MIR::Ident.new(next_var),
            ], false, MIR::CallableContract.no_ownership(2)),
            actual_var,
          ),
        ], [
          MIR::Set.new(MIR::Ident.new(curr_var), MIR::Ident.new(actual_var)),
        ], [
          MIR::BreakStmt.new(nil, nil),
        ]),
      ], nil, nil, nil, nil),
      MIR::ExprStmt.new(
        MIR::MethodCall.new(inner_recv, "markSeen", [], false, MIR::CallableContract.no_ownership(0)),
        false,
      ),
      MIR::BreakStmt.new(blk_label, MIR::Cast.new(MIR::Lit.new("0"), "i32", :as)),
    ]), true)]

    obs_target = without_pointer_prefix(@host.range_transpile_type(smooth_node.full_type!))
    acc_alloc = observable_alloc_expr(obs_target, "newWith", [
      MIR::AllocatorRef.new(:heap),
      MIR::RuntimeCall.new(MIR::RuntimeCalls.atomic_reduce_init_spec(inner_zig), [init_mir]),
    ])

    lower_range_fold_observable(p, smooth_node, label, source_node,
      acc_alloc_expr: acc_alloc,
      publish_stmts: publish,
      observable_id: fid)
  end

  sig { params(p: PipelineLazyRangePrefix, distinct_op: AST::DistinctOp, smooth_node: AST::BinaryOp, label: String, source_node: AST::Node).returns(MIR::BlockExpr) }
  def lower_range_fold_observable_distinct(p, distinct_op, smooth_node, label, source_node)
    item_var = p.item_var
    key_expr_mir = @host.range_visit_mir_with_context(distinct_op.expression, placeholder: item_var)
    obs_zig = @host.range_transpile_type(smooth_node.full_type!)
    target = without_pointer_prefix(obs_zig)
    set_type = smooth_node.full_type!.tense_type
    elem_type = T.must(set_type.element_type)
    elem_zig = @host.range_transpile_type(elem_type)
    is_bounded = set_type.fixed?
    cap = set_type.capacity

    submit_contract = if pipeline_element_owns_heap?(elem_type)
      MIR::CallableContract.new(
        FunctionSignature.new(params: [
          AST::Param.new(name: "item", type: elem_type, takes: true),
        ], return_type: Type.new(:Void)),
        MIR::OwnershipContract.consume_operands([
          MIR::OwnershipOperandFact.owned_binding(item_var, elem_type, "observable distinct item", :heap),
        ]),
        1,
      )
    else
      MIR::CallableContract.no_ownership(1)
    end
    submit_expr = MIR::MethodCall.new(
      MIR::FieldGet.new(MIR::Ident.new("__obs_acc"), "inner"),
      "submit",
      [key_expr_mir],
      false,
      submit_contract,
    )
    submit_expr = MIR::TryCatch.new(submit_expr, MIR::Lit.new("unreachable"), nil) unless is_bounded
    publish = [MIR::ExprStmt.new(submit_expr, true)]

    inner_ctor = if is_bounded
      observable_catch_unreachable(MIR::Call.new(
        "CheatLib.obs.StreamSetBounded(#{elem_zig}, #{cap}).init",
        [MIR::AllocatorRef.new(:heap)],
        false,
        false,
        MIR::CallableContract.no_ownership(1),
      ))
    else
      observable_catch_unreachable(MIR::Call.new(
        "CheatLib.obs.StreamSet(#{elem_zig}).init",
        [MIR::AllocatorRef.new(:heap)],
        false,
        false,
        MIR::CallableContract.no_ownership(1),
      ))
    end

    lower_range_fold_observable(p, smooth_node, label, source_node,
      acc_alloc_expr: observable_alloc_expr(target, "newWith", [
        MIR::AllocatorRef.new(:heap),
        inner_ctor,
      ]),
      publish_stmts: publish)
  end

  sig { params(smooth_node: AST::BinaryOp).returns(MIR::TryCatch) }
  def default_obs_alloc_expr(smooth_node)
    target = without_pointer_prefix(@host.range_transpile_type(smooth_node.full_type!))
    observable_alloc_expr(target, "new", [MIR::AllocatorRef.new(:heap)])
  end

  sig { params(expr: MIR::Node).returns(MIR::TryCatch) }
  def observable_catch_unreachable(expr)
    MIR::TryCatch.new(expr, MIR::Lit.new("unreachable"), nil)
  end

  sig { params(target: String, method: String, args: T::Array[MIR::Emittable]).returns(MIR::TryCatch) }
  def observable_alloc_expr(target, method, args)
    observable_catch_unreachable(
      MIR::Call.new("#{target}.#{method}", args, false, true,
        MIR::CallableContract.no_ownership(args.length))
    )
  end

  sig { params(type_name: String).returns(String) }
  def without_const_prefix(type_name)
    prefix = "const "
    return type_name unless type_name.start_with?(prefix)

    type_name[prefix.length..] || ""
  end

  sig { params(type_name: String).returns(String) }
  def without_pointer_prefix(type_name)
    return type_name unless type_name.start_with?("*")

    type_name[1..] || ""
  end

  sig { params(source: String, needle: String, replacement: String).returns(String) }
  def replace_zig_identifier(source, needle, replacement)
    return source if needle.empty?

    idx = 0
    needle_len = needle.bytesize
    result = +""
    while idx < source.bytesize
      if source.byteslice(idx, needle_len) == needle &&
          zig_identifier_boundary?(source, idx - 1) &&
          zig_identifier_boundary?(source, idx + needle_len)
        result << replacement
        idx += needle_len
      else
        result << T.must(source.byteslice(idx, 1))
        idx += 1
      end
    end
    result
  end

  sig { params(source: String, idx: Integer).returns(T::Boolean) }
  def zig_identifier_boundary?(source, idx)
    return true if idx < 0 || idx >= source.bytesize

    byte = source.getbyte(idx)
    !zig_identifier_byte?(T.must(byte))
  end

  sig { params(byte: Integer).returns(T::Boolean) }
  def zig_identifier_byte?(byte)
    (byte >= 65 && byte <= 90) ||
      (byte >= 97 && byte <= 122) ||
      (byte >= 48 && byte <= 57) ||
      byte == 95
  end
  private :all_fold_plan
  private :any_fold_plan
  private :average_fold_plan
  private :bc_loop_iter
  private :count_fold_plan
  private :find_fold_plan
  private :max_fold_plan
  private :min_fold_plan
  private :min_max_fold_plan
  private :observable_stream_item_alloc_marks
  private :range_literal_element_type
  private :scalar_fold_plan
  private :sum_fold_plan
  private :zig_identifier_boundary?
  private :zig_identifier_byte?

end
