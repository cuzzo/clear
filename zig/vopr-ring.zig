// vopr-ring.zig -- SimRing: drop-in replacement for std.os.linux.IoUring.
//
// Every SQE submission yields to the Loom coordinator via fiber.yield().
// This creates yield points at each io_uring operation, allowing the
// coordinator to interleave operations from different virtual threads.
//
// No real io_uring syscalls -- everything is simulated state. The Loom
// coordinator injects synthetic CQEs via complete() before resuming
// the polling thread.
//
// The API surface matches what scheduler.zig uses from IoUring:
//   init, deinit, fd,
//   read, write, poll_add, poll_remove,
//   accept, connect, recv, send,
//   submit, copy_cqes

const std = @import("std");
const fc = @import("fiber-core.zig");
const linux = std.os.linux;
const posix = std.posix;

/// Yield to the Loom coordinator. Called at every io_uring submission.
/// If not running on a fiber (e.g., during setup), this is a no-op.
fn yieldPoint() void {
    if (fc.__fiber_parent_ctx != null) {
        if (fc.__fiber) |fiber| {
            fiber.yield();
        }
    }
}

/// Tracks a pending SQE (submitted but not yet completed).
const PendingSqe = struct {
    user_data: u64,
    op: OpType,
    fd: i32,
    /// For POLL_ADD: the poll mask (POLLIN, POLLOUT, etc.)
    poll_mask: u32 = 0,
};

const OpType = enum {
    Read,
    Write,
    PollAdd,
    PollRemove,
    Accept,
    Connect,
    Recv,
    Send,
    Timeout,
};

const CAPACITY = 256;

/// Drop-in replacement for std.os.linux.IoUring.
/// Same public API used by scheduler.zig, simulated state, yields at every operation.
pub const SimRing = struct {
    /// Synthetic fd identity (matches IoUring.fd field).
    fd: posix.fd_t,

    /// SQEs queued but not yet submitted (between get_sqe and submit).
    staged_buf: [CAPACITY]PendingSqe = undefined,
    staged_len: u32 = 0,

    /// SQEs submitted (after submit()) but not yet completed.
    /// The coordinator calls complete() to move entries from here to cq.
    pending_buf: [CAPACITY]PendingSqe = undefined,
    pending_len: u32 = 0,

    /// Completion queue -- filled by the coordinator via complete().
    /// Drained by copy_cqes().
    cq_buf: [CAPACITY]linux.io_uring_cqe = undefined,
    cq_len: u32 = 0,

    /// Monotonic counter for synthetic fd identity.
    var next_fd: i32 = 1000;

    pub fn init(_: u32, _: u32) !SimRing {
        const identity = next_fd;
        next_fd += 1;
        return .{ .fd = identity };
    }

    pub fn deinit(_: *SimRing) void {}

    // -----------------------------------------------------------------
    // SQE submission methods
    //
    // Each method stages a PendingSqe. The actual "submission" happens
    // in submit(), which moves staged -> pending and yields.
    // -----------------------------------------------------------------

    fn stageAppend(self: *SimRing, entry: PendingSqe) !void {
        if (self.staged_len >= CAPACITY) return error.SubmissionQueueFull;
        self.staged_buf[self.staged_len] = entry;
        self.staged_len += 1;
    }

    pub fn read(
        self: *SimRing,
        user_data: u64,
        fd: posix.fd_t,
        _: linux.IoUring.ReadBuffer,
        _: u64,
    ) !*linux.io_uring_sqe {
        try self.stageAppend(.{
            .user_data = user_data,
            .op = .Read,
            .fd = fd,
        });
        // SimRing doesn't have real SQEs. Return a dummy pointer.
        // Callers only use the return value to set flags (which we ignore).
        return @ptrFromInt(@intFromPtr(&self.staged_buf) + 1);
    }

    pub fn write(
        self: *SimRing,
        user_data: u64,
        fd: posix.fd_t,
        _: []const u8,
        _: u64,
    ) !*linux.io_uring_sqe {
        try self.stageAppend(.{
            .user_data = user_data,
            .op = .Write,
            .fd = fd,
        });
        return @ptrFromInt(@intFromPtr(&self.staged_buf) + 1);
    }

    pub fn poll_add(
        self: *SimRing,
        user_data: u64,
        fd: posix.fd_t,
        poll_mask: u32,
    ) !*linux.io_uring_sqe {
        try self.stageAppend(.{
            .user_data = user_data,
            .op = .PollAdd,
            .fd = fd,
            .poll_mask = poll_mask,
        });
        return @ptrFromInt(@intFromPtr(&self.staged_buf) + 1);
    }

    pub fn poll_remove(
        self: *SimRing,
        user_data: u64,
        _: u64, // target_user_data to cancel
    ) !*linux.io_uring_sqe {
        try self.stageAppend(.{
            .user_data = user_data,
            .op = .PollRemove,
            .fd = -1,
        });
        return @ptrFromInt(@intFromPtr(&self.staged_buf) + 1);
    }

    pub fn accept(
        self: *SimRing,
        user_data: u64,
        fd: posix.fd_t,
        _: ?*posix.sockaddr,
        _: ?*posix.socklen_t,
        _: u32,
    ) !*linux.io_uring_sqe {
        try self.stageAppend(.{
            .user_data = user_data,
            .op = .Accept,
            .fd = fd,
        });
        return @ptrFromInt(@intFromPtr(&self.staged_buf) + 1);
    }

    pub fn connect(
        self: *SimRing,
        user_data: u64,
        fd: posix.fd_t,
        _: *const posix.sockaddr,
        _: posix.socklen_t,
    ) !*linux.io_uring_sqe {
        try self.stageAppend(.{
            .user_data = user_data,
            .op = .Connect,
            .fd = fd,
        });
        return @ptrFromInt(@intFromPtr(&self.staged_buf) + 1);
    }

    pub fn recv(
        self: *SimRing,
        user_data: u64,
        fd: posix.fd_t,
        _: linux.IoUring.RecvBuffer,
        _: u32,
    ) !*linux.io_uring_sqe {
        try self.stageAppend(.{
            .user_data = user_data,
            .op = .Recv,
            .fd = fd,
        });
        return @ptrFromInt(@intFromPtr(&self.staged_buf) + 1);
    }

    pub fn send(
        self: *SimRing,
        user_data: u64,
        fd: posix.fd_t,
        _: []const u8,
        _: u32,
    ) !*linux.io_uring_sqe {
        try self.stageAppend(.{
            .user_data = user_data,
            .op = .Send,
            .fd = fd,
        });
        return @ptrFromInt(@intFromPtr(&self.staged_buf) + 1);
    }

    pub fn timeout(
        self: *SimRing,
        user_data: u64,
        _: *const linux.kernel_timespec,
        _: u32,
        _: u32,
    ) !*linux.io_uring_sqe {
        try self.stageAppend(.{
            .user_data = user_data,
            .op = .Timeout,
            .fd = -1,
        });
        return @ptrFromInt(@intFromPtr(&self.staged_buf) + 1);
    }

    // -----------------------------------------------------------------
    // submit / copy_cqes
    // -----------------------------------------------------------------

    /// Move all staged SQEs to the pending list (simulates kernel submission).
    /// Yields to the Loom coordinator -- this is the primary yield point.
    pub fn submit(self: *SimRing) !u32 {
        const count = self.staged_len;
        for (self.staged_buf[0..self.staged_len]) |sqe| {
            if (self.pending_len >= CAPACITY) return error.SubmissionQueueFull;
            self.pending_buf[self.pending_len] = sqe;
            self.pending_len += 1;
        }
        self.staged_len = 0;
        yieldPoint();
        return count;
    }

    /// Drain completed CQEs into the caller's buffer.
    /// Returns the number of CQEs copied.
    pub fn copy_cqes(self: *SimRing, cqes: []linux.io_uring_cqe, _: u32) !u32 {
        const n = @min(self.cq_len, @as(u32, @intCast(cqes.len)));
        for (0..n) |i| {
            cqes[i] = self.cq_buf[i];
        }
        // Shift remaining CQEs down
        if (n > 0 and n < self.cq_len) {
            const remaining = self.cq_len - n;
            for (0..remaining) |i| {
                self.cq_buf[i] = self.cq_buf[i + n];
            }
        }
        self.cq_len -= n;
        return n;
    }

    // -----------------------------------------------------------------
    // Coordinator API (not part of real IoUring)
    // -----------------------------------------------------------------

    /// Complete a pending operation by user_data. Removes it from pending
    /// and pushes a CQE with the given result. Returns true if found.
    pub fn complete(self: *SimRing, user_data: u64, result: i32) bool {
        // Find and remove from pending
        for (self.pending_buf[0..self.pending_len], 0..) |entry, i| {
            if (entry.user_data == user_data) {
                // Shift remaining entries down
                const remaining = self.pending_len - @as(u32, @intCast(i)) - 1;
                for (0..remaining) |j| {
                    self.pending_buf[i + j] = self.pending_buf[i + j + 1];
                }
                self.pending_len -= 1;
                if (self.cq_len >= CAPACITY) return false;
                self.cq_buf[self.cq_len] = .{
                    .user_data = user_data,
                    .res = result,
                    .flags = 0,
                };
                self.cq_len += 1;
                return true;
            }
        }
        return false;
    }

    /// Complete ALL pending operations with the given result.
    pub fn completeAll(self: *SimRing, result: i32) u32 {
        var count: u32 = 0;
        for (self.pending_buf[0..self.pending_len]) |entry| {
            if (self.cq_len >= CAPACITY) break;
            self.cq_buf[self.cq_len] = .{
                .user_data = entry.user_data,
                .res = result,
                .flags = 0,
            };
            self.cq_len += 1;
            count += 1;
        }
        self.pending_len = 0;
        return count;
    }

    /// Check if there is a pending operation with the given user_data.
    pub fn hasPending(self: *const SimRing, user_data: u64) bool {
        for (self.pending_buf[0..self.pending_len]) |entry| {
            if (entry.user_data == user_data) return true;
        }
        return false;
    }

    /// Get the number of pending (submitted but not completed) operations.
    pub fn pendingCount(self: *const SimRing) usize {
        return self.pending_len;
    }

    /// Find a pending POLL_ADD for a specific fd. Returns the user_data
    /// (task pointer) if found. Used by Loom scenarios to simulate I/O
    /// readiness on a specific fd.
    pub fn findPollForFd(self: *const SimRing, fd: i32) ?u64 {
        for (self.pending_buf[0..self.pending_len]) |entry| {
            if (entry.op == .PollAdd and entry.fd == fd) return entry.user_data;
        }
        return null;
    }

    /// Cancel a pending operation by user_data (simulates POLL_REMOVE).
    /// Pushes a CQE with -ECANCELED for the cancelled op, and a
    /// success CQE for the remove op itself.
    pub fn cancelByUserData(self: *SimRing, target_user_data: u64, remove_user_data: u64) bool {
        for (self.pending_buf[0..self.pending_len], 0..) |entry, i| {
            if (entry.user_data == target_user_data) {
                // Shift remaining entries down
                const remaining = self.pending_len - @as(u32, @intCast(i)) - 1;
                for (0..remaining) |j| {
                    self.pending_buf[i + j] = self.pending_buf[i + j + 1];
                }
                self.pending_len -= 1;
                // CQE for the cancelled op
                if (self.cq_len < CAPACITY) {
                    self.cq_buf[self.cq_len] = .{
                        .user_data = target_user_data,
                        .res = -@as(i32, @intCast(@intFromEnum(linux.E.CANCELED))),
                        .flags = 0,
                    };
                    self.cq_len += 1;
                }
                // CQE for the POLL_REMOVE op itself (success)
                if (self.cq_len < CAPACITY) {
                    self.cq_buf[self.cq_len] = .{
                        .user_data = remove_user_data,
                        .res = 0,
                        .flags = 0,
                    };
                    self.cq_len += 1;
                }
                return true;
            }
        }
        // Target not found -- CQE with -ENOENT for the remove op
        if (self.cq_len < CAPACITY) {
            self.cq_buf[self.cq_len] = .{
                .user_data = remove_user_data,
                .res = -@as(i32, @intCast(@intFromEnum(linux.E.NOENT))),
                .flags = 0,
            };
            self.cq_len += 1;
        }
        return false;
    }

    /// Reset all state (for Loom scenario reuse).
    pub fn reset(self: *SimRing) void {
        self.staged_len = 0;
        self.pending_len = 0;
        self.cq_len = 0;
    }
};
