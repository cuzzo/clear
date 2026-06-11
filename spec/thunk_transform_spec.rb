require "rspec"
require_relative "../src/mir/thunk_transform"
require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/ast/ast"
require_relative "../src/backends/transpiler"

RSpec.describe "ThunkTransform module wiring" do
  describe ZigType do
    it "classifies and formats Zig error-return shapes" do
      expect(ZigType.new("i64").error_union?).to eq(false)
      expect(ZigType.new("i64").fallible_return_type).to eq("!i64")
      expect(ZigType.new("i64").concrete_fallible_return_type).to eq("anyerror!i64")
      expect(ZigType.new("!i64").error_union?).to eq(true)
      expect(ZigType.new("!i64").concrete_fallible_return_type).to eq("anyerror!i64")
      expect(ZigType.new("anyerror!i64").fallible_return_type).to eq("anyerror!i64")
      expect(ZigType.new("!i64").cast_target_type).to eq("anyerror!i64")
      expect(ZigType.new("!i64").cleanup_storage_type).to eq("i64")
    end

    it "classifies primitive Zig numeric identifiers without regex parsing" do
      expect(ZigType.primitive_numeric_identifier?("i64")).to eq(true)
      expect(ZigType.primitive_numeric_identifier?("f32")).to eq(true)
      expect(ZigType.integer_identifier?("u8")).to eq(true)
      expect(ZigType.float_identifier?("f64")).to eq(true)
      expect(ZigType.integer_identifier?("usize")).to eq(false)
      expect(ZigType.primitive_numeric_identifier?("Int64")).to eq(false)
    end
  end

  describe "module structure" do
    it "loads ThunkTransform" do
      expect(defined?(ThunkTransform)).to eq("constant")
    end

    it "loads ThunkTransform::RecursiveSplitter" do
      expect(defined?(ThunkTransform::RecursiveSplitter)).to eq("constant")
    end

    it "loads ThunkTransform::Emit" do
      expect(defined?(ThunkTransform::Emit)).to eq("constant")
    end
  end

  # Tranche 1 guardrail: today's heap-CPS trampoline only frees child
  # Frames on the normal-return path. The simple-recurrence splitter
  # plus the type checker keep the body non-fallible (a `RETURN <lhs>
  # <op> self_call(args)` shape rejects fallible operands), but a
  # future Phase 4 extension could relax that. The guard fails loudly
  # if the return type is fallible so the leak can't ship silently.
  describe "non-fallible body invariant (assert_non_fallible_ret!)" do
    let(:tok) { Lexer::Token.new(:IDENT, "deep", 1, 1) }
    let(:fake_fn) {
      AST::FunctionDef.new(tok, "deep", [], nil, "i64", nil, [], [], nil, :pub, nil, false)
    }

    it "passes for plain integer return types" do
      expect {
        ThunkTransform::Emit.assert_non_fallible_ret!(fake_fn, Type.new(:Int64))
      }.not_to raise_error
    end

    it "passes for void return type" do
      expect {
        ThunkTransform::Emit.assert_non_fallible_ret!(fake_fn, Type.new(:Void))
      }.not_to raise_error
    end

    it "raises a directed error message when the return type is fallible" do
      expect {
        ThunkTransform::Emit.assert_non_fallible_ret!(fake_fn, Type.new(:"!Int64"))
      }.to raise_error(/THUNK trampoline.*'deep'.*fallible/)
    end

    it "names the helpers a future maintainer must extend" do
      expect {
        ThunkTransform::Emit.assert_non_fallible_ret!(fake_fn, Type.new(:"!Int64"))
      }.to raise_error(/build_trampoline.*build_mutual_trampoline.*errdefer/m)
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
      when MIR::UnaryOp then "#{mir.op}#{emit_expr(mir.operand)}"
      when MIR::FieldGet then "#{emit_expr(mir.object)}.#{mir.field}"
      when MIR::IndexGet then "#{emit_expr(mir.object)}[#{emit_expr(mir.index)}]"
      when MIR::MethodCall then "#{emit_expr(mir.receiver)}.#{mir.method}(#{mir.args.map { |arg| emit_expr(arg) }.join(", ")})"
      when MIR::Call then "#{mir.callee}(#{mir.args.map { |arg| emit_expr(arg) }.join(", ")})"
      when MIR::Cast then "@as(#{mir.target_type}, #{emit_expr(mir.expr)})"
      when MIR::TryExpr then "try #{emit_expr(mir.expr)}"
      when MIR::TryCatch then "#{emit_expr(mir.expr)} catch #{emit_expr(mir.catch_body)}"
      when MIR::AddressOf then "&#{emit_expr(mir.expr)}"
      when MIR::Deref then "#{emit_expr(mir.expr)}.*"
      when MIR::OptionalUnwrap then "#{emit_expr(mir.expr)}.?"
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
    node = AST::FunctionDef.new(
      tok,
      name,
      params,
      nil,
      return_type,
      nil,
      [],
      [],
      nil,
      :pub,
      nil,
      false,
    )
    node.thunk_plan = plan
    node.mutual_thunk_plan = mutual_plan
    node.tight_reentrance = tight
    node
  end

  def param(name, type = "i64")
    AST::Param.new(name: name, type: type)
  end

  def base_case(cond, value)
    ThunkTransform::RecursiveSplitter::BaseCase.new(cond_ast: cond, value_ast: value)
  end

  def simple_plan(base_cases:, recurse_args:, combine_lhs:, combine_op:)
    ThunkTransform::RecursiveSplitter::Plan.new(
      base_cases: base_cases,
      recurse_args: recurse_args,
      combine_lhs: combine_lhs,
      combine_op: combine_op,
      final_return: AST::ReturnNode.new(tok, combine_lhs),
    )
  end

  def mutual_plan(base_cases:, target_fn:, target_args:)
    ThunkTransform::RecursiveSplitter::MutualPlan.new(
      base_cases: base_cases,
      target_fn: target_fn,
      target_args: target_args,
      final_return: AST::ReturnNode.new(tok, AST::FuncCall.new(tok, target_fn, target_args)),
    )
  end

  def mutual_thunk_plan(cycle_fns, own_plan)
    ThunkTransform::RecursiveSplitter::MutualThunkPlan.new(
      cycle_fns: cycle_fns,
      own_plan: own_plan,
    )
  end

  it "builds and renders heap-CPS trampoline MIR for simple recursive thunks" do
    plan = simple_plan(
      base_cases: [base_case(bin(id("n"), :LT_EQ, int(1)), int(1))],
      recurse_args: [bin(id("n"), :SUB, int(1))],
      combine_lhs: id("n"),
      combine_op: :MUL
    )
    node = ThunkTransform::Emit.build_trampoline(
      fn("factorial", params: [param("n")], plan: plan),
      FakeThunkLowering.new
    )

    expect(node).to be_a(MIR::ThunkTrampoline)
    expect(node.fn_name).to eq("factorial")
    expect(node.base_cases.first).to be_a(MIR::ThunkBaseCase)
    expect(FakeThunkLowering.new.emit_expr(node.base_cases.first.fetch(:cond))).to eq("current.n <= 1")
    expect(FakeThunkLowering.new.emit_expr(node.base_cases.first.fetch(:value))).to eq("1")
    expect {
      node.base_cases.first.fetch(:missing)
    }.to raise_error(KeyError, /missing/)
    expect(FakeThunkLowering.new.emit_expr(node.combine_lhs)).to eq("current.n")
    expect(node.return_type.zig_type).to eq("i64")
    expect(node.param_fields.first.type_info.zig_type).to eq("i64")
    expect(node.combine_op).to eq(:MUL)
    expect(node.yield_policy).to eq(:check)
    zig = MIREmitter.new.emit(node)
    expect(zig).to include("const Frame = struct")
    expect(zig).to include("rt.checkYield();")
    expect(zig).to include("const child = rt.heapAlloc().create(Frame) catch unreachable;")
    expect(zig).to include(".n = (current.n - 1)")
    expect(zig).to include("const result: i64 = current.n * current.child_result;")
    expect(zig).to include("rt.heapAlloc().destroy(current);")
  end

  it "skips the scheduler yield line for tight thunk trampolines" do
    plan = simple_plan(
      base_cases: [base_case(id("done"), id("acc"))],
      recurse_args: [id("n"), id("acc")],
      combine_lhs: id("acc"),
      combine_op: :ADD
    )
    node = ThunkTransform::Emit.build_trampoline(
      fn("sum", params: [param("n"), param("acc")], plan: plan, tight: true),
      FakeThunkLowering.new
    )

    expect(node.yield_policy).to eq(:tight_skip)
    zig = MIREmitter.new.emit(node)
    expect(zig).to include("// (TIGHT: scheduler yield-check skipped)")
    expect(zig).not_to include("rt.checkYield();")
  end

  it "raises directed errors for invalid simple thunk plans" do
    expect {
      ThunkTransform::Emit.build_trampoline(fn("missing", params: []), FakeThunkLowering.new)
    }.to raise_error(/has no thunk_plan/)

    bad_op = simple_plan(base_cases: [], recurse_args: [], combine_lhs: id("x"), combine_op: :MOD)
    expect {
      ThunkTransform::Emit.build_trampoline(fn("bad_op", params: [], plan: bad_op), FakeThunkLowering.new)
    }.to raise_error(/unsupported op MOD/)

    bad_arity = simple_plan(base_cases: [], recurse_args: [id("x")], combine_lhs: id("x"), combine_op: :ADD)
    expect {
      ThunkTransform::Emit.build_trampoline(fn("bad_arity", params: [], plan: bad_arity), FakeThunkLowering.new)
    }.to raise_error(/arg\/param count mismatch/)
  end

  it "binds thunk frame params structurally before emitting Zig" do
    context = ThunkTransform::Emit.current_frame_context(fn("sample", params: [param("n"), param("name")]))
    mir = MIR::BinOp.new(
      "+",
      MIR::Ident.new("n"),
      MIR::BinOp.new(
        "+",
        MIR::FieldGet.new(MIR::Ident.new("obj"), "n"),
        MIR::Ident.new("name_extra")
      )
    )

    rebound = ThunkTransform::Emit.bind_frame_refs(mir, context)

    expect(FakeThunkLowering.new.emit_expr(rebound)).to eq("current.n + obj.n + name_extra")
  end

  it "binds nested thunk call, method, index, and wrapper expressions structurally" do
    context = ThunkTransform::Emit.mutual_frame_context(fn("sample", params: [param("n"), param("items")]))
    call = MIR::Call.new(
      "next",
      [
        MIR::MethodCall.new(
          MIR::IndexGet.new(MIR::Ident.new("items"), MIR::Ident.new("n")),
          "value",
          [MIR::AddressOf.new(MIR::OptionalUnwrap.new(MIR::Ident.new("n")))],
          false,
          MIR::CallableContract.no_ownership(1)
        )
      ],
      true,
      false,
      MIR::CallableContract.no_ownership(1)
    )

    rebound = ThunkTransform::Emit.bind_frame_refs(
      MIR::TryCatch.new(MIR::TryExpr.new(call), MIR::Deref.new(MIR::Ident.new("items")), nil),
      context
    )

    expect(FakeThunkLowering.new.emit_expr(rebound)).
      to eq("try next(f.items[f.n].value(&f.n.?)) catch f.items.*")

    casted = ThunkTransform::Emit.bind_frame_refs(
      MIR::Cast.new(MIR::UnaryOp.new("-", MIR::Ident.new("n")), "i64", :as),
      context
    )
    expect(FakeThunkLowering.new.emit_expr(casted)).to eq("@as(i64, -f.n)")
  end

  it "builds and renders mutual-recursion trampoline MIR with tagged frame variants" do
    even = fn("even", params: [param("n")])
    odd = fn("odd", params: [param("n")])
    even_plan = mutual_plan(
      base_cases: [base_case(bin(id("n"), :LT_EQ, int(0)), int(1))],
      target_fn: "odd",
      target_args: [bin(id("n"), :SUB, int(1))]
    )
    odd_plan = mutual_plan(
      base_cases: [base_case(bin(id("n"), :LT_EQ, int(0)), int(0))],
      target_fn: "even",
      target_args: [bin(id("n"), :SUB, int(1))]
    )
    cycle = [even, odd]
    even.mutual_thunk_plan = mutual_thunk_plan(cycle, even_plan)
    odd.mutual_thunk_plan = mutual_thunk_plan(cycle, odd_plan)

    node = ThunkTransform::Emit.build_mutual_trampoline(even, FakeThunkLowering.new)
    expect(node).to be_a(MIR::MutualThunkTrampoline)
    expect(node.variants.map { |v| v.fetch(:name) }).to eq(%w[even odd])
    expect(node.arms).to all(be_a(MIR::MutualThunkArm))
    expect(node.arms.first.fetch(:variant_name)).to eq("even")
    expect(node.arms.map { |a| a.fetch(:target_variant) }).to eq(%w[odd even])
    expect(node.arms.first.target_arg_inits.first).to be_a(MIR::ThunkFrameInit)
    expect(node.arms.first.target_arg_inits.first.fetch(:field_name)).to eq("n")
    expect(FakeThunkLowering.new.emit_expr(node.arms.first.target_arg_inits.first.fetch(:value))).to eq("f.n - 1")
    expect {
      node.arms.first.target_arg_inits.first.fetch(:missing)
    }.to raise_error(KeyError, /missing/)
    expect {
      node.arms.first.fetch(:missing)
    }.to raise_error(KeyError, /missing/)

    zig = MIREmitter.new.emit(node)

    expect(zig).to include("const Frame = union(enum)")
    expect(zig).to include("even: struct")
    expect(zig).to include("odd: struct")
    expect(zig).to include("var current: Frame = .{ .even")
    expect(zig).to include("current = .{ .odd = .{ .n = (f.n - 1) } };")
  end

  it "raises directed errors for invalid mutual thunk plans" do
    missing = fn("missing", params: [])
    expect {
      ThunkTransform::Emit.build_mutual_trampoline(missing, FakeThunkLowering.new)
    }.to raise_error(/has no mutual_thunk_plan/)

    cf = fn("even", params: [param("n")])
    cf.mutual_thunk_plan = mutual_thunk_plan(
      [cf],
      mutual_plan(base_cases: [], target_fn: "odd", target_args: [])
    )
    expect {
      ThunkTransform::Emit.send(:build_mutual_arm, cf, cf.mutual_thunk_plan, FakeThunkLowering.new)
    }.to raise_error(/cycle member 'odd' not found/)

    target = fn("odd", params: [param("n")])
    cf.mutual_thunk_plan = mutual_thunk_plan(
      [cf, target],
      mutual_plan(base_cases: [], target_fn: "odd", target_args: [])
    )
    expect {
      ThunkTransform::Emit.send(:build_mutual_arm, cf, cf.mutual_thunk_plan, FakeThunkLowering.new)
    }.to raise_error(/target arg\/param count mismatch/)
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
