const std = @import("std");
const builtin = @import("builtin");

const qs = @import("queues.zig");
const fc = @import("fiber-core.zig");
const fm = @import("fiber-memory.zig");
const EbrContext = @import("ebr.zig").EbrContext;
const SlabAllocator = @import("slab-alloc.zig").SlabAllocator;

const InboxType = qs.InboxType;
const InboxNode = qs.InboxNode;
const AtomicInbox = qs.AtomicInbox;
const RunQueue = qs.RunQueue;
const Task = qs.Task;
const TaskStatus = qs.TaskStatus;
pub const TaskConfig = qs.TaskConfig;
const TaskFn = qs.TaskFn;

const Context = fc.Context;
const switchContext = fc.switchContext;
const Fiber = fc.Fiber;
const Stack = fc.Stack;
const StackSize = fc.StackSize;

const StackPool = fm.StackPool;
const STANDARD_STACK_SIZE = fm.STANDARD_STACK_SIZE;

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

    // 2. Communcation
    inbox: AtomicInbox = .{},  // Lock-free Inbox
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

    pub fn init(allocator: std.mem.Allocator, global_ebr: *EbrContext, stack_pool: *StackPool) !Scheduler {
        const p = Poller.init() catch unreachable;
        const efd = try SmartEventFd.init();

        // io_uring ring for async file I/O (256 SQE slots).
        const ring = try IoUring.init(256, 0);

        var sched = Scheduler{
            .stack_pool = stack_pool,
            .fiber_pool = .{},
            .ready_queue = .{},
            .stack_cache = .{}, // probs needs to be unmanaged
            .sleeping_queue = .{},
            .inbox = .{},
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
        };

        try sched.poller.register(sched.event_fd.fd, 0);

        // Register the io_uring fd with epoll so CQE readiness wakes the
        // scheduler from epoll_wait.  Use a sentinel user_data value (1) to
        // distinguish from the eventfd sentinel (0) and task pointers (>4096).
        try sched.poller.register(ring.fd, 1);

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

        var node = AtomicInbox.reverse(self.inbox.popAll());
        while (node) |n| {
            const next = n.next;
            if (n.type == .Resume) {
                 const task: *Task = @fieldParentPtr("inbox_link", n);
                 // Free the stack
                 if (task.base.stack.memory.len > 0) {
                     self.freeStack(task.base.stack.memory);
                 }
                 // Free the structs
                 self.allocator.destroy(task.base);
                 self.allocator.destroy(task);
            } else if (n.type == .Spawn) {
                 const req: *SpawnRequest = @fieldParentPtr("inbox_link", n);
                 self.allocator.destroy(req);
            }
            node = next;
        }

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
    // 1. THE SPAWN (Producer Side - Thread A)
    // ------------------------------------------------------------
    pub fn submitSpawn(self: *Scheduler, trampoline_addr: usize, user_fn: TaskFn, args: ?*anyopaque, config: TaskConfig) !void {
        const req = try self.allocator.create(SpawnRequest);
        req.* = .{
            .inbox_link = .{.type = .Spawn},
            .user_fn = user_fn,
            .args = args,
            .context = null, // TODO: remove the field from struct
            .config = config,
            .trampoline_addr = trampoline_addr,
        };

        // Push to target's inbox (Lock Free)
        self.inbox.push(&req.inbox_link);

        // Wake up target
        self.event_fd.notify();
    }

    // ------------------------------------------------------------
    // 2. THE RESUME (Producer Side - Thread B, WaitGroup, etc)
    // ------------------------------------------------------------
    pub fn submitResume(self: *Scheduler, task: *Task) void {
        task.inbox_link.type = .Resume;

        // Push the existing task back to the inbox
        // Note: Task now has an 'inbox_link' field
        self.inbox.push(&task.inbox_link);

        // Wake up target (ignore error in hot path)
        self.event_fd.notify();
    }

    pub fn run(self: *Scheduler) void {
        const my_id = std.Thread.getCurrentId();

        std.debug.print("[Sched {d}] Registering...\n", .{my_id});

        global_registry.register(self.allocator, std.Thread.getCurrentId(), self) catch |err| {
            std.debug.print("SCHEDULER REGISTRATION FAILED: {}\n", .{err});
            return;
        };

        defer {
            std.debug.print("[Sched {d}] Exiting & Unregistering...\n", .{my_id});
            global_registry.unregister(my_id);
        }

        std.debug.print("[Sched {d}] Loop Started\n", .{my_id});

        while (true) {
            if (self.global_shutdown) |flag| {
                if (flag.load(.monotonic)) break;
            }

            // run all to-be-scheduled tasks
            var req_node = AtomicInbox.reverse(self.inbox.popAll());

            while (req_node) |node| {
                const next_node = node.next;

                // Determine what this node is.
                if (node.type == .Spawn) {
                    const req: *SpawnRequest = @fieldParentPtr("inbox_link", node);

                    // 1. GET STACK FROM POOL (Fast!)
                    const stack_mem = self.allocStack(req.config.stack_size) catch |err| {
                        std.debug.print("Stack Alloc Failed: {}\n", .{err});
                        self.allocator.destroy(req);
                        req_node = next_node;
                        continue;
                    };

                    const fiber_ptr = self.allocator.create(Fiber) catch {
                        self.freeStack(stack_mem); // Return memory to cache
                        self.allocator.destroy(req);
                        req_node = next_node; // Must advance, or infinite loop
                        continue;
                    };
                    fiber_ptr.* = Fiber.init(stack_mem, req.trampoline_addr, req.config.stack_size);

                    // 2. Alloc Task shell (local allocator)
                    const task = self.allocator.create(Task) catch {
                        self.freeStack(stack_mem);
                        self.allocator.destroy(fiber_ptr);
                        self.allocator.destroy(req);
                        req_node = next_node; // Must advance, or infinite loop
                        continue;
                    };

                    task.* = .{
                        .base = fiber_ptr,
                        .user_fn = req.user_fn,
                        .context = req.args,
                        .status = .Ready,
                        .config = req.config,
                        .inbox_link = .{ .type = .Resume } // When it comes back, it's a resume
                    };

                    // Cleanup Request
                    self.allocator.destroy(req);

                    self.ready_queue.push(self.allocator, task) catch {
                        // If we can't queue the task, we must rollback everything
                        self.freeStack(stack_mem); // Save the fiber
                        self.allocator.destroy(task);   // Destroy the task
                        req_node = next_node; // must advance, or infinite loop
                        continue;
                    };
                    _ = self.active_tasks.fetchAdd(1, .monotonic);

                } else {
                    // It is an existing Task
                    const task: *Task = @fieldParentPtr("inbox_link", node);
                    task.status = .Ready;
                    // TODO: There must be a fix here before release.
                    self.ready_queue.push(self.allocator, task) catch unreachable;
                }

                req_node = next_node;
            }

            // Look for beautiful sleeping tasks to wake up
            if (self.sleeping_queue.items.len > 0) {
                const now = std.time.milliTimestamp();
                var i: usize = 0;
                while (i < self.sleeping_queue.items.len) {
                    const task = self.sleeping_queue.items[i];
                    if (now >= task.wake_time) {
                        // WAKE UP, Sleeping Beauty! It's me, your scheduler!
                        // Remove from sleeping queue (O(1) swap remove)
                        _ = self.sleeping_queue.swapRemove(i);

                        // Add to ready queue
                        task.status = .Ready;
                        self.ready_queue.push(self.allocator, task) catch unreachable;

                        // Don't increment 'i' because we just swapped a new item here
                    } else {
                        i += 1;
                    }
                }
            }

            // Look for tasks ready to start:
            if (self.ready_queue.len() > 0) {
                const task = self.ready_queue.pop().?;
                self.current_task = task;

                // 1. Switch to the Task
                // The task will resume inside 'entryWrapper' (if new)
                // or wherever it yielded (if old).
                task.base.switchTo(&self.main_ctx);

                switch (task.status) {
                    .Finished => {
                        // Recycle
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
                        const stolen = self.ready_queue.tryStealFrom(&victim.ready_queue, self.allocator, &self.inbox);
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
            if (self.ready_queue.len() > 0 or self.inbox.head.load(.monotonic) != null) {
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
                        // It's a standard IO Task Wakeup
                        const task = @as(*Task, @ptrFromInt(data_ptr));
                        task.status = .Ready;
                        self.ready_queue.push(self.allocator, task) catch unreachable;
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
    pub fn coopYield(self: *Scheduler) void {
        if (self.ready_queue.len() > 0) {
            const task = self.getCurrent();
            task.status = .Ready;
            task.base.yield();
            // Resumed here — task.status remains .Ready (scheduler sets nothing on resume)
        }
    }

    // Lay this beautiful task to rest until a specific time
    pub fn sleepTask(self: *Scheduler, task: *Task, wake_time: i64) void {
        task.wake_time = wake_time;
        task.status = .Blocked;
        self.sleeping_queue.append(self.allocator, task) catch unreachable;
    }

    // Helper to do IO
    pub fn registerFd(self: *Scheduler, fd: i32, task: *Task) !void {
        // We cast the task pointer to usize to store it in epoll user_data
        try self.poller.register(fd, @intFromPtr(task));
    }

    // Register fd for write-readiness (used by socketWrite EAGAIN path).
    pub fn registerWriteFd(self: *Scheduler, fd: i32, task: *Task) !void {
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
        waiter.task.status = .Blocked;
    }

    /// Drain all ready CQEs from the io_uring, writing the result into each
    /// IoWaiter and pushing the corresponding task back onto the ready queue.
    fn drainCqes(self: *Scheduler) void {
        const n = self.ring.copy_cqes(&self.uring_cqes, 0) catch return;
        for (self.uring_cqes[0..n]) |cqe| {
            const waiter: *IoWaiter = @ptrFromInt(cqe.user_data);
            waiter.result = cqe.res;
            waiter.task.status = .Ready;
            self.ready_queue.push(self.allocator, waiter.task) catch unreachable;
        }
    }
};

pub const SchedulerRegistry = struct {
    mutex: std.Thread.Mutex = .{},
    // Map Thread ID -> *Scheduler
    map: std.AutoHashMapUnmanaged(std.Thread.Id, *Scheduler) = .{},

    // Helper for Load Balancing
    pub const Pair = struct { a: ?*Scheduler, b: ?*Scheduler };

    pub fn getRandomPair(self: *SchedulerRegistry) Pair {
        self.mutex.lock();
        defer self.mutex.unlock();

        const count = self.map.count();
        if (count == 0) return .{ .a = null, .b = null };

        // Linear scan is okay for N < 100. For large N, keep a separate ArrayList of keys.
        // We'll just grab the first two we find for this simple implementation.
        // In prod: use a PRNG to pick indices.

        var it = self.map.valueIterator();
        const a = it.next().?.*;
        const b = if (it.next()) |ptr| ptr.* else a; // If only 1 exists, compare against self

        return .{ .a = a, .b = b };
    }

    pub fn register(self: *SchedulerRegistry, allocator: std.mem.Allocator, id: std.Thread.Id, sched: *Scheduler) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.map.put(allocator, id, sched);
    }

    pub fn unregister(self: *SchedulerRegistry, id: std.Thread.Id) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.map.remove(id);
    }

    /// Free the registry's internal hash map storage.
    /// Safe to call after all schedulers have been unregistered.
    /// Resets to empty state so the registry can be reused.
    pub fn deinit(self: *SchedulerRegistry, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.map.deinit(allocator);
        self.map = .{};
    }

    pub fn get(self: *SchedulerRegistry, id: std.Thread.Id) ?*Scheduler {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.map.get(id);
    }

    /// Returns the scheduler with the fewest active tasks (least loaded).
    /// Falls back to current scheduler's registry entry if only one is registered.
    pub fn getLeastLoaded(self: *SchedulerRegistry) ?*Scheduler {
        self.mutex.lock();
        defer self.mutex.unlock();
        var best: ?*Scheduler = null;
        var best_load: usize = std.math.maxInt(usize);
        var it = self.map.valueIterator();
        while (it.next()) |ptr| {
            const sched = ptr.*;
            const load = sched.active_tasks.load(.monotonic);
            if (load < best_load) {
                best_load = load;
                best = sched;
            }
        }
        return best;
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
        defer self.lock.store(0, .release);

        if (self.waiting_task) |task| {
            self.sched.schedule(task);
            self.waiting_task = null;
        }
    }

    // Blocking Wait (Yields Fiber)
    pub fn wait(self: *WaitGroup) void {
        // Fast path: already done
        if (self.counter.load(.seq_cst) == 0) return;

        // 1. Get current task
        const task = self.sched.getCurrent();
        task.status = .Blocked;

        // 2. Register as waiter (Spinlock protected)
        // CRITICAL: We must check counter *inside* the lock or right before/after
        // to avoid the "Lost Wakeup" race where done() happens between check and sleep.
        while (self.lock.swap(1, .acquire) == 1) {
             std.Thread.yield() catch {};
        }

        // Double Check inside lock: Did it finish while we were acquiring lock?
        if (self.counter.load(.seq_cst) == 0) {
            self.lock.store(0, .release);
            task.status = .Ready; // Undo status change
            return;
        }

        self.waiting_task = task;
        self.lock.store(0, .release);

        // 3. Yield control
        task.base.yield();

        // 4. Back (Reset status)
        task.status = .Ready;
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
            task.status = .Blocked;

            while (self.lock.swap(1, .acquire) == 1) {
                std.Thread.yield() catch {};
            }
            // Double-check inside lock
            const recheck = self.counter.load(.seq_cst);
            if (recheck > 0) {
                self.lock.store(0, .release);
                task.status = .Ready;
                continue;
            }
            self.waiting_task = task;
            self.lock.store(0, .release);

            task.base.yield();
            task.status = .Ready;
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

    // Register a file descriptor (socket) to watch for READ events
    // user_data: We will store the *Task pointer here so we know who to wake up
    // Only works on Linux
    pub fn register(self: *Poller, fd: i32, user_data: usize) !void {
        var event = std.os.linux.epoll_event{
            .events = std.os.linux.EPOLL.IN | std.os.linux.EPOLL.ET, // Read + Edge Triggered
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
    pub fn registerWrite(self: *Poller, fd: i32, user_data: usize) !void {
        var event = std.os.linux.epoll_event{
            .events = std.os.linux.EPOLL.OUT | std.os.linux.EPOLL.ET,
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

