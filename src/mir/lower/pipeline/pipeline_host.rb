# typed: strict
require "sorbet-runtime"

require "set"
require_relative "./pipeline_context"
require_relative "../../../backends/zig_type_mapper"
require_relative "./pipeline_materializer"
require_relative "./pipeline_range_lowerer"
require_relative "./pipeline_concurrent_lowerer"
require_relative "./pipeline_batch_window_lowerer"
require_relative "./pipeline_set_index_lowerer"
require_relative "./pipeline_each_lowerer"
require_relative "../../fiber_ctx_builder"
require_relative "../../placement"

# MIR pipeline lowering host. It owns cross-operator pipeline context and
# delegates operator families to typed lowerers that emit structural MIR.
class PipelineHost
    extend T::Sig

  include ZigTypeMapper

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

  BcIterRange = T.type_alias { PipelineBcIterRange }
  LazyRangePrefix = PipelineLazyRangePrefix
  DefaultObservableFoldOp = T.type_alias { PipelineDefaultObservableFoldOp }

  class BindingUnnestChain < T::Struct
    extend T::Sig

    const :source, AST::Node
    const :outer_binding, String
    const :unnest_expr, AST::Node
    const :inner_binding, T.nilable(String)
    const :stages, T::Array[AST::Node]
    const :fold, AST::Node

    sig { params(key: Symbol).returns(T.nilable(T.any(AST::Node, String, T::Array[AST::Node]))) }
    def [](key)
      case key
      when :source then source
      when :outer_binding then outer_binding
      when :unnest_expr then unnest_expr
      when :inner_binding then inner_binding
      when :stages then stages
      when :fold then fold
      end
    end
  end

  sig { returns(T.untyped) }
  attr_reader :fn_sigs

  sig { params(lowering: T.untyped, emitter: MIREmitter).void }
  def initialize(lowering:, emitter:)
    @lowering = lowering
    @emitter = emitter
    @fn_sigs = T.let(lowering.fn_sigs, T.untyped)
    @pipeline_context = T.let(PipelineContextState.empty, PipelineContextState)
    @mir_mode = T.let(false, T::Boolean)
    @each_idx_counter = T.let(0, Integer)
    @sh_counter = T.let(nil, T.nilable(Integer))
    @bounded_conc_counter = T.let(nil, T.nilable(Integer))
    @pipe_label_counter = T.let(0, Integer)
    @pipe_temp_counter = T.let(0, Integer)
    @current_pipe_label = T.let(nil, T.nilable(String))
    @do_rt_name = T.let(nil, T.nilable(String))
    @materializer = T.let(PipelineMaterializer.new(host: build_materializer_host), PipelineMaterializer)
    @range_lowerer = T.let(PipelineRangeLowerer.new(host: build_range_lowerer_host), PipelineRangeLowerer)
    @concurrent_lowerer = T.let(PipelineConcurrentLowerer.new(services: build_concurrent_services), PipelineConcurrentLowerer)
    @batch_window_lowerer = T.let(PipelineBatchWindowLowerer.new(services: build_batch_window_services), PipelineBatchWindowLowerer)
    @set_index_lowerer = T.let(PipelineSetIndexLowerer.new(services: build_set_index_services), PipelineSetIndexLowerer)
    @each_lowerer = T.let(PipelineEachLowerer.new(services: build_each_services), PipelineEachLowerer)
  end

  private

  sig { returns(PipelineEachServices) }
  def build_each_services
    PipelineEachServices.new(
      bc_target: -> { bc_target? },
      visit_mir: ->(node) { T.cast(visit_mir(node), MIR::Node) },
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
      lower_sharded_each: ->(list_node, each_op) { lower_sharded_each(PipelineSite.new(list: list_node, options: list_node), each_op) },
      ast_stmts_use_placeholder: ->(body_stmts) { ast_stmts_use_placeholder?(body_stmts) },
      next_index_name: -> {
        @each_idx_counter += 1
        "__each_i_#{@each_idx_counter}"
      },
    )
  end

  sig { returns(PipelineSetIndexServices) }
  def build_set_index_services
    PipelineSetIndexServices.new(
      bc_target: -> { bc_target? },
      visit_mir: ->(node) { T.cast(visit_mir(node), MIR::Node) },
      visit_mir_with_placeholder: ->(node, placeholder) {
        T.cast(with_pipeline_context(placeholder: placeholder) { visit_mir(node) }, MIR::Node)
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
        fact = @lowering.pipeline_alloc_mark_fact(
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
        @lowering.pipeline_owned_cleanup_entry(value, ast_node)
      },
      pipeline_index_insert_with_ownership: ->(insert, value, value_owns, target_alloc) {
        @lowering.pipeline_index_insert_with_ownership(insert, value, value_owns, target_alloc: target_alloc)
      },
      index_temp_name: -> { "__idx_item_#{@pipe_temp_counter + 1}" },
    )
  end

  sig { returns(PipelineBatchWindowServices) }
  def build_batch_window_services
    PipelineBatchWindowServices.new(
      bc_target: -> { bc_target? },
      visit_mir: ->(node) { T.cast(visit_mir(node), MIR::Node) },
      visit_mir_with_placeholder: ->(node, placeholder) {
        T.cast(with_pipeline_context(placeholder: placeholder) { visit_mir(node) }, MIR::Node)
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
      visit_mir: ->(node) { T.cast(visit_mir(node), MIR::Node) },
      visit_mir_with_context: ->(node, placeholder, acc) {
        T.cast(with_pipeline_context(placeholder: placeholder, acc: acc) { visit_mir(node) }, MIR::Node)
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
        @lowering.next_pipeline_observable_id
      },
      emit_observable_body: ->(body_mir, fiber_rt) { emit_observable_body_with_rt(body_mir, fiber_rt) },
      task_config_zig: -> { @lowering.task_config_zig(nil, nil) },
    )
  end

  sig { returns(PipelineConcurrentServices) }
  def build_concurrent_services
    PipelineConcurrentServices.new(
      bc_target: -> { bc_target? },
      visit_mir: ->(node) {
        T.cast(visit_mir(node), MIR::Node)
      },
      visit_mir_with_placeholder: ->(node, placeholder) {
        T.cast(with_pipeline_context(placeholder: placeholder) { visit_mir(node) }, MIR::Node)
      },
      visit_body_with_placeholder: ->(body_stmts, placeholder) {
        visit_pipeline_body_mir(body_stmts, placeholder: placeholder)
      },
      lower_head_with_placeholder: ->(node, placeholder) {
        value, pending = @lowering.lower_head {
          T.cast(with_pipeline_context(placeholder: placeholder) { visit_mir(node) }, MIR::Node)
        }
        PipelineConcurrentHeadResult.new(
          value: T.cast(value, MIR::Node),
          pending: T.cast(pending, T::Array[MIR::Emittable]),
        )
      },
      callback_expr_mir: ->(expr, placeholder, capture_map, capture_symbols, rt_override) {
        T.cast(with_pipeline_context(placeholder: placeholder) {
          with_fiber_capture_map(capture_map, capture_symbols: capture_symbols, rt_override: rt_override) {
            visit_mir(expr)
          }
        }, MIR::Node)
      },
      callback_body_mir: ->(body_stmts, placeholder, capture_map, capture_symbols, rt_override) {
        T.cast(with_pipeline_context(placeholder: placeholder) {
          with_fiber_capture_map(capture_map, capture_symbols: capture_symbols, rt_override: rt_override) {
            visit_pipeline_body_mir(body_stmts, placeholder: placeholder)
          }
        }, T::Array[MIR::Emittable])
      },
      pipeline_alloc_mark_fact: ->(value, name, fallback_alloc, type_info, ast_node, accept_owned_call, include_cleanup) {
        fact = @lowering.pipeline_alloc_mark_fact(
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
        T.cast(@lowering.append_ownership_transfers_for_mir_body(body), T::Array[MIR::Emittable])
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
        T.cast(@lowering.emit_builtin(name, args), MIR::Node)
      },
      emit_expr: ->(node) {
        @lowering.emit_expr(node)
      },
      lower_mir: ->(node) {
        T.cast(@lowering.lower(node), MIR::Node)
      },
      next_label: -> { next_pipe_label },
      typed_block_expr: ->(label, body, result_type) {
        typed_block_expr(label, T.cast(body, T::Array[MIR::Node]), result_type)
      },
      task_config_variant: ->(size_name) {
        @lowering.task_config_variant(size_name, nil)
      },
      guarded_cleanup_name: ->(name) {
        @lowering.pipeline_guarded_cleanup_name?(name)
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
    saved_emit_rt = @emitter.rt_name
    @emitter.rt_name = fiber_rt
    @lowering.with_runtime_binding_name(fiber_rt) do
      body_mir.filter_map { |stmt|
        code = @lowering.emit_expr(stmt)
        next nil if code.nil? || code.empty?
        code.strip.end_with?("}", ";") ? code : "#{code};"
      }.join("\n            ")
    end
  ensure
    @emitter.rt_name = T.must(saved_emit_rt)
  end

  sig { returns(PipelineMaterializer::RuntimeHost) }
  def build_materializer_host
    PipelineMaterializer::RuntimeHost.new(
      visit_mir: ->(node) { T.cast(visit_mir(node), MIR::Node) },
      alloc_mark_fact: ->(value, name, fallback_alloc, type_info, ast_node, context, known_allocating) {
        fact = @lowering.pipeline_alloc_mark_fact(
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
      result_alloc: -> { @lowering.pipeline_result_alloc },
      bc_target: -> { bc_target? },
      schema_lookup: -> { @lowering.mir_schema_lookup },
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
  sig { params(new_entries: T::Hash[String, String], capture_symbols: T.nilable(T::Hash[String, SymbolEntry]), rt_override: String, blk: T.untyped).returns(T.untyped) }
  def with_fiber_capture_map(new_entries, capture_symbols: nil, rt_override: "__rt", &blk)
    @lowering.with_fiber_capture_map(new_entries, capture_symbols: capture_symbols, rt_override: rt_override, &blk)
  end

  sig { params(label: String, body: T::Array[MIR::Node], result_type: Type).returns(MIR::BlockExpr) }
  def typed_block_expr(label, body, result_type)
    block = MIR::BlockExpr.new(label, body)
    block.result_type = result_type
    block
  end

  # Route AST node -> Zig string, handling pipeline-specific nodes
  # (Placeholder, SOA field rewrites) before general MIR lowering.
  sig { params(node: T.untyped).returns(String) }
  def visit(node)
    # In MIR mode, return MIR nodes instead of Zig strings.
    return visit_mir(node) if @mir_mode

    context = current_context

    # Placeholder: _ inside pipeline expression -> loop variable name
    if node.is_a?(AST::Identifier) && node.name == "_" && context.placeholder_name
      return T.must(context.placeholder_name)
    end

    # Join param map: lambda param names -> Zig loop variables
    join_param_map = context.join_param_map
    if node.is_a?(AST::Identifier) && join_param_map && join_param_map[node.name]
      return join_param_map.fetch(node.name)
    end

    # Named pipeline binding: $u -> registered Zig var (e.g. "__pipe_u")
    if node.is_a?(AST::Identifier) && !context.named_bindings.empty? && context.named_bindings.key?(node.name)
      return context.named_bindings.fetch(node.name)
    end

    # SOA field-slice rewrite: _.field -> __soa_field[__soa_i]
    if context.soa_rewrite_active && AST.soa_placeholder_field?(node)
      context.soa_needed_fields << node.field
      return "__soa_#{node.field}[__soa_i]"
    end

    # SOA assignment rewrite: _.field = expr -> __soa_field[__soa_i] = expr
    if context.soa_rewrite_active && AST.soa_placeholder_assignment?(node)
      field = node.name.field
      context.soa_needed_fields << field
      value = visit(node.value)
      return "__soa_#{field}[__soa_i] = #{value};"
    end

    # Accumulator placeholder
    if node.is_a?(AST::Identifier) && node.name == "acc" && context.acc_placeholder
      return T.must(context.acc_placeholder)
    end

    # Before sending to MIRLowering, substitute _ placeholders and join
    # params in the AST tree. MIRLowering's lower() recurses on its own,
    # so it won't call back to us for sub-expressions.
    substituted = substitute_placeholders(node)

    # Propagate shard-direct context so MIRLowering emits putDirect/getDirect
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
    return false if AST.scalar_literal_value?(node)
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
  sig { params(node: AST::Node).returns(AST::Node) }
  def substitute_placeholders(node)
    PipelinePlaceholderRewriter.new(current_context).substitute(node)
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
    is_soa = lhs_type&.soa_linear_collection?
    scalar_op = AST.pipeline_range_fold?(rhs)
    if is_soa && scalar_op && @lowering.lowering_target != :bc
      return lower_soa_scalar_fold(PipelineSite.new(list: lhs, options: node), rhs)
    end

    # Range source with fold terminal: fuse into a single accumulating while loop.
    if AST.pipeline_range_fold?(rhs)
      range_chain = unwrap_range_chain(lhs)
      return lower_range_fold(range_chain.source, range_chain.stages, T.cast(rhs, DefaultObservableFoldOp), node) if range_chain
    end

    # Range source with REDUCE: fuse into a single accumulating while loop.
    if rhs.is_a?(AST::ReduceOp)
      range_chain = unwrap_range_chain(lhs)
      return lower_range_reduce(range_chain.source, range_chain.stages, rhs, node) if range_chain
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

  sig { returns(T.nilable(Proc)) }
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

    expr_mir = T.let(nil, T.nilable(MIR::Emittable))
    fields = T.let([], T::Array[String])
    needs_whole_item = T.let(false, T::Boolean)

    with_soa_rewrite(each_mode: false) do
      if fold_node.respond_to?(:expression)
        expr_mir = T.cast(with_pipeline_context(placeholder: "it") { visit_mir(fold_node.expression) }, MIR::Emittable)
      end
      fields = current_context.soa_needed_fields.map(&:to_s).sort
      needs_whole_item = fold_node.is_a?(AST::FindOp) ||
        !!(fold_node.respond_to?(:expression) && ast_uses_bare_placeholder?(fold_node.expression))
    end

    build_soa_scalar_fold_block(site, fold_node, label, source_mir, T.must(expr_mir), fields, needs_whole_item)
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
      elem_zig_type = transpile_type(list_node.full_type!.element_type.resolved.to_s)
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
    pipeline_block(list_node) do |items, label|
      [
        MIR::Let.new("count_result", MIR::Lit.new("0"), true, Type.new("i64"), nil),
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
    pipeline_block(list_node) do |items, label|
      [
        MIR::Let.new("sum_result", MIR::Lit.new("0"), true, Type.new("f64"), nil),
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
    pipeline_block(list_node) do |items, label|
      [
        MIR::Let.new("avg_sum", MIR::Lit.new("0"), true, Type.new("f64"), nil),
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
    pipeline_block(list_node) do |items, label|
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
    pipeline_block(list_node) do |items, label|
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
    pipeline_block(list_node) do |items, label|
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
    pipeline_block(list_node) do |items, label|
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
    pipeline_block(list_node) do |items, label|
      [
        MIR::Let.new("find_result",
          MIR::Undef.new(nil), true, Type.new(elem_zig_type), nil),
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
    pipeline_block(list_node) do |items, label|
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
    pipeline_block(list_node) do |items, label|
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
    pipeline_block(list_node) do |items, label|
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
    pipeline_block(list_node) do |items, label|
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
    @set_index_lowerer.lower_distinct(
      T.cast(site.list, AST::Node),
      T.cast(site.options, AST::BinaryOp),
      distinct_node,
    )
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
    pipeline_block(list_node) do |items, label|
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
    pipeline_block(list_node) do |items, label|
      [
        MIR::Let.new("acc", init_mir, true, Type.new(acc_zig), nil),
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
    pipeline_block(list_node) do |items, label|
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

  sig { params(site: PipelineHost::PipelineSite, bw_node: AST::BatchWindowOp).returns(MIR::BlockExpr) }
  def lower_batch_window(site, bw_node)
    @batch_window_lowerer.lower(
      T.cast(site.list, AST::Node),
      T.cast(site.options, AST::BinaryOp),
      bw_node,
    )
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
    pipeline_block(list_node) do |items, label|
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

  sig { params(site: PipelineHost::PipelineSite, expr_node: AST::Node).returns(MIR::BlockExpr) }
  def lower_index(site, expr_node)
    @set_index_lowerer.lower_index(
      T.cast(site.list, AST::Node),
      T.cast(site.options, AST::BinaryOp),
      expr_node,
    )
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
      left_param  = params[0].name
      right_param = params[1].name
      join_params = T.let({ left_param => "__jl", right_param => "__jr" }, PipelinePlaceholderMap)
      pred_mir = with_context_state(current_context.with_join_params(join_params)) do
        visit_mir(key_expr.body)
      end
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
        MIR::Let.new("__match", MIR::Lit.new("null"), true, Type.new("?#{right_zig}"), nil),
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

  sig { params(site: PipelineHost::PipelineSite, each_op: AST::EachOp).returns(PipelineEachResult) }
  def lower_each(site, each_op)
    @each_lowerer.lower(T.cast(site.list, AST::Node), each_op)
  end

  sig { params(site: PipelineHost::PipelineSite, each_op: AST::EachOp).returns(MIR::ScopeBlock) }
  def lower_sharded_each(site, each_op)
    @concurrent_lowerer.lower_sharded_each(T.cast(site.list, AST::Node), each_op)
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

  # Detect a binding-unnest chain suitable for fused nested-loop generation:
  #   BIND_VAR(source, $u) |> [BIND_VAR(]UNNEST(expr)[, $o)] |> [WHERE/SELECT] |> fold
  #
  # Note: `UNNEST expr AS $o` parses as BIND_VAR(UnnestOp(expr), $o) because AS has
  # higher precedence than |>. Both `|> UNNEST expr` and `|> UNNEST expr AS $o` are handled.
  #
  # Returns the chain components, or nil if the pattern doesn't match.
  sig { params(node: AST::BinaryOp).returns(T.nilable(BindingUnnestChain)) }
  def unwrap_binding_unnest_chain(node)
    return nil unless node.is_a?(AST::BinaryOp) && node.smooth?

    # Terminal must be a fold op
    fold = node.right
    return nil unless AST.pipeline_range_fold?(fold)
    cursor = T.let(node.left, T.any(AST::BinaryOp, AST::Identifier))

    # Collect optional intermediate WHERE/SELECT stages (in chain order)
    stages = T.let([], T::Array[AST::Node])
    rhs = T.let(nil, T.nilable(AST::Node))
    while cursor.is_a?(AST::BinaryOp) && cursor.smooth?
      rhs = cursor.right
      if AST.pipeline_select_filter_op?(rhs)
        stages.unshift(rhs)
        cursor = cursor.left
      else
        break
      end
    end

    # cursor must now be: SMOOTH(BIND_VAR(source, $u), unnest_part)
    return nil unless cursor.is_a?(AST::BinaryOp) && cursor.smooth?
    lhs = cursor.left
    rhs = cursor.right

    # Must be a UnnestOp
    return nil unless rhs.is_a?(AST::UnnestOp)

    # Detect optional inner binding: `UNNEST expr AS $o` parses as
    # UnnestOp(expression=BIND_VAR(expr, $o)) because :pipe_expression uses
    # parse_expression(1) which consumes AS at prec 2 as part of the inner expr.
    unnest_expr = rhs.expression
    inner_binding = T.let(nil, T.nilable(String))
    if unnest_expr.is_a?(AST::BinaryOp) && unnest_expr.op == :BIND_VAR
      inner_binding = unnest_expr.right.name.to_s # "$o"
      unnest_expr   = unnest_expr.left        # the actual array expression
    end

    # LHS must be a BIND_VAR (source AS $u)
    return nil unless lhs.is_a?(AST::BinaryOp) && lhs.op == :BIND_VAR

    BindingUnnestChain.new(
      source: lhs.left,
      outer_binding: lhs.right.name.to_s,
      unnest_expr: unnest_expr,
      inner_binding: inner_binding,
      stages: stages,
      fold: fold,
    )
  end

  # Generate fused nested loops for a binding-unnest chain.
  # Outer loop: source elements bound to $u (outer_zig).
  # Inner loop: unnest expression elements (inner_zig).
  # Both bindings are visible in stage expressions and the fold.
  sig { params(chain: BindingUnnestChain, smooth_node: AST::BinaryOp).returns(T.nilable(MIR::BlockExpr)) }
  def lower_binding_chain(chain, smooth_node)
    outer_name = chain.outer_binding            # "$u"
    outer_zig  = pipe_binding_zig_name(outer_name)  # "__pipe_u"
    inner_name = chain.inner_binding            # "$o" or nil
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
      source_mir = visit_mir(chain.source)
      unnest_mir = visit_mir(chain.unnest_expr) # $u already in @named_bindings

      inner_block = lambda do
        acc_init, loop_body, post_inner, result_expr = lower_binding_fold(
          chain.fold, chain.stages, inner_zig, smooth_node, names)

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
  sig { params(fold: T.untyped, stages: T::Array[T.untyped], placeholder: String, smooth_node: T.nilable(AST::BinaryOp), names: T.nilable(T::Hash[Symbol, String])).returns(T.nilable(T::Array[T.untyped])) }
  def lower_binding_fold(fold, stages, placeholder, smooth_node = nil, names = nil)
    names ||= { acc: "__bc_acc", sum: "__bc_sum", cnt: "__bc_cnt",
                val: "__bc_val", result: "__bc_result", found: "__bc_found" }
    acc_n, sum_n, cnt_n, val_n, result_n, found_n =
      names[:acc], names[:sum], names[:cnt], names[:val], names[:result], names[:found]
    acc_n = T.must(acc_n)
    sum_n = T.must(sum_n)
    cnt_n = T.must(cnt_n)
    val_n = T.must(val_n)
    result_n = T.must(result_n)
    found_n = T.must(found_n)
    case fold
    when AST::SumOp
      expr = with_pipeline_context(placeholder: placeholder) { visit_mir(fold.expression) }
      init   = [MIR::Let.new(acc_n, MIR::Lit.new("0"), true, Type.new("f64"), nil)]
      accum  = [MIR::Set.new(MIR::Ident.new(acc_n),
                  MIR::BinOp.new("+", MIR::Ident.new(acc_n), expr))]
      [init, bc_wrap_stages(stages, placeholder, accum), [], MIR::Ident.new(acc_n)]

    when AST::CountOp
      pred  = with_pipeline_context(placeholder: placeholder) { visit_mir(fold.expression) }
      init  = [MIR::Let.new(acc_n, MIR::Lit.new("0"), true, Type.new("i64"), nil)]
      accum = [MIR::IfStmt.new(pred, [MIR::Set.new(MIR::Ident.new(acc_n),
                 MIR::BinOp.new("+", MIR::Ident.new(acc_n), MIR::Lit.new("1")))], nil)]
      [init, bc_wrap_stages(stages, placeholder, accum), [], MIR::Ident.new(acc_n)]

    when AST::AverageOp
      expr = with_pipeline_context(placeholder: placeholder) { visit_mir(fold.expression) }
      # Use f64 for count to avoid @floatFromInt in the division.
      init = [MIR::Let.new(sum_n, MIR::Lit.new("0"), true, Type.new("f64"), nil),
              MIR::Let.new(cnt_n, MIR::Lit.new("0.0"), true, Type.new("f64"), nil)]
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
                 MIR::TypeSentinel.new(:max, "f64"), true, Type.new("f64"), nil)]
      accum = [MIR::Let.new(val_n, expr, false, nil, nil),
               MIR::IfStmt.new(
                 MIR::BinOp.new("<", MIR::Ident.new(val_n), MIR::Ident.new(acc_n)),
                 [MIR::Set.new(MIR::Ident.new(acc_n), MIR::Ident.new(val_n))], nil)]
      [init, bc_wrap_stages(stages, placeholder, accum), [], MIR::Ident.new(acc_n)]

    when AST::MaxOp
      expr = with_pipeline_context(placeholder: placeholder) { visit_mir(fold.expression) }
      init  = [MIR::Let.new(acc_n,
                 MIR::TypeSentinel.new(:min, "f64"), true, Type.new("f64"), nil)]
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
      init = [MIR::Let.new(result_n, MIR::Undef.new(nil), true, Type.new(find_zig), nil),
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
    @lowering.lowering_target == :bc
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
    @concurrent_lowerer.lower(T.cast(site.options, AST::BinaryOp), conc_op)
  end

end
