class Arena
  def self.current; @instance ||= new; end

  # Optional: Reset the arena (e.g. between tests)
  def self.reset!; @instance = new; end

  def initialize
    @allocations = []
  end

  # 1. Register a new Heap Object
  def register(obj)
    @allocations << obj
  end

  # 2. Get the current "Stack Pointer"
  def mark
    @allocations.size
  end

  # 3. Rewind to a previous mark (Poisoning)
  def rewind(start_index)
    dead_objects = @allocations[start_index..-1] || []
    @allocations = @allocations[0...start_index]

    dead_objects.each(&:poison!)
  end

  # 4. Save an object from the upcoming rewind (RVO)
  def promote(obj)
    return unless obj.is_a?(FluxObject)
    # We remove it from the list so it isn't poisoned during rewind.
    # It effectively "moves" to the parent scope's lifespan.
    @allocations.delete(obj)
  end
end
