# FFI — Foreign Function Interface

CLEAR interfaces directly with Zig and C libraries via `EXTERN FN` and `EXTERN STRUCT` declarations. Declare the types and functions in CLEAR, and the transpiler generates the correct `@import` and call code.

## EXTERN STRUCT — declare native types

```ruby clear illustrative
EXTERN STRUCT JsonDoc { id: Int64, data: Int64[] } FROM "json_module";
```

- Fields map directly to Zig struct fields
- Supports all CLEAR types including slices (`Int64[]`, `String`)
- Field access works: `doc.id`, `doc.data[0]`, `doc.data.length()`
- FOR loop iteration over slice fields works
- Structs are passed by value

### CLOSE — auto-cleanup via RAII

```ruby clear illustrative
EXTERN STRUCT Buffer { data: String } CLOSE "deinit" FROM "native_resource";
```

`CLOSE "method"` registers the EXTERN STRUCT as a resource type. When a variable goes out of scope, CLEAR auto-emits `defer obj.deinit()`. The full RAII system works:

- **Scope exit:** `defer buf.deinit()` emitted automatically
- **Move tracking:** `buf_moved = true` suppresses defer when ownership transfers
- **BG capture:** fiber inherits cleanup responsibility when resource is captured
- **Return:** `RETURN buf` transfers ownership to caller, skips local defer

No manual cleanup needed — same behavior as built-in `File` and `TCPClient`.

## EXTERN FN — call native functions

```ruby clear illustrative
EXTERN FN parseJson(content: String) RETURNS JsonDoc FROM "json_module";
EXTERN FN freeDoc(doc: JsonDoc) RETURNS Void FROM "json_module";
```

- Parameters and return types use CLEAR type syntax
- Maps directly to `module.functionName(args)` in Zig
- All EXTERN FN calls are **trampolined to g0** (the OS thread stack) automatically

### Error union returns (`!T`)

```ruby clear illustrative
EXTERN FN safeDivide(a: Int64, b: Int64) RETURNS !Int64 FROM "math_utils";
```

When the return type is `!T`, the transpiler catches the native error inside the g0 trampoline and propagates it to the CLEAR caller.

### EFFECTS — automatic allocator injection

```ruby clear illustrative
EXTERN FN zigDupe(src: String) RETURNS !String EFFECTS :alloc FROM "utils";
EXTERN FN zigDupe(src: String) RETURNS !String EFFECTS :alloc:frame FROM "utils";
EXTERN FN heapDupe(src: String) RETURNS !String EFFECTS :alloc:heap FROM "utils";
```

The CLEAR declaration omits the allocator parameter — the transpiler injects `rt.frameAlloc()` or `rt.heapAlloc()` as the first argument to the native function automatically.

| Effect | Behavior |
|--------|----------|
| `:alloc` or `:alloc:frame` | Inject `rt.frameAlloc()` — data freed by arena rewind |
| `:alloc:heap` | Inject `rt.heapAlloc()` — data persists until explicitly freed |

Combine with `!T` for native functions that both allocate and fail:

```ruby clear illustrative
EXTERN FN zigConcat(a: String, sep: String, b: String) RETURNS !String EFFECTS :alloc FROM "utils";
```

## Complete example: JSON parsing with RAII

Native module (`json_native.zig`):

```zig
const std = @import("std");

pub const JsonDoc = struct {
    id: i64,
    data: []const i64,
};

pub fn parseJson(content: []const u8) JsonDoc {
    // parse with std.json, dupe data, return by value
}

pub fn freeDoc(doc: JsonDoc) void {
    // free the data slice
}
```

CLEAR code — iteration and summing in CLEAR, cleanup is automatic:

```ruby clear illustrative
EXTERN STRUCT JsonDoc { id: Int64, data: Int64[] } FROM "json_native";
EXTERN FN parseJson(content: String) RETURNS JsonDoc FROM "json_native";
EXTERN FN freeDoc(doc: JsonDoc) RETURNS Void FROM "json_native";

FN processJson(content: String) RETURNS Int64 ->
    doc = parseJson(content);
    MUTABLE sum: Int64 = 0;
    FOR i IN (0_i64 ..< doc.data.length()) -> sum += doc.data[i];
    freeDoc(doc);
    RETURN sum;
END
```

With `CLOSE`, the `freeDoc` call becomes unnecessary:

```ruby clear illustrative
EXTERN STRUCT JsonDoc { id: Int64, data: Int64[] } CLOSE "freeDoc" FROM "json_native";
EXTERN FN parseJson(content: String) RETURNS JsonDoc FROM "json_native";

FN processJson(content: String) RETURNS Int64 ->
    doc = parseJson(content);     -- auto: defer doc.freeDoc()
    MUTABLE sum: Int64 = 0;
    FOR i IN (0_i64 ..< doc.data.length()) -> sum += doc.data[i];
    RETURN sum;                   -- cleanup runs automatically
END
```

## What You Can Import

| Pattern | CLEAR declaration | Works? |
|---------|-------------------|--------|
| Simple function (primitives) | `EXTERN FN add(a: Int64, b: Int64) RETURNS Int64 FROM "mod"` | Yes |
| Function returning struct | `EXTERN FN parse(s: String) RETURNS MyStruct FROM "mod"` | Yes |
| Function taking struct | `EXTERN FN free(doc: MyStruct) RETURNS Void FROM "mod"` | Yes |
| Function with allocator param | `EXTERN FN dupe(s: String) RETURNS !String EFFECTS :alloc FROM "mod"` | Yes |
| Function returning error union | `EXTERN FN div(a: Int64, b: Int64) RETURNS !Int64 FROM "mod"` | Yes |
| Struct with RAII cleanup | `EXTERN STRUCT Buf { data: String } CLOSE "deinit" FROM "mod"` | Yes |
| Struct with slice fields | `EXTERN STRUCT Doc { data: Int64[] } FROM "mod"` | Yes |
| Struct field access | `doc.field`, `doc.data[i]`, `doc.data.length()` | Yes |
| Slice iteration | `FOR i IN (0 ..< doc.data.length()) -> doc.data[i]` | Yes |

## Local EXTERN STRUCT (no FROM)

For defining Zig-compatible struct layouts without an external module:

```ruby clear illustrative
-- Default options struct (empty -- Zig infers the type from context)
EXTERN STRUCT ParseOptions {};

-- Data shape for JSON deserialization
EXTERN STRUCT JsonRecord { id: Int64, data: Int64[] };
```

Local EXTERN STRUCTs emit Zig struct definitions in the transpiled output. Empty structs emit `.{}` for their literals, allowing Zig's type inference to provide default values.

## Comptime Type Parameters

Pass CLEAR types as comptime arguments to generic native functions:

```ruby clear illustrative
EXTERN FN parseFromSliceLeaky<T>(comptime: T, content: String, options: ParseOptions)
    RETURNS !T EFFECTS :alloc:heap FROM "std.json";

-- Usage: T is resolved to JsonRecord at compile time
record = parseFromSliceLeaky(JsonRecord, content, ParseOptions{}) OR_ELSE RAISE;
```

## Method Calls on EXTERN Structs

Declare methods on EXTERN types for chained calls:

```ruby clear illustrative
EXTERN STRUCT Dir {} FROM "std.fs";
EXTERN FN cwd() RETURNS Dir FROM "std.fs";
EXTERN FN Dir.makePath(self: Dir, path: String) RETURNS Void FROM "std.fs";

-- Chained call (both trampolined to g0)
cwd().makePath("data");
```

## Dotted Module Paths

Import from nested Zig modules using dotted paths:

```ruby clear illustrative
-- FROM "std.json" emits @import("std").json
EXTERN FN parseFromSliceLeaky<T>(...) FROM "std.json";

-- FROM "std.fs" emits @import("std").fs
EXTERN FN cwd() RETURNS Dir FROM "std.fs";
```

## What You Can't Import Yet

| Pattern | Why not | Planned |
|---------|---------|---------|
| Callbacks (fn pointers to CLEAR) | One-way FFI only | v0.3 |
| C header auto-parsing | Must write Zig wrapper | v0.2 |
| Functions taking `*T` (pointer) | CLEAR passes by value | v0.2 |

## g0 Trampoline

All EXTERN FN calls run on the scheduler's OS thread stack (g0), not the fiber stack. This is automatic — no annotation needed. The trampoline is a no-op when already on the OS stack.

## Compilation

EXTERN modules require Zig's `-M` flag:

```ruby clear illustrative
zig build-exe --dep json_native -Mroot=program.zig -lc switch.S onRoot.S \
    -Mjson_native=json_native.zig -O ReleaseFast
```

The benchmark runner detects `.zig` files in the benchmark directory automatically.

## See Also

- `benchmarks/server/02_json_api/` — TCP JSON server using FFI
- `transpile-tests/ffi-integration/` — EXTERN FN arithmetic
- `transpile-tests/ffi-struct-test/` — EXTERN STRUCT with slices
- `transpile-tests/ffi-effects-test/` — EFFECTS :alloc and !T returns
- `transpile-tests/ffi-close-test/` — EXTERN STRUCT CLOSE (RAII)
