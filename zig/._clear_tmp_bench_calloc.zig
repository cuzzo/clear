pub const USE_C_ALLOCATOR = true;
const std = @import("std");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = CheatHeader.Runtime;
const EbrContext = CheatHeader.EbrContext;

// -------------------------------------------------------------------------
// 2. User Types & Functions (Transpiled)
// -------------------------------------------------------------------------
// CLR:18
const Msg = struct {
    seed: i64,
};

// CLR:20
fn processMessage(seed: i64) i64 {
    
    // CLR:21
var x: i64 = seed; 
// CLR:22
{
var __for_1: i64 = 0;
while (__for_1 < 2000) : (__for_1 += 1) {
const i: i64 = __for_1; _ = &i;
 // CLR:22
x = CheatLib.wrapAdd(CheatLib.wrapMul(x, 6364136223846793005), 1442695040888963407); 
}
}
// CLR:23
return x;
}


// CLR:26
fn subscriberWork(rt: *Runtime, n: i64) !i64 {
    const frame_mark = rt.saveFrameMark();
defer rt.restoreFrameMark(frame_mark);

    // CLR:28
var msgs = try CheatLib.makeList(Msg, rt.frameAlloc(), &.{}); _ = &msgs;
// CLR:29
{
var __for_2: i64 = 0;
while (__for_2 < n) : (__for_2 += 1) {
const i: i64 = __for_2; _ = &i;
 // CLR:29
try msgs.append(rt.frameAlloc(), Msg{ .seed = i }); 
rt.checkYield();
}
}
// CLR:31
const results = __pblk1: {
    const pipe_src_list = msgs;
    _ = &pipe_src_list;
    const pipe_items = if (@hasField(@TypeOf(pipe_src_list), "items")) pipe_src_list.items else pipe_src_list[0..];
    const __ccs0_items = pipe_items;
    const __ccs0_len = __ccs0_items.len;
    const __ccs0_results = try rt.heapAlloc().alloc(?i64, __ccs0_len);
    defer rt.heapAlloc().free(__ccs0_results);
    for (__ccs0_results) |*__s| __s.* = null;
    var __ccs0_wg = CheatHeader.WaitGroup.init(rt.getSched());
    const __ccs0_n_workers: usize = @intCast(32);
    const __CcsWorker0 = struct {
        wg:      *CheatHeader.WaitGroup,
        items:   []const Msg,
        results: []?i64,
        next:    *std.atomic.Value(usize),
        fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
            _ = &__rt;
            const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
            defer ctx.wg.done();
            while (true) {
                const __idx = ctx.next.fetchAdd(1, .monotonic);
                if (__idx >= ctx.items.len) break;
                ctx.results[__idx] = processMessage(ctx.items[__idx].seed);
                __rt.checkYield();
            }
        }
    };
    var __ccs0_next = std.atomic.Value(usize).init(0);
    var __ccs0_workers: [64]__CcsWorker0 = undefined;
    const __ccs0_actual_workers = @min(__ccs0_n_workers, 64);
    __ccs0_wg.add(__ccs0_actual_workers);
    for (0..__ccs0_actual_workers) |__w| {
        __ccs0_workers[__w] = .{
            .wg      = &__ccs0_wg,
            .items   = __ccs0_items,
            .results = __ccs0_results,
            .next    = &__ccs0_next,
        };
        try CheatHeader.spawnBest(
    @intFromPtr(&Runtime.entryWrapper),
    @as(CheatHeader.TaskFn, @ptrCast(&__CcsWorker0.run)),
    &__ccs0_workers[__w],
    .{ .stack_size = .Standard },
);
    }
    __ccs0_wg.wait();
    var __ccs0_final = std.ArrayListUnmanaged(i64){};
    for (__ccs0_results) |__ccs0_slot| {
        if (__ccs0_slot) |__v| try __ccs0_final.append(rt.heapAlloc(), __v);
    }
    break :__pblk1 __ccs0_final;
}; 
// CLR:31
var results_moved = false; _ = &results_moved;
defer if (!results_moved) CheatLib.free(rt, results);

// CLR:33
var total: i64 = 0; 
// CLR:34
{
var __for_3: i64 = 0;
while (__for_3 < CheatLib.len(results)) : (__for_3 += 1) {
const j: i64 = __for_3; _ = &j;
 // CLR:34
total = CheatLib.wrapAdd(total, CheatLib.getAt(results, j)); 
rt.checkYield();
}
}
// CLR:35
return total;
}


// CLR:38
fn clearMain(rt: *Runtime) !void {
    const frame_mark = rt.saveFrameMark();
defer rt.restoreFrameMark(frame_mark);

    // CLR:39
const t0: i64 = CheatLib.timestampMs(); 
// CLR:40
var futures = std.ArrayListUnmanaged(CheatLib.Promise(i64)){}; _ = &futures;
// CLR:40
defer CheatLib.cleanup(std.ArrayListUnmanaged(CheatLib.Promise(i64)), rt.frameAlloc(), &futures);

// CLR:41
{
var __for_4: i64 = 0;
while (__for_4 < 64) : (__for_4 += 1) {
const i: i64 = __for_4; _ = &i;
 // CLR:41
try futures.append(rt.frameAlloc(), __bg0: {
    const __BgCtx0 = struct {
        inner: *CheatLib.Promise(i64).Inner,
        alloc: std.mem.Allocator,
        
        fn run(__raw_rt_0: *anyopaque, __raw_args_0: ?*anyopaque) anyerror!void {
            const __rt_bg0 = @as(*Runtime, @ptrCast(@alignCast(__raw_rt_0)));
            
            
            const __ctx_0 = @as(*@This(), @ptrCast(@alignCast(__raw_args_0.?)));
            defer __ctx_0.alloc.destroy(__ctx_0);
            defer __ctx_0.inner.wg.done();
            errdefer |fiber_err| __ctx_0.inner.result = fiber_err;
            
            
            __ctx_0.inner.result = subscriberWork(__rt_bg0, 100000);
            
        }
    };
    const __bg0_alloc = rt.getSched().allocator;
    const __bg0_promise = try CheatLib.Promise(i64).spawn(__bg0_alloc, rt.getSched());
    
    const __bg0_ctx = try __bg0_alloc.create(__BgCtx0);
    errdefer __bg0_alloc.destroy(__bg0_ctx);
    __bg0_ctx.* = .{ .inner = __bg0_promise.inner, .alloc = __bg0_alloc };
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
// CLR:43
var total: i64 = 0; 
// CLR:44
{
var __for_5: i64 = 0;
while (__for_5 < 64) : (__for_5 += 1) {
const j: i64 = __for_5; _ = &j;
 // CLR:45
const result: i64 = try CheatLib.getAt(futures, j).next(); 
// CLR:46
total = CheatLib.wrapAdd(total, result); 
rt.checkYield();
}
}
// CLR:48
const elapsed: i64 = CheatLib.intSub(CheatLib.timestampMs(), t0); 
// CLR:50
const checksum: i64 = @mod(total, 1000000000); 
// CLR:51
std.debug.print("{s}\n", .{try std.mem.concat(rt.frameAlloc(), u8, &.{ "Checksum: ", try CheatLib.intToString(rt.frameAlloc(), checksum), "" })});
// CLR:52
std.debug.print("{s}\n", .{"Messages: 100000"});
// CLR:53
std.debug.print("{s}\n", .{"Subscribers: 64"});
// CLR:54
std.debug.print("{s}\n", .{try std.mem.concat(rt.frameAlloc(), u8, &.{ "Time: ", try CheatLib.intToString(rt.frameAlloc(), elapsed), " ms" })});
// CLR:55
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


    // 10. Dump allocation profile (if profiling was enabled at compile time).
    const profiling_enabled = if (@hasDecl(@import("root"), "CLEAR_PROFILE"))
        @import("root").CLEAR_PROFILE
    else
        false;
    if (profiling_enabled) {
        @import("alloc-profile.zig").dump();
    }
}

