const std = @import("std");
const header = @import("runtime-header.zig");
const sim_atomic = @import("vopr-atomic.zig");

const CheatLib = header.CheatLib;

const Payload = struct {
    destroyed: *usize,

    pub fn deinit(self: *@This(), _: std.mem.Allocator) void {
        self.destroyed.* += 1;
    }
};

const ArcT = CheatLib.Arc(Payload);
const WeakT = CheatLib.WeakArc(Payload);
const max_handles = 32;

pub fn testArcWeakStateMachine() !void {
    var seed: u64 = 0;
    while (seed < 200) : (seed += 1) {
        var gpa = std.heap.DebugAllocator(.{}){};
        const allocator = gpa.allocator();
        var destroyed: usize = 0;
        var arcs = [_]?ArcT{null} ** max_handles;
        var weaks = [_]?WeakT{null} ** max_handles;
        arcs[0] = try CheatLib.arcCreate(Payload, allocator, .{ .destroyed = &destroyed });
        var expected_strong: usize = 1;
        var expected_weak: usize = 0;
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();

        var step: usize = 0;
        while (step < 1_000) : (step += 1) {
            const src = random.uintLessThan(usize, max_handles);
            const dst = random.uintLessThan(usize, max_handles);
            switch (random.uintLessThan(u8, 5)) {
                0 => if (arcs[src] != null and arcs[dst] == null) {
                    arcs[dst] = CheatLib.arcRetain(Payload, arcs[src].?);
                    expected_strong += 1;
                },
                1 => if (arcs[src] != null and weaks[dst] == null) {
                    weaks[dst] = CheatLib.arcDowngrade(Payload, arcs[src].?);
                    expected_weak += 1;
                },
                2 => if (weaks[src] != null and arcs[dst] == null) {
                    // Force the actual WeakArc CAS retry body on a stable,
                    // replayable subset of state-machine steps.
                    if (expected_strong > 0 and step % 17 == 0) {
                        sim_atomic.inject_cas_fault_count_remaining = 1;
                    }
                    const upgraded = CheatLib.weakArcUpgrade(Payload, weaks[src].?);
                    try std.testing.expectEqual(expected_strong > 0, upgraded != null);
                    if (upgraded) |arc| {
                        arcs[dst] = arc;
                        expected_strong += 1;
                    }
                },
                3 => if (arcs[src]) |arc| {
                    arcs[src] = null;
                    CheatLib.arcRelease(Payload, allocator, arc);
                    expected_strong -= 1;
                    if (expected_strong == 0) try std.testing.expectEqual(@as(usize, 1), destroyed);
                },
                4 => if (weaks[src]) |weak| {
                    weaks[src] = null;
                    CheatLib.weakArcRelease(Payload, weak);
                    expected_weak -= 1;
                },
                else => unreachable,
            }
        }

        for (&arcs) |*slot| if (slot.*) |arc| {
            slot.* = null;
            CheatLib.arcRelease(Payload, allocator, arc);
            expected_strong -= 1;
        };
        try std.testing.expectEqual(@as(usize, 0), expected_strong);
        try std.testing.expectEqual(@as(usize, 1), destroyed);

        for (&weaks) |*slot| if (slot.*) |weak| {
            try std.testing.expect(CheatLib.weakArcUpgrade(Payload, weak) == null);
            slot.* = null;
            CheatLib.weakArcRelease(Payload, weak);
            expected_weak -= 1;
        };
        try std.testing.expectEqual(@as(usize, 0), expected_weak);
        try std.testing.expect(gpa.deinit() == .ok);
    }
    sim_atomic.resetFault();
}
