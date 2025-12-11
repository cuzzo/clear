const std = @import("std");

// -------------------------------------------------------------------------
// 1. The Runtime (Memory Management)
// -------------------------------------------------------------------------

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

    // Used to make HEAP strings
    pub fn makeString(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "{s}", .{text});
    }
};




// -------------------------------------------------------------------------
// 2. User Types
// -------------------------------------------------------------------------

const User = struct {
    id: i64,
    score: i32,
    // Native String! []const u8 is a struct { ptr: [*]u8, len: usize }
    // It fits in registers (16 bytes). No custom struct needed.
    name: []const u8,
};

// -------------------------------------------------------------------------
// 3. The Implementation
// -------------------------------------------------------------------------

pub fn createUser(rt: *Runtime) !*User {
    // 1. MARK STACK (The Kill Zone)
    const frame_mark = rt.saveStackMark();

    // We defer the cleanup so it happens automatically when function returns
    // (This is nicer than manually calling restore_mark at the end)
    defer rt.restoreStackMark(frame_mark);

    const temp_score: i32 = 100;

    // 2. Create a Dynamic List on the STACK
    //    Use ArrayListUnmanaged to avoid storing the allocator in the struct.
    //    This matches your CheatList exactly.
    var list = std.ArrayListUnmanaged(*User){};

    //    Alloc 1,000 temp users in the Kill Zone
    var i: i64 = 0;
    while (i < 1000) : (i += 1) {
        // Alloc Struct in Stack
        const stack_user = try rt.stackAlloc().create(User);

        // Init logic
        stack_user.* = User{
            .id = i,
            .score = 0,
            .name = "Temp", // Pointing to static .rodata (optimization!)
        };

        // Push to list (List grows in Stack Arena)
        try list.append(rt.stackAlloc(), stack_user);
    }

    // 3. Create SURVIVOR in Heap Arena (Request Scope)
    //    Use heapAlloc()
    const heap_user = try rt.heapAlloc().create(User);

    //    Promote String: Copy "Brian" into Heap Arena
    //    (Using a static literal would be faster, but demonstrating allocation)
    const heap_name = try makeString(rt.heapAlloc(), "Brian");

    heap_user.* = User{
        .id = 999,
        .score = temp_score * 2,
        .name = heap_name,
    };

    // 4. PRINT MEMORY STATS
    const current_stack = rt.stack_fba.end_index;
    const current_heap = rt.heap_arena.queryCapacity();

    std.debug.print("--- Memory Report ---\n", .{});
    std.debug.print("Stack Used This Frame: {d} bytes\n", .{current_stack - frame_mark});
    std.debug.print("Total Heap Arena Used: {d} bytes\n", .{current_heap});

    // 5. RETURN
    //    The 'defer' block above runs now, resetting stack to 'frame_mark'.
    //    The 'list' and 'stack_users' are gone.
    //    The 'heap_user' survives.
    return heap_user;
}

// -------------------------------------------------------------------------
// 4. Main Entry Point
// -------------------------------------------------------------------------

pub fn main() !void {
    // Setup OS Allocator (for the backing memory)
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Init Runtime (1MB Stack)
    var rt = try Runtime.init(allocator, 1024 * 1024);
    defer rt.deinit(allocator);

    std.debug.print("Start Stack Offset: {d}\n", .{rt.stack_fba.end_index});

    // Run Function
    const user = try createUser(&rt);

    std.debug.print("USER NAME: {s}\n", .{user.name});
    std.debug.print("USER ID:   {d}\n", .{user.id});

    std.debug.print("End Stack Offset:   {d} (Should be 0)\n", .{rt.stack_fba.end_index});
}

