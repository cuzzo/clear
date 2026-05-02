require "rspec"
require_relative "../src/backends/transpiler"
require_relative "../src/ast/ast"

# True-Sync-Polymorphism (#333): generalized rejection of multi-object
# WITH where any sync-constrained binding could be `@atomic` /
# `@indirect:atomic` at runtime. Folds and broadens M3.9 (which only
# covered `WITH SNAPSHOT` with concrete `@indirect:atomic`).
#
# Rule:
#   If a WITH binds 2+ sync-constrained cells AND any binding admits
#   ATOMIC (concretely or via REQUIRES disjunction), the compiler
#   errors. The user must (a) narrow REQUIRES to a non-ATOMIC family
#   (LOCKED | VERSIONED), or (b) refactor to single-cell WITHs.
#
# Sync-only: BORROWED / RESTRICT / VIEW / MATERIALIZED VIEW capabilities
# don't count toward the multi-binding threshold (they don't synchronize).
RSpec.describe "Multi-object WITH cannot admit ATOMIC (#333)" do
  def annotate(src)
    tokens = Lexer.new(src).tokenize
    ast = Parser.new(tokens, src).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  # ── 1. Concrete @indirect:atomic in multi-cell SNAPSHOT (folded M3.9) ──

  describe "concrete @indirect:atomic in multi-cell SNAPSHOT" do
    it "MUTABLE form rejects when ANY cell is @indirect:atomic" do
      expect {
        annotate(<<~CLEAR)
          STRUCT C { v: Int64 }
          FN both!() RETURNS Void ->
            a = C{ v: 0 } @versioned;
            b = C{ v: 0 } @indirect:atomic;
            WITH SNAPSHOT a AS MUTABLE va, SNAPSHOT b AS MUTABLE vb {
              va.v = va.v + 1; vb.v = vb.v + 1;
            } ON MvccConflict RAISE
            RETURN;
          END
        CLEAR
      }.to raise_error(/Multi-object WITH cannot admit ATOMIC/)
    end

    it "read-only form rejects too" do
      expect {
        annotate(<<~CLEAR)
          STRUCT C { v: Int64 }
          FN both() RETURNS Void ->
            a = C{ v: 0 } @indirect:atomic;
            b = C{ v: 0 } @versioned;
            WITH SNAPSHOT a AS va, SNAPSHOT b AS vb { x = va.v; y = vb.v; }
            RETURN;
          END
        CLEAR
      }.to raise_error(/Multi-object WITH cannot admit ATOMIC/)
    end
  end

  # ── 2. Polymorphic params that admit ATOMIC ──

  describe "polymorphic REQUIRES that admits ATOMIC" do
    it "REQUIRES x, y: ATOMIC + multi-binding plain WITH → error" do
      expect {
        annotate(<<~CLEAR)
          STRUCT C { v: Int64 }
          FN tx!(MUTABLE x: C, MUTABLE y: C) RETURNS Void
            REQUIRES x, y: ATOMIC
          ->
            WITH EXCLUSIVE x AS xa, EXCLUSIVE y AS ya { xa.v = ya.v + 1; }
            RETURN;
          END
        CLEAR
      }.to raise_error(/Multi-object WITH cannot admit ATOMIC.*narrow.*REQUIRES/m)
    end

    it "REQUIRES x, y: SNAPSHOTTED + multi-binding WITH POLYMORPHIC → error" do
      expect {
        annotate(<<~CLEAR)
          STRUCT C { v: Int64 }
          FN tx!(MUTABLE x: C, MUTABLE y: C) RETURNS Void
            REQUIRES x, y: SNAPSHOTTED
          ->
            WITH POLYMORPHIC EXCLUSIVE x AS xa, EXCLUSIVE y AS ya {
              xa.v = ya.v + 1;
            }
            RETURN;
          END
        CLEAR
      }.to raise_error(/Multi-object WITH cannot admit ATOMIC/)
    end

    it "REQUIRES x, y: LOCKED | ATOMIC + multi-binding → error" do
      expect {
        annotate(<<~CLEAR)
          STRUCT C { v: Int64 }
          FN tx!(MUTABLE x: C, MUTABLE y: C) RETURNS Void
            REQUIRES x, y: LOCKED | ATOMIC
          ->
            WITH POLYMORPHIC EXCLUSIVE x AS xa, EXCLUSIVE y AS ya {
              xa.v = ya.v + 1;
            }
            RETURN;
          END
        CLEAR
      }.to raise_error(/Multi-object WITH cannot admit ATOMIC/)
    end
  end

  # ── 3. The recommended fixes are accepted ──

  describe "non-ATOMIC family disjunctions are accepted" do
    it "REQUIRES x, y: LOCKED | VERSIONED + multi-binding WITH POLYMORPHIC" do
      expect {
        annotate(<<~CLEAR)
          STRUCT C { v: Int64 }
          FN tx!(MUTABLE x: C, MUTABLE y: C) RETURNS Void
            REQUIRES x, y: LOCKED | VERSIONED
          ->
            WITH POLYMORPHIC EXCLUSIVE x AS xa, EXCLUSIVE y AS ya {
              xa.v = ya.v + 1;
            }
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end

    it "REQUIRES x, y: VERSIONED + multi-cell SNAPSHOT" do
      expect {
        annotate(<<~CLEAR)
          STRUCT C { v: Int64 }
          FN tx!(MUTABLE x: C, MUTABLE y: C) RETURNS Void
            REQUIRES x, y: VERSIONED
          ->
            WITH SNAPSHOT x AS MUTABLE xa, SNAPSHOT y AS MUTABLE ya {
              xa.v = ya.v + 1;
            } ON MvccConflict RAISE
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end

    it "REQUIRES x, y: LOCKED + multi-binding plain WITH" do
      expect {
        annotate(<<~CLEAR)
          STRUCT C { v: Int64 }
          FN tx!(MUTABLE x: C, MUTABLE y: C) RETURNS Void
            REQUIRES x, y: LOCKED
          ->
            WITH POLYMORPHIC EXCLUSIVE x AS xa, EXCLUSIVE y AS ya {
              xa.v = ya.v + 1;
            }
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end
  end

  # ── 4. Single-cell forms are unaffected ──

  describe "single-cell WITH always accepts ATOMIC" do
    it "concrete @indirect:atomic single-cell SNAPSHOT MUTABLE" do
      expect {
        annotate(<<~CLEAR)
          STRUCT C { v: Int64 }
          FN one!() RETURNS Void ->
            a = C{ v: 0 } @indirect:atomic;
            WITH SNAPSHOT a AS MUTABLE va { va.v = va.v + 1; }
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end

    it "REQUIRES x: SNAPSHOTTED single-cell" do
      expect {
        annotate(<<~CLEAR)
          STRUCT C { v: Int64 }
          FN read(c: C) RETURNS Void
            REQUIRES c: SNAPSHOTTED
          ->
            WITH SNAPSHOT c AS x { _ = x.v; }
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end
  end
end
