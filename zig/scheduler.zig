const std = @import("std");
const builtin = @import("builtin");

const qs = @import("queues.zig");
const fc = @import("fiber-core.zig");
const fm = @import("fiber-memory.zig");
const EbrContext = @import("ebr.zig").EbrContext;
const SlabAllocator = @import("slab-alloc.zig").SlabAllocator;

fn milliTimestamp() i64 {
    const ts = std.posix.clock_gettime(.MONOTONIC) catch return 0;
    return @intCast(ts.sec * 1000 + @divFloor(ts.nsec, 1_000_000));
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

/// Thread-local allocator for @pinned tasks.  Set by the scheduler
/// before switching to a pinned task; cleared after the task yields.
/// The Runtime reads this in heapAlloc() to avoid the global GPA.
pub threadlocal var __pinned_local_alloc: ?std.mem.Allocator = null;

const linux = std.os.linux;
const posix = std.posix;
const IoUring = linux.IoUring;

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


// A thread-safe wake-up signal
pub const SmartEventFd = struct {
    fd: i32,
    // 0 = Awake (Busy processing), 1 = Sleeping (Waiting on Epoll)
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn init() !SmartEventFd {
        // EFD_SEMAPHORE: Reads decrement counter by 1.
        // We use this so we can consume exactly one wake-up if needed.
        const flags = std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK | std.os.linux.EFD.SEMAPHORE;
        const fd = try std.posix.eventfd(0, flags);
        return SmartEventFd{ .fd = fd };
    }

    pub fn deinit(self: *SmartEventFd) void {
        std.posix.close(self.fd);
    }

    // HOT PATH: This is what makes it fast!
    pub fn notify(self: *SmartEventFd) void {
        // 1. Check if the scheduler is actually sleeping
        // We utilize 'monotonic' for the load because strict ordering isn't
        // strictly required here; if we miss a race, the scheduler loops anyway.
        const is_sleeping = (self.state.load(.seq_cst) == 1);

        // 2. Only pay the syscall tax if absolutely necessary
        if (is_sleeping) {
            const val: u64 = 1;
            const bytes = std.mem.asBytes(&val);
            // Ignore error, if buffer is full, they are already awake
            // TODO: This must be fixed before release.
            _ = std.posix.write(self.fd, bytes) catch {};
        }
    }

    // Called by Scheduler loop to reset the signal drain
    pub fn consume(self: *SmartEventFd) void {
        var val: u64 = 0;
        const buf = std.mem.asBytes(&val);
        // Drain the eventfd buffer
        _ = std.posix.read(self.fd, buf) catch {};
    }

    // Called before entering epoll
    pub fn markSleeping(self: *SmartEventFd) void {
        self.state.store(1, .seq_cst);
    }

    // Called immediately after exiting epoll
    pub fn markAwake(self: *SmartEventFd) void {
        self.state.store(0, .seq_cst);
    }
};

const STACK_CACHE_LIMIT: usize = 16;


pub const Scheduler = struct {
    // 1. The Manager State
    fiber_pool: std.ArrayListUnmanaged(*Task) = .{},
    ready_queue: RunQueue,
    stack_cache: std.ArrayListUnmanaged([]u8) = .{},   // LIFO Cache for Stacks
    sleeping_queue: std.ArrayListUnmanaged(*Task) = .{},

    // 2. Communication — Pure SPSC (no MPSC linked list)
    /// SPSC channels: lazily allocated, one per potential sender (max 64).
    /// channels[i] is the ring FROM scheduler i TO this scheduler.
    /// Null until first message is sent on that channel (~288 KB per ring).
    /// Messages are value-copied — no linked lists, no pointer reuse.
    channels: [64]?*spsc.DefaultRing = [_]?*spsc.DefaultRing{null} ** 64,
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
    poller: Poller,

    // 4a. io_uring — used for async file I/O (readFile).
    // Network I/O stays on epoll.  The ring fd is registered with epoll so the
    // scheduler's existing event loop drains CQEs alongside socket events.
    ring: IoUring,
    uring_cqes: [128]linux.io_uring_cqe = undefined,

    // 4. Main Thread Context (To return to OS)
    main_ctx: Context,
    current_task: ?*Task,

    // Buffer for epoll events (reused)
    // Max of 128 for now, likely want to increase
    // Only works on Linux
    epoll_events: [128]std.os.linux.epoll_event = undefined,

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

    /// Stable index assigned at registration (0..N-1).  Used by
    /// PartitionedStringMap to determine shard ownership.
    index: u32 = 0,

    // Thread-local arena for @pinned tasks.  Pinned tasks use this
    // instead of the global heap allocator — zero locks, zero contention.
    // The arena is backed by the scheduler's own allocator (page-level).
    local_arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator, global_ebr: *EbrContext, stack_pool: *StackPool) !Scheduler {
        const p = Poller.init() catch unreachable;
        const efd = try SmartEventFd.init();

        // io_uring ring for async file I/O (256 SQE slots).
        const ring = try IoUring.init(256, 0);
        var sched = Scheduler{
            .stack_pool = stack_pool,
            .fiber_pool = .{},
            .ready_queue = .{},
            .stack_cache = .{},
            .sleeping_queue = .{},
            .event_fd = efd,
            .load = std.atomic.Value(isize).init(0),
            .allocator = allocator,
            .global_ebr = global_ebr,
            .poller = p,
            .ring = ring,
            .main_ctx = undefined,
            .current_task = null,
            .active_tasks = std.atomic.Value(usize).init(0),
            .shutdown_on_idle = true,
            // Use c_allocator as backing for per-scheduler arenas.
            // This avoids GPA mutex contention when pinned fibers allocate
            // concurrently on different schedulers — libc malloc has per-thread arenas.
            // Use the same allocator as the scheduler for arena backing.
            // When USE_C_ALLOCATOR is set, this is c_allocator (per-thread arenas,
            // zero contention). When GPA, it's GPA (with leak detection).
            .local_arena = std.heap.ArenaAllocator.init(allocator),
        };

        try sched.poller.registerPersistent(sched.event_fd.fd, 0);

        // Register the io_uring fd with epoll so CQE readiness wakes the
        // scheduler from epoll_wait.  Use a sentinel user_data value (1) to
        // distinguish from the eventfd sentinel (0) and task pointers (>4096).
        try sched.poller.registerPersistent(ring.fd, 1);

        // Initialize the RunQueue buffer to null. The default `= undefined`
        // leaves 65536 slots as garbage; in ReleaseFast, stealOne() can read
        // garbage pointers from uninitialized slots, causing use-after-free.
        for (&sched.ready_queue.buffer) |*slot| slot.* = std.atomic.Value(?*Task).init(null);

        return sched;
    }

    pub fn deinit(self: *Scheduler) void {
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
             const task_opt = self.ready_queue.buffer[i & self.ready_queue.mask].load(.monotonic);
             if (task_opt) |task| {
                 self.freeStack(task.base.stack.memory);
                 self.allocator.destroy(task.base);
                 self.allocator.destroy(task);
             }
        }

        self.stack_pool.flushLocalCache();
        self.stack_cache.deinit(self.allocator);
        for (&self.channels) |*ch| {
            if (ch.*) |ring| self.allocator.destroy(ring);
        }
        self.local_arena.deinit();
        self.ring.deinit();
        self.poller.deinit();
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
    fn ensureChannel(self: *Scheduler, idx: usize) !*spsc.DefaultRing {
        if (self.channels[idx]) |ring| return ring;
        const ring = try self.allocator.create(spsc.DefaultRing);
        ring.* = .{};
        self.channels[idx] = ring;
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
        _ = self.dirty_mask.fetchOr(@as(u64, 1) << @intCast(sender_idx), .release);
        self.event_fd.notify();
    }

    // ------------------------------------------------------------
    // 2. THE RESUME (Producer Side - Thread B, WaitGroup, etc)
    // ------------------------------------------------------------
    pub fn submitResume(self: *Scheduler, task: *Task) void {
        // Double-push guard
        if (task.in_inbox.load(.acquire)) return;
        task.in_inbox.store(true, .release);

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
        _ = self.dirty_mask.fetchOr(@as(u64, 1) << @intCast(sender_idx), .release);
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
            const ch = self.channels[sender_idx] orelse continue;
            while (true) {
                const peeked = ch.peek() orelse break;
                if (peeked.tag != .RemoteCall) break; // leave for main loop
                // It's a RemoteCall — pop and execute
                _ = ch.pop();
                const func = peeked.rc_func.?;
                const ctx = peeked.rc_ctx.?;
                func(ctx);
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
            const ch = self.channels[sender_idx] orelse continue;
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
                            // set the fiber pointer. This ensures epoll_fd, wake_time,
                            // inbox_link, etc. are properly initialized — not garbage
                            // from the allocator.
                            t.* = Task{ .base = fiber_ptr, .user_fn = msg.user_fn.? };
                            break :blk t;
                        };
                        task.context = msg.args;
                        task.status.store(.Ready, .release);
                        task.config = config;
                        self.ready_queue.push(self.allocator, task) catch {
                            self.freeStack(stack_mem);
                            self.fiber_pool.append(self.allocator, task) catch
                                self.allocator.destroy(task);
                            continue;
                        };
                        _ = self.active_tasks.fetchAdd(1, .monotonic);
                    },
                    .Resume => {
                        const task: *Task = @ptrCast(@alignCast(msg.task.?));
                        task.in_inbox.store(false, .release);
                        task.status.store(.Ready, .release);
                        self.ready_queue.push(self.allocator, task) catch unreachable;
                    },
                    .RemoteCall => {
                        if (self.draining) {
                            std.debug.print("RE-ENTRANT DRAIN: sched={d}\n", .{self.index});
                            @panic("re-entrant drainChannels detected in RemoteCall");
                        }
                        self.draining = true;
                        const func = msg.rc_func.?;
                        const ctx = msg.rc_ctx.?;
                        func(ctx);
                        self.draining = false;
                    },
                }
            }
        }
    }

    fn hasChannelMessages(self: *Scheduler) bool {
        return self.dirty_mask.load(.monotonic) != 0;
    }

    pub fn run(self: *Scheduler) void {

        const my_id = std.Thread.getCurrentId();

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

            // ── Fast path: if the ready_queue has work, run it immediately.
            // Every 64 fast-path iterations, drain inbox + poll epoll to
            // pick up newly spawned tasks and wake I/O-blocked fibers.
            if (self.ready_queue.len() > 0) {
                self.fast_path_counter +%= 1;
                // Drain RemoteCalls every iteration (O(1) when empty).
                self.drainRemoteCalls();
                if (self.fast_path_counter & 63 == 0) {
                    self.drainChannels();
                }
                // Non-blocking epoll poll EVERY iteration: wake I/O-blocked
                // fibers that have data ready. This is critical for I/O servers
                // where one fiber with pipelined data can monopolize the scheduler.
                // epoll_wait(timeout=0) is ~100ns when empty — acceptable overhead.
                self.pollEpollNonBlocking();
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
                            self.ready_queue.push(self.allocator, task) catch unreachable;
                        } else {
                            i += 1;
                        }
                    }
                }
            } // end slow path

            // Look for tasks ready to start:
            if (self.ready_queue.len() > 0) {
                // pop() can return null if a thief stole the last task between
                // the len() check and this pop() (TOCTOU race). Not an error.
                const task = self.ready_queue.pop() orelse continue;
                self.current_task = task;

                // Set task identity for the control plane.
                // If this task overflows its stack, __zig_alloc_segment
                // reads these to record which task class needs upsizing.
                fc.__current_task_fn = @intFromPtr(task.user_fn);
                fc.__current_task_size = task.base.size_class;

                // For @pinned tasks, expose the thread-local arena so the
                // Runtime's heapAlloc() can use it instead of the global GPA.
                if (task.config.pinned) {
                    __pinned_local_alloc = self.local_arena.allocator();
                }

                // 1. Switch to the Task
                task.base.switchTo(&self.main_ctx);

                // Clear pinned allocator — we're back on the scheduler's context.
                __pinned_local_alloc = null;

                switch (task.status.load(.acquire)) {
                    .Finished => {
                        _ = self.active_tasks.fetchSub(1, .monotonic);
                        self.freeStack(task.base.stack.memory);
                        self.allocator.destroy(task.base);
                        self.allocator.destroy(task);
                    },
                    .Ready => {
                        // It yielded, but wants to run again. Put back in queue.
                        self.ready_queue.push(self.allocator, task) catch unreachable;
                    },
                    .Blocked => {
                        // Do nothing! It is now owned by the WaitGroup/Mutex/Etc.
                        // It will be added back to ready_queue by someone else later.
                    }
                }
                continue; // Keep looping if we have work!
            }

            // Look for tasks to steal (ONLY IF IDLE):
            if (self.ready_queue.len() == 0) {
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

            // Drain any io_uring completions before sleeping.  This catches CQEs
            // that arrived while we were busy running fibers, without waiting for
            // epoll to fire on the ring fd.
            self.drainCqes();
            if (self.ready_queue.len() > 0) continue;

            // IF IDLE: Poll for IO
            // Determine timeout based on next timer
            // If we have a sleeper in 50ms, poll(50). If empty, poll(-1) [Wait Forever].
            var timeout: i32 = -1;

            if (self.sleeping_queue.items.len > 0) {
                // Simplification: Just poll for 1ms if we have timers pending
                timeout = 1;
            }
            else if (self.shutdown_on_idle and self.active_tasks.load(.monotonic) == 0) {
                timeout = 0;
            }

            // A. Announce we are going to sleep
            self.event_fd.markSleeping();

            // B. The Double Check
            // We must check for new work ONE LAST TIME after setting the flag.
            // If we don't do this, a task could arrive between our last check
            // and the 'markSleeping' call, and we would sleep forever.
            if (self.ready_queue.len() > 0 or self.hasChannelMessages()) {
                self.event_fd.markAwake();
                continue; // Restart loop to process the new work
            }

            // C. Actually Sleep
            const count = self.poller.poll(&self.epoll_events, timeout);

            // D. We are awake
            self.event_fd.markAwake();

            if (count > 0) {
                for (self.epoll_events[0..count]) |event| {
                    const data_ptr = event.data.ptr;

                    // CHECK: Is this the Wake Up Signal?
                    if (data_ptr == 0) {
                        self.event_fd.consume();
                    }
                    // CHECK: Is this the io_uring ring fd? (sentinel = 1)
                    else if (data_ptr == 1) {
                        self.drainCqes();
                    }
                    else {
                        // IO Task Wakeup: CAS from Blocked → Ready.
                        // Only the winner pushes to the ready queue.
                        // This prevents double-push when a stale epoll event
                        // races with the task being woken by another path.
                        const task = @as(*Task, @ptrFromInt(data_ptr));
                        if (task.status.cmpxchgStrong(.Blocked, .Ready, .acq_rel, .monotonic) == null) {
                            self.ready_queue.push(self.allocator, task) catch unreachable;
                        }
                    }
                }
            }

            // If no IO and no Tasks and no Sleepers -> Break
            if (self.shutdown_on_idle and count == 0 and self.ready_queue.len() == 0 and self.sleeping_queue.items.len == 0) {
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
    pub noinline fn coopYield(self: *Scheduler) void {
        if (self.ready_queue.len() > 0) {
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

    // Register fd for read-readiness with this scheduler's epoll.
    // If the fd was previously registered with a DIFFERENT scheduler (fiber
    // was stolen), unregister from the old one first to prevent double-wake.
    pub fn registerFd(self: *Scheduler, fd: i32, task: *Task) !void {
        if (task.epoll_fd >= 0 and task.epoll_fd != self.poller.epoll_fd) {
            // Unregister from old scheduler's epoll
            std.posix.epoll_ctl(task.epoll_fd, std.os.linux.EPOLL.CTL_DEL, fd, null) catch {};
        }
        task.epoll_fd = self.poller.epoll_fd;
        task.epoll_io_fd = fd;
        try self.poller.register(fd, @intFromPtr(task));
    }

    // Register fd for write-readiness (used by socketWrite EAGAIN path).
    pub fn registerWriteFd(self: *Scheduler, fd: i32, task: *Task) !void {
        if (task.epoll_fd >= 0 and task.epoll_fd != self.poller.epoll_fd) {
            std.posix.epoll_ctl(task.epoll_fd, std.os.linux.EPOLL.CTL_DEL, fd, null) catch {};
        }
        task.epoll_fd = self.poller.epoll_fd;
        task.epoll_io_fd = fd;
        try self.poller.registerWrite(fd, @intFromPtr(task));
    }

    // Remove fd from epoll (called by socketClose before closing the fd).
    pub fn unregisterFd(self: *Scheduler, fd: i32) void {
        self.poller.unregister(fd);
    }

    // -----------------------------------------------------------------
    // io_uring helpers — async file I/O
    // -----------------------------------------------------------------

    /// Per-operation handle placed on the fiber's (blocked) stack frame.
    /// Its address goes into the SQE user_data field.  The scheduler
    /// writes the CQE result before waking the fiber, so the fiber
    /// reads `waiter.result` immediately after resume.
    pub const IoWaiter = struct {
        task: *Task,
        result: i32 = undefined,
    };

    /// Submit an IORING_OP_READ for `fd` into `buffer` and park `waiter.task`.
    pub fn submitRead(self: *Scheduler, waiter: *IoWaiter, fd: posix.fd_t, buffer: []u8) !void {
        _ = try self.ring.read(@intFromPtr(waiter), fd, .{ .buffer = buffer }, 0);
        _ = try self.ring.submit();
        waiter.task.status.store(.Blocked, .release);
    }

    /// Drain all ready CQEs from the io_uring, writing the result into each
    /// IoWaiter and pushing the corresponding task back onto the ready queue.
    // Non-blocking epoll poll: check for I/O readiness without sleeping.
    // Wakes any Blocked fibers whose fds have data ready.
    fn pollEpollNonBlocking(self: *Scheduler) void {
        const count = self.poller.poll(&self.epoll_events, 0);
        if (count > 0) {
            for (self.epoll_events[0..count]) |event| {
                const data_ptr = event.data.ptr;
                if (data_ptr == 0) {
                    self.event_fd.consume();
                } else if (data_ptr == 1) {
                    self.drainCqes();
                } else {
                    const task: *Task = @ptrFromInt(data_ptr);
                    if (task.status.cmpxchgStrong(.Blocked, .Ready, .acq_rel, .monotonic) == null) {
                        self.ready_queue.push(self.allocator, task) catch unreachable;
                    }
                }
            }
        }
    }

    fn drainCqes(self: *Scheduler) void {
        const n = self.ring.copy_cqes(&self.uring_cqes, 0) catch return;
        for (self.uring_cqes[0..n]) |cqe| {
            const waiter: *IoWaiter = @ptrFromInt(cqe.user_data);
            waiter.result = cqe.res;
            waiter.task.status.store(.Ready, .release);
            self.ready_queue.push(self.allocator, waiter.task) catch unreachable;
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
    id_mutex: std.Thread.Mutex = .{},
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
        // Atomic Decrement
        const prev = self.counter.fetchSub(1, .seq_cst);

        // If we just dropped to 0 (prev was 1), we must wake the waiter.
        if (prev == 1) {
            self.wakeWaiter();
        }
    }

    fn wakeWaiter(self: *WaitGroup) void {
        // Spinlock to grab the waiter
        while (self.lock.swap(1, .acquire) == 1) {
            std.Thread.yield() catch {};
        }

        const task = self.waiting_task;
        const sched = self.sched;
        // Clear state BEFORE scheduling — once the waiter is scheduled, it may
        // immediately wake, consume the result, and free the WaitGroup (Promise Inner).
        // Accessing self after schedule() would be use-after-free.
        self.waiting_task = null;
        self.lock.store(0, .release);

        if (task) |t| {
            sched.schedule(t);
        }
    }

    // Blocking Wait (Yields Fiber)
    pub fn wait(self: *WaitGroup) void {
        // Fast path: already done
        if (self.counter.load(.seq_cst) == 0) return;

        // 1. Get current task
        const task = self.sched.getCurrent();
        task.status.store(.Blocked, .release);

        // 2. Register as waiter (Spinlock protected)
        // CRITICAL: We must check counter *inside* the lock or right before/after
        // to avoid the "Lost Wakeup" race where done() happens between check and sleep.
        while (self.lock.swap(1, .acquire) == 1) {
             std.Thread.yield() catch {};
        }

        // Double Check inside lock: Did it finish while we were acquiring lock?
        if (self.counter.load(.seq_cst) == 0) {
            self.lock.store(0, .release);
            task.status.store(.Ready, .release); // Undo status change
            return;
        }

        self.waiting_task = task;
        self.lock.store(0, .release);

        // 3. Yield control
        task.base.yield();

        // 4. Back (Reset status)
        task.status.store(.Ready, .release);
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

// Poller lets us make IO & other sys calls without blocking
// Without this, green fibers are pretty much useless
// This only works on Linux for now
pub const Poller = struct {
    epoll_fd: i32,

    // This only works on Linux for now
    pub fn init() !Poller {
        // Create epoll instance
        // flags=0 is standard
        const fd = try std.posix.epoll_create1(0);
        return Poller{ .epoll_fd = fd };
    }

    pub fn deinit(self: *Poller) void {
        std.posix.close(self.epoll_fd);
    }

    // Register a fd for persistent edge-triggered monitoring (no ONESHOT).
    // Used ONLY for scheduler-internal fds (eventfd, io_uring ring fd) that
    // must fire on every edge without re-arming.
    pub fn registerPersistent(self: *Poller, fd: i32, user_data: usize) !void {
        var event = std.os.linux.epoll_event{
            .events = std.os.linux.EPOLL.IN | std.os.linux.EPOLL.ET,
            .data = .{ .ptr = user_data },
        };
        std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_ADD, fd, &event) catch |err| {
            if (err == error.FileDescriptorAlreadyPresentInSet) {
                try std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_MOD, fd, &event);
            } else return err;
        };
    }

    // Register a file descriptor (socket) to watch for READ events.
    // user_data: We will store the *Task pointer here so we know who to wake up.
    // ONESHOT: the fd is disabled after each event, preventing stale events
    // when a fiber is stolen to another scheduler. Re-armed on next WouldBlock.
    pub fn register(self: *Poller, fd: i32, user_data: usize) !void {
        var event = std.os.linux.epoll_event{
            .events = std.os.linux.EPOLL.IN | std.os.linux.EPOLL.ET | std.os.linux.EPOLL.ONESHOT,
            .data = .{ .ptr = user_data },
        };
        // Try CTL_ADD first; if the fd is already registered (e.g. after a prior
        // socketConnect registered it for EPOLLOUT), fall back to CTL_MOD.
        std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_ADD, fd, &event) catch |err| {
            if (err == error.FileDescriptorAlreadyPresentInSet) {
                try std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_MOD, fd, &event);
            } else return err;
        };
    }

    // Register a file descriptor to watch for WRITE readiness (non-blocking sends).
    // ONESHOT: disabled after each event to prevent stale cross-scheduler wakes.
    pub fn registerWrite(self: *Poller, fd: i32, user_data: usize) !void {
        var event = std.os.linux.epoll_event{
            .events = std.os.linux.EPOLL.OUT | std.os.linux.EPOLL.ET | std.os.linux.EPOLL.ONESHOT,
            .data = .{ .ptr = user_data },
        };
        // Use MOD if already registered for reads, ADD if new.
        std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_MOD, fd, &event) catch |err| {
            if (err == error.FileDescriptorNotRegistered) {
                try std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_ADD, fd, &event);
            } else return err;
        };
    }

    // Remove a fd from epoll. Safe to call even if fd was never registered.
    pub fn unregister(self: *Poller, fd: i32) void {
        std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_DEL, fd, null) catch {};
    }

    // Wait for events. Returns the number of events ready.
    // events: A slice to store the results
    // timeout_ms: How long to sleep if nothing happens (-1 = forever, 0 = return immediately)
    // Only works on Linux
    pub fn poll(self: *Poller, events: []std.os.linux.epoll_event, timeout_ms: i32) usize {
        const count = std.os.linux.epoll_wait(self.epoll_fd, events.ptr, @intCast(events.len), timeout_ms);
        return count;
    }
};

// We need a global pointer to the active scheduler so the wrapper can find context.
// In a real threaded app, this would be thread-local storage.
pub threadlocal var active_scheduler: *Scheduler = undefined;
// True when a Scheduler has been initialised on this thread (safe to call coopYield).
pub threadlocal var scheduler_running: bool = false;

