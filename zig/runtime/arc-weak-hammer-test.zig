const std = @import("std");
const header = @import("runtime-header.zig");

const CheatLib = header.CheatLib;
const worker_count = 8;
const upgrades_per_worker = 50_000;

const Payload = struct {
    destroyed: *std.atomic.Value(usize),

    pub fn deinit(self: *@This(), _: std.mem.Allocator) void {
        _ = self.destroyed.fetchAdd(1, .monotonic);
    }
};

const Worker = struct {
    weak: CheatLib.WeakArc(Payload),
    start: *std.atomic.Value(bool),
    owner_released: *std.atomic.Value(bool),
    upgrades: *std.atomic.Value(usize),
};

fn upgradeWorker(worker: Worker) void {
    while (!worker.start.load(.acquire)) std.atomic.spinLoopHint();

    var attempts: usize = 0;
    while (attempts < upgrades_per_worker) : (attempts += 1) {
        if (CheatLib.weakArcUpgrade(Payload, worker.weak)) |arc| {
            _ = worker.upgrades.fetchAdd(1, .monotonic);
            CheatLib.arcRelease(Payload, std.heap.c_allocator, arc);
        } else if (worker.owner_released.load(.acquire)) {
            break;
        }
    }
    CheatLib.weakArcRelease(Payload, worker.weak);
}

// HAMMER-COVERS: weak-arc-upgrade-cas
test "CheatLib WeakArc upgrades race safely with final strong and weak releases" {
    var destroyed = std.atomic.Value(usize).init(0);
    var start = std.atomic.Value(bool).init(false);
    var owner_released = std.atomic.Value(bool).init(false);
    var upgrades = std.atomic.Value(usize).init(0);

    const arc = try CheatLib.arcCreate(
        Payload,
        std.heap.c_allocator,
        .{ .destroyed = &destroyed },
    );

    var threads: [worker_count]std.Thread = undefined;
    for (&threads) |*thread| {
        const weak = CheatLib.arcDowngrade(Payload, arc);
        thread.* = try std.Thread.spawn(.{}, upgradeWorker, .{Worker{
            .weak = weak,
            .start = &start,
            .owner_released = &owner_released,
            .upgrades = &upgrades,
        }});
    }

    start.store(true, .release);
    while (upgrades.load(.acquire) < worker_count) std.atomic.spinLoopHint();
    CheatLib.arcRelease(Payload, std.heap.c_allocator, arc);
    owner_released.store(true, .release);

    for (&threads) |*thread| thread.join();
    try std.testing.expect(upgrades.load(.monotonic) >= worker_count);
    try std.testing.expectEqual(@as(usize, 1), destroyed.load(.acquire));
}
