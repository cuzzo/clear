require "rspec"
require_relative "../src/backends/transpiler"
require_relative "../src/ast/ast"

# AtomicPtr M3.9 -- multi-cell `WITH SNAPSHOT` rejection when any
# cell is @indirect:atomic.
#
# `@indirect:atomic` has no portable hardware multi-pointer CAS
# primitive (and software MCAS is out of scope for v0.3), so per-cell
# atomic CAS gives no atomicity ACROSS cells. MVCC's `Shared.updateMulti`
# works because of sorted-pointer locking + commit-or-rollback machinery
# that AtomicPtr doesn't have. Reject the combination at the annotator
# with the user-specified message:
#
#   "@indirect:atomic cannot guarantee multi-object consistency.
#    If you need multi-object consistency use @shared:versioned
#    or @shared:locked."
RSpec.describe "Multi-cell `WITH SNAPSHOT` with @indirect:atomic (M3.9)" do
  def annotate(src)
    tokens = Lexer.new(src).tokenize
    ast = ClearParser.new(tokens, src).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  describe "single-arm SNAPSHOT" do
    it "accepts multi-cell SNAPSHOT when ALL cells are @versioned" do
      expect {
        annotate(<<~CLEAR)
          STRUCT C { v: Int64 }
          FN both!() RETURNS !Void ->
            a = C{ v: 0 } @versioned;
            b = C{ v: 0 } @versioned;
            WITH SNAPSHOT a AS MUTABLE va, SNAPSHOT b AS MUTABLE vb {
              va.v = va.v + 1;
              vb.v = vb.v + 1;
            } ON MvccConflict RAISE
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end

    it "rejects multi-cell SNAPSHOT MUTABLE when ANY cell is @indirect:atomic" do
      expect {
        annotate(<<~CLEAR)
          STRUCT C { v: Int64 }
          FN both!() RETURNS Void ->
            a = C{ v: 0 } @versioned;
            b = C{ v: 0 } @indirect:atomic;
            WITH SNAPSHOT a AS MUTABLE va, SNAPSHOT b AS MUTABLE vb {
              va.v = va.v + 1;
              vb.v = vb.v + 1;
            } ON MvccConflict RAISE
            RETURN;
          END
        CLEAR
      }.to raise_error(/Multi-object WITH cannot admit ATOMIC.*atomicity across cells/im)
    end

    it "rejects multi-cell SNAPSHOT (read-only) when ANY cell is @indirect:atomic" do
      # Even pure-read multi-cell SNAPSHOT is rejected -- per-cell
      # atomic loads aren't cross-cell consistent (the reader can
      # see a state nobody ever published). The error directs the
      # user to @shared:versioned for cross-cell snapshot reads.
      expect {
        annotate(<<~CLEAR)
          STRUCT C { v: Int64 }
          FN both() RETURNS Void ->
            a = C{ v: 0 } @indirect:atomic;
            b = C{ v: 0 } @versioned;
            WITH SNAPSHOT a AS va, SNAPSHOT b AS vb {
              x = va.v;
              y = vb.v;
            }
            RETURN;
          END
        CLEAR
      }.to raise_error(/Multi-object WITH cannot admit ATOMIC/i)
    end

    it "rejects multi-cell SNAPSHOT when ALL cells are @indirect:atomic" do
      expect {
        annotate(<<~CLEAR)
          STRUCT C { v: Int64 }
          FN both!() RETURNS Void ->
            a = C{ v: 0 } @indirect:atomic;
            b = C{ v: 0 } @indirect:atomic;
            WITH SNAPSHOT a AS MUTABLE va, SNAPSHOT b AS MUTABLE vb {
              va.v = va.v + 1;
              vb.v = vb.v + 1;
            }
            RETURN;
          END
        CLEAR
      }.to raise_error(/Multi-object WITH cannot admit ATOMIC/i)
    end
  end

  describe "single-cell SNAPSHOT (regression)" do
    it "single-cell @indirect:atomic still works (M3.5/M3.6 path unaffected)" do
      expect {
        annotate(<<~CLEAR)
          STRUCT C { v: Int64 }
          FN one!() RETURNS !Void ->
            a = C{ v: 0 } @indirect:atomic;
            WITH SNAPSHOT a AS MUTABLE va { va.v = va.v + 1; }
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end

    it "single-cell @versioned still works (regression)" do
      expect {
        annotate(<<~CLEAR)
          STRUCT C { v: Int64 }
          FN one!() RETURNS !Void ->
            a = C{ v: 0 } @versioned;
            WITH SNAPSHOT a AS MUTABLE va { va.v = va.v + 1; } ON MvccConflict RAISE
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end
  end
end
