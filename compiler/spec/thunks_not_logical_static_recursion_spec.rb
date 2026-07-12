require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/annotator" unless defined?(SemanticAnnotator)

# F1 (Tranche 3): EFFECTS REENTRANT:NOT_LOGICAL on a function that
# the call-graph proves is statically reachable from itself should
# be rejected at compile time, not at runtime.
#
# Today the runtime StackGuard catches re-entry on the live path
# (raises System UnexpectedRecursion). But if the static call-graph
# already shows `f -> f` directly OR_ELSE transitively, the contract is
# unkeepable: the runtime is guaranteed to fire on EVERY call. The
# user almost certainly meant `:THUNK` (handle the recursion) or
# `:MAX_DEPTH(N)` (bound it). Reject loudly with that nudge.

RSpec.describe "EFFECTS REENTRANT:NOT_LOGICAL static-recursion validation" do
  def annotate(source)
    tokens = Lexer.new(source).tokenize
    ast = ClearParser.new(tokens, source).parse
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)
    ast
  end

  it "rejects directly self-recursive NOT_LOGICAL" do
    # Tail-call shape avoids the BinaryOp type-checker (which would
    # reject `Int64 + !Int64` before our new check fires).
    expect {
      annotate(<<~CLEAR)
        FN f(n: Int64) RETURNS !Int64
          EFFECTS REENTRANT:NOT_LOGICAL ->
          RETURN f(n - 1_i64);
        END
        FN main() RETURNS Void -> _ = f(5_i64) OR_ELSE EXIT "boom"; RETURN; END
      CLEAR
    }.to raise_error(/NOT_LOGICAL on 'f'.*directly calls itself/i)
  end

  it "rejects mutually-recursive NOT_LOGICAL pair" do
    expect {
      annotate(<<~CLEAR)
        FN ping(n: Int64) RETURNS !Int64
          EFFECTS REENTRANT:NOT_LOGICAL ->
          RETURN pong(n - 1_i64);
        END
        FN pong(n: Int64) RETURNS !Int64
          EFFECTS REENTRANT:NOT_LOGICAL ->
          RETURN ping(n - 1_i64);
        END
        FN main() RETURNS Void -> _ = ping(5_i64) OR_ELSE EXIT "boom"; RETURN; END
      CLEAR
    }.to raise_error(/NOT_LOGICAL.*ping|reachable from itself/i)
  end

  it "accepts a non-recursive NOT_LOGICAL function" do
    expect {
      annotate(<<~CLEAR)
        FN apply(cb: FN(Int64) -> Int64, x: Int64) RETURNS !Int64
          EFFECTS REENTRANT:NOT_LOGICAL ->
          RETURN cb(x);
        END
        FN double(x: Int64) RETURNS Int64 -> RETURN x * 2; END
        FN main() RETURNS Void -> _ = apply(double, 7_i64) OR_ELSE EXIT "boom"; RETURN; END
      CLEAR
    }.not_to raise_error
  end

  it "error message points at :THUNK or :MAX_DEPTH(N) as the fix" do
    expect {
      annotate(<<~CLEAR)
        FN f(n: Int64) RETURNS !Int64
          EFFECTS REENTRANT:NOT_LOGICAL ->
          RETURN f(n - 1_i64);
        END
        FN main() RETURNS Void -> _ = f(5_i64) OR_ELSE EXIT "boom"; RETURN; END
      CLEAR
    }.to raise_error(/THUNK.*MAX_DEPTH|MAX_DEPTH.*THUNK/m)
  end
end
