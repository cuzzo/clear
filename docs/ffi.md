# FFI — Foreign Function Interface

CLEAR interfaces directly with Zig and C libraries via `EXTERN FN` and `EXTERN STRUCT` declarations. No wrapper files needed for simple cases — declare the types and functions in CLEAR, and the transpiler generates the correct `@import` and call code.

## What Works (v0.1)

### EXTERN STRUCT — declare native types

```clear-example
EXTERN STRUCT JsonDoc { id: Int64, data: Int64[] } FROM "json_module";
```

- Fields map directly to Zig struct fields
- Supports all CLEAR types including slices (`Int64[]`, `String`)
- Field access works: `doc.id`, `doc.data[0]`, `doc.data.length()`
- FOR loop iteration over slice fields works
- Structs are passed by value (same as CLEAR's normal convention)

### EXTERN FN — call native functions

```clear-example
EXTERN FN parseJson(content: String) RETURNS JsonDoc FROM "json_module";
EXTERN FN freeDoc(doc: JsonDoc) RETURNS Void FROM "json_module";
```

- Parameters and return types use CLEAR type syntax
- Maps directly to `module.functionName(args)` in Zig
- All EXTERN FN calls are automatically **trampolined to g0** (the OS thread stack), so native libraries with deep recursion or large stack frames work safely on fiber stacks

### EFFECTS — declare native function side effects

```clear-example
-- :alloc — inject CLEAR's frame allocator as the first native argument
EXTERN FN zigDupe(src: String) RETURNS !String EFFECTS :alloc FROM "native_utils";
```

The CLEAR declaration omits the allocator parameter — the transpiler injects `rt.frameAlloc()` automatically. The native function receives it as its first argument:

```zig
// Zig side: first param is the allocator, injected by CLEAR
pub fn zigDupe(allocator: std.mem.Allocator, src: []const u8) ![]const u8 {
    return try allocator.dupe(u8, src);
}
```

Data allocated via the injected allocator lives on the caller's frame arena and is freed automatically by arena rewind. No manual free needed in CLEAR.

**Available effects:**
| Effect | Behavior |
|--------|----------|
| `:alloc` | Inject `rt.frameAlloc()` as first argument to native function |

More effects (`:heap`, `:io`) planned for v0.2.

### Error union returns (`!T`)

```clear-example
EXTERN FN safeDivide(a: Int64, b: Int64) RETURNS !Int64 FROM "math_utils";
```

When the return type is `!T`, the transpiler:
1. Catches the native error inside the g0 trampoline
2. Propagates it to the CLEAR caller via the normal error-handling path
3. The CLEAR function's return type automatically becomes failable

Combine with `EFFECTS :alloc` for native functions that both allocate and fail:
```clear-example
EXTERN FN zigConcat(a: String, sep: String, b: String) RETURNS !String EFFECTS :alloc FROM "utils";
```

### Complete example: JSON parsing in CLEAR

Native module (`json_module.zig`):
```zig
const std = @import("std");

pub const JsonDoc = struct {
    id: i64,
    data: []const i64,
};

pub fn parseJson(content: []const u8) JsonDoc {
    // ... parse with std.json, return by value
}

pub fn freeDoc(doc: JsonDoc) void {
    // ... free the data slice
}
```

CLEAR code:
```clear-example
EXTERN STRUCT JsonDoc { id: Int64, data: Int64[] } FROM "json_module";
EXTERN FN parseJson(content: String) RETURNS JsonDoc FROM "json_module";
EXTERN FN freeDoc(doc: JsonDoc) RETURNS Void FROM "json_module";

FN processJson(content: String) RETURNS Int64 ->
    doc = parseJson(content);
    MUTABLE sum: Int64 = 0;
    FOR i IN (0_i64 ..< doc.data.length()) -> sum += doc.data[i];
    freeDoc(doc);
    RETURN sum;
END
```

The parsing happens in native Zig (fast), the iteration and summing happen in CLEAR (readable), and cleanup is explicit.

### Compilation

EXTERN modules require Zig's `-M` flag for module resolution:
```bash
# With FFI module
zig build-exe --dep json_module -Mroot=program.zig -lc switch.S onRoot.S \
    -Mjson_module=json_module.zig -O ReleaseFast
```

The benchmark runner handles this automatically — any `.zig` files in the benchmark directory are detected as FFI modules.

## What You Can Import Today

| Native pattern | CLEAR declaration | Works? |
|---------------|-------------------|--------|
| Simple function (primitives) | `EXTERN FN add(a: Int64, b: Int64) RETURNS Int64 FROM "mod"` | Yes |
| Function returning struct | `EXTERN FN parse(s: String) RETURNS MyStruct FROM "mod"` | Yes |
| Function taking struct | `EXTERN FN free(doc: MyStruct) RETURNS Void FROM "mod"` | Yes |
| Function with allocator param | `EXTERN FN dupe(s: String) RETURNS !String EFFECTS :alloc FROM "mod"` | Yes |
| Function returning error union | `EXTERN FN div(a: Int64, b: Int64) RETURNS !Int64 FROM "mod"` | Yes |
| Struct with slice fields | `EXTERN STRUCT Doc { data: Int64[] } FROM "mod"` | Yes |
| Struct field access | `doc.field`, `doc.data[i]`, `doc.data.length()` | Yes |
| Slice iteration | `FOR i IN (0 ..< doc.data.length()) -> doc.data[i]` | Yes |

## What You Can't Import Yet

| Native pattern | Why not | Planned |
|---------------|---------|---------|
| Generic types (`Parsed<T>`) | CLEAR has no generic EXTERN STRUCT | v0.2 |
| Method calls (`doc.deinit()`) | No EXTERN method syntax | v0.2 |
| Callbacks (fn pointers to CLEAR) | One-way FFI only | v0.3 |
| C header auto-parsing | Must write Zig wrapper | v0.2 |
| Functions taking `*T` (pointer) | CLEAR passes by value | v0.2 |
| Opaque types (no field layout) | EXTERN STRUCT requires fields | v0.2 |

## g0 Trampoline

All EXTERN FN calls run on the scheduler's OS thread stack (g0), not the fiber stack. This is automatic — no annotation needed. Native libraries like `std.json` (recursive descent) or C libraries calling `malloc` work safely regardless of fiber stack size.

The trampoline is a no-op when already on the OS stack (e.g., `main()` before fibers are spawned, or nested EXTERN calls).

## See Also

- `benchmarks/24_json_api/` — TCP JSON server using FFI for parsing
- `transpile-tests/ffi-integration/` — basic EXTERN FN arithmetic
- `transpile-tests/ffi-struct-test/` — EXTERN STRUCT with slice fields
- `transpile-tests/ffi-effects-test/` — EFFECTS :alloc and !T returns
