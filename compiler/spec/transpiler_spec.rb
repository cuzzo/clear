require "rspec"
require "byebug"

require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../ruby/ast/ast" unless defined?(MIR::ReassignPlan)

RSpec.describe ZigTranspiler do
  def transpile(src)
    ZigTranspiler.new.transpile(src)
  end

  def function_body(zig, name)
    zig[/fn #{Regexp.escape(name)}\b.*?\n(.*?)^}/m, 1] || ""
  end

  describe "panic intrinsic" do
    it "allows NoReturn panic branches in match expressions without fallible returns" do
      zig = transpile(<<~CLEAR)
        FN choose(x: Int64) RETURNS Int64 ->
          RETURN PARTIAL MATCH x START
            1 -> 1,
            DEFAULT -> panic("bad")
          END;
        END

        FN main() RETURNS Void ->
          _ = choose(1);
          RETURN;
        END
      CLEAR

      expect(zig).to include('@panic(@as([]const u8, "bad"))')
      expect(zig).to include("fn choose(x: i64) i64")
    end
  end

  describe "collection ownership regressions" do
    it "cleans popped frame-list string captures with the receiver allocator" do
      zig = transpile(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE src: String[]@list = [];
          src.append(COPY "a");
          src.append(COPY "b");
          IF src.pop() AS v THEN
            ASSERT v.length() >= 0_i64, "captured string";
          ELSE
            ASSERT FALSE, "expected a popped value";
          END
          RETURN;
        END
      CLEAR

      expect(zig).to include("defer if (!v_moved) CheatLib.cleanup(@TypeOf(v), rt.frameAlloc(), &v);")
      expect(zig).not_to include("CheatLib.cleanup(@TypeOf(v), rt.heapAlloc(), &v)")
    end

    it "cleans popped frame-list struct captures with the receiver allocator" do
      zig = transpile(<<~CLEAR)
        STRUCT Item { name: String }

        FN main() RETURNS Void ->
          MUTABLE src: Item[]@list = [];
          src.append(Item{ name: COPY "a" });
          WHILE src.pop() AS v DO
            ASSERT v.name.length() >= 0_i64, "captured struct";
          END
          RETURN;
        END
      CLEAR

      expect(zig).to include("defer if (!v_moved) CheatLib.cleanup(@TypeOf(v), rt.frameAlloc(), &v);")
      expect(zig).not_to include("CheatLib.cleanup(@TypeOf(v), rt.heapAlloc(), &v)")
    end

    it "lets heap return destinations override frame-default intrinsic return allocation" do
      src = <<~CLEAR
        UNION Val {
          Nil,
          Str: String,
          Num: Float64
        }

        FN convert!(token: String) RETURNS !Val ->
          IF token == "nil" THEN RETURN Val.Nil; END
          IF charAt(token, 0) == "\\"" THEN RETURN Val{ Str: substr(token, 1, token.length() - 2) }; END
          n = toNumber(token) OR (0.0 - 999999.0);
          IF n != 0.0 - 999999.0 THEN RETURN Val{ Num: n }; END
          RETURN Val{ Str: COPY token };
        END
      CLEAR

      expect { transpile(src) }.not_to raise_error
    end

    it "does not require ownership facts for primitive receiver-storage pop fallbacks" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE stack: Int64[]@list = [];
          stack.append(1_i64);
          v = stack.pop() OR 0_i64;
          ASSERT v == 1_i64, "primitive pop fallback";
          RETURN;
        END
      CLEAR

      expect { transpile(src) }.not_to raise_error
    end

    it "keeps owned receiver-storage pop fallbacks checker-clean" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE src: String[]@list = [];
          src.append(COPY "a");
          v = src.pop() OR COPY "fallback";
          ASSERT v.length() > 0_i64, "owned pop fallback";
          RETURN;
        END
      CLEAR

      expect { transpile(src) }.not_to raise_error
    end
  end

  describe "BG promise capture regressions" do
    it "allows footguns/06-style consumer BG to NEXT a producer promise captured from the same scope" do
      src = <<~CLEAR
        STRUCT State {
          message: String
        }

        FN main() RETURNS Void ->
          s = State{ message: "" } @shared:locked;

          producer = BG {
            WITH EXCLUSIVE s AS inner {
              inner.message = "hello from producer";
            }
          };

          consumer = BG {
            NEXT producer;
            WITH s AS inner {
              print(inner.message);
            }
          };

          NEXT consumer;
        END
      CLEAR

      expect { transpile(src) }.not_to raise_error
    end

    it "allows footguns/07-style relay BG to NEXT a producer promise captured from the same scope" do
      src = <<~CLEAR
        STRUCT Payload {
          data: String
        }

        FN main() RETURNS Void ->
          result = Payload{ data: "" } @shared:locked;

          producer = BG {
            WITH EXCLUSIVE result AS r {
              r.data = "important result";
            }
          };

          relay = BG {
            NEXT producer;
          };

          consumer = BG {
            NEXT relay;
            WITH result AS r {
              print("consumer saw: " + r.data);
            }
          };

          NEXT consumer;
        END
      CLEAR

      expect { transpile(src) }.not_to raise_error
    end

    it "rejects using a plain producer promise after it is moved into a consumer BG" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          producer = BG { 1_i64; };
          consumer = BG { NEXT producer; };
          x = NEXT producer;
          NEXT consumer;
          RETURN;
        END
      CLEAR

      expect { transpile(src) }.to raise_error(/USE AFTER MOVE/)
    end
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
      expect(zig).to include("CheatLib.cleanup(@TypeOf(vals), rt.frameAlloc(), &vals)")
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
      FN buildList() RETURNS !Float64[]@list ->
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

    it "allocates always-escaped list on heap (no promoteList)" do
      zig = transpile(frame_list_src)
      # Always-escaped: single return referencing vals → heap from the start.
      # No runtime promoteList needed.
      expect(zig).not_to include("CheatLib.promoteList(")
    end

    it "uses heapAlloc for always-escaped list operations" do
      zig = transpile(frame_list_src)
      expect(zig).to include("rt.heapAlloc()")
    end

    it "caller cleans up heap-allocated list (no frame deinit)" do
      zig = transpile(frame_list_src)
      expect(zig).not_to include("vals.deinit(rt.frameAlloc())")
    end
  end

  # ===========================================================================
  # String HashMap frame-key promotion (mapPromote)
  # ===========================================================================
  describe "String HashMap escape promotion" do
    let(:map_return_src) { <<~CLEAR }
      FN buildMap() RETURNS !HashMap<Int64> ->
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

    it "always-escaped map is heap from start (no separate alloc set before return)" do
      zig = transpile(map_return_src)
      # StringMap init already sets .alloc = rt.heapAlloc(). Always-escaped
      # detection eliminates the redundant MIR::Promote alloc assignment.
      expect(zig).to include(".alloc = rt.heapAlloc()")
      expect(zig).not_to include("m.alloc = rt.heapAlloc()")
    end

    it "uses heapAlloc for mapPut keys and values (heap-provenance map)" do
      zig = transpile(map_return_src)
      expect(zig).to include(".put(rt.heapAlloc(), rt.heapAlloc()")
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

    it "emits saveLoopMark/restoreLoopMark for FOR..IN (ForEach) with loop-local list" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE items: Int64[] = [1_i64, 2_i64, 3_i64];
          FOR item IN items DO
            MUTABLE parts: Int64[]@list = [];
            parts.append(item);
          END
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("saveLoopMark")
      expect(zig).to include("restoreLoopMark")
    end

    it "emits saveLoopMark/restoreLoopMark for FOR..IN range (ForRange) with loop-local list" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          FOR i IN (0_i64 ..< 10) DO
            MUTABLE parts: Int64[]@list = [];
            parts.append(i);
          END
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("saveLoopMark")
      expect(zig).to include("restoreLoopMark")
    end

    it "does NOT promote outer list to heap or add loop marks when appending literal in loop" do
      # append(outer, 1.0): the literal is a value type, no frame allocation.
      # The backing store grows under the container's own allocator (frame).
      # The outer scope's rewind handles cleanup -- per-iteration rewind is wrong
      # here (it would corrupt the accumulation).
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
      expect(zig).not_to include("saveLoopMark")
      expect(zig).not_to include("heapAlloc")
    end
  end

  # ===========================================================================
  # SHARD pipeline producer loop frame marks
  # ===========================================================================
  describe "SHARD pipeline producer loop frame marks" do
    it "Phase 2: emits saveLoopMark in SHARD producer when key expression allocates from frame" do
      src = <<~CLEAR
        FN makeKey(n: Int64) RETURNS !String ->
            RETURN "k:${toString(n)}";
        END

        FN main() RETURNS Void ->
            MUTABLE counts: HashMap<Int64>@sharded(4) = {};
            (0_i64 ..< 100_i64) |> SHARD(makeKey(_), counts) |> CONCURRENT EACH {
                cur = counts[_] OR 0;
                counts[_] = cur + 1;
            };
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("saveLoopMark")
    end

    it "lowers SHARD map writes structurally with explicit ownership cleanup" do
      src = <<~CLEAR
        FN makeKey(n: Int64) RETURNS !String ->
            RETURN "k:${toString(n)}";
        END

        FN main() RETURNS Void ->
            MUTABLE counts: HashMap<Int64>@sharded(4) = {};
            (0_i64 ..< 100_i64) |> SHARD(makeKey(_), counts) |> CONCURRENT EACH {
                cur = counts[_] OR 0;
                counts[_] = cur + 1;
            };
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("CheatLib.BoundedChannel(__ShWork")
      expect(zig).to include("putDirect(ctx.shard")
    end

    it "lowers SHARD map reads structurally in the verifier-visible worker body" do
      src = <<~CLEAR
        FN makeKey(n: Int64) RETURNS !String ->
            RETURN "k:${toString(n)}";
        END

        FN main() RETURNS Void ->
            MUTABLE counts: HashMap<Int64>@sharded(4) = {};
            (0_i64 ..< 100_i64) |> SHARD(makeKey(_), counts) |> CONCURRENT EACH {
                cur = counts[_] OR 0;
                counts[_] = cur + 1;
            };
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("(ctx.__shard_map.*.getDirect(ctx.shard, __sh1_key) orelse @as(i64, 0))")
      expect(zig).to include("var __sh1_i: i64 = 0")
      expect(zig).to include("while ((__sh1_i < __sh1_end)")
    end

    it "structural SHARD put owns the value through explicit transfer markers" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
            MUTABLE map: HashMap<String>@sharded(4) = {};
            (0_i64 ..< 10_i64) |> SHARD("k:" + toString(_), map) |> CONCURRENT EACH {
                map[_] = "value";
            };
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("try ctx.__shard_map.*.putDirect(ctx.shard")
      expect(zig).to include(%(@as([]const u8, "value")))
      expect(zig).not_to include(%(dupe(u8, @as([]const u8, "value"))))
    end

    it "keeps borrowed SHARD string map reads borrowed through OR fallback" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
            MUTABLE map: HashMap<String>@sharded(4) = {};
            (0_i64 ..< 10_i64) |> SHARD("k:" + toString(_), map) |> CONCURRENT EACH {
                got = map[_] OR "";
            };
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("ctx.__shard_map.*.getDirect(ctx.shard, __sh1_key) orelse")
      expect(zig).not_to include("frameAlloc().dupe(u8")
    end

    it "skips saveLoopMark in SHARD producer when key is a pre-built array lookup (no frame alloc)" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
            MUTABLE keys: String[]@list = [];
            keys.append("a");
            keys.append("b");
            MUTABLE counts: HashMap<Int64>@sharded(4) = {};
            (0_i64 ..< 2_i64) |> SHARD(keys[_], counts) |> CONCURRENT EACH {
                cur = counts[_] OR 0;
                counts[_] = cur + 1;
            };
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      # keys[_] is a GetIndex into an existing String[] — no frame allocation.
      expect(zig).not_to include("saveLoopMark")
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

    it "raises a compile error when TIGHT loop calls a plain EFFECTS REENTRANT function directly" do
      src = <<~CLEAR
        FN fib(n: Int64) RETURNS Int64 EFFECTS REENTRANT ->
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
      expect { transpile(src) }.to raise_error(/TIGHT loop cannot call plain EFFECTS REENTRANT/)
    end

    it "raises a compile error when a plain EFFECTS REENTRANT call is nested inside an IF inside TIGHT" do
      src = <<~CLEAR
        FN fib(n: Int64) RETURNS Int64 EFFECTS REENTRANT ->
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
      expect { transpile(src) }.to raise_error(/TIGHT loop cannot call plain EFFECTS REENTRANT/)
    end

    it "raises when a TIGHT loop method-call argument calls a plain EFFECTS REENTRANT function" do
      src = <<~CLEAR
        FN fib(n: Int64) RETURNS Int64 EFFECTS REENTRANT ->
          IF n <= 1 THEN RETURN n; END
          RETURN fib(n - 1) + fib(n - 2);
        END
        FN main() RETURNS Void ->
          MUTABLE i = 0_i64;
          MUTABLE vals: Int64[]@list = [];
          TIGHT WHILE i < 3 DO
            vals.append(fib(i));
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR
      expect { transpile(src) }.to raise_error(/TIGHT loop cannot call plain EFFECTS REENTRANT/)
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
        FN update!(key: String, MUTABLE env: HashMap<Int64>, depth: Int64) RETURNS !Int64 EFFECTS REENTRANT ->
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
        FN build() RETURNS !Pair ->
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
        FN build() RETURNS !Pair ->
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
    it "emits saveFrameMark for frame-owned split results returning Void" do
      src = <<~CLEAR
        FN f(s: String) RETURNS !Void ->
          parts = split(s, ",");
          RETURN;
        END
        FN main() RETURNS Void ->
          f("a,b");
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(function_body(zig, "f")).to include("saveFrameMark")
      expect(function_body(zig, "f")).to include("restoreFrameMark")
    end

    it "emits saveFrameMark for frame-owned split results with borrowed string return" do
      src = <<~CLEAR
        FN f(s: String) RETURNS !String ->
          parts = split(s, ",");
          RETURN s;
        END
        FN main() RETURNS Void ->
          r = f("a,b");
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(function_body(zig, "f")).to include("saveFrameMark")
      expect(function_body(zig, "f")).to include("restoreFrameMark")
      expect(zig).not_to include("preserveAndRewind")
      expect(zig).not_to include("__pr_body")
    end

    it "emits saveFrameMark for frame-owned split results returning an ENUM value" do
      src = <<~CLEAR
        ENUM Status { Ok, Err }
        FN check(s: String) RETURNS !Status ->
          parts = split(s, ",");
          RETURN Status.Ok;
        END
        FN main() RETURNS Void ->
          r = check("a,b");
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(function_body(zig, "check")).to include("saveFrameMark")
      expect(function_body(zig, "check")).to include("restoreFrameMark")
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
        FN test!(MUTABLE pool: Env[10]@pool, MUTABLE map: HashMap<Value>) RETURNS !Void ->
            pool.insert(Env{ x: 1 });
            val = Value.Lambda{ body: Value{ Num: 42.0 }, id: 1 };
            map["key"] = val;
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      # Owned values move into map storage directly; no hidden promotion or deep copy.
      expect(zig).to include("val_moved")
      expect(zig).not_to include("dupeUnionValue(Value, val")
      expect(zig).not_to match(/defer CheatLib\.cleanup\([^,]+, [^,]+, &val\);/)
      expect(zig).to include('map.put(rt.heapAlloc(), rt.heapAlloc(), "key", val)')
    end

    it "moves owned map assignment values without deep-copying them" do
      src = <<~CLEAR
        UNION Value { Nil, Num: Float64, Str: String, Lambda { body: Value @indirect, id: Int64 } }
        FN test!(MUTABLE map: HashMap<Value>) RETURNS !Void ->
            val = Value.Lambda{ body: Value{ Num: 42.0 }, id: 1 };
            map["key"] = val;
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      # Map storage owns val after assignment; the transfer is explicit.
      expect(zig).to include("val_moved = true")
      expect(zig).not_to include("dupeUnionValue(Value, val")
      expect(zig).not_to match(/defer CheatLib\.cleanup\([^,]+, [^,]+, &val\)/)
      expect(zig).to include('map.put(rt.heapAlloc(), rt.heapAlloc(), "key", val)')
    end

    it "does not emit source_moved for plain MATCH AS on non-Copy variant" do
      src = <<~CLEAR
        STRUCT Env { x: Int64 }
        UNION Value { Nil, Num: Float64, Str: String, List: Value[], Lambda { body: Value @indirect, id: Int64 } }
        FN test!(TAKES v: Value, MUTABLE pool: Env[10]@pool) RETURNS !Value ->
            pool.insert(Env{ x: 1 });
            PARTIAL MATCH v START
                Value.Lambda AS lam -> RETURN Value.Nil;,
                DEFAULT -> RETURN Value.Nil;
            END
            RETURN Value.Nil;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).not_to include("v_moved = true")
    end

    it "keeps v moved guard when can_fail call precedes MATCH TAKES" do
      src = <<~CLEAR
        STRUCT Env { x: Int64 }
        UNION Value { Nil, Num: Float64, Str: String, List: Value[], Lambda { body: Value @indirect, id: Int64 } }
        FN test!(TAKES v: Value, MUTABLE pool: Env[10]@pool) RETURNS !Value ->
            pool.insert(Env{ x: 1 });
            PARTIAL MATCH TAKES v START
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
        FN test!(TAKES v: Value, MUTABLE pool: Env[10]@pool) RETURNS !Value ->
            pool.insert(Env{ x: 1 });
            PARTIAL MATCH v START
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
        FN test!(MUTABLE map: HashMap<String>) RETURNS !Void ->
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
        FN test!(MUTABLE map: HashMap<Value>) RETURNS !Void ->
            map["key"] = Value{ Str: "world" };
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to match(/dupeValue\(\[\]const u8, __copy_src/)
    end

    it "plain MATCH AS on non-Copy variant does not emit owned binding cleanup" do
      src = <<~CLEAR
        UNION Value { Num: Float64, List: Value[] }
        FN test!() RETURNS !Void ->
            result = Value{ Num: 1.0 };
            PARTIAL MATCH result START
                Value.List AS items -> RETURN;,
                DEFAULT -> RETURN;
            END
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).not_to include("items_moved")
    end

    it "MATCH TAKES emits cleanup on AS binding" do
      src = <<~CLEAR
        UNION Value { Num: Float64, List: Value[] }
        FN test!() RETURNS !Void ->
            result = Value{ Num: 1.0 };
            PARTIAL MATCH TAKES result START
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
        FN makeStr(s: String) RETURNS !Value -> RETURN Value{ Str: COPY s }; END
        FN main() RETURNS Void ->
            MUTABLE result = makeStr("hello");
            result = makeStr("world");
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to match(/cleanup\([^,]+, [^,]+, &result\).*\n.*result = /)
    end
  end

  describe "Heap-promoted temporary from function call gets cleanup" do
    it "emits cleanup for heap string temporary passed to print" do
      src = <<~CLEAR
        FN makeStr() RETURNS !String -> RETURN COPY "hello"; END
        FN main() RETURNS Void ->
            print(makeStr());
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      # The temp from makeStr() is heap-allocated and hoisted before cleanup classification.
      expect(zig).to match(/defer.*__hoist_\d+/)
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
      expect(zig).to match(/dupeValue\(\[\]const u8, __copy_src/)
    end

    it "emits a dupe method for cleanup-bearing inline struct variant fields" do
      src = <<~CLEAR
        UNION Value { Nil, Error { errMsg: String, errKind: String } }
        FN main() RETURNS Void ->
            err = Value.Error{ errMsg: "x", errKind: "E" };
            copied = COPY err;
            RETURN;
        END
      CLEAR
      zig = transpile(src)

      expect(zig).to include("pub fn dupe(self: @This(), alloc: std.mem.Allocator) !@This()")
      expect(zig).to include("try CheatLib.dupeValue(@TypeOf(self.errMsg), self.errMsg, alloc)")
      expect(zig).to include("errdefer CheatLib.cleanup(@TypeOf(__dupe_errMsg), alloc, &__dupe_errMsg)")
      expect(zig).to include("result.errKind = __dupe_errKind")
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
        FN makeValue() RETURNS !Value -> RETURN Value{ Str: COPY "hello" }; END
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
        FN makeValue() RETURNS !Value -> RETURN Value{ Str: COPY "hello" }; END
        FN wrapper() RETURNS !Value -> RETURN makeValue(); END
        FN main() RETURNS Void ->
            v = wrapper();
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      # wrapper() may bind the returned value so ownership markers have a
      # named target, but it must not use the deleted __hpt promotion path.
      fn_body = zig[zig.index("fn wrapper")..zig.index("fn clearMain")]
      expect(fn_body).not_to include("__hpt")
      expect(fn_body).to include("try makeValue")
      expect(fn_body).to include("return __hoist_")
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
      # Hoisting may name the union literal, but the move marker must be
      # emitted before returning the hoisted value.
      expect(zig).to match(/items_moved = true;.*\n(?:.*\n)*?\s*return __hoist_/)
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
        FN consume!(TAKES v: Value) RETURNS !String ->
            PARTIAL MATCH TAKES v START
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

  describe "optional unwrap on non-identifier receivers" do
    it "transpiles pool index unwrap followed by field method call" do
      src = <<~CLEAR
        STRUCT Env { vars: HashMap<Int64> }

        FN has!(envId: Id<Env>, name: String, MUTABLE pool: Env[10]@pool) RETURNS Bool ->
            RETURN pool[envId]?.vars.contains?(name);
        END
      CLEAR

      zig = transpile(src)
      expect(zig).to include("contains(name)")
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
      expect(zig).to match(/dupeValue\(\[\]const u8, __copy_src/)
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
      expect(zig).to match(/dupeValue\(\[\]const u8, __copy_src/)
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
      # @list COPY routes through CheatLib.dupeValue's slice arm (one path).
      expect(zig).to match(/dupeValue\(std\.ArrayListUnmanaged\(Value\)/)
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
      expect(zig).to match(/dupeValue\(std\.ArrayListUnmanaged\(Value\)/)
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
      lines = zig.scan(/dupeValue\(/).length
      expect(lines).to eq(1)
    end

    it "deep-copies @list of non-Copy unions (canonical dupeValue per element)" do
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
      expect(zig).to include("dupeValue")
    end

    it "shallow-copies @list of Copy unions into union field via dupeValue (slice arm uses @memcpy internally for Copy elements)" do
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
      # Copy union elements - dupeValue's slice arm @memcpy's the buffer.
      expect(zig).not_to include("dupeUnionValue")
      expect(zig).to match(/dupeValue\(std\.ArrayListUnmanaged\(Num\)/)
    end
  end

  describe "heap cleanup for copy-only ids" do
    it "does not free Id<T> extracted from a union payload" do
      src = <<~CLEAR
        STRUCT Env { vars: String[]@list }
        UNION Value {
          Nil,
          Tco { tcoAst: String @indirect, tcoEnv: Id<Env> }
        }

        FN getEnvId!(v: Value, MUTABLE pool: Env[8]@pool) RETURNS !Id<Env> ->
          PARTIAL MATCH v START
            Value.Tco AS tco ->
              tcoEnv = COPY tco.tcoEnv;
              RETURN tcoEnv;,
            DEFAULT ->
              dummy: Id<Env> = pool.insert(Env{ vars: [] });
              RETURN dummy;
          END
          dummy2: Id<Env> = pool.insert(Env{ vars: [] });
          RETURN dummy2;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).not_to include("defer CheatLib.free(rt, tcoEnv)")
      expect(zig).not_to include("CheatLib.cleanup(u64")
    end

    it "does not free Id<T> copied into a reentrant call path" do
      src = <<~CLEAR
        STRUCT Env { vars: String[]@list }
        UNION Value {
          Nil,
          Tco { tcoAst: String @indirect, tcoEnv: Id<Env> }
        }

        FN eval!(TAKES ast: String, envId: Id<Env>, MUTABLE pool: Env[8]@pool) RETURNS String EFFECTS REENTRANT ->
          RETURN ast;
        END

        FN resolveTco!(v: Value, MUTABLE pool: Env[8]@pool) RETURNS !String EFFECTS REENTRANT ->
          PARTIAL MATCH v START
            Value.Tco AS tco ->
              tcoAst = COPY tco.tcoAst;
              tcoEnv = COPY tco.tcoEnv;
              RETURN eval!(GIVE tcoAst, tcoEnv, pool);,
            DEFAULT -> RETURN "";
          END
          RETURN "";
        END
      CLEAR
      zig = transpile(src)
      expect(zig).not_to include("defer CheatLib.free(rt, tcoEnv)")
      expect(zig).not_to include("CheatLib.cleanup(u64")
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
  # BG string capture: do not free non-duped captures
  # ===========================================================================
  describe "BG string capture defer free" do
    it "captures an already-owned heap string as a fiber-owned duplicate" do
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
      user_code = zig.split("// 3. Main Entry").first
      expect(user_code).to include("CheatLib.dupeCaptured(@TypeOf(msg), msg")
      expect(user_code).to include(".msg = __fc_")
      expect(user_code).to include("msg_moved: bool = false,")
      expect(user_code).to include("errdefer CheatLib.cleanup(@TypeOf(__fc_0_msg), __bg0_alloc, &__fc_0_msg);")
      expect(user_code).to include(
        "if (!__ctx_0.msg_moved) CheatLib.cleanup(@TypeOf(__ctx_0.msg), __ctx_0.alloc, &__ctx_0.msg);"
      )
    end

    it "cleans duplicated FSM captures even when the source string starts as rodata" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
            greeting: String = "world";
            p: ~String = BG { greeting + "!"; };
            result: String = NEXT p;
            ASSERT result == "world!", "BG string capture";
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      user_code = zig.split("// 3. Main Entry").first
      expect(user_code).to include("CheatLib.dupeCaptured(@TypeOf(greeting), greeting, __bg0_alloc)")
      expect(user_code).to include("greeting_moved: bool = false,")
      expect(user_code).to include("errdefer CheatLib.cleanup(@TypeOf(__fc_0_greeting), __bg0_alloc, &__fc_0_greeting);")
      expect(user_code).to include(
        "if (!__ctx_0.greeting_moved) CheatLib.cleanup(@TypeOf(__ctx_0.greeting), __ctx_0.alloc, &__ctx_0.greeting);"
      )
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

  # ===========================================================================
  # BG spawn: @local uses same-scheduler, not round-robin
  # ===========================================================================
  describe "BG spawn dispatch" do
    it "uses spawnFsmBest (cross-scheduler) for @locked captures via FSM" do
      src = <<~CLEAR
        STRUCT Counter { value: Int64 }
        FN inc(c: Counter) RETURNS Void -> RETURN; END
        FN main() RETURNS Void ->
            c = Counter{ value: 0 } @locked;
            p: ~Void = BG { inc(c); };
            NEXT p;
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      # @locked auto-pins to :shared. FSM bodies under :shared use
      # spawnFsmBest (cross-scheduler) -- the FSM's lock-acquire and
      # IO suspends route via parking-lot/io_uring regardless of
      # the spawning scheduler. The legacy stackful path used
      # spawnPinned for @locked; FSM unification removes that
      # restriction.
      user_code = zig.split("// 3. Main Entry").first
      expect(user_code).to include("spawnFsmBest")
    end

    it "uses submitSpawn (same-scheduler) for @local captures" do
      src = <<~CLEAR
        STRUCT Counter { value: Int64 }
        FN inc(c: Counter) RETURNS Void -> RETURN; END
        FN main() RETURNS Void ->
            c = Counter{ value: 0 } @local;
            p: ~Void = BG { inc(c); };
            NEXT p;
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      # @local is shared-nothing — all fibers on same scheduler. Pure-compute
      # body is Phase-B1 FSM-eligible, so dispatch is submitFsmSpawn (same
      # scheduler, FSM queue) rather than submitSpawn (same scheduler, stackful).
      user_code = zig.split("// 3. Main Entry").first
      expect(user_code).to match(/submit(Spawn|FsmSpawn)\(/)
      expect(user_code).not_to include("spawnPinned(")
      expect(user_code).not_to include("spawnBest(")
      expect(user_code).not_to include("spawnFsmBest(")
    end
  end

  # ===========================================================================
  # NEXT on ~T[]@list (promise list await-all)
  # ===========================================================================
  describe "NEXT on promise list (~T[]@list)" do
    it "emits an await-all loop that collects local results into a frame list" do
      src = <<~CLEAR
        FN work(n: Int64) RETURNS Int64 -> RETURN n; END
        FN main() RETURNS Void ->
            MUTABLE futures: ~Int64[]@list = [];
            futures.append(BG { work(1); });
            futures.append(BG { work(2); });
            results: Int64[]@list = NEXT futures;
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      # Should emit the labeled block with for-loop over futures.items
      expect(zig).to include("for (futures.items)")
      expect(zig).to include(".append(")
      expect(zig).to include("__p.next()")
      expect(zig).to include("frameAlloc()")
      expect(zig).to include("CheatLib.cleanup(@TypeOf(results), rt.frameAlloc(), &results)")
    end
  end

  # ===========================================================================
  # INV regression: memory safety invariant checks
  # ===========================================================================

  describe "INV-1/INV-5: always-escaped collections are heap from start" do
    it "allocates always-escaped list on heap (no promoteList)" do
      src = <<~CLEAR
        FN build!() RETURNS !Float64[] ->
            MUTABLE vals: Float64[]@list = List[];
            append(vals, 1.0);
            RETURN vals;
        END
        FN main() RETURNS Void -> x = build!(); RETURN; END
      CLEAR
      zig = transpile(src)
      expect(zig).not_to include("promoteList")
      expect(zig).to include("heapAlloc")
    end

    it "uses heap allocator for always-escaped map" do
      src = <<~CLEAR
        FN buildMap!() RETURNS !HashMap<Int64> ->
            MUTABLE m: HashMap<Int64> = {};
            m["x"] = 1_i64;
            RETURN m;
        END
        FN main() RETURNS Void -> x = buildMap!(); RETURN; END
      CLEAR
      zig = transpile(src)
      expect(zig).not_to include("promoteList")
    end
  end

  describe "INV: recursive union indirect payload moves" do
    it "marks local recursive union payloads moved after boxing into @indirect fields" do
      src = <<~CLEAR
        UNION Node { Nil, One: String, Pair { left: Node @indirect, right: Node @indirect } }

        FN mk() RETURNS !Node ->
            left = Node{ One: COPY "a" };
            right = Node{ One: COPY "b" };
            RETURN Node.Pair{ left: left, right: right };
        END

        FN main() RETURNS Void ->
            n: Node = mk() OR RAISE;
            PARTIAL MATCH n START
                Node.Pair AS p -> ASSERT TRUE, "recursive pair returned";,
                DEFAULT -> ASSERT FALSE, "expected recursive pair";
            END
            RETURN;
        END
      CLEAR
      zig = transpile(src)

      expect(zig).to match(/__p\.\* = left;\s+break :blk_left __p;\s+};\s+left_moved = true;/m)
      expect(zig).to match(/__p\.\* = right;\s+break :blk_right __p;\s+};\s+right_moved = true;/m)
    end
  end

  # ===========================================================================
  # BUG-MIR-002: heap-returning call in non-TAKES argument position
  # ===========================================================================
  describe "BUG-MIR-002: heap-returning call in non-TAKES arg position is hoisted" do
    it "hoists non-Copy union return from function call used as non-TAKES arg" do
      src = <<~CLEAR
        UNION Value { Nil, Num: Float64, Lambda { body: Value @indirect, id: Int64 } }
        FN makeVal!() RETURNS !Value ->
            RETURN Value.Lambda{ body: Value{ Num: 1.0 }, id: 1 };
        END
        FN useVal(v: Value) RETURNS String ->
            RETURN "ok";
        END
        FN test!() RETURNS !String ->
            RETURN useVal(makeVal!() OR RAISE);
        END
      CLEAR
      zig = transpile(src)
      # makeVal!() returns a heap-owning Value. useVal borrows it (non-TAKES).
      # The temporary must be hoisted to a named let with a cleanup defer,
      # otherwise the Lambda's @indirect body pointer leaks.
      expect(zig).to match(/defer CheatLib\.cleanup\([^,]+, [^,]+, &__hoist_\d+\)/)
    end

    it "does not hoist Copy types (Int64) used as non-TAKES args" do
      src = <<~CLEAR
        FN makeNum!() RETURNS Int64 -> RETURN 42_i64; END
        FN useNum(n: Int64) RETURNS Void -> RETURN; END
        FN test!() RETURNS Void -> useNum(makeNum!()); RETURN; END
      CLEAR
      zig = transpile(src)
      # Int64 is a Copy type -- no cleanup needed, no __tmp hoisting
      expect(zig).not_to match(/defer CheatLib\.cleanup\([^,]+, [^,]+, &num\)/)
    end
  end

  describe "INV-1: HPT string dupe matches storage" do
    it "uses heapAlloc for dupe when function has heap storage" do
      # Use a named binding so makeStr!'s result is properly cleaned up
      # (inline `transform!(makeStr!())` would leak the temp string -- ERRDEFER_LEAK).
      src = <<~CLEAR
        FN makeStr!() RETURNS !String -> RETURN COPY "hi"; END
        FN transform!(s: String) RETURNS !String -> RETURN COPY s; END
        FN caller!() RETURNS !String ->
            s = makeStr!();
            RETURN transform!(s);
        END
        FN main() RETURNS Void -> result = caller!(); RETURN; END
      CLEAR
      zig = transpile(src)
      expect(zig).to match(/dupeValue\(\[\]const u8, .+, rt\.heapAlloc\(\)\)/)
    end
  end

  describe "INV-7: string concat flag is annotation-driven" do
    it "emits std.mem.concat for string addition" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
            a = "hello";
            b = " world";
            c = a + b;
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("std.mem.concat")
    end
  end

  describe "INV-8: cleanup allocator is type-driven" do
    it "uses heapAlloc cleanup for map types" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
            MUTABLE m: HashMap<Int64> = {};
            m["x"] = 1_i64;
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("heapAlloc")
    end
  end

  # ===========================================================================
  # Pipeline on slice parameter (no .items on []T)
  # ===========================================================================
  describe "pipeline on slice parameter" do
    it "does not emit .items on a slice parameter in WHERE pipeline" do
      src = <<~CLEAR
        FN filterSum(data: Float64[]) RETURNS !Float64 ->
            RETURN data |> WHERE _ > 5.0 |> SUM _;
        END
        FN main() RETURNS Void ->
            MUTABLE data: Float64[]@list = [];
            data.append(10.0);
            result = filterSum(data);
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      # The for loop inside filterSum must not use .items on a slice param.
      # (The call site may use @hasField conditional -- that's fine.)
      expect(zig).not_to match(/for\s*\(data\.items\)/)
    end

    it "does not emit .items on a slice parameter in SUM pipeline" do
      src = <<~CLEAR
        FN sumAll(data: Float64[]) RETURNS Float64 ->
            RETURN data |> SUM _;
        END
        FN main() RETURNS Void ->
            MUTABLE data: Float64[]@list = [];
            data.append(1.0);
            result = sumAll(data);
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).not_to match(/for\s*\(data\.items\)/)
    end
  end

  # ===========================================================================
  # Variable-backed finite stream pipelines
  # ===========================================================================
  describe "variable-backed finite stream pipelines" do
    it "lowers SELECT/WHERE/EACH over ~T[] variables through .next(), not .items" do
      src = <<~CLEAR
        FN f() RETURNS !Void ->
            s: ~Int64[] = 0 ..< 5;
            MUTABLE acc: Int64 = 0;
            s |> SELECT _ * 2 |> WHERE _ > 3 |> EACH {
                acc = acc + _;
            };
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("while (try s.next())")
      expect(zig).not_to include("s.items")
      expect(zig).to include("const __each_item_1")
    end

    it "lowers TAKE_WHILE and SKIP over ~T[] variables through the fused .next() loop" do
      src = <<~CLEAR
        FN f() RETURNS !Void ->
            s: ~Int64[] = 0 ..< 8;
            MUTABLE acc: Int64 = 0;
            s |> SKIP 2 |> TAKE_WHILE _ < 6 |> EACH {
                acc = acc + _;
            };
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("while (try s.next())")
      expect(zig).to include("var __skip_cnt_1 = @as(i64, 0);")
      expect(zig).to include("const __skip_max_1 = 2;")
      expect(zig).to include("if ((__skip_cnt_1 < __skip_max_1))")
      expect(zig).to include("continue;")
      expect(zig).to include("if (!(__each_item < 6))")
      expect(zig).to include("break;")
      expect(zig).not_to include("s.items")
    end

    it "lowers CONCURRENT SELECT over ~T[] variables through the stream helper" do
      src = <<~CLEAR
        FN f() RETURNS !Void ->
            s: ~Int64[] = 0 ..< 5;
            vals = s |> CONCURRENT(workers: 2) SELECT _ * 2;
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("CheatLib.concurrentStreamSelect(i64, i64, __BoundedConcurrentCtx1.apply, false,")
      expect(zig).not_to include("CheatLib.concurrentStreamSelect(i64, i64, false, __BoundedConcurrentCtx1.apply")
      expect(zig).to include("__BoundedConcurrentCtx1.apply")
      expect(zig).not_to include("s.toList(")
    end

    it "lowers CONCURRENT WHERE over ~T[] variables through the stream helper" do
      src = <<~CLEAR
        FN f() RETURNS !Void ->
            s: ~Int64[] = 0 ..< 5;
            vals = s |> CONCURRENT(workers: 2) WHERE _ > 2;
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("CheatLib.concurrentStreamWhere(i64, __BoundedConcurrentCtx1.apply, false,")
      expect(zig).not_to include("CheatLib.concurrentStreamWhere(i64, false, __BoundedConcurrentCtx1.apply")
      expect(zig).to include("__BoundedConcurrentCtx1.apply")
      expect(zig).not_to include("s.toList(")
    end

    it "orders CONCURRENT EACH stream helper arguments for the runtime wrapper" do
      src = <<~CLEAR
        FN f() RETURNS !Void ->
            s: ~Int64[] = 0 ..< 5;
            s |> CONCURRENT(workers: 2, capacity: 4) EACH {
                print(_);
            };
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("CheatLib.concurrentStreamEach(i64, __BoundedConcurrentCtx1.apply, false, rt.frameAlloc(), rt, &s, @intCast(2), @intCast(4)")
      expect(zig).not_to include("CheatLib.concurrentStreamEach(i64, false, __BoundedConcurrentCtx1.apply")
      expect(zig).not_to include("s.toList(")
    end
  end

  describe "concurrent bounded stream pipelines" do
    it "lowers CONCURRENT SELECT on ~T[N] through the bounded helper call, not materialization" do
      src = <<~CLEAR
        FN f() RETURNS !Void ->
            s: ~Int64[3] = [BG { 1; }, BG { 2; }, BG { 3; }];
            vals = s |> CONCURRENT(workers: 2) SELECT _ * 2;
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("CheatLib.concurrentBoundedSelect(i64, i64, 3")
      expect(zig).to include("__BoundedConcurrentCtx1.apply")
      expect(zig).to include("&s.items")
      expect(zig).not_to include("s.toList(")
    end

    it "lowers CONCURRENT WHERE on ~T[N] through the bounded helper call" do
      src = <<~CLEAR
        FN f() RETURNS !Void ->
            s: ~Int64[4] = [BG { 1; }, BG { 2; }, BG { 3; }, BG { 4; }];
            vals = s |> CONCURRENT(workers: 2) WHERE _ > 2;
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("CheatLib.concurrentBoundedWhere(i64, 4")
      expect(zig).to include("__BoundedConcurrentCtx1.apply")
      expect(zig).to include("&s.items")
      expect(zig).not_to include("s.toList(")
    end

    it "lowers CONCURRENT EACH on ~T[N] through the bounded helper call" do
      src = <<~CLEAR
        FN f() RETURNS !Void ->
            MUTABLE total: Int64@shared:locked = 0;
            s: ~Int64[2] = [BG { 10; }, BG { 20; }];
            s |> CONCURRENT(workers: 2) EACH {
                WITH EXCLUSIVE total AS t {
                    t = t + _;
                }
            };
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("CheatLib.concurrentBoundedEach(i64, 2")
      expect(zig).to include("__BoundedConcurrentCtx1.apply")
      expect(zig).to include("&s.items")
      expect(zig).not_to include("s.toList(")
    end
  end

  # ===========================================================================
  # Fixed SOA cleanup
  # ===========================================================================
  describe "fixed SOA array cleanup" do
    it "emits SoaList.initCapacity for T[N]@soa, not empty init" do
      src = <<~CLEAR
        STRUCT Point { x: Float64, y: Float64 }
        FN main() RETURNS Void ->
            MUTABLE soa: Point[10]@soa = [];
            soa.append(Point{ x: 1.0, y: 2.0 });
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      # Must use initCapacity(N) to avoid frame-arena doubling waste
      expect(zig).to include("CheatLib.SoaList(Point).initCapacity(rt.frameAlloc(), 10)")
      # Must not start empty (old broken behavior)
      expect(zig).not_to include("CheatLib.SoaList(Point){}")
      # Must not be a plain fixed array
      expect(zig).not_to match(/\[\d+\]Point/)
    end

    it "emits matching deinit for the pre-allocated SOA" do
      src = <<~CLEAR
        STRUCT Point { x: Float64, y: Float64 }
        FN main() RETURNS Void ->
            MUTABLE soa: Point[10]@soa = [];
            soa.append(Point{ x: 1.0, y: 2.0 });
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      # Post-collapse: @soa routes through CheatLib.cleanup ("struct with
      # deinit" comptime arm dispatches to ptr.deinit(alloc) internally).
      expect(zig).to include("CheatLib.cleanup(@TypeOf(soa), rt.frameAlloc(), &soa)")
    end
  end

  # ===========================================================================
  # SOA EACH placeholder rewriting (benchmark 28)
  # ===========================================================================
  describe "SOA EACH pipeline placeholder" do
    it "rewrites _ placeholder to SOA field accessors in EACH body" do
      src = <<~CLEAR
        STRUCT Point { x: Float64, y: Float64 }
        FN main() RETURNS Void ->
            MUTABLE soa: Point[100]@soa = [];
            soa.append(Point{ x: 1.0, y: 2.0 });
            soa |> EACH { _.x = _.x + _.y; };
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      # The EACH body must not contain literal '_.x' or '_.y' --
      # they should be rewritten to __soa_x[__soa_i] etc.
      expect(zig).not_to include("_.x")
      expect(zig).not_to include("_.y")
    end
  end

  # ===========================================================================
  # SHARD pipeline variable suppression (benchmark 19)
  # ===========================================================================
  describe "SHARD pipeline variable suppression" do
    it "does not emit pointless _ = var discard for used variables" do
      src = <<~CLEAR
        FN makeKey(seed: Int64) RETURNS !String ->
            RETURN toString(seed);
        END
        FN main() RETURNS Void ->
            MUTABLE counts: HashMap<Int64>@sharded(32) = {};
            MUTABLE seeds: Int64[]@list = [];
            seeds.append(1_i64);
            seeds.append(2_i64);
            (0..<2) |> SHARD(makeKey(seeds[_]), counts) |> CONCURRENT EACH {
                cur = counts[_] OR 0;
                counts[_] = cur + 1;
            };
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      # Must not have "_ = cur;" which Zig rejects as pointless discard
      expect(zig).not_to match(/;\s*_ = cur;/)
    end
  end

  # ===========================================================================
  # AS $v pipeline binding - happy path
  # ===========================================================================
  describe "AS $v pipeline binding" do
    let(:struct_preamble) { <<~CLEAR }
      STRUCT Order { price: Float64, qty: Int64 }
      STRUCT User { name: String, orders: Order[]@list }
      FN main() RETURNS Void ->
        alice_orders: Order[] = [Order{ price: 10.0, qty: 2 }, Order{ price: 20.0, qty: 1 }];
        bob_orders:   Order[] = [Order{ price: 15.0, qty: 3 }];
        users: User[] = [
          User{ name: "alice", orders: alice_orders },
          User{ name: "bob",   orders: bob_orders }
        ];
    CLEAR

    it "generates an outer for-loop with named capture for AS $u" do
      src = struct_preamble + "_ = users AS $u |> UNNEST $u.orders |> SUM _.price; RETURN; END"
      zig = transpile(src)
      expect(zig).to match(/for.*\|__pipe_u\|/)
    end

    it "generates an inner for-loop over the unnested field" do
      src = struct_preamble + "_ = users AS $u |> UNNEST $u.orders |> SUM _.price; RETURN; END"
      zig = transpile(src)
      expect(zig).to match(/__pipe_u\.orders/)
    end

    it "substitutes $u in the fold expression" do
      src = struct_preamble + "_ = users AS $u |> UNNEST $u.orders |> SUM _.price; RETURN; END"
      zig = transpile(src)
      # _.price should reference the inner loop variable, $u should be the outer
      expect(zig).to include("__pipe_u")
      expect(zig).not_to match(/\$u/)   # no literal $u in output
    end

    it "generates explicit inner binding for UNNEST $u.orders AS $o" do
      src = struct_preamble + "_ = users AS $u |> UNNEST $u.orders AS $o |> SUM $o.price; RETURN; END"
      zig = transpile(src)
      expect(zig).to match(/for.*\|__pipe_u\|/)
      expect(zig).to match(/for.*\|__pipe_o\|/)
      expect(zig).to include("__pipe_o.price")
    end

    it "WHERE stage filters using inner element, fold uses $u" do
      src = <<~CLEAR
        STRUCT Order { price: Float64, qty: Int64 }
        STRUCT User { name: String, discount: Float64, orders: Order[]@list }
        FN main() RETURNS Void ->
          ao: Order[] = [Order{ price: 10.0, qty: 2 }];
          us: User[] = [User{ name: "a", discount: 0.9, orders: ao }];
          _ = us AS $u |> UNNEST $u.orders |> WHERE _.qty > 1 |> SUM _.price * $u.discount;
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to match(/if \(.*__bc_inner\.qty > 1/)
      expect(zig).to include("__pipe_u.discount")
    end

    it "supports ALL fold types in a binding chain" do
      src = <<~CLEAR
        STRUCT Order { price: Float64, qty: Int64 }
        STRUCT User { name: String, orders: Order[]@list }
        FN main() RETURNS Void ->
          ao: Order[] = [Order{ price: 5.0, qty: 1 }];
          us: User[] = [User{ name: "x", orders: ao }];
          cnt  = us AS $u |> UNNEST $u.orders |> COUNT TRUE;
          any_ = us AS $u |> UNNEST $u.orders |> ANY _.price > 0.0;
          all_ = us AS $u |> UNNEST $u.orders |> ALL _.qty > 0;
          found = us AS $u |> UNNEST $u.orders |> FIND _.qty == 1;
          mn   = us AS $u |> UNNEST $u.orders |> MIN _.price;
          mx   = us AS $u |> UNNEST $u.orders |> MAX _.price;
          avg  = us AS $u |> UNNEST $u.orders |> AVERAGE _.price;
          RETURN;
        END
      CLEAR
      expect { transpile(src) }.not_to raise_error
    end

    it "CONCURRENT SELECT uses $u as the current element" do
      src = <<~CLEAR
        STRUCT SimpleUser { val: Float64 }
        FN main() RETURNS Void ->
          sus: SimpleUser[] = [SimpleUser{ val: 1.0 }, SimpleUser{ val: 2.0 }];
          _ = sus AS $u |> CONCURRENT(workers: 2) SELECT $u.val * 2.0;
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("CheatLib.concurrentListSelect")
      expect(zig).to include("return (__item.val * 2.0)")
      expect(zig).not_to include("ctx.items[__idx].val")
    end

    it "CONCURRENT SUM uses $u as the current element" do
      src = <<~CLEAR
        STRUCT SimpleUser { val: Float64 }
        FN main() RETURNS Void ->
          sus: SimpleUser[] = [SimpleUser{ val: 1.0 }];
          _ = sus AS $u |> CONCURRENT(workers: 1) SUM $u.val;
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("CheatLib.concurrentListReduce")
      expect(zig).to include("return __item.val")
      expect(zig).not_to include("ctx.items[__idx].val")
    end
  end

  # ===========================================================================
  # AS $v binding error cases
  # ===========================================================================
  describe "AS $v binding error cases" do
    it "raises an error when a pipeline binding is used after the pipeline ends" do
      src = <<~CLEAR
        STRUCT Order { price: Float64 }
        STRUCT User { name: String, orders: Order[]@list }
        FN main() RETURNS Void ->
          users: User[] = [User{ name: "alice", orders: [Order{price: 10.0}] }];
          total = users AS $u |> UNNEST $u.orders |> SUM _.price;
          bad = $u.name;
          RETURN;
        END
      CLEAR
      expect { transpile(src) }.to raise_error(/Undefined pipeline binding '\$u'/)
    end

    it "raises an error when SELECT is used in an AS $v binding chain" do
      src = <<~CLEAR
        STRUCT Order { price: Float64 }
        STRUCT User { name: String, orders: Order[]@list }
        FN main() RETURNS Void ->
          users: User[] = [User{ name: "alice", orders: [Order{price: 10.0}] }];
          total = users AS $u |> UNNEST $u.orders |> SELECT _.price |> SUM _;
          RETURN;
        END
      CLEAR
      expect { transpile(src) }.to raise_error(/SELECT is not supported in AS \$v binding chains/)
    end
  end

  # ===========================================================================
  # Pipeline placeholder field error
  # ===========================================================================
  describe "pipeline placeholder field errors" do
    let(:point_preamble) { <<~CLEAR }
      STRUCT Point { x: Float64, y: Float64 }
      FN main() RETURNS Void ->
        pts: Point[] = [Point{ x: 1.0, y: 2.0 }];
    CLEAR

    it "raises a type error when SUM accesses a non-existent field on _" do
      src = point_preamble + "_ = pts |> SUM _.z; RETURN; END"
      expect { transpile(src) }.to raise_error(/field access 'z'.*Point|Point.*field.*'z'/i)
    end

    it "raises a type error when WHERE accesses a non-existent field on _" do
      src = point_preamble + "_ = pts |> WHERE _.z > 0.0; RETURN; END"
      expect { transpile(src) }.to raise_error(/field access 'z'.*Point|Point.*field.*'z'/i)
    end

    it "raises a type error when SELECT accesses a non-existent field on _" do
      src = point_preamble + "_ = pts |> SELECT _.z; RETURN; END"
      expect { transpile(src) }.to raise_error(/field access 'z'.*Point|Point.*field.*'z'/i)
    end
  end

  it "applies exact stack tier overrides to BG blocks before MIR lowering" do
    zig = ZigTranspiler.new.transpile(<<~CLEAR, exact_tiers: { 0 => :large })
      FN main() RETURNS !Void ->
        p: ~Int64 = BG { @stack -> 1_i64; };
        x: Int64 = NEXT p;
        RETURN;
      END
    CLEAR

    expect(zig).to include(".{ .stack_size = .Large")
  end

  it "lowers catch-wrapped non-error returns through concrete fallible inner functions" do
    zig = ZigTranspiler.new.transpile(<<~CLEAR)
      FN recoverable(flag: Bool) RETURNS String ->
        IF flag THEN
          RAISE Input, "bad";
        END
        RETURN "ok";
      CATCH Input
        RETURN "recovered";
      END
    CLEAR

    expect(zig).to include("fn __recoverable_body")
    expect(zig).to include("anyerror![]const u8")
  end
end
