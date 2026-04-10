const std = @import("std");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = CheatHeader.Runtime;
const EbrContext = CheatHeader.EbrContext;

// -------------------------------------------------------------------------
// 2. User Types & Functions (Transpiled)
// -------------------------------------------------------------------------
// CLR:9
const native_utils = @import("native_utils");

// CLR:15
fn clearMain(rt: *Runtime) !void {
    _ = &rt;
    // CLR:17
const duped = blk_ext1: { const __ext1_args = .{ (if (@hasField(@TypeOf(@as([]const u8, "hello")), "items")) @as([]const u8, "hello").items else @as([]const u8, "hello")) }; const __Ext1 = struct { alloc: std.mem.Allocator, a0: []const u8, err: ?anyerror = null, ret: []const u8 = undefined, fn run(ptr: ?*anyopaque) callconv(.c) void { const f: *@This() = @ptrCast(@alignCast(ptr)); f.ret = (native_utils.zigDupe(f.alloc, f.a0) catch |err| { f.err = err; return; }); } }; var __ext1_frame = __Ext1{ .a0 = __ext1_args[0], .alloc = rt.frameAlloc() }; rt.onRootStack(@as(*const fn (?*anyopaque) callconv(.c) void, &__Ext1.run), @ptrCast(&__ext1_frame)); if (__ext1_frame.err) |e| return e; break :blk_ext1 __ext1_frame.ret; }; 


// CLR:18
CheatLib.assert(CheatLib.eql(duped, "hello"), "zigDupe should return 'hello'");
// CLR:21
const joined = blk_ext2: { const __ext2_args = .{ (if (@hasField(@TypeOf(@as([]const u8, "foo")), "items")) @as([]const u8, "foo").items else @as([]const u8, "foo")), (if (@hasField(@TypeOf(@as([]const u8, "-")), "items")) @as([]const u8, "-").items else @as([]const u8, "-")), (if (@hasField(@TypeOf(@as([]const u8, "bar")), "items")) @as([]const u8, "bar").items else @as([]const u8, "bar")) }; const __Ext2 = struct { alloc: std.mem.Allocator, a0: []const u8, a1: []const u8, a2: []const u8, err: ?anyerror = null, ret: []const u8 = undefined, fn run(ptr: ?*anyopaque) callconv(.c) void { const f: *@This() = @ptrCast(@alignCast(ptr)); f.ret = (native_utils.zigConcat(f.alloc, f.a0, f.a1, f.a2) catch |err| { f.err = err; return; }); } }; var __ext2_frame = __Ext2{ .a0 = __ext2_args[0], .a1 = __ext2_args[1], .a2 = __ext2_args[2], .alloc = rt.frameAlloc() }; rt.onRootStack(@as(*const fn (?*anyopaque) callconv(.c) void, &__Ext2.run), @ptrCast(&__ext2_frame)); if (__ext2_frame.err) |e| return e; break :blk_ext2 __ext2_frame.ret; }; 


// CLR:22
CheatLib.assert(CheatLib.eql(joined, "foo-bar"), "zigConcat should return 'foo-bar'");
// CLR:25
const result = blk_ext3: { const __ext3_args = .{ 100, 4 }; const __Ext3 = struct { a0: i64, a1: i64, err: ?anyerror = null, ret: i64 = undefined, fn run(ptr: ?*anyopaque) callconv(.c) void { const f: *@This() = @ptrCast(@alignCast(ptr)); f.ret = (native_utils.safeDivide(f.a0, f.a1) catch |err| { f.err = err; return; }); } }; var __ext3_frame = __Ext3{ .a0 = __ext3_args[0], .a1 = __ext3_args[1] }; rt.onRootStack(@as(*const fn (?*anyopaque) callconv(.c) void, &__Ext3.run), @ptrCast(&__ext3_frame)); if (__ext3_frame.err) |e| return e; break :blk_ext3 __ext3_frame.ret; }; 


// CLR:26
CheatLib.assert((result == 25), "100/4 should be 25");
// CLR:28
std.debug.print("{s}\n", .{"FFI effects test passed"});
// CLR:29
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
}

