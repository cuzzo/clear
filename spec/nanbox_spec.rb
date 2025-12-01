require "rspec"

require_relative "../src/value"
require_relative "../src/types"

RSpec.describe "Value Module (NaN Boxing Simulation)" do
  # Prerequisite: Ensure FluxObject types are available without needing a full VM run
  let(:flux_array) { FluxArray.new(nil, [1, 2]) }
  let(:flux_string) { FluxString.new("test", register: false) }
  let(:flux_byte) { FluxByte.new(255) }

  # --- Tag Consistency Check ---
  # These tests verify that the tag system correctly identifies the type
  # based on the underlying object, regardless of what the VM does with it.
  describe "Tag Identification (get_tag)" do
    it "correctly identifies TAG_NUMBER for integers and floats" do
      expect(Value.get_tag(10)).to eq(Value::TAG_NUMBER)
      expect(Value.get_tag(10.5)).to eq(Value::TAG_NUMBER)
    end

    it "correctly identifies TAG_BOOL" do
      expect(Value.get_tag(true)).to eq(Value::TAG_BOOL)
      expect(Value.get_tag(false)).to eq(Value::TAG_BOOL)
    end

    it "correctly identifies TAG_NIL" do
      expect(Value.get_tag(nil)).to eq(Value::TAG_NIL)
    end

    it "correctly identifies TAG_BYTE" do
      expect(Value.get_tag(flux_byte)).to eq(Value::TAG_BYTE)
    end

    it "correctly identifies TAG_OBJ for complex heap objects" do
      # Note: FluxByte must NOT be treated as a generic object
      expect(Value.get_tag(flux_array)).to eq(Value::TAG_OBJ)
      expect(Value.get_tag(flux_string)).to eq(Value::TAG_OBJ)
    end
  end

  # --- Encoding/Decoding (Boxing Discipline) ---
  # These tests ensure the box/unbox functions are symmetrical and safe.
  describe "Encoding and Decoding Symmetry" do
    it "preserves Number values through boxing and unboxing" do
      boxed = Value.box_number(3.14)
      # In the Ruby mock, boxed is just 3.14, but we test the API
      expect(Value.as_number(boxed)).to eq(3.14)
    end

    it "preserves Boolean values through boxing and unboxing" do
      boxed = Value.box_bool(true)
      expect(Value.as_bool(boxed)).to be true
    end

    it "preserves FluxObject identity through boxing and unboxing" do
      original_id = flux_array.object_id
      boxed = Value.box_obj(flux_array)
      unboxed = Value.as_obj(boxed)

      # Crucial: Unboxing must return the original object instance (pointer)
      expect(unboxed.object_id).to eq(original_id)
      expect(unboxed).to be_a(FluxArray)
    end
  end

  # --- Constant Loading Discipline (LOADK) ---
  # These ensure the system correctly identifies and handles raw constants
  # before they enter the execution registers.
  describe "Constant Boxing (box_constant)" do
    it "boxes raw Ruby String constants into FluxString Objects" do
      raw_string = "Error Message"
      boxed = Value.box_constant(raw_string)

      # 1. Must be tagged as an Object
      expect(Value.get_tag(boxed)).to eq(Value::TAG_OBJ)
      # 2. Must be the FluxString type
      expect(Value.as_obj(boxed)).to be_a(FluxString)
      # 3. Must not be registered (immortal flag)
      expect(Value.as_obj(boxed).is_alive).to be true # Alive, but untracked
    end

    it "boxes raw Number constants correctly" do
      boxed = Value.box_constant(42)
      expect(Value.get_tag(boxed)).to eq(Value::TAG_NUMBER)
      expect(Value.as_number(boxed)).to eq(42.0)
    end

    it "boxes FluxByte constants as TAG_BYTE" do
      boxed = Value.box_constant(flux_byte)
      expect(Value.get_tag(boxed)).to eq(Value::TAG_BYTE)
      expect(Value.as_byte(boxed)).to be_a(FluxByte)
    end
  end

  # --- Generic Unboxing (Testing Helper) ---
  # This tests the convenience method used by your RSpec assertions.
  describe "Generic Unbox Helper" do
    it "unboxes a FluxArray reference correctly (returns the container)" do
      boxed = Value.box_obj(flux_array)
      unboxed_container = Value.unbox(boxed)

      expect(unboxed_container).to be_a(FluxArray)
    end

    it "unboxes a boxed Number to its raw Float value" do
      boxed = Value.box_number(123)
      expect(Value.unbox(boxed)).to eq(123.0)
    end

    it "unboxes a FluxString to a raw Ruby String" do
      boxed = Value.box_constant("Result")
      expect(Value.unbox(boxed)).to eq("Result")
    end

    it "unboxes a FluxByte to its raw Integer value" do
      boxed = Value.box_constant(flux_byte)
      expect(Value.unbox(boxed)).to eq(255) # FluxByte#value should be 255
    end
  end
end

