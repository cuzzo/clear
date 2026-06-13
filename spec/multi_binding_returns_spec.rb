require "rspec"
require_relative "../src/backends/transpiler"
require_relative "../src/ast/ast"

# Atomics M2.4 / M2.5: parser + lifetime-checker support for
# multi-binding `RETURNS (a b c):T` and the wildcard form
# `RETURNS *:T`.
#
# This spec covers BOTH directions of the audit matrix:
#   - POSITIVE cases: a return derivation that matches one of the
#     declared sources MUST compile.
#   - NEGATIVE cases: a return that doesn't match any of the
#     declared sources MUST error with a clear diagnostic.
#
# Particular attention to the user's flagged case: a function with
# multiple declared sources where the actual return derives from
# the WRONG one (matches one source's name but not the source the
# value actually comes from).
RSpec.describe "RETURNS (a b ...):T multi-binding lifetimes (M2.4 + M2.5)" do
  def parse(src)
    ClearParser.new(Lexer.new(src).tokenize, src).parse
  end

  def annotate(src)
    ast = parse(src)
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  def fn(ast, name = nil)
    ast.statements.find { |s| s.is_a?(AST::FunctionDef) && (name.nil? || s.name == name) }
  end

  describe "parser shape" do
    it "single-binding RETURNS foo:T parses as one-element Array" do
      ast = parse("FN identity(n: Float64) RETURNS n:Float64 -> RETURN n; END")
      rl = fn(ast).return_lifetime
      expect(rl).to be_a(Array)
      expect(rl.size).to eq(1)
      expect(rl.first.name).to eq("n")
    end

    it "multi-binding RETURNS (a b):T parses with space separation" do
      ast = parse("FN pickBest(a: Float64, b: Float64) RETURNS (a b):Float64 -> RETURN a; END")
      rl = fn(ast).return_lifetime
      expect(rl).to be_a(Array)
      expect(rl.size).to eq(2)
      expect(rl.map(&:name)).to eq(["a", "b"])
    end

    it "multi-binding RETURNS (a, b):T parses with comma separation" do
      ast = parse("FN pickBest(a: Float64, b: Float64) RETURNS (a, b):Float64 -> RETURN a; END")
      rl = fn(ast).return_lifetime
      expect(rl.map(&:name)).to eq(["a", "b"])
    end

    it "multi-binding accepts mixed comma/space (parser is permissive)" do
      ast = parse("FN pickBest(a: Float64, b: Float64, c: Float64) RETURNS (a, b c):Float64 -> RETURN a; END")
      expect(fn(ast).return_lifetime.map(&:name)).to eq(["a", "b", "c"])
    end

    it "wildcard RETURNS *:T parses as the :wildcard symbol" do
      ast = parse("FN whatever(a: Float64) RETURNS *:Float64 -> RETURN a; END")
      expect(fn(ast).return_lifetime).to eq(:wildcard)
    end
  end

  describe "annotator validation of declarations" do
    it "errors when a multi-binding source isn't a parameter" do
      expect {
        annotate(<<~CLEAR)
          FN identity(a: Float64, b: Float64) RETURNS (a, ghost):Float64 ->
            RETURN a;
          END
        CLEAR
      }.to raise_error(CompilerError, /Lifetime Error.*'ghost' is not a parameter/i)
    end

    it "accepts a multi-binding when all sources are parameters" do
      expect {
        annotate(<<~CLEAR)
          FN pickBest(a: Float64, b: Float64) RETURNS (a, b):Float64 ->
            RETURN a;
          END
        CLEAR
      }.not_to raise_error
    end

    it "wildcard form annotates without error (informational note only)" do
      expect {
        annotate(<<~CLEAR)
          FN lazy(a: Float64, b: Float64) RETURNS *:Float64 ->
            RETURN a;
          END
        CLEAR
      }.not_to raise_error
    end
  end

  describe "escape semantics — RETURN through one source" do
    it "POS: borrow derived from a-side source compiles" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Bar { v: Float64 }
          STRUCT Foo { b: Bar }
          FN pick(a: Foo, b: Foo) RETURNS (a, b):Bar ->
            RETURN a.b;
          END
        CLEAR
      }.not_to raise_error
    end

    it "POS: borrow derived from b-side source compiles" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Bar { v: Float64 }
          STRUCT Foo { b: Bar }
          FN pick(a: Foo, b: Foo) RETURNS (a, b):Bar ->
            RETURN b.b;
          END
        CLEAR
      }.not_to raise_error
    end
  end

  describe "escape semantics — partial match (user-flagged case)" do
    it "NEG: returning from a third param NOT in the lifetime list errors" do
      # Critical case: the function declares `RETURNS (a b):T` but
      # the return value derives from `c`. This is the "one parameter
      # has the right lifetime, but not the other" pattern -- the
      # checker has to walk the full sources list and verify the
      # actual derivation matches AT LEAST ONE source. Matching zero
      # sources = error.
      expect {
        annotate(<<~CLEAR)
          STRUCT Bar { v: Float64 }
          STRUCT Foo { b: Bar }
          FN pick(a: Foo, b: Foo, c: Foo) RETURNS (a, b):Bar ->
            RETURN c.b;
          END
        CLEAR
      }.to raise_error(CompilerError, /Expected return derived from one of: a \| b/m)
    end

    it "NEG: error message lists ALL sources so the user can see what was expected" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Bar { v: Float64 }
          STRUCT Foo { b: Bar }
          FN pick(a: Foo, b: Foo, c: Foo, d: Foo) RETURNS (a, b, c):Bar ->
            RETURN d.b;
          END
        CLEAR
      }.to raise_error(CompilerError, /a \| b \| c/m)
    end

    it "NEG: single-binding RETURNS still produces the v0.1 error format" do
      # Single-source case keeps the older "Expected return derived
      # from: <source>" wording (no `|`-list noise for one entry).
      expect {
        annotate(<<~CLEAR)
          STRUCT Bar { v: Float64 }
          STRUCT Foo { b: Bar }
          FN pick(a: Foo, b: Foo) RETURNS a:Bar ->
            RETURN b.b;
          END
        CLEAR
      }.to raise_error(CompilerError, /Expected return derived from: a/i)
    end
  end

  describe "escape semantics — wildcard" do
    it "POS: wildcard accepts derivation from any param" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Bar { v: Float64 }
          STRUCT Foo { b: Bar }
          FN pickAny(a: Foo, b: Foo, c: Foo) RETURNS *:Bar ->
            RETURN c.b;
          END
        CLEAR
      }.not_to raise_error
    end

    it "POS: wildcard with no param-derived borrow still compiles when
        the return is implicitly copyable (no lifetime needed)" do
      expect {
        annotate(<<~CLEAR)
          FN lazy(a: Float64, b: Float64) RETURNS *:Float64 ->
            RETURN a;
          END
        CLEAR
      }.not_to raise_error
    end
  end

  describe "field-path sources mix with multi-binding" do
    it "POS: multi-binding accepts field-path sources" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Inner { v: Float64 }
          STRUCT Outer { i: Inner }
          FN pick(a: Outer, b: Outer) RETURNS (a.i, b.i):Inner ->
            RETURN a.i;
          END
        CLEAR
      }.not_to raise_error
    end

    it "NEG: deriving from a sibling field of the declared path errors" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Inner { v: Float64 }
          STRUCT Outer { i: Inner, j: Inner }
          FN pick(a: Outer, b: Outer) RETURNS (a.i, b.i):Inner ->
            RETURN a.j;
          END
        CLEAR
      }.to raise_error(CompilerError, /Lifetime Error/i)
    end
  end
end
