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
    # Named pipeline bindings: "@u" -> "__pipe_u" (persist across stages, cleared per-chain)
    @named_bindings = {}
  end

  def current_tp_ctx; @transpiler_context_stack.last; end

  # Compute the Zig variable name for a CLEAR named pipeline binding.
  # "@u" -> "__pipe_u", "@order" -> "__pipe_order"
  def pipe_binding_zig_name(clear_name)
    "__pipe_#{clear_name.delete_prefix('@')}"
  end

  # Conditional version of with_named_binding: registers the binding only
  # if a name is provided, otherwise just calls the block. Used at the
  # CONCURRENT lowering site where `list AS @u s> ...` provides a name
  # but plain `list s> ...` does not.
  def with_optional_named_binding(clear_name, zig_var, &blk)
    return blk.call if clear_name.nil?
    with_named_binding(clear_name, zig_var, &blk)
  end

  # Register a named pipeline binding for the duration of a block.
  # Saves and restores previous value so nested bindings stack correctly.
  def with_named_binding(clear_name, zig_var, &blk)
    prev = @named_bindings[clear_name]
    @named_bindings[clear_name] = zig_var
    blk.call
  ensure
    if prev.nil?
      @named_bindings.delete(clear_name)
    else
      @named_bindings[clear_name] = prev
    end
  end

  # Delegate fiber capture map management to MIRLowering
  def with_fiber_capture_map(new_entries, capture_symbols: nil, rt_override: "__rt", &blk)
    @lowering.with_fiber_capture_map(new_entries, capture_symbols: capture_symbols, rt_override: rt_override, &blk)
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

    # Named pipeline binding: @u -> registered Zig var (e.g. "__pipe_u")
    if node.is_a?(AST::Identifier) && !@named_bindings.empty? && @named_bindings.key?(node.name)
      return @named_bindings[node.name]
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
    return node unless @placeholder_name || @acc_placeholder || @join_param_map || @soa_each_mode || !@named_bindings.empty?

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
      elsif !@named_bindings.empty? && (zig_var = @named_bindings[node.name])
        new_id = AST::Identifier.new(node.token, zig_var)
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
    when AST::StructLit
      new_fields = node.fields.transform_values { |v| substitute_placeholders(v) }
      if new_fields != node.fields
        new_sl = AST::StructLit.new(node.token, node.name, new_fields, node.storage, node.type_args)
        copy_type_info(node, new_sl)
        return new_sl
      end
    when AST::HashLit
      new_pairs = node.pairs.transform_values { |v| substitute_placeholders(v) }
      if new_pairs != node.pairs
        new_hl = AST::HashLit.new(node.token, new_pairs, node.storage)
        copy_type_info(node, new_hl)
        return new_hl
      end
    when AST::Assert
      new_cond = substitute_placeholders(node.condition)
      if new_cond != node.condition
        new_assert = AST::Assert.new(node.token, new_cond, node.message)
        copy_type_info(node, new_assert)
        return new_assert
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
    # string generator is strictly better (no materialization overhead) on
    # the Zig backend. The VM has no SoA layout (Value.List is uniform), so
    # in BC mode, treat the SoA source as a regular list and dispatch through
    # the structural fold path. This keeps both backends going through MIR
    # nodes the bc_emitter can compile.
    is_soa = lhs_type&.soa? && (lhs_type&.pool? || lhs_type&.list_collection? || lhs_type&.fixed_soa?)
    scalar_op = RANGE_FOLD_OPS.any? { |t| rhs.is_a?(t) }
    return nil if is_soa && scalar_op && @lowering.instance_variable_get(:@target) != :bc

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

    # Binding-unnest chain: source AS @u s> UNNEST expr [AS @o] s> [stages] s> fold
    # Must be fused into nested loops - materializing UNNEST would lose the @u context.
    if (bchain = unwrap_binding_unnest_chain(node))
      return lower_binding_chain(bchain, node)
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
    when AST::WindowOp       then lower_window(lhs, rhs, node)
    when AST::BatchWindowOp
      # Zig keeps the legacy template (battle-tested, has time-based
      # semantics via CheatLib.BatchWindow). BC has no equivalent runtime
      # type, so route to a structural slice-based lowering on BC only.
      if @lowering.instance_variable_get(:@target) == :bc
        lower_batch_window(lhs, rhs, node)
      else
        nil
      end
    when AST::OrderByOp      then lower_order_by(lhs, rhs, node)
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
    # In BC mode the VM has no SoA layout; treat @soa lists as regular lists
    # so the structural ItemsAccess path below applies uniformly.
    bc_mode = @lowering.instance_variable_get(:@target) == :bc
    if lhs_type&.pool? && lhs_type&.sharded?
      [build_mat_sharded_pool(lhs_type), "pipe_items"]
    elsif lhs_type&.pool? && lhs_type&.soa? && !bc_mode
      [build_mat_soa_pool(lhs_type), "pipe_items"]
    elsif lhs_type&.pool? && !bc_mode
      [build_mat_pool(lhs_type), "pipe_items"]
    elsif (lhs_type&.list_collection? || lhs_type&.fixed_soa?) && lhs_type&.soa? && !bc_mode
      [build_mat_soa_list(lhs_type), "pipe_items"]
    elsif lhs_type&.list_collection? && lhs_type&.sharded? && !bc_mode
      [build_mat_sharded_list(lhs_type), "pipe_items"]
    elsif lhs_type&.set_collection?
      [build_mat_set(lhs_type), "pipe_items"]
    else
      # Plain array/list: structural ItemsAccess(safe: true) emits the same
      # comptime hasField pattern (with [0..] slice coercion in the else
      # branch). Resolves to identity in the VM since Value.List has no
      # ArrayList/raw-slice distinction.
      init = MIR::ItemsAccess.new(MIR::Ident.new("pipe_src_list"), true)
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
    # Use a structural MIR node so both backends can dispatch. The Zig
    # backend's ContainerInit emitter produces `@as(std.ArrayListUnmanaged(T),
    # .empty)` for :list_empty + this zig_type prefix, matching what the
    # legacy InlineZig string used to produce. The VM's bc_emitter compiles
    # ContainerInit :list_empty to LOAD_CONST [:empty_list], giving it a real
    # Value.List to grow via list-push.
    var_decl = MIR::Let.new("pipe_mat",
      MIR::ContainerInit.new("std.ArrayListUnmanaged(#{elem_zig})",
        :list_empty, :heap, nil),
      true, nil, nil)
    defer = MIR::DeferStmt.new(
      MIR::MethodCall.new(MIR::Ident.new("pipe_mat"), "deinit",
        [MIR::AllocatorRef.new(:heap)], false)
    )
    [var_decl, defer]
  end

  # Common: const pipe_items = pipe_mat.items;
  def mat_items_let
    MIR::Let.new("pipe_items", MIR::FieldGet.new(MIR::Ident.new("pipe_mat"), "items"), false, nil, nil)
  end

  # try pipe_mat.append(rt.heapAlloc(), value_expr)
  def mat_append(value_expr)
    MIR::ExprStmt.new(
      MIR::MethodCall.new(MIR::Ident.new("pipe_mat"), "append",
        [MIR::AllocatorRef.new(:heap), value_expr], true), false)
  end

  # try pipe_mat.appendSlice(rt.heapAlloc(), slice_expr)
  def mat_append_slice(slice_expr)
    MIR::ExprStmt.new(
      MIR::MethodCall.new(MIR::Ident.new("pipe_mat"), "appendSlice",
        [MIR::AllocatorRef.new(:heap), slice_expr], true), false)
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
      MIR::IterRange.new(MIR::Lit.new("0"), MIR::Lit.new(n.to_s)), "__psi", [inner_loop], nil)

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
      MIR::IterRange.new(MIR::Lit.new("0"), MIR::Cast.new(MIR::ListLength.new(MIR::FieldGet.new(MIR::Ident.new("pipe_src_list"), "data")), "usize", :intCast)),
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

  # Set: materialize keys into a temp slice via keyIterator (deref ?*T pointers).
  def build_mat_set(lhs_type)
    elem_zig = lhs_type.element_type.zig_type
    var_decl, defer = mat_var_and_defer(elem_zig)

    iter_let = MIR::Let.new("__skit",
      MIR::MethodCall.new(MIR::Ident.new("pipe_src_list"), "keyIterator", [], false),
      true, nil, nil)
    deref = MIR::FieldGet.new(MIR::Ident.new("__skptr"), "*")
    loop_node = MIR::WhileStmt.new(
      MIR::MethodCall.new(MIR::Ident.new("__skit"), "next", [], false),
      [mat_append(deref)],
      "__skptr", nil)

    [var_decl, defer, iter_let, loop_node, mat_items_let]
  end

  # SOA list: iterate data.len, append data.get(i).
  def build_mat_soa_list(lhs_type)
    elem_zig = lhs_type.element_type.zig_type
    var_decl, defer = mat_var_and_defer(elem_zig)

    value_expr = MIR::MethodCall.new(
      MIR::FieldGet.new(MIR::Ident.new("pipe_src_list"), "data"),
      "get", [MIR::Ident.new("__psi")], false)

    loop_node = MIR::ForStmt.new(
      MIR::IterRange.new(MIR::Lit.new("0"), MIR::Cast.new(MIR::ListLength.new(MIR::FieldGet.new(MIR::Ident.new("pipe_src_list"), "data")), "usize", :intCast)),
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
      MIR::IterRange.new(MIR::Lit.new("0"), MIR::Lit.new(n.to_s)), "__psi",
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
        MIR::IfStmt.new(
          MIR::BinOp.new("==",
            MIR::FieldGet.new(MIR::Ident.new(items), "len"),
            MIR::Lit.new("0")),
          [MIR::Panic.new("MIN applied to empty list")],
          nil),
        MIR::Let.new("min_result", MIR::TypeSentinel.new(:max, "f64"),
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
        MIR::IfStmt.new(
          MIR::BinOp.new("==",
            MIR::FieldGet.new(MIR::Ident.new(items), "len"),
            MIR::Lit.new("0")),
          [MIR::Panic.new("MAX applied to empty list")],
          nil),
        MIR::Let.new("max_result", MIR::TypeSentinel.new(:min, "f64"),
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
          MIR::Undef.new(nil), true, elem_zig_type, nil),
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
              [MIR::AllocatorRef.new(alloc), MIR::Ident.new("it")], true), nil)
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
            [MIR::AllocatorRef.new(alloc), MIR::Ident.new("val")], true), nil)
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
          MIR::Call.new("@min", [MIR::Ident.new("lim_requested"),
                                 MIR::ListLength.new(MIR::Ident.new(items))], false),
          false, nil, nil),
        MIR::BreakStmt.new(label,
          MIR::Call.new("CheatLib.makeList",
            [MIR::Ident.new(elem_zig), MIR::AllocatorRef.new(alloc),
             MIR::SliceExpr.new(MIR::Ident.new(items),
               MIR::Lit.new("0"), MIR::Ident.new("lim_actual"), nil)],
            true))
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
            [MIR::AllocatorRef.new(alloc), MIR::Ident.new("it")], true), nil)
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
        MIR::ItemsAccess.new(MIR::Ident.new("__skip_src"), true), false, nil, nil),
      MIR::Let.new("skip_requested",
        MIR::Cast.new(count_mir, "usize", :intCast), false, nil, nil),
      MIR::Let.new("skip_actual",
        MIR::Call.new("@min", [MIR::Ident.new("skip_requested"),
                               MIR::ListLength.new(MIR::Ident.new("__skip_items"))], false),
        false, nil, nil),
      MIR::BreakStmt.new(label,
        MIR::SliceExpr.new(MIR::Ident.new("__skip_items"),
                           MIR::Ident.new("skip_actual"), nil, nil))
    ])
  end

  def lower_distinct(list_node, distinct_node, smooth_node)
    # smooth_node.full_type is T[]@set; element_type gives the key type T.
    elem_zig = transpile_type(smooth_node.full_type.element_type.resolved.to_s)
    set_zig  = "CheatLib.Set(#{elem_zig})"
    alloc    = :heap  # Set.insert/deinit always use heap (HashMap needs real allocator)
    expr_mir = visit_pipeline_expr_mir(list_node, distinct_node.expression)

    # Use unwrap_range_chain to detect stream sources: list_node may be a SMOOTH
    # chain (e.g. counter s> LIMIT 9) whose annotated full_type is already a
    # materialized list, so checking lhs_ti.dynamic_stream? is insufficient.
    range_chain = unwrap_range_chain(list_node)
    if range_chain

      p = build_lazy_range_prefix(range_chain[:source], range_chain[:stages])
      item_var     = p[:item_var]
      range_next   = MIR::MethodCall.new(MIR::Ident.new(p[:source_name]), p[:next_method], [], true)
      key_expr_mir = with_pipeline_context(placeholder: item_var) { visit_mir(distinct_node.expression) }
      label        = next_pipe_label

      source_ti    = range_chain[:source].type_info
      defer_deinit = source_ti&.bounded_stream? ?
        MIR::DeferStmt.new(MIR::MethodCall.new(MIR::Ident.new(p[:source_name]), "deinit", [], false)) :
        nil

      return MIR::BlockExpr.new(label, [
        *([p[:range_let]].compact), *p[:outer_stmts],
        MIR::Let.new("dist_set", MIR::ContainerInit.new(set_zig, :set_empty, nil, nil), true, nil, nil),
        *([defer_deinit].compact),
        MIR::WhileStmt.new(range_next,
          [*p[:stage_stmts],
           MIR::Let.new("dist_key", key_expr_mir, false, nil, nil),
           MIR::ExprStmt.new(MIR::MethodCall.new(
             MIR::Ident.new("dist_set"), "insert",
             [MIR::AllocatorRef.new(alloc),
              MIR::Ident.new("dist_key")], true), nil)],
          p[:initial_capture], nil, nil, nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("dist_set"))
      ])
    end

    lower_pipeline_block(list_node) do |items, label|
      [
        MIR::Let.new("dist_set", MIR::ContainerInit.new(set_zig, :set_empty, nil, nil), true, nil, nil),
        MIR::ForStmt.new(MIR::Ident.new(items), "it", [
          MIR::Let.new("dist_key", expr_mir, false, nil, nil),
          MIR::ExprStmt.new(MIR::MethodCall.new(
            MIR::Ident.new("dist_set"), "insert",
            [MIR::AllocatorRef.new(alloc),
             MIR::Ident.new("dist_key")], true), nil)
        ], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("dist_set"))
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
            MIR::ItemsAccess.new(MIR::Ident.new("unn_inner"), true), false, nil, nil),
          MIR::ForStmt.new(MIR::Ident.new("unn_inner_items"), "inner_it", [
            MIR::ExprStmt.new(MIR::MethodCall.new(
              MIR::Ident.new("res_list"), "append",
              [MIR::AllocatorRef.new(alloc), MIR::Ident.new("inner_it")], true), nil)
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
                    MIR::SliceExpr.new(MIR::Ident.new(items),
                      MIR::Ident.new("__wi"),
                      MIR::BinOp.new("+", MIR::Ident.new("__wi"), MIR::Ident.new("__w_size")),
                      nil),
                    false, nil, nil),
                  MIR::Let.new("val", expr_mir, false, nil, nil),
                  MIR::ExprStmt.new(MIR::MethodCall.new(
                    MIR::Ident.new("res_list"), "append",
                    [MIR::AllocatorRef.new(alloc), MIR::Ident.new("val")],
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

  # WINDOW(size: N [, time: 'Xs']) batch/tumbling window:
  # accumulate items into a batch, fire `expr(batch)` whenever the
  # batch reaches `size`, and flush a final partial batch at end.
  # Time-only / size+time semantics: the BC backend is synchronous, so
  # there is no time-based mid-stream flush; the final flush captures
  # any accumulated tail. Tests using time-only windows (e.g. test 7
  # of 243_batch_window) rely on the final flush for a single batch.
  def lower_batch_window(list_node, bw_node, smooth_node)
    expr_type_str = (bw_node.expression.full_type || bw_node.expression.resolved_type).to_s
    res_zig = transpile_type(expr_type_str)

    lhs_type = list_node.type_info
    elem_type = if lhs_type&.open_stream? || lhs_type&.dynamic_stream?
      (lhs_type.open_stream? ? lhs_type.open_stream_element_type : lhs_type.tense_type.element_type).resolved
    elsif lhs_type&.inf_stream?
      lhs_type.inf_stream_element_type.resolved
    elsif lhs_type&.bounded_stream?
      lhs_type.stream_element_type.resolved
    else
      lhs_type.element_type.resolved
    end
    elem_zig = transpile_type(elem_type.to_s)
    alloc = pipeline_alloc(smooth_node)

    # Keep size as i64 for the in-loop counter comparison; cast to
    # usize only at the @intCast wrapper if a Zig caller needs it.
    size_mir = bw_node.options["size"] ? visit_mir(bw_node.options["size"]) : MIR::Lit.new("0")

    placeholder_var = "__bw_batch"
    expr_mir = with_pipeline_context(placeholder: placeholder_var) {
      visit_mir(bw_node.expression)
    }

    # BC-only structural lowering: walk an offset into the materialized
    # `pipe_items` list and on each step, slice [offset, offset+size]
    # into the placeholder, run the user expr, append the result.
    # In BC, the lower_pipeline_block materialization path produces a
    # Value.List for all source shapes (lists, ranges, BG STREAM via
    # eager materialization), so slicing works uniformly.
    lower_pipeline_block(list_node) do |items, label|
      [
        MIR::Let.new("res_list",
          MIR::MakeList.new(res_zig, [], alloc), true, nil, nil),
        MIR::Let.new("__bw_size", size_mir, false, "i64", nil),
        MIR::Let.new("__bw_total",
          MIR::Cast.new(
            MIR::FieldGet.new(MIR::Ident.new(items), "len"),
            "i64", :intCast),
          false, "i64", nil),
        # If size <= 0 (time-only), treat the whole list as one batch by
        # bumping size to total. The final-flush logic isn't needed: the
        # while loop emits the single full batch.
        MIR::Let.new("__bw_step",
          MIR::Conditional.new(
            MIR::BinOp.new(">", MIR::Ident.new("__bw_size"), MIR::Lit.new("0")),
            MIR::Ident.new("__bw_size"),
            MIR::Ident.new("__bw_total")),
          false, "i64", nil),
        MIR::Let.new("__bw_offset", MIR::Lit.new("0"), true, "i64", nil),
        MIR::WhileStmt.new(
          MIR::BinOp.new("<", MIR::Ident.new("__bw_offset"), MIR::Ident.new("__bw_total")),
          [
            MIR::Let.new("__bw_end",
              MIR::Conditional.new(
                MIR::BinOp.new("<",
                  MIR::BinOp.new("+", MIR::Ident.new("__bw_offset"), MIR::Ident.new("__bw_step")),
                  MIR::Ident.new("__bw_total")),
                MIR::BinOp.new("+", MIR::Ident.new("__bw_offset"), MIR::Ident.new("__bw_step")),
                MIR::Ident.new("__bw_total")),
              false, "i64", nil),
            MIR::Let.new(placeholder_var,
              MIR::SliceExpr.new(MIR::Ident.new(items),
                MIR::Cast.new(MIR::Ident.new("__bw_offset"), "usize", :intCast),
                MIR::Cast.new(MIR::Ident.new("__bw_end"), "usize", :intCast),
                nil),
              false, nil, nil),
            MIR::Let.new("__bw_val", expr_mir, false, nil, nil),
            MIR::ExprStmt.new(MIR::MethodCall.new(
              MIR::Ident.new("res_list"), "append",
              [MIR::AllocatorRef.new(alloc), MIR::Ident.new("__bw_val")],
              true), nil),
            MIR::Set.new(MIR::Ident.new("__bw_offset"),
              MIR::Ident.new("__bw_end")),
          ], nil, nil, nil, nil),
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
          MIR::Call.new("CheatLib.makeList",
            [MIR::Ident.new(elem_zig), MIR::AllocatorRef.new(alloc), MIR::Ident.new(items)],
            true), true, nil, "_ = &ord_result;"),
        MIR::Sort.new(elem_zig,
          MIR::FieldGet.new(MIR::Ident.new("ord_result"), "items"),
          key_a, key_b),
        MIR::BreakStmt.new(label, MIR::Ident.new("ord_result"))
      ]
    end
  end

  def lower_index(list_node, expr_node, smooth_node)
    lhs_ti = list_node.type_info
    alloc = pipeline_alloc(smooth_node)

    # Stream source: use lazy while loop instead of materializing first.
    if (range_chain = unwrap_range_chain(list_node))
      elem_sym = if lhs_ti&.open_stream?
        lhs_ti.open_stream_element_type.resolved
      elsif lhs_ti&.dynamic_stream? || lhs_ti&.bounded_stream?
        lhs_ti.tense_type.element_type.resolved
      elsif range_chain[:source].type_info&.inf_stream?
        # list_node is a SMOOTH chain (e.g. counter s> LIMIT 9); lhs_ti is the
        # materialized list type so tense_type is unavailable. Pull element type
        # from the inf stream source directly.
        range_chain[:source].type_info.inf_stream_element_type.resolved
      else
        list_node.full_type.element_type.resolved
      end
      elem_zig = transpile_type(elem_sym.to_s)
      map_type = "CheatLib.StringMap(std.ArrayListUnmanaged(#{elem_zig}))"
      return lower_stream_index(range_chain, expr_node, elem_zig, alloc, map_type)
    end

    elem_zig = transpile_type(list_node.full_type.element_type.resolved.to_s)
    expr_mir = visit_pipeline_expr_mir(list_node, expr_node)
    map_type = "CheatLib.StringMap(std.ArrayListUnmanaged(#{elem_zig}))"
    lower_pipeline_block(list_node) do |items, label|
      [
        MIR::Let.new("idx_result",
          MIR::StructInit.new(nil, [{name: "alloc", value: MIR::AllocatorRef.new(alloc)}]),
          true, map_type, nil),
        MIR::ForStmt.new(MIR::Ident.new(items), "it", build_index_gop_body(expr_mir, alloc, "it"), nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("idx_result"))
      ]
    end
  end

  # INDEX op: append item to map[key] bucket, creating the bucket if missing.
  # Lowered to MIR::IndexInsert which both backends decompose: Zig emits the
  # getOrPut + dupe/free + value_ptr.append idiom; the VM emits MAP_GET +
  # APPEND/MAKE_LIST + MAP_PUT.
  def build_index_gop_body(expr_mir, alloc, item_var)
    elem_zig_type = "@TypeOf(#{item_var})"
    [
      MIR::Let.new("idx_key", expr_mir, false, nil, nil),
      MIR::IndexInsert.new(
        MIR::Ident.new("idx_result"),
        MIR::Ident.new("idx_key"),
        MIR::Ident.new(item_var),
        "u8", elem_zig_type, alloc)
    ]
  end

  def lower_stream_index(range_chain, expr_node, elem_zig, alloc, map_type)
    # Filtered-out items must have their heap sub-fields freed; comptime no-op
    # for primitives. CheatLib.cleanup takes a comptime Type as its first arg;
    # we encode it as MIR::Ident(zig_type_str), matching mir_lowering's other
    # CheatLib.cleanup call sites (lower_field_assignment_with_cleanup).
    on_skip = ->(var) {
      [MIR::ExprStmt.new(
        MIR::Call.new("CheatLib.cleanup", [
          MIR::Ident.new(elem_zig),
          MIR::Ident.new(HEAP_ALLOC),
          MIR::AddressOf.new(MIR::Ident.new(var))
        ], false), nil)]
    }
    p = build_lazy_range_prefix(range_chain[:source], range_chain[:stages], on_skip: on_skip)
    item_var   = p[:item_var]
    range_next = MIR::MethodCall.new(MIR::Ident.new(p[:source_name]), p[:next_method], [], true)

    expr_mir = with_pipeline_context(placeholder: item_var) { visit_mir(expr_node) }
    label    = next_pipe_label

    source_ti    = range_chain[:source].type_info
    defer_deinit = source_ti&.bounded_stream? ?
      MIR::DeferStmt.new(MIR::MethodCall.new(MIR::Ident.new(p[:source_name]), "deinit", [], false)) :
      nil

    if bc_target?
      iter = if range_chain[:source].is_a?(AST::RangeLit)
               start_mir = visit_mir(range_chain[:source].start)
               end_mir   = visit_mir(range_chain[:source].finish)
               end_expr  = range_chain[:source].inclusive ?
                 MIR::BinOp.new("+", end_mir, MIR::Lit.new("1")) : end_mir
               MIR::IterRange.new(start_mir, end_expr)
             elsif range_chain[:source].is_a?(AST::Identifier)
               visit_mir(range_chain[:source])
             else
               nil
             end
      if iter
        return MIR::BlockExpr.new(label, [
          *p[:outer_stmts],
          MIR::Let.new("idx_result",
            MIR::StructInit.new(nil, [{name: "alloc", value: MIR::AllocatorRef.new(:heap)}]),
            true, map_type, nil),
          MIR::ForStmt.new(iter, p[:initial_capture], [
            *p[:stage_stmts],
            *build_index_gop_body(expr_mir, :heap, item_var)
          ], nil),
          MIR::BreakStmt.new(label, MIR::Ident.new("idx_result"))
        ])
      end
    end

    MIR::BlockExpr.new(label, [
      *([p[:range_let]].compact), *p[:outer_stmts],
      MIR::Let.new("idx_result",
        MIR::StructInit.new(nil, [{name: "alloc", value: MIR::AllocatorRef.new(:heap)}]),
        true, map_type, nil),
      *([defer_deinit].compact),
      MIR::WhileStmt.new(range_next, [
        *p[:stage_stmts],
        *build_index_gop_body(expr_mir, :heap, item_var)
      ], p[:initial_capture], nil, nil, nil),
      MIR::BreakStmt.new(label, MIR::Ident.new("idx_result"))
    ])
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
        MIR::ItemsAccess.new(MIR::Ident.new("__jl_src"), true), false, nil, nil),
      MIR::Let.new("__jr_items",
        MIR::ItemsAccess.new(MIR::Ident.new("__jr_src"), true), false, nil, nil),
      MIR::Let.new("res_list",
        MIR::ContainerInit.new("std.ArrayListUnmanaged(#{result_zig})",
          :list_empty, alloc, nil), true, nil, nil),
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
          [MIR::AllocatorRef.new(alloc),
           MIR::StructInit.new(nil, [
             {name: "left",  value: MIR::Ident.new("__jl")},
             {name: "right", value: MIR::Ident.new("__match")}])],
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
        MIR::ItemsAccess.new(MIR::Ident.new("__tap_src"), true), false, nil, nil),
      MIR::ForStmt.new(MIR::Ident.new("__tap_items"), "__tap_item", body_mir, nil),
      MIR::BreakStmt.new(label, MIR::Ident.new("__tap_src"))
    ])
  end

  # --- Side-effect operator lowerings (Phase 4) ---

  def lower_each(list_node, each_op, smooth_node)
    lhs_type = list_node.type_info

    # Sharded pools/lists need fibers on the Zig backend (one per shard) --
    # stay on the string path there. For BC the sharded structure is
    # flattened to a Value.List at runtime, so the regular per-item
    # ForStmt path below works for both sharded pools and sharded lists.
    return nil if lhs_type&.sharded? && !bc_target?

    # In BC mode the VM has no SoA layout, so the field-slice optimization
    # has no benefit. Skip the SoaFieldAccess emission and let the regular
    # per-item ForStmt path below handle iteration uniformly.
    is_soa = lhs_type&.soa? && (lhs_type&.pool? || lhs_type&.list_collection? || lhs_type&.fixed_soa?) &&
             @lowering.instance_variable_get(:@target) != :bc

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
          MIR::SoaFieldAccess.new(MIR::Ident.new("__soa_src"), f),
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
          MIR::IterRange.new(MIR::Lit.new("0"), MIR::Cast.new(MIR::ListLength.new(MIR::FieldGet.new(MIR::Ident.new("__soa_src"), "data")), "usize", :intCast)),
          "__soa_i",
          [*alive_guard, *body_mir],
          nil)
      ])
    end

    # Non-SOA pool: iterate slots with alive check
    if lhs_type&.pool?
      source_mir = visit_mir(list_node)
      body_mir = visit_pipeline_body_mir(each_op.body, placeholder: "__each_item")
      # BC backend models pools as plain lists with Nil holes for removed
      # slots. Iterate by index, skip Nil entries (alive check), and
      # write back the mutated item to support field-mutation semantics.
      if bc_target? && list_node.is_a?(AST::Identifier)
        @each_idx_counter = (@each_idx_counter || 0) + 1
        idx_name = "__each_i_#{@each_idx_counter}"
        src_ident = MIR::Ident.new(list_node.name.to_s)
        return MIR::ForStmt.new(
          MIR::IterRange.new(MIR::Lit.new("0"), MIR::ListLength.new(src_ident)),
          idx_name,
          [
            MIR::Let.new("__each_item",
              MIR::IndexGet.new(src_ident, MIR::Ident.new(idx_name)),
              true, nil, nil),
            MIR::IfStmt.new(
              MIR::BinOp.new("==", MIR::Ident.new("__each_item"), MIR::Lit.new("nil")),
              [MIR::ContinueStmt.new(nil)], nil),
            *body_mir,
            MIR::Set.new(
              MIR::IndexGet.new(src_ident, MIR::Ident.new(idx_name)),
              MIR::Ident.new("__each_item"))
          ],
          nil)
      end
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
    # pull iteration via .next(). The BC backend has no LazyRange / .next()
    # protocol; it iterates ranges via IterRange instead, so a plain RangeLit
    # without fusible stages falls through to the structural ForStmt path
    # below. With stages we still go through lower_each_range so the
    # fusion pipeline (SELECT/WHERE/LIMIT/...) can be expressed; the BC
    # emitter handles the resulting next() loop by materializing the range.
    range_chain = unwrap_range_chain(list_node)
    is_bc = (@lowering.instance_variable_get(:@target) == :bc)
    if range_chain && !(is_bc && list_node.is_a?(AST::RangeLit) && range_chain[:stages].empty?)
      return lower_each_range(range_chain[:source], range_chain[:stages], each_op)
    end

    # Non-SOA list collection or fixed_soa: iterate items
    if lhs_type&.list_collection? || lhs_type&.fixed_soa?
      source_mir = visit_mir(list_node)
      body_mir = visit_pipeline_body_mir(each_op.body, placeholder: "__each_item")
      # BC backend: in Zig, `for (items.items) |*item|` gives a pointer
      # so field-writes propagate. The BC ForStmt iterates by-value, so
      # field mutations on __each_item never reach the underlying list.
      # Lower to an index loop with an explicit writeback when the source
      # is a known list-bound Identifier (the common case: `xs s> EACH`).
      # BC backend: in Zig, `for (items.items) |*item|` gives a pointer
      # so field-writes propagate. The BC ForStmt iterates by-value, so
      # field mutations on __each_item never reach the underlying list.
      # Lower to an index loop with an explicit writeback when the source
      # is a known list-bound Identifier (the common case: `xs s> EACH`).
      # Use the original Identifier as the in-place target so the writeback
      # actually updates the user's binding (a fresh __each_src copy
      # wouldn't propagate the mutation back to `xs`).
      if bc_target? && list_node.is_a?(AST::Identifier)
        @each_idx_counter = (@each_idx_counter || 0) + 1
        idx_name = "__each_i_#{@each_idx_counter}"
        src_ident = MIR::Ident.new(list_node.name.to_s)
        return MIR::ForStmt.new(
          MIR::IterRange.new(MIR::Lit.new("0"), MIR::ListLength.new(src_ident)),
          idx_name,
          [
            MIR::Let.new("__each_item",
              MIR::IndexGet.new(src_ident, MIR::Ident.new(idx_name)),
              true, nil, nil),
            *body_mir,
            MIR::Set.new(
              MIR::IndexGet.new(src_ident, MIR::Ident.new(idx_name)),
              MIR::Ident.new("__each_item"))
          ],
          nil)
      end
      return MIR::ScopeBlock.new([
        MIR::Let.new("__each_src", source_mir, false, nil, nil),
        MIR::Let.new("__each_items",
          MIR::ItemsAccess.new(MIR::Ident.new("__each_src"), true), false, nil, nil),
        MIR::ForStmt.new(MIR::Ident.new("__each_items"), "__each_item", body_mir, nil)
      ])
    end

    # Set collection: iterate via keyIterator(); next() returns ?*T so deref in body.
    if lhs_type&.set_collection?
      source_mir = visit_mir(list_node)
      body_mir = visit_pipeline_body_mir(each_op.body, placeholder: "__each_item")
      return MIR::ScopeBlock.new([
        MIR::Let.new("__each_src", MIR::UnaryOp.new("&", source_mir), false, nil, nil),
        MIR::Let.new("__each_iter",
          MIR::MethodCall.new(MIR::Ident.new("__each_src"), "keyIterator", [], false),
          true, nil, nil),
        MIR::WhileStmt.new(
          MIR::MethodCall.new(MIR::Ident.new("__each_iter"), "next", [], false),
          [MIR::Let.new("__each_item", MIR::FieldGet.new(MIR::Ident.new("__each_kptr"), "*"), false, nil, nil),
           *body_mir],
          "__each_kptr", nil)
      ])
    end

    # Range source: zero-allocation lazy iteration via Zig's literal range
    # syntax inside ForStmt (`for (start..end) |item| { body }`). Equivalent
    # to the prior LazyRange(T).init + while(.next()) pattern -- LazyRange's
    # next() is just `current < end ? current++ : null` with no yield -- so
    # the structural ForStmt + IterRange compiles to the same loop in Zig
    # while giving the VM a backend-native iteration shape.
    if list_node.is_a?(AST::RangeLit)
      start_mir = visit_mir(list_node.start)
      end_mir   = visit_mir(list_node.finish)
      end_expr  = list_node.inclusive ?
        MIR::BinOp.new("+", end_mir, MIR::Lit.new("1")) : end_mir

      body_mir = visit_pipeline_body_mir(each_op.body, placeholder: "__each_item")

      # Use `_` as the for capture when the body doesn't reference the
      # element, to avoid Zig's "unused capture" error.
      capture_name = ast_stmts_use_placeholder?(each_op.body) ? "__each_item" : "_"

      return MIR::ForStmt.new(
        MIR::IterRange.new(start_mir, end_expr),
        capture_name, body_mir, nil)
    end

    nil  # Fall through to string path
  end

  def finite_stream_source_node?(node)
    node.is_a?(AST::RangeLit) || node.type_info&.dynamic_stream? ||
      node.type_info&.open_stream? ||
      node.type_info&.bounded_stream? || node.type_info&.inf_stream?
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

  # Detect a binding-unnest chain suitable for fused nested-loop generation:
  #   BIND_VAR(source, @u) s> [BIND_VAR(]UNNEST(expr)[, @o)] s> [WHERE/SELECT] s> fold
  #
  # Note: `UNNEST expr AS @o` parses as BIND_VAR(UnnestOp(expr), @o) because AS has
  # higher precedence than s>. Both `s> UNNEST expr` and `s> UNNEST expr AS @o` are handled.
  #
  # Returns a hash with the chain components, or nil if the pattern doesn't match.
  def unwrap_binding_unnest_chain(node)
    return nil unless node.is_a?(AST::BinaryOp) && node.op == :SMOOTH

    # Terminal must be a fold op
    fold = node.right
    return nil unless RANGE_FOLD_OPS.any? { |t| fold.is_a?(t) }
    cursor = node.left

    # Collect optional intermediate WHERE/SELECT stages (in chain order)
    stages = []
    while cursor.is_a?(AST::BinaryOp) && cursor.op == :SMOOTH
      rhs = cursor.right
      if rhs.is_a?(AST::WhereOp) || rhs.is_a?(AST::SelectOp)
        stages.unshift(rhs)
        cursor = cursor.left
      else
        break
      end
    end

    # cursor must now be: SMOOTH(BIND_VAR(source, @u), unnest_part)
    return nil unless cursor.is_a?(AST::BinaryOp) && cursor.op == :SMOOTH
    lhs = cursor.left
    rhs = cursor.right

    # Must be a UnnestOp
    return nil unless rhs.is_a?(AST::UnnestOp)

    # Detect optional inner binding: `UNNEST expr AS @o` parses as
    # UnnestOp(expression=BIND_VAR(expr, @o)) because :pipe_expression uses
    # parse_expression(1) which consumes AS at prec 2 as part of the inner expr.
    unnest_expr = rhs.expression
    inner_binding = nil
    if unnest_expr.is_a?(AST::BinaryOp) && unnest_expr.op == :BIND_VAR
      inner_binding = unnest_expr.right.name  # "@o"
      unnest_expr   = unnest_expr.left        # the actual array expression
    end

    # LHS must be a BIND_VAR (source AS @u)
    return nil unless lhs.is_a?(AST::BinaryOp) && lhs.op == :BIND_VAR

    {
      source:        lhs.left,
      outer_binding: lhs.right.name,  # "@u"
      unnest_expr:   unnest_expr,     # @u.orders (unwrapped from any BIND_VAR)
      inner_binding: inner_binding,   # "@o" or nil
      stages:        stages,
      fold:          fold
    }
  end

  # Generate fused nested loops for a binding-unnest chain.
  # Outer loop: source elements bound to @u (outer_zig).
  # Inner loop: unnest expression elements (inner_zig).
  # Both bindings are visible in stage expressions and the fold.
  def lower_binding_chain(chain, smooth_node)
    outer_name = chain[:outer_binding]          # "@u"
    outer_zig  = pipe_binding_zig_name(outer_name)  # "__pipe_u"
    inner_name = chain[:inner_binding]          # "@o" or nil
    inner_zig  = inner_name ? pipe_binding_zig_name(inner_name) : "__bc_inner"
    label      = next_pipe_label

    # BC backend's bc_emitter has a flat per-function slot table, so two
    # binding chains in the same function reusing __bc_acc would land on
    # the same slot with whichever residency was assigned first (e.g.
    # SUM allocates an f64 fslot, then ANY's :bool tries to STORE through
    # @slots and reads back stale f64). Suffix per pipeline so each chain
    # has its own slot. Mirrors the lower_range_fold suffix scheme.
    names = if bc_target?
      sfx = "_#{label.sub('__pblk', 'b')}"
      {
        src:    "__bc_src#{sfx}",
        unn:    "__bc_unn#{sfx}",
        acc:    "__bc_acc#{sfx}",
        sum:    "__bc_sum#{sfx}",
        cnt:    "__bc_cnt#{sfx}",
        val:    "__bc_val#{sfx}",
        result: "__bc_result#{sfx}",
        found:  "__bc_found#{sfx}",
      }
    else
      { src: "__bc_src", unn: "__bc_unn", acc: "__bc_acc",
        sum: "__bc_sum", cnt: "__bc_cnt", val: "__bc_val",
        result: "__bc_result", found: "__bc_found" }
    end

    with_named_binding(outer_name, outer_zig) do
      source_mir = visit_mir(chain[:source])
      unnest_mir = visit_mir(chain[:unnest_expr])  # @u already in @named_bindings

      inner_block = lambda do
        acc_init, loop_body, post_inner, result_expr = lower_binding_fold(
          chain[:fold], chain[:stages], inner_zig, smooth_node, names)

        # When inner_name is nil the capture is the generated __bc_inner which
        # the fold expression may not reference (e.g. ALL @u.discount > 0.0).
        # Detect actual usage by emitting the body to text and scanning for the
        # capture name, then suppress only if unused to avoid Zig errors.
        unless inner_name
          body_text = loop_body.map { |s| @emitter.emit(s).to_s }.join
          unless body_text.include?(inner_zig)
            # Structural unused-capture suppression: MIR::Suppress emits
            # `_ = &name;` which silences Zig's unused-capture error and
            # is a no-op the VM skips entirely.
            loop_body = [MIR::Suppress.new(inner_zig), *loop_body]
          end
        end

        inner_loop = MIR::ForStmt.new(
          MIR::ItemsAccess.new(MIR::Ident.new(names[:unn]), true),
          inner_zig, loop_body, nil)

        outer_loop = MIR::ForStmt.new(
          MIR::ItemsAccess.new(MIR::Ident.new(names[:src]), true),
          outer_zig,
          [
            MIR::Let.new(names[:unn], unnest_mir, false, nil, nil),
            inner_loop,
            *post_inner
          ],
          nil)

        MIR::BlockExpr.new(label, [
          MIR::Let.new(names[:src], source_mir, false, nil, nil),
          *acc_init,
          outer_loop,
          MIR::BreakStmt.new(label, result_expr)
        ])
      end

      if inner_name
        with_named_binding(inner_name, inner_zig) { inner_block.call }
      else
        inner_block.call
      end
    end
  end

  # Build accumulator init stmts, per-element body stmts, optional post-inner-loop
  # stmts, and result expr for a fold op inside a binding chain.
  # Returns [init_stmts, loop_body_stmts, post_inner_stmts, result_expr].
  # post_inner_stmts are placed in the OUTER loop after the inner for-loop.
  # placeholder is the Zig inner loop var name. smooth_node is the outer SMOOTH node.
  # names: hash of bc-suffixed binding names (acc, sum, cnt, val, result, found).
  def lower_binding_fold(fold, stages, placeholder, smooth_node = nil, names = nil)
    names ||= { acc: "__bc_acc", sum: "__bc_sum", cnt: "__bc_cnt",
                val: "__bc_val", result: "__bc_result", found: "__bc_found" }
    acc_n, sum_n, cnt_n, val_n, result_n, found_n =
      names[:acc], names[:sum], names[:cnt], names[:val], names[:result], names[:found]
    case fold
    when AST::SumOp
      expr = with_pipeline_context(placeholder: placeholder) { visit_mir(fold.expression) }
      init   = [MIR::Let.new(acc_n, MIR::Lit.new("0"), true, "f64", nil)]
      accum  = [MIR::Set.new(MIR::Ident.new(acc_n),
                  MIR::BinOp.new("+", MIR::Ident.new(acc_n), expr))]
      [init, bc_wrap_stages(stages, placeholder, accum), [], MIR::Ident.new(acc_n)]

    when AST::CountOp
      pred  = with_pipeline_context(placeholder: placeholder) { visit_mir(fold.expression) }
      init  = [MIR::Let.new(acc_n, MIR::Lit.new("0"), true, "i64", nil)]
      accum = [MIR::IfStmt.new(pred, [MIR::Set.new(MIR::Ident.new(acc_n),
                 MIR::BinOp.new("+", MIR::Ident.new(acc_n), MIR::Lit.new("1")))], nil)]
      [init, bc_wrap_stages(stages, placeholder, accum), [], MIR::Ident.new(acc_n)]

    when AST::AverageOp
      expr = with_pipeline_context(placeholder: placeholder) { visit_mir(fold.expression) }
      # Use f64 for count to avoid @floatFromInt in the division (same as the
      # non-binding-chain AVERAGE code path in PipelineGenerator).
      init = [MIR::Let.new(sum_n, MIR::Lit.new("0"), true, "f64", nil),
              MIR::Let.new(cnt_n, MIR::Lit.new("0.0"), true, "f64", nil)]
      accum = [MIR::Set.new(MIR::Ident.new(sum_n),
                 MIR::BinOp.new("+", MIR::Ident.new(sum_n), expr)),
               MIR::Set.new(MIR::Ident.new(cnt_n),
                 MIR::BinOp.new("+", MIR::Ident.new(cnt_n), MIR::Lit.new("1.0")))]
      result = MIR::Conditional.new(
        MIR::BinOp.new("==", MIR::Ident.new(cnt_n), MIR::Lit.new("0.0")),
        MIR::Cast.new(MIR::Lit.new("0"), "f64", :as),
        MIR::BinOp.new("/", MIR::Ident.new(sum_n), MIR::Ident.new(cnt_n)))
      [init, bc_wrap_stages(stages, placeholder, accum), [], result]

    when AST::MinOp
      expr = with_pipeline_context(placeholder: placeholder) { visit_mir(fold.expression) }
      init  = [MIR::Let.new(acc_n,
                 MIR::TypeSentinel.new(:max, "f64"), true, "f64", nil)]
      accum = [MIR::Let.new(val_n, expr, false, nil, nil),
               MIR::IfStmt.new(
                 MIR::BinOp.new("<", MIR::Ident.new(val_n), MIR::Ident.new(acc_n)),
                 [MIR::Set.new(MIR::Ident.new(acc_n), MIR::Ident.new(val_n))], nil)]
      [init, bc_wrap_stages(stages, placeholder, accum), [], MIR::Ident.new(acc_n)]

    when AST::MaxOp
      expr = with_pipeline_context(placeholder: placeholder) { visit_mir(fold.expression) }
      init  = [MIR::Let.new(acc_n,
                 MIR::TypeSentinel.new(:min, "f64"), true, "f64", nil)]
      accum = [MIR::Let.new(val_n, expr, false, nil, nil),
               MIR::IfStmt.new(
                 MIR::BinOp.new(">", MIR::Ident.new(val_n), MIR::Ident.new(acc_n)),
                 [MIR::Set.new(MIR::Ident.new(acc_n), MIR::Ident.new(val_n))], nil)]
      [init, bc_wrap_stages(stages, placeholder, accum), [], MIR::Ident.new(acc_n)]

    when AST::AnyOp
      pred  = with_pipeline_context(placeholder: placeholder) { visit_mir(fold.expression) }
      init  = [MIR::Let.new(acc_n, MIR::Lit.new("false"), true, nil, nil)]
      accum = [MIR::IfStmt.new(pred, [
                 MIR::Set.new(MIR::Ident.new(acc_n), MIR::Lit.new("true")),
                 MIR::BreakStmt.new(nil, nil)], nil)]
      [init, bc_wrap_stages(stages, placeholder, accum), [], MIR::Ident.new(acc_n)]

    when AST::AllOp
      pred  = with_pipeline_context(placeholder: placeholder) { visit_mir(fold.expression) }
      init  = [MIR::Let.new(acc_n, MIR::Lit.new("true"), true, nil, nil)]
      accum = [MIR::IfStmt.new(MIR::UnaryOp.new("!", pred), [
                 MIR::Set.new(MIR::Ident.new(acc_n), MIR::Lit.new("false")),
                 MIR::BreakStmt.new(nil, nil)], nil)]
      [init, bc_wrap_stages(stages, placeholder, accum), [], MIR::Ident.new(acc_n)]

    when AST::FindOp
      # Result type is ?InnerElemType; derive from smooth_node.full_type.
      result_ft = Type.new(smooth_node.full_type)
      find_zig  = result_ft.optional? ? transpile_type(result_ft.wrapped_type.resolved.to_s) : placeholder
      pred = with_pipeline_context(placeholder: placeholder) { visit_mir(fold.expression) }
      init = [MIR::Let.new(result_n, MIR::Undef.new(nil), true, find_zig, nil),
              MIR::Let.new(found_n, MIR::Lit.new("false"), true, nil, nil)]
      accum = [MIR::IfStmt.new(pred, [
                 MIR::Set.new(MIR::Ident.new(result_n), MIR::Ident.new(placeholder)),
                 MIR::Set.new(MIR::Ident.new(found_n), MIR::Lit.new("true")),
                 MIR::BreakStmt.new(nil, nil)
               ], nil)]
      # After the inner loop, break the outer loop too so the first match wins.
      post_inner = [MIR::IfStmt.new(MIR::Ident.new(found_n), [MIR::BreakStmt.new(nil, nil)], nil)]
      result = MIR::Conditional.new(
        MIR::Ident.new(found_n),
        MIR::Cast.new(MIR::Ident.new(result_n), "?#{find_zig}", :as),
        MIR::Lit.new("null"))
      [init, bc_wrap_stages(stages, placeholder, accum), post_inner, result]

    else
      raise "lower_binding_fold: unsupported fold op #{fold.class}"
    end
  end

  # Wrap accum_stmts with WHERE predicate guards from intermediate stages.
  # Stages are applied innermost-first (each WHERE wraps the inner body).
  def bc_wrap_stages(stages, placeholder, accum_stmts)
    body = accum_stmts
    stages.reverse_each do |stage|
      if stage.is_a?(AST::SelectOp)
        raise "SELECT is not supported in AS @v binding chains. " \
              "Use WHERE to filter or name the projection with AS @o before the fold."
      end
      next unless stage.is_a?(AST::WhereOp)
      pred = with_pipeline_context(placeholder: placeholder) { visit_mir(stage.expression) }
      body = [MIR::IfStmt.new(pred, body, nil)]
    end
    body
  end

  # Lower a fold expression and wrap in @as(f64, @floatFromInt(...)) if integer.
  # SUM/AVERAGE/MIN/MAX accumulators are f64; integer range elements need coercion.
  # Returns a proper MIR node -- no InlineZig string embedding.
  def numeric_fold_expr_f64(expr_ast, item_var)
    expr_mir = with_pipeline_context(placeholder: item_var) { visit_mir(expr_ast) }
    expr_type = expr_ast.respond_to?(:full_type) ? expr_ast.full_type : nil
    if expr_type && Type.new(expr_type).integer?
      # @as(f64, @floatFromInt(expr)) -- keeps MIR structure visible to checker
      MIR::Cast.new(MIR::Cast.new(expr_mir, nil, :floatFromInt), "f64", :as)
    else
      expr_mir
    end
  end

  # Like numeric_fold_expr_f64 but targets any accumulator type.
  # For float accumulators, converts integer expressions via @floatFromInt.
  # For integer accumulators, returns the expression as-is.
  def numeric_fold_expr_typed(expr_ast, item_var, acc_zig)
    expr_mir  = with_pipeline_context(placeholder: item_var) { visit_mir(expr_ast) }
    expr_type = expr_ast.respond_to?(:full_type) ? expr_ast.full_type : nil
    expr_is_int = expr_type && Type.new(expr_type).integer?
    acc_is_float = acc_zig == "f64" || acc_zig == "f32"
    if expr_is_int && acc_is_float
      MIR::Cast.new(MIR::Cast.new(expr_mir, nil, :floatFromInt), acc_zig, :as)
    else
      expr_mir
    end
  end

  # Build the LazyRange init + stage prefix shared by lower_each_range and lower_range_fold.
  # Returns a hash: { range_let, source_name, outer_stmts, stage_stmts, item_var, initial_capture,
  #                   item_used, elem_zig }
  # `item_used` tracks whether the initial capture (`__each_item`) is referenced
  # by any stage -- used by callers to decide between |__each_item| and |_| in Zig.
  def build_lazy_range_prefix(source_node, stages, on_skip: nil)
    source_ti = source_node.type_info
    elem_t = if source_ti&.open_stream?
      source_ti.open_stream_element_type
    elsif source_ti&.dynamic_stream? || source_ti&.bounded_stream?
      source_ti.tense_type.element_type
    elsif source_ti&.inf_stream?
      source_ti.inf_stream_element_type
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
        skip_stmts = on_skip ? [*on_skip.call(item_var), MIR::ContinueStmt.new(nil)] : [MIR::ContinueStmt.new(nil)]
        stage_stmts << MIR::IfStmt.new(MIR::UnaryOp.new("!", pred_mir), skip_stmts, nil)

      when AST::TakeWhileOp
        item_used = true if item_var == initial_capture
        pred_mir  = with_pipeline_context(placeholder: item_var) { visit_mir(stage.expression) }
        skip_stmts = on_skip ? [*on_skip.call(item_var), MIR::BreakStmt.new(nil, nil)] : [MIR::BreakStmt.new(nil, nil)]
        stage_stmts << MIR::IfStmt.new(MIR::UnaryOp.new("!", pred_mir), skip_stmts, nil)

      when AST::LimitOp
        item_counter += 1
        cvar     = "__limit_cnt_#{item_counter}"
        cnt_var  = "__limit_max_#{item_counter}"
        cnt_mir  = visit_mir(stage.count)
        # Counter and bound live outside the loop; bound is immutable.
        outer_stmts << MIR::Let.new(cvar, MIR::Cast.new(MIR::Lit.new("0"), "i64", :as), true, nil, nil)
        outer_stmts << MIR::Let.new(cnt_var, cnt_mir, false, nil, nil)
        # Inside loop: if cvar >= cnt_var -> break; then increment.
        stage_stmts << MIR::IfStmt.new(
          MIR::BinOp.new(">=", MIR::Ident.new(cvar), MIR::Ident.new(cnt_var)),
          [MIR::BreakStmt.new(nil, nil)], nil)
        stage_stmts << MIR::Set.new(
          MIR::Ident.new(cvar), MIR::BinOp.new("+", MIR::Ident.new(cvar), MIR::Lit.new("1")))

      when AST::SkipOp
        item_counter += 1
        cvar     = "__skip_cnt_#{item_counter}"
        cnt_var  = "__skip_max_#{item_counter}"
        cnt_mir  = visit_mir(stage.count)
        outer_stmts << MIR::Let.new(cvar, MIR::Cast.new(MIR::Lit.new("0"), "i64", :as), true, nil, nil)
        outer_stmts << MIR::Let.new(cnt_var, cnt_mir, false, nil, nil)
        # Inside loop: if cvar < cnt_var -> increment counter and skip.
        stage_stmts << MIR::IfStmt.new(
          MIR::BinOp.new("<", MIR::Ident.new(cvar), MIR::Ident.new(cnt_var)),
          [MIR::Set.new(MIR::Ident.new(cvar),
             MIR::BinOp.new("+", MIR::Ident.new(cvar), MIR::Lit.new("1"))),
           MIR::ContinueStmt.new(nil)], nil)

      when AST::TapOp
        item_used = true if item_var == initial_capture
        stage_stmts.concat(visit_pipeline_body_mir(stage.body, placeholder: item_var))
      end
    end

    is_var_stream = source_node.is_a?(AST::Identifier) &&
                   (source_ti&.dynamic_stream? || source_ti&.open_stream? ||
                    source_ti&.bounded_stream? || source_ti&.inf_stream?)
    source_name = is_var_stream ? source_node.name.to_s : "__range_src"
    range_let = is_var_stream ? nil :
      MIR::Let.new("__range_src", visit_mir(source_node), true, nil, "_ = &__range_src;")

    # BoundedStream and InfStream use nextOrNull() (returns ?T) for while-loop capture.
    # Dynamic streams (~T[] = IntRange/Range) use next() which already returns ?T.
    # InfStream.nextOrNull() blocks until data arrives or the stream is closed; the
    # LIMIT stage breaks the loop after N items, then the variable-scope defer deinit
    # signals the generator to stop.
    next_method = (source_ti&.bounded_stream? || source_ti&.inf_stream?) ? "nextOrNull" : "next"

    { range_let: range_let, source_name: source_name,
      outer_stmts: outer_stmts, stage_stmts: stage_stmts,
      item_var: item_var, initial_capture: initial_capture, item_used: item_used,
      elem_zig: elem_zig, next_method: next_method }
  end

  # Emit a fused while loop for a finite stream source with zero or more fusible stages.
  def lower_each_range(range_lit, stages, each_op)
    p = build_lazy_range_prefix(range_lit, stages)
    item_var        = p[:item_var]
    initial_capture = p[:initial_capture]
    item_used       = p[:item_used]

    body_mir = visit_pipeline_body_mir(each_op.body, placeholder: item_var)

    # Use |_| only when the initial capture is never referenced (avoids Zig
    # "unused capture" error).
    body_uses_initial = (item_var == initial_capture) && ast_stmts_use_placeholder?(each_op.body)
    item_used ||= body_uses_initial
    capture_name = item_used ? initial_capture : "_"

    # Bounded streams (~T[N]): emit defer deinit so early-exit ops (TAKE_WHILE, LIMIT)
    # drain unconsumed Promise.Inner allocations.  No-op when all items are consumed.
    source_ti = range_lit.type_info
    defer_deinit = source_ti&.bounded_stream? ?
      MIR::DeferStmt.new(MIR::MethodCall.new(MIR::Ident.new(p[:source_name]), "deinit", [], false)) :
      nil

    # BC backend: there's no LazyRange / .next() protocol; iterate ranges
    # via IterRange and let stage_stmts (BreakStmt for TAKE_WHILE/LIMIT,
    # ContinueStmt for WHERE/SKIP) drive the same fusion shape inside
    # a ForStmt instead of a WhileStmt-with-capture.
    if bc_target? && range_lit.is_a?(AST::RangeLit)
      iter, cap = bc_for_iter_range(range_lit, capture_name == "_" ? "_" : initial_capture)
      return MIR::ScopeBlock.new([
        *p[:outer_stmts],
        MIR::ForStmt.new(iter, cap, [*p[:stage_stmts], *body_mir], nil)
      ])
    end
    # BC backend, variable-backed finite stream (`s: ~T[] = 0..<n; s s> EACH`):
    # the source slot holds the materialized list (RangeLit -> iota in BC), so
    # iterate it as a list instead of going through .next() coroutine semantics.
    if bc_target? && range_lit.is_a?(AST::Identifier)
      ti = range_lit.type_info
      if ti&.dynamic_stream? || ti&.bounded_stream?
        cap = capture_name == "_" ? "_" : initial_capture
        return MIR::ScopeBlock.new([
          *p[:outer_stmts],
          MIR::ForStmt.new(visit_mir(range_lit), cap,
            [*p[:stage_stmts], *body_mir], nil)
        ])
      end
    end

    range_next = MIR::MethodCall.new(MIR::Ident.new(p[:source_name]), p[:next_method], [], true)

    MIR::ScopeBlock.new([
      *([p[:range_let]].compact), *p[:outer_stmts],
      *([defer_deinit].compact),
      MIR::WhileStmt.new(range_next,
        [*p[:stage_stmts], *body_mir],
        capture_name, nil, nil, nil)
    ])
  end

  # When the BC backend would otherwise emit `while (range.next()) |x| { ... }`,
  # rewrite the loop as a structural ForStmt+IterRange so the existing FOR
  # opcode path drives iteration. The fusion stage_stmts (BreakStmt for
  # TAKE_WHILE/LIMIT, ContinueStmt for WHERE/SKIP) compose cleanly inside
  # a ForStmt, so semantics are preserved.
  def bc_for_iter_range(range_lit, capture_name)
    start_mir = visit_mir(range_lit.start)
    end_mir   = visit_mir(range_lit.finish)
    end_expr  = range_lit.inclusive ?
      MIR::BinOp.new("+", end_mir, MIR::Lit.new("1")) : end_mir
    [MIR::IterRange.new(start_mir, end_expr), capture_name]
  end

  def bc_target?
    @lowering.instance_variable_get(:@target) == :bc
  end

  # Emit a single fused accumulating while loop for range s> stages s> fold.
  # fold_op is one of CountOp, SumOp, AverageOp, AnyOp, AllOp, FindOp, MinOp, MaxOp.
  # Returns a MIR::BlockExpr (labeled) so the accumulated result can be used as an expression.
  def lower_range_fold(range_lit, stages, fold_op, smooth_node)
    p = build_lazy_range_prefix(range_lit, stages)
    item_var   = p[:item_var]
    elem_zig   = p[:elem_zig]
    range_next = MIR::MethodCall.new(MIR::Ident.new(p[:source_name]), p[:next_method], [], true)

    # Fold always references the element; always use the initial capture name.
    capture_name = p[:initial_capture]

    label          = next_pipe_label
    # BC backend's bc_emitter uses a flat per-function slot table, so two
    # folds in the same function reusing __fold_acc would land on the
    # same slot with whichever residency was assigned first (e.g.
    # AVERAGE allocates an f64 fslot, then ANY's :bool tries to STORE
    # through @slots and reads back stale f64). Suffix the names with
    # the pipeline label so each fold has its own slot.
    if bc_target?
      sfx = "_#{label.sub('__pblk', 'b')}"
      fold_acc   = "__fold_acc#{sfx}"
      fold_cnt   = "__fold_cnt#{sfx}"
      fold_sum   = "__fold_sum#{sfx}"
      fold_val   = "__fold_val#{sfx}"
      fold_found = "__fold_found#{sfx}"
      fold_result = "__fold_result#{sfx}"
    else
      fold_acc, fold_cnt, fold_sum, fold_val, fold_found, fold_result =
        "__fold_acc", "__fold_cnt", "__fold_sum", "__fold_val", "__fold_found", "__fold_result"
    end
    acc_init_stmts = []   # accumulator var declarations (before while)
    loop_acc_stmts = []   # accumulator update stmts (inside while, after stages)
    post_loop_stmts = []  # post-loop checks (panic for MIN/MAX on empty)
    result_expr    = nil  # MIR expression evaluated as the block result

    case fold_op
    when AST::CountOp
      pred_mir = with_pipeline_context(placeholder: item_var) { visit_mir(fold_op.expression) }
      acc_init_stmts << MIR::Let.new(fold_acc, MIR::Lit.new("0"), true, "i64", nil)
      loop_acc_stmts << MIR::IfStmt.new(pred_mir, [
        MIR::Set.new(MIR::Ident.new(fold_acc),
          MIR::BinOp.new("+", MIR::Ident.new(fold_acc), MIR::Lit.new("1")))
      ], nil)
      result_expr = MIR::Ident.new(fold_acc)

    when AST::SumOp
      acc_zig  = transpile_type(smooth_node.full_type.to_s)  # already upsized by pipe_analysis
      expr_mir = numeric_fold_expr_typed(fold_op.expression, item_var, acc_zig)
      acc_init_stmts << MIR::Let.new(fold_acc, MIR::Lit.new("0"), true, acc_zig, nil)
      loop_acc_stmts << MIR::Set.new(MIR::Ident.new(fold_acc),
        MIR::BinOp.new("+", MIR::Ident.new(fold_acc), expr_mir))
      result_expr = MIR::Ident.new(fold_acc)

    when AST::AverageOp
      expr_f64 = numeric_fold_expr_f64(fold_op.expression, item_var)
      acc_init_stmts << MIR::Let.new(fold_sum, MIR::Lit.new("0"), true, "f64", nil)
      acc_init_stmts << MIR::Let.new(fold_cnt, MIR::Lit.new("0"), true, "i64", nil)
      loop_acc_stmts << MIR::Set.new(MIR::Ident.new(fold_sum),
        MIR::BinOp.new("+", MIR::Ident.new(fold_sum), expr_f64))
      loop_acc_stmts << MIR::Set.new(MIR::Ident.new(fold_cnt),
        MIR::BinOp.new("+", MIR::Ident.new(fold_cnt), MIR::Lit.new("1")))
      result_expr = MIR::Conditional.new(
        MIR::BinOp.new("==", MIR::Ident.new(fold_cnt), MIR::Lit.new("0")),
        MIR::Cast.new(MIR::Lit.new("0"), "f64", :as),
        MIR::BinOp.new("/", MIR::Ident.new(fold_sum),
          MIR::Cast.new(MIR::Cast.new(MIR::Ident.new(fold_cnt), nil, :floatFromInt), "f64", :as)))

    when AST::MinOp
      expr_sym = smooth_node.full_type.resolved  # exact type set by pipe_analysis
      acc_zig  = transpile_type(smooth_node.full_type.to_s)
      expr_mir = numeric_fold_expr_typed(fold_op.expression, item_var, acc_zig)
      acc_init_stmts << MIR::Let.new(fold_acc,
        MIR::TypeSentinel.new(:max, acc_zig), true, acc_zig, nil)
      acc_init_stmts << MIR::Let.new(fold_found, MIR::Lit.new("false"), true, nil, nil)
      loop_acc_stmts << MIR::Let.new(fold_val, expr_mir, false, nil, nil)
      loop_acc_stmts << MIR::IfStmt.new(
        MIR::BinOp.new("<", MIR::Ident.new(fold_val), MIR::Ident.new(fold_acc)),
        [MIR::Set.new(MIR::Ident.new(fold_acc), MIR::Ident.new(fold_val)),
         MIR::Set.new(MIR::Ident.new(fold_found), MIR::Lit.new("true"))], nil)
      post_loop_stmts << MIR::IfStmt.new(
        MIR::UnaryOp.new("!", MIR::Ident.new(fold_found)),
        [MIR::Panic.new("MIN applied to empty sequence")], nil)
      result_expr = MIR::Ident.new(fold_acc)

    when AST::MaxOp
      expr_sym = smooth_node.full_type.resolved  # exact type set by pipe_analysis
      acc_zig  = transpile_type(smooth_node.full_type.to_s)
      expr_mir = numeric_fold_expr_typed(fold_op.expression, item_var, acc_zig)
      acc_init_stmts << MIR::Let.new(fold_acc,
        MIR::TypeSentinel.new(:min, acc_zig), true, acc_zig, nil)
      acc_init_stmts << MIR::Let.new(fold_found, MIR::Lit.new("false"), true, nil, nil)
      loop_acc_stmts << MIR::Let.new(fold_val, expr_mir, false, nil, nil)
      loop_acc_stmts << MIR::IfStmt.new(
        MIR::BinOp.new(">", MIR::Ident.new(fold_val), MIR::Ident.new(fold_acc)),
        [MIR::Set.new(MIR::Ident.new(fold_acc), MIR::Ident.new(fold_val)),
         MIR::Set.new(MIR::Ident.new(fold_found), MIR::Lit.new("true"))], nil)
      post_loop_stmts << MIR::IfStmt.new(
        MIR::UnaryOp.new("!", MIR::Ident.new(fold_found)),
        [MIR::Panic.new("MAX applied to empty sequence")], nil)
      result_expr = MIR::Ident.new(fold_acc)

    when AST::AnyOp
      pred_mir = with_pipeline_context(placeholder: item_var) { visit_mir(fold_op.expression) }
      acc_init_stmts << MIR::Let.new(fold_acc, MIR::Lit.new("false"), true, nil, nil)
      loop_acc_stmts << MIR::IfStmt.new(pred_mir, [
        MIR::Set.new(MIR::Ident.new(fold_acc), MIR::Lit.new("true")),
        MIR::BreakStmt.new(nil, nil)
      ], nil)
      result_expr = MIR::Ident.new(fold_acc)

    when AST::AllOp
      pred_mir = with_pipeline_context(placeholder: item_var) { visit_mir(fold_op.expression) }
      acc_init_stmts << MIR::Let.new(fold_acc, MIR::Lit.new("true"), true, nil, nil)
      loop_acc_stmts << MIR::IfStmt.new(MIR::UnaryOp.new("!", pred_mir), [
        MIR::Set.new(MIR::Ident.new(fold_acc), MIR::Lit.new("false")),
        MIR::BreakStmt.new(nil, nil)
      ], nil)
      result_expr = MIR::Ident.new(fold_acc)

    when AST::FindOp
      # Element type after stages: derive from smooth_node.full_type (?ElemType)
      result_ft = Type.new(smooth_node.full_type)
      find_zig  = result_ft.optional? ? transpile_type(result_ft.wrapped_type.resolved.to_s) : elem_zig
      pred_mir = with_pipeline_context(placeholder: item_var) { visit_mir(fold_op.expression) }
      acc_init_stmts << MIR::Let.new(fold_result,
        MIR::Undef.new(nil), true, find_zig, nil)
      acc_init_stmts << MIR::Let.new(fold_found, MIR::Lit.new("false"), true, nil, nil)
      loop_acc_stmts << MIR::IfStmt.new(pred_mir, [
        MIR::Set.new(MIR::Ident.new(fold_result), MIR::Ident.new(item_var)),
        MIR::Set.new(MIR::Ident.new(fold_found), MIR::Lit.new("true")),
        MIR::BreakStmt.new(nil, nil)
      ], nil)
      result_expr = MIR::Conditional.new(
        MIR::Ident.new(fold_found),
        MIR::Cast.new(MIR::Ident.new(fold_result), "?#{find_zig}", :as),
        MIR::Lit.new("null"))
    end

    # Bounded streams (~T[N]): emit defer deinit so early-exit folds (AnyOp, AllOp, FindOp)
    # drain unconsumed Promise.Inner allocations.  No-op when all items are consumed.
    source_ti = range_lit.type_info
    defer_deinit = source_ti&.bounded_stream? ?
      MIR::DeferStmt.new(MIR::MethodCall.new(MIR::Ident.new(p[:source_name]), "deinit", [], false)) :
      nil

    if bc_target? && range_lit.is_a?(AST::RangeLit)
      iter, cap = bc_for_iter_range(range_lit, capture_name)
      return MIR::BlockExpr.new(label, [
        *p[:outer_stmts], *acc_init_stmts,
        MIR::ForStmt.new(iter, cap,
          [*p[:stage_stmts], *loop_acc_stmts], nil),
        *post_loop_stmts,
        MIR::BreakStmt.new(label, result_expr)
      ])
    end
    if bc_target? && range_lit.is_a?(AST::Identifier) &&
       (range_lit.type_info&.dynamic_stream? || range_lit.type_info&.bounded_stream?)
      return MIR::BlockExpr.new(label, [
        *p[:outer_stmts], *acc_init_stmts,
        MIR::ForStmt.new(visit_mir(range_lit), capture_name,
          [*p[:stage_stmts], *loop_acc_stmts], nil),
        *post_loop_stmts,
        MIR::BreakStmt.new(label, result_expr)
      ])
    end

    MIR::BlockExpr.new(label, [
      *([p[:range_let]].compact), *p[:outer_stmts], *acc_init_stmts,
      *([defer_deinit].compact),
      MIR::WhileStmt.new(range_next,
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
    item_var   = p[:item_var]
    range_next = MIR::MethodCall.new(MIR::Ident.new(p[:source_name]), p[:next_method], [], true)

    label    = next_pipe_label
    acc_zig  = transpile_type(reduce_op.full_type.to_s)
    init_mir = visit_mir(reduce_op.initial_value)
    expr_mir = with_pipeline_context(placeholder: item_var, acc: "acc") {
      visit_mir(reduce_op.expression)
    }

    source_ti = range_lit.type_info
    defer_deinit = source_ti&.bounded_stream? ?
      MIR::DeferStmt.new(MIR::MethodCall.new(MIR::Ident.new(p[:source_name]), "deinit", [], false)) :
      nil

    if bc_target? && range_lit.is_a?(AST::RangeLit)
      iter, cap = bc_for_iter_range(range_lit, p[:initial_capture])
      return MIR::BlockExpr.new(label, [
        *p[:outer_stmts],
        MIR::Let.new("acc", init_mir, true, acc_zig, nil),
        MIR::ForStmt.new(iter, cap,
          [*p[:stage_stmts], MIR::Set.new(MIR::Ident.new("acc"), expr_mir)], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("acc"))
      ])
    end
    if bc_target? && range_lit.is_a?(AST::Identifier) &&
       (range_lit.type_info&.dynamic_stream? || range_lit.type_info&.bounded_stream?)
      return MIR::BlockExpr.new(label, [
        *p[:outer_stmts],
        MIR::Let.new("acc", init_mir, true, acc_zig, nil),
        MIR::ForStmt.new(visit_mir(range_lit), p[:initial_capture],
          [*p[:stage_stmts], MIR::Set.new(MIR::Ident.new("acc"), expr_mir)], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("acc"))
      ])
    end

    MIR::BlockExpr.new(label, [
      *([p[:range_let]].compact), *p[:outer_stmts],
      MIR::Let.new("acc", init_mir, true, acc_zig, nil),
      *([defer_deinit].compact),
      MIR::WhileStmt.new(range_next,
        [*p[:stage_stmts], MIR::Set.new(MIR::Ident.new("acc"), expr_mir)],
        p[:initial_capture], nil, nil, nil),
      MIR::BreakStmt.new(label, MIR::Ident.new("acc"))
    ])
  end

  # CONCURRENT pipeline: worker dispatch stays as RawZig string (struct defs,
  # atomics, spawn -- too complex for MIR nodes), but with stdlib_def so the
  # checker knows the allocation effects.
  def lower_concurrent(_lhs, conc_op, smooth_node)
    # SHARD + CONCURRENT EACH: structural lowering for both backends.
    # This is a fused single-fiber loop (no real concurrency); produce a
    # ScopeBlock + ForStmt that both backends consume directly. The
    # body's `map[k] = v` routes through ShardedMapPut/Get with
    # shard_direct mode for Zig (putDirect/getDirect) and through
    # MAP_PUT/MAP_GET for BC.
    if conc_op.respond_to?(:shard_context) && conc_op.shard_context
      return lower_shard_concurrent_each(smooth_node.left, conc_op, smooth_node)
    end

    # BC backend has no fiber scheduler -- CONCURRENT is sequential
    # simulation. Strip the CONCURRENT wrapper and redispatch the inner
    # op through the regular pipeline lowering. Result-order-deterministic
    # tests pass identically; tests asserting via order-invariant aggregates
    # (sum/count/min/max) don't care. Stream sources still fall through to
    # the RawZig path below — the regular lower_select / lower_where don't
    # handle stream materialization, and the BC stream-pipeline story is
    # its own piece of work (see UNIMPL: 240/241/242/243).
    if @lowering.instance_variable_get(:@target) == :bc
      lhs_ti = smooth_node.left.type_info
      stream_lhs = lhs_ti && (lhs_ti.dynamic_stream? || lhs_ti.bounded_stream? ||
                              lhs_ti.open_stream? || lhs_ti.inf_stream? ||
                              smooth_node.left.is_a?(AST::RangeLit))
      return lower_concurrent_bc(smooth_node.left, conc_op, smooth_node) unless stream_lhs
    end

    if smooth_node.left.type_info&.bounded_stream?
      return lower_concurrent_bounded_stream(smooth_node.left, conc_op)
    end

    # Dynamic / infinite / open stream sources: structural lowering for
    # both backends. The MIR call routes to CheatLib.concurrentStreamSelect
    # (Zig: real feeder + worker fibers via BoundedChannel) or to
    # compile_concurrent_stream (BC: sequential simulation via .next()).
    lhs_ti = smooth_node.left.type_info
    stream_lhs = lhs_ti && (lhs_ti.dynamic_stream? || lhs_ti.open_stream? || lhs_ti.inf_stream?)
    if stream_lhs
      case conc_op.op
      when AST::SelectOp
        return lower_concurrent_stream_select(smooth_node.left, conc_op, conc_op.op)
      when AST::WhereOp
        return lower_concurrent_stream_where(smooth_node.left, conc_op, conc_op.op)
      when AST::EachOp
        return lower_concurrent_stream_each(smooth_node.left, conc_op, conc_op.op)
      end
    end

    # List-source CONCURRENT (Zig backend only -- BC handles lists via
    # the BC short-circuit above). `list AS @u s> CONCURRENT ...` is
    # supported: extract the binding name and run the callback body
    # lowering with `@u` registered to resolve to `__item`.
    if @lowering.instance_variable_get(:@target) != :bc
      lhs_node = smooth_node.left
      bind_name = nil
      real_lhs = lhs_node
      if lhs_node.is_a?(AST::BinaryOp) && lhs_node.op == :BIND_VAR
        bind_name = lhs_node.right.name
        real_lhs = lhs_node.left
      end
      real_lhs_ti = real_lhs.type_info
      if real_lhs_ti && real_lhs_ti.list_collection?
        case conc_op.op
        when AST::SelectOp
          return with_optional_named_binding(bind_name, "__item") {
            lower_concurrent_list_select(real_lhs, conc_op, conc_op.op)
          }
        when AST::WhereOp
          return with_optional_named_binding(bind_name, "__item") {
            lower_concurrent_list_where(real_lhs, conc_op, conc_op.op)
          }
        when AST::EachOp
          # If the body directly mutates `_` (e.g. `_.field = X` or
          # `_[i] = X`), use the in-place helper that passes `*T` to
          # the worker. Otherwise the by-value callback is fine.
          if each_body_mutates_placeholder?(conc_op.op.body)
            return with_optional_named_binding(bind_name, "__item") {
              lower_concurrent_list_each_in_place(real_lhs, conc_op, conc_op.op)
            }
          else
            return with_optional_named_binding(bind_name, "__item") {
              lower_concurrent_list_each(real_lhs, conc_op, conc_op.op)
            }
          end
        end
      end
    end

    # Detect `list AS @u s> CONCURRENT SELECT @u.field` -- thread the binding
    # into the CONCURRENT worker body so @u resolves to ctx.items[__idx].
    lhs = smooth_node.left
    prev_outer = @concurrent_outer_binding
    @concurrent_outer_binding = if lhs.is_a?(AST::BinaryOp) && lhs.op == :BIND_VAR
      lhs.right.name   # "@u"
    end

    inner = conc_op.op
    zig_code = transpile_concurrent(smooth_node)
    @concurrent_outer_binding = prev_outer

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

  # BC sequential simulation of CONCURRENT. Strips the CONCURRENT wrapper
  # (workers/parallel/capacity options become no-ops) and redispatches the
  # inner op as a regular pipeline. OR PRUNE inside the inner expression
  # gets explicit isError checking because the standard SELECT auto-tries
  # failable expressions, which would propagate errors instead of skipping.
  #
  # When `lhs` is `BIND_VAR(source, @u)`, register @u as an alias for the
  # pipeline iterator "it" and use the unwrapped source as the actual
  # data source. This makes `users AS @u s> CONCURRENT SELECT @u.field`
  # work — substitute_placeholders rewrites @u → it inside the inner
  # expression at MIR-build time. Mirrors @concurrent_outer_binding's
  # role on the Zig path.
  def lower_concurrent_bc(lhs, conc_op, smooth_node)
    inner = conc_op.op

    real_lhs = lhs
    bind_name = nil
    if lhs.is_a?(AST::BinaryOp) && lhs.op == :BIND_VAR
      bind_name = lhs.right.name
      real_lhs = lhs.left
    end

    work = lambda do
      case inner
      when AST::SelectOp
        policy, inner_expr = extract_concurrent_error_policy_for_bc(inner.expression)
        next lower_bc_concurrent_select_prune(real_lhs, inner_expr, smooth_node) if policy == :prune
        lower_select(real_lhs, inner_expr, smooth_node)

      when AST::WhereOp
        policy, inner_expr = extract_concurrent_error_policy_for_bc(inner.expression)
        next lower_bc_concurrent_where_prune(real_lhs, inner_expr, smooth_node) if policy == :prune
        lower_where(real_lhs, inner_expr, smooth_node)

      when AST::EachOp
        lower_each(real_lhs, inner, smooth_node)

      when AST::SumOp     then lower_sum(real_lhs, inner, smooth_node)
      when AST::CountOp   then lower_count(real_lhs, inner, smooth_node)
      when AST::MinOp     then lower_min(real_lhs, inner, smooth_node)
      when AST::MaxOp     then lower_max(real_lhs, inner, smooth_node)
      when AST::AverageOp then lower_average(real_lhs, inner, smooth_node)
      when AST::AnyOp     then lower_any(real_lhs, inner, smooth_node)
      when AST::AllOp     then lower_all(real_lhs, inner, smooth_node)
      when AST::FindOp    then lower_find(real_lhs, inner, smooth_node)
      else
        raise "lower_concurrent_bc: unsupported inner op #{inner.class}"
      end
    end

    bind_name ? with_named_binding(bind_name, "it", &work) : work.call
  end

  # Mirror of pipeline_generator.rb's extract_concurrent_error_policy --
  # peels OR PRUNE / OR RAISE from the inner pipeline expression. We
  # duplicate it here (instead of borrowing from the generator) so the BC
  # path is self-contained.
  def extract_concurrent_error_policy_for_bc(expr)
    if expr.is_a?(AST::BinaryOp) && expr.op == :OR_RESCUE
      return [:prune, expr.left] if expr.right.is_a?(AST::OrPrune)
      return [:raise, expr.left] if expr.right.is_a?(AST::OrRaise)
    end
    [:default, expr]
  end

  # SHARD + CONCURRENT EACH (both backends): produces structural MIR
  # describing a fused single-fiber loop. The "CONCURRENT" name is
  # misleading -- the original transpile_shard_concurrent_each emitted
  # a serial while-loop with no real fibers; the body's map[k] = v
  # used putDirect with the shard idx computed per iteration.
  #
  # Both backends produce the same shape:
  #   ScopeBlock {
  #     // (Zig only) Let map_ptr = &map; map_ptr.ensureOwnership();
  #     // (Zig only) ForStmt body has Let sh = @TypeOf(map.*).shardIndexWithHash(key)
  #     ForStmt(IterRange(start, end), idx_var, [
  #       Let key_var = key_expr_with_idx
  #       ...body lowered with shard_context set so map[k]=v
  #          dispatches to ShardedMapPut(shard_direct)...
  #     ])
  #   }
  #
  # For BC, shard_idx/shard_key on the ShardedMapPut are ignored and
  # the put compiles to plain MAP_PUT.
  def lower_shard_concurrent_each(lhs, conc_op, smooth_node)
    ctx = conc_op.shard_context
    each_op = conc_op.op
    range_node = ctx[:auto_detected] ? lhs : lhs.left
    is_bc = bc_target?

    @sh_counter ||= 0
    id = (@sh_counter += 1)
    idx_var = "__sh#{id}_i"
    key_var = "__sh#{id}_key"
    sh_var = "__sh#{id}_sh"
    map_ptr = "__sh#{id}_map"

    start_mir = visit_mir(range_node.start)
    end_mir   = visit_mir(range_node.finish)
    end_expr  = range_node.inclusive ?
      MIR::BinOp.new("+", end_mir, MIR::Lit.new("1")) : end_mir

    map_node = ctx[:map_var]
    map_var_name = map_node.is_a?(AST::Identifier) ? map_node.name.to_s : nil

    # Set mir_lowering's @shard_context so the body's map[k] = v dispatches
    # to ShardedMapPut/Get with shard_direct mode (Zig) -- BC ignores these
    # fields but the same path runs for both backends.
    prev_ctx = @lowering.instance_variable_get(:@shard_context)
    @lowering.instance_variable_set(:@shard_context, is_bc ? nil : {
      map: map_var_name,
      idx: "#{sh_var}.shard",
      key: key_var,
      hash: "#{sh_var}.hash"
    })

    key_mir, body_mir = nil, nil
    begin
      key_mir = with_pipeline_context(placeholder: idx_var) {
        visit_mir(ctx[:key_expr])
      }
      body_mir = visit_pipeline_body_mir(each_op.body, placeholder: key_var)
    ensure
      @lowering.instance_variable_set(:@shard_context, prev_ctx)
    end

    inner = []
    if !is_bc && ctx[:key_allocates_frame]
      # The key expression allocates from the frame arena (e.g. a string
      # concat). Save/restore per iteration so successive iterations
      # don't accumulate frame memory. Mirrors what
      # transpile_shard_concurrent_each used to emit.
      lm_var = "__sh#{id}_loop_mark"
      rt = @do_rt_name || "rt"
      inner << MIR::InlineZig.new("const #{lm_var} = #{rt}.saveLoopMark();", "shard_loop_save_mark")
      inner << MIR::InlineZig.new("defer #{rt}.restoreLoopMark(#{lm_var});", "shard_loop_restore_mark")
    end
    inner << MIR::Let.new(key_var, key_mir, false, nil, nil)
    unless is_bc
      # __sh#_sh = @TypeOf(__sh#_map.*).shardIndexWithHash(__sh#_key)
      # Used by the body's putDirect / getDirect (via ShardedMapPut shard_idx).
      inner << MIR::Let.new(sh_var,
        MIR::Call.new("@TypeOf(#{map_ptr}.*).shardIndexWithHash",
          [MIR::Ident.new(key_var)], false),
        false, nil, nil)
    end
    inner.concat(body_mir)

    if is_bc
      # BC: ForStmt over IterRange (the VM iterates Int64 directly so
      # the idx_var binds an Int64). No map ptr setup or ensureOwnership.
      return MIR::ForStmt.new(
        MIR::IterRange.new(start_mir, end_expr),
        idx_var, inner, nil)
    end

    # Zig: WhileStmt with explicit i64 counter so the idx_var has the
    # right type for @mod/arithmetic in the key expression. ForStmt's
    # `for (0..n) |i|` would bind i as usize, mismatching with i64
    # operands in the typical key_expr pattern.
    op_str = range_node.inclusive ? "<=" : "<"
    end_var = "__sh#{id}_end"
    MIR::ScopeBlock.new([
      MIR::Let.new(map_ptr, MIR::UnaryOp.new("&", visit_mir(map_node)), false, nil, nil),
      MIR::ExprStmt.new(
        MIR::MethodCall.new(MIR::Ident.new(map_ptr), "ensureOwnership", [], false), false),
      MIR::ScopeBlock.new([
        MIR::Let.new(idx_var, start_mir, true, "i64", nil),
        MIR::Let.new(end_var, end_mir, false, "i64", nil),
        MIR::WhileStmt.new(
          MIR::BinOp.new(op_str, MIR::Ident.new(idx_var), MIR::Ident.new(end_var)),
          inner, nil,
          MIR::Set.new(MIR::Ident.new(idx_var),
            MIR::BinOp.new("+", MIR::Ident.new(idx_var), MIR::Lit.new("1"))),
          nil, nil)
      ])
    ])
  end

  # CONCURRENT SELECT ... OR PRUNE: build a structural for-loop that runs
  # the failable expression, checks for an error sentinel, and only appends
  # on success. Result list element type is the SUCCESS type of the
  # failable expression (smooth_node.full_type).
  def lower_bc_concurrent_select_prune(lhs, inner_expr, smooth_node)
    res_zig = transpile_type(smooth_node.full_type.element_type.resolved.to_s)
    alloc = pipeline_alloc(smooth_node)
    expr_mir = visit_pipeline_expr_mir(lhs, inner_expr)

    lower_pipeline_block(lhs) do |items, label|
      [
        MIR::Let.new("res_list",
          MIR::MakeList.new(res_zig, [], alloc), true, nil, nil),
        MIR::ForStmt.new(MIR::Ident.new(items), "it", [
          MIR::Let.new("__cv", expr_mir, false, nil, nil),
          MIR::IfStmt.new(MIR::UnaryOp.new("!",
            MIR::InlineBc.new(:is_error, [MIR::Ident.new("__cv")], { bc: true })), [
            MIR::ExprStmt.new(MIR::MethodCall.new(
              MIR::Ident.new("res_list"), "append",
              [MIR::AllocatorRef.new(alloc), MIR::Ident.new("__cv")], true), nil)
          ], nil)
        ], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("res_list"))
      ]
    end
  end

  # CONCURRENT WHERE ... OR PRUNE: predicate evaluation that raises is
  # treated as "false" (item skipped). Same loop shape as lower_where but
  # the truthiness check is gated by !isError.
  def lower_bc_concurrent_where_prune(lhs, inner_expr, smooth_node)
    elem_type = lhs.full_type.element_type.resolved.to_s
    elem_zig = transpile_type(elem_type)
    alloc = pipeline_alloc(smooth_node)
    pred_mir = visit_pipeline_expr_mir(lhs, inner_expr)

    lower_pipeline_block(lhs) do |items, label|
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
              [MIR::AllocatorRef.new(alloc), MIR::Ident.new("it")], true), nil)
          ], nil)
        ], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("res_list"))
      ]
    end
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

    # Same field/init/access pattern as lower_bg_block + lower_do_block
    # (commit 04062213 + the BG-DO unification): @TypeOf(name) for the
    # field type lets Zig deduce the correct post-monomorphization
    # type, handling Arc-wrapped captures (@shared:locked propagated
    # via REQUIRES LOCKABLE) and already-pointer collection params
    # without compiler-side type math. Init is `.name = name` (no `&`),
    # body references `ctx.name` (no deref). Replaces the previous
    # `*const T` + `&name` + `ctx.name.*` triplet that broke for
    # `@shared:locked` captures (transpile-tests/257).
    fields = captures.keys.map do |name|
      MIR::FieldDef.new(name, "@TypeOf(#{name})", nil)
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
      capture_map = captures.keys.to_h { |name| [name, "ctx.#{name}"] }
    else
      body << MIR::Suppress.new("raw_ctx")
    end

    lowered_body = with_pipeline_context(placeholder: "__item") do
      with_fiber_capture_map(capture_map, capture_symbols: analysis&.capture_symbols, rt_override: "__rt") do
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
      { name: name, value: MIR::Ident.new(name) }
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

  # Element type for ~T[] / ~T[INF] / open-stream sources, mirroring the
  # extraction in the legacy transpile_concurrent_stream_* paths.
  def stream_concurrent_element_type(lhs_ti)
    if lhs_ti.inf_stream?
      Type.new(lhs_ti.inf_stream_element_type.resolved)
    elsif lhs_ti.open_stream?
      Type.new(lhs_ti.open_stream_element_type.resolved)
    else
      Type.new(lhs_ti.tense_type.element_type.resolved)
    end
  end

  # Source pointer for the feeder fiber. Identifiers can be referenced
  # directly with `&ident`; non-Ident sources (range literals, method
  # chains) need a local temp so the feeder can hold a stable pointer.
  def stream_concurrent_source_setup_mir(lhs, id)
    src = visit_mir(lhs)
    if lhs.is_a?(AST::Identifier)
      [[], MIR::AddressOf.new(src)]
    else
      local = "__stream_conc_src_#{id}"
      setup = MIR::Let.new(local, src, true, nil, "_ = &#{local};")
      [[setup], MIR::AddressOf.new(MIR::Ident.new(local))]
    end
  end

  # Capacity expression for the BoundedChannel. User-provided value via
  # `CONCURRENT(capacity: N)` overrides the default. Default rounds the
  # worker count to the next power of 2 (>= 4, <= 64) so the channel's
  # ring buffer satisfies its `cap & (cap-1) == 0` invariant.
  def stream_concurrent_capacity_mir(conc_op, n_workers_zig)
    if (cap_node = conc_op.options&.[]("capacity"))
      cap_zig = @lowering.send(:emit_expr, @lowering.lower(cap_node))
      MIR::InlineZig.new("@intCast(#{cap_zig})", "stream_conc_capacity_user")
    else
      expr = "blk: { var c: usize = 4; while (c < #{n_workers_zig} * 4) : (c <<= 1) {} break :blk @min(c, 64); }"
      MIR::InlineZig.new(expr, "stream_conc_capacity_default")
    end
  end

  def lower_concurrent_stream_select(lhs, conc_op, inner)
    lhs_ti  = lhs.type_info
    item_t  = stream_concurrent_element_type(lhs_ti)
    result_t = Type.new(inner.expression.full_type)
    cb = build_bounded_concurrent_callback(conc_op, item_t, result_t, :expr)
    setup_stmts, src_ptr = stream_concurrent_source_setup_mir(lhs, cb[:id])
    is_inf = lhs_ti.inf_stream? ? "true" : "false"

    n_workers_mir = bounded_concurrent_worker_count_mir(conc_op)
    n_workers_zig = @lowering.send(:emit_expr, n_workers_mir)
    cap_mir = stream_concurrent_capacity_mir(conc_op, n_workers_zig)

    call = @lowering.send(:emit_builtin, :concurrentStreamSelect, [
      MIR::Ident.new(item_t.zig_type),
      MIR::Ident.new(result_t.zig_type),
      MIR::Ident.new("#{cb[:ctx_name]}.apply"),
      MIR::Lit.new(is_inf),
      MIR::MethodCall.new(MIR::Ident.new("rt"), "heapAlloc", [], false),
      MIR::Ident.new("rt"),
      src_ptr,
      n_workers_mir,
      cap_mir,
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

  def lower_concurrent_stream_where(lhs, conc_op, inner)
    lhs_ti  = lhs.type_info
    item_t  = stream_concurrent_element_type(lhs_ti)
    cb = build_bounded_concurrent_callback(conc_op, item_t, :Bool, :expr)
    setup_stmts, src_ptr = stream_concurrent_source_setup_mir(lhs, cb[:id])
    is_inf = lhs_ti.inf_stream? ? "true" : "false"

    n_workers_mir = bounded_concurrent_worker_count_mir(conc_op)
    n_workers_zig = @lowering.send(:emit_expr, n_workers_mir)
    cap_mir = stream_concurrent_capacity_mir(conc_op, n_workers_zig)

    call = @lowering.send(:emit_builtin, :concurrentStreamWhere, [
      MIR::Ident.new(item_t.zig_type),
      MIR::Ident.new("#{cb[:ctx_name]}.apply"),
      MIR::Lit.new(is_inf),
      MIR::MethodCall.new(MIR::Ident.new("rt"), "heapAlloc", [], false),
      MIR::Ident.new("rt"),
      src_ptr,
      n_workers_mir,
      cap_mir,
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

  def lower_concurrent_stream_each(lhs, conc_op, inner)
    lhs_ti  = lhs.type_info
    item_t  = stream_concurrent_element_type(lhs_ti)
    cb = build_bounded_concurrent_callback(conc_op, item_t, :Void, :each)
    setup_stmts, src_ptr = stream_concurrent_source_setup_mir(lhs, cb[:id])
    is_inf = lhs_ti.inf_stream? ? "true" : "false"

    n_workers_mir = bounded_concurrent_worker_count_mir(conc_op)
    n_workers_zig = @lowering.send(:emit_expr, n_workers_mir)
    cap_mir = stream_concurrent_capacity_mir(conc_op, n_workers_zig)

    call = @lowering.send(:emit_builtin, :concurrentStreamEach, [
      MIR::Ident.new(item_t.zig_type),
      MIR::Ident.new("#{cb[:ctx_name]}.apply"),
      MIR::Lit.new(is_inf),
      MIR::MethodCall.new(MIR::Ident.new("rt"), "heapAlloc", [], false),
      MIR::Ident.new("rt"),
      src_ptr,
      n_workers_mir,
      cap_mir,
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

  # Source materialization for list-source CONCURRENT. Reuses the
  # legacy build_pipe_items_block / visit() to produce a Zig prelude
  # that binds `pipe_src_list` and `pipe_items` (a slice). The shape
  # adaptation (sharded pool / SoA / etc.) lives in build_pipe_items_block;
  # only the worker-pool wiring is migrated to structural MIR.
  def list_concurrent_source_setup_iz(lhs)
    lhs_type = lhs.type_info
    list_zig = visit(lhs)
    src_needs_cleanup = lhs.is_a?(AST::MethodCall) &&
                        %w[values keys].include?(lhs.name.to_s) &&
                        lhs.object.type_info&.sharded?
    cleanup_line = src_needs_cleanup ? "defer pipe_src_list.deinit(rt.heapAlloc());\n" : ""
    src_decl     = src_needs_cleanup ? "var pipe_src_list" : "const pipe_src_list"
    items_block  = build_pipe_items_block(lhs_type, "rt.heapAlloc()")

    setup = "#{src_decl} = #{list_zig};\n#{cleanup_line}_ = &pipe_src_list;\n#{items_block}"
    MIR::InlineZig.new(setup, "list_concurrent_src_setup")
  end

  def lower_concurrent_list_select(lhs, conc_op, inner)
    item_t  = Type.new(lhs.type_info.element_type.resolved)
    result_t = Type.new(inner.expression.full_type)
    cb = build_bounded_concurrent_callback(conc_op, item_t, result_t, :expr)
    setup_iz = list_concurrent_source_setup_iz(lhs)

    call = @lowering.send(:emit_builtin, :concurrentListSelect, [
      MIR::Ident.new(item_t.zig_type),
      MIR::Ident.new(result_t.zig_type),
      MIR::Ident.new("#{cb[:ctx_name]}.apply"),
      MIR::MethodCall.new(MIR::Ident.new("rt"), "heapAlloc", [], false),
      MIR::Ident.new("rt"),
      MIR::Ident.new("pipe_items"),
      bounded_concurrent_worker_count_mir(conc_op),
      bounded_concurrent_parallel_mir(conc_op),
      bounded_concurrent_task_cfg_mir(conc_op),
      MIR::AddressOf.new(MIR::Ident.new(cb[:ctx_var])),
    ])

    label = next_pipe_label
    MIR::BlockExpr.new(label, [
      setup_iz,
      cb[:ctx_def],
      cb[:ctx_let],
      MIR::BreakStmt.new(label, call),
    ])
  end

  def lower_concurrent_list_where(lhs, conc_op, inner)
    item_t  = Type.new(lhs.type_info.element_type.resolved)
    cb = build_bounded_concurrent_callback(conc_op, item_t, :Bool, :expr)
    setup_iz = list_concurrent_source_setup_iz(lhs)

    call = @lowering.send(:emit_builtin, :concurrentListWhere, [
      MIR::Ident.new(item_t.zig_type),
      MIR::Ident.new("#{cb[:ctx_name]}.apply"),
      MIR::MethodCall.new(MIR::Ident.new("rt"), "heapAlloc", [], false),
      MIR::Ident.new("rt"),
      MIR::Ident.new("pipe_items"),
      bounded_concurrent_worker_count_mir(conc_op),
      bounded_concurrent_parallel_mir(conc_op),
      bounded_concurrent_task_cfg_mir(conc_op),
      MIR::AddressOf.new(MIR::Ident.new(cb[:ctx_var])),
    ])

    label = next_pipe_label
    MIR::BlockExpr.new(label, [
      setup_iz,
      cb[:ctx_def],
      cb[:ctx_let],
      MIR::BreakStmt.new(label, call),
    ])
  end

  def lower_concurrent_list_each(lhs, conc_op, inner)
    item_t  = Type.new(lhs.type_info.element_type.resolved)
    cb = build_bounded_concurrent_callback(conc_op, item_t, :Void, :each)
    setup_iz = list_concurrent_source_setup_iz(lhs)

    call = @lowering.send(:emit_builtin, :concurrentListEach, [
      MIR::Ident.new(item_t.zig_type),
      MIR::Ident.new("#{cb[:ctx_name]}.apply"),
      MIR::Ident.new("rt"),
      MIR::Ident.new("pipe_items"),
      bounded_concurrent_worker_count_mir(conc_op),
      bounded_concurrent_parallel_mir(conc_op),
      bounded_concurrent_task_cfg_mir(conc_op),
      MIR::AddressOf.new(MIR::Ident.new(cb[:ctx_var])),
    ])

    MIR::ScopeBlock.new([
      setup_iz,
      cb[:ctx_def],
      cb[:ctx_let],
      MIR::ExprStmt.new(call, false),
    ])
  end

  # Scan an EACH body for direct mutation of `_` (e.g. `_.field = X` or
  # `_[i] = X`). When present, the worker callback must take `*T` not
  # `T` so the mutation lands on the shared slice, not a value copy.
  # Walks AST::Assignment.name chains rooted at Identifier("_").
  def each_body_mutates_placeholder?(body_stmts)
    body_stmts.any? { |stmt| assignment_targets_placeholder?(stmt) }
  end

  def assignment_targets_placeholder?(node)
    return false unless node
    if node.is_a?(AST::Assignment)
      return target_rooted_at_placeholder?(node.name)
    end
    if node.is_a?(Struct)
      node.members.any? do |m|
        next false if [:token, :location].include?(m)
        v = node[m]
        if v.is_a?(Array) then v.any? { |x| assignment_targets_placeholder?(x) }
        elsif v.is_a?(Struct) then assignment_targets_placeholder?(v)
        else false
        end
      end
    else
      false
    end
  end

  def target_rooted_at_placeholder?(target)
    cur = target
    while cur
      case cur
      when AST::Identifier
        return cur.name == "_"
      when AST::GetField
        cur = cur.target
      when AST::GetIndex
        cur = cur.target
      else
        return false
      end
    end
    false
  end

  # In-place EACH variant: items is a *mutable* slice and each worker
  # invocation receives `*T` so the body can update the slice element
  # via field/index assignment. Used when the body has a direct
  # `_.field = X` or `_[i] = X` mutation.
  def lower_concurrent_list_each_in_place(lhs, conc_op, inner)
    item_t = Type.new(lhs.type_info.element_type.resolved)
    cb = build_bounded_concurrent_callback_pointer(conc_op, item_t)
    setup_iz = list_concurrent_source_setup_iz(lhs)

    call = @lowering.send(:emit_builtin, :concurrentListEachInPlace, [
      MIR::Ident.new(item_t.zig_type),
      MIR::Ident.new("#{cb[:ctx_name]}.apply"),
      MIR::Ident.new("rt"),
      # The legacy `pipe_items` is a `[]const T`; @constCast strips the
      # const so the in-place helper can write through the slice.
      MIR::InlineZig.new("@constCast(pipe_items)", "list_each_inplace_mut_items"),
      bounded_concurrent_worker_count_mir(conc_op),
      bounded_concurrent_parallel_mir(conc_op),
      bounded_concurrent_task_cfg_mir(conc_op),
      MIR::AddressOf.new(MIR::Ident.new(cb[:ctx_var])),
    ])

    MIR::ScopeBlock.new([
      setup_iz,
      cb[:ctx_def],
      cb[:ctx_let],
      MIR::ExprStmt.new(call, false),
    ])
  end

  # Variant of build_bounded_concurrent_callback for in-place EACH:
  # `__item` is `*T` (mutable pointer) so `_.field = X` lands on the
  # slice element. Otherwise identical to the by-value callback.
  def build_bounded_concurrent_callback_pointer(conc_op, item_type)
    @bounded_conc_counter ||= 0
    id = (@bounded_conc_counter += 1)
    ctx_name = "__BoundedConcurrentCtx#{id}"
    analysis = conc_op.capture_analysis
    captures = analysis&.captures || {}

    # @TypeOf(name) field, .name = name init, ctx.name access -- same
    # pattern as build_bounded_concurrent_callback above; the `_pointer`
    # suffix refers only to how `__item` is passed (mutable pointer
    # for in-place mutation), not how captures are stored.
    fields = captures.keys.map do |name|
      MIR::FieldDef.new(name, "@TypeOf(#{name})", nil)
    end

    raw_ctx = MIR::Param.new("raw_ctx", "?*anyopaque")
    item_zig_ptr = "*#{Type.new(item_type).zig_type}"
    params = [
      MIR::Param.new("__rt", "*Runtime"),
      raw_ctx,
      MIR::Param.new("__item", item_zig_ptr),
    ]

    body = [MIR::Suppress.new("__rt")]
    capture_map = {}
    unless captures.empty?
      ctx_cast = MIR::InlineZig.new("@as(*@This(), @ptrCast(@alignCast(raw_ctx.?)))", "bounded_concurrent_ctx_cast")
      body << MIR::Let.new("ctx", ctx_cast, false, nil, nil)
      capture_map = captures.keys.to_h { |name| [name, "ctx.#{name}"] }
    else
      body << MIR::Suppress.new("raw_ctx")
    end

    lowered_body = with_pipeline_context(placeholder: "__item") do
      with_fiber_capture_map(capture_map, capture_symbols: analysis&.capture_symbols, rt_override: "__rt") do
        [*visit_pipeline_body_mir(conc_op.op.body, placeholder: "__item"), MIR::ReturnStmt.new(nil)]
      end
    end
    body.concat(lowered_body)

    fn = MIR::FnDef.new("apply", params, "void", body, nil, true, nil)
    ctx_def = MIR::StructDef.new(ctx_name, fields, [fn], nil)
    ctx_init = MIR::StructInit.new(ctx_name, captures.keys.map { |name|
      { name: name, value: MIR::Ident.new(name) }
    })
    ctx_var = "__bounded_conc_ctx_#{id}"
    ctx_let = MIR::Let.new(ctx_var, ctx_init, true, nil, "_ = &#{ctx_var};")

    { id: id, ctx_name: ctx_name, ctx_def: ctx_def, ctx_var: ctx_var, ctx_let: ctx_let }
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
    elsif rhs.is_a?(AST::BatchWindowOp)
      return transpile_batch_window(lhs, rhs, node)
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
