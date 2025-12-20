const std = @import("std");
const EbrContext = @import("ebr.zig").EbrContext;

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

pub const Stack = struct {
    // The raw slice of memory we own
    memory: []align(4096) u8,

    // The usable size (excluding the guard page)
    usable_len: usize,

    // How big we want the guard to be (usually 4KB, one OS page)
    const PAGE_SIZE: usize = 4096;

    pub fn init(size: usize) !Stack {
        // 1. Round up to page size to keep the OS happy
        const total_size = std.mem.alignForward(usize, size + PAGE_SIZE, PAGE_SIZE);

        // 2. Ask OS for memory
        // PROT_READ | PROT_WRITE: We can read and write
        // MAP_PRIVATE | MAP_ANONYMOUS: Private memory, not backed by a file
        const ptr = try std.posix.mmap(
            null,
            total_size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        );
        const slice = ptr[0..total_size];

        // 3. The Magic: "Poison" the bottom page
        // We tell the OS: "If anyone touches the first 4KB, kill the process."
        // This is our hardware stack-overflow protection.
        try std.posix.mprotect(slice[0..PAGE_SIZE], std.posix.PROT.NONE // No permissions at all
        );

        return Stack{
            .memory = slice,
            .usable_len = total_size - PAGE_SIZE,
        };
    }

    pub fn deinit(self: *Stack) void {
        // Return memory to OS
        std.posix.munmap(self.memory);
    }

    // CRITICAL: Stacks grow DOWN (High -> Low).
    // So the "Start" of the stack is actually the END of the memory block.
    // We return a pointer slightly offset from the top to be safe.
    pub fn getStackTop(self: *Stack) usize {
        const top = @intFromPtr(self.memory.ptr) + self.memory.len;
        // Align to 16 bytes (x64 requirement) and back off a tiny bit
        return (top & ~@as(usize, 15)) - 16;
    }
};

pub const Fiber = struct {
    stack: Stack,
    ctx: Context,
    parent_ctx: *Context, // Who to jump back to when we yield/finish

    pub fn init(stack_size: usize, entry_fn: usize) !Fiber {
        var stack = try Stack.init(stack_size);
        const stack_top = stack.getStackTop();

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
        };
    }

    pub fn deinit(self: *Fiber) void {
        self.stack.deinit();
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


pub const TaskStatus = enum {
    Ready,    // Run me again
    Finished, // Recycle me
    Blocked,  // Don't run me, I'm waiting on something
};

pub const TaskConfig = struct {
    timeout_ms: u64 = 0,
};

pub const Task = struct {
    base: Fiber,
    user_fn: TaskFn,
    runtime_ptr: ?*anyopaque = null,
    context: ?*anyopaque = null,
    status: TaskStatus = .Ready,
    config: TaskConfig = .{},
    wake_time: i64 = 0, // Timestamp to wake up (0 = not sleeping - deal with it)
};

// A thread-safe wake-up signal
pub const EventFd = struct {
    fd: i32,

    pub fn init() !EventFd {
        // EFD_NONBLOCK: Don't block on read/write
        // EFD_CLOEXEC: Standard safety
        const fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
        return EventFd{ .fd = fd };
    }

    pub fn deinit(self: *EventFd) void {
        std.posix.close(self.fd);
    }

    // Wake up the other thread! (Write 1 to the counter)
    pub fn notify(self: *EventFd) !void {
        const val: u64 = 1;
        const bytes = std.mem.asBytes(&val);
        _ = try std.posix.write(self.fd, bytes);
    }

    // Reset the signal (Read the counter)
    pub fn consume(self: *EventFd) !void {
        var val: u64 = 0;
        const buf = std.mem.asBytes(&val);
        _ = try std.posix.read(self.fd, buf);
    }
};

pub const TaskFn = *const fn (rt: *anyopaque, ctx: ?*anyopaque) anyerror!void;

pub const Scheduler = struct {
    // 1. The Manager State
    fiber_pool: std.ArrayListUnmanaged(*Task) = .{},
    ready_queue: std.ArrayListUnmanaged(*Task) = .{},
    sleeping_queue: std.ArrayListUnmanaged(*Task) = .{},

    // 2. Communcation
    inbox_mutex: std.Thread.Mutex = .{},
    inbox: std.ArrayListUnmanaged(*Task) = .{},
    event_fd: EventFd,
    load: std.atomic.Value(isize) = std.atomic.Value(isize).init(0),

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

    active_tasks: usize = 0,

    pub fn init(allocator: std.mem.Allocator, global_ebr: *EbrContext) !Scheduler {
        const p = Poller.init() catch unreachable;
        const efd = try EventFd.init();

        var sched = Scheduler{
            .fiber_pool = .{},
            .ready_queue = .{},
            .sleeping_queue = .{},
            .inbox = .{},
            .event_fd = efd,
            .load = std.atomic.Value(isize).init(0),
            .allocator = allocator,
            .global_ebr = global_ebr,
            .poller = p,
            .main_ctx = undefined,
            .current_task = null,
        };

        try sched.poller.register(sched.event_fd.fd, 0);

        return sched;
    }

    pub fn deinit(self: *Scheduler) void {
        // Cleanup all memory
        for (self.fiber_pool.items) |task| {
            task.base.deinit();
            self.allocator.destroy(task);
        }
        self.fiber_pool.deinit(self.allocator);

        for (self.ready_queue.items) |task| {
            task.base.deinit();
            self.allocator.destroy(task);
        }
        self.ready_queue.deinit(self.allocator);

        for (self.sleeping_queue.items) |task| {
            task.base.deinit();
            self.allocator.destroy(task);
        }
        self.sleeping_queue.deinit(self.allocator);

        self.poller.deinit();
    }

    pub fn pushRemote(self: *Scheduler, task: *Task) !void {
        {
            self.inbox_mutex.lock();
            defer self.inbox_mutex.unlock();
            _ = self.load.fetchAdd(1, .monotonic);
            try self.inbox.append(self.allocator, task);
        }
        // WAKE UP!
        try self.event_fd.notify();
    }

    // THE BRIDGE: Connects Fibers to the Runtime
    pub fn spawn(
        self: *Scheduler,
        trampoline_addr: usize, // <--- NEW ARGUMENT
        config: TaskConfig,
        runtime_ptr: *anyopaque,
        user_fn: TaskFn, ctx: ?*anyopaque
    ) !void {
        var task: *Task = undefined;

        if (self.fiber_pool.items.len > 0) {
            task = self.fiber_pool.pop().?;

            // IMPORTANT: Reset the stack pointer so we start fresh!
            task.base.reset(trampoline_addr);

            task.status = .Ready;
        } else {
            // Alloc new Task container
            task = try self.allocator.create(Task);

            // Safety: Handle error if Fiber init fails
            errdefer self.allocator.destroy(task);

            // Alloc 8MB Virtual Stack, pointing to OUR Bootstrap function
            task.base = try Fiber.init(8 * 1024 * 1024, trampoline_addr);

            task.status = .Ready;
        }

        // Store the user's function so the wrapper can find it later
        task.runtime_ptr = runtime_ptr;
        task.user_fn = user_fn;
        task.context = ctx;
        task.config = config;

        self.active_tasks += 1;
        _ = self.load.fetchAdd(1, .monotonic);
        try self.ready_queue.append(self.allocator, task);
    }

    pub fn run(self: *Scheduler) void {
        global_registry.register(self.allocator, std.Thread.getCurrentId(), self) catch |err| {
            std.debug.print("SCHEDULER REGISTRATION FAILED: {}\n", .{err});
            return;
        };

        // Ensure we unregister when this loop exits (e.g. shutdown)
        defer global_registry.unregister(std.Thread.getCurrentId());

        while (true) {
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
                        self.ready_queue.append(self.allocator, task) catch unreachable;

                        // Don't increment 'i' because we just swapped a new item here
                    } else {
                        i += 1;
                    }
                }
            }

            // Look for tasks ready to start:
            if (self.ready_queue.items.len > 0) {
                const task = self.ready_queue.orderedRemove(0);
                self.current_task = task;

                // 1. Switch to the Task
                // The task will resume inside 'entryWrapper' (if new)
                // or wherever it yielded (if old).
                task.base.switchTo(&self.main_ctx);

                switch (task.status) {
                    .Finished => {
                        // Recycle
                        self.active_tasks -= 1;
                        _ = self.load.fetchSub(1, .monotonic);
                        self.fiber_pool.append(self.allocator, task) catch unreachable;
                    },
                    .Ready => {
                        // It yielded, but wants to run again. Put back in queue.
                        self.ready_queue.append(self.allocator, task) catch unreachable;
                    },
                    .Blocked => {
                        // Do nothing! It is now owned by the WaitGroup/Mutex/Etc.
                        // It will be added back to ready_queue by someone else later.
                    }
                }
                continue; // Keep looping if we have work!
            }

            if (self.active_tasks == 0) {
                break;
            }

            // IF IDLE: Poll for IO
            // Determine timeout based on next timer
            // If we have a sleeper in 50ms, poll(50). If empty, poll(-1) [Wait Forever].
            var timeout: i32 = -1;

            if (self.sleeping_queue.items.len > 0) {
                // Simplification: Just poll for 1ms if we have timers pending
                timeout = 1;
            }

            const count = self.poller.poll(&self.epoll_events, timeout);

            if (count > 0) {
                for (self.epoll_events[0..count]) |event| {
                    const data_ptr = event.data.ptr;

                    // CHECK: Is this the Wake Up Signal?
                    if (data_ptr == 0) {
                        // 1. Reset the signal
                        self.event_fd.consume() catch {};

                        // 2. Drain the Inbox
                        self.inbox_mutex.lock();
                        // Move everything from Inbox to Ready Queue
                        while (self.inbox.items.len > 0) {
                            const t = self.inbox.pop().?; // Taking from end is O(1)
                            t.status = .Ready;
                            self.ready_queue.append(self.allocator, t) catch unreachable;
                            self.active_tasks += 1;
                        }
                        self.inbox_mutex.unlock();
                    }
                    else {
                        // It's a standard IO Task Wakeup
                        const task = @as(*Task, @ptrFromInt(data_ptr));
                        task.status = .Ready;
                        self.ready_queue.append(self.allocator, task) catch unreachable;
                    }
                }
            }

            // If no IO and no Tasks and no Sleepers -> Break
            if (count == 0 and self.ready_queue.items.len == 0 and self.sleeping_queue.items.len == 0) {
                break;
            }
        }
    }

    // Helper to wake a specific fiber
    pub fn schedule(self: *Scheduler, task: *Task) void {
        self.ready_queue.append(self.allocator, task) catch unreachable;
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

