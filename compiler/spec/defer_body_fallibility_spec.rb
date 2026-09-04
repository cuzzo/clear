require "rspec"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

# A DEFER body runs during scope teardown, where Zig's `defer` gives it no
# error channel -- so the body may not contain `try`. Owning a value is a
# different question: `list.pop()` moves an existing handle out and releases
# it with an infallible cleanup, which is legal inside a defer. The check
# must separate the two, or Ruby's `ensure stack.pop` has no translation.
RSpec.describe "DEFER body fallibility" do
  def transpile(src) = ZigTranspiler.new.transpile(src)

  it "rejects a fallible call in a DEFER body" do
    src = <<~CLEAR
      FN risky() RETURNS !Int64 ->
          RETURN 1_i64;
      END

      FN run() RETURNS !Int64 ->
          DEFER TRY (risky());
          RETURN 2_i64;
      END
    CLEAR
    expect { transpile(src) }.to raise_error(CompilerError, /DEFER body must be infallible/)
  end

  it "accepts a discarded pop of an owned element" do
    src = <<~CLEAR
      STRUCT Scope { depth: Int64 }
      STRUCT Session { scopes: []Scope@multiowned }

      FN with_new_scope(MUTABLE s: Session) RETURNS Int64 ->
          DEFER &s.scopes.pop();
          &s.scopes.append(Scope{ depth: s.scopes.length() } @multiowned);
          RETURN s.scopes.length();
      END
    CLEAR
    expect { transpile(src) }.not_to raise_error
  end
end
