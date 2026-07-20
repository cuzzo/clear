require "rspec"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../ruby/annotator" unless defined?(SemanticAnnotator)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/ast/lexer" unless defined?(Lexer)

RSpec.describe "Resource RAII Transpilation" do
  def transpile(src)
    ZigTranspiler.new.transpile(src)
  end

  it "emits plain defer f.close() when File::open is never moved" do
    src = <<~CLEAR
      FN test() RETURNS !Void ->
        f = TRY File::open("test.txt");
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
      FN getFile() RETURNS !File ->
        f = TRY File::open("test.txt");
        RETURN f;
      END
    CLEAR
    zig = transpile(src)
    # f is returned through an explicit transfer mark visible to MIRChecker.
    expect(zig).to include("f_moved = true")
    expect(zig).not_to include("f.close()")
    expect(zig).to include("return f;")
  end

  it "eliminates f cleanup when always moved to g (regression)" do
    src = <<~CLEAR
      FN moveFile() RETURNS !Void ->
        f = TRY File::open("test.txt");
        g = f;
        RETURN;
      END
    CLEAR
    zig = transpile(src)
    # f is transferred to g; the guard makes that transfer explicit to MIRChecker.
    expect(zig).to include("f_moved = true")
    # g takes ownership → g gets its own defer
    expect(zig).to include("g.close()")
  end

  it "eliminates f cleanup when always GIVEn (regression)" do
    src = <<~CLEAR
      FN giveFile() RETURNS !Void ->
        f = TRY File::open("test.txt");
        GIVE f;
        RETURN;
      END
    CLEAR
    zig = transpile(src)
    # GIVE is an explicit ownership transfer visible to MIRChecker.
    expect(zig).to include("f_moved = true")
  end

  it "emits recursive cleanup for structs containing resources" do
    src = <<~CLEAR
      STRUCT Holder {
        f: File
      }
      FN test() RETURNS !Void ->
        h = Holder{ f: File::open("x") };
        RETURN;
      END
    CLEAR
    zig = transpile(src)
    expect(zig).to include("pub fn __clear_drop(self: *@This(), alloc: std.mem.Allocator) void")
    expect(zig).to include("self.f.close()")
    expect(zig).to include("defer CheatLib.cleanup(@TypeOf(h), __clear_heap_alloc, &h)")
  end
end
