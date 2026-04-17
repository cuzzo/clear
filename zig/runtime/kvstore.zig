const std = @import("std");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = CheatHeader.Runtime;
const EbrContext = CheatHeader.EbrContext;
pub const USE_C_ALLOCATOR = true;

// -------------------------------------------------------------------------
// 2. User Types & Functions (Transpiled)
// -------------------------------------------------------------------------
fn handleClient(rt: *Runtime, client: i32, _m_store: anytype, _m_counters: anytype) !void {
    _ = &rt;
    var store = _m_store; _ = &store;
    var counters = _m_counters; _ = &counters;
    var running: bool = true; 


while (running) {
const __loop_mark_2 = rt.saveLoopMark(); defer rt.restoreLoopMark(__loop_mark_2);
 const data: []const u8 = try CheatLib.socketRead(rt.frameAlloc(), client); 


if ((CheatLib.len(data) == 0)) {
    running = false; 
    } else {
    var resp: []const u8 = ""; 


var pos: i64 = 0; 


while (((pos < CheatLib.len(data)) and running)) {
 var ch: []const u8 = CheatLib.charAt(data, pos); _ = &ch;


if (CheatLib.eql(ch, "*")) {
    pos = (pos + 1); 
var countStr: []const u8 = ""; 


while (((pos < CheatLib.len(data)) and !CheatLib.eql(CheatLib.charAt(data, pos), "\r"))) {
 countStr = @as([]const u8, try CheatLib.concat(rt.frameAlloc(), countStr, CheatLib.charAt(data, pos))); 
pos = (pos + 1);  
rt.checkYield();
}
var argCount: i64 = @intFromFloat((((std.fmt.parseFloat(f64, @as([]const u8, countStr)) catch null)) orelse (0.0 - 1.0))); _ = &argCount;


pos = (pos + 2); 
var arg0: []const u8 = ""; 


var arg1: []const u8 = ""; 


var arg2: []const u8 = ""; 


var ai: i64 = 0; 


while (((ai < argCount) and (pos < CheatLib.len(data)))) {
const __loop_mark_1 = rt.saveLoopMark(); defer rt.restoreLoopMark(__loop_mark_1);
 if (CheatLib.eql(CheatLib.charAt(data, pos), "$")) {
    pos = (pos + 1); 
var lenStr: []const u8 = ""; 


while (((pos < CheatLib.len(data)) and !CheatLib.eql(CheatLib.charAt(data, pos), "\r"))) {
 lenStr = @as([]const u8, try CheatLib.concat(rt.frameAlloc(), lenStr, CheatLib.charAt(data, pos))); 
pos = (pos + 1);  
rt.checkYield();
}
var len: i64 = @intFromFloat((((std.fmt.parseFloat(f64, @as([]const u8, lenStr)) catch null)) orelse (0.0 - 1.0))); _ = &len;


pos = (pos + 2); 
var val: []const u8 = try CheatLib.substr(rt.frameAlloc(), data, pos, len); _ = &val;


pos = (pos + len); 
pos = (pos + 2); 
if ((ai == 0)) {
    arg0 = @as([]const u8, val); 
    } else {
    if ((ai == 1)) {
    arg1 = @as([]const u8, val); 
    } else {
    if ((ai == 2)) {
    arg2 = @as([]const u8, val); 
    }
    }
    }
    }
ai = (ai + 1);  
rt.checkYield();
}
if ((CheatLib.eql(arg0, "SET") or CheatLib.eql(arg0, "set"))) {
    try store.put(rt.frameAlloc(), rt.frameAlloc(), arg1, @as([]const u8, arg2));
resp = try CheatLib.concat(rt.frameAlloc(), resp, "+OK\r\n"); 
    } else {
    if ((CheatLib.eql(arg0, "GET") or CheatLib.eql(arg0, "get"))) {
    var result: []const u8 = ((store.get(arg1)) orelse ""); _ = &result;


if ((CheatLib.len(result) > 0)) {
    resp = @as([]const u8, try CheatLib.concat(rt.frameAlloc(), try CheatLib.concat(rt.frameAlloc(), try CheatLib.concat(rt.frameAlloc(), try CheatLib.concat(rt.frameAlloc(), try CheatLib.concat(rt.frameAlloc(), resp, "$"), try CheatLib.intToString(rt.frameAlloc(), CheatLib.len(result))), "\r\n"), result), "\r\n")); 
    } else {
    resp = try CheatLib.concat(rt.frameAlloc(), resp, "$-1\r\n"); 
    }
    } else {
    if ((CheatLib.eql(arg0, "INCR") or CheatLib.eql(arg0, "incr"))) {
    if ((CheatLib.len(@as([]const u8, arg1)) > 0)) {
    const newVal: i64 = (((counters.get(arg1)) orelse 0) + 1); 


try counters.put(rt.frameAlloc(), rt.frameAlloc(), arg1, newVal);
resp = @as([]const u8, try CheatLib.concat(rt.frameAlloc(), try CheatLib.concat(rt.frameAlloc(), try CheatLib.concat(rt.frameAlloc(), resp, ":"), try CheatLib.intToString(rt.frameAlloc(), newVal)), "\r\n")); 
    } else {
    resp = try CheatLib.concat(rt.frameAlloc(), resp, "-ERR wrong number of arguments for 'INCR'\r\n"); 
    }
    } else {
    if ((CheatLib.eql(arg0, "DECR") or CheatLib.eql(arg0, "decr"))) {
    if ((CheatLib.len(@as([]const u8, arg1)) > 0)) {
    const newVal: i64 = (((counters.get(arg1)) orelse 0) - 1); 


try counters.put(rt.frameAlloc(), rt.frameAlloc(), arg1, newVal);
resp = @as([]const u8, try CheatLib.concat(rt.frameAlloc(), try CheatLib.concat(rt.frameAlloc(), try CheatLib.concat(rt.frameAlloc(), resp, ":"), try CheatLib.intToString(rt.frameAlloc(), newVal)), "\r\n")); 
    } else {
    resp = try CheatLib.concat(rt.frameAlloc(), resp, "-ERR wrong number of arguments for 'DECR'\r\n"); 
    }
    } else {
    if ((CheatLib.eql(arg0, "PING") or CheatLib.eql(arg0, "ping"))) {
    resp = try CheatLib.concat(rt.frameAlloc(), resp, "+PONG\r\n"); 
    } else {
    if ((CheatLib.eql(arg0, "COMMAND") or CheatLib.eql(arg0, "command"))) {
    resp = try CheatLib.concat(rt.frameAlloc(), resp, "*0\r\n"); 
    } else {
    if ((CheatLib.eql(arg0, "QUIT") or CheatLib.eql(arg0, "quit"))) {
    resp = try CheatLib.concat(rt.frameAlloc(), resp, "+OK\r\n"); 
running = false; 
    } else {
    resp = try CheatLib.concat(rt.frameAlloc(), try CheatLib.concat(rt.frameAlloc(), try CheatLib.concat(rt.frameAlloc(), resp, "-ERR unknown command '"), arg0), "'\r\n"); 
    }
    }
    }
    }
    }
    }
    }
    } else {
    if ((CheatLib.eql(ch, "\r") or CheatLib.eql(ch, "\n"))) {
    pos = (pos + 1); 
    } else {
    var cmd: []const u8 = ""; 


while ((((pos < CheatLib.len(data)) and !CheatLib.eql(CheatLib.charAt(data, pos), "\r")) and !CheatLib.eql(CheatLib.charAt(data, pos), "\n"))) {
 cmd = @as([]const u8, try CheatLib.concat(rt.frameAlloc(), cmd, CheatLib.charAt(data, pos))); 
pos = (pos + 1);  
rt.checkYield();
}
while (((pos < CheatLib.len(data)) and (CheatLib.eql(CheatLib.charAt(data, pos), "\r") or CheatLib.eql(CheatLib.charAt(data, pos), "\n")))) {
 pos = (pos + 1);  
rt.checkYield();
}
if ((CheatLib.eql(cmd, "PING") or CheatLib.eql(cmd, "ping"))) {
    resp = try CheatLib.concat(rt.frameAlloc(), resp, "+PONG\r\n"); 
    } else {
    if ((CheatLib.eql(cmd, "QUIT") or CheatLib.eql(cmd, "quit"))) {
    resp = try CheatLib.concat(rt.frameAlloc(), resp, "+OK\r\n"); 
running = false; 
    } else {
    resp = try CheatLib.concat(rt.frameAlloc(), try CheatLib.concat(rt.frameAlloc(), try CheatLib.concat(rt.frameAlloc(), resp, "-ERR unknown command '"), cmd), "'\r\n"); 
    }
    }
    }
    } 
rt.checkYield();
}
if ((CheatLib.len(@as([]const u8, resp)) > 0)) {
    try CheatLib.socketWriteVoid(client, @as([]const u8, resp));
    }
    } 
rt.checkYield();
}
}


fn cheatMain(rt: *Runtime) !void {
    _ = &rt;
    var store = CheatLib.MutexShardedStringMap([]const u8, 8){ .alloc = rt.heapAlloc() }; _ = &store;
defer store.deinit(rt.heapAlloc(), rt.heapAlloc());


var counters = CheatLib.MutexShardedStringMap(i64, 8){ .alloc = rt.heapAlloc() }; _ = &counters;
defer counters.deinit(rt.heapAlloc(), rt.heapAlloc());


const server = try CheatLib.socketListen(@intCast(6380)); 
var server_moved = false; _ = &server_moved;
defer if (!server_moved) CheatLib.socketClose(server);


std.debug.print("{s}\n", .{"CLEAR kvstore listening on port 6380"});
var tasks = std.ArrayListUnmanaged(CheatLib.Promise(void)){}; _ = &tasks;
defer tasks.deinit(rt.frameAlloc());


while (true) {
 const client = try CheatLib.socketAccept(server); 
var client_moved = false; _ = &client_moved;
defer if (!client_moved) CheatLib.socketClose(client);


try tasks.append(rt.frameAlloc(), __bg0: {
    const __BgCtx0 = struct {
        inner: *CheatLib.Promise(void).Inner,
        alloc: std.mem.Allocator,
        client: i32,
        store: *CheatLib.MutexShardedStringMap([]const u8, 8),
        counters: *CheatLib.MutexShardedStringMap(i64, 8),
        fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
            _ = &__rt;
            
            const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
            defer ctx.alloc.destroy(ctx);
            defer ctx.inner.wg.done();
            
            try handleClient(__rt, ctx.client, ctx.store, ctx.counters);
        }
    };
    const __bg0_alloc = rt.getSched().allocator;
    const __bg0_promise = try CheatLib.Promise(void).spawn(__bg0_alloc, rt.getSched());
    const __bg0_ctx = try __bg0_alloc.create(__BgCtx0);
    __bg0_ctx.* = .{ .inner = __bg0_promise.inner, .alloc = __bg0_alloc, .client = client, .store = &store, .counters = &counters };
    client_moved = true;
    try CheatHeader.spawnPinned(
            @intFromPtr(&Runtime.entryWrapper),
            @as(CheatHeader.TaskFn, @ptrCast(&__BgCtx0.run)),
            __bg0_ctx,
            .{ .stack_size = .Standard, .pinned = true },
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
// epoll instance.  The main thread runs Scheduler 0 (which owns cheatMain);
// N-1 worker threads run idle schedulers that steal work via the existing
// Chase-Lev work-stealing deque in RunQueue.
//
// Shared state (heap-allocated, outlives all threads):
//   - GPA allocator
//   - EbrContext  (thread-safe — has its own registry_lock)
//   - StackPool   (thread-safe — slab allocator with atomic free lists)
//   - shutdown    (atomic bool — signals workers to exit after cheatMain)
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
        if (std.c.getenv("CLEAR_THREADS")) |env_ptr| {
            const n = std.fmt.parseInt(usize, std.mem.span(env_ptr), 10) catch 1;
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

    // 8. Submit cheatMain as a fiber on the main scheduler.
    const MainRunner = struct {
        outer_rt: *Runtime,
        fn run(_: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw_args.?));
            const result = try cheatMain(self.outer_rt);
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

