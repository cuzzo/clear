require "rspec"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

RSpec.describe "collection constructor capability integration" do
  it "transpiles constructor :sharded and :soa modifiers through collection annotations" do
    zig = ZigTranspiler.new.transpile(<<~CLEAR)
      STRUCT Item { value: Float64, other: Float64 }

      FN main() RETURNS Void ->
        MUTABLE vals: []@sharded(2) Float64 = List[]:sharded(2);
        &vals.append(1.0);
        &vals.append(2.0);
        ASSERT vals.length() == 2_i64, "sharded list constructor";

        MUTABLE pool: [Pool(8)]@soa Item = Pool[]:soa;
        &pool.insert(Item{ value: 1.0, other: 10.0 });
        &pool.insert(Item{ value: 2.0, other: 20.0 });
        total = pool |> SUM _.value;
        ASSERT total == 3.0, "soa pool constructor";
        RETURN;
      END
    CLEAR

    expect(zig).to include("ShardedList")
    expect(zig).to include("SoaPool")
  end

  it "rejects invalid constructor shard counts through the compiler frontend" do
    expect {
      ZigTranspiler.new.transpile(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE vals: []@sharded(2) Float64 = List[]:sharded(1);
          RETURN;
        END
      CLEAR
    }.to raise_error(ParserError, /requires N >= 2/)
  end
end
