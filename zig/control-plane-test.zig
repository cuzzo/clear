// control-plane-test.zig — Unit tests for the control plane overflow registry.
//
// Tests the lock-free registry in isolation (no scheduler, no fibers).
// Verifies:
//   1. Overflow is recorded and recommendation bumps up one tier
//   2. Multiple overflows ratchet upward (Standard → Large → XL)
//   3. recommendSize returns the higher of requested vs recorded
//   4. Unknown functions pass through unchanged
//   5. XL doesn't go higher (stays at XL)
//   6. Policy = .ignore suppresses recording
//   7. Distinct functions get independent entries

const std = @import("std");
const cp = @import("control-plane.zig");
const StackSize = @import("fiber-core.zig").StackSize;

test "recordOverflow bumps Standard → Large" {
    cp.resetRegistry();
    const fn_addr: usize = 0xDEAD_0001;

    cp.recordOverflow(fn_addr, .Standard);

    const rec = cp.recommendSize(fn_addr, .Standard);
    try std.testing.expectEqual(StackSize.Large, rec);
}

test "multiple overflows ratchet: Standard → Large → XL" {
    cp.resetRegistry();
    const fn_addr: usize = 0xDEAD_0002;

    // First overflow: Standard → Large
    cp.recordOverflow(fn_addr, .Standard);
    try std.testing.expectEqual(StackSize.Large, cp.recommendSize(fn_addr, .Standard));

    // Second overflow (now running at Large): Large → XL
    cp.recordOverflow(fn_addr, .Large);
    try std.testing.expectEqual(StackSize.Xl, cp.recommendSize(fn_addr, .Standard));
}

test "XL stays at XL (no higher tier)" {
    cp.resetRegistry();
    const fn_addr: usize = 0xDEAD_0003;

    cp.recordOverflow(fn_addr, .Xl);
    try std.testing.expectEqual(StackSize.Xl, cp.recommendSize(fn_addr, .Standard));
}

test "recommendSize returns requested if no overflow recorded" {
    cp.resetRegistry();
    const unknown_fn: usize = 0xBEEF_9999;

    try std.testing.expectEqual(StackSize.Standard, cp.recommendSize(unknown_fn, .Standard));
    try std.testing.expectEqual(StackSize.Large, cp.recommendSize(unknown_fn, .Large));
}

test "recommendSize returns max of requested and recommended" {
    cp.resetRegistry();
    const fn_addr: usize = 0xDEAD_0004;

    // Record overflow: recommends Large
    cp.recordOverflow(fn_addr, .Standard);

    // If user requests XL (already larger than Large), keep XL
    try std.testing.expectEqual(StackSize.Xl, cp.recommendSize(fn_addr, .Xl));

    // If user requests Micro (smaller than Large), upsize to Large
    try std.testing.expectEqual(StackSize.Large, cp.recommendSize(fn_addr, .Micro));
}

test "distinct functions get independent entries" {
    cp.resetRegistry();
    const fn_a: usize = 0xAAAA_0001;
    const fn_b: usize = 0xBBBB_0002;

    cp.recordOverflow(fn_a, .Standard); // a → Large
    cp.recordOverflow(fn_b, .Large); // b → XL

    try std.testing.expectEqual(StackSize.Large, cp.recommendSize(fn_a, .Standard));
    try std.testing.expectEqual(StackSize.Xl, cp.recommendSize(fn_b, .Standard));
}

test "overflow count tracks correctly" {
    cp.resetRegistry();
    const fn_addr: usize = 0xDEAD_0005;

    try std.testing.expectEqual(@as(u32, 0), cp.getOverflowCount(fn_addr));

    cp.recordOverflow(fn_addr, .Standard);
    try std.testing.expectEqual(@as(u32, 1), cp.getOverflowCount(fn_addr));

    cp.recordOverflow(fn_addr, .Standard);
    try std.testing.expectEqual(@as(u32, 2), cp.getOverflowCount(fn_addr));
}

test "policy = ignore suppresses recording" {
    cp.resetRegistry();
    const fn_addr: usize = 0xDEAD_0006;

    const saved = cp.config.on_overflow;
    cp.config.on_overflow = .ignore;
    defer cp.config.on_overflow = saved;

    cp.recordOverflow(fn_addr, .Standard);
    try std.testing.expectEqual(StackSize.Standard, cp.recommendSize(fn_addr, .Standard));
    try std.testing.expectEqual(@as(u32, 0), cp.getOverflowCount(fn_addr));
}

test "fn_addr = 0 is ignored (no task context)" {
    cp.resetRegistry();

    cp.recordOverflow(0, .Standard);
    try std.testing.expectEqual(StackSize.Standard, cp.recommendSize(0, .Standard));
}
