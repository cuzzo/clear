require "rspec"

require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/ast/ast"
require_relative "../src/annotator"

# MVCC L5 -- annotator validation for WITH SNAPSHOT.
#
# Covers:
#   - source must be `T@versioned`.
#   - alias is non_escaping; every escape vector is rejected.
#   - ON Conflict required when any cell is MUTABLE (transaction).
#   - ON Conflict accepts `RAISE`, `RETRY(N) THEN <action>`, etc.
RSpec.describe "WITH SNAPSHOT annotator validation" do
  def run(src)
    tokens = Lexer.new(src).tokenize
    ast = Parser.new(tokens, src).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  # Returns the diagnostics from a parse + annotate run, swallowing any
  # raised error so we can introspect the message.
  def errors_for(src)
    begin
      run(src)
    rescue => e
      return [e.message]
    end
    []
  end

  describe "source-type validation" do
    it "accepts `WITH SNAPSHOT counter AS view` when counter is @versioned" do
      src = <<~CLEAR
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @versioned;
        WITH SNAPSHOT c AS view { x = view.v; }
      CLEAR
      expect { run(src) }.not_to raise_error
    end

    it "rejects `WITH SNAPSHOT` on a plain (non-@versioned) variable" do
      src = <<~CLEAR
        STRUCT C { v: Int64 }
        c = C{ v: 0 };
        WITH SNAPSHOT c AS view { x = view.v; }
      CLEAR
      expect { run(src) }.to raise_error(/WITH SNAPSHOT requires a @versioned or @indirect:atomic variable/i)
    end

    it "rejects `WITH SNAPSHOT` on a @locked variable" do
      src = <<~CLEAR
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @locked;
        WITH SNAPSHOT c AS view { x = view.v; }
      CLEAR
      expect { run(src) }.to raise_error(/WITH SNAPSHOT requires a @versioned or @indirect:atomic variable/i)
    end
  end

  describe "alias declaration" do
    it "binds the alias as the bare inner type (Group 2 strip)" do
      src = <<~CLEAR
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @versioned;
        WITH SNAPSHOT c AS view { x = view.v; }
      CLEAR
      expect { run(src) }.not_to raise_error
    end

    it "AS MUTABLE alias is mutable (can mutate fields)" do
      src = <<~CLEAR
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @versioned;
        WITH SNAPSHOT c AS MUTABLE va { va.v = 5; } ON Conflict RAISE
      CLEAR
      expect { run(src) }.not_to raise_error
    end

    it "non-MUTABLE alias rejects field mutation (immutable)" do
      src = <<~CLEAR
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @versioned;
        WITH SNAPSHOT c AS view { view.v = 5; }
      CLEAR
      expect { run(src) }.to raise_error(/cannot.*assign|immutable/i)
    end
  end

  describe "ON Conflict requirement (D2/D3)" do
    it "requires ON Conflict when AS MUTABLE" do
      src = <<~CLEAR
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @versioned;
        WITH SNAPSHOT c AS MUTABLE va { va.v = 5; }
      CLEAR
      expect { run(src) }.to raise_error(/AS MUTABLE requires an ON Conflict handler/i)
    end

    it "accepts ON Conflict RAISE" do
      src = <<~CLEAR
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @versioned;
        WITH SNAPSHOT c AS MUTABLE va { va.v = 5; } ON Conflict RAISE
      CLEAR
      expect { run(src) }.not_to raise_error
    end

    it "accepts ON Conflict RETRY(3) THEN PASS (D3)" do
      src = <<~CLEAR
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @versioned;
        WITH SNAPSHOT c AS MUTABLE va { va.v = 5; } ON Conflict RETRY(3) THEN PASS
      CLEAR
      expect { run(src) }.not_to raise_error
    end

    it "rejects ON Conflict on a non-fallible cap (lock-style fallible only)" do
      src = <<~CLEAR
        STRUCT C { v: Int64 }
        MUTABLE c = C{ v: 0 } @multiowned;
        WITH c { } ON Conflict RAISE
      CLEAR
      expect { run(src) }.to raise_error(/never produce a lock-acquire error/i)
    end

    it "ON Conflict not required for read-only SNAPSHOT" do
      src = <<~CLEAR
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @versioned;
        WITH SNAPSHOT c AS view { x = view.v; }
      CLEAR
      expect { run(src) }.not_to raise_error
    end

    it "rejects RETRY targeting a non-Transient kind (Conflict is Transient, so this is only via wrong selector)" do
      # This is a regression / behavior pin: Conflict IS Transient, so
      # RETRY(N) is allowed. Just verify the path doesn't false-positive.
      src = <<~CLEAR
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @versioned;
        WITH SNAPSHOT c AS MUTABLE va { va.v = 1; } ON Transient RETRY(5) THEN PASS
      CLEAR
      expect { run(src) }.not_to raise_error
    end
  end

  describe "non-escape (D5)" do
    # Per CLEAR's design, capability annotations are not allowed on
    # function parameters -- the sync flows in from the caller binding.
    # For the L5 escape-vector tests we use local @versioned bindings
    # inside a function body.
    let(:setup) {
      <<~CLEAR
        STRUCT C { v: Int64 }
      CLEAR
    }

    it "rejects RETURN of the alias (struct alias is borrow-non-escaping)" do
      bad = setup + <<~CLEAR
        FN leak() RETURNS C ->
          c = C{ v: 0 } @versioned;
          WITH SNAPSHOT c AS view { RETURN view; }
        END
      CLEAR
      expect { run(bad) }.to raise_error(/.+/)
    end

    it "rejects RETURN of any field via the alias (chain rooted at non_escaping is non_escaping)" do
      bad = setup + <<~CLEAR
        FN read_v() RETURNS Int64 ->
          c = C{ v: 42 } @versioned;
          WITH SNAPSHOT c AS view { RETURN view.v; }
        END
      CLEAR
      expect { run(bad) }.to raise_error(/Cannot RETURN a field of a WITH-scoped binding/i)
    end

    it "rejects struct-field store of the alias into a longer-lived heap container" do
      bad = setup + <<~CLEAR
        STRUCT Box { content: C }
        FN store_() RETURNS Void ->
          c = C{ v: 0 } @versioned;
          MUTABLE b = Box{ content: C{ v: 0 } };
          WITH SNAPSHOT c AS view { b.content = view; }
          RETURN;
        END
      CLEAR
      expect { run(bad) }.to raise_error(/.+/)
    end

    it "rejects BG capture of the alias" do
      bad = setup + <<~CLEAR
        FN spawn_() RETURNS Void ->
          c = C{ v: 0 } @versioned;
          WITH SNAPSHOT c AS view {
            BG { x = view.v; };
          }
          RETURN;
        END
      CLEAR
      expect { run(bad) }.to raise_error(/.+/)
    end

    it "rejects GIVE of the alias" do
      bad = setup + <<~CLEAR
        FN consume_(t: C) RETURNS Void -> RETURN; END
        FN caller() RETURNS Void ->
          c = C{ v: 0 } @versioned;
          WITH SNAPSHOT c AS view { consume_(GIVE view); }
          RETURN;
        END
      CLEAR
      expect { run(bad) }.to raise_error(/.+/)
    end
  end
end
