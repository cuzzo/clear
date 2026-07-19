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

  it "keeps COPY of String@symbol as a non-owning static value" do
    zig = transpile(<<~CLEAR)
      FN keep(name: String@symbol) RETURNS String@symbol ->
        RETURN COPY name;
      END
    CLEAR

    body = zig[/fn keep\b.*?\n(.*?)^}/m, 1]
    expect(body).not_to include("dupeValue")
    expect(body).not_to include(".dupe(u8")
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

  it "keeps TRY of an indexed cleanup-bearing value borrowed through MIR lowering" do
    src = <<~CLEAR
      STRUCT Managed { text: String }
      FN inspect(items: []Managed) RETURNS !Void ->
        item = TRY items[0];
        ASSERT item.text == "kept by container";
      END
    CLEAR

    expect { transpile(src) }.not_to raise_error
  end

  it "lets COPY explicitly own a value obtained through TRY indexing" do
    src = <<~CLEAR
      STRUCT Managed { text: String }
      FN extract(items: []Managed) RETURNS !Managed ->
        item = COPY TRY items[0];
        RETURN item;
      END
    CLEAR

    expect { transpile(src) }.not_to raise_error
  end

  it "copies an optional indexed value before an enclosing UNWRAP consumes it" do
    zig = transpile(<<~CLEAR)
      UNION Value { Text: String }
      FN first(items: []Value) RETURNS Value ->
        RETURN UNWRAP COPY items[0];
      END
    CLEAR

    expect(zig).to include("dupeValue(?Value")
    expect(zig).not_to match(/dupeValue\(Value,\s*CheatLib\.getAtOpt/)
  end

  it "preserves the pointer-backed representation when copying a sync wrapper" do
    zig = transpile(<<~CLEAR)
      STRUCT Counter { value: Int64 }
      FN main() RETURNS Void ->
        counter = Counter{ value: 1 } @versioned;
        duplicate = COPY counter;
        WITH SNAPSHOT duplicate AS view { ASSERT view.value == 1; }
        RETURN;
      END
    CLEAR

    copy_line = T.must(zig.lines.find { |line| line.include?("var duplicate = blk_copy") })
    expect(copy_line).to include("dupeValue(@TypeOf(counter), __copy_src")
    expect(copy_line).not_to include("dupeValue(CheatLib.Versioned(Counter), __copy_src.*")
  end

  it "returns a copied optional value from dynamic-list indexing without changing its ownership capability" do
    src = <<~CLEAR
      STRUCT Type { value: Int64 }
      FN at(items: []Type, index: Int64) RETURNS ?Type ->
        RETURN COPY items[index];
      END
    CLEAR

    expect { transpile(src) }.not_to raise_error
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

  it "rejects COPY transitively through every linear-resource wrapper" do
    cases = {
      direct: ["Probe", "makeProbe()"],
      optional: ["?Probe", "makeProbe()"],
      tuple: ["Tuple<Probe, Int64>", "Tuple{makeProbe(), 1}"],
      struct: ["Owner", "Owner{ probe: makeProbe() }"],
      generic: ["Box<Probe>", "Box<Probe>{ value: makeProbe() }"],
      union: ["Choice", "Choice{ Value: makeProbe() }"],
      list: ["Probe[]@list", "[makeProbe()]"],
      map: ["HashMap<Probe>", '{"probe": makeProbe()}'],
    }

    cases.each do |name, (type, value)|
      src = <<~CLEAR
        EXTERN STRUCT Probe { id: Int64 } CLOSE "deinit" FROM "probe";
        EXTERN FN makeProbe() RETURNS Probe FROM "probe";
        STRUCT Owner { probe: Probe }
        STRUCT Box<T> { value: T }
        UNION Choice { Empty, Value: Probe }
        FN main() RETURNS Void ->
          source: #{type} = #{value};
          copied: #{type} = COPY source;
          RETURN;
        END
      CLEAR

      expect { annotate(src) }
        .to raise_error(CompilerError, /Cannot COPY non-copyable type/i), name.to_s
    end
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
