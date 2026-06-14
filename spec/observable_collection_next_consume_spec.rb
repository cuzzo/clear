# Gap H: NEXT on a `~T[]@set:observable` (DISTINCT collection) must
# linearly consume the binding. A second NEXT is UAF: the cleanup
# path destroys the StreamSet at scope exit and `materializeNext`
# already published the producer's finish.
require "rspec"
require_relative "../src/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../src/ast/ast" unless defined?(MIR::ReassignPlan)

RSpec.describe "NEXT on collection observable: linear consume" do
  def annotate(source)
    tokens = Lexer.new(source).tokenize
    ast = ClearParser.new(tokens, source).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  it "marks the binding moved on first NEXT (rejects double-NEXT)" do
    src = <<~CLEAR
      FN main() RETURNS Void ->
          gen: ~?Int64[] = BG STREAM {
              MUTABLE i: Int64 = 0_i64;
              WHILE i < 3_i64 DO YIELD i; i = i + 1_i64; END
          };
          running: ~Int64[]@set:observable = gen |> DISTINCT _;
          first  = NEXT running;
          second = NEXT running;
          RETURN;
      END
    CLEAR
    expect { annotate(src) }.to raise_error(CompilerError, /moved|consumed|already/i)
  end

  it "accepts a single NEXT" do
    src = <<~CLEAR
      FN main() RETURNS Void ->
          gen: ~?Int64[] = BG STREAM {
              MUTABLE i: Int64 = 0_i64;
              WHILE i < 3_i64 DO YIELD i; i = i + 1_i64; END
          };
          running: ~Int64[]@set:observable = gen |> DISTINCT _;
          final = NEXT running;
          RETURN;
      END
    CLEAR
    expect { annotate(src) }.not_to raise_error
  end
end
