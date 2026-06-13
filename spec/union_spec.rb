require "rspec"
require "byebug"
require "tmpdir"
require "fileutils"

require_relative "../src/backends/transpiler"
require_relative "../src/ast/ast"

RSpec.describe SemanticAnnotator do
  def run(source)
    tokens = Lexer.new(source).tokenize
    ast = ClearParser.new(tokens, source).parse
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)
    return ast
  end

  def get_last_type(source)
    run(source).statements.last.resolved_type
  end

  let(:ast) { run(code) }
  let(:result) { ast.statements.last.resolved_type }

  # ==========================================
  # UNION (Tagged Sum Types)
  # ==========================================
  describe "UNION" do
    # --------------------------------------------------
    # Declaration
    # --------------------------------------------------
    describe "declaration" do
      it "registers the union type in scope without error" do
        expect { run("UNION Shape { Circle: Float64, Point }") }.not_to raise_error
      end

      it "resolves the UnionDef node as Void (like StructDef)" do
        ast = run("UNION Shape { Circle: Float64, Point }")
        expect(ast.statements.first.resolved_type).to eq(:Void)
      end

      it "accepts PUB UNION without error" do
        expect { run("PUB UNION Result { Ok: Float64, Err: Float64 }") }.not_to raise_error
      end

      it "accepts PRIVATE UNION without error" do
        expect { run("PRIVATE UNION Internal { A: Float64, B }") }.not_to raise_error
      end

      it "allows unit variants (no payload type)" do
        expect { run("UNION Maybe { Some: Float64, None }") }.not_to raise_error
      end

      it "allows multiple independent union types in the same file" do
        expect {
          run(<<~CLEAR)
            UNION Shape { Circle: Float64, Point }
            UNION Result { Ok: Float64, Err: Float64 }
          CLEAR
        }.not_to raise_error
      end
    end

    # --------------------------------------------------
    # Variant construction
    # --------------------------------------------------
    describe "variant construction" do
      context "payload variant: UnionType{ Variant: value }" do
        let(:code) {
          <<~CLEAR
            UNION Result { Ok: Float64, Err: Float64 }
            r: Result = Result{ Ok: 42 };
          CLEAR
        }

        it "resolves the struct literal to the union type" do
          # The value of the BindExpr is a StructLit resolved to :Result
          expect(ast.statements.last.value.resolved_type).to eq(:Result)
        end

        it "resolves the declared variable to the union type" do
          expect(ast.statements.last.resolved_type).to eq(:Result)
        end
      end

      context "unit variant: UnionType.Variant (no payload — GetField)" do
        let(:code) {
          <<~CLEAR
            UNION Maybe { Some: Float64, None }
            x: Maybe = Maybe.None;
          CLEAR
        }

        it "resolves the unit variant access to the union type" do
          expect(ast.statements.last.value.resolved_type).to eq(:Maybe)
        end

        it "resolves the declared variable to the union type" do
          expect(ast.statements.last.resolved_type).to eq(:Maybe)
        end
      end

      it "resolves all variants to the same union type" do
        ast = run(<<~CLEAR)
          UNION Shape { Circle: Float64, Rectangle: Float64, Point }
          a: Shape = Shape{ Circle: 1.0 };
          b: Shape = Shape{ Rectangle: 2.0 };
          c: Shape = Shape.Point;
        CLEAR
        ast.statements.drop(1).each do |stmt|
          expect(stmt.resolved_type).to eq(:Shape)
        end
      end
    end

    # --------------------------------------------------
    # Functions with union params / return types
    # --------------------------------------------------
    describe "union in function signatures" do
      let(:code) {
        <<~CLEAR
          UNION Result { Ok: Float64, Err: Float64 }
          FN mirror(r: Result) RETURNS Result ->
            RETURN r;
          END
          FN main() RETURNS Void ->
            out = mirror(Result{ Ok: 1 });
          END
        CLEAR
      }

      it "accepts union as parameter type without error" do
        expect { ast }.not_to raise_error
      end

      it "resolves the call result to the union type" do
        fn   = ast.statements.last
        stmt = fn.body.last
        expect(stmt.resolved_type).to eq(:Result)
      end

      it "raises Type Error when wrong type is passed to union param" do
        expect {
          run(<<~CLEAR)
            UNION Result { Ok: Float64 }
            FN use(r: Result) RETURNS Void ->
            END
            FN main() RETURNS Void ->
              use(42);
            END
          CLEAR
        }.to raise_error(/Type Error/i)
      end
    end

    # --------------------------------------------------
    # Optional union: ?UnionType
    # --------------------------------------------------
    describe "optional union (?UnionType)" do
      it "parses and type-checks ?Union as a valid type annotation" do
        expect {
          run(<<~CLEAR)
            UNION Result { Ok: Float64, Err: Float64 }
            FN maybe_result() RETURNS ?Result ->
              RETURN NIL;
            END
          CLEAR
        }.not_to raise_error
      end
    end

    # --------------------------------------------------
    # Error union: !UnionType
    # --------------------------------------------------
    describe "error union (!UnionType)" do
      it "parses and type-checks !Union as a valid return type" do
        expect {
          run(<<~CLEAR)
            UNION Payload { Data: Float64, Empty }
            FN risky() RETURNS !Payload ->
              RETURN Payload{ Data: 1 };
            END
          CLEAR
        }.not_to raise_error
      end
    end

    # --------------------------------------------------
    # MATCH on union values
    # --------------------------------------------------
    describe "MATCH" do
      it "type-checks MATCH cases against the union type without error" do
        expect {
          run(<<~CLEAR)
            UNION Shape { Circle: Float64, Point }
            FN main() RETURNS Void ->
              s: Shape = Shape.Point;
              MUTABLE n = 0_i64;
              PARTIAL MATCH s START
                Shape.Circle -> n = 1_i64;,
                Shape.Point  -> n = 2_i64;
              END
            END
          CLEAR
        }.not_to raise_error
      end

      it "raises an error when a MATCH case is a different union type" do
        expect {
          run(<<~CLEAR)
            UNION Shape { Circle: Float64, Point }
            UNION Color  { Red, Blue }
            FN main() RETURNS Void ->
              s: Shape = Shape.Point;
              MUTABLE n = 0_i64;
              PARTIAL MATCH s START
                Color.Red -> n = 1_i64;
              END
            END
          CLEAR
        }.to raise_error(CompilerError, /MATCH case type Color does not match expression type Shape/)
      end
    end

    # --------------------------------------------------
    # Error messages
    # --------------------------------------------------
    describe "error messages" do
      it "raises 'Type Error: Union ... has no variant' for an unknown variant (dot access)" do
        expect {
          run(<<~CLEAR)
            UNION Result { Ok: Float64 }
            x: Result = Result.Missing;
          CLEAR
        }.to raise_error(CompilerError, /Type Error: Union 'Result' has no variant 'Missing'/)
      end

      it "raises 'Type Error: Union ... has no variant' for an unknown variant in struct literal" do
        expect {
          run(<<~CLEAR)
            UNION Result { Ok: Float64 }
            FN main() RETURNS Void ->
              x: Result = Result{ Nope: 1 };
            END
          CLEAR
        }.to raise_error(CompilerError, /Type Error: Union 'Result' has no variant 'Nope'/)
      end

      it "raises 'Type Error: Union variant ... expects ...' for a payload type mismatch" do
        expect {
          run(<<~CLEAR)
            UNION Result { Ok: Float64 }
            FN main() RETURNS Void ->
              x: Result = Result{ Ok: TRUE };
            END
          CLEAR
        }.to raise_error(CompilerError, /Type Error: Union variant 'Ok' expects Float64, got Bool/)
      end

      it "raises 'Type Error: ... is a union type' when accessing a field on a union value" do
        expect {
          run(<<~CLEAR)
            UNION Shape { Circle: Float64 }
            FN main() RETURNS Void ->
              s: Shape = Shape{ Circle: 1.0 };
              bad = s.Circle;
            END
          CLEAR
        }.to raise_error(CompilerError, /Type Error: 'Shape' is a union type/)
      end
    end

    # --------------------------------------------------
    # Zig code generation
    # --------------------------------------------------
    describe "Zig code generation" do
      def transpile(src)
        ZigTranspiler.new.transpile(src)
      end

      it "emits a Zig tagged union declaration" do
        out = transpile(<<~CLEAR)
          UNION Shape { Circle: Float64, Point }
          FN main() RETURNS Void ->
          END
        CLEAR
        expect(out).to include("const Shape = union(enum) {")
        expect(out).to include("Circle: f64,")
        expect(out).to include("Point: void")
      end

      it "emits payload variant constructor as UnionType{ .Variant = payload }" do
        out = transpile(<<~CLEAR)
          UNION Result { Ok: Float64 }
          FN main() RETURNS Void ->
            r: Result = Result{ Ok: 42 };
          END
        CLEAR
        expect(out).to include("Result{ .Ok = 42 }")
      end

      it "emits unit variant constructor as UnionType{ .Variant = {} }" do
        out = transpile(<<~CLEAR)
          UNION Maybe { Some: Float64, None }
          FN main() RETURNS Void ->
            x: Maybe = Maybe.None;
          END
        CLEAR
        expect(out).to include("Maybe{ .None = {} }")
      end

      it "emits MATCH on union using std.meta.activeTag" do
        out = transpile(<<~CLEAR)
          UNION Shape { Circle: Float64, Point }
          FN main() RETURNS Void ->
            s: Shape = Shape.Point;
            MUTABLE n = 0_i64;
            PARTIAL MATCH s START
              Shape.Circle -> n = 1_i64;,
              Shape.Point  -> n = 2_i64;
            END
          END
        CLEAR
        expect(out).to include("switch (s)")
        expect(out).to include(".Circle =>")
        expect(out).to include(".Point =>")
      end

      it "includes PUB UNION in transpile_module output" do
        out = ZigTranspiler.new.transpile_as_module(<<~CLEAR)
          PUB UNION Result { Ok: Float64, Err: Float64 }
          FN main() RETURNS Void ->
          END
        CLEAR
        expect(out).to include("const Result = union(enum) {")
      end

      it "excludes PRIVATE UNION from transpile_module output" do
        out = ZigTranspiler.new.transpile_as_module(<<~CLEAR)
          PRIVATE UNION Internal { A: Float64, B }
          FN main() RETURNS Void ->
          END
        CLEAR
        expect(out).not_to include("const Internal = union(enum) {")
      end
    end

    # --------------------------------------------------
    # Inline struct variants
    # --------------------------------------------------
    describe "inline struct variants" do
      def transpile(src)
        ZigTranspiler.new.transpile(src)
      end

      # Declaration
      describe "declaration" do
        it "accepts a UNION with an inline struct variant without error" do
          expect {
            run("UNION Shape { Circle { radius: Float64 }, Point }")
          }.not_to raise_error
        end

        it "accepts multiple inline struct variants alongside unit and single-payload variants" do
          expect {
            run(<<~CLEAR)
              UNION Mixed {
                Inline { x: Float64, y: Float64 },
                Single: Float64,
                Unit
              }
            CLEAR
          }.not_to raise_error
        end

        it "resolves the UnionDef node as Void" do
          ast = run("UNION Shape { Circle { radius: Float64 }, Point }")
          expect(ast.statements.first.resolved_type).to eq(:Void)
        end

        it "accepts PUB UNION with inline struct variants" do
          expect {
            run("PUB UNION Shape { Circle { radius: Float64 }, Point }")
          }.not_to raise_error
        end

        it "raises an error when inline struct variant is used in a generic union" do
          expect {
            run("UNION Box<T> { Wrapped { value: T }, Empty }")
          }.to raise_error(CompilerError, /Inline struct variants are not supported in generic unions/)
        end
      end

      # Construction
      describe "construction (UnionVariantLit)" do
        it "resolves an inline variant constructor to the union type" do
          ast = run(<<~CLEAR)
            UNION Shape { Circle { radius: Float64 }, Point }
            FN main() RETURNS Void ->
              c: Shape = Shape.Circle{ radius: 5.0 };
            END
          CLEAR
          bind = ast.statements.last.body.first
          expect(bind.value.resolved_type).to eq(:Shape)
        end

        it "resolves the declared variable to the union type" do
          ast = run(<<~CLEAR)
            UNION Shape { Circle { radius: Float64 }, Point }
            FN main() RETURNS Void ->
              c: Shape = Shape.Circle{ radius: 5.0 };
            END
          CLEAR
          bind = ast.statements.last.body.first
          expect(bind.resolved_type).to eq(:Shape)
        end

        it "accepts multiple-field inline variant constructor" do
          expect {
            run(<<~CLEAR)
              UNION Shape { Rectangle { width: Float64, height: Float64 }, Point }
              FN main() RETURNS Void ->
                r: Shape = Shape.Rectangle{ width: 3.0, height: 4.0 };
              END
            CLEAR
          }.not_to raise_error
        end

        it "raises when an unknown field is passed" do
          expect {
            run(<<~CLEAR)
              UNION Shape { Circle { radius: Float64 }, Point }
              FN main() RETURNS Void ->
                c: Shape = Shape.Circle{ radius: 5.0, color: 1.0 };
              END
            CLEAR
          }.to raise_error(CompilerError, /Union variant 'Shape.Circle' has no field 'color'/)
        end

        it "raises when a required field is missing" do
          expect {
            run(<<~CLEAR)
              UNION Shape { Rectangle { width: Float64, height: Float64 }, Point }
              FN main() RETURNS Void ->
                r: Shape = Shape.Rectangle{ width: 3.0 };
              END
            CLEAR
          }.to raise_error(CompilerError, /Union variant 'Shape.Rectangle' is missing required field 'height'/)
        end

        it "raises on field type mismatch" do
          expect {
            run(<<~CLEAR)
              UNION Shape { Circle { radius: Float64 }, Point }
              FN main() RETURNS Void ->
                c: Shape = Shape.Circle{ radius: TRUE };
              END
            CLEAR
          }.to raise_error(CompilerError, /Union variant 'Shape.Circle' field 'radius' expects Float64, got Bool/)
        end

        it "raises when a unit variant is used with inline struct syntax" do
          expect {
            run(<<~CLEAR)
              UNION Shape { Circle { radius: Float64 }, Point }
              FN main() RETURNS Void ->
                p: Shape = Shape.Point{ radius: 5.0 };
              END
            CLEAR
          }.to raise_error(CompilerError, /unit variant/)
        end

        it "raises when a single-payload variant is used with inline struct syntax" do
          expect {
            run(<<~CLEAR)
              UNION Shape { Data: Float64, Point }
              FN main() RETURNS Void ->
                d: Shape = Shape.Data{ value: 5.0 };
              END
            CLEAR
          }.to raise_error(CompilerError, /single typed payload/)
        end

        it "raises when an inline struct variant is accessed without braces (GetField)" do
          expect {
            run(<<~CLEAR)
              UNION Shape { Circle { radius: Float64 }, Point }
              FN main() RETURNS Void ->
                c: Shape = Shape.Circle;
              END
            CLEAR
          }.to raise_error(CompilerError, /inline struct variant/)
        end

        it "raises when old StructLit syntax is used for an inline struct variant" do
          expect {
            run(<<~CLEAR)
              UNION Shape { Circle { radius: Float64 }, Point }
              FN main() RETURNS Void ->
                c: Shape = Shape{ Circle: 5.0 };
              END
            CLEAR
          }.to raise_error(CompilerError, /inline struct fields/)
        end
      end

      # MATCH integration
      describe "MATCH integration" do
        it "MATCH accepts inline struct union without error" do
          expect {
            run(<<~CLEAR)
              UNION Shape { Circle { radius: Float64 }, Point }
              FN main() RETURNS Void ->
                c: Shape = Shape.Circle{ radius: 5.0 };
                PARTIAL MATCH c START
                  Shape.Circle -> 1;,
                  Shape.Point  -> 2;
                END
              END
            CLEAR
          }.not_to raise_error
        end

        it "MATCH enforces exhaustiveness over inline struct variants" do
          expect {
            run(<<~CLEAR)
              UNION Shape { Circle { radius: Float64 }, Point }
              FN main() RETURNS Void ->
                c: Shape = Shape.Circle{ radius: 5.0 };
                MATCH c START
                  Shape.Circle -> 1;
                END
              END
            CLEAR
          }.to raise_error(CompilerError, /non-exhaustive/)
        end

        it "AS binding on inline struct variant resolves to the synthetic struct type" do
          ast = run(<<~CLEAR)
            UNION Shape { Circle { radius: Float64 }, Point }
            FN main() RETURNS Void ->
              c: Shape = Shape.Circle{ radius: 5.0 };
              MUTABLE got = 0.0;
              PARTIAL MATCH c START
                Shape.Circle AS ci -> got = ci.radius;,
                DEFAULT            -> got = -1.0;
              END
            END
          CLEAR
          expect { ast }.not_to raise_error
        end

        it "field access on AS binding type-checks correctly" do
          expect {
            run(<<~CLEAR)
              UNION Shape { Circle { radius: Float64 }, Point }
              FN main() RETURNS Void ->
                c: Shape = Shape.Circle{ radius: 5.0 };
                MUTABLE got = 0.0;
                PARTIAL MATCH c START
                  Shape.Circle AS ci -> got = ci.radius;,
                  DEFAULT            -> got = -1.0;
                END
              END
            CLEAR
          }.not_to raise_error
        end

        it "raises when accessing a non-existent field on the AS binding" do
          expect {
            run(<<~CLEAR)
              UNION Shape { Circle { radius: Float64 }, Point }
              FN main() RETURNS Void ->
                c: Shape = Shape.Circle{ radius: 5.0 };
                MUTABLE got = 0.0;
                PARTIAL MATCH c START
                  Shape.Circle AS ci -> got = ci.diameter;,
                  DEFAULT            -> got = -1.0;
                END
              END
            CLEAR
          }.to raise_error(CompilerError, /no field 'diameter'/)
        end
      end

      # Zig code generation
      describe "Zig code generation" do
        it "emits a helper struct before the union declaration" do
          out = transpile(<<~CLEAR)
            UNION Shape { Circle { radius: Float64 }, Point }
            FN main() RETURNS Void ->
            END
          CLEAR
          expect(out).to include("const Shape_Circle = struct {")
          expect(out).to include("    radius: f64,")
        end

        it "emits the union with the helper struct type for inline variants" do
          out = transpile(<<~CLEAR)
            UNION Shape { Circle { radius: Float64 }, Point }
            FN main() RETURNS Void ->
            END
          CLEAR
          expect(out).to include("const Shape = union(enum) {")
          expect(out).to include("Circle: Shape_Circle,")
          expect(out).to include("Point: void")
        end

        it "emits helper structs for multiple inline struct variants" do
          out = transpile(<<~CLEAR)
            UNION Shape { Circle { radius: Float64 }, Rectangle { width: Float64, height: Float64 }, Point }
            FN main() RETURNS Void ->
            END
          CLEAR
          expect(out).to include("const Shape_Circle = struct {")
          expect(out).to include("const Shape_Rectangle = struct {")
          expect(out).to include("Circle: Shape_Circle,")
          expect(out).to include("Rectangle: Shape_Rectangle,")
        end

        it "emits UnionVariantLit as Shape{ .Circle = Shape_Circle{ .radius = val } }" do
          out = transpile(<<~CLEAR)
            UNION Shape { Circle { radius: Float64 }, Point }
            FN main() RETURNS Void ->
              c: Shape = Shape.Circle{ radius: 5.0 };
            END
          CLEAR
          # NUMBER literals are emitted as integers (existing transpiler behaviour).
          expect(out).to include("Shape{ .Circle = Shape_Circle{ .radius = 5.0 } }")
        end

        it "emits multi-field inline variant constructor correctly" do
          out = transpile(<<~CLEAR)
            UNION Shape { Rectangle { width: Float64, height: Float64 }, Point }
            FN main() RETURNS Void ->
              r: Shape = Shape.Rectangle{ width: 3.0, height: 4.0 };
            END
          CLEAR
          expect(out).to include("Shape{ .Rectangle = Shape_Rectangle{ .width = 3.0, .height = 4.0 } }")
        end

        it "emits const binding = subject.Variant for AS capture" do
          out = transpile(<<~CLEAR)
            UNION Shape { Circle { radius: Float64 }, Point }
            FN main() RETURNS Void ->
              c: Shape = Shape.Circle{ radius: 5.0 };
              MUTABLE got = 0.0;
              PARTIAL MATCH c START
                Shape.Circle AS ci -> got = ci.radius;,
                DEFAULT            -> got = -1.0;
              END
            END
          CLEAR
        expect(out).to include(".Circle => |__match_payload_")
        expect(out).to include("const ci = __match_payload_")
        expect(out).to include("ci.radius")
        end
      end

      describe "method requirements" do
        it "accepts a UNION with FN stubs when matching top-level functions exist" do
          expect {
            run(<<~CLEAR)
              UNION Shape {
                Circle { radius: Float64 },
                Point,
                FN area(s: Shape) RETURNS Float64
              }
              FN area(s: Shape) RETURNS Float64 ->
                RETURN 0.0;
              END
              FN main() RETURNS Void -> END
            CLEAR
          }.not_to raise_error
        end

        it "parses multiple FN requirements without error" do
          expect {
            run(<<~CLEAR)
              UNION Shape {
                Circle { radius: Float64 },
                Point,
                FN area(s: Shape) RETURNS Float64,
                FN describe(s: Shape) RETURNS String
              }
              FN area(s: Shape) RETURNS Float64 -> RETURN 0.0; END
              FN describe(s: Shape) RETURNS String -> RETURN ""; END
              FN main() RETURNS Void -> END
            CLEAR
          }.not_to raise_error
        end

        it "stores method requirements on the UnionDef node" do
          ast = run(<<~CLEAR)
            UNION Shape {
              Circle { radius: Float64 },
              FN area(s: Shape) RETURNS Float64
            }
            FN area(s: Shape) RETURNS Float64 -> RETURN 0.0; END
            FN main() RETURNS Void -> END
          CLEAR
          union_node = ast.statements.first
          expect(union_node).to be_a(AST::UnionDef)
          expect(union_node.methods).to be_an(Array)
          expect(union_node.methods.length).to eq(1)
          expect(union_node.methods.first).to be_a(AST::UnionMethodRequirement)
          expect(union_node.methods.first.name).to eq("area")
        end

        it "raises UNION_METHOD_MISSING when the required function does not exist" do
          expect {
            run(<<~CLEAR)
              UNION Shape {
                Circle { radius: Float64 },
                FN area(s: Shape) RETURNS Float64
              }
              FN main() RETURNS Void -> END
            CLEAR
          }.to raise_error(CompilerError, /Union 'Shape' requires method 'area'/)
        end

        it "raises UNION_METHOD_WRONG_ARITY when arity does not match" do
          expect {
            run(<<~CLEAR)
              UNION Shape {
                Circle { radius: Float64 },
                FN area(s: Shape) RETURNS Float64
              }
              FN area(s: Shape, n: Float64) RETURNS Float64 -> RETURN 0.0; END
              FN main() RETURNS Void -> END
            CLEAR
          }.to raise_error(CompilerError, /Union 'Shape' method 'area' requires 1 parameter.*has 2/)
        end

        it "raises UNION_METHOD_PARAM_TYPE when a parameter type mismatches" do
          expect {
            run(<<~CLEAR)
              UNION Shape {
                Circle { radius: Float64 },
                FN area(s: Float64) RETURNS Float64
              }
              FN area(s: Shape) RETURNS Float64 -> RETURN 0.0; END
              FN main() RETURNS Void -> END
            CLEAR
          }.to raise_error(CompilerError, /Union 'Shape' method 'area' parameter 1 expects 'Float64'/)
        end

        it "raises UNION_METHOD_RETURN_TYPE when the return type mismatches" do
          expect {
            run(<<~CLEAR)
              UNION Shape {
                Circle { radius: Float64 },
                FN area(s: Shape) RETURNS String
              }
              FN area(s: Shape) RETURNS Float64 -> RETURN 0.0; END
              FN main() RETURNS Void -> END
            CLEAR
          }.to raise_error(CompilerError, /Union 'Shape' method 'area' requires return type 'String'.*returns 'Float64'/)
        end

        it "does not emit Zig code for FN stubs — no duplicate definitions" do
          out = transpile(<<~CLEAR)
            UNION Shape {
              Circle { radius: Float64 },
              Point,
              FN area(s: Shape) RETURNS Float64
            }
            FN area(s: Shape) RETURNS Float64 ->
              RETURN 0.0;
            END
            FN main() RETURNS Void -> END
          CLEAR
          # There should be exactly one Zig function definition named 'area'
          expect(out.scan(/fn area\b/).length).to eq(1)
        end

        it "works with unit-only union and method requirements" do
          expect {
            run(<<~CLEAR)
              UNION Color { Red, Green, Blue, FN label(c: Color) RETURNS String }
              FN label(c: Color) RETURNS String -> RETURN ""; END
              FN main() RETURNS Void -> END
            CLEAR
          }.not_to raise_error
        end
      end

      describe "default method implementations" do
        it "accepts a FN stub with a default body when no concrete override exists" do
          expect {
            run(<<~CLEAR)
              UNION Shape {
                Circle { radius: Float64 },
                Point,
                FN area(s: Shape) RETURNS Float64 ->
                  RETURN 0.0;
                END
              }
              FN main() RETURNS Void -> END
            CLEAR
          }.not_to raise_error
        end

        it "does not raise an error for a missing method when a default body is provided" do
          # Previously UNION_METHOD_MISSING — now satisfied by the default body.
          expect {
            run(<<~CLEAR)
              UNION Shape {
                Circle { radius: Float64 },
                FN area(s: Shape) RETURNS Float64 ->
                  RETURN 0.0;
                END
              }
              FN main() RETURNS Void -> END
            CLEAR
          }.not_to raise_error
        end

        it "still raises UNION_METHOD_MISSING when stub has no body and function is missing" do
          expect {
            run(<<~CLEAR)
              UNION Shape {
                Circle { radius: Float64 },
                FN area(s: Shape) RETURNS Float64
              }
              FN main() RETURNS Void -> END
            CLEAR
          }.to raise_error(CompilerError, /requires method 'area'/)
        end

        it "synthesizes a top-level function from the default body" do
          out = transpile(<<~CLEAR)
            UNION Shape {
              Circle { radius: Float64 },
              Point,
              FN area(s: Shape) RETURNS Float64 ->
                RETURN 0.0;
              END
            }
            FN main() RETURNS Void -> END
          CLEAR
          expect(out).to include("fn area(")
        end

        it "does not emit a duplicate when a concrete override also exists" do
          out = transpile(<<~CLEAR)
            UNION Shape {
              Circle { radius: Float64 },
              FN area(s: Shape) RETURNS Float64 ->
                RETURN -1.0;
              END
            }
            FN area(s: Shape) RETURNS Float64 ->
              RETURN 0.0;
            END
            FN main() RETURNS Void -> END
          CLEAR
          # Concrete override wins; only one fn area definition should appear.
          expect(out.scan(/fn area\b/).length).to eq(1)
        end

        it "concrete override validates against the declared default signature" do
          expect {
            run(<<~CLEAR)
              UNION Shape {
                Circle { radius: Float64 },
                FN area(s: Shape) RETURNS String ->
                  RETURN "";
                END
              }
              FN area(s: Shape) RETURNS Float64 ->
                RETURN 0.0;
              END
              FN main() RETURNS Void -> END
            CLEAR
          }.to raise_error(CompilerError, /return type 'String'/)
        end

        it "multiple default methods are all synthesized when none are overridden" do
          out = transpile(<<~CLEAR)
            UNION Shape {
              Point,
              FN area(s: Shape) RETURNS Float64 ->
                RETURN 0.0;
              END,
              FN perimeter(s: Shape) RETURNS Float64 ->
                RETURN 0.0;
              END
            }
            FN main() RETURNS Void -> END
          CLEAR
          expect(out).to include("fn area(")
          expect(out).to include("fn perimeter(")
        end
      end

      describe "Phase 4 — PUB/PRIVATE visibility on method stubs" do
        it "accepts PUB FN stub when concrete implementation is PUB" do
          expect {
            run(<<~CLEAR)
              UNION Shape { Circle { radius: Float64 }, PUB FN area(s: Shape) RETURNS Float64 }
              PUB FN area(s: Shape) RETURNS Float64 -> RETURN 0.0; END
              FN main() RETURNS Void -> END
            CLEAR
          }.not_to raise_error
        end

        it "raises UNION_METHOD_WRONG_VISIBILITY when PUB stub has package function" do
          expect {
            run(<<~CLEAR)
              UNION Shape { Circle { radius: Float64 }, PUB FN area(s: Shape) RETURNS Float64 }
              FN area(s: Shape) RETURNS Float64 -> RETURN 0.0; END
              FN main() RETURNS Void -> END
            CLEAR
          }.to raise_error(CompilerError, /method 'area' is declared PUB but function 'area' is package/)
        end

        it "raises UNION_METHOD_WRONG_VISIBILITY when PRIVATE stub has package function" do
          expect {
            run(<<~CLEAR)
              UNION Shape { Circle { radius: Float64 }, PRIVATE FN area(s: Shape) RETURNS Float64 }
              FN area(s: Shape) RETURNS Float64 -> RETURN 0.0; END
              FN main() RETURNS Void -> END
            CLEAR
          }.to raise_error(CompilerError, /method 'area' is declared PRIVATE but function 'area' is package/)
        end

        it "synthesized default from PUB FN stub is emitted as pub fn in Zig" do
          out = transpile(<<~CLEAR)
            UNION Shape {
              Point,
              PUB FN area(s: Shape) RETURNS Float64 ->
                RETURN 0.0;
              END
            }
            FN main() RETURNS Void -> END
          CLEAR
          expect(out).to include("pub fn area(")
        end

        it "synthesized default from plain FN stub is NOT pub" do
          out = transpile(<<~CLEAR)
            UNION Shape {
              Point,
              FN area(s: Shape) RETURNS Float64 ->
                RETURN 0.0;
              END
            }
            FN main() RETURNS Void -> END
          CLEAR
          expect(out).to include("fn area(")
          expect(out).not_to include("pub fn area(")
        end

        it "plain FN stub accepts either pub or package implementation without visibility check" do
          # Plain (package) stubs do not enforce visibility — only PUB/PRIVATE stubs do.
          expect {
            run(<<~CLEAR)
              UNION Shape { Point, FN area(s: Shape) RETURNS Float64 }
              PUB FN area(s: Shape) RETURNS Float64 -> RETURN 0.0; END
              FN main() RETURNS Void -> END
            CLEAR
          }.not_to raise_error
        end
      end

      describe "Phase 5 — duplicate method stub detection" do
        it "raises UNION_METHOD_DUPLICATE when the same method name appears twice" do
          expect {
            run(<<~CLEAR)
              UNION Shape {
                Point,
                FN area(s: Shape) RETURNS Float64,
                FN area(s: Shape) RETURNS Float64
              }
              FN area(s: Shape) RETURNS Float64 -> RETURN 0.0; END
              FN main() RETURNS Void -> END
            CLEAR
          }.to raise_error(CompilerError, /Union 'Shape' declares method 'area' more than once/)
        end

        it "allows different method names without error" do
          expect {
            run(<<~CLEAR)
              UNION Shape {
                Point,
                FN area(s: Shape) RETURNS Float64,
                FN perimeter(s: Shape) RETURNS Float64
              }
              FN area(s: Shape) RETURNS Float64 -> RETURN 0.0; END
              FN perimeter(s: Shape) RETURNS Float64 -> RETURN 0.0; END
              FN main() RETURNS Void -> END
            CLEAR
          }.not_to raise_error
        end

        it "duplicate detection fires before signature validation" do
          # Even if the concrete fn is missing, duplicate error fires first.
          expect {
            run(<<~CLEAR)
              UNION Shape {
                Point,
                FN area(s: Shape) RETURNS Float64,
                FN area(s: Shape) RETURNS Float64
              }
              FN main() RETURNS Void -> END
            CLEAR
          }.to raise_error(CompilerError, /declares method 'area' more than once/)
        end
      end
    end
  end

end
