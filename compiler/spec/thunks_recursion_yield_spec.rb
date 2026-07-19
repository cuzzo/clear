require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/ast/ast" unless defined?(MIR::ReassignPlan)
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

# Recursion co-op yield: the compiler injects `rt.checkYield()` at
# the entry of every non-TIGHT recursive fn, mirroring the
# back-edge of every non-TIGHT WHILE loop. Same yield budget
# (4096 inline counter ticks) reused across both.

RSpec.describe "Recursion co-op yield + :TIGHT opt-out" do
  def parse(source)
    tokens = Lexer.new(source).tokenize
    ClearParser.new(tokens, source).parse
  end

  def annotate(source)
    ast = parse(source)
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  def fn_named(ast, name)
    ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == name }
  end

  describe "parser" do
    it "accepts EFFECTS REENTRANT:TIGHT alone (plain reentrant, no yield)" do
      ast = parse(<<~CLEAR)
        FN walk(n: Int64) RETURNS Int64
          EFFECTS REENTRANT:TIGHT ->
          IF n <= 0 -> RETURN 0;
          RETURN walk(n - 1);
        END
      CLEAR
      fn = fn_named(ast, "walk")
      expect(fn.effects_decl).to eq(:reentrant)
      expect(fn.tight_reentrance).to be true
    end

    it "accepts EFFECTS REENTRANT:TIGHT:TAIL_CALL" do
      ast = parse(<<~CLEAR)
        FN sum(n: Int64, acc: Int64) RETURNS Int64
          EFFECTS REENTRANT:TIGHT:TAIL_CALL ->
          IF n <= 0 -> RETURN acc;
          RETURN sum(n - 1, acc + n);
        END
      CLEAR
      fn = fn_named(ast, "sum")
      expect(fn.effects_decl).to eq(:reentrant_tail_call)
      expect(fn.tight_reentrance).to be true
    end

    it "accepts EFFECTS REENTRANT:TIGHT:THUNK" do
      ast = parse(<<~CLEAR)
        FN factorial(n: Int64) RETURNS Int64
          EFFECTS REENTRANT:TIGHT:THUNK ->
          IF n <= 1 -> RETURN 1;
          RETURN n * factorial(n - 1);
        END
      CLEAR
      fn = fn_named(ast, "factorial")
      expect(fn.effects_decl).to eq(:reentrant_thunk)
      expect(fn.tight_reentrance).to be true
    end

    it "rejects :TIGHT:NOT_LOGICAL (depth=1, TIGHT meaningless)" do
      expect {
        parse(<<~CLEAR)
          FN f(n: Int64) RETURNS !Int64
            EFFECTS REENTRANT:TIGHT:NOT_LOGICAL ->
            RETURN n;
          END
        CLEAR
      }.to raise_error(/:TIGHT:NOT_LOGICAL is invalid/)
    end

    it "rejects :TIGHT:MAX_DEPTH(N) (TIGHT is implied)" do
      expect {
        parse(<<~CLEAR)
          FN f(n: Int64) RETURNS !Int64
            EFFECTS REENTRANT:TIGHT:MAX_DEPTH(8) ->
            RETURN n;
          END
        CLEAR
      }.to raise_error(/:TIGHT:MAX_DEPTH is invalid/)
    end
  end

  describe "annotator: tight_reentrance flag" do
    it "is false by default for plain :reentrant" do
      ast = annotate(<<~CLEAR)
        FN f(n: Int64) RETURNS Int64
          EFFECTS REENTRANT ->
          IF n <= 0 -> RETURN 0;
          RETURN f(n - 1);
        END
        FN main() RETURNS Void ->
          p: ~Int64 = BG { @service -> f(5_i64); };
          _ = NEXT p;
          RETURN;
        END
      CLEAR
      fn = fn_named(ast, "f")
      expect(fn.tight_reentrance).to be_falsey
    end

    it "is implied true for :MAX_DEPTH(N) when N <= YIELD_BUDGET" do
      ast = annotate(<<~CLEAR)
        FN f(n: Int64) RETURNS !Int64
          EFFECTS REENTRANT:MAX_DEPTH(64) ->
          RETURN n + 1;
        END
        FN main() RETURNS Void -> _ = TRY f(0_i64); RETURN; END
      CLEAR
      fn = fn_named(ast, "f")
      expect(fn.tight_reentrance).to be true
    end

    it "is FALSE for :MAX_DEPTH(N) when N > YIELD_BUDGET (auto-yield injected)" do
      # YIELD_BUDGET = 4096; N = 8192 forces yield-on
      ast = annotate(<<~CLEAR)
        FN f(n: Int64) RETURNS !Int64
          EFFECTS REENTRANT:MAX_DEPTH(8192) ->
          RETURN n + 1;
        END
        FN main() RETURNS Void -> _ = TRY f(0_i64); RETURN; END
      CLEAR
      fn = fn_named(ast, "f")
      expect(fn.tight_reentrance).to be false
    end
  end

  # The post-bridge `tight_reentrance` flag is what mir_lowering and
  # ThunkTransform::Emit consume. These specs verify the flag is
  # set/unset correctly per variant; codegen verification is in the
  # corresponding transpile-tests + the existing build-time
  # `grep rt.checkYield` smoke check.
  describe "tight_reentrance flag drives codegen" do
    it "plain :reentrant defaults tight_reentrance=false (yield emitted)" do
      ast = annotate(<<~CLEAR)
        FN walk(n: Int64) RETURNS Int64
          EFFECTS REENTRANT ->
          IF n <= 0 -> RETURN 0;
          RETURN walk(n - 1);
        END
        FN main() RETURNS Void ->
          p: ~Int64 = BG { @service -> walk(5_i64); };
          _ = NEXT p;
          RETURN;
        END
      CLEAR
      expect(fn_named(ast, "walk").tight_reentrance).to be_falsey
    end

    it ":TIGHT plain :reentrant sets tight_reentrance=true (yield skipped)" do
      ast = annotate(<<~CLEAR)
        FN walk(n: Int64) RETURNS Int64
          EFFECTS REENTRANT:TIGHT ->
          IF n <= 0 -> RETURN 0;
          RETURN walk(n - 1);
        END
        FN main() RETURNS Void ->
          p: ~Int64 = BG { @service -> walk(5_i64); };
          _ = NEXT p;
          RETURN;
        END
      CLEAR
      expect(fn_named(ast, "walk").tight_reentrance).to be true
    end

    it ":TAIL_CALL defaults tight_reentrance=false" do
      ast = annotate(<<~CLEAR)
        FN sum(n: Int64, acc: Int64) RETURNS Int64
          EFFECTS REENTRANT:TAIL_CALL ->
          IF n <= 0 -> RETURN acc;
          RETURN sum(n - 1, acc + n);
        END
        FN main() RETURNS Void -> _ = sum(10_i64, 0_i64); RETURN; END
      CLEAR
      expect(fn_named(ast, "sum").tight_reentrance).to be_falsey
    end

    it ":TIGHT:TAIL_CALL sets tight_reentrance=true" do
      ast = annotate(<<~CLEAR)
        FN sum(n: Int64, acc: Int64) RETURNS Int64
          EFFECTS REENTRANT:TIGHT:TAIL_CALL ->
          IF n <= 0 -> RETURN acc;
          RETURN sum(n - 1, acc + n);
        END
        FN main() RETURNS Void -> _ = sum(10_i64, 0_i64); RETURN; END
      CLEAR
      expect(fn_named(ast, "sum").tight_reentrance).to be true
    end

    it ":THUNK defaults tight_reentrance=false" do
      ast = annotate(<<~CLEAR)
        FN factorial(n: Int64) RETURNS Int64
          EFFECTS REENTRANT:THUNK ->
          IF n <= 1 -> RETURN 1;
          RETURN n * factorial(n - 1);
        END
        FN main() RETURNS Void -> _ = factorial(5_i64); RETURN; END
      CLEAR
      expect(fn_named(ast, "factorial").tight_reentrance).to be_falsey
    end

    it ":TIGHT:THUNK sets tight_reentrance=true" do
      ast = annotate(<<~CLEAR)
        FN factorial(n: Int64) RETURNS Int64
          EFFECTS REENTRANT:TIGHT:THUNK ->
          IF n <= 1 -> RETURN 1;
          RETURN n * factorial(n - 1);
        END
        FN main() RETURNS Void -> _ = factorial(5_i64); RETURN; END
      CLEAR
      expect(fn_named(ast, "factorial").tight_reentrance).to be true
    end

    it ":NOT_LOGICAL is unaffected (TIGHT was rejected at parse time)" do
      ast = annotate(<<~CLEAR)
        FN apply(cb: FN(Int64) -> Int64, x: Int64) RETURNS !Int64
          EFFECTS REENTRANT:NOT_LOGICAL ->
          RETURN cb(x);
        END
        FN double(x: Int64) RETURNS Int64 -> RETURN x * 2; END
        FN main() RETURNS Void ->
          _ = apply(double, 7_i64) OR_ELSE EXIT System, "x";
          RETURN;
        END
      CLEAR
      # tight_reentrance not set; mir_lowering's needs_recursion_yield?
      # excludes :NOT_LOGICAL anyway (depth=1 by assertion).
      expect(fn_named(ast, "apply").tight_reentrance).to be_falsey
    end
  end
end
