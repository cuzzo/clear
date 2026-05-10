// spsc-hammer-test.zig -- TSan hammer coverage for scheduler SPSC wait loops.

const std = @import("std");
const spsc = @import("spsc.zig");

// HAMMER-COVERS: spsc.push-lock
test "Hammer: SpscRing push lock wait-loop yields under producer contention" {
    const PRODUCERS = 8;
    const PER_PRODUCER = 2_000;
    const Ring = spsc.SpscRing(1024);

    var ring = Ring{};
    var started = std.atomic.Value(usize).init(0);
    var done = std.atomic.Value(usize).init(0);
    var consumed = std.atomic.Value(usize).init(0);

    // Hold the push lock before producer startup so every producer must enter
    // the wait-loop at least once. The rest of the test then drains the ring
    // normally to keep this a real producer/consumer hammer, not just a lock
    // probe.
    try std.testing.expectEqual(@as(u8, 0), ring.push_lock.swap(1, .acquire));

    const Consumer = struct {
        fn run(r: *Ring, done_count: *std.atomic.Value(usize), consumed_count: *std.atomic.Value(usize)) void {
            while (true) {
                if (r.pop()) |_| {
                    _ = consumed_count.fetchAdd(1, .monotonic);
                } else if (done_count.load(.acquire) == PRODUCERS) {
                    while (r.pop()) |_| {
                        _ = consumed_count.fetchAdd(1, .monotonic);
                    }
                    break;
                } else {
                    std.Thread.yield() catch {};
                }
            }
        }
    };

    const ProducerCtx = struct {
        ring: *Ring,
        started: *std.atomic.Value(usize),
        done: *std.atomic.Value(usize),
        producer_id: usize,

        fn run(ctx: *@This()) void {
            _ = ctx.started.fetchAdd(1, .release);
            for (0..PER_PRODUCER) |i| {
                const value = ctx.producer_id * PER_PRODUCER + i + 1;
                while (!ctx.ring.push(.{ .tag = .Resume, .trampoline_addr = value })) {
                    std.Thread.yield() catch {};
                }
            }
            _ = ctx.done.fetchAdd(1, .release);
        }
    };

    const consumer = try std.Thread.spawn(.{}, Consumer.run, .{ &ring, &done, &consumed });

    var ctxs: [PRODUCERS]ProducerCtx = undefined;
    var producers: [PRODUCERS]std.Thread = undefined;
    for (&ctxs, 0..) |*ctx, i| {
        ctx.* = .{
            .ring = &ring,
            .started = &started,
            .done = &done,
            .producer_id = i,
        };
        producers[i] = try std.Thread.spawn(.{}, ProducerCtx.run, .{ctx});
    }

    while (started.load(.acquire) != PRODUCERS) {
        std.Thread.yield() catch {};
    }

    // Give the producers a scheduling window to block in push() before the
    // lock is released. Under TSan this also increases instrumentation
    // pressure on the wait-loop path this hammer covers.
    for (0..1024) |_| {
        std.Thread.yield() catch {};
    }
    ring.push_lock.store(0, .release);

    for (&producers) |*producer| producer.join();
    consumer.join();

    try std.testing.expectEqual(@as(usize, PRODUCERS * PER_PRODUCER), consumed.load(.acquire));
}
