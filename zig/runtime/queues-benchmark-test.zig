const std = @import("std");
const compat = @import("../lib/compat.zig");
const builtin = @import("builtin");
const testing = std.testing;

const queues = @import("queues.zig");
const RunQueue = queues.RunQueue;

test "Benchmark: Throughput" {
    if (builtin.mode == .Debug) return error.SkipZigTest; // Don't bench in debug

    var timer = try compat.Timer.start();
    const ITERATIONS = 10_000_000;

    var q = RunQueue.init();

    // Simple Push/Pop loop
    for (0..ITERATIONS) |_| {
        // Reuse same task ptr to avoid allocator noise
        try q.push(std.testing.allocator, @ptrFromInt(0xDEADBEEF0));
        _ = q.pop();
    }

    const ns = timer.read();
    std.debug.print("\nThroughput: {d} ops/sec\n", .{
        ITERATIONS * 1_000_000_000 / ns
    });
}
