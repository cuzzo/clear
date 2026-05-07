require "rspec"
require_relative "../src/backends/transpiler"
require_relative "../src/tools/formatter"

# Predicate-library tranche of the test framework. Each predicate is a
# stdlib FN tagged `is_method: true` so call sites read as English when
# fed to ASSERT:
#
#   ASSERT n.positive?();
#   ASSERT score.between?(0, 100);
#   ASSERT temp.closeTo?(98.6, 0.1);
#
# The predicates ship in core STD_LIB rather than `pkg:testing` because
# they're useful well outside testing — in app code, in pipelines,
# anywhere a boolean read should sound like English.
#
# These specs verify (a) each predicate compiles when used UFCS-style,
# and (b) `clear fmt` rewrites prefix calls to UFCS form.

RSpec.describe "predicate library — numeric" do
  def transpile(src)
    ZigTranspiler.new.transpile(src)
  end

  def fmt(src)
    Formatter.format(src)
  end

  describe "compilation" do
    it "compiles n.zero?() for Int64" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          n: Int64 = 0;
          ASSERT n.zero?();
          RETURN;
        END
      CLEAR
      expect { transpile(src) }.not_to raise_error
    end

    it "compiles f.zero?() for Float64" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          f: Float64 = 0.0;
          ASSERT f.zero?();
          RETURN;
        END
      CLEAR
      expect { transpile(src) }.not_to raise_error
    end

    it "compiles n.positive?() / n.negative?()" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          n: Int64 = 5;
          ASSERT n.positive?();
          ASSERT (-n).negative?();
          RETURN;
        END
      CLEAR
      expect { transpile(src) }.not_to raise_error
    end

    it "compiles n.even?() / n.odd?()" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          ASSERT 4.even?();
          ASSERT 5.odd?();
          RETURN;
        END
      CLEAR
      expect { transpile(src) }.not_to raise_error
    end

    it "compiles n.between?(low, high) for Int64" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          n: Int64 = 5;
          ASSERT n.between?(1, 10);
          RETURN;
        END
      CLEAR
      expect { transpile(src) }.not_to raise_error
    end

    it "compiles f.between?(low, high) for Float64" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          f: Float64 = 3.14;
          ASSERT f.between?(0.0, 10.0);
          RETURN;
        END
      CLEAR
      expect { transpile(src) }.not_to raise_error
    end

    it "compiles f.closeTo?(val, tol) for Float64" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          f: Float64 = 3.14;
          ASSERT f.closeTo?(3.14, 0.001);
          RETURN;
        END
      CLEAR
      expect { transpile(src) }.not_to raise_error
    end
  end

  describe "fmt rewrite to UFCS" do
    it "rewrites positive?(n) to n.positive?()" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          n: Int64 = 5;
          ok = positive?(n);
          RETURN;
        END
      CLEAR
      expect(fmt(src)).to include("ok = n.positive?();")
    end

    it "rewrites between?(n, 1, 10) to n.between?(1, 10)" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          n: Int64 = 5;
          ok = between?(n, 1, 10);
          RETURN;
        END
      CLEAR
      expect(fmt(src)).to include("ok = n.between?(1, 10);")
    end

    it "rewrites closeTo?(f, 3.14, 0.001) to f.closeTo?(3.14, 0.001)" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          f: Float64 = 3.14;
          ok = closeTo?(f, 3.14, 0.001);
          RETURN;
        END
      CLEAR
      expect(fmt(src)).to include("ok = f.closeTo?(3.14, 0.001);")
    end

    it "rewrites all numeric predicates in a single pass" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          n: Int64 = 5;
          a = zero?(n);
          b = positive?(n);
          c = negative?(n);
          d = even?(n);
          e = odd?(n);
          RETURN;
        END
      CLEAR
      out = fmt(src)
      expect(out).to include("a = n.zero?();")
      expect(out).to include("b = n.positive?();")
      expect(out).to include("c = n.negative?();")
      expect(out).to include("d = n.even?();")
      expect(out).to include("e = n.odd?();")
    end
  end
end

RSpec.describe "pkg:testing — first-party stdlib package resolution" do
  def transpile(src)
    ZigTranspiler.new.transpile(src)
  end

  it "resolves `REQUIRE \"pkg:testing\"` without an explicit --pkg flag" do
    src = <<~CLEAR
      REQUIRE "pkg:testing"

      FN main() RETURNS Void ->
        b = ready?();
        ASSERT b;
        RETURN;
      END
    CLEAR
    expect { transpile(src) }.not_to raise_error
  end

  it "errors with a useful message when the package doesn't exist" do
    src = <<~CLEAR
      REQUIRE "pkg:nonexistent_package_xyz"

      FN main() RETURNS Void ->
        RETURN;
      END
    CLEAR
    expect { transpile(src) }.to raise_error(/unknown package 'nonexistent_package_xyz'/)
  end
end
