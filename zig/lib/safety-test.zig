const std = @import("std");
const safety = @import("safety.zig");

test "StackGuard rejects reentrant entry for the same source location" {
    safety.stack_guard_head = null;
    const src = @src();

    var guard = try safety.StackGuard.enter(src);
    guard.push();
    defer {
        guard.pop();
        safety.stack_guard_head = null;
    }

    try std.testing.expectError(error.UnexpectedRecursion, safety.StackGuard.enter(src));
}

test "StackGuard pop restores the previous guard node" {
    safety.stack_guard_head = null;
    const outer_src = @src();
    const inner_src = @src();

    var outer = try safety.StackGuard.enter(outer_src);
    outer.push();
    defer {
        outer.pop();
        safety.stack_guard_head = null;
    }

    var inner = try safety.StackGuard.enter(inner_src);
    inner.push();
    try std.testing.expect(safety.stack_guard_head == &inner.node);

    inner.pop();
    try std.testing.expect(safety.stack_guard_head == &outer.node);
}

test "DepthCounter enforces max depth and recovers after exit" {
    const src = @src();
    try safety.enterDepth(src, 1);
    defer safety.exitDepth(src);

    try std.testing.expectError(error.MaxDepthExceeded, safety.enterDepth(src, 1));
}

test "DepthCounter allows entry after paired exit" {
    const src = @src();
    try safety.enterDepth(src, 1);
    safety.exitDepth(src);

    try safety.enterDepth(src, 1);
    safety.exitDepth(src);
}

test "depthGuard records a concrete stack depth" {
    const previous = safety.__min_depth;
    defer safety.__min_depth = previous;

    safety.__min_depth = std.math.maxInt(usize);
    safety.depthGuard();

    try std.testing.expect(safety.__min_depth != std.math.maxInt(usize));
}

test "depthGuard does not update if sp >= __min_depth" {
    const previous = safety.__min_depth;
    defer safety.__min_depth = previous;

    safety.__min_depth = 0;
    safety.depthGuard();
    try std.testing.expectEqual(@as(usize, 0), safety.__min_depth);
}

test "GlobalReentrancyGuard initializes to unlocked" {
    const Guard = safety.GlobalReentrancyGuard("test");
    try std.testing.expectEqual(false, Guard.locked);
}
