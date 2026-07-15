require "rspec"
require "set"

require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/annotator/annotator" unless defined?(SemanticAnnotator)
require_relative "../ruby/compiler/module_importer" unless defined?(ModuleImporter)
require_relative "../ruby/compiler/compiler_frontend" unless defined?(CompilerFrontend)
require_relative "../ruby/mir/mir_lowering" unless defined?(MIRLowering)
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)
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

  def lower(source, target: :zig)
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
      target: target
    )).lower_program(result.ast)
  end

  def transpile(source)
    ZigTranspiler.new(source_dir: Dir.pwd).transpile(source)
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

  it "requires YIELDS for future items but not optional or fallible widening" do
    expect {
      annotate(<<~CLEAR)
        promise: ~Int64 = BG { 10_i64; };
        stream = BG STREAM { YIELD promise; };
      CLEAR
    }.to raise_error(CompilerError, /requires an explicit item contract.*YIELDS ~Int64/m)

    expect {
      annotate(<<~CLEAR)
        promise: ~Int64 = BG { 10_i64; };
        stream = BG STREAM YIELDS ~Int64 { YIELD promise; };
      CLEAR
    }.not_to raise_error

    expect {
      annotate("stream = BG STREAM { YIELD 10_i64; YIELD NIL; };")
    }.not_to raise_error
  end

  it "requires YIELDS for a named union even when all variants share its type" do
    source = <<~CLEAR
      UNION NumberOrText { Number: Int64, Text: String }
      stream = BG STREAM {
        YIELD NumberOrText{ Number: 10_i64 };
        YIELD NumberOrText{ Text: "OK" };
      };
    CLEAR

    expect { annotate(source) }
      .to raise_error(CompilerError, /YIELDS NumberOrText/)
    expect {
      annotate(source.sub("BG STREAM {", "BG STREAM YIELDS NumberOrText {"))
    }.not_to raise_error
  end

  it "offers an exact clear-fix insertion when a YIELDS contract is knowable" do
    source = <<~CLEAR
      promise: ~Int64 = BG { 10_i64; };
      stream = BG STREAM { YIELD promise; };
    CLEAR
    findings = ClearFixSupport.collect_findings(source, source_dir: Dir.pwd)
    finding = findings.find { |item| item.message.include?("YIELDS ~Int64") }

    expect(finding).not_to be_nil
    edit = T.must(finding).fixes.first.edits.first
    expect(edit.replacement).to eq(" YIELDS ~Int64")
    line = source.lines.fetch(edit.span.line - 1)
    rewritten = line.dup.insert(edit.span.col - 1, edit.replacement)
    expect(rewritten).to include("BG STREAM YIELDS ~Int64 {")
  end

  it "diagnoses heterogeneous yields with both viable remedies" do
    expect {
      annotate('stream = BG STREAM { YIELD 10_i64; YIELD "OK"; };')
    }.to raise_error(CompilerError, /Union<Int64, Byte\[2\]>.*add `YIELDS YourUnion`.*OR change one of the YIELD/m)
  end

  it "parses CLOSE as an explicit stream terminator" do
    stream = parse("stream = BG STREAM { YIELD 1_i64; CLOSE; };").statements.first.value

    expect(stream.body.last).to be_a(AST::CloseStream)
  end

  it "keeps yielded NIL distinct from finite stream completion" do
    ast = annotate(<<~CLEAR)
      stream = BG STREAM { YIELD 10_i64; YIELD NIL; };
      step = NEXT stream;
    CLEAR
    stream = ast.statements.fetch(0).value
    step = ast.statements.fetch(1).value

    expect(stream.full_type!).to be_dynamic_stream
    expect(stream.full_type!.tense_type.element_type).to be_optional
    expect(step.full_type!).to be_stream_step
    expect(step.full_type!.stream_step_item_type).to be_optional
  end

  it "uses EXISTS AS to bind a StreamStep item without unwrapping its optional payload" do
    zig = transpile(<<~CLEAR)
      stream = BG STREAM { YIELD 10_i64; YIELD NIL; };
      IF NEXT stream EXISTS AS item THEN
        seen = item;
      END
    CLEAR

    expect(zig).to include(".nextStep()")
    expect(zig).to include(".Item => |item|")
    expect(zig).to include(".Closed =>")
  end

  it "uses StreamStep for canonical bounded streams while preserving legacy NEXT" do
    canonical = annotate(<<~CLEAR)
      stream: [~2]Int64 = [BG { 10_i64; }, BG { 20_i64; }];
      step = NEXT stream;
    CLEAR
    legacy = annotate(<<~CLEAR)
      stream: ~Int64[2] = [BG { 10_i64; }, BG { 20_i64; }];
      item = NEXT stream;
    CLEAR

    expect(canonical.statements.last.value.full_type!).to be_stream_step
    expect(legacy.statements.last.value.resolved_type).to eq(:Int64)
  end

  it "rejects CLOSE outside a stream and YIELD after CLOSE" do
    expect { annotate("CLOSE;") }
      .to raise_error(CompilerError, /CLOSE can only be used inside a BG STREAM/)
    expect {
      annotate("stream = BG STREAM { CLOSE; YIELD 1_i64; };")
    }.to raise_error(CompilerError, /YIELD cannot follow CLOSE/)
  end

  it "lowers explicit CLOSE and relies on idempotent deferred close for fallthrough" do
    zig = transpile(<<~CLEAR)
      stream = BG STREAM { YIELD 1_i64; CLOSE; };
      step = NEXT stream;
    CLEAR

    expect(zig).to include(".close();")
    expect(zig).to include("return;")
    expect(zig).to include(".nextStep()")
  end

  it "rejects explicit and implicit normal completion for infinite streams" do
    expect {
      annotate("stream: ~Int64[INF] = BG STREAM { YIELD 1_i64; CLOSE; };")
    }.to raise_error(CompilerError, /infinite stream cannot execute CLOSE/i)
    expect {
      annotate("stream: ~Int64[INF] = BG STREAM { YIELD 1_i64; };")
    }.to raise_error(CompilerError, /infinite stream producer can reach the end/i)
    expect {
      annotate("stream: ~Int64[INF] = BG STREAM { WHILE TRUE DO YIELD 1_i64; END };")
    }.not_to raise_error
    expect {
      annotate(<<~CLEAR)
        stream: ~Int64[INF] = BG STREAM {
          WHILE TRUE DO
            WHILE FALSE DO BREAK; END
            YIELD 1_i64;
          END
        };
      CLEAR
    }.not_to raise_error
  end

  it "parses canonical infinite streams and proves branch-complete producers cannot fall through" do
    expect {
      annotate(<<~CLEAR)
        stream: [~INF]Int64 = BG STREAM {
          IF TRUE THEN
            WHILE TRUE DO YIELD 1_i64; END
          ELSE
            WHILE TRUE DO YIELD 2_i64; END
          END
        };
      CLEAR
    }.not_to raise_error

    expect {
      annotate(<<~CLEAR)
        stream: [~INF]Int64 = BG STREAM {
          IF TRUE THEN WHILE TRUE DO YIELD 1_i64; END END
        };
      CLEAR
    }.to raise_error(CompilerError, /can reach the end/i)
  end

  it "proves branch-complete optional bindings cannot fall through" do
    prelude = <<~CLEAR
      FN maybe() RETURNS ?Bool -> RETURN TRUE; END
    CLEAR
    expect {
      annotate(prelude + <<~CLEAR)
        stream: [~INF]Int64 = BG STREAM {
          IF maybe() EXISTS AS flag THEN
            WHILE TRUE DO YIELD 1_i64; END
          ELSE
            WHILE TRUE DO YIELD 2_i64; END
          END
        };
      CLEAR
    }.not_to raise_error

    expect {
      annotate(prelude + <<~CLEAR)
        stream: [~INF]Int64 = BG STREAM {
          IF maybe() EXISTS AS flag THEN WHILE TRUE DO YIELD 1_i64; END END
        };
      CLEAR
    }.to raise_error(CompilerError, /can reach the end/i)
  end

  it "lowers finite CLOSE to the bytecode stream exit label" do
    mir = lower("stream = BG STREAM { YIELD 1_i64; CLOSE; };", target: :bc)

    expect(contains_mir?(mir, MIR::BreakStmt)).to be(true)
  end

  it "infers exact positional types for Tuple literals" do
    ast = annotate(<<~CLEAR)
      value = Tuple{10_i64, "OK", TRUE};
      number = value._0;
      text = value._1;
      flag = value._2;
    CLEAR
    tuple = ast.statements.first.value

    expect(tuple).to be_a(AST::TupleLit)
    expect(tuple.full_type!.generic_args.map(&:resolved)).to eq([:Int64, :"Byte[2]", :Bool])
    expect(ast.statements.drop(1).map { |statement| statement.value.resolved_type })
      .to eq([:Int64, :"Byte[2]", :Bool])
  end

  it "keeps Tuple access distinct from homogeneous array indexing" do
    expect { annotate('value = Tuple{"hi", 1_i64}; missing = value._2;') }
      .to raise_error(CompilerError, /Position 2 is out of bounds.*2 positions/)
    expect { annotate('value = Tuple{"hi", 1_i64}; first = value[0];') }
      .to raise_error(CompilerError, /Tuple values use positional fields/)
    expect { annotate('value: Int64 = 1_i64; first = value._0;') }
      .to raise_error(CompilerError, /field.*_0|_0.*field/i)
  end

  it "emits Tuple positional fields as Zig anonymous-struct fields" do
    zig = transpile(<<~CLEAR)
      FN main() RETURNS Void ->
        value: Tuple<Bool, Int64> = Tuple{TRUE, 1_i64};
        flag = value._0;
        number = value._1;
        RETURN;
      END
    CLEAR

    declared = parse("value: Tuple<Bool, Int64> = DEFAULT;").statements.first.type
    expect(declared.zig_type).to eq("struct { bool, i64 }")
    expect(zig).to include("const value = .{true, 1}")
    expect(zig).to include('.@"0"')
    expect(zig).to include('.@"1"')
  end

  it "keeps legacy contextual Tuple literals on the shared lowering path" do
    zig = transpile(<<~CLEAR)
      FN main() RETURNS Void ->
        value: Tuple<Bool, Int64> = [TRUE, 1_i64];
        RETURN;
      END
    CLEAR

    expect(zig).to include("const value = .{true, 1}")
  end

  it "renders fixed SOA elements through recursive nested type lowering" do
    plain, locked = parse(<<~CLEAR).statements.map(&:type)
      plain: [2]@soa Int64 = DEFAULT;
      locked: [2]@soa:locked Int64 = DEFAULT;
    CLEAR

    expect(plain.zig_type).to eq("CheatLib.SoaList(i64)")
    expect(locked.zig_type).to eq("*CheatLib.Locked(CheatLib.SoaList(i64))")
  end

  it "owns cleanup-bearing values nested in typed Tuple literals" do
    zig = transpile(<<~CLEAR)
      FN main() RETURNS Void ->
        value: Tuple<String, Int64> = Tuple{"hello", 1_i64};
        text = value._0;
        RETURN;
      END
    CLEAR

    expect(zig).to match(/const __tmp_\d+ = @as\(\[\]const u8, try rt\.heapAlloc\(\)\.dupe\(u8, "hello"\)\)/)
    expect(zig).to match(/const value = \.\{__tmp_\d+, 1\}/)
    expect(zig).to include('CheatLib.cleanup(@TypeOf(value), rt.heapAlloc(), &value)')
    expect(zig).to match(/errdefer if \(!__tmp_\d+_moved\) CheatLib\.cleanup/)
    expect(zig).to match(/__tmp_\d+_moved = true/)
    expect(zig.scan(/__tmp_\d+_moved = true/).length).to eq(1)
  end

  it "cleans a future field without changing ordinary promise-list allocation" do
    tuple_zig = transpile(<<~CLEAR)
      FN main() RETURNS Void ->
        value: Tuple<~Int64, Bool> = Tuple{BG { RETURN 20_i64; }, TRUE};
        RETURN;
      END
    CLEAR
    list_zig = transpile(<<~CLEAR)
      FN main() RETURNS Void ->
        MUTABLE futures: [List]~Void = List[];
        futures.append(BG { sleep(1_i64); });
        RETURN;
      END
    CLEAR

    expect(tuple_zig).to include("CheatLib.cleanup(@TypeOf(value), rt.heapAlloc(), &value)")
    expect(list_zig).to include("try futures.append(rt.frameAlloc()")
  end

  it "validates recursively nested Tuple and nominal generic arguments" do
    expect { annotate("value: Tuple<Tuple<Int64, Bool>, Bool> = DEFAULT;") }
      .not_to raise_error
    expect {
      annotate(<<~CLEAR)
        STRUCT Box<T> { value: T }
        value: Tuple<Box<Int64>, Bool> = Tuple{Box<Int64>{ value: 1_i64 }, TRUE};
      CLEAR
    }.not_to raise_error
    expect {
      annotate(<<~CLEAR)
        STRUCT Box<T> { value: T }
        value: Tuple<Box<Int64, Bool>, Bool> = DEFAULT;
      CLEAR
    }.to raise_error(CompilerError, /expects 1 type argument.*got 2/i)
    expect { annotate("value: Tuple<Missing<Int64>, Bool> = DEFAULT;") }
      .to raise_error(CompilerError, /Unknown type argument/i)
  end

  it "composes Tuple recursively with collections and layer capabilities" do
    types = parse(<<~CLEAR).statements.map(&:type)
      fixed_outer: [2]Tuple<Int64, Bool> = DEFAULT;
      list_outer: [List]Tuple<Int64, Bool> = DEFAULT;
      pool_outer: [Pool(4)]Tuple<Int64, Bool> = DEFAULT;
      set_outer: [Set]Tuple<Int64, Bool> = DEFAULT;
      map_outer: {String}Tuple<Int64, Bool> = DEFAULT;
      tuple_inner: Tuple<[2]Int64, []Bool, [Pool(4)]Int64, [Set]Bool, {String}Int64> = DEFAULT;
      capable_inner: Tuple<[]@shared Int64, {String}@sharded(2) Bool> = DEFAULT;
    CLEAR

    expect(types.first.element_type).to be_tuple
    expect(types[1].element_type).to be_tuple
    expect(types[2].element_type).to be_tuple
    expect(types[3].element_type).to be_tuple
    expect(types[4].value_type).to be_tuple
    inner = types[5].generic_args
    expect(inner[0]).to be_fixed
    expect(inner[1]).to be_list_collection
    expect(inner[2]).to be_pool
    expect(inner[3]).to be_set_collection
    expect(inner[4]).to be_map
    expect(types[6].generic_args.first).to be_shared
    expect(types[6].generic_args.last).to be_sharded
  end

  it "preserves the exact Tuple or collection node gated by each tense" do
    type = parse(<<~CLEAR).statements.first.type
      value: Tuple<?[]Int64, []?Int64, !{String}Int64, {String}!Int64, ~[]Int64, []~Int64> = DEFAULT;
    CLEAR
    optional_list, list_optional, fallible_map, map_fallible, future_list, list_future = type.generic_args

    expect(optional_list).to be_optional
    expect(T.must(optional_list.wrapped_type)).to be_list_collection
    expect(list_optional).to be_list_collection
    expect(T.must(list_optional.element_type)).to be_optional
    expect(fallible_map).to be_error_union
    expect(T.must(fallible_map.success_type)).to be_map
    expect(map_fallible).to be_map
    expect(map_fallible.value_type).to be_error_union
    expect(future_list).to be_tense
    expect(T.must(future_list.tense_type)).to be_list_collection
    expect(list_future).to be_list_collection
    expect(T.must(list_future.element_type)).to be_tense
    expect(Type.new("Tuple<!Int64, Bool>").zig_type).to eq("struct { anyerror!i64, bool }")
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

  it "classifies Inline Pivot maps from their semantic key types" do
    symbol_map, string_map, numeric_map = parse(<<~CLEAR).statements.map(&:type)
      by_symbol: {Symbol}Int64 = {};
      by_string: {String}Int64 = {};
      by_number: {Int64}String = {};
    CLEAR

    expect(symbol_map).not_to be_numeric_map
    expect(string_map).not_to be_numeric_map
    expect(numeric_map).to be_numeric_map
  end

  it "annotates canonical string-like and numeric map operations" do
    expect {
      annotate(<<~CLEAR)
        by_symbol: {Symbol}Int64 = {};
        by_symbol.put("answer", 42_i64);
        symbol_value = by_symbol["answer"];
        by_number: {Int64}String = {};
        by_number.put(42_i64, "answer");
        numeric_value = by_number[42_i64];
      CLEAR
    }.not_to raise_error
  end

  it "lowers canonical collection layers and their allocation hints" do
    zig = transpile(<<~CLEAR)
      FN main() RETURNS !Void ->
        list: [List(10)]Int64 = [1_i64, 2_i64];
        empty_list: [List(9)]Int64 = List[];
        set: [Set(12)]Int64 = Set[];
        pool: [Pool(16)]Int64 = Pool[];
        by_symbol: {Symbol}Int64 = {};
        by_number: {Int64}String = {};
        RETURN;
      END
    CLEAR

    expect(zig).to include("makeListCapacity(i64")
    expect(zig).to include("&.{ 1, 2 }, 10")
    expect(zig).to include("std.ArrayListUnmanaged(i64).initCapacity")
    expect(zig).to include(", 9)")
    expect(zig).to include("CheatLib.Set(i64).initCapacity")
    expect(zig).to include(", 12)")
    expect(zig).to include("CheatLib.Pool(i64).initCapacity")
    expect(zig).to include(", 16)")
    expect(zig).to include("CheatLib.StringMap(i64)")
    expect(zig).to include("CheatLib.NumericMapType(i64, []const u8)")
  end

  it "keeps pre-allocation hints at value construction sites" do
    expect {
      annotate("FN consume(values: [List(8)]Int64) RETURNS Void -> RETURN; END")
    }.to raise_error(CompilerError, /pre-allocation hints are allowed only on initialized local bindings/)

    expect {
      annotate("FN create() RETURNS [Set(8)]Int64 -> RETURN Set[]; END")
    }.to raise_error(CompilerError, /pre-allocation hints are allowed only on initialized local bindings/)

    expect {
      annotate("STRUCT Cache { values: [List(8)]Int64 }")
    }.to raise_error(CompilerError, /pre-allocation hints are allowed only on initialized local bindings/)

    expect {
      annotate("FN use_pool(values: [Pool(8)]Int64) RETURNS Void -> RETURN; END")
    }.not_to raise_error
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
    expect { parse("value: {Symbol, Int64}String = {};") }
      .to raise_error(ParserError, /nested maps use separate brace layers/)
  end

  it "models comma dimensions as one flat rectangular rank" do
    fixed, dynamic, mixed = parse(<<~CLEAR).statements.map(&:type)
      fixed: [2, 3]Int64 = [1_i64, 2_i64, 3_i64, 4_i64, 5_i64, 6_i64];
      dynamic: [List, List]Int64 = List[];
      mixed: [4, List]Int64 = List[];
    CLEAR

    expect(fixed.rank_dimensions).to eq([2, 3])
    expect(fixed.capacity).to eq(6)
    expect(fixed).to be_fixed_rank
    expect(dynamic.rank_dimensions).to eq(%i[LIST LIST])
    expect(dynamic).to be_dynamic_rank
    expect(mixed.rank_dimensions).to eq([4, :LIST])
    expect(TypeExpressionPrinter.inline(fixed.shape.expression)).to eq("[2, 3]Int64")
    expect(fixed.fixed_position_count).to eq(6)
    expect(fixed.fixed_position_type(5)&.resolved).to eq(:Int64)
    expect(fixed.fixed_position_type(6)).to be_nil
  end


  it "rejects collection layouts and unknown dimensions inside a flat rank" do
    expect { parse("value: [Set, List]Int64 = DEFAULT;") }
      .to raise_error(ParserError, /integer or List dimensions/)
    expect { parse("value: [List, Set]Int64 = DEFAULT;") }
      .to raise_error(ParserError, /integer or List dimensions/)
  end

  it "type-checks complete integer coordinates and exact fixed storage" do
    ast = annotate(<<~CLEAR)
      matrix: [2, 3]Int64 = [1_i64, 2_i64, 3_i64, 4_i64, 5_i64, 6_i64];
      item = matrix[1_i64, 2_i64];
    CLEAR

    expect(ast.statements.last.value.resolved_type).to eq(:Int64)
    expect { annotate("matrix: [2, 3]Int64 = [1_i64];") }
      .to raise_error(CompilerError, /requires 6 items, got 1/)
    expect { annotate("matrix: [2, 3]Int64 = DEFAULT; item = matrix[1_i64];") }
      .to raise_error(CompilerError, /expects 2 indices, got 1/)
    expect { annotate('matrix: [2, 3]Int64 = DEFAULT; item = matrix[1_i64, "x"];') }
      .to raise_error(CompilerError, /indices must be integers/)
    expect { annotate("matrix: [List, List]Int64 = [1_i64];") }
      .to raise_error(CompilerError, /requires explicit shape metadata/)
  end

  it "lowers fixed and dynamic ranks to flat layouts with checked indexing" do
    zig = transpile(<<~CLEAR)
      FN main() RETURNS Void ->
        MUTABLE matrix: [2, 3]Int64 = [1_i64, 2_i64, 3_i64, 4_i64, 5_i64, 6_i64];
        item = matrix[1_i64, 2_i64];
        matrix[0_i64, 1_i64] = item;
        grid: [List, List]Int64 = List[];
        grid_item = grid[0_i64, 0_i64];
        RETURN;
      END
    CLEAR

    expect(zig).to include("[6]i64")
    expect(zig).to include("CheatLib.rankGet")
    expect(zig).to include("CheatLib.rankSet")
    expect(zig).to include("[2]usize{ 2, 3 }")
    expect(zig).to include("[2]usize{ @as(usize, @intCast(1)), @as(usize, @intCast(2)) }")
    expect(zig).to include("CheatLib.Grid(i64, 2)")
    expect(zig).to include("grid.shape")
    expect(zig).to include(".empty")
  end

  it "autofixes legacy annotations from their semantic type trees" do
    source = <<~CLEAR
      list: Int64[]@list = [];
      maybe_item: ?Int64[]@list = [];
      maybe_list: ?(Int64[]@list) = NIL;
      lookup: HashMap<Int64> = {};
      nested: HashMap<Symbol, String[]@list> = {};
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
      future_unique: ~Int64[]@set = DEFAULT;
    CLEAR

    rewritten, count, = ClearFixSupport.apply_to_source(source, only_set: Set[:type_migration])
    expect(count).to eq(9)
    expect(rewritten).to eq(expected)
    expect(ClearFixSupport.apply_to_source(rewritten, only_set: Set[:type_migration]).first).to eq(rewritten)
  end

  it "does not auto-migrate overloaded legacy async collection annotations" do
    source = <<~CLEAR
      bounded: ~Int64[2] = DEFAULT;
      open: ~?Int64[] = DEFAULT;
      infinite: ~Int64[INF] = DEFAULT;
      ambiguous_list: ~Int64[]@list = DEFAULT;
    CLEAR

    rewritten, count, = ClearFixSupport.apply_to_source(source, only_set: Set[:type_migration])
    expect(count).to eq(0)
    expect(rewritten).to eq(source)
  end

  it "does not rewrite a legacy slice as an owned Inline Pivot list" do
    source = "values: Int64[] = [];\n"
    rewritten, count, = ClearFixSupport.apply_to_source(source, only_set: Set[:type_migration])

    expect(count).to eq(0)
    expect(rewritten).to eq(source)
  end

  it "does not treat nominal aliases as collection-syntax migrations" do
    source = "value: Number = 1.0;\n"
    rewritten, count, = ClearFixSupport.apply_to_source(source, only_set: Set[:type_migration])

    expect(count).to eq(0)
    expect(rewritten).to eq(source)
  end

  it "leaves a legacy capacity-free pool unchanged because Inline Pivot pools require a bound" do
    source = "values: Int64[]@pool = Pool[];\n"
    rewritten, count, = ClearFixSupport.apply_to_source(source, only_set: Set[:type_migration])

    expect(count).to eq(0)
    expect(rewritten).to eq(source)
  end

  it "migrates collection and element capabilities onto their exact layers" do
    source = "values: Int64[]@list:shared:locked = [];\n"
    rewritten, count, = ClearFixSupport.apply_to_source(source, only_set: Set[:type_migration])
    element_source = "values: Int64@shared[]@list = [];\n"
    element_rewritten, element_count, = ClearFixSupport.apply_to_source(element_source, only_set: Set[:type_migration])
    shared = parse("value: SHARED Int64 = DEFAULT;").statements.first.type

    expect(count).to eq(1)
    expect(rewritten).to eq("values: []@shared:locked Int64 = [];\n")
    expect(element_count).to eq(1)
    expect(element_rewritten).to eq("values: []Int64@shared = [];\n")
    expect(shared).to be_polymorphic_shared
  end


  it "attaches capabilities to the exact Inline Pivot layers" do
    type = parse("value: [List]@local {Symbol}@shared:locked Int64 = DEFAULT;")
      .statements.first.type
    map = T.must(type.element_type)

    expect(type.sync).to eq(:local)
    expect(map).to be_map
    expect(map.ownership).to eq(:shared)
    expect(map.sync).to eq(:locked)
    expect(map.value_type.resolved).to eq(:Int64)
    expect(TypeExpressionTree.capability_site_count(type.shape.expression)).to eq(2)
    expect(TypeExpressionPrinter.inline(type.shape.expression))
      .to eq("[]@local {Symbol}@shared:locked Int64")

    boxed_item = parse("value: []Int64@boxed = DEFAULT;").statements.first.type
    expect(T.must(boxed_item.element_type).layout).to eq(:indirect)
  end

  it "accepts legacy @indirect while fixing it to canonical @boxed" do
    source = <<~CLEAR
      value: []Int64@indirect = DEFAULT;
      shared_value: []Int64@shared:indirect = DEFAULT;
    CLEAR
    rewritten, count, = ClearFixSupport.apply_to_source(source, only_set: Set[:type_migration])

    expect(parse(source).statements.first.type.element_type&.layout).to eq(:indirect)
    expect(count).to eq(2)
    expect(rewritten).to eq(<<~CLEAR)
      value: []Int64@boxed = DEFAULT;
      shared_value: []Int64@shared:boxed = DEFAULT;
    CLEAR
  end

  it "enforces capability-site and semantic-node budgets" do
    legal = "Box<" * 31 + "Int64" + ">" * 31
    illegal = "Box<" * 32 + "Int64" + ">" * 32
    expect { parse("value: #{legal} = DEFAULT;") }.not_to raise_error
    expect { parse("value: #{illegal} = DEFAULT;") }
      .to raise_error(ParserError, /maximum is 32/)

    too_many_caps = "[]@local {Symbol}@versioned []@shared {Int64}@locked String"
    expect { parse("value: #{too_many_caps} = DEFAULT;") }
      .to raise_error(ParserError, /maximum is 3/)
    expect { parse("value: []@list Int64 = DEFAULT;") }
      .to raise_error(ParserError, /topology in the Inline Pivot layer sigil/)
  end

  it "does not migrate an ambiguous capability attached to a tense wrapper" do
    expression = FutureTypeExpression.new(
      inner: NamedTypeExpression.new(name: :Int64),
      capabilities: TypeCapabilities.new(ownership: :shared)
    )

    expect(Type.inline_migration_name(Type.new(expression))).to be_nil
  end
end
