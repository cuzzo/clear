require "rspec"
require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/ast/ast"
require_relative "../src/backends/transpiler"

# Multi-pattern MATCH arms:
#
#   MATCH x START
#       Op.A, Op.B, Op.C       -> body1
#       Op.D, Op.E AS payload   -> body2
#       Op.F                    -> body3
#   END
#
# AS / { destructure } apply to the whole arm; per-pattern AS is not a
# thing. Single-pattern arms keep their existing AST shape (no
# :extra_values) for back-compat. Multi-arm AS / destructure require
# every variant to share payload shape (post-generic-substitution).
RSpec.describe "MATCH multi-pattern arm" do
  def parse(src)
    tokens = Lexer.new(src).tokenize
    Parser.new(tokens, src).parse
  end

  def annotate(src)
    SemanticAnnotator.new.annotate!(parse(src))
  end

  def find_match(ast)
    found = nil
    walk = lambda do |n|
      return unless n
      if n.is_a?(AST::MatchStatement)
        found = n
        return
      end
      n.each { |v| walk.call(v) if v.is_a?(Struct) || v.is_a?(Array) } if n.is_a?(Struct)
      n.each { |v| walk.call(v) } if n.is_a?(Array)
    end
    ast.statements.each { |s| walk.call(s) }
    found
  end

  # ============================================================================
  # Parser
  # ============================================================================

  describe "parser — statement-position" do
    it "single-pattern arms have no :extra_values key (back-compat)" do
      src = <<~CLEAR
        UNION Op { A, B, C }
        FN main() RETURNS Void ->
          x = Op.A;
          MATCH x START
            Op.A -> RETURN;,
            DEFAULT -> RETURN;
          END
        END
      CLEAR
      m = find_match(parse(src))
      expect(m.cases.size).to eq(1)
      expect(m.cases[0].extra_values).to be_nil
    end

    it "two-pattern arm collects the second pattern under :extra_values" do
      src = <<~CLEAR
        UNION Op { A, B, C }
        FN main() RETURNS Void ->
          x = Op.A;
          MATCH x START
            Op.A, Op.B -> RETURN;,
            DEFAULT -> RETURN;
          END
        END
      CLEAR
      c = find_match(parse(src)).cases[0]
      expect(c[:value]).to be_a(AST::GetField)
      expect(c[:value].field).to eq("A")
      expect(c[:extra_values].size).to eq(1)
      expect(c[:extra_values][0].field).to eq("B")
    end

    it "three-pattern arm collects two under :extra_values, ordered" do
      src = <<~CLEAR
        UNION Op { A, B, C }
        FN main() RETURNS Void ->
          x = Op.A;
          MATCH x START
            Op.A, Op.B, Op.C -> RETURN;,
            DEFAULT -> RETURN;
          END
        END
      CLEAR
      m = find_match(parse(src))
      expect(m.cases[0][:extra_values].map(&:field)).to eq(%w[B C])
    end

    it "AS binds across the whole multi-pattern arm" do
      src = <<~CLEAR
        UNION Op { A, B }
        FN main() RETURNS Void ->
          x = Op.A;
          MATCH x START
            Op.A, Op.B AS p -> RETURN;,
            DEFAULT -> RETURN;
          END
        END
      CLEAR
      c = find_match(parse(src)).cases[0]
      expect(c[:extra_values].map(&:field)).to eq(["B"])
      expect(c[:binding]).to eq("p")
    end

    it "{ destructure } applies after the whole pattern list" do
      src = <<~CLEAR
        UNION R { Ok { x: Int64 }, Err { x: Int64 } }
        FN main() RETURNS Void ->
          r = R.Ok{ x: 1_i64 };
          MATCH r START
            R.Ok, R.Err { x } -> RETURN;,
            DEFAULT -> RETURN;
          END
        END
      CLEAR
      c = find_match(parse(src)).cases[0]
      expect(c[:extra_values].map(&:field)).to eq(["Err"])
      expect(c[:destructure]).to be_a(AST::StructPattern)
    end

    it "multi and single arms can mix in the same MATCH" do
      src = <<~CLEAR
        UNION Op { A, B, C, D }
        FN main() RETURNS Void ->
          x = Op.A;
          MATCH x START
            Op.A, Op.B -> RETURN;,
            Op.C       -> RETURN;,
            Op.D       -> RETURN;
          END
        END
      CLEAR
      m = find_match(parse(src))
      expect(m.cases.size).to eq(3)
      expect(m.cases[0][:extra_values].map(&:field)).to eq(["B"])
      expect(m.cases[1].extra_values).to be_nil
      expect(m.cases[2].extra_values).to be_nil
    end

    it "arm-separator comma after body is still consumed (not as multi-pattern)" do
      # The `,` after `RETURN;` belongs to the arm separator, NOT to a
      # multi-pattern continuation. Op.B should be a NEW arm.
      src = <<~CLEAR
        UNION Op { A, B }
        FN main() RETURNS Void ->
          x = Op.A;
          MATCH x START
            Op.A -> RETURN;,
            Op.B -> RETURN;
          END
        END
      CLEAR
      m = find_match(parse(src))
      expect(m.cases.size).to eq(2)
      m.cases.each { |c| expect(c.extra_values).to be_nil }
    end
  end

  describe "parser — disambiguation: arm-separator vs multi-pattern continuation" do
    # The `,` between arms (after a body) and the `,` between patterns
    # (before `->`) look identical. Disambiguation is positional: we're
    # consuming `,`s only while still parsing patterns of one arm.
    # Tokens that can ONLY start a new arm — DEFAULT, WHEN, END, the
    # struct-pattern `{` — must terminate the multi-pattern loop.

    it "parses `Op.A -> body, WHEN cond -> body` correctly (`,` is arm-separator)" do
      src = <<~CLEAR
        UNION Op { A, B }
        FN main() RETURNS Void ->
          x = Op.A;
          PARTIAL MATCH x START
            Op.A -> RETURN;,
            WHEN TRUE -> RETURN;
          END
        END
      CLEAR
      m = find_match(parse(src))
      expect(m.cases.size).to eq(2)
      expect(m.cases[0].extra_values).to be_nil
      expect(m.cases[1][:kind]).to eq(:when)
    end

    it "parses `Op.A -> body, DEFAULT -> body` correctly (`,` is arm-separator)" do
      src = <<~CLEAR
        UNION Op { A, B }
        FN main() RETURNS Void ->
          x = Op.A;
          PARTIAL MATCH x START
            Op.A -> RETURN;,
            DEFAULT -> RETURN;
          END
        END
      CLEAR
      m = find_match(parse(src))
      expect(m.cases.size).to eq(1)
      expect(m.cases[0].extra_values).to be_nil
      expect(m.default_case).not_to be_nil
    end

    it "rejects `Op.A, WHEN cond -> body` with a clear parser error (mixing variant + WHEN in one arm)" do
      src = <<~CLEAR
        UNION Op { A, B }
        FN main() RETURNS Void ->
          x = Op.A;
          PARTIAL MATCH x START
            Op.A, WHEN TRUE -> RETURN;
          END
        END
      CLEAR
      # The multi-pattern loop must terminate on `WHEN` so the `,` is
      # treated as an arm-separator that's missing the preceding body.
      expect { parse(src) }.to raise_error(/Expected ARROW/)
    end

    it "rejects trailing-comma `Op.A, Op.B, -> body` (the `,` precedes the arrow)" do
      src = <<~CLEAR
        UNION Op { A, B }
        FN main() RETURNS Void ->
          x = Op.A;
          PARTIAL MATCH x START
            Op.A, Op.B, -> RETURN;
          END
        END
      CLEAR
      expect { parse(src) }.to raise_error(/Expected ARROW/)
    end

    it "rejects `Op.A, { x } -> body` (struct-pattern shape can't continue a multi-arm)" do
      src = <<~CLEAR
        UNION Op { A, B { x: Int64 } }
        FN main() RETURNS Void ->
          x = Op.A;
          PARTIAL MATCH x START
            Op.A, { x } -> RETURN;
          END
        END
      CLEAR
      expect { parse(src) }.to raise_error(StandardError)
    end
  end

  describe "parser — expression-position" do
    it "supports multi-pattern arms in expression form" do
      src = <<~CLEAR
        UNION Op { A, B, C }
        FN classify(x: Op) RETURNS Int64 ->
          MUTABLE result: Int64 = 0_i64;
          PARTIAL MATCH x START
            Op.A, Op.B -> result = 1_i64;,
            Op.C       -> result = 2_i64;
          END
          RETURN result;
        END
      CLEAR
      m = find_match(parse(src))
      expect(m.cases.size).to eq(2)
      expect(m.cases[0][:extra_values].map(&:field)).to eq(["B"])
    end

    it "expression-position multi-arm with AS annotates without error" do
      src = <<~CLEAR
        UNION Result { Ok: Int64, Err: Int64 }
        FN unwrap(r: Result) RETURNS Int64 ->
          MUTABLE out: Int64 = 0_i64;
          MATCH r START
            Result.Ok, Result.Err AS n -> out = n;
          END
          RETURN out;
        END
      CLEAR
      expect { annotate(src) }.not_to raise_error
    end
  end

  # ============================================================================
  # Annotator
  # ============================================================================

  describe "annotator — exhaustiveness" do
    it "counts each variant in a multi-pattern arm — fully exhaustive multi-arm passes" do
      expect {
        annotate(<<~CLEAR)
          ENUM Op { Add, Sub, Mul }
          FN c(o: Op) RETURNS Int64 ->
            RETURN MATCH o START
              Op.Add, Op.Sub, Op.Mul -> 1_i64
            END;
          END
        CLEAR
      }.not_to raise_error
    end

    it "still flags missing variants when only some are in the multi-arm" do
      expect {
        annotate(<<~CLEAR)
          ENUM Op { Add, Sub, Mul }
          FN c(o: Op) RETURNS Int64 ->
            RETURN MATCH o START
              Op.Add, Op.Sub -> 1_i64
            END;
          END
        CLEAR
      }.to raise_error(/MATCH .* missing.*Mul/m)
    end
  end

  describe "annotator — AS payload type-compat across multi-arm" do
    it "accepts a multi-arm AS when both variants share the same payload type" do
      expect {
        annotate(<<~CLEAR)
          UNION Result { Ok: Int64, Err: Int64 }
          FN extract(r: Result) RETURNS Int64 ->
            MUTABLE out: Int64 = 0_i64;
            MATCH r START
              Result.Ok, Result.Err AS n -> out = n;
            END
            RETURN out;
          END
        CLEAR
      }.not_to raise_error
    end

    it "rejects a multi-arm AS when variant payload types differ" do
      expect {
        annotate(<<~CLEAR)
          UNION R { Ok: Int64, Err: String }
          FN main() RETURNS Void ->
            r = R{ Ok: 1_i64 };
            MATCH r START
              R.Ok, R.Err AS n -> RETURN;
            END
          END
        CLEAR
      }.to raise_error(/MATCH multi-pattern arm: variants 'Ok' and 'Err' have incompatible payloads.*shared `AS n`/)
    end

    it "accepts a generic-union multi-arm AS where post-substitution payloads coincide" do
      # `Mixed<Int64>` — variant A's payload is T (= Int64 after
      # substitution) and B's is Int64. Pre-substitution comparison
      # would falsely reject; the check applies union_subst first.
      expect {
        annotate(<<~CLEAR)
          UNION Mixed<T> { A: T, B: Int64 }
          FN unwrap(m: Mixed<Int64>) RETURNS Int64 ->
            MUTABLE out: Int64 = 0_i64;
            MATCH m START
              Mixed.A, Mixed.B AS n -> out = n;
            END
            RETURN out;
          END
        CLEAR
      }.not_to raise_error
    end
  end

  describe "annotator — destructure across multi-arm" do
    it "accepts a multi-arm { destructure } when variants share payload shape" do
      expect {
        annotate(<<~CLEAR)
          UNION T {
            Even { n: Int64, w: Int64 },
            Odd  { n: Int64, w: Int64 },
            None
          }
          FN main() RETURNS Void ->
            t = T.None;
            MUTABLE out: Int64 = 0_i64;
            PARTIAL MATCH t START
              T.Even, T.Odd { n } -> out = n;,
              DEFAULT -> out = 0_i64;
            END
          END
        CLEAR
      }.not_to raise_error
    end

    it "rejects a multi-arm { destructure } when variant payload shapes differ" do
      expect {
        annotate(<<~CLEAR)
          UNION T {
            Even { n: Int64 },
            Odd  { m: Int64 },
            None
          }
          FN main() RETURNS Void ->
            t = T.None;
            PARTIAL MATCH t START
              T.Even, T.Odd { n } -> RETURN;,
              DEFAULT -> RETURN;
            END
          END
        CLEAR
      }.to raise_error(/MATCH multi-pattern arm: variants 'Even' and 'Odd' have incompatible payloads.*shared `destructure/)
    end
  end

  describe "annotator — bare multi-arm has no payload constraint" do
    it "lets variants with different payload types share an arm body when no AS / destructure" do
      expect {
        annotate(<<~CLEAR)
          UNION R { Ok: Int64, Err: String, None }
          FN main() RETURNS Void ->
            r = R.None;
            MUTABLE out: Int64 = -1_i64;
            PARTIAL MATCH r START
              R.Ok, R.Err -> out = 1_i64;,
              R.None       -> out = 0_i64;
            END
          END
        CLEAR
      }.not_to raise_error
    end
  end

  describe "annotator — duplicate-pattern detection" do
    it "rejects `Op.A, Op.A -> body` within a single multi-arm" do
      src = <<~CLEAR
        ENUM Op { Add, Sub }
        FN c(o: Op) RETURNS Int64 ->
          RETURN MATCH o START
            Op.Add, Op.Add -> 1_i64,
            Op.Sub          -> 2_i64
          END;
        END
      CLEAR
      expect { annotate(src) }.to raise_error(/duplicate|already covered|matched more than once/i)
    end

    it "rejects duplicate variants ACROSS arms (`Op.A -> ..., Op.A -> ...`)" do
      src = <<~CLEAR
        ENUM Op { Add, Sub }
        FN c(o: Op) RETURNS Int64 ->
          RETURN MATCH o START
            Op.Add -> 1_i64,
            Op.Add -> 2_i64,
            Op.Sub -> 3_i64
          END;
        END
      CLEAR
      expect { annotate(src) }.to raise_error(/duplicate|already covered|matched more than once/i)
    end
  end
end
