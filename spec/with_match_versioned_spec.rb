require "rspec"

require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/ast/ast"
require_relative "../src/annotator"

# MVCC L7 -- WITH MATCH @versioned arm support.
#
# Verifies that the polymorphic form
#
#   FN f(c: T) REQUIRES c: VERSIONED | LOCKED -> ...
#     WITH c MATCH
#       WHEN VERSIONED -> { body_v }
#       WHEN LOCKED  -> { body_l }
#     END
#   END
#
# is accepted at parser + annotator level. The infrastructure was
# laid down in L3 (`VERSIONED_SYNCS = %i[versioned]` family table) and
# L5 (exhaustiveness check uses the family table).
#
# Codegen for WITH MATCH ARM BODIES (the per-family `inline if
# @hasDecl(...)` dispatch) is a separate feature that exists as a gap
# for all families (LOCKED, VERSIONED). Tracked in L7-followup.
RSpec.describe "MVCC L7: WITH MATCH @versioned arm" do
  def parse(src)
    tokens = Lexer.new(src).tokenize
    ClearParser.new(tokens, src).parse
  end

  def annotate(src)
    ast = parse(src)
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  describe "parser" do
    it "accepts WHEN VERSIONED arm" do
      src = <<~CHT
        FN f(c: A) RETURNS Void
          REQUIRES c: VERSIONED
        ->
          WITH c MATCH
            WHEN VERSIONED -> { x = 1; }
          END
        END
      CHT
      ast = parse(src)
      with_block = ast.statements.first.body.first
      expect(with_block.arms.length).to eq(1)
      expect(with_block.arms.first[:family]).to eq(:VERSIONED)
    end

    it "accepts polymorphic WHEN VERSIONED + WHEN LOCKED arms" do
      src = <<~CHT
        FN f(c: A) RETURNS Void
          REQUIRES c: VERSIONED | LOCKED
        ->
          WITH c MATCH
            WHEN VERSIONED -> { x = 1; }
            WHEN LOCKED  -> { y = 2; }
          END
        END
      CHT
      ast = parse(src)
      arms = ast.statements.first.body.first.arms
      expect(arms.map { |a| a[:family] }).to eq([:VERSIONED, :LOCKED])
    end
  end

  describe "annotator: REQUIRES <-> WHEN exhaustiveness (L5 family table)" do
    # The explicit-alias form `WITH c AS a MATCH ...` annotates
    # correctly when the arms cover the REQUIRES disjunction. Per-arm
    # body codegen (the `@hasDecl` comptime dispatch) is a broader
    # gap that exists for ALL families today, not VERSIONED-specific
    # -- tracked as L7-followup.
    it "polymorphic LOCKED | VERSIONED with explicit alias annotates without error" do
      src = <<~CHT
        STRUCT A { v: Int64 }
        FN f(c: A) RETURNS Void
          REQUIRES c: VERSIONED | LOCKED
        ->
          WITH c AS a MATCH
            WHEN VERSIONED -> { x = 1; }
            WHEN LOCKED  -> { y = 2; }
          END
        END
      CHT
      expect { annotate(src) }.not_to raise_error
    end

    it "rejects WITH MATCH missing VERSIONED arm when REQUIRES has it" do
      src = <<~CHT
        STRUCT A { v: Int64 }
        FN f(c: A) RETURNS Void
          REQUIRES c: VERSIONED | LOCKED
        ->
          WITH c MATCH
            WHEN LOCKED -> { y = 2; }
          END
        END
      CHT
      expect { annotate(src) }.to raise_error(CompilerError, /missing.*VERSIONED/i)
    end

    it "rejects WITH MATCH with extra VERSIONED arm not in REQUIRES" do
      src = <<~CHT
        STRUCT A { v: Int64 }
        FN f(c: A) RETURNS Void
          REQUIRES c: LOCKED
        ->
          WITH c MATCH
            WHEN LOCKED  -> { y = 2; }
            WHEN VERSIONED -> { x = 1; }
          END
        END
      CHT
      expect { annotate(src) }.to raise_error(CompilerError, /VERSIONED.*not in REQUIRES/i)
    end
  end

  describe "family_of_arg classification (L3 family table)" do
    it "classifies a @versioned binding as :VERSIONED at the call-site check" do
      # Indirect test: a function with REQUIRES c: VERSIONED accepts a
      # call with a @versioned argument without raising.
      src = <<~CHT
        STRUCT A { v: Int64 }
        FN inner(c: A) RETURNS Void REQUIRES c: VERSIONED -> RETURN; END
        FN main() RETURNS Void ->
          c = A{ v: 0 } @versioned;
          inner(c);
          RETURN;
        END
      CHT
      expect { annotate(src) }.not_to raise_error
    end

    it "rejects calling a REQUIRES VERSIONED fn with a @locked argument" do
      src = <<~CHT
        STRUCT A { v: Int64 }
        FN inner(c: A) RETURNS Void REQUIRES c: VERSIONED -> RETURN; END
        FN main() RETURNS Void ->
          c = A{ v: 0 } @locked;
          inner(c);
          RETURN;
        END
      CHT
      expect { annotate(src) }.to raise_error(CompilerError, /family LOCKED.*not.*accepted/i)
    end
  end
end
