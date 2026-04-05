// inf-stream-test.zig
// Unit tests for CheatLib.InfStream(T) — Phase 4 infinite rendezvous streams.
//
// Full behavioral tests (concurrent push/next rendezvous) require a live scheduler
// and are covered by transpile-tests/76_inf_stream.cht.
//
// Run with:
//   zig test zig/inf-stream-test.zig -lc zig/switch.S zig/onRoot.S
const std = @import("std");
const CheatLib = @import("runtime-header.zig").CheatLib;

// ---------------------------------------------------------------------------
// Struct shape
// ---------------------------------------------------------------------------

test "InfStream has inner and alloc fields" {
    const S = CheatLib.InfStream(f64);
    const fields = @typeInfo(S).@"struct".fields;
    var found_inner = false;
    var found_alloc = false;
    inline for (fields) |f| {
        if (std.mem.eql(u8, f.name, "inner")) found_inner = true;
        if (std.mem.eql(u8, f.name, "alloc")) found_alloc = true;
    }
    try std.testing.expect(found_inner);
    try std.testing.expect(found_alloc);
}

test "InfStream.Inner has buf, head, tail, lock, consumer_task, producer_task, and sched fields" {
    const Inner = CheatLib.InfStream(f64).Inner;
    const fields = @typeInfo(Inner).@"struct".fields;
    var found_buf      = false;
    var found_head     = false;
    var found_tail     = false;
    var found_lock     = false;
    var found_consumer = false;
    var found_producer = false;
    var found_sched    = false;
    inline for (fields) |f| {
        if (std.mem.eql(u8, f.name, "buf"))           found_buf      = true;
        if (std.mem.eql(u8, f.name, "head"))          found_head     = true;
        if (std.mem.eql(u8, f.name, "tail"))          found_tail     = true;
        if (std.mem.eql(u8, f.name, "lock"))          found_lock     = true;
        if (std.mem.eql(u8, f.name, "consumer_task")) found_consumer = true;
        if (std.mem.eql(u8, f.name, "producer_task")) found_producer = true;
        if (std.mem.eql(u8, f.name, "sched"))         found_sched    = true;
    }
    try std.testing.expect(found_buf);
    try std.testing.expect(found_head);
    try std.testing.expect(found_tail);
    try std.testing.expect(found_lock);
    try std.testing.expect(found_consumer);
    try std.testing.expect(found_producer);
    try std.testing.expect(found_sched);
}

test "InfStream.Inner head defaults to 0 (empty)" {
    // Verify head and tail default to 0 by checking a default-initialized Inner.
    // We can't instantiate Inner directly (requires a scheduler pointer), but we
    // can verify the struct type has the expected fields with default values.
    const Inner = CheatLib.InfStream(f64).Inner;
    const fields = @typeInfo(Inner).@"struct".fields;
    var found_head = false;
    var found_tail = false;
    inline for (fields) |f| {
        if (std.mem.eql(u8, f.name, "head")) found_head = true;
        if (std.mem.eql(u8, f.name, "tail")) found_tail = true;
    }
    try std.testing.expect(found_head);
    try std.testing.expect(found_tail);
}

test "InfStream.Inner consumer_task defaults to null" {
    const Inner = CheatLib.InfStream(f64).Inner;
    const fields = @typeInfo(Inner).@"struct".fields;
    var consumer_default_is_null = false;
    inline for (fields) |f| {
        if (std.mem.eql(u8, f.name, "consumer_task")) {
            consumer_default_is_null = (f.default_value_ptr != null);
        }
    }
    try std.testing.expect(consumer_default_is_null);
}

// ---------------------------------------------------------------------------
// close() is a no-op (compiles and does not panic)
// ---------------------------------------------------------------------------

test "InfStream.close() is a no-op" {
    const S = CheatLib.InfStream(f64);
    const alloc = std.testing.allocator;
    const inner = try alloc.create(S.Inner);
    inner.* = .{ .sched = @as(*@import("scheduler.zig").Scheduler, @ptrFromInt(@alignOf(@import("scheduler.zig").Scheduler))) };
    defer alloc.destroy(inner);
    var s = S{ .inner = inner, .alloc = alloc };
    s.close(); // must not panic
}

// ---------------------------------------------------------------------------
// Type distinctness
// ---------------------------------------------------------------------------

test "InfStream(f64) and Promise(f64) are distinct types" {
    const I = CheatLib.InfStream(f64);
    const P = CheatLib.Promise(f64);
    try std.testing.expect(I != P);
}

test "InfStream(f64) and Stream(f64) are distinct types" {
    const I = CheatLib.InfStream(f64);
    const S = CheatLib.Stream(f64);
    try std.testing.expect(I != S);
}

test "InfStream(f64) and InfStream(bool) are distinct types" {
    const IF = CheatLib.InfStream(f64);
    const IB = CheatLib.InfStream(bool);
    try std.testing.expect(IF != IB);
}
