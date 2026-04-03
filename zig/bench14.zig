const std = @import("std");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = CheatHeader.Runtime;
const EbrContext = CheatHeader.EbrContext;

// -------------------------------------------------------------------------
// 2. User Types & Functions (Transpiled)
// -------------------------------------------------------------------------
// CLR:10
fn doWork(seed: i64) i64 {
    
    // CLR:11
var x: i64 = seed; 


// CLR:12
{
var __for_1: i64 = 0;
while (__for_1 < 10000) : (__for_1 += 1) {
const i: i64 = __for_1; _ = &i;
 // CLR:12
x = CheatLib.intAdd(CheatLib.intMul(x, 6364136223846793005), 1442695040888963407);  
}
}
// CLR:13
return x;
}


// CLR:16
fn clearMain(rt: *Runtime) !void {
    const frame_mark = rt.saveFrameMark();
defer rt.restoreFrameMark(frame_mark);

    // CLR:17
const t0: i64 = CheatLib.timestampMs(); 


// CLR:18
var futures = std.ArrayListUnmanaged(CheatLib.Promise(i64)){}; _ = &futures;
defer futures.deinit(rt.frameAlloc());


// CLR:19
{
var __for_2: i64 = 0;
while (__for_2 < 10000) : (__for_2 += 1) {
const i: i64 = __for_2; _ = &i;
 // CLR:19
try futures.append(rt.frameAlloc(), __bg0: {
    const __BgCtx0 = struct {
        inner: *CheatLib.Promise(i64).Inner,
        alloc: std.mem.Allocator,
        i: i64,
        fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
            _ = &__rt;
            
            const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
            defer ctx.alloc.destroy(ctx);
            defer ctx.inner.wg.done();
            errdefer |fiber_err| ctx.inner.result = fiber_err;
            
            
            ctx.inner.result = doWork(ctx.i);
            
        }
    };
    const __bg0_alloc = rt.getSched().allocator;
    const __bg0_promise = try CheatLib.Promise(i64).spawn(__bg0_alloc, rt.getSched());
    
    const __bg0_ctx = try __bg0_alloc.create(__BgCtx0);
    __bg0_ctx.* = .{ .inner = __bg0_promise.inner, .alloc = __bg0_alloc, .i = i };
    
    try CheatHeader.spawnBest(
            @intFromPtr(&Runtime.entryWrapper),
            @as(CheatHeader.TaskFn, @ptrCast(&__BgCtx0.run)),
            __bg0_ctx,
            .{ .stack_size = .Standard },
        );
    break :__bg0 __bg0_promise;
}); 
rt.checkYield();
}
}
// CLR:21
var total: i64 = 0; 


// CLR:22
{
var __for_3: i64 = 0;
while (__for_3 < 10000) : (__for_3 += 1) {
const j: i64 = __for_3; _ = &j;
 // CLR:23
const result: i64 = try CheatLib.getAt(futures, j).next(); 


// CLR:24
total = CheatLib.intAdd(total, result);  
rt.checkYield();
}
}
// CLR:26
const elapsed: i64 = CheatLib.intSub(CheatLib.timestampMs(), t0); 


// CLR:28
const checksum: i64 = @mod(total, 1000000000); 


// CLR:29
std.debug.print("{s}\n", .{__interp0: {
    const __n = std.fmt.count("Checksum: {d}", .{ checksum });
    const __buf = try rt.frameAlloc().alloc(u8, __n);
    _ = std.fmt.bufPrint(__buf, "Checksum: {d}", .{ checksum }) catch unreachable;
    break :__interp0 __buf;
}});
// CLR:30
std.debug.print("{s}\n", .{"Tasks: 10000"});
// CLR:31
std.debug.print("{s}\n", .{"Iterations: 10000"});
// CLR:32
std.debug.print("{s}\n", .{__interp1: {
    const __n = std.fmt.count("Time: {d} ms", .{ elapsed });
    const __buf = try rt.frameAlloc().alloc(u8, __n);
    _ = std.fmt.bufPrint(__buf, "Time: {d} ms", .{ elapsed }) catch unreachable;
    break :__interp1 __buf;
}});
// CLR:33
return ;
}


// -------------------------------------------------------------------------
// 3. Main Entry
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
    // ReleaseFast defaults to c_allocator (libc malloc — jemalloc compatible,
    // per-thread arenas, zero contention). Debug/ReleaseSafe defaults to GPA
    // for leak detection. Override with USE_C_ALLOCATOR declaration.
    const use_c_alloc = if (@hasDecl(@import("root"), "USE_C_ALLOCATOR"))
        @import("root").USE_C_ALLOCATOR
    else
        (@import("builtin").mode == .ReleaseFast or @import("builtin").mode == .ReleaseSmall);

    var gpa = if (use_c_alloc) {} else std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer if (!use_c_alloc) {
        _ = gpa.deinit();
    };
    const allocator = if (use_c_alloc) std.heap.c_allocator else gpa.allocator();

    // 2. Setup Contexts
    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);

    // 3. Init Runtime (4 KB frame arena — same as any spawned fiber).
    //    Grows automatically via CheatArena overflow blocks (4KB → 16KB → 64KB → 256KB).
    var rt = try Runtime.init(allocator, 4 * 1024, &global_ctx);
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

