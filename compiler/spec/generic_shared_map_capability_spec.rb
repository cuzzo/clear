# typed: false
require "rspec"
require_relative "../ruby/annotator/annotator"
require_relative "../ruby/backends/transpiler"

RSpec.describe "capability-polymorphic generic Maps" do
  def annotate(source)
    program = ClearParser.new(Lexer.new(source, file: "generic_shared_map.clear").tokenize, source).parse
    SemanticAnnotator.new.annotate!(program)
    program
  end

  it "preserves capable Map type arguments as semantic type expressions" do
    program = annotate(<<~CLEAR)
      STRUCT Cache<M: SHARED Map> { values: M }
      FN main() RETURNS Void ->
        storage: {String}@shared:locked Int64 = {};
        cache = Cache<{String}@shared:locked Int64>{ values: storage };
      END
    CLEAR

    cache = program.statements.last.body.last
    map_type = cache.full_type.generic_args.first
    expect(map_type).to be_map
    expect(map_type).to be_shared
    expect(map_type).to be_locked
    expect(map_type.key_type).to be_string
    expect(map_type.value_type.resolved).to eq(:Int64)
  end

  it "rejects direct access and admits only a scoped polymorphic alias" do
    expect {
      annotate(<<~CLEAR)
        FN bad<M: SHARED Map>(map: M, key: M::Key) RETURNS ?M::Value ->
          RETURN map[key];
        END
      CLEAR
    }.to raise_error(CompilerError, /caller-selected shared Map capability.*cannot be accessed directly/)

    expect {
      annotate(<<~CLEAR)
        FN bad<M: SHARED Map>(map: M, key: M::Key) RETURNS Void ->
          WITH map AS values { values.contains?(key); }
        END
      CLEAR
    }.to raise_error(CompilerError, /caller-selected shared Map capability.*cannot be accessed directly/)

    expect {
      annotate(<<~CLEAR)
        FN valid<M: SHARED Map>(MUTABLE map: M, key: M::Key, TAKES value: M::Value) RETURNS !Void ->
          WITH POLYMORPHIC map AS values { values[key] = value; }
        END
      CLEAR
    }.not_to raise_error
  end

  it "lowers a constrained nested field to a typed comptime synchronization boundary" do
    zig = ZigTranspiler.new.transpile(<<~CLEAR)
      STRUCT Cache<M: SHARED Map> { values: M }
      IMPLEMENTATION Cache<M> {
        METHOD put(MUTABLE self, key: M::Key, TAKES value: M::Value) RETURNS !Void ->
          WITH POLYMORPHIC self.values AS values { values[key] = value; }
        END
      }
      FN main() RETURNS Void -> PASS END
    CLEAR

    expect(zig).to include("CheatLib.polymorphicMutate(&self.values")
    expect(zig).to include("values: *CheatLib.PolymorphicInner(M)")
    expect(zig).to include("CheatLib.mapProtocolPut(values")
    expect(zig).to include("heapAlloc()")
  end
end
