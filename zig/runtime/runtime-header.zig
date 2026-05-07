const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const compat = @import("../lib/compat.zig");
pub const Runtime = @import("runtime.zig").Runtime;

// ── CLEAR_PROFILE comptime gate ────────────────────────────────────
// `clear profile` prepends `pub const CLEAR_PROFILE = true;` to the
// transpiled entry module. The runtime reads that const from the root
// module at comptime so profile-only telemetry compiles to nothing in
// normal `clear build` / `clear build --optimized` / `--safe` output.
// Default is `false` when the entry doesn't define it.
pub const CLEAR_PROFILE: bool = blk: {
    const root = @import("root");
    break :blk if (@hasDecl(root, "CLEAR_PROFILE")) root.CLEAR_PROFILE else false;
};

// SIMD-accelerated byte search from libc. Not exposed in std.c in Zig 0.16.
extern "c" fn memchr(s: [*]const u8, c: c_int, n: usize) ?[*]const u8;
const fc = @import("fiber-core.zig");
const fp = @import("scheduler.zig");
const streams = @import("../lib/streams.zig");
const freeze_mod = @import("../experimental/freeze.zig");

/// Lock-free observable accumulators (AtomicSum, AtomicCount,
/// Observable<T>, StreamSet, ...). Re-exported so CLEAR programs
/// can reach them via `EXTERN ... FROM "cheat_runtime"`.
pub const obs = @import("../lib/observable.zig");

pub const EbrContext = @import("../lib/ebr.zig").EbrContext;
const Task = @import("queues.zig").Task;
const Fiber = fc.Fiber;

// Concurrency primitives re-exported for DO block fork-join support.
pub const WaitGroup = fp.WaitGroup;
pub const Semaphore = fp.Semaphore;
pub const TaskFn = @import("queues.zig").TaskFn;

// Trampolines that bridge ObservableSum's runtime-agnostic
// completion-callback shape (?*anyopaque + fn ptrs) to the
// scheduler's WaitGroup. The codegen calls
// `obs.ObservableSum(T).setCompletion(wg_ptr, obsWgDone, obsWgWait,
// obsWgDestroy)` so the producer fiber's `acc.finish()` issues
// `wg.done()` and the joiner's `acc.next()` parks on `wg.wait()`.
// observable.zig stays runtime-free; the runtime knowledge lives
// here.
pub fn obsWgDone(handle: ?*anyopaque) void {
    const wg: *fp.WaitGroup = @ptrCast(@alignCast(handle.?));
    wg.done();
}
pub fn obsWgWait(handle: ?*anyopaque) void {
    const wg: *fp.WaitGroup = @ptrCast(@alignCast(handle.?));
    wg.wait();
}
pub fn obsWgDestroy(handle: ?*anyopaque, alloc: std.mem.Allocator) void {
    const wg: *fp.WaitGroup = @ptrCast(@alignCast(handle.?));
    alloc.destroy(wg);
}

// FSM types re-exported for Phase B1 pure-compute BG lowering.
pub const FsmTask = fp.FsmTask;
pub const YieldReason = fp.YieldReason;
pub const FsmIoWaiter = @import("fsm.zig").FsmIoWaiter;

// WaiterNode re-exported for FSM-WITH (Phase B2-WITH): the state
// struct embeds one to register on a parking-lot queue when an FSM
// suspends on a contended lock.
pub const WaiterNode = @import("queues.zig").WaiterNode;

// Monotonic millisecond timestamp re-exported for FSM-IO templates
// (Phase B2-IO). Wraps the same `compat.milliTimestamp()` the
// scheduler uses for sleep wake-time bookkeeping.
pub fn milliTimestamp() i64 {
    return compat.milliTimestamp();
}

// File-IO helpers re-exported for FSM-mode `readFile` / `writeFile`
// templates. These are the same syscalls the stackful versions use,
// just publicly callable via `CheatHeader.X` from emitted templates.
pub fn fsmOpenForRead(path: []const u8) !std.posix.fd_t {
    return openPathFd(path, .{ .ACCMODE = .RDONLY }, 0);
}
pub fn fsmOpenForWrite(path: []const u8) !std.posix.fd_t {
    return openPathFd(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
}
pub fn fsmFileSize(fd: std.posix.fd_t) !u64 {
    return compat.fileSizeFd(fd);
}
pub fn fsmCloseFd(fd: std.posix.fd_t) void {
    compat.closeFd(fd);
}
// Translate a negative io_uring CQE result into an error. Public
// shim around scheduler.Scheduler.ioError so templates can use a
// short-named call.
pub fn fsmIoError(result: i32) std.posix.UnexpectedError {
    return fp.Scheduler.ioError(result);
}

// Scheduler + fiber-memory re-exported for test harness scheduler setup.
pub const scheduler = fp;
pub const fiber_memory = @import("fiber-memory.zig");
pub var partitioned_map_delay_ctx_destroy = false;


// Helper Functions
fn getCwdFd() std.posix.fd_t {
    return std.posix.AT.FDCWD;
}

// Open a file relative to cwd using direct openat syscall.
// Null-terminates the path inline — zero heap alloc, minimal stack.
noinline fn openPathFd(path: []const u8, flags: std.posix.O, mode: std.posix.mode_t) !std.posix.fd_t {
    if (path.len > 255) return error.NameTooLong;
    var buf: [256]u8 = undefined;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return std.posix.openatZ(getCwdFd(), buf[0..path.len :0], flags, mode);
}

pub const CheatLib = struct {
    pub const Range = streams.Range;
    pub const IntRange = streams.IntRange;
    /// Lock-free observable accumulators (pipeline-terminal backings
    /// for ~T@observable). Re-exported from the top-level `obs` so
    /// emitted Zig can reach them via `CheatLib.obs.ObservableSum(T)`.
    pub const obs = @import("../lib/observable.zig");
    pub fn SplitStream(comptime T: type) type {
        return streams.SplitStream(T, WaitGroup, struct {
            fn cloneValue(alloc: std.mem.Allocator, value: T) !T {
                return dupeValue(T, value, alloc);
            }
        }.cloneValue, struct {
            fn cleanupValue(alloc: std.mem.Allocator, ptr: *T) void {
                cleanup(T, alloc, ptr);
            }
        }.cleanupValue);
    }

    pub fn concurrentBoundedSelect(
        comptime T: type,
        comptime R: type,
        comptime N: usize,
        comptime mapFn: fn (*Runtime, ?*anyopaque, T) anyerror!R,
        alloc: std.mem.Allocator,
        rt: *Runtime,
        items: *[N]Promise(T),
        workers: usize,
        batch: usize,
        parallel: bool,
        task_cfg: fp.TaskConfig,
        user_ctx: ?*anyopaque,
    ) !std.ArrayListUnmanaged(R) {
        return streams.concurrentBoundedSelect(
            fp.WaitGroup, T, R, N, mapFn,
            struct {
                fn localSpawn(sched: *fp.Scheduler, user_fn: TaskFn, args: ?*anyopaque, config: fp.TaskConfig) !void {
                    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper), user_fn, args, config);
                }
            }.localSpawn,
            struct {
                fn parallelSpawn(user_fn: TaskFn, args: ?*anyopaque, config: fp.TaskConfig) !void {
                    try CheatLib.spawnBest(@intFromPtr(&Runtime.entryWrapper), user_fn, args, config);
                }
            }.parallelSpawn,
            struct {
                fn cleanupResult(alloc_: std.mem.Allocator, ptr: *R) void {
                    cleanup(R, alloc_, ptr);
                }
            }.cleanupResult,
            alloc, rt, items, workers, batch, parallel, task_cfg, user_ctx
        );
    }

    pub fn concurrentBoundedWhere(
        comptime T: type,
        comptime N: usize,
        comptime predFn: fn (*Runtime, ?*anyopaque, T) anyerror!bool,
        alloc: std.mem.Allocator,
        rt: *Runtime,
        items: *[N]Promise(T),
        workers: usize,
        batch: usize,
        parallel: bool,
        task_cfg: fp.TaskConfig,
        user_ctx: ?*anyopaque,
    ) !std.ArrayListUnmanaged(T) {
        return streams.concurrentBoundedWhere(
            fp.WaitGroup, T, N, predFn,
            struct {
                fn localSpawn(sched: *fp.Scheduler, user_fn: TaskFn, args: ?*anyopaque, config: fp.TaskConfig) !void {
                    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper), user_fn, args, config);
                }
            }.localSpawn,
            struct {
                fn parallelSpawn(user_fn: TaskFn, args: ?*anyopaque, config: fp.TaskConfig) !void {
                    try CheatLib.spawnBest(@intFromPtr(&Runtime.entryWrapper), user_fn, args, config);
                }
            }.parallelSpawn,
            struct {
                fn cleanupItem(alloc_: std.mem.Allocator, ptr: *T) void {
                    cleanup(T, alloc_, ptr);
                }
            }.cleanupItem,
            alloc, rt, items, workers, batch, parallel, task_cfg, user_ctx
        );
    }

    pub fn concurrentBoundedEach(
        comptime T: type,
        comptime N: usize,
        comptime eachFn: fn (*Runtime, ?*anyopaque, T) anyerror!void,
        rt: *Runtime,
        items: *[N]Promise(T),
        workers: usize,
        batch: usize,
        parallel: bool,
        task_cfg: fp.TaskConfig,
        user_ctx: ?*anyopaque,
    ) !void {
        return streams.concurrentBoundedEach(
            fp.WaitGroup, T, N, eachFn,
            struct {
                fn localSpawn(sched: *fp.Scheduler, user_fn: TaskFn, args: ?*anyopaque, config: fp.TaskConfig) !void {
                    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper), user_fn, args, config);
                }
            }.localSpawn,
            struct {
                fn parallelSpawn(user_fn: TaskFn, args: ?*anyopaque, config: fp.TaskConfig) !void {
                    try CheatLib.spawnBest(@intFromPtr(&Runtime.entryWrapper), user_fn, args, config);
                }
            }.parallelSpawn,
            rt, items, workers, batch, parallel, task_cfg, user_ctx
        );
    }

    // Dynamic-stream concurrent helpers: feeder fiber + N worker fibers
    // wired through a BoundedChannel(T). Mirror the bounded variants but
    // pull items via .next() / .nextOrNull() over an unsized source.
    pub fn concurrentStreamSelect(
        comptime T: type,
        comptime R: type,
        comptime mapFn: fn (*Runtime, ?*anyopaque, T) anyerror!R,
        comptime is_inf: bool,
        alloc: std.mem.Allocator,
        rt: *Runtime,
        src: anytype,
        workers: usize,
        capacity: usize,
        batch: usize,
        parallel: bool,
        task_cfg: fp.TaskConfig,
        user_ctx: ?*anyopaque,
    ) !std.ArrayListUnmanaged(R) {
        return streams.concurrentStreamSelect(
            fp.WaitGroup, BoundedChannel(T), T, R, mapFn,
            struct {
                fn localSpawn(sched: *fp.Scheduler, user_fn: TaskFn, args: ?*anyopaque, config: fp.TaskConfig) !void {
                    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper), user_fn, args, config);
                }
            }.localSpawn,
            struct {
                fn parallelSpawn(user_fn: TaskFn, args: ?*anyopaque, config: fp.TaskConfig) !void {
                    try CheatLib.spawnBest(@intFromPtr(&Runtime.entryWrapper), user_fn, args, config);
                }
            }.parallelSpawn,
            struct {
                fn cleanupResult(alloc_: std.mem.Allocator, ptr: *R) void {
                    cleanup(R, alloc_, ptr);
                }
            }.cleanupResult,
            is_inf, alloc, rt, src, workers, capacity, batch, parallel, task_cfg, user_ctx
        );
    }

    pub fn concurrentStreamWhere(
        comptime T: type,
        comptime predFn: fn (*Runtime, ?*anyopaque, T) anyerror!bool,
        comptime is_inf: bool,
        alloc: std.mem.Allocator,
        rt: *Runtime,
        src: anytype,
        workers: usize,
        capacity: usize,
        batch: usize,
        parallel: bool,
        task_cfg: fp.TaskConfig,
        user_ctx: ?*anyopaque,
    ) !std.ArrayListUnmanaged(T) {
        return streams.concurrentStreamWhere(
            fp.WaitGroup, BoundedChannel(T), T, predFn,
            struct {
                fn localSpawn(sched: *fp.Scheduler, user_fn: TaskFn, args: ?*anyopaque, config: fp.TaskConfig) !void {
                    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper), user_fn, args, config);
                }
            }.localSpawn,
            struct {
                fn parallelSpawn(user_fn: TaskFn, args: ?*anyopaque, config: fp.TaskConfig) !void {
                    try CheatLib.spawnBest(@intFromPtr(&Runtime.entryWrapper), user_fn, args, config);
                }
            }.parallelSpawn,
            struct {
                fn cleanupItem(alloc_: std.mem.Allocator, ptr: *T) void {
                    cleanup(T, alloc_, ptr);
                }
            }.cleanupItem,
            is_inf, alloc, rt, src, workers, capacity, batch, parallel, task_cfg, user_ctx
        );
    }

    pub fn concurrentStreamEach(
        comptime T: type,
        comptime eachFn: fn (*Runtime, ?*anyopaque, T) anyerror!void,
        comptime is_inf: bool,
        alloc: std.mem.Allocator,
        rt: *Runtime,
        src: anytype,
        workers: usize,
        capacity: usize,
        batch: usize,
        parallel: bool,
        task_cfg: fp.TaskConfig,
        user_ctx: ?*anyopaque,
    ) !void {
        return streams.concurrentStreamEach(
            fp.WaitGroup, BoundedChannel(T), T, eachFn,
            struct {
                fn localSpawn(sched: *fp.Scheduler, user_fn: TaskFn, args: ?*anyopaque, config: fp.TaskConfig) !void {
                    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper), user_fn, args, config);
                }
            }.localSpawn,
            struct {
                fn parallelSpawn(user_fn: TaskFn, args: ?*anyopaque, config: fp.TaskConfig) !void {
                    try CheatLib.spawnBest(@intFromPtr(&Runtime.entryWrapper), user_fn, args, config);
                }
            }.parallelSpawn,
            is_inf, alloc, rt, src, workers, capacity, batch, parallel, task_cfg, user_ctx
        );
    }

    // List-source concurrent helpers: persistent worker pool over a
    // materialized slice. Workers race on an atomic index against the
    // slice length; no feeder, no channel.
    pub fn concurrentListSelect(
        comptime T: type,
        comptime R: type,
        comptime mapFn: fn (*Runtime, ?*anyopaque, T) anyerror!R,
        alloc: std.mem.Allocator,
        rt: *Runtime,
        items: []const T,
        workers: usize,
        batch: usize,
        parallel: bool,
        task_cfg: fp.TaskConfig,
        user_ctx: ?*anyopaque,
    ) !std.ArrayListUnmanaged(R) {
        return streams.concurrentListSelect(
            fp.WaitGroup, T, R, mapFn,
            struct {
                fn localSpawn(sched: *fp.Scheduler, user_fn: TaskFn, args: ?*anyopaque, config: fp.TaskConfig) !void {
                    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper), user_fn, args, config);
                }
            }.localSpawn,
            struct {
                fn parallelSpawn(user_fn: TaskFn, args: ?*anyopaque, config: fp.TaskConfig) !void {
                    try CheatLib.spawnBest(@intFromPtr(&Runtime.entryWrapper), user_fn, args, config);
                }
            }.parallelSpawn,
            struct {
                fn cleanupResult(alloc_: std.mem.Allocator, ptr: *R) void {
                    cleanup(R, alloc_, ptr);
                }
            }.cleanupResult,
            alloc, rt, items, workers, batch, parallel, task_cfg, user_ctx
        );
    }

    pub fn concurrentListWhere(
        comptime T: type,
        comptime predFn: fn (*Runtime, ?*anyopaque, T) anyerror!bool,
        alloc: std.mem.Allocator,
        rt: *Runtime,
        items: []const T,
        workers: usize,
        batch: usize,
        parallel: bool,
        task_cfg: fp.TaskConfig,
        user_ctx: ?*anyopaque,
    ) !std.ArrayListUnmanaged(T) {
        return streams.concurrentListWhere(
            fp.WaitGroup, T, predFn,
            struct {
                fn localSpawn(sched: *fp.Scheduler, user_fn: TaskFn, args: ?*anyopaque, config: fp.TaskConfig) !void {
                    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper), user_fn, args, config);
                }
            }.localSpawn,
            struct {
                fn parallelSpawn(user_fn: TaskFn, args: ?*anyopaque, config: fp.TaskConfig) !void {
                    try CheatLib.spawnBest(@intFromPtr(&Runtime.entryWrapper), user_fn, args, config);
                }
            }.parallelSpawn,
            struct {
                fn cleanupItem(alloc_: std.mem.Allocator, ptr: *T) void {
                    cleanup(T, alloc_, ptr);
                }
            }.cleanupItem,
            alloc, rt, items, workers, batch, parallel, task_cfg, user_ctx
        );
    }

    pub fn concurrentListEach(
        comptime T: type,
        comptime eachFn: fn (*Runtime, ?*anyopaque, T) anyerror!void,
        rt: *Runtime,
        items: []const T,
        workers: usize,
        batch: usize,
        parallel: bool,
        task_cfg: fp.TaskConfig,
        user_ctx: ?*anyopaque,
    ) !void {
        return streams.concurrentListEach(
            fp.WaitGroup, T, eachFn,
            struct {
                fn localSpawn(sched: *fp.Scheduler, user_fn: TaskFn, args: ?*anyopaque, config: fp.TaskConfig) !void {
                    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper), user_fn, args, config);
                }
            }.localSpawn,
            struct {
                fn parallelSpawn(user_fn: TaskFn, args: ?*anyopaque, config: fp.TaskConfig) !void {
                    try CheatLib.spawnBest(@intFromPtr(&Runtime.entryWrapper), user_fn, args, config);
                }
            }.parallelSpawn,
            rt, items, workers, batch, parallel, task_cfg, user_ctx
        );
    }

    pub fn concurrentListEachInPlace(
        comptime T: type,
        comptime eachFn: fn (*Runtime, ?*anyopaque, *T) anyerror!void,
        rt: *Runtime,
        items: []T,
        workers: usize,
        batch: usize,
        parallel: bool,
        task_cfg: fp.TaskConfig,
        user_ctx: ?*anyopaque,
    ) !void {
        return streams.concurrentListEachInPlace(
            fp.WaitGroup, T, eachFn,
            struct {
                fn localSpawn(sched: *fp.Scheduler, user_fn: TaskFn, args: ?*anyopaque, config: fp.TaskConfig) !void {
                    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper), user_fn, args, config);
                }
            }.localSpawn,
            struct {
                fn parallelSpawn(user_fn: TaskFn, args: ?*anyopaque, config: fp.TaskConfig) !void {
                    try CheatLib.spawnBest(@intFromPtr(&Runtime.entryWrapper), user_fn, args, config);
                }
            }.parallelSpawn,
            rt, items, workers, batch, parallel, task_cfg, user_ctx
        );
    }

    pub const File = struct {
        fd: std.posix.fd_t,

        pub fn close(self: File) void {
            compat.closeFd(self.fd);
        }

        pub fn read(self: File, buffer: []u8) !usize {
            return try std.posix.read(self.fd, buffer);
        }

        pub fn writeAll(self: File, data: []const u8) !void {
            var written: usize = 0;
            while (written < data.len) {
                const n = std.c.write(self.fd, data.ptr + written, data.len - written);
                if (n < 0) return error.Unexpected;
                if (n == 0) return error.WriteFailed;
                written += @intCast(n);
            }
        }
    };

    // -----------------------------------------------------------------------
    // LazyRange(T): zero-allocation lazy iterator over a half-open range [start, end).
    // Used by the pipeline system for `(start..<end) s> EACH { ... }`.
    // Protocol: var src = LazyRange(T).init(s, e); while (try src.next(rt)) |item| { ... }
    pub fn LazyRange(comptime T: type) type {
        return struct {
            current: T,
            end: T,
            pub fn init(start: T, end: T) @This() {
                return .{ .current = start, .end = end };
            }
            pub fn next(self: *@This()) !?T {
                if (self.current >= self.end) return null;
                defer self.current += 1;
                return self.current;
            }
            pub fn deinit(_: *@This(), _: std.mem.Allocator) void {}
        };
    }

    // Read from a non-blocking socket.
    //
    // Fast path: try a direct read first. Hot loopback/socket workloads often
    // have bytes ready already, and paying an io_uring submission + yield for
    // every ready read is far more expensive than the syscall itself.
    //
    // Slow path: if the fd would block, submit IORING_OP_RECV and yield. This
    // preserves the completion-based path needed for streaming/parked fibers.
    pub noinline fn read(fd: i32, buffer: []u8) !usize {
        const n = std.posix.read(fd, buffer) catch |err| {
            if (err != error.WouldBlock) return err;
            if (!fp.scheduler_running) return err;

            const sched = fp.active_scheduler;
            const task = sched.getCurrent();
            var waiter = fp.Scheduler.IoWaiter{ .task = task };
            try sched.submitRecv(&waiter, fd, buffer);
            task.base.yield();
            if (waiter.result < 0) return fp.Scheduler.ioError(waiter.result);
            return @intCast(waiter.result);
        };
        return n;
    }

    // Force completion-based socket read. Kept separate so streaming code can
    // opt into the one-SQE/one-yield path explicitly instead of penalizing
    // ready-socket hot paths.
    pub noinline fn readAsync(fd: i32, buffer: []u8) !usize {
        const sched = fp.active_scheduler;
        const task = sched.getCurrent();
        var waiter = fp.Scheduler.IoWaiter{ .task = task };
        try sched.submitRecv(&waiter, fd, buffer);
        task.base.yield();
        if (waiter.result < 0) return fp.Scheduler.ioError(waiter.result);
        return @intCast(waiter.result);
    }

    // List / Dynamic Array

    pub fn makeList(comptime T: type, allocator: std.mem.Allocator, items: []const T) !std.ArrayListUnmanaged(T) {
        var list = try std.ArrayListUnmanaged(T).initCapacity(allocator, items.len);
        list.appendSliceAssumeCapacity(items);
        return list;
    }

    // Promote a @list's arena-backed buffer to heap before returning from a frame-using
    // function.  The frame arena rewinds on function exit; without promotion the caller
    // would hold a dangling pointer.  After promotion the caller must deinit with
    // rt.heapAlloc() — the annotator sets heap_list=true on the receiving variable so
    // emit_cleanup emits the correct allocator.
    //
    // Empty lists are a no-op (items.len == 0 means no backing allocation).
    pub fn promoteList(comptime T: type, rt: *Runtime, list: *std.ArrayListUnmanaged(T)) !void {
        if (list.items.len == 0) return;
        const heap_buf = try rt.heapAlloc().alloc(T, list.items.len);
        @memcpy(heap_buf, list.items);
        list.items = heap_buf;
        list.capacity = heap_buf.len;
    }

    // Works for ArrayListUnmanaged (has .items) AND Standard Slices (direct access)
    // Also handles casting the index to usize automatically.
    // Unwraps optional containers (e.g. from hashmap.get()) before indexing.
    pub fn getAt(container: anytype, index: anytype) ElementType(@TypeOf(container)) {
        const i: usize = @intCast(index);
        const c = if (@typeInfo(@TypeOf(container)) == .optional) container.? else container;

        if (@hasField(@TypeOf(c), "items")) {
            return c.items[i];
        } else {
            return c[i];
        }
    }

    fn ElementType(comptime C: type) type {
        const Inner = if (@typeInfo(C) == .optional) @typeInfo(C).optional.child else C;
        if (@hasField(Inner, "items")) {
            // ArrayList: .items is []T, element type is T
            for (@typeInfo(Inner).@"struct".fields) |f| {
                if (std.mem.eql(u8, f.name, "items"))
                    return std.meta.Elem(f.type);
            }
            unreachable;
        } else {
            return std.meta.Elem(Inner);
        }
    }

    // Bounds-safe index: returns null on out-of-bounds instead of panicking.
    pub fn getAtOpt(container: anytype, index: anytype) ?ElementType(@TypeOf(container)) {
        const i: usize = @intCast(index);
        const c = if (@typeInfo(@TypeOf(container)) == .optional) container.? else container;
        if (@hasField(@TypeOf(c), "items")) {
            if (i >= c.items.len) return null;
            return c.items[i];
        } else {
            if (i >= c.len) return null;
            return c[i];
        }
    }

    // First element, or null if empty. Backs CLEAR's `.first()` predicate.
    pub fn firstOpt(container: anytype) ?ElementType(@TypeOf(container)) {
        const c = if (@typeInfo(@TypeOf(container)) == .optional) container.? else container;
        if (@hasField(@TypeOf(c), "items")) {
            if (c.items.len == 0) return null;
            return c.items[0];
        } else {
            if (c.len == 0) return null;
            return c[0];
        }
    }

    // Last element, or null if empty. Backs CLEAR's `.last()` predicate.
    // Computed via the same shape-dispatch as firstOpt — works for both
    // ArrayList (`.items`) and bare slices.
    pub fn lastOpt(container: anytype) ?ElementType(@TypeOf(container)) {
        const c = if (@typeInfo(@TypeOf(container)) == .optional) container.? else container;
        if (@hasField(@TypeOf(c), "items")) {
            if (c.items.len == 0) return null;
            return c.items[c.items.len - 1];
        } else {
            if (c.len == 0) return null;
            return c[c.len - 1];
        }
    }

    // Linear search over a slice or ArrayList for item equality.
    pub fn sliceContains(container: anytype, item: anytype) bool {
        const c = if (@typeInfo(@TypeOf(container)) == .optional) container.? else container;
        const slice = if (@hasField(@TypeOf(c), "items")) c.items else c;
        for (slice) |elem| {
            if (eql(elem, item)) return true;
        }
        return false;
    }

    // Byte-level character access: returns a single-byte slice ([]const u8).
    // Used by CLEAR's String@raw buf[i] indexing.
    pub noinline fn charAt(str: []const u8, index: anytype) []const u8 {
        const idx = @as(i64, @intCast(index));
        if (idx < 0) return "";
        const i: usize = @intCast(idx);
        if (i >= str.len) return "";
        return str[i .. i + 1];
    }

    // UTF-8 codepoint count. Returns the number of Unicode codepoints in the string.
    // Falls back to byte count on invalid UTF-8.
    pub fn codepointCount(str: []const u8) i64 {
        return @intCast(std.unicode.utf8CountCodepoints(str) catch str.len);
    }

    // UTF-8 codepoint access: returns the i-th codepoint as a multi-byte slice.
    // O(n) per call — iterates from the start. Returns "" on out-of-bounds or invalid UTF-8.
    pub fn charAtCodepoint(alloc: std.mem.Allocator, str: []const u8, index: anytype) ![]const u8 {
        Runtime.profileAlloc(1);
        const target: usize = @intCast(index);
        const view = std.unicode.Utf8View.initUnchecked(str);
        var it = view.iterator();
        var i: usize = 0;
        while (it.nextCodepointSlice()) |cp_slice| {
            if (i == target) {
                const result = try alloc.dupe(u8, cp_slice);
                return result;
            }
            i += 1;
        }
        return "";
    }

    // Works for Lists and Slices because it modifies the memory the slice points to.
    pub fn setAt(container: anytype, index: anytype, value: anytype) void {
        const i: usize = @intCast(index);

        if (@hasField(@TypeOf(container), "items")) {
            // ArrayListUnmanaged
            container.items[i] = value;
        } else {
            // Standard Slice
            container[i] = value;
        }
    }

    pub fn cleanupAt(comptime T: type, container: anytype, alloc: std.mem.Allocator, index: anytype) void {
        const i: usize = @intCast(index);
        if (@hasField(@TypeOf(container), "items")) {
            cleanup(T, alloc, &container.items[i]);
        } else {
            cleanup(T, alloc, &container[i]);
        }
    }

    pub fn concat(allocator: std.mem.Allocator, s1: []const u8, s2: []const u8) ![]const u8 {
        Runtime.profileAlloc(s1.len + s2.len);
        return try std.mem.concat(allocator, u8, &.{ s1, s2 });
    }

    // Polymorphic Length (Strings or Lists)
    // Unwraps optional containers (e.g. from hashmap.get()) before measuring.
    pub fn len(container: anytype) i64 {
        const c = if (@typeInfo(@TypeOf(container)) == .optional) container.? else container;
        // If it has .items (ArrayList), use that. Otherwise assume it's a Slice.
        if (@hasField(@TypeOf(c), "items")) {
            return @intCast(c.items.len);
        } else {
            return @intCast(c.len);
        }
    }

    // =========================================================================
    // String-keyed HashMap (StringHashMapUnmanaged)
    //
    // Option 1 — Arena bucket array:
    //   mapPut takes two allocators:
    //     key_alloc    — heap allocator for key string copies (keys must
    //                    outlive the frame; GPA ensures this).
    //   Both key copies and bucket array use frameAlloc (bump, ~2 ns/alloc).
    //   mapPromote() is called before RETURN to clone both to heapAlloc for
    //   maps that escape their function.  Non-escaping maps pay zero GPA cost.
    //   mapDeinit() is only called for promoted (heap-backed) maps.
    // =========================================================================

    const DataStructures = @import("../lib/data-structures.zig").bind(struct {
        pub fn cleanup(comptime T: type, alloc: std.mem.Allocator, cptr: *const T) void {
            CheatLib.cleanup(T, alloc, cptr);
        }

        pub fn needsCleanup(comptime T: type) bool {
            return CheatLib.needsCleanup(T);
        }

        pub fn refInnerType(comptime T: type) ?type {
            return CheatLib.refInnerType(T);
        }

        pub fn releaseOne(comptime T: type, alloc: std.mem.Allocator, value: T) void {
            CheatLib.releaseOne(T, alloc, value);
        }

        pub fn partitionedMapDelayCtxDestroy() bool {
            return partitioned_map_delay_ctx_destroy;
        }
    });

    pub const makeHashMap = DataStructures.makeHashMap;
    pub const mapPut = DataStructures.mapPut;
    pub const StringMap = DataStructures.StringMap;
    pub const mapPromote = DataStructures.mapPromote;
    pub const mapDeinit = DataStructures.mapDeinit;
    pub const mapGet = DataStructures.mapGet;
    pub const mapDelete = DataStructures.mapDelete;
    pub const mapContains = DataStructures.mapContains;
    pub const mapCount = DataStructures.mapCount;
    pub const mapKeys = DataStructures.mapKeys;
    pub const mapValues = DataStructures.mapValues;
    pub const NumericMapType = DataStructures.NumericMapType;
    pub const numericMapPut = DataStructures.numericMapPut;
    pub const numericMapGet = DataStructures.numericMapGet;
    pub const numericMapDelete = DataStructures.numericMapDelete;
    pub const numericMapContains = DataStructures.numericMapContains;
    pub const numericMapCount = DataStructures.numericMapCount;
    pub const numericMapDeinit = DataStructures.numericMapDeinit;
    pub const numericMapKeys = DataStructures.numericMapKeys;
    pub const numericMapValues = DataStructures.numericMapValues;
    pub const deinitList = DataStructures.deinitList;
    pub const deinitSet = DataStructures.deinitSet;
    pub const Locked = DataStructures.Locked;
    /// Multi-Version Concurrency Control (MVCC) cell: atomic-pointer
    /// COW + EBR reclamation. Backs `T@versioned` (and
    /// `T@shared:versioned` -> `Arc(Versioned(T))`). Readers acquire a
    /// Guard via `read()`; writers swap a new version via `update()`
    /// with a bounded CAS retry loop that surfaces
    /// `error.UpdateRetriesExhausted` (mapped to CLEAR's `MvccConflict`
    /// at the runtime bridge). Named `Versioned` (not `Shared`) to
    /// disambiguate from CLEAR's `@shared` capability (Arc-based
    /// ownership wrapper).
    pub const Versioned = @import("versioned.zig").Versioned;
    /// `T@shared:atomic` lowers to `CheatLib.Atomic(T)` (= AtomicInt(T)
    /// / AtomicFloat(T) / AtomicBool from lib/atomic.zig). Single-cell
    /// lock-free primitive; load/store/exchange/cmpxchg/fetch_*. The
    /// composed `@shared:atomic` form additionally Arc-wraps it for M1.
    /// M2 drops the Arc and ties the cell's lifetime to its declaring
    /// scope (bare Atomic(T)). See docs/agents/atomics.md.
    pub const Atomic = @import("../lib/atomic.zig").Atomic;
    /// Allocate `*Atomic(T)` on the heap, init it with `data`, return
    /// the heap pointer. Mirrors `versionedCreate` for `T@shared:atomic`.
    /// The generated CLEAR codegen calls this for `c = ... @shared:atomic`.
    pub fn atomicCreate(comptime T: type, alloc: std.mem.Allocator, data: T) !*@import("../lib/atomic.zig").Atomic(T) {
        const AT = @import("../lib/atomic.zig").Atomic(T);
        const ptr = try alloc.create(AT);
        ptr.* = AT.init(data);
        return ptr;
    }

    /// AtomicPtr M3.5 -- allocate `*AtomicPtr(T)` on the heap, init
    /// it by publishing an initial heap-allocated `T` snapshot,
    /// return the cell pointer. Mirrors `atomicCreate` for the
    /// struct case (`T@indirect:atomic`). The cell publishes whole-T
    /// snapshots via atomic pointer swap (lock-free Rust arc-swap
    /// rcu semantics). The CLEAR codegen calls this for
    /// `c = ... @indirect:atomic`.
    pub const AtomicPtr = @import("../lib/atomic_ptr.zig").AtomicPtr;
    pub fn atomicPtrCreate(comptime T: type, alloc: std.mem.Allocator, data: T) !*@import("../lib/atomic_ptr.zig").AtomicPtr(T) {
        const APT = @import("../lib/atomic_ptr.zig").AtomicPtr(T);
        const cell = try alloc.create(APT);
        cell.* = try APT.init(alloc, data);
        return cell;
    }
    /// AtomicPtr M3.5 -- tear down a `*AtomicPtr(T)` cell. Retires
    /// the currently-published `*T` via EBR (deferred-free until
    /// every active epoch drains -- safe even if a reader is in the
    /// middle of `read()`) and destroys the cell struct.
    pub fn atomicPtrDestroy(comptime T: type, rt: *Runtime, alloc: std.mem.Allocator, cell: *@import("../lib/atomic_ptr.zig").AtomicPtr(T)) void {
        cell.deinit(rt, alloc) catch {};
        alloc.destroy(cell);
    }
    /// Allocate `*Versioned(T)` on the heap, init it with `data`,
    /// return the heap pointer. Mirrors `lockedCreate` for
    /// `T@versioned`. The generated CLEAR codegen calls this for
    /// `c = ... @versioned;`.
    pub fn versionedCreate(comptime T: type, alloc: std.mem.Allocator, data: T) !*@import("versioned.zig").Versioned(T) {
        const VersionedT = @import("versioned.zig").Versioned(T);
        const ptr = try alloc.create(VersionedT);
        ptr.* = try VersionedT.init(alloc, data);
        return ptr;
    }
    /// Tear down a `*Versioned(T)` cell created by `versionedCreate`.
    /// Retires the live inner pointer via EBR (deferred-free until
    /// every active epoch drains -- safe even if a reader still holds
    /// a Guard) and destroys the outer Versioned struct. Best-effort:
    /// an OOM in `retire` would leak, which is acceptable on a
    /// teardown path.
    pub fn versionedDestroy(comptime T: type, rt: *Runtime, alloc: std.mem.Allocator, cell: *@import("versioned.zig").Versioned(T)) void {
        cell.deinit(rt, alloc) catch {};
        alloc.destroy(cell);
    }
    /// Atomic multi-cell transaction over a tuple of `*Versioned(T_i)`
    /// (cells may have heterogeneous T). Sorts cells by address,
    /// installs tagged-pointer "soft locks" in order, runs the user
    /// transaction body against mutable views, then publishes all
    /// new pointers atomically. Used to lower CLEAR's
    /// `WITH SNAPSHOT a AS MUTABLE va, SNAPSHOT b AS MUTABLE vb`.
    pub const versionedUpdateMulti = @import("versioned.zig").updateMulti;
    pub const RefCell = DataStructures.RefCell;
    pub const refCellCreate = DataStructures.refCellCreate;
    pub const refCellDestroy = DataStructures.refCellDestroy;
    pub const localCreate = DataStructures.localCreate;
    pub const lockedCreate = DataStructures.lockedCreate;
    pub const lockedDestroy = DataStructures.lockedDestroy;
    pub const RwLocked = DataStructures.RwLocked;
    pub const rwLockedCreate = DataStructures.rwLockedCreate;
    pub const rwLockedDestroy = DataStructures.rwLockedDestroy;
    pub const Promise = DataStructures.Promise;
    pub const SharedPromise = DataStructures.SharedPromise;
    pub const BoundedStream = DataStructures.BoundedStream;
    pub const Stream = DataStructures.Stream;
    pub const InfStream = DataStructures.InfStream;
    pub const BoundedChannel = DataStructures.BoundedChannel;
    pub const BatchWindow = DataStructures.BatchWindow;
    pub const Pool = DataStructures.Pool;
    pub const SoaList = DataStructures.SoaList;
    pub const SoaPool = DataStructures.SoaPool;
    pub const ShardedPool = DataStructures.ShardedPool;
    pub const ShardedList = DataStructures.ShardedList;
    pub const Set = DataStructures.Set;
    pub const PartitionedStringMap = DataStructures.PartitionedStringMap;
    pub const PartitionedNumericMap = DataStructures.PartitionedNumericMap;
    pub const ShardedStringMap = DataStructures.ShardedStringMap;
    pub const MutexShardedStringMap = DataStructures.MutexShardedStringMap;
    pub const StripedStringMap = DataStructures.StripedStringMap;
    pub const ShardedNumericMap = DataStructures.ShardedNumericMap;
    pub const StripedNumericMap = DataStructures.StripedNumericMap;

    // FILE

    // Open a file as a linear resource. Caller is responsible for calling .close().
    // Designed for use with CLEAR's resource system: `f = File::open("path")`.
    // The compiler auto-injects `defer f.close()` at the declaration site.
    pub fn fileOpen(path: []const u8) !File {
        return .{
            .fd = try openPathFd(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0),
        };
    }

    // Read all bytes from an open file resource into a heap-allocated buffer.
    // Intended for use as `f.readAll()` on a File resource.
    pub fn fileReadAll(allocator: std.mem.Allocator, file: File) ![]const u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = try file.read(&buf);
            if (n == 0) break;
            try out.appendSlice(allocator, buf[0..n]);
        }
        return try out.toOwnedSlice(allocator);
    }

    // Create (or truncate) a file for writing. Caller owns the returned File resource.
    // The compiler auto-injects `defer f.close()` at the declaration site.
    pub fn fileCreate(path: []const u8) !File {
        return .{
            .fd = try openPathFd(path, .{
                .ACCMODE = .WRONLY,
                .CREAT = true,
                .TRUNC = true,
                .CLOEXEC = true,
            }, 0o644),
        };
    }

    // Write `data` to an open writable File resource.
    // Usage: fileWrite(f, "hello world")
    pub fn fileWrite(file: File, data: []const u8) !void {
        return file.writeAll(data);
    }

    // Read File (Allocates on HEAP)
    //
    // When a scheduler is active (BG fibers), the bulk read is submitted
    // via io_uring (IORING_OP_READ). The fiber parks as .Blocked and yields;
    // the kernel completes the read asynchronously and the scheduler's CQE
    // drain wakes the fiber. Other fibers run in the meantime.
    //
    // open/fstat remain synchronous -- fast VFS metadata lookups that don't
    // benefit from async submission.
    //
    // Fallback: Outside a scheduler context (unit tests), a plain blocking
    // readAll is used -- no io_uring, no yield.
    pub noinline fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
        const fd = try openPathFd(path, .{ .ACCMODE = .RDONLY }, 0);
        defer compat.closeFd(fd);
        const size: usize = @intCast(try compat.fileSizeFd(fd));
        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        if (fp.scheduler_running) {
            // Async path: submit IORING_OP_READ, yield, resume on CQE.
            const sched = fp.active_scheduler;
            const task = sched.getCurrent();
            var total: usize = 0;
            while (total < buffer.len) {
                var waiter = fp.Scheduler.IoWaiter{ .task = task };
                try sched.submitRead(&waiter, fd, buffer[total..]);
                task.base.yield();
                if (waiter.result < 0) return fp.Scheduler.ioError(waiter.result);
                if (waiter.result == 0) break; // EOF
                total += @intCast(waiter.result);
            }
            return buffer[0..total];
        } else {
            // Blocking fallback (no scheduler -- unit tests, CLI tools).
            var total: usize = 0;
            while (total < buffer.len) {
                const n = std.posix.read(fd, buffer[total..]) catch break;
                if (n == 0) break;
                total += n;
            }
            return buffer[0..total];
        }
    }

    // List all files in a directory. Returns an ArrayListUnmanaged of heap-allocated
    // filename slices (not full paths). Caller owns the list and each string.
    // Usage: files = listDir(allocator, "/some/dir")
    pub fn listDir(allocator: std.mem.Allocator, path: []const u8) !std.ArrayListUnmanaged([]const u8) {
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (list.items) |s| allocator.free(s);
            list.deinit(allocator);
        }
        if (path.len > 255) return error.NameTooLong;
        var path_buf: [256]u8 = undefined;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        const dir = std.c.opendir(path_buf[0..path.len :0]) orelse return error.FileNotFound;
        defer _ = std.c.closedir(dir);
        while (std.c.readdir(dir)) |entry| {
            const name = std.mem.sliceTo(&entry.name, 0);
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            if (entry.type == std.c.DT.REG) {
                const dup = try allocator.dupe(u8, name);
                try list.append(allocator, dup);
            }
        }
        return list;
    }

    // List ALL entries (files AND directories) in a directory.
    // Returns entries prefixed with "f:" for files or "d:" for directories.
    // Usage: entries = listAll(allocator, "/some/dir")
    pub fn listAll(allocator: std.mem.Allocator, path: []const u8) !std.ArrayListUnmanaged([]const u8) {
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (list.items) |s| allocator.free(s);
            list.deinit(allocator);
        }
        if (path.len > 255) return error.NameTooLong;
        var path_buf: [256]u8 = undefined;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        const dir = std.c.opendir(path_buf[0..path.len :0]) orelse return error.FileNotFound;
        defer _ = std.c.closedir(dir);
        while (std.c.readdir(dir)) |entry| {
            const name = std.mem.sliceTo(&entry.name, 0);
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            const prefix: []const u8 = switch (entry.type) {
                std.c.DT.REG => "f:",
                std.c.DT.DIR => "d:",
                else => continue,
            };
            const full = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, name });
            try list.append(allocator, full);
        }
        return list;
    }

    // Get file size in bytes. Returns -1 on error.
    // Usage: size = fileSize("/some/file.txt")
    pub fn fileSize(path: []const u8) i64 {
        const fd = openPathFd(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch return -1;
        defer compat.closeFd(fd);
        const size = compat.fileSizeFd(fd) catch return -1;
        return @intCast(size);
    }

    // Count non-overlapping occurrences of needle in haystack.
    // Returns 0 if needle is empty or not found.
    // Usage: n = countOccurrences("hello world", "o")  → 2
    //
    // Strategy: use libc memchr (SIMD-accelerated on all modern platforms) to
    // find first-byte hits at full vector width (16-32 bytes/cycle on SSE2/AVX2),
    // then scalar-verify the remaining bytes.  This matches the approach used by
    // Go's bytes.Count and Rust's memchr::memmem, and is strictly faster than
    // std.mem.count whose irregular stride (needle.len on hit, 1 on miss) prevents
    // LLVM from autovectorizing the inner loop.
    pub fn countOccurrences(haystack: []const u8, needle: []const u8) i64 {
        if (needle.len == 0) return 0;
        var count: i64 = 0;
        var remaining = haystack;
        while (remaining.len >= needle.len) {
            // SIMD scan for first byte of needle.
            const ptr = memchr(remaining.ptr, needle[0], remaining.len) orelse break;
            const offset = @intFromPtr(ptr) - @intFromPtr(remaining.ptr);
            const rest = remaining[offset..];
            if (rest.len >= needle.len and std.mem.eql(u8, rest[0..needle.len], needle)) {
                count += 1;
                remaining = rest[needle.len..];
            } else {
                remaining = rest[1..];
            }
        }
        return count;
    }

    // Sleep for milliseconds using a blocking OS sleep. Intended for tests / utility code.
    pub fn sleep(ms: u64) void {
        compat.sleepNs(ms * std.time.ns_per_ms);
    }

    // Write File
    //
    // Async path mirrors readFile: open is synchronous, bulk write uses
    // io_uring IORING_OP_WRITE. Handles short writes by resubmitting
    // the remainder.
    pub noinline fn writeFile(path: []const u8, content: []const u8) !void {
        const fd = try openPathFd(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
        defer compat.closeFd(fd);

        if (fp.scheduler_running) {
            const sched = fp.active_scheduler;
            const task = sched.getCurrent();
            var written: usize = 0;
            while (written < content.len) {
                var waiter = fp.Scheduler.IoWaiter{ .task = task };
                try sched.submitWrite(&waiter, fd, content[written..]);
                task.base.yield();
                if (waiter.result < 0) return fp.Scheduler.ioError(waiter.result);
                if (waiter.result == 0) return error.WriteError; // zero bytes written
                written += @intCast(waiter.result);
            }
        } else {
            var written: usize = 0;
            while (written < content.len) {
                written += compat.writeFd(fd, content[written..]) catch return error.WriteError;
            }
        }
    }

    // Read Line from stdin
    const ReadLineCtx = struct {
        allocator: std.mem.Allocator,
        result: []const u8 = &.{},
        err: ?anyerror = null,
        fn run(ptr: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            var buf: [4096]u8 = undefined;
            var pos: usize = 0;
            while (pos < buf.len) {
                const n = std.posix.read(std.posix.STDIN_FILENO, buf[pos..][0..1]) catch |e| {
                    self.err = e;
                    return;
                };
                if (n == 0) break; // EOF
                if (buf[pos] == '\n') break;
                pos += 1;
            }
            if (pos > 0 and buf[pos - 1] == '\r') {
                pos -= 1;
            }
            self.result = self.allocator.dupe(u8, buf[0..pos]) catch |e| {
                self.err = e;
                return;
            };
        }
    };

    pub noinline fn readLine(allocator: std.mem.Allocator) ![]const u8 {
        var ctx = ReadLineCtx{ .allocator = allocator };
        if (fp.scheduler_running) {
            const rt: *Runtime = @ptrCast(@alignCast(fp.active_scheduler.getCurrent().runtime_ptr.?));
            rt.onRootStack(@as(*const fn (?*anyopaque) callconv(.c) void, &ReadLineCtx.run), @ptrCast(&ctx));
        } else {
            ReadLineCtx.run(@ptrCast(&ctx));
        }
        if (ctx.err) |e| return e;
        return ctx.result;
    }

    // Line editing with history (POSIX termios)
    const LINE_MAX = 4096;
    const HISTORY_MAX = 256;

    var rl_history: [HISTORY_MAX][LINE_MAX]u8 = undefined;
    var rl_history_lens: [HISTORY_MAX]usize = [_]usize{0} ** HISTORY_MAX;
    var rl_history_count: usize = 0;
    var rl_history_initialized: bool = false;

    fn rlHistoryAdd(buf: []const u8) void {
        if (buf.len == 0) return;
        // Don't add duplicates of the last entry
        if (rl_history_count > 0) {
            const last_idx = rl_history_count - 1;
            const last = rl_history[last_idx][0..rl_history_lens[last_idx]];
            if (std.mem.eql(u8, last, buf)) return;
        }
        if (rl_history_count < HISTORY_MAX) {
            @memcpy(rl_history[rl_history_count][0..buf.len], buf);
            rl_history_lens[rl_history_count] = buf.len;
            rl_history_count += 1;
        } else {
            // Shift history up, drop oldest
            for (0..HISTORY_MAX - 1) |i| {
                @memcpy(rl_history[i][0..rl_history_lens[i + 1]], rl_history[i + 1][0..rl_history_lens[i + 1]]);
                rl_history_lens[i] = rl_history_lens[i + 1];
            }
            @memcpy(rl_history[HISTORY_MAX - 1][0..buf.len], buf);
            rl_history_lens[HISTORY_MAX - 1] = buf.len;
        }
    }

    const ReadLineEditCtx = struct {
        allocator: std.mem.Allocator,
        prompt: []const u8,
        result: []const u8 = &.{},
        err: ?anyerror = null,

        fn run(ptr: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.result = rlEdit(self.allocator, self.prompt) catch |e| {
                self.err = e;
                return;
            };
        }
    };

    fn rlEdit(allocator: std.mem.Allocator, prompt: []const u8) ![]const u8 {
        const stdin_fd = std.posix.STDIN_FILENO;
        const stderr_fd = std.posix.STDERR_FILENO;

        // Check if stdin is a tty; if not, fall back to basic readLine
        if (!std.posix.isatty(stdin_fd)) {
            return readLine(allocator);
        }

        // Save original terminal state
        const orig = try std.posix.tcgetattr(stdin_fd);

        // Enter raw mode
        var raw = orig;
        // Input: no break/CR-to-NL/parity/strip/flow-control
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        // Output: keep default
        // Local: no echo, no canonical, no signals, no extended
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;
        // Read returns after 1 byte
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;

        try std.posix.tcsetattr(stdin_fd, .FLUSH, raw);
        errdefer std.posix.tcsetattr(stdin_fd, .FLUSH, orig) catch {};

        defer std.posix.tcsetattr(stdin_fd, .FLUSH, orig) catch {};

        // Write prompt
        _ = std.posix.write(stderr_fd, prompt) catch {};

        var buf: [LINE_MAX]u8 = undefined;
        var line_len: usize = 0;
        var pos: usize = 0; // cursor position within buf
        var hist_idx: usize = rl_history_count; // browsing index (count = "current line")
        var saved_line: [LINE_MAX]u8 = undefined;
        var saved_len: usize = 0;

        while (true) {
            var c: [1]u8 = undefined;
            const n = std.posix.read(stdin_fd, &c) catch break;
            if (n == 0) {
                // EOF
                if (line_len == 0) return error.EndOfStream;
                break;
            }

            switch (c[0]) {
                '\r', '\n' => {
                    // Submit line
                    _ = std.posix.write(stderr_fd, "\r\n") catch {};
                    break;
                },
                3 => {
                    // Ctrl-C: discard line, print ^C
                    _ = std.posix.write(stderr_fd, "^C\r\n") catch {};
                    line_len = 0;
                    pos = 0;
                    break;
                },
                4 => {
                    // Ctrl-D: EOF if empty, delete-char otherwise
                    if (line_len == 0) {
                        _ = std.posix.write(stderr_fd, "\r\n") catch {};
                        return error.EndOfStream;
                    }
                    if (pos < line_len) {
                        std.mem.copyForwards(u8, buf[pos..line_len - 1], buf[pos + 1 .. line_len]);
                        line_len -= 1;
                        rlRefresh(stderr_fd, prompt, buf[0..line_len], pos);
                    }
                },
                1 => {
                    // Ctrl-A: home
                    pos = 0;
                    rlRefresh(stderr_fd, prompt, buf[0..line_len], pos);
                },
                5 => {
                    // Ctrl-E: end
                    pos = line_len;
                    rlRefresh(stderr_fd, prompt, buf[0..line_len], pos);
                },
                11 => {
                    // Ctrl-K: kill to end of line
                    line_len = pos;
                    rlRefresh(stderr_fd, prompt, buf[0..line_len], pos);
                },
                21 => {
                    // Ctrl-U: kill to start of line
                    std.mem.copyForwards(u8, buf[0 .. line_len - pos], buf[pos..line_len]);
                    line_len -= pos;
                    pos = 0;
                    rlRefresh(stderr_fd, prompt, buf[0..line_len], pos);
                },
                12 => {
                    // Ctrl-L: clear screen and redraw
                    _ = std.posix.write(stderr_fd, "\x1b[H\x1b[2J") catch {};
                    rlRefresh(stderr_fd, prompt, buf[0..line_len], pos);
                },
                127, 8 => {
                    // Backspace (127 or BS 8)
                    if (pos > 0) {
                        std.mem.copyForwards(u8, buf[pos - 1 .. line_len - 1], buf[pos..line_len]);
                        pos -= 1;
                        line_len -= 1;
                        rlRefresh(stderr_fd, prompt, buf[0..line_len], pos);
                    }
                },
                27 => {
                    // Escape sequence
                    var seq: [2]u8 = undefined;
                    const n1 = std.posix.read(stdin_fd, seq[0..1]) catch break;
                    if (n1 == 0) break;
                    if (seq[0] == '[') {
                        const n2 = std.posix.read(stdin_fd, seq[1..2]) catch break;
                        if (n2 == 0) break;
                        switch (seq[1]) {
                            'A' => {
                                // Up arrow: history previous
                                if (rl_history_count > 0 and hist_idx > 0) {
                                    if (hist_idx == rl_history_count) {
                                        // Save current line
                                        @memcpy(saved_line[0..line_len], buf[0..line_len]);
                                        saved_len = line_len;
                                    }
                                    hist_idx -= 1;
                                    const hlen = rl_history_lens[hist_idx];
                                    @memcpy(buf[0..hlen], rl_history[hist_idx][0..hlen]);
                                    line_len = hlen;
                                    pos = line_len;
                                    rlRefresh(stderr_fd, prompt, buf[0..line_len], pos);
                                }
                            },
                            'B' => {
                                // Down arrow: history next
                                if (hist_idx < rl_history_count) {
                                    hist_idx += 1;
                                    if (hist_idx == rl_history_count) {
                                        // Restore saved line
                                        @memcpy(buf[0..saved_len], saved_line[0..saved_len]);
                                        line_len = saved_len;
                                    } else {
                                        const hlen = rl_history_lens[hist_idx];
                                        @memcpy(buf[0..hlen], rl_history[hist_idx][0..hlen]);
                                        line_len = hlen;
                                    }
                                    pos = line_len;
                                    rlRefresh(stderr_fd, prompt, buf[0..line_len], pos);
                                }
                            },
                            'C' => {
                                // Right arrow
                                if (pos < line_len) {
                                    pos += 1;
                                    rlRefresh(stderr_fd, prompt, buf[0..line_len], pos);
                                }
                            },
                            'D' => {
                                // Left arrow
                                if (pos > 0) {
                                    pos -= 1;
                                    rlRefresh(stderr_fd, prompt, buf[0..line_len], pos);
                                }
                            },
                            'H' => {
                                // Home
                                pos = 0;
                                rlRefresh(stderr_fd, prompt, buf[0..line_len], pos);
                            },
                            'F' => {
                                // End
                                pos = line_len;
                                rlRefresh(stderr_fd, prompt, buf[0..line_len], pos);
                            },
                            '3' => {
                                // Delete key: ESC [ 3 ~
                                var tilde: [1]u8 = undefined;
                                _ = std.posix.read(stdin_fd, &tilde) catch break;
                                if (tilde[0] == '~' and pos < line_len) {
                                    std.mem.copyForwards(u8, buf[pos..line_len - 1], buf[pos + 1 .. line_len]);
                                    line_len -= 1;
                                    rlRefresh(stderr_fd, prompt, buf[0..line_len], pos);
                                }
                            },
                            '1' => {
                                // Home: ESC [ 1 ~
                                var tilde: [1]u8 = undefined;
                                _ = std.posix.read(stdin_fd, &tilde) catch break;
                                if (tilde[0] == '~') {
                                    pos = 0;
                                    rlRefresh(stderr_fd, prompt, buf[0..line_len], pos);
                                }
                            },
                            '4' => {
                                // End: ESC [ 4 ~
                                var tilde: [1]u8 = undefined;
                                _ = std.posix.read(stdin_fd, &tilde) catch break;
                                if (tilde[0] == '~') {
                                    pos = line_len;
                                    rlRefresh(stderr_fd, prompt, buf[0..line_len], pos);
                                }
                            },
                            else => {},
                        }
                    } else if (seq[0] == 'O') {
                        // ESC O H (Home), ESC O F (End) - alternate sequences
                        switch (seq[1]) {
                            'H' => {
                                pos = 0;
                                rlRefresh(stderr_fd, prompt, buf[0..line_len], pos);
                            },
                            'F' => {
                                pos = line_len;
                                rlRefresh(stderr_fd, prompt, buf[0..line_len], pos);
                            },
                            else => {},
                        }
                    }
                },
                else => {
                    // Printable character
                    if (c[0] >= 32 and line_len < LINE_MAX - 1) {
                        if (pos < line_len) {
                            // Shift right to make room
                            std.mem.copyBackwards(u8, buf[pos + 1 .. line_len + 1], buf[pos..line_len]);
                        }
                        buf[pos] = c[0];
                        pos += 1;
                        line_len += 1;
                        rlRefresh(stderr_fd, prompt, buf[0..line_len], pos);
                    }
                },
            }
        }

        // Add to history
        if (line_len > 0) {
            rlHistoryAdd(buf[0..line_len]);
        }

        return try allocator.dupe(u8, buf[0..line_len]);
    }

    fn rlRefresh(fd: std.posix.fd_t, prompt: []const u8, line: []const u8, cursor: usize) void {
        // \r to start of line, write prompt + buffer, clear to end, reposition cursor
        var out: [LINE_MAX + 256]u8 = undefined;
        var off: usize = 0;

        // Carriage return
        out[off] = '\r';
        off += 1;

        // Prompt
        const plen = @min(prompt.len, out.len - off - 64);
        @memcpy(out[off .. off + plen], prompt[0..plen]);
        off += plen;

        // Line content
        const llen = @min(line.len, out.len - off - 64);
        @memcpy(out[off .. off + llen], line[0..llen]);
        off += llen;

        // Clear to end of line: ESC [ K
        out[off] = '\x1b';
        off += 1;
        out[off] = '[';
        off += 1;
        out[off] = 'K';
        off += 1;

        // Move cursor to correct position: \r then ESC [ <n> C
        out[off] = '\r';
        off += 1;

        const cursor_pos = prompt.len + cursor;
        if (cursor_pos > 0) {
            // ESC [ <n> C - move cursor forward n columns
            out[off] = '\x1b';
            off += 1;
            out[off] = '[';
            off += 1;
            // Format the number
            var num_buf: [16]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{cursor_pos}) catch return;
            @memcpy(out[off .. off + num_str.len], num_str);
            off += num_str.len;
            out[off] = 'C';
            off += 1;
        }

        _ = std.posix.write(fd, out[0..off]) catch {};
    }

    pub noinline fn readLinePrompt(allocator: std.mem.Allocator, prompt: []const u8) ![]const u8 {
        var ctx = ReadLineEditCtx{ .allocator = allocator, .prompt = prompt };
        if (fp.scheduler_running) {
            const rt: *Runtime = @ptrCast(@alignCast(fp.active_scheduler.getCurrent().runtime_ptr.?));
            rt.onRootStack(@as(*const fn (?*anyopaque) callconv(.c) void, &ReadLineEditCtx.run), @ptrCast(&ctx));
        } else {
            ReadLineEditCtx.run(@ptrCast(&ctx));
        }
        if (ctx.err) |e| return e;
        return ctx.result;
    }

    // String Lib

    // Used to make HEAP strings
    pub fn makeString(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
        Runtime.profileAlloc(text.len);
        return try std.fmt.allocPrint(allocator, "{s}", .{text});
    }

    pub fn substr(allocator: std.mem.Allocator, str: []const u8, start: i64, length: i64) ![]const u8 {
        Runtime.profileAlloc(@intCast(length));
        const u_start: usize = @intCast(start);
        const u_len: usize = @intCast(length);

        if (u_start + u_len > str.len) return error.OutOfBounds;

        // Slicing in Zig is O(1) pointer math!
        const slice = str[u_start .. u_start + u_len];

        // We must COPY it to the new allocator (usually Heap) so it survives
        return allocator.dupe(u8, slice);
    }

    // O(1) sub-slice for String@raw — zero copy, no allocation.
    // Caller guarantees lifetime: the result borrows from `str`.
    pub fn substrRaw(str: []const u8, start: i64, length: i64) []const u8 {
        const u_start: usize = @intCast(start);
        const u_len: usize = @intCast(length);
        return str[u_start .. u_start + u_len];
    }

    // String Equality (Content check)
    pub fn strEql(s1: []const u8, s2: []const u8) bool {
        return std.mem.eql(u8, s1, s2);
    }

    // Lexicographic string comparison. Returns -1, 0, or 1.
    pub fn strcmp(a: []const u8, b: []const u8) i64 {
        const order = std.mem.order(u8, a, b);
        return switch (order) {
            .lt => @as(i64, -1),
            .eq => @as(i64, 0),
            .gt => @as(i64, 1),
        };
    }

    // Generic Equality (works for primitives and slices)
    pub fn eql(a: anytype, b: @TypeOf(a)) bool {
        const T = @TypeOf(a);
        const info = @typeInfo(T);

        // For slices (like strings), use mem.eql
        if (info == .pointer and info.pointer.size == .slice) {
            return std.mem.eql(info.pointer.child, a, b);
        }

        // For primitives (int, float, bool), use ==
        return a == b;
    }

    // indexOf: returns ?i64 position of needle in haystack, or null if not found.
    // Uses memchr (libc SIMD) to find the first byte, then scalar-verifies the rest.
    pub fn indexOf(haystack: []const u8, needle: []const u8) ?i64 {
        if (needle.len == 0) return 0;
        var remaining = haystack;
        while (remaining.len >= needle.len) {
            const ptr = memchr(remaining.ptr, needle[0], remaining.len) orelse return null;
            const offset = @intFromPtr(ptr) - @intFromPtr(remaining.ptr);
            const rest = remaining[offset..];
            if (rest.len >= needle.len and std.mem.eql(u8, rest[0..needle.len], needle))
                return @intCast(@intFromPtr(ptr) - @intFromPtr(haystack.ptr));
            remaining = rest[1..];
        }
        return null;
    }
    // toString: Int64 -> String (heap-allocated decimal representation)
    /// Parse a string to i64. Returns error on invalid input.
    pub fn toInt(s: []const u8) !i64 {
        return std.fmt.parseInt(i64, s, 10);
    }

    // -----------------------------------------------------------------
    // Clock & Timing
    // -----------------------------------------------------------------

    // Integer arithmetic: checked in debug/safe (panics on overflow),
    // wrapping in release (matches Rust semantics). This ensures hash
    // functions, RNGs, and checksums work correctly in production while
    // catching accidental overflow bugs during development.
    fn IntResult(comptime A: type, comptime B: type) type {
        // When mixing comptime_int with a fixed-width int, use the fixed-width type.
        if (A == comptime_int) return B;
        return A;
    }

    pub inline fn intAdd(a: anytype, b: anytype) IntResult(@TypeOf(a), @TypeOf(b)) {
        const R = IntResult(@TypeOf(a), @TypeOf(b));
        const av: R = a;
        const bv: R = b;
        if (@import("builtin").mode == .Debug or @import("builtin").mode == .ReleaseSafe) {
            return av + bv;
        } else {
            return av +% bv;
        }
    }
    pub inline fn intSub(a: anytype, b: anytype) IntResult(@TypeOf(a), @TypeOf(b)) {
        const R = IntResult(@TypeOf(a), @TypeOf(b));
        const av: R = a;
        const bv: R = b;
        if (@import("builtin").mode == .Debug or @import("builtin").mode == .ReleaseSafe) {
            return av - bv;
        } else {
            return av -% bv;
        }
    }
    pub inline fn intMul(a: anytype, b: anytype) IntResult(@TypeOf(a), @TypeOf(b)) {
        const R = IntResult(@TypeOf(a), @TypeOf(b));
        const av: R = a;
        const bv: R = b;
        if (@import("builtin").mode == .Debug or @import("builtin").mode == .ReleaseSafe) {
            return av * bv;
        } else {
            return av *% bv;
        }
    }

    // Explicit wrapping arithmetic (%+, %-, %*) — wraps in ALL build modes.
    // Use for hash functions, RNGs, checksums, and other intentional-overflow code.
    pub inline fn wrapAdd(a: anytype, b: anytype) IntResult(@TypeOf(a), @TypeOf(b)) {
        const R = IntResult(@TypeOf(a), @TypeOf(b));
        return @as(R, a) +% @as(R, b);
    }
    pub inline fn wrapSub(a: anytype, b: anytype) IntResult(@TypeOf(a), @TypeOf(b)) {
        const R = IntResult(@TypeOf(a), @TypeOf(b));
        return @as(R, a) -% @as(R, b);
    }
    pub inline fn wrapMul(a: anytype, b: anytype) IntResult(@TypeOf(a), @TypeOf(b)) {
        const R = IntResult(@TypeOf(a), @TypeOf(b));
        return @as(R, a) *% @as(R, b);
    }

    // Explicit checked arithmetic (!+, !-, !*) — panics in ALL build modes.
    // Use for financial math, safety-critical code, and overflow detection.
    pub inline fn checkAdd(a: anytype, b: anytype) IntResult(@TypeOf(a), @TypeOf(b)) {
        const R = IntResult(@TypeOf(a), @TypeOf(b));
        const result = @addWithOverflow(@as(R, a), @as(R, b));
        if (result[1] != 0) @panic("integer overflow in checked addition (!+)");
        return result[0];
    }
    pub inline fn checkSub(a: anytype, b: anytype) IntResult(@TypeOf(a), @TypeOf(b)) {
        const R = IntResult(@TypeOf(a), @TypeOf(b));
        const result = @subWithOverflow(@as(R, a), @as(R, b));
        if (result[1] != 0) @panic("integer overflow in checked subtraction (!-)");
        return result[0];
    }
    pub inline fn checkMul(a: anytype, b: anytype) IntResult(@TypeOf(a), @TypeOf(b)) {
        const R = IntResult(@TypeOf(a), @TypeOf(b));
        const result = @mulWithOverflow(@as(R, a), @as(R, b));
        if (result[1] != 0) @panic("integer overflow in checked multiplication (!*)");
        return result[0];
    }

    /// Wall clock milliseconds since Unix epoch.
    pub fn timestampMs() i64 {
        return compat.milliTimestamp();
    }

    /// Returns the total number of scheduler threads.
    /// Matches the CLEAR_THREADS environment variable.
    pub fn threadCount() i64 {
        return @as(i64, @intCast(fp.global_registry.count()));
    }

    // sleep is called directly on rt: rt.sleep(ms) — see Runtime.sleep in runtime.zig

    /// Peak resident set size (VmHWM) in KB, from /proc/self/status.
    /// Returns the high-water mark of physical memory used by this process.
    /// Cross-language comparable — works identically in C, Go, Zig, etc.
    pub fn peakMemoryKb() i64 {
        const fd = openPathFd("/proc/self/status", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch return -1;
        defer compat.closeFd(fd);
        var buf: [4096]u8 = undefined;
        const n = std.posix.read(fd, &buf) catch return -1;
        const content = buf[0..n];
        // Find "VmHWM:" line and parse the KB value
        if (std.mem.indexOf(u8, content, "VmHWM:")) |pos| {
            var i = pos + 6; // skip "VmHWM:"
            while (i < content.len and (content[i] == ' ' or content[i] == '\t')) : (i += 1) {}
            var val: i64 = 0;
            while (i < content.len and content[i] >= '0' and content[i] <= '9') : (i += 1) {
                val = val * 10 + @as(i64, content[i] - '0');
            }
            return val;
        }
        return -1;
    }

    /// Peak virtual memory size (VmPeak) in KB, from /proc/self/status.
    pub fn peakVirtualMemoryKb() i64 {
        const fd = openPathFd("/proc/self/status", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch return -1;
        defer compat.closeFd(fd);
        var buf: [4096]u8 = undefined;
        const n = std.posix.read(fd, &buf) catch return -1;
        const content = buf[0..n];
        if (std.mem.indexOf(u8, content, "VmPeak:")) |pos| {
            var i = pos + 7;
            while (i < content.len and (content[i] == ' ' or content[i] == '\t')) : (i += 1) {}
            var val: i64 = 0;
            while (i < content.len and content[i] >= '0' and content[i] <= '9') : (i += 1) {
                val = val * 10 + @as(i64, content[i] - '0');
            }
            return val;
        }
        return -1;
    }

    /// Current resident set size (VmRSS) in KB, from /proc/self/status.
    pub fn currentMemoryKb() i64 {
        const fd = openPathFd("/proc/self/status", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch return -1;
        defer compat.closeFd(fd);
        var buf: [4096]u8 = undefined;
        const n = std.posix.read(fd, &buf) catch return -1;
        const content = buf[0..n];
        if (std.mem.indexOf(u8, content, "VmRSS:")) |pos| {
            var i = pos + 6; // skip "VmRSS:"
            while (i < content.len and (content[i] == ' ' or content[i] == '\t')) : (i += 1) {}
            var val: i64 = 0;
            while (i < content.len and content[i] >= '0' and content[i] <= '9') : (i += 1) {
                val = val * 10 + @as(i64, content[i] - '0');
            }
            return val;
        }
        return -1;
    }

    /// Fault pages in the current fiber's allocated stack slice.
    /// This is benchmark-only plumbing: it makes resident memory reflect the
    /// selected stack tier instead of only the pages naturally reached by a
    /// tiny stack frame. It is a no-op on the root stack and for FSM tasks.
    pub fn touchCurrentFiberStack(bytes_i64: i64, seed: i64) i64 {
        const fiber = fc.__fiber orelse return seed;
        if (bytes_i64 <= 0) return seed;

        const requested: usize = @intCast(bytes_i64);
        const stack = fiber.stack.memory;
        const bytes = @min(requested, stack.len);
        if (bytes == 0) return seed;

        var acc: u64 = @bitCast(seed);
        const start = stack.len - bytes;
        var offset: usize = 0;
        while (offset < bytes) : (offset += 4096) {
            const idx = start + offset;
            const value: u8 = @truncate(acc +% @as(u64, @intCast(offset)));
            stack[idx] = value;
            acc +%= stack[idx];
        }

        const last = stack.len - 1;
        const last_value: u8 = @truncate(acc +% @as(u64, @intCast(bytes)));
        stack[last] = last_value;
        acc +%= stack[last];
        return @bitCast(acc);
    }

    // -----------------------------------------------------------------
    // Random
    // -----------------------------------------------------------------
    //
    // Per-thread userspace PRNG (Xoshiro256++), seeded once from the OS
    // CSPRNG on first use. Each scheduler-thread has its own state, so
    // two fibers on different schedulers don't contend; two fibers on
    // the same scheduler share state, which is fine for non-cryptographic
    // randomness (the cooperative scheduler serializes them anyway).
    //
    // Pre-fix this used compat.randomBytes (which calls getrandom(2))
    // for every randomInt/random call. On benchmark 14_nested_lock
    // that meant 2M getrandom syscalls (~8.6s of kernel time, dominating
    // the 9.9s wall clock). With Xoshiro the per-call cost drops from
    // ~4µs to ~3ns. CSPRNG semantics are not the contract for randomInt
    // — std_lib.rb documents it as "random integer in [0, max)" with
    // no security guarantee, and Rust/Go do the same userspace-PRNG
    // pattern in their stdlib.
    threadlocal var prng_state: std.Random.DefaultPrng = undefined;
    threadlocal var prng_seeded: bool = false;

    inline fn threadPrng() std.Random {
        if (!prng_seeded) {
            var seed_bytes: [8]u8 = undefined;
            compat.randomBytes(&seed_bytes) catch {
                // Fall back to a per-thread fingerprint when getrandom
                // is unavailable (sandbox / very early init). Sufficient
                // entropy for non-cryptographic use.
                const tid: u64 = @intCast(std.Thread.getCurrentId());
                std.mem.writeInt(u64, &seed_bytes, tid *% 0x9E3779B97F4A7C15, .little);
            };
            const seed = std.mem.readInt(u64, &seed_bytes, .little);
            prng_state = std.Random.DefaultPrng.init(seed);
            prng_seeded = true;
        }
        return prng_state.random();
    }

    /// Random float in [0.0, 1.0). Uses per-thread userspace PRNG.
    pub fn random() f64 {
        return threadPrng().float(f64);
    }

    /// Random integer in [0, max). Uses per-thread userspace PRNG.
    pub fn randomInt(max: i64) i64 {
        if (max <= 0) return 0;
        const umax: u64 = @intCast(max);
        return @intCast(threadPrng().uintLessThan(u64, umax));
    }

    /// Format an integer into a caller-provided buffer. Returns the slice written.
    /// Zero-allocation — use for transient string interpolation (map keys, comparisons).
    pub fn fmtInt(buf: []u8, value: i64) []const u8 {
        var tmp: [21]u8 = undefined;
        var slen: usize = 0;
        var v: u64 = if (value < 0) @intCast(-value) else @intCast(value);
        if (v == 0) {
            tmp[0] = '0';
            slen = 1;
        } else {
            while (v > 0) : (slen += 1) {
                tmp[slen] = @intCast('0' + (v % 10));
                v /= 10;
            }
            if (value < 0) {
                tmp[slen] = '-';
                slen += 1;
            }
            var lo: usize = 0;
            var hi: usize = slen - 1;
            while (lo < hi) {
                const t = tmp[lo];
                tmp[lo] = tmp[hi];
                tmp[hi] = t;
                lo += 1;
                hi -= 1;
            }
        }
        @memcpy(buf[0..slen], tmp[0..slen]);
        return buf[0..slen];
    }

    /// Concatenate slices into a caller-provided buffer. Returns the slice written.
    /// Zero-allocation — use for transient string building (map keys, comparisons).
    pub fn bufConcat(buf: []u8, parts: anytype) []const u8 {
        var pos: usize = 0;
        inline for (parts) |part| {
            @memcpy(buf[pos..][0..part.len], part);
            pos += part.len;
        }
        return buf[0..pos];
    }

    pub fn intToString(allocator: std.mem.Allocator, value: i64) ![]const u8 {
        Runtime.profileAlloc(21);
        // Max i64 is 19 digits + sign + null = 21 bytes; allocate 21
        var buf: [21]u8 = undefined;
        var slen: usize = 0;
        var v: u64 = if (value < 0) @intCast(-value) else @intCast(value);
        if (v == 0) {
            buf[0] = '0';
            slen = 1;
        } else {
            while (v > 0) : (slen += 1) {
                buf[slen] = @intCast('0' + (v % 10));
                v /= 10;
            }
            if (value < 0) {
                buf[slen] = '-';
                slen += 1;
            }
            // Reverse in-place
            var lo: usize = 0;
            var hi: usize = slen - 1;
            while (lo < hi) {
                const tmp = buf[lo];
                buf[lo] = buf[hi];
                buf[hi] = tmp;
                lo += 1;
                hi -= 1;
            }
        }
        const result = try allocator.alloc(u8, slen);
        @memcpy(result, buf[0..slen]);
        return result;
    }

    // Split: String -> List
    pub fn split(allocator: std.mem.Allocator, str: []const u8, delimiter: []const u8) !std.ArrayListUnmanaged([]const u8) {
        var list: std.ArrayListUnmanaged([]const u8) = .empty;

        // splitSequence handles string delimiters (e.g. ", ")
        var iter = std.mem.splitSequence(u8, str, delimiter);

        while (iter.next()) |part| {
            // Important: Make a copy of the part in the new allocator (Heap)
            // so the list doesn't point to frame memory that might die.
            const part_copy = try allocator.dupe(u8, part);
            try list.append(allocator, part_copy);
        }
        return list;
    }

    // Join: List -> String (technically an array function)
    pub fn join(allocator: std.mem.Allocator, list: anytype, delimiter: []const u8) ![]const u8 {
        Runtime.profileAlloc(0); // size unknown until join completes
        const items = if (@hasField(@TypeOf(list), "items")) list.items else list;
        return std.mem.join(allocator, delimiter, items);
    }

    // replace(str, old, new) -> String with all occurrences replaced
    pub fn stringReplace(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ![]const u8 {
        Runtime.profileAlloc(0);
        var result: std.ArrayListUnmanaged(u8) = .empty;
        var i: usize = 0;
        while (i < haystack.len) {
            if (i + needle.len <= haystack.len and std.mem.eql(u8, haystack[i..][0..needle.len], needle)) {
                try result.appendSlice(allocator, replacement);
                i += needle.len;
            } else {
                try result.append(allocator, haystack[i]);
                i += 1;
            }
        }
        return result.items;
    }

    // lowercase(str) -> new string with all ASCII bytes lowered
    pub fn stringLowercase(allocator: std.mem.Allocator, str: []const u8) ![]const u8 {
        Runtime.profileAlloc(str.len);
        const buf = try allocator.alloc(u8, str.len);
        for (str, 0..) |c, idx| {
            buf[idx] = std.ascii.toLower(c);
        }
        return buf;
    }

    // uppercase(str) -> new string with all ASCII bytes uppercased
    pub fn stringUppercase(allocator: std.mem.Allocator, str: []const u8) ![]const u8 {
        Runtime.profileAlloc(str.len);
        const buf = try allocator.alloc(u8, str.len);
        for (str, 0..) |c, idx| {
            buf[idx] = std.ascii.toUpper(c);
        }
        return buf;
    }

    // shell

    pub fn shell(allocator: std.mem.Allocator, cmd: []const u8) ![]const u8 {
        const libc = struct {
            extern "c" fn popen(command: [*:0]const u8, mode: [*:0]const u8) ?*std.c.FILE;
            extern "c" fn pclose(stream: *std.c.FILE) c_int;
        };

        const c_cmd = try allocator.dupeZ(u8, cmd);
        defer allocator.free(c_cmd);

        const pipe = libc.popen(c_cmd.ptr, "r") orelse return error.Unexpected;
        defer _ = libc.pclose(pipe);

        var out = std.ArrayListUnmanaged(u8).empty;
        errdefer out.deinit(allocator);

        var buf: [4096]u8 = undefined;
        while (true) {
            const n = std.c.fread(&buf, 1, buf.len, pipe);
            if (n == 0) break;
            try out.appendSlice(allocator, buf[0..n]);
        }

        return out.toOwnedSlice(allocator);
    }

    // -------------------------------------------------------------------------
    // TCP SOCKETS — fiber-aware, epoll-backed, Linux only
    // -------------------------------------------------------------------------

    // Create a non-blocking TCP server socket, bind it to `port`, and begin
    // listening. Returns the raw server fd; caller owns it (must socketClose).
    pub fn socketListen(port: u16) !i32 {
        const fd = try compat.socket(
            std.posix.AF.INET,
            std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC,
            0,
        );
        errdefer compat.closeFd(fd);

        // SO_REUSEADDR so we can restart quickly without TIME_WAIT stalls.
        try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

        const addr = std.posix.sockaddr.in{
            .family = std.posix.AF.INET,
            .port   = std.mem.nativeToBig(u16, port),
            .addr   = 0, // INADDR_ANY
            .zero   = [_]u8{0} ** 8,
        };
        try compat.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
        try compat.listen(fd, 128);
        return fd;
    }

    // Accept one incoming connection on `server_fd` via io_uring.
    // Submits IORING_OP_ACCEPT and yields; the CQE result is the client fd
    // (already non-blocking via SOCK_NONBLOCK flag in the SQE).
    // Returns the client fd; caller owns it (close via socketClose / RAII).
    pub noinline fn socketAccept(server_fd: i32) !i32 {
        const sched = fp.active_scheduler;
        const task = sched.getCurrent();
        var waiter = fp.Scheduler.IoWaiter{ .task = task };
        try sched.submitAccept(&waiter, server_fd);
        task.base.yield();
        if (waiter.result < 0) return fp.Scheduler.ioError(waiter.result);
        return waiter.result;
    }

    // -----------------------------------------------------------------------
    // Socket I/O: completion-based via io_uring.
    //
    // Each operation submits a single SQE and yields the fiber. The CQE
    // result contains the byte count (or negative errno). No EAGAIN retry
    // loops -- the kernel handles the wait internally.
    // -----------------------------------------------------------------------

    // Write `data` to a socket via io_uring IORING_OP_SEND.
    // Loops on short sends (resubmits remainder), yielding between each.
    // Returns the total bytes sent (== data.len on success).
    pub noinline fn socketWrite(fd: i32, data: []const u8) !usize {
        const sched = fp.active_scheduler;
        const task = sched.getCurrent();
        var sent: usize = 0;
        while (sent < data.len) {
            var waiter = fp.Scheduler.IoWaiter{ .task = task };
            try sched.submitSend(&waiter, fd, data[sent..]);
            task.base.yield();
            if (waiter.result < 0) return fp.Scheduler.ioError(waiter.result);
            if (waiter.result == 0) return sent;
            sent += @intCast(waiter.result);
        }
        return sent;
    }

    // Close a TCP socket fd. With io_uring completion-based I/O, there are
    // no pending polls to cancel -- the fd is simply closed.
    pub noinline fn socketClose(fd: i32) void {
        compat.closeFd(fd);
    }

    // Read up to 4096 bytes from a connected client socket via io_uring.
    // Submits IORING_OP_RECV and yields until data is available.
    //
    // Reads into a frame-arena buffer (the allocator passed by the transpiler
    // is rt.frameAlloc()). The returned slice lives until the enclosing loop
    // iteration's restoreLoopMark rewinds the arena.
    //
    // Yields after successful read for I/O fairness among concurrent client fibers.
    pub noinline fn socketRead(allocator: std.mem.Allocator, fd: i32) ![]const u8 {
        // Allocate read buffer on the frame arena (not the fiber stack)
        // to avoid consuming 4 KB of the fiber's limited 16 KB stack space.
        const buf = try allocator.alloc(u8, 4096);
        const n = try CheatLib.read(fd, buf);
        const result = buf[0..n];
        // Cooperative yield: if other fibers are Ready, give them a turn.
        // This prevents a single client with pipelined data from monopolizing
        // the scheduler across multiple read-process-write cycles.
        if (fp.scheduler_running) {
            fp.active_scheduler.coopYield();
        }
        return result;
    }

    // Write all bytes from `data` to a connected client socket, discarding the byte count.
    // Yields the fiber via io_uring IORING_OP_SEND.
    // Usage: tcpWrite(client, "hello")
    pub noinline fn socketWriteVoid(fd: i32, data: []const u8) !void {
        _ = try CheatLib.socketWrite(fd, data);
    }

    // Connect to a TCP server at `host:port` (dotted-decimal IPv4 only).
    // Submits IORING_OP_CONNECT and yields; the CQE result is 0 on success
    // or negative errno on error. No getsockoptError post-check needed.
    // Returns the client fd; caller owns it (close via socketClose / RAII).
    pub noinline fn socketConnect(host: []const u8, port: u16) !i32 {
        const fd = try compat.socket(
            std.posix.AF.INET,
            std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC,
            0,
        );
        errdefer compat.closeFd(fd);

        const s_addr = try parseIpv4Addr(host);
        const addr = std.posix.sockaddr.in{
            .family = std.posix.AF.INET,
            .port   = std.mem.nativeToBig(u16, port),
            .addr   = s_addr,
            .zero   = [_]u8{0} ** 8,
        };

        const sched = fp.active_scheduler;
        const task = sched.getCurrent();
        var waiter = fp.Scheduler.IoWaiter{ .task = task };
        try sched.submitConnect(&waiter, fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
        task.base.yield();
        if (waiter.result < 0) return fp.Scheduler.ioError(waiter.result);

        return fd;
    }

    // Parse a dotted-decimal IPv4 address ("127.0.0.1") into a network-byte-order u32.
    fn parseIpv4Addr(host: []const u8) !u32 {
        var parts: [4]u8 = .{0} ** 4;
        var part_idx: usize = 0;
        var cur: u32 = 0;
        var has_digit: bool = false;

        for (host) |c| {
            switch (c) {
                '0'...'9' => {
                    cur = cur * 10 + (c - '0');
                    if (cur > 255) return error.InvalidHost;
                    has_digit = true;
                },
                '.' => {
                    if (!has_digit or part_idx >= 3) return error.InvalidHost;
                    parts[part_idx] = @intCast(cur);
                    part_idx += 1;
                    cur = 0;
                    has_digit = false;
                },
                else => return error.InvalidHost,
            }
        }
        if (!has_digit or part_idx != 3) return error.InvalidHost;
        parts[3] = @intCast(cur);

        // Assemble as host-byte-order then flip to network byte order.
        const host_order: u32 = (@as(u32, parts[0]) << 24) | (@as(u32, parts[1]) << 16) |
                                 (@as(u32, parts[2]) << 8)  |  @as(u32, parts[3]);
        return std.mem.nativeToBig(u32, host_order);
    }

    // Threading
    // THE INTERNAL WRAPPER
    // This runs INSIDE the new thread. It handles the boilerplate.
    fn threadWrapper(allocator: std.mem.Allocator, frame_size: usize, global_ctx: *EbrContext, comptime func: anytype, args: anytype) !void {
        // 1. BOILERPLATE: Setup Runtime
        var rt = try Runtime.init(allocator, frame_size, global_ctx);
        defer rt.deinit();

        rt.wireAllocator();

        // IMPORTANT: Register this thread with the global context now that `rt` is stable on the frame.
        try global_ctx.register(allocator, rt.ebr);

        // This runs FIRST (before deinit): Remove from global registry
        // so the GC doesn't try to look at our dead frame.
        defer global_ctx.unregister(rt.ebr);

        // 2. MAGIC: Call the user function
        // We assume your worker functions always take 'rt' as the first argument.
        // We use '++' to concatenate the Runtime pointer with the user's arguments.
        const type_info = @typeInfo(@TypeOf(func));
        if (type_info == .@"fn" or type_info == .Fn) {
            try @call(.auto, func, .{&rt} ++ args);
        }
    }

    /// Distribute a fiber to the least-loaded scheduler (default for BG/DO blocks).
    /// Fully lock-free: pickTwo is 1 fetchAdd + 2 atomic loads (O(1), wait-free).
    /// Fallback: if registry is empty (test contexts), uses active_scheduler.
    pub fn spawnBest(trampoline_addr: usize, user_fn: TaskFn, args: ?*anyopaque, config: fp.TaskConfig) !void {
        const pair = fp.global_registry.pickTwo();
        const a = pair.a orelse {
            // Registry empty (unit-test context) — fall back to threadlocal scheduler.
            if (fp.scheduler_running) {
                try fp.active_scheduler.submitSpawn(trampoline_addr, user_fn, args, config);
                return;
            }
            return error.NoSchedulerAvailable;
        };
        const b = pair.b orelse {
            // Single scheduler — direct submit, zero overhead.
            try a.submitSpawn(trampoline_addr, user_fn, args, config);
            return;
        };
        // Power-of-Two Choices: compare load, pick lighter.
        const la = a.active_tasks.load(.monotonic);
        const lb = b.active_tasks.load(.monotonic);
        const target = if (la <= lb) a else b;
        try target.submitSpawn(trampoline_addr, user_fn, args, config);
    }

    // TODO: When does this get cleaned up?
    pub fn spawnThread(sys_allocator: std.mem.Allocator, frame_size: usize, global_ctx: *EbrContext, comptime func: anytype, args: anytype) !std.Thread {
        // We don't call 'func' directly. We call the wrapper.
        // We pass the config + the function + the args TO the wrapper.
        return std.Thread.spawn(.{}, threadWrapper, .{ sys_allocator, frame_size, global_ctx, func, args });
    }

    // Helper to wrap arbitrary arguments into a Context Pointer
    pub fn wrapArgs(allocator: std.mem.Allocator, args: anytype) !*anyopaque {
        const ArgsType = @TypeOf(args);
        const ptr = try allocator.create(ArgsType);
        ptr.* = args;
        return ptr;
    }

    // Polymorphic free: TODO: do this in the transpiler
    pub fn free(rt: *Runtime, item: anytype) void {
        const T = @TypeOf(item);

        switch (@typeInfo(T)) {
            // Case 1: Structs (check for deinit, e.g. ArrayListUnmanaged)
            .@"struct" => {
                // Special case: StringHashMapUnmanaged - free duplicated keys first
                if (@hasDecl(T, "iterator") and @hasField(T, "metadata")) {
                    var mut_item = item;
                    var it = mut_item.iterator();
                    while (it.next()) |entry| {
                        rt.heapAlloc().free(entry.key_ptr.*);
                    }
                    mut_item.deinit(rt.heapAlloc());
                } else if (@hasDecl(T, "deinit")) {
                    var mut_item = item;
                    mut_item.deinit(rt.heapAlloc());
                }
            },
            // Case 2: Pointers
            .pointer => |ptr_info| {
                switch (ptr_info.size) {
                    // Case 2a: Slices ([]const u8)
                    // Frame-allocated slices (e.g. from socketRead) live inside
                    // the frame arena's static_block and are freed in bulk by
                    // restoreLoopMark / restoreFrameMark — individual free is
                    // a no-op for them.  Heap-allocated slices (string concat
                    // results, etc.) live outside the static_block and must be
                    // freed via the GPA.
                    .slice => {
                        const frame_mem = rt.overflow_arena.static_block;
                        const p = @intFromPtr(item.ptr);
                        const frame_base = @intFromPtr(frame_mem.ptr);
                        if (p >= frame_base and p < frame_base + frame_mem.len) {
                            // Frame-allocated — freed by arena rewind, not here.
                        } else {
                            rt.heapAlloc().free(item);
                        }
                    },
                    // Case 2b: Single Items (*User)
                    .one => {
                        rt.heapAlloc().destroy(item);
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    // -------------------------------------------------------------------------
    // Reference Counting (multiowned / Rc)
    // -------------------------------------------------------------------------

    // -------------------------------------------------------------------------
    // Reference Counting with Control Block (supports weak references)
    // -------------------------------------------------------------------------
    // Both Rc and Arc use a control block that holds strong + weak counts
    // alongside the data pointer. This enables WeakRc/WeakArc to check if
    // the value is still alive without holding a strong reference.

    pub fn RcControlBlock(comptime T: type) type {
        return struct {
            strong: usize,
            weak: usize,
            data: *T,
            alloc: std.mem.Allocator,
        };
    }

    /// Rc(T): a reference-counted wrapper around a heap-allocated T.
    /// Uses a control block shared with WeakRc for weak reference support.
    pub fn Rc(comptime T: type) type {
        return struct {
            const Self = @This();
            ctrl: *RcControlBlock(T),
            // Convenience: access data through .data for compatibility
            pub fn getData(self: Self) *T { return self.ctrl.data; }
        };
    }

    pub fn rcCreate(comptime T: type, alloc: std.mem.Allocator, data: T) !Rc(T) {
        const alloc_profile = @import("alloc-profile.zig");
        const ctrl = try alloc.create(RcControlBlock(T));
        const data_ptr = try alloc.create(T);
        data_ptr.* = data;
        ctrl.* = .{ .strong = 1, .weak = 0, .data = data_ptr, .alloc = alloc };
        alloc_profile.recordAlloc(@returnAddress(), @sizeOf(RcControlBlock(T)) + @sizeOf(T));
        return Rc(T){ .ctrl = ctrl };
    }

    pub fn Frozen(comptime T: type) type {
        return freeze_mod.Frozen(T);
    }

    pub fn freeze(comptime T: type, alloc: std.mem.Allocator, val: *const T) freeze_mod.FreezeError!freeze_mod.Frozen(T) {
        return freeze_mod.freeze(T, alloc, val);
    }

    pub fn rcRetain(comptime T: type, rc: Rc(T)) Rc(T) {
        rc.ctrl.strong += 1;
        return rc;
    }

    pub fn splitRetain(comptime T: type, stream: T) T {
        return stream.retain();
    }

    pub fn rcRelease(comptime T: type, alloc: std.mem.Allocator, rc: Rc(T)) void {
        _ = alloc; // alloc stored in control block
        rc.ctrl.strong -= 1;
        if (rc.ctrl.strong == 0) {
            rc.ctrl.alloc.destroy(rc.ctrl.data);
            if (rc.ctrl.weak == 0) {
                rc.ctrl.alloc.destroy(rc.ctrl);
            }
        }
    }

    // -------------------------------------------------------------------------
    // Atomic Reference Counting with Control Block (shared / Arc)
    // -------------------------------------------------------------------------

    pub fn ArcControlBlock(comptime T: type) type {
        return struct {
            strong: std.atomic.Value(usize),
            weak: std.atomic.Value(usize),
            data: *T,
            alloc: std.mem.Allocator,
        };
    }

    /// Arc(T): an atomically reference-counted wrapper around a heap-allocated T.
    /// Uses a control block shared with WeakArc for weak reference support.
    pub fn Arc(comptime T: type) type {
        return struct {
            const Self = @This();
            ctrl: *ArcControlBlock(T),
            pub fn getData(self: Self) *T { return self.ctrl.data; }
        };
    }

    /// MVCC L7.3: comptime resolver used by WITH MATCH per-arm dispatch.
    /// Given the param type seen at the call site, peel off any
    /// outer pointer (`*T` -> T) and then any outer Arc-wrapper
    /// (`Arc(X)` -> X) to reach the underlying cell type. Used so the
    /// per-family probes (`@hasDecl(_, "Inner")` for Versioned,
    /// `@hasField(_, "mutex")` for Locked) work uniformly across:
    ///   - bare `*Versioned(T)` / `*Locked(T)` (versionedCreate /
    ///     lockedCreate return *T, so the param arrives as *T),
    ///   - `Arc(Versioned(T))` / `Arc(Locked(T))` by value (Arc is
    ///     a small handle, passed without pointer indirection).
    /// All branches are comptime-elided when not taken so the
    /// expression is well-typed for every shape.
    pub fn WithMatchInner(comptime ValT: type) type {
        const Underlying = if (@typeInfo(ValT) == .pointer)
            @typeInfo(ValT).pointer.child
        else
            ValT;
        if (@hasField(Underlying, "ctrl")) {
            const CtrlPtr = std.meta.fieldInfo(Underlying, .ctrl).type;
            const Ctrl = @typeInfo(CtrlPtr).pointer.child;
            const DataPtr = std.meta.fieldInfo(Ctrl, .data).type;
            return @typeInfo(DataPtr).pointer.child;
        }
        return Underlying;
    }

    pub fn arcCreate(comptime T: type, alloc: std.mem.Allocator, data: T) !Arc(T) {
        const ctrl = try alloc.create(ArcControlBlock(T));
        const data_ptr = try alloc.create(T);
        data_ptr.* = data;
        ctrl.* = .{
            .strong = std.atomic.Value(usize).init(1),
            .weak = std.atomic.Value(usize).init(0),
            .data = data_ptr,
            .alloc = alloc,
        };
        return Arc(T){ .ctrl = ctrl };
    }

    pub fn arcRetain(comptime T: type, arc: Arc(T)) Arc(T) {
        _ = arc.ctrl.strong.fetchAdd(1, .acquire);
        return arc;
    }

    pub fn arcRelease(comptime T: type, alloc: std.mem.Allocator, arc: Arc(T)) void {
        _ = alloc;
        const prev = arc.ctrl.strong.fetchSub(1, .release);
        if (prev == 1) {
            _ = arc.ctrl.strong.load(.acquire);
            // Deinit inner data before freeing the pointer.
            // RwLocked/Locked wrap types that may own heap memory (StringMap keys, etc.).
            arcDeinitInner(T, arc.ctrl.alloc, arc.ctrl.data);
            arc.ctrl.alloc.destroy(arc.ctrl.data);
            if (arc.ctrl.weak.load(.acquire) == 0) {
                arc.ctrl.alloc.destroy(arc.ctrl);
            }
        }
    }

    /// Recursively deinit inner data for Arc-wrapped types.
    /// Handles RwLocked(StringMap), Locked(StringMap), and plain StringMap.
    fn arcDeinitInner(comptime T: type, a: std.mem.Allocator, ptr: *T) void {
        // RwLocked(U) or Locked(U): deinit the inner .data field
        if (@hasField(T, "data") and @hasField(T, "lock")) {
            const DataT = @TypeOf(ptr.data);
            if (@hasDecl(DataT, "deinit")) {
                // StringMap.deinit takes (key_alloc, bucket_alloc) but uses self.alloc internally
                const deinit_fn = @typeInfo(@TypeOf(DataT.deinit)).@"fn";
                if (deinit_fn.params.len == 3) {
                    ptr.data.deinit(a, a);
                } else if (deinit_fn.params.len == 2) {
                    ptr.data.deinit(a);
                } else {
                    ptr.data.deinit();
                }
            }
        } else if (@hasDecl(T, "Inner") and @hasDecl(T, "deinitSync")) {
            // B1 fix (2026-04-30): Arc(Versioned(T)). Versioned re-exports
            // `Inner` (the wrapped T) and provides `deinitSync(allocator)`
            // for arc-cleanup contexts that lack a *Runtime. The 3-arg
            // `deinit(*Runtime, Allocator)` below would mis-pass
            // (Allocator, Allocator) here -- this branch routes around
            // that. See versioned.zig: deinitSync for the safety argument.
            ptr.deinitSync(a);
        } else if (@hasDecl(T, "deinit")) {
            const deinit_fn = @typeInfo(@TypeOf(T.deinit)).@"fn";
            if (deinit_fn.params.len == 3) {
                ptr.deinit(a, a);
            } else if (deinit_fn.params.len == 2) {
                ptr.deinit(a);
            } else {
                ptr.deinit();
            }
        }
    }

    // -------------------------------------------------------------------------
    // Weak References (link / WeakRc / WeakArc)
    // -------------------------------------------------------------------------

    pub fn WeakRc(comptime T: type) type {
        return struct {
            const Self = @This();
            ctrl: *RcControlBlock(T),
        };
    }

    pub fn rcDowngrade(comptime T: type, rc: Rc(T)) WeakRc(T) {
        rc.ctrl.weak += 1;
        return WeakRc(T){ .ctrl = rc.ctrl };
    }

    pub fn weakRcUpgrade(comptime T: type, weak: WeakRc(T)) ?Rc(T) {
        if (weak.ctrl.strong == 0) return null;
        weak.ctrl.strong += 1;
        return Rc(T){ .ctrl = weak.ctrl };
    }

    pub fn weakRcRelease(comptime T: type, weak: WeakRc(T)) void {
        weak.ctrl.weak -= 1;
        if (weak.ctrl.weak == 0 and weak.ctrl.strong == 0) {
            weak.ctrl.alloc.destroy(weak.ctrl);
        }
    }

    pub fn WeakArc(comptime T: type) type {
        return struct {
            const Self = @This();
            ctrl: *ArcControlBlock(T),
        };
    }

    pub fn arcDowngrade(comptime T: type, arc: Arc(T)) WeakArc(T) {
        _ = arc.ctrl.weak.fetchAdd(1, .acquire);
        return WeakArc(T){ .ctrl = arc.ctrl };
    }

    pub fn weakArcUpgrade(comptime T: type, weak: WeakArc(T)) ?Arc(T) {
        // CAS loop: atomically increment strong if > 0
        while (true) {
            const strong = weak.ctrl.strong.load(.acquire);
            if (strong == 0) return null;
            if (weak.ctrl.strong.cmpxchgWeak(strong, strong + 1, .acquire, .monotonic)) |_| {
                continue; // CAS failed, retry
            } else {
                return Arc(T){ .ctrl = weak.ctrl };
            }
        }
    }

    pub fn weakArcRelease(comptime T: type, weak: WeakArc(T)) void {
        const prev = weak.ctrl.weak.fetchSub(1, .release);
        if (prev == 1) {
            if (weak.ctrl.strong.load(.acquire) == 0) {
                weak.ctrl.alloc.destroy(weak.ctrl);
            }
        }
    }

    // -------------------------------------------------------------------------
    // Comptime Structural Helpers
    // -------------------------------------------------------------------------

    /// Extracts the inner type T from Rc(T), Arc(T), WeakRc(T), or WeakArc(T).
    /// Returns null if the type is not a recognized ref-counted wrapper.
    fn refInnerType(comptime FT: type) ?type {
        const info = @typeInfo(FT);
        if (info != .@"struct") return null;
        const fields = info.@"struct".fields;
        if (fields.len < 1) return null;
        if (!std.mem.eql(u8, fields[0].name, "ctrl")) return null;
        const ctrl_ptr_info = @typeInfo(fields[0].type);
        if (ctrl_ptr_info != .pointer) return null;
        const ctrl_info = @typeInfo(ctrl_ptr_info.pointer.child);
        if (ctrl_info != .@"struct") return null;
        inline for (ctrl_info.@"struct".fields) |cf| {
            if (comptime std.mem.eql(u8, cf.name, "data")) {
                const data_info = @typeInfo(cf.type);
                if (data_info == .pointer) return data_info.pointer.child;
            }
        }
        return null;
    }

    /// Returns true if FT is an Arc(T) or WeakArc(T) — the control block
    /// uses atomic ref counts (strong field is not a plain integer).
    fn isAtomicRef(comptime FT: type) bool {
        const info = @typeInfo(FT);
        if (info != .@"struct") return false;
        const fields = info.@"struct".fields;
        if (fields.len < 1) return false;
        if (!comptime std.mem.eql(u8, fields[0].name, "ctrl")) return false;
        const ctrl_ptr_info = @typeInfo(fields[0].type);
        if (ctrl_ptr_info != .pointer) return false;
        const ctrl_info = @typeInfo(ctrl_ptr_info.pointer.child);
        if (ctrl_info != .@"struct") return false;
        inline for (ctrl_info.@"struct".fields) |cf| {
            if (comptime std.mem.eql(u8, cf.name, "strong")) {
                return @typeInfo(cf.type) != .int;
            }
        }
        return false;
    }

    /// Returns true if FT is a WeakRc(T) or WeakArc(T).
    /// Weak types have no `getData` decl (only strong Rc/Arc do).
    fn isWeakRef(comptime FT: type) bool {
        if (refInnerType(FT) == null) return false;
        return !@hasDecl(FT, "getData");
    }

    /// Release a single ref-counted value. Dispatches to the correct release
    /// function based on the comptime type (Rc/Arc/WeakRc/WeakArc).
    pub fn releaseOne(comptime FT: type, alloc: std.mem.Allocator, value: FT) void {
        const T = comptime refInnerType(FT) orelse return;
        const is_weak = comptime isWeakRef(FT);
        const is_atomic = comptime isAtomicRef(FT);
        if (is_weak) {
            if (is_atomic) {
                weakArcRelease(T, .{ .ctrl = @ptrCast(value.ctrl) });
            } else {
                weakRcRelease(T, .{ .ctrl = @ptrCast(value.ctrl) });
            }
        } else {
            if (is_atomic) {
                arcRelease(T, alloc, .{ .ctrl = @ptrCast(value.ctrl) });
            } else {
                rcRelease(T, alloc, .{ .ctrl = @ptrCast(value.ctrl) });
            }
        }
    }

    /// Walk all fields of struct T and release any that are ref-counted
    /// (Rc, Arc, WeakRc, WeakArc). Zero-cost: fields without ref-counted
    /// types emit no code thanks to comptime dead-code elimination.
    pub fn releaseFields(comptime T: type, alloc: std.mem.Allocator, value: T) void {
        inline for (@typeInfo(T).@"struct".fields) |field| {
            if (comptime refInnerType(field.type) != null) {
                releaseOne(field.type, alloc, @field(value, field.name));
            }
        }
    }

    // -------------------------------------------------------------------------
    // Unified comptime cleanup — replaces per-type Ruby emit_cleanup logic.
    // The transpiler emits `defer CheatLib.cleanup(T, alloc, &x);` for every
    // variable that needs cleanup. Zig comptime eliminates no-op branches,
    // so primitives and copy types emit zero code.
    // -------------------------------------------------------------------------

    /// Returns true if T is a StringMap(V) wrapper (has inner + alloc + put).
    fn isStringMap(comptime T: type) bool {
        const info = @typeInfo(T);
        if (info != .@"struct") return false;
        return @hasField(T, "inner") and @hasField(T, "alloc") and @hasDecl(T, "put");
    }

    /// Returns true if T is a numeric map (AutoHashMapUnmanaged or similar).
    /// Detected by: struct with metadata field and deinit, but not a StringMap.
    fn isNumericMap(comptime T: type) bool {
        const info = @typeInfo(T);
        if (info != .@"struct") return false;
        if (isStringMap(T)) return false;
        return @hasField(T, "metadata") and @hasDecl(T, "deinit");
    }

    /// Returns true if T is a Pool(U) — has slots, free_stack, free_top, capacity.
    fn isPool(comptime T: type) bool {
        const info = @typeInfo(T);
        if (info != .@"struct") return false;
        return @hasField(T, "slots") and @hasField(T, "free_stack") and
               @hasField(T, "free_top") and @hasField(T, "capacity");
    }

    /// Returns true if T is a Set(U) — has inner field and is not a StringMap.
    fn isSetType(comptime T: type) bool {
        const info = @typeInfo(T);
        if (info != .@"struct") return false;
        if (!@hasField(T, "inner")) return false;
        if (isStringMap(T)) return false;
        // Set has insert/remove/contains but no alloc field
        return @hasDecl(T, "insert") and !@hasField(T, "alloc");
    }

    /// Returns true if T is a Locked(U) — has mutex + data fields.
    fn isLocked(comptime T: type) bool {
        const info = @typeInfo(T);
        if (info != .@"struct") return false;
        return @hasField(T, "mutex") and @hasField(T, "data") and !@hasField(T, "lock");
    }

    /// Returns true if T is a RwLocked(U) — has lock (RwLock) + data fields.
    fn isRwLocked(comptime T: type) bool {
        const info = @typeInfo(T);
        if (info != .@"struct") return false;
        return @hasField(T, "lock") and @hasField(T, "data") and !@hasField(T, "mutex");
    }

    /// True-Sync-Polymorphism Gate 3 — comptime-dispatched mutate that
    /// admits every sync family CLEAR supports through one call site.
    /// Used by `WITH POLYMORPHIC c AS x { body }` when the parameter has
    /// no narrow REQUIRES (universal polymorphism).
    ///
    /// Caller provides:
    ///   - cell: the binding (Counter / Arc(Locked(Counter)) / ...).
    ///     Pointer-typed forms (e.g. *Counter from @local) are passed
    ///     through; value-typed forms get an `&cell` address-of inside.
    ///   - rt:   runtime pointer (needed by Versioned / AtomicPtr update).
    ///   - body: a struct fn `fn run(x: *T, ...args) void` (or `!void`)
    ///     that mutates *x. Lifted out of the WITH body by the lowering
    ///     so the closure is a no-capture standalone function.
    ///   - args: tuple of additional captures (currently unused; reserved
    ///     for future bodies that need outer-local writes via `*r_out`).
    ///
    /// Dispatch (comptime; only one branch survives per call site):
    ///   - has `update` -> Versioned / AtomicPtr (CAS-retry write)
    ///   - has `write`  -> RwLocked (write-side acquire)
    ///   - has `acquire` -> Locked (mutex acquire)
    ///   - else         -> plain `*T` (direct call)
    pub fn polymorphicMutate(
        cell_ptr_or_val: anytype,
        rt: *Runtime,
        comptime body: anytype,
        args: anytype,
    ) !void {
        const T = @TypeOf(cell_ptr_or_val);
        // Comptime arc-unwrap. End state: `inner` is a `*Inner` where
        // Inner is the post-Arc payload (Locked / Versioned / AtomicPtr
        // / plain T). The Arc shape stores `data: *T` already, so for
        // an Arc-wrapped param we forward `cell.ctrl.data` directly --
        // taking another `&` would yield `**T` which @hasDecl can't
        // probe.
        if (comptime @typeInfo(T) == .pointer) {
            const Child = @typeInfo(T).pointer.child;
            if (comptime @typeInfo(Child) == .@"struct" and @hasField(Child, "ctrl")) {
                return polymorphicMutateInner(cell_ptr_or_val.ctrl.data, rt, body, args);
            }
            if (comptime @typeInfo(Child) == .pointer) {
                const GrandChild = @typeInfo(Child).pointer.child;
                if (comptime @typeInfo(GrandChild) == .@"struct" and @hasField(GrandChild, "ctrl")) {
                    return polymorphicMutateInner(cell_ptr_or_val.*.ctrl.data, rt, body, args);
                }
                return polymorphicMutateInner(cell_ptr_or_val.*, rt, body, args);
            }
            return polymorphicMutateInner(cell_ptr_or_val, rt, body, args);
        }
        if (comptime @typeInfo(T) == .@"struct" and @hasField(T, "ctrl")) {
            return polymorphicMutateInner(cell_ptr_or_val.ctrl.data, rt, body, args);
        }
        // Plain T by value: take address of the formal parameter copy.
        // Mutation through this pointer affects only the local copy --
        // pass-by-value plain T cannot flow updates back to the caller.
        return polymorphicMutateInner(&cell_ptr_or_val, rt, body, args);
    }

    /// Inner half of polymorphicMutate -- takes a *Inner directly so
    /// the outer wrapper's comptime arc-unwrap can compose naturally
    /// without duplicating the dispatch in every branch.
    inline fn polymorphicMutateInner(
        inner: anytype,
        rt: *Runtime,
        comptime body: anytype,
        args: anytype,
    ) !void {
        const Inner = @TypeOf(inner.*);
        if (comptime @hasDecl(Inner, "update")) {
            // Versioned or AtomicPtr -- both expose the same shape:
            //   `.update(rt, alloc, comptime fn, args)`.
            try inner.update(rt, rt.heapAlloc(), body, args);
        } else if (comptime @hasDecl(Inner, "write")) {
            var g = inner.write();
            defer g.release();
            @call(.auto, body, .{g.get()} ++ args);
        } else if (comptime @hasDecl(Inner, "acquire")) {
            var g = inner.acquire();
            defer g.release();
            @call(.auto, body, .{g.get()} ++ args);
        } else {
            @call(.auto, body, .{inner} ++ args);
        }
    }

    pub fn polymorphicMutateFlow(
        cell_ptr_or_val: anytype,
        rt: *Runtime,
        comptime body: anytype,
        args: anytype,
    ) !void {
        const T = @TypeOf(cell_ptr_or_val);
        if (comptime @typeInfo(T) == .pointer) {
            const Child = @typeInfo(T).pointer.child;
            if (comptime @typeInfo(Child) == .@"struct" and @hasField(Child, "ctrl")) {
                return polymorphicMutateFlowInner(cell_ptr_or_val.ctrl.data, rt, body, args);
            }
            if (comptime @typeInfo(Child) == .pointer) {
                const GrandChild = @typeInfo(Child).pointer.child;
                if (comptime @typeInfo(GrandChild) == .@"struct" and @hasField(GrandChild, "ctrl")) {
                    return polymorphicMutateFlowInner(cell_ptr_or_val.*.ctrl.data, rt, body, args);
                }
                return polymorphicMutateFlowInner(cell_ptr_or_val.*, rt, body, args);
            }
            return polymorphicMutateFlowInner(cell_ptr_or_val, rt, body, args);
        }
        if (comptime @typeInfo(T) == .@"struct" and @hasField(T, "ctrl")) {
            return polymorphicMutateFlowInner(cell_ptr_or_val.ctrl.data, rt, body, args);
        }
        return polymorphicMutateFlowInner(&cell_ptr_or_val, rt, body, args);
    }

    inline fn polymorphicMutateFlowInner(
        inner: anytype,
        rt: *Runtime,
        comptime body: anytype,
        args: anytype,
    ) !void {
        const Inner = @TypeOf(inner.*);
        if (comptime @hasDecl(Inner, "updateFlow")) {
            try inner.updateFlow(rt, rt.heapAlloc(), body, args);
        } else if (comptime @hasDecl(Inner, "write")) {
            var g = inner.write();
            defer g.release();
            @call(.auto, body, .{g.get()} ++ args);
        } else if (comptime @hasDecl(Inner, "acquire")) {
            var g = inner.acquire();
            defer g.release();
            @call(.auto, body, .{g.get()} ++ args);
        } else {
            @call(.auto, body, .{inner} ++ args);
        }
    }

    /// Unified comptime cleanup for any CLEAR type.
    /// Dispatches to the correct cleanup function based on structural type analysis.
    /// For types that need no cleanup (primitives, enums, plain structs without RC fields),
    /// comptime eliminates the entire function body — zero runtime cost.
    pub fn cleanup(comptime T: type, alloc: std.mem.Allocator, cptr: *const T) void {
        const ptr = @constCast(cptr);

        // 0. Strings: free with the provided allocator. Frame-arena free is
        // a no-op, so frame strings are safe. Heap strings are freed.
        if (T == []const u8 or T == []u8) {
            if (ptr.len > 0) alloc.free(ptr.*);
            return;
        }

        // 1. Ref-counted types: Rc(U), Arc(U), WeakRc(U), WeakArc(U)
        if (comptime refInnerType(T) != null) {
            releaseOne(T, alloc, ptr.*);
            return;
        }

        // Atomics M2.2: bare pointer-to-Atomic(U). After dropping the
        // Arc wrap from `@shared:atomic`, the binding holds a heap-
        // allocated `*Atomic(U)` returned by atomicCreate. Cleanup
        // is just `alloc.destroy(ptr.*)`. Detected at comptime via
        // the pointer-to-struct-with-`cmpxchgStrong`-decl shape; the
        // three Atomic primitives (AtomicInt / AtomicFloat /
        // AtomicBool) all expose that.
        if (comptime blk: {
            const ti = @typeInfo(T);
            if (ti != .pointer or ti.pointer.size != .one) break :blk false;
            const child = ti.pointer.child;
            if (@typeInfo(child) != .@"struct") break :blk false;
            break :blk @hasDecl(child, "cmpxchgStrong");
        }) {
            alloc.destroy(ptr.*);
            return;
        }

        // AtomicPtr M3.5: pointer-to-AtomicPtr(U) cell. The cell owns
        // the currently-published `*U` (allocated by atomicPtrCreate /
        // updates via Self.update); cleanup must (a) recursively
        // clean the inner U's owned heap fields (strings, slices,
        // nested unions, ...) via the same generic `cleanup()` shim,
        // (b) destroy the inner *U, (c) destroy the AtomicPtr cell.
        //
        // The runtime EBR retire path (`AtomicPtr.deinit`) needs a
        // `*ThreadLocalEbr` to defer the inner free; cleanup() runs
        // without one (no `rt` argument), so we use the sync
        // teardown path: by the time scope-end cleanup fires, every
        // reader's WITH SNAPSHOT alias has released its Guard
        // (CLEAR's non_escaping checker guarantees no Guard
        // outlives its WITH), so the sync `destroy` is safe.
        if (comptime blk: {
            const ti = @typeInfo(T);
            if (ti != .pointer or ti.pointer.size != .one) break :blk false;
            const child = ti.pointer.child;
            if (@typeInfo(child) != .@"struct") break :blk false;
            break :blk @hasDecl(child, "compareAndPublish");
        }) {
            const Cell = @typeInfo(T).pointer.child;
            const InnerT = Cell.Inner;
            // Swap to null so we own the inner pointer; cleanup
            // recursively (handles String fields and nested heaps)
            // before destroying.
            const inner_ptr = ptr.*.ptr.swap(null, .acq_rel);
            if (inner_ptr) |ip| {
                cleanup(InnerT, alloc, ip);
                alloc.destroy(ip);
            }
            alloc.destroy(ptr.*);
            return;
        }

        // 2. ArrayList (list collections)
        if (comptime isArrayList(T)) {
            const ElemT = comptime arrayListElemType(T).?;
            // Recursively cleanup elements (RC release, string free, nested unions, etc.)
            if (comptime needsCleanup(ElemT)) {
                for (ptr.items) |*item| {
                    cleanup(ElemT, alloc, item);
                }
            }
            ptr.deinit(alloc);
            return;
        }

        // 2b. Slices: recursively cleanup elements then free the buffer.
        // The compiler guarantees cleanup is only called on owned slices
        // (COPY results, TAKES params) via _moved guards.
        if (comptime blk: {
            const ti = @typeInfo(T);
            break :blk ti == .pointer and ti.pointer.size == .slice and T != []const u8 and T != []u8;
        }) {
            const ElemT = @typeInfo(T).pointer.child;
            if (comptime needsCleanup(ElemT)) {
                for (ptr.*) |*elem| {
                    cleanup(ElemT, alloc, elem);
                }
            }
            if (ptr.len > 0) alloc.free(ptr.*);
            return;
        }

        // 3. StringMap(V) — string-keyed hashmap wrapper
        if (comptime isStringMap(T)) {
            ptr.deinit(alloc, alloc);
            return;
        }

        // 4. Numeric map (AutoHashMapUnmanaged or custom hash)
        if (comptime isNumericMap(T)) {
            // Extract V from the pub ValueIterator type: its `items` field is [*]V
            const ElemT = comptime blk: {
                for (@typeInfo(T.ValueIterator).@"struct".fields) |f| {
                    if (std.mem.eql(u8, f.name, "items")) {
                        break :blk @typeInfo(f.type).pointer.child;
                    }
                }
                unreachable;
            };
            if (comptime needsCleanup(ElemT)) {
                var vit = ptr.valueIterator();
                while (vit.next()) |val_ptr| cleanup(ElemT, alloc, val_ptr);
            }
            ptr.deinit(alloc);
            return;
        }

        // 5. Pool(U)
        if (comptime isPool(T)) {
            ptr.deinit(alloc);
            return;
        }

        // 6. Set(U)
        if (comptime isSetType(T)) {
            // Release ref-counted elements
            const InnerMap = @TypeOf(ptr.inner);
            const inner_info = @typeInfo(InnerMap);
            if (inner_info == .@"struct") {
                // Iterate keys to release RC elements or free duped strings
                var it = ptr.inner.keyIterator();
                while (it.next()) |key_ptr| {
                    const KeyT = @TypeOf(key_ptr.*);
                    if (comptime refInnerType(KeyT) != null) {
                        releaseOne(KeyT, alloc, key_ptr.*);
                    } else if (KeyT == []const u8) {
                        alloc.free(key_ptr.*);
                    }
                }
            }
            ptr.inner.deinit(alloc);
            return;
        }

        // 7. Locked(U) / RwLocked(U)
        if (comptime isLocked(T)) {
            alloc.destroy(@as(*align(@alignOf(T)) T, @alignCast(ptr)));
            return;
        }
        if (comptime isRwLocked(T)) {
            alloc.destroy(@as(*align(@alignOf(T)) T, @alignCast(ptr)));
            return;
        }

        // 8. Structs with a deinit method (ShardedList, ShardedMap, etc.)
        //    Detect deinit arity: 1 alloc (ShardedList) vs 2 allocs (ShardedMap).
        if (@typeInfo(T) == .@"struct" and @hasDecl(T, "deinit") and
            !isStringMap(T) and !isPool(T) and !isNumericMap(T))
        {
            const deinit_info = @typeInfo(@TypeOf(T.deinit));
            const param_count = deinit_info.@"fn".params.len;
            if (param_count == 3) {
                // deinit(self, key_alloc, bucket_alloc)
                ptr.deinit(alloc, alloc);
            } else if (param_count == 2) {
                // deinit(self, alloc)
                ptr.deinit(alloc);
            } else {
                // deinit(self) - no allocator needed
                ptr.deinit();
            }
            return;
        }

        // 9. Structs: recursively clean up all owned fields
        const info = @typeInfo(T);
        if (info == .@"struct") {
            inline for (info.@"struct".fields) |field| {
                const FT = field.type;
                const f_info = @typeInfo(FT);
                // Skip opaque types and function pointers (Zig stdlib internals)
                if (f_info == .@"opaque" or f_info == .@"fn") continue;
                if (comptime refInnerType(FT) != null) {
                    releaseOne(FT, alloc, @field(ptr, field.name));
                } else if (f_info == .pointer and f_info.pointer.size == .slice) {
                    const payload = @field(ptr, field.name);
                    if (FT == []const u8 or FT == []u8) {
                        if (payload.len > 0) alloc.free(payload);
                    } else {
                        if (comptime needsCleanup(f_info.pointer.child)) {
                            for (payload) |*elem| {
                                cleanup(f_info.pointer.child, alloc, elem);
                            }
                        }
                        if (payload.len > 0) alloc.free(payload);
                    }
                } else if (f_info == .pointer and f_info.pointer.size == .one and @typeInfo(f_info.pointer.child) != .@"opaque" and @typeInfo(f_info.pointer.child) != .@"fn") {
                    // Single pointer (*T): cleanup the pointee then free the pointer.
                    // This handles @indirect fields in inline struct union variants.
                    const pointee = @field(ptr, field.name);
                    const ChildT = f_info.pointer.child;
                    if (comptime needsCleanup(ChildT)) {
                        cleanup(ChildT, alloc, pointee);
                    }
                    alloc.destroy(pointee);
                } else if (comptime needsCleanup(FT)) {
                    cleanup(FT, alloc, &@field(ptr, field.name));
                }
            }
            return;
        }

        // 9. Tagged unions: check active variant and clean up its payload.
        if (info == .@"union" and info.@"union".tag_type != null) {
            inline for (info.@"union".fields) |field| {
                if (std.meta.activeTag(ptr.*) == @field(std.meta.Tag(T), field.name)) {
                    const FT = field.type;
                    const f_info = @typeInfo(FT);
                    // Slice variant ([]T): recursively cleanup elements then free buffer.
                    if (f_info == .pointer and f_info.pointer.size == .slice) {
                        if (FT == []const u8 or FT == []u8) {
                            const str = @field(ptr, field.name);
                            if (str.len > 0) alloc.free(str);
                        } else {
                            const payload = @field(ptr, field.name);
                            if (comptime needsCleanup(f_info.pointer.child)) {
                                for (payload) |*elem| {
                                    cleanup(f_info.pointer.child, alloc, elem);
                                }
                            }
                            if (payload.len > 0) alloc.free(payload);
                        }
                    } else if (f_info == .pointer and f_info.pointer.size == .one and
                        @typeInfo(f_info.pointer.child) != .@"opaque" and @typeInfo(f_info.pointer.child) != .@"fn")
                    {
                        // Single pointer (*T): cleanup pointee then free pointer.
                        const pointee = @field(ptr, field.name);
                        const ChildT = f_info.pointer.child;
                        if (comptime needsCleanup(ChildT)) {
                            cleanup(ChildT, alloc, pointee);
                        }
                        alloc.destroy(pointee);
                    } else if (comptime needsCleanup(FT)) {
                        cleanup(FT, alloc, &@field(ptr, field.name));
                    }
                    return;
                }
            }
            return;
        }

        // Primitives, enums, untagged unions: no-op (comptime-eliminated)
    }

    pub fn dupeValue(comptime T: type, value: T, alloc: std.mem.Allocator) std.mem.Allocator.Error!T {
        const info = @typeInfo(T);

        if (T == []const u8) {
            return if (value.len > 0) try alloc.dupe(u8, value) else value;
        }
        if (T == []u8) {
            return if (value.len > 0) try alloc.dupe(u8, value) else value;
        }

        if (info == .@"union" and info.@"union".tag_type != null) {
            return dupeUnionValue(T, value, alloc);
        }

        if (info == .pointer and info.pointer.size == .slice) {
            const ElemT = info.pointer.child;
            var buf = try alloc.alloc(ElemT, value.len);
            errdefer alloc.free(buf);
            if (comptime needsCleanup(ElemT)) {
                for (value, 0..) |elem, i| {
                    buf[i] = try dupeValue(ElemT, elem, alloc);
                }
            } else {
                @memcpy(buf, value);
            }
            return buf;
        }

        if (info == .pointer and info.pointer.size == .one and
            @typeInfo(info.pointer.child) != .@"opaque" and @typeInfo(info.pointer.child) != .@"fn")
        {
            const ChildT = info.pointer.child;
            const new_ptr = try alloc.create(ChildT);
            errdefer alloc.destroy(new_ptr);
            new_ptr.* = try dupeValue(ChildT, value.*, alloc);
            return new_ptr;
        }

        if (info == .@"struct" and !@hasDecl(T, "deinit")) {
            var result = value;
            inline for (info.@"struct".fields) |field| {
                const FT = field.type;
                if (comptime needsCleanup(FT)) {
                    @field(result, field.name) = try dupeValue(FT, @field(value, field.name), alloc);
                }
            }
            return result;
        }

        // ArrayList: allocate a fresh buffer of the same length and deep-copy
        // each item (recursively if the element type needs cleanup, byte-copy
        // otherwise). Without this branch, dupeValue used to fall through to
        // `return value` for any type with a deinit method -- the caller got
        // a shallow ArrayList header pointing at the original's buffer, and
        // freeing one would dangling-pointer the other (the COPY @list bug
        // 258). Uses T's own initCapacity / appendAssumeCapacity so it works
        // for any std.ArrayListUnmanaged-shaped struct (the same shape
        // isArrayList accepts).
        if (comptime isArrayList(T)) {
            const ElemT = comptime arrayListElemType(T).?;
            var result = try T.initCapacity(alloc, value.items.len);
            errdefer result.deinit(alloc);
            if (comptime needsCleanup(ElemT)) {
                for (value.items) |elem| {
                    const duped = try dupeValue(ElemT, elem, alloc);
                    result.appendAssumeCapacity(duped);
                }
            } else {
                result.appendSliceAssumeCapacity(value.items);
            }
            return result;
        }

        return value;
    }

    /// Returns true if a type needs cleanup (has heap-allocated data).
    pub fn needsCleanup(comptime FT: type) bool {
        @setEvalBranchQuota(100000);
        if (FT == []const u8 or FT == []u8) return true;
        if (refInnerType(FT) != null) return true;
        if (isArrayList(FT)) return true;
        if (isStringMap(FT)) return true;
        if (isNumericMap(FT)) return true;
        if (isPool(FT)) return true;
        const ft_info = @typeInfo(FT);
        // Pointers and non-string slices trivially need cleanup (heap data).
        // Check BEFORE recursing to avoid exponential blowup on recursive types.
        if (ft_info == .pointer and ft_info.pointer.size == .one) return true;
        if (ft_info == .pointer and ft_info.pointer.size == .slice) return true;
        // Types with deinit manage their own lifecycle — don't recurse into fields.
        if (ft_info == .@"struct" and @hasDecl(FT, "deinit")) return true;
        if (ft_info == .@"struct") {
            inline for (ft_info.@"struct".fields) |field| {
                if (comptime needsCleanup(field.type)) return true;
            }
        }
        if (ft_info == .@"union" and ft_info.@"union".tag_type != null) {
            inline for (ft_info.@"union".fields) |field| {
                if (comptime needsCleanup(field.type)) return true;
            }
        }
        return false;
    }

    /// Promote all escapable fields of a struct from frame arena to heap.
    /// DEPRECATED: use promote() for new code. Kept for backward compat.
    /// Deep-copy a union value's heap-owning payload (strings, slices, struct fields).
    pub fn dupeUnionValue(comptime T: type, value: T, alloc: std.mem.Allocator) std.mem.Allocator.Error!T {
        const info = @typeInfo(T);
        if (info != .@"union" or info.@"union".tag_type == null) return value;
        var result = value;
        inline for (info.@"union".fields) |field| {
            if (std.meta.activeTag(value) == @field(std.meta.Tag(T), field.name)) {
                const FT = field.type;
                const ft_info = @typeInfo(FT);
                if (FT == []const u8) {
                    const src = @field(value, field.name);
                    @field(result, field.name) = if (src.len > 0) try alloc.dupe(u8, src) else src;
                    return result;
                } else if (ft_info == .pointer and ft_info.pointer.size == .slice and FT != []u8) {
                    const src = @field(value, field.name);
                    if (src.len > 0) {
                        const ElemT = ft_info.pointer.child;
                        const buf = try alloc.alloc(ElemT, src.len);
                        for (src, 0..) |elem, i| {
                            buf[i] = try dupeUnionValue(ElemT, elem, alloc);
                        }
                        @field(result, field.name) = buf;
                    }
                    return result;
                } else if (ft_info == .pointer and ft_info.pointer.size == .one and
                    @typeInfo(ft_info.pointer.child) != .@"opaque" and @typeInfo(ft_info.pointer.child) != .@"fn")
                {
                    // Single pointer (*T): allocate new pointee and deep-copy.
                    // Handles @indirect fields in union variants.
                    const src_ptr = @field(value, field.name);
                    const ChildT = ft_info.pointer.child;
                    const new_ptr = try alloc.create(ChildT);
                    // Use dupeStructSlices for struct pointees (deep-copies string/slice fields).
                    // Use dupeUnionValue for union pointees.
                    if (@typeInfo(ChildT) == .@"struct")
                        new_ptr.* = try dupeStructSlices(ChildT, src_ptr.*, alloc)
                    else
                        new_ptr.* = try dupeUnionValue(ChildT, src_ptr.*, alloc);
                    @field(result, field.name) = new_ptr;
                    return result;
                } else if (ft_info == .@"struct") {
                    if (comptime isArrayList(FT)) {
                        // Deep copy ArrayList: allocate independent backing slice and dupe each element.
                        const ElemT = arrayListElemType(FT).?;
                        const src = @field(value, field.name);
                        if (src.items.len > 0) {
                            const new_buf = try alloc.alloc(ElemT, src.items.len);
                            for (src.items, 0..) |elem, ii| {
                                new_buf[ii] = try dupeUnionValue(ElemT, elem, alloc);
                            }
                            @field(result, field.name) = FT{ .items = new_buf, .capacity = new_buf.len };
                        }
                        return result;
                    } else if (comptime (!isStringMap(FT) and !isNumericMap(FT) and !isPool(FT) and
                        !(@hasField(FT, "inner") and @hasField(FT, "alloc") and @hasDecl(FT, "put"))))
                    {
                        @field(result, field.name) = try dupeStructSlices(FT, @field(value, field.name), alloc);
                        return result;
                    }
                }
                return value;
            }
        }
        return value;
    }

    /// Deep-copy slice and pointer fields inside a struct.
    fn dupeStructSlices(comptime T: type, value: T, alloc: std.mem.Allocator) std.mem.Allocator.Error!T {
        const info = @typeInfo(T);
        if (info != .@"struct") return value;
        var result = value;
        inline for (info.@"struct".fields) |field| {
            const FT = field.type;
            const ft_info = @typeInfo(FT);
            if (ft_info == .pointer and ft_info.pointer.size == .slice) {
                const src = @field(value, field.name);
                if (src.len > 0) {
                    const ElemT = ft_info.pointer.child;
                    if (FT == []const u8 or FT == []u8) {
                        @field(result, field.name) = try alloc.dupe(u8, src);
                    } else {
                        const buf = try alloc.alloc(ElemT, src.len);
                        for (src, 0..) |elem, i| {
                            buf[i] = try dupeUnionValue(ElemT, elem, alloc);
                        }
                        @field(result, field.name) = buf;
                    }
                }
            } else if (ft_info == .pointer and ft_info.pointer.size == .one) {
                const child_ptr = @field(value, field.name);
                const ChildT = ft_info.pointer.child;
                const new_ptr = try alloc.create(ChildT);
                new_ptr.* = try dupeUnionValue(ChildT, child_ptr.*, alloc);
                @field(result, field.name) = new_ptr;
            } else if (ft_info == .@"union" and ft_info.@"union".tag_type != null) {
                @field(result, field.name) = try dupeUnionValue(FT, @field(value, field.name), alloc);
            }
        }
        return result;
    }

    pub fn promoteFields(comptime T: type, rt: *Runtime, value: *T) !void {
        try promote(T, rt, value);
    }

    /// Deep promote: unconditionally dupe ALL strings (including heap).
    /// Used for HPT independence -- the source is about to be freed,
    /// so the returned copy must own its own data regardless of allocator.
    pub fn promoteDeep(comptime T: type, rt: *Runtime, value: *T) std.mem.Allocator.Error!void {
        const info = @typeInfo(T);

        if (T == []const u8 or T == []u8) {
            if (value.len == 0) return;
            value.* = try rt.heapAlloc().dupe(u8, value.*);
            return;
        }

        if (comptime isArrayList(T)) {
            const ElemT = comptime arrayListElemType(T).?;
            try promoteList(ElemT, rt, value);
            if (comptime needsPromotion(ElemT)) {
                for (value.items) |*elem| {
                    try promoteDeep(ElemT, rt, elem);
                }
            }
            return;
        }

        if (comptime isStringMap(T)) {
            value.alloc = rt.heapAlloc();
            return;
        }

        if (info == .@"union" and info.@"union".tag_type != null) {
            inline for (info.@"union".fields) |field| {
                if (comptime needsPromotion(field.type)) {
                    if (std.meta.activeTag(value.*) == @field(std.meta.Tag(T), field.name)) {
                        const FT = field.type;
                        const ft_info = @typeInfo(FT);
                        if (ft_info == .pointer and ft_info.pointer.size == .one and
                            @typeInfo(ft_info.pointer.child) != .@"opaque" and @typeInfo(ft_info.pointer.child) != .@"fn")
                        {
                            const ChildT = ft_info.pointer.child;
                            if (comptime needsPromotion(ChildT)) {
                                try promoteDeep(ChildT, rt, @field(value, field.name));
                            }
                        } else {
                            try promoteDeep(FT, rt, &@field(value, field.name));
                        }
                        return;
                    }
                }
            }
            return;
        }

        if (info == .@"struct") {
            inline for (info.@"struct".fields) |field| {
                const FT = field.type;
                const ft_info = @typeInfo(FT);
                if (ft_info == .pointer and ft_info.pointer.size == .one and
                    @typeInfo(ft_info.pointer.child) != .@"opaque" and @typeInfo(ft_info.pointer.child) != .@"fn")
                {
                    const ChildT = ft_info.pointer.child;
                    if (comptime needsPromotion(ChildT)) {
                        try promoteDeep(ChildT, rt, @field(value, field.name));
                    }
                } else if (comptime needsPromotion(FT)) {
                    try promoteDeep(FT, rt, &@field(value, field.name));
                }
            }
            return;
        }
    }

    /// Generic comptime promotion: walks any type and dupes all frame-arena
    /// data to heap. Handles strings, ArrayLists, StringMaps, structs, and
    /// tagged unions recursively. No-op for primitives (comptime eliminated).
    pub fn promote(comptime T: type, rt: *Runtime, value: *T) std.mem.Allocator.Error!void {
        const info = @typeInfo(T);

        // 1. Strings: dupe only frame-arena strings to heap.
        // Heap strings (from COPY, toString, etc.) are already escaped —
        // duping them again leaks the original.
        if (T == []const u8 or T == []u8) {
            if (value.len == 0) return;
            const frame_mem = rt.overflow_arena.static_block;
            const p = @intFromPtr(value.*.ptr);
            const frame_base = @intFromPtr(frame_mem.ptr);
            if (p >= frame_base and p < frame_base + frame_mem.len) {
                value.* = try rt.heapAlloc().dupe(u8, value.*);
            }
            return;
        }

        // 2. ArrayList: promote backing buffer + recurse into elements
        if (comptime isArrayList(T)) {
            const ElemT = comptime arrayListElemType(T).?;
            try promoteList(ElemT, rt, value);
            // Recursively promote elements if they contain escapable data
            if (comptime needsPromotion(ElemT)) {
                for (value.items) |*elem| {
                    try promote(ElemT, rt, elem);
                }
            }
            return;
        }

        // 3. StringMap: alloc is already heapAlloc (set at construction).
        // Ensure alloc field is heap. Keys and values are managed by StringMap.
        if (comptime isStringMap(T)) {
            value.alloc = rt.heapAlloc();
            return;
        }

        // 4. Tagged unions: promote the active variant's payload
        if (info == .@"union" and info.@"union".tag_type != null) {
            inline for (info.@"union".fields) |field| {
                if (comptime needsPromotion(field.type)) {
                    if (std.meta.activeTag(value.*) == @field(std.meta.Tag(T), field.name)) {
                        const FT = field.type;
                        const ft_info = @typeInfo(FT);
                        if (ft_info == .pointer and ft_info.pointer.size == .one and
                            @typeInfo(ft_info.pointer.child) != .@"opaque" and @typeInfo(ft_info.pointer.child) != .@"fn")
                        {
                            const ChildT = ft_info.pointer.child;
                            if (comptime needsPromotion(ChildT)) {
                                try promote(ChildT, rt, @field(value, field.name));
                            }
                        } else {
                            try promote(FT, rt, &@field(value, field.name));
                        }
                        return;
                    }
                }
            }
            return;
        }

        // 5. Structs: walk fields recursively
        if (info == .@"struct") {
            inline for (info.@"struct".fields) |field| {
                const FT = field.type;
                const ft_info = @typeInfo(FT);
                if (ft_info == .pointer and ft_info.pointer.size == .one and
                    @typeInfo(ft_info.pointer.child) != .@"opaque" and @typeInfo(ft_info.pointer.child) != .@"fn")
                {
                    // Single pointer (*T) from @indirect: promote the pointee.
                    const ChildT = ft_info.pointer.child;
                    if (comptime needsPromotion(ChildT)) {
                        try promote(ChildT, rt, @field(value, field.name));
                    }
                } else if (comptime needsPromotion(FT)) {
                    try promote(FT, rt, &@field(value, field.name));
                }
            }
            return;
        }

        // Primitives, enums, etc.: no-op (comptime-eliminated)
    }

    /// Returns true if a type has data that needs promotion (frame -> heap).
    fn needsPromotion(comptime FT: type) bool {
        if (FT == []const u8 or FT == []u8) return true;
        if (isArrayList(FT)) return true;
        if (isStringMap(FT)) return true;
        const ft_info = @typeInfo(FT);
        // Single pointer (*T) from @indirect: return true without recursing
        // to avoid infinite comptime recursion on self-referential types.
        if (ft_info == .pointer and ft_info.pointer.size == .one) return true;
        if (ft_info == .@"struct") {
            inline for (ft_info.@"struct".fields) |field| {
                if (comptime needsPromotion(field.type)) return true;
            }
        }
        if (ft_info == .@"union" and ft_info.@"union".tag_type != null) {
            inline for (ft_info.@"union".fields) |field| {
                if (comptime needsPromotion(field.type)) return true;
            }
        }
        return false;
    }

    fn isArrayList(comptime T: type) bool {
        return arrayListElemType(T) != null;
    }

    fn arrayListElemType(comptime T: type) ?type {
        const info = @typeInfo(T);
        if (info != .@"struct") return null;
        const fields = info.@"struct".fields;
        // ArrayListUnmanaged has `items` (slice) and `capacity` (usize)
        var has_items = false;
        var has_capacity = false;
        var elem_type: ?type = null;
        inline for (fields) |f| {
            if (comptime std.mem.eql(u8, f.name, "items")) {
                has_items = true;
                const slice_info = @typeInfo(f.type);
                if (slice_info == .pointer and slice_info.pointer.size == .slice) {
                    elem_type = slice_info.pointer.child;
                }
            }
            if (comptime std.mem.eql(u8, f.name, "capacity")) has_capacity = true;
        }
        if (has_items and has_capacity) return elem_type;
        return null;
    }

    pub fn assert(condition: bool, msg: []const u8) void {
        if (!condition) {
            std.debug.print("ASSERTION FAILED: {s}\n", .{msg});
            std.process.exit(1);
        }
    }

    pub fn ffi(rt: *Runtime, comptime f: anytype, args: anytype) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
        const F = @TypeOf(f);
        const type_info = @typeInfo(F);
        const ReturnType = type_info.@"fn".return_type.?;

        // Create a Function POINTER type based on the function's signature.
        // This is the key: we need the pointer type, not the function type.
        const PtrType = *const F;

        const Frame = struct {
            args: @TypeOf(args),
            ret: ReturnType,
            func_ptr: PtrType,
        };

        var frame = Frame{
            .args = args,
            .ret = undefined,
            .func_ptr = &f, // Take the address of the function constant
        };

        rt.onRootStack(struct {
            fn wrapper(ptr: ?*anyopaque) callconv(.c) void {
                const wrapped: *Frame = @ptrCast(@alignCast(ptr));
                // We call through the pointer stored in the frame.
                // Since func_ptr is a PtrType (*const fn...), this is a valid runtime call.
                wrapped.ret = @call(.auto, wrapped.func_ptr, wrapped.args);
            }
        }.wrapper, &frame);

        return frame.ret;
    }

    // =====================================================================
    // Benchmark / Profile / Smash Infrastructure
    // =====================================================================

    pub const BenchmarkResult = struct {
        iterations: u64,
        total_ns: u64,
        min_ns: u64,
        max_ns: u64,
        avg_ns: u64,
        p50_ns: u64,
        p99_ns: u64,
        alloc_count: u64,
        alloc_bytes: u64,
        arena_high_water: usize,
    };

    /// Run a function N times, measuring wall-clock time, allocations, and arena usage.
    pub fn benchmark(
        comptime func: anytype,
        rt: *Runtime,
        args: anytype,
        iterations: u64,
    ) BenchmarkResult {
        const alloc_profile = @import("alloc-profile.zig");
        const timer = compat.Timer;

        const max_samples = @min(iterations, 10_000);
        var samples: [10_000]u64 = undefined;
        var sample_count: u64 = 0;

        const alloc_before = alloc_profile.totalAllocs();
        const bytes_before = alloc_profile.totalBytes();

        var total_ns: u64 = 0;
        var min_ns: u64 = std.math.maxInt(u64);
        var max_ns: u64 = 0;
        var arena_hw: usize = 0;

        var i: u64 = 0;
        while (i < iterations) : (i += 1) {
            const mark = rt.saveFrameMark();
            var t = timer.start() catch continue;

            const ResultType = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
            if (@typeInfo(ResultType) == .error_union) {
                _ = @call(.auto, func, .{rt} ++ args) catch {};
            } else {
                _ = @call(.auto, func, .{rt} ++ args);
            }
            const elapsed = t.read();

            const cursor = rt.overflow_arena.cursor;
            if (cursor > arena_hw) arena_hw = cursor;
            rt.restoreFrameMark(mark);

            total_ns += elapsed;
            if (elapsed < min_ns) min_ns = elapsed;
            if (elapsed > max_ns) max_ns = elapsed;
            if (sample_count < max_samples) {
                samples[sample_count] = elapsed;
                sample_count += 1;
            }
        }

        const alloc_after = alloc_profile.totalAllocs();
        const bytes_after = alloc_profile.totalBytes();

        if (sample_count > 0) {
            std.mem.sort(u64, samples[0..sample_count], {}, std.sort.asc(u64));
        }
        const p50_idx = if (sample_count > 0) sample_count / 2 else 0;
        const p99_idx = if (sample_count > 0) (sample_count * 99) / 100 else 0;

        return BenchmarkResult{
            .iterations = iterations,
            .total_ns = total_ns,
            .min_ns = if (min_ns == std.math.maxInt(u64)) 0 else min_ns,
            .max_ns = max_ns,
            .avg_ns = if (iterations > 0) total_ns / iterations else 0,
            .p50_ns = if (sample_count > 0) samples[p50_idx] else 0,
            .p99_ns = if (sample_count > 0) samples[p99_idx] else 0,
            .alloc_count = alloc_after - alloc_before,
            .alloc_bytes = bytes_after - bytes_before,
            .arena_high_water = arena_hw,
        };
    }

    /// Print a BenchmarkResult to stderr.
    pub fn printBenchmarkResult(name: []const u8, r: BenchmarkResult) void {
        std.debug.print("\nBENCHMARK {s} x{d}:\n", .{ name, r.iterations });
        std.debug.print("  Time:    {d:.1}ms avg ({d:.1}ms min, {d:.1}ms max)\n", .{
            @as(f64, @floatFromInt(r.avg_ns)) / 1_000_000.0,
            @as(f64, @floatFromInt(r.min_ns)) / 1_000_000.0,
            @as(f64, @floatFromInt(r.max_ns)) / 1_000_000.0,
        });
        std.debug.print("  Latency: {d:.1}ms p50, {d:.1}ms p99\n", .{
            @as(f64, @floatFromInt(r.p50_ns)) / 1_000_000.0,
            @as(f64, @floatFromInt(r.p99_ns)) / 1_000_000.0,
        });
        if (r.alloc_count > 0) {
            const per_call = if (r.iterations > 0) r.alloc_count / r.iterations else 0;
            std.debug.print("  Allocs:  {d} total ({d} per call, {d} KB)\n", .{
                r.alloc_count, per_call, r.alloc_bytes / 1024,
            });
        }
        if (r.arena_high_water > 0) {
            std.debug.print("  Arena:   {d} KB high-water\n", .{r.arena_high_water / 1024});
        }
    }

    /// Generate keys that all route to the same shard in a sharded map.
    pub fn generateSkewKeys(
        comptime N: usize,
        target_shard: usize,
        count: usize,
        allocator: std.mem.Allocator,
    ) ![][]const u8 {
        var keys = try allocator.alloc([]const u8, count);
        var found: usize = 0;
        var candidate: u64 = 0;

        while (found < count) : (candidate += 1) {
            var buf: [20]u8 = undefined;
            const key_str = std.fmt.bufPrint(&buf, "sk{d}", .{candidate}) catch continue;
            const h = std.hash_map.hashString(key_str);
            if (@as(usize, h) % N == target_shard) {
                const duped = try allocator.dupe(u8, key_str);
                keys[found] = duped;
                found += 1;
            }
        }
        return keys;
    }

    /// Free keys generated by generateSkewKeys.
    pub fn freeSkewKeys(keys: [][]const u8, allocator: std.mem.Allocator) void {
        for (keys) |k| allocator.free(k);
        allocator.free(keys);
    }
};

/// Module-level spawnPinned: distribute a pinned fiber round-robin across
/// schedulers.  Each call picks the next scheduler in sequence.  The fiber
/// is pinned to that scheduler (config.pinned = true).  This gives each
/// scheduler its own set of fibers — the shared-nothing model.
pub fn spawnPinned(trampoline_addr: usize, user_fn: TaskFn, args: ?*anyopaque, config: fp.TaskConfig) !void {
    var pinned_config = config;
    pinned_config.pinned = true; // fiber must not be stolen — it owns its scheduler's io_uring ring
    const n = fp.global_registry.len.load(.acquire);
    if (n == 0) {
        if (fp.scheduler_running) {
            try fp.active_scheduler.submitSpawn(trampoline_addr, user_fn, args, pinned_config);
            return;
        }
        return error.NoSchedulerAvailable;
    }
    const idx = fp.global_registry.next.fetchAdd(1, .monotonic) % n;
    const sched = fp.global_registry.slots[idx].load(.acquire) orelse {
        try fp.active_scheduler.submitSpawn(trampoline_addr, user_fn, args, pinned_config);
        return;
    };
    try sched.submitSpawn(trampoline_addr, user_fn, args, pinned_config);
}

/// Module-level spawnBest: distribute a fiber to the least-loaded scheduler.
/// Default dispatch for BG/DO blocks; @pinned blocks bypass this.
/// Fully lock-free via pickTwo (1 fetchAdd + 2 atomic loads).
pub fn spawnBest(trampoline_addr: usize, user_fn: TaskFn, args: ?*anyopaque, config: fp.TaskConfig) !void {
    const pair = fp.global_registry.pickTwo();
    const a = pair.a orelse {
        if (fp.scheduler_running) {
            try fp.active_scheduler.submitSpawn(trampoline_addr, user_fn, args, config);
            return;
        }
        return error.NoSchedulerAvailable;
    };
    const b = pair.b orelse {
        try a.submitSpawn(trampoline_addr, user_fn, args, config);
        return;
    };
    const la = a.active_tasks.load(.monotonic);
    const lb = b.active_tasks.load(.monotonic);
    const target = if (la <= lb) a else b;
    try target.submitSpawn(trampoline_addr, user_fn, args, config);
}

/// Module-level spawnFsmOn: submit an FSM task to a specific scheduler.
/// `fsm_task` MUST have been allocated via `allocFsmTask` so the
/// detectCycleFsm slab-pin protocol works. The caller owns the user
/// ctx struct (separate heap allocation) and points to it from
/// `fsm_task.ctx`; destroy_fn frees the ctx, the scheduler returns
/// the FsmTask slot to fsm_task_slab on .Done.
pub fn spawnFsmOn(target: *fp.Scheduler, fsm_task: *fp.FsmTask) !void {
    try target.submitFsmSpawn(fsm_task);
}

/// Allocate a fresh slab-allocated FsmTask. The chain-walker
/// (detectCycleFsm) requires every FsmTask in a lock chain to live
/// in `Scheduler.fsm_task_slab` so it can pin the slab against
/// reclamation while traversing. Ctx is the caller's responsibility
/// — assign the FsmTask's `.ctx` field after allocating it.
///
/// Convention:
///   const task = try CheatHeader.allocFsmTask(parent_rt, &Ctx.resumeFn);
///   task.ctx = ctx;                 // back-pointer for resumeFn recovery
///   task.destroy_fn = &Ctx.destroyTask;
///   const __rt = try CheatHeader.allocFsmTaskRuntime(task, parent_rt);
///   ctx.rt = __rt;
///   try CheatHeader.spawnFsmBest(task);
pub fn allocFsmTask(parent_rt: *Runtime, resume_fn: fp.ResumeFn) !*fp.FsmTask {
    return parent_rt.getSched().allocFsmTask(resume_fn);
}

/// Allocate a generated FSM context using the scheduler-local ctx slabs
/// for the common small cases (64 B / 128 B), falling back to heap for
/// larger or over-aligned contexts. The allocation class is recorded on
/// the FsmTask so destroy can route the free back to the owning scheduler.
pub fn allocFsmCtx(comptime T: type, parent_rt: *Runtime, fsm_task: *fp.FsmTask) !*T {
    return parent_rt.getSched().allocFsmCtx(T, fsm_task);
}

/// Free a generated FSM context through the allocation class recorded by
/// allocFsmCtx. This is called by generated destroyTask after it has run
/// type-specific cleanup.
pub fn freeFsmCtx(comptime T: type, fsm_task: *fp.FsmTask, ctx: *T) void {
    const owner: *fp.Scheduler = if (fsm_task.owner_scheduler) |raw|
        @ptrCast(@alignCast(raw))
    else
        fp.active_scheduler;
    const current = if (fp.scheduler_running) fp.active_scheduler else owner;
    current.freeFsmCtx(T, fsm_task, ctx);
}

/// Allocate a per-FSM-task Runtime shell.
///
/// FSM tasks still need their own Runtime pointer because generated FSM
/// contexts store `rt` directly, but EBR no longer lives on the task. MVCC
/// operations call Runtime.currentEbr(), which resolves to the active
/// scheduler thread's registered EBR slot at dispatch time.
///
/// Lifecycle: this fn allocates Runtime and stashes it on
/// `task.task_runtime`. The scheduler frees it in `releaseFsmTaskEbr`
/// after the task reaches .Done.
///
/// Caller MUST invoke this BEFORE submitting the task (spawnFsmBest /
/// submitFsmSpawn). The CLEAR codegen does:
///   1. ctx.* = .{ .task = undefined, .rt = undefined, ... };
///   2. ctx.task = FsmTask.init(...);
///   3. ctx.task.destroy_fn = ...;
///   4. const __task_rt = try CheatHeader.allocFsmTaskRuntime(&ctx.task, parent_rt);
///   5. ctx.rt = __task_rt;
///   6. try CheatHeader.spawnFsmBest(&ctx.task);
pub fn allocFsmTaskRuntime(fsm_task: *fp.FsmTask, parent_rt: *Runtime) !*Runtime {
    const allocator = parent_rt.heap_allocator;

    const rt_ptr = try allocator.create(Runtime);
    errdefer allocator.destroy(rt_ptr);
    // Build a minimal Runtime. No frame slice -- the FSM body uses its own
    // ctx for state; if it calls frameAlloc via a deep path, that lands in
    // the lazy-heap arena. The ebr pointer is only the non-scheduler
    // fallback; under scheduler dispatch Runtime.currentEbr() returns the
    // active scheduler's thread_ebr.
    rt_ptr.* = try Runtime.initFromSliceWithEbr(&[_]u8{}, parent_rt.ebr, allocator, 0);
    rt_ptr.wireAllocator();

    fsm_task.task_runtime = rt_ptr;
    return rt_ptr;
}

/// Module-level spawnFsmBest: distribute an FSM task to the least-loaded
/// scheduler. Fully lock-free via pickTwo, same as stackful spawnBest.
pub fn spawnFsmBest(fsm_task: *fp.FsmTask) !void {
    const pair = fp.global_registry.pickTwo();
    const a = pair.a orelse {
        if (fp.scheduler_running) {
            try fp.active_scheduler.submitFsmSpawn(fsm_task);
            return;
        }
        return error.NoSchedulerAvailable;
    };
    const b = pair.b orelse {
        try a.submitFsmSpawn(fsm_task);
        return;
    };
    const la = a.active_tasks.load(.monotonic);
    const lb = b.active_tasks.load(.monotonic);
    const target = if (la <= lb) a else b;
    try target.submitFsmSpawn(fsm_task);
}

/// Spawn a BG block on a dedicated OS thread (not a green fiber).
/// Designed for heavy-compute tasks that are non-cooperative (no yields).
/// The OS handles preemption. The result is delivered via the existing
/// Promise/WaitGroup mechanism — the thread calls wg.done() when finished,
/// which wakes the calling fiber on its scheduler.
///
/// Unlike fiber-based BG, the user function receives a freshly allocated
/// Runtime with its own frame arena. No scheduler is involved — the thread
/// runs independently until completion.
pub fn spawnOsThread(user_fn: TaskFn, args: ?*anyopaque) !void {
    _ = std.Thread.spawn(.{}, struct {
        fn run(fn_ptr: TaskFn, fn_args: ?*anyopaque) void {
            // Allocate a standalone Runtime for this thread.
            // Use c_allocator (no GPA — OS threads are outside the scheduler).
            const allocator = std.heap.c_allocator;
            const frame_size = 64 * 1024; // 64 KB frame arena
            const frame_mem = allocator.alloc(u8, frame_size) catch return;
            defer allocator.free(frame_mem);

            var global_ctx = EbrContext{};
            var rt = Runtime.initFromSlice(frame_mem, &global_ctx, allocator, 0) catch return;
            defer rt.deinit();
            rt.wireAllocator();

            const rt_ptr = @as(*anyopaque, @ptrCast(&rt));
            if (fn_ptr(rt_ptr, fn_args)) |_| {} else |_| {}
        }
    }.run, .{ user_fn, args }) catch return error.ThreadSpawnFailed;
}
