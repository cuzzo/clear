require "rspec"
require_relative "../src/backends/transpiler"
require_relative "../src/ast/ast"

# AtomicPtr M3.5 / M3.6 -- WITH SNAPSHOT validation against
# @indirect:atomic cells. Read mode shares the @versioned surface
# (M3.5); MUTABLE mode requires NO `ON Conflict` (M3.6, Rust rcu --
# AtomicPtr.update retries until success, no conflict path).
RSpec.describe "WITH SNAPSHOT against @indirect:atomic (M3.5 / M3.6)" do
  def annotate(src)
    tokens = Lexer.new(src).tokenize
    ast = Parser.new(tokens, src).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  describe "read mode (M3.5)" do
    it "accepts WITH SNAPSHOT cell AS view { ... } on @indirect:atomic" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Cfg { v: Int64 }
          FN main() RETURNS Void ->
            cfg = Cfg{ v: 0 } @indirect:atomic;
            WITH SNAPSHOT cfg AS x { _ = x.v; }
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end

    it "still rejects WITH SNAPSHOT on a plain (non-versioned, non-atomic-ptr) struct" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Cfg { v: Int64 }
          FN main() RETURNS Void ->
            cfg = Cfg{ v: 0 };
            WITH SNAPSHOT cfg AS x { _ = x.v; }
            RETURN;
          END
        CLEAR
      }.to raise_error(/WITH SNAPSHOT requires a @versioned or @indirect:atomic/)
    end
  end

  describe "MUTABLE mode (M3.6)" do
    it "accepts WITH SNAPSHOT cell AS MUTABLE x { ... } with NO ON Conflict on @indirect:atomic" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Counter { value: Int64 }
          FN main() RETURNS Void ->
            cfg = Counter{ value: 0 } @indirect:atomic;
            WITH SNAPSHOT cfg AS MUTABLE x { x.value = x.value + 1; }
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end

    it "rejects ON Conflict on an @indirect:atomic SNAPSHOT MUTABLE block" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Counter { value: Int64 }
          FN main() RETURNS Void ->
            cfg = Counter{ value: 0 } @indirect:atomic;
            WITH SNAPSHOT cfg AS MUTABLE x { x.value = x.value + 1; } ON Conflict RAISE
            RETURN;
          END
        CLEAR
      }.to raise_error(/ON Conflict.*isn'?t valid.*@indirect:atomic.*rcu/i)
    end

    it "still requires ON Conflict on a @versioned SNAPSHOT MUTABLE block" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Counter { value: Int64 }
          FN main() RETURNS Void ->
            cfg = Counter{ value: 0 } @versioned;
            WITH SNAPSHOT cfg AS MUTABLE x { x.value = x.value + 1; }
            RETURN;
          END
        CLEAR
      }.to raise_error(/WITH SNAPSHOT.*MUTABLE requires an ON Conflict/)
    end
  end
end
