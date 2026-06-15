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
const compat = @import("../lib/compat.zig");
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const sim_atomic = @import("vopr-atomic.zig");
const SimClock = @import("testing/vopr-clock.zig").SimClock;

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
    pub fn dupeValue(comptime T: type, value: T, alloc: std.mem.Allocator) !T {
        _ = alloc;
        return value;
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

pub fn testBatchWindowSimClockFlush() !void {
    const allocator = gpa.allocator();

    SimClock.reset();

    const BatchWindowI64 = DataStructures.BatchWindow(i64);
    var window = BatchWindowI64.init(allocator, 0, 10_000_000);
    defer window.deinit();

    if (try window.push(1)) |batch| {
        window.freeBatch(batch);
        return error.BatchFlushedTooEarly;
    }

    SimClock.advanceMs(5);
    if (try window.push(2)) |batch| {
        window.freeBatch(batch);
        return error.BatchFlushedTooEarly;
    }

    SimClock.advanceMs(6);
    const batch = (try window.push(3)) orelse return error.BatchDidNotFlush;
    defer window.freeBatch(batch);

    if (batch.len != 3) return error.BatchLenWrong;
    if (batch[0] != 1 or batch[1] != 2 or batch[2] != 3) return error.BatchContentsWrong;

    if (try window.flush()) |leftover| {
        window.freeBatch(leftover);
        return error.BatchLeftoverAfterFlush;
    }
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

fn resetSchedulerGlobals(allocator: std.mem.Allocator) void {
    fp.active_scheduler = undefined;
    fp.scheduler_running = false;
    fp.global_registry.deinit(allocator);
    fp.global_registry = .{};
}

const RemoteWorkerCtx = struct {
    allocator: std.mem.Allocator,
    ebr: *ebr_mod.EbrContext,
    stack_pool: *fm.StackPool,
    shutdown: *std.atomic.Value(bool),
};

fn partitionedMapRemoteWorker(ctx: *RemoteWorkerCtx) void {
    var sched = fp.Scheduler.init(ctx.allocator, ctx.ebr, ctx.stack_pool) catch return;
    defer sched.deinit();
    sched.global_shutdown = ctx.shutdown;
    sched.shutdown_on_idle = false;
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;
    sched.run();
    fp.scheduler_running = false;
}

fn keyForStringShard(comptime MapT: type, target_shard: usize, buf: []u8) ![]const u8 {
    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        const key = try std.fmt.bufPrint(buf, "remote-{d}", .{i});
        if (MapT.shardIndex(key) == target_shard) return key;
    }
    return error.NoStringShardKey;
}

fn keyForNumericShard(comptime MapT: type, target_shard: usize) !i64 {
    var i: i64 = 0;
    while (i < 10_000) : (i += 1) {
        if (MapT.shardIndex(i) == target_shard) return i;
    }
    return error.NoNumericShardKey;
}

/// Covers the partitioned-map ownership initialization protocol and the
/// stack-local operation completion flags for string and numeric maps.
/// The remote scheduler path is exercised by the TSan partitioned-map
/// suite; this VOPR case keeps the deterministic coverage target to the
/// ownership_init/owners[] fact setup and local operation contexts.
pub fn testPartitionedMapOwnershipLocalOps() !void {
    const allocator = gpa.allocator();

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
        resetSchedulerGlobals(allocator);
    }

    try fp.global_registry.register(allocator, std.Thread.getCurrentId(), &sched);
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;

    const StringMap = DataStructures.PartitionedStringMap(i64, 4);
    var smap: StringMap = .{};
    defer smap.deinit(allocator, allocator);

    try smap.put(allocator, allocator, "alpha", 11);
    if (smap.get("alpha") orelse -1 != 11) return error.StringMapGetWrong;
    if (!smap.contains("alpha")) return error.StringMapMissingKey;
    smap.remove(allocator, "alpha");
    if (smap.contains("alpha")) return error.StringMapRemoveFailed;

    const NumericMap = DataStructures.PartitionedNumericMap(i64, i64, 4);
    var nmap: NumericMap = .{};
    defer nmap.deinit(allocator, allocator);

    try nmap.put(allocator, allocator, 7, 77);
    if (nmap.get(7) orelse -1 != 77) return error.NumericMapGetWrong;
    if (!nmap.contains(7)) return error.NumericMapMissingKey;
    nmap.remove(allocator, 7);
    if (nmap.contains(7)) return error.NumericMapRemoveFailed;
}

fn completeStringOwnershipInit(map: *DataStructures.PartitionedStringMap(i64, 4)) void {
    compat.sleepNs(std.time.ns_per_ms);
    map.ownership_init.store(2, .release);
}

fn completeNumericOwnershipInit(map: *DataStructures.PartitionedNumericMap(i64, i64, 4)) void {
    compat.sleepNs(std.time.ns_per_ms);
    map.ownership_init.store(2, .release);
}

pub fn testPartitionedMapOwnershipWaiters() !void {
    const StringMap = DataStructures.PartitionedStringMap(i64, 4);
    var smap: StringMap = .{};
    smap.ownership_init.store(1, .release);
    const string_worker = try std.Thread.spawn(.{}, completeStringOwnershipInit, .{&smap});
    smap.ensureOwnership();
    string_worker.join();
    if (smap.ownership_init.load(.acquire) != 2) return error.StringOwnershipInitWaitFailed;

    const NumericMap = DataStructures.PartitionedNumericMap(i64, i64, 4);
    var nmap: NumericMap = .{};
    nmap.ownership_init.store(1, .release);
    const numeric_worker = try std.Thread.spawn(.{}, completeNumericOwnershipInit, .{&nmap});
    nmap.ensureOwnership();
    numeric_worker.join();
    if (nmap.ownership_init.load(.acquire) != 2) return error.NumericOwnershipInitWaitFailed;
}

/// Covers the remote partitioned-map path: owner selection routes a shard
/// to another scheduler, the caller sends a RemoteCall through the SPSC
/// channel, and the completion WaitGroup/finished flag is observed before
/// the stack-local operation context is destroyed.
pub fn testPartitionedMapRemoteOps() !void {
    const allocator = gpa.allocator();

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var main_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    var shutdown = std.atomic.Value(bool).init(false);
    var worker_ctx = RemoteWorkerCtx{
        .allocator = allocator,
        .ebr = &ebr,
        .stack_pool = &stack_pool,
        .shutdown = &shutdown,
    };
    var worker: ?std.Thread = null;
    defer {
        shutdown.store(true, .release);
        fp.global_registry.notifyAll();
        if (worker) |t| t.join();
        main_sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
        resetSchedulerGlobals(allocator);
    }

    try fp.global_registry.register(allocator, std.Thread.getCurrentId(), &main_sched);
    fp.active_scheduler = &main_sched;
    fp.scheduler_running = true;

    worker = try std.Thread.spawn(.{}, partitionedMapRemoteWorker, .{&worker_ctx});
    var wait_ms: usize = 0;
    while (fp.global_registry.count() < 2) : (wait_ms += 1) {
        if (wait_ms >= 5_000) return error.WorkerRegistrationTimeout;
        compat.sleepNs(std.time.ns_per_ms);
    }

    const StringMap = DataStructures.PartitionedStringMap(i64, 4);
    var smap: StringMap = .{};
    defer smap.deinit(allocator, allocator);
    var key_buf: [64]u8 = undefined;
    const skey = try keyForStringShard(StringMap, 1, &key_buf);

    try smap.put(allocator, allocator, skey, 101);
    if (smap.get(skey) orelse -1 != 101) return error.RemoteStringMapGetWrong;
    smap.remove(allocator, skey);
    if (smap.contains(skey)) return error.RemoteStringMapRemoveFailed;

    const NumericMap = DataStructures.PartitionedNumericMap(i64, i64, 4);
    var nmap: NumericMap = .{};
    defer nmap.deinit(allocator, allocator);
    const nkey = try keyForNumericShard(NumericMap, 1);

    try nmap.put(allocator, allocator, nkey, 202);
    if (nmap.get(nkey) orelse -1 != 202) return error.RemoteNumericMapGetWrong;
    nmap.remove(allocator, nkey);
    if (nmap.contains(nkey)) return error.RemoteNumericMapRemoveFailed;
}

pub fn testPartitionedMapPutAllocationFailureCompletes() !void {
    const allocator = gpa.allocator();

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
        resetSchedulerGlobals(allocator);
    }

    try fp.global_registry.register(allocator, std.Thread.getCurrentId(), &sched);
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;

    var byte: u8 = 0;
    const impossible_value = @as([*]const u8, @ptrCast(&byte))[0..std.math.maxInt(usize)];

    const StringMap = DataStructures.PartitionedStringMap([]const u8, 4);
    var smap: StringMap = .{};
    defer smap.deinit(allocator, allocator);

    if (smap.put(allocator, allocator, "oom-string", impossible_value)) |_| {
        return error.StringPutUnexpectedlySucceeded;
    } else |err| if (err != error.OutOfMemory) {
        return err;
    }
    if (smap.contains("oom-string")) return error.StringPutFailureInsertedKey;

    const NumericMap = DataStructures.PartitionedNumericMap(i64, []const u8, 4);
    var nmap: NumericMap = .{};
    defer nmap.deinit(allocator, allocator);

    if (nmap.put(allocator, allocator, 9001, impossible_value)) |_| {
        return error.NumericPutUnexpectedlySucceeded;
    } else |err| if (err != error.OutOfMemory) {
        return err;
    }
    if (nmap.contains(9001)) return error.NumericPutFailureInsertedKey;
}
