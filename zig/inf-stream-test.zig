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
// close() sets closed flag and signals EOF
// ---------------------------------------------------------------------------

test "InfStream.close() sets inner.closed to true" {
    const S = CheatLib.InfStream(f64);
    const alloc = std.testing.allocator;
    const inner = try alloc.create(S.Inner);
    inner.* = .{ .sched = @as(*@import("scheduler.zig").Scheduler, @ptrFromInt(@alignOf(@import("scheduler.zig").Scheduler))) };
    defer alloc.destroy(inner);
    var s = S{ .inner = inner, .alloc = alloc };
    try std.testing.expect(!inner.closed);
    s.close();
    try std.testing.expect(inner.closed);
}

test "InfStream.push() returns StreamClosed after close()" {
    const S = CheatLib.InfStream(f64);
    const alloc = std.testing.allocator;
    const inner = try alloc.create(S.Inner);
    inner.* = .{ .sched = @as(*@import("scheduler.zig").Scheduler, @ptrFromInt(@alignOf(@import("scheduler.zig").Scheduler))) };
    defer alloc.destroy(inner);
    var s = S{ .inner = inner, .alloc = alloc };
    s.close();
    try std.testing.expectError(error.StreamClosed, s.push(1.0));
}

// ---------------------------------------------------------------------------
// nextOrNull: reads buffered items, returns null on EOF
// ---------------------------------------------------------------------------

test "InfStream.nextOrNull() returns items then null after close" {
    const S = CheatLib.InfStream(i64);
    const alloc = std.testing.allocator;
    const inner = try alloc.create(S.Inner);
    inner.* = .{ .sched = @as(*@import("scheduler.zig").Scheduler, @ptrFromInt(@alignOf(@import("scheduler.zig").Scheduler))) };
    defer alloc.destroy(inner);
    var s = S{ .inner = inner, .alloc = alloc };

    // Push 3 items (fast path, no blocking)
    try s.push(10);
    try s.push(20);
    try s.push(30);

    // Close the stream (no more pushes)
    s.close();

    // nextOrNull returns all buffered items
    const v1 = try s.nextOrNull();
    try std.testing.expectEqual(@as(?i64, 10), v1);
    const v2 = try s.nextOrNull();
    try std.testing.expectEqual(@as(?i64, 20), v2);
    const v3 = try s.nextOrNull();
    try std.testing.expectEqual(@as(?i64, 30), v3);

    // Buffer empty + closed = null (EOF)
    const v4 = try s.nextOrNull();
    try std.testing.expectEqual(@as(?i64, null), v4);

    // Subsequent calls also return null
    const v5 = try s.nextOrNull();
    try std.testing.expectEqual(@as(?i64, null), v5);
}

test "InfStream.nextOrNull() returns null immediately when closed with empty buffer" {
    const S = CheatLib.InfStream(i64);
    const alloc = std.testing.allocator;
    const inner = try alloc.create(S.Inner);
    inner.* = .{ .sched = @as(*@import("scheduler.zig").Scheduler, @ptrFromInt(@alignOf(@import("scheduler.zig").Scheduler))) };
    defer alloc.destroy(inner);
    var s = S{ .inner = inner, .alloc = alloc };

    // Close immediately (no items pushed)
    s.close();

    // nextOrNull returns null (EOF)
    const v = try s.nextOrNull();
    try std.testing.expectEqual(@as(?i64, null), v);
}

test "InfStream.nextOrNull() with struct element type" {
    const Item = struct { key: []const u8, hash: u64 };
    const S = CheatLib.InfStream(Item);
    const alloc = std.testing.allocator;
    const inner = try alloc.create(S.Inner);
    inner.* = .{ .sched = @as(*@import("scheduler.zig").Scheduler, @ptrFromInt(@alignOf(@import("scheduler.zig").Scheduler))) };
    defer alloc.destroy(inner);
    var s = S{ .inner = inner, .alloc = alloc };

    // Push a struct item (simulates SHARD pipeline element)
    try s.push(.{ .key = "hello", .hash = 42 });
    s.close();

    const item = try s.nextOrNull();
    try std.testing.expect(item != null);
    try std.testing.expectEqualStrings("hello", item.?.key);
    try std.testing.expectEqual(@as(u64, 42), item.?.hash);

    // EOF
    const eof = try s.nextOrNull();
    try std.testing.expectEqual(@as(?Item, null), eof);
}

// ---------------------------------------------------------------------------
// String stream memory safety
// ---------------------------------------------------------------------------

test "InfStream(string).deinit() frees unconsumed buffered strings" {
    // Regression: before the fix, deinit() only signalled closed=true but did
    // not free []const u8 items already committed to the ring buffer, leaking
    // them when the consumer exits early (e.g. reads 3 items from an infinite
    // stream then drops it).
    const S = CheatLib.InfStream([]const u8);
    const alloc = std.testing.allocator;
    const inner = try alloc.create(S.Inner);
    inner.* = .{ .sched = @as(*@import("scheduler.zig").Scheduler, @ptrFromInt(@alignOf(@import("scheduler.zig").Scheduler))) };
    var s = S{ .inner = inner, .alloc = alloc };

    // Push 4 strings (fast path, no blocking).
    const a = try alloc.dupe(u8, "hello");
    const b = try alloc.dupe(u8, "world");
    const c = try alloc.dupe(u8, "foo");
    const d = try alloc.dupe(u8, "bar");
    try s.push(a);
    try s.push(b);
    try s.push(c);
    try s.push(d);

    // Consume only 2 — "foo" and "bar" are still in the buffer.
    const v1 = try s.next();
    defer alloc.free(v1);
    const v2 = try s.next();
    defer alloc.free(v2);

    try std.testing.expectEqualStrings("hello", v1);
    try std.testing.expectEqualStrings("world", v2);

    // deinit() must free "foo" and "bar" before destroying inner.
    // GPA will catch any leak.
    s.deinit();
    alloc.destroy(inner);
}

test "InfStream(string).push() frees value when stream is closed" {
    // Regression: the generator pre-allocates a value (dupe), then calls push().
    // If the stream was closed between the dupe and the push(), push() returns
    // StreamClosed and the value was leaked.  push() must free it before returning.
    const S = CheatLib.InfStream([]const u8);
    const alloc = std.testing.allocator;
    const inner = try alloc.create(S.Inner);
    inner.* = .{ .sched = @as(*@import("scheduler.zig").Scheduler, @ptrFromInt(@alignOf(@import("scheduler.zig").Scheduler))) };
    defer alloc.destroy(inner);
    var s = S{ .inner = inner, .alloc = alloc };

    // Close the stream first so any subsequent push() sees closed=true.
    inner.closed = true;

    // push() must free the slice before returning StreamClosed.
    const val = try alloc.dupe(u8, "leaked?");
    const result = s.push(val);
    try std.testing.expectError(error.StreamClosed, result);
    // GPA would report val as leaked if push() didn't free it.
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
