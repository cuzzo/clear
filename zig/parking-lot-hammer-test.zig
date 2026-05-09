// parking-lot-hammer-test.zig — VOPR-style long-running stress for parking-lot.
//
// Time-boxed randomized-schedule hammer. Many fibers contend on a shared
// pool of ParkingMutex + ParkingRwLock, each picking randomized actions
// until the time budget expires. Exercises the code paths the focused
// tests cover in isolation, but with enough volume and interleaving
// diversity to catch bugs the focused tests miss.
//
// Invariants checked:
//   1. Counter correctness — a shared counter guarded by locks must equal
//      the sum of per-fiber increments. Torn updates or dropped writes
//      show up as a mismatch.
//   2. Detection integrity — every ~200 iterations, each fiber tries a
//      re-entrant self-acquire and must get error.Deadlock. If detection
//      silently regresses, this fires.
//   3. Lock state invariants — after the hammer finishes, every lock is
//      unlocked and rwlock reader counts are zero.
//   4. No leaks — std.testing.allocator catches anything orphaned.
//
// Duration: controlled by CLEAR_HAMMER_SECONDS env var. Default 2s (runs
// on every zig build test). Raise to 60-300 for nightly CI runs; the
// randomized coverage grows with the time budget.
//
// Run: zig test parking-lot-hammer-test.zig -lc  (linked via all-tests.zig)

const std = @import("std");
const builtin = @import("builtin");
const pl = @import("lib/parking-lot.zig");
const CheatHeader = @import("runtime/runtime-header.zig");
const Runtime = CheatHeader.Runtime;
const EbrContext = CheatHeader.EbrContext;
const fp = @import("runtime/scheduler.zig");
const fm = @import("runtime/fiber-memory.zig");
const compat = @import("lib/compat.zig");
const build_options = @import("build_options");

const ParkingMutex = pl.ParkingMutex;
const ParkingRwLock = pl.ParkingRwLock;

// How often each fiber probes detection integrity (once every N iterations).
const DETECTION_PROBE_EVERY: u32 = 200;

// Number of fibers spawned by the hammer. High enough to produce real
// contention on the tiny lock pool; low enough that each fiber gets
// meaningful scheduler time in the time budget.
const NUM_FIBERS: usize = if (build_options.coverage) 4 else 16;

// Hammer duration — read from CLEAR_HAMMER_SECONDS or falls back to 2s.
// Debug builds default to 1s because ReleaseFast gets far more iterations
// per second and Debug stretches over several minutes otherwise.
fn hammerDurationMs() u64 {
    if (std.c.getenv("CLEAR_HAMMER_SECONDS")) |env_z| {
        const s = std.mem.span(env_z);
        const secs = std.fmt.parseInt(u64, s, 10) catch 0;
        if (secs > 0) return secs * 1000;
    }
    if (build_options.coverage) return 50;
    return if (builtin.mode == .Debug) 1000 else 2000;
}

fn initSched(alloc: std.mem.Allocator, ebr: *EbrContext, sp: *fm.StackPool) !fp.Scheduler {
    return fp.Scheduler.init(alloc, ebr, sp);
}

// Shared state exercised by every fiber. All fields that aren't a lock
// are accessed only under the lock they're associated with.
const Shared = struct {
    mu: ParkingMutex = .{},
    rw: ParkingRwLock = .{},

    // Guarded by mu. Each fiber's increments are summed here.
    counter: u64 = 0,

    // Guarded by rw write-lock; read under rw read-lock. Mirror of
    // counter for cross-checking.
    writer_counter: u64 = 0,

    // Aggregate per-fiber work counts; summed at the end and compared.
    per_fiber_writes: [NUM_FIBERS]u64 = [_]u64{0} ** NUM_FIBERS,
    per_fiber_rw_writes: [NUM_FIBERS]u64 = [_]u64{0} ** NUM_FIBERS,

    // Set to true by any fiber that fails a detection integrity probe.
    // Read at the end; if any fiber flipped it, the test fails.
    detection_regression: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    wg: CheatHeader.WaitGroup,
    deadline_ms: i64 = 0,
};

// Minimal deterministic PRNG seeded per fiber.
fn rotl(x: u64, k: u6) u64 { return (x << k) | (x >> @intCast(@as(u7, 64) - k)); }
fn nextRand(state: *u64) u64 {
    // xorshift64*. Good-enough randomness for workload selection.
    var x = state.*;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    state.* = x;
    return rotl(x, 17) *% 0x2545F4914F6CDD1D;
}

const WorkerCtx = struct {
    shared: *Shared,
    fiber_id: u32,
    seed: u64,
};

// Probe detection integrity. Acquire the mutex, then try to re-acquire:
// the second attempt must return error.Deadlock. If it returns a Guard
// (detection regressed) we signal failure and release both holds to
// keep the test moving.
fn probeDetection(s: *Shared) void {
    s.mu.lock() catch |e| {
        // We only probe when we expect to acquire cleanly; any error
        // here means the lock was unexpectedly in a bad state.
        std.debug.print("probeDetection: outer lock returned {}\n", .{e});
        s.detection_regression.store(true, .release);
        return;
    };
    defer s.mu.unlock();
    s.mu.lock() catch |e| {
        if (e != error.Deadlock) {
            std.debug.print("probeDetection: re-acquire returned {} (expected Deadlock)\n", .{e});
            s.detection_regression.store(true, .release);
        }
        return; // Good — detection fired.
    };
    // Re-acquire succeeded — detection regressed.
    s.mu.unlock();
    s.detection_regression.store(true, .release);
}

fn workerFn(_: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
    const ctx: *WorkerCtx = @ptrCast(@alignCast(raw_args.?));
    defer ctx.shared.wg.done();

    var prng_state: u64 = ctx.seed;
    var iter: u32 = 0;

    while (compat.milliTimestamp() < ctx.shared.deadline_ms) : (iter += 1) {
        // Detection integrity probe every ~DETECTION_PROBE_EVERY iters.
        if (iter % DETECTION_PROBE_EVERY == 0 and iter > 0) {
            probeDetection(ctx.shared);
            continue;
        }

        const r = nextRand(&prng_state);
        const action = r % 4;

        switch (action) {
            0 => {
                // Mutex write: increment under lock.
                ctx.shared.mu.lock() catch unreachable;
                ctx.shared.counter += 1;
                ctx.shared.per_fiber_writes[ctx.fiber_id] += 1;
                ctx.shared.mu.unlock();
            },
            1 => {
                // RwLock read: sample the writer_counter. We don't
                // assert anything on reads — they just exercise the
                // shared path.
                ctx.shared.rw.lockShared() catch unreachable;
                _ = ctx.shared.writer_counter;
                ctx.shared.rw.unlockShared();
            },
            2 => {
                // RwLock write: increment writer_counter.
                ctx.shared.rw.lock() catch unreachable;
                ctx.shared.writer_counter += 1;
                ctx.shared.per_fiber_rw_writes[ctx.fiber_id] += 1;
                ctx.shared.rw.unlock();
            },
            3 => {
                // Short CS: lock + unlock with no work. Exercises the
                // uncontended fast path most heavily.
                ctx.shared.mu.lock() catch unreachable;
                ctx.shared.mu.unlock();
            },
            else => unreachable,
        }
    }
}

// HAMMER-COVERS: parking-lot.mutex-non-fiber-acquire
test "VOPR hammer: parking-lot under randomized fiber schedule" {
    const t_alloc = std.testing.allocator;
    var ebr = EbrContext{};
    defer ebr.deinit(t_alloc);
    var rt = try Runtime.init(t_alloc, 512 * 1024, &ebr);
    defer rt.deinit();
    rt.wireAllocator();
    var sp = fm.StackPool.init(t_alloc);
    defer sp.deinit();
    var sched = try initSched(t_alloc, &ebr, &sp);
    defer { sched.deinit(); fp.global_registry.deinit(t_alloc); }
    // Long lock timeout so a slow iteration doesn't spuriously time out.
    sched.lock_timeout_ms = 30_000;
    fp.active_scheduler = &sched;

    const duration_ms = hammerDurationMs();
    const deadline = compat.milliTimestamp() + @as(i64, @intCast(duration_ms));

    var shared = Shared{
        .wg = CheatHeader.WaitGroup.init(&sched),
        .deadline_ms = deadline,
    };

    var contexts: [NUM_FIBERS]WorkerCtx = undefined;
    for (&contexts, 0..) |*c, i| {
        c.* = .{
            .shared = &shared,
            .fiber_id = @intCast(i),
            // Deterministic-but-distinct seed per fiber.
            .seed = @as(u64, @intCast(i)) *% 2654435761 + @as(u64, @intCast(duration_ms)),
        };
    }

    const Main = struct {
        s: *Shared,
        ctxs: *[NUM_FIBERS]WorkerCtx,
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            self.s.wg.add(NUM_FIBERS);
            for (self.ctxs) |*c| {
                try fp.active_scheduler.submitSpawn(
                    @intFromPtr(&Runtime.entryWrapper),
                    @as(CheatHeader.TaskFn, @ptrCast(&workerFn)),
                    c,
                    .{ .stack_size = .Large },
                );
            }
            self.s.wg.wait();
        }
    };
    var main_ctx = Main{ .s = &shared, .ctxs = &contexts };
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&Main.run)),
        &main_ctx,
        .{ .stack_size = .Large },
    );

    sched.run();

    // Invariant 1: counter equals the sum of per-fiber mutex writes.
    var sum_writes: u64 = 0;
    for (shared.per_fiber_writes) |n| sum_writes += n;
    try std.testing.expectEqual(sum_writes, shared.counter);

    // Invariant 2: writer_counter equals the sum of per-fiber rw writes.
    var sum_rw: u64 = 0;
    for (shared.per_fiber_rw_writes) |n| sum_rw += n;
    try std.testing.expectEqual(sum_rw, shared.writer_counter);

    // Invariant 3: detection fired on every integrity probe.
    try std.testing.expect(!shared.detection_regression.load(.acquire));

    // Invariant 4: post-hammer lock state is clean.
    try std.testing.expect(!shared.mu.isLocked());
    try std.testing.expect(!shared.rw.isWriteLocked());
    try std.testing.expectEqual(@as(i32, 0), shared.rw.readerCount());

    // Emit a progress line so nightly runs show how much work got done.
    std.debug.print(
        "\n  VOPR hammer: {}ms  mutex_writes={}  rw_writes={}  fibers={}\n",
        .{ duration_ms, sum_writes, sum_rw, NUM_FIBERS },
    );
}
