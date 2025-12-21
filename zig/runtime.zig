const std = @import("std");
const fp = @import("fiber-pool.zig");

const ThreadLocalEbr = @import("ebr.zig").ThreadLocalEbr;
const EbrContext = @import("ebr.zig").EbrContext;
const Scheduler = fp.Scheduler;
const Task = fp.Task;
const Fiber = fp.Fiber;

pub const CheatArena = struct {
    // 16KB Blocks - nice balance for L1/L2 cache
    const BlockSize = 16 * 1024;

    const Block = struct {
        // We don't need a linked list pointers here because 'blocks' array tracks them
        data: [BlockSize]u8,
    };

    // State
    blocks: std.ArrayListUnmanaged(*Block),
    current_block_index: usize = 0,
    cursor: usize = 0,

    child_allocator: std.mem.Allocator,

    pub fn init(child_allocator: std.mem.Allocator) CheatArena {
        return .{
            .blocks = .{},
            .child_allocator = child_allocator,
        };
    }

    pub fn deinit(self: *CheatArena) void {
        for (self.blocks.items) |block| {
            self.child_allocator.destroy(block);
        }
        self.blocks.deinit(self.child_allocator);
    }

    pub fn alloc(self: *CheatArena, n: usize, alignment: u8, _: usize) ?[*]u8 {
        // 1. Check current block
        if (self.blocks.items.len > 0) {
            const block = self.blocks.items[self.current_block_index];
            const start = @intFromPtr(&block.data[0]);
            const curr = start + self.cursor;
            const aligned = std.mem.alignForward(usize, curr, alignment);
            const offset = aligned - start;

            if (offset + n <= BlockSize) {
                self.cursor = offset + n;
                return @as([*]u8, @ptrFromInt(aligned));
            }
        }

        // 2. Move to next cached block (Reuse!)
        if (self.current_block_index + 1 < self.blocks.items.len) {
            self.current_block_index += 1;
            self.cursor = 0;
            return self.alloc(n, alignment, 0);
        }

        // 3. Allocate new block (Slow path)
        const new_block = self.child_allocator.create(Block) catch return null;
        self.blocks.append(self.child_allocator, new_block) catch {
            self.child_allocator.destroy(new_block);
            return null;
        };

        self.current_block_index = self.blocks.items.len - 1;
        self.cursor = 0;

        return self.alloc(n, alignment, 0);
    }

    // --- REWIND ---

    pub const Mark = struct {
        block_index: usize,
        cursor: usize,
    };

    pub fn getMark(self: *CheatArena) Mark {
        // If we have no blocks yet, mark is 0,0
        if (self.blocks.items.len == 0) return .{ .block_index = 0, .cursor = 0 };
        return .{
            .block_index = self.current_block_index,
            .cursor = self.cursor,
        };
    }

    pub fn rewind(self: *CheatArena, mark: Mark) void {
        // 1. Reset Logic
        self.current_block_index = mark.block_index;
        self.cursor = mark.cursor;

        // 2. HYBRID TRIM:
        // We keep the block we are currently standing on (mark.block_index),
        // but we free any blocks that come AFTER it.
        // This ensures we don't hold 100MB of extra pages if we rewound all the way back.

        const keep_count = if (self.blocks.items.len > 0) self.current_block_index + 1 else 0;

        while (self.blocks.items.len > keep_count) {
            const popped = self.blocks.pop();
            if (@typeInfo(@TypeOf(popped)) == .optional) {
                self.child_allocator.destroy(popped.?);
            } else {
                self.child_allocator.destroy(popped);
            }
        }
    }
};

pub const Runtime = struct {
    // THE FRAME (Scratchpad)
    // We use a FixedBufferAllocator to simulate the linear stack.
    // It is backed by a raw slice of memory.
    frame_backing: []u8,
    frame_fba: std.heap.FixedBufferAllocator,

    // Control
    ebr: ThreadLocalEbr,  // This probably needs to be global...
    owns_frame_memory: bool,
    // For green fibers, how long until this DIES? (0 = No timeout - deal with it)
    deadline: i64 = 0,

    // OVERFLOW (The Safety Valve)
    // We use an Arena so we can track all the overflow allocations
    // and free them in one go when the task resets.
    overflow_arena: CheatArena,

    // THREE ALLOCATORS
    local_allocator: std.mem.Allocator,  // Thread-local HEAP (No lock) -> %
    global_allocator: std.mem.Allocator, // Shared / Global HEAP (Locked) -> %%
    smart_allocator: std.mem.Allocator,  // The VTable interface / FRAME

    pub fn init(
        allocator: std.mem.Allocator,
        frame_size: usize,
        global_ctx: *EbrContext,
        global_alloc: std.mem.Allocator,
        local_alloc: std.mem.Allocator,
    ) !Runtime {
        // Alloc raw memory for the frame (1MB or whatever passed)
        const frame_mem = try allocator.alloc(u8, frame_size);

        // Pass 'local_alloc' down to initFromSlice
        var rt = try initFromSlice(frame_mem, global_ctx, global_alloc, local_alloc, 0);

        // Because we allocated 'slice' above
        rt.owns_frame_memory = true;
        return rt;
    }

    pub fn initFromSlice(
        slice: []u8,
        global_ctx: *EbrContext,
        global_alloc: std.mem.Allocator,
        local_alloc: std.mem.Allocator,
        timeout_ms: u64
    ) !Runtime {
        const local_ebr = ThreadLocalEbr{ .context = global_ctx, .limbo_list = .{} };

        var deadline: i64 = 0;
        if (timeout_ms > 0) {
            deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
        }

        return Runtime{
            .frame_backing = slice,
            .frame_fba = std.heap.FixedBufferAllocator.init(slice),
            .global_allocator = global_alloc,
            .local_allocator = local_alloc,
            .ebr = local_ebr,
            .owns_frame_memory = false, // DO NOT FREE THIS in deinit.
            .deadline = deadline,
            .smart_allocator = undefined,
            .overflow_arena = CheatArena.init(local_alloc),
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.ebr.deinit(self.global_allocator);
        self.overflow_arena.deinit();

        // We DO NOT free global_allocator (it's shared)

        // IMPORTANT: Only free frame IF WE OWN IT!
        if (self.owns_frame_memory) {
            self.global_allocator.free(self.frame_backing);
        }
    }

    pub fn wireAllocator(self: *Runtime) void {
        self.smart_allocator = std.mem.Allocator{
            .ptr = self,
            .vtable = &SmartAllocatorVTable,
        };
    }

    pub const SmartAllocatorVTable = std.mem.Allocator.VTable{
        .alloc = smartAlloc,
        .resize = smartResize,
        .free = smartFree,
        .remap = smartRemap,
    };

    fn smartAlloc(ctx: *anyopaque, n: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self = @as(*Runtime, @ptrCast(@alignCast(ctx)));

        // 1. Try FRAME
        // rawAlloc accepts std.mem.Alignment directly
        if (self.frame_fba.allocator().rawAlloc(n, ptr_align, ret_addr)) |ptr| {
            return ptr;
        }

        // 2. Try Overflow Arena
        // CheatArena.alloc still expects u8 (or usize), so we convert using .toByteUnits()
        // We cast to u8 because alignment is rarely > 255.
        const align_u8 = @as(u8, @intCast(ptr_align.toByteUnits()));
        return self.overflow_arena.alloc(n, align_u8, ret_addr);
    }

    fn smartResize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = buf_align;
        _ = ret_addr;

        const self = @as(*Runtime, @ptrCast(@alignCast(ctx)));
        const start = @intFromPtr(self.frame_backing.ptr);
        const end = start + self.frame_backing.len;
        const ptr_addr = @intFromPtr(buf.ptr);

        if (ptr_addr >= start and ptr_addr < end) {
            return self.frame_fba.allocator().resize(buf, new_len);
        }
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
    pub fn saveFrameMark(self: *Runtime) usize {
        return FrameMark{
            .stack_index = self.frame_fba.end_index,
            .overflow_mark = self.overflow_list.getMark(),
        };
    }

    // Stack Helper: Reset to Mark (O(1) Free)
    pub fn restoreFrameMark(self: *Runtime, mark: FrameMark) void {
        self.frame_fba.end_index = mark.stack_index;
        self.overflow_arena.rewind(mark.overflow_mark);
    }

    pub fn frameAlloc(self: *Runtime) std.mem.Allocator {
        return self.smart_allocator;
    }

    pub fn globalAlloc(self: *Runtime) std.mem.Allocator {
        return self.global_allocator;
    }

    pub fn allocCopy(self: *Runtime, comptime T: type, value: T) !*T {
        const ptr = try self.heapAlloc().create(T);
        ptr.* = value;
        return ptr;
    }

    // For green fibers
    pub fn checkpoint(self: *Runtime) !void {
        if (self.deadline > 0) {
            const now = std.time.milliTimestamp();
            if (now > self.deadline) {
                return error.Timeout;
            }
        }
        // Optional: Auto-yield every N calls to prevent CPU hogging?
        // For now, just checking time is enough.
    }

    // Helper to spawn tasks easily from the Runtime
    // TODO: need to pass config here.
    pub fn spawn(self: *Runtime, user_fn: *const fn (*Runtime, ?*anyopaque) anyerror!void, args_ptr: ?*anyopaque) !void {
        try self.scheduler.submitSpawn(
            @intFromPtr(&entryWrapper), // trampoline
            @as(fp.TaskFn, @ptrCast(user_fn)),
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
            @as(fp.TaskFn, @ptrCast(user_fn)),
            args_ptr,
            .{} // Default Config (timeout_ms = 0)
        );
    }

    // "Power of Two Choices": Pick 2 random threads - best of 2 is surprisingly good - send to the least busy one.
    // TODO: need to pass config here.
    pub fn spawnBest(user_fn: *const fn (*Runtime, ?*anyopaque) anyerror!void, args_ptr: ?*anyopaque) !void {
        // 1. Pick 2 Random Candidates
        const candidates = fp.global_registry.getRandomPair();
        if (candidates.a == null) return error.NoThreads;

        const s1 = candidates.a.?;
        const s2 = candidates.b orelse s1;

        // 2. Compare Load
        const l1 = s1.load.load(.monotonic);
        const l2 = s2.load.load(.monotonic);

        // 3. Pick the Winner
        const target = if (l1 <= l2) s1 else s2;

        // 4. Allocate the REQUEST node locally (eventually from a global slab if strict ownership)
        // Ideally, we use a global lock-free slab allocator for these nodes
        // so we don't leak memory if the runtime shuts down.
        // For now, we'll malloc it.
        try target.submitSpawn(
            @intFromPtr(&entryWrapper),
            @as(fp.TaskFn, @ptrCast(user_fn)),
            args_ptr,
            .{}
        );
    }

    // For green fibers
    pub fn sleep(_: *Runtime, ms: u64) void {
        const sched = fp.active_scheduler;
        const task = sched.getCurrent();

        // Calculate wake time
        const now = std.time.milliTimestamp();
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

        // 2. THE FIX: Skip the first 4KB (Guard Page)
        // We cannot write to index 0. We must start at 4096.
        const guard_offset = 4096;
        const scratchpad_size = 1024 * 1024; // 1MB

        // 3. Initialize Runtime
        // Optimization: We carve 1MB off the bottom of the Fiber's OWN stack
        // to use as the Runtime's scratchpad. No malloc needed!
        const full_stack_memory = task.base.stack.memory;
        const scratchpad_slice = full_stack_memory[guard_offset .. guard_offset + scratchpad_size];

        var rt = Runtime.initFromSlice(
            scratchpad_slice,
            sched.global_ebr,
            sched.allocator,
            sched.allocator,
            task.config.timeout_ms
        ) catch unreachable;

        defer rt.deinit();
        rt.wireAllocator();

        const rt_ptr = @as(*anyopaque, @ptrCast(&rt));

        // 3. EXECUTE USER CODE
        if (task.user_fn(rt_ptr, task.context)) {
            // Success
        } else |err| {
            // Failure / Timeout
            // Later, we'll store this error in the Task so the parent can see it.
            // For now, we just print and die safely.
            if (err == error.Timeout) {
                 std.debug.print("\n[Scheduler] Task Timed Out! Killing it.\n", .{});
            } else {
                 std.debug.print("\n[Scheduler] Task Crashed: {}\n", .{err});
            }
        }

        // 4. Mark as finished before yielding back
        task.status = .Finished;

        // 5. Cleanup & Yield
        // When we yield here, we go back to Scheduler.run loop.
        task.base.yield();
    }
};

