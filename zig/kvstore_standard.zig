const std = @import("std");

const CheatHeader = @import("runtime-header.zig");

const CheatLib = CheatHeader.CheatLib;

const Runtime = CheatHeader.Runtime;

const EbrContext = CheatHeader.EbrContext;

// CLR:11

fn handleClient(rt: *Runtime, client: i32, _m_store: anytype, _m_counters: anytype) !void {
@setEvalBranchQuota(100000);
const frame_mark = rt.saveFrameMark();
defer rt.restoreFrameMark(frame_mark);
var store = _m_store; _ = &store;
var counters = _m_counters; _ = &counters;
var running: bool = true;
while (running) {
const __loop_mark_3 = rt.saveLoopMark();
defer rt.restoreLoopMark(__loop_mark_3);
const data = try CheatLib.socketRead(rt.frameAlloc(), client);
if ((CheatLib.len(data) == 0)) {
running = false;
} else {
var resp: []const u8 = try rt.heapAlloc().dupe(u8, ""); _ = &resp;
defer rt.heapAlloc().free(resp);

var pos: i64 = 0;
while (((pos < CheatLib.len(data)) and running)) {
const __loop_mark_2 = rt.saveLoopMark();
defer rt.restoreLoopMark(__loop_mark_2);
const ch = CheatLib.charAt(data, pos);
if (CheatLib.eql(ch, "*")) {
pos = CheatLib.intAdd(pos, 1);
var crPos: i64 = pos;
while (((crPos < CheatLib.len(data)) and !CheatLib.eql(CheatLib.charAt(data, crPos), "\r"))) {
crPos = CheatLib.intAdd(crPos, 1);
rt.checkYield();
}
const countStr = CheatLib.substrRaw(data, pos, CheatLib.intSub(crPos, pos));
const argCount: i64 = @intFromFloat(((std.fmt.parseFloat(f64, countStr) catch null) orelse (0.0 - 1.0)));
pos = CheatLib.intAdd(crPos, 2);
var arg0: []const u8 = try rt.heapAlloc().dupe(u8, ""); _ = &arg0;
defer rt.heapAlloc().free(arg0);

var arg1: []const u8 = try rt.heapAlloc().dupe(u8, ""); _ = &arg1;
defer rt.heapAlloc().free(arg1);

var arg2: []const u8 = try rt.heapAlloc().dupe(u8, ""); _ = &arg2;
defer rt.heapAlloc().free(arg2);

var ai: i64 = 0;
while (((ai < argCount) and (pos < CheatLib.len(data)))) {
const __loop_mark_1 = rt.saveLoopMark();
defer rt.restoreLoopMark(__loop_mark_1);
if (CheatLib.eql(CheatLib.charAt(data, pos), "$")) {
pos = CheatLib.intAdd(pos, 1);
var crPos2: i64 = pos;
while (((crPos2 < CheatLib.len(data)) and !CheatLib.eql(CheatLib.charAt(data, crPos2), "\r"))) {
crPos2 = CheatLib.intAdd(crPos2, 1);
rt.checkYield();
}
const lenStr = CheatLib.substrRaw(data, pos, CheatLib.intSub(crPos2, pos));
const len: i64 = @intFromFloat(((std.fmt.parseFloat(f64, lenStr) catch null) orelse (0.0 - 1.0)));
pos = CheatLib.intAdd(crPos2, 2);
const val = CheatLib.substrRaw(data, pos, len);
pos = CheatLib.intAdd(pos, len);
pos = CheatLib.intAdd(pos, 2);
if ((ai == 0)) {
{
const __new_arg0 = @as([]const u8, val);
CheatLib.cleanup([]const u8, rt.heapAlloc(), &arg0);
arg0 = __new_arg0;
}
} else {
if ((ai == 1)) {
{
const __new_arg1 = @as([]const u8, val);
CheatLib.cleanup([]const u8, rt.heapAlloc(), &arg1);
arg1 = __new_arg1;
}
} else {
if ((ai == 2)) {
{
const __new_arg2 = @as([]const u8, val);
CheatLib.cleanup([]const u8, rt.heapAlloc(), &arg2);
arg2 = __new_arg2;
}
}
}
}
}
ai = CheatLib.intAdd(ai, 1);
rt.checkYield();
}
if ((CheatLib.eql(arg0, "SET") or CheatLib.eql(arg0, "set"))) {
try store.put(rt.heapAlloc(), rt.heapAlloc(), arg1, try rt.heapAlloc().dupe(u8, @as([]const u8, arg2)));
{
const __new_resp = try std.mem.concat(rt.heapAlloc(), u8, &.{ resp, "+OK\r\n" });
CheatLib.cleanup([]const u8, rt.heapAlloc(), &resp);
resp = __new_resp;
}
} else {
if ((CheatLib.eql(arg0, "GET") or CheatLib.eql(arg0, "get"))) {
const result: []const u8 = (store.get(arg1) orelse "");
if ((CheatLib.len(result) > 0)) {
{
const __new_resp = try std.mem.concat(rt.heapAlloc(), u8, &.{ resp, "$", try CheatLib.intToString(rt.frameAlloc(), CheatLib.len(result)), "\r\n", result, "\r\n" });
CheatLib.cleanup([]const u8, rt.heapAlloc(), &resp);
resp = __new_resp;
}
} else {
{
const __new_resp = try std.mem.concat(rt.heapAlloc(), u8, &.{ resp, "$-1\r\n" });
CheatLib.cleanup([]const u8, rt.heapAlloc(), &resp);
resp = __new_resp;
}
}
} else {
if ((CheatLib.eql(arg0, "INCR") or CheatLib.eql(arg0, "incr"))) {
if ((CheatLib.len(@as([]const u8, arg1)) > 0)) {
const newVal: i64 = CheatLib.intAdd((counters.get(arg1) orelse 0), 1);
try counters.put(rt.heapAlloc(), rt.heapAlloc(), arg1, newVal);
{
const __new_resp = try std.mem.concat(rt.heapAlloc(), u8, &.{ resp, ":", try CheatLib.intToString(rt.frameAlloc(), newVal), "\r\n" });
CheatLib.cleanup([]const u8, rt.heapAlloc(), &resp);
resp = __new_resp;
}
} else {
{
const __new_resp = try std.mem.concat(rt.heapAlloc(), u8, &.{ resp, "-ERR wrong number of arguments for 'INCR'\r\n" });
CheatLib.cleanup([]const u8, rt.heapAlloc(), &resp);
resp = __new_resp;
}
}
} else {
if ((CheatLib.eql(arg0, "DECR") or CheatLib.eql(arg0, "decr"))) {
if ((CheatLib.len(@as([]const u8, arg1)) > 0)) {
const newVal: i64 = CheatLib.intSub((counters.get(arg1) orelse 0), 1);
try counters.put(rt.heapAlloc(), rt.heapAlloc(), arg1, newVal);
{
const __new_resp = try std.mem.concat(rt.heapAlloc(), u8, &.{ resp, ":", try CheatLib.intToString(rt.frameAlloc(), newVal), "\r\n" });
CheatLib.cleanup([]const u8, rt.heapAlloc(), &resp);
resp = __new_resp;
}
} else {
{
const __new_resp = try std.mem.concat(rt.heapAlloc(), u8, &.{ resp, "-ERR wrong number of arguments for 'DECR'\r\n" });
CheatLib.cleanup([]const u8, rt.heapAlloc(), &resp);
resp = __new_resp;
}
}
} else {
if ((CheatLib.eql(arg0, "PING") or CheatLib.eql(arg0, "ping"))) {
{
const __new_resp = try std.mem.concat(rt.heapAlloc(), u8, &.{ resp, "+PONG\r\n" });
CheatLib.cleanup([]const u8, rt.heapAlloc(), &resp);
resp = __new_resp;
}
} else {
if ((CheatLib.eql(arg0, "COMMAND") or CheatLib.eql(arg0, "command"))) {
{
const __new_resp = try std.mem.concat(rt.heapAlloc(), u8, &.{ resp, "*0\r\n" });
CheatLib.cleanup([]const u8, rt.heapAlloc(), &resp);
resp = __new_resp;
}
} else {
if ((CheatLib.eql(arg0, "CONFIG") or CheatLib.eql(arg0, "config"))) {
if ((CheatLib.eql(arg1, "SET") or CheatLib.eql(arg1, "set"))) {
{
const __new_resp = try std.mem.concat(rt.heapAlloc(), u8, &.{ resp, "+OK\r\n" });
CheatLib.cleanup([]const u8, rt.heapAlloc(), &resp);
resp = __new_resp;
}
} else {
{
const __new_resp = try std.mem.concat(rt.heapAlloc(), u8, &.{ resp, "*0\r\n" });
CheatLib.cleanup([]const u8, rt.heapAlloc(), &resp);
resp = __new_resp;
}
}
} else {
if ((CheatLib.eql(arg0, "CLIENT") or CheatLib.eql(arg0, "client"))) {
{
const __new_resp = try std.mem.concat(rt.heapAlloc(), u8, &.{ resp, "+OK\r\n" });
CheatLib.cleanup([]const u8, rt.heapAlloc(), &resp);
resp = __new_resp;
}
} else {
if ((CheatLib.eql(arg0, "FLUSHALL") or CheatLib.eql(arg0, "flushall"))) {
{
const __new_resp = try std.mem.concat(rt.heapAlloc(), u8, &.{ resp, "+OK\r\n" });
CheatLib.cleanup([]const u8, rt.heapAlloc(), &resp);
resp = __new_resp;
}
} else {
if ((CheatLib.eql(arg0, "FLUSHDB") or CheatLib.eql(arg0, "flushdb"))) {
{
const __new_resp = try std.mem.concat(rt.heapAlloc(), u8, &.{ resp, "+OK\r\n" });
CheatLib.cleanup([]const u8, rt.heapAlloc(), &resp);
resp = __new_resp;
}
} else {
if ((CheatLib.eql(arg0, "DBSIZE") or CheatLib.eql(arg0, "dbsize"))) {
{
const __new_resp = try std.mem.concat(rt.heapAlloc(), u8, &.{ resp, ":0\r\n" });
CheatLib.cleanup([]const u8, rt.heapAlloc(), &resp);
resp = __new_resp;
}
} else {
if ((CheatLib.eql(arg0, "QUIT") or CheatLib.eql(arg0, "quit"))) {
{
const __new_resp = try std.mem.concat(rt.heapAlloc(), u8, &.{ resp, "+OK\r\n" });
CheatLib.cleanup([]const u8, rt.heapAlloc(), &resp);
resp = __new_resp;
}
running = false;
} else {
{
const __new_resp = try std.mem.concat(rt.heapAlloc(), u8, &.{ resp, "-ERR unknown command '", arg0, "'\r\n" });
CheatLib.cleanup([]const u8, rt.heapAlloc(), &resp);
resp = __new_resp;
}
}
}
}
}
}
}
}
}
}
}
}
}
} else {
if ((CheatLib.eql(ch, "\r") or CheatLib.eql(ch, "\n"))) {
pos = CheatLib.intAdd(pos, 1);
} else {
var cmdEnd: i64 = pos;
while ((((cmdEnd < CheatLib.len(data)) and !CheatLib.eql(CheatLib.charAt(data, cmdEnd), "\r")) and !CheatLib.eql(CheatLib.charAt(data, cmdEnd), "\n"))) {
cmdEnd = CheatLib.intAdd(cmdEnd, 1);
rt.checkYield();
}
const cmd = CheatLib.substrRaw(data, pos, CheatLib.intSub(cmdEnd, pos));
pos = cmdEnd;
while (((pos < CheatLib.len(data)) and (CheatLib.eql(CheatLib.charAt(data, pos), "\r") or CheatLib.eql(CheatLib.charAt(data, pos), "\n")))) {
pos = CheatLib.intAdd(pos, 1);
rt.checkYield();
}
if ((CheatLib.eql(cmd, "PING") or CheatLib.eql(cmd, "ping"))) {
{
const __new_resp = try std.mem.concat(rt.heapAlloc(), u8, &.{ resp, "+PONG\r\n" });
CheatLib.cleanup([]const u8, rt.heapAlloc(), &resp);
resp = __new_resp;
}
} else {
if (CheatLib.eql(cmd, "READY?")) {
{
const __new_resp = try std.mem.concat(rt.heapAlloc(), u8, &.{ resp, "+READY\r\n" });
CheatLib.cleanup([]const u8, rt.heapAlloc(), &resp);
resp = __new_resp;
}
} else {
if ((CheatLib.eql(cmd, "QUIT") or CheatLib.eql(cmd, "quit"))) {
{
const __new_resp = try std.mem.concat(rt.heapAlloc(), u8, &.{ resp, "+OK\r\n" });
CheatLib.cleanup([]const u8, rt.heapAlloc(), &resp);
resp = __new_resp;
}
running = false;
} else {
{
const __new_resp = try std.mem.concat(rt.heapAlloc(), u8, &.{ resp, "-ERR unknown command '", cmd, "'\r\n" });
CheatLib.cleanup([]const u8, rt.heapAlloc(), &resp);
resp = __new_resp;
}
}
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

// CLR:144

fn clearMain(rt: *Runtime) !void {
@setEvalBranchQuota(100000);
const frame_mark = rt.saveFrameMark();
defer rt.restoreFrameMark(frame_mark);
var store = CheatLib.MutexShardedStringMap([]const u8, 128){ .alloc = rt.heapAlloc() }; _ = &store;
defer CheatLib.cleanup(CheatLib.MutexShardedStringMap([]const u8, 128), rt.heapAlloc(), &store);

var counters = CheatLib.MutexShardedStringMap(i64, 128){ .alloc = rt.heapAlloc() }; _ = &counters;
defer CheatLib.cleanup(CheatLib.MutexShardedStringMap(i64, 128), rt.heapAlloc(), &counters);

var server = try CheatLib.socketListen(@intCast(6390)); _ = &server;
defer CheatLib.socketClose(server);

std.debug.print("{s}\n", .{"CLEAR kvstore listening on port 6390"});
var tasks = std.ArrayListUnmanaged(CheatLib.Promise(void)){}; _ = &tasks;
defer CheatLib.cleanup(std.ArrayListUnmanaged(CheatLib.Promise(void)), rt.frameAlloc(), &tasks);

while (true) {
var client = try CheatLib.socketAccept(server); _ = &client;
var client_moved = false; _ = &client_moved;
defer if (!client_moved) CheatLib.socketClose(client);

try tasks.append(rt.frameAlloc(), __bg0: {
    const __BgCtx0 = struct {
        inner: *CheatLib.Promise(void).Inner,
        alloc: std.mem.Allocator,
        client: i32,
        store: *CheatLib.MutexShardedStringMap([]const u8, 128),
        counters: *CheatLib.MutexShardedStringMap(i64, 128),
        fn run(__raw_rt_0: *anyopaque, __raw_args_0: ?*anyopaque) anyerror!void {
            const __rt_bg0 = @as(*Runtime, @ptrCast(@alignCast(__raw_rt_0)));
            
            
            const __ctx_0 = @as(*@This(), @ptrCast(@alignCast(__raw_args_0.?)));
            defer __ctx_0.alloc.destroy(__ctx_0);
            defer __ctx_0.inner.wg.done();
            errdefer |fiber_err| __ctx_0.inner.result = fiber_err;
            defer CheatLib.socketClose(__ctx_0.client);
            
            try handleClient(__rt_bg0, __ctx_0.client, __ctx_0.store, __ctx_0.counters);
            __ctx_0.inner.result = {};
        }
    };
    const __bg0_alloc = rt.getSched().allocator;
    const __bg0_promise = try CheatLib.Promise(void).spawn(__bg0_alloc, rt.getSched());
    
    const __bg0_ctx = try __bg0_alloc.create(__BgCtx0);
    errdefer __bg0_alloc.destroy(__bg0_ctx);
    __bg0_ctx.* = .{ .inner = __bg0_promise.inner, .alloc = __bg0_alloc, .client = client, .store = &store, .counters = &counters };
    try CheatHeader.spawnPinned(
    @intFromPtr(&Runtime.entryWrapper),
    @as(CheatHeader.TaskFn, @ptrCast(&__BgCtx0.run)),
    __bg0_ctx,
    .{ .stack_size = .Standard }
);
    break :__bg0 __bg0_promise;
});
client_moved = true;
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
        .{ .stack_size = .Large, .pinned = true },
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

