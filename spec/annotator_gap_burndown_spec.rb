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

  def quiet_annotator
    ann = SemanticAnnotator.new(source_code: "")
    errors = []
    ann.define_singleton_method(:error!) do |node, code, *args, **kwargs|
      errors << [node, code, args, kwargs]
      nil
    end
    ann.define_singleton_method(:fixable!) do |node, **kwargs|
      errors << [node, :fixable, [], kwargs]
      nil
    end
    ann.define_singleton_method(:og_declare) { |_name, _node, _type_info| nil }
    ann.instance_variable_set(:@direct_errors, errors)
    ann
  end

  def parse_source(source)
    Parser.new(Lexer.new(source).tokenize, source).parse
  end

  def function_from(source, name)
    parse_source(source).statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == name }
  end

  def auto_type
    t = Type.new(:Auto, auto: true)
    t.auto_token = token(:TYPE_ID, "Auto")
    t
  end

  def direct_errors(ann)
    ann.instance_variable_get(:@direct_errors)
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


  it "covers direct annotator diagnostic branch clusters without a corpus template" do
    expect { annotate_source("FN main() RETURNS Void -> x: Missing<Int64> = 1_i64; RETURN; END") }.to raise_error(CompilerError)

    unknown = AST::StructLit.new(nil, "Missing", {}, :stack, nil)
    expect { SemanticAnnotator.new(source_code: "").send(:visit_StructLit, unknown) }.to raise_error(CompilerError)

    lit = AST::Literal.new(token(:NUMBER, "1_i64"), :INT64, 1, :stack)
    lit.full_type = Type.new(:Int64)

    union_ann = SemanticAnnotator.new(source_code: "")
    union_ann.define_singleton_method(:lookup_type_schema) do |name|
      Schemas::UnionSchema.new(variants: { Good: Type.new(:Int64) }) if name == :Choice
    end
    union_ann.define_singleton_method(:literal_type_substitution!) { |_node, _schema| {} }
    bad_variant = AST::StructLit.new(nil, "Choice", { "Bad" => lit }, :stack, nil)
    expect { union_ann.send(:visit_StructLit, bad_variant) }.to raise_error(CompilerError)

    struct_ann = SemanticAnnotator.new(source_code: "")
    struct_ann.define_singleton_method(:lookup_type_schema) do |name|
      if name == :Box
        Schemas::StructSchema.new(fields: {
          "value" => AST::StructField.new(type: Type.new(:Int64))
        })
      end
    end
    struct_ann.define_singleton_method(:literal_type_substitution!) { |_node, _schema| {} }
    bad_field = AST::StructLit.new(nil, "Box", { "missing" => lit }, :stack, nil)
    expect { struct_ann.send(:visit_StructLit, bad_field) }.to raise_error(CompilerError)

    pipe_ann = quiet_annotator
    pipe_ann.define_singleton_method(:has_catch_blocks?) { true }
    left = AST::Literal.new(token(:STRING, "abc"), :STRING, "abc", :rodata)
    left.full_type = Type.new(:String)
    pipe = AST::BinaryOp.new(token(:PIPE, "|>"), left, :SMOOTH, AST::Identifier.new(token, "f"))
    optional_sig = FunctionSignature.new(
      params: [AST::Param.new(name: "x", type: Type.new(:Int64), required: false)],
      return_type: Type.new(:"!String")
    )
    pipe_ann.send(:analyze_pipe_to_named_function, pipe, optional_sig, "f")
    no_arg_sig = FunctionSignature.new(params: [], return_type: Type.new(:Void))
    pipe_ann.send(:analyze_pipe_to_named_function, pipe, no_arg_sig, "zero")
    expect(direct_errors(pipe_ann).map { |e| e[1] }).to include(:ARITY_MISMATCH_RANGE, :ARITY_MISMATCH, :ARGUMENT_TYPE_ERROR)
    expect(pipe.full_type.resolved).to eq(:Void)

    cap_ann = quiet_annotator
    fake_og = Struct.new(:calls) do
      def declare(*args, **kwargs) = calls << [:declare, args, kwargs]
      def borrow(*args, **kwargs)
        calls << [:borrow, args, kwargs]
        nil
      end
    end.new([])
    cap_ann.instance_variable_set(:@og, fake_og)

    locked_var = AST::Identifier.new(token, "locked")
    locked_var.symbol = SymbolEntry.new(reg: nil, type: Type.new(:Counter), mutable: true, storage: :heap, sync: :locked)
    cap_ann.send(:declare_capability_scope!, AST::Capability.new(
      capability: :EXCLUSIVE, var_node: locked_var, alias: "inner",
      old_scope: Scope.new, resolved_type: Type.new(:Counter)
    ))

    plain_var = AST::Identifier.new(token, "plain")
    plain_var.symbol = SymbolEntry.new(reg: nil, type: Type.new(:Counter), mutable: true, storage: :stack)
    plain_var.full_type = Type.new(:Counter)
    cap_ann.send(:declare_capability_scope!, AST::Capability.new(
      capability: :EXCLUSIVE, var_node: plain_var, old_scope: Scope.new,
      resolved_type: Type.new(:Counter)
    ))

    borrowed_var = AST::Identifier.new(token, "borrowed")
    borrowed_var.symbol = SymbolEntry.new(reg: nil, type: Type.new(:Counter), mutable: true, storage: :stack)
    borrowed_var.full_type = Type.new(:Counter)
    cap_ann.send(:declare_capability_scope!, AST::Capability.new(
      capability: :BORROWED, var_node: borrowed_var, old_scope: Scope.new,
      resolved_type: Type.new(:Counter)
    ))
    expect(direct_errors(cap_ann).map { |e| e[1] }).to include(:WITH_CAP_BINDING_LOST)
    expect(fake_og.calls.map(&:first)).to include(:borrow)
  end


  it "covers direct capability and parameter validation branch clusters" do
    cap_ann = quiet_annotator
    cap_ann.instance_variable_set(:@deferred_with_validations, [])
    with_node = AST::WithBlock.new(token(:WITH, "WITH"), [], [], [])

    mk_var = lambda do |name, type, storage: nil, sync: nil, layout: nil, is_param: false|
      ident = AST::Identifier.new(token, name)
      ident.full_type = type
      ident.symbol = SymbolEntry.new(reg: nil, type: type, mutable: true, storage: storage || :stack, sync: sync, layout: layout)
      ident.symbol.is_param = is_param
      ident
    end

    cap_ann.send(:validate_capability, with_node, :SNAPSHOT, mk_var.call("atomic_cell", Type.new(:Counter, ownership: :shared, sync: :atomic, layout: :indirect), sync: :atomic, layout: :indirect))
    cap_ann.send(:validate_capability, with_node, :SNAPSHOT, mk_var.call("indirect_locked", Type.new(:Counter, sync: :locked, layout: :indirect), sync: :locked, layout: :indirect))
    cap_ann.send(:validate_capability, with_node, :SNAPSHOT, mk_var.call("locked", Type.new(:Counter, sync: :locked), sync: :locked))
    cap_ann.send(:validate_capability, with_node, :SNAPSHOT, mk_var.call("shared", Type.new(:Counter, ownership: :shared), storage: :shared))
    plain = AST::Identifier.new(token, "plain")
    plain.full_type = Type.new(:Counter)
    cap_ann.send(:validate_capability, with_node, :SNAPSHOT, plain)
    cap_ann.send(:validate_capability, with_node, :multiowned, mk_var.call("not_multi", Type.new(:Counter), storage: :stack))
    cap_ann.send(:validate_capability, with_node, :shared, mk_var.call("not_shared", Type.new(:Counter), storage: :stack))
    cap_ann.send(:validate_capability, with_node, :ATOMIC, mk_var.call("param_atomic", Type.new(:Counter), is_param: true))
    cap_ann.send(:validate_capability, with_node, :ATOMIC, mk_var.call("locked_atomic", Type.new(:Counter, sync: :locked), sync: :locked))
    cap_ann.send(:validate_capability, with_node, :ATOMIC, mk_var.call("wrong_atomic", Type.new(:Counter), storage: :shared))
    cap_ann.send(:validate_capability, with_node, :ATOMIC, plain)
    cap_ann.send(:validate_capability, with_node, :RESTRICT, AST::Literal.new(token(:NUMBER, "1_i64"), :INT64, 1, :stack))
    cap_ann.send(:validate_capability, with_node, :UNKNOWN, mk_var.call("unknown", Type.new(:Counter)))

    codes = direct_errors(cap_ann).map { |e| e[1] }
    expect(codes).to include(:WITH_CAP_BAD_TARGET, :UNKNOWN_WITH_CAP_TYPE)
    expect(cap_ann.instance_variable_get(:@deferred_with_validations)).not_to be_empty

    bad_param_ann = SemanticAnnotator.new(source_code: "")
    bad_fn = AST::FunctionDef.new(token, "bad_default", [
      AST::Param.new(name: "plain", type: Type.new(:Int64), default: AST::DefaultLit.new(token(:DEFAULT, "DEFAULT")))
    ], Type.new(:Void), [], :package)
    expect { bad_param_ann.send(:declare_and_verify_params, bad_fn) }.to raise_error(CompilerError)

    param_ann = quiet_annotator
    default_number = token(:NUMBER, "1_i64")
    param_ann.define_singleton_method(:lookup_type_schema) do |name|
      case name
      when :AllDefault
        Schemas::StructSchema.new(fields: {
          "a" => AST::StructField.new(type: Type.new(:Int64), default: AST::Literal.new(default_number, :INT64, 1, :stack))
        })
      when :MissingDefault
        Schemas::StructSchema.new(fields: { "a" => AST::StructField.new(type: Type.new(:Int64)) })
      when :EmptyDefault
        Schemas::StructSchema.new(fields: {})
      end
    end
    param_ann.define_singleton_method(:visit) { |node| node.full_type = Type.new(:String) if node.respond_to?(:full_type=) }
    fn = AST::FunctionDef.new(token, "defaults", [
      AST::Param.new(name: "ok", type: Type.new(:AllDefault), default: AST::DefaultLit.new(token(:DEFAULT, "DEFAULT"))),
      AST::Param.new(name: "missing", type: Type.new(:MissingDefault), default: AST::DefaultLit.new(token(:DEFAULT, "DEFAULT"))),
      AST::Param.new(name: "empty", type: Type.new(:EmptyDefault), default: AST::DefaultLit.new(token(:DEFAULT, "DEFAULT"))),
      AST::Param.new(name: "wrong", type: Type.new(:Int64), default: AST::Literal.new(token(:STRING, "x"), :STRING, "x", :rodata))
    ], Type.new(:Void), [], :package)
    param_ann.send(:declare_and_verify_params, fn)
    expect(direct_errors(param_ann).map { |e| e[1] }).to include(:DEFAULT_STRUCT_MISSING_DEFAULTS, :DEFAULT_VALUE_TYPE_MISMATCH)

    pipe_ann = SemanticAnnotator.new(source_code: "")
    void_lit = AST::Literal.new(token(:NIL, "nil"), :NIL, nil, :stack)
    void_lit.full_type = Type.new(:Void)
    err_lit = AST::Literal.new(token(:STRING, "x"), :STRING, "x", :rodata)
    err_lit.full_type = Type.new(:"!String")
    int_lit = AST::Literal.new(token(:NUMBER, "1_i64"), :INT64, 1, :stack)
    int_lit.full_type = Type.new(:Int64)
    body = [
      AST::BinaryOp.new(token(:PIPE, "|>"), void_lit, :SMOOTH, AST::Identifier.new(token, "f")),
      AST::BinaryOp.new(token(:PIPE, "|>"), err_lit, :SMOOTH, AST::Identifier.new(token, "f")),
      AST::BinaryOp.new(token(:PIPE, "|>"), int_lit, :SMOOTH, AST::Identifier.new(token, "f"))
    ]
    types = Set.new
    pipe_ann.send(:collect_pipe_input_types, body, types)
    expect(types).to eq(Set["Int64"])
  end

  it "covers direct struct-pattern, literal-span, and atomic bind branch clusters" do
    ann = quiet_annotator
    ann.define_singleton_method(:lookup_type_schema) do |_name|
      Schemas::StructSchema.new(fields: {
        "a" => AST::StructField.new(type: Type.new(:Int64)),
        "b" => AST::StructField.new(type: Type.new(:Int64)),
        "_private" => AST::StructField.new(type: Type.new(:String))
      })
    end
    ann.define_singleton_method(:emit_typo_suggestion!) do |node, *_args, **_kwargs|
      error!(node, :typo)
    end
    ann.define_singleton_method(:visit) { |node| node.full_type = Type.new(:String) if node.respond_to?(:full_type=) }

    subject = AST::Identifier.new(token, "thing")
    subject.full_type = Type.new(:Thing)
    match_node = AST::MatchStatement.new(token(:MATCH, "MATCH"), subject, [], nil, [], nil, false, nil)
    expr = AST::Literal.new(token(:STRING, "bad"), :STRING, "bad", :rodata)
    expr.full_type = Type.new(:String)
    pat = AST::StructPattern.new(token(:LBRACE, "{"), [
      AST::PatternField.new(name: "missing_tok", value: expr, name_token: token(:VAR_ID, "missing_tok")),
      AST::PatternField.new(name: "missing_plain", value: expr, name_token: token(:VAR_ID, "missing_plain")),
      AST::PatternField.new(name: "a", value: :bind, name_token: token(:VAR_ID, "a")),
      AST::PatternField.new(name: "b", value: expr, name_token: token(:VAR_ID, "b")),
      AST::PatternField.new(name: "_private", value: :wildcard, name_token: token(:VAR_ID, "_private"))
    ], false)
    ann.send(:annotate_struct_pattern!, match_node, pat)
    expect(direct_errors(ann).map { |e| e[1] }).to include(:typo, :MATCH_FIELD_TYPE_MISMATCH)

    nil_schema_ann = quiet_annotator
    nil_schema_ann.define_singleton_method(:lookup_type_schema) { |_name| nil }
    nil_schema_ann.define_singleton_method(:visit) { |_node| nil }
    nil_schema_subject = AST::Identifier.new(token, "unknown_struct")
    nil_schema_subject.full_type = Type.new(:UnknownStruct)
    nil_schema_match = AST::MatchStatement.new(token(:MATCH, "MATCH"), nil_schema_subject, [], nil, [], nil, false, nil)
    nil_schema_pat = AST::StructPattern.new(token(:LBRACE, "{"), [
      AST::PatternField.new(name: "a", value: :bind, name_token: token(:VAR_ID, "a"))
    ], false)
    nil_schema_ann.send(:annotate_struct_pattern!, nil_schema_match, nil_schema_pat)

    span_ann = SemanticAnnotator.new(source_code: "x = \"a\\\"b\";\ny = \"\"\"multi\"\"\";\nz = ;\n")
    expect(span_ann.send(:literal_source_length, Lexer::Token.new(:STRING, "a\"b", 1, 5))).to eq(6)
    expect(span_ann.send(:literal_source_length, Lexer::Token.new(:STRING, "multi", 2, 5))).to eq(11)
    expect(span_ann.send(:literal_source_length, Lexer::Token.new(:NUMBER, "1", 3, 5))).to eq(1)
    expect(SemanticAnnotator.new(source_code: nil).send(:literal_source_length, Lexer::Token.new(:STRING, "abc", 1, 1))).to eq(3)

    bind_ann = quiet_annotator
    bind_ann.current_scope.declare("a", nil, Type.new(:Int64), true, false, nil, :stack, Set.new, [], sync: :atomic)
    bind_ann.define_singleton_method(:visit) { |_node| nil }
    bind_ann.define_singleton_method(:verify_unrestricted!) { |_node| nil }
    bind_ann.define_singleton_method(:validate_assignment_type) { |_node, _expected, _actual| nil }
    bind_ann.define_singleton_method(:handle_assign_move) { |_node| nil }
    bind_ann.define_singleton_method(:handle_assign_borrow) { |_node| nil }
    bind_ann.define_singleton_method(:mark_var_mutated) { |_name| nil }
    bind_ann.define_singleton_method(:og_set_live) { |_name| nil }
    bind_ann.define_singleton_method(:record_effect) { |_effect| nil }
    value = AST::Literal.new(token(:NUMBER, "1_i64"), :INT64, 1, :stack)
    value.full_type = Type.new(:Int64)
    [:ADD, :SUB, :MUL, :DIV, :MOD].each do |op|
      node = AST::BindExpr.new(token(:VAR_ID, "a"), "a", Type.new(:Int64), value)
      node.compound_op = op
      bind_ann.send(:visit_BindExpr, node)
    end
    expect(direct_errors(bind_ann).map { |e| e[1] }).to include(:ATOMIC_NO_MUL_DIV_COMPOUND, :ATOMIC_UNSUPPORTED_COMPOUND)
  end

  it "covers direct generic, precondition, index, next, and concurrent branch clusters" do
    generic_node = Struct.new(:token).new(nil)
    expect {
      SemanticAnnotator.new(source_code: "").send(:validate_type_annotation!, generic_node, Type.new(:"Missing<Int64>"))
    }.to raise_error(CompilerError)

    pre_ann = quiet_annotator
    bool_expr = AST::Literal.new(token(:TRUE, "TRUE"), :BOOLEAN, true, :stack)
    bool_expr.full_type = Type.new(:Bool)
    fn = AST::FunctionDef.new(token, "guarded", [], Type.new(:Void), [], :package)
    fn.pre_clauses = [{ expr: bool_expr, source: "TRUE" }]
    fn.explicit_return_type = false
    fn.arrow_token = nil
    pre_ann.define_singleton_method(:visit) { |_node| nil }
    pre_ann.send(:visit_pre_clauses!, fn)
    expect(direct_errors(pre_ann).map { |e| e[1] }).to include(:PURITY_VIOLATION)

    index_ann = quiet_annotator
    index_ann.define_singleton_method(:visit) { |_node| nil }
    index_ann.define_singleton_method(:resolve_index_op) do |type_info, _op|
      case type_info.resolved
      when :Indexed
        { return_type: Type.new(:Int64), container_borrow: true }
      when :ValueIndexed
        { return_type: Type.new(:Int64), container_borrow: false }
      end
    end
    target = AST::Identifier.new(token, "items")
    target.full_type = Type.new(:Indexed)
    idx = AST::Literal.new(token(:NUMBER, "0_i64"), :INT64, 0, :stack)
    idx.full_type = Type.new(:Int64)
    get = AST::GetIndex.new(token(:LBRACKET, "["), target, idx)
    index_ann.send(:visit_GetIndex, get)
    expect(get.container_borrow).to eq(true)

    value_target = AST::Identifier.new(token, "values")
    value_target.full_type = Type.new(:ValueIndexed)
    value_get = AST::GetIndex.new(token(:LBRACKET, "["), value_target, idx)
    index_ann.send(:visit_GetIndex, value_get)
    expect(value_get.container_borrow).to be_nil

    promise_list = AST::Identifier.new(token, "promises")
    promise_list.full_type = Type.new(:"~Int64[]", collection: :list)
    promise_get = AST::GetIndex.new(token(:LBRACKET, "["), promise_list, idx)
    index_ann.send(:visit_GetIndex, promise_get)
    expect(promise_get.resolved_type).to eq(:"~Int64")

    struct_type = Type.new(:StructLike)
    struct_type.define_singleton_method(:metatype) { :struct }
    struct_type.define_singleton_method(:element_type) { Type.new(:String) }
    struct_target = AST::Identifier.new(token, "structish")
    struct_target.full_type = struct_type
    struct_get = AST::GetIndex.new(token(:LBRACKET, "["), struct_target, idx)
    expect { index_ann.send(:visit_GetIndex, struct_get) }.to raise_error(TypeError)
    expect(struct_get.container_borrow).to eq(true)

    next_ann = quiet_annotator
    next_ann.define_singleton_method(:visit) { |_node| nil }
    next_ann.define_singleton_method(:record_effect) { |_effect| nil }
    next_ann.define_singleton_method(:og_set_moved) { |_name, **_kwargs| nil }
    {
      Type.new(:"~Int64[]") => :"?Int64",
      Type.new(:"~Int64[3]") => :Int64,
      Type.new(:"~Int64", ownership: :shared) => :Int64,
      Type.new(:"~?Int64[]") => :"?Int64"
    }.each do |promise_type, expected|
      expr = AST::Identifier.new(token, "future")
      expr.full_type = promise_type
      node = AST::NextExpr.new(token(:NEXT, "NEXT"), expr)
      next_ann.send(:visit_NextExpr, node)
      expect(node.resolved_type).to eq(expected)
    end

    pipe_ann = quiet_annotator
    left = AST::Identifier.new(token, "xs")
    left.full_type = Type.new(:"Int64[]")
    bad_op = AST::Placeholder.new(token(:UNDERSCORE, "_"))
    conc = AST::ConcurrentOp.new(token(:CONCURRENT, "CONCURRENT"), bad_op, {})
    pipe = AST::BinaryOp.new(token(:PIPE, "|>"), left, :SMOOTH, conc)
    pipe_ann.send(:analyze_concurrent_op, pipe)
    expect(direct_errors(pipe_ann).map { |e| e[1] }).to include(:CONCURRENT_BAD_FOLLOWING_OP)

    lifetime_ann = quiet_annotator
    lifetime_ann.current_scope.declare("x", nil, Type.new(:String), true)
    arg = AST::Identifier.new(token, "x")
    sig = FunctionSignature.new(
      params: [AST::Param.new(name: "p", type: Type.new(:String))],
      return_type: Type.new(:String),
      return_lifetime: [:wildcard]
    )
    sig.instance_variable_set(:@return_lifetime, [:wildcard])
    lifetime_ann.send(:verify_param_lifetime!, arg, sig.params.first, sig)

    expect(SemanticAnnotator.new(source_code: "").send(:init_value_contents_heap?, nil)).to eq(false)
    init_ann = SemanticAnnotator.new(source_code: "")
    struct_lit = AST::StructLit.new(token, Type.new(:Thing), { "a" => nil })
    expect(init_ann.send(:init_value_contents_heap?, struct_lit)).to eq(true)

    post_ann = quiet_annotator
    post_expr = AST::Literal.new(token(:TRUE, "TRUE"), :BOOLEAN, true, :stack)
    post_expr.full_type = Type.new(:Bool)
    post_fn = AST::FunctionDef.new(token, "checked", [], [], nil, nil, [], [], nil, :package)
    post_fn.post_clauses = [{ expr: post_expr, source: "TRUE" }]
    post_ann.define_singleton_method(:visit) { |_node| nil }
    post_ann.send(:visit_post_clauses!, post_fn)

    effects_ann = SemanticAnnotator.new(source_code: "")
    caller = AST::FunctionDef.new(token, "caller", [], [], Type.new(:Void), nil, [], [], nil, :package)
    callee = AST::FunctionDef.new(token, "callee", [], [], Type.new(:"!Void"), nil, [], [], nil, :package)
    effects_ann.instance_variable_set(:@fn_nodes, { "caller" => caller, "callee" => callee })
    effects_ann.instance_variable_set(:@fn_raises_directly, { "callee" => true })
    effects_ann.instance_variable_set(:@call_graph, { "caller" => ["callee", "missing"], "callee" => [] })
    effects_ann.instance_variable_set(:@fn_propagating_callees, { "caller" => ["callee"] })
    effects_ann.send(:compute_can_fail!)
    expect(caller.can_fail).to eq(true)

    tied_ann = quiet_annotator
    [
      nil,
      SymbolEntry.new(reg: nil, type: Type.new(:String), mutable: false, storage: :stack),
      SymbolEntry.new(reg: nil, type: Type.new(:String), mutable: false, storage: :stack)
    ].each_with_index do |sym, i|
      value = AST::Identifier.new(token, "ret#{i}")
      value.symbol = sym if sym
      sym.non_escaping = true if i == 2
      tied_ann.send(:verify_tied_return!, AST::ReturnNode.new(token(:RETURN, "RETURN"), value))
    end

    source_sym = SymbolEntry.new(reg: nil, type: Type.new(:String), mutable: false, storage: :stack)
    returned_sym = SymbolEntry.new(reg: nil, type: Type.new(:String), mutable: false, storage: :stack)
    returned_sym.instance_variable_set(:@lifetime, [source_sym])
    tied_ann.current_scope.locals["source"] = source_sym
    tied_ann.instance_variable_set(:@fn_nodes, {
      "tied" => AST::FunctionDef.new(token, "tied", [], [], Type.new(:String), nil, [], [], nil, :package)
    })
    tied_ann.instance_variable_get(:@function_context_stack) << FunctionContext.new(name: "tied", return_type: Type.new(:String), lifetime: [], type_params: [])
    returned = AST::Identifier.new(token, "returned")
    returned.symbol = returned_sym
    tied_ann.send(:verify_tied_return!, AST::ReturnNode.new(token(:RETURN, "RETURN"), returned))

    fix_ann = quiet_annotator
    moved_ident = AST::Identifier.new(token, "moved")
    fix_ann.send(:emit_use_of_moved_error!, moved_ident, OwnershipGraph::Node.new(path: "moved", kind: :owned, state: :moved))
    cap_ident = AST::Identifier.new(token, "cell")
    cap_field = AST::GetField.new(token(:DOT, "."), cap_ident, "value")
    fix_ann.send(:emit_cap_field_needs_with!, cap_field, :FIELD_NEEDS_WITH, name: "cell", field: "value", cap: "read", perm: "READ")
    expect(direct_errors(fix_ann).map { |e| e[1] }).to include(:USE_OF_MOVED_VALUE, :FIELD_NEEDS_WITH)
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

  it "covers effect maybe-resolution branch matrix directly" do
    ann = SemanticAnnotator.new(source_code: "")
    families = Hash.new { |h, caller| h[caller] = Hash.new { |hh, callee| hh[callee] = [] } }
    ann.instance_variable_set(:@call_site_arg_families, families)

    plain = Set[EffectTracker::HEAP]
    expect(ann.send(:resolve_maybe_effects, plain, "caller", "plain")).to equal(plain)

    maybe = Set[EffectTracker::BLOCKING_MAYBE, EffectTracker::CONTENTION_MAYBE]
    expect(ann.send(:resolve_maybe_effects, maybe, "caller", "uncalled")).to equal(maybe)

    families["caller"]["locked"] << [Set[:LOCKED]]
    locked = ann.send(:resolve_maybe_effects, maybe, "caller", "locked")
    expect(locked).to include(EffectTracker::BLOCKING, EffectTracker::CONTENTION)
    expect(locked).not_to include(EffectTracker::BLOCKING_MAYBE, EffectTracker::CONTENTION_MAYBE)

    families["caller"]["atomic"] << [Set[:ATOMIC]]
    atomic = ann.send(:resolve_maybe_effects, maybe, "caller", "atomic")
    expect(atomic).to include(EffectTracker::CONTENTION)
    expect(atomic).not_to include(EffectTracker::BLOCKING_MAYBE, EffectTracker::CONTENTION_MAYBE)

    families["caller"]["none"] << [Set.new]
    none = ann.send(:resolve_maybe_effects, maybe, "caller", "none")
    expect(none).to include(EffectTracker::BLOCKING_MAYBE)
    expect(none).not_to include(EffectTracker::CONTENTION_MAYBE)

    families["caller"]["poly"] << [Set[:LOCKED, :ATOMIC]]
    poly = ann.send(:resolve_maybe_effects, maybe, "caller", "poly")
    expect(poly).to include(EffectTracker::BLOCKING_MAYBE, EffectTracker::CONTENTION_MAYBE)
    expect(poly).not_to include(EffectTracker::BLOCKING, EffectTracker::CONTENTION)
  end

  it "covers reentrance validation and mutual thunk fix branches directly" do
    ann = quiet_annotator
    direct = function_from(<<~CHT, "direct")
      FN direct(n: Int64) RETURNS !Int64
        EFFECTS REENTRANT:NOT_LOGICAL ->
        RETURN n;
      END
    CHT
    mutual = function_from(<<~CHT, "mutual")
      FN mutual(n: Int64) RETURNS !Int64
        EFFECTS REENTRANT:NOT_LOGICAL ->
        RETURN other(n);
      END
    CHT
    other = function_from(<<~CHT, "other")
      FN other(n: Int64) RETURNS !Int64
        EFFECTS REENTRANT ->
        RETURN mutual(n);
      END
    CHT
    direct.reentrance_kind = :reentrant_not_logical
    mutual.reentrance_kind = :reentrant_not_logical
    other.reentrance_kind = :reentrant
    ann.instance_variable_set(:@fn_nodes, { "direct" => direct, "mutual" => mutual, "other" => other })
    ann.instance_variable_set(:@fn_direct_effects, { "direct" => Set[EffectTracker::REENTRANT], "mutual" => Set.new, "other" => Set.new })
    ann.instance_variable_set(:@call_graph, { "direct" => Set.new, "mutual" => Set["other"], "other" => Set["mutual"] })

    ann.send(:validate_not_logical_recursion!)
    expect(direct_errors(ann).map { |e| e[1] }).to include(:REENTRANT_NOT_LOGICAL_BUT_RECURSIVE)

    max_depth = function_from(<<~CHT, "bounded")
      FN bounded(n: Int64) RETURNS !Int64
        EFFECTS REENTRANT:MAX_DEPTH(8) ->
        RETURN partner(n);
      END
    CHT
    partner = function_from(<<~CHT, "partner")
      FN partner(n: Int64) RETURNS !Int64
        EFFECTS REENTRANT ->
        RETURN bounded(n);
      END
    CHT
    max_depth.reentrance_kind = :reentrant_max_depth
    max_depth.max_depth_n = 8
    partner.reentrance_kind = :reentrant
    ann.instance_variable_set(:@fn_nodes, { "bounded" => max_depth, "partner" => partner })
    ann.instance_variable_set(:@fn_direct_effects, { "bounded" => Set.new, "partner" => Set.new })
    ann.instance_variable_set(:@call_graph, { "bounded" => Set["partner"], "partner" => Set["bounded"] })
    ann.send(:validate_max_depth_mutual_cycle!)
    expect(direct_errors(ann).map { |e| e[1] }).to include(:fixable)

    lonely = function_from(<<~CHT, "lonely")
      FN lonely(n: Int64) RETURNS Int64
        EFFECTS REENTRANT:THUNK ->
        RETURN n;
      END
    CHT
    lonely.reentrance_kind = :reentrant_thunk
    ann.instance_variable_set(:@fn_nodes, { "lonely" => lonely })
    ann.instance_variable_set(:@call_graph, { "lonely" => Set.new })
    expect(ann.send(:try_stamp_mutual_thunk_plan!, lonely)).to eq(false)

    a = function_from(<<~CHT, "a")
      FN a(n: Int64) RETURNS Int64
        EFFECTS REENTRANT:THUNK ->
        RETURN b(n);
      END
    CHT
    b = function_from(<<~CHT, "b")
      FN b(n: Int64) RETURNS Bool
        EFFECTS REENTRANT:THUNK ->
        RETURN TRUE;
      END
    CHT
    a.reentrance_kind = :reentrant_thunk
    b.reentrance_kind = :reentrant_thunk
    ann.instance_variable_set(:@fn_nodes, { "a" => a, "b" => b })
    ann.instance_variable_set(:@call_graph, { "a" => Set["b"], "b" => Set["a"] })
    expect(ann.send(:try_stamp_mutual_thunk_plan!, a)).to eq(false)

    c = function_from(<<~CHT, "c")
      FN c(n: Int64) RETURNS Int64
        EFFECTS REENTRANT:THUNK ->
        RETURN d(n);
      END
    CHT
    d = function_from(<<~CHT, "d")
      FN d(n: Int64) RETURNS Int64
        EFFECTS REENTRANT:THUNK ->
        RETURN c(n);
      END
    CHT
    c.reentrance_kind = :reentrant_thunk
    d.reentrance_kind = :reentrant_thunk
    ann.instance_variable_set(:@fn_nodes, { "c" => c, "d" => d })
    ann.instance_variable_set(:@call_graph, { "c" => Set["d"], "d" => Set["c"] })
    ann.send(:emit_mutual_thunk_unsupported!, c)
    expect(direct_errors(ann).map { |e| e[1] }).to include(:fixable)

    no_span = function_from(<<~CHT, "no_span")
      FN no_span(n: Int64) RETURNS Int64
        EFFECTS REENTRANT:THUNK ->
        RETURN no_edit(n);
      END
    CHT
    no_edit = function_from(<<~CHT, "no_edit")
      FN no_edit(n: Int64) RETURNS Int64
        EFFECTS REENTRANT:THUNK ->
        RETURN no_span(n);
      END
    CHT
    [no_span, no_edit].each do |fn|
      fn.reentrance_kind = :reentrant_thunk
      fn.effects_span = nil
      fn.return_type_token = nil
    end
    ann.instance_variable_set(:@fn_nodes, { "no_span" => no_span, "no_edit" => no_edit })
    ann.instance_variable_set(:@call_graph, { "no_span" => Set["no_edit"], "no_edit" => Set["no_span"] })
    ann.send(:emit_mutual_thunk_unsupported!, no_span)
    expect(direct_errors(ann).map { |e| e[1] }).to include(:REENTRANT_MUTUAL_THUNK_UNSUPPORTED)
  end

  it "covers pipe window, distinct, shard, and fixable-helper branches directly" do
    ann = quiet_annotator
    ann.define_singleton_method(:visit) do |node|
      next unless node.respond_to?(:full_type=)
      inferred = case node
                 when AST::Literal
                   node.type == :STRING ? Type.new(:String) : Type.new(:Int64)
                 else
                   Type.new(:Int64)
                 end
      node.full_type = inferred
    end
    ann.instance_variable_get(:@function_context_stack) << FunctionContext.new(name: "pipe", return_type: Type.new(:Void), lifetime: [], type_params: [])

    left = AST::Identifier.new(token, "xs")
    left.full_type = Type.new(:"Int64[]")
    neg_size = AST::Literal.new(token(:NUMBER, "-1_i64"), :INT64, -1, :stack)
    bad_time = AST::Literal.new(token(:STRING, "0ms"), :STRING, "0ms", :rodata)
    expr = AST::Literal.new(token(:NUMBER, "1_i64"), :INT64, 1, :stack)
    expr.full_type = Type.new(:Int64)
    batch = AST::BatchWindowOp.new(token(:WINDOW, "WINDOW"), {
      "bogus" => expr,
      "size" => neg_size,
      "time" => bad_time
    }, expr)
    ann.send(:analyze_batch_window_op, AST::BinaryOp.new(token(:PIPE, "|>"), left, :SMOOTH, batch))
    expect(direct_errors(ann).map { |e| e[1] }).to include(:WINDOW_BAD_OPTION, :WINDOW_SIZE_NEEDS_POSITIVE, :WINDOW_TIME_NEEDS_POSITIVE)

    no_opts = AST::BatchWindowOp.new(token(:WINDOW, "WINDOW"), {}, expr)
    ann.send(:analyze_batch_window_op, AST::BinaryOp.new(token(:PIPE, "|>"), left, :SMOOTH, no_opts))
    expect(direct_errors(ann).map { |e| e[1] }).to include(:WINDOW_NEEDS_SIZE_OR_TIME)

    distinct_ann = quiet_annotator
    observed_terminals = []
    distinct_ann.define_singleton_method(:visit) { |node| node.full_type = Type.new(:String) if node.respond_to?(:full_type=) }
    distinct_ann.define_singleton_method(:require_array_input!) { |_node, _op, **_kwargs| nil }
    distinct_ann.define_singleton_method(:finite_stream_source?) { |_node| true }
    distinct_ann.define_singleton_method(:finite_stream_element_type) { |_node| Type.new(:Int64) }
    distinct_ann.define_singleton_method(:mark_observable_terminal!) do |_node, **kwargs|
      observed_terminals << kwargs
      nil
    end
    distinct_ann.instance_variable_get(:@function_context_stack) << FunctionContext.new(name: "distinct", return_type: Type.new(:Void), lifetime: [], type_params: [])
    bounded_left = AST::Identifier.new(token, "stream")
    bounded_left.full_type = Type.new(:"~Int64[3]")
    key = AST::Literal.new(token(:STRING, "k"), :STRING, "k", :rodata)
    key.full_type = Type.new(:String)
    distinct_ann.send(:analyze_distinct_op, AST::BinaryOp.new(token(:PIPE, "|>"), bounded_left, :SMOOTH, AST::DistinctOp.new(token(:DISTINCT, "DISTINCT"), key)))

    array_left = AST::Identifier.new(token, "array")
    array_left.full_type = Type.new(:"Int64[]")
    distinct_ann.define_singleton_method(:finite_stream_source?) { |_node| false }
    distinct_ann.send(:analyze_distinct_op, AST::BinaryOp.new(token(:PIPE, "|>"), array_left, :SMOOTH, AST::DistinctOp.new(token(:DISTINCT, "DISTINCT"), key)))
    expect(observed_terminals.map { |t| t[:collection] }).to eq([:set, :set])

    shard_ann = quiet_annotator
    shard_ann.define_singleton_method(:visit) { |node| node.full_type ||= Type.new(:String) if node.respond_to?(:full_type=) }
    bad_left = AST::Identifier.new(token, "scalar")
    bad_left.full_type = Type.new(:Int64)
    bad_target = AST::Identifier.new(token, "plain_map")
    bad_target.full_type = Type.new(:HashMap)
    bad_key = AST::Literal.new(token(:NUMBER, "1_i64"), :INT64, 1, :stack)
    bad_key.full_type = Type.new(:Int64)
    shard_ann.send(:analyze_shard_op, AST::BinaryOp.new(token(:PIPE, "|>"), bad_left, :SMOOTH, AST::ShardOp.new(token(:SHARD, "SHARD"), bad_target, bad_key)))

    map_type = Type.new(:HashMap)
    map_type.define_singleton_method(:sharded?) { true }
    map_type.define_singleton_method(:key_type) { Type.new(:String) }
    target = AST::Identifier.new(token, "sharded")
    target.full_type = map_type
    target.symbol = SymbolEntry.new(reg: nil, type: map_type, mutable: true, storage: :heap)
    shard_ann.send(:analyze_shard_op, AST::BinaryOp.new(token(:PIPE, "|>"), left, :SMOOTH, AST::ShardOp.new(token(:SHARD, "SHARD"), target, bad_key)))

    numeric_map = Type.new(:HashMap)
    numeric_map.define_singleton_method(:sharded?) { true }
    numeric_map.define_singleton_method(:key_type) { Type.new(:Int64) }
    numeric_target = AST::Identifier.new(token, "numeric")
    numeric_target.full_type = numeric_map
    numeric_target.symbol = SymbolEntry.new(reg: nil, type: numeric_map, mutable: true, storage: :heap)
    string_key = AST::Literal.new(token(:STRING, "k"), :STRING, "k", :rodata)
    string_key.full_type = Type.new(:String)
    shard_ann.send(:analyze_shard_op, AST::BinaryOp.new(token(:PIPE, "|>"), left, :SMOOTH, AST::ShardOp.new(token(:SHARD, "SHARD"), numeric_target, string_key)))
    expect(direct_errors(shard_ann).map { |e| e[1] }).to include(:SHARD_NEEDS_RANGE_OR_COLLECTION, :SHARD_TARGET_BAD, :SHARD_KEY_NEEDS_STRING)

    fix_ann = quiet_annotator
    fix_ann.instance_variable_set(:@source_code, "WITH SNAPSHOT cell AS MUTABLE guard {\n  guard.value;\n}\n")
    with_node = AST::WithBlock.new(token(:WITH, "WITH"), [], [], [])
    fix_ann.send(:emit_with_guard_mutable_mutated!, with_node, ["guard"], "is")
    expect(direct_errors(fix_ann).map { |e| e[1] }).to include(:fixable)

    auto_decl = AST::VarDecl.new(token(:VAR_ID, "item"), "item", Type.new(:"Int64[]"), expr, false)
    slot = AutoConstraintCollector::Slot.new(kind: :local, decl_node: auto_decl, sources: [], auto_token: token(:TYPE_ID, "Auto"))
    fix_ann.send(:emit_auto_shape_resolved_finding!, auto_decl, slot)
    expect(direct_errors(fix_ann).map { |e| e[1] }).to include(:fixable)
  end

  it "covers auto constraint collection branch matrix directly" do
    callee = AST::FunctionDef.new(token, "callee", [
      AST::Param.new(name: "x", type: auto_type),
      AST::Param.new(name: "y", type: Type.new(:Int64))
    ], [], auto_type, nil, [], [], nil, :package)
    collector = AutoConstraintCollector.new({ "callee" => callee })
    collector.send(:register_signature_slots)
    slots = collector.instance_variable_get(:@slots)

    arg = AST::Literal.new(token(:NUMBER, "1_i64"), :INT64, 1, :stack)
    collector.send(:record_call_site, AST::FuncCall.new(token, "missing", [arg]))
    collector.send(:record_call_site, AST::FuncCall.new(token, "callee", []))
    collector.send(:record_call_site, AST::FuncCall.new(token, "callee", [arg]))
    expect(slots[AutoSlotId.param("callee", 0)].sources).to include(arg)

    ret = AST::ReturnNode.new(token(:RETURN, "RETURN"), arg)
    collector.send(:record_return, AST::ReturnNode.new(token(:RETURN, "RETURN"), nil), callee)
    collector.send(:record_return, ret, callee)
    expect(slots[AutoSlotId.return("callee")].sources).to include(arg)

    collector.instance_variable_set(:@local_decls, {})
    scalar_value = AST::Literal.new(token(:STRING, "s"), :STRING, "s", :rodata)
    scalar_decl = AST::VarDecl.new(token(:VAR_ID, "scalar"), "scalar", auto_type, scalar_value, true)
    collector.send(:record_local, scalar_decl)
    scalar_slot_id = AutoSlotId.local(scalar_decl)
    expect(slots[scalar_slot_id].sources).to include(scalar_value)

    reassigned = AST::Literal.new(token(:NUMBER, "2_i64"), :INT64, 2, :stack)
    collector.send(:record_local, AST::BindExpr.new(token(:VAR_ID, "scalar"), "scalar", nil, reassigned))
    expect(slots[scalar_slot_id].sources).to include(reassigned)
    collector.send(:record_local, AST::BindExpr.new(token(:VAR_ID, "unknown"), "unknown", nil, reassigned))

    list_decl = AST::VarDecl.new(token(:VAR_ID, "items"), "items", auto_type, AST::ListLit.new(token(:LBRACKET, "["), [], :stack), true)
    collector.send(:record_local, list_decl)
    list_slot = slots[AutoSlotId.list_element(list_decl)]
    list_items = [
      AST::Literal.new(token(:NUMBER, "3_i64"), :INT64, 3, :stack),
      AST::Literal.new(token(:NUMBER, "4_i64"), :INT64, 4, :stack)
    ]
    collector.send(:record_reassignment_sources, AutoSlotId.list_element(list_decl), AST::ListLit.new(token(:LBRACKET, "["), list_items, :stack))
    expect(list_slot.sources).to include(*list_items)

    map_decl = AST::VarDecl.new(token(:VAR_ID, "map"), "map", auto_type, AST::HashLit.new(token(:LBRACE, "{"), [], :stack), true)
    collector.send(:record_local, map_decl)
    key_slot = slots[AutoSlotId.map_key(map_decl)]
    val_slot = slots[AutoSlotId.map_value(map_decl)]
    key = AST::Literal.new(token(:STRING, "k"), :STRING, "k", :rodata)
    val = AST::Literal.new(token(:NUMBER, "5_i64"), :INT64, 5, :stack)
    collector.send(:record_reassignment_sources, AutoMapShapeEntry.new(key: AutoSlotId.map_key(map_decl), value: AutoSlotId.map_value(map_decl)), AST::HashLit.new(token(:LBRACE, "{"), [[key, val]], :stack))
    expect(key_slot.sources).to include(key)
    expect(val_slot.sources).to include(val)

    shape_collector = ShapeEvidenceCollector.new(slots, {})
    shape_slots = AutoShapeSlots.new(list: list_slot, key: key_slot, value: val_slot)
    target = AST::Identifier.new(token, "items")
    shape_collector.send(:record_method_call, AST::MethodCall.new(token, AST::Literal.new(token(:NUMBER, "0_i64"), :INT64, 0, :stack), "append", [arg]), {})
    shape_collector.send(:record_method_call, AST::MethodCall.new(token, target, "append", [arg]), {})
    shape_collector.send(:record_method_call, AST::MethodCall.new(token, target, "append", [arg]), { "items" => shape_slots })
    shape_collector.send(:record_method_call, AST::MethodCall.new(token, target, "insert", [key, val]), { "items" => shape_slots })
    shape_collector.send(:record_method_call, AST::MethodCall.new(token, target, "put", [key, val]), { "items" => shape_slots })
    expect(list_slot.sources).to include(arg)
    expect(key_slot.sources).to include(key)
    expect(val_slot.sources).to include(val)

    indexed = AST::GetIndex.new(token(:LBRACKET, "["), target, key)
    shape_collector.send(:record_index_assign, AST::Assignment.new(token(:EQ, "="), AST::Identifier.new(token, "plain"), val), { "items" => shape_slots })
    shape_collector.send(:record_index_assign, AST::Assignment.new(token(:EQ, "="), indexed, val), {})
    shape_collector.send(:record_index_assign, AST::Assignment.new(token(:EQ, "="), indexed, val), { "items" => AutoShapeSlots.new(list: list_slot, key: nil, value: nil) })
    shape_collector.send(:record_index_assign, AST::Assignment.new(token(:EQ, "="), indexed, val), { "items" => AutoShapeSlots.new(list: nil, key: key_slot, value: val_slot) })
    expect(list_slot.sources).to include(val)
    expect(key_slot.sources).to include(key)
    expect(val_slot.sources).to include(val)
  end

  it "covers fixable helper branch matrix directly" do
    ann = quiet_annotator
    ann.instance_variable_set(:@source_code, [
      "MUTABLE local: Int64 @local = 1_i64;",
      "other: Byte = 1000_i64;",
      "wide = 1000_i8;",
      "cell: Int64 @shared:atomic = 0_i64;"
    ].join("\n"))

    reg = AST::VarDecl.new(token(:MUTABLE, "MUTABLE"), "local", Type.new(:Int64), nil, true)
    reg.token.line = 1
    reg.token.column = 1
    ann.send(:emit_mutable_unused_finding!, reg, "local")
    ann.send(:emit_mutable_unused_finding!, AST::VarDecl.new(token(:VAR_ID, "plain"), "plain", Type.new(:Int64), nil, true), "plain")
    expect(ann.send(:levenshtein, "", "abc")).to eq(3)
    expect(ann.send(:levenshtein, "abc", "")).to eq(3)

    ann.send(:emit_local_never_shared_finding!, { var: "local", line: 1, column: 1 })
    ann.send(:emit_local_never_shared_finding!, { var: "missing", line: 99, column: 1 })

    overflow_suffix = AST::Literal.new(token(:NUMBER, "1000_i8"), :INT64, 1000, :stack)
    overflow_suffix.token.line = 3
    overflow_suffix.token.column = 8
    ann.send(:emit_int_overflow_error!, overflow_suffix, 1000, :Int8, -128, 127)
    overflow_annotation = AST::Literal.new(token(:NUMBER, "1000_i64"), :INT64, 1000, :stack)
    overflow_annotation.token.line = 2
    overflow_annotation.token.column = 15
    ann.send(:emit_int_overflow_error!, overflow_annotation, 1000, :Byte, 0, 255)

    close = token(:TYPE_ID, "Inpug")
    ann.send(:emit_registry_mismatch!, close, :Inpug, [:Input], "bad registry", "known type")
    ann.send(:emit_registry_mismatch!, token(:TYPE_ID, "zzzz"), :zzzz, [:Input], "bad registry", "known type")

    ann.send(:emit_variant_typo!, FixableHelper::AnchorToken.new(1, 1), "Alpa", [:Alpha], "bad variant", "known variant")
    ann.send(:emit_variant_typo!, FixableHelper::AnchorToken.new(1, 1), "zzzz", [:Alpha], "bad variant", "known variant")

    match = AST::MatchStatement.new(token(:MATCH, "MATCH"), AST::Identifier.new(token, "x"), [], nil, [], nil, false, nil)
    ann.send(:emit_match_partial_fix!, match, :MATCH_NON_EXHAUSTIVE, kind: "union", name: "Choice", missing: "Other")
    no_tok_match = AST::MatchStatement.new(nil, AST::Identifier.new(token, "x"), [], nil, [], nil, false, nil)
    ann.send(:emit_match_partial_fix!, no_tok_match, :MATCH_NON_EXHAUSTIVE, kind: "union", name: "Choice", missing: "Other")

    borrowed = AST::Identifier.new(token, "borrowed")
    borrowed.full_type = Type.new(:String)
    ann.send(:emit_return_borrowed_no_copy_error!, borrowed)
    borrowed_no_tok = AST::Identifier.new(nil, "borrowed")
    borrowed_no_tok.full_type = Type.new(:String)
    ann.send(:emit_return_borrowed_no_copy_error!, borrowed_no_tok)

    fn = AST::FunctionDef.new(token, "mutates", [], [], Type.new(:Void), nil, [], [], nil, :package)
    fn.name_token = token(:VAR_ID, "mutates")
    ann.send(:emit_style_mutable_param_needs_bang!, fn)
    fn.name_token = nil
    ann.send(:emit_style_mutable_param_needs_bang!, fn)

    scope = Scope.new
    decl_tok = token(:VAR_ID, "cell")
    decl_tok.line = 4
    decl_tok.column = 1
    cell_decl = AST::VarDecl.new(decl_tok, "cell", Type.new(:Int64), nil, true)
    cell_sym = SymbolEntry.new(reg: cell_decl, type: Type.new(:Int64), mutable: true, storage: :heap, sync: :atomic)
    scope.locals["cell"] = cell_sym
    expect(ann.send(:build_declare_mutable_fix, "missing", scope)).to be_nil
    expect(ann.send(:build_atomic_escape_migration_fix, cell_sym, "cell")).not_to be_nil

    codes = direct_errors(ann).map { |e| e[1] }
    expect(codes.count(:fixable)).to be >= 8
    expect(codes).to include(:REGISTRY_MISMATCH_REJECTED, :TYPO_SUGGESTION_REJECTED, :MATCH_NON_EXHAUSTIVE,
      :RETURN_BORROWED_NO_COPY_OR_LIFETIME, :STYLE_MUTABLE_PARAM_NEEDS_BANG)
  end

  it "covers error selector resolution branch matrix directly" do
    ann = quiet_annotator
    node = AST::WithBlock.new(token(:WITH, "WITH"), [
      AST::Capability.new(capability: :EXCLUSIVE, var_node: AST::Identifier.new(token, "lock"))
    ], [])
    clause = {
      token: token(:ON, "ON"),
      retries: true,
      selectors: [
        { form: :kind, name: :Transient, token: token(:TYPE_ID, "Transient") },
        { form: :kind, name: :Transint, token: token(:TYPE_ID, "Transint") },
        { form: :type, name: :LockTimeout, token: token(:TYPE_ID, "LockTimeout") },
        { form: :type, name: :MadeUpFailure, token: token(:TYPE_ID, "MadeUpFailure") },
        { form: :message, name: :ignored, token: token(:STRING, "\"x\"") },
      ]
    }

    ann.send(:resolve_error_selectors!, node, clause)

    expect(clause[:matched_types]).to include(:LockTimeout, :LockCycle)
    expect(clause[:bubble_types]).to include(:Deadlock)
    expect(direct_errors(ann).map { |e| e[1] }).to include(:REGISTRY_MISMATCH_REJECTED)
  end

  it "covers union method and schema validation branch matrix directly" do
    ann = quiet_annotator
    scope = Scope.new
    ann.define_singleton_method(:lookup_scope_for) { |_name| scope }

    scope.locals["not_a_function"] = SymbolEntry.new(reg: nil, type: Type.new(:Int64), mutable: false, storage: :stack)
    short_sig = FunctionSignature.new(params: [], return_type: Type.new(:Int64))
    scope.locals["short"] = SymbolEntry.new(reg: nil, type: short_sig, mutable: false, storage: :stack)
    no_return_sig = FunctionSignature.new(params: [], return_type: Type.new(:Void))
    scope.locals["no_return"] = SymbolEntry.new(reg: nil, type: no_return_sig, mutable: false, storage: :stack)

    union = AST::UnionDef.new(token(:UNION, "UNION"), "Choice", {}, :package)
    union.methods = [
      { token: token(:VAR_ID, "not_a_function"), name: "not_a_function", params: [], return_type: Type.new(:Int64) },
      { token: token(:VAR_ID, "short"), name: "short", params: [{ name: "x", type: Type.new(:Int64) }], return_type: Type.new(:Int64) },
      { token: token(:VAR_ID, "no_return"), name: "no_return", params: [], return_type: nil },
    ]

    ann.send(:validate_union_methods!, union)

    lit_token = token(:LBRACE, "{")
    lit_token.column = 20
    lit = AST::UnionVariantLit.new(lit_token, "Choice", "Missng", {}, :stack)
    schema = Schemas::UnionSchema.new(variants: { "Present" => Schemas::InlineStructVariant.new(fields: {}) })
    ann.send(:validate_union_schema!, lit, schema)

    codes = direct_errors(ann).map { |e| e[1] }
    expect(codes).to include(:UNION_METHOD_MISSING, :TYPO_SUGGESTION_REJECTED)
  end

  it "covers catch clause normalization branch matrix directly" do
    ann = quiet_annotator
    visited = []
    ann.define_singleton_method(:visit) do |node|
      visited << node
      node.full_type = Type.new(:String) if node.respond_to?(:full_type=)
    end

    msg = AST::Literal.new(token(:STRING, "\"retry\""), :STRING, "retry", :rodata)
    clause = AST::CatchClause.new(
      items: [
        AST::CatchItem.new(form: :kind, name: "Transient", token: token(:TYPE_ID, "Transient")),
        AST::CatchItem.new(form: :kind, name: "Transint", token: token(:TYPE_ID, "Transint")),
        AST::CatchItem.new(form: :type, name: "LockTimeout", token: token(:TYPE_ID, "LockTimeout")),
        AST::CatchItem.new(form: :type, name: "MadeUpFailure", token: token(:TYPE_ID, "MadeUpFailure")),
      ],
      filters: [
        AST::CatchFilter.new(form: :type, value: "MvccConflict", token: token(:TYPE_ID, "MvccConflict")),
        AST::CatchFilter.new(form: :type, value: "MadeUpFilter", token: token(:TYPE_ID, "MadeUpFilter")),
        AST::CatchFilter.new(form: :message, value: msg, token: token(:STRING, "\"retry\"")),
        AST::CatchFilter.new(form: :other, value: "ignored", token: token(:VAR_ID, "ignored")),
      ],
    )

    ann.send(:resolve_catch_clause!, clause)

    expect(clause.kinds).to eq([:Transient])
    expect(clause.types).to eq(["LockTimeout"])
    expect(clause.filter_types).to include("MvccConflict", "MadeUpFilter")
    expect(clause.filter_messages).to eq([msg])
    expect(visited).to eq([msg])
    expect(direct_errors(ann).map { |e| e[1] }).to include(:REGISTRY_MISMATCH_REJECTED, :CATCH_WITH_UNREGISTERED)
  end

  it "covers snapshot match handler validation branch matrix directly" do
    ann = quiet_annotator
    visited = []
    policy_msg = AST::Literal.new(token(:STRING, "\"policy\""), :STRING, "policy", :rodata)
    ann.define_singleton_method(:synthesize_clause_from_policy) do |name|
      name == :MvccConflict ? { action: :exit, message: policy_msg } : nil
    end
    ann.define_singleton_method(:visit) do |node|
      visited << node
      node.full_type = Type.new(:String) if node.respond_to?(:full_type=)
    end
    ann.define_singleton_method(:visit_stmts) { |body| visited.concat(body) }

    block_body = [AST::Literal.new(token(:NUMBER, "1_i64"), :INT64, 1, :stack)]
    node = AST::WithBlock.new(token(:WITH, "WITH"), [], [])
    node.arms = [
      { family: :VERSIONED, lock_error_clauses: [], body: [] },
      { family: :ATOMIC, lock_error_clauses: [{ action: :raise }], body: [] },
      { family: :LOCKED, lock_error_clauses: [{ action: :block, body: block_body }], body: [] },
      { family: :OTHER, lock_error_clauses: [{ action: :exit, message: AST::Literal.new(token(:STRING, "\"x\""), :STRING, "x", :rodata) }], body: [] },
    ]

    ann.send(:validate_snapshot_match_arms!, node)

    expect(node.arms.first[:lock_error_clauses].first[:action]).to eq(:exit)
    expect(visited).to include(node.arms.first[:lock_error_clauses].first[:message], block_body.first, node.arms.last[:lock_error_clauses].first[:message])
    expect(direct_errors(ann).map { |e| e[1] }).to include(:WITH_SNAPSHOT_MATCH_ATOMIC_FORBIDS_HANDLER)

    miss = AST::WithBlock.new(token(:WITH, "WITH"), [], [])
    miss.arms = [{ family: :VERSIONED, lock_error_clauses: [], body: [] }]
    ann.define_singleton_method(:synthesize_clause_from_policy) { |_name| nil }
    ann.send(:validate_snapshot_match_arms!, miss)
    expect(direct_errors(ann).map { |e| e[1] }).to include(:WITH_SNAPSHOT_MATCH_VERSIONED_NEEDS_HANDLER)
  end

  it "covers lock handler reachability branch matrix directly" do
    ann = quiet_annotator

    lock_node = AST::WithBlock.new(token(:WITH, "WITH"), [
      AST::Capability.new(capability: :EXCLUSIVE, var_node: AST::Identifier.new(token, "lock")),
      AST::Capability.new(capability: :RESTRICT, var_node: AST::Identifier.new(token, "guarded"), guard_expr: AST::Literal.new(token(:TRUE, "TRUE"), :BOOL, true, :stack)),
    ], [])
    lock_node.lock_error_clause = {
      selectors: [
        { form: :type, name: :LockTimeout, token: token(:TYPE_ID, "LockTimeout") },
        { form: :type, name: :LockCycle, token: token(:TYPE_ID, "LockCycle") },
        { form: :type, name: :Deadlock, token: token(:TYPE_ID, "Deadlock") },
        { form: :type, name: :GuardFail, token: token(:TYPE_ID, "GuardFail") },
        { form: :kind, name: :System, token: token(:TYPE_ID, "System") },
        { form: :message, name: :Ignored, token: token(:STRING, "\"ignored\"") },
      ]
    }
    ann.send(:verify_handler_reachability!,
      { node: lock_node, cap_types: [:Counter] },
      Set[:Counter],
      Set[:Counter])

    atomic_sym = SymbolEntry.new(reg: nil, type: Type.new(:Counter), mutable: true, storage: :heap, sync: :atomic, layout: :indirect)
    atomic_var = AST::Identifier.new(token, "cell")
    atomic_var.symbol = atomic_sym
    atomic_node = AST::WithBlock.new(token(:WITH, "WITH"), [
      AST::Capability.new(capability: :SNAPSHOT, var_node: atomic_var)
    ], [])
    atomic_node.snapshot_mode = :transaction
    atomic_node.lock_error_clause = {
      selectors: [
        { form: :type, name: :AtomicConflict, token: token(:TYPE_ID, "AtomicConflict") },
        { form: :type, name: :MvccConflict, token: token(:TYPE_ID, "MvccConflict") },
      ]
    }
    ann.send(:verify_handler_reachability!, { node: atomic_node, cap_types: [] }, Set.new, Set.new)

    versioned_node = AST::WithBlock.new(token(:WITH, "WITH"), [
      AST::Capability.new(capability: :SNAPSHOT, var_node: AST::Identifier.new(token, "versioned"))
    ], [])
    versioned_node.snapshot_mode = :transaction
    versioned_node.lock_error_clause = {
      selectors: [
        { form: :type, name: :MvccConflict, token: token(:TYPE_ID, "MvccConflict") },
        { form: :type, name: :AtomicConflict, token: token(:TYPE_ID, "AtomicConflict") },
      ]
    }
    ann.send(:verify_handler_reachability!, { node: versioned_node, cap_types: [] }, Set.new, Set.new)

    expect(direct_errors(ann).map { |e| e[1] }.count(:SELECTOR_NOT_POSSIBLE)).to be >= 3
  end

  it "covers stack tier escalation and propagation branch matrix directly" do
    ann = quiet_annotator
    mk = lambda do |name|
      fn = function_from("FN #{name}() RETURNS Void -> RETURN; END", name)
      fn.effects = Set.new
      fn.stack_vars_bytes = 0
      fn
    end

    micro = mk.call("micro")
    standard = mk.call("standard")
    standard.effects = Set[EffectTracker::HEAP]
    large = mk.call("large")
    large.stack_vars_bytes = EffectTracker::STACK_TIER_BUDGET[:standard]
    xl = mk.call("xl")
    xl.stack_vars_bytes = EffectTracker::STACK_TIER_BUDGET[:large]
    unbounded = mk.call("unbounded")
    unbounded.reentrance_kind = :reentrant
    bounded = mk.call("bounded")
    bounded.reentrance_kind = :reentrant_max_depth
    bounded.max_depth_n = 3
    bounded.stack_vars_bytes = 2_000
    mutual = mk.call("mutual")
    mutual.reentrance_kind = :reentrant_max_depth
    mutual.max_depth_n = 3
    caller = mk.call("caller")
    missing_caller = mk.call("missing_caller")

    ann.instance_variable_set(:@fn_nodes, {
      "micro" => micro,
      "standard" => standard,
      "large" => large,
      "xl" => xl,
      "unbounded" => unbounded,
      "bounded" => bounded,
      "mutual" => mutual,
      "caller" => caller,
      "missing_caller" => missing_caller,
    })
    ann.instance_variable_set(:@call_graph, {
      "micro" => Set.new,
      "standard" => Set.new,
      "large" => Set.new,
      "xl" => Set.new,
      "unbounded" => Set.new,
      "bounded" => Set.new,
      "mutual" => Set["mutual_partner"],
      "mutual_partner" => Set["mutual"],
      "caller" => Set["unbounded"],
      "missing_caller" => Set["missing"],
    })

    ann.send(:compute_stack_tiers!)

    expect(micro.stack_tier).to eq(:micro)
    expect(standard.stack_tier).to eq(:standard)
    expect(large.stack_tier).to eq(:large)
    expect(xl.stack_tier).to eq(:xl)
    expect(unbounded.stack_tier).to eq(:unbounded)
    expect(bounded.stack_vars_bytes).to eq(6_000)
    expect(mutual.stack_tier).to eq(:unbounded)
    expect(caller.stack_tier).to eq(:unbounded)
    expect(missing_caller.stack_tier).to eq(:micro)
  end

  it "covers with-block arm effect and snapshot violation branches directly" do
    ann = quiet_annotator
    fn_ctx = FunctionContext.new(name: "with_fn", return_type: Type.new(:Void), lifetime: [], type_params: [])
    ann.instance_variable_get(:@function_context_stack) << fn_ctx
    ann.instance_variable_set(:@fn_direct_effects, { "with_fn" => Set.new })

    ann.define_singleton_method(:acquire_capability!) { |_node, cap, expanded| expanded << cap }
    ann.define_singleton_method(:check_nested_lock_reacquire!) { |_node, _caps| nil }
    ann.define_singleton_method(:check_lock_rank_ordering!) { |_node, _caps| nil }
    ann.define_singleton_method(:record_with_acquire!) { |_fn, _cap, _held, _escape| nil }
    ann.define_singleton_method(:cap_var_name) { |node| node.respond_to?(:name) ? node.name : "cap" }
    ann.define_singleton_method(:lock_identity_of) { |_cap| :Counter }
    ann.define_singleton_method(:with_new_scope) { |_scope, &blk| blk.call }
    ann.define_singleton_method(:current_scope) { nil }
    ann.define_singleton_method(:declare_capability_scope!) { |_cap| nil }
    ann.define_singleton_method(:validate_and_visit_with_guards!) { |_node| nil }
    ann.define_singleton_method(:validate_with_guard_no_body_mutation!) { |_node| nil }
    ann.define_singleton_method(:retryable_with_fallible_sources) { |_body| [] }
    ann.define_singleton_method(:retryable_with_universal_poly_candidate?) { |_node| false }
    ann.define_singleton_method(:finalize_scope) { |_node| nil }
    ann.define_singleton_method(:validate_no_multi_object_atomic!) { |_node| nil }
    ann.define_singleton_method(:validate_lock_error_clause!) { |_node, _caps| nil }
    ann.define_singleton_method(:visit_stmts) do |body|
      record_effect(EffectTracker::HEAP) if body.include?(:heap_arm)
      @snapshot_txn_violations << { effect: EffectTracker::BLOCKING } if body.include?(:snapshot_violation)
    end

    cap_var = AST::Identifier.new(token, "locked")
    cap = AST::Capability.new(capability: :EXCLUSIVE, var_node: cap_var)
    node = AST::WithBlock.new(token(:WITH, "WITH"), [cap], [:snapshot_violation])
    node.snapshot_mode = :transaction
    node.arms = [
      { family: :LOCKED, body: [:heap_arm], lock_error_clauses: [] },
      { family: :VERSIONED, body: [], lock_error_clauses: [] },
      { family: :ATOMIC, body: [], lock_error_clauses: [] },
      { family: :OTHER, body: [], lock_error_clauses: [] },
    ]

    ann.send(:visit_WithBlock, node)

    effects = ann.instance_variable_get(:@fn_direct_effects)["with_fn"]
    expect(effects).to include(EffectTracker::CONTENTION_MAYBE)
    expect(effects).to include(EffectTracker::BLOCKING_MAYBE, EffectTracker::HEAP)
    expect(direct_errors(ann).map { |e| e[1] }).to include(:WITH_SNAPSHOT_BODY_NOT_PURE)
  end

  it "covers auto method-call shape collection branches directly" do
    decl = AST::VarDecl.new(token(:VAR_ID, "xs"), "xs", auto_type, nil, false)
    list_slot = AutoConstraintCollector::Slot.new(kind: :local, decl_node: decl, sources: [], shape: :list)
    key_slot = AutoConstraintCollector::Slot.new(kind: :local, decl_node: decl, sources: [], shape: :map_key)
    val_slot = AutoConstraintCollector::Slot.new(kind: :local, decl_node: decl, sources: [], shape: :map_value)
    slots = AutoShapeSlots.new(list: list_slot, key: key_slot, value: val_slot)
    name_map = { "xs" => slots }

    elem = AST::Literal.new(token(:NUMBER, "1_i64"), :INT64, 1, :stack)
    key = AST::Literal.new(token(:STRING, "\"k\""), :STRING, "k", :rodata)
    val = AST::Literal.new(token(:NUMBER, "2_i64"), :INT64, 2, :stack)
    target = AST::Identifier.new(token, "xs")
    collector = ShapeEvidenceCollector.new({}, {})

    collector.send(:record_method_call, AST::MethodCall.new(token(:DOT, "."), target, "append", [elem]), name_map)
    collector.send(:record_method_call, AST::MethodCall.new(token(:DOT, "."), target, "insert", [key, val]), name_map)
    collector.send(:record_method_call, AST::MethodCall.new(token(:DOT, "."), target, "put", [key, val]), name_map)
    collector.send(:record_method_call, AST::MethodCall.new(token(:DOT, "."), target, "ignored", [elem]), name_map)
    collector.send(:record_method_call, AST::MethodCall.new(token(:DOT, "."), AST::GetField.new(token, target, "field"), "append", [elem]), name_map)
    collector.send(:record_method_call, AST::MethodCall.new(token(:DOT, "."), AST::Identifier.new(token, "missing"), "append", [elem]), name_map)

    expect(list_slot.sources).to eq([elem])
    expect(key_slot.sources).to eq([key, key])
    expect(val_slot.sources).to eq([val, val])
  end

  it "covers capability variable label shapes directly" do
    ann = quiet_annotator
    root = AST::Identifier.new(token, "root")
    field = AST::GetField.new(token, root, "field")
    index = AST::GetIndex.new(token, root, AST::Literal.new(token(:NUMBER, "0_i64"), :INT64, 0, :stack))
    ann.define_singleton_method(:cap_var_name) { |node| "index:#{node.target.name}" }

    expect(ann.send(:cap_var_label, root)).to eq("root")
    expect(ann.send(:cap_var_label, field)).to eq("field")
    expect(ann.send(:cap_var_label, index)).to eq("index:root")
    expect(ann.send(:cap_var_label, AST::Literal.new(token(:NUMBER, "1_i64"), :INT64, 1, :stack))).to eq("__unknown")
  end

  it "covers fallible return enforcement branches directly" do
    ann = quiet_annotator
    good = function_from("FN good() RETURNS !Int64 -> RETURN 1_i64; END", "good")
    good.error_fallible = true
    good.explicit_return_type = true

    caught = function_from("FN caught() RETURNS Int64 -> RETURN 1_i64; CATCH Input RETURN 0_i64; END", "caught")
    caught.error_fallible = true
    caught.explicit_return_type = true
    caught.catch_clauses = [AST::CatchClause.new]

    no_ret = function_from("FN no_ret() RETURNS Int64 -> RETURN 1_i64; END", "no_ret")
    no_ret.error_fallible = true
    no_ret.explicit_return_type = true
    no_ret.return_type = nil

    fixable = function_from("FN fixable() RETURNS Int64 -> RETURN 1_i64; END", "fixable")
    fixable.error_fallible = true
    fixable.explicit_return_type = true
    fixable.return_type_token = token(:TYPE_ID, "Int64")
    ann.instance_variable_set(:@fn_raises_directly, { "fixable" => true })

    plain_error = function_from("FN plain_error() RETURNS Int64 -> RETURN 1_i64; END", "plain_error")
    plain_error.error_fallible = true
    plain_error.explicit_return_type = true
    plain_error.return_type_token = nil

    main = function_from("FN main() RETURNS Void -> RETURN; END", "main")
    main.error_fallible = true
    main.explicit_return_type = true

    ann.instance_variable_set(:@fn_nodes, {
      "good" => good,
      "caught" => caught,
      "no_ret" => no_ret,
      "fixable" => fixable,
      "plain_error" => plain_error,
      "main" => main,
    })

    ann.send(:enforce_fallible_returns!)

    codes = direct_errors(ann).map { |e| e[1] }
    expect(codes).to include(:fixable, :PURITY_VIOLATION)
  end

  it "covers remaining helper guard and fallback branch matrix directly" do
    ann = quiet_annotator

    families = Hash.new { |h, caller| h[caller] = Hash.new { |hh, callee| hh[callee] = [] } }
    ann.instance_variable_set(:@call_site_arg_families, families)
    maybe = Set[EffectTracker::BLOCKING_MAYBE, EffectTracker::CONTENTION_MAYBE]
    families["caller"]["poly_sync"] << [Set[:ATOMIC, :VERSIONED]]
    poly_sync = ann.send(:resolve_maybe_effects, maybe, "caller", "poly_sync")
    expect(poly_sync).to include(EffectTracker::BLOCKING_MAYBE, EffectTracker::CONTENTION_MAYBE)
    families["caller"]["plain_family"] << [Set[:LOCAL]]
    plain_family = ann.send(:resolve_maybe_effects, maybe, "caller", "plain_family")
    expect(plain_family).to include(EffectTracker::BLOCKING_MAYBE)
    expect(plain_family).not_to include(EffectTracker::CONTENTION_MAYBE)
    families["caller"]["contention_only"] << [Set[:VERSIONED]]
    contention_only = ann.send(:resolve_maybe_effects, Set[EffectTracker::CONTENTION_MAYBE], "caller", "contention_only")
    expect(contention_only).to include(EffectTracker::CONTENTION)

    expect(ann.send(:sum_result_clear_type, :UInt16)).to eq(:UInt64)
    expect(ann.send(:sum_result_clear_type, :Float32)).to eq(:Float32)
    expect(ann.send(:sum_result_clear_type, :String)).to eq(:Float64)

    fn = function_from("FN auto_fn(x: Auto) RETURNS Auto -> RETURN x; END", "auto_fn")
    param_slot = AutoConstraintCollector::Slot.new(kind: :param, fn_name: nil, index: 0, decl_node: fn, sources: [])
    return_slot = AutoConstraintCollector::Slot.new(kind: :return, fn_name: nil, decl_node: fn, sources: [])
    unknown_slot = AutoConstraintCollector::Slot.new(kind: :other, decl_node: fn, sources: [])
    expect(ann.send(:slot_id_for, param_slot)).to be_nil
    expect(ann.send(:slot_id_for, return_slot)).to be_nil
    expect(ann.send(:slot_id_for, unknown_slot)).to be_nil

    ann.instance_variable_set(:@source_code, nil)
    expect(ann.send(:consumer_source_text, 1)).to be_nil
    ann.instance_variable_set(:@source_code, ";\n  process(GIVE msg);\n")
    expect(ann.send(:consumer_source_text, 1)).to be_nil
    expect(ann.send(:consumer_source_text, 2)).to eq("process(GIVE msg)")
    expect(ann.send(:consumer_source_text, 99)).to be_nil

    expect(ann.send(:variant_anchor_from_getfield, AST::GetField.new(token, AST::Identifier.new(nil, "Shape"), "Wrong"))).to be_nil
    expect(ann.send(:build_cast_wrap_fix, nil, :Int64)).to be_nil
    expect(ann.send(:build_cast_wrap_fix, AST::Identifier.new(nil, "x"), :Int64)).to be_nil
    expect(ann.send(:build_cast_wrap_fix, AST::PassStmt.new(token), :Int64)).to be_nil

    ann.instance_variable_set(:@source_code, "x = 999_i64;\ny: Int64 = 999_i64;\n")
    no_token = AST::Literal.new(nil, :INT64, 999, :stack)
    ann.send(:emit_int_overflow_error!, no_token, 999, :Int8, -128, 127)
    no_best = AST::Literal.new(token(:NUMBER, "999999999999999999999999_i64"), :INT64, 999999999999999999999999, :stack)
    no_best.token.line = 1
    no_best.token.column = 5
    ann.send(:emit_int_overflow_error!, no_best, 999999999999999999999999, :Int8, -128, 127)
    same_suffix = AST::Literal.new(token(:NUMBER, "999_i64"), :INT64, 999, :stack)
    same_suffix.token.line = 2
    same_suffix.token.column = 12
    ann.send(:emit_int_overflow_error!, same_suffix, 999, :Int64, -9_223_372_036_854_775_808, 9_223_372_036_854_775_807)

    atomic_type = Type.new(:Int64)
    atomic_sym = SymbolEntry.new(reg: nil, type: atomic_type, mutable: true, storage: :heap, sync: :atomic)
    expect(ann.send(:build_atomic_escape_migration_fix, SymbolEntry.new(reg: nil, type: Type.new(:Int64), mutable: true, storage: :heap), "cell")).to be_nil
    expect(ann.send(:build_atomic_escape_migration_fix, atomic_sym, "cell")).to be_nil
    ann.instance_variable_set(:@source_code, "cell: Int64 = 0_i64;\n")
    expect(ann.send(:build_atomic_escape_migration_fix, atomic_sym, "cell")).to be_nil
    no_token_decl = AST::VarDecl.new(nil, "cell", Type.new(:Int64), nil, true)
    atomic_sym.reg = no_token_decl
    expect(ann.send(:build_atomic_escape_migration_fix, atomic_sym, "cell")).to be_nil
    no_line_token = token(:VAR_ID, "cell")
    no_line_token.line = nil
    atomic_sym.reg = AST::VarDecl.new(no_line_token, "cell", Type.new(:Int64), nil, true)
    expect(ann.send(:build_atomic_escape_migration_fix, atomic_sym, "cell")).to be_nil
  end

  it "covers auto inference and fixable fallback arms directly" do
    collector = AutoConstraintCollector.new({})
    auto_fn = function_from("FN inferred(x: Auto) RETURNS Auto -> RETURN x; END", "inferred")
    auto_arg = AST::Literal.new(token(:NUMBER, "1_i64"), :INT64, 1, :stack)
    collector.instance_variable_set(:@fn_nodes, { "inferred" => auto_fn })
    collector.send(:record_call_site, AST::FuncCall.new(token, "inferred", [auto_arg]))
    collector.send(:record_return, AST::ReturnNode.new(token(:RETURN, "RETURN"), auto_arg), auto_fn)
    collector.send(:record_reassignment_sources, AutoSlotId.local(AST::VarDecl.new(token, "x", auto_type, nil, true)), nil)

    nil_value_decl = AST::VarDecl.new(token(:VAR_ID, "unseen"), "unseen", auto_type, nil, true)
    collector.send(:record_local, nil_value_decl)
    slots = collector.instance_variable_get(:@slots)
    expect(slots[AutoSlotId.local(nil_value_decl)].sources).to be_empty

    list_decl = AST::VarDecl.new(token(:VAR_ID, "list"), "list", auto_type, AST::ListLit.new(token(:LBRACKET, "["), [], :stack), true)
    map_decl = AST::VarDecl.new(token(:VAR_ID, "map"), "map", auto_type, AST::HashLit.new(token(:LBRACE, "{"), [], :stack), true)
    collector.send(:register_list_shape_slot, list_decl)
    collector.send(:register_map_shape_slots, map_decl)

    key_slot = AutoConstraintCollector::Slot.new(kind: :local, decl_node: map_decl, sources: [], shape: :map_key)
    val_slot = AutoConstraintCollector::Slot.new(kind: :local, decl_node: map_decl, sources: [], shape: :map_value)
    list_slot = AutoConstraintCollector::Slot.new(kind: :local, decl_node: list_decl, sources: [], shape: :list_element)
    shape = ShapeEvidenceCollector.new({}, {})
    key = AST::Literal.new(token(:STRING, "\"k\""), :STRING, "k", :rodata)
    val = AST::Literal.new(token(:NUMBER, "2_i64"), :INT64, 2, :stack)
    target = AST::Identifier.new(token, "map")
    shape.send(:record_method_call, AST::MethodCall.new(token, target, "insert", [key, val]), { "map" => AutoShapeSlots.new(list: nil, key: key_slot, value: val_slot) })
    shape.send(:record_method_call, AST::MethodCall.new(token, target, "put", [key]), { "map" => AutoShapeSlots.new(list: nil, key: key_slot, value: val_slot) })
    shape.send(:record_index_assign, AST::Assignment.new(token(:EQ, "="), AST::GetIndex.new(token, target, key), val), { "map" => AutoShapeSlots.new(list: nil, key: key_slot, value: val_slot) })
    shape.send(:record_index_assign, AST::Assignment.new(token(:EQ, "="), AST::GetIndex.new(token, AST::Identifier.new(token, "list"), key), val), { "list" => AutoShapeSlots.new(list: list_slot, key: nil, value: nil) })
    expect(key_slot.sources).to include(key)
    expect(val_slot.sources).to include(val)
    expect(list_slot.sources).to include(val)

    ann = quiet_annotator
    ann.instance_variable_set(:@source_code, [
      "a: Int64 @local= 1_i64;",
      "b: Int64@local = 2_i64;",
      "c: Int64 = 3_i64",
      "d: Int64 @locked = 4_i64;"
    ].join("\n"))
    ann.send(:emit_local_never_shared_finding!, { var: "a", line: 1, column: 1 })
    ann.send(:emit_local_never_shared_finding!, { var: "b", line: 2, column: 1 })
    ann.send(:emit_local_never_shared_finding!, { var: "noloc", line: nil, column: 1 })

    scope = Scope.new
    decl_c_tok = token(:VAR_ID, "c")
    decl_c_tok.line = 3
    decl_c_tok.column = 1
    decl_d_tok = token(:VAR_ID, "d")
    decl_d_tok.line = 4
    decl_d_tok.column = 1
    scope.locals["c"] = SymbolEntry.new(reg: AST::VarDecl.new(decl_c_tok, "c", Type.new(:Int64), nil, false), type: Type.new(:Int64), mutable: false, storage: :stack)
    scope.locals["d"] = SymbolEntry.new(reg: AST::VarDecl.new(decl_d_tok, "d", Type.new(:Int64), nil, false), type: Type.new(:Int64), mutable: false, storage: :stack)
    ann.define_singleton_method(:lookup_scope_for) { |_name| scope }
    expect(ann.send(:build_decl_cap_insert_fix, "c", "@locked")).to be_nil
    expect(ann.send(:build_decl_cap_insert_fix, "d", "@locked")).to be_nil
    mutable_tok = token(:MUTABLE, "MUTABLE")
    mutable_tok.line = 1
    mutable_tok.column = 1
    scope.locals["m"] = SymbolEntry.new(reg: AST::VarDecl.new(mutable_tok, "m", Type.new(:Int64), nil, true), type: Type.new(:Int64), mutable: true, storage: :stack)
    expect(ann.send(:build_declare_mutable_fix, "m", scope)).to be_nil
  end
end
