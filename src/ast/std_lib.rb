STRING_TYPE = :String
HEAP_STRING_TYPE = :String

STD_LIB = {
  # Method Name => { args: [Type...], return: Type, zig: Pattern }

  # NOT SUPPORTED YET IN TRANSPILATION
  "map" => {
    args: :Varargs,
    return: :infer_map_return_type,
    zig: :macro_map
  },

  "append" => {
    args: [:"Any[]", { type: :Any, takes: true }],
    return: :Void,
    zig: "try {0}.append({alloc}, {1})",
    bc: true,
    narrows_collection: true,  # narrows Any[] element type from arg 1
    allocates: true,
    alloc: :receiver_storage,
    mutates_receiver: true,
  },

  "insert" => {
    args: [:"Any[]", { type: :Any, takes: true }],
    return: :Void,
    zig: "try {0}.append({alloc}, {1})",
    bc: true,
    narrows_collection: true,
    allocates: true,
    alloc: :receiver_storage,
    mutates_receiver: true,
  },

  "push" => {
    args: [:"Any[]", { type: :Any, takes: true }],
    return: :Void,
    zig: "try {0}.append({alloc}, {1})",
    bc: true,
    narrows_collection: true,
    allocates: true,
    alloc: :receiver_storage,
    mutates_receiver: true,
  },

  # Pre-allocate capacity without inserting elements. No-op if capacity already sufficient.
  # Avoids doubling waste when the final size is known before filling a loop.
  #
  # TODO: eliminate reserve() entirely. T[N]@list already calls initCapacity(alloc, N) for
  # literal N (mir_lowering.rb). Extend that to accept runtime expressions — T[n]@list where
  # n is a variable — so the declaration itself pre-allocates without a separate method call.
  # The capacity annotation today only accepts integer literals (type.rb: match[2].to_i).
  "reserve" => {
    args: [:"Any[]", :Int64],
    return: :Void,
    zig: "try {0}.ensureTotalCapacity({alloc}, @intCast({1}))",
    bc: true,
    allocates: true,
    alloc: :receiver_storage,
    mutates_receiver: true,
  },

  "remove" => {
    args: [:"Any[]", :Int64],
    return: :infer_element_type,
    return_alloc: :heap,  # removed element is now owned by caller
    zig: "{0}.orderedRemove(@intCast({1}))",
    bc: true,
    mutates_receiver: true,
    borrows: :all,  # borrows list + index; returns owned element
  },

  # pop() — remove and return the last element, or null if empty.
  "pop" => {
    args: [:"Any[]"],
    return: :infer_optional_element_type,
    zig: "{0}.pop()",
    bc: true,
    mutates_receiver: true,
    borrows: :all,
  },


  # 1. String.length()
  "length" => [
    { args: [STRING_TYPE], return: :Int64, zig: "CheatLib.len({0})", bc: true, borrows: :all },
    { args: [:"Any[]"], return: :Int64, zig: "CheatLib.len({0})", bc: true, borrows: :all }
  ],

  # 2. String.substr(start, len)
  # String@raw: O(1) zero-copy sub-slice, no allocation. Returns String@raw.
  # String:     Allocates a copy on the frame arena.
  "substr" => [
    { args: [{type: STRING_TYPE, sync: :raw}, :Int64, :Int64],
      return: {type: STRING_TYPE, sync: :raw},
      zig: "CheatLib.substrRaw({0}, {1}, {2})",
      bc: true },
    { args: [STRING_TYPE, :Int64, :Int64],
      return: STRING_TYPE, return_alloc: :frame,
      zig: "try CheatLib.substr({alloc}, {0}, {1}, {2})",
      bc: true,
      allocates: true, alloc: :node_storage },
  ],

  # 3. String Equality
  "eql?" => {
    args: [STRING_TYPE, STRING_TYPE],
    return: :Bool,
    zig: "CheatLib.eql({0}, {1})",
    bc: true,
    borrows: :all,
  },

  # toInt() (Overloaded)
  "toInt" => [
    { args: [STRING_TYPE], return: :Int64, zig: "try CheatLib.toInt({0})", bc: true, can_fail: true, borrows: :all },
    { args: [:Float64], return: :Int64, zig: "@intFromFloat({0})", bc: true },
    { args: [:Int64], return: :Int64, zig: "{0}", bc: true }
  ],

  # toString() (Overloaded)
  "toString" => [
    { args: [:Int64],   return: STRING_TYPE, return_alloc: :frame, zig: "try CheatLib.intToString({alloc}, {0})", bc: true, allocates: true, alloc: :node_storage },
    { args: [:Float64], return: STRING_TYPE, return_alloc: :frame, zig: "try CheatLib.intToString({alloc}, @as(i64, @intFromFloat({0})))", bc: true, allocates: true, alloc: :node_storage },
    { args: [STRING_TYPE], return: STRING_TYPE, return_alloc: :frame, zig: "{0}", bc: true }
  ],

  # toFloat() (Overloaded)
  "toFloat" => [
    { args: [STRING_TYPE], return: :Float64, zig: "try std.fmt.parseFloat(f64, {0})", bc: true, can_fail: true, borrows: :all },
    { args: [:Int64],      return: :Float64, zig: "@as(f64, @floatFromInt({0}))", bc: true },
    { args: [:Float64],    return: :Float64, zig: "{0}", bc: true }
  ],

  "toList" => [
    {
      args: [:"Any[]"],
      return: lambda { |args, _node|
        recv_t = Type.new(args[0])
        elem_t = if recv_t.dynamic_stream? || recv_t.promise_list?
          recv_t.tense_type.element_type
        elsif recv_t.bounded_stream?
          recv_t.stream_element_type
        elsif recv_t.inf_stream?
          recv_t.inf_stream_element_type
        elsif recv_t.open_stream?
          recv_t.open_stream_element_type
        else
          recv_t.element_type
        end
        Type.new(:"#{elem_t.resolved}[]", collection: :list)
      },
      zig: "try ({0}).toList(rt.heapAlloc())",
      allocates: true,
      alloc: :heap,
      is_method: true,
    }
  ],

  # charAt(string, index) → String
  # String@raw: O(1) byte indexing, no allocation, no UTF-8 iteration.
  # String:     O(n) UTF-8 codepoint indexing, allocates result.
  "charAt" => [
    { args: [{type: STRING_TYPE, sync: :raw}, :Int64],
      return: {type: STRING_TYPE, sync: :raw},
      zig: "CheatLib.charAt({0}, {1})",
      bc: true },
    { args: [STRING_TYPE, :Int64],
      return: STRING_TYPE, return_alloc: :frame,
      zig: "try CheatLib.charAtCodepoint({alloc}, {0}, {1})",
      bc: true,
      allocates: true, alloc: :node_storage },
  ],

  # codepointCount(string) → Int64 — number of Unicode codepoints (O(n))
  "codepointCount" => {
    args: [STRING_TYPE],
    return: :Int64,
    zig: "CheatLib.codepointCount({0})",
    bc: true,
    borrows: :all,
  },

  # bytes(string) → Int64 — byte length (O(1), explicit intent)
  "bytes" => {
    args: [STRING_TYPE],
    return: :Int64,
    zig: "CheatLib.len({0})",
    bc: true,
    borrows: :all,
  },

  # toNumber(string) → ?Float64 — safe parse, returns null on failure
  "toNumber" => {
    args: [STRING_TYPE],
    return: :"?Float64",
    zig: "(std.fmt.parseFloat(f64, {0}) catch null)",
    bc: true,
    borrows: :all,
  },

  # 5. print()
  "print" => {
    args: :Varargs,      # Special marker: Accept any number of arguments
    return: :Void,
    zig: :macro_print    # Special marker: Dispatch to 'macro_print' method
  },

  # 4. Read File
  "readFile" => {
    args: [STRING_TYPE],
    return: STRING_TYPE, return_alloc: :frame,
    zig: "try CheatLib.readFile({alloc}, {0})",
    bc: true,
    allocates: true,
    alloc: :frame,
  },

  # 5. Write File
  "writeFile" => {
    args: [STRING_TYPE, STRING_TYPE],     # Path, Content
    return: :Void,
    zig: "try CheatLib.writeFile({0}, {1})",
    bc: true,
    can_fail: true,
    borrows: :all,
  },

  # 6. Read Line from stdin
  "readLine!" => {
    args: [],
    return: STRING_TYPE,
    return_alloc: :frame,
    zig: "try CheatLib.readLine({alloc})",
    allocates: true,
    alloc: :frame,
    can_fail: true,
  },

  # 6b. Read Line with prompt, editing, and history
  "readLinePrompt!" => {
    args: [STRING_TYPE],
    return: STRING_TYPE,
    return_alloc: :frame,
    zig: "try CheatLib.readLinePrompt({alloc}, {0})",
    allocates: true,
    alloc: :frame,
    can_fail: true,
  },

  # 7. Split (String -> String[])
  "split" => {
    args: [STRING_TYPE, STRING_TYPE],
    return: :"String[]",
    zig: "try CheatLib.split({alloc}, {0}, {1})",
    bc: true,
    allocates: true,
    alloc: :node_storage,
  },

  # 7. Join (String[] -> String)
  "join" => {
    args: [:"String[]", STRING_TYPE],
    return: STRING_TYPE, return_alloc: :frame,
    zig: "try CheatLib.join({alloc}, {0}, {1})",
    bc: true,
    allocates: true,
    alloc: :node_storage,
  },

  "trim" => {
    args: [STRING_TYPE],
    return: STRING_TYPE,
    lifetime: "self",  # returns a sub-slice of the input; no allocation
    zig: "std.mem.trim(u8, {0}, &std.ascii.whitespace)",
    bc: true,
    borrows: :all,
  },

  # startsWith("file.txt", "file") -> true
  "startsWith?" => {
    args: [STRING_TYPE, STRING_TYPE],
    return: :Bool,
    zig: "std.mem.startsWith(u8, {0}, {1})",
    bc: true,
    borrows: :all,
  },

  # endsWith?("image.png", ".png") -> true
  "endsWith?" => {
    args: [STRING_TYPE, STRING_TYPE],
    return: :Bool,
    zig: "std.mem.endsWith(u8, {0}, {1})",
    bc: true,
    borrows: :all,
  },

  # indexOf("hello world", "world") -> 6  (or nil if not found)
  "indexOf" => {
    args: [STRING_TYPE, STRING_TYPE],
    return: :"?Int64",
    zig: "CheatLib.indexOf({0}, {1})",
    bc: true,
    borrows: :all,
  },

  # replace("hello world", "world", "CLEAR") -> "hello CLEAR"
  "replace" => {
    args: [STRING_TYPE, STRING_TYPE, STRING_TYPE],
    return: STRING_TYPE, return_alloc: :frame,
    zig: "try CheatLib.stringReplace({alloc}, {0}, {1}, {2})",
    bc: true,
    allocates: true,
    alloc: :node_storage,
  },

  # lowercase("Hello") -> "hello"
  "lowercase" => {
    args: [STRING_TYPE],
    return: STRING_TYPE, return_alloc: :frame,
    zig: "try CheatLib.stringLowercase({alloc}, {0})",
    bc: true,
    allocates: true,
    alloc: :node_storage,
  },

  # uppercase("Hello") -> "HELLO"
  "uppercase" => {
    args: [STRING_TYPE],
    return: STRING_TYPE, return_alloc: :frame,
    zig: "try CheatLib.stringUppercase({alloc}, {0})",
    bc: true,
    allocates: true,
    alloc: :node_storage,
  },

  # contains?("hello", "ll") -> true
  # contains?(arr, item)     -> true/false (linear search, @list or T[])
  "contains?" => [
    { args: [STRING_TYPE, STRING_TYPE],
      return: :Bool,
      zig: "(std.mem.indexOf(u8, {0}, {1}) != null)",
      bc: true,
      borrows: :all },
    { args: [:"Any[]", :Any],
      return: :Bool,
      zig: "CheatLib.sliceContains({0}, {1})",
      bc: true,
      borrows: :all },
  ],

  # max(a, b) -> larger value
  "max" => [
    { args: [:Int64, :Int64], return: :Int64, zig: "@max({0}, {1})", bc: true },
    { args: [:Float64, :Float64], return: :Float64, zig: "@max({0}, {1})", bc: true },
  ],

  # min(a, b) -> smaller value
  "min" => [
    { args: [:Int64, :Int64], return: :Int64, zig: "@min({0}, {1})", bc: true },
    { args: [:Float64, :Float64], return: :Float64, zig: "@min({0}, {1})", bc: true },
  ],

  # abs(x) -> absolute value
  "abs" => [
    { args: [:Float64], return: :Float64, zig: "@abs({0})", bc: true },
    { args: [:Int64], return: :Int64, zig: "@intCast(@abs({0}))", bc: true },
  ],

  # log(x) -> natural logarithm
  "log" => {
    args: [:Float64],
    return: :Float64,
    zig: "@log({0})",
    bc: true,
  },

  # exp(x) -> e^x
  "exp" => {
    args: [:Float64],
    return: :Float64,
    zig: "@exp({0})",
    bc: true,
  },

  # floor(x) -> largest integer <= x (as Float64)
  "floor" => {
    args: [:Float64],
    return: :Float64,
    zig: "@floor({0})",
    bc: true,
  },

  "shell" => {
    args: [STRING_TYPE],
    return: STRING_TYPE, return_alloc: :frame,
    zig: "try CheatLib.shell({alloc}, {0})",
    bc: true,
    allocates: true,
    alloc: :node_storage,
  },

  # Read all bytes from an open File resource into a heap-allocated String.
  # Usage: contents = fileReadAll(f)
  "fileReadAll" => {
    args: [:File],
    return: STRING_TYPE, return_alloc: :heap,
    zig: "try CheatLib.fileReadAll({alloc}, {0})",
    bc: true, bc_op: :file_read_all,
    allocates: true,
    alloc: :heap,
  },

  # Write a String to an open writable File resource (created via File::create).
  # Usage: fileWrite(f, "hello")
  "fileWrite" => {
    args: [:File, STRING_TYPE],
    return: :Void,
    zig: "try CheatLib.fileWrite({0}, {1})",
    bc: true, bc_op: :file_write,
    can_fail: true,
    borrows: :all,
  },

  # List all files in a directory. Returns a list of filenames (not full paths).
  # Usage: files = listDir("/some/dir")
  "listDir" => {
    args: [STRING_TYPE],
    return: :"String[]",
    zig: "try CheatLib.listDir({alloc}, {0})",
    allocates: true,
    alloc: :node_storage,
  },

  # List ALL entries (files + directories) with type prefix ("f:" or "d:").
  # Usage: entries = listAll("/some/dir")
  "listAll" => {
    args: [STRING_TYPE],
    return: :"String[]",
    zig: "try CheatLib.listAll({alloc}, {0})",
    allocates: true,
    alloc: :node_storage,
  },

  # Get file size in bytes. Returns -1 on error.
  # Usage: size = fileSize("/some/file.txt")
  "fileSize" => {
    args: [STRING_TYPE],
    return: :Int64,
    zig: "CheatLib.fileSize({0})",
    bc: true,
    borrows: :all,
  },

  # Count non-overlapping occurrences of needle in haystack.
  # Usage: n = countOccurrences(content, "the")
  "countOccurrences" => {
    args: [STRING_TYPE, STRING_TYPE],
    return: :Int64,
    zig: "CheatLib.countOccurrences({0}, {1})",
    bc: true,
    borrows: :all,
  },

  # -------------------------------------------------------------------------
  # TCP Socket — Phase 3
  # -------------------------------------------------------------------------

  # Accept one incoming TCP connection on a listening server socket.
  # Yields the current fiber (via epoll) until a client connects.
  # Returns a TCPClient resource; auto-closes via RAII defer.
  # Usage: client = accept(server)
  "accept" => {
    args: [:TCPServer],
    return: :TCPClient,
    zig: "try CheatLib.socketAccept({0})",
    can_fail: true,
    allocates: true,  # produces owned resource (TCPClient)
    borrows: :all,
  },

  # Read up to 4096 bytes from a connected TCP client into a heap String.
  # Yields the fiber if no data is ready (epoll-backed).
  # Usage: data = tcpRead(client)
  "tcpRead" => {
    args: [:TCPClient],
    return: STRING_TYPE, return_alloc: :frame,
    zig: "try CheatLib.socketRead({alloc}, {0})",
    allocates: true,
    alloc: :node_storage,
  },

  # Write a String to a connected TCP client.
  # Yields the fiber if the send buffer is full (epoll-backed).
  # Usage: tcpWrite(client, "hello")
  "tcpWrite" => {
    args: [:TCPClient, STRING_TYPE],
    return: :Void,
    zig: "try CheatLib.socketWriteVoid({0}, {1})",
    can_fail: true,
    borrows: :all,
  },

  # -------------------------------------------------------------------------
  # Clock & Timing
  # -------------------------------------------------------------------------

  # Wall clock milliseconds since Unix epoch.
  # Usage: start = timestampMs(); ... elapsed = timestampMs() - start;
  "timestampMs" => {
    args: [],
    return: :Int64,
    zig: "CheatLib.timestampMs()",
    bc: true,
  },

  # Frame arena peak bytes (debug/safe builds only; returns 0 in release).
  # Usage: peak = framePeakBytes(); ASSERT peak < 1000000;
  "framePeakBytes" => {
    args: [],
    return: :Int64,
    zig: "@as(i64, @intCast(rt.framePeakBytes()))",
    bc: true,
  },

  # Number of scheduler threads (main + workers). Matches CLEAR_THREADS env var.
  # Usage: workers = threadCount();
  "threadCount" => {
    args: [],
    return: :Int64,
    zig: "CheatLib.threadCount()",
    bc: true,
  },

  # Peak resident set size (VmHWM) in KB — high-water mark of physical memory.
  # Cross-language comparable (reads /proc/self/status).
  "peakMemoryKb" => {
    args: [],
    return: :Int64,
    zig: "CheatLib.peakMemoryKb()",
    bc: true,
  },

  # Current resident set size (VmRSS) in KB — physical memory in use right now.
  "currentMemoryKb" => {
    args: [],
    return: :Int64,
    zig: "CheatLib.currentMemoryKb()",
    bc: true,
  },

  # Sleep the current fiber for N milliseconds. Cooperative — other fibers run.
  # Usage: sleep(100);
  "sleep" => {
    args: [:Int64],
    return: :Void,
    zig: "rt.sleep(@intCast(@as(u64, @bitCast({0}))))",
    bc: true,
    needs_rt: true,
  },

  # -------------------------------------------------------------------------
  # Random
  # -------------------------------------------------------------------------

  # Random float in [0.0, 1.0). Cryptographically secure.
  # Usage: val = random();
  "random" => {
    args: [],
    return: :Float64,
    zig: "CheatLib.random()",
    bc: true,
  },

  # Random integer in [0, max). Cryptographically secure.
  # Usage: idx = randomInt(100);
  "randomInt" => {
    args: [:Int64],
    return: :Int64,
    zig: "CheatLib.randomInt({0})",
    bc: true,
  },
}

# ============================================================================
# Method Registry — type-specific method definitions for Pool and HashMap
# ============================================================================
# Each entry: { arity: N, validate: lambda, return_type: lambda, tag: symbol }
#   arity:       expected arg count (-1 = any)
#   validate:    lambda(node, args, obj_type, error_fn) — type-check args
#   return_type: lambda(obj_type) — compute return type from receiver type
#   tag:         symbol to set on the node (pool_method / map_method)

POOL_METHODS = {
  "insert" => {
    arity: 1, tag: :pool_method, allocates: true,
    bc: true,
    takes_args: [0],  # Pool.insert takes ownership of the value
    zig: "try {0}.insert({alloc}, {1})",
    alloc: :heap,
    args: [:"Any[]", { type: :Any, takes: true }],
    validate: ->(node, args, obj_type, error_fn) {
      elem = obj_type.element_type
      arg_type = args[0].resolved_type
      unless arg_type == :Any || arg_type == elem.resolved || Type.new(elem.resolved).accepts?(Type.new(arg_type))
        error_fn.call(node, "Pool.insert: argument type #{arg_type} does not match pool element type #{elem.resolved}")
      end
    },
    return_type: ->(obj_type) { Type.new(:"Id<#{obj_type.element_type.resolved}>") },
  },
  "get" => {
    arity: 1, tag: :pool_method,
    bc: true,
    zig: "{0}.get({1})",
    return_type: ->(obj_type) { Type.new(:"?#{obj_type.element_type.resolved}") },
    borrows: :all,  # returns borrowed pointer into pool storage
  },
  "remove" => {
    arity: 1, tag: :pool_method,
    bc: true,
    zig: "{0}.remove({1})",
    mutates_receiver: true,
    return_type: ->(_) { :Void },
    borrows: :all,  # pool frees the slot internally
  },
  "length" => {
    arity: 0, tag: :pool_method,
    bc: true,
    zig: "{0}.length()",
    return_type: ->(_) { Type.new(:Int64) },
    borrows: :all,
  },
  "contains?" => {
    arity: 1, tag: :pool_method,
    bc: true,
    zig: "({0}.get({1}) != null)",
    return_type: ->(_) { :Bool },
    borrows: :all,
  },
}.freeze

SET_METHODS = {
  "insert" => {
    arity: 1, tag: :set_method, allocates: true,
    zig: "try {0}.insert({alloc}, {1})",
    bc: true,
    alloc: :heap,
    mutates_receiver: true,
    borrows: :all,  # set dupes strings internally; caller retains ownership
    args: [:"Any[]", :Any],
    validate: ->(node, args, obj_type, error_fn) {
      elem = obj_type.element_type
      arg_type = args[0].resolved_type
      unless arg_type == :Any || arg_type == elem.resolved || Type.new(elem.resolved).accepts?(Type.new(arg_type))
        error_fn.call(node, "Set.insert: argument type #{arg_type} does not match set element type #{elem.resolved}")
      end
    },
    return_type: ->(_) { :Void },
  },
  "contains?" => {
    arity: 1, tag: :set_method,
    zig: "{0}.contains({1})",
    bc: true,
    return_type: ->(_) { :Bool },
    borrows: :all,
  },
  "remove" => {
    arity: 1, tag: :set_method,
    zig: "{0}.remove({alloc}, {1})",
    bc: true,
    alloc: :heap,
    mutates_receiver: true,
    return_type: ->(_) { :Void },
    borrows: :all,  # set frees the element internally
  },
  "length" => {
    arity: 0, tag: :set_method,
    zig: "{0}.length()",
    bc: true,
    return_type: ->(_) { Type.new(:Int64) },
    borrows: :all,
  },
}.freeze

MAP_METHODS = {
  "put" => {
    arity: 2, tag: :map_method, allocates: true,
    mutates_receiver: true,
    bc: true,
    takes_args: [1],  # value (arg 1) is TAKES
    zig: "try {0}.put({alloc}, {alloc}, {1}, {2})",
    alloc: :heap,
    args: [:"String{}", :String, { type: :Any, takes: true }],
    numeric_zig: "try CheatLib.numericMapPut({key_zig}, {val_zig}, {alloc}, &{0}, {1}, {2})",
    validate: ->(node, args, obj_type, error_fn) {
      key_type = Type.new(args[0].resolved_type)
      if obj_type.numeric_map?
        error_fn.call(node, "HashMap.put: key must be a numeric type, got #{args[0].resolved_type}") unless key_type.numeric?
      else
        error_fn.call(node, "HashMap.put: key must be a String, got #{args[0].resolved_type}") unless key_type.string?
      end
    },
    return_type: ->(_) { :Void },
  },
  "delete" => {
    arity: 1, tag: :map_method,
    bc: true,
    zig: "{0}.remove({alloc}, {1})",
    alloc: :heap,
    mutates_receiver: true,
    numeric_zig: "CheatLib.numericMapDelete({key_zig}, {val_zig}, {alloc}, &{0}, {1})",
    validate: ->(node, args, obj_type, error_fn) {
      arg_type = Type.new(args[0].resolved_type)
      if obj_type.numeric_map?
        error_fn.call(node, "HashMap.delete: key must be a numeric type, got #{args[0].resolved_type}") unless arg_type.numeric?
      else
        error_fn.call(node, "HashMap.delete: key must be a String, got #{args[0].resolved_type}") unless arg_type.string?
      end
    },
    return_type: ->(_) { :Void },
    borrows: :all,  # map frees key+value internally
  },
  "contains?" => {
    arity: 1, tag: :map_method,
    zig: "{0}.contains({1})",
    bc: true,
    numeric_zig: "CheatLib.numericMapContains({key_zig}, {val_zig}, {0}, {1})",
    validate: ->(node, args, obj_type, error_fn) {
      arg_type = Type.new(args[0].resolved_type)
      if obj_type.numeric_map?
        error_fn.call(node, "HashMap.contains?: key must be a numeric type, got #{args[0].resolved_type}") unless arg_type.numeric?
      else
        error_fn.call(node, "HashMap.contains?: key must be a String, got #{args[0].resolved_type}") unless arg_type.string?
      end
    },
    return_type: ->(_) { :Bool },
    borrows: :all,
  },
  "count" => {
    arity: 0, tag: :map_method,
    zig: "{0}.count()",
    bc: true,
    numeric_zig: "CheatLib.numericMapCount({key_zig}, {val_zig}, {0})",
    return_type: ->(_) { Type.new(:Int64) },
    borrows: :all,
  },
  "length" => {
    arity: 0, tag: :map_method,
    zig: "{0}.count()",
    bc: true,
    numeric_zig: "CheatLib.numericMapCount({key_zig}, {val_zig}, {0})",
    return_type: ->(_) { Type.new(:Int64) },
    borrows: :all,
  },
  "keys" => {
    arity: 0, tag: :map_method, allocates: true,
    bc: true,
    zig: "try CheatLib.mapKeys({val_zig}, {alloc}, {0}.inner)",
    alloc: :frame,
    sharded_zig: "try {0}.keys({alloc})",
    sharded_alloc: :heap,
    numeric_zig: "try CheatLib.numericMapKeys({key_zig}, {val_zig}, {alloc}, {0})",
    return_type: ->(_) { :"String[]" },
    borrows: :all,  # borrows map; returns new owned list
  },
  "values" => {
    arity: 0, tag: :map_method, allocates: true,
    bc: true,
    zig: "try CheatLib.mapValues({val_zig}, {alloc}, {0}.inner)",
    alloc: :frame,
    sharded_zig: "try {0}.values({alloc})",
    sharded_alloc: :heap,
    numeric_zig: "try CheatLib.numericMapValues({key_zig}, {val_zig}, {alloc}, {0})",
    return_type: ->(obj_type) { :"#{obj_type.value_type.resolved}[]" },
    borrows: :all,  # borrows map; returns new owned list
  },
}.freeze

# ============================================================================
# Index Operations Registry — container[key] get/set semantics
# ============================================================================
# Keyed by container kind (:string_map, :numeric_map, :array, :pool, :set_collection).
# Each entry has :get and/or :set with:
#   zig:               Zig pattern string ({target}, {index}, {value}, {alloc}, {key_alloc}, etc.)
#   return_type:       lambda(container_type) -> return type for get
#   container_borrow:  true if get returns a borrowed view (no cleanup)
#   takes_value:       true if set takes ownership of the value
#   allocates:         true if set requires an allocator
#
# Allocator symbols for :set entries:
#   :heap              always rt.heapAlloc()
#   :frame             always rt.frameAlloc()
#   :receiver_storage  heap if escaped/provenance/sharded/striped, frame otherwise
#
# Value transforms (ordered, applied to {value} before substitution):
#   :dupe_string_literal   heap-dupe string literals (rodata can't be freed)
#   :dupe_borrowed_union   deep-copy borrowed non-Copy union values
#   :container_promote     promote frame-allocated sub-collections to heap

INDEX_OPS = {
  string_map: {
    get: {
      zig: "{target}.get({index})",
      shard_direct_zig: "{target}.getDirect({shard_idx}, {shard_key})",
      return_type: ->(ct) { :"?#{ct.value_type.resolved}" },
      container_borrow: true,
      bc: true, bc_op: :map_get,
    },
    set: {
      zig: "try {target}.put({key_alloc}, {val_alloc}, {index}, {value})",
      takes_value: true,
      allocates: true,
      key_alloc: :heap,
      val_alloc: :receiver_storage,
      value_transforms: [:dupe_string_literal, :dupe_borrowed_union, :container_promote],
      shard_direct_zig: "try {target}.putDirect({shard_idx}, {shard_alloc}, {shard_key}, {value})",
      shard_direct_value_transforms: [],  # putDirect dupes key+value internally; no caller-side transforms
      shard_alloc: :heap,
      bc: true, bc_op: :map_set,
    },
  },
  numeric_map: {
    get: {
      zig: "CheatLib.numericMapGet({key_zig}, {val_zig}, {target}, {index})",
      sharded_zig: "{target}.get({index})",
      shard_direct_zig: "{target}.getDirect({shard_idx}, {shard_key})",
      return_type: ->(ct) { :"?#{ct.value_type.resolved}" },
      container_borrow: true,
      bc: true, bc_op: :map_get,
    },
    set: {
      zig: "try CheatLib.numericMapPut({key_zig}, {val_zig}, {alloc}, &{target}, {index}, {value})",
      takes_value: true,
      allocates: true,
      alloc: :receiver_storage,
      value_transforms: [],
      sharded_zig: "try {target}.put({alloc}, {alloc}, {index}, {value})",
      shard_direct_zig: "try {target}.putDirect({shard_idx}, {shard_alloc}, {shard_key}, {value})",
      shard_direct_value_transforms: [],
      shard_alloc: :heap,
      bc: true, bc_op: :map_set,
    },
  },
  array: {
    get: {
      zig: "CheatLib.getAt({target}, {index})",
      return_type: ->(ct) { ct.element_type },
      container_borrow: true,
    },
    set: {
      zig: "CheatLib.setAt({target}, {index}, {value})",
      takes_value: false,
      value_transforms: [],
    },
  },
  list: {
    get: {
      zig: "CheatLib.getAt({target}, {index})",
      return_type: ->(ct) { ct.element_type },
      container_borrow: true,
    },
    set: {
      zig: "CheatLib.setAt({target}, {index}, {value})",
      takes_value: false,
      value_transforms: [],
    },
  },
  pool: {
    get: {
      zig: "{target}.get({index})",
      return_type: ->(ct) { :"?#{ct.element_type.resolved}" },
      container_borrow: false,
    },
    set: {
      zig: "try {target}.insert({alloc}, {value})",
      takes_value: true,
      allocates: true,
      alloc: :heap,
      value_transforms: [:container_promote],
    },
  },
  set_collection: {
    get: {
      zig: "if ({target}.contains({index})) {index} else null",
      return_type: ->(ct) { Type.new(:"?#{ct.element_type.resolved}") },
      container_borrow: true,
    },
    set: {
      zig: "try {target}.insert({alloc}, {value})",
      takes_value: true,
      allocates: true,
      alloc: :heap,
      value_transforms: [],
    },
  },
  string_raw: {
    get: {
      # O(1) byte access on String@raw. No allocation.
      builtin: :charAt,
      return_type: ->(_t) { Type.new(:String, sync: :raw) },
      container_borrow: true,
    },
    # No :set — strings are immutable.
  },
  string_symbol: {
    get: {
      # Byte indexing on String@symbol — same as @raw, returns @symbol slice.
      builtin: :charAt,
      return_type: ->(_t) { Type.new(:String, sync: :symbol) },
      container_borrow: true,
    },
    # No :set — symbols are immutable.
  },
}.freeze

# ============================================================================
# Collection Method Dispatch Configuration
#
# Maps Type#dispatch_key → { registry, tag, label }.
# `resolve_collection_method` uses this instead of an if/elsif chain so that
# new collection types only need a dispatch_key entry + this table entry.
# ============================================================================
COLLECTION_METHOD_CONFIGS = {
  pool:           { registry: POOL_METHODS, tag: :pool_method,
                    label: ->(t) { "Pool<#{t.element_type.resolved}>" } },
  set_collection: { registry: SET_METHODS,  tag: :set_method,
                    label: ->(t) { "Set<#{t.element_type.resolved}>" } },
  string_map:     { registry: MAP_METHODS,  tag: :map_method,
                    label: ->(t) { "HashMap<#{t.value_type.resolved}>" } },
  numeric_map:    { registry: MAP_METHODS,  tag: :map_method,
                    label: ->(t) { "HashMap<#{t.value_type.resolved}>" } },
}.freeze

# ============================================================================
# Builtin Operations Registry -- CheatLib runtime functions used by operators,
# indexing, assertions, and deep copy. NOT user-callable -- emitted by the
# lowering for operators/expressions. Each entry gets attached as stdlib_def
# on the MIR::InlineZig node so the MIR checker can verify ownership.
# ============================================================================
# Pattern placeholders: {0}, {1}, {2} = positional args
# All entries implicitly borrow their args unless noted otherwise.

BUILTIN_OPS = {
  # --- String comparison ---
  eql:       { zig: "CheatLib.eql({0}, {1})", bc: true, borrows: :all },
  strcmp:    { zig: "CheatLib.strcmp({0}, {1})", bc: true, borrows: :all },
  strEql:    { zig: "CheatLib.strEql({0}, {1})", bc: true, borrows: :all },
  # O(1) pointer+length comparison for String@symbol. Valid because the compiler
  # deduplicates identical string literals within a single compilation unit.
  symbolEql: { zig: "({0}.ptr == {1}.ptr and {0}.len == {1}.len)", bc: true, borrows: :all },

  # --- String indexing ---
  charAt: { zig: "CheatLib.charAt({0}, {1})", bc: true, borrows: :all },

  # --- Collection indexing (fallback for non-registry paths) ---
  getAt: { zig: "CheatLib.getAt({0}, {1})", bc: true, borrows: :all },
  setAt: { zig: "CheatLib.setAt({0}, {1}, {2})", bc: true, borrows: :all },
  numericMapGet: { zig: "CheatLib.numericMapGet({0}, {1}, {2}, {3})", bc: true, borrows: :all },

  # --- Checked integer arithmetic ---
  intAdd: { zig: "CheatLib.intAdd({0}, {1})", bc: true, borrows: :all },
  intSub: { zig: "CheatLib.intSub({0}, {1})", bc: true, borrows: :all },
  intMul: { zig: "CheatLib.intMul({0}, {1})", bc: true, borrows: :all },
  # Integer division / modulo: @divTrunc and @mod are Zig builtins on the
  # :zig side; on :bc side bc_emitter maps them to DIV_I64 / MOD_I64 opcodes.
  intDiv: { zig: "@divTrunc({0}, {1})", bc: true, borrows: :all },
  intMod: { zig: "@mod({0}, {1})", bc: true, borrows: :all },

  # --- Wrapping arithmetic ---
  wrapAdd: { zig: "CheatLib.wrapAdd({0}, {1})", bc: true, borrows: :all },
  wrapSub: { zig: "CheatLib.wrapSub({0}, {1})", bc: true, borrows: :all },
  wrapMul: { zig: "CheatLib.wrapMul({0}, {1})", bc: true, borrows: :all },

  # --- Overflow-checked arithmetic ---
  checkAdd: { zig: "CheatLib.checkAdd({0}, {1})", bc: true, borrows: :all },
  checkSub: { zig: "CheatLib.checkSub({0}, {1})", bc: true, borrows: :all },
  checkMul: { zig: "CheatLib.checkMul({0}, {1})", bc: true, borrows: :all },

  # --- Assertion ---
  assert: { zig: "CheatLib.assert({0}, {1})", bc: true, borrows: :all },

  # --- Deep copy (allocates heap copy of union value) ---
  dupeUnionValue: { zig: "try CheatLib.dupeUnionValue({0}, {1}, {2})", bc: true, allocates: true },

  # --- In-place element cleanup (frees the element at idx before overwrite) ---
  cleanupAt: { zig: "CheatLib.cleanupAt({0}, {1}, {2}, {3})", bc: true, allocates: false, borrows: :all },

  # --- Duplicate a []u8 with the given allocator (used by BG stream yield to
  # outlive per-iteration frame rewind). Returns an owned []u8.
  streamDupeBytes: { zig: "try {0}.dupe(u8, {1})", bc: true, allocates: true },

  # --- Set membership probe: target[item] -> item if present else null.
  # {0}=target, {1}=item (also used as the result when present), {2}=elem_zig_type
  setMemberGet: { zig: "if ({0}.contains({1})) @as({2}, {1}) else null", bc: true, borrows: :all },

  # --- Typed cleanup call used by errdefer hoisted temps.
  # {0}=zig_type, {1}=allocator, {2}=binding name
  cleanup: { zig: "CheatLib.cleanup({0}, {1}, {2})", bc: true, allocates: false, borrows: :all },

  # --- Comptime cleanup predicate (true iff the type has non-trivial cleanup).
  # {0}=elem_zig_type
  needsCleanup: { zig: "CheatLib.needsCleanup({0})", bc: true, borrows: :all },
  concurrentBoundedSelect: {
    zig: "try CheatLib.concurrentBoundedSelect({0}, {1}, {2}, {3}, {4}, {5}, {6}, {7}, {8}, {9}, {10})",
    bc: true,
    allocates: true
  },
  concurrentBoundedWhere: {
    zig: "try CheatLib.concurrentBoundedWhere({0}, {1}, {2}, {3}, {4}, {5}, {6}, {7}, {8}, {9})",
    bc: true,
    allocates: true
  },
  concurrentBoundedEach: {
    zig: "try CheatLib.concurrentBoundedEach({0}, {1}, {2}, {3}, {4}, {5}, {6}, {7}, {8})",
    bc: true,
    borrows: :all
  },
  concurrentStreamSelect: {
    zig: "try CheatLib.concurrentStreamSelect({0}, {1}, {2}, {3}, {4}, {5}, {6}, {7}, {8}, {9}, {10}, {11})",
    allocates: true
  },
  concurrentStreamWhere: {
    zig: "try CheatLib.concurrentStreamWhere({0}, {1}, {2}, {3}, {4}, {5}, {6}, {7}, {8}, {9}, {10})",
    allocates: true
  },
  concurrentStreamEach: {
    zig: "try CheatLib.concurrentStreamEach({0}, {1}, {2}, {3}, {4}, {5}, {6}, {7}, {8}, {9}, {10})",
    borrows: :all
  },
  concurrentListSelect: {
    zig: "try CheatLib.concurrentListSelect({0}, {1}, {2}, {3}, {4}, {5}, {6}, {7}, {8}, {9})",
    allocates: true
  },
}.freeze
