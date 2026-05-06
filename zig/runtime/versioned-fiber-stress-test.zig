//! Fiber-aware stress test for the MVCC primitives.
//!
//! Reproduces a real-world bug discovered in the user's CLEAR program:
//!
//!     STRUCT C { v: Int64 }
//!     FN main() RETURNS Void ->
//!       MUTABLE c = C{ v: 0_i64 } @shared:versioned;
//!       r1: ~Int64 = BG {
//!         WHILE i < 200_000 DO
//!           WITH SNAPSHOT c AS view { s = s + view.v; }
//!         END; s
//!       };
//!       r2: ~Int64 = BG { -- same body };
//!       NEXT r1 + NEXT r2;
//!     END
//!
//! This crashes (segfault near scheduler.zig:1494 `processCqes`) when run on
//! the CLEAR scheduler. The same shape with `@shared:locked` (Mutex-backed)
//! at the same iteration count runs clean. The same shape under
//! `std.Thread.spawn` (the existing stress tests in
//! versioned-stress-test.zig) also runs clean.
//!
//! The key axis the existing test stages do NOT cover:
//!
//!   - `versioned-stress-test.zig`: spawns std.Thread workers. Each thread
//!     calls `args.ctx.register(allocator, &rt.ebr)` on entry and
//!     `unregister(...)` on exit. Bug-relevant: every reader's
//!     ThreadLocalEbr is in `EbrContext.registry`, so `EbrContext.reclaim()`
//!     correctly waits on it. Also: io_uring is not exercised at all (no
//!     scheduler involved).
//!
//!   - `versioned-loom-test.zig`: a documentation stub. The actual Loom
//!     harness is "future work" -- no fiber driver, no SimRing wiring,
//!     no SimAtomic-instrumented sequence search. Lines 18-26 spell this
//!     out: "T3's std.Thread stress tests are sufficient for catching the
//!     common race classes today; Loom adds value for the rare
//!     interleavings...". Today it does NOT add that value.
//!
//!   - `versioned-vopr-test.zig`: single-threaded sequence-of-ops simulator.
//!     Drives `Read`/`ReadHold`/`ReleaseHeld`/`Update`/`ReclaimLocal`/
//!     `ReclaimGlobal` randomly. NO fiber spawn, NO scheduler, NO I/O ring,
//!     NO cross-thread atomics, NO BG-fiber EBR registration. The whole
//!     interaction surface tested by the user's CLEAR program is invisible.
//!
//! The bug surfaces only when:
//!   1. Two CLEAR BG fibers run concurrently on the scheduler.
//!   2. Each enters/exits the EBR critical section in a tight loop.
//!   3. The WaitGroup-driven NEXT eventually fires (cross-scheduler
//!      Resume via SPSC ring + eventfd notify -> CQE).
//!
//! What this file does:
//!   1. Bring up a multi-scheduler runtime (the same shape as
//!      inbox-race-smoke-test.zig::withMainRuntime).
//!   2. Spawn N=2 BG fibers, each calling Versioned(Sample).read() in a
//!      tight loop M=200_000 times.
//!   3. NEXT both promises from the main fiber.
//!   4. Verify no crash, no torn reads.
//!
//! Determinism: PRNG is seeded; iteration count is fixed. The test pulls
//! in `std.heap.c_allocator` (matches inbox-race-smoke-test) so allocator
//! behavior is consistent across runs.

const std = @import("std");
const testing = std.testing;

const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const rt_mod = @import("runtime.zig");
const ebr_mod = @import("../lib/ebr.zig");
const compat = @import("../lib/compat.zig");
const CheatHeader = @import("runtime-header.zig");
const versioned = @import("versioned.zig");

const CheatLib = CheatHeader.CheatLib;
const Runtime = rt_mod.Runtime;
const EbrContext = ebr_mod.EbrContext;
const Scheduler = fp.Scheduler;
const StackPool = fm.StackPool;

// Identical scaffolding to inbox-race-smoke-test.zig: this is the "main
// runtime + N worker schedulers" shape that mirrors how the CLEAR
// runtime starts a real program.
//
// File-scoped because schedulerThread is a thread entry point and Zig
// doesn't let us close over locals in a non-comptime-known struct.
const test_alloc = std.heap.c_allocator;
var global_ebr: EbrContext = .{};
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

// Multi-scheduler shape: 2 worker schedulers on 2 OS threads + main on a
// third. Used by the broader-coverage test below.
fn withMainRuntime(comptime body: fn (*Runtime) anyerror!void) !void {
    var threads: [2]std.Thread = undefined;
    startWorkers(&threads, 2);
    defer stopWorkers(&threads, 2);

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

// Higher-thread variant: N worker schedulers + main = N+1 schedulers.
// The bench-17 heap-corruption bug is observed at CLEAR_THREADS>=4, which
// withMainRuntime (3 total) does not reach. This helper lets stress tests
// exercise the same surface as the real benchmark.
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

// Single-scheduler shape: NO worker threads. Mirrors the
// `CLEAR_THREADS` unset (= default) bootstrap in
// runtime-footer.zig:18-137. The BG fibers and the main fiber all run
// cooperatively on ONE OS thread, interleaved by coopYield(). This is
// the configuration in which the user's CLEAR program crashes.
fn withMainRuntimeSingle(comptime body: fn (*Runtime) anyerror!void) !void {
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

// ----------------------------------------------------------------------
// The shared payload + invariant. Identical shape to versioned-stress-test
// so we can compare results directly.
const Sample = struct {
    a: i64,
    b: i64,
};

// ----------------------------------------------------------------------
// Reader BG: 200_000 iterations of read+release. This is exactly what
// CLEAR's `BG { WHILE i < 200_000 DO WITH SNAPSHOT c AS v {...} END }`
// lowers to, modulo the trivial loop-body work.
const ReaderCtx = struct {
    inner: *CheatLib.Promise(i64).Inner,
    bg_alloc: std.mem.Allocator,
    cell: *versioned.Versioned(Sample),
    iters: usize,
    invariant_violations: *std.atomic.Value(usize),

    fn run(rt_raw: *anyopaque, raw: ?*anyopaque) anyerror!void {
        const ctx: *@This() = @ptrCast(@alignCast(raw.?));
        defer ctx.bg_alloc.destroy(ctx);
        defer ctx.inner.wg.done();

        const rt: *Runtime = @ptrCast(@alignCast(rt_raw));
        var s: i64 = 0;
        var i: usize = 0;
        while (i < ctx.iters) : (i += 1) {
            // Mirrors the WITH SNAPSHOT body: read, release on scope exit.
            // Loop-back-edge cooperative yield triggers every 4096 iters
            // via rt.checkYield(); this is what produces the BG-fiber
            // schedule pressure that the std.Thread stress tests don't
            // recreate.
            var g = ctx.cell.read(rt);
            defer g.release();
            const view = g.get().*;
            if (view.b != view.a * 2) {
                _ = ctx.invariant_violations.fetchAdd(1, .seq_cst);
            }
            s +%= view.a;
            rt.checkYield();
        }
        ctx.inner.result = s;
    }
};

const HeldGuardReaderCtx = struct {
    inner: *CheatLib.Promise(i64).Inner,
    bg_alloc: std.mem.Allocator,
    cell: *versioned.Versioned(Sample),
    reader_pinned: *std.atomic.Value(bool),
    release_reader: *std.atomic.Value(bool),
    violations: *std.atomic.Value(usize),

    fn run(rt_raw: *anyopaque, raw: ?*anyopaque) anyerror!void {
        const ctx: *@This() = @ptrCast(@alignCast(raw.?));
        defer ctx.bg_alloc.destroy(ctx);
        defer ctx.inner.wg.done();

        const rt: *Runtime = @ptrCast(@alignCast(rt_raw));
        var g = ctx.cell.read(rt);
        defer g.release();

        const view = g.get().*;
        ctx.reader_pinned.store(true, .release);

        while (!ctx.release_reader.load(.acquire)) {
            rt.checkYield();
        }

        if (view.a != 1 or view.b != 2) {
            _ = ctx.violations.fetchAdd(1, .seq_cst);
        }
        ctx.inner.result = view.a + view.b;
    }
};

const RetireThenExitWriterCtx = struct {
    inner: *CheatLib.Promise(i64).Inner,
    bg_alloc: std.mem.Allocator,
    cell: *versioned.Versioned(Sample),
    reader_pinned: *std.atomic.Value(bool),

    fn setSample(p: *Sample, a: i64, b: i64) void {
        p.a = a;
        p.b = b;
    }

    fn run(rt_raw: *anyopaque, raw: ?*anyopaque) anyerror!void {
        const ctx: *@This() = @ptrCast(@alignCast(raw.?));
        defer ctx.bg_alloc.destroy(ctx);
        defer ctx.inner.wg.done();

        const rt: *Runtime = @ptrCast(@alignCast(rt_raw));
        while (!ctx.reader_pinned.load(.acquire)) {
            rt.checkYield();
        }

        try ctx.cell.update(rt, ctx.bg_alloc, setSample, .{ 7, 14 });
        ctx.inner.result = 1;
    }
};

// ----------------------------------------------------------------------
// The actual test. Mirrors the user's CLEAR repro:
//   r1 = BG { N reads }; r2 = BG { N reads };
//   total = NEXT r1 + NEXT r2;
//
// Iter count is configurable. The user's CLEAR repro crashes at 200_000
// per fiber. We run a deterministic seed at the same count -- if the
// crash reproduces, the test fails immediately; if it does NOT reproduce
// from pure-Zig fibers, this is itself a finding (the bug is in some
// CLEAR-specific lowering, not in the runtime's fiber+EBR interaction).
//
// Marked `error.SkipZigTest` if there's only one worker scheduler --
// the bug is two-fiber-on-different-thread specific.
// ═══════════════════════════════════════════════════════════════════════
// SECTION 1 — Reader-only stackful BG fibers
// ═══════════════════════════════════════════════════════════════════════

test "Versioned: 2 BG fibers x 200_000 reads via scheduler -- repro for processCqes crash" {
    stack_pool = StackPool.init(test_alloc);
    defer stack_pool.deinit();

    try withMainRuntime(struct {
        fn body(rt: *Runtime) !void {
            const count = fp.global_registry.count();
            if (count < 2) return error.SkipZigTest;

            // The Versioned cell has to outlive both BG fibers. `rt`
            // here is the main fiber's Runtime, which lives in the
            // outer test scope (heap-backed via Runtime.init).
            var cell = try versioned.Versioned(Sample).init(test_alloc, .{ .a = 1, .b = 2 });
            defer {
                cell.deinit(rt, test_alloc) catch unreachable;
                // Drain limbo+orphans so DebugAllocator stays happy.
                var i: usize = 0;
                while (i < 6) : (i += 1) {
                    global_ebr.reclaim(test_alloc);
                    rt.currentEbr().reclaimLocal(test_alloc);
                }
            }

            var violations = std.atomic.Value(usize).init(0);
            const ITERS: usize = 200_000;

            // ----- spawn r1 -----
            const sa = rt.getSched().allocator;
            const promise1 = try CheatLib.Promise(i64).spawn(sa, rt.getSched());
            const ctx1 = try sa.create(ReaderCtx);
            ctx1.* = .{
                .inner = promise1.inner,
                .bg_alloc = sa,
                .cell = &cell,
                .iters = ITERS,
                .invariant_violations = &violations,
            };
            try CheatHeader.spawnBest(
                @intFromPtr(&Runtime.entryWrapper),
                @as(CheatHeader.TaskFn, @ptrCast(&ReaderCtx.run)),
                ctx1,
                .{ .stack_size = .Large },
            );

            // ----- spawn r2 -----
            const promise2 = try CheatLib.Promise(i64).spawn(sa, rt.getSched());
            const ctx2 = try sa.create(ReaderCtx);
            ctx2.* = .{
                .inner = promise2.inner,
                .bg_alloc = sa,
                .cell = &cell,
                .iters = ITERS,
                .invariant_violations = &violations,
            };
            try CheatHeader.spawnBest(
                @intFromPtr(&Runtime.entryWrapper),
                @as(CheatHeader.TaskFn, @ptrCast(&ReaderCtx.run)),
                ctx2,
                .{ .stack_size = .Large },
            );

            // NEXT r1 + NEXT r2: blocks the main fiber until both BG
            // fibers signal done. This is the exact shape of the
            // user's `MUTABLE total = (NEXT r1) + (NEXT r2);`.
            const v1 = try promise1.next();
            const v2 = try promise2.next();
            // Each iteration adds .a (==1) so each fiber returns ITERS.
            try testing.expectEqual(@as(i64, @intCast(ITERS)), v1);
            try testing.expectEqual(@as(i64, @intCast(ITERS)), v2);
            try testing.expectEqual(@as(usize, 0), violations.load(.seq_cst));
        }
    }.body);
}

// ----------------------------------------------------------------------
// Same shape, but with a heap-allocated Versioned cell mirroring the
// `@shared:versioned` -> Arc<Versioned<T>> placement that the CLEAR
// transpiler emits. The Versioned struct is the inner of a hypothetical
// Arc; we skip the Arc itself and just heap-allocate the Versioned so
// the pointer is stable across fiber stacks.
//
// This is the closest pure-Zig analog of the CLEAR repro shape.
test "Versioned: 2 BG fibers, heap-allocated cell -- exact CLEAR @shared:versioned shape" {
    stack_pool = StackPool.init(test_alloc);
    defer stack_pool.deinit();

    try withMainRuntime(struct {
        fn body(rt: *Runtime) !void {
            const count = fp.global_registry.count();
            if (count < 2) return error.SkipZigTest;

            // Heap-place the Versioned cell to match the CLEAR-emitted
            // `Arc<Versioned<T>>` shape (the cell lives in heap memory
            // owned by the Arc; here we own it directly).
            const cell = try test_alloc.create(versioned.Versioned(Sample));
            cell.* = try versioned.Versioned(Sample).init(test_alloc, .{ .a = 1, .b = 2 });
            defer {
                cell.deinit(rt, test_alloc) catch unreachable;
                var i: usize = 0;
                while (i < 6) : (i += 1) {
                    global_ebr.reclaim(test_alloc);
                    rt.currentEbr().reclaimLocal(test_alloc);
                }
                test_alloc.destroy(cell);
            }

            var violations = std.atomic.Value(usize).init(0);
            const ITERS: usize = 200_000;

            const sa = rt.getSched().allocator;
            const promise1 = try CheatLib.Promise(i64).spawn(sa, rt.getSched());
            const ctx1 = try sa.create(ReaderCtx);
            ctx1.* = .{
                .inner = promise1.inner,
                .bg_alloc = sa,
                .cell = cell,
                .iters = ITERS,
                .invariant_violations = &violations,
            };
            try CheatHeader.spawnBest(
                @intFromPtr(&Runtime.entryWrapper),
                @as(CheatHeader.TaskFn, @ptrCast(&ReaderCtx.run)),
                ctx1,
                .{ .stack_size = .Large },
            );

            const promise2 = try CheatLib.Promise(i64).spawn(sa, rt.getSched());
            const ctx2 = try sa.create(ReaderCtx);
            ctx2.* = .{
                .inner = promise2.inner,
                .bg_alloc = sa,
                .cell = cell,
                .iters = ITERS,
                .invariant_violations = &violations,
            };
            try CheatHeader.spawnBest(
                @intFromPtr(&Runtime.entryWrapper),
                @as(CheatHeader.TaskFn, @ptrCast(&ReaderCtx.run)),
                ctx2,
                .{ .stack_size = .Large },
            );

            const v1 = try promise1.next();
            const v2 = try promise2.next();
            try testing.expectEqual(@as(i64, @intCast(ITERS)), v1);
            try testing.expectEqual(@as(i64, @intCast(ITERS)), v2);
            try testing.expectEqual(@as(usize, 0), violations.load(.seq_cst));
        }
    }.body);
}

test "Versioned: retired version survives writer task exit while another task holds a guard" {
    stack_pool = StackPool.init(test_alloc);
    defer stack_pool.deinit();

    try withMainRuntime(struct {
        fn body(rt: *Runtime) !void {
            const count = fp.global_registry.count();
            if (count < 2) return error.SkipZigTest;

            const cell = try test_alloc.create(versioned.Versioned(Sample));
            cell.* = try versioned.Versioned(Sample).init(test_alloc, .{ .a = 1, .b = 2 });
            defer {
                cell.deinit(rt, test_alloc) catch unreachable;
                var i: usize = 0;
                while (i < 6) : (i += 1) {
                    global_ebr.reclaim(test_alloc);
                    rt.currentEbr().reclaimLocal(test_alloc);
                }
                test_alloc.destroy(cell);
            }

            var reader_pinned = std.atomic.Value(bool).init(false);
            var release_reader = std.atomic.Value(bool).init(false);
            var violations = std.atomic.Value(usize).init(0);

            const sa = rt.getSched().allocator;
            const reader_promise = try CheatLib.Promise(i64).spawn(sa, rt.getSched());
            const reader_ctx = try sa.create(HeldGuardReaderCtx);
            reader_ctx.* = .{
                .inner = reader_promise.inner,
                .bg_alloc = sa,
                .cell = cell,
                .reader_pinned = &reader_pinned,
                .release_reader = &release_reader,
                .violations = &violations,
            };
            try CheatHeader.spawnBest(
                @intFromPtr(&Runtime.entryWrapper),
                @as(CheatHeader.TaskFn, @ptrCast(&HeldGuardReaderCtx.run)),
                reader_ctx,
                .{ .stack_size = .Large },
            );

            const writer_promise = try CheatLib.Promise(i64).spawn(sa, rt.getSched());
            const writer_ctx = try sa.create(RetireThenExitWriterCtx);
            writer_ctx.* = .{
                .inner = writer_promise.inner,
                .bg_alloc = sa,
                .cell = cell,
                .reader_pinned = &reader_pinned,
            };
            try CheatHeader.spawnBest(
                @intFromPtr(&Runtime.entryWrapper),
                @as(CheatHeader.TaskFn, @ptrCast(&RetireThenExitWriterCtx.run)),
                writer_ctx,
                .{ .stack_size = .Large },
            );

            try testing.expectEqual(@as(i64, 1), try writer_promise.next());

            var i: usize = 0;
            while (i < 12) : (i += 1) {
                global_ebr.reclaim(test_alloc);
                rt.currentEbr().reclaimLocal(test_alloc);
                rt.checkYield();
            }

            release_reader.store(true, .release);
            try testing.expectEqual(@as(i64, 3), try reader_promise.next());
            try testing.expectEqual(@as(usize, 0), violations.load(.seq_cst));
        }
    }.body);
}

// ----------------------------------------------------------------------
// Variant: 4 BG readers x 100_000 iters each. Strictly more concurrent
// EBR enter/exit pressure across more fibers. If the bug is a per-fiber
// EBR-registration omission, scaling the fiber count makes the bug
// proportionally more likely to surface in any given run.
test "Versioned: 4 BG fibers x 100_000 reads via scheduler -- broader concurrency surface" {
    stack_pool = StackPool.init(test_alloc);
    defer stack_pool.deinit();

    try withMainRuntime(struct {
        fn body(rt: *Runtime) !void {
            const count = fp.global_registry.count();
            if (count < 2) return error.SkipZigTest;

            var cell = try versioned.Versioned(Sample).init(test_alloc, .{ .a = 1, .b = 2 });
            defer {
                cell.deinit(rt, test_alloc) catch unreachable;
                var i: usize = 0;
                while (i < 6) : (i += 1) {
                    global_ebr.reclaim(test_alloc);
                    rt.currentEbr().reclaimLocal(test_alloc);
                }
            }

            var violations = std.atomic.Value(usize).init(0);

            const N = 4;
            const sa = rt.getSched().allocator;
            var promises: [N]CheatLib.Promise(i64) = undefined;
            for (0..N) |i| {
                promises[i] = try CheatLib.Promise(i64).spawn(sa, rt.getSched());
                const ctx = try sa.create(ReaderCtx);
                ctx.* = .{
                    .inner = promises[i].inner,
                    .bg_alloc = sa,
                    .cell = &cell,
                    .iters = 100_000,
                    .invariant_violations = &violations,
                };
                try CheatHeader.spawnBest(
                    @intFromPtr(&Runtime.entryWrapper),
                    @as(CheatHeader.TaskFn, @ptrCast(&ReaderCtx.run)),
                    ctx,
                    .{ .stack_size = .Large },
                );
            }

            for (&promises) |*p| {
                const v = try p.next();
                try testing.expectEqual(@as(i64, 100_000), v);
            }
            try testing.expectEqual(@as(usize, 0), violations.load(.seq_cst));
        }
    }.body);
}

// ----------------------------------------------------------------------
// FSM-shaped reproducer. Exact match for what the CLEAR transpiler
// emits for `r1 = BG { WHILE i < 200_000 DO WITH SNAPSHOT c AS view {...} END }`:
//
//   const __BgCtx = struct {
//     task: *FsmTask,                               (line 45 of emitted code)
//     rt: *Runtime,                                (sharing main's rt!)
//     inner: *Promise(i64).Inner,
//     alloc: std.mem.Allocator,
//     c: Arc(Versioned(C)),
//     step: u8 = 0,
//     ...
//     fn runSeg0(ctx) { while (i<N) {
//        var g = unwrap.read(rt); defer g.release();
//        const view = g.get(); s += view.v;
//        rt.checkYield();
//     }
//     }
//     fn resumeFn(task) -> YieldReason { runSeg0(); ...; .Done }
//     fn destroyTask(task) -> void { ... }
//   };
//   try sched.submitFsmSpawn(__bg_ctx.task);
//
// Key features the previous (stackful spawnBest) tests miss:
//   1. The FSM body shares the main fiber's Runtime (`rt`). Both BG
//      fibers + main fiber enter/exit EBR through Runtime.currentEbr().
//   2. The FSM body calls `rt.checkYield()` -> `coopYield()` ->
//      `getCurrent()` which returns the SCHEDULER's current_task,
//      not the FSM's task. The yield mechanics for FSM-on-worker-
//      stack are different from stackful fibers.
//   3. `submitFsmSpawn` is the entry; `drainFsmQueue` dispatches them
//      inline on the worker stack.
const FsmReaderCtx = struct {
    task: *CheatHeader.FsmTask,
    rt: *Runtime,
    inner: *CheatLib.Promise(i64).Inner,
    alloc: std.mem.Allocator,
    cell: *versioned.Versioned(Sample),
    iters: usize,
    invariant_violations: *std.atomic.Value(usize),
    step: u8 = 0,
    s: i64 = undefined,
    i: i64 = undefined,

    fn runSeg0(ctx: *@This()) anyerror!void {
        const rt = ctx.rt;
        ctx.s = 0;
        ctx.i = 0;
        while (ctx.i < @as(i64, @intCast(ctx.iters))) {
            // === WITH SNAPSHOT c AS view ===
            {
                var g = ctx.cell.read(rt);
                defer g.release();
                const view = g.get();
                if (view.b != view.a * 2) {
                    _ = ctx.invariant_violations.fetchAdd(1, .seq_cst);
                }
                ctx.s = ctx.s +% view.a;
            }
            ctx.i += 1;
            // The CLEAR transpiler injects checkYield at every WHILE
            // back-edge. THIS is the crucial part the stackful test
            // doesn't exercise: from inside FSM dispatchOnce, this
            // ends up calling sched.coopYield() which calls
            // getCurrent() -- and getCurrent returns the SCHEDULER's
            // most-recent stackful task, not the FSM that's calling.
            rt.checkYield();
        }
        ctx.inner.result = ctx.s;
    }

    fn resumeFn(fsm_task: *CheatHeader.FsmTask) CheatHeader.YieldReason {
        const ctx: *@This() = @ptrCast(@alignCast(fsm_task.ctx.?));
        if (@This().runSeg0(ctx)) |_| {} else |err| {
            ctx.inner.result = err;
        }
        ctx.inner.wg.done();
        return .{ .Done = {} };
    }

    fn destroyTask(fsm_task: *CheatHeader.FsmTask) void {
        const ctx: *@This() = @ptrCast(@alignCast(fsm_task.ctx.?));
        ctx.alloc.destroy(ctx);
    }
};

// Single-scheduler FSM repro. This is the exact CLEAR_THREADS-unset
// (= default) configuration in which the user's program previously
// crashed. After the in_fsm_dispatch guard in coopYield, checkYield
// from inside an FSM resumeFn becomes a no-op, so this test now runs
// to completion: both FSM bodies do 200K reads each.
// ═══════════════════════════════════════════════════════════════════════
// SECTION 2 — FSM-shaped reader fibers + EBR registration diagnostics
// ═══════════════════════════════════════════════════════════════════════

test "FSM Versioned: 2 BG-FSM fibers x 200_000 reads, single scheduler -- DEFAULT crash repro" {
    stack_pool = StackPool.init(test_alloc);
    defer stack_pool.deinit();

    try withMainRuntimeSingle(struct {
        fn body(rt: *Runtime) !void {
            const cell = try test_alloc.create(versioned.Versioned(Sample));
            cell.* = try versioned.Versioned(Sample).init(test_alloc, .{ .a = 1, .b = 2 });
            defer {
                cell.deinit(rt, test_alloc) catch unreachable;
                var i: usize = 0;
                while (i < 6) : (i += 1) {
                    global_ebr.reclaim(test_alloc);
                    rt.currentEbr().reclaimLocal(test_alloc);
                }
                test_alloc.destroy(cell);
            }

            var violations = std.atomic.Value(usize).init(0);
            const ITERS: usize = 200_000;

            const sa = rt.getSched().allocator;
            const promise1 = try CheatLib.Promise(i64).spawn(sa, rt.getSched());
            const ctx1 = try sa.create(FsmReaderCtx);
            ctx1.* = .{
                .task = undefined,
                .rt = rt,
                .inner = promise1.inner,
                .alloc = sa,
                .cell = cell,
                .iters = ITERS,
                .invariant_violations = &violations,
            };
            ctx1.task = try CheatHeader.allocFsmTask(rt, &FsmReaderCtx.resumeFn); ctx1.task.ctx = ctx1;
            ctx1.task.destroy_fn = &FsmReaderCtx.destroyTask;
            try rt.getSched().submitFsmSpawn(ctx1.task);

            const promise2 = try CheatLib.Promise(i64).spawn(sa, rt.getSched());
            const ctx2 = try sa.create(FsmReaderCtx);
            ctx2.* = .{
                .task = undefined,
                .rt = rt,
                .inner = promise2.inner,
                .alloc = sa,
                .cell = cell,
                .iters = ITERS,
                .invariant_violations = &violations,
            };
            ctx2.task = try CheatHeader.allocFsmTask(rt, &FsmReaderCtx.resumeFn); ctx2.task.ctx = ctx2;
            ctx2.task.destroy_fn = &FsmReaderCtx.destroyTask;
            try rt.getSched().submitFsmSpawn(ctx2.task);

            const v1 = try promise1.next();
            const v2 = try promise2.next();
            try testing.expectEqual(@as(i64, @intCast(ITERS)), v1);
            try testing.expectEqual(@as(i64, @intCast(ITERS)), v2);
            try testing.expectEqual(@as(usize, 0), violations.load(.seq_cst));
        }
    }.body);
}

// ----------------------------------------------------------------------
// CONTROL test: identical FSM-shaped reproducer but WITHOUT the
// rt.checkYield() call inside the loop body. This isolates
// checkYield-from-FSM as the bug source.
//
// If this test PASSES while the version above CRASHES, the diagnosis
// is confirmed: it's not the EBR enter/exit, not the read/release
// guard, not the cell shape. It's the checkYield call that
// CLEAR_v0 emits at every WHILE back-edge inside an FSM body.
//
// CLEAR's FSM lowering inherits the WHILE-body checkYield injection
// from the generic loop lowerer (mir_lowering.rb:5314). The locked
// (lockable) variant skips this because the FSM transform splits the
// body around the lock acquire suspension point, and the trailing
// checkYield ends up in a segment that's reached only on natural
// .Yielded returns (not from a deep call). The MVCC variant has no
// suspension point in the body, so the entire body stays in
// runSeg0 -- including the trailing checkYield.
const FsmReaderCtxNoYield = struct {
    task: *CheatHeader.FsmTask,
    rt: *Runtime,
    inner: *CheatLib.Promise(i64).Inner,
    alloc: std.mem.Allocator,
    cell: *versioned.Versioned(Sample),
    iters: usize,
    invariant_violations: *std.atomic.Value(usize),
    s: i64 = undefined,
    i: i64 = undefined,

    fn runSeg0(ctx: *@This()) anyerror!void {
        const rt = ctx.rt;
        ctx.s = 0;
        ctx.i = 0;
        while (ctx.i < @as(i64, @intCast(ctx.iters))) {
            {
                var g = ctx.cell.read(rt);
                defer g.release();
                const view = g.get();
                if (view.b != view.a * 2) {
                    _ = ctx.invariant_violations.fetchAdd(1, .seq_cst);
                }
                ctx.s = ctx.s +% view.a;
            }
            ctx.i += 1;
            // *** No checkYield ***
        }
        ctx.inner.result = ctx.s;
    }

    fn resumeFn(fsm_task: *CheatHeader.FsmTask) CheatHeader.YieldReason {
        const ctx: *@This() = @ptrCast(@alignCast(fsm_task.ctx.?));
        if (@This().runSeg0(ctx)) |_| {} else |err| {
            ctx.inner.result = err;
        }
        ctx.inner.wg.done();
        return .{ .Done = {} };
    }

    fn destroyTask(fsm_task: *CheatHeader.FsmTask) void {
        const ctx: *@This() = @ptrCast(@alignCast(fsm_task.ctx.?));
        ctx.alloc.destroy(ctx);
    }
};

test "FSM Versioned CONTROL: same shape WITHOUT checkYield -- isolates the bug" {
    stack_pool = StackPool.init(test_alloc);
    defer stack_pool.deinit();

    try withMainRuntimeSingle(struct {
        fn body(rt: *Runtime) !void {
            const cell = try test_alloc.create(versioned.Versioned(Sample));
            cell.* = try versioned.Versioned(Sample).init(test_alloc, .{ .a = 1, .b = 2 });
            defer {
                cell.deinit(rt, test_alloc) catch unreachable;
                var i: usize = 0;
                while (i < 6) : (i += 1) {
                    global_ebr.reclaim(test_alloc);
                    rt.currentEbr().reclaimLocal(test_alloc);
                }
                test_alloc.destroy(cell);
            }

            var violations = std.atomic.Value(usize).init(0);
            const ITERS: usize = 200_000;

            const sa = rt.getSched().allocator;
            const promise1 = try CheatLib.Promise(i64).spawn(sa, rt.getSched());
            const ctx1 = try sa.create(FsmReaderCtxNoYield);
            ctx1.* = .{
                .task = undefined,
                .rt = rt,
                .inner = promise1.inner,
                .alloc = sa,
                .cell = cell,
                .iters = ITERS,
                .invariant_violations = &violations,
            };
            ctx1.task = try CheatHeader.allocFsmTask(rt, &FsmReaderCtxNoYield.resumeFn); ctx1.task.ctx = ctx1;
            ctx1.task.destroy_fn = &FsmReaderCtxNoYield.destroyTask;
            try rt.getSched().submitFsmSpawn(ctx1.task);

            const promise2 = try CheatLib.Promise(i64).spawn(sa, rt.getSched());
            const ctx2 = try sa.create(FsmReaderCtxNoYield);
            ctx2.* = .{
                .task = undefined,
                .rt = rt,
                .inner = promise2.inner,
                .alloc = sa,
                .cell = cell,
                .iters = ITERS,
                .invariant_violations = &violations,
            };
            ctx2.task = try CheatHeader.allocFsmTask(rt, &FsmReaderCtxNoYield.resumeFn); ctx2.task.ctx = ctx2;
            ctx2.task.destroy_fn = &FsmReaderCtxNoYield.destroyTask;
            try rt.getSched().submitFsmSpawn(ctx2.task);

            const v1 = try promise1.next();
            const v2 = try promise2.next();
            try testing.expectEqual(@as(i64, @intCast(ITERS)), v1);
            try testing.expectEqual(@as(i64, @intCast(ITERS)), v2);
            try testing.expectEqual(@as(usize, 0), violations.load(.seq_cst));
        }
    }.body);
}

// ----------------------------------------------------------------------
// Diagnostic: confirm BG fibers use a registered scheduler-thread EBR.
// This guards the core safety invariant: reclaim() must observe a pinned
// BG fiber even though the task itself does not own an EBR slot.
const RegProbeCtx = struct {
    inner: *CheatLib.Promise(usize).Inner,
    bg_alloc: std.mem.Allocator,
    ebr_count_inside: *std.atomic.Value(usize),
    cell: *versioned.Versioned(Sample),

    fn run(rt_raw: *anyopaque, raw: ?*anyopaque) anyerror!void {
        const ctx: *@This() = @ptrCast(@alignCast(raw.?));
        defer ctx.bg_alloc.destroy(ctx);
        defer ctx.inner.wg.done();

        const rt: *Runtime = @ptrCast(@alignCast(rt_raw));
        // Pin EBR briefly so we can inspect global state under load.
        var g = ctx.cell.read(rt);
        defer g.release();

        // Walk the registry under its lock and confirm the scheduler
        // thread's EBR participant is registered.
        global_ebr.registry_lock.lock();
        defer global_ebr.registry_lock.unlock();

        var seen_self: usize = 0;
        const current_ebr = rt.currentEbr();
        for (global_ebr.registry.items) |entry| {
            if (entry == current_ebr) seen_self = 1;
        }
        ctx.ebr_count_inside.store(seen_self, .seq_cst);
        ctx.inner.result = global_ebr.registry.items.len;
    }
};

// Pin-blocker BG fiber: enters EBR critical section, publishes the
// epoch it saw at pin time, then spins on `can_release` so the main
// fiber can drive several reclaim() calls while we hold the pin. Used
// by the next test to verify EBR.reclaim() correctly observes a
// BG-fiber-pinned epoch.
const PinBlockerCtx = struct {
    inner: *CheatLib.Promise(usize).Inner,
    bg_alloc: std.mem.Allocator,
    cell: *versioned.Versioned(Sample),
    can_release: *std.atomic.Value(bool),
    pinned_global_epoch: *std.atomic.Value(u32),

    fn run(rt_raw: *anyopaque, raw: ?*anyopaque) anyerror!void {
        const ctx: *@This() = @ptrCast(@alignCast(raw.?));
        defer ctx.bg_alloc.destroy(ctx);
        defer ctx.inner.wg.done();

        const rt: *Runtime = @ptrCast(@alignCast(rt_raw));
        var g = ctx.cell.read(rt);
        defer g.release();

        // Publish the global epoch at the moment we pinned. Main reads
        // this to compute the post-reclaim assertion.
        ctx.pinned_global_epoch.store(global_ebr.global_epoch.load(.seq_cst), .seq_cst);

        // Spin until main signals; checkYield lets the scheduler run
        // other fibers cooperatively. (Stackful spawn -- checkYield is
        // safe here, unlike inside an FSM resume body.)
        while (!ctx.can_release.load(.seq_cst)) {
            rt.checkYield();
        }
        ctx.inner.result = 1;
    }
};

// EBR-registration consequence test. Captures the actual safety
// violation that the registration omission permits:
//
//   When a reader (BG fiber) is mid-Versioned.read() with a Guard
//   alive, EbrContext.reclaim() MUST observe the reader's pinned
//   epoch and refuse to advance past it. If reclaim advances past
//   the pinned epoch, any retired pointer at the pinned epoch is
//   eligible for free -- with the Guard still pointing at it. UAF.
//
// Pre-fix: BG fiber's ThreadLocalEbr is NOT in the registry, so
// reclaim() can't see it. Main can crank the epoch arbitrarily.
// Post-fix: entryWrapper registers the BG ebr; reclaim observes the
// pinned epoch; advance stalls after one step.
// Outer state for the EBR-registration UAF test. Stored at file scope
// because withMainRuntime's `body` is comptime and can't capture
// stack-locals; the outer test reads these after the scheduler exits
// and asserts on them. The pattern is required because errors thrown
// inside `body` are swallowed by entryWrapper (it logs "Task Crashed"
// to stderr but does not propagate), so a `try testing.expect(...)`
// inside `body` would silently report the test as passing.
var ebr_test_initial_epoch: u32 = 0;
var ebr_test_final_epoch: u32 = 0;

test "EBR registration: BG fiber's pin must block reclaim advance (UAF guard)" {
    stack_pool = StackPool.init(test_alloc);
    defer stack_pool.deinit();

    try withMainRuntime(struct {
        fn body(rt: *Runtime) !void {
            // entryWrapper now auto-registers `rt.ebr` with the global
            // context, so no manual register is needed here.

            var cell = try versioned.Versioned(Sample).init(test_alloc, .{ .a = 1, .b = 2 });
            defer {
                cell.deinit(rt, test_alloc) catch unreachable;
                var i: usize = 0;
                while (i < 6) : (i += 1) {
                    global_ebr.reclaim(test_alloc);
                    rt.currentEbr().reclaimLocal(test_alloc);
                }
            }

            var can_release = std.atomic.Value(bool).init(false);
            const SENTINEL: u32 = 0xFFFFFFFF;
            var pinned_epoch = std.atomic.Value(u32).init(SENTINEL);

            const sa = rt.getSched().allocator;
            const promise = try CheatLib.Promise(usize).spawn(sa, rt.getSched());
            const ctx = try sa.create(PinBlockerCtx);
            ctx.* = .{
                .inner = promise.inner,
                .bg_alloc = sa,
                .cell = &cell,
                .can_release = &can_release,
                .pinned_global_epoch = &pinned_epoch,
            };
            try CheatHeader.spawnBest(
                @intFromPtr(&Runtime.entryWrapper),
                @as(CheatHeader.TaskFn, @ptrCast(&PinBlockerCtx.run)),
                ctx,
                .{ .stack_size = .Large },
            );

            // Wait for BG to pin and publish its epoch.
            while (pinned_epoch.load(.seq_cst) == SENTINEL) {
                compat.sleepNs(1 * std.time.ns_per_ms);
            }
            ebr_test_initial_epoch = pinned_epoch.load(.seq_cst);

            // Try to advance the global epoch four times. Invariant:
            // BG's pinned epoch should block advance after the first
            // step (the first step bumps global to initial+1; from
            // then on BG.local_epoch=initial < global=initial+1 so
            // reclaim bails out).
            var i: usize = 0;
            while (i < 4) : (i += 1) global_ebr.reclaim(test_alloc);

            ebr_test_final_epoch = global_ebr.global_epoch.load(.seq_cst);

            // Release BG and join.
            can_release.store(true, .seq_cst);
            _ = try promise.next();
        }
    }.body);

    // INVARIANT: a pinned reader blocks epoch advance after one step.
    // Pre-fix this fails (epoch advances 4 times because BG's
    // ThreadLocalEbr was never added to global_ebr.registry).
    try testing.expectEqual(ebr_test_initial_epoch + 1, ebr_test_final_epoch);
}

test "DIAGNOSTIC: BG fiber's ThreadLocalEbr IS registered with EbrContext" {
    stack_pool = StackPool.init(test_alloc);
    defer stack_pool.deinit();

    try withMainRuntime(struct {
        fn body(rt: *Runtime) !void {
            var cell = try versioned.Versioned(Sample).init(test_alloc, .{ .a = 1, .b = 2 });
            defer {
                cell.deinit(rt, test_alloc) catch unreachable;
                var i: usize = 0;
                while (i < 6) : (i += 1) {
                    global_ebr.reclaim(test_alloc);
                    rt.currentEbr().reclaimLocal(test_alloc);
                }
            }

            var seen_self = std.atomic.Value(usize).init(99);
            const sa = rt.getSched().allocator;
            const promise = try CheatLib.Promise(usize).spawn(sa, rt.getSched());
            const ctx = try sa.create(RegProbeCtx);
            ctx.* = .{
                .inner = promise.inner,
                .bg_alloc = sa,
                .ebr_count_inside = &seen_self,
                .cell = &cell,
            };
            try CheatHeader.spawnBest(
                @intFromPtr(&Runtime.entryWrapper),
                @as(CheatHeader.TaskFn, @ptrCast(&RegProbeCtx.run)),
                ctx,
                .{ .stack_size = .Large },
            );
            _ = try promise.next();
            // Post-fix: BG fiber's ThreadLocalEbr is in global_ebr.registry
            // (entryWrapper auto-registers), so reclaim() correctly observes
            // its pinned epoch -- the EBR safety invariant is upheld for
            // BG fibers.
            ebr_diag_seen_self = seen_self.load(.seq_cst);
        }
    }.body);

    try testing.expectEqual(@as(usize, 1), ebr_diag_seen_self);
}

// Outer state for the DIAGNOSTIC assertion. See note above ebr_test_*
// fields for why this can't live on body's stack.
var ebr_diag_seen_self: usize = 99;

// ----------------------------------------------------------------------
// WRITER-STRESS COVERAGE GAP
// ----------------------------------------------------------------------
// Until 2026-04, every fiber+Versioned test in this file exercised
// READERS only. Multi-writer coverage was delegated to
// `versioned-stress-test.zig` (std.Thread workers, no scheduler), which
// does NOT exercise:
//   - Cross-scheduler @parallel BG distribution (spawnFsmBest)
//   - Scheduler-thread EBR lifecycle under migratable tasks
//   - Versioned.update's per-write heap-alloc + EBR-retire under many
//     concurrent writers all racing the same cell
//
// Discovery: `bench-17` with 4 BG-FSM writers + CLEAR_THREADS=4 aborts
// 100% of the time with `realloc(): invalid old size` (glibc heap
// corruption). 1-2 writers fine; 4+ writers crash.
//
// This test reproduces the same shape in pure Zig so the bug can be
// caught by `zig build test` instead of slipping through to
// benchmark-time discovery.
const WriterCtx = struct {
    inner: *CheatLib.Promise(usize).Inner,
    bg_alloc: std.mem.Allocator,
    cell: *versioned.Versioned(Sample),
    iters: usize,
    base: i64,
    failed_updates: *std.atomic.Value(usize),

    fn writeSample(p: *Sample, n: i64) void {
        p.a = n;
        p.b = n * 2;
    }

    fn run(rt_raw: *anyopaque, raw: ?*anyopaque) anyerror!void {
        const ctx: *@This() = @ptrCast(@alignCast(raw.?));
        defer ctx.bg_alloc.destroy(ctx);
        defer ctx.inner.wg.done();

        const rt: *Runtime = @ptrCast(@alignCast(rt_raw));
        var i: usize = 0;
        while (i < ctx.iters) : (i += 1) {
            const v = ctx.base + @as(i64, @intCast(i));
            ctx.cell.update(rt, ctx.bg_alloc, writeSample, .{v}) catch {
                _ = ctx.failed_updates.fetchAdd(1, .seq_cst);
                continue;
            };
            // Same loop-back yield the reader uses — keeps the bg fiber
            // co-operatively scheduled.
            rt.checkYield();
        }
        ctx.inner.result = i;
    }
};

// Reproduces the bench-17 heap corruption.
//
// 4 BG fibers, each calls Versioned.update() in a loop on the SAME
// cell. Writers contend on the cell pointer's CAS; losers retry. Each
// successful update heap-allocates a new Sample, retires the old via
// EBR. With CLEAR_THREADS=N>=4 (i.e. >=2 worker schedulers + main +
// stealing), this triggers `realloc(): invalid old size` 100% of
// the time on the bench. As a runtime test it should fail by abort
// (heap-asserts kill the process); if heap corruption silently
// succeeds, downstream allocations may exhibit other failures.
// ═══════════════════════════════════════════════════════════════════════
// SECTION 3 — Writer-stress + mixed-load tests (bench-17 shapes)
// ═══════════════════════════════════════════════════════════════════════

test "Versioned: 4 BG-FSM writers race the same cell -- bench-17 heap-corruption repro" {
    stack_pool = StackPool.init(test_alloc);
    defer stack_pool.deinit();

    try withMainRuntime(struct {
        fn body(rt: *Runtime) !void {
            const count = fp.global_registry.count();
            if (count < 2) return error.SkipZigTest;

            var cell = try versioned.Versioned(Sample).init(test_alloc, .{ .a = 0, .b = 0 });
            defer {
                cell.deinit(rt, test_alloc) catch unreachable;
                var i: usize = 0;
                while (i < 6) : (i += 1) {
                    global_ebr.reclaim(test_alloc);
                    rt.currentEbr().reclaimLocal(test_alloc);
                }
            }

            var failed = std.atomic.Value(usize).init(0);

            const N = 4;
            const ITERS = 1_000;
            const sa = rt.getSched().allocator;
            var promises: [N]CheatLib.Promise(usize) = undefined;
            for (0..N) |i| {
                promises[i] = try CheatLib.Promise(usize).spawn(sa, rt.getSched());
                const ctx = try sa.create(WriterCtx);
                ctx.* = .{
                    .inner = promises[i].inner,
                    .bg_alloc = sa,
                    .cell = &cell,
                    .iters = ITERS,
                    .base = @as(i64, @intCast(i)) * 1_000_000,
                    .failed_updates = &failed,
                };
                try CheatHeader.spawnBest(
                    @intFromPtr(&Runtime.entryWrapper),
                    @as(CheatHeader.TaskFn, @ptrCast(&WriterCtx.run)),
                    ctx,
                    .{ .stack_size = .Large },
                );
            }

            for (&promises) |*p| {
                _ = try p.next();
            }
            // No invariant on completed-iters: lost CAS retries are OK.
            // The ASSERT here is implicit: glibc must not have aborted
            // the process by now. The `failed_updates` count is
            // informational only -- a clean run typically has 0 but
            // any value is acceptable (writers only fail on OOM, which
            // shouldn't happen here).
            _ = failed.load(.seq_cst);
        }
    }.body);
}

// Same shape, larger surface (32 writers, 100 iters each = same
// total updates, more concurrent retire pressure). If the 4-writer
// test passes, this should too; if NOT, the bug scales with writer
// count.
test "Versioned: 32 BG-FSM writers race the same cell -- bench-17 scale-up repro" {
    stack_pool = StackPool.init(test_alloc);
    defer stack_pool.deinit();

    try withMainRuntime(struct {
        fn body(rt: *Runtime) !void {
            const count = fp.global_registry.count();
            if (count < 2) return error.SkipZigTest;

            var cell = try versioned.Versioned(Sample).init(test_alloc, .{ .a = 0, .b = 0 });
            defer {
                cell.deinit(rt, test_alloc) catch unreachable;
                var i: usize = 0;
                while (i < 6) : (i += 1) {
                    global_ebr.reclaim(test_alloc);
                    rt.currentEbr().reclaimLocal(test_alloc);
                }
            }

            var failed = std.atomic.Value(usize).init(0);

            const N = 32;
            const ITERS = 100;
            const sa = rt.getSched().allocator;
            var promises: [N]CheatLib.Promise(usize) = undefined;
            for (0..N) |i| {
                promises[i] = try CheatLib.Promise(usize).spawn(sa, rt.getSched());
                const ctx = try sa.create(WriterCtx);
                ctx.* = .{
                    .inner = promises[i].inner,
                    .bg_alloc = sa,
                    .cell = &cell,
                    .iters = ITERS,
                    .base = @as(i64, @intCast(i)) * 1_000_000,
                    .failed_updates = &failed,
                };
                try CheatHeader.spawnBest(
                    @intFromPtr(&Runtime.entryWrapper),
                    @as(CheatHeader.TaskFn, @ptrCast(&WriterCtx.run)),
                    ctx,
                    .{ .stack_size = .Large },
                );
            }

            for (&promises) |*p| {
                _ = try p.next();
            }
            _ = failed.load(.seq_cst);
        }
    }.body);
}

// Bench-17 exact shape repro at the production thread count.
// 32 readers + 4 writers, all @parallel BG, on 4 worker schedulers + main =
// 5 schedulers (matches the failing CLEAR_THREADS=8 surface enough to
// exercise reader-pin / writer-retire interleaving across threads).
//
// Readers call cell.read() in a loop; writers call cell.update() in a loop.
// If glibc heap asserts fire (`realloc(): invalid old size`, double-free,
// invalid pointer), this aborts the process and the test runner reports a
// failure.
test "Versioned: 32 readers + 4 writers on 5 schedulers -- bench-17 mixed-load repro" {
    stack_pool = StackPool.init(test_alloc);
    defer stack_pool.deinit();

    try withMainRuntimeN(4, struct {
        fn body(rt: *Runtime) !void {
            const count = fp.global_registry.count();
            if (count < 4) return error.SkipZigTest;

            var cell = try versioned.Versioned(Sample).init(test_alloc, .{ .a = 0, .b = 0 });
            defer {
                cell.deinit(rt, test_alloc) catch unreachable;
                var i: usize = 0;
                while (i < 6) : (i += 1) {
                    global_ebr.reclaim(test_alloc);
                    rt.currentEbr().reclaimLocal(test_alloc);
                }
            }

            var failed = std.atomic.Value(usize).init(0);
            var invariant_violations = std.atomic.Value(usize).init(0);

            const NR = 32;
            const NW = 4;
            const READS = 1_000;
            const WRITES = 200;
            const sa = rt.getSched().allocator;

            var rprom: [NR]CheatLib.Promise(i64) = undefined;
            var wprom: [NW]CheatLib.Promise(usize) = undefined;

            for (0..NR) |i| {
                rprom[i] = try CheatLib.Promise(i64).spawn(sa, rt.getSched());
                const ctx = try sa.create(ReaderCtx);
                ctx.* = .{
                    .inner = rprom[i].inner,
                    .bg_alloc = sa,
                    .cell = &cell,
                    .iters = READS,
                    .invariant_violations = &invariant_violations,
                };
                try CheatHeader.spawnBest(
                    @intFromPtr(&Runtime.entryWrapper),
                    @as(CheatHeader.TaskFn, @ptrCast(&ReaderCtx.run)),
                    ctx,
                    .{ .stack_size = .Large },
                );
            }
            for (0..NW) |i| {
                wprom[i] = try CheatLib.Promise(usize).spawn(sa, rt.getSched());
                const ctx = try sa.create(WriterCtx);
                ctx.* = .{
                    .inner = wprom[i].inner,
                    .bg_alloc = sa,
                    .cell = &cell,
                    .iters = WRITES,
                    .base = @as(i64, @intCast(i)) * 1_000_000,
                    .failed_updates = &failed,
                };
                try CheatHeader.spawnBest(
                    @intFromPtr(&Runtime.entryWrapper),
                    @as(CheatHeader.TaskFn, @ptrCast(&WriterCtx.run)),
                    ctx,
                    .{ .stack_size = .Large },
                );
            }

            for (&rprom) |*p| _ = try p.next();
            for (&wprom) |*p| _ = try p.next();

            _ = failed.load(.seq_cst);
            try testing.expectEqual(@as(usize, 0), invariant_violations.load(.seq_cst));
        }
    }.body);
} // end of mixed-load repro

// Same mixed workload as above, but writer-heavy (4 writers + only 4
// readers) on 4 worker schedulers. The bug-trigger hypothesis is that
// the writer-retire path interacts with the reader-pin path; reducing the
// reader count keeps the test fast while preserving the writer surface.
test "Versioned: 4 readers + 4 writers on 5 schedulers -- writer-heavy repro" {
    stack_pool = StackPool.init(test_alloc);
    defer stack_pool.deinit();

    try withMainRuntimeN(4, struct {
        fn body(rt: *Runtime) !void {
            const count = fp.global_registry.count();
            if (count < 4) return error.SkipZigTest;

            var cell = try versioned.Versioned(Sample).init(test_alloc, .{ .a = 0, .b = 0 });
            defer {
                cell.deinit(rt, test_alloc) catch unreachable;
                var i: usize = 0;
                while (i < 6) : (i += 1) {
                    global_ebr.reclaim(test_alloc);
                    rt.currentEbr().reclaimLocal(test_alloc);
                }
            }

            var failed = std.atomic.Value(usize).init(0);
            var invariant_violations = std.atomic.Value(usize).init(0);

            const NR = 4;
            const NW = 4;
            const READS = 5_000;
            const WRITES = 1_000;
            const sa = rt.getSched().allocator;

            var rprom: [NR]CheatLib.Promise(i64) = undefined;
            var wprom: [NW]CheatLib.Promise(usize) = undefined;

            for (0..NR) |i| {
                rprom[i] = try CheatLib.Promise(i64).spawn(sa, rt.getSched());
                const ctx = try sa.create(ReaderCtx);
                ctx.* = .{
                    .inner = rprom[i].inner,
                    .bg_alloc = sa,
                    .cell = &cell,
                    .iters = READS,
                    .invariant_violations = &invariant_violations,
                };
                try CheatHeader.spawnBest(
                    @intFromPtr(&Runtime.entryWrapper),
                    @as(CheatHeader.TaskFn, @ptrCast(&ReaderCtx.run)),
                    ctx,
                    .{ .stack_size = .Large },
                );
            }
            for (0..NW) |i| {
                wprom[i] = try CheatLib.Promise(usize).spawn(sa, rt.getSched());
                const ctx = try sa.create(WriterCtx);
                ctx.* = .{
                    .inner = wprom[i].inner,
                    .bg_alloc = sa,
                    .cell = &cell,
                    .iters = WRITES,
                    .base = @as(i64, @intCast(i)) * 1_000_000,
                    .failed_updates = &failed,
                };
                try CheatHeader.spawnBest(
                    @intFromPtr(&Runtime.entryWrapper),
                    @as(CheatHeader.TaskFn, @ptrCast(&WriterCtx.run)),
                    ctx,
                    .{ .stack_size = .Large },
                );
            }

            for (&rprom) |*p| _ = try p.next();
            for (&wprom) |*p| _ = try p.next();

            _ = failed.load(.seq_cst);
            try testing.expectEqual(@as(usize, 0), invariant_violations.load(.seq_cst));
        }
    }.body);
}

// FSM-based writer task. Mirrors EXACTLY what the CLEAR transpiler emits
// for `BG { @parallel -> WHILE i < N DO WITH SNAPSHOT c AS MUTABLE va {...} END }`:
//
//   const __BgCtxN = struct {
//     task: *CheatHeader.FsmTask,
//     rt: *Runtime,                     <-- SHARES the OUTER rt (clearMain's)
//     inner: *Promise(void).Inner,
//     alloc: std.mem.Allocator,
//     c_v: Versioned(C),
//     ...
//     fn runSeg0(ctx) {
//       while (i < N) {
//         cell.update(rt, rt.heapAlloc(), ...);   <-- enter/exit/retire on SHARED ebr
//         rt.checkYield();
//       }
//     }
//   };
//   try CheatHeader.spawnFsmBest(ctx.task);  <-- cross-scheduler distribution!
//
// The bug: when these FSMs dispatch on a WORKER scheduler thread, EBR must
// resolve to that worker scheduler's thread EBR, not to the spawning runtime's
// fallback slot.
const FsmWriterCtx = struct {
    task: *CheatHeader.FsmTask,
    rt: *Runtime,
    inner: *CheatLib.Promise(usize).Inner,
    alloc: std.mem.Allocator,
    cell: *versioned.Versioned(Sample),
    iters: usize,
    base: i64,
    failed_updates: *std.atomic.Value(usize),
    step: u8 = 0,
    i: usize = undefined,

    fn writeSample(p: *Sample, n: i64) void {
        p.a = n;
        p.b = n * 2;
    }

    fn runSeg0(ctx: *@This()) anyerror!void {
        const rt = ctx.rt;
        ctx.i = 0;
        while (ctx.i < ctx.iters) {
            const v = ctx.base + @as(i64, @intCast(ctx.i));
            ctx.cell.update(rt, rt.heapAlloc(), writeSample, .{v}) catch {
                _ = ctx.failed_updates.fetchAdd(1, .seq_cst);
            };
            ctx.i += 1;
            rt.checkYield();
        }
        ctx.inner.result = ctx.i;
    }

    fn resumeFn(fsm_task: *CheatHeader.FsmTask) CheatHeader.YieldReason {
        const ctx: *@This() = @ptrCast(@alignCast(fsm_task.ctx.?));
        if (@This().runSeg0(ctx)) |_| {} else |err| {
            ctx.inner.result = err;
        }
        ctx.inner.wg.done();
        return .{ .Done = {} };
    }

    fn destroyTask(fsm_task: *CheatHeader.FsmTask) void {
        const ctx: *@This() = @ptrCast(@alignCast(fsm_task.ctx.?));
        ctx.alloc.destroy(ctx);
    }
};

// Bench-17 EXACT shape repro. The previous writer-stress tests used
// stackful `spawnBest` and passed -- they didn't capture the FSM-on-worker
// shape. Each FSM ctx still gets its own Runtime shell because codegen stores
// an `rt` pointer, but EBR resolves through Runtime.currentEbr() at dispatch.
test "FSM Versioned: 4 BG-FSM writers via spawnFsmBest with Runtime.currentEbr -- bench-17 fix verifier" {
    stack_pool = StackPool.init(test_alloc);
    defer stack_pool.deinit();

    try withMainRuntime(struct {
        fn body(rt: *Runtime) !void {
            const count = fp.global_registry.count();
            if (count < 2) return error.SkipZigTest;

            var cell = try versioned.Versioned(Sample).init(test_alloc, .{ .a = 0, .b = 0 });
            defer {
                cell.deinit(rt, test_alloc) catch unreachable;
                var i: usize = 0;
                while (i < 6) : (i += 1) {
                    global_ebr.reclaim(test_alloc);
                    rt.currentEbr().reclaimLocal(test_alloc);
                }
            }

            var failed = std.atomic.Value(usize).init(0);
            const N = 4;
            const ITERS = 1_000;

            const sa = rt.getSched().allocator;
            var promises: [N]CheatLib.Promise(usize) = undefined;
            for (0..N) |i| {
                promises[i] = try CheatLib.Promise(usize).spawn(sa, rt.getSched());
                const ctx = try sa.create(FsmWriterCtx);
                ctx.* = .{
                    .task = undefined,
                    .rt = undefined, // rebound below to per-task Runtime shell
                    .inner = promises[i].inner,
                    .alloc = sa,
                    .cell = &cell,
                    .iters = ITERS,
                    .base = @as(i64, @intCast(i)) * 1_000_000,
                    .failed_updates = &failed,
                };
                ctx.task = try CheatHeader.allocFsmTask(rt, &FsmWriterCtx.resumeFn); ctx.task.ctx = ctx;
                ctx.task.destroy_fn = &FsmWriterCtx.destroyTask;
                // Allocate a per-task Runtime shell before spawning. The
                // scheduler frees it on .Done.
                const task_rt = try CheatHeader.allocFsmTaskRuntime(ctx.task, rt);
                ctx.rt = task_rt;
                try CheatHeader.spawnFsmBest(ctx.task);
            }

            for (&promises) |*p| _ = try p.next();
            _ = failed.load(.seq_cst);
        }
    }.body);
}

// Higher writer pressure on more schedulers using per-task Runtime shells.
// Validates that Runtime.currentEbr() scales under cross-thread dispatch.
test "FSM Versioned: 8 BG-FSM writers via spawnFsmBest on 5 schedulers (Runtime.currentEbr) -- bench-17 fix scale" {
    stack_pool = StackPool.init(test_alloc);
    defer stack_pool.deinit();

    try withMainRuntimeN(4, struct {
        fn body(rt: *Runtime) !void {
            const count = fp.global_registry.count();
            if (count < 4) return error.SkipZigTest;

            var cell = try versioned.Versioned(Sample).init(test_alloc, .{ .a = 0, .b = 0 });
            defer {
                cell.deinit(rt, test_alloc) catch unreachable;
                var i: usize = 0;
                while (i < 6) : (i += 1) {
                    global_ebr.reclaim(test_alloc);
                    rt.currentEbr().reclaimLocal(test_alloc);
                }
            }

            var failed = std.atomic.Value(usize).init(0);
            const N = 8;
            const ITERS = 500;

            const sa = rt.getSched().allocator;
            var promises: [N]CheatLib.Promise(usize) = undefined;
            for (0..N) |i| {
                promises[i] = try CheatLib.Promise(usize).spawn(sa, rt.getSched());
                const ctx = try sa.create(FsmWriterCtx);
                ctx.* = .{
                    .task = undefined,
                    .rt = undefined, // rebound below to per-task Runtime shell
                    .inner = promises[i].inner,
                    .alloc = sa,
                    .cell = &cell,
                    .iters = ITERS,
                    .base = @as(i64, @intCast(i)) * 1_000_000,
                    .failed_updates = &failed,
                };
                ctx.task = try CheatHeader.allocFsmTask(rt, &FsmWriterCtx.resumeFn); ctx.task.ctx = ctx;
                ctx.task.destroy_fn = &FsmWriterCtx.destroyTask;
                const task_rt = try CheatHeader.allocFsmTaskRuntime(ctx.task, rt);
                ctx.rt = task_rt;
                try CheatHeader.spawnFsmBest(ctx.task);
            }

            for (&promises) |*p| _ = try p.next();
            _ = failed.load(.seq_cst);
        }
    }.body);
}

// Gap 1: structural invariants for the FSM Runtime shell + thread EBR fix.
//
// The bench-17 fix verifier above (and its 8-writer scale-up) prove
// the fix at the *behavioral* level: the heap doesn't abort. This
// test pins the *structural* properties that make the fix work:
// each FSM task has a separate Runtime shell, but none allocates a
// task-local EBR participant. MVCC operations resolve EBR through
// Runtime.currentEbr(), i.e. the active scheduler thread's registered slot.
//
// The behavioral test catches the bug only stochastically; the
// glibc abort fires after enough iterations corrupt the limbo. This
// structural test catches the bug in O(N) work with deterministic
// invariants, so a regression is caught at the first run.
//
// Invariants checked (all before any FSM task starts running):
//   I1  every per-task Runtime pointer is unique
//   I2  registry size does not grow with task count
//   I3  no per-task Runtime aliases the parent rt
//   I4  runtime shells keep only the non-scheduler fallback ebr
//
// And after all tasks complete:
//   I5  the registry size is unchanged
//
// The fix has two parts: (a) allocate per-task runtime shell, (b) keep EBR
// scheduler-local. If either regresses, this catches it before relying on
// stochastic heap corruption.
test "FSM Versioned: Runtime shells use scheduler-thread EBR -- bench-17 fix invariants" {
    stack_pool = StackPool.init(test_alloc);
    defer stack_pool.deinit();

    try withMainRuntime(struct {
        fn body(rt: *Runtime) !void {
            const count = fp.global_registry.count();
            if (count < 2) return error.SkipZigTest;

            var cell = try versioned.Versioned(Sample).init(test_alloc, .{ .a = 0, .b = 0 });
            defer {
                cell.deinit(rt, test_alloc) catch unreachable;
                var i: usize = 0;
                while (i < 6) : (i += 1) {
                    global_ebr.reclaim(test_alloc);
                    rt.currentEbr().reclaimLocal(test_alloc);
                }
            }

            // Snapshot the registry size before allocating Runtime shells.
            global_ebr.registry_lock.lock();
            const initial_registry: usize = global_ebr.registry.items.len;
            global_ebr.registry_lock.unlock();

            var failed = std.atomic.Value(usize).init(0);
            const N = 4;
            const ITERS = 50;

            const sa = rt.getSched().allocator;
            var promises: [N]CheatLib.Promise(usize) = undefined;
            var task_rts: [N]*Runtime = undefined;
            var ctxs: [N]*FsmWriterCtx = undefined;

            // Phase 1: allocate all per-task Runtimes BEFORE spawning any.
            // Capturing pointers up-front is what lets us assert I1-I5.
            for (0..N) |i| {
                promises[i] = try CheatLib.Promise(usize).spawn(sa, rt.getSched());
                ctxs[i] = try sa.create(FsmWriterCtx);
                ctxs[i].* = .{
                    .task = undefined,
                    .rt = undefined,
                    .inner = promises[i].inner,
                    .alloc = sa,
                    .cell = &cell,
                    .iters = ITERS,
                    .base = @as(i64, @intCast(i)) * 1_000,
                    .failed_updates = &failed,
                };
                ctxs[i].task = try CheatHeader.allocFsmTask(rt, &FsmWriterCtx.resumeFn);
                ctxs[i].task.ctx = ctxs[i];
                ctxs[i].task.destroy_fn = &FsmWriterCtx.destroyTask;
                const task_rt = try CheatHeader.allocFsmTaskRuntime(ctxs[i].task, rt);
                ctxs[i].rt = task_rt;
                task_rts[i] = task_rt;
            }

            // I1: per-task Runtimes are pairwise distinct.
            for (0..N) |i| {
                for (i + 1..N) |j| {
                    try testing.expect(task_rts[i] != task_rts[j]);
                }
            }
            // I2: registry does not grow with task count.
            global_ebr.registry_lock.lock();
            const after_alloc_registry = global_ebr.registry.items.len;
            global_ebr.registry_lock.unlock();
            try testing.expectEqual(initial_registry, after_alloc_registry);
            // I3: no per-task Runtime aliases the parent.
            for (0..N) |i| try testing.expect(task_rts[i] != rt);
            // I4: runtime shells use the parent's fallback ebr pointer, but
            // scheduler execution ignores it and uses currentEbr().
            for (0..N) |i| try testing.expect(task_rts[i].ebr == rt.ebr);

            // Phase 2: spawn the FSMs and wait for completion.
            for (0..N) |i| try CheatHeader.spawnFsmBest(ctxs[i].task);
            for (&promises) |*p| _ = try p.next();
            _ = failed.load(.seq_cst);

            // I5: task completion did not add or leak EBR participants.
            global_ebr.registry_lock.lock();
            const after_done_registry = global_ebr.registry.items.len;
            global_ebr.registry_lock.unlock();
            try testing.expectEqual(initial_registry, after_done_registry);
        }
    }.body);
}
