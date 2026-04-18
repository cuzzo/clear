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

  # ===========================================================================
  # FIRST-CLASS FUNCTION TYPES — Phase 1
  # ===========================================================================
  describe "Function Types — Phase 1 (FN(T) -> R type annotations)" do

    def transpile(source)
      ZigTranspiler.new.transpile(source)
    end

    # -------------------------------------------------------------------------
    # Parser: parse_fn_type_annotation
    # -------------------------------------------------------------------------
    describe "Parser" do
      context "FN(Int64) -> Bool in a type annotation position" do
        let(:code) { "cb: FN(Int64) -> Bool = %(n: Int64) -> n > 0;" }
        it "parses without error" do
          expect { run(code) }.not_to raise_error
        end
      end

      context "FN(Int64, Int64) -> Int64 (two params)" do
        let(:code) { "add: FN(Int64, Int64) -> Int64 = %(a: Int64, b: Int64) -> a + b;" }
        it "parses without error" do
          expect { run(code) }.not_to raise_error
        end
      end

      context "FN() -> Bool (no params)" do
        let(:code) { "noop: FN() -> Bool = %() -> TRUE;" }
        it "parses without error" do
          expect { run(code) }.not_to raise_error
        end
      end

      context "FN(n: Int64) -> Bool with optional parameter name" do
        let(:code) { "cb: FN(n: Int64) -> Bool = %(n: Int64) -> n > 0;" }
        it "parses without error (name is documentation only)" do
          expect { run(code) }.not_to raise_error
        end
      end

      context "FN type in a named-function parameter position" do
        let(:code) {
          <<~CLEAR
            FN apply(cb: FN(Int64) -> Bool, n: Int64) RETURNS Bool ->
              RETURN FALSE;
            END
          CLEAR
        }
        it "parses without error" do
          expect { run(code) }.not_to raise_error
        end
      end
    end

    # -------------------------------------------------------------------------
    # Type object: fn_type? predicate
    # -------------------------------------------------------------------------
    describe "Type#fn_type?" do
      it "returns true for a parsed FN type annotation" do
        tokens = Lexer.new("cb: FN(Int64) -> Bool = %(n: Int64) -> n > 0;").tokenize
        ast    = Parser.new(tokens, "").parse
        bind   = ast.statements.first
        expect(bind.type.fn_type?).to be true
      end

      it "returns false for plain symbol types" do
        expect(Type.new(:Bool).fn_type?).to be false
        expect(Type.new(:Int64).fn_type?).to be false
      end
    end

    # -------------------------------------------------------------------------
    # Type#zig_type for fn_type
    # -------------------------------------------------------------------------
    describe "Type#zig_type for fn_type" do
      def fn_type_for(source)
        tokens = Lexer.new(source).tokenize
        ast    = Parser.new(tokens, "").parse
        ast.statements.first.type
      end

      it "emits *const fn(*Runtime, i64) anyerror!bool for FN(Int64) -> Bool" do
        t = fn_type_for("cb: FN(Int64) -> Bool = %(n: Int64) -> n > 0;")
        expect(t.zig_type).to eq("*const fn(*Runtime, i64) anyerror!bool")
      end

      it "emits *const fn(*Runtime, i64, i64) anyerror!i64 for FN(Int64, Int64) -> Int64" do
        t = fn_type_for("add: FN(Int64, Int64) -> Int64 = %(a: Int64, b: Int64) -> a + b;")
        expect(t.zig_type).to eq("*const fn(*Runtime, i64, i64) anyerror!i64")
      end

      it "emits *const fn(*Runtime) anyerror!void for FN() -> Void" do
        # Parse only — don't run the annotator (Void lambdas need separate handling)
        tokens = Lexer.new("FN() -> Void").tokenize
        # Parse just the type annotation directly via the parser
        t = Type.new({ params: [], return: { type: Type.new(:Void) }, fn_type: true })
        expect(t.zig_type).to eq("*const fn(*Runtime) anyerror!void")
      end
    end

    # -------------------------------------------------------------------------
    # Annotator: variable declaration stores fn_type correctly
    # -------------------------------------------------------------------------
    describe "Annotator: variable declaration with fn_type" do
      context "cb: FN(Int64) -> Bool = %(n: Int64) -> n > 0" do
        let(:code) { "cb: FN(Int64) -> Bool = %(n: Int64) -> n > 0;" }

        it "annotates without error" do
          expect { run(code) }.not_to raise_error
        end

        it "stores the fn_type as full_type on the bind node" do
          tree = run(code)
          bind = tree.statements.first
          expect(bind.full_type.fn_type?).to be true
        end
      end

      context "fn_type param in a function definition" do
        let(:code) {
          <<~CLEAR
            FN apply(cb: FN(Int64) -> Bool, n: Int64) RETURNS Bool ->
              RETURN FALSE;
            END
          CLEAR
        }
        it "annotates without error" do
          expect { run(code) }.not_to raise_error
        end

        it "stores the fn_type as the param type" do
          tree = run(code)
          fn_def = tree.statements.first
          cb_param = fn_def.params.find { |p| p[:name] == "cb" }
          expect(cb_param[:type].fn_type?).to be true
        end
      end
    end

    # -------------------------------------------------------------------------
    # Phase 2: Full signature matching in Type#accepts?
    # -------------------------------------------------------------------------
    describe "Type#accepts? full signature matching (Phase 2)" do
      def fn_type(params, ret)
        Type.new({
          params: params.map.with_index { |t, i| { name: "arg#{i}", type: Type.new(t), required: true, mutable: false, takes: false } },
          return: { type: Type.new(ret) },
          fn_type: true
        })
      end

      it "accepts identical signatures" do
        expect(fn_type([:Int64], :Bool).accepts?(fn_type([:Int64], :Bool))).to be true
      end

      it "rejects when param type differs" do
        expect(fn_type([:Int64], :Bool).accepts?(fn_type([:String], :Bool))).to be false
      end

      it "rejects when return type differs" do
        expect(fn_type([:Int64], :Bool).accepts?(fn_type([:Int64], :Int64))).to be false
      end

      it "rejects when param count differs" do
        expect(fn_type([:Int64], :Bool).accepts?(fn_type([:Int64, :Int64], :Bool))).to be false
      end

      it "rejects non-fn_type (plain symbol)" do
        expect(fn_type([:Int64], :Bool).accepts?(Type.new(:Bool))).to be false
      end

      it "accepts when other_type is :Any" do
        expect(fn_type([:Int64], :Bool).accepts?(Type.new(:Any))).to be true
      end
    end

    # -------------------------------------------------------------------------
    # Annotator: type mismatch errors
    # -------------------------------------------------------------------------
    describe "Annotator: fn_type type checking" do
      context "lambda return type does not match declared FN return type" do
        let(:code) { "cb: FN(Int64) -> Bool = %(n: Int64) -> \"hello\";" }
        it "raises a type mismatch error" do
          expect { run(code) }.to raise_error(/Type Mismatch/i)
        end
      end

      context "lambda param count does not match FN param count" do
        let(:code) { "cb: FN(Int64) -> Bool = %(a: Int64, b: Int64) -> a > b;" }
        it "raises a type mismatch error" do
          expect { run(code) }.to raise_error(CompilerError)
        end
      end
    end

    # -------------------------------------------------------------------------
    # Transpiler: LambdaLit + fn_type VarDecl
    # -------------------------------------------------------------------------
    describe "Transpiler" do
      context "lambda assigned to FN(Int64) -> Bool variable" do
        let(:source) {
          <<~CLEAR
            FN main() RETURNS Void ->
              cb: FN(Int64) -> Bool = %(n: Int64) -> n > 0;
            END
          CLEAR
        }
        it "emits *const fn(*Runtime, i64) anyerror!bool type annotation" do
          zig = transpile(source)
          expect(zig).to include("*const fn(*Runtime, i64) anyerror!bool")
        end

        it "emits a lambda struct wrapper" do
          zig = transpile(source)
          expect(zig).to match(/&\(struct \{ fn _lambda_\d+/)
        end
      end

      context "FN type in a function parameter" do
        let(:source) {
          <<~CLEAR
            FN apply(cb: FN(Int64) -> Bool, n: Int64) RETURNS Bool ->
              RETURN FALSE;
            END
          CLEAR
        }
        it "emits *const fn(*Runtime, i64) anyerror!bool as the parameter type" do
          zig = transpile(source)
          expect(zig).to include("cb: *const fn(*Runtime, i64) anyerror!bool")
        end
      end
    end

  end

  # ===========================================================================
  # FIRST-CLASS FUNCTION TYPES — Phase 3
  # ===========================================================================
  describe "Function Types — Phase 3 (calling fn-type variables)" do

    def transpile(source)
      ZigTranspiler.new.transpile(source)
    end

    # -------------------------------------------------------------------------
    # Annotator: calling fn-type variables resolves the return type
    # -------------------------------------------------------------------------
    describe "Annotator: calling fn-type variables" do
      context "cb: FN(Int64) -> Bool; result = cb(5)" do
        let(:code) {
          <<~CLEAR
            cb: FN(Int64) -> Bool = %(n: Int64) -> n > 0;
            result: Bool = cb(5);
          CLEAR
        }
        it "annotates without error" do
          expect { run(code) }.not_to raise_error
        end

        it "resolves the call's type to Bool" do
          tree = run(code)
          call_stmt = tree.statements[1]
          # call_stmt is a BindExpr; the value is the FuncCall
          expect(call_stmt.value.resolved_type).to eq(:Bool)
        end
      end

      context "add: FN(Int64, Int64) -> Int64; sum = add(3, 4)" do
        let(:code) {
          <<~CLEAR
            add: FN(Int64, Int64) -> Int64 = %(a: Int64, b: Int64) -> a + b;
            sum: Int64 = add(3, 4);
          CLEAR
        }
        it "annotates without error" do
          expect { run(code) }.not_to raise_error
        end
      end

      context "calling fn-type variable with wrong argument type" do
        let(:code) {
          <<~CLEAR
            cb: FN(Int64) -> Bool = %(n: Int64) -> n > 0;
            result: Bool = cb("oops");
          CLEAR
        }
        it "raises a type mismatch error" do
          expect { run(code) }.to raise_error(CompilerError)
        end
      end
    end

    # -------------------------------------------------------------------------
    # Transpiler: fn-type call emits try name(rt, args...)
    # -------------------------------------------------------------------------
    describe "Transpiler: calling fn-type variables" do
      context "cb(5) where cb: FN(Int64) -> Bool" do
        let(:source) {
          <<~CLEAR
            FN main() RETURNS Void @nonReentrant ->
              cb: FN(Int64) -> Bool = %(n: Int64) -> n > 0;
              result: Bool = cb(5);
            END
          CLEAR
        }
        it "emits try cb(rt, ...)" do
          zig = transpile(source)
          expect(zig).to match(/try cb\(rt,/)
        end
      end

      context "add(3, 4) where add: FN(Int64, Int64) -> Int64" do
        let(:source) {
          <<~CLEAR
            FN main() RETURNS Void @nonReentrant ->
              add: FN(Int64, Int64) -> Int64 = %(a: Int64, b: Int64) -> a + b;
              sum: Int64 = add(3, 4);
            END
          CLEAR
        }
        it "emits try add(rt, ...)" do
          zig = transpile(source)
          expect(zig).to match(/try add\(rt,/)
        end
      end
    end

  end

  # ===========================================================================
  # FIRST-CLASS FUNCTION TYPES — Phase 4
  # ===========================================================================
  describe "Function Types — Phase 4 (named functions as values)" do

    def transpile(source)
      ZigTranspiler.new.transpile(source)
    end

    let(:fn_preamble) {
      <<~CLEAR
        FN isPositive(n: Int64) RETURNS Bool ->
          RETURN n > 0;
        END
        FN apply(cb: FN(Int64) -> Bool, n: Int64) RETURNS Bool ->
          RETURN cb(n);
        END
      CLEAR
    }

    # -------------------------------------------------------------------------
    # Annotator: named function used as a value
    # -------------------------------------------------------------------------
    describe "Annotator: named function as value" do
      context "apply(isPositive, 5)" do
        let(:code) {
          <<~CLEAR
            FN isPositive(n: Int64) RETURNS Bool ->
              RETURN n > 0;
            END
            FN apply(cb: FN(Int64) -> Bool, n: Int64) RETURNS Bool @nonReentrant ->
              RETURN cb(n);
            END
            result: Bool = apply(isPositive, 5);
          CLEAR
        }

        it "annotates without error" do
          expect { run(code) }.not_to raise_error
        end

        it "marks the Identifier as fn_ref" do
          tree = run(code)
          call_stmt = tree.statements.last
          fn_ref_arg = call_stmt.value.args.find { |a| a.is_a?(AST::Identifier) && a.name == "isPositive" }
          expect(fn_ref_arg).not_to be_nil
          expect(fn_ref_arg.fn_ref).to be true
        end

        it "resolves the fn_ref identifier's type as fn_type?" do
          tree = run(code)
          call_stmt = tree.statements.last
          fn_ref_arg = call_stmt.value.args.find { |a| a.is_a?(AST::Identifier) && a.name == "isPositive" }
          expect(fn_ref_arg.full_type.fn_type?).to be true
        end
      end

      context "named function with wrong return type passed where fn_type expected" do
        let(:code) {
          <<~CLEAR
            FN returnsString(n: Int64) RETURNS String ->
              RETURN "hello";
            END
            FN apply(cb: FN(Int64) -> Bool, n: Int64) RETURNS Bool ->
              RETURN cb(n);
            END
            result: Bool = apply(returnsString, 5);
          CLEAR
        }
        it "raises a type mismatch error" do
          expect { run(code) }.to raise_error(CompilerError)
        end
      end
    end

    # -------------------------------------------------------------------------
    # Transpiler: named function as value emits &name
    # -------------------------------------------------------------------------
    describe "Transpiler: named function as value" do
      let(:source) {
        <<~CLEAR
          FN isPositive(n: Int64) RETURNS Bool ->
            RETURN n > 0;
          END
          FN apply(cb: FN(Int64) -> Bool, n: Int64) RETURNS Bool @nonReentrant ->
            RETURN cb(n);
          END
          FN main() RETURNS Void ->
            result: Bool = apply(isPositive, 5);
          END
        CLEAR
      }

      it "emits &isPositive as the argument" do
        zig = transpile(source)
        expect(zig).to include("&isPositive")
      end

      it "emits try apply(rt, &isPositive, ...)" do
        zig = transpile(source)
        expect(zig).to match(/try apply\(rt, &isPositive,/)
      end
    end

  end

  # ===========================================================================
  # FN-TYPE PARAMETER @reentrant CONSTRAINT
  # ===========================================================================
  describe "fn-type parameter @reentrant constraint" do

    # -------------------------------------------------------------------------
    # Blocking @reentrant functions at non-reentrant parameters
    # -------------------------------------------------------------------------
    describe "passing @reentrant functions to non-@reentrant parameters" do
      it "raises a reentrancy error when passing a @reentrant function to a plain fn-type param" do
        code = <<~CLEAR
          FN fib(n: Int64) RETURNS Int64 @reentrant ->
            IF n <= 1 THEN RETURN n; END
            RETURN fib(n - 1) + fib(n - 2);
          END
          FN apply(cb: FN(Int64) -> Int64, x: Int64) RETURNS Int64 @nonReentrant ->
            RETURN cb(x);
          END
          result: Int64 = apply(fib, 5);
        CLEAR
        expect { run(code) }.to raise_error(CompilerError, /Reentrancy Error.*fib.*@reentrant/)
      end

      it "does not raise when passing a non-reentrant function to a plain fn-type param" do
        code = <<~CLEAR
          FN double(x: Int64) RETURNS Int64 ->
            RETURN x * 2;
          END
          FN apply(cb: FN(Int64) -> Int64, x: Int64) RETURNS Int64 @nonReentrant ->
            RETURN cb(x);
          END
          result: Int64 = apply(double, 5);
        CLEAR
        expect { run(code) }.not_to raise_error
      end
    end

    # -------------------------------------------------------------------------
    # Allowing @reentrant functions at @reentrant-annotated parameters
    # -------------------------------------------------------------------------
    describe "passing @reentrant functions to @reentrant-annotated fn-type params" do
      it "accepts a @reentrant function when the param declares @reentrant" do
        code = <<~CLEAR
          FN fib(n: Int64) RETURNS Int64 @reentrant ->
            IF n <= 1 THEN RETURN n; END
            RETURN fib(n - 1) + fib(n - 2);
          END
          FN apply(cb: FN(Int64) -> Int64 @reentrant, x: Int64) RETURNS Int64 @nonReentrant ->
            RETURN cb(x);
          END
          result: Int64 = apply(fib, 5);
        CLEAR
        expect { run(code) }.not_to raise_error
      end

      it "also accepts a non-reentrant function at a @reentrant-annotated param (covariant)" do
        code = <<~CLEAR
          FN double(x: Int64) RETURNS Int64 ->
            RETURN x * 2;
          END
          FN apply(cb: FN(Int64) -> Int64 @reentrant, x: Int64) RETURNS Int64 @nonReentrant ->
            RETURN cb(x);
          END
          result: Int64 = apply(double, 5);
        CLEAR
        expect { run(code) }.not_to raise_error
      end
    end

    # -------------------------------------------------------------------------
    # Parser: @reentrant on fn-type annotation
    # -------------------------------------------------------------------------
    describe "parser" do
      it "parses @reentrant on a fn-type param annotation" do
        code = <<~CLEAR
          FN apply(cb: FN(Int64) -> Int64 @reentrant, x: Int64) RETURNS Int64 @nonReentrant ->
            RETURN cb(x);
          END
        CLEAR
        tree = run(code)
        fn = tree.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "apply" }
        cb_param = fn.params.find { |p| p[:name] == "cb" }
        expect(cb_param[:type].raw[:reentrant]).to be true
      end

      it "leaves reentrant false on a plain fn-type param annotation" do
        code = <<~CLEAR
          FN apply(cb: FN(Int64) -> Int64, x: Int64) RETURNS Int64 @nonReentrant ->
            RETURN cb(x);
          END
        CLEAR
        tree = run(code)
        fn = tree.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "apply" }
        cb_param = fn.params.find { |p| p[:name] == "cb" }
        expect(cb_param[:type].raw[:reentrant]).to be_falsy
      end
    end

    # -------------------------------------------------------------------------
    # Type: @reentrant propagated on fn_ref
    # -------------------------------------------------------------------------
    describe "fn_ref type propagation" do
      it "marks the fn_ref type as reentrant when the named function is @reentrant" do
        code = <<~CLEAR
          FN fib(n: Int64) RETURNS Int64 @reentrant ->
            IF n <= 1 THEN RETURN n; END
            RETURN fib(n - 1) + fib(n - 2);
          END
          FN apply(cb: FN(Int64) -> Int64 @reentrant, x: Int64) RETURNS Int64 @nonReentrant ->
            RETURN cb(x);
          END
          result: Int64 = apply(fib, 5);
        CLEAR
        tree = run(code)
        call = tree.statements.last.value
        fib_arg = call.args.find { |a| a.is_a?(AST::Identifier) && a.name == "fib" }
        expect(fib_arg.full_type.raw[:reentrant]).to be true
      end

      it "does not mark the fn_ref type as reentrant for a non-@reentrant function" do
        code = <<~CLEAR
          FN double(x: Int64) RETURNS Int64 ->
            RETURN x * 2;
          END
          FN apply(cb: FN(Int64) -> Int64, x: Int64) RETURNS Int64 @nonReentrant ->
            RETURN cb(x);
          END
          result: Int64 = apply(double, 5);
        CLEAR
        tree = run(code)
        call = tree.statements.last.value
        double_arg = call.args.find { |a| a.is_a?(AST::Identifier) && a.name == "double" }
        expect(double_arg.full_type.raw[:reentrant]).to be_falsy
      end
    end

  end

end
