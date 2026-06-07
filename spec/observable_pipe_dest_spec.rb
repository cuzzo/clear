require "rspec"

require_relative "../src/backends/transpiler"
require_relative "../src/ast/ast"

# Pipeline-terminal observable wiring (Commit 3): the annotator must
# accept the canonical user-facing form
#
#     running: ~Int64@observable = stream |> SUM _;
#
# without rejecting the assignment as a type mismatch. The pipe
# BinaryOp gets `observable_dest = true` so the MIR pipeline lowerers emit the
# accumulator-and-fiber codegen path.
RSpec.describe "observable pipe destination (Commit 3)" do
  def annotate(source)
    tokens = Lexer.new(source).tokenize
    ast = Parser.new(tokens, source).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  def find_pipe(ast)
    found = nil
    walk = lambda do |n|
      return unless n
      found = n if n.is_a?(AST::BinaryOp) && n.op == :SMOOTH
      n.each { |v| walk.call(v) if v.is_a?(Struct) || v.is_a?(Array) } if n.is_a?(Struct)
      n.each { |v| walk.call(v) } if n.is_a?(Array)
    end
    ast.statements.each { |s| walk.call(s) }
    found
  end

  # Innermost SUM/etc. pipe (where `observable_terminal` is stamped).
  # `find_pipe` returns the OUTERMOST smooth (e.g. `... |> COLLECT`),
  # which is fine for COLLECT-checks but wrong for terminal-stamps.
  def find_first_sum_pipe(ast)
    pipes = []
    walk = lambda do |n|
      return unless n
      if n.is_a?(AST::BinaryOp) && n.op == :SMOOTH &&
         (n.right.is_a?(AST::SumOp) || n.right.is_a?(AST::CountOp) ||
          n.right.is_a?(AST::MaxOp) || n.right.is_a?(AST::MinOp) ||
          n.right.is_a?(AST::AverageOp))
        pipes << n
      end
      n.each { |v| walk.call(v) if v.is_a?(Struct) || v.is_a?(Array) } if n.is_a?(Struct)
      n.each { |v| walk.call(v) } if n.is_a?(Array)
    end
    ast.statements.each { |s| walk.call(s) }
    pipes.first
  end

  it "accepts `running: ~Int64@observable = gen |> SUM _;` (no type-mismatch)" do
    src = <<~F
      FN main() RETURNS Void ->
          gen: ~?Int64[] = BG STREAM {
              MUTABLE i: Int64 = 0_i64;
              WHILE i < 100_i64 DO
                  YIELD i;
                  i = i + 1_i64;
              END
          };
          running: ~Int64@observable = gen |> SUM _;
          _ = NEXT running;
          RETURN;
      END
    F
    expect { annotate(src) }.not_to raise_error
  end

  it "stamps `observable_dest` on the pipe BinaryOp" do
    src = <<~F
      FN main() RETURNS Void ->
          gen: ~?Int64[] = BG STREAM {
              MUTABLE i: Int64 = 0_i64;
              WHILE i < 100_i64 DO
                  YIELD i;
                  i = i + 1_i64;
              END
          };
          running: ~Int64@observable = gen |> SUM _;
          _ = NEXT running;
          RETURN;
      END
    F
    pipe = find_pipe(annotate(src))
    expect(pipe).not_to be_nil
    expect(pipe.observable_terminal).to be true
    expect(pipe.observable_dest).to be true
  end

  it "stamps `observable_dest` even on inferred bindings (default-observable)" do
    # After the streaming-aggregates-default-observable pivot, a SUM
    # over a tense source produces ~Int64@observable regardless of
    # whether the LHS is annotated. The COLLECT pipe-terminal joins.
    src = <<~F
      FN main() RETURNS Void ->
          gen: ~?Int64[] = BG STREAM {
              MUTABLE i: Int64 = 0_i64;
              WHILE i < 4_i64 DO
                  YIELD i;
                  i = i + 1_i64;
              END
          };
          total = gen |> SUM _ |> COLLECT;
          _ = total;
          RETURN;
      END
    F
    # The first pipe BinaryOp the walker hits is the inner SUM
    # (which is what `observable_dest` is stamped on).
    pipe = find_first_sum_pipe(annotate(src))
    expect(pipe).not_to be_nil
    expect(pipe.observable_terminal).to be true
    expect(pipe.observable_dest).to be true
  end
end
