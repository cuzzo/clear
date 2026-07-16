# typed: false
require "rspec"
require "stringio"
require_relative "../ruby/backends/transpiler"

RSpec.describe "generic associated-key map storage" do
  def transpile(source)
    ZigTranspiler.new.transpile(source)
  end

  let(:index_source) do
    <<~CLEAR
      STRUCT Index<M: Map> { entries={}: {M::Key}M::Value }
      IMPLEMENTATION Index<M> {
        METHOD put!(MUTABLE self, key: M::Key, value: M::Value) RETURNS !Void ->
          self.entries[key] = COPY value;
        END
        METHOD get(self, key: M::Key) RETURNS !?M::Value ->
          RETURN COPY self.entries[key];
        END
      }
      FN main() RETURNS !Void ->
        words = Index<{String}String>{};
        ASSERT words.get("missing") OR_ELSE RAISE == NIL;
      END
    CLEAR
  end

  it "selects map representation at specialization and preserves owning flow returns" do
    zig = transpile(index_source)

    expect(zig).to include("entries: CheatLib.MapType(CheatLib.MapFacts(M).Key")
    expect(zig).to include("try __inherent_Index_get")
    expect(zig).to include("CheatLib.mapProtocolGet(&self.entries")
    expect(zig).to include("const __tmp_1 = CheatLib.StringMap([]const u8){ .alloc = rt.heapAlloc() };")
    expect(zig).to include("Index(CheatLib.StringMap([]const u8)){ .entries = __tmp_1 }")
    expect(zig).not_to include("entries: CheatLib.MapType(CheatLib.MapFacts(M).Key, CheatLib.MapFacts(M).Value) =")
  end

  it "substitutes non-map protocol projections in concrete generic literals" do
    zig = transpile(<<~CLEAR)
      PROTOCOL Identity<Value> {
        METHOD identity(self: Self, value: Value) RETURNS Value;
      }
      STRUCT Store<V> { marker: Int64 }
      STRUCT ProjectionBox<S: Identity> { latest: ?S::Value }
      IMPLEMENTATION Identity<V> FOR Store {
        METHOD identity(self, value: V) RETURNS V -> RETURN value; END
      }
      FN main() RETURNS Void ->
        projected = ProjectionBox<Store<Int64>>{ latest: NIL };
        ASSERT projected.latest == NIL;
      END
    CLEAR

    expect(zig).to include("ProjectionBox(Store(i64)){ .latest = @as(?i64, null) }")
  end

  it "does not misreport mutable generic calls as unused synchronization" do
    stderr = StringIO.new
    original = $stderr
    $stderr = stderr
    transpile(<<~CLEAR)
      STRUCT Index<M: Map> { entries: {M::Key}M::Value }
      IMPLEMENTATION Index<M> {
        METHOD put!(MUTABLE self, key: M::Key, value: M::Value) RETURNS !Void ->
          self.entries[key] = COPY value;
        END
      }
      FN main() RETURNS !Void ->
        MUTABLE words = Index<{String}String>{ entries: {} } @shared:locked;
        WITH EXCLUSIVE words AS view { view.put!("key", "value"); }
      END
    CLEAR
    expect(stderr.string).not_to include("never mutated via WITH EXCLUSIVE")
  ensure
    $stderr = original
  end

  it "rejects a key that does not match an associated-key storage map" do
    expect {
      transpile(<<~CLEAR)
        STRUCT Index<M: Map> { entries: {M::Key}Int64 }
        IMPLEMENTATION Index<M> {
          METHOD bad(self) RETURNS ?Int64 -> RETURN self.entries[TRUE]; END
        }
      CLEAR
    }.to raise_error(CompilerError, /expects M::Key|must be M::Key/)
  end

  it "rejects moving an owned optional capture instead of emitting a double free" do
    expect {
      transpile(<<~CLEAR)
        STRUCT Box { value: String }
        FN make() RETURNS ?Box -> RETURN Box{ value: COPY "owned" }; END
        FN main() RETURNS Void ->
          IF make() EXISTS AS box THEN
            taken = MOVE box;
          END
        END
      CLEAR
    }.to raise_error(CompilerError, /Cannot MOVE owned optional capture 'box'/)
  end

  it "keeps value-shaped optional captures value-shaped at method boundaries" do
    zig = transpile(<<~CLEAR)
      STRUCT Holder { key: ?String }
      IMPLEMENTATION Holder {
        METHOD identity(self, key: String) RETURNS String -> RETURN COPY key; END
        METHOD copied(self) RETURNS !?String ->
          current = COPY self.key;
          IF current EXISTS AS key THEN RETURN self.identity(key); END
          RETURN NIL;
        END
      }
      FN main() RETURNS Void ->
        holder = Holder{ key: COPY "key" };
        ASSERT holder.copied() OR_ELSE RAISE OR_ELSE "" == "key";
      END
    CLEAR

    expect(zig).to include("__inherent_Holder_identity(rt, self, key)")
    expect(zig).not_to include("__inherent_Holder_identity(rt, self, key.*)")
  end
end
