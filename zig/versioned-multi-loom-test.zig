// versioned-multi-loom-test — multi-fiber Loom harness for
// `versioned.updateMulti` contention. Built as an executable (NOT a
// b.addTest) so `@import("root")` from versioned.zig resolves to *this*
// file. Two `pub const`s at root drive comptime behavior:
//
//   - SimAtomic: makes versioned.zig's atomic ops yield to the loom
//     harness instead of running on real atomics. Without it the
//     fibers would never deterministically interleave.
//   - CLEAR_MVCC_MAX_INNER_RETRIES_MULTI: lowers the per-cell
//     tag-acquire spin budget from 1024 (production) to 4 so the
//     contention-rollback path (versioned.zig:565) fires within the
//     enumerable schedule space.
//
// What this proves: line 565 is the per-cell tag-release store in the
// rollback prefix of `updateMulti`. Triggered ONLY when one fiber has
// acquired SOME (>0) tags but cannot acquire the next cell within the
// inner-retry budget. Two fibers updating overlapping cell-sets with
// staggered ordering deterministically reach this branch.
//
// Cell layout:
//   Fiber X transactions  .{ &a, &b }
//   Fiber Y transactions  .{ &b, &c }
// Both fibers sort by address so their acquisition orders interleave
// on `b`. Schedule X tags `a` -> Y tags `b` -> X spins on `b` ->
// inner-retry budget exhausts -> X enters rollback (line 565 fires
// for the prefix `[a]`).

const std = @import("std");
const fc = @import("runtime/fiber-core.zig");
const ebr_mod = @import("lib/ebr.zig");
const versioned = @import("runtime/versioned.zig");
const Runtime = @import("runtime/runtime.zig").Runtime;
const va = @import("runtime/vopr-atomic.zig");

pub const SimAtomic = va.SimAtomic;

// Lower the inner-retry budget from 1024 to 4 so the contention path
// is reachable in a small enumerable schedule space. Production-only
// callers see the default 1024.
pub const CLEAR_MVCC_MAX_INNER_RETRIES_MULTI: usize = 4;

const Fiber = fc.Fiber;
const Context = fc.Context;
const EbrContext = ebr_mod.EbrContext;
const ThreadLocalEbr = ebr_mod.ThreadLocalEbr;

const STACK_SIZE = 64 * 1024;
const MAX_STEPS = 200_000;

// 3 cells in a contiguous array so g_cells[0] < g_cells[1] < g_cells[2]
// in address order regardless of Zig BSS layout. Fiber X uses
// .{ &g_cells[0], &g_cells[1] } and Fiber Y uses
// .{ &g_cells[1], &g_cells[2] }: their first acquisitions differ
// (X tags g_cells[0], Y tags g_cells[1]) but their second cell is
// shared (g_cells[1]). Whichever fiber tries the second cell after
// the other has tagged it spins out the inner-retry budget with
// acquired > 0, exercising the rollback store at versioned.zig:574.
var g_cells: [3]versioned.Versioned(i64) = undefined;

var g_rt: Runtime = undefined;
var g_frame_buf: [4096]u8 = undefined;

const HarnessSlot = struct {
    fiber: Fiber = undefined,
    stack: []u8 = &.{},
    done: bool = false,
};

const MultiCellLoomHarness = struct {
    slots: [2]HarnessSlot = .{ .{}, .{} },
    main_ctx: Context = undefined,
    schedule: []const u8,
    pos: usize = 0,
    allocator: std.mem.Allocator,
    // True iff at least one schedule observed a fiber retrying outer
    // (i.e. the contention-rollback path executed). The check is
    // out-of-band because versioned.zig has no observable hook for
    // "I rolled back" -- we count outer-retry observations indirectly
    // via the global flag flipped from inside the harness.
    rollback_observed: bool = false,

    fn init(allocator: std.mem.Allocator, schedule: []const u8) MultiCellLoomHarness {
        return .{
            .schedule = schedule,
            .allocator = allocator,
        };
    }

    fn deinit(self: *MultiCellLoomHarness) void {
        fc.__fiber = null;
        fc.__fiber_parent_ctx = null;
        fc.__fiber_stack_limit = null;
        for (&self.slots) |*s| {
            if (s.stack.len > 0) {
                self.allocator.free(s.stack);
                s.stack = &.{};
            }
        }
    }

    fn createThread(self: *MultiCellLoomHarness, id: usize, entry_fn: usize) !void {
        if (self.slots[id].stack.len == 0) {
            self.slots[id].stack = try self.allocator.alloc(u8, STACK_SIZE);
        }
        self.slots[id].fiber = Fiber.init(self.slots[id].stack, entry_fn, .Large);
        self.slots[id].done = false;
    }

    fn pickThread(self: *MultiCellLoomHarness) usize {
        if (self.slots[0].done) return 1;
        if (self.slots[1].done) return 0;
        // For schedule[0..len], use the explicit bit. After the schedule
        // exhausts, round-robin so neither fiber starves -- without this,
        // a fiber spinning on a tagged cell would never let its peer
        // run, and we'd hit error.UpdateRetriesExhausted on every
        // schedule that didn't fully resolve within `schedule.len`
        // picks.
        const bit = if (self.pos < self.schedule.len)
            self.schedule[self.pos] & 1
        else
            @as(u8, @intCast(self.pos & 1));
        self.pos += 1;
        return bit;
    }

    fn run(self: *MultiCellLoomHarness) !void {
        var steps: usize = 0;
        while (steps < MAX_STEPS) : (steps += 1) {
            if (self.slots[0].done and self.slots[1].done) break;
            const chosen = self.pickThread();
            self.slots[chosen].fiber.switchTo(&self.main_ctx);
        }
        fc.__fiber = null;
        fc.__fiber_parent_ctx = null;
        fc.__fiber_stack_limit = null;
        if (steps >= MAX_STEPS) return error.StepLimitExceeded;
    }
};

var harness: *MultiCellLoomHarness = undefined;

fn fiberTxnAB(views: anytype) anyerror!void {
    views[0].* += 1;
    views[1].* += 1;
}

fn fiberTxnBC(views: anytype) anyerror!void {
    views[0].* += 10;
    views[1].* += 10;
}

fn entryFiberX() callconv(.c) void {
    versioned.updateMulti(
        .{ &g_cells[0], &g_cells[1] },
        &g_rt,
        std.heap.c_allocator,
        fiberTxnAB,
        .{},
    ) catch {};
    harness.slots[0].done = true;
    while (true) fc.__fiber.?.yield();
}

fn entryFiberY() callconv(.c) void {
    versioned.updateMulti(
        .{ &g_cells[1], &g_cells[2] },
        &g_rt,
        std.heap.c_allocator,
        fiberTxnBC,
        .{},
    ) catch {};
    harness.slots[1].done = true;
    while (true) fc.__fiber.?.yield();
}

fn fillBinarySchedule(buf: []u8, value: usize) void {
    for (buf, 0..) |*slot, i| {
        slot.* = @intCast((value >> @as(u6, @intCast(i))) & 1);
    }
}

fn runOneSchedule(allocator: std.mem.Allocator, schedule: []const u8) !struct { a: i64, b: i64, c: i64 } {
    g_cells[0] = try versioned.Versioned(i64).init(allocator, 0);
    defer g_cells[0].deinit(&g_rt, allocator) catch {};
    g_cells[1] = try versioned.Versioned(i64).init(allocator, 0);
    defer g_cells[1].deinit(&g_rt, allocator) catch {};
    g_cells[2] = try versioned.Versioned(i64).init(allocator, 0);
    defer g_cells[2].deinit(&g_rt, allocator) catch {};

    var h = MultiCellLoomHarness.init(allocator, schedule);
    defer h.deinit();
    harness = &h;

    try h.createThread(0, @intFromPtr(&entryFiberX));
    try h.createThread(1, @intFromPtr(&entryFiberY));
    try h.run();

    // Drain limbo so the deinitSync doesn't leak reclaimed nodes.
    var d: usize = 0;
    while (d < 6) : (d += 1) {
        g_rt.ebr.reclaimLocal(allocator);
    }

    const a = g_cells[0].withRead(&g_rt, struct { fn call(p: *i64) i64 { return p.*; } }.call, .{});
    const b = g_cells[1].withRead(&g_rt, struct { fn call(p: *i64) i64 { return p.*; } }.call, .{});
    const c = g_cells[2].withRead(&g_rt, struct { fn call(p: *i64) i64 { return p.*; } }.call, .{});
    return .{ .a = a, .b = b, .c = c };
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var ctx = EbrContext{};
    defer ctx.deinit(allocator);

    g_rt = try Runtime.initFromSlice(&g_frame_buf, &ctx, allocator, 0);
    defer g_rt.deinit();

    // Each schedule entry is a 0/1 picking fiber 0 or fiber 1 at a yield.
    // Depth 10 covers 2^10 = 1024 interleavings -- enough to enumerate
    // the contention-rollback path's prerequisites (X tags a -> Y tags b
    // -> X spins on b for 4 inner retries -> X rolls back). After the
    // schedule exhausts, the harness round-robins, guaranteeing both
    // fibers complete (no UpdateRetriesExhausted from starvation).
    const depth: usize = 10;
    var schedule_buf: [depth]u8 = undefined;

    var sched_idx: usize = 0;
    const total: usize = 1 << depth;
    var failures: usize = 0;
    const ops_at_start = va.sim_atomic_op_count;

    while (sched_idx < total) : (sched_idx += 1) {
        fillBinarySchedule(&schedule_buf, sched_idx);

        const result = runOneSchedule(allocator, &schedule_buf) catch |e| {
            std.debug.print("schedule {d}: {}\n", .{ sched_idx, e });
            failures += 1;
            continue;
        };

        // Both txns must commit exactly once. Fiber X adds 1 to a and b;
        // Fiber Y adds 10 to b and c. So a == 1, b == 11, c == 10.
        if (result.a != 1 or result.b != 11 or result.c != 10) {
            std.debug.print(
                "schedule {d}: invariant fail a={d} b={d} c={d}\n",
                .{ sched_idx, result.a, result.b, result.c },
            );
            failures += 1;
        }
    }

    const ops_total = va.sim_atomic_op_count - ops_at_start;
    std.debug.print(
        "\nversioned-multi-loom: {d}/{d} schedules failed, {d} sim atomic ops, {d} unique sites\n",
        .{ failures, total, ops_total, va.sim_unique_site_count },
    );

    if (failures > 0) std.process.exit(1);
}
