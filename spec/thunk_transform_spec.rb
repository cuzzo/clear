require "rspec"
require_relative "../src/mir/thunk_transform"
require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/ast/ast"
require_relative "../src/backends/transpiler"

# Thunk Phase 4a — scaffolding for the THUNK CPS transform plus
# validation that `EFFECTS REENTRANT:THUNK` requires self-recursion
# (analogous to ':TAIL_CALL').
#
# The transform itself currently returns nil for every input;
# subsequent commits land the actual CPS lowering. This spec covers:
#   - the module + submodule files load
#   - the validation rejects non-recursive :THUNK declarations
#   - the validation accepts directly-recursive :THUNK declarations
#   - `transform` returns nil today (placeholder for Phase 4b+)

RSpec.describe "ThunkTransform scaffolding" do
  describe "module structure" do
    it "loads ThunkTransform" do
      expect(defined?(ThunkTransform)).to eq("constant")
    end

    it "loads ThunkTransform::Segments" do
      expect(defined?(ThunkTransform::Segments)).to eq("constant")
    end

    it "loads ThunkTransform::RecursiveSplitter" do
      expect(defined?(ThunkTransform::RecursiveSplitter)).to eq("constant")
    end

    it "loads ThunkTransform::Emit" do
      expect(defined?(ThunkTransform::Emit)).to eq("constant")
    end

    it "exposes Segment + tail variants" do
      expect(ThunkTransform::Segments::Segment).to be_a(Class)
      expect(ThunkTransform::Segments::Done).to be_a(Class)
      expect(ThunkTransform::Segments::Goto).to be_a(Class)
      expect(ThunkTransform::Segments::CondBranch).to be_a(Class)
      expect(ThunkTransform::Segments::RecurseTail).to be_a(Class)
      expect(ThunkTransform::Segments::RecurseStep).to be_a(Class)
    end
  end

  describe "transform entry" do
    it "returns nil today (Phase 4a placeholder)" do
      fake_fn = Struct.new(:reentrance_kind).new(:reentrant_thunk)
      expect(ThunkTransform.transform(fake_fn, nil)).to be_nil
    end

    it "returns nil for non-thunk functions regardless of body shape" do
      fake_fn = Struct.new(:reentrance_kind).new(:reentrant)
      expect(ThunkTransform.transform(fake_fn, nil)).to be_nil
    end
  end

  # Tranche 1 guardrail: today's heap-CPS trampoline only frees child
  # Frames on the normal-return path. The simple-recurrence splitter
  # plus the type checker keep the body non-fallible (a `RETURN <lhs>
  # <op> self_call(args)` shape rejects fallible operands), but a
  # future Phase 4 extension could relax that. The guard fails loudly
  # if ret_zig is fallible so the leak can't ship silently.
  describe "non-fallible body invariant (assert_non_fallible_ret!)" do
    let(:fake_fn) { Struct.new(:name).new("deep") }

    it "passes for plain integer return types" do
      expect {
        ThunkTransform::Emit.assert_non_fallible_ret!(fake_fn, "i64")
      }.not_to raise_error
    end

    it "passes for void return type" do
      expect {
        ThunkTransform::Emit.assert_non_fallible_ret!(fake_fn, "void")
      }.not_to raise_error
    end

    it "raises a directed error message when ret_zig is fallible" do
      expect {
        ThunkTransform::Emit.assert_non_fallible_ret!(fake_fn, "!i64")
      }.to raise_error(/THUNK trampoline.*'deep'.*fallible/)
    end

    it "names the helpers a future maintainer must extend" do
      expect {
        ThunkTransform::Emit.assert_non_fallible_ret!(fake_fn, "!i64")
      }.to raise_error(/emit_trampoline.*emit_mutual_trampoline.*errdefer/m)
    end
  end
end

RSpec.describe "EFFECTS REENTRANT:THUNK validation" do
  def annotate(source)
    tokens = Lexer.new(source).tokenize
    ast = Parser.new(tokens, source).parse
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)
    ast
  end

  it "accepts a tail-recursive :THUNK function" do
    # Phase 4b only handles tail-recursive :THUNK; the non-tail case
    # (factorial without an accumulator) errors with a Phase 4c hint.
    expect {
      annotate(<<~CLEAR)
        FN sum(n: Int64, acc: Int64) RETURNS Int64
          EFFECTS REENTRANT:THUNK ->
          IF n <= 0 -> RETURN acc;
          RETURN sum(n - 1, acc + n);
        END
        FN main() RETURNS Void -> _ = sum(10_i64, 0_i64); RETURN; END
      CLEAR
    }.not_to raise_error
  end

  it "rejects a non-recursive :THUNK function" do
    expect {
      annotate(<<~CLEAR)
        FN noop(n: Int64) RETURNS Int64
          EFFECTS REENTRANT:THUNK ->
          RETURN n + 1;
        END
        FN main() RETURNS Void -> _ = noop(5_i64); RETURN; END
      CLEAR
    }.to raise_error(/EFFECTS REENTRANT:THUNK on 'noop' but the function is not recursive/)
  end

  it "names plain EFFECTS REENTRANT as the alternative in the error message" do
    expect {
      annotate(<<~CLEAR)
        FN noop(n: Int64) RETURNS Int64
          EFFECTS REENTRANT:THUNK ->
          RETURN n + 1;
        END
        FN main() RETURNS Void -> _ = noop(5_i64); RETURN; END
      CLEAR
    }.to raise_error(/'EFFECTS REENTRANT'/)
  end
end

# Thunk Phase 4b -- tail-recursive `:reentrant_thunk` functions
# piggyback on the existing :TAIL_CALL MIR emission. Non-tail :THUNK
# errors with a clear "Phase 4c" message.

RSpec.describe "Phase 4b: tail-recursive :THUNK routing" do
  def annotate(source)
    tokens = Lexer.new(source).tokenize
    ast = Parser.new(tokens, source).parse
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)
    ast
  end

  def fn(ast, name)
    ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == name }
  end

  it "back-fills tail_call=true for a tail-recursive :THUNK function" do
    ast = annotate(<<~CLEAR)
      FN sum(n: Int64, acc: Int64) RETURNS Int64
        EFFECTS REENTRANT:THUNK ->
        IF n <= 0 -> RETURN acc;
        RETURN sum(n - 1, acc + n);
      END
      FN main() RETURNS Void -> _ = sum(10_i64, 0_i64); RETURN; END
    CLEAR
    f = fn(ast, "sum")
    expect(f.reentrance_kind).to eq(:reentrant_thunk)
    expect(f.tail_call).to be(true)
    expect(f.reentrant).to eq(:reentrant)
  end

  it "leaves tail_call false for a non-tail :THUNK function (handled by Phase 4d codegen)" do
    # Phase 4d landed Zig codegen for the factorial-shape so this no
    # longer errors -- the function lowers to a heap-CPS trampoline
    # body. tail_call stays false (the trampoline ISN'T a tail-call
    # self-loop).
    ast = annotate(<<~CLEAR)
      FN factorial(n: Int64) RETURNS Int64
        EFFECTS REENTRANT:THUNK ->
        IF n <= 1 -> RETURN 1;
        RETURN n * factorial(n - 1);
      END
      FN main() RETURNS Void -> _ = factorial(5_i64); RETURN; END
    CLEAR
    f = fn(ast, "factorial")
    expect(f.tail_call).to be_falsey
    expect(f.thunk_plan).not_to be_nil
  end

  it "still errors on shapes the splitter doesn't yet recognize" do
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

  it "preserves reentrance_kind for downstream effect propagation" do
    # Phase 5 will use reentrance_kind (not tail_call alone) to keep
    # :THUNK out of @service propagation. This spec locks in that the
    # bridge does NOT overwrite reentrance_kind when it sets tail_call.
    ast = annotate(<<~CLEAR)
      FN sum(n: Int64, acc: Int64) RETURNS Int64
        EFFECTS REENTRANT:THUNK ->
        IF n <= 0 -> RETURN acc;
        RETURN sum(n - 1, acc + n);
      END
      FN main() RETURNS Void -> _ = sum(10_i64, 0_i64); RETURN; END
    CLEAR
    expect(fn(ast, "sum").reentrance_kind).to eq(:reentrant_thunk)
  end
end
