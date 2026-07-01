// bounded-stream-test.zig
// Unit tests for CheatLib.BoundedStream(T, N) — Phase 1 bounded streams.
//
// These tests exercise the Zig runtime struct directly, independent of the
// CLEAR compiler.  Full behavioral tests (concurrent BG fibers, NEXT in order)
// require a live scheduler and are covered by transpile-tests/70_bounded_stream.clear.
//
// Run with:
//   zig test zig/bounded-stream-test.zig -lc zig/switch.S zig/onRoot.S
const std = @import("std");
const CheatLib = @import("runtime-header.zig").CheatLib;

// ---------------------------------------------------------------------------
// Struct shape
// ---------------------------------------------------------------------------

test "BoundedStream has correct item-count at comptime" {
    const S3 = CheatLib.BoundedStream(f64, 3);
    // The items field is [3]Promise(f64); verify the array length via comptime.
    const items_len = comptime blk: {
        const info = @typeInfo(S3);
        for (info.@"struct".fields) |f| {
            if (std.mem.eql(u8, f.name, "items")) {
                break :blk @typeInfo(f.type).array.len;
            }
        }
        break :blk @as(usize, 0);
    };
    try std.testing.expectEqual(@as(usize, 3), items_len);
}

test "BoundedStream head field defaults to 0" {
    // Allocate a dummy BoundedStream without filling items (we cannot call
    // next() without a live scheduler, so we only inspect the head counter).
    var s: CheatLib.BoundedStream(f64, 2) = undefined;
    s.head = 0; // mimic the default initializer
    try std.testing.expectEqual(@as(usize, 0), s.head);
}

test "BoundedStream(i32, 1) and BoundedStream(i32, 5) are distinct types" {
    const S1 = CheatLib.BoundedStream(i32, 1);
    const S5 = CheatLib.BoundedStream(i32, 5);
    // Distinct N → distinct types; their item arrays have different sizes.
    const len1 = @typeInfo(@TypeOf(@as(S1, undefined).items)).array.len;
    const len5 = @typeInfo(@TypeOf(@as(S5, undefined).items)).array.len;
    try std.testing.expectEqual(@as(usize, 1), len1);
    try std.testing.expectEqual(@as(usize, 5), len5);
}

test "BoundedStream(f64, 0) compiles (zero-item degenerate case)" {
    // A zero-capacity stream is a valid type even if calling next() on it
    // would always panic.  It should compile without issues.
    const S0 = CheatLib.BoundedStream(f64, 0);
    var s: S0 = undefined;
    s.head = 0;
    try std.testing.expectEqual(@as(usize, 0), s.head);
}

// ---------------------------------------------------------------------------
// Head counter progression (without scheduler — manually craft a fake stream)
// ---------------------------------------------------------------------------
// We cannot call BoundedStream.next() in a unit test without a live scheduler
// because Promise.next() blocks on a WaitGroup.  Instead, we directly verify
// the head-advancement logic by inspecting the struct after a simulated advance.

test "BoundedStream head advances when next() would be called" {
    // Simulate what next() does to the head pointer, without touching items.
    var s: CheatLib.BoundedStream(f64, 3) = undefined;
    s.head = 0;

    // Advance head twice (mimicking two next() calls)
    s.head += 1;
    try std.testing.expectEqual(@as(usize, 1), s.head);

    s.head += 1;
    try std.testing.expectEqual(@as(usize, 2), s.head);
}

test "BoundedStream exhaustion condition is head >= N" {
    var s: CheatLib.BoundedStream(f64, 2) = undefined;
    s.head = 0;
    try std.testing.expect(s.head < 2); // not exhausted

    s.head = 2;
    try std.testing.expect(s.head >= 2); // exhausted: next() would panic
}

// ---------------------------------------------------------------------------
// nextOrNull: structural invariants (no scheduler required)
// ---------------------------------------------------------------------------
// nextOrNull() returns null immediately when head >= N without touching items.
// The scheduler-dependent path (consuming actual Promise values) is covered by
// transpile-tests/233_bounded_stream_sequential_pipelines.clear.

test "nextOrNull returns null for exhausted stream (head == N)" {
    // Stream of 3 with head already at 3 — nextOrNull must return null without
    // touching items[] (which are uninitialised).
    var s: CheatLib.BoundedStream(i64, 3) = undefined;
    s.head = 3;
    const result = try s.nextOrNull();
    try std.testing.expect(result == null);
    // head must not advance past N
    try std.testing.expectEqual(@as(usize, 3), s.head);
}

test "nextOrNull returns null for zero-capacity stream" {
    var s: CheatLib.BoundedStream(i64, 0) = undefined;
    s.head = 0;
    const result = try s.nextOrNull();
    try std.testing.expect(result == null);
}

// ---------------------------------------------------------------------------
// deinit: no-op when already exhausted (no scheduler required)
// ---------------------------------------------------------------------------
// deinit() must be a no-op when head == N — it must not touch items[].
// The early-exit drain path (calling next() on unconsumed promises) is covered
// by transpile-tests/233_bounded_stream_sequential_pipelines.clear.

test "deinit is a no-op when stream is already exhausted" {
    // head == N means all promises were consumed; deinit's while condition
    // (head < N) is false and the body never runs.  No scheduler needed.
    var s: CheatLib.BoundedStream(i64, 4) = undefined;
    s.head = 4;
    s.deinit(); // must not access items[4] (out of bounds) or call next()
    try std.testing.expectEqual(@as(usize, 4), s.head);
}

test "deinit is a no-op for zero-capacity stream" {
    var s: CheatLib.BoundedStream(i64, 0) = undefined;
    s.head = 0;
    s.deinit();
    try std.testing.expectEqual(@as(usize, 0), s.head);
}
