# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "../../../ast/ast"
require_relative "../../../ast/type"
require_relative "../../mir"
require_relative "./pipeline_records"

PipelineBindingFoldOp = T.type_alias do
  T.any(
    AST::SumOp,
    AST::CountOp,
    AST::AverageOp,
    AST::MinOp,
    AST::MaxOp,
    AST::AnyOp,
    AST::AllOp,
    AST::FindOp,
  )
end

class PipelineBindingUnnestChain < T::Struct
  const :source, AST::Node
  const :outer_binding, String
  const :unnest_expr, AST::Node
  const :inner_binding, T.nilable(String)
  const :stages, T::Array[AST::Node]
  const :fold, PipelineBindingFoldOp
end

class PipelineBindingNames < T::Struct
  const :source, String
  const :unnest, String
  const :accumulator, String
  const :sum, String
  const :count, String
  const :value, String
  const :result, String
  const :found, String
end

class PipelineBindingFoldPlan < T::Struct
  const :init_stmts, T::Array[MIR::Emittable]
  const :loop_body_stmts, T::Array[MIR::Emittable]
  const :post_inner_stmts, T::Array[MIR::Emittable]
  const :result_expr, MIR::Node
end

class PipelineBindingChainLowerer < T::Struct
  extend T::Sig
  const :bc_target, T.proc.returns(T::Boolean)
  const :next_label, T.proc.returns(String)
  const :set_current_label, T.proc.params(label: String).void
  const :pipe_binding_zig_name, T.proc.params(clear_name: String).returns(String)
  const :visit_mir, T.proc.params(node: AST::Node).returns(MIR::Node)
  const :visit_mir_with_placeholder, T.proc.params(node: AST::Node, placeholder: String).returns(MIR::Node)
  const :visit_mir_with_reduce_placeholders, T.proc.params(node: AST::Node, item_placeholder: String, acc_placeholder: String).returns(MIR::Node)
  const :transpile_type, T.proc.params(type_info: PipelineTypeInput).returns(String)
  const :with_named_bindings, T.proc.params(bindings: T::Hash[String, String], blk: T.proc.returns(MIR::BlockExpr)).returns(MIR::BlockExpr)
  const :ast_uses_placeholder, T.proc.params(node: AST::Node).returns(T::Boolean)

  sig { params(node: AST::BinaryOp).returns(T.nilable(PipelineBindingUnnestChain)) }
  def unwrap_chain(node)
    return nil unless node.smooth?

    fold = node.right
    return nil unless AST.pipeline_range_fold?(fold)

    cursor = T.let(node.left, AST::Node)
    stages = T.let([], T::Array[AST::Node])
    while cursor.is_a?(AST::BinaryOp) && cursor.smooth?
      stage_rhs = T.cast(cursor.right, AST::Node)
      if AST.pipeline_select_filter_op?(stage_rhs)
        stages.unshift(stage_rhs)
        cursor = cursor.left
      else
        break
      end
    end

    return nil unless cursor.is_a?(AST::BinaryOp) && cursor.smooth?

    lhs = cursor.left
    rhs = cursor.right
    return nil unless rhs.is_a?(AST::UnnestOp)

    unnest_expr = T.let(T.cast(rhs.expression, AST::Node), AST::Node)
    inner_binding = T.let(nil, T.nilable(String))
    if unnest_expr.is_a?(AST::BinaryOp) && unnest_expr.op == :BIND_VAR
      inner_binding = unnest_expr.right.name.to_s
      unnest_expr = unnest_expr.left
    end

    return nil unless lhs.is_a?(AST::BinaryOp) && lhs.op == :BIND_VAR

    PipelineBindingUnnestChain.new(
      source: lhs.left,
      outer_binding: lhs.right.name.to_s,
      unnest_expr: unnest_expr,
      inner_binding: inner_binding,
      stages: stages,
      fold: T.cast(fold, PipelineBindingFoldOp),
    )
  end

  sig { params(chain: PipelineBindingUnnestChain, smooth_node: AST::BinaryOp).returns(MIR::BlockExpr) }
  def lower(chain, smooth_node)
    outer_name = chain.outer_binding
    outer_zig = self.pipe_binding_zig_name.call(outer_name)
    inner_name = chain.inner_binding
    inner_zig = inner_name ? self.pipe_binding_zig_name.call(inner_name) : "__bc_inner"
    label = self.next_label.call
    self.set_current_label.call(label)
    names = binding_names(label)
    bindings = T.let({ outer_name => outer_zig }, T::Hash[String, String])
    bindings[inner_name] = inner_zig if inner_name

    self.with_named_bindings.call(bindings, lambda do
      source_mir = self.visit_mir.call(chain.source)
      unnest_mir = self.visit_mir.call(chain.unnest_expr)
      fold_plan = lower_binding_fold(chain.fold, chain.stages, inner_zig, smooth_node, names)
      loop_body = binding_loop_body(chain, inner_zig, fold_plan.loop_body_stmts)
      inner_loop = MIR::ForStmt.new(
        MIR::ItemsAccess.new(MIR::Ident.new(names.unnest), true),
        inner_zig, loop_body, nil)
      outer_loop = MIR::ForStmt.new(
        MIR::ItemsAccess.new(MIR::Ident.new(names.source), true),
        outer_zig,
        [
          MIR::Let.new(names.unnest, unnest_mir, false, nil, nil),
          inner_loop,
          *fold_plan.post_inner_stmts,
        ],
        nil)

      MIR::BlockExpr.new(label, [
        MIR::Let.new(names.source, source_mir, false, nil, nil),
        *fold_plan.init_stmts,
        outer_loop,
        MIR::BreakStmt.new(label, fold_plan.result_expr),
      ])
    end)
  end

  private

  sig { params(label: String).returns(PipelineBindingNames) }
  def binding_names(label)
    suffix = self.bc_target.call ? "_#{label.sub('__pblk', 'b')}" : ""
    PipelineBindingNames.new(
      source: "__bc_src#{suffix}",
      unnest: "__bc_unn#{suffix}",
      accumulator: "__bc_acc#{suffix}",
      sum: "__bc_sum#{suffix}",
      count: "__bc_cnt#{suffix}",
      value: "__bc_val#{suffix}",
      result: "__bc_result#{suffix}",
      found: "__bc_found#{suffix}",
    )
  end

  sig { params(chain: PipelineBindingUnnestChain, inner_zig: String, loop_body: T::Array[MIR::Emittable]).returns(T::Array[MIR::Emittable]) }
  def binding_loop_body(chain, inner_zig, loop_body)
    return loop_body if chain.inner_binding || inner_capture_required?(chain)

    [MIR::Suppress.new(inner_zig), *loop_body]
  end

  sig { params(chain: PipelineBindingUnnestChain).returns(T::Boolean) }
  def inner_capture_required?(chain)
    return true if chain.fold.is_a?(AST::FindOp)

    fold_expr = fold_expression(chain.fold)
    return true if fold_expr && self.ast_uses_placeholder.call(fold_expr)

    chain.stages.any? do |stage|
      stage.is_a?(AST::WhereOp) &&
        self.ast_uses_placeholder.call(T.cast(stage.expression, AST::Node))
    end
  end

  sig { params(fold: PipelineBindingFoldOp).returns(T.nilable(AST::Node)) }
  def fold_expression(fold)
    case fold
    when AST::SumOp, AST::CountOp, AST::AverageOp, AST::MinOp, AST::MaxOp, AST::AnyOp, AST::AllOp, AST::FindOp
      T.cast(fold.expression, AST::Node)
    end
  end

  sig { params(fold: PipelineBindingFoldOp, stages: T::Array[AST::Node], placeholder: String, smooth_node: AST::BinaryOp, names: PipelineBindingNames).returns(PipelineBindingFoldPlan) }
  def lower_binding_fold(fold, stages, placeholder, smooth_node, names)
    case fold
    when AST::SumOp
      expr = visit_placeholder_expr(T.cast(fold.expression, AST::Node), placeholder)
      init = [MIR::Let.new(names.accumulator, MIR::Lit.new("0"), true, Type.new("f64"), nil)]
      accum = [MIR::Set.new(MIR::Ident.new(names.accumulator),
        MIR::BinOp.new("+", MIR::Ident.new(names.accumulator), expr))]
      fold_plan(init, wrap_stages(stages, placeholder, accum), [], MIR::Ident.new(names.accumulator))
    when AST::CountOp
      pred = visit_placeholder_expr(T.cast(fold.expression, AST::Node), placeholder)
      init = [MIR::Let.new(names.accumulator, MIR::Lit.new("0"), true, Type.new("i64"), nil)]
      accum = [MIR::IfStmt.new(pred, [MIR::Set.new(MIR::Ident.new(names.accumulator),
        MIR::BinOp.new("+", MIR::Ident.new(names.accumulator), MIR::Lit.new("1")))], nil)]
      fold_plan(init, wrap_stages(stages, placeholder, accum), [], MIR::Ident.new(names.accumulator))
    when AST::AverageOp
      expr = visit_placeholder_expr(T.cast(fold.expression, AST::Node), placeholder)
      init = [
        MIR::Let.new(names.sum, MIR::Lit.new("0"), true, Type.new("f64"), nil),
        MIR::Let.new(names.count, MIR::Lit.new("0.0"), true, Type.new("f64"), nil),
      ]
      accum = [
        MIR::Set.new(MIR::Ident.new(names.sum),
          MIR::BinOp.new("+", MIR::Ident.new(names.sum), expr)),
        MIR::Set.new(MIR::Ident.new(names.count),
          MIR::BinOp.new("+", MIR::Ident.new(names.count), MIR::Lit.new("1.0"))),
      ]
      result = MIR::Conditional.new(
        MIR::BinOp.new("==", MIR::Ident.new(names.count), MIR::Lit.new("0.0")),
        MIR::Cast.new(MIR::Lit.new("0"), "f64", :as),
        MIR::BinOp.new("/", MIR::Ident.new(names.sum), MIR::Ident.new(names.count)))
      fold_plan(init, wrap_stages(stages, placeholder, accum), [], result)
    when AST::MinOp
      expr = visit_placeholder_expr(T.cast(fold.expression, AST::Node), placeholder)
      init = [MIR::Let.new(names.accumulator,
        MIR::TypeSentinel.new(:max, "f64"), true, Type.new("f64"), nil)]
      accum = [
        MIR::Let.new(names.value, expr, false, nil, nil),
        MIR::IfStmt.new(
          MIR::BinOp.new("<", MIR::Ident.new(names.value), MIR::Ident.new(names.accumulator)),
          [MIR::Set.new(MIR::Ident.new(names.accumulator), MIR::Ident.new(names.value))], nil),
      ]
      fold_plan(init, wrap_stages(stages, placeholder, accum), [], MIR::Ident.new(names.accumulator))
    when AST::MaxOp
      expr = visit_placeholder_expr(T.cast(fold.expression, AST::Node), placeholder)
      init = [MIR::Let.new(names.accumulator,
        MIR::TypeSentinel.new(:min, "f64"), true, Type.new("f64"), nil)]
      accum = [
        MIR::Let.new(names.value, expr, false, nil, nil),
        MIR::IfStmt.new(
          MIR::BinOp.new(">", MIR::Ident.new(names.value), MIR::Ident.new(names.accumulator)),
          [MIR::Set.new(MIR::Ident.new(names.accumulator), MIR::Ident.new(names.value))], nil),
      ]
      fold_plan(init, wrap_stages(stages, placeholder, accum), [], MIR::Ident.new(names.accumulator))
    when AST::AnyOp
      pred = visit_placeholder_expr(T.cast(fold.expression, AST::Node), placeholder)
      init = [MIR::Let.new(names.accumulator, MIR::Lit.new("false"), true, nil, nil)]
      accum = [MIR::IfStmt.new(pred, [
        MIR::Set.new(MIR::Ident.new(names.accumulator), MIR::Lit.new("true")),
        MIR::BreakStmt.new(nil, nil),
      ], nil)]
      fold_plan(init, wrap_stages(stages, placeholder, accum), [], MIR::Ident.new(names.accumulator))
    when AST::AllOp
      pred = visit_placeholder_expr(T.cast(fold.expression, AST::Node), placeholder)
      init = [MIR::Let.new(names.accumulator, MIR::Lit.new("true"), true, nil, nil)]
      accum = [MIR::IfStmt.new(MIR::UnaryOp.new("!", pred), [
        MIR::Set.new(MIR::Ident.new(names.accumulator), MIR::Lit.new("false")),
        MIR::BreakStmt.new(nil, nil),
      ], nil)]
      fold_plan(init, wrap_stages(stages, placeholder, accum), [], MIR::Ident.new(names.accumulator))
    when AST::FindOp
      result_ft = Type.new(smooth_node.full_type!)
      find_zig = result_ft.optional? ? self.transpile_type.call(T.must(result_ft.wrapped_type).resolved.to_s) : placeholder
      pred = visit_placeholder_expr(T.cast(fold.expression, AST::Node), placeholder)
      init = [
        MIR::Let.new(names.result, MIR::Undef.new(nil), true, Type.new(find_zig), nil),
        MIR::Let.new(names.found, MIR::Lit.new("false"), true, nil, nil),
      ]
      accum = [MIR::IfStmt.new(pred, [
        MIR::Set.new(MIR::Ident.new(names.result), MIR::Ident.new(placeholder)),
        MIR::Set.new(MIR::Ident.new(names.found), MIR::Lit.new("true")),
        MIR::BreakStmt.new(nil, nil),
      ], nil)]
      post_inner = [MIR::IfStmt.new(MIR::Ident.new(names.found), [MIR::BreakStmt.new(nil, nil)], nil)]
      result = MIR::Conditional.new(
        MIR::Ident.new(names.found),
        MIR::Cast.new(MIR::Ident.new(names.result), "?#{find_zig}", :as),
        MIR::Lit.new("null"))
      fold_plan(init, wrap_stages(stages, placeholder, accum), post_inner, result)
    end
  end

  sig { params(init: T::Array[MIR::Emittable], body: T::Array[MIR::Emittable], post_inner: T::Array[MIR::Emittable], result: MIR::Node).returns(PipelineBindingFoldPlan) }
  def fold_plan(init, body, post_inner, result)
    PipelineBindingFoldPlan.new(
      init_stmts: init,
      loop_body_stmts: body,
      post_inner_stmts: post_inner,
      result_expr: result,
    )
  end

  sig { params(stages: T::Array[AST::Node], placeholder: String, accum_stmts: T::Array[MIR::Emittable]).returns(T::Array[MIR::Emittable]) }
  def wrap_stages(stages, placeholder, accum_stmts)
    body = T.let(accum_stmts, T::Array[MIR::Emittable])
    stages.reverse_each do |stage|
      if stage.is_a?(AST::SelectOp)
        raise "SELECT is not supported in AS $v binding chains. " \
              "Use WHERE to filter or name the projection with AS $o before the fold."
      end
      next unless stage.is_a?(AST::WhereOp)

      pred = visit_placeholder_expr(T.cast(stage.expression, AST::Node), placeholder)
      body = [MIR::IfStmt.new(pred, body, nil)]
    end
    body
  end

  sig { params(expr: AST::Node, placeholder: String).returns(MIR::Node) }
  def visit_placeholder_expr(expr, placeholder)
    self.visit_mir_with_placeholder.call(expr, placeholder)
  end
end
