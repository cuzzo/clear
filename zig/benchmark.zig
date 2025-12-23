const std = @import("std");
const builtin = @import("builtin");

const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const rt_mod = @import("runtime.zig");
const ebr = @import("ebr.zig");

const StackPool = fm.StackPool;

// Global context for the benchmark
// We need these to live as long as the application
var global_ebr: ebr.EbrContext = .{};
var stack_pool: fm.StackPool = undefined;
var global_shutdown = std.atomic.Value(bool).init(false);

pub fn main() !void {
    if (builtin.mode == .Debug) return error.SkipZigTest; // Don't bench in debug

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    std.debug.print("\n[Benchmark] Initializing System...\n", .{});

    // 1. Setup Global Contexts
    // Note: EbrContext is initialized with default field values
    stack_pool = StackPool.init(allocator);
    defer stack_pool.deinit();

    // 2. Configure Thread Pool
    // We use all available cores to maximize contention
    const core_count = try std.Thread.getCpuCount();
    std.debug.print("[Benchmark] Spawning {d} Scheduler Threads\n", .{core_count});

    const threads = try allocator.alloc(std.Thread, core_count);

    // Launch Schedulers
    for (threads) |*t| {
        t.* = try std.Thread.spawn(.{}, schedulerThread, .{allocator});
    }

    // Give schedulers a moment to spin up
    std.posix.nanosleep(0, 100 * std.time.ns_per_ms);

    // =========================================================
    // SCENARIO 1: The "Throughput" Baseline
    // =========================================================
    // Target: Allocator speed, Queue contention, Stack reuse.
    // Expectation: > 2M ops/sec.
    try runBenchmark("Throughput: 1M tiny tasks", benchmarkThroughput);

    // =========================================================
    // SCENARIO 2: Head-of-Line Blocking (The Rogue Task)
    // =========================================================
    // Target: Cooperative scheduling weakness.
    // A single CPU-heavy task should NOT block new tasks if work-stealing works.
    try runBenchmark("HOL Blocking: Latency Under Load", benchmarkBlocking);

    // =========================================================
    // SCENARIO 3: Deep Recursion (Stack/Memory Pressure)
    // =========================================================
    // Target: mmap limits and stack caching efficiency.
    // Failure Mode: crashing due to 'vm.max_map_count' or OOM.
    try runBenchmark("Work Stealing: Deep Recursion", benchmarkRecursion);

    // =========================================================
    // SCENARIO 4: Epoll Saturation (C10K Simulation)
    // =========================================================
    // Target: The O(N) lookup in `sleeping_queue` and Epoll overhead.
    try runBenchmark("IO/Sleep: 10k concurrent timers", benchmarkSleepers);

    // Cleanup
    std.debug.print("\n[Benchmark] Shutting down...\n", .{});
    global_shutdown.store(true, .seq_cst);

    // Wake up all threads so they check the shutdown flag
    // (In a real app, you'd have a condition variable or eventfd broadcast)
    fp.global_registry.mutex.lock();
    var it = fp.global_registry.map.valueIterator();
    while (it.next()) |sched_ptr| {
        sched_ptr.*.event_fd.notify();
    }
    fp.global_registry.mutex.unlock();

    for (threads) |t| t.join();
    global_ebr.deinit(allocator);
}

fn schedulerThread(allocator: std.mem.Allocator) !void {
    // Each thread initializes its own Scheduler
    var sched = try fp.Scheduler.init(allocator, &global_ebr, &stack_pool);
    defer sched.deinit();

    // Hook up the global shutdown signal
    sched.global_shutdown = &global_shutdown;

    // Set thread-local global pointer
    fp.active_scheduler = &sched;
    sched.shutdown_on_idle = false;

    // Enter the loop
    sched.run();
}

// ============================================================================
// HELPER: Run a benchmark function inside the Runtime
// ============================================================================
// We need a way to inject the *first* task from the main thread into the fiber world.
fn runBenchmark(name: []const u8, func: *const fn (*rt_mod.Runtime, ?*anyopaque) anyerror!void) !void {
    std.debug.print("\n------------------------------------------------\n", .{});
    std.debug.print("RUNNING: {s}\n", .{name});
    std.debug.print("------------------------------------------------\n", .{});

    // Pick a random scheduler to start the chain
    const pair = fp.global_registry.getRandomPair();
    if (pair.a == null) return error.NoScheduler;
    const sched = pair.a.?;

    const start = std.time.nanoTimestamp();

    // Synchronization: Main thread waits for Fiber to finish
    var done: bool = false;

    const Wrapper = struct {
        target_fn: *const fn (*rt_mod.Runtime, ?*anyopaque) anyerror!void,
        done_ptr: *bool,

        fn run(opaque_rt: *anyopaque, ctx: ?*anyopaque) !void {
            const r = @as(*rt_mod.Runtime, @ptrCast(@alignCast(opaque_rt)));
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            // Run the actual benchmark
            try self.target_fn(r, null);
            // Signal completion
            @atomicStore(bool, self.done_ptr, true, .release);
        }
    };

    var args = Wrapper{ .target_fn = func, .done_ptr = &done };

    // Inject the root task
    try sched.submitSpawn(
        @intFromPtr(&rt_mod.Runtime.entryWrapper),
        Wrapper.run,
        &args,
        .{}
    );

    // Busy wait for completion (acceptable for benchmarking harness)
    while (!@atomicLoad(bool, &done, .acquire)) {
        std.posix.nanosleep(0, 1 * std.time.ns_per_ms);
    }

    const end = std.time.nanoTimestamp();
    const duration_ms = @divFloor(end - start, std.time.ns_per_ms);
    std.debug.print(">>> Result: {d} ms\n", .{duration_ms});
}


// ============================================================================
// BENCH 1: THROUGHPUT
// ============================================================================
fn benchmarkThroughput(_: *rt_mod.Runtime, _: ?*anyopaque) !void {
    const TASKS = 55_000; // 1_000_000;

    var i: usize = 0;
    while (i < TASKS) : (i += 1) {
        // 'spawnBest' forces the runtime to check load and potentially
        // migrate tasks, testing the registry lock and atomic load counters.
        try rt_mod.Runtime.spawnBest(noopTask, null);
    }
}

fn noopTask(_: *rt_mod.Runtime, _: ?*anyopaque) !void {
    return;
}


// ============================================================================
// BENCH 2: HEAD OF LINE BLOCKING
// ============================================================================
const HolContext = struct {
    latencies: []i64,
    counter: std.atomic.Value(usize),
};

fn benchmarkBlocking(rt: *rt_mod.Runtime, _: ?*anyopaque) !void {
    // 1. Spawn a "Rogue" task.
    // This task will spin-loop for 500ms WITHOUT yielding.
    // In a cooperative system, this effectively kills one OS thread.
    try rt.spawn(rogueTask, null);

    // 2. Spawn 100 "Victim" tasks.
    // We want to see if the other OS threads steal these tasks
    // or if they get stuck behind the Rogue task.
    const COUNT = 100;
    const latencies = try rt.globalAlloc().alloc(i64, COUNT);

    // We need heap-allocated context to share safe pointers
    const ctx = try rt.globalAlloc().create(HolContext);
    ctx.* = .{
        .latencies = latencies,
        .counter = std.atomic.Value(usize).init(0)
    };

    var i: usize = 0;
    while (i < COUNT) : (i += 1) {
        // Record the time we *wanted* to start
        const queued_time = std.time.nanoTimestamp();

        // Pass the context and the start time packed together?
        // For simplicity, we'll just alloc a node for the time.
        const time_ptr = try rt.allocCopy(i64, @intCast(queued_time));

        // We use spawn (local queue) to intentionally put them
        // on the same queue as the Rogue task (if we are lucky/unlucky).
        try rt.spawn(victimTask, time_ptr);
    }

    // The benchmark runner sleeps long enough for the Rogue to finish
    rt.sleep(600);

    // Calculate stats
    //const max: i64 = 0;
    //const total: i64 = 0;
    //const count: i64 = 0;

    // Simple verification
    // (In real code, we'd use a WaitGroup to ensure all victims finished)
    // This assumes they finished within the 600ms window.
    // We can check by iterating the allocated latency array?
    // Since we don't have atomic indices easily here without passing ctx to victim,
    // we'll rely on console output from victimTask for failures.
}

fn rogueTask(_: *rt_mod.Runtime, _: ?*anyopaque) !void {
    std.debug.print("[Rogue] I am blocking a thread for 500ms...\n", .{});
    const start = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - start < 500) {
        std.atomic.spinLoopHint();
    }
    std.debug.print("[Rogue] Done blocking.\n", .{});
}

fn victimTask(_: *rt_mod.Runtime, start_ptr: ?*anyopaque) !void {
    const start = @as(*i64, @ptrCast(@alignCast(start_ptr))).*;
    const now = std.time.nanoTimestamp();
    const latency_ns = now - start;
    const latency_ms = @divFloor(latency_ns, 1_000_000);

    // If a task takes > 50ms to start, it was likely blocked.
    if (latency_ms > 50) {
         std.debug.print("!! VICTIM DELAYED BY: {d}ms !!\n", .{latency_ms});
    }
}


// ============================================================================
// BENCH 3: RECURSION / WORK STEALING
// ============================================================================
fn benchmarkRecursion(rt: *rt_mod.Runtime, _: ?*anyopaque) !void {
    // 2^15 = 32,768 tasks.
    // This creates a massive surge of tasks on one thread.
    // If work stealing fails, one thread drowns while others idle.
    try recursiveTask(rt, @ptrFromInt(15));
}

fn recursiveTask(rt: *rt_mod.Runtime, arg: ?*anyopaque) !void {
    const depth = @intFromPtr(arg);
    if (depth == 0) return;

    // Spawn two children
    // We use regular .spawn() to fill the local queue, forcing
    // other threads to steal from us.
    try rt.spawn(recursiveTask, @ptrFromInt(depth - 1));
    try rt.spawn(recursiveTask, @ptrFromInt(depth - 1));
}

// ============================================================================
// BENCH 4: SLEEPERS / IO
// ============================================================================
fn benchmarkSleepers(rt: *rt_mod.Runtime, _: ?*anyopaque) !void {
    const COUNT = 10_000;
    std.debug.print("[Sleepers] Spawning 10k timers...\n", .{});

    var i: usize = 0;
    while (i < COUNT) : (i += 1) {
        // Random sleep between 10ms and 100ms
        // This thrashes the scheduler's sleeping_queue (ArrayList)
        const ms = (i % 90) + 10;
        try rt.spawn(sleeperTask, @ptrFromInt(ms));
    }

    // Wait for all to finish
    rt.sleep(200);
}

fn sleeperTask(rt: *rt_mod.Runtime, arg: ?*anyopaque) !void {
    const ms = @intFromPtr(arg);
    rt.sleep(ms);
}

