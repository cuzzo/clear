const std = @import("std");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = CheatHeader.Runtime;
const EbrContext = CheatHeader.EbrContext;
pub const USE_C_ALLOCATOR = true;

// -------------------------------------------------------------------------
// 2. User Types & Functions (Transpiled)
// -------------------------------------------------------------------------
fn hFunc(x: f64, s: f64) f64 {
    
    return @exp((0.0 - (s * @log(x))));
}


fn hInt(x: f64, s: f64) f64 {
    
    const t: f64 = (1.0 - s); 


if ((@abs(t) > 1.0e-08)) {
    return ((std.math.pow(f64, x, t) - 1.0) / t);
    }
return @log(x);
}


fn hIntInv(x: f64, s: f64) f64 {
    
    const t: f64 = (1.0 - s); 


if ((@abs(t) > 1.0e-08)) {
    return std.math.pow(f64, ((t * x) + 1.0), (1.0 / t));
    }
return @exp(x);
}


fn zipfNext(_m_state: i64, n: i64, s: f64, hIntegral: f64, hFraction: f64) i64 {
    var state = _m_state; _ = &state;
    const hIntHalf: f64 = hInt(0.5, s); 


while (true) {
 state = ((state * 6364136223846793005) + 1442695040888963407); 
var uBits: i64 = state; 


if ((uBits < 0)) {
    uBits = (0 - uBits); 
    }
var u: f64 = (@as(f64, @floatFromInt(@mod(uBits, 1000000000))) / 1000000000.0); 


u = (hIntegral + (u * (hIntHalf - hIntegral))); 
const x: f64 = hIntInv(u, s); 


var k: i64 = @intFromFloat((x + 0.5)); 


if ((k < 1)) {
    k = 1; 
    }
if ((k > n)) {
    k = n; 
    }
if (((@as(f64, @floatFromInt(k)) - x) <= hFraction)) {
    return (k - 1);
    }
if ((u >= (hInt((@as(f64, @floatFromInt(k)) + 0.5), s) - hFunc(@as(f64, @floatFromInt(k)), s)))) {
    return (k - 1);
    } 
}
return 0;
}


fn doSet(rt: *Runtime, _m_map: anytype, start: i64, count: i64) !void {
    _ = &rt;
    var map = _m_map; _ = &map;
    var i: i64 = start; 


while ((i < (start + count))) {
 try map.put(rt.frameAlloc(), rt.frameAlloc(), try CheatLib.concat(rt.frameAlloc(), "key:", try CheatLib.intToString(rt.frameAlloc(), i)), try CheatLib.concat(rt.frameAlloc(), "value-", try CheatLib.intToString(rt.frameAlloc(), i)));
i = (i + 1);  
rt.checkYield();
}
return ;
}


fn doGet(rt: *Runtime, _m_map: anytype, start: i64, count: i64) !i64 {
    _ = &rt;
    var map = _m_map; _ = &map;
    var hits: i64 = 0; 


var i: i64 = start; 


while ((i < (start + count))) {
 var got: []const u8 = (map.get(try CheatLib.concat(rt.frameAlloc(), "key:", try CheatLib.intToString(rt.frameAlloc(), i)))) orelse ""; _ = &got;


if ((CheatLib.len(got) > 0)) {
    hits = (hits + 1); 
    }
i = (i + 1);  
rt.checkYield();
}
return hits;
}


fn doZipfGet(rt: *Runtime, _m_map: anytype, seed: i64, count: i64, n: i64, s: f64) !i64 {
    _ = &rt;
    var map = _m_map; _ = &map;
    const hIntegral: f64 = hInt((@as(f64, @floatFromInt(n)) + 0.5), s); 


const hFraction: f64 = (hFunc(1.5, s) - 1.0); 


var hits: i64 = 0; 


var state: i64 = seed; 


var i: i64 = 0; 


while ((i < count)) {
 const k: i64 = zipfNext(state, n, s, hIntegral, hFraction); 


state = ((state * 6364136223846793005) + 1442695040888963407); 
var got: []const u8 = (map.get(try CheatLib.concat(rt.frameAlloc(), "key:", try CheatLib.intToString(rt.frameAlloc(), k)))) orelse ""; _ = &got;


if ((CheatLib.len(got) > 0)) {
    hits = (hits + 1); 
    }
i = (i + 1);  
rt.checkYield();
}
return hits;
}


fn doZipfMixed(rt: *Runtime, _m_map: anytype, seed: i64, count: i64, n: i64, s: f64) !i64 {
    _ = &rt;
    var map = _m_map; _ = &map;
    const hIntegral: f64 = hInt((@as(f64, @floatFromInt(n)) + 0.5), s); 


const hFraction: f64 = (hFunc(1.5, s) - 1.0); 


var hits: i64 = 0; 


var state: i64 = seed; 


var i: i64 = 0; 


while ((i < count)) {
 const k: i64 = zipfNext(state, n, s, hIntegral, hFraction); 


state = ((state * 6364136223846793005) + 1442695040888963407); 
var decision: i64 = @mod(state, 100); 


if ((decision < 0)) {
    decision = (0 - decision); 
    }
if ((decision < 80)) {
    var got: []const u8 = (map.get(try CheatLib.concat(rt.frameAlloc(), "key:", try CheatLib.intToString(rt.frameAlloc(), k)))) orelse ""; _ = &got;


if ((CheatLib.len(got) > 0)) {
    hits = (hits + 1); 
    }
    } else {
    try map.put(rt.frameAlloc(), rt.frameAlloc(), try CheatLib.concat(rt.frameAlloc(), "key:", try CheatLib.intToString(rt.frameAlloc(), k)), try CheatLib.concat(rt.frameAlloc(), "updated-", try CheatLib.intToString(rt.frameAlloc(), i)));
    }
i = (i + 1);  
rt.checkYield();
}
return hits;
}


fn cheatMain(rt: *Runtime) !void {
    _ = &rt;
    var map = CheatLib.MutexShardedStringMap([]const u8, 8){ .alloc = rt.heapAlloc() }; _ = &map;
defer map.deinit(rt.heapAlloc(), rt.heapAlloc());


const n: i64 = 1000000; 


const workers: i64 = 8; 


const chunk: i64 = (n / workers); 


const zipfSkew: f64 = 1.0; 


var set_futures = std.ArrayListUnmanaged(CheatLib.Promise(void)){}; _ = &set_futures;
defer set_futures.deinit(rt.frameAlloc());


var wi: i64 = 0; 


while ((wi < workers)) {
 const start: i64 = (wi * chunk); 


try set_futures.append(rt.frameAlloc(), __bg0: {
    const __BgCtx0 = struct {
        inner: *CheatLib.Promise(void).Inner,
        alloc: std.mem.Allocator,
        map: *CheatLib.MutexShardedStringMap([]const u8, 8),
        start: i64,
        chunk: i64,
        fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
            _ = &__rt;
            
            const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
            defer ctx.alloc.destroy(ctx);
            defer ctx.inner.wg.done();
            
            try doSet(__rt, ctx.map, ctx.start, ctx.chunk);
        }
    };
    const __bg0_alloc = rt.getSched().allocator;
    const __bg0_promise = try CheatLib.Promise(void).spawn(__bg0_alloc, rt.getSched());
    const __bg0_ctx = try __bg0_alloc.create(__BgCtx0);
    __bg0_ctx.* = .{ .inner = __bg0_promise.inner, .alloc = __bg0_alloc, .map = &map, .start = start, .chunk = chunk };
    
    try CheatHeader.spawnPinned(
            @intFromPtr(&Runtime.entryWrapper),
            @as(CheatHeader.TaskFn, @ptrCast(&__BgCtx0.run)),
            __bg0_ctx,
            .{ .stack_size = .Standard, .pinned = true },
        );
    break :__bg0 __bg0_promise;
});
wi = (wi + 1);  
rt.checkYield();
}
var si: i64 = 0; 


while ((si < workers)) {
 CheatLib.getAt(set_futures, si).next();
si = (si + 1);  
rt.checkYield();
}
var get_futures = std.ArrayListUnmanaged(CheatLib.Promise(i64)){}; _ = &get_futures;
defer get_futures.deinit(rt.frameAlloc());


wi = 0; 
while ((wi < workers)) {
 const start: i64 = (wi * chunk); 


try get_futures.append(rt.frameAlloc(), __bg1: {
    const __BgCtx1 = struct {
        inner: *CheatLib.Promise(i64).Inner,
        alloc: std.mem.Allocator,
        map: *CheatLib.MutexShardedStringMap([]const u8, 8),
        start: i64,
        chunk: i64,
        fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
            _ = &__rt;
            
            const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
            defer ctx.alloc.destroy(ctx);
            defer ctx.inner.wg.done();
            
            ctx.inner.result = try doGet(__rt, ctx.map, ctx.start, ctx.chunk);
        }
    };
    const __bg1_alloc = rt.getSched().allocator;
    const __bg1_promise = try CheatLib.Promise(i64).spawn(__bg1_alloc, rt.getSched());
    const __bg1_ctx = try __bg1_alloc.create(__BgCtx1);
    __bg1_ctx.* = .{ .inner = __bg1_promise.inner, .alloc = __bg1_alloc, .map = &map, .start = start, .chunk = chunk };
    
    try CheatHeader.spawnPinned(
            @intFromPtr(&Runtime.entryWrapper),
            @as(CheatHeader.TaskFn, @ptrCast(&__BgCtx1.run)),
            __bg1_ctx,
            .{ .stack_size = .Standard, .pinned = true },
        );
    break :__bg1 __bg1_promise;
});
wi = (wi + 1);  
rt.checkYield();
}
var total_hits: i64 = 0; 


var gi: i64 = 0; 


while ((gi < workers)) {
 total_hits = (total_hits + CheatLib.getAt(get_futures, gi).next()); 
gi = (gi + 1);  
rt.checkYield();
}
var zipf_futures = std.ArrayListUnmanaged(CheatLib.Promise(i64)){}; _ = &zipf_futures;
defer zipf_futures.deinit(rt.frameAlloc());


wi = 0; 
while ((wi < workers)) {
 try zipf_futures.append(rt.frameAlloc(), __bg2: {
    const __BgCtx2 = struct {
        inner: *CheatLib.Promise(i64).Inner,
        alloc: std.mem.Allocator,
        map: *CheatLib.MutexShardedStringMap([]const u8, 8),
        wi: i64,
        chunk: i64,
        n: i64,
        zipfSkew: f64,
        fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
            _ = &__rt;
            
            const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
            defer ctx.alloc.destroy(ctx);
            defer ctx.inner.wg.done();
            
            ctx.inner.result = try doZipfGet(__rt, ctx.map, (ctx.wi + 42), ctx.chunk, ctx.n, ctx.zipfSkew);
        }
    };
    const __bg2_alloc = rt.getSched().allocator;
    const __bg2_promise = try CheatLib.Promise(i64).spawn(__bg2_alloc, rt.getSched());
    const __bg2_ctx = try __bg2_alloc.create(__BgCtx2);
    __bg2_ctx.* = .{ .inner = __bg2_promise.inner, .alloc = __bg2_alloc, .map = &map, .wi = wi, .chunk = chunk, .n = n, .zipfSkew = zipfSkew };
    
    try CheatHeader.spawnPinned(
            @intFromPtr(&Runtime.entryWrapper),
            @as(CheatHeader.TaskFn, @ptrCast(&__BgCtx2.run)),
            __bg2_ctx,
            .{ .stack_size = .Standard, .pinned = true },
        );
    break :__bg2 __bg2_promise;
});
wi = (wi + 1);  
rt.checkYield();
}
var zipf_hits: i64 = 0; 


var zi: i64 = 0; 


while ((zi < workers)) {
 zipf_hits = (zipf_hits + CheatLib.getAt(zipf_futures, zi).next()); 
zi = (zi + 1);  
rt.checkYield();
}
var mix_futures = std.ArrayListUnmanaged(CheatLib.Promise(i64)){}; _ = &mix_futures;
defer mix_futures.deinit(rt.frameAlloc());


wi = 0; 
while ((wi < workers)) {
 try mix_futures.append(rt.frameAlloc(), __bg3: {
    const __BgCtx3 = struct {
        inner: *CheatLib.Promise(i64).Inner,
        alloc: std.mem.Allocator,
        map: *CheatLib.MutexShardedStringMap([]const u8, 8),
        wi: i64,
        chunk: i64,
        n: i64,
        zipfSkew: f64,
        fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
            _ = &__rt;
            
            const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
            defer ctx.alloc.destroy(ctx);
            defer ctx.inner.wg.done();
            
            ctx.inner.result = try doZipfMixed(__rt, ctx.map, (ctx.wi + 99), ctx.chunk, ctx.n, ctx.zipfSkew);
        }
    };
    const __bg3_alloc = rt.getSched().allocator;
    const __bg3_promise = try CheatLib.Promise(i64).spawn(__bg3_alloc, rt.getSched());
    const __bg3_ctx = try __bg3_alloc.create(__BgCtx3);
    __bg3_ctx.* = .{ .inner = __bg3_promise.inner, .alloc = __bg3_alloc, .map = &map, .wi = wi, .chunk = chunk, .n = n, .zipfSkew = zipfSkew };
    
    try CheatHeader.spawnPinned(
            @intFromPtr(&Runtime.entryWrapper),
            @as(CheatHeader.TaskFn, @ptrCast(&__BgCtx3.run)),
            __bg3_ctx,
            .{ .stack_size = .Standard, .pinned = true },
        );
    break :__bg3 __bg3_promise;
});
wi = (wi + 1);  
rt.checkYield();
}
var mix_hits: i64 = 0; 


var mi: i64 = 0; 


while ((mi < workers)) {
 mix_hits = (mix_hits + CheatLib.getAt(mix_futures, mi).next()); 
mi = (mi + 1);  
rt.checkYield();
}
CheatLib.assert((total_hits == n), "GET hits must equal key count — data corruption detected");
CheatLib.assert((zipf_hits > 0), "Zipf hits must be > 0 — workload 3 failed");
CheatLib.assert((mix_hits > 0), "Mixed hits must be > 0 — workload 4 failed");
std.debug.print("{s} {d} {s} {d}\n", .{"Keys:", n, "Workers:", workers});
std.debug.print("{s} {d} {s} {d} {s} {d}\n", .{"GET hits:", total_hits, "Zipf hits:", zipf_hits, "Mixed hits:", mix_hits});
std.debug.print("{s}\n", .{"VERIFIED: all workloads completed correctly"});
return ;
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

