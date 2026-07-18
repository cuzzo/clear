// Multi-threaded bootstrapper.
//
// Spawns N schedulers (N = CPU count), each with its own io_uring ring and
// epoll instance.  The main thread runs Scheduler 0 (which owns main);
// N-1 worker threads run idle schedulers that steal work via the existing
// Chase-Lev work-stealing deque in RunQueue.
//
// Shared state (heap-allocated, outlives all threads):
//   - allocator
//   - EbrContext  (thread-safe — has its own registry_lock)
//   - shutdown    (atomic bool — signals workers to exit after main)
//
// Per-thread:
//   - Scheduler   (owns io_uring ring + epoll + ready_queue + inbox)
//   - active_scheduler threadlocal (set before sched.run)

pub fn main() !void {
    // 1. Setup Allocator
    // ReleaseFast defaults to c_allocator (libc malloc — jemalloc compatible,
    // per-thread arenas, zero contention). Debug/ReleaseSafe defaults to
    // smp_allocator for scalable concurrent allocation. Override with
    // USE_C_ALLOCATOR declaration.
    //
    // USE_DEBUG_ALLOCATOR opts into std.heap.DebugAllocator with checks for
    // double-free / use-after-free, so the panic stack trace points at the
    // offending alloc/free site. Used by `clear build --debug-allocator` to
    // localize compiler bugs that emit unsafe Zig.
    const use_debug_alloc = if (@hasDecl(@import("root"), "USE_DEBUG_ALLOCATOR"))
        @import("root").USE_DEBUG_ALLOCATOR
    else
        false;
    const use_c_alloc = if (@hasDecl(@import("root"), "USE_C_ALLOCATOR"))
        @import("root").USE_C_ALLOCATOR
    else
        (@import("builtin").mode == .ReleaseFast or @import("builtin").mode == .ReleaseSmall);

    // The .safety field below catches double-free panics with both the
    // alloc + free stack traces. Setting retain_metadata + never_unmap
    // additionally keeps freed pages mapped so UAF reads return undefined
    // bytes instead of corrupting libc allocator metadata (which gives the
    // cryptic `malloc(): mismatching next->prev_size` diagnostics that
    // don't point at the offending site).
    //
    // stack_trace_frames bumped up so the printed trace climbs past the
    // generic `CheatLib.cleanup` shim into the user-emitted Zig that's the
    // real bug source.
    var dbg_gpa: std.heap.DebugAllocator(.{
        .safety = true,
        // Default DebugAllocator: catches double-free (panics with both
        // alloc + free stack traces) and out-of-bounds writes. DOES NOT
        // catch UAF on its own — for that, set retain_metadata + never_unmap
        // (which trades correctness-coverage for memory growth).
        .retain_metadata = false,
        .never_unmap = false,
        .thread_safe = true,
        .stack_trace_frames = 16,
    }) = .{};
    defer if (use_debug_alloc) {
        // Print leaks/invalid frees to stderr; ignore the leak status code so
        // the program's exit code reflects normal termination.
        _ = dbg_gpa.deinit();
    };

    const allocator = if (use_debug_alloc)
        dbg_gpa.allocator()
    else if (use_c_alloc)
        std.heap.c_allocator
    else
        std.heap.smp_allocator;

    // 2. Setup Contexts
    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);

    // 3. Init Runtime (4 KB frame arena — same as any spawned fiber).
    //    Grows automatically via CheatArena overflow blocks (4KB → 16KB → 64KB → 256KB).
    var rt = try Runtime.init(allocator, 4 * 1024, &global_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    // 4. Shared infrastructure
    const fp = @import("runtime/scheduler.zig");

    // Global shutdown flag — workers check this each loop iteration.
    var shutdown = std.atomic.Value(bool).init(false);

    // 5. Determine thread count.
    //    CLEAR_THREADS=N overrides; default = 1 (single scheduler, zero overhead).
    //    On machines with many cores + large workloads, set CLEAR_THREADS=0 (auto)
    //    or CLEAR_THREADS=N to spawn N-1 worker schedulers.
    const num_workers = blk: {
        if (std.c.getenv("CLEAR_THREADS")) |env_z| {
            const env = std.mem.span(env_z);
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
        shutdown: *std.atomic.Value(bool),
    };
    var worker_ctx = WorkerCtx{
        .allocator = allocator,
        .global_ctx = &global_ctx,
        .shutdown = &shutdown,
    };

    const workerMain = struct {
        fn run(ctx: *WorkerCtx) void {
            var worker_sched = fp.Scheduler.init(ctx.allocator, ctx.global_ctx, null) catch return;
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
            CheatLib.sleep(1);
        }
    }

    // 7. Main scheduler (runs on the main thread).
    var sched = try fp.Scheduler.init(allocator, &global_ctx, null);
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
    // LOOM-EXCLUDE-BEGIN: OS-thread bootstrap shutdown, covered by runtime hammers
    shutdown.store(true, .release);
    // LOOM-EXCLUDE-END
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
        @import("runtime/alloc-profile.zig").dump();
        @import("runtime/channel-profile.zig").dumpToEnvFile();
        @import("runtime/fiber-profile.zig").dumpToEnvFile();
        @import("runtime/lock-profile.zig").dumpToEnvFile();
        @import("runtime/mvcc-profile.zig").dumpToEnvFile();
    }
}
