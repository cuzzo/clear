require 'rspec'
require_relative '../src/arena'
require_relative '../src/types' # Needed for FluxObject

# A helper class to track poisoning status without complex logic
class TestObject < FluxObject
  def initialize(register: true)
    super(register: register)
    @poisoned = false
  end
end

RSpec.describe Arena do
  before(:each) do
    Arena.reset!
  end

  describe "Registration & Lookup" do
    it "registers an object and finds it by masked address" do
      obj = TestObject.new

      # Calculate expected address using the mask
      expected_addr = obj.flux_id & Arena::ID_MASK

      found = Arena.current.find_object_by_address(expected_addr)
      expect(found).to eq(obj)
    end

    it "does not find objects that were never registered" do
      obj = TestObject.new(register: false)
      addr = obj.flux_id & Arena::ID_MASK

      found = Arena.current.find_object_by_address(addr)
      expect(found).to be_nil
    end
  end

  describe "Static Registration (Constants)" do
    it "registers static objects that persist across resets" do
      # 1. Register a static object
      static_obj = TestObject.new(register: :static)
      static_addr = static_obj.flux_id & Arena::ID_MASK

      # 2. Reset the Arena (Simulate new VM run)
      Arena.reset!

      # 3. It should still be found
      found = Arena.current.find_object_by_address(static_addr)
      expect(found).to eq(static_obj)
      expect(found.is_alive).to be true
    end
  end

  describe "Stack Lifecycle (Mark & Rewind)" do
    it "poisons objects allocated after the mark" do
      # 1. Base level object
      root_obj = TestObject.new

      # 2. Mark the stack (Start of function)
      mark = Arena.current.mark

      # 3. Allocate 'local' objects
      local_obj = TestObject.new

      # 4. Rewind (End of function)
      Arena.current.rewind(mark)

      # Root should be alive
      expect(root_obj.is_alive?).to be(true)
      expect(Arena.current.find_object_by_address(root_obj.flux_id & Arena::ID_MASK)).to eq(root_obj)

      # Local should be dead and removed from registry
      expect(local_obj.is_poisoned?).to be(true)
      expect(Arena.current.find_object_by_address(local_obj.flux_id & Arena::ID_MASK)).to be_nil
    end

    it "handles nested stack frames correctly" do
      mark1 = Arena.current.mark
      obj1 = TestObject.new

      mark2 = Arena.current.mark
      obj2 = TestObject.new

      # Rewind inner frame
      Arena.current.rewind(mark2)
      expect(obj2.is_poisoned?).to be(true)
      expect(obj1.is_alive?).to be(true)

      # Rewind outer frame
      Arena.current.rewind(mark1)
      expect(obj1.is_poisoned?).to be(true)
    end
  end

  describe "Promotion (RVO)" do
    it "protects promoted objects from being poisoned during rewind" do
      mark = Arena.current.mark

      # Allocate object in this scope
      result_obj = TestObject.new
      garbage_obj = TestObject.new

      # Promote the result
      Arena.current.promote(result_obj)

      # Rewind
      Arena.current.rewind(mark)

      # Result should survive
      expect(result_obj.is_alive?).to be(true)
      expect(result_obj.is_alive?).to be(true)
      # Registry lookup should still work
      expect(Arena.current.find_object_by_address(result_obj.flux_id & Arena::ID_MASK)).to eq(result_obj)

      # Garbage should be dead
      expect(garbage_obj.is_poisoned?).to be(true)
    end
  end

  describe "Masking Logic" do
    it "handles object_ids larger than the mask correctly" do
      # This is harder to mock without stubbing object_id,
      # but we can verify the mask constant exists and is applied.

      obj = TestObject.new
      raw_id = obj.flux_id
      masked_id = raw_id & Arena::ID_MASK

      # Verify internal storage uses masked key
      internal_map = Arena.current.instance_variable_get(:@live_objects)
      expect(internal_map.key?(masked_id)).to be true

      # If the ID was small enough, masked == raw
      # If large, masked != raw. Both should be consistent.
      found = Arena.current.find_object_by_address(masked_id)
      expect(found).to eq(obj)
    end
  end
end

