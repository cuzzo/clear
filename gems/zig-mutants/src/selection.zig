const std = @import("std");

const Allocator = std.mem.Allocator;

pub const ChangedRange = struct {
    path: []const u8,
    start_line: usize,
    end_line: usize,
};

pub const ChangedLines = struct {
    allocator: Allocator,
    ranges: []ChangedRange,

    pub fn deinit(self: ChangedLines) void {
        for (self.ranges) |range| self.allocator.free(range.path);
        self.allocator.free(self.ranges);
    }

    pub fn contains(self: ChangedLines, path: []const u8, line: usize) bool {
        const normalized = normalizePath(path);
        for (self.ranges) |range| {
            if (!std.mem.eql(u8, normalized, range.path)) continue;
            if (range.start_line <= line and line <= range.end_line) return true;
        }
        return false;
    }
};

pub fn parseUnifiedDiff(allocator: Allocator, diff: []const u8) !ChangedLines {
    var ranges = std.array_list.Managed(ChangedRange).init(allocator);
    errdefer {
        for (ranges.items) |range| allocator.free(range.path);
        ranges.deinit();
    }

    var current_path: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, diff, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (std.mem.startsWith(u8, line, "+++ ")) {
            const value = std.mem.trim(u8, line[4..], " \t");
            current_path = if (std.mem.eql(u8, value, "/dev/null")) null else normalizePath(diffPath(value));
            continue;
        }
        if (!std.mem.startsWith(u8, line, "@@ ")) continue;
        const path = current_path orelse continue;
        const plus = std.mem.indexOfScalar(u8, line, '+') orelse return error.InvalidDiffHunk;
        const after_plus = line[plus + 1 ..];
        const end = std.mem.indexOfAny(u8, after_plus, " @") orelse return error.InvalidDiffHunk;
        const range_text = after_plus[0..end];
        const comma = std.mem.indexOfScalar(u8, range_text, ',');
        const start_text = if (comma) |index| range_text[0..index] else range_text;
        const count_text = if (comma) |index| range_text[index + 1 ..] else "1";
        const start_line = try std.fmt.parseInt(usize, start_text, 10);
        const count = try std.fmt.parseInt(usize, count_text, 10);
        if (count == 0) continue;
        try ranges.append(.{
            .path = try allocator.dupe(u8, path),
            .start_line = start_line,
            .end_line = start_line + count - 1,
        });
    }

    return .{ .allocator = allocator, .ranges = try ranges.toOwnedSlice() };
}

fn diffPath(value: []const u8) []const u8 {
    const tab = std.mem.indexOfScalar(u8, value, '\t') orelse value.len;
    return value[0..tab];
}

fn normalizePath(path: []const u8) []const u8 {
    var normalized = path;
    while (std.mem.startsWith(u8, normalized, "./")) normalized = normalized[2..];
    if (std.mem.startsWith(u8, normalized, "a/") or std.mem.startsWith(u8, normalized, "b/")) {
        normalized = normalized[2..];
    }
    return normalized;
}

test "parses added and modified Git diff lines" {
    const allocator = std.testing.allocator;
    const diff =
        \\diff --git a/src/math.zig b/src/math.zig
        \\--- a/src/math.zig
        \\+++ b/src/math.zig
        \\@@ -3,2 +3,4 @@
        \\@@ -20 +22 @@
        \\diff --git a/src/old.zig b/src/old.zig
        \\--- a/src/old.zig
        \\+++ /dev/null
        \\@@ -1,5 +0,0 @@
        \\
    ;
    const changed = try parseUnifiedDiff(allocator, diff);
    defer changed.deinit();

    try std.testing.expect(changed.contains("src/math.zig", 3));
    try std.testing.expect(changed.contains("./src/math.zig", 6));
    try std.testing.expect(changed.contains("src/math.zig", 22));
    try std.testing.expect(!changed.contains("src/math.zig", 7));
    try std.testing.expect(!changed.contains("src/old.zig", 1));
}
