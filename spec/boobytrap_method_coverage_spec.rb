require "rspec"
require "ostruct"
require "set"

require_relative "../src/annotator/annotator"
require_relative "../src/ast/ast"
require_relative "../src/ast/lexer"
require_relative "../src/ast/type"
require_relative "../src/mir/cleanup_classifier"
require_relative "../src/mir/control_flow"
require_relative "../src/mir/fsm_transform/recursive_splitter"
require_relative "../src/mir/mir"
require_relative "../src/mir/mir_checker"
require_relative "../src/mir/mir_emitter"
require_relative "../src/mir/mir_lowering"
require_relative "../src/mir/mir_pass"

RSpec.describe "Boobytrap-ranked method coverage gaps" do
  let(:tok) { Lexer::Token.new(:VAR_ID, "x", 1, 1) }

  def id(name, type: Type.new(:String), storage: :heap, moved: false)
    node = AST::Identifier.new(tok, name)
    node.full_type = type
    node.storage = storage
    node.was_moved = moved
    node.symbol = SymbolEntry.new(reg: name, type: type, mutable: true, storage: storage)
    node
  end

  def lit(value = "1", type: Type.new(:Int64))
    node = AST::Literal.new(tok, :NUMBER, value, :stack)
    node.full_type = type
    node
  end

  def annotator
    SemanticAnnotator.new(source_code: "LET counter @locked: Int64 = 0;\n")
  end

  def lowering
    MIRLowering.new
  end

  it "covers cleanup-classifier allocator and owned-value classification helpers" do
    frame_decl = OpenStruct.new(symbol: OpenStruct.new(storage: :frame))
    sym = OpenStruct.new(reg: frame_decl, storage: :heap)
    expect(CleanupClassifier.send(:container_alloc_from, sym, OpenStruct.new(storage: :heap))).to eq(:frame)
    expect(CleanupClassifier.send(:container_alloc_from, OpenStruct.new(storage: :stack), Object.new)).to eq(:frame)
    expect(CleanupClassifier.send(:container_alloc_from, nil, OpenStruct.new(storage: :heap))).to eq(:heap)

    schema_lookup = ->(_) { nil }
    copy_string = AST::VarDecl.new(tok, "s_copy", nil, AST::CopyNode.new(tok, id("s")), false)
    copy_string.symbol = SymbolEntry.new(reg: "s", type: Type.new(:String), mutable: false, storage: :heap)
    expect(CleanupClassifier.send(:classify_owned_string, Type.new(:String), copy_string, schema_lookup)).to include(kind: :heap_string)

    borrowed_string = AST::VarDecl.new(tok, "b", nil, lit, false)
    borrowed_string.symbol = SymbolEntry.new(reg: "b", type: Type.new(:String), mutable: false, storage: :rodata)
    expect(CleanupClassifier.send(:classify_owned_string, Type.new(:String), borrowed_string, schema_lookup)).to be_nil

    field = AST::StructField.new(type: Type.new(:String), default: nil, borrowed: true)
    schema = OpenStruct.new(fields: { "name" => field }, borrowed_fields: Set.new)
    struct_lit = AST::StructLit.new(tok, "User", { "name" => id("name") }, :stack, [])
    node = OpenStruct.new(value: struct_lit)
    expect(CleanupClassifier.send(:struct_lit_borrows_cleanup_fields?, node, schema, schema_lookup)).to be(true)

    borrowed_type = Type.new(:String)
    borrowed_type.mark_borrowed_reference!
    borrowed_value = id("borrowed_name", type: borrowed_type)
    owned_field = AST::StructField.new(type: Type.new(:String), default: nil, borrowed: false)
    borrowed_schema = OpenStruct.new(fields: { "name" => owned_field }, borrowed_fields: Set.new)
    borrowed_struct = AST::StructLit.new(tok, "User", { "name" => borrowed_value }, :stack, [])
    expect(CleanupClassifier.send(:struct_lit_borrows_cleanup_fields?, OpenStruct.new(value: borrowed_struct), borrowed_schema, schema_lookup)).to be(true)

    expect(CleanupClassifier.send(:struct_lit_borrows_cleanup_fields?, OpenStruct.new(value: lit), schema, schema_lookup)).to be(false)
  end

  it "covers MIR hoisting and scoped branch ownership helpers" do
    l = lowering
    l.define_singleton_method(:mir_allocates?) { |expr| expr.is_a?(MIR::DupeSlice) }
    l.define_singleton_method(:alloc_mark_type_info) { |_expr, _node, _context| Type.new(:String) }
    l.define_singleton_method(:mir_owned_alloc) { |_expr| :frame }
    l.define_singleton_method(:stamp_allocating_result_target!) { |_expr, _name, alloc: nil| alloc }

    l.send(:hoist_lazy_alloc_result, MIR::DupeSlice.new(MIR::Ident.new("s"), :frame), id("s"))
    expect(l.function_state.pending_stmts.map(&:class)).to include(MIR::AllocMark, MIR::Let)

    passthrough = MIR::Ident.new("plain")
    l.send(:hoist_lazy_alloc_result, passthrough, id("plain"))

    parent = AST::BinaryOp.new(tok, id("left"), :ADD, id("right"))
    parent.define_singleton_method(:lazy_fields) { Set[:left] }
    lowered = []
    l.define_singleton_method(:lower_scoped) { |&blk| lowered << :scoped; blk.call }
    l.define_singleton_method(:lower) { |child| lowered << child.name }
    l.send(:descend, parent, :left)
    l.send(:descend, parent, :right)
    expect(lowered).to eq([:scoped, "left", "right"])

    branch = lowering
    branch.define_singleton_method(:alloc_mark_type_info) { |_mir, _node, _context| Type.new(:String) }
    branch.define_singleton_method(:hoist_cleanup_entry) do |_mir, _node|
      CleanupEntry.build(:heap_string, alloc: :heap, has_moved_guard: false, needs_cleanup: true)
    end
    branch.define_singleton_method(:ownership_transfer_marks) do |name, target, move_guarded: false, target_alloc: nil|
      [MIR::TransferMark.new(name, target, target_alloc)]
    end
    out = branch.send(:scoped_owning_branch_value, MIR::DupeSlice.new(MIR::Ident.new("s"), :heap), id("s"))
    expect(out).to be_a(MIR::BlockExpr)
    expect(out.body.map(&:class)).to include(MIR::AllocMark, MIR::ErrCleanup, MIR::TransferMark, MIR::BreakStmt)
  end

  it "covers moved-root collection helpers without source-level fuzz state" do
    l = lowering
    owned = CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: true, needs_cleanup: true, zig_type: "Thing")
    l.function_state.current_bindings["item"] = owned

    moved = AST::MoveNode.new(tok, id("item", type: Type.new(:String), moved: true))
    expect(l.send(:collect_explicit_move_roots, moved)).to eq(["item"])
    seen = []
    l.send(:walk_ast_for_moved_args, moved) { |arg| seen << arg.name.to_s }
    expect(seen).to eq(["item"])

    decl = AST::VarDecl.new(tok, "dst", nil, id("item", type: Type.new(:String), moved: true), false)
    expect(l.send(:collect_moved_arg_roots, decl)).to eq(["item"])
    expect(l.send(:consumed_binding_root, AST::CopyNode.new(tok, id("item")))).to be_nil
    expect(l.send(:consumed_binding_root, moved)).to eq("item")
  end

  it "covers MIR checker and pass helpers for frame allocs and return escapes" do
    checker = MIRChecker.new
    inline_mutator = MIR::InlineZig.new("x", "mutator", MIR::OwnershipContract.empty, { mutates_receiver: true }, nil)
    expect(checker.send(:expr_has_frame_alloc?, inline_mutator)).to be(false)
    expect(checker.send(:expr_has_frame_alloc?, MIR::DupeSlice.new(MIR::Ident.new("s"), :frame))).to be(true)
    inline_frame = MIR::InlineZig.new("frameAlloc()", "frame_alloc_probe")
    inline_frame.allocs = { alloc: :frame }
    expect(checker.send(:expr_has_frame_alloc?, inline_frame)).to be(true)
    expect(checker.send(:expr_has_frame_alloc?, nil)).to be(false)

    pass = MIRPass.new(fn_nodes: {}, schema_lookup: ->(_) { nil })
    escape = id("owned", moved: true)
    bindings = {
      "owned" => CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: true, needs_cleanup: true, zig_type: "Thing"),
      "__hoist_tmp" => CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: false, needs_cleanup: true, zig_type: "Thing"),
    }
    ret = AST::ReturnNode.new(tok, AST::StructLit.new(tok, "Pair", { "v" => escape }, :heap, []))
    expect(pass.send(:collect_return_escapes, ret, bindings)).to eq(["owned"])

    hoist = id("__hoist_tmp", moved: true)
    expect(pass.send(:collect_return_escapes, AST::ReturnNode.new(tok, hoist), bindings)).to eq(["__hoist_tmp"])
  end

  it "covers emitter raw-bytecode and discard-owned paths" do
    emitter = MIREmitter.new
    raw = MIR::RawBc.new(nil, [MIR::Ident.new("x"), MIR::Lit.new("1")], { zig: "doIt({0}, {1})" })
    expect(emitter.emit(raw)).to eq("doIt(x, 1)")
    expect { emitter.emit(MIR::RawBc.new(nil, [], nil)) }.to raise_error(/no stdlib_def/)

    cleanup = CleanupEntry.build(:heap_string, alloc: :heap, has_moved_guard: true)
    success_only = MIR::TryCatch.new(MIR::Call.new("maybe", [], false, false), MIR::Undef.new, nil)
    expect(emitter.emit(MIR::DiscardOwned.new(success_only, cleanup, "[]const u8"))).to include("catch null")
    expect(emitter.emit(MIR::DiscardOwned.new(MIR::Ident.new("owned"), cleanup, "[]const u8"))).to include("var __discard_")
  end

  it "covers function-lowering helpers for owned returns, safe navigation, and extern methods" do
    l = lowering
    param = AST::Param.new(name: "source", type: Type.new(:String))
    sig = FunctionSignature.new(params: [param], return_type: Type.new(:String))
    sig.heap_carry_return_vars = Set["source"]
    heap_arg = OpenStruct.new(needs_heap_create: true, full_type!: Type.new(:String))
    node = OpenStruct.new(args: [heap_arg])
    expect(l.send(:call_owned_return_from_args?, node, sig)).to be(true)

    sig.heap_carry_return_vars = Set["missing"]
    expect(l.send(:call_owned_return_from_args?, node, sig)).to be(true)

    recv = id("maybe", type: Type.new(:String))
    safe_target = Struct.new(:target, :token) do
      def full_type!(context:) = Type.new(:String)
    end.new(recv, tok)
    call = AST::MethodCall.new(tok, safe_target, "len", [])
    l.define_singleton_method(:lower) { |_n| MIR::Ident.new("maybe") }
    l.define_singleton_method(:lower_intrinsic) { |_n| MIR::Call.new("len", [MIR::Ident.new("_snav_1")], false, false) }
    expect(l.send(:lower_safe_nav_method_call, call)).to be_a(MIR::IfOptional)

    extern = AST::MethodCall.new(tok, recv, "native", [lit])
    l.define_singleton_method(:callable_contract_for) { |_sig_obj, args| MIR::CallableContract.no_ownership(args.length) }
    lowered = l.send(:lower_extern_direct_method, extern)
    expect(lowered).to be_a(MIR::MethodCall)
    expect(lowered.method).to eq("native")
  end

  it "covers type capability copying and field-path emission" do
    l = lowering
    source = Type.new(:String, ownership: :shared, sync: :locked, layout: :indirect)
    source.elem_ownership = :affine
    source.elem_sync = :write_locked
    target = Type.new(:String)
    l.send(:copy_type_capabilities, source, target)
    expect(target.sync).to eq(:locked)
    expect(target.layout).to eq(:indirect)
    expect(target.elem_ownership).to eq(:affine)
    expect(target.elem_sync).to eq(:write_locked)

    l.capture_state.do_capture_map = { "root" => "__ctx.root" }
    path = AST::GetField.new(tok, AST::GetField.new(tok, id("root"), "inner"), "leaf")
    expect(l.send(:build_field_path_zig, path)).to eq("__ctx.root.inner.leaf")
    expect(l.send(:build_field_path_zig, Object.new)).to be_a(String)
  end

  it "covers annotator recursive scans and stack/lifetime helpers" do
    a = annotator
    call = AST::FuncCall.new(tok, "recur", [])
    nested = AST::StructLit.new(tok, "Box", { "call" => call }, :stack, [])
    expect(a.send(:contains_self_call?, nested, "recur")).to be(true)
    expect(a.send(:contains_self_call?, nil, "recur")).to be(false)

    {
      "start" => Set["mid"],
      "mid" => Set["deep"],
    }.each do |name, callees|
      a.send(:record_function_body_summary!, Annotator::Phases::FunctionBodySummary.new(
        name: name,
        callees: callees,
        propagating_callees: callees,
        has_fnptr_call: false,
        raises_directly: false
      ))
    end
    fn = AST::FunctionDef.new(tok, "deep", [], [], :Void, nil, [], [], nil, :private, [], false)
    fn.stack_tier = :unbounded
    a.instance_variable_set(:@fn_nodes, { "deep" => fn })
    expect(a.send(:find_unbounded_callee, Set["start"])).to eq("deep")

    source = OpenStruct.new(scope_depth: 3)
    a.define_singleton_method(:lifetime_sources_for_value) { |_node| [source] }
    expect(a.send(:lifetime_violation_for_store, id("borrow"), 2)).to include("scope depth 3")
    expect(a.send(:lifetime_violation_for_store, id("borrow"), 4)).to be_nil
  end

  it "covers annotator visit helpers for copy, block expressions, assignment, and fixable caps" do
    a = annotator
    a.define_singleton_method(:visit) { |_node| nil }
    a.define_singleton_method(:with_new_scope) { |_parent = nil, &blk| blk.call }
    a.define_singleton_method(:mark_var_mutated) { |_name| true }
    a.define_singleton_method(:validate_assignment_type) { |_node, _expected, _actual| true }
    a.define_singleton_method(:fixable!) { |*_args, **_kwargs| :fixable }
    a.define_singleton_method(:error!) { |*_args, **_kwargs| :error }

    value = id("copyable", type: Type.new(:String), storage: :rodata)
    copy = AST::Copy.new(tok, value)
    a.send(:visit_Copy, copy)
    expect(copy.full_type!(context: "copy test").string?).to be(true)

    block = AST::BlockExpr.new(tok, [lit], value)
    a.send(:visit_BlockExpr, block)
    expect(block.storage).to eq(:rodata)

    a.current_scope.declare("counter", OpenStruct.new(token: tok), Type.new(:Int64), true, false, nil, :stack)
    assign = AST::Assignment.new(tok, id("counter", type: Type.new(:Int64)), lit("2", type: Type.new(:Int64)))
    a.send(:visit_assignment_variable, assign.name, assign)
    expect(assign.full_type!(context: "assignment test").resolved).to eq(:Int64)

    fix = a.send(:build_decl_cap_replace_fix, "counter", "@locked", "@writeLocked")
    expect(fix.edits.first.replacement).to eq("@writeLocked")

    a.define_singleton_method(:cap_var_sync) { |_var_node| :locked }
    with_block = AST::WithBlock.new(tok, [], [], nil)
    expect(a.send(:emit_with_read_needs_write_lock!, with_block, "counter", id("counter"))).to eq(:fixable)
  end

  it "covers sharded pipeline scanners" do
    a = annotator
    shard_id = id("items")
    a.define_singleton_method(:each_shard_scan_node) do |node, &blk|
      Array(node).each { |n| blk.call(n) }
    end
    a.define_singleton_method(:sharded_unsynced_identifier?) { |node| node.equal?(shard_id) }
    expect(a.send(:pre_scan_node_for_sharded, [id("other"), shard_id])).to be(true)

    access = AST::PipelineShardedAccess.new(
      map_name: "items",
      key_expr: lit,
      map_token: tok,
    )
    a.define_singleton_method(:sharded_get_index_access) do |node, context:|
      context == "pipeline target" && node.equal?(shard_id) ? access : nil
    end
    results = []
    a.send(:walk_for_sharded_getindex, [shard_id], results)
    expect(results).to eq([access])
  end

  it "covers ownership dataflow move detection" do
    fn = AST::FunctionDef.new(tok, "main", [], [], :Void, nil, [], [], nil, :private, [], false)
    dataflow = OwnershipDataflow.new(FunctionCFG.build(fn), fn, schema_lookup: ->(_) { nil })
    move = AST::MoveNode.new(tok, id("owned", type: Type.new(:String), moved: true))
    expect(dataflow.send(:stmt_moves_name?, move, "owned")).to be(true)
    expect(dataflow.send(:stmt_moves_name?, AST::ReturnNode.new(tok, move), "owned")).to be(false)
  end

  it "covers recursive FSM suspend fragment emission" do
    builder = FsmTransform::RecursiveSplitter::Builder.new
    tail = FsmTransform::Segments::IoSuspend.new(nil, nil, "result", nil)
    idx = FsmTransform::RecursiveSplitter.send(:emit_suspend, tail, 99, builder)
    segment = builder.segments.fetch(idx)
    expect(segment.tail.next_index).to eq(99)

    expect {
      FsmTransform::RecursiveSplitter.send(:emit_suspend, Object.new, 99, builder)
    }.to raise_error(FsmTransform::RecursiveSplitter::UnsupportedShape)
  end
end
