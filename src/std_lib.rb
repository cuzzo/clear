STRING_TYPE = "String[]".to_sym
HEAP_STRING_TYPE = "%String[]".to_sym

STD_LIB = {
  # Method Name => { args: [Type...], return: Type, zig: Pattern }

  "append" => {
    args: [:"Any[]", :Any],
    return: :Void, # Zig's append returns !void, so chaining isn't supported yet
    zig: "try {0}.append({alloc}, {1})"
  },

  # 1. String.length()
  "length" => {
    args: [STRING_TYPE],
    return: :Int64,
    zig: "{0}.len"  # {0} is the receiver/first arg
  },

  # TODO: allow overloading
  # 1b. Array.length()
  "count" => {
    args: [:"Any[]"],   # TODO: Get this to work
    return: :Int64,
    zig: "rt.len({0})"
  },

  # 2. String.substr(start, len)
  "substr" => {
    args: [STRING_TYPE, :Int64, :Int64],
    return: HEAP_STRING_TYPE, # Returns new string on heap
    # Call runtime helper: rt.substr(allocator, str, start, len)
    zig: "try rt.substr({alloc}, {0}, {1}, {2})"
  },

  # 3. String Equality
  "eql" => {
    args: [STRING_TYPE, STRING_TYPE],
    return: :Bool,
    zig: "rt.eql({0}, {1})"
  },

  # 4. Parse Int
  "toInt" => {
    args: [STRING_TYPE],
    return: :Int64,
    zig: "try rt.toInt({0})"
  },

  # 4b. Parse Float "2.5" -> 12.5
  "toFloat" => {
    args: [STRING_TYPE],
    return: :Number, # f64
    zig: "try std.fmt.parseFloat(f64, {0})"
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
    return: HEAP_STRING_TYPE,
    zig: "try rt.readFile({0})"
  },

  # 5. Write File
  "writeFile" => {
    args: [STRING_TYPE, STRING_TYPE],     # Path, Content
    return: :Void,
    zig: "try rt.writeFile({0}, {1})"
  },

  # 6. Split (String -> String[])
  "split" => {
    args: [STRING_TYPE, STRING_TYPE], # str, delimiter
    return: :"%String[][]",         # Returns a Heap List of Strings
    zig: "try rt.split({alloc}, {0}, {1})"
  },

  # 7. Join (String[] -> String)
  "join" => {
    args: [:"String[][]", STRING_TYPE], # list, delimiter
    return: HEAP_STRING_TYPE,
    zig: "try rt.join({alloc}, {0}, {1})"
  },

  "trim" => {
    args: [STRING_TYPE],
    return: STRING_TYPE,
    # No 'rt.' prefix needed. We call std directly.
    zig: "std.mem.trim(u8, {0}, &std.ascii.whitespace)"
  },

  # startsWith("file.txt", "file") -> true
  "startsWith" => {
    args: [STRING_TYPE, STRING_TYPE],
    return: :Bool,
    zig: "std.mem.startsWith(u8, {0}, {1})"
  },

  # endsWith("image.png", ".png") -> true
  "endsWith" => {
    args: [STRING_TYPE, STRING_TYPE],
    return: :Bool,
    zig: "std.mem.endsWith(u8, {0}, {1})"
  },

  # contains("hello", "ll") -> true
  # Zig returns an optional index (?usize). We check if it is not null.
  "contains" => {
    args: [STRING_TYPE, STRING_TYPE],
    return: :Bool,
    zig: "(std.mem.indexOf(u8, {0}, {1}) != null)"
  },

  # TODO: only works with directly with :Number
  # All other types will do implicit casts, slow
  "max" => {
    args: [:Number, :Number], # Works for f64 (and i64 via implicit cast)
    return: :Number,
    zig: "@max({0}, {1})"
  },

  # min(10, 20) -> 10
  "min" => {
    args: [:Number, :Number],
    return: :Number,
    zig: "@min({0}, {1})"
  },

  # abs(-5) -> 5
  "abs" => {
    args: [:Number],
    return: :Number,
    zig: "@abs({0})"
  },
}

