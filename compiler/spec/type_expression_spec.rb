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

  it "keeps empty generic positions and canonicalizes legacy ownership spellings" do
    expect(Type.new(:Int64).shape.generic_args_raw).to eq([])
    expect(Type.new(:"?Int64").shape.generic_args_raw).to eq([])
    expect(Type.new(:"?Int64[]").shape.generic_args_raw).to eq([])
    expect(Type.new("Box@multiowned")).to be_multiowned
  end

  it "refuses to migrate a capability-bearing tense wrapper across its child" do
    expression = OptionalTypeExpression.new(
      inner: LinearTypeExpression.new(
        kind: :list,
        dimensions: [:LIST],
        item: NamedTypeExpression.new(name: :Int64),
      ),
      capabilities: TypeCapabilities.new(ownership: :shared, collection: :list),
    )

    expect(Type.inline_migration_name(Type.new(expression))).to be_nil
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

  it "prints an explicit dynamic array dimension without changing its rank" do
    dynamic = LinearTypeExpression.new(
      kind: :array,
      dimensions: [:LIST],
      item: NamedTypeExpression.new(name: :Int64)
    )

    expect(TypeExpressionPrinter.inline(dynamic)).to eq("[List]Int64")
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

  it "parses every canonical stream cardinality from its textual surface" do
    finite = expression("[~]Int64")
    infinite = expression("[~INF]String")
    bounded = expression("[~12]Bool")

    expect(T.cast(finite, StreamTypeExpression).cardinality).to eq(:FINITE)
    expect(T.cast(infinite, StreamTypeExpression).cardinality).to eq(:INF)
    expect(T.cast(bounded, StreamTypeExpression).cardinality).to eq(12)
    expect(TypeShape.from_core("[~]Int64").tense_type_raw).to eq(:"Int64[]")
  end

  it "projects inline stream nodes through the runtime stream API without losing optional items" do
    finite = Type.new(StreamTypeExpression.new(
      cardinality: :FINITE,
      item: OptionalTypeExpression.new(inner: NamedTypeExpression.new(name: :Int64))
    ))
    infinite = Type.new(StreamTypeExpression.new(
      cardinality: :INF,
      item: NamedTypeExpression.new(name: :String)
    ))

    expect(finite).to be_future
    expect(finite).to be_dynamic_stream
    expect(finite.tense_type.element_type).to be_optional
    expect(finite.zig_type).to eq("CheatLib.Stream(?i64)")
    expect(infinite).to be_inf_stream
    expect(infinite.zig_type).to eq("CheatLib.InfStream([]const u8)")
  end

  it "maps StreamStep<T> to the runtime tagged step type" do
    step = Type.stream_step_of(Type.optional_of(:Int64))

    expect(step).to be_stream_step
    expect(step.stream_step_item_type).to be_optional
    expect(step.zig_type).to eq("CheatLib.StreamStep(?i64)")
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

RSpec.describe "recursive Type accessors" do
  it "constructs every child Type directly from semantic nodes" do
    type = Type.new("~!?HashMap<Symbol,Tuple<Int64,String[]>>")
    allow(TypeExpressionParser).to receive(:parse).and_raise("child type was reparsed")

    future_payload = type.tense_type
    fallible_payload = T.must(future_payload.payload_type)
    map = T.must(fallible_payload.wrapped_type)
    expect(map.key_type.resolved).to eq(:Symbol)
    tuple = map.value_type
    expect(tuple.generic_args.map(&:resolved)).to eq([:Int64, :"String[]"])
    expect(T.must(tuple.generic_args.last.element_type).resolved).to eq(:String)
  end


  it "isolates legacy nested capability suffix compatibility" do
    map = Type.new("HashMap<String,Box@shared@locked>")

    expect(map.value_type.resolved).to eq(:Box)
    expect(map.value_type.ownership).to eq(:shared)
    expect(map.value_type.sync).to eq(:locked)
  end

  it "keeps the legacy non-future tense fallback total" do
    expect(Type.new(:Int64).tense_type.resolved).to eq(:Void)
  end
end

RSpec.describe TypeExpressionTree do
  it "replaces nominal arguments through streams and leaves unrelated nodes intact" do
    tuple = TupleTypeExpression.new(items: [NamedTypeExpression.new(name: :Old)])
    stream = StreamTypeExpression.new(cardinality: :FINITE, item: tuple)
    replacement = NamedTypeExpression.new(name: :Int64)
    updated = described_class.with_nominal_arguments(stream, :Tuple, [replacement])

    expect(updated).to be_a(StreamTypeExpression)
    updated_tuple = T.cast(T.cast(updated, StreamTypeExpression).item, TupleTypeExpression)
    expect(updated_tuple.items).to contain_exactly(replacement)

    wrapped = [
      OptionalTypeExpression.new(inner: tuple),
      FallibleTypeExpression.new(inner: tuple),
      FutureTypeExpression.new(inner: tuple),
      LinearTypeExpression.new(kind: :list, dimensions: [:LIST], item: tuple),
    ]
    expect(wrapped.map { |node| described_class.with_nominal_arguments(node, :Tuple, [replacement]).class })
      .to eq(wrapped.map(&:class))

    named = NamedTypeExpression.new(name: :Box)
    updated_named = T.cast(described_class.with_nominal_arguments(named, :Box, [replacement]), NamedTypeExpression)
    expect(updated_named.arguments).to contain_exactly(replacement)
    expect(described_class.with_nominal_arguments(named, :Other, [replacement])).to equal(named)

    signature = Type::FunctionType.new(params: [], return_type: Type.new(:Void))
    function = FunctionTypeExpression.new(signature: signature)
    expect(described_class.with_nominal_arguments(function, :Tuple, [replacement])).to equal(function)

    map = MapTypeExpression.new(
      key: NamedTypeExpression.new(name: :String),
      value: NamedTypeExpression.new(name: :Old),
    )
    updated_map = T.cast(described_class.with_nominal_arguments(map, :HashMap, [replacement]), MapTypeExpression)
    expect(updated_map.value).to equal(replacement)

    unknown_class = Class.new do
      include TypeExpression
      define_method(:capabilities) { TypeCapabilities.new(ownership: :affine) }
    end
    unknown = T.cast(unknown_class.new, TypeExpression)
    expect(described_class.with_nominal_arguments(unknown, :Tuple, [replacement])).to equal(unknown)
  end

  it "updates capability-bearing unary and stream nodes exhaustively" do
    item = NamedTypeExpression.new(name: :Item)
    linear = LinearTypeExpression.new(kind: :list, dimensions: [:LIST], item: item)
    wrapped = FutureTypeExpression.new(
      inner: FallibleTypeExpression.new(inner: OptionalTypeExpression.new(inner: linear))
    )
    caps = TypeCapabilities.new(ownership: :shared, sync: :locked)
    updated = described_class.with_linear_item_capabilities(wrapped, caps)

    expect(described_class.linear_item_capabilities(updated)).to eq(caps)

    stream = StreamTypeExpression.new(cardinality: :FINITE, item: item)
    updated_stream = described_class.with_root_capabilities(stream, caps)
    expect(described_class.root_capabilities(updated_stream)).to eq(caps)
  end

  it "counts function parameter and result nodes and keeps unknown variants total" do
    signature = Type::FunctionType.new(
      params: [Type::FunctionTypeParam.new(type: Type.new(:Int64))],
      return_type: Type.new(:String)
    )
    function = FunctionTypeExpression.new(signature: signature)
    unknown_class = Class.new do
      include TypeExpression
      define_method(:capabilities) { TypeCapabilities.new(ownership: :affine) }
    end
    unknown = T.cast(unknown_class.new, TypeExpression)
    caps = TypeCapabilities.new(ownership: :shared)

    expect(described_class.node_count(function)).to eq(3)
    expect(described_class.root_capabilities(unknown).ownership).to eq(:affine)
    expect(described_class.with_root_capabilities(unknown, caps)).to equal(unknown)
    expect(described_class.node_count(unknown)).to eq(1)
  end

  it "normalizes every supported legacy capability dimension" do
    expected = {
      "Box@multiowned" => [:multiowned, nil, nil],
      "Box@link" => [:link, nil, nil],
      "Box@split" => [:split, nil, nil],
      "Box@writeLocked" => [:affine, :write_locked, nil],
      "Box@versioned" => [:affine, :versioned, nil],
      "Box@atomic" => [:affine, :atomic, nil],
      "Box@local" => [:affine, :local, nil],
      "Box@raw" => [:affine, :raw, nil],
      "Box@symbol" => [:affine, :symbol, nil],
      "Box@boxed" => [:affine, nil, :indirect],
    }

    expected.each do |source, dimensions|
      expression = TypeExpressionParser.parse(source)
      caps = described_class.root_capabilities(expression)
      expect([caps.ownership, caps.sync, caps.layout]).to eq(dimensions)
    end
  end
end

RSpec.describe TypeShape do
  it "keeps one recursive expression instead of raw child-symbol fields" do
    shape = described_class.from_core("!?HashMap<Symbol,String[]>")

    expect(shape.expression).to be_a(FallibleTypeExpression)
    expect(shape.instance_variables.sort).to eq([:@auto, :@expression, :@legacy_raw])
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

  it "renders the legacy shape once and reuses it for repeated projections" do
    shape = described_class.from_core("?Tuple<Int64,String>[10]")
    expect(TypeExpressionPrinter).not_to receive(:legacy)

    3.times do
      expect(shape.raw).to eq(:"?Tuple<Int64,String>[10]")
      expect(shape.resolved).to eq(:"?Tuple<Int64,String>[10]")
    end
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
