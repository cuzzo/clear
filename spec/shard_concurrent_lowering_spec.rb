require_relative "../src/backends/transpiler"

RSpec.describe "SHARD + CONCURRENT EACH lowering" do
  it "lowers SHARD + CONCURRENT EACH as verifier-visible structural MIR" do
    src = <<~CLEAR
      FN main() RETURNS Void ->
          MUTABLE counts: HashMap<Int64, Int64>@sharded(4) = {};
          (0..<16_i64) |> SHARD(_ MOD 4_i64, counts) |> CONCURRENT EACH {
              counts[_] = (counts[_] OR 0_i64) + 1_i64;
          };
      END
    CLEAR

    zig = ZigTranspiler.new.transpile(src)

    expect(zig).to include("for (0..16) |____sh1_i_usize|")
    expect(zig).to include("const __sh1_i: i64 = @intCast(____sh1_i_usize);")
    expect(zig).to include("try counts.put(")
    expect(zig).not_to include("CheatLib.BoundedChannel(__ShWork")
    expect(zig).not_to include("__ShWorker")
  end
end
