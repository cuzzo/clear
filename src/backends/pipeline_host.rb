# typed: strict
require "sorbet-runtime"

require "set"
require_relative "./pipeline_generator"
require_relative "./zig_type_mapper"
require_relative "../mir/fiber_ctx_builder"
require_relative "../mir/placement"

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
    extend T::Sig

  include PipelineGenerator
  include ZigTypeMapper

  # Single-source loopMark save/restore pair for shard contexts that emit
  # InlineZig (vs MIR::Let used by mir_lowering.prepend_loop_mark). Returns
  # an array of two MIR::InlineZig nodes; caller concats into its inner
  # body. Inline-string variant (for raw key_loop_mark / body_loop_mark
  # interpolation) is shard_loop_mark_string below.
  sig { params(var: String, rt: String, tag: String).returns(T::Array[T.untyped]) }
  def shard_loop_mark_pair(var, rt, tag: "shard_loop")
    rt_ident = MIR::Ident.new(rt)
    [
      MIR::Let.new(var, MIR::MethodCall.new(rt_ident, "saveLoopMark", [], false, MIR::CallableContract.no_ownership(0)), false, nil, nil),
      MIR::DeferStmt.new(MIR::MethodCall.new(rt_ident, "restoreLoopMark", [MIR::Ident.new(var)], false, MIR::CallableContract.no_ownership(1))),
    ]
  end

  # String-template variant for sites that interpolate the marker into a
  # larger Zig template literal (key_loop_mark / body_loop_mark).
  sig { params(var: String, rt: String, indent: String).returns(String) }
  def shard_loop_mark_string(var, rt, indent: "              ")
    "const #{var} = #{rt}.saveLoopMark();\n#{indent}defer #{rt}.restoreLoopMark(#{var});"
  end

  sig { params(cb: T::Hash[T.untyped, T.untyped]).returns(T::Array[T.untyped]) }
  def bounded_callback_context_stmts(cb)
    [
      cb[:ctx_def],
      *T.cast(cb[:pre_ctx_stmts], T::Array[T.untyped]),
      cb[:ctx_let],
      *T.cast(cb[:post_ctx_stmts], T::Array[T.untyped]),
    ].compact
  end

  # Per-stage state for sequential pipeline lowering. `list` is the source
  # list AST, `options` is the smooth-node carrying alloc/error policy/etc.
  # Reek flagged the (list_node, smooth_node) clump across 13+ lower_*
  # methods. Bundled so the dispatcher builds once and threads through.
  class PipelineSite < T::Struct
    const :list, T.untyped
    const :options, T.untyped
  end

  class PipelineSourceShape < T::Struct
    extend T::Sig

    const :type, Type
    const :bc_target, T::Boolean
    const :named_source, T::Boolean

    sig { returns(Type) }
    def element_type
      elem_type = type.element_type
      raise "pipeline source shape: #{type} has no element type" unless elem_type
      elem_type
    end

    sig { returns(T::Boolean) }
    def infinite_stream?
      type.inf_stream?
    end

    sig { returns(T::Boolean) }
    def bc_infinite_stream?
      bc_target && infinite_stream?
    end

    sig { returns(T::Boolean) }
    def bc_named_infinite_stream?
      bc_infinite_stream? && named_source
    end
  end

  class PipelinePublishSpec < T::Struct
    extend T::Sig

    const :publish_method, String
    const :expr, Symbol
    const :gate, Symbol
    const :transfers_item_on_success, T::Boolean

    sig { params(raw: T::Hash[Symbol, T.untyped]).returns(PipelinePublishSpec) }
    def self.from(raw)
      expr = T.cast(raw.fetch(:expr), Symbol)
      gate = T.cast(raw.fetch(:gate), Symbol)
      PipelinePublishSpec.new(
        publish_method: T.cast(raw.fetch(:method), String),
        expr: expr,
        gate: gate,
        transfers_item_on_success: expr == :item && gate == :pred,
      )
    end
  end

  sig { returns(T.untyped) }
  attr_reader :fn_sigs

  sig { params(lowering: T.untyped, emitter: MIREmitter).void }
  def initialize(lowering:, emitter:)
    @lowering = lowering
    @emitter = emitter
    @fn_sigs = T.let(lowering.fn_sigs, T.untyped)
    # Pipeline context state (managed by with_pipeline_context)
    @soa_rewrite_active = T.let(false, T::Boolean)
    @soa_each_mode = T.let(false, T::Boolean)
    @soa_needed_fields = T.let(Set.new, T::Set[T.untyped])
    @mir_mode = T.let(false, T::Boolean)
    @each_idx_counter = T.let(nil, T.nilable(Integer))
    @sh_counter = T.let(nil, T.nilable(Integer))
    @bounded_conc_counter = T.let(nil, T.nilable(Integer))
    @pipe_label_counter = T.let(0, Integer)
    @pipe_temp_counter = T.let(0, Integer)
    @current_pipe_label = T.let(nil, T.nilable(String))
    @placeholder_name = T.let(nil, T.nilable(String))
    @acc_placeholder = T.let(nil, T.untyped)
    @shard_direct_map = T.let(nil, T.untyped)
    @shard_direct_idx = T.let(nil, T.untyped)
    @shard_direct_key = T.let(nil, T.untyped)
    @shard_direct_hash = T.let(nil, T.untyped)
    @do_rt_name = T.let(nil, T.nilable(String))
    # Named pipeline bindings: "$u" -> "__pipe_u" (persist across stages, cleared per-chain)
    @named_bindings = T.let({}, T::Hash[T.untyped, T.untyped])
    @join_param_map = T.let(nil, T.nilable(T::Hash[T.untyped, T.untyped]))
  end

  # Compute the Zig variable name for a CLEAR named pipeline binding.
  # "$u" -> "__pipe_u", "$order" -> "__pipe_order"
  sig { params(clear_name: String).returns(String) }
  def pipe_binding_zig_name(clear_name)
    "__pipe_#{clear_name.delete_prefix('$')}"
  end

  # Conditional version of with_named_binding: registers the binding only
  # if a name is provided, otherwise just calls the block. Used at the
  # CONCURRENT lowering site where `list AS $u |> ...` provides a name
  # but plain `list |> ...` does not.
  sig { params(clear_name: T.nilable(String), zig_var: String, blk: T.untyped).returns(T.untyped) }
  def with_optional_named_binding(clear_name, zig_var, &blk)
    return blk.call if clear_name.nil?
    with_named_binding(clear_name, zig_var, &blk)
  end

  # Register a named pipeline binding for the duration of a block.
  # Saves and restores previous value so nested bindings stack correctly.
  sig { params(clear_name: String, zig_var: String, blk: T.untyped).returns(T.untyped) }
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
  sig { params(new_entries: T::Hash[String, String], capture_symbols: T.nilable(T::Hash[String, SymbolEntry]), rt_override: String, blk: T.untyped).returns(T.untyped) }
  def with_fiber_capture_map(new_entries, capture_symbols: nil, rt_override: "__rt", &blk)
    @lowering.with_fiber_capture_map(new_entries, capture_symbols: capture_symbols, rt_override: rt_override, &blk)
  end

  # Delegate task_config_zig to MIRLowering (used by CONCURRENT pipeline operators)
  sig { params(stack_size: T.nilable(Symbol), computed_tier: T.untyped).returns(String) }
  def task_config_zig(stack_size, computed_tier = nil)
    @lowering.send(:task_config_zig, stack_size, computed_tier)
  end

  # Route AST node -> Zig string, handling pipeline-specific nodes
  # (Placeholder, SOA field rewrites) before general MIR lowering.
  sig { params(node: T.untyped).returns(String) }
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

    # Named pipeline binding: $u -> registered Zig var (e.g. "__pipe_u")
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
    T.must(@emitter.emit(mir_node))
  end

  # MIR-mode visit: returns MIR node instead of Zig string.
  # Used by lower_* pipeline methods during MIR migration.
  sig { params(node: T.untyped).returns(T.untyped) }
  def visit_mir(node)
    substituted = substitute_placeholders(node)
    @lowering.lower(substituted)
  end

  # Lower an array of AST body statements to MIR nodes, with pipeline
  # placeholder substitution. Used by side-effect operators (Tap, Each, Join)
  # whose loop bodies contain multiple statements.
  sig { params(body_stmts: T::Array[T.untyped], placeholder: String).returns(T::Array[T.untyped]) }
  def visit_pipeline_body_mir(body_stmts, placeholder:)
    with_pipeline_context(placeholder: placeholder) do
      substituted = body_stmts.map { |stmt| substitute_placeholders(stmt) }
      @lowering.lower_body(substituted)
    end
  end

  private

  # Check whether any statement in an AST array references the `_` placeholder.
  # Used to decide whether to use `|__each_item|` vs `|_|` in while captures.
  sig { params(stmts: T::Array[T.untyped]).returns(T::Boolean) }
  def ast_stmts_use_placeholder?(stmts)
    stmts.any? { |s| ast_node_uses_placeholder?(s) }
  end

  sig { params(node: T.untyped).returns(T::Boolean) }
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
  sig { params(node: T.untyped).returns(T.untyped) }
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
        new_call.zig_pattern = node.zig_pattern
        new_call.matched_stdlib_def = node.matched_stdlib_def if node.matched_stdlib_def
        return new_call
      end
    when AST::MethodCall
      new_target = substitute_placeholders(node.object)
      new_args = node.args.map { |a| substitute_placeholders(a) }
      if new_target != node.object || new_args != node.args
        new_mc = AST::MethodCall.new(node.token, new_target, node.name, new_args)
        copy_type_info(node, new_mc)
        new_mc.zig_pattern = node.zig_pattern if node.zig_pattern
        new_mc.matched_stdlib_def = node.matched_stdlib_def if node.matched_stdlib_def
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
        AST.stamp_synthetic_type!(soa_field, soa_field_slice_type(node), context: "synthetic AST type")
        soa_idx = AST::Identifier.new(node.token, "__soa_i")
        AST.stamp_synthetic_type!(soa_idx, :Int64, context: "synthetic AST type")
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
      new_operand = substitute_placeholders(node.right)
      if new_operand != node.right
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
    when AST::IfStatement
      new_cond = substitute_placeholders(node.condition)
      new_then = node.then_branch.map { |stmt| substitute_placeholders(stmt) }
      new_else = node.else_branch&.map { |stmt| substitute_placeholders(stmt) }
      if new_cond != node.condition || new_then != node.then_branch || new_else != node.else_branch
        new_if = AST::IfStatement.new(node.token, new_cond, new_then, new_else, node.then_drops, node.else_drops)
        new_if.expr_mode = node.expr_mode if node.respond_to?(:expr_mode)
        new_if.then_result_type = node.then_result_type if node.respond_to?(:then_result_type)
        new_if.else_result_type = node.else_result_type if node.respond_to?(:else_result_type)
        copy_type_info(node, new_if)
        return new_if
      end
    end

    node
  end

  sig { params(src: AST::Locatable, dst: AST::Locatable).void }
  def copy_type_info(src, dst)
    AST.stamp_synthetic_type!(dst, src.full_type!(context: "pipeline rewrite type copy"), context: "synthetic AST type")
    dst.coerced_type = src.coerced_type if src.coerced_type
    dst.storage = src.storage if src.storage
    dst.var_used = src.var_used
  end

  sig { params(field_node: AST::GetField).returns(Type) }
  def soa_field_slice_type(field_node)
    field_type = field_node.full_type!(context: "SOA field slice")
    Type.new(:"#{field_type.resolved}[]")
  end

  public

  # MIR entry point: returns MIR node tree for migrated pipeline operators.
  # Returns nil for non-migrated operators (caller falls back to string path).
  sig { params(node: AST::BinaryOp).returns(T.untyped) }
  def lower_pipeline(node)
    rhs = node.right
    lhs = node.left
    lhs_type = lhs.full_type!

    # SOA scalar operators must keep the direct field-slice loop on the
    # Zig backend; materializing full structs would erase the point of SOA.
    # The VM has no SoA layout (Value.List is uniform), so BC keeps using
    # the generic structural fold path.
    is_soa = lhs_type&.soa? && (lhs_type&.pool? || lhs_type&.list_collection? || lhs_type&.fixed_soa?)
    scalar_op = AST.pipeline_range_fold?(rhs)
    if is_soa && scalar_op && @lowering.instance_variable_get(:@target) != :bc
      return lower_soa_scalar_fold(PipelineSite.new(list: lhs, options: node), rhs)
    end

    # Range source with fold terminal: fuse into a single accumulating while loop.
    if AST.pipeline_range_fold?(rhs)
      range_chain = unwrap_range_chain(lhs)
      return lower_range_fold(range_chain[:source], range_chain[:stages], rhs, node) if range_chain
    end

    # Range source with REDUCE: fuse into a single accumulating while loop.
    if rhs.is_a?(AST::ReduceOp)
      range_chain = unwrap_range_chain(lhs)
      return lower_range_reduce(range_chain[:source], range_chain[:stages], rhs, node) if range_chain
    end

    # Binding-unnest chain: source AS $u |> UNNEST expr [AS $o] |> [stages] |> fold
    # Must be fused into nested loops - materializing UNNEST would lose the $u context.
    if (bchain = unwrap_binding_unnest_chain(node))
      return lower_binding_chain(bchain, node)
    end

    site = PipelineSite.new(list: lhs, options: node)
    case rhs
    when AST::CountOp   then lower_count(site, rhs)
    when AST::SumOp     then lower_sum(site, rhs)
    when AST::AverageOp then lower_average(site, rhs)
    when AST::MinOp     then lower_min(site, rhs)
    when AST::MaxOp     then lower_max(site, rhs)
    when AST::AnyOp     then lower_any(site, rhs)
    when AST::AllOp     then lower_all(site, rhs)
    when AST::FindOp    then lower_find(site, rhs)
    when AST::WhereOp   then lower_where(site, rhs.expression)
    when AST::SelectOp  then lower_select(site, rhs.expression)
    when AST::LimitOp   then lower_limit(site, rhs)
    when AST::TakeWhileOp then lower_take_while(site, rhs.expression)
    when AST::SkipOp    then lower_skip(site, rhs)
    when AST::DistinctOp then lower_distinct(site, rhs)
    when AST::UnnestOp  then lower_unnest(site, rhs)
    when AST::ReduceOp  then lower_reduce(site, rhs)
    when AST::WindowOp       then lower_window(site, rhs)
    when AST::BatchWindowOp
      lower_batch_window(site, rhs)
    when AST::OrderByOp      then lower_order_by(site, rhs)
    when AST::IndexOp   then lower_index(site, rhs.expression)
    when AST::JoinOp    then lower_join(site, rhs)
    when AST::TapOp     then lower_tap(site, rhs)
    when AST::EachOp    then lower_each(site, rhs)
    when AST::ConcurrentOp then lower_concurrent(site, rhs)
    else nil
    end
  end

  # Infrastructure: builds labeled block with source eval + materialization,
  # yields to operator body, returns MIR::BlockExpr.
  sig { params(list_node: T.untyped, blk: T.proc.params(items_ident: String, label: String).returns(T::Array[T.untyped])).returns(MIR::BlockExpr) }
  def lower_pipeline_block(list_node, &blk)
    label = next_pipe_label
    source_mir = visit_mir(list_node)
    source_prefix = T.let([], T::Array[T.untyped])
    source_cleanup = T.let(nil, T.nilable(MIR::Cleanup))
    if source_mir.is_a?(MIR::InlineZig) && source_mir.has_alloc_metadata?
      alloc = source_mir.allocs.any_heap? ? :heap : :frame
      @lowering.send(:stamp_allocating_result_target!, source_mir, "pipe_src_list", alloc: alloc)
      mark = MIR::AllocMark.new("pipe_src_list", alloc, list_node.full_type!)
      mark.scope = MIR::Placement.alloc_scope(alloc)
      source_prefix << mark
      source_cleanup = MIR::Cleanup.new("pipe_src_list",
        CleanupEntry.build(:uniform, alloc: alloc, has_moved_guard: false, zig_type: list_node.full_type!.zig_type))
    end
    @current_pipe_label = label

    lhs_type = list_node.full_type!
    mat_stmts, items_ident = build_pipe_items_mir(lhs_type)

    body_stmts = blk.call(items_ident, label)

    MIR::BlockExpr.new(label, [
      *source_prefix,
      MIR::Let.new("pipe_src_list", source_mir, false, nil, nil),
      source_cleanup,
      *mat_stmts,
      *body_stmts
    ].compact)
  end

  # Build materialization MIR nodes. Returns [stmts_array, items_ident_string].
  # Pool/sharded sources materialize live items into a temp buffer.
  sig { params(lhs_type: Type).returns(T::Array[T.untyped]) }
  def build_pipe_items_mir(lhs_type)
    # In BC mode the VM has no SoA layout; treat @soa lists as regular lists
    # so the structural ItemsAccess path below applies uniformly.
    bc_mode = bc_target?
    if lhs_type.pool? && lhs_type.sharded?
      [build_mat_sharded_pool(lhs_type), "pipe_items"]
    elsif lhs_type.pool? && lhs_type.soa? && !bc_mode
      [build_mat_soa_pool(lhs_type), "pipe_items"]
    elsif lhs_type.pool? && !bc_mode
      [build_mat_pool(lhs_type), "pipe_items"]
    elsif (lhs_type.list_collection? || lhs_type.fixed_soa?) && lhs_type.soa? && !bc_mode
      [build_mat_soa_list(lhs_type), "pipe_items"]
    elsif lhs_type.list_collection? && lhs_type.sharded? && !bc_mode
      [build_mat_sharded_list(lhs_type), "pipe_items"]
    elsif lhs_type.set_collection?
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

  # A pipeline result is built with the allocator of the binding it
  # flows into -- escape analysis already decided that placement (frame
  # when the result does not escape, heap when it does). One allocator
  # per binding; the pipeline is placed like every other value.
  sig { returns(Symbol) }
  def pipeline_result_alloc
    @lowering.instance_variable_get(:@current_decl_alloc) == :heap ? :heap : :frame
  end

  # Convert allocator symbol to Zig string (for InlineZig content only).
  sig { params(sym: T.untyped).returns(String) }
  def alloc_zig_str(sym)
    MIR::Placement.zig_allocator(sym.is_a?(Symbol) ? sym : nil, "rt")
  end

  sig { returns(T.nilable(Proc)) }
  def pipeline_schema_lookup
    T.unsafe(@lowering).instance_variable_get(:@schema_lookup)
  end

  sig { params(value: T.untyped, type_info: Type, alloc: Symbol).returns(T.untyped) }
  def borrowed_pipeline_value(value, type_info, alloc)
    return value unless type_info.recursive_cleanup_shape?(pipeline_schema_lookup) || type_info.heap_ptr?

    MIR::DeepCopy.new(value, type_info.zig_type, nil, :full_value, alloc)
  end

  sig { params(type_info: Type).returns(T::Boolean) }
  def cleanup_bearing_type?(type_info)
    type_info.recursive_cleanup_shape?(pipeline_schema_lookup)
  end

  sig do
    params(name: String, source: T.untyped, type_info: Type,
           zig_type: String, alloc: Symbol).returns(T::Array[T.untyped])
  end
  def owning_pipeline_temp_stmts(name, source, type_info, zig_type, alloc)
    mark = MIR::AllocMark.new(name, alloc, type_info)
    mark.scope = MIR::Placement.alloc_scope(alloc)
    entry = CleanupEntry.build(:uniform, alloc: alloc, has_moved_guard: true, zig_type: zig_type)
    [
      mark,
      MIR::Let.new(name, MIR::DeepCopy.new(source, zig_type, nil, :full_value, alloc), false, zig_type, nil),
      MIR::ErrCleanup.new(name, entry),
    ]
  end

  # stdlib_def for InlineZig nodes that pass an allocator (borrows only).
  ALLOC_REF_DEF = T.let(FunctionSignature.borrowing_intrinsic, FunctionSignature)
  # stdlib_def for InlineZig nodes that allocate via the passed allocator.
  ALLOCATING_DEF = T.let(FunctionSignature.allocating_intrinsic, FunctionSignature)

  # Common: var pipe_mat = ArrayListUnmanaged(T){}; defer pipe_mat.deinit(alloc);
  sig { params(elem_zig: String).returns(T::Array[T.untyped]) }
  def mat_var_and_defer(elem_zig)
    # Use a structural MIR node so both backends can dispatch. The Zig
    # backend's ContainerInit emitter produces `@as(std.ArrayListUnmanaged(T),
    # .empty)` for :list_empty + this zig_type prefix, matching what the
    # legacy InlineZig string used to produce. The VM's bc_emitter compiles
    # ContainerInit :list_empty to LOAD_CONST [:empty_list], giving it a real
    # Value.List to grow via list-push.
    var_decl = MIR::Let.new("pipe_mat",
      MIR::ContainerInit.new("std.ArrayListUnmanaged(#{elem_zig})",
        :list_empty, pipeline_result_alloc, nil),
      true, nil, nil)
    defer = MIR::DeferStmt.new(
      MIR::MethodCall.new(MIR::Ident.new("pipe_mat"), "deinit",
        [MIR::AllocatorRef.new(pipeline_result_alloc)], false, MIR::CallableContract.no_ownership(1))
    )
    [var_decl, defer]
  end

  # Common: const pipe_items = pipe_mat.items;
  sig { returns(MIR::Let) }
  def mat_items_let
    MIR::Let.new("pipe_items", MIR::FieldGet.new(MIR::Ident.new("pipe_mat"), "items"), false, nil, nil)
  end

  # try pipe_mat.append(rt.heapAlloc(), value_expr)
  sig { params(receiver: String, alloc: Symbol, value_expr: T.untyped).returns(T.untyped) }
  def append_owned_value_stmt(receiver, alloc, value_expr)
    if @lowering.send(:mir_allocates?, value_expr)
      @pipe_temp_counter += 1
      temp_name = "__pipe_item_#{@pipe_temp_counter}"
      value_alloc = @lowering.send(:mir_owned_alloc, value_expr) || alloc
      @lowering.send(:stamp_allocating_result_target!, value_expr, temp_name, alloc: value_alloc)
      entry = CleanupEntry.build(:uniform, alloc: value_alloc, has_moved_guard: true,
        zig_type: value_expr.respond_to?(:zig_type) && value_expr.zig_type ? value_expr.zig_type : "void")
      mark_type = @lowering.send(:mir_alloc_mark_type_info, value_expr, nil,
        context: "pipeline owned append item")
      mark = MIR::AllocMark.new(temp_name, value_alloc, mark_type)
      mark.scope = MIR::Placement.alloc_scope(value_alloc)
      return MIR::ScopeBlock.new([
        mark,
        MIR::Let.new(temp_name, value_expr, false, nil, nil),
        MIR::ErrCleanup.new(temp_name, entry),
        MIR::ExprStmt.new(
          MIR::MethodCall.new(MIR::Ident.new(receiver), "append",
            [MIR::AllocatorRef.new(alloc), MIR::Ident.new(temp_name)], true,
            MIR::CallableContract.no_ownership(2)), false),
        *MIR::OwnershipTransferPlan.new(
          name: temp_name,
          target: :owned_sink,
          target_alloc: alloc,
          move_guarded: true,
        ).marks,
      ])
    end

    MIR::ExprStmt.new(
      MIR::MethodCall.new(MIR::Ident.new(receiver), "append",
        [MIR::AllocatorRef.new(alloc), value_expr], true, MIR::CallableContract.no_ownership(2)), false)
  end

  sig { params(value_expr: T.untyped).returns(T.untyped) }
  def mat_append(value_expr)
    append_owned_value_stmt("pipe_mat", pipeline_result_alloc, value_expr)
  end

  # try pipe_mat.appendSlice(rt.heapAlloc(), slice_expr)
  sig { params(slice_expr: MIR::FieldGet).returns(MIR::ExprStmt) }
  def mat_append_slice(slice_expr)
    MIR::ExprStmt.new(
      MIR::MethodCall.new(MIR::Ident.new("pipe_mat"), "appendSlice",
        [MIR::AllocatorRef.new(pipeline_result_alloc), slice_expr], true, MIR::CallableContract.no_ownership(2)), false)
  end

  # Sharded pool: for each shard, for each slot, append alive values.
  sig { params(lhs_type: T.untyped).returns(T::Array[T.untyped]) }
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
      MIR::IterRange.new(MIR::Lit.new("0"), MIR::Lit.new(n.to_s), :usize), "__psi", [inner_loop], nil)

    [var_decl, defer, outer_loop, mat_items_let]
  end

  # SOA pool: iterate data.len, check alive[i], append data.get(i).
  sig { params(lhs_type: Type).returns(T::Array[T.untyped]) }
  def build_mat_soa_pool(lhs_type)
    elem_zig = T.must(lhs_type.element_type).zig_type
    var_decl, defer = mat_var_and_defer(elem_zig)

    value_expr = MIR::MethodCall.new(
      MIR::FieldGet.new(MIR::Ident.new("pipe_src_list"), "data"),
      "get", [MIR::Ident.new("__psi")], false,
      MIR::CallableContract.no_ownership(1))
    alive_check = MIR::IndexGet.new(
      MIR::FieldGet.new(MIR::Ident.new("pipe_src_list"), "alive"),
      MIR::Ident.new("__psi"))

    loop_node = MIR::ForStmt.new(
      MIR::IterRange.new(MIR::Lit.new("0"), MIR::Cast.new(MIR::ListLength.new(MIR::FieldGet.new(MIR::Ident.new("pipe_src_list"), "data")), "usize", :intCast), :usize),
      "__psi",
      [MIR::IfStmt.new(alive_check, [mat_append(value_expr)], nil)],
      nil)

    [var_decl, defer, loop_node, mat_items_let]
  end

  # Plain pool: iterate slots, check alive, append value.
  sig { params(lhs_type: Type).returns(T::Array[T.untyped]) }
  def build_mat_pool(lhs_type)
    elem_zig = T.must(lhs_type.element_type).zig_type
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
  sig { params(lhs_type: T.untyped).returns(T::Array[T.untyped]) }
  def build_mat_set(lhs_type)
    elem_zig = lhs_type.element_type.zig_type
    var_decl, defer = mat_var_and_defer(elem_zig)

    iter_let = MIR::Let.new("__skit",
      MIR::MethodCall.new(MIR::Ident.new("pipe_src_list"), "keyIterator", [], false, MIR::CallableContract.no_ownership(0)),
      true, nil, nil)
    deref = MIR::FieldGet.new(MIR::Ident.new("__skptr"), "*")
    loop_node = MIR::WhileStmt.new(
      MIR::MethodCall.new(MIR::Ident.new("__skit"), "next", [], false, MIR::CallableContract.no_ownership(0)),
      [mat_append(deref)],
      "__skptr", nil)

    [var_decl, defer, iter_let, loop_node, mat_items_let]
  end

  # SOA list: iterate data.len, append data.get(i).
  sig { params(lhs_type: Type).returns(T::Array[T.untyped]) }
  def build_mat_soa_list(lhs_type)
    elem_zig = T.must(lhs_type.element_type).zig_type
    var_decl, defer = mat_var_and_defer(elem_zig)

    value_expr = MIR::MethodCall.new(
      MIR::FieldGet.new(MIR::Ident.new("pipe_src_list"), "data"),
      "get", [MIR::Ident.new("__psi")], false,
      MIR::CallableContract.no_ownership(1))

    loop_node = MIR::ForStmt.new(
      MIR::IterRange.new(MIR::Lit.new("0"), MIR::Cast.new(MIR::ListLength.new(MIR::FieldGet.new(MIR::Ident.new("pipe_src_list"), "data")), "usize", :intCast), :usize),
      "__psi",
      [mat_append(value_expr)],
      nil)

    [var_decl, defer, loop_node, mat_items_let]
  end

  # Sharded list: iterate shards, appendSlice each shard's items.
  sig { params(lhs_type: Type).returns(T::Array[T.untyped]) }
  def build_mat_sharded_list(lhs_type)
    elem_zig = T.must(lhs_type.element_type).zig_type
    n = lhs_type.shard_count
    var_decl, defer = mat_var_and_defer(elem_zig)

    shard_items = MIR::FieldGet.new(
      MIR::IndexGet.new(MIR::FieldGet.new(MIR::Ident.new("pipe_src_list"), "shards"),
                        MIR::Ident.new("__psi")),
      "items")

    loop_node = MIR::ForStmt.new(
      MIR::IterRange.new(MIR::Lit.new("0"), MIR::Lit.new(n.to_s), :usize), "__psi",
      [mat_append_slice(shard_items)],
      nil)

    [var_decl, defer, loop_node, mat_items_let]
  end

  public

  # Visit pipeline expression in MIR mode with placeholder substitution.
  sig { params(list_node: T.untyped, expr_node: T.untyped, placeholder: String).returns(T.untyped) }
  def visit_pipeline_expr_mir(list_node, expr_node, placeholder = "it")
    with_pipeline_context(placeholder: placeholder) do
      visit_mir(expr_node)
    end
  end

  sig { params(node: T.untyped).returns(T::Boolean) }
  def ast_uses_bare_placeholder?(node)
    return false unless node
    return false if node.is_a?(String) || node.is_a?(Symbol) || node.is_a?(Numeric) ||
                    node.is_a?(TrueClass) || node.is_a?(FalseClass)
    return node.name == "_" if node.is_a?(AST::Identifier)
    if node.is_a?(AST::GetField) && node.target.is_a?(AST::Identifier) && node.target.name == "_"
      return false
    end

    [:left, :right, :value, :args, :object, :target, :index, :condition,
     :then_branch, :else_branch, :do_branch, :body, :start, :finish].each do |field|
      next unless node.respond_to?(field)
      child = node.public_send(field)
      case child
      when Array
        return true if child.any? { |c| ast_uses_bare_placeholder?(c) }
      when NilClass, String, Symbol, Numeric, TrueClass, FalseClass, Hash
        next
      else
        return true if ast_uses_bare_placeholder?(child)
      end
    end
    false
  end

  sig { params(site: PipelineHost::PipelineSite, fold_node: T.untyped).returns(MIR::BlockExpr) }
  def lower_soa_scalar_fold(site, fold_node)
    list_node = site.list
    label = next_pipe_label
    source_mir = visit_mir(list_node)
    @current_pipe_label = label

    prev_soa_active = @soa_rewrite_active
    prev_soa_each = @soa_each_mode
    prev_soa_fields = @soa_needed_fields
    expr_mir = T.let(nil, T.untyped)
    fields = T.let([], T::Array[T.untyped])
    needs_whole_item = T.let(false, T::Boolean)

    begin
      @soa_rewrite_active = true
      @soa_each_mode = false
      @soa_needed_fields = Set.new

      if fold_node.respond_to?(:expression)
        expr_mir = with_pipeline_context(placeholder: "it") { visit_mir(fold_node.expression) }
      end
      fields = @soa_needed_fields.to_a.sort_by(&:to_s)
      needs_whole_item = fold_node.is_a?(AST::FindOp) ||
        !!(fold_node.respond_to?(:expression) && ast_uses_bare_placeholder?(fold_node.expression))
    ensure
      @soa_rewrite_active = prev_soa_active
      @soa_each_mode = prev_soa_each
      @soa_needed_fields = prev_soa_fields
    end

    build_soa_scalar_fold_block(site, fold_node, label, source_mir, expr_mir, fields, needs_whole_item)
  end

  sig { params(site: PipelineHost::PipelineSite, fold_node: T.untyped, label: String, source_mir: T.untyped, expr_mir: T.untyped, fields: T::Array[String], needs_whole_item: T::Boolean).returns(MIR::BlockExpr) }
  def build_soa_scalar_fold_block(site, fold_node, label, source_mir, expr_mir, fields, needs_whole_item)
    list_node = site.list
    lhs_type = list_node.full_type!
    smooth_node = site.options

    len_expr = lhs_type.pool? ?
      MIR::Cast.new(MIR::FieldGet.new(MIR::Ident.new("__soa_src"), "live_count"), "usize", :intCast) :
      MIR::Cast.new(MIR::ListLength.new(MIR::FieldGet.new(MIR::Ident.new("__soa_src"), "data")), "usize", :intCast)
    iter_expr = MIR::IterRange.new(MIR::Lit.new("0"),
      MIR::Cast.new(MIR::ListLength.new(MIR::FieldGet.new(MIR::Ident.new("__soa_src"), "data")), "usize", :intCast), :usize)

    pre_loop = [
      MIR::Let.new("__soa_src", MIR::UnaryOp.new("&", source_mir), false, nil, nil),
      *fields.map { |f|
        MIR::Let.new("__soa_#{f}", MIR::SoaFieldAccess.new(MIR::Ident.new("__soa_src"), f), false, nil, nil)
      }
    ]

    loop_prefix = []
    if lhs_type.pool?
      loop_prefix << MIR::IfStmt.new(
        MIR::UnaryOp.new("!", MIR::IndexGet.new(MIR::FieldGet.new(MIR::Ident.new("__soa_src"), "alive"), MIR::Ident.new("__soa_i"))),
        [MIR::ContinueStmt.new(nil)], nil)
    end
    if needs_whole_item
      loop_prefix << MIR::Let.new("it",
        MIR::MethodCall.new(MIR::FieldGet.new(MIR::Ident.new("__soa_src"), "data"), "get",
          [MIR::Ident.new("__soa_i")], false, MIR::CallableContract.no_ownership(1)),
        false, nil, nil)
    end

    result_type = transpile_type(smooth_node.full_type!.to_s)
    init_stmts = []
    loop_body = []
    final_expr = nil

    case fold_node
    when AST::CountOp
      init_stmts << MIR::Let.new("count_result", MIR::Lit.new("0"), true, "i64", nil)
      loop_body << MIR::IfStmt.new(expr_mir, [
        MIR::Set.new(MIR::Ident.new("count_result"), MIR::BinOp.new("+", MIR::Ident.new("count_result"), MIR::Lit.new("1")))
      ], nil)
      final_expr = MIR::Ident.new("count_result")
    when AST::SumOp
      init_stmts << MIR::Let.new("sum_result", MIR::Lit.new("0"), true, result_type, nil)
      loop_body << MIR::Set.new(MIR::Ident.new("sum_result"), MIR::BinOp.new("+", MIR::Ident.new("sum_result"), expr_mir))
      final_expr = MIR::Ident.new("sum_result")
    when AST::AverageOp
      init_stmts << MIR::Let.new("avg_sum", MIR::Lit.new("0"), true, "f64", nil)
      init_stmts << MIR::Let.new("avg_count", len_expr, false, nil, nil)
      loop_body << MIR::Set.new(MIR::Ident.new("avg_sum"), MIR::BinOp.new("+", MIR::Ident.new("avg_sum"), expr_mir))
      final_expr = MIR::Conditional.new(
        MIR::BinOp.new("==", MIR::Ident.new("avg_count"), MIR::Lit.new("0")),
        MIR::Cast.new(MIR::Lit.new("0"), "f64", :as),
        MIR::BinOp.new("/", MIR::Ident.new("avg_sum"),
          MIR::Cast.new(MIR::Cast.new(MIR::Ident.new("avg_count"), nil, :floatFromInt), "f64", :as)))
    when AST::MinOp
      init_stmts << MIR::IfStmt.new(MIR::BinOp.new("==", len_expr, MIR::Lit.new("0")), [MIR::Panic.new("MIN applied to empty list")], nil)
      init_stmts << MIR::Let.new("min_result", MIR::TypeSentinel.new(:max, result_type), true, result_type, nil)
      loop_body << MIR::Let.new("min_val", expr_mir, false, nil, nil)
      loop_body << MIR::IfStmt.new(MIR::BinOp.new("<", MIR::Ident.new("min_val"), MIR::Ident.new("min_result")),
        [MIR::Set.new(MIR::Ident.new("min_result"), MIR::Ident.new("min_val"))], nil)
      final_expr = MIR::Ident.new("min_result")
    when AST::MaxOp
      init_stmts << MIR::IfStmt.new(MIR::BinOp.new("==", len_expr, MIR::Lit.new("0")), [MIR::Panic.new("MAX applied to empty list")], nil)
      init_stmts << MIR::Let.new("max_result", MIR::TypeSentinel.new(:min, result_type), true, result_type, nil)
      loop_body << MIR::Let.new("max_val", expr_mir, false, nil, nil)
      loop_body << MIR::IfStmt.new(MIR::BinOp.new(">", MIR::Ident.new("max_val"), MIR::Ident.new("max_result")),
        [MIR::Set.new(MIR::Ident.new("max_result"), MIR::Ident.new("max_val"))], nil)
      final_expr = MIR::Ident.new("max_result")
    when AST::AnyOp
      init_stmts << MIR::Let.new("any_result", MIR::Lit.new("false"), true, nil, nil)
      loop_body << MIR::IfStmt.new(expr_mir, [
        MIR::Set.new(MIR::Ident.new("any_result"), MIR::Lit.new("true")),
        MIR::BreakStmt.new(nil, nil)
      ], nil)
      final_expr = MIR::Ident.new("any_result")
    when AST::AllOp
      init_stmts << MIR::Let.new("all_result", MIR::Lit.new("true"), true, nil, nil)
      loop_body << MIR::IfStmt.new(MIR::UnaryOp.new("!", expr_mir), [
        MIR::Set.new(MIR::Ident.new("all_result"), MIR::Lit.new("false")),
        MIR::BreakStmt.new(nil, nil)
      ], nil)
      final_expr = MIR::Ident.new("all_result")
    when AST::FindOp
      elem_zig_type = transpile_type(list_node.full_type!.element_type.resolved.to_s)
      init_stmts << MIR::Let.new("find_result", MIR::Undef.new(nil), true, elem_zig_type, nil)
      init_stmts << MIR::Let.new("find_found", MIR::Lit.new("false"), true, nil, nil)
      loop_body << MIR::Let.new("find_matches", expr_mir, false, nil, nil)
      loop_body << MIR::IfStmt.new(MIR::Ident.new("find_matches"), [
        MIR::Set.new(MIR::Ident.new("find_result"), MIR::Ident.new("it")),
        MIR::Set.new(MIR::Ident.new("find_found"), MIR::Lit.new("true")),
        MIR::BreakStmt.new(nil, nil)
      ], nil)
      final_expr = MIR::Conditional.new(
        MIR::Ident.new("find_found"),
        MIR::Cast.new(MIR::Ident.new("find_result"), "?#{elem_zig_type}", :as),
        MIR::Lit.new("null"))
    else
      raise "BUG: unsupported SOA scalar fold #{fold_node.class}"
    end

    MIR::BlockExpr.new(label, [
      *pre_loop,
      *init_stmts,
      MIR::ForStmt.new(iter_expr, "__soa_i", [*loop_prefix, *loop_body], nil),
      MIR::BreakStmt.new(label, final_expr)
    ])
  end

  # --- Scalar accumulator lowerings (Phase 1) ---

  sig { params(site: PipelineHost::PipelineSite, count_node: AST::CountOp).returns(MIR::BlockExpr) }
  def lower_count(site, count_node)
    list_node = site.list
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

  sig { params(site: PipelineHost::PipelineSite, sum_node: AST::SumOp).returns(MIR::BlockExpr) }
  def lower_sum(site, sum_node)
    list_node = site.list
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

  sig { params(site: PipelineHost::PipelineSite, avg_node: AST::AverageOp).returns(MIR::BlockExpr) }
  def lower_average(site, avg_node)
    list_node = site.list
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
              MIR::Cast.new(MIR::Cast.new(MIR::Ident.new("avg_count"), nil, :floatFromInt), "f64", :as))))
      ]
    end
  end

  sig { params(site: PipelineHost::PipelineSite, min_node: AST::MinOp).returns(MIR::BlockExpr) }
  def lower_min(site, min_node)
    list_node = site.list
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

  sig { params(site: PipelineHost::PipelineSite, max_node: AST::MaxOp).returns(MIR::BlockExpr) }
  def lower_max(site, max_node)
    list_node = site.list
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

  sig { params(site: PipelineHost::PipelineSite, any_node: AST::AnyOp).returns(MIR::BlockExpr) }
  def lower_any(site, any_node)
    list_node = site.list
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

  sig { params(site: PipelineHost::PipelineSite, all_node: AST::AllOp).returns(MIR::BlockExpr) }
  def lower_all(site, all_node)
    list_node = site.list
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

  sig { params(site: PipelineHost::PipelineSite, find_node: AST::FindOp).returns(MIR::BlockExpr) }
  def lower_find(site, find_node)
    list_node = site.list
    elem_zig_type = transpile_type(list_node.full_type!.element_type.resolved.to_s)
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

  sig { params(smooth_node: AST::BinaryOp).returns(Symbol) }
  def pipeline_alloc(smooth_node)
    pipeline_result_alloc
  end

  sig { params(site: PipelineHost::PipelineSite, expr_node: T.untyped).returns(MIR::BlockExpr) }
  def lower_where(site, expr_node)
    list_node = site.list
    smooth_node = site.options
    elem_type = list_node.full_type!.element_type.resolved.to_s
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
            append_owned_value_stmt("res_list", alloc,
              borrowed_pipeline_value(MIR::Ident.new("it"), Type.new(elem_type), alloc))
          ], nil)
        ], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("res_list"))
      ]
    end
  end

  sig { params(site: PipelineHost::PipelineSite, expr_node: T.untyped).returns(MIR::BlockExpr) }
  def lower_select(site, expr_node)
    list_node = site.list
    smooth_node = site.options
    res_type = expr_node.full_type!
    res_zig = transpile_type(res_type)
    alloc = pipeline_alloc(smooth_node)
    expr_mir = visit_pipeline_expr_mir(list_node, expr_node)
    lower_pipeline_block(list_node) do |items, label|
      [
        MIR::Let.new("res_list",
          MIR::MakeList.new(res_zig, [], alloc), true, nil, nil),
        MIR::ForStmt.new(MIR::Ident.new(items), "it", [
          MIR::Let.new("val", expr_mir, false, nil, nil),
          append_owned_value_stmt("res_list", alloc,
            borrowed_pipeline_value(MIR::Ident.new("val"), Type.new(res_type), alloc))
        ], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("res_list"))
      ]
    end
  end

  sig { params(site: PipelineHost::PipelineSite, limit_node: AST::LimitOp).returns(MIR::BlockExpr) }
  def lower_limit(site, limit_node)
    list_node = site.list
    smooth_node = site.options
    source_shape = pipeline_source_shape(list_node)
    elem_type = source_shape.element_type.resolved.to_s
    elem_zig = transpile_type(elem_type)
    alloc = pipeline_alloc(smooth_node)
    count_mir = visit_mir(limit_node.count)
    # BC + inf-stream source: SliceExpr/ListLength can't talk to
    # Value.Channel. Drain N items via a ForStmt that pulls from the
    # channel through STREAM_NEXT (the bc_emitter's compile_for special-
    # cases @channel_slots) and accumulates into a list. Producer fibers
    # whose body terminates early push Nil; the for-loop's nil-guard
    # ends the drain.
    if source_shape.bc_infinite_stream?
      label = next_pipe_label
      source_mir = visit_mir(list_node)
      @current_pipe_label = label
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
        MIR::BreakStmt.new(label, MIR::Ident.new("__lim_res"))
      ])
    end
    lower_pipeline_block(list_node) do |items, label|
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
            append_owned_value_stmt("lim_result", alloc,
              borrowed_pipeline_value(MIR::Ident.new("it"), Type.new(elem_type), alloc))
          ],
          nil
        ),
        MIR::BreakStmt.new(label, MIR::Ident.new("lim_result"))
      ]
    end
  end

  sig { params(site: PipelineHost::PipelineSite, expr_node: T.untyped).returns(MIR::BlockExpr) }
  def lower_take_while(site, expr_node)
    list_node = site.list
    smooth_node = site.options
    elem_type = list_node.full_type!.element_type.resolved.to_s
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
          append_owned_value_stmt("res_list", alloc,
            borrowed_pipeline_value(MIR::Ident.new("it"), Type.new(elem_type), alloc))
        ], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("res_list"))
      ]
    end
  end

  sig { params(site: T.untyped, skip_node: T.untyped).returns(MIR::BlockExpr) }
  def lower_skip(site, skip_node)
    list_node = site.list
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

  sig { params(site: PipelineHost::PipelineSite, distinct_node: AST::DistinctOp).returns(MIR::BlockExpr) }
  def lower_distinct(site, distinct_node)
    list_node = site.list
    smooth_node = site.options
    # Observable variant: `~T[]@set:observable` -- producer-fiber-spawn
    # backed by `*ObservableStreamSet(T)` (= ObservableTerminal(StreamSet(T))).
    # Per-item: `_ = acc.inner.submit(item) catch unreachable`.
    if smooth_node.observable_dest
      range_chain = unwrap_range_chain(list_node)
      if range_chain
        p = build_lazy_range_prefix(range_chain[:source], range_chain[:stages])
        return lower_range_fold_observable_distinct(p, distinct_node, smooth_node,
          next_pipe_label, range_chain[:source])
      end
    end

    # smooth_node.full_type! is T[]@set; element_type gives the key type T.
    elem_zig = transpile_type(smooth_node.full_type!.element_type.resolved.to_s)
    set_zig  = "CheatLib.Set(#{elem_zig})"
    alloc    = :heap  # Set.insert/deinit always use heap (HashMap needs real allocator)
    expr_mir = visit_pipeline_expr_mir(list_node, distinct_node.expression)

    # Use unwrap_range_chain to detect stream sources: list_node may be a SMOOTH
    # chain (e.g. counter |> LIMIT 9) whose annotated full_type is already a
    # materialized list, so checking lhs_ti.dynamic_stream? is insufficient.
    range_chain = unwrap_range_chain(list_node)
    if range_chain

      p = build_lazy_range_prefix(range_chain[:source], range_chain[:stages])
      item_var     = p[:item_var]
      range_next   = MIR::MethodCall.new(MIR::Ident.new(p[:source_name]), p[:next_method], [], true, MIR::CallableContract.no_ownership(0))
      key_expr_mir = with_pipeline_context(placeholder: item_var) { visit_mir(distinct_node.expression) }
      label        = next_pipe_label

      source_ti    = range_chain[:source].full_type!
      defer_deinit = source_ti&.bounded_stream? ?
        MIR::DeferStmt.new(MIR::MethodCall.new(MIR::Ident.new(p[:source_name]), "deinit", [], false, MIR::CallableContract.no_ownership(0))) :
        nil

      # BC: identifier-backed stream sources go through ForStmt so the
      # bc_emitter's compile_for routes channels via STREAM_NEXT and
      # bounded streams via list-ref iteration. Same shape as the
      # lower_each_range / lower_range_fold inf-stream branch.
      if bc_target? && range_chain[:source].is_a?(AST::Identifier) &&
         (source_ti&.dynamic_stream? || source_ti&.bounded_stream? || source_ti&.inf_stream?)
        return MIR::BlockExpr.new(label, [
          *p[:outer_stmts],
          MIR::Let.new("dist_set", MIR::ContainerInit.new(set_zig, :set_empty, nil, nil), true, nil, nil),
          MIR::ForStmt.new(visit_mir(range_chain[:source]), p[:initial_capture],
            [*p[:stage_stmts],
             MIR::Let.new("dist_key", key_expr_mir, false, nil, nil),
             MIR::ExprStmt.new(MIR::MethodCall.new(
               MIR::Ident.new("dist_set"), "insert",
               [MIR::Ident.new("dist_key")], true,
               MIR::CallableContract.no_ownership(1)), nil)], nil),
          MIR::BreakStmt.new(label, MIR::Ident.new("dist_set"))
        ])
      end

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
              MIR::Ident.new("dist_key")], true,
             MIR::CallableContract.no_ownership(2)), nil)],
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
             MIR::Ident.new("dist_key")], true,
            MIR::CallableContract.no_ownership(2)), nil)
        ], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("dist_set"))
      ]
    end
  end

  # --- Complex operator lowerings (Phase 3) ---

  sig { params(site: PipelineHost::PipelineSite, unnest_node: AST::UnnestOp).returns(MIR::BlockExpr) }
  def lower_unnest(site, unnest_node)
    list_node = site.list
    smooth_node = site.options
    inner_elem_type = T.must(unnest_node.full_type!.element_type).resolved.to_s
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
              [MIR::AllocatorRef.new(alloc), MIR::Ident.new("inner_it")], true,
              MIR::CallableContract.no_ownership(2)), nil)
          ], nil)
        ], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("res_list"))
      ]
    end
  end

  sig { params(site: PipelineHost::PipelineSite, reduce_node: AST::ReduceOp).returns(MIR::BlockExpr) }
  def lower_reduce(site, reduce_node)
    list_node = site.list
    acc_zig = transpile_type(reduce_node.full_type!)
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

  sig { params(site: PipelineHost::PipelineSite, window_node: AST::WindowOp).returns(MIR::BlockExpr) }
  def lower_window(site, window_node)
    list_node = site.list
    smooth_node = site.options
    expr_type_str = window_node.expression.full_type!.to_s
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
                    true, MIR::CallableContract.no_ownership(2)), nil)
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
  BATCH_WINDOW_TIME_NS = T.let({ 'ms' => 1_000_000, 's' => 1_000_000_000, 'min' => 60_000_000_000, 'h' => 3_600_000_000_000 }.freeze, T::Hash[T.untyped, T.untyped])

  sig { params(bw_node: T.untyped).returns(String) }
  def batch_window_timeout_ns(bw_node)
    return "0" unless bw_node.options["time"]
    str = bw_node.options["time"].value
    match = /\A(\d+(?:\.\d+)?)(ms|s|min|h)\z/.match(str)
    return "0" unless match
    (match[1].to_f * BATCH_WINDOW_TIME_NS.fetch(match[2])).to_i.to_s
  end

  sig { params(site: PipelineHost::PipelineSite, bw_node: AST::BatchWindowOp).returns(MIR::BlockExpr) }
  def lower_batch_window(site, bw_node)
    list_node = site.list
    smooth_node = site.options
    expr_type_str = bw_node.expression.full_type!.to_s
    res_zig = transpile_type(expr_type_str)

    lhs_type = list_node.full_type!
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

    return lower_zig_batch_window(site, bw_node, elem_zig, res_zig, size_mir, expr_mir, alloc, placeholder_var) unless bc_target?

    # BC + inf-stream identifier source: lower_pipeline_block emits
    # `pipe_items = ItemsAccess(channel)` which is identity in BC, so
    # `pipe_items.len` and SliceExpr are nonsensical on a Value.Channel.
    # Drain the channel into a real list via a ForStmt (compile_for
    # routes channel slots through STREAM_NEXT), then run the original
    # batch-window logic on that materialized list. Producer fibers
    # whose body terminates push Nil so the for-loop exits cleanly;
    # genuinely-infinite producers stay blocked at the next YIELD until
    # exec! shutdown closes the channel.
    if bc_target? && list_node.is_a?(AST::Identifier) &&
       list_node.full_type!.inf_stream?
      label = next_pipe_label
      drain_label = next_pipe_label
      source_mir = visit_mir(list_node)
      @current_pipe_label = label
      return MIR::BlockExpr.new(label, [
        MIR::Let.new("__bw_drained",
          MIR::MakeList.new(elem_zig, [], alloc), true, nil, nil),
        MIR::ForStmt.new(source_mir, "__bw_it", [
          MIR::ExprStmt.new(MIR::MethodCall.new(
            MIR::Ident.new("__bw_drained"), "append",
            [MIR::Ident.new("__bw_it")], true,
            MIR::CallableContract.no_ownership(1)), nil)
        ], nil),
        MIR::Let.new("res_list",
          MIR::MakeList.new(res_zig, [], alloc), true, nil, nil),
        MIR::Let.new("__bw_size", size_mir, false, "i64", nil),
        MIR::Let.new("__bw_total",
          MIR::Cast.new(
            MIR::FieldGet.new(MIR::Ident.new("__bw_drained"), "len"),
            "i64", :intCast),
          false, "i64", nil),
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
              MIR::SliceExpr.new(MIR::Ident.new("__bw_drained"),
                MIR::Cast.new(MIR::Ident.new("__bw_offset"), "usize", :intCast),
                MIR::Cast.new(MIR::Ident.new("__bw_end"), "usize", :intCast),
                nil),
              false, nil, nil),
            MIR::Let.new("__bw_val", expr_mir, false, nil, nil),
            MIR::ExprStmt.new(MIR::MethodCall.new(
              MIR::Ident.new("res_list"), "append",
              [MIR::Ident.new("__bw_val")],
              true, MIR::CallableContract.no_ownership(1)), nil),
            MIR::Set.new(MIR::Ident.new("__bw_offset"),
              MIR::Ident.new("__bw_end")),
          ], nil, nil, nil, nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("res_list"))
      ])
    end

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
              true, MIR::CallableContract.no_ownership(2)), nil),
            MIR::Set.new(MIR::Ident.new("__bw_offset"),
              MIR::Ident.new("__bw_end")),
          ], nil, nil, nil, nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("res_list"))
      ]
    end
  end

  sig do
    params(
      site: PipelineHost::PipelineSite,
      bw_node: AST::BatchWindowOp,
      elem_zig: String,
      res_zig: String,
      size_mir: T.untyped,
      expr_mir: T.untyped,
      alloc: Symbol,
      placeholder_var: String
    ).returns(MIR::BlockExpr)
  end
  def lower_zig_batch_window(site, bw_node, elem_zig, res_zig, size_mir, expr_mir, alloc, placeholder_var)
    list_node = site.list
    lhs_type = list_node.full_type!
    timeout_ns = batch_window_timeout_ns(bw_node)

    if lhs_type&.open_stream? || lhs_type&.dynamic_stream? || lhs_type&.inf_stream?
      label = next_pipe_label
      @current_pipe_label = label
      pop_method = lhs_type&.inf_stream? ? "nextOrNull" : "next"
      source_mir = visit_mir(list_node)
      return MIR::BlockExpr.new(label, [
        MIR::Let.new("__bw_src", source_mir, true, nil, "_ = &__bw_src;"),
        *batch_window_setup_stmts(elem_zig, res_zig, size_mir, timeout_ns, alloc),
        MIR::WhileStmt.new(
          MIR::MethodCall.new(MIR::Ident.new("__bw_src"), pop_method, [], true, MIR::CallableContract.no_ownership(0)),
          [batch_window_push_stmt("__bw_item", elem_zig, expr_mir, alloc, placeholder_var)],
          "__bw_item", nil, nil, nil),
        batch_window_flush_stmt(elem_zig, expr_mir, alloc, placeholder_var),
        MIR::BreakStmt.new(label, MIR::Ident.new("res_list"))
      ])
    end

    if lhs_type&.bounded_stream?
      label = next_pipe_label
      @current_pipe_label = label
      source_mir = visit_mir(list_node)
      return MIR::BlockExpr.new(label, [
        MIR::Let.new("__bw_bsrc", source_mir, false, nil, nil),
        *batch_window_setup_stmts(elem_zig, res_zig, size_mir, timeout_ns, alloc),
        MIR::ForStmt.new(
          MIR::FieldGet.new(MIR::Ident.new("__bw_bsrc"), "items"),
          "__bw_item",
          [batch_window_push_stmt("__bw_item", elem_zig, expr_mir, alloc, placeholder_var)],
          nil, nil, nil),
        batch_window_flush_stmt(elem_zig, expr_mir, alloc, placeholder_var),
        MIR::BreakStmt.new(label, MIR::Ident.new("res_list"))
      ])
    end

    lower_pipeline_block(list_node) do |items, label|
      [
        *batch_window_setup_stmts(elem_zig, res_zig, size_mir, timeout_ns, alloc),
        MIR::ForStmt.new(
          MIR::Ident.new(items),
          "__bw_item",
          [batch_window_push_stmt("__bw_item", elem_zig, expr_mir, alloc, placeholder_var)],
          nil, nil, nil),
        batch_window_flush_stmt(elem_zig, expr_mir, alloc, placeholder_var),
        MIR::BreakStmt.new(label, MIR::Ident.new("res_list"))
      ]
    end
  end

  sig { params(elem_zig: String, res_zig: String, size_mir: T.untyped, timeout_ns: String, alloc: Symbol).returns(T::Array[T.untyped]) }
  def batch_window_setup_stmts(elem_zig, res_zig, size_mir, timeout_ns, alloc)
    [
      MIR::Let.new("res_list", MIR::MakeList.new(res_zig, [], alloc), true, nil, nil),
      MIR::Let.new("__bw",
        MIR::Call.new("CheatLib.BatchWindow(#{elem_zig}).init", [
          MIR::AllocatorRef.new(alloc),
          MIR::Cast.new(size_mir, "usize", :intCast),
          MIR::Lit.new(timeout_ns)
        ], false, false, MIR::CallableContract.no_ownership(3)),
        true, nil, nil),
      MIR::DeferStmt.new(MIR::MethodCall.new(MIR::Ident.new("__bw"), "deinit", [], false, MIR::CallableContract.no_ownership(0)))
    ]
  end

  sig { params(item_var: String, elem_zig: String, expr_mir: T.untyped, alloc: Symbol, placeholder_var: String).returns(MIR::BatchWindowPush) }
  def batch_window_push_stmt(item_var, elem_zig, expr_mir, alloc, placeholder_var)
    MIR::BatchWindowPush.new("__bw", MIR::Ident.new(item_var), placeholder_var, elem_zig, "res_list", expr_mir, alloc)
  end

  sig { params(elem_zig: String, expr_mir: T.untyped, alloc: Symbol, placeholder_var: String).returns(MIR::BatchWindowFlush) }
  def batch_window_flush_stmt(elem_zig, expr_mir, alloc, placeholder_var)
    MIR::BatchWindowFlush.new("__bw", placeholder_var, elem_zig, "res_list", expr_mir, alloc)
  end

  sig { params(site: PipelineHost::PipelineSite, order_node: AST::OrderByOp).returns(MIR::BlockExpr) }
  def lower_order_by(site, order_node)
    list_node = site.list
    smooth_node = site.options
    elem_type = list_node.full_type!.element_type.resolved.to_s
    elem_zig = transpile_type(elem_type)
    alloc = pipeline_alloc(smooth_node)
    key_a = with_pipeline_context(placeholder: "a") { visit_mir(order_node.expression) }
    key_b = with_pipeline_context(placeholder: "b") { visit_mir(order_node.expression) }
    lower_pipeline_block(list_node) do |items, label|
      result_name = "#{label}_ord_result"
      [
        MIR::Let.new(result_name,
          MIR::MakeList.new(elem_zig, [], alloc), true, nil, "_ = &#{result_name};"),
        MIR::ForStmt.new(MIR::Ident.new(items), "it", [
          append_owned_value_stmt(result_name, alloc,
            borrowed_pipeline_value(MIR::Ident.new("it"), Type.new(elem_type), alloc))
        ], nil),
        MIR::Sort.new(elem_zig,
          MIR::FieldGet.new(MIR::Ident.new(result_name), "items"),
          key_a, key_b),
        MIR::BreakStmt.new(label, MIR::Ident.new(result_name))
      ]
    end
  end

  sig { params(site: PipelineHost::PipelineSite, expr_node: T.untyped).returns(MIR::BlockExpr) }
  def lower_index(site, expr_node)
    list_node = site.list
    smooth_node = site.options
    lhs_ti = list_node.full_type!
    alloc = pipeline_alloc(smooth_node)

    # Stream source: use lazy while loop instead of materializing first.
    if (range_chain = unwrap_range_chain(list_node))
      elem_sym = if lhs_ti&.open_stream?
        lhs_ti.open_stream_element_type.resolved
      elsif lhs_ti&.dynamic_stream? || lhs_ti&.bounded_stream?
        lhs_ti.tense_type.element_type.resolved
      elsif range_chain[:source].full_type!.inf_stream?
        # list_node is a SMOOTH chain (e.g. counter |> LIMIT 9); lhs_ti is the
        # materialized list type so tense_type is unavailable. Pull element type
        # from the inf stream source directly.
        range_chain[:source].full_type!.inf_stream_element_type.resolved
      else
        list_node.full_type!.element_type.resolved
      end
      elem_zig = transpile_type(elem_sym.to_s)
      map_type = "CheatLib.StringMap(std.ArrayListUnmanaged(#{elem_zig}))"
      return lower_stream_index(range_chain, expr_node, elem_zig, Type.new(elem_sym), alloc, map_type, Type.from_node!(smooth_node, context: "INDEX result"))
    end

    elem_zig = transpile_type(list_node.full_type!.element_type.resolved.to_s)
    expr_mir = visit_pipeline_expr_mir(list_node, expr_node)
    map_type = "CheatLib.StringMap(std.ArrayListUnmanaged(#{elem_zig}))"
    lower_pipeline_block(list_node) do |items, label|
      [
        MIR::Let.new("idx_result",
          MIR::StructInit.new(nil, [{name: "alloc", value: MIR::AllocatorRef.new(alloc)}]),
          true, map_type, nil),
        MIR::ForStmt.new(
          MIR::Ident.new(items),
          "it",
          build_index_gop_body(expr_mir, alloc, "it",
            expr_node: expr_node,
            item_type: Type.new(list_node.full_type!.element_type),
            value_ownership: :borrowed),
          nil
        ),
        MIR::BreakStmt.new(label, MIR::Ident.new("idx_result"))
      ]
    end
  end

  # INDEX op: append item to map[key] bucket, creating the bucket if missing.
  # Lowered to MIR::IndexInsert which both backends decompose: Zig emits the
  # getOrPut + dupe/free + value_ptr.append idiom; the VM emits MAP_GET +
  # APPEND/MAKE_LIST + MAP_PUT.
  sig do
    params(expr_mir: T.untyped, alloc: Symbol, item_var: String,
           expr_node: T.untyped, item_type: T.nilable(Type), value_ownership: Symbol).returns(T::Array[T.untyped])
  end
  def build_index_gop_body(expr_mir, alloc, item_var, expr_node: nil, item_type: nil, value_ownership: :owned)
    elem_zig_type = "@TypeOf(#{item_var})"
    item_owns = item_type ? cleanup_bearing_type?(item_type) : true
    item_value = if value_ownership == :borrowed
      MIR::DeepCopy.new(MIR::Ident.new(item_var), elem_zig_type, nil, :full_value, alloc)
    else
      MIR::Ident.new(item_var)
    end
    value_body = T.let([], T::Array[T.untyped])
    if value_ownership == :owned && item_owns
      mark = MIR::AllocMark.new(item_var, alloc, item_type || Type.new(:Any))
      mark.scope = MIR::Placement.alloc_scope(alloc)
      value_body << mark
    elsif @lowering.send(:mir_allocates?, item_value)
      @pipe_temp_counter += 1
      value_name = "__idx_item_#{@pipe_temp_counter}"
      value_alloc = @lowering.send(:mir_owned_alloc, item_value) || alloc
      @lowering.send(:stamp_allocating_result_target!, item_value, value_name, alloc: value_alloc)
      mark_type = @lowering.send(:mir_alloc_mark_type_info, item_value, nil,
        context: "INDEX bucket item")
      mark = MIR::AllocMark.new(value_name, value_alloc, mark_type)
      mark.scope = MIR::Placement.alloc_scope(value_alloc)
      entry = T.unsafe(@lowering).hoist_cleanup_entry(item_value, nil)
      value_body << mark
      value_body << MIR::Let.new(value_name, item_value, false, nil, nil)
      if entry
        entry[:has_moved_guard] = true
        value_body << MIR::ErrCleanup.new(value_name, entry)
      end
      item_value = MIR::Ident.new(value_name)
    end
    insert = MIR::IndexInsert.new(
      MIR::Ident.new("idx_result"),
      MIR::Ident.new("idx_key"),
      item_value,
      "u8", elem_zig_type, alloc)
    if item_owns || @lowering.send(:mir_allocates?, item_value)
      insert = T.cast(@lowering.send(:with_ownership_consumption,
        insert,
        @lowering.send(:mir_ident_names, item_value),
        "MIR::IndexInsert",
        :owned_sink,
        target_alloc: alloc,
        require_visible: false), MIR::IndexInsert)
    end
    body = T.let([
      MIR::Let.new("idx_key", expr_mir, false, nil, nil),
      *value_body,
      insert
    ], T::Array[T.untyped])
    entry = index_key_cleanup_entry(expr_mir, expr_node)
    body << MIR::Cleanup.new("idx_key", entry) if entry
    body
  end

  sig { params(expr_mir: T.untyped, expr_node: T.untyped).returns(T.nilable(CleanupEntry)) }
  def index_key_cleanup_entry(expr_mir, expr_node)
    return nil unless T.unsafe(@lowering).mir_owned_alloc(expr_mir)
    T.unsafe(@lowering).hoist_cleanup_entry(expr_mir, expr_node)
  end

  sig { params(range_chain: T::Hash[T.untyped, T.untyped], expr_node: T.untyped, elem_zig: String, elem_type: Type, alloc: Symbol, map_type: String, result_type: Type).returns(MIR::BlockExpr) }
  def lower_stream_index(range_chain, expr_node, elem_zig, elem_type, alloc, map_type, result_type)
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
        ], false, false, MIR::CallableContract.no_ownership(3)), nil)]
    }
    p = build_lazy_range_prefix(range_chain[:source], range_chain[:stages], on_skip: on_skip)
    item_var   = p[:item_var]
    range_next = MIR::MethodCall.new(MIR::Ident.new(p[:source_name]), p[:next_method], [], true, MIR::CallableContract.no_ownership(0))

    expr_mir = with_pipeline_context(placeholder: item_var) { visit_mir(expr_node) }
    label    = next_pipe_label

    source_ti    = range_chain[:source].full_type!
    defer_deinit = source_ti&.bounded_stream? ?
      MIR::DeferStmt.new(MIR::MethodCall.new(MIR::Ident.new(p[:source_name]), "deinit", [], false, MIR::CallableContract.no_ownership(0))) :
      nil

    if bc_target?
      iter = if range_chain[:source].is_a?(AST::RangeLit)
               start_mir = visit_mir(range_chain[:source].start)
               end_mir   = visit_mir(range_chain[:source].finish)
               end_expr  = range_chain[:source].inclusive ?
                 MIR::BinOp.new("+", end_mir, MIR::Lit.new("1")) : end_mir
               MIR::IterRange.new(start_mir, end_expr, :i64)
             elsif range_chain[:source].is_a?(AST::Identifier)
               visit_mir(range_chain[:source])
             else
               nil
             end
      if iter
        block = MIR::BlockExpr.new(label, [
          *p[:outer_stmts],
          MIR::Let.new("idx_result",
            MIR::StructInit.new(nil, [{name: "alloc", value: MIR::AllocatorRef.new(:heap)}]),
            true, map_type, nil),
          MIR::ForStmt.new(iter, p[:initial_capture], [
            *p[:stage_stmts],
            *build_index_gop_body(expr_mir, :heap, item_var,
              expr_node: expr_node,
              item_type: elem_type,
              value_ownership: :owned)
          ], nil),
          MIR::BreakStmt.new(label, MIR::Ident.new("idx_result"))
        ])
        block.result_type = result_type
        return block
      end
    end

    block = MIR::BlockExpr.new(label, [
      *([p[:range_let]].compact), *p[:outer_stmts],
      MIR::Let.new("idx_result",
        MIR::StructInit.new(nil, [{name: "alloc", value: MIR::AllocatorRef.new(:heap)}]),
        true, map_type, nil),
      *([defer_deinit].compact),
      MIR::WhileStmt.new(range_next, [
        *p[:stage_stmts],
        *build_index_gop_body(expr_mir, :heap, item_var,
          expr_node: expr_node,
          item_type: elem_type,
          value_ownership: :owned)
      ], p[:initial_capture], nil, nil, nil),
      MIR::BreakStmt.new(label, MIR::Ident.new("idx_result"))
    ])
    block.result_type = result_type
    block
  end

  sig { params(site: PipelineHost::PipelineSite, join_node: AST::JoinOp).returns(MIR::BlockExpr) }
  def lower_join(site, join_node)
    list_node = site.list
    smooth_node = site.options
    left_zig  = transpile_type(list_node.full_type!.element_type.resolved.to_s)
    right_src_mir = visit_mir(join_node.right_source)
    right_type_info = join_node.right_source.full_type!
    left_type_info = list_node.full_type!.element_type
    right_zig = transpile_type(right_type_info.element_type.resolved.to_s)
    result_zig = "struct { left: #{left_zig}, right: ?#{right_zig} }"
    alloc = pipeline_result_alloc
    left_owns = cleanup_bearing_type?(left_type_info)
    right_owns = cleanup_bearing_type?(right_type_info.element_type)

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

    left_value = left_owns ? MIR::Ident.new("__jl_owned") : MIR::Ident.new("__jl")
    right_value = MIR::Ident.new("__match")
    after_append = []
    if left_owns
      after_append.concat(MIR::OwnershipTransferPlan.new(
        name: "__jl_owned",
        target: :owned_sink,
        target_alloc: pipeline_result_alloc,
        move_guarded: true,
      ).marks)
    end
    if right_owns
      after_append.concat(MIR::OwnershipTransferPlan.new(
        name: "__match",
        target: :owned_sink,
        target_alloc: pipeline_result_alloc,
        move_guarded: true,
      ).marks)
    end

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
        *(right_owns ? [
          MIR::ErrCleanup.new("__match",
            CleanupEntry.build(:uniform, alloc: alloc, has_moved_guard: true, zig_type: "?#{right_zig}")),
        ] : []),
        MIR::ForStmt.new(MIR::Ident.new("__jr_items"), "__jr", [
          MIR::IfStmt.new(pred_mir, [
            MIR::Set.new(MIR::Ident.new("__match"),
              right_owns ? MIR::DeepCopy.new(MIR::Ident.new("__jr"), right_zig, nil, :full_value, alloc) : MIR::Ident.new("__jr")),
            MIR::BreakStmt.new(nil, nil),
          ], nil)
        ], nil),
        *(left_owns ? owning_pipeline_temp_stmts("__jl_owned", MIR::Ident.new("__jl"), left_type_info, left_zig, alloc) : []),
        MIR::ExprStmt.new(MIR::MethodCall.new(
          MIR::Ident.new("res_list"), "append",
          [MIR::AllocatorRef.new(alloc),
           MIR::StructInit.new(nil, [
             {name: "left",  value: left_value},
             {name: "right", value: right_value}])],
          true, MIR::CallableContract.no_ownership(2)), nil),
        *after_append
      ], nil),
      MIR::BreakStmt.new(label, MIR::Ident.new("res_list"))
    ])
  end

  sig { params(site: T.untyped, tap_op: T.untyped).returns(MIR::BlockExpr) }
  def lower_tap(site, tap_op)
    list_node = site.list
    smooth_node = site.options
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

  sig { params(site: PipelineHost::PipelineSite, each_op: AST::EachOp).returns(T.nilable(T.any(MIR::ForStmt, MIR::ScopeBlock))) }
  def lower_each(site, each_op)
    list_node = site.list
    smooth_node = site.options
    lhs_type = list_node.full_type!

    # Sharded pools/lists use one runtime worker per shard on the Zig
    # backend. BC flattens sharded structures to Value.List at runtime,
    # so the regular per-item ForStmt path below handles it there.
    return lower_sharded_each(site, each_op) if lhs_type&.sharded? && !bc_target?

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
          MIR::IterRange.new(MIR::Lit.new("0"), MIR::Cast.new(MIR::ListLength.new(MIR::FieldGet.new(MIR::Ident.new("__soa_src"), "data")), "usize", :intCast), :usize),
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
          MIR::IterRange.new(MIR::Lit.new("0"), MIR::ListLength.new(src_ident), :usize),
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
    is_bc = (bc_target?)
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
      # is a known list-bound Identifier (the common case: `xs |> EACH`).
      # BC backend: in Zig, `for (items.items) |*item|` gives a pointer
      # so field-writes propagate. The BC ForStmt iterates by-value, so
      # field mutations on __each_item never reach the underlying list.
      # Lower to an index loop with an explicit writeback when the source
      # is a known list-bound Identifier (the common case: `xs |> EACH`).
      # Use the original Identifier as the in-place target so the writeback
      # actually updates the user's binding (a fresh __each_src copy
      # wouldn't propagate the mutation back to `xs`).
      if bc_target? && list_node.is_a?(AST::Identifier)
        @each_idx_counter = (@each_idx_counter || 0) + 1
        idx_name = "__each_i_#{@each_idx_counter}"
        src_ident = MIR::Ident.new(list_node.name.to_s)
        return MIR::ForStmt.new(
          MIR::IterRange.new(MIR::Lit.new("0"), MIR::ListLength.new(src_ident), :usize),
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
          MIR::MethodCall.new(MIR::Ident.new("__each_src"), "keyIterator", [], false, MIR::CallableContract.no_ownership(0)),
          true, nil, nil),
        MIR::WhileStmt.new(
          MIR::MethodCall.new(MIR::Ident.new("__each_iter"), "next", [], false, MIR::CallableContract.no_ownership(0)),
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
        MIR::IterRange.new(start_mir, end_expr, :i64),
        capture_name, body_mir, nil)
    end

    nil  # Fall through to string path
  end

  sig { params(site: PipelineHost::PipelineSite, each_op: AST::EachOp).returns(MIR::ScopeBlock) }
  def lower_sharded_each(site, each_op)
    list_node = site.list
    lhs_type = list_node.full_type!
    item_t = Type.new(lhs_type.element_type.resolved)
    shard_count = lhs_type.shard_count

    # Reuse the CONCURRENT callback builder so the worker body is still
    # structural MIR. There is no user-facing CONCURRENT wrapper here;
    # sharded EACH has always implied one worker per shard.
    conc = AST::ConcurrentOp.new(each_op.token, each_op, {})
    # Synthesized post-annotation: inherit the wrapped EachOp's type
    # so the AST->MIR type-resolution invariant holds.
    AST.stamp_synthetic_type!(conc, each_op.full_type!(context: "sharded EACH result"), context: "synthetic AST type")
    cb = build_bounded_concurrent_callback_pointer(conc, item_t)

    source_mir = visit_mir(list_node)
    setup = if list_node.is_a?(AST::Identifier)
      [MIR::Let.new("__sh_each_src", MIR::AddressOf.new(source_mir), false, nil, nil)]
    else
      [
        MIR::Let.new("__sh_each_val", source_mir, true, nil, "_ = &__sh_each_val;"),
        MIR::Let.new("__sh_each_src", MIR::AddressOf.new(MIR::Ident.new("__sh_each_val")), false, nil, nil)
      ]
    end

    helper = lhs_type.pool? ? :concurrentShardedPoolEachInPlace : :concurrentShardedListEachInPlace
    call = @lowering.send(:emit_builtin, helper, [
      MIR::Ident.new(item_t.zig_type),
      MIR::Lit.new(shard_count.to_s),
      MIR::Ident.new("#{cb[:ctx_name]}.apply"),
      MIR::Ident.new("rt"),
      MIR::Ident.new("__sh_each_src"),
      MIR::Lit.new("false"),
      bounded_concurrent_task_cfg_mir(conc),
      MIR::AddressOf.new(MIR::Ident.new(cb[:ctx_var])),
    ])

    MIR::ScopeBlock.new([
      *bounded_callback_context_stmts(cb),
      *setup,
      MIR::ExprStmt.new(call, false)
    ])
  end

  sig { params(node: T.untyped).returns(T::Boolean) }
  def finite_stream_source_node?(node)
    node.is_a?(AST::RangeLit) || node.full_type!.dynamic_stream? ||
      node.full_type!.open_stream? ||
      node.full_type!.bounded_stream? || node.full_type!.inf_stream?
  end

  # Walk a BinaryOp(SMOOTH) left-spine looking for a finite stream source
  # with only fusible stages between.
  sig { params(node: T.untyped).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  def unwrap_range_chain(node)
    return { source: node, stages: [] } if finite_stream_source_node?(node)
    return nil unless node.is_a?(AST::BinaryOp) && node.op == :SMOOTH

    stages = []
    cursor = T.let(node, AST::BinaryOp)
    while cursor.is_a?(AST::BinaryOp) && cursor.op == :SMOOTH
      rhs = cursor.right
      if AST.pipeline_fusible_stage?(rhs)
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
  #   BIND_VAR(source, $u) |> [BIND_VAR(]UNNEST(expr)[, $o)] |> [WHERE/SELECT] |> fold
  #
  # Note: `UNNEST expr AS $o` parses as BIND_VAR(UnnestOp(expr), $o) because AS has
  # higher precedence than |>. Both `|> UNNEST expr` and `|> UNNEST expr AS $o` are handled.
  #
  # Returns a hash with the chain components, or nil if the pattern doesn't match.
  sig { params(node: AST::BinaryOp).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  def unwrap_binding_unnest_chain(node)
    return nil unless node.is_a?(AST::BinaryOp) && node.op == :SMOOTH

    # Terminal must be a fold op
    fold = node.right
    return nil unless AST.pipeline_range_fold?(fold)
    cursor = T.let(node.left, T.untyped)

    # Collect optional intermediate WHERE/SELECT stages (in chain order)
    stages = []
    rhs = T.let(nil, T.untyped)
    while cursor.is_a?(AST::BinaryOp) && cursor.op == :SMOOTH
      rhs = cursor.right
      if AST.pipeline_select_filter_op?(rhs)
        stages.unshift(rhs)
        cursor = cursor.left
      else
        break
      end
    end

    # cursor must now be: SMOOTH(BIND_VAR(source, $u), unnest_part)
    return nil unless cursor.is_a?(AST::BinaryOp) && cursor.op == :SMOOTH
    lhs = cursor.left
    rhs = cursor.right

    # Must be a UnnestOp
    return nil unless rhs.is_a?(AST::UnnestOp)

    # Detect optional inner binding: `UNNEST expr AS $o` parses as
    # UnnestOp(expression=BIND_VAR(expr, $o)) because :pipe_expression uses
    # parse_expression(1) which consumes AS at prec 2 as part of the inner expr.
    unnest_expr = rhs.expression
    inner_binding = nil
    if unnest_expr.is_a?(AST::BinaryOp) && unnest_expr.op == :BIND_VAR
      inner_binding = unnest_expr.right.name  # "$o"
      unnest_expr   = unnest_expr.left        # the actual array expression
    end

    # LHS must be a BIND_VAR (source AS $u)
    return nil unless lhs.is_a?(AST::BinaryOp) && lhs.op == :BIND_VAR

    {
      source:        lhs.left,
      outer_binding: lhs.right.name,  # "$u"
      unnest_expr:   unnest_expr,     # $u.orders (unwrapped from any BIND_VAR)
      inner_binding: inner_binding,   # "$o" or nil
      stages:        stages,
      fold:          fold
    }
  end

  # Generate fused nested loops for a binding-unnest chain.
  # Outer loop: source elements bound to $u (outer_zig).
  # Inner loop: unnest expression elements (inner_zig).
  # Both bindings are visible in stage expressions and the fold.
  sig { params(chain: T::Hash[T.untyped, T.untyped], smooth_node: AST::BinaryOp).returns(T.nilable(MIR::BlockExpr)) }
  def lower_binding_chain(chain, smooth_node)
    outer_name = chain[:outer_binding]          # "$u"
    outer_zig  = pipe_binding_zig_name(outer_name)  # "__pipe_u"
    inner_name = chain[:inner_binding]          # "$o" or nil
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
      unnest_mir = visit_mir(chain[:unnest_expr])  # $u already in @named_bindings

      inner_block = lambda do
        acc_init, loop_body, post_inner, result_expr = lower_binding_fold(
          chain[:fold], chain[:stages], inner_zig, smooth_node, names)

        # When inner_name is nil the capture is the generated __bc_inner which
        # the fold expression may not reference (e.g. ALL $u.discount > 0.0).
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
  sig { params(fold: T.untyped, stages: T::Array[T.untyped], placeholder: String, smooth_node: T.nilable(AST::BinaryOp), names: T.nilable(T::Hash[T.untyped, T.untyped])).returns(T.nilable(T::Array[T.untyped])) }
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
      # Use f64 for count to avoid @floatFromInt in the division.
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
      # Result type is ?InnerElemType; derive from smooth_node.full_type!.
      result_ft = Type.new(T.must(smooth_node).full_type!)
      find_zig  = result_ft.optional? ? transpile_type(T.must(result_ft.wrapped_type).resolved.to_s) : placeholder
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
  sig { params(stages: T::Array[T.untyped], placeholder: String, accum_stmts: T::Array[T.untyped]).returns(T.nilable(T::Array[T.untyped])) }
  def bc_wrap_stages(stages, placeholder, accum_stmts)
    body = accum_stmts
    stages.reverse_each do |stage|
      if stage.is_a?(AST::SelectOp)
        raise "SELECT is not supported in AS $v binding chains. " \
              "Use WHERE to filter or name the projection with AS $o before the fold."
      end
      next unless stage.is_a?(AST::WhereOp)
      pred = with_pipeline_context(placeholder: placeholder) { visit_mir(stage.expression) }
      body = [MIR::IfStmt.new(pred, body, nil)]
    end
    body
  end

  # Lower a fold expression with integer→float coercion when the
  # accumulator is a float type. SUM/AVERAGE/MIN/MAX accumulators may
  # be f64 (always for AVERAGE); integer items in those folds need
  # `@floatFromInt`. Integer-into-integer and float-into-float folds
  # pass through unchanged. Returns a proper MIR node -- no InlineZig
  # string embedding.
  sig { params(expr_ast: AST::Identifier, item_var: String, acc_zig: String).returns(T.untyped) }
  def numeric_fold_expr_typed(expr_ast, item_var, acc_zig)
    expr_mir  = with_pipeline_context(placeholder: item_var) { visit_mir(expr_ast) }
    expr_type = expr_ast.full_type!
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
  sig { params(source_node: T.untyped, stages: T::Array[T.untyped], on_skip: T.nilable(Proc)).returns(T::Hash[T.untyped, T.untyped]) }
  def build_lazy_range_prefix(source_node, stages, on_skip: nil)
    source_ti = source_node.full_type!
    elem_t = if source_ti&.open_stream?
      source_ti.open_stream_element_type
    elsif source_ti&.dynamic_stream? || source_ti&.bounded_stream?
      source_ti.tense_type.element_type
    elsif source_ti&.inf_stream?
      source_ti.inf_stream_element_type
    else
      start_ft = source_node.is_a?(AST::RangeLit) ? source_node.start.full_type!(context: "lazy range start") : Type.new(:Int64)
      Type.new(start_ft)
    end
    elem_zig = elem_t.zig_type

    initial_capture = "__each_item"
    item_var    = T.let(initial_capture, String)
    item_counter = 0
    item_used   = T.let(false, T::Boolean)
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
  sig { params(range_lit: T.untyped, stages: T::Array[T.untyped], each_op: AST::EachOp).returns(MIR::ScopeBlock) }
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
    source_ti = range_lit.full_type!
    defer_deinit = source_ti&.bounded_stream? ?
      MIR::DeferStmt.new(MIR::MethodCall.new(MIR::Ident.new(p[:source_name]), "deinit", [], false, MIR::CallableContract.no_ownership(0))) :
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
    # BC backend, variable-backed finite stream (`s: ~T[] = 0..<n; s |> EACH`):
    # the source slot holds the materialized list (RangeLit -> iota in BC), so
    # iterate it as a list instead of going through .next() coroutine semantics.
    # Same shape applies to inf streams: source slot holds a Value.Channel, and
    # the bc_emitter's compile_for routes the iteration through STREAM_NEXT
    # (rendezvous pull, terminating on Nil from a closed channel). Stages like
    # LIMIT N are encoded in stage_stmts as `if cnt >= N break;` so the loop
    # bounds itself even on a non-terminating producer.
    if bc_target? && range_lit.is_a?(AST::Identifier)
      ti = range_lit.full_type!
      if ti&.dynamic_stream? || ti&.bounded_stream? || ti&.inf_stream?
        cap = capture_name == "_" ? "_" : initial_capture
        return MIR::ScopeBlock.new([
          *p[:outer_stmts],
          MIR::ForStmt.new(visit_mir(range_lit), cap,
            [*p[:stage_stmts], *body_mir], nil)
        ])
      end
    end

    range_next = MIR::MethodCall.new(MIR::Ident.new(p[:source_name]), p[:next_method], [], true, MIR::CallableContract.no_ownership(0))

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
  sig { params(range_lit: T.untyped, capture_name: T.nilable(String)).returns(T::Array[T.untyped]) }
  def bc_for_iter_range(range_lit, capture_name)
    start_mir = visit_mir(range_lit.start)
    end_mir   = visit_mir(range_lit.finish)
    end_expr  = range_lit.inclusive ?
      MIR::BinOp.new("+", end_mir, MIR::Lit.new("1")) : end_mir
    [MIR::IterRange.new(start_mir, end_expr, :i64), capture_name]
  end

  sig { returns(T::Boolean) }
  def bc_target?
    @lowering.instance_variable_get(:@target) == :bc
  end

  sig { params(source_node: AST::Node).returns(PipelineHost::PipelineSourceShape) }
  def pipeline_source_shape(source_node)
    PipelineSourceShape.new(
      type: Type.from_node!(source_node, context: "pipeline source shape"),
      bc_target: bc_target?,
      named_source: source_node.is_a?(AST::Identifier)
    )
  end

  # Generic pipeline-terminal observable lowering. SUM/COUNT/MAX/MIN/
  # AVG/ANY/ALL/FIND/REDUCE-scalar all share the same scaffold:
  #
  #   1. Heap-allocate `*Observable<Terminal>` + a WaitGroup, wire the
  #      WG into the observable's completion callback.
  #   2. Spawn a consumer fiber cross-scheduler whose body pulls from
  #      `gen` and publishes each item to the accumulator.
  #   3. Return the accumulator pointer to the surrounding BlockExpr.
  #
  # Per-terminal differences are isolated to TWO inputs:
  #
  #   - `acc_alloc_zig`: the Zig expression that constructs the wrapper
  #     (typically `WrapperT.new(rt.heapAlloc()) catch unreachable`,
  #     but seeded variants like REDUCE pass `WrapperT.newWith(...)`).
  #   - `publish_stmts`: the MIR statements that publish one item to
  #     the accumulator. Each terminal builds its own (e.g. SUM emits
  #     `acc.inner.add(expr)`; COUNT emits `if pred then acc.inner.inc()`;
  #     ANY/ALL emit `acc.inner.submit(pred_eval)`; ...). The wrapper
  #     does not expose `add`/`inc`/`submit`/`update` -- consumers go
  #     through `acc.inner` so ObservableTerminal stays per-terminal
  #     surface-free.
  sig { params(p: T::Hash[T.untyped, T.untyped], smooth_node: AST::BinaryOp, label: String, source_node: AST::Node, acc_alloc_zig: String, publish_stmts: T::Array[T.untyped]).returns(MIR::BlockExpr) }
  def lower_range_fold_observable(p, smooth_node, label, source_node,
                                  acc_alloc_zig:, publish_stmts:)
    range_next = MIR::MethodCall.new(MIR::Ident.new(p[:source_name]), p[:next_method], [], true, MIR::CallableContract.no_ownership(0))
    capture_name = p[:initial_capture]

    # Zig type of the wrapper, sourced from the binding's full_type.
    # Type#zig_type switches on `observable_terminal` to pick
    # ObservableSum / ObservableCount / etc. -- single source of truth.
    obs_zig    = transpile_type(smooth_node.full_type!)            # "*CheatLib.obs.ObservableSum(i64)"
    obs_zig    = obs_zig.sub(/\Aconst\s+/, '')                    # defensive
    # Source type comes from the already-lowered source binding, not the
    # surface CLEAR type. `~Int64[]` may lower to IntRange or Stream(i64)
    # depending on the producer; @TypeOf(source) is the authoritative Zig fact.
    source_zig = "@TypeOf(#{p[:source_name]})"
    rt_name    = @do_rt_name || "rt"

    # Heap-allocate the observable accumulator + a WaitGroup, then
    # wire the WG into the observable's completion callback. The
    # producer fiber's `defer ctx.acc.finish()` issues `wg.done()`;
    # joiners (`NEXT running` / `|> COLLECT`) park on `wg.wait()`.
    # observable.zig stays runtime-free -- the WG bridge lives in
    # runtime-header.zig (CheatHeader.obsWg*).
    # H9: every InlineZig that allocates carries a stdlib_def so the MIR
    # checker can see the ownership effect. The observable's `:observable`
    # cleanup template owns both the wrapper and the WaitGroup it wraps
    # (destroy() forwards via done_destroy_fn), so neither needs a
    # separate MIR::Cleanup -- but the `allocates: true` declaration
    # makes the heap touch explicit instead of slipping past INV-12.
    acc_alloc = MIR::InlineZig.new(acc_alloc_zig, "obs_alloc")
    acc_alloc.stdlib_def = ALLOCATING_DEF
    acc_alloc.allocs = MIR.inline_alloc_metadata(alloc: :heap)
    acc_alloc.target_var = "__obs_acc"
    wg_init = MIR::HeapCreate.new(
      "CheatHeader.WaitGroup",
      MIR::InlineZig.new("CheatHeader.WaitGroup.init(#{rt_name}.getSched())", "obs_wg_init", MIR::OwnershipContract.empty, ALLOC_REF_DEF),
      :heap,
      "__obs_wg_alloc"
    )
    set_completion = MIR::InlineZig.new(
      "__obs_acc.setCompletion(@as(*anyopaque, @ptrCast(__obs_wg)), CheatHeader.obsWgDone, CheatHeader.obsWgWait, CheatHeader.obsWgDestroy)",
      "obs_set_completion")
    # setCompletion mutates __obs_acc to take ownership of __obs_wg; no
    # net allocation here. Borrows both pointers.
    set_completion.stdlib_def = ALLOC_REF_DEF
    set_completion.ownership_contract = MIR::OwnershipContract.consume_operands([
      MIR::OwnershipOperandFact.owned_binding("__obs_wg", Type.new(:"CheatHeader.WaitGroup", layout: :indirect), "observable completion", :heap),
    ])
    wg_alloc_mark = MIR::AllocMark.new("__obs_wg", :heap,
      Type.new(:"CheatHeader.WaitGroup", layout: :indirect))
    wg_alloc_mark.scope = :heap
    acc_alloc_mark = MIR::AllocMark.new("__obs_acc", :heap, Type.new(obs_zig))
    acc_alloc_mark.scope = :heap
    acc_init_stmts = [
      *([p[:range_let]].compact), *p[:outer_stmts],
      acc_alloc_mark,
      MIR::Let.new("__obs_acc", acc_alloc, false, obs_zig, nil),
      wg_alloc_mark,
      MIR::Let.new("__obs_wg", wg_init,
        false, "*CheatHeader.WaitGroup", nil),
      MIR::ExprStmt.new(MIR::MethodCall.new(MIR::Ident.new("__obs_wg"), "add", [MIR::Lit.new("1")], false,
        MIR::CallableContract.no_ownership(1)), nil),
      MIR::ExprStmt.new(set_completion, nil),
    ]

    # Consumer fiber body: while-consume + per-item publish stmts.
    # The defer in the spawn scaffold's run() fn handles `acc.finish()`
    # on every exit path (normal end, error, early-exit), so we don't
    # emit a post-loop finish here -- doing so would double-decrement
    # the observable's WaitGroup and corrupt joiner wake state.
    body_mir = [
      MIR::WhileStmt.new(range_next,
        [*p[:stage_stmts], *publish_stmts],
        capture_name, nil, nil, nil),
    ]

    # Generate per-call ids so two observable pipes in one fn don't
    # collide on struct/ctx names.
    fid = (@lowering.instance_variable_get(:@bg_block_counter) || 0)
    @lowering.instance_variable_set(:@bg_block_counter, fid + 1)
    ctx_type = "__ObsConsumerCtx#{fid}"
    ctx_var  = "__obs_consumer_ctx#{fid}"
    fiber_rt = "__rt_obs_#{fid}"

    # Emit the body MIR as Zig, then post-process to rewrite
    # outer-scope identifiers to their ctx-scoped equivalents. The
    # rewrite is textual: lower_bg_block's with_fiber_capture_map
    # operates during lower() (AST→MIR) and doesn't apply when MIR
    # is constructed directly (as we do here). \b word boundaries
    # avoid clobbering substrings.
    #
    # C8 partial: the runtime-name rewrite is now done via the
    # emitter's `rt_name` swap rather than a textual gsub on the
    # emitted Zig. This eliminates the most fragile of the three
    # rewrites (the gsub for `\brt\b` could in principle match any
    # user-named identifier with the bytes "rt"; swapping rt_name
    # during emit produces fiber-scoped `__rt_obs_N.X` directly).
    # The remaining two gsubs target reserved-prefix names
    # (`__obs_acc`) or a generated source-name local, both safely
    # under the codegen's namespace; replacing them with a true MIR
    # walker remains future work because no general-purpose tree
    # mutator exists in this codebase yet.
    # The body emits through `@lowering.emit_expr` which sets its own
    # internal emitter's rt_name from `@lowering.rt_name` on every
    # call. Swapping `@emitter.rt_name` is insufficient -- swap the
    # lowering's `@rt_name` too so AllocatorRef / alloc_zig / and any
    # other rt-aware emitter codepath produce fiber-scoped names.
    saved_emit_rt = @emitter.rt_name
    saved_low_rt  = @lowering.instance_variable_get(:@rt_name)
    @emitter.rt_name = fiber_rt
    @lowering.instance_variable_set(:@rt_name, fiber_rt)
    body_zig = begin
      body_mir.filter_map { |m|
        code = @lowering.send(:emit_expr, m)
        next nil if code.nil? || code.empty?
        code.strip.end_with?("}", ";") ? code : "#{code};"
      }.join("\n            ")
    ensure
      @emitter.rt_name = saved_emit_rt
      @lowering.instance_variable_set(:@rt_name, saved_low_rt)
    end
    body_zig = body_zig
      .gsub(/\b__obs_acc\b/, "ctx.acc")
      .gsub(/\b#{Regexp.escape(p[:source_name])}\b/, "ctx.gen")

    # Spawn the consumer on the source scheduler. Observable terminal
    # consumers are tightly coupled to their source Stream; keeping both
    # sides local avoids cross-scheduler stream waiter handoff on the
    # hot path and lets producer/consumer/main make cooperative progress
    # through the scheduler's normal yield points.
    task_cfg = @lowering.send(:task_config_zig, nil, nil)

    spawn_zig = <<~ZIG.chomp
      const #{ctx_type} = struct {
              acc: #{obs_zig},
              gen: #{source_zig},
              fn run(__raw_rt_obs_#{fid}: *anyopaque, __raw_args_obs_#{fid}: ?*anyopaque) anyerror!void {
                  const #{fiber_rt} = @as(*Runtime, @ptrCast(@alignCast(__raw_rt_obs_#{fid})));
                  #{body_zig.include?(fiber_rt) ? "" : "_ = &#{fiber_rt};"}
                  const ctx = @as(*@This(), @ptrCast(@alignCast(__raw_args_obs_#{fid}.?)));
                  defer ctx.acc.finish();
                  #{body_zig}
              }
          };
          try CheatHeader.spawnObservableConsumerCtx(
              #{ctx_type},
              #{rt_name},
              .{ .acc = __obs_acc, .gen = #{p[:source_name]} },
              @as(CheatHeader.TaskFn, @ptrCast(&#{ctx_type}.run)),
              #{task_cfg}
          )
    ZIG

    spawn_inline = MIR::InlineZig.new(spawn_zig, "obs_consumer_spawn")
    # spawn_inline allocates the consumer-fiber ctx (heapAlloc().create)
    # and transfers ownership to the spawned fiber. The fiber's run() has
    # `defer rt.heapAlloc().destroy(ctx)` and the alloc site itself has
    # `errdefer rt.heapAlloc().destroy(ctx_var)` so cleanup is closed-form
    # within this block. From outside, it's a no-net-allocation effect:
    # mark as borrowing the allocator + ctx-init args. (H9)
    spawn_inline.stdlib_def = ALLOC_REF_DEF
    spawn_inline.ownership_contract = MIR::OwnershipContract.consume_operands([
      MIR::OwnershipOperandFact.owned_binding(p[:source_name].to_s, Type.new(:Any), "observable consumer spawn", :heap),
    ])

    MIR::BlockExpr.new(label, [
      *acc_init_stmts,
      MIR::ExprStmt.new(spawn_inline, nil),
      MIR::BreakStmt.new(label, MIR::Ident.new("__obs_acc"))
    ])
  end

  # Per-terminal publish specs for default-init observables. Each
  # terminal contributes only:
  #   - `:method`       -- the Inner accumulator's publish method name
  #                        (`add` / `inc` / `submit`).
  #   - `:expr`         -- :typed (numeric coerced to inner Zig type) /
  #                        :f64 (numeric coerced to f64, AVG-style) /
  #                        :pred (boolean predicate evaluated as-is) /
  #                        :item (the raw item, no expression eval) /
  #                        :none (no argument; method takes nothing).
  #   - `:gate`         -- :always (publish unconditionally) /
  #                        :pred (publish only when the predicate is true;
  #                        the predicate IS the fold expression and is
  #                        not passed to the publish method).
  # Allocator is the default `Wrapper.new(...)` -- terminals needing a
  # seeded init (REDUCE, DISTINCT) take their own dedicated path.
  #
  # A3: derived from Type.observable_terminals (the single source of
  # truth). Adding a default-handled terminal means one entry there;
  # this projection picks up the :publish key automatically.
  PUBLISH_SPEC = T.let(Type.observable_terminals.each_with_object({}) { |(sym, entry), h|
    h[sym] = PipelinePublishSpec.from(T.cast(entry[:publish], T::Hash[Symbol, T.untyped])) if entry[:publish]
  }.freeze, T::Hash[Symbol, PipelinePublishSpec])

  # Single shared lowering for SUM/COUNT/MAX/MIN/AVG/ANY/ALL/FIND.
  # REDUCE and DISTINCT need seeded inits or inline CAS, so they keep
  # dedicated helpers below.
  sig { params(p: T::Hash[T.untyped, T.untyped], fold_op: T.untyped, smooth_node: AST::BinaryOp, label: String, source_node: AST::Node, terminal: Symbol).returns(MIR::BlockExpr) }
  def lower_range_fold_observable_default(p, fold_op, smooth_node, label, source_node, terminal:)
    spec  = PUBLISH_SPEC.fetch(terminal)
    source_elem = source_node.full_type!(context: "observable pipeline source").tense_type&.element_type
    item  = p[:item_var]
    inner_recv = MIR::FieldGet.new(MIR::Ident.new("__obs_acc"), "inner")

    arg = case spec.expr
          when :typed
            inner_zig = transpile_type(smooth_node.full_type!.tense_type)
            [numeric_fold_expr_typed(fold_op.expression, item, inner_zig)]
          when :f64
            [numeric_fold_expr_typed(fold_op.expression, item, "f64")]
          when :pred
            [with_pipeline_context(placeholder: item) { visit_mir(fold_op.expression) }]
          when :item
            [MIR::Ident.new(item)]
          when :none
            []
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
      MIR::CallableContract.no_ownership(T.must(arg).length)
    end
    call = MIR::ExprStmt.new(
      MIR::MethodCall.new(inner_recv, spec.publish_method, T.must(arg), false, callable_contract), nil)

    source_type = source_node.full_type!(context: "observable pipeline source cleanup")
    item_cleanup = consumed_stream_item_cleanup(p, source_node)
    publish = case spec.gate
              when :always
                [call, *item_cleanup]
              when :pred
                pred_mir = with_pipeline_context(placeholder: item) {
                  visit_mir(fold_op.expression)
                }
                if spec.transfers_item_on_success
                  [MIR::IfStmt.new(pred_mir, [call], item_cleanup)]
                else
                  [MIR::IfStmt.new(pred_mir, [call], nil), *item_cleanup]
                end
              end

    lower_range_fold_observable(p, smooth_node, label, source_node,
      acc_alloc_zig: default_obs_alloc_zig(smooth_node),
      publish_stmts: T.must(publish))
  end

  sig { params(type_info: Type).returns(T::Boolean) }
  def pipeline_element_owns_heap?(type_info)
    type_info.string? ||
      type_info.heap_ptr? ||
      type_info.recursive_cleanup_shape?(pipeline_schema_lookup) ||
      type_info.needs_explicit_cleanup?(:heap, pipeline_schema_lookup)
  end

  sig { params(p: T::Hash[T.untyped, T.untyped], source_node: AST::Node).returns(T::Array[T.untyped]) }
  def consumed_stream_item_cleanup(p, source_node)
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
        MIR::OwnershipOperandFact.owned_binding(p[:item_var].to_s, elem_t, "pipeline item cleanup", :heap),
      ]),
      3,
    )
    [MIR::ExprStmt.new(
      MIR::Call.new("CheatLib.cleanup", [
        MIR::Ident.new("@TypeOf(#{p[:item_var]})"),
        MIR::AllocatorRef.new(:heap),
        MIR::AddressOf.new(MIR::Ident.new(p[:item_var])),
      ], false, false, contract),
      nil,
    )]
  end

  # REDUCE-scalar: per-item publish is a CAS loop that applies the
  # user-supplied reducer body. We emit the loop inline (rather than
  # using AtomicReduce.update + a comptime fn pointer) because the
  # reducer body references stage-context (`_` and `acc`), which is
  # easier to inline than to lift into a top-level Zig fn.
  #
  # Wrapper: `*ObservableReduce(T)` -- the Inner is `AtomicReduce(T)`
  # which needs a seeded init(initial). Caller passes `newWith(...)`.
  sig { params(p: T::Hash[T.untyped, T.untyped], reduce_op: AST::ReduceOp, smooth_node: AST::BinaryOp, label: String, source_node: AST::Node).returns(MIR::BlockExpr) }
  def lower_range_reduce_observable(p, reduce_op, smooth_node, label, source_node)
    inner_zig = transpile_type(smooth_node.full_type!.tense_type)
    init_mir  = visit_mir(reduce_op.initial_value)
    init_zig  = @lowering.send(:emit_expr, init_mir)

    # Use a fid-prefixed sentinel for the `acc` substitution so
    # nothing in the user's reducer body can collide. Two REDUCE
    # pipes in the same fn pick different fids → different sentinels;
    # any user identifier `__obs_reduce_curr_<N>` would have to
    # collide on the exact same N to interfere.
    fid = (@lowering.instance_variable_get(:@bg_block_counter) || 0)
    curr_var = "__obs_reduce_curr_#{fid}"
    next_var = "__obs_reduce_next_#{fid}"
    actual_var = "__obs_reduce_actual_#{fid}"
    blk_label = "__obs_reduce_blk_#{fid}"

    body_mir = with_pipeline_context(placeholder: p[:item_var], acc: curr_var) {
      visit_mir(reduce_op.expression)
    }
    body_zig = @lowering.send(:emit_expr, body_mir)

    # Inline CAS-loop publish, wrapped as a labeled block expression so
    # ExprStmt's trailing `;` is well-formed (`(blk: { ... break :blk 0; });`).
    # References `__obs_acc` so the surrounding lower_range_fold_observable
    # text-rewrite (-> ctx.acc) catches it.
    #
    # A4: routes through AtomicReduce's public `view`/`tryCommit`/`markSeen`
    # methods instead of poking the private `inner.inner.load`,
    # `inner.inner.cmpxchgWeak`, and `inner.seen.store` fields. Also
    # picks up the .release ordering on markSeen (was .monotonic, a
    # latent ordering bug since a reader's `started()` acquire-load
    # didn't synchronize-with the publish).
    cas_zig = <<~ZIG.chomp
      #{blk_label}: {
                  var #{curr_var}: #{inner_zig} = __obs_acc.inner.view();
                  while (true) {
                      const #{next_var}: #{inner_zig} = #{body_zig};
                      if (__obs_acc.inner.tryCommit(#{curr_var}, #{next_var})) |#{actual_var}| {
                          #{curr_var} = #{actual_var};
                      } else { break; }
                  }
                  __obs_acc.inner.markSeen();
                  break :#{blk_label} @as(i32, 0);
              }
    ZIG
    publish = [MIR::ExprStmt.new(MIR::InlineZig.new(cas_zig, "obs_reduce_publish"), true)]

    rt_name = @do_rt_name || "rt"
    obs_target = transpile_type(smooth_node.full_type!).sub(/\A\*/, '')
    acc_alloc = "#{obs_target}.newWith(#{rt_name}.heapAlloc(), CheatLib.obs.AtomicReduce(#{inner_zig}).init(#{init_zig})) catch unreachable"

    lower_range_fold_observable(p, smooth_node, label, source_node,
      acc_alloc_zig: acc_alloc,
      publish_stmts: publish)
  end

  # DISTINCT into ~T[]@set:observable (dynamic) or ~T[N]@set:observable
  # (bounded). Inner is `StreamSet(T)` for the dynamic shape (geometric
  # grow + refcounted snapshots) or `StreamSetBounded(T, N)` for the
  # bounded shape (fixed [N]T buffer, no grow, no refcounting). Both
  # take an allocator -- non-default-init Inner -- so we use newWith(...).
  # Per-item publish:
  #   - dynamic:  `_ = acc.inner.submit(item) catch unreachable`  (fallible: grow can fail)
  #   - bounded:  `_ = acc.inner.submit(item)`                    (infallible: no grow path)
  sig { params(p: T::Hash[T.untyped, T.untyped], distinct_op: AST::DistinctOp, smooth_node: AST::BinaryOp, label: String, source_node: AST::Node).returns(MIR::BlockExpr) }
  def lower_range_fold_observable_distinct(p, distinct_op, smooth_node, label, source_node)
    key_expr_mir = with_pipeline_context(placeholder: p[:item_var]) {
      visit_mir(distinct_op.expression)
    }
    rt_name      = @do_rt_name || "rt"
    obs_zig      = transpile_type(smooth_node.full_type!)        # "*CheatLib.obs.ObservableStreamSet(i64)" or "*CheatLib.obs.ObservableStreamSetBounded(i64, 8)"
    target       = obs_zig.sub(/\A\*/, '')
    set_type     = smooth_node.full_type!.tense_type
    elem_zig     = transpile_type(set_type.element_type)
    is_bounded   = set_type.fixed?
    cap          = set_type.capacity

    submit_call = "_ = __obs_acc.inner.submit(#{@lowering.send(:emit_expr, key_expr_mir)})"
    submit_call = "#{submit_call} catch unreachable" unless is_bounded
    publish = [
      MIR::ExprStmt.new(MIR::InlineZig.new(submit_call, "obs_distinct_publish"), nil),
    ]

    inner_ctor = if is_bounded
      "CheatLib.obs.StreamSetBounded(#{elem_zig}, #{cap}).init(#{rt_name}.heapAlloc()) catch unreachable"
    else
      "CheatLib.obs.StreamSet(#{elem_zig}).init(#{rt_name}.heapAlloc()) catch unreachable"
    end

    lower_range_fold_observable(p, smooth_node, label, source_node,
      acc_alloc_zig: "#{target}.newWith(#{rt_name}.heapAlloc(), #{inner_ctor}) catch unreachable",
      publish_stmts: publish)
  end

  # Default-init Observable<Terminal>.new allocator call. The wrapper Zig
  # type comes from Type#zig_type via smooth_node.full_type!, so terminals
  # whose Inner default-constructs (SUM/COUNT/AVG/ANY/ALL/FIND) all share
  # this one builder. MAX/MIN/REDUCE need a seeded init -- they pass
  # their own `acc_alloc_zig`.
  sig { params(smooth_node: AST::BinaryOp).returns(String) }
  def default_obs_alloc_zig(smooth_node)
    rt_name = @do_rt_name || "rt"
    target  = transpile_type(smooth_node.full_type!).sub(/\A\*/, '')
    "#{target}.new(#{rt_name}.heapAlloc()) catch unreachable"
  end

  # Single source of truth mapping fold-op AST class to its observable
  # terminal kind. Replaces the per-case `if observable_dest` branches
  # that previously duplicated the dispatch shape eight times in
  # lower_range_fold (H8 / M6).
  #
  # A3: derived from Type.observable_terminals; entries without an
  # `:ast_class` (REDUCE / DISTINCT) are skipped — they have their own
  # lowering helpers and never hit the default fold-op dispatch.
  FOLD_OP_OBSERVABLE_TERMINAL = T.let(Type.observable_terminals.each_with_object({}) { |(sym, entry), h|
    h[entry[:ast_class]] = sym if entry[:ast_class]
  }.freeze, T::Hash[T.untyped, T.untyped])

  # Emit a single fused accumulating while loop for range |> stages |> fold.
  # fold_op is one of CountOp, SumOp, AverageOp, AnyOp, AllOp, FindOp, MinOp, MaxOp.
  # Returns a MIR::BlockExpr (labeled) so the accumulated result can be used as an expression.
  sig { params(range_lit: T.untyped, stages: T::Array[T.untyped], fold_op: T.untyped, smooth_node: AST::BinaryOp).returns(MIR::BlockExpr) }
  def lower_range_fold(range_lit, stages, fold_op, smooth_node)
    p = build_lazy_range_prefix(range_lit, stages)
    item_var   = p[:item_var]
    elem_zig   = p[:elem_zig]
    range_next = MIR::MethodCall.new(MIR::Ident.new(p[:source_name]), p[:next_method], [], true, MIR::CallableContract.no_ownership(0))

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

    # Observable destination: dispatch through the central terminal-kind
    # registry instead of repeating an `if observable_dest` arm in every
    # `case fold_op` branch (H8). Adding a new terminal is then one
    # FOLD_OP_OBSERVABLE_TERMINAL entry plus the per-terminal accumulator
    # builder, with no per-shape codegen branch here.
    if smooth_node.observable_dest
      terminal = FOLD_OP_OBSERVABLE_TERMINAL[fold_op.class]
      if terminal.nil?
        raise CompilerError.new(
          range_lit.token,
          "lower_range_fold: observable_dest set but no terminal registered for #{fold_op.class.name}",
          nil,
        )
      end
      return lower_range_fold_observable_default(
        p, fold_op, smooth_node, label, range_lit, terminal: terminal,
      )
    end

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
      acc_zig  = transpile_type(smooth_node.full_type!.to_s)  # already upsized by pipe_analysis
      expr_mir = numeric_fold_expr_typed(fold_op.expression, item_var, acc_zig)
      acc_init_stmts << MIR::Let.new(fold_acc, MIR::Lit.new("0"), true, acc_zig, nil)
      loop_acc_stmts << MIR::Set.new(MIR::Ident.new(fold_acc),
        MIR::BinOp.new("+", MIR::Ident.new(fold_acc), expr_mir))
      result_expr = MIR::Ident.new(fold_acc)

    when AST::AverageOp
      expr_f64 = numeric_fold_expr_typed(fold_op.expression, item_var, "f64")
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
      expr_sym = smooth_node.full_type!.resolved  # exact type set by pipe_analysis
      acc_zig  = transpile_type(smooth_node.full_type!.to_s)
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
      expr_sym = smooth_node.full_type!.resolved  # exact type set by pipe_analysis
      acc_zig  = transpile_type(smooth_node.full_type!.to_s)
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
      # Element type after stages: derive from smooth_node.full_type! (?ElemType)
      result_ft = Type.new(smooth_node.full_type!)
      find_zig  = result_ft.optional? ? transpile_type(T.must(result_ft.wrapped_type).resolved.to_s) : elem_zig
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
    source_ti = range_lit.full_type!
    defer_deinit = source_ti&.bounded_stream? ?
      MIR::DeferStmt.new(MIR::MethodCall.new(MIR::Ident.new(p[:source_name]), "deinit", [], false, MIR::CallableContract.no_ownership(0))) :
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
       (range_lit.full_type!.dynamic_stream? || range_lit.full_type!.bounded_stream? ||
        range_lit.full_type!.inf_stream?)
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

  # Emit a single fused accumulating while loop for range |> stages |> REDUCE(init) body.
  # Returns a MIR::BlockExpr so the accumulated result can be used as an expression.
  sig { params(range_lit: T.untyped, stages: T::Array[T.untyped], reduce_op: AST::ReduceOp, smooth_node: T.nilable(AST::BinaryOp)).returns(MIR::BlockExpr) }
  def lower_range_reduce(range_lit, stages, reduce_op, smooth_node = nil)
    p = build_lazy_range_prefix(range_lit, stages)
    item_var   = p[:item_var]
    range_next = MIR::MethodCall.new(MIR::Ident.new(p[:source_name]), p[:next_method], [], true, MIR::CallableContract.no_ownership(0))

    if smooth_node && smooth_node.respond_to?(:observable_dest) && smooth_node.observable_dest
      label = next_pipe_label
      return lower_range_reduce_observable(p, reduce_op, smooth_node, label, range_lit)
    end

    label    = next_pipe_label
    acc_zig  = transpile_type(reduce_op.full_type!.to_s)
    init_mir = visit_mir(reduce_op.initial_value)
    expr_mir = with_pipeline_context(placeholder: item_var, acc: "acc") {
      visit_mir(reduce_op.expression)
    }

    source_ti = range_lit.full_type!
    defer_deinit = source_ti&.bounded_stream? ?
      MIR::DeferStmt.new(MIR::MethodCall.new(MIR::Ident.new(p[:source_name]), "deinit", [], false, MIR::CallableContract.no_ownership(0))) :
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
       (range_lit.full_type!.dynamic_stream? || range_lit.full_type!.bounded_stream? ||
        range_lit.full_type!.inf_stream?)
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

  # CONCURRENT pipeline: supported shapes lower through structural MIR or
  # runtime-backed InlineZig calls. Falling through here is now a migration bug.
  sig { params(site: PipelineHost::PipelineSite, conc_op: AST::ConcurrentOp).returns(T.untyped) }
  def lower_concurrent(site, conc_op)
    _lhs = site.list
    smooth_node = site.options
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
    # (sum/count/min/max) don't care.
    if bc_target?
      lhs_ti = smooth_node.left.full_type!
      stream_lhs = lhs_ti && (lhs_ti.dynamic_stream? || lhs_ti.bounded_stream? ||
                              lhs_ti.open_stream? || lhs_ti.inf_stream?)
      return lower_concurrent_bc(smooth_node.left, conc_op, smooth_node) unless stream_lhs
    end

    if !smooth_node.left.is_a?(AST::RangeLit) && smooth_node.left.full_type!.bounded_stream?
      return lower_concurrent_bounded_stream(smooth_node.left, conc_op)
    end

    # Dynamic / infinite / open stream sources: structural lowering for
    # both backends. The MIR call routes to CheatLib.concurrentStreamSelect
    # (Zig: real feeder + worker fibers via BoundedChannel) or to
    # compile_concurrent_stream (BC: sequential simulation via .next()).
    lhs_ti = smooth_node.left.full_type!
    stream_lhs = !smooth_node.left.is_a?(AST::RangeLit) &&
      lhs_ti && (lhs_ti.dynamic_stream? || lhs_ti.open_stream? || lhs_ti.inf_stream?)
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
    # the BC short-circuit above). `list AS $u |> CONCURRENT ...` is
    # supported: extract the binding name and run the callback body
    # lowering with `$u` registered to resolve to `__item`.
    if @lowering.instance_variable_get(:@target) != :bc
      lhs_node = smooth_node.left
      bind_name = nil
      real_lhs = lhs_node
      if lhs_node.is_a?(AST::BinaryOp) && lhs_node.op == :BIND_VAR
        bind_name = lhs_node.right.name
        real_lhs = lhs_node.left
      end
      real_lhs_ti = real_lhs.full_type!
      if concurrent_range_runtime_source?(real_lhs) ||
         (real_lhs_ti && concurrent_list_runtime_source?(real_lhs_ti))
        case conc_op.op
        when AST::SelectOp
          return with_optional_named_binding(bind_name, "__item") {
            lower_concurrent_list_select(real_lhs, conc_op, conc_op.op)
          }
        when AST::WhereOp
          return with_optional_named_binding(bind_name, "__item") {
            lower_concurrent_list_where(real_lhs, conc_op, conc_op.op)
          }
        when AST::CountOp
          return with_optional_named_binding(bind_name, "__item") {
            lower_concurrent_list_count(real_lhs, conc_op, conc_op.op)
          }
        when AST::SumOp, AST::AverageOp, AST::MinOp, AST::MaxOp
          return with_optional_named_binding(bind_name, "__item") {
            lower_concurrent_list_reduce(real_lhs, conc_op, conc_op.op, smooth_node)
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

    inner = conc_op.op
    lhs_type = smooth_node.left.full_type!
    raise "lower_concurrent: unsupported non-legacy CONCURRENT shape lhs=#{smooth_node.left.class} lhs_type=#{lhs_type&.class} op=#{inner.class}"
  end

  sig { params(lhs_type: T.untyped).returns(T::Boolean) }
  def concurrent_list_runtime_source?(lhs_type)
    return false if lhs_type.dynamic_stream? || lhs_type.bounded_stream? ||
                    lhs_type.open_stream? || lhs_type.inf_stream?
    lhs_type.respond_to?(:element_type) && !lhs_type.element_type.nil?
  end

  sig { params(lhs: T.untyped).returns(T::Boolean) }
  def concurrent_range_runtime_source?(lhs)
    lhs.is_a?(AST::RangeLit)
  end

  # BC sequential simulation of CONCURRENT. Strips the CONCURRENT wrapper
  # (workers/parallel/capacity options become no-ops) and redispatches the
  # inner op as a regular pipeline. OR PRUNE inside the inner expression
  # gets explicit isError checking because the standard SELECT auto-tries
  # failable expressions, which would propagate errors instead of skipping.
  #
  # When `lhs` is `BIND_VAR(source, $u)`, register $u as an alias for the
  # pipeline iterator "it" and use the unwrapped source as the actual
  # data source. This makes `users AS $u |> CONCURRENT SELECT $u.field`
  # work: substitute_placeholders rewrites $u to it inside the inner
  # expression at MIR-build time.
  sig { params(lhs: T.untyped, conc_op: AST::ConcurrentOp, smooth_node: T.untyped).returns(FsmOps::CallExpr) }
  def lower_concurrent_bc(lhs, conc_op, smooth_node)
    inner = conc_op.op

    real_lhs = lhs
    bind_name = nil
    if lhs.is_a?(AST::BinaryOp) && lhs.op == :BIND_VAR
      bind_name = lhs.right.name
      real_lhs = lhs.left
    end

    real_site = PipelineSite.new(list: real_lhs, options: smooth_node)
    work = lambda do
      case inner
      when AST::SelectOp
        policy, inner_expr = extract_concurrent_error_policy_for_bc(inner.expression)
        next lower_bc_concurrent_select_prune(real_lhs, inner_expr, smooth_node) if policy == :prune
        lower_select(real_site, inner_expr)

      when AST::WhereOp
        policy, inner_expr = extract_concurrent_error_policy_for_bc(inner.expression)
        next lower_bc_concurrent_where_prune(real_lhs, inner_expr, smooth_node) if policy == :prune
        lower_where(real_site, inner_expr)

      when AST::EachOp
        lower_each(real_site, inner)

      when AST::SumOp     then lower_sum(real_site, inner)
      when AST::CountOp   then lower_count(real_site, inner)
      when AST::MinOp     then lower_min(real_site, inner)
      when AST::MaxOp     then lower_max(real_site, inner)
      when AST::AverageOp then lower_average(real_site, inner)
      when AST::AnyOp     then lower_any(real_site, inner)
      when AST::AllOp     then lower_all(real_site, inner)
      when AST::FindOp    then lower_find(real_site, inner)
      else
        raise "lower_concurrent_bc: unsupported inner op #{inner.class}"
      end
    end

    bind_name ? with_named_binding(bind_name, "it", &work) : work.call
  end

  # Peels OR PRUNE / OR RAISE from the inner pipeline expression for the
  # BC sequential simulation path.
  sig { params(expr: T.untyped).returns(T::Array[T.untyped]) }
  def extract_concurrent_error_policy_for_bc(expr)
    if expr.is_a?(AST::BinaryOp) && expr.op == :OR_RESCUE
      return [:prune, expr.left] if expr.right.is_a?(AST::OrPrune)
      return [:raise, expr.left] if expr.right.is_a?(AST::OrRaise)
    end
    [:default, expr]
  end

  # SHARD + CONCURRENT EACH.
  #
  # BC remains sequential because the VM has no scheduler ownership model.
  # Zig uses one bounded channel and one worker fiber per shard. The producer
  # computes the routing key/hash and enqueues an owned WorkItem; each worker
  # serially drains its shard and lowers the body in shard-direct mode so
  # map[k]/map[k]=v compile to getDirect/putDirect.
  sig { params(lhs: T.untyped, conc_op: AST::ConcurrentOp, smooth_node: T.untyped).returns(T.untyped) }
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
    # to ShardedMapPut/Get with shard_direct mode. Until the concurrent shard
    # runtime is exposed as typed MIR, lower this as a correctness-equivalent
    # structural loop so MIRChecker can verify ownership instead of accepting an
    # opaque allocator-bearing InlineZig blob.
    prev_ctx = @lowering.instance_variable_get(:@shard_context)
    @lowering.instance_variable_set(:@shard_context, nil)

    key_mir, key_pending, body_mir = nil, [], nil
    begin
      key_mir, key_pending = @lowering.send(:lower_head) {
        with_pipeline_context(placeholder: idx_var) {
        visit_mir(ctx[:key_expr])
        }
      }
      body_mir = visit_pipeline_body_mir(each_op.body, placeholder: key_var)
    ensure
      @lowering.instance_variable_set(:@shard_context, prev_ctx)
    end

    inner = []
    if !is_bc && ctx[:key_allocates_frame]
      # The key expression allocates from the frame arena (e.g. a string
      # concat). Save/restore per iteration so successive iterations
      # don't accumulate frame memory.
      inner.concat(shard_loop_mark_pair("__sh#{id}_loop_mark", @do_rt_name || "rt", tag: "shard_loop"))
    end
    inner.concat(key_pending)
    if @lowering.send(:mir_allocates?, key_mir) || (key_mir.is_a?(MIR::Call) && key_mir.owned_return?)
      key_type = Type.from_node!(ctx[:key_expr], context: "SHARD key binding")
      key_alloc = @lowering.send(:mir_owned_alloc, key_mir) || :heap
      key_mark = MIR::AllocMark.new(key_var, key_alloc, key_type)
      key_mark.scope = MIR::Placement.alloc_scope(key_alloc)
      inner << key_mark
      inner << MIR::Let.new(key_var, key_mir, false, nil, nil)
      cleanup = @lowering.send(:hoist_cleanup_entry, key_mir, ctx[:key_expr])
      inner << MIR::Cleanup.new(key_var, cleanup) if cleanup
    else
      inner << MIR::Let.new(key_var, key_mir, false, nil, nil)
    end
    inner.concat(body_mir)
    inner = @lowering.send(:append_ownership_transfers_for_mir_body, inner)

    # BC: ForStmt over IterRange (the VM iterates Int64 directly so the idx_var
    # binds an Int64). No map ptr setup, channels, or ensureOwnership.
    MIR::ForStmt.new(MIR::IterRange.new(start_mir, end_expr, :i64), idx_var, inner, nil)
  end

  sig { params(id: Integer, range_node: AST::RangeLit, conc_op: AST::ConcurrentOp, each_op: AST::EachOp, ctx: T::Hash[T.untyped, T.untyped], map_node: AST::Identifier, map_var_name: String, idx_var: String, key_var: String, sh_var: String, map_ptr: String, start_mir: MIR::Lit, end_mir: T.untyped).returns(MIR::InlineZig) }
  def lower_shard_concurrent_each_zig(id, range_node, conc_op, each_op, ctx,
                                      map_node, map_var_name, idx_var, key_var,
                                      sh_var, map_ptr, start_mir, end_mir)
    shard_count = ctx[:shard_count] || map_node.full_type!.shard_count
    raise "SHARD target missing shard_count" unless shard_count

    map_t = map_node.full_type!
    key_t = if map_t&.numeric_map? && map_t&.key_type
      map_t.key_type
    else
      Type.new(:String)
    end
    key_zig = key_t.zig_type
    string_key = !map_t&.numeric_map?

    start_zig = @lowering.send(:emit_expr, start_mir)
    end_zig   = @lowering.send(:emit_expr, end_mir)
    cap_mir = stream_concurrent_capacity_mir(conc_op, shard_count.to_s)
    cap_zig = @lowering.send(:emit_expr, cap_mir)
    batch_mir = bounded_concurrent_batch_mir(conc_op)
    batch_zig = @lowering.send(:emit_expr, batch_mir)
    task_cfg = task_config_zig(conc_op.options["size"]&.name&.downcase&.to_sym)

    key_mir = with_pipeline_context(placeholder: idx_var) { visit_mir(ctx[:key_expr]) }
    key_zig_expr = @lowering.send(:emit_expr, key_mir)

    caps = FiberCtxBuilder.build(conc_op.capture_analysis, body_access_prefix: "ctx")
    shard_map_field = "__shard_map"
    map_capture_map = map_var_name ? { map_var_name => "ctx.#{shard_map_field}.*" } : {}
    capture_fields_arr = ["        #{shard_map_field}: *@TypeOf(#{map_ptr}.*),"]
    capture_fields_arr.concat(caps.specs.map { |s| "        #{s.name}: #{s.field_type_zig}," })
    capture_fields = capture_fields_arr.join("\n")
    capture_inits = [".#{shard_map_field} = #{map_ptr}"] + caps.specs.map { |s| ".#{s.name} = #{s.init_value_zig}" }
    capture_inits_str = capture_inits.empty? ? "" : ", #{capture_inits.join(", ")}"

    prev_ctx = @lowering.instance_variable_get(:@shard_context)
    body_mir = nil
    begin
      @lowering.instance_variable_set(:@shard_context, {
        map: map_var_name,
        idx: "ctx.shard",
        key: key_var,
        hash: "0"
      })
      body_mir = with_pipeline_context(placeholder: key_var) do
        with_fiber_capture_map(map_capture_map.merge(caps.capture_map), capture_symbols: caps.capture_symbols, rt_override: "__rt") do
          visit_pipeline_body_mir(each_op.body, placeholder: key_var)
        end
      end
    ensure
      @lowering.instance_variable_set(:@shard_context, prev_ctx)
    end

    saved_low_rt = @lowering.instance_variable_get(:@rt_name)
    @lowering.instance_variable_set(:@rt_name, "__rt")
    body_zig = begin
      body_mir.filter_map { |m|
        code = @lowering.send(:emit_expr, m)
        next nil if code.nil? || code.empty?
        code.strip.end_with?("}", ";") ? code : "#{code};"
      }.join("\n                    ")
    ensure
      @lowering.instance_variable_set(:@rt_name, saved_low_rt)
    end

    key_loop_mark = ctx[:key_allocates_frame] ?
      shard_loop_mark_string("__sh#{id}_key_mark", "rt") : ""
    body_loop_mark = ctx[:body_allocates_frame] ?
      shard_loop_mark_string("__sh#{id}_body_mark", "__rt", indent: " " * 22) : ""
    key_store_expr = string_key ? "try rt.heapAlloc().dupe(u8, #{key_var})" : key_var
    key_free_work = if string_key
      "for (__work.keys) |__k| __rt.heapAlloc().free(__k);\n                  __rt.heapAlloc().free(__work.keys);"
    else
      "__rt.heapAlloc().free(__work.keys);"
    end
    key_free_success = string_key ? "__rt.heapAlloc().free(#{key_var});" : ""
    key_free_remaining = string_key ? "errdefer for (__work.keys[__sh#{id}_ki..]) |__k| __rt.heapAlloc().free(__k);" : ""
    key_slice_cleanup = string_key ? "for (__sh#{id}_keys) |__k| rt.heapAlloc().free(__k);" : ""
    pending_batch_cleanup = string_key ? "for (__sh#{id}_batches[__s].items) |__k| rt.heapAlloc().free(__k);" : ""
    channel_buffer_cleanup = if string_key
      <<~ZIG.chomp
        fn cleanupBuffered(chan: *CheatLib.BoundedChannel(__ShWork#{id}), __rt: *Runtime) void {
                          const inner = chan.inner;
                          inner.mutex.lock();
                          while (inner.tail != inner.head) {
                              const __work = inner.buf[inner.tail & inner.mask];
                              inner.tail += 1;
                              for (__work.keys) |__k| __rt.heapAlloc().free(__k);
                              __rt.heapAlloc().free(__work.keys);
                          }
                          inner.mutex.unlock();
                      }
      ZIG
    else
      <<~ZIG.chomp
        fn cleanupBuffered(chan: *CheatLib.BoundedChannel(__ShWork#{id}), __rt: *Runtime) void {
                          const inner = chan.inner;
                          inner.mutex.lock();
                          while (inner.tail != inner.head) {
                              const __work = inner.buf[inner.tail & inner.mask];
                              inner.tail += 1;
                              __rt.heapAlloc().free(__work.keys);
                          }
                          inner.mutex.unlock();
                      }
      ZIG
    end
    op_str = range_node.inclusive ? "<=" : "<"

    code = <<~ZIG.chomp
      {
          const #{map_ptr} = &#{@lowering.send(:emit_expr, visit_mir(map_node))};
          #{map_ptr}.ensureOwnership();
          const __sh#{id}_cap: usize = #{cap_zig};
          const __sh#{id}_batch: usize = @max(@as(usize, #{batch_zig}), 1);
          const __ShWork#{id} = struct {
              keys: []#{key_zig},
          };
          const __ShCleanup#{id} = struct {
              #{channel_buffer_cleanup}
          };
          var __sh#{id}_chans: [#{shard_count}]CheatLib.BoundedChannel(__ShWork#{id}) = undefined;
          for (0..#{shard_count}) |__s| {
              __sh#{id}_chans[__s] = try CheatLib.BoundedChannel(__ShWork#{id}).init(rt.heapAlloc(), __sh#{id}_cap);
          }
          defer for (0..#{shard_count}) |__s| __sh#{id}_chans[__s].deinit();

          var __sh#{id}_wg = CheatHeader.WaitGroup.init(rt.getSched());
          var __sh#{id}_err = std.atomic.Value(bool).init(false);
          const __ShWorker#{id} = struct {
              wg: *CheatHeader.WaitGroup,
              chans: *[#{shard_count}]CheatLib.BoundedChannel(__ShWork#{id}),
              err: *std.atomic.Value(bool),
              shard: usize,
      #{capture_fields.empty? ? "" : capture_fields + "\n"}        fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
                  const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
                  const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
                  defer ctx.wg.done();
                  errdefer {
                      ctx.err.store(true, .release);
                      for (0..#{shard_count}) |__s| ctx.chans[__s].setError(error.CheatError);
                  }
                  while (ctx.chans[ctx.shard].pop() catch |__err| {
                      ctx.err.store(true, .release);
                      for (0..#{shard_count}) |__s| ctx.chans[__s].setError(__err);
                      return __err;
                  }) |__work| {
                      errdefer {
                          #{key_free_work}
                      }
                      var __sh#{id}_ki: usize = 0;
                      while (__sh#{id}_ki < __work.keys.len) : (__sh#{id}_ki += 1) {
                          #{key_free_remaining}
                          const #{key_var}: #{key_zig} = __work.keys[__sh#{id}_ki];
                          #{body_loop_mark}
                          #{body_zig}
                          #{key_free_success}
                      }
                      __rt.heapAlloc().free(__work.keys);
                      __rt.checkYield();
                  }
              }
          };
          var __sh#{id}_workers: [#{shard_count}]__ShWorker#{id} = undefined;
          __sh#{id}_wg.add(#{shard_count});
          for (0..#{shard_count}) |__s| {
              __sh#{id}_workers[__s] = .{ .wg = &__sh#{id}_wg, .chans = &__sh#{id}_chans, .err = &__sh#{id}_err, .shard = __s#{capture_inits_str} };
              try CheatHeader.spawnBest(
                  @intFromPtr(&Runtime.entryWrapper),
                  @as(CheatHeader.TaskFn, @ptrCast(&__ShWorker#{id}.run)),
                  &__sh#{id}_workers[__s],
                  #{task_cfg},
              );
          }

          var __sh#{id}_batches: [#{shard_count}]std.ArrayListUnmanaged(#{key_zig}) = [_]std.ArrayListUnmanaged(#{key_zig}){.empty} ** #{shard_count};
          defer for (0..#{shard_count}) |__s| {
              #{pending_batch_cleanup}
              __sh#{id}_batches[__s].deinit(rt.heapAlloc());
          };

          var #{idx_var}: i64 = #{start_zig};
          const __sh#{id}_end: i64 = #{end_zig};
          while ((#{idx_var} #{op_str} __sh#{id}_end) and !__sh#{id}_err.load(.acquire)) : (#{idx_var} += 1) {
              #{key_loop_mark}
              const #{key_var}: #{key_zig} = #{key_zig_expr};
              const #{sh_var} = @TypeOf(#{map_ptr}.*).shardIndexWithHash(#{key_var});
              try __sh#{id}_batches[#{sh_var}.shard].append(rt.heapAlloc(), #{key_store_expr});
              if (__sh#{id}_batches[#{sh_var}.shard].items.len >= __sh#{id}_batch) {
                  const __sh#{id}_keys = try __sh#{id}_batches[#{sh_var}.shard].toOwnedSlice(rt.heapAlloc());
                  const __sh#{id}_work = __ShWork#{id}{ .keys = __sh#{id}_keys };
                  __sh#{id}_chans[#{sh_var}.shard].push(__sh#{id}_work) catch |__err| {
                      #{key_slice_cleanup}
                      rt.heapAlloc().free(__sh#{id}_keys);
                      __sh#{id}_err.store(true, .release);
                      for (0..#{shard_count}) |__s| __sh#{id}_chans[__s].setError(__err);
                      break;
                  };
              }
          }
          for (0..#{shard_count}) |__s| {
              if (__sh#{id}_batches[__s].items.len > 0 and !__sh#{id}_err.load(.acquire)) {
                  const __sh#{id}_keys = try __sh#{id}_batches[__s].toOwnedSlice(rt.heapAlloc());
                  const __sh#{id}_work = __ShWork#{id}{ .keys = __sh#{id}_keys };
                  __sh#{id}_chans[__s].push(__sh#{id}_work) catch |__err| {
                      #{key_slice_cleanup}
                      rt.heapAlloc().free(__sh#{id}_keys);
                      __sh#{id}_err.store(true, .release);
                      for (0..#{shard_count}) |__ss| __sh#{id}_chans[__ss].setError(__err);
                      break;
                  };
              }
          }
          for (0..#{shard_count}) |__s| __sh#{id}_chans[__s].close();
          __sh#{id}_wg.wait();
          for (0..#{shard_count}) |__s| __ShCleanup#{id}.cleanupBuffered(&__sh#{id}_chans[__s], rt);
          if (__sh#{id}_err.load(.acquire)) return error.CheatError;
      }
    ZIG
    MIR::InlineZig.new(code, "shard_concurrent_each")
  end

  # CONCURRENT SELECT ... OR PRUNE: build a structural for-loop that runs
  # the failable expression, checks for an error sentinel, and only appends
  # on success. Result list element type is the SUCCESS type of the
  # failable expression (smooth_node.full_type!).
  sig { params(lhs: T.untyped, inner_expr: T.untyped, smooth_node: AST::BinaryOp).returns(MIR::BlockExpr) }
  def lower_bc_concurrent_select_prune(lhs, inner_expr, smooth_node)
    res_zig = transpile_type(T.must(smooth_node.full_type!.element_type).resolved.to_s)
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
              [MIR::AllocatorRef.new(alloc), MIR::Ident.new("__cv")], true,
              MIR::CallableContract.no_ownership(2)), nil)
          ], nil)
        ], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("res_list"))
      ]
    end
  end

  # CONCURRENT WHERE ... OR PRUNE: predicate evaluation that raises is
  # treated as "false" (item skipped). Same loop shape as lower_where but
  # the truthiness check is gated by !isError.
  sig { params(lhs: T.untyped, inner_expr: T.untyped, smooth_node: AST::BinaryOp).returns(MIR::BlockExpr) }
  def lower_bc_concurrent_where_prune(lhs, inner_expr, smooth_node)
    elem_type = lhs.full_type!.element_type.resolved.to_s
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
              [MIR::AllocatorRef.new(alloc), MIR::Ident.new("it")], true,
              MIR::CallableContract.no_ownership(2)), nil)
          ], nil)
        ], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("res_list"))
      ]
    end
  end

  sig { params(lhs: AST::Identifier, conc_op: AST::ConcurrentOp).returns(T.untyped) }
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

  sig { params(conc_op: AST::ConcurrentOp).returns(T.untyped) }
  def bounded_concurrent_worker_count_mir(conc_op)
    if (workers = conc_op.options["workers"])
      visit_mir(workers)
    else
      MIR::Call.new("CheatLib.threadCount", [], false)
    end
  end

  # The Zig-side `workers: usize` parameter requires a usize value, but the
  # raw worker-count expression is i64 (CheatLib.threadCount returns i64;
  # CLEAR's Number lowers to i64). Wrap with @intCast at the call site only
  # -- the default-capacity expression interpolates the raw form to keep
  # comptime-int simplification (e.g. `c < 2 * 4`) working in Zig.
  sig { params(conc_op: AST::ConcurrentOp).returns(MIR::InlineZig) }
  def bounded_concurrent_worker_count_for_call_mir(conc_op)
    raw = bounded_concurrent_worker_count_mir(conc_op)
    raw_zig = @lowering.send(:emit_expr, raw)
    MIR::InlineZig.new("@intCast(#{raw_zig})", "bounded_workers_usize")
  end

  sig { params(conc_op: AST::ConcurrentOp).returns(MIR::Lit) }
  def bounded_concurrent_parallel_mir(conc_op)
    if (par = conc_op.options["parallel"])
      visit_mir(par)
    else
      MIR::Lit.new("false")
    end
  end

  sig { params(conc_op: T.untyped).returns(T.untyped) }
  def bounded_concurrent_batch_mir(conc_op)
    if (batch = conc_op.options["batch"])
      raw = visit_mir(batch)
      raw_zig = @lowering.send(:emit_expr, raw)
      MIR::InlineZig.new("@intCast(#{raw_zig})", "bounded_batch_usize")
    else
      MIR::Lit.new("1")
    end
  end

  # Resolve the bare struct name (if any) for a capture symbol, used to
  # stamp BC pre-decoded slots with `:struct_<Name>`. Returns a String or
  # nil. Only struct-shaped Type values yield a useful hint.
  sig { params(sym: SymbolEntry).returns(T.nilable(String)) }
  def struct_name_hint_for_sym(sym)
    return nil unless sym
    bare = sym.type.bare_data_type
    return bare.to_s if bare && bare.respond_to?(:struct?) && bare.struct?
    nil
  end

  sig { params(conc_op: AST::ConcurrentOp).returns(MIR::InlineZig) }
  def bounded_concurrent_task_cfg_mir(conc_op)
    size_node = conc_op.options["size"]
    MIR::InlineZig.new(task_config_zig(size_node&.name&.downcase&.to_sym), "task_cfg")
  end

  sig { params(conc_op: AST::ConcurrentOp, item_type: Type, return_type: T.untyped, body_kind: Symbol).returns(T::Hash[T.untyped, T.untyped]) }
  def build_bounded_concurrent_callback(conc_op, item_type, return_type, body_kind)
    @bounded_conc_counter ||= 0
    id = (@bounded_conc_counter += 1)
    ctx_name = "__BoundedConcurrentCtx#{id}"
    analysis = conc_op.capture_analysis

    # Capture handling delegated to FiberCtxBuilder -- same builder
    # BG/BG STREAM/DO use. CONCURRENT pipeline callbacks render the
    # specs as MIR::FieldDef/MIR::StructInit (instead of Zig templates)
    # because pipeline_host produces MIR nodes directly.
    caps = FiberCtxBuilder.build(analysis, body_access_prefix: "ctx")

    fields = caps.specs.map { |s|
      fd = MIR::FieldDef.new(s.name, s.field_type_zig, nil)
      # Stamp @shared:locked / @local / @writeLocked captures as boxed
      # so the BC worker pre-decode marks the corresponding local slot
      # as boxed (alias_to_source then propagates the flag onto the
      # WITH alias `t`, and writes through `t.value = ...` route via
      # BOX_STORE back to the same envId the outer binding holds).
      sym = caps.capture_symbols&.dig(s.name)
      if sym && (sym.locked? || sym.write_locked? || sym.storage == :local)
        # Stamp the inner struct name (when knowable) so the BC pre-decode
        # can stamp `:struct_<Name>` on the worker's local slot — without
        # it, find_field_index for `t.value` walks every struct and may
        # return the wrong index when multiple structs share a field name.
        fd.boxed_capture = struct_name_hint_for_sym(sym) || true
      end
      fd
    }

    raw_ctx = MIR::Param.new("raw_ctx", "?*anyopaque", false)
    params = T.let([
      MIR::Param.new("__rt", "*Runtime", false),
      raw_ctx,
      MIR::Param.new("__item", Type.new(item_type).zig_type, false),
    ], T::Array[MIR::Param])

    body = T.let([MIR::Suppress.new("__rt")], T::Array[T.untyped])
    if caps.specs.empty?
      body << MIR::Suppress.new("raw_ctx")
    else
      ctx_cast = MIR::InlineZig.new("@as(*@This(), @ptrCast(@alignCast(raw_ctx.?)))", "bounded_concurrent_ctx_cast")
      body << MIR::Let.new("ctx", ctx_cast, false, nil, nil)
    end

    # In BC mode, also pre-decode each capture into a local Let bound by
    # the original capture name. The worker body's MIR identifiers are
    # rewritten to `ctx.<name>` by `with_fiber_capture_map` below, but
    # auto-lock InlineZig produced by `WITH EXCLUSIVE <name>` carries the
    # capture name as raw Zig source. The bc_emitter scans that source
    # for `<name>.acquire()` to emit LOCK_ACQUIRE -- it needs <name> to
    # resolve to a local slot. Without these Lets the lock acquire is
    # silently dropped, the worker's mutation runs against an unlocked
    # local copy, and writes never reach the outer @shared:locked
    # binding (regressed 228/240/241/242 EACH-with-mutation).
    if bc_target?
      caps.specs.each do |spec|
        body << MIR::Let.new(spec.name,
          MIR::FieldGet.new(MIR::Ident.new("ctx"), spec.name),
          true, nil, nil)
      end
    end

    lowered_body = with_pipeline_context(placeholder: "__item") do
      with_fiber_capture_map(caps.capture_map, capture_symbols: caps.capture_symbols, rt_override: "__rt") do
        case body_kind
        when :expr
          expr_mir = visit_mir(conc_op.op.expression)
          # Bounded-concurrent SELECT worker ABI: the worker fn is typed
          # `!T` and returns the RAW error union; CheatLib.concurrent-
          # ListSelect performs error propagation. The worker must NOT
          # try-unwrap locally -- that would swallow the error before the
          # helper sees it. (Latent until declared-`!T` callees were
          # correctly classified can_fail; see concurrency_spec "leaves
          # error propagation to the runtime helper".)
          expr_mir.try_wrap = false if expr_mir.is_a?(MIR::Call) || expr_mir.is_a?(MIR::MethodCall)
          expr_type = conc_op.op.expression.full_type!
          ret_type = Type.new(return_type)
          if expr_type && Type.new(expr_type).integer? && ret_type.float?
            expr_mir = MIR::Cast.new(MIR::Cast.new(expr_mir, nil, :floatFromInt), ret_type.zig_type, :as)
          end
          [MIR::ReturnStmt.new(expr_mir)]
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
    ctx_init = MIR::StructInit.new(ctx_name, caps.specs.map { |s|
      { name: s.name, value: s.init_value_mir }
    })
    ctx_var = "__bounded_conc_ctx_#{id}"
    ctx_let = MIR::Let.new(ctx_var, ctx_init, true, nil, "_ = &#{ctx_var};")
    pre_ctx_stmts = caps.specs.filter_map(&:setup_mir)
    post_ctx_stmts = caps.specs.filter_map { |s| s.cleanup_mir_for(ctx_var) }

    {
      id: id,
      ctx_name: ctx_name,
      ctx_def: ctx_def,
      ctx_var: ctx_var,
      ctx_let: ctx_let,
      pre_ctx_stmts: pre_ctx_stmts,
      post_ctx_stmts: post_ctx_stmts,
    }
  end

  sig { params(lhs: AST::Identifier, _id: Integer).returns(T::Array[T.untyped]) }
  def bounded_stream_items_setup(lhs, _id)
    source = visit_mir(lhs)
    [[], MIR::AddressOf.new(MIR::FieldGet.new(source, "items"))]
  end

  sig { params(lhs: AST::Identifier).returns(T::Array[T.untyped]) }
  def bounded_stream_source_move(lhs)
    name = lhs.name.to_s
    guarded = @lowering.instance_variable_get(:@guarded_cleanup_names)&.[](name)
    return [] unless guarded
    MIR::OwnershipTransferPlan.new(
      name: name,
      target: :owned_sink,
      target_alloc: :heap,
      move_guarded: true,
    ).marks
  end

  sig { params(lhs: AST::Identifier, conc_op: AST::ConcurrentOp, inner: AST::SelectOp).returns(MIR::BlockExpr) }
  def lower_concurrent_bounded_select(lhs, conc_op, inner)
    item_t = lhs.full_type!.stream_element_type
    result_t = Type.new(inner.expression.full_type!)
    cb = build_bounded_concurrent_callback(conc_op, item_t, result_t, :expr)
    setup_stmts, items_ptr = bounded_stream_items_setup(lhs, cb[:id])
    source_move = bounded_stream_source_move(lhs)

    call = @lowering.send(:emit_builtin, :concurrentBoundedSelect, [
      MIR::Ident.new(item_t.zig_type),
      MIR::Ident.new(result_t.zig_type),
      MIR::Lit.new(lhs.full_type!.stream_capacity.to_s),
      MIR::Ident.new("#{cb[:ctx_name]}.apply"),
      MIR::AllocatorRef.new(pipeline_result_alloc),
      MIR::Ident.new("rt"),
      items_ptr,
      bounded_concurrent_worker_count_for_call_mir(conc_op),
      bounded_concurrent_batch_mir(conc_op),
      bounded_concurrent_parallel_mir(conc_op),
      bounded_concurrent_task_cfg_mir(conc_op),
      MIR::AddressOf.new(MIR::Ident.new(cb[:ctx_var])),
    ])

    label = next_pipe_label
    MIR::BlockExpr.new(label, [
      *bounded_callback_context_stmts(cb),
      *setup_stmts,
      *source_move,
      MIR::BreakStmt.new(label, call),
    ].compact)
  end

  sig { params(lhs: AST::Identifier, conc_op: AST::ConcurrentOp, _inner: AST::WhereOp).returns(MIR::BlockExpr) }
  def lower_concurrent_bounded_where(lhs, conc_op, _inner)
    item_t = lhs.full_type!.stream_element_type
    cb = build_bounded_concurrent_callback(conc_op, item_t, :Bool, :expr)
    setup_stmts, items_ptr = bounded_stream_items_setup(lhs, cb[:id])
    source_move = bounded_stream_source_move(lhs)

    call = @lowering.send(:emit_builtin, :concurrentBoundedWhere, [
      MIR::Ident.new(item_t.zig_type),
      MIR::Lit.new(lhs.full_type!.stream_capacity.to_s),
      MIR::Ident.new("#{cb[:ctx_name]}.apply"),
      MIR::AllocatorRef.new(pipeline_result_alloc),
      MIR::Ident.new("rt"),
      items_ptr,
      bounded_concurrent_worker_count_for_call_mir(conc_op),
      bounded_concurrent_batch_mir(conc_op),
      bounded_concurrent_parallel_mir(conc_op),
      bounded_concurrent_task_cfg_mir(conc_op),
      MIR::AddressOf.new(MIR::Ident.new(cb[:ctx_var])),
    ])

    label = next_pipe_label
    MIR::BlockExpr.new(label, [
      *bounded_callback_context_stmts(cb),
      *setup_stmts,
      *source_move,
      MIR::BreakStmt.new(label, call),
    ].compact)
  end

  sig { params(lhs: AST::Identifier, conc_op: AST::ConcurrentOp, _inner: AST::EachOp).returns(MIR::ScopeBlock) }
  def lower_concurrent_bounded_each(lhs, conc_op, _inner)
    item_t = lhs.full_type!.stream_element_type
    cb = build_bounded_concurrent_callback(conc_op, item_t, :Void, :each)
    setup_stmts, items_ptr = bounded_stream_items_setup(lhs, cb[:id])
    source_move = bounded_stream_source_move(lhs)

    call = @lowering.send(:emit_builtin, :concurrentBoundedEach, [
      MIR::Ident.new(item_t.zig_type),
      MIR::Lit.new(lhs.full_type!.stream_capacity.to_s),
      MIR::Ident.new("#{cb[:ctx_name]}.apply"),
      MIR::Ident.new("rt"),
      items_ptr,
      bounded_concurrent_worker_count_for_call_mir(conc_op),
      bounded_concurrent_batch_mir(conc_op),
      bounded_concurrent_parallel_mir(conc_op),
      bounded_concurrent_task_cfg_mir(conc_op),
      MIR::AddressOf.new(MIR::Ident.new(cb[:ctx_var])),
    ])

    MIR::ScopeBlock.new([
      *bounded_callback_context_stmts(cb),
      *setup_stmts,
      *source_move,
      MIR::ExprStmt.new(call, false),
    ].compact)
  end

  # Element type for ~T[] / ~T[INF] / open-stream sources.
  sig { params(lhs_ti: Type).returns(Type) }
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
  sig { params(lhs: AST::Identifier, id: Integer).returns(T::Array[T.untyped]) }
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
  sig { params(conc_op: AST::ConcurrentOp, n_workers_zig: String).returns(MIR::InlineZig) }
  def stream_concurrent_capacity_mir(conc_op, n_workers_zig)
    if (cap_node = conc_op.options&.[]("capacity"))
      cap_zig = @lowering.send(:emit_expr, @lowering.lower(cap_node))
      MIR::InlineZig.new("@intCast(#{cap_zig})", "stream_conc_capacity_user")
    else
      expr = "blk: { var c: usize = 4; while (c < #{n_workers_zig} * 4) : (c <<= 1) {} break :blk @min(c, 64); }"
      MIR::InlineZig.new(expr, "stream_conc_capacity_default")
    end
  end

  sig { params(lhs: AST::Identifier, conc_op: AST::ConcurrentOp, inner: AST::SelectOp).returns(MIR::BlockExpr) }
  def lower_concurrent_stream_select(lhs, conc_op, inner)
    lhs_ti  = lhs.full_type!
    item_t  = stream_concurrent_element_type(lhs_ti)
    result_t = Type.new(inner.expression.full_type!)
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
      MIR::AllocatorRef.new(pipeline_result_alloc),
      MIR::Ident.new("rt"),
      src_ptr,
      bounded_concurrent_worker_count_for_call_mir(conc_op),
      cap_mir,
      bounded_concurrent_batch_mir(conc_op),
      bounded_concurrent_parallel_mir(conc_op),
      bounded_concurrent_task_cfg_mir(conc_op),
      MIR::AddressOf.new(MIR::Ident.new(cb[:ctx_var])),
    ])

    label = next_pipe_label
    MIR::BlockExpr.new(label, [
      *bounded_callback_context_stmts(cb),
      *setup_stmts,
      MIR::BreakStmt.new(label, call),
    ])
  end

  sig { params(lhs: AST::Identifier, conc_op: AST::ConcurrentOp, inner: AST::WhereOp).returns(MIR::BlockExpr) }
  def lower_concurrent_stream_where(lhs, conc_op, inner)
    lhs_ti  = lhs.full_type!
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
      MIR::AllocatorRef.new(pipeline_result_alloc),
      MIR::Ident.new("rt"),
      src_ptr,
      bounded_concurrent_worker_count_for_call_mir(conc_op),
      cap_mir,
      bounded_concurrent_batch_mir(conc_op),
      bounded_concurrent_parallel_mir(conc_op),
      bounded_concurrent_task_cfg_mir(conc_op),
      MIR::AddressOf.new(MIR::Ident.new(cb[:ctx_var])),
    ])

    label = next_pipe_label
    MIR::BlockExpr.new(label, [
      *bounded_callback_context_stmts(cb),
      *setup_stmts,
      MIR::BreakStmt.new(label, call),
    ])
  end

  sig { params(lhs: AST::Identifier, conc_op: AST::ConcurrentOp, inner: AST::EachOp).returns(MIR::ScopeBlock) }
  def lower_concurrent_stream_each(lhs, conc_op, inner)
    lhs_ti  = lhs.full_type!
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
      MIR::AllocatorRef.new(pipeline_result_alloc),
      MIR::Ident.new("rt"),
      src_ptr,
      bounded_concurrent_worker_count_for_call_mir(conc_op),
      cap_mir,
      bounded_concurrent_batch_mir(conc_op),
      bounded_concurrent_parallel_mir(conc_op),
      bounded_concurrent_task_cfg_mir(conc_op),
      MIR::AddressOf.new(MIR::Ident.new(cb[:ctx_var])),
    ])

    MIR::ScopeBlock.new([
      *bounded_callback_context_stmts(cb),
      *setup_stmts,
      MIR::ExprStmt.new(call, false),
    ])
  end

  # Source materialization for collection-source CONCURRENT. Reuses
  # build_pipe_items_block / visit() to produce a Zig prelude
  # that binds `pipe_src_list` and `pipe_items` (a slice). The shape
  # adaptation (sharded pool / SoA / etc.) lives in build_pipe_items_block;
  # only the worker-pool wiring is migrated to structural MIR.
  sig { params(lhs: T.untyped).returns(T::Array[T.untyped]) }
  def list_concurrent_source_setup_stmts(lhs)
    if lhs.is_a?(AST::RangeLit)
      source_mir = visit_mir(lhs)
      to_list = MIR::MethodCall.new(MIR::Ident.new("pipe_src_list"), "toList",
        [MIR::AllocatorRef.new(:heap)], true, MIR::CallableContract.no_ownership(1))
      return [
        MIR::Let.new("pipe_src_list", source_mir, true, nil, "_ = &pipe_src_list;"),
        MIR::Let.new("pipe_mat", to_list, true, nil, nil),
        MIR::DeferStmt.new(MIR::MethodCall.new(MIR::Ident.new("pipe_mat"), "deinit",
          [MIR::AllocatorRef.new(:heap)], false, MIR::CallableContract.no_ownership(1))),
        MIR::Let.new("pipe_items", MIR::ItemsAccess.new(MIR::Ident.new("pipe_mat"), true), false, nil, nil),
      ]
    end

    lhs_type = lhs.full_type!
    source_mir = visit_mir(lhs)
    source_prefix = T.let([], T::Array[T.untyped])
    source_cleanup = T.let(nil, T.nilable(MIR::Cleanup))
    if @lowering.send(:mir_allocates?, source_mir)
      owned_alloc = @lowering.send(:mir_owned_alloc, source_mir)
      alloc = owned_alloc || :heap
      @lowering.send(:stamp_allocating_result_target!, source_mir, "pipe_src_list", alloc: alloc)
      mark = MIR::AllocMark.new("pipe_src_list", alloc, lhs.full_type!)
      mark.scope = MIR::Placement.alloc_scope(alloc)
      source_prefix << mark
      source_cleanup = MIR::Cleanup.new("pipe_src_list",
        CleanupEntry.build(:uniform, alloc: alloc, has_moved_guard: false, zig_type: lhs_type.zig_type))
    end
    mat_stmts, = build_pipe_items_mir(lhs_type)
    [
      *source_prefix,
      MIR::Let.new("pipe_src_list", source_mir, !source_cleanup.nil?, nil, "_ = &pipe_src_list;"),
      source_cleanup,
      *mat_stmts,
    ].compact
  end

  sig { params(lhs: T.untyped).returns(Type) }
  def concurrent_list_item_type(lhs)
    if lhs.is_a?(AST::RangeLit)
      # tense_type is legitimately nil for a non-tense source; the
      # range start is an evaluatable node, so its full_type is the
      # invariant-guaranteed fallback (no dead :Int64 guard).
      elem = lhs.full_type!.tense_type&.element_type&.resolved ||
        lhs.start.full_type!
      return Type.new(elem)
    end
    Type.new(lhs.full_type!.element_type.resolved)
  end

  sig { params(lhs: T.untyped, conc_op: AST::ConcurrentOp, inner: AST::SelectOp).returns(MIR::BlockExpr) }
  def lower_concurrent_list_select(lhs, conc_op, inner)
    item_t  = concurrent_list_item_type(lhs)
    result_t = Type.new(inner.expression.full_type!)
    cb = build_bounded_concurrent_callback(conc_op, item_t, result_t, :expr)
    setup_stmts = list_concurrent_source_setup_stmts(lhs)

    call = @lowering.send(:emit_builtin, :concurrentListSelect, [
      MIR::Ident.new(item_t.zig_type),
      MIR::Ident.new(result_t.zig_type),
      MIR::Ident.new("#{cb[:ctx_name]}.apply"),
      MIR::AllocatorRef.new(pipeline_result_alloc),
      MIR::Ident.new("rt"),
      MIR::Ident.new("pipe_items"),
      bounded_concurrent_worker_count_for_call_mir(conc_op),
      bounded_concurrent_batch_mir(conc_op),
      bounded_concurrent_parallel_mir(conc_op),
      bounded_concurrent_task_cfg_mir(conc_op),
      MIR::AddressOf.new(MIR::Ident.new(cb[:ctx_var])),
    ])

    label = next_pipe_label
    MIR::BlockExpr.new(label, [
      *setup_stmts,
      *bounded_callback_context_stmts(cb),
      MIR::BreakStmt.new(label, call),
    ])
  end

  sig { params(lhs: T.untyped, conc_op: AST::ConcurrentOp, inner: T.untyped).returns(MIR::BlockExpr) }
  def lower_concurrent_list_where(lhs, conc_op, inner)
    item_t  = concurrent_list_item_type(lhs)
    cb = build_bounded_concurrent_callback(conc_op, item_t, :Bool, :expr)
    setup_stmts = list_concurrent_source_setup_stmts(lhs)

    call = @lowering.send(:emit_builtin, :concurrentListWhere, [
      MIR::Ident.new(item_t.zig_type),
      MIR::Ident.new("#{cb[:ctx_name]}.apply"),
      MIR::AllocatorRef.new(pipeline_result_alloc),
      MIR::Ident.new("rt"),
      MIR::Ident.new("pipe_items"),
      bounded_concurrent_worker_count_for_call_mir(conc_op),
      bounded_concurrent_batch_mir(conc_op),
      bounded_concurrent_parallel_mir(conc_op),
      bounded_concurrent_task_cfg_mir(conc_op),
      MIR::AddressOf.new(MIR::Ident.new(cb[:ctx_var])),
    ])

    label = next_pipe_label
    MIR::BlockExpr.new(label, [
      *setup_stmts,
      *bounded_callback_context_stmts(cb),
      MIR::BreakStmt.new(label, call),
    ])
  end

  sig { params(lhs: T.untyped, conc_op: AST::ConcurrentOp, inner: AST::CountOp).returns(MIR::BlockExpr) }
  def lower_concurrent_list_count(lhs, conc_op, inner)
    item_t = concurrent_list_item_type(lhs)
    cb = build_bounded_concurrent_callback(conc_op, item_t, :Bool, :expr)
    setup_stmts = list_concurrent_source_setup_stmts(lhs)

    call = @lowering.send(:emit_builtin, :concurrentListCount, [
      MIR::Ident.new(item_t.zig_type),
      MIR::Ident.new("#{cb[:ctx_name]}.apply"),
      MIR::Ident.new("rt"),
      MIR::Ident.new("pipe_items"),
      bounded_concurrent_worker_count_for_call_mir(conc_op),
      bounded_concurrent_batch_mir(conc_op),
      bounded_concurrent_parallel_mir(conc_op),
      bounded_concurrent_task_cfg_mir(conc_op),
      MIR::AddressOf.new(MIR::Ident.new(cb[:ctx_var])),
    ])

    label = next_pipe_label
    MIR::BlockExpr.new(label, [
      *setup_stmts,
      *bounded_callback_context_stmts(cb),
      MIR::BreakStmt.new(label, call),
    ])
  end

  sig { params(lhs: T.untyped, conc_op: AST::ConcurrentOp, inner: T.untyped, smooth_node: AST::BinaryOp).returns(MIR::BlockExpr) }
  def lower_concurrent_list_reduce(lhs, conc_op, inner, smooth_node)
    item_t = concurrent_list_item_type(lhs)

    result_t = Type.new(smooth_node.full_type!)
    result_zig = result_t.zig_type
    kind = case inner
           when AST::SumOp then :sum
           when AST::AverageOp then :average
           when AST::MinOp then :min
           when AST::MaxOp then :max
           else raise "lower_concurrent_list_reduce: unsupported inner op #{inner.class}"
           end
    initial = case kind
              when :sum then MIR::Lit.new("0")
              when :average then MIR::Lit.new("0.0")
              when :min
                MIR::InlineZig.new(T.must(agg_minmax_sentinels(result_zig, smooth_node.full_type!.resolved)[0]), "concurrent_reduce_min_init")
              when :max
                MIR::InlineZig.new(T.must(agg_minmax_sentinels(result_zig, smooth_node.full_type!.resolved)[1]), "concurrent_reduce_max_init")
              end

    cb = build_bounded_concurrent_callback(conc_op, item_t, result_t, :expr)
    setup_stmts = list_concurrent_source_setup_stmts(lhs)

    call = @lowering.send(:emit_builtin, :concurrentListReduce, [
      MIR::Ident.new(item_t.zig_type),
      MIR::Ident.new(result_zig),
      MIR::Ident.new("#{cb[:ctx_name]}.apply"),
      MIR::Ident.new("rt"),
      MIR::Ident.new("pipe_items"),
      bounded_concurrent_worker_count_for_call_mir(conc_op),
      bounded_concurrent_batch_mir(conc_op),
      bounded_concurrent_parallel_mir(conc_op),
      bounded_concurrent_task_cfg_mir(conc_op),
      MIR::AddressOf.new(MIR::Ident.new(cb[:ctx_var])),
      initial,
      MIR::InlineZig.new(".#{kind}", "concurrent_reduce_kind"),
    ])

    label = next_pipe_label
    MIR::BlockExpr.new(label, [
      *setup_stmts,
      *bounded_callback_context_stmts(cb),
      MIR::BreakStmt.new(label, call),
    ])
  end

  sig { params(lhs: T.untyped, conc_op: AST::ConcurrentOp, inner: AST::EachOp).returns(MIR::ScopeBlock) }
  def lower_concurrent_list_each(lhs, conc_op, inner)
    item_t  = concurrent_list_item_type(lhs)
    cb = build_bounded_concurrent_callback(conc_op, item_t, :Void, :each)
    setup_stmts = list_concurrent_source_setup_stmts(lhs)

    call = @lowering.send(:emit_builtin, :concurrentListEach, [
      MIR::Ident.new(item_t.zig_type),
      MIR::Ident.new("#{cb[:ctx_name]}.apply"),
      MIR::Ident.new("rt"),
      MIR::Ident.new("pipe_items"),
      bounded_concurrent_worker_count_for_call_mir(conc_op),
      bounded_concurrent_batch_mir(conc_op),
      bounded_concurrent_parallel_mir(conc_op),
      bounded_concurrent_task_cfg_mir(conc_op),
      MIR::AddressOf.new(MIR::Ident.new(cb[:ctx_var])),
    ])

    MIR::ScopeBlock.new([
      *setup_stmts,
      *bounded_callback_context_stmts(cb),
      MIR::ExprStmt.new(call, false),
    ])
  end

  # Scan an EACH body for direct mutation of `_` (e.g. `_.field = X` or
  # `_[i] = X`). When present, the worker callback must take `*T` not
  # `T` so the mutation lands on the shared slice, not a value copy.
  # Walks AST::Assignment.name chains rooted at Identifier("_").
  sig { params(body_stmts: T::Array[T.untyped]).returns(T::Boolean) }
  def each_body_mutates_placeholder?(body_stmts)
    body_stmts.any? { |stmt| assignment_targets_placeholder?(stmt) }
  end

  sig { params(node: T.untyped).returns(T::Boolean) }
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

  sig { params(target: AST::GetField).returns(T::Boolean) }
  def target_rooted_at_placeholder?(target)
    AST.root_identifier(target)&.name == "_"
  end

  # In-place EACH variant: items is a *mutable* slice and each worker
  # invocation receives `*T` so the body can update the slice element
  # via field/index assignment. Used when the body has a direct
  # `_.field = X` or `_[i] = X` mutation.
  sig { params(lhs: T.untyped, conc_op: AST::ConcurrentOp, inner: AST::EachOp).returns(MIR::ScopeBlock) }
  def lower_concurrent_list_each_in_place(lhs, conc_op, inner)
    item_t = concurrent_list_item_type(lhs)
    cb = build_bounded_concurrent_callback_pointer(conc_op, item_t)
    setup_stmts = list_concurrent_source_setup_stmts(lhs)

    call = @lowering.send(:emit_builtin, :concurrentListEachInPlace, [
      MIR::Ident.new(item_t.zig_type),
      MIR::Ident.new("#{cb[:ctx_name]}.apply"),
      MIR::Ident.new("rt"),
      # The legacy `pipe_items` is a `[]const T`; @constCast strips the
      # const so the in-place helper can write through the slice.
      MIR::InlineZig.new("@constCast(pipe_items)", "list_each_inplace_mut_items"),
      bounded_concurrent_worker_count_for_call_mir(conc_op),
      bounded_concurrent_batch_mir(conc_op),
      bounded_concurrent_parallel_mir(conc_op),
      bounded_concurrent_task_cfg_mir(conc_op),
      MIR::AddressOf.new(MIR::Ident.new(cb[:ctx_var])),
    ])

    MIR::ScopeBlock.new([
      *setup_stmts,
      *bounded_callback_context_stmts(cb),
      MIR::ExprStmt.new(call, false),
    ])
  end

  # Variant of build_bounded_concurrent_callback for in-place EACH:
  # `__item` is `*T` (mutable pointer) so `_.field = X` lands on the
  # slice element. Otherwise identical to the by-value callback.
  sig { params(conc_op: AST::ConcurrentOp, item_type: Type).returns(T::Hash[T.untyped, T.untyped]) }
  def build_bounded_concurrent_callback_pointer(conc_op, item_type)
    @bounded_conc_counter ||= 0
    id = (@bounded_conc_counter += 1)
    ctx_name = "__BoundedConcurrentCtx#{id}"
    analysis = conc_op.capture_analysis

    # Capture handling delegated to FiberCtxBuilder -- same builder
    # BG/BG STREAM/DO/CONCURRENT-by-value use. The `_pointer` suffix
    # only refers to how `__item` is passed (mutable pointer for
    # in-place mutation), not how captures are stored.
    caps = FiberCtxBuilder.build(analysis, body_access_prefix: "ctx")

    fields = caps.specs.map { |s|
      fd = MIR::FieldDef.new(s.name, s.field_type_zig, nil)
      # Stamp @shared:locked / @local / @writeLocked captures as boxed
      # so the BC worker pre-decode marks the corresponding local slot
      # as boxed (alias_to_source then propagates the flag onto the
      # WITH alias `t`, and writes through `t.value = ...` route via
      # BOX_STORE back to the same envId the outer binding holds).
      sym = caps.capture_symbols&.dig(s.name)
      if sym && (sym.locked? || sym.write_locked? || sym.storage == :local)
        fd.boxed_capture = struct_name_hint_for_sym(sym) || true
      end
      fd
    }

    raw_ctx = MIR::Param.new("raw_ctx", "?*anyopaque", false)
    item_zig_ptr = "*#{Type.new(item_type).zig_type}"
    params = T.let([
      MIR::Param.new("__rt", "*Runtime", false),
      raw_ctx,
      MIR::Param.new("__item", item_zig_ptr, false),
    ], T::Array[MIR::Param])

    body = T.let([MIR::Suppress.new("__rt")], T::Array[T.untyped])
    if caps.specs.empty?
      body << MIR::Suppress.new("raw_ctx")
    else
      ctx_cast = MIR::InlineZig.new("@as(*@This(), @ptrCast(@alignCast(raw_ctx.?)))", "bounded_concurrent_ctx_cast")
      body << MIR::Let.new("ctx", ctx_cast, false, nil, nil)
    end

    lowered_body = with_pipeline_context(placeholder: "__item") do
      with_fiber_capture_map(caps.capture_map, capture_symbols: caps.capture_symbols, rt_override: "__rt") do
        [*visit_pipeline_body_mir(conc_op.op.body, placeholder: "__item"), MIR::ReturnStmt.new(nil)]
      end
    end
    body.concat(lowered_body)

    fn = MIR::FnDef.new("apply", params, "void", body, nil, true, nil)
    ctx_def = MIR::StructDef.new(ctx_name, fields, [fn], nil)
    ctx_init = MIR::StructInit.new(ctx_name, caps.specs.map { |s|
      { name: s.name, value: s.init_value_mir }
    })
    ctx_var = "__bounded_conc_ctx_#{id}"
    ctx_let = MIR::Let.new(ctx_var, ctx_init, true, nil, "_ = &#{ctx_var};")
    pre_ctx_stmts = caps.specs.filter_map(&:setup_mir)
    post_ctx_stmts = caps.specs.filter_map { |s| s.cleanup_mir_for(ctx_var) }

    {
      id: id,
      ctx_name: ctx_name,
      ctx_def: ctx_def,
      ctx_var: ctx_var,
      ctx_let: ctx_let,
      pre_ctx_stmts: pre_ctx_stmts,
      post_ctx_stmts: post_ctx_stmts,
    }
  end

end
