const std = @import("std");

pub const default_enabled = true;

test "default is enabled" {
    try std.testing.expect(default_enabled);
}
