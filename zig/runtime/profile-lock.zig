const std = @import("std");

pub const SpinLock = struct {
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub inline fn lock(self: *SpinLock) void {
        // LOOM-EXCLUDE-BEGIN: kept on real atomics; contention is hammer-tested
        // HAMMER-WAIT-LOOP-BEGIN: tag=profile-lock.acquire
        while (self.locked.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
        // HAMMER-WAIT-LOOP-END: tag=profile-lock.acquire
        // LOOM-EXCLUDE-END
    }

    pub inline fn unlock(self: *SpinLock) void {
        // LOOM-EXCLUDE-BEGIN: paired real-atomic release is hammer-tested
        self.locked.store(false, .release);
        // LOOM-EXCLUDE-END
    }
};
