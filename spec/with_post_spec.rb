require "rspec"
require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/annotator"
require_relative "../src/backends/transpiler"

RSpec.describe "DEBUG_POST clauses on function signatures" do
  def parse(src)
    tokens = Lexer.new(src).tokenize
    Parser.new(tokens, src).parse
  end

  def annotate(src)
    ast = parse(src)
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  describe "parser" do
    it "leaves post_clauses nil when no DEBUG_POST is given" do
      ast = parse(<<~CLEAR)
        FN foo(x: Int64) RETURNS Int64 ->
          RETURN x;
        END
      CLEAR
      fn = ast.statements.first
      expect(fn.post_clauses).to be_nil
    end

    it "parses a single DEBUG_POST clause after RETURNS" do
      ast = parse(<<~CLEAR)
        FN foo(x: Int64) RETURNS Int64
          DEBUG_POST: result == x * 2
        ->
          RETURN x * 2;
        END
      CLEAR
      fn = ast.statements.first
      expect(fn.post_clauses.length).to eq(1)
      entry = fn.post_clauses.first
      expect(entry[:expr]).to be_a(AST::BinaryOp)
      expect(entry[:source]).to eq("result == x * 2")
    end

    it "parses multiple DEBUG_POST clauses" do
      ast = parse(<<~CLEAR)
        FN foo(x: Int64) RETURNS Int64
          DEBUG_POST: result >= 0
          DEBUG_POST: result == x * 2
        ->
          RETURN x * 2;
        END
      CLEAR
      fn = ast.statements.first
      expect(fn.post_clauses.length).to eq(2)
    end

    it "parses PRE and DEBUG_POST together (PRE before POST)" do
      ast = parse(<<~CLEAR)
        FN foo(x: Int64) RETURNS !Int64
          PRE: x > 0
          DEBUG_POST: result > x
        ->
          RETURN x * 2;
        END
      CLEAR
      fn = ast.statements.first
      expect(fn.pre_clauses.length).to eq(1)
      expect(fn.post_clauses.length).to eq(1)
    end
  end

  describe "annotator: validation" do
    it "accepts a Bool predicate over result and parameters" do
      expect {
        annotate(<<~CLEAR)
          FN foo(x: Int64) RETURNS Int64
            DEBUG_POST: result == x * 2
          ->
            RETURN x * 2;
          END
        CLEAR
      }.not_to raise_error
    end

    it "does NOT require an error-union return type (panic semantics)" do
      expect {
        annotate(<<~CLEAR)
          FN double(x: Int64) RETURNS Int64
            DEBUG_POST: result >= x
          ->
            RETURN x * 2;
          END
        CLEAR
      }.not_to raise_error
    end

    it "rejects a non-Bool DEBUG_POST expression" do
      expect {
        annotate(<<~CLEAR)
          FN foo(x: Int64) RETURNS Int64
            DEBUG_POST: result
          ->
            RETURN x;
          END
        CLEAR
      }.to raise_error(CompilerError, /DEBUG_POST expression must return Bool/)
    end

    it "rejects DEBUG_POST references to symbols outside params/result" do
      expect {
        annotate(<<~CLEAR)
          FN foo(x: Int64) RETURNS Int64
            DEBUG_POST: y == x
          ->
            RETURN x;
          END
        CLEAR
      }.to raise_error(CompilerError,
        /DEBUG_POST clauses may only reference function parameters or 'result'.*'y'/m)
    end

    it "accepts TRUE / FALSE in a DEBUG_POST predicate" do
      expect {
        annotate(<<~CLEAR)
          FN foo(x: Int64) RETURNS Int64
            DEBUG_POST: TRUE
          ->
            RETURN x;
          END
        CLEAR
      }.not_to raise_error
    end

    it "rejects DEBUG_POST that calls a fallible function (impure)" do
      expect {
        annotate(<<~CLEAR)
          FN check?(x: Int64) RETURNS !Bool ->
            IF x < 0 THEN RAISE Input, BadInput, "negative"; END
            RETURN TRUE;
          END
          FN foo(x: Int64) RETURNS Int64
            DEBUG_POST: check?(x)
          ->
            RETURN x;
          END
        CLEAR
      }.to raise_error(CompilerError, /DEBUG_POST clauses must be pure.*can fail/m)
    end

    it "rejects DEBUG_POST + CATCH on the same function with a clean CLEAR error" do
      expect {
        annotate(<<~CLEAR)
          FN foo(x: Int64) RETURNS !Int64
            DEBUG_POST: result >= 0
          ->
            RETURN x;
          CATCH BadInput
            RETURN 0;
          END
        CLEAR
      }.to raise_error(CompilerError,
        /DEBUG_POST clauses cannot be combined with CATCH.*Split into two functions/m)
    end

    it "rejects DEBUG_POST referencing a synchronized parameter" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Counter { value: Int64 }
          FN bump!(c: Counter) RETURNS Int64
            REQUIRES c: LOCKED
            DEBUG_POST: result > c.value
          ->
            WITH EXCLUSIVE c AS x { x.value = x.value + 1; }
            RETURN 1;
          END
        CLEAR
      }.to raise_error(CompilerError,
        /DEBUG_POST cannot reference synchronized parameter 'c'.*runs after.*locks have been released/m)
    end
  end

  describe "lowering" do
    def transpile(src)
      ZigTranspiler.new.transpile(src)
    end

    it "wraps every panic call in `if (@import(\"builtin\").mode == .Debug)`" do
      # Release-build elision smoke test. Zig's comptime constant
      # folding eliminates the entire if-block in non-debug builds,
      # so verifying the wrapper structure is sufficient — the panic
      # never reaches LLVM's codegen for ReleaseFast / ReleaseSmall.
      zig = transpile(<<~CLEAR)
        FN double(x: Int64) RETURNS Int64
          DEBUG_POST: result == x * 2
        ->
          RETURN x * 2;
        END
      CLEAR
      expect(zig).to include('if (@import("builtin").mode == .Debug)')
      panic_idx = zig.index('@panic("DEBUG_POST failed: result == x * 2")')
      expect(panic_idx).not_to be_nil
      # The @panic must lie INSIDE the gated block — there must be an
      # `if (@import("builtin").mode == .Debug)` between the start of
      # the wrapper body and the @panic call.
      gate_idx = zig.index('if (@import("builtin").mode == .Debug)')
      expect(gate_idx).to be < panic_idx
    end

    it "synthesizes inner/outer fn pair for POST-having functions" do
      zig = transpile(<<~CLEAR)
        FN sq(x: Int64) RETURNS Int64
          DEBUG_POST: result >= 0
        ->
          RETURN x * x;
        END
      CLEAR
      # Inner private fn: __sq_post_body. Outer public fn: sq.
      expect(zig).to match(/fn __sq_post_body\(/)
      expect(zig).to match(/(?:pub )?fn sq\(/)
    end

    it "supports nested-call DEBUG_POST chains (caller and callee both have POSTs)" do
      # caller -> mid -> base; each has DEBUG_POST. Outer wrappers
      # nest cleanly: each level calls the inner of the level below
      # via the outer wrapper, so each level's POST runs at its own
      # exit. No panic-confusion or stack-trace mangling.
      expect {
        annotate(<<~CLEAR)
          FN base(x: Int64) RETURNS Int64
            DEBUG_POST: result >= 0
          ->
            RETURN x * x;
          END
          FN mid(x: Int64) RETURNS Int64
            DEBUG_POST: result >= 0
          ->
            RETURN base(x) + 1;
          END
          FN top(x: Int64) RETURNS Int64
            DEBUG_POST: result > 0
          ->
            RETURN mid(x);
          END
          FN main() RETURNS !Void ->
            v = top(3);
            ASSERT v == 10, "3*3 + 1 == 10";
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end
  end
end
