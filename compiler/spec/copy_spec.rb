require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/annotator" unless defined?(SemanticAnnotator)
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

RSpec.describe "COPY keyword" do
  def annotate(src)
    tokens = Lexer.new(src).tokenize
    ast = ClearParser.new(tokens, src).parse
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
    ast = ClearParser.new(tokens, "x = COPY y;").parse
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
      UNION Value { Nil, Num: Float64, Lambda { body: Value @boxed, id: Int64 } }
      FN test(v: Value, MUTABLE map: {String}Value) RETURNS !Void ->
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
      UNION Value { Nil, Num: Float64, List: Value[], Lambda { params: Value[], body: Value @boxed, id: Int64 } }
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
      UNION Value { Nil, Num: Float64, Str: String, Lambda { body: Value @boxed, id: Int64 } }
      FN test(v: Value, MUTABLE pool: [Pool(10)]Env) RETURNS !Value ->
          &pool.insert(Env{ x: 1 });
          owned = COPY v;
          RETURN owned;
      END
    CLEAR
    zig = transpile(src)
    expect(zig).to match(/dupeUnionValue|dupeValue\(/)
  end

  # =========================================================================
  # BUG: @boxed union fields shallow-copied when reconstructing variant
  # When a union variant with @boxed fields is reconstructed in a new union
  # literal (e.g. in a MATCH TAKES block), the @boxed field is shallow-copied
  # via HeapCreate (__p.* = val), leaving the new copy pointing at heap memory
  # that is freed by the original binding's cleanup. The fix is to emit
  # dupeUnionValue for @boxed fields whose type is a union.
  # =========================================================================
  it "deep-copies @boxed union fields when reconstructing variant in new union literal" do
    src = <<~CLEAR
      UNION Val { Nil, Box { data: Val @boxed, id: Int64 } }
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
    expect(zig).to match(/dupeUnionValue|dupeValue\(/)
  end
end
