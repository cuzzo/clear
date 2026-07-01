require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/annotator" unless defined?(SemanticAnnotator)

# F2 (Tranche 3): calling a recursive function (THUNK / TAIL_CALL /
# plain REENTRANT / MAX_DEPTH) from inside a WITH lock body is a
# yield-while-held violation. The trampoline (or the prologue check
# emitted by mir_lowering) fires `rt.checkYield()` which gives the
# scheduler a chance to preempt the fiber while it still holds the
# lock -- the classic deadlock setup.
#
# The existing P3.3 check (hold-lock-across-yield) inspects callee
# effects for YIELD; the fix is to seed YIELD onto recursive fns
# whose codegen injects `rt.checkYield()` (every kind except TIGHT
# and NOT_LOGICAL).

RSpec.describe "Recursion-yield + WITH lock (P3.3 propagation)" do
  def annotate(source)
    tokens = Lexer.new(source).tokenize
    ast = ClearParser.new(tokens, source).parse
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)
    ast
  end

  it "rejects calling a :THUNK fn from inside a WITH lock body" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }

        FN factorial(n: Int64) RETURNS Int64
          EFFECTS REENTRANT:THUNK ->
          IF n <= 1 -> RETURN 1;
          RETURN n * factorial(n - 1);
        END

        FN main() RETURNS Void ->
          c1 = Counter{ value: 0_i64 } @locked;
          WITH EXCLUSIVE c1 AS inner {
            _ = factorial(5_i64);
          }
          RETURN;
        END
      CLEAR
    }.to raise_error(/Hold-lock-across-yield.*factorial/i)
  end

  it "rejects calling a plain :REENTRANT fn from inside WITH" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }

        FN recur(n: Int64) RETURNS Int64
          EFFECTS REENTRANT ->
          IF n <= 0 -> RETURN 0;
          RETURN recur(n - 1);
        END

        FN main() RETURNS Void ->
          c1 = Counter{ value: 0_i64 } @locked;
          WITH EXCLUSIVE c1 AS inner {
            _ = recur(5_i64);
          }
          RETURN;
        END
      CLEAR
    }.to raise_error(/Hold-lock-across-yield.*recur/i)
  end

  it "rejects calling a :MAX_DEPTH(N>BUDGET) fn from inside WITH" do
    # MAX_DEPTH(N) with N <= 4096 (RECURSION_YIELD_BUDGET) is
    # implicitly TIGHT -- the bounded depth means the scheduler
    # can't stall, so no yield is injected. Use N > BUDGET to
    # force yield emission, which P3.3 must then reject.
    expect {
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }

        FN bounded(n: Int64) RETURNS !Int64
          EFFECTS REENTRANT:MAX_DEPTH(8192) ->
          RETURN n + 1_i64;
        END

        FN main() RETURNS Void ->
          c1 = Counter{ value: 0_i64 } @locked;
          WITH EXCLUSIVE c1 AS inner {
            _ = bounded(5_i64) OR EXIT "boom";
          }
          RETURN;
        END
      CLEAR
    }.to raise_error(/Hold-lock-across-yield.*bounded/i)
  end

  it "accepts calling a :MAX_DEPTH(N<=BUDGET) fn from inside WITH (TIGHT-implied)" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }

        FN bounded(n: Int64) RETURNS !Int64
          EFFECTS REENTRANT:MAX_DEPTH(64) ->
          RETURN n + 1_i64;
        END

        FN main() RETURNS Void ->
          c1 = Counter{ value: 0_i64 } @locked;
          WITH EXCLUSIVE c1 AS inner {
            _ = bounded(5_i64) OR EXIT "boom";
          }
          RETURN;
        END
      CLEAR
    }.not_to raise_error
  end

  it "accepts calling a :TIGHT:THUNK fn from inside WITH (no yield emitted)" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }

        FN factorial(n: Int64) RETURNS Int64
          EFFECTS REENTRANT:TIGHT:THUNK ->
          IF n <= 1 -> RETURN 1;
          RETURN n * factorial(n - 1);
        END

        FN main() RETURNS Void ->
          c1 = Counter{ value: 0_i64 } @locked;
          WITH EXCLUSIVE c1 AS inner {
            _ = factorial(5_i64);
          }
          RETURN;
        END
      CLEAR
    }.not_to raise_error
  end

  it "accepts calling a :NOT_LOGICAL fn from inside WITH (StackGuard doesn't yield)" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }

        FN apply(cb: FN(Int64) -> Int64, x: Int64) RETURNS !Int64
          EFFECTS REENTRANT:NOT_LOGICAL ->
          RETURN cb(x);
        END

        FN doubler(n: Int64) RETURNS Int64 -> RETURN n * 2; END

        FN main() RETURNS Void ->
          c1 = Counter{ value: 0_i64 } @locked;
          WITH EXCLUSIVE c1 AS inner {
            _ = apply(doubler, 5_i64) OR EXIT "boom";
          }
          RETURN;
        END
      CLEAR
    }.not_to raise_error
  end
end
