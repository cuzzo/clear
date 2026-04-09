require "rspec"
require_relative "../src/mir"
require_relative "../src/mir_emitter"

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

  it "emits a function reference" do
    expect(e.emit(MIR::FnRef.new("handler"))).to eq("&handler")
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

  # =========================================================================
  # Variable declarations
  # =========================================================================

  it "emits const declaration" do
    node = MIR::Let.new("x", MIR::Lit.new("42"), false, nil, nil)
    expect(e.emit(node)).to eq("const x = 42;")
  end

  it "emits var declaration with annotation" do
    node = MIR::Let.new("count", MIR::Lit.new("0"), true, "i64", "_ = &count;")
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
    node = MIR::ReassignWithCleanup.new("buf", MIR::Lit.new("new_val"), "[]const u8", "rt.heapAlloc()")
    zig = e.emit(node)
    expect(zig).to include("const __new_buf = new_val;")
    expect(zig).to include("CheatLib.cleanup([]const u8, rt.heapAlloc(), &buf);")
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
      [{ pattern: ".North", body: [MIR::ReturnStmt.new(MIR::Lit.new("0"))] },
       { pattern: ".South", body: [MIR::ReturnStmt.new(MIR::Lit.new("1"))] }],
      [MIR::ReturnStmt.new(MIR::Lit.new("-1"))]
    )
    zig = e.emit(node)
    expect(zig).to include("switch (dir)")
    expect(zig).to include(".North =>")
    expect(zig).to include(".South =>")
    expect(zig).to include("else =>")
  end

  it "emits if-chain" do
    node = MIR::IfChain.new(
      [{ cond: MIR::BinOp.new("==", MIR::Ident.new("x"), MIR::Lit.new("1")),
         body: [MIR::ReturnStmt.new(MIR::Lit.new("\"one\""))] }],
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

  it "emits range literal" do
    node = MIR::RangeLit.new(MIR::Lit.new("0"), MIR::Lit.new("10"))
    expect(e.emit(node)).to eq("CheatLib.Range{ .start = 0, .end = 10 }")
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
      node = MIR::HeapCreate.new("MyStruct", MIR::Ident.new("value"), "rt.heapAlloc()", "blk_f")
      zig = e.emit(node)
      expect(zig).to include("try rt.heapAlloc().create(MyStruct)")
      expect(zig).to include("errdefer rt.heapAlloc().destroy(__p)")
      expect(zig).to include("__p.* = value")
      expect(zig).to include("break :blk_f __p")
    end
  end

  describe "DupeSlice" do
    it "emits heap dupe" do
      node = MIR::DupeSlice.new(MIR::Ident.new("src"), "rt.heapAlloc()")
      expect(e.emit(node)).to eq("try rt.heapAlloc().dupe(u8, src)")
    end

    it "emits frame dupe" do
      node = MIR::DupeSlice.new(MIR::Ident.new("src"), "rt.frameAlloc()")
      expect(e.emit(node)).to eq("try rt.frameAlloc().dupe(u8, src)")
    end
  end

  describe "AllocSlice" do
    it "emits typed slice allocation" do
      node = MIR::AllocSlice.new("i64", MIR::Lit.new("100"), "rt.heapAlloc()")
      expect(e.emit(node)).to eq("try rt.heapAlloc().alloc(i64, 100)")
    end
  end

  describe "Cleanup" do
    it "emits unguarded defer for list" do
      entry = { kind: :list, zig_type: "CheatLib.ArrayListUnmanaged(i64)", alloc: :frame, has_moved_guard: false }
      node = MIR::Cleanup.new("nums", entry)
      zig = e.emit(node)
      expect(zig).to include("defer CheatLib.cleanup(CheatLib.ArrayListUnmanaged(i64), rt.frameAlloc(), &nums);")
      expect(zig).not_to include("_moved")
    end

    it "emits guarded defer for heap string" do
      entry = { kind: :heap_string, alloc: :heap, has_moved_guard: true }
      node = MIR::Cleanup.new("name", entry)
      zig = e.emit(node)
      expect(zig).to include("var name_moved = false;")
      expect(zig).to include("defer if (!name_moved) rt.heapAlloc().free(name);")
    end

    it "emits resource cleanup" do
      entry = { kind: :resource, alloc: :heap, has_moved_guard: false, resource_close_zig: "{0}.deinit()" }
      node = MIR::Cleanup.new("conn", entry)
      zig = e.emit(node)
      expect(zig).to include("defer conn.deinit();")
    end

    it "emits pool cleanup" do
      entry = { kind: :pool, alloc: :heap, has_moved_guard: false }
      node = MIR::Cleanup.new("pool", entry)
      zig = e.emit(node)
      expect(zig).to include("defer pool.deinit(rt.heapAlloc());")
    end

    it "emits rc cleanup with release fields" do
      entry = { kind: :rc, zig_type: "CheatLib.Rc(User)", alloc: :heap,
                has_moved_guard: false, rc_variant: nil, rc_alloc: :heap,
                base_zig: "User", needs_release_fields: true }
      node = MIR::Cleanup.new("user_rc", entry)
      zig = e.emit(node)
      expect(zig).to include("CheatLib.cleanup(CheatLib.Rc(User), rt.heapAlloc(), &user_rc)")
      expect(zig).to include("CheatLib.releaseFields(User, rt.heapAlloc(), user_rc.ctrl.data.*)")
    end

    it "emits locked cleanup" do
      entry = { kind: :locked, zig_type: "CheatLib.Locked(Counter)", alloc: :heap, has_moved_guard: false }
      node = MIR::Cleanup.new("counter", entry)
      zig = e.emit(node)
      expect(zig).to include("defer CheatLib.lockedDestroy(CheatLib.Locked(Counter), rt.heapAlloc(), counter);")
    end
  end

  describe "MoveMark" do
    it "emits moved flag set" do
      expect(e.emit(MIR::MoveMark.new("result"))).to eq("result_moved = true;")
    end
  end

  describe "EscapePromote" do
    it "emits list promotion" do
      node = MIR::EscapePromote.new("items", "CheatLib.ArrayListUnmanaged(i64)", :list, nil, "rt")
      expect(e.emit(node)).to eq("try CheatLib.promoteList(i64, rt, &items);")
    end

    it "emits string_map promotion" do
      node = MIR::EscapePromote.new("cache", nil, :string_map, nil, "rt")
      expect(e.emit(node)).to eq("cache.alloc = rt.heapAlloc();")
    end

    it "emits generic promotion" do
      node = MIR::EscapePromote.new("val", "User", :generic, nil, "rt")
      expect(e.emit(node)).to eq("try CheatLib.promote(User, rt, &val);")
    end

    it "returns nil for pending strategies" do
      %i[container_store ret_fields bg_string catch_string_dupe or_fallback_dupe hpt_string_dupe hpt_promote].each do |s|
        node = MIR::EscapePromote.new("x", nil, s, nil, "rt")
        expect(e.emit(node)).to be_nil
      end
    end
  end

  describe "DeepCopy" do
    it "emits string copy" do
      node = MIR::DeepCopy.new(MIR::Ident.new("src"), nil, nil, :string, "rt.heapAlloc()")
      expect(e.emit(node)).to eq("try rt.heapAlloc().dupe(u8, src)")
    end

    it "emits union copy" do
      node = MIR::DeepCopy.new(MIR::Ident.new("val"), "Result", nil, :union, "rt.heapAlloc()")
      expect(e.emit(node)).to eq("try CheatLib.dupeUnionValue(Result, val, rt.heapAlloc())")
    end

    it "emits shallow list copy" do
      node = MIR::DeepCopy.new(MIR::Ident.new("items"), nil, "i64", :list_shallow, "rt.heapAlloc()")
      zig = e.emit(node)
      expect(zig).to include("@memcpy(__buf, __src)")
      expect(zig).to include("rt.heapAlloc().alloc(i64, __src.len)")
    end

    it "emits deep list copy with union elements" do
      node = MIR::DeepCopy.new(MIR::Ident.new("items"), nil, "Value", :list_deep, "rt.heapAlloc()")
      zig = e.emit(node)
      expect(zig).to include("dupeUnionValue(Value, __src[__i], rt.heapAlloc())")
      expect(zig).to include("errdefer rt.heapAlloc().free(__buf)")
    end

    it "emits passthrough for value types" do
      node = MIR::DeepCopy.new(MIR::Ident.new("n"), nil, nil, :passthrough, nil)
      expect(e.emit(node)).to eq("n")
    end
  end

  describe "ContainerInit" do
    it "emits pool init" do
      node = MIR::ContainerInit.new("Pool(User)", :pool, "rt.heapAlloc()", 64)
      expect(e.emit(node)).to eq("try Pool(User).initCapacity(rt.heapAlloc(), 64)")
    end

    it "emits empty list" do
      node = MIR::ContainerInit.new("CheatLib.ArrayListUnmanaged(i64)", :list_empty, nil, nil)
      expect(e.emit(node)).to eq("CheatLib.ArrayListUnmanaged(i64){}")
    end

    it "emits map with allocator" do
      node = MIR::ContainerInit.new("StringMap(i64)", :map_bare, "rt.heapAlloc()", nil)
      expect(e.emit(node)).to eq("StringMap(i64){ .alloc = rt.heapAlloc() }")
    end
  end

  describe "CapWrap" do
    it "emits local create" do
      node = MIR::CapWrap.new(MIR::Ident.new("val"), "Counter", :local, nil, nil, nil, "rt.heapAlloc()")
      expect(e.emit(node)).to eq("try CheatLib.localCreate(Counter, rt.heapAlloc(), val)")
    end

    it "emits sync-only (locked)" do
      node = MIR::CapWrap.new(MIR::Ident.new("val"), "Counter", :sync_only, "lockedCreate", nil, nil, "rt.heapAlloc()")
      expect(e.emit(node)).to eq("try CheatLib.lockedCreate(Counter, rt.heapAlloc(), val)")
    end

    it "emits own-only (arc)" do
      node = MIR::CapWrap.new(MIR::Ident.new("val"), "Counter", :own_only, nil, nil, "arcCreate", "rt.heapAlloc()")
      expect(e.emit(node)).to eq("try CheatLib.arcCreate(Counter, rt.heapAlloc(), val)")
    end

    it "emits both sync + ownership" do
      node = MIR::CapWrap.new(MIR::Ident.new("val"), "Counter", :both,
        "lockedCreate", "CheatLib.Locked(Counter)", "arcCreate", "rt.heapAlloc()")
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

  describe "MakeList" do
    it "emits makeList with items" do
      node = MIR::MakeList.new("i64", [MIR::Lit.new("1"), MIR::Lit.new("2")], "rt.frameAlloc()")
      expect(e.emit(node)).to eq("try CheatLib.makeList(i64, rt.frameAlloc(), &.{ 1, 2 })")
    end

    it "emits makeList empty" do
      node = MIR::MakeList.new("i64", [], "rt.frameAlloc()")
      expect(e.emit(node)).to eq("try CheatLib.makeList(i64, rt.frameAlloc(), &.{})")
    end
  end

  describe "Frame operations" do
    it "emits frame save" do
      expect(e.emit(MIR::FrameSave.new("rt"))).to eq("const frame_mark = rt.saveFrameMark();")
    end

    it "emits frame restore" do
      expect(e.emit(MIR::FrameRestore.new("rt"))).to eq("defer rt.restoreFrameMark(frame_mark);")
    end

    it "emits preserve and rewind" do
      node = MIR::PreserveAndRewind.new(MIR::Ident.new("result"), "rt")
      expect(e.emit(node)).to eq("try rt.preserveAndRewind(frame_mark, result)")
    end
  end

  # =========================================================================
  # Verification-only nodes emit nothing
  # =========================================================================

  it "emits nil for AllocMark" do
    expect(e.emit(MIR::AllocMark.new("x", :list, :frame))).to be_nil
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
    node = MIR::DeferStmt.new(MIR::RawZig.new("allocator.free(buf)", "cleanup"))
    expect(e.emit(node)).to eq("defer allocator.free(buf);")
  end

  it "emits errdefer" do
    node = MIR::ErrDeferStmt.new(MIR::RawZig.new("allocator.free(buf)", "cleanup"))
    expect(e.emit(node)).to eq("errdefer allocator.free(buf);")
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
  # RawZig and Noop
  # =========================================================================

  it "emits raw Zig" do
    node = MIR::RawZig.new("@setEvalBranchQuota(100000);", "prologue")
    expect(e.emit(node)).to eq("@setEvalBranchQuota(100000);")
  end

  it "emits nil for Noop" do
    expect(e.emit(MIR::Noop.new("placeholder"))).to be_nil
  end

  # =========================================================================
  # String passthrough
  # =========================================================================

  it "passes through raw strings" do
    expect(e.emit("already_zig_code")).to eq("already_zig_code")
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
    ], "rt.frameAlloc()")
    expect(e.emit(node)).to eq("try CheatLib.makeList(i64, rt.frameAlloc(), &.{ (a + 1), (b * 2) })")
  end

  it "emits HeapCreate with nested struct init" do
    inner = MIR::StructInit.new("Node", [
      { name: "value", value: MIR::Lit.new("42") },
      { name: "next", value: MIR::Lit.new("null") }
    ])
    node = MIR::HeapCreate.new("Node", inner, "rt.heapAlloc()", "blk_indirect")
    zig = e.emit(node)
    expect(zig).to include("try rt.heapAlloc().create(Node)")
    expect(zig).to include("__p.* = Node{ .value = 42, .next = null }")
    expect(zig).to include("break :blk_indirect __p")
  end
end
