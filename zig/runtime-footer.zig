pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var rt = try Runtime.init(allocator, 1024 * 1024);
    defer rt.deinit(allocator);

    // Call the function defined in CHEAT
    const result = try cheatMain(&rt);
    std.debug.print("Result ID: {d}\n", .{result.id});
}

