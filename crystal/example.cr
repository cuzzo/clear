require "./runtime"

# --- CALLER FUNCTION ---
def handleRequest
  runtime = Runtime.new() # 1MB stack, 1MB request HEAP
  heap_mark = runtime.heap.save_mark

  puts "Start Offset: #{runtime.heap.offset}"

  # PREPARE FOR CALL:
  # We need to allocate space for the return value *before* calling.
  # This is "Destination Passing Style"
  #result_dest = arena.alloc(sizeof(User)).as(Pointer(User))

  # CALL THE FUNCTION
  user_ptr = createUser(runtime) # , result_dest)
  puts "USER NAME: #{user_ptr.value.name.to_s}"

  # USAGE
  # The result is valid, but all internal junk from create_user is gone.
  #puts "User ID: #{result_dest.value.id}"       # 1
  #puts "User Score: #{result_dest.value.score}" # 200

  memory_report(runtime, heap_mark, "handleRequest")
  runtime.heap.restore_mark(heap_mark)
end


# Run it
handleRequest

