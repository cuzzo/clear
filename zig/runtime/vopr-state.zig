// vopr-state.zig — VOPR global state: simulated schedulers, task registry, I/O.
//
// The VOPR simulates N schedulers in a single OS thread.  Each SimScheduler
// wraps a REAL RunQueue from queues.zig — we exercise the actual production
// Chase-Lev deque, not a mock.  Tasks are lightweight stubs (no real fibers,
// no context switching, no stacks).

const std = @import("std");
const qs = @import("queues.zig");
const fc = @import("fiber-core.zig");

const RunQueue = qs.RunQueue;
const Task = qs.Task;
const TaskStatus = qs.TaskStatus;
const TaskConfig = qs.TaskConfig;
const Fiber = fc.Fiber;
const Context = fc.Context;
const Stack = fc.Stack;

pub const MAX_SCHEDULERS = 8;
pub const MAX_TASKS = 128;
pub const MAX_SHARDS = 8;
// Higher than the real runtime would need because the VOPR's random step
// selection means any given scheduler gets PollEpoll only ~15% / N_sched
// of ticks.  In the real runtime, epoll is polled every fast-path iteration.
pub const MAX_STALL_TICKS = 2048;

pub const TaskLocation = enum {
    InQueue,
    Running,
    Blocked,
    Sleeping,
    Finished,
};

pub const SimFd = struct {
    registered_sched: ?u32,
    task: *Task,
    ready: bool,
    ready_since_tick: u64,
};

/// Pending remote shard operation queued via SPSC.
pub const PendingShardOp = struct {
    shard: u32,
    source_task: *Task,
};

/// Simulated shard state for PartitionedStringMap verification.
pub const ShardState = struct {
    owner_sched: u32,
    /// Tick when the shard was last accessed (for detecting overlap).
    last_access_tick: u64 = 0,
    /// Which scheduler accessed it last.
    last_access_sched: u32 = 0,
};

/// Heap-allocated SimTask.  Each holds an embedded Task and stub Fiber.
/// Allocated individually so pointers to task/fiber remain stable.
pub const SimTask = struct {
    task: Task,
    fiber: Fiber,
    steps_remaining: u16,
    will_do_io: bool,
    io_fd: i32,
    owner_sched: u32,
    alive: bool,
    stub_stack: [64]u8,
    /// Count of pending remote shard ops (models sendAndWait's steal-prevention
    /// pin). Task stays pinned until all pending ops are drained.
    pending_remote_count: u32 = 0,
    /// True if task was spawned as pinned (permanent). Drain never clears
    /// config.pinned for originally-pinned tasks.
    originally_pinned: bool = false,
    /// Tick at which the task was most recently enqueued (push or yield-back).
    /// Used by the ready-queue fairness invariant to detect starvation when
    /// a task waits in queue while the same scheduler keeps popping others.
    enqueued_tick: u64 = 0,
    /// Tick at which the task was most recently popped. 0 means never.
    last_pop_tick: u64 = 0,
    /// Total number of times this task has been popped. Increases each
    /// executePopAndRun call. Used by the cooperative-fairness scenario
    /// test to assert each co-located task gets CPU time.
    pop_count: u32 = 0,
};

/// SimScheduler wraps a heap-allocated RunQueue.
/// RunQueue is ~512KB (65536 atomic slots) — cannot live on the stack.
pub const SimScheduler = struct {
    ready_queue: *RunQueue,
    pinned_queue: std.ArrayListUnmanaged(*Task) = .empty,
    /// Mirrors Scheduler.yield_queue in scheduler.zig. Cooperative yields
    /// land here (FIFO) instead of on the LIFO Chase-Lev ready_queue, so
    /// co-located cooperative tasks rotate fairly. Drained AFTER ready_queue
    /// each tick: see executePopAndRun for the priority logic.
    yield_queue: std.ArrayListUnmanaged(*Task) = .empty,
    sleeping_queue: std.ArrayListUnmanaged(*Task),
    current_task: ?*Task,
    poll_fds: std.AutoHashMapUnmanaged(i32, *Task),
    index: u32,
    active_tasks: usize,
    ticks_since_poll: u32,
    /// Pending remote shard ops queued to this scheduler (simulated SPSC inbox).
    pending_shard_ops: std.ArrayListUnmanaged(PendingShardOp) = .empty,

    pub fn init(allocator: std.mem.Allocator, idx: u32) !SimScheduler {
        const rq = try allocator.create(RunQueue);
        rq.* = try RunQueue.initWithAllocator(allocator);
        return SimScheduler{
            .ready_queue = rq,
            .sleeping_queue = .empty,
            .current_task = null,
            .poll_fds = .{},
            .index = idx,
            .active_tasks = 0,
            .ticks_since_poll = 0,
        };
    }

    pub fn deinit(self: *SimScheduler, allocator: std.mem.Allocator) void {
        self.sleeping_queue.deinit(allocator);
        self.pinned_queue.deinit(allocator);
        self.yield_queue.deinit(allocator);
        self.poll_fds.deinit(allocator);
        self.pending_shard_ops.deinit(allocator);
        self.ready_queue.deinit();
        allocator.destroy(self.ready_queue);
    }

    pub fn enqueueTask(self: *SimScheduler, allocator: std.mem.Allocator, task: *Task) void {
        if (task.config.pinned) {
            self.pinned_queue.append(allocator, task) catch unreachable;
        } else {
            self.ready_queue.push(allocator, task) catch unreachable;
        }
    }

    /// Cooperative-yield re-enqueue. Mirrors Scheduler.run()'s .Ready
    /// handler routing for tasks that set co_yielded before yielding.
    pub fn yieldTask(self: *SimScheduler, allocator: std.mem.Allocator, task: *Task) void {
        self.yield_queue.append(allocator, task) catch unreachable;
    }

    /// Pop the next task respecting the production priority order:
    /// pinned > ready_queue (LIFO) > yield_queue (FIFO). Returns null
    /// when all three are empty.
    pub fn popNext(self: *SimScheduler) ?*Task {
        if (self.pinned_queue.items.len > 0) return self.pinned_queue.swapRemove(0);
        if (self.ready_queue.pop()) |t| return t;
        if (self.yield_queue.items.len > 0) return self.yield_queue.orderedRemove(0);
        return null;
    }
};

pub const VoprState = struct {
    rng: std.Random.DefaultPrng,
    random: std.Random,
    allocator: std.mem.Allocator,

    schedulers: [MAX_SCHEDULERS]SimScheduler,
    sched_count: usize,

    // Task pool — heap-allocated individually for pointer stability
    tasks: [MAX_TASKS]?*SimTask,
    task_count: usize,

    // Registry: task pointer -> location
    task_registry: std.AutoHashMapUnmanaged(*Task, TaskLocation),
    total_spawned: usize,
    total_finished: usize,

    // Blocked tasks: task -> fd
    blocked_tasks: std.AutoHashMapUnmanaged(*Task, i32),

    // Simulated fds
    sim_fds: std.AutoHashMapUnmanaged(i32, SimFd),
    next_fd: i32,

    tick: u64,
    sim_time_ms: i64,

    // Shard simulation for PartitionedStringMap concurrency verification
    shards: [MAX_SHARDS]ShardState = undefined,
    shard_count: usize = 0,

    // Pending spawns
    pending_spawns: std.ArrayListUnmanaged(PendingSpawn),

    // Reusable scratch map for invariant checking (avoids alloc/dealloc per check)
    scratch_seen: std.AutoHashMapUnmanaged(*Task, u32),

    pub const PendingSpawn = struct {
        task: *Task,
        target_sched: u32,
    };

    pub fn init(seed: u64, allocator: std.mem.Allocator) VoprState {
        const prng = std.Random.DefaultPrng.init(seed);
        var state = VoprState{
            .rng = prng,
            .random = undefined,
            .allocator = allocator,
            .schedulers = undefined,
            .sched_count = 0,
            .tasks = [_]?*SimTask{null} ** MAX_TASKS,
            .task_count = 0,
            .task_registry = .{},
            .total_spawned = 0,
            .total_finished = 0,
            .blocked_tasks = .empty,
            .sim_fds = .empty,
            .next_fd = 100,
            .tick = 0,
            .sim_time_ms = 0,
            .pending_spawns = .empty,
            .scratch_seen = .empty,
        };
        state.random = state.rng.random();
        return state;
    }

    pub fn deinit(self: *VoprState) void {
        for (self.schedulers[0..self.sched_count]) |*sched| {
            sched.deinit(self.allocator);
        }
        for (self.tasks[0..self.task_count]) |opt| {
            if (opt) |sim| self.allocator.destroy(sim);
        }
        self.task_registry.deinit(self.allocator);
        self.blocked_tasks.deinit(self.allocator);
        self.sim_fds.deinit(self.allocator);
        self.pending_spawns.deinit(self.allocator);
        self.scratch_seen.deinit(self.allocator);
    }

    pub fn initSchedulers(self: *VoprState, count: usize) void {
        self.sched_count = count;
        for (0..count) |i| {
            self.schedulers[i] = SimScheduler.init(self.allocator, @intCast(i)) catch
                @panic("VOPR: failed to allocate scheduler");
        }
    }

    /// Allocate a SimTask on the heap, initialize stub Fiber + Task.
    fn allocSimTask(self: *VoprState, target_sched: u32, pinned: bool) !*SimTask {
        if (self.task_count >= MAX_TASKS) return error.TaskPoolFull;

        const sim = try self.allocator.create(SimTask);

        @memset(&sim.stub_stack, 0);

        sim.fiber = Fiber{
            .stack = Stack{ .memory = &sim.stub_stack },
            .ctx = Context{ .sp = 0 },
            .parent_ctx = undefined,
            .size_class = .Standard,
            .stack_limit = 0,
            .stack_guard_head = null,
        };

        sim.task = Task{
            .base = &sim.fiber,
            .user_fn = @ptrCast(&dummyTaskFn),
            .status = qs.Atomic(TaskStatus).init(.Ready),
            .config = .{
                .pinned = pinned,
                .stack_size = .Standard,
            },
        };

        sim.steps_remaining = self.random.intRangeAtMost(u16, 1, 20);
        sim.will_do_io = self.random.intRangeAtMost(u8, 0, 3) == 0;
        sim.io_fd = -1;
        sim.owner_sched = target_sched;
        sim.alive = true;
        sim.pending_remote_count = 0;
        sim.originally_pinned = pinned;
        sim.enqueued_tick = self.tick;
        sim.last_pop_tick = 0;
        sim.pop_count = 0;

        self.tasks[self.task_count] = sim;
        self.task_count += 1;

        return sim;
    }

    /// Spawn a task directly into a scheduler's ready queue.
    pub fn spawnTask(self: *VoprState, target_sched: u32, pinned: bool) !void {
        const sim = try self.allocSimTask(target_sched, pinned);
        const task_ptr = &sim.task;

        self.task_registry.put(self.allocator, task_ptr, .InQueue) catch unreachable;
        self.total_spawned += 1;

        self.schedulers[target_sched].enqueueTask(self.allocator, task_ptr);
        self.schedulers[target_sched].active_tasks += 1;
        sim.enqueued_tick = self.tick;
    }

    /// Queue a spawn for the DrainSpawns step.
    pub fn queueSpawn(self: *VoprState, target_sched: u32, pinned: bool) !void {
        const sim = try self.allocSimTask(target_sched, pinned);

        self.task_registry.put(self.allocator, &sim.task, .InQueue) catch unreachable;
        self.total_spawned += 1;

        self.pending_spawns.append(self.allocator, .{
            .task = &sim.task,
            .target_sched = target_sched,
        }) catch unreachable;
    }

    /// Find the SimTask that owns a given *Task pointer.
    pub fn getSimTask(self: *VoprState, task: *Task) ?*SimTask {
        for (self.tasks[0..self.task_count]) |opt| {
            if (opt) |sim| {
                if (&sim.task == task) return sim;
            }
        }
        return null;
    }

    /// Allocate a simulated fd for a task.
    pub fn allocFd(self: *VoprState, task: *Task, sched_idx: u32) i32 {
        const fd = self.next_fd;
        self.next_fd += 1;
        self.sim_fds.put(self.allocator, fd, .{
            .registered_sched = sched_idx,
            .task = task,
            .ready = false,
            .ready_since_tick = 0,
        }) catch unreachable;
        self.schedulers[sched_idx].poll_fds.put(self.allocator, fd, task) catch unreachable;
        return fd;
    }

    /// Initialize shard ownership (mirrors PartitionedStringMap.ensureOwnership).
    /// Assigns shards round-robin to schedulers.
    pub fn initShards(self: *VoprState, count: usize) void {
        self.shard_count = count;
        for (0..count) |i| {
            self.shards[i] = .{ .owner_sched = @intCast(i % self.sched_count) };
        }
    }

    pub fn allTasksFinished(self: *VoprState) bool {
        return self.total_finished >= self.total_spawned and self.pending_spawns.items.len == 0;
    }

    fn dummyTaskFn(_: *anyopaque, _: ?*anyopaque) anyerror!void {}
};
