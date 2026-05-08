require "rspec"
require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/annotator"

# Tests that the annotator raises a compile error when a non-Copy variable
# is used after being moved. This is the core borrow checker rule.

RSpec.describe "Use-after-move detection" do
  def annotate(src)
    tokens = Lexer.new(src).tokenize
    ast = Parser.new(tokens, src).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  def expect_error(src, pattern)
    expect { annotate(src) }.to raise_error(CompilerError, pattern)
  end

  def expect_no_error(src)
    expect { annotate(src) }.not_to raise_error
  end

  # =========================================================================
  # 1. v2 = v1 consumes v1. Using v1 after is an error.
  # =========================================================================
  it "raises on use after move via binding" do
    expect_error(<<~CLEAR, /USE AFTER MOVE/)
      UNION Value { Num: Float64, List: Int64[] }
      FN makeList() RETURNS Value ->
          MUTABLE items: Int64[]@list = List[];
          items.append(1_i64);
          RETURN Value{ List: items };
      END
      FN main() RETURNS Void ->
          v1 = makeList();
          v2 = v1;
          v3 = v1;
          RETURN;
      END
    CLEAR
  end

  # =========================================================================
  # 2. items.append(val) consumes val. Using val after is an error.
  # =========================================================================
  it "raises on use after move via append" do
    expect_error(<<~CLEAR, /USE AFTER MOVE/)
      UNION Value { Num: Float64, List: Int64[] }
      FN main() RETURNS Void ->
          MUTABLE v = Value{ Num: 1.0 };
          MUTABLE items: Value[]@list = List[];
          items.append(v);
          items.append(v);
          RETURN;
      END
    CLEAR
  end

  it "reports TAKES when a method argument consumes a value" do
    expect_error(<<~CLEAR, /USE AFTER MOVE.*`item`.*already TOOK.*line 5/m)
      STRUCT Item { v: Int64 }
      FN main() RETURNS Void ->
          MUTABLE pool: Item[10]@pool = [];
          item = Item{ v: 1 };
          pool.insert(item);
          x = item.v;
          RETURN;
      END
    CLEAR
  end

  it "maps move actions to user-facing phrases (active and passive forms)" do
    annotator = SemanticAnnotator.new

    # Active form is used by USE_OF_MOVED_VALUE — the consumer is the
    # subject of the sentence ("`process(GIVE msg)` already GAVE it away").
    expect(annotator.send(:ownership_active_phrase, :give)).to    eq("already GAVE it away")
    expect(annotator.send(:ownership_active_phrase, :takes)).to   eq("already TOOK it away")
    expect(annotator.send(:ownership_active_phrase, :return)).to  eq("already RETURNED it")
    expect(annotator.send(:ownership_active_phrase, :share)).to   eq("already SHARED it")
    expect(annotator.send(:ownership_active_phrase, :move)).to    eq("already MOVED it")
    # Passive form is used by USE_OF_MOVED_PATH — the value (path's
    # owner) is the subject ("its owner `b` was already TAKEN away").
    expect(annotator.send(:ownership_passive_phrase, :give)).to   eq("was already GIVEN away")
    expect(annotator.send(:ownership_passive_phrase, :takes)).to  eq("was already TAKEN away")
    expect(annotator.send(:ownership_passive_phrase, :return)).to eq("was already RETURNED")
    expect(annotator.send(:ownership_passive_phrase, :move)).to   eq("was already MOVED")
  end

  # =========================================================================
  # 3. Struct literal consumes captured variables.
  # =========================================================================
  it "raises on use after move via struct literal" do
    expect_error(<<~CLEAR, /USE AFTER MOVE/)
      STRUCT Container { data: HashMap<Int64> }
      FN main() RETURNS Void ->
          MUTABLE m: HashMap<Int64> = {};
          m["x"] = 1_i64;
          c1 = Container{ data: m };
          c2 = Container{ data: m };
          RETURN;
      END
    CLEAR
  end

  # =========================================================================
  # 4. fn(val) is an implicit borrow — val is NOT consumed.
  #    Calling the same function twice with the same arg is fine.
  # =========================================================================
  it "allows reuse of non-Copy value passed as implicit borrow" do
    expect_no_error(<<~CLEAR)
      UNION Value { Num: Float64, List: Int64[] }
      FN getNum(v: Value) RETURNS Float64 ->
          RETURN 1.0;
      END
      FN main() RETURNS Void ->
          v1 = Value{ Num: 1.0 };
          r1 = getNum(v1);
          r2 = getNum(v1);
          RETURN;
      END
    CLEAR
  end

  # =========================================================================
  # 4b. TAKES fn(val) consumes val. Using val after is an error.
  # =========================================================================
  it "raises on use after move via TAKES" do
    expect_error(<<~CLEAR, /USE AFTER MOVE/)
      FN consume(TAKES items: Int64[]) RETURNS Int64 ->
          RETURN items.length();
      END
      FN main() RETURNS Void ->
          MUTABLE vals: Int64[]@list = List[];
          vals.append(1_i64);
          n = consume(vals);
          n2 = consume(vals);
          RETURN;
      END
    CLEAR
  end

  # =========================================================================
  # 5. Primitives are Copy — no error.
  # =========================================================================
  it "allows reuse of primitive values" do
    expect_no_error(<<~CLEAR)
      FN main() RETURNS Void ->
          x = 42;
          y = x;
          z = x;
          RETURN;
      END
    CLEAR
  end

  # =========================================================================
  # 6. Strings are owned (non-Copy). Assignment moves.
  # =========================================================================
  it "raises on reuse of moved string" do
    expect_error(<<~CLEAR, /USE AFTER MOVE/)
      FN main() RETURNS Void ->
          s = "hello";
          s2 = s;
          s3 = s;
          RETURN;
      END
    CLEAR
  end

  # =========================================================================
  # 7. Rc/Arc are Copy (ref-counted) — no error.
  # =========================================================================
  it "allows reuse of multiowned values" do
    expect_no_error(<<~CLEAR)
      STRUCT Node { value: Int64 }
      FN main() RETURNS Void ->
          n = Node{ value: 1 } @multiowned;
          n2 = n;
          n3 = n;
          RETURN;
      END
    CLEAR
  end

  # =========================================================================
  # 9. GIVE on non-RC types should work (ownership transfer to TAKES param)
  # =========================================================================
  it "allows GIVE on collection type to TAKES parameter" do
    expect_no_error(<<~CLEAR)
      FN consume(TAKES items: Int64[]) RETURNS Int64 ->
          RETURN items.length();
      END
      FN main() RETURNS Void ->
          MUTABLE vals: Int64[]@list = List[];
          vals.append(1_i64);
          n = consume(GIVE vals);
          RETURN;
      END
    CLEAR
  end

  it "allows GIVE on union type to TAKES parameter" do
    expect_no_error(<<~CLEAR)
      UNION Value { Num: Float64, List: Int64[] }
      FN consume(TAKES v: Value) RETURNS Float64 ->
          RETURN 1.0;
      END
      FN main() RETURNS Void ->
          v = Value{ Num: 1.0 };
          r = consume(GIVE v);
          RETURN;
      END
    CLEAR
  end

  it "rejects GIVE on Copy types" do
    expect_error(<<~CLEAR, /Copy/)
      FN consume(x: Float64) RETURNS Float64 ->
          RETURN x;
      END
      FN main() RETURNS Void ->
          n = 42.0;
          r = consume(GIVE n);
          RETURN;
      END
    CLEAR
  end

  # =========================================================================
  # 8. Single use is fine — no error.
  # =========================================================================
  it "allows single use of non-Copy value" do
    expect_no_error(<<~CLEAR)
      UNION Value { Num: Float64, List: Int64[] }
      FN makeList() RETURNS !Value ->
          MUTABLE items: Int64[]@list = List[];
          items.append(1_i64);
          RETURN Value{ List: items };
      END
      FN main() RETURNS Void ->
          v1 = makeList();
          v2 = v1;
          RETURN;
      END
    CLEAR
  end

  # =========================================================================
  # Union with @indirect inline struct variant is non-Copy.
  # @indirect creates a *T heap pointer - by-value copy creates shared
  # ownership of the same pointer, which is an illegal state (double-free).
  # =========================================================================
  it "raises on use after move for union with @indirect struct variant" do
    expect_error(<<~CLEAR, /USE AFTER MOVE/)
      UNION Value { Nil, Num: Float64, Lambda { body: Value @indirect, id: Int64 } }
      FN makeLambda!() RETURNS Value ->
          RETURN Value.Lambda{ body: Value{ Num: 42.0 }, id: 1 };
      END
      FN main() RETURNS Void ->
          v1 = makeLambda!();
          v2 = v1;
          v3 = v1;
          RETURN;
      END
    CLEAR
  end

end
