const std = @import("std");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = CheatHeader.Runtime;
const EbrContext = CheatHeader.EbrContext;

// -------------------------------------------------------------------------
// 2. User Types & Functions (Transpiled)
// -------------------------------------------------------------------------
// CLR:10
const Entity = struct {
    x: i64,
    y: i64,
    health: i64,
};

// CLR:12
fn benchPool(rt: *Runtime, n: i64) !i64 {
    _ = &rt;
    // CLR:13
var pool = CheatLib.Pool(Entity){}; _ = &pool;
var pool_moved = false; _ = &pool_moved;
defer if (!pool_moved) pool.deinit(rt.heapAlloc());


// CLR:16
var i: i64 = 0; 


// CLR:17
while ((i < n)) {
 // CLR:17
_ = try pool.insert(rt.heapAlloc(), Entity{ .x = i, .y = (i * 2), .health = 100 }); 
rt.checkYield();
}
// CLR:17
i = (i + 1); 
// CLR:19
return pool.count();
}


// CLR:22
fn benchList(rt: *Runtime, n: i64) !i64 {
    _ = &rt;
    // CLR:23
var items = std.ArrayListUnmanaged(Entity){}; _ = &items;
defer items.deinit(rt.frameAlloc());


// CLR:26
var i: i64 = 0; 


// CLR:27
while ((i < n)) {
 // CLR:27
try items.append(rt.frameAlloc(), Entity{ .x = i, .y = (i * 2), .health = 100 }); 
rt.checkYield();
}
// CLR:27
i = (i + 1); 
// CLR:29
return CheatLib.len(items);
}


// CLR:32
fn clearMain(rt: *Runtime) !void {
    _ = &rt;
    // CLR:33
const n: i64 = 1000000; 


// CLR:35
const t0: i64 = CheatLib.timestampMs(); 


// CLR:36
const poolCount: i64 = try benchPool(rt, n); 


// CLR:37
const poolMs: i64 = (CheatLib.timestampMs() - t0); 


// CLR:39
const t1: i64 = CheatLib.timestampMs(); 


// CLR:40
const listCount: i64 = try benchList(rt, n); 


// CLR:41
const listMs: i64 = (CheatLib.timestampMs() - t1); 


// CLR:43
CheatLib.assert((poolCount == listCount), "both must insert same count");
// CLR:45
std.debug.print("{s}\n", .{try CheatLib.concat(rt.frameAlloc(), try CheatLib.concat(rt.frameAlloc(), "Pool vs List insert (", try CheatLib.intToString(rt.frameAlloc(), n)), " entities)")});
// CLR:46
std.debug.print("{s}\n", .{try CheatLib.concat(rt.frameAlloc(), try CheatLib.concat(rt.frameAlloc(), "  Pool (generational): ", try CheatLib.intToString(rt.frameAlloc(), poolMs)), " ms")});
// CLR:47
std.debug.print("{s}\n", .{try CheatLib.concat(rt.frameAlloc(), try CheatLib.concat(rt.frameAlloc(), "  List (dense array):  ", try CheatLib.intToString(rt.frameAlloc(), listMs)), " ms")});
// CLR:48
return ;
}


// -------------------------------------------------------------------------
// 3. Main Entry (Test Harness)
// -------------------------------------------------------------------------
// Multi-threaded bootstrapper.
//
// Spawns N schedulers (N = CPU count), each with its own io_uring ring and
// epoll instance.  The main thread runs Scheduler 0 (which owns main);
// N-1 worker threads run idle schedulers that steal work via the existing
// Chase-Lev work-stealing deque in RunQueue.
//
// Shared state (heap-allocated, outlives all threads):
//   - GPA allocator
//   - EbrContext  (thread-safe — has its own registry_lock)
//   - StackPool   (thread-safe — slab allocator with atomic free lists)
//   - shutdown    (atomic bool — signals workers to exit after main)
//
// Per-thread:
//   - Scheduler   (owns io_uring ring + epoll + ready_queue + inbox)
//   - active_scheduler threadlocal (set before sched.run)

pub fn main() !void {
    // 1. Setup Allocator
    // Compile-time flag: USE_C_ALLOCATOR = true uses libc malloc (thread-safe,
    // per-thread arenas in glibc/musl). Otherwise uses GPA for leak detection.
    // Multi-threaded builds should always set USE_C_ALLOCATOR.
    const use_c_alloc = if (@hasDecl(@import("root"), "USE_C_ALLOCATOR")) @import("root").USE_C_ALLOCATOR else false;

    var gpa = if (use_c_alloc) {} else std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer if (!use_c_alloc) {
        _ = gpa.deinit();
    };
    const allocator = if (use_c_alloc) std.heap.c_allocator else gpa.allocator();

    // 2. Setup Contexts
    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);

    // 3. Init Runtime (4 MB frame arena for the main fiber).
    var rt = try Runtime.init(allocator, 4 * 1024 * 1024, &global_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    // 4. Shared infrastructure
    const fm = @import("fiber-memory.zig");
    const fp = @import("scheduler.zig");
    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();

    // Global shutdown flag — workers check this each loop iteration.
    var shutdown = std.atomic.Value(bool).init(false);

    // 5. Determine thread count.
    //    CLEAR_THREADS=N overrides; default = 1 (single scheduler, zero overhead).
    //    On machines with many cores + large workloads, set CLEAR_THREADS=0 (auto)
    //    or CLEAR_THREADS=N to spawn N-1 worker schedulers.
    const num_workers = blk: {
        if (std.posix.getenv("CLEAR_THREADS")) |env| {
            const n = std.fmt.parseInt(usize, env, 10) catch 1;
            if (n == 0) {
                // Auto: use all CPUs
                const cpus = std.Thread.getCpuCount() catch 1;
                break :blk if (cpus > 1) cpus - 1 else 0;
            }
            break :blk if (n > 1) n - 1 else 0;
        }
        break :blk @as(usize, 0); // Default: single scheduler
    };

    // 6. Spawn worker schedulers.
    const WorkerCtx = struct {
        allocator: std.mem.Allocator,
        global_ctx: *EbrContext,
        stack_pool: *fm.StackPool,
        shutdown: *std.atomic.Value(bool),
    };
    var worker_ctx = WorkerCtx{
        .allocator = allocator,
        .global_ctx = &global_ctx,
        .stack_pool = &stack_pool,
        .shutdown = &shutdown,
    };

    const workerMain = struct {
        fn run(ctx: *WorkerCtx) void {
            var worker_sched = fp.Scheduler.init(ctx.allocator, ctx.global_ctx, ctx.stack_pool) catch return;
            defer worker_sched.deinit();
            worker_sched.shutdown_on_idle = false; // stay alive until explicit shutdown
            worker_sched.global_shutdown = ctx.shutdown;
            fp.active_scheduler = &worker_sched;
            fp.scheduler_running = true;
            worker_sched.run();
            fp.scheduler_running = false;
        }
    }.run;

    var workers: [64]std.Thread = undefined;
    for (0..num_workers) |i| {
        workers[i] = std.Thread.spawn(.{}, workerMain, .{&worker_ctx}) catch break;
    }

    // Wait for all workers to register before starting main scheduler.
    // This prevents ensureOwnership from seeing partial scheduler state.
    if (num_workers > 0) {
        while (fp.global_registry.count() < num_workers) {
            std.posix.nanosleep(0, 1 * std.time.ns_per_ms);
        }
    }

    // 7. Main scheduler (runs on the main thread).
    var sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer {
        sched.deinit();
        fp.global_registry.deinit(allocator);
    }
    sched.global_shutdown = &shutdown;
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;

    // 8. Submit main as a fiber on the main scheduler.
    const MainRunner = struct {
        outer_rt: *Runtime,
        fn run(_: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw_args.?));
            const result = try clearMain(self.outer_rt);
            const RType = @TypeOf(result);
            if (@typeInfo(RType) == .pointer) {
                CheatLib.free(self.outer_rt, result);
            }
        }
    };
    var main_runner = MainRunner{ .outer_rt = &rt };
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&MainRunner.run)),
        &main_runner,
        .{ .stack_size = .Large },
    );
    sched.run();

    // 9. Signal workers to shut down and join.
    shutdown.store(true, .release);
    fp.global_registry.notifyAll(); // wake workers from epoll_wait
    for (0..num_workers) |i| {
        workers[i].join();
    }
}

