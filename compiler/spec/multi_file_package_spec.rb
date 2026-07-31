# typed: false
require "rspec"
require "open3"
require "tmpdir"

# Multi-file packages (Go model): files registered together with
# `--pkg name=a.clear,b.clear` compile as ONE unit. References between the
# files need no REQUIRE (sibling requires are dropped); the acyclic-import
# rule applies BETWEEN packages only. `clear test pkg:<name>` compiles the
# package itself as the root unit and runs its members' TEST blocks.
RSpec.describe "multi-file packages", :integration do
  ROOT = File.expand_path("../..", __dir__)

  def write(dir, name, content)
    path = File.join(dir, name)
    File.write(path, content)
    path
  end

  def clear(*args, chdir: ROOT)
    out, _status = Open3.capture2e(File.join(ROOT, "clear"), *args, chdir: chdir)
    out
  end

  def fixture(dir)
    shapes = write(dir, "shapes.clear", <<~CLEAR)
      REQUIRE "pkg:geom_points" AS points

      PUB STRUCT Shape { name: String, origin: Point }

      PUB FN shapeLabel(s: Shape) RETURNS String ->
          RETURN COPY s.name;
      END

      TEST GeomShapes DO
        WHEN "labels" DO
          TEST THAT "shape label reads back" DO
            s = Shape{ name: "disc", origin: Point{ x: 0, y: 0 } };
            ASSERT shapeLabel(s) == "disc";
          END
        END
      END
    CLEAR
    points = write(dir, "points.clear", <<~CLEAR)
      REQUIRE "pkg:geom_shapes" AS shapes

      PUB STRUCT Point { x: Int64, y: Int64 }

      PUB FN originName(s: Shape) RETURNS String ->
          RETURN shapeLabel(s);
      END
    CLEAR
    [shapes, points]
  end

  def pkg_flags(shapes, points)
    ["--pkg", "geom=#{shapes},#{points}",
     "--pkg", "geom_points=#{points}",
     "--pkg", "geom_shapes=#{shapes}"]
  end

  it "compiles mutually-referential files as one package importable by a root" do
    Dir.mktmpdir do |dir|
      shapes, points = fixture(dir)
      main = write(dir, "main.clear", <<~CLEAR)
        REQUIRE "pkg:geom" AS geom

        FN main() RETURNS Void ->
            p = Point{ x: 1, y: 2 };
            s = Shape{ name: "box", origin: p };
            ASSERT originName(s) == "box", "label";
            RETURN;
        END
      CLEAR

      out = clear("test", main, *pkg_flags(shapes, points))
      expect(out).to include("All 1 tests passed")
    end
  end

  it "runs member TEST blocks via a pkg: root" do
    Dir.mktmpdir do |dir|
      shapes, points = fixture(dir)
      out = clear("test", "pkg:geom", *pkg_flags(shapes, points))
      expect(out).to include("All 2 tests passed")
    end
  end

  it "aliases a member file's own package name to the whole package" do
    Dir.mktmpdir do |dir|
      shapes, points = fixture(dir)
      # Root imports only ONE member's package name; the importer must
      # compile the whole package (the unit is never split).
      main = write(dir, "main.clear", <<~CLEAR)
        REQUIRE "pkg:geom_points" AS points

        FN main() RETURNS Void ->
            s = Shape{ name: "box", origin: Point{ x: 1, y: 2 } };
            ASSERT originName(s) == "box", "label";
            RETURN;
        END
      CLEAR

      out = clear("test", main, *pkg_flags(shapes, points))
      expect(out).to include("All 1 tests passed")
    end
  end

  it "still rejects cycles BETWEEN packages" do
    Dir.mktmpdir do |dir|
      a = write(dir, "a.clear", <<~CLEAR)
        REQUIRE "pkg:right" AS right
        PUB STRUCT A { n: Int64 }
      CLEAR
      b = write(dir, "b.clear", <<~CLEAR)
        REQUIRE "pkg:left" AS left
        PUB STRUCT B { n: Int64 }
      CLEAR
      main = write(dir, "main.clear", <<~CLEAR)
        REQUIRE "pkg:left" AS left

        FN main() RETURNS Void -> RETURN; END
      CLEAR

      out = clear("test", main, "--pkg", "left=#{a}", "--pkg", "right=#{b}")
      expect(out).to match(/Circular dependency detected/)
    end
  end
end
