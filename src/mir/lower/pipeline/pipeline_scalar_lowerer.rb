# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "../../../ast/ast"
require_relative "../../../ast/type"
require_relative "../../mir"
require_relative "./pipeline_records"

PipelineMaterializedScalarOp = T.type_alias do
  T.any(
    AST::CountOp,
    AST::SumOp,
    AST::AverageOp,
    AST::MinOp,
    AST::MaxOp,
    AST::AnyOp,
    AST::AllOp,
    AST::FindOp,
  )
end

class PipelineScalarServices < T::Struct
  const :visit_expr, T.proc.params(list_node: AST::Node, expr_node: AST::Node, placeholder: String).returns(MIR::Node)
  const :pipeline_block, T.proc.params(list_node: AST::Node, blk: T.proc.params(items: String, label: String).returns(T::Array[MIR::Emittable])).returns(MIR::BlockExpr)
  const :transpile_type, T.proc.params(type_info: PipelineTypeInput).returns(String)
end

class PipelineScalarLowerer
  extend T::Sig

  sig { params(services: PipelineScalarServices).void }
  def initialize(services:)
    @services = T.let(services, PipelineScalarServices)
  end

  sig { params(site: PipelineSite, op: PipelineMaterializedScalarOp).returns(MIR::BlockExpr) }
  def lower(site, op)
    case op
    when AST::CountOp
      lower_count(site, op)
    when AST::SumOp
      lower_sum(site, op)
    when AST::AverageOp
      lower_average(site, op)
    when AST::MinOp
      lower_min(site, op)
    when AST::MaxOp
      lower_max(site, op)
    when AST::AnyOp
      lower_any(site, op)
    when AST::AllOp
      lower_all(site, op)
    when AST::FindOp
      lower_find(site, op)
    end
  end

  private

  sig { params(site: PipelineSite, count_node: AST::CountOp).returns(MIR::BlockExpr) }
  def lower_count(site, count_node)
    list_node = site.list
    pred_mir = visit_pipeline_expr_mir(list_node, T.cast(count_node.expression, AST::Node))
    @services.pipeline_block.call(list_node, lambda do |items, label|
      [
        MIR::Let.new("count_result", MIR::Lit.new("0"), true, Type.new("i64"), nil),
        MIR::ForStmt.new(MIR::Ident.new(items), "it", [
          MIR::IfStmt.new(pred_mir, [
            MIR::Set.new(MIR::Ident.new("count_result"),
              MIR::BinOp.new("+", MIR::Ident.new("count_result"), MIR::Lit.new("1"))),
          ], nil),
        ], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("count_result")),
      ]
    end)
  end

  sig { params(site: PipelineSite, sum_node: AST::SumOp).returns(MIR::BlockExpr) }
  def lower_sum(site, sum_node)
    list_node = site.list
    expr_mir = visit_pipeline_expr_mir(list_node, T.cast(sum_node.expression, AST::Node))
    @services.pipeline_block.call(list_node, lambda do |items, label|
      [
        MIR::Let.new("sum_result", MIR::Lit.new("0"), true, Type.new("f64"), nil),
        MIR::ForStmt.new(MIR::Ident.new(items), "it", [
          MIR::Set.new(MIR::Ident.new("sum_result"),
            MIR::BinOp.new("+", MIR::Ident.new("sum_result"), expr_mir)),
        ], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("sum_result")),
      ]
    end)
  end

  sig { params(site: PipelineSite, avg_node: AST::AverageOp).returns(MIR::BlockExpr) }
  def lower_average(site, avg_node)
    list_node = site.list
    expr_mir = visit_pipeline_expr_mir(list_node, T.cast(avg_node.expression, AST::Node))
    @services.pipeline_block.call(list_node, lambda do |items, label|
      [
        MIR::Let.new("avg_sum", MIR::Lit.new("0"), true, Type.new("f64"), nil),
        MIR::Let.new("avg_count", MIR::FieldGet.new(MIR::Ident.new(items), "len"), false, nil, nil),
        MIR::ForStmt.new(MIR::Ident.new(items), "it", [
          MIR::Set.new(MIR::Ident.new("avg_sum"),
            MIR::BinOp.new("+", MIR::Ident.new("avg_sum"), expr_mir)),
        ], nil),
        MIR::BreakStmt.new(label,
          MIR::Conditional.new(
            MIR::BinOp.new("==", MIR::Ident.new("avg_count"), MIR::Lit.new("0")),
            MIR::Cast.new(MIR::Lit.new("0"), "f64", :as),
            MIR::BinOp.new("/", MIR::Ident.new("avg_sum"),
              MIR::Cast.new(MIR::Cast.new(MIR::Ident.new("avg_count"), nil, :floatFromInt), "f64", :as)))),
      ]
    end)
  end

  sig { params(site: PipelineSite, min_node: AST::MinOp).returns(MIR::BlockExpr) }
  def lower_min(site, min_node)
    list_node = site.list
    expr_mir = visit_pipeline_expr_mir(list_node, T.cast(min_node.expression, AST::Node))
    @services.pipeline_block.call(list_node, lambda do |items, label|
      [
        MIR::IfStmt.new(
          MIR::BinOp.new("==",
            MIR::FieldGet.new(MIR::Ident.new(items), "len"),
            MIR::Lit.new("0")),
          [MIR::Panic.new("MIN applied to empty list")],
          nil),
        MIR::Let.new("min_result", MIR::TypeSentinel.new(:max, "f64"),
          true, Type.new("f64"), nil),
        MIR::ForStmt.new(MIR::Ident.new(items), "it", [
          MIR::Let.new("min_val", expr_mir, false, nil, nil),
          MIR::IfStmt.new(
            MIR::BinOp.new("<", MIR::Ident.new("min_val"), MIR::Ident.new("min_result")),
            [MIR::Set.new(MIR::Ident.new("min_result"), MIR::Ident.new("min_val"))],
            nil),
        ], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("min_result")),
      ]
    end)
  end

  sig { params(site: PipelineSite, max_node: AST::MaxOp).returns(MIR::BlockExpr) }
  def lower_max(site, max_node)
    list_node = site.list
    expr_mir = visit_pipeline_expr_mir(list_node, T.cast(max_node.expression, AST::Node))
    @services.pipeline_block.call(list_node, lambda do |items, label|
      [
        MIR::IfStmt.new(
          MIR::BinOp.new("==",
            MIR::FieldGet.new(MIR::Ident.new(items), "len"),
            MIR::Lit.new("0")),
          [MIR::Panic.new("MAX applied to empty list")],
          nil),
        MIR::Let.new("max_result", MIR::TypeSentinel.new(:min, "f64"),
          true, Type.new("f64"), nil),
        MIR::ForStmt.new(MIR::Ident.new(items), "it", [
          MIR::Let.new("max_val", expr_mir, false, nil, nil),
          MIR::IfStmt.new(
            MIR::BinOp.new(">", MIR::Ident.new("max_val"), MIR::Ident.new("max_result")),
            [MIR::Set.new(MIR::Ident.new("max_result"), MIR::Ident.new("max_val"))],
            nil),
        ], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("max_result")),
      ]
    end)
  end

  sig { params(site: PipelineSite, any_node: AST::AnyOp).returns(MIR::BlockExpr) }
  def lower_any(site, any_node)
    list_node = site.list
    pred_mir = visit_pipeline_expr_mir(list_node, T.cast(any_node.expression, AST::Node))
    @services.pipeline_block.call(list_node, lambda do |items, label|
      [
        MIR::Let.new("any_result", MIR::Lit.new("false"), true, nil, nil),
        MIR::ForStmt.new(MIR::Ident.new(items), "it", [
          MIR::IfStmt.new(pred_mir, [
            MIR::Set.new(MIR::Ident.new("any_result"), MIR::Lit.new("true")),
            MIR::BreakStmt.new(nil, nil),
          ], nil),
        ], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("any_result")),
      ]
    end)
  end

  sig { params(site: PipelineSite, all_node: AST::AllOp).returns(MIR::BlockExpr) }
  def lower_all(site, all_node)
    list_node = site.list
    pred_mir = visit_pipeline_expr_mir(list_node, T.cast(all_node.expression, AST::Node))
    @services.pipeline_block.call(list_node, lambda do |items, label|
      [
        MIR::Let.new("all_result", MIR::Lit.new("true"), true, nil, nil),
        MIR::ForStmt.new(MIR::Ident.new(items), "it", [
          MIR::IfStmt.new(MIR::UnaryOp.new("!", pred_mir), [
            MIR::Set.new(MIR::Ident.new("all_result"), MIR::Lit.new("false")),
            MIR::BreakStmt.new(nil, nil),
          ], nil),
        ], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("all_result")),
      ]
    end)
  end

  sig { params(site: PipelineSite, find_node: AST::FindOp).returns(MIR::BlockExpr) }
  def lower_find(site, find_node)
    list_node = site.list
    elem_zig_type = @services.transpile_type.call(T.must(list_node.full_type!.element_type).resolved.to_s)
    pred_mir = visit_pipeline_expr_mir(list_node, T.cast(find_node.expression, AST::Node))
    @services.pipeline_block.call(list_node, lambda do |items, label|
      [
        MIR::Let.new("find_result",
          MIR::Undef.new(nil), true, Type.new(elem_zig_type), nil),
        MIR::Let.new("find_found", MIR::Lit.new("false"), true, nil, nil),
        MIR::ForStmt.new(MIR::Ident.new(items), "it", [
          MIR::Let.new("find_matches", pred_mir, false, nil, nil),
          MIR::IfStmt.new(MIR::Ident.new("find_matches"), [
            MIR::Set.new(MIR::Ident.new("find_result"), MIR::Ident.new("it")),
            MIR::Set.new(MIR::Ident.new("find_found"), MIR::Lit.new("true")),
            MIR::BreakStmt.new(nil, nil),
          ], nil),
        ], nil),
        MIR::BreakStmt.new(label,
          MIR::Conditional.new(
            MIR::Ident.new("find_found"),
            MIR::Cast.new(MIR::Ident.new("find_result"), "?#{elem_zig_type}", :as),
            MIR::Lit.new("null"))),
      ]
    end)
  end

  sig { params(list_node: AST::Node, expr_node: AST::Node, placeholder: String).returns(MIR::Node) }
  def visit_pipeline_expr_mir(list_node, expr_node, placeholder = "it")
    @services.visit_expr.call(list_node, expr_node, placeholder)
  end
end
