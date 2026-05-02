// control-plane-hammer-test.zig — Concurrency stress test for the control plane.
//
// Verifies that the lock-free overflow registry has no publication races,
// torn reads, or lost updates under heavy concurrent access.
//
// Run:
//   zig test control-plane-hammer-test.zig -lc
//
// (needs -lc for pthreads on Linux)

const std = @import("std");
const cp = @import("control-plane.zig");
const StackSize = @import("fiber-core.zig").StackSize;

// ═══════════════════════════════════════════════════════════════════
// Test 1: Concurrent overflow + recommend — no stale reads
//
// Half the threads hammer recordOverflow (Standard → Large).
// The other half hammer recommendSize for the same fn.
// Assert: recommendSize NEVER returns Micro (the old sentinel bug)
// and eventually settles on Large.
// ═══════════════════════════════════════════════════════════════════

const T1_FN_ADDR: usize = 0xAAAA_1111;
const T1_ITERS: usize = 100_000;
const T1_WRITERS: usize = 4;
const T1_READERS: usize = 4;

var t1_bad_reads = std.atomic.Value(u64).init(0);
var t1_large_seen = std.atomic.Value(u64).init(0);

fn t1Writer(_: usize) void {
    for (0..T1_ITERS) |_| {
        cp.recordOverflow(T1_FN_ADDR, .Standard);
    }
}

fn t1Reader(_: usize) void {
    for (0..T1_ITERS) |_| {
        const rec = cp.recommendSize(T1_FN_ADDR, .Standard);
        // Must be Standard (no recommendation yet) or Large (overflow recorded).
        // MUST NEVER be Micro — that would mean we read the sentinel / uninitialized value.
        switch (rec) {
            .Standard => {}, // Fine: recommendation not yet visible.
            .Large => {
                _ = t1_large_seen.fetchAdd(1, .monotonic);
            },
            .Micro => {
                _ = t1_bad_reads.fetchAdd(1, .monotonic);
            },
            .Xl => {
                _ = t1_bad_reads.fetchAdd(1, .monotonic);
            },
            .Huge => {
                _ = t1_bad_reads.fetchAdd(1, .monotonic);
            },
        }
    }
}

test "Hammer: concurrent overflow + recommend — no publication race" {
    cp.resetRegistry();

    var threads: [T1_WRITERS + T1_READERS]std.Thread = undefined;

    // Spawn writers
    for (0..T1_WRITERS) |i| {
        threads[i] = try std.Thread.spawn(.{}, t1Writer, .{i});
    }
    // Spawn readers
    for (0..T1_READERS) |i| {
        threads[T1_WRITERS + i] = try std.Thread.spawn(.{}, t1Reader, .{i});
    }

    for (threads) |t| t.join();

    const bad = t1_bad_reads.load(.monotonic);
    const large = t1_large_seen.load(.monotonic);

    if (bad > 0) {
        std.debug.print("\nFAIL: {d} bad reads (Micro or XL instead of Standard/Large)\n", .{bad});
    }
    try std.testing.expectEqual(@as(u64, 0), bad);

    // After all writers finished, at least SOME readers should have seen Large.
    try std.testing.expect(large > 0);

    // Final state: must recommend Large.
    try std.testing.expectEqual(StackSize.Large, cp.recommendSize(T1_FN_ADDR, .Standard));
}

// ═══════════════════════════════════════════════════════════════════
// Test 2: Many distinct functions — no slot corruption
//
// 8 threads each record overflows for their own unique fn_addr.
// After joining, each fn must have an independent, correct recommendation.
// ═══════════════════════════════════════════════════════════════════

const T2_THREADS: usize = 8;
const T2_ITERS: usize = 50_000;

fn t2Worker(thread_id: usize) void {
    const fn_addr: usize = 0xBBBB_0000 + thread_id;
    for (0..T2_ITERS) |_| {
        cp.recordOverflow(fn_addr, .Standard);
    }
}

test "Hammer: distinct functions — independent slots" {
    cp.resetRegistry();

    var threads: [T2_THREADS]std.Thread = undefined;
    for (0..T2_THREADS) |i| {
        threads[i] = try std.Thread.spawn(.{}, t2Worker, .{i});
    }
    for (threads) |t| t.join();

    // Each function should independently recommend Large.
    for (0..T2_THREADS) |i| {
        const fn_addr: usize = 0xBBBB_0000 + i;
        try std.testing.expectEqual(
            StackSize.Large,
            cp.recommendSize(fn_addr, .Standard),
        );
        // Each should have exactly T2_ITERS overflows recorded.
        try std.testing.expectEqual(@as(u32, T2_ITERS), cp.getOverflowCount(fn_addr));
    }
}

// ═══════════════════════════════════════════════════════════════════
// Test 3: Ratchet race — concurrent multi-tier overflow
//
// All threads record overflows for the SAME fn, but at different
// tiers: half at Standard (→Large), half at Large (→XL).
// Final recommendation must be XL (the max), never Large.
// ═══════════════════════════════════════════════════════════════════

const T3_FN_ADDR: usize = 0xCCCC_3333;
const T3_ITERS: usize = 50_000;
const T3_THREADS: usize = 8;

fn t3WorkerStandard(_: usize) void {
    for (0..T3_ITERS) |_| {
        cp.recordOverflow(T3_FN_ADDR, .Standard); // wants Large
    }
}

fn t3WorkerLarge(_: usize) void {
    for (0..T3_ITERS) |_| {
        cp.recordOverflow(T3_FN_ADDR, .Large); // wants XL
    }
}

test "Hammer: multi-tier ratchet — converges to max" {
    cp.resetRegistry();

    var threads: [T3_THREADS]std.Thread = undefined;
    for (0..T3_THREADS / 2) |i| {
        threads[i] = try std.Thread.spawn(.{}, t3WorkerStandard, .{i});
    }
    for (T3_THREADS / 2..T3_THREADS) |i| {
        threads[i] = try std.Thread.spawn(.{}, t3WorkerLarge, .{i});
    }
    for (threads) |t| t.join();

    // Must converge to XL (highest tier requested).
    try std.testing.expectEqual(StackSize.Xl, cp.recommendSize(T3_FN_ADDR, .Standard));
}

// ═══════════════════════════════════════════════════════════════════
// Test 4: Concurrent overflow + underflow — no crash, no corruption
//
// Writers record overflows (upsize).  Readers record completions
// (underflow / downsize).  The system must not crash and the
// final state must be internally consistent.
// ═══════════════════════════════════════════════════════════════════

const T4_FN_ADDR: usize = 0xDDDD_4444;
const T4_ITERS: usize = 50_000;
const T4_THREADS: usize = 8;

fn t4Overflower(_: usize) void {
    for (0..T4_ITERS) |_| {
        cp.recordOverflow(T4_FN_ADDR, .Standard);
    }
}

fn t4Completer(_: usize) void {
    for (0..T4_ITERS) |_| {
        // Simulate task completion with low stack usage (underflow).
        cp.recordCompletion(T4_FN_ADDR, .Large, 1024);
    }
}

test "Hammer: concurrent overflow + underflow — no crash" {
    cp.resetRegistry();

    // Use low thresholds so underflow actually triggers.
    const saved_t1 = cp.config.underflow_1tier_threshold;
    const saved_t2 = cp.config.underflow_2tier_threshold;
    cp.config.underflow_1tier_threshold = 1000;
    cp.config.underflow_2tier_threshold = 500;
    defer {
        cp.config.underflow_1tier_threshold = saved_t1;
        cp.config.underflow_2tier_threshold = saved_t2;
    }

    var threads: [T4_THREADS]std.Thread = undefined;
    for (0..T4_THREADS / 2) |i| {
        threads[i] = try std.Thread.spawn(.{}, t4Overflower, .{i});
    }
    for (T4_THREADS / 2..T4_THREADS) |i| {
        threads[i] = try std.Thread.spawn(.{}, t4Completer, .{i});
    }
    for (threads) |t| t.join();

    // Just verify it didn't crash and the recommendation is a valid enum.
    const rec = cp.recommendSize(T4_FN_ADDR, .Standard);
    // Must be one of the valid tiers.
    try std.testing.expect(
        rec == .Micro or rec == .Standard or rec == .Large or rec == .Xl,
    );
}
