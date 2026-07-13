const std = @import("std");
const builtin = @import("builtin");

const qs = @import("queues.zig");
const fc = @import("fiber-core.zig");
const fm = @import("fiber-memory.zig");
const fsm_mod = @import("fsm.zig");
pub const FsmTask = fsm_mod.FsmTask;
pub const FsmIoWaiter = fsm_mod.FsmIoWaiter;
pub const FsmStatus = fsm_mod.FsmStatus;
pub const YieldReason = fsm_mod.YieldReason;
pub const FsmRunQueue = fsm_mod.FsmRunQueue;
pub const ResumeFn = fsm_mod.ResumeFn;
const compat = @import("../lib/compat.zig");
// Profile telemetry (comptime-gated). Imports are cheap; actual calls
// live inside `if (rt_profile.CLEAR_PROFILE)` blocks that compile away
// when the flag is false.
const rt_profile = @import("runtime-header.zig");
const fp_mod = @import("fiber-profile.zig");
const ebr_mod = @import("../lib/ebr.zig");
const EbrContext = ebr_mod.EbrContext;
const ThreadLocalEbr = ebr_mod.ThreadLocalEbr;
const SlabAllocator = @import("slab-alloc.zig").SlabAllocator;

const Atomic = blk: {
    const root = @import("root");
    break :blk if (@hasDecl(root, "SimAtomic")) root.SimAtomic else std.atomic.Value;
};

fn milliTimestamp() i64 {
    return compat.milliTimestamp();
}

const RunQueue = qs.RunQueue;
const Task = qs.Task;
const TaskStatus = qs.TaskStatus;

const spsc = @import("spsc.zig");
pub const SpscMessage = spsc.Message;
pub const SpscMessageTag = spsc.MessageTag;
const AtomicRingPtr = std.atomic.Value(?*spsc.DefaultRing);
pub const TaskConfig = qs.TaskConfig;
const TaskFn = qs.TaskFn;

const Context = fc.Context;
const switchContext = fc.switchContext;
const Fiber = fc.Fiber;
const Stack = fc.Stack;
const StackSize = fc.StackSize;

const StackPool = fm.StackPool;
const STANDARD_STACK_SIZE = fm.STANDARD_STACK_SIZE;

const cp = @import("control-plane.zig");
const IO_HELPER_STACK_SIZE = 16 * 1024;

/// Thread-local allocator for @arena BG fibers.  Set by the scheduler
/// before switching to a use_arena task; cleared after the task yields.
/// The Runtime reads this in frameAlloc()/heapAlloc() to use the
/// scheduler's thread-local arena instead of the global heap.
pub threadlocal var __pinned_local_alloc: ?std.mem.Allocator = null;

/// Per-thread alternate signal stack. Fibers run on small stacks (4 KB
/// for Micro, 16 KB for Standard) with no pthread guard page; any signal
/// (real SIGSEGV from a bug, SIGBUS, SIGINT, debugger SIGTRAP) whose
/// handler runs on the current stack would push a signal frame onto the
/// fiber stack and overflow into the adjacent slab header. sigaltstack
/// gives signal handlers a dedicated 64 KB buffer instead.
///
/// Handlers must still be installed with SA_ONSTACK to actually use the
/// alternate stack -- this just makes the stack available. Zig's
/// std.debug.attachSegfaultHandler does set SA_ONSTACK, so installing
/// the alt stack is sufficient for the segfault-handler case.
///
/// Public so a test can verify the handler runs in this range.
pub threadlocal var sig_alt_stack: [64 * 1024]u8 align(16) = undefined;
threadlocal var sig_alt_stack_installed: bool = false;

/// Inclusive lower / exclusive upper address bounds of this thread's
/// `sig_alt_stack`. Used by the sigaltstack-test to verify a handler
/// invoked with SA_ONSTACK actually ran on this buffer. Must be called
/// after `ensureSignalAltStack` (so the threadlocal is materialized).
pub fn sigAltStackRange() [2]usize {
    return .{ @intFromPtr(&sig_alt_stack), @intFromPtr(&sig_alt_stack) + sig_alt_stack.len };
}

/// Install `sig_alt_stack` as this thread's alternate signal stack via
/// `sigaltstack(2)`. Idempotent. Called from `Scheduler.run()`.
pub fn ensureSignalAltStack() void {
    if (sig_alt_stack_installed) return;
    if (builtin.os.tag != .linux) return;
    const ss = std.posix.stack_t{
        .sp = &sig_alt_stack,
        .flags = 0,
        .size = sig_alt_stack.len,
    };
    std.posix.sigaltstack(&ss, null) catch {};
    sig_alt_stack_installed = true;
}

const linux = std.os.linux;
const posix = std.posix;
const IoUring = linux.IoUring;

// Comptime io_uring type selection: SimRing in Loom mode, real IoUring otherwise.
// When the root module exports SimRing (vopr-loom.zig), all io_uring submissions
// become yield points for deterministic interleaving.
pub const RingType = blk: {
    const root = @import("root");
    break :blk if (@hasDecl(root, "SimRing")) root.SimRing else IoUring;
};

const FiberNode = struct {
    // The SlabAllocator will overwrite the first 8 bytes for its 'next' pointer.
    // We sacrifice this dummy field so our Fiber data stays safe.
    freelist_link: ?*anyopaque,

    fiber: Fiber,

    // Not needed when we trust our sizing, but kept as a safety check.
    magic: u64,
};

const FIBER_MAGIC: u64 = 0xDEAD_BEEF_CAFE_BABE;

const SpawnRequest = struct {
    user_fn: TaskFn,
    context: ?*anyopaque,
    args: ?*anyopaque,
    config: TaskConfig,
    trampoline_addr: usize,
};

/// Lightweight cross-scheduler RPC.  Caller pushes this into the target
/// scheduler's inbox; the target executes `func(ctx)` inline during
/// drainChannels calls `wg.done()` to resume the caller.
///
/// SAFETY: The remote function must NOT call wg.done() itself.
/// drainChannels captures func/ctx into locals before calling
/// func, so the caller's fiber stack is never touched after wg.done().
pub const RemoteCall = struct {
    func: *const fn (*anyopaque) void,
    ctx: *anyopaque,
    wg: *WaitGroup,
};

pub const RemoteCompletion = struct {
    wg: WaitGroup,
    finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

// A thread-safe wake-up signal
pub const SmartEventFd = struct {
    const WakeEmpty: u32 = 0;
    const WakeParked: u32 = 1;
    const WakeNotified: u32 = 2;

    fd: i32,

    // Parker state for cross-scheduler wake coalescing:
    //   Empty    -- scheduler is awake or no wake token is pending
    //   Parked   -- scheduler is about to block / blocked in io_uring
    //   Notified -- one wake token is pending
    //
    // Producers swap in Notified after enqueueing work. Only the producer
    // that observes Parked writes eventfd; producers that observe Empty or
    // Notified rely on the scheduler's next prepareSleep() consuming the
    // token or on the already-pending eventfd wake.
    state: Atomic(u32) = Atomic(u32).init(WakeEmpty),

    pub fn init() !SmartEventFd {
        // EFD_SEMAPHORE: Reads decrement counter by 1.
        // We use this so we can consume exactly one wake-up if needed.
        const flags = std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK | std.os.linux.EFD.SEMAPHORE;
        const fd = try compat.eventFd(0, flags);
        return SmartEventFd{ .fd = fd };
    }

    pub fn deinit(self: *SmartEventFd) void {
        compat.closeFd(self.fd);
    }

    /// Record a wake token. Returns true only when the target scheduler
    /// was already parked and therefore needs a kernel eventfd write.
    pub fn armNotify(self: *SmartEventFd) bool {
        const old = self.state.swap(WakeNotified, .acq_rel);
        return old == WakeParked;
    }

    // HOT PATH: coalesces wakeups in userspace. Only the Empty -> Notified
    // transition is recorded when the scheduler is awake; only Parked ->
    // Notified performs the eventfd write needed to wake io_uring.
    pub fn notify(self: *SmartEventFd) void {
        if (!self.armNotify()) return;
        self.writeWake();
    }

    fn writeWake(self: *SmartEventFd) void {
        const val: u64 = 1;
        const bytes = std.mem.asBytes(&val);
        _ = std.c.write(self.fd, bytes.ptr, bytes.len);
    }

    /// Cold-path wake used by shutdown/watchdog code. This deliberately
    /// writes eventfd even if the userspace token already says Notified;
    /// that state can be stale relative to io_uring sleep during shutdown.
    pub fn forceNotify(self: *SmartEventFd) void {
        self.state.store(WakeNotified, .release);
        self.writeWake();
    }

    // Called by Scheduler loop to reset the signal drain
    pub fn consume(self: *SmartEventFd) void {
        var val: u64 = 0;
        const buf = std.mem.asBytes(&val);
        // Drain the eventfd buffer
        _ = std.posix.read(self.fd, buf) catch {};
    }

    /// Prepare to block in io_uring. Returns false when a producer already
    /// left a wake token while we were awake; the scheduler must not sleep
    /// and should loop back to drain queues.
    pub fn prepareSleep(self: *SmartEventFd) bool {
        while (true) {
            const old = self.state.load(.acquire);
            switch (old) {
                WakeNotified => {
                    if (self.state.cmpxchgWeak(WakeNotified, WakeEmpty, .acq_rel, .acquire) == null)
                        return false;
                },
                WakeEmpty => {
                    if (self.state.cmpxchgWeak(WakeEmpty, WakeParked, .acq_rel, .acquire) == null)
                        return true;
                },
                WakeParked => return true,
                else => unreachable,
            }
        }
    }

    // Called when the scheduler decides not to sleep after prepareSleep()
    // or immediately after io_uring returns.
    pub fn finishSleep(self: *SmartEventFd) void {
        _ = self.state.swap(WakeEmpty, .acq_rel);
    }
};

const STACK_CACHE_LIMIT: usize = 128;

pub const Scheduler = struct {
    // 1. The Manager State
    fiber_pool: std.ArrayListUnmanaged(*Task) = .empty,
    ready_queue: RunQueue,
    pinned_queue: std.ArrayListUnmanaged(*Task) = .empty,
    // FSM (stackless) tasks — Chase-Lev work-stealing deque, algorithmically
    // identical to the stackful ready_queue above but specialized for
    // *FsmTask. Owner pushes/pops from the bottom; idle siblings steal
    // half from the top. Drained once per main-loop iteration (see run()).
    fsm_ready_queue: FsmRunQueue,
    // Staging list for .Yielded FSM tasks during a single drain. The
    // Chase-Lev deque is LIFO for the owner, so re-pushing a yielded
    // task would have it immediately re-dispatched — one task could
    // monopolize the batch. Instead we collect yielded tasks here and
    // flush them back to the main queue after the batch, guaranteeing
    // FIFO-style progress across all yielders.
    fsm_deferred_queue: std.ArrayListUnmanaged(*FsmTask) = .empty,
    // Stackful-task analog of fsm_deferred_queue. Tasks that yielded
    // cooperatively via coopYield go here (FIFO) instead of back to
    // the LIFO Chase-Lev ready_queue. Without this split, two
    // co-located cooperative fibers starve the older one: writer
    // pushes itself back to ready_queue, scheduler pops bottom and
    // gets writer again, reader at top never runs. (Proven by VOPR
    // test "ready queue starves the older of two co-located
    // cooperative tasks".) Owner-only — never stolen, never crosses
    // threads, no atomics needed. Drained after ready_queue per main-
    // loop iteration so newly spawned / cross-thread-resumed tasks
    // get cache-hot priority but yielded tasks rotate fairly.
    yield_queue: std.ArrayListUnmanaged(*Task) = .empty,
    stack_cache: std.ArrayListUnmanaged([]u8) = .empty, // LIFO Cache for Stacks
    sleeping_queue: std.ArrayListUnmanaged(*Task) = .empty,
    // Fibers parked waiting for a ParkingMutex or ParkingRwLock.
    // Scanned in the run loop's slow path for LOCK_TIMEOUT_MS deadlock detection.
    lock_waiters: std.ArrayListUnmanaged(*Task) = .empty,
    // FSM parallel to lock_waiters. Populated by ParkingMutex.tryLockForFsm
    // on .Registered. Scanned every run() iteration for timeout expiry.
    fsm_lock_waiters: std.ArrayListUnmanaged(*FsmTask) = .empty,
    // FSM parallel to sleeping_queue. Populated by Scheduler.fsmSleepTask
    // before the resume fn yields WaitForLock. The slow-path scan in run()
    // re-enqueues to fsm_ready_queue when fsm_wake_time is reached.
    fsm_sleeping_queue: std.ArrayListUnmanaged(*FsmTask) = .empty,

    // 2. Communication — Pure SPSC (no MPSC linked list)
    /// SPSC channels: lazily allocated, one per potential sender (max 64).
    /// channels[i] is the ring FROM scheduler i TO this scheduler.
    /// Null until first message is sent on that channel (~288 KB per ring).
    /// Messages are value-copied — no linked lists, no pointer reuse.
    channels: [64]AtomicRingPtr = [_]AtomicRingPtr{AtomicRingPtr.init(null)} ** 64,
    /// Bitmask: bit i is set when channel[i] has pending messages.
    dirty_mask: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Re-entrancy guard for drainChannels (prevents RemoteCall → map.put → sendAndWait → drainChannels)
    draining: bool = false,
    stack_pool: StackPool,
    event_fd: SmartEventFd,
    load: std.atomic.Value(isize) = std.atomic.Value(isize).init(0),
    global_shutdown: ?*std.atomic.Value(bool) = null,

    // 3. IO & Memory
    allocator: std.mem.Allocator,
    global_ebr: *EbrContext,
    /// One EBR participant per scheduler OS thread. Tasks borrow this
    /// through Runtime.currentEbr(); they do not allocate EBR slots.
    thread_ebr: *ThreadLocalEbr,
    /// Per-scheduler slab allocator for Task structs. Tasks live in
    /// page-aligned slabs, which (a) lets walkers compute the owning
    /// slab from a *Task via address arithmetic in Phase 3 (cycle-detect
    /// UAF fix), and (b) reuses Task slots within a slab instead of
    /// going through the general allocator on every spawn/finish.
    /// Slab size: 64 KB (power-of-two, ~330 tasks per slab at ~192 B each).
    task_slab: SlabAllocator(Task),
    /// Per-scheduler slab allocator for FsmTask structs. Mirrors
    /// task_slab but for stackless FSM tasks. The slab gives
    /// detectCycleFsm the same Option-(C) UAF guard the stackful
    /// detectCycle relies on: chain walkers `pinFsmTask` to hold a
    /// refcount on the slab, then check `task.generation` to detect
    /// slot reuse. Without the slab, FsmTasks were heap-allocated
    /// inside user ctx structs and could be freed mid-walk.
    /// Slab size: 64 KB (power-of-two, ≈800 FsmTasks per slab at
    /// ~80 B each).
    fsm_task_slab: SlabAllocator(fsm_mod.FsmTask),
    /// Per-scheduler slabs for generated FSM context payloads. The
    /// compiler/runtime route <=64 B, <=128 B, and <=256 B contexts here; larger
    /// contexts stay explicit heap until @fsm:heap / @stack policy is
    /// fully surfaced in the language.
    fsm_ctx_64_slab: SlabAllocator(FsmCtx64),
    fsm_ctx_128_slab: SlabAllocator(FsmCtx128),
    fsm_ctx_256_slab: SlabAllocator(FsmCtx256),

    // 4a. io_uring — unified I/O ring for poll-based socket I/O, async file
    // I/O, and eventfd wakeups. In Loom mode, this is SimRing.
    ring: RingType,
    ring_dirty: bool = false,
    uring_cqes: [128]linux.io_uring_cqe = undefined,
    // Dedicated stack for non-yielding io_uring calls made from run().
    // This keeps helper frames off the scheduler's suspended switch slot.
    io_helper_stack: []u8,

    // 4. Main Thread Context (To return to OS)
    main_ctx: Context,
    current_task: ?*Task,

    // True while drainFsmQueue is dispatching an FSM resumeFn inline on
    // the worker stack. checkYield()/coopYield() inspect this so they
    // do NOT perform a stackful context switch (current_task points at
    // a different stackful task than the FSM body that's actually
    // executing -- yielding here would corrupt the wrong stack). FSM
    // tasks suspend cooperatively by returning .Yielded from resumeFn,
    // not via coopYield, so this is a clean no-op for the FSM caller.
    in_fsm_dispatch: bool = false,

    // -------------------------------------------------------------------------
    // PERFORMANCE NOTE: ATOMIC SCALABILITY & CACHE LINE SAFETY
    // -------------------------------------------------------------------------
    // We use an atomic here to track active tasks across threads. This allows
    // accurate accounting even when tasks are stolen by other threads.
    //
    // Q: Does this cause Cache-Line Bouncing / False Sharing?
    // A: NO, provided Schedulers are not packed tightly in memory.
    //
    // 1. Thread-Local Access: In 99% of cases (no stealing), this atomic is
    //    only modified by the owning thread. It stays in the L1 cache (Modified state)
    //    and executes in ~1ns with zero bus traffic.
    //
    // 2. Stealing (The Victim): When a thief steals, they issue an atomic SUB.
    //    This forces a cache invalidation for the Victim. This is the intended cost
    //    of work stealing. It only happens when a thread is idle.
    //
    // 3. False Sharing: If two Schedulers shared a 64-byte cache line, modifying
    //    Scheduler A would invalidate Scheduler B. We avoid this because Schedulers
    //    are typically allocated on the Thread Stack (MBs apart) or individually
    //    heap-allocated (likely padded by allocator metadata).
    //
    //    If you allocate an array of Schedulers (e.g. `[]Scheduler`), you MUST
    //    ensure `align(64)` padding between them to preserve scalability.
    // -------------------------------------------------------------------------
    active_tasks: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    shutdown_on_idle: bool = true,
    fast_path_counter: u32 = 0,
    // Configurable lock timeout. 30s in production (ReleaseFast/Safe) so
    // long-running legitimate waits don't spuriously time out; 100ms in
    // Debug builds so WITH ... ON <selector> clauses are actually
    // exercised by tests under contention.
    // Default lock-acquire timeout (per-WAIT, not per-program). Debug
    // mode used to be 100ms to surface hangs quickly during development,
    // but high-concurrency benchmarks (14_nested_lock at THREADS=$(nproc))
    // genuinely sat on contended mutexes longer than 100ms and would
    // false-fail. With the Phase 1-6 cycle-detection rework — slab
    // pin, generation, atomic per-hop lock-state snapshot, atomic
    // wait-field protocol — false-positive timeouts no longer occur,
    // so the original 100ms can be restored. 100ms is what the
    // transpile-test 263_with_lock_contention.clear and other timeout
    // tests assume; bumping it broke them silently.
    lock_timeout_ms: i64 = if (builtin.mode == .Debug) 100 else 30_000,

    /// Stable index assigned at registration (0..N-1).  Used by
    /// PartitionedStringMap to determine shard ownership.
    index: u32 = 0,

    // Thread-local arena for @arena BG fibers only (use_arena: true).
    // Backed by the scheduler's allocator (c_allocator in production, GPA in debug).
    // Not used by default — only when the CLEAR programmer opts in with @arena.
    local_arena: std.heap.ArenaAllocator,

    pub const FsmCtx64 = extern struct { bytes: [64]u8 };
    pub const FsmCtx128 = extern struct { bytes: [128]u8 };
    pub const FsmCtx256 = extern struct { bytes: [256]u8 };

    pub fn init(allocator: std.mem.Allocator, global_ebr: *EbrContext, unused_shared_stack_pool: anytype) !Scheduler {
        _ = unused_shared_stack_pool;
        const efd = try SmartEventFd.init();

        // io_uring ring for all I/O: poll-based socket I/O, async file reads,
        // and eventfd wakeups. 256 SQE slots.
        // In Loom mode, this is SimRing (no real syscalls).
        var ring = try RingType.init(256, 0);

        // Register the eventfd with the ring using multishot POLL_ADD.
        // Multishot means each eventfd write produces a new CQE without
        // re-submitting. user_data = EVENTFD_SENTINEL (0).
        if (RingType != @import("vopr-ring.zig").SimRing) {
            const sqe = try ring.poll_add(EVENTFD_SENTINEL, efd.fd, linux.POLL.IN);
            // Set POLL_ADD_MULTI so this poll persists across multiple fires.
            sqe.len = linux.IORING_POLL_ADD_MULTI;
            _ = try ring.submit();
        }

        const thread_ebr = try allocator.create(ThreadLocalEbr);
        errdefer allocator.destroy(thread_ebr);
        thread_ebr.* = .{ .context = global_ebr };
        try global_ebr.register(allocator, thread_ebr);
        errdefer global_ebr.unregister(thread_ebr);

        const sched = Scheduler{
            .stack_pool = StackPool.init(allocator),
            .fiber_pool = .empty,
            .ready_queue = try RunQueue.initWithAllocator(allocator),
            .fsm_ready_queue = try FsmRunQueue.initWithAllocator(allocator),
            .fsm_lock_waiters = .empty,
            .fsm_sleeping_queue = .empty,
            .stack_cache = .empty,
            .sleeping_queue = .empty,
            .event_fd = efd,
            .load = std.atomic.Value(isize).init(0),
            .allocator = allocator,
            .global_ebr = global_ebr,
            .thread_ebr = thread_ebr,
            // Power-of-two slab size required by SlabAllocator; 64 KB hits
            // the sweet spot for current Task footprint (~192 B incl.
            // cache-line padding) — ≈330 tasks per slab.
            .task_slab = SlabAllocator(Task).init(allocator, 64 * 1024),
            .fsm_task_slab = SlabAllocator(fsm_mod.FsmTask).init(allocator, 64 * 1024),
            .fsm_ctx_64_slab = SlabAllocator(FsmCtx64).init(allocator, 64 * 1024),
            .fsm_ctx_128_slab = SlabAllocator(FsmCtx128).init(allocator, 64 * 1024),
            .fsm_ctx_256_slab = SlabAllocator(FsmCtx256).init(allocator, 64 * 1024),
            .ring = ring,
            .io_helper_stack = try allocator.alloc(u8, IO_HELPER_STACK_SIZE),
            .main_ctx = undefined,
            .current_task = null,
            .active_tasks = std.atomic.Value(usize).init(0),
            .shutdown_on_idle = true,
            // local_arena is only used for @arena BG fibers (use_arena: true).
            // Backed by the scheduler's allocator: c_allocator in production
            // (per-thread arenas, no lock contention), GPA in debug (leak detection).
            .local_arena = std.heap.ArenaAllocator.init(allocator),
        };

        return sched;
    }

    pub fn deinit(self: *Scheduler) void {
        self.lock_waiters.deinit(self.allocator);
        self.fsm_lock_waiters.deinit(self.allocator);
        self.fsm_sleeping_queue.deinit(self.allocator);
        const queues = .{ &self.fiber_pool, &self.sleeping_queue };
        inline for (queues) |q| {
            for (q.items) |task| {
                self.releaseTaskEbr(task);
                if (task.base.stack.memory.len > 0) {
                    self.freeStack(task.base.stack);
                }
                self.destroyFiber(task.base); // Free Fiber
                self.task_slab.destroy(task); // Free Task Struct
            }
            q.deinit(self.allocator);
        }

        // Drain any remaining SPSC messages
        self.drainChannels();

        // Ownership: We must return all cached stacks to the pool
        while (self.stack_cache.items.len > 0) {
            const stack = self.stack_cache.pop().?;
            self.stack_pool.free(stack);
        }

        // Ownership Split: RunQueue manages the backing array (the pointers),
        // but Scheduler (me) owns the Task structs (the memory).
        // We must destroy the Tasks before destroying the container.
        // Otherwise we lose the keys to the memory, before we free the memory.
        const b = self.ready_queue.bottom.load(.monotonic);
        const t = self.ready_queue.top.load(.monotonic);

        // Iterate valid range
        var i = t;
        while (i < b) : (i += 1) {
            // Access raw slot directly
            const task_opt = self.ready_queue.getBuffer()[i & self.ready_queue.getMask()].load(.monotonic);
            if (task_opt) |task| {
                self.releaseTaskEbr(task);
                self.freeStack(task.base.stack);
                self.destroyFiber(task.base);
                self.task_slab.destroy(task);
            }
        }
        self.ready_queue.deinit();
        for (self.pinned_queue.items) |task| {
            self.releaseTaskEbr(task);
            self.freeStack(task.base.stack);
            self.destroyFiber(task.base);
            self.task_slab.destroy(task);
        }
        self.pinned_queue.deinit(self.allocator);
        // Free any cooperatively-yielded stackful tasks that never got
        // popped before shutdown. Same destroy path as pinned_queue.
        for (self.yield_queue.items) |task| {
            self.releaseTaskEbr(task);
            self.freeStack(task.base.stack);
            self.destroyFiber(task.base);
            self.task_slab.destroy(task);
        }
        self.yield_queue.deinit(self.allocator);
        // FSM tasks have caller-owned state structs. We do not free them
        // here — just release the queue storage. Any unfinished FSM is the
        // caller's responsibility.
        self.fsm_ready_queue.deinit();
        self.fsm_deferred_queue.deinit(self.allocator);

        self.drainChannels();
        self.stack_pool.flushLocalCache();
        self.stack_pool.deinit();
        self.stack_cache.deinit(self.allocator);
        for (&self.channels) |*ch| {
            if (ch.load(.acquire)) |ring| self.allocator.destroy(ring);
        }
        self.local_arena.deinit();
        self.allocator.free(self.io_helper_stack);
        self.ring.deinit();
        // Tear down the Task slab last; everything above that destroys
        // Tasks (`self.task_slab.destroy(task)`) just returns the slot to
        // the slab's free list — the underlying slab pages live until
        // here. Deinit walks the partial / full slab lists and frees
        // their memory back to the general allocator.
        self.task_slab.deinit();
        self.fsm_task_slab.deinit();
        self.fsm_ctx_64_slab.deinit();
        self.fsm_ctx_128_slab.deinit();
        self.fsm_ctx_256_slab.deinit();
        self.global_ebr.unregister(self.thread_ebr);
        self.thread_ebr.deinit(self.allocator);
        self.allocator.destroy(self.thread_ebr);
    }

    /// Compatibility hook for test runners with custom .Finished handling.
    /// Tasks no longer own EBR slots; the scheduler thread owns one slot.
    pub fn releaseTaskEbr(self: *Scheduler, task: *Task) void {
        _ = self;
        _ = task;
    }

    /// Release the per-FSM Runtime shell before destroy_fn frees the ctx.
    pub fn releaseFsmTaskEbr(self: *Scheduler, task: *fsm_mod.FsmTask) void {
        if (task.task_runtime) |rt_ptr| {
            rt_ptr.deinit();
            self.allocator.destroy(rt_ptr);
            task.task_runtime = null;
        }
    }

    /// Allocate a fresh FsmTask from `fsm_task_slab`, bump its
    /// generation, and initialize it. The slab gives detectCycleFsm
    /// its UAF-safe pin protocol (mirrors stackful Task slab).
    /// Generation bump happens after field reset: capture the previous
    /// generation, reinitialize the slot, then store +1 with .release.
    /// Cross-scheduler scanners can retain stale waiter-list pointers briefly,
    /// so reset the atomic waiter/back-pointer fields with atomic stores rather
    /// than a bulk struct assignment. Any chain walker holding a stale
    /// `(*FsmTask, generation)` pair from the previous slot occupant observes
    /// the mismatch and aborts safely.
    pub fn allocFsmTask(self: *Scheduler, resume_fn: fsm_mod.ResumeFn) !*fsm_mod.FsmTask {
        const t = try self.fsm_task_slab.create();
        const prev_gen = t.generation.load(.monotonic);
        t.resume_fn = resume_fn;
        t.status = .Ready;
        t.spawn_ns = 0;
        t.ctx = null;
        t.seq.store(0, .release);
        t.waiter = null;
        t.lock_waiter.store(null, .release);
        t.waiting_for_lock_list.store(null, .release);
        t.lock_error = .None;
        t.waiting_for_lock.store(null, .release);
        t.waiting_for_fsm_owner.store(null, .release);
        t.lock_wait_start_ms.store(0, .release);
        t.fsm_wake_time = 0;
        t.destroy_fn = null;
        t.task_runtime = null;
        t.generation.store(prev_gen +% 1, .release);
        t.owner_scheduler = self;
        return t;
    }

    pub fn allocFsmCtx(self: *Scheduler, comptime T: type, task: *fsm_mod.FsmTask) !*T {
        const size = @sizeOf(T);
        const alignment = @alignOf(T);
        const ptr = if (comptime size <= 64 and alignment <= 16) blk: {
            const slot = try self.fsm_ctx_64_slab.create();
            task.ctx_alloc_class = .slab64;
            break :blk @as(*T, @ptrCast(@alignCast(slot)));
        } else if (comptime size <= 128 and alignment <= 16) blk: {
            const slot = try self.fsm_ctx_128_slab.create();
            task.ctx_alloc_class = .slab128;
            break :blk @as(*T, @ptrCast(@alignCast(slot)));
        } else if (comptime size <= 256 and alignment <= 16) blk: {
            const slot = try self.fsm_ctx_256_slab.create();
            task.ctx_alloc_class = .slab256;
            break :blk @as(*T, @ptrCast(@alignCast(slot)));
        } else blk: {
            const heap_ptr = try self.allocator.create(T);
            task.ctx_alloc_class = .heap;
            break :blk heap_ptr;
        };
        task.owner_scheduler = self;
        return ptr;
    }

    pub fn freeFsmCtx(self: *Scheduler, comptime T: type, task: *fsm_mod.FsmTask, ctx: *T) void {
        const class = task.ctx_alloc_class;
        const owner: *Scheduler = if (task.owner_scheduler) |raw|
            @ptrCast(@alignCast(raw))
        else
            self;

        if (owner != self and (class == .slab64 or class == .slab128 or class == .slab256)) {
            self.submitRemoteFsmCtxFree(owner, class, @intFromPtr(ctx));
            task.ctx_alloc_class = .none;
            task.ctx = null;
            return;
        }

        switch (class) {
            .none => {},
            .slab64 => self.fsm_ctx_64_slab.destroy(@as(*FsmCtx64, @ptrCast(@alignCast(ctx)))),
            .slab128 => self.fsm_ctx_128_slab.destroy(@as(*FsmCtx128, @ptrCast(@alignCast(ctx)))),
            .slab256 => self.fsm_ctx_256_slab.destroy(@as(*FsmCtx256, @ptrCast(@alignCast(ctx)))),
            .heap => owner.allocator.destroy(ctx),
        }
        task.ctx_alloc_class = .none;
        task.ctx = null;
    }

    fn submitRemoteFsmCtxFree(
        self: *Scheduler,
        owner: *Scheduler,
        class: fsm_mod.FsmCtxAllocClass,
        ptr: usize,
    ) void {
        const sender_idx = if (scheduler_running) active_scheduler.index else self.index;
        std.debug.assert(sender_idx < owner.channels.len);
        const ring = owner.ensureChannel(sender_idx) catch {
            @panic("failed to allocate remote FSM ctx-free channel");
        };
        const msg = SpscMessage{
            .tag = .RemoteFsmCtxFree,
            .fsm_ctx_ptr = ptr,
            .fsm_ctx_class = @intFromEnum(class),
        };
        // HAMMER-WAIT-LOOP-BEGIN: tag=spsc-submit-fsm-ctx-free
        // What stalls: the owning scheduler's inbound ring is full and
        // it is not draining fast enough — typically because the owner
        // is itself blocked in a different wait-loop or running a long
        // user task without yielding.
        // Yield contract: drain our own inbound channels (we may be
        // holding work that, once dispatched, frees the owner) then
        // unconditionally yield the OS thread.
        while (!ring.push(msg)) {
            if (scheduler_running) {
                active_scheduler.drainChannels();
            }
            std.Thread.yield() catch {};
        }
        // HAMMER-WAIT-LOOP-END: tag=spsc-submit-fsm-ctx-free
        const bit = @as(u64, 1) << @intCast(sender_idx);
        const old_dirty = owner.dirty_mask.fetchOr(bit, .release);
        if ((old_dirty & bit) == 0) owner.event_fd.notify();
    }

    // ------------------------------------------------------------
    // Memory Management
    // ------------------------------------------------------------
    // HOT PATH: Allocating a stack.
    // The L1 cache (stack_cache) holds only Standard-sized stacks.
    // Non-standard sizes bypass the cache and go directly to the pool slab.
    pub fn allocStack(self: *Scheduler, size: StackSize) ![]u8 {
        if (size == .Standard and self.stack_cache.items.len > 0) {
            return self.stack_cache.pop().?;
        }
        return self.stack_pool.alloc(size);
    }

    // HOT PATH: Freeing a stack.
    // Standard-sized stacks are kept in the L1 cache for fast reuse.
    // All other sizes are returned directly to the pool slab.
    fn freeLocalStackMemory(self: *Scheduler, stack: []u8) void {
        if (fm.debug_stack_origins) fm.forgetStackOrigin(@intFromPtr(stack.ptr));
        if (stack.len == STANDARD_STACK_SIZE and self.stack_cache.items.len < STACK_CACHE_LIMIT) {
            self.stack_cache.append(self.allocator, stack) catch {
                self.stack_pool.free(stack);
            };
        } else {
            self.stack_pool.free(stack);
        }
    }

    pub fn freeStack(self: *Scheduler, stack: Stack) void {
        const owner = if (stack.owner) |raw|
            @as(*Scheduler, @ptrCast(@alignCast(raw)))
        else
            self;
        if (owner == self) {
            self.freeLocalStackMemory(stack.memory);
            return;
        }
        self.submitRemoteStackFree(owner, stack.memory);
    }

    fn destroyFiber(self: *Scheduler, fiber: *Fiber) void {
        fiber.deinit();
        self.allocator.destroy(fiber);
    }

    fn submitRemoteStackFree(self: *Scheduler, owner: *Scheduler, memory: []u8) void {
        const sender_idx = if (scheduler_running) active_scheduler.index else self.index;
        std.debug.assert(sender_idx < owner.channels.len);
        const ring = owner.ensureChannel(sender_idx) catch {
            @panic("failed to allocate remote stack-free channel");
        };
        const msg = SpscMessage{
            .tag = .RemoteStackFree,
            .stack_ptr = @intFromPtr(memory.ptr),
            .stack_len = memory.len,
        };
        // HAMMER-WAIT-LOOP-BEGIN: tag=spsc-submit-stack-free
        // What stalls: the owning scheduler's inbound ring is full.
        // Stack-free messages are unbounded (one per fiber finalize),
        // so a slow owner can backlog stack returns from a fast worker
        // pool that's tearing down many fibers.
        // Yield contract: drain our own inbound channels then
        // unconditionally yield the OS thread to let the owner drain.
        while (!ring.push(msg)) {
            if (scheduler_running) {
                active_scheduler.drainChannels();
            }
            std.Thread.yield() catch {};
        }
        // HAMMER-WAIT-LOOP-END: tag=spsc-submit-stack-free
        const bit = @as(u64, 1) << @intCast(sender_idx);
        const old_dirty = owner.dirty_mask.fetchOr(bit, .release);
        if ((old_dirty & bit) == 0) owner.event_fd.notify();
    }

    // IDLE PATH: Scavenge memory (The Cleanup)
    fn scavengeMemory(self: *Scheduler, draining: bool) void {
        // 1. Drain L1 Cache (Scheduler ArrayList) -> L2 Cache (Slab Magazine)
        // We keep a small buffer (e.g. 4) just in case we wake up immediately.
        const WARM_CACHE_SIZE: usize = if (draining) 0 else 4;

        while (self.stack_cache.items.len > WARM_CACHE_SIZE) {
            const stack = self.stack_cache.pop().?;
            self.stack_pool.free(stack);
        }

        // 2. Flush L2 Cache (Magazine) -> L3 Depot (Global Slabs)
        // If a slab becomes completely empty during this flush,
        // SlabAllocator will free the backing memory to the OS/Allocator.
        self.stack_pool.flushLocalCache();
    }

    // ------------------------------------------------------------
    // Channel Management — lazy allocation
    // ------------------------------------------------------------

    /// Lazily allocate an SPSC ring for the given sender index.
    /// Called on the producer side (first message to this channel).
    pub fn ensureChannel(self: *Scheduler, idx: usize) !*spsc.DefaultRing {
        if (self.channels[idx].load(.acquire)) |ring| return ring;
        const ring = try self.allocator.create(spsc.DefaultRing);
        errdefer self.allocator.destroy(ring);
        ring.* = .{};
        if (self.channels[idx].cmpxchgStrong(null, ring, .release, .acquire)) |existing| {
            return existing.?;
        }
        return ring;
    }

    // ------------------------------------------------------------
    // 1. THE SPAWN (Producer Side - Thread A)
    // ------------------------------------------------------------
    pub fn submitSpawn(self: *Scheduler, trampoline_addr: usize, user_fn: TaskFn, args: ?*anyopaque, config: TaskConfig) !void {
        const sender_idx = if (scheduler_running) active_scheduler.index else 0;
        std.debug.assert(sender_idx < self.channels.len);
        const ring = try self.ensureChannel(sender_idx);
        const msg = SpscMessage{
            .tag = .Spawn,
            .trampoline_addr = trampoline_addr,
            .user_fn = user_fn,
            .args = args,
            .config_stack_size = @intFromEnum(config.stack_size),
            .config_pinned = config.pinned,
            .config_timeout_ms = config.timeout_ms,
            .config_profile_site_id = config.profile_site_id,
            .config_profile_dispatch = config.profile_dispatch,
        };
        // HAMMER-WAIT-LOOP-BEGIN: tag=spsc-submit-spawn
        // What stalls: cross-scheduler SPSC ring is full because the
        // destination scheduler is slow to drain (typically a busy
        // worker spawning faster than the target can dispatch).
        // Yield contract: must always fall through to std.Thread.yield
        // — coopYield is a no-op when no local work exists, which
        // would otherwise produce a tight CPU spin under TSan.
        // Wait-and-work: if ring is full, drain our own channels + yield
        while (!ring.push(msg)) {
            if (scheduler_running) {
                active_scheduler.drainChannels();
                active_scheduler.coopYield();
            }
            // Fall through to std.Thread.yield even on the scheduler
            // path: coopYield is a no-op when there's no local work to
            // dispatch to, leaving the loop tight-spinning on a full
            // SPSC ring. Yielding the OS thread gives the destination
            // scheduler CPU to drain its inbound ring. Critical under
            // TSan, where tight loops cost 50-100x release because
            // every atomic is intercepted.
            std.Thread.yield() catch {};
        }
        // HAMMER-WAIT-LOOP-END: tag=spsc-submit-spawn
        const bit = @as(u64, 1) << @intCast(sender_idx);
        const old_dirty = self.dirty_mask.fetchOr(bit, .release);
        if ((old_dirty & bit) == 0) self.event_fd.notify();
    }

    // ------------------------------------------------------------
    // 1b. FSM SPAWN (cross-scheduler)
    // ------------------------------------------------------------
    /// Submit a pre-initialized FsmTask to this scheduler's FSM queue
    /// via SPSC. Fast path enqueues directly when the caller is running
    /// on the same scheduler; cross-thread callers go through the ring.
    /// Caller owns the state struct that embeds the FsmTask; the task
    /// pointer must outlive the scheduler run.
    pub fn submitFsmSpawn(self: *Scheduler, fsm_task: *FsmTask) !void {
        // Fast path: same scheduler — avoid the ring + eventfd roundtrip.
        if (scheduler_running and self == active_scheduler) {
            self.enqueueFsm(fsm_task);
            return;
        }

        const sender_idx = if (scheduler_running) active_scheduler.index else 0;
        std.debug.assert(sender_idx < self.channels.len);
        const ring = try self.ensureChannel(sender_idx);
        const msg = SpscMessage{
            .tag = .FsmSpawn,
            .fsm_task = fsm_task,
        };
        // HAMMER-WAIT-LOOP-BEGIN: tag=spsc-submit-fsm-spawn
        // What stalls: cross-scheduler SPSC ring is full while
        // submitting an FSM (stackless) task. Pattern is the same as
        // spsc-submit-spawn but for FSM tasks — common when an FSM
        // pipeline is producing children faster than downstream stage
        // can consume.
        // Yield contract: same as spsc-submit-spawn — always fall
        // through to std.Thread.yield after the optional coopYield.
        while (!ring.push(msg)) {
            if (scheduler_running) {
                active_scheduler.drainChannels();
                active_scheduler.coopYield();
            }
            // Fall through to std.Thread.yield even on the scheduler
            // path: coopYield is a no-op when there's no local work to
            // dispatch to, leaving the loop tight-spinning on a full
            // SPSC ring. Yielding the OS thread gives the destination
            // scheduler CPU to drain its inbound ring. Critical under
            // TSan, where tight loops cost 50-100x release because
            // every atomic is intercepted.
            std.Thread.yield() catch {};
        }
        // HAMMER-WAIT-LOOP-END: tag=spsc-submit-fsm-spawn
        const bit = @as(u64, 1) << @intCast(sender_idx);
        const old_dirty = self.dirty_mask.fetchOr(bit, .release);
        if ((old_dirty & bit) == 0) self.event_fd.notify();
    }

    /// Wake a previously-parked FSM task. Same routing as submitFsmSpawn
    /// (same-scheduler fast path, SPSC slow path) but tagged as
    /// FsmResume so drainChannels does NOT increment active_tasks (the
    /// task was counted when originally enqueued). Called by parking-lot
    /// unlock when the waker is an FSM.
    pub fn submitFsmResume(self: *Scheduler, fsm_task: *FsmTask) !void {
        if (scheduler_running and self == active_scheduler) {
            // Same-scheduler fast path: bypass active_tasks increment
            // by pushing directly. enqueueFsm would double-count.
            fsm_task.status = .Ready;
            self.fsm_ready_queue.push(self.allocator, fsm_task) catch unreachable;
            return;
        }
        const sender_idx = if (scheduler_running) active_scheduler.index else 0;
        std.debug.assert(sender_idx < self.channels.len);
        const ring = try self.ensureChannel(sender_idx);
        const msg = SpscMessage{
            .tag = .FsmResume,
            .fsm_task = fsm_task,
        };
        // HAMMER-WAIT-LOOP-BEGIN: tag=spsc-submit-fsm-resume
        // What stalls: cross-scheduler SPSC ring is full while waking
        // a previously-parked FSM. Called by parking-lot unlock when
        // the waker is an FSM on a different scheduler. Liveness
        // critical — this is on the wakeup path of a lock release.
        // Yield contract: same as spsc-submit-spawn — always fall
        // through to std.Thread.yield after the optional coopYield.
        while (!ring.push(msg)) {
            if (scheduler_running) {
                active_scheduler.drainChannels();
                active_scheduler.coopYield();
            }
            // Fall through to std.Thread.yield even on the scheduler
            // path: coopYield is a no-op when there's no local work to
            // dispatch to, leaving the loop tight-spinning on a full
            // SPSC ring. Yielding the OS thread gives the destination
            // scheduler CPU to drain its inbound ring. Critical under
            // TSan, where tight loops cost 50-100x release because
            // every atomic is intercepted.
            std.Thread.yield() catch {};
        }
        // HAMMER-WAIT-LOOP-END: tag=spsc-submit-fsm-resume
        const bit = @as(u64, 1) << @intCast(sender_idx);
        const old_dirty = self.dirty_mask.fetchOr(bit, .release);
        if ((old_dirty & bit) == 0) self.event_fd.notify();
    }

    // ------------------------------------------------------------
    // 2. THE RESUME (Producer Side - Thread B, WaitGroup, etc)
    // ------------------------------------------------------------
    pub fn submitResume(self: *Scheduler, task: *Task) void {
        // CAS-claim the inbox slot. Three outcomes:
        //   IDLE       -> IN_QUEUE  : we own the right to push
        //   IN_QUEUE   (already)    : a concurrent submitResume already
        //                             pushed; double-push guard
        //   DESTROYING (already)    : run()'s .Finished branch claimed
        //                             the slot; the task is being
        //                             destroyed and we MUST NOT push
        //                             (closes the use-after-free race
        //                             surfaced by the SplitStream
        //                             pubsub hammer).
        if (task.in_inbox.cmpxchgStrong(qs.IN_INBOX_IDLE, qs.IN_INBOX_IN_QUEUE, .acq_rel, .acquire) != null) return;

        // Fast path: if resuming on the SAME scheduler we're running on,
        // push directly to the ready queue.  Skips the SPSC ring, the
        // dirty_mask atomic OR, and the eventfd syscall.
        // NOTE: in_inbox stays true until the scheduler dequeues the task
        // in run(). This prevents a cross-thread submitResume from pushing
        // a duplicate through the SPSC ring while the task sits in the
        // ready queue.
        if (scheduler_running and self == active_scheduler) {
            task.status.store(.Ready, .release);
            self.enqueueTask(task);
            return;
        }

        const sender_idx = if (scheduler_running) active_scheduler.index else 0;
        std.debug.assert(sender_idx < self.channels.len);
        const ring = self.ensureChannel(sender_idx) catch return;
        const msg = SpscMessage{
            .tag = .Resume,
            .task = @ptrCast(task),
        };
        // HAMMER-WAIT-LOOP-BEGIN: tag=spsc-submit-resume
        // What stalls: cross-scheduler SPSC ring is full because the
        // destination scheduler is slow to drainChannels (e.g. heavy
        // TSan instrumentation, or no other ready work locally).
        // Yield contract: the loop must always fall through to
        // std.Thread.yield, even on the scheduler-running branch —
        // coopYield is a no-op when no local work exists, which would
        // otherwise produce a tight CPU spin under TSan.
        // Wait-and-work
        while (!ring.push(msg)) {
            if (scheduler_running) {
                active_scheduler.drainChannels();
                active_scheduler.coopYield();
            }
            // Fall through to std.Thread.yield even on the scheduler
            // path: coopYield is a no-op when there's no local work to
            // dispatch to, leaving the loop tight-spinning on a full
            // SPSC ring. Yielding the OS thread gives the destination
            // scheduler CPU to drain its inbound ring. Critical under
            // TSan, where tight loops cost 50-100x release because
            // every atomic is intercepted.
            std.Thread.yield() catch {};
        }
        // HAMMER-WAIT-LOOP-END: tag=spsc-submit-resume
        const bit = @as(u64, 1) << @intCast(sender_idx);
        const old_dirty = self.dirty_mask.fetchOr(bit, .release);
        if ((old_dirty & bit) == 0) self.event_fd.notify();
    }
    /// Lightweight: only process RemoteCall messages. Spawn and Resume are
    /// left in the ring for the full drainChannels to handle. Safe to call
    /// from a fiber's stack — RemoteCall handlers use <1KB of stack.
    /// Lightweight: only process RemoteCall messages from SPSC channels.
    /// Uses peek() to avoid consuming Spawn/Resume messages.
    /// Safe to call from a fiber — RemoteCall handlers use <1KB stack.
    pub fn drainRemoteCalls(self: *Scheduler) void {
        const mask = self.dirty_mask.load(.acquire);
        if (mask == 0) return;
        var bits = mask;
        while (bits != 0) {
            const sender_idx = @ctz(bits);
            bits &= bits - 1;
            const ch = self.channels[sender_idx].load(.acquire) orelse continue;
            while (true) {
                const peeked = ch.peek() orelse break;
                if (peeked.tag != .RemoteCall) break; // leave for main loop
                // It's a RemoteCall — pop and execute
                _ = ch.pop();
                const func = peeked.rc_func.?;
                const ctx = peeked.rc_ctx.?;
                const completion = peeked.rc_wg;
                func(ctx);
                if (completion) |completion_ptr| {
                    const typed: *RemoteCompletion = @ptrCast(@alignCast(completion_ptr));
                    // Order matters: write `finished` BEFORE `wg.done()`. Once
                    // done() returns, the waiter may already have been woken
                    // and freed *typed — touching it would be UAF.
                    typed.finished.store(true, .release);
                    typed.wg.done();
                }
            }
        }
    }

    /// Full drain: processes ALL message types (Spawn, Resume, RemoteCall).
    /// Must run on the scheduler's main stack (not from a fiber).
    pub noinline fn drainChannels(self: *Scheduler) void {
        var mask = self.dirty_mask.swap(0, .acquire);
        while (mask != 0) {
            const sender_idx = @ctz(mask);
            mask &= mask - 1;
            const ch = self.channels[sender_idx].load(.acquire) orelse continue;
            while (ch.pop()) |msg| {
                switch (msg.tag) {
                    .Spawn => {
                        const config = TaskConfig{
                            .stack_size = @enumFromInt(msg.config_stack_size),
                            .pinned = msg.config_pinned,
                            .timeout_ms = msg.config_timeout_ms,
                            .profile_site_id = msg.config_profile_site_id,
                            .profile_dispatch = msg.config_profile_dispatch,
                        };
                        const effective_size = cp.recommendSize(
                            if (msg.user_fn) |f| @intFromPtr(f) else 0,
                            config.stack_size,
                        );
                        const stack_mem = self.allocStack(effective_size) catch continue;
                        if (fm.debug_stack_origins) fm.recordStackOrigin(@intFromPtr(stack_mem.ptr), .{
                            .user_fn = if (msg.user_fn) |f| @intFromPtr(f) else 0,
                            .return_addr = @returnAddress(),
                            .size_class = effective_size,
                            .owner_index = @intCast(self.index),
                        });
                        const task = blk: {
                            const fiber_ptr = self.allocator.create(Fiber) catch {
                                self.freeLocalStackMemory(stack_mem);
                                continue;
                            };
                            fiber_ptr.* = Fiber.initWithOwner(stack_mem, msg.trampoline_addr, effective_size, self);
                            const t = self.task_slab.create() catch {
                                self.freeLocalStackMemory(stack_mem);
                                self.allocator.destroy(fiber_ptr);
                                continue;
                            };
                            // Slab returns memory potentially recycled from a
                            // freed Task in the same slot. The previous
                            // occupant's `generation` is still in memory; we
                            // capture and bump it so that any external chain
                            // walker holding a stale `(*Task, generation)`
                            // pair from the previous occupant detects the
                            // mismatch and aborts the walk safely.
                            //
                            // .release on the bump pairs with .acquire reads
                            // by chain walkers (detectCycle), so any write
                            // to the new Task (including its lock-state
                            // observability through subsequent ParkingMutex
                            // CAS into lock.state) happens-after the bump.
                            const prev_gen = t.generation.load(.monotonic);
                            t.* = Task{ .base = fiber_ptr, .user_fn = msg.user_fn.? };
                            t.generation.store(prev_gen +% 1, .release);
                            if (rt_profile.CLEAR_PROFILE) {
                                t.spawn_ns = fp_mod.nowNs();
                                t.profile_site_id = config.profile_site_id;
                                fp_mod.recordSiteSpawn(
                                    config.profile_site_id,
                                    @as(fp_mod.DispatchKind, @enumFromInt(config.profile_dispatch)),
                                    .stack,
                                );
                            }
                            break :blk t;
                        };
                        task.context = msg.args;
                        task.status.store(.Ready, .release);
                        task.config = config;
                        if (task.config.pinned) {
                            self.pinned_queue.append(self.allocator, task) catch {
                                self.freeLocalStackMemory(stack_mem);
                                self.destroyFiber(task.base);
                                self.task_slab.destroy(task);
                                continue;
                            };
                        } else {
                            self.ready_queue.push(self.allocator, task) catch {
                                self.freeLocalStackMemory(stack_mem);
                                self.fiber_pool.append(self.allocator, task) catch
                                    {
                                        self.destroyFiber(task.base);
                                        self.task_slab.destroy(task);
                                    };
                                continue;
                            };
                        }
                        _ = self.active_tasks.fetchAdd(1, .monotonic);
                    },
                    .Resume => {
                        const task: *Task = @ptrCast(@alignCast(msg.task.?));
                        // in_inbox stays true until run() dequeues the task.
                        task.status.store(.Ready, .release);
                        self.enqueueTask(task);
                    },
                    .FsmSpawn => {
                        const fsm_task: *FsmTask = @ptrCast(@alignCast(msg.fsm_task.?));
                        self.enqueueFsm(fsm_task);
                    },
                    .FsmResume => {
                        // Wake (not spawn): push to queue without incrementing
                        // active_tasks. The task was counted at its original
                        // enqueueFsm and remains counted while parked.
                        const fsm_task: *FsmTask = @ptrCast(@alignCast(msg.fsm_task.?));
                        fsm_task.status = .Ready;
                        self.fsm_ready_queue.push(self.allocator, fsm_task) catch unreachable;
                    },
                    .RemoteStackFree => {
                        const memory = @as([*]u8, @ptrFromInt(msg.stack_ptr))[0..msg.stack_len];
                        self.freeLocalStackMemory(memory);
                    },
                    .RemoteFsmCtxFree => {
                        const class: fsm_mod.FsmCtxAllocClass = @enumFromInt(msg.fsm_ctx_class);
                        switch (class) {
                            .slab64 => self.fsm_ctx_64_slab.destroy(@as(*FsmCtx64, @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(msg.fsm_ctx_ptr)))))),
                            .slab128 => self.fsm_ctx_128_slab.destroy(@as(*FsmCtx128, @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(msg.fsm_ctx_ptr)))))),
                            .slab256 => self.fsm_ctx_256_slab.destroy(@as(*FsmCtx256, @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(msg.fsm_ctx_ptr)))))),
                            .none, .heap => {},
                        }
                    },
                    .RemoteCall => {
                        if (self.draining) {
                            std.debug.print("RE-ENTRANT DRAIN: sched={d}\n", .{self.index});
                            @panic("re-entrant drainChannels detected in RemoteCall");
                        }
                        self.draining = true;
                        const func = msg.rc_func.?;
                        const ctx = msg.rc_ctx.?;
                        const completion = msg.rc_wg;
                        func(ctx);
                        self.draining = false;
                        if (completion) |completion_ptr| {
                            const typed: *RemoteCompletion = @ptrCast(@alignCast(completion_ptr));
                            // Order matters: write `finished` BEFORE `wg.done()`.
                            // Once done() returns, the waiter may have been woken
                            // and freed *typed — touching it would be UAF.
                            typed.finished.store(true, .release);
                            typed.wg.done();
                        }
                    },
                }
            }
        }
    }

    fn hasChannelMessages(self: *Scheduler) bool {
        return self.dirty_mask.load(.seq_cst) != 0;
    }

    pub fn run(self: *Scheduler) void {
        ensureSignalAltStack();
        const my_id = std.Thread.getCurrentId();

        // CRITICAL: clear thread-locals on exit, regardless of how we
        // leave (normal return, panic, error). If we leave them set,
        // subsequent code on this thread that calls submitSpawn or any
        // helper gated on getScheduler() reads a dangling pointer — in
        // Debug the `sender_idx < channels.len` assert fires, in Release
        // the garbage pointer silently corrupts state. Before this defer
        // every caller had to remember to reset; missing it was a latent
        // landmine exposed whenever Scheduler's layout shifted.
        //
        // We clear rather than save/restore: a dirty prior state is
        // either (a) a bug the caller should fix, or (b) an intentional
        // nested invocation that should have set the state itself before
        // re-entering run(). Clearing is the safe default.
        defer {
            active_scheduler = undefined;
            scheduler_running = false;
        }

        active_scheduler = self;
        scheduler_running = true;

        global_registry.register(self.allocator, std.Thread.getCurrentId(), self) catch |err| {
            std.debug.print("SCHEDULER REGISTRATION FAILED: {}\n", .{err});
            return;
        };

        defer {
            global_registry.unregister(my_id);
        }

        while (true) {
            if (self.global_shutdown) |flag| {
                if (flag.load(.monotonic)) {
                    self.drainChannels();
                    self.scavengeMemory(true);
                    break;
                }
            }

            // Scan lock_waiters every iteration (fast or slow path). Without
            // this, three failure modes silently break lock timeouts:
            //   1. Idle scheduler blocks on io_uring_enter forever — handled
            //      by the idle path below arming a timeout for the earliest
            //      lock deadline.
            //   2. Fast-path starvation: a scheduler that always has ready
            //      work never enters the slow-path branch, so lock timeouts
            //      never fire. Running the scan here fixes that.
            //   3. Stale-entry leak: entries for fibers that woke via unlock
            //      (not timeout) are only lazily cleaned in this scan, so
            //      #2 also means the list grows without bound.
            _ = self.scanLockWaiters();
            self.scanFsmLockWaiters();

            // ── Fast path: if any queue has work, run it immediately.
            if (self.hasWork()) {
                self.fast_path_counter +%= 1;
                self.drainChannels();
                self.pollNonBlocking();
            } else {
                // ── Slow path: no ready work — check all sources.
                self.drainChannels();

                // Wake sleeping tasks
                self.wakeExpiredSleepers();

                // Wake sleeping FSM tasks. Same wake-time semantics
                // as the stackful sleeping_queue, but routed onto
                // fsm_ready_queue. submitFsmResume is the bypass-
                // active_tasks-increment variant (the FSM was
                // counted at original spawn).
                self.wakeExpiredFsmSleepers();
            } // end slow path

            // FSM tasks run inline on the worker stack — drain them before
            // context-switching to any stackful task. dispatchFsmTask
            // snapshots the queue length so cooperative yields (.Yielded)
            // defer to the next iteration.
            if (self.fsm_ready_queue.len() > 0) {
                self.drainFsmQueue();
            }

            // Look for tasks ready to start:
            if (self.ready_queue.len() > 0 or self.pinned_queue.items.len > 0 or self.yield_queue.items.len > 0) {
                // Priority order:
                //   1. Pinned queue (owner-local, no steal contention)
                //   2. Ready queue (Chase-Lev: cache-hot LIFO for fresh
                //      spawns/resumes, stealable by sibling schedulers)
                //   3. Yield queue (FIFO of cooperatively-yielded tasks).
                //      Drained AFTER ready_queue so new spawns get prompt
                //      CPU, but FIFO order within so co-located cooperative
                //      yielders rotate fairly.
                const task = blk: {
                    if (self.pinned_queue.items.len > 0)
                        break :blk self.pinned_queue.swapRemove(0);
                    if (self.ready_queue.pop()) |t| break :blk t;
                    if (self.yield_queue.items.len > 0)
                        break :blk self.yield_queue.orderedRemove(0);
                    continue;
                };
                self.current_task = task;

                // Transition IN_QUEUE -> IDLE now that the task is
                // dequeued. Keeping in_inbox at IN_QUEUE from
                // submitResume until here prevents duplicate pushes
                // via concurrent cross-thread resumes while the task
                // sat in the queue.
                task.in_inbox.store(qs.IN_INBOX_IDLE, .release);

                // Set task identity for the control plane.
                // If this task overflows its stack, __zig_alloc_segment
                // reads these to record which task class needs upsizing.
                fc.__current_task_fn = @intFromPtr(task.user_fn);
                fc.__current_task_size = task.base.size_class;

                // For @arena BG blocks, expose the thread-local arena so the
                // Runtime's frameAlloc() resolves to the lock-free local arena.
                // Regular @pinned fibers (scheduler affinity) do NOT use this —
                // they get normal frame arena + loop marks like any other fiber.
                if (task.config.use_arena) {
                    __pinned_local_alloc = self.local_arena.allocator();
                }

                if (rt_profile.CLEAR_PROFILE) {
                    fp_mod.recordSchedulerRun(self.index);
                    fp_mod.recordSiteRun(task.profile_site_id, self.index);
                }
                // 1. Switch to the Task
                task.base.switchTo(&self.main_ctx);

                // Clear pinned allocator — we're back on the scheduler's context.
                __pinned_local_alloc = null;

                self.handleTaskAfterDispatch(task);
                continue; // Keep looping if we have work!
            }

            // Look for tasks to steal (ONLY IF IDLE):
            if (!self.hasWork()) {
                const pair = global_registry.getRandomPair();
                if (pair.b) |victim| {
                    self.idleStealFrom(victim);
                }
            }

            // Flush any SQEs queued by fibers during this tick, then drain
            // completions. This batches all per-fiber submit() calls into one.
            self.flushRing();
            self.pollNonBlocking();
            if (self.hasWork()) continue;

            // IF IDLE: Wait for I/O completions via io_uring.
            // Determine wait_nr: 0 = non-blocking, 1 = block until at least one CQE.
            var wait_nr: u32 = 1;

            // Compute the wait timeout in nanoseconds. 0 means "no timeout"
            // (block indefinitely on CQEs). Otherwise we submit an io_uring
            // timeout SQE for that duration so the scheduler wakes up in
            // time to fire sleeper wakes or lock-waiter timeouts.
            var timeout_ns: u64 = 0;

            if (self.sleeping_queue.items.len > 0) {
                // 1ms poll for sleepers. (Existing behavior; the sleep
                // queue's exact next wake_time is not consulted.)
                timeout_ns = 1_000_000;
            }
            if (self.fsm_sleeping_queue.items.len > 0) {
                // 1ms poll for FSM sleepers. Same coarseness as the
                // stackful sleeping_queue.
                if (timeout_ns == 0 or 1_000_000 < timeout_ns) timeout_ns = 1_000_000;
            }
            if (self.earliestLockWaiterDeadlineMsUntil()) |ms_until| {
                const ns: u64 = @as(u64, @intCast(ms_until)) * 1_000_000;
                if (timeout_ns == 0 or ns < timeout_ns) timeout_ns = ns;
            }

            if (timeout_ns > 0) {
                const ts = linux.kernel_timespec{
                    .sec = @intCast(timeout_ns / 1_000_000_000),
                    .nsec = @intCast(timeout_ns % 1_000_000_000),
                };
                self.queueTimeoutOnIoStack(&ts);
                self.ring_dirty = true;
            } else if (self.shutdown_on_idle and self.active_tasks.load(.monotonic) == 0) {
                wait_nr = 0;
            }

            // Flush any pending SQEs (e.g. the timeout above) before sleeping.
            self.flushRing();

            // A. Park in userspace. If a producer already left a wake
            // token while we were awake, consume it and loop instead of
            // entering io_uring.
            if (!self.event_fd.prepareSleep()) {
                continue;
            }

            // B. The Double Check
            // We must check for new work ONE LAST TIME after parking.
            // If we don't do this, a task could arrive between our last check
            // and the prepareSleep call. Producers that arrive after
            // prepareSleep observe WakeParked and write eventfd.
            if (self.hasWork() or self.hasChannelMessages()) {
                self.event_fd.finishSleep();
                continue; // Restart loop to process the new work
            }

            // C. Actually Sleep -- wait for at least `wait_nr` CQEs.
            const count = self.copyCqesOnIoStack(wait_nr);

            // D. We are awake
            self.event_fd.finishSleep();

            if (count > 0) {
                self.processCqes(self.uring_cqes[0..count]);
            }

            // If still truly idle after waking, exit. This final gate must
            // include active_tasks and pending channel work, not just ready
            // queues, otherwise run() can return while blocked tasks or inbox
            // messages still exist.
            if (self.shutdown_on_idle and
                count == 0 and
                self.active_tasks.load(.monotonic) == 0 and
                !self.hasWork() and
                !self.hasChannelMessages() and
                self.sleeping_queue.items.len == 0 and
                self.fsm_sleeping_queue.items.len == 0)
            {
                self.scavengeMemory(true);
                break;
            }
        }
    }

    // Helper to wake a specific fiber.
    pub fn schedule(self: *Scheduler, task: *Task) void {
        self.submitResume(task);
    }

    /// Post-dispatch state machine: invoked by `run()` after a fiber
    /// returns control to the scheduler via `task.base.switchTo(&self.main_ctx)`.
    /// Examines `task.status` and performs the corresponding lifecycle
    /// transition: destroy (.Finished), re-enqueue (.Ready), or no-op
    /// (.Blocked, owned by sync primitive). Public so Loom regression
    /// tests can drive the .Finished destroy CAS at production-line
    /// granularity (see parking-lot-loom.zig:S27 — required for
    /// `loom_atomic_coverage.rb` to mark this site as Loom-covered).
    pub fn handleTaskAfterDispatch(self: *Scheduler, task: *Task) void {
        switch (task.status.load(.acquire)) {
            .Finished => {
                // Atomically claim the slot for destroy. CAS
                // IDLE -> DESTROYING. If a concurrent
                // submitResume claimed IDLE -> IN_QUEUE first,
                // the task is now sitting in some queue
                // (or SPSC ring); we do NOT destroy here. The
                // next pop will dequeue the task, see status
                // still .Finished and in_inbox back at IDLE,
                // and retry this branch with the CAS now
                // succeeding.
                //
                // This single CAS closes the cross-scheduler
                // submitResume-after-Finished UAF that
                // surfaced as the SplitStream pubsub-hammer
                // SEGV at destroy(task.base) below. See
                // queues.zig:Task.in_inbox doc and the
                // matching VOPR + Loom regression tests.
                if (task.in_inbox.cmpxchgStrong(qs.IN_INBOX_IDLE, qs.IN_INBOX_DESTROYING, .acq_rel, .acquire) != null) {
                    // A concurrent submitResume holds the
                    // slot. The task is queued elsewhere; the
                    // next pop will reach this branch again
                    // with in_inbox back at IDLE.
                } else {
                    if (rt_profile.CLEAR_PROFILE) {
                        fp_mod.recordFiberExit(task.profile_site_id, task.spawn_ns, fp_mod.nowNs());
                    }
                    _ = self.active_tasks.fetchSub(1, .monotonic);
                    // Remove from lock_waiters before destroying to prevent stale pointer access.
                    // A task can register itself there via registerLockWaiter and then complete
                    // (e.g. after deadlock detection returns error.Deadlock) without being lazily
                    // removed, because waiting_for_lock was already cleared by detectCycle.
                    for (self.lock_waiters.items, 0..) |wt, idx| {
                        if (wt == task) {
                            _ = self.lock_waiters.swapRemove(idx);
                            break;
                        }
                    }
                    // Compatibility no-op: tasks no longer own EBR slots.
                    self.releaseTaskEbr(task);
                    self.freeStack(task.base.stack);
                    self.destroyFiber(task.base);
                    self.task_slab.destroy(task);
                }
            },
            .Ready => {
                // It yielded, but wants to run again. If a concurrent
                // wake already queued it through submitResume, honor the
                // in_inbox guard and avoid a duplicate enqueue.
                if (task.in_inbox.load(.acquire) == qs.IN_INBOX_IDLE) {
                    // Cooperative coopYield path goes to yield_queue
                    // (FIFO), so the just-yielded task does NOT win
                    // the next pop against tasks that yielded earlier.
                    // All other re-enqueues (e.g., scheduler-internal
                    // suspensions that store .Ready without setting
                    // co_yielded) keep the legacy ready_queue route.
                    if (task.co_yielded) {
                        task.co_yielded = false;
                        self.yield_queue.append(self.allocator, task) catch unreachable;
                    } else {
                        self.enqueueTask(task);
                    }
                }
            },
            .Blocked => {
                // Do nothing! It is now owned by the WaitGroup/Mutex/Etc.
                // It will be added back to ready_queue by someone else later.
            },
        }
    }

    /// Walk `fsm_sleeping_queue` and wake any FSM tasks whose
    /// `fsm_wake_time` has passed. Public so VOPR tests can drive
    /// the wake path directly without running the full scheduler
    /// loop. Mirrors wakeExpiredSleepers but for the FSM queue.
    pub fn wakeExpiredFsmSleepers(self: *Scheduler) void {
        if (self.fsm_sleeping_queue.items.len == 0) return;
        const now = milliTimestamp();
        var i: usize = 0;
        while (i < self.fsm_sleeping_queue.items.len) {
            const fsm_task = self.fsm_sleeping_queue.items[i];
            if (now >= fsm_task.fsm_wake_time) {
                _ = self.fsm_sleeping_queue.swapRemove(i);
                fsm_task.status = .Ready;
                self.fsm_ready_queue.push(self.allocator, fsm_task) catch unreachable;
            } else {
                i += 1;
            }
        }
    }

    /// Walk `sleeping_queue` and wake any tasks whose `wake_time`
    /// has passed. Public so loom tests can drive the wake path
    /// directly without running the full scheduler loop.
    pub fn wakeExpiredSleepers(self: *Scheduler) void {
        if (self.sleeping_queue.items.len == 0) return;
        const now = milliTimestamp();
        var i: usize = 0;
        while (i < self.sleeping_queue.items.len) {
            const task = self.sleeping_queue.items[i];
            if (now >= task.wake_time) {
                _ = self.sleeping_queue.swapRemove(i);
                task.status.store(.Ready, .release);
                self.enqueueTask(task);
            } else {
                i += 1;
            }
        }
    }

    /// Try to steal half of `victim`'s ready queue (stackful first;
    /// if empty, fall back to FSM ready queue). Updates active_tasks
    /// counters on both schedulers. Caller is responsible for the
    /// idleness gate -- this method just performs the steal+
    /// accounting without checking `self.hasWork()` or the
    /// `victim != self` invariant. The run-loop's idle steal block
    /// at the call site enforces both. Public so loom tests can
    /// drive the steal+accounting paths directly without the run
    /// loop's implicit registry+rng dependencies.
    pub fn idleStealFrom(self: *Scheduler, victim: *Scheduler) void {
        if (victim == self) return;
        // Stackful steal: take half of victim's stackful queue.
        const stolen = self.ready_queue.tryStealFrom(&victim.ready_queue, self.allocator);
        if (stolen > 0) {
            // update my queue size to account for steals
            _ = self.active_tasks.fetchAdd(stolen, .monotonic);
            // update victim queue size to account for steals
            _ = victim.active_tasks.fetchSub(stolen, .monotonic);
        }
        // FSM steal: if still idle after stackful steal, grab half
        // of victim's FSM queue. Same algorithm, separate type.
        // Stealing transfers ownership of the *FsmTask handle; state
        // struct is still owned by the original caller (scheduler-
        // agnostic).
        if (stolen == 0) {
            const fsm_stolen = self.fsm_ready_queue.tryStealFrom(&victim.fsm_ready_queue, self.allocator);
            if (fsm_stolen > 0) {
                _ = self.active_tasks.fetchAdd(fsm_stolen, .monotonic);
                _ = victim.active_tasks.fetchSub(fsm_stolen, .monotonic);
            }
        }
    }

    // Helper to get current task
    pub fn getCurrent(self: *Scheduler) *Task {
        return self.current_task.?;
    }

    /// Test-only single-iteration drain+pop+switchTo+dispatch helper.
    ///
    /// Mirrors the subset of `Scheduler.run` that test code that drives
    /// a scheduler manually (e.g. main-thread polling in a test that
    /// also spawns worker scheduler threads) typically reimplements.
    /// Centralizing this prevents bugs where a hand-rolled loop omits
    /// the `in_inbox` protocol and silently drops wakes, leading to
    /// parked-forever fibers and leaked Fiber/Task allocations.
    ///
    /// Concrete subset of `run()` mirrored here:
    ///   - drainChannels (pulls in cross-thread Spawn / Resume / RemoteCall)
    ///   - ready_queue.pop
    ///   - in_inbox transition IN_QUEUE -> IDLE before switchTo (line 1239
    ///     of run()); without this, a re-park's submitResume CAS
    ///     IDLE->IN_QUEUE silently fails and the wake is lost.
    ///   - .Finished destroy guarded by CAS IDLE -> DESTROYING (line 1283)
    ///     so a concurrent submitResume that planted IN_QUEUE delegates
    ///     destruction to the next pop instead of double-destroying.
    ///   - .Ready re-enqueue guarded by in_inbox == IDLE (line 1314) to
    ///     avoid duplicate pushes when a concurrent submitResume already
    ///     queued the task elsewhere.
    ///
    /// Returns true if any task was popped (work was done), false if
    /// idle. Caller is responsible for the outer loop and termination
    /// condition.
    ///
    /// Manual polling loops that should use this helper:
    ///   - zig/runtime/steal-hammer-test.zig:189-213 (same broken pattern
    ///     as stream-test had: missing `in_inbox = IDLE` after pop +
    ///     missing .Finished CAS guard + missing .Ready in_inbox guard).
    /// `zig/runtime/stream-test.zig:1170-1192` already uses pollOne.
    pub fn pollOne(self: *Scheduler) bool {
        self.drainChannels();
        const task = self.ready_queue.pop() orelse return false;
        task.in_inbox.store(qs.IN_INBOX_IDLE, .release);
        self.current_task = task;
        fc.__current_task_fn = @intFromPtr(task.user_fn);
        fc.__current_task_size = task.base.size_class;
        task.base.switchTo(&self.main_ctx);
        switch (task.status.load(.acquire)) {
            .Finished => {
                if (task.in_inbox.cmpxchgStrong(qs.IN_INBOX_IDLE, qs.IN_INBOX_DESTROYING, .acq_rel, .acquire) == null) {
                    _ = self.active_tasks.fetchSub(1, .monotonic);
                    self.releaseTaskEbr(task);
                    self.freeStack(task.base.stack);
                    self.destroyFiber(task.base);
                    self.task_slab.destroy(task);
                }
                // CAS-fail: a concurrent submitResume holds IN_QUEUE.
                // The next pollOne call will pick up the task with
                // status still .Finished and the CAS will succeed.
            },
            .Ready => {
                if (task.in_inbox.load(.acquire) == qs.IN_INBOX_IDLE) {
                    self.enqueueTask(task);
                }
            },
            .Blocked => {},
        }
        return true;
    }

    // Cooperative yield: switch to the scheduler only if other fibers are ready.
    // Called from rt.checkYield() every YIELD_BUDGET iterations of a while loop.
    // Zero-cost when no other fiber is waiting (single-fiber programs).
    fn enqueueTask(self: *Scheduler, task: *Task) void {
        if (task.config.pinned) {
            self.pinned_queue.append(self.allocator, task) catch unreachable;
        } else {
            self.ready_queue.push(self.allocator, task) catch unreachable;
        }
    }

    /// Enqueue an FSM (stackless) task on this scheduler's local queue.
    /// FSM tasks run inline on the worker stack. They CAN migrate via
    /// work-stealing (tryStealFrom) when a sibling scheduler is idle.
    /// Caller owns the backing state struct; scheduler only moves the handle.
    pub fn enqueueFsm(self: *Scheduler, task: *FsmTask) void {
        task.status = .Ready;
        if (rt_profile.CLEAR_PROFILE) {
            if (task.spawn_ns == 0) {
                task.spawn_ns = fp_mod.nowNs();
                fp_mod.recordSiteSpawn(
                    task.profile_site_id,
                    @as(fp_mod.DispatchKind, @enumFromInt(task.profile_dispatch)),
                    .fsm,
                );
            }
        }
        self.fsm_ready_queue.push(self.allocator, task) catch unreachable;
        _ = self.active_tasks.fetchAdd(1, .monotonic);
    }

    /// Maximum FSM tasks dispatched per scheduler iteration. Bounds the
    /// wait time a stackful task can incur when the FSM queue is under
    /// burst load. With 141 ns/FSM (measured), 64 caps stackful latency
    /// at ~9 us per iteration. Newly-yielded FSMs beyond this batch are
    /// deferred to the next iteration (not lost).
    const FSM_DRAIN_BATCH: usize = 64;

    /// Drain up to FSM_DRAIN_BATCH ready FSMs for this iteration. Bounded
    /// so stackful task latency is not held hostage by FSM burst load.
    /// Yielded tasks go to fsm_deferred_queue and are flushed back to the
    /// main queue after the batch — this guarantees FIFO-style progress
    /// across all yielders (without this, Chase-Lev's LIFO owner-pop would
    /// let a single yielded task monopolize the batch).
    pub fn drainFsmQueue(self: *Scheduler) void {
        // Mark the dispatch window so coopYield()/checkYield() called
        // from inside an FSM resumeFn becomes a no-op. See the comment
        // on the field declaration for why this is necessary.
        self.in_fsm_dispatch = true;
        defer self.in_fsm_dispatch = false;
        const snapshot = @min(self.fsm_ready_queue.len(), FSM_DRAIN_BATCH);
        var i: usize = 0;
        while (i < snapshot) : (i += 1) {
            const task = self.fsm_ready_queue.pop() orelse break;
            if (rt_profile.CLEAR_PROFILE) {
                fp_mod.recordSchedulerRun(self.index);
                fp_mod.recordSiteRun(task.profile_site_id, self.index);
            }
            const reason = fsm_mod.dispatchOnce(task);
            switch (reason) {
                .Done => {
                    if (rt_profile.CLEAR_PROFILE) {
                        fp_mod.recordFiberExit(task.profile_site_id, task.spawn_ns, fp_mod.nowNs());
                    }
                    _ = self.active_tasks.fetchSub(1, .monotonic);
                    // Per-task Runtime shell teardown MUST happen before
                    // destroy_fn (destroy_fn reads task.ctx and frees the
                    // user ctx struct).
                    self.releaseFsmTaskEbr(task);
                    // The synthesized destroy_fn frees the user ctx
                    // pointed to by task.ctx. It does NOT free the
                    // FsmTask itself — the FsmTask lives in
                    // `fsm_task_slab` and is reclaimed below by
                    // `fsm_task_slab.destroy(task)`. The slab return
                    // happens AFTER destroy_fn runs so destroy_fn can
                    // still read task.ctx.
                    if (task.destroy_fn) |df| df(task);
                    const owner: *Scheduler = if (task.owner_scheduler) |raw|
                        @ptrCast(@alignCast(raw))
                    else
                        self;
                    owner.fsm_task_slab.destroy(task);
                },
                .Yielded => {
                    // Stage for flush after the batch. Prevents LIFO starvation.
                    self.fsm_deferred_queue.append(self.allocator, task) catch unreachable;
                },
                .WaitForIO => {
                    // Parked; CQE path will re-enqueue via enqueueFsm when the
                    // completion arrives. Scheduler stores nothing — the task's
                    // waiter field retains the pointer for decode.
                },
                .WaitForLock => {
                    // Parked on a ParkingMutex/RwLock. Unlock path wakes us
                    // via submitFsmResume. The waiter node lives in the
                    // user state struct; we hold a pointer to it in
                    // task.lock_waiter for future timeout-scan support.
                },
            }
        }
        // Flush deferred tasks back to the main queue for the next iteration.
        for (self.fsm_deferred_queue.items) |t| {
            self.fsm_ready_queue.push(self.allocator, t) catch unreachable;
        }
        self.fsm_deferred_queue.clearRetainingCapacity();
    }

    fn hasWork(self: *Scheduler) bool {
        return self.ready_queue.len() > 0 or self.pinned_queue.items.len > 0 or self.yield_queue.items.len > 0 or self.fsm_ready_queue.len() > 0;
    }

    /// Public alias of hasWork for tests that need to inspect scheduler state.
    pub fn hasWorkPub(self: *Scheduler) bool {
        return self.hasWork();
    }

    pub noinline fn coopYield(self: *Scheduler) void {
        // FSM tasks dispatched by drainFsmQueue run inline on the worker
        // stack. They are NOT stackful tasks; getCurrent() returns the
        // most-recent stackful task (or null), and task.base.yield()
        // would corrupt that stack rather than suspending the FSM. FSMs
        // yield cooperatively by returning .Yielded from resumeFn -- so
        // the right thing to do here is nothing.
        if (self.in_fsm_dispatch) return;
        if (self.hasWork()) {
            const task = self.getCurrent();
            task.status.store(.Ready, .release);
            // Mark as cooperative-yield so run() routes to yield_queue
            // (FIFO) instead of ready_queue (LIFO). Without this, two
            // co-located cooperative fibers starve the older one.
            task.co_yielded = true;
            task.base.yield();
            // Resumed here — task.status remains .Ready (scheduler sets nothing on resume)
        }
    }

    // Lay this beautiful task to rest until a specific time
    pub fn sleepTask(self: *Scheduler, task: *Task, wake_time: i64) void {
        task.wake_time = wake_time;
        task.status.store(.Blocked, .release);
        self.sleeping_queue.append(self.allocator, task) catch unreachable;
    }

    /// FSM-mode parallel of sleepTask: park an FSM task on the
    /// fsm_sleeping_queue with a wake time. The user's resume fn
    /// must return YieldReason.WaitForLock immediately after this
    /// call so the scheduler treats the FSM as Blocked. The slow-
    /// path scan in run() compares now against fsm_wake_time and
    /// re-enqueues to fsm_ready_queue when reached.
    pub fn fsmSleepTask(self: *Scheduler, fsm_task: *FsmTask, wake_time: i64) void {
        fsm_task.fsm_wake_time = wake_time;
        fsm_task.status = .Blocked;
        self.fsm_sleeping_queue.append(self.allocator, fsm_task) catch unreachable;
    }

    // Register a lock-parked task for timeout scanning.
    // Called by parking-lot.zig before the fiber yields.
    // The task's waiting_for_lock / waiting_for_lock_list / lock_waiter_node
    // must already be set by the caller.
    /// Compute the milliseconds until the earliest lock-waiter
    /// deadline fires, or null if there are no live waiters. Used by
    /// run()'s idle-arming code to size the io_uring timeout so
    /// `lock_timeout_ms` actually fires on an otherwise-idle
    /// scheduler. Public so VOPR tests can drive it without entering
    /// run().
    pub fn earliestLockWaiterDeadlineMsUntil(self: *Scheduler) ?i64 {
        if (self.lock_waiters.items.len == 0) return null;
        const now_ms = milliTimestamp();
        var earliest_ms: i64 = now_ms + self.lock_timeout_ms;
        for (self.lock_waiters.items) |t| {
            if (t.waiting_for_lock.load(.monotonic) == null) continue;
            const deadline = t.lock_wait_start_ms.load(.acquire) + self.lock_timeout_ms;
            if (deadline < earliest_ms) earliest_ms = deadline;
        }
        return @max(@as(i64, 1), earliest_ms - now_ms);
    }

    pub fn registerLockWaiter(self: *Scheduler, task: *Task) void {
        // .release pairs with .acquire load by scanLockWaiters /
        // idle-deadline path on potentially another scheduler thread
        // (after work-stealing, `self` may not be the original spawner).
        task.lock_wait_start_ms.store(milliTimestamp(), .release);
        self.lock_waiters.append(self.allocator, task) catch {};
    }

    /// FSM parallel to registerLockWaiter. lock_wait_start_ms is set by
    /// the caller (tryLockForFsm) since the FSM locking path owns the
    /// waiter-node setup.
    pub fn registerFsmLockWaiter(self: *Scheduler, fsm_task: *FsmTask) void {
        self.fsm_lock_waiters.append(self.allocator, fsm_task) catch {};
    }

    /// Lock-timeout scanner for FSM waiters. Mirrors scanLockWaiters.
    /// On expiry: set lock_error = .LockTimeout, clear waiting_for_lock,
    /// re-enqueue for dispatch. Resume fn reads lock_error and surfaces
    /// the error on its next call.
    ///
    /// FsmTask back-pointer fields are atomic (matching stackful Task),
    /// so reads here use .acquire to pair with the .release stores in
    /// tryLock*ForFsm and wakeNext. The post-spin re-check mirrors the
    /// stackful scanLockWaiters race fix: between our pre-spin observation
    /// and taking wl.spinAcquire(), the wake-side can pop our node and
    /// clear the back-pointers. Re-checking under spin treats that case
    /// as "wake won" and skips both the remove and the re-enqueue.
    fn scanFsmLockWaiters(self: *Scheduler) void {
        const now_ms = milliTimestamp();
        var i: usize = 0;
        while (i < self.fsm_lock_waiters.items.len) {
            const task = self.fsm_lock_waiters.items[i];
            if (task.waiting_for_lock.load(.acquire) == null) {
                _ = self.fsm_lock_waiters.swapRemove(i);
                continue;
            }
            const start_ms = task.lock_wait_start_ms.load(.acquire);
            if (now_ms - start_ms > self.lock_timeout_ms) {
                // Remove the FSM's WaiterNode from the parking-lot's
                // waiter list (mirrors stackful scanLockWaiters). If
                // we don't, a later unlock will pop the stale node and
                // either grant ownership to a Done-or-retrying FSM
                // (use-after-free risk) or push it twice on retry.
                var wake_lost = false;
                if (task.waiting_for_lock_list.load(.acquire)) |raw| {
                    const wl: *qs.WaiterList = @ptrCast(@alignCast(raw));
                    wl.spinAcquire();
                    // Re-check under spin: waker may have popped + cleared
                    // both fields between our pre-spin observation and now.
                    const wfl_now = task.waiting_for_lock_list.load(.acquire);
                    const lw_now = task.lock_waiter.load(.acquire);
                    if (wfl_now == null or lw_now == null) {
                        wake_lost = true;
                    } else {
                        const node: *qs.WaiterNode = @ptrCast(@alignCast(lw_now.?));
                        _ = wl.remove(node);
                    }
                    wl.spinRelease();
                }
                if (wake_lost) {
                    _ = self.fsm_lock_waiters.swapRemove(i);
                    continue;
                }
                task.lock_error = .LockTimeout;
                task.waiting_for_lock.store(null, .release);
                task.waiting_for_lock_list.store(null, .release);
                task.lock_waiter.store(null, .release);
                task.waiting_for_fsm_owner.store(null, .release);
                _ = task.seq.fetchAdd(1, .release);
                task.status = .Ready;
                self.fsm_ready_queue.push(self.allocator, task) catch {};
                _ = self.fsm_lock_waiters.swapRemove(i);
                continue;
            }
            i += 1;
        }
    }

    /// Public drain pass for the FSM lock scanner — used by tests that
    /// don't run the full main loop.
    pub fn scanFsmLockWaitersPub(self: *Scheduler) void {
        self.scanFsmLockWaiters();
    }

    /// Public drain pass for the stackful lock scanner — used by loom
    /// tests that drive the timeout-fire path without entering run().
    /// Returns the earliest-known deadline (used by run() to arm the
    /// io_uring wait).
    pub fn scanLockWaitersPub(self: *Scheduler) ?i64 {
        return self.scanLockWaiters();
    }

    // -----------------------------------------------------------------
    // io_uring helpers
    // -----------------------------------------------------------------

    // CQE user_data encoding:
    //   0           = eventfd sentinel (cross-scheduler wakeup)
    //   1           = timeout sentinel (ignore)
    //   ptr & 1 == 1 = IoWaiter pointer (file I/O completion). Real ptr = user_data & ~1.
    //   ptr & 1 == 0 = Task pointer (poll readiness wakeup). Real ptr = user_data.
    //
    // Task and IoWaiter are both aligned >= 4, so bit 0 is always free.
    pub const EVENTFD_SENTINEL: u64 = 0;
    pub const TIMEOUT_SENTINEL: u64 = 1;

    /// Per-operation handle placed on the fiber's (blocked) stack frame.
    /// Its address goes into the SQE user_data field (tagged with bit 0 = 1).
    /// The scheduler writes the CQE result before waking the fiber, so the
    /// fiber reads `waiter.result` immediately after resume.
    pub const IoWaiter = struct {
        task: *Task,
        result: i32 = undefined,

        /// Encode this IoWaiter's address as a user_data value (bit 0 set).
        pub fn encode(self: *IoWaiter) u64 {
            return @intFromPtr(self) | 1;
        }

        /// Decode a user_data value back to an IoWaiter pointer.
        pub fn decode(user_data: u64) *IoWaiter {
            return @ptrFromInt(user_data & ~@as(u64, 1));
        }
    };

    /// Convert a negative CQE result (negative errno) to a Zig error.
    /// Widens to i64 before negation to prevent overflow when result == minInt(i32).
    /// We intentionally collapse kernel errno values to `error.Unexpected` here:
    /// the runtime does not currently preserve specific errno tags, and
    /// `std.posix.unexpectedErrno` prints a stack trace that makes the test
    /// suite noisy without adding useful signal.
    pub fn ioError(result: i32) std.posix.UnexpectedError {
        const raw = -@as(i64, result);
        if (raw >= 1 and raw <= 4095) return error.Unexpected;
        return error.Unexpected;
    }

    /// Submit an IORING_OP_READ for `fd` into `buffer` and park `waiter.task`.
    pub fn submitRead(self: *Scheduler, waiter: *IoWaiter, fd: posix.fd_t, buffer: []u8) !void {
        _ = try self.ring.read(waiter.encode(), fd, .{ .buffer = buffer }, 0);
        self.ring_dirty = true;
        waiter.task.status.store(.Blocked, .release);
    }

    /// FSM-mode variant of submitRead. Same SQE shape, but the
    /// user_data is FsmIoWaiter.encode() so processCqes routes the
    /// completion to the FSM ready queue (via submitFsmResume) and
    /// stores the CQE.res on `waiter.result` for the resume fn to
    /// read on next dispatch.
    ///
    /// Caller (the user FSM's resume fn) is responsible for:
    ///   - waiter pointer outlives the SQE (lives in the user state struct);
    ///   - returning YieldReason.WaitForIO from the resume fn after this call;
    ///   - reading waiter.result on the next dispatch.
    pub fn submitReadForFsm(self: *Scheduler, waiter: *fsm_mod.FsmIoWaiter, fd: posix.fd_t, buffer: []u8) !void {
        _ = try self.ring.read(waiter.encode(), fd, .{ .buffer = buffer }, 0);
        self.ring_dirty = true;
        waiter.task.status = .Blocked;
    }

    /// Submit an IORING_OP_WRITE for `fd` from `buffer` and park `waiter.task`.
    pub fn submitWrite(self: *Scheduler, waiter: *IoWaiter, fd: posix.fd_t, buffer: []const u8) !void {
        _ = try self.ring.write(waiter.encode(), fd, buffer, 0);
        self.ring_dirty = true;
        waiter.task.status.store(.Blocked, .release);
    }

    /// Submit an IORING_OP_ACCEPT for `server_fd` and park `waiter.task`.
    /// CQE result: client fd on success, negative errno on error.
    pub fn submitAccept(self: *Scheduler, waiter: *IoWaiter, server_fd: posix.fd_t) !void {
        _ = try self.ring.accept(waiter.encode(), server_fd, null, null, std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC);
        self.ring_dirty = true;
        waiter.task.status.store(.Blocked, .release);
    }

    /// Submit an IORING_OP_CONNECT for `fd` to `addr` and park `waiter.task`.
    /// CQE result: 0 on success, negative errno on error.
    pub fn submitConnect(self: *Scheduler, waiter: *IoWaiter, fd: posix.fd_t, addr: *const posix.sockaddr, addr_len: posix.socklen_t) !void {
        _ = try self.ring.connect(waiter.encode(), fd, addr, addr_len);
        self.ring_dirty = true;
        waiter.task.status.store(.Blocked, .release);
    }

    /// Submit an IORING_OP_RECV for `fd` into `buffer` and park `waiter.task`.
    /// CQE result: bytes received, 0 = EOF, negative = -errno.
    pub fn submitRecv(self: *Scheduler, waiter: *IoWaiter, fd: posix.fd_t, buffer: []u8) !void {
        _ = try self.ring.recv(waiter.encode(), fd, .{ .buffer = buffer }, 0);
        self.ring_dirty = true;
        waiter.task.status.store(.Blocked, .release);
    }

    /// FSM-mode submitRecv. Same SQE shape as submitRecv but tags
    /// the user_data with the FsmIoWaiter marker so processCqes
    /// routes the completion to the FSM ready queue. The user
    /// FSM's resume fn must return YieldReason.WaitForIO after this
    /// call and read waiter.result on next dispatch.
    pub fn submitRecvForFsm(self: *Scheduler, waiter: *fsm_mod.FsmIoWaiter, fd: posix.fd_t, buffer: []u8) !void {
        _ = try self.ring.recv(waiter.encode(), fd, .{ .buffer = buffer }, 0);
        self.ring_dirty = true;
        waiter.task.status = .Blocked;
    }

    /// FSM-mode submitWrite. Same SQE shape as submitWrite but tags
    /// the user_data with the FsmIoWaiter marker. CQE result is
    /// bytes written or negative -errno.
    pub fn submitWriteForFsm(self: *Scheduler, waiter: *fsm_mod.FsmIoWaiter, fd: posix.fd_t, buffer: []const u8) !void {
        _ = try self.ring.write(waiter.encode(), fd, buffer, 0);
        self.ring_dirty = true;
        waiter.task.status = .Blocked;
    }

    /// Submit an IORING_OP_SEND for `fd` from `buffer` and park `waiter.task`.
    /// CQE result: bytes sent, negative = -errno.
    pub fn submitSend(self: *Scheduler, waiter: *IoWaiter, fd: posix.fd_t, buffer: []const u8) !void {
        _ = try self.ring.send(waiter.encode(), fd, buffer, 0);
        self.ring_dirty = true;
        waiter.task.status.store(.Blocked, .release);
    }

    /// Core I/O wakeup logic: CAS from Blocked -> Ready, push to queue.
    /// Only the CAS winner pushes, preventing double-push when stale
    /// CQEs race with other wakeup paths. Extracted so Loom scenarios
    /// can exercise this code path under deterministic interleaving.
    pub fn wakeTaskFromIo(self: *Scheduler, task: *Task) void {
        if (task.status.cmpxchgStrong(.Blocked, .Ready, .acq_rel, .monotonic) == null) {
            self.enqueueTask(task);
        }
    }

    fn ioHelperStackTop(self: *Scheduler) usize {
        return @intFromPtr(self.io_helper_stack.ptr) + self.io_helper_stack.len;
    }

    /// Time out any lock_waiters past their deadline and lazy-clean stale
    /// entries. Returns the earliest remaining deadline in milliseconds
    /// (absolute wall-clock), or null if the list is empty after scanning.
    /// The caller uses this to arm an io_uring timeout in the idle path so
    /// a totally-idle scheduler still wakes up in time to fire timeouts.
    fn scanLockWaiters(self: *Scheduler) ?i64 {
        if (self.lock_waiters.items.len == 0) return null;
        const now_ms = milliTimestamp();
        var earliest: ?i64 = null;
        var i: usize = 0;
        while (i < self.lock_waiters.items.len) {
            const task = self.lock_waiters.items[i];
            if (task.waiting_for_lock.load(.acquire) == null) {
                // Already woken normally; clean up the tracking entry.
                _ = self.lock_waiters.swapRemove(i);
                continue;
            }
            const start_ms = task.lock_wait_start_ms.load(.acquire);
            const deadline = start_ms + self.lock_timeout_ms;
            if (now_ms - start_ms > self.lock_timeout_ms) {
                // Timed out: remove from lock's waiter list, then wake.
                //
                // Race with the wake-side path (parking-lot.zig wakeNext):
                // the waker clears task fields in this order under
                // queue_spin: waiting_for_lock_list, then lock_waiter_node.
                // Our pre-spin reads above may have observed
                // waiting_for_lock as non-null, but by the time we take
                // wl.spinAcquire() the waker may have already popped this
                // node, cleared waiting_for_lock_list, and cleared
                // lock_waiter_node. RE-CHECK both fields under spin: if
                // either is now null, the wake-side won — the task is
                // already being resumed normally, so we must NOT re-wake
                // (would double-enqueue) and must NOT call wl.remove on a
                // null/stale node pointer (would deref dangling memory or
                // panic on `.?` unwrap).
                var removed = false;
                var wake_lost = false;
                if (task.waiting_for_lock_list.load(.acquire)) |wl| {
                    wl.spinAcquire();
                    if (task.waiting_for_lock_list.load(.acquire) == null or
                        task.lock_waiter_node.load(.acquire) == null)
                    {
                        // Waker won the race after we observed wfl != null
                        // but before we took the spin. Don't touch the
                        // queue or task fields — the wake-side already
                        // owns the resume. We just clean up our tracking
                        // entry so we stop re-checking this task.
                        wake_lost = true;
                    } else {
                        removed = wl.remove(task.lock_waiter_node.load(.acquire).?);
                    }
                    wl.spinRelease();
                }
                if (wake_lost) {
                    _ = self.lock_waiters.swapRemove(i);
                    continue;
                }
                // If this was a ParkingRwLock write-lock waiter and we
                // won the removal race, decrement writers_waiting so
                // future lockShared calls are not permanently blocked.
                if (removed) {
                    if (task.lock_counter_ptr) |ctr| {
                        _ = @atomicRmw(u32, ctr, .Sub, 1, .monotonic);
                    }
                }
                _ = self.lock_waiters.swapRemove(i);
                // Set lock_timed_out BEFORE clearing waiting_for_lock so
                // the waker-side check in lockSlow (which reads
                // lock_timed_out only after seeing waiting_for_lock has
                // become null and the fiber resumed) observes the flag.
                task.lock_timed_out.store(true, .release);
                task.waiting_for_lock.store(null, .release);
                task.waiting_for_lock_list.store(null, .release);
                task.lock_waiter_node.store(null, .release);
                task.lock_counter_ptr = null;
                task.status.store(.Ready, .release);
                self.enqueueTask(task);
                continue;
            }
            if (earliest == null or deadline < earliest.?) earliest = deadline;
            i += 1;
        }
        return earliest;
    }

    fn queueTimeoutOnIoStack(self: *Scheduler, ts: *const linux.kernel_timespec) void {
        const Ctx = struct {
            self: *Scheduler,
            ts: *const linux.kernel_timespec,
            fn run(raw: ?*anyopaque) callconv(.c) void {
                const ctx: *@This() = @ptrCast(@alignCast(raw.?));
                _ = ctx.self.ring.timeout(TIMEOUT_SENTINEL, ctx.ts, 0, 0) catch {};
            }
        };

        var ctx = Ctx{ .self = self, .ts = ts };
        fc.callOnStack(self.ioHelperStackTop(), &Ctx.run, @ptrCast(&ctx));
    }

    fn submitRingOnIoStack(self: *Scheduler) void {
        const Ctx = struct {
            self: *Scheduler,
            fn run(raw: ?*anyopaque) callconv(.c) void {
                const ctx: *@This() = @ptrCast(@alignCast(raw.?));
                _ = ctx.self.ring.submit() catch {};
            }
        };

        var ctx = Ctx{ .self = self };
        fc.callOnStack(self.ioHelperStackTop(), &Ctx.run, @ptrCast(&ctx));
    }

    fn copyCqesOnIoStack(self: *Scheduler, wait_nr: u32) usize {
        const Ctx = struct {
            self: *Scheduler,
            wait_nr: u32,
            result: usize = 0,
            fn run(raw: ?*anyopaque) callconv(.c) void {
                const ctx: *@This() = @ptrCast(@alignCast(raw.?));
                ctx.result = ctx.self.ring.copy_cqes(&ctx.self.uring_cqes, ctx.wait_nr) catch 0;
            }
        };

        var ctx = Ctx{ .self = self, .wait_nr = wait_nr };
        fc.callOnStack(self.ioHelperStackTop(), &Ctx.run, @ptrCast(&ctx));
        return ctx.result;
    }

    /// Process CQEs from the io_uring ring. Unified handler for:
    /// - Poll readiness (POLL_ADD completions) -> wake blocked task
    /// - File I/O completions (READ/WRITE) -> write result to IoWaiter, wake task
    /// - Eventfd wakeup (sentinel 0) -> consume eventfd
    /// - Timeout (sentinel 1) -> ignore
    pub fn processCqes(self: *Scheduler, cqes: []const linux.io_uring_cqe) void {
        for (cqes) |cqe| {
            const ud = cqe.user_data;
            if (ud == EVENTFD_SENTINEL) {
                self.event_fd.consume();
            } else if (ud == TIMEOUT_SENTINEL) {
                // Timeout expired or cancelled -- no action needed.
            } else if (FsmIoWaiter.isFsmMarker(ud)) {
                // FSM IoWaiter: stackless task's IO completion. Check this
                // BEFORE the stackful IoWaiter path because FSM encoding
                // (bits 00 = 11) also satisfies bit 0 = 1.
                //
                // Re-enqueue without incrementing active_tasks: the task
                // was counted at original spawn and has not been
                // decremented (it just moved Blocked -> Ready). Mirrors
                // submitFsmResume's bypass.
                const fsm_waiter = FsmIoWaiter.decode(ud);
                fsm_waiter.result = cqe.res;
                fsm_waiter.task.status = .Ready;
                self.fsm_ready_queue.push(self.allocator, fsm_waiter.task) catch unreachable;
            } else if (ud & 1 == 1) {
                // Stackful IoWaiter: file I/O completion (READ, WRITE, etc.)
                const waiter = IoWaiter.decode(ud);
                waiter.result = cqe.res;
                waiter.task.status.store(.Ready, .release);
                self.enqueueTask(waiter.task);
            } else {
                // Task pointer: poll readiness (POLL_ADD completion)
                self.wakeTaskFromIo(@ptrFromInt(ud));
            }
        }
    }

    /// Non-blocking CQE drain: check for completions without sleeping.
    /// Wakes any Blocked fibers whose I/O has completed.
    pub fn pollNonBlocking(self: *Scheduler) void {
        const n = self.copyCqesOnIoStack(0);
        if (n > 0) {
            self.processCqes(self.uring_cqes[0..n]);
        }
    }

    /// Flush pending SQEs to the kernel. Called once per scheduler tick
    /// instead of after every individual submit call.
    ///
    /// On failure (EAGAIN, EBUSY): SQEs remain in the ring because flush_sq()
    /// already updated the kernel-visible SQ tail before enter() was called.
    /// The next io_uring_enter (from copy_cqes with wait_nr>0) will process them.
    /// No SQEs are lost; blocked fibers just wait slightly longer.
    pub fn flushRing(self: *Scheduler) void {
        if (self.ring_dirty) {
            self.submitRingOnIoStack();
            self.ring_dirty = false;
        }
    }
};

// ---------------------------------------------------------------------------
// SchedulerRegistry — fully lock-free scheduler lookup.
//
// Fixed-size atomic array of *Scheduler pointers.  No heap allocation,
// no mutex on any hot path.
//
// Hot paths (per-spawn, per-steal):
//   pickTwo():  1 fetchAdd + 2 atomic loads               — O(1), wait-free
//
// Cold paths (once per thread lifetime):
//   register(): 1 fetchAdd + 1 atomic store                — O(1), wait-free
//   unregister(): linear scan + 1 atomic store             — O(N), rare
//
// The round-robin `next` counter cycles consecutive calls through all pairs
// of schedulers, approximating Power-of-Two-Choices without a PRNG.
// ---------------------------------------------------------------------------
pub const SchedulerRegistry = struct {
    const MAX = 64;

    slots: [MAX]std.atomic.Value(?*Scheduler) = [_]std.atomic.Value(?*Scheduler){std.atomic.Value(?*Scheduler).init(null)} ** MAX,
    len: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    next: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    // For backward compat — spawnOn(thread_id) needs ThreadId → *Scheduler.
    // Cold path only (not used by spawnBest or work-stealing).
    id_mutex: compat.Mutex = .{},
    id_map: std.AutoHashMapUnmanaged(std.Thread.Id, *Scheduler) = .{},

    pub const Pair = struct { a: ?*Scheduler, b: ?*Scheduler };

    /// O(1), wait-free.  Returns two scheduler candidates via round-robin.
    /// Callers compare active_tasks to pick the least loaded (Power-of-Two).
    pub fn pickTwo(self: *SchedulerRegistry) Pair {
        const n = self.len.load(.acquire);
        if (n == 0) return .{ .a = null, .b = null };
        if (n == 1) {
            return .{ .a = self.slots[0].load(.acquire), .b = null };
        }
        const i = self.next.fetchAdd(1, .monotonic);
        const a = self.slots[i % n].load(.acquire);
        const b = self.slots[(i +% 1) % n].load(.acquire);
        return .{ .a = a, .b = b };
    }

    /// Backward-compat alias used by the work-stealing idle path.
    pub fn getRandomPair(self: *SchedulerRegistry) Pair {
        return self.pickTwo();
    }

    /// Returns the least loaded of two random candidates (lock-free).
    pub fn getLeastLoaded(self: *SchedulerRegistry) ?*Scheduler {
        const pair = self.pickTwo();
        const a = pair.a orelse return null;
        const b = pair.b orelse return a;
        const la = a.active_tasks.load(.monotonic);
        const lb = b.active_tasks.load(.monotonic);
        return if (la <= lb) a else b;
    }

    /// Cold path.  First tries to reuse a null hole left by unregister;
    /// falls back to appending at len.  This prevents len from growing
    /// unboundedly when threads are repeatedly spawned and killed.
    pub fn register(self: *SchedulerRegistry, allocator: std.mem.Allocator, id: std.Thread.Id, sched: *Scheduler) !void {
        self.id_mutex.lock();
        defer self.id_mutex.unlock();

        // 1. Scan existing slots for a null hole (left by unregister).
        const n = self.len.load(.acquire);
        for (self.slots[0..n], 0..) |*slot, slot_idx| {
            if (slot.load(.acquire) == null) {
                slot.store(sched, .release);
                sched.index = @intCast(slot_idx);
                try self.id_map.put(allocator, id, sched);
                return;
            }
        }

        // 2. No holes — append at the end.
        const idx = self.len.load(.acquire);
        if (idx >= MAX) {
            return error.RegistryFull;
        }
        self.slots[idx].store(sched, .release);
        self.len.store(idx + 1, .release);
        sched.index = @intCast(idx);

        try self.id_map.put(allocator, id, sched);
    }

    /// Cold path.  Marks the scheduler's slot as null (hole).
    /// The round-robin index may hit this null — pickTwo handles it gracefully.
    /// The hole will be reclaimed by the next register() call.
    pub fn unregister(self: *SchedulerRegistry, id: std.Thread.Id) void {
        self.id_mutex.lock();
        defer self.id_mutex.unlock();

        const sched_opt = self.id_map.get(id);
        _ = self.id_map.remove(id);

        if (sched_opt) |sched| {
            const n = self.len.load(.acquire);
            for (self.slots[0..n]) |*slot| {
                if (slot.load(.acquire) == sched) {
                    slot.store(null, .release);
                    break;
                }
            }
        }
    }

    /// Wake all registered schedulers.  Used on shutdown.
    pub fn notifyAll(self: *SchedulerRegistry) void {
        const n = self.len.load(.acquire);
        for (self.slots[0..n]) |*slot| {
            if (slot.load(.acquire)) |sched| {
                sched.event_fd.notify();
            }
        }
    }

    /// Force-wake all registered schedulers. This is for cold shutdown and
    /// watchdog-style test harnesses where a stale coalesced wake token must
    /// not suppress the eventfd write that gets a scheduler out of io_uring.
    pub fn forceNotifyAll(self: *SchedulerRegistry) void {
        const n = self.len.load(.acquire);
        for (self.slots[0..n]) |*slot| {
            if (slot.load(.acquire)) |sched| {
                sched.event_fd.forceNotify();
            }
        }
    }

    /// Free the id_map storage and reset all atomic state.
    /// Safe after all schedulers unregistered.  Required for test reuse.
    pub fn deinit(self: *SchedulerRegistry, allocator: std.mem.Allocator) void {
        // Reset atomic array — clear slots and counters.
        const n = self.len.load(.acquire);
        for (self.slots[0..n]) |*slot| {
            slot.store(null, .release);
        }
        self.len.store(0, .release);
        self.next.store(0, .release);

        // Free id_map backing storage.
        self.id_mutex.lock();
        defer self.id_mutex.unlock();
        self.id_map.deinit(allocator);
        self.id_map = .{};
    }

    /// Cold path: look up scheduler by thread ID (for spawnOn).
    pub fn get(self: *SchedulerRegistry, id: std.Thread.Id) ?*Scheduler {
        self.id_mutex.lock();
        defer self.id_mutex.unlock();
        return self.id_map.get(id);
    }

    /// Number of currently *live* (non-null) registered schedulers.
    /// Distinct from `len`, which is the high-water slot count and
    /// only ever grows: unregister leaves a null hole rather than
    /// decrementing `len`. Callers that gate on "N workers have
    /// registered" (test harnesses, kvstore startup) MUST count
    /// live slots — otherwise stale `len` from prior test runs
    /// reports the new gate as already satisfied before the new
    /// workers register, producing a race where spawnBest's
    /// pickTwo() reads null slots and silently falls back to the
    /// active scheduler. Linear scan is bounded (slots ≤ MAX) and
    /// only invoked from cold setup paths.
    pub fn count(self: *SchedulerRegistry) u32 {
        const n = self.len.load(.acquire);
        var c: u32 = 0;
        for (self.slots[0..n]) |*slot| {
            if (slot.load(.acquire) != null) c += 1;
        }
        return c;
    }
};

// Global instance
pub var global_registry: SchedulerRegistry = .{};

/// Pin handle for safe cross-scheduler Task derefs.
///
/// Returned by `pinTask`. When `allocator != null`, holds a refcount
/// on the slab containing the Task, so the slab's memory cannot be
/// reclaimed while the pin is live. When `allocator == null`, the
/// pin is a no-op handle returned in test/non-production contexts
/// where the global scheduler registry is empty (see pinTask).
///
/// `gen` is the Task's generation captured at pin time; callers
/// compare it against `task.generation` after each field read to
/// detect slot reuse (a TOCTOU window where the slab is alive but
/// the slot has been freed and reallocated to a different logical
/// Task — distinct from the slab being freed entirely, which the
/// slab Ref/epoch mechanism rules out).
pub const TaskPin = struct {
    /// Allocator that owns the slab. null for no-op test pins.
    allocator: ?*SlabAllocator(Task),
    /// Slab containing the Task, with pin_count >= 1 held by us.
    /// Undefined when `allocator == null`.
    slab: *SlabAllocator(Task).SlabHeader,
    /// Snapshot of `task.generation` at pin time. A subsequent read
    /// of `task.generation != gen` means the slot was reused while
    /// we held the pin → the captured ptr now refers to a different
    /// logical Task and the chain walk should treat its observed
    /// fields as torn.
    gen: u32,
};

/// Find the scheduler whose `task_slab` contains `ptr`, then pin
/// the slab against reclamation. Returns null if no live slab in
/// any registered scheduler contains `ptr` (slab freed already, or
/// `ptr` is for a Task that was never slab-allocated by a
/// registered Scheduler).
///
/// **Test mode**: when `global_registry` is empty (e.g. the Loom
/// harness, which constructs a Scheduler manually but never calls
/// `Scheduler.run()` to register it), pinTask returns a no-op pin
/// that does NOT hold any slab refcount. This is structurally
/// safe in test contexts because such tests construct stub Tasks
/// with stable lifetime that outlive any chain walk. It would be
/// unsafe in production, but production always has at least one
/// registered scheduler before any fiber lock is acquired (every
/// fiber comes from a Scheduler that registered itself).
///
/// Cost: O(N_schedulers * N_slabs_per_scheduler) under each
/// scheduler's task_slab lock briefly. Slow path only — used by
/// detectCycle, never on the lock fast path.
pub fn pinTask(ptr: *Task) ?TaskPin {
    const n = global_registry.len.load(.acquire);
    if (n == 0) {
        // No registered schedulers → test/non-production context.
        // Caller's Task lifetime is the caller's responsibility.
        return TaskPin{
            .allocator = null,
            .slab = undefined,
            .gen = ptr.generation.load(.acquire),
        };
    }

    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const sched = global_registry.slots[i].load(.acquire) orelse continue;
        const slab_alloc = &sched.task_slab;
        const ref = slab_alloc.refFromPtr(ptr) orelse continue;
        const slab = slab_alloc.pin(ref) orelse continue;
        // Capture generation AFTER pin — the slab is now guaranteed
        // alive, so the read is safe. The generation may already
        // belong to a successor of the original Task (slot reuse
        // race); the caller's revalidation step catches that.
        return TaskPin{
            .allocator = slab_alloc,
            .slab = slab,
            .gen = ptr.generation.load(.acquire),
        };
    }
    return null;
}

pub fn unpinTask(pin: TaskPin) void {
    if (pin.allocator) |alloc| alloc.unpin(pin.slab);
}

/// Pin handle for safe cross-scheduler FsmTask derefs. Mirrors TaskPin.
///
/// detectCycleFsm walks a chain of `*FsmTask` pointers it discovered
/// through lock back-pointers. Without a pin, the FsmTask's slot can
/// be reused by a different logical task between the moment the
/// walker captured the pointer and the moment it derefs the chain
/// (Option-(C) protocol). `pinFsmTask` holds a refcount on the slab
/// so the underlying memory cannot be reclaimed; `gen` is captured
/// at pin time so callers can detect slot-level reuse.
pub const FsmTaskPin = struct {
    /// Allocator that owns the slab. null for no-op test pins.
    allocator: ?*SlabAllocator(fsm_mod.FsmTask),
    /// Slab containing the FsmTask, with pin_count >= 1 held by us.
    /// Undefined when `allocator == null`.
    slab: *SlabAllocator(fsm_mod.FsmTask).SlabHeader,
    /// Snapshot of `task.generation` at pin time.
    gen: u32,
};

/// Find the scheduler whose `fsm_task_slab` contains `ptr`, then pin
/// the slab against reclamation. Returns null if no live slab in any
/// registered scheduler contains `ptr` (slab freed already, or `ptr`
/// is for an FsmTask that was never slab-allocated by a registered
/// Scheduler — e.g. a Loom-harness stub or a test that bypasses
/// allocFsmTask). Test mode (no registered schedulers) returns a
/// no-op pin, mirroring `pinTask`.
pub fn pinFsmTask(ptr: *fsm_mod.FsmTask) ?FsmTaskPin {
    const n = global_registry.len.load(.acquire);
    if (n == 0) {
        return FsmTaskPin{
            .allocator = null,
            .slab = undefined,
            .gen = ptr.generation.load(.acquire),
        };
    }

    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const sched = global_registry.slots[i].load(.acquire) orelse continue;
        const slab_alloc = &sched.fsm_task_slab;
        const ref = slab_alloc.refFromPtr(ptr) orelse continue;
        const slab = slab_alloc.pin(ref) orelse continue;
        return FsmTaskPin{
            .allocator = slab_alloc,
            .slab = slab,
            .gen = ptr.generation.load(.acquire),
        };
    }
    return null;
}

pub fn unpinFsmTask(pin: FsmTaskPin) void {
    if (pin.allocator) |alloc| alloc.unpin(pin.slab);
}

pub const WaitGroup = struct {
    // The counter must be atomic. Routed through the comptime
    // `Atomic` alias so VOPR's SimAtomic can drive cmpxchg fault
    // injection on the spinlock + counter fetch sites.
    counter: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    // We need to protect the 'waiting_task' pointer itself,
    // because one thread might be writing it (wait) while another reads it (done)
    // 0 = unlocked, 1 = locked
    lock: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    waiting_task: ?*Task = null,
    /// FSM Phase B2 — set by NEXT-on-promise FSM lowering when an FSM
    /// task awaits a Promise's WaitGroup. wakeWaiter dispatches the
    /// stackful or FSM branch based on which slot is non-null.
    /// Single-waiter invariant matches `waiting_task`: each Promise has
    /// its own WaitGroup with count=1 and a single NEXT consumer.
    waiting_fsm: ?*fsm_mod.FsmTask = null,
    sched: *Scheduler,

    pub fn init(sched: *Scheduler) WaitGroup {
        return .{ .sched = sched };
    }

    pub fn add(self: *WaitGroup, count: usize) void {
        _ = self.counter.fetchAdd(count, .seq_cst);
    }

    /// Non-blocking settlement poll. Acquire pairs with done()'s decrement so
    /// observing ready also observes the producer's result write.
    pub fn isReady(self: *const WaitGroup) bool {
        return self.counter.load(.acquire) == 0;
    }

    pub fn done(self: *WaitGroup) void {
        // Take the lock BEFORE the decrement so wait() cannot observe
        // counter==0 and free the WaitGroup while we're still inside this
        // function (UAF on *self). With the lock held, any wait() call must
        // either complete its check before us (saw counter>0, parked, will be
        // woken below) or after us (sees counter==0 only after we release
        // the lock; by that point all our writes to *self are done).
        // VOPR-START-RETRY: WaitGroup.done spinlock acquire
        while (self.lock.swap(1, .acquire) == 1) {
            std.Thread.yield() catch {};
        }
        // VOPR-END-RETRY

        const prev = self.counter.fetchSub(1, .seq_cst);
        if (prev != 1) {
            self.lock.store(0, .release);
            return;
        }

        // counter just dropped to 0 — wake the waiter (if parked).
        const task = self.waiting_task;
        const fsm_task = self.waiting_fsm;
        const sched = self.sched;
        self.waiting_task = null;
        self.waiting_fsm = null;
        self.lock.store(0, .release);

        if (task) |t| {
            // schedule() may cause the waiter to run, return from wait(),
            // and free *self. Do NOT touch self after this point.
            sched.schedule(t);
        }
        if (fsm_task) |ft| {
            // FSM was parked via registerFsmWaiter. submitFsmResume is
            // the bypass-active_tasks-increment variant (the task was
            // counted at original spawn).
            sched.submitFsmResume(ft) catch unreachable;
        }
    }

    /// FSM Phase B2 — register an FSM task to be woken when count→0.
    /// Returns true if registered (caller must yield WaitForLock; the
    /// scheduler's wake path will re-enqueue via submitFsmResume).
    /// Returns false if count is already 0 (no need to suspend; caller
    /// can read the result inline).
    ///
    /// Mirrors the stackful `wait()` registration pattern but does not
    /// itself yield — the FSM's resume fn must return WaitForLock after
    /// this function returns true.
    pub fn registerFsmWaiter(self: *WaitGroup, fsm_task: *fsm_mod.FsmTask) bool {
        if (self.counter.load(.seq_cst) == 0) return false;

        // VOPR-START-RETRY: WaitGroup.registerFsmWaiter spinlock acquire
        while (self.lock.swap(1, .acquire) == 1) {
            std.Thread.yield() catch {};
        }
        // VOPR-END-RETRY

        // Re-check under the lock — count may have hit 0 between the
        // load above and acquiring the lock.
        if (self.counter.load(.seq_cst) == 0) {
            self.lock.store(0, .release);
            return false;
        }

        self.waiting_fsm = fsm_task;
        self.lock.store(0, .release);
        return true;
    }

    // Blocking Wait (Yields Fiber)
    pub fn wait(self: *WaitGroup) void {
        // Completed waitgroups do not need scheduler state. Still take the
        // metadata lock so this synchronizes with done() before callers free self.
        while (self.lock.swap(1, .acquire) == 1) std.Thread.yield() catch {};
        if (self.counter.load(.seq_cst) == 0) {
            self.lock.store(0, .release);
            return;
        }
        self.lock.store(0, .release);

        if (self.sched.current_task == null) {
            // HAMMER-WAIT-LOOP-BEGIN: tag=waitgroup.wait-non-fiber
            // What stalls: a non-fiber caller (typically test code)
            // waits until counter reaches 0. Each iteration acquires
            // the metadata spinlock, checks counter, releases, and
            // yields the OS thread.
            // Yield contract: spinlock acquire uses Thread.yield (not
            // spinLoopHint) because done() may be running in a fiber
            // that yields while holding the lock briefly. After
            // checking counter and releasing the lock, yield the OS
            // thread before the next iteration to let the worker
            // running the fibers make progress.
            //
            // Non-fiber caller (test code): busy-wait. Acquire the lock for
            // the final check so we synchronize-with done()'s release; this
            // makes it safe to free *self after we return.
            // VOPR-START-RETRY: WaitGroup.wait non-fiber busy-wait until counter==0
            while (true) {
                while (self.lock.swap(1, .acquire) == 1) std.Thread.yield() catch {};
                if (self.counter.load(.seq_cst) == 0) {
                    self.lock.store(0, .release);
                    return;
                }
                self.lock.store(0, .release);
                std.Thread.yield() catch {};
            }
            // VOPR-END-RETRY
            // HAMMER-WAIT-LOOP-END: tag=waitgroup.wait-non-fiber
        }

        const task = self.sched.getCurrent();

        // HAMMER-WAIT-LOOP-BEGIN: tag=waitgroup.wait-fiber-park
        // What stalls: the calling fiber waits for counter to reach 0.
        // The recheck loop guards against spurious wakes and against
        // the lockless-fastpath UAF where the wait-side returns and
        // frees *self while done() is still inside its critical
        // section.
        // Yield contract: take the metadata lock (spin-yield until
        // released by done()), check counter, register self as the
        // waiting task under the lock, drop the lock, and yield. done()
        // schedules the waiter when the last decrement crosses 0.
        //
        // VOPR-START-RETRY: WaitGroup.wait fiber park-then-recheck loop
        while (true) {
            // Always take the lock to check counter — synchronizes with done().
            // Without this, the lockless fast-path lets us return + destroy
            // *self while done() is still inside its critical section.
            while (self.lock.swap(1, .acquire) == 1) {
                std.Thread.yield() catch {};
            }

            if (self.counter.load(.seq_cst) == 0) {
                self.lock.store(0, .release);
                return;
            }

            task.status.store(.Blocked, .release);
            self.waiting_task = task;
            self.lock.store(0, .release);

            task.base.yield();
            task.status.store(.Ready, .release);
        }
        // VOPR-END-RETRY
        // HAMMER-WAIT-LOOP-END: tag=waitgroup.wait-fiber-park
    }
};

pub const Semaphore = struct {
    counter: std.atomic.Value(usize),
    lock: std.atomic.Value(u32),
    waiting_task: ?*Task,
    sched: *Scheduler,

    pub fn init(count: usize, sched: *Scheduler) Semaphore {
        return .{
            .counter = std.atomic.Value(usize).init(count),
            .lock = std.atomic.Value(u32).init(0),
            .waiting_task = null,
            .sched = sched,
        };
    }

    /// Acquire one slot. Blocks the calling fiber if no slots are available.
    /// Only one fiber should call acquire() at a time (the spawner loop).
    pub fn acquire(self: *Semaphore) void {
        // HAMMER-WAIT-LOOP-BEGIN: tag=semaphore.acquire-park
        // What stalls: counter is 0 because all slots are held by
        // other fibers. The CAS-loser fast path falls through to a
        // park; release() grants the slot directly to the parked task
        // without re-incrementing counter.
        // Yield contract: CAS decrement is the fast path (no wait).
        // When counter==0, register self as the waiting task under
        // the metadata lock, drop the lock, and yield. release()
        // wakes the parked task with .schedule, which routes through
        // submitResume (cross-thread) or the local ready queue.
        //
        // std.debug.print("ACQUIRE: counter={d}\n", .{self.counter.load(.seq_cst)});
        // VOPR-START-RETRY: Semaphore.acquire CAS-loser + park-recheck loop
        while (true) {
            // Fast path: try CAS decrement
            var c = self.counter.load(.seq_cst);
            while (c > 0) {
                if (self.counter.cmpxchgWeak(c, c - 1, .seq_cst, .seq_cst) == null) {
                    return; // Acquired
                }
                c = self.counter.load(.seq_cst);
            }

            // Slow path: must block
            const task = self.sched.getCurrent();
            task.status.store(.Blocked, .release);

            while (self.lock.swap(1, .acquire) == 1) {
                std.Thread.yield() catch {};
            }
            // Double-check inside lock
            const recheck = self.counter.load(.seq_cst);
            if (recheck > 0) {
                self.lock.store(0, .release);
                task.status.store(.Ready, .release);
                continue;
            }
            self.waiting_task = task;
            self.lock.store(0, .release);

            task.base.yield();
            task.status.store(.Ready, .release);
            // Slot was granted by release() directly — return
            return;
        }
        // VOPR-END-RETRY
        // HAMMER-WAIT-LOOP-END: tag=semaphore.acquire-park
    }

    /// Release one slot. Wakes a blocked acquirer if present; otherwise increments counter.
    pub fn release(self: *Semaphore) void {
        // VOPR-START-RETRY: Semaphore.release spinlock acquire
        while (self.lock.swap(1, .acquire) == 1) {
            std.Thread.yield() catch {};
        }
        // VOPR-END-RETRY
        if (self.waiting_task) |task| {
            // Grant slot directly to waiter (don't increment counter)
            self.waiting_task = null;
            self.lock.store(0, .release);
            self.sched.schedule(task);
        } else {
            self.lock.store(0, .release);
            _ = self.counter.fetchAdd(1, .seq_cst);
        }
    }
};

// We need a global pointer to the active scheduler so the wrapper can find context.
// In a real threaded app, this would be thread-local storage.
pub threadlocal var active_scheduler: *Scheduler = undefined;
// True when a Scheduler has been initialised on this thread (safe to call coopYield).
pub threadlocal var scheduler_running: bool = false;
