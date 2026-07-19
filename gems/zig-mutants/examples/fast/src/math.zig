const std = @import("std");

pub fn less(left: u8, right: u8) bool {
    return left < right;
}

pub fn enabled(flag: bool) bool {
    return flag == true;
}

test "less rejects equal values" {
    try std.testing.expect(less(1, 2));
    try std.testing.expect(!less(2, 2));
}

test "enabled returns its input" {
    try std.testing.expect(enabled(true));
    try std.testing.expect(!enabled(false));
}
