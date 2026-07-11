# typed: strict
require "sorbet-runtime"
require_relative "type"
require_relative "../mir/fsm_ops"

STRING_TYPE = :String
HEAP_STRING_TYPE = :String

# Shorthand for FsmOps DSL constructors used in FSM templates below.
# Usage in std_lib entries:
#   fsm_setup: [
#     FO.assign_field("rf_fd", FO.call(FO.fn("CheatHeader.fsmOpenForRead"), [FO.arg(0)], is_try: true)),
#     ...
#   ]
FO = FsmOps::DSL

STD_LIB = T.let({
  # Method Name => { args: [Type...], return: Type, zig: Pattern }

  "symbol" => {
    args: [STRING_TYPE],
    return: {type: STRING_TYPE, sync: :symbol},
    zig: "try {rt}.internSymbol({0})",
    bc: false,
    can_fail: true,
    needs_rt: true,
    borrows: :all,
  },

  "panic" => {
    args: [STRING_TYPE],
    return: :NoReturn,
    zig: "@panic({0})",
    bc: false,
    borrows: :all,
  },

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
    is_method: true,
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
    is_method: true,
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
    is_method: true,
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
    is_method: true,
  },

  "clear" => {
    args: [:"Any[]"],
    return: :Void,
    zig: "{0}.clearRetainingCapacity()",
    bc: true,
    mutates_receiver: true,
    borrows: :all,
    is_method: true,
  },

  "remove" => {
    args: [:"Any[]", :Int64],
    return: :infer_element_type,
    return_alloc: :receiver_storage,  # removed element is now owned by caller
    zig: "{0}.orderedRemove(@intCast({1}))",
    bc: true,
    mutates_receiver: true,
    borrows: :all,  # borrows list + index; returns owned element,
    is_method: true,
  },

  # pop() — remove and return the last element, or null if empty.
  "pop" => {
    args: [:"Any[]"],
    return: :infer_optional_element_type,
    return_alloc: :receiver_storage,  # popped element is now owned by caller
    zig: "{0}.pop()",
    bc: true,
    mutates_receiver: true,
    borrows: :all,
    is_method: true,
  },

  # first() / last() — non-mutating peek at index 0 / index N-1, or NIL
  # if the collection is empty. Backed by CheatLib.firstOpt / lastOpt
  # so the same registry entry handles ArrayList and bare slices via
  # comptime `@hasField` shape dispatch.
  #
  # Not registered in POOL_METHODS, SET_METHODS, or MAP_METHODS:
  #   - HashMap and Set are unordered (hash iteration), so "first" /
  #     "last" would be nondeterministic. Wait for @sorted variants.
  #   - Pool is a slot allocator with ABA-safe handles, not a sequence;
  #     a Pool's "first slot's value" is rarely what users want.
  "first" => {
    args: [:"Any[]"],
    return: :infer_optional_element_type,
    lifetime: "self",  # peeks element in place; result borrows the container
    zig: "CheatLib.firstOpt({0})",
    bc: true,
    borrows: :all,
    is_method: true,
  },

  "last" => {
    args: [:"Any[]"],
    return: :infer_optional_element_type,
    lifetime: "self",  # peeks element in place; result borrows the container
    zig: "CheatLib.lastOpt({0})",
    bc: true,
    borrows: :all,
    is_method: true,
  },


  # 1. String.length()
  "length" => [
    { args: [STRING_TYPE], return: :Int64, zig: "CheatLib.len({0})", bc: true, borrows: :all,
      is_method: true,
    },
    { args: [:"Any[]"], return: :Int64, zig: "CheatLib.len({0})", bc: true, borrows: :all,
      is_method: true,
    }
  ],

  # 2. String.substr(start, len)
  # String@raw: O(1) zero-copy sub-slice, no allocation. Returns String@raw.
  # String:     Allocates a copy on the frame arena.
  "substr" => [
    { args: [{type: STRING_TYPE, sync: :raw}, :Int64, :Int64],
      return: {type: STRING_TYPE, sync: :raw},
      zig: "CheatLib.substrRaw({0}, {1}, {2})",
      bc: true,
        is_method: true,
      },
    { args: [STRING_TYPE, :Int64, :Int64],
      return: STRING_TYPE, return_alloc: :frame,
      zig: "try CheatLib.substr({alloc}, {0}, {1}, {2})",
      bc: true,
      allocates: true, alloc: :node_storage,
        is_method: true,
      },
  ],

  # 3. String Equality
  "eql?" => {
    args: [STRING_TYPE, STRING_TYPE],
    return: :Bool,
    zig: "CheatLib.eql({0}, {1})",
    bc: true,
    borrows: :all,
    is_method: true,
  },

  # toInt() (Overloaded)
  "toInt" => [
    { args: [STRING_TYPE], return: :Int64, zig: "try CheatLib.toInt({0})", bc: true, can_fail: true, borrows: :all,
      is_method: true,
    },
    { args: [:Float64], return: :Int64, zig: "@intFromFloat({0})", bc: true,
      is_method: true,
    },
    { args: [:Int64], return: :Int64, zig: "{0}", bc: true,
      is_method: true,
    }
  ],

  # toString() (Overloaded)
  "toString" => [
    { args: [:Int64],   return: STRING_TYPE, return_alloc: :frame, zig: "try CheatLib.intToString({alloc}, {0})", bc: true, allocates: true, alloc: :node_storage,
      is_method: true,
    },
    { args: [:Float64], return: STRING_TYPE, return_alloc: :frame, zig: "try CheatLib.intToString({alloc}, @as(i64, @intFromFloat({0})))", bc: true, allocates: true, alloc: :node_storage,
      is_method: true,
    },
    { args: [STRING_TYPE], return: STRING_TYPE, return_alloc: :frame, zig: "{0}", bc: true,
      is_method: true,
    }
  ],

  # toFloat() (Overloaded)
  "toFloat" => [
    { args: [STRING_TYPE], return: :Float64, zig: "try std.fmt.parseFloat(f64, {0})", bc: true, can_fail: true, borrows: :all,
      is_method: true,
    },
    { args: [:Int64],      return: :Float64, zig: "@as(f64, @floatFromInt({0}))", bc: true,
      is_method: true,
    },
    { args: [:Float64],    return: :Float64, zig: "{0}", bc: true,
      is_method: true,
    }
  ],

  "toList" => [
    {
      args: [:"Any[]"],
      return: :infer_to_list,
      zig: "try ({0}).toList({alloc})",
      bc: true, bc_op: :to_list,
      allocates: true,
      alloc: :node_storage,
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
      bc: true,
        is_method: true,
      },
    { args: [STRING_TYPE, :Int64],
      return: STRING_TYPE, return_alloc: :frame,
      zig: "try CheatLib.charAtCodepoint({alloc}, {0}, {1})",
      bc: true,
      allocates: true, alloc: :node_storage,
        is_method: true,
      },
  ],

  # codepointCount(string) → Int64 — number of Unicode codepoints (O(n))
  "codepointCount" => {
    args: [STRING_TYPE],
    return: :Int64,
    zig: "CheatLib.codepointCount({0})",
    bc: true,
    borrows: :all,
    is_method: true,
  },

  # byteAt(string, index) → Int64 — O(1) byte-level numeric access.
  # Out-of-range returns 0 rather than raising. Used by the register VM
  # bytecode parser; not a method to discourage misuse from CLEAR code.
  "byteAt" => {
    args: [STRING_TYPE, :Int64],
    return: :Int64,
    zig: "CheatLib.byteAt({0}, {1})",
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
    is_method: true,
  },

  # toNumber(string) → ?Float64 — safe parse, returns null on failure
  "toNumber" => {
    args: [STRING_TYPE],
    return: :"?Float64",
    zig: "(std.fmt.parseFloat(f64, {0}) catch null)",
    bc: true,
    borrows: :all,
    is_method: true,
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
    alloc: :node_storage,
    suspends: true,   # io_uring submitRead + yield
    # FSM-mode templates (Phase B2-IO). Single-syscall variant: open
    # → fileSize → alloc buffer → one io_uring read → close. Most
    # files return all bytes in a single read; the stackful version's
    # chunked-read loop is omitted here. Files larger than what one
    # read returns will be truncated — for those, force stackful via
    # @xl on the BG block.
    # KNOWN LIMITATION: rf_buf is heap-allocated via the BG's allocator
    # but the consumer's NEXT site does not emit a matching free. This
    # leaks for read-into-BG patterns. Tracked as a follow-up: the FSM
    # lowering must teach MIR/promotion-plan that the FSM-lowered BG
    # result owns heap data so the consumer auto-cleans.
    fsm_state_decls: [
      FsmOps::StateFieldDecl.new(name: "rf_fd", zig_type: "i32", default_value: MIR::Lit.new("-1")),
      FsmOps::StateFieldDecl.new(name: "rf_buf", zig_type: "[]u8", default_value: MIR::AddressOf.new(MIR::ArrayInit.new("u8", "_", []))),
      FsmOps::StateFieldDecl.new(name: "rf_waiter", zig_type: "CheatHeader.FsmIoWaiter", default_value: MIR::Undef.new(nil)),
    ],
    fsm_setup: [
      # ctx.rf_fd = try fsmOpenForRead(path)
      FO.assign_field("rf_fd",
        FO.call(FO.fn("CheatHeader.fsmOpenForRead"), [FO.arg(0)], is_try: true)),
      # errdefer fsmCloseFd(ctx.rf_fd)
      FO.err_defer_call(FO.fn("CheatHeader.fsmCloseFd"), [FO.state("rf_fd")]),
      # const __rf_size: usize = @as(usize, @intCast(try fsmFileSize(ctx.rf_fd)))
      FO.let_const("__rf_size", "usize",
        FO.intcast("usize",
          FO.call(FO.fn("CheatHeader.fsmFileSize"), [FO.state("rf_fd")], is_try: true))),
      # ctx.rf_buf = try ctx.alloc.alloc(u8, __rf_size)
      FO.assign_field("rf_buf",
        FO.alloc_expr("u8", FO.local("__rf_size"))),
      # errdefer ctx.alloc.free(ctx.rf_buf)
      FO.err_defer_free_field("rf_buf"),
      # ctx.rf_waiter = CheatHeader.FsmIoWaiter.init(ctx.task)
      # `task` is `*FsmTask` (slab-allocated), so pass directly.
      FO.assign_field("rf_waiter",
        FO.call(FO.fn("CheatHeader.FsmIoWaiter.init"),
                [FO.state("task")])),
      # try ctx.rt.getSched().submitReadForFsm(&ctx.rf_waiter, ctx.rf_fd, ctx.rf_buf)
      FO.io_submit(:read, "rf_waiter", [FO.state("rf_fd"), FO.state("rf_buf")]),
    ],
    fsm_finish_block: [
      # fsmCloseFd(ctx.rf_fd);
      FO.stmt_call(FO.fn("CheatHeader.fsmCloseFd"), [FO.state("rf_fd")]),
      # if (ctx.rf_waiter.result < 0) return fsmIoError(ctx.rf_waiter.result);
      FO.if_neg_return_call("rf_waiter", "result",
        FO.fn("CheatHeader.fsmIoError"),
        [FO.subf(FO.state("rf_waiter"), "result")]),
    ],
    # Bound expression: ctx.rf_buf[0..@as(usize, @intCast(ctx.rf_waiter.result))]
    fsm_finish_value: FO.slice_intcast(
      FO.state("rf_buf"),
      FO.subf(FO.state("rf_waiter"), "result"),
    ),
    # defer ctx.alloc.free(ctx.rf_buf) at start of runStep1 — fires
    # AFTER post-stmts read the slice. Step 0 success guarantees
    # rf_buf was allocated. Result-aliasing case rejected by
    # INV-FSM-RESULT-NO-FINALIZED-ALIAS in MIRChecker.
    fsm_state_finalize: [
      FO.defer_free_field("rf_buf"),
    ],
    is_method: true,
  },

  # 5. Write File
  "writeFile" => {
    args: [STRING_TYPE, STRING_TYPE],     # Path, Content
    return: :Void,
    zig: "try CheatLib.writeFile({0}, {1})",
    bc: true,
    can_fail: true,
    borrows: :all,
    suspends: true,
    # FSM-mode templates: open (CREAT + TRUNC) → one io_uring write
    # → close. Single-syscall write; large content where one write
    # returns less than full length is truncated. Force stackful via
    # @xl when partial-write robustness is required.
    fsm_state_decls: [
      FsmOps::StateFieldDecl.new(name: "wf_fd", zig_type: "i32", default_value: MIR::Lit.new("-1")),
      FsmOps::StateFieldDecl.new(name: "wf_waiter", zig_type: "CheatHeader.FsmIoWaiter", default_value: MIR::Undef.new(nil)),
    ],
    fsm_setup: [
      FO.assign_field("wf_fd",
        FO.call(FO.fn("CheatHeader.fsmOpenForWrite"), [FO.arg(0)], is_try: true)),
      FO.err_defer_call(FO.fn("CheatHeader.fsmCloseFd"), [FO.state("wf_fd")]),
      FO.assign_field("wf_waiter",
        FO.call(FO.fn("CheatHeader.FsmIoWaiter.init"),
                [FO.state("task")])),
      FO.io_submit(:write, "wf_waiter", [FO.state("wf_fd"), FO.arg(1)]),
    ],
    fsm_finish_block: [
      FO.stmt_call(FO.fn("CheatHeader.fsmCloseFd"), [FO.state("wf_fd")]),
      FO.if_neg_return_call("wf_waiter", "result",
        FO.fn("CheatHeader.fsmIoError"),
        [FO.subf(FO.state("wf_waiter"), "result")]),
    ],
    fsm_finish_value: nil,   # Void return,
    is_method: true,
  },

  # 6. Read Line from stdin
  "readLine!" => {
    args: [],
    return: STRING_TYPE,
    return_alloc: :frame,
    zig: "try CheatLib.readLine({alloc})",
    allocates: true,
    alloc: :node_storage,
    can_fail: true,
  },

  # 6b. Read Line with prompt, editing, and history
  "readLinePrompt!" => {
    args: [STRING_TYPE],
    return: STRING_TYPE,
    return_alloc: :frame,
    zig: "try CheatLib.readLinePrompt({alloc}, {0})",
    allocates: true,
    alloc: :node_storage,
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
    is_method: true,
  },

  # 7. Join (String[] -> String)
  "join" => {
    args: [:"String[]", STRING_TYPE],
    return: STRING_TYPE, return_alloc: :frame,
    zig: "try CheatLib.join({alloc}, {0}, {1})",
    bc: true,
    allocates: true,
    alloc: :node_storage,
    is_method: true,
  },

  "trim" => {
    args: [STRING_TYPE],
    return: STRING_TYPE,
    lifetime: "self",  # returns a sub-slice of the input; no allocation
    zig: "std.mem.trim(u8, {0}, &std.ascii.whitespace)",
    bc: true,
    borrows: :all,
    is_method: true,
  },

  # startsWith("file.txt", "file") -> true
  "startsWith?" => {
    args: [STRING_TYPE, STRING_TYPE],
    return: :Bool,
    zig: "std.mem.startsWith(u8, {0}, {1})",
    bc: true,
    borrows: :all,
    is_method: true,
  },

  # endsWith?("image.png", ".png") -> true
  "endsWith?" => {
    args: [STRING_TYPE, STRING_TYPE],
    return: :Bool,
    zig: "std.mem.endsWith(u8, {0}, {1})",
    bc: true,
    borrows: :all,
    is_method: true,
  },

  # indexOf("hello world", "world") -> 6  (or nil if not found)
  "indexOf" => [
    {
      args: [STRING_TYPE, STRING_TYPE],
      return: :"?Int64",
      zig: "CheatLib.indexOf({0}, {1})",
      bc: true,
      borrows: :all,
      is_method: true,
    },
    {
      args: [STRING_TYPE, STRING_TYPE, :Int64],
      return: :"?Int64",
      zig: "CheatLib.indexOfFrom({0}, {1}, {2})",
      borrows: :all,
      is_method: true,
    },
  ],

  # replace("hello world", "world", "CLEAR") -> "hello CLEAR"
  "replace" => {
    args: [STRING_TYPE, STRING_TYPE, STRING_TYPE],
    return: STRING_TYPE, return_alloc: :frame,
    zig: "try CheatLib.stringReplace({alloc}, {0}, {1}, {2})",
    bc: true,
    allocates: true,
    alloc: :node_storage,
    is_method: true,
  },

  # "Hello".downcase() -> "hello"
  # ASCII case-folding, allocates a new String on the frame arena.
  # Named after Ruby (`.downcase` / `.upcase`) to stay consistent with
  # the rest of the predicate/utility surface (`.empty?`, `.any?`,
  # `.starts_with?`, `.zero?`). Zig helper retains the descriptive
  # name `stringLowercase` since it operates on a Zig `[]const u8`.
  "downcase" => {
    args: [STRING_TYPE],
    return: STRING_TYPE, return_alloc: :frame,
    zig: "try CheatLib.stringLowercase({alloc}, {0})",
    bc: true,
    allocates: true,
    alloc: :node_storage,
    is_method: true,
  },

  # "Hello".upcase() -> "HELLO"
  "upcase" => {
    args: [STRING_TYPE],
    return: STRING_TYPE, return_alloc: :frame,
    zig: "try CheatLib.stringUppercase({alloc}, {0})",
    bc: true,
    allocates: true,
    alloc: :node_storage,
    is_method: true,
  },

  # contains?("hello", "ll") -> true
  # contains?(arr, item)     -> true/false (linear search, @list or T[])
  "contains?" => [
    { args: [STRING_TYPE, STRING_TYPE],
      return: :Bool,
      zig: "(std.mem.indexOf(u8, {0}, {1}) != null)",
      bc: true,
      borrows: :all,
        is_method: true,
      },
    { args: [:"Any[]", :Any],
      return: :Bool,
      zig: "CheatLib.sliceContains({0}, {1})",
      bc: true,
      borrows: :all,
        is_method: true,
      },
  ],

  # starts_with?("hello", "he") -> true
  # ends_with?("hello", "lo")   -> true
  # Both are byte-level prefix/suffix checks via Zig stdlib. No
  # allocation, no UTF-8 iteration — match the same shape as the
  # String overload of contains?.
  "starts_with?" => {
    args: [STRING_TYPE, STRING_TYPE],
    return: :Bool,
    zig: "std.mem.startsWith(u8, {0}, {1})",
    bc: true,
    borrows: :all,
    is_method: true,
  },

  "ends_with?" => {
    args: [STRING_TYPE, STRING_TYPE],
    return: :Bool,
    zig: "std.mem.endsWith(u8, {0}, {1})",
    bc: true,
    borrows: :all,
    is_method: true,
  },

  # ---- Numeric predicates (ActiveSupport-style English-as-CLEAR) ----
  # Each is `is_method: true` so `clear fmt` rewrites prefix calls to
  # UFCS form: `zero?(n)` -> `n.zero?()`. Designed for ergonomic
  # `ASSERT n.between?(0, 100)` reads in tests AND idiomatic
  # `IF count.positive? THEN ...` reads in app code.

  # n.zero? -> n == 0. Float64 listed first so a Float64 receiver
  # binds to the Float64 overload rather than autocasting through
  # `@intFromFloat` to the Int64 overload (mirrors `abs`'s ordering).
  "zero?" => [
    { args: [:Float64], return: :Bool, zig: "({0} == 0.0)", bc: true, is_method: true },
    { args: [:Int64],   return: :Bool, zig: "({0} == 0)",   bc: true, is_method: true },
  ],

  # n.positive? -> n > 0
  "positive?" => [
    { args: [:Float64], return: :Bool, zig: "({0} > 0.0)", bc: true, is_method: true },
    { args: [:Int64],   return: :Bool, zig: "({0} > 0)",   bc: true, is_method: true },
  ],

  # n.negative? -> n < 0
  #
  # Numeric autocast lets a UInt receiver match either the Float64 or
  # the Int64 entry (and the matcher picks Float64 because it's first).
  # `u32_val < 0` is always false — values of unsigned types are >= 0
  # by construction, so the call is a bug regardless of which overload
  # matched. Tag BOTH entries with `reject_when: :unsigned_integer` so
  # the reject fires whichever way autocast routes the call.
  "negative?" => [
    { args: [:Float64], return: :Bool, zig: "({0} < 0.0)", bc: true, is_method: true,
      reject_when: :unsigned_integer,
      reject_error: ".negative?() is always false on unsigned integers — values of unsigned types are >= 0 by construction. Did you mean .zero?() or remove the check?" },
    { args: [:Int64],   return: :Bool, zig: "({0} < 0)",   bc: true, is_method: true,
      reject_when: :unsigned_integer,
      reject_error: ".negative?() is always false on unsigned integers — values of unsigned types are >= 0 by construction. Did you mean .zero?() or remove the check?" },
  ],

  # n.even? -> (n & 1) == 0
  "even?" => {
    args: [:Int64], return: :Bool, zig: "(@mod({0}, 2) == 0)", bc: true, is_method: true,
  },

  # n.odd? -> (n & 1) != 0
  "odd?" => {
    args: [:Int64], return: :Bool, zig: "(@mod({0}, 2) != 0)", bc: true, is_method: true,
  },

  # n.between?(low, high) -> low <= n <= high (inclusive). Like Ruby
  # Comparable#between?; chosen over an exclusive variant because
  # half-open ranges are spelled differently elsewhere (`a..<b`).
  "between?" => [
    { args: [:Float64, :Float64, :Float64],
      return: :Bool, zig: "(({0} >= {1}) and ({0} <= {2}))",
      bc: true, is_method: true },
    { args: [:Int64, :Int64, :Int64],
      return: :Bool, zig: "(({0} >= {1}) and ({0} <= {2}))",
      bc: true, is_method: true },
  ],

  # f.closeTo?(val, tol) -> |f - val| <= tol. Float-equality replacement
  # for tests. `closeTo?(_, 0.0001)` is the canonical "approximately
  # equal" check.
  "closeTo?" => {
    args: [:Float64, :Float64, :Float64],
    return: :Bool,
    zig: "(@abs({0} - {1}) <= {2})",
    bc: true,
    is_method: true,
  },

  # ---- ActiveSupport-style optional / collection predicates ----
  # `.nil?` / `.present?` are designed for `?T` receivers and lower
  # to a direct null comparison. Calling them on a non-optional T is
  # rejected by Zig at compile time ("cannot compare T to null") —
  # not the friendliest diagnostic, but the predicate is by
  # construction only meaningful on optionals.

  # x.nil?  -> Bool — true iff the optional is null
  "nil?" => {
    args: [:Any],
    return: :Bool,
    zig: "({0} == null)",
    bc: true,
    borrows: :all,
    is_method: true,
  },

  # x.present?  -> !x.nil?  (the not-null inverse)
  "present?" => {
    args: [:Any],
    return: :Bool,
    zig: "({0} != null)",
    bc: true,
    borrows: :all,
    is_method: true,
  },

  # `.empty?` on collections — direct counterpart to `.length() == 0`.
  # Strings: byte length. Lists: items length. The comptime
  # @hasField branch chooses between bare `.len` (raw slices) and
  # `.items.len` (ArrayList shape), so the same entry handles both
  # CLEAR list shapes uniformly.
  "empty?" => [
    { args: [STRING_TYPE], return: :Bool,
      zig: "({0}.len == 0)",
      bc: true, borrows: :all, is_method: true },
    { args: [:"Any[]"], return: :Bool,
      zig: "((if (@hasField(@TypeOf({0}), \"items\")) {0}.items.len else {0}.len) == 0)",
      bc: true, borrows: :all, is_method: true },
  ],

  # `.blank?` on optional collections — true if nil OR empty. Only
  # meaningful on `?T` shapes (where it's distinct from `.empty?`,
  # which would null-deref on a nil receiver). For non-optional
  # collections users write `.empty?`; CLEAR avoids two predicates
  # for the same check on the same shape.
  #
  # The comptime @hasField guard handles both String (`.len`) and
  # ArrayList-shaped lists (`.items.len`) under the same Zig pattern.
  "blank?" => {
    args: [:Any],
    return: :Bool,
    zig: "({0} == null or (if (@hasField(@TypeOf(({0}).?), \"items\")) ({0}).?.items.len else ({0}).?.len) == 0)",
    bc: true,
    borrows: :all,
    is_method: true,
  },

  # `.any?` — CLEAR's "has data" predicate. Distinct from Ruby's
  # `.present?` because CLEAR reserves `.present?` for the not-nil
  # check on `?T`. `.any?` answers "does this collection
  # contain anything" and works uniformly on both bare and optional
  # collections via the comptime null + shape dispatch.
  #
  # Behavior:
  #   String / Any[]              -> length > 0
  #   ?String / ?Any[]            -> not-nil AND unwrapped length > 0
  #   HashMap (see MAP_METHODS)   -> count > 0
  "any?" => [
    { args: [STRING_TYPE], return: :Bool,
      zig: "({0}.len > 0)",
      bc: true, borrows: :all, is_method: true },
    { args: [:"Any[]"], return: :Bool,
      zig: "((if (@hasField(@TypeOf({0}), \"items\")) {0}.items.len else {0}.len) > 0)",
      bc: true, borrows: :all, is_method: true },
    # ?String / ?Any[] — accept-all optional via :Any so this overload
    # fires when the receiver is nullable. The comptime guard inside
    # the Zig pattern peeks the unwrapped shape (`.items.len` for
    # ArrayList, `.len` for raw slice/string).
    { args: [:Any], return: :Bool,
      zig: "({0} != null and (if (@hasField(@TypeOf(({0}).?), \"items\")) ({0}).?.items.len else ({0}).?.len) > 0)",
      bc: true, borrows: :all, is_method: true },
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
    suspends: true,
    is_method: true,
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
    suspends: true,
    is_method: true,
  },

  # List all files in a directory. Returns a list of filenames (not full paths).
  # Usage: files = listDir("/some/dir")
  "listDir" => {
    args: [STRING_TYPE],
    return: :"String[]",
    zig: "try CheatLib.listDir({alloc}, {0})",
    allocates: true,
    alloc: :node_storage,
    is_method: true,
  },

  # List ALL entries (files + directories) with type prefix ("f:" or "d:").
  # Usage: entries = listAll("/some/dir")
  "listAll" => {
    args: [STRING_TYPE],
    return: :"String[]",
    zig: "try CheatLib.listAll({alloc}, {0})",
    allocates: true,
    alloc: :node_storage,
    is_method: true,
  },

  # Get file size in bytes. Returns -1 on error.
  # Usage: size = fileSize("/some/file.txt")
  "fileSize" => {
    args: [STRING_TYPE],
    return: :Int64,
    zig: "CheatLib.fileSize({0})",
    bc: true,
    borrows: :all,
    is_method: true,
  },

  # Count non-overlapping occurrences of needle in haystack.
  # Usage: n = countOccurrences(content, "the")
  "countOccurrences" => {
    args: [STRING_TYPE, STRING_TYPE],
    return: :Int64,
    zig: "CheatLib.countOccurrences({0}, {1})",
    bc: true,
    borrows: :all,
    is_method: true,
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
    suspends: true,
    is_method: true,
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
    suspends: true,
    is_method: true,
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
    suspends: true,
    is_method: true,
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
    zig: "@as(i64, @intCast({rt}.framePeakBytes()))",
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

  # Peak virtual memory size (VmPeak) in KB.
  "peakVirtualMemoryKb" => {
    args: [],
    return: :Int64,
    zig: "CheatLib.peakVirtualMemoryKb()",
    bc: true,
  },

  # Current resident set size (VmRSS) in KB — physical memory in use right now.
  "currentMemoryKb" => {
    args: [],
    return: :Int64,
    zig: "CheatLib.currentMemoryKb()",
    bc: true,
  },

  # Benchmark helper: touch pages in the current fiber's allocated stack slice.
  # No-op on root-stack/FSM execution.
  "touchCurrentFiberStack" => {
    args: [:Int64, :Int64],
    return: :Int64,
    zig: "CheatLib.touchCurrentFiberStack({0}, {1})",
  },

  # Sleep the current fiber for N milliseconds. Cooperative — other fibers run.
  # Usage: sleep(100);
  "sleep" => {
    args: [:Int64],
    return: :Void,
    zig: "{rt}.sleep(@intCast(@as(u64, @bitCast({0}))))",
    bc: true,
    needs_rt: true,
    suspends: true,    # rt.sleep yields the fiber — not safe inside an FSM body
    # FSM-mode templates (Phase B2-IO): split the suspend across two
    # state machine steps. fsm_setup runs at the call site BEFORE the
    # WaitForLock yield; fsm_finish is the expression bound to the
    # result var on resume (nil for Void).
    #
    # The setup queues the FSM on fsm_sleeping_queue with a wake
    # time; the resume fn must immediately return WaitForLock so the
    # scheduler treats the FSM as Blocked. The slow-path scan in
    # run() re-enqueues to fsm_ready_queue when fsm_wake_time is
    # reached.
    # FSM templates as op trees (FsmOps DSL). One setup op registers
    # the FSM on fsm_sleeping_queue with a wake time; finish_value
    # is nil because sleep returns Void.
    fsm_setup: [
      FO.stmt_call(
        FO.ctx_fn(["rt", "getSched()", "fsmSleepTask"]),
        [
          # `task` is a `*FsmTask` (slab-allocated; the ctx holds the
          # pointer), so pass it directly — no `&` wrapper.
          FO.state("task"),
          FO.binop("+",
                   FO.call(FO.fn("CheatHeader.milliTimestamp"), []),
                   FO.intcast("i64", FO.arg(0))),
        ],
      ),
    ],
    fsm_finish_value: nil,
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
}, T::Hash[String, T.untyped])

# ============================================================================
# Method Registry — type-specific method definitions for Pool and HashMap
# ============================================================================
# Each entry: { arity: N, validate: lambda, return_type: <directive>, tag: symbol }
#   arity:       expected arg count (-1 = any)
#   validate:    lambda(node, args, obj_type, error_fn) — type-check args
#   return_type: declarative return directive (a type Symbol/Hash, an
#                r_* receiver-parametric variant, or an infer_* host
#                method) -> FunctionReturn via IntrinsicRegistry
#   tag:         symbol to set on the node (pool_method / map_method)

POOL_METHODS = T.let({
  "insert" => {
    arity: 1, tag: :pool_method, allocates: true,
    mutates_receiver: true,
    narrows_receiver_collection: true,
    bc: true,
    takes_args: [0],  # Pool.insert takes ownership of the value
    zig: "try {0}.insert({alloc}, {1})",
    alloc: :receiver_storage,
    args: [:"Any[]", { type: :Any, takes: true }],
    validate: ->(node, args, obj_type, error_fn) {
      elem = obj_type.element_type
      arg_type = args[0].resolved_type
      unless arg_type == :Any || arg_type == elem.resolved || Type.new(elem.resolved).accepts?(Type.new(arg_type))
        error_fn.call(node, "Pool.insert: argument type #{arg_type} does not match pool element type #{elem.resolved}")
      end
    },
    return_type: :r_id_element,
    is_method: true,
  },
  "get" => {
    arity: 1, tag: :pool_method,
    bc: true,
    zig: "{0}.get({1})",
    return_type: :r_optional_element,
    container_borrow: true,
    borrows: :all,  # returns borrowed pointer into pool storage,
    is_method: true,
  },
  "remove" => {
    arity: 1, tag: :pool_method,
    bc: true,
    zig: "{0}.remove({1})",
    mutates_receiver: true,
    return_type: :Void,
    borrows: :all,  # pool frees the slot internally,
    is_method: true,
  },
  "length" => {
    arity: 0, tag: :pool_method,
    bc: true,
    zig: "{0}.length()",
    return_type: :Int64,
    borrows: :all,
    is_method: true,
  },
  "contains?" => {
    arity: 1, tag: :pool_method,
    bc: true,
    zig: "({0}.get({1}) != null)",
    return_type: :Bool,
    borrows: :all,
    is_method: true,
  },
  "empty?" => {
    arity: 0, tag: :pool_method,
    bc: true,
    zig: "({0}.length() == 0)",
    return_type: :Bool,
    borrows: :all,
    is_method: true,
  },
  "any?" => {
    arity: 0, tag: :pool_method,
    bc: true,
    zig: "({0}.length() > 0)",
    return_type: :Bool,
    borrows: :all,
    is_method: true,
  },
}.freeze, T::Hash[String, T.untyped])

class StdLibGlobalBinding < T::Struct
  const :name, String
  const :type, Type::TypeInput
  const :storage, Symbol
end

class StdLibTypeBinding < T::Struct
  const :name, Symbol
  const :schema_factory, T.proc.returns(T.untyped)
end

BUILTIN_GLOBAL_BINDINGS = T.let([
  StdLibGlobalBinding.new(name: "argv", type: Type::STRING_TYPE, storage: :heap),
].freeze, T::Array[StdLibGlobalBinding])

BUILTIN_TYPE_BINDINGS = T.let([
  StdLibTypeBinding.new(
    name: :Range,
    schema_factory: -> {
      Schemas::StructSchema.new(fields: {
        "start" => AST::StructField.new(type: :Float64),
        "end"   => AST::StructField.new(type: :Float64),
      })
    }
  ),
  StdLibTypeBinding.new(
    name: :File,
    schema_factory: -> {
      Schemas::ResourceSchema.new(
        close_plan: Schemas::ResourceClosePlan.method("close"),
        static_methods: {
          "open" => {
            args: [:String], return: :File, zig: "try CheatLib.fileOpen({0})",
            bc: true, bc_op: :file_open, can_fail: true
          },
          "create" => {
            args: [:String], return: :File, zig: "try CheatLib.fileCreate({0})",
            bc: true, bc_op: :file_create, can_fail: true
          }
        }
      )
    }
  ),
  StdLibTypeBinding.new(
    name: :TCPServer,
    schema_factory: -> {
      Schemas::ResourceSchema.new(
        close_plan: Schemas::ResourceClosePlan.function("CheatLib.socketClose"),
        static_methods: {
          "listen" => {
            args: [:Int64], return: :TCPServer,
            zig: "try CheatLib.socketListen(@intCast({0}))", can_fail: true
          }
        }
      )
    }
  ),
  StdLibTypeBinding.new(
    name: :TCPClient,
    schema_factory: -> {
      Schemas::ResourceSchema.new(
        close_plan: Schemas::ResourceClosePlan.function("CheatLib.socketClose"),
        static_methods: {
          "connect" => {
            args: [:String, :Int64], return: :TCPClient,
            zig: "try CheatLib.socketConnect({0}, @intCast({1}))", can_fail: true
          }
        }
      )
    }
  ),
].freeze, T::Array[StdLibTypeBinding])

SET_METHODS = T.let({
  "insert" => {
    arity: 1, tag: :set_method, allocates: true,
    zig: "try {0}.insert({alloc}, {1})",
    bc: true,
    alloc: :receiver_storage,
    mutates_receiver: true,
    narrows_receiver_collection: true,
    takes_args: [0],
    args: [:"Any[]", { type: :Any, takes: true }],
    validate: ->(node, args, obj_type, error_fn) {
      elem = obj_type.element_type
      arg_type = args[0].resolved_type
      unless arg_type == :Any || arg_type == elem.resolved || Type.new(elem.resolved).accepts?(Type.new(arg_type))
        error_fn.call(node, "Set.insert: argument type #{arg_type} does not match set element type #{elem.resolved}")
      end
    },
    return_type: :Void,
    is_method: true,
  },
  "contains?" => {
    arity: 1, tag: :set_method,
    zig: "{0}.contains({1})",
    bc: true,
    return_type: :Bool,
    borrows: :all,
    is_method: true,
  },
  "remove" => {
    arity: 1, tag: :set_method,
    zig: "{0}.remove({alloc}, {1})",
    bc: true,
    alloc: :heap,
    mutates_receiver: true,
    return_type: :Void,
    borrows: :all,  # set frees the element internally,
    is_method: true,
  },
  "length" => {
    arity: 0, tag: :set_method,
    zig: "CheatLib.len({0})",
    bc: true,
    return_type: :Int64,
    borrows: :all,
    is_method: true,
  },
  "empty?" => {
    arity: 0, tag: :set_method,
    zig: "({0}.length() == 0)",
    bc: true,
    return_type: :Bool,
    borrows: :all,
    is_method: true,
  },
  "any?" => {
    arity: 0, tag: :set_method,
    zig: "({0}.length() > 0)",
    bc: true,
    return_type: :Bool,
    borrows: :all,
    is_method: true,
  },
}.freeze, T::Hash[String, T.untyped])

MAP_METHODS = T.let({
  "put" => {
    arity: 2, tag: :map_method, allocates: true,
    mutates_receiver: true,
    bc: true,
    takes_args: [1],  # value (arg 1) is TAKES
    zig: "try {0}.put({alloc}, {alloc}, {1}, {2})",
    alloc: :receiver_storage,
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
    return_type: :Void,
    is_method: true,
  },
  "delete" => {
    arity: 1, tag: :map_method,
    bc: true,
    zig: "{0}.remove({alloc}, {1})",
    alloc: :receiver_storage,
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
    return_type: :Void,
    borrows: :all,  # map frees key+value internally,
    is_method: true,
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
    return_type: :Bool,
    borrows: :all,
    is_method: true,
  },
  "count" => {
    arity: 0, tag: :map_method,
    zig: "{0}.count()",
    bc: true,
    numeric_zig: "CheatLib.numericMapCount({key_zig}, {val_zig}, {0})",
    return_type: :Int64,
    borrows: :all,
    is_method: true,
  },
  "length" => {
    arity: 0, tag: :map_method,
    zig: "{0}.count()",
    bc: true,
    numeric_zig: "CheatLib.numericMapCount({key_zig}, {val_zig}, {0})",
    return_type: :Int64,
    borrows: :all,
    is_method: true,
  },
  "keys" => {
    arity: 0, tag: :map_method, allocates: true,
    bc: true,
    zig: "try CheatLib.mapKeys({val_zig}, {alloc}, {0}.inner)",
    alloc: :node_storage,
    sharded_zig: "try {0}.keys({alloc})",
    sharded_alloc: :heap,
    numeric_zig: "try CheatLib.numericMapKeys({key_zig}, {val_zig}, {alloc}, {0})",
    # `.keys()` allocates an owned ArrayList via the supplied
    # allocator and transfers ownership to the caller. The declared
    # return type must reflect that: `K[]@list` (ArrayList of the
    # map's key type). Returning a slice would let the annotator
    # silently accept assignments to a `K[]@list` local while the
    # cleanup template still expects ArrayList, producing a Zig
    # type-mismatch in CheatLib.cleanup at the binding's defer site.
    # For string-keyed HashMap<V>, key_type defaults to String;
    # numeric maps return e.g. `Int64[]@list`.
    return_type: :r_key_list,
    borrows: :all,  # borrows map; returns new owned list,
    is_method: true,
  },
  # `.any?` — true iff the map has at least one entry.
  # Lowers to `count() > 0` because the count is an O(1) cached
  # field on ArrayHashMap; querying keys/values would allocate.
  "empty?" => {
    arity: 0, tag: :map_method,
    zig: "({0}.count() == 0)",
    bc: true,
    numeric_zig: "(CheatLib.numericMapCount({key_zig}, {val_zig}, {0}) == 0)",
    return_type: :Bool,
    borrows: :all,
    is_method: true,
  },
  "any?" => {
    arity: 0, tag: :map_method,
    zig: "({0}.count() > 0)",
    bc: true,
    numeric_zig: "(CheatLib.numericMapCount({key_zig}, {val_zig}, {0}) > 0)",
    return_type: :Bool,
    borrows: :all,
    is_method: true,
  },
  "values" => {
    arity: 0, tag: :map_method, allocates: true,
    bc: true,
    zig: "try CheatLib.mapValues({val_zig}, {alloc}, {0}.inner)",
    alloc: :node_storage,
    sharded_zig: "try {0}.values({alloc})",
    sharded_alloc: :heap,
    numeric_zig: "try CheatLib.numericMapValues({key_zig}, {val_zig}, {alloc}, {0})",
    # See the matching note on `keys`: this allocates an owned list,
    # so the declared type must be `T[]@list`, not the bare slice.
    return_type: :r_value_list,
    borrows: :all,  # borrows map; returns new owned list,
    is_method: true,
  },
}.freeze, T::Hash[String, T.untyped])

MAP_METHOD_ALIASES = T.let({ "insert" => "put" }.freeze, T::Hash[String, String])

# ============================================================================
# Index Operations Registry — container[key] get/set semantics
# ============================================================================
# Keyed by container kind (:string_map, :numeric_map, :array, :pool, :set_collection).
# Each entry has :get and/or :set with:
#   zig:               Zig pattern string ({target}, {index}, {value}, {alloc}, {key_alloc}, etc.)
#   return_type:       declarative return directive (r_* variant / type) for get
#   container_borrow:  true if get returns a borrowed view (no cleanup)
#   takes_value:       true if set takes ownership of the value
#   allocates:         true if set requires an allocator
#
# Allocator symbols for :set entries:
#   :heap              always rt.heapAlloc()
#   :frame             always rt.frameAlloc()
#   :receiver_storage  heap if escaped/provenance/sharded/striped, frame otherwise
#
INDEX_OPS = T.let({
  string_map: {
    get: {
      zig: "{target}.get({index})",
      shard_direct_zig: "{target}.getDirect({shard_idx}, {shard_key})",
      return_type: :r_optional_value,
      container_borrow: true,
      bc: true, bc_op: :map_get,
    },
    set: {
      zig: "try {target}.put({key_alloc}, {val_alloc}, {index}, {value})",
      takes_value: true,
      allocates: true,
      key_alloc: :receiver_storage,
      val_alloc: :receiver_storage,
      shard_direct_zig: "try {target}.putDirect({shard_idx}, {shard_alloc}, {shard_key}, {value})",
      shard_alloc: :heap,
      bc: true, bc_op: :map_set,
    },
  },
  numeric_map: {
    get: {
      zig: "CheatLib.numericMapGet({key_zig}, {val_zig}, {target}, {index})",
      sharded_zig: "{target}.get({index})",
      shard_direct_zig: "{target}.getDirect({shard_idx}, {shard_key})",
      return_type: :r_optional_value,
      container_borrow: true,
      bc: true, bc_op: :map_get,
    },
    set: {
      zig: "try CheatLib.numericMapPut({key_zig}, {val_zig}, {alloc}, &{target}, {index}, {value})",
      takes_value: true,
      allocates: true,
      alloc: :receiver_storage,
      sharded_zig: "try {target}.put({alloc}, {alloc}, {index}, {value})",
      shard_direct_zig: "try {target}.putDirect({shard_idx}, {shard_alloc}, {shard_key}, {value})",
      shard_alloc: :heap,
      bc: true, bc_op: :map_set,
    },
  },
  array: {
    get: {
      zig: "CheatLib.getAt({target}, {index})",
      return_type: :r_element_of,
      container_borrow: true,
    },
    set: {
      zig: "CheatLib.setAt({target}, {index}, {value})",
      takes_value: true,
      val_alloc: :receiver_storage,
    },
  },
  list: {
    get: {
      zig: "CheatLib.getAtOpt({target}, {index})",
      builtin: :getAtOpt,
      return_type: :r_optional_element,
      container_borrow: true,
    },
    set: {
      zig: "CheatLib.setAt({target}, {index}, {value})",
      takes_value: true,
      val_alloc: :receiver_storage,
    },
  },
  pool: {
    get: {
      zig: "{target}.get({index})",
      return_type: :r_optional_element,
      container_borrow: true,
    },
    set: {
      zig: "try {target}.insert({alloc}, {value})",
      takes_value: true,
      allocates: true,
      alloc: :heap,
    },
  },
  set_collection: {
    get: {
      zig: "if ({target}.contains({index})) {index} else null",
      return_type: :r_optional_element,
      container_borrow: true,
    },
    set: {
      zig: "try {target}.insert({alloc}, {value})",
      takes_value: true,
      allocates: true,
      alloc: :heap,
    },
  },
  string_raw: {
    get: {
      # O(1) byte access on String@raw. No allocation.
      builtin: :charAt,
      return_type: {type: :String, sync: :raw},
      container_borrow: true,
    },
    # No :set — strings are immutable.
  },
  string_symbol: {
    get: {
      # Byte indexing on String@symbol — same as @raw, returns @symbol slice.
      builtin: :charAt,
      return_type: {type: :String, sync: :symbol},
      container_borrow: true,
    },
    # No :set — symbols are immutable.
  },
}.freeze, T::Hash[T.untyped, T.untyped])

# ============================================================================
# Collection Method Dispatch Configuration
#
# Maps Type#dispatch_key → { registry, tag, label }.
# `resolve_collection_method` uses this instead of an if/elsif chain so that
# new collection types only need a dispatch_key entry + this table entry.
# ============================================================================
COLLECTION_METHOD_CONFIGS = T.let({
  pool:           { registry: POOL_METHODS, tag: :pool_method,
                    label: ->(t) { "Pool<#{t.element_type.resolved}>" } },
  set_collection: { registry: SET_METHODS,  tag: :set_method,
                    label: ->(t) { "Set<#{t.element_type.resolved}>" } },
  string_map:     { registry: MAP_METHODS,  tag: :map_method,
                    label: ->(t) { "HashMap<#{t.value_type.resolved}>" } },
  numeric_map:    { registry: MAP_METHODS,  tag: :map_method,
                    label: ->(t) { "HashMap<#{t.value_type.resolved}>" } },
}.freeze, T::Hash[Symbol, T.untyped])

# ============================================================================
# Builtin Operations Registry -- CheatLib runtime functions used by operators,
# indexing, assertions, and deep copy. NOT user-callable -- emitted by the
# lowering for operators/expressions. Each entry gets attached to structural
# registry MIR nodes so the MIR checker can verify ownership.
# ============================================================================
# Pattern placeholders: {0}, {1}, {2} = positional args
# All entries implicitly borrow their args unless noted otherwise.

BUILTIN_OPS = T.let({
  # --- String comparison ---
  eql:       { zig: "CheatLib.eql({0}, {1})", bc: true, borrows: :all },
  strcmp:    { zig: "CheatLib.strcmp({0}, {1})", bc: true, borrows: :all },
  strEql:    { zig: "CheatLib.strEql({0}, {1})", bc: true, borrows: :all },
  # O(1) pointer+length comparison for String@symbol. Valid for compiler-pooled
  # static symbol literals; dynamic String@symbol values must be interned first.
  symbolEql: { zig: "({0}.ptr == {1}.ptr and {0}.len == {1}.len)", bc: true, borrows: :all },

  # --- String indexing ---
  charAt: { zig: "CheatLib.charAt({0}, {1})", bc: true, borrows: :all },

  # --- Collection indexing (fallback for non-registry paths) ---
  getAt: { zig: "CheatLib.getAt({0}, {1})", bc: true, borrows: :all },
  getAtOpt: { zig: "CheatLib.getAtOpt({0}, {1})", bc: true, bc_op: :getAt, borrows: :all },
  getAtPtrOpt: { zig: "CheatLib.getAtPtrOpt({0}, {1})", bc: true, bc_op: :getAt, borrows: :all },
  getOptionalPtr: { zig: "CheatLib.getOptionalPtr({0})", bc: false, borrows: :all },
  getNodeAt: { zig: "CheatLib.getNodeAt({0}, {1})", bc: true, bc_op: :getAt, borrows: :all },
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
    zig: "try CheatLib.concurrentBoundedSelect({0}, {1}, {2}, {3}, {4}, {5}, {6}, {7}, {8}, {9}, {10}, {11})",
    bc: true,
    allocates: true
  },
  concurrentBoundedWhere: {
    zig: "try CheatLib.concurrentBoundedWhere({0}, {1}, {2}, {3}, {4}, {5}, {6}, {7}, {8}, {9}, {10})",
    bc: true,
    allocates: true
  },
  concurrentBoundedEach: {
    zig: "try CheatLib.concurrentBoundedEach({0}, {1}, {2}, {3}, {4}, {5}, {6}, {7}, {8}, {9})",
    bc: true,
    borrows: :all
  },
  concurrentStreamSelect: {
    zig: "try CheatLib.concurrentStreamSelect({0}, {1}, {2}, {3}, {4}, {5}, {6}, {7}, {8}, {9}, {10}, {11}, {12})",
    bc: true,
    allocates: true
  },
  concurrentStreamWhere: {
    zig: "try CheatLib.concurrentStreamWhere({0}, {1}, {2}, {3}, {4}, {5}, {6}, {7}, {8}, {9}, {10}, {11})",
    bc: true,
    allocates: true
  },
  concurrentStreamEach: {
    zig: "try CheatLib.concurrentStreamEach({0}, {1}, {2}, {3}, {4}, {5}, {6}, {7}, {8}, {9}, {10}, {11})",
    bc: true,
    borrows: :all
  },
  concurrentListSelect: {
    zig: "try CheatLib.concurrentListSelect({0}, {1}, {2}, {3}, {4}, {5}, {6}, {7}, {8}, {9}, {10})",
    allocates: true
  },
  concurrentListWhere: {
    zig: "try CheatLib.concurrentListWhere({0}, {1}, {2}, {3}, {4}, {5}, {6}, {7}, {8}, {9})",
    allocates: true
  },
  concurrentListEach: {
    zig: "try CheatLib.concurrentListEach({0}, {1}, {2}, {3}, {4}, {5}, {6}, {7}, {8})",
    borrows: :all
  },
  concurrentListEachInPlace: {
    zig: "try CheatLib.concurrentListEachInPlace({0}, {1}, {2}, {3}, {4}, {5}, {6}, {7}, {8})",
    borrows: :all
  },
  concurrentListCount: {
    zig: "try CheatLib.concurrentListCount({0}, {1}, {2}, {3}, {4}, {5}, {6}, {7}, {8})",
    borrows: :all
  },
  concurrentListReduce: {
    zig: "try CheatLib.concurrentListReduce({0}, {1}, {2}, {3}, {4}, {5}, {6}, {7}, {8}, {9}, {10}, {11})",
    borrows: :all
  },
  concurrentShardedListEachInPlace: {
    zig: "try CheatLib.concurrentShardedListEachInPlace({0}, {1}, {2}, {3}, {4}, {5}, {6}, {7})",
    borrows: :all
  },
  concurrentShardedPoolEachInPlace: {
    zig: "try CheatLib.concurrentShardedPoolEachInPlace({0}, {1}, {2}, {3}, {4}, {5}, {6}, {7})",
    borrows: :all
  },
}.freeze, T::Hash[Symbol, T.untyped])
