const std = @import("std");

// Register index for RIP
const UNW_REG_IP: c_int = 16;

extern fn unw_init_local(cursor: *anyopaque, context: *anyopaque) c_int;
extern fn unw_step(cursor: *anyopaque) c_int;
extern fn unw_get_reg(cursor: *anyopaque, reg: c_int, val: *usize) c_int;
extern fn unw_get_proc_name(cursor: *anyopaque, bufp: [*]u8, len: usize, offp: *usize) c_int;


var dc: usize = 0;

export fn zig_dump_from_context(context_ptr: *anyopaque) i64 {  // i64 => returns %rax
    // Large aligned buffer for the cursor
    var cursor: [2048]u8 align(64) = undefined;

    dc += 1;
    if (dc > 1) {
       return 1; // error
    }

    if (unw_init_local(&cursor, context_ptr) != 0) return 0;

    std.debug.print("\n=== START UNWIND ===\n", .{});
    var depth: usize = 0;
    while (depth < 10) : (depth += 1) {
        var ip: usize = 0;
        var name_buf: [256]u8 = undefined;
        var off: usize = 0;

        _ = unw_get_reg(&cursor, UNW_REG_IP, &ip);

        if (unw_get_proc_name(&cursor, &name_buf, name_buf.len, &off) == 0) {
            const name = std.mem.sliceTo(&name_buf, 0);
            std.debug.print("#{d}: [0x{x}] {s}+0x{x}\n", .{depth, ip, name, off});
        } else {
            std.debug.print("#{d}: [0x{x}] ???\n", .{depth, ip});
        }

        if (unw_step(&cursor) <= 0) break;
    }

    return 0;
}

extern var breadcrumb_counter: u64;
extern var breadcrumbs: [64]u64;

pub fn printBreadcrumbs() void {
    std.debug.print("Breadcrumbs: ", .{});
    for (0..breadcrumb_counter) |i| {
        std.debug.print("{} ", .{breadcrumbs[i]});
    }
    std.debug.print("\n", .{});
}



extern fn test_macro_chain() i64;
test "Test Working Unwind" {
    // This works
    _ = test_macro_chain();
    printBreadcrumbs();

    // This fails
    const result = test_macro_chain();
    if (result != 0) {
       try std.testing.expectEqual(true, false);
    }
    printBreadcrumbs();
    try std.testing.expectEqual(true, true);
}

