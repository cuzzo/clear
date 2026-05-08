//! VOPR scenarios for lib/data-structures.zig.
//!
//! Goal: get the file FILE-LOADED in the VOPR cobertura. Before this
//! test no VOPR executable imported data-structures, so the 15
//! sharded inner-lock spinlock markers there were FILE-NOT-LOADED in
//! the gap report. With this exe wired into coverage-vopr the file
//! is instrumented and per-marker coverage shows up.
//!
//! Heavy Stream/InfStream paths require a real fiber stack to drive
//! the producer/consumer dance; we don't go there. The simple
//! single-thread paths (setError, close on empty inner, deinit
//! immediate) are enough to load the file.

const std = @import("std");

const ebr_mod = @import("../lib/ebr.zig");
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const sim_atomic = @import("vopr-atomic.zig");

// `bind` with stub deps -- lib/data-structures.zig's collection types
// take cleanup / refcount hooks via the deps struct so user code can
// override them. VOPR's smoke scenarios don't need real cleanup.
pub const DataStructures = @import("../lib/data-structures.zig").bind(struct {
    pub fn cleanup(comptime T: type, alloc: std.mem.Allocator, cptr: *const T) void {
        _ = alloc;
        _ = cptr;
    }
    pub fn needsCleanup(comptime T: type) bool {
        _ = T;
        return false;
    }
    pub fn refInnerType(comptime T: type) ?type {
        _ = T;
        return null;
    }
    pub fn releaseOne(comptime T: type, alloc: std.mem.Allocator, value: T) void {
        _ = alloc;
        _ = value;
    }
    pub fn partitionedMapDelayCtxDestroy() bool {
        return false;
    }
});

var gpa: std.heap.DebugAllocator(.{}) = .{};

pub fn checkLeaksAndReset() !void {
    if (gpa.deinit() != .ok) return error.LeaksDetected;
    gpa = .{};
    sim_atomic.resetFault();
}

/// File-load gate: simply referencing DataStructures.Stream(i64) in
/// this scenario forces lib/data-structures.zig's machinery to
/// instantiate, so kcov instruments the file. We do a minimal
/// construct + immediate destroy without entering push/next; those
/// paths need real fibers and aren't on the file-load critical path.
///
/// Once this passes, the 15 inner-lock spinlock markers in
/// data-structures.zig flip from FILE-NOT-LOADED to instrumented (0-hit
/// or hit, depending on whether the scenario actually entered them).
pub fn testStreamFileLoad() !void {
    const allocator = gpa.allocator();

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }

    const StreamI64 = DataStructures.Stream(i64);
    var stream = try StreamI64.spawnNew(allocator, &sched);
    defer allocator.destroy(stream.inner);

    // setError takes the inner.lock spinlock at L816. Direct call,
    // no fiber needed -- write under the spinlock is unconditional.
    stream.setError(error.VoprFileLoadProbe);

    // Sanity: error stored.
    if (stream.inner.err == null) return error.SetErrorDidNotStick;
}

/// File-loads InfStream and exercises the fast-path spinlock that
/// fires when the consumer wake check runs on an empty-buffer push.
/// Then closes the stream to hit the close-path spinlock at L1083.
/// All single-thread; no fiber needed since no producer/consumer
/// task is registered, so the wake-consumer branch short-circuits.
pub fn testInfStreamPushCloseFileLoad() !void {
    const allocator = gpa.allocator();

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }

    const InfStreamI64 = DataStructures.InfStream(i64);
    var stream = try InfStreamI64.spawnNew(allocator, &sched);
    defer allocator.destroy(stream.inner);

    // First push: h=0, t=0 -> h == t -> wake-consumer spinlock branch.
    try stream.push(11);
    // Second push: buffer non-empty, no spinlock taken (fast path).
    try stream.push(22);

    // close() takes the spinlock at L1083, sets closed, calls wg.done.
    stream.close();
}

/// Drives InfStream.push + close spinlocks under swap fault injection.
/// Each push that hits the wake-consumer branch retries the swap; with
/// fault rate >0 the retry body executes deterministically.
pub fn testInfStreamSpinlockUnderFault() !void {
    const allocator = gpa.allocator();

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }

    const InfStreamI64 = DataStructures.InfStream(i64);
    var stream = try InfStreamI64.spawnNew(allocator, &sched);
    defer allocator.destroy(stream.inner);

    sim_atomic.seedFault(6);
    sim_atomic.inject_swap_busy_fault = true;
    sim_atomic.inject_swap_busy_rate = 7000;

    const synthetic_before = sim_atomic.sim_swap_synthetic_fault_count;

    // First push triggers the wake-consumer spinlock; subsequent
    // pushes don't take the lock (buffer non-empty). Drain via tail
    // bumps so each iteration's push hits the wake branch again.
    var i: i64 = 0;
    while (i < 4) : (i += 1) {
        try stream.push(i);
        // Manually drain the buffer so the next push sees h == t.
        const h = stream.inner.head.load(.monotonic);
        stream.inner.tail.store(h, .release);
    }
    stream.close();

    const synthetic_after = sim_atomic.sim_swap_synthetic_fault_count;
    if (synthetic_after == synthetic_before) return error.NoSwapFaultInjected;
}

/// Drives Stream.setError's spinlock retry body under swap fault
/// injection. With Stream.Inner.lock now routed through the comptime
/// Atomic alias, SimAtomic's inject_swap_busy_fault reaches the
/// `lock.swap(1, .acquire)` at lib/data-structures.zig:816 and the
/// retry body (the inline yield path) executes deterministically.
pub fn testStreamSetErrorUnderFault() !void {
    const allocator = gpa.allocator();

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }

    const StreamI64 = DataStructures.Stream(i64);
    var stream = try StreamI64.spawnNew(allocator, &sched);
    defer allocator.destroy(stream.inner);

    sim_atomic.seedFault(5);
    sim_atomic.inject_swap_busy_fault = true;
    sim_atomic.inject_swap_busy_rate = 7000;

    const synthetic_before = sim_atomic.sim_swap_synthetic_fault_count;

    // Four setError() calls each contest the lock. With 70% rate the
    // spinlock body retries on average ~2 times per call.
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        stream.setError(error.VoprFaultProbe);
    }

    const synthetic_after = sim_atomic.sim_swap_synthetic_fault_count;
    if (synthetic_after == synthetic_before) return error.NoSwapFaultInjected;
}
