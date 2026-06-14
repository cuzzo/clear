require "rspec"
require_relative "../src/backends/transpiler" unless defined?(ZigTranspiler)

RSpec.describe "primitive non-shared atomics in functions" do
  def transpile(src)
    ZigTranspiler.new.transpile(src)
  end

  it "passes a primitive @atomic cell to a plain Int64 parameter as one loaded value" do
    out = transpile(<<~CLEAR)
      FN id(x: Int64) RETURNS Int64 ->
        RETURN x + x;
      END
      FN main() RETURNS Void ->
        MUTABLE c: Int64 = 0 @atomic;
        y = id(c);
        RETURN;
      END
    CLEAR

    expect(out).to include("fn id(x: i64) i64")
    expect(out).to include("return CheatLib.intAdd(x, x);")
    expect(out).to include("const y: i64 = id(c.*.load())")
  end

  it "passes a primitive @atomic cell through an explicit Int64 @atomic parameter" do
    out = transpile(<<~CLEAR)
      FN read(c: Int64 @atomic) RETURNS Int64 ->
        RETURN c;
      END
      FN main() RETURNS Void ->
        MUTABLE c: Int64 = 0 @atomic;
        y = read(c);
        RETURN;
      END
    CLEAR

    expect(out).to include("fn read(c: anytype) i64")
    expect(out).to include("return c.*.load();")
    expect(out).to include("const y: i64 = read(c)")
  end

  it "rejects a bare primitive passed to an explicit Int64 @atomic parameter" do
    expect {
      transpile(<<~CLEAR)
        FN read(c: Int64 @atomic) RETURNS Int64 ->
          RETURN c;
        END
        FN main() RETURNS Void ->
          c: Int64 = 0;
          y = read(c);
          RETURN;
        END
      CLEAR
    }.to raise_error(CompilerError, /expects an @atomic Int64 cell/)
  end

  it "warns when a call reads multiple atomic cells as independent bare values" do
    warnings = []
    allow($stderr).to receive(:puts) { |msg| warnings << msg }

    out = transpile(<<~CLEAR)
      FN add(x: Int64, y: Int64) RETURNS Int64 ->
        RETURN x + y;
      END
      FN main() RETURNS Void ->
        MUTABLE a: Int64 = 1 @atomic;
        MUTABLE b: Int64 = 2 @atomic;
        z = add(a, b);
        RETURN;
      END
    CLEAR

    expect(out).to include("const z: i64 = add(a.*.load(), b.*.load())")
    expect(warnings.join("\n")).to include("reads multiple atomic values independently")
    expect(warnings.join("\n")).to include("STRICT/STRICT EXTREME")
  end

  it "does not warn for a single atomic cell loaded into a bare parameter" do
    warnings = []
    allow($stderr).to receive(:puts) { |msg| warnings << msg }

    out = transpile(<<~CLEAR)
      FN inc(x: Int64) RETURNS Int64 ->
        RETURN x + 1;
      END
      FN main() RETURNS Void ->
        MUTABLE a: Int64 = 1 @atomic;
        z = inc(a);
        RETURN;
      END
    CLEAR

    expect(out).to include("const z: i64 = inc(a.*.load())")
    expect(warnings.join("\n")).not_to include("reads multiple atomic values independently")
  end

  it "does not warn when explicit Int64 @atomic parameters receive cells" do
    warnings = []
    allow($stderr).to receive(:puts) { |msg| warnings << msg }

    out = transpile(<<~CLEAR)
      FN sum_loaded(a: Int64 @atomic, b: Int64 @atomic) RETURNS Int64 ->
        RETURN a + b;
      END
      FN main() RETURNS Void ->
        MUTABLE a: Int64 = 1 @atomic;
        MUTABLE b: Int64 = 2 @atomic;
        z = sum_loaded(a, b);
        RETURN;
      END
    CLEAR

    expect(out).to include("const z: i64 = sum_loaded(a, b)")
    expect(out).to include("return CheatLib.intAdd(a.*.load(), b.*.load());")
    expect(warnings.join("\n")).not_to include("reads multiple atomic values independently")
  end

  it "returns a primitive @atomic cell as a loaded fallible Int64 value" do
    out = transpile(<<~CLEAR)
      FN get() RETURNS !Int64 ->
        MUTABLE c: Int64 = 0 @atomic;
        RETURN c;
      END
      FN main() RETURNS !Void ->
        y = get() OR EXIT;
        RETURN;
      END
    CLEAR

    expect(out).to include("fn get(rt: *Runtime) !i64")
    expect(out).to include("return c.*.load();")
  end
end
