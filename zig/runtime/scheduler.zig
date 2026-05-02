const std = @import("std");
const builtin = @import("builtin");

const qs = @import("queues.zig");
const fc = @import("fiber-core.zig");
const fm = @import("fiber-memory.zig");
const compat = @import("../lib/compat.zig");
// Profile telemetry (comptime-gated). Imports are cheap; actual calls
// live inside `if (rt_profile.CLEAR_PROFILE)` blocks that compile away
// when the flag is false.
const rt_profile = @import("runtime-header.zig");
const fp_mod = @import("fiber-profile.zig");
const EbrContext = @import("../lib/ebr.zig").EbrContext;
const SlabAllocator = @import("slab-alloc.zig").SlabAllocator;

fn milliTimestamp() i64 {
    return compat.milliTimestamp();
}

const InboxType = qs.InboxType;
const InboxNode = qs.InboxNode;
const AtomicInbox = qs.AtomicInbox;
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

    // TODO: deprecated
    // Not needed when we trust our sizing, but keeping for safety.
    magic: u64,
};

const FIBER_MAGIC: u64 = 0xDEAD_BEEF_CAFE_BABE;

const SpawnRequest = struct {
    inbox_link: InboxNode = .{ .type = .Spawn },
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
    inbox_link: InboxNode = .{ .type = .RemoteCall },
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
    fd: i32,
    // 0 = Awake (Busy processing), 1 = Sleeping (Waiting on io_uring)
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

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

    // HOT PATH: This is what makes it fast!
    pub fn notify(self: *SmartEventFd) void {
        // Unconditionally write to eventfd.  The previous optimization
        // (skip write when target appears awake) raced with the target's
        // markSleeping/hasChannelMessages/poll sequence, causing missed
        // wakeups that deadlocked pinned fiber yield-poll loops.
        //
        // Cost: ~200ns write() syscall per notify.  Acceptable because
        // notify is called once per submitSpawn/submitResume/sendAndWait,
        // each of which already costs 1-10us for SPSC push + channel drain.
        const val: u64 = 1;
        const bytes = std.mem.asBytes(&val);
        _ = std.c.write(self.fd, bytes.ptr, bytes.len);
    }

    // Called by Scheduler loop to reset the signal drain
    pub fn consume(self: *SmartEventFd) void {
        var val: u64 = 0;
        const buf = std.mem.asBytes(&val);
        // Drain the eventfd buffer
        _ = std.posix.read(self.fd, buf) catch {};
    }

    // Called before entering io_uring wait
    pub fn markSleeping(self: *SmartEventFd) void {
        self.state.store(1, .seq_cst);
    }

    // Called immediately after exiting io_uring wait
    pub fn markAwake(self: *SmartEventFd) void {
        self.state.store(0, .seq_cst);
    }
};

const STACK_CACHE_LIMIT: usize = 128;


pub const Scheduler = struct {
    // 1. The Manager State
    fiber_pool: std.ArrayListUnmanaged(*Task) = .empty,
    ready_queue: RunQueue,
    pinned_queue: std.ArrayListUnmanaged(*Task) = .empty,
    stack_cache: std.ArrayListUnmanaged([]u8) = .empty,   // LIFO Cache for Stacks
    sleeping_queue: std.ArrayListUnmanaged(*Task) = .empty,
    // Fibers parked waiting for a ParkingMutex or ParkingRwLock.
    // Scanned in the run loop's slow path for LOCK_TIMEOUT_MS deadlock detection.
    lock_waiters: std.ArrayListUnmanaged(*Task) = .empty,

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
    stack_pool: *StackPool,    // GLOBAL Stack Cache
    event_fd: SmartEventFd,
    load: std.atomic.Value(isize) = std.atomic.Value(isize).init(0),
    global_shutdown: ?*std.atomic.Value(bool) = null,

    // 3. IO & Memory
    allocator: std.mem.Allocator,
    global_ebr: *EbrContext,

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
    // genuinely sit on contended mutexes longer than that and false-fail.
    // 5s in Debug is still much shorter than Release's 30s and catches
    // real bugs without strangling realistic workloads.
    lock_timeout_ms: i64 = if (builtin.mode == .Debug) 5_000 else 30_000,

    /// Stable index assigned at registration (0..N-1).  Used by
    /// PartitionedStringMap to determine shard ownership.
    index: u32 = 0,

    // Thread-local arena for @arena BG fibers only (use_arena: true).
    // Backed by the scheduler's allocator (c_allocator in production, GPA in debug).
    // Not used by default — only when the CLEAR programmer opts in with @arena.
    local_arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator, global_ebr: *EbrContext, stack_pool: *StackPool) !Scheduler {
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

        const sched = Scheduler{
            .stack_pool = stack_pool,
            .fiber_pool = .empty,
            .ready_queue = try RunQueue.initWithAllocator(allocator),
            .stack_cache = .empty,
            .sleeping_queue = .empty,
            .event_fd = efd,
            .load = std.atomic.Value(isize).init(0),
            .allocator = allocator,
            .global_ebr = global_ebr,
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
        const queues = .{ &self.fiber_pool, &self.sleeping_queue };
        inline for (queues) |q| {
            for (q.items) |task| {
                if (task.base.stack.memory.len > 0) {
                     self.freeStack(task.base.stack.memory);
                }
                self.allocator.destroy(task.base); // Free Fiber
                self.allocator.destroy(task); // Free Task Struct
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
                 self.freeStack(task.base.stack.memory);
                 self.allocator.destroy(task.base);
                 self.allocator.destroy(task);
             }
        }
        self.ready_queue.deinit();
        for (self.pinned_queue.items) |task| {
            self.freeStack(task.base.stack.memory);
            self.allocator.destroy(task.base);
            self.allocator.destroy(task);
        }
        self.pinned_queue.deinit(self.allocator);

        self.stack_pool.flushLocalCache();
        self.stack_cache.deinit(self.allocator);
        for (&self.channels) |*ch| {
            if (ch.load(.acquire)) |ring| self.allocator.destroy(ring);
        }
        self.local_arena.deinit();
        self.allocator.free(self.io_helper_stack);
        self.ring.deinit();
    }

    // ------------------------------------------------------------
    // Memory Management
    // ------------------------------------------------------------
    // HOT PATH: Allocating a stack.
    // The L1 cache (stack_cache) holds only Standard-sized stacks.
    // Non-standard sizes bypass the cache and go directly to the pool slab.
    fn allocStack(self: *Scheduler, size: StackSize) ![]u8 {
        if (size == .Standard and self.stack_cache.items.len > 0) {
            return self.stack_cache.pop().?;
        }
        return self.stack_pool.alloc(size);
    }

    // HOT PATH: Freeing a stack.
    // Standard-sized stacks are kept in the L1 cache for fast reuse.
    // All other sizes are returned directly to the pool slab.
    fn freeStack(self: *Scheduler, stack: []u8) void {
        if (stack.len == STANDARD_STACK_SIZE and self.stack_cache.items.len < STACK_CACHE_LIMIT) {
            self.stack_cache.append(self.allocator, stack) catch {
                self.stack_pool.free(stack);
            };
        } else {
            self.stack_pool.free(stack);
        }
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
        };
        // Wait-and-work: if ring is full, drain our own channels + yield
        while (!ring.push(msg)) {
            if (scheduler_running) {
                active_scheduler.drainChannels();
                active_scheduler.coopYield();
            } else {
                std.Thread.yield() catch {};
            }
        }
        _ = self.dirty_mask.fetchOr(@as(u64, 1) << @intCast(sender_idx), .seq_cst);
        self.event_fd.notify();
    }

    // ------------------------------------------------------------
    // 2. THE RESUME (Producer Side - Thread B, WaitGroup, etc)
    // ------------------------------------------------------------
    pub fn submitResume(self: *Scheduler, task: *Task) void {
        // Double-push guard
        if (task.in_inbox.load(.acquire)) return;
        task.in_inbox.store(true, .release);

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
        // Wait-and-work
        while (!ring.push(msg)) {
            if (scheduler_running) {
                active_scheduler.drainChannels();
                active_scheduler.coopYield();
            } else {
                std.Thread.yield() catch {};
            }
        }
        _ = self.dirty_mask.fetchOr(@as(u64, 1) << @intCast(sender_idx), .seq_cst);
        self.event_fd.notify();
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
                        };
                        const effective_size = cp.recommendSize(
                            if (msg.user_fn) |f| @intFromPtr(f) else 0,
                            config.stack_size,
                        );
                        const stack_mem = self.allocStack(effective_size) catch continue;
                        const task = blk: {
                            const fiber_ptr = self.allocator.create(Fiber) catch {
                                self.freeStack(stack_mem);
                                continue;
                            };
                            fiber_ptr.* = Fiber.init(stack_mem, msg.trampoline_addr, effective_size);
                            const t = self.allocator.create(Task) catch {
                                self.freeStack(stack_mem);
                                self.allocator.destroy(fiber_ptr);
                                continue;
                            };
                            // Zero-initialize all fields via aggregate init, then
                            // set the fiber pointer. This ensures wake_time,
                            // inbox_link, etc. are properly initialized — not garbage
                            // from the allocator.
                            t.* = Task{ .base = fiber_ptr, .user_fn = msg.user_fn.? };
                            if (rt_profile.CLEAR_PROFILE) {
                                t.spawn_ns = fp_mod.nowNs();
                            }
                            break :blk t;
                        };
                        task.context = msg.args;
                        task.status.store(.Ready, .release);
                        task.config = config;
                        if (task.config.pinned) {
                            self.pinned_queue.append(self.allocator, task) catch {
                                self.freeStack(stack_mem);
                                self.allocator.destroy(task);
                                continue;
                            };
                        } else {
                            self.ready_queue.push(self.allocator, task) catch {
                                self.freeStack(stack_mem);
                                self.fiber_pool.append(self.allocator, task) catch
                                    self.allocator.destroy(task);
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

        const my_id = std.Thread.getCurrentId();

        // Ensure thread-locals always point to this scheduler when run() is
        // called. Tests that set these before calling run() get the same value;
        // tests that omit the setup (relying on implicit state from a previous
        // test) get the correct scheduler without fragile stack-address aliasing.
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
                if (flag.load(.monotonic)) break;
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

            // ── Fast path: if any queue has work, run it immediately.
            if (self.hasWork()) {
                self.fast_path_counter +%= 1;
                self.drainChannels();
                self.pollNonBlocking();
            } else {
                // ── Slow path: no ready work — check all sources.
                self.drainChannels();

                // Wake sleeping tasks
                if (self.sleeping_queue.items.len > 0) {
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
            } // end slow path

            // Look for tasks ready to start:
            if (self.hasWork()) {
                // Pinned queue first (owner-local, no steal contention).
                const task = if (self.pinned_queue.items.len > 0)
                    self.pinned_queue.swapRemove(0)
                else
                    (self.ready_queue.pop() orelse continue);
                self.current_task = task;

                // Clear the double-push guard now that the task is
                // dequeued.  Keeping in_inbox true from submitResume
                // until here prevents duplicate pushes via concurrent
                // cross-thread resumes while the task sat in the queue.
                task.in_inbox.store(false, .release);

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
                }
                // 1. Switch to the Task
                task.base.switchTo(&self.main_ctx);

                // Clear pinned allocator — we're back on the scheduler's context.
                __pinned_local_alloc = null;

                switch (task.status.load(.acquire)) {
                    .Finished => {
                        if (rt_profile.CLEAR_PROFILE) {
                            fp_mod.recordFiberExit(task.spawn_ns, fp_mod.nowNs());
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
                        self.freeStack(task.base.stack.memory);
                        self.allocator.destroy(task.base);
                        self.allocator.destroy(task);
                    },
                    .Ready => {
                        // It yielded, but wants to run again. If a concurrent
                        // wake already queued it through submitResume, honor the
                        // in_inbox guard and avoid a duplicate enqueue.
                        if (!task.in_inbox.load(.acquire)) {
                            self.enqueueTask(task);
                        }
                    },
                    .Blocked => {
                        // Do nothing! It is now owned by the WaitGroup/Mutex/Etc.
                        // It will be added back to ready_queue by someone else later.
                    }
                }
                continue; // Keep looping if we have work!
            }

            // Look for tasks to steal (ONLY IF IDLE):
            if (!self.hasWork()) {
                const pair = global_registry.getRandomPair();
                if (pair.b) |victim| {
                    // Don't steal from myself
                    if (victim != self) {
                        // Lock the victim's queue and take half tasks
                        const stolen = self.ready_queue.tryStealFrom(&victim.ready_queue, self.allocator);
                        if (stolen > 0) {
                            // update my queue size to account for steals
                            _ = self.active_tasks.fetchAdd(stolen, .monotonic);
                            // update victim queue size to account for steals
                            _ = victim.active_tasks.fetchSub(stolen, .monotonic);
                        }
                    }
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
            if (self.lock_waiters.items.len > 0) {
                // Arm the wait for the earliest lock-waiter deadline so an
                // otherwise-idle scheduler still wakes up to fire the
                // timeout. Without this, io_uring_enter blocks forever and
                // lock_timeout_ms is a no-op.
                const now_ms = milliTimestamp();
                var earliest_ms: i64 = now_ms + self.lock_timeout_ms;
                for (self.lock_waiters.items) |t| {
                    if (t.waiting_for_lock.load(.monotonic) == null) continue;
                    const deadline = t.lock_wait_start_ms + self.lock_timeout_ms;
                    if (deadline < earliest_ms) earliest_ms = deadline;
                }
                const ms_until = @max(@as(i64, 1), earliest_ms - now_ms);
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

            // A. Announce we are going to sleep
            self.event_fd.markSleeping();

            // B. The Double Check
            // We must check for new work ONE LAST TIME after setting the flag.
            // If we don't do this, a task could arrive between our last check
            // and the 'markSleeping' call, and we would sleep forever.
            if (self.hasWork() or self.hasChannelMessages()) {
                self.event_fd.markAwake();
                continue; // Restart loop to process the new work
            }

            // C. Actually Sleep -- wait for at least `wait_nr` CQEs.
            const count = self.copyCqesOnIoStack(wait_nr);

            // D. We are awake
            self.event_fd.markAwake();

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
                self.sleeping_queue.items.len == 0)
            {
                self.scavengeMemory(true);
                break;
            }
        }
    }

    // Helper to wake a specific fiber
    // TODO: Deprecate
    pub fn schedule(self: *Scheduler, task: *Task) void {
        self.submitResume(task);
    }

    // Helper to get current task
    pub fn getCurrent(self: *Scheduler) *Task {
        return self.current_task.?;
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

    fn hasWork(self: *Scheduler) bool {
        return self.ready_queue.len() > 0 or self.pinned_queue.items.len > 0;
    }

    pub noinline fn coopYield(self: *Scheduler) void {
        if (self.hasWork()) {
            const task = self.getCurrent();
            task.status.store(.Ready, .release);
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

    // Register a lock-parked task for timeout scanning.
    // Called by parking-lot.zig before the fiber yields.
    // The task's waiting_for_lock / waiting_for_lock_list / lock_waiter_node
    // must already be set by the caller.
    pub fn registerLockWaiter(self: *Scheduler, task: *Task) void {
        task.lock_wait_start_ms = milliTimestamp();
        self.lock_waiters.append(self.allocator, task) catch {};
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
    const EVENTFD_SENTINEL: u64 = 0;
    const TIMEOUT_SENTINEL: u64 = 1;

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
        fn decode(user_data: u64) *IoWaiter {
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
            const deadline = task.lock_wait_start_ms + self.lock_timeout_ms;
            if (now_ms - task.lock_wait_start_ms > self.lock_timeout_ms) {
                // Timed out: remove from lock's waiter list, then wake.
                var removed = false;
                if (task.waiting_for_lock_list) |wl| {
                    wl.spinAcquire();
                    removed = wl.remove(task.lock_waiter_node.?);
                    wl.spinRelease();
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
                task.lock_timed_out = true;
                task.waiting_for_lock.store(null, .release);
                task.waiting_for_lock_list = null;
                task.lock_waiter_node = null;
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
            } else if (ud & 1 == 1) {
                // IoWaiter: file I/O completion (READ, WRITE, etc.)
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
        // 1. Scan existing slots for a null hole (left by unregister).
        const n = self.len.load(.acquire);
        for (self.slots[0..n], 0..) |*slot, slot_idx| {
            // CAS null → sched.  If another thread races us for the same
            // hole, exactly one wins; the loser continues scanning.
            if (slot.cmpxchgStrong(null, sched, .acq_rel, .monotonic) == null) {
                sched.index = @intCast(slot_idx);
                // Won the slot — record in id_map and return.
                self.id_mutex.lock();
                defer self.id_mutex.unlock();
                try self.id_map.put(allocator, id, sched);
                return;
            }
        }

        // 2. No holes — append at the end.
        const idx = self.len.fetchAdd(1, .acq_rel);
        if (idx >= MAX) {
            _ = self.len.fetchSub(1, .acq_rel);
            return error.RegistryFull;
        }
        sched.index = @intCast(idx);
        self.slots[idx].store(sched, .release);

        self.id_mutex.lock();
        defer self.id_mutex.unlock();
        try self.id_map.put(allocator, id, sched);
    }

    /// Cold path.  Marks the scheduler's slot as null (hole).
    /// The round-robin index may hit this null — pickTwo handles it gracefully.
    /// The hole will be reclaimed by the next register() call.
    pub fn unregister(self: *SchedulerRegistry, id: std.Thread.Id) void {
        self.id_mutex.lock();
        const sched_opt = self.id_map.get(id);
        _ = self.id_map.remove(id);
        self.id_mutex.unlock();

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

    /// Number of currently registered schedulers.
    pub fn count(self: *SchedulerRegistry) u32 {
        return self.len.load(.acquire);
    }
};

// Global instance
pub var global_registry: SchedulerRegistry = .{};

pub const WaitGroup = struct {
    // The counter must be atomic
    counter: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    // We need to protect the 'waiting_task' pointer itself,
    // because one thread might be writing it (wait) while another reads it (done)
    // 0 = unlocked, 1 = locked
    lock: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    waiting_task: ?*Task = null,
    sched: *Scheduler,

    pub fn init(sched: *Scheduler) WaitGroup {
        return .{ .sched = sched };
    }

    pub fn add(self: *WaitGroup, count: usize) void {
        _ = self.counter.fetchAdd(count, .seq_cst);
    }

    pub fn done(self: *WaitGroup) void {
        // Take the lock BEFORE the decrement so wait() cannot observe
        // counter==0 and free the WaitGroup while we're still inside this
        // function (UAF on *self). With the lock held, any wait() call must
        // either complete its check before us (saw counter>0, parked, will be
        // woken below) or after us (sees counter==0 only after we release
        // the lock; by that point all our writes to *self are done).
        while (self.lock.swap(1, .acquire) == 1) {
            std.Thread.yield() catch {};
        }

        const prev = self.counter.fetchSub(1, .seq_cst);
        if (prev != 1) {
            self.lock.store(0, .release);
            return;
        }

        // counter just dropped to 0 — wake the waiter (if parked).
        const task = self.waiting_task;
        const sched = self.sched;
        self.waiting_task = null;
        self.lock.store(0, .release);

        if (task) |t| {
            // schedule() may cause the waiter to run, return from wait(),
            // and free *self. Do NOT touch self after this point.
            sched.schedule(t);
        }
    }

    // Blocking Wait (Yields Fiber)
    pub fn wait(self: *WaitGroup) void {
        if (self.sched.current_task == null) {
            // Non-fiber caller (test code): busy-wait. Acquire the lock for
            // the final check so we synchronize-with done()'s release; this
            // makes it safe to free *self after we return.
            while (true) {
                while (self.lock.swap(1, .acquire) == 1) std.Thread.yield() catch {};
                if (self.counter.load(.seq_cst) == 0) {
                    self.lock.store(0, .release);
                    return;
                }
                self.lock.store(0, .release);
                std.Thread.yield() catch {};
            }
        }

        const task = self.sched.getCurrent();

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
        // std.debug.print("ACQUIRE: counter={d}\n", .{self.counter.load(.seq_cst)});
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
    }

    /// Release one slot. Wakes a blocked acquirer if present; otherwise increments counter.
    pub fn release(self: *Semaphore) void {
        while (self.lock.swap(1, .acquire) == 1) {
            std.Thread.yield() catch {};
        }
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "ioError: common errno values" {
    // EINVAL = 22
    const err1 = Scheduler.ioError(-22);
    try std.testing.expectEqual(error.Unexpected, err1);

    // ENOMEM = 12
    const err2 = Scheduler.ioError(-12);
    try std.testing.expectEqual(error.Unexpected, err2);

    // ENOSPC = 28
    const err3 = Scheduler.ioError(-28);
    try std.testing.expectEqual(error.Unexpected, err3);

    // EIO = 5
    const err4 = Scheduler.ioError(-5);
    try std.testing.expectEqual(error.Unexpected, err4);
}

test "ioError: boundary errno values" {
    // -1 (EPERM) -- smallest valid errno
    const err1 = Scheduler.ioError(-1);
    try std.testing.expectEqual(error.Unexpected, err1);

    // -4095 -- largest errno the kernel returns (MAX_ERRNO)
    const err2 = Scheduler.ioError(-4095);
    try std.testing.expectEqual(error.Unexpected, err2);
}

test "ioError: i32 min does not overflow" {
    // This is the case that overflows with naive `-waiter.result` on i32.
    // The i64 widening in ioError prevents undefined behavior.
    const err = Scheduler.ioError(std.math.minInt(i32));
    try std.testing.expectEqual(error.Unexpected, err);
}

test "IoWaiter: encode/decode roundtrip" {
    var dummy_fiber = fc.Fiber{
        .stack = fc.Stack{ .memory = &[_]u8{} },
        .ctx = fc.Context{ .sp = 0 },
        .parent_ctx = undefined,
        .size_class = .Standard,
        .stack_limit = 0,
        .stack_guard_head = null,
    };
    var task = qs.Task{
        .base = &dummy_fiber,
        .user_fn = @ptrCast(&dummyTaskFn),
        .status = qs.Atomic(qs.TaskStatus).init(.Ready),
        .config = .{},
    };
    var waiter = Scheduler.IoWaiter{ .task = &task };
    const encoded = waiter.encode();
    // Bit 0 must be set (IoWaiter tag)
    try std.testing.expect(encoded & 1 == 1);
    // Decode must recover the original pointer
    const decoded = Scheduler.IoWaiter.decode(encoded);
    try std.testing.expectEqual(&waiter, decoded);
    try std.testing.expectEqual(&task, decoded.task);
}

test "IoWaiter: encode is distinct from sentinels" {
    var dummy_fiber = fc.Fiber{
        .stack = fc.Stack{ .memory = &[_]u8{} },
        .ctx = fc.Context{ .sp = 0 },
        .parent_ctx = undefined,
        .size_class = .Standard,
        .stack_limit = 0,
        .stack_guard_head = null,
    };
    var task = qs.Task{
        .base = &dummy_fiber,
        .user_fn = @ptrCast(&dummyTaskFn),
        .status = qs.Atomic(qs.TaskStatus).init(.Ready),
        .config = .{},
    };
    var waiter = Scheduler.IoWaiter{ .task = &task };
    const encoded = waiter.encode();
    // Must not collide with EVENTFD_SENTINEL (0) or TIMEOUT_SENTINEL (1)
    try std.testing.expect(encoded != Scheduler.EVENTFD_SENTINEL);
    try std.testing.expect(encoded != Scheduler.TIMEOUT_SENTINEL);
}

fn dummyTaskFn(_: *anyopaque, _: ?*anyopaque) anyerror!void {}
