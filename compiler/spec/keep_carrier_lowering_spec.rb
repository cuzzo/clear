require "rspec"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

# V5-4a: MIR lowering consumes the stamped KeepNode.carrier_op. Concrete
# retained carriers emit exactly one carrier-appropriate retain and no copy;
# the carrier-polymorphic case fails CLOSED with a clear boundary message
# until carrier specialization (Phase 4b) lands.
RSpec.describe "KEEP carrier lowering" do
  def transpile(source, mode: :default)
    ZigTranspiler.new(source_dir: Dir.pwd).transpile(source, source_dir: Dir.pwd, ownership_mode: mode)
  end

  it "emits exactly one rcRetain and no payload copy for KEEP of an @multiowned local" do
    zig = transpile(<<~CLEAR)
      STRUCT S { id: Int64 }
      FN obs(x: S) RETURNS Int64 -> RETURN x.id; END
      FN main() RETURNS Void ->
        s = S{ id: 1 } @multiowned;
        t = KEEP s;
        WITH s { ASSERT obs(s) == 1; }
        WITH t { ASSERT obs(t) == 1; }
        RETURN;
      END
    CLEAR
    expect(zig.scan(/rcRetain/).length).to eq(1)
    expect(zig).not_to match(/arcRetain/)
  end

  it "emits exactly one arcRetain for KEEP of an @shared local" do
    zig = transpile(<<~CLEAR)
      STRUCT S { id: Int64 }
      FN obs(x: S) RETURNS Int64 -> RETURN x.id; END
      FN main() RETURNS Void ->
        s = S{ id: 1 } @shared;
        t = KEEP s;
        WITH s { ASSERT obs(s) == 1; }
        WITH t { ASSERT obs(t) == 1; }
        RETURN;
      END
    CLEAR
    expect(zig.scan(/arcRetain/).length).to eq(1)
  end

  it "fails closed with a carrier-specialization boundary message for KEEP of a carrier-polymorphic param" do
    src = <<~CLEAR
      STRUCT User { name: String }
      FN sink(TAKES u: User) RETURNS Void -> RETURN; END
      FN foo(TAKES u: User) RETURNS Void -> sink(KEEP u); sink(u); RETURN; END
      FN main() RETURNS Void -> foo(User{ name: "Ada" }); RETURN; END
    CLEAR
    expect { transpile(src) }.to raise_error(/carrier specialization/)
  end
end

# V5-5c codegen assertions for the shared->unique COPY and last-use move.
RSpec.describe "COPY/move carrier codegen (v5)" do
  def transpile(source, mode: :default)
    ZigTranspiler.new(source_dir: Dir.pwd).transpile(source, source_dir: Dir.pwd, ownership_mode: mode)
  end

  it "emits an explicit payload copy (dupe) for a shared->unique COPY at a UNIQUE boundary" do
    zig = transpile(<<~CLEAR)
      STRUCT Doc { version: Int64 }
      FN persist(TAKES d: UNIQUE Doc) RETURNS Int64 -> RETURN d.version; END
      FN main() RETURNS Void ->
        MUTABLE shared = Doc{ version: 3 } @multiowned;
        snap = persist(OWN COPY shared);
        ASSERT snap == 3, "s";
        shared.version = 9;
        WITH shared { ASSERT shared.version == 9, "a"; }
        RETURN;
      END
    CLEAR
    expect(zig).to match(/dupeValue|__copy_src/)
  end

  it "emits no retain for an @multiowned handle moved at its last use" do
    # Moving a handle to a new @multiowned binding at its last use transfers the
    # handle -- no retain. (A handle can no longer fill a plain slot silently;
    # that now requires OWN COPY.)
    zig = transpile(<<~CLEAR)
      STRUCT Cell { n: Int64 }
      FN main() RETURNS Void ->
        original = Cell{ n: 42 } @multiowned;
        moved = GIVE original;
        WITH moved { ASSERT moved.n == 42, "m"; }
        RETURN;
      END
    CLEAR
    expect(zig).not_to match(/rcRetain|arcRetain/)
  end
end
