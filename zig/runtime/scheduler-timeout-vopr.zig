//! VOPR scenarios for scheduler timeout / sleep paths.
//!
//! Drives `scanLockWaiters` / `wakeExpiredSleepers` / `scanFsmLock-
//! Waiters` deterministically by advancing SimClock past the deadline
//! and then verifying the timeout-fire branch executes. Designed to
//! run inside the `scheduler-timeout-vopr` EXECUTABLE (not a
//! `b.addTest`) so `@import("root")` resolves to the entry file
//! that exposes `pub const SimClock = ...` -- only then does the
//! comptime SimClock seam in lib/compat.zig activate.
//!
//! Goal: cover the time-related sites in scheduler.zig under VOPR's
//! virtual-clock determinism:
//!   L1456  wakeExpiredSleepers: const now = milliTimestamp();
//!   L1910  scanLockWaiters:     const now_ms = milliTimestamp();
//!
//! Each scenario calls `SimClock.reset()` first so it's hermetic.

const std = @import("std");

const ebr_mod = @import("../lib/ebr.zig");
const compat = @import("../lib/compat.zig");
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const qs = @import("queues.zig");
const fc = @import("fiber-core.zig");
const fsm_mod = @import("fsm.zig");
const rt_mod = @import("runtime.zig");
const sim_atomic = @import("vopr-atomic.zig");
const observable = @import("../lib/observable.zig");
const profile_lock = @import("profile-lock.zig");
const fiber_profile = @import("fiber-profile.zig");
const lock_profile = @import("lock-profile.zig");
const SimClock = @import("testing/vopr-clock.zig").SimClock;

const Task = qs.Task;
const TaskStatus = qs.TaskStatus;

fn dummyFn(_: *anyopaque, _: ?*anyopaque) anyerror!void {}
fn dummyFsmResume(_: *fsm_mod.FsmTask) fsm_mod.YieldReason {
    return .Done;
}

var lock_sentinel: u8 = 0;

/// SimClock-active liveness check. If `compat.milliTimestamp()`
/// returns SimClock's virtual time, advancing the clock by 1234ms
/// must move the read by the same amount. If it falls through to
/// the OS clock, the delta will be way larger (real elapsed time)
/// and the test fails -- catches the GAP-B regression where the
/// SimClock seam silently disables.
pub fn testSimClockActive() !void {
    SimClock.reset();
    const t0 = compat.milliTimestamp();
    SimClock.advanceMs(1234);
    const t1 = compat.milliTimestamp();
    if (t1 - t0 != 1234) return error.SimClockNotActive;
}

pub fn testScanLockWaitersTimeoutFire() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        const final_b = sched.ready_queue.bottom.load(.monotonic);
        sched.ready_queue.top.store(final_b, .monotonic);
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }

    SimClock.reset();
    sched.lock_timeout_ms = 100;

    var stub_task: Task = .{
        .base = undefined,
        .user_fn = @ptrCast(&dummyFn),
        .status = qs.Atomic(TaskStatus).init(.Blocked),
    };
    stub_task.waiting_for_lock.store(@ptrCast(&lock_sentinel), .release);
    stub_task.lock_wait_start_ms.store(compat.milliTimestamp(), .release);
    stub_task.waiting_for_lock_list.store(null, .release);

    try sched.lock_waiters.append(allocator, &stub_task);

    // 50ms in: still within the 100ms deadline. No timeout.
    SimClock.advanceMs(50);
    _ = sched.scanLockWaitersPub();
    if (stub_task.waiting_for_lock.load(.monotonic) == null) return error.PrematureTimeout;
    if (sched.lock_waiters.items.len != 1) return error.WaiterRemovedTooEarly;

    // 150ms in (advance another 100ms): past the deadline. Timeout fires.
    SimClock.advanceMs(100);
    _ = sched.scanLockWaitersPub();
    if (stub_task.waiting_for_lock.load(.monotonic) != null) return error.TimeoutDidNotFire;
    if (!stub_task.lock_timed_out.load(.monotonic)) return error.LockTimedOutNotSet;
    if (stub_task.status.load(.monotonic) != .Ready) return error.StatusNotReady;
    if (sched.lock_waiters.items.len != 0) return error.WaiterNotRemoved;
}

pub fn testWakeExpiredSleepers() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        const final_b = sched.ready_queue.bottom.load(.monotonic);
        sched.ready_queue.top.store(final_b, .monotonic);
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }

    SimClock.reset();

    var stub_task: Task = .{
        .base = undefined,
        .user_fn = @ptrCast(&dummyFn),
        .status = qs.Atomic(TaskStatus).init(.Blocked),
        .wake_time = 1000,
    };
    try sched.sleeping_queue.append(allocator, &stub_task);

    // 500ms in (before wake_time=1000): no wake.
    SimClock.advanceMs(500);
    sched.wakeExpiredSleepers();
    if (sched.sleeping_queue.items.len != 1) return error.PrematureWake;
    if (stub_task.status.load(.monotonic) != .Blocked) return error.StatusChangedTooEarly;

    // 1100ms in (past wake_time): wake fires.
    SimClock.advanceMs(600);
    sched.wakeExpiredSleepers();
    if (sched.sleeping_queue.items.len != 0) return error.WakeDidNotFire;
    if (stub_task.status.load(.monotonic) != .Ready) return error.StatusNotReady;
}

/// Drives compat.nanoTimestamp + compat.Timer through the SimClock
/// seam. Without this test, the nanoTimestamp / Timer call sites in
/// lib/compat.zig (lines ~156-177) are FILE-LOADED but never reached
/// by any VOPR scenario -- those sites support Timer-based latency
/// instrumentation in the runtime, and we want VOPR to confirm the
/// virtual-clock contract for them too.
///
/// Asserts:
///   - compat.nanoTimestamp() returns SimClock-driven time
///   - Timer.start() captures the virtual now, Timer.read() returns
///     elapsed ns from the virtual clock
///   - Timer.reset() re-captures
pub fn testCompatTimerSimClock() !void {
    SimClock.reset();

    const t0 = compat.nanoTimestamp();
    if (t0 != 0) return error.UnexpectedInitialNs;

    SimClock.advanceMs(7);
    const t1 = compat.nanoTimestamp();
    if (t1 - t0 != 7_000_000) return error.NanoTimestampDelta;

    var timer = try compat.Timer.start();
    if (timer.read() != 0) return error.TimerStartNonZero;

    SimClock.advanceMs(123);
    if (timer.read() != 123_000_000) return error.TimerReadDelta;

    SimClock.advanceNs(456);
    if (timer.read() != 123_000_456) return error.TimerNsResolution;

    timer.reset();
    if (timer.read() != 0) return error.TimerResetNonZero;

    SimClock.advanceMs(50);
    if (timer.read() != 50_000_000) return error.TimerPostResetDelta;
}

/// Drives Runtime.checkpoint() under SimClock.
///
/// Covers:
///   runtime.zig:21-22  fn milliTimestamp wrapper
///   runtime.zig:278    initFromSlice deadline computation
///   runtime.zig:516    checkpoint deadline check
///
/// Runtime is initialized with timeout_ms=100. Checkpoint inside the
/// deadline returns OK; advancing SimClock past the deadline makes
/// the next checkpoint return error.Timeout.
pub fn testRuntimeCheckpointTimeout() !void {
    const allocator = std.heap.c_allocator;

    var ebr_ctx: ebr_mod.EbrContext = .{};
    defer ebr_ctx.deinit(allocator);

    SimClock.reset();
    var slice: [2048]u8 = undefined;
    var rt = try rt_mod.Runtime.initFromSlice(&slice, &ebr_ctx, allocator, 100);
    defer rt.deinit();

    // Inside deadline (now=0, deadline=100): checkpoint succeeds.
    SimClock.advanceMs(50);
    rt.checkpoint() catch return error.PrematureTimeout;

    // Past deadline (now=150, deadline=100): checkpoint returns Timeout.
    SimClock.advanceMs(100);
    if (rt.checkpoint()) |_| {
        return error.TimeoutDidNotFire;
    } else |err| if (err != error.Timeout) return err;
}

// testWaitGroupSpinlockUnderFault and testSemaphoreSpinlockUnderFault
// were dropped in V29: routing scheduler.zig WaitGroup/Semaphore
// counter+lock through the comptime `Atomic` alias (so SimAtomic.swap
// fault injection could reach them) destabilized stream-test's TSan
// SplitStream pubsub hammer (3% master flake -> 17% with the
// migration). The migration is semantically a no-op under TSan
// (Atomic = std.atomic.Value) but timing-perturbing enough to amplify
// a pre-existing race. Reverted to keep TSan green; fault injection
// on these primitives needs a different approach (e.g., interceptor
// hooks rather than a type-level alias).

/// Drives queues.WaiterList.spinAcquire's CAS retry body under fault
/// injection. WaiterList is internal to parking-lot's contended path;
/// directly constructing one + calling spinAcquire/spinRelease with
/// faulted CAS forces the retry loop to spin a few times before
/// succeeding.
pub fn testWaiterListSpinlockUnderFault() !void {
    var wl: qs.WaiterList = .{};

    sim_atomic.seedFault(3);
    sim_atomic.inject_cas_fault = true;
    sim_atomic.inject_cas_fault_rate = 7000;

    const synthetic_before = sim_atomic.sim_cmpxchg_synthetic_fault_count;

    // Acquire/release pairs each contest the spinlock. With 70% rate
    // each cmpxchgWeak fails synthetically several times before
    // succeeding. The retry body (spinLoopHint line) runs each fail.
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        wl.spinAcquire();
        wl.spinRelease();
    }

    const synthetic_after = sim_atomic.sim_cmpxchg_synthetic_fault_count;
    if (synthetic_after == synthetic_before) return error.NoFaultInjected;

    // Lock state is 0 after the final release.
    if (wl.spin.load(.monotonic) != 0) return error.SpinNotReleased;

    sim_atomic.resetFault();
}

/// Drives observable.SpinLock.lock's CAS retry body under fault
/// injection. Mirrors testWaiterListSpinlockUnderFault but for the
/// SpinLock at zig/lib/observable.zig:1135 (used by StreamSet).
pub fn testObservableSpinLockUnderFault() !void {
    var lock: observable.SpinLock = .{};

    sim_atomic.seedFault(4);
    sim_atomic.inject_cas_fault = true;
    sim_atomic.inject_cas_fault_rate = 7000;

    const synthetic_before = sim_atomic.sim_cmpxchg_synthetic_fault_count;

    var i: usize = 0;
    while (i < 4) : (i += 1) {
        lock.lock();
        lock.unlock();
    }

    const synthetic_after = sim_atomic.sim_cmpxchg_synthetic_fault_count;
    if (synthetic_after == synthetic_before) return error.NoFaultInjected;

    if (lock.flag.load(.monotonic)) return error.LockNotReleased;

    sim_atomic.resetFault();
}

/// Drives SmartEventFd.consume's posix.read path (scheduler.zig:207).
/// Constructs a real eventfd, writes a wake token, then calls consume()
/// which posix.read's it. Single-shot, deterministic.
pub fn testSmartEventFdConsume() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }

    // sched.event_fd is initialized by Scheduler.init. notify() writes
    // a wake token to the eventfd; consume() drains it via posix.read.
    sched.event_fd.notify();
    sched.event_fd.consume();
}

/// Drives the scheduler.submit{Read,Write,Accept,Connect,Recv,Send}
/// io_uring submission fns through the SimRing seam. Covers the
/// `self.ring.X` call sites (ring_io category) plus the
/// `waiter.task.status.store(.Blocked)` lines after each submission.
/// Uses a stub Task; SimRing stages SQEs without touching real fds.
pub fn testIoSubmitFns() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }

    var stub_task: Task = .{
        .base = undefined,
        .user_fn = @ptrCast(&dummyFn),
        .status = qs.Atomic(TaskStatus).init(.Ready),
    };
    var w: fp.Scheduler.IoWaiter = .{ .task = &stub_task };
    var buf: [16]u8 = undefined;
    const cbuf: []const u8 = &buf;

    try sched.submitRead(&w, 0, &buf);
    try sched.submitWrite(&w, 0, cbuf);
    try sched.submitAccept(&w, 0);
    var addr: std.posix.sockaddr = undefined;
    try sched.submitConnect(&w, 0, &addr, @sizeOf(std.posix.sockaddr));
    try sched.submitRecv(&w, 0, &buf);
    try sched.submitSend(&w, 0, cbuf);

    // FSM-mode variants: same SQE shape but tagged with the FsmIoWaiter
    // marker so processCqes routes the completion to the FSM ready
    // queue. Covers ring_io sites at scheduler.zig:1825/1867/1876.
    var stub_fsm: fsm_mod.FsmTask = .{ .resume_fn = &dummyFsmResume };
    var fw: fsm_mod.FsmIoWaiter = .{ .task = &stub_fsm };
    try sched.submitReadForFsm(&fw, 0, &buf);
    try sched.submitRecvForFsm(&fw, 0, &buf);
    try sched.submitWriteForFsm(&fw, 0, cbuf);
}

/// File-loads runtime/fiber-profile.zig and runtime/lock-profile.zig
/// (and transitively runtime/profile-lock.zig) by calling their pub
/// record fns. nowNs() in each file calls compat.nanoTimestamp;
/// SimClock makes the read deterministic. The record fns acquire
/// the profile-lock SpinLock briefly and update an internal table.
pub fn testProfileFilesLoad() !void {
    SimClock.reset();

    fiber_profile.resetForTest();
    fiber_profile.recordSchedulerRun(0);
    const t0 = fiber_profile.nowNs();

    SimClock.advanceMs(5);
    const t1 = fiber_profile.nowNs();
    if (t1 - t0 != 5_000_000) return error.FiberProfileNanoTimestampNotSimClock;

    // lock-profile.recordAcquire takes the profile-lock SpinLock,
    // updates the per-lock latency table.
    lock_profile.recordAcquire(0xCAFE, 1500, true);
    const lt = lock_profile.now();
    SimClock.advanceMs(3);
    const lt2 = lock_profile.now();
    if (lt2 - lt != 3_000_000) return error.LockProfileNanoTimestampNotSimClock;
}

/// Drives profile-lock.SpinLock's swap retry body under fault
/// injection. profile-lock is the spinlock inside fiber-profile,
/// lock-profile, alloc-profile, channel-profile, mvcc-profile --
/// covering it once covers the spinlock retry on all five profile
/// modules.
pub fn testProfileLockUnderFault() !void {
    var pl: profile_lock.SpinLock = .{};

    sim_atomic.seedFault(7);
    sim_atomic.inject_swap_busy_fault = true;
    sim_atomic.inject_swap_busy_rate = 7000;

    const synthetic_before = sim_atomic.sim_swap_synthetic_fault_count;

    var i: usize = 0;
    while (i < 4) : (i += 1) {
        pl.lock();
        pl.unlock();
    }

    const synthetic_after = sim_atomic.sim_swap_synthetic_fault_count;
    if (synthetic_after == synthetic_before) return error.NoSwapFaultInjected;

    if (pl.locked.load(.monotonic)) return error.LockNotReleased;

    sim_atomic.resetFault();
}

/// Drives wakeExpiredFsmSleepers (extracted in this commit from
/// scheduler.zig run() inline). Mirrors testWakeExpiredSleepers but
/// for FSM tasks. Covers scheduler.zig:1189 (the milliTimestamp read
/// inside the FSM sleep wake scan).
pub fn testWakeExpiredFsmSleepers() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }

    const now_ms = compat.milliTimestamp();

    // Future wake_time -> nothing wakes.
    {
        var future: fsm_mod.FsmTask = .{
            .resume_fn = &dummyFsmResume,
            .fsm_wake_time = now_ms + 60_000,
        };
        try sched.fsm_sleeping_queue.append(allocator, &future);
        sched.wakeExpiredFsmSleepers();
        if (sched.fsm_sleeping_queue.items.len != 1) return error.PrematureWake;
        _ = sched.fsm_sleeping_queue.swapRemove(0);
    }

    // Past wake_time -> wakes; pushed to fsm_ready_queue with status=.Ready.
    var past: fsm_mod.FsmTask = .{
        .resume_fn = &dummyFsmResume,
        .fsm_wake_time = now_ms - 100,
    };
    try sched.fsm_sleeping_queue.append(allocator, &past);
    sched.wakeExpiredFsmSleepers();
    if (sched.fsm_sleeping_queue.items.len != 0) return error.WakeDidNotFire;
    if (past.status != .Ready) return error.StatusNotReady;
}

/// Drives earliestLockWaiterDeadlineMsUntil (extracted in this commit
/// from scheduler.zig run() idle-arming). Covers scheduler.zig:1374
/// (the milliTimestamp call), the deadline-min loop, and the empty-
/// list early return.
pub fn testEarliestLockWaiterDeadline() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }

    sched.lock_timeout_ms = 100;

    // Empty list -> null (early return).
    if (sched.earliestLockWaiterDeadlineMsUntil() != null) return error.EmptyExpectedNull;

    // Single waiter, started 30ms ago: deadline is 70ms from now.
    const sentinel: u8 = 0;
    var task1: Task = .{
        .base = undefined,
        .user_fn = @ptrCast(&dummyFn),
        .status = qs.Atomic(TaskStatus).init(.Blocked),
    };
    task1.waiting_for_lock.store(@constCast(@ptrCast(&sentinel)), .release);
    task1.lock_wait_start_ms.store(compat.milliTimestamp() - 30, .release);
    try sched.lock_waiters.append(allocator, &task1);

    const ms_until1 = sched.earliestLockWaiterDeadlineMsUntil() orelse return error.UnexpectedNull;
    if (ms_until1 <= 0 or ms_until1 > 100) return error.DeadlineOutOfRange;

    // Skip-null path: a waiter with waiting_for_lock = null should be
    // ignored by the loop. Add it; the result should be unchanged.
    var task2: Task = .{
        .base = undefined,
        .user_fn = @ptrCast(&dummyFn),
        .status = qs.Atomic(TaskStatus).init(.Blocked),
    };
    task2.waiting_for_lock.store(null, .release);
    task2.lock_wait_start_ms.store(0, .release);
    try sched.lock_waiters.append(allocator, &task2);

    const ms_until2 = sched.earliestLockWaiterDeadlineMsUntil() orelse return error.UnexpectedNull;
    if (ms_until2 != ms_until1) return error.SkipNullChangedDeadline;
}

/// Drives registerLockWaiter directly (scheduler.zig:1674).
pub fn testRegisterLockWaiter() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }

    var stub_task: Task = .{
        .base = undefined,
        .user_fn = @ptrCast(&dummyFn),
        .status = qs.Atomic(TaskStatus).init(.Blocked),
    };

    sched.registerLockWaiter(&stub_task);

    if (sched.lock_waiters.items.len != 1) return error.WaiterNotAppended;
    if (sched.lock_waiters.items[0] != &stub_task) return error.WrongWaiter;
    // lock_wait_start_ms was stamped with milliTimestamp() inside
    // registerLockWaiter; verify it's a sane non-zero value.
    if (stub_task.lock_wait_start_ms.load(.acquire) == 0) {
        return error.WaitStartMsNotStamped;
    }
}

// ──────────────────────────────────────────────────────────────────
// Real fiber harness for VOPR scenarios that need a live fiber stack.
//
// Pattern: allocate a stack, build a Fiber with the test entry as
// the start address, wrap it in a Task pointing at the Fiber. Set
// fp.active_scheduler + sched.current_task so Runtime / scheduler
// helpers that read those globals see the right context. switchTo
// runs the fiber until it yields back; harness then exercises the
// wake side (e.g., SimClock.advanceMs + wakeExpiredSleepers) and
// switchTo's again to resume.
//
// Single-deterministic by design. No interleaving exploration --
// VOPR's value here is reproducible single-seed end-to-end paths,
// not exhaustive ordering. Loom owns the latter.
// ──────────────────────────────────────────────────────────────────

const FIBER_HARNESS_STACK_SIZE: usize = 64 * 1024;

const SleepHarness = struct {
    sched: *fp.Scheduler,
    rt: *rt_mod.Runtime,
    sleep_ms: u64,
    entered: bool = false,
    woke: bool = false,
};

var g_sleep_harness: ?*SleepHarness = null;

fn sleepMinimalEntry() callconv(.c) void {
    const h = g_sleep_harness orelse @panic("sleep harness null");
    h.entered = true;
    fc.__fiber.?.yield();
    // After resume:
    h.woke = true;
    while (true) fc.__fiber.?.yield();
}

fn sleepFiberEntry() callconv(.c) void {
    const h = g_sleep_harness orelse @panic("sleep harness null");
    h.entered = true;
    h.rt.sleep(h.sleep_ms);
    // Reaching this line proves the fiber resumed from rt.sleep.
    h.woke = true;
    // Park forever so the harness can verify state without the fiber
    // running off the end of its stack.
    while (true) fc.__fiber.?.yield();
}

/// Clear the fiber thread-locals so subsequent atomic ops don't try
/// to yield through a stale fiber pointer. Fiber.yield() sets
/// `__fiber = undefined` (not null), and `__fiber_parent_ctx` is
/// left pointing at the harness frame. Under SimAtomic, every atomic
/// op calls yieldPoint() which checks `if (fc.__fiber_parent_ctx
/// != null)` and then derefs `fc.__fiber` — undefined-after-yield
/// is a GP fault waiting to happen the moment sched.deinit (or any
/// other atomic op) runs in the harness frame. Call this AFTER the
/// last fiber.switchTo returns and BEFORE any allocator/sched ops.
fn clearFiberTLS() void {
    fc.__fiber = null;
    fc.__fiber_parent_ctx = null;
    fc.__fiber_stack_limit = null;
}

/// Minimal fiber-harness sanity check: spawn a fiber, switchTo it,
/// it sets entered=true and yields. switchTo it again, it sets
/// woke=true and parks. Verifies the bare switchTo/yield mechanism
/// works without involving Runtime.sleep or scheduler queues.
pub fn testFiberHarnessMinimal() !void {
    const allocator = std.heap.c_allocator;

    var ebr_ctx: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr_ctx, &stack_pool);

    const stack_mem = try allocator.alloc(u8, FIBER_HARNESS_STACK_SIZE);

    var fiber = fc.Fiber.init(stack_mem, @intFromPtr(&sleepMinimalEntry), .Large);

    var harness = SleepHarness{
        .sched = &sched,
        .rt = undefined,
        .sleep_ms = 0,
    };
    g_sleep_harness = &harness;

    fiber.switchTo(&sched.main_ctx);
    if (!harness.entered) {
        clearFiberTLS();
        return error.FiberDidNotEnter;
    }
    if (harness.woke) {
        clearFiberTLS();
        return error.FiberWokeBeforeResume;
    }

    fiber.switchTo(&sched.main_ctx);
    if (!harness.woke) {
        clearFiberTLS();
        return error.FiberDidNotResume;
    }

    // CRITICAL: clear fiber TLS before any further atomic ops in this
    // frame. sched.deinit + allocator.free + ebr.deinit all touch
    // SimAtomic-aliased atomics; yieldPoint would otherwise dereference
    // the stale __fiber and GP-fault.
    clearFiberTLS();
    g_sleep_harness = null;
    allocator.free(stack_mem);
    sched.deinit();
    stack_pool.deinit();
    ebr_ctx.deinit(allocator);
}

/// End-to-end sleep -> wake test via a real fiber.
///
/// Sequence:
///   1. Spawn a fiber whose body is `rt.sleep(SLEEP_MS); woke=true`.
///   2. switchTo the fiber. Inside Runtime.sleep:
///        - milliTimestamp() at runtime.zig:611  (the previously
///          uncovered site)
///        - sched.sleepTask(task, wake_time) appends to sleeping_queue
///        - task.base.yield() returns control HERE.
///   3. Verify task is in sleeping_queue with status .Blocked.
///   4. SimClock.advanceMs(SLEEP_MS + 1).
///   5. wakeExpiredSleepers() pops the task into ready_queue.
///   6. switchTo the fiber again. The fiber resumes from inside
///      rt.sleep, runs `woke = true`, and parks at the trailing
///      yield loop.
///   7. Verify woke == true and the fiber's status went through
///      Blocked -> Ready.
///
/// This is the canonical VOPR fiber-harness pattern. Future fiber-
/// bearing scenarios (Stream/InfStream push/next, multi-fiber wake
/// races, stack-switch-correctness) build on the same shape.
pub fn testRuntimeSleepEndToEnd() !void {
    const allocator = std.heap.c_allocator;
    const SLEEP_MS: u64 = 100;

    var ebr_ctx: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr_ctx, &stack_pool);

    var slice: [4096]u8 = undefined;
    var rt = try rt_mod.Runtime.initFromSlice(&slice, &ebr_ctx, allocator, 0);

    const stack_mem = try allocator.alloc(u8, FIBER_HARNESS_STACK_SIZE);
    var fiber = fc.Fiber.init(stack_mem, @intFromPtr(&sleepFiberEntry), .Large);
    var task: qs.Task = .{
        .base = &fiber,
        .user_fn = @ptrCast(&dummyFn),
        .status = qs.Atomic(qs.TaskStatus).init(.Ready),
    };

    var harness = SleepHarness{
        .sched = &sched,
        .rt = &rt,
        .sleep_ms = SLEEP_MS,
    };
    g_sleep_harness = &harness;

    const prev_active = fp.active_scheduler;
    const prev_running = fp.scheduler_running;
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;
    sched.current_task = &task;

    SimClock.reset();
    var test_err: ?anyerror = null;

    // SimAtomic's yieldPoint normally yields the fiber back to the
    // harness on every atomic op (Loom-coordinator contract). For a
    // VOPR fiber harness driving REAL production code, the atomic ops
    // inside e.g. sched.sleepTask are part of the transition, not
    // walk-through yield points. Disable yield-on-atomic for the
    // duration of the fiber's execution.
    sim_atomic.disable_fiber_yield_point = true;

    // 1. Run the fiber until it yields inside rt.sleep().
    fiber.switchTo(&sched.main_ctx);

    // 2. Post-yield: task should be in sleeping_queue, .Blocked.
    if (test_err == null and !harness.entered) test_err = error.FiberDidNotEnter;
    if (test_err == null and sched.sleeping_queue.items.len != 1) test_err = error.NotInSleepingQueue;
    if (test_err == null and sched.sleeping_queue.items[0] != &task) test_err = error.WrongSleeperTask;
    if (test_err == null and task.status.load(.acquire) != .Blocked) test_err = error.NotBlocked;
    if (test_err == null and harness.woke) test_err = error.WokeBeforeSleep;

    if (test_err == null) {
        // 3. Advance SimClock past wake_time + run wake path.
        SimClock.advanceMs(@as(i64, @intCast(SLEEP_MS)) + 1);
        sched.wakeExpiredSleepers();

        if (sched.sleeping_queue.items.len != 0) test_err = error.WakeDidNotRemove;
        if (test_err == null and task.status.load(.acquire) != .Ready) test_err = error.NotReadyAfterWake;
    }

    if (test_err == null) {
        // 4. Resume the fiber. Runtime.sleep returns; entry sets woke=true,
        // re-enters while(true) yield, ctrl returns here.
        fiber.switchTo(&sched.main_ctx);
        if (!harness.woke) test_err = error.WokeFlagNotSet;
    }

    // CRITICAL: clear fiber TLS before any subsequent atomic ops in
    // this frame. After the fiber's last yield, __fiber is undefined
    // and yieldPoint() in SimAtomic would deref it. Drain the ready
    // queue so sched.deinit doesn't walk our stack-allocated task.
    clearFiberTLS();
    sim_atomic.disable_fiber_yield_point = false;
    sched.current_task = null;
    fp.active_scheduler = prev_active;
    fp.scheduler_running = prev_running;
    g_sleep_harness = null;

    // The wake moved &task into ready_queue. Drain it so sched.deinit
    // doesn't try to allocator.destroy(task.base) on our stack-Fiber.
    const final_b = sched.ready_queue.bottom.load(.monotonic);
    sched.ready_queue.top.store(final_b, .monotonic);

    rt.deinit();
    allocator.free(stack_mem);
    sched.deinit();
    stack_pool.deinit();
    ebr_ctx.deinit(allocator);

    if (test_err) |e| return e;
}

pub fn testScanFsmLockWaitersTimeoutFire() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }

    SimClock.reset();
    sched.lock_timeout_ms = 100;

    var stub_fsm: fsm_mod.FsmTask = .{ .resume_fn = &dummyFsmResume };
    stub_fsm.waiting_for_lock.store(@ptrCast(&lock_sentinel), .release);
    stub_fsm.lock_wait_start_ms.store(compat.milliTimestamp(), .release);
    stub_fsm.waiting_for_lock_list.store(null, .release);

    try sched.fsm_lock_waiters.append(allocator, &stub_fsm);

    SimClock.advanceMs(50);
    sched.scanFsmLockWaitersPub();
    if (stub_fsm.waiting_for_lock.load(.monotonic) == null) return error.PrematureTimeout;

    SimClock.advanceMs(100);
    sched.scanFsmLockWaitersPub();
    if (stub_fsm.waiting_for_lock.load(.monotonic) != null) return error.TimeoutDidNotFire;
    if (sched.fsm_lock_waiters.items.len != 0) return error.WaiterNotRemoved;
}
