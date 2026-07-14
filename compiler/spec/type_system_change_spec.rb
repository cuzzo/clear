require "rspec"

require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/annotator/annotator" unless defined?(SemanticAnnotator)
require_relative "../ruby/compiler/module_importer" unless defined?(ModuleImporter)
require_relative "../ruby/compiler/compiler_frontend" unless defined?(CompilerFrontend)
require_relative "../ruby/mir/mir_lowering" unless defined?(MIRLowering)

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
end
