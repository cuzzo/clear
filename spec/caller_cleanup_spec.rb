require "rspec"
require_relative "../src/transpiler"

# Tests CALLER-side cleanup for heap-promoted return values.
# When a function with returns_promoted returns data, the caller must
# emit defer cleanup so heap allocations are freed.

RSpec.describe "Caller-side cleanup for promoted returns" do
  def transpile(src)
    ZigTranspiler.new.transpile(src)
  end

  def fn_body(zig, name)
    zig[/fn #{name}\b.*?\n(.*?)^}/m, 1]
  end

  # =========================================================================
  # Case 1: Direct binding of returns_promoted function
  # list1 = makeList() should get defer cleanup
  # =========================================================================
  describe "direct binding of promoted list return" do
    let(:zig) do
      transpile(<<~CLEAR)
        FN makeList() RETURNS Int64[] ->
            MUTABLE items: Int64[]@list = List[];
            items.append(1_i64);
            RETURN items;
        END
        FN main() RETURNS Void ->
            list1 = makeList();
            ASSERT list1.length() == 1;
            RETURN;
        END
      CLEAR
    end

    it "emits defer cleanup for the caller's binding" do
      main_body = fn_body(zig, "clearMain")
      expect(main_body).to include("defer")
      expect(main_body).to include("cleanup").or include("free")
    end
  end

  # =========================================================================
  # Case 2: Union with List variant from returns_promoted function
  # val = readFormEnv() where Value union has List: []Value
  # =========================================================================
  # Known limitation: union with string variant can't be cleaned up generically
  # because cleanup can't distinguish heap strings from rodata at comptime.
  # Requires v0.2 isFrameOwned runtime check.
  describe "binding of promoted union return with heap variant" do
    let(:zig) do
      transpile(<<~CLEAR)
        UNION Value { Num: Float64, Text: String }
        FN makeValue(s: String) RETURNS Value ->
            label = s + "!";
            RETURN Value{ Text: label };
        END
        FN main() RETURNS Void ->
            v = makeValue("hi");
            RETURN;
        END
      CLEAR
    end

    it "does NOT emit cleanup (string provenance unknown at comptime)" do
      main_body = fn_body(zig, "clearMain")
      expect(main_body).not_to include("cleanup(Value")
    end
  end

  # =========================================================================
  # Case 3: Nested binding in IF branch
  # IF cond THEN val = promoted(); END — val still needs cleanup
  # =========================================================================
  describe "promoted return bound inside IF branch" do
    let(:zig) do
      transpile(<<~CLEAR)
        FN makeList() RETURNS Int64[] ->
            MUTABLE items: Int64[]@list = List[];
            items.append(1_i64);
            RETURN items;
        END
        FN main() RETURNS Void ->
            MUTABLE result: Int64[] = [];
            IF TRUE THEN
                result = makeList();
            END
            ASSERT result.length() == 1;
            RETURN;
        END
      CLEAR
    end

    it "emits defer cleanup for the binding" do
      main_body = fn_body(zig, "clearMain")
      expect(main_body).to include("defer")
    end
  end
end
