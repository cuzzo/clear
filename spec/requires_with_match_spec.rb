require "rspec"
require "set"

require_relative "../src/backends/transpiler"

# P2.8: pin the REQUIRES + WITH MATCH grammar end-to-end.
#
# Coverage:
#   - REQUIRES grammar: single-family, multi-family disjunction, grouped
#     param-list, multiple groups separated by ','.
#   - WITH MATCH grammar: single-family no-MATCH (sugar), multi-family
#     MATCH with WHEN arms, per-arm ON clauses.
#   - Validation rules: P2.4 (exhaustiveness), P2.5 (WITH ⇒ REQUIRES),
#     P2.6 (call-site family), P2.7 (compatibility shim).

RSpec.describe "P2 grammar: REQUIRES + WITH MATCH" do
  def parse(src)
    Parser.new(Lexer.new(src).tokenize, src).parse
  end

  def annotate(src)
    ast = parse(src)
    ann = SemanticAnnotator.new
    ann.annotate!(ast)
    [ast, ann]
  end

  # ── REQUIRES parsing ────────────────────────────────────────────────────

  describe "REQUIRES parsing" do
    it "parses a single-family REQUIRES" do
      ast = parse("FN bumpIt(c: Counter) RETURNS Void REQUIRES c: LOCKABLE -> END")
      expect(ast.statements.first.requires).to eq("c" => Set[:LOCKABLE])
    end

    it "parses a multi-family disjunction" do
      ast = parse("FN bumpIt(c: Counter) RETURNS Void REQUIRES c: LOCKABLE | VERSIONED -> END")
      expect(ast.statements.first.requires).to eq("c" => Set[:LOCKABLE, :VERSIONED])
    end

    it "parses a grouped param-list (one disjunction shared)" do
      ast = parse("FN transact(x: A, y: B) RETURNS Void REQUIRES x, y: LOCKABLE -> END")
      expect(ast.statements.first.requires).to eq(
        "x" => Set[:LOCKABLE],
        "y" => Set[:LOCKABLE]
      )
    end

    it "parses multiple groups separated by ','" do
      ast = parse("FN mixed(x: A, y: B) RETURNS Void REQUIRES x: LOCKABLE, y: VERSIONED -> END")
      expect(ast.statements.first.requires).to eq(
        "x" => Set[:LOCKABLE],
        "y" => Set[:VERSIONED]
      )
    end

    it "rejects unknown family names" do
      expect {
        parse("FN bumpIt(c: Counter) RETURNS Void REQUIRES c: NOT_A_FAMILY -> END")
      }.to raise_error(ParserError, /Unknown REQUIRES family/)
    end
  end

  # ── WITH MATCH parsing ──────────────────────────────────────────────────

  describe "WITH MATCH parsing" do
    it "parses a single-family WITH (no MATCH wrapper) — sugar form" do
      src = <<~CHT
        FN bumpIt(c: Counter) RETURNS Void
          REQUIRES c: LOCKABLE
        ->
          WITH EXCLUSIVE c AS inner { x = inner.value; }
        END
      CHT
      ast = parse(src)
      with_block = ast.statements.first.body.first
      expect(with_block).to be_a(AST::WithBlock)
      expect(with_block.arms).to be_nil  # sugar form: no MATCH
    end

    it "parses a multi-family WITH MATCH with WHEN arms" do
      src = <<~CHT
        FN transact(x: A, y: B) RETURNS Bool
          REQUIRES x, y: LOCKABLE | VERSIONED
        ->
          WITH x AS a, y AS b MATCH
            WHEN LOCKABLE -> { z = 1; }
            WHEN VERSIONED -> { w = 2; }
          END
        END
      CHT
      ast = parse(src)
      with_block = ast.statements.first.body.first
      expect(with_block.arms).not_to be_nil
      expect(with_block.arms.length).to eq(2)
      expect(with_block.arms.map { |a| a[:family] }).to eq([:LOCKABLE, :VERSIONED])
    end

    it "parses per-arm ON clauses" do
      src = <<~CHT
        FN transact(x: A) RETURNS Void
          REQUIRES x: LOCKABLE | VERSIONED
        ->
          WITH x AS a MATCH
            WHEN LOCKABLE
              -> { z = 1; }
              ON LockTimeout EXIT "timed out"
            WHEN VERSIONED
              -> { w = 2; }
          END
        END
      CHT
      ast = parse(src)
      arms = ast.statements.first.body.first.arms
      expect(arms[0][:lock_error_clauses].length).to eq(1)
      expect(arms[1][:lock_error_clauses].length).to eq(0)
    end

    it "rejects WITH MATCH with no WHEN arms" do
      src = <<~CHT
        FN bad(x: A) RETURNS Void
          REQUIRES x: LOCKABLE
        ->
          WITH EXCLUSIVE x AS a MATCH END
        END
      CHT
      expect { parse(src) }.to raise_error(ParserError, /requires at least one WHEN arm/i)
    end
  end

  # ── Per-function validation (P2.4 + P2.5 + P2.7 shim) ───────────────────

  describe "P2.4: REQUIRES↔WHEN exhaustiveness" do
    it "errors when a WHEN arm is missing for a declared family" do
      src = <<~CHT
        STRUCT Counter { value: Int64 }
        FN transact(x: Counter, y: Counter) RETURNS Bool
          REQUIRES x, y: LOCKABLE | VERSIONED
        ->
          WITH EXCLUSIVE x AS a, EXCLUSIVE y AS b MATCH
            WHEN LOCKABLE -> { z = 1; }
          END
          RETURN TRUE;
        END
      CHT
      expect { annotate(src) }.to raise_error(CompilerError, /missing a WHEN arm for VERSIONED/)
    end

    it "errors when a WHEN arm is present but not in REQUIRES" do
      src = <<~CHT
        STRUCT Counter { value: Int64 }
        FN bumpIt(c: Counter) RETURNS Void
          REQUIRES c: LOCKABLE
        ->
          WITH EXCLUSIVE c AS inner MATCH
            WHEN LOCKABLE -> { x = inner.value; }
            WHEN VERSIONED -> { x = inner.value; }
          END
        END
      CHT
      expect { annotate(src) }.to raise_error(CompilerError, /WHEN arm for VERSIONED.*not in REQUIRES/m)
    end
  end

  describe "P2.7: shim auto-infers REQUIRES on legacy code" do
    it "compiles WITH-on-param without REQUIRES under the shim" do
      src = <<~CHT
        STRUCT Counter { value: Int64 }
        FN bumpIt(c: Counter) RETURNS Void ->
          WITH EXCLUSIVE c AS inner { inner.value = inner.value + 1; }
        END
        FN main() RETURNS Void ->
          c = Counter{ value: 0 } @shared:locked;
          bumpIt(c);
        END
      CHT
      # Shim emits Note to stderr; suppress it for the test.
      expect {
        capture = StringIO.new
        $stderr, orig = capture, $stderr
        begin
          annotate(src)
        ensure
          $stderr = orig
        end
        # Verify the shim populated fn.requires with LOCKABLE.
        ast = parse(src)
        ann = SemanticAnnotator.new
        $stderr = StringIO.new
        ann.annotate!(ast)
        $stderr = orig
        bump_fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "bumpIt" }
        expect(bump_fn.requires).to eq("c" => Set[:LOCKABLE])
      }.not_to raise_error
    end
  end

  # ── Call-site family check (P2.6) ───────────────────────────────────────

  describe "P2.6: call-site family check" do
    it "errors when caller passes bare arg to LOCKABLE-required param" do
      src = <<~CHT
        STRUCT Counter { value: Int64 }
        FN bumpIt(c: Counter) RETURNS Void
          REQUIRES c: LOCKABLE
        ->
          WITH EXCLUSIVE c AS inner { inner.value = inner.value + 1; }
        END
        FN main() RETURNS Void ->
          c = Counter{ value: 0 };
          bumpIt(c);
        END
      CHT
      expect { annotate(src) }.to raise_error(CompilerError,
        /Call to 'bumpIt' requires parameter 'c' to be bound under one of: LOCKABLE/)
    end

    it "accepts a caller binding in the LOCKABLE family" do
      src = <<~CHT
        STRUCT Counter { value: Int64 }
        FN bumpIt(c: Counter) RETURNS Void
          REQUIRES c: LOCKABLE
        ->
          WITH EXCLUSIVE c AS inner { inner.value = inner.value + 1; }
        END
        FN main() RETURNS Void ->
          c = Counter{ value: 0 } @shared:locked;
          bumpIt(c);
        END
      CHT
      expect { annotate(src) }.not_to raise_error
    end
  end
end
