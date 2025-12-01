class Arena
  # Define the mask locally or access it via Value::OBJ_PAYLOAD_MASK if required/available
  # 48 bits = 0xFFFFFFFFFFFF
  ID_MASK = 0xFFFFFFFFFFFF

  @@static_registry = {}

  def self.register_static(obj)
    id = obj.object_id & ID_MASK
    @@static_registry[id] = obj
  end

  def self.current; @instance ||= new; end

  # Optional: Reset the arena (e.g. between tests)
  def self.reset!; @instance = new; end

  def initialize
    @allocations = []
    @live_objects = {}
  end

  # 1. Register a new Heap Object
  def register(obj)
    @allocations << obj
    id = obj.object_id & ID_MASK
    @live_objects[id] = obj
  end

  # 2. Get the current "Stack Pointer"
  def mark
    @allocations.size
  end

  # 3. Rewind to a previous mark (Poisoning)
  def rewind(start_index)
    dead_objects = @allocations[start_index..-1] || []
    @allocations = @allocations[0...start_index]

    dead_objects.each do |obj|
      obj.poison!
      id = obj.object_id & ID_MASK
      @live_objects.delete(id)
    end
  end

  def find_object_by_address(address)
    # The 'address' is the object_id we boxed earlier
    @live_objects[address] || @@static_registry[address]
  end

  # TODO: ???
  # Note: promote also needs to be updated to delete from @live_objects
  # 4. Save an object from the upcoming rewind (RVO)
  def promote(obj_or_box)
    target_obj = obj_or_box

    # IF it is a Boxed Integer (Pointer), we must find the real object
    if obj_or_box.is_a?(Integer)
      # Check if it's an object tag
      if Value.get_tag(obj_or_box) == Value::TAG_OBJ
        target_obj = Value.as_obj(obj_or_box)
      else
        # Primitives (Bool/Nil/Byte) don't need promotion
        return
      end
    end

    # Now we have the raw object, perform the promotion
    return unless target_obj.is_a?(FluxObject)

    # We remove it from the list so it isn't poisoned during rewind.
    @allocations.delete(target_obj)
    # Don't delete from @live_objects, because it's still accessible globally
  end
end

