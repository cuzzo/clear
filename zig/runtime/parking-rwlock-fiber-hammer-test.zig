// parking-rwlock-fiber-hammer-test.zig
//
// Hammer test for stackful-fiber ParkingRwLock under multi-scheduler
// load, targeting the wake-on-undo correctness bug in lockShared:
//
//   1. Writer W1 holds the lock. State = WRITE_LOCKED.
//   2. Reader R_A enters lockSharedSlow, parks.
//      State = WRITE_LOCKED + HAS_WAITERS, R_A in queue.
//   3. Reader R_B fast-paths: fetchAdd(1) -> state = WL + HW + 1.
//      Conflict (NON_READER_BITS != 0). R_B undoes: fetchSub(1).
//   4. R_B's prev_undo = WL + HW + 1, READER_MASK == 1, HAS_WAITERS set.
//      The wake-on-undo branch fires.
//   5. wakeNext peeks queue, sees R_A (Read kind) at head. The .Read
//      branch does fetchAdd(1) UNCONDITIONALLY ("WRITE_LOCKED is clear
//      here -- callers know") -- but in the wake-on-undo path WRITE_LOCKED
//      is NOT clear; W1 still holds. wakeNext grants R_A's reader slot
//      and submitResume(R_A).
//   6. R_A wakes thinking it has the read lock -- but W1 still mutates.
//      Two threads access the protected data simultaneously.
//
// This is the stackful analog of the FSM lost-wakeup race fixed in
// fb0576b9. The FSM path was MISSING wake-on-undo entirely; the
// stackful path HAS the wake-on-undo (line 956), but its check is
// missing the WRITE_LOCKED == 0 guard.
//
// Why it requires fibers + multi-scheduler: lockShared's slow path
// only parks when running on a Scheduler (sched_opt != null). std.Thread
// callers spin instead -- HAS_WAITERS is never set, the bug condition
// never reproduces. To trigger the bug, fibers must be the ones
// contending the lock, and they must run on different OS threads so
// that the writer and the prematurely-woken reader can race in real
// time (single-scheduler cooperative scheduling serializes them).
//
// Detection: the protected data is a Sample{a, b} pair where the
// invariant `b == a * 2` holds while quiescent. Writer mutates the
// pair non-atomically (a then b, with a brief spin between). A
// reader that wakes inside the mutation window sees b != a * 2 and
// increments `torn_reads`. Without the WRITE_LOCKED guard the test
// fails; with the guard it passes deterministically.

const std = @import("std");
const testing = std.testing;

const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const qs = @import("queues.zig");
const ebr_mod = @import("../lib/ebr.zig");
const pl = @import("../lib/parking-lot.zig");
const compat = @import("../lib/compat.zig");
const rt_mod = @import("runtime.zig");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = rt_mod.Runtime;
const Scheduler = fp.Scheduler;
const StackPool = fm.StackPool;
const build_options = @import("build_options");

const SKIP_BY_DEFAULT = false;

const test_alloc = std.heap.c_allocator;
var global_ebr: ebr_mod.EbrContext = .{};
var stack_pool: StackPool = undefined;
var global_shutdown = std.atomic.Value(bool).init(false);

fn schedulerThread(a: std.mem.Allocator) void {
    var sched = Scheduler.init(a, &global_ebr, &stack_pool) catch return;
    defer sched.deinit();
    sched.global_shutdown = &global_shutdown;
    sched.shutdown_on_idle = false;
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;
    sched.run();
    fp.scheduler_running = false;
}

fn startWorkers(threads: []std.Thread, n: usize) void {
    for (threads[0..n]) |*t| {
        t.* = std.Thread.spawn(.{}, schedulerThread, .{test_alloc}) catch continue;
    }
    while (fp.global_registry.count() < n) {
        compat.sleepNs(1 * std.time.ns_per_ms);
    }
}

fn stopWorkers(threads: []std.Thread, n: usize) void {
    global_shutdown.store(true, .release);
    fp.global_registry.notifyAll();
    for (threads[0..n]) |*t| t.join();
    global_shutdown.store(false, .release);
}

fn withMainRuntimeN(comptime workers: usize, comptime body: fn (*Runtime) anyerror!void) !void {
    var threads: [workers]std.Thread = undefined;
    startWorkers(&threads, workers);
    defer stopWorkers(&threads, workers);

    var sched = try Scheduler.init(test_alloc, &global_ebr, &stack_pool);
    defer {
        sched.deinit();
        fp.active_scheduler = undefined;
        fp.scheduler_running = false;
    }
    sched.global_shutdown = &global_shutdown;
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;

    var rt = try Runtime.init(test_alloc, 4 * 1024 * 1024, &global_ebr);
    defer rt.deinit();
    rt.wireAllocator();

    const Runner = struct {
        rt: *Runtime,
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try body(self.rt);
        }
    };

    var runner = Runner{ .rt = &rt };
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&Runner.run)),
        &runner,
        .{ .stack_size = .Large, .pinned = true },
    );
    sched.run();
}

// ---------------- Stackful Writer / Reader fibers --------------------

// Sample fields are atomic so TSan does not flag the writer's plain
// reads/writes as data races vs the reader's loads. The parking-lot
// rwlock provides the actual mutual exclusion, but TSan does not
// model parking-lot as a synchronization primitive — without atomics
// here every (writer-write, reader-read) pair on a/b looks like an
// unsynchronized race in TSan's view, even though the rwlock semantics
// make it safe. Using `.monotonic` ordering preserves the test's
// torn-read detection (writer still has a window between the a-store
// and the b-store; reader still has a window between the a-load and
// the b-load) without burning the protected-data accesses through
// extra acquire/release pairs.
const Sample = struct {
    a: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    b: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

const Shared = struct {
    rw: pl.ParkingRwLock = .{},
    sample: Sample = .{},
    torn_reads: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    done_writers: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
};

const WriterCtx = struct {
    inner: *CheatLib.Promise(usize).Inner,
    bg_alloc: std.mem.Allocator,
    shared: *Shared,
    iters: usize,

    fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
        const ctx: *@This() = @ptrCast(@alignCast(raw.?));
        defer ctx.bg_alloc.destroy(ctx);
        defer ctx.inner.wg.done();

        var i: u64 = 1;
        var op: usize = 0;
        while (op < ctx.iters) : (op += 1) {
            ctx.shared.rw.lock() catch continue;
            // Mutate with a deliberate window between the two stores.
            // If a reader is granted while we hold (the bug under
            // test), it can read (a=i, b=stale_or_partial). The .a/.b
            // stores are atomic only so TSan does not flag them as
            // unsynchronized data races against the reader's loads
            // (TSan does not model the parking-lot rwlock); the
            // intentional torn-read window between the two stores is
            // preserved.
            ctx.shared.sample.a.store(i, .monotonic);
            var k: usize = 0;
            while (k < 32) : (k += 1) std.atomic.spinLoopHint();
            ctx.shared.sample.b.store(i * 2, .monotonic);
            ctx.shared.rw.unlock();
            i += 1;
        }
        _ = ctx.shared.done_writers.fetchAdd(1, .release);
        ctx.inner.result = op;
    }
};

const ReaderCtx = struct {
    inner: *CheatLib.Promise(usize).Inner,
    bg_alloc: std.mem.Allocator,
    shared: *Shared,
    iters: usize,

    fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
        const ctx: *@This() = @ptrCast(@alignCast(raw.?));
        defer ctx.bg_alloc.destroy(ctx);
        defer ctx.inner.wg.done();

        var op: usize = 0;
        while (op < ctx.iters) : (op += 1) {
            ctx.shared.rw.lockShared() catch continue;
            const aa = ctx.shared.sample.a.load(.monotonic);
            var k: usize = 0;
            while (k < 32) : (k += 1) std.atomic.spinLoopHint();
            const bb = ctx.shared.sample.b.load(.monotonic);
            if (aa != 0 and bb != aa * 2) {
                _ = ctx.shared.torn_reads.fetchAdd(1, .monotonic);
            }
            ctx.shared.rw.unlockShared();
        }
        ctx.inner.result = op;
    }
};

// Stackful fiber ParkingRwLock hammer: 4 writers + 8 readers spawned
// across 4 worker schedulers + main = 5 schedulers via spawnBest. Each
// writer mutates Sample{a, b} non-atomically; each reader checks the
// invariant b == a * 2.
//
// Without the WRITE_LOCKED guard on lockShared's wake-on-undo (line
// 956 of parking-lot.zig), this fails by reporting torn_reads > 0 --
// the bug grants a queued reader's read slot while a writer still
// holds, and the multi-thread layout means the reader's read can land
// inside the writer's a-then-b mutation window.
//
// With the guard, wake-on-undo skips the wake when WRITE_LOCKED is
// set (the writer's eventual unlock will fire the wake), and the test
// passes deterministically.
test "ParkingRwLock fiber hammer: 4 writers + 8 readers, torn-read invariant under wake-on-undo" {
    if (SKIP_BY_DEFAULT) return error.SkipZigTest;

    stack_pool = StackPool.init(test_alloc);
    defer stack_pool.deinit();

    const workers = if (build_options.coverage) 1 else 4;
    try withMainRuntimeN(workers, struct {
        fn body(rt: *Runtime) !void {
            const NW = if (build_options.coverage) 1 else 4;
            const NR = if (build_options.coverage) 1 else 8;
            const ITERS: usize = if (build_options.coverage) 1 else 500;

            var shared = Shared{};
            const sa = rt.getSched().allocator;

            var wprom: [NW]CheatLib.Promise(usize) = undefined;
            var rprom: [NR]CheatLib.Promise(usize) = undefined;

            for (0..NW) |i| {
                wprom[i] = try CheatLib.Promise(usize).spawn(sa, rt.getSched());
                const ctx = try sa.create(WriterCtx);
                ctx.* = .{
                    .inner = wprom[i].inner,
                    .bg_alloc = sa,
                    .shared = &shared,
                    .iters = ITERS,
                };
                try CheatHeader.spawnBest(
                    @intFromPtr(&Runtime.entryWrapper),
                    @as(CheatHeader.TaskFn, @ptrCast(&WriterCtx.run)),
                    ctx,
                    .{ .stack_size = .Large },
                );
            }
            for (0..NR) |i| {
                rprom[i] = try CheatLib.Promise(usize).spawn(sa, rt.getSched());
                const ctx = try sa.create(ReaderCtx);
                ctx.* = .{
                    .inner = rprom[i].inner,
                    .bg_alloc = sa,
                    .shared = &shared,
                    .iters = ITERS,
                };
                try CheatHeader.spawnBest(
                    @intFromPtr(&Runtime.entryWrapper),
                    @as(CheatHeader.TaskFn, @ptrCast(&ReaderCtx.run)),
                    ctx,
                    .{ .stack_size = .Large },
                );
            }

            for (&wprom) |*p| _ = try p.next();
            for (&rprom) |*p| _ = try p.next();

            try testing.expectEqual(@as(usize, 0), shared.torn_reads.load(.monotonic));
            try testing.expect(!shared.rw.isWriteLocked());
            try testing.expectEqual(@as(i32, 0), shared.rw.readerCount());
        }
    }.body);
}
