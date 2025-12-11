const std = @import("std");
const builtin = @import("builtin");

pub const Runtime = struct {
    // THE STACK ARENA (Scratchpad)
    // We use a FixedBufferAllocator to simulate the linear stack.
    // It is backed by a raw slice of memory.
    stack_backing: []u8,
    stack_fba: std.heap.FixedBufferAllocator,

    // THE HEAP ARENA (Survivor/Request)
    // We use a standard ArenaAllocator. It wraps the OS allocator (page_allocator)
    // and frees everything at once when we call deinit().
    heap_arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator, stack_size: usize) !Runtime {
        // Alloc raw memory for the stack (1MB or whatever passed)
        const stack_mem = try allocator.alloc(u8, stack_size);

        return Runtime{
            .stack_backing = stack_mem,
            .stack_fba = std.heap.FixedBufferAllocator.init(stack_mem),
            .heap_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        };
    }

    pub fn deinit(self: *Runtime, allocator: std.mem.Allocator) void {
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

    // Helper to get the Allocator interfaces
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
};

