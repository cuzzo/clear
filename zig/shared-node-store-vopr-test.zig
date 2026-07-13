const std = @import("std");
const rt_mod = @import("runtime/runtime.zig");
const ebr = @import("lib/ebr.zig");
const CheatLib = @import("runtime/runtime-header.zig").CheatLib;

pub const SimAtomic = @import("runtime/vopr-atomic.zig").SimAtomic;

const Payload = struct {
    value: u64,
    destroyed: *usize,

    pub fn deinit(self: *@This(), _: std.mem.Allocator) void {
        self.destroyed.* += 1;
    }
};

const Store = CheatLib.SharedNodeStore(Payload);
const Ref = CheatLib.NodeRef(Payload);
const slots = 128;

fn runSeed(allocator: std.mem.Allocator, context: *ebr.EbrContext, seed: u64) !void {
    var rt = try rt_mod.Runtime.init(allocator, 16 * 1024, context);
    var destroyed: usize = 0;
    var refs = [_]?Ref{null} ** slots;
    var values = [_]u64{0} ** slots;
    var live: usize = 0;
    var inserted: usize = 0;
    var prng = std.Random.DefaultPrng.init(seed ^ 0x5348_4152_4544_4e4f);
    const random = prng.random();

    var step: usize = 0;
    while (step < 1_000) : (step += 1) {
        const index = random.uintLessThan(usize, slots);
        switch (random.uintLessThan(u8, 4)) {
            0 => if (refs[index] == null) {
                const state = try Store.lockWrite(&rt);
                const value = random.int(u64);
                refs[index] = try Store.createBound(state, .{ .value = value, .destroyed = &destroyed });
                values[index] = value;
                live += 1;
                inserted += 1;
                try std.testing.expect(Store.validateBound(state));
                Store.unlockWrite(state);
            },
            1 => if (refs[index]) |ref| {
                const state = try Store.lockWrite(&rt);
                try std.testing.expect(Store.removeBound(state, ref));
                try std.testing.expect(!Store.removeBound(state, ref));
                try std.testing.expect(Store.getBound(state, ref) == null);
                refs[index] = null;
                live -= 1;
                try std.testing.expect(Store.validateBound(state));
                Store.unlockWrite(state);
            },
            2 => if (refs[index]) |ref| {
                const state = try Store.lockRead(&rt);
                try std.testing.expectEqual(values[index], Store.getBound(state, ref).?.value);
                try std.testing.expectEqual(live, Store.countBound(state));
                Store.unlockRead(state);
            },
            3 => if (refs[index]) |ref| {
                const state = try Store.lockWrite(&rt);
                const value = random.int(u64);
                Store.getBound(state, ref).?.value = value;
                values[index] = value;
                Store.unlockWrite(state);
            },
            else => unreachable,
        }
    }

    rt.deinit();
    try std.testing.expectEqual(inserted, destroyed);
    try std.testing.expect(destroyed >= live);
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    var context = ebr.EbrContext{};
    defer context.deinit(allocator);

    var seed: u64 = 0;
    while (seed < 64) : (seed += 1) try runSeed(allocator, &context, seed);
    std.debug.print("shared-node-store-vopr: 64 seeds x 1000 operations passed\n", .{});
}
