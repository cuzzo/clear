const std = @import("std");
const builtin = @import("builtin");
pub const Runtime = @import("runtime.zig").Runtime;
const fc = @import("fiber-core.zig");
const fp = @import("scheduler.zig");

pub const EbrContext = @import("ebr.zig").EbrContext;
const Task = fc.Task;
const Fiber = fc.Fiber;


// Helper Functions
pub const CheatLib = struct {
    // Mostly for green fibers
    // Read from a non-blocking socket
    // Only works on Linux
    pub fn read(fd: i32, buffer: []u8) !usize {
        const sched = fp.active_scheduler;
        const task = sched.getCurrent();

        while (true) {
            // 1. Try to read using the high-level wrapper
            // This returns an error union (!usize), not a raw number.
            const n = std.posix.read(fd, buffer) catch |err| {
                if (err == error.WouldBlock) {
                    // 2. EAGAIN! No data yet.

                    // Register with Epoll
                    // We catch 'FileDescriptorAlreadyPresent' just in case we loop rapidly
                    try sched.registerFd(fd, task);

                    // Yield (Block)
                    task.status = .Blocked;
                    task.base.yield();

                    // When we wake up, loop back and try read() again!
                    continue;
                }
                // Propagate legitimate errors (e.g. ConnectionReset, etc)
                return err;
            };

            // Success! 'n' is definitely the valid byte count.
            return n;
        }
    }

    // List / Dynamic Array

    pub fn makeList(comptime T: type, allocator: std.mem.Allocator, items: []const T) !std.ArrayListUnmanaged(T) {
        var list = try std.ArrayListUnmanaged(T).initCapacity(allocator, items.len);
        list.appendSliceAssumeCapacity(items);
        return list;
    }

    // Works for ArrayListUnmanaged (has .items) AND Standard Slices (direct access)
    // Also handles casting the index to usize automatically.
    pub fn getAt(container: anytype, index: anytype) @TypeOf(if (@hasField(@TypeOf(container), "items")) container.items[0] else container[0]) {
        const i: usize = @intCast(index); // Auto-cast i64 -> usize

        if (@hasField(@TypeOf(container), "items")) {
            return container.items[i];
        } else {
            return container[i];
        }
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

    pub fn concat(allocator: std.mem.Allocator, s1: []const u8, s2: []const u8) ![]const u8 {
        return try std.mem.concat(allocator, u8, &.{ s1, s2 });
    }

    // Polymorphic Length (Strings or Lists)
    pub fn len(container: anytype) i64 {
        // If it has .items (ArrayList), use that. Otherwise assume it's a Slice.
        if (@hasField(@TypeOf(container), "items")) {
            return @intCast(container.items.len);
        } else {
            return @intCast(container.len);
        }
    }

    // HashMap / Associative Map

    // Usage: var map = try rt.makeMap(i64, rt.heapAlloc());
    pub fn makeHashMap(comptime V: type) !std.StringHashMapUnmanaged(V) {
        // Start empty. Unmanaged maps don't alloc until you put().
        return std.StringHashMapUnmanaged(V){};
    }

    // Usage: try rt.mapPut(i64, rt.heapAlloc(), &map, "key", 100);
    pub fn mapPut(comptime V: type, allocator: std.mem.Allocator, map: *std.StringHashMapUnmanaged(V), key: []const u8, value: V) !void {
        // Check if key already exists - if so, just update the value
        if (map.getPtr(key)) |val_ptr| {
            val_ptr.* = value;
            return;
        }
        // Key doesn't exist - duplicate it to the Heap because the Map keeps a pointer to it.
        // If we don't, and 'key' is a frame string that dies, the map breaks.
        const key_copy = try allocator.dupe(u8, key);
        try map.put(allocator, key_copy, value);
    }

    // Usage: rt.mapGet(i64, map, "key")
    // Smart return: if V is ArrayListUnmanaged(T), returns []T instead of the list struct
    pub fn mapGet(comptime V: type, map: std.StringHashMapUnmanaged(V), key: []const u8) MapGetReturnType(V) {
        const is_array_list = comptime isArrayListUnmanaged(V);

        if (map.get(key)) |val| {
            if (comptime is_array_list) {
                return val.items; // Return slice for ArrayListUnmanaged
            } else {
                return val;
            }
        }

        // Default values based on type
        if (comptime is_array_list) return &[_]ArrayListElement(V){};
        if (V == i64 or V == f64) return 0;
        if (V == []const u8) return "";
        return undefined;
    }

    // Helper: Check if type is ArrayListUnmanaged
    fn isArrayListUnmanaged(comptime T: type) bool {
        if (@typeInfo(T) != .@"struct") return false;
        return @hasField(T, "items") and @hasField(T, "capacity") and !@hasField(T, "allocator");
    }

    // Helper: Get element type from ArrayListUnmanaged
    fn ArrayListElement(comptime T: type) type {
        const items_field = @typeInfo(T).@"struct".fields[0]; // items is first field
        const slice_info = @typeInfo(items_field.type).pointer;
        return slice_info.child;
    }

    // Helper: Compute return type for mapGet
    fn MapGetReturnType(comptime V: type) type {
        if (comptime isArrayListUnmanaged(V)) {
            return []ArrayListElement(V);
        }
        return V;
    }

    // FILE

    // Read File (Allocates on HEAP)
    pub fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
        // 1. Open File
        // Note: We use the absolute path or CWD.
        var dir = std.fs.cwd();
        var file = try dir.openFile(path, .{});
        defer file.close();

        // 2. Stat size to allocate exact buffer
        const stat = try file.stat();

        // 3. Alloc buffer in Heap Arena (Survivor)
        const buffer = try allocator.alloc(u8, stat.size);

        // 4. Read
        _ = try file.readAll(buffer);
        return buffer;
    }

    // Write File
    pub fn writeFile(path: []const u8, content: []const u8) !void {
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

    pub fn substr(allocator: std.mem.Allocator, str: []const u8, start: i64, length: i64) ![]const u8 {
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
    pub fn eql(s1: []const u8, s2: []const u8) bool {
        return std.mem.eql(u8, s1, s2);
    }

    // Split: String -> List
    pub fn split(allocator: std.mem.Allocator, str: []const u8, delimiter: []const u8) !std.ArrayListUnmanaged([]const u8) {
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
    pub fn join(allocator: std.mem.Allocator, list: anytype, delimiter: []const u8) ![]const u8 {
        // Support both ArrayListUnmanaged and raw Slices
        const items = if (@hasField(@TypeOf(list), "items")) list.items else list;
        return std.mem.join(allocator, delimiter, items);
    }

    // shell

    pub fn shell(allocator: std.mem.Allocator, cmd: []const u8) ![]const u8 {
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
    // THE INTERNAL WRAPPER
    // This runs INSIDE the new thread. It handles the boilerplate.
    fn threadWrapper(allocator: std.mem.Allocator, frame_size: usize, global_ctx: *EbrContext, comptime func: anytype, args: anytype) !void {
        // 1. BOILERPLATE: Setup Runtime
        var rt = try Runtime.init(allocator, frame_size, global_ctx);
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
                    .slice => {
                        rt.heapAlloc().free(item);
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
};


