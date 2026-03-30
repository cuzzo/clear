# FFI — Foreign Function Interface

CLEAR can call native Zig and C functions via `EXTERN FN` declarations. This enables using battle-tested native libraries (JSON parsers, crypto, compression) without reimplementing them in CLEAR.

## Syntax

```clear-example
-- Declare a native function from a Zig module
EXTERN FN native_add(a: Number, b: Number) RETURNS Number FROM "native_math";

-- Declare a native struct type
EXTERN STRUCT Vec2 { x: Number, y: Number } FROM "native_math";

-- Call it like any CLEAR function
result = native_add(3.0, 4.0);
```

The `FROM "module_name"` maps to `@import("module_name")` in the generated Zig. The native module is a `.zig` file compiled alongside the CLEAR output.

## What Works (v0.1)

### Simple function calls
Functions that take primitives (`Int64`, `Float64`, `String`) and return primitives:

```clear-example
EXTERN FN parseJsonArraySum(content: String) RETURNS Int64 FROM "json_native";
EXTERN FN ensureDir(path: String) RETURNS Void FROM "json_native";
```

The native Zig module:
```zig
const std = @import("std");

pub fn ensureDir(path: []const u8) void {
    std.fs.cwd().makePath(path) catch {};
}

pub fn parseJsonArraySum(content: []const u8) i64 {
    const parsed = std.json.parseFromSlice(
        struct { id: i64, data: []const i64 },
        std.heap.c_allocator,
        content,
        .{},
    ) catch return 0;
    defer parsed.deinit();

    var sum: i64 = 0;
    for (parsed.value.data) |v| {
        sum += v;
    }
    return sum;
}
```

### EXTERN STRUCT
Import native struct layouts for type-safe field access:

```clear-example
EXTERN STRUCT Vec2 { x: Number, y: Number } FROM "native_math";
v = native_create_vec(1.0, 2.0);  -- returns Vec2
print(v.x);
```

### Compilation

EXTERN modules require Zig's `-M` flag for module resolution:
```bash
# Standard (no FFI)
zig build-exe program.zig -lc switch.S onRoot.S -O ReleaseFast

# With FFI module
zig build-exe --dep json_native -Mroot=program.zig -lc switch.S onRoot.S \
    -Mjson_native=json_native.zig -O ReleaseFast
```

The benchmark runner handles this automatically — any `.zig` files in the benchmark directory are detected as FFI modules.

## g0 Trampoline

**All EXTERN FN calls run on the scheduler's OS thread stack (g0), not the fiber stack.** This is critical because:

- Fiber stacks are 16 KB (Standard) — native libraries can easily exceed this
- Zig's `std.json.parseFromSlice` uses recursive descent, consuming significant stack
- C libraries may call `malloc` (or jemalloc) which uses 4-8 KB of stack internally

The trampoline is automatic — no annotation needed. The transpiler emits a wrapper struct that packs arguments, calls `rt.onRootStack()`, and extracts the return value. If the fiber is already on the OS stack (e.g., running in `main()` before fibers are spawned), the trampoline is a no-op.

### What the trampoline does NOT support

- **Yielding**: The trampolined function must NOT call `yield()`. This means EXTERN functions cannot do async IO (io_uring, epoll). Use CLEAR's built-in `readFile`/`writeFile`/`tcpRead` for async IO instead.
- **Frame allocator access**: EXTERN functions don't receive the `rt` parameter. They must manage their own memory (use `std.heap.c_allocator` or stack-local buffers).

## Known Limitations (v0.1)

### JSON parsing requires a "thick FFI boundary"

CLEAR cannot represent Zig's `std.json.Parsed(T)` return type — it's a generic struct with a `deinit` method and internal allocator state. The workaround: perform the full operation (parse + compute) in a single EXTERN function, returning only a primitive result.

```clear-example
-- This works: parse + sum in one native call
EXTERN FN parseJsonArraySum(content: String) RETURNS Int64 FROM "json_native";
sum = parseJsonArraySum(content);

-- This does NOT work (v0.1): can't return parsed Zig struct to CLEAR
-- EXTERN FN parseJson(content: String) RETURNS JsonDoc FROM "json_native";
```

See `benchmarks/24_json_api/` for a complete working example of a TCP JSON file server using FFI for JSON parsing. The benchmark compares CLEAR vs Go vs Rust/Tokio under concurrent load.

### No callback support

EXTERN functions cannot call back into CLEAR functions. The FFI boundary is one-way: CLEAR calls native, native returns.

### No C header parsing

CLEAR does not parse `.h` files. Native functions must be wrapped in a `.zig` module that exposes a clean interface. For C libraries, write a thin Zig wrapper that `@cImport`s the header.

## Planned (v0.2)

### Returning native arrays to CLEAR
Allow EXTERN functions to return `[]T` slices that CLEAR can iterate. Requires solving memory ownership — who frees the returned slice?

Proposed approach: EXTERN functions that return arrays accept a CLEAR allocator parameter, allocating on the caller's frame. This enables zero-copy returns with automatic cleanup via frame rewind.

### EXTERN methods on types
```clear-example
-- v0.2: methods on extern types
EXTERN STRUCT JsonDoc FROM "json_native";
EXTERN FN parse(content: String) RETURNS JsonDoc FROM "json_native";
EXTERN FN getArray(doc: JsonDoc, key: String) RETURNS Int64[] FROM "json_native";
EXTERN FN free(doc: JsonDoc) RETURNS Void FROM "json_native";
```

### Bidirectional FFI
Allow native code to call CLEAR functions (callbacks). Required for event-driven libraries and plugin architectures.

### C library integration
Direct `@cImport` support without manual Zig wrappers:
```clear-example
-- v0.2 (aspirational)
EXTERN FN compress(data: String) RETURNS String FROM C "zlib";
```
