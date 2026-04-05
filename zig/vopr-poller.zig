// vopr-poller.zig -- SimPoller: drop-in replacement for scheduler.Poller.
//
// Every register/unregister/poll yields to the Loom coordinator via
// fiber.yield().  This creates yield points at each epoll operation,
// allowing the coordinator to interleave epoll wakeups with RunQueue
// operations from other virtual threads.
//
// No real epoll syscalls -- everything is simulated state.  The
// interleaving is what creates race conditions, not kernel behavior.

const std = @import("std");
const fc = @import("fiber-core.zig");
const qs = @import("queues.zig");

const Task = qs.Task;

/// Yield to the Loom coordinator.  Called at every epoll operation.
/// If not running on a fiber (e.g., during setup), this is a no-op.
fn yieldPoint() void {
    if (fc.__fiber_parent_ctx != null) {
        if (fc.__fiber) |fiber| {
            fiber.yield();
        }
    }
}

/// Simulated fd registration entry.
const SimEpollEntry = struct {
    user_data: usize, // task pointer encoded as usize
    events: u32, // EPOLL.IN, EPOLL.OUT, etc.
    ready: bool, // has the coordinator made this fd ready?
};

/// Drop-in replacement for scheduler.Poller.
/// Same API, simulated state, yields at every operation.
pub const SimPoller = struct {
    epoll_fd: i32, // synthetic identity (matches real Poller field)
    fds: std.AutoHashMapUnmanaged(i32, SimEpollEntry),
    // Pending events set by the coordinator before poll() is called.
    pending_events: std.BoundedArray(std.os.linux.epoll_event, 64),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, identity: i32) SimPoller {
        return .{
            .epoll_fd = identity,
            .fds = .{},
            .pending_events = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SimPoller) void {
        self.fds.deinit(self.allocator);
    }

    // Persistent registration (eventfd, io_uring ring fd).
    // In simulation these are no-ops -- we don't model internal wakeup fds.
    pub fn registerPersistent(self: *SimPoller, fd: i32, user_data: usize) !void {
        _ = self;
        _ = fd;
        _ = user_data;
    }

    // Register fd for read-readiness (EPOLLIN | ONESHOT).
    pub fn register(self: *SimPoller, fd: i32, user_data: usize) !void {
        yieldPoint();
        self.fds.put(self.allocator, fd, .{
            .user_data = user_data,
            .events = std.os.linux.EPOLL.IN,
            .ready = false,
        }) catch unreachable;
    }

    // Register fd for write-readiness (EPOLLOUT | ONESHOT).
    pub fn registerWrite(self: *SimPoller, fd: i32, user_data: usize) !void {
        yieldPoint();
        self.fds.put(self.allocator, fd, .{
            .user_data = user_data,
            .events = std.os.linux.EPOLL.OUT,
            .ready = false,
        }) catch unreachable;
    }

    // Remove fd from epoll.
    pub fn unregister(self: *SimPoller, fd: i32) void {
        yieldPoint();
        _ = self.fds.remove(fd);
    }

    // Poll for events.  The coordinator sets pending_events before
    // resuming the polling thread.  This consumes them (ONESHOT semantics:
    // each fired fd is removed from the registration map).
    pub fn poll(self: *SimPoller, events: []std.os.linux.epoll_event, _: i32) usize {
        yieldPoint();
        const n = @min(self.pending_events.len, events.len);
        for (0..n) |i| {
            events[i] = self.pending_events.buffer[i];
        }
        // ONESHOT: remove fired fds from registration
        for (0..n) |i| {
            const data_ptr = events[i].data.ptr;
            // Find and remove the fd that had this user_data
            var fd_iter = self.fds.iterator();
            while (fd_iter.next()) |entry| {
                if (entry.value_ptr.user_data == data_ptr) {
                    _ = self.fds.remove(entry.key_ptr.*);
                    break;
                }
            }
        }
        self.pending_events.len = 0;
        return n;
    }

    // --- Coordinator API (not part of real Poller) ---

    /// Make an fd ready.  Called by the Loom coordinator to simulate
    /// I/O readiness before the polling thread's next poll() call.
    pub fn makeReady(self: *SimPoller, fd: i32) bool {
        if (self.fds.getPtr(fd)) |entry| {
            if (!entry.ready) {
                entry.ready = true;
                self.pending_events.append(.{
                    .events = entry.events,
                    .data = .{ .ptr = entry.user_data },
                }) catch return false;
                return true;
            }
        }
        return false;
    }

    /// Check if an fd is currently registered.
    pub fn isRegistered(self: *const SimPoller, fd: i32) bool {
        return self.fds.contains(fd);
    }

    /// Get the task pointer for a registered fd (for invariant checking).
    pub fn getTaskForFd(self: *const SimPoller, fd: i32) ?*Task {
        if (self.fds.get(fd)) |entry| {
            return @ptrFromInt(entry.user_data);
        }
        return null;
    }
};
