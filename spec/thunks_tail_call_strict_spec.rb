require "rspec"
require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/ast/ast"
require_relative "../src/backends/transpiler"

# Thunk Phase 3 — `EFFECTS REENTRANT:TAIL_CALL` strictness in the
# annotator. Every recursive self-call inside a TAIL_CALL function
# MUST be the direct value of a RETURN node. Any other position --
# statement, nested expression inside a RETURN, body of a WHILE/FOR
# loop, etc. -- is a hard error.

RSpec.describe "TAIL_CALL strictness" do
  def annotate(source)
    tokens = Lexer.new(source).tokenize
    ast = ClearParser.new(tokens, source).parse
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)
    ast
  end

  it "accepts a clean tail-recursive function" do
    expect {
      annotate(<<~CLEAR)
        FN sum(n: Int64, acc: Int64) RETURNS Int64
          EFFECTS REENTRANT:TAIL_CALL ->
          IF n <= 0 -> RETURN acc;
          RETURN sum(n - 1, acc + n);
        END
        FN main() RETURNS Void -> _ = sum(10_i64, 0_i64); RETURN; END
      CLEAR
    }.not_to raise_error
  end

  it "accepts a tail call inside an IF then-branch (block form)" do
    expect {
      annotate(<<~CLEAR)
        FN sum(n: Int64, acc: Int64) RETURNS Int64
          EFFECTS REENTRANT:TAIL_CALL ->
          IF n > 0 THEN RETURN sum(n - 1, acc + n); END
          RETURN acc;
        END
        FN main() RETURNS Void -> _ = sum(10_i64, 0_i64); RETURN; END
      CLEAR
    }.not_to raise_error
  end

  it "rejects a non-tail self-call wrapped in a binary op" do
    # The IF branch has a tail call (blessed); the second RETURN wraps
    # a self-call in `+ 1`, which makes it non-tail.
    expect {
      annotate(<<~CLEAR)
        FN x(n: Int64) RETURNS Int64
          EFFECTS REENTRANT:TAIL_CALL ->
          IF n <= 0 -> RETURN x(0);
          RETURN x(n - 1) + 1;
        END
        FN main() RETURNS Void -> _ = x(5_i64); RETURN; END
      CLEAR
    }.to raise_error(/'x' is called in non-tail position/)
  end

  it "rejects a self-call in statement position" do
    expect {
      annotate(<<~CLEAR)
        FN walk(n: Int64) RETURNS Int64
          EFFECTS REENTRANT:TAIL_CALL ->
          IF n <= 0 -> RETURN walk(0);
          walk(n - 1);
          RETURN walk(n - 2);
        END
        FN main() RETURNS Void -> _ = walk(5_i64); RETURN; END
      CLEAR
    }.to raise_error(/'walk' is called in non-tail position/)
  end

  it "rejects a self-call inside a WHILE body" do
    expect {
      annotate(<<~CLEAR)
        FN loopy(n: Int64) RETURNS Int64
          EFFECTS REENTRANT:TAIL_CALL ->
          IF n <= 0 -> RETURN loopy(0);
          MUTABLE m: Int64 = n;
          WHILE m > 0 DO
            x = loopy(m - 1);
            m = m - 1;
          END
          RETURN loopy(n - 2);
        END
        FN main() RETURNS Void -> _ = loopy(5_i64); RETURN; END
      CLEAR
    }.to raise_error(/'loopy' is called in non-tail position/)
  end

  it "rejects when every self-call is wrapped in an expression" do
    # The function IS recursive but every recursive call is non-tail.
    # The "missing tail call" branch of the validator fires before the
    # per-call non-tail loop runs.
    expect {
      annotate(<<~CLEAR)
        FN noop(n: Int64) RETURNS Int64
          EFFECTS REENTRANT:TAIL_CALL ->
          IF n <= 0 -> RETURN 0;
          RETURN noop(n - 1) + 1;
        END
        FN main() RETURNS Void -> _ = noop(5_i64); RETURN; END
      CLEAR
    }.to raise_error(/requires at least one RETURN that directly calls 'noop'/)
  end

  it "rejects non-tail calls for inline EFFECTS REENTRANT:TAIL_CALL declarations" do
    expect {
      annotate(<<~CLEAR)
        FN sum(n: Int64, acc: Int64) RETURNS Int64 EFFECTS REENTRANT:TAIL_CALL ->
          IF n <= 0 -> RETURN sum(0, acc);
          RETURN sum(n - 1, acc) + 1;
        END
        FN main() RETURNS Void -> _ = sum(5_i64, 0_i64); RETURN; END
      CLEAR
    }.to raise_error(/'sum' is called in non-tail position/)
  end

  it "names the THUNK fallback in the error message" do
    expect {
      annotate(<<~CLEAR)
        FN x(n: Int64) RETURNS Int64
          EFFECTS REENTRANT:TAIL_CALL ->
          IF n <= 0 -> RETURN x(0);
          RETURN x(n - 1) + 1;
        END
        FN main() RETURNS Void -> _ = x(5_i64); RETURN; END
      CLEAR
    }.to raise_error(/declare ':THUNK' instead/)
  end
end
