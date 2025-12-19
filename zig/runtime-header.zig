const std = @import("std");
const builtin = @import("builtin");

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

    // For green fibers
    pub fn sleep(_: *Runtime, ms: u64) void {
        const sched = active_scheduler;
        const task = sched.getCurrent();

        // Calculate wake time
        const now = std.time.milliTimestamp();
        const wake_time = now + @as(i64, @intCast(ms));

        // Tell scheduler to hold us
        sched.sleepTask(task, wake_time);

        // Yield (The scheduler will put us in the sleeping_queue, NOT ready_queue)
        task.base.yield();
    }

    // Mostly for green fibers
    // Read from a non-blocking socket
    // Only works on Linux
    pub fn read(_: *Runtime, fd: i32, buffer: []u8) !usize {
        const sched = active_scheduler;
        const task = sched.getCurrent();

        while (true) {
            // 1. Try to read directly
            const rc = std.os.linux.read(fd, buffer.ptr, buffer.len);
            const errno = std.posix.errno(rc);

            switch (errno) {
                .SUCCESS => {
                    // Success! rc is the bytes read.
                    return rc;
                },
                .AGAIN => { // (This handles EAGAIN / EWOULDBLOCK)
                     // 3. Register with Epoll
                     try sched.registerFd(fd, task);

                     // 4. Yield (Block)
                     task.status = .Blocked;
                     task.base.yield();

                     // When we wake up, loop back and try read() again!
                     continue;
                },
                else => {
                    // Real Error
                    return std.posix.unexpectedErrno(errno);
                }
            }
        }
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

    // List / Dynamic Array

    pub fn makeList(self: *Runtime, comptime T: type, allocator: std.mem.Allocator, items: []const T) !std.ArrayListUnmanaged(T) {
        _ = self;
        var list = try std.ArrayListUnmanaged(T).initCapacity(allocator, items.len);
        list.appendSliceAssumeCapacity(items);
        return list;
    }

    // Works for ArrayListUnmanaged (has .items) AND Standard Slices (direct access)
    // Also handles casting the index to usize automatically.
    pub fn getAt(self: *Runtime, container: anytype, index: anytype) @TypeOf(if (@hasField(@TypeOf(container), "items")) container.items[0] else container[0]) {
        _ = self;
        const i: usize = @intCast(index); // Auto-cast i64 -> usize

        if (@hasField(@TypeOf(container), "items")) {
            return container.items[i];
        } else {
            return container[i];
        }
    }

    // Works for Lists and Slices because it modifies the memory the slice points to.
    pub fn setAt(self: *Runtime, container: anytype, index: anytype, value: anytype) void {
        _ = self;
        const i: usize = @intCast(index);

        if (@hasField(@TypeOf(container), "items")) {
            // ArrayListUnmanaged
            container.items[i] = value;
        } else {
            // Standard Slice
            container[i] = value;
        }
    }

    pub fn concat(self: *Runtime, allocator: std.mem.Allocator, s1: []const u8, s2: []const u8) ![]const u8 {
        _ = self;
        return try std.mem.concat(allocator, u8, &.{ s1, s2 });
    }

    // Polymorphic Length (Strings or Lists)
    pub fn len(self: *Runtime, container: anytype) i64 {
        _ = self;
        // If it has .items (ArrayList), use that. Otherwise assume it's a Slice.
        if (@hasField(@TypeOf(container), "items")) {
            return @intCast(container.items.len);
        } else {
            return @intCast(container.len);
        }
    }

    // HashMap / Associative Map

    // Usage: var map = try rt.makeMap(i64, rt.heapAlloc());
    pub fn makeHashMap(self: *Runtime, comptime V: type, allocator: std.mem.Allocator) !std.StringHashMapUnmanaged(V) {
        _ = self;
        _ = allocator;
        // Start empty. Unmanaged maps don't alloc until you put().
        return std.StringHashMapUnmanaged(V){};
    }

    // Usage: try rt.mapPut(i64, rt.heapAlloc(), &map, "key", 100);
    pub fn mapPut(self: *Runtime, comptime V: type, allocator: std.mem.Allocator, map: *std.StringHashMapUnmanaged(V), key: []const u8, value: V) !void {
        _ = self;
        // Critical: We must duplicate the key to the Heap because the Map keeps a pointer to it.
        // If we don't, and 'key' is a frame string that dies, the map breaks.
        const key_copy = try allocator.dupe(u8, key);
        try map.put(allocator, key_copy, value);
    }

    // Usage: rt.mapGet(i64, map, "key")
    pub fn mapGet(self: *Runtime, comptime V: type, map: std.StringHashMapUnmanaged(V), key: []const u8) V {
        _ = self;
        // Return value or Default (0/null).
        // For v0.1 scripting, returning 0/empty is often friendlier than crashing.
        if (map.get(key)) |val| {
            return val;
        }

        // Default values based on type
        if (V == i64 or V == f64) return 0;
        if (V == []const u8) return "";
        return undefined; // Should ideally handle this better
    }

    // FILE

    // Read File (Allocates on HEAP)
    pub fn readFile(self: *Runtime, path: []const u8) ![]const u8 {
        // 1. Open File
        // Note: We use the absolute path or CWD.
        var dir = std.fs.cwd();
        var file = try dir.openFile(path, .{});
        defer file.close();

        // 2. Stat size to allocate exact buffer
        const stat = try file.stat();

        // 3. Alloc buffer in Heap Arena (Survivor)
        const buffer = try self.heapAlloc().alloc(u8, stat.size);

        // 4. Read
        _ = try file.readAll(buffer);
        return buffer;
    }

    // Write File
    pub fn writeFile(self: *Runtime, path: []const u8, content: []const u8) !void {
        _ = self;
        var dir = std.fs.cwd();
        // Create or Overwrite
        var file = try dir.createFile(path, .{});
        defer file.close();

        try file.writeAll(content);
    }

    // String Lib

    // Used to make HEAP strings
    pub fn makeString(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "{s}", .{text});
    }

    pub fn substr(self: *Runtime, allocator: std.mem.Allocator, str: []const u8, start: i64, length: i64) ![]const u8 {
        _ = self;
        // Basic safety checks (Zig panics on slice OOB, but clean errors are better)
        const u_start: usize = @intCast(start);
        const u_len: usize = @intCast(length);

        if (u_start + u_len > str.len) return error.OutOfBounds;

        // Slicing in Zig is O(1) pointer math!
        const slice = str[u_start .. u_start + u_len];

        // We must COPY it to the new allocator (usually Heap) so it survives
        return allocator.dupe(u8, slice);
    }

    // String Equality (Content check)
    pub fn eql(self: *Runtime, s1: []const u8, s2: []const u8) bool {
        _ = self;
        return std.mem.eql(u8, s1, s2);
    }

    // Split: String -> List
    pub fn split(self: *Runtime, allocator: std.mem.Allocator, str: []const u8, delimiter: []const u8) !std.ArrayListUnmanaged([]const u8) {
        _ = self;
        var list = std.ArrayListUnmanaged([]const u8){};

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
    pub fn join(self: *Runtime, allocator: std.mem.Allocator, list: anytype, delimiter: []const u8) ![]const u8 {
        _ = self;
        // Support both ArrayListUnmanaged and raw Slices
        const items = if (@hasField(@TypeOf(list), "items")) list.items else list;
        return std.mem.join(allocator, delimiter, items);
    }

    // shell

    pub fn shell(self: *Runtime, allocator: std.mem.Allocator, cmd: []const u8) ![]const u8 {
        _ = self;

        // 1. Prepare Command (Wrap in sh -c to support pipes/globbing)
        //    Note: For Windows support, you'd check builtin.os.tag and use "cmd", "/C"
        const argv = if (builtin.os.tag == .windows)
            &[_][]const u8{ "cmd", "/C", cmd }
        else
            &[_][]const u8{ "/bin/sh", "-c", cmd };

        // 2. Initialize Process
        var child = std.process.Child.init(argv, allocator);
        child.stdout_behavior = .Pipe; // Capture StdOut
        child.stderr_behavior = .Inherit; // Print StdErr to console (helpful for debugging)

        // 3. Run
        try child.spawn();

        // 4. Read Output
        //    readToEndAlloc will allocate exactly enough memory for the output.
        //    We set a safety limit (e.g., 10MB) to prevent crashing on massive output.
        const stdout = try child.stdout.?.readToEndAlloc(allocator, 10 * 1024 * 1024);

        // 5. Cleanup
        _ = try child.wait(); // Wait for finish

        return stdout;
    }

    // Threading

    pub fn spawnThread(sys_allocator: std.mem.Allocator, frame_size: usize, global_ctx: *EbrContext, global_alloc: std.mem.Allocator, local_alloc: std.mem.Allocator, comptime func: anytype, args: anytype) !std.Thread {
        // We don't call 'func' directly. We call the wrapper.
        // We pass the config + the function + the args TO the wrapper.
        return std.Thread.spawn(.{}, threadWrapper, .{ sys_allocator, frame_size, global_ctx, global_alloc, local_alloc, func, args });
    }

    // THE INTERNAL WRAPPER
    // This runs INSIDE the new thread. It handles the boilerplate.
    fn threadWrapper(allocator: std.mem.Allocator, frame_size: usize, global_ctx: *EbrContext, global_alloc: std.mem.Allocator, local_alloc: std.mem.Allocator, comptime func: anytype, args: anytype) !void {
        // 1. BOILERPLATE: Setup Runtime
        var rt = try Runtime.init(allocator, frame_size, global_ctx, global_alloc, local_alloc);
        defer rt.deinit();

        rt.wireAllocator();

        // IMPORTANT: Register this thread with the global context now that `rt` is stable on the frame.
        try global_ctx.register(allocator, &rt.ebr);

        // This runs FIRST (before deinit): Remove from global registry
        // so the GC doesn't try to look at our dead frame.
        defer global_ctx.unregister(&rt.ebr);

        // 2. MAGIC: Call the user function
        // We assume your worker functions always take 'rt' as the first argument.
        // We use '++' to concatenate the Runtime pointer with the user's arguments.
        const type_info = @typeInfo(@TypeOf(func));
        if (type_info == .@"fn" or type_info == .Fn) {
            try @call(.auto, func, .{&rt} ++ args);
        }
    }
};

// -------------------------------------------------------------------------
// Concurrency Primitives (Locked<T>)
// -------------------------------------------------------------------------

pub fn Locked(comptime T: type) type {
    return struct {
        // The mutex protects the data below
        mutex: std.Thread.Mutex = .{},
        data: T,

        const Self = @This();

        // 1. Init: Create the object (unlocked)
        pub fn init(val: T) Self {
            return .{ .data = val };
        }

        // 2. Acquire: Blocks until lock is obtained.
        // Returns a "Guard" that gives access to data.
        pub fn acquire(self: *Self) Guard {
            self.mutex.lock();
            return Guard{ .parent = self };
        }

        // The Guard Pattern:
        // Holds the pointer to the parent.
        // Releases the lock automatically when usage is done (if you defer release).
        pub const Guard = struct {
            parent: *Self,

            // Get mutable pointer to the inner data
            pub fn get(self: *Guard) *T {
                return &self.parent.data;
            }

            // Get const pointer (read-only)
            pub fn getConst(self: *Guard) *const T {
                return &self.parent.data;
            }

            // Release the lock
            pub fn release(self: *Guard) void {
                self.parent.mutex.unlock();
            }
        };
    };
}

// -------------------------------------------------------------------------
// Concurrency Primitives (Shared<T> - LEAKY VERSION)
// -------------------------------------------------------------------------

pub fn Shared(comptime T: type) type {
    return struct {
        // The Atomic Pointer to the current version.
        // We use *T because we are swapping the entire object.
        ptr: std.atomic.Value(*T),

        const Self = @This();

        // 1. Init: Allocate the first version on the heap
        pub fn init(allocator: std.mem.Allocator, val: T) !Self {
            const node = try allocator.create(T);
            node.* = val;
            return Self{ .ptr = std.atomic.Value(*T).init(node) };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            // Load the current pointer and destroy it
            const current_ptr = self.ptr.load(.seq_cst);
            allocator.destroy(current_ptr);
        }

        // 2. Read: Just load the pointer.
        // This is Wait-Free, Lock-Free, and insanely fast.
        pub fn read(self: *Self, trt: *Runtime) Guard {
            // A. Signal start
            trt.ebr.enter();

            // B. Load pointer (Safe because we are in the epoch)
            const val = self.ptr.load(.monotonic);

            return Guard{ .ptr = val, .rt = trt };
        }

        // The Read Guard
        pub const Guard = struct {
            ptr: *T,
            rt: *Runtime,

            pub fn get(self: *Guard) *T {
                return self.ptr;
            }

            pub fn release(self: *Guard) void {
                // C. Signal done
                self.rt.ebr.exit();
            }
        };

        // 3. Write: Copy-On-Write with CAS (Compare And Swap)
        // This is the "Transaction" logic.
        // func: A lambda/function that takes (*NewData) and modifies it.
        pub fn update(self: *Self, trt: *Runtime, allocator: std.mem.Allocator, comptime func: anytype, args: anytype) !void {

            // OPTIMISTIC LOOP
            while (true) {
                // A. Snapshot the world
                const old_ptr = self.ptr.load(.monotonic);

                // B. Create the Future (Allocation)
                const new_ptr = try allocator.create(T);

                // C. Copy History (Clone old data to new)
                new_ptr.* = old_ptr.*;

                // D. Apply Changes (Run the user's logic on the PRIVATE new copy)
                //    We use @call to pass arguments to the update function
                @call(.auto, func, .{new_ptr} ++ args);

                // E. The Commit (Compare and Swap)
                // "If ptr is still old_ptr, replace it with new_ptr."
                // ordering: .release to ensure writes to new_ptr are visible before the swap
                const result = self.ptr.cmpxchgWeak(old_ptr, new_ptr, .release, .monotonic);

                if (result == null) {
                    // Schedule this ptr for deletion
                    try trt.ebr.retire(allocator, old_ptr);
                    return;
                } else {
                    allocator.destroy(new_ptr);
                }
            }
        }
    };
}

// EBR
pub const RetiredPtr = struct {
    ptr: *anyopaque,
    // We need a function pointer to know how to free this specific type later
    deinit_fn: *const fn (allocator: std.mem.Allocator, ptr: *anyopaque) void,

    // We must store the epoch so we know WHEN it was deleted
    epoch: u32,

    // Helper to wrap the type-erasure
    pub fn create(comptime T: type, ptr: *T, epoch: u32) RetiredPtr {
        return .{
            .ptr = ptr,
            .epoch = epoch,
            .deinit_fn = struct {
                fn call(allocator: std.mem.Allocator, p: *anyopaque) void {
                    const typed: *T = @ptrCast(@alignCast(p));
                    allocator.destroy(typed);
                }
            }.call,
        };
    }
};

pub const EbrContext = struct {
    // The Global Clock (0, 1, 2...)
    global_epoch: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    // A registry so the memory reclaimer can find all active threads
    registry_lock: std.Thread.Mutex = .{},
    registry: std.ArrayListUnmanaged(*ThreadLocalEbr) = .{},

    // The Graveyard for dead threads' garbage
    orphans: std.ArrayListUnmanaged(RetiredPtr) = .{},

    pub fn deinit(self: *EbrContext, allocator: std.mem.Allocator) void {
        self.registry.deinit(allocator);
        for (self.orphans.items) |item| {
            item.deinit_fn(allocator, item.ptr);
        }
        self.orphans.deinit(allocator);
    }

    // Register a new thread (We will call this when threads start)
    pub fn register(self: *EbrContext, allocator: std.mem.Allocator, local: *ThreadLocalEbr) !void {
        self.registry_lock.lock();
        defer self.registry_lock.unlock();
        try self.registry.append(allocator, local);
    }

    pub fn unregister(self: *EbrContext, local: *ThreadLocalEbr) void {
        self.registry_lock.lock();
        defer self.registry_lock.unlock();

        // Find the pointer and remove it
        for (self.registry.items, 0..) |item, i| {
            if (item == local) {
                // swapRemove is O(1) - it moves the last item to this spot
                _ = self.registry.swapRemove(i);
                return;
            }
        }
    }

    pub fn dumpTrash(self: *EbrContext, allocator: std.mem.Allocator, trash: []RetiredPtr) !void {
        self.registry_lock.lock();
        defer self.registry_lock.unlock();
        try self.orphans.appendSlice(allocator, trash);
    }

    // You can call this periodically (e.g., every 1000 updates, or on a timer).
    pub fn reclaim(self: *EbrContext, allocator: std.mem.Allocator) void {
        self.registry_lock.lock();
        defer self.registry_lock.unlock();

        // 1. Advance Global Epoch
        const current_global = self.global_epoch.load(.seq_cst);
        var can_advance = true;

        for (self.registry.items) |thread_local| {
            if (thread_local.is_active.load(.seq_cst)) {
                const t_epoch = thread_local.local_epoch.load(.seq_cst);
                if (t_epoch != current_global) {
                    can_advance = false;
                    break;
                }
            }
        }

        if (can_advance) {
            self.global_epoch.store(current_global + 1, .seq_cst);

            // 2. CLEAN ORPHANS ONLY
            // [MOVED] We stopped iterating active threads here. That was the bug.
            const safe_threshold = if (current_global > 1) current_global - 1 else 0;

            var i: usize = 0;
            while (i < self.orphans.items.len) {
                const item = self.orphans.items[i];
                if (item.epoch < safe_threshold) {
                    item.deinit_fn(allocator, item.ptr);
                    _ = self.orphans.swapRemove(i);
                } else {
                    i += 1;
                }
            }
        }
    }
};

pub const ThreadLocalEbr = struct {
    // Things I have deleted but not freed
    limbo_list: std.ArrayListUnmanaged(RetiredPtr) = .{},

    // local_epoch: "The time I saw when I started reading"
    local_epoch: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    // is_active: "I am currently holding a pointer inside a critical section"
    is_active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // link to the global world
    context: *EbrContext,

    pub fn deinit(self: *ThreadLocalEbr, allocator: std.mem.Allocator) void {
        if (self.limbo_list.items.len > 0) {
            // Try to move to global orphans
            self.context.dumpTrash(allocator, self.limbo_list.items) catch {
                // Fallback: If OOM, we must force free to avoid leaks.
                for (self.limbo_list.items) |node| {
                    node.deinit_fn(allocator, node.ptr);
                }
            };
        }
        self.limbo_list.deinit(allocator);
    }

    pub fn retire(self: *ThreadLocalEbr, allocator: std.mem.Allocator, ptr: anytype) !void {
        const T = @TypeOf(ptr.*);
        const current_time = self.local_epoch.load(.monotonic);
        const node = RetiredPtr.create(T, ptr, current_time);
        try self.limbo_list.append(allocator, node);
    }

    pub fn reclaimLocal(self: *ThreadLocalEbr, allocator: std.mem.Allocator) void {
        // Read the global epoch to know what is safe
        const global_epoch = self.context.global_epoch.load(.seq_cst);
        const safe_threshold = if (global_epoch > 1) global_epoch - 1 else 0;

        var i: usize = 0;
        while (i < self.limbo_list.items.len) {
            const item = self.limbo_list.items[i];

            if (item.epoch < safe_threshold) {
                // SAFE TO FREE
                item.deinit_fn(allocator, item.ptr);
                // Safe to modify: We are the only thread touching this list
                _ = self.limbo_list.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    // Signal that we are starting a read
    pub fn enter(self: *ThreadLocalEbr) void {
        // 1. Mark active
        self.is_active.store(true, .seq_cst);

        // 2. Snap to global time
        // We must load global AFTER marking active to ensure we don't miss an epoch change.
        const global = self.context.global_epoch.load(.seq_cst);
        self.local_epoch.store(global, .seq_cst);
    }

    // Signal that we are done
    pub fn exit(self: *ThreadLocalEbr) void {
        self.is_active.store(false, .seq_cst);
    }
};

// -------------------------------------------------------------------------
// Concurrency Primitives (RwLock<T>)
// -------------------------------------------------------------------------

pub fn RwLock(comptime T: type) type {
    return struct {
        lock: std.Thread.RwLock = .{},
        data: T,

        const Self = @This();

        pub fn init(val: T) Self {
            return .{ .data = val };
        }

        // 1. Read Access
        // Allows multiple concurrent readers. Blocks if a Writer is active.
        pub fn read(self: *Self) ReadGuard {
            self.lock.lockShared();
            return ReadGuard{ .parent = self };
        }

        // 2. Write Access
        // Exclusive access. Blocks until all Readers AND Writers are gone.
        pub fn write(self: *Self) WriteGuard {
            self.lock.lock();
            return WriteGuard{ .parent = self };
        }

        pub const ReadGuard = struct {
            parent: *Self,

            // CRITICAL: We only return a CONST pointer here.
            // This prevents the user from accidentally modifying data inside a read lock.
            pub fn get(self: *ReadGuard) *const T {
                return &self.parent.data;
            }

            pub fn release(self: *ReadGuard) void {
                self.parent.lock.unlockShared();
            }
        };

        pub const WriteGuard = struct {
            parent: *Self,

            // Mutable pointer allowed here.
            pub fn get(self: *WriteGuard) *T {
                return &self.parent.data;
            }

            // You can also get const if you want
            pub fn getConst(self: *WriteGuard) *const T {
                return &self.parent.data;
            }

            pub fn release(self: *WriteGuard) void {
                self.parent.lock.unlock();
            }
        };
    };
}

// Fibers
// The registers we need to save.
// This layout matches the assembly exactly.
pub const Context = extern struct {
    sp: u64, // Stack Pointer

    // Callee-saved registers for x86_64
    rbx: u64 = 0,
    rbp: u64 = 0,
    r12: u64 = 0,
    r13: u64 = 0,
    r14: u64 = 0,
    r15: u64 = 0,
};

// 1. Declare the external symbol
// Zig will look for this in the .s file we just created.
extern fn switch_context_asm(from: *Context, to: *Context) callconv(.c) void;

// 2. Public Wrapper
pub fn switchContext(from: *Context, to: *Context) void {
    switch_context_asm(from, to);
}

pub const Stack = struct {
    // The raw slice of memory we own
    memory: []align(4096) u8,

    // The usable size (excluding the guard page)
    usable_len: usize,

    // How big we want the guard to be (usually 4KB, one OS page)
    const PAGE_SIZE: usize = 4096;

    pub fn init(size: usize) !Stack {
        // 1. Round up to page size to keep the OS happy
        const total_size = std.mem.alignForward(usize, size + PAGE_SIZE, PAGE_SIZE);

        // 2. Ask OS for memory
        // PROT_READ | PROT_WRITE: We can read and write
        // MAP_PRIVATE | MAP_ANONYMOUS: Private memory, not backed by a file
        const ptr = try std.posix.mmap(
            null,
            total_size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        );
        const slice = ptr[0..total_size];

        // 3. The Magic: "Poison" the bottom page
        // We tell the OS: "If anyone touches the first 4KB, kill the process."
        // This is our hardware stack-overflow protection.
        try std.posix.mprotect(slice[0..PAGE_SIZE], std.posix.PROT.NONE // No permissions at all
        );

        return Stack{
            .memory = slice,
            .usable_len = total_size - PAGE_SIZE,
        };
    }

    pub fn deinit(self: *Stack) void {
        // Return memory to OS
        std.posix.munmap(self.memory);
    }

    // CRITICAL: Stacks grow DOWN (High -> Low).
    // So the "Start" of the stack is actually the END of the memory block.
    // We return a pointer slightly offset from the top to be safe.
    pub fn getStackTop(self: *Stack) usize {
        const top = @intFromPtr(self.memory.ptr) + self.memory.len;
        // Align to 16 bytes (x64 requirement) and back off a tiny bit
        return (top & ~@as(usize, 15)) - 16;
    }
};

pub const Fiber = struct {
    stack: Stack,
    ctx: Context,
    parent_ctx: *Context, // Who to jump back to when we yield/finish

    pub fn init(stack_size: usize, entry_fn: usize) !Fiber {
        var stack = try Stack.init(stack_size);
        const stack_top = stack.getStackTop();

        // THE TRAMPOLINE:
        // We simulate a "Return Address" on the top of the stack.
        // When switchContext executes 'ret', it will pop this address and jump to it.
        const ptr = @as(*usize, @ptrFromInt(stack_top));
        ptr.* = entry_fn;

        return Fiber{
            .stack = stack,
            // Point SP to the address we just wrote.
            // When 'ret' runs, it pops the value AT this pointer.
            .ctx = Context{ .sp = stack_top },
            .parent_ctx = undefined,
        };
    }

    pub fn deinit(self: *Fiber) void {
        self.stack.deinit();
    }

    // Switch FROM parent TO this fiber
    pub fn switchTo(self: *Fiber, parent: *Context) void {
        self.parent_ctx = parent;
        switchContext(parent, &self.ctx);
    }

    // Switch FROM this fiber BACK to parent
    pub fn yield(self: *Fiber) void {
        switchContext(&self.ctx, self.parent_ctx);
    }

    // Reset the stack pointer and put the entry function back at the top.
    pub fn reset(self: *Fiber, entry_fn: usize) void {
        const stack_top = self.stack.getStackTop();

        // 1. Rewrite the Trampoline (Return Address)
        const ptr = @as(*usize, @ptrFromInt(stack_top));
        ptr.* = entry_fn;

        // 2. Reset the Context Stack Pointer
        self.ctx.sp = stack_top;

        // No need to clear registers; they get overwritten on switchContext
    }
};


pub const TaskStatus = enum {
    Ready,    // Run me again
    Finished, // Recycle me
    Blocked,  // Don't run me, I'm waiting on something
};

pub const TaskConfig = struct {
    timeout_ms: u64 = 0,
};

pub const Task = struct {
    base: Fiber,
    user_fn: *const fn (*Runtime) anyerror!void,
    status: TaskStatus = .Ready,
    config: TaskConfig = .{},
    wake_time: i64 = 0, // Timestamp to wake up (0 = not sleeping - deal with it)
};

pub const Scheduler = struct {
    // 1. The Manager State
    fiber_pool: std.ArrayListUnmanaged(*Task) = .{},
    ready_queue: std.ArrayListUnmanaged(*Task) = .{},
    sleeping_queue: std.ArrayListUnmanaged(*Task) = .{},

    // 2. IO & Memory
    allocator: std.mem.Allocator,
    global_ebr: *EbrContext,
    poller: Poller,

    // 3. Main Thread Context (To return to OS)
    main_ctx: Context,
    current_task: ?*Task,

    // Buffer for epoll events (reused)
    // Max of 128 for now, likely want to increase
    // Only works on Linux
    epoll_events: [128]std.os.linux.epoll_event = undefined,

    active_tasks: usize = 0,

    pub fn init(allocator: std.mem.Allocator, global_ebr: *EbrContext) Scheduler {
        const p = Poller.init() catch unreachable;

        return Scheduler{
            .fiber_pool = .{},
            .ready_queue = .{},
            .sleeping_queue = .{},
            .allocator = allocator,
            .global_ebr = global_ebr,
            .poller = p,
            .main_ctx = undefined,
            .current_task = null,
        };
    }

    pub fn deinit(self: *Scheduler) void {
        // Cleanup all memory
        for (self.fiber_pool.items) |task| {
            task.base.deinit();
            self.allocator.destroy(task);
        }
        self.fiber_pool.deinit(self.allocator);

        for (self.ready_queue.items) |task| {
            task.base.deinit();
            self.allocator.destroy(task);
        }
        self.ready_queue.deinit(self.allocator);

        for (self.sleeping_queue.items) |task| {
            task.base.deinit();
            self.allocator.destroy(task);
        }
        self.sleeping_queue.deinit(self.allocator);

        self.poller.deinit();
    }

    // THE BRIDGE: Connects Fibers to your MVCC Runtime
    pub fn spawn(self: *Scheduler, config: TaskConfig, user_fn: *const fn (*Runtime) anyerror!void) !void {
        var task: *Task = undefined;

        if (self.fiber_pool.items.len > 0) {
            task = self.fiber_pool.pop().?;

            // IMPORTANT: Reset the stack pointer so we start fresh!
            task.base.reset(@intFromPtr(&entryWrapper));

            task.status = .Ready;
        } else {
            // Alloc new Task container
            task = try self.allocator.create(Task);

            // Safety: Handle error if Fiber init fails
            errdefer self.allocator.destroy(task);

            // Alloc 8MB Virtual Stack, pointing to OUR Bootstrap function
            task.base = try Fiber.init(8 * 1024 * 1024, @intFromPtr(&entryWrapper));

            task.status = .Ready;
        }

        // Store the user's function so the wrapper can find it later
        task.user_fn = user_fn;
        task.config = config;

        self.active_tasks += 1;
        try self.ready_queue.append(self.allocator, task);
    }

    pub fn run(self: *Scheduler) void {
       while (true) {
            // Look for beautiful sleeping tasks to wake up
            if (self.sleeping_queue.items.len > 0) {
                const now = std.time.milliTimestamp();
                var i: usize = 0;
                while (i < self.sleeping_queue.items.len) {
                    const task = self.sleeping_queue.items[i];
                    if (now >= task.wake_time) {
                        // WAKE UP, Sleeping Beauty! It's me, your scheduler!
                        // Remove from sleeping queue (O(1) swap remove)
                        _ = self.sleeping_queue.swapRemove(i);

                        // Add to ready queue
                        task.status = .Ready;
                        self.ready_queue.append(self.allocator, task) catch unreachable;

                        // Don't increment 'i' because we just swapped a new item here
                    } else {
                        i += 1;
                    }
                }
            }

            // Look for tasks ready to start:
            if (self.ready_queue.items.len > 0) {
                const task = self.ready_queue.orderedRemove(0);
                self.current_task = task;

                // 1. Switch to the Task
                // The task will resume inside 'entryWrapper' (if new)
                // or wherever it yielded (if old).
                task.base.switchTo(&self.main_ctx);

                switch (task.status) {
                    .Finished => {
                        // Recycle
                        self.active_tasks -= 1;
                        self.fiber_pool.append(self.allocator, task) catch unreachable;
                    },
                    .Ready => {
                        // It yielded, but wants to run again. Put back in queue.
                        self.ready_queue.append(self.allocator, task) catch unreachable;
                    },
                    .Blocked => {
                        // Do nothing! It is now owned by the WaitGroup/Mutex/Etc.
                        // It will be added back to ready_queue by someone else later.
                    }
                }
                continue; // Keep looping if we have work!
            }

            if (self.active_tasks == 0) {
                break;
            }

            // IF IDLE: Poll for IO
            // Determine timeout based on next timer
            // If we have a sleeper in 50ms, poll(50). If empty, poll(-1) [Wait Forever].
            var timeout: i32 = -1;
            if (self.sleeping_queue.items.len > 0) {
                // Simplification: Just poll for 1ms if we have timers pending
                timeout = 1;
            }

            const count = self.poller.poll(&self.epoll_events, timeout);

            if (count > 0) {
                // Wake up tasks waiting on IO!
                for (self.epoll_events[0..count]) |event| {
                    const task_ptr = event.data.ptr;
                    const task = @as(*Task, @ptrFromInt(task_ptr));

                    // Add back to ready queue
                    task.status = .Ready;
                    self.ready_queue.append(self.allocator, task) catch unreachable;
                }
            }

            // If no IO and no Tasks and no Sleepers -> Break
            if (count == 0 and self.ready_queue.items.len == 0 and self.sleeping_queue.items.len == 0) {
                break;
            }
        }
    }

    // Helper to wake a specific fiber
    pub fn schedule(self: *Scheduler, task: *Task) void {
        self.ready_queue.append(self.allocator, task) catch unreachable;
    }

    // Helper to get current task
    pub fn getCurrent(self: *Scheduler) *Task {
        return self.current_task.?;
    }

    // Lay this beautiful task to rest until a specific time
    pub fn sleepTask(self: *Scheduler, task: *Task, wake_time: i64) void {
        task.wake_time = wake_time;
        task.status = .Blocked;
        self.sleeping_queue.append(self.allocator, task) catch unreachable;
    }

    // Helper to do IO
    pub fn registerFd(self: *Scheduler, fd: i32, task: *Task) !void {
        // We cast the task pointer to usize to store it in epoll user_data
        try self.poller.register(fd, @intFromPtr(task));
    }
};

pub const WaitGroup = struct {
    counter: usize = 0,
    waiting_task: ?*Task = null,

    // We need the scheduler to wake people up
    sched: *Scheduler,

    pub fn init(sched: *Scheduler) WaitGroup {
        return .{ .sched = sched };
    }

    pub fn add(self: *WaitGroup, count: usize) void {
        self.counter += count;
    }

    pub fn done(self: *WaitGroup) void {
        self.counter -= 1;
        if (self.counter == 0) {
            if (self.waiting_task) |task| {
                // Wake up the waiter!
                self.sched.schedule(task);
                self.waiting_task = null;
            }
        }
    }

    // This is a blocking call!
    pub fn wait(self: *WaitGroup) void {
        if (self.counter == 0) return;

        var task = self.sched.getCurrent();

        // 1. Mark status as Blocked
        task.status = .Blocked;
        self.waiting_task = task;

        // 2. Yield. The scheduler will see .Blocked and NOT re-queue us.
        task.base.yield();

        // 3. We are back! Reset status for safety
        task.status = .Ready;
    }
};

// Poller lets us make IO & other sys calls without blocking
// Without this, green fibers are pretty much useless
// This only works on Linux for now
pub const Poller = struct {
    epoll_fd: i32,

    // This only works on Linux for now
    pub fn init() !Poller {
        // Create epoll instance
        // flags=0 is standard
        const fd = try std.posix.epoll_create1(0);
        return Poller{ .epoll_fd = fd };
    }

    pub fn deinit(self: *Poller) void {
        std.posix.close(self.epoll_fd);
    }

    // Register a file descriptor (socket) to watch for READ events
    // user_data: We will store the *Task pointer here so we know who to wake up
    // Only works on Linux
    pub fn register(self: *Poller, fd: i32, user_data: usize) !void {
        var event = std.os.linux.epoll_event{
            .events = std.os.linux.EPOLL.IN | std.os.linux.EPOLL.ET, // Read + Edge Triggered
            .data = .{ .ptr = user_data },
        };
        try std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_ADD, fd, &event);
    }

    // Wait for events. Returns the number of events ready.
    // events: A slice to store the results
    // timeout_ms: How long to sleep if nothing happens (-1 = forever, 0 = return immediately)
    // Only works on Linux
    pub fn poll(self: *Poller, events: []std.os.linux.epoll_event, timeout_ms: i32) usize {
        const count = std.os.linux.epoll_wait(self.epoll_fd, events.ptr, @intCast(events.len), timeout_ms);
        return count;
    }
};

// -----------------------------------------------------------------------------
// THE BOOTSTRAP / WRAPPER
// This is a global function (or static method).
// -----------------------------------------------------------------------------

// We need a global pointer to the active scheduler so the wrapper can find context.
// In a real threaded app, this would be thread-local storage.
pub threadlocal var active_scheduler: *Scheduler = undefined;

fn entryWrapper() void {
    // 1. Get the current task info
    const sched = active_scheduler;
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

    var rt = Runtime.initFromSlice(scratchpad_slice, sched.global_ebr, sched.allocator, task.config.timeout_ms) catch unreachable;
    defer rt.deinit();

    // 3. EXECUTE USER CODE
    if (task.user_fn(&rt)) {
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

