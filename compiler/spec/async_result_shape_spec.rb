require "rspec"

require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

RSpec.describe "AsyncResultShape" do
  it "lowers BG returning a list as Promise<List<T>>, not list-of-promises" do
    src = <<~CLEAR
      FN main() RETURNS Void ->
        xs: ~Int64[]@list = BG {
          MUTABLE out: []Int64 = [];
          &out.append(1_i64);
          out;
        };
        ys: []Int64 = NEXT xs;
        ASSERT ys[0_i64] == 1_i64, "promise of list";
        RETURN;
      END
    CLEAR

    out = ZigTranspiler.new.transpile(src)
    expect(out).to include("CheatLib.Promise(std.ArrayListUnmanaged(i64)).spawn")
    expect(out).to include("var ys = try xs.next()")
    expect(out).not_to include("for (xs.items)")
  end

  it "publishes a literal String as an owned promise result" do
    src = <<~CLEAR
      FN main() RETURNS Void ->
        promise:~ = BG { "hello"; };
        result = NEXT promise;
        ASSERT result == "hello";
      END
    CLEAR

    out = ZigTranspiler.new.transpile(src)
    expect(out).to include("CheatLib.Promise([]const u8)")
    expect(out).to include("const result: []const u8 = try promise.next()")
    expect(out).to include("CheatLib.free")
  end
end
