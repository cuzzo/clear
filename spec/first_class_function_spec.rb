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
            FN cheatMain() RETURNS Void ->
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

end
