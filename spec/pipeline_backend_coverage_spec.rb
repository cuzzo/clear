require "rspec"
require "ostruct"
require_relative "../src/ast/ast"
require_relative "../src/ast/lexer"
require_relative "../src/ast/symbol_entry"
require_relative "../src/ast/type"
require_relative "../src/backends/pipeline_generator"
require_relative "../src/backends/pipeline_host"
require_relative "../src/mir/mir"
require_relative "../src/mir/mir_emitter"

class PipelineBackendCoverageHost
  include PipelineGenerator

  attr_accessor :named_bindings

  def initialize
    @named_bindings = {}
    @soa_rewrite_active = false
    @soa_needed_fields = Set.new
  end

  def visit(node)
    case node
    when AST::Identifier then node.name.to_s
    when AST::Literal then node.value.inspect
    when AST::BinaryOp then "(#{visit(node.left)} #{node.op} #{visit(node.right)})"
    when AST::GetField then "#{visit(node.target)}.#{node.field}"
    when AST::FuncCall then "#{node.name}(#{node.args.map { |a| visit(a) }.join(', ')})"
    else node.respond_to?(:name) ? node.name.to_s : "expr"
    end
  end

  def transpile_type(type)
    case type.to_s
    when "Int64" then "i64"
    when "Float64" then "f64"
    when "Bool", "Boolean" then "bool"
    else type.to_s
    end
  end

  def with_named_binding(clear_name, zig_var)
    prev = @named_bindings[clear_name]
    @named_bindings[clear_name] = zig_var
    yield
  ensure
    prev.nil? ? @named_bindings.delete(clear_name) : @named_bindings[clear_name] = prev
  end

  def with_fiber_capture_map(_entries)
    yield
  end
end

RSpec.describe "pipeline backend coverage" do
  let(:tok) { Lexer::Token.new(:VAR_ID, "x", 1, 1) }
  let(:host) { PipelineBackendCoverageHost.new }

  def elem(resolved = :Int64, zig = "i64")
    OpenStruct.new(resolved: resolved, zig_type: zig)
  end

  def ptype(**opts)
    defaults = {
      pool?: false, sharded?: false, soa?: false, list_collection?: false,
      fixed_soa?: false, set_collection?: false, dynamic_stream?: false,
      open_stream?: false, inf_stream?: false, bounded_stream?: false,
      shard_count: 4, element_type: elem,
      stream_element_type: elem, open_stream_element_type: elem,
      inf_stream_element_type: elem, tense_type: OpenStruct.new(element_type: elem)
    }
    OpenStruct.new(defaults.merge(opts))
  end

  def id(name, type: Type.new(:Int64))
    node = AST::Identifier.new(tok, name)
    node.full_type = type
    node
  end

  def lit(value, type = :Int64)
    node = AST::Literal.new(tok, :NUMBER, value, nil)
    node.full_type = type
    node
  end

  def typed(node, type = Type.new(:Int64))
    node.full_type = type
    node
  end

  describe PipelineGenerator do
    it "restores full pipeline context including explicit SOA mode" do
      host.instance_variable_set(:@placeholder_name, "outer")
      host.instance_variable_set(:@acc_placeholder, "outer_acc")
      host.instance_variable_set(:@soa_rewrite_active, false)
      host.instance_variable_set(:@soa_needed_fields, Set[:old])

      result = host.with_pipeline_context(placeholder: "inner", acc: "acc", soa: true) do
        expect(host.instance_variable_get(:@placeholder_name)).to eq("inner")
        expect(host.instance_variable_get(:@acc_placeholder)).to eq("acc")
        expect(host.instance_variable_get(:@soa_rewrite_active)).to be true
        host.instance_variable_get(:@soa_needed_fields) << :field
        "ok"
      end

      expect(result).to eq("ok")
      expect(host.instance_variable_get(:@placeholder_name)).to eq("outer")
      expect(host.instance_variable_get(:@acc_placeholder)).to eq("outer_acc")
      expect(host.instance_variable_get(:@soa_rewrite_active)).to be false
      expect(host.instance_variable_get(:@soa_needed_fields)).to eq(Set[:old])
    end

    it "builds pipe item materializers for every collection layout branch" do
      expect(host.build_pipe_items_block(ptype(pool?: true, sharded?: true), "rt.frameAlloc()")).to include("shards[__psi].slots")
      expect(host.build_pipe_items_block(ptype(pool?: true, soa?: true), "rt.frameAlloc()")).to include("data.get(__psi)")
      expect(host.build_pipe_items_block(ptype(list_collection?: true, soa?: true), "rt.frameAlloc()")).to include("pipe_src_list.data.len")
      expect(host.build_pipe_items_block(ptype(pool?: true), "rt.frameAlloc()")).to include("pipe_src_list.slots")
      expect(host.build_pipe_items_block(ptype(list_collection?: true, sharded?: true), "rt.frameAlloc()")).to include("appendSlice")
      expect(host.build_pipe_items_block(ptype, "rt.frameAlloc()")).to include("pipe_src_list[0..]")
    end

    it "uses numeric sentinel values by result family" do
      expect(host.agg_minmax_sentinels("f64", :Float64)).to eq(["std.math.floatMax(f64)", "-std.math.floatMax(f64)"])
      expect(host.agg_minmax_sentinels("i64", :Int64)).to eq(["std.math.maxInt(i64)", "std.math.minInt(i64)"])
      expect(host.agg_minmax_sentinels("u64", :UInt64)).to eq(["std.math.maxInt(u64)", "0"])
      expect(host.agg_minmax_sentinels("Custom", :Custom)).to eq(["std.math.floatMax(f64)", "-std.math.floatMax(f64)"])
    end

  end

  describe PipelineHost do
    let(:lowering) do
      Class.new do
        attr_accessor :fn_sigs, :shard_context

        def initialize
          @fn_sigs = {}
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

      end.new
    end

    let(:pipeline_host) { PipelineHost.new(lowering: lowering, emitter: MIREmitter.new) }

    it "scopes optional named bindings" do
      expect(pipeline_host.with_optional_named_binding(nil, "__ignored") { pipeline_host.instance_variable_get(:@named_bindings).dup }).to eq({})
      result = pipeline_host.with_optional_named_binding("$u", "__pipe_u") do
        pipeline_host.send(:substitute_placeholders, id("$u")).name
      end
      expect(result).to eq("__pipe_u")
      expect(pipeline_host.instance_variable_get(:@named_bindings)).to eq({})
    end

    it "visits placeholders, join params, named bindings, SOA fields, and accumulators" do
      pipeline_host.instance_variable_set(:@placeholder_name, "__it")
      expect(pipeline_host.visit(id("_"))).to eq("__it")

      pipeline_host.instance_variable_set(:@join_param_map, { "left" => "__jl" })
      expect(pipeline_host.visit(id("left"))).to eq("__jl")

      pipeline_host.instance_variable_set(:@named_bindings, { "$u" => "__pipe_u" })
      expect(pipeline_host.visit(id("$u"))).to eq("__pipe_u")

      pipeline_host.instance_variable_set(:@soa_rewrite_active, true)
      expect(pipeline_host.visit(AST::GetField.new(tok, id("_"), :x))).to eq("__soa_x[__soa_i]")

      assign = AST::Assignment.new(tok, AST::GetField.new(tok, id("_"), :x), lit(1))
      expect(pipeline_host.visit(assign)).to include("__soa_x[__soa_i] =")

      pipeline_host.instance_variable_set(:@acc_placeholder, "__acc")
      expect(pipeline_host.visit(id("acc"))).to eq("__acc")
    end

    it "substitutes placeholders through common expression nodes" do
      pipeline_host.instance_variable_set(:@placeholder_name, "__it")
      pipeline_host.instance_variable_set(:@acc_placeholder, "__acc")
      pipeline_host.instance_variable_set(:@join_param_map, { "r" => "__jr" })
      pipeline_host.instance_variable_set(:@named_bindings, { "$u" => "__pipe_u" })

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

    it "substitutes assignment and bind targets plus SOA EACH fields" do
      pipeline_host.instance_variable_set(:@placeholder_name, "__it")
      pipeline_host.instance_variable_set(:@soa_each_mode, true)
      gf = typed(AST::GetField.new(tok, id("_"), :x))
      expect(pipeline_host.send(:substitute_placeholders, gf).name).to eq("__soa_x[__soa_i]")

      bind = typed(AST::BindExpr.new(tok, typed(AST::GetField.new(tok, id("_"), :x)), nil, id("_")))
      expect(pipeline_host.send(:substitute_placeholders, bind).name.name).to eq("__soa_x[__soa_i]")

      assign = typed(AST::Assignment.new(tok, typed(AST::GetField.new(tok, id("_"), :x)), id("_")))
      expect(pipeline_host.send(:substitute_placeholders, assign).name.name).to eq("__soa_x[__soa_i]")
    end

    it "does not skip SOA rewrite-active substitution when no placeholder is active" do
      pipeline_host.instance_variable_set(:@placeholder_name, nil)
      pipeline_host.instance_variable_set(:@soa_rewrite_active, true)

      rewritten = pipeline_host.send(:substitute_placeholders, typed(AST::GetField.new(tok, id("_"), :x)))

      expect(rewritten).to be_a(AST::GetIndex)
      expect(rewritten.target.name).to eq("__soa_x")
    end

    it "detects placeholder usage in nested statement trees" do
      stmt = AST::FuncCall.new(tok, "f", [AST::BinaryOp.new(tok, id("x"), :ADD, id("_"))])
      expect(pipeline_host.send(:ast_stmts_use_placeholder?, [stmt])).to be true
      expect(pipeline_host.send(:ast_stmts_use_placeholder?, [AST::FuncCall.new(tok, "f", [id("x")])])).to be false
    end

    it "lowers SHARD+CONCURRENT EACH to a sequential BC loop" do
      lowering.instance_variable_set(:@target, :bc)
      range = AST::RangeLit.new(tok, lit(0), lit(4), false)
      key_expr = id("_")
      map = id("counts")
      conc = AST::ConcurrentOp.new(tok, AST::EachOp.new(tok, [AST::FuncCall.new(tok, "touch", [id("_")])]), {})
      conc.shard_context = { auto_detected: true, key_expr: key_expr, map_var: map }

      pipeline_host.define_singleton_method(:visit_mir) do |node|
        node.is_a?(AST::Literal) ? MIR::Lit.new(node.value) : MIR::Ident.new(node.name)
      end
      pipeline_host.define_singleton_method(:visit_pipeline_body_mir) do |_body, placeholder:|
        [MIR::ExprStmt.new(MIR::Ident.new("body_for_#{placeholder}"), nil)]
      end

      result = pipeline_host.send(:lower_shard_concurrent_each, range, conc, OpenStruct.new)

      expect(result).to be_a(MIR::ForStmt)
      expect(result.capture).to match(/__sh\d+_i/)
      expect(result.body.first).to be_a(MIR::Let)
      expect(result.body.last.expr.name).to match(/body_for___sh\d+_key/)
    ensure
      lowering.instance_variable_set(:@target, nil)
    end

    it "wraps explicit concurrent batch options for Zig usize use" do
      batch = lit(8)
      conc = OpenStruct.new(options: { "batch" => batch })
      pipeline_host.define_singleton_method(:visit_mir) { |node| MIR::Lit.new(node.value) }
      lowering.define_singleton_method(:emit_expr) { |node| node.respond_to?(:value) ? node.value.to_s : node.name.to_s }

      mir = pipeline_host.send(:bounded_concurrent_batch_mir, conc)

      expect(mir).to be_a(MIR::InlineZig)
      expect(mir.code).to eq("@intCast(8)")
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

      callback = pipeline_host.send(:build_bounded_concurrent_callback_pointer, conc, Type.new(:Int64))

      field = callback[:ctx_def].fields.first
      expect(field.name).to eq("c")
      expect(field.boxed_capture).to eq("Counter")
    end
  end
end
