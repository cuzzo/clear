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

  # Entry point for SMOOTH pipeline nodes from MIRLowering.
  # Moved from transpiler.rb -- dispatches to PipelineGenerator methods.
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
