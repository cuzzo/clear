# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "../../../ast/ast"
require_relative "../../../ast/type"
require_relative "../../mir"

PipelineBatchWindowTypeInput = T.type_alias { T.any(Type, Symbol, String) }

class PipelineBatchWindowSourceKind < T::Enum
  enums do
    BcInfiniteStream = new("bc_infinite_stream")
    BcMaterialized = new("bc_materialized")
    ZigRuntimeStream = new("zig_runtime_stream")
    ZigBoundedStream = new("zig_bounded_stream")
    ZigMaterialized = new("zig_materialized")
  end
end

class PipelineBatchWindowPlan < T::Struct
  const :source_kind, PipelineBatchWindowSourceKind
  const :list_node, AST::Node
  const :smooth_node, AST::BinaryOp
  const :element_zig, String
  const :result_zig, String
  const :size_mir, MIR::Node
  const :expr_mir, MIR::Node
  const :alloc, Symbol
  const :placeholder_var, String
  const :timeout_ns, String
  const :stream_pop_method, T.nilable(String)
end

class PipelineBatchWindowServices < T::Struct
  const :bc_target, T.proc.returns(T::Boolean)
  const :visit_mir, T.proc.params(node: AST::Node).returns(MIR::Node)
  const :visit_mir_with_placeholder, T.proc.params(node: AST::Node, placeholder: String).returns(MIR::Node)
  const :pipeline_block, T.proc.params(list_node: AST::Node, blk: T.proc.params(items: String, label: String).returns(T::Array[MIR::Emittable])).returns(MIR::BlockExpr)
  const :next_label, T.proc.returns(String)
  const :set_current_label, T.proc.params(label: String).void
  const :transpile_type, T.proc.params(type_info: PipelineBatchWindowTypeInput).returns(String)
  const :pipeline_alloc, T.proc.params(smooth_node: AST::BinaryOp).returns(Symbol)
end

class PipelineBatchWindowLowerer
  extend T::Sig

  BATCH_WINDOW_TIME_NS = T.let([
    ["ms", 1_000_000],
    ["s", 1_000_000_000],
    ["min", 60_000_000_000],
    ["h", 3_600_000_000_000],
  ].to_h.freeze, T::Hash[String, Integer])
  BATCH_WINDOW_TIME_UNITS = T.let(["min", "ms", "s", "h"].freeze, T::Array[String])

  sig { params(services: PipelineBatchWindowServices).void }
  def initialize(services:)
    @services = T.let(services, PipelineBatchWindowServices)
  end

  sig { params(list_node: AST::Node, smooth_node: AST::BinaryOp, bw_node: AST::BatchWindowOp).returns(MIR::BlockExpr) }
  def lower(list_node, smooth_node, bw_node)
    lower_plan(batch_window_plan(list_node, smooth_node, bw_node))
  end

  private

  sig { params(list_node: AST::Node, smooth_node: AST::BinaryOp, bw_node: AST::BatchWindowOp).returns(PipelineBatchWindowPlan) }
  def batch_window_plan(list_node, smooth_node, bw_node)
    lhs_type = list_node.full_type!
    placeholder_var = "__bw_batch"
    PipelineBatchWindowPlan.new(
      source_kind: source_kind_for(list_node, lhs_type),
      list_node: list_node,
      smooth_node: smooth_node,
      element_zig: @services.transpile_type.call(batch_element_type(lhs_type).to_s),
      result_zig: @services.transpile_type.call(bw_node.expression.full_type!.to_s),
      size_mir: batch_size_mir(bw_node),
      expr_mir: @services.visit_mir_with_placeholder.call(T.cast(bw_node.expression, AST::Node), placeholder_var),
      alloc: @services.pipeline_alloc.call(smooth_node),
      placeholder_var: placeholder_var,
      timeout_ns: batch_window_timeout_ns(bw_node),
      stream_pop_method: runtime_stream_pop_method(lhs_type),
    )
  end

  sig { params(plan: PipelineBatchWindowPlan).returns(MIR::BlockExpr) }
  def lower_plan(plan)
    source_kind = plan.source_kind
    case source_kind
    when PipelineBatchWindowSourceKind::BcInfiniteStream
      lower_bc_infinite_stream(plan)
    when PipelineBatchWindowSourceKind::BcMaterialized
      lower_bc_materialized(plan)
    when PipelineBatchWindowSourceKind::ZigRuntimeStream
      lower_zig_runtime_stream(plan)
    when PipelineBatchWindowSourceKind::ZigBoundedStream
      lower_zig_bounded_stream(plan)
    when PipelineBatchWindowSourceKind::ZigMaterialized
      lower_zig_materialized(plan)
    end
  end

  sig { params(list_node: AST::Node, lhs_type: Type).returns(PipelineBatchWindowSourceKind) }
  def source_kind_for(list_node, lhs_type)
    if @services.bc_target.call
      return PipelineBatchWindowSourceKind::BcInfiniteStream if list_node.is_a?(AST::Identifier) && lhs_type.inf_stream?

      return PipelineBatchWindowSourceKind::BcMaterialized
    end

    return PipelineBatchWindowSourceKind::ZigRuntimeStream if runtime_stream?(lhs_type)
    return PipelineBatchWindowSourceKind::ZigBoundedStream if lhs_type.bounded_stream?

    PipelineBatchWindowSourceKind::ZigMaterialized
  end

  sig { params(lhs_type: Type).returns(T::Boolean) }
  def runtime_stream?(lhs_type)
    lhs_type.open_stream? || lhs_type.dynamic_stream? || lhs_type.inf_stream?
  end

  sig { params(lhs_type: Type).returns(T.nilable(String)) }
  def runtime_stream_pop_method(lhs_type)
    return nil unless runtime_stream?(lhs_type)

    lhs_type.inf_stream? ? "nextOrNull" : "next"
  end

  sig { params(lhs_type: Type).returns(Type) }
  def batch_element_type(lhs_type)
    return Type.new(T.cast(lhs_type.stream_element_type, Type).resolved) if lhs_type.bounded_stream?

    lhs_type.runtime_stream_storage_element_type || T.must(lhs_type.element_type)
  end

  sig { params(bw_node: AST::BatchWindowOp).returns(MIR::Node) }
  def batch_size_mir(bw_node)
    size = T.cast(bw_node.options["size"], T.nilable(AST::Node))
    return MIR::Lit.new("0") unless size

    @services.visit_mir.call(size)
  end

  sig { params(bw_node: AST::BatchWindowOp).returns(String) }
  def batch_window_timeout_ns(bw_node)
    time = T.cast(bw_node.options["time"], T.nilable(AST::Literal))
    return "0" unless time

    raw_value = time.value.to_s
    unit = BATCH_WINDOW_TIME_UNITS.find { |candidate| raw_value.end_with?(candidate) }
    return "0" unless unit

    amount = raw_value[0, raw_value.length - unit.length]
    return "0" unless decimal_literal?(amount)

    (amount.to_f * BATCH_WINDOW_TIME_NS.fetch(unit)).to_i.to_s
  end

  sig { params(value: String).returns(T::Boolean) }
  def decimal_literal?(value)
    return false if value.empty?

    saw_digit = T.let(false, T::Boolean)
    saw_dot = T.let(false, T::Boolean)
    value.each_char do |char|
      if char == "."
        return false if saw_dot
        saw_dot = true
      elsif char >= "0" && char <= "9"
        saw_digit = true
      else
        return false
      end
    end

    saw_digit
  end

  sig { params(plan: PipelineBatchWindowPlan).returns(MIR::BlockExpr) }
  def lower_bc_infinite_stream(plan)
    label = @services.next_label.call
    @services.set_current_label.call(label)
    source_mir = @services.visit_mir.call(plan.list_node)

    MIR::BlockExpr.new(label, [
      MIR::Let.new("__bw_drained", MIR::MakeList.new(plan.element_zig, [], plan.alloc), true, nil, nil),
      MIR::ForStmt.new(source_mir, "__bw_it", [
        MIR::ExprStmt.new(MIR::MethodCall.new(
          MIR::Ident.new("__bw_drained"),
          "append",
          [MIR::Ident.new("__bw_it")],
          true,
          MIR::CallableContract.no_ownership(1),
        ), nil),
      ], nil),
      *bc_materialized_window_stmts(plan, MIR::Ident.new("__bw_drained"), append_uses_allocator: false),
      MIR::BreakStmt.new(label, MIR::Ident.new("res_list")),
    ])
  end

  sig { params(plan: PipelineBatchWindowPlan).returns(MIR::BlockExpr) }
  def lower_bc_materialized(plan)
    @services.pipeline_block.call(plan.list_node, lambda do |items, label|
      [
        *bc_materialized_window_stmts(plan, MIR::Ident.new(items), append_uses_allocator: true),
        MIR::BreakStmt.new(label, MIR::Ident.new("res_list")),
      ]
    end)
  end

  sig { params(plan: PipelineBatchWindowPlan).returns(MIR::BlockExpr) }
  def lower_zig_runtime_stream(plan)
    label = @services.next_label.call
    @services.set_current_label.call(label)
    source_mir = @services.visit_mir.call(plan.list_node)

    MIR::BlockExpr.new(label, [
      MIR::Let.new("__bw_src", source_mir, true, nil, "_ = &__bw_src;"),
      *batch_window_setup_stmts(plan),
      MIR::WhileStmt.new(
        MIR::MethodCall.new(MIR::Ident.new("__bw_src"), T.must(plan.stream_pop_method), [], true, MIR::CallableContract.no_ownership(0)),
        [batch_window_push_stmt(plan, "__bw_item")],
        "__bw_item",
        nil,
        nil,
        nil,
      ),
      batch_window_flush_stmt(plan),
      MIR::BreakStmt.new(label, MIR::Ident.new("res_list")),
    ])
  end

  sig { params(plan: PipelineBatchWindowPlan).returns(MIR::BlockExpr) }
  def lower_zig_bounded_stream(plan)
    label = @services.next_label.call
    @services.set_current_label.call(label)
    source_mir = @services.visit_mir.call(plan.list_node)

    MIR::BlockExpr.new(label, [
      MIR::Let.new("__bw_bsrc", source_mir, false, nil, nil),
      *batch_window_setup_stmts(plan),
      MIR::ForStmt.new(
        MIR::FieldGet.new(MIR::Ident.new("__bw_bsrc"), "items"),
        "__bw_item",
        [batch_window_push_stmt(plan, "__bw_item")],
        nil,
        nil,
        nil,
      ),
      batch_window_flush_stmt(plan),
      MIR::BreakStmt.new(label, MIR::Ident.new("res_list")),
    ])
  end

  sig { params(plan: PipelineBatchWindowPlan).returns(MIR::BlockExpr) }
  def lower_zig_materialized(plan)
    @services.pipeline_block.call(plan.list_node, lambda do |items, label|
      [
        *batch_window_setup_stmts(plan),
        MIR::ForStmt.new(
          MIR::Ident.new(items),
          "__bw_item",
          [batch_window_push_stmt(plan, "__bw_item")],
          nil,
          nil,
          nil,
        ),
        batch_window_flush_stmt(plan),
        MIR::BreakStmt.new(label, MIR::Ident.new("res_list")),
      ]
    end)
  end

  sig { params(plan: PipelineBatchWindowPlan, source: MIR::Emittable, append_uses_allocator: T::Boolean).returns(T::Array[MIR::Emittable]) }
  def bc_materialized_window_stmts(plan, source, append_uses_allocator:)
    [
      MIR::Let.new("res_list", MIR::MakeList.new(plan.result_zig, [], plan.alloc), true, nil, nil),
      MIR::Let.new("__bw_size", plan.size_mir, false, Type.new("i64"), nil),
      MIR::Let.new("__bw_total",
        MIR::Cast.new(MIR::FieldGet.new(source, "len"), "i64", :intCast),
        false, Type.new("i64"), nil),
      MIR::Let.new("__bw_step", bc_batch_step_expr, false, Type.new("i64"), nil),
      MIR::Let.new("__bw_offset", MIR::Lit.new("0"), true, Type.new("i64"), nil),
      MIR::WhileStmt.new(
        MIR::BinOp.new("<", MIR::Ident.new("__bw_offset"), MIR::Ident.new("__bw_total")),
        bc_materialized_loop_body(plan, source, append_uses_allocator: append_uses_allocator),
        nil,
        nil,
        nil,
        nil,
      ),
    ]
  end

  sig { returns(MIR::Conditional) }
  def bc_batch_step_expr
    MIR::Conditional.new(
      MIR::BinOp.new(">", MIR::Ident.new("__bw_size"), MIR::Lit.new("0")),
      MIR::Ident.new("__bw_size"),
      MIR::Ident.new("__bw_total"),
    )
  end

  sig { params(plan: PipelineBatchWindowPlan, source: MIR::Emittable, append_uses_allocator: T::Boolean).returns(T::Array[MIR::Emittable]) }
  def bc_materialized_loop_body(plan, source, append_uses_allocator:)
    [
      MIR::Let.new("__bw_end", bc_batch_end_expr, false, Type.new("i64"), nil),
      MIR::Let.new(plan.placeholder_var,
        MIR::SliceExpr.new(
          source,
          MIR::Cast.new(MIR::Ident.new("__bw_offset"), "usize", :intCast),
          MIR::Cast.new(MIR::Ident.new("__bw_end"), "usize", :intCast),
          nil,
        ),
        false,
        nil,
        nil),
      MIR::Let.new("__bw_val", plan.expr_mir, false, nil, nil),
      bc_append_value_stmt(plan.alloc, append_uses_allocator: append_uses_allocator),
      MIR::Set.new(MIR::Ident.new("__bw_offset"), MIR::Ident.new("__bw_end")),
    ]
  end

  sig { returns(MIR::Conditional) }
  def bc_batch_end_expr
    MIR::Conditional.new(
      MIR::BinOp.new("<",
        MIR::BinOp.new("+", MIR::Ident.new("__bw_offset"), MIR::Ident.new("__bw_step")),
        MIR::Ident.new("__bw_total")),
      MIR::BinOp.new("+", MIR::Ident.new("__bw_offset"), MIR::Ident.new("__bw_step")),
      MIR::Ident.new("__bw_total"),
    )
  end

  sig { params(alloc: Symbol, append_uses_allocator: T::Boolean).returns(MIR::ExprStmt) }
  def bc_append_value_stmt(alloc, append_uses_allocator:)
    append_args = if append_uses_allocator
      [MIR::AllocatorRef.new(alloc), MIR::Ident.new("__bw_val")]
    else
      [MIR::Ident.new("__bw_val")]
    end

    MIR::ExprStmt.new(
      MIR::MethodCall.new(
        MIR::Ident.new("res_list"),
        "append",
        append_args,
        true,
        MIR::CallableContract.no_ownership(append_args.length),
      ),
      nil,
    )
  end

  sig { params(plan: PipelineBatchWindowPlan).returns(T::Array[MIR::Emittable]) }
  def batch_window_setup_stmts(plan)
    [
      MIR::Let.new("res_list", MIR::MakeList.new(plan.result_zig, [], plan.alloc), true, nil, nil),
      MIR::Let.new("__bw",
        MIR::Call.new("CheatLib.BatchWindow(#{plan.element_zig}).init", [
          MIR::AllocatorRef.new(plan.alloc),
          MIR::Cast.new(plan.size_mir, "usize", :intCast),
          MIR::Lit.new(plan.timeout_ns),
        ], false, false, MIR::CallableContract.no_ownership(3)),
        true, nil, nil),
      MIR::DeferStmt.new(MIR::MethodCall.new(MIR::Ident.new("__bw"), "deinit", [], false, MIR::CallableContract.no_ownership(0))),
    ]
  end

  sig { params(plan: PipelineBatchWindowPlan, item_var: String).returns(MIR::BatchWindowPush) }
  def batch_window_push_stmt(plan, item_var)
    MIR::BatchWindowPush.new(
      "__bw",
      MIR::Ident.new(item_var),
      plan.placeholder_var,
      plan.element_zig,
      "res_list",
      plan.expr_mir,
      plan.alloc,
    )
  end

  sig { params(plan: PipelineBatchWindowPlan).returns(MIR::BatchWindowFlush) }
  def batch_window_flush_stmt(plan)
    MIR::BatchWindowFlush.new(
      "__bw",
      plan.placeholder_var,
      plan.element_zig,
      "res_list",
      plan.expr_mir,
      plan.alloc,
    )
  end
end
