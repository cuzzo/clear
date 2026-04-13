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
    @soa_each_mode = false
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

    # Propagate shard-direct context so MIRLowering emits putDirect/getDirect
    @lowering.shard_context = if @shard_direct_map
      { map: @shard_direct_map, idx: @shard_direct_idx, key: @shard_direct_key }
    end

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

  # Lower an array of AST body statements to MIR nodes, with pipeline
  # placeholder substitution. Used by side-effect operators (Tap, Each, Join)
  # whose loop bodies contain multiple statements.
  def visit_pipeline_body_mir(body_stmts, placeholder:)
    with_pipeline_context(placeholder: placeholder) do
      substituted = body_stmts.map { |stmt| substitute_placeholders(stmt) }
      @lowering.lower_body(substituted)
    end
  end

  private

  # Check whether any statement in an AST array references the `_` placeholder.
  # Used to decide whether to use `|__each_item|` vs `|_|` in while captures.
  def ast_stmts_use_placeholder?(stmts)
    stmts.any? { |s| ast_node_uses_placeholder?(s) }
  end

  def ast_node_uses_placeholder?(node)
    return false unless node
    return false if node.is_a?(String) || node.is_a?(Symbol) || node.is_a?(Numeric) ||
                    node.is_a?(TrueClass) || node.is_a?(FalseClass)
    return node.name == "_" if node.is_a?(AST::Identifier)
    # Traverse known child fields that may contain sub-expressions/statements
    [:left, :right, :value, :args, :object, :target, :index, :condition,
     :then_branch, :else_branch, :do_branch, :body, :start, :finish].each do |field|
      next unless node.respond_to?(field)
      child = node.public_send(field)
      case child
      when Array  then return true if child.any? { |c| ast_node_uses_placeholder?(c) }
      when NilClass, String, Symbol, Numeric, TrueClass, FalseClass, Hash then next
      else return true if ast_node_uses_placeholder?(child)
      end
    end
    false
  end

  # Recursively replace AST::Identifier("_") with the current placeholder name,
  # and join param names with their Zig loop variable names.
  # Returns the node (possibly modified) or a new synthetic Identifier.
  def substitute_placeholders(node)
    return node unless @placeholder_name || @acc_placeholder || @join_param_map || @soa_each_mode

    # SOA EACH: _.field -> synthetic identifier __soa_field[__soa_i]
    if @soa_each_mode && node.is_a?(AST::GetField) &&
       node.target.is_a?(AST::Identifier) && node.target.name == "_"
      @soa_needed_fields << node.field
      new_id = AST::Identifier.new(node.token, "__soa_#{node.field}[__soa_i]")
      copy_type_info(node, new_id)
      return new_id
    end

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
      # SOA field-slice rewrite: _.field -> __soa_field[__soa_i]
      if @soa_rewrite_active && node.target.is_a?(AST::Identifier) && node.target.name == "_"
        @soa_needed_fields << node.field
        soa_field = AST::Identifier.new(node.token, "__soa_#{node.field}")
        soa_idx = AST::Identifier.new(node.token, "__soa_i")
        new_gi = AST::GetIndex.new(node.token, soa_field, soa_idx)
        copy_type_info(node, new_gi)
        return new_gi
      end
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
    when AST::WithBlock
      new_body = node.body.map { |stmt| substitute_placeholders(stmt) }
      if new_body != node.body
        new_with = AST::WithBlock.new(node.token, node.capabilities, new_body, node.deferred_drops)
        copy_type_info(node, new_with)
        return new_with
      end
    end

    node
  end

  def copy_type_info(src, dst)
    dst.full_type = src.full_type if src.respond_to?(:full_type) && src.full_type && dst.respond_to?(:full_type=)
    dst.type_info = src.type_info if src.respond_to?(:type_info) && src.type_info && dst.respond_to?(:type_info=)
    dst.coerced_type = src.coerced_type if src.respond_to?(:coerced_type) && src.coerced_type && dst.respond_to?(:coerced_type=)
    dst.storage = src.storage if src.respond_to?(:storage) && src.storage && dst.respond_to?(:storage=)
    dst.var_used = src.var_used if src.respond_to?(:var_used) && dst.respond_to?(:var_used=)
  end

  public

  # MIR entry point: returns MIR node tree for migrated pipeline operators.
  # Returns nil for non-migrated operators (caller falls back to string path).
  RANGE_FOLD_OPS = [AST::CountOp, AST::SumOp, AST::AverageOp, AST::MinOp,
                    AST::MaxOp, AST::AnyOp, AST::AllOp, AST::FindOp].freeze

  def lower_pipeline(node)
    rhs = node.right
    lhs = node.left
    lhs_type = lhs.type_info

    # SOA scalar operators have zero allocations -- field-slice path in the
    # string generator is strictly better (no materialization overhead).
    # Let them fall through to the string path where field-slice optimization applies.
    is_soa = lhs_type&.soa? && (lhs_type&.pool? || lhs_type&.list_collection? || lhs_type&.fixed_soa?)
    scalar_op = RANGE_FOLD_OPS.any? { |t| rhs.is_a?(t) }
    return nil if is_soa && scalar_op

    # Range source with fold terminal: fuse into a single accumulating while loop.
    if RANGE_FOLD_OPS.any? { |t| rhs.is_a?(t) }
      range_chain = unwrap_range_chain(lhs)
      return lower_range_fold(range_chain[:source], range_chain[:stages], rhs, node) if range_chain
    end

    # Range source with REDUCE: fuse into a single accumulating while loop.
    if rhs.is_a?(AST::ReduceOp)
      range_chain = unwrap_range_chain(lhs)
      return lower_range_reduce(range_chain[:source], range_chain[:stages], rhs) if range_chain
    end

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
    when AST::ConcurrentOp then lower_concurrent(lhs, rhs, node)
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
      [build_mat_sharded_pool(lhs_type), "pipe_items"]
    elsif lhs_type&.pool? && lhs_type&.soa?
      [build_mat_soa_pool(lhs_type), "pipe_items"]
    elsif lhs_type&.pool?
      [build_mat_pool(lhs_type), "pipe_items"]
    elsif (lhs_type&.list_collection? || lhs_type&.fixed_soa?) && lhs_type&.soa?
      [build_mat_soa_list(lhs_type), "pipe_items"]
    elsif lhs_type&.list_collection? && lhs_type&.sharded?
      [build_mat_sharded_list(lhs_type), "pipe_items"]
    else
      # Plain array/list: hasField check for .items vs raw slice
      init = MIR::InlineZig.new(
        'if (@hasField(@TypeOf(pipe_src_list), "items")) pipe_src_list.items else pipe_src_list[0..]',
        "pipe_items_access")
      [[MIR::Let.new("pipe_items", init, false, nil, nil)], "pipe_items"]
    end
  end

  private

  HEAP_ALLOC = "rt.heapAlloc()"

  # Convert allocator symbol to Zig string (for InlineZig content only).
  def alloc_zig_str(sym)
    case sym
    when :heap  then "rt.heapAlloc()"
    when :frame then "rt.frameAlloc()"
    else "rt.heapAlloc()"
    end
  end

  # stdlib_def for InlineZig nodes that pass an allocator (borrows only).
  ALLOC_REF_DEF = { borrows: :all }.freeze
  # stdlib_def for InlineZig nodes that allocate via the passed allocator.
  ALLOCATING_DEF = { allocates: true }.freeze

  # Common: var pipe_mat = ArrayListUnmanaged(T){}; defer pipe_mat.deinit(alloc);
  def mat_var_and_defer(elem_zig)
    var_decl = MIR::Let.new("pipe_mat",
      MIR::InlineZig.new("std.ArrayListUnmanaged(#{elem_zig}){}", "mat_init"),
      true, nil, nil)
    alloc_ref = MIR::InlineZig.new(HEAP_ALLOC, "alloc")
    alloc_ref.stdlib_def = ALLOC_REF_DEF
    defer = MIR::DeferStmt.new(
      MIR::MethodCall.new(MIR::Ident.new("pipe_mat"), "deinit",
        [alloc_ref], false)
    )
    [var_decl, defer]
  end

  # Common: const pipe_items = pipe_mat.items;
  def mat_items_let
    MIR::Let.new("pipe_items", MIR::FieldGet.new(MIR::Ident.new("pipe_mat"), "items"), false, nil, nil)
  end

  # try pipe_mat.append(rt.heapAlloc(), value_expr)
  def mat_append(value_expr)
    alloc_ref = MIR::InlineZig.new(HEAP_ALLOC, "alloc")
    alloc_ref.stdlib_def = ALLOC_REF_DEF
    MIR::ExprStmt.new(
      MIR::MethodCall.new(MIR::Ident.new("pipe_mat"), "append",
        [alloc_ref, value_expr], true), false)
  end

  # try pipe_mat.appendSlice(rt.heapAlloc(), slice_expr)
  def mat_append_slice(slice_expr)
    alloc_ref = MIR::InlineZig.new(HEAP_ALLOC, "alloc")
    alloc_ref.stdlib_def = ALLOC_REF_DEF
    MIR::ExprStmt.new(
      MIR::MethodCall.new(MIR::Ident.new("pipe_mat"), "appendSlice",
        [alloc_ref, slice_expr], true), false)
  end

  # Sharded pool: for each shard, for each slot, append alive values.
  def build_mat_sharded_pool(lhs_type)
    elem_zig = lhs_type.element_type.zig_type
    n = lhs_type.shard_count
    var_decl, defer = mat_var_and_defer(elem_zig)

    inner_loop = MIR::ForStmt.new(
      MIR::FieldGet.new(
        MIR::IndexGet.new(MIR::FieldGet.new(MIR::Ident.new("pipe_src_list"), "shards"),
                          MIR::Ident.new("__psi")),
        "slots"),
      "*__pslot",
      [MIR::IfStmt.new(
        MIR::FieldGet.new(MIR::Ident.new("__pslot"), "alive"),
        [mat_append(MIR::FieldGet.new(MIR::Ident.new("__pslot"), "value"))],
        nil)],
      nil)

    outer_loop = MIR::ForStmt.new(
      MIR::InlineZig.new("0..#{n}", "range"), "__psi", [inner_loop], nil)

    [var_decl, defer, outer_loop, mat_items_let]
  end

  # SOA pool: iterate data.len, check alive[i], append data.get(i).
  def build_mat_soa_pool(lhs_type)
    elem_zig = lhs_type.element_type.zig_type
    var_decl, defer = mat_var_and_defer(elem_zig)

    value_expr = MIR::MethodCall.new(
      MIR::FieldGet.new(MIR::Ident.new("pipe_src_list"), "data"),
      "get", [MIR::Ident.new("__psi")], false)
    alive_check = MIR::IndexGet.new(
      MIR::FieldGet.new(MIR::Ident.new("pipe_src_list"), "alive"),
      MIR::Ident.new("__psi"))

    loop_node = MIR::ForStmt.new(
      MIR::InlineZig.new("0..@intCast(pipe_src_list.data.len)", "range"),
      "__psi",
      [MIR::IfStmt.new(alive_check, [mat_append(value_expr)], nil)],
      nil)

    [var_decl, defer, loop_node, mat_items_let]
  end

  # Plain pool: iterate slots, check alive, append value.
  def build_mat_pool(lhs_type)
    elem_zig = lhs_type.element_type.zig_type
    var_decl, defer = mat_var_and_defer(elem_zig)

    loop_node = MIR::ForStmt.new(
      MIR::FieldGet.new(MIR::Ident.new("pipe_src_list"), "slots"),
      "*__pslot",
      [MIR::IfStmt.new(
        MIR::FieldGet.new(MIR::Ident.new("__pslot"), "alive"),
        [mat_append(MIR::FieldGet.new(MIR::Ident.new("__pslot"), "value"))],
        nil)],
      nil)

    [var_decl, defer, loop_node, mat_items_let]
  end

  # SOA list: iterate data.len, append data.get(i).
  def build_mat_soa_list(lhs_type)
    elem_zig = lhs_type.element_type.zig_type
    var_decl, defer = mat_var_and_defer(elem_zig)

    value_expr = MIR::MethodCall.new(
      MIR::FieldGet.new(MIR::Ident.new("pipe_src_list"), "data"),
      "get", [MIR::Ident.new("__psi")], false)

    loop_node = MIR::ForStmt.new(
      MIR::InlineZig.new("0..@intCast(pipe_src_list.data.len)", "range"),
      "__psi",
      [mat_append(value_expr)],
      nil)

    [var_decl, defer, loop_node, mat_items_let]
  end

  # Sharded list: iterate shards, appendSlice each shard's items.
  def build_mat_sharded_list(lhs_type)
    elem_zig = lhs_type.element_type.zig_type
    n = lhs_type.shard_count
    var_decl, defer = mat_var_and_defer(elem_zig)

    shard_items = MIR::FieldGet.new(
      MIR::IndexGet.new(MIR::FieldGet.new(MIR::Ident.new("pipe_src_list"), "shards"),
                        MIR::Ident.new("__psi")),
      "items")

    loop_node = MIR::ForStmt.new(
      MIR::InlineZig.new("0..#{n}", "range"), "__psi",
      [mat_append_slice(shard_items)],
      nil)

    [var_decl, defer, loop_node, mat_items_let]
  end

  public

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
    smooth_node.respond_to?(:storage) && smooth_node.storage == :heap ? :heap : :frame
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
              [MIR::InlineZig.new(alloc_zig_str(alloc), "alloc").tap { |iz| iz.stdlib_def = ALLOC_REF_DEF }, MIR::Ident.new("it")], true), nil)
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
            [MIR::InlineZig.new(alloc_zig_str(alloc), "alloc").tap { |iz| iz.stdlib_def = ALLOC_REF_DEF }, MIR::Ident.new("val")], true), nil)
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
            "try CheatLib.makeList(#{elem_zig}, #{alloc_zig_str(alloc)}, #{items}[0..lim_actual])",
            "make_limited_list").tap { |iz| iz.stdlib_def = ALLOCATING_DEF })
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
            [MIR::InlineZig.new(alloc_zig_str(alloc), "alloc").tap { |iz| iz.stdlib_def = ALLOC_REF_DEF }, MIR::Ident.new("it")], true), nil)
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
              [MIR::InlineZig.new(alloc_zig_str(alloc), "alloc").tap { |iz| iz.stdlib_def = ALLOC_REF_DEF }, MIR::Ident.new("it")], true), nil)
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
              [MIR::InlineZig.new(alloc_zig_str(alloc), "alloc").tap { |iz| iz.stdlib_def = ALLOC_REF_DEF }, MIR::Ident.new("inner_it")], true), nil)
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
              MIR::Let.new("__wi", MIR::Lit.new("0"), true, "usize", nil),
              MIR::WhileStmt.new(
                MIR::BinOp.new("<=",
                  MIR::Ident.new("__wi"),
                  MIR::BinOp.new("-",
                    MIR::FieldGet.new(MIR::Ident.new(items), "len"),
                    MIR::Ident.new("__w_size"))),
                [
                  MIR::Let.new("window_slice",
                    MIR::InlineZig.new("#{items}[__wi .. __wi + __w_size]", "window_slice_expr"),
                    false, nil, nil),
                  MIR::Let.new("val", expr_mir, false, nil, nil),
                  MIR::ExprStmt.new(MIR::MethodCall.new(
                    MIR::Ident.new("res_list"), "append",
                    [MIR::InlineZig.new(alloc_zig_str(alloc), "alloc").tap { |iz| iz.stdlib_def = ALLOC_REF_DEF }, MIR::Ident.new("val")],
                    true), nil)
                ],
                nil,
                MIR::Set.new(MIR::Ident.new("__wi"),
                  MIR::BinOp.new("+", MIR::Ident.new("__wi"), MIR::Lit.new("1"))),
                nil, nil)
            ], nil)
        ]),
        MIR::BreakStmt.new(label, MIR::Ident.new("res_list"))
      ]
    end
  end

  def lower_order_by(list_node, order_node, smooth_node)
    elem_zig = transpile_type(list_node.full_type.element_type.resolved.to_s)
    alloc = pipeline_alloc(smooth_node)
    key_a = with_pipeline_context(placeholder: "a") { visit_mir(order_node.expression) }
    key_b = with_pipeline_context(placeholder: "b") { visit_mir(order_node.expression) }
    sort_code = "std.mem.sort(#{elem_zig}, ord_result.items, {}, struct {\n" \
                "    pub fn lessThan(_: void, a: #{elem_zig}, b: #{elem_zig}) bool {\n" \
                "        return #{@emitter.emit(key_a)} < #{@emitter.emit(key_b)};\n" \
                "    }\n" \
                "}.lessThan)"
    lower_pipeline_block(list_node) do |items, label|
      [
        MIR::Let.new("ord_result",
          MIR::InlineZig.new(
            "try CheatLib.makeList(#{elem_zig}, #{alloc_zig_str(alloc)}, #{items})",
            "make_ord_list").tap { |iz| iz.stdlib_def = ALLOCATING_DEF }, true, nil, "_ = &ord_result;"),
        MIR::ExprStmt.new(MIR::InlineZig.new(sort_code, "order_by_sort"), nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("ord_result"))
      ]
    end
  end

  def lower_index(list_node, expr_node, smooth_node)
    elem_zig = transpile_type(list_node.full_type.element_type.resolved.to_s)
    alloc = pipeline_alloc(smooth_node)
    expr_mir = visit_pipeline_expr_mir(list_node, expr_node)
    map_type = "CheatLib.StringMap(std.ArrayListUnmanaged(#{elem_zig}))"
    lower_pipeline_block(list_node) do |items, label|
      [
        MIR::Let.new("idx_result",
          MIR::InlineZig.new(".{ .alloc = #{alloc_zig_str(alloc)} }", "idx_init_val"),
          true, map_type, nil),
        MIR::ForStmt.new(MIR::Ident.new(items), "it", [
          MIR::Let.new("idx_key", expr_mir, false, nil, nil),
          # Dupe the key so the HashMap owns its own copy. If found_existing, the duped
          # copy is unused — free it immediately to avoid a leak.
          MIR::Let.new("idx_key_owned",
            MIR::InlineZig.new(
              "try #{alloc_zig_str(alloc)}.dupe(u8, idx_key)",
              "idx_key_dupe").tap { |iz| iz.stdlib_def = ALLOCATING_DEF }, false, nil, nil),
          MIR::Let.new("gop",
            MIR::InlineZig.new(
              "idx_result.inner.getOrPut(#{alloc_zig_str(alloc)}, idx_key_owned) catch @panic(\"INDEX allocation failed\")",
              "idx_get_or_put").tap { |iz| iz.stdlib_def = ALLOCATING_DEF }, false, nil, nil),
          MIR::IfStmt.new(
            MIR::FieldGet.new(MIR::Ident.new("gop"), "found_existing"),
            [MIR::ExprStmt.new(
              MIR::InlineZig.new(
                "#{alloc_zig_str(alloc)}.free(idx_key_owned)",
                "idx_key_free"), nil)
            ], nil),
          MIR::IfStmt.new(
            MIR::UnaryOp.new("!", MIR::FieldGet.new(MIR::Ident.new("gop"), "found_existing")),
            [MIR::ExprStmt.new(
              MIR::InlineZig.new(
                "gop.value_ptr.* = std.ArrayListUnmanaged(#{elem_zig}){}",
                "idx_init_slot"), nil)
            ], nil),
          MIR::ExprStmt.new(
            MIR::InlineZig.new(
              "gop.value_ptr.append(#{alloc_zig_str(alloc)}, it) catch @panic(\"INDEX append failed\")",
              "idx_append").tap { |iz| iz.stdlib_def = ALLOCATING_DEF }, nil)
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
    alloc = :frame

    key_expr = join_node.key_expr
    is_lambda = key_expr.is_a?(AST::LambdaLit)

    if is_lambda
      params = key_expr.params
      left_param  = params[0].is_a?(Hash) ? params[0][:name] : params[0].name
      right_param = params[1].is_a?(Hash) ? params[1][:name] : params[1].name
      old_join_map = @join_param_map
      @join_param_map = { left_param => "__jl", right_param => "__jr" }
      pred_mir = visit_mir(key_expr.body)
      @join_param_map = old_join_map
    else
      left_key_mir  = with_pipeline_context(placeholder: "__jl") { visit_mir(key_expr) }
      right_key_mir = with_pipeline_context(placeholder: "__jr") { visit_mir(key_expr) }
      pred_mir = MIR::Call.new("CheatLib.eql", [left_key_mir, right_key_mir], false)
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
          "try CheatLib.makeList(#{result_zig}, #{alloc_zig_str(alloc)}, &.{})",
          "join_make_list").tap { |iz| iz.stdlib_def = ALLOCATING_DEF }, true, nil, nil),
      MIR::ForStmt.new(MIR::Ident.new("__jl_items"), "__jl", [
        MIR::Let.new("__match", MIR::Lit.new("null"), true, "?#{right_zig}", nil),
        MIR::ForStmt.new(MIR::Ident.new("__jr_items"), "__jr", [
          MIR::IfStmt.new(pred_mir, [
            MIR::Set.new(MIR::Ident.new("__match"), MIR::Ident.new("__jr")),
            MIR::BreakStmt.new(nil, nil),
          ], nil)
        ], nil),
        MIR::ExprStmt.new(MIR::MethodCall.new(
          MIR::Ident.new("res_list"), "append",
          [MIR::InlineZig.new(alloc_zig_str(alloc), "alloc").tap { |iz| iz.stdlib_def = ALLOC_REF_DEF },
           MIR::InlineZig.new(".{ .left = __jl, .right = __match }", "join_pair")],
          true), nil)
      ], nil),
      MIR::BreakStmt.new(label, MIR::Ident.new("res_list"))
    ])
  end

  def lower_tap(list_node, tap_op, smooth_node)
    label = next_pipe_label
    source_mir = visit_mir(list_node)
    @current_pipe_label = label

    body_mir = visit_pipeline_body_mir(tap_op.body, placeholder: "__tap_item")

    MIR::BlockExpr.new(label, [
      MIR::Let.new("__tap_src", source_mir, false, nil, nil),
      MIR::Let.new("__tap_items",
        MIR::InlineZig.new(
          'if (@hasField(@TypeOf(__tap_src), "items")) __tap_src.items else __tap_src[0..]',
          "tap_items"), false, nil, nil),
      MIR::ForStmt.new(MIR::Ident.new("__tap_items"), "__tap_item", body_mir, nil),
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
      # SOA path: field-slice access (preserves SOA cache locality).
      # substitute_placeholders rewrites _.field -> __soa_field[__soa_i]
      # and collects accessed fields in @soa_needed_fields.
      prev_soa_active = @soa_rewrite_active
      prev_soa_fields = @soa_needed_fields
      @soa_rewrite_active = true
      @soa_each_mode = true
      @soa_needed_fields = Set.new

      body_mir = visit_pipeline_body_mir(each_op.body, placeholder: "_")

      source_mir = visit_mir(list_node)
      field_slice_lets = @soa_needed_fields.map { |f|
        MIR::Let.new("__soa_#{f}",
          MIR::InlineZig.new("__soa_src.data.items(.#{f})", "soa_field_#{f}"),
          false, nil, nil)
      }

      alive_guard = if lhs_type&.pool?
        [MIR::IfStmt.new(
          MIR::UnaryOp.new("!",
            MIR::IndexGet.new(
              MIR::FieldGet.new(MIR::Ident.new("__soa_src"), "alive"),
              MIR::Ident.new("__soa_i"))),
          [MIR::ContinueStmt.new(nil)], nil)]
      else
        []
      end

      @soa_rewrite_active = prev_soa_active
      @soa_each_mode = false
      @soa_needed_fields = prev_soa_fields

      return MIR::ScopeBlock.new([
        MIR::Let.new("__soa_src", MIR::UnaryOp.new("&", source_mir), false, nil, nil),
        *field_slice_lets,
        MIR::ForStmt.new(
          MIR::InlineZig.new("0..@intCast(__soa_src.data.len)", "soa_range"),
          "__soa_i",
          [*alive_guard, *body_mir],
          nil)
      ])
    end

    # Non-SOA pool: iterate slots with alive check
    if lhs_type&.pool?
      source_mir = visit_mir(list_node)
      body_mir = visit_pipeline_body_mir(each_op.body, placeholder: "__each_item")
      return MIR::ScopeBlock.new([
        MIR::Let.new("__each_src", MIR::UnaryOp.new("&", source_mir), false, nil, nil),
        MIR::ForStmt.new(
          MIR::FieldGet.new(MIR::Ident.new("__each_src"), "slots"),
          "*__each_slot",
          [
            MIR::IfStmt.new(
              MIR::UnaryOp.new("!", MIR::FieldGet.new(MIR::Ident.new("__each_slot"), "alive")),
              [MIR::ContinueStmt.new(nil)], nil),
            MIR::Let.new("__each_item",
              MIR::UnaryOp.new("&", MIR::FieldGet.new(MIR::Ident.new("__each_slot"), "value")),
              false, nil, nil),
            *body_mir
          ], nil)
      ])
    end

    # Finite stream source (direct range or variable-backed ~T[]): zero-allocation
    # pull iteration via .next().
    range_chain = unwrap_range_chain(list_node)
    return lower_each_range(range_chain[:source], range_chain[:stages], each_op) if range_chain

    # Non-SOA list collection or fixed_soa: iterate items
    if lhs_type&.list_collection? || lhs_type&.fixed_soa?
      source_mir = visit_mir(list_node)
      body_mir = visit_pipeline_body_mir(each_op.body, placeholder: "__each_item")
      return MIR::ScopeBlock.new([
        MIR::Let.new("__each_src", source_mir, false, nil, nil),
        MIR::Let.new("__each_items",
          MIR::InlineZig.new(
            'if (@hasField(@TypeOf(__each_src), "items")) __each_src.items else __each_src[0..]',
            "each_items"), false, nil, nil),
        MIR::ForStmt.new(MIR::Ident.new("__each_items"), "__each_item", body_mir, nil)
      ])
    end

    # Range source: zero-allocation lazy iteration via LazyRange(T).
    # `(start..<end) s> EACH { body }` emits a while loop that pulls items
    # one-by-one from a LazyRange without materializing the range into a list.
    if list_node.is_a?(AST::RangeLit)
      start_mir = visit_mir(list_node.start)
      end_mir   = visit_mir(list_node.finish)
      start_code = @emitter.emit(start_mir)
      end_code   = @emitter.emit(end_mir)
      end_expr   = list_node.inclusive ? "#{end_code} + 1" : end_code

      start_ft = list_node.start.respond_to?(:full_type) ? list_node.start.full_type : nil
      elem_zig = (start_ft && Type.new(start_ft).zig_type) || "i64"

      body_mir = visit_pipeline_body_mir(each_op.body, placeholder: "__each_item")

      # Use `|_|` as the while capture when the body doesn't reference the
      # element, to avoid Zig's "unused capture" error. Use `|__each_item|`
      # when the body does reference it.
      capture_name = ast_stmts_use_placeholder?(each_op.body) ? "__each_item" : "_"

      return MIR::ScopeBlock.new([
        MIR::Let.new("__range_src",
          MIR::InlineZig.new(
            "CheatLib.LazyRange(#{elem_zig}).init(@as(#{elem_zig}, #{start_code}), @as(#{elem_zig}, #{end_expr}))",
            "lazy_range"),
          true, nil, nil),
        MIR::WhileStmt.new(
          MIR::InlineZig.new("try __range_src.next(rt)", "lazy_range_next"),
          body_mir, capture_name, nil, nil, nil)
      ])
    end

    nil  # Fall through to string path
  end

  def finite_stream_source_node?(node)
    node.is_a?(AST::RangeLit) || node.type_info&.dynamic_stream?
  end

  # Walk a BinaryOp(SMOOTH) left-spine looking for a finite stream source
  # with only fusible stages between.
  def unwrap_range_chain(node)
    return { source: node, stages: [] } if finite_stream_source_node?(node)
    return nil unless node.is_a?(AST::BinaryOp) && node.op == :SMOOTH

    stages = []
    cursor = node
    while cursor.is_a?(AST::BinaryOp) && cursor.op == :SMOOTH
      rhs = cursor.right
      if rhs.is_a?(AST::SelectOp)   || rhs.is_a?(AST::WhereOp)     ||
         rhs.is_a?(AST::TakeWhileOp) || rhs.is_a?(AST::LimitOp)    ||
         rhs.is_a?(AST::SkipOp)      || rhs.is_a?(AST::TapOp)
        stages.unshift(rhs)
        cursor = cursor.left
      else
        return nil
      end
    end
    return nil unless finite_stream_source_node?(cursor)
    { source: cursor, stages: stages }
  end

  # Lower a fold expression and wrap in @floatFromInt if the expression is an integer type.
  # SUM/AVERAGE/MIN/MAX accumulators are f64; integer range elements need coercion.
  def numeric_fold_expr_f64(expr_ast, item_var)
    expr_mir = with_pipeline_context(placeholder: item_var) { visit_mir(expr_ast) }
    expr_type = expr_ast.respond_to?(:full_type) ? expr_ast.full_type : nil
    if expr_type && Type.new(expr_type).integer?
      MIR::InlineZig.new("@as(f64, @floatFromInt(#{@emitter.emit(expr_mir)}))", "to_f64")
    else
      expr_mir
    end
  end

  # Build the finite-stream source setup + stage prefix shared by lower_each_range and lower_range_fold.
  # Returns a hash: { source_setup, outer_stmts, stage_stmts, item_var, initial_capture,
  #                   item_used, elem_zig }
  # `item_used` tracks whether the initial capture (`__each_item`) is referenced
  # by any stage -- used by callers to decide between |__each_item| and |_| in Zig.
  def build_lazy_range_prefix(source_node, stages)
    source_ti = source_node.type_info
    elem_t = if source_ti&.dynamic_stream?
      source_ti.tense_type.element_type
    else
      start_ft = source_node.respond_to?(:start) && source_node.start.respond_to?(:full_type) ? source_node.start.full_type : nil
      Type.new(start_ft || :Int64)
    end
    elem_zig = elem_t.zig_type

    initial_capture = "__each_item"
    item_var    = initial_capture
    item_counter = 0
    item_used   = false
    outer_stmts = []
    stage_stmts = []

    stages.each do |stage|
      case stage
      when AST::SelectOp
        item_used = true
        next_item = "__each_item_#{item_counter += 1}"
        expr_mir = with_pipeline_context(placeholder: item_var) { visit_mir(stage.expression) }
        stage_stmts << MIR::Let.new(next_item, expr_mir, false, nil, nil)
        item_var = next_item

      when AST::WhereOp
        item_used = true if item_var == initial_capture
        pred_mir  = with_pipeline_context(placeholder: item_var) { visit_mir(stage.expression) }
        stage_stmts << MIR::IfStmt.new(
          MIR::UnaryOp.new("!", pred_mir), [MIR::ContinueStmt.new(nil)], nil)

      when AST::TakeWhileOp
        item_used = true if item_var == initial_capture
        pred_mir  = with_pipeline_context(placeholder: item_var) { visit_mir(stage.expression) }
        stage_stmts << MIR::IfStmt.new(
          MIR::UnaryOp.new("!", pred_mir), [MIR::BreakStmt.new(nil, nil)], nil)

      when AST::LimitOp
        cvar = "__limit_cnt_#{item_counter += 1}"
        cnt_code = @emitter.emit(visit_mir(stage.count))
        outer_stmts << MIR::Let.new(cvar,
          MIR::InlineZig.new("@as(i64, 0)", "zero"), true, nil, nil)
        stage_stmts << MIR::IfStmt.new(
          MIR::InlineZig.new("#{cvar} >= #{cnt_code}", "limit_chk"),
          [MIR::BreakStmt.new(nil, nil)], nil)
        stage_stmts << MIR::ExprStmt.new(
          MIR::InlineZig.new("#{cvar} += 1", "limit_inc"), nil)

      when AST::SkipOp
        cvar = "__skip_cnt_#{item_counter += 1}"
        cnt_code = @emitter.emit(visit_mir(stage.count))
        outer_stmts << MIR::Let.new(cvar,
          MIR::InlineZig.new("@as(i64, 0)", "zero"), true, nil, nil)
        stage_stmts << MIR::IfStmt.new(
          MIR::InlineZig.new("#{cvar} < #{cnt_code}", "skip_chk"),
          [MIR::ExprStmt.new(MIR::InlineZig.new("#{cvar} += 1", "skip_inc"), nil),
           MIR::ContinueStmt.new(nil)], nil)

      when AST::TapOp
        item_used = true if item_var == initial_capture
        stage_stmts.concat(visit_pipeline_body_mir(stage.body, placeholder: item_var))
      end
    end

    source_setup = unless source_node.is_a?(AST::Identifier) && source_ti&.dynamic_stream?
      MIR::Let.new("__range_src", visit_mir(source_node), true, nil, "_ = &__range_src;")
    end

    { source_setup: source_setup, outer_stmts: outer_stmts, stage_stmts: stage_stmts,
      item_var: item_var, initial_capture: initial_capture, item_used: item_used,
      elem_zig: elem_zig }
  end

  # Emit a fused while loop for a finite stream source with zero or more fusible stages.
  def lower_each_range(range_lit, stages, each_op)
    p = build_lazy_range_prefix(range_lit, stages)
    item_var        = p[:item_var]
    initial_capture = p[:initial_capture]
    item_used       = p[:item_used]
    source_name     = (range_lit.is_a?(AST::Identifier) && range_lit.type_info&.dynamic_stream?) ? visit_mir(range_lit).name : "__range_src"

    body_mir = visit_pipeline_body_mir(each_op.body, placeholder: item_var)

    # Use |_| only when the initial capture is never referenced (avoids Zig
    # "unused capture" error).
    body_uses_initial = (item_var == initial_capture) && ast_stmts_use_placeholder?(each_op.body)
    item_used ||= body_uses_initial
    capture_name = item_used ? initial_capture : "_"

    MIR::ScopeBlock.new([
      *([p[:source_setup]].compact), *p[:outer_stmts],
      MIR::WhileStmt.new(
        MIR::InlineZig.new("try #{source_name}.next()", "lazy_range_next"),
        [*p[:stage_stmts], *body_mir],
        capture_name, nil, nil, nil)
    ])
  end

  # Emit a single fused accumulating while loop for range s> stages s> fold.
  # fold_op is one of CountOp, SumOp, AverageOp, AnyOp, AllOp, FindOp, MinOp, MaxOp.
  # Returns a MIR::BlockExpr (labeled) so the accumulated result can be used as an expression.
  def lower_range_fold(range_lit, stages, fold_op, smooth_node)
    p = build_lazy_range_prefix(range_lit, stages)
    item_var = p[:item_var]
    elem_zig = p[:elem_zig]
    source_name = (range_lit.is_a?(AST::Identifier) && range_lit.type_info&.dynamic_stream?) ? visit_mir(range_lit).name : "__range_src"

    # Fold always references the element; always use the initial capture name.
    capture_name = p[:initial_capture]

    label          = next_pipe_label
    acc_init_stmts = []   # accumulator var declarations (before while)
    loop_acc_stmts = []   # accumulator update stmts (inside while, after stages)
    post_loop_stmts = []  # post-loop checks (panic for MIN/MAX on empty)
    result_expr    = nil  # MIR expression evaluated as the block result

    case fold_op
    when AST::CountOp
      pred_mir = with_pipeline_context(placeholder: item_var) { visit_mir(fold_op.expression) }
      acc_init_stmts << MIR::Let.new("__fold_acc", MIR::Lit.new("0"), true, "i64", nil)
      loop_acc_stmts << MIR::IfStmt.new(pred_mir, [
        MIR::Set.new(MIR::Ident.new("__fold_acc"),
          MIR::BinOp.new("+", MIR::Ident.new("__fold_acc"), MIR::Lit.new("1")))
      ], nil)
      result_expr = MIR::Ident.new("__fold_acc")

    when AST::SumOp
      expr_f64 = numeric_fold_expr_f64(fold_op.expression, item_var)
      acc_init_stmts << MIR::Let.new("__fold_acc", MIR::Lit.new("0"), true, "f64", nil)
      loop_acc_stmts << MIR::Set.new(MIR::Ident.new("__fold_acc"),
        MIR::BinOp.new("+", MIR::Ident.new("__fold_acc"), expr_f64))
      result_expr = MIR::Ident.new("__fold_acc")

    when AST::AverageOp
      expr_f64 = numeric_fold_expr_f64(fold_op.expression, item_var)
      acc_init_stmts << MIR::Let.new("__fold_sum", MIR::Lit.new("0"), true, "f64", nil)
      acc_init_stmts << MIR::Let.new("__fold_cnt", MIR::Lit.new("0"), true, "i64", nil)
      loop_acc_stmts << MIR::Set.new(MIR::Ident.new("__fold_sum"),
        MIR::BinOp.new("+", MIR::Ident.new("__fold_sum"), expr_f64))
      loop_acc_stmts << MIR::Set.new(MIR::Ident.new("__fold_cnt"),
        MIR::BinOp.new("+", MIR::Ident.new("__fold_cnt"), MIR::Lit.new("1")))
      result_expr = MIR::Conditional.new(
        MIR::BinOp.new("==", MIR::Ident.new("__fold_cnt"), MIR::Lit.new("0")),
        MIR::Cast.new(MIR::Lit.new("0"), "f64", :as),
        MIR::BinOp.new("/", MIR::Ident.new("__fold_sum"),
          MIR::InlineZig.new("@as(f64, @floatFromInt(__fold_cnt))", "int_to_f64")))

    when AST::MinOp
      expr_f64 = numeric_fold_expr_f64(fold_op.expression, item_var)
      acc_init_stmts << MIR::Let.new("__fold_acc",
        MIR::InlineZig.new("std.math.floatMax(f64)", "float_max"), true, "f64", nil)
      acc_init_stmts << MIR::Let.new("__fold_found", MIR::Lit.new("false"), true, nil, nil)
      loop_acc_stmts << MIR::Let.new("__fold_val", expr_f64, false, nil, nil)
      loop_acc_stmts << MIR::IfStmt.new(
        MIR::BinOp.new("<", MIR::Ident.new("__fold_val"), MIR::Ident.new("__fold_acc")),
        [MIR::Set.new(MIR::Ident.new("__fold_acc"), MIR::Ident.new("__fold_val")),
         MIR::Set.new(MIR::Ident.new("__fold_found"), MIR::Lit.new("true"))], nil)
      post_loop_stmts << MIR::ExprStmt.new(MIR::InlineZig.new(
        "if (!__fold_found) @panic(\"MIN applied to empty sequence\")", "min_check"), nil)
      result_expr = MIR::Ident.new("__fold_acc")

    when AST::MaxOp
      expr_f64 = numeric_fold_expr_f64(fold_op.expression, item_var)
      acc_init_stmts << MIR::Let.new("__fold_acc",
        MIR::InlineZig.new("-std.math.floatMax(f64)", "float_min"), true, "f64", nil)
      acc_init_stmts << MIR::Let.new("__fold_found", MIR::Lit.new("false"), true, nil, nil)
      loop_acc_stmts << MIR::Let.new("__fold_val", expr_f64, false, nil, nil)
      loop_acc_stmts << MIR::IfStmt.new(
        MIR::BinOp.new(">", MIR::Ident.new("__fold_val"), MIR::Ident.new("__fold_acc")),
        [MIR::Set.new(MIR::Ident.new("__fold_acc"), MIR::Ident.new("__fold_val")),
         MIR::Set.new(MIR::Ident.new("__fold_found"), MIR::Lit.new("true"))], nil)
      post_loop_stmts << MIR::ExprStmt.new(MIR::InlineZig.new(
        "if (!__fold_found) @panic(\"MAX applied to empty sequence\")", "max_check"), nil)
      result_expr = MIR::Ident.new("__fold_acc")

    when AST::AnyOp
      pred_mir = with_pipeline_context(placeholder: item_var) { visit_mir(fold_op.expression) }
      acc_init_stmts << MIR::Let.new("__fold_acc", MIR::Lit.new("false"), true, nil, nil)
      loop_acc_stmts << MIR::IfStmt.new(pred_mir, [
        MIR::Set.new(MIR::Ident.new("__fold_acc"), MIR::Lit.new("true")),
        MIR::BreakStmt.new(nil, nil)
      ], nil)
      result_expr = MIR::Ident.new("__fold_acc")

    when AST::AllOp
      pred_mir = with_pipeline_context(placeholder: item_var) { visit_mir(fold_op.expression) }
      acc_init_stmts << MIR::Let.new("__fold_acc", MIR::Lit.new("true"), true, nil, nil)
      loop_acc_stmts << MIR::IfStmt.new(MIR::UnaryOp.new("!", pred_mir), [
        MIR::Set.new(MIR::Ident.new("__fold_acc"), MIR::Lit.new("false")),
        MIR::BreakStmt.new(nil, nil)
      ], nil)
      result_expr = MIR::Ident.new("__fold_acc")

    when AST::FindOp
      # Element type after stages: derive from smooth_node.full_type (?ElemType)
      result_ft = Type.new(smooth_node.full_type)
      find_zig  = result_ft.optional? ? transpile_type(result_ft.wrapped_type.resolved.to_s) : elem_zig
      pred_mir = with_pipeline_context(placeholder: item_var) { visit_mir(fold_op.expression) }
      acc_init_stmts << MIR::Let.new("__fold_result",
        MIR::InlineZig.new("undefined", "undef"), true, find_zig, nil)
      acc_init_stmts << MIR::Let.new("__fold_found", MIR::Lit.new("false"), true, nil, nil)
      loop_acc_stmts << MIR::IfStmt.new(pred_mir, [
        MIR::Set.new(MIR::Ident.new("__fold_result"), MIR::Ident.new(item_var)),
        MIR::Set.new(MIR::Ident.new("__fold_found"), MIR::Lit.new("true")),
        MIR::BreakStmt.new(nil, nil)
      ], nil)
      result_expr = MIR::Conditional.new(
        MIR::Ident.new("__fold_found"),
        MIR::Cast.new(MIR::Ident.new("__fold_result"), "?#{find_zig}", :as),
        MIR::Lit.new("null"))
    end

    MIR::BlockExpr.new(label, [
      *([p[:source_setup]].compact), *p[:outer_stmts], *acc_init_stmts,
      MIR::WhileStmt.new(
        MIR::InlineZig.new("try #{source_name}.next()", "lazy_range_next"),
        [*p[:stage_stmts], *loop_acc_stmts],
        capture_name, nil, nil, nil),
      *post_loop_stmts,
      MIR::BreakStmt.new(label, result_expr)
    ])
  end

  # Emit a single fused accumulating while loop for range s> stages s> REDUCE(init) body.
  # Returns a MIR::BlockExpr so the accumulated result can be used as an expression.
  def lower_range_reduce(range_lit, stages, reduce_op)
    p = build_lazy_range_prefix(range_lit, stages)
    item_var = p[:item_var]
    source_name = (range_lit.is_a?(AST::Identifier) && range_lit.type_info&.dynamic_stream?) ? visit_mir(range_lit).name : "__range_src"

    label    = next_pipe_label
    acc_zig  = transpile_type(reduce_op.full_type.to_s)
    init_mir = visit_mir(reduce_op.initial_value)
    expr_mir = with_pipeline_context(placeholder: item_var, acc: "acc") {
      visit_mir(reduce_op.expression)
    }

    MIR::BlockExpr.new(label, [
      *([p[:source_setup]].compact), *p[:outer_stmts],
      MIR::Let.new("acc", init_mir, true, acc_zig, nil),
      MIR::WhileStmt.new(
        MIR::InlineZig.new("try #{source_name}.next()", "lazy_range_next"),
        [*p[:stage_stmts], MIR::Set.new(MIR::Ident.new("acc"), expr_mir)],
        p[:initial_capture], nil, nil, nil),
      MIR::BreakStmt.new(label, MIR::Ident.new("acc"))
    ])
  end

  # CONCURRENT pipeline: worker dispatch stays as RawZig string (struct defs,
  # atomics, spawn -- too complex for MIR nodes), but with stdlib_def so the
  # checker knows the allocation effects.
  def lower_concurrent(_lhs, conc_op, smooth_node)
    if smooth_node.left.type_info&.bounded_stream?
      return lower_concurrent_bounded_stream(smooth_node.left, conc_op)
    end

    if unwrap_range_chain(smooth_node.left)
      raise "CONCURRENT over finite streams is temporarily disabled until it has a MIR-safe lowering path"
    end

    inner = conc_op.op
    zig_code = transpile_concurrent(smooth_node)

    allocates = case inner
                when AST::SelectOp, AST::WhereOp then true
                else false
                end

    stdlib_def = { allocates: allocates }
    stdlib_def[:return] = :Void unless allocates

    MIR::RawZig.new(zig_code,
      "concurrent_#{inner.class.name.split('::').last.downcase}",
      { consumes: [], produces: [], borrows: [] },
      stdlib_def)
  end

  def lower_concurrent_bounded_stream(lhs, conc_op)
    inner = conc_op.op
    case inner
    when AST::SelectOp
      lower_concurrent_bounded_select(lhs, conc_op, inner)
    when AST::WhereOp
      lower_concurrent_bounded_where(lhs, conc_op, inner)
    when AST::EachOp
      lower_concurrent_bounded_each(lhs, conc_op, inner)
    else
      raise "CONCURRENT over bounded streams only supports SELECT/WHERE/EACH"
    end
  end

  def bounded_concurrent_worker_count_mir(conc_op)
    if (workers = conc_op.options["workers"])
      visit_mir(workers)
    else
      MIR::Call.new("CheatLib.threadCount", [], false)
    end
  end

  def bounded_concurrent_parallel_mir(conc_op)
    if (par = conc_op.options["parallel"])
      visit_mir(par)
    else
      MIR::Lit.new("false")
    end
  end

  def bounded_concurrent_task_cfg_mir(conc_op)
    size_node = conc_op.options["size"]
    MIR::InlineZig.new(task_config_zig(size_node&.name&.downcase&.to_sym), "task_cfg")
  end

  def build_bounded_concurrent_callback(conc_op, item_type, return_type, body_kind)
    @bounded_conc_counter ||= 0
    id = (@bounded_conc_counter += 1)
    ctx_name = "__BoundedConcurrentCtx#{id}"
    analysis = conc_op.capture_analysis
    captures = analysis&.captures || {}

    fields = captures.map do |name, type_obj|
      zig_t = Type.new(type_obj).zig_type
      mutable = @lowering.instance_variable_get(:@scope_stack)&.last&.is_mutable?(name)
      ptr_t = mutable ? "*#{zig_t}" : "*const #{zig_t}"
      MIR::FieldDef.new(name, ptr_t, nil)
    end

    raw_ctx = MIR::Param.new("raw_ctx", "?*anyopaque")
    params = [
      MIR::Param.new("__rt", "*Runtime"),
      raw_ctx,
      MIR::Param.new("__item", Type.new(item_type).zig_type),
    ]

    body = [MIR::Suppress.new("__rt")]
    capture_map = {}
    unless captures.empty?
      ctx_cast = MIR::InlineZig.new("@as(*@This(), @ptrCast(@alignCast(raw_ctx.?)))", "bounded_concurrent_ctx_cast")
      body << MIR::Let.new("ctx", ctx_cast, false, nil, nil)
      capture_map = captures.keys.to_h { |name| [name, "ctx.#{name}.*"] }
    else
      body << MIR::Suppress.new("raw_ctx")
    end

    lowered_body = with_pipeline_context(placeholder: "__item") do
      with_fiber_capture_map(capture_map, rt_override: "__rt") do
        case body_kind
        when :expr
          [MIR::ReturnStmt.new(visit_mir(conc_op.op.expression))]
        when :each
          [*visit_pipeline_body_mir(conc_op.op.body, placeholder: "__item"), MIR::ReturnStmt.new(nil)]
        else
          raise "unknown bounded concurrent callback kind #{body_kind}"
        end
      end
    end
    body.concat(lowered_body)

    fn = MIR::FnDef.new("apply", params, Type.new(return_type).zig_type, body, nil, true, nil)
    ctx_def = MIR::StructDef.new(ctx_name, fields, [fn], nil)
    ctx_init = MIR::StructInit.new(ctx_name, captures.keys.map { |name|
      { name: name, value: MIR::AddressOf.new(MIR::Ident.new(name)) }
    })
    ctx_var = "__bounded_conc_ctx_#{id}"
    ctx_let = MIR::Let.new(ctx_var, ctx_init, true, nil, "_ = &#{ctx_var};")

    { id: id, ctx_name: ctx_name, ctx_def: ctx_def, ctx_var: ctx_var, ctx_let: ctx_let }
  end

  def bounded_stream_items_setup(lhs, id)
    source = visit_mir(lhs)
    if lhs.is_a?(AST::Identifier)
      [[], MIR::AddressOf.new(MIR::FieldGet.new(source, "items"))]
    else
      local = "__bounded_conc_stream_#{id}"
      setup = MIR::Let.new(local, source, true, nil, "_ = &#{local};")
      [[setup], MIR::AddressOf.new(MIR::FieldGet.new(MIR::Ident.new(local), "items"))]
    end
  end

  def lower_concurrent_bounded_select(lhs, conc_op, inner)
    item_t = lhs.type_info.stream_element_type
    result_t = Type.new(inner.expression.full_type)
    cb = build_bounded_concurrent_callback(conc_op, item_t, result_t, :expr)
    setup_stmts, items_ptr = bounded_stream_items_setup(lhs, cb[:id])

    call = @lowering.send(:emit_builtin, :concurrentBoundedSelect, [
      MIR::Ident.new(item_t.zig_type),
      MIR::Ident.new(result_t.zig_type),
      MIR::Lit.new(lhs.type_info.stream_capacity.to_s),
      MIR::Ident.new("#{cb[:ctx_name]}.apply"),
      MIR::MethodCall.new(MIR::Ident.new("rt"), "heapAlloc", [], false),
      MIR::Ident.new("rt"),
      items_ptr,
      bounded_concurrent_worker_count_mir(conc_op),
      bounded_concurrent_parallel_mir(conc_op),
      bounded_concurrent_task_cfg_mir(conc_op),
      MIR::AddressOf.new(MIR::Ident.new(cb[:ctx_var])),
    ])

    label = next_pipe_label
    MIR::BlockExpr.new(label, [
      cb[:ctx_def],
      cb[:ctx_let],
      *setup_stmts,
      MIR::BreakStmt.new(label, call),
    ])
  end

  def lower_concurrent_bounded_where(lhs, conc_op, _inner)
    item_t = lhs.type_info.stream_element_type
    cb = build_bounded_concurrent_callback(conc_op, item_t, :Bool, :expr)
    setup_stmts, items_ptr = bounded_stream_items_setup(lhs, cb[:id])

    call = @lowering.send(:emit_builtin, :concurrentBoundedWhere, [
      MIR::Ident.new(item_t.zig_type),
      MIR::Lit.new(lhs.type_info.stream_capacity.to_s),
      MIR::Ident.new("#{cb[:ctx_name]}.apply"),
      MIR::MethodCall.new(MIR::Ident.new("rt"), "heapAlloc", [], false),
      MIR::Ident.new("rt"),
      items_ptr,
      bounded_concurrent_worker_count_mir(conc_op),
      bounded_concurrent_parallel_mir(conc_op),
      bounded_concurrent_task_cfg_mir(conc_op),
      MIR::AddressOf.new(MIR::Ident.new(cb[:ctx_var])),
    ])

    label = next_pipe_label
    MIR::BlockExpr.new(label, [
      cb[:ctx_def],
      cb[:ctx_let],
      *setup_stmts,
      MIR::BreakStmt.new(label, call),
    ])
  end

  def lower_concurrent_bounded_each(lhs, conc_op, _inner)
    item_t = lhs.type_info.stream_element_type
    cb = build_bounded_concurrent_callback(conc_op, item_t, :Void, :each)
    setup_stmts, items_ptr = bounded_stream_items_setup(lhs, cb[:id])

    call = @lowering.send(:emit_builtin, :concurrentBoundedEach, [
      MIR::Ident.new(item_t.zig_type),
      MIR::Lit.new(lhs.type_info.stream_capacity.to_s),
      MIR::Ident.new("#{cb[:ctx_name]}.apply"),
      MIR::Ident.new("rt"),
      items_ptr,
      bounded_concurrent_worker_count_mir(conc_op),
      bounded_concurrent_parallel_mir(conc_op),
      bounded_concurrent_task_cfg_mir(conc_op),
      MIR::AddressOf.new(MIR::Ident.new(cb[:ctx_var])),
    ])

    MIR::ScopeBlock.new([
      cb[:ctx_def],
      cb[:ctx_let],
      *setup_stmts,
      MIR::ExprStmt.new(call, false),
    ])
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
