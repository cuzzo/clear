//! Loom-shim sanity test for the MVCC primitives.
//!
//! This file exercises the SimAtomic comptime shim in versioned.zig
//! and ebr.zig.  When the root module exports `SimAtomic`, every
//! atomic load/store/cmpxchg in `Versioned(T)` and `EbrContext` /
//! `ThreadLocalEbr` becomes a deterministic yield point.  Without
//! `SimAtomic` in root, the shim resolves to `std.atomic.Value` and
//! these tests just exercise the same single-threaded path as T1.
//!
//! Why this file exists in addition to T1's `shared-memory-test.zig`:
//!   - T1 uses std.atomic.Value directly (compiles under either alias).
//!   - This file has the test infrastructure ready for a future
//!     full-fiber Loom harness like `parking-lot-loom.zig` (~600 LOC),
//!     where:
//!       1. The wrapper file (e.g. `shared-memory-loom-driver.zig`)
//!          re-exports SimAtomic at root.
//!       2. A LoomHarness fires N virtual fibers running mvcc ops.
//!       3. Each SimAtomic op yields via fiber.yield(), letting the
//!          coordinator pick which fiber runs next.
//!       4. PRNG / exhaustive enumeration drives interleaving coverage.
//!
//! The shim is the foundation step; the harness is the next investment.
//! T3's std.Thread stress tests are sufficient for catching the
//! common race classes today; Loom adds value for the rare
//! interleavings the OS scheduler doesn't naturally hit (e.g. EBR's
//! `enter()` 2-step active+local race window).

const std = @import("std");
const testing = std.testing;
const fc = @import("fiber-core.zig");
const root = @import("root");
const sim_atomic = if (@hasDecl(root, "SimAtomicState")) root.SimAtomicState else @import("vopr-atomic.zig");

const ebr_mod = @import("../lib/ebr.zig");
const versioned = @import("versioned.zig");
const Runtime = @import("runtime.zig").Runtime;
const scheduler_mod = @import("scheduler.zig");

const EbrContext = ebr_mod.EbrContext;
const ThreadLocalEbr = ebr_mod.ThreadLocalEbr;

const Fiber = fc.Fiber;
const Context = fc.Context;
const STACK_SIZE = 64 * 1024;
const MAX_STEPS = 10_000;

var pin_harness: *PinDepthLoomHarness = undefined;
var wake_harness: *WakeGateLoomHarness = undefined;

const PinDepthLoomHarness = struct {
    fibers: [2]Fiber = undefined,
    stacks: [2][]u8 = [_][]u8{ &.{}, &.{} },
    main_ctx: Context = undefined,
    done: [2]bool = [_]bool{ false, false },
    schedule: []const u8,
    pos: usize = 0,
    allocator: std.mem.Allocator,
    ctx: EbrContext = .{},
    local: ThreadLocalEbr,
    violation: bool = false,
    observed_pinned: bool = false,
    observed_inner_window: bool = false,
    outer_hold_window: bool = false,

    fn init(allocator: std.mem.Allocator, schedule: []const u8) PinDepthLoomHarness {
        var h = PinDepthLoomHarness{
            .schedule = schedule,
            .allocator = allocator,
            .local = ThreadLocalEbr{ .context = undefined },
        };
        h.local.context = &h.ctx;
        return h;
    }

    fn deinit(self: *PinDepthLoomHarness) void {
        fc.__fiber = null;
        fc.__fiber_parent_ctx = null;
        fc.__fiber_stack_limit = null;
        self.local.deinit(self.allocator);
        self.ctx.deinit(self.allocator);
        for (&self.stacks) |*stack| {
            if (stack.len > 0) {
                self.allocator.free(stack.*);
                stack.* = &.{};
            }
        }
    }

    fn createThread(self: *PinDepthLoomHarness, id: usize, entry_fn: usize) !void {
        self.stacks[id] = try self.allocator.alloc(u8, STACK_SIZE);
        self.fibers[id] = Fiber.init(self.stacks[id], entry_fn, .Large);
        self.done[id] = false;
    }

    fn pickThread(self: *PinDepthLoomHarness) usize {
        if (self.done[0]) return 1;
        if (self.done[1]) return 0;
        const bit = if (self.pos < self.schedule.len) self.schedule[self.pos] else 0;
        self.pos += 1;
        return bit & 1;
    }

    fn run(self: *PinDepthLoomHarness) !void {
        var steps: usize = 0;
        while (steps < MAX_STEPS) : (steps += 1) {
            if (self.done[0] and self.done[1]) break;
            const chosen = self.pickThread();
            self.fibers[chosen].switchTo(&self.main_ctx);
        }
        fc.__fiber = null;
        fc.__fiber_parent_ctx = null;
        fc.__fiber_stack_limit = null;
        if (steps >= MAX_STEPS) return error.StepLimitExceeded;
        if (self.violation) return error.PinDepthInactiveWhilePinned;
    }

    fn observe(self: *PinDepthLoomHarness) void {
        const depth = self.local.pin_depth.load(.seq_cst);
        const active = self.local.is_active.load(.seq_cst);
        if (depth > 0) {
            self.observed_pinned = true;
            if (self.outer_hold_window) {
                if (!active) self.violation = true;
                if (depth == 1) self.observed_inner_window = true;
            }
        }
    }
};

fn entryNestedPinReader() callconv(.c) void {
    const h = pin_harness;
    h.local.enter();
    h.local.enter();
    h.local.exit();
    h.outer_hold_window = true;

    // Keep the inner-exit/outer-still-held window open long enough for
    // exhaustive schedules to observe it. These are explicit Loom thread
    // yields, not production retries/timers/IO.
    fc.__fiber.?.yield();
    fc.__fiber.?.yield();

    h.outer_hold_window = false;
    h.local.exit();
    h.done[0] = true;
    fc.__fiber.?.yield();
    unreachable;
}

fn entryPinObserver() callconv(.c) void {
    const h = pin_harness;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        h.observe();
        fc.__fiber.?.yield();
    }
    h.done[1] = true;
    fc.__fiber.?.yield();
    unreachable;
}

fn runPinDepthSchedule(allocator: std.mem.Allocator, schedule: []const u8) !PinDepthLoomHarness {
    var h = PinDepthLoomHarness.init(allocator, schedule);
    errdefer h.deinit();
    pin_harness = &h;
    try h.createThread(0, @intFromPtr(&entryNestedPinReader));
    try h.createThread(1, @intFromPtr(&entryPinObserver));
    try h.run();
    return h;
}

fn fillBinarySchedule(buf: []u8, value: usize) void {
    for (buf, 0..) |*slot, i| {
        slot.* = @intCast((value >> @intCast(i)) & 1);
    }
}

test "Loom-shim sanity: shared-memory.Atomic resolves to std.atomic.Value when SimAtomic absent" {
    // No `pub const SimAtomic = ...` at root, so the comptime
    // resolution should land on std.atomic.Value(*T).  Verify by
    // checking the underlying type's API surface (load/store/cmpxchg).
    const PtrT = versioned.Atomic(*u64);
    var v: u64 = 0;
    var a = PtrT.init(&v);
    _ = a.load(.acquire);
    a.store(&v, .release);
    _ = a.cmpxchgWeak(&v, &v, .release, .monotonic);
    // If we got here, the shim type provided the std.atomic.Value
    // API. (Pin against accidental shim-type narrowing.)
}

test "Loom-shim sanity: ebr.Atomic resolves to std.atomic.Value when SimAtomic absent" {
    const U32A = ebr_mod.Atomic(u32);
    var x = U32A.init(0);
    _ = x.load(.acquire);
    x.store(7, .release);
    _ = x.cmpxchgWeak(@as(u32, 7), @as(u32, 8), .release, .monotonic);
}

pub fn testNestedEbrPinDepthLoom(allocator: std.mem.Allocator, require_sim_atomic: bool) !void {
    const before_ops = sim_atomic.sim_atomic_op_count;
    var saw_pinned = false;
    var saw_inner_window = false;

    var schedule: [12]u8 = undefined;
    var n: usize = 0;
    while (n < (1 << schedule.len)) : (n += 1) {
        fillBinarySchedule(&schedule, n);
        var h = try runPinDepthSchedule(allocator, &schedule);
        saw_pinned = saw_pinned or h.observed_pinned;
        saw_inner_window = saw_inner_window or h.observed_inner_window;
        h.deinit();
    }

    if (require_sim_atomic and sim_atomic.sim_atomic_op_count == before_ops) {
        return error.SimAtomicNotActive;
    }
    if (!saw_pinned) return error.PinDepthPinnedWindowNotObserved;
    if (!saw_inner_window) return error.PinDepthInnerExitWindowNotObserved;
}

test "loom: nested EBR pin keeps is_active true until final exit" {
    // Under `zig test`, @import("root") is the generated test runner,
    // so this is a structural fallback. The real SimAtomic-backed run is
    // the `versioned-loom-test` executable wired in build.zig.
    try testNestedEbrPinDepthLoom(testing.allocator, false);
}

const WakeGateLoomHarness = struct {
    fibers: [2]Fiber = undefined,
    stacks: [2][]u8 = [_][]u8{ &.{}, &.{} },
    main_ctx: Context = undefined,
    done: [2]bool = [_]bool{ false, false },
    schedule: []const u8,
    pos: usize = 0,
    allocator: std.mem.Allocator,
    event: scheduler_mod.SmartEventFd = .{ .fd = -1 },
    work_available: bool = false,
    scheduler_blocked: bool = false,
    writes: u32 = 0,
    violation: bool = false,
    consumed_prepark_notify: bool = false,

    fn init(allocator: std.mem.Allocator, schedule: []const u8) WakeGateLoomHarness {
        return .{ .schedule = schedule, .allocator = allocator };
    }

    fn deinit(self: *WakeGateLoomHarness) void {
        fc.__fiber = null;
        fc.__fiber_parent_ctx = null;
        fc.__fiber_stack_limit = null;
        for (&self.stacks) |*stack| {
            if (stack.len > 0) {
                self.allocator.free(stack.*);
                stack.* = &.{};
            }
        }
    }

    fn createThread(self: *WakeGateLoomHarness, id: usize, entry_fn: usize) !void {
        self.stacks[id] = try self.allocator.alloc(u8, STACK_SIZE);
        self.fibers[id] = Fiber.init(self.stacks[id], entry_fn, .Large);
        self.done[id] = false;
    }

    fn pickThread(self: *WakeGateLoomHarness) usize {
        if (self.done[0]) return 1;
        if (self.done[1]) return 0;
        const bit = if (self.pos < self.schedule.len) self.schedule[self.pos] else 0;
        self.pos += 1;
        return bit & 1;
    }

    fn run(self: *WakeGateLoomHarness) !void {
        var steps: usize = 0;
        while (steps < MAX_STEPS) : (steps += 1) {
            if (self.done[0] and self.done[1]) break;
            const chosen = self.pickThread();
            self.fibers[chosen].switchTo(&self.main_ctx);
        }
        fc.__fiber = null;
        fc.__fiber_parent_ctx = null;
        fc.__fiber_stack_limit = null;
        if (steps >= MAX_STEPS) return error.StepLimitExceeded;
        if (self.violation) return error.WakeGateMissedWake;
    }
};

fn entryWakeScheduler() callconv(.c) void {
    const h = wake_harness;
    const should_sleep = h.event.prepareSleep();
    if (!should_sleep) {
        h.consumed_prepark_notify = true;
        h.done[0] = true;
        fc.__fiber.?.yield();
        unreachable;
    }

    // Window 1: producer may notify after prepareSleep and before the
    // scheduler's last work check.
    fc.__fiber.?.yield();
    if (h.work_available) {
        h.event.finishSleep();
        h.done[0] = true;
        fc.__fiber.?.yield();
        unreachable;
    }

    // Window 2: producer may notify after the last work check but before
    // the scheduler enters the blocking syscall. It must observe Parked
    // and request an eventfd write.
    fc.__fiber.?.yield();
    h.scheduler_blocked = true;

    // Window 3: producer may notify while the scheduler is logically
    // blocked. It must request an eventfd write.
    fc.__fiber.?.yield();
    h.event.finishSleep();
    h.scheduler_blocked = false;
    h.done[0] = true;
    fc.__fiber.?.yield();
    unreachable;
}

fn entryWakeProducer() callconv(.c) void {
    const h = wake_harness;
    fc.__fiber.?.yield();
    h.work_available = true;
    if (h.event.armNotify()) h.writes += 1;
    if (h.scheduler_blocked and h.writes == 0) h.violation = true;
    h.done[1] = true;
    fc.__fiber.?.yield();
    unreachable;
}

fn runWakeGateSchedule(allocator: std.mem.Allocator, schedule: []const u8) !WakeGateLoomHarness {
    var h = WakeGateLoomHarness.init(allocator, schedule);
    errdefer h.deinit();
    wake_harness = &h;
    try h.createThread(0, @intFromPtr(&entryWakeScheduler));
    try h.createThread(1, @intFromPtr(&entryWakeProducer));
    try h.run();
    return h;
}

pub fn testSchedulerWakeGateLoom(allocator: std.mem.Allocator, require_sim_atomic: bool) !void {
    const before_ops = sim_atomic.sim_atomic_op_count;
    var saw_blocked_write = false;
    var saw_prepark_token = false;

    var schedule: [10]u8 = undefined;
    var n: usize = 0;
    while (n < (1 << schedule.len)) : (n += 1) {
        fillBinarySchedule(&schedule, n);
        var h = try runWakeGateSchedule(allocator, &schedule);
        saw_blocked_write = saw_blocked_write or h.writes > 0;
        saw_prepark_token = saw_prepark_token or h.consumed_prepark_notify;
        h.deinit();
    }

    if (require_sim_atomic and sim_atomic.sim_atomic_op_count == before_ops) {
        return error.SimAtomicNotActive;
    }
    if (!saw_blocked_write) return error.WakeGateParkedNotifyWindowNotObserved;
    if (!saw_prepark_token) return error.WakeGatePreparkNotifyWindowNotObserved;
}

test "loom: scheduler wake gate does not miss notify around park" {
    try testSchedulerWakeGateLoom(testing.allocator, false);
}

// Smoke test: full Versioned(T) + EBR lifecycle with the shim in place.
// Same test as in T1 but routed through the shim — proves the shim
// doesn't break the protocol under the default (real-atomic) build.
test "Loom-shim sanity: full Versioned(T) lifecycle through the shim" {
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);

    var frame: [1024]u8 = undefined;
    var rt = try Runtime.initFromSlice(&frame, &ctx, testing.allocator, 0);
    defer rt.deinit();

    var s = try versioned.Versioned(i64).init(testing.allocator, 100);
    defer s.deinit(&rt, testing.allocator) catch unreachable;

    const observed = s.withRead(&rt, struct {
        fn call(p: *i64) i64 { return p.*; }
    }.call, .{});
    try testing.expectEqual(@as(i64, 100), observed);

    try s.update(&rt, testing.allocator, struct {
        fn call(p: *i64, v: i64) void { p.* = v; }
    }.call, .{@as(i64, 200)});

    const after = s.withRead(&rt, struct {
        fn call(p: *i64) i64 { return p.*; }
    }.call, .{});
    try testing.expectEqual(@as(i64, 200), after);
}

// Gap 5: pin-survives-retire ordering validation through the SimAtomic shim.
//
// The C2 contract test in versioned-stress-test.zig validates that a held
// Guard's pointer keeps dereferencing across concurrent retire+reclaim
// cycles. That's a real-thread test; under the OS scheduler, the producer
// fiber drives writer iterations the natural way (mostly forward).
//
// This deterministic version sequences pin / update / reclaim cycles
// tightly through the same SimAtomic-instrumented path. It catches a
// different class of regression: an ordering bug in the EBR contract
// itself (e.g. retire stamping the wrong epoch, reclaimLocal sweeping
// items still inside a held thread's grace window) that only surfaces
// when many short cycles run back-to-back without the OS rescheduling.
//
// Property: a Guard taken at update step `k` continues to dereference
// to value `k` even after updates k+1..k+N retire intermediate snapshots
// and reclaim cycles fire. The expectation flows from the EBR pin
// preventing reclamation past `local_epoch[k]`.
test "Versioned: pin survives N successive update+reclaim cycles (single-thread EBR contract)" {
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);

    var frame: [2048]u8 = undefined;
    var rt = try Runtime.initFromSlice(&frame, &ctx, testing.allocator, 0);
    defer rt.deinit();
    try ctx.register(testing.allocator, rt.ebr);
    defer ctx.unregister(rt.ebr);

    var s = try versioned.Versioned(i64).init(testing.allocator, 0);
    defer {
        s.deinit(&rt, testing.allocator) catch unreachable;
        var i: usize = 0;
        while (i < 6) : (i += 1) {
            ctx.reclaim(testing.allocator);
            rt.ebr.reclaimLocal(testing.allocator);
        }
    }

    // Seed with a known value at "epoch 0" of the test, then pin
    // a Guard. The pin must hold this value alive across all
    // subsequent updates + reclaims.
    try s.update(&rt, testing.allocator, struct {
        fn call(p: *i64, v: i64) void { p.* = v; }
    }.call, .{@as(i64, 1000)});

    var pinned = s.read(&rt);
    defer pinned.release();
    const captured: i64 = pinned.get().*;
    try testing.expectEqual(@as(i64, 1000), captured);

    // 200 update+reclaim cycles. Each iteration:
    //   1. Update: writes a new value, retires the prior snapshot.
    //   2. ReclaimLocal: drains thread-local limbo (skips items
    //      below safe_threshold; the held Guard's epoch is the
    //      threshold, so items at/after that epoch stay alive).
    //   3. Re-check the pinned guard's value -- must still be 1000.
    //
    // If the EBR contract were broken (e.g. limbo swept past the
    // guard's epoch, or retire used the wrong epoch), `pinned.get().*`
    // would either dereference freed memory (DebugAllocator catches
    // post-test) or read whatever new value happens to live where
    // the freed node sat (caught by the inline equality check).
    var k: usize = 0;
    while (k < 200) : (k += 1) {
        const new_v: i64 = 2000 + @as(i64, @intCast(k));
        try s.update(&rt, testing.allocator, struct {
            fn call(p: *i64, v: i64) void { p.* = v; }
        }.call, .{new_v});
        rt.ebr.reclaimLocal(testing.allocator);
        // Every 16 iterations, also drive the global reclaim path so
        // both the local-limbo and orphan-list paths get exercised.
        if ((k & 0xF) == 0xF) ctx.reclaim(testing.allocator);

        // Pinned guard still observes its captured value.
        try testing.expectEqual(captured, pinned.get().*);
    }

    // A FRESH read sees the latest published value (sanity that
    // updates actually landed, not just bypassed).
    var fresh = s.read(&rt);
    defer fresh.release();
    try testing.expectEqual(@as(i64, 2000 + 199), fresh.get().*);
}
