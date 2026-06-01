require "rspec"

require_relative "../src/ast/ast"
require_relative "../src/ast/type"
require_relative "../src/annotator/helpers/function_signature"

RSpec.describe "Type#zig_type gap coverage" do
  it "renders generic and stream-style surface names without string re-parsing" do
    expect(Type.surface_name(Type.generic_instance_of(:Box, [Type.new(:Int64)]))).to eq("Box<Int64>")
    expect(Type.array_capacity_suffix(:STREAM_OPEN)).to eq("[?]")
    expect(Type.array_capacity_suffix(:INF)).to eq("[INF]")
  end

  it "keeps fallible function return types fallible" do
    sig = FunctionSignature.new(params: [], return_type: Type.new("!Int64"))

    expect(Type.new(sig).zig_type).to eq("*const fn(*Runtime) !i64")
  end

  it "wraps shared fixed SOA arrays around the SoaList shape" do
    type = Type.new(:"Int64[4]", ownership: :shared)
    type.soa = true

    expect(type.zig_type).to eq("CheatLib.Arc(CheatLib.SoaList(i64))")
  end

  it "uses a pointer for sync-wrapped affine structs" do
    expect(Type.new("Counter", sync: :locked).zig_type).to eq("*CheatLib.Locked(Counter)")
  end

  it "maps striped numeric hash maps through the numeric striped wrapper" do
    type = Type.new(:"HashMap<Int64, Float64>", sync: :locked, shard_count: 4)

    expect(type.zig_type).to eq("CheatLib.StripedNumericMap(i64, f64, 4)")
  end
end
