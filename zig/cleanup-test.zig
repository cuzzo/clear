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
