require "rspec"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

RSpec.describe Type, "binary operator type checking" do
  def annotate(source)
    tokens = Lexer.new(source).tokenize
    ast = ClearParser.new(tokens, source).parse
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
    expect_compile_expr("TRUE AND FALSE")
    expect_compile_expr("TRUE OR FALSE")
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
    expect_reject_expr("TRUE AND 1")
    expect_reject_expr('"x" OR FALSE')
  end

  it "accepts optional payload equality and ordering against concrete payloads" do
    expect {
      annotate(<<~CLEAR)
        ENUM Color { Red, Blue }
        FN main() RETURNS Bool ->
          maybe_count: ?Int64 = 1_i64;
          maybe_color: ?Color = Color.Red;
          concrete_color: Color = Color.Blue;
          RETURN maybe_count >= 0_i64 AND maybe_color != concrete_color;
        END
      CLEAR
    }.not_to raise_error
  end

  it "accepts numeric operators on the same generic type parameter" do
    expect {
      annotate(<<~CLEAR)
        FN dec<T>(n: T, one: T) RETURNS T ->
          IF n <= one -> RETURN one;
          RETURN n - one;
        END
        FN main() RETURNS Int64 ->
          RETURN dec(2_i64, 1_i64);
        END
      CLEAR
    }.not_to raise_error
  end

  it "resolves direct Type.binary_op operator branches" do
    auto = Type.new(:Auto, auto: true)

    expect(Type.binary_op(:EQ, auto, Type.new(:Int64)).type.resolved).to eq(:Bool)
    expect(Type.binary_op(:AND, auto, Type.new(:Bool)).type.resolved).to eq(:Bool)
    expect(Type.binary_op(:OR, Type.new(:Bool), auto).type.resolved).to eq(:Bool)
    expect(Type.binary_op(:ADD, auto, Type.new(:Int64)).type.auto?).to be(true)
    expect(Type.binary_op(:MUL, Type.new(:Int64), auto).type.auto?).to be(true)
    expect(Type.binary_op(:UNKNOWN, Type.new(:Int64), Type.new(:Int64)).error).to eq("Unknown operator: UNKNOWN")

    expect(Type.binary_op(:AND, Type.new(:Bool), Type.new(:Bool)).type.resolved).to eq(:Bool)
    expect(Type.binary_op(:AND, Type.new(:Bool), Type.new(:Int64)).error).to eq("Operator AND requires Bool operands, got Bool and Int64")

    expect(Type.binary_op(:EQ, Type.new(:Direction), Type.new(:Direction)).type.resolved).to eq(:Bool)
    expect(Type.binary_op(:EQ, Type.new(:Int64), Type.new(:Float64)).type.resolved).to eq(:Bool)
    expect(Type.binary_op(:EQ, Type.new(:String), Type.new(:"Byte[1]")).type.resolved).to eq(:Bool)
    expect(Type.binary_op(:EQ, Type.new(:"?Float64"), Type.new(:NIL)).type.resolved).to eq(:Bool)
    expect(Type.binary_op(:NEQ, Type.new(:NIL), Type.new(:"?Float64")).type.resolved).to eq(:Bool)
    expect(Type.binary_op(:EQ, Type.new(:String), Type.new(:Int64)).error).to eq("Operator EQ cannot compare String with Int64")
    expect(Type.binary_op(:EQ, Type.new(:Int64), Type.new(:NIL)).error).to include("cannot compare")

    expect(Type.binary_op(:LT, Type.new(:Int64), Type.new(:Float64)).type.resolved).to eq(:Bool)
    expect(Type.binary_op(:LT, Type.new(:String), Type.new(:"Byte[1]")).type.resolved).to eq(:Bool)
    expect(Type.binary_op(:LT, Type.new(:Bool), Type.new(:Int64)).error).to eq("Operator LT requires ordered operands, got Bool and Int64")
    expect(Type.binary_op(:LT, Type.new(:"?Int64"), Type.new(:Int64)).type.resolved).to eq(:Bool)
    expect(Type.binary_op(:EQ, Type.new(:"?Int64"), Type.new(:Int64)).type.resolved).to eq(:Bool)
    expect(Type.binary_op(:EQ, Type.new(:Int64), Type.new(:"?Int64")).type.resolved).to eq(:Bool)
    expect(Type.binary_op(:LT, Type.new(:"?Bool"), Type.new(:Bool)).error).to include("ordered")
    expect(Type.binary_op(:LTE, Type.new(:T), Type.new(:T)).type.resolved).to eq(:Bool)

    expect(Type.binary_op(:SUB, Type.new(:Int64), Type.new(:Int64)).type.resolved).to eq(:Int64)
    expect(Type.binary_op(:WRAP_ADD, Type.new(:Int64), Type.new(:Int64)).type.resolved).to eq(:Int64)
    expect(Type.binary_op(:CHECK_ADD, Type.new(:Int64), Type.new(:Int64)).type.resolved).to eq(:Int64)
    expect(Type.binary_op(:SUB, Type.new(:T), Type.new(:T)).type.resolved).to eq(:T)
    expect(Type.binary_op(:ADD, Type.new(:T), Type.new(:T)).type.resolved).to eq(:T)
    expect(Type.binary_op(:SUB, Type.new(:Int8), Type.new(:Int64)).type.resolved).to eq(:Int64)
    expect(Type.binary_op(:SUB, Type.new(:Int64), Type.new(:Int8)).type.resolved).to eq(:Int64)
    expect(Type.binary_op(:SUB, Type.new(:Float32), Type.new(:Float64)).type.resolved).to eq(:Float64)
    expect(Type.binary_op(:SUB, Type.new(:Float64), Type.new(:Float32)).type.resolved).to eq(:Float64)
    expect(Type.binary_op(:SUB, Type.new(:Int64), Type.new(:Float64)).type.resolved).to eq(:Float64)
    expect(Type.binary_op(:SUB, Type.new(:Float64), Type.new(:Int64)).type.resolved).to eq(:Float64)
    expect(Type.binary_op(:MUL, Type.new(:Any), Type.new(:Any)).type.resolved).to eq(:Any)
    expect(Type.binary_op(:SUB, Type.new(:String), Type.new(:String)).error).to include("numeric")
    expect(Type.binary_op(:ADD, Type.new(:Bool), Type.new(:Counter)).error).to eq("Cannot add types: Bool and Counter")
  end
end
