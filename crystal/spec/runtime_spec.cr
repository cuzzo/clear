require "spec"
require "../runtime"

describe Arena do
  it "allocates memory and advances the offset" do
    arena = Arena.new(1024)
    initial_offset = arena.offset

    # Alloc 10 bytes
    ptr = arena.alloc(10)

    # Check pointer is valid
    ptr.should_not be_nil

    # Check offset moved by 10
    arena.offset.should eq(initial_offset + 10)
  end

  it "raises an error on Stack Overflow (OOM)" do
    arena = Arena.new(10) # Small arena

    expect_raises(Exception, "Arena capacity exceeded") do
      arena.alloc(20) # Too big
    end
  end

  it "resets memory state using marks (O(1) Free)" do
    arena = Arena.new(1024)

    # 1. Mark start
    mark = arena.save_mark

    # 2. Alloc garbage
    arena.alloc(100)
    arena.offset.should eq(100)

    # 3. Restore mark
    arena.restore_mark(mark)

    # 4. Offset should be back to 0
    arena.offset.should eq(0)
  end
end

describe "Integration: Destination Passing" do
  it "allows the callee to write to the caller's memory" do
    arena = Arena.new(1024)

    # 1. CALLER: Alloc space for result
    result_ptr = arena.alloc(sizeof(User)).as(Pointer(User))

    # 2. CALLEE: Run the logic (simulated)
    # We simulate a function frame here
    frame_mark = arena.save_mark

    # Allocate internal garbage
    temp = arena.alloc(sizeof(Int32))

    # Write to the CALLER'S pointer
    result_ptr.value = User.new(id: 42, score: 9000)

    # Cleanup Callee
    arena.restore_mark(frame_mark)

    # 3. VERIFY
    # The internal temp alloc should be "gone" (offset reset)
    # But the result_ptr should still hold the data
    arena.offset.should eq(sizeof(User)) # Only the result exists
    result_ptr.value.id.should eq(42)
    result_ptr.value.score.should eq(9000)
  end
end

