# typed: strict
require "sorbet-runtime"

require "set"
require_relative "./pipeline_context"
require_relative "./pipeline_records"
require_relative "./pipeline_binding_chain_lowerer"
require_relative "./pipeline_plan"
require_relative "./pipeline_lowering_bridge"
require_relative "../../../backends/zig_type_mapper"
require_relative "./pipeline_materializer"
require_relative "./pipeline_scalar_lowerer"
require_relative "./pipeline_list_lowerer"
require_relative "./pipeline_range_lowerer"
require_relative "./pipeline_concurrent_lowerer"
require_relative "./pipeline_batch_window_lowerer"
require_relative "./pipeline_set_index_lowerer"
require_relative "./pipeline_each_lowerer"
require_relative "./pipeline_placeholder_usage"
require_relative "../../fiber_ctx_builder"
require_relative "../../placement"

# MIR pipeline lowering host. It owns cross-operator pipeline context and
# delegates operator families to typed lowerers that emit structural MIR.
class PipelineHost
    extend T::Sig

  include ZigTypeMapper

  PipelineSite = ::PipelineSite
  PipelineSourceShape = ::PipelineSourceShape

  BcIterRange = T.type_alias { PipelineBcIterRange }
  LazyRangePrefix = PipelineLazyRangePrefix
  DefaultObservableFoldOp = T.type_alias { PipelineDefaultObservableFoldOp }
  BindingUnnestChain = ::PipelineBindingUnnestChain

  sig { returns(MIRLoweringProgramState::FnSigMap) }
  attr_reader :fn_sigs

  sig { params(lowering: MIRLowering, emitter: MIREmitter).void }
  def initialize(lowering:, emitter:)
    @lowering_bridge = T.let(PipelineLoweringBridge.new(lowering: lowering, emitter: emitter), PipelineLoweringBridge)
    @fn_sigs = T.let(@lowering_bridge.fn_sigs, MIRLoweringProgramState::FnSigMap)
    @pipeline_context = T.let(PipelineContextState.empty, PipelineContextState)
    @mir_mode = T.let(false, T::Boolean)
    @each_idx_counter = T.let(0, Integer)
    @pipe_label_counter = T.let(0, Integer)
    @pipe_temp_counter = T.let(0, Integer)
    @current_pipe_label = T.let(nil, T.nilable(String))
    @do_rt_name = T.let(nil, T.nilable(String))
    @materializer = T.let(PipelineMaterializer.new(host: build_materializer_host), PipelineMaterializer)
    @range_lowerer = T.let(PipelineRangeLowerer.new(host: build_range_lowerer_host), PipelineRangeLowerer)
    @binding_chain_lowerer = T.let(build_binding_chain_lowerer, PipelineBindingChainLowerer)
    @plan_builder = T.let(build_plan_builder, PipelinePlanBuilder)
    @scalar_lowerer = T.let(build_scalar_lowerer, PipelineScalarLowerer)
    @list_lowerer = T.let(build_list_lowerer, PipelineListLowerer)
    @concurrent_lowerer = T.let(build_concurrent_lowerer, PipelineConcurrentLowerer)
    @batch_window_lowerer = T.let(build_batch_window_lowerer, PipelineBatchWindowLowerer)
    @set_index_lowerer = T.let(build_set_index_lowerer, PipelineSetIndexLowerer)
    @each_lowerer = T.let(build_each_lowerer, PipelineEachLowerer)
  end

  private

  sig { returns(PipelinePlanBuilder) }
  def build_plan_builder
    PipelinePlanBuilder.new(
      lowering_target: -> { @lowering_bridge.lowering_target },
      range_chain: ->(node) { unwrap_range_chain(node) },
      binding_chain: ->(node) { @binding_chain_lowerer.unwrap_chain(node) },
    )
  end

  sig { returns(PipelineScalarLowerer) }
  def build_scalar_lowerer
    PipelineScalarLowerer.new(
      visit_expr: ->(_list_node, expr_node, placeholder) {
        with_pipeline_context(placeholder: placeholder) { visit_mir(expr_node) }
      },
      pipeline_block: ->(list_node, blk) {
        pipeline_block(list_node) { |items, label| blk.call(items, label) }
      },
      transpile_type: ->(type_info) { transpile_type(type_info) },
    )
  end

  sig { returns(PipelineListLowerer) }
  def build_list_lowerer
    PipelineListLowerer.new(
      visit_mir: ->(node) { visit_mir(node) },
      visit_expr: ->(_list_node, expr_node, placeholder) {
        with_pipeline_context(placeholder: placeholder) { visit_mir(expr_node) }
      },
      visit_reduce_expr: ->(expr_node, item_placeholder, acc_placeholder) {
        with_pipeline_context(placeholder: item_placeholder, acc: acc_placeholder) { visit_mir(expr_node) }
      },
      visit_body: ->(body_stmts, placeholder) {
        visit_pipeline_body_mir(body_stmts, placeholder: placeholder)
      },
      visit_join_lambda: ->(body, join_params) {
        with_context_state(current_context.with_join_params(join_params)) { visit_mir(body) }
      },
      pipeline_block: ->(list_node, blk) {
        pipeline_block(list_node) { |items, label| blk.call(items, label) }
      },
      transpile_type: ->(type_info) { transpile_type(type_info) },
      pipeline_alloc: ->(smooth_node) { pipeline_alloc(smooth_node) },
      pipeline_result_alloc: -> { pipeline_result_alloc },
      source_shape: ->(source_node) { pipeline_source_shape(source_node) },
      next_label: -> { next_pipe_label },
      set_current_label: ->(label) { @current_pipe_label = label },
      append_owned_value_stmt: ->(receiver, alloc, value_expr) {
        append_owned_value_stmt(receiver, alloc, value_expr)
      },
      borrowed_pipeline_value: ->(value, type_info, alloc) {
        borrowed_pipeline_value(value, type_info, alloc)
      },
      cleanup_bearing_type: ->(type_info) { cleanup_bearing_type?(type_info) },
      owning_pipeline_temp_stmts: ->(name, source, type_info, zig_type, alloc) {
        owning_pipeline_temp_stmts(name, source, type_info, zig_type, alloc)
      },
    )
  end

  sig { returns(PipelineBindingChainLowerer) }
  def build_binding_chain_lowerer
    PipelineBindingChainLowerer.new(
      bc_target: -> { bc_target? },
      next_label: -> { next_pipe_label },
      set_current_label: ->(label) { @current_pipe_label = label },
      pipe_binding_zig_name: ->(clear_name) { pipe_binding_zig_name(clear_name) },
      visit_mir: ->(node) { visit_mir(node) },
      visit_mir_with_placeholder: ->(node, placeholder) {
        with_pipeline_context(placeholder: placeholder) { visit_mir(node) }
      },
      visit_mir_with_reduce_placeholders: ->(node, item_placeholder, acc_placeholder) {
        with_pipeline_context(placeholder: item_placeholder, acc: acc_placeholder) { visit_mir(node) }
      },
      transpile_type: ->(type_info) { transpile_type(type_info) },
      with_named_bindings: ->(bindings, blk) { with_named_bindings(bindings, &blk) },
      ast_uses_placeholder: ->(node) { ast_node_uses_placeholder?(node) },
    )
  end

  sig { params(bindings: T::Hash[String, String], blk: T.proc.returns(MIR::BlockExpr)).returns(MIR::BlockExpr) }
  def with_named_bindings(bindings, &blk)
    entries = bindings.map { |name, zig| PipelineNamedBinding.new(name: name, zig: zig) }
    apply_named_bindings(entries, 0, &blk)
  end

  sig { params(entries: T::Array[PipelineNamedBinding], index: Integer, blk: T.proc.returns(MIR::BlockExpr)).returns(MIR::BlockExpr) }
  def apply_named_bindings(entries, index, &blk)
    return blk.call if index >= entries.length

    entry = entries.fetch(index)
    with_named_binding(entry.name, entry.zig) { apply_named_bindings(entries, index + 1, &blk) }
  end

  sig { returns(PipelineEachLowerer) }
  def build_each_lowerer
    PipelineEachLowerer.new(
      bc_target: -> { bc_target? },
      visit_mir: ->(node) { visit_mir(node) },
      visit_body_with_placeholder: ->(body_stmts, placeholder) {
        visit_pipeline_body_mir(body_stmts, placeholder: placeholder)
      },
      soa_body: ->(body_stmts) {
        body_mir = T.let([], T::Array[MIR::Emittable])
        fields = T.let([], T::Array[String])
        with_soa_rewrite(each_mode: true) do
          body_mir = visit_pipeline_body_mir(body_stmts, placeholder: "_")
          fields = current_context.soa_needed_fields.map(&:to_s).sort
        end
        PipelineEachSoaBody.new(body: body_mir, fields: fields)
      },
      range_chain: ->(node) { unwrap_range_chain(node) },
      lower_each_range: ->(source_node, stages, each_op) { lower_each_range(source_node, stages, each_op) },
      lower_sharded_each: ->(list_node, each_op) { lower_sharded_each(list_node, each_op) },
      ast_stmts_use_placeholder: ->(body_stmts) { ast_stmts_use_placeholder?(body_stmts) },
      next_index_name: -> {
        @each_idx_counter += 1
        "__each_i_#{@each_idx_counter}"
      },
    )
  end

  sig { returns(PipelineSetIndexLowerer) }
  def build_set_index_lowerer
    PipelineSetIndexLowerer.new(
      bc_target: -> { bc_target? },
      visit_mir: ->(node) { visit_mir(node) },
      visit_mir_with_placeholder: ->(node, placeholder) {
        with_pipeline_context(placeholder: placeholder) { visit_mir(node) }
      },
      pipeline_block: ->(list_node, blk) {
        pipeline_block(list_node) { |items, label| blk.call(items, label) }
      },
      transpile_type: ->(type_info) { transpile_type(type_info) },
      pipeline_alloc: ->(smooth_node) { pipeline_alloc(smooth_node) },
      next_label: -> { next_pipe_label },
      typed_block_expr: ->(label, body, result_type) {
        typed_block_expr(label, T.cast(body, T::Array[MIR::Node]), result_type)
      },
      range_chain: ->(node) { unwrap_range_chain(node) },
      lazy_range_prefix: ->(source_node, stages, on_skip) {
        build_lazy_range_prefix(source_node, stages, on_skip: on_skip)
      },
      range_fold_observable_distinct: ->(prefix, distinct_op, smooth_node, label, source_node) {
        lower_range_fold_observable_distinct(prefix, distinct_op, smooth_node, label, source_node)
      },
      cleanup_bearing_type: ->(type_info) { cleanup_bearing_type?(type_info) },
      pipeline_alloc_mark_fact: ->(value, name, fallback_alloc, ast_node, context, include_cleanup) {
        fact = @lowering_bridge.pipeline_alloc_mark_fact(
          value,
          name,
          fallback_alloc: fallback_alloc,
          ast_node: ast_node,
          context: context,
          include_cleanup: include_cleanup,
        )
        @pipe_temp_counter += 1 if fact
        fact ? PipelineIndexAllocationFact.new(alloc: fact.alloc, mark: fact.mark, cleanup_entry: fact.cleanup_entry) : nil
      },
      pipeline_owned_cleanup_entry: ->(value, ast_node) {
        @lowering_bridge.pipeline_owned_cleanup_entry(value, ast_node)
      },
      pipeline_index_insert_with_ownership: ->(insert, value, value_owns, target_alloc) {
        @lowering_bridge.pipeline_index_insert_with_ownership(insert, value, value_owns, target_alloc: target_alloc)
      },
      index_temp_name: -> { "__idx_item_#{@pipe_temp_counter + 1}" },
    )
  end

  sig { returns(PipelineBatchWindowLowerer) }
  def build_batch_window_lowerer
    PipelineBatchWindowLowerer.new(
      bc_target: -> { bc_target? },
      visit_mir: ->(node) { visit_mir(node) },
      visit_mir_with_placeholder: ->(node, placeholder) {
        with_pipeline_context(placeholder: placeholder) { visit_mir(node) }
      },
      pipeline_block: ->(list_node, blk) {
        pipeline_block(list_node) { |items, label| blk.call(items, label) }
      },
      next_label: -> { next_pipe_label },
      set_current_label: ->(label) { @current_pipe_label = label },
      transpile_type: ->(type_info) { transpile_type(type_info) },
      pipeline_alloc: ->(smooth_node) { pipeline_alloc(smooth_node) },
    )
  end

  sig { returns(PipelineRangeLowerer::RuntimeHost) }
  def build_range_lowerer_host
    PipelineRangeLowerer::RuntimeHost.new(
      visit_mir: ->(node) { visit_mir(node) },
      visit_mir_with_context: ->(node, placeholder, acc) {
        with_pipeline_context(placeholder: placeholder, acc: acc) { visit_mir(node) }
      },
      visit_pipeline_body_mir: ->(body_stmts, placeholder) {
        visit_pipeline_body_mir(body_stmts, placeholder: placeholder)
      },
      ast_stmts_use_placeholder: ->(body_stmts) { ast_stmts_use_placeholder?(body_stmts) },
      bc_target: -> { bc_target? },
      next_label: -> { next_pipe_label },
      transpile_type: ->(type_info) { transpile_type(type_info) },
      schema_lookup: -> { pipeline_schema_lookup },
      runtime_name: -> { @do_rt_name || "rt" },
      next_observable_id: -> {
        @lowering_bridge.next_pipeline_observable_id
      },
      emit_observable_body: ->(body_mir, fiber_rt) { emit_observable_body_with_rt(body_mir, fiber_rt) },
      task_config_zig: -> { @lowering_bridge.default_task_config_zig },
    )
  end

  sig { returns(PipelineConcurrentLowerer) }
  def build_concurrent_lowerer
    PipelineConcurrentLowerer.new(
      bc_target: -> { bc_target? },
      visit_mir: ->(node) {
        visit_mir(node)
      },
      visit_mir_with_placeholder: ->(node, placeholder) {
        with_pipeline_context(placeholder: placeholder) { visit_mir(node) }
      },
      visit_body_with_placeholder: ->(body_stmts, placeholder) {
        visit_pipeline_body_mir(body_stmts, placeholder: placeholder)
      },
      lower_head_with_placeholder: ->(node, placeholder) {
        head = @lowering_bridge.lower_head {
          with_pipeline_context(placeholder: placeholder) { visit_mir(node) }
        }
        PipelineConcurrentHeadResult.new(
          value: head.value,
          pending: head.pending,
        )
      },
      callback_expr_mir: ->(expr, placeholder, capture_map, capture_symbols, rt_override) {
        with_pipeline_context(placeholder: placeholder) {
          with_fiber_capture_map(capture_map, capture_symbols: capture_symbols, rt_override: rt_override) {
            visit_mir(expr)
          }
        }
      },
      callback_body_mir: ->(body_stmts, placeholder, capture_map, capture_symbols, rt_override) {
        with_pipeline_context(placeholder: placeholder) {
          with_fiber_capture_map(capture_map, capture_symbols: capture_symbols, rt_override: rt_override) {
            visit_pipeline_body_mir(body_stmts, placeholder: placeholder)
          }
        }
      },
      pipeline_alloc_mark_fact: ->(value, name, fallback_alloc, type_info, ast_node, accept_owned_call, include_cleanup) {
        fact = @lowering_bridge.pipeline_alloc_mark_fact(
          value,
          name,
          fallback_alloc: fallback_alloc,
          type_info: type_info,
          ast_node: ast_node,
          accept_owned_call: accept_owned_call,
          include_cleanup: include_cleanup,
        )
        fact ? PipelineConcurrentAllocationFact.new(alloc: fact.alloc, mark: fact.mark, cleanup_entry: fact.cleanup_entry) : nil
      },
      append_ownership_transfers: ->(body) {
        @lowering_bridge.append_ownership_transfers_for_mir_body(body)
      },
      pipeline_block: ->(list_node, blk) {
        pipeline_block(list_node) { |items, label| blk.call(items, label) }
      },
      transpile_type: ->(type_name) { transpile_type(type_name) },
      pipeline_alloc: ->(smooth_node) { pipeline_alloc(smooth_node) },
      pipeline_result_alloc: -> { pipeline_result_alloc },
      source_setup: ->(lhs) {
        concurrent_source_setup(lhs)
      },
      emit_builtin: ->(name, args) {
        @lowering_bridge.emit_builtin(name, args)
      },
      emit_expr: ->(node) {
        T.must(@lowering_bridge.emit_expr(node))
      },
      lower_mir: ->(node) {
        @lowering_bridge.lower_node(node)
      },
      next_label: -> { next_pipe_label },
      typed_block_expr: ->(label, body, result_type) {
        typed_block_expr(label, T.cast(body, T::Array[MIR::Node]), result_type)
      },
      task_config_variant: ->(size_name) {
        @lowering_bridge.task_config_variant(size_name)
      },
      guarded_cleanup_name: ->(name) {
        @lowering_bridge.guarded_cleanup_name?(name)
      },
      do_rt_name: -> { @do_rt_name || "rt" },
      agg_min_sentinel_mir: ->(zig_type) { agg_min_sentinel_mir(zig_type) },
      agg_max_sentinel_mir: ->(zig_type, result_type) { agg_max_sentinel_mir(zig_type, result_type) },
      lower_select: ->(lhs, smooth_node, inner_expr) {
        lower_select(PipelineSite.new(list: lhs, options: smooth_node), inner_expr)
      },
      lower_where: ->(lhs, smooth_node, inner_expr) {
        lower_where(PipelineSite.new(list: lhs, options: smooth_node), inner_expr)
      },
      lower_each: ->(lhs, smooth_node, inner) {
        T.cast(lower_each(PipelineSite.new(list: lhs, options: smooth_node), inner), PipelineConcurrentResult)
      },
      lower_sum: ->(lhs, smooth_node, inner) {
        lower_sum(PipelineSite.new(list: lhs, options: smooth_node), inner)
      },
      lower_count: ->(lhs, smooth_node, inner) {
        lower_count(PipelineSite.new(list: lhs, options: smooth_node), inner)
      },
      lower_min: ->(lhs, smooth_node, inner) {
        lower_min(PipelineSite.new(list: lhs, options: smooth_node), inner)
      },
      lower_max: ->(lhs, smooth_node, inner) {
        lower_max(PipelineSite.new(list: lhs, options: smooth_node), inner)
      },
      lower_average: ->(lhs, smooth_node, inner) {
        lower_average(PipelineSite.new(list: lhs, options: smooth_node), inner)
      },
      with_optional_named_binding: ->(clear_name, zig_var, blk) {
        T.cast(with_optional_named_binding(clear_name, zig_var) { blk.call }, PipelineConcurrentResult)
      },
    )
  end

  sig { params(body_mir: T::Array[MIR::Emittable], fiber_rt: String).returns(String) }
  def emit_observable_body_with_rt(body_mir, fiber_rt)
    saved_emit_rt = @lowering_bridge.emitter_rt_name
    @lowering_bridge.emitter_rt_name = fiber_rt
    @lowering_bridge.with_runtime_binding_name(fiber_rt) do
      body_mir.filter_map { |stmt|
        code = @lowering_bridge.emit_expr(stmt)
        next nil if code.nil? || code.empty?
        code.strip.end_with?("}", ";") ? code : "#{code};"
      }.join("\n            ")
    end
  ensure
    @lowering_bridge.emitter_rt_name = T.must(saved_emit_rt)
  end

  sig { returns(PipelineMaterializer::RuntimeHost) }
  def build_materializer_host
    PipelineMaterializer::RuntimeHost.new(
      visit_mir: ->(node) { visit_mir(node) },
      alloc_mark_fact: ->(value, name, fallback_alloc, type_info, ast_node, context, known_allocating) {
        fact = @lowering_bridge.pipeline_alloc_mark_fact(
          value,
          name,
          fallback_alloc: fallback_alloc,
          type_info: type_info,
          ast_node: ast_node,
          context: context,
          known_allocating: known_allocating,
        )
        fact ? PipelineMaterializer::AllocationFact.new(alloc: fact.alloc, mark: fact.mark) : nil
      },
      result_alloc: -> { @lowering_bridge.pipeline_result_alloc },
      bc_target: -> { bc_target? },
      schema_lookup: -> { @lowering_bridge.mir_schema_lookup },
      next_label: -> { next_pipe_label },
      set_current_label: ->(label) { @current_pipe_label = label },
      next_item_temp_name: -> {
        @pipe_temp_counter += 1
        "__pipe_item_#{@pipe_temp_counter}"
      },
    )
  end

  sig { returns(PipelineContextState) }
  def current_context
    @pipeline_context
  end

  sig do
    type_parameters(:U)
      .params(context: PipelineContextState, blk: T.proc.returns(T.type_parameter(:U)))
      .returns(T.type_parameter(:U))
  end
  def with_context_state(context, &blk)
    previous = @pipeline_context
    @pipeline_context = context
    blk.call
  ensure
    @pipeline_context = T.must(previous)
  end

  sig do
    type_parameters(:U)
      .params(placeholder: T.nilable(String), acc: T.nilable(String), blk: T.proc.returns(T.type_parameter(:U)))
      .returns(T.type_parameter(:U))
  end
  def with_pipeline_context(placeholder: nil, acc: nil, &blk)
    with_context_state(current_context.with_pipeline_values(placeholder, acc), &blk)
  end

  sig do
    type_parameters(:U)
      .params(each_mode: T::Boolean, blk: T.proc.returns(T.type_parameter(:U)))
      .returns(T.type_parameter(:U))
  end
  def with_soa_rewrite(each_mode:, &blk)
    with_context_state(current_context.with_soa_rewrite(each_mode, Set.new), &blk)
  end

  sig { returns(String) }
  def next_pipe_label
    @pipe_label_counter += 1
    "__pblk#{@pipe_label_counter}"
  end

  sig { params(zig_t: String).returns(MIR::TypeSentinel) }
  def agg_min_sentinel_mir(zig_t)
    MIR::TypeSentinel.new(:max, zig_t)
  end

  sig { params(zig_t: String, result_type: Type).returns(T.any(MIR::Lit, MIR::TypeSentinel)) }
  def agg_max_sentinel_mir(zig_t, result_type)
    result_type.unsigned_integer? ? MIR::Lit.new("0") : MIR::TypeSentinel.new(:min, zig_t)
  end

  public

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
  sig do
    type_parameters(:U)
      .params(clear_name: T.nilable(String), zig_var: String, blk: T.proc.returns(T.type_parameter(:U)))
      .returns(T.type_parameter(:U))
  end
  def with_optional_named_binding(clear_name, zig_var, &blk)
    return blk.call if clear_name.nil?
    with_named_binding(clear_name, zig_var, &blk)
  end

  # Register a named pipeline binding for the duration of a block.
  # Saves and restores previous value so nested bindings stack correctly.
  sig do
    type_parameters(:U)
      .params(clear_name: String, zig_var: String, blk: T.proc.returns(T.type_parameter(:U)))
      .returns(T.type_parameter(:U))
  end
  def with_named_binding(clear_name, zig_var, &blk)
    with_context_state(current_context.with_named_binding(clear_name, zig_var), &blk)
  end

  # Delegate fiber capture map management to MIRLowering
  sig do
    type_parameters(:U)
      .params(
        new_entries: T::Hash[String, String],
        capture_symbols: T.nilable(T::Hash[String, SymbolEntry]),
        rt_override: String,
        blk: T.proc.returns(T.type_parameter(:U)),
      )
      .returns(T.type_parameter(:U))
  end
  def with_fiber_capture_map(new_entries, capture_symbols: nil, rt_override: "__rt", &blk)
    @lowering_bridge.with_fiber_capture_map(new_entries, capture_symbols: capture_symbols, rt_override: rt_override, &blk)
  end

  sig { params(label: String, body: T::Array[MIR::Node], result_type: Type).returns(MIR::BlockExpr) }
  def typed_block_expr(label, body, result_type)
    block = MIR::BlockExpr.new(label, body)
    block.result_type = result_type
    block
  end

  # Route AST node -> Zig string, handling pipeline-specific nodes
  # (Placeholder, SOA field rewrites) before general MIR lowering.
  sig { params(node: AST::Node).returns(T.any(String, MIR::Node)) }
  def visit(node)
    # In MIR mode, return MIR nodes instead of Zig strings.
    return visit_mir(node) if @mir_mode

    context = current_context

    if node.is_a?(AST::Identifier)
      replacement = context.replacement_for_identifier(node.name)
      return replacement if replacement
    end

    # SOA field-slice rewrite: _.field -> __soa_field[__soa_i]
    if context.soa_rewrite_active && AST.soa_placeholder_field?(node)
      target = T.cast(node, AST::GetField)
      context.soa_needed_fields << target.field
      return "__soa_#{target.field}[__soa_i]"
    end

    # SOA assignment rewrite: _.field = expr -> __soa_field[__soa_i] = expr
    if context.soa_rewrite_active && AST.soa_placeholder_assignment?(node)
      assignment = T.cast(node, T.any(AST::BindExpr, AST::Assignment))
      target = T.cast(assignment.name, AST::GetField)
      field = target.field
      context.soa_needed_fields << field
      value = T.cast(visit(T.cast(assignment.value, AST::Node)), String)
      return "__soa_#{field}[__soa_i] = #{value};"
    end

    # Before sending to MIRLowering, substitute _ placeholders and join
    # params in the AST tree. MIRLowering's lower() recurses on its own,
    # so it won't call back to us for sub-expressions.
    substituted = substitute_placeholders(node)

    # Propagate shard-direct context so MIRLowering emits putDirect/getDirect
    # General case: lower to MIR, emit to Zig
    mir_node = @lowering_bridge.lower_node(substituted)
    T.must(@lowering_bridge.emit_mir(mir_node))
  end

  # MIR-mode visit: returns MIR node instead of Zig string.
  # Used by lower_* pipeline methods during MIR migration.
  sig { params(node: AST::Node).returns(MIR::Node) }
  def visit_mir(node)
    substituted = substitute_placeholders(node)
    @lowering_bridge.lower_node(substituted)
  end

  # Lower an array of AST body statements to MIR nodes, with pipeline
  # placeholder substitution. Used by side-effect operators (Tap, Each, Join)
  # whose loop bodies contain multiple statements.
  sig { params(body_stmts: T::Array[AST::Node], placeholder: String).returns(T::Array[MIR::Emittable]) }
  def visit_pipeline_body_mir(body_stmts, placeholder:)
    with_pipeline_context(placeholder: placeholder) do
      substituted = body_stmts.map { |stmt| substitute_placeholders(stmt) }
      @lowering_bridge.lower_body(substituted)
    end
  end

  private

  # Check whether any statement in an AST array references the `_` placeholder.
  # Used to decide whether to use `|__each_item|` vs `|_|` in while captures.
  sig { params(stmts: T::Array[AST::Node]).returns(T::Boolean) }
  def ast_stmts_use_placeholder?(stmts)
    PipelinePlaceholderUsage.statements_use_placeholder?(stmts)
  end

  sig { params(node: T.nilable(T.any(AST::Node, Object))).returns(T::Boolean) }
  def ast_node_uses_placeholder?(node)
    PipelinePlaceholderUsage.node_uses_placeholder?(node)
  end

  # Recursively replace AST::Identifier("_") with the current placeholder name,
  # and join param names with their Zig loop variable names.
  # Returns the node (possibly modified) or a new synthetic Identifier.
  sig { params(node: AST::Node).returns(AST::Node) }
  def substitute_placeholders(node)
    PipelinePlaceholderRewriter.new(current_context).substitute(node)
  end

  public

  # MIR entry point: returns MIR node tree for migrated pipeline operators.
  # Returns nil for non-migrated operators (caller falls back to string path).
  sig { params(node: AST::BinaryOp).returns(PipelineLoweringResult) }
  def lower_pipeline(node)
    plan = @plan_builder.build(node)
    return nil unless plan

    lower_dispatch_plan(plan)
  end

  sig { params(plan: PipelineOperationPlan).returns(PipelineLoweringResult) }
  def lower_dispatch_plan(plan)
    lower_execution_plan(plan.execution, plan)
  end

  sig { params(execution: PipelineExecutionKind, plan: PipelineOperationPlan).returns(PipelineLoweringResult) }
  def lower_execution_plan(execution, plan)
    case execution
    when PipelineExecutionKind::SoaScalarFold
      lower_soa_scalar_fold(plan.site, T.cast(plan.rhs, PipelineMaterializedScalarOp))
    when PipelineExecutionKind::FusedRangeFold
      range_chain = T.must(plan.source.range_chain)
      lower_range_fold(range_chain.source, range_chain.stages, T.cast(plan.rhs, DefaultObservableFoldOp), plan.site.options)
    when PipelineExecutionKind::FusedRangeReduce
      range_chain = T.must(plan.source.range_chain)
      lower_range_reduce(range_chain.source, range_chain.stages, T.cast(plan.rhs, AST::ReduceOp), plan.site.options)
    when PipelineExecutionKind::BindingChain
      lower_binding_chain(T.must(plan.source.binding_chain), plan.site.options)
    when PipelineExecutionKind::MaterializedScalar
      @scalar_lowerer.lower(plan.site, T.cast(plan.rhs, PipelineMaterializedScalarOp))
    when PipelineExecutionKind::MaterializedList
      @list_lowerer.lower(plan.site, T.cast(plan.rhs, PipelineListTerminalOp))
    when PipelineExecutionKind::SetDistinct
      lower_distinct(plan.site, T.cast(plan.rhs, AST::DistinctOp))
    when PipelineExecutionKind::BatchWindow
      lower_batch_window(plan.site, T.cast(plan.rhs, AST::BatchWindowOp))
    when PipelineExecutionKind::SetIndex
      lower_index(plan.site, T.cast(T.cast(plan.rhs, AST::IndexOp).expression, AST::Node))
    when PipelineExecutionKind::Each
      lower_each(plan.site, T.cast(plan.rhs, AST::EachOp))
    when PipelineExecutionKind::Concurrent
      lower_concurrent(plan.site, T.cast(plan.rhs, AST::ConcurrentOp))
    end
  end

  private

  HEAP_ALLOC = "rt.heapAlloc()"
  ALLOC_REF_DEF = T.let(FunctionSignature.borrowing_intrinsic, FunctionSignature)

  sig { params(list_node: AST::Node, blk: T.proc.params(items_ident: String, label: String).returns(T::Array[MIR::Emittable])).returns(MIR::BlockExpr) }
  def pipeline_block(list_node, &blk)
    @materializer.pipeline_block(list_node, &blk)
  end

  sig { returns(Symbol) }
  def pipeline_result_alloc
    @materializer.result_alloc
  end

  sig { returns(MIRLoweringSchemas::SchemaLookup) }
  def pipeline_schema_lookup
    @materializer.schema_lookup
  end

  sig { params(receiver: String, alloc: Symbol, value_expr: MIR::Node).returns(MIR::Emittable) }
  def append_owned_value_stmt(receiver, alloc, value_expr)
    @materializer.append_owned_value_stmt(receiver, alloc, value_expr)
  end

  sig { params(value: MIR::Node, type_info: Type, alloc: Symbol).returns(MIR::Node) }
  def borrowed_pipeline_value(value, type_info, alloc)
    @materializer.borrowed_pipeline_value(value, type_info, alloc)
  end

  sig { params(type_info: Type).returns(T::Boolean) }
  def cleanup_bearing_type?(type_info)
    @materializer.cleanup_bearing_type?(type_info)
  end

  sig { params(name: String, source: MIR::Node, type_info: Type, zig_type: String, alloc: Symbol).returns(T::Array[MIR::Emittable]) }
  def owning_pipeline_temp_stmts(name, source, type_info, zig_type, alloc)
    @materializer.owning_pipeline_temp_stmts(name, source, type_info, zig_type, alloc)
  end

  sig { params(lhs: AST::Node).returns(T::Array[MIR::Emittable]) }
  def concurrent_source_setup(lhs)
    @materializer.concurrent_source_setup(lhs)
  end

  # Visit pipeline expression in MIR mode with placeholder substitution.
  sig { params(list_node: AST::Node, expr_node: AST::Node, placeholder: String).returns(MIR::Node) }
  def visit_pipeline_expr_mir(list_node, expr_node, placeholder = "it")
    with_pipeline_context(placeholder: placeholder) do
      visit_mir(expr_node)
    end
  end

  sig { params(node: T.nilable(T.any(AST::Node, Object))).returns(T::Boolean) }
  def ast_uses_bare_placeholder?(node)
    PipelinePlaceholderUsage.node_uses_bare_placeholder?(node)
  end

  sig { params(site: PipelineHost::PipelineSite, fold_node: PipelineMaterializedScalarOp).returns(MIR::BlockExpr) }
  def lower_soa_scalar_fold(site, fold_node)
    list_node = site.list
    label = next_pipe_label
    source_mir = visit_mir(list_node)
    @current_pipe_label = label

    expr_mir = T.let(nil, T.nilable(MIR::Emittable))
    fields = T.let([], T::Array[String])
    needs_whole_item = T.let(false, T::Boolean)

    with_soa_rewrite(each_mode: false) do
      if fold_node.respond_to?(:expression)
        expr_mir = with_pipeline_context(placeholder: "it") { visit_mir(fold_node.expression) }
      end
      fields = current_context.soa_needed_fields.map(&:to_s).sort
      needs_whole_item = fold_node.is_a?(AST::FindOp) ||
        !!(fold_node.respond_to?(:expression) && ast_uses_bare_placeholder?(fold_node.expression))
    end

    build_soa_scalar_fold_block(site, fold_node, label, source_mir, T.must(expr_mir), fields, needs_whole_item)
  end

  sig { params(site: PipelineHost::PipelineSite, fold_node: PipelineMaterializedScalarOp, label: String, source_mir: MIR::Node, expr_mir: MIR::Node, fields: T::Array[String], needs_whole_item: T::Boolean).returns(MIR::BlockExpr) }
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
      init_stmts << MIR::Let.new("count_result", MIR::Lit.new("0"), true, Type.new("i64"), nil)
      loop_body << MIR::IfStmt.new(expr_mir, [
        MIR::Set.new(MIR::Ident.new("count_result"), MIR::BinOp.new("+", MIR::Ident.new("count_result"), MIR::Lit.new("1")))
      ], nil)
      final_expr = MIR::Ident.new("count_result")
    when AST::SumOp
      init_stmts << MIR::Let.new("sum_result", MIR::Lit.new("0"), true, Type.new(result_type), nil)
      loop_body << MIR::Set.new(MIR::Ident.new("sum_result"), MIR::BinOp.new("+", MIR::Ident.new("sum_result"), expr_mir))
      final_expr = MIR::Ident.new("sum_result")
    when AST::AverageOp
      init_stmts << MIR::Let.new("avg_sum", MIR::Lit.new("0"), true, Type.new("f64"), nil)
      init_stmts << MIR::Let.new("avg_count", len_expr, false, nil, nil)
      loop_body << MIR::Set.new(MIR::Ident.new("avg_sum"), MIR::BinOp.new("+", MIR::Ident.new("avg_sum"), expr_mir))
      final_expr = MIR::Conditional.new(
        MIR::BinOp.new("==", MIR::Ident.new("avg_count"), MIR::Lit.new("0")),
        MIR::Cast.new(MIR::Lit.new("0"), "f64", :as),
        MIR::BinOp.new("/", MIR::Ident.new("avg_sum"),
          MIR::Cast.new(MIR::Cast.new(MIR::Ident.new("avg_count"), nil, :floatFromInt), "f64", :as)))
    when AST::MinOp
      init_stmts << MIR::IfStmt.new(MIR::BinOp.new("==", len_expr, MIR::Lit.new("0")), [MIR::Panic.new("MIN applied to empty list")], nil)
      init_stmts << MIR::Let.new("min_result", MIR::TypeSentinel.new(:max, result_type), true, Type.new(result_type), nil)
      loop_body << MIR::Let.new("min_val", expr_mir, false, nil, nil)
      loop_body << MIR::IfStmt.new(MIR::BinOp.new("<", MIR::Ident.new("min_val"), MIR::Ident.new("min_result")),
        [MIR::Set.new(MIR::Ident.new("min_result"), MIR::Ident.new("min_val"))], nil)
      final_expr = MIR::Ident.new("min_result")
    when AST::MaxOp
      init_stmts << MIR::IfStmt.new(MIR::BinOp.new("==", len_expr, MIR::Lit.new("0")), [MIR::Panic.new("MAX applied to empty list")], nil)
      init_stmts << MIR::Let.new("max_result", MIR::TypeSentinel.new(:min, result_type), true, Type.new(result_type), nil)
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
      elem_zig_type = transpile_type(T.must(list_node.full_type!.element_type).resolved.to_s)
      init_stmts << MIR::Let.new("find_result", MIR::Undef.new(nil), true, Type.new(elem_zig_type), nil)
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
    @scalar_lowerer.lower(site, count_node)
  end

  sig { params(site: PipelineHost::PipelineSite, sum_node: AST::SumOp).returns(MIR::BlockExpr) }
  def lower_sum(site, sum_node)
    @scalar_lowerer.lower(site, sum_node)
  end

  sig { params(site: PipelineHost::PipelineSite, avg_node: AST::AverageOp).returns(MIR::BlockExpr) }
  def lower_average(site, avg_node)
    @scalar_lowerer.lower(site, avg_node)
  end

  sig { params(site: PipelineHost::PipelineSite, min_node: AST::MinOp).returns(MIR::BlockExpr) }
  def lower_min(site, min_node)
    @scalar_lowerer.lower(site, min_node)
  end

  sig { params(site: PipelineHost::PipelineSite, max_node: AST::MaxOp).returns(MIR::BlockExpr) }
  def lower_max(site, max_node)
    @scalar_lowerer.lower(site, max_node)
  end

  sig { params(site: PipelineHost::PipelineSite, any_node: AST::AnyOp).returns(MIR::BlockExpr) }
  def lower_any(site, any_node)
    @scalar_lowerer.lower(site, any_node)
  end

  sig { params(site: PipelineHost::PipelineSite, all_node: AST::AllOp).returns(MIR::BlockExpr) }
  def lower_all(site, all_node)
    @scalar_lowerer.lower(site, all_node)
  end

  sig { params(site: PipelineHost::PipelineSite, find_node: AST::FindOp).returns(MIR::BlockExpr) }
  def lower_find(site, find_node)
    @scalar_lowerer.lower(site, find_node)
  end

  # --- Filter/transform operator lowerings (Phase 2) ---

  sig { params(smooth_node: AST::BinaryOp).returns(Symbol) }
  def pipeline_alloc(smooth_node)
    pipeline_result_alloc
  end

  sig { params(site: PipelineHost::PipelineSite, expr_node: AST::Node).returns(MIR::BlockExpr) }
  def lower_where(site, expr_node)
    @list_lowerer.lower_where_expr(site, expr_node)
  end

  sig { params(site: PipelineHost::PipelineSite, expr_node: AST::Node).returns(MIR::BlockExpr) }
  def lower_select(site, expr_node)
    @list_lowerer.lower_select_expr(site, expr_node)
  end

  sig { params(site: PipelineHost::PipelineSite, limit_node: AST::LimitOp).returns(MIR::BlockExpr) }
  def lower_limit(site, limit_node)
    @list_lowerer.lower(site, limit_node)
  end

  sig { params(site: PipelineHost::PipelineSite, expr_node: AST::Node).returns(MIR::BlockExpr) }
  def lower_take_while(site, expr_node)
    @list_lowerer.lower_take_while_expr(site, expr_node)
  end

  sig { params(site: PipelineHost::PipelineSite, skip_node: AST::SkipOp).returns(MIR::BlockExpr) }
  def lower_skip(site, skip_node)
    @list_lowerer.lower(site, skip_node)
  end

  sig { params(site: PipelineHost::PipelineSite, distinct_node: AST::DistinctOp).returns(MIR::BlockExpr) }
  def lower_distinct(site, distinct_node)
    @set_index_lowerer.lower_distinct(
      site.list,
      site.options,
      distinct_node,
    )
  end

  # --- Complex operator lowerings (Phase 3) ---

  sig { params(site: PipelineHost::PipelineSite, unnest_node: AST::UnnestOp).returns(MIR::BlockExpr) }
  def lower_unnest(site, unnest_node)
    @list_lowerer.lower(site, unnest_node)
  end

  sig { params(site: PipelineHost::PipelineSite, reduce_node: AST::ReduceOp).returns(MIR::BlockExpr) }
  def lower_reduce(site, reduce_node)
    @list_lowerer.lower(site, reduce_node)
  end

  sig { params(site: PipelineHost::PipelineSite, window_node: AST::WindowOp).returns(MIR::BlockExpr) }
  def lower_window(site, window_node)
    @list_lowerer.lower(site, window_node)
  end

  sig { params(site: PipelineHost::PipelineSite, bw_node: AST::BatchWindowOp).returns(MIR::BlockExpr) }
  def lower_batch_window(site, bw_node)
    @batch_window_lowerer.lower(
      site.list,
      site.options,
      bw_node,
    )
  end

  sig { params(site: PipelineHost::PipelineSite, order_node: AST::OrderByOp).returns(MIR::BlockExpr) }
  def lower_order_by(site, order_node)
    @list_lowerer.lower(site, order_node)
  end

  sig { params(site: PipelineHost::PipelineSite, expr_node: AST::Node).returns(MIR::BlockExpr) }
  def lower_index(site, expr_node)
    @set_index_lowerer.lower_index(
      site.list,
      site.options,
      expr_node,
    )
  end

  sig { params(site: PipelineHost::PipelineSite, join_node: AST::JoinOp).returns(MIR::BlockExpr) }
  def lower_join(site, join_node)
    @list_lowerer.lower(site, join_node)
  end

  sig { params(site: PipelineHost::PipelineSite, tap_op: AST::TapOp).returns(MIR::BlockExpr) }
  def lower_tap(site, tap_op)
    @list_lowerer.lower(site, tap_op)
  end

  # --- Side-effect operator lowerings (Phase 4) ---

  sig { params(site: PipelineHost::PipelineSite, each_op: AST::EachOp).returns(PipelineEachResult) }
  def lower_each(site, each_op)
    @each_lowerer.lower(site.list, each_op)
  end

  sig { params(list_node: AST::Node, each_op: AST::EachOp).returns(MIR::ScopeBlock) }
  def lower_sharded_each(list_node, each_op)
    @concurrent_lowerer.lower_sharded_each(list_node, each_op)
  end

  sig { params(node: AST::Node).returns(T::Boolean) }
  def finite_stream_source_node?(node)
    @range_lowerer.finite_stream_source_node?(node)
  end

  # Walk a BinaryOp(SMOOTH) left-spine looking for a finite stream source
  # with only fusible stages between.
  sig { params(node: AST::Node).returns(T.nilable(PipelineRangeChain)) }
  def unwrap_range_chain(node)
    @range_lowerer.unwrap_range_chain(node)
  end

  sig { params(node: AST::BinaryOp).returns(T.nilable(BindingUnnestChain)) }
  def unwrap_binding_unnest_chain(node)
    @binding_chain_lowerer.unwrap_chain(node)
  end

  sig { params(chain: BindingUnnestChain, smooth_node: AST::BinaryOp).returns(MIR::BlockExpr) }
  def lower_binding_chain(chain, smooth_node)
    @binding_chain_lowerer.lower(chain, smooth_node)
  end

  # Lower a fold expression with integer→float coercion when the
  # accumulator is a float type. SUM/AVERAGE/MIN/MAX accumulators may
  # be f64 (always for AVERAGE); integer items in those folds need
  # `@floatFromInt`. Integer-into-integer and float-into-float folds
  # pass through unchanged. Returns a proper MIR node -- no InlineZig
  # string embedding.
  sig { params(expr_ast: AST::Node, item_var: String, acc_zig: String).returns(MIR::Node) }
  def numeric_fold_expr_typed(expr_ast, item_var, acc_zig)
    @range_lowerer.numeric_fold_expr_typed(expr_ast, item_var, acc_zig)
  end

  # Build the LazyRange init + stage prefix shared by lower_each_range and lower_range_fold.
  # `item_used` tracks whether the initial capture (`__each_item`) is referenced
  # by any stage -- used by callers to decide between |__each_item| and |_| in Zig.
  sig { params(source_node: AST::Node, stages: T::Array[AST::Node], on_skip: T.nilable(PipelineRangeSkipHook)).returns(PipelineHost::LazyRangePrefix) }
  def build_lazy_range_prefix(source_node, stages, on_skip: nil)
    @range_lowerer.build_lazy_range_prefix(source_node, stages, on_skip: on_skip)
  end

  # Emit a fused while loop for a finite stream source with zero or more fusible stages.
  sig { params(range_lit: AST::Node, stages: T::Array[AST::Node], each_op: AST::EachOp).returns(MIR::ScopeBlock) }
  def lower_each_range(range_lit, stages, each_op)
    @range_lowerer.lower_each_range(range_lit, stages, each_op)
  end

  # When the BC backend would otherwise emit `while (range.next()) |x| { ... }`,
  # rewrite the loop as a structural ForStmt+IterRange so the existing FOR
  # opcode path drives iteration. The fusion stage_stmts (BreakStmt for
  # TAKE_WHILE/LIMIT, ContinueStmt for WHERE/SKIP) compose cleanly inside
  # a ForStmt, so semantics are preserved.
  sig { params(range_lit: AST::RangeLit, capture_name: T.nilable(String)).returns(BcIterRange) }
  def bc_for_iter_range(range_lit, capture_name)
    @range_lowerer.bc_for_iter_range(range_lit, capture_name)
  end

  sig { returns(T::Boolean) }
  def bc_target?
    @lowering_bridge.bc_target?
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
  #   - `acc_alloc_expr`: the MIR expression that constructs the wrapper
  #     (typically `WrapperT.new(rt.heapAlloc()) catch unreachable`,
  #     but seeded variants like REDUCE pass `WrapperT.newWith(...)`).
  #   - `publish_stmts`: the MIR statements that publish one item to
  #     the accumulator. Each terminal builds its own (e.g. SUM emits
  #     `acc.inner.add(expr)`; COUNT emits `if pred then acc.inner.inc()`;
  #     ANY/ALL emit `acc.inner.submit(pred_eval)`; ...). The wrapper
  #     does not expose `add`/`inc`/`submit`/`update` -- consumers go
  #     through `acc.inner` so ObservableTerminal stays per-terminal
  #     surface-free.
  sig { params(p: PipelineHost::LazyRangePrefix, smooth_node: AST::BinaryOp, label: String, source_node: AST::Node, acc_alloc_expr: MIR::Emittable, publish_stmts: T::Array[MIR::Emittable]).returns(MIR::BlockExpr) }
  def lower_range_fold_observable(p, smooth_node, label, source_node,
                                  acc_alloc_expr:, publish_stmts:)
    @range_lowerer.lower_range_fold_observable(p, smooth_node, label, source_node,
      acc_alloc_expr: acc_alloc_expr,
      publish_stmts: publish_stmts)
  end

  # Single shared lowering for SUM/COUNT/MAX/MIN/AVG/ANY/ALL/FIND.
  # REDUCE and DISTINCT need seeded inits or inline CAS, so they keep
  # dedicated helpers below.
  sig { params(p: PipelineHost::LazyRangePrefix, fold_op: DefaultObservableFoldOp, smooth_node: AST::BinaryOp, label: String, source_node: AST::Node, terminal: Symbol).returns(MIR::BlockExpr) }
  def lower_range_fold_observable_default(p, fold_op, smooth_node, label, source_node, terminal:)
    @range_lowerer.lower_range_fold_observable_default(p, fold_op, smooth_node, label, source_node, terminal: terminal)
  end

  sig { params(type_info: Type).returns(T::Boolean) }
  def pipeline_element_owns_heap?(type_info)
    @range_lowerer.pipeline_element_owns_heap?(type_info)
  end

  sig { params(item_var: String, source_node: AST::Node).returns(T::Array[MIR::Emittable]) }
  def consumed_stream_item_cleanup(item_var, source_node)
    @range_lowerer.consumed_stream_item_cleanup(item_var, source_node)
  end

  # REDUCE-scalar: per-item publish is a CAS loop that applies the
  # user-supplied reducer body. We emit the loop inline (rather than
  # using AtomicReduce.update + a comptime fn pointer) because the
  # reducer body references stage-context (`_` and `acc`), which is
  # easier to inline than to lift into a top-level Zig fn.
  #
  # Wrapper: `*ObservableReduce(T)` -- the Inner is `AtomicReduce(T)`
  # which needs a seeded init(initial). Caller passes `newWith(...)`.
  sig { params(p: PipelineHost::LazyRangePrefix, reduce_op: AST::ReduceOp, smooth_node: AST::BinaryOp, label: String, source_node: AST::Node).returns(MIR::BlockExpr) }
  def lower_range_reduce_observable(p, reduce_op, smooth_node, label, source_node)
    @range_lowerer.lower_range_reduce_observable(p, reduce_op, smooth_node, label, source_node)
  end

  # DISTINCT into ~T[]@set:observable (dynamic) or ~T[N]@set:observable
  # (bounded). Inner is `StreamSet(T)` for the dynamic shape (geometric
  # grow + refcounted snapshots) or `StreamSetBounded(T, N)` for the
  # bounded shape (fixed [N]T buffer, no grow, no refcounting). Both
  # take an allocator -- non-default-init Inner -- so we use newWith(...).
  # Per-item publish:
  #   - dynamic:  `_ = acc.inner.submit(item) catch unreachable`  (fallible: grow can fail)
  #   - bounded:  `_ = acc.inner.submit(item)`                    (infallible: no grow path)
  sig { params(p: PipelineHost::LazyRangePrefix, distinct_op: AST::DistinctOp, smooth_node: AST::BinaryOp, label: String, source_node: AST::Node).returns(MIR::BlockExpr) }
  def lower_range_fold_observable_distinct(p, distinct_op, smooth_node, label, source_node)
    @range_lowerer.lower_range_fold_observable_distinct(p, distinct_op, smooth_node, label, source_node)
  end

  # Default-init Observable<Terminal>.new allocator call. The wrapper Zig
  # type comes from Type#zig_type via smooth_node.full_type!, so terminals
  # whose Inner default-constructs (SUM/COUNT/AVG/ANY/ALL/FIND) all share
  # this one builder. MAX/MIN/REDUCE need a seeded init -- they pass
  # their own `acc_alloc_expr`.
  sig { params(smooth_node: AST::BinaryOp).returns(MIR::TryCatch) }
  def default_obs_alloc_expr(smooth_node)
    @range_lowerer.default_obs_alloc_expr(smooth_node)
  end

  sig { params(expr: MIR::Node).returns(MIR::TryCatch) }
  def observable_catch_unreachable(expr)
    @range_lowerer.observable_catch_unreachable(expr)
  end

  sig { params(target: String, method: String, args: T::Array[MIR::Emittable]).returns(MIR::TryCatch) }
  def observable_alloc_expr(target, method, args)
    @range_lowerer.observable_alloc_expr(target, method, args)
  end

  sig { params(range_lit: AST::Node, stages: T::Array[AST::Node], fold_op: DefaultObservableFoldOp, smooth_node: AST::BinaryOp).returns(MIR::BlockExpr) }
  def lower_range_fold(range_lit, stages, fold_op, smooth_node)
    @range_lowerer.lower_range_fold(range_lit, stages, fold_op, smooth_node)
  end

  sig { params(range_lit: AST::Node, stages: T::Array[AST::Node], reduce_op: AST::ReduceOp, smooth_node: T.nilable(AST::BinaryOp)).returns(MIR::BlockExpr) }
  def lower_range_reduce(range_lit, stages, reduce_op, smooth_node = nil)
    @range_lowerer.lower_range_reduce(range_lit, stages, reduce_op, smooth_node)
  end

  # CONCURRENT pipeline: supported shapes lower through structural MIR or
  # runtime-backed InlineZig calls. Falling through here is now a migration bug.
  sig { params(site: PipelineHost::PipelineSite, conc_op: AST::ConcurrentOp).returns(PipelineConcurrentResult) }
  def lower_concurrent(site, conc_op)
    @concurrent_lowerer.lower(site.options, conc_op)
  end

end
