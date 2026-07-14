require "rspec"
require "set"

require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/annotator/annotator" unless defined?(SemanticAnnotator)
require_relative "../ruby/compiler/module_importer" unless defined?(ModuleImporter)
require_relative "../ruby/compiler/compiler_frontend" unless defined?(CompilerFrontend)
require_relative "../ruby/mir/mir_lowering" unless defined?(MIRLowering)
require_relative "../ruby/tools/clear_fix_support" unless defined?(ClearFixSupport::LocationToken)

RSpec.describe "type-system change contracts" do
  def parse(source)
    ClearParser.new(Lexer.new(source).tokenize, source).parse
  end

  def annotate(source)
    ast = parse(source)
    SemanticAnnotator.new(source_code: source).annotate!(ast)
    ast
  end

  def lower(source)
    importer = ModuleImporter.new(base_dir: Dir.pwd, use_mir: true)
    result = CompilerFrontend.compile(source, importer: importer, source_dir: Dir.pwd)
    MIRLowering.new(input: MIRLoweringInput.new(
      struct_schemas: result.struct_schemas,
      enum_schemas: result.enum_schemas,
      union_schemas: result.union_schemas,
      fn_sigs: result.fn_sigs,
      moved_guard_info: result.moved_guard_info,
      importer: importer,
      source_dir: Dir.pwd,
      target: :zig
    )).lower_program(result.ast)
  end

  def contains_mir?(value, expected_class, seen = {})
    return false if value.nil?
    return value.any? { |item| contains_mir?(item, expected_class, seen) } if value.is_a?(Array)
    return value.any? { |key, item| contains_mir?(key, expected_class, seen) || contains_mir?(item, expected_class, seen) } if value.is_a?(Hash)
    return false unless value.class.name&.start_with?("MIR::")
    return true if value.is_a?(expected_class)
    return false if seen[value.object_id]

    seen[value.object_id] = true
    return value.each_pair.any? { |_name, item| contains_mir?(item, expected_class, seen) } if value.respond_to?(:each_pair)

    value.instance_variables.any? { |name| contains_mir?(value.instance_variable_get(name), expected_class, seen) }
  end

  it "parses BG STREAM YIELDS as an item contract before its body" do
    ast = parse(<<~CLEAR)
      stream: ~?Int64[] = BG STREAM YIELDS ?Int64 {
        YIELD 10_i64;
        YIELD NIL;
      };
    CLEAR
    stream = ast.statements.first.value

    expect(stream).to be_a(AST::BgStreamBlock)
    expect(Type.surface_name(T.must(stream.declared_yield_type))).to eq("?Int64")
    expect(stream.yields_token&.text!).to eq("YIELDS")
  end

  it "allows definite and NIL yields under an optional item contract" do
    expect {
      annotate(<<~CLEAR)
        stream: ~?Int64[] = BG STREAM YIELDS ?Int64 {
          YIELD 10_i64;
          YIELD NIL;
        };
      CLEAR
    }.not_to raise_error
  end

  it "infers optionality without synthesizing a union" do
    ast = annotate(<<~CLEAR)
      stream: ~?Int64[] = BG STREAM {
        YIELD 10_i64;
        YIELD NIL;
      };
    CLEAR
    stream = ast.statements.first.value

    expect(stream.full_type!).to be_open_stream
  end

  it "joins optional and fallible envelopes only for the same payload" do
    left = Type.join_async_results([Type.new(:Int64), Type.new(:NIL)])
    right = Type.join_async_results([Type.new("!Int64"), Type.new("?Int64")])

    expect(Type.surface_name(T.must(left.type))).to eq("?Int64")
    expect(Type.surface_name(T.must(right.type))).to eq("!?Int64")
  end

  it "keeps the join commutative associative and idempotent" do
    values = [Type.new(:Int64), Type.new("?Int64"), Type.new("!Int64")]
    forward = T.must(Type.join_async_results(values).type)
    reverse = T.must(Type.join_async_results(values.reverse).type)
    duplicate = T.must(Type.join_async_results(values + [Type.new(:Int64)]).type)
    left_pair = T.must(Type.join_async_results(values.first(2)).type)
    associated = T.must(Type.join_async_results([left_pair, values.last]).type)

    expect([reverse, duplicate, associated].map { |type| Type.surface_name(type) })
      .to all(eq(Type.surface_name(forward)))
  end

  it "rejects unrelated payloads and future-state mixing" do
    payload_conflict = Type.join_async_results([Type.new(:Int64), Type.new(:String)])
    future_conflict = Type.join_async_results([Type.new(:Int64), Type.new("~Int64")])

    expect(payload_conflict.reason).to eq(:payload_mismatch)
    expect(future_conflict.reason).to eq(:future_mismatch)
  end

  it "rejects a yield that conflicts with an explicit item contract" do
    expect {
      annotate(<<~CLEAR)
        stream: ~?Int64[] = BG STREAM YIELDS Int64 {
          YIELD 10_i64;
          YIELD "OK";
        };
      CLEAR
    }.to raise_error(CompilerError, /inconsistent types/i)
  end

  it "infers exact positional types for Tuple literals" do
    ast = annotate(<<~CLEAR)
      value = Tuple{10_i64, "OK", TRUE};
      number = value[0];
    CLEAR
    tuple = ast.statements.first.value

    expect(tuple).to be_a(AST::TupleLit)
    expect(tuple.full_type!.generic_args.map(&:resolved)).to eq([:Int64, :"Byte[2]", :Bool])
    expect(ast.statements.last.value.resolved_type).to eq(:Int64)
  end

  it "lowers Tuple literals through the existing tuple MIR" do
    mir = lower(<<~CLEAR)
      FN main() RETURNS Void ->
        value = Tuple{10_i64, "OK", TRUE};
        RETURN;
      END
    CLEAR

    expect(contains_mir?(mir, MIR::TupleLiteral)).to be(true)
  end

  it "parses Inline Pivot aliases directly into recursive type nodes" do
    source = <<~CLEAR
      fixed: [10]Int64 = DEFAULT;
      list: []String = List[];
      set: [Set]Int64 = Set[];
      pool: [Pool(16)]Int64 = Pool[];
      map: {Symbol}[]Int64 = {};
    CLEAR
    ast = parse(source)
    types = ast.statements.map(&:type)

    expect(types.map { |type| type.shape.expression.class }).to all(be <= TypeExpression)
    expect(types[0]).to be_fixed
    expect(types[1].collection).to eq(:list)
    expect(types[2].collection).to eq(:set)
    expect(types[3].collection).to eq(:pool)
    expect(types[4]).to be_map
    expect(types[4].value_type.collection).to eq(:list)
  end

  it "parses tense and nested map layers without backtracking" do
    ast = parse("value: ?{Symbol}{Int64}[10]String = NIL;")
    type = ast.statements.first.type

    expect(type).to be_optional
    outer = T.must(type.wrapped_type)
    expect(outer.key_type.resolved).to eq(:Symbol)
    expect(outer.value_type.key_type.resolved).to eq(:Int64)
    expect(outer.value_type.value_type).to be_fixed
  end

  it "parses every predictive Inline Pivot layer without speculative replay" do
    ast = parse(<<~CLEAR)
      fallible: ![List(8)]Tuple<Int64, String> = DEFAULT;
      future: ~[Set(4)]Int64 = DEFAULT;
      callbacks: {}FN(Int64) -> Bool = {};
    CLEAR
    fallible, future, callbacks = ast.statements.map(&:type)

    expect(fallible).to be_error_union
    fallible_expression = T.cast(fallible.shape.expression, FallibleTypeExpression)
    fallible_list = Type.from_child_expression(fallible_expression.inner)
    expect(fallible_list.collection).to eq(:list)
    expect(fallible_list.shape.expression).to be_a(LinearTypeExpression)
    expect(T.cast(fallible_list.shape.expression, LinearTypeExpression).allocation_hint).to eq(8)
    expect(future).to be_future
    expect(future.tense_type.collection).to eq(:set)
    expect(callbacks.key_type.resolved).to eq(:Symbol)
    expect(callbacks.value_type.shape.expression).to be_a(FunctionTypeExpression)
  end

  it "rejects unsupported dimensions before accepting ambiguous type syntax" do
    expect { parse("value: [Matrix]Int64 = DEFAULT;") }
      .to raise_error(ParserError, /Inline Pivot dimension/)
    expect { parse("value: [10, 5]Int64 = DEFAULT;") }
      .to raise_error(ParserError, /flat-rank lowering/)
    expect { parse("value: {Symbol, Int64}String = {};") }
      .to raise_error(ParserError, /nested maps use separate brace layers/)
  end

  it "autofixes legacy annotations from their semantic type trees" do
    source = <<~CLEAR
      list: Int64[] = [];
      maybe_item: ?Int64[] = [];
      maybe_list: ?(Int64[]) = NIL;
      lookup: HashMap<Int64> = {};
      nested: HashMap<Symbol, String[]> = {};
      unique: Int64[]@set = Set[];
      arena: Int64[16]@pool = Pool[];
      optional_unique: ?(Int64[]@set) = NIL;
      fallible_unique: !Int64[]@set = DEFAULT;
      future_unique: ~Int64[]@set = DEFAULT;
    CLEAR
    expected = <<~CLEAR
      list: []Int64 = [];
      maybe_item: []?Int64 = [];
      maybe_list: ?[]Int64 = NIL;
      lookup: {String}Int64 = {};
      nested: {Symbol}[]String = {};
      unique: [Set]Int64 = Set[];
      arena: [Pool(16)]Int64 = Pool[];
      optional_unique: ?[Set]Int64 = NIL;
      fallible_unique: ![Set]Int64 = DEFAULT;
      future_unique: ~[Set]Int64 = DEFAULT;
    CLEAR

    rewritten, count, = ClearFixSupport.apply_to_source(source, only_set: Set[:type])
    expect(count).to eq(10)
    expect(rewritten).to eq(expected)
    expect(ClearFixSupport.apply_to_source(rewritten, only_set: Set[:type]).first).to eq(rewritten)
  end

  it "preserves legacy capability syntax until capabilities live on type layers" do
    source = "values: Int64[]@shared:locked = [];\n"
    rewritten, count, = ClearFixSupport.apply_to_source(source, only_set: Set[:type])
    shared = parse("value: SHARED Int64 = DEFAULT;").statements.first.type

    expect(count).to eq(0)
    expect(rewritten).to eq(source)
    expect(shared).to be_polymorphic_shared
  end
end
