require "rspec"
require_relative "../src/backends/transpiler"
require_relative "../src/ast/ast"

# AtomicPtr M3.11 -- when a fn declares `REQUIRES c: VERSIONED | ATOMIC`
# AND the body contains `WITH SNAPSHOT c AS MUTABLE x { ... }` without
# MATCH, error directing the user to MATCH-dispatch. The two families
# differ in their ON Conflict requirement (VERSIONED requires it,
# ATOMIC forbids it), so the bare body shape can't be reconciled.
#
# Error message (design contract docs/agents/atomicptr.md §6.4):
#   "Mutate surface differs by family: @versioned bounds retries and
#    requires `ON Conflict`; @indirect:atomic retries unbounded and
#    forbids it. Dispatch per family with `WITH SNAPSHOT c AS
#    MUTABLE x MATCH ...`."
RSpec.describe "Polymorphic VERSIONED|ATOMIC mutate without MATCH (M3.11)" do
  def annotate(src)
    tokens = Lexer.new(src).tokenize
    ast = Parser.new(tokens, src).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  describe "rejected: VERSIONED | ATOMIC without MATCH" do
    it "rejects bare `WITH SNAPSHOT c AS MUTABLE x { ... }` with ON Conflict" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Cfg { port: Int64 }
          FN bumpPort!(MUTABLE c: Cfg) RETURNS Void
            REQUIRES c: VERSIONED | ATOMIC
          ->
            WITH SNAPSHOT c AS MUTABLE x { x.port = x.port + 1; } ON Conflict RAISE
            RETURN;
          END
        CLEAR
      }.to raise_error(/Mutate surface differs by family.*WITH SNAPSHOT.*MATCH/im)
    end

    it "rejects bare `WITH SNAPSHOT c AS MUTABLE x { ... }` without ON Conflict" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Cfg { port: Int64 }
          FN bumpPort!(MUTABLE c: Cfg) RETURNS Void
            REQUIRES c: VERSIONED | ATOMIC
          ->
            WITH SNAPSHOT c AS MUTABLE x { x.port = x.port + 1; }
            RETURN;
          END
        CLEAR
      }.to raise_error(/Mutate surface differs by family.*WITH SNAPSHOT.*MATCH/im)
    end
  end

  describe "accepted: VERSIONED | ATOMIC with MATCH" do
    it "accepts SNAPSHOT MATCH dispatch (M3.7+M3.8 path)" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Cfg { port: Int64 }
          FN bumpPort!(MUTABLE c: Cfg) RETURNS Void
            REQUIRES c: VERSIONED | ATOMIC
          ->
            WITH SNAPSHOT c AS MUTABLE x MATCH
              WHEN VERSIONED -> { x.port = x.port + 1; } ON Conflict RAISE
              WHEN ATOMIC    -> { x.port = x.port + 1; }
            END
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end
  end

  describe "accepted: read-only polymorphic VERSIONED | ATOMIC works without MATCH (uniform body)" do
    it "accepts bare read-only `WITH SNAPSHOT c AS x { ... }`" do
      # Read paths can't fail in EITHER family, so the same body works
      # uniformly without MATCH.
      expect {
        annotate(<<~CLEAR)
          STRUCT Cfg { port: Int64 }
          FN dump(c: Cfg) RETURNS Void
            REQUIRES c: VERSIONED | ATOMIC
          ->
            WITH SNAPSHOT c AS x { _ = x.port; }
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end
  end

  describe "regression: single-family REQUIRES still uses bare body" do
    it "REQUIRES c: VERSIONED only -- bare body still works (with ON Conflict)" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Cfg { port: Int64 }
          FN bumpV!(MUTABLE c: Cfg) RETURNS Void
            REQUIRES c: VERSIONED
          ->
            WITH SNAPSHOT c AS MUTABLE x { x.port = x.port + 1; } ON Conflict RAISE
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end

    it "REQUIRES c: ATOMIC only -- bare body still works (no ON Conflict)" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Cfg { port: Int64 }
          FN bumpA!(MUTABLE c: Cfg) RETURNS Void
            REQUIRES c: ATOMIC
          ->
            WITH SNAPSHOT c AS MUTABLE x { x.port = x.port + 1; }
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end
  end
end
