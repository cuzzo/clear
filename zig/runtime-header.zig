const std = @import("std");

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

    pub fn concat(self: *Runtime, allocator: std.mem.Allocator, s1: []const u8, s2: []const u8) ![]const u8 {
        _ = self;
        return try std.mem.concat(allocator, u8, &.{s1, s2});
    }

    // String Lib

    // Used to make HEAP strings
    pub fn makeString(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "{s}", .{text});
    }

    pub fn substr(self: *Runtime, allocator: std.mem.Allocator, str: []const u8, start: i64, len: i64) ![]const u8 {
        _ = self;
        // Basic safety checks (Zig panics on slice OOB, but clean errors are better)
        const u_start: usize = @intCast(start);
        const u_len: usize = @intCast(len);

        if (u_start + u_len > str.len) return error.OutOfBounds;

        // Slicing in Zig is O(1) pointer math!
        const slice = str[u_start .. u_start + u_len];

        // We must COPY it to the new allocator (usually Heap) so it survives
        return allocator.dupe(u8, slice);
    }
};

