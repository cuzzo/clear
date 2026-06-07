require "rspec"
require "ostruct"
require_relative "../src/ast/ast"
require_relative "../src/ast/lexer"
require_relative "../src/ast/source_error"
require_relative "../src/ast/symbol_entry"
require_relative "../src/ast/type"
require_relative "../src/mir/lower/pipeline/pipeline_host"
require_relative "../src/mir/mir"
require_relative "../src/mir/mir_emitter"
require_relative "../src/mir/mir_lowering"

PipelineMaterializerCoverageState = Struct.new(
  :current_label,
  :visited_nodes,
  :alloc_fact_names,
  :label_counter,
  :item_counter,
  keyword_init: true,
)
PipelineMaterializerCoverageHarness = Struct.new(:host, :state, keyword_init: true)

class PipelineConcurrentCoverageHost
  attr_reader :calls, :builtins
  attr_accessor :bc_target, :mutates_each

  def initialize
    @calls = []
    @builtins = []
    @bc_target = false
    @mutates_each = false
  end

  def services
    PipelineConcurrentServices.new(
      bc_target: -> { concurrent_bc_target? },
      visit_mir: ->(node) { concurrent_visit_mir(node) },
      visit_mir_with_placeholder: ->(node, _placeholder) { concurrent_visit_mir(node) },
      visit_body_with_placeholder: ->(_body_stmts, placeholder) { [MIR::Suppress.new(placeholder)] },
      lower_head_with_placeholder: ->(node, _placeholder) {
        PipelineConcurrentHeadResult.new(value: concurrent_visit_mir(node), pending: [])
      },
      callback_expr_mir: ->(expr, _placeholder, _capture_map, _capture_symbols, _rt_override) {
        concurrent_visit_mir(expr)
      },
      callback_body_mir: ->(_body_stmts, placeholder, _capture_map, _capture_symbols, _rt_override) {
        [MIR::Suppress.new(placeholder)]
      },
      pipeline_alloc_mark_fact: ->(_value, _name, _fallback_alloc, _type_info, _ast_node, _accept_owned_call, _include_cleanup) { nil },
      append_ownership_transfers: ->(body) {
        mark(:shard)
        body
      },
      pipeline_block: ->(list_node, blk) {
        body = blk.call("pipe_items", "__label")
        for_stmt = body[1]
        if_stmt = for_stmt.body[1]
        append = if_stmt.then_body[0].expr
        append_arg = append.args[1]
        mark(append_arg == MIR::Ident.new("__cv") ? :bc_select_prune : :bc_where_prune)
        MIR::BlockExpr.new("__label", body)
      },
      transpile_type: ->(type_name) { type_name == "Int64" ? "i64" : type_name },
      pipeline_alloc: ->(_smooth_node) { :heap },
      pipeline_result_alloc: -> { :heap },
      source_setup: ->(_lhs) { [MIR::Let.new("pipe_items", MIR::Ident.new("items"), false, nil, nil)] },
      emit_builtin: ->(name, args) {
        @builtins << [name, args]
        mark(concurrent_builtin_mark(name, args))
        MIR::Call.new(name.to_s, [], false, false, MIR::CallableContract.no_ownership(0))
      },
      emit_expr: ->(node) { MIREmitter.new.emit(node) },
      lower_mir: ->(node) { concurrent_visit_mir(node) },
      next_label: -> { "__label" },
      typed_block_expr: ->(label, body, result_type) {
        block = MIR::BlockExpr.new(label, body)
        block.result_type = result_type
        block
      },
      task_config_variant: ->(size_name) { size_name ? size_name.to_s.capitalize : "Standard" },
      guarded_cleanup_name: ->(_name) { false },
      do_rt_name: -> { "rt" },
      agg_min_sentinel_mir: ->(zig_type) { MIR::TypeSentinel.new(:max, zig_type) },
      agg_max_sentinel_mir: ->(zig_type, result_type) {
        result_type.unsigned_integer? ? MIR::Lit.new("0") : MIR::TypeSentinel.new(:min, zig_type)
      },
      lower_select: ->(lhs, smooth_node, inner_expr) { concurrent_lower_select(lhs, smooth_node, inner_expr) },
      lower_where: ->(lhs, smooth_node, inner_expr) { concurrent_lower_where(lhs, smooth_node, inner_expr) },
      lower_each: ->(lhs, smooth_node, inner) { concurrent_lower_each(lhs, smooth_node, inner) },
      lower_sum: ->(lhs, smooth_node, inner) { concurrent_lower_sum(lhs, smooth_node, inner) },
      lower_count: ->(lhs, smooth_node, inner) { concurrent_lower_count(lhs, smooth_node, inner) },
      lower_min: ->(lhs, smooth_node, inner) { concurrent_lower_min(lhs, smooth_node, inner) },
      lower_max: ->(lhs, smooth_node, inner) { concurrent_lower_max(lhs, smooth_node, inner) },
      lower_average: ->(lhs, smooth_node, inner) { concurrent_lower_average(lhs, smooth_node, inner) },
      with_optional_named_binding: ->(clear_name, zig_var, blk) { concurrent_with_optional_named_binding(clear_name, zig_var, blk) },
    )
  end

  def concurrent_visit_mir(node)
    case node
    when AST::Literal then MIR::Lit.new(node.value.to_s)
    when AST::Identifier then MIR::Ident.new(node.name.to_s)
    else MIR::Ident.new("expr")
    end
  end

  def concurrent_builtin_mark(name, args)
    case name
    when :concurrentBoundedSelect, :concurrentBoundedWhere, :concurrentBoundedEach
      :bounded_stream
    when :concurrentStreamSelect then :stream_select
    when :concurrentStreamWhere then :stream_where
    when :concurrentStreamEach then :stream_each
    when :concurrentListSelect then :list_select
    when :concurrentListWhere then :list_where
    when :concurrentListCount then :list_count
    when :concurrentListEach then :list_each
    when :concurrentListEachInPlace then :list_each_in_place
    when :concurrentListReduce
      suffix = args.last.name.delete_prefix(".").capitalize
      :"list_reduce_#{suffix == "Sum" ? "SumOp" : suffix == "Average" ? "AverageOp" : suffix == "Min" ? "MinOp" : "MaxOp"}"
    else name
    end
  end

  def concurrent_bc_target?
    @bc_target
  end

  def concurrent_lower_shard_each(_lhs, _conc_op, _smooth_node)
    mark(:shard)
  end

  def concurrent_lower_bounded_stream(_lhs, _conc_op)
    mark(:bounded_stream)
  end

  def concurrent_lower_select(_lhs, _smooth_node, _inner_expr)
    mark(:bc_select)
  end

  def concurrent_lower_where(_lhs, _smooth_node, _inner_expr)
    mark(:bc_where)
  end

  def concurrent_lower_each(_lhs, _smooth_node, _inner)
    mark(:bc_each)
  end

  def concurrent_lower_sum(_lhs, _smooth_node, _inner)
    mark(:bc_sum)
  end

  def concurrent_lower_count(_lhs, _smooth_node, _inner)
    mark(:bc_count)
  end

  def concurrent_lower_min(_lhs, _smooth_node, _inner)
    mark(:bc_min)
  end

  def concurrent_lower_max(_lhs, _smooth_node, _inner)
    mark(:bc_max)
  end

  def concurrent_lower_average(_lhs, _smooth_node, _inner)
    mark(:bc_average)
  end

  def concurrent_lower_bc_select_prune(_lhs, _inner_expr, _smooth_node)
    mark(:bc_select_prune)
  end

  def concurrent_lower_bc_where_prune(_lhs, _inner_expr, _smooth_node)
    mark(:bc_where_prune)
  end

  def concurrent_lower_stream_select(_lhs, _conc_op, _inner)
    mark(:stream_select)
  end

  def concurrent_lower_stream_where(_lhs, _conc_op, _inner)
    mark(:stream_where)
  end

  def concurrent_lower_stream_each(_lhs, _conc_op, _inner)
    mark(:stream_each)
  end

  def concurrent_lower_list_select(_lhs, _conc_op, _inner)
    mark(:list_select)
  end

  def concurrent_lower_list_where(_lhs, _conc_op, _inner)
    mark(:list_where)
  end

  def concurrent_lower_list_count(_lhs, _conc_op, _inner)
    mark(:list_count)
  end

  def concurrent_lower_list_reduce(_lhs, _conc_op, inner, _smooth_node)
    mark(:"list_reduce_#{inner.class.name.split('::').last}")
  end

  def concurrent_lower_list_each(_lhs, _conc_op, _inner)
    mark(:list_each)
  end

  def concurrent_lower_list_each_in_place(_lhs, _conc_op, _inner)
    mark(:list_each_in_place)
  end

  def concurrent_each_body_mutates_placeholder?(_body_stmts)
    @mutates_each
  end

  def concurrent_with_optional_named_binding(clear_name, zig_var, blk)
    @calls << [:bind, clear_name, zig_var]
    blk.call
  end

  def mark(name)
    @calls << name
    MIR::ScopeBlock.new([])
  end
end

class PipelineBatchWindowCoverageHost
  attr_reader :current_label, :pipeline_blocks, :visited, :placeholder_visits
  attr_accessor :bc_target

  def initialize
    @bc_target = false
    @label_counter = 0
    @current_label = nil
    @pipeline_blocks = []
    @visited = []
    @placeholder_visits = []
  end

  def services
    PipelineBatchWindowServices.new(
      bc_target: -> { @bc_target },
      visit_mir: ->(node) { visit_mir(node) },
      visit_mir_with_placeholder: ->(node, placeholder) {
        @placeholder_visits << [node, placeholder]
        visit_mir(node)
      },
      pipeline_block: ->(list_node, blk) {
        @label_counter += 1
        label = "__bw_pblk#{@label_counter}"
        body = blk.call("pipe_items", label)
        @pipeline_blocks << [list_node, body]
        block = MIR::BlockExpr.new(label, body)
        @current_label = label
        block
      },
      next_label: -> {
        @label_counter += 1
        "__bw_label#{@label_counter}"
      },
      set_current_label: ->(label) { @current_label = label },
      transpile_type: ->(type_info) { type_info.to_s == "Int64" ? "i64" : type_info.to_s },
      pipeline_alloc: ->(_smooth_node) { :heap },
    )
  end

  def visit_mir(node)
    @visited << node
    case node
    when AST::Literal then MIR::Lit.new(node.value.to_s)
    when AST::Identifier then MIR::Ident.new(node.name.to_s)
    else MIR::Ident.new("expr")
    end
  end
end

class PipelineSetIndexCoverageHost
  attr_reader :pipeline_blocks, :observable_calls, :insert_calls, :typed_blocks,
    :alloc_fact_names, :skip_hook, :range_chains
  attr_accessor :bc_target, :cleanup_bearing, :alloc_fact, :owned_cleanup

  def initialize
    @bc_target = false
    @cleanup_bearing = false
    @alloc_fact = false
    @owned_cleanup = nil
    @label_counter = 0
    @pipeline_blocks = []
    @observable_calls = []
    @insert_calls = []
    @typed_blocks = []
    @alloc_fact_names = []
    @range_chains = {}
    @skip_hook = nil
  end

  def services
    PipelineSetIndexServices.new(
      bc_target: -> { @bc_target },
      visit_mir: ->(node) { set_index_visit_mir(node) },
      visit_mir_with_placeholder: ->(node, _placeholder) { set_index_visit_mir(node) },
      pipeline_block: ->(list_node, blk) {
        label = next_label
        body = blk.call("pipe_items", label)
        @pipeline_blocks << [list_node, body]
        MIR::BlockExpr.new(label, body)
      },
      transpile_type: ->(type_info) { type_info.to_s == "Int64" ? "i64" : type_info.to_s },
      pipeline_alloc: ->(_smooth_node) { :heap },
      next_label: -> { next_label },
      typed_block_expr: ->(label, body, result_type) {
        block = MIR::BlockExpr.new(label, body)
        block.result_type = result_type
        @typed_blocks << block
        block
      },
      range_chain: ->(node) { @range_chains[node.object_id] },
      lazy_range_prefix: ->(source_node, _stages, on_skip) {
        @skip_hook = on_skip
        PipelineLazyRangePrefix.new(
          range_let: MIR::Let.new("__range_src", set_index_visit_mir(source_node), true, nil, nil),
          source_name: "__range_src",
          outer_stmts: [],
          stage_stmts: [],
          item_var: "__range_item",
          initial_capture: "__range_item",
          item_used: true,
          elem_zig: "i64",
          next_method: "next",
        )
      },
      range_fold_observable_distinct: ->(prefix, distinct_op, smooth_node, label, source_node) {
        @observable_calls << [prefix, distinct_op, smooth_node, label, source_node]
        MIR::BlockExpr.new(label, [MIR::BreakStmt.new(label, MIR::Ident.new("observable"))])
      },
      cleanup_bearing_type: ->(_type_info) { @cleanup_bearing },
      pipeline_alloc_mark_fact: ->(_value, name, fallback_alloc, _ast_node, _context, _include_cleanup) {
        @alloc_fact_names << name
        next nil unless @alloc_fact

        PipelineIndexAllocationFact.new(
          alloc: fallback_alloc,
          mark: MIR::AllocMark.new(name, fallback_alloc, Type.new(:Int64), :heap),
          cleanup_entry: CleanupEntry.build(:uniform, alloc: fallback_alloc, has_moved_guard: false),
        )
      },
      pipeline_owned_cleanup_entry: ->(_value, _ast_node) { @owned_cleanup },
      pipeline_index_insert_with_ownership: ->(insert, value, value_owns, target_alloc) {
        @insert_calls << [insert, value, value_owns, target_alloc]
        insert
      },
      index_temp_name: -> { "__idx_item_#{@alloc_fact_names.length + 1}" },
    )
  end

  private

  def set_index_visit_mir(node)
    case node
    when AST::Literal then MIR::Lit.new(node.value.to_s)
    when AST::Identifier then MIR::Ident.new(node.name.to_s)
    when AST::RangeLit then MIR::Ident.new("range")
    else MIR::Ident.new("expr")
    end
  end

  def next_label
    @label_counter += 1
    "__setidx#{@label_counter}"
  end
end

class PipelineEachCoverageHost
  attr_reader :calls, :range_chains
  attr_accessor :bc_target, :use_placeholder

  def initialize
    @bc_target = false
    @use_placeholder = true
    @calls = []
    @range_chains = {}
    @index_counter = 0
  end

  def services
    PipelineEachServices.new(
      bc_target: -> { @bc_target },
      visit_mir: ->(node) { each_visit_mir(node) },
      visit_body_with_placeholder: ->(_body_stmts, placeholder) {
        @calls << [:body, placeholder]
        [MIR::Suppress.new(placeholder)]
      },
      soa_body: ->(_body_stmts) {
        @calls << :soa
        PipelineEachSoaBody.new(body: [MIR::Suppress.new("_")], fields: ["age"])
      },
      range_chain: ->(node) { @range_chains[node.object_id] },
      lower_each_range: ->(source_node, stages, _each_op) {
        @calls << [:range, source_node, stages.length]
        MIR::ScopeBlock.new([MIR::Suppress.new("__range")])
      },
      lower_sharded_each: ->(list_node, _each_op) {
        @calls << [:sharded, list_node]
        MIR::ScopeBlock.new([MIR::Suppress.new("__sharded")])
      },
      ast_stmts_use_placeholder: ->(_body_stmts) { @use_placeholder },
      next_index_name: -> {
        @index_counter += 1
        "__each_i_#{@index_counter}"
      },
    )
  end

  private

  def each_visit_mir(node)
    case node
    when AST::Literal then MIR::Lit.new(node.value.to_s)
    when AST::Identifier then MIR::Ident.new(node.name.to_s)
    else MIR::Ident.new("expr")
    end
  end
end

RSpec.describe "pipeline backend coverage" do
  let(:tok) { Lexer::Token.new(:VAR_ID, "x", 1, 1) }

  def id(name, type: Type.new(:Int64))
    typed(AST::Identifier.new(tok, name), type)
  end

  def lit(value, type = :Int64)
    typed(AST::Literal.new(tok, :NUMBER, value, nil), type)
  end

  def typed(node, type = Type.new(:Int64))
    AST.stamp_synthetic_type!(node, type, context: "pipeline coverage fixture")
    node
  end

  def empty_schema_lookup
    ->(_name) { nil }
  end

  def stamp_pipeline_fixture_metadata(node, coerced_type: nil, storage: nil,
                                      var_used: nil, slot_size: nil)
    node.instance_variable_set(:@coerced_type_object, Type.new(coerced_type)) if coerced_type
    node.instance_variable_set(:@storage_override, storage) if storage
    node.instance_variable_set(:@var_used, var_used) unless var_used.nil?
    node.instance_variable_set(:@slot_size, slot_size) if slot_size
    node
  end

  def stamp_pipeline_fixture_call_metadata(call, signature)
    call.instance_variable_set(:@zig_pattern, "try checked({0})")
    call.instance_variable_set(:@matched_stdlib_def, signature)
    call.instance_variable_set(:@matched_signature, signature)
    call.instance_variable_set(:@stdlib_allocates, true)
    call.instance_variable_set(:@mutates_receiver, true)
    call.instance_variable_set(:@can_fail, true)
    call.instance_variable_set(:@error_kind, :IO)
    call.instance_variable_set(:@error_type, :FileError)
    call
  end

  def materializer_coverage_harness(bc_target: false, result_alloc: :frame,
                                    source_mir: nil, alloc_fact: false)
    state = PipelineMaterializerCoverageState.new(
      current_label: nil,
      visited_nodes: [],
      alloc_fact_names: [],
      label_counter: 0,
      item_counter: 0,
    )
    host = PipelineMaterializer::RuntimeHost.new(
      visit_mir: ->(node) {
        state.visited_nodes << node
        source_mir || MIR::Ident.new(node.is_a?(AST::Identifier) ? node.name.to_s : "source")
      },
      alloc_mark_fact: ->(_value, name, fallback_alloc, type_info, ast_node, context, known_allocating) {
        next nil unless alloc_fact || known_allocating

        state.alloc_fact_names << [name, context, ast_node]
        PipelineMaterializer::AllocationFact.new(
          alloc: fallback_alloc,
          mark: MIR::AllocMark.new(name, fallback_alloc, type_info || Type.new(:Int64), :heap),
        )
      },
      result_alloc: -> { result_alloc },
      bc_target: -> { bc_target },
      schema_lookup: -> { empty_schema_lookup },
      next_label: -> {
        state.label_counter += 1
        "__mat#{state.label_counter}"
      },
      set_current_label: ->(label) {
        state.current_label = label
      },
      next_item_temp_name: -> {
        state.item_counter += 1
        "__pipe_item_#{state.item_counter}"
      },
    )
    PipelineMaterializerCoverageHarness.new(host: host, state: state)
  end

  def add_range_chain(host, node, source: node, stages: [])
    host.range_chains[node.object_id] = PipelineRangeChain.new(source: source, stages: stages)
  end

  def collect_mir_nodes(root, klass)
    found = []
    walk = lambda do |node|
      return unless node
      found << node if node.is_a?(klass)
      if node.respond_to?(:body) && node.body.is_a?(Array)
        node.body.each { |child| walk.call(child) }
      end
      if node.respond_to?(:then_body) && node.then_body.is_a?(Array)
        node.then_body.each { |child| walk.call(child) }
      end
      if node.respond_to?(:else_body) && node.else_body.is_a?(Array)
        node.else_body.each { |child| walk.call(child) }
      end
      if node.respond_to?(:init)
        walk.call(node.init)
      end
      if node.respond_to?(:expr)
        walk.call(node.expr)
      end
      if node.respond_to?(:value)
        walk.call(node.value)
      end
      [:condition, :cond, :left, :right, :target, :index, :iter].each do |field|
        next unless node.respond_to?(field)
        reader = node.method(field)
        walk.call(reader.call) if reader.arity.zero?
      end
      if node.respond_to?(:args) && node.args.is_a?(Array)
        node.args.each { |child| walk.call(child) }
      end
    end
    walk.call(root)
    found
  end

  def lazy_range_prefix(**overrides)
    PipelineHost::LazyRangePrefix.new({
      range_let: nil,
      source_name: "source",
      outer_stmts: [],
      stage_stmts: [],
      item_var: "__item",
      initial_capture: "__each_item",
      item_used: true,
      elem_zig: "i64",
      next_method: "next",
    }.merge(overrides))
  end

  def stub_pipeline_host_mir_visitors(pipeline_host)
    pipeline_host.define_singleton_method(:visit_mir) do |node|
      case node
      when AST::Literal
        MIR::Lit.new(node.value.to_s)
      when AST::Identifier
        MIR::Ident.new(node.name.to_s)
      else
        MIR::Ident.new("expr")
      end
    end
    pipeline_host.define_singleton_method(:visit_pipeline_body_mir) do |_body, placeholder:|
      [MIR::Suppress.new(placeholder)]
    end
  end

  describe PipelineMaterializer do
    def materializer(host_overrides = {})
      described_class.new(host: materializer_coverage_harness(**host_overrides).host)
    end

    def collection_type(raw, collection:, shard_count: nil, soa: false)
      type = Type.new(raw, collection: collection, shard_count: shard_count)
      type.mark_soa_layout! if soa
      type
    end

    it "builds structural item setup for every collection layout branch" do
      sharded_pool = materializer.items_setup(collection_type(:"Int64[8]", collection: :pool, shard_count: 4))
      expect(sharded_pool.statements[2]).to be_a(MIR::ForStmt)
      expect(sharded_pool.statements[2].body.first).to be_a(MIR::ForStmt)

      soa_pool = materializer.items_setup(collection_type(:"Int64[8]", collection: :pool, soa: true))
      expect(soa_pool.statements[2]).to be_a(MIR::ForStmt)
      expect(soa_pool.statements[2].body.first).to be_a(MIR::IfStmt)

      pool = materializer.items_setup(collection_type(:"Int64[8]", collection: :pool))
      expect(pool.statements[2].iter.field).to eq("slots")

      set = materializer.items_setup(collection_type(:"Int64[]", collection: :set))
      expect(set.statements[2].name).to eq("__skit")
      expect(set.statements[3]).to be_a(MIR::WhileStmt)

      soa_list = materializer.items_setup(collection_type(:"Int64[]", collection: :list, soa: true))
      expect(soa_list.statements[2]).to be_a(MIR::ForStmt)
      expect(soa_list.statements[2].body.first).to be_a(MIR::ExprStmt)

      sharded_list = materializer.items_setup(collection_type(:"Int64[]", collection: :list, shard_count: 3))
      expect(sharded_list.statements[2].body.first.expr.method).to eq("appendSlice")

      plain = materializer.items_setup(Type.new(:"Int64[]"))
      expect(plain.statements).to contain_exactly(be_a(MIR::Let))
      expect(plain.statements.first.init).to be_a(MIR::ItemsAccess)
    end

    it "uses structural ItemsAccess for BC-only SOA collection layouts" do
      mat = materializer(bc_target: true)

      soa_pool = mat.items_setup(collection_type(:"Int64[8]", collection: :pool, soa: true))
      expect(soa_pool.statements.first.init).to be_a(MIR::ItemsAccess)

      soa_list = mat.items_setup(collection_type(:"Int64[]", collection: :list, soa: true))
      expect(soa_list.statements.first.init).to be_a(MIR::ItemsAccess)
    end

    it "builds pipeline blocks with source cleanup, item setup, and result body" do
      inline = MIR::InlineZig.new("make()", "test", MIR::OwnershipContract.empty, nil,
        MIR.inline_alloc_metadata(alloc: :heap), "pipe_src_list")
      harness = materializer_coverage_harness(source_mir: inline)
      mat = described_class.new(host: harness.host)
      list = id("items", type: Type.new(:"Int64[]", collection: :list))

      block = mat.pipeline_block(list) do |items, label|
        [MIR::BreakStmt.new(label, MIR::Ident.new(items))]
      end

      expect(harness.state.current_label).to eq("__mat1")
      expect(harness.state.alloc_fact_names.first.first).to eq("pipe_src_list")
      expect(block.body[0]).to be_a(MIR::AllocMark)
      expect(block.body[2]).to be_a(MIR::Cleanup)
      expect(block.body.last.value.name).to eq("pipe_items")
    end

    it "builds concurrent source setup for range and collection sources" do
      mat = materializer(alloc_fact: true)
      range = typed(AST::RangeLit.new(tok, lit(0), lit(5), false), Type.new(:"~Int64[]"))
      range_setup = mat.concurrent_source_setup(range)
      expect(range_setup.map(&:class)).to eq([MIR::Let, MIR::Let, MIR::DeferStmt, MIR::Let])
      expect(range_setup[1].init.method).to eq("toList")

      list = id("items", type: Type.new(:"Int64[]", collection: :list))
      list_setup = mat.concurrent_source_setup(list)
      expect(list_setup.first).to be_a(MIR::AllocMark)
      expect(list_setup).to include(be_a(MIR::Cleanup))
      expect(list_setup.last.init).to be_a(MIR::ItemsAccess)
    end

    it "copies borrowed cleanup-bearing values and leaves scalar values borrowed" do
      mat = materializer
      string_copy = mat.borrowed_pipeline_value(MIR::Ident.new("s"), Type.new(:String), :heap)
      int_value = MIR::Ident.new("n")

      expect(string_copy).to be_a(MIR::DeepCopy)
      expect(mat.borrowed_pipeline_value(int_value, Type.new(:Int64), :frame)).to equal(int_value)
      expect(mat.cleanup_bearing_type?(Type.new(:String))).to be true
      expect(mat.cleanup_bearing_type?(Type.new(:Int64))).to be false
    end

    it "emits direct appends or owned temp transfers based on allocation facts" do
      direct = materializer.append_owned_value_stmt("items", :frame, MIR::Ident.new("value"))
      expect(direct).to be_a(MIR::ExprStmt)
      expect(direct.expr.method).to eq("append")

      owning = materializer(alloc_fact: true)
      deep_copy = MIR::DeepCopy.new(MIR::Ident.new("value"), "Payload", nil, :full_value, :heap)
      scoped = owning.append_owned_value_stmt("items", :heap, deep_copy)
      expect(scoped).to be_a(MIR::ScopeBlock)
      expect(scoped.body[0]).to be_a(MIR::AllocMark)
      expect(scoped.body[2]).to be_a(MIR::ErrCleanup)
      expect(scoped.body[2].cleanup_entry[:zig_type]).to eq("Payload")
      expect(scoped.body.last).to be_a(MIR::MoveMark)
    end

    it "normalizes zig type metadata for append cleanup entries" do
      mat = materializer
      cleanup_entry = CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: true, zig_type: "Payload")

      nodes = [
        MIR::DeepCopy.new(MIR::Ident.new("x"), "Payload", nil, :full_value, :heap),
        MIR::ContainerInit.new("std.ArrayListUnmanaged(i64)", :list_empty, :heap, nil),
        MIR::StructInit.new("Box", []),
        MIR::TypeSentinel.new(:max, "i64"),
        MIR::Undef.new("i64"),
        MIR::HeapCreate.new("Box", MIR::Ident.new("x"), :heap, "__box"),
        MIR::DiscardOwned.new(MIR::Ident.new("x"), cleanup_entry, "Payload"),
        MIR::UnionVariantGet.new(MIR::Ident.new("u"), :Some, "i64"),
      ]

      expect(nodes.map { |node| mat.send(:zig_type_for, node) }).to eq([
        "Payload",
        "std.ArrayListUnmanaged(i64)",
        "Box",
        "i64",
        "i64",
        "Box",
        "Payload",
        "i64",
      ])
      expect(mat.send(:zig_type_for, MIR::StructInit.new(nil, []))).to eq("void")
      expect(mat.send(:zig_type_for, MIR::Ident.new("x"))).to eq("void")
    end
  end

  describe PipelineConcurrentLowerer do
    let(:concurrent_host) { PipelineConcurrentCoverageHost.new }
    let(:concurrent_lowerer) { described_class.new(services: concurrent_host.services) }

    def concurrent_smooth(lhs, op)
      result_type = if op.is_a?(AST::ConcurrentOp) && op.op.is_a?(AST::SelectOp)
        Type.new(:"Int64[]")
      else
        Type.new(:Any)
      end
      typed(AST::BinaryOp.new(tok, lhs, :SMOOTH, op), result_type)
    end

    def concurrent_call(lhs, op)
      conc = AST::ConcurrentOp.new(tok, op, {})
      typed(conc, Type.new(:Any))
      concurrent_lowerer.lower(concurrent_smooth(lhs, conc), conc)
      concurrent_host.calls.last
    end

    it "routes every concurrent source and terminal shape through the typed host boundary" do
      list = id("items", type: Type.new(:"Int64[]", collection: :list))
      range = typed(AST::RangeLit.new(tok, lit(0), lit(4), false), Type.new(:"~Int64[]"))
      bounded = id("bounded", type: Type.new(:"~Int64[4]"))
      stream = id("events", type: Type.new(:"~Int64[INF]"))

      shard = AST::ConcurrentOp.new(tok, AST::EachOp.new(tok, []), {})
      typed(shard, Type.new(:Void))
      shard.shard_context = AST::PipelineShardContext.new(
        auto_detected: true,
        key_expr: id("_"),
        map_var: id("counts"),
      )
      concurrent_lowerer.lower(concurrent_smooth(range, shard), shard)
      expect(concurrent_host.calls.last).to eq(:shard)

      concurrent_host.bc_target = true
      expect(concurrent_call(list, AST::SelectOp.new(tok, id("_")))).to eq(:bc_select)
      expect(concurrent_call(list, AST::WhereOp.new(tok, id("_")))).to eq(:bc_where)
      expect(concurrent_call(list, AST::EachOp.new(tok, []))).to eq(:bc_each)
      expect(concurrent_call(list, AST::SumOp.new(tok, id("_")))).to eq(:bc_sum)
      expect(concurrent_call(list, AST::CountOp.new(tok, id("_")))).to eq(:bc_count)
      expect(concurrent_call(list, AST::MinOp.new(tok, id("_")))).to eq(:bc_min)
      expect(concurrent_call(list, AST::MaxOp.new(tok, id("_")))).to eq(:bc_max)
      expect(concurrent_call(list, AST::AverageOp.new(tok, id("_")))).to eq(:bc_average)
      prune_expr = AST::BinaryOp.new(tok, id("_"), :OR_RESCUE, AST::OrPrune.new(tok))
      expect(concurrent_call(list, AST::SelectOp.new(tok, prune_expr))).to eq(:bc_select_prune)
      expect(concurrent_call(list, AST::WhereOp.new(tok, prune_expr))).to eq(:bc_where_prune)
      concurrent_host.bc_target = false

      expect(concurrent_call(bounded, AST::EachOp.new(tok, []))).to eq(:bounded_stream)
      expect(concurrent_call(stream, AST::SelectOp.new(tok, id("_")))).to eq(:stream_select)
      expect(concurrent_call(stream, AST::WhereOp.new(tok, id("_")))).to eq(:stream_where)
      expect(concurrent_call(stream, AST::EachOp.new(tok, []))).to eq(:stream_each)

      expect(concurrent_call(list, AST::SelectOp.new(tok, id("_")))).to eq(:list_select)
      expect(concurrent_call(list, AST::WhereOp.new(tok, id("_")))).to eq(:list_where)
      expect(concurrent_call(list, AST::CountOp.new(tok, id("_")))).to eq(:list_count)
      expect(concurrent_call(list, AST::SumOp.new(tok, id("_")))).to eq(:list_reduce_SumOp)
      expect(concurrent_call(list, AST::AverageOp.new(tok, id("_")))).to eq(:list_reduce_AverageOp)
      expect(concurrent_call(list, AST::MinOp.new(tok, id("_")))).to eq(:list_reduce_MinOp)
      expect(concurrent_call(list, AST::MaxOp.new(tok, id("_")))).to eq(:list_reduce_MaxOp)
      expect(concurrent_call(range, AST::SelectOp.new(tok, id("_")))).to eq(:list_select)

      expect(concurrent_call(list, AST::EachOp.new(tok, []))).to eq(:list_each)
      list_each_builtin = concurrent_host.builtins.reverse.find { |name, _args| name == :concurrentListEach }
      expect(list_each_builtin[1][-2]).to be_a(MIR::StructInit)
      target = AST::GetField.new(tok, id("_"), "value")
      expect(concurrent_call(list, AST::EachOp.new(tok, [AST::Assignment.new(tok, target, lit(1))]))).to eq(:list_each_in_place)

      bind = AST::BinaryOp.new(tok, list, :BIND_VAR, id("$u"))
      concurrent_call(bind, AST::WhereOp.new(tok, id("_")))
      expect(concurrent_host.calls[-2]).to eq([:bind, "$u", "__item"])
      expect(concurrent_host.calls[-1]).to eq(:list_where)
    end

    it "builds typed concurrent plans for source, terminal, and semantic facts" do
      list = id("items", type: Type.new(:"Int64[]", collection: :list))
      range = typed(AST::RangeLit.new(tok, lit(0), lit(4), false), Type.new(:"~Int64[]"))
      bounded = id("bounded", type: Type.new(:"~Int64[4]"))
      stream = id("events", type: Type.new(:"~Int64[INF]"))

      shard = AST::ConcurrentOp.new(tok, AST::EachOp.new(tok, []), {})
      typed(shard, Type.new(:Void))
      shard.shard_context = AST::PipelineShardContext.new(
        auto_detected: true,
        key_expr: id("_"),
        map_var: id("counts"),
      )
      shard_plan = concurrent_lowerer.send(:concurrent_plan, concurrent_smooth(range, shard), shard)
      expect(shard_plan.source_kind).to eq(PipelineConcurrentSourceKind::ShardEach)
      expect(shard_plan.terminal_kind).to eq(PipelineConcurrentTerminalKind::Each)
      expect(shard_plan.shard_context).to be_a(AST::PipelineShardContext)

      concurrent_host.bc_target = true
      prune_expr = AST::BinaryOp.new(tok, id("_"), :OR_RESCUE, AST::OrPrune.new(tok))
      bc = AST::ConcurrentOp.new(tok, AST::SelectOp.new(tok, prune_expr), {})
      typed(bc, Type.new(:"Int64[]"))
      bind = AST::BinaryOp.new(tok, list, :BIND_VAR, id("$u"))
      bc_plan = concurrent_lowerer.send(:concurrent_plan, concurrent_smooth(bind, bc), bc)
      expect(bc_plan.source_kind).to eq(PipelineConcurrentSourceKind::BcMaterialized)
      expect(bc_plan.terminal_kind).to eq(PipelineConcurrentTerminalKind::Select)
      expect(bc_plan.binding_name).to eq("$u")
      expect(bc_plan.bc_expression.policy).to eq(:prune)
      concurrent_host.bc_target = false

      bounded_conc = AST::ConcurrentOp.new(tok, AST::WhereOp.new(tok, id("_")), {})
      bounded_plan = concurrent_lowerer.send(:concurrent_plan, concurrent_smooth(bounded, bounded_conc), bounded_conc)
      expect(bounded_plan.source_kind).to eq(PipelineConcurrentSourceKind::BoundedStream)
      expect(bounded_plan.terminal_kind).to eq(PipelineConcurrentTerminalKind::Where)

      stream_conc = AST::ConcurrentOp.new(tok, AST::EachOp.new(tok, []), {})
      stream_plan = concurrent_lowerer.send(:concurrent_plan, concurrent_smooth(stream, stream_conc), stream_conc)
      expect(stream_plan.source_kind).to eq(PipelineConcurrentSourceKind::RuntimeStream)

      mutating_each = AST::EachOp.new(tok, [AST::Assignment.new(tok, id("_"), lit(1))])
      list_conc = AST::ConcurrentOp.new(tok, mutating_each, {})
      list_plan = concurrent_lowerer.send(:concurrent_plan, concurrent_smooth(list, list_conc), list_conc)
      expect(list_plan.source_kind).to eq(PipelineConcurrentSourceKind::RuntimeList)
      expect(list_plan.list_each_mutates_placeholder).to be true
    end

    it "raises explicit errors for unsupported concurrent shapes" do
      scalar = id("n", type: Type.new(:Int64))
      list = id("items", type: Type.new(:"Int64[]"))
      stream = id("events", type: Type.new(:"~Int64[INF]"))
      reduce = AST::ReduceOp.new(tok, lit(0), id("_"))

      expect {
        concurrent_call(scalar, AST::SelectOp.new(tok, id("_")))
      }.to raise_error(/unsupported non-legacy CONCURRENT shape/)
      expect {
        concurrent_call(stream, reduce)
      }.to raise_error(/unsupported non-legacy CONCURRENT shape/)
      expect {
        concurrent_call(list, reduce)
      }.to raise_error(/unsupported list CONCURRENT op/)
    end

    it "covers concurrent callback, shard, stream, and bytecode edge branches" do
      list = id("items", type: Type.new(:"Int64[]", collection: :list, shard_count: 3))
      call_source = typed(AST::FuncCall.new(tok, "items", []), Type.new(:"Int64[]", collection: :list, shard_count: 3))
      each = typed(AST::EachOp.new(tok, [AST::FuncCall.new(tok, "touch", [id("_")])]), Type.new(:Void))

      sharded = concurrent_lowerer.lower_sharded_each(call_source, each)
      expect(sharded.body).to include(an_object_having_attributes(name: "__sh_each_val"))

      concurrent_host.bc_target = true
      bind = AST::BinaryOp.new(tok, list, :BIND_VAR, id("$u"))
      expect(concurrent_call(bind, AST::CountOp.new(tok, id("_")))).to eq(:bc_count)

      bounded = id("bounded", type: Type.new(:"~Int64[4]"))
      expect {
        concurrent_call(bounded, AST::SumOp.new(tok, id("_")))
      }.to raise_error(/bounded streams only supports/)

      expect {
        concurrent_call(list, AST::ReduceOp.new(tok, lit(0), id("_")))
      }.to raise_error(/unsupported inner op/)

      raise_expr = AST::BinaryOp.new(tok, id("_"), :OR_RESCUE, AST::OrRaise.new(tok))
      expect(concurrent_lowerer.send(:bc_error_policy, raise_expr).policy).to eq(:raise)
      concurrent_host.bc_target = false

      open_stream = id("open_stream", type: Type.new(:"~?Int64[]"))
      expect(concurrent_call(open_stream, AST::WhereOp.new(tok, id("_")))).to eq(:stream_where)

      sym = SymbolEntry.new(reg: "c", type: Type.new(:Int64), mutable: false, storage: :frame)
      analysis = OpenStruct.new(
        has_local: false,
        has_rc: false,
        has_shared: false,
        has_sharded: false,
        has_affine_locked: false,
        has_outer_ref: false,
        has_non_escaping_capture: false,
        captures: { "c" => Type.new(:Int64) },
        capture_symbols: { "c" => sym },
        close_patterns: {},
        pointer_captures: Set.new,
        string_captures: Set.new,
        resource_captures: Set.new,
        site_moved: Set.new,
        site_copied: Set.new,
        strategies: {},
        move_mark_names: Set.new,
        alloc_mark_entries: {}
      )
      select = typed(AST::SelectOp.new(tok, id("_")), Type.new(:Int64))
      conc = typed(AST::ConcurrentOp.new(tok, select, {}), Type.new(:Int64))
      conc.capture_analysis = analysis
      concurrent_host.bc_target = true
      expr_callback = concurrent_lowerer.send(:build_bounded_concurrent_callback,
        conc, Type.new(:Int64), Type.new(:Int64), :expr)
      expect(expr_callback.ctx_def.methods.first.body).to include(an_object_having_attributes(name: "c"))

      each_conc = typed(AST::ConcurrentOp.new(tok, each, {}), Type.new(:Void))
      each_conc.capture_analysis = analysis
      each_callback = concurrent_lowerer.send(:build_bounded_concurrent_callback,
        each_conc, Type.new(:Int64), Type.new(:Void), :each)
      expect(each_callback.ctx_def.methods.first.body.last).to be_a(MIR::ReturnStmt)

      expect {
        concurrent_lowerer.send(:callback_body, each_conc, :bad, Type.new(:Void), {}, {})
      }.to raise_error(/unknown bounded concurrent callback kind/)
      expect {
        concurrent_lowerer.send(:callback_expression, each_conc)
      }.to raise_error(/expected expression op/)
      expect {
        concurrent_lowerer.send(:list_reduce_initial, :median, "i64", Type.new(:Int64))
      }.to raise_error(/unsupported reduce kind/)

      nested_assignment = AST::FuncCall.new(tok, "touch", [
        AST::Assignment.new(tok, id("_"), lit(1)),
      ])
      expect(concurrent_lowerer.send(:each_body_mutates_placeholder?, [nested_assignment])).to be true
      expect(concurrent_lowerer.send(:assignment_targets_placeholder?, Object.new)).to be false
    end
  end

  describe PipelineBatchWindowLowerer do
    let(:batch_host) { PipelineBatchWindowCoverageHost.new }
    let(:batch_lowerer) { described_class.new(services: batch_host.services) }

    def string_lit(value)
      typed(AST::Literal.new(tok, :STRING, value, nil), Type.new(:String))
    end

    def batch_window(size: lit(2), time: nil, expr: id("_", type: Type.new(:Int64)))
      options = {}
      options["size"] = size if size
      options["time"] = time if time
      AST::BatchWindowOp.new(tok, options, expr)
    end

    def batch_smooth(lhs, op)
      typed(AST::BinaryOp.new(tok, lhs, :SMOOTH, op), Type.new(:"Int64[]"))
    end

    def lower_batch(lhs, op = batch_window)
      batch_lowerer.lower(lhs, batch_smooth(lhs, op), op)
    end

    def batch_runtime_method(block)
      collect_mir_nodes(block, MIR::WhileStmt).first.cond.method
    end

    def batch_init_timeout(block)
      init_call = collect_mir_nodes(block, MIR::Call).find { |call| call.callee.include?("BatchWindow") }
      init_call&.args&.[](2)&.value
    end

    it "parses batch-window timeout units without regex fallback" do
      expect(batch_lowerer.send(:batch_window_timeout_ns, batch_window(time: nil))).to eq("0")
      expect(batch_lowerer.send(:batch_window_timeout_ns, batch_window(time: string_lit("7ms")))).to eq("7000000")
      expect(batch_lowerer.send(:batch_window_timeout_ns, batch_window(time: string_lit("2.5s")))).to eq("2500000000")
      expect(batch_lowerer.send(:batch_window_timeout_ns, batch_window(time: string_lit("1min")))).to eq("60000000000")
      expect(batch_lowerer.send(:batch_window_timeout_ns, batch_window(time: string_lit("1h")))).to eq("3600000000000")
      expect(batch_lowerer.send(:batch_window_timeout_ns, batch_window(time: string_lit("10m")))).to eq("0")
      expect(batch_lowerer.send(:batch_window_timeout_ns, batch_window(time: string_lit("1..2s")))).to eq("0")
      expect(batch_lowerer.send(:batch_window_timeout_ns, batch_window(time: string_lit(".s")))).to eq("0")
      expect(batch_lowerer.send(:batch_window_timeout_ns, batch_window(time: string_lit("1xs")))).to eq("0")
    end

    it "lowers Zig materialized, dynamic, open, bounded, and infinite stream windows" do
      list = id("items", type: Type.new(:"Int64[]"))
      dynamic = id("dynamic", type: Type.new(:"~Int64[]"))
      open_stream = id("open_stream", type: Type.new(:"~?Int64[]"))
      bounded = id("bounded", type: Type.new(:"~Int64[4]"))
      infinite = id("infinite", type: Type.new(:"~Int64[INF]"))

      list_block = lower_batch(list)
      expect(batch_host.pipeline_blocks.length).to eq(1)
      expect(collect_mir_nodes(list_block, MIR::BatchWindowPush).length).to eq(1)
      expect(collect_mir_nodes(list_block, MIR::BatchWindowFlush).length).to eq(1)

      dynamic_block = lower_batch(dynamic, batch_window(time: string_lit("2.5s")))
      expect(batch_runtime_method(dynamic_block)).to eq("next")
      expect(batch_init_timeout(dynamic_block)).to eq("2500000000")

      open_block = lower_batch(open_stream)
      expect(batch_runtime_method(open_block)).to eq("next")

      bounded_block = lower_batch(bounded)
      bounded_for = collect_mir_nodes(bounded_block, MIR::ForStmt).first
      expect(bounded_for.iter).to eq(MIR::FieldGet.new(MIR::Ident.new("__bw_bsrc"), "items"))

      infinite_block = lower_batch(infinite)
      expect(batch_runtime_method(infinite_block)).to eq("nextOrNull")
      expect(batch_host.placeholder_visits.map(&:last)).to all(eq("__bw_batch"))
    end

    it "lowers BC materialized and infinite-stream windows with their distinct append shapes" do
      batch_host.bc_target = true
      list = id("items", type: Type.new(:"Int64[]"))
      infinite = id("infinite", type: Type.new(:"~Int64[INF]"))

      materialized = lower_batch(list, batch_window(size: nil, time: string_lit("garbage")))
      expect(batch_host.pipeline_blocks.length).to eq(1)
      expect(collect_mir_nodes(materialized, MIR::BatchWindowPush)).to be_empty
      expect(batch_init_timeout(materialized)).to be_nil
      materialized_append = collect_mir_nodes(materialized, MIR::MethodCall).find { |call| call.method == "append" }
      expect(materialized_append.args.length).to eq(2)

      drained = lower_batch(infinite)
      expect(drained.body.first.name).to eq("__bw_drained")
      drain_append = drained.body[1].body.first.expr
      expect(drain_append.args.length).to eq(1)
      result_append = collect_mir_nodes(drained, MIR::MethodCall).select { |call| call.method == "append" }.last
      expect(result_append.args.length).to eq(1)
    end
  end

  describe PipelineSetIndexLowerer do
    let(:set_index_host) { PipelineSetIndexCoverageHost.new }
    let(:set_index_lowerer) { described_class.new(services: set_index_host.services) }

    def set_index_smooth(lhs, op, type: Type.new(:Any))
      typed(AST::BinaryOp.new(tok, lhs, :SMOOTH, op), type)
    end

    it "lowers DISTINCT for materialized, range, observable, and BC stream sources" do
      list = id("items", type: Type.new(:"Int64[]"))
      stream = id("events", type: Type.new(:"~Int64[4]"))
      distinct = AST::DistinctOp.new(tok, id("_"))
      materialized_smooth = set_index_smooth(list, distinct, type: Type.new(:"Int64[]", collection: :set))

      materialized = set_index_lowerer.lower_distinct(list, materialized_smooth, distinct)
      expect(set_index_host.pipeline_blocks.length).to eq(1)
      materialized_insert = collect_mir_nodes(materialized, MIR::MethodCall).find { |call| call.method == "insert" }
      expect(materialized_insert.args.length).to eq(2)

      add_range_chain(set_index_host, stream)
      ranged_smooth = set_index_smooth(stream, distinct, type: Type.new(:"Int64[]", collection: :set))
      ranged = set_index_lowerer.lower_distinct(stream, ranged_smooth, distinct)
      expect(ranged.body).to include(a_kind_of(MIR::Let), a_kind_of(MIR::DeferStmt), a_kind_of(MIR::WhileStmt))

      observable_smooth = set_index_smooth(stream, distinct, type: Type.new(:"Int64[]", collection: :set))
      observable_smooth.observable_dest = true
      observable = set_index_lowerer.lower_distinct(stream, observable_smooth, distinct)
      expect(observable.body.last.value.name).to eq("observable")
      expect(set_index_host.observable_calls.length).to eq(1)

      set_index_host.bc_target = true
      bc_stream = set_index_lowerer.lower_distinct(stream, ranged_smooth, distinct)
      bc_insert = collect_mir_nodes(bc_stream, MIR::MethodCall).find { |call| call.method == "insert" }
      expect(bc_insert.args.length).to eq(1)
      expect(collect_mir_nodes(bc_stream, MIR::ForStmt).first.iter).to eq(MIR::Ident.new("events"))
    end

    it "lowers INDEX for materialized and stream sources with ownership facts and cleanup hooks" do
      list = id("items", type: Type.new(:"Int64[]"))
      index = AST::IndexOp.new(tok, id("_"))
      set_index_host.alloc_fact = true
      set_index_host.owned_cleanup = CleanupEntry.build(:uniform, alloc: :heap)

      materialized = set_index_lowerer.lower_index(list, set_index_smooth(list, index), index.expression)
      expect(set_index_host.pipeline_blocks.length).to eq(1)
      expect(set_index_host.alloc_fact_names).to include("__idx_item_1")
      expect(set_index_host.insert_calls.last[2]).to be false
      expect(collect_mir_nodes(materialized, MIR::Cleanup)).not_to be_empty

      stream = id("events", type: Type.new(:"~Int64[4]"))
      add_range_chain(set_index_host, stream)
      stream_index = set_index_lowerer.lower_index(stream, set_index_smooth(stream, index), index.expression)
      expect(stream_index.body).to include(a_kind_of(MIR::DeferStmt), a_kind_of(MIR::WhileStmt))
      expect(set_index_host.skip_hook.call("__range_item")).to contain_exactly(a_kind_of(MIR::ExprStmt))

      set_index_host.bc_target = true
      range = typed(AST::RangeLit.new(tok, lit(0), lit(3), true), Type.new(:"~Int64[]"))
      add_range_chain(set_index_host, range)
      bc_range_index = set_index_lowerer.lower_index(range, set_index_smooth(range, index), index.expression)
      expect(collect_mir_nodes(bc_range_index, MIR::ForStmt).first.iter).to be_a(MIR::IterRange)

      bc_stream_index = set_index_lowerer.lower_index(stream, set_index_smooth(stream, index), index.expression)
      expect(collect_mir_nodes(bc_stream_index, MIR::ForStmt).first.iter).to eq(MIR::Ident.new("events"))
    end

    it "preserves already-owned index items without introducing a copy" do
      set_index_host.cleanup_bearing = true

      prepared = set_index_lowerer.send(:index_prepared_value,
        "__item",
        "[]const u8",
        :heap,
        Type.new(:String),
        PipelineIndexValueOwnership::Owned)

      expect(prepared.value).to eq(MIR::Ident.new("__item"))
      expect(prepared.setup_stmts).to contain_exactly(a_kind_of(MIR::AllocMark))
      expect(prepared.owns_heap).to be true
    end
  end

  describe PipelinePlanBuilder do
    def plan_builder(target:, range_chains:, binding_chains:)
      PipelinePlanBuilder.new(
        services: PipelinePlanServices.new(
          lowering_target: -> { target },
          range_chain: ->(node) { range_chains[node.object_id] },
          binding_chain: ->(node) { binding_chains[node.object_id] },
        ),
      )
    end

    def smooth_pipeline(lhs, rhs, type = Type.new(:Int64))
      typed(AST::BinaryOp.new(tok, lhs, :SMOOTH, rhs), type)
    end

    def soa_list_type
      type = Type.new(:"Int64[]", collection: :list)
      type.mark_soa_layout!
      type
    end

    it "builds checked source, terminal, execution, and semantic facts" do
      target = :zig
      range_chains = {}
      binding_chains = {}
      builder = plan_builder(target: target, range_chains: range_chains, binding_chains: binding_chains)

      soa = id("soa_items", type: soa_list_type)
      soa_count = AST::CountOp.new(tok, id("_", type: Type.new(:Bool)))
      soa_plan = builder.build(smooth_pipeline(soa, soa_count))
      expect(soa_plan.execution).to eq(PipelineExecutionKind::SoaScalarFold)
      expect(soa_plan.source.kind).to eq(PipelineSourceKind::Soa)
      expect(soa_plan.terminal.kind).to eq(PipelineTerminalKind::ScalarFold)
      expect(soa_plan.facts.bc_target).to be false

      bc_builder = plan_builder(target: :bc, range_chains: range_chains, binding_chains: binding_chains)
      bc_plan = bc_builder.build(smooth_pipeline(soa, AST::CountOp.new(tok, id("_", type: Type.new(:Bool)))))
      expect(bc_plan.execution).to eq(PipelineExecutionKind::MaterializedScalar)
      expect(bc_plan.source.kind).to eq(PipelineSourceKind::Materialized)
      expect(bc_plan.facts.bc_target).to be true

      range = typed(AST::RangeLit.new(tok, lit(0), lit(4), false), Type.new(:"~Int64[]"))
      range_chains[range.object_id] = PipelineRangeChain.new(source: range, stages: [AST::WhereOp.new(tok, id("_", type: Type.new(:Bool)))])
      range_plan = builder.build(smooth_pipeline(range, AST::SumOp.new(tok, id("_"))))
      expect(range_plan.execution).to eq(PipelineExecutionKind::FusedRangeFold)
      expect(range_plan.source.range_chain.stages.length).to eq(1)
      expect(range_plan.facts.range_fused).to be true

      reduce_plan = builder.build(smooth_pipeline(range, AST::ReduceOp.new(tok, lit(0), id("_"))))
      expect(reduce_plan.execution).to eq(PipelineExecutionKind::FusedRangeReduce)
      expect(reduce_plan.terminal.kind).to eq(PipelineTerminalKind::RangeReduce)

      list = id("items", type: Type.new(:"Int64[]", collection: :list))
      binding_smooth = smooth_pipeline(list, AST::CountOp.new(tok, id("_", type: Type.new(:Bool))))
      binding_chains[binding_smooth.object_id] = PipelineBindingUnnestChain.new(
        source: list,
        outer_binding: "$u",
        unnest_expr: id("orders", type: Type.new(:"Int64[]")),
        inner_binding: "$o",
        stages: [],
        fold: AST::CountOp.new(tok, id("_", type: Type.new(:Bool))),
      )
      binding_plan = builder.build(binding_smooth)
      expect(binding_plan.execution).to eq(PipelineExecutionKind::BindingChain)
      expect(binding_plan.source.binding_chain.outer_binding).to eq("$u")
      expect(binding_plan.facts.binding_fused).to be true
    end

    it "maps every materialized terminal and rejects unsupported terminal execution" do
      builder = plan_builder(target: :zig, range_chains: {}, binding_chains: {})
      list = id("items", type: Type.new(:"Int64[]", collection: :list))

      terminals = {
        PipelineExecutionKind::MaterializedList => AST::WhereOp.new(tok, id("_", type: Type.new(:Bool))),
        PipelineExecutionKind::SetDistinct => AST::DistinctOp.new(tok),
        PipelineExecutionKind::BatchWindow => AST::BatchWindowOp.new(tok, { "count" => lit(2) }, id("_")),
        PipelineExecutionKind::SetIndex => AST::IndexOp.new(tok, id("_")),
        PipelineExecutionKind::Each => AST::EachOp.new(tok, []),
        PipelineExecutionKind::Concurrent => AST::ConcurrentOp.new(tok, AST::EachOp.new(tok, []), {}),
      }

      terminals.each do |execution, terminal|
        plan = builder.build(smooth_pipeline(list, terminal, Type.new(:"Int64[]")))
        expect(plan.execution).to eq(execution)
      end

      each_plan = builder.build(smooth_pipeline(list, AST::EachOp.new(tok, [])))
      expect(each_plan.facts.side_effecting).to be true
      concurrent_plan = builder.build(smooth_pipeline(list, AST::ConcurrentOp.new(tok, AST::EachOp.new(tok, []), {})))
      expect(concurrent_plan.facts.concurrent).to be true
      expect(builder.build(smooth_pipeline(list, id("not_a_terminal")))).to be_nil
      expect {
        builder.send(:execution_for, PipelineTerminalKind::RangeFold)
      }.to raise_error(/unsupported pipeline terminal/)
    end
  end

  describe PipelineEachLowerer do
    let(:each_host) { PipelineEachCoverageHost.new }
    let(:each_lowerer) { described_class.new(services: each_host.services) }

    def each_op(body = [AST::FuncCall.new(tok, "touch", [id("_")])])
      AST::EachOp.new(tok, body)
    end

    def soa_type(collection)
      type = Type.new(:"Int64[]", collection: collection)
      type.mark_soa_layout!
      type
    end

    it "routes sharded, SOA, pool, list, set, range-chain, and scalar fallback branches" do
      sharded = id("sharded", type: Type.new(:"Int64[]", collection: :list, shard_count: 4))
      expect(each_lowerer.lower(sharded, each_op).body.first.name).to eq("__sharded")

      soa = id("soa_items", type: soa_type(:list))
      soa_block = each_lowerer.lower(soa, each_op)
      expect(collect_mir_nodes(soa_block, MIR::SoaFieldAccess).first.field_name).to eq("age")

      pool = id("pool_items", type: Type.new(:"Int64[]", collection: :pool))
      pool_block = each_lowerer.lower(pool, each_op)
      expect(collect_mir_nodes(pool_block, MIR::ForStmt).first.iter).to eq(MIR::FieldGet.new(MIR::Ident.new("__each_src"), "slots"))

      each_host.bc_target = true
      bc_pool = each_lowerer.lower(pool, each_op)
      expect(bc_pool).to be_a(MIR::ForStmt)
      expect(collect_mir_nodes(bc_pool, MIR::IfStmt)).not_to be_empty

      list = id("items", type: Type.new(:"Int64[]", collection: :list))
      bc_list = each_lowerer.lower(list, each_op)
      expect(bc_list).to be_a(MIR::ScopeBlock)
      expect(collect_mir_nodes(bc_list, MIR::Set)).not_to be_empty

      each_host.bc_target = false
      list_block = each_lowerer.lower(list, each_op)
      expect(collect_mir_nodes(list_block, MIR::ItemsAccess)).not_to be_empty

      set = id("set_items", type: Type.new(:"Int64[]", collection: :set))
      set_block = each_lowerer.lower(set, each_op)
      expect(collect_mir_nodes(set_block, MIR::WhileStmt).first.capture).to eq("__each_kptr")

      stream = id("events", type: Type.new(:"~Int64[INF]"))
      add_range_chain(each_host, stream, stages: [AST::WhereOp.new(tok, id("_"))])
      expect(each_lowerer.lower(stream, each_op).body.first.name).to eq("__range")

      scalar = id("n", type: Type.new(:Int64))
      expect(each_lowerer.lower(scalar, each_op)).to be_nil
    end

    it "lowers range literals with placeholder-aware capture names" do
      range = typed(AST::RangeLit.new(tok, lit(0), lit(2), true), Type.new(:"~Int64[]"))

      with_placeholder = each_lowerer.lower(range, each_op)
      expect(with_placeholder.capture).to eq("__each_item")
      expect(with_placeholder.iter.end_val).to eq(MIR::BinOp.new("+", MIR::Lit.new("2"), MIR::Lit.new("1")))

      each_host.use_placeholder = false
      without_placeholder = each_lowerer.lower(range, AST::EachOp.new(tok, []))
      expect(without_placeholder.capture).to eq("_")
    end
  end

  describe PipelineContextState do
    it "derives immutable context snapshots for pipeline placeholder state" do
      fields = Set[:age]
      base = described_class.empty
      pipeline = base.with_pipeline_values("__item", "__acc")
      named = pipeline.with_named_binding("$u", "__pipe_u")
      joined = named.with_join_params({ "left" => "__jl" })
      soa = joined.with_soa_rewrite(true, fields)

      expect(base.active?).to be false
      expect(pipeline.placeholder_name).to eq("__item")
      expect(pipeline.acc_placeholder).to eq("__acc")
      expect(named.named_bindings).to eq("$u" => "__pipe_u")
      expect(joined.join_param_map).to eq("left" => "__jl")
      expect(soa.soa_each_mode).to be true
      expect(soa.soa_needed_fields).to equal(fields)
      expect(base.named_bindings).to eq({})
      expect(base.soa_rewrite_active).to be false
    end
  end

  describe PipelinePlaceholderRewriter do
    def rewriter(context)
      described_class.new(context)
    end

    it "returns inactive AST nodes unchanged" do
      node = typed(AST::FuncCall.new(tok, "touch", [id("_")]))

      expect(rewriter(PipelineContextState.empty).substitute(node)).to equal(node)
    end

    it "rewrites block bodies, string assignment targets, and copied AST metadata" do
      source = id("_")
      stamp_pipeline_fixture_metadata(source, coerced_type: :Float64, storage: :heap, var_used: true, slot_size: 16)
      context = PipelineContextState.empty.with_pipeline_values("__item", nil)

      rewritten_source = rewriter(context).substitute(source)
      expect(rewritten_source.name).to eq("__item")
      expect(rewritten_source.full_type!.resolved).to eq(:Int64)
      expect(rewritten_source.coerced_type).to eq(:Float64)
      expect(rewritten_source.storage).to eq(:heap)
      expect(rewritten_source.var_used).to be true
      expect(rewritten_source.slot_size).to eq(16)

      with_block = typed(AST::WithBlock.new(tok, [], [typed(AST::FuncCall.new(tok, "touch", [id("_")]))], []), Type.new(:Void))
      rewritten_with = rewriter(context).substitute(with_block)
      expect(rewritten_with).not_to equal(with_block)
      expect(rewritten_with.body.first.args.first.name).to eq("__item")

      bind = typed(AST::BindExpr.new(tok, "slot", nil, id("_")), Type.new(:Void))
      rewritten_bind = rewriter(context).substitute(bind)
      expect(rewritten_bind.name).to eq("slot")
      expect(rewritten_bind.value.name).to eq("__item")
    end

    it "rewrites SOA field access into indexed field slices and records needed fields" do
      fields = Set.new
      context = PipelineContextState.empty.with_soa_rewrite(false, fields)
      field = typed(AST::GetField.new(tok, id("_"), :age), Type.new(:Int64))

      rewritten = rewriter(context).substitute(field)

      expect(rewritten).to be_a(AST::GetIndex)
      expect(rewritten.target.name).to eq("__soa_age")
      expect(rewritten.index.name).to eq("__soa_i")
      expect(rewritten.full_type!.resolved).to eq(:Int64)
      expect(fields).to include(:age)
    end
  end

  describe PipelineHost do
    let(:lowering) do
      Class.new(MIRLowering) do
        def initialize
          super(input: MIRLoweringInput.new(target: :zig))
          instance_variable_set(:@target, nil)
          instance_variable_set(:@bg_block_counter, 0)
          instance_variable_set(:@rt_name, "rt")
        end

        def lowering_target
          instance_variable_get(:@target) || :zig
        end

        def bc_target?
          lowering_target == :bc
        end

        def runtime_binding_name
          instance_variable_get(:@rt_name)
        end

        def next_pipeline_observable_id
          id = instance_variable_get(:@bg_block_counter)
          instance_variable_set(:@bg_block_counter, id + 1)
          id
        end

        def pipeline_result_alloc
          super
        end

        def pipeline_guarded_cleanup_name?(name)
          super
        end

        def with_runtime_binding_name(rt_name)
          previous = instance_variable_get(:@rt_name)
          instance_variable_set(:@rt_name, rt_name)
          yield
        ensure
          instance_variable_set(:@rt_name, previous)
        end

        def lower(node)
          MIR::Ident.new(node.respond_to?(:name) ? node.name.to_s : "lowered")
        end

        def lower_body(nodes)
          nodes.map { |n| lower(n) }
        end

        def lower_head
          [yield, []]
        end

        def pipeline_alloc_mark_fact(_value, _name, fallback_alloc:, type_info: nil, ast_node: nil,
                                     context: "pipeline allocation", known_allocating: false,
                                     accept_owned_call: false, include_cleanup: false)
          nil
        end

        def pipeline_owned_cleanup_entry(_value, _ast_node)
          nil
        end

        def pipeline_index_insert_with_ownership(insert, _value, _value_owns, target_alloc:)
          insert
        end

        def emit_expr(node)
          node.respond_to?(:value) ? node.value.to_s : node.name.to_s
        end

        def emit_builtin(name, args)
          MIR::InlineZig.new("#{name}(#{args.map { |arg| emit_expr(arg) }.join(", ")})", "test_builtin")
        end

        def append_ownership_transfers_for_mir_body(body)
          body
        end

        def with_fiber_capture_map(_entries, capture_symbols: nil, rt_override: "__rt")
          yield
        end

        def task_config_zig(_stack_size, _computed_tier = nil)
          ".{}"
        end

        def task_config_variant(_stack_size, _computed_tier = nil)
          "Large"
        end

      end.new
    end

    let(:pipeline_host) { PipelineHost.new(lowering: lowering, emitter: MIREmitter.new) }

    it "routes MIRLowering protocol access through the typed bridge" do
      bridge = pipeline_host.instance_variable_get(:@lowering_bridge)
      lowering.function_state.current_decl_alloc = :heap

      expect(bridge.fn_sigs).to eq(lowering.fn_sigs)
      expect(bridge.lowering_target).to eq(:zig)
      expect(bridge.bc_target?).to be false
      lowering.instance_variable_set(:@target, :bc)
      expect(bridge.bc_target?).to be true
      expect(bridge.pipeline_result_alloc).to eq(:heap)
      expect(bridge.mir_schema_lookup.call(:Missing)).to be_nil
      expect(bridge.next_pipeline_observable_id).to eq(0)
      expect(bridge.default_task_config_zig).to eq(".{}")
      expect(bridge.task_config_variant(:large)).to eq("Large")
      expect(bridge.guarded_cleanup_name?("__missing")).to be false

      lowered = bridge.lower_node(id("x"))
      expect(lowered).to eq(MIR::Ident.new("x"))
      expect(bridge.lower_body([id("x")])).to eq([MIR::Ident.new("x")])
      expect(bridge.emit_mir(MIR::Ident.new("x"))).to eq("x")
      expect(bridge.emit_expr(MIR::Ident.new("x"))).to eq("x")
      expect(bridge.emit_builtin(:testBuiltin, [MIR::Lit.new("1")])).to be_a(MIR::InlineZig)
      expect(bridge.lower_head { MIR::Ident.new("head") }.value).to eq(MIR::Ident.new("head"))
      expect(bridge.append_ownership_transfers_for_mir_body([MIR::Suppress.new("x")])).to eq([MIR::Suppress.new("x")])

      lowering.define_singleton_method(:pipeline_alloc_mark_fact) do |_value, name, fallback_alloc:,
          type_info: nil, ast_node: nil, context: "pipeline allocation", known_allocating: false,
          accept_owned_call: false, include_cleanup: false|
        MIRLowering::PipelineAllocMarkFact.new(
          alloc: fallback_alloc,
          mark: MIR::AllocMark.new(name, fallback_alloc, type_info || Type.new(:Int64), :heap),
        )
      end
      fact = bridge.pipeline_alloc_mark_fact(
        MIR::Ident.new("owned"),
        "__owned",
        fallback_alloc: :heap,
        type_info: Type.new(:String),
        ast_node: id("owned", type: Type.new(:String)),
        known_allocating: true,
      )
      expect(fact.mark.name).to eq("__owned")
      expect(bridge.pipeline_owned_cleanup_entry(MIR::Ident.new("x"), nil)).to be_nil
      insert = MIR::IndexInsert.new(MIR::Ident.new("idx"), MIR::Ident.new("k"), MIR::Ident.new("v"))
      expect(bridge.pipeline_index_insert_with_ownership(insert, MIR::Ident.new("v"), false, target_alloc: :heap)).to equal(insert)

      expect(bridge.with_runtime_binding_name("__rt2") { lowering.runtime_binding_name }).to eq("__rt2")
      expect(bridge.with_fiber_capture_map({}, capture_symbols: nil, rt_override: "__rt3") { :ok }).to eq(:ok)
      bridge.emitter_rt_name = "__rt4"
      expect(bridge.emitter_rt_name).to eq("__rt4")
    end

    it "normalizes observable type names and rewrites body identifiers on token boundaries" do
      range_lowerer = pipeline_host.instance_variable_get(:@range_lowerer)

      expect(range_lowerer.without_const_prefix("const *Obs")).to eq("*Obs")
      expect(range_lowerer.without_const_prefix("*Obs")).to eq("*Obs")
      expect(range_lowerer.without_pointer_prefix("*Obs")).to eq("Obs")
      expect(range_lowerer.without_pointer_prefix("Obs")).to eq("Obs")
      expect(range_lowerer.replace_zig_identifier(
        "__obs_acc + __obs_acc_extra + prefix__obs_acc + __obs_acc",
        "__obs_acc",
        "ctx.acc",
      )).to eq("ctx.acc + __obs_acc_extra + prefix__obs_acc + ctx.acc")
      expect(range_lowerer.replace_zig_identifier(
        "source + source_len + other.source",
        "source",
        "ctx.gen",
      )).to eq("ctx.gen + source_len + other.ctx.gen")
    end

    it "adapts PipelineMaterializer services through the real host runtime adapter" do
      lowering.function_state.current_decl_alloc = :heap
      lowering.instance_variable_set(:@target, :bc)
      lookup = empty_schema_lookup
      lowering.define_singleton_method(:mir_schema_lookup) { lookup }
      lowering.define_singleton_method(:pipeline_alloc_mark_fact) do |_value, name, fallback_alloc:,
          type_info: nil, ast_node: nil, context: "pipeline allocation", known_allocating: false,
          accept_owned_call: false, include_cleanup: false|
        OpenStruct.new(
          alloc: fallback_alloc,
          mark: MIR::AllocMark.new(name, fallback_alloc, type_info || Type.new(:Int64), :heap),
        )
      end

      materializer = pipeline_host.instance_variable_get(:@materializer)

      expect(materializer.result_alloc).to eq(:heap)
      expect(materializer.schema_lookup.call(:Missing)).to be_nil

      soa_pool_type = Type.new(:"Int64[8]", collection: :pool)
      soa_pool_type.mark_soa_layout!
      soa_pool = materializer.items_setup(soa_pool_type)
      expect(soa_pool.statements.first.init).to be_a(MIR::ItemsAccess)

      block = materializer.pipeline_block(id("source", type: Type.new(:"Int64[]"))) do |items, label|
        [MIR::BreakStmt.new(label, MIR::Ident.new(items))]
      end
      expect(pipeline_host.instance_variable_get(:@current_pipe_label)).to eq("__pblk1")
      expect(block.body.first).to be_a(MIR::AllocMark)
      expect(block.body.last.value.name).to eq("pipe_items")

      scoped = materializer.append_owned_value_stmt(
        "items",
        :heap,
        MIR::DeepCopy.new(MIR::Ident.new("value"), "Payload", nil, :full_value, :heap),
      )
      expect(scoped.body.first.name).to eq("__pipe_item_1")
    end

    it "scopes optional named bindings" do
      expect(pipeline_host.with_optional_named_binding(nil, "__ignored") {
        pipeline_host.send(:current_context).named_bindings.dup
      }).to eq({})
      result = pipeline_host.with_optional_named_binding("$u", "__pipe_u") do
        pipeline_host.send(:substitute_placeholders, id("$u")).name
      end
      expect(result).to eq("__pipe_u")
      expect(pipeline_host.send(:current_context).named_bindings).to eq({})
    end

    it "visits placeholders, join params, named bindings, SOA fields, and accumulators" do
      pipeline_host.send(:with_pipeline_context, placeholder: "__it") do
        expect(pipeline_host.visit(id("_"))).to eq("__it")
      end

      context = pipeline_host.send(:current_context).with_join_params({ "left" => "__jl" })
      pipeline_host.send(:with_context_state, context) do
        expect(pipeline_host.visit(id("left"))).to eq("__jl")
      end

      pipeline_host.with_named_binding("$u", "__pipe_u") do
        expect(pipeline_host.visit(id("$u"))).to eq("__pipe_u")
      end

      pipeline_host.send(:with_soa_rewrite, each_mode: false) do
        expect(pipeline_host.visit(AST::GetField.new(tok, id("_"), :x))).to eq("__soa_x[__soa_i]")

        assign = AST::Assignment.new(tok, AST::GetField.new(tok, id("_"), :x), lit(1))
        expect(pipeline_host.visit(assign)).to include("__soa_x[__soa_i] =")
      end

      pipeline_host.send(:with_pipeline_context, acc: "__acc") do
        expect(pipeline_host.visit(id("acc"))).to eq("__acc")
      end
    end

    it "substitutes placeholders through common expression nodes" do
      context = pipeline_host.send(:current_context)
        .with_pipeline_values("__it", "__acc")
        .with_join_params({ "r" => "__jr" })
        .with_named_binding("$u", "__pipe_u")

      pipeline_host.send(:with_context_state, context) do
        expect(pipeline_host.send(:substitute_placeholders, typed(AST::FuncCall.new(tok, "f", [id("_")]))).args.first.name).to eq("__it")
        expect(pipeline_host.send(:substitute_placeholders, typed(AST::MethodCall.new(tok, id("_"), "m", [id("acc")]))).object.name).to eq("__it")
        expect(pipeline_host.send(:substitute_placeholders, typed(AST::BinaryOp.new(tok, id("_"), :ADD, id("acc")))).right.name).to eq("__acc")
        expect(pipeline_host.send(:substitute_placeholders, typed(AST::GetIndex.new(tok, id("$u"), id("r")))).target.name).to eq("__pipe_u")
        expect(pipeline_host.send(:substitute_placeholders, typed(AST::UnaryOp.new(tok, :NOT, id("_")))).right.name).to eq("__it")
        expect(pipeline_host.send(:substitute_placeholders, typed(AST::StructLit.new(tok, "Box", { "x" => id("_") }))).fields["x"].name).to eq("__it")
        expect(pipeline_host.send(:substitute_placeholders, typed(AST::HashLit.new(tok, { "k" => id("_") }))).pairs["k"].name).to eq("__it")
        expect(pipeline_host.send(:substitute_placeholders, typed(AST::Assert.new(tok, id("_"), nil))).condition.name).to eq("__it")

        if_stmt = typed(AST::IfStatement.new(tok, id("_"), [typed(AST::FuncCall.new(tok, "t", [id("_")]))], [typed(AST::FuncCall.new(tok, "e", [id("acc")]))]))
        replaced = pipeline_host.send(:substitute_placeholders, if_stmt)
        expect(replaced.condition.name).to eq("__it")
        expect(replaced.then_branch.first.args.first.name).to eq("__it")
        expect(replaced.else_branch.first.args.first.name).to eq("__acc")
      end
    end

    it "preserves intrinsic call metadata while substituting placeholders" do
      signature = FunctionSignature.new(params: [], return_type: Type.new(:Int64))
      call = typed(AST::FuncCall.new(tok, "checked", [id("_")]))
      stamp_pipeline_fixture_call_metadata(call, signature)

      rewritten = pipeline_host.send(:with_pipeline_context, placeholder: "__it") do
        pipeline_host.send(:substitute_placeholders, call)
      end

      expect(rewritten).not_to equal(call)
      expect(rewritten.args.first.name).to eq("__it")
      expect(rewritten.zig_pattern).to eq(call.zig_pattern)
      expect(rewritten.matched_stdlib_def).to eq(signature)
      expect(rewritten.matched_signature).to eq(signature)
      expect(rewritten.stdlib_allocates).to be true
      expect(rewritten.mutates_receiver).to be true
      expect(rewritten.can_fail).to be true
      expect(rewritten.error_kind).to eq(:IO)
      expect(rewritten.error_type).to eq(:FileError)
    end

    it "preserves storage slot size while substituting typed nodes" do
      source = id("_")
      stamp_pipeline_fixture_metadata(source, slot_size: 16)

      rewritten = pipeline_host.send(:with_pipeline_context, placeholder: "__it") do
        pipeline_host.send(:substitute_placeholders, source)
      end

      expect(rewritten.name).to eq("__it")
      expect(rewritten.slot_size).to eq(16)
    end

    it "substitutes assignment and bind targets plus SOA EACH fields" do
      pipeline_host.send(:with_pipeline_context, placeholder: "__it") do
        pipeline_host.send(:with_soa_rewrite, each_mode: true) do
          gf = typed(AST::GetField.new(tok, id("_"), :x))
          expect(pipeline_host.send(:substitute_placeholders, gf).name).to eq("__soa_x[__soa_i]")

          bind = typed(AST::BindExpr.new(tok, typed(AST::GetField.new(tok, id("_"), :x)), nil, id("_")))
          expect(pipeline_host.send(:substitute_placeholders, bind).name.name).to eq("__soa_x[__soa_i]")

          assign = typed(AST::Assignment.new(tok, typed(AST::GetField.new(tok, id("_"), :x)), id("_")))
          expect(pipeline_host.send(:substitute_placeholders, assign).name.name).to eq("__soa_x[__soa_i]")
        end
      end
    end

    it "does not skip SOA rewrite-active substitution when no placeholder is active" do
      rewritten = pipeline_host.send(:with_soa_rewrite, each_mode: false) do
        pipeline_host.send(:substitute_placeholders, typed(AST::GetField.new(tok, id("_"), :x)))
      end

      expect(rewritten).to be_a(AST::GetIndex)
      expect(rewritten.target.name).to eq("__soa_x")
    end

    it "detects placeholder usage in nested statement trees" do
      stmt = AST::FuncCall.new(tok, "f", [AST::BinaryOp.new(tok, id("x"), :ADD, id("_"))])
      expect(pipeline_host.send(:ast_stmts_use_placeholder?, [stmt])).to be true
      expect(pipeline_host.send(:ast_stmts_use_placeholder?, [AST::FuncCall.new(tok, "f", [id("x")])])).to be false
    end

    it "unwraps finite range SMOOTH chains and rejects non-SMOOTH range candidates" do
      range = AST::RangeLit.new(tok, lit(0), lit(4), false)
      where = AST::WhereOp.new(tok, id("_"))
      chain = typed(AST::BinaryOp.new(tok, range, :SMOOTH, where), Type.new(:"Int64[]"))
      non_smooth = typed(AST::BinaryOp.new(tok, id("items", type: Type.new(:"Int64[]")), :ADD, where), Type.new(:"Int64[]"))

      result = pipeline_host.send(:unwrap_range_chain, chain)
      expect(result).to be_a(PipelineRangeChain)
      expect(result.source).to equal(range)
      expect(result.stages).to eq([where])
      expect(pipeline_host.send(:unwrap_range_chain, non_smooth)).to be_nil
    end

    it "unwraps binding UNNEST fold chains and rejects malformed left spines" do
      source = id("users", type: Type.new(:"User[]"))
      outer_binding = AST::BinaryOp.new(tok, source, :BIND_VAR, id("$u"))
      unnest_expr = AST::GetField.new(tok, id("$u"), :orders)
      unnest = AST::UnnestOp.new(tok, unnest_expr)
      unnest_chain = typed(AST::BinaryOp.new(tok, outer_binding, :SMOOTH, unnest), Type.new(:"Order[]"))
      where = AST::WhereOp.new(tok, id("_"))
      filtered_chain = typed(AST::BinaryOp.new(tok, unnest_chain, :SMOOTH, where), Type.new(:"Order[]"))
      fold = AST::CountOp.new(tok, id("_"))
      full_chain = typed(AST::BinaryOp.new(tok, filtered_chain, :SMOOTH, fold), Type.new(:Int64))
      malformed_left = typed(AST::BinaryOp.new(tok, outer_binding, :ADD, unnest), Type.new(:"Order[]"))
      malformed_chain = typed(AST::BinaryOp.new(tok, malformed_left, :SMOOTH, fold), Type.new(:Int64))
      non_smooth_terminal = typed(AST::BinaryOp.new(tok, malformed_left, :ADD, fold), Type.new(:Int64))

      result = pipeline_host.send(:unwrap_binding_unnest_chain, full_chain)

      expect(result.source).to equal(source)
      expect(result.outer_binding).to eq("$u")
      expect(result.unnest_expr).to equal(unnest_expr)
      expect(result.stages).to eq([where])
      expect(pipeline_host.send(:unwrap_binding_unnest_chain, malformed_chain)).to be_nil
      expect(pipeline_host.send(:unwrap_binding_unnest_chain, non_smooth_terminal)).to be_nil
    end

    it "exposes source shape predicates and binding-chain stage capture facts" do
      shape = PipelineHost::PipelineSourceShape.new(
        type: Type.new(:"~Int64[INF]"),
        bc_target: true,
        named_source: true,
      )
      expect(shape.infinite_stream?).to be true
      expect(shape.bc_named_infinite_stream?).to be true

      source = id("users", type: Type.new(:"User[]"))
      chain = PipelineHost::BindingUnnestChain.new(
        source: source,
        outer_binding: "$u",
        unnest_expr: id("orders", type: Type.new(:"Int64[]")),
        inner_binding: nil,
        stages: [AST::WhereOp.new(tok, id("_", type: Type.new(:Bool)))],
        fold: AST::CountOp.new(tok, id("flag", type: Type.new(:Bool))),
      )
      lowerer = pipeline_host.instance_variable_get(:@binding_chain_lowerer)

      expect(lowerer.send(:inner_capture_required?, chain)).to be true
    end

    it "keeps host service adapters and terminal wrappers narrow" do
      list_services = pipeline_host.send(:build_list_services)
      expect(list_services.owning_pipeline_temp_stmts.call(
        "__owned",
        MIR::Ident.new("source"),
        Type.new(:String),
        "[]u8",
        :heap,
      )).to include(a_kind_of(MIR::AllocMark), a_kind_of(MIR::Let), a_kind_of(MIR::ErrCleanup))

      binding_services = pipeline_host.send(:build_binding_chain_services)
      reduced = binding_services.visit_mir_with_reduce_placeholders.call(
        typed(AST::BinaryOp.new(tok, id("_"), :ADD, id("acc"))),
        "__item",
        "__acc",
      )
      expect(reduced).to be_a(MIR::Ident)

      site = PipelineHost::PipelineSite.new(
        list: id("items", type: Type.new(:"Int64[]")),
        options: typed(AST::BinaryOp.new(tok, id("items", type: Type.new(:"Int64[]")), :SMOOTH, AST::CountOp.new(tok, id("_"))), Type.new(:Int64)),
      )
      block = MIR::BlockExpr.new("__delegated", [])
      scalar_calls = []
      scalar = Object.new
      scalar.define_singleton_method(:lower) do |_site, op|
        scalar_calls << op.class
        block
      end
      pipeline_host.instance_variable_set(:@scalar_lowerer, scalar)

      pipeline_host.send(:lower_sum, site, AST::SumOp.new(tok, id("_")))
      pipeline_host.send(:lower_average, site, AST::AverageOp.new(tok, id("_")))
      pipeline_host.send(:lower_min, site, AST::MinOp.new(tok, id("_")))
      pipeline_host.send(:lower_max, site, AST::MaxOp.new(tok, id("_")))
      pipeline_host.send(:lower_any, site, AST::AnyOp.new(tok, id("_", type: Type.new(:Bool))))
      pipeline_host.send(:lower_all, site, AST::AllOp.new(tok, id("_", type: Type.new(:Bool))))
      pipeline_host.send(:lower_find, site, AST::FindOp.new(tok, id("_", type: Type.new(:Bool))))
      expect(scalar_calls).to eq([
        AST::SumOp, AST::AverageOp, AST::MinOp, AST::MaxOp,
        AST::AnyOp, AST::AllOp, AST::FindOp,
      ])

      list_calls = []
      list = Object.new
      list.define_singleton_method(:lower_where_expr) { |_site, expr| list_calls << [:where, expr.class]; block }
      list.define_singleton_method(:lower_select_expr) { |_site, expr| list_calls << [:select, expr.class]; block }
      list.define_singleton_method(:lower_take_while_expr) { |_site, expr| list_calls << [:take, expr.class]; block }
      list.define_singleton_method(:lower) { |_site, op| list_calls << [:terminal, op.class]; block }
      pipeline_host.instance_variable_set(:@list_lowerer, list)

      pipeline_host.send(:lower_where, site, id("_", type: Type.new(:Bool)))
      pipeline_host.send(:lower_select, site, id("_"))
      pipeline_host.send(:lower_limit, site, AST::LimitOp.new(tok, lit(2)))
      pipeline_host.send(:lower_take_while, site, id("_", type: Type.new(:Bool)))
      pipeline_host.send(:lower_skip, site, AST::SkipOp.new(tok, lit(1)))
      pipeline_host.send(:lower_unnest, site, typed(AST::UnnestOp.new(tok, id("_")), Type.new(:"Int64[]")))
      pipeline_host.send(:lower_reduce, site, typed(AST::ReduceOp.new(tok, lit(0), id("_")), Type.new(:Int64)))
      pipeline_host.send(:lower_window, site, typed(AST::WindowOp.new(tok, lit(2), id("_")), Type.new(:"Int64[]")))
      pipeline_host.send(:lower_order_by, site, AST::OrderByOp.new(tok, id("_")))
      pipeline_host.send(:lower_join, site, AST::JoinOp.new(tok, id("other", type: Type.new(:"Int64[]")), id("_")))
      pipeline_host.send(:lower_tap, site, AST::TapOp.new(tok, []))
      expect(list_calls.map(&:first)).to eq([
        :where, :select, :terminal, :take, :terminal, :terminal,
        :terminal, :terminal, :terminal, :terminal, :terminal,
      ])

      sharded_calls = []
      concurrent = Object.new
      concurrent.define_singleton_method(:lower_sharded_each) do |list_node, each_op|
        sharded_calls << [list_node, each_op]
        MIR::ScopeBlock.new([])
      end
      pipeline_host.instance_variable_set(:@concurrent_lowerer, concurrent)
      each = AST::EachOp.new(tok, [])
      expect(pipeline_host.send(:lower_sharded_each, site.list, each)).to be_a(MIR::ScopeBlock)
      expect(sharded_calls).to eq([[site.list, each]])
    end

    it "exercises PipelineHost service records and range adapter wrappers" do
      stub_pipeline_host_mir_visitors(pipeline_host)
      list = id("items", type: Type.new(:"Int64[]", collection: :list))
      select_smooth = typed(AST::BinaryOp.new(tok, list, :SMOOTH, AST::SelectOp.new(tok, id("_"))), Type.new(:"Int64[]"))
      sum_smooth = typed(AST::BinaryOp.new(tok, list, :SMOOTH, AST::SumOp.new(tok, id("_"))), Type.new(:Int64))

      each_services = pipeline_host.send(:build_each_services)
      expect(each_services.ast_stmts_use_placeholder.call([AST::FuncCall.new(tok, "touch", [id("_")])])).to be true
      expect(each_services.next_index_name.call).to eq("__each_i_1")

      concurrent_services = pipeline_host.send(:build_concurrent_services)
      expect(concurrent_services.lower_select.call(list, select_smooth, id("_"))).to be_a(MIR::BlockExpr)
      expect(concurrent_services.lower_where.call(list, select_smooth, id("_", type: Type.new(:Bool)))).to be_a(MIR::BlockExpr)
      expect(concurrent_services.lower_each.call(list, select_smooth, AST::EachOp.new(tok, []))).to be_a(MIR::ScopeBlock)
      expect(concurrent_services.lower_sum.call(list, sum_smooth, AST::SumOp.new(tok, id("_")))).to be_a(MIR::BlockExpr)

      expect(pipeline_host.send(:visit_pipeline_expr_mir, list, id("_"), "__item")).to be_a(MIR::Ident)
      expect(pipeline_host.send(:ast_uses_bare_placeholder?, AST::FuncCall.new(tok, "touch", [id("_")]))).to be true
      expect(pipeline_host.send(:ast_uses_bare_placeholder?, AST::GetField.new(tok, id("_"), :x))).to be false

      range = typed(AST::RangeLit.new(tok, lit(0), lit(2), true), Type.new(:"~Int64[]"))
      expect(pipeline_host.send(:finite_stream_source_node?, range)).to be true
      expect(pipeline_host.send(:numeric_fold_expr_typed, lit(1), "__item", "f64")).to be_a(MIR::Cast)
      expect(pipeline_host.send(:bc_for_iter_range, range, "__item").first).to be_a(MIR::IterRange)
      expect(pipeline_host.send(:bc_target?)).to be false

      source = id("events", type: Type.new(:"~Int64[]"))
      count = AST::CountOp.new(tok, id("_"))
      smooth = typed(AST::BinaryOp.new(tok, source, :SMOOTH, count), Type.new(:Int64))
      expect(pipeline_host.send(:pipeline_element_owns_heap?, Type.new(:String))).to be true
      expect(pipeline_host.send(:default_obs_alloc_expr, smooth)).to be_a(MIR::TryCatch)
      expect(pipeline_host.send(:observable_catch_unreachable, MIR::Lit.new("x"))).to be_a(MIR::TryCatch)
      expect(pipeline_host.send(:observable_alloc_expr, "Obs", "new", [MIR::AllocatorRef.new(:heap)])).to be_a(MIR::TryCatch)
    end

    it "lowers uncovered materialized list terminal shapes through typed services" do
      labels = []
      services = PipelineListServices.new(
        visit_mir: ->(node) {
          case node
          when AST::Literal then MIR::Lit.new(node.value.to_s)
          when AST::Identifier then MIR::Ident.new(node.name.to_s)
          else MIR::Ident.new("expr")
          end
        },
        visit_expr: ->(_list_node, _expr_node, placeholder) { MIR::Ident.new(placeholder) },
        visit_reduce_expr: ->(_expr_node, item_placeholder, acc_placeholder) {
          MIR::BinOp.new("+", MIR::Ident.new(item_placeholder), MIR::Ident.new(acc_placeholder))
        },
        visit_body: ->(_body_stmts, placeholder) { [MIR::Suppress.new(placeholder)] },
        visit_join_lambda: ->(_body, _join_params) { MIR::Lit.new("true") },
        pipeline_block: ->(_list_node, blk) {
          label = "__list#{labels.length + 1}"
          labels << label
          MIR::BlockExpr.new(label, blk.call("pipe_items", label))
        },
        transpile_type: ->(type_info) { type_info.to_s.include?("Int64") ? "i64" : type_info.to_s },
        pipeline_alloc: ->(_smooth_node) { :heap },
        pipeline_result_alloc: -> { :heap },
        source_shape: ->(source_node) {
          PipelineHost::PipelineSourceShape.new(
            type: source_node.full_type!,
            bc_target: true,
            named_source: source_node.is_a?(AST::Identifier),
          )
        },
        next_label: -> {
          label = "__direct#{labels.length + 1}"
          labels << label
          label
        },
        set_current_label: ->(label) { labels << "current:#{label}" },
        append_owned_value_stmt: ->(receiver, _alloc, value_expr) {
          MIR::ExprStmt.new(MIR::MethodCall.new(MIR::Ident.new(receiver), "append", [value_expr], false,
            MIR::CallableContract.no_ownership(1)), nil)
        },
        borrowed_pipeline_value: ->(value, _type_info, _alloc) { value },
        cleanup_bearing_type: ->(_type_info) { true },
        owning_pipeline_temp_stmts: ->(name, source, type_info, _zig_type, _alloc) {
          [MIR::Let.new(name, source, false, type_info, nil)]
        },
      )
      lowerer = PipelineListLowerer.new(services: services)
      items = id("items", type: Type.new(:"Int64[]"))

      where_site = PipelineHost::PipelineSite.new(
        list: items,
        options: typed(AST::BinaryOp.new(tok, items, :SMOOTH, AST::WhereOp.new(tok, id("_"))), Type.new(:"Int64[]")),
      )
      expect(lowerer.lower_where_expr(where_site, id("_", type: Type.new(:Bool)))).to be_a(MIR::BlockExpr)
      expect(lowerer.lower_select_expr(where_site, id("_"))).to be_a(MIR::BlockExpr)
      expect(lowerer.lower_take_while_expr(where_site, id("_", type: Type.new(:Bool)))).to be_a(MIR::BlockExpr)

      stream = id("events", type: Type.new(:"~Int64[INF]"))
      limit = AST::LimitOp.new(tok, lit(2))
      limit_site = PipelineHost::PipelineSite.new(
        list: stream,
        options: typed(AST::BinaryOp.new(tok, stream, :SMOOTH, limit), Type.new(:"Int64[]")),
      )
      limit_block = lowerer.lower(limit_site, limit)
      expect(limit_block.body.grep(MIR::Let).map(&:name)).to include("__lim_src", "__lim_res")

      unnest = typed(AST::UnnestOp.new(tok, id("_", type: Type.new(:"Int64[]"))), Type.new(:"Int64[]"))
      unnest_block = lowerer.lower(where_site, unnest)
      expect(collect_mir_nodes(unnest_block, MIR::ForStmt).length).to be >= 2

      join = AST::JoinOp.new(tok, id("other", type: Type.new(:"Int64[]")), id("key"))
      join_block = lowerer.lower(where_site, join)
      expect(collect_mir_nodes(join_block, MIR::ErrCleanup)).not_to be_empty
      expect(collect_mir_nodes(join_block, MIR::TransferMark).map(&:name)).to include("__jl_owned", "__match")
      expect(collect_mir_nodes(join_block, MIR::Call).map(&:callee)).to include("CheatLib.eql")
    end

    it "builds typed lazy range prefixes for finite stage chains" do
      stub_pipeline_host_mir_visitors(pipeline_host)

      range = typed(AST::RangeLit.new(tok, lit(0), lit(5), false), Type.new(:"~Int64[]"))
      select = AST::SelectOp.new(tok, id("_"))
      where = AST::WhereOp.new(tok, id("_"))
      take = AST::TakeWhileOp.new(tok, id("_"))
      limit = AST::LimitOp.new(tok, lit(3))
      skip = AST::SkipOp.new(tok, lit(1))
      tap = AST::TapOp.new(tok, [AST::FuncCall.new(tok, "touch", [id("_")])])

      prefix = pipeline_host.send(:build_lazy_range_prefix, range, [select, where, take, limit, skip, tap])

      expect(prefix).to be_a(PipelineHost::LazyRangePrefix)
      expect(prefix.range_let).to be_a(MIR::Let)
      expect(prefix.source_name).to eq("__range_src")
      expect(prefix.initial_capture).to eq("__each_item")
      expect(prefix.item_var).to eq("__each_item_1")
      expect(prefix.item_used).to be true
      expect(prefix.elem_zig).to eq("i64")
      expect(prefix.next_method).to eq("next")
      expect(prefix.setup_stmts.first).to equal(prefix.range_let)
      expect(prefix.outer_stmts.map(&:name)).to eq(["__limit_cnt_2", "__limit_max_2", "__skip_cnt_3", "__skip_max_3"])
      expect(prefix.stage_stmts.map(&:class)).to eq([
        MIR::Let,
        MIR::IfStmt,
        MIR::IfStmt,
        MIR::IfStmt,
        MIR::Set,
        MIR::IfStmt,
        MIR::Suppress,
      ])
    end

    it "builds typed lazy range prefixes for named runtime streams without materializing the source" do
      stream = id("events", type: Type.new(:"~Int64[]"))

      prefix = pipeline_host.send(:build_lazy_range_prefix, stream, [])

      expect(prefix).to be_a(PipelineHost::LazyRangePrefix)
      expect(prefix.range_let).to be_nil
      expect(prefix.source_name).to eq("events")
      expect(prefix.outer_stmts).to be_empty
      expect(prefix.stage_stmts).to be_empty
      expect(prefix.next_method).to eq("next")
    end

    it "threads typed lazy range prefixes through non-bytecode bounded stream consumers" do
      stub_pipeline_host_mir_visitors(pipeline_host)
      lookup = empty_schema_lookup
      lowering.define_singleton_method(:mir_schema_lookup) { lookup }

      stream = id("events", type: Type.new(:"~Int64[4]"))
      distinct = AST::DistinctOp.new(tok, id("_"))
      distinct_smooth = AST::BinaryOp.new(tok, stream, :SMOOTH, distinct)
      typed(distinct_smooth, Type.new(:"Int64[]", collection: :set))
      distinct_block = pipeline_host.send(:lower_distinct,
        PipelineHost::PipelineSite.new(list: stream, options: distinct_smooth), distinct)

      index = AST::IndexOp.new(tok, id("_"))
      index_smooth = typed(AST::BinaryOp.new(tok, stream, :SMOOTH, index), Type.new(:Any))
      index_block = pipeline_host.send(:lower_index,
        PipelineHost::PipelineSite.new(list: stream, options: index_smooth), index.expression)

      each_block = pipeline_host.send(:lower_each_range,
        stream, [], AST::EachOp.new(tok, [AST::FuncCall.new(tok, "touch", [id("_")])]))

      cleanup = pipeline_host.send(:consumed_stream_item_cleanup,
        "__owned_item", id("names", type: Type.new(:"~String[]")))

      count = AST::CountOp.new(tok, id("_"))
      count_smooth = typed(AST::BinaryOp.new(tok, stream, :SMOOTH, count), Type.new(:Int64))
      fold_block = pipeline_host.send(:lower_range_fold, stream, [], count, count_smooth)

      reduce = AST::ReduceOp.new(tok, lit(0), id("_"))
      typed(reduce, Type.new(:Int64))
      reduce_block = pipeline_host.send(:lower_range_reduce, stream, [], reduce)

      expect(distinct_block.body).to include(a_kind_of(MIR::DeferStmt), a_kind_of(MIR::WhileStmt))
      expect(index_block.body).to include(a_kind_of(MIR::DeferStmt), a_kind_of(MIR::WhileStmt))
      expect(each_block.body).to include(a_kind_of(MIR::DeferStmt), a_kind_of(MIR::WhileStmt))
      expect(cleanup).to contain_exactly(a_kind_of(MIR::ExprStmt))
      expect(fold_block.body).to include(a_kind_of(MIR::DeferStmt), a_kind_of(MIR::WhileStmt))
      expect(reduce_block.body).to include(a_kind_of(MIR::DeferStmt), a_kind_of(MIR::WhileStmt))
    end

    it "threads typed lazy range prefixes through bytecode range reduce" do
      lowering.instance_variable_set(:@target, :bc)
      stub_pipeline_host_mir_visitors(pipeline_host)
      range = typed(AST::RangeLit.new(tok, lit(0), lit(4), false), Type.new(:"~Int64[]"))
      reduce = AST::ReduceOp.new(tok, lit(0), id("_"))
      typed(reduce, Type.new(:Int64))

      reduce_block = pipeline_host.send(:lower_range_reduce, range, [], reduce)

      expect(reduce_block.body).to include(a_kind_of(MIR::ForStmt))
    ensure
      lowering.instance_variable_set(:@target, nil)
    end

    it "threads typed lazy range prefixes through bytecode range each" do
      lowering.instance_variable_set(:@target, :bc)
      stub_pipeline_host_mir_visitors(pipeline_host)
      range = typed(AST::RangeLit.new(tok, lit(0), lit(4), false), Type.new(:"~Int64[]"))
      each = AST::EachOp.new(tok, [id("_")])

      each_block = pipeline_host.send(:lower_each_range, range, [], each)

      loop = each_block.body.find { |stmt| stmt.is_a?(MIR::ForStmt) }
      expect(loop).not_to be_nil
      expect(loop.iter).to be_a(MIR::IterRange)
    ensure
      lowering.instance_variable_set(:@target, nil)
    end

    it "builds scalar range fold plans for every terminal" do
      stub_pipeline_host_mir_visitors(pipeline_host)
      range = typed(AST::RangeLit.new(tok, lit(0), lit(4), false), Type.new(:"~Int64[]"))
      pred = id("_", type: Type.new(:Bool))
      value = id("_", type: Type.new(:Int64))

      count_block = pipeline_host.send(:lower_range_fold, range, [], AST::CountOp.new(tok, pred),
        typed(AST::BinaryOp.new(tok, range, :SMOOTH, AST::CountOp.new(tok, pred)), Type.new(:Int64)))
      sum_block = pipeline_host.send(:lower_range_fold, range, [], AST::SumOp.new(tok, value),
        typed(AST::BinaryOp.new(tok, range, :SMOOTH, AST::SumOp.new(tok, value)), Type.new(:Int64)))
      average_block = pipeline_host.send(:lower_range_fold, range, [], AST::AverageOp.new(tok, value),
        typed(AST::BinaryOp.new(tok, range, :SMOOTH, AST::AverageOp.new(tok, value)), Type.new(:Float64)))
      min_block = pipeline_host.send(:lower_range_fold, range, [], AST::MinOp.new(tok, value),
        typed(AST::BinaryOp.new(tok, range, :SMOOTH, AST::MinOp.new(tok, value)), Type.new(:Int64)))
      max_block = pipeline_host.send(:lower_range_fold, range, [], AST::MaxOp.new(tok, value),
        typed(AST::BinaryOp.new(tok, range, :SMOOTH, AST::MaxOp.new(tok, value)), Type.new(:Int64)))
      any_block = pipeline_host.send(:lower_range_fold, range, [], AST::AnyOp.new(tok, pred),
        typed(AST::BinaryOp.new(tok, range, :SMOOTH, AST::AnyOp.new(tok, pred)), Type.new(:Bool)))
      all_block = pipeline_host.send(:lower_range_fold, range, [], AST::AllOp.new(tok, pred),
        typed(AST::BinaryOp.new(tok, range, :SMOOTH, AST::AllOp.new(tok, pred)), Type.new(:Bool)))
      find_block = pipeline_host.send(:lower_range_fold, range, [], AST::FindOp.new(tok, pred),
        typed(AST::BinaryOp.new(tok, range, :SMOOTH, AST::FindOp.new(tok, pred)), Type.optional_of(:Int64)))
      direct_find_block = pipeline_host.send(:lower_range_fold, range, [], AST::FindOp.new(tok, pred),
        typed(AST::BinaryOp.new(tok, range, :SMOOTH, AST::FindOp.new(tok, pred)), Type.new(:Int64)))

      expect(count_block.body).to include(a_kind_of(MIR::WhileStmt))
      expect(count_block.body.grep(MIR::Let).map(&:name)).to include("__fold_acc")
      expect(sum_block.body.find { |stmt| stmt.is_a?(MIR::WhileStmt) }.body).to include(a_kind_of(MIR::Set))
      expect(average_block.body.grep(MIR::Let).map(&:name)).to include("__fold_sum", "__fold_cnt")
      expect(average_block.body.last.value).to be_a(MIR::Conditional)
      expect(min_block.body).to include(
        an_object_having_attributes(then_body: include(an_object_having_attributes(message: "MIN applied to empty sequence")))
      )
      expect(max_block.body).to include(
        an_object_having_attributes(then_body: include(an_object_having_attributes(message: "MAX applied to empty sequence")))
      )
      expect(any_block.body.find { |stmt| stmt.is_a?(MIR::WhileStmt) }.body.first.then_body).to include(a_kind_of(MIR::BreakStmt))
      expect(all_block.body.find { |stmt| stmt.is_a?(MIR::WhileStmt) }.body.first.then_body).to include(a_kind_of(MIR::BreakStmt))
      expect(find_block.body.grep(MIR::Let).map(&:name)).to include("__fold_result", "__fold_found")
      expect(find_block.body.last.value).to be_a(MIR::Conditional)
      direct_find_result = direct_find_block.body.grep(MIR::Let).find { |let| let.name == "__fold_result" }
      expect(direct_find_result.annotation.to_s).to eq("i64")
    end

    it "suffixes bytecode fold variables with the block label" do
      names = PipelineRangeFoldNames.for_label("__pblk12", true)

      expect(names.acc).to eq("__fold_acc_b12")
      expect(names.cnt).to eq("__fold_cnt_b12")
      expect(PipelineRangeFoldNames.for_label("__pblk12", false).acc).to eq("__fold_acc")
    end

    it "dispatches observable range folds through the typed terminal registry" do
      stub_pipeline_host_mir_visitors(pipeline_host)
      lowering.define_singleton_method(:emit_expr) { |node| MIREmitter.new.emit(node) }
      lookup = empty_schema_lookup
      lowering.define_singleton_method(:mir_schema_lookup) { lookup }
      stream = id("events", type: Type.new(:"~Int64[]"))
      count = AST::CountOp.new(tok, id("_"))
      smooth = typed(AST::BinaryOp.new(tok, stream, :SMOOTH, count), Type.new(:Int64))
      smooth.observable_dest = true

      block = pipeline_host.send(:lower_range_fold, stream, [], count, smooth)

      expect(block.body).to include(a_kind_of(MIR::AllocMark), a_kind_of(MIR::ExprStmt), a_kind_of(MIR::BreakStmt))
      expect(block.body.find { |stmt| stmt.is_a?(MIR::ExprStmt) && stmt.expr.is_a?(MIR::ZigTemplate) }).not_to be_nil
    end

    it "rejects observable range folds without a terminal registry entry" do
      stub_pipeline_host_mir_visitors(pipeline_host)
      stream = id("events", type: Type.new(:"~Int64[]"))
      count = AST::CountOp.new(tok, id("_"))
      smooth = typed(AST::BinaryOp.new(tok, stream, :SMOOTH, count), Type.new(:Int64))
      smooth.observable_dest = true
      stub_const("PipelineRangeLowerer::FOLD_OP_OBSERVABLE_TERMINAL", {})

      expect {
        pipeline_host.send(:lower_range_fold, stream, [], count, smooth)
      }.to raise_error(CompilerError, /observable_dest set but no terminal registered/)
    end

    it "lowers SHARD+CONCURRENT EACH to a sequential BC loop" do
      lowering.instance_variable_set(:@target, :bc)
      range = AST::RangeLit.new(tok, lit(0), lit(4), false)
      key_expr = id("_")
      map = id("counts")
      conc = AST::ConcurrentOp.new(tok, AST::EachOp.new(tok, [AST::FuncCall.new(tok, "touch", [id("_")])]), {})
      conc.shard_context = AST::PipelineShardContext.new(
        auto_detected: true,
        key_expr: key_expr,
        map_var: map,
      )

      pipeline_host.define_singleton_method(:visit_mir) do |node|
        node.is_a?(AST::Literal) ? MIR::Lit.new(node.value) : MIR::Ident.new(node.name)
      end
      pipeline_host.define_singleton_method(:visit_pipeline_body_mir) do |_body, placeholder:|
        [MIR::ExprStmt.new(MIR::Ident.new("body_for_#{placeholder}"), nil)]
      end

      smooth = typed(AST::BinaryOp.new(tok, range, :SMOOTH, conc), Type.new(:Void))
      lowerer = pipeline_host.instance_variable_get(:@concurrent_lowerer)
      result = lowerer.send(:lower_shard_concurrent_each, range, conc, smooth)

      expect(result).to be_a(MIR::ForStmt)
      expect(result.capture).to match(/__sh\d+_i/)
      expect(result.body.first).to be_a(MIR::Let)
      expect(result.body.last.expr.name).to match(/body_for___sh\d+_key/)
    ensure
      lowering.instance_variable_set(:@target, nil)
    end

    it "wraps explicit concurrent scalar options as structural MIR" do
      batch = lit(8)
      workers = lit(4)
      capacity = id("cap")
      size = id("large")
      conc = AST::ConcurrentOp.new(tok, nil, {
        "batch" => batch,
        "workers" => workers,
        "capacity" => capacity,
        "size" => size,
      })
      pipeline_host.define_singleton_method(:visit_mir) { |node| MIR::Lit.new(node.value.to_s) }

      lowerer = pipeline_host.instance_variable_get(:@concurrent_lowerer)
      batch_mir = lowerer.send(:bounded_concurrent_batch_mir, conc)
      workers_mir = lowerer.send(:bounded_concurrent_worker_count_for_call_mir, conc)
      capacity_mir = lowerer.send(:stream_concurrent_capacity_mir, conc, "n_workers")
      task_cfg_mir = lowerer.send(:bounded_concurrent_task_cfg_mir, conc)

      expect(batch_mir).to be_a(MIR::Cast)
      expect(MIREmitter.new.emit(batch_mir)).to eq("@intCast(8)")
      expect(workers_mir).to be_a(MIR::Cast)
      expect(MIREmitter.new.emit(workers_mir)).to eq("@intCast(4)")
      expect(capacity_mir).to be_a(MIR::Cast)
      expect(MIREmitter.new.emit(capacity_mir)).to eq("@intCast(cap)")
      expect(task_cfg_mir).to be_a(MIR::StructInit)
      expect(MIREmitter.new.emit(task_cfg_mir)).to eq(".{ .stack_size = .Large }")
    end

    it "delegates PipelineHost concurrent lowering to the concurrent lowerer" do
      conc = AST::ConcurrentOp.new(tok, AST::EachOp.new(tok, []), {})
      smooth = typed(AST::BinaryOp.new(tok, id("items", type: Type.new(:"Int64[]")), :SMOOTH, conc), Type.new(:Void))
      calls = []
      fake = Object.new
      fake.define_singleton_method(:lower) do |smooth_node, concurrent_op|
        calls << [smooth_node, concurrent_op]
        MIR::ScopeBlock.new([])
      end
      pipeline_host.instance_variable_set(:@concurrent_lowerer, fake)

      result = pipeline_host.send(:lower_concurrent,
        PipelineHost::PipelineSite.new(list: smooth.left, options: smooth), conc)

      expect(result).to be_a(MIR::ScopeBlock)
      expect(calls).to eq([[smooth, conc]])
    end

    it "builds observable reduce publish as a structural MIR block" do
      reduce = AST::ReduceOp.new(tok, lit(0), AST::BinaryOp.new(tok, id("acc"), :ADD, id("_")))
      smooth = typed(AST::BinaryOp.new(tok, id("source"), :SMOOTH, reduce), Type.new(:Int64))

      pipeline_host.define_singleton_method(:transpile_type) { |_type| "i64" }
      pipeline_host.define_singleton_method(:visit_mir) do |node|
        node.equal?(reduce.initial_value) ? MIR::Lit.new("0") : MIR::BinOp.new("+", MIR::Ident.new("__obs_reduce_curr_0"), MIR::Ident.new("__item"))
      end
      lowering.define_singleton_method(:emit_expr) { |node| MIREmitter.new.emit(node) }

      result = pipeline_host.send(:lower_range_reduce_observable,
        lazy_range_prefix(item_var: "__item", source_name: "source"), reduce, smooth, "__obs_label", id("source"))

      expect(result).to be_a(MIR::BlockExpr)
      expect(result.body).to include(a_kind_of(MIR::AllocMark), a_kind_of(MIR::Let), a_kind_of(MIR::BreakStmt))
      spawn = result.body.find { |stmt| stmt.is_a?(MIR::ExprStmt) && stmt.expr.is_a?(MIR::ZigTemplate) }
      expect(spawn).not_to be_nil
      zig = spawn.expr.code
      expect(zig).to include("ctx.acc.inner.view()")
      expect(zig).to include("ctx.acc.inner.tryCommit(__obs_reduce_curr_0, __obs_reduce_next_0)")
      expect(zig).to include("ctx.acc.inner.markSeen()")
      expect(zig).to include("break :__obs_reduce_blk_0 @as(i32, 0);")
    end

    it "threads typed lazy range prefixes through observable fold helpers" do
      stub_pipeline_host_mir_visitors(pipeline_host)
      lowering.define_singleton_method(:emit_expr) { |node| MIREmitter.new.emit(node) }
      lookup = empty_schema_lookup
      lowering.define_singleton_method(:mir_schema_lookup) { lookup }
      source = id("source", type: Type.new(:"~Int64[]"))
      prefix = lazy_range_prefix(source_name: "source", item_var: "__item")
      count = AST::CountOp.new(tok, id("_"))
      count_smooth = typed(AST::BinaryOp.new(tok, source, :SMOOTH, count), Type.new(:Int64))

      scaffold = pipeline_host.send(:lower_range_fold_observable, prefix, count_smooth, "__obs_label", source,
        acc_alloc_expr: MIR::Ident.new("acc_alloc"),
        publish_stmts: [MIR::Suppress.new("__item")])

      default_result = pipeline_host.send(:lower_range_fold_observable_default,
        prefix, count, count_smooth, "__obs_default", source, terminal: :count)

      distinct = AST::DistinctOp.new(tok, id("_"))
      distinct_smooth = typed(AST::BinaryOp.new(tok, source, :SMOOTH, distinct),
        Type.new(:"~Int64[]", collection: :set, observable: true, observable_terminal: :distinct))
      distinct_result = pipeline_host.send(:lower_range_fold_observable_distinct,
        prefix, distinct, distinct_smooth, "__obs_distinct", source)

      range_lowerer = pipeline_host.instance_variable_get(:@range_lowerer)
      expect(range_lowerer.send(:range_literal_element_type,
        typed(AST::RangeLit.new(tok, lit(0), lit(2), false), Type.new(:"~Int64[]")))).to eq(Type.new(:Int64))

      avg = AST::AverageOp.new(tok, id("_"))
      avg_smooth = typed(AST::BinaryOp.new(tok, source, :SMOOTH, avg), Type.new(:Float64))
      avg_result = pipeline_host.send(:lower_range_fold_observable_default,
        prefix, avg, avg_smooth, "__obs_avg", source, terminal: :avg)

      any_op = AST::AnyOp.new(tok, id("_", type: Type.new(:Bool)))
      any_smooth = typed(AST::BinaryOp.new(tok, source, :SMOOTH, any_op), Type.new(:Bool))
      any_result = pipeline_host.send(:lower_range_fold_observable_default,
        prefix, any_op, any_smooth, "__obs_any", source, terminal: :any)

      owned_source = id("names", type: Type.new(:"~String[]"))
      owned_prefix = lazy_range_prefix(source_name: "names", item_var: "__name", elem_zig: "[]const u8")
      find = AST::FindOp.new(tok, id("_", type: Type.new(:Bool)))
      find_smooth = typed(AST::BinaryOp.new(tok, owned_source, :SMOOTH, find), Type.optional_of(:String))
      find_result = pipeline_host.send(:lower_range_fold_observable_default,
        owned_prefix, find, find_smooth, "__obs_find", owned_source, terminal: :find)

      bounded_distinct_smooth = typed(AST::BinaryOp.new(tok, source, :SMOOTH, distinct),
        Type.new(:"~Int64[4]", collection: :set, observable: true, observable_terminal: :distinct))
      bounded_distinct_result = pipeline_host.send(:lower_range_fold_observable_distinct,
        prefix, distinct, bounded_distinct_smooth, "__obs_distinct_bounded", source)

      expect(scaffold.body).to include(a_kind_of(MIR::ExprStmt))
      expect(default_result).to be_a(MIR::BlockExpr)
      expect(distinct_result).to be_a(MIR::BlockExpr)
      expect(avg_result).to be_a(MIR::BlockExpr)
      expect(any_result).to be_a(MIR::BlockExpr)
      expect(find_result).to be_a(MIR::BlockExpr)
      expect(bounded_distinct_result).to be_a(MIR::BlockExpr)
      [scaffold, default_result, distinct_result, avg_result, any_result, find_result, bounded_distinct_result].each do |block|
        spawn = block.body.find { |stmt| stmt.is_a?(MIR::ExprStmt) && stmt.expr.is_a?(MIR::ZigTemplate) }
        expect(spawn).not_to be_nil
        expect(spawn.expr.code).to include(".gen = ")
      end

      stub_const("PipelineRangeLowerer::PUBLISH_SPEC", {
        count: PipelinePublishSpec.new(
          publish_method: "inc",
          expr: :invalid,
          gate: :always,
          transfers_item_on_success: false,
        )
      })
      expect {
        pipeline_host.send(:lower_range_fold_observable_default,
          prefix, count, count_smooth, "__obs_bad_expr", source, terminal: :count)
      }.to raise_error(/unsupported observable publish expr invalid/)

      stub_const("PipelineRangeLowerer::PUBLISH_SPEC", {
        count: PipelinePublishSpec.new(
          publish_method: "inc",
          expr: :none,
          gate: :invalid,
          transfers_item_on_success: false,
        )
      })
      expect {
        pipeline_host.send(:lower_range_fold_observable_default,
          prefix, count, count_smooth, "__obs_bad_gate", source, terminal: :count)
      }.to raise_error(/unsupported observable publish gate invalid/)
    end

    it "builds concurrent reduce min/max seeds structurally" do
      lhs = id("items", type: Type.new(:"Int64[]"))
      captured_args = []
      lowering.define_singleton_method(:emit_builtin) do |name, args|
        captured_args << args
        MIR::Call.new(name.to_s, [], false, false, MIR::CallableContract.no_ownership(0))
      end
      lowerer = pipeline_host.instance_variable_get(:@concurrent_lowerer)

      min = AST::MinOp.new(tok, id("_"))
      min_smooth = typed(AST::BinaryOp.new(tok, lhs, :SMOOTH, min), Type.new(:Int64))
      min_conc = typed(AST::ConcurrentOp.new(tok, min, {}), Type.new(:Int64))
      lowerer.send(:lower_concurrent_list_reduce, lhs, min_conc, min, min_smooth)

      max = AST::MaxOp.new(tok, id("_"))
      max_smooth = typed(AST::BinaryOp.new(tok, lhs, :SMOOTH, max), Type.new(:Int64))
      max_conc = typed(AST::ConcurrentOp.new(tok, max, {}), Type.new(:Int64))
      lowerer.send(:lower_concurrent_list_reduce, lhs, max_conc, max, max_smooth)

      unsigned_max_smooth = typed(AST::BinaryOp.new(tok, lhs, :SMOOTH, max), Type.new(:UInt64))
      unsigned_conc = typed(AST::ConcurrentOp.new(tok, max, {}), Type.new(:UInt64))
      lowerer.send(:lower_concurrent_list_reduce, lhs, unsigned_conc, max, unsigned_max_smooth)

      expect(captured_args[0][-2]).to eq(MIR::TypeSentinel.new(:max, "i64"))
      expect(captured_args[0][-1]).to eq(MIR::Ident.new(".min"))
      expect(captured_args[1][-2]).to eq(MIR::TypeSentinel.new(:min, "i64"))
      expect(captured_args[1][-1]).to eq(MIR::Ident.new(".max"))
      expect(captured_args[2][-2]).to eq(MIR::Lit.new("0"))
    end

    it "stamps boxed capture fields for pointer bounded callbacks" do
      counter_type = Type.new(:Counter, sync: :locked)
      sym = SymbolEntry.new(reg: "c", type: counter_type, mutable: true, storage: :heap, sync: :locked)
      analysis = OpenStruct.new(
        has_local: false,
        has_rc: false,
        has_shared: false,
        has_sharded: false,
        has_affine_locked: false,
        has_outer_ref: false,
        has_non_escaping_capture: false,
        captures: { "c" => counter_type },
        capture_symbols: { "c" => sym },
        close_patterns: {},
        pointer_captures: Set.new,
        string_captures: Set.new,
        resource_captures: Set["c"],
        site_moved: Set.new,
        site_copied: Set.new,
        strategies: {},
        move_mark_names: Set.new,
        alloc_mark_entries: {}
      )
      conc = AST::ConcurrentOp.new(tok, AST::EachOp.new(tok, []), {})
      conc.capture_analysis = analysis
      pipeline_host.define_singleton_method(:visit_pipeline_body_mir) do |_body, placeholder:|
        [MIR::Suppress.new(placeholder)]
      end

      lowerer = pipeline_host.instance_variable_get(:@concurrent_lowerer)
      callback = lowerer.send(:build_bounded_concurrent_callback_pointer, conc, Type.new(:Int64))

      field = callback.ctx_def.fields.first
      expect(field.name).to eq("c")
      expect(field.boxed_capture).to eq("Counter")
    end

    it "lowers bytecode identifier streams through for-loops for distinct and reduce terminals" do
      lowering.instance_variable_set(:@target, :bc)
      stream = id("events", type: Type.new(:"~Int64[]"))
      distinct = AST::DistinctOp.new(tok, id("_"))
      smooth = AST::BinaryOp.new(tok, stream, :SMOOTH, distinct)
      typed(smooth, Type.new(:"Int64[]", collection: :set))
      site = PipelineHost::PipelineSite.new(list: stream, options: smooth)

      distinct_mir = pipeline_host.send(:lower_distinct, site, distinct)

      reduce = AST::ReduceOp.new(tok, lit(0), id("_"))
      typed(reduce, Type.new(:Int64))
      reduce_mir = pipeline_host.send(:lower_range_reduce, stream, [], reduce)

      expect(distinct_mir.body).to include(a_kind_of(MIR::ForStmt))
      expect(reduce_mir.body).to include(a_kind_of(MIR::ForStmt))
    ensure
      lowering.instance_variable_set(:@target, nil)
    end
  end
end
