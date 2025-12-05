# Static Registery
#   * Constants
#   * Struct Defs & Function Defs (named functions)
#   * Built-in Functions
#   * Singletons (empty string, empty list, etc)
#   * Symbols
# Regular Registry
#   * Everything else inside a function
class Arena
  # Define the mask locally or access it via Value::OBJ_PAYLOAD_MASK if required/available
  # 48 bits = 0xFFFFFFFFFFFF
  ID_MASK = 0xFFFFFFFFFFFF

  # This prevents Static (Compile Time) and Heap (Runtime) collisions.
  @@next_id = 1
  def self.allocate_id
    id = @@next_id
    @@next_id = (@@next_id + 1) & ID_MASK
    id
  end

  @@static_registry = {}

  def self.register_static(obj)
    id = obj.flux_id & ID_MASK
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
    id = obj.flux_id & ID_MASK
    @live_objects[id] = obj
  end

  # 2. Get the current "Stack Pointer"
  def mark
    @allocations.size
  end

  # 3. Rewind to a previous mark (Poisoning)
  # Currently an O(N) operation.
  # After implementing pages, this will be O(1).
  def rewind(start_index)
    dead_objects = @allocations[start_index..-1] || []
    @allocations = @allocations[0...start_index]

    dead_objects.each do |obj|
      obj.poison!
      id = obj.flux_id & ID_MASK
      @live_objects.delete(id)
    end
  end

  def find_object_by_address(address)
    # The 'address' is the object_id we boxed earlier
    @live_objects[address] || @@static_registry[address]
  end

  # Note: promote also needs to be updated to delete from @live_objects
  # 4. Save an object (and descendents resursively) from the upcoming rewind
  #    (RVO)
  def promote(obj_or_box)
    survivors = []

    # Queue for Breadth-First Search (Graph Traversal)
    queue = [obj_or_box]

    # Keep track of visited IDs to handle cyclic references
    visited = {}

    while queue.any?
      curr = queue.shift

      # 1. Resolve Boxed Pointer -> Real Object
      target_obj = curr
      if curr.is_a?(Integer)
        # Only unbox if it looks like an object pointer
        if defined?(Value) && Value.get_tag(curr) == Value::TAG_OBJ
          target_obj = Value.as_obj(curr)
        else
          next # Primitive (Number/Bool/Byte) - no need to promote
        end
      end

      # Skip if not a managed object or already processed
      next unless target_obj.is_a?(FluxObject)
      next if visited[target_obj.object_id]

      # 2. Check if currently managed by Arena
      # If it's not in @allocations, it's either Static or already promoted.
      if @allocations.include?(target_obj)
        # REMOVE from the death zone (Stash)
        @allocations.delete(target_obj)

        # Add to survivors list
        survivors << target_obj
        visited[target_obj.object_id] = true

        # 3. Enqueue Children (Recursion)
        case target_obj
        when FluxArray
          (0...target_obj.size).each do |i|
            queue << target_obj[i]
          end
        when FluxHash
          # Promote values (keys are usually primitives/static strings)
          target_obj.data.values.each do |val|
            queue << val
          end
        when FluxClosure
          # Promote captured variables
          target_obj.captures.each do |val|
            queue << val
          end
        end
      end
    end

    return survivors
  end
end

