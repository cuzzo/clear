require "rspec"
require_relative "../src/backends/transpiler"

RSpec.describe "binary operator type checking" do
  def annotate(source)
    tokens = Lexer.new(source).tokenize
    ast = Parser.new(tokens, source).parse
    SemanticAnnotator.new(source_code: source).annotate!(ast)
    ast
  end

  def expect_compile_expr(expr, returns: "Bool")
    expect {
      annotate(<<~CLEAR)
        FN main() RETURNS #{returns} ->
          RETURN #{expr};
        END
      CLEAR
    }.not_to raise_error
  end

  def expect_reject_expr(expr, returns: "Bool")
    expect {
      annotate(<<~CLEAR)
        FN main() RETURNS #{returns} ->
          RETURN #{expr};
        END
      CLEAR
    }.to raise_error(CompilerError)
  end

  it "accepts valid numeric arithmetic and ordering" do
    expect_compile_expr("1 + 2", returns: "Int64")
    expect_compile_expr("1 + 2.5", returns: "Float64")
    expect_compile_expr("1 < 2")
    expect_compile_expr("1 == 2.0")
  end

  it "accepts valid string concatenation and equality" do
    expect_compile_expr('"a" + "b"', returns: "String")
    expect_compile_expr('"a" == "b"')
  end

  it "accepts valid boolean logic" do
    expect_compile_expr("TRUE && FALSE")
    expect_compile_expr("TRUE || FALSE")
  end

  it "rejects nonnumeric arithmetic operands" do
    expect_reject_expr('"a" - "b"', returns: "String")
    expect_reject_expr('TRUE * "b"', returns: "Float64")
  end

  it "rejects incompatible ordering and equality operands" do
    expect_reject_expr('1 < "x"')
    expect_reject_expr('"a" == 1')
  end

  it "rejects non-Bool logical operands" do
    expect_reject_expr("TRUE && 1")
    expect_reject_expr('"x" || FALSE')
  end

  it "resolves direct Type.binary_op operator branches" do
    auto = Type.new(:Auto, auto: true)

    expect(Type.binary_op(:EQ, auto, Type.new(:Int64)).type.resolved).to eq(:Bool)
    expect(Type.binary_op(:ADD, auto, Type.new(:Int64)).type.auto?).to be(true)
    expect(Type.binary_op(:UNKNOWN, Type.new(:Int64), Type.new(:Int64)).error).to include("Unknown")

    expect(Type.binary_op(:AND, Type.new(:Bool), Type.new(:Bool)).type.resolved).to eq(:Bool)
    expect(Type.binary_op(:AND, Type.new(:Bool), Type.new(:Int64)).error).to include("Bool")

    expect(Type.binary_op(:EQ, Type.new(:Direction), Type.new(:Direction)).type.resolved).to eq(:Bool)
    expect(Type.binary_op(:EQ, Type.new(:Int64), Type.new(:Float64)).type.resolved).to eq(:Bool)
    expect(Type.binary_op(:EQ, Type.new(:String), Type.new(:"Byte[1]")).type.resolved).to eq(:Bool)
    expect(Type.binary_op(:EQ, Type.new(:"?Float64"), Type.new(:NIL)).type.resolved).to eq(:Bool)
    expect(Type.binary_op(:NEQ, Type.new(:NIL), Type.new(:"?Float64")).type.resolved).to eq(:Bool)
    expect(Type.binary_op(:EQ, Type.new(:String), Type.new(:Int64)).error).to include("cannot compare")
    expect(Type.binary_op(:EQ, Type.new(:Int64), Type.new(:NIL)).error).to include("cannot compare")

    expect(Type.binary_op(:LT, Type.new(:Int64), Type.new(:Float64)).type.resolved).to eq(:Bool)
    expect(Type.binary_op(:LT, Type.new(:String), Type.new(:"Byte[1]")).type.resolved).to eq(:Bool)
    expect(Type.binary_op(:LT, Type.new(:Bool), Type.new(:Int64)).error).to include("ordered")
    expect(Type.binary_op(:LT, Type.new(:"?Int64"), Type.new(:Int64)).error).to include("ordered")

    expect(Type.binary_op(:SUB, Type.new(:Int64), Type.new(:Int64)).type.resolved).to eq(:Int64)
    expect(Type.binary_op(:SUB, Type.new(:Int8), Type.new(:Int64)).type.resolved).to eq(:Int64)
    expect(Type.binary_op(:SUB, Type.new(:Int64), Type.new(:Int8)).type.resolved).to eq(:Int64)
    expect(Type.binary_op(:SUB, Type.new(:Float32), Type.new(:Float64)).type.resolved).to eq(:Float64)
    expect(Type.binary_op(:SUB, Type.new(:Float64), Type.new(:Float32)).type.resolved).to eq(:Float64)
    expect(Type.binary_op(:SUB, Type.new(:Int64), Type.new(:Float64)).type.resolved).to eq(:Float64)
    expect(Type.binary_op(:SUB, Type.new(:Float64), Type.new(:Int64)).type.resolved).to eq(:Float64)
    expect(Type.binary_op(:MUL, Type.new(:Any), Type.new(:Any)).type.resolved).to eq(:Any)
    expect(Type.binary_op(:SUB, Type.new(:String), Type.new(:String)).error).to include("numeric")
  end
end
