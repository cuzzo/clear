const std = @import("std");
const builtin = @import("builtin");

pub const Runtime = struct {
    // THE STACK ARENA (Scratchpad)
    // We use a FixedBufferAllocator to simulate the linear stack.
    // It is backed by a raw slice of memory.
    stack_backing: []u8,
    stack_fba: std.heap.FixedBufferAllocator,
    ebr: ThreadLocalEbr,

    // THE HEAP ARENA (Survivor/Request)
    // We use a standard ArenaAllocator. It wraps the OS allocator (page_allocator)
    // and frees everything at once when we call deinit().
    // TODO: probably want this to be a gpa allocator
    heap_arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator, stack_size: usize, global_ctx: *EbrContext) !Runtime {
        // Alloc raw memory for the frame (1MB or whatever passed)
        const stack_mem = try allocator.alloc(u8, stack_size);

        const local_ebr = ThreadLocalEbr{ .context = global_ctx, .limbo_list = .{} };

        return Runtime{
            .stack_backing = stack_mem,
            .stack_fba = std.heap.FixedBufferAllocator.init(stack_mem),
            .heap_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .ebr = local_ebr,
        };
    }

    pub fn deinit(self: *Runtime, allocator: std.mem.Allocator) void {
        self.ebr.deinit(allocator);
        self.heap_arena.deinit();
        allocator.free(self.stack_backing);
    }

    // Stack Helper: Get current Mark (Offset)
    pub fn saveStackMark(self: *Runtime) usize {
        return self.stack_fba.end_index;
    }

    // Stack Helper: Reset to Mark (O(1) Free)
    pub fn restoreStackMark(self: *Runtime, mark: usize) void {
        self.stack_fba.end_index = mark;
    }

    // TODO: Rename -> frameAlloc
    pub fn stackAlloc(self: *Runtime) std.mem.Allocator {
        return self.stack_fba.allocator();
    }

    pub fn heapAlloc(self: *Runtime) std.mem.Allocator {
        return self.heap_arena.allocator();
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
        return try std.mem.concat(allocator, u8, &.{s1, s2});
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
        // If we don't, and 'key' is a stack string that dies, the map breaks.
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
            // so the list doesn't point to stack memory that might die.
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
        child.stdout_behavior = .Pipe;    // Capture StdOut
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

    pub fn spawnThread(sys_allocator: std.mem.Allocator, global_ctx: *EbrContext, stack_size: usize, comptime func: anytype, args: anytype) !std.Thread {
        // We don't call 'func' directly. We call the wrapper.
        // We pass the config + the function + the args TO the wrapper.
        return std.Thread.spawn(.{}, threadWrapper, .{ sys_allocator, global_ctx, stack_size, func, args });
    }

    // THE INTERNAL WRAPPER
    // This runs INSIDE the new thread. It handles the boilerplate.
    fn threadWrapper(allocator: std.mem.Allocator, global_ctx: *EbrContext, stack_size: usize, comptime func: anytype, args: anytype) !void {
        // 1. BOILERPLATE: Setup Runtime
        var rt = try Runtime.init(allocator, stack_size, global_ctx);
        defer rt.deinit(allocator);

        // IMPORTANT: Register this thread with the global context now that `rt` is stable on the stack.
        try global_ctx.register(allocator, &rt.ebr);

        // This runs FIRST (before deinit): Remove from global registry
        // so the GC doesn't try to look at our dead stack.
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

            return Guard{
                .ptr = val,
                .rt = trt
            };
        }

        // The Read Guard
        pub const Guard = struct {
            ptr: *T,
            rt: *Runtime,

            pub fn get(self: *Guard) *T { return self.ptr; }

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
                const result = self.ptr.cmpxchgWeak(
                    old_ptr,
                    new_ptr,
                    .release,
                    .monotonic
                );

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
    deinit_fn: *const fn(allocator: std.mem.Allocator, ptr: *anyopaque) void,

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
        // 1. TRY TO ADVANCE GLOBAL EPOCH
        // We need to see if any threads are lagging behind.
        self.registry_lock.lock();
        defer self.registry_lock.unlock();

        const current_global = self.global_epoch.load(.seq_cst);
        var can_advance = true;

        for (self.registry.items) |thread_local| {
            // If a thread is ACTIVE, it must have caught up to the current epoch.
            if (thread_local.is_active.load(.seq_cst)) {
                const t_epoch = thread_local.local_epoch.load(.seq_cst);
                if (t_epoch != current_global) {
                    can_advance = false;
                    break;
                }
            }
        }

        if (can_advance) {
            // Move time forward!
            // Now 'current_global' becomes 'past'.
            self.global_epoch.store(current_global + 1, .seq_cst);

            // 2. SWEEP TRASH
            // Now that time has moved, we check every thread's limbo list.
            // Any item from (Global - 2) or older is safe to free.
            const safe_threshold = if (current_global > 1) current_global - 1 else 0;

            for (self.registry.items) |thread_local| {
                // We operate on the list tail-backwards or swap-remove to be efficient
                var i: usize = 0;
                while (i < thread_local.limbo_list.items.len) {
                    const item = thread_local.limbo_list.items[i];

                    if (item.epoch < safe_threshold) {
                        // SAFE TO FREE!
                        item.deinit_fn(allocator, item.ptr);

                        // Remove from list (swap with last to be O(1))
                        _ = thread_local.limbo_list.swapRemove(i);
                        // Don't increment 'i' because we just swapped a new item into this slot
                    } else {
                        // Keep it, check next
                        i += 1;
                    }
                }
            }

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
    limbo_list: std.ArrayList(RetiredPtr) = .{},

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

