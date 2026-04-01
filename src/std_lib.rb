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
    args: [:"Any[]", :Any],
    return: :Void,
    zig: "try {0}.append({alloc}, {1})",
    narrows_collection: true,  # narrows Any[] element type from arg 1
    allocates: true,
  },


  # 1. String.length()
  "length" => [
    { args: [STRING_TYPE], return: :Int64, zig: "CheatLib.len({0})" },
    { args: [:"Any[]"], return: :Int64, zig: "CheatLib.len({0})" }
  ],

  # 2. String.substr(start, len)
  "substr" => {
    args: [STRING_TYPE, :Int64, :Int64],
    return: STRING_TYPE, # Returns new string on heap
    # Call runtime helper: rt.substr(allocator, str, start, len)
    zig: "try CheatLib.substr({alloc}, {0}, {1}, {2})",
    allocates: true,
  },

  # 3. String Equality
  "eql?" => {
    args: [STRING_TYPE, STRING_TYPE],
    return: :Bool,
    zig: "CheatLib.eql({0}, {1})"
  },

  # toInt() (Overloaded)
  "toInt" => [
    { args: [STRING_TYPE], return: :Int64, zig: "try CheatLib.toInt({0})", can_fail: true },
    { args: [:Float64], return: :Int64, zig: "@intFromFloat({0})" },
    { args: [:Int64], return: :Int64, zig: "{0}" }
  ],

  # toString() (Overloaded)
  "toString" => [
    { args: [:Int64],   return: STRING_TYPE, zig: "try CheatLib.intToString({alloc}, {0})", allocates: true },
    { args: [:Float64], return: STRING_TYPE, zig: "try CheatLib.intToString({alloc}, @as(i64, @intFromFloat({0})))", allocates: true },
    { args: [STRING_TYPE], return: STRING_TYPE, zig: "{0}" }
  ],

  # toFloat() (Overloaded)
  "toFloat" => [
    { args: [STRING_TYPE], return: :Float64, zig: "try std.fmt.parseFloat(f64, {0})", can_fail: true },
    { args: [:Int64],      return: :Float64, zig: "@as(f64, @floatFromInt({0}))" },
    { args: [:Float64],    return: :Float64, zig: "{0}" }
  ],

  # charAt(string, index) → String — i-th codepoint (UTF-8 aware, O(n))
  "charAt" => {
    args: [STRING_TYPE, :Int64],
    return: STRING_TYPE,
    zig: "try CheatLib.charAtCodepoint({alloc}, {0}, {1})",
    allocates: true,
  },

  # codepointCount(string) → Int64 — number of Unicode codepoints (O(n))
  "codepointCount" => {
    args: [STRING_TYPE],
    return: :Int64,
    zig: "CheatLib.codepointCount({0})"
  },

  # bytes(string) → Int64 — byte length (O(1), explicit intent)
  "bytes" => {
    args: [STRING_TYPE],
    return: :Int64,
    zig: "CheatLib.len({0})"
  },

  # toNumber(string) → ?Float64 — safe parse, returns null on failure
  "toNumber" => {
    args: [STRING_TYPE],
    return: :"?Float64",
    zig: "(std.fmt.parseFloat(f64, {0}) catch null)"
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
    return: STRING_TYPE,
    zig: "try CheatLib.readFile({alloc}, {0})",
    allocates: true,
  },

  # 5. Write File
  "writeFile" => {
    args: [STRING_TYPE, STRING_TYPE],     # Path, Content
    return: :Void,
    zig: "try CheatLib.writeFile({0}, {1})",
    can_fail: true,
  },

  # 6. Split (String -> String[])
  "split" => {
    args: [STRING_TYPE, STRING_TYPE], # str, delimiter
    return: :"String[]",         # Returns a Heap List of Strings
    zig: "try CheatLib.split({alloc}, {0}, {1})",
    allocates: true,
  },

  # 7. Join (String[] -> String)
  "join" => {
    args: [:"String[]", STRING_TYPE], # list, delimiter
    return: STRING_TYPE,
    zig: "try CheatLib.join({alloc}, {0}, {1})",
    allocates: true,
  },

  "trim" => {
    args: [STRING_TYPE],
    return: STRING_TYPE,
    # No 'rt.' prefix needed. We call std directly.
    zig: "std.mem.trim(u8, {0}, &std.ascii.whitespace)"
  },

  # startsWith("file.txt", "file") -> true
  "startsWith?" => {
    args: [STRING_TYPE, STRING_TYPE],
    return: :Bool,
    zig: "std.mem.startsWith(u8, {0}, {1})"
  },

  # endsWith?("image.png", ".png") -> true
  "endsWith?" => {
    args: [STRING_TYPE, STRING_TYPE],
    return: :Bool,
    zig: "std.mem.endsWith(u8, {0}, {1})"
  },

  # indexOf("hello world", "world") -> 6  (or nil if not found)
  "indexOf" => {
    args: [STRING_TYPE, STRING_TYPE],
    return: :"?Int64",
    zig: "CheatLib.indexOf({0}, {1})"
  },

  # contains?("hello", "ll") -> true
  "contains?" => {
    args: [STRING_TYPE, STRING_TYPE],
    return: :Bool,
    zig: "(std.mem.indexOf(u8, {0}, {1}) != null)"
  },

  # max(a, b) -> larger value
  "max" => [
    { args: [:Int64, :Int64], return: :Int64, zig: "@max({0}, {1})" },
    { args: [:Float64, :Float64], return: :Float64, zig: "@max({0}, {1})" },
  ],

  # min(a, b) -> smaller value
  "min" => [
    { args: [:Int64, :Int64], return: :Int64, zig: "@min({0}, {1})" },
    { args: [:Float64, :Float64], return: :Float64, zig: "@min({0}, {1})" },
  ],

  # abs(x) -> absolute value
  "abs" => [
    { args: [:Float64], return: :Float64, zig: "@abs({0})" },
    { args: [:Int64], return: :Int64, zig: "@intCast(@abs({0}))" },
  ],

  # log(x) -> natural logarithm
  "log" => {
    args: [:Float64],
    return: :Float64,
    zig: "@log({0})"
  },

  # exp(x) -> e^x
  "exp" => {
    args: [:Float64],
    return: :Float64,
    zig: "@exp({0})"
  },

  # floor(x) -> largest integer <= x (as Float64)
  "floor" => {
    args: [:Float64],
    return: :Float64,
    zig: "@floor({0})"
  },

  "shell" => {
    args: [STRING_TYPE],
    return: STRING_TYPE, # Returns %String (Heap String)
    zig: "try CheatLib.shell({alloc}, {0})",
    allocates: true,
  },

  # Read all bytes from an open File resource into a heap-allocated String.
  # Usage: contents = fileReadAll(f)
  "fileReadAll" => {
    args: [:File],
    return: STRING_TYPE,
    zig: "try CheatLib.fileReadAll({alloc}, {0})",
    allocates: true,
  },

  # Write a String to an open writable File resource (created via File::create).
  # Usage: fileWrite(f, "hello")
  "fileWrite" => {
    args: [:File, STRING_TYPE],
    return: :Void,
    zig: "try CheatLib.fileWrite({0}, {1})",
    can_fail: true,
  },

  # List all files in a directory. Returns a list of filenames (not full paths).
  # Usage: files = listDir("/some/dir")
  "listDir" => {
    args: [STRING_TYPE],
    return: :"String[]",
    zig: "try CheatLib.listDir({alloc}, {0})",
    allocates: true,
  },

  # List ALL entries (files + directories) with type prefix ("f:" or "d:").
  # Usage: entries = listAll("/some/dir")
  "listAll" => {
    args: [STRING_TYPE],
    return: :"String[]",
    zig: "try CheatLib.listAll({alloc}, {0})",
    allocates: true,
  },

  # Get file size in bytes. Returns -1 on error.
  # Usage: size = fileSize("/some/file.txt")
  "fileSize" => {
    args: [STRING_TYPE],
    return: :Int64,
    zig: "CheatLib.fileSize({0})"
  },

  # Count non-overlapping occurrences of needle in haystack.
  # Usage: n = countOccurrences(content, "the")
  "countOccurrences" => {
    args: [STRING_TYPE, STRING_TYPE],
    return: :Int64,
    zig: "CheatLib.countOccurrences({0}, {1})"
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
  },

  # Read up to 4096 bytes from a connected TCP client into a heap String.
  # Yields the fiber if no data is ready (epoll-backed).
  # Usage: data = tcpRead(client)
  "tcpRead" => {
    args: [:TCPClient],
    return: STRING_TYPE,
    zig: "try CheatLib.socketRead({alloc}, {0})",
    allocates: true,
  },

  # Write a String to a connected TCP client.
  # Yields the fiber if the send buffer is full (epoll-backed).
  # Usage: tcpWrite(client, "hello")
  "tcpWrite" => {
    args: [:TCPClient, STRING_TYPE],
    return: :Void,
    zig: "try CheatLib.socketWriteVoid({0}, {1})",
    can_fail: true,
  },

  # -------------------------------------------------------------------------
  # Clock & Timing
  # -------------------------------------------------------------------------

  # Wall clock milliseconds since Unix epoch.
  # Usage: start = timestampMs(); ... elapsed = timestampMs() - start;
  "timestampMs" => {
    args: [],
    return: :Int64,
    zig: "CheatLib.timestampMs()"
  },

  # Number of scheduler threads (main + workers). Matches CLEAR_THREADS env var.
  # Usage: workers = threadCount();
  "threadCount" => {
    args: [],
    return: :Int64,
    zig: "CheatLib.threadCount()"
  },

  # Peak resident set size (VmHWM) in KB — high-water mark of physical memory.
  # Cross-language comparable (reads /proc/self/status).
  "peakMemoryKb" => {
    args: [],
    return: :Int64,
    zig: "CheatLib.peakMemoryKb()"
  },

  # Current resident set size (VmRSS) in KB — physical memory in use right now.
  "currentMemoryKb" => {
    args: [],
    return: :Int64,
    zig: "CheatLib.currentMemoryKb()"
  },

  # Sleep the current fiber for N milliseconds. Cooperative — other fibers run.
  # Usage: sleep(100);
  "sleep" => {
    args: [:Int64],
    return: :Void,
    zig: "rt.sleep(@intCast(@as(u64, @bitCast({0}))))"
  },

  # -------------------------------------------------------------------------
  # Random
  # -------------------------------------------------------------------------

  # Random float in [0.0, 1.0). Cryptographically secure.
  # Usage: val = random();
  "random" => {
    args: [],
    return: :Float64,
    zig: "CheatLib.random()"
  },

  # Random integer in [0, max). Cryptographically secure.
  # Usage: idx = randomInt(100);
  "randomInt" => {
    args: [:Int64],
    return: :Int64,
    zig: "CheatLib.randomInt({0})"
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
    return_type: ->(obj_type) { Type.new(:"?#{obj_type.element_type.resolved}") },
  },
  "remove" => {
    arity: 1, tag: :pool_method,
    return_type: ->(_) { :Void },
  },
  "count" => {
    arity: 0, tag: :pool_method,
    return_type: ->(_) { Type.new(:Int64) },
  },
}.freeze

SET_METHODS = {
  "insert" => {
    arity: 1, tag: :set_method, allocates: true,
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
    return_type: ->(_) { :Bool },
  },
  "remove" => {
    arity: 1, tag: :set_method,
    return_type: ->(_) { :Void },
  },
  "count" => {
    arity: 0, tag: :set_method,
    return_type: ->(_) { Type.new(:Int64) },
  },
}.freeze

MAP_METHODS = {
  "delete" => {
    arity: 1, tag: :map_method,
    validate: ->(node, args, obj_type, error_fn) {
      arg_type = Type.new(args[0].resolved_type)
      if obj_type.numeric_map?
        error_fn.call(node, "HashMap.delete: key must be a numeric type, got #{args[0].resolved_type}") unless arg_type.numeric?
      else
        error_fn.call(node, "HashMap.delete: key must be a String, got #{args[0].resolved_type}") unless arg_type.string?
      end
    },
    return_type: ->(_) { :Void },
  },
  "contains?" => {
    arity: 1, tag: :map_method,
    validate: ->(node, args, obj_type, error_fn) {
      arg_type = Type.new(args[0].resolved_type)
      if obj_type.numeric_map?
        error_fn.call(node, "HashMap.contains?: key must be a numeric type, got #{args[0].resolved_type}") unless arg_type.numeric?
      else
        error_fn.call(node, "HashMap.contains?: key must be a String, got #{args[0].resolved_type}") unless arg_type.string?
      end
    },
    return_type: ->(_) { :Bool },
  },
  "count" => {
    arity: 0, tag: :map_method,
    return_type: ->(_) { Type.new(:Int64) },
  },
  "keys" => {
    arity: 0, tag: :map_method,
    return_type: ->(_) { :"String[]" },
  },
  "values" => {
    arity: 0, tag: :map_method,
    return_type: ->(obj_type) { :"#{obj_type.value_type.resolved}[]" },
  },
}.freeze
