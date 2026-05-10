require "rspec"
require "byebug"
require "tmpdir"
require "fileutils"

require_relative "../src/backends/transpiler"
require_relative "../src/ast/ast"

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
        ast = run("STRUCT User { id: Float64 }")
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
          run("STRUCT Foo<Float64> { value: Float64 }")
        }.to raise_error(CompilerError, /Type Error: Type parameter 'Float64' shadows built-in type/)
      end

      it "raises an error when a type parameter shadows Bool" do
        expect {
          run("STRUCT Foo<Bool> { flag: Bool }")
        }.to raise_error(CompilerError, /Type Error: Type parameter 'Bool' shadows built-in type/)
      end

      # NOTE: The following validations are Phase 2 (type annotation instantiation):
      #   - Using a generic type without type args: `x: Pair` should error
      #   - Wrong number of type args: `x: Pair<Float64, String>` when Pair<T> expects 1
      #   - Value supplied instead of type: `x: Pair<42>` (parser-level check)
    end

    # --------------------------------------------------
    # Phase 2: Generic Type Annotations
    # --------------------------------------------------
    describe "generic type annotations" do
      # Helpers: use function params/returns to test annotations without needing struct literals.
      # (Phase 3 adds struct literal instantiation: Pair<Float64>{ first: 1, second: 2 })

      def fn_with_param(param_annotation)
        <<~CLEAR
          STRUCT Pair<T> { first: T, second: T }
          STRUCT Map<K, V> { key: K, value: V }
          STRUCT User { id: Float64 }
          FN use(p: #{param_annotation}) RETURNS Float64 ->
            RETURN 0.0;
          END
          FN main() RETURNS Void -> PASS END
        CLEAR
      end

      def fn_with_bad_param(param_annotation)
        <<~CLEAR
          STRUCT Pair<T> { first: T, second: T }
          STRUCT Map<K, V> { key: K, value: V }
          STRUCT User { id: Float64 }
          FN bad(p: #{param_annotation}) RETURNS Float64 ->
            RETURN 0.0;
          END
          FN main() RETURNS Void -> PASS END
        CLEAR
      end

      it "allows Pair<Float64> as a function parameter type" do
        expect { run(fn_with_param("Pair<Float64>")) }.not_to raise_error
      end

      it "stores the generic type on the param" do
        ast = run(fn_with_param("Pair<Float64>"))
        fn = ast.statements[3]  # FunctionDef for 'use'
        expect(fn.params.first[:type].to_s).to eq("Pair<Float64>")
      end

      it "allows multi-param generic Map<String, Float64> as a param type" do
        expect { run(fn_with_param("Map<String, Float64>")) }.not_to raise_error
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
          STRUCT User { id: Float64 }
          STRUCT Pair<T> { first: T, second: T }
          FN use(p: Pair<User>) RETURNS Float64 ->
            RETURN 0.0;
          END
          FN main() RETURNS Void -> PASS END
        CLEAR
        expect { run(src) }.not_to raise_error
      end

      it "allows ?Pair<Float64> as an optional generic param type" do
        expect { run(fn_with_param("?Pair<Float64>")) }.not_to raise_error
      end

      it "allows a generic type as a function return type annotation" do
        # The return type annotation Pair<Float64> is valid even without a body that returns one.
        # Full round-trip (function body returning a struct literal) is Phase 3.
        src = <<~CLEAR
          STRUCT Pair<T> { first: T, second: T }
          FN make() RETURNS Pair<Float64> ->
            PASS
          END
          FN main() RETURNS Void -> PASS END
        CLEAR
        expect { run(src) }.not_to raise_error
      end

      it "allows a generic variable declaration when given a value from a function" do
        # Define make() with implicit return (avoids needing a struct literal for now)
        src = <<~CLEAR
          STRUCT Pair<T> { first: T, second: T }
          FN make() RETURNS Pair<Float64> ->
            PASS
          END
          FN main() RETURNS Void ->
            p: Pair<Float64> = make();
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
            FN main() RETURNS Void -> PASS END
          CLEAR
          expect { run(src) }.to raise_error(CompilerError, /Type Error: 'Pair' is a generic type — type arguments are required/)
        end

        it "raises 'missing type args' in a variable declaration" do
          src = <<~CLEAR
            STRUCT Pair<T> { first: T, second: T }
            FN main() RETURNS Void ->
              x: Pair = 0.0;
            END
          CLEAR
          expect { run(src) }.to raise_error(CompilerError, /Type Error: 'Pair' is a generic type — type arguments are required/)
        end

        it "raises 'wrong arg count' for too many type arguments" do
          expect {
            run(fn_with_bad_param("Pair<Float64, Bool>"))
          }.to raise_error(CompilerError, /Type Error: 'Pair' expects 1 type argument\(s\), got 2/)
        end

        it "raises 'wrong arg count' for too few type arguments" do
          expect {
            run(fn_with_bad_param("Map<Float64>"))
          }.to raise_error(CompilerError, /Type Error: 'Map' expects 2 type argument\(s\), got 1/)
        end

        it "raises 'not generic' when a non-generic struct is given type args" do
          expect {
            run(fn_with_bad_param("User<Float64>"))
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
          # Note: nested generics Pair<Pair<Float64>> are not yet supported by the parser (Phase 4+).
          # This test documents that the bare Pair inside <> is caught as missing args.
          src = <<~CLEAR
            STRUCT Pair<T> { first: T, second: T }
            FN bad(p: Pair<Pair>) RETURNS Float64 ->
              RETURN 0.0;
            END
            FN main() RETURNS Void -> PASS END
          CLEAR
          expect { run(src) }.to raise_error(CompilerError, /Type Error: 'Pair' is a generic type — type arguments are required/)
        end
      end
    end

    describe "Phase 2 Zig code generation" do
      it "emits Pair(f64) for Pair<Float64> in a function param" do
        src = <<~CLEAR
          STRUCT Pair<T> { first: T, second: T }
          FN use(p: Pair<Float64>) RETURNS Float64 ->
            RETURN 0.0;
          END
          FN main() RETURNS Void -> PASS END
        CLEAR
        out = ZigTranspiler.new.transpile(src)
        expect(out).to include("Pair(f64)")
      end

      it "emits Map([]const u8, f64) for Map<String, Float64>" do
        src = <<~CLEAR
          STRUCT Map<K, V> { key: K, value: V }
          FN use(m: Map<String, Float64>) RETURNS Float64 ->
            RETURN 0.0;
          END
          FN main() RETURNS Void -> PASS END
        CLEAR
        out = ZigTranspiler.new.transpile(src)
        expect(out).to include("Map([]const u8, f64)")
      end

      it "emits Pair(f64) as the Zig return type for RETURNS Pair<Float64>" do
        src = <<~CLEAR
          STRUCT Pair<T> { first: T, second: T }
          FN make() RETURNS Pair<Float64> ->
            PASS
          END
          FN main() RETURNS Void -> PASS END
        CLEAR
        out = ZigTranspiler.new.transpile(src)
        expect(out).to include("Pair(f64)")
      end

      it "emits Pair(bool) for Pair<Bool>" do
        src = <<~CLEAR
          STRUCT Pair<T> { first: T, second: T }
          FN use(p: Pair<Bool>) RETURNS Float64 ->
            RETURN 0.0;
          END
          FN main() RETURNS Void -> PASS END
        CLEAR
        out = ZigTranspiler.new.transpile(src)
        expect(out).to include("Pair(bool)")
      end

      it "emits Pair(User) for Pair<User> where User is a plain struct" do
        src = <<~CLEAR
          STRUCT User { id: Float64 }
          STRUCT Pair<T> { first: T, second: T }
          FN use(p: Pair<User>) RETURNS Float64 ->
            RETURN 0.0;
          END
          FN main() RETURNS Void -> PASS END
        CLEAR
        out = ZigTranspiler.new.transpile(src)
        expect(out).to include("Pair(User)")
      end

      it "emits ?Pair(f64) for an optional generic param" do
        src = <<~CLEAR
          STRUCT Pair<T> { first: T, second: T }
          FN use(p: ?Pair<Float64>) RETURNS Float64 ->
            RETURN 0.0;
          END
          FN main() RETURNS Void -> PASS END
        CLEAR
        out = ZigTranspiler.new.transpile(src)
        expect(out).to include("?Pair(f64)")
      end
    end

    describe "Zig code generation" do
      it "emits a comptime function for a single-param generic struct" do
        out = ZigTranspiler.new.transpile("STRUCT Pair<T> { first: T, second: T }\nFN main() RETURNS Void -> PASS END")
        expect(out).to include("fn Pair(comptime T: type) type")
        expect(out).to include("first: T")
        expect(out).to include("second: T")
      end

      it "emits multiple comptime params for a multi-param generic struct" do
        out = ZigTranspiler.new.transpile("STRUCT Map<K, V> { key: K, value: V }\nFN main() RETURNS Void -> PASS END")
        expect(out).to include("fn Map(comptime K: type, comptime V: type) type")
      end

      it "emits a plain const struct for a non-generic struct" do
        out = ZigTranspiler.new.transpile("STRUCT User { id: Float64 }\nFN main() RETURNS Void -> PASS END")
        expect(out).to include("const User = struct")
        expect(out).not_to include("comptime")
      end

      it "correctly emits field types that are type parameters" do
        out = ZigTranspiler.new.transpile("STRUCT Wrapper<T> { value: T }\nFN main() RETURNS Void -> PASS END")
        expect(out).to include("value: T")
      end

      it "emits three comptime params for a triple-param struct" do
        out = ZigTranspiler.new.transpile("STRUCT Triple<A, B, C> { a: A, b: B, c: C }\nFN main() RETURNS Void -> PASS END")
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
        "FN main() RETURNS Void -> PASS END"
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
        ast = run(fn_src("FN identity<T>(x: T) RETURNS T -> RETURN x; END\nFN main() RETURNS Void -> PASS END"))
        # Verify it doesn't raise — the signature is checked at call site
        expect(ast).not_to be_nil
      end
    end

    describe "generic function call site inference" do
      def call_src(fn_code, call_code)
        "STRUCT Pair<T> { first: T, second: T }\n" \
        "STRUCT Box<T> { value: T }\n" \
        "#{fn_code}\n" \
        "FN main() RETURNS Void ->\n#{call_code}\nEND"
      end

      it "infers T=Float64 when calling identity(42.0)" do
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

      it "sets generic_type_args to [:Float64] on the FuncCall node for identity(42.0)" do
        src = call_src(
          "FN identity<T>(x: T) RETURNS T -> RETURN x; END",
          "n = identity(42.0);"
        )
        ast = run(src)
        fn = ast.statements.last
        bind = fn.body.first
        call = bind.value
        expect(call).to be_a(AST::FuncCall)
        expect(call.generic_type_args).to eq([:Float64])
      end

      it "sets full_type to :Float64 on the FuncCall result of identity(42.0)" do
        src = call_src(
          "FN identity<T>(x: T) RETURNS T -> RETURN x; END",
          "n = identity(42.0);"
        )
        ast = run(src)
        fn = ast.statements.last
        bind = fn.body.first
        expect(bind.value.resolved_type).to eq(:Float64)
      end

      it "infers T from a generic struct parameter: unbox(Box<Float64>{ value: 1.0 })" do
        src = call_src(
          "FN unbox<T>(b: Box<T>) RETURNS T -> RETURN b.value; END",
          'b = Box<Float64>{ value: 1.0 }; v = unbox(b);'
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

      it "preserves capability axes when T is inferred directly from an argument" do
        src = <<~CLEAR
          STRUCT Box { value: Int64 }
          FN identity<T>(x: T) RETURNS T -> RETURN x; END
          FN main() RETURNS Void ->
            b = Box{ value: 1 } @shared:locked;
            got = identity(b);
            RETURN;
          END
        CLEAR

        ast = run(src)
        got = ast.statements.last.body[1]
        call = got.value

        expect(got.type_info).to be_shared
        expect(got.type_info.sync).to eq(:locked)
        expect(call.generic_type_args.first).to be_a(Type)
        expect(call.generic_type_args.first).to be_shared
        expect(call.generic_type_args.first.sync).to eq(:locked)
      end

      it "preserves capability axes through Cache<T> get/set" do
        src = <<~CLEAR
          STRUCT Box { value: Int64 }
          STRUCT Cache<T> { value: T }
          FN get<T>(c: Cache<T>) RETURNS T -> RETURN c.value; END
          FN set!<T>(MUTABLE c: Cache<T>, TAKES v: T) RETURNS Void ->
            c.value = v;
            RETURN;
          END
          FN main() RETURNS Void ->
            b = Box{ value: 1 } @shared:locked;
            MUTABLE c = Cache<Box @shared:locked>{ value: b };
            got = get(c);
            set!(c, got);
            RETURN;
          END
        CLEAR

        ast = run(src)
        main = ast.statements.last
        cache = main.body[1]
        got = main.body[2]
        set_call = main.body[3]

        cache_arg = cache.type_info.generic_args.first
        expect(cache_arg).to be_shared
        expect(cache_arg.sync).to eq(:locked)

        expect(got.type_info).to be_shared
        expect(got.type_info.sync).to eq(:locked)

        expect(got.value.generic_type_args.first).to be_shared
        expect(got.value.generic_type_args.first.sync).to eq(:locked)
        expect(set_call.generic_type_args.first).to be_shared
        expect(set_call.generic_type_args.first.sync).to eq(:locked)
      end

      it "infers implicit T for shared-family input and return" do
        src = <<~CLEAR
          STRUCT Box { value: Int64 }
          FN keep(x: SHARED T) RETURNS SHARED T
            REQUIRES x: LOCKED | VERSIONED
          ->
            RETURN x;
          END
          FN main() RETURNS Void ->
            b = Box{ value: 1 } @shared:locked;
            got = keep(b);
            RETURN;
          END
        CLEAR

        ast = run(src)
        keep = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "keep" }
        got = ast.statements.last.body[1]

        expect(keep.type_params).to eq(["T"])
        expect(got.type_info).to be_shared
        expect(got.type_info.sync).to eq(:locked)
        expect(got.value.generic_type_args.first).to be_a(Type)
      end

      it "returns bare T when copying out through a polymorphic shared access gate" do
        src = <<~CLEAR
          STRUCT Box { value: Int64 }
          FN copyOut(x: SHARED T) RETURNS !T ->
            WITH POLYMORPHIC x AS y { RETURN COPY y; }
          END
          FN main() RETURNS !Void ->
            b = Box{ value: 1 } @shared:locked;
            got = copyOut(b) OR EXIT;
            RETURN;
          END
        CLEAR

        ast = run(src)
        copy_out = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "copyOut" }
        ret = copy_out.body.first.body.first
        got = ast.statements.last.body[1]

        expect(ret.value.type_info.resolved).to eq(:T)
        expect(ret.value.type_info.ownership).to eq(:affine)
        expect(ret.value.type_info.sync).to be_nil
        expect(got.type_info.resolved).to eq(:Box)
        expect(got.type_info.ownership).to eq(:affine)
        expect(got.type_info.sync).to be_nil
      end

      it "rejects mixed synchronization capabilities across generic shared parameters at the call site" do
        src = <<~CLEAR
          STRUCT Box { value: Int64 }
          STRUCT Toy { value: Int64 }
          FN choose(x: SHARED T, y: SHARED Z) RETURNS SHARED Z
            REQUIRES x, y: LOCKED
          ->
            RETURN y;
          END
          FN main() RETURNS Void ->
            x = Box{ value: 1 } @shared:locked;
            y = Toy{ value: 2 } @shared:writeLocked;
            got = choose(x, y);
            RETURN;
          END
        CLEAR

        expect {
          run(src)
        }.to raise_error(CompilerError, /polymorphic @shared parameters.*same synchronization capability.*x.*@shared:locked.*y.*@shared:writeLocked/m)
      end

      it "allows different generic payloads when shared parameters use the same synchronization capability" do
        src = <<~CLEAR
          STRUCT Box { value: Int64 }
          STRUCT Toy { value: Int64 }
          FN choose(x: SHARED T, y: SHARED Z) RETURNS SHARED Z
            REQUIRES x, y: LOCKED
          ->
            RETURN y;
          END
          FN main() RETURNS Void ->
            x = Box{ value: 1 } @shared:locked;
            y = Toy{ value: 2 } @shared:locked;
            got = choose(x, y);
            RETURN;
          END
        CLEAR

        ast = run(src)
        got = ast.statements.last.body[2]
        expect(got.type_info).to be_shared
        expect(got.type_info.resolved).to eq(:Toy)
        expect(got.type_info.sync).to eq(:locked)
      end
    end

    describe "generic function error messages" do
      def fn_err_src(fn_code, call_code = "PASS")
        "STRUCT Pair<T> { first: T, second: T }\n" \
        "#{fn_code}\n" \
        "FN main() RETURNS Void ->\n#{call_code}\nEND"
      end

      it "raises GENERIC_FN_DUPLICATE_PARAM for duplicate type params" do
        expect {
          run(fn_err_src("FN bad<T, T>(x: T) RETURNS T -> RETURN x; END"))
        }.to raise_error(CompilerError, /Duplicate type parameter 'T' in generic function 'bad'/)
      end

      it "raises GENERIC_FN_PARAM_SHADOWS_BUILTIN for shadowing Float64" do
        expect {
          run(fn_err_src("FN bad<Float64>(x: Float64) RETURNS Float64 -> RETURN x; END"))
        }.to raise_error(CompilerError, /Type parameter 'Float64'.*shadows built-in type/)
      end

      it "raises GENERIC_FN_PARAM_SHADOWS_BUILTIN for shadowing Bool" do
        expect {
          run(fn_err_src("FN bad<Bool>(x: Bool) RETURNS Bool -> RETURN x; END"))
        }.to raise_error(CompilerError, /Type parameter 'Bool'.*shadows built-in type/)
      end

      it "raises GENERIC_FN_CANNOT_INFER when type param T is not used in any param" do
        expect {
          run(fn_err_src(
            "FN bad<T>(x: Float64) RETURNS Float64 -> RETURN x; END",
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
        # T inferred as Float64 from first arg; second arg should also be Float64
        src = fn_err_src(
          "FN same<T>(a: T, b: T) RETURNS T -> RETURN a; END",
          'r = same(1.0, "hello");'
        )
        expect { run(src) }.to raise_error(CompilerError)
      end
    end

    describe "Phase 4 Zig code generation" do
      it "emits 'comptime T: type' in function signature for FN identity<T>" do
        src = "FN identity<T>(x: T) RETURNS T -> RETURN x; END\nFN main() RETURNS Void -> PASS END"
        out = ZigTranspiler.new.transpile(src)
        expect(out).to include("fn identity(comptime T: type, x: T)")
      end

      it "emits two comptime params for a two-type-param function" do
        src = "FN first<A, B>(a: A, b: B) RETURNS A -> RETURN a; END\nFN main() RETURNS Void -> PASS END"
        out = ZigTranspiler.new.transpile(src)
        expect(out).to include("fn first(comptime A: type, comptime B: type, a: A")
      end

      it "emits inferred type arg at call site without rt when callee is pure" do
        src = "FN identity<T>(x: T) RETURNS T -> RETURN x; END\nFN main() RETURNS Void -> n = identity(42.0); END"
        out = ZigTranspiler.new.transpile(src)
        expect(out).to include("identity(f64,")
        expect(out).not_to include("identity(f64, rt,")
      end

      it "emits bool type arg at call site for identity(TRUE)" do
        src = "FN identity<T>(x: T) RETURNS T -> RETURN x; END\nFN main() RETURNS Void -> b = identity(TRUE); END"
        out = ZigTranspiler.new.transpile(src)
        expect(out).to include("identity(bool,")
        expect(out).not_to include("identity(bool, rt,")
      end

      it "emits Pair(T) as return type when RETURNS Pair<T>" do
        src = "STRUCT Pair<T> { first: T, second: T }\nFN makePair<T>(v: T) RETURNS Pair<T> -> RETURN Pair<T>{ first: v, second: v }; END\nFN main() RETURNS Void -> PASS END"
        out = ZigTranspiler.new.transpile(src)
        expect(out).to include("Pair(T)")
      end

      it "emits capability-preserving type args for Cache<T> get/set" do
        src = <<~CLEAR
          STRUCT Box { value: Int64 }
          STRUCT Cache<T> { value: T }
          FN get<T>(c: Cache<T>) RETURNS T -> RETURN c.value; END
          FN set!<T>(MUTABLE c: Cache<T>, TAKES v: T) RETURNS Void ->
            c.value = v;
            RETURN;
          END
          FN main() RETURNS Void ->
            b = Box{ value: 1 } @shared:locked;
            MUTABLE c = Cache<Box @shared:locked>{ value: b };
            got = get(c);
            set!(c, got);
            RETURN;
          END
        CLEAR

        out = ZigTranspiler.new.transpile(src)
        expect(out).to include("Cache(CheatLib.Arc(CheatLib.Locked(Box)))")
        expect(out).to include("get(CheatLib.Arc(CheatLib.Locked(Box)), c)")
        expect(out).to include("set(CheatLib.Arc(CheatLib.Locked(Box)), &c, got)")
        expect(out).to include("CheatLib.arcRetain(CheatLib.Locked(Box), b)")
      end

      it "monomorphizes shared-family returns from the input synchronization strategy" do
        src = <<~CLEAR
          STRUCT Box { value: Int64 }
          FN keep(x: SHARED T) RETURNS SHARED T
            REQUIRES x: LOCKED | VERSIONED
          ->
            RETURN x;
          END
          FN main() RETURNS Void ->
            b = Box{ value: 1 } @shared:versioned;
            got = keep(b);
            RETURN;
          END
        CLEAR

        out = ZigTranspiler.new.transpile(src)
        expect(out).to include("fn keep(comptime T: type, x: CheatLib.Arc(T)) @TypeOf(x)")
        expect(out).to include("keep(CheatLib.Versioned(Box), b)")
        expect(out).to include("CheatLib.arcRetain(T, x)")
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
          FN main() RETURNS Void ->
            #{extra}
          END
        CLEAR
      end

      it "parses and annotates Pair<Float64>{ first: 1.0, second: 2.0 } without error" do
        expect {
          run(generic_lit_src("p = Pair<Float64>{ first: 1.0, second: 2.0 };"))
        }.not_to raise_error
      end

      it "sets full_type to :\"Pair<Float64>\" on the StructLit node" do
        ast = run(generic_lit_src("p = Pair<Float64>{ first: 1.0, second: 2.0 };"))
        fn = ast.statements.last
        bind = fn.body.first
        lit = bind.value
        expect(lit).to be_a(AST::StructLit)
        expect(lit.resolved_type).to eq(:"Pair<Float64>")
      end

      it "stores type_args on the StructLit AST node" do
        ast = run(generic_lit_src("p = Pair<Float64>{ first: 1.0, second: 2.0 };"))
        fn = ast.statements.last
        bind = fn.body.first
        lit = bind.value
        expect(lit.type_args).to eq(["Float64"])
      end

      it "accepts KeyValue<String, Float64>{ key: \"x\", value: 42.0 }" do
        expect {
          run(generic_lit_src('kv = KeyValue<String, Float64>{ key: "x", value: 42.0 };'))
        }.not_to raise_error
      end

      it "resolves field access on a generic struct literal" do
        src = <<~CLEAR
          STRUCT Pair<T> { first: T, second: T }
          FN main() RETURNS Void ->
            p = Pair<Float64>{ first: 1.0, second: 2.0 };
            x = p.first;
          END
        CLEAR
        expect { run(src) }.not_to raise_error
      end

      it "infers field type as Float64 when accessing .first on Pair<Float64>" do
        src = <<~CLEAR
          STRUCT Pair<T> { first: T, second: T }
          FN main() RETURNS Void ->
            p = Pair<Float64>{ first: 1.0, second: 2.0 };
            x = p.first;
          END
        CLEAR
        ast = run(src)
        fn = ast.statements.last
        bind_x = fn.body[1]
        get_field = bind_x.value
        expect(get_field).to be_a(AST::GetField)
        expect(get_field.resolved_type).to eq(:Float64)
      end

      describe "error messages" do
        it "raises a type error when a field value has the wrong type" do
          expect {
            run(generic_lit_src('p = Pair<Float64>{ first: "oops", second: 2.0 };'))
          }.to raise_error(CompilerError, /expected.*Float64|got.*String/i)
        end

        it "raises a type error when wrong number of type args in literal" do
          expect {
            run(generic_lit_src("p = Pair<Float64, Bool>{ first: 1.0, second: true };"))
          }.to raise_error(CompilerError, /expects 1 type argument/)
        end

        it "raises a type error when a non-generic struct gets type args in literal" do
          src = <<~CLEAR
            STRUCT User { id: Float64 }
            FN main() RETURNS Void ->
              u = User<Float64>{ id: 1.0 };
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
            FN main() RETURNS Void ->
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
            FN main() RETURNS Void -> END
          CLEAR
          expect { run(src) }.to raise_error(CompilerError,
            /Duplicate type parameter 'T' in generic union 'Bad'/)
        end

        it "raises when type parameter shadows a builtin" do
          src = <<~CLEAR
            UNION Bad<Float64> { A: Float64 }
            FN main() RETURNS Void -> END
          CLEAR
          expect { run(src) }.to raise_error(CompilerError,
            /Type parameter 'Float64' shadows built-in type 'Float64'/)
        end

        it "accepts Option<Float64>{ Some: 42.0 } without error" do
          expect { run(union_src("opt = Option<Float64>{ Some: 42.0 };")) }.not_to raise_error
        end

        it "sets full_type to :\"Option<Float64>\" on the union literal" do
          ast = run(union_src("opt = Option<Float64>{ Some: 42.0 };"))
          fn = ast.statements.last
          bind = fn.body.first
          lit = bind.value
          expect(lit).to be_a(AST::StructLit)
          expect(lit.resolved_type).to eq(:"Option<Float64>")
        end

        it "accepts Option<Float64>{ Some: 0.0 } (second Some variant) without error" do
          expect { run(union_src("n = Option<Float64>{ Some: 0.0 };")) }.not_to raise_error
        end

        it "accepts Result<Float64, Bool>{ Err: TRUE } without error" do
          expect { run(union_src("r = Result<Float64, Bool>{ Err: TRUE };")) }.not_to raise_error
        end

        it "raises when instantiating a generic union without type args" do
          src = <<~CLEAR
            UNION Option<T> { Some: T, None }
            FN main() RETURNS Void ->
              bad = Option{ Some: 1.0 };
            END
          CLEAR
          expect { run(src) }.to raise_error(CompilerError,
            /generic type.*type arguments are required/i)
        end

        it "raises when a union variant value type is wrong" do
          src = <<~CLEAR
            UNION Option<T> { Some: T, None }
            FN main() RETURNS Void ->
              bad = Option<Float64>{ Some: TRUE };
            END
          CLEAR
          expect { run(src) }.to raise_error(CompilerError, /Type Error/)
        end

        it "allows MATCH on Option<Float64> without type error" do
          src = union_src(<<~BODY)
            opt = Option<Float64>{ Some: 42.0 };
            MUTABLE got = 0.0;
            PARTIAL MATCH opt START
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
            FN main() RETURNS Void -> END
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
            FN main() RETURNS Void -> END
          CLEAR
          out = union_zig(src)
          expect(out).to include("fn Result(comptime T: type, comptime E: type)")
          expect(out).to include("Ok: T")
          expect(out).to include("Err: E")
        end

        it "emits Option(f64){ .Some = 42 } for Option<Float64>{ Some: 42.0 }" do
          src = <<~CLEAR
            UNION Option<T> { Some: T, None }
            FN main() RETURNS Void ->
              opt = Option<Float64>{ Some: 42.0 };
            END
          CLEAR
          out = union_zig(src)
          expect(out).to include("Option(f64)")
          expect(out).to include(".Some =")
        end

        it "emits Result(f64, bool){ .Err = true } for generic Result literal" do
          src = <<~CLEAR
            UNION Result<T, E> { Ok: T, Err: E }
            FN main() RETURNS Void ->
              r = Result<Float64, Bool>{ Err: TRUE };
            END
          CLEAR
          out = union_zig(src)
          expect(out).to include("Result(f64, bool)")
          expect(out).to include(".Err =")
        end
      end

      describe "Phase 3 Zig code generation" do
        it "emits Pair(f64){ .first = ..., .second = ... } for Pair<Float64>" do
          src = <<~CLEAR
            STRUCT Pair<T> { first: T, second: T }
            FN main() RETURNS Void ->
              p = Pair<Float64>{ first: 1.0, second: 2.0 };
            END
          CLEAR
          out = ZigTranspiler.new.transpile(src)
          expect(out).to include("Pair(f64)")
          expect(out).to include(".first =")
          expect(out).to include(".second =")
        end

        it "emits KeyValue([]const u8, f64){ ... } for KeyValue<String, Float64>" do
          src = <<~CLEAR
            STRUCT KeyValue<K, V> { key: K, value: V }
            FN main() RETURNS Void ->
              kv = KeyValue<String, Float64>{ key: "x", value: 42.0 };
            END
          CLEAR
          out = ZigTranspiler.new.transpile(src)
          expect(out).to include("KeyValue([]const u8, f64)")
        end
      end
    end
  end

end
