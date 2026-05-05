require_relative "../src/backends/transpiler"

RSpec.describe "SHARD + CONCURRENT EACH lowering" do
  it "emits per-shard bounded channels and workers instead of the serial SHARD loop" do
    src = <<~CLEAR
      FN main() RETURNS Void ->
          MUTABLE counts: HashMap<Int64, Int64>@sharded(4) = {};
          (0..<16_i64) s> SHARD(_ MOD 4_i64, counts) s> CONCURRENT EACH {
              counts[_] = (counts[_] OR 0_i64) + 1_i64;
          };
      END
    CLEAR

    zig = ZigTranspiler.new.transpile(src)

    expect(zig).to include("CheatLib.BoundedChannel(__ShWork")
    expect(zig).to include("__ShWorker")
    expect(zig).to include("CheatHeader.spawnBest")
    expect(zig).to include("putDirect")
    expect(zig).not_to include("while ((__sh1_i < __sh1_end)) : (__sh1_i = (__sh1_i + 1))")
  end
end
