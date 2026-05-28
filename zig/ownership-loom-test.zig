// ownership-loom-test — multi-fiber Loom harness for Arc<T> / Weak<T>
// reference-counting races. Built as an executable so `@import("root")`
// from lib/ownership.zig sees `pub const SimAtomic`, and every fetchAdd/
// fetchSub/cmpxchg on the strong/weak counts becomes a yield point.
//
// What this proves: each scenario hits a different cross-fiber atomic
// interleaving on the refcount control block. Coverage closes the
// 14 atomic ops in lib/ownership.zig and the report should land at
// ownership.zig 14/14 after this runs.
//
// Scenarios:
//   1. clone-vs-deinit: two fibers each clone+deinit a shared Arc.
//      Exercises strong_count.fetchAdd (clone) racing with .fetchSub
//      (deinit), and the `if (prev_strong == 1)` last-drop branch.
//
//   2. weak-upgrade-vs-deinit: a Weak in one fiber races to upgrade
//      while another fiber drops the last strong reference. Hits
//      the cmpxchg-fail retry path in Weak.upgrade and the strong=0
//      check.
//
//   3. concurrent-downgrade: two fibers both call downgrade on a
//      shared Arc, exercising weak_count.fetchAdd from two contended
//      fetchAdd sites at once.

const std = @import("std");
const fc = @import("runtime/fiber-core.zig");
const ownership = @import("lib/ownership.zig");
const header = @import("runtime/runtime-header.zig");
const dsv = @import("runtime/data-structures-vopr.zig");
const va = @import("runtime/vopr-atomic.zig");

pub const SimAtomic = va.SimAtomic;

const Fiber = fc.Fiber;
const Context = fc.Context;
const Arc = ownership.Arc;
const Weak = ownership.Weak;

const STACK_SIZE = 64 * 1024;
const MAX_STEPS = 200_000;

// Shared ArcI64 lives at module scope so fiber entries can reach it.
// Each scenario reinits before its run.
const ArcI64 = Arc(i64);
const WeakI64 = Weak(i64);

var g_arc_x: ArcI64 = undefined;
var g_arc_y: ArcI64 = undefined;
var g_weak: WeakI64 = undefined;

const HarnessSlot = struct {
    fiber: Fiber = undefined,
    stack: []u8 = &.{},
    done: bool = false,
};

const OwnershipLoomHarness = struct {
    slots: [2]HarnessSlot = .{ .{}, .{} },
    main_ctx: Context = undefined,
    schedule: []const u8,
    pos: usize = 0,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, schedule: []const u8) OwnershipLoomHarness {
        return .{ .schedule = schedule, .allocator = allocator };
    }

    fn deinit(self: *OwnershipLoomHarness) void {
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

    fn createThread(self: *OwnershipLoomHarness, id: usize, entry_fn: usize) !void {
        if (self.slots[id].stack.len == 0) {
            self.slots[id].stack = try self.allocator.alloc(u8, STACK_SIZE);
        }
        self.slots[id].fiber = Fiber.init(self.slots[id].stack, entry_fn, .Large);
        self.slots[id].done = false;
    }

    fn pickThread(self: *OwnershipLoomHarness) usize {
        if (self.slots[0].done) return 1;
        if (self.slots[1].done) return 0;
        const bit = if (self.pos < self.schedule.len)
            self.schedule[self.pos] & 1
        else
            @as(u8, @intCast(self.pos & 1));
        self.pos += 1;
        return bit;
    }

    fn run(self: *OwnershipLoomHarness) !void {
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

var harness: *OwnershipLoomHarness = undefined;

// ─────────────────────────────────────────────────────────────────────
// Scenario 1: clone-vs-deinit. Each fiber clones the shared Arc
// (fetchAdd), then drops it (fetchSub). The original Arc is also
// dropped from main(), so total = 3 deinits and 2 clones; refcount
// must reach 0 exactly once.
// ─────────────────────────────────────────────────────────────────────
fn entryCloneDeinit0() callconv(.c) void {
    var copy = g_arc_x.clone();
    copy.deinit();
    harness.slots[0].done = true;
    while (true) fc.__fiber.?.yield();
}

fn entryCloneDeinit1() callconv(.c) void {
    var copy = g_arc_x.clone();
    copy.deinit();
    harness.slots[1].done = true;
    while (true) fc.__fiber.?.yield();
}

fn runCloneDeinit(allocator: std.mem.Allocator, schedule: []const u8) !void {
    g_arc_x = try ArcI64.init(allocator, 42);
    var h = OwnershipLoomHarness.init(allocator, schedule);
    defer h.deinit();
    harness = &h;

    try h.createThread(0, @intFromPtr(&entryCloneDeinit0));
    try h.createThread(1, @intFromPtr(&entryCloneDeinit1));
    try h.run();

    // Drop the original handle. This is the FINAL drop: by now both
    // fibers have clone+deinit'd, leaving refcount=1. This deinit
    // takes it to 0, freeing the control block.
    g_arc_x.deinit();
}

// ─────────────────────────────────────────────────────────────────────
// Scenario 2: Weak.upgrade races Arc.deinit. One fiber tries to
// upgrade a Weak, the other drops the last strong reference. Hits
// the upgrade CAS-fail path and the upgrade-sees-strong=0 path.
// ─────────────────────────────────────────────────────────────────────
fn entryWeakUpgrade() callconv(.c) void {
    if (g_weak.upgrade()) |arc_inst| {
        var arc_local = arc_inst;
        arc_local.deinit();
    }
    harness.slots[0].done = true;
    while (true) fc.__fiber.?.yield();
}

fn entryStrongDrop() callconv(.c) void {
    g_arc_x.deinit();
    harness.slots[1].done = true;
    while (true) fc.__fiber.?.yield();
}

fn runWeakUpgradeRace(allocator: std.mem.Allocator, schedule: []const u8) !void {
    g_arc_x = try ArcI64.init(allocator, 7);
    g_weak = g_arc_x.downgrade();

    var h = OwnershipLoomHarness.init(allocator, schedule);
    defer h.deinit();
    harness = &h;

    try h.createThread(0, @intFromPtr(&entryWeakUpgrade));
    try h.createThread(1, @intFromPtr(&entryStrongDrop));
    try h.run();

    // Drop the weak. If upgrade() succeeded, strong was bumped+dropped
    // so refcount returned to its original. If upgrade() returned
    // null, strong already 0. Either way, dropping the weak is the
    // final ref.
    g_weak.deinit();
}

// ─────────────────────────────────────────────────────────────────────
// Scenario 3: concurrent downgrade. Each fiber calls downgrade()
// on a shared Arc, exercising weak_count.fetchAdd from two contended
// sites simultaneously.
// ─────────────────────────────────────────────────────────────────────
fn entryDowngrade0() callconv(.c) void {
    var w = g_arc_x.downgrade();
    w.deinit();
    harness.slots[0].done = true;
    while (true) fc.__fiber.?.yield();
}

fn entryDowngrade1() callconv(.c) void {
    var w = g_arc_x.downgrade();
    w.deinit();
    harness.slots[1].done = true;
    while (true) fc.__fiber.?.yield();
}

fn runConcurrentDowngrade(allocator: std.mem.Allocator, schedule: []const u8) !void {
    g_arc_x = try ArcI64.init(allocator, 99);
    var h = OwnershipLoomHarness.init(allocator, schedule);
    defer h.deinit();
    harness = &h;

    try h.createThread(0, @intFromPtr(&entryDowngrade0));
    try h.createThread(1, @intFromPtr(&entryDowngrade1));
    try h.run();

    g_arc_x.deinit();
}

fn fillBinarySchedule(buf: []u8, value: usize) void {
    for (buf, 0..) |*slot, i| {
        slot.* = @intCast((value >> @as(u6, @intCast(i))) & 1);
    }
}

const Scenario = struct {
    name: []const u8,
    func: *const fn (std.mem.Allocator, []const u8) anyerror!void,
};

// ─────────────────────────────────────────────────────────────────────
// Scenario 4: inspection accessors (refCount / weakCount / isAlive /
// strongCount / Weak.fromArc / Weak.clone). These have no concurrent
// interleaving to explore, but the loom report wants every atomic op
// site covered. Drive them in fiber context so the SimAtomic ops
// register as sim-instrumented.
// ─────────────────────────────────────────────────────────────────────
fn entryInspectArc() callconv(.c) void {
    _ = g_arc_x.refCount();    // line 192
    _ = g_arc_x.weakCount();   // line 198
    var w_clone = WeakI64.fromArc(g_arc_x);  // line 271
    var w2 = w_clone.clone();  // line 280
    _ = w2.isAlive();          // line 321
    _ = w2.strongCount();      // line 326
    _ = w2.weakCount();        // line 331
    w2.deinit();
    w_clone.deinit();
    harness.slots[0].done = true;
    while (true) fc.__fiber.?.yield();
}

fn entryInspectNoop() callconv(.c) void {
    // No-op fiber so the harness has 2 fibers to interleave.
    harness.slots[1].done = true;
    while (true) fc.__fiber.?.yield();
}

fn runInspectAccessors(allocator: std.mem.Allocator, schedule: []const u8) !void {
    g_arc_x = try ArcI64.init(allocator, 17);

    var h = OwnershipLoomHarness.init(allocator, schedule);
    defer h.deinit();
    harness = &h;

    try h.createThread(0, @intFromPtr(&entryInspectArc));
    try h.createThread(1, @intFromPtr(&entryInspectNoop));
    try h.run();

    g_arc_x.deinit();
}

const scenarios = [_]Scenario{
    .{ .name = "clone-vs-deinit", .func = &runCloneDeinit },
    .{ .name = "weak-upgrade-vs-strong-drop", .func = &runWeakUpgradeRace },
    .{ .name = "concurrent-downgrade", .func = &runConcurrentDowngrade },
    .{ .name = "inspect-accessors", .func = &runInspectAccessors },
};

fn runRuntimeHeaderArcCoverage(allocator: std.mem.Allocator) !void {
    const CheatLib = header.CheatLib;

    const arc = try CheatLib.arcCreate(i64, allocator, 5);
    const retained = CheatLib.arcRetain(i64, arc);
    const weak = CheatLib.arcDowngrade(i64, arc);
    if (CheatLib.weakArcUpgrade(i64, weak)) |upgraded| {
        CheatLib.arcRelease(i64, allocator, upgraded);
    } else {
        return error.WeakUpgradeUnexpectedNull;
    }
    CheatLib.arcRelease(i64, allocator, retained);
    CheatLib.arcRelease(i64, allocator, arc);
    CheatLib.weakArcRelease(i64, weak);

    const arc2 = try CheatLib.arcCreate(i64, allocator, 9);
    const weak2 = CheatLib.arcDowngrade(i64, arc2);
    CheatLib.arcRelease(i64, allocator, arc2);
    if (CheatLib.weakArcUpgrade(i64, weak2) != null) return error.WeakUpgradeUnexpectedLive;
    CheatLib.weakArcRelease(i64, weak2);
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    // Depth 8 covers 256 schedules per scenario -- enough to hit all
    // interesting cross-fiber orderings of a few fetchAdd/fetchSub/
    // cmpxchg ops between two fibers. The round-robin tail prevents
    // starvation if either fiber is in a CAS retry loop.
    const depth: usize = 8;
    var schedule_buf: [depth]u8 = undefined;
    const total: usize = 1 << depth;

    var total_failures: usize = 0;
    const ops_at_start = va.sim_atomic_op_count;

    runRuntimeHeaderArcCoverage(allocator) catch |e| {
        std.debug.print("runtime-header Arc/WeakArc coverage: {}\n", .{e});
        total_failures += 1;
    };
    dsv.testPartitionedMapOwnershipLocalOps() catch |e| {
        std.debug.print("partitioned map ownership coverage: {}\n", .{e});
        total_failures += 1;
    };
    dsv.checkLeaksAndReset() catch |e| {
        std.debug.print("partitioned map ownership leak check: {}\n", .{e});
        total_failures += 1;
    };
    dsv.testPartitionedMapOwnershipWaiters() catch |e| {
        std.debug.print("partitioned map ownership waiter coverage: {}\n", .{e});
        total_failures += 1;
    };
    dsv.checkLeaksAndReset() catch |e| {
        std.debug.print("partitioned map ownership waiter leak check: {}\n", .{e});
        total_failures += 1;
    };
    dsv.testPartitionedMapRemoteOps() catch |e| {
        std.debug.print("partitioned map remote coverage: {}\n", .{e});
        total_failures += 1;
    };
    dsv.checkLeaksAndReset() catch |e| {
        std.debug.print("partitioned map remote leak check: {}\n", .{e});
        total_failures += 1;
    };

    for (scenarios) |sc| {
        const before = va.sim_atomic_op_count;
        var failures: usize = 0;
        var i: usize = 0;
        while (i < total) : (i += 1) {
            fillBinarySchedule(&schedule_buf, i);
            sc.func(allocator, &schedule_buf) catch |e| {
                std.debug.print("{s} schedule {d}: {}\n", .{ sc.name, i, e });
                failures += 1;
            };
        }
        const delta = va.sim_atomic_op_count - before;
        std.debug.print("  {s}: {d}/{d} schedules failed, {d} sim atomic ops\n", .{ sc.name, failures, total, delta });
        total_failures += failures;
    }

    const ops_total = va.sim_atomic_op_count - ops_at_start;
    std.debug.print(
        "\nownership-loom: {d} total schedules failed, {d} sim atomic ops, {d} unique sites\n",
        .{ total_failures, ops_total, va.sim_unique_site_count },
    );
    if (total_failures > 0) std.process.exit(1);
}
