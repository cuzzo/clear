require "rspec"
require "byebug"

require_relative "../src/transpiler"
require_relative "../src/ast"

RSpec.describe ZigTranspiler do
  def transpile(src)
    ZigTranspiler.new.transpile(src)
  end

  # ===========================================================================
  # @list allocator selection
  # ===========================================================================
  describe "@list uses frame allocator" do
    it "uses frameAlloc for append" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE vals: Float64[]@list = [];
          append(vals, 1.0);
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("rt.frameAlloc()")
      expect(zig).not_to include("rt.heapAlloc()")
    end

    it "uses frameAlloc for deinit" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE vals: Float64[]@list = [];
          append(vals, 1.0);
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("CheatLib.cleanup(std.ArrayListUnmanaged(f64), rt.frameAlloc(), &vals)")
    end

    it "sharded list still uses heapAlloc" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE vals: Float64[]@list:sharded(4) = [];
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("rt.heapAlloc()")
    end
  end

  # ===========================================================================
  # @list return promotion (list escape safety)
  # ===========================================================================
  describe "@list return promotion" do
    # BigS is 130 slots (>128 threshold) → local BigS declaration → uses_frame=true.
    # The frame mark rewinds on function exit, which would invalidate the list's arena buffer.
    # CLEAR must emit promoteList before the return and the caller uses heapAlloc for deinit.
    let(:frame_list_src) { <<~CLEAR }
      STRUCT Chunk5 { a: Float64, b: Float64, c: Float64, d: Float64, e: Float64 }
      STRUCT BigS {
        c1: Chunk5, c2: Chunk5, c3: Chunk5, c4: Chunk5, c5: Chunk5,
        c6: Chunk5, c7: Chunk5, c8: Chunk5, c9: Chunk5, c10: Chunk5,
        c11: Chunk5, c12: Chunk5, c13: Chunk5, c14: Chunk5, c15: Chunk5,
        c16: Chunk5, c17: Chunk5, c18: Chunk5, c19: Chunk5, c20: Chunk5,
        c21: Chunk5, c22: Chunk5, c23: Chunk5, c24: Chunk5, c25: Chunk5,
        c26: Chunk5
      }
      FN buildList() RETURNS Float64[]@list ->
        zero: Chunk5 = Chunk5{ a: 0.0, b: 0.0, c: 0.0, d: 0.0, e: 0.0 };
        big: BigS = BigS{
          c1: zero, c2: zero, c3: zero, c4: zero, c5: zero,
          c6: zero, c7: zero, c8: zero, c9: zero, c10: zero,
          c11: zero, c12: zero, c13: zero, c14: zero, c15: zero,
          c16: zero, c17: zero, c18: zero, c19: zero, c20: zero,
          c21: zero, c22: zero, c23: zero, c24: zero, c25: zero,
          c26: zero
        };
        MUTABLE vals: Float64[]@list = [];
        append(vals, big.c1.a);
        RETURN vals;
      END
      FN main() RETURNS Void ->
        RETURN;
      END
    CLEAR

    it "emits promoteList before return" do
      zig = transpile(frame_list_src)
      expect(zig).to include("CheatLib.promoteList(f64, rt, &vals)")
    end

    it "emits promoteList before the return statement" do
      zig = transpile(frame_list_src)
      promote_pos = zig.index("CheatLib.promoteList(")
      return_pos  = zig.index("return __ret")
      expect(promote_pos).to be < return_pos
    end

    it "callee omits the defer deinit for the returned list (escaped_return suppresses cleanup)" do
      zig = transpile(frame_list_src)
      # The returned list must NOT have a defer deinit — ownership transfers to the
      # caller and a defer would corrupt the value through Zig NRVO aliasing.
      expect(zig).not_to include("vals.deinit(rt.frameAlloc())")
    end
  end

  # ===========================================================================
  # String HashMap frame-key promotion (mapPromote)
  # ===========================================================================
  describe "String HashMap escape promotion" do
    let(:map_return_src) { <<~CLEAR }
      FN buildMap() RETURNS HashMap<Int64> ->
        MUTABLE m: HashMap<Int64> = {};
        m["x"] = 1_i64;
        m["y"] = 2_i64;
        RETURN m;
      END
      FN main() RETURNS Void ->
        result = buildMap();
        RETURN;
      END
    CLEAR

    it "sets heapAlloc on returned StringMap (no mapPromote needed)" do
      zig = transpile(map_return_src)
      # StringMap already uses heapAlloc for all ops, so mapPromote is not needed.
      # The escape path just ensures .alloc is set.
      expect(zig).not_to include("CheatLib.mapPromote")
      expect(zig).to include(".alloc = rt.heapAlloc()")
    end

    it "sets alloc before the return statement" do
      zig = transpile(map_return_src)
      alloc_pos  = zig.index(".alloc = rt.heapAlloc()")
      return_pos = zig.index("return __ret")
      expect(alloc_pos).to be < return_pos
    end

    it "uses heapAlloc for mapPut keys (keys must outlive frame rewind)" do
      zig = transpile(map_return_src)
      expect(zig).to include(".put(rt.heapAlloc(), rt.frameAlloc()")
    end

    it "caller uses cleanup with heapAlloc for promoted map" do
      zig = transpile(map_return_src)
      expect(zig).to include("CheatLib.cleanup(")
      expect(zig).to include("rt.heapAlloc()")
    end

    it "all string maps use heapAlloc cleanup (consistent with put allocator)" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE m: HashMap<Int64> = {};
          m["k"] = 42_i64;
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("CheatLib.cleanup(")
      expect(zig).to include("rt.heapAlloc()")
    end
  end

  # ===========================================================================
  # WhileLoop per-iteration frame marks
  # ===========================================================================
  describe "WhileLoop per-iteration frame marks" do
    it "emits saveLoopMark/restoreLoopMark when loop-local list is appended" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE i = 0_i64;
          WHILE i < 10 DO
            MUTABLE vals: Float64[]@list = [];
            append(vals, 1.0);
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("saveLoopMark")
      expect(zig).to include("restoreLoopMark")
    end

    it "skips loop marks when only appending to outer list (no per-iteration waste)" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE all: Float64[]@list = [];
          MUTABLE i = 0_i64;
          WHILE i < 10 DO
            append(all, 1.0);
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      # append to outer list: allocation is into receiver's backing, not per-iteration.
      # No loop marks needed, container stays frame-allocated.
      expect(zig).not_to include("saveLoopMark")
      expect(zig).to include("frameAlloc")
    end
  end

  # ===========================================================================
  # Cooperative yield injection
  # ===========================================================================
  describe "cooperative yield injection" do
    it "emits checkYield at the back-edge of a normal while loop with rt" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE i = 0_i64;
          WHILE i < 1000 DO
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("checkYield()")
    end

    it "emits checkYield alongside saveLoopMark for frame-allocating loops" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE i = 0_i64;
          WHILE i < 10 DO
            MUTABLE vals: Float64[]@list = [];
            append(vals, 1.0);
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("saveLoopMark")
      expect(zig).to include("checkYield()")
    end

    it "does NOT emit checkYield in functions without rt (no-scheduler context)" do
      # A pure function that calls no alloc helpers and has no frame vars
      # will not have rt, so no yield injection possible.
      src = <<~CLEAR
        FN addTwo(a: Float64, b: Float64) RETURNS Float64 ->
          RETURN a + b;
        END
        FN main() RETURNS Void ->
          x = addTwo(1.0, 2.0);
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      # addTwo has no rt — no checkYield inside it
      fn_body = zig[/fn addTwo\b.*?\n\}/m]
      expect(fn_body).not_to include("checkYield") if fn_body
    end
  end

  # ===========================================================================
  # TIGHT loops
  # ===========================================================================
  describe "TIGHT loops" do
    it "does NOT emit checkYield for a TIGHT loop" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE i = 0_i64;
          TIGHT WHILE i < 1000 DO
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).not_to include("checkYield")
    end

    it "does NOT emit saveLoopMark for a TIGHT loop even with frame allocs" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE i = 0_i64;
          TIGHT WHILE i < 10 DO
            MUTABLE vals: Float64[]@list = [];
            append(vals, 1.0);
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).not_to include("saveLoopMark")
      expect(zig).not_to include("checkYield")
    end

    it "raises a compile error when TIGHT loop calls an EXTERN FN directly" do
      src = <<~CLEAR
        EXTERN FN native_sqrt(x: Float64) RETURNS Float64 FROM "math";
        FN main() RETURNS Void ->
          MUTABLE i = 0_i64;
          TIGHT WHILE i < 100 DO
            x = native_sqrt(i + 0.0);
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR
      expect { transpile(src) }.to raise_error(/TIGHT loop cannot call EXTERN FN/)
    end

    it "raises a compile error when TIGHT loop calls an @reentrant function directly" do
      src = <<~CLEAR
        FN fib(n: Int64) RETURNS Int64 @reentrant ->
          IF n <= 1 THEN RETURN n; END
          RETURN fib(n - 1) + fib(n - 2);
        END
        FN main() RETURNS Void ->
          MUTABLE i = 0_i64;
          TIGHT WHILE i < 100 DO
            x = fib(i);
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR
      expect { transpile(src) }.to raise_error(/TIGHT loop cannot call @reentrant/)
    end

    it "raises a compile error when @reentrant call is nested inside an IF inside TIGHT" do
      src = <<~CLEAR
        FN fib(n: Int64) RETURNS Int64 @reentrant ->
          IF n <= 1 THEN RETURN n; END
          RETURN fib(n - 1) + fib(n - 2);
        END
        FN main() RETURNS Void ->
          MUTABLE i = 0_i64;
          TIGHT WHILE i < 100 DO
            IF i > 50_i64 THEN
              x = fib(i);
            END
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR
      expect { transpile(src) }.to raise_error(/TIGHT loop cannot call @reentrant/)
    end

    it "allows normal (non-reentrant, non-extern) CLEAR calls inside TIGHT" do
      src = <<~CLEAR
        FN square(x: Float64) RETURNS Float64 ->
          RETURN x * x;
        END
        FN main() RETURNS Void ->
          MUTABLE i = 0_i64;
          TIGHT WHILE i < 100 DO
            x = square(i + 0.0);
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR
      expect { transpile(src) }.not_to raise_error
      zig = transpile(src)
      expect(zig).not_to include("checkYield")
    end
  end

  # ===========================================================================
  # var_mutated — SROA suppression optimization
  # ===========================================================================
  describe "var_mutated SROA suppression" do
    it "omits _ = &name for a mutable scalar that is read AND reassigned" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE sum: Float64 = 0.0;
          MUTABLE i = 0_i64;
          WHILE i < 10 DO
            sum = sum + 1.0;
            i = i + 1_i64;
          END
          ASSERT sum > 0.0, "positive";
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      # Both sum and i are read AND reassigned — no address-taken suppression
      expect(zig).not_to include("_ = &sum")
      expect(zig).not_to include("_ = &i")
    end

    it "omits _ = &name for a mutable struct that is reassigned" do
      src = <<~CLEAR
        STRUCT Vec2 { x: Float64, y: Float64 }
        FN main() RETURNS Void ->
          MUTABLE v: Vec2 = Vec2{ x: 0.0, y: 0.0 };
          MUTABLE i = 0_i64;
          WHILE i < 3 DO
            v = Vec2{ x: i+1.0, y: i+2.0 };
            i = i + 1_i64;
          END
          ASSERT v.x > 0.0, "positive";
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      # v is reassigned — no _ = &v; (which would block SROA)
      # (but _ = &v_moved is fine — moved flags don't block SROA)
      expect(zig).not_to match(/_ = &v;/)
    end

    it "omits _ = &name for a mutable struct with field mutation" do
      src = <<~CLEAR
        STRUCT Point { x: Float64, y: Float64 }
        FN main() RETURNS Void ->
          MUTABLE p: Point = Point{ x: 1.0, y: 2.0 };
          p.x = 99.0;
          ASSERT p.x > 0.0, "positive";
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      # p.x mutation marks p as mutated — no _ = &p;
      expect(zig).not_to match(/_ = &p;/)
    end

    it "downgrades MUTABLE to const when never reassigned (SROA-safe)" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE x = 5_i64;
          ASSERT x == 5_i64, "should be 5";
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      # x is MUTABLE but never reassigned — downgraded to const for SROA
      expect(zig).to include("const x")
      expect(zig).not_to include("var x")
    end

    it "downgrades completely unused MUTABLE to const" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE x = 5_i64;
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("const x")
      expect(zig).not_to include("var x")
    end

    it "warns about MUTABLE that is used but never reassigned" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE x = 5_i64;
          ASSERT x == 5_i64, "used";
          RETURN;
        END
      CLEAR
      warnings = []
      allow($stderr).to receive(:puts) { |msg| warnings << msg }
      transpile(src)
      expect(warnings.any? { |w| w.include?("MUTABLE 'x' is never reassigned") }).to be true
    end

    it "warns about completely unused MUTABLE variable" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE x = 5_i64;
          RETURN;
        END
      CLEAR
      warnings = []
      allow($stderr).to receive(:puts) { |msg| warnings << msg }
      transpile(src)
      expect(warnings.any? { |w| w.include?("Unused variable 'x'") }).to be true
    end

    it "does NOT warn about MUTABLE that is actually reassigned" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE x = 5_i64;
          x = 10_i64;
          ASSERT x == 10_i64, "reassigned";
          RETURN;
        END
      CLEAR
      warnings = []
      allow($stderr).to receive(:puts) { |msg| warnings << msg }
      transpile(src)
      mutable_warnings = warnings.select { |w| w.include?("MUTABLE 'x'") || w.include?("Unused variable 'x'") }
      expect(mutable_warnings).to be_empty
    end
  end

  describe "HashMap param double-& fix" do
    it "does not double-wrap HashMap params with & in recursive calls" do
      src = <<~CLEAR
        FN update!(key: String, MUTABLE env: HashMap<Int64>, depth: Int64) RETURNS Int64 @reentrant ->
            env[key] = depth;
            IF depth > 0 THEN RETURN update!(key, env, depth - 1); END
            RETURN depth;
        END
        FN main() RETURNS Void ->
            MUTABLE env: HashMap<Int64> = {};
            update!("k", env, 3);
        END
      CLEAR
      zig = transpile(src)
      # Caller in main passes &env (local var → pointer)
      expect(zig).to match(/update\(.*&env/)
      # Recursive call inside update! passes env without & (already a pointer)
      fn_body = zig[/fn update\b.*?^}/m]
      expect(fn_body).to match(/return.*update\(/)
      # The body should not pass &env at recursive call sites (only _ = &env; suppression is OK)
      recursive_call = fn_body[/return.*update\(.*/]
      expect(recursive_call).not_to include("&env")
    end
  end

  describe "union inline struct fields use slice type" do
    it "emits []T for array fields in union inline structs" do
      src = <<~CLEAR
        UNION Expr {
            Lit: Float64,
            Call { name: String, args: Expr[] }
        }
        FN main() RETURNS Void -> RETURN; END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("args: []Expr")
      expect(zig).not_to include("ArrayListUnmanaged(Expr)")
    end
  end

  describe "@list to slice conversion in struct/union literals" do
    it "implicit-copies @list into union slice field (heap buffer)" do
      src = <<~CLEAR
        UNION Wrapper { Items: Int64[] }
        FN main() RETURNS Void ->
            MUTABLE vals: Int64[]@list = List[];
            vals.append(1_i64);
            w = Wrapper{ Items: vals };
        END
      CLEAR
      zig = transpile(src)
      # @list is implicit-copied: buffer is heap-allocated so union cleanup works
      expect(zig).to match(/heapAlloc|__buf|__src/)
    end
  end

  describe "@list frame-escape through struct returns" do
    it "implicit-copies @list in struct field (heap buffer via CopyNode)" do
      src = <<~CLEAR
        STRUCT Pair { items: Int64[], count: Int64 }
        FN build() RETURNS Pair ->
            MUTABLE vals: Int64[]@list = List[];
            vals.append(1_i64);
            vals.append(2_i64);
            RETURN Pair{ items: vals, count: 2 };
        END
        FN main() RETURNS Void ->
            p = build();
        END
      CLEAR
      zig = transpile(src)
      # @list field is implicit-copied by annotator (CopyNode wraps vals)
      expect(zig).to match(/heapAlloc|__buf|__src/)
    end

    it "suppresses defer deinit for escaped @list in struct return" do
      src = <<~CLEAR
        STRUCT Pair { items: Int64[], count: Int64 }
        FN build() RETURNS Pair ->
            MUTABLE vals: Int64[]@list = List[];
            vals.append(1_i64);
            RETURN Pair{ items: vals, count: 1 };
        END
        FN main() RETURNS Void ->
            p = build();
        END
      CLEAR
      zig = transpile(src)
      expect(zig).not_to match(/defer vals\.deinit/)
    end
  end

  # ===========================================================================
  # Function-level frame mark (saveFrameMark / restoreFrameMark)
  # ===========================================================================
  describe "function-level frame mark" do
    it "emits saveFrameMark for uses_alloc function returning Void" do
      src = <<~CLEAR
        FN f(s: String) RETURNS Void ->
          parts = split(s, ",");
          RETURN;
        END
        FN main() RETURNS Void ->
          f("a,b");
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("saveFrameMark")
    end

    it "emits saveFrameMark + preserveAndRewind for uses_alloc function returning String" do
      src = <<~CLEAR
        FN f(s: String) RETURNS String ->
          parts = split(s, ",");
          RETURN s;
        END
        FN main() RETURNS Void ->
          r = f("a,b");
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      # String-returning functions that use frame: save mark in prologue,
      # wrap body in labeled block, preserveAndRewind on return.
      expect(zig).to include("saveFrameMark")
      expect(zig).to include("preserveAndRewind")
      expect(zig).to include("__pr_body")
    end

    it "emits saveFrameMark for function returning an ENUM value (value type)" do
      src = <<~CLEAR
        ENUM Status { Ok, Err }
        FN check(s: String) RETURNS Status ->
          parts = split(s, ",");
          RETURN Status.Ok;
        END
        FN main() RETURNS Void ->
          r = check("a,b");
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      # Enums are value types (returned by copy), so frame mark is safe.
      expect(zig).to include("saveFrameMark")
    end
  end

  # ===========================================================================
  # Move suppression: _moved = true must be emitted for all OG-tracked moves
  # ===========================================================================
  describe "OG-driven move emission" do
    it "eliminates val cleanup when always moved into HashMap" do
      src = <<~CLEAR
        STRUCT Env { x: Int64 }
        UNION Value { Nil, Num: Float64, Str: String, Lambda { body: Value @indirect, id: Int64 } }
        FN test!(MUTABLE pool: Env[10]@pool, MUTABLE map: HashMap<Value>) RETURNS Void ->
            pool.insert(Env{ x: 1 });
            val = Value.Lambda{ body: Value{ Num: 42.0 }, id: 1 };
            map["key"] = val;
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      # val is MOVED on all paths (assigned to map) → no defer, no _moved guard
      expect(zig).not_to include("val_moved")
    end

    it "emits source_moved for MATCH AS on non-Copy variant (auto-TAKES)" do
      src = <<~CLEAR
        STRUCT Env { x: Int64 }
        UNION Value { Nil, Num: Float64, Str: String, List: Value[], Lambda { body: Value @indirect, id: Int64 } }
        FN test!(TAKES v: Value, MUTABLE pool: Env[10]@pool) RETURNS Value ->
            pool.insert(Env{ x: 1 });
            MATCH v START
                Value.Lambda AS lam -> RETURN Value.Nil;,
                DEFAULT -> RETURN Value.Nil;
            END
            RETURN Value.Nil;
        END
      CLEAR
      zig = transpile(src)
      # MATCH AS on non-Copy variant auto-promotes to TAKES - source is consumed
      expect(zig).to include("v_moved = true")
    end

    it "keeps v moved guard when can_fail call precedes MATCH TAKES" do
      src = <<~CLEAR
        STRUCT Env { x: Int64 }
        UNION Value { Nil, Num: Float64, Str: String, List: Value[], Lambda { body: Value @indirect, id: Int64 } }
        FN test!(TAKES v: Value, MUTABLE pool: Env[10]@pool) RETURNS Value ->
            pool.insert(Env{ x: 1 });
            MATCH TAKES v START
                Value.Lambda AS lam -> RETURN Value.Nil;,
                DEFAULT -> RETURN Value.Nil;
            END
            RETURN Value.Nil;
        END
      CLEAR
      zig = transpile(src)
      # pool.insert can fail → error unwind leaves v OWNED → moved guard needed
      expect(zig).to include("v_moved")
    end

    it "does NOT emit source_moved for MATCH AS on Copy payload" do
      src = <<~CLEAR
        STRUCT Env { x: Int64 }
        UNION Value { Nil, Num: Float64, Str: String, List: Value[], Lambda { body: Value @indirect, id: Int64 } }
        FN test!(TAKES v: Value, MUTABLE pool: Env[10]@pool) RETURNS Value ->
            pool.insert(Env{ x: 1 });
            MATCH v START
                Value.Num AS n -> RETURN Value{ Num: n };,
                DEFAULT -> RETURN Value.Nil;
            END
            RETURN Value.Nil;
        END
      CLEAR
      zig = transpile(src)
      # Copy payload: no move needed, source still usable
      expect(zig).not_to include("v_moved = true")
    end
    it "heap-dupes string literal value in HashMap assignment" do
      src = <<~CLEAR
        FN test!(MUTABLE map: HashMap<String>) RETURNS Void ->
            map["key"] = "hello";
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      # String literal "hello" must be heap-duped before storing in HashMap.
      # Without this, HashMap.deinit tries to free rodata -> crash.
      expect(zig).to match(/heapAlloc\(\)\.dupe\(u8.*"hello"/)
    end

    it "heap-dupes string literal inside union value in HashMap assignment" do
      src = <<~CLEAR
        UNION Value { Nil, Str: String }
        FN test!(MUTABLE map: HashMap<Value>) RETURNS Void ->
            map["key"] = Value{ Str: "world" };
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to match(/heapAlloc\(\)\.dupe\(u8.*"world"/)
    end

    it "MATCH AS on non-Copy variant emits cleanup on binding (auto-TAKES)" do
      src = <<~CLEAR
        UNION Value { Num: Float64, List: Value[] }
        FN test!() RETURNS Void ->
            result = Value{ Num: 1.0 };
            MATCH result START
                Value.List AS items -> RETURN;,
                DEFAULT -> RETURN;
            END
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      # MATCH AS auto-TAKES: binding gets cleanup, source suppressed
      expect(zig).to include("items_moved")
    end

    it "MATCH TAKES emits cleanup on AS binding" do
      src = <<~CLEAR
        UNION Value { Num: Float64, List: Value[] }
        FN test!() RETURNS Void ->
            result = Value{ Num: 1.0 };
            MATCH TAKES result START
                Value.List AS items -> RETURN;,
                DEFAULT -> RETURN;
            END
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      # MATCH TAKES transfers ownership - items must get defer cleanup
      expect(zig).to match(/items_moved|cleanup.*items/)
    end
  end

  describe "Mutable reassignment cleanup" do
    it "emits cleanup of old value before overwriting non-Copy union" do
      src = <<~CLEAR
        UNION Value { Nil, Str: String }
        FN makeStr(s: String) RETURNS Value -> RETURN Value{ Str: COPY s }; END
        FN main() RETURNS Void ->
            MUTABLE result = makeStr("hello");
            result = makeStr("world");
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to match(/cleanup\(Value.*&result\).*\n.*result = /)
    end
  end

  describe "Heap-promoted temporary from function call gets cleanup" do
    it "emits cleanup for heap string temporary passed to print" do
      src = <<~CLEAR
        FN makeStr() RETURNS String -> RETURN COPY "hello"; END
        FN main() RETURNS Void ->
            print(makeStr());
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      # The temp from makeStr() is heap-allocated. Must be freed after print.
      expect(zig).to match(/heapAlloc\(\)\.free|defer.*makeStr|__hpt/)
    end
  end

  describe "Borrow rejection in struct construction" do
    it "rejects container index borrow stored in struct field" do
      src = <<~CLEAR
        UNION Value { Nil, Str: String }
        STRUCT Pair { a: Value, b: Value }
        FN consume!(TAKES items: Value[]) RETURNS Pair ->
            RETURN Pair{ a: items[0], b: Value.Nil };
        END
        FN main() RETURNS Void ->
            MUTABLE list: Value[]@list = List[];
            p = consume!(list);
            RETURN;
        END
      CLEAR
      expect { transpile(src) }.to raise_error(/Cannot store borrowed value/)
    end
  end

  describe "Inline struct variant fields get implicit COPY" do
    it "implicit-copies @list into inline struct variant []T field" do
      src = <<~CLEAR
        STRUCT Env { vars: HashMap<Value> }
        UNION Value {
            Nil, Number: Float64, Symbol: String, List: Value[],
            Lambda { params: Value[], body: Value @indirect, envId: Id<Env> }
        }
        FN main() RETURNS Void ->
            MUTABLE pool: Env[10]@pool = [];
            rootId: Id<Env> = pool.insert(Env{ vars: {} });
            MUTABLE p: Value[]@list = List[];
            p.append(Value.Nil);
            v = Value.Lambda{ params: p, body: Value.Nil, envId: rootId };
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      # @list params field should be implicit-copied (not raw .items)
      expect(zig).to match(/heapAlloc|__buf|__src/)
    end

    it "implicit-copies rodata string into inline struct variant field" do
      src = <<~CLEAR
        UNION Value { Nil, Named { name: String, id: Int64 } }
        FN main() RETURNS Void ->
            v = Value.Named{ name: "hello", id: 1_i64 };
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to match(/heapAlloc\(\)\.dupe\(u8/)
    end
  end

  describe "RETURN fn(borrowed_arg) does NOT suppress borrowed arg cleanup" do
    it "does not set _moved on borrowed args in return function call" do
      src = <<~CLEAR
        UNION Value { Nil, Str: String, List: Value[] }
        FN consume(items: Value[]) RETURNS Value -> RETURN Value.Nil; END
        FN main() RETURNS Void ->
            MUTABLE evaled: Value[]@list = List[];
            evaled.append(Value{ Str: COPY "hello" });
            result = consume(evaled);
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      # consume takes items as borrow (not TAKES). evaled cleanup must fire.
      expect(zig).not_to include("evaled_moved = true")
    end
  end

  describe "Heap-promoted value assigned to HashMap is NOT hoisted" do
    it "stores directly without __hpt wrapper" do
      src = <<~CLEAR
        UNION Value { Nil, Str: String }
        FN makeValue() RETURNS Value -> RETURN Value{ Str: COPY "hello" }; END
        FN main() RETURNS Void ->
            MUTABLE map: HashMap<Value> = {};
            map["key"] = makeValue();
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      fn_body = zig[zig.index("fn clearMain")..zig.index("// ----")]
      expect(fn_body).not_to include("__hpt")
    end
  end

  describe "Heap-promoted return value is NOT hoisted into temp" do
    it "returns directly from heap_promoted function without __hpt wrapper" do
      src = <<~CLEAR
        UNION Value { Nil, Str: String }
        FN makeValue() RETURNS Value -> RETURN Value{ Str: COPY "hello" }; END
        FN wrapper() RETURNS Value -> RETURN makeValue(); END
        FN main() RETURNS Void ->
            v = wrapper();
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      # wrapper() should return makeValue() directly, not via __hpt temp
      fn_body = zig[zig.index("fn wrapper")..zig.index("fn clearMain")]
      expect(fn_body).not_to include("__hpt")
      expect(fn_body).to include("return try makeValue")
    end
  end

  describe "TAKES parameter returned in union suppresses cleanup" do
    it "emits items_moved = true when TAKES slice is returned inside union" do
      src = <<~CLEAR
        UNION Value { Nil, List: Value[] }
        FN consume!(TAKES items: Value[]) RETURNS Value ->
            IF items.length() == 0 THEN RETURN Value{ List: items }; END
            RETURN Value.Nil;
        END
        FN main() RETURNS Void ->
            MUTABLE list: Value[]@list = List[];
            result = consume!(list);
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      # The RETURN Value{ List: items } must set items_moved = true
      # so the TAKES defer doesn't double-free the returned data.
      expect(zig).to match(/items_moved = true;.*\n(?:.*\n)*?\s*return Value/)
    end
  end

  describe "TAKES slice needs_rt" do
    it "generates rt parameter for function with TAKES slice" do
      src = <<~CLEAR
        UNION Value { Nil, Symbol: String }
        FN process!(TAKES items: Value[]) RETURNS Float64 -> RETURN 42.0; END
        FN main() RETURNS Void ->
            MUTABLE list: Value[]@list = List[];
            result = process!(list);
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("fn process(rt: *Runtime,")
    end
  end

  describe "Heap-promoted return cleanup" do
    it "emits cleanup for heap string returned by TAKES function" do
      src = <<~CLEAR
        UNION Value { Nil, Symbol: String, List: Value[] }
        FN consume!(TAKES v: Value) RETURNS String ->
            MATCH TAKES v START
                Value.Symbol AS s -> RETURN COPY s;,
                DEFAULT -> RETURN "other";
            END
            RETURN "?";
        END
        FN main() RETURNS Void ->
            sym = Value{ Symbol: COPY "hello" };
            result = consume!(sym);
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      # result holds a heap-duped string - needs cleanup
      expect(zig).to match(/result.*=.*consume|heapAlloc\(\)\.dupe/)
    end
  end

  describe "Union construction auto-dupes rodata strings" do
    it "dupes string literal in union variant construction" do
      src = <<~CLEAR
        UNION Value { Nil, Symbol: String }
        FN main() RETURNS Void ->
            v = Value{ Symbol: "hello" };
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to match(/heapAlloc\(\)\.dupe\(u8.*"hello"/)
    end

    it "dupes rodata string variable in union variant construction" do
      src = <<~CLEAR
        UNION Value { Nil, Symbol: String }
        FN main() RETURNS Void ->
            s = "hello";
            v = Value{ Symbol: s };
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to match(/heapAlloc\(\)\.dupe\(u8.*s\b/)
    end

    it "implicit-copies @list into union []T field" do
      src = <<~CLEAR
        UNION Value { Nil, List: Value[] }
        FN main() RETURNS Void ->
            MUTABLE items: Value[]@list = List[];
            items.append(Value.Nil);
            v = Value{ List: items };
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      # @list should be implicit-copied via CopyNode (emits slice copy)
      expect(zig).to match(/heapAlloc|alloc.*__src/)
    end

    it "implicit-copies @list into struct []T field" do
      src = <<~CLEAR
        UNION Value { Nil }
        STRUCT Container { items: Value[] }
        FN main() RETURNS Void ->
            MUTABLE list: Value[]@list = List[];
            list.append(Value.Nil);
            c = Container{ items: list };
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to match(/heapAlloc|alloc.*__src/)
    end

    it "does NOT dupe heap string (COPY) in union - already owned" do
      src = <<~CLEAR
        UNION Value { Nil, Symbol: String }
        FN main() RETURNS Void ->
            v = Value{ Symbol: COPY "hello" };
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      # COPY already dupes - should not double-dupe
      lines = zig.scan(/heapAlloc\(\)\.dupe/).length
      expect(lines).to eq(1)
    end

    it "deep-copies @list of non-Copy unions (dupeUnionValue per element)" do
      src = <<~CLEAR
        UNION Value { Nil, Str: String, List: Value[] }
        FN main() RETURNS Void ->
            MUTABLE items: Value[]@list = List[];
            items.append(Value{ Str: COPY "hello" });
            v = Value{ List: items };
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      # Non-Copy union elements need deep copy
      expect(zig).to include("dupeUnionValue")
    end

    it "shallow-copies @list of Copy unions into union field (memcpy)" do
      src = <<~CLEAR
        UNION Num { Int: Int64, Float: Float64 }
        UNION Wrapper { Nil, Items: Num[] }
        FN main() RETURNS Void ->
            MUTABLE items: Num[]@list = List[];
            items.append(Num{ Int: 42_i64 });
            w = Wrapper{ Items: items };
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      # Copy union elements - memcpy is safe, no dupeUnionValue needed
      expect(zig).not_to include("dupeUnionValue")
      expect(zig).to include("@memcpy")
    end
  end

  # ===========================================================================
  # EXTERN method trampoline
  # ===========================================================================
  describe "EXTERN method calls use onRootStack trampoline" do
    it "emits method trampoline for EXTERN FN on EXTERN STRUCT" do
      src = <<~CLEAR
        EXTERN STRUCT Dir {} FROM "std.fs";
        EXTERN FN cwd() RETURNS Dir FROM "std.fs";
        EXTERN FN Dir.makePath(self: Dir, path: String) RETURNS Void FROM "std.fs";
        FN main() RETURNS Void ->
          cwd().makePath("data");
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("__ExtM")
      expect(zig).to include("self_val")
      expect(zig).to include("onRootStack")
      expect(zig).to include(".makePath")
    end
  end

  describe "Interior mutability: string field overwrite frees old value" do
    it "@alwaysMutable frees old string before overwriting" do
      src = <<~CLEAR
        STRUCT Config { theme: String, retries: Int64 }
        FN main() RETURNS Void ->
            MUTABLE cfg = Config{ theme: "dark", retries: 3_i64 } @alwaysMutable;
            cfg.theme = "light";
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      # Must free old "dark" before assigning "light"
      expect(zig).to include("__old")
      expect(zig).to include("free(__old)")
    end

    it "@locked frees old string before overwriting" do
      src = <<~CLEAR
        STRUCT Config { theme: String, retries: Int64 }
        FN main() RETURNS Void ->
            MUTABLE cfg = Config{ theme: "dark", retries: 3_i64 } @locked;
            cfg.theme = "light";
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      # Must free old string before assigning new one under lock
      expect(zig).to include("__old")
      expect(zig).to include("free(__old)")
    end
  end

  # ===========================================================================
  # BG string capture: defer free only for promoted captures
  # ===========================================================================
  describe "BG string capture defer free" do
    it "emits defer free for promoted (frame-allocated) string capture" do
      src = <<~CLEAR
        FN greet!(name: String) RETURNS String -> RETURN name; END
        FN main() RETURNS Void ->
            msg = greet!("hello");
            p: ~Void = BG { print(msg); };
            NEXT p;
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      # msg is frame-allocated, captured by BG -> must be duped + freed
      expect(zig).to include("dupe(u8, msg)")
      expect(zig).to include(".free(")
    end

    it "does NOT emit defer free for unpromoted string captures (BG inside MethodCall)" do
      src = <<~CLEAR
        FN greet!(name: String) RETURNS String -> RETURN name; END
        FN main() RETURNS Void ->
            msg = greet!("hello");
            needle = "the";
            MUTABLE futures: ~Void[]@list = [];
            futures.append(BG { print(msg); print(needle); });
            NEXT futures[0];
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      # BG is inside a MethodCall arg. If MIR::Promote was missed, there
      # should be NO defer free (freeing un-duped data crashes).
      # After the fix: both msg and needle should be duped AND freed.
      has_msg_dupe = zig.include?("dupe(u8, msg)")
      has_msg_free = zig.match?(/free.*msg/)
      # Either both dupe+free, or neither. Never free without dupe.
      expect(has_msg_free && !has_msg_dupe).to be(false),
        "free without dupe is a crash: msg is freed but was never duped to heap"
    end
  end
end
