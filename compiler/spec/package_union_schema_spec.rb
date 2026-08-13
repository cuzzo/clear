require "rspec"
require "tmpdir"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

# MATCH dispatch reads union_schemas to choose a switch-with-payload over a tag
# equality chain. A package REQUIRE emitted type aliases but never merged the
# imported schemas, so `Imported.Variant AS payload` in a consuming package
# lowered to `value == Imported.Variant` and left `payload` undeclared.
RSpec.describe "package union schema import" do
  it "lowers a MATCH on an imported union to a payload switch" do
    Dir.mktmpdir do |dir|
      lib = File.join(dir, "lib.clear")
      File.write(lib, <<~CLEAR)
        PUB STRUCT Circle { radius: Int64 }
        PUB STRUCT Square { side: Int64 }
        PUB UNION Shape { Circle: Circle, Square: Square }
      CLEAR

      out = ZigTranspiler.new.transpile_as_module(<<~CLEAR, source_dir: dir, pkg_paths: { "shapes" => lib })
        REQUIRE "pkg:shapes";

        PUB FN shape_size(shape: Shape) RETURNS Int64 ->
          PARTIAL MATCH shape START
            Shape.Circle AS payload -> RETURN payload.radius;,
            Shape.Square AS payload -> RETURN payload.side;
          END
          RETURN 0_i64;
        END
      CLEAR

      expect(out).to include("switch (shape)")
      expect(out).to include(".Circle => |__match_payload_")
      expect(out).not_to include("shape == Shape.Circle")
    end
  end
end
