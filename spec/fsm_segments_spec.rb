require "rspec"
require_relative "../src/ast/ast"
require_relative "../src/ast/lexer"
require_relative "../src/ast/std_lib"
require_relative "../src/ast/type"
require_relative "../src/mir/fsm_transform/segments"

RSpec.describe FsmTransform::Segments do
  let(:tok) { Lexer::Token.new(:IDENTIFIER, "x", 1, 1) }
  let(:stdlib_def) { intrinsic_sig(suspends: true, fsm_setup: []) }
  let(:plain_def) { intrinsic_sig(suspends: false) }

  def intrinsic_sig(suspends:, fsm_setup: nil)
    sig = FunctionSignature.new(params: [], return_type: Type.new(:String), intrinsic: true)
    sig.emit = IntrinsicEmit.new(suspends: suspends, fsm_setup: fsm_setup)
    sig
  end

  def typed(node, type = :Int64)
    node.full_type = Type.new(type)
    node
  end

  def ident(name = "p", type: :"~Int64")
    typed(AST::Identifier.new(tok, name), type)
  end

  def lit(value = 1)
    typed(AST::Literal.new(tok, :INT64, value, nil), :Int64)
  end

  def next_expr(name = "p")
    typed(AST::NextExpr.new(tok, ident(name)), :Int64)
  end

  def io_call(name = "readFile")
    call = typed(AST::FuncCall.new(tok, name, []), :String)
    call.matched_stdlib_def = stdlib_def
    call
  end

  def non_io_call
    call = typed(AST::FuncCall.new(tok, "plain", []), :String)
    call.matched_stdlib_def = plain_def
    call
  end

  it "exposes stable tail helpers for IO and NEXT suspends" do
    io = described_class::IoSuspend.new(io_call, stdlib_def, "out")
    expect(io.kind).to eq(:io)
    expect(io.suspend?).to eq(true)
    expect(io.with_next_index(7).next_index).to eq(7)
    expect(io.result_type.resolved).to eq(:String)

    nxt = described_class::NextSuspend.new(ident, "out")
    expect(nxt.kind).to eq(:next)
    expect(nxt.suspend?).to eq(true)
    expect(nxt.with_next_index(3).next_index).to eq(3)
    expect(nxt.result_type.resolved).to eq(:Int64)

    expect(described_class::LockSuspend.new(nil, {}, [], 1, 2).kind).to eq(:lock)
    expect(described_class::LoopBack.new(1).kind).to eq(:loop_back)
    expect(described_class::Goto.new(1).kind).to eq(:goto)
    expect(described_class::CondBranch.new(lit, 1, 2).kind).to eq(:cond_branch)
    expect(described_class.send(:suspend_tail?, described_class::Done.new(nil))).to eq(false)
  end

  it "classifies top-level, binding, and assignment suspend statements" do
    bind = AST::BindExpr.new(tok, "future_value", nil, next_expr)
    assign = AST::Assignment.new(tok, "file_value", io_call)

    expect(described_class.send(:classify_suspend, next_expr)).to be_a(described_class::NextSuspend)
    expect(described_class.send(:classify_suspend, bind)).to be_a(described_class::NextSuspend)
    expect(described_class.send(:classify_suspend, assign)).to be_a(described_class::IoSuspend)
    expect(described_class.send(:classify_suspend, non_io_call)).to be_nil
    expect(described_class.send(:suspending_call?, io_call)).to eq(true)
    expect(described_class.send(:suspending_call?, non_io_call)).to eq(false)
  end

  it "splits linear bodies and rejects unsupported control-flow shapes" do
    first = lit
    last = lit
    bind = AST::BindExpr.new(tok, "a", nil, next_expr("p1"))
    assign = AST::Assignment.new(tok, "b", io_call("sleep"))
    segments = described_class.split([first, bind, assign, last], nil)

    expect(segments.map(&:index)).to eq([0, 1, 2])
    expect(segments[0].stmts).to eq([first])
    expect(segments[0].tail).to be_a(described_class::NextSuspend)
    expect(segments[1].tail).to be_a(described_class::IoSuspend)
    expect(segments[2].stmts).to eq([last])
    expect(segments[2].tail).to be_a(described_class::Done)

    with_block = AST::WithBlock.new(tok, [], [lit])
    expect(described_class.split([with_block], nil)).to be_nil
    expect(described_class.send(:contains_unsupported_shape?, [with_block])).to eq(true)
  end

  it "handles the legacy while-loop single-suspend shape" do
    loop = AST::WhileLoop.new(tok, lit, [lit, next_expr, lit], nil)
    segments = described_class.send(:split_while_loop_next, [lit, loop, lit])

    expect(segments.length).to eq(5)
    expect(segments[0].tail).to be_a(described_class::Goto)
    expect(segments[1].tail).to be_a(described_class::CondBranch)
    expect(segments[2].tail).to be_a(described_class::NextSuspend)
    expect(segments[2].stmts.length).to eq(1)
    expect(segments[3].tail).to be_a(described_class::LoopBack)
    expect(segments[4].tail).to be_a(described_class::Done)

    expect(described_class.split([lit, loop, lit], nil).map(&:tail).map(&:kind)).
      to eq(%i[goto cond_branch next loop_back done])
  end

  it "rejects while-loop shapes with nested or multiple suspends" do
    multiple = AST::WhileLoop.new(tok, lit, [next_expr("a"), next_expr("b")], nil)
    nested_if = AST::IfStatement.new(tok, lit, [next_expr], [], nil, nil)
    nested = AST::WhileLoop.new(tok, lit, [nested_if], nil)
    pre_suspend = AST::WhileLoop.new(tok, lit, [lit], nil)

    expect(described_class.send(:split_while_loop_next, "not a body")).to be_nil
    expect(described_class.send(:split_while_loop_next, [multiple])).to be_nil
    expect(described_class.send(:split_while_loop_next, [nested])).to be_nil
    expect(described_class.send(:split_while_loop_next, [next_expr, pre_suspend])).to be_nil
  end

  it "detects suspends inside unsupported control-flow containers" do
    with_next = [next_expr]
    without_next = [lit]
    while_loop = AST::WhileLoop.new(tok, lit, with_next, nil)
    for_range = AST::ForRange.new(tok, "i", lit, lit, false, with_next, nil, false)
    for_each = AST::ForEach.new(tok, "x", ident("items", type: :"Int64[]"), with_next, nil, false)
    while_bind = AST::WhileBindLoop.new(tok, ident("maybe"), "x", tok, with_next, nil)
    nested_if = AST::IfStatement.new(tok, lit, without_next, with_next, nil, nil)
    catch_block = AST::CatchBlock.new(tok, [], without_next)
    with_block = AST::WithBlock.new(tok, [], without_next)

    expect(described_class.send(:contains_unsupported_shape?, [while_loop])).to eq(true)
    expect(described_class.send(:contains_unsupported_shape?, [for_range])).to eq(true)
    expect(described_class.send(:contains_unsupported_shape?, [for_each])).to eq(true)
    expect(described_class.send(:contains_unsupported_shape?, [while_bind])).to eq(true)
    expect(described_class.send(:contains_unsupported_shape?, [nested_if])).to eq(true)
    expect(described_class.send(:contains_unsupported_shape?, [catch_block])).to eq(true)
    expect(described_class.send(:contains_suspend_anywhere?, [while_loop])).to eq(true)
    expect(described_class.send(:contains_suspend_anywhere?, [with_block])).to eq(true)
    expect(described_class.send(:contains_suspend_anywhere?, [catch_block])).to eq(true)
  end

  it "rewrites top-level suspending pipeline heads into bind plus residual pipeline" do
    right = typed(AST::FuncCall.new(tok, "trim", []), :String)
    pipeline = typed(AST::BinaryOp.new(tok, io_call, :SMOOTH, right), :String)

    rewritten = described_class.send(:rewrite_pipeline_io, [pipeline, lit])

    expect(rewritten.length).to eq(3)
    expect(rewritten[0]).to be_a(AST::BindExpr)
    expect(rewritten[0].name).to eq("__pipe_v_0")
    expect(rewritten[1]).to be_a(AST::BinaryOp)
    expect(rewritten[1].left).to be_a(AST::Identifier)
    expect(described_class.send(:rewrite_pipeline_io, pipeline)).to be(pipeline)
  end
end
