require "rspec"
require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/ast/ast"
require_relative "../src/backends/transpiler"

# Thunk Phase 4.1 / 4.2 -- call-site override syntax (parser-only).
#
# `@thunk(N) f(args)` and `@maxDepth(N) f(args)` are reserved at
# parse time; runtime semantics (per-call-site monomorphization
# of the callee with recursive-call rewriting) defer to v0.3.
# The annotator emits a precise "not yet implemented" diagnostic.

RSpec.describe "Thunk Phase 4.1/4.2 -- call-site override (parser-only)" do
  def parse(source)
    tokens = Lexer.new(source).tokenize
    Parser.new(tokens, source).parse
  end

  def annotate(source)
    ast = parse(source)
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  describe "parser" do
    it "accepts @thunk(N) before a call expression" do
      ast = parse(<<~CLEAR)
        FN factorial(n: Int64) RETURNS Int64
          EFFECTS REENTRANT ->
          IF n <= 1 -> RETURN 1;
          RETURN n * factorial(n - 1);
        END
        FN main() RETURNS Void ->
          x = @thunk(1000) factorial(5_i64);
          RETURN;
        END
      CLEAR
      main = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "main" }
      bind = main.body.first
      override = bind.respond_to?(:value) ? bind.value : nil
      expect(override).to be_a(AST::CallSiteOverride)
      expect(override.kind).to eq(:thunk)
      expect(override.n).to eq(1000)
    end

    it "accepts @maxDepth(N) before a call expression" do
      ast = parse(<<~CLEAR)
        FN f(n: Int64) RETURNS Int64 -> RETURN n + 1; END
        FN main() RETURNS Void ->
          x = @maxDepth(64) f(5_i64);
          RETURN;
        END
      CLEAR
      main = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "main" }
      bind = main.body.first
      override = bind.value
      expect(override).to be_a(AST::CallSiteOverride)
      expect(override.kind).to eq(:maxDepth)
      expect(override.n).to eq(64)
    end

    it "rejects N <= 0" do
      expect {
        parse(<<~CLEAR)
          FN f(n: Int64) RETURNS Int64 -> RETURN n; END
          FN main() RETURNS Void ->
            x = @thunk(0) f(5_i64);
            RETURN;
          END
        CLEAR
      }.to raise_error(/positive integer N/)
    end
  end

  describe "annotator (deferred-to-v0.3 diagnostic)" do
    it "@thunk(N) errors with the v0.3 forward-pointing message" do
      expect {
        annotate(<<~CLEAR)
          FN factorial(n: Int64) RETURNS Int64
            EFFECTS REENTRANT ->
            IF n <= 1 -> RETURN 1;
            RETURN n * factorial(n - 1);
          END
          FN main() RETURNS Void ->
            x = @thunk(1000) factorial(5_i64);
            RETURN;
          END
        CLEAR
      }.to raise_error(/@thunk\(1000\).*not yet implemented.*v0\.3/m)
    end

    it "the diagnostic recommends the function-side variant as a workaround" do
      expect {
        annotate(<<~CLEAR)
          FN f(n: Int64) RETURNS Int64 -> RETURN n; END
          FN main() RETURNS Void ->
            x = @maxDepth(64) f(5_i64);
            RETURN;
          END
        CLEAR
      }.to raise_error(/EFFECTS REENTRANT:MAX_DEPTH\(64\)/)
    end
  end
end
