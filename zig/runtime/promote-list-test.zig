// promote-list-test.zig
// Unit tests for CheatLib.promoteList — list escape safety.
//
// Tests focus on the contract of promoteList: items are copied to heap,
// values are preserved, and capacity equals items.len.
//
// The full frame-rewind survival guarantee is exercised by the end-to-end
// integration test transpile-tests/90_list_return.cht.
//
// Run with:
//   zig test zig/promote-list-test.zig -lc zig/switch.S zig/onRoot.S
const std = @import("std");
const Header = @import("runtime-header.zig");
const CheatLib = Header.CheatLib;
const Runtime = Header.Runtime;
const EbrContext = Header.EbrContext;

// ---------------------------------------------------------------------------
// promoteList: empty list is a no-op (no allocation)
// ---------------------------------------------------------------------------
test "promoteList on empty list is a no-op" {
    const alloc = std.testing.allocator;
    var ctx = EbrContext{};
    defer ctx.deinit(alloc);
    var rt = try Runtime.init(alloc, 1024 * 1024, &ctx);
    defer rt.deinit();
    rt.wireAllocator();

    var list = std.ArrayListUnmanaged(f64){};
    // Empty list: promoteList should do nothing (no heap allocation).
    try CheatLib.promoteList(f64, &rt, &list);

    try std.testing.expectEqual(@as(usize, 0), list.items.len);
    try std.testing.expectEqual(@as(usize, 0), list.capacity);
}

// ---------------------------------------------------------------------------
// promoteList: simulates arena→heap promotion using a stack-backed buffer.
// Builds the initial backing store on the stack (simulating arena memory),
// then promotes to heap and verifies values survive.
// ---------------------------------------------------------------------------
test "promoteList copies items to heap with correct values" {
    const alloc = std.testing.allocator;
    var ctx = EbrContext{};
    defer ctx.deinit(alloc);
    var rt = try Runtime.init(alloc, 1024 * 1024, &ctx);
    defer rt.deinit();
    rt.wireAllocator();

    // Simulate an arena-backed list using a stack buffer as initial storage.
    // (Mimics frameAlloc backing without requiring a live scheduler.)
    var arena_buf = [_]f64{ 1.0, 2.0, 3.0 };
    var list = std.ArrayListUnmanaged(f64){
        .items = arena_buf[0..3],
        .capacity = 3,
    };
    // After promotion the backing buffer moves to heap; use heapAlloc for deinit.
    defer list.deinit(rt.heapAlloc());

    // promoteList copies the stack buffer to heap and updates list.items.
    try CheatLib.promoteList(f64, &rt, &list);

    // Stack buffer is no longer referenced by list.items; list is heap-backed.
    try std.testing.expectEqual(@as(usize, 3), list.items.len);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), list.items[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), list.items[1], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), list.items[2], 1e-9);
    // Capacity equals len — exact-fit allocation, no wasted space.
    try std.testing.expectEqual(list.items.len, list.capacity);
}
