const std = @import("std");
const classifier = @import("src/classifier.zig");

test "positive_primary" {
    try std.testing.expectEqualStrings("positive", classifier.classify(5));
}

test "positive_duplicate" {
    try std.testing.expectEqualStrings("positive", classifier.classify(5));
}

test "high" {
    try std.testing.expectEqualStrings("high", classifier.classify(11));
}

test "nonpositive" {
    try std.testing.expectEqualStrings("nonpositive", classifier.classify(0));
}
