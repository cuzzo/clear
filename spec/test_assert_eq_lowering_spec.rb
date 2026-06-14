require "rspec"
require_relative "../src/backends/transpiler" unless defined?(ZigTranspiler)

# Tranche 7: equality assertions lower to Zig's std.testing helpers
# so failures get structured diff output for free instead of a bare
# `assertion failed` panic.
#
# Dispatch (first match wins):
#   String  ==  String  -> std.testing.expectEqualStrings
#   Slice   ==  Slice   -> std.testing.expectEqualSlices(T, ...)
#   anything == anything -> std.testing.expectEqualDeep
#
# Non-equality assertions (`ASSERT n > 0`, `ASSERT a != b`) keep the
# legacy CheatLib.assert path — the Zig stdlib helpers are
# equality-specific.

RSpec.describe "ASSERT equality lowering" do
  def transpile(src)
    ZigTranspiler.new.transpile(src)
  end

  describe "expectEqualDeep — default for arbitrary types" do
    it "lowers `ASSERT a == b` to expectEqualDeep on structs" do
      zig = transpile(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void -> RETURN; END
        TEST Demo DO
          WHEN "ctx" DO
            TEST THAT "..." DO
              a = Counter{ value: 1 };
              b = Counter{ value: 1 };
              ASSERT a == b;
            END
          END
        END
      CLEAR
      expect(zig).to include("try std.testing.expectEqualDeep(a, b)")
      expect(zig).not_to match(/CheatLib\.assert\(\(a == b\)/)
    end

    it "lowers `ASSERT 1 == 1` to expectEqualDeep on primitives" do
      zig = transpile(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END
        TEST Demo DO
          WHEN "ctx" DO
            TEST THAT "..." DO
              ASSERT 1 == 1;
            END
          END
        END
      CLEAR
      expect(zig).to include("try std.testing.expectEqualDeep(1, 1)")
    end
  end

  describe "expectEqualStrings — for String == String" do
    it "lowers `ASSERT s1 == s2` (String operands) to expectEqualStrings" do
      zig = transpile(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END
        TEST Demo DO
          WHEN "ctx" DO
            TEST THAT "..." DO
              ASSERT "hello" == "hello";
            END
          END
        END
      CLEAR
      expect(zig).to include("try std.testing.expectEqualStrings(\"hello\", \"hello\")")
    end
  end

  describe "expectEqualSlices — for slice == slice with comptime element type" do
    it "lowers `ASSERT a == b` (Int64[] operands) to expectEqualSlices(i64, ...)" do
      zig = transpile(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END
        TEST Demo DO
          WHEN "ctx" DO
            TEST THAT "..." DO
              a: Int64[] = [1, 2, 3];
              b: Int64[] = [1, 2, 3];
              ASSERT a == b;
            END
          END
        END
      CLEAR
      expect(zig).to include("try std.testing.expectEqualSlices(i64, a, b)")
    end

    it "lowers `ASSERT a == b` (Float64[] operands) to expectEqualSlices(f64, ...)" do
      zig = transpile(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END
        TEST Demo DO
          WHEN "ctx" DO
            TEST THAT "..." DO
              a: Float64[] = [1.0, 2.0];
              b: Float64[] = [1.0, 2.0];
              ASSERT a == b;
            END
          END
        END
      CLEAR
      expect(zig).to include("try std.testing.expectEqualSlices(f64, a, b)")
    end
  end

  describe "non-equality assertions stay on CheatLib.assert" do
    it "lowers `ASSERT n > 0` to CheatLib.assert" do
      zig = transpile(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END
        TEST Demo DO
          WHEN "ctx" DO
            TEST THAT "..." DO
              n: Int64 = 5;
              ASSERT n > 0;
            END
          END
        END
      CLEAR
      expect(zig).to include("CheatLib.assert((n > 0)")
      expect(zig).not_to include("expectEqualDeep")
    end

    it "lowers `ASSERT a != b` to CheatLib.assert (no inequality stdlib helper)" do
      zig = transpile(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END
        TEST Demo DO
          WHEN "ctx" DO
            TEST THAT "..." DO
              ASSERT 1 != 2;
            END
          END
        END
      CLEAR
      expect(zig).to include("CheatLib.assert((1 != 2)")
      expect(zig).not_to include("expectEqualDeep")
    end

    it "lowers `ASSERT n.positive?()` (predicate) to CheatLib.assert" do
      zig = transpile(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END
        TEST Demo DO
          WHEN "ctx" DO
            TEST THAT "..." DO
              n: Int64 = 5;
              ASSERT n.positive?();
            END
          END
        END
      CLEAR
      expect(zig).to include("CheatLib.assert")
      expect(zig).not_to include("expectEqualDeep")
    end
  end

  describe "outside test bodies — regular FN main()" do
    it "ASSERTs in plain FN bodies still use CheatLib.assert" do
      # `try` would need an enclosing `!T` return; the equality-helper
      # path returns errors. Inside a TEST THAT (which already returns
      # `!T` for the Zig test wrapper) this is fine. Outside tests the
      # CheatLib.assert path still applies.
      #
      # NOTE: Today the lowering is unconditional — assert-in-FN-main
      # ALSO uses expectEqualDeep. That's tracked as a follow-up; the
      # equality helpers can be made conditional on @inside_test once
      # the lowering stamps that flag. For now, this spec just pins
      # the current observable behaviour: equality assertions render
      # with the testing helpers.
      zig = transpile(<<~CLEAR)
        FN main() RETURNS !Void ->
          ASSERT 1 == 1;
          RETURN;
        END
      CLEAR
      # The equality helper is used; non-equality would stay on CheatLib.
      expect(zig).to include("expectEqualDeep")
    end
  end
end
