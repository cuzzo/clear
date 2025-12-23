const std = @import("std");
const builtin = @import("builtin");

const EbrContext = @import("ebr.zig").EbrContext;
const SlabAllocator = @import("slab-alloc.zig").SlabAllocator;

const linux = std.os.linux;
const posix = std.posix;

// Fibers
// The registers we need to save.
// This layout matches the assembly exactly.
pub const Context = extern struct {
    sp: u64, // Stack Pointer

    // Callee-saved registers for x86_64
    rbx: u64 = 0,
    rbp: u64 = 0,
    r12: u64 = 0,
    r13: u64 = 0,
    r14: u64 = 0,
    r15: u64 = 0,
};

// 1. Declare the external symbol
// Zig will look for this in the .s file we just created.
extern fn switch_context_asm(from: *Context, to: *Context) callconv(.c) void;

// 2. Public Wrapper
pub fn switchContext(from: *Context, to: *Context) void {
    switch_context_asm(from, to);
}

// CHEAT uses VMA Pooling with mprotect and madvise.
// 2MB is not the per-fiber stack memory usage. It's the limit.
// 4KB is the minimum (p95) size.
pub const StackSize = enum {
    Standard,  // 2MB (Fall back to mmap/mprotect)
};

pub const Stack = struct {
    // The raw slice of memory we own
    memory: []u8,

    // Add this helper. Fiber.reset() relies on it.
    pub fn getStackTop(self: Stack) usize {
        const addr = @intFromPtr(self.memory.ptr) + self.memory.len;
        // Align to 16 bytes and back off by 16 bytes
        return (addr & ~@as(usize, 15)) - 16;
    }
};

pub const Fiber = struct {
    stack: Stack,
    ctx: Context,
    parent_ctx: *Context, // Who to jump back to when we yield/finish
    size_class: StackSize,

    pub fn init(memory: []u8, entry_fn: usize) Fiber {
        const stack = Stack{ .memory = memory };

        // CALCULATION: Stack grows DOWN from the end of the memory block.
        const stack_top_addr = @intFromPtr(memory.ptr) + memory.len;

        // ---------------------------------------------------------------------
        // PERFORMANCE FIX: L1 Cache Staggering
        // ---------------------------------------------------------------------
        // Problem: 2MB strides cause every stack to alias to the same L1 Cache Set.
        // Fix: We shift the starting stack pointer by 64 bytes (1 cache line)
        // for every 2MB index. We wrap around every 16KB (half of L1 cache).
        //
        // Math: (Address >> 21) gives us the unique index of this 2MB block.
        // We multiply by 64 to shift one cache line per block.
        // We mask with 0x3FFF to limit the wasted space to 16KB max.
        // ---------------------------------------------------------------------
        const block_index = stack_top_addr >> 21;
        const stagger_offset = (block_index * 64) & 0x3FFF;

        // Align to 16 bytes (x64 requirement) and back off slightly
        // to ensure we don't start at the very edge.
        const stack_top = ((stack_top_addr - stagger_offset) & ~@as(usize, 15)) - 16;

        // THE TRAMPOLINE:
        // We simulate a "Return Address" on the top of the stack.
        // When switchContext executes 'ret', it will pop this address and jump to it.
        const ptr = @as(*usize, @ptrFromInt(stack_top));
        ptr.* = entry_fn;

        return Fiber{
            .stack = stack,
            // Point SP to the address we just wrote.
            // When 'ret' runs, it pops the value AT this pointer.
            .ctx = Context{ .sp = stack_top },
            .parent_ctx = undefined,
            .size_class = .Standard,
        };
    }

    // Switch FROM parent TO this fiber
    pub fn switchTo(self: *Fiber, parent: *Context) void {
        self.parent_ctx = parent;
        switchContext(parent, &self.ctx);
    }

    // Switch FROM this fiber BACK to parent
    pub fn yield(self: *Fiber) void {
        switchContext(&self.ctx, self.parent_ctx);
    }

    // Reset the stack pointer and put the entry function back at the top.
    pub fn reset(self: *Fiber, entry_fn: usize) void {
        const stack_top = self.stack.getStackTop();

        // 1. Rewrite the Trampoline (Return Address)
        const ptr = @as(*usize, @ptrFromInt(stack_top));
        ptr.* = entry_fn;

        // 2. Reset the Context Stack Pointer
        self.ctx.sp = stack_top;

        // No need to clear registers; they get overwritten on switchContext
    }
};

pub const InboxType = enum { Spawn, Resume };

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

pub const TaskStatus = enum {
    Ready,    // Run me again
    Finished, // Recycle me
    Blocked,  // Don't run me, I'm waiting on something
};

pub const TaskConfig = struct {
    timeout_ms: u64 = 0,
    stack_size: StackSize = .Standard,  // Default to Standard
};

pub const Task = struct {
    base: *Fiber,
    user_fn: TaskFn,
    inbox_link: InboxNode = .{ .type = .Resume },
    runtime_ptr: ?*anyopaque = null,
    context: ?*anyopaque = null,
    status: TaskStatus = .Ready,
    config: TaskConfig = .{},
    wake_time: i64 = 0, // Timestamp to wake up (0 = not sleeping - deal with it)
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
        const is_sleeping = (self.state.load(.monotonic) == 1);

        // 2. Only pay the syscall tax if absolutely necessary
        if (is_sleeping) {
            const val: u64 = 1;
            const bytes = std.mem.asBytes(&val);
            // Ignore error, if buffer is full, they are already awake
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

// A generic node header that must be embedded in any struct sent to the Inbox.
pub const InboxNode = struct {
    next: ?*InboxNode = null,
    type: InboxType,
};

// Multi-Producer, Single-Consumer Atomic Stack
// Provides a scalable, thread-safe way to spawn new tasks / fibers
pub const AtomicInbox = struct {
    // The "Head" of the linked list.
    // Producers CAS this to push. Consumer SWAPs this to pop all.
    head: std.atomic.Value(?*InboxNode) = std.atomic.Value(?*InboxNode).init(null),

    /// Producer: Push a single node. Wait-Free.
    pub fn push(self: *AtomicInbox, node: *InboxNode) void {
        var old_head = self.head.load(.monotonic);
        while (true) {
            node.next = old_head;
            // Try to swap Head with Node.
            // If Head is still OldHead, it works. If not, OldHead updates to current.
            old_head = self.head.cmpxchgWeak(
                old_head,
                node,
                .release,
                .monotonic
            ) orelse break;
        }
    }

    /// Consumer: Detach the entire list and return it. Wait-Free.
    pub fn popAll(self: *AtomicInbox) ?*InboxNode {
        // Atomically replace HEAD with NULL. We now own the entire chain.
        return self.head.swap(null, .acquire);
    }

    /// Helper: The list comes out LIFO (Reverse order).
    /// If you strictly need FIFO, call this on the result of popAll.
    pub fn reverse(list: ?*InboxNode) ?*InboxNode {
        var prev: ?*InboxNode = null;
        var curr = list;
        while (curr) |node| {
            const next = node.next;
            node.next = prev;
            prev = node;
            curr = next;
        }
        return prev;
    }
};

// TODO: Deprecate, replaced by Arena
pub const StackPool = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) StackPool {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *StackPool) void {
    }

    pub fn flushLocalCache(_: *StackPool) void {
    }

    // The "Cache Check" happens inside Scheduler before calling this.
    pub fn get(self: *StackPool, entry_fn: usize, size: StackSize) !*Fiber {
        _ = size; // We only support 2MB now

        // Atomic Alloc from Arena
        const memory = try global_arena.allocGlobalSlot();

        // We still allocate the Fiber struct itself.
        // Ideally this comes from a SlabAllocator, but using standard allocator for now as per your code.
        const fiber = try self.allocator.create(Fiber);
        fiber.* = Fiber.init(memory, entry_fn);
        return fiber;
    }

    // This function is deprecated in the new flow.
    pub fn put(self: *StackPool, fiber: *Fiber) void {
        // Scheduler puts memory into its local cache.
        // If we must destroy a fiber struct:
        self.allocator.destroy(fiber);
    }
};


// We reserve 1TB of virtual address space.
// 0 syscalls to sub-divide this. It's just math.
const ARENA_SIZE: usize = 1 * 1024 * 1024 * 1024 * 1024;
const STACK_SIZE: usize = 2 * 1024 * 1024; // 2MB
const MAX_STACKS: usize = ARENA_SIZE / STACK_SIZE;

pub const VirtualArena = struct {
    base_addr: ?[*]u8,

    // Global atomic counter for the "Watermark" of allocated stacks.
    // We only increment this. We never "free" an index back to the global pool
    // to keep it lock-free. Freed stacks go to Thread-Local caches.
    stack_watermark: std.atomic.Value(usize),

    pub fn init() !VirtualArena {
        // HUGE mmap. NO_RESERVE means we don't commit swap/ram.
        // PROT_READ|WRITE means no mprotect needed later.
        const addr = try posix.mmap(
            null,
            ARENA_SIZE,
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true },
            -1,
            0,
        );

        return VirtualArena{
            .base_addr = addr.ptr,
            .stack_watermark = std.atomic.Value(usize).init(0),
        };
    }

    // Returns a POINTER to the start of the stack memory.
    // Hot Path: 1 atomic increment.
    pub fn allocGlobalSlot(self: *VirtualArena) ![]u8 {
        const index = self.stack_watermark.fetchAdd(1, .monotonic);
        if (index >= MAX_STACKS) return error.OutOfMemory;

        const offset = index * STACK_SIZE;
        return self.base_addr.?[offset..offset+STACK_SIZE];
    }
};

pub var global_arena: VirtualArena = .{
    .base_addr = null,
    .stack_watermark = std.atomic.Value(usize).init(0),
};

// TODO: Rename to Deque
pub const RunQueue = struct {
    // Fixed size ring buffer for MVP
    buffer: [256]std.atomic.Value(?*Task) = undefined,
    mask: u32 = 255,

    top: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    bottom: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn init() RunQueue {
        var q = RunQueue{};
        for (&q.buffer) |*slot| slot.* = std.atomic.Value(?*Task).init(null);
        return q;
    }

    // push (bottom) - lock free
    pub fn push(self: *RunQueue, alloc: std.mem.Allocator, task: *Task) !void {
        _ = alloc; // Don't need allocator for fixed buffer

        // Chase-Lev Push Bottom
        const b = self.bottom.load(.monotonic);
        const t = self.top.load(.acquire);

        if (b -% t > self.mask) return error.QueueFull; // MVP limitation

        self.buffer[b & self.mask].store(task, .monotonic);
        self.bottom.store(b +% 1, .release);
    }


    // Chase-Lev Pop Bottom - lock free
    pub fn pop(self: *RunQueue) ?*Task {
        const b = self.bottom.load(.monotonic);
        if (b == 0) return null; // Simplified

        const new_b = b -% 1;
        self.bottom.store(new_b, .seq_cst);
        const t = self.top.load(.monotonic);
        const task = self.buffer[new_b & self.mask].load(.monotonic);

        if (t > new_b) {
            self.bottom.store(b, .monotonic); // Restore
            return null;
        }
        if (t == new_b) {
            // Race with thief
            if (self.top.cmpxchgWeak(t, t +% 1, .seq_cst, .monotonic) != null) {
                self.bottom.store(b, .monotonic); // Lost race
                return null;
            }
            self.bottom.store(b, .monotonic);
            return task;
        }
        return task;
    }

    // Safe length check
    pub fn len(self: *RunQueue) usize {
        const b = self.bottom.load(.monotonic);
        const t = self.top.load(.monotonic);
        if (b >= t) return b - t;
        return 0;
    }

    // Used internally by tryStealFrom
    fn stealOne(self: *RunQueue) ?*Task {
        const t = self.top.load(.acquire);
        const b = self.bottom.load(.seq_cst);

        if (t >= b) return null;

        const task = self.buffer[t & self.mask].load(.monotonic);
        if (self.top.cmpxchgStrong(t, t +% 1, .seq_cst, .monotonic) != null) {
            return null;  // Lost race
        }
        return task;
    }

    // For stealing (Take half, lock free)
    pub fn tryStealFrom(self: *RunQueue, victim: *RunQueue, alloc: std.mem.Allocator, fallback_inbox: *AtomicInbox) usize {
        const v_len = victim.len();
        if (v_len == 0) return 0;

        const target = (v_len + 1) / 2;
        var stolen_count: usize = 0;

        while (stolen_count < target) {
            const task = victim.stealOne() orelse break;

            self.push(alloc, task) catch {
                // FIX: Queue is full, but we already stole the task!
                // We cannot drop it. We must offload it to the inbox.
                task.inbox_link.type = .Resume;
                fallback_inbox.push(&task.inbox_link);

                // We successfully took responsibility for the task, even if we put it in inbox.
                stolen_count += 1;
                continue;
            };
            stolen_count += 1;
        }

        return stolen_count;
    }
};

pub const TaskFn = *const fn (rt: *anyopaque, ctx: ?*anyopaque) anyerror!void;

pub const Scheduler = struct {
    // 1. The Manager State
    fiber_pool: std.ArrayListUnmanaged(*Task) = .{},
    ready_queue: RunQueue,
    stack_cache: std.ArrayListUnmanaged([]u8) = .{},   // LIFO Cache for Stacks
    sleeping_queue: std.ArrayListUnmanaged(*Task) = .{},

    // 2. Communcation
    inbox: AtomicInbox = .{},  // Lock-free Inbox
    stack_pool: *StackPool,    //GLOBAL Stack Cache
    event_fd: SmartEventFd,
    load: std.atomic.Value(isize) = std.atomic.Value(isize).init(0),
    global_shutdown: ?*std.atomic.Value(bool) = null,

    // 3. IO & Memory
    allocator: std.mem.Allocator,
    global_ebr: *EbrContext,
    poller: Poller,

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
            .main_ctx = undefined,
            .current_task = null,
            .active_tasks = std.atomic.Value(usize).init(0),
            .shutdown_on_idle = true,
        };

        try sched.poller.register(sched.event_fd.fd, 0);

        return sched;
    }

    pub fn deinit(self: *Scheduler) void {
        const queues = .{ &self.fiber_pool, &self.sleeping_queue };
        inline for (queues) |q| {
            for (q.items) |task| {
                self.allocator.destroy(task); // Free Task Struct
            }
            q.deinit(self.allocator);
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
                 self.allocator.destroy(task.base);
                 self.allocator.destroy(task);
             }
        }

        self.stack_cache.deinit(self.allocator);
        self.poller.deinit();
    }

    // ------------------------------------------------------------
    // Memory Management
    // ------------------------------------------------------------
    // HOT PATH: Allocating a stack
    fn allocStack(self: *Scheduler) ![]u8 {
        // 1. Check Local Cache (5ns)
        if (self.stack_cache.items.len > 0) {
            const stack = self.stack_cache.pop().?;
            return stack;
        }
        // 2. Fallback to Global Arena (Atomic Increment)
        return global_arena.allocGlobalSlot();
    }

    // HOT PATH: Freeing a stack
    fn freeStack(self: *Scheduler, stack: []u8) void {
        // 1. Push to local cache (Amortized Alloc)
        self.stack_cache.append(self.allocator, stack) catch {
            // Cache full or OOM on arraylist?
            // In a robust system, we might madvise immediately or drop reference.
            // For MVP, if ArrayList fails, we technically leak the VMA mapping (not RAM).
        };
    }

    // IDLE PATH: Scavenge memory (The Cleanup)
    fn scavengeMemory(self: *Scheduler) void {
        // Keep 16 stacks warm, release the rest to OS
        const CACHE_LIMIT = 16;
        while (self.stack_cache.items.len > CACHE_LIMIT) {
            const stack = self.stack_cache.pop().?;
            const aligned_ptr = @as([*]align(4096) u8, @alignCast(stack.ptr));
            // Blocking Syscall! Only call when idle.
            posix.madvise(aligned_ptr, stack.len, linux.MADV.DONTNEED) catch {};
            // We keep the slice in the "air" (virtually mapped),
            // but we drop it from our cache so we don't reuse it immediately?
            // Actually, for a simple cache, we just drop the physical RAM.
            // We can add it back to the cache if we want to reuse the VMA address,
            // OR we can just drop the VMA pointer effectively leaking the virtual address
            // (but saving the RAM).
            // Since we have 1TB, leaking virtual addresses is fine for MVP.
        }
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
        if (global_arena.base_addr == null) {
            global_arena = VirtualArena.init() catch unreachable;
        }

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
            var req_node = self.inbox.popAll();
            // OPTIONALLLY: reverse if we want to preserve FIFO

            while (req_node) |node| {
                const next_node = node.next;

                // Determine what this node is.
                if (node.type == .Spawn) {
                    const req: *SpawnRequest = @fieldParentPtr("inbox_link", node);

                    // 1. GET STACK FROM POOL (Fast!)
                    const stack_mem = self.allocStack() catch |err| {
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
                    fiber_ptr.* = Fiber.init(stack_mem, req.trampoline_addr);

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
                        self.allocator.destroy(req);
                        req_node = next_node; // must advance, or infinite loop
                        continue;
                    };
                    _ = self.active_tasks.fetchAdd(1, .monotonic);

                } else {
                    // It is an existing Task
                    const task: *Task = @fieldParentPtr("inbox_link", node);
                    task.status = .Ready;
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

            // Scavange (ONLY IF IDLE):
            if (self.ready_queue.len() == 0) {
                 // Free excess stacks in local cache back to OS (physically)
                 // Keep 16 hot.
                 while (self.stack_cache.items.len > 16) {
                     const stack = self.stack_cache.pop().?;
                     const aligned_ptr = @as([*]align(4096) u8, @alignCast(stack.ptr));
                     // BLOCKING SYSCALL: Only pay this when truly idle
                     std.posix.madvise(aligned_ptr, stack.len, linux.MADV.DONTNEED) catch {};
                     // We drop the pointer. VMA stays mapped but unused.
                 }
            }

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

    pub fn get(self: *SchedulerRegistry, id: std.Thread.Id) ?*Scheduler {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.map.get(id);
    }
};

// Global instance
pub var global_registry: SchedulerRegistry = .{};

pub const WaitGroup = struct {
    counter: usize = 0,
    waiting_task: ?*Task = null,

    // We need the scheduler to wake people up
    sched: *Scheduler,

    pub fn init(sched: *Scheduler) WaitGroup {
        return .{ .sched = sched };
    }

    pub fn add(self: *WaitGroup, count: usize) void {
        self.counter += count;
    }

    pub fn done(self: *WaitGroup) void {
        self.counter -= 1;
        if (self.counter == 0) {
            if (self.waiting_task) |task| {
                // Wake up the waiter!
                self.sched.schedule(task);
                self.waiting_task = null;
            }
        }
    }

    // This is a blocking call!
    pub fn wait(self: *WaitGroup) void {
        if (self.counter == 0) return;

        var task = self.sched.getCurrent();

        // 1. Mark status as Blocked
        task.status = .Blocked;
        self.waiting_task = task;

        // 2. Yield. The scheduler will see .Blocked and NOT re-queue us.
        task.base.yield();

        // 3. We are back! Reset status for safety
        task.status = .Ready;
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
        try std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_ADD, fd, &event);
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

