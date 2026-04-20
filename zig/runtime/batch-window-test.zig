// batch-window-test.zig
// Thorough unit tests for CheatLib.BatchWindow(T).
//
// Tests are grouped into four tiers:
//   1. Structural  -- verify fields, init, deinit.
//   2. Size-only   -- flush triggers on max_size, partial final batch.
//   3. Time-only   -- flush triggers on timeout_ns elapsed (real sleep).
//   4. Both        -- first-of-either: size fires before time, time fires before size.
//
// Run with:
//   zig test zig/runtime/batch-window-test.zig -lc zig/runtime/switch.S zig/runtime/onRoot.S
const std = @import("std");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;

fn sleepMs(ms: u64) void {
    var req = std.c.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    var rem: std.c.timespec = undefined;
    while (std.c.nanosleep(&req, &rem) != 0) req = rem;
}

// ============================================================================
// Tier 1: Structural
// ============================================================================

test "BatchWindow(i64) compiles and init/deinit works" {
    const BW = CheatLib.BatchWindow(i64);
    var w = BW.init(std.testing.allocator, 4, 0);
    defer w.deinit();
    try std.testing.expectEqual(@as(usize, 4), w.max_size);
    try std.testing.expectEqual(@as(u64, 0), w.timeout_ns);
    try std.testing.expect(!w.has_items);
}

test "BatchWindow: flush on empty buffer returns null" {
    var w = CheatLib.BatchWindow(i64).init(std.testing.allocator, 4, 0);
    defer w.deinit();
    const result = try w.flush();
    try std.testing.expectEqual(@as(?[]i64, null), result);
}

test "BatchWindow: push without flush returns null" {
    var w = CheatLib.BatchWindow(i64).init(std.testing.allocator, 4, 0);
    defer w.deinit();
    const r1 = try w.push(10);
    try std.testing.expectEqual(@as(?[]i64, null), r1);
    const r2 = try w.push(20);
    try std.testing.expectEqual(@as(?[]i64, null), r2);
    // partial batch still in buffer; explicit flush returns it
    const batch = (try w.flush()).?;
    defer w.freeBatch(batch);
    try std.testing.expectEqual(@as(usize, 2), batch.len);
}

// ============================================================================
// Tier 2: Size-only flush
// ============================================================================

test "BatchWindow size=3: flushes exactly when 3rd item pushed" {
    var w = CheatLib.BatchWindow(i64).init(std.testing.allocator, 3, 0);
    defer w.deinit();

    const r0 = try w.push(1); try std.testing.expectEqual(@as(?[]i64, null), r0);
    const r1 = try w.push(2); try std.testing.expectEqual(@as(?[]i64, null), r1);
    const batch = (try w.push(3)).?;
    defer w.freeBatch(batch);
    try std.testing.expectEqualSlices(i64, &.{1, 2, 3}, batch);
}

test "BatchWindow size=3: two full batches, no remainder" {
    var w = CheatLib.BatchWindow(i64).init(std.testing.allocator, 3, 0);
    defer w.deinit();

    // First batch
    _ = try w.push(10);
    _ = try w.push(20);
    const b1 = (try w.push(30)).?;
    defer w.freeBatch(b1);
    try std.testing.expectEqualSlices(i64, &.{10, 20, 30}, b1);

    // Second batch
    _ = try w.push(40);
    _ = try w.push(50);
    const b2 = (try w.push(60)).?;
    defer w.freeBatch(b2);
    try std.testing.expectEqualSlices(i64, &.{40, 50, 60}, b2);

    // Nothing left
    const tail = try w.flush();
    try std.testing.expectEqual(@as(?[]i64, null), tail);
}

test "BatchWindow size=4: partial final batch via flush()" {
    var w = CheatLib.BatchWindow(i64).init(std.testing.allocator, 4, 0);
    defer w.deinit();

    _ = try w.push(1);
    _ = try w.push(2);
    _ = try w.push(3);
    // 3 items, size limit is 4 -> no flush yet
    const partial = (try w.flush()).?;
    defer w.freeBatch(partial);
    try std.testing.expectEqualSlices(i64, &.{1, 2, 3}, partial);
}

test "BatchWindow size=1: every item is its own batch" {
    var w = CheatLib.BatchWindow(i64).init(std.testing.allocator, 1, 0);
    defer w.deinit();

    for (0..5) |i| {
        const batch = (try w.push(@intCast(i))).?;
        defer w.freeBatch(batch);
        try std.testing.expectEqual(@as(usize, 1), batch.len);
        try std.testing.expectEqual(@as(i64, @intCast(i)), batch[0]);
    }
    const tail = try w.flush();
    try std.testing.expectEqual(@as(?[]i64, null), tail);
}

test "BatchWindow size=5: window resets after flush, produces independent batches" {
    var w = CheatLib.BatchWindow(i64).init(std.testing.allocator, 5, 0);
    defer w.deinit();

    var sum: i64 = 0;
    var batches: usize = 0;

    for (0..10) |i| {
        if (try w.push(@intCast(i))) |batch| {
            defer w.freeBatch(batch);
            batches += 1;
            for (batch) |v| sum += v;
        }
    }
    // 10 items at size=5 -> exactly 2 batches
    try std.testing.expectEqual(@as(usize, 2), batches);
    // sum 0..9 = 45
    try std.testing.expectEqual(@as(i64, 45), sum);
    const tail = try w.flush();
    try std.testing.expectEqual(@as(?[]i64, null), tail);
}

test "BatchWindow: works with struct type" {
    const Item = struct { id: u32, val: f64 };
    var w = CheatLib.BatchWindow(Item).init(std.testing.allocator, 2, 0);
    defer w.deinit();

    _ = try w.push(.{ .id = 1, .val = 1.5 });
    const batch = (try w.push(.{ .id = 2, .val = 2.5 })).?;
    defer w.freeBatch(batch);
    try std.testing.expectEqual(@as(usize, 2), batch.len);
    try std.testing.expectEqual(@as(u32, 1), batch[0].id);
    try std.testing.expectEqual(@as(u32, 2), batch[1].id);
}

// ============================================================================
// Tier 3: Time-only flush
// ============================================================================

test "BatchWindow time=1ms: single item flushes after timeout" {
    const timeout_ns: u64 = 1_000_000; // 1ms
    var w = CheatLib.BatchWindow(i64).init(std.testing.allocator, 0, timeout_ns);
    defer w.deinit();

    // Push item; should not flush immediately
    const r0 = try w.push(42);
    try std.testing.expectEqual(@as(?[]i64, null), r0);

    // Sleep past timeout
    sleepMs(2); // 2ms

    // Next push triggers time flush (first checks time, then appends 99)
    // Actually: push appends first, then checks shouldFlush.
    // After sleep, the NEXT push will see elapsed >= timeout and flush.
    const batch = (try w.push(99)).?;
    defer w.freeBatch(batch);
    // Both items in the batch (42 was buffered, 99 was appended before flush check)
    try std.testing.expectEqual(@as(usize, 2), batch.len);
    try std.testing.expectEqual(@as(i64, 42), batch[0]);
    try std.testing.expectEqual(@as(i64, 99), batch[1]);
}

test "BatchWindow time=1ms: explicit flush() after timeout" {
    const timeout_ns: u64 = 1_000_000; // 1ms
    var w = CheatLib.BatchWindow(i64).init(std.testing.allocator, 0, timeout_ns);
    defer w.deinit();

    _ = try w.push(10);
    _ = try w.push(20);
    _ = try w.push(30);

    // No push to trigger time check; call flush() explicitly
    sleepMs(2);
    const batch = (try w.flush()).?;
    defer w.freeBatch(batch);
    try std.testing.expectEqualSlices(i64, &.{10, 20, 30}, batch);
}

test "BatchWindow time: no timeout if items arrive fast enough" {
    const timeout_ns: u64 = 500_000_000; // 500ms -- very long
    var w = CheatLib.BatchWindow(i64).init(std.testing.allocator, 0, timeout_ns);
    defer w.deinit();

    // Push 10 items quickly; no size limit, no time elapsed -> no flush
    for (0..10) |i| {
        const r = try w.push(@intCast(i));
        try std.testing.expectEqual(@as(?[]i64, null), r);
    }
    const batch = (try w.flush()).?;
    defer w.freeBatch(batch);
    try std.testing.expectEqual(@as(usize, 10), batch.len);
}

// ============================================================================
// Tier 4: Both size and time (first-of-either)
// ============================================================================

test "BatchWindow size+time: size fires before time" {
    const timeout_ns: u64 = 500_000_000; // 500ms (won't fire in test)
    var w = CheatLib.BatchWindow(i64).init(std.testing.allocator, 3, timeout_ns);
    defer w.deinit();

    _ = try w.push(1);
    _ = try w.push(2);
    // 3rd item triggers size flush before time fires
    const batch = (try w.push(3)).?;
    defer w.freeBatch(batch);
    try std.testing.expectEqualSlices(i64, &.{1, 2, 3}, batch);
}

test "BatchWindow size+time: time fires before size" {
    const timeout_ns: u64 = 1_000_000; // 1ms
    var w = CheatLib.BatchWindow(i64).init(std.testing.allocator, 100, timeout_ns);
    defer w.deinit();

    _ = try w.push(10);
    _ = try w.push(20);
    sleepMs(2); // 2ms -- let time fire
    // Next push should trigger time flush (size=100 not reached)
    const batch = (try w.push(30)).?;
    defer w.freeBatch(batch);
    try std.testing.expectEqualSlices(i64, &.{10, 20, 30}, batch);
}

test "BatchWindow size+time: after time flush, new batch starts fresh" {
    const timeout_ns: u64 = 1_000_000; // 1ms
    var w = CheatLib.BatchWindow(i64).init(std.testing.allocator, 100, timeout_ns);
    defer w.deinit();

    _ = try w.push(1);
    sleepMs(2);
    // Time fires on this push: batch = {1, 2}
    const b1 = (try w.push(2)).?;
    defer w.freeBatch(b1);
    try std.testing.expectEqualSlices(i64, &.{1, 2}, b1);
    try std.testing.expect(!w.has_items);

    // New batch starts fresh
    _ = try w.push(3);
    _ = try w.push(4);
    const b2 = (try w.flush()).?;
    defer w.freeBatch(b2);
    try std.testing.expectEqualSlices(i64, &.{3, 4}, b2);
}

test "BatchWindow size+time: empty flush after time flush" {
    const timeout_ns: u64 = 1_000_000; // 1ms
    var w = CheatLib.BatchWindow(i64).init(std.testing.allocator, 100, timeout_ns);
    defer w.deinit();

    _ = try w.push(5);
    sleepMs(2);
    const b = (try w.push(6)).?;
    defer w.freeBatch(b);
    // Buffer is now empty
    const tail = try w.flush();
    try std.testing.expectEqual(@as(?[]i64, null), tail);
}
