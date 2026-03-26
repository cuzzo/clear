require "rspec"
require_relative "../src/transpiler"
require_relative "../src/annotator"
require_relative "../src/parser"
require_relative "../src/lexer"

RSpec.describe "Resource RAII Transpilation" do
  def transpile(src)
    ZigTranspiler.new.transpile(src)
  end

  it "emits conditional defer f.close() for File::open" do
    src = <<~CLEAR
      FN test() RETURNS Void ->
        f = File::open("test.txt");
        RETURN;
      END
    CLEAR
    zig = transpile(src)
    expect(zig).to include("const f = try CheatLib.fileOpen")
    expect(zig).to include("var f_moved = false; _ = &f_moved;")
    expect(zig).to include("defer if (!f_moved) f.close();")
  end

  it "DOES NOT emit defer close() when returning a resource (regression)" do
    src = <<~CLEAR
      FN getFile() RETURNS File ->
        f = File::open("test.txt");
        RETURN f;
      END
    CLEAR
    zig = transpile(src)
    expect(zig).to include("f_moved = true;")
    expect(zig).to include("return f;")
  end

  it "uses _moved flag to suppress defer close() on moved resources (regression)" do
    src = <<~CLEAR
      FN moveFile() RETURNS Void ->
        f = File::open("test.txt");
        g = f;
        RETURN;
      END
    CLEAR
    zig = transpile(src)
    # This should FAIL currently because it doesn't use the _moved flag for resources
    expect(zig).to include("defer if (!f_moved) f.close();")
  end

  it "uses _moved flag to suppress defer close() when GIVEn (regression)" do
    src = <<~CLEAR
      FN giveFile() RETURNS Void ->
        f = File::open("test.txt");
        GIVE f;
        RETURN;
      END
    CLEAR
    zig = transpile(src)
    expect(zig).to include("f_moved = true;")
    expect(zig).to include("defer if (!f_moved) f.close();")
  end

  it "emits recursive cleanup for structs containing resources" do
    src = <<~CLEAR
      STRUCT Holder {
        f: File
      }
      FN test() RETURNS Void ->
        h = Holder{ f: File::open("x") };
        RETURN;
      END
    CLEAR
    zig = transpile(src)
    # This might fail if the struct doesn't know it needs to close its fields
    expect(zig).to include("h.f.close()")
  end
end
