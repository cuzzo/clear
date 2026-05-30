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
end
