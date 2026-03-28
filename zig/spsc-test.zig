// spsc-test.zig — Exhaustive test suite for the SPSC ring buffer.
//
// Tests every operation, every edge case, every concurrent scenario.
// Must be 100% pass before the SPSC ring is used in the scheduler.
//
// Build: zig test spsc-test.zig
// Or:    zig build-exe spsc-test.zig -OReleaseFast && ./spsc-test

const std = @import("std");
const spsc = @import("spsc.zig");
const Message = spsc.Message;
const MessageTag = spsc.MessageTag;

// ========================================================================
// 1. BASIC OPERATIONS — single-threaded correctness
// ========================================================================

test "empty ring returns null on pop" {
    var ring = spsc.SpscRing(4){};
    try std.testing.expect(ring.pop() == null);
    try std.testing.expect(ring.isEmpty());
    try std.testing.expect(ring.len() == 0);
}

test "push one, pop one" {
    var ring = spsc.SpscRing(4){};
    const msg = Message{ .tag = .Resume, .task = @ptrFromInt(0xDEAD) };
    try std.testing.expect(ring.push(msg));
    try std.testing.expect(ring.len() == 1);
    try std.testing.expect(!ring.isEmpty());

    const popped = ring.pop().?;
    try std.testing.expect(popped.tag == .Resume);
    try std.testing.expect(@intFromPtr(popped.task.?) == 0xDEAD);
    try std.testing.expect(ring.isEmpty());
}

test "FIFO ordering" {
    var ring = spsc.SpscRing(8){};
    for (0..5) |i| {
        try std.testing.expect(ring.push(.{ .tag = .Spawn, .trampoline_addr = i }));
    }
    for (0..5) |i| {
        const msg = ring.pop().?;
        try std.testing.expect(msg.trampoline_addr == i);
    }
    try std.testing.expect(ring.pop() == null);
}

test "fill to capacity" {
    var ring = spsc.SpscRing(4){};
    for (0..4) |i| {
        try std.testing.expect(ring.push(.{ .tag = .Spawn, .trampoline_addr = i }));
    }
    try std.testing.expect(ring.len() == 4);
    // Ring is full — push should fail
    try std.testing.expect(!ring.push(.{ .tag = .Spawn }));
}

test "fill, drain, refill (wraparound)" {
    var ring = spsc.SpscRing(4){};
    // Fill
    for (0..4) |i| _ = ring.push(.{ .tag = .Spawn, .trampoline_addr = i });
    // Drain
    for (0..4) |i| {
        const msg = ring.pop().?;
        try std.testing.expect(msg.trampoline_addr == i);
    }
    // Refill — tests wraparound
    for (10..14) |i| {
        try std.testing.expect(ring.push(.{ .tag = .Spawn, .trampoline_addr = i }));
    }
    for (10..14) |i| {
        const msg = ring.pop().?;
        try std.testing.expect(msg.trampoline_addr == i);
    }
    try std.testing.expect(ring.isEmpty());
}

test "many wraparounds" {
    var ring = spsc.SpscRing(4){};
    for (0..1000) |i| {
        try std.testing.expect(ring.push(.{ .tag = .Spawn, .trampoline_addr = i }));
        const msg = ring.pop().?;
        try std.testing.expect(msg.trampoline_addr == i);
    }
    try std.testing.expect(ring.isEmpty());
}

test "alternating push-pop at capacity boundary" {
    var ring = spsc.SpscRing(4){};
    // Fill to 3
    for (0..3) |i| _ = ring.push(.{ .tag = .Spawn, .trampoline_addr = i });
    // Push one, pop one, 500 times
    for (0..500) |i| {
        try std.testing.expect(ring.push(.{ .tag = .Resume, .trampoline_addr = 100 + i }));
        const msg = ring.pop().?;
        try std.testing.expect(msg.tag == .Spawn or msg.tag == .Resume);
    }
}

test "all message tags preserved" {
    var ring = spsc.SpscRing(8){};
    _ = ring.push(.{ .tag = .Spawn, .trampoline_addr = 1 });
    _ = ring.push(.{ .tag = .Resume, .task = @ptrFromInt(2) });
    _ = ring.push(.{ .tag = .RemoteCall, .rc_func = undefined, .rc_ctx = @ptrFromInt(3) });

    try std.testing.expect(ring.pop().?.tag == .Spawn);
    try std.testing.expect(ring.pop().?.tag == .Resume);
    try std.testing.expect(ring.pop().?.tag == .RemoteCall);
}

test "message fields survive round-trip" {
    var ring = spsc.SpscRing(4){};
    const original = Message{
        .tag = .Spawn,
        .trampoline_addr = 0x12345678,
        .user_fn = @ptrFromInt(0xABCD),
        .args = @ptrFromInt(0xFEED),
        .config_stack_size = 3,
        .config_pinned = true,
        .config_timeout_ms = 99999,
    };
    _ = ring.push(original);
    const got = ring.pop().?;
    try std.testing.expect(got.trampoline_addr == 0x12345678);
    try std.testing.expect(@intFromPtr(got.user_fn.?) == 0xABCD);
    try std.testing.expect(@intFromPtr(got.args.?) == 0xFEED);
    try std.testing.expect(got.config_stack_size == 3);
    try std.testing.expect(got.config_pinned == true);
    try std.testing.expect(got.config_timeout_ms == 99999);
}

test "len accuracy through operations" {
    var ring = spsc.SpscRing(8){};
    try std.testing.expect(ring.len() == 0);
    _ = ring.push(.{ .tag = .Spawn });
    try std.testing.expect(ring.len() == 1);
    _ = ring.push(.{ .tag = .Spawn });
    try std.testing.expect(ring.len() == 2);
    _ = ring.pop();
    try std.testing.expect(ring.len() == 1);
    _ = ring.pop();
    try std.testing.expect(ring.len() == 0);
}

// ========================================================================
// 2. CONCURRENT SPSC — one producer thread, one consumer thread
// ========================================================================

test "concurrent SPSC: 100K messages, 1 producer, 1 consumer" {
    const N = 100_000;
    var ring = spsc.SpscRing(256){};
    var consumer_sum: u64 = 0;
    var consumer_count: u64 = 0;
    var producer_done = std.atomic.Value(bool).init(false);

    const consumer = try std.Thread.spawn(.{}, struct {
        fn run(r: *spsc.SpscRing(256), sum: *u64, count: *u64, done: *std.atomic.Value(bool)) void {
            while (true) {
                if (r.pop()) |msg| {
                    sum.* += msg.trampoline_addr;
                    count.* += 1;
                } else if (done.load(.acquire)) {
                    // Drain remaining
                    while (r.pop()) |msg| {
                        sum.* += msg.trampoline_addr;
                        count.* += 1;
                    }
                    break;
                } else {
                    std.Thread.yield() catch {};
                }
            }
        }
    }.run, .{ &ring, &consumer_sum, &consumer_count, &producer_done });

    // Producer
    var producer_sum: u64 = 0;
    for (0..N) |i| {
        const val: usize = i + 1;
        while (!ring.push(.{ .tag = .Spawn, .trampoline_addr = val })) {
            std.Thread.yield() catch {};
        }
        producer_sum += val;
    }
    producer_done.store(true, .release);

    consumer.join();

    try std.testing.expect(consumer_count == N);
    try std.testing.expect(consumer_sum == producer_sum);
}

test "concurrent SPSC: ring full backpressure" {
    // Tiny ring — producer will often find it full
    var ring = spsc.SpscRing(4){};
    var consumer_count: u64 = 0;
    var producer_done = std.atomic.Value(bool).init(false);
    const N = 10_000;

    const consumer = try std.Thread.spawn(.{}, struct {
        fn run(r: *spsc.SpscRing(4), count: *u64, done: *std.atomic.Value(bool)) void {
            while (true) {
                if (r.pop()) |_| {
                    count.* += 1;
                } else if (done.load(.acquire)) {
                    while (r.pop()) |_| count.* += 1;
                    break;
                } else {
                    std.Thread.yield() catch {};
                }
            }
        }
    }.run, .{ &ring, &consumer_count, &producer_done });

    for (0..N) |_| {
        while (!ring.push(.{ .tag = .Spawn })) {
            std.Thread.yield() catch {};
        }
    }
    producer_done.store(true, .release);
    consumer.join();

    try std.testing.expect(consumer_count == N);
}

test "concurrent SPSC: multiple rounds of fill/drain" {
    var ring = spsc.SpscRing(64){};
    const ROUNDS = 100;
    const BATCH = 50;
    var total_consumed: u64 = 0;
    var producer_done = std.atomic.Value(bool).init(false);

    const consumer = try std.Thread.spawn(.{}, struct {
        fn run(r: *spsc.SpscRing(64), total: *u64, done: *std.atomic.Value(bool)) void {
            while (true) {
                if (r.pop()) |_| {
                    total.* += 1;
                } else if (done.load(.acquire)) {
                    while (r.pop()) |_| total.* += 1;
                    break;
                } else {
                    std.Thread.yield() catch {};
                }
            }
        }
    }.run, .{ &ring, &total_consumed, &producer_done });

    for (0..ROUNDS) |_| {
        for (0..BATCH) |_| {
            while (!ring.push(.{ .tag = .Resume })) std.Thread.yield() catch {};
        }
    }
    producer_done.store(true, .release);
    consumer.join();

    try std.testing.expect(total_consumed == ROUNDS * BATCH);
}

// ========================================================================
// 3. STRESS TEST — high contention, verify no data corruption
// ========================================================================

test "stress: concurrent SPSC with value verification" {
    // Each message carries a sequence number. Consumer verifies strict ordering.
    var ring = spsc.SpscRing(128){};
    const N = 500_000;
    var consumer_ok = std.atomic.Value(bool).init(true);
    var producer_done = std.atomic.Value(bool).init(false);

    const consumer = try std.Thread.spawn(.{}, struct {
        fn run(r: *spsc.SpscRing(128), ok: *std.atomic.Value(bool), done: *std.atomic.Value(bool)) void {
            var expected: usize = 0;
            while (true) {
                if (r.pop()) |msg| {
                    if (msg.trampoline_addr != expected) {
                        std.debug.print("ORDER FAIL: expected {d}, got {d}\n", .{ expected, msg.trampoline_addr });
                        ok.store(false, .release);
                    }
                    expected += 1;
                } else if (done.load(.acquire)) {
                    while (r.pop()) |msg| {
                        if (msg.trampoline_addr != expected) ok.store(false, .release);
                        expected += 1;
                    }
                    if (expected != N) {
                        std.debug.print("COUNT FAIL: expected {d}, got {d}\n", .{ N, expected });
                        ok.store(false, .release);
                    }
                    break;
                } else {
                    std.Thread.yield() catch {};
                }
            }
        }
    }.run, .{ &ring, &consumer_ok, &producer_done });

    for (0..N) |i| {
        while (!ring.push(.{ .tag = .Spawn, .trampoline_addr = i })) {
            std.Thread.yield() catch {};
        }
    }
    producer_done.store(true, .release);
    consumer.join();

    try std.testing.expect(consumer_ok.load(.acquire));
}

// ========================================================================
// 4. DefaultRing specific tests
// ========================================================================

test "DefaultRing: basic push/pop" {
    var ring = spsc.DefaultRing{};
    _ = ring.push(.{ .tag = .Spawn, .trampoline_addr = 42 });
    const msg = ring.pop().?;
    try std.testing.expect(msg.trampoline_addr == 42);
}

test "DefaultRing: fill to capacity (4096)" {
    var ring = spsc.DefaultRing{};
    for (0..4096) |i| {
        try std.testing.expect(ring.push(.{ .tag = .Spawn, .trampoline_addr = i }));
    }
    try std.testing.expect(!ring.push(.{ .tag = .Spawn })); // full
    try std.testing.expect(ring.len() == 4096);

    for (0..4096) |i| {
        try std.testing.expect(ring.pop().?.trampoline_addr == i);
    }
    try std.testing.expect(ring.isEmpty());
}

// ========================================================================
// 5. Edge cases
// ========================================================================

test "pop after empty returns null repeatedly" {
    var ring = spsc.SpscRing(4){};
    for (0..100) |_| {
        try std.testing.expect(ring.pop() == null);
    }
}

test "push after full returns false repeatedly" {
    var ring = spsc.SpscRing(4){};
    for (0..4) |_| _ = ring.push(.{ .tag = .Spawn });
    for (0..100) |_| {
        try std.testing.expect(!ring.push(.{ .tag = .Spawn }));
    }
}

test "interleaved push/pop never corrupts" {
    var ring = spsc.SpscRing(4){};
    for (0..10000) |i| {
        _ = ring.push(.{ .tag = .Spawn, .trampoline_addr = i });
        _ = ring.push(.{ .tag = .Resume, .trampoline_addr = i + 1 });
        const a = ring.pop().?;
        const b = ring.pop().?;
        try std.testing.expect(a.trampoline_addr == i);
        try std.testing.expect(b.trampoline_addr == i + 1);
    }
}

test "size 2 ring works correctly" {
    var ring = spsc.SpscRing(2){};
    for (0..1000) |i| {
        try std.testing.expect(ring.push(.{ .tag = .Spawn, .trampoline_addr = i }));
        try std.testing.expect(ring.pop().?.trampoline_addr == i);
    }
}

// ========================================================================
// MAIN: run as executable for quick iteration
// ========================================================================

pub fn main() !void {
    std.debug.print("SPSC tests must be run with: zig test spsc-test.zig\n", .{});
}
