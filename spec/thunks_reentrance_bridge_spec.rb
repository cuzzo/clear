require "rspec"
require "set"
require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/ast/ast"
require_relative "../src/backends/transpiler"
require_relative "../src/annotator-helpers/reentrance"

# Thunk Phase 1.3 — annotator bridge that unifies the legacy
# `@reentrant` annotation and the new `EFFECTS REENTRANT[:VARIANT]`
# clause into a single canonical `fn_node.reentrance_kind` field,
# and validates `REQUIRES <name>: NON_REENTRANT` clauses against
# the parameter list.
#
# Spec covers the mapping rules and parameter-name validation.
# Errors that depend on call-graph state (e.g. propagating
# REENTRANT_PLAIN through transitive callees) are out of scope here
# — that's Phase 2.

RSpec.describe "ReentranceBridge" do
  def annotated(source)
    tokens = Lexer.new(source).tokenize
    ast = Parser.new(tokens, source).parse
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)
    ast
  end

  def fn(ast, name)
    ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == name }
  end

  describe "canonical reentrance_kind" do
    it "is nil when no declaration is present" do
      ast = annotated(<<~CLEAR)
        FN main() RETURNS Void ->
          RETURN;
        END
      CLEAR
      expect(fn(ast, "main").reentrance_kind).to be_nil
    end

    it "is :reentrant for `EFFECTS REENTRANT`" do
      ast = annotated(<<~CLEAR)
        FN walk(n: Int64) RETURNS Void
          EFFECTS REENTRANT ->
          IF n <= 0 -> RETURN;
          walk(n - 1);
        END
        FN main() RETURNS Void -> walk(3); RETURN; END
      CLEAR
      expect(fn(ast, "walk").reentrance_kind).to eq(:reentrant)
    end

    it "is :reentrant_thunk for `EFFECTS REENTRANT:THUNK`" do
      # Phase 4b only handles tail-recursive :THUNK; use a tail-recursive
      # accumulator-style sum here so the bridge doesn't reject.
      ast = annotated(<<~CLEAR)
        FN sum(n: Int64, acc: Int64) RETURNS Int64
          EFFECTS REENTRANT:THUNK ->
          IF n <= 0 -> RETURN acc;
          RETURN sum(n - 1, acc + n);
        END
        FN main() RETURNS Void -> _ = sum(10, 0); RETURN; END
      CLEAR
      expect(fn(ast, "sum").reentrance_kind).to eq(:reentrant_thunk)
    end

    it "is :reentrant_tail_call for `EFFECTS REENTRANT:TAIL_CALL`" do
      ast = annotated(<<~CLEAR)
        FN sum(n: Int64, acc: Int64) RETURNS Int64
          EFFECTS REENTRANT:TAIL_CALL ->
          IF n <= 0 -> RETURN acc;
          RETURN sum(n - 1, acc + n);
        END
        FN main() RETURNS Void -> _ = sum(10, 0); RETURN; END
      CLEAR
      expect(fn(ast, "sum").reentrance_kind).to eq(:reentrant_tail_call)
    end

    it "is :reentrant for legacy @reentrant" do
      ast = annotated(<<~CLEAR)
        FN walk(n: Int64) RETURNS Void @reentrant ->
          IF n <= 0 -> RETURN;
          walk(n - 1);
        END
        FN main() RETURNS Void -> walk(3); RETURN; END
      CLEAR
      expect(fn(ast, "walk").reentrance_kind).to eq(:reentrant)
    end

    it "is :reentrant_tail_call for legacy @reentrant:tailCall" do
      ast = annotated(<<~CLEAR)
        FN sum(n: Int64, acc: Int64) RETURNS Int64 @reentrant:tailCall ->
          IF n <= 0 -> RETURN acc;
          RETURN sum(n - 1, acc + n);
        END
        FN main() RETURNS Void -> _ = sum(10, 0); RETURN; END
      CLEAR
      expect(fn(ast, "sum").reentrance_kind).to eq(:reentrant_tail_call)
    end
  end

  describe "legacy attr back-fill" do
    it "fills fn_node.reentrant when EFFECTS REENTRANT is declared" do
      ast = annotated(<<~CLEAR)
        FN walk(n: Int64) RETURNS Void
          EFFECTS REENTRANT ->
          IF n <= 0 -> RETURN;
          walk(n - 1);
        END
        FN main() RETURNS Void -> walk(1); RETURN; END
      CLEAR
      expect(fn(ast, "walk").reentrant).to eq(:reentrant)
    end

    it "fills both fn_node.reentrant AND tail_call for EFFECTS REENTRANT:TAIL_CALL" do
      ast = annotated(<<~CLEAR)
        FN sum(n: Int64, acc: Int64) RETURNS Int64
          EFFECTS REENTRANT:TAIL_CALL ->
          IF n <= 0 -> RETURN acc;
          RETURN sum(n - 1, acc + n);
        END
        FN main() RETURNS Void -> _ = sum(10, 0); RETURN; END
      CLEAR
      f = fn(ast, "sum")
      expect(f.reentrant).to eq(:reentrant)
      expect(f.tail_call).to be(true)
    end

    it "leaves legacy attrs nil when there is no declaration" do
      ast = annotated(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END
      CLEAR
      f = fn(ast, "main")
      expect(f.reentrant).to be_nil
      expect(f.tail_call).to be_falsey
    end
  end

  describe "REQUIRES validation" do
    it "accepts a clause that names a real parameter" do
      expect {
        annotated(<<~CLEAR)
          FN apply(f: FN(Int64) -> Int64, x: Int64) RETURNS !Int64
            REQUIRES f: NON_REENTRANT ->
            RETURN f(x);
          END
          FN main() RETURNS Void -> RETURN; END
        CLEAR
      }.not_to raise_error
    end

    it "rejects a clause that names a non-parameter binding" do
      expect {
        annotated(<<~CLEAR)
          FN apply(f: FN(Int64) -> Int64, x: Int64) RETURNS Int64
            REQUIRES g: NON_REENTRANT ->
            RETURN f(x);
          END
          FN main() RETURNS Void -> RETURN; END
        CLEAR
      }.to raise_error(/'g' is not a parameter of 'apply'/)
    end
  end
end
