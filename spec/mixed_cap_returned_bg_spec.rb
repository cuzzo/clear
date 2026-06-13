require "rspec"
require_relative "../src/backends/transpiler"
require_relative "../src/ast/ast"

# Atomics M2.7: a `REQUIRES x: ATOMIC | <non-atomic>` declaration
# combined with `RETURNS x:T` cannot be safely emitted. The
# returned value's runtime layout differs by family:
#
#   ATOMIC  -> bare `*Atomic(T)` (scope-bounded; M2.2)
#   LOCKED  -> Arc(Locked(T))    (refcounted)
#   VERSIONED -> Versioned(T) cell + EBR pin
#
# A single returned future would have two different lifetime
# stories at the call site, so the compiler rejects the
# combination at the declaration site. The user has to split
# into two separate functions (one per family) or drop ATOMIC
# from the REQUIRES disjunction.
RSpec.describe "Mixed-cap REQUIRES + RETURNS x:T (M2.7)" do
  def annotate(src)
    tokens = Lexer.new(src).tokenize
    ast = ClearParser.new(tokens, src).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  describe "ATOMIC | LOCKED with RETURNS x:T (rejected)" do
    it "errors when the param appears in BOTH the disjunction AND the RETURNS lifetime" do
      expect {
        annotate(<<~CLEAR)
          STRUCT C { v: Int64 }
          FN spawn!(MUTABLE c: C) RETURNS c:~Void
            REQUIRES c: ATOMIC | LOCKED
          ->
            bg = BG { x = c.v; print(x.toString()); };
            RETURN bg;
          END
        CLEAR
      }.to raise_error(CompilerError, /Lifetime Error.*ATOMIC \| LOCKED/i)
    end

    it "error message names the function and points at the split-or-drop fix" do
      expect {
        annotate(<<~CLEAR)
          STRUCT C { v: Int64 }
          FN spawn!(MUTABLE c: C) RETURNS c:~Void
            REQUIRES c: ATOMIC | LOCKED
          ->
            bg = BG { x = c.v; print(x.toString()); };
            RETURN bg;
          END
        CLEAR
      }.to raise_error(CompilerError, /split into two functions|drop the ATOMIC family/i)
    end
  end

  describe "ATOMIC | VERSIONED with RETURNS x:T (rejected)" do
    it "errors symmetrically for ATOMIC + any non-atomic family" do
      expect {
        annotate(<<~CLEAR)
          STRUCT C { v: Int64 }
          FN spawn!(MUTABLE c: C) RETURNS c:~Void
            REQUIRES c: ATOMIC | VERSIONED
          ->
            bg = BG { x = c.v; print(x.toString()); };
            RETURN bg;
          END
        CLEAR
      }.to raise_error(CompilerError, /Lifetime Error.*ATOMIC \| VERSIONED/i)
    end
  end

  describe "single-family REQUIRES (allowed)" do
    it "RETURNS x:T with REQUIRES x: ATOMIC alone compiles" do
      expect {
        annotate(<<~CLEAR)
          FN spawn!(counter: Int64) RETURNS counter:~Void
            REQUIRES counter: ATOMIC
          ->
            bg = BG { v = counter; print(v.toString()); };
            RETURN bg;
          END
        CLEAR
      }.not_to raise_error
    end

    it "RETURNS x:T with REQUIRES x: LOCKED alone compiles (Arc-refcounted lifetime)" do
      expect {
        annotate(<<~CLEAR)
          STRUCT C { v: Int64 }
          FN spawn!(c: C) RETURNS c:~Void
            REQUIRES c: LOCKED
          ->
            bg = BG { WITH EXCLUSIVE c AS inner { x = inner.v; print(x.toString()); } };
            RETURN bg;
          END
        CLEAR
      }.not_to raise_error
    end
  end

  describe "mixed-cap REQUIRES with NO RETURNS x:T (allowed)" do
    it "ATOMIC | LOCKED is fine when the function doesn't return through that param" do
      # If the polymorphic param doesn't appear in the RETURNS
      # lifetime, the runtime-layout divergence is irrelevant -- the
      # call-site never receives a captured-handle whose lifetime
      # depends on the family.
      expect {
        annotate(<<~CLEAR)
          STRUCT C { v: Int64 }
          FN inspect!(MUTABLE c: C) RETURNS Int64
            REQUIRES c: ATOMIC | LOCKED
          ->
            WITH c AS va MATCH
              WHEN ATOMIC   -> { x: Int64 = 0; }
              WHEN LOCKED   -> { _ = va.v; }
            END
            RETURN 0;
          END
        CLEAR
      }.not_to raise_error
    end
  end

  describe "multi-source RETURNS — error fires per offending source" do
    it "errors when ANY source in `RETURNS (a b):T` is mixed-cap" do
      expect {
        annotate(<<~CLEAR)
          STRUCT C { v: Int64 }
          FN spawn!(MUTABLE a: C, b: Int64) RETURNS (a, b):~Void
            REQUIRES a: ATOMIC | LOCKED, b: ATOMIC
          ->
            bg = BG { x = a.v; y = b; print(x.toString()); print(y.toString()); };
            RETURN bg;
          END
        CLEAR
      }.to raise_error(CompilerError, /Lifetime Error.*ATOMIC \| LOCKED/i)
    end

    it "compiles when each source is single-family" do
      expect {
        annotate(<<~CLEAR)
          FN spawn!(a: Int64, b: Int64) RETURNS (a, b):~Void
            REQUIRES a: ATOMIC, b: ATOMIC
          ->
            bg = BG { x = a; y = b; print(x.toString()); print(y.toString()); };
            RETURN bg;
          END
        CLEAR
      }.not_to raise_error
    end
  end
end
