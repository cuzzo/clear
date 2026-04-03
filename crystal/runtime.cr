# ---------------------------------------------------------------
# 1. The Arena Allocator
# ---------------------------------------------------------------
class Arena
  getter offset : Int32

  def initialize(@capacity : Int32)
    # We allocate one massive slab of raw memory.
    # This is the only time we touch the OS/GC.
    @memory = Pointer(UInt8).malloc(@capacity)
    @offset = 0
  end

  # The "Bump Pointer" Allocation (O(1))
  def alloc(size : Int32) : Pointer(UInt8)
    if @offset + size > @capacity
      raise "Stack Overflow / OOM: Arena capacity exceeded"
    end

    ptr = @memory + @offset
    @offset += size
    ptr
  end

  # Checkpointing for Stack Unwinding
  def save_mark : Int32
    @offset
  end

  # The O(1) "Free" - instant destruction of everything since the mark
  def restore_mark(mark : Int32)
    @offset = mark
  end
end

class Runtime
  getter stack : Arena # The Scratchpad (Dies per function)
  getter heap  : Arena # The Result Store (Dies per request)
  def initialize
    @stack = Arena.new(1024 * 1024) # 1MB
    @heap = Arena.new(1024 * 1024) # 1MB
  end
end

def memory_report(rt : Runtime, frame_mark : Int32, name : String)
  current_stack = rt.stack.offset
  current_heap = rt.heap.offset

  puts "--- Memory Report : #{name} ---"
  puts "Total Stack Arena Used:  #{current_stack} bytes"
  puts "Stack Used This Frame:   #{current_stack - frame_mark} bytes"
  puts "Total Heap Arena Used:   #{current_heap} bytes"
end


# ---------------------------------------------------------------
# 2. System Types
# ---------------------------------------------------------------
struct CheatString
  property size : Int64
  property data : Pointer(UInt8)
  def initialize(@size, @data); end

  # This is inefficient, but used only for printing
  def to_s
    String.new(@data, @size)
  end
end

def makeString(arena : Arena, raw_ptr : Pointer(UInt8), length : Int64) : CheatString
  data = arena.alloc(length.to_i32)
  data.copy_from(raw_ptr, length.to_i32)
  return CheatString.new(length, data)
end

# Bounds checking isn't required, as the compiler takes care of it.
# Here for v0.1 just because.
struct CheatArray(T)
  property size : Int64
  property data : Pointer(T)

  def initialize(@size, @data); end

  # O(1) Access - Compile to raw pointer arithmetic
  def [](index : Int64) : T
    if index < 0 || index >= @size
      raise "Index out of bounds"
    end
    (@data + index).value
  end

  # O(1) Write
  def []=(index : Int64, value : T)
    if index < 0 || index >= @size
      raise "Index out of bounds"
    end
    (@data + index).value = value
  end
end

def makeArray(arena : Arena, size : Int64, default_val : T) : CheatArray(T) forall T
  # 1. Alloc Data Block (size * sizeof(T))
  #    Note: Crystal handles the 'sizeof(T)' math automatically in Pointer arithmetic usually,
  #    but for 'alloc' (bytes), we need to be explicit.
  byte_size = size * sizeof(T)
  data_ptr = arena.alloc(byte_size.to_i32).as(Pointer(T))

  # 2. Initialize (Optional, but safe)
  size.times do |i|
    (data_ptr + i).value = default_val
  end

  # 3. Return Header
  return CheatArray(T).new(size, data_ptr)
end


struct CheatList(T)
  property allocator : Arena      # Where to alloc my items
  property size : Int64           # How many items currently used
  property capacity : Int64       # How many items we have room for
  property data : Pointer(T)      # The contiguous memory block

  def initialize(@allocator, @size, @capacity, @data); end

  # Standard Access (O(1))
  def [](index : Int64) : T
    if index < 0 || index >= @size
      raise "Index out of bounds"
    end
    (@data + index).value
  end

  def push(item : T)
    # 1. Check Capacity
    if @size >= @capacity
      # --- GROW REQUIRED ---
      old_cap = @capacity
      new_cap = (old_cap == 0) ? 4 : old_cap * 2

      # Alloc new block (Contiguous!)
      new_data = @allocator.alloc((new_cap * sizeof(T)).to_i32).as(Pointer(T))

      # Copy old data to new block (Memcpy is fast)
      if @size > 0
        new_data.copy_from(@data, @size)
      end

      # Update the List Struct to point to the new home
      @data = new_data
      @capacity = new_cap.to_i64

      # The old 'data' block is now "wasted" in the arena,
      # but will be cleaned up automatically when the function ends.
    end

    # 2. Write Value (O(1))
    (@data + @size).value = item
    @size += 1
  end
end

def makeList(arena : Arena, size : Int64, default_val : T) : CheatList(T) forall T
  # 1. Alloc Data Block (size * sizeof(T))
  #    Note: Crystal handles the 'sizeof(T)' math automatically in Pointer arithmetic usually,
  #    but for 'alloc' (bytes), we need to be explicit.
  byte_size = size * sizeof(T)
  data_ptr = arena.alloc(byte_size.to_i32).as(Pointer(T))

  # 2. Initialize (Optional, but safe)
  size.times do |i|
    (data_ptr + i).value = default_val
  end

  # 3. Return Header
  return CheatList(T).new(arena, 0, size, data_ptr)
end


# ---------------------------------------------------------------
# 2. Userland Types (The "User" Struct)
# ---------------------------------------------------------------
struct User
  property id : Int64
  property score : Int32
  property name : CheatString           # This is already a pointer

  def initialize(@id, @score, @name)
  end
end



# --- CALLEE FUNCTION ---
# 1. O(1) allocations
# 2. O(1) cleanup
# 3. Crystal LLVM takes care of SRVO for us auto-magically
def createUser(rt : Runtime) : Pointer(User)
  frame_mark = rt.stack.save_mark

  temp_score = 100
  calculation = 500

  # 2. Create a FixedArray on the STACK, fill it with garbage users
  #    They live only in this function, cheaply.

  defStr = CheatString.new(1, Pointer(UInt8).null)
  defUser = User.new(999, 0, defStr)
  arr = StaticArray(User, 5).new(defUser)                     # makeArray(rt.heap, 10_005, User)
                                                              # would never makeArray on Stack
  4.to_i64.times do |i|
    arr[i] = defUser
  end

  # 3. Create a DyanmicArray on the STACK, fill it with garbage users
  #    They live only in this function, cheaply.

  list = makeList(rt.stack, 1000, Pointer(User).null)                   # DON'T KNOW SIZE AT COMPILE TIME
  1_000.to_i64.times do |i|
    stack_user = rt.stack.alloc(sizeof(User)).as(Pointer(User))
    list.push(stack_user)
  end

  # [STEP 3] Alloc "Heap" Objects (Arena/Request Bound)
  heap_user = rt.heap.alloc(sizeof(User)).as(Pointer(User))

  # This has to be in `rt.heap` because this is effectively CoW
  heap_str = makeString(rt.heap, "Brian".to_unsafe, 5)           # "Brian".to_unsafe => stack_string

  heap_user.value = User.new(999, 0, heap_str)                   # This will die at the end of the function

  final_score = temp_score * 2

  # We write the RESULT into the pointer provided by the caller.
  # Note: 'result_ptr' lives BEFORE 'frame_mark', so it survives the reset.
  #
  # The user could pass in a STACK object to SRVO like so:
  # result_ptr.value = User.new(id: 1, score: final_score, name: cheat_str)

  # [STEP 5] O(1) Cleanup
  # We reset the arena pointer.
  # The 'StackFrame' is gone. The 'temp_user' is gone.
  # The 'result_ptr' remains because it was allocated by the caller.
  memory_report(rt, frame_mark, "createUser")
  rt.stack.restore_mark(frame_mark)

  return heap_user
end

