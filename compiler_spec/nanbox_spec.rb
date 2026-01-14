require "rspec"
require_relative "../src/value"
require_relative "../src/types"

RSpec.describe "Value Module (NaN Boxing Simulation)" do
  let(:flux_array) { FluxArray.new(nil, [1, 2]) }
  let(:flux_byte) { FluxByte.new(255) }

  describe "Tag Identification (get_tag)" do
    it "identifies boxed Numbers" do
      # Box it first!
      boxed = Value.box_number(10)
      expect(Value.get_tag(boxed)).to eq(Value::TAG_NUMBER)
    end

    it "identifies boxed Bools" do
      boxed = Value.box_bool(true)
      expect(Value.get_tag(boxed)).to eq(Value::TAG_BOOL)
    end

    it "identifies boxed Nils" do
      boxed = Value.box_nil
      expect(Value.get_tag(boxed)).to eq(Value::TAG_NIL)
    end

    it "identifies boxed Bytes" do
      boxed = Value.box_byte(255)
      expect(Value.get_tag(boxed)).to eq(Value::TAG_BYTE)
    end

    it "identifies boxed Objects" do
      boxed = Value.box_obj(flux_array)
      expect(Value.get_tag(boxed)).to eq(Value::TAG_OBJ)
    end
  end

  describe "Encoding/Decoding Symmetry" do
    it "preserves Numbers" do
      boxed = Value.box_number(3.14)
      expect(Value.as_number(boxed)).to eq(3.14)
    end

    it "preserves Bools" do
      boxed = Value.box_bool(true)
      expect(Value.as_bool(boxed)).to be true
    end

    it "preserves Bytes (as Integers)" do
      # Note: We pass 255 (Integer), we get 255 (Integer)
      boxed = Value.box_byte(255)
      expect(Value.as_byte(boxed)).to eq(255)
    end

    it "wraps Bytes on overflow during boxing" do
      # 256 -> 0
      boxed = Value.box_byte(256)
      expect(Value.as_byte(boxed)).to eq(0)
    end

    it "preserves Objects" do
      boxed = Value.box_obj(flux_array)
      expect(Value.as_obj(boxed)).to eq(flux_array)
    end
  end

  describe "Constant Boxing (box_constant)" do
    it "boxes raw Numbers" do
      boxed = Value.box_constant(42)
      expect(Value.get_tag(boxed)).to eq(Value::TAG_NUMBER)
    end

    it "boxes FluxByte objects as TAG_BYTE" do
      # This handles the FluxByte class used in the compiler
      boxed = Value.box_constant(flux_byte)
      expect(Value.get_tag(boxed)).to eq(Value::TAG_BYTE)
      expect(Value.as_byte(boxed)).to eq(255)
    end
  end

  describe "Generic Unbox Helper" do
    it "unboxes FluxByte to raw Integer" do
      boxed = Value.box_byte(255)
      expect(Value.unbox(boxed)).to eq(255)
    end
  end
end
