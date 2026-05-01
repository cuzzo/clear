require "rspec"
require "set"

require_relative "../src/backends/transpiler"
require_relative "../src/mir/effect_set"
require_relative "../src/mir/effect_inference"

# P3.7: pin the four Phase 3 compile-time correctness checks plus the
# EffectSet / EffectInference scaffolding.

RSpec.describe "P3 effect inference + correctness checks" do
  def annotate(src)
    ast = Parser.new(Lexer.new(src).tokenize, src).parse
    ann = SemanticAnnotator.new
    ann.annotate!(ast)
    [ast, ann]
  end

  # ── EffectSet (P3.1) ────────────────────────────────────────────────────

  describe "EffectSet" do
    it "rejects unknown effects" do
      expect { EffectSet.new([:not_a_thing]) }.to raise_error(ArgumentError, /Unknown effect/)
    end

    it "unions two sets" do
      a = EffectSet.new([:yield])
      b = EffectSet.new([:fail])
      expect(a.union(b).to_a).to eq([:yield, :fail])
    end

    it "compares by value" do
      expect(EffectSet.new([:yield, :fail])).to eq(EffectSet.new([:fail, :yield]))
    end

  end

  # ── EffectInference (P3.2) ──────────────────────────────────────────────

  describe "EffectInference" do
    it "stamps :yield on functions that BG or NEXT" do
      src = <<~CHT
        FN spawnAndWait() RETURNS Int64 ->
          p: ~Int64 = BG { 1; };
          x = NEXT p;
          RETURN x;
        END
      CHT
      ast, _ = annotate(src)
      fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "spawnAndWait" }
      expect(fn.effect_set.include?(:yield)).to be true
    end

    it "leaves :yield unset for pure functions" do
      src = <<~CHT
        FN add(a: Int64, b: Int64) RETURNS Int64 ->
          RETURN a + b;
        END
      CHT
      ast, _ = annotate(src)
      fn = ast.statements.first
      expect(fn.effect_set.include?(:yield)).to be false
    end

    it "propagates effects transitively" do
      src = <<~CHT
        FN inner() RETURNS Int64 ->
          p: ~Int64 = BG { 1; };
          RETURN NEXT p;
        END

        FN outer() RETURNS Int64 ->
          RETURN inner();
        END
      CHT
      ast, _ = annotate(src)
      outer = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "outer" }
      expect(outer.effect_set.include?(:yield)).to be true
    end
  end

  # ── P3.3: hold-lock-across-yield ────────────────────────────────────────

  describe "P3.3: hold-lock-across-yield" do
    it "errors when NEXT is inside a WITH EXCLUSIVE body" do
      src = <<~CHT
        STRUCT Counter { value: Int64 }
        FN bump(c: Counter, p: ~Int64) RETURNS Void
          REQUIRES c: LOCKED
        ->
          WITH EXCLUSIVE c AS x {
            v = NEXT p;
            x.value = x.value + v;
          }
        END
      CHT
      expect { annotate(src) }.to raise_error(CompilerError, /Hold-lock-across-yield: NEXT/)
    end

    it "accepts NEXT outside the WITH body" do
      src = <<~CHT
        STRUCT Counter { value: Int64 }
        FN bump(c: Counter, p: ~Int64) RETURNS Void
          REQUIRES c: LOCKED
        ->
          v = NEXT p;
          WITH EXCLUSIVE c AS x { x.value = x.value + v; }
        END

        FN main() RETURNS Void ->
          c = Counter{ value: 0 } @shared:locked;
          p: ~Int64 = BG { 1; };
          bump(c, GIVE p);
        END
      CHT
      expect { annotate(src) }.not_to raise_error
    end
  end

  # ── P3.4: naked nested-WITH on different bindings ───────────────────────

  describe "P3.4: naked nested-WITH on different bindings" do
    # The pre-existing same-type lock-cycle analysis fires before P3.4 in
    # most native cases. P3.4 adds coverage for distinct-binding nesting
    # specifically, validating that the multi-resource form is the
    # intended fix.
    it "still errors on cross-binding nesting (existing same-type detector)" do
      src = <<~CHT
        STRUCT Counter { value: Int64 }
        FN nested(a: Counter, b: Counter) RETURNS Void
          REQUIRES a, b: LOCKED
        ->
          WITH EXCLUSIVE a AS ai {
            WITH EXCLUSIVE b AS bi { bi.value = ai.value + bi.value; }
          }
        END
      CHT
      expect { annotate(src) }.to raise_error(CompilerError)
    end

    it "accepts BORROWED nesting (no lock held)" do
      src = <<~CHT
        STRUCT Counter { value: Int64 }
        FN nested(a: Counter, b: Counter) RETURNS Int64 ->
          MUTABLE total = 0_i64;
          WITH BORROWED a AS ai {
            WITH BORROWED b AS bi { total = ai.value + bi.value; }
          }
          RETURN total;
        END
      CHT
      expect { annotate(src) }.not_to raise_error
    end
  end

end
