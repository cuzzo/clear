require "rspec"
require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/annotator"
require_relative "../src/backends/transpiler"

# Coverage for shared_call_capability_display (generic_analysis.rb:449-462).
# The method renders the per-arg sync portion of the
# "polymorphic @shared parameters... must use the same synchronization
# capability" error. Each branch of its `case t.sync` corresponds to a
# concrete sync family. The existing generics_spec only exercises
# `:locked` and `:write_locked`; this file fills the remaining variants
# (`:versioned`, `:atomic`) by calling a polymorphic SHARED-T fn with
# arg pairs that hit each branch.

RSpec.describe "polymorphic @shared sync-mismatch error display" do
  def annotate(src)
    tokens = Lexer.new(src).tokenize
    ast = ClearParser.new(tokens, src).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  it "reports `@shared:locked` vs `@shared:versioned`" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN merge(x: SHARED T, y: SHARED Z) RETURNS Int64
          REQUIRES x, y: LOCKED | VERSIONED
        ->
          RETURN 0;
        END
        FN main() RETURNS Void ->
          a = Counter{ value: 1 } @shared:locked;
          b = Counter{ value: 2 } @shared:versioned;
          n = merge(a, b);
          RETURN;
        END
      CLEAR
    }.to raise_error(CompilerError, /same synchronization capability.*@shared:locked.*@shared:versioned/m)
  end

  it "reports `@shared:versioned` vs `@shared:writeLocked`" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        STRUCT Toy { value: Int64 }
        FN merge(x: SHARED T, y: SHARED Z) RETURNS Int64
          REQUIRES x, y: VERSIONED | LOCKED
        ->
          RETURN 0;
        END
        FN main() RETURNS Void ->
          MUTABLE a = Counter{ value: 0 } @shared:versioned;
          b = Toy{ value: 1 } @shared:writeLocked;
          n = merge(a, b);
          RETURN;
        END
      CLEAR
    }.to raise_error(CompilerError, /same synchronization capability.*@shared:versioned.*@shared:writeLocked/m)
  end
end
