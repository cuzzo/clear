pub const CLEAR_FRAME_DEBUG = false;

const std = @import("std");
const fc = @import("runtime/fiber-core.zig");
const obs = @import("lib/observable.zig");
const va = @import("runtime/vopr-atomic.zig");

pub const SimAtomic = va.SimAtomic;

const Fiber = fc.Fiber;
const Context = fc.Context;

const STACK_SIZE = 64 * 1024;
const MAX_STEPS = 200_000;

const SumTerminal = obs.ObservableSum(i64);
const MaxTerminal = obs.ObservableMax(i64);
const MinTerminal = obs.ObservableMin(i64);
const AnyTerminal = obs.ObservableAny();
const AllTerminal = obs.ObservableAll();
const ObservableI64 = obs.Observable(i64);
const StreamSetI64 = obs.StreamSetCfg(i64, .{ .initial_capacity = 4 });
const ObservableSetI64 = obs.ObservableTerminal(StreamSetI64);

var harness: *LoomHarness = undefined;
var g_sum: *SumTerminal = undefined;
var g_max: *MaxTerminal = undefined;
var g_min: *MinTerminal = undefined;
var g_any: *AnyTerminal = undefined;
var g_all: *AllTerminal = undefined;
var g_cell: ObservableI64 = undefined;
var g_cell_done: bool = false;
var g_set: *ObservableSetI64 = undefined;
var g_set_done: bool = false;

const Slot = struct {
    fiber: Fiber = undefined,
    stack: []u8 = &.{},
    done: bool = false,
};

const LoomHarness = struct {
    slots: [2]Slot = .{ .{}, .{} },
    main_ctx: Context = undefined,
    schedule: []const u8,
    pos: usize = 0,
    allocator: std.mem.Allocator,
    failure: ?anyerror = null,

    fn init(allocator: std.mem.Allocator, schedule: []const u8) LoomHarness {
        return .{ .allocator = allocator, .schedule = schedule };
    }

    fn deinit(self: *LoomHarness) void {
        fc.__fiber = null;
        fc.__fiber_parent_ctx = null;
        fc.__fiber_stack_limit = null;
        for (&self.slots) |*slot| {
            if (slot.stack.len > 0) {
                self.allocator.free(slot.stack);
                slot.stack = &.{};
            }
        }
    }

    fn createThread(self: *LoomHarness, id: usize, entry_fn: usize) !void {
        if (self.slots[id].stack.len == 0) {
            self.slots[id].stack = try self.allocator.alloc(u8, STACK_SIZE);
        }
        self.slots[id].fiber = Fiber.init(self.slots[id].stack, entry_fn, .Large);
        self.slots[id].done = false;
    }

    fn fail(self: *LoomHarness, err: anyerror) void {
        if (self.failure == null) self.failure = err;
    }

    fn pickThread(self: *LoomHarness) usize {
        if (self.slots[0].done) return 1;
        if (self.slots[1].done) return 0;
        const bit = if (self.pos < self.schedule.len)
            self.schedule[self.pos] & 1
        else
            @as(u8, @intCast(self.pos & 1));
        self.pos += 1;
        return bit;
    }

    fn run(self: *LoomHarness) !void {
        var steps: usize = 0;
        while (steps < MAX_STEPS) : (steps += 1) {
            if (self.slots[0].done and self.slots[1].done) break;
            const chosen = self.pickThread();
            self.slots[chosen].fiber.switchTo(&self.main_ctx);
        }
        fc.__fiber = null;
        fc.__fiber_parent_ctx = null;
        fc.__fiber_stack_limit = null;
        if (self.failure) |err| return err;
        if (steps >= MAX_STEPS) return error.StepLimitExceeded;
    }
};

fn finishThread(id: usize) noreturn {
    harness.slots[id].done = true;
    while (true) fc.__fiber.?.yield();
}

fn entrySumProducer() callconv(.c) void {
    g_sum.inner.add(7);
    g_sum.inner.add(11);
    g_sum.inner.add(13);
    g_sum.finish();
    g_sum.finish();
    finishThread(0);
}

fn entrySumReader() callconv(.c) void {
    var last: i64 = 0;
    while (!g_sum.isFinished()) {
        if (g_sum.started()) {
            const value = g_sum.view();
            if (value < 7 or value > 31 or value < last) {
                harness.fail(error.SumViewRegression);
            }
            last = value;
        }
        fc.__fiber.?.yield();
    }
    if (g_sum.view() != 31) harness.fail(error.SumFinalWrong);
    finishThread(1);
}

fn entryExtremaProducer() callconv(.c) void {
    g_max.inner.submit(7);
    g_min.inner.submit(7);
    g_any.inner.submit(false);
    g_all.inner.submit(true);

    g_max.inner.submit(42);
    g_min.inner.submit(-5);
    g_any.inner.submit(true);
    g_all.inner.submit(false);

    g_max.inner.submit(13);
    g_min.inner.submit(99);
    g_any.inner.submit(false);
    g_all.inner.submit(true);

    g_max.finish();
    g_min.finish();
    g_any.finish();
    g_all.finish();
    finishThread(0);
}

fn entryExtremaReader() callconv(.c) void {
    while (!(g_max.isFinished() and g_min.isFinished() and g_any.isFinished() and g_all.isFinished())) {
        if (g_max.started()) {
            const max_value = g_max.view();
            if (max_value < 7 or max_value > 42) harness.fail(error.MaxViewOutOfRange);
        }
        if (g_min.started()) {
            const min_value = g_min.view();
            if (min_value < -5 or min_value > 7) harness.fail(error.MinViewOutOfRange);
        }
        if (g_any.started()) _ = g_any.view();
        if (g_all.started()) _ = g_all.view();
        fc.__fiber.?.yield();
    }
    if (g_max.view() != 42) harness.fail(error.MaxFinalWrong);
    if (g_min.view() != -5) harness.fail(error.MinFinalWrong);
    if (!g_any.view()) harness.fail(error.AnyFinalWrong);
    if (g_all.view()) harness.fail(error.AllFinalWrong);
    finishThread(1);
}

fn entryCellProducer() callconv(.c) void {
    g_cell.set(1) catch {
        harness.fail(error.ObservableSetFailed);
        g_cell_done = true;
        finishThread(0);
    };
    g_cell.set(2) catch {
        harness.fail(error.ObservableSetFailed);
        g_cell_done = true;
        finishThread(0);
    };
    g_cell.set(3) catch {
        harness.fail(error.ObservableSetFailed);
        g_cell_done = true;
        finishThread(0);
    };
    g_cell_done = true;
    finishThread(0);
}

fn entryCellReader() callconv(.c) void {
    var last: i64 = 0;
    while (!g_cell_done) {
        var handle = g_cell.view();
        const value = handle.value().*;
        if (value < 0 or value > 3 or value < last) harness.fail(error.ObservableViewRegression);
        last = value;
        handle.release();
        fc.__fiber.?.yield();
    }
    var final_handle = g_cell.view();
    defer final_handle.release();
    if (final_handle.value().* != 3) harness.fail(error.ObservableFinalWrong);
    finishThread(1);
}

fn entrySetProducer() callconv(.c) void {
    var i: i64 = 0;
    while (i < 16) : (i += 1) {
        _ = g_set.inner.submit(i) catch {
            harness.fail(error.StreamSetSubmitFailed);
            g_set_done = true;
            finishThread(0);
        };
    }
    g_set.finish();
    g_set_done = true;
    finishThread(0);
}

fn entrySetReader() callconv(.c) void {
    var last_len: usize = 0;
    while (!g_set_done) {
        var snap = g_set.inner.view();
        const len = snap.slice().len;
        if (len < last_len or len > 16) harness.fail(error.StreamSetViewRegression);
        last_len = len;
        snap.release();
        fc.__fiber.?.yield();
    }
    if (g_set.inner.len() != 16) harness.fail(error.StreamSetFinalWrong);
    finishThread(1);
}

fn fillBinarySchedule(buf: []u8, value: usize) void {
    for (buf, 0..) |*slot, i| {
        slot.* = @intCast((value >> @as(u6, @intCast(i))) & 1);
    }
}

fn runExhaustive(
    allocator: std.mem.Allocator,
    name: []const u8,
    depth: usize,
    scenario: *const fn (std.mem.Allocator, []const u8) anyerror!void,
) !void {
    const total: usize = @as(usize, 1) << @intCast(depth);
    const schedule = try allocator.alloc(u8, depth);
    defer allocator.free(schedule);

    var failures: usize = 0;
    var idx: usize = 0;
    while (idx < total) : (idx += 1) {
        fillBinarySchedule(schedule, idx);
        scenario(allocator, schedule) catch |err| {
            std.debug.print("{s} schedule {d}: {}\n", .{ name, idx, err });
            failures += 1;
            if (failures > 3) return error.TooManyObservableLoomFailures;
        };
    }
    if (failures != 0) return error.ObservableLoomFailures;
    std.debug.print("  {s}: {d} interleavings OK\n", .{ name, total });
}

fn runSumScenario(allocator: std.mem.Allocator, schedule: []const u8) !void {
    g_sum = try SumTerminal.new(allocator);
    defer g_sum.destroy(allocator);

    var h = LoomHarness.init(allocator, schedule);
    defer h.deinit();
    harness = &h;
    try h.createThread(0, @intFromPtr(&entrySumProducer));
    try h.createThread(1, @intFromPtr(&entrySumReader));
    try h.run();
}

fn runExtremaScenario(allocator: std.mem.Allocator, schedule: []const u8) !void {
    g_max = try MaxTerminal.new(allocator);
    defer g_max.destroy(allocator);
    g_min = try MinTerminal.new(allocator);
    defer g_min.destroy(allocator);
    g_any = try AnyTerminal.new(allocator);
    defer g_any.destroy(allocator);
    g_all = try AllTerminal.new(allocator);
    defer g_all.destroy(allocator);

    var h = LoomHarness.init(allocator, schedule);
    defer h.deinit();
    harness = &h;
    try h.createThread(0, @intFromPtr(&entryExtremaProducer));
    try h.createThread(1, @intFromPtr(&entryExtremaReader));
    try h.run();
}

fn runCellScenario(allocator: std.mem.Allocator, schedule: []const u8) !void {
    g_cell = try ObservableI64.init(allocator, 0);
    g_cell_done = false;
    defer g_cell.deinit();

    var h = LoomHarness.init(allocator, schedule);
    defer h.deinit();
    harness = &h;
    try h.createThread(0, @intFromPtr(&entryCellProducer));
    try h.createThread(1, @intFromPtr(&entryCellReader));
    try h.run();
}

fn runSetScenario(allocator: std.mem.Allocator, schedule: []const u8) !void {
    const inner = try StreamSetI64.init(allocator);
    g_set = try ObservableSetI64.newWith(allocator, inner);
    g_set_done = false;
    defer g_set.destroy(allocator);

    var h = LoomHarness.init(allocator, schedule);
    defer h.deinit();
    harness = &h;
    try h.createThread(0, @intFromPtr(&entrySetProducer));
    try h.createThread(1, @intFromPtr(&entrySetReader));
    try h.run();
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const ops_at_start = va.sim_atomic_op_count;

    try runExhaustive(allocator, "observable_sum_terminal", 8, &runSumScenario);
    try runExhaustive(allocator, "observable_extrema_bool_terminals", 8, &runExtremaScenario);
    try runExhaustive(allocator, "observable_snapshot_cell", 8, &runCellScenario);
    try runExhaustive(allocator, "observable_stream_set_grow", 8, &runSetScenario);

    const ops_total = va.sim_atomic_op_count - ops_at_start;
    std.debug.print(
        "  observable_loom_atomic_sites={d}, sim_atomic_ops={d}\n",
        .{ va.sim_unique_site_count, ops_total },
    );
    if (ops_total == 0) return error.SimAtomicDidNotFire;
    if (va.sim_unique_site_count < 35) return error.ObservableLoomCoverageRegressed;
}
