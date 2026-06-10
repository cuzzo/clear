# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "../../../ast/ast"
require_relative "../../../ast/type"
require_relative "../../cleanup_entry"
require_relative "../../mir"
require_relative "./pipeline_records"

PipelineListTerminalOp = T.type_alias do
  T.any(
    AST::WhereOp,
    AST::SelectOp,
    AST::LimitOp,
    AST::TakeWhileOp,
    AST::SkipOp,
    AST::UnnestOp,
    AST::ReduceOp,
    AST::WindowOp,
    AST::OrderByOp,
    AST::JoinOp,
    AST::TapOp,
  )
end

class PipelineListLowerer < T::Struct
  extend T::Sig
  const :visit_mir, T.proc.params(node: AST::Node).returns(MIR::Node)
  const :visit_expr, T.proc.params(list_node: AST::Node, expr_node: AST::Node, placeholder: String).returns(MIR::Node)
  const :visit_reduce_expr, T.proc.params(expr_node: AST::Node, item_placeholder: String, acc_placeholder: String).returns(MIR::Node)
  const :visit_body, T.proc.params(body_stmts: T::Array[AST::Node], placeholder: String).returns(T::Array[MIR::Emittable])
  const :visit_join_lambda, T.proc.params(body: AST::Node, join_params: T::Hash[String, String]).returns(MIR::Node)
  const :pipeline_block, T.proc.params(list_node: AST::Node, blk: T.proc.params(items: String, label: String).returns(T::Array[MIR::Emittable])).returns(MIR::BlockExpr)
  const :transpile_type, T.proc.params(type_info: PipelineTypeInput).returns(String)
  const :pipeline_alloc, T.proc.params(smooth_node: AST::BinaryOp).returns(Symbol)
  const :pipeline_result_alloc, T.proc.returns(Symbol)
  const :source_shape, T.proc.params(source_node: AST::Node).returns(PipelineSourceShape)
  const :next_label, T.proc.returns(String)
  const :set_current_label, T.proc.params(label: String).void
  const :append_owned_value_stmt, T.proc.params(receiver: String, alloc: Symbol, value_expr: MIR::Node).returns(MIR::Emittable)
  const :borrowed_pipeline_value, T.proc.params(value: MIR::Node, type_info: Type, alloc: Symbol).returns(MIR::Node)
  const :cleanup_bearing_type, T.proc.params(type_info: Type).returns(T::Boolean)
  const :owning_pipeline_temp_stmts, T.proc.params(name: String, source: MIR::Node, type_info: Type, zig_type: String, alloc: Symbol).returns(T::Array[MIR::Emittable])

  sig { params(site: PipelineSite, op: PipelineListTerminalOp).returns(MIR::BlockExpr) }
  def lower(site, op)
    case op
    when AST::WhereOp
      lower_where(site, T.cast(op.expression, AST::Node))
    when AST::SelectOp
      lower_select(site, T.cast(op.expression, AST::Node))
    when AST::LimitOp
      lower_limit(site, op)
    when AST::TakeWhileOp
      lower_take_while(site, T.cast(op.expression, AST::Node))
    when AST::SkipOp
      lower_skip(site, op)
    when AST::UnnestOp
      lower_unnest(site, op)
    when AST::ReduceOp
      lower_reduce(site, op)
    when AST::WindowOp
      lower_window(site, op)
    when AST::OrderByOp
      lower_order_by(site, op)
    when AST::JoinOp
      lower_join(site, op)
    when AST::TapOp
      lower_tap(site, op)
    end
  end

  sig { params(site: PipelineSite, expr_node: AST::Node).returns(MIR::BlockExpr) }
  def lower_where_expr(site, expr_node)
    lower_where(site, expr_node)
  end

  sig { params(site: PipelineSite, expr_node: AST::Node).returns(MIR::BlockExpr) }
  def lower_select_expr(site, expr_node)
    lower_select(site, expr_node)
  end

  sig { params(site: PipelineSite, expr_node: AST::Node).returns(MIR::BlockExpr) }
  def lower_take_while_expr(site, expr_node)
    lower_take_while(site, expr_node)
  end

  private

  sig { params(site: PipelineSite, expr_node: AST::Node).returns(MIR::BlockExpr) }
  def lower_where(site, expr_node)
    list_node = site.list
    smooth_node = site.options
    elem_type = T.must(list_node.full_type!.element_type).resolved.to_s
    elem_zig = self.transpile_type.call(elem_type)
    alloc = self.pipeline_alloc.call(smooth_node)
    pred_mir = visit_pipeline_expr_mir(list_node, expr_node)
    self.pipeline_block.call(list_node, lambda do |items, label|
      [
        MIR::Let.new("res_list",
          MIR::MakeList.new(elem_zig, [], alloc), true, nil, nil),
        MIR::ForStmt.new(MIR::Ident.new(items), "it", [
          MIR::Let.new("matches", pred_mir, false, nil, nil),
          MIR::IfStmt.new(MIR::Ident.new("matches"), [
            self.append_owned_value_stmt.call("res_list", alloc,
              self.borrowed_pipeline_value.call(MIR::Ident.new("it"), Type.new(elem_type), alloc)),
          ], nil),
        ], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("res_list")),
      ]
    end)
  end

  sig { params(site: PipelineSite, expr_node: AST::Node).returns(MIR::BlockExpr) }
  def lower_select(site, expr_node)
    list_node = site.list
    smooth_node = site.options
    res_type = expr_node.full_type!
    res_zig = self.transpile_type.call(res_type)
    alloc = self.pipeline_alloc.call(smooth_node)
    expr_mir = visit_pipeline_expr_mir(list_node, expr_node)
    self.pipeline_block.call(list_node, lambda do |items, label|
      [
        MIR::Let.new("res_list",
          MIR::MakeList.new(res_zig, [], alloc), true, nil, nil),
        MIR::ForStmt.new(MIR::Ident.new(items), "it", [
          MIR::Let.new("val", expr_mir, false, nil, nil),
          self.append_owned_value_stmt.call("res_list", alloc,
            self.borrowed_pipeline_value.call(MIR::Ident.new("val"), Type.new(res_type), alloc)),
        ], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("res_list")),
      ]
    end)
  end

  sig { params(site: PipelineSite, limit_node: AST::LimitOp).returns(MIR::BlockExpr) }
  def lower_limit(site, limit_node)
    list_node = site.list
    smooth_node = site.options
    source_shape = self.source_shape.call(list_node)
    elem_type = source_shape.element_type.resolved.to_s
    elem_zig = self.transpile_type.call(elem_type)
    alloc = self.pipeline_alloc.call(smooth_node)
    count_mir = self.visit_mir.call(T.cast(limit_node.count, AST::Node))

    if source_shape.bc_infinite_stream?
      label = self.next_label.call
      source_mir = self.visit_mir.call(list_node)
      self.set_current_label.call(label)
      return MIR::BlockExpr.new(label, [
        MIR::Let.new("__lim_src", source_mir, false, nil, nil),
        MIR::Let.new("__lim_n", count_mir, false, nil, nil),
        MIR::Let.new("__lim_res",
          MIR::MakeList.new(elem_zig, [], alloc), true, nil, nil),
        MIR::Let.new("__lim_i", MIR::Lit.new("0_i64"), true, nil, nil),
        MIR::ForStmt.new(MIR::Ident.new("__lim_src"), "__lim_it", [
          MIR::IfStmt.new(
            MIR::BinOp.new(">=", MIR::Ident.new("__lim_i"), MIR::Ident.new("__lim_n")),
            [MIR::BreakStmt.new(nil, nil)], nil),
          MIR::ExprStmt.new(MIR::MethodCall.new(
            MIR::Ident.new("__lim_res"), "append",
            [MIR::Ident.new("__lim_it")], true,
            MIR::CallableContract.no_ownership(1)), nil),
          MIR::Set.new(MIR::Ident.new("__lim_i"),
            MIR::BinOp.new("+", MIR::Ident.new("__lim_i"), MIR::Lit.new("1_i64")), nil),
        ], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("__lim_res")),
      ])
    end

    self.pipeline_block.call(list_node, lambda do |items, label|
      [
        MIR::Let.new("lim_requested",
          MIR::Cast.new(count_mir, "usize", :intCast), false, nil, nil),
        MIR::Let.new("lim_actual",
          MIR::Call.new("@min", [MIR::Ident.new("lim_requested"),
                                 MIR::ListLength.new(MIR::Ident.new(items))], false),
          false, nil, nil),
        MIR::Let.new("lim_result",
          MIR::MakeList.new(elem_zig, [], alloc), true, nil, nil),
        MIR::ForStmt.new(
          MIR::SliceExpr.new(MIR::Ident.new(items),
            MIR::Lit.new("0"), MIR::Ident.new("lim_actual"), nil),
          "it",
          [
            self.append_owned_value_stmt.call("lim_result", alloc,
              self.borrowed_pipeline_value.call(MIR::Ident.new("it"), Type.new(elem_type), alloc)),
          ],
          nil
        ),
        MIR::BreakStmt.new(label, MIR::Ident.new("lim_result")),
      ]
    end)
  end

  sig { params(site: PipelineSite, expr_node: AST::Node).returns(MIR::BlockExpr) }
  def lower_take_while(site, expr_node)
    list_node = site.list
    smooth_node = site.options
    elem_type = T.must(list_node.full_type!.element_type).resolved.to_s
    elem_zig = self.transpile_type.call(elem_type)
    alloc = self.pipeline_alloc.call(smooth_node)
    pred_mir = visit_pipeline_expr_mir(list_node, expr_node)
    self.pipeline_block.call(list_node, lambda do |items, label|
      [
        MIR::Let.new("res_list",
          MIR::MakeList.new(elem_zig, [], alloc), true, nil, nil),
        MIR::ForStmt.new(MIR::Ident.new(items), "it", [
          MIR::Let.new("matches", pred_mir, false, nil, nil),
          MIR::IfStmt.new(MIR::UnaryOp.new("!", MIR::Ident.new("matches")),
            [MIR::BreakStmt.new(nil, nil)], nil),
          self.append_owned_value_stmt.call("res_list", alloc,
            self.borrowed_pipeline_value.call(MIR::Ident.new("it"), Type.new(elem_type), alloc)),
        ], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("res_list")),
      ]
    end)
  end

  sig { params(site: PipelineSite, skip_node: AST::SkipOp).returns(MIR::BlockExpr) }
  def lower_skip(site, skip_node)
    list_node = site.list
    label = self.next_label.call
    source_mir = self.visit_mir.call(list_node)
    self.set_current_label.call(label)
    count_mir = self.visit_mir.call(T.cast(skip_node.count, AST::Node))

    MIR::BlockExpr.new(label, [
      MIR::Let.new("__skip_src", source_mir, false, nil, nil),
      MIR::Let.new("__skip_items",
        MIR::ItemsAccess.new(MIR::Ident.new("__skip_src"), true), false, nil, nil),
      MIR::Let.new("skip_requested",
        MIR::Cast.new(count_mir, "usize", :intCast), false, nil, nil),
      MIR::Let.new("skip_actual",
        MIR::Call.new("@min", [MIR::Ident.new("skip_requested"),
                               MIR::ListLength.new(MIR::Ident.new("__skip_items"))], false),
        false, nil, nil),
      MIR::BreakStmt.new(label,
        MIR::SliceExpr.new(MIR::Ident.new("__skip_items"),
                           MIR::Ident.new("skip_actual"), nil, nil)),
    ])
  end

  sig { params(site: PipelineSite, unnest_node: AST::UnnestOp).returns(MIR::BlockExpr) }
  def lower_unnest(site, unnest_node)
    list_node = site.list
    smooth_node = site.options
    inner_elem_type = T.must(unnest_node.full_type!.element_type).resolved.to_s
    inner_zig = self.transpile_type.call(inner_elem_type)
    alloc = self.pipeline_alloc.call(smooth_node)
    expr_mir = visit_pipeline_expr_mir(list_node, T.cast(unnest_node.expression, AST::Node))
    self.pipeline_block.call(list_node, lambda do |items, label|
      [
        MIR::Let.new("res_list",
          MIR::MakeList.new(inner_zig, [], alloc), true, nil, nil),
        MIR::ForStmt.new(MIR::Ident.new(items), "it", [
          MIR::Let.new("unn_inner", expr_mir, false, nil, nil),
          MIR::Let.new("unn_inner_items",
            MIR::ItemsAccess.new(MIR::Ident.new("unn_inner"), true), false, nil, nil),
          MIR::ForStmt.new(MIR::Ident.new("unn_inner_items"), "inner_it", [
            MIR::ExprStmt.new(MIR::MethodCall.new(
              MIR::Ident.new("res_list"), "append",
              [MIR::AllocatorRef.new(alloc), MIR::Ident.new("inner_it")], true,
              MIR::CallableContract.no_ownership(2)), nil),
          ], nil),
        ], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("res_list")),
      ]
    end)
  end

  sig { params(site: PipelineSite, reduce_node: AST::ReduceOp).returns(MIR::BlockExpr) }
  def lower_reduce(site, reduce_node)
    list_node = site.list
    acc_zig = self.transpile_type.call(reduce_node.full_type!)
    init_mir = self.visit_mir.call(T.cast(reduce_node.initial_value, AST::Node))
    expr_mir = self.visit_reduce_expr.call(T.cast(reduce_node.expression, AST::Node), "it", "acc")
    self.pipeline_block.call(list_node, lambda do |items, label|
      [
        MIR::Let.new("acc", init_mir, true, Type.new(acc_zig), nil),
        MIR::ForStmt.new(MIR::Ident.new(items), "it", [
          MIR::Set.new(MIR::Ident.new("acc"), expr_mir),
        ], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("acc")),
      ]
    end)
  end

  sig { params(site: PipelineSite, window_node: AST::WindowOp).returns(MIR::BlockExpr) }
  def lower_window(site, window_node)
    list_node = site.list
    smooth_node = site.options
    expr_type_str = window_node.expression.full_type!.to_s
    res_zig = self.transpile_type.call(expr_type_str)
    alloc = self.pipeline_alloc.call(smooth_node)
    size_mir = self.visit_mir.call(T.cast(window_node.size, AST::Node))
    expr_mir = self.visit_expr.call(list_node, T.cast(window_node.expression, AST::Node), "window_slice")
    self.pipeline_block.call(list_node, lambda do |items, label|
      [
        MIR::Let.new("res_list",
          MIR::MakeList.new(res_zig, [], alloc), true, nil, nil),
        MIR::ScopeBlock.new([
          MIR::Let.new("__w_size",
            MIR::Cast.new(size_mir, "usize", :intCast), false, nil, nil),
          MIR::IfStmt.new(
            MIR::BinOp.new(">=",
              MIR::FieldGet.new(MIR::Ident.new(items), "len"),
              MIR::Ident.new("__w_size")),
            [
              MIR::Let.new("__wi", MIR::Lit.new("0"), true, Type.new("usize"), nil),
              MIR::WhileStmt.new(
                MIR::BinOp.new("<=",
                  MIR::Ident.new("__wi"),
                  MIR::BinOp.new("-",
                    MIR::FieldGet.new(MIR::Ident.new(items), "len"),
                    MIR::Ident.new("__w_size"))),
                [
                  MIR::Let.new("window_slice",
                    MIR::SliceExpr.new(MIR::Ident.new(items),
                      MIR::Ident.new("__wi"),
                      MIR::BinOp.new("+", MIR::Ident.new("__wi"), MIR::Ident.new("__w_size")),
                      nil),
                    false, nil, nil),
                  MIR::Let.new("val", expr_mir, false, nil, nil),
                  MIR::ExprStmt.new(MIR::MethodCall.new(
                    MIR::Ident.new("res_list"), "append",
                    [MIR::AllocatorRef.new(alloc), MIR::Ident.new("val")],
                    true, MIR::CallableContract.no_ownership(2)), nil),
                ],
                nil,
                MIR::Set.new(MIR::Ident.new("__wi"),
                  MIR::BinOp.new("+", MIR::Ident.new("__wi"), MIR::Lit.new("1"))),
                nil, nil),
            ], nil),
        ]),
        MIR::BreakStmt.new(label, MIR::Ident.new("res_list")),
      ]
    end)
  end

  sig { params(site: PipelineSite, order_node: AST::OrderByOp).returns(MIR::BlockExpr) }
  def lower_order_by(site, order_node)
    list_node = site.list
    smooth_node = site.options
    elem_type = T.must(list_node.full_type!.element_type).resolved.to_s
    elem_zig = self.transpile_type.call(elem_type)
    alloc = self.pipeline_alloc.call(smooth_node)
    key_expr = T.cast(order_node.expression, AST::Node)
    key_a = self.visit_expr.call(list_node, key_expr, "a")
    key_b = self.visit_expr.call(list_node, key_expr, "b")
    self.pipeline_block.call(list_node, lambda do |items, label|
      result_name = "#{label}_ord_result"
      [
        MIR::Let.new(result_name,
          MIR::MakeList.new(elem_zig, [], alloc), true, nil, "_ = &#{result_name};"),
        MIR::ForStmt.new(MIR::Ident.new(items), "it", [
          self.append_owned_value_stmt.call(result_name, alloc,
            self.borrowed_pipeline_value.call(MIR::Ident.new("it"), Type.new(elem_type), alloc)),
        ], nil),
        MIR::Sort.new(elem_zig,
          MIR::FieldGet.new(MIR::Ident.new(result_name), "items"),
          key_a, key_b),
        MIR::BreakStmt.new(label, MIR::Ident.new(result_name)),
      ]
    end)
  end

  sig { params(site: PipelineSite, join_node: AST::JoinOp).returns(MIR::BlockExpr) }
  def lower_join(site, join_node)
    list_node = site.list
    left_type_info = T.must(list_node.full_type!.element_type)
    left_zig = self.transpile_type.call(left_type_info.resolved.to_s)
    right_src_mir = self.visit_mir.call(T.cast(join_node.right_source, AST::Node))
    right_type_info = join_node.right_source.full_type!
    right_zig = self.transpile_type.call(right_type_info.element_type.resolved.to_s)
    result_zig = "struct { left: #{left_zig}, right: ?#{right_zig} }"
    alloc = self.pipeline_result_alloc.call
    left_owns = self.cleanup_bearing_type.call(left_type_info)
    right_owns = self.cleanup_bearing_type.call(right_type_info.element_type)
    pred_mir = join_predicate_mir(list_node, join_node)
    label = self.next_label.call
    source_mir = self.visit_mir.call(list_node)
    self.set_current_label.call(label)

    left_value = left_owns ? MIR::Ident.new("__jl_owned") : MIR::Ident.new("__jl")
    right_value = MIR::Ident.new("__match")
    after_append = ownership_sink_marks(left_owns: left_owns, right_owns: right_owns)

    MIR::BlockExpr.new(label, [
      MIR::Let.new("__jl_src", source_mir, false, nil, nil),
      MIR::Let.new("__jr_src", right_src_mir, false, nil, nil),
      MIR::Let.new("__jl_items",
        MIR::ItemsAccess.new(MIR::Ident.new("__jl_src"), true), false, nil, nil),
      MIR::Let.new("__jr_items",
        MIR::ItemsAccess.new(MIR::Ident.new("__jr_src"), true), false, nil, nil),
      MIR::Let.new("res_list",
        MIR::ContainerInit.new("std.ArrayListUnmanaged(#{result_zig})",
          :array_list_empty, alloc, nil), true, nil, nil),
      MIR::ForStmt.new(MIR::Ident.new("__jl_items"), "__jl", [
        MIR::Let.new("__match", MIR::Lit.new("null"), true, Type.new("?#{right_zig}"), nil),
        *right_cleanup_stmts(right_owns, alloc, right_zig),
        MIR::ForStmt.new(MIR::Ident.new("__jr_items"), "__jr", [
          MIR::IfStmt.new(pred_mir, [
            MIR::Set.new(MIR::Ident.new("__match"),
              right_owns ? MIR::DeepCopy.new(MIR::Ident.new("__jr"), right_zig, nil, :full_value, alloc) : MIR::Ident.new("__jr")),
            MIR::BreakStmt.new(nil, nil),
          ], nil),
        ], nil),
        *(left_owns ? self.owning_pipeline_temp_stmts.call("__jl_owned", MIR::Ident.new("__jl"), left_type_info, left_zig, alloc) : []),
        MIR::ExprStmt.new(MIR::MethodCall.new(
          MIR::Ident.new("res_list"), "append",
           [MIR::AllocatorRef.new(alloc),
            MIR::StructInit.new(nil, [
             MIR.named_field("left", left_value),
             MIR.named_field("right", right_value),
           ])],
          true, MIR::CallableContract.no_ownership(2)), nil),
        *after_append,
      ], nil),
      MIR::BreakStmt.new(label, MIR::Ident.new("res_list")),
    ])
  end

  sig { params(site: PipelineSite, tap_op: AST::TapOp).returns(MIR::BlockExpr) }
  def lower_tap(site, tap_op)
    list_node = site.list
    label = self.next_label.call
    source_mir = self.visit_mir.call(list_node)
    self.set_current_label.call(label)
    body_mir = self.visit_body.call(tap_op.body, "__tap_item")

    MIR::BlockExpr.new(label, [
      MIR::Let.new("__tap_src", source_mir, false, nil, nil),
      MIR::Let.new("__tap_items",
        MIR::ItemsAccess.new(MIR::Ident.new("__tap_src"), true), false, nil, nil),
      MIR::ForStmt.new(MIR::Ident.new("__tap_items"), "__tap_item", body_mir, nil),
      MIR::BreakStmt.new(label, MIR::Ident.new("__tap_src")),
    ])
  end

  sig { params(list_node: AST::Node, expr_node: AST::Node, placeholder: String).returns(MIR::Node) }
  def visit_pipeline_expr_mir(list_node, expr_node, placeholder = "it")
    self.visit_expr.call(list_node, expr_node, placeholder)
  end

  sig { params(list_node: AST::Node, join_node: AST::JoinOp).returns(MIR::Node) }
  def join_predicate_mir(list_node, join_node)
    key_expr = T.cast(join_node.key_expr, AST::Node)
    if key_expr.is_a?(AST::LambdaLit)
      params = key_expr.params
      left_param = params[0].name
      right_param = params[1].name
      join_params = T.let({ left_param => "__jl", right_param => "__jr" }, T::Hash[String, String])
      return self.visit_join_lambda.call(T.cast(key_expr.body, AST::Node), join_params)
    end

    left_key_mir = self.visit_expr.call(list_node, key_expr, "__jl")
    right_key_mir = self.visit_expr.call(list_node, key_expr, "__jr")
    MIR::RuntimeCall.new(MIR::RuntimeCalls.eql_spec, [left_key_mir, right_key_mir])
  end

  sig { params(left_owns: T::Boolean, right_owns: T::Boolean).returns(T::Array[MIR::Emittable]) }
  def ownership_sink_marks(left_owns:, right_owns:)
    marks = T.let([], T::Array[MIR::Emittable])
    if left_owns
      marks.concat(MIR::OwnershipTransferPlan.new(
        name: "__jl_owned",
        target: :owned_sink,
        target_alloc: self.pipeline_result_alloc.call,
        move_guarded: true,
      ).marks)
    end
    if right_owns
      marks.concat(MIR::OwnershipTransferPlan.new(
        name: "__match",
        target: :owned_sink,
        target_alloc: self.pipeline_result_alloc.call,
        move_guarded: true,
      ).marks)
    end
    marks
  end

  sig { params(right_owns: T::Boolean, alloc: Symbol, right_zig: String).returns(T::Array[MIR::Emittable]) }
  def right_cleanup_stmts(right_owns, alloc, right_zig)
    return [] unless right_owns

    [
      MIR::ErrCleanup.new("__match",
        CleanupEntry.build(:uniform, alloc: alloc, has_moved_guard: true, zig_type: "?#{right_zig}")),
    ]
  end
end
