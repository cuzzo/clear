require "rspec"
require_relative "../src/ast/ast" unless defined?(MIR::ReassignPlan)
require_relative "../src/mir/mir" unless defined?(MIR::StdlibDefFsCoercion)
require_relative "../src/backends/mir_emitter" unless defined?(MIREmitter)

RSpec.describe MIREmitter do
  let(:e) { MIREmitter.new }

  # =========================================================================
  # Literals and identifiers
  # =========================================================================

  it "emits a literal" do
    expect(e.emit(MIR::Lit.new("42"))).to eq("42")
  end

  it "emits an identifier" do
    expect(e.emit(MIR::Ident.new("foo"))).to eq("foo")
  end

  it "emits structural defaults and enum pseudo-literals only at the emitter edge" do
    expect(e.emit(MIR::DefaultValue.new(kind: :aggregate_empty))).to eq(".{}")
    expect(e.emit(MIR::DefaultValue.new(kind: :string_empty))).to eq('@as([]const u8, "")')
    expect(e.emit(MIR::DefaultValue.new(kind: :collection_empty, zig_type: "CheatLib.ArrayListUnmanaged(i64)")))
      .to eq("@as(CheatLib.ArrayListUnmanaged(i64), .empty)")
    expect(e.emit(MIR::DefaultValue.new(kind: :undefined, zig_type: "i64"))).to eq("@as(i64, undefined)")
    expect(e.emit(MIR::EnumTag.new(variant: "Transient"))).to eq(".Transient")
    expect(e.emit(MIR::EnumOrdinal.new(MIR::FieldGet.new(MIR::Ident.new("ErrorName"), "Timeout"))))
      .to eq("@intFromEnum(ErrorName.Timeout)")
  end

  it "emits an anonymous tuple literal from structural children" do
    node = MIR::TupleLiteral.new([MIR::Ident.new("x"), MIR::Lit.new("42")])

    expect(e.emit(node)).to eq(".{x, 42}")
  end

  it "emits a function reference" do
    expect(e.emit(MIR::FnRef.new("handler"))).to eq("&handler")
  end

  it "emits TypeOf from a structural child expression" do
    node = MIR::TypeOf.new(MIR::FieldGet.new(MIR::Ident.new("target"), "field"))

    expect(e.emit(node)).to eq("@TypeOf(target.field)")
  end

  # =========================================================================
  # Binary and unary operations
  # =========================================================================

  it "emits a binary operation" do
    node = MIR::BinOp.new("+", MIR::Ident.new("a"), MIR::Lit.new("1"))
    expect(e.emit(node)).to eq("(a + 1)")
  end

  it "emits a unary operation" do
    node = MIR::UnaryOp.new("-", MIR::Ident.new("x"))
    expect(e.emit(node)).to eq("-x")
  end

  it "emits pointer, const, and default stream capacity helper expressions" do
    ptr = MIR::PointerCast.new(MIR::OptionalUnwrap.new(MIR::Ident.new("raw_ctx")), "*@This()")
    expect(e.emit(ptr)).to eq("@as(*@This(), @ptrCast(@alignCast(raw_ctx.?)))")
    expect(e.emit(MIR::ConstCast.new(MIR::Ident.new("pipe_items")))).to eq("@constCast(pipe_items)")

    cap = e.emit(MIR::DefaultStreamCapacity.new(MIR::Ident.new("n_workers")))
    expect(cap).to include("var c: usize = 4")
    expect(cap).to include("while (c < n_workers * 4)")
    expect(cap).to include("break :blk @min(c, 64);")
  end

  it "emits polymorphic flow signals inside flow bodies" do
    signal = MIR::PolymorphicFlowSignal.new(:raise_no_commit, nil)
    expect(e.send(:emit_body_flow, [signal], :ret_no_commit)).to eq("__flow.* = .{ .kind = .raise_no_commit };\nreturn;")
  end

  it "emits public statement lists through the standard body renderer" do
    stmts = [
      MIR::Set.new(MIR::Ident.new("x"), MIR::Lit.new("1"), false),
      MIR::ExprStmt.new(MIR::MethodCall.new(MIR::Ident.new("lock"), "unlock", [], false), false),
    ]

    expect(e.emit_stmt_list(stmts)).to eq("x = 1;\nlock.unlock();")
  end

  it "emits promise-list NEXT await-all expressions" do
    node = MIR::NextPromiseList.new(
      MIR::Ident.new("futures"),
      "i64",
      "__next_all_1",
      "__next_results_1",
      :frame,
      Type.new(:"Int64[]"),
    )
    zig = e.emit(node)
    expect(zig).to include("var __next_results_1 = std.ArrayListUnmanaged(i64).empty")
    expect(zig).to include("for (futures.items) |__p|")
    expect(zig).to include("try __next_results_1.append(rt.frameAlloc(), try __p.next())")
    expect(zig).to include("break :__next_all_1 __next_results_1;")
  end

  # =========================================================================
  # Variable declarations
  # =========================================================================

  it "emits const declaration" do
    node = MIR::Let.new("x", MIR::Lit.new("42"), false, nil, nil)
    expect(e.emit(node)).to eq("const x = 42;")
  end

  it "emits var declaration with annotation" do
    node = MIR::Let.new("count", MIR::Lit.new("0"), true, Type.new("i64"), "_ = &count;")
    expect(e.emit(node)).to eq("var count: i64 = 0; _ = &count;")
  end

  # =========================================================================
  # Assignments
  # =========================================================================

  it "emits simple assignment" do
    node = MIR::Set.new(MIR::Ident.new("x"), MIR::Lit.new("5"))
    expect(e.emit(node)).to eq("x = 5;")
  end

  it "emits field assignment" do
    target = MIR::FieldGet.new(MIR::Ident.new("user"), "name")
    node = MIR::Set.new(target, MIR::Lit.new("\"alice\""))
    expect(e.emit(node)).to eq("user.name = \"alice\";")
  end

  it "emits reassignment with cleanup" do
    node = MIR::ReassignWithCleanup.new("buf", MIR::Lit.new("new_val"), "[]const u8", :heap)
    zig = e.emit(node)
    expect(zig).to include("const __new_buf = new_val;")
    expect(zig).to include("CheatLib.cleanup(@TypeOf(buf), rt.heapAlloc(), &buf);")
    expect(zig).to include("buf = __new_buf;")
  end

  # =========================================================================
  # Control flow
  # =========================================================================

  it "emits if statement" do
    node = MIR::IfStmt.new(
      MIR::Ident.new("flag"),
      [MIR::ReturnStmt.new(MIR::Lit.new("1"))],
      [MIR::ReturnStmt.new(MIR::Lit.new("0"))]
    )
    zig = e.emit(node)
    expect(zig).to include("if (flag)")
    expect(zig).to include("return 1;")
    expect(zig).to include("else")
    expect(zig).to include("return 0;")
  end

  it "emits while loop" do
    node = MIR::WhileStmt.new(
      MIR::Ident.new("running"),
      [MIR::ExprStmt.new(MIR::Call.new("tick", [], false), false)],
      nil
    )
    zig = e.emit(node)
    expect(zig).to include("while (running)")
    expect(zig).to include("tick();")
  end

  it "emits for loop" do
    node = MIR::ForStmt.new(
      MIR::Ident.new("items"),
      "item",
      [MIR::ExprStmt.new(MIR::Call.new("process", [MIR::Ident.new("item")], false), false)],
      "i"
    )
    zig = e.emit(node)
    expect(zig).to include("for (items) |item, i|")
    expect(zig).to include("process(item);")
  end

  it "emits return with value" do
    expect(e.emit(MIR::ReturnStmt.new(MIR::Lit.new("42")))).to eq("return 42;")
  end

  it "emits bare return" do
    expect(e.emit(MIR::ReturnStmt.new(nil))).to eq("return;")
  end

  it "emits break with label and value" do
    expect(e.emit(MIR::BreakStmt.new("blk", MIR::Ident.new("result")))).to eq("break :blk result;")
  end

  it "emits continue" do
    expect(e.emit(MIR::ContinueStmt.new(nil))).to eq("continue;")
  end

  it "emits switch statement" do
    node = MIR::SwitchStmt.new(
      MIR::Ident.new("dir"),
      [
        MIR::SwitchArm.new(
          patterns: [MIR::EnumSwitchPattern.new(variant: "North")],
          body: [MIR::ReturnStmt.new(MIR::Lit.new("0"))],
        ),
        MIR::SwitchArm.new(
          patterns: [MIR::EnumSwitchPattern.new(variant: "South")],
          body: [MIR::ReturnStmt.new(MIR::Lit.new("1"))],
        ),
      ],
      [MIR::ReturnStmt.new(MIR::Lit.new("-1"))]
    )
    zig = e.emit(node)
    expect(zig).to include("switch (dir)")
    expect(zig).to include(".North =>")
    expect(zig).to include(".South =>")
    expect(zig).to include("else =>")
  end

  it "emits structural function catch wrappers" do
    clause = MIR::CatchClause.new(
      meta: MIR::CatchClauseMeta.new(
        kinds: ["Input"],
        types: ["ParseErr"],
        filter_types: [],
        filter_messages: [MIR::Lit.new("\"bad\"")],
      ),
      body: [MIR::ReturnStmt.new(MIR::Lit.new("1"))],
    )
    node = MIR::CatchWrapper.new(
      MIR::Call.new("__f_body", [MIR::Ident.new("rt")], false, false, MIR::CallableContract.no_ownership(1)),
      [],
      [clause],
      [],
      MIR::CatchDefaultAction::Propagate,
      Type.new(:String),
      "rt",
    )

    zig = e.emit(node)

    expect(zig).to include("return __f_body(rt) catch")
    expect(zig).to include("rt.__error.matchesKind(.Input)")
    expect(zig).to include("ErrorName.ParseErr")
    expect(zig).to include('rt.__error.matchesMessage("bad")')
    expect(zig).to include("const __snap_ptr = rt.__error.snapshotAs([]const u8);")
    expect(zig).to include("return error.CheatError;")
  end

  it "emits default-only structural function catch wrappers" do
    node = MIR::CatchWrapper.new(
      MIR::Call.new("__f_body", [], false, false, MIR::CallableContract.no_ownership(0)),
      [],
      [],
      [MIR::ReturnStmt.new(MIR::Lit.new("0"))],
      MIR::CatchDefaultAction::Body,
      nil,
      "rt",
    )

    zig = e.emit(node)

    expect(zig).to include("return __f_body() catch")
    expect(zig).to include("const __error = rt.__error;")
    expect(zig).to include("return 0;")
    expect(zig).not_to include("else")
  end

  it "emits snapshot reads from structural capability unwraps" do
    node = MIR::SnapshotRead.new(
      MIR::CapabilityUnwrap.new(MIR::Ident.new("cell")),
      "rt",
      "view",
      "__guard",
      [MIR::Suppress.new("view")],
    )

    zig = e.emit(node)

    expect(zig).to include("@typeInfo(@TypeOf(cell))")
    expect(zig).to include("var __guard = ")
    expect(zig).to include(".*.read(rt);")
    expect(zig).to include("const view = __guard.get();")
  end

  it "emits if-chain" do
    node = MIR::IfChain.new(
      [MIR::IfChainBranch.new(
        cond: MIR::BinOp.new("==", MIR::Ident.new("x"), MIR::Lit.new("1")),
        body: [MIR::ReturnStmt.new(MIR::Lit.new("\"one\""))],
      )],
      [MIR::ReturnStmt.new(MIR::Lit.new("\"other\""))]
    )
    zig = e.emit(node)
    expect(zig).to include("if ((x == 1))")
    expect(zig).to include("else")
  end

  # =========================================================================
  # Function definitions
  # =========================================================================

  it "emits a pub function" do
    node = MIR::FnDef.new(
      "add",
      [MIR::Param.new("a", "i64"), MIR::Param.new("b", "i64")],
      "i64",
      [MIR::ReturnStmt.new(MIR::BinOp.new("+", MIR::Ident.new("a"), MIR::Ident.new("b")))],
      :pub, false, nil
    )
    zig = e.emit(node)
    expect(zig).to include("pub fn add(a: i64, b: i64) i64")
    expect(zig).to include("return (a + b);")
  end

  it "emits a failable function" do
    node = MIR::FnDef.new(
      "fetch",
      [MIR::Param.new("rt", "*Runtime")],
      "[]const u8",
      [MIR::ReturnStmt.new(MIR::Lit.new("\"hello\""))],
      :pub, true, nil
    )
    zig = e.emit(node)
    expect(zig).to include("pub fn fetch(rt: *Runtime) ![]const u8")
  end

  it "emits comptime params" do
    node = MIR::FnDef.new(
      "make",
      [MIR::Param.new("rt", "*Runtime")],
      "void",
      [],
      :pub, true, ["comptime T: type"]
    )
    zig = e.emit(node)
    expect(zig).to include("pub fn make(comptime T: type, rt: *Runtime) !void")
  end

  # =========================================================================
  # Type definitions
  # =========================================================================

  it "emits struct definition" do
    node = MIR::StructDef.new(
      "User",
      [MIR::FieldDef.new("id", "i64", nil),
       MIR::FieldDef.new("name", "[]const u8", nil)],
      nil, :pub
    )
    zig = e.emit(node)
    expect(zig).to include("pub const User = struct")
    expect(zig).to include("id: i64,")
    expect(zig).to include("name: []const u8,")
  end

  it "emits enum definition" do
    node = MIR::EnumDef.new("Color", ["Red", "Green", "Blue"], :pub)
    expect(e.emit(node)).to eq("pub const Color = enum { Red, Green, Blue };")
  end

  it "emits union definition" do
    node = MIR::UnionTypeDef.new(
      "Result",
      [{ name: "Ok", zig_type: "i64" }, { name: "Err", zig_type: "[]const u8" }, { name: "Empty", zig_type: "void" }],
      :pub
    )
    zig = e.emit(node)
    expect(zig).to include("pub const Result = union(enum)")
    expect(zig).to include("Ok: i64")
    expect(zig).to include("Err: []const u8")
    expect(zig).to include("Empty: void")
  end

  it "emits import" do
    node = MIR::Import.new("std", "std", nil)
    expect(e.emit(node)).to eq("const std = @import(\"std\");")
  end

  it "emits import with member" do
    node = MIR::Import.new("json", "std", "json")
    expect(e.emit(node)).to eq("const json = @import(\"std\").json;")
  end

  it "emits structural module namespaces" do
    node = MIR::ModuleNamespace.new("helper", [
      MIR::FnDef.new(
        "answer",
        [],
        "i64",
        [MIR::ReturnStmt.new(MIR::Lit.new("42"))],
        :pub, false, nil
      ),
    ])

    zig = e.emit(node)

    expect(zig).to include("const helper = struct {")
    expect(zig).to include("    pub fn answer() i64")
    expect(zig).to include("    return 42;")
  end

  it "emits type alias" do
    node = MIR::TypeAlias.new("Alloc", "std.mem.Allocator")
    expect(e.emit(node)).to eq("const Alloc = std.mem.Allocator;")
  end

  it "emits test block" do
    node = MIR::TestDef.new("basic arithmetic", [
      MIR::ExprStmt.new(
        MIR::Call.new("try std.testing.expectEqual", [MIR::Lit.new("4"), MIR::BinOp.new("+", MIR::Lit.new("2"), MIR::Lit.new("2"))], false),
        false
      )
    ])
    zig = e.emit(node)
    expect(zig).to include('test "basic arithmetic"')
  end

  # =========================================================================
  # Expressions
  # =========================================================================

  it "emits function call" do
    node = MIR::Call.new("add", [MIR::Lit.new("1"), MIR::Lit.new("2")], false)
    expect(e.emit(node)).to eq("add(1, 2)")
  end

  it "emits try-wrapped call" do
    node = MIR::Call.new("fetch", [MIR::Ident.new("rt")], true)
    expect(e.emit(node)).to eq("try fetch(rt)")
  end

  it "builds contracted runtime helper calls from named constructors" do
    eql = MIR::RuntimeCall.new(MIR::RuntimeCalls.eql_spec, [MIR::Ident.new("a"), MIR::Ident.new("b")])
    expect(eql.spec.callable_contract.checked_arg_count).to eq(2)
    expect(e.emit(eql)).to eq("CheatLib.eql(a, b)")

    thread_count = MIR::RuntimeCall.new(MIR::RuntimeCalls.thread_count_spec, [])
    expect(thread_count.spec.callable_contract.checked_arg_count).to eq(0)
    expect(e.emit(thread_count)).to eq("CheatLib.threadCount()")

    batch = MIR::RuntimeCall.new(MIR::RuntimeCalls.batch_window_init_spec("i64"), [
      MIR::AllocatorRef.new(:heap),
      MIR::Lit.new("4"),
      MIR::Lit.new("100"),
    ])
    expect(batch.spec.callable_contract.checked_arg_count).to eq(3)
    expect(e.emit(batch)).to eq("CheatLib.BatchWindow(i64).init(rt.heapAlloc(), 4, 100)")

    atomic = MIR::RuntimeCall.new(MIR::RuntimeCalls.atomic_reduce_init_spec("i64"), [MIR::Lit.new("0")])
    expect(atomic.spec.callable_contract.checked_arg_count).to eq(1)
    expect(e.emit(atomic)).to eq("CheatLib.obs.AtomicReduce(i64).init(0)")
  end

  it "rebases runtime-scoped calls and allocators" do
    e.rt_name = "__rt"

    expect(e.emit(MIR::Call.new("rt.sleep", [MIR::Lit.new("1")], false))).to eq("__rt.sleep(1)")
    expect(e.emit(MIR::FreezeExpr.new(MIR::Ident.new("value"), "Payload")))
      .to eq("try CheatLib.freeze(Payload, __rt.heapAlloc(), value)")
    expect(e.emit(MIR::FreezeExpr.new(MIR::Ident.new("value"), "Payload", MIR::AllocatorRef.new(:frame))))
      .to eq("try CheatLib.freeze(Payload, __rt.frameAlloc(), value)")
    expect(e.send(:emit_thunk_yield_statement, :check)).to eq("__rt.checkYield();")
  end

  it "rebases runtime-owned thunk frame allocation" do
    e.rt_name = "__rt"
    node = MIR::ThunkTrampoline.new(
      fn_name: "fact",
      return_type: Type.new(:Int64),
      param_fields: [MIR::ThunkFrameField.new(name: "n", type_info: Type.new(:Int64))],
      param_init_fields: [MIR::ThunkFrameInit.new(field_name: "n", value: MIR::Ident.new("n"))],
      base_cases: [MIR::ThunkBaseCase.new(cond: MIR::BinOp.new("<=", MIR::Ident.new("current.n"), MIR::Lit.new("1")), value: MIR::Lit.new("1"))],
      recurse_arg_inits: [MIR::ThunkFrameInit.new(field_name: "n", value: MIR::BinOp.new("-", MIR::Ident.new("current.n"), MIR::Lit.new("1")))],
      combine_lhs: MIR::Ident.new("current.n"),
      combine_op: :MUL,
      yield_policy: :check,
    )

    zig = e.emit(node)

    expect(zig).to include("__rt.checkYield();")
    expect(zig).to include("const child = __rt.heapAlloc().create(Frame) catch unreachable;")
    expect(zig).to include("if (current != &initial) __rt.heapAlloc().destroy(current);")
  end

  it "rebases structural DO block wait-group runtime access" do
    e.rt_name = "__outer_rt"
    plan = MIR::DoBlockPlan.new(wg_var: "__wg", branches: [])

    expect(e.emit(MIR::DoBlock.new(plan, []))).to include(
      "var __wg = CheatHeader.WaitGroup.init(__outer_rt.getSched());"
    )
  end

  it "rebases stackful BG run-body allocation and cleanup to the BG runtime" do
    cleanup = CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: false)
    task_config = MIR::TaskConfigPlan.new(stack_variant: "Large")
    plan = MIR::BgStackfulPlan.new(
      id: 0,
      ctx_type: "__BgCtx0",
      alloc_var: "__bg0_alloc",
      promise_var: "__bg0_promise",
      ctx_var: "__bg0_ctx",
      blk_label: "__bg0",
      bg_rt: "__rt_bg0",
      rt_name: "rt",
      promise_zig: "CheatLib.Promise(i64)",
      is_void: false,
      capture_fields: [],
      capture_inits: [
        MIR::StructInitField.new(name: :inner, value: MIR::Ident.new("__bg0_promise.inner")),
        MIR::StructInitField.new(name: :alloc, value: MIR::Ident.new("__bg0_alloc")),
      ],
      capture_frees: [
        MIR::CaptureCleanupAction.new(target: MIR::Ident.new("cap"), cleanup_entry: cleanup),
      ],
      promoted_decls: [],
      profile_site: MIR::ProfileTaskSite.new(site_id: 1, line: 1, column: 1, dispatch: :local, form: :stack),
      arena_init: nil,
      spawn_call: MIR::FiberSpawnCall.new(
        target: :runtime_submit,
        runtime_name: "rt",
        ctx_type: "__BgCtx0",
        ctx_var: "__bg0_ctx",
        task_config: task_config,
      ),
      alloc_expr: MIR::AllocatorRef.new(:heap),
      run_body: [
        MIR::Let.new("pool", MIR::ContainerInit.new("Pool(User)", :pool, :heap, 4), true, nil, nil),
        MIR::Cleanup.new("pool", cleanup),
      ],
    )

    zig = e.emit(MIR::BgBlock.new(plan))

    expect(zig).to include("var pool = try Pool(User).initCapacity(__rt_bg0.heapAlloc(), 4);")
    expect(zig).to include("defer CheatLib.cleanup(@TypeOf(pool), __rt_bg0.heapAlloc(), &pool);")
    expect(zig).to include("defer CheatLib.cleanup(@TypeOf(cap), __rt_bg0.heapAlloc(), &cap)")
  end

  it "emits method call" do
    node = MIR::MethodCall.new(MIR::Ident.new("list"), "append", [MIR::Lit.new("42")], false)
    expect(e.emit(node)).to eq("list.append(42)")
  end

  it "emits field access" do
    node = MIR::FieldGet.new(MIR::Ident.new("user"), "name")
    expect(e.emit(node)).to eq("user.name")
  end

  it "emits index access" do
    node = MIR::IndexGet.new(MIR::Ident.new("arr"), MIR::Lit.new("0"))
    expect(e.emit(node)).to eq("arr[0]")
  end

  it "emits struct init" do
    node = MIR::StructInit.new("User", [
      { name: "id", value: MIR::Lit.new("1") },
      { name: "name", value: MIR::Lit.new("\"alice\"") }
    ])
    expect(e.emit(node)).to eq("User{ .id = 1, .name = \"alice\" }")
  end

  it "emits anonymous struct init" do
    node = MIR::StructInit.new(nil, [{ name: "x", value: MIR::Lit.new("1") }])
    expect(e.emit(node)).to eq(".{ .x = 1 }")
  end

  it "emits array init" do
    node = MIR::ArrayInit.new("i64", 3, [MIR::Lit.new("1"), MIR::Lit.new("2"), MIR::Lit.new("3")])
    expect(e.emit(node)).to eq("[3]i64{ 1, 2, 3 }")
  end

  it "emits compact repeated default array init" do
    node = MIR::ArrayDefaultInit.new("[]const u8", "256", MIR::Lit.new("\"\""), :frame, Type.array_of(:String, capacity: 256))
    expect(node.result_type.zig_type).to eq("[256][]const u8")
    expect(node.ownership_effect.produces_owned).to eq(true)
    expect(node.ownership_effect.alloc).to eq(:frame)
    expect(e.emit(node)).to eq("[_][]const u8{ \"\" } ** 256")
  end

  it "preserves OR-EXIT bytecode rewrite metadata and child message" do
    message = MIR::Lit.new("\"fail\"")
    node = MIR::OrExitBcRewrite.new("Runtime", 3, true, true, 12, message)

    expect(node.kind).to eq("Runtime")
    expect(node.name_id).to eq(3)
    expect(node.clear_type).to eq(true)
    expect(node.has_message).to eq(true)
    expect(node.line).to eq(12)
    expect(node.child_exprs).to eq([message])
  end

  it "emits slice expression with type coercion" do
    node = MIR::SliceExpr.new(MIR::Ident.new("buf"), MIR::Lit.new("0"), MIR::Lit.new("5"), "u8")
    expect(e.emit(node)).to eq("@as([]const u8, buf[0..5])")
  end

  it "emits block expression" do
    node = MIR::BlockExpr.new("blk", [
      MIR::Let.new("tmp", MIR::Lit.new("42"), false, nil, nil),
      MIR::BreakStmt.new("blk", MIR::Ident.new("tmp"))
    ])
    zig = e.emit(node)
    expect(zig).to include("blk: {")
    expect(zig).to include("const tmp = 42;")
    expect(zig).to include("break :blk tmp;")
  end

  it "emits cast @as" do
    node = MIR::Cast.new(MIR::Ident.new("x"), "usize", :as)
    expect(e.emit(node)).to eq("@as(usize, x)")
  end

  it "emits cast @intCast" do
    node = MIR::Cast.new(MIR::Ident.new("n"), nil, :intCast)
    expect(e.emit(node)).to eq("@intCast(n)")
  end

  it "emits try expression" do
    node = MIR::TryExpr.new(MIR::Call.new("open", [], false))
    expect(e.emit(node)).to eq("try open()")
  end

  it "emits try-catch expression" do
    node = MIR::TryCatch.new(MIR::Ident.new("result"), MIR::Lit.new("0"), nil)
    expect(e.emit(node)).to eq("(result catch 0)")
  end

  it "emits conditional expression" do
    node = MIR::Conditional.new(MIR::Ident.new("flag"), MIR::Lit.new("1"), MIR::Lit.new("0"))
    expect(e.emit(node)).to eq("(if (flag) 1 else 0)")
  end

  it "emits address-of" do
    expect(e.emit(MIR::AddressOf.new(MIR::Ident.new("val")))).to eq("&val")
  end

  it "emits deref" do
    expect(e.emit(MIR::Deref.new(MIR::Ident.new("ptr")))).to eq("ptr.*")
  end

  it "emits optional unwrap" do
    expect(e.emit(MIR::OptionalUnwrap.new(MIR::Ident.new("maybe")))).to eq("maybe.?")
  end

  it "emits integer range literals as CheatLib.IntRange" do
    node = MIR::RangeLit.new(MIR::Lit.new("0"), MIR::Lit.new("10"), :Int64)
    expect(e.emit(node)).to eq("CheatLib.IntRange{ .start = 0, .end = 10 }")
  end

  it "emits float range literals as CheatLib.Range" do
    s = MIR::Cast.new(MIR::Cast.new(MIR::Lit.new("0"), nil, :floatFromInt), "f64", :as)
    f = MIR::Cast.new(MIR::Cast.new(MIR::Lit.new("10"), nil, :floatFromInt), "f64", :as)
    node = MIR::RangeLit.new(s, f, :Float64)
    result = e.emit(node)
    expect(result).to include("CheatLib.Range{")
    expect(result).not_to include("@floatFromInt(@as(f64")
  end

  it "emits items access (safe)" do
    node = MIR::ItemsAccess.new(MIR::Ident.new("list"), true)
    expect(e.emit(node)).to include("@hasField")
    expect(e.emit(node)).to include(".items")
  end

  it "emits items access (direct)" do
    node = MIR::ItemsAccess.new(MIR::Ident.new("list"), false)
    expect(e.emit(node)).to eq("list.items")
  end

  # =========================================================================
  # Memory operations
  # =========================================================================

  describe "HeapCreate" do
    it "emits heap allocation + init pattern" do
      node = MIR::HeapCreate.new("MyStruct", MIR::Ident.new("value"), :heap, "blk_f")
      zig = e.emit(node)
      expect(zig).to include("try rt.heapAlloc().create(MyStruct)")
      expect(zig).to include("errdefer rt.heapAlloc().destroy(__p)")
      expect(zig).to include("__p.* = value")
      expect(zig).to include("break :blk_f __p")
    end
  end

  describe "DupeSlice" do
    it "emits heap dupe" do
      node = MIR::DupeSlice.new(MIR::Ident.new("src"), :heap)
      expect(e.emit(node)).to eq("@as([]const u8, try rt.heapAlloc().dupe(u8, src))")
    end

    it "emits frame dupe" do
      node = MIR::DupeSlice.new(MIR::Ident.new("src"), :frame)
      expect(e.emit(node)).to eq("@as([]const u8, try rt.frameAlloc().dupe(u8, src))")
    end
  end

  describe "AllocSlice" do
    it "emits typed slice allocation" do
      node = MIR::AllocSlice.new("i64", MIR::Lit.new("100"), :heap)
      expect(e.emit(node)).to eq("try rt.heapAlloc().alloc(i64, 100)")
    end
  end

  describe "Cleanup" do
    it "emits unguarded defer for list" do
      entry = CleanupEntry.from({ kind: :uniform, zig_type: "CheatLib.ArrayListUnmanaged(i64)", alloc: :frame, has_moved_guard: false })
      node = MIR::Cleanup.new("nums", entry)
      zig = e.emit(node)
      expect(zig).to start_with("defer ")
      expect(zig).to include("defer CheatLib.cleanup(@TypeOf(nums), rt.frameAlloc(), &nums);")
      expect(zig).not_to include("_moved")
    end

    it "emits guarded defer for heap string" do
      entry = CleanupEntry.from({ kind: :heap_string, alloc: :heap, has_moved_guard: true })
      node = MIR::Cleanup.new("name", entry)
      zig = e.emit(node)
      # Post-collapse: heap strings route through CheatLib.cleanup shim
      # ([]const u8 arm calls alloc.free internally with an empty-string
      # guard). One unified emit form across all cleanup kinds.
      expect(zig).to include("var name_moved = false;")
      expect(zig).to include("defer if (!name_moved) CheatLib.cleanup(@TypeOf(name), rt.heapAlloc(), &name);")
    end

    it "terminates deferred guarded-if bodies but not deferred blocks" do
      guarded = MIR::DeferStmt.new(MIR::IfStmt.new(
        MIR::Ident.new("ready"),
        [MIR::Set.new(MIR::Ident.new("ready"), MIR::Lit.new("false"))],
        nil,
      ))
      block = MIR::DeferStmt.new(MIR::ScopeBlock.new([
        MIR::Set.new(MIR::Ident.new("ready"), MIR::Lit.new("false")),
      ]))

      expect(e.emit(guarded)).to eq("defer if (ready) {\nready = false;\n};")
      expect(e.emit(block)).to eq("defer {\nready = false;\n}")
    end

    it "emits resource cleanup" do
      entry = CleanupEntry.from({
        kind: :resource,
        alloc: :heap,
        has_moved_guard: false,
        resource_close_plan: Schemas::ResourceClosePlan.method("deinit"),
      })
      node = MIR::Cleanup.new("conn", entry)
      zig = e.emit(node)
      expect(zig).to include("defer conn.deinit();")
    end

    it "emits direct resource cleanup with the active runtime binding" do
      e.rt_name = "__ctx_9.rt"
      entry = CleanupEntry.build(
        :resource,
        alloc: :heap,
        has_moved_guard: false,
        resource_close_plan: Schemas::ResourceClosePlan.method("deinit", runtime_heap_alloc_args: 1),
      )

      zig = e.emit_direct_cleanup("__ctx_9.file", entry)

      expect(zig).to eq("__ctx_9.file.deinit(__ctx_9.rt.heapAlloc());")
    end

    it "emits structural rc release and function resource cleanup at the final edge" do
      release = MIR::RcRelease.new(
        MIR::FieldGet.new(MIR::Ident.new("ctx"), "shared"),
        "Payload",
        "arcRelease",
        MIR::FieldGet.new(MIR::Ident.new("ctx"), "alloc"),
      )
      expect(e.emit(release)).to eq("CheatLib.arcRelease(Payload, ctx.alloc, ctx.shared)")

      e.rt_name = "rt"
      entry = CleanupEntry.build(
        :resource,
        alloc: :heap,
        has_moved_guard: false,
        resource_close_plan: Schemas::ResourceClosePlan.function("closeHandle", runtime_heap_alloc_args: 1),
      )
      expect(e.emit_direct_cleanup("handle", entry)).to eq("closeHandle(handle, rt.heapAlloc());")
    end

    it "emits direct guarded cleanup with an allocator override" do
      entry = CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: true)

      zig = e.emit_direct_cleanup("__ctx_4.owned", entry, alloc_override: "__ctx_4.alloc")

      expect(zig).to eq(
        "if (!__ctx_4.owned_moved) CheatLib.cleanup(@TypeOf(__ctx_4.owned), __ctx_4.alloc, &__ctx_4.owned);"
      )
    end

    it "emits direct rc cleanup with releaseFields" do
      entry = CleanupEntry.build(
        :rc,
        alloc: :heap,
        has_moved_guard: false,
        rc_alloc: :frame,
        base_zig: "User",
        needs_release_fields: true,
      )

      zig = e.emit_direct_cleanup("owner", entry)

      expect(zig).to include("CheatLib.cleanup(@TypeOf(owner), rt.frameAlloc(), &owner);")
      expect(zig).to include("CheatLib.releaseFields(User, rt.frameAlloc(), owner.ctrl.data.*);")
    end

    it "emits pool cleanup" do
      entry = CleanupEntry.from({ kind: :uniform, zig_type: "CheatLib.Pool(User, 100)", alloc: :heap, has_moved_guard: false })
      node = MIR::Cleanup.new("pool", entry)
      zig = e.emit(node)
      # Post-collapse: pool routes through CheatLib.cleanup shim (Pool arm
      # calls ptr.deinit(alloc) internally). One emit form across all
      # collection shapes.
      expect(zig).to include("defer CheatLib.cleanup(@TypeOf(pool), rt.heapAlloc(), &pool);")
    end

    it "emits rc cleanup with release fields" do
      entry = CleanupEntry.from({ kind: :rc, zig_type: "CheatLib.Rc(User)", alloc: :heap,
                has_moved_guard: false, rc_variant: nil, rc_alloc: :heap,
                base_zig: "User", needs_release_fields: true })
      node = MIR::Cleanup.new("user_rc", entry)
      zig = e.emit(node)
      expect(zig).to include("CheatLib.cleanup(@TypeOf(user_rc), rt.heapAlloc(), &user_rc)")
      expect(zig).to include("CheatLib.releaseFields(User, rt.heapAlloc(), user_rc.ctrl.data.*)")
    end

    it "emits rc cleanup with release fields AND moved guard" do
      # Pins the guarded branch of the :rc releaseFields side-channel:
      # has_moved_guard=true makes the post-cleanup releaseFields wrap in
      # `if (!name_moved)`. Without this spec the guarded arm was dead.
      entry = CleanupEntry.from({ kind: :rc, zig_type: "CheatLib.Rc(User)", alloc: :heap,
                has_moved_guard: true, rc_variant: nil, rc_alloc: :heap,
                base_zig: "User", needs_release_fields: true })
      node = MIR::Cleanup.new("user_rc", entry)
      zig = e.emit(node)
      expect(zig).to include("CheatLib.cleanup(@TypeOf(user_rc), rt.heapAlloc(), &user_rc)")
      expect(zig).to include("defer if (!user_rc_moved) CheatLib.releaseFields(User, rt.heapAlloc(), user_rc.ctrl.data.*)")
    end

    it "emits locked cleanup" do
      entry = CleanupEntry.from({ kind: :uniform, zig_type: "CheatLib.Locked(Counter)", alloc: :heap, has_moved_guard: false })
      node = MIR::Cleanup.new("counter", entry)
      zig = e.emit(node)
      expect(zig).to include("defer CheatLib.cleanup(@TypeOf(counter), rt.heapAlloc(), &counter);")
    end
  end

  describe "MoveMark" do
    it "emits moved flag set" do
      expect(e.emit(MIR::MoveMark.new("result"))).to eq("result_moved = true;")
    end
  end

  describe "DeepCopy" do
    it "emits string copy via dupeValue with explicit []const u8 type" do
      node = MIR::DeepCopy.new(MIR::Ident.new("src"), "[]const u8", nil, :full_value, :heap)
      expect(node.copy_shape).to eq(:slice)
      expect(e.emit(node)).to include("try CheatLib.dupeValue([]const u8, __copy_src, rt.heapAlloc())")
    end

    it "emits union copy via dupeValue with explicit union type" do
      node = MIR::DeepCopy.new(MIR::Ident.new("val"), "Result", nil, :full_value, :heap)
      expect(node.copy_shape).to eq(:value)
      expect(e.emit(node)).to include("try CheatLib.dupeValue(Result, __copy_src, rt.heapAlloc())")
    end

    it "emits slice copy via CheatLib.dupeValue (subsumes the old :list_shallow / :list_deep strategies)" do
      # Lower_copy now stamps zig_type = "[]ElemT" and strategy :full_value
      # for any list/slice COPY. CheatLib.dupeValue's slice arm handles
      # both shallow (Copy elements -> @memcpy) and deep (heap-owning
      # elements -> recursive dupeValue) internally.
      node = MIR::DeepCopy.new(MIR::Ident.new("items"), "[]i64", "i64", :full_value, :heap)
      expect(node.copy_shape).to eq(:slice)
      expect(e.emit(node)).to include("try CheatLib.dupeValue([]i64, __copy_src, rt.heapAlloc())")

      node = MIR::DeepCopy.new(MIR::Ident.new("items"), "[]Value", "Value", :full_value, :heap)
      expect(node.copy_shape).to eq(:slice)
      expect(e.emit(node)).to include("try CheatLib.dupeValue([]Value, __copy_src, rt.heapAlloc())")
    end

    it "emits passthrough for value types as a comptime-evaluated inline expression" do
      node = MIR::DeepCopy.new(MIR::Ident.new("n"), nil, nil, :passthrough, nil)
      expect(node.copy_shape).to eq(:inferred)
      expect(e.emit(node)).to eq("(if (@typeInfo(@TypeOf(n)) == .pointer) n.* else n)")
    end

    it "emits pointer-shaped full copies from the explicit MIR shape" do
      node = MIR::DeepCopy.new(MIR::Ident.new("ptr"), "*Payload", nil, :full_value, :heap)
      expect(node.copy_shape).to eq(:pointer)
      expect(e.emit(node)).to include("try CheatLib.dupeValue(@TypeOf(ptr), __copy_src, rt.heapAlloc())")
    end
  end

  describe "ContainerInit" do
    it "emits pool init" do
      node = MIR::ContainerInit.new("Pool(User)", :pool, :heap, 64)
      expect(e.emit(node)).to eq("try Pool(User).initCapacity(rt.heapAlloc(), 64)")
    end

    it "emits empty list" do
      node = MIR::ContainerInit.new("CheatLib.ArrayListUnmanaged(i64)", :array_list_empty, nil, nil)
      expect(e.emit(node)).to eq("@as(CheatLib.ArrayListUnmanaged(i64), .empty)")
    end

    it "emits structural empty containers without type-prefix inspection" do
      node = MIR::ContainerInit.new("Set(i64)", :set_empty, nil, nil)
      expect(e.emit(node)).to eq("Set(i64){}")
    end

    it "emits map with allocator" do
      node = MIR::ContainerInit.new("StringMap(i64)", :map_bare, :heap, nil)
      expect(e.emit(node)).to eq("StringMap(i64){ .alloc = rt.heapAlloc() }")
    end
  end

  describe "CapWrap" do
    it "emits local create" do
      node = MIR::CapWrap.new(MIR::Ident.new("val"), "Counter", :local, nil, nil, nil, :heap)
      expect(e.emit(node)).to eq("try CheatLib.localCreate(Counter, rt.heapAlloc(), val)")
    end

    it "emits sync-only (locked)" do
      node = MIR::CapWrap.new(MIR::Ident.new("val"), "Counter", :sync_only, "lockedCreate", nil, nil, :heap)
      expect(e.emit(node)).to eq("try CheatLib.lockedCreate(Counter, rt.heapAlloc(), val)")
    end

    it "emits own-only (arc)" do
      node = MIR::CapWrap.new(MIR::Ident.new("val"), "Counter", :own_only, nil, nil, "arcCreate", :heap)
      expect(e.emit(node)).to eq("try CheatLib.arcCreate(Counter, rt.heapAlloc(), val)")
    end

    it "emits both sync + ownership" do
      node = MIR::CapWrap.new(MIR::Ident.new("val"), "Counter", :both,
        "lockedCreate", "CheatLib.Locked(Counter)", "arcCreate", :heap)
      zig = e.emit(node)
      expect(zig).to include("CheatLib.lockedCreate(Counter, rt.heapAlloc(), val)")
      expect(zig).to include("rt.heapAlloc().destroy(__cap_inner)")
      expect(zig).to include("CheatLib.arcCreate(CheatLib.Locked(Counter), rt.heapAlloc(), __cap_val)")
    end
  end

  describe "RcRetain" do
    it "emits arc retain" do
      node = MIR::RcRetain.new(MIR::Ident.new("ref"), "User", "arcRetain")
      expect(e.emit(node)).to eq("CheatLib.arcRetain(User, ref)")
    end
  end

  describe "SharePromote" do
    it "emits Rc to Arc promotion with Rc release" do
      node = MIR::SharePromote.new(MIR::Ident.new("ref"), "User", :heap)
      zig = e.emit(node)

      expect(zig).to include("const __share_src = ref;")
      expect(zig).to include("CheatLib.dupeValue(User, __share_src.ctrl.data.*, rt.heapAlloc())")
      expect(zig).to include("CheatLib.rcRelease(User, rt.heapAlloc(), __share_src);")
      expect(zig).to include("CheatLib.arcCreate(User, rt.heapAlloc(), __share_val)")
    end
  end

  describe "MakeList" do
    it "emits makeList with items" do
      node = MIR::MakeList.new("i64", [MIR::Lit.new("1"), MIR::Lit.new("2")], :frame)
      expect(e.emit(node)).to eq("try CheatLib.makeList(i64, rt.frameAlloc(), &.{ 1, 2 })")
    end

    it "emits makeList empty" do
      node = MIR::MakeList.new("i64", [], :frame)
      expect(e.emit(node)).to eq("try CheatLib.makeList(i64, rt.frameAlloc(), &.{})")
    end
  end

  describe "TypeSentinel" do
    it "emits numeric sentinels through ZigType predicates" do
      expect(e.emit(MIR::TypeSentinel.new(:max, "f64"))).to eq("std.math.floatMax(f64)")
      expect(e.emit(MIR::TypeSentinel.new(:min, "i64"))).to eq("std.math.minInt(i64)")
      expect(e.emit(MIR::TypeSentinel.new(:max, "Custom"))).to eq("std.math.floatMax(f64)")
    end
  end

  describe "Frame operations" do
    it "emits frame save" do
      expect(e.emit(MIR::FrameSave.new("rt"))).to eq("const frame_mark = rt.saveFrameMark();")
    end

    it "emits frame restore" do
      expect(e.emit(MIR::FrameRestore.new("rt"))).to eq("defer rt.restoreFrameMark(frame_mark);")
    end

  end

  # =========================================================================
  # Verification-only nodes emit nothing
  # =========================================================================

  it "emits nil for AllocMark" do
    expect(e.emit(MIR::AllocMark.new("x", :frame, Type.new(:String)))).to be_nil
  end

  it "emits nil for ReturnMark" do
    expect(e.emit(MIR::ReturnMark.new(["x", "y"]))).to be_nil
  end

  it "emits nil for ReassignMark" do
    expect(e.emit(MIR::ReassignMark.new("x", :heap))).to be_nil
  end

  it "emits nil for FieldCleanupMark" do
    expect(e.emit(MIR::FieldCleanupMark.new("user", "name", :heap))).to be_nil
  end

  # =========================================================================
  # Defer and errdefer
  # =========================================================================

  it "emits defer with simple statement" do
    node = MIR::DeferStmt.new(MIR::MethodCall.new(MIR::Ident.new("allocator"), "free", [MIR::Ident.new("buf")], false))
    expect(e.emit(node)).to eq("defer allocator.free(buf);")
  end

  it "emits errdefer" do
    node = MIR::ErrDeferStmt.new(MIR::MethodCall.new(MIR::Ident.new("allocator"), "free", [MIR::Ident.new("buf")], false))
    expect(e.emit(node)).to eq("errdefer allocator.free(buf);")
  end

  it "rejects raw string defer bodies" do
    expect { MIR::DeferStmt.new("allocator.free(buf)") }
      .to raise_error(TypeError, /MIR::DeferStmt body must be structural MIR/)
    expect { MIR::ErrDeferStmt.new("allocator.free(buf)") }
      .to raise_error(TypeError, /MIR::ErrDeferStmt body must be structural MIR/)
  end

  # =========================================================================
  # Expression as statement
  # =========================================================================

  it "emits expression statement" do
    node = MIR::ExprStmt.new(MIR::Call.new("doWork", [], false), false)
    expect(e.emit(node)).to eq("doWork();")
  end

  it "emits discarded expression" do
    node = MIR::ExprStmt.new(MIR::Call.new("compute", [], false), true)
    expect(e.emit(node)).to eq("_ = compute();")
  end

  # =========================================================================
  # Noop
  # =========================================================================

  it "emits nil for Noop" do
    expect(e.emit(MIR::Noop.new("placeholder"))).to be_nil
  end

  # =========================================================================
  # Raw string rejection
  # =========================================================================

  it "rejects raw strings" do
    expect { e.emit("already_zig_code") }
      .to raise_error(/MIREmitter cannot emit raw Zig strings/)
  end

  it "emits empty string for nil" do
    expect(e.emit(nil)).to eq("")
  end

  # =========================================================================
  # Nested / composed expressions
  # =========================================================================

  it "emits deeply nested expression tree" do
    # CheatLib.makeList(i64, rt.frameAlloc(), &.{ (a + 1), (b * 2) })
    node = MIR::MakeList.new("i64", [
      MIR::BinOp.new("+", MIR::Ident.new("a"), MIR::Lit.new("1")),
      MIR::BinOp.new("*", MIR::Ident.new("b"), MIR::Lit.new("2"))
    ], :frame)
    expect(e.emit(node)).to eq("try CheatLib.makeList(i64, rt.frameAlloc(), &.{ (a + 1), (b * 2) })")
  end

  it "emits HeapCreate with nested struct init" do
    inner = MIR::StructInit.new("Node", [
      { name: "value", value: MIR::Lit.new("42") },
      { name: "next", value: MIR::Lit.new("null") }
    ])
    node = MIR::HeapCreate.new("Node", inner, :heap, "blk_indirect")
    zig = e.emit(node)
    expect(zig).to include("try rt.heapAlloc().create(Node)")
    expect(zig).to include("__p.* = Node{ .value = 42, .next = null }")
    expect(zig).to include("break :blk_indirect __p")
  end

  describe "edge coverage" do
    def intrinsic_sig(**emit_kwargs)
      FunctionSignature.new(
        params: [],
        return_type: Type.new(:Void),
        intrinsic: true,
        emit: IntrinsicEmit.new(**emit_kwargs)
      )
    end

    def return_action(value = MIR::Ident.new("error.Stop"))
      MIR::FailureAction.new(
        kind: MIR::FailureActionKind::Return,
        error_type: :LockTimeout,
        error_kind: :Transient,
        default_message: "lock timeout",
        line: "9",
        rt_name: "rt",
        return_value: value,
      )
    end

    it "emits miscellaneous dispatch-only expression nodes" do
      expect(e.emit(MIR::TryOrPanic.new(MIR::Call.new("fallible", [], false), "boom")))
        .to eq("fallible() catch @panic(\"boom\")")
      expect(e.emit(MIR::UnionPayloadGet.new(MIR::Ident.new("result"), :Ok)))
        .to eq("(switch (result) { .Ok => |payload| payload, else => unreachable })")
      expect(e.emit(MIR::UnionVariantGet.new(MIR::TryExpr.new(MIR::Call.new("load", [], false)), "Ok", nil)))
        .to eq("(try load()).Ok")
      expect(e.emit(MIR::HasField.new(MIR::Ident.new("item"), "value")))
        .to eq("@hasField(@TypeOf(item), \"value\")")
    end

    it "emits sort statements" do
      node = MIR::Sort.new(
        "i64",
        MIR::Ident.new("items"),
        MIR::FieldGet.new(MIR::Ident.new("a"), "score"),
        MIR::FieldGet.new(MIR::Ident.new("b"), "score"),
      )

      zig = e.emit(node)
      expect(zig).to include("std.mem.sort(i64, items")
      expect(zig).to include("return a.score < b.score;")
    end

    it "emits break expressions without statement punctuation" do
      expect(e.emit(MIR::BreakExpr.new("blk", MIR::Ident.new("result"))))
        .to eq("break :blk result")
      expect(e.emit(MIR::BreakExpr.new(nil, nil))).to eq("break")
    end

    it "emits success-only reassignment cleanup for try-catch fallback to the old value" do
      value = MIR::TryCatch.new(MIR::Call.new("replace", [], false), MIR::Ident.new("buf"), nil)
      node = MIR::ReassignWithCleanup.new("buf", value, "[]const u8", :heap)
      zig = e.emit(node)

      expect(zig).to include("const __new_buf_opt: ?[]const u8 = (replace() catch null);")
      expect(zig).to include("if (__new_buf_opt) |__new_buf_val|")
      expect(zig).to include("buf = __new_buf_val;")
      expect(e.send(:reassign_success_only_expr, node)).to eq(value.expr)
    end

    it "substitutes sharded direct map templates and allocator metadata" do
      sig = intrinsic_sig(
        zig: "{target}.put({index}, {value}, {alloc})",
        shard_direct_zig: "{target}.direct({shard_idx}, {shard_key}, {index}, {value}, {key_zig}, {val_zig}, {alloc})",
      )
      node = MIR::ShardedMapPut.new(
        MIR::Ident.new("map"),
        MIR::Ident.new("key"),
        MIR::Ident.new("val"),
        MIR::Ident.new("idx"),
        MIR::Ident.new("shard_key"),
        :string_map,
        sig,
        Type.new(:String),
        Type.new(:Int64),
        MIR::InlineAllocMetadata.new(alloc: :frame),
        :shard_direct_zig,
      )

      expect(e.emit(node)).to eq("map.direct(idx, shard_key, key, val, []const u8, i64, rt.frameAlloc())")
    end

    it "reports missing sharded map templates loudly" do
      sig = intrinsic_sig(zig: "{target}.get({index})")
      node = MIR::ShardedMapGet.new(
        MIR::Ident.new("map"),
        MIR::Ident.new("key"),
        nil,
        nil,
        :string_map,
        sig,
        nil,
        nil,
        MIR::InlineAllocMetadata.new,
        :shard_direct_zig,
      )

      expect { e.emit(node) }.to raise_error(/ShardedMap: op has no :shard_direct_zig template/)
    end

    it "emits snapshot multi transactions through the conflict wrapper" do
      action = MIR::FailureAction.new(
        kind: MIR::FailureActionKind::Return,
        error_type: :UpdateRetriesExhausted,
        error_kind: :Transient,
        default_message: "conflict",
        line: "0",
        rt_name: "rt",
        return_value: MIR::Ident.new("error.Conflict"),
      )
      node = MIR::SnapshotMultiTxn.new(
        [MIR::Ident.new("left"), MIR::Ident.new("right")],
        "rt",
        :heap,
        ["left_view"],
        [MIR::Set.new(MIR::Ident.new("left_view.value"), MIR::Lit.new("1"))],
        action,
        nil,
        nil,
      )

      zig = e.emit(node)
      expect(zig).to include("CheatLib.versionedUpdateMulti(.{ left, right }, rt, rt.heapAlloc()")
      expect(zig).to include("const left_view = views[0];")
      expect(zig).to include("left_view.value = 1;")
      expect(zig).to include("error.UpdateRetriesExhausted")
      expect(zig).to include("return error.Conflict;")
    end

    it "emits WITH MATCH dispatch arms with preludes" do
      node = MIR::WithMatchDispatch.new(
        MIR::Ident.new("cell"),
        "x",
        false,
        "rt",
        [
          MIR::WithMatchArm.new(
            family: :LOCKED,
            guard_var: "__guard",
            body: [MIR::ExprStmt.new(MIR::Call.new("use", [MIR::Ident.new("x")], false), false)],
          ),
          MIR::WithMatchArm.new(
            family: :ATOMIC,
            guard_var: "__unused",
            body: [MIR::ExprStmt.new(MIR::Call.new("use", [MIR::Ident.new("cell")], false), false)],
          ),
        ],
      )

      zig = e.emit(node)
      expect(zig).to include("if (comptime @hasField(CheatLib.WithMatchInner(@TypeOf(cell)), \"mutex\"))")
      expect(zig).to include("var __guard = ")
      expect(zig).to include(".*.acquire();")
      expect(zig).to include("else if (comptime @hasDecl(CheatLib.WithMatchInner(@TypeOf(cell)), \"cmpxchgStrong\"))")
      expect(zig).to include("const x = ")
      expect(zig).to include("_ = &cell;")
    end

    it "covers polymorphic flow termination helpers" do
      expect(e.send(:flow_body_terminates?, [MIR::ReturnStmt.new(MIR::Ident.new("value"))])).to be true
      expect(e.send(:flow_body_terminates?, [
        MIR::ScopeBlock.new([MIR::ReturnStmt.new(nil)]),
      ])).to be true
      expect(e.send(:flow_body_terminates?, [
        MIR::ExprStmt.new(MIR::Call.new("tick", [], false), false),
      ])).to be false
      expect(e.send(:flow_body_terminates?, [
        MIR::IfStmt.new(
          MIR::Ident.new("cond"),
          [MIR::ReturnStmt.new(nil)],
          [MIR::ReturnStmt.new(nil)],
        ),
      ])).to be true
      expect(e.send(:flow_body_terminates?, [
        MIR::IfStmt.new(
          MIR::Ident.new("cond"),
          [MIR::ExprStmt.new(MIR::Call.new("tick", [], false), false)],
          [MIR::ReturnStmt.new(nil)],
        ),
      ])).to be false
      expect(e.send(:flow_body_terminates?, [
        MIR::IfStmt.new(
          MIR::Ident.new("cond"),
          [MIR::ReturnStmt.new(nil)],
          [],
        ),
      ])).to be false
    end

    it "wraps snapshot conflicts with retry loops" do
      action = MIR::FailureAction.new(
        kind: MIR::FailureActionKind::Return,
        error_type: :AtomicConflict,
        error_kind: :Transient,
        default_message: "atomic CAS retries exhausted",
        line: "0",
        rt_name: "rt",
        return_value: MIR::Ident.new("error.Stop"),
      )
      zig = e.send(:wrap_conflict_handler, "cell.update()", action, 3, "AtomicConflict")
      expect(zig).to include("__snap_retry: while (true)")
      expect(zig).to include("error.AtomicConflict")
      expect(zig).to include("if (__retry + 1 < 3) continue;")
      expect(zig).to include("return error.Stop;")
    end

    it "emits index inserts with frame and custom allocator expressions" do
      heap = e.emit(MIR::IndexInsert.new(
        MIR::Ident.new("map"),
        MIR::Ident.new("key"),
        MIR::Ident.new("value"),
        nil,
        "i64",
        nil,
      ))
      frame = e.emit(MIR::IndexInsert.new(
        MIR::Ident.new("map"),
        MIR::Ident.new("key"),
        MIR::Ident.new("value"),
        nil,
        "i64",
        :frame,
      ))
      custom = e.emit(MIR::IndexInsert.new(
        MIR::Ident.new("map"),
        MIR::Ident.new("key"),
        MIR::Ident.new("value"),
        "u16",
        "i64",
        :arena_alloc,
      ))

      expect(heap).to include("rt.heapAlloc().dupe(u8, key)")
      expect(frame).to include("rt.frameAlloc().dupe(u8, key)")
      expect(custom).to include("arena_alloc.dupe(u16, key)")
    end

    it "emits multi-binding if-bind with else fallback" do
      node = MIR::IfBindStmt.new(
        [
          { expr: MIR::Ident.new("maybe_a"), capture: "a" },
          { expr: MIR::Ident.new("maybe_b"), capture: "b" },
        ],
        [MIR::ReturnStmt.new(MIR::Ident.new("a"))],
        [MIR::ReturnStmt.new(MIR::Ident.new("b"))],
      )

      zig = e.emit(node)
      expect(zig).to include("var __ib_ok_1: bool = false;")
      expect(zig).to include("const a = maybe_a orelse break :__ib_1;")
      expect(zig).to include("const b = maybe_b orelse break :__ib_1;")
      expect(zig).to include("if (!__ib_ok_1)")
    end

    it "covers defensive strategy errors and passthrough cap wrapping" do
      expect { e.emit(MIR::DeepCopy.new(MIR::Ident.new("src"), nil, nil, :unknown, :heap)) }
        .to raise_error(/emit_deep_copy: unhandled strategy :unknown/)
      expect { e.emit(MIR::ContainerInit.new("Bad", :unknown, :heap, nil)) }
        .to raise_error(/emit_container_init: unhandled strategy :unknown/)
      expect(e.emit(MIR::CapWrap.new(MIR::Ident.new("val"), "Counter", :passthrough, nil, nil, nil, :heap)))
        .to eq("val")
      expect { e.emit(MIR::CapWrap.new(MIR::Ident.new("val"), "Counter", :unknown, nil, nil, nil, :heap)) }
        .to raise_error(/emit_cap_wrap: unhandled strategy :unknown/)
    end

    it "covers additional cast variants and invalid cast methods" do
      expect(e.emit(MIR::Cast.new(MIR::Ident.new("n"), nil, :floatCast))).to eq("@floatCast(n)")
      expect(e.emit(MIR::Cast.new(MIR::Ident.new("ptr"), "*u8", :ptrCast))).to eq("@ptrCast(ptr)")
      expect(e.emit(MIR::Cast.new(MIR::Ident.new("wide"), "u8", :truncate))).to eq("@truncate(wide)")
      expect { e.emit(MIR::Cast.new(MIR::Ident.new("x"), nil, :badCast)) }
        .to raise_error(/emit_cast: unknown method :badCast/)
    end

    it "covers fallback sentinels and block-shaped guarded defers" do
      expect(e.emit(MIR::SliceExpr.new(MIR::Ident.new("items"), MIR::Lit.new("1"), nil, nil)))
        .to eq("items[1..]")
      expect(e.emit(MIR::TypeSentinel.new(:min, "Custom"))).to eq("-std.math.floatMax(f64)")
      expect(e.send(:guarded_defer, "conn", "{\nconn.close();\n}", false))
        .to eq("defer {\nconn.close();\n}\n")
    end

    it "emits simple dispatcher-only statements and expressions through emit" do
      cleanup = CleanupEntry.from({ kind: :heap_string, alloc: :heap, has_moved_guard: false })

      expect(e.emit(MIR::Panic.new("stop"))).to eq("@panic(\"stop\");")
      expect(e.emit(MIR::TestPreamble.new(nil))).to include("const rt: *Runtime = &__rt_box")
      expect(e.emit(MIR::DebugOnly.new([MIR::ExprStmt.new(MIR::Call.new("trace", [], false), false)])))
        .to include("if (@import(\"builtin\").mode == .Debug)")
      expect(e.emit(MIR::SoaFieldAccess.new(MIR::Ident.new("rows"), "age"))).to eq("rows.data.items(.age)")
      expect(e.emit(MIR::Pipeline.new(nil, MIR::Call.new("pipeDone", [], false), nil, nil, nil, nil)))
        .to eq("pipeDone()")
      expect(e.emit(MIR::Comment.new("generated"))).to eq("// generated")
      expect(e.emit(MIR::Suppress.new("unused"))).to eq("_ = &unused;")
      expect(e.emit(MIR::PubConst.new("Answer", "42"))).to eq("pub const Answer = 42;")
      expect(e.emit(MIR::ErrCleanup.new("name", cleanup)))
        .to eq("errdefer CheatLib.cleanup(@TypeOf(name), rt.heapAlloc(), &name);\n")
      expect(e.emit(MIR::FreeSlice.new(MIR::Ident.new("buf"), :frame))).to eq("rt.frameAlloc().free(buf)")
      expect(e.emit(MIR::DestroyPtr.new(MIR::Ident.new("ptr"), :heap))).to eq("rt.heapAlloc().destroy(ptr)")
      expect(e.emit(MIR::RcDowngrade.new(MIR::Ident.new("ref"), "User", "arcDowngrade")))
        .to eq("CheatLib.arcDowngrade(User, ref)")
      expect(e.emit(MIR::WeakUpgrade.new(MIR::Ident.new("weak"), "User", "weakArcUpgrade")))
        .to eq("CheatLib.weakArcUpgrade(User, weak)")
      expect(e.emit(MIR::VoidLiteral.new)).to eq("{}")
      expect(e.emit(MIR::Comptime.new(MIR::Ident.new("T")))).to eq("comptime T")
      expect(e.emit(MIR::ListItems.new(MIR::Ident.new("items")))).to eq("items.items")
      expect(e.emit(MIR::ListLength.new(MIR::ListItems.new(MIR::Ident.new("items"))))).to eq("items.items.len")
      expect(e.emit(MIR::IterRange.new(MIR::Lit.new("0"), MIR::Ident.new("n"), nil))).to eq("0..n")
      expect(e.emit(MIR::Undef.new(nil))).to eq("undefined")
      expect(e.emit(MIR::Undef.new("i64"))).to eq("@as(i64, undefined)")
    end

    it "emits direct dispatcher statement helpers through emit" do
      cleanup = CleanupEntry.from({ kind: :heap_string, alloc: :heap, has_moved_guard: false })
      assert_node = MIR::AssertRaisesCheck.new(
        MIR::Call.new("mayFail", [], false),
        "rt",
        :Transient,
        :Timeout,
      )
      push = MIR::BatchWindowPush.new(
        "window",
        MIR::Ident.new("item"),
        "__batch",
        "i64",
        "out",
        MIR::Call.new("sum", [MIR::Ident.new("__batch")], false),
        :frame,
      )
      flush = MIR::BatchWindowFlush.new(
        "window",
        "__batch",
        "i64",
        "out",
        MIR::Call.new("sum", [MIR::Ident.new("__batch")], false),
        :heap,
      )
      discard = MIR::DiscardOwned.new(MIR::Call.new("makeString", [], true), cleanup, "[]const u8")

      assert_zig = e.emit(assert_node)
      expect(assert_zig).to include("if (mayFail()) |_|")
      expect(assert_zig).to include("ASSERT_RAISES: expected Transient error")
      expect(assert_zig).to include("rt.__error.matchesKind(.Transient)")
      expect(assert_zig).to include("rt.__error.matchesName(@intFromEnum(ErrorName.Timeout))")

      expect(e.emit(push)).to include("if (try window.push(item)) |__batch_slice|")
      expect(e.emit(push)).to include("try out.append(rt.frameAlloc(), __batch_val);")
      expect(e.emit(flush)).to include("if (try window.flush()) |__batch_slice|")
      expect(e.emit(flush)).to include("try out.append(rt.heapAlloc(), __batch_val);")
      expect(e.emit(discard)).to include("var __discard_")
      expect(e.emit(discard)).to include("try makeString()")
      expect(e.emit(discard)).to include("defer CheatLib.cleanup(@TypeOf(__discard_")
    end

    it "emits direct dispatcher control-flow helpers through emit" do
      variant = MIR::ThunkVariant.new(
        name: "even",
        param_fields: [MIR::ThunkFrameField.new(name: "n", type_info: Type.new(:Int64))],
      )
      arm = MIR::MutualThunkArm.new(
        variant_name: "even",
        base_cases: [MIR::ThunkBaseCase.new(cond: MIR::BinOp.new("==", MIR::FieldGet.new(MIR::Ident.new("f"), "n"), MIR::Lit.new("0")), value: MIR::Lit.new("true"))],
        target_variant: "even",
        target_arg_inits: [MIR::ThunkFrameInit.new(field_name: "n", value: MIR::BinOp.new("-", MIR::FieldGet.new(MIR::Ident.new("f"), "n"), MIR::Lit.new("1")))],
      )
      thunk = MIR::MutualThunkTrampoline.new(
        fn_name: "even",
        return_type: Type.new(:Bool),
        variants: [variant],
        initial_variant: "even",
        initial_fields: [MIR::ThunkFrameInit.new(field_name: "n", value: MIR::Ident.new("n"))],
        arms: [arm],
        yield_policy: :check,
      )
      snapshot = MIR::SnapshotTransaction.new(
        MIR::CapabilityUnwrap.new(MIR::Ident.new("cell")),
        "rt",
        :heap,
        "view",
        Type.new(:Counter),
        [MIR::Set.new(MIR::FieldGet.new(MIR::Ident.new("view"), "value"), MIR::Lit.new("1"))],
        return_action,
        nil,
        nil,
        false,
      )

      thunk_zig = e.emit(thunk)
      expect(thunk_zig).to include("const Frame = union(enum)")
      expect(thunk_zig).to include(".even => |f|")
      expect(thunk_zig).to include("return true;")
      expect(thunk_zig).to include("current = .{ .even = .{ .n = (f.n - 1) } };")

      snapshot_zig = e.emit(snapshot)
      expect(snapshot_zig).to include(".*.update(rt, rt.heapAlloc()")
      expect(snapshot_zig).to include("fn run(view: *Counter) void")
      expect(snapshot_zig).to include("view.value = 1;")
      expect(snapshot_zig).to include("error.UpdateRetriesExhausted => { return error.Stop; }")
    end

    it "emits polymorphic and lock dispatcher helpers through emit" do
      mutate = MIR::PolymorphicMutate.new(
        MIR::Ident.new("cell"),
        "rt",
        "view",
        Type.new(:Counter),
        [MIR::Set.new(MIR::FieldGet.new(MIR::Ident.new("view"), "value"), MIR::Lit.new("2"))],
      )
      flow = MIR::PolymorphicMutateFlow.new(
        MIR::Ident.new("cell"),
        "rt",
        "view",
        Type.new(:Counter),
        Type.new(:Int64),
        [MIR::ReturnStmt.new(MIR::FieldGet.new(MIR::Ident.new("view"), "value"))],
        MIR::Ident.new("ok"),
        [MIR::PolymorphicFlowSignal.new(:skip_no_commit, nil)],
      )
      entry = MIR::SortedLockAcquireEntry.new(
        index: 0,
        alias_name: "guarded",
        guard_var: "__guard",
        held_var: "__held",
        lock_expr: MIR::Ident.new("lock"),
        address_expr: MIR::AddressOf.new(MIR::Ident.new("lock")),
        method_name: "acquire",
      )
      sorted = MIR::SortedLockAcquire.new([entry], nil, [], [], nil, "__LINE__", "__locks", "rt", false)
      fallible = MIR::FallibleLockBinding.new(
        "__guard",
        "guarded",
        MIR::LockAcquire.new(MIR::Ident.new("lock"), :locked, true),
        return_action,
        nil,
        [:LockTimeout],
        [],
        "__LINE__",
        "__lock_acquire",
        "rt",
      )

      mutate_zig = e.emit(mutate)
      expect(mutate_zig).to include("try CheatLib.polymorphicMutate(cell, rt")
      expect(mutate_zig).to include("fn run(view: *Counter) void")
      expect(mutate_zig).to include("view.value = 2;")

      flow_zig = e.emit(flow)
      expect(flow_zig).to include("const __PolyFlow = struct")
      expect(flow_zig).to include("try CheatLib.polymorphicMutateFlow(cell, rt")
      expect(flow_zig).to include("if (!(ok))")
      expect(flow_zig).to include(".ret_commit, .ret_no_commit => return __poly_flow.ret")

      sorted_zig = e.emit(sorted)
      expect(sorted_zig).to include("var __guard: @TypeOf(lock.acquire()) = undefined;")
      expect(sorted_zig).to include("const __ptrs = [_]usize{ @intFromPtr(&lock) };")
      expect(sorted_zig).to include("0 => __guard = lock.acquire(),")
      expect(sorted_zig).to include("const guarded = __guard.get();")

      fallible_zig = e.emit(fallible)
      expect(fallible_zig).to include("var __guard = __lock_acquire: {")
      expect(fallible_zig).to include("if (lock.acquireOrErr()) |__g|")
      expect(fallible_zig).to include("error.LockTimeout => { return error.Stop; }")
      expect(fallible_zig).to include("const guarded = __guard.get();")
    end

    it "emits callable expression dispatcher helpers through emit" do
      registry = MIR::RegistryCall.new(
        entry: intrinsic_sig(zig: "try registryCall({0}, {alloc})"),
        args: [MIR::RegistryCallArg.new(expr: MIR::Ident.new("value"), coerce_type: :Int64)],
        reason: "spec",
        allocs: MIR::InlineAllocMetadata.new(alloc: :heap),
      )
      indexed = MIR::IndexedStore.new(
        target: MIR::Ident.new("map"),
        index: MIR::Ident.new("key"),
        value: MIR::Ident.new("value"),
        entry: intrinsic_sig(zig: "try {target}.put({index}, {value}, {alloc})"),
        template_kind: :zig,
        map_kind: :string_map,
        allocs: MIR::InlineAllocMetadata.new(alloc: :frame),
        key_type: Type.new(:String),
        value_type: Type.new(:Int64),
      )
      lambda_fn = MIR::FnDef.new(
        "__lambda",
        [MIR::Param.new("x", "i64")],
        "i64",
        [MIR::ReturnStmt.new(MIR::Ident.new("x"))],
        :private,
        false,
        nil,
      )
      extern = MIR::ExternTrampoline.new(
        id: 7,
        callee_name: "nativeCall",
        runtime_args: [MIR::ExternTrampolineArg.new(expr: MIR::Ident.new("x"), field_type: Type.new(:Int64))],
        return_type: Type.new(:Int64),
        stdlib_def: FunctionSignature.borrowing_intrinsic,
      )
      observable = MIR::ObservableConsumerSpawn.new(
        id: 4,
        acc_name: "acc",
        source_name: "gen",
        acc_type: Type.new(:Int64),
        runtime_name: "rt",
        task_config_variant: "Medium",
        stdlib_def: FunctionSignature.borrowing_intrinsic,
        ownership_contract: MIR::OwnershipContract.empty,
        body: [MIR::ExprStmt.new(MIR::Call.new("publish", [MIR::Ident.new("acc"), MIR::Ident.new("gen")], false), false)],
      )
      inline = MIR::InlineBc.new(:add, [MIR::Ident.new("left"), MIR::Ident.new("right")], intrinsic_sig(zig: "CheatLib.add({0}, {1})"))

      expect(e.emit(registry)).to eq("try registryCall(@as(i64, value), rt.heapAlloc())")
      expect(e.emit(indexed)).to eq("try map.put(key, value, rt.frameAlloc())")
      expect(e.emit(MIR::LambdaExpr.new(lambda_fn, []))).to include("&(struct { fn __lambda(x: i64) i64")

      extern_zig = e.emit(extern)
      expect(extern_zig).to include("const __Ext7 = struct")
      expect(extern_zig).to include("nativeCall(f.a0)")
      expect(extern_zig).to include("rt.onRootStack")
      expect(extern_zig).to include("break :blk_ext7 __ext7_frame.ret;")

      observable_zig = e.emit(observable)
      expect(observable_zig).to include("const __ObsConsumerCtx4 = struct")
      expect(observable_zig).to include("defer ctx.acc.finish();")
      expect(observable_zig).to include("publish(ctx.acc, ctx.gen);")
      expect(observable_zig).to include("try CheatHeader.spawnObservableConsumerCtx")

      expect(e.emit(inline)).to eq("CheatLib.add(left, right)")
    end

    it "emits sharded concurrent each through emit" do
      node = MIR::ShardConcurrentEach.new(
        id: 2,
        map_expr: MIR::Ident.new("counts"),
        map_var_name: "counts",
        map_type: Type.new(:Any),
        key_type: Type.new(:String),
        shard_count: 2,
        start_expr: MIR::Lit.new("0"),
        finish_expr: MIR::Ident.new("limit"),
        inclusive: false,
        capacity_expr: MIR::Lit.new("8"),
        batch_size_expr: MIR::Lit.new("2"),
        task_config_variant: "Medium",
        producer_key_body: [MIR::Let.new("__sh2_key", MIR::Ident.new("source_key"), false, nil, nil)],
        body: [MIR::ExprStmt.new(MIR::Call.new("consume", [MIR::Ident.new("__sh2_key")], false), false)],
        key_allocates_frame: true,
        body_allocates_frame: true,
      )

      zig = e.emit(node)
      expect(zig).to include("const __sh2_map = &counts;")
      expect(zig).to include("var __sh2_chans: [2]CheatLib.BoundedChannel(__ShWork2)")
      expect(zig).to include("try CheatHeader.spawnBest")
      expect(zig).to include("const __sh2_key_mark = rt.saveLoopMark();")
      expect(zig).to include("const __sh2_body_mark = __rt.saveLoopMark();")
      expect(zig).to include("consume(__sh2_key);")
    end

    it "emits remaining direct expression wrappers through emit" do
      expect(e.emit(MIR::CapabilityLockTarget.new(MIR::Ident.new("cell"), false, false))).to eq("cell")
      expect(e.emit(MIR::CapabilityLockTarget.new(MIR::Ident.new("cell"), true, false))).to eq("cell.ctrl.data.*")
      expect(e.emit(MIR::CapabilityLockAddress.new(MIR::Ident.new("cell"), false))).to eq("&cell")
      expect(e.emit(MIR::CapabilityLockAddress.new(MIR::Ident.new("cell"), true))).to eq("cell.ctrl.data")
      expect(e.emit(MIR::LockAcquire.new(MIR::Ident.new("lock"), :locked, false))).to eq("lock.acquire()")
      expect(e.emit(MIR::LockAcquire.new(MIR::Ident.new("lock"), :write_locked, true))).to eq("lock.writeOrErr()")
      expect(e.emit(MIR::TailCall.new("nextStep", [MIR::Ident.new("state"), MIR::Lit.new("1")])))
        .to eq("@call(.always_tail, nextStep, .{state, 1})")
      expect(e.emit(MIR::ConcatStr.new([MIR::Lit.new("\"a\""), MIR::Ident.new("b")], :frame, nil)))
        .to eq("try std.mem.concat(rt.frameAlloc(), u8, &.{ \"a\", b })")
      expect(e.emit(MIR::ListItems.new(MIR::TryExpr.new(MIR::Call.new("loadList", [], false)))))
        .to eq("(try loadList()).items")
      expect(e.emit(MIR::ListLength.new(MIR::TryExpr.new(MIR::Call.new("loadList", [], false)))))
        .to eq("(try loadList()).len")
      expect(e.emit(MIR::IfOptional.new(
        MIR::Ident.new("maybe"),
        "value",
        MIR::Ident.new("value"),
        MIR::Lit.new("0"),
      ))).to eq("(if (maybe) |value| value else 0)")
      owned_slice = e.emit(MIR::OwnedSlice.new(MIR::Ident.new("list"), :heap))
      expect(owned_slice).to include("try __x.toOwnedSlice(rt.heapAlloc())")
      expect(owned_slice).to include("break :blk_owned_slice_")
    end

    it "emits structural union matches through emit" do
      node = MIR::UnionMatchStmt.new(
        MIR::Ident.new("result"),
        [
          MIR::UnionMatchArm.new(
            variant: "Ok",
            payload: "value",
            body: [MIR::ReturnStmt.new(MIR::Ident.new("value"))],
          ),
          MIR::UnionMatchArm.new(
            variant: "Err",
            payload: nil,
            body: [MIR::ReturnStmt.new(MIR::Lit.new("0"))],
          ),
        ],
        [MIR::Panic.new("unknown")],
      )

      zig = e.emit(node)
      expect(zig).to include("switch (result)")
      expect(zig).to include(".Ok => |value|")
      expect(zig).to include("return value;")
      expect(zig).to include(".Err =>")
      expect(zig).to include("else =>")
      expect(zig).to include("@panic(\"unknown\");")
    end

    it "keeps verification-only ownership facts non-emitting through emit" do
      expect(e.emit(MIR::TransferMark.new("name", :return, :heap))).to be_nil
      expect(e.emit(MIR::OwnedCreate.new("name", :heap, Type.new(:String), "source"))).to be_nil
      expect(e.emit(MIR::OwnedDestroy.new("name", :heap, "source"))).to be_nil
      expect(e.emit(MIR::OwnedTransfer.new("name", :return, "source"))).to be_nil
      expect(e.emit(MIR::OwnedBorrow.new("name", "source"))).to be_nil
      expect(e.emit(MIR::OwnedStore.new("name", "target", :heap, "source"))).to be_nil
      expect(e.emit(MIR::OwnedReturn.new("name", "source"))).to be_nil
    end

    it "reports unknown structural nodes with their class" do
      expect { e.emit(Object.new) }.to raise_error(/MIREmitter: unknown node type Object/)
    end
  end
end
