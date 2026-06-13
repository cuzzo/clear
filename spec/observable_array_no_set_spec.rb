# C4: `~T[]@observable` (without `@set`) was silently miscompiling
# (fell through to promise_list path emitting ArrayList(Promise(T))).
# The annotator now rejects it explicitly.
require "rspec"
require_relative "../src/backends/transpiler"
require_relative "../src/ast/ast"

RSpec.describe "C4: ~T[]@observable without :set is rejected" do
  def annotate(source)
    tokens = Lexer.new(source).tokenize
    ast = ClearParser.new(tokens, source).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  it "rejects ~Int64[]@observable without :set" do
    src = <<~CLEAR
      FN main() RETURNS Void ->
          gen: ~?Int64[] = BG STREAM {
              MUTABLE i: Int64 = 0_i64;
              WHILE i < 4_i64 DO YIELD i; i = i + 1_i64; END
          };
          running: ~Int64[]@observable = gen |> DISTINCT _;
          _ = NEXT running;
          RETURN;
      END
    CLEAR
    expect { annotate(src) }.to raise_error(CompilerError, /@observable on `T\[\]` requires `@set`/)
  end

  it "accepts ~Int64[]@set:observable (the canonical DISTINCT shape)" do
    src = <<~CLEAR
      FN main() RETURNS Void ->
          gen: ~?Int64[] = BG STREAM {
              MUTABLE i: Int64 = 0_i64;
              WHILE i < 4_i64 DO YIELD i; i = i + 1_i64; END
          };
          running: ~Int64[]@set:observable = gen |> DISTINCT _;
          final = NEXT running;
          RETURN;
      END
    CLEAR
    expect { annotate(src) }.not_to raise_error
  end
end
