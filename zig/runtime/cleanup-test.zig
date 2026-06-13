// cleanup-test.zig — Unit tests for CheatLib.cleanup, promote, and
// freeUnionPayload with union types containing collections.
//
// Run: cd zig && zig test cleanup-test.zig -lc switch.S onRoot.S

const std = @import("std");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = @import("runtime.zig").Runtime;
const ebr_mod = @import("../lib/ebr.zig");

// A tagged union similar to json_parser's JsonValue
const TestValue = union(enum) {
    Null: void,
    Num: f64,
    Str: []const u8,
    List: []TestValue,
    Array: std.ArrayListUnmanaged(TestValue),
    Map: CheatLib.StringMap(TestValue),
};

const StringListValue = union(enum) {
    Empty: void,
    Items: std.ArrayListUnmanaged([]const u8),
};

// `ebr` is taken as a pointer parameter so the caller owns its
// lifetime (the EbrContext is stored by-pointer inside Runtime via
// ThreadLocalEbr.context). The previous version returned the
// EbrContext by value alongside the Runtime, leaving the Runtime's
// internal `context` pointer dangling at the now-defunct
// makeRuntime() stack frame. Same issue with the frame buffer:
// `Runtime.init` heap-allocates 16 KB internally and sets
// `owns_frame_memory = true`, so deinit cleans up.
//
// CALLER MUST `rt.wireAllocator()` after receiving the returned
// Runtime — wireAllocator captures `&rt` into `rt.frame_allocator.ptr`,
// which would otherwise dangle at the moved-from location. With
// `wireAllocator` left to the caller the pointer points at the
// caller's `var rt`, which is the live address.
//
// Frame arena: 16 KB normally; 256 KB under -Dcoverage. kcov's
// per-instruction breakpoint instrumentation inflates the runtime's
// promote/cleanup recursion path enough to exhaust the 16 KB headroom
// on union-variant tests with frame-allocated strings, manifesting as
// segfaults that read like "kcov+mmap corruption". Widening the test's
// own arena leaves production sizing untouched.
fn makeRuntime(ebr: *ebr_mod.EbrContext) !Runtime {
    const arena_size: usize = if (@import("build_options").coverage) 256 * 1024 else 16384;
    return Runtime.init(std.heap.page_allocator, arena_size, ebr);
}

test "cleanup: Null variant is no-op" {
    var val = TestValue{ .Null = {} };
    CheatLib.cleanup(TestValue, std.heap.page_allocator, &val);
    // No crash = pass
}

test "cleanup: Num variant is no-op" {
    var val = TestValue{ .Num = 42.0 };
    CheatLib.cleanup(TestValue, std.heap.page_allocator, &val);
}

test "cleanup: Str variant frees heap-allocated string" {
    // cleanup frees string variants (strings are owned, non-Copy).
    const alloc = std.testing.allocator;
    const s = try alloc.dupe(u8, "hello");
    var val = TestValue{ .Str = s };
    CheatLib.cleanup(TestValue, alloc, &val);
    // cleanup freed the string - no manual free needed.
}

test "cleanup: Array variant frees backing buffer" {
    const alloc = std.testing.allocator;
    var list = std.ArrayListUnmanaged(TestValue).empty;
    try list.append(alloc, TestValue{ .Num = 1.0 });
    try list.append(alloc, TestValue{ .Num = 2.0 });
    try list.append(alloc, TestValue{ .Num = 3.0 });

    var val = TestValue{ .Array = list };
    CheatLib.cleanup(TestValue, alloc, &val);
    // If cleanup didn't free the backing, testing.allocator would detect the leak
}

test "cleanup: Map variant frees keys and backing" {
    const alloc = std.testing.allocator;
    var map = CheatLib.StringMap(TestValue){ .alloc = alloc };
    try map.put(alloc, alloc, "key1", TestValue{ .Num = 1.0 });
    try map.put(alloc, alloc, "key2", TestValue{ .Num = 2.0 });

    var val = TestValue{ .Map = map };
    CheatLib.cleanup(TestValue, alloc, &val);
    // testing.allocator checks for leaks
}

test "cleanup: nested Array with heap Str elements" {
    const alloc = std.testing.allocator;
    var list = std.ArrayListUnmanaged(TestValue).empty;

    // Add a heap-allocated string element
    const s = try alloc.dupe(u8, "heap string");
    try list.append(alloc, TestValue{ .Str = s });
    try list.append(alloc, TestValue{ .Num = 42.0 });

    var val = TestValue{ .Array = list };

    // cleanup frees everything: list backing + string elements.
    CheatLib.cleanup(TestValue, alloc, &val);
}

test "cleanup: Map with nested Array values" {
    const alloc = std.testing.allocator;
    var map = CheatLib.StringMap(TestValue){ .alloc = alloc };

    // Create a nested array value
    var inner_list = std.ArrayListUnmanaged(TestValue).empty;
    try inner_list.append(alloc, TestValue{ .Num = 1.0 });
    try inner_list.append(alloc, TestValue{ .Num = 2.0 });

    try map.put(alloc, alloc, "items", TestValue{ .Array = inner_list });
    try map.put(alloc, alloc, "count", TestValue{ .Num = 2.0 });

    var val = TestValue{ .Map = map };
    CheatLib.cleanup(TestValue, alloc, &val);
    // freeUnionPayload should recursively free the inner ArrayList
}

test "cleanup: ArrayList of unions frees element slice variants" {
    // The scheme interpreter pattern: ArrayList(Value) where Value.List
    // holds a heap-promoted []Value slice. When the ArrayList is cleaned up,
    // each element's List variant slice must be freed.
    const alloc = std.testing.allocator;
    var ebr = ebr_mod.EbrContext{};
    defer ebr.deinit(alloc);
    var arena_buf: [4096]u8 = undefined;
    var rt = try Runtime.initFromSlice(&arena_buf, &ebr, alloc, 0);
    defer rt.deinit();
    rt.wireAllocator();

    // Build an ArrayList of TestValue, each containing a List slice.
    var results = std.ArrayListUnmanaged(TestValue).empty;
    for (0..3) |i| {
        // Create a List variant with a heap slice
        const slice = try alloc.alloc(TestValue, 2);
        slice[0] = TestValue{ .Num = @as(f64, @floatFromInt(i)) };
        slice[1] = TestValue{ .Num = @as(f64, @floatFromInt(i + 10)) };
        try results.append(alloc, TestValue{ .List = slice });
    }

    // cleanup should free: the ArrayList backing + each element's List slice
    CheatLib.cleanup(std.ArrayListUnmanaged(TestValue), alloc, &results);
}

// Minimal union matching scheme's Value pattern: only Num + List (no Map/Array).
// needsCleanup returns false for this because []MinValue is not recognized.
const MinValue = union(enum) {
    Num: f64,
    List: []MinValue,
};

test "cleanup: nested MinValue.List freed by cleanup" {
    // This is the EXACT scheme leak pattern.
    // MinValue.List contains []MinValue, each element can be MinValue.List.
    // Currently LEAKS because needsCleanup(MinValue) = false.
    const alloc = std.testing.allocator;

    const inner = try alloc.alloc(MinValue, 2);
    inner[0] = MinValue{ .Num = 1.0 };
    inner[1] = MinValue{ .Num = 2.0 };

    const outer = try alloc.alloc(MinValue, 1);
    outer[0] = MinValue{ .List = inner };

    var val = MinValue{ .List = outer };
    CheatLib.cleanup(MinValue, alloc, &val);
}

test "cleanup: nested List variants recursively freed" {
    // Reproducer for scheme interpreter leak: Value.List contains []Value,
    // each element may itself be Value.List with its own heap slice.
    // cleanup(Value) must recurse into elements and free their slices.
    const alloc = std.testing.allocator;

    // Build nested structure: outer list of [inner_list_1, inner_list_2]
    const inner1 = try alloc.alloc(TestValue, 2);
    inner1[0] = TestValue{ .Num = 1.0 };
    inner1[1] = TestValue{ .Num = 2.0 };

    const inner2 = try alloc.alloc(TestValue, 1);
    inner2[0] = TestValue{ .Num = 3.0 };

    const outer = try alloc.alloc(TestValue, 2);
    outer[0] = TestValue{ .List = inner1 };
    outer[1] = TestValue{ .List = inner2 };

    var val = TestValue{ .List = outer };
    // Must free: outer slice + inner1 slice + inner2 slice = 3 allocations
    CheatLib.cleanup(TestValue, alloc, &val);
}

// ═══════════════════════════════════════════════════════════════════
// Bug reproduction tests — each tests one specific broken behavior.
// All should FAIL before the fix and PASS after.
// ═══════════════════════════════════════════════════════════════════

// --- Bug 2: HashMap.put doesn't deep-copy non-string slice variants ---

test "StringMap.put takes ownership of slice variant" {
    // put TAKES the []MinValue slice. Caller must not free it.
    const alloc = std.testing.allocator;

    var map = CheatLib.StringMap(MinValue){ .alloc = alloc };

    const slice = try alloc.alloc(MinValue, 2);
    slice[0] = MinValue{ .Num = 1.0 };
    slice[1] = MinValue{ .Num = 2.0 };

    try map.put(alloc, alloc, "items", MinValue{ .List = slice });
    // Do NOT free slice - map owns it.

    const stored = map.get("items").?;
    try std.testing.expect(stored.List.len == 2);
    try std.testing.expect(stored.List[0].Num == 1.0);

    map.deinit(alloc, alloc);
}

// --- Bug 3: HashMap.put doesn't deep-copy struct variants with slice/pointer fields ---

const LamPayload = struct {
    params: []MinValue,
    body: *MinValue,
    env_id: u64,

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        CheatLib.cleanup(MinValue, alloc, self.body);
        alloc.destroy(self.body);
        if (self.params.len > 0) alloc.free(self.params);
    }
};
const LamValue = union(enum) {
    Num: f64,
    List: []LamValue,
    Lambda: LamPayload,
};

test "BUG: StringMap.put must deep-copy struct variant slice+pointer fields" {
    // Lambda-style struct variant: params is []MinValue (slice), body is
    // *MinValue (heap pointer). Both must be duplicated on put so the
    // map owns independent copies.
    const alloc = std.testing.allocator;

    var map = CheatLib.StringMap(LamValue){ .alloc = alloc };
    defer map.deinit(alloc, alloc);

    const params = try alloc.alloc(MinValue, 2);
    params[0] = MinValue{ .Num = 5.0 };
    params[1] = MinValue{ .Num = 6.0 };
    const body = try alloc.create(MinValue);
    body.* = MinValue{ .Num = 99.0 };

    try map.put(alloc, alloc, "fn", LamValue{ .Lambda = .{
        .params = params,
        .body = body,
        .env_id = 1,
    } });

    // Do NOT free originals - map took ownership.
    const stored = map.get("fn").?;
    try std.testing.expect(std.meta.activeTag(stored) == .Lambda);
    try std.testing.expect(stored.Lambda.params.len == 2);
    try std.testing.expect(stored.Lambda.params[0].Num == 5.0);
    try std.testing.expect(stored.Lambda.body.*.Num == 99.0);
}

test "StringMap.deinit frees struct variant owned fields" {
    // put TAKES the Lambda. deinit must free params + body.
    const alloc = std.testing.allocator;

    var map = CheatLib.StringMap(LamValue){ .alloc = alloc };

    const params = try alloc.alloc(MinValue, 2);
    params[0] = MinValue{ .Num = 10.0 };
    params[1] = MinValue{ .Num = 20.0 };
    const body = try alloc.create(MinValue);
    body.* = MinValue{ .Num = 42.0 };

    try map.put(alloc, alloc, "fn", LamValue{ .Lambda = .{
        .params = params, .body = body, .env_id = 1,
    } });
    // Do NOT free originals - map owns them.
    map.deinit(alloc, alloc);
}

// --- Bug 5: Pool's freeUnionPayloadGeneric doesn't free struct variant fields ---

const PoolEnv = struct {
    vars: CheatLib.StringMap(LamValue),
};

test "BUG: Pool.deinit must free struct variant fields in HashMap values" {
    // Scheme pattern: Pool(Env) where Env.vars is StringMap(Value).
    // When a Lambda (struct variant with params: []Value, body: *Value)
    // is stored via vars.put, dupeUnionStrings deep-copies the fields.
    // Pool.deinit -> deinitFields -> freeUnionPayloadGeneric must free
    // those deep-copied fields. The Pool has its OWN copy of
    // freeUnionPayloadGeneric which is missing struct variant handling.
    const alloc = std.testing.allocator;

    var pool = try CheatLib.Pool(PoolEnv).initCapacity(alloc, 4);

    // Insert an env with a StringMap
    const env_id = try pool.insert(alloc, PoolEnv{
        .vars = CheatLib.StringMap(LamValue){ .alloc = alloc },
    });

    // Store a Lambda with heap-allocated params and body into the env's map
    const params = try alloc.alloc(MinValue, 2);
    params[0] = MinValue{ .Num = 1.0 };
    params[1] = MinValue{ .Num = 2.0 };
    const body = try alloc.create(MinValue);
    body.* = MinValue{ .Num = 99.0 };

    try pool.get(env_id).?.vars.put(alloc, alloc, "f", LamValue{ .Lambda = .{
        .params = params,
        .body = body,
        .env_id = 0,
    } });

    // Do NOT free originals - map took ownership.
    pool.deinit(alloc);
    // testing.allocator detects leaks.
}

// --- Bug 6: cleanup() on union struct variant doesn't free *T (@indirect) field ---
// NOTE: This is blocked by an annotator bug - HashMap.get() returns a by-value
// copy of a union with @indirect fields, creating shared ownership of the *T
// pointer. The annotator must prevent this (non-Copy type) before cleanup can
// safely free *T fields. See annotator specs for the illegal-state test.

test "BUG: cleanup(LamValue.Lambda) must free *MinValue body pointer" {
    // A union with an inline struct variant containing body: *MinValue
    // (the @indirect pattern). cleanup() must free the heap-allocated
    // pointer. Currently cleanup's struct handler only handles RC fields
    // and nested struct recursion - it skips single-pointer fields.
    const alloc = std.testing.allocator;

    const body = try alloc.create(MinValue);
    body.* = MinValue{ .Num = 42.0 };

    var val = LamValue{ .Lambda = .{
        .params = &.{},  // empty slice, no alloc
        .body = body,
        .env_id = 1,
    } };
    CheatLib.cleanup(LamValue, alloc, &val);
    // testing.allocator will report leak if body pointer wasn't freed.
}

test "BUG: cleanup(Lambda) with List body must not double-free shared slice" {
    // Scheme pattern: Lambda body is *Value pointing to a Value.List
    // whose []Value slice was allocated by promoteList. If the same
    // []Value slice is also cleaned up by the caller (e.g. via
    // cleanup on the parent AST list), cleanup on the Lambda's body
    // must not double-free.
    //
    // This tests that cleanup on an INDEPENDENTLY-owned *Value.List
    // body works correctly (no double-free, no leak).
    const alloc = std.testing.allocator;

    // Create a body that is Value.List with its own heap slice
    const body_items = try alloc.alloc(MinValue, 2);
    body_items[0] = MinValue{ .Num = 10.0 };
    body_items[1] = MinValue{ .Num = 20.0 };
    const body = try alloc.create(MinValue);
    body.* = MinValue{ .List = body_items };

    var val = LamValue{ .Lambda = .{
        .params = &.{},
        .body = body,
        .env_id = 1,
    } };
    // cleanup must free: body_items slice + body pointer. No double-free.
    CheatLib.cleanup(LamValue, alloc, &val);
}

// Bug 7: HashMap.get returns shallow copy sharing *T with map entry.
// This is an ILLEGAL STATE that the annotator prevents (non-Copy unions
// with @indirect fields cannot be copied by value). No Zig test needed -
// the annotator's use_after_move_spec covers this at the language level.

// --- Bug 8: HashMap deinit must free duped strings inside struct variant slice fields ---

const SchemeValue = union(enum) {
    Nil: void,
    Num: f64,
    Sym: []const u8,
    List: []SchemeValue,
    Lambda: SchemeLam,
};
const SchemeLam = struct {
    params: []SchemeValue,
    body: *SchemeValue,
    env_id: u64,

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        if (comptime CheatLib.needsCleanup(SchemeValue)) {
            for (self.params) |*e| CheatLib.cleanup(SchemeValue, alloc, e);
        }
        if (self.params.len > 0) alloc.free(self.params);
        CheatLib.cleanup(SchemeValue, alloc, self.body);
        alloc.destroy(self.body);
    }
};

test "BUG: HashMap deinit frees duped strings inside Lambda params" {
    // Scheme pattern: Lambda params is []Value containing Value.Symbol
    // elements with heap-duped strings. When the map deinits, freeStructPayload
    // must recurse into params elements and free the duped strings.
    const alloc = std.testing.allocator;

    var map = CheatLib.StringMap(SchemeValue){ .alloc = alloc };

    // Build params with string-containing union elements
    const params = try alloc.alloc(SchemeValue, 2);
    const s1 = try alloc.dupe(u8, "x");
    const s2 = try alloc.dupe(u8, "y");
    params[0] = SchemeValue{ .Sym = s1 };
    params[1] = SchemeValue{ .Sym = s2 };
    const body = try alloc.create(SchemeValue);
    body.* = SchemeValue{ .Num = 0.0 };

    // put deep-copies everything: params slice, each Sym string, body pointer
    try map.put(alloc, alloc, "f", SchemeValue{ .Lambda = .{
        .params = params,
        .body = body,
        .env_id = 0,
    } });

    // Do NOT free originals - map took ownership.
    // Sym strings inside params are duped by dupeStringsOnly on put.
    // But params/body are taken by move, not copied.
    // deinit frees: key + params slice + body pointer + duped Sym strings.
    map.deinit(alloc, alloc);
}

test "BUG: Pool deinit frees COPY'd Value.Sym stored via put" {
    // Scheme pattern: envGet returns COPY of a Value from HashMap.
    // The COPY dupes strings inside the Value. The COPY'd Value is then
    // stored into another HashMap (pool[callId].vars[pname] = COPY val).
    // put uses dupeStringsOnly which dupes the string AGAIN.
    // deinit must free the dupeStringsOnly dupe. The COPY's dupe leaks
    // because nobody frees it.
    const alloc = std.testing.allocator;

    var map = CheatLib.StringMap(SchemeValue){ .alloc = alloc };

    // Simulate COPY: deep-copy a Sym value (dupes the string)
    const original = SchemeValue{ .Sym = "hello" };
    const copied = CheatLib.dupeUnionValue(SchemeValue, original, alloc) catch original;

    // Store the COPY'd value into the map (put dupes strings again via dupeStringsOnly)
    try map.put(alloc, alloc, "x", copied);

    // deinit must free: key + the dupeStringsOnly'd string.
    // But what about the COPY'd string from dupeUnionValue? Nobody frees it.
    // The COPY'd string is inside `copied.Sym` which was overwritten by
    // dupeStringsOnly in put. The original COPY'd string leaks.
    map.deinit(alloc, alloc);
}

const SchemeEnv = struct {
    vars: CheatLib.StringMap(SchemeValue),
};

test "BUG: Pool deinit frees duped strings inside Lambda params in HashMap values" {
    // Same as Bug 8 but through Pool(Env) -> Env.vars HashMap.
    // Pool.freeStructPayloadPool was passing @TypeOf(value) (struct type)
    // to freeUnionPayloadGeneric instead of ElemT (union element type),
    // causing it to return immediately without freeing duped strings.
    const alloc = std.testing.allocator;

    var pool = try CheatLib.Pool(SchemeEnv).initCapacity(alloc, 4);

    const env_id = try pool.insert(alloc, SchemeEnv{
        .vars = CheatLib.StringMap(SchemeValue){ .alloc = alloc },
    });

    const params = try alloc.alloc(SchemeValue, 2);
    const s1 = try alloc.dupe(u8, "x");
    const s2 = try alloc.dupe(u8, "y");
    params[0] = SchemeValue{ .Sym = s1 };
    params[1] = SchemeValue{ .Sym = s2 };
    const body = try alloc.create(SchemeValue);
    body.* = SchemeValue{ .Num = 0.0 };

    try pool.get(env_id).?.vars.put(alloc, alloc, "f", SchemeValue{ .Lambda = .{
        .params = params, .body = body, .env_id = 0,
    } });

    // Do NOT free originals - map took ownership.
    pool.deinit(alloc);
}

test "cleanup: owned slice of tagged unions frees elements and buffer" {
    const alloc = std.testing.allocator;

    var buf = try alloc.alloc(TestValue, 2);
    buf[0] = TestValue{ .Str = try alloc.dupe(u8, "hello") };
    buf[1] = TestValue{ .Str = try alloc.dupe(u8, "world") };

    // cleanup([]TestValue, ...) must free each element's string then free the buffer.
    CheatLib.cleanup([]TestValue, alloc, &buf);
}

test "dupeUnionValue deep-copies string variant independently" {
    const alloc = std.testing.allocator;

    const original = TestValue{ .Str = try alloc.dupe(u8, "hello") };
    const copied = try CheatLib.dupeUnionValue(TestValue, original, alloc);

    try std.testing.expectEqualStrings("hello", copied.Str);
    try std.testing.expect(copied.Str.ptr != original.Str.ptr);

    // Clean up both independently - no double-free if deep copy worked.
    var orig_mut = original;
    CheatLib.cleanup(TestValue, alloc, &orig_mut);
    var copy_mut = copied;
    CheatLib.cleanup(TestValue, alloc, &copy_mut);
}

test "dupeValue deep-copies union ArrayList string payload elements independently" {
    const alloc = std.testing.allocator;

    var items = std.ArrayListUnmanaged([]const u8).empty;
    try items.append(alloc, try alloc.dupe(u8, "a"));
    try items.append(alloc, try alloc.dupe(u8, "b"));

    const original = StringListValue{ .Items = items };
    const copied = try CheatLib.dupeValue(StringListValue, original, alloc);

    try std.testing.expectEqual(@as(usize, 2), copied.Items.items.len);
    try std.testing.expectEqualStrings("a", copied.Items.items[0]);
    try std.testing.expectEqualStrings("b", copied.Items.items[1]);
    try std.testing.expect(copied.Items.items.ptr != original.Items.items.ptr);
    try std.testing.expect(copied.Items.items[0].ptr != original.Items.items[0].ptr);
    try std.testing.expect(copied.Items.items[1].ptr != original.Items.items[1].ptr);

    var original_mut = original;
    CheatLib.cleanup(StringListValue, alloc, &original_mut);
    var copied_mut = copied;
    CheatLib.cleanup(StringListValue, alloc, &copied_mut);
}

// Recursive union type similar to the interpreter's Value (17 variants,
// @indirect pointers, slices of self). needsCleanup must handle this
// without exceeding comptime branch limits.
const RecValue_Pair = struct { car: *RecValue, cdr: *RecValue };
const RecValue_Lambda = struct { params: []RecValue, body: *RecValue, env_id: u64 };
const RecValue_Tco = struct { ast: *RecValue, env_id: u64 };
const RecValue_Error = struct { msg: []const u8, kind: []const u8 };
const RecValue = union(enum) {
    Nil: void,
    TrueVal: void,
    FalseVal: void,
    Number: f64,
    Str: []const u8,
    Symbol: []const u8,
    List: []RecValue,
    Vector: []RecValue,
    Pair: RecValue_Pair,
    Lambda: RecValue_Lambda,
    NativeFn: i64,
    EnvRef: u64,
    Tco: RecValue_Tco,
    Error: RecValue_Error,
    Int64Val: i64,
    TypedI64Arr: []i64,
    TypedF64Arr: []f64,
};

test "needsCleanup: recursive union with 17 variants compiles" {
    // This test verifies needsCleanup handles deeply recursive types
    // without exceeding comptime branch limits. If it compiles, it passes.
    try std.testing.expect(CheatLib.needsCleanup(RecValue));
    try std.testing.expect(CheatLib.needsCleanup([]RecValue));
    try std.testing.expect(CheatLib.needsCleanup(RecValue_Lambda));
    try std.testing.expect(CheatLib.needsCleanup(RecValue_Pair));
}

// cleanupAlloc + the mixed-provenance test were removed: escape analysis now
// promotes any frame container that would receive heap-owned elements
// to heap at the binding site, so the "mixed-provenance" scenario this
// test simulated cannot arise in compiler output. tools/audit_provenance_mismatch
// pins this invariant across the transpile-test corpus.

test "cleanup: recursive union Str variant" {
    const alloc = std.testing.allocator;
    var val = RecValue{ .Str = try alloc.dupe(u8, "test") };
    CheatLib.cleanup(RecValue, alloc, &val);
}

test "cleanup: recursive union slice" {
    const alloc = std.testing.allocator;
    var buf = try alloc.alloc(RecValue, 2);
    buf[0] = RecValue{ .Str = try alloc.dupe(u8, "a") };
    buf[1] = RecValue{ .Number = 42.0 };
    CheatLib.cleanup([]RecValue, alloc, &buf);
}

test "CapturedValue: only *const (borrow) strips; *T / value / slice passthrough" {
    const LI = std.ArrayListUnmanaged(i64);
    try std.testing.expect(CheatLib.CapturedValue(*const LI) == LI);
    try std.testing.expect(CheatLib.CapturedValue(*LI) == *LI);
    try std.testing.expect(CheatLib.CapturedValue(LI) == LI);
    try std.testing.expect(CheatLib.CapturedValue([]const u8) == []const u8);
}

test "dupeCaptured: borrowed @list param deep-copies into an independent owned list" {
    const LI = std.ArrayListUnmanaged(i64);
    const alloc = std.testing.allocator;

    var src = LI.empty;
    defer src.deinit(alloc);
    try src.append(alloc, 1);
    try src.append(alloc, 2);
    try src.append(alloc, 3);

    const sp: *const LI = &src;
    var dup = try CheatLib.dupeCaptured(*const LI, sp, alloc);
    defer dup.deinit(alloc);

    try std.testing.expect(@TypeOf(dup) == LI);
    try std.testing.expectEqual(@as(usize, 3), dup.items.len);
    try std.testing.expectEqualSlices(i64, &[_]i64{ 1, 2, 3 }, dup.items);
    dup.items[0] = 99;
    try std.testing.expectEqual(@as(i64, 1), src.items[0]);
}

test "dupeCaptured: owned-value source path matches dupeValue (no regression)" {
    const LI = std.ArrayListUnmanaged(i64);
    const alloc = std.testing.allocator;
    var src = LI.empty;
    defer src.deinit(alloc);
    try src.append(alloc, 7);

    var dup = try CheatLib.dupeCaptured(LI, src, alloc);
    defer dup.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), dup.items.len);
    try std.testing.expectEqual(@as(i64, 7), dup.items[0]);
}
