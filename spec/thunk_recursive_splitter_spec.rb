require "rspec"
require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/ast/ast"
require_relative "../src/mir/thunk_transform"

# Thunk Phase 4c — RecursiveSplitter pattern detection. Detects the
# simple-recurrence shape (factorial / fibonacci-individual-call):
#
#   IF base_cond -> RETURN base_value;       -- 0 or more base cases
#   ...
#   RETURN combine_lhs <op> f(recurse_args); -- exactly one self-call
#
# Detection only -- Zig codegen lands in Phase 4d.

RSpec.describe "ThunkTransform::RecursiveSplitter.split" do
  def parse(source)
    tokens = Lexer.new(source).tokenize
    Parser.new(tokens, source).parse
  end

  def fn(ast, name)
    ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == name }
  end

  def split(source, fn_name)
    f = fn(parse(source), fn_name)
    ThunkTransform::RecursiveSplitter.split(f.body, f.name, nil)
  end

  describe "factorial-shape" do
    it "matches `IF base; RETURN n * f(n-1)`" do
      plan = split(<<~CLEAR, "factorial")
        FN factorial(n: Int64) RETURNS Int64 ->
          IF n <= 1 -> RETURN 1;
          RETURN n * factorial(n - 1);
        END
      CLEAR
      expect(plan).not_to be_nil
      expect(plan.base_cases.length).to eq(1)
      expect(plan.combine_op).to eq(:MUL)
      expect(plan.recurse_args.length).to eq(1)
    end

    it "matches with multiple base cases" do
      plan = split(<<~CLEAR, "f")
        FN f(n: Int64) RETURNS Int64 ->
          IF n == 0 -> RETURN 1;
          IF n == 1 -> RETURN 1;
          RETURN n * f(n - 1);
        END
      CLEAR
      expect(plan).not_to be_nil
      expect(plan.base_cases.length).to eq(2)
    end

    it "matches with the self-call on the LEFT of the operator" do
      plan = split(<<~CLEAR, "f")
        FN f(n: Int64) RETURNS Int64 ->
          IF n <= 0 -> RETURN 0;
          RETURN f(n - 1) + n;
        END
      CLEAR
      expect(plan).not_to be_nil
      expect(plan.combine_op).to eq(:ADD)
    end
  end

  describe "rejected shapes" do
    it "rejects a tail call (no combine op)" do
      # Tail-recursive shape -- handled by the existing TailCall MIR
      # path, not the THUNK splitter.
      plan = split(<<~CLEAR, "sum")
        FN sum(n: Int64, acc: Int64) RETURNS Int64 ->
          IF n <= 0 -> RETURN acc;
          RETURN sum(n - 1, acc + n);
        END
      CLEAR
      expect(plan).to be_nil
    end

    it "rejects two recursive calls in the final RETURN (fibonacci)" do
      plan = split(<<~CLEAR, "fib")
        FN fib(n: Int64) RETURNS Int64 ->
          IF n <= 1 -> RETURN n;
          RETURN fib(n - 1) + fib(n - 2);
        END
      CLEAR
      expect(plan).to be_nil
    end

    it "rejects a base case whose body has a self-call" do
      plan = split(<<~CLEAR, "f")
        FN f(n: Int64) RETURNS Int64 ->
          IF n <= 0 -> RETURN f(n + 1);
          RETURN n * f(n - 1);
        END
      CLEAR
      expect(plan).to be_nil
    end

    it "rejects body with statements between base cases and final RETURN" do
      # The simple-recurrence shape requires base cases first, then
      # the final RETURN with no statements between.
      plan = split(<<~CLEAR, "f")
        FN f(n: Int64) RETURNS Int64 ->
          IF n <= 0 -> RETURN 0;
          MUTABLE x = n + 1;
          RETURN n * f(n - 1);
        END
      CLEAR
      expect(plan).to be_nil
    end

    it "rejects a non-recurrence (no self-call at all)" do
      plan = split(<<~CLEAR, "f")
        FN f(n: Int64) RETURNS Int64 ->
          RETURN n + 1;
        END
      CLEAR
      expect(plan).to be_nil
    end

    it "rejects an unsupported operator" do
      plan = split(<<~CLEAR, "f")
        FN f(n: Int64) RETURNS Bool ->
          IF n <= 0 -> RETURN TRUE;
          RETURN n == f(n - 1);
        END
      CLEAR
      expect(plan).to be_nil
    end
  end
end

# Annotator-side reporting: the Phase 4b error is detection-aware
# now -- the message names whether the splitter recognized the
# shape so users can plan.
RSpec.describe "Phase 4c detection-aware error message" do
  def annotate(source)
    require_relative "../src/backends/transpiler"
    tokens = Lexer.new(source).tokenize
    ast = Parser.new(tokens, source).parse
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)
    ast
  end

  it "compiles cleanly (Phase 4d codegen) when the recurrence shape is recognized" do
    # Phase 4c stamps thunk_plan; Phase 4d's lower_function_def uses
    # it to synthesize a trampoline body, replacing what used to be
    # a hard error.
    expect {
      annotate(<<~CLEAR)
        FN factorial(n: Int64) RETURNS Int64
          EFFECTS REENTRANT:THUNK ->
          IF n <= 1 -> RETURN 1;
          RETURN n * factorial(n - 1);
        END
        FN main() RETURNS Void -> _ = factorial(5_i64); RETURN; END
      CLEAR
    }.not_to raise_error
  end

  it "names the unrecognized-shape message when the body is more complex" do
    expect {
      annotate(<<~CLEAR)
        FN fib(n: Int64) RETURNS Int64
          EFFECTS REENTRANT:THUNK ->
          IF n <= 1 -> RETURN n;
          RETURN fib(n - 1) + fib(n - 2);
        END
        FN main() RETURNS Void -> _ = fib(5_i64); RETURN; END
      CLEAR
    }.to raise_error(/this phase does not yet recognize/)
  end
end
