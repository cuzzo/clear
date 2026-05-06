require "rspec"
require_relative "../src/backends/transpiler"

# A22: pin the behavior of nested observable pipes. Today the type
# system rejects every shape that would naturally express a "nested
# observable" because:
#   - A fold-pipe over a tense source produces a `~T` (tense) value.
#   - Tense values cannot be implicitly unwrapped into expressions.
#   - `WITH VIEW running AS s` is a statement-level binding, not an
#     expression, so it can't appear inside another fold-pipe's body.
#
# These tests document the failure modes so a future change to expression-
# level VIEW or implicit tense unwrap doesn't silently land a half-wired
# nested-observable shape.
RSpec.describe "A22: nested observable pipes" do
  def annotate(source)
    tokens = Lexer.new(source).tokenize
    ast = Parser.new(tokens, source).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  it "rejects an inner fold-pipe inside an outer fold-pipe terminal expression (type error)" do
    src = <<~CLEAR
      FN main() RETURNS Void ->
          g_outer: ~?Int64[] = BG STREAM {
              MUTABLE i: Int64 = 0_i64;
              WHILE i < 3_i64 DO YIELD i; i = i + 1_i64; END
          };
          g_inner: ~?Int64[] = BG STREAM {
              MUTABLE j: Int64 = 0_i64;
              WHILE j < 5_i64 DO YIELD j; j = j + 1_i64; END
          };
          outer: ~Int64@observable = g_outer |> SUM (_ + (g_inner |> SUM _));
          _ = NEXT outer;
          RETURN;
      END
    CLEAR
    # The inner pipe produces ~Int64 (tense observable); it can't be
    # added to a plain Int64 and the annotator's BinaryOp visitor
    # rejects with a type-mismatch.
    expect { annotate(src) }.to raise_error(CompilerError, /Cannot add types: Int64 and ~Int64/)
  end

  it "rejects WITH VIEW inside a fold-pipe expression (parser-level)" do
    src = <<~CLEAR
      FN main() RETURNS Void ->
          g: ~?Int64[] = BG STREAM {
              MUTABLE i: Int64 = 0_i64;
              WHILE i < 3_i64 DO YIELD i; i = i + 1_i64; END
          };
          inner_running: ~Int64@observable = g |> SUM _;
          outer: ~Int64@observable = g |> SUM (_ + WITH VIEW inner_running AS s s);
          _ = NEXT outer;
          RETURN;
      END
    CLEAR
    expect { annotate(src) }.to raise_error(/Unexpected token WITH/)
  end

  it "accepts sequential observables in the same scope (T14 — already pinned)" do
    src = <<~CLEAR
      FN main() RETURNS Void ->
          g1: ~?Int64[] = BG STREAM {
              MUTABLE i: Int64 = 0_i64;
              WHILE i < 4_i64 DO YIELD i; i = i + 1_i64; END
          };
          running_sum: ~Int64@observable = g1 |> SUM _;
          g2: ~?Int64[] = BG STREAM {
              MUTABLE j: Int64 = 0_i64;
              WHILE j < 4_i64 DO YIELD j; j = j + 1_i64; END
          };
          running_max: ~Int64@observable = g2 |> MAX _;
          a = NEXT running_sum;
          b = NEXT running_max;
          RETURN;
      END
    CLEAR
    expect { annotate(src) }.not_to raise_error
  end
end
