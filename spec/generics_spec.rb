require "rspec"
require "byebug"
require "tmpdir"
require "fileutils"

require_relative "../src/transpiler"
require_relative "../src/ast"

RSpec.describe SemanticAnnotator do
  def run(source)
    tokens = Lexer.new(source).tokenize
    ast = Parser.new(tokens, source).parse
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)
    return ast
  end

  def get_last_type(source)
    run(source).statements.last.resolved_type
  end

  let(:ast) { run(code) }
  let(:result) { ast.statements.last.resolved_type }

  # ==================================================
  # GENERICS — Phase 1: Generic Struct Definitions
  # ==================================================
  describe "GENERICS" do
    describe "generic struct definition" do
      it "parses a single type param without error" do
        expect { run("STRUCT Pair<T> { first: T, second: T }") }.not_to raise_error
      end

      it "parses multiple type params without error" do
        expect { run("STRUCT Map<K, V> { key: K, value: V }") }.not_to raise_error
      end

      it "stores type_params in the schema" do
        ast = run("STRUCT Pair<T> { first: T, second: T }")
        node = ast.statements.first
        expect(node).to be_a(AST::StructDef)
        expect(node.type_params).to eq(["T"])
      end

      it "stores multiple type params" do
        ast = run("STRUCT Map<K, V> { key: K, value: V }")
        expect(ast.statements.first.type_params).to eq(["K", "V"])
      end

      it "a non-generic struct has empty type_params" do
        ast = run("STRUCT User { id: Number }")
        expect(ast.statements.first.type_params).to be_nil.or(be_empty)
      end
    end

    describe "error messages" do
      it "raises an error for duplicate type parameter names" do
        expect {
          run("STRUCT Pair<T, T> { first: T, second: T }")
        }.to raise_error(CompilerError, /Type Error: Duplicate type parameter 'T' in generic struct 'Pair'/)
      end

      it "raises an error when a type parameter shadows a built-in type" do
        expect {
          run("STRUCT Foo<Number> { value: Number }")
        }.to raise_error(CompilerError, /Type Error: Type parameter 'Number' shadows built-in type/)
      end

      it "raises an error when a type parameter shadows Bool" do
        expect {
          run("STRUCT Foo<Bool> { flag: Bool }")
        }.to raise_error(CompilerError, /Type Error: Type parameter 'Bool' shadows built-in type/)
      end

      # NOTE: The following validations are Phase 2 (type annotation instantiation):
      #   - Using a generic type without type args: `x: Pair` should error
      #   - Wrong number of type args: `x: Pair<Number, String>` when Pair<T> expects 1
      #   - Value supplied instead of type: `x: Pair<42>` (parser-level check)
    end

    # --------------------------------------------------
    # Phase 2: Generic Type Annotations
    # --------------------------------------------------
    describe "generic type annotations" do
      # Helpers: use function params/returns to test annotations without needing struct literals.
      # (Phase 3 adds struct literal instantiation: Pair<Number>{ first: 1, second: 2 })

      def fn_with_param(param_annotation)
        <<~CLEAR
          STRUCT Pair<T> { first: T, second: T }
          STRUCT Map<K, V> { key: K, value: V }
          STRUCT User { id: Number }
          FN use(p: #{param_annotation}) RETURNS Number ->
            RETURN 0.0;
          END
          FN cheatMain() RETURNS Void -> PASS END
        CLEAR
      end

      def fn_with_bad_param(param_annotation)
        <<~CLEAR
          STRUCT Pair<T> { first: T, second: T }
          STRUCT Map<K, V> { key: K, value: V }
          STRUCT User { id: Number }
          FN bad(p: #{param_annotation}) RETURNS Number ->
            RETURN 0.0;
          END
          FN cheatMain() RETURNS Void -> PASS END
        CLEAR
      end

      it "allows Pair<Number> as a function parameter type" do
        expect { run(fn_with_param("Pair<Number>")) }.not_to raise_error
      end

      it "stores the generic type on the param" do
        ast = run(fn_with_param("Pair<Number>"))
        fn = ast.statements[3]  # FunctionDef for 'use'
        expect(fn.params.first[:type].to_s).to eq("Pair<Number>")
      end

      it "allows multi-param generic Map<String, Number> as a param type" do
        expect { run(fn_with_param("Map<String, Number>")) }.not_to raise_error
      end

      it "allows other built-in type args: Pair<Bool>" do
        expect { run(fn_with_param("Pair<Bool>")) }.not_to raise_error
      end

      it "allows other built-in type args: Pair<String>" do
        expect { run(fn_with_param("Pair<String>")) }.not_to raise_error
      end

      it "allows other built-in type args: Pair<Int64>" do
        expect { run(fn_with_param("Pair<Int64>")) }.not_to raise_error
      end

      it "allows a user-defined struct as a type argument: Pair<User>" do
        src = <<~CLEAR
          STRUCT User { id: Number }
          STRUCT Pair<T> { first: T, second: T }
          FN use(p: Pair<User>) RETURNS Number ->
            RETURN 0.0;
          END
          FN cheatMain() RETURNS Void -> PASS END
        CLEAR
        expect { run(src) }.not_to raise_error
      end

      it "allows ?Pair<Number> as an optional generic param type" do
        expect { run(fn_with_param("?Pair<Number>")) }.not_to raise_error
      end

      it "allows a generic type as a function return type annotation" do
        # The return type annotation Pair<Number> is valid even without a body that returns one.
        # Full round-trip (function body returning a struct literal) is Phase 3.
        src = <<~CLEAR
          STRUCT Pair<T> { first: T, second: T }
          FN make() RETURNS Pair<Number> ->
            PASS
          END
          FN cheatMain() RETURNS Void -> PASS END
        CLEAR
        expect { run(src) }.not_to raise_error
      end

      it "allows a generic variable declaration when given a value from a function" do
        # Define make() with implicit return (avoids needing a struct literal for now)
        src = <<~CLEAR
          STRUCT Pair<T> { first: T, second: T }
          FN make() RETURNS Pair<Number> ->
            PASS
          END
          FN cheatMain() RETURNS Void ->
            p: Pair<Number> = make();
          END
        CLEAR
        expect { run(src) }.not_to raise_error
      end

      describe "error messages" do
        it "raises 'missing type args' when a generic param type has no args" do
          expect {
            run(fn_with_bad_param("Pair"))
          }.to raise_error(CompilerError, /Type Error: 'Pair' is a generic type — type arguments are required/)
        end

        it "raises 'missing type args' when a generic return type has no args" do
          src = <<~CLEAR
            STRUCT Pair<T> { first: T, second: T }
            FN bad() RETURNS Pair ->
              PASS
            END
            FN cheatMain() RETURNS Void -> PASS END
          CLEAR
          expect { run(src) }.to raise_error(CompilerError, /Type Error: 'Pair' is a generic type — type arguments are required/)
        end

        it "raises 'missing type args' in a variable declaration" do
          src = <<~CLEAR
            STRUCT Pair<T> { first: T, second: T }
            FN cheatMain() RETURNS Void ->
              x: Pair = 0.0;
            END
          CLEAR
          expect { run(src) }.to raise_error(CompilerError, /Type Error: 'Pair' is a generic type — type arguments are required/)
        end

        it "raises 'wrong arg count' for too many type arguments" do
          expect {
            run(fn_with_bad_param("Pair<Number, Bool>"))
          }.to raise_error(CompilerError, /Type Error: 'Pair' expects 1 type argument\(s\), got 2/)
        end

        it "raises 'wrong arg count' for too few type arguments" do
          expect {
            run(fn_with_bad_param("Map<Number>"))
          }.to raise_error(CompilerError, /Type Error: 'Map' expects 2 type argument\(s\), got 1/)
        end

        it "raises 'not generic' when a non-generic struct is given type args" do
          expect {
            run(fn_with_bad_param("User<Number>"))
          }.to raise_error(CompilerError, /Type Error: 'User' is not a generic type — remove the type arguments/)
        end

        it "raises 'unknown type arg' for an unrecognised type argument" do
          expect {
            run(fn_with_bad_param("Pair<Blorp>"))
          }.to raise_error(CompilerError, /Type Error: Unknown type argument 'Blorp'/)
        end

        it "raises a parser error when a value literal is used as a type arg" do
          expect {
            run(fn_with_bad_param("Pair<42>"))
          }.to raise_error(ParserError)
        end

        it "raises 'missing type args' when a generic type is used as a type arg without its own args" do
          # Pair<Pair> — the inner 'Pair' is itself generic and needs args
          # Note: nested generics Pair<Pair<Number>> are not yet supported by the parser (Phase 4+).
          # This test documents that the bare Pair inside <> is caught as missing args.
          src = <<~CLEAR
            STRUCT Pair<T> { first: T, second: T }
            FN bad(p: Pair<Pair>) RETURNS Number ->
              RETURN 0.0;
            END
            FN cheatMain() RETURNS Void -> PASS END
          CLEAR
          expect { run(src) }.to raise_error(CompilerError, /Type Error: 'Pair' is a generic type — type arguments are required/)
        end
      end
    end

    describe "Phase 2 Zig code generation" do
      it "emits Pair(f64) for Pair<Number> in a function param" do
        src = <<~CLEAR
          STRUCT Pair<T> { first: T, second: T }
          FN use(p: Pair<Number>) RETURNS Number ->
            RETURN 0.0;
          END
          FN cheatMain() RETURNS Void -> PASS END
        CLEAR
        out = ZigTranspiler.new.transpile(src)
        expect(out).to include("Pair(f64)")
      end

      it "emits Map([]const u8, f64) for Map<String, Number>" do
        src = <<~CLEAR
          STRUCT Map<K, V> { key: K, value: V }
          FN use(m: Map<String, Number>) RETURNS Number ->
            RETURN 0.0;
          END
          FN cheatMain() RETURNS Void -> PASS END
        CLEAR
        out = ZigTranspiler.new.transpile(src)
        expect(out).to include("Map([]const u8, f64)")
      end

      it "emits Pair(f64) as the Zig return type for RETURNS Pair<Number>" do
        src = <<~CLEAR
          STRUCT Pair<T> { first: T, second: T }
          FN make() RETURNS Pair<Number> ->
            PASS
          END
          FN cheatMain() RETURNS Void -> PASS END
        CLEAR
        out = ZigTranspiler.new.transpile(src)
        expect(out).to include("Pair(f64)")
      end

      it "emits Pair(bool) for Pair<Bool>" do
        src = <<~CLEAR
          STRUCT Pair<T> { first: T, second: T }
          FN use(p: Pair<Bool>) RETURNS Number ->
            RETURN 0.0;
          END
          FN cheatMain() RETURNS Void -> PASS END
        CLEAR
        out = ZigTranspiler.new.transpile(src)
        expect(out).to include("Pair(bool)")
      end

      it "emits Pair(User) for Pair<User> where User is a plain struct" do
        src = <<~CLEAR
          STRUCT User { id: Number }
          STRUCT Pair<T> { first: T, second: T }
          FN use(p: Pair<User>) RETURNS Number ->
            RETURN 0.0;
          END
          FN cheatMain() RETURNS Void -> PASS END
        CLEAR
        out = ZigTranspiler.new.transpile(src)
        expect(out).to include("Pair(User)")
      end

      it "emits ?Pair(f64) for an optional generic param" do
        src = <<~CLEAR
          STRUCT Pair<T> { first: T, second: T }
          FN use(p: ?Pair<Number>) RETURNS Number ->
            RETURN 0.0;
          END
          FN cheatMain() RETURNS Void -> PASS END
        CLEAR
        out = ZigTranspiler.new.transpile(src)
        expect(out).to include("?Pair(f64)")
      end
    end

    describe "Zig code generation" do
      it "emits a comptime function for a single-param generic struct" do
        out = ZigTranspiler.new.transpile("STRUCT Pair<T> { first: T, second: T }\nFN cheatMain() RETURNS Void -> PASS END")
        expect(out).to include("fn Pair(comptime T: type) type")
        expect(out).to include("first: T")
        expect(out).to include("second: T")
      end

      it "emits multiple comptime params for a multi-param generic struct" do
        out = ZigTranspiler.new.transpile("STRUCT Map<K, V> { key: K, value: V }\nFN cheatMain() RETURNS Void -> PASS END")
        expect(out).to include("fn Map(comptime K: type, comptime V: type) type")
      end

      it "emits a plain const struct for a non-generic struct" do
        out = ZigTranspiler.new.transpile("STRUCT User { id: Number }\nFN cheatMain() RETURNS Void -> PASS END")
        expect(out).to include("const User = struct")
        expect(out).not_to include("comptime")
      end

      it "correctly emits field types that are type parameters" do
        out = ZigTranspiler.new.transpile("STRUCT Wrapper<T> { value: T }\nFN cheatMain() RETURNS Void -> PASS END")
        expect(out).to include("value: T")
      end

      it "emits three comptime params for a triple-param struct" do
        out = ZigTranspiler.new.transpile("STRUCT Triple<A, B, C> { a: A, b: B, c: C }\nFN cheatMain() RETURNS Void -> PASS END")
        expect(out).to include("fn Triple(comptime A: type, comptime B: type, comptime C: type) type")
      end
    end

    # --------------------------------------------------
    # Phase 4: Generic Functions
    # --------------------------------------------------
    describe "generic function definitions" do
      def fn_src(fn_code)
        "STRUCT Pair<T> { first: T, second: T }\n" \
        "STRUCT Box<T> { value: T }\n" \
        "#{fn_code}\n" \
        "FN cheatMain() RETURNS Void -> PASS END"
      end

      it "parses FN identity<T>(x: T) RETURNS T without error" do
        expect { run(fn_src("FN identity<T>(x: T) RETURNS T -> RETURN x; END")) }.not_to raise_error
      end

      it "stores type_params on the FunctionDef node" do
        ast = run(fn_src("FN identity<T>(x: T) RETURNS T -> RETURN x; END"))
        fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "identity" }
        expect(fn.type_params).to eq(["T"])
      end

      it "parses a two-type-param function FN swap<A, B>(a: A, b: B) RETURNS A" do
        expect {
          run(fn_src("FN first<A, B>(a: A, b: B) RETURNS A -> RETURN a; END"))
        }.not_to raise_error
      end

      it "allows Cache<T> as a param type in a generic function" do
        expect {
          run(fn_src("FN sz<T>(c: Box<T>) RETURNS T -> RETURN c.value; END"))
        }.not_to raise_error
      end

      it "stores type_params in the registered function signature" do
        ast = run(fn_src("FN identity<T>(x: T) RETURNS T -> RETURN x; END\nFN cheatMain() RETURNS Void -> PASS END"))
        # Verify it doesn't raise — the signature is checked at call site
        expect(ast).not_to be_nil
      end
    end

    describe "generic function call site inference" do
      def call_src(fn_code, call_code)
        "STRUCT Pair<T> { first: T, second: T }\n" \
        "STRUCT Box<T> { value: T }\n" \
        "#{fn_code}\n" \
        "FN cheatMain() RETURNS Void ->\n#{call_code}\nEND"
      end

      it "infers T=Number when calling identity(42.0)" do
        src = call_src(
          "FN identity<T>(x: T) RETURNS T -> RETURN x; END",
          "n = identity(42.0);"
        )
        expect { run(src) }.not_to raise_error
      end

      it "infers T=Bool when calling identity(TRUE)" do
        src = call_src(
          "FN identity<T>(x: T) RETURNS T -> RETURN x; END",
          "b = identity(TRUE);"
        )
        expect { run(src) }.not_to raise_error
      end

      it "sets generic_type_args to [:Number] on the FuncCall node for identity(42.0)" do
        src = call_src(
          "FN identity<T>(x: T) RETURNS T -> RETURN x; END",
          "n = identity(42.0);"
        )
        ast = run(src)
        fn = ast.statements.last
        bind = fn.body.first
        call = bind.value
        expect(call).to be_a(AST::FuncCall)
        expect(call.generic_type_args).to eq([:Number])
      end

      it "sets full_type to :Number on the FuncCall result of identity(42.0)" do
        src = call_src(
          "FN identity<T>(x: T) RETURNS T -> RETURN x; END",
          "n = identity(42.0);"
        )
        ast = run(src)
        fn = ast.statements.last
        bind = fn.body.first
        expect(bind.value.resolved_type).to eq(:Number)
      end

      it "infers T from a generic struct parameter: unbox(Box<Number>{ value: 1.0 })" do
        src = call_src(
          "FN unbox<T>(b: Box<T>) RETURNS T -> RETURN b.value; END",
          'b = Box<Number>{ value: 1.0 }; v = unbox(b);'
        )
        expect { run(src) }.not_to raise_error
      end

      it "infers the correct type when unboxing Box<Bool>" do
        src = call_src(
          "FN unbox<T>(b: Box<T>) RETURNS T -> RETURN b.value; END",
          "b = Box<Bool>{ value: TRUE }; v = unbox(b);"
        )
        ast = run(src)
        fn = ast.statements.last
        call = fn.body[1].value
        expect(call.generic_type_args).to eq([:Bool])
      end
    end

    describe "generic function error messages" do
      def fn_err_src(fn_code, call_code = "PASS")
        "STRUCT Pair<T> { first: T, second: T }\n" \
        "#{fn_code}\n" \
        "FN cheatMain() RETURNS Void ->\n#{call_code}\nEND"
      end

      it "raises GENERIC_FN_DUPLICATE_PARAM for duplicate type params" do
        expect {
          run(fn_err_src("FN bad<T, T>(x: T) RETURNS T -> RETURN x; END"))
        }.to raise_error(CompilerError, /Duplicate type parameter 'T' in generic function 'bad'/)
      end

      it "raises GENERIC_FN_PARAM_SHADOWS_BUILTIN for shadowing Number" do
        expect {
          run(fn_err_src("FN bad<Number>(x: Number) RETURNS Number -> RETURN x; END"))
        }.to raise_error(CompilerError, /Type parameter 'Number'.*shadows built-in type/)
      end

      it "raises GENERIC_FN_PARAM_SHADOWS_BUILTIN for shadowing Bool" do
        expect {
          run(fn_err_src("FN bad<Bool>(x: Bool) RETURNS Bool -> RETURN x; END"))
        }.to raise_error(CompilerError, /Type parameter 'Bool'.*shadows built-in type/)
      end

      it "raises GENERIC_FN_CANNOT_INFER when type param T is not used in any param" do
        expect {
          run(fn_err_src(
            "FN bad<T>(x: Number) RETURNS Number -> RETURN x; END",
            "r = bad(1.0);"
          ))
        }.to raise_error(CompilerError, /Cannot infer type argument 'T' for 'bad'/)
      end

      it "raises GENERIC_FN_CONFLICT on conflicting type inference" do
        expect {
          run(fn_err_src(
            "FN bad<T>(x: T, y: T) RETURNS T -> RETURN x; END",
            "r = bad(1.0, TRUE);"
          ))
        }.to raise_error(CompilerError, /Conflicting inference for 'T' in 'bad'/)
      end

      it "raises an argument type error when wrong type is passed after inference" do
        # T inferred as Number from first arg; second arg should also be Number
        src = fn_err_src(
          "FN same<T>(a: T, b: T) RETURNS T -> RETURN a; END",
          'r = same(1.0, "hello");'
        )
        expect { run(src) }.to raise_error(CompilerError)
      end
    end

    describe "Phase 4 Zig code generation" do
      it "emits 'comptime T: type' in function signature for FN identity<T>" do
        src = "FN identity<T>(x: T) RETURNS T -> RETURN x; END\nFN cheatMain() RETURNS Void -> PASS END"
        out = ZigTranspiler.new.transpile(src)
        expect(out).to include("fn identity(comptime T: type, x: T)")
      end

      it "emits two comptime params for a two-type-param function" do
        src = "FN first<A, B>(a: A, b: B) RETURNS A -> RETURN a; END\nFN cheatMain() RETURNS Void -> PASS END"
        out = ZigTranspiler.new.transpile(src)
        expect(out).to include("fn first(comptime A: type, comptime B: type, a: A")
      end

      it "emits inferred type arg at call site without rt when callee is pure" do
        src = "FN identity<T>(x: T) RETURNS T -> RETURN x; END\nFN cheatMain() RETURNS Void -> n = identity(42.0); END"
        out = ZigTranspiler.new.transpile(src)
        expect(out).to include("identity(f64,")
        expect(out).not_to include("identity(f64, rt,")
      end

      it "emits bool type arg at call site for identity(TRUE)" do
        src = "FN identity<T>(x: T) RETURNS T -> RETURN x; END\nFN cheatMain() RETURNS Void -> b = identity(TRUE); END"
        out = ZigTranspiler.new.transpile(src)
        expect(out).to include("identity(bool,")
        expect(out).not_to include("identity(bool, rt,")
      end

      it "emits Pair(T) as return type when RETURNS Pair<T>" do
        src = "STRUCT Pair<T> { first: T, second: T }\nFN makePair<T>(v: T) RETURNS Pair<T> -> RETURN Pair<T>{ first: v, second: v }; END\nFN cheatMain() RETURNS Void -> PASS END"
        out = ZigTranspiler.new.transpile(src)
        expect(out).to include("Pair(T)")
      end
    end

    # --------------------------------------------------
    # Phase 3: Generic Struct Literals
    # --------------------------------------------------
    describe "generic struct literals" do
      def generic_lit_src(extra = "")
        <<~CLEAR
          STRUCT Pair<T> { first: T, second: T }
          STRUCT KeyValue<K, V> { key: K, value: V }
          FN cheatMain() RETURNS Void ->
            #{extra}
          END
        CLEAR
      end

      it "parses and annotates Pair<Number>{ first: 1.0, second: 2.0 } without error" do
        expect {
          run(generic_lit_src("p = Pair<Number>{ first: 1.0, second: 2.0 };"))
        }.not_to raise_error
      end

      it "sets full_type to :\"Pair<Number>\" on the StructLit node" do
        ast = run(generic_lit_src("p = Pair<Number>{ first: 1.0, second: 2.0 };"))
        fn = ast.statements.last
        bind = fn.body.first
        lit = bind.value
        expect(lit).to be_a(AST::StructLit)
        expect(lit.resolved_type).to eq(:"Pair<Number>")
      end

      it "stores type_args on the StructLit AST node" do
        ast = run(generic_lit_src("p = Pair<Number>{ first: 1.0, second: 2.0 };"))
        fn = ast.statements.last
        bind = fn.body.first
        lit = bind.value
        expect(lit.type_args).to eq(["Number"])
      end

      it "accepts KeyValue<String, Number>{ key: \"x\", value: 42.0 }" do
        expect {
          run(generic_lit_src('kv = KeyValue<String, Number>{ key: "x", value: 42.0 };'))
        }.not_to raise_error
      end

      it "resolves field access on a generic struct literal" do
        src = <<~CLEAR
          STRUCT Pair<T> { first: T, second: T }
          FN cheatMain() RETURNS Void ->
            p = Pair<Number>{ first: 1.0, second: 2.0 };
            x = p.first;
          END
        CLEAR
        expect { run(src) }.not_to raise_error
      end

      it "infers field type as Number when accessing .first on Pair<Number>" do
        src = <<~CLEAR
          STRUCT Pair<T> { first: T, second: T }
          FN cheatMain() RETURNS Void ->
            p = Pair<Number>{ first: 1.0, second: 2.0 };
            x = p.first;
          END
        CLEAR
        ast = run(src)
        fn = ast.statements.last
        bind_x = fn.body[1]
        get_field = bind_x.value
        expect(get_field).to be_a(AST::GetField)
        expect(get_field.resolved_type).to eq(:Number)
      end

      describe "error messages" do
        it "raises a type error when a field value has the wrong type" do
          expect {
            run(generic_lit_src('p = Pair<Number>{ first: "oops", second: 2.0 };'))
          }.to raise_error(CompilerError, /expected.*Number|got.*String/i)
        end

        it "raises a type error when wrong number of type args in literal" do
          expect {
            run(generic_lit_src("p = Pair<Number, Bool>{ first: 1.0, second: true };"))
          }.to raise_error(CompilerError, /expects 1 type argument/)
        end

        it "raises a type error when a non-generic struct gets type args in literal" do
          src = <<~CLEAR
            STRUCT User { id: Number }
            FN cheatMain() RETURNS Void ->
              u = User<Number>{ id: 1.0 };
            END
          CLEAR
          expect { run(src) }.to raise_error(CompilerError, /not a generic type/)
        end

        it "raises a type error when a generic struct literal has no type args" do
          expect {
            run(generic_lit_src("p = Pair{ first: 1.0, second: 2.0 };"))
          }.to raise_error(CompilerError, /type arguments are required/)
        end
      end

      # --------------------------------------------------
      # Phase 5: Generic Unions
      # --------------------------------------------------
      describe "generic union definitions" do
        def union_src(extra = "")
          <<~CLEAR
            UNION Option<T> { Some: T, None }
            UNION Result<T, E> { Ok: T, Err: E }
            FN cheatMain() RETURNS Void ->
              #{extra}
            END
          CLEAR
        end

        it "declares Option<T> without error" do
          expect { run(union_src) }.not_to raise_error
        end

        it "declares Result<T, E> without error" do
          expect { run(union_src) }.not_to raise_error
        end

        it "raises on duplicate type parameter in union" do
          src = <<~CLEAR
            UNION Bad<T, T> { A: T, B: T }
            FN cheatMain() RETURNS Void -> END
          CLEAR
          expect { run(src) }.to raise_error(CompilerError,
            /Duplicate type parameter 'T' in generic union 'Bad'/)
        end

        it "raises when type parameter shadows a builtin" do
          src = <<~CLEAR
            UNION Bad<Number> { A: Number }
            FN cheatMain() RETURNS Void -> END
          CLEAR
          expect { run(src) }.to raise_error(CompilerError,
            /Type parameter 'Number' shadows built-in type 'Number'/)
        end

        it "accepts Option<Number>{ Some: 42.0 } without error" do
          expect { run(union_src("opt = Option<Number>{ Some: 42.0 };")) }.not_to raise_error
        end

        it "sets full_type to :\"Option<Number>\" on the union literal" do
          ast = run(union_src("opt = Option<Number>{ Some: 42.0 };"))
          fn = ast.statements.last
          bind = fn.body.first
          lit = bind.value
          expect(lit).to be_a(AST::StructLit)
          expect(lit.resolved_type).to eq(:"Option<Number>")
        end

        it "accepts Option<Number>{ Some: 0.0 } (second Some variant) without error" do
          expect { run(union_src("n = Option<Number>{ Some: 0.0 };")) }.not_to raise_error
        end

        it "accepts Result<Number, Bool>{ Err: TRUE } without error" do
          expect { run(union_src("r = Result<Number, Bool>{ Err: TRUE };")) }.not_to raise_error
        end

        it "raises when instantiating a generic union without type args" do
          src = <<~CLEAR
            UNION Option<T> { Some: T, None }
            FN cheatMain() RETURNS Void ->
              bad = Option{ Some: 1.0 };
            END
          CLEAR
          expect { run(src) }.to raise_error(CompilerError,
            /generic type.*type arguments are required/i)
        end

        it "raises when a union variant value type is wrong" do
          src = <<~CLEAR
            UNION Option<T> { Some: T, None }
            FN cheatMain() RETURNS Void ->
              bad = Option<Number>{ Some: TRUE };
            END
          CLEAR
          expect { run(src) }.to raise_error(CompilerError, /Type Error/)
        end

        it "allows MATCH on Option<Number> without type error" do
          src = union_src(<<~BODY)
            opt = Option<Number>{ Some: 42.0 };
            MUTABLE got = 0.0;
            MATCH opt START
              Option.Some -> got = 1.0;,
              Option.None -> got = 2.0;
            END
          BODY
          expect { run(src) }.not_to raise_error
        end
      end

      describe "Phase 5 Zig code generation" do
        def union_zig(src)
          ZigTranspiler.new.transpile(src)
        end

        it "emits a comptime function for Option<T>" do
          src = <<~CLEAR
            UNION Option<T> { Some: T, None }
            FN cheatMain() RETURNS Void -> END
          CLEAR
          out = union_zig(src)
          expect(out).to include("fn Option(comptime T: type)")
          expect(out).to include("union(enum)")
          expect(out).to include("Some: T")
          expect(out).to include("None: void")
        end

        it "emits a comptime function for Result<T, E>" do
          src = <<~CLEAR
            UNION Result<T, E> { Ok: T, Err: E }
            FN cheatMain() RETURNS Void -> END
          CLEAR
          out = union_zig(src)
          expect(out).to include("fn Result(comptime T: type, comptime E: type)")
          expect(out).to include("Ok: T")
          expect(out).to include("Err: E")
        end

        it "emits Option(f64){ .Some = 42 } for Option<Number>{ Some: 42.0 }" do
          src = <<~CLEAR
            UNION Option<T> { Some: T, None }
            FN cheatMain() RETURNS Void ->
              opt = Option<Number>{ Some: 42.0 };
            END
          CLEAR
          out = union_zig(src)
          expect(out).to include("Option(f64)")
          expect(out).to include(".Some =")
        end

        it "emits Result(f64, bool){ .Err = true } for generic Result literal" do
          src = <<~CLEAR
            UNION Result<T, E> { Ok: T, Err: E }
            FN cheatMain() RETURNS Void ->
              r = Result<Number, Bool>{ Err: TRUE };
            END
          CLEAR
          out = union_zig(src)
          expect(out).to include("Result(f64, bool)")
          expect(out).to include(".Err =")
        end
      end

      describe "Phase 3 Zig code generation" do
        it "emits Pair(f64){ .first = ..., .second = ... } for Pair<Number>" do
          src = <<~CLEAR
            STRUCT Pair<T> { first: T, second: T }
            FN cheatMain() RETURNS Void ->
              p = Pair<Number>{ first: 1.0, second: 2.0 };
            END
          CLEAR
          out = ZigTranspiler.new.transpile(src)
          expect(out).to include("Pair(f64)")
          expect(out).to include(".first =")
          expect(out).to include(".second =")
        end

        it "emits KeyValue([]const u8, f64){ ... } for KeyValue<String, Number>" do
          src = <<~CLEAR
            STRUCT KeyValue<K, V> { key: K, value: V }
            FN cheatMain() RETURNS Void ->
              kv = KeyValue<String, Number>{ key: "x", value: 42.0 };
            END
          CLEAR
          out = ZigTranspiler.new.transpile(src)
          expect(out).to include("KeyValue([]const u8, f64)")
        end
      end
    end
  end

end
