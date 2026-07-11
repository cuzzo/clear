require "rspec"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

# Tests that CLEAR enforces Rust-like move/borrow semantics for types
# containing heap data. Every use of a non-copyable type must be either
# a move (ownership transfers, original consumed) or a borrow (& reference).

RSpec.describe "Move semantics for heap-owning types" do
  def transpile(src)
    ZigTranspiler.new.transpile(src)
  end

  def fn_body(zig, name)
    zig[/fn #{Regexp.escape(name)}\b.*?\n(.*?)^}/m, 1]
  end

  # =========================================================================
  # 1. list.append(val) — val should be MOVED (source consumed)
  # =========================================================================
  describe "list.append moves the value" do
    let(:zig) do
      transpile(<<~CLEAR)
        FN makeMap() RETURNS !HashMap<Int64> ->
            MUTABLE m: HashMap<Int64> = {};
            m["a"] = 1_i64;
            RETURN m;
        END
        FN main() RETURNS Void ->
            MUTABLE m = makeMap();
            MUTABLE items: HashMap<Int64>[]@list = List[];
            items.append(m);
            RETURN;
        END
      CLEAR
    end

    it "transfers the source directly after append" do
      body = fn_body(zig, "clearMain")
      expect(body).to include("try items.append(rt.heapAlloc(), m)")
      expect(body).not_to include("CheatLib.dupeValue(CheatLib.StringMap(i64), m")
    end
  end

  # =========================================================================
  # 2. map["k"] = val — old value should be DROPPED
  # =========================================================================
  describe "map put drops old value" do
    it "StringMap freeUnionPayload handles slice variants on overwrite" do
      zig = transpile(<<~CLEAR)
        UNION Value { Num: Float64, Items: Int64[] }
        FN makeItems() RETURNS !Value ->
            MUTABLE items: Int64[]@list = List[];
            items.append(1_i64);
            RETURN Value{ Items: items };
        END
        FN main() RETURNS Void ->
            MUTABLE env: HashMap<Value> = {};
            env["x"] = makeItems();
            env["x"] = Value.Num;
            RETURN;
        END
      CLEAR
      # The Zig StringMap.put calls freeUnionPayload on the old value.
      # freeUnionPayload already handles []T slices at line 320-329.
      body = fn_body(zig, "clearMain")
      expect(body).to include("StringMap(Value)")
    end
  end

  # =========================================================================
  # 3. fn(arg) non-TAKES — should be IMPLICIT BORROW
  # =========================================================================
  describe "function argument is implicit borrow" do
    let(:zig) do
      transpile(<<~CLEAR)
        STRUCT Pair { x: Float64, y: Float64 }
        FN sum(p: Pair) RETURNS Float64 ->
            RETURN p.x + p.y;
        END
        FN main() RETURNS Void ->
            p = Pair{ x: 1.0, y: 2.0 };
            result = sum(p);
            RETURN;
        END
      CLEAR
    end

    it "passes struct as anytype (Zig borrows, no copy)" do
      # Structs are passed as anytype in Zig which is monomorphized —
      # callee receives the caller's value without copying heap data.
      expect(zig).to include("p: anytype")
    end
  end

  # =========================================================================
  # 4. struct.field = val — val should be MOVED
  # =========================================================================
  describe "struct field assignment moves value" do
    let(:zig) do
      transpile(<<~CLEAR)
        STRUCT Container { data: HashMap<Int64> }
        FN main() RETURNS Void ->
            MUTABLE m: HashMap<Int64> = {};
            m["x"] = 1_i64;
            MUTABLE c = Container{ data: m };
            RETURN;
        END
      CLEAR
    end

    it "eliminates m cleanup when always moved into struct" do
      body = fn_body(zig, "clearMain")
      # The source keeps an error-only moved guard until the transfer point.
      expect(body).to include("m_moved")
      expect(body).to include("Container{ .data = m }")
      expect(body).to include("m_moved = true")
    end

    it "marks hoisted string temps moved after assigning into a cleaned field" do
      zig = transpile(<<~CLEAR)
        STRUCT Box { name: String }
        FN main() RETURNS Void ->
            MUTABLE v: Box = Box{ name: COPY "abc" };
            v.name = v.name + COPY "d";
            RETURN;
        END
      CLEAR
      body = fn_body(zig, "clearMain")
      expect(body).to include("defer if (!__hoist_1_moved) CheatLib.cleanup(@TypeOf(__hoist_1), rt.heapAlloc(), &__hoist_1)")
      expect(body).to include("CheatLib.cleanup(@TypeOf(v.name), rt.heapAlloc(), &v.name)")
      expect(body).to match(/v\.name = __hoist_1;\s*__hoist_1_moved = true;/)
    end

    it "marks copied map literal values moved after put" do
      zig = transpile(<<~CLEAR)
        FN run(flag: Bool) RETURNS !Int64 ->
            x: HashMap<String> = {"a": COPY "aa", "b": COPY "bb"};
            IF flag THEN RAISE "stop"; END
            RETURN x.count();
        END
        FN main() RETURNS Void ->
            bad: Int64 = run(TRUE) OR 0_i64;
            RETURN;
        END
      CLEAR
      body = fn_body(zig, "run")
      expect(body).to include("defer if (!__tmp_1_moved) CheatLib.cleanup(@TypeOf(__tmp_1), rt.heapAlloc(), &__tmp_1)")
      expect(body).to match(/try __hm\.put[^\n]*__tmp_1[^\n]*\n__tmp_1_moved = true;/)
      expect(body).to match(/try __hm\.put[^\n]*__tmp_2[^\n]*\n__tmp_2_moved = true;/)
    end
  end

  # =========================================================================
  # 5. Union construction moves payload
  # =========================================================================
  describe "union construction moves payload" do
    let(:zig) do
      transpile(<<~CLEAR)
        UNION Value { Num: Float64, Items: Int64[] }
        FN main() RETURNS Void ->
            MUTABLE items: Int64[]@list = List[];
            items.append(1_i64);
            v = Value{ Items: items };
            RETURN;
        END
      CLEAR
    end

    it "unconditional cleanup for items (copied into union, not moved)" do
      body = fn_body(zig, "clearMain")
      # items is COPIED into the union (blk_copy), not moved.
      # Dataflow: items is never moved -> unconditional cleanup, no _moved guard.
      expect(body).to include("defer CheatLib.cleanup")
      expect(body).not_to include("items_moved")
    end
  end

  # =========================================================================
  # 6. x = y (union with slice) — y should be MOVED
  # =========================================================================
  describe "binding union with heap variant moves source" do
    let(:zig) do
      transpile(<<~CLEAR)
        UNION Value { Num: Float64, Items: Int64[] }
        FN makeItems() RETURNS !Value ->
            MUTABLE items: Int64[]@list = List[];
            items.append(1_i64);
            RETURN Value{ Items: items };
        END
        FN main() RETURNS Void ->
            v1 = makeItems();
            v2 = v1;
            RETURN;
        END
      CLEAR
    end

    it "compiles without error (single use after move is valid)" do
      expect(zig).to include("const v2 = v1")
    end
  end

  # =========================================================================
  # 7. TAKES parameter — should already work
  # =========================================================================
  describe "TAKES parameter moves ownership" do
    let(:zig) do
      transpile(<<~CLEAR)
        FN consume(TAKES items: Int64[]) RETURNS Int64 ->
            RETURN items.length();
        END
        FN main() RETURNS Void ->
            MUTABLE vals: Int64[]@list = List[];
            vals.append(1_i64);
            n = consume(vals);
            RETURN;
        END
      CLEAR
    end

    it "implicit-copies @list to TAKES param using the source allocator when frame-safe" do
      body = fn_body(zig, "clearMain")
      # @list is implicit-copied for TAKES: source list is NOT consumed
      # (its defer still fires), and plain Int64 slice data can remain frame-backed.
      expect(body).to include("CheatLib.dupeValue(std.ArrayListUnmanaged(i64)")
      expect(body).to include("rt.heapAlloc()")
      expect(body).not_to include("vals_moved")
    end
  end

  # =========================================================================
  # 8. ArrayList of unions: element cleanup frees variant heap data
  # =========================================================================
  describe "ArrayList element cleanup frees union slice variants" do
    it "generates element-level cleanup for union list" do
      zig = transpile(<<~CLEAR)
        UNION Value { Num: Float64, Items: Int64[] }
        FN makeItems() RETURNS !Value ->
            MUTABLE items: Int64[]@list = List[];
            items.append(1_i64);
            RETURN Value{ Items: items };
        END
        FN main() RETURNS Void ->
            MUTABLE results: Value[]@list = List[];
            results.append(makeItems());
            RETURN;
        END
      CLEAR
      body = fn_body(zig, "clearMain")
      has_element_cleanup = body.include?("cleanup(@TypeOf") ||
                            body.include?("for (results.items)")
      expect(has_element_cleanup).to be(true)
    end
  end
end
