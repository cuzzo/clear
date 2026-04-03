const std = @import("std");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = CheatHeader.Runtime;
const EbrContext = CheatHeader.EbrContext;

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
return @mod(x, 1000000000);
}


// CLR:24
fn handleClient(rt: *Runtime, client: i32) !void {
    const frame_mark = rt.saveFrameMark();
defer rt.restoreFrameMark(frame_mark);

    // CLR:25
var running: bool = true; 


// CLR:26
while (running) {
const __loop_mark_1 = rt.saveLoopMark(); defer rt.restoreLoopMark(__loop_mark_1);
 // CLR:27
const data: []const u8 = try CheatLib.socketRead(rt.frameAlloc(), client); 


// CLR:28
if ((CheatLib.len(data) == 0)) {
    // CLR:29
running = false; 
    } else {
    // CLR:31
var resp: []const u8 = ""; 


// CLR:32
var pos: i64 = 0; 


// CLR:33
while ((pos < CheatLib.len(data))) {
 // CLR:34
var eol: i64 = pos; 


// CLR:35
while ((((eol < CheatLib.len(data)) and !CheatLib.eql(try CheatLib.charAtCodepoint(rt.frameAlloc(), data, eol), "\r")) and !CheatLib.eql(try CheatLib.charAtCodepoint(rt.frameAlloc(), data, eol), "\n"))) {
 // CLR:36
eol = CheatLib.intAdd(eol, 1);  
rt.checkYield();
}
// CLR:38
const line: []const u8 = try CheatLib.substr(rt.frameAlloc(), data, pos, CheatLib.intSub(eol, pos)); 


// CLR:39
pos = eol; 
// CLR:40
while (((pos < CheatLib.len(data)) and (CheatLib.eql(try CheatLib.charAtCodepoint(rt.frameAlloc(), data, pos), "\r") or CheatLib.eql(try CheatLib.charAtCodepoint(rt.frameAlloc(), data, pos), "\n")))) {
 // CLR:41
pos = CheatLib.intAdd(pos, 1);  
rt.checkYield();
}
// CLR:44
if ((CheatLib.len(line) == 0)) {
    
    } else {
    // CLR:46
if (std.mem.startsWith(u8, line, @as([]const u8, "WORK:"))) {
    // CLR:47
const rest: []const u8 = try CheatLib.substr(rt.frameAlloc(), line, 5, CheatLib.intSub(CheatLib.len(line), 5)); 


// CLR:48
var colonPos: i64 = 0; 


// CLR:49
while (((colonPos < CheatLib.len(rest)) and !CheatLib.eql(try CheatLib.charAtCodepoint(rt.frameAlloc(), rest, colonPos), ":"))) {
 // CLR:50
colonPos = CheatLib.intAdd(colonPos, 1);  
rt.checkYield();
}
// CLR:52
const idStr: []const u8 = try CheatLib.substr(rt.frameAlloc(), rest, 0, colonPos); 


// CLR:53
const nStr: []const u8 = try CheatLib.substr(rt.frameAlloc(), rest, CheatLib.intAdd(colonPos, 1), CheatLib.intSub(CheatLib.intSub(CheatLib.len(rest), colonPos), 1)); 


// CLR:54
const id: i64 = @intFromFloat((((std.fmt.parseFloat(f64, idStr) catch null)) orelse 1.0)); 


// CLR:55
var n: i64 = @intFromFloat((((std.fmt.parseFloat(f64, nStr) catch null)) orelse 1.0)); 


// CLR:56
if ((n < 1)) {
    // CLR:56
n = 1; 
    }
// CLR:57
const result: i64 = heavyCompute(id, n); 


// CLR:58
resp = @as([]const u8, try std.mem.concat(rt.frameAlloc(), u8, &.{ resp, ":", try CheatLib.intToString(rt.frameAlloc(), result), "\r\n" })); 
    } else {
    // CLR:59
if (CheatLib.eql(line, "QUIT")) {
    // CLR:60
resp = try std.mem.concat(rt.frameAlloc(), u8, &.{ resp, "+OK\r\n" }); 
// CLR:61
running = false; 
    } else {
    // CLR:62
if (CheatLib.eql(line, "READY?")) {
    // CLR:63
resp = try std.mem.concat(rt.frameAlloc(), u8, &.{ resp, "+READY\r\n" }); 
    } else {
    // CLR:65
resp = try std.mem.concat(rt.frameAlloc(), u8, &.{ resp, "-ERR unknown command\r\n" }); 
    }
    }
    }
    } 
rt.checkYield();
}
// CLR:68
if ((CheatLib.len(@as([]const u8, resp)) > 0)) {
    // CLR:68
try CheatLib.socketWriteVoid(client, @as([]const u8, resp));
    }
    } 
rt.checkYield();
}
}


// CLR:73
fn clearMain(rt: *Runtime) !void {
    const frame_mark = rt.saveFrameMark();
defer rt.restoreFrameMark(frame_mark);

    // CLR:74
var server: i32 = try CheatLib.socketListen(@intCast(6390)); _ = &server;
var server_moved = false; _ = &server_moved;
defer if (!server_moved) CheatLib.socketClose(server);


// CLR:75
std.debug.print("{s}\n", .{"CLEAR pathological server listening on port 6390"});
// CLR:77
var tasks = std.ArrayListUnmanaged(CheatLib.Promise(void)){}; _ = &tasks;
defer tasks.deinit(rt.frameAlloc());


// CLR:78
while (true) {
 // CLR:79
var client: i32 = try CheatLib.socketAccept(server); _ = &client;
var client_moved = false; _ = &client_moved;
defer if (!client_moved) CheatLib.socketClose(client);


// CLR:80
try tasks.append(rt.frameAlloc(), __bg0: {
    const __BgCtx0 = struct {
        inner: *CheatLib.Promise(void).Inner,
        alloc: std.mem.Allocator,
        client: i32,
        fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
            
            
            const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
            defer ctx.alloc.destroy(ctx);
            defer ctx.inner.wg.done();
            errdefer |fiber_err| ctx.inner.result = fiber_err;
            defer CheatLib.socketClose(ctx.client);
            
            try handleClient(__rt, ctx.client);
            ctx.inner.result = {};
        }
    };
    const __bg0_alloc = rt.getSched().allocator;
    const __bg0_promise = try CheatLib.Promise(void).spawn(__bg0_alloc, rt.getSched());
    
    const __bg0_ctx = try __bg0_alloc.create(__BgCtx0);
    __bg0_ctx.* = .{ .inner = __bg0_promise.inner, .alloc = __bg0_alloc, .client = client };
    client_moved = true;
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

