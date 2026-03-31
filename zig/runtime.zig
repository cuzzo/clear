const std = @import("std");
const fc = @import("fiber-core.zig");
const fp = @import("scheduler.zig");
const qs = @import("queues.zig");
const ebr_mod = @import("ebr.zig");

const ThreadLocalEbr = ebr_mod.ThreadLocalEbr;
const EbrContext = ebr_mod.EbrContext;

// Compat: std.time.milliTimestamp was removed in newer Zig versions.
fn milliTimestamp() i64 {
    const ts = std.posix.clock_gettime(.MONOTONIC) catch return 0;
    return @intCast(ts.sec * 1000 + @divFloor(ts.nsec, 1_000_000));
}
const Scheduler = fp.Scheduler;
const Task = qs.Task;
const Fiber = qs.Fiber;
pub const CheatArena = @import("frame.zig").CheatArena;

// This forces Zig to generate the exported panic symbols
comptime {
    _ = fc;
}

// Cooperative yield budget: power-of-two so the check reduces to a single AND.
// Every YIELD_BUDGET loop iterations, checkYield() hands control to the scheduler
// if another fiber is ready. Reset to 0 after each yield, giving each fiber a
// fresh 4096-iteration slice on resume.
const YIELD_BUDGET: u32 = 4096;
const YIELD_MASK:   u32 = YIELD_BUDGET - 1;

pub const Runtime = struct {
    // Control
    ebr: ThreadLocalEbr,  // This probably needs to be global...
    owns_frame_memory: bool,
    // For green fibers, how long until this DIES? (0 = No timeout - deal with it)
    deadline: i64 = 0,
    // Cooperative scheduling: counts loop back-edges; yields when lower 12 bits hit 0.
    yield_counter: u32 = 0,

    // OVERFLOW (The Safety Valve)
    // We use an Arena so we can track all the overflow allocations
    // and free them in one go when the task resets.
    overflow_arena: CheatArena,

    // THREE ALLOCATORS
    heap_allocator: std.mem.Allocator,    // GPA or tcmalloc/jemalloc/mimalloc/malloc
    frame_allocator: std.mem.Allocator,   // The VTable interface / FRAME

    // @arena mode: when true, restoreFrameMark is a no-op.
    // The entire arena is freed when the fiber finishes, not per-function.
    arena_mode: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        frame_size: usize,
        global_ctx: *EbrContext,
    ) !Runtime {
        // Alloc raw memory for the frame (1MB or whatever passed)
        const frame_mem = try allocator.alloc(u8, frame_size);

        var rt = try initFromSlice(frame_mem, global_ctx, allocator, 0);

        // Because we allocated 'slice' above
        rt.owns_frame_memory = true;
        return rt;
    }

    pub fn initFromSlice(
        slice: []u8,
        global_ctx: *EbrContext,
        heap_allocator: std.mem.Allocator,
        timeout_ms: u64
    ) !Runtime {
        const local_ebr = ThreadLocalEbr{ .context = global_ctx, .limbo_list = .{} };

        var deadline: i64 = 0;
        if (timeout_ms > 0) {
            deadline = milliTimestamp() + @as(i64, @intCast(timeout_ms));
        }

        return Runtime{
            .ebr = local_ebr,
            .owns_frame_memory = false, // DO NOT FREE THIS in deinit.
            .deadline = deadline,
            .frame_allocator = undefined,
            .heap_allocator = heap_allocator,
            .overflow_arena = CheatArena.init(heap_allocator, slice),
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.overflow_arena.deinit();
        self.ebr.deinit(self.heap_allocator);

        // IMPORTANT: Only free frame IF WE OWN IT!
        if (self.owns_frame_memory) {
            self.heap_allocator.free(self.overflow_arena.static_block);
        }
    }

    // Allocators:

    pub fn wireAllocator(self: *Runtime) void {
        self.frame_allocator = std.mem.Allocator{
            .ptr = self,
            .vtable = &SmartAllocatorVTable,
        };
    }

    // Frame Allocator Backing

    pub const SmartAllocatorVTable = std.mem.Allocator.VTable{
        .alloc = smartAlloc,
        .resize = smartResize,
        .free = smartFree,
        .remap = smartRemap,
    };

    fn smartAlloc(ctx: *anyopaque, n: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self = @as(*Runtime, @ptrCast(@alignCast(ctx)));
        const align_u8 = @as(u8, @intCast(ptr_align.toByteUnits()));

        // No more "try fba, else try arena". It's just arena.
        return self.overflow_arena.alloc(n, align_u8, ret_addr);
    }

    fn smartResize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ctx; _ = buf; _ = buf_align; _ = ret_addr; _ = new_len;
        return false;
    }

    fn smartFree(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        // We don't actually free individual items in a Frame/Arena model.
        // We just let them accumulate and wipe the slate clean at the end.
        // But for correctness, we can forward the call if needed.
        _ = ctx; _ = buf; _ = buf_align; _ = ret_addr;
    }

    fn smartRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = ctx; _ = memory; _ = alignment; _ = new_len; _ = ret_addr;
        return null;
    }

    pub const FrameMark = struct {
        stack_index: usize,
        overflow_mark: CheatArena.Mark,
    };

    // Stack Helper: Get current Mark (Offset)
    pub fn saveFrameMark(self: *Runtime) FrameMark {
        return FrameMark{
            .stack_index = 0,  // TODO: Deprecate
            .overflow_mark = self.overflow_arena.getMark(),
        };
    }

    // Stack Helper: Reset to Mark (O(1) Free)
    pub fn restoreFrameMark(self: *Runtime, mark: FrameMark) void {
        if (self.arena_mode) return; // Skip rewind — fiber owns the arena until completion.
        self.overflow_arena.rewind(mark.overflow_mark);
    }

    // Lightweight arena mark for per-loop-iteration rewind.
    // Used by the transpiler for WhileLoop bodies that contain loop-local
    // frame-allocated data (e.g. @list or tcpRead results inside a loop body).
    pub fn saveLoopMark(self: *Runtime) CheatArena.Mark {
        return self.overflow_arena.getMark();
    }

    pub fn restoreLoopMark(self: *Runtime, mark: CheatArena.Mark) void {
        self.overflow_arena.rewind(mark);
    }

    pub fn frameAlloc(self: *Runtime) std.mem.Allocator {
        // @pinned tasks use the scheduler's thread-local arena — the shared
        // frame_allocator is NOT thread-safe and must not be used from
        // fibers distributed across multiple schedulers.
        return fp.__pinned_local_alloc orelse self.frame_allocator;
    }

    pub fn heapAlloc(self: *Runtime) std.mem.Allocator {
        // @pinned tasks use the scheduler's thread-local arena — zero locks.
        return fp.__pinned_local_alloc orelse self.heap_allocator;
    }

    // TODO: Deprecate
    pub fn globalAlloc(self: *Runtime) std.mem.Allocator {
        return self.heap_allocator;
    }

    pub fn allocCopy(self: *Runtime, comptime T: type, value: T) !*T {
        const ptr = try self.globalAlloc().create(T);
        ptr.* = value;
        return ptr;
    }

    // For green fibers
    pub fn checkpoint(self: *Runtime) !void {
        if (self.deadline > 0) {
            const now = milliTimestamp();
            if (now > self.deadline) {
                return error.Timeout;
            }
        }
        // Optional: Auto-yield every N calls to prevent CPU hogging?
        // For now, just checking time is enough.
    }

    // Returns the scheduler for the current thread.
    // Used by the DO block fork-join primitive.
    pub fn getSched(_: *Runtime) *fp.Scheduler {
        return fp.active_scheduler;
    }

    // Cooperative yield check — injected at the back-edge of every non-TIGHT while loop.
    // Uses a power-of-two counter so the hot path is: wrapping-add + AND + compare-zero.
    // Yields to the scheduler only when another fiber is ready; single-fiber programs pay
    // only the counter arithmetic (no syscall, no context switch).
    // The counter resets to 0 on each yield, giving the fiber a fresh 4096-iteration
    // budget on every resume.
    pub inline fn checkYield(self: *Runtime) void {
        self.yield_counter = (self.yield_counter +% 1) & YIELD_MASK;
        if (self.yield_counter == 0) {
            fp.active_scheduler.coopYield();
        }
    }

    // Helper to spawn tasks easily from the Runtime
    // TODO: need to pass config here.
    pub fn spawn(_: *Runtime, user_fn: *const fn (*Runtime, ?*anyopaque) anyerror!void, args_ptr: ?*anyopaque) !void {
        try fp.active_scheduler.submitSpawn(
            @intFromPtr(&entryWrapper), // trampoline
            @as(qs.TaskFn, @ptrCast(user_fn)),
            args_ptr,
            .{}
        );
    }

    // SPAWN ON (Specific Thread)
    // TODO: need to pass config here.
    pub fn spawnOn(target_id: std.Thread.Id, user_fn: *const fn (*Runtime, ?*anyopaque) anyerror!void, args_ptr: ?*anyopaque) !void {
        const target = fp.global_registry.get(target_id) orelse return error.ThreadNotFound;

        // We must allocate the Task struct on the GLOBAL heap because
        // we are creating it here but it lives over there.
        try target.submitSpawn(
            @intFromPtr(&entryWrapper),
            @as(qs.TaskFn, @ptrCast(user_fn)),
            args_ptr,
            .{} // Default Config (timeout_ms = 0)
        );
    }

    // Power-of-Two Choices via lock-free pickTwo.
    // TODO: need to pass config here.
    pub fn spawnBest(user_fn: *const fn (*Runtime, ?*anyopaque) anyerror!void, args_ptr: ?*anyopaque) !void {
        const pair = fp.global_registry.pickTwo();
        const a = pair.a orelse return error.NoThreads;
        const b = pair.b orelse {
            try a.submitSpawn(
                @intFromPtr(&entryWrapper),
                @as(qs.TaskFn, @ptrCast(user_fn)),
                args_ptr,
                .{}
            );
            return;
        };
        const la = a.active_tasks.load(.monotonic);
        const lb = b.active_tasks.load(.monotonic);
        const target = if (la <= lb) a else b;
        try target.submitSpawn(
            @intFromPtr(&entryWrapper),
            @as(qs.TaskFn, @ptrCast(user_fn)),
            args_ptr,
            .{}
        );
    }

    // For green fibers
    pub fn sleep(_: *Runtime, ms: u64) void {
        const sched = fp.active_scheduler;
        const task = sched.getCurrent();

        // Calculate wake time
        const now = milliTimestamp();
        const wake_time = now + @as(i64, @intCast(ms));

        // Tell scheduler to hold us
        sched.sleepTask(task, wake_time);

        // Yield (The scheduler will put us in the sleeping_queue, NOT ready_queue)
        task.base.yield();
    }

    pub fn entryWrapper() callconv(.c) void {
        // 1. Get the current task info
        const sched = fp.active_scheduler;
        const task = sched.current_task.?;

        // Skip the first 4KB (Frame)
        const frame_size = 4 * 1024; // 4kb -> Frame

        // 3. Initialize Runtime
        // Optimization: We carve 1MB off the bottom of the Fiber's OWN stack
        // to use as the Runtime's scratchpad. No malloc needed!
        const full_stack_memory = task.base.stack.memory;
        if (full_stack_memory.len < frame_size + 1024) @panic("Stack too small for Frame!");

        const frame_slice = full_stack_memory[0 .. frame_size];

        var rt = Runtime.initFromSlice(
            frame_slice,
            sched.global_ebr,
            sched.allocator,
            task.config.timeout_ms
        ) catch unreachable;

        rt.wireAllocator();

        const rt_ptr = @as(*anyopaque, @ptrCast(&rt));
        task.runtime_ptr = rt_ptr;

        // 4. EXECUTE USER CODE
        if (task.user_fn(rt_ptr, task.context)) {
            // Success
        } else |err| {
            // Failure / Timeout
            // Later, we'll store this error in the Task so the parent can see it.
            // For now, we just print and die safely.
            if (err == error.Timeout) {
                 std.debug.print("\n[Scheduler] Task Timed Out! Killing it.\n", .{});
            } else if (err == error.StreamClosed) {
                 // InfStream generator received a close signal — clean exit, not a crash.
            } else {
                 std.debug.print("\n[Scheduler] Task Crashed: {}\n", .{err});
            }
        }


        // 5. Cleanup & Yield
        // When we yield here, we go back to Scheduler.run loop.
        rt.deinit();  // must manually de-init
        task.status = .Finished;
        task.base.yield();
    }

    /// Run a function on the scheduler's root OS stack (like Go's g0).
    /// Use for FFI calls to C libraries with unknown stack requirements.
    /// If we're already on the main thread (no scheduler running) or already
    /// on the root stack, calls the function directly — no trampoline overhead.
    /// NOTE: The trampolined function must NOT yield (no io_uring, no fiber sleep).
    pub fn onRootStack(_: *Runtime, user_fn: *const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque) void {
        // Fast path: not in a fiber — already on the OS stack.
        if (!fp.scheduler_running) {
            user_fn(arg);
            return;
        }

        const sched = fp.active_scheduler;
        const task = sched.getCurrent();

        // Fast path: already on the root stack (nested onRootStack call).
        if (task.is_on_root_stack) {
            user_fn(arg);
            return;
        }

        task.is_on_root_stack = true;
        defer task.is_on_root_stack = false;

        // Use the scheduler's saved SP (main_ctx.sp). Stacks grow downward:
        // the trampoline pushes frames BELOW main_ctx.sp into unused thread
        // stack space. The scheduler's own frames are ABOVE main_ctx.sp and
        // are frozen while the fiber runs (cooperative scheduling).
        fc.callOnStack(sched.main_ctx.sp, user_fn, arg);
    }
};

