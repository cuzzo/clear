require "rspec"
require_relative "../src/backends/transpiler"
require_relative "../src/ast/ast"

RSpec.describe "annotator branch gap burndown" do
  def annotate_source(source)
    tokens = Lexer.new(source).tokenize
    ast = Parser.new(tokens, source).parse
    SemanticAnnotator.new(source_code: source).annotate!(ast)
    ast
  end

  def expect_compile(source)
    expect { annotate_source(source) }.not_to raise_error
  end

  def expect_reject(source)
    expect { annotate_source(source) }.to raise_error(CompilerError)
  end

  def token(type = :VAR_ID, value = "x")
    Lexer::Token.new(type, value, 1, 1)
  end

  it "covers representable capability conflict validation directly" do
    type = Type.new(:Counter)
    type.ownership = :shared
    type.soa = true

    expect(Capabilities.errors_for(type)).to eq(["SOA layout is incompatible with reference-counted ownership"])
  end

  it "covers high-rank access, call, loop, match, and capability source shapes" do
    positive = [
      <<~CHT,
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          MUTABLE c = Counter{ value: 1_i64 } @locked;
          c.value = c.value + 1_i64;
          RETURN;
        END
      CHT
      <<~CHT,
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          MUTABLE c = Counter{ value: 1_i64 } @locked;
          WITH EXCLUSIVE c {
            c.value = c.value + 1_i64;
          }
          RETURN;
        END
      CHT
      <<~CHT,
        UNION Box { Empty, Item: String @indirect }
        FN main() RETURNS Void ->
          b = Box{ Item: COPY "abc" };
          RETURN;
        END
      CHT
      <<~CHT,
        UNION Box { Empty, Item: String @indirect }
        top = Box{ Item: COPY "abc" };
      CHT
      <<~CHT,
        UNION Value { Nil, Lambda { body: Value @indirect } }
        top = Value.Lambda{ body: Value.Nil };
      CHT
      <<~CHT,
        STRUCT Box { label: String }
        UNION Shape { Empty, Named { label: String }, Boxed: Box @indirect }
        FN main() RETURNS Void ->
          s = Shape.Named{ label: COPY "abc" };
          PARTIAL MATCH TAKES s START
            Shape.Named AS n -> n.label.length();,
            Shape.Empty -> 0_i64;
          END
          RETURN;
        END
      CHT
      <<~CHT,
        FN make(flag: Bool) RETURNS !String ->
          IF flag THEN RETURN COPY "ok"; END
          RAISE Input;
        END
        FN main() RETURNS !Void ->
          s: String = make(TRUE) OR RAISE;
          ASSERT s.length() == 2_i64, "fallible return";
          RETURN;
        END
      CHT
      <<~CHT,
        FN by_name(x: String) RETURNS x:String -> RETURN x; END
        FN main() RETURNS Void ->
          s: String = COPY "abc";
          out: String = by_name(s);
          ASSERT out.length() == 3_i64, "named lifetime";
          RETURN;
        END
      CHT
      <<~CHT,
        FN by_any(x: String) RETURNS *:String -> RETURN x; END
        FN main() RETURNS Void ->
          s: String = COPY "abc";
          out: String = by_any(s);
          ASSERT out.length() == 3_i64, "wildcard lifetime";
          RETURN;
        END
      CHT
      <<~CHT,
        FN inc(x: Int64) RETURNS Int64 -> RETURN x + 1_i64; END
        FN main() RETURNS !Void ->
          a = 1_i64 |> inc;
          b = 2_i64 |> inc();
          RETURN;
        CATCH Input
          RETURN;
        END
      CHT
      <<~CHT,
        FN risky(x: Int64) RETURNS !Int64 ->
          IF x > 0_i64 THEN RETURN x; END
          RAISE Input;
        END
        FN main() RETURNS !Void ->
          y = 1_i64 |> risky();
          ASSERT y == 1_i64, "pipe unwrap";
          RETURN;
        CATCH Input
          RETURN;
        END
      CHT
      <<~CHT,
        FN main() RETURNS Void ->
          1_i64 |> print;
          RETURN;
        END
      CHT
      <<~CHT,
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          MUTABLE c = Counter{ value: 1_i64 } @indirect:atomic;
          WITH SNAPSHOT c AS MUTABLE x {
            x.value = x.value + 1_i64;
          } ON AtomicConflict RAISE
          RETURN;
        END
      CHT
      <<~CHT,
        STRUCT Counter { value: Int64 }
        FN bump!(MUTABLE c: Counter) RETURNS Void -> c.value = c.value + 1_i64; RETURN; END
        FN main() RETURNS Void ->
          MUTABLE c = Counter{ value: 1_i64 };
          bump!(c);
          RETURN;
        END
      CHT
      <<~CHT,
        FN main() RETURNS Void ->
          src: ~?Int64[] = BG STREAM {
            YIELD 1_i64;
            YIELD 2_i64;
          };
          running: ~Int64@observable = src |> SUM _;
          ASSERT (NEXT running) == 3_i64, "observable dest";
          RETURN;
        END
      CHT
      <<~CHT,
        FN main() RETURNS Void ->
          MUTABLE items: HashMap<Int64> = {};
          items["a"] = 1_i64;
          items["b"] = 2_i64;
          FOR k IN items DO
            v = items[k] OR 0_i64;
            IF v == 1_i64 THEN CONTINUE; END
          END
          RETURN;
        END
      CHT
      <<~CHT,
        STRUCT Box { values: Int64[]@list }
        FN main() RETURNS Void ->
          MUTABLE xs: Int64[]@list = [];
          xs.append(1_i64);
          b = Box{ values: xs };
          MUTABLE out: Int64[]@list = [];
          out.append(b.values[0_i64]);
          RETURN;
        END
      CHT
      <<~CHT,
        FN make() RETURNS ~String -> RETURN BG { COPY "abc"; }; END
        FN main() RETURNS Void ->
          h = make();
          s: String = NEXT h;
          ASSERT s.length() == 3_i64, "shared promise next";
          RETURN;
        END
      CHT
    ]

    negative = [
      <<~CHT,
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          c = Counter{ value: 1_i64 } @locked;
          x = c.value;
          RETURN;
        END
      CHT
      <<~CHT,
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          c = Counter{ value: 1_i64 } @indirect:atomic;
          x = c.value;
          RETURN;
        END
      CHT
      <<~CHT,
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          c = Counter{ value: 1_i64 };
          WITH SNAPSHOT c AS x { x.value; }
          RETURN;
        END
      CHT
      <<~CHT,
        FN main() RETURNS Void ->
          xs: Int64[] = [1_i64, 2_i64];
          WHILE xs.pop() AS v DO
            s: String = COPY "owned";
            GIVE s;
          END
          RETURN;
        END
      CHT
      <<~CHT,
        FN bad(x: Int64) RETURNS x.missing:Int64 -> RETURN x; END
      CHT
      <<~CHT,
        FN hold(MUTABLE x: String) RETURNS *:String -> RETURN x; END
        FN main() RETURNS Void ->
          MUTABLE s: String = COPY "abc";
          out: String = hold(s);
          RETURN;
        END
      CHT
    ]

    positive.each { |source| expect_compile(source) }
    negative.each { |source| expect_reject(source) }
  end

  it "covers literal source span recovery branches directly" do
    ann = SemanticAnnotator.new(source_code: "missing\nplain = \"abc\"\nesc = \"a\\\\\"b\"\ntriple = \"\"\"abc\"\"\"\nopen = \"\"\"abc\nnum = 123_456_i64\n")
    tok_missing = Lexer::Token.new(:STRING, "x", 99, 1)
    tok_plain = Lexer::Token.new(:STRING, "abc", 2, 9)
    tok_escape = Lexer::Token.new(:STRING, "a\"b", 3, 7)
    tok_triple = Lexer::Token.new(:STRING, "abc", 4, 10)
    tok_open = Lexer::Token.new(:STRING, "abc", 5, 8)
    tok_number = Lexer::Token.new(:NUMBER, "123_456_i64", 6, 7)

    expect(ann.send(:literal_source_length, tok_missing)).to eq(1)
    expect(ann.send(:literal_source_length, tok_plain)).to eq(5)
    expect(ann.send(:literal_source_length, tok_escape)).to eq(5)
    expect(ann.send(:literal_source_length, tok_triple)).to eq(9)
    expect(ann.send(:literal_source_length, tok_open)).to eq(3)
    expect(ann.send(:literal_source_length, tok_number)).to eq(11)
  end

  it "covers collection narrowing helper branches directly" do
    ann = SemanticAnnotator.new(source_code: "")
    sig = FunctionSignature.new(params: [], return_type: Type.new(:Void))
    sig.emit = IntrinsicEmit.new(narrows_collection: true)

    list_type = Type.new(:"Any[]", collection: :list)
    list_type.shard_count = 2
    list_type.provenance = :heap
    list_type.elem_ownership = :shared
    list_type.elem_sync = :locked
    sym = SymbolEntry.new(reg: "xs", type: list_type, mutable: true, storage: :heap)

    list = AST::Identifier.new(token, "xs")
    list.symbol = sym
    value = AST::Literal.new(token(:NUMBER, "1_i64"), :INT64, 1, :stack)
    value.full_type = Type.new(:Int64)

    ann.send(:narrow_collection_type!, sig, [list, value])

    expect(sym.type.element_type.resolved).to eq(:Int64)
    expect(sym.type.collection).to eq(:list)
    expect(sym.type.shard_count).to eq(2)
    expect(sym.type.provenance).to eq(:heap)
    expect(sym.type.elem_ownership).to eq(:shared)
    expect(sym.type.elem_sync).to eq(:locked)
    expect(list.full_type.element_type.resolved).to eq(:Int64)
  end

  it "covers borrow source resolver branches directly" do
    ann = SemanticAnnotator.new(source_code: "")
    source = AST::Identifier.new(token, "source")

    intrinsic = FunctionSignature.new(params: [], return_type: Type.new(:String))
    intrinsic.arg_spec = [{ name: "value" }]
    intrinsic.emit = IntrinsicEmit.new(lifetime: ["value"])
    intrinsic_call = AST::FuncCall.new(token, "borrow_intrinsic", [source])
    intrinsic_call.matched_stdlib_def = intrinsic
    expect(ann.send(:resolve_borrow_source, intrinsic_call)).to equal(source)

    self_lifetime = FunctionSignature.new(params: [], return_type: Type.new(:String))
    self_lifetime.emit = IntrinsicEmit.new(lifetime: ["self"])
    method_call = AST::MethodCall.new(token, source, "trim", [])
    method_call.matched_stdlib_def = self_lifetime
    expect(ann.send(:resolve_borrow_source, method_call)).to equal(source)

    user_sig = FunctionSignature.new(
      params: [AST::Param.new(name: "x", type: Type.new(:String))],
      return_type: Type.new(:String),
      return_lifetime: ["x"]
    )
    wildcard_sig = FunctionSignature.new(
      params: [AST::Param.new(name: "x", type: Type.new(:String))],
      return_type: Type.new(:String),
      return_lifetime: :wildcard
    )
    scope = Struct.new(:entries) do
      def resolve_type(name) = entries[name]
    end.new({ "borrow_user" => user_sig, "borrow_any" => wildcard_sig })
    ann.define_singleton_method(:lookup_scope_for) { |name| scope if scope.entries.key?(name) }

    expect(ann.send(:resolve_borrow_source, AST::MethodCall.new(token, source, "borrow_user", []))).to equal(source)
    expect(ann.send(:resolve_borrow_source, AST::FuncCall.new(token, "borrow_any", [source]))).to be_nil
    expect(ann.send(:resolve_borrow_source, AST::FuncCall.new(token, "missing", [source]))).to be_nil
  end

  it "covers retryable WITH fallible source discovery branches directly" do
    ann = SemanticAnnotator.new(source_code: "")
    arg = AST::Literal.new(token(:STRING, "x"), :STRING, "x", :rodata)
    fn = AST::FuncCall.new(token, "fallible_fn", [arg])
    fn.error_union_type = Type.new(:"!String")
    method = AST::MethodCall.new(token, AST::Identifier.new(token, "s"), "fallible_method", [arg])
    method.define_singleton_method(:error_union_type) { Type.new(:"!String") }
    static = AST::StaticCall.new(token, AST::Identifier.new(token(:TYPE_ID, "Box"), "Box"), "fallible_static", [arg])
    static.define_singleton_method(:error_union_type) { Type.new(:"!String") }
    frozen = AST::FreezeNode.new(token(:FREEZE, "FREEZE"), fn)

    sources = ann.send(:retryable_with_fallible_sources, [
      { nested: [AST::Raise.new(token(:RAISE, "RAISE"), nil, nil, nil), AST::OrRaise.new(token(:OR, "OR"))] },
      method,
      static,
      frozen
    ])

    expect(sources).to include("RAISE", "OR RAISE", "fallible_fn", "fallible_method()", "fallible_static", "FREEZE")
  end
end
