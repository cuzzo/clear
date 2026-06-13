require "rspec"
require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/ast/ast"
require_relative "../src/backends/transpiler"

# `@canSmash` is parsed but blocked at compile time. The runtime
# has stack-hysteresis page-guards to soft-detect fiber overflow,
# but the compiler does not yet wire that feature on. The user
# is directed to `@service` (OS-thread, 2 MB pre-allocation) until
# v0.3 lights up the runtime support.

RSpec.describe "@canSmash deferred-to-v0.3 diagnostic" do
  def annotate(source)
    tokens = Lexer.new(source).tokenize
    ast = ClearParser.new(tokens, source).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  it "BG { @canSmash -> ... } errors with the v0.3 message" do
    expect {
      annotate(<<~CLEAR)
        FN main() RETURNS Void ->
          p: ~Int64 = BG { @canSmash -> 7_i64; };
          _ = NEXT p;
          RETURN;
        END
      CLEAR
    }.to raise_error(/`@canSmash`.*not yet supported.*v0\.3/m)
  end

  it "the message names @service as the workaround" do
    expect {
      annotate(<<~CLEAR)
        FN main() RETURNS Void ->
          p: ~Int64 = BG { @canSmash -> 7_i64; };
          _ = NEXT p;
          RETURN;
        END
      CLEAR
    }.to raise_error(/@service/)
  end

  it "the message acknowledges the runtime stack-hysteresis exists" do
    expect {
      annotate(<<~CLEAR)
        FN main() RETURNS Void ->
          p: ~Int64 = BG { @canSmash -> 7_i64; };
          _ = NEXT p;
          RETURN;
        END
      CLEAR
    }.to raise_error(/stack-hysteresis|page-guard/)
  end

  it "DO branches with @canSmash also error" do
    expect {
      annotate(<<~CLEAR)
        FN noop() RETURNS Int64 -> RETURN 7; END
        FN main() RETURNS Void ->
          DO { @canSmash -> noop() }
          RETURN;
        END
      CLEAR
    }.to raise_error(/`@canSmash`.*not yet supported/)
  end

  it "@<size>:canSmash combinations error too (canSmash dominates)" do
    expect {
      annotate(<<~CLEAR)
        FN main() RETURNS Void ->
          p: ~Int64 = BG { @micro:canSmash -> 7_i64; };
          _ = NEXT p;
          RETURN;
        END
      CLEAR
    }.to raise_error(/`@canSmash`.*not yet supported/)
  end

  it "BG without @canSmash compiles fine" do
    expect {
      annotate(<<~CLEAR)
        FN main() RETURNS Void ->
          p: ~Int64 = BG { 7_i64; };
          _ = NEXT p;
          RETURN;
        END
      CLEAR
    }.not_to raise_error
  end
end
