const std = @import("std");

pub const SpinLock = struct {
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub inline fn lock(self: *SpinLock) void {
        while (self.locked.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
    }

    pub inline fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};
