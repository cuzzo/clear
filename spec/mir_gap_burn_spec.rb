require "rspec"
require "set"
require_relative "../src/ast/ast"
require_relative "../src/ast/lexer"
require_relative "../src/ast/type"
require_relative "../src/ast/symbol_entry"
require_relative "../src/mir/control_flow"
require_relative "../src/mir/mir"
require_relative "../src/backends/importer"
require_relative "../src/semantic/concurrency_checks"
require_relative "../src/mir/mir_lowering"
require_relative "../src/semantic/escape_analysis"
require_relative "../src/mir/fiber_ctx_builder"

RSpec.describe "MIR gap-burn characterization" do
  let(:tok) { Lexer::Token.new(:VAR_ID, "x", 1, 1) }

  it "does not clean up borrowed capture values" do
    borrowed = Type.new(:String)
    borrowed.mark_borrowed_reference!

    expect(FiberCtxBuilder.needs_capture_value_cleanup?(borrowed)).to be(false)
  end

  def fn(body, params: [], return_type: :Void)
    AST::FunctionDef.new(tok, "main", params, [], return_type, nil, body, [], nil, :private, [], false)
  end

  def id(name, type: :String, storage: :frame)
    node = AST::Identifier.new(tok, name)
    node.full_type = type
    node.symbol = SymbolEntry.new(reg: name, type: type, mutable: false, storage: storage)
    node
  end

  def lit(value = "x", type: :String)
    node = AST::Literal.new(tok, type == :String ? :STRING : :NUMBER, value, nil)
    node.full_type = type
    node
  end

  def param(name, type: :String, takes: false)
    p = AST::Param.new(name: name, type: type, default: nil, mutable: false, takes: takes, comptime: false,
      name_token: tok, required: nil, sync: nil)
    p.takes = takes
    p.symbol = SymbolEntry.new(reg: name, type: type, mutable: false, storage: :heap)
    p.symbol.is_param = true
    p.symbol.takes = takes
    p
  end

  def owner_state(*names)
    names.to_h do |name|
      [name, OwnershipDataflow::OwnerEntry.new(state: OwnershipDataflow::OWNED, allocator: :heap, needs_cleanup: true)]
    end
  end

  def lowering
    MIRLowering.new
  end

  def ownership_finalization_context(out: [], guarded_cleanup_names: Set.new, alloc_marks: {}, body_alloc_mark_names: Set.new)
    MIRLowering::OwnershipFinalizationContext.new(
      inherited_alloc_names: Set.new,
      out: out,
      guarded_cleanup_names: guarded_cleanup_names,
      alloc_marks: alloc_marks,
      body_alloc_mark_names: body_alloc_mark_names,
      transfer_mark_names: Set.new,
      body_transfer_mark_names: Set.new,
      move_mark_names: out.filter_map { |node| node.name.to_s if node.is_a?(MIR::MoveMark) }.to_set,
      cleanup_by_name: {},
    )
  end

  it "builds CFG edges for every structured body form in one pass" do
    one = lit(1, type: :Int64)
    if_stmt = AST::IfStatement.new(tok, one, [AST::BreakNode.new(tok)], [AST::ContinueNode.new(tok)], nil, nil)
    while_stmt = AST::WhileLoop.new(tok, one, [AST::BreakNode.new(tok)], nil)
    range_stmt = AST::ForRange.new(tok, "i", one, one, false, [AST::ContinueNode.new(tok)], nil, nil)
    each_stmt = AST::ForEach.new(tok, "v", id("items"), [AST::BreakNode.new(tok)], nil, false)
    match_case = AST::MatchCase.new(kind: :literal, value: one, body: [AST::BreakNode.new(tok)])
    match_stmt = AST::MatchStatement.new(tok, id("tag", type: :Int64), [match_case], [AST::ContinueNode.new(tok)], nil, nil, false, false)
    with_stmt = AST::WithBlock.new(tok, [], [AST::BreakNode.new(tok)], nil)
    do_stmt = AST::DoBlock.new(tok, [{ body: [AST::BreakNode.new(tok)], pinned: false, stack_size: nil }])
    bg_stmt = AST::BgBlock.new(tok, [AST::ReturnNode.new(tok, nil)], nil, nil, false, false, nil, false)
    call = AST::FuncCall.new(tok, "fails", [])

    graph = FunctionCFG.build(fn([if_stmt, while_stmt, range_stmt, each_stmt, match_stmt, with_stmt, do_stmt, bg_stmt, call, AST::Raise.new(tok, :System, nil, nil)]),
      can_fail_fns: Set["fails"])

    expect(graph.blocks.length).to be > 12
    expect(graph.entry.successors).not_to be_empty
    expect(graph.exit_block.predecessors).not_to be_empty
  end

  it "summarizes cleanup decision facts in one body traversal" do
    subject = id("payload")
    takes_match = AST::MatchStatement.new(
      tok, subject,
      [AST::MatchCase.new(kind: :literal, value: lit(1, type: :Int64), body: [])],
      nil, nil, nil, false, true
    )
    borrowed_match = AST::MatchStatement.new(
      tok, id("borrowed"),
      [AST::MatchCase.new(kind: :literal, value: lit(2, type: :Int64), body: [])],
      nil, nil, nil, false, false
    )
    non_identifier_match = AST::MatchStatement.new(
      tok, AST::StructLit.new(tok, "Box", [], nil),
      [AST::MatchCase.new(kind: :literal, value: lit(3, type: :Int64), body: [])],
      nil, nil, nil, false, true
    )
    loop_decl = AST::VarDecl.new(tok, "inside_loop", nil, lit(1, type: :Int64), false)
    outside_decl = AST::VarDecl.new(tok, "outside_loop", nil, lit(1, type: :Int64), false)
    loop = AST::WhileLoop.new(tok, lit(true, type: :Bool), [loop_decl], nil)
    fn_node = fn([takes_match, borrowed_match, non_identifier_match, outside_decl, loop])
    dataflow = OwnershipDataflow.new(FunctionCFG.build(fn_node), fn_node)

    facts = dataflow.send(:cleanup_decision_facts, fn_node.body)

    expect(facts.match_takes_vars).to eq(Set["payload"])
    expect(facts.loop_declared_names).to eq(Set["inside_loop"])
  end

  it "detects linear moves inside nested lexical bodies" do
    dataflow = OwnershipDataflow.new(FunctionCFG.build(fn([])), fn([]), schema_lookup: nil)
    decl = AST::VarDecl.new(tok, "owned", nil, id("source", storage: :heap), false)
    moved = AST::MoveNode.new(tok, id("owned", storage: :heap))
    nested = AST::IfStatement.new(tok, lit(true, type: :Bool), [decl, moved], nil, nil, nil)

    expect(dataflow.send(:linear_scope_decl_always_moves?, [nested], "owned")).to eq(true)
  end

  it "tracks ownership transfers for statement categories through one dataflow object" do
    value = id("owned")
    moved_value = id("moved", storage: :heap)
    moved_value.was_moved = true
    call = AST::FuncCall.new(tok, "consume", [moved_value])
    bg = AST::BgBlock.new(tok, [], nil, nil, false, false, nil, false)
    bg.capture_analysis = double(resource_captures: Set["captured"], move_mark_names: Set["given"])
    each_stmt = AST::ForEach.new(tok, "loop_item", id("items"), [], nil, false)
    each_stmt.full_type = Type.new(:Box, layout: :indirect)

    dataflow = OwnershipDataflow.new(FunctionCFG.build(fn([])), fn([]), schema_lookup: nil)
    state = owner_state("owned", "moved", "captured", "given", "items")

    decl = AST::VarDecl.new(tok, "declared", nil, value, false)
    decl.full_type = Type.new(:Box, layout: :indirect)
    dataflow.send(:transfer_stmt, decl, state)
    dataflow.send(:transfer_stmt, AST::Assignment.new(tok, id("slot"), AST::MoveNode.new(tok, id("owned"))), state)
    dataflow.send(:transfer_stmt, call, state)
    dataflow.send(:transfer_stmt, each_stmt, state)
    dataflow.send(:transfer_stmt, bg, state)

    expect(state["declared"].state).to eq(OwnershipDataflow::OWNED)
    expect(state["owned"].state).to eq(OwnershipDataflow::MOVED)
    expect(state["moved"].state).to eq(OwnershipDataflow::MOVED)
    expect(state["captured"].state).to eq(OwnershipDataflow::MOVED)
    expect(state["loop_item"].state).to eq(OwnershipDataflow::OWNED)
  end

  it "exercises escape return and call heap facts without source fuzz" do
    p = param("source", type: :String)
    ret_fn = fn([], params: [p], return_type: :String)
    escaped = id("local", type: :String, storage: :heap)
    expect(EscapeAnalysis.send(:owning_return_needs_heap_placement?, ret_fn, escaped, nil)).to eq(true)

    borrowed_fn = fn([], params: [p], return_type: :String)
    borrowed_fn.return_lifetime = [p]
    expect(EscapeAnalysis.send(:borrowed_return?, borrowed_fn, id("source", type: :String))).to eq(true)

    callee = fn([AST::ReturnNode.new(tok, id("made", type: :String))], return_type: :String)
    callee.heap_carry_return = true
    call = AST::FuncCall.new(tok, "callee", [])
    expect(EscapeAnalysis.send(:call_result_is_heap?, call, { "callee" => callee }, nil)).to eq(true)

    sig = FunctionSignature.new(params: [], return_type: Type.new(:String))
    sig.heap_carry_return = true
    foreign = AST::FuncCall.new(tok, "foreign", [])
    foreign.matched_signature = sig
    expect(EscapeAnalysis.send(:call_result_is_heap?, foreign, {}, nil)).to eq(true)
  end

  it "exercises lowering placement and sink plans directly" do
    low = lowering
    string_ast = lit("s", type: :String)
    or_ast = AST::BinaryOp.new(tok, lit("a", type: :String), :OR, lit("b", type: :String))
    or_ast.full_type = :String

    expect(low.destination_placement_plan(MIR::Ident.new("s"), string_ast, :heap, Type.new(:String)).action).to eq(:string)
    expect(low.destination_placement_plan(MIR::Cast.new(MIR::Ident.new("s"), "[]const u8", nil), or_ast, :heap, Type.new(:String)).action).to eq(:cast_wrapped_or)

    dupe = low.send(:materialize_owned_sink_value, MIR::Ident.new("s"), string_ast, :heap, Type.new(:String))
    expect(dupe).to be_a(MIR::DupeSlice)

    copy = AST::CopyNode.new(tok, string_ast)
    copied = low.send(:materialize_owned_sink_value, MIR::Ident.new("s"), copy, :heap, Type.new(:String))
    expect(copied).to be_a(MIR::Ident)
  end

  it "collects allocator facts from nested catch-body reassignments" do
    low = lowering
    heap_value = id("heap_value", storage: :heap)
    frame_value = id("frame_value", storage: :frame)
    ignored_value = lit("ro")

    bind_assign = AST::BindExpr.new(tok, "slot", nil, heap_value)
    bind_assign.mode = :assign
    ident_assign = AST::Assignment.new(tok, id("other"), frame_value)
    string_assign = AST::Assignment.new(tok, "not_a_target_identifier", heap_value)
    if_stmt = AST::IfStatement.new(tok, lit(1, type: :Int64), [bind_assign], [ident_assign], nil, nil)
    match_case = AST::MatchCase.new(kind: :literal, value: lit("E"), body: [string_assign])
    default_bind = AST::BindExpr.new(tok, "ignored", nil, ignored_value)
    default_bind.mode = :assign
    match_stmt = AST::MatchStatement.new(tok, id("tag"), [match_case], [default_bind], nil, nil, false, false)

    fun = fn([], return_type: :String)
    fun.catch_clauses = [AST::CatchClause.new(body: [if_stmt, match_stmt])]
    fun.default_catch = [AST::Assignment.new(tok, id("fallback"), heap_value)]

    facts = low.send(:collect_catch_reassigns, fun)

    expect(facts.map { |fact| [fact.name, fact.alloc] }).to contain_exactly(
      ["slot", :heap],
      ["other", :frame],
      ["fallback", :heap],
    )
  end

  it "covers lowering coercion and implicit allocation facts as typed facts" do
    low = lowering

    untyped = lit(1, type: :Int64)
    untyped.full_type = :Untyped
    untyped.coerced_type = :Float64
    expect(low.send(:apply_lowered_coercion, MIR::Ident.new("n"), untyped)).to be_a(MIR::Ident)

    fixed_stack = AST::ListLit.new(tok, [lit(1, type: :Int64)], :stack)
    fixed_stack.full_type = :"Int64[]"
    fixed_stack.coerced_type = :"Int64[3]"
    expect(low.send(:apply_lowered_coercion, MIR::Ident.new("xs"), fixed_stack)).to be_a(MIR::Ident)

    coerced = lit(1, type: :Int64)
    coerced.coerced_type = :Float64
    cast = low.send(:apply_lowered_coercion, MIR::Ident.new("n"), coerced)
    expect(cast).to be_a(MIR::Cast)

    same = lit(1, type: :Int64)
    same.coerced_type = :Int64
    expect(low.send(:apply_lowered_coercion, MIR::Ident.new("n"), same)).to be_a(MIR::Ident)

    plain = MIR::Let.new("tmp", MIR::DupeSlice.new(MIR::Ident.new("s"), :heap), false, Type.new("[]const u8"), nil)
    fact = low.send(:implicit_allocating_result_fact, plain, ownership_finalization_context)
    expect(fact.name).to eq("tmp")
    expect(fact.ownership_effect.target_var).to eq("tmp")

    wrapped_alloc = MIR::Let.new("wrapped", MIR::Cast.new(MIR::DupeSlice.new(MIR::Ident.new("s"), :heap), "[]const u8", nil), false, Type.new("[]const u8"), nil)
    expect(low.send(:implicit_allocating_result_fact, wrapped_alloc, ownership_finalization_context).ownership_effect.target_var).to eq("wrapped")

    marked = MIR::Let.new("marked", MIR::DupeSlice.new(MIR::Ident.new("s"), :heap), false, Type.new("[]const u8"), nil)
    mark = MIR::AllocMark.new("marked", :heap, Type.new(:String), :function)
    expect(low.send(:implicit_allocating_result_fact, marked,
      ownership_finalization_context(alloc_marks: { "marked" => mark }))).to be_nil
  end

  it "covers lowering ownership source predicates without lowering syntax" do
    low = lowering
    moved = id("moved", storage: :heap)
    moved.was_moved = true
    expect(low.send(:owner_transfer_node?, moved)).to eq(true)

    indirect_field = AST::GetField.new(tok, id("root", storage: :heap), "ptr")
    indirect_t = Type.new(:String)
    indirect_t.layout = :indirect
    indirect_field.full_type = indirect_t
    expect(low.send(:owner_transfer_node?, indirect_field)).to eq(true)

    source = lit("s", type: :String)
    direct = Type.new(:String)
    direct.layout = :indirect
    expect(low.destination_placement_plan(MIR::Ident.new("p"), source, :heap, direct).action).to eq(:heap_indirect)
    expect(low.destination_placement_plan(MIR::HeapCreate.new("[]const u8", MIR::Ident.new("s"), :heap), source, :heap, direct).action).not_to eq(:heap_indirect)

    shared = id("rc", type: :String, storage: :heap)
    rc_type = Type.new(:Payload)
    rc_type.ownership = :shared
    shared.full_type = rc_type
    expect(low.send(:rc_retain_needed?, shared)).to eq(true)

    atomic = id("atomic", type: :String, storage: :heap)
    atomic_type = Type.new(:String)
    atomic_type.ownership = :shared
    atomic_type.sync = :atomic
    atomic_type.layout = :indirect
    atomic.full_type = atomic_type
    expect(low.send(:rc_retain_needed?, atomic)).to eq(false)

    low.instance_variable_set(:@rc_unwrap_map, { "rc" => true })
    expect(low.send(:rc_retain_needed?, shared)).to eq(false)
  end

  it "covers simple MIR lowering dispatch arms and formatting facts" do
    low = lowering

    expect(low.lower(AST::DefaultLit.new(tok))).to be_a(MIR::Lit)
    expect(low.lower(AST::Copy.new(tok, lit(7, type: :Int64)))).to be_a(MIR::Lit)
    expect(low.lower(MIR::Return.new(tok, ["escaped"]))).to be_a(MIR::ReturnMark)
    expect(low.lower(AST::ThrowNode.new(tok, nil))).to be_a(MIR::ReturnStmt)
    expect(low.lower(AST::DieNode.new(tok, 2))).to be_a(MIR::ExprStmt)
    expect(low.lower(AST::ShareNode.new(tok, id("shared", storage: :heap)))).to be_a(MIR::CapWrap)
    expect(low.lower(AST::OrRaise.new(tok))).to be_a(MIR::Ident)
    expect(low.lower(AST::OrBreak.new(tok))).to be_a(MIR::BreakStmt)
    expect(low.lower(AST::OrPass.new(tok))).to be_a(MIR::Ident)
    expect(low.lower(AST::OrPrune.new(tok))).to be_a(MIR::Ident)
    expect(low.lower(AST::OrExit.new(tok, :Runtime, nil, nil))).to be_a(MIR::ScopeBlock)
    expect(low.lower(AST::AssertRaises.new(tok, :Runtime, nil, lit(1, type: :Int64)))).to be_a(MIR::InlineZig)
    expect { low.lower(AST::ThenChain.new(tok, [])) }.to raise_error(/ThenChain should be flattened/)
    expect(low.send(:ast_void_type?, Type.new(:Int64))).to eq(false)
    expect(low.send(:zig_format_for_type, Type.new(:String))).to eq("{s}")
    expect(low.send(:zig_format_for_type, Type.new(:"Byte[4]"))).to eq("{s}")
    expect(low.send(:zig_format_for_type, Type.new(:Int64))).to eq("{d}")
    expect(low.send(:zig_format_for_type, Type.new(:Bool))).to eq("{}")
    expect(low.send(:zig_format_for_type, Type.new(:Any))).to eq("{any}")
    expect(low.send(:callee_can_fail?, "")).to eq(true)
    expect(low.send(:callee_can_fail?, "missing")).to eq(true)

    prog = AST::Program.new(tok, [])
    MIRPassState::ORDER.take_while { |stage| stage != :mir_lowered }.each { |stage| MIRPassState.for!(prog).mark!(stage) }
    expect(low.lower(prog)).to be_a(MIR::Program)
  end

  it "covers top-ranked MIR helper branch variants without new source fixtures" do
    low = lowering

    same = lit(1, type: :Int64)
    same.coerced_type = :Int64
    expect(low.send(:apply_lowered_coercion, MIR::Ident.new("n"), same)).to be_a(MIR::Ident)

    guarded = CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: false)
    drop = MIR::Drop.new(tok, "unguarded")
    drop.cleanup_entry = guarded
    expect(low.lower(drop)).to be_a(MIR::Cleanup)

    expect(low.send(:symbol_storage_for_node, nil)).to be_nil
    expect(low.send(:placement_for_node, id("plain", storage: :heap))).to eq(:heap)
    expect(low.send(:resolve_alloc_sym, :frame)).to eq(:frame)
    expect(low.send(:resolve_alloc_sym, :unknown)).to eq(:heap)
    expect(low.send(:extract_root_var_name, id("root"))).to eq("root")

    nil_lowering = Class.new(MIRLowering) do
      def lower(_stmt) = nil
    end.new
    expect(nil_lowering.send(:lowered_stmt_packet, ownership_finalization_context, AST::PassStmt.new(tok))).to be_nil
    expect(low.send(:lower_body_with_break, [], "__label")).to eq([])
    expect(low.send(:emit_stmts_zig, [MIR::Noop.new("skip")])).to eq("")

    borrowed = MIR::OwnershipOperandFact.borrowed_access("b", Type.new(:String), "src", :frame)
    owned = MIR::OwnershipOperandFact.owned_binding("o", Type.new(:String), "src", :frame)
    non = MIR::OwnershipOperandFact.non_owning(Type.new(:String), "src")
    retargeted = low.send(:retarget_ownership_operands, [borrowed, owned, non], :heap)
    expect(retargeted[0].borrowed).to eq(true)
    expect(retargeted[0].target_alloc).to eq(:heap)
    expect(retargeted[1].name).to eq("o")
    expect(retargeted[1].target_alloc).to eq(:heap)
    expect(retargeted[2].name).to be_nil
  end

  it "covers owned sink materialization actions as a compact dispatch matrix" do
    low = lowering
    value = MIR::Ident.new("v")
    ast = id("v", type: :String, storage: :frame)

    expect(low.send(:materialize_owned_sink_value, value, nil, :heap)).to be(value)

    plans = [
      MIRLowering::OwnedSinkPlan.new(action: :deep_copy, target_alloc: :heap, zig_type: "[]const u8", copy_mode: :full_value, source_slice_view: true),
      MIRLowering::OwnedSinkPlan.new(action: :rc_retain, target_alloc: :heap, zig_type: "Payload", copy_mode: nil, rc_func: "arcRetain"),
      MIRLowering::OwnedSinkPlan.new(action: :dupe_union, target_alloc: :heap, zig_type: "Choice", copy_mode: nil),
      MIRLowering::OwnedSinkPlan.new(action: :unknown, target_alloc: :heap, zig_type: nil, copy_mode: nil),
    ]

    plans.each do |plan|
      singleton = Class.new(MIRLowering) do
        define_method(:owned_sink_plan) { |_value, _ast_node, _sink_alloc, _sink_type = nil| plan }
        def emit_builtin(name, args)
          MIR::InlineZig.new("#{name}(#{args.length})", "test")
        end
      end.new
      result = singleton.send(:materialize_owned_sink_value, value, ast, :heap, Type.new(:String))
      case plan.action
      when :deep_copy
        expect(result).to be_a(MIR::DeepCopy)
        expect(result.source).to be_a(MIR::ItemsAccess)
      when :rc_retain
        expect(result).to be_a(MIR::RcRetain)
      when :dupe_union
        expect(result).to be_a(MIR::InlineZig)
      else
        expect(result).to be(value)
      end
    end
  end

  it "covers remaining high-rank MIR lowering helper variants compactly" do
    low = lowering

    stdlib_alloc = double(emits_allocating?: true, heap_return_alloc?: true,
      fixed_return?: false, mutates_receiver?: true)
    mutating_alloc = MIR::InlineZig.new("append()", "test", MIR::OwnershipContract.empty,
      stdlib_alloc, { alloc: :heap })
    mutating_alloc.result_ownership_bearing = true
    expect(low.send(:implicit_allocating_result_fact,
      MIR::Let.new("receiver", mutating_alloc, false, Type.new(:String), nil), ownership_finalization_context)).to be_nil

    nested_alloc = Struct.new(:child) do
      include MIR::Expr
      def child_exprs = [child]
      def ownership_source_exprs = [child]
      def ownership_effect = MIR::OwnershipEffect.none
    end.new(MIR::DupeSlice.new(MIR::Ident.new("s"), :heap))
    nested_fact = low.send(:implicit_allocating_result_fact,
      MIR::Let.new("nested", nested_alloc, false, Type.new(:String), nil), ownership_finalization_context)
    expect(nested_fact.ownership_effect.target_var).to eq("nested")

    if_bind = MIR::IfBindStmt.new([
      { capture: nil, expr: MIR::Ident.new("a") },
      { capture: "b", expr: nil },
    ], [], nil)
    expect(low.send(:if_bind_ownership_fact_targets, if_bind)).to eq([])

    low.instance_variable_set(:@current_bindings, {})
    bg_missing_body = AST::BgBlock.new(tok, [id("other")], nil, nil, false, false, nil, false)
    bg_missing_body.capture_analysis = double(move_mark_names: Set["missing"])
    expect(low.send(:ownership_transfers_for_stmt, bg_missing_body, Set.new)).to eq([])

    bg_missing_entry = AST::BgBlock.new(tok, [id("given")], nil, nil, false, false, nil, false)
    bg_missing_entry.capture_analysis = double(move_mark_names: Set["given"])
    expect(low.send(:collect_bg_capture_transfer_roots, bg_missing_entry)).to eq([])
    low.instance_variable_set(:@current_bindings, { "given" => CleanupEntry.build(:uniform, alloc: :heap) })
    low.instance_variable_set(:@fn_name_rename_map, { "given" => "renamed_given" })
    expect(low.send(:ownership_transfers_for_stmt, bg_missing_entry, Set.new).first.name).to eq("renamed_given")
    missing_entry_low = Class.new(MIRLowering) do
      def collect_bg_capture_transfer_roots(_stmt) = ["missing_entry"]
    end.new
    missing_entry_low.instance_variable_set(:@current_bindings, {})
    expect(missing_entry_low.send(:ownership_transfers_for_stmt, bg_missing_entry, Set.new)).to eq([])

    empty_target_lowering = Class.new(MIRLowering) do
      def ownership_transfer_operands_for_node(_node, _existing = [])
        [MIRLowering::OwnershipTransferTarget.new(name: "", target: :owned_sink, target_alloc: :heap)]
      end
    end.new
    expect(empty_target_lowering.send(:ownership_transfers_for_node,
      MIR::ExprStmt.new(MIR::Ident.new("x"), false),
      ownership_finalization_context)).to eq([])

    low.instance_variable_set(:@current_bindings, nil)
    expect(low.send(:ownership_consumed_name_operands, ["hidden"], "src", :heap)).to eq([])
    visibility_low = lowering
    visibility_low.instance_variable_set(:@current_bindings, {})
    visibility_low.instance_variable_set(:@lowered_alloc_names, nil)
    expect(visibility_low.send(:owned_binding_visible?, "hidden")).to eq(false)

    prog = AST::Program.new(tok, [])
    MIRPassState::ORDER.take_while { |stage| stage != :mir_lowered }.each { |stage| MIRPassState.for!(prog).mark!(stage) }
    debug_program = low.send(:lower_program, prog, use_debug_allocator: true)
    expect(debug_program.items).to include(an_object_having_attributes(name: "USE_DEBUG_ALLOCATOR"))

    items = []
    low.send(:append_lowered_items!, MIRLowering::LoweredItemTarget.new(items: items, line: 7), nil)
    expect(items).to eq([])

    fn_sig = FunctionSignature.new(params: [], return_type: Type.new(:Void))
    expect(low.send(:mir_cast, MIR::Ident.new("fn"), Type.new(fn_sig), Type.new(:Any))).to be_a(MIR::Cast)
    expect(low.send(:mir_cast, MIR::Ident.new("err"), Type.new(:Int64), Type.new(:"!String"))).to be_a(MIR::Cast)
    expect(low.send(:ast_void_type?, nil)).to eq(true)
    expect(low.send(:implicit_allocating_result_fact, MIR::Ident.new("not_let"), ownership_finalization_context)).to be_nil
    borrowed_field = AST::GetField.new(tok, id("owner", type: :String, storage: :heap), "field")
    borrowed_field.full_type = Type.new(:String)
    expect(low.send(:return_destination_alloc, AST::ReturnNode.new(tok, borrowed_field))).to eq(:heap)

    generic_field = AST::StructField.new(type: :Int64, default: lit(1, type: :Int64))
    generic_struct = AST::StructDef.new(tok, "Box", { value: generic_field }, :pub, ["T"])
    expect(low.lower(generic_struct)).to be_a(MIR::FnDef)

    inline_variant = Schemas::InlineStructVariant.new(fields: { value: :String })
    generic_union = AST::UnionDef.new(tok, "Choice", { Item: inline_variant }, :pub)
    generic_union.type_params = ["T"]
    expect(low.lower(generic_union)).to all(satisfy { |node| node.is_a?(MIR::StructDef) || node.is_a?(MIR::FnDef) })

    expect(low.send(:lower_direct_length, AST::FuncCall.new(tok, "len", []))).to be_nil
    missing_ast_mod = ModuleImporter::CompiledModule.new(nil, nil, nil, nil, nil, nil, nil, "const Hidden = struct {};", nil)
    expect(low.send(:visible_type_defs, missing_ast_mod)).to be_nil
    ptr_type = Type.new(:Payload)
    ptr_type.layout = :indirect
    expect(low.send(:bare_zig_type, ptr_type)).not_to start_with("*")

    rc_type = Type.new(:Payload)
    rc_type.ownership = :shared
    rc_ast = id("rc_value", type: rc_type, storage: :frame)
    expect(low.send(:owned_sink_plan, MIR::Ident.new("rc_value"), rc_ast, :heap, rc_type).action).to eq(:rc_retain)
    multi_type = Type.new(:Payload)
    multi_type.ownership = :multiowned
    multi_ast = id("multi_value", type: multi_type, storage: :frame)
    expect(low.send(:owned_sink_plan, MIR::Ident.new("multi_value"), multi_ast, :heap, multi_type).rc_func).to eq("rcRetain")

    borrowed_union_low = Class.new(MIRLowering) do
      def owned_sink_source_fact(_value, _ast_node, _sink_alloc, _ti)
        MIRLowering::OwnedSinkSourceFact.new(
          source_alloc: nil,
          moved_without_copy: false,
          owned_parameter: false,
          needs_heap_create: false,
          same_alloc_verifiable: false,
          same_alloc_transfer_source: false,
          transfer_without_local_cleanup: false,
          already_owned_value: false,
          existing_owned_source: false,
          borrowed_union_sink: true,
        )
      end
    end.new
    expect(borrowed_union_low.send(:owned_sink_plan, MIR::Ident.new("borrowed_union"), id("borrowed_union", type: :Int64), :heap, Type.new(:Int64)).action).to eq(:dupe_union)
  end

  it "covers hardened MIR hoist helper fallbacks directly" do
    low = lowering

    expect(MIRHoistFacts.container_borrow_expr?(nil)).to eq(false)
    borrow_left = id("borrowed_left", storage: :heap)
    borrow_left.container_borrow = true
    expect(MIRHoistFacts.container_borrow_expr?(AST::BinaryOp.new(tok, borrow_left, :OR, lit("fallback")))).to eq(true)
    expect(low.send(:mir_allocates?, Object.new)).to eq(false)
    expect(low.send(:hoist_alloc, MIR::Ident.new("plain"), nil)).to be_a(MIR::Ident)
    passthrough = Object.new
    expect(low.send(:hoist_alloc, passthrough, nil)).to be(passthrough)

    pipeline_ast = lit("pipeline", type: :String)
    typed_pipeline = MIR::Pipeline.new(pipeline_ast, nil, nil, [], nil, nil)
    expect(low.send(:mir_alloc_mark_type_info, typed_pipeline).resolved).to eq(:String)

    inner_pipeline = MIR::Pipeline.new(nil, MIR::DupeSlice.new(MIR::Ident.new("s"), :heap), nil, [], nil, nil)
    expect(low.send(:mir_alloc_mark_type_info, inner_pipeline).resolved).to eq(:String)

    untyped_pipeline = MIR::Pipeline.new(nil, MIR::Ident.new("s"), nil, [], nil, nil)
    expect { low.send(:mir_alloc_mark_type_info, untyped_pipeline) }.to raise_error(/Pipeline has no typed result/)

    owned_stmt = MIR::ExprStmt.new(MIR::DupeSlice.new(MIR::Ident.new("s"), :heap), false)
    expect(low.send(:normalize_allocating_mir_stmt!, owned_stmt)).not_to be_empty
    expect(low.send(:normalize_stmt_child_exprs!, Object.new)).to eq([])
    expect(low.send(:normalize_stmt_child_exprs!, MIR::ExprStmt.new(MIR::Ident.new("plain"), false))).to eq([])

    old_child = MIR::Ident.new("old")
    new_child = MIR::Ident.new("new")
    array_parent = MIR::ArrayInit.new("i64", nil, [[old_child]])
    low.send(:replace_mir_expr_child!, array_parent, old_child, new_child)
    expect(array_parent.items.first.first).to be(new_child)

    hash_parent = MIR::StructInit.new("Box", { nested: { value: old_child } })
    low.send(:replace_mir_expr_child!, hash_parent, old_child, new_child)
    expect(hash_parent.fields[:nested][:value]).to be(new_child)

    expect(low.send(:replace_mir_expr_in_value!, [MIR::Ident.new("other")], old_child, new_child)).to eq(false)
    expect(low.send(:replace_mir_expr_in_value!, { nested: [MIR::Ident.new("other")] }, old_child, new_child)).to eq(false)
    expect(low.send(:replace_mir_expr_in_value!, { nested: [old_child] }, old_child, new_child)).to eq(true)

    mixed_parent = MIR::StructInit.new("Box", { misses: [MIR::Ident.new("other")], hit: old_child })
    low.send(:replace_mir_expr_child!, mixed_parent, old_child, new_child)
    expect(mixed_parent.fields[:hit]).to be(new_child)
    array_miss = MIR::ArrayInit.new("i64", nil, [MIR::Ident.new("other")])
    low.send(:replace_mir_expr_child!, array_miss, old_child, new_child)
    expect(array_miss.items.first.name).to eq("other")
    hash_miss = MIR::StructInit.new("Box", { miss: MIR::Ident.new("other") })
    low.send(:replace_mir_expr_child!, hash_miss, old_child, new_child)
    expect(hash_miss.fields[:miss].name).to eq("other")

    call = MIR::Call.new("make", [], false, true)
    call.result_type = Type.new(:String)
    expect(low.send(:cleanup_entry_for_ownership_effect, call, alloc: :heap).kind).to eq(:uniform)
    untyped_call = MIR::Call.new("make", [], false, true)
    expect { low.send(:cleanup_entry_for_ownership_effect, untyped_call, alloc: :heap) }.to raise_error(/no typed cleanup result/)

    expect(low.send(:mir_ident_names, Object.new)).to eq([])
    expect(low.send(:mir_ident_names, MIR::ArrayInit.new("i64", nil, [MIR::Ident.new("a"), MIR::Ident.new("b")]))).to eq(["a", "b"])
  end

  it "covers hardened MIR ownership finalization fallbacks directly" do
    low = lowering

    already_finalized = MIR::Let.new("kept", MIR::Lit.new("1"), false, Type.new(:Int64), nil)
    already_state = ownership_finalization_context
    low.send(:mark_ownership_finalized_node!, already_finalized)
    low.send(:append_ownership_finalized_node!, already_state, already_finalized, [], 4, 2)
    expect(already_state.out).to eq([already_finalized])

    already_mark = MIR::TransferMark.new("kept", :owned_sink, :heap)
    already_mark_state = ownership_finalization_context
    low.send(:mark_ownership_finalized_node!, already_mark)
    low.send(:append_transfer_marks_to_body!, already_mark_state, [already_mark], 4, 2)
    expect(already_mark_state.out).to eq([already_mark])

    append_state = ownership_finalization_context
    finalized_for_append = MIR::TransferMark.new("done", :return, :heap)
    low.send(:mark_ownership_finalized_node!, finalized_for_append)
    low.send(:append_transfer_marks!, [finalized_for_append], append_state)
    expect(append_state.out).to eq([finalized_for_append])

    expect(low.send(:alloc_mark_present?, [MIR::AllocMark.new("owned", :heap, Type.new(:String))], "owned")).to eq(true)
    expect(low.send(:transfer_mark_present?, [MIR::TransferMark.new("owned", :return, :heap)], "owned")).to eq(true)
    borrowed = MIR::OwnedBorrow.new("borrowed", "source")
    expect(low.send(:dedupe_ownership_facts, [borrowed, borrowed])).to eq([borrowed])

    cap_state = ownership_finalization_context(body_alloc_mark_names: Set["cap_src"])
    cap = MIR::CapWrap.new(MIR::Ident.new("cap_src"), "Box", :own_only, nil, nil, "arcCreate", :heap)
    targets = low.send(:ownership_transfer_operands_for_node, cap, cap_state)
    expect(targets.map { |target| [target.name, target.target, target.target_alloc] })
      .to eq([["cap_src", :owned_sink, :heap]])

    facts = []
    low.send(:append_ownership_facts_for_owned_result!,
      facts, "promise", MIR::BgBlock.new("bg", {}, [], nil), Type.new(:String))
    expect(facts.first).to be_a(MIR::OwnedReturn)
    expect(facts.first.name).to eq("promise")

    state = ownership_finalization_context(
      out: [MIR::MoveMark.new("owned")],
      guarded_cleanup_names: Set["owned"],
    )
    low.send(:append_move_guard_for_transfer_mark!, MIR::TransferMark.new("owned", :owned_sink, :heap), state)
    expect(state.out.count { |stmt| stmt.is_a?(MIR::MoveMark) && stmt.name == "owned" }).to eq(1)
    unmarked_state = ownership_finalization_context(guarded_cleanup_names: Set["owned"])
    low.send(:append_move_guard_for_transfer_mark!, MIR::TransferMark.new("owned", :owned_sink, :heap), unmarked_state)
    expect(unmarked_state.out).to include(an_instance_of(MIR::MoveMark))

    fact = MIR::OwnershipConsumptionFact.new(
      operands: [MIR::OwnershipOperandFact.owned_binding("x", Type.new(:String), "spec", :heap)],
      target: :owned_sink,
      target_alloc: :heap,
      source: "spec",
      covers_consuming_params: true,
    )
    expr = MIR::Call.new("consume", [], false, false)
    expr.ownership_consumption = fact
    expect(low.send(:ownership_consumption_for_node, MIR::Ident.new("plain"))).to be_nil
    expect(low.send(:ownership_consumption_for_node, expr)).to be(fact)
    expect(low.send(:ownership_consumption_for_node, MIR::ExprStmt.new(expr, false))).to be(fact)
    expect(low.send(:ownership_contract_for_node, Object.new)).to be_nil
    expect(low.send(:ownership_contract_for_node, MIR::Call.new("plain", [], false, false))).to be_nil

    expect(low.send(:ownership_consumer_requires_fact?, MIR::Ident.new("plain"))).to eq(false)
    expect(low.send(:ownership_consumer_requires_fact?, MIR::InlineZig.new("x", "spec"))).to eq(false)
    no_params_sig = Struct.new(:return_type).new(Type.new(:Void))
    expect(low.send(:ownership_consumer_requires_fact?, MIR::InlineZig.new("x", "spec", MIR::OwnershipContract.empty, no_params_sig))).to eq(false)
    taking_sig = FunctionSignature.new(params: [param("taken", takes: true)], return_type: Type.new(:Void))
    expect(low.send(:ownership_consumer_requires_fact?, MIR::InlineZig.new("x", "spec", MIR::OwnershipContract.empty, taking_sig))).to eq(true)
    non_taking_sig = FunctionSignature.new(params: [param("kept")], return_type: Type.new(:Void))
    expect(low.send(:ownership_consumer_requires_fact?, MIR::InlineZig.new("x", "spec", MIR::OwnershipContract.empty, non_taking_sig))).to eq(false)

    try_catch = MIR::TryCatch.new(MIR::Ident.new("fallible"), MIR::Ident.new("fallback"), nil)
    expect(low.send(:place_owned_try_catch_for_destination, try_catch, Type.new(:String), :heap)).to be_a(MIR::TryCatch)
    plain_try_catch = MIR::TryCatch.new(MIR::Ident.new("fallible"), MIR::Ident.new("fallback"), nil)
    expect(low.send(:place_owned_try_catch_for_destination, plain_try_catch, Type.new(:Int64), :heap)).to be_a(MIR::TryCatch)

    low.instance_variable_set(:@current_bindings, {})
    low.instance_variable_set(:@lowered_alloc_names, Set["lowered"])
    expect(low.send(:ownership_consumed_name_operands, ["lowered"], "spec", :heap).first.name).to eq("lowered")
    low.instance_variable_set(:@lowered_alloc_names, nil)
    expect(low.send(:ownership_consumed_name_operands, ["hidden"], "spec", :heap)).to eq([])
    expect(low.send(:ownership_operand_type, Object.new, "spec").resolved).to eq(:Any)
    expect(low.send(:ownership_operand_type, lit("typed", type: :String), "spec").resolved).to eq(:String)

    low.instance_variable_set(:@current_bindings, {})
    low.instance_variable_set(:@pending_stmts, [MIR::AllocMark.new("pending", :heap, Type.new(:String))])
    expect(low.send(:owned_binding_visible?, "pending")).to eq(true)
    low.instance_variable_set(:@pending_stmts, nil)
    low.instance_variable_set(:@lowered_alloc_names, Set.new)
    expect(low.send(:owned_binding_visible?, "missing")).to eq(false)

    expect(low.send(:borrowed_ownership_ast?, nil)).to eq(false)
    expect(low.send(:borrowed_ownership_ast?, AST::CopyNode.new(tok, AST::GetIndex.new(tok, id("items"), lit(0, type: :Int64))))).to eq(true)
    borrowed = id("borrowed", storage: :heap)
    borrowed.container_borrow = true
    expect(low.send(:borrowed_ownership_ast?, borrowed)).to eq(true)
    expect(low.send(:borrowed_ownership_ast?, lit("x", type: :String))).to eq(false)

    type_root = id("TypeName")
    type_root.token = Lexer::Token.new(:TYPE_ID, "TypeName", 1, 1)
    type_field = AST::GetField.new(tok, type_root, "field")
    type_field.full_type = Type.new(:Int64)
    expect(low.send(:borrowed_ownership_ast?, type_field)).to eq(false)
    literal_field = AST::GetField.new(tok, lit("root", type: :String), "field")
    literal_field.full_type = Type.new(:Int64)
    expect(low.send(:borrowed_ownership_ast?, literal_field)).to eq(false)
    owner_field = AST::GetField.new(tok, id("owner", storage: :heap), "field")
    owner_field.full_type = Type.new(:Int64)
    expect(low.send(:borrowed_ownership_ast?, owner_field)).to eq(true)

    expect(low.send(:ownership_operands_for_sink_value,
      MIR::Ident.new("borrowed"), owner_field,
      Type.new(:String), "spec", :heap, require_visible_owned: true).first.borrowed).to eq(true)
    expect(low.send(:ownership_operands_for_sink_value,
      MIR::Ident.new("missing"), lit("missing", type: :String),
      Type.new(:String), "spec", :heap, require_visible_owned: false)).to eq([])
    no_fact_call = MIR::Call.new("read", [], false, false)
    expect(low.send(:ownership_operands_for_sink_value,
      no_fact_call, lit("missing", type: :String),
      Type.new(:String), "spec", :heap, require_visible_owned: false)).to eq([])

    expect(low.send(:strip_try, MIR::Ident.new("plain")).name).to eq("plain")
    expect(low.send(:strip_try, MIR::Call.new("fallible", [], true, false)).try_wrap).to eq(false)
  end

  it "covers ownership transfer collection through AST structural children" do
    dataflow = OwnershipDataflow.new(FunctionCFG.build(fn([])), fn([]), schema_lookup: nil)
    state = owner_state("a", "b", "c", "d", "e", "f", "g")

    struct_lit = AST::StructLit.new(tok, "Box", { "a" => id("a", storage: :heap) }, :heap, [])
    list_lit = AST::ListLit.new(tok, [id("b", storage: :heap)], :heap)
    type_ident = id("Maybe")
    type_ident.token = Lexer::Token.new(:TYPE_ID, "Maybe", 1, 1)
    union_ctor = AST::MethodCall.new(tok, type_ident, "Some", [id("c", storage: :heap)])
    share = AST::ShareNode.new(tok, id("d", storage: :heap))
    cap = AST::CapabilityWrap.new(tok, id("e", storage: :heap), :shared)
    get = AST::GetField.new(tok, id("f", storage: :heap), "payload")
    indirect = Type.new(:String)
    indirect.layout = :indirect
    get.full_type = indirect

    consumed = dataflow.send(:collect_binding_moves,
      AST::ListLit.new(tok, [struct_lit, list_lit, union_ctor, share, cap, get, AST::CopyNode.new(tok, id("g", storage: :heap))], :heap),
      state)

    expect(consumed).to include("a", "b", "c", "d", "e", "f")
    expect(consumed).not_to include("g")
  end

  it "covers ownership read checks and shard allocation facts" do
    fn_node = fn([])
    checker = UseAfterMoveChecker.new(fn_node, OwnershipDataflow.new(FunctionCFG.build(fn_node), fn_node))
    moved_state = { "dead" => OwnershipDataflow::OwnerEntry.new(state: OwnershipDataflow::MOVED, allocator: :heap, needs_cleanup: true) }
    checker.send(:check_identifier_read, "dead", moved_state, tok)
    checker.send(:check_identifier_read, "unknown", moved_state, tok)
    expect(checker.errors.join).to include("USE_AFTER_MOVE")

    shared = id("shared", storage: :heap)
    shared_type = Type.new(:String)
    shared_type.ownership = :shared
    shared.full_type = shared_type
    checker.send(:check_share_reads, AST::ShareNode.new(tok, shared), { "shared" => moved_state["dead"] })
    checker.send(:check_share_reads, AST::ShareNode.new(tok, AST::CopyNode.new(tok, shared)), { "shared" => moved_state["dead"] })
    checker.send(:check_share_reads, AST::ShareNode.new(tok, AST::BinaryOp.new(tok, shared, :ADD, lit("x"))), { "shared" => moved_state["dead"] })
    plain = id("plain", storage: :heap)
    checker.send(:check_share_reads, AST::ShareNode.new(tok, plain), { "plain" => moved_state["dead"] })
    expect(checker.errors.join).to include("shared")

    call = AST::FuncCall.new(tok, "allocates", [])
    call.full_type = :String
    fn_node = fn([])
    fn_node.uses_frame = true
    expect(LoopFrameAnalysis.key_allocates_frame?(call, { "allocates" => fn_node })).to eq(true)

    frame_list = AST::ListLit.new(tok, [], :frame)
    frame_list.full_type = Type.new(:"Int64[]")
    expect(LoopFrameAnalysis.key_allocates_frame?(frame_list, {})).to eq(true)
  end

  it "covers bg capture transfer helpers through expression children" do
    dataflow = OwnershipDataflow.new(FunctionCFG.build(fn([])), fn([]), schema_lookup: nil)
    state = owner_state("captured", "given")
    bg = AST::BgBlock.new(tok, [AST::MoveNode.new(tok, id("given", storage: :heap))], nil, nil, false, false, nil, false)
    bg.capture_analysis = double(resource_captures: Set["captured"], captures: { "captured" => true }, move_mark_names: Set["given"])
    call = AST::FuncCall.new(tok, "enqueue", [bg])

    expect(dataflow.send(:collect_bg_captures_in_args, call, state)).to include("captured", "given")

    missing = AST::BgBlock.new(tok, [], nil, nil, false, false, nil, false)
    missing.capture_analysis = double(resource_captures: Set["missing"], captures: {}, move_mark_names: Set["also_missing"])
    expect(dataflow.send(:collect_bg_captures_in_args, AST::FuncCall.new(tok, "enqueue", [missing]), state)).to eq([])
  end

  it "covers escape heap return and argument-return dependency facts" do
    p = param("value", type: :String)
    heap_arg = id("arg", type: :String, storage: :heap)
    heap_arg.full_type.mark_heap_allocated!

    expect(EscapeAnalysis.send(:heap_return_from_args?, [heap_arg], [p], Set["value"], Type.new(:String), nil)).to eq(true)
    expect(EscapeAnalysis.send(:heap_return_from_args?, [lit("x", type: :String)], [p], Set["missing"], Type.new(:String), nil)).to eq(true)
    int_param = param("n", type: :Int64)
    expect(EscapeAnalysis.send(:heap_return_from_args?, [lit(1, type: :Int64)], [int_param], Set["n"], Type.new(:Int64), nil)).to eq(false)
    expect(EscapeAnalysis.send(:heap_return_from_args?, [], [], nil, Type.new(:String), nil)).to be_nil

    callee = fn([AST::ReturnNode.new(tok, id("made", type: :String, storage: :heap))], return_type: :String)
    expect(EscapeAnalysis.send(:function_has_owned_return_value?, callee, nil)).to eq(true)
    return_value = id("returned", type: :String, storage: :heap)
    ret = AST::ReturnNode.new(tok, return_value)
    facts = EscapeAnalysis.send(:function_facts_for_body, [ret])
    expect(facts.fn.name).to eq("__escape_return_probe")
    expect(facts.return_values).to eq([return_value])
    expect(EscapeAnalysis.send(:body_has_heap_return_binding?, [ret])).to eq(true)

    borrowed = fn([], params: [p], return_type: :String)
    borrowed.return_lifetime = :wildcard
    expect(EscapeAnalysis.send(:borrowed_return?, borrowed, id("value", type: :String))).to eq(true)
  end

  it "covers MIR expression type substitution and fallback type decisions" do
    low = lowering
    expect(SymbolEntry.new(reg: "locked", type: Type.new(:String), mutable: true, storage: :stack, sync: :locked).sync_or_shared_storage?).to eq(true)

    source = Type.new(:T, sync: :locked, layout: :indirect)
    replaced = low.send(:substitute_mir_type, source, { T: :String })
    expect(replaced.resolved).to eq(:String)
    expect(replaced.sync).to eq(:locked)
    expect(replaced.layout).to eq(:indirect)

    generic = low.send(:substitute_mir_type, Type.new(:"Pair<T>"), { T: :String })
    expect(generic.resolved).to eq(:"Pair<String>")

    array = low.send(:substitute_mir_type, Type.new(:"T[]"), { T: :Int64 })
    expect(array.resolved).to eq(:"Int64[]")

    fixed_array = low.send(:substitute_mir_type, Type.new(:"T[4]"), { T: :String })
    expect(fixed_array.resolved).to eq(:"String[4]")

    optional = low.send(:substitute_mir_type, Type.new(:"?T"), { T: :String })
    expect(optional.resolved).to eq(:"?String")

    fallible = low.send(:substitute_mir_type, Type.new(:"!T"), { T: :String })
    expect(fallible.resolved).to eq(:"!String")

    tense = low.send(:substitute_mir_type, Type.new(:"~T[]"), { T: :Int64 })
    expect(tense.resolved).to eq(:"~Int64[]")
    unchanged_tense = Type.new(:"~String")
    expect(low.send(:substitute_mir_type, unchanged_tense, { T: :Int64 })).to equal(unchanged_tense)

    left = id("fallible", type: Type.new(:"!String"))
    op = AST::BinaryOp.new(tok, left, :OR_RESCUE, lit("fallback", type: :String))
    op.full_type = Type.new(:String)
    expect(low.send(:or_fallback_expected_type, op).resolved).to eq(:String)

    idx = AST::GetIndex.new(tok, id("items", type: Type.new(:"String[]")), lit(0, type: :Int64))
    idx.full_type = Type.new(:Untyped)
    expect(low.send(:copy_source_type_info, idx).resolved).to eq(:String)

    frame_source = SymbolEntry.new(reg: "source", type: Type.new(:String), mutable: false, storage: :frame)
    lifetime_view = id("view", type: :String, storage: :stack)
    lifetime_view.symbol.lifetime = [frame_source]
    expect(low.send(:placement_for_node, lifetime_view)).to eq(:frame)
  end

  it "materializes unhoisted owned return values before returning identifiers" do
    low = lowering
    ast_return = AST::ReturnNode.new(tok, lit("made", type: :String))
    call = MIR::Call.new("makeString", [MIR::Ident.new("rt")], false, true)

    lowered = low.send(:hoist_unhoisted_return_allocs, [MIR::ReturnStmt.new(call)], [ast_return])

    expect(lowered.grep(MIR::AllocMark).first.name).to start_with("__tmp_")
    expect(lowered.grep(MIR::Let).first.init).to equal(call)
    expect(lowered.last.value).to be_a(MIR::Ident)
  end

  it "covers non-switch match lowering branches that switch lowering intentionally bypasses" do
    low = lowering
    subject = id("point", type: :Point)
    x_field = AST::PatternField.new(name: "x", value: :bind, name_token: tok)
    y_field = AST::PatternField.new(name: "y", value: lit(3, type: :Int64), name_token: tok)
    pattern = AST::StructPattern.new(tok, [x_field, y_field], false)
    case_node = AST::MatchCase.new(kind: :struct_pattern, value: pattern, body: [lit(1, type: :Int64)])
    match = AST::MatchStatement.new(tok, subject, [case_node], nil, nil, nil, false, nil)
    match.full_type = :Void

    result = low.lower(match)
    expect(result).to be_a(MIR::IfChain)
    expect(result.branches.first[:body].grep(MIR::Let).map(&:name)).to include("x")
    expect(result.branches.first[:cond]).to be_a(MIR::BinOp)

    low.define_singleton_method(:emit_builtin) { |name, args| MIR::Call.new(name.to_s, args, false, false) }
    string_case = AST::MatchCase.new(
      kind: :eq,
      value: lit("start", type: :String),
      extra_values: [lit("stop", type: :String)],
      body: [lit(2, type: :Int64)]
    )
    string_match = AST::MatchStatement.new(tok, id("cmd", type: :String), [string_case], nil, nil, nil, false, nil)
    string_match.string_match = true
    string_match.full_type = :Void
    expect(low.lower(string_match).branches.first[:cond].op).to eq("or")

    union_low = MIRLowering.new(union_schemas: { Result: Schemas::UnionSchema.new(variants: { Ok: :Int64, Err: :Int64, Warn: :Int64 }) })
    union_subject = id("result", type: :Result)
    ok = AST::GetField.new(tok, id("Result"), "Ok")
    err = AST::MethodCall.new(tok, id("Result"), "Err", [])
    warn = AST::MethodCall.new(tok, id("Result"), "Warn", [])
    destructure = AST::StructPattern.new(tok, [
      AST::PatternField.new(name: "value", value: :bind, name_token: tok),
      AST::PatternField.new(name: "ignored", value: :wildcard, name_token: tok),
    ], true)
    guard_true = AST::Literal.new(tok, :BOOLEAN, true, nil)
    guard_true.full_type = :Boolean
    union_cases = [
      AST::MatchCase.new(kind: :eq, value: ok, extra_values: [err], binding: "payload", body: [lit(3, type: :Int64)]),
      AST::MatchCase.new(kind: :eq, value: warn, destructure: destructure, body: [lit(4, type: :Int64)]),
      AST::MatchCase.new(kind: :when, value: guard_true, body: [lit(5, type: :Int64)]),
    ]
    union_match = AST::MatchStatement.new(tok, union_subject, union_cases, nil, nil, nil, false, nil)
    union_match.full_type = :Void
    union_result = union_low.lower(union_match)
    expect(union_result).to be_a(MIR::IfChain)
    expect(union_result.branches.flat_map { |b| b[:body].grep(MIR::Let).map(&:name) }).to include("payload", "value")

    generic_case = AST::MatchCase.new(kind: :eq, value: id("A", type: :Any),
      extra_values: [id("B", type: :Any)], body: [lit(6, type: :Int64)])
    generic_match = AST::MatchStatement.new(tok, id("subject", type: :Any), [generic_case], nil, nil, nil, false, nil)
    generic_match.full_type = :Void
    expect(low.lower(generic_match).branches.first[:cond].op).to eq("or")
  end

  it "covers heap-destination OR placement without flattening branch ownership" do
    low = lowering
    left = id("maybe", type: Type.new(:"?String"), storage: :frame)
    right = id("fallback", type: :String, storage: :frame)
    op = AST::BinaryOp.new(tok, left, :OR_RESCUE, right)
    op.full_type = Type.new(:String)

    optional_placed = low.send(:place_string_or_for_heap_destination, MIR::Orelse.new(MIR::Ident.new("maybe"), MIR::Ident.new("fallback")), op)
    expect(optional_placed).to be_a(MIR::DupeSlice)

    fallible_left = id("fallible", type: Type.new(:"!String"), storage: :frame)
    fallible = AST::BinaryOp.new(tok, fallible_left, :OR_RESCUE, right)
    fallible.full_type = Type.new(:String)
    low.define_singleton_method(:heap_owned_result?) { |_mir, ast| ast.equal?(fallible_left) }
    placed = low.send(:place_string_or_for_heap_destination,
      MIR::TryCatch.new(MIR::Ident.new("fallible"), MIR::Ident.new("fallback"), nil),
      fallible)

    expect(placed).to be_a(MIR::TryCatch)
    expect(placed.expr).to be_a(MIR::Ident)
    expect(placed.catch_body).to be_a(MIR::BlockExpr)
    expect(placed.catch_body.body.grep(MIR::Let).first.init).to be_a(MIR::DupeSlice)
  end

  it "covers hoist container-borrow and deep-copy type decisions" do
    low = MIRLowering.new(union_schemas: { Result: Schemas::UnionSchema.new(variants: { Ok: :String }) })
    borrowed = id("borrowed", type: :Result, storage: :heap)
    borrowed.container_borrow = true
    expr = MIR::Ident.new("borrowed")
    captured = nil
    low.define_singleton_method(:hoist_alloc) do |copied, ast_node, err_cleanup: false, **_|
      captured = [copied, ast_node, err_cleanup]
      MIR::Ident.new("__tmp_copy")
    end

    out = low.send(:copy_container_borrow_if_needed, expr, borrowed)
    expect(out.name).to eq("__tmp_copy")
    expect(captured[0]).to be_a(MIR::DeepCopy)
    expect(captured[2]).to eq(true)

    passthrough = low.send(:copy_container_borrow_if_needed, expr, id("plain", type: :String))
    expect(passthrough).to equal(expr)

    explicit = MIR::DeepCopy.new(MIR::Ident.new("x"), "[]const u8", nil, :full_value, :heap)
    expect(low.send(:deep_copy_zig_type, explicit, nil)).to eq("[]const u8")
    inferred_ast = id("owned", type: Type.new(:String, location: :heap))
    inferred = MIR::DeepCopy.new(MIR::Ident.new("owned"), nil, nil, :full_value, :heap)
    expect(low.send(:deep_copy_zig_type, inferred, inferred_ast)).to eq("[]const u8")
  end

  it "covers reentrant lock checks across WITH-held params" do
    held_param = param("c", type: Type.new(:Counter))
    call_arg = id("c", type: Type.new(:Counter))
    call = AST::FuncCall.new(tok, "touch", [call_arg])
    with_block = AST::WithBlock.new(tok, [{ capability: :EXCLUSIVE, var_node: call_arg }], [call], nil)
    fn_node = fn([with_block], params: [held_param])

    callee_param = param("x", type: Type.new(:Counter))
    callee_sig = FunctionSignature.new(params: [callee_param], return_type: Type.new(:Void))
    callee_sig.requires = { "x" => Set[:LOCKED] }
    errors = []

    ConcurrencyChecks.check_reentrant!(fn_node, ->(name) { name == "touch" ? callee_sig : nil }, ->(_node, msg) { errors << msg })

    expect(errors.join).to include("Reentrant lock acquisition")
    expect(errors.join).to include("already held")
  end
end
