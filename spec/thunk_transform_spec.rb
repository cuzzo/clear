require "rspec"
require "ostruct"
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

RSpec.describe "ThunkTransform emit coverage" do
  let(:tok) { Lexer::Token.new(:IDENT, "x", 1, 1) }

  class FakeThunkLowering
    OP_TO_ZIG = {
      ADD: "+",
      SUB: "-",
      MUL: "*",
      DIV: "/",
      LT_EQ: "<=",
    }.freeze

    def lower(ast)
      case ast
      when AST::Identifier
        MIR::Ident.new(ast.name)
      when AST::Literal
        MIR::Lit.new(ast.value.to_s)
      when AST::BinaryOp
        MIR::BinOp.new(OP_TO_ZIG.fetch(ast.op, ast.op.to_s), lower(ast.left), lower(ast.right))
      else
        MIR::Ident.new(ast.to_s)
      end
    end

    def emit_expr(mir)
      case mir
      when MIR::Ident then mir.name
      when MIR::Lit then mir.value
      when MIR::BinOp then "#{emit_expr(mir.left)} #{mir.op} #{emit_expr(mir.right)}"
      else mir.to_s
      end
    end
  end

  def id(name)
    AST::Identifier.new(tok, name)
  end

  def int(value)
    AST::Literal.new(tok, :INT64, value)
  end

  def bin(left, op, right)
    AST::BinaryOp.new(tok, left, op, right)
  end

  def fn(name, params:, return_type: "i64", plan: nil, mutual_plan: nil, tight: false)
    OpenStruct.new(
      name: name,
      params: params,
      return_type: return_type,
      thunk_plan: plan,
      mutual_thunk_plan: mutual_plan,
      tight_reentrance: tight
    )
  end

  def param(name, type = "i64")
    { name: name, type: type }
  end

  it "emits heap-CPS trampoline scaffolding for simple recursive thunks" do
    plan = OpenStruct.new(
      base_cases: [{ cond_ast: bin(id("n"), :LT_EQ, int(1)), value_ast: int(1) }],
      recurse_args: [bin(id("n"), :SUB, int(1))],
      combine_lhs: id("n"),
      combine_op: :MUL
    )
    zig = ThunkTransform::Emit.emit_trampoline(
      fn("factorial", params: [param("n")], plan: plan),
      FakeThunkLowering.new
    )

    expect(zig).to include("const Frame = struct")
    expect(zig).to include("rt.checkYield();")
    expect(zig).to include("const child = rt.heapAlloc().create(Frame) catch unreachable;")
    expect(zig).to include(".n = current.n - 1")
    expect(zig).to include("const result: i64 = current.n * current.child_result;")
    expect(zig).to include("rt.heapAlloc().destroy(current);")
  end

  it "skips the scheduler yield line for tight thunk trampolines" do
    plan = OpenStruct.new(
      base_cases: [{ cond_ast: id("done"), value_ast: id("acc") }],
      recurse_args: [id("n"), id("acc")],
      combine_lhs: id("acc"),
      combine_op: :ADD
    )
    zig = ThunkTransform::Emit.emit_trampoline(
      fn("sum", params: [param("n"), param("acc")], plan: plan, tight: true),
      FakeThunkLowering.new
    )

    expect(zig).to include("// (TIGHT: scheduler yield-check skipped)")
    expect(zig).not_to include("rt.checkYield();")
  end

  it "raises directed errors for invalid simple thunk plans" do
    expect {
      ThunkTransform::Emit.emit_trampoline(fn("missing", params: []), FakeThunkLowering.new)
    }.to raise_error(/has no thunk_plan/)

    bad_op = OpenStruct.new(base_cases: [], recurse_args: [], combine_lhs: id("x"), combine_op: :MOD)
    expect {
      ThunkTransform::Emit.emit_trampoline(fn("bad_op", params: [], plan: bad_op), FakeThunkLowering.new)
    }.to raise_error(/unsupported op MOD/)

    bad_arity = OpenStruct.new(base_cases: [], recurse_args: [id("x")], combine_lhs: id("x"), combine_op: :ADD)
    expect {
      ThunkTransform::Emit.emit_trampoline(fn("bad_arity", params: [], plan: bad_arity), FakeThunkLowering.new)
    }.to raise_error(/arg\/param count mismatch/)
  end

  it "qualifies only bare frame parameters" do
    fn_node = fn("sample", params: [param("n"), param("name")])

    expect(ThunkTransform::Emit.qualify_params("n + obj.n + name_extra + name", fn_node)).
      to eq("current.n + obj.n + name_extra + current.name")
  end

  it "emits mutual-recursion trampolines with tagged frame variants" do
    even = fn("even", params: [param("n")])
    odd = fn("odd", params: [param("n")])
    even_plan = OpenStruct.new(
      base_cases: [{ cond_ast: bin(id("n"), :LT_EQ, int(0)), value_ast: int(1) }],
      target_fn: "odd",
      target_args: [bin(id("n"), :SUB, int(1))]
    )
    odd_plan = OpenStruct.new(
      base_cases: [{ cond_ast: bin(id("n"), :LT_EQ, int(0)), value_ast: int(0) }],
      target_fn: "even",
      target_args: [bin(id("n"), :SUB, int(1))]
    )
    cycle = [even, odd]
    even.mutual_thunk_plan = OpenStruct.new(cycle_fns: cycle, own_plan: even_plan)
    odd.mutual_thunk_plan = OpenStruct.new(cycle_fns: cycle, own_plan: odd_plan)

    node = ThunkTransform::Emit.build_mutual_trampoline(even, FakeThunkLowering.new)
    expect(node).to be_a(MIR::MutualThunkTrampoline)
    expect(node.variants.map { |v| v.fetch(:name) }).to eq(%w[even odd])
    expect(node.arms.map { |a| a.fetch(:target_variant) }).to eq(%w[odd even])

    zig = ThunkTransform::Emit.emit_mutual_trampoline(even, FakeThunkLowering.new)

    expect(zig).to include("const Frame = union(enum)")
    expect(zig).to include("even: struct")
    expect(zig).to include("odd: struct")
    expect(zig).to include("var current: Frame = .{ .even")
    expect(zig).to include("current = .{ .odd = .{ .n = f.n - 1 } };")
  end

  it "raises directed errors for invalid mutual thunk plans" do
    missing = fn("missing", params: [])
    expect {
      ThunkTransform::Emit.emit_mutual_trampoline(missing, FakeThunkLowering.new)
    }.to raise_error(/has no mutual_thunk_plan/)

    cf = fn("even", params: [param("n")])
    cf.mutual_thunk_plan = OpenStruct.new(
      cycle_fns: [cf],
      own_plan: OpenStruct.new(base_cases: [], target_fn: "odd", target_args: [])
    )
    expect {
      ThunkTransform::Emit.build_mutual_arm(cf, cf.mutual_thunk_plan, "i64", FakeThunkLowering.new)
    }.to raise_error(/cycle member 'odd' not found/)

    target = fn("odd", params: [param("n")])
    cf.mutual_thunk_plan = OpenStruct.new(
      cycle_fns: [cf, target],
      own_plan: OpenStruct.new(base_cases: [], target_fn: "odd", target_args: [])
    )
    expect {
      ThunkTransform::Emit.build_mutual_arm(cf, cf.mutual_thunk_plan, "i64", FakeThunkLowering.new)
    }.to raise_error(/target arg\/param count mismatch/)
  end

  it "keeps the legacy build hook as a no-op" do
    expect(ThunkTransform::Emit.build([], nil, FakeThunkLowering.new, nil)).to be_nil
  end
end

RSpec.describe "ThunkTransform recursive splitter helpers" do
  let(:tok) { Lexer::Token.new(:IDENT, "f", 1, 1) }

  it "walks arrays while looking for mutual-recursion calls" do
    call = AST::FuncCall.new(tok, "even", [])

    expect(ThunkTransform::RecursiveSplitter.contains_any_call?([AST::Identifier.new(tok, "x"), call], ["even"])).to be(true)
    expect(ThunkTransform::RecursiveSplitter.contains_any_call?([AST::Identifier.new(tok, "x")], ["even"])).to be(false)
  end

  it "walks arrays while looking for self-recursion calls" do
    call = AST::FuncCall.new(tok, "fact", [])

    expect(ThunkTransform::RecursiveSplitter.contains_self_call?([AST::Identifier.new(tok, "x"), call], "fact")).to be(true)
    expect(ThunkTransform::RecursiveSplitter.contains_self_call?([AST::Identifier.new(tok, "x")], "fact")).to be(false)
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
