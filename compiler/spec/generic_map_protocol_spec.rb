# typed: false
require "rspec"
require_relative "../ruby/annotator/annotator"
require_relative "../ruby/backends/transpiler"
require_relative "../ruby/mir/mir_pass"
require_relative "../ruby/ast/diagnostic_buckets"

RSpec.describe "the intrinsic generic Map protocol" do
  def parse(source)
    ClearParser.new(Lexer.new(source, file: "generic_map.clear").tokenize, source).parse
  end

  def annotate(source)
    program = parse(source)
    SemanticAnnotator.new.annotate!(program)
    program
  end

  it "tracks protocol diagnostics in the generics tooling bucket" do
    expect(DiagnosticBuckets.covered_codes).to include(
      :GENERIC_UNKNOWN_PROTOCOL,
      :GENERIC_PROTOCOL_BOUND_FAILED,
      :GENERIC_MAP_METHOD_ARGUMENT,
    )
  end

  it "preserves associated types through parsing, tenses, and type printing" do
    fn = parse(<<~CLEAR).statements.first
      FN lookup<M: Map>(map: M, key: M::Key) RETURNS ?M::Value ->
        RETURN map[key];
      END
    CLEAR

    expect(fn.params[1].type).to be_projection
    expect(fn.params[1].type.projection_owner).to eq(:M)
    expect(fn.params[1].type.projection_member).to eq(:Key)
    expect(fn.params[1].type.raw.to_s).to eq("M::Key")
    expect(fn.return_type.raw.to_s).to eq("?M::Value")
    expect(fn.return_type.wrapped_type).to be_projection
    expect(Type.inline_migration_name(fn.return_type)).to eq("?M::Value")
  end

  it "validates projections nested in generic arguments and inherited shared bounds" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Box<T> { value: T }
        STRUCT SharedCache<M: SHARED Map> { values: M }
        FN inspect<M: Map>(box: Box<M::Key>, keys: [2]M::Key) RETURNS Void -> PASS END
        FN forward<M: SHARED Map>(cache: SharedCache<M>) RETURNS Void -> PASS END
      CLEAR
    }.not_to raise_error

    expect {
      annotate("FN invalid<M: MissingProtocol>(value: M) RETURNS Void -> PASS END")
    }.to raise_error(CompilerError, /Unknown generic protocol MissingProtocol/)
  end

  it "type-checks generic indexing and the stable Map method surface" do
    program = annotate(<<~CLEAR)
      FN exercise<M: Map>(MUTABLE map: M, key: M::Key, TAKES first: M::Value, TAKES second: M::Value) RETURNS !Int64 ->
        before = map[key];
        map[key] = first;
        &map.put(key, second);
        ASSERT map.contains?(key);
        &map.delete(key);
        ASSERT map.empty?() OR map.any?();
        RETURN map.length();
      END
    CLEAR

    fn = program.statements.first
    operations = []
    AST.each_locatable(fn, descend_functions: true) do |node|
      operations << node.protocol_operation if node.respond_to?(:protocol_operation) && node.protocol_operation
    end
    expect(operations).to include(:map_get, :map_put, :put, :contains, :delete, :empty, :any, :count)
    expect(fn.can_fail).to be(true)
  end

  it "requires owned generic values and preserves explicit COPY through MIR" do
    expect {
      annotate(<<~CLEAR)
        FN invalid<M: Map>(MUTABLE map: M, key: M::Key, value: M::Value) RETURNS !Void ->
          &map.put(key, value);
        END
      CLEAR
    }.to raise_error(CompilerError, /Cannot pass borrowed access to TAKES parameter/)

    # Checked indexing normally fails the associated-type check first because
    # it yields ?M::Value. Exercise the ownership helper directly so a future
    # definite-index form cannot silently turn that borrow into an owned put.
    session = Annotator::Phases::TypeAnalysisSession.new
    token = Lexer::Token.new(:LBRACKET, "[", 1, 1)
    indexed = AST::GetIndex.new(
      token,
      AST::Identifier.new(Lexer::Token.new(:IDENTIFIER, "values", 1, 1), "values"),
      AST::Literal.new(Lexer::Token.new(:INT64, "0", 1, 8), :INT64, 0, :stack),
    )
    expect {
      session.send(:consume_generic_map_value!, indexed, Type.new(:String))
    }.to raise_error(CompilerError, /Cannot pass container index access to TAKES parameter/)

    zig = ZigTranspiler.new.transpile(<<~CLEAR)
      FN copied<M: Map>(MUTABLE map: M, key: M::Key, value: M::Value) RETURNS !Void ->
        map[key] = COPY value;
      END
    CLEAR
    expect(zig).to include("CheatLib.dupeValue(CheatLib.MapFacts(M).Value")
    expect(zig).to include("CheatLib.mapProtocolPut(map")
    expect(zig).to match(/__(?:tmp|hoist)_1_moved = true/)
  end

  it "specializes concrete calls and emits static adapters with caller allocator provenance" do
    zig = ZigTranspiler.new.transpile(<<~CLEAR)
      FN write<M: Map>(MUTABLE map: M, key: M::Key, TAKES value: M::Value) RETURNS !Void ->
        map[key] = value;
      END

      FN forward<M: Map>(MUTABLE map: M, key: M::Key, TAKES value: M::Value) RETURNS !Void ->
        write(&map, key, value);
      END

      FN main() RETURNS !Void ->
        MUTABLE words: {String}Int64 = {};
        write(&words, "answer", 42_i64);
      END
    CLEAR

    expect(zig).to include("fn write(comptime M: type")
    expect(zig).to include("map: *M, __clear_map_alloc_map: std.mem.Allocator")
    expect(zig).to include("CheatLib.mapProtocolPut(map, __clear_map_alloc_map, __clear_map_alloc_map")
    expect(zig).to match(/write\(CheatLib\.StringMap\(i64\), rt, &words, rt\.heapAlloc\(\)/)
    expect(zig).to match(/write\(M, rt, map, __clear_map_alloc_map/)
    expect(zig).not_to include("WitnessTable")
    expect(zig).not_to include("vtable")
  end

  it "rejects concrete arguments that do not satisfy Map and SHARED Map" do
    expect {
      annotate(<<~CLEAR)
        STRUCT User { id: Int64 }
        STRUCT Cache<M: Map> { values: M }
        FN bad(cache: Cache<User>) RETURNS Void -> PASS END
      CLEAR
    }.to raise_error(CompilerError, /M requires Map, but User does not conform/)

    expect {
      annotate(<<~CLEAR)
        STRUCT Cache<M: SHARED Map> { values: M }
        FN bad(cache: Cache<{String}Int64>) RETURNS Void -> PASS END
      CLEAR
    }.to raise_error(CompilerError, /requires SHARED Map.*is not shared/)
  end

  it "reports invalid associated-type owners, bounds, and members at the declaration" do
    expect {
      annotate("FN bad<M>(value: M::Value) RETURNS Void -> PASS END")
    }.to raise_error(CompilerError, /Cannot resolve M::Value: M is not constrained by Map/)

    expect {
      annotate("FN bad<M: Map>(value: X::Key) RETURNS Void -> PASS END")
    }.to raise_error(CompilerError, /Cannot resolve X::Key: X is not a generic parameter/)

    expect {
      annotate("FN bad<M: Map>(value: M::Missing) RETURNS Void -> PASS END")
    }.to raise_error(CompilerError, /Map has no associated type M::Missing.*Key, Value/m)
  end

  it "reports invalid generic Map operations without deferring to Zig" do
    expect {
      annotate(<<~CLEAR)
        FN bad<M: Map>(map: M) RETURNS Void ->
          map["not-a-generic-key"];
        END
      CLEAR
    }.to raise_error(CompilerError, /Map protocol indexing expects M::Key, but this key is Byte\[17\]/)

    expect {
      annotate("FN bad<M: Map>(map: M) RETURNS Void -> map.keys(); END")
    }.to raise_error(CompilerError, /Map has no stable protocol method 'keys'/)

    expect {
      annotate("FN bad<M: Map>(map: M) RETURNS Void -> map.put(); END")
    }.to raise_error(CompilerError, /Map.put expects 2 argument\(s\), but got 0/)

    expect {
      annotate(<<~CLEAR)
        FN bad<M: Map>(MUTABLE map: M, key: M::Key) RETURNS Void ->
          &map.put(key, "not-a-generic-value");
        END
      CLEAR
    }.to raise_error(CompilerError, /Map.put argument 2 expects M::Value, but got Byte\[19\]/)
  end

  it "keeps concrete map assignment and protocol runtime classification distinct" do
    program = annotate(<<~CLEAR)
      FN concrete() RETURNS !Void ->
        MUTABLE map: {String}Int64 = {};
        map["x"] = 1_i64;
      END
      FN generic<M: Map>(MUTABLE map: M, key: M::Key, TAKES value: M::Value) RETURNS !Void ->
        map[key] = value;
      END
    CLEAR

    assignments = []
    AST.each_locatable(program, descend_functions: true) do |node|
      assignments << node if node.is_a?(AST::Assignment) && node.name.is_a?(AST::GetIndex)
    end
    concrete, generic = assignments
    expect(concrete.name.protocol_operation).to be_nil
    expect(generic.name.protocol_operation).to eq(:map_put)

    pass = MIRPass.new(fn_nodes: {}, schema_lookup: ->(_name) { nil })
    expect(pass.send(:indexed_assignment_lowers_through_runtime?, generic)).to be(true)
  end

  it "fails closed for impossible protocol MIR identifiers" do
    emitter = MIREmitter.new
    bad_protocol = MIR::ProtocolCall.new(:Missing, :get, MIR::Ident.new("map"), [MIR::Ident.new("key")])
    bad_operation = MIR::ProtocolCall.new(:Map, :missing, MIR::Ident.new("map"), [])

    expect { emitter.emit(bad_protocol) }.to raise_error(RuntimeError, /unsupported protocol call Missing.get/)
    expect { emitter.emit(bad_operation) }.to raise_error(RuntimeError, /unsupported Map protocol operation missing/)
  end
end
