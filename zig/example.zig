const std = @import("std");
const Runtime = @import("runtime-header.zig").Runtime;
const EbrContext = @import("runtime-header.zig").EbrContext;


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

    const heap_name = try Runtime.makeString(rt.heapAlloc(), "Brian");

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

    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);

    var rt = try Runtime.init(allocator, 1024 * 1024, &global_ctx);
    defer rt.deinit(allocator);

    std.debug.print("Start Stack Offset: {d}\n", .{rt.stack_fba.end_index});

    // Run Function
    const user = try createUser(&rt);

    std.debug.print("USER NAME: {s}\n", .{user.name});
    std.debug.print("USER ID:   {d}\n", .{user.id});

    std.debug.print("End Stack Offset:   {d} (Should be 0)\n", .{rt.stack_fba.end_index});
}

