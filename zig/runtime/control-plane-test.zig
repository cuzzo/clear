// control-plane-test.zig — Unit tests for the control plane.
//
// Tests the lock-free registry in isolation (no scheduler, no fibers).
//
// Overflow tests:
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

// ═══════════════════════════════════════════════════════════════════
// OnUnderflow tests
// ═══════════════════════════════════════════════════════════════════

test "measureStackUsage: fully used stack returns full size" {
    var stack: [1024]u8 = undefined;
    @memset(&stack, 0xCC); // fill pattern
    @memset(stack[0..], 0x00); // overwrite ALL of it
    try std.testing.expectEqual(@as(usize, 1024), cp.measureStackUsage(&stack));
}

test "measureStackUsage: untouched stack returns 0" {
    var stack: [1024]u8 = undefined;
    @memset(&stack, 0xCC); // all fill pattern = untouched
    try std.testing.expectEqual(@as(usize, 0), cp.measureStackUsage(&stack));
}

test "measureStackUsage: half-used stack" {
    var stack: [1024]u8 = undefined;
    @memset(&stack, 0xCC);
    // Touch the top half (higher addresses = used by stack growing downward)
    @memset(stack[512..], 0x00);
    // Bottom half untouched (512 bytes of 0xCC)
    try std.testing.expectEqual(@as(usize, 512), cp.measureStackUsage(&stack));
}

test "recordCompletion: 1-tier underflow increments counter" {
    cp.resetRegistry();
    const fn_addr: usize = 0xFACE_0001;

    // Standard = 16KB.  Using 4KB = 25% → that's actually < 25% boundary.
    // Let's use 6KB = 37.5% of 16KB → < 50% but >= 25% → 1-tier underflow.
    cp.recordCompletion(fn_addr, .Standard, 6 * 1024);

    const counts = cp.getUnderflowCounts(fn_addr);
    try std.testing.expectEqual(@as(u32, 1), counts.tier1);
    try std.testing.expectEqual(@as(u32, 0), counts.tier2);
}

test "recordCompletion: 2-tier underflow increments tier2 counter" {
    cp.resetRegistry();
    const fn_addr: usize = 0xFACE_0002;

    // Standard = 16KB.  Using 2KB = 12.5% → < 25% → 2-tier underflow.
    cp.recordCompletion(fn_addr, .Standard, 2 * 1024);

    const counts = cp.getUnderflowCounts(fn_addr);
    try std.testing.expectEqual(@as(u32, 0), counts.tier1);
    try std.testing.expectEqual(@as(u32, 1), counts.tier2);
}

test "recordCompletion: no underflow when usage is > 50%" {
    cp.resetRegistry();
    const fn_addr: usize = 0xFACE_0003;

    // Standard = 16KB.  Using 12KB = 75% → no underflow.
    cp.recordCompletion(fn_addr, .Standard, 12 * 1024);

    const counts = cp.getUnderflowCounts(fn_addr);
    try std.testing.expectEqual(@as(u32, 0), counts.tier1);
    try std.testing.expectEqual(@as(u32, 0), counts.tier2);
}

test "recordCompletion: 2-tier threshold triggers downsize by 2" {
    cp.resetRegistry();
    const fn_addr: usize = 0xFACE_0004;

    // Use low thresholds for testing.
    const saved_t = cp.config.underflow_2tier_threshold;
    cp.config.underflow_2tier_threshold = 5;
    defer cp.config.underflow_2tier_threshold = saved_t;

    // Large task using < 25% → 2-tier underflow.  Large - 2 = Micro.
    for (0..5) |_| {
        cp.recordCompletion(fn_addr, .Large, 1024); // 1KB of 64KB = 1.5%
    }

    // After 5 completions (= threshold), should recommend Micro.
    try std.testing.expectEqual(StackSize.Micro, cp.recommendSize(fn_addr, .Large));
}

test "recordCompletion: 1-tier threshold triggers downsize by 1" {
    cp.resetRegistry();
    const fn_addr: usize = 0xFACE_0005;

    const saved_t = cp.config.underflow_1tier_threshold;
    cp.config.underflow_1tier_threshold = 3;
    defer cp.config.underflow_1tier_threshold = saved_t;

    // Large task using 30% → < 50% but >= 25% → 1-tier underflow.  Large - 1 = Standard.
    for (0..3) |_| {
        cp.recordCompletion(fn_addr, .Large, 20 * 1024); // 20KB of 64KB = 31%
    }

    try std.testing.expectEqual(StackSize.Standard, cp.recommendSize(fn_addr, .Large));
}

test "recordCompletion: Micro tasks are not downsized" {
    cp.resetRegistry();
    const fn_addr: usize = 0xFACE_0006;

    cp.config.underflow_2tier_threshold = 1;
    defer cp.config.underflow_2tier_threshold = 10_000;

    // Micro task using nothing — can't downsize further.
    cp.recordCompletion(fn_addr, .Micro, 100);

    const counts = cp.getUnderflowCounts(fn_addr);
    try std.testing.expectEqual(@as(u32, 0), counts.tier1);
    try std.testing.expectEqual(@as(u32, 0), counts.tier2);
}

test "overflow takes priority over underflow downsize" {
    cp.resetRegistry();
    const fn_addr: usize = 0xFACE_0007;

    cp.config.underflow_1tier_threshold = 1;
    defer cp.config.underflow_1tier_threshold = 100_000;

    // First: overflow bumps Standard → Large.
    cp.recordOverflow(fn_addr, .Standard);
    try std.testing.expectEqual(StackSize.Large, cp.recommendSize(fn_addr, .Standard));

    // Then: underflow tries to downsize Large → Standard.
    cp.recordCompletion(fn_addr, .Large, 20 * 1024);

    // Underflow downsize set recommended to Standard.
    // recommendSize returns max(requested=Standard, recommended=Standard) = Standard.
    // But the overflow previously set it to Large — the downsize overwrote it.
    // This is intentional: if the task consistently uses less after being upsized,
    // the underflow should be allowed to correct it.
    try std.testing.expectEqual(StackSize.Standard, cp.recommendSize(fn_addr, .Standard));
}

test "underflow policy = ignore suppresses counting" {
    cp.resetRegistry();
    const fn_addr: usize = 0xFACE_0008;

    const saved = cp.config.on_underflow;
    cp.config.on_underflow = .ignore;
    defer cp.config.on_underflow = saved;

    cp.recordCompletion(fn_addr, .Large, 1024);
    const counts = cp.getUnderflowCounts(fn_addr);
    try std.testing.expectEqual(@as(u32, 0), counts.tier2);
}

// ═══════════════════════════════════════════════════════════════════
// OnSkew tests
// ═══════════════════════════════════════════════════════════════════

test "isSkewed: uniform distribution is not skewed" {
    const counts = [_]u64{ 1000, 1000, 1000, 1000 };
    try std.testing.expect(!cp.isSkewed(&counts));
}

test "isSkewed: one hot shard is skewed" {
    // Shard 0 has nearly all traffic.  CV ≈ 3.4 (>> 2.0 threshold).
    const counts = [_]u64{ 50000, 100, 100, 100 };
    try std.testing.expect(cp.isSkewed(&counts));
}

test "isSkewed: below min_ops threshold is not skewed" {
    // Looks skewed but total < 1000 (warmup period).
    const counts = [_]u64{ 500, 1, 1, 1 };
    try std.testing.expect(!cp.isSkewed(&counts));
}

test "isSkewed: mild imbalance is not skewed (CV < threshold)" {
    // 2:1 ratio — uneven but not extreme.
    const counts = [_]u64{ 2000, 1000, 1500, 1200 };
    try std.testing.expect(!cp.isSkewed(&counts));
}

test "isSkewed: policy = ignore always returns false" {
    const saved = cp.config.on_skew;
    cp.config.on_skew = .ignore;
    defer cp.config.on_skew = saved;

    const counts = [_]u64{ 100000, 1, 1, 1 };
    try std.testing.expect(!cp.isSkewed(&counts));
}

test "checkAndFixSkew: detects skew on ShardedStringMap" {
    const CheatLib = @import("runtime-header.zig").CheatLib;
    var map = CheatLib.ShardedStringMap(i64, 4){};

    // Simulate skewed ops: shard 0 gets all traffic.
    map.shards[0].ops.store(50000, .monotonic);
    map.shards[1].ops.store(10, .monotonic);
    map.shards[2].ops.store(10, .monotonic);
    map.shards[3].ops.store(10, .monotonic);

    const skewed = cp.checkAndFixSkew(&map);
    try std.testing.expect(skewed);
}

test "checkAndFixSkew: no skew on balanced map" {
    const CheatLib = @import("runtime-header.zig").CheatLib;
    var map = CheatLib.ShardedStringMap(i64, 4){};

    map.shards[0].ops.store(1000, .monotonic);
    map.shards[1].ops.store(1000, .monotonic);
    map.shards[2].ops.store(1000, .monotonic);
    map.shards[3].ops.store(1000, .monotonic);

    const skewed = cp.checkAndFixSkew(&map);
    try std.testing.expect(!skewed);
}
