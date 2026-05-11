require "rspec"
require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/annotator"
require_relative "../src/backends/transpiler"

RSpec.describe "COPY keyword" do
  def annotate(src)
    tokens = Lexer.new(src).tokenize
    ast = Parser.new(tokens, src).parse
    ann = SemanticAnnotator.new
    ann.annotate!(ast)
    [ast, ann]
  end

  def transpile(src)
    ZigTranspiler.new.transpile(src)
  end

  def expect_error(src, pattern)
    expect { annotate(src) }.to raise_error(CompilerError, pattern)
  end

  # =========================================================================
  # Parsing: COPY produces a CopyNode AST
  # =========================================================================
  it "parses COPY as an expression" do
    tokens = Lexer.new("x = COPY y;").tokenize
    ast = Parser.new(tokens, "x = COPY y;").parse
    bind = ast.statements.first
    expect(bind.value).to be_a(AST::CopyNode)
    expect(bind.value.value).to be_a(AST::Identifier)
    expect(bind.value.value.name).to eq("y")
  end

  # =========================================================================
  # COPY of a borrowed parameter produces an owned value
  # =========================================================================
  it "allows storing COPY of borrowed parameter into HashMap" do
    src = <<~CLEAR
      UNION Value { Nil, Num: Float64, Lambda { body: Value @indirect, id: Int64 } }
      FN test!(v: Value, MUTABLE map: HashMap<Value>) RETURNS !Void ->
          owned = COPY v;
          map["key"] = owned;
          RETURN;
      END
    CLEAR
    expect { annotate(src) }.not_to raise_error
  end

  # =========================================================================
  # COPY of a slice produces an owned copy
  # =========================================================================
  it "allows storing COPY of borrowed slice into union variant" do
    src = <<~CLEAR
      UNION Value { Nil, Num: Float64, List: Value[], Lambda { params: Value[], body: Value @indirect, id: Int64 } }
      FN test(items: Value[]) RETURNS !Value ->
          ownedItems = COPY items;
          RETURN Value.Lambda{ params: ownedItems, body: Value{ Num: 0.0 }, id: 1 };
      END
    CLEAR
    expect { annotate(src) }.not_to raise_error
  end

  # =========================================================================
  # Transpiler emits dupeUnionValue for COPY of union type
  # =========================================================================
  it "emits dupeUnionValue for COPY of union" do
    src = <<~CLEAR
      STRUCT Env { x: Int64 }
      UNION Value { Nil, Num: Float64, Str: String, Lambda { body: Value @indirect, id: Int64 } }
      FN test!(v: Value, MUTABLE pool: Env[10]@pool) RETURNS !Value ->
          pool.insert(Env{ x: 1 });
          owned = COPY v;
          RETURN owned;
      END
    CLEAR
    zig = transpile(src)
    expect(zig).to include("dupeUnionValue")
  end

  # =========================================================================
  # BUG: @indirect union fields shallow-copied when reconstructing variant
  # When a union variant with @indirect fields is reconstructed in a new union
  # literal (e.g. in a MATCH TAKES block), the @indirect field is shallow-copied
  # via HeapCreate (__p.* = val), leaving the new copy pointing at heap memory
  # that is freed by the original binding's cleanup. The fix is to emit
  # dupeUnionValue for @indirect fields whose type is a union.
  # =========================================================================
  it "deep-copies @indirect union fields when reconstructing variant in new union literal" do
    src = <<~CLEAR
      UNION Val { Nil, Box { data: Val @indirect, id: Int64 } }
      FN rebuild(TAKES v: Val) RETURNS !Val ->
          PARTIAL MATCH TAKES v START
              Val.Box AS b ->
                  RETURN Val.Box{ data: b.data, id: b.id };,
              DEFAULT -> RETURN Val.Nil;
          END
          RETURN Val.Nil;
      END
    CLEAR
    zig = transpile(src)
    expect(zig).to include("dupeUnionValue")
  end
end
