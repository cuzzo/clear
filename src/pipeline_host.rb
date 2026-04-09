require "set"
require_relative "./pipeline_generator"
require_relative "./zig_type_mapper"

# Lightweight host for PipelineGenerator that routes sub-expression
# transpilation through MIRLowering + MIREmitter instead of the old
# ZigTranspiler visit() dispatch.
#
# PipelineGenerator expects its host to provide:
#   - visit(node) -> Zig string
#   - transpile_type(type) -> Zig type string
#   - @placeholder_name, @acc_placeholder, @soa_* state (via with_pipeline_context)
#   - @join_param_map (managed internally by PipelineGenerator)
#   - @fn_sigs (for catch snapshot detection in transpile_Smooth)
class PipelineHost
  include PipelineGenerator
  include ZigTypeMapper

  attr_accessor :fn_sigs

  def initialize(lowering:, emitter:)
    @lowering = lowering
    @emitter = emitter
    @fn_sigs = lowering.fn_sigs
    # Pipeline context state (managed by with_pipeline_context)
    @soa_rewrite_active = false
    @soa_needed_fields = Set.new
    @transpiler_context_stack = []
    @mir_mode = false
  end

  def current_tp_ctx; @transpiler_context_stack.last; end

  # Delegate fiber capture map management to MIRLowering
  def with_fiber_capture_map(new_entries, rt_override: "__rt", &blk)
    @lowering.with_fiber_capture_map(new_entries, rt_override: rt_override, &blk)
  end

  # Delegate task_config_zig to MIRLowering (used by CONCURRENT pipeline operators)
  def task_config_zig(stack_size, computed_tier = nil)
    @lowering.send(:task_config_zig, stack_size, computed_tier)
  end

  # Route AST node -> Zig string, handling pipeline-specific nodes
  # (Placeholder, SOA field rewrites) before general MIR lowering.
  def visit(node)
    # In MIR mode, return MIR nodes instead of Zig strings.
    return visit_mir(node) if @mir_mode

    # Placeholder: _ inside pipeline expression -> loop variable name
    if node.is_a?(AST::Identifier) && node.name == "_" && @placeholder_name
      return @placeholder_name
    end

    # Join param map: lambda param names -> Zig loop variables
    if node.is_a?(AST::Identifier) && @join_param_map && @join_param_map[node.name]
      return @join_param_map[node.name]
    end

    # SOA field-slice rewrite: _.field -> __soa_field[__soa_i]
    if @soa_rewrite_active && node.is_a?(AST::GetField) &&
       node.target.is_a?(AST::Identifier) && node.target.name == "_"
      @soa_needed_fields << node.field
      return "__soa_#{node.field}[__soa_i]"
    end

    # SOA assignment rewrite: _.field = expr -> __soa_field[__soa_i] = expr
    if @soa_rewrite_active && (node.is_a?(AST::BindExpr) || node.is_a?(AST::Assignment)) &&
       node.name.is_a?(AST::GetField) && node.name.target.is_a?(AST::Identifier) &&
       node.name.target.name == "_"
      field = node.name.field
      @soa_needed_fields << field
      value = visit(node.value)
      return "__soa_#{field}[__soa_i] = #{value};"
    end

    # Accumulator placeholder
    if node.is_a?(AST::Identifier) && node.name == "acc" && @acc_placeholder
      return @acc_placeholder
    end

    # Before sending to MIRLowering, substitute _ placeholders and join
    # params in the AST tree. MIRLowering's lower() recurses on its own,
    # so it won't call back to us for sub-expressions.
    substituted = substitute_placeholders(node)

    # General case: lower to MIR, emit to Zig
    mir_node = @lowering.lower(substituted)
    @emitter.emit(mir_node)
  end

  # MIR-mode visit: returns MIR node instead of Zig string.
  # Used by lower_* pipeline methods during MIR migration.
  def visit_mir(node)
    substituted = substitute_placeholders(node)
    @lowering.lower(substituted)
  end

  private

  # Recursively replace AST::Identifier("_") with the current placeholder name,
  # and join param names with their Zig loop variable names.
  # Returns the node (possibly modified) or a new synthetic Identifier.
  def substitute_placeholders(node)
    return node unless @placeholder_name || @acc_placeholder || @join_param_map

    case node
    when AST::Identifier
      if node.name == "_" && @placeholder_name
        new_id = AST::Identifier.new(node.token, @placeholder_name)
        copy_type_info(node, new_id)
        return new_id
      elsif node.name == "acc" && @acc_placeholder
        new_id = AST::Identifier.new(node.token, @acc_placeholder)
        copy_type_info(node, new_id)
        return new_id
      elsif @join_param_map && @join_param_map[node.name]
        new_id = AST::Identifier.new(node.token, @join_param_map[node.name])
        copy_type_info(node, new_id)
        return new_id
      end
    when AST::FuncCall
      new_args = node.args.map { |a| substitute_placeholders(a) }
      if new_args != node.args
        new_call = AST::FuncCall.new(node.token, node.name, new_args)
        copy_type_info(node, new_call)
        new_call.zig_pattern = node.zig_pattern if node.respond_to?(:zig_pattern)
        new_call.matched_stdlib_def = node.matched_stdlib_def if node.respond_to?(:matched_stdlib_def) && node.matched_stdlib_def
        return new_call
      end
    when AST::MethodCall
      new_target = substitute_placeholders(node.object)
      new_args = node.args.map { |a| substitute_placeholders(a) }
      if new_target != node.object || new_args != node.args
        new_mc = AST::MethodCall.new(node.token, new_target, node.name, new_args)
        copy_type_info(node, new_mc)
        new_mc.zig_pattern = node.zig_pattern if node.respond_to?(:zig_pattern) && node.zig_pattern
        new_mc.matched_stdlib_def = node.matched_stdlib_def if node.respond_to?(:matched_stdlib_def) && node.matched_stdlib_def
        return new_mc
      end
    when AST::BinaryOp
      new_left = substitute_placeholders(node.left)
      new_right = substitute_placeholders(node.right)
      if new_left != node.left || new_right != node.right
        new_bin = AST::BinaryOp.new(node.token, new_left, node.op, new_right)
        copy_type_info(node, new_bin)
        new_bin.string_concat = node.string_concat if node.respond_to?(:string_concat) && node.string_concat
        return new_bin
      end
    when AST::GetField
      new_target = substitute_placeholders(node.target)
      if new_target != node.target
        new_gf = AST::GetField.new(node.token, new_target, node.field)
        copy_type_info(node, new_gf)
        return new_gf
      end
    when AST::GetIndex
      new_target = substitute_placeholders(node.target)
      new_index = substitute_placeholders(node.index)
      if new_target != node.target || new_index != node.index
        new_ia = AST::GetIndex.new(node.token, new_target, new_index)
        copy_type_info(node, new_ia)
        return new_ia
      end
    when AST::BindExpr
      new_name = node.name.is_a?(AST::GetField) || node.name.is_a?(AST::GetIndex) ? substitute_placeholders(node.name) : node.name
      new_value = substitute_placeholders(node.value)
      if new_name != node.name || new_value != node.value
        new_bind = AST::BindExpr.new(node.token, new_name, node.type, new_value)
        new_bind.mode = node.mode
        new_bind.reassign_cleanup = node.reassign_cleanup
        new_bind.cleanup_alloc = node.cleanup_alloc
        new_bind.has_cleanup = node.has_cleanup
        copy_type_info(node, new_bind)
        return new_bind
      end
    when AST::Assignment
      new_name = node.name.is_a?(AST::GetField) || node.name.is_a?(AST::GetIndex) ? substitute_placeholders(node.name) : node.name
      new_value = substitute_placeholders(node.value)
      if new_name != node.name || new_value != node.value
        new_assign = AST::Assignment.new(node.token, new_name, new_value)
        new_assign.auto_lock = node.auto_lock
        new_assign.field_pre_cleanup = node.field_pre_cleanup
        copy_type_info(node, new_assign)
        return new_assign
      end
    when AST::UnaryOp
      new_operand = substitute_placeholders(node.operand)
      if new_operand != node.operand
        new_uo = AST::UnaryOp.new(node.token, node.op, new_operand)
        copy_type_info(node, new_uo)
        return new_uo
      end
    end

    node
  end

  def copy_type_info(src, dst)
    dst.full_type = src.full_type if src.respond_to?(:full_type) && src.full_type && dst.respond_to?(:full_type=)
    dst.type_info = src.type_info if src.respond_to?(:type_info) && src.type_info && dst.respond_to?(:type_info=)
    dst.coerced_type = src.coerced_type if src.respond_to?(:coerced_type) && src.coerced_type && dst.respond_to?(:coerced_type=)
    dst.storage = src.storage if src.respond_to?(:storage) && src.storage && dst.respond_to?(:storage=)
  end

  public

  # MIR entry point: returns MIR node tree for migrated pipeline operators.
  # Returns nil for non-migrated operators (caller falls back to string path).
  def lower_pipeline(node)
    rhs = node.right
    lhs = node.left
    lhs_type = lhs.type_info

    # SOA scalar operators have zero allocations -- field-slice path in the
    # string generator is strictly better (no materialization overhead).
    # Let them fall through to the string path where field-slice optimization applies.
    is_soa = lhs_type&.soa? && (lhs_type&.pool? || lhs_type&.list_collection? || lhs_type&.fixed_soa?)
    scalar_op = [AST::CountOp, AST::SumOp, AST::AverageOp, AST::MinOp,
                 AST::MaxOp, AST::AnyOp, AST::AllOp, AST::FindOp].any? { |t| rhs.is_a?(t) }
    return nil if is_soa && scalar_op

    case rhs
    when AST::CountOp   then lower_count(lhs, rhs, node)
    when AST::SumOp     then lower_sum(lhs, rhs, node)
    when AST::AverageOp then lower_average(lhs, rhs, node)
    when AST::MinOp     then lower_min(lhs, rhs, node)
    when AST::MaxOp     then lower_max(lhs, rhs, node)
    when AST::AnyOp     then lower_any(lhs, rhs, node)
    when AST::AllOp     then lower_all(lhs, rhs, node)
    when AST::FindOp    then lower_find(lhs, rhs, node)
    when AST::WhereOp   then lower_where(lhs, rhs.expression, node)
    when AST::SelectOp  then lower_select(lhs, rhs.expression, node)
    when AST::LimitOp   then lower_limit(lhs, rhs, node)
    when AST::TakeWhileOp then lower_take_while(lhs, rhs.expression, node)
    when AST::SkipOp    then lower_skip(lhs, rhs, node)
    when AST::DistinctOp then lower_distinct(lhs, rhs, node)
    when AST::UnnestOp  then lower_unnest(lhs, rhs, node)
    when AST::ReduceOp  then lower_reduce(lhs, rhs, node)
    when AST::WindowOp  then lower_window(lhs, rhs, node)
    when AST::OrderByOp then lower_order_by(lhs, rhs, node)
    when AST::IndexOp   then lower_index(lhs, rhs.expression, node)
    when AST::JoinOp    then lower_join(lhs, rhs, node)
    when AST::TapOp     then lower_tap(lhs, rhs, node)
    when AST::EachOp    then lower_each(lhs, rhs, node)
    else nil
    end
  end

  # Infrastructure: builds labeled block with source eval + materialization,
  # yields to operator body, returns MIR::BlockExpr.
  def lower_pipeline_block(list_node)
    label = next_pipe_label
    source_mir = visit_mir(list_node)
    @current_pipe_label = label

    lhs_type = list_node.type_info
    mat_stmts, items_ident = build_pipe_items_mir(lhs_type)

    body_stmts = yield(items_ident, label)

    MIR::BlockExpr.new(label, [
      MIR::Let.new("pipe_src_list", source_mir, false, nil, nil),
      *mat_stmts,
      *body_stmts
    ])
  end

  # Build materialization MIR nodes. Returns [stmts_array, items_ident_string].
  # Pool/sharded sources materialize live items into a temp buffer.
  def build_pipe_items_mir(lhs_type)
    if lhs_type&.pool? && lhs_type&.sharded?
      elem_zig = lhs_type.element_type.zig_type
      n = lhs_type.shard_count
      code = "var pipe_mat = std.ArrayListUnmanaged(#{elem_zig}){};\n" \
             "defer pipe_mat.deinit(rt.heapAlloc());\n" \
             "for (0..#{n}) |__psi| {\n" \
             "    for (pipe_src_list.shards[__psi].slots) |*__pslot| {\n" \
             "        if (__pslot.alive) try pipe_mat.append(rt.heapAlloc(), __pslot.value);\n" \
             "    }\n" \
             "}\n" \
             "const pipe_items = pipe_mat.items;"
      [[MIR::RawZig.new(code, "mat_sharded_pool")], "pipe_items"]
    elsif lhs_type&.pool? && lhs_type&.soa?
      elem_zig = lhs_type.element_type.zig_type
      code = "var pipe_mat = std.ArrayListUnmanaged(#{elem_zig}){};\n" \
             "defer pipe_mat.deinit(rt.heapAlloc());\n" \
             "for (0..@intCast(pipe_src_list.data.len)) |__psi| {\n" \
             "    if (pipe_src_list.alive[__psi]) try pipe_mat.append(rt.heapAlloc(), pipe_src_list.data.get(__psi));\n" \
             "}\n" \
             "const pipe_items = pipe_mat.items;"
      [[MIR::RawZig.new(code, "mat_soa_pool")], "pipe_items"]
    elsif lhs_type&.pool?
      elem_zig = lhs_type.element_type.zig_type
      code = "var pipe_mat = std.ArrayListUnmanaged(#{elem_zig}){};\n" \
             "defer pipe_mat.deinit(rt.heapAlloc());\n" \
             "for (pipe_src_list.slots) |*__pslot| {\n" \
             "    if (__pslot.alive) try pipe_mat.append(rt.heapAlloc(), __pslot.value);\n" \
             "}\n" \
             "const pipe_items = pipe_mat.items;"
      [[MIR::RawZig.new(code, "mat_pool")], "pipe_items"]
    elsif (lhs_type&.list_collection? || lhs_type&.fixed_soa?) && lhs_type&.soa?
      elem_zig = lhs_type.element_type.zig_type
      code = "var pipe_mat = std.ArrayListUnmanaged(#{elem_zig}){};\n" \
             "defer pipe_mat.deinit(rt.heapAlloc());\n" \
             "for (0..@intCast(pipe_src_list.data.len)) |__psi| {\n" \
             "    try pipe_mat.append(rt.heapAlloc(), pipe_src_list.data.get(__psi));\n" \
             "}\n" \
             "const pipe_items = pipe_mat.items;"
      [[MIR::RawZig.new(code, "mat_soa_list")], "pipe_items"]
    elsif lhs_type&.list_collection? && lhs_type&.sharded?
      elem_zig = lhs_type.element_type.zig_type
      n = lhs_type.shard_count
      code = "var pipe_mat = std.ArrayListUnmanaged(#{elem_zig}){};\n" \
             "defer pipe_mat.deinit(rt.heapAlloc());\n" \
             "for (0..#{n}) |__psi| {\n" \
             "    try pipe_mat.appendSlice(rt.heapAlloc(), pipe_src_list.shards[__psi].items);\n" \
             "}\n" \
             "const pipe_items = pipe_mat.items;"
      [[MIR::RawZig.new(code, "mat_sharded_list")], "pipe_items"]
    else
      # Plain array/list: hasField check for .items vs raw slice
      init = MIR::InlineZig.new(
        'if (@hasField(@TypeOf(pipe_src_list), "items")) pipe_src_list.items else pipe_src_list[0..]',
        "pipe_items_access")
      [[MIR::Let.new("pipe_items", init, false, nil, nil)], "pipe_items"]
    end
  end

  # Visit pipeline expression in MIR mode with placeholder substitution.
  def visit_pipeline_expr_mir(list_node, expr_node, placeholder = "it")
    with_pipeline_context(placeholder: placeholder) do
      visit_mir(expr_node)
    end
  end

  # --- Scalar accumulator lowerings (Phase 1) ---

  def lower_count(list_node, count_node, _smooth_node)
    pred_mir = visit_pipeline_expr_mir(list_node, count_node.expression)
    lower_pipeline_block(list_node) do |items, label|
      [
        MIR::Let.new("count_result", MIR::Lit.new("0"), true, "i64", nil),
        MIR::ForStmt.new(MIR::Ident.new(items), "it", [
          MIR::IfStmt.new(pred_mir, [
            MIR::Set.new(MIR::Ident.new("count_result"),
              MIR::BinOp.new("+", MIR::Ident.new("count_result"), MIR::Lit.new("1")))
          ], nil)
        ], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("count_result"))
      ]
    end
  end

  def lower_sum(list_node, sum_node, _smooth_node)
    expr_mir = visit_pipeline_expr_mir(list_node, sum_node.expression)
    lower_pipeline_block(list_node) do |items, label|
      [
        MIR::Let.new("sum_result", MIR::Lit.new("0"), true, "f64", nil),
        MIR::ForStmt.new(MIR::Ident.new(items), "it", [
          MIR::Set.new(MIR::Ident.new("sum_result"),
            MIR::BinOp.new("+", MIR::Ident.new("sum_result"), expr_mir))
        ], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("sum_result"))
      ]
    end
  end

  def lower_average(list_node, avg_node, _smooth_node)
    expr_mir = visit_pipeline_expr_mir(list_node, avg_node.expression)
    lower_pipeline_block(list_node) do |items, label|
      [
        MIR::Let.new("avg_sum", MIR::Lit.new("0"), true, "f64", nil),
        MIR::Let.new("avg_count", MIR::FieldGet.new(MIR::Ident.new(items), "len"), false, nil, nil),
        MIR::ForStmt.new(MIR::Ident.new(items), "it", [
          MIR::Set.new(MIR::Ident.new("avg_sum"),
            MIR::BinOp.new("+", MIR::Ident.new("avg_sum"), expr_mir))
        ], nil),
        MIR::BreakStmt.new(label,
          MIR::Conditional.new(
            MIR::BinOp.new("==", MIR::Ident.new("avg_count"), MIR::Lit.new("0")),
            MIR::Cast.new(MIR::Lit.new("0"), "f64", :as),
            MIR::BinOp.new("/", MIR::Ident.new("avg_sum"),
              MIR::Cast.new(MIR::Ident.new("avg_count"), "f64", :floatFromInt))))
      ]
    end
  end

  def lower_min(list_node, min_node, _smooth_node)
    expr_mir = visit_pipeline_expr_mir(list_node, min_node.expression)
    lower_pipeline_block(list_node) do |items, label|
      [
        MIR::ExprStmt.new(
          MIR::InlineZig.new(
            "if (#{items}.len == 0) @panic(\"MIN applied to empty list\")",
            "min_empty_check"), nil),
        MIR::Let.new("min_result", MIR::InlineZig.new("std.math.floatMax(f64)", "float_max"),
          true, "f64", nil),
        MIR::ForStmt.new(MIR::Ident.new(items), "it", [
          MIR::Let.new("min_val", expr_mir, false, nil, nil),
          MIR::IfStmt.new(
            MIR::BinOp.new("<", MIR::Ident.new("min_val"), MIR::Ident.new("min_result")),
            [MIR::Set.new(MIR::Ident.new("min_result"), MIR::Ident.new("min_val"))],
            nil)
        ], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("min_result"))
      ]
    end
  end

  def lower_max(list_node, max_node, _smooth_node)
    expr_mir = visit_pipeline_expr_mir(list_node, max_node.expression)
    lower_pipeline_block(list_node) do |items, label|
      [
        MIR::ExprStmt.new(
          MIR::InlineZig.new(
            "if (#{items}.len == 0) @panic(\"MAX applied to empty list\")",
            "max_empty_check"), nil),
        MIR::Let.new("max_result", MIR::InlineZig.new("-std.math.floatMax(f64)", "float_min"),
          true, "f64", nil),
        MIR::ForStmt.new(MIR::Ident.new(items), "it", [
          MIR::Let.new("max_val", expr_mir, false, nil, nil),
          MIR::IfStmt.new(
            MIR::BinOp.new(">", MIR::Ident.new("max_val"), MIR::Ident.new("max_result")),
            [MIR::Set.new(MIR::Ident.new("max_result"), MIR::Ident.new("max_val"))],
            nil)
        ], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("max_result"))
      ]
    end
  end

  def lower_any(list_node, any_node, _smooth_node)
    pred_mir = visit_pipeline_expr_mir(list_node, any_node.expression)
    lower_pipeline_block(list_node) do |items, label|
      [
        MIR::Let.new("any_result", MIR::Lit.new("false"), true, nil, nil),
        MIR::ForStmt.new(MIR::Ident.new(items), "it", [
          MIR::IfStmt.new(pred_mir, [
            MIR::Set.new(MIR::Ident.new("any_result"), MIR::Lit.new("true")),
            MIR::BreakStmt.new(nil, nil)
          ], nil)
        ], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("any_result"))
      ]
    end
  end

  def lower_all(list_node, all_node, _smooth_node)
    pred_mir = visit_pipeline_expr_mir(list_node, all_node.expression)
    lower_pipeline_block(list_node) do |items, label|
      [
        MIR::Let.new("all_result", MIR::Lit.new("true"), true, nil, nil),
        MIR::ForStmt.new(MIR::Ident.new(items), "it", [
          MIR::IfStmt.new(MIR::UnaryOp.new("!", pred_mir), [
            MIR::Set.new(MIR::Ident.new("all_result"), MIR::Lit.new("false")),
            MIR::BreakStmt.new(nil, nil)
          ], nil)
        ], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("all_result"))
      ]
    end
  end

  def lower_find(list_node, find_node, _smooth_node)
    elem_zig_type = transpile_type(list_node.full_type.element_type.resolved.to_s)
    pred_mir = visit_pipeline_expr_mir(list_node, find_node.expression)
    lower_pipeline_block(list_node) do |items, label|
      [
        MIR::Let.new("find_result",
          MIR::InlineZig.new("undefined", "undef"), true, elem_zig_type, nil),
        MIR::Let.new("find_found", MIR::Lit.new("false"), true, nil, nil),
        MIR::ForStmt.new(MIR::Ident.new(items), "it", [
          MIR::Let.new("find_matches", pred_mir, false, nil, nil),
          MIR::IfStmt.new(MIR::Ident.new("find_matches"), [
            MIR::Set.new(MIR::Ident.new("find_result"), MIR::Ident.new("it")),
            MIR::Set.new(MIR::Ident.new("find_found"), MIR::Lit.new("true")),
            MIR::BreakStmt.new(nil, nil)
          ], nil)
        ], nil),
        MIR::BreakStmt.new(label,
          MIR::Conditional.new(
            MIR::Ident.new("find_found"),
            MIR::Cast.new(MIR::Ident.new("find_result"), "?#{elem_zig_type}", :as),
            MIR::Lit.new("null")))
      ]
    end
  end

  # --- Filter/transform operator lowerings (Phase 2) ---

  def pipeline_alloc(smooth_node)
    smooth_node.respond_to?(:storage) && smooth_node.storage == :heap ? "rt.heapAlloc()" : "rt.frameAlloc()"
  end

  def lower_where(list_node, expr_node, smooth_node)
    elem_type = list_node.full_type.element_type.resolved.to_s
    elem_zig = transpile_type(elem_type)
    alloc = pipeline_alloc(smooth_node)
    pred_mir = visit_pipeline_expr_mir(list_node, expr_node)
    lower_pipeline_block(list_node) do |items, label|
      [
        MIR::Let.new("res_list",
          MIR::MakeList.new(elem_zig, [], alloc), true, nil, nil),
        MIR::ForStmt.new(MIR::Ident.new(items), "it", [
          MIR::Let.new("matches", pred_mir, false, nil, nil),
          MIR::IfStmt.new(MIR::Ident.new("matches"), [
            MIR::ExprStmt.new(MIR::MethodCall.new(
              MIR::Ident.new("res_list"), "append",
              [MIR::InlineZig.new(alloc, "alloc"), MIR::Ident.new("it")], true), nil)
          ], nil)
        ], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("res_list"))
      ]
    end
  end

  def lower_select(list_node, expr_node, smooth_node)
    res_type = expr_node.full_type
    res_zig = transpile_type(res_type)
    alloc = pipeline_alloc(smooth_node)
    expr_mir = visit_pipeline_expr_mir(list_node, expr_node)
    lower_pipeline_block(list_node) do |items, label|
      [
        MIR::Let.new("res_list",
          MIR::MakeList.new(res_zig, [], alloc), true, nil, nil),
        MIR::ForStmt.new(MIR::Ident.new(items), "it", [
          MIR::Let.new("val", expr_mir, false, nil, nil),
          MIR::ExprStmt.new(MIR::MethodCall.new(
            MIR::Ident.new("res_list"), "append",
            [MIR::InlineZig.new(alloc, "alloc"), MIR::Ident.new("val")], true), nil)
        ], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("res_list"))
      ]
    end
  end

  def lower_limit(list_node, limit_node, smooth_node)
    elem_type = list_node.full_type.element_type.resolved.to_s
    elem_zig = transpile_type(elem_type)
    alloc = pipeline_alloc(smooth_node)
    count_mir = visit_mir(limit_node.count)
    lower_pipeline_block(list_node) do |items, label|
      [
        MIR::Let.new("lim_requested",
          MIR::Cast.new(count_mir, "usize", :intCast), false, nil, nil),
        MIR::Let.new("lim_actual",
          MIR::InlineZig.new("@min(lim_requested, #{items}.len)", "min_len"),
          false, nil, nil),
        MIR::BreakStmt.new(label,
          MIR::InlineZig.new(
            "try CheatLib.makeList(#{elem_zig}, #{alloc}, #{items}[0..lim_actual])",
            "make_limited_list"))
      ]
    end
  end

  def lower_take_while(list_node, expr_node, smooth_node)
    elem_type = list_node.full_type.element_type.resolved.to_s
    elem_zig = transpile_type(elem_type)
    alloc = pipeline_alloc(smooth_node)
    pred_mir = visit_pipeline_expr_mir(list_node, expr_node)
    lower_pipeline_block(list_node) do |items, label|
      [
        MIR::Let.new("res_list",
          MIR::MakeList.new(elem_zig, [], alloc), true, nil, nil),
        MIR::ForStmt.new(MIR::Ident.new(items), "it", [
          MIR::Let.new("matches", pred_mir, false, nil, nil),
          MIR::IfStmt.new(MIR::UnaryOp.new("!", MIR::Ident.new("matches")),
            [MIR::BreakStmt.new(nil, nil)], nil),
          MIR::ExprStmt.new(MIR::MethodCall.new(
            MIR::Ident.new("res_list"), "append",
            [MIR::InlineZig.new(alloc, "alloc"), MIR::Ident.new("it")], true), nil)
        ], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("res_list"))
      ]
    end
  end

  def lower_skip(list_node, skip_node, _smooth_node)
    label = next_pipe_label
    source_mir = visit_mir(list_node)
    @current_pipe_label = label
    count_mir = visit_mir(skip_node.count)

    MIR::BlockExpr.new(label, [
      MIR::Let.new("__skip_src", source_mir, false, nil, nil),
      MIR::Let.new("__skip_items",
        MIR::InlineZig.new(
          'if (@hasField(@TypeOf(__skip_src), "items")) __skip_src.items else __skip_src[0..]',
          "skip_items"), false, nil, nil),
      MIR::Let.new("skip_requested",
        MIR::Cast.new(count_mir, "usize", :intCast), false, nil, nil),
      MIR::Let.new("skip_actual",
        MIR::InlineZig.new("@min(skip_requested, __skip_items.len)", "skip_min"),
        false, nil, nil),
      MIR::BreakStmt.new(label,
        MIR::InlineZig.new("__skip_items[skip_actual..]", "skip_slice"))
    ])
  end

  def lower_distinct(list_node, distinct_node, smooth_node)
    elem_type = list_node.full_type.element_type.resolved.to_s
    elem_zig = transpile_type(elem_type)
    alloc = pipeline_alloc(smooth_node)

    expr_mir = visit_pipeline_expr_mir(list_node, distinct_node.expression)
    expr_mir_inner = with_pipeline_context(placeholder: "it2") {
      visit_mir(distinct_node.expression)
    }

    lower_pipeline_block(list_node) do |items, label|
      [
        MIR::Let.new("res_list",
          MIR::MakeList.new(elem_zig, [], alloc), true, nil, nil),
        MIR::ForStmt.new(MIR::Ident.new(items), "it", [
          MIR::Let.new("dist_key", expr_mir, false, nil, nil),
          MIR::Let.new("dist_found", MIR::Lit.new("false"), true, nil, nil),
          MIR::ForStmt.new(
            MIR::FieldGet.new(MIR::Ident.new("res_list"), "items"), "it2", [
              MIR::Let.new("dist_existing_key", expr_mir_inner, false, nil, nil),
              MIR::IfStmt.new(
                MIR::Call.new("CheatLib.eql",
                  [MIR::Ident.new("dist_key"), MIR::Ident.new("dist_existing_key")], false),
                [
                  MIR::Set.new(MIR::Ident.new("dist_found"), MIR::Lit.new("true")),
                  MIR::BreakStmt.new(nil, nil)
                ], nil)
            ], nil),
          MIR::IfStmt.new(MIR::UnaryOp.new("!", MIR::Ident.new("dist_found")), [
            MIR::ExprStmt.new(MIR::MethodCall.new(
              MIR::Ident.new("res_list"), "append",
              [MIR::InlineZig.new(alloc, "alloc"), MIR::Ident.new("it")], true), nil)
          ], nil)
        ], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("res_list"))
      ]
    end
  end

  # --- Complex operator lowerings (Phase 3) ---

  def lower_unnest(list_node, unnest_node, smooth_node)
    inner_elem_type = unnest_node.full_type.element_type.resolved.to_s
    inner_zig = transpile_type(inner_elem_type)
    alloc = pipeline_alloc(smooth_node)
    expr_mir = visit_pipeline_expr_mir(list_node, unnest_node.expression)
    lower_pipeline_block(list_node) do |items, label|
      [
        MIR::Let.new("res_list",
          MIR::MakeList.new(inner_zig, [], alloc), true, nil, nil),
        MIR::ForStmt.new(MIR::Ident.new(items), "it", [
          MIR::Let.new("unn_inner", expr_mir, false, nil, nil),
          MIR::Let.new("unn_inner_items",
            MIR::InlineZig.new(
              'if (@hasField(@TypeOf(unn_inner), "items")) unn_inner.items else unn_inner',
              "unnest_items"), false, nil, nil),
          MIR::ForStmt.new(MIR::Ident.new("unn_inner_items"), "inner_it", [
            MIR::ExprStmt.new(MIR::MethodCall.new(
              MIR::Ident.new("res_list"), "append",
              [MIR::InlineZig.new(alloc, "alloc"), MIR::Ident.new("inner_it")], true), nil)
          ], nil)
        ], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("res_list"))
      ]
    end
  end

  def lower_reduce(list_node, reduce_node, _smooth_node)
    acc_zig = transpile_type(reduce_node.full_type)
    init_mir = visit_mir(reduce_node.initial_value)
    expr_mir = with_pipeline_context(placeholder: "it", acc: "acc") {
      visit_mir(reduce_node.expression)
    }
    lower_pipeline_block(list_node) do |items, label|
      [
        MIR::Let.new("acc", init_mir, true, acc_zig, nil),
        MIR::ForStmt.new(MIR::Ident.new(items), "it", [
          MIR::Set.new(MIR::Ident.new("acc"), expr_mir)
        ], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("acc"))
      ]
    end
  end

  def lower_window(list_node, window_node, smooth_node)
    expr_type_str = (window_node.expression.full_type || window_node.expression.resolved_type).to_s
    res_zig = transpile_type(expr_type_str)
    alloc = pipeline_alloc(smooth_node)
    size_mir = visit_mir(window_node.size)
    expr_mir = with_pipeline_context(placeholder: "window_slice") {
      visit_mir(window_node.expression)
    }
    lower_pipeline_block(list_node) do |items, label|
      # Window uses a while loop with index, RawZig for slice + size logic
      [
        MIR::Let.new("res_list",
          MIR::MakeList.new(res_zig, [], alloc), true, nil, nil),
        MIR::RawZig.new(
          "{\n" \
          "    const __w_size: usize = @intCast(#{@emitter.emit(size_mir)});\n" \
          "    if (#{items}.len >= __w_size) {\n" \
          "        var __wi: usize = 0;\n" \
          "        while (__wi <= #{items}.len - __w_size) : (__wi += 1) {\n" \
          "            const window_slice = #{items}[__wi .. __wi + __w_size];\n" \
          "            const val = #{@emitter.emit(expr_mir)};\n" \
          "            try res_list.append(#{alloc}, val);\n" \
          "        }\n" \
          "    }\n" \
          "}", "window_loop"),
        MIR::BreakStmt.new(label, MIR::Ident.new("res_list"))
      ]
    end
  end

  def lower_order_by(list_node, order_node, smooth_node)
    elem_zig = transpile_type(list_node.full_type.element_type.resolved.to_s)
    alloc = pipeline_alloc(smooth_node)
    key_a = with_pipeline_context(placeholder: "a") { visit_mir(order_node.expression) }
    key_b = with_pipeline_context(placeholder: "b") { visit_mir(order_node.expression) }
    lower_pipeline_block(list_node) do |items, label|
      [
        MIR::Let.new("ord_result",
          MIR::InlineZig.new(
            "try CheatLib.makeList(#{elem_zig}, #{alloc}, #{items})",
            "make_ord_list"), true, nil, nil),
        MIR::RawZig.new("_ = &ord_result;", "suppress_unused"),
        MIR::RawZig.new(
          "std.mem.sort(#{elem_zig}, ord_result.items, {}, struct {\n" \
          "    pub fn lessThan(_: void, a: #{elem_zig}, b: #{elem_zig}) bool {\n" \
          "        return #{@emitter.emit(key_a)} < #{@emitter.emit(key_b)};\n" \
          "    }\n" \
          "}.lessThan);", "order_by_sort"),
        MIR::BreakStmt.new(label, MIR::Ident.new("ord_result"))
      ]
    end
  end

  def lower_index(list_node, expr_node, smooth_node)
    elem_zig = transpile_type(list_node.full_type.element_type.resolved.to_s)
    alloc = pipeline_alloc(smooth_node)
    expr_mir = visit_pipeline_expr_mir(list_node, expr_node)
    lower_pipeline_block(list_node) do |items, label|
      [
        MIR::RawZig.new(
          "var idx_result: CheatLib.StringMap(std.ArrayListUnmanaged(#{elem_zig})) = .{ .alloc = #{alloc} };",
          "index_init"),
        MIR::ForStmt.new(MIR::Ident.new(items), "it", [
          MIR::Let.new("idx_key", expr_mir, false, nil, nil),
          MIR::RawZig.new(
            "const gop = idx_result.inner.getOrPut(#{alloc}, idx_key) catch @panic(\"INDEX allocation failed\");\n" \
            "if (!gop.found_existing) {\n" \
            "    gop.value_ptr.* = std.ArrayListUnmanaged(#{elem_zig}){};\n" \
            "}\n" \
            "gop.value_ptr.append(#{alloc}, it) catch @panic(\"INDEX append failed\");",
            "index_get_or_put")
        ], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("idx_result"))
      ]
    end
  end

  def lower_join(list_node, join_node, smooth_node)
    left_zig  = transpile_type(list_node.full_type.element_type.resolved.to_s)
    right_src_mir = visit_mir(join_node.right_source)
    right_type_info = join_node.right_source.type_info
    right_zig = transpile_type(right_type_info.element_type.resolved.to_s)
    result_zig = "struct { left: #{left_zig}, right: ?#{right_zig} }"
    alloc = "rt.frameAlloc()"

    key_expr = join_node.key_expr
    is_lambda = key_expr.is_a?(AST::LambdaLit)

    if is_lambda
      params = key_expr.params
      left_param  = params[0].is_a?(Hash) ? params[0][:name] : params[0].name
      right_param = params[1].is_a?(Hash) ? params[1][:name] : params[1].name
      old_join_map = @join_param_map
      @join_param_map = { left_param => "__jl", right_param => "__jr" }
      pred_zig = visit(key_expr.body)
      @join_param_map = old_join_map
    else
      left_key  = with_pipeline_context(placeholder: "__jl") { visit(key_expr) }
      right_key = with_pipeline_context(placeholder: "__jr") { visit(key_expr) }
      pred_zig = "CheatLib.eql(#{left_key}, #{right_key})"
    end

    label = next_pipe_label
    source_mir = visit_mir(list_node)
    @current_pipe_label = label

    MIR::BlockExpr.new(label, [
      MIR::Let.new("__jl_src", source_mir, false, nil, nil),
      MIR::Let.new("__jr_src", right_src_mir, false, nil, nil),
      MIR::Let.new("__jl_items",
        MIR::InlineZig.new(
          'if (@hasField(@TypeOf(__jl_src), "items")) __jl_src.items else __jl_src[0..]',
          "join_left_items"), false, nil, nil),
      MIR::Let.new("__jr_items",
        MIR::InlineZig.new(
          'if (@hasField(@TypeOf(__jr_src), "items")) __jr_src.items else __jr_src[0..]',
          "join_right_items"), false, nil, nil),
      MIR::Let.new("res_list",
        MIR::InlineZig.new(
          "try CheatLib.makeList(#{result_zig}, #{alloc}, &.{})",
          "join_make_list"), true, nil, nil),
      MIR::RawZig.new(
        "for (__jl_items) |__jl| {\n" \
        "    var __match: ?#{right_zig} = null;\n" \
        "    for (__jr_items) |__jr| {\n" \
        "        if (#{pred_zig}) {\n" \
        "            __match = __jr;\n" \
        "            break;\n" \
        "        }\n" \
        "    }\n" \
        "    try res_list.append(#{alloc}, .{ .left = __jl, .right = __match });\n" \
        "}", "join_loop"),
      MIR::BreakStmt.new(label, MIR::Ident.new("res_list"))
    ])
  end

  def lower_tap(list_node, tap_op, smooth_node)
    label = next_pipe_label
    source_mir = visit_mir(list_node)
    @current_pipe_label = label

    body_code = with_pipeline_context(placeholder: "__tap_item") do
      tap_op.body.map { |stmt|
        code = visit(stmt)
        code.strip.end_with?(";") ? code : "#{code};"
      }.join("\n        ")
    end

    MIR::BlockExpr.new(label, [
      MIR::Let.new("__tap_src", source_mir, false, nil, nil),
      MIR::Let.new("__tap_items",
        MIR::InlineZig.new(
          'if (@hasField(@TypeOf(__tap_src), "items")) __tap_src.items else __tap_src[0..]',
          "tap_items"), false, nil, nil),
      MIR::RawZig.new(
        "for (__tap_items) |__tap_item| {\n" \
        "    #{body_code}\n" \
        "}", "tap_loop"),
      MIR::BreakStmt.new(label, MIR::Ident.new("__tap_src"))
    ])
  end

  # --- Side-effect operator lowerings (Phase 4) ---

  def lower_each(list_node, each_op, smooth_node)
    lhs_type = list_node.type_info

    # Sharded pools/lists need fibers -- stay on string path
    return nil if lhs_type&.sharded?

    is_soa = lhs_type&.soa? && (lhs_type&.pool? || lhs_type&.list_collection? || lhs_type&.fixed_soa?)

    if is_soa
      # SOA path: field-slice access (preserves SOA cache locality)
      prev_soa_active = @soa_rewrite_active
      prev_soa_fields = @soa_needed_fields
      @soa_rewrite_active = true
      @soa_needed_fields = Set.new

      body_code = with_pipeline_context(placeholder: "_") do
        each_op.body.map { |stmt|
          code = visit(stmt)
          code.strip.end_with?(";") ? code : "#{code};"
        }.join("\n        ")
      end

      source_mir = visit_mir(list_node)
      field_slices = @soa_needed_fields.map { |f|
        "const __soa_#{f} = __soa_src.data.items(.#{f});"
      }.join("\n    ")

      alive_check = lhs_type&.pool? ? "if (!__soa_src.alive[__soa_i]) continue;\n        " : ""

      @soa_rewrite_active = prev_soa_active
      @soa_needed_fields = prev_soa_fields

      return MIR::ScopeBlock.new([
        MIR::Let.new("__soa_src", MIR::UnaryOp.new("&", source_mir), false, nil, nil),
        MIR::RawZig.new(
          "#{field_slices}\n" \
          "for (0..@intCast(__soa_src.data.len)) |__soa_i| {\n" \
          "    #{alive_check}#{body_code}\n" \
          "}", "each_soa_loop")
      ])
    end

    # Non-SOA pool: iterate slots with alive check
    if lhs_type&.pool?
      source_mir = visit_mir(list_node)
      body_code = with_pipeline_context(placeholder: "__each_item") do
        each_op.body.map { |stmt|
          code = visit(stmt)
          code.strip.end_with?(";") ? code : "#{code};"
        }.join("\n        ")
      end
      return MIR::ScopeBlock.new([
        MIR::Let.new("__each_src", MIR::UnaryOp.new("&", source_mir), false, nil, nil),
        MIR::RawZig.new(
          "for (__each_src.slots) |*__each_slot| {\n" \
          "    if (!__each_slot.alive) continue;\n" \
          "    const __each_item = &__each_slot.value;\n" \
          "    #{body_code}\n" \
          "}", "each_pool_loop")
      ])
    end

    # Non-SOA list collection or fixed_soa: iterate items
    if lhs_type&.list_collection? || lhs_type&.fixed_soa?
      source_mir = visit_mir(list_node)
      body_code = with_pipeline_context(placeholder: "__each_item") do
        each_op.body.map { |stmt|
          code = visit(stmt)
          code.strip.end_with?(";") ? code : "#{code};"
        }.join("\n        ")
      end
      return MIR::ScopeBlock.new([
        MIR::Let.new("__each_src", source_mir, false, nil, nil),
        MIR::RawZig.new(
          "for (if (@hasField(@TypeOf(__each_src), \"items\")) __each_src.items else __each_src[0..]) |__each_item| {\n" \
          "    #{body_code}\n" \
          "}", "each_list_loop")
      ])
    end

    nil  # Fall through to string path
  end

  # String entry point for SMOOTH pipeline nodes from MIRLowering.
  # Dispatches to PipelineGenerator methods that return Zig strings.
  def transpile_pipeline(node)
    lhs = node.left
    rhs = node.right

    # Dispatch by operator type
    if rhs.is_a?(AST::SelectOp)
      return transpile_select_projection(lhs, rhs.expression)
    elsif rhs.is_a?(AST::WhereOp)
      return transpile_where_filter(lhs, rhs.expression)
    elsif rhs.is_a?(AST::IndexOp)
      return transpile_index_grouping(lhs, rhs.expression, node)
    elsif rhs.is_a?(AST::ReduceOp)
      return transpile_reduce(lhs, rhs)
    elsif rhs.is_a?(AST::OrderByOp)
      return transpile_order_by(lhs, rhs, node)
    elsif rhs.is_a?(AST::LimitOp)
      return transpile_limit(lhs, rhs, node)
    elsif rhs.is_a?(AST::UnnestOp)
      return transpile_unnest(lhs, rhs, node)
    elsif rhs.is_a?(AST::DistinctOp)
      return transpile_distinct(lhs, rhs, node)
    elsif rhs.is_a?(AST::EachOp)
      return transpile_each(node)
    elsif rhs.is_a?(AST::FindOp)
      return transpile_find(lhs, rhs, node)
    elsif rhs.is_a?(AST::AnyOp)
      return transpile_any(lhs, rhs, node)
    elsif rhs.is_a?(AST::AllOp)
      return transpile_all(lhs, rhs, node)
    elsif rhs.is_a?(AST::CountOp)
      return transpile_count(lhs, rhs, node)
    elsif rhs.is_a?(AST::SumOp)
      return transpile_sum(lhs, rhs, node)
    elsif rhs.is_a?(AST::AverageOp)
      return transpile_average(lhs, rhs, node)
    elsif rhs.is_a?(AST::MinOp)
      return transpile_min(lhs, rhs, node)
    elsif rhs.is_a?(AST::MaxOp)
      return transpile_max(lhs, rhs, node)
    elsif rhs.is_a?(AST::TakeWhileOp)
      return transpile_take_while(lhs, rhs.expression, node)
    elsif rhs.is_a?(AST::WindowOp)
      return transpile_window(lhs, rhs, node)
    elsif rhs.is_a?(AST::JoinOp)
      return transpile_join(lhs, rhs, node)
    elsif rhs.is_a?(AST::RecoverOp)
      default_code = visit(rhs.default_expr)
      left_code = visit(lhs).sub(/^try /, '')
      return "(#{left_code} catch #{default_code})"
    elsif rhs.is_a?(AST::TapOp)
      return transpile_tap(node)
    elsif rhs.is_a?(AST::SkipOp)
      return transpile_skip(lhs, rhs, node)
    elsif rhs.is_a?(AST::ShardOp)
      raise "SHARD must be followed by s> CONCURRENT EACH"
    elsif rhs.is_a?(AST::ConcurrentOp)
      return transpile_concurrent(node)
    end

    # Simple function pipe: x s> f -> f(x)
    synthetic_call = if rhs.is_a?(AST::Identifier)
      AST::FuncCall.new(rhs.token, rhs.name, [lhs])
    elsif rhs.is_a?(AST::FuncCall)
      AST::FuncCall.new(rhs.token, rhs.name, [lhs] + rhs.args)
    else
      raise "PipelineHost Error: Invalid Pipe Destination #{rhs.class}"
    end

    if rhs.respond_to?(:zig_pattern)
      synthetic_call.zig_pattern = rhs.zig_pattern
    end
    if rhs.respond_to?(:full_type)
      synthetic_call.full_type = rhs.full_type
    end
    if rhs.respond_to?(:coerced_type)
      synthetic_call.coerced_type = rhs.coerced_type
    end

    visit(synthetic_call)
  end
end
