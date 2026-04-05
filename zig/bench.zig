const std = @import("std");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = CheatHeader.Runtime;
const EbrContext = CheatHeader.EbrContext;
pub const USE_C_ALLOCATOR = true;

// -------------------------------------------------------------------------
// 2. User Types & Functions (Transpiled)
// -------------------------------------------------------------------------
// CLR:15
fn heavyCompute(seed: i64, n: i64) i64 {
    
    // CLR:16
var x: i64 = seed; 


// CLR:17
{
var __for_1: i64 = 0;
while (__for_1 < n) : (__for_1 += 1) {
const i: i64 = __for_1; _ = &i;
 // CLR:18
x = CheatLib.wrapAdd(CheatLib.wrapMul(x, 6364136223846793005), 1442695040888963407); 
// CLR:19
x = CheatLib.wrapAdd(CheatLib.wrapMul(x, x), 1);  
}
}
// CLR:21
if ((x < 0)) {
    // CLR:21
x = CheatLib.intSub(0, x); 
    }
// CLR:22
return @mod(x, 1000000000);
}


// CLR:25
fn handleClient(rt: *Runtime, client: i32) !void {
    const frame_mark = rt.saveFrameMark();
defer rt.restoreFrameMark(frame_mark);

    // CLR:26
var running: bool = true; 


// CLR:27
while (running) {
const __loop_mark_1 = rt.saveLoopMark(); defer rt.restoreLoopMark(__loop_mark_1);
 // CLR:28
const data = try CheatLib.socketRead(rt.frameAlloc(), client); 


// CLR:29
if ((CheatLib.len(data) == 0)) {
    // CLR:30
running = false; 
    } else {
    // CLR:32
var resp: []const u8 = ""; 


// CLR:33
var pos: i64 = 0; 


// CLR:34
while ((pos < CheatLib.len(data))) {
 // CLR:35
var eol: i64 = pos; 


// CLR:36
while ((((eol < CheatLib.len(data)) and !CheatLib.eql(CheatLib.charAt(data, eol), "\r")) and !CheatLib.eql(CheatLib.charAt(data, eol), "\n"))) {
 // CLR:37
eol = CheatLib.intAdd(eol, 1);  
rt.checkYield();
}
// CLR:39
const line: []const u8 = try CheatLib.substr(rt.frameAlloc(), data, pos, CheatLib.intSub(eol, pos)); 


// CLR:40
pos = eol; 
// CLR:41
while (((pos < CheatLib.len(data)) and (CheatLib.eql(CheatLib.charAt(data, pos), "\r") or CheatLib.eql(CheatLib.charAt(data, pos), "\n")))) {
 // CLR:42
pos = CheatLib.intAdd(pos, 1);  
rt.checkYield();
}
// CLR:45
if ((CheatLib.len(line) == 0)) {
    
    } else {
    // CLR:47
if (std.mem.startsWith(u8, line, @as([]const u8, "WORK:"))) {
    // CLR:48
const rest = try CheatLib.substr(rt.frameAlloc(), line, 5, CheatLib.intSub(CheatLib.len(line), 5)); 


// CLR:49
var colonPos: i64 = 0; 


// CLR:50
while (((colonPos < CheatLib.len(rest)) and !CheatLib.eql(CheatLib.charAt(rest, colonPos), ":"))) {
 // CLR:51
colonPos = CheatLib.intAdd(colonPos, 1);  
rt.checkYield();
}
// CLR:53
const idStr: []const u8 = try CheatLib.substr(rt.frameAlloc(), rest, 0, colonPos); 


// CLR:54
const nStr: []const u8 = try CheatLib.substr(rt.frameAlloc(), rest, CheatLib.intAdd(colonPos, 1), CheatLib.intSub(CheatLib.intSub(CheatLib.len(rest), colonPos), 1)); 


// CLR:55
const id: i64 = @intFromFloat((((std.fmt.parseFloat(f64, idStr) catch null)) orelse 0.0)); 


// CLR:56
var n: i64 = @intFromFloat((((std.fmt.parseFloat(f64, nStr) catch null)) orelse 0.0)); 


// CLR:57
if ((n < 1)) {
    // CLR:57
n = 1; 
    }
// CLR:58
const result: i64 = heavyCompute(id, n); 


// CLR:59
resp = try std.mem.concat(rt.frameAlloc(), u8, &.{ resp, ":", try CheatLib.intToString(rt.frameAlloc(), result), "\r\n" }); 
    } else {
    // CLR:60
if (CheatLib.eql(line, "QUIT")) {
    // CLR:61
resp = try std.mem.concat(rt.frameAlloc(), u8, &.{ resp, "+OK\r\n" }); 
// CLR:62
running = false; 
    } else {
    // CLR:63
if (CheatLib.eql(line, "READY?")) {
    // CLR:64
resp = try std.mem.concat(rt.frameAlloc(), u8, &.{ resp, "+READY\r\n" }); 
    } else {
    // CLR:66
resp = try std.mem.concat(rt.frameAlloc(), u8, &.{ resp, "-ERR unknown command\r\n" }); 
    }
    }
    }
    } 
rt.checkYield();
}
// CLR:69
if ((CheatLib.len(@as([]const u8, resp)) > 0)) {
    // CLR:69
try CheatLib.socketWriteVoid(client, @as([]const u8, resp));
    }
    } 
rt.checkYield();
}
}


// CLR:74
fn clearMain(rt: *Runtime) !void {
    const frame_mark = rt.saveFrameMark();
defer rt.restoreFrameMark(frame_mark);

    // CLR:75
var server: i32 = try CheatLib.socketListen(@intCast(6390)); _ = &server;
var server_moved = false; _ = &server_moved;
defer if (!server_moved) CheatLib.socketClose(server);


// CLR:76
std.debug.print("{s}\n", .{"CLEAR pathological server listening on port 6390"});
// CLR:80
var pin = CheatLib.MutexShardedStringMap(i64, 32){ .alloc = rt.heapAlloc() }; _ = &pin;
var pin_moved = false; _ = &pin_moved;
defer if (!pin_moved) CheatLib.cleanup(CheatLib.MutexShardedStringMap(i64, 32), rt.heapAlloc(), &pin);


// CLR:82
var tasks = std.ArrayListUnmanaged(CheatLib.Promise(void)){}; _ = &tasks;
var tasks_moved = false; _ = &tasks_moved;
defer if (!tasks_moved) CheatLib.cleanup(std.ArrayListUnmanaged(CheatLib.Promise(void)), rt.frameAlloc(), &tasks);


// CLR:83
while (true) {
 // CLR:84
var client: i32 = try CheatLib.socketAccept(server); _ = &client;
var client_moved = false; _ = &client_moved;
defer if (!client_moved) CheatLib.socketClose(client);


// CLR:85
try tasks.append(rt.frameAlloc(), __bg0: {
    const __BgCtx0 = struct {
        inner: *CheatLib.Promise(void).Inner,
        alloc: std.mem.Allocator,
        pin: *CheatLib.MutexShardedStringMap(i64, 32),
        client: i32,
        fn run(__raw_rt_0: *anyopaque, __raw_args_0: ?*anyopaque) anyerror!void {
            const __rt_bg0 = @as(*Runtime, @ptrCast(@alignCast(__raw_rt_0)));
            
            
            const __ctx_0 = @as(*@This(), @ptrCast(@alignCast(__raw_args_0.?)));
            defer __ctx_0.alloc.destroy(__ctx_0);
            defer __ctx_0.inner.wg.done();
            errdefer |fiber_err| __ctx_0.inner.result = fiber_err;
            defer CheatLib.socketClose(__ctx_0.client);
            const n: i64 = __ctx_0.pin.count(); _ = n;


            try handleClient(__rt_bg0, __ctx_0.client);
            __ctx_0.inner.result = {};
        }
    };
    const __bg0_alloc = rt.getSched().allocator;
    const __bg0_promise = try CheatLib.Promise(void).spawn(__bg0_alloc, rt.getSched());
    
    const __bg0_ctx = try __bg0_alloc.create(__BgCtx0);
    __bg0_ctx.* = .{ .inner = __bg0_promise.inner, .alloc = __bg0_alloc, .pin = &pin, .client = client };
    client_moved = true;
    try CheatHeader.spawnPinned(
            @intFromPtr(&Runtime.entryWrapper),
            @as(CheatHeader.TaskFn, @ptrCast(&__BgCtx0.run)),
            __bg0_ctx,
            .{ .stack_size = .Large, .pinned = true },
        );
    break :__bg0 __bg0_promise;
}); 
rt.checkYield();
}
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

