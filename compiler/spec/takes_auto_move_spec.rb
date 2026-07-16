require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/annotator" unless defined?(SemanticAnnotator)
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

# TAKES should automatically move the argument — no explicit GIVE needed.
# After calling fn(TAKES val), val is consumed. Using val again is an error.

RSpec.describe "TAKES auto-move" do
  def annotate(src)
    tokens = Lexer.new(src).tokenize
    ast = ClearParser.new(tokens, src).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  def transpile(src)
    ZigTranspiler.new.transpile(src)
  end

  it "calling TAKES fn without GIVE compiles (auto-move)" do
    expect {
      annotate(<<~CLEAR)
        FN consume(TAKES v: Int64[]) RETURNS Int64 ->
            RETURN v.length();
        END
        FN main() RETURNS Void ->
            MUTABLE vals: []Int64 = List[];
            vals.append(1_i64);
            n = consume(vals);
            RETURN;
        END
      CLEAR
    }.not_to raise_error
  end

  it "requires an explicit snapshot when STRICT sees a later use" do
    expect {
      annotate(<<~CLEAR)
        UNION Value { Num: Float64, List: Int64[] }
        FN consume(TAKES v: Value) RETURNS Float64 ->
            RETURN 1.0;
        END
        FN main() RETURNS Void ->
            MUTABLE v = Value{ Num: 1.0 };
            r1 = consume(v);
            r2 = consume(v);
            RETURN;
        END
      CLEAR
    }.to raise_error(CompilerError, /USE AFTER MOVE.*`v`/m)
  end

  it "does not leak moved local state into a later function with the same local name" do
    expect {
      transpile(<<~CLEAR)
        FN first() RETURNS !Void ->
            p: ~Int64 = BG { 1_i64; };
            r = NEXT p;
            RETURN;
        END

        FN second() RETURNS !Void ->
            values: []Int64 = [1, 2, 3];
            FOR p IN (0 ..< values.length()) DO
                r = values[p];
            END
            RETURN;
        END

        FN main() RETURNS !Void ->
            first() OR_ELSE RAISE;
            second() OR_ELSE RAISE;
            RETURN;
        END
      CLEAR
    }.not_to raise_error
  end

  it "eliminates v cleanup when always consumed by TAKES" do
    zig = transpile(<<~CLEAR)
      UNION Value { Num: Float64, List: Int64[] }
      FN consume(TAKES v: Value) RETURNS Float64 ->
          RETURN 1.0;
      END
      FN main() RETURNS Void ->
          MUTABLE v = Value{ Num: 1.0 };
          r = consume(v);
          RETURN;
      END
    CLEAR
    body = zig[/fn clearMain.*?\n(.*?)^}/m, 1]
    # v is transferred into the TAKES call; the guard records that transfer.
    expect(body).to include("v_moved = true")
  end

  it "RETURN fn(TAKES arg) eliminates cleanup when always moved" do
    zig = transpile(<<~CLEAR)
      UNION Value { Num: Float64, List: Int64[] }
      FN makeValue() RETURNS !Value ->
          MUTABLE items: []Int64 = List[];
          items.append(1_i64);
          RETURN Value{ List: items };
      END
      FN consume(TAKES v: Value) RETURNS Float64 ->
          RETURN 1.0;
      END
      FN main() RETURNS Float64 ->
          ast = makeValue();
          RETURN consume(ast);
      END
    CLEAR
    body = zig[/fn clearMain.*?\n(.*?)^}/m, 1]
    # The RETURN call is still an ownership boundary: the guarded cleanup is
    # suppressed by an explicit move mark before the callee takes ownership.
    expect(body).to include("ast_moved = true")
  end

  it "TAKES + RETURN eliminates caller defer (no double-free)" do
    zig = transpile(<<~CLEAR)
      UNION Value { Num: Float64, List: Int64[] }
      FN passthrough(TAKES v: Value) RETURNS Value ->
          RETURN v;
      END
      FN main() RETURNS Void ->
          MUTABLE v = Value{ Num: 1.0 };
          result = passthrough(v);
          RETURN;
      END
    CLEAR
    body = zig[/fn clearMain.*?\n(.*?)^}/m, 1]
    # v is transferred into the TAKES call; the guard records that transfer.
    expect(body).to include("v_moved = true")
  end
end
