require "rspec"
require "tmpdir"

require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

RSpec.describe "C ABI integration" do
  def parse(source)
    ClearParser.new(Lexer.new(source).tokenize, source).parse
  end

  def transpile(source)
    ZigTranspiler.new.transpile(source)
  end

  it "keeps the ABI, native symbol, calling convention, and header as structured metadata" do
    fn = parse(<<~CLEAR).statements.fetch(0)
      EXTERN FN clear_name(value: TargetInt) RETURNS TargetUInt AS "native_name"
        FROM "fixture" ABI C CALLCONV SYSTEM HEADER "fixture.h";
    CLEAR

    expect(fn).to be_a(AST::ExternFnDecl)
    expect(fn.extern_source.dependency).to eq("fixture")
    expect(fn.extern_source.abi).to eq(:c)
    expect(fn.extern_source.symbol).to eq("native_name")
    expect(fn.extern_source.callconv).to eq(:system)
    expect(fn.extern_source.header).to eq("fixture.h")
  end

  it "lowers target integer aliases, size values, C strings, structs, and mutable out parameters" do
    zig = transpile(<<~CLEAR)
      EXTERN STRUCT Pair { left: TargetLong, right: Float64 } FROM "fixture" ABI C;
      EXTERN STRUCT Handle {} CLOSE "release_handle" FROM "fixture" ABI C;
      EXTERN FN acquire(name: String@c, MUTABLE out: ?Handle, size: TargetUInt@size)
        RETURNS TargetInt FROM "fixture" ABI C;
      EXTERN FN release_handle(handle: Handle) RETURNS TargetInt FROM "fixture" ABI C;

      FN main() RETURNS Void ->
        MUTABLE out: ?Handle = NIL;
        ASSERT acquire("item", &out, 4) == 0;
        handle = out?;
      END
    CLEAR

    expect(zig).to include('const Pair = extern struct { left: c_long, right: f64 };')
    expect(zig).to include('const Handle__opaque = opaque {};')
    expect(zig).to include('const Handle = *Handle__opaque;')
    expect(zig).to include('extern "fixture" fn acquire(name: [*:0]const u8, out: *?Handle, size: usize) callconv(.c) c_int;')
    expect(zig).to include('defer _ = release_handle(handle);')
    expect(zig).not_to include('@import("fixture")')
  end

  it "preserves borrowed C string representation through nested calls" do
    zig = transpile(<<~CLEAR)
      EXTERN STRUCT Handle {} FROM "fixture" ABI C;
      EXTERN FN borrowed_name(handle: Handle) RETURNS String@c FROM "fixture" ABI C;
      EXTERN FN compare(left: String@c, right: String@c) RETURNS TargetInt FROM "fixture" ABI C;

      FN check(handle: Handle) RETURNS Bool ->
        RETURN compare(borrowed_name(handle), "expected") == 0;
      END
    CLEAR

    expect(zig).to include("ret: [*:0]const u8")
    expect(zig).not_to include("dupe(u8")
    expect(zig).not_to include("@as([]const u8")
  end

  it "retains Zig EXTERN behavior when ABI is omitted" do
    zig = transpile(<<~CLEAR)
      EXTERN FN native(value: Int64) RETURNS Int64 FROM "native_module";
      FN main() RETURNS Void -> _ = native(1); END
    CLEAR

    expect(zig).to include('@import("native_module.zig")')
    expect(zig).to include("native_module.native(")
  end


  it "represents C callbacks without CLEAR's hidden runtime parameter" do
    type = parse("callback: FN(TargetInt) -> TargetInt CALLCONV C = native;").statements.fetch(0).type

    expect(Type.surface_name(type)).to eq("FN(TargetInt) -> TargetInt CALLCONV C")
    expect(type.zig_type).to eq("*const fn(c_int) callconv(.c) c_int")

    zig = transpile(<<~CLEAR)
      EXTERN FN apply(value: TargetInt, callback: FN(TargetInt) -> TargetInt CALLCONV C)
        RETURNS TargetInt FROM "fixture" ABI C;
      EXTERN FN invoke(callback: FN() -> Void CALLCONV C) RETURNS Void FROM "fixture" ABI C;
      FN increment(value: TargetInt) RETURNS TargetInt -> RETURN value + 1; END
      FN notify() RETURNS Void -> RETURN; END
      FN main() RETURNS Void ->
        ASSERT apply(4, increment) == 5;
        invoke(notify);
      END
    CLEAR

    expect(zig).to include("threadlocal var __clear_c_callback_rt: ?*Runtime = null;")
    expect(zig).to include("callconv(.c) c_int")
    expect(zig).to include("callconv(.c) void")
    expect(zig).to include("CLEAR error crossed a C callback")
    expect(zig).to include("__previous_c_callback_rt")
  end

  it "bounds foreign pointers only through a scoped unsafe view" do
    source = <<~CLEAR
      EXTERN STRUCT Handle {} FROM "fixture" ABI C;
      EXTERN FN values(handle: Handle) RETURNS ?[]@c Int64 FROM "fixture" ABI C;
      FN first(handle: Handle) RETURNS Int64 ->
        pointer = values(handle)?;
        WITH UNSAFE VIEW pointer LENGTH 3 AS view {
          RETURN view[0];
        }
      END
    CLEAR
    expect(transpile(source)).to include("[0..@intCast(3)]")

    expect { transpile(source.sub("LENGTH 3", 'LENGTH "three"')) }
      .to raise_error(/indices must be integers/)

    legacy = source.sub(
      "WITH UNSAFE VIEW pointer LENGTH 3 AS view {\n    RETURN view[0];\n  }",
      "RETURN pointer.view(3)[0];"
    )
    expect { transpile(legacy) }.to raise_error(/do not have a `.view\(\)` method/)

    direct = source.sub(
      "WITH UNSAFE VIEW pointer LENGTH 3 AS view {\n    RETURN view[0];\n  }",
      "RETURN pointer[0];"
    )
    expect { transpile(direct) }.to raise_error(/Cannot index pointer directly.*WITH UNSAFE VIEW/m)

    safe_view = source.sub("WITH UNSAFE VIEW", "WITH VIEW").sub(" LENGTH 3", "")
    expect { transpile(safe_view) }
      .to raise_error(/Use `WITH UNSAFE VIEW pointer LENGTH count AS values/)
  end

  it "does not allow the bounded foreign view itself to escape its WITH scope" do
    source = <<~CLEAR
      FN leak(pointer: []@c Int64, count: TargetUInt@size) RETURNS Int64[] ->
        WITH UNSAFE VIEW pointer LENGTH count AS bounded {
          RETURN bounded;
        }
      END
    CLEAR

    expect { transpile(source) }.to raise_error(/Cannot RETURN 'bounded' from inside a WITH block/)
  end

  it "renders target capabilities, mutable fixed arrays, and supported C calling conventions" do
    declaration = parse(<<~CLEAR).statements.fetch(0)
      EXTERN FN surfaces(text: String@c, count: TargetUInt@size) RETURNS Void FROM "fixture" ABI C;
    CLEAR
    expect(Type.coercion_surface_name(declaration.params.fetch(0).type)).to eq("String@c")
    expect(Type.coercion_surface_name(declaration.params.fetch(1).type)).to eq("TargetUInt@size")

    zig = transpile(<<~CLEAR)
      EXTERN FN mutate(MUTABLE values: [4]Int64) RETURNS Void FROM "fixture" ABI C CALLCONV SYSTEM;
      EXTERN FN windows(value: TargetInt) RETURNS TargetInt FROM "fixture" ABI C CALLCONV WINAPI;
      FN main() RETURNS Void -> RETURN; END
    CLEAR
    expect(zig).to include("values: *[4]i64")
    expect(zig).to include("callconv(.c) void")
    expect(zig).to include("callconv(.winapi) c_int")
  end

  it "uses Zig to expand a header directive into ordinary typed EXTERN declarations" do
    fixture = File.expand_path("../../transpile-tests/c-ffi-test", __dir__)
    source = CHeaderImporter.expand(<<~CLEAR, source_dir: fixture)
      EXTERN FROM HEADER "fixture.h" LINK "clear_c_fixture" ABI C;
    CLEAR

    expect(source).to include("EXTERN STRUCT ClearFixtureRecord { id: Int64")
    expect(source).to include("EXTERN STRUCT ClearFixtureHandle {}")
    expect(source).to include("clear_fixture_echo_size(value: TargetUInt@size)")
    expect(source).to include("callback: FN(TargetInt) -> TargetInt CALLCONV C")
    expect(source).not_to include("MaxAlignT")
  end

  it "rejects CLEAR-only representations before Zig sees an invalid C declaration" do
    invalid = {
      "implicit Any" => 'EXTERN FN bad() FROM "bad" ABI C;',
      "untyped parameter" => 'EXTERN FN bad(value) RETURNS Void FROM "bad" ABI C;',
      "error union" => 'EXTERN FN bad() RETURNS !Int64 FROM "bad" ABI C;',
      "future" => 'EXTERN FN bad() RETURNS ~Int64 FROM "bad" ABI C;',
      "CLEAR string" => 'EXTERN FN bad(value: String) RETURNS Void FROM "bad" ABI C;',
      "managed list" => 'EXTERN FN bad(value: [List]Int64) RETURNS Void FROM "bad" ABI C;',
      "array return" => 'EXTERN FN bad() RETURNS [4]Int64 FROM "bad" ABI C;',
      "CLEAR callback" => 'EXTERN FN bad(callback: FN(Int64) -> Int64) RETURNS Void FROM "bad" ABI C;',
      "optional scalar" => 'EXTERN FN bad(value: ?Int64) RETURNS Void FROM "bad" ABI C;',
      "boxed scalar" => 'EXTERN FN bad(value: Int64@boxed) RETURNS Void FROM "bad" ABI C;',
    }

    invalid.each_value do |declaration|
      expect { transpile("#{declaration} FN main() RETURNS Void -> RETURN; END") }
        .to raise_error(/Unsupported ABI C/)
    end
  end

  it "reports header import failures at the CLEAR boundary" do
    Dir.mktmpdir("clear-header-errors") do |dir|
      expect { CHeaderImporter.import("missing.h", "missing", source_dir: dir) }
        .to raise_error(CHeaderImporter::Error, /C header not found/)

      File.write(File.join(dir, "empty.h"), "#define ONLY_A_MACRO 1\n")
      expect { CHeaderImporter.import("empty.h", "empty", source_dir: dir) }
        .to raise_error(CHeaderImporter::Error, /contains no ABI declarations/)

      File.write(File.join(dir, "broken.h"), "this is not C;\n")
      expect { CHeaderImporter.import("broken.h", "broken", source_dir: dir) }
        .to raise_error(CHeaderImporter::Error, /could not import C header/)

      File.write(File.join(dir, "nullable.h"), <<~HEADER)
        typedef struct nullable_handle nullable_handle;
        nullable_handle *nullable_open(void);
      HEADER
      imported = CHeaderImporter.import("nullable.h", "nullable", source_dir: dir)
      expect(imported).to include("RETURNS ?NullableHandle")
    end

    allow(CHeaderImporter).to receive(:zig_executable).and_return("/definitely/missing/zig")
    fixture = File.expand_path("../../transpile-tests/c-ffi-test", __dir__)
    expect { CHeaderImporter.import("fixture.h", "fixture", source_dir: fixture) }
      .to raise_error(CHeaderImporter::Error, /Zig is required/)
  end
end
