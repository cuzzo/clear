require "rspec"
require "byebug"

require_relative "../src/transpiler"
require_relative "../src/ast"

RSpec.describe ZigTranspiler do
  def transpile(src)
    ZigTranspiler.new.transpile(src)
  end

  # ===========================================================================
  # @list allocator selection
  # ===========================================================================
  describe "@list uses frame allocator" do
    it "uses frameAlloc for append" do
      src = <<~CLEAR
        FN cheatMain() RETURNS Void ->
          MUTABLE vals: Number[]@list = [];
          append(vals, 1.0);
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("rt.frameAlloc()")
      expect(zig).not_to include("rt.heapAlloc()")
    end

    it "uses frameAlloc for deinit" do
      src = <<~CLEAR
        FN cheatMain() RETURNS Void ->
          MUTABLE vals: Number[]@list = [];
          append(vals, 1.0);
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("vals.deinit(rt.frameAlloc())")
    end

    it "sharded list still uses heapAlloc" do
      src = <<~CLEAR
        FN cheatMain() RETURNS Void ->
          MUTABLE vals: Number[]@list:sharded(4) = [];
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("rt.heapAlloc()")
    end
  end
end
