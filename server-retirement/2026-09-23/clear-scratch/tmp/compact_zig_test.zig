const std = @import("std");
const ds = @import("data-structures.zig");
test "compactList drops absent slots" {
    const alloc = std.testing.allocator;
    var src: [3]?i64 = .{ 1, null, 3 };
    var out = try ds.CheatLib.compactList(alloc, src[0..]);
    defer out.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqual(@as(i64, 1), out.items[0]);
    try std.testing.expectEqual(@as(i64, 3), out.items[1]);
}
