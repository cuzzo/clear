const std = @import("std");

pub fn main() void {
    const x = switch (1) {
        1 => 2,
        else => 3,
    };
    if (x == 2) {
    } else if (x == 3) {
    } else {
    }
    while (true) {
        break;
    }
}
