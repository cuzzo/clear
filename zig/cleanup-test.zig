// cleanup-test.zig — Unit tests for CheatLib.cleanup, promote, and
// freeUnionPayload with union types containing collections.
//
// Run: cd zig && zig test cleanup-test.zig -lc switch.S onRoot.S

const std = @import("std");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = @import("runtime.zig").Runtime;
const ebr_mod = @import("ebr.zig");

// A tagged union similar to json_parser's JsonValue
const TestValue = union(enum) {
    Null: void,
    Num: f64,
    Str: []const u8,
    List: []TestValue,
    Array: std.ArrayListUnmanaged(TestValue),
    Map: CheatLib.StringMap(TestValue),
};

fn makeRuntime() !struct { rt: Runtime, ebr: ebr_mod.EbrContext } {
    var ebr = ebr_mod.EbrContext{};
    var arena_buf: [4096]u8 = undefined;
    var rt = try Runtime.initFromSlice(&arena_buf, &ebr, std.heap.page_allocator, 0);
    rt.wireAllocator();
    return .{ .rt = rt, .ebr = ebr };
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

test "cleanup: Str variant - string cleanup handled by StringMap.freeUnionPayload" {
    // cleanup does NOT free bare Str variants (mixed provenance).
    // String cleanup inside collections is handled by StringMap.freeUnionPayload
    // and the ArrayList element cleanup path.
    const alloc = std.testing.allocator;
    const s = try alloc.dupe(u8, "hello");
    var val = TestValue{ .Str = s };
    CheatLib.cleanup(TestValue, alloc, &val);
    // cleanup is a no-op for Str - must free manually
    alloc.free(s);
}

test "cleanup: Array variant frees backing buffer" {
    const alloc = std.testing.allocator;
    var list = std.ArrayListUnmanaged(TestValue){};
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
    var list = std.ArrayListUnmanaged(TestValue){};

    // Add a heap-allocated string element
    const s = try alloc.dupe(u8, "heap string");
    try list.append(alloc, TestValue{ .Str = s });
    try list.append(alloc, TestValue{ .Num = 42.0 });

    var val = TestValue{ .Array = list };

    // cleanup frees the list backing but not bare Str variant strings.
    // Str strings inside StringMap values ARE freed by freeUnionPayload.
    // For top-level Array, we must free manually.
    alloc.free(val.Array.items[0].Str);
    CheatLib.cleanup(TestValue, alloc, &val);
}

test "cleanup: Map with nested Array values" {
    const alloc = std.testing.allocator;
    var map = CheatLib.StringMap(TestValue){ .alloc = alloc };

    // Create a nested array value
    var inner_list = std.ArrayListUnmanaged(TestValue){};
    try inner_list.append(alloc, TestValue{ .Num = 1.0 });
    try inner_list.append(alloc, TestValue{ .Num = 2.0 });

    try map.put(alloc, alloc, "items", TestValue{ .Array = inner_list });
    try map.put(alloc, alloc, "count", TestValue{ .Num = 2.0 });

    var val = TestValue{ .Map = map };
    CheatLib.cleanup(TestValue, alloc, &val);
    // freeUnionPayload should recursively free the inner ArrayList
}

test "promote: Null variant is no-op" {
    var ctx = try makeRuntime();
    defer ctx.rt.deinit();
    defer ctx.ebr.deinit(std.heap.page_allocator);

    var val = TestValue{ .Null = {} };
    try CheatLib.promote(TestValue, &ctx.rt, &val);
}

test "promote: Str variant dupes to heap" {
    var ctx = try makeRuntime();
    defer ctx.rt.deinit();
    defer ctx.ebr.deinit(std.heap.page_allocator);

    var val = TestValue{ .Str = "frame string" };
    try CheatLib.promote(TestValue, &ctx.rt, &val);
    // After promote, val.Str should be a heap-duped copy
    try std.testing.expectEqualStrings("frame string", val.Str);
    // Free the duped string
    ctx.rt.heapAlloc().free(val.Str);
}

test "promote: Array of Str elements dupes strings to heap" {
    // promote recursively dupes strings inside union elements.
    // cleanup frees the list backing but not bare Str variants.
    var ctx = try makeRuntime();
    defer ctx.rt.deinit();
    defer ctx.ebr.deinit(std.heap.page_allocator);

    var list = std.ArrayListUnmanaged(TestValue){};
    try list.append(ctx.rt.frameAlloc(), TestValue{ .Str = "hello" });
    try list.append(ctx.rt.frameAlloc(), TestValue{ .Num = 42.0 });

    var val = TestValue{ .Array = list };
    try CheatLib.promote(TestValue, &ctx.rt, &val);

    try std.testing.expect(val.Array.items.len == 2);
    try std.testing.expectEqualStrings("hello", val.Array.items[0].Str);

    // Free promoted strings manually (cleanup doesn't handle bare Str variants)
    ctx.rt.heapAlloc().free(val.Array.items[0].Str);
    // Then cleanup frees the list backing
    CheatLib.cleanup(TestValue, ctx.rt.heapAlloc(), &val);
}

test "promote: nested Map inside Array" {
    // Scenario: array containing map values (like JSON [{...}, {...}])
    var ctx = try makeRuntime();
    defer ctx.rt.deinit();
    defer ctx.ebr.deinit(std.heap.page_allocator);

    const heap = ctx.rt.heapAlloc();
    var inner_map = CheatLib.StringMap(TestValue){ .alloc = heap };
    try inner_map.put(heap, heap, "key", TestValue{ .Num = 99.0 });

    var list = std.ArrayListUnmanaged(TestValue){};
    try list.append(ctx.rt.frameAlloc(), TestValue{ .Map = inner_map });
    try list.append(ctx.rt.frameAlloc(), TestValue{ .Num = 1.0 });

    var val = TestValue{ .Array = list };
    try CheatLib.promote(TestValue, &ctx.rt, &val);

    // Cleanup recursively frees map inside array
    CheatLib.cleanup(TestValue, heap, &val);
}

test "full cycle: promote then cleanup Array of mixed values" {
    // End-to-end: promote frame data to heap, then cleanup.
    // Strings in union variants are promoted by promote() and freed
    // when they're inside a collection (StringMap.freeUnionPayload).
    // Bare strings at the top-level Array need manual cleanup since
    // cleanup() doesn't free string union variants directly.
    const alloc = std.testing.allocator;
    var ebr = ebr_mod.EbrContext{};
    defer ebr.deinit(alloc);
    var arena_buf: [4096]u8 = undefined;
    var rt = try Runtime.initFromSlice(&arena_buf, &ebr, alloc, 0);
    defer rt.deinit();
    rt.wireAllocator();

    var list = std.ArrayListUnmanaged(TestValue){};
    try list.append(rt.frameAlloc(), TestValue{ .Num = 1.0 });
    try list.append(rt.frameAlloc(), TestValue{ .Null = {} });

    var val = TestValue{ .Array = list };
    try CheatLib.promote(TestValue, &rt, &val);
    CheatLib.cleanup(TestValue, alloc, &val);
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
    var results = std.ArrayListUnmanaged(TestValue){};
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

test "cleanup: List variant ([]T slice) is freed by cleanup" {
    // Simulates the json_parser leak: promoteList creates a heap slice
    // inside a union List variant. cleanup must free it.
    const alloc = std.testing.allocator;
    var ebr = ebr_mod.EbrContext{};
    defer ebr.deinit(alloc);
    var arena_buf: [4096]u8 = undefined;
    var rt = try Runtime.initFromSlice(&arena_buf, &ebr, alloc, 0);
    defer rt.deinit();
    rt.wireAllocator();

    // Build a List variant: ArrayList promoted to heap slice.
    var list = std.ArrayListUnmanaged(TestValue){};
    try list.append(rt.frameAlloc(), TestValue{ .Num = 1.0 });
    try list.append(rt.frameAlloc(), TestValue{ .Num = 2.0 });
    try CheatLib.promoteList(TestValue, &rt, &list);
    // Now list.items is heap-backed. Extract slice into union.
    var val = TestValue{ .List = list.items };
    // cleanup should free the List slice (and any nested union elements).
    CheatLib.cleanup(TestValue, alloc, &val);
    // If we get here without leak/double-free, the test passes.
}

test "promote: Array variant promotes backing" {
    var ctx = try makeRuntime();
    defer ctx.rt.deinit();
    defer ctx.ebr.deinit(std.heap.page_allocator);

    var list = std.ArrayListUnmanaged(TestValue){};
    try list.append(ctx.rt.frameAlloc(), TestValue{ .Num = 1.0 });
    try list.append(ctx.rt.frameAlloc(), TestValue{ .Num = 2.0 });

    var val = TestValue{ .Array = list };
    try CheatLib.promote(TestValue, &ctx.rt, &val);

    // After promote, backing is on heap - can cleanup with heapAlloc
    try std.testing.expect(val.Array.items.len == 2);
    val.Array.deinit(ctx.rt.heapAlloc());
}

// ═══════════════════════════════════════════════════════════════════
// Bug reproduction tests — each tests one specific broken behavior.
// All should FAIL before the fix and PASS after.
// ═══════════════════════════════════════════════════════════════════

// --- Bug 2: HashMap.put doesn't deep-copy non-string slice variants ---

test "BUG: StringMap.put must deep-copy Value.List slice variant" {
    // When storing MinValue.List ([]MinValue) into a HashMap, the slice
    // buffer must be duplicated so the map owns its own copy. Without
    // this, freeing the original buffer leaves the map with a dangling
    // pointer (use-after-free / segfault on access).
    const alloc = std.testing.allocator;

    var map = CheatLib.StringMap(MinValue){ .alloc = alloc };
    defer map.deinit(alloc, alloc);

    const slice = try alloc.alloc(MinValue, 2);
    slice[0] = MinValue{ .Num = 1.0 };
    slice[1] = MinValue{ .Num = 2.0 };

    try map.put(alloc, alloc, "items", MinValue{ .List = slice });

    // Free the ORIGINAL slice. If the map didn't dupe, this is use-after-free.
    alloc.free(slice);

    // Read from the map — must still be valid.
    const stored = map.get("items").?;
    try std.testing.expect(std.meta.activeTag(stored) == .List);
    try std.testing.expect(stored.List.len == 2);
    try std.testing.expect(stored.List[0].Num == 1.0);
}

// --- Bug 3: HashMap.put doesn't deep-copy struct variants with slice/pointer fields ---

const LamPayload = struct {
    params: []MinValue,
    body: *MinValue,
    env_id: u64,
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

    // Free originals. Map must have its own copies.
    alloc.free(params);
    alloc.destroy(body);

    const stored = map.get("fn").?;
    try std.testing.expect(std.meta.activeTag(stored) == .Lambda);
    try std.testing.expect(stored.Lambda.params.len == 2);
    try std.testing.expect(stored.Lambda.params[0].Num == 5.0);
    try std.testing.expect(stored.Lambda.body.*.Num == 99.0);
}

// --- Bug 4: freeUnionPayload doesn't free struct variant slice/pointer fields ---

test "BUG: StringMap.deinit must free struct variant slice+pointer fields" {
    // When a HashMap containing LamValue.Lambda entries is deinited,
    // freeUnionPayload must free the params slice and body pointer that
    // were deep-copied on put. Otherwise they leak.
    const alloc = std.testing.allocator;

    var map = CheatLib.StringMap(LamValue){ .alloc = alloc };

    const params = try alloc.alloc(MinValue, 2);
    params[0] = MinValue{ .Num = 10.0 };
    params[1] = MinValue{ .Num = 20.0 };
    const body = try alloc.create(MinValue);
    body.* = MinValue{ .Num = 42.0 };

    // put deep-copies (assuming bug 3 is fixed), so free originals.
    try map.put(alloc, alloc, "fn", LamValue{ .Lambda = .{
        .params = params,
        .body = body,
        .env_id = 1,
    } });
    alloc.free(params);
    alloc.destroy(body);

    // deinit must free the map's deep-copied params slice + body pointer.
    // If freeUnionPayload doesn't handle struct variants, these leak.
    map.deinit(alloc, alloc);
    // testing.allocator detects any leaked memory.
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

    // Free originals — map owns deep copies
    alloc.free(params);
    alloc.destroy(body);

    // Pool.deinit must free everything: map keys, map values (including
    // Lambda's deep-copied params slice and body pointer).
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

// --- Bug 7: HashMap.get returns shallow copy sharing *T with map entry ---

test "BUG: StringMap.get of struct variant with *T must not share pointer with map" {
    // Scheme pattern: put Lambda into map (deep-copies body *Value),
    // then get it back. The returned copy's body pointer must be
    // independent of the map's entry. Otherwise cleanup on the copy
    // frees the map's body, and map.deinit double-frees.
    const alloc = std.testing.allocator;

    var map = CheatLib.StringMap(LamValue){ .alloc = alloc };

    const params = try alloc.alloc(MinValue, 1);
    params[0] = MinValue{ .Num = 1.0 };
    const body = try alloc.create(MinValue);
    body.* = MinValue{ .Num = 99.0 };

    try map.put(alloc, alloc, "f", LamValue{ .Lambda = .{
        .params = params, .body = body, .env_id = 0,
    } });
    alloc.free(params);
    alloc.destroy(body);

    // get returns a copy. Cleanup on the copy must not corrupt the map.
    var got = map.get("f").?;
    CheatLib.cleanup(LamValue, alloc, &got);

    // Map must still be valid and deinit cleanly.
    map.deinit(alloc, alloc);
}

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

    // Free originals
    alloc.free(s1);
    alloc.free(s2);
    alloc.free(params);
    alloc.destroy(body);

    // deinit must free: map key + deep-copied params slice + each duped Sym
    // string inside params + deep-copied body pointer. No leaks.
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

    alloc.free(s1);
    alloc.free(s2);
    alloc.free(params);
    alloc.destroy(body);

    pool.deinit(alloc);
}
