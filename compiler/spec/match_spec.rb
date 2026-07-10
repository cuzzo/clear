require "rspec"
require "byebug"
require "tmpdir"
require "fileutils"

require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../ruby/ast/ast" unless defined?(MIR::ReassignPlan)

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

  describe "MATCH statement" do
    context "basic integer match with default" do
      let(:code) {
        <<~FLUX
          MUTABLE x = 2;
          PARTIAL MATCH x START
            1 -> x = 10;,
            2 -> x = 20;,
            DEFAULT -> x = 99;
          END
        FLUX
      }

      it "resolves to Void" do
        expect { ast }.not_to raise_error
        expect(ast.statements.last.resolved_type).to eq(:Void)
      end
    end

    context "match with no default" do
      let(:code) {
        <<~FLUX
          MUTABLE x = 0;
          PARTIAL MATCH x START
            1 -> x = 1;,
            2 -> x = 2;
          END
        FLUX
      }

      it "succeeds without a default case" do
        expect { ast }.not_to raise_error
      end
    end

    context "optional symbol-string value match" do
      let(:code) {
        <<~FLUX
          FN pick(v: ?String@symbol) RETURNS ?String@symbol ->
            RETURN PARTIAL MATCH v START
              :heap -> :heap,
              :frame -> :frame,
              DEFAULT -> NIL
            END;
          END
        FLUX
      }

      it "matches non-nil symbol cases against the wrapped type" do
        expect { ast }.not_to raise_error
      end
    end

    context "case type mismatch" do
      let(:code) {
        <<~FLUX
          MUTABLE x = 42;
          PARTIAL MATCH x START
            "hello" -> x = 0;
          END
        FLUX
      }

      it "raises an error when case type differs from expression type" do
        expect { ast }.to raise_error(/MATCH case type/)
      end
    end

    context "WHEN conditional arm" do
      let(:code) {
        <<~FLUX
          MUTABLE x = 7;
          PARTIAL MATCH x START
            1 -> x = 1;,
            WHEN x MOD 2 == 0 -> x = 0;,
            DEFAULT -> x = 99;
          END
        FLUX
      }

      it "resolves to Void without errors" do
        expect { ast }.not_to raise_error
        expect(ast.statements.last.resolved_type).to eq(:Void)
      end
    end

    context "WHEN arm with non-Bool condition" do
      let(:code) {
        <<~FLUX
          MUTABLE x = 7;
          PARTIAL MATCH x START
            WHEN x + 1 -> x = 0;
          END
        FLUX
      }

      it "raises an error" do
        expect { ast }.to raise_error(/WHEN condition must be Bool/)
      end
    end

    # ── PASS statement ──────────────────────────────────────────────────────────

    context "PASS as case body (with semicolon)" do
      let(:code) {
        <<~FLUX
          MUTABLE x = 1;
          PARTIAL MATCH x START
            1 -> PASS;,
            DEFAULT -> x = 99;
          END
        FLUX
      }

      it "resolves to Void without errors" do
        expect { ast }.not_to raise_error
        expect(ast.statements.last.resolved_type).to eq(:Void)
      end
    end

    context "PASS as case body (without semicolon)" do
      let(:code) {
        <<~FLUX
          MUTABLE x = 1;
          PARTIAL MATCH x START
            1 -> PASS,
            DEFAULT -> x = 99;
          END
        FLUX
      }

      it "resolves to Void without errors" do
        expect { ast }.not_to raise_error
      end
    end

    # ── Struct destructuring ─────────────────────────────────────────────────────

    context "partial match with ..." do
      let(:code) {
        <<~FLUX
          STRUCT Point { x: Float64, y: Float64 }
          p = Point{ x: 10.0, y: 5.0 };
          MUTABLE result = 0;
          PARTIAL MATCH p START
            {x: 10.0, ...} -> result = 1;,
            {x: 20.0, ...} -> result = 2;,
            DEFAULT -> result = 3;
          END
        FLUX
      }

      it "resolves to Void without errors" do
        expect { ast }.not_to raise_error
        expect(ast.statements.last.resolved_type).to eq(:Void)
      end
    end

    context "wildcard field with _" do
      let(:code) {
        <<~FLUX
          STRUCT Point { x: Float64, y: Float64, z: Float64 }
          p = Point{ x: 1.0, y: 99.0, z: 3.0 };
          MUTABLE result = 0;
          PARTIAL MATCH p START
            {x: 1.0, y: _, z: 3.0} -> result = 42;,
            DEFAULT -> result = 0;
          END
        FLUX
      }

      it "resolves to Void without errors" do
        expect { ast }.not_to raise_error
        expect(ast.statements.last.resolved_type).to eq(:Void)
      end
    end

    context "mixed eq and struct pattern arms" do
      let(:code) {
        <<~FLUX
          STRUCT Msg { code: Float64 }
          MUTABLE x = 0;
          m = Msg{ code: 5.0 };
          PARTIAL MATCH m START
            {code: 5.0, ...} -> x = 1;,
            {code: 10.0, ...} -> x = 2;,
            DEFAULT -> x = 3;
          END
        FLUX
      }

      it "succeeds" do
        expect { ast }.not_to raise_error
      end
    end

    context "struct pattern against a primitive type" do
      let(:code) {
        <<~FLUX
          x = 42;
          PARTIAL MATCH x START
            {value: 42, ...} -> PASS;
          END
        FLUX
      }

      it "raises an error" do
        expect { ast }.to raise_error(/MATCH struct pattern requires a struct type/)
      end
    end

    context "struct pattern field not on struct" do
      let(:code) {
        <<~FLUX
          STRUCT Point { x: Float64, y: Float64 }
          p = Point{ x: 1, y: 2 };
          MUTABLE result = 0;
          PARTIAL MATCH p START
            {z: 99, ...} -> result = 1;
          END
        FLUX
      }

      it "raises an error for unknown field" do
        expect { ast }.to raise_error(/MATCH struct pattern: field 'z' does not exist on type Point/)
      end
    end

    context "struct pattern field type mismatch" do
      let(:code) {
        <<~FLUX
          STRUCT Point { x: Float64, y: Float64 }
          p = Point{ x: 1, y: 2 };
          MUTABLE result = 0;
          PARTIAL MATCH p START
            {x: "hello", ...} -> result = 1;
          END
        FLUX
      }

      it "raises an error for wrong field value type" do
        expect { ast }.to raise_error(/MATCH struct pattern: field 'x' has type Float64, but pattern value has type/)
      end
    end

    # --------------------------------------------------
    # Regular MATCH: no exhaustiveness enforced
    # --------------------------------------------------
    context "regular MATCH has no exhaustiveness requirement" do
      it "accepts a partial enum MATCH with no DEFAULT" do
        expect {
          run(<<~CLEAR)
            ENUM Dir { North, South, East, West }
            FN main() RETURNS Void ->
              d: Dir = Dir.North;
              MUTABLE n = 0_i64;
              PARTIAL MATCH d START
                Dir.North -> n = 1_i64;,
                Dir.South -> n = 2_i64;
              END
            END
          CLEAR
        }.not_to raise_error
      end

      it "accepts a partial union MATCH with no DEFAULT" do
        expect {
          run(<<~CLEAR)
            UNION Result { Ok: Float64, Err: Float64, Empty }
            FN main() RETURNS Void ->
              r: Result = Result{ Ok: 1 };
              MUTABLE n = 0_i64;
              PARTIAL MATCH r START
                Result.Ok -> n = 1_i64;
              END
            END
          CLEAR
        }.not_to raise_error
      end

      it "accepts a partial enum MATCH with DEFAULT" do
        expect {
          run(<<~CLEAR)
            ENUM Color { Red, Green, Blue }
            FN main() RETURNS Void ->
              c: Color = Color.Red;
              MUTABLE n = 0_i64;
              PARTIAL MATCH c START
                Color.Red -> n = 1_i64;,
                DEFAULT   -> n = 99_i64;
              END
            END
          CLEAR
        }.not_to raise_error
      end

      it "accepts a MATCH with a WHEN guard and missing enum variants" do
        expect {
          run(<<~CLEAR)
            ENUM Bit { Zero, One }
            FN main() RETURNS Void ->
              b: Bit = Bit.Zero;
              MUTABLE n = 0_i64;
              PARTIAL MATCH b START
                Bit.Zero -> n = 0_i64;,
                WHEN n == 0 -> n = 99_i64;
              END
            END
          CLEAR
        }.not_to raise_error
      end
    end

    # --------------------------------------------------
    # MATCH: exhaustiveness enforced
    # --------------------------------------------------
    context "MATCH enum exhaustiveness" do
      it "accepts a fully exhaustive MATCH on an enum" do
        expect {
          run(<<~CLEAR)
            ENUM Dir { North, South, East, West }
            FN main() RETURNS Void ->
              d: Dir = Dir.North;
              MUTABLE n = 0_i64;
              MATCH d START
                Dir.North -> n = 1_i64;,
                Dir.South -> n = 2_i64;,
                Dir.East  -> n = 3_i64;,
                Dir.West  -> n = 4_i64;
              END
            END
          CLEAR
        }.not_to raise_error
      end

      it "raises an error when MATCH on enum is non-exhaustive" do
        expect {
          run(<<~CLEAR)
            ENUM Dir { North, South, East, West }
            FN main() RETURNS Void ->
              d: Dir = Dir.North;
              MUTABLE n = 0_i64;
              MATCH d START
                Dir.North -> n = 1_i64;,
                Dir.South -> n = 2_i64;
              END
            END
          CLEAR
        }.to raise_error(CompilerError, /MATCH on enum 'Dir' is non-exhaustive: missing variants: East, West/)
      end

      it "raises an error when MATCH has a DEFAULT branch" do
        expect {
          run(<<~CLEAR)
            ENUM Color { Red, Green, Blue }
            FN main() RETURNS Void ->
              c: Color = Color.Red;
              MUTABLE n = 0_i64;
              MATCH c START
                Color.Red   -> n = 1_i64;,
                Color.Green -> n = 2_i64;,
                Color.Blue  -> n = 3_i64;,
                DEFAULT     -> n = 99_i64;
              END
            END
          CLEAR
        }.to raise_error(CompilerError, /MATCH cannot have a DEFAULT branch/)
      end

      it "raises an error when MATCH contains a WHEN guard" do
        expect {
          run(<<~CLEAR)
            ENUM Bit { Zero, One }
            FN main() RETURNS Void ->
              b: Bit = Bit.Zero;
              MUTABLE n = 0_i64;
              MATCH b START
                Bit.Zero    -> n = 0_i64;,
                WHEN n == 0 -> n = 99_i64;
              END
            END
          CLEAR
        }.to raise_error(CompilerError, /MATCH cannot contain WHEN guards/)
      end

      it "raises an error when MATCH subject is not an enum or union" do
        expect {
          run(<<~CLEAR)
            FN main() RETURNS Void ->
              x = 42_i64;
              MUTABLE n = 0_i64;
              MATCH x START
                1_i64 -> n = 1_i64;,
                2_i64 -> n = 2_i64;
              END
            END
          CLEAR
        }.to raise_error(CompilerError, /MATCH requires an enum or union type/)
      end
    end

    context "MATCH union exhaustiveness" do
      it "accepts a fully exhaustive MATCH on a union" do
        expect {
          run(<<~CLEAR)
            UNION Shape { Circle: Float64, Point }
            FN main() RETURNS Void ->
              s: Shape = Shape.Point;
              MUTABLE n = 0_i64;
              MATCH s START
                Shape.Circle -> n = 1_i64;,
                Shape.Point  -> n = 2_i64;
              END
            END
          CLEAR
        }.not_to raise_error
      end

      it "raises an error when MATCH on union is non-exhaustive" do
        expect {
          run(<<~CLEAR)
            UNION Result { Ok: Float64, Err: Float64, Empty }
            FN main() RETURNS Void ->
              r: Result = Result{ Ok: 1 };
              MUTABLE n = 0_i64;
              MATCH r START
                Result.Ok -> n = 1_i64;
              END
            END
          CLEAR
        }.to raise_error(CompilerError, /MATCH on union 'Result' is non-exhaustive: missing variants: Empty, Err/)
      end

      it "accepts a PARTIAL MATCH on a union with DEFAULT" do
        expect {
          run(<<~CLEAR)
            UNION Result { Ok: Float64, Err: Float64 }
            FN main() RETURNS Void ->
              r: Result = Result{ Ok: 1 };
              MUTABLE n = 0_i64;
              PARTIAL MATCH r START
                Result.Ok -> n = 1_i64;,
                DEFAULT   -> n = 99_i64;
              END
            END
          CLEAR
        }.not_to raise_error
      end

      it "accepts exhaustive MATCH on a generic union" do
        expect {
          run(<<~CLEAR)
            UNION Option<T> { Some: T, None }
            FN main() RETURNS Void ->
              opt = Option<Float64>{ Some: 1.0 };
              MUTABLE n = 0.0;
              MATCH opt START
                Option.Some -> n = 1.0;,
                Option.None -> n = 2.0;
              END
            END
          CLEAR
        }.not_to raise_error
      end

      it "raises an error for non-exhaustive MATCH on generic union" do
        expect {
          run(<<~CLEAR)
            UNION Option<T> { Some: T, None }
            FN main() RETURNS Void ->
              opt = Option<Float64>{ Some: 1.0 };
              MUTABLE n = 0.0;
              MATCH opt START
                Option.Some -> n = 1.0;
              END
            END
          CLEAR
        }.to raise_error(CompilerError, /MATCH on union 'Option' is non-exhaustive: missing variants: None/)
      end
    end

    # --------------------------------------------------
    # Union payload capture (AS binding)
    # --------------------------------------------------
    context "union payload capture (AS binding)" do
      it "accepts payload capture from a payload variant" do
        expect {
          run(<<~CLEAR)
            UNION Shape { Circle: Float64, Point }
            FN main() RETURNS Void ->
              s: Shape = Shape{ Circle: 5.0 };
              MUTABLE a = 0.0;
              PARTIAL MATCH s START
                Shape.Circle AS r -> a = r;,
                Shape.Point       -> a = 0.0;
              END
            END
          CLEAR
        }.not_to raise_error
      end

      it "resolves the captured binding to the variant's payload type" do
        ast = run(<<~CLEAR)
          UNION Result { Ok: Float64, Err: Float64, Empty }
          FN main() RETURNS Void ->
            r: Result = Result{ Ok: 42.0 };
            MUTABLE got = 0.0;
            PARTIAL MATCH r START
              Result.Ok    AS v -> got = v;,
              Result.Err   AS e -> got = e;,
              Result.Empty      -> got = 0.0;
            END
          END
        CLEAR
        # The body of the first case contains `got = v`.
        # If the annotator didn't declare `v` with the right type, it would error.
        expect(ast).not_to be_nil
      end

      it "raises an error when capturing from a unit variant" do
        expect {
          run(<<~CLEAR)
            UNION Maybe { Some: Float64, None }
            FN main() RETURNS Void ->
              m: Maybe = Maybe.None;
              MUTABLE n = 0.0;
              PARTIAL MATCH m START
                Maybe.Some AS x -> n = x;,
                Maybe.None AS y -> n = 0.0;
              END
            END
          CLEAR
        }.to raise_error(CompilerError, /Cannot bind 'AS y': 'None' is a unit variant with no payload/)
      end

      it "raises an error when using AS on an enum variant" do
        expect {
          run(<<~CLEAR)
            ENUM Dir { North, South }
            FN main() RETURNS Void ->
              d: Dir = Dir.North;
              MUTABLE n = 0_i64;
              PARTIAL MATCH d START
                Dir.North AS x -> n = 1_i64;,
                Dir.South      -> n = 2_i64;
              END
            END
          CLEAR
        }.to raise_error(CompilerError, /Cannot capture payload from enum variant: enums have no payload/)
      end

      it "correctly resolves generic union payload type through AS binding" do
        expect {
          run(<<~CLEAR)
            UNION Option<T> { Some: T, None }
            FN main() RETURNS Void ->
              opt = Option<Float64>{ Some: 3.14 };
              MUTABLE got = 0.0;
              PARTIAL MATCH opt START
                Option.Some AS x -> got = x;,
                Option.None      -> got = -1.0;
              END
            END
          CLEAR
        }.not_to raise_error
      end

      it "raises a type mismatch when using the captured binding with a wrong type" do
        expect {
          run(<<~CLEAR)
            UNION Result { Ok: Float64, Err: Float64 }
            FN need_str(s: String) RETURNS Void ->
            END
            FN main() RETURNS Void ->
              r: Result = Result{ Ok: 1.0 };
              MUTABLE n = 0.0;
              PARTIAL MATCH r START
                Result.Ok  AS v -> need_str(v);,
                Result.Err AS e -> n = e;
              END
            END
          CLEAR
        }.to raise_error(CompilerError, /Type Error/)
      end
    end

    # --------------------------------------------------
    # Zig code generation for AS capture and MATCH
    # --------------------------------------------------
    context "Zig code generation" do
      def transpile(src)
        ZigTranspiler.new.transpile(src)
      end

      it "emits 'const r = subject.Circle;' for payload capture" do
        out = transpile(<<~CLEAR)
          UNION Shape { Circle: Float64, Point }
          FN main() RETURNS Void ->
            s: Shape = Shape{ Circle: 2.0 };
            MUTABLE a = 0.0;
            PARTIAL MATCH s START
              Shape.Circle AS r -> a = r;,
              Shape.Point       -> a = 0.0;
            END
          END
        CLEAR
        expect(out).to include("switch (s)")
        expect(out).to include(".Circle => |__match_payload_")
        expect(out).to include("const r = __match_payload_")
      end

      it "emits == comparison (not activeTag) for enum MATCH" do
        out = transpile(<<~CLEAR)
          ENUM Dir { North, South }
          FN main() RETURNS Void ->
            d: Dir = Dir.North;
            MUTABLE n = 0_i64;
            PARTIAL MATCH d START
              Dir.North -> n = 1_i64;,
              Dir.South -> n = 2_i64;
            END
          END
        CLEAR
        expect(out).to include("switch (d)")
        expect(out).to include(".North =>")
        expect(out).to include(".South =>")
        expect(out).not_to include("activeTag")
      end

      it "emits payload capture for generic union MATCH" do
        out = transpile(<<~CLEAR)
          UNION Option<T> { Some: T, None }
          FN main() RETURNS Void ->
            opt = Option<Float64>{ Some: 7.0 };
            MUTABLE got = 0.0;
            PARTIAL MATCH opt START
              Option.Some AS x -> got = x;,
              Option.None      -> got = -1.0;
            END
          END
        CLEAR
        expect(out).to include("switch (opt)")
        expect(out).to include(".Some => |__match_payload_")
        expect(out).to include("const x = __match_payload_")
      end

      it "MATCH and MATCH produce identical Zig output for the same exhaustive case" do
        src_iff = <<~CLEAR
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
        src_plain = src_iff.sub("MATCH", "MATCH")
        expect(transpile(src_iff)).to eq(transpile(src_plain))
      end
    end
  end

end
