require 'rspec'
require_relative '../src/types'
require_relative '../src/value'
require_relative '../src/arena'
require_relative '../src/vm' # To ensure we load the same environment as the VM

RSpec.describe "Memory Integration (Types <-> Value <-> Arena)" do
  before(:each) do
    Arena.reset!
  end

  it "successfully boxes and unboxes a FluxObject" do
    obj = FluxString.new("Integration Test", register: true)

    # 1. Box it
    boxed = Value.box_obj(obj)

    # 2. Unbox it (This triggers the lookup that is failing in your VM tests)
    unboxed = Value.as_obj(boxed)

    expect(unboxed).to eq(obj)
    expect(unboxed.to_s).to eq("Integration Test")
  end

  it "successfully boxes and unboxes a Static Constant" do
    # Simulate compiler creating a constant
    const_str = FluxString.new("Static Data", register: :static)

    Arena.reset!

    # Box/Unbox should still work because it's static
    boxed = Value.box_constant(const_str)
    unboxed = Value.unbox(boxed)

    expect(unboxed.to_s).to eq("Static Data")
  end


  it "correctly handles FluxPtr (View) registration and dereferencing" do
    # 1. Create Owner
    owner = FluxString.new("Owner Data")

    # 2. Create Pointer
    # This should register the Pointer object in the Arena
    ptr = FluxPtr.new(owner)

    # 3. Box the Pointer (simulating TAKE_REF result in register)
    boxed_ptr = Value.box_obj(ptr)

    # 4. Unbox the Pointer
    unboxed_ptr = Value.as_obj(boxed_ptr)
    expect(unboxed_ptr).to be_a(FluxPtr)
    expect(unboxed_ptr).to eq(ptr)

    # 5. Dereference
    expect(unboxed_ptr.deref).to eq(owner)
    expect(unboxed_ptr.deref.to_s).to eq("Owner Data")
  end

  it "raises Segfault/MemoryError when unboxing a poisoned (dead) object" do
    # 1. Create object
    mark = Arena.current.mark
    obj = FluxString.new("Temporary")
    boxed = Value.box_obj(obj)

    # 2. Kill it (Rewind)
    Arena.current.rewind(mark)

    # 3. Try to Unbox (Should fail lookup in Arena)
    expect {
      Value.as_obj(boxed)
    }.to raise_error(/Memory Error: Segfault/)
  end

  it "handles Byte wrapping correctly at the Value boundary" do
    # 256 should wrap to 0
    boxed = Value.box_byte(256)
    expect(Value.get_tag(boxed)).to eq(Value::TAG_BYTE)
    expect(Value.as_byte(boxed)).to eq(0)

    # 255 should be 255
    boxed_max = Value.box_byte(255)
    expect(Value.as_byte(boxed_max)).to eq(255)
  end

  it "differentiates between Boxed Integers (Bytes) and Raw Numbers" do
    # 10.0 is a Float -> TAG_NUMBER
    boxed_num = Value.box_number(10)
    expect(Value.get_tag(boxed_num)).to eq(Value::TAG_NUMBER)

    # 10 is an Integer -> TAG_BYTE (if boxed explicitly)
    boxed_byte = Value.box_byte(10)
    expect(Value.get_tag(boxed_byte)).to eq(Value::TAG_BYTE)

    # They should NOT be equal
    expect(boxed_num).not_to eq(boxed_byte)
  end
end
