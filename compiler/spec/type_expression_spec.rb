require "rspec"

require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/ast" unless defined?(AST::Node)
require_relative "../ruby/ast/type" unless defined?(Type)

RSpec.describe TypeExpressionParser do
  def expression(source)
    described_class.parse(source)
  end

  it "represents nested legacy types as recursive semantic nodes" do
    parsed = expression("?HashMap<Symbol,Tuple<Int64,String[]>>")

    expect(parsed).to be_a(OptionalTypeExpression)
    map = parsed.inner
    expect(map).to be_a(MapTypeExpression)
    expect(map.key).to be_a(NamedTypeExpression)
    expect(map.key.name).to eq(:Symbol)
    expect(map.value).to be_a(TupleTypeExpression)
    expect(map.value.items.last).to be_a(LinearTypeExpression)
  end

  it "round-trips legacy spellings without reparsing raw child symbols" do
    surfaces = [
      "Int64",
      "?String",
      "?(String[])",
      "!?(HashMap<Symbol,String[]>)",
      "~?Int64[]",
      "Tuple<String@symbol,?String>",
      "HashMap<HashMap<Int64,String>>",
      "Int64[10][5]",
    ]

    expect(surfaces.map { |surface| TypeExpressionPrinter.legacy(expression(surface)) }).to eq(surfaces)
  end

  it "preserves explicit and implicit legacy default map keys" do
    expect(TypeExpressionPrinter.legacy(expression("HashMap<Int64>"))).to eq("HashMap<Int64>")
    expect(TypeExpressionPrinter.legacy(expression("HashMap<String, Int64>"))).to eq("HashMap<String, Int64>")
    expect(TypeExpressionPrinter.legacy(expression("HashMap<String,Int64>"))).to eq("HashMap<String,Int64>")
    expect(TypeExpressionPrinter.legacy(expression("HashMap<Page<(A)>, Int64>"))).to eq("HashMap<Page<(A)>, Int64>")
    expect(described_class.send(:top_level_argument_separator, "HashMap<Page<A>>")).to eq(",")
  end

  it "prints equivalent Inline Pivot collection spellings" do
    expect(TypeExpressionPrinter.inline(expression("Int64[10][5]"))).to eq("[5][10]Int64")
    expect(TypeExpressionPrinter.inline(expression("String[]"))).to eq("[]String")
    expect(TypeExpressionPrinter.inline(expression("HashMap<String>"))).to eq("{String}String")
    expect(TypeExpressionPrinter.inline(expression("HashMap<Symbol,Int64[]>"))).to eq("{Symbol}[]Int64")
  end

  it "keeps tuple positions as semantic children" do
    tuple = expression("Tuple<Int64,String,?Bool>")

    expect(tuple).to be_a(TupleTypeExpression)
    expect(tuple.items.map { |item| TypeExpressionPrinter.inline(item) }).to eq(["Int64", "String", "?Bool"])
    expect(TypeExpressionPrinter.inline(tuple)).to eq("Tuple<Int64, String, ?Bool>")
  end

  it "prints every legacy collection marker and named generic" do
    surfaces = ["Int64[?]", "Int64[INF]", "Int64[*]", "Page<Row>"]

    expect(surfaces.map { |surface| TypeExpressionPrinter.legacy(expression(surface)) }).to eq(surfaces)
    expect(surfaces.map { |surface| TypeExpressionPrinter.inline(expression(surface)) }).to eq([
      "[~]Int64",
      "[~INF]Int64",
      "[*]Int64",
      "Page<Row>",
    ])
  end

  it "prints function and stream nodes in both surfaces" do
    signature = Type::FunctionType.new(
      params: [Type::FunctionTypeParam.new(type: Type.new(:Int64))],
      return_type: Type.new(:String)
    )
    function = FunctionTypeExpression.new(signature: signature)
    finite = StreamTypeExpression.new(cardinality: :FINITE, item: NamedTypeExpression.new(name: :Int64))
    bounded = StreamTypeExpression.new(cardinality: 10, item: NamedTypeExpression.new(name: :String))

    expect(TypeExpressionPrinter.legacy(function)).to eq("FN(Int64) -> String")
    expect(TypeExpressionPrinter.inline(function)).to eq("FN(Int64) -> String")
    expect(TypeExpressionPrinter.legacy(finite)).to eq("[~]Int64")
    expect(TypeExpressionPrinter.inline(finite)).to eq("[~]Int64")
    expect(TypeExpressionPrinter.legacy(bounded)).to eq("[~10]String")
    expect(TypeExpressionPrinter.inline(bounded)).to eq("[~10]String")
  end

  it "prints tense wrappers recursively in Inline Pivot form" do
    surfaces = ["?(String[])", "!Int64", "~Int64"]

    expect(surfaces.map { |surface| TypeExpressionPrinter.inline(expression(surface)) }).to eq([
      "?[]String",
      "!Int64",
      "~Int64",
    ])
  end

  it "rejects malformed or repeated future and fallible prefixes" do
    expect { expression("") }.to raise_error(ArgumentError, /empty type/)
    expect { expression("~~Int64") }.to raise_error(ArgumentError, /double future/)
    expect { expression("!!Int64") }.to raise_error(ArgumentError, /double fallible/)
    expect { expression("??Int64") }.to raise_error(ArgumentError, /double optional/)
    expect { expression("!~Int64") }.to raise_error(ArgumentError, /~!T/)
    expect { expression("HashMap<A,B,C>") }.to raise_error(ArgumentError, /one or two/)
  end


  it "rejects unknown expression implementations at the printer boundary" do
    unknown_class = Class.new do
      include TypeExpression
    end
    unknown = unknown_class.new

    expect { TypeExpressionPrinter.legacy(unknown) }.to raise_error(/unknown type expression/)
    expect { TypeExpressionPrinter.inline(unknown) }.to raise_error(/unknown type expression/)
  end
end

RSpec.describe TypeShape do
  it "keeps one recursive expression instead of raw child-symbol fields" do
    shape = described_class.from_core("!?HashMap<Symbol,String[]>")

    expect(shape.expression).to be_a(FallibleTypeExpression)
    expect(shape.instance_variables.sort).to eq([:@auto, :@expression])
    expect(shape.error_union).to be(true)
    expect(shape.optional).to be(true)
    expect(shape.map).to be(true)
    expect(shape.payload_type_raw).to eq(:"?(HashMap<Symbol,String[]>)")
    expect(shape.key_type_raw).to eq(:Symbol)
    expect(shape.value_type_raw).to eq(:"String[]")
    expect(shape.numeric_map?).to be(true)
  end

  it "projects legacy array and generic accessors from the expression tree" do
    array = described_class.from_core("?Tuple<Int64,String>[10]")

    expect(array.array).to be(true)
    expect(array.optional).to be(true)
    expect(array.capacity).to eq(10)
    expect(array.element_type_raw).to eq(:"Tuple<Int64,String>")
    expect(array.generic_instance).to be(false)

    tuple = described_class.from_core("Tuple<Int64,?String>")
    expect(tuple.generic_instance).to be(true)
    expect(tuple.generic_base_raw).to eq(:Tuple)
    expect(tuple.generic_args_raw).to eq([:Int64, :"?String"])
  end

  it "projects future, optional, function, and copy accessors" do
    future = described_class.from_core("~?Int64[]", auto: true)
    expect(future.tense).to be(true)
    expect(future.tense_type_raw).to eq(:"?Int64[]")
    expect(future.copy.auto).to be(true)
    expect(future.copy_with_auto(false).auto).to be(false)

    optional = described_class.from_core("?String")
    expect(optional.wrapped_type_raw).to eq(:String)
    expect(optional.wrapped_function_type_raw).to be_nil

    signature = Type::FunctionType.new(params: [], return_type: Type.new(:Void))
    function = described_class.new(raw: signature)
    optional_function = described_class.new(
      raw: :Any,
      optional: true,
      wrapped_function_type_raw: signature
    )
    expect(function.fn_type?).to be(true)
    expect(function.resolved).to eq(:Any)
    expect(optional_function.wrapped_function_type_raw).to equal(signature)
    expect(optional_function.wrapped_type_raw).to be_nil
  end

  it "keeps String-keyed maps non-numeric and rejects fallible futures" do
    expect(described_class.from_core("HashMap<String>").numeric_map?).to be(false)
    expect { described_class.from_core("!~Int64") }.to raise_error(/~!T/)
  end

  it "does not mistake a leading Zig builtin marker for CLEAR capabilities" do
    type = Type.new("@TypeOf(it)")

    expect(type.resolved).to eq(:"@TypeOf(it)")
    expect(type.ownership).to eq(:affine)
    expect(type.any_sync?).to be(false)
  end
end
