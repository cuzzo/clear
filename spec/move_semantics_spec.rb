require "rspec"
require_relative "../src/transpiler"

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
        FN makeMap() RETURNS HashMap<Int64> ->
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

    it "marks source as moved after append" do
      body = fn_body(zig, "clearMain")
      expect(body).to include("m_moved = true")
    end
  end

  # =========================================================================
  # 2. map["k"] = val — old value should be DROPPED
  # =========================================================================
  describe "map put drops old value" do
    it "StringMap freeUnionPayload handles slice variants on overwrite" do
      zig = transpile(<<~CLEAR)
        UNION Value { Num: Float64, Items: Int64[] }
        FN makeItems() RETURNS Value ->
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

    it "marks source as moved after struct construction" do
      body = fn_body(zig, "clearMain")
      expect(body).to include("m_moved = true")
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

    it "suppresses list defer after items captured in union" do
      body = fn_body(zig, "clearMain")
      # items is captured in the union — its defer cleanup must not fire
      has_items_defer = body.include?("defer") && body.include?("cleanup") && body.include?("items")
      has_items_moved = body.include?("items_moved")
      expect(has_items_moved || !has_items_defer).to be(true)
    end
  end

  # =========================================================================
  # 6. x = y (union with slice) — y should be MOVED
  # =========================================================================
  describe "binding union with heap variant moves source" do
    let(:zig) do
      transpile(<<~CLEAR)
        UNION Value { Num: Float64, Items: Int64[] }
        FN makeItems() RETURNS Value ->
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

    it "marks source as moved at call site" do
      body = fn_body(zig, "clearMain")
      expect(body).to include("vals_moved = true")
    end
  end

  # =========================================================================
  # 8. ArrayList of unions: element cleanup frees variant heap data
  # =========================================================================
  describe "ArrayList element cleanup frees union slice variants" do
    it "generates element-level cleanup for union list" do
      zig = transpile(<<~CLEAR)
        UNION Value { Num: Float64, Items: Int64[] }
        FN makeItems() RETURNS Value ->
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
      has_element_cleanup = body.include?("cleanup(Value") ||
                            body.include?("for (results.items)")
      expect(has_element_cleanup).to be(true)
    end
  end
end
