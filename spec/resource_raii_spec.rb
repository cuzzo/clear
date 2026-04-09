require "rspec"
require_relative "../src/transpiler"
require_relative "../src/annotator"
require_relative "../src/parser"
require_relative "../src/lexer"

RSpec.describe "Resource RAII Transpilation" do
  def transpile(src)
    ZigTranspiler.new.transpile(src)
  end

  it "emits plain defer f.close() when File::open is never moved" do
    src = <<~CLEAR
      FN test() RETURNS Void ->
        f = File::open("test.txt");
        RETURN;
      END
    CLEAR
    zig = transpile(src)
    expect(zig).to include("var f = try CheatLib.fileOpen")
    expect(zig).to include("defer f.close();")
    expect(zig).not_to include("f_moved")
  end

  it "DOES NOT emit defer close() when returning a resource (regression)" do
    src = <<~CLEAR
      FN getFile() RETURNS File ->
        f = File::open("test.txt");
        RETURN f;
      END
    CLEAR
    zig = transpile(src)
    # f is MOVED on all paths (returned) → no defer, no _moved guard
    expect(zig).not_to include("f_moved")
    expect(zig).not_to include("f.close()")
    expect(zig).to include("return f;")
  end

  it "eliminates f cleanup when always moved to g (regression)" do
    src = <<~CLEAR
      FN moveFile() RETURNS Void ->
        f = File::open("test.txt");
        g = f;
        RETURN;
      END
    CLEAR
    zig = transpile(src)
    # f is MOVED on all paths → no defer, no _moved guard for f
    expect(zig).not_to include("f_moved")
    # g takes ownership → g gets its own defer
    expect(zig).to include("g.close()")
  end

  it "eliminates f cleanup when always GIVEn (regression)" do
    src = <<~CLEAR
      FN giveFile() RETURNS Void ->
        f = File::open("test.txt");
        GIVE f;
        RETURN;
      END
    CLEAR
    zig = transpile(src)
    # f is MOVED on all paths (GIVEn) → no defer, no _moved guard
    expect(zig).not_to include("f_moved")
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
