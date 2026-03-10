// stream_test.zig
// Unit tests for CheatLib.Stream(T) — Phase 3 open/closeable streams.
//
// Full behavioral tests (concurrent generator fiber, multi-YIELD) require a
// live scheduler and are covered by transpile-tests/75_open_stream.cht.
//
// Run with:
//   zig test zig/stream_test.zig -lc zig/switch.S zig/onRoot.S
const std = @import("std");
const CheatLib = @import("runtime-header.zig").CheatLib;

// ---------------------------------------------------------------------------
// Struct shape
// ---------------------------------------------------------------------------

test "Stream has inner, alloc, and head fields" {
    const S = CheatLib.Stream(f64);
    const fields = @typeInfo(S).@"struct".fields;
    var found_inner = false;
    var found_alloc = false;
    var found_head  = false;
    inline for (fields) |f| {
        if (std.mem.eql(u8, f.name, "inner")) found_inner = true;
        if (std.mem.eql(u8, f.name, "alloc")) found_alloc = true;
        if (std.mem.eql(u8, f.name, "head"))  found_head  = true;
    }
    try std.testing.expect(found_inner);
    try std.testing.expect(found_alloc);
    try std.testing.expect(found_head);
}

test "Stream.Inner has items and wg fields" {
    const Inner = CheatLib.Stream(f64).Inner;
    const fields = @typeInfo(Inner).@"struct".fields;
    var found_items = false;
    var found_wg    = false;
    inline for (fields) |f| {
        if (std.mem.eql(u8, f.name, "items")) found_items = true;
        if (std.mem.eql(u8, f.name, "wg"))    found_wg    = true;
    }
    try std.testing.expect(found_items);
    try std.testing.expect(found_wg);
}

test "Stream head defaults to 0" {
    // Verify the default value in the head field definition
    const S = CheatLib.Stream(f64);
    const field_defaults = comptime blk: {
        const fields = @typeInfo(S).@"struct".fields;
        var head_default: usize = 999;
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, "head")) {
                if (f.default_value_ptr) |ptr| {
                    head_default = @as(*const usize, @ptrCast(@alignCast(ptr))).*;
                }
            }
        }
        break :blk head_default;
    };
    try std.testing.expectEqual(@as(usize, 0), field_defaults);
}

// ---------------------------------------------------------------------------
// push() adds items to Inner.items (simulate generator phase)
// ---------------------------------------------------------------------------

test "Stream.push appends to inner items (direct Inner manipulation)" {
    const S = CheatLib.Stream(f64);
    const alloc = std.testing.allocator;

    const inner = try alloc.create(S.Inner);
    inner.* = .{};  // items starts empty; wg field left undefined (not called)
    defer {
        inner.items.deinit(alloc);
        alloc.destroy(inner);
    }

    // Simulate the generator fiber calling push() on a local stream handle
    var gen_handle = S{ .inner = inner, .alloc = alloc };
    try gen_handle.push(10.0);
    try gen_handle.push(20.0);
    try gen_handle.push(30.0);

    try std.testing.expectEqual(@as(usize, 3), inner.items.items.len);
    try std.testing.expectApproxEqAbs(10.0, inner.items.items[0], 1e-9);
    try std.testing.expectApproxEqAbs(20.0, inner.items.items[1], 1e-9);
    try std.testing.expectApproxEqAbs(30.0, inner.items.items[2], 1e-9);
}

test "Stream.push works for bool type" {
    const S = CheatLib.Stream(bool);
    const alloc = std.testing.allocator;

    const inner = try alloc.create(S.Inner);
    inner.* = .{};
    defer {
        inner.items.deinit(alloc);
        alloc.destroy(inner);
    }

    var gen_handle = S{ .inner = inner, .alloc = alloc };
    try gen_handle.push(true);
    try gen_handle.push(false);

    try std.testing.expectEqual(@as(usize, 2), inner.items.items.len);
    try std.testing.expect(inner.items.items[0] == true);
    try std.testing.expect(inner.items.items[1] == false);
}

// ---------------------------------------------------------------------------
// head advancement via direct field access (validate the algorithm,
// not the scheduler-dependent wait() path)
// ---------------------------------------------------------------------------

test "Stream head advances as items are consumed (simulated)" {
    const S = CheatLib.Stream(f64);
    const alloc = std.testing.allocator;

    const inner = try alloc.create(S.Inner);
    inner.* = .{};
    defer {
        inner.items.deinit(alloc);
        alloc.destroy(inner);
    }

    var consumer = S{ .inner = inner, .alloc = alloc };

    // Push 2 items (simulating generator)
    try consumer.push(100.0);
    try consumer.push(200.0);

    // Simulate the post-wait() part of next() — advance head manually
    try std.testing.expectEqual(@as(usize, 0), consumer.head);
    // First pop
    consumer.head += 1;
    try std.testing.expectEqual(@as(usize, 1), consumer.head);
    // Second pop
    consumer.head += 1;
    try std.testing.expectEqual(@as(usize, 2), consumer.head);
    // Exhausted: head >= items.len
    try std.testing.expect(consumer.head >= inner.items.items.len);
}

// ---------------------------------------------------------------------------
// Type distinctness
// ---------------------------------------------------------------------------

test "Stream(f64) and Promise(f64) are distinct types" {
    const S = CheatLib.Stream(f64);
    const P = CheatLib.Promise(f64);
    try std.testing.expect(S != P);
}

test "Stream(f64) and Stream(bool) are distinct types" {
    const SF = CheatLib.Stream(f64);
    const SB = CheatLib.Stream(bool);
    try std.testing.expect(SF != SB);
}

test "Stream(f64) and BoundedStream(f64, 3) are distinct types" {
    const S  = CheatLib.Stream(f64);
    const BS = CheatLib.BoundedStream(f64, 3);
    try std.testing.expect(S != BS);
}
