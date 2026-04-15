const std = @import("std");

pub const Range = struct {
    start: f64,
    end: f64,
    current: f64 = 0,
    started: bool = false,

    pub fn next(self: *Range) anyerror!?f64 {
        return self.nextOrNull();
    }

    pub fn nextOrNull(self: *Range) anyerror!?f64 {
        if (!self.started) {
            self.current = self.start;
            self.started = true;
        }
        if (self.current >= self.end) return null;
        const out = self.current;
        self.current += 1.0;
        return out;
    }

    pub fn toList(self: Range, allocator: std.mem.Allocator) !std.ArrayListUnmanaged(f64) {
        const count = if (self.end > self.start) @as(usize, @intFromFloat(self.end - self.start)) else 0;
        var list = try std.ArrayListUnmanaged(f64).initCapacity(allocator, count);
        var cur = self.start;
        while (cur < self.end) : (cur += 1.0) {
            list.appendAssumeCapacity(cur);
        }
        return list;
    }

    pub fn deinit(self: *Range) void {
        _ = self;
    }
};

pub const IntRange = struct {
    start: i64,
    end: i64,
    current: i64 = 0,
    started: bool = false,

    pub fn next(self: *IntRange) anyerror!?i64 {
        return self.nextOrNull();
    }

    pub fn nextOrNull(self: *IntRange) anyerror!?i64 {
        if (!self.started) {
            self.current = self.start;
            self.started = true;
        }
        if (self.current >= self.end) return null;
        const out = self.current;
        self.current += 1;
        return out;
    }

    pub fn toList(self: IntRange, allocator: std.mem.Allocator) !std.ArrayListUnmanaged(i64) {
        const count = if (self.end > self.start) @as(usize, @intCast(self.end - self.start)) else 0;
        var list = try std.ArrayListUnmanaged(i64).initCapacity(allocator, count);
        var cur = self.start;
        while (cur < self.end) : (cur += 1) {
            list.appendAssumeCapacity(cur);
        }
        return list;
    }

    pub fn deinit(self: *IntRange) void {
        _ = self;
    }
};
