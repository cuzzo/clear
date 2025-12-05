require 'rspec'
require 'objspace'

require_relative '../src/types'
require_relative '../src/value'

RSpec.describe "Flux Type System" do
  # Reset the Arena before every test so allocations don't leak
  before(:each) do
    Arena.reset!
  end

  describe FluxByte do
    it "wraps around 255" do
      b = FluxByte.new(255)
      res = b + FluxByte.new(1)
      expect(res.value).to eq(0)
    end

    it "behaves like a value type" do
      b1 = FluxByte.new(10)
      b2 = FluxByte.new(10)
      expect(b1).to eq(b2)
    end
  end

  describe FluxArray do
    it "acts like a dynamic array" do
      arr = FluxArray.new(nil, [1, 2]) # nil = dynamic
      arr << 3
      expect(arr.size).to eq(3)
      expect(arr[2]).to eq(3)
    end

    it "enforces fixed size limits" do
      # Fixed size of 2
      arr = FluxArray.new(2, [1, 2])

      expect {
        arr << 3
      }.to raise_error(RuntimeError, /Cannot append to Fixed Array/)
    end

    it "delegates methods to underlying array via method_missing" do
      arr = FluxArray.new(nil, [1, 2, 3])
      # .first is not explicitly defined, so it hits method_missing
      expect(arr.first).to eq(1)
    end

    context "when type is :int64" do
      it "allocates exactly 8 bytes per slot" do
        # 10 items * 8 bytes = 80 bytes
        arr = FluxArray.new(10, nil, type: :int64, register: false)

        # Verify backing store is a String (Binary Blob), not an Array
        expect(arr.data).to be_a(String)
        expect(arr.data.bytesize).to eq(80)
      end

      it "stores 64-bit integers correctly" do
        arr = FluxArray.new(1, nil, type: :int64, register: false)

        # Max 64-bit signed integer
        val = Value::MAX_SAFE_INTEGER - 1

        # Use Value.box_number(val) if your setter expects boxes
        # Assuming your VM loop boxes it before calling []=
        boxed_val = Value.box_number(val)

        arr[0] = boxed_val

        # Read it back (Unbox happens inside [])
        expect(arr[0]).to eq(val)
      end
    end

    context "when type is :byte" do
      it "allocates exactly 1 byte per slot" do
        # 256 items * 1 byte = 256 bytes
        arr = FluxArray.new(256, nil, type: :byte, register: false)

        expect(arr.data).to be_a(String)
        expect(arr.data.bytesize).to eq(256)
      end

      it "wraps values > 255" do
        arr = FluxArray.new(1, nil, type: :byte, register: false)

        # 300 % 256 = 44
        boxed_val = Value.box_number(300)
        arr[0] = boxed_val

        # Expect the unboxed value to be wrapped
        expect(Value.unbox(arr[0])).to eq(44)
      end
    end
  end

  describe FluxString do
    it "concatenates with strings or other FluxStrings" do
      s1 = FluxString.new("Hello")
      s2 = FluxString.new(" World")

      res = s1 + s2
      expect(res).to be_a(FluxString)
      expect(res.to_s).to eq("Hello World")
    end
  end

  describe FluxHash do
    it "allows key/value access" do
      h = FluxHash.new
      h["x"] = 10
      expect(h["x"]).to eq(10)
      expect(h.key?("x")).to be true
    end
  end

  describe FluxView do
    it "reads from the owner without copying" do
      owner = FluxArray.new(nil, [10, 20, 30, 40])
      # View starting at index 1, length 2
      view = FluxView.new(owner, 1, 2)

      expect(view[0]).to eq(20) # owner[1]
      expect(view[1]).to eq(30) # owner[2]

      # Bounds check
      expect { view[2] }.to raise_error(/View index out of bounds/)
    end

    it "reflects changes in the owner" do
      owner = FluxArray.new(nil, [10, 20])
      view = FluxView.new(owner, 0, 1)

      # Mutate owner
      owner[0] = 99

      # View sees the change (Pass by Reference behavior)
      expect(view[0]).to eq(99)
    end
  end

  describe "Arena Memory Safety" do
    it "poisons objects after a rewind (Use After Free)" do
      # 1. Start a "Function Frame"
      mark = Arena.current.mark

      # 2. Allocate object inside the frame
      local_arr = FluxArray.new(nil, [1, 2, 3])

      # Sanity check: it works
      expect(local_arr[0]).to eq(1)

      # 3. End function (Rewind the stack)
      Arena.current.rewind(mark)

      # 4. Try to access the object (Dangling Pointer)
      expect {
        local_arr[0]
      }.to raise_error(/Memory Error: Use After Free/)
    end

    it "poisons Views if the Owner dies" do
      mark = Arena.current.mark

      owner = FluxArray.new(nil, [10, 20])

      # Create View OUTSIDE the scope (simulate return or promotion)
      # We manually promote it or create it in a way that survives rewind.
      view = FluxView.new(owner, 0, 1)
      Arena.current.promote(view) # This causes survival after rewind

      # Kill the stack frame
      Arena.current.rewind(mark)

      # Accessing the view should fail because the Owner is dead
      expect {
        view[0]
      }.to raise_error(/Memory Error: Dangling Pointer/)
    end

    it "allows RVO via promote" do
      mark = Arena.current.mark

      boxed_val = Value.box_number(1)
      obj = FluxArray.new(nil, [boxed_val])

      # Save 'obj' from the upcoming purge
      survivors = Arena.current.promote(obj)

      # Rewind
      Arena.current.rewind(mark)

      survivors.each { |s| Arena.current.register(s) }

      # It should still be alive!
      expect(obj[0]).to eq(boxed_val)
    end
  end
end

RSpec.describe "VM Type Formatting" do

  describe FluxArray do
    context "when it is a basic Object Array" do
      # VM Workflow: process_new_list usually inits with empty data
      let(:arr) { FluxArray.new(10, [], type: :obj) }

      before do
        # VM Workflow: process_append or process_set_index fills it
        arr[0] = 1
        arr[1] = 2
        arr[2] = 3
        # Indices 3-9 remain nil
      end

      it "inspects as Obj[Size]" do
        expect(arr.inspect).to eq("Obj[10]")
      end

      it "to_s returns a human readable list with padding" do
        expect(arr.to_s).to eq("[1, 2, 3, nil, nil, nil, nil, nil, nil, nil]")
      end
    end

    context "when it is a Typed Array (Int64)" do
      # VM Workflow: process_array_cast or alloca creates empty binary blob
      let(:arr) { FluxArray.new(4, nil, type: :int64) }

      before do
        # VM Workflow: process_set_index passes BOXED values
        # We assume Value.box_number handles int64 boxing
        arr[0] = Value.box_number(100)
        arr[1] = Value.box_number(200)
      end

      it "inspects as Int64[Size]" do
        expect(arr.inspect).to eq("Int64[4]")
      end

      it "to_s returns a human readable list" do
        # Expect the 2 values we added, plus 2 empty slots (0)
        expect(arr.to_s).to eq("[100, 200, 0, 0]")
      end
    end

    context "when it is a Struct (via process_new_struct)" do
      # VM Workflow: process_new_struct creates :nanbox array with nil data
      let(:arr) { FluxArray.new(5, nil, type: :nanbox) }

      before do
        # VM Workflow: monkey-patches type
        arr.struct_type = "MyStruct"

        # VM Workflow: process_set_field passes BOXED values
        arr[0] = Value.box_number(1)
        arr[1] = Value.box_number(1)
        # Indices 2,3,4 are 0.0 (or 0) because of binary init
      end

      it "inspects using Curly Braces {Size}" do
        expect(arr.inspect).to eq("MyStruct{5}")
      end

      it "to_s still returns list content" do
        # NanBox 0 unboxes to float 0.0 or int 0 depending on bit pattern
        # Default \x00 is 0.0 in double precision usually, or 0 int.
        # Let's match typical NanBox behavior (double 0.0)
        expect(arr.to_s).to match(/\[1(\.0)?, 1(\.0)?, 0(\.0)?, 0(\.0)?, 0(\.0)?\]/)
        #expect(arr.to_s).to match(/\[1, 1, 0(\.0)?, 0(\.0)?, 0(\.0)?\]/)
      end
    end

    context "when it is a Byte Array Struct (ByteArray)" do
      # VM Workflow: process_new_struct with name "ByteArray"
      let(:arr) { FluxArray.new(5, nil, type: :nanbox) }

      before do
        arr.struct_type = "ByteArray"
        # VM Workflow: set_index with Boxed Numbers
        bytes = [72, 101, 108, 108, 111] # Hello
        bytes.each_with_index { |b, i| arr[i] = Value.box_number(b) }
      end

      it "inspects as ByteArray{Size}" do
        expect(arr.inspect).to eq("ByteArray{5}")
      end

      it "to_s converts the integers to a string" do
        expect(arr.to_s).to eq("Hello")
      end
    end

    context "when it is a native :byte type (via Cast)" do
      # VM Workflow: process_array_cast can create :byte type
      let(:arr) { FluxArray.new(3, nil, type: :byte) }

      before do
        # VM passes boxed numbers, Array converts to byte
        arr[0] = Value.box_number(65)
        arr[1] = Value.box_number(66)
        arr[2] = Value.box_number(67)
      end

      it "inspects as Byte[Size]" do
        expect(arr.inspect).to eq("Byte[3]")
      end

      it "to_s converts to string" do
        expect(arr.to_s).to eq("ABC")
      end
    end
  end
end

RSpec.describe "Hypothesis Verification: Mixed-Key Recursion" do
  it "successfully serializes the specific nested structure of Constant 4" do
    # 1. SETUP: The exact structure retrieved from your debug output
    # Outer key "chunks" is a String.
    # Inner keys :name, :code, :constants are Symbols.
    # Deepest key "number" is a String.
    failing_structure = {
      "chunks" => {
        :name => "test",
        :code => [
          [:LOADK, "R2", "K0"],
          [:RETURN, "R2"],
          [:JMP, 3],
          [:RETURN, "R0"]
        ],
        :constants => [
          { "number" => nil }
        ]
      }
    }

    # 2. ACT & ASSERT: Attempt to pack it
    # If this fails with the same error, the structure/mixing of keys is the root cause.
    # If this PASSES, I am wrong, and the issue is not the structure itself.
    expect { failing_structure.to_msgpack }.not_to raise_error
  end
end

