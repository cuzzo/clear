require 'rspec'
require_relative '../src/types'

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

      obj = FluxArray.new(nil, [1])

      # Save 'obj' from the upcoming purge
      Arena.current.promote(obj)

      # Rewind
      Arena.current.rewind(mark)

      # It should still be alive!
      expect(obj[0]).to eq(1)
    end
  end
end

