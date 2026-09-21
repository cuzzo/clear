// Platform selection for the scheduler's completion ring.
//
// The scheduler is built on io_uring, which exists only on Linux. Everything
// Linux-specific it touches is named here once, so the scheduler itself has no
// `std.os.linux` in it and a non-Linux target gets a working substitute rather
// than a compile error. On Linux every alias below IS the std type, chosen at
// comptime, so Linux codegen is unchanged.
//
// The substitute is deliberately NOT an async I/O backend. It supports exactly
// what a compute-only CLEAR program needs -- park until woken or until a
// timeout expires -- and reports AsyncIoUnsupported for socket and file
// submissions. A real macOS port would put a kqueue backend here, behind this
// same interface; nothing outside this file would change.
const std = @import("std");
const builtin = @import("builtin");
const compat = @import("../lib/compat.zig");

pub const have_io_uring = builtin.os.tag == .linux;

pub const Cqe = if (have_io_uring) std.os.linux.io_uring_cqe else extern struct {
    user_data: u64 = 0,
    res: i32 = 0,
    flags: u32 = 0,
};

pub const KernelTimespec = if (have_io_uring) std.os.linux.kernel_timespec else extern struct {
    sec: i64 = 0,
    nsec: i64 = 0,
};

pub const Sqe = if (have_io_uring) std.os.linux.io_uring_sqe else struct {
    // The scheduler sets `.len` on the poll_add SQE to ask for multishot.
    len: u32 = 0,
};

pub const POLL_IN: i16 = if (have_io_uring) @intCast(std.os.linux.POLL.IN) else 1;
pub const POLL_ADD_MULTI: u32 = if (have_io_uring) std.os.linux.IORING_POLL_ADD_MULTI else 0;

// A wake channel the ring can block on. On Linux this is the eventfd the
// scheduler already used; elsewhere it is a pipe, because there is no eventfd
// and a pipe is the portable one-writer/one-reader wakeup.
pub const WakeFd = struct {
    read_fd: std.posix.fd_t = -1,
    write_fd: std.posix.fd_t = -1,

    pub fn open() !WakeFd {
        if (have_io_uring) {
            const flags = std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK | std.os.linux.EFD.SEMAPHORE;
            const fd = try compat.eventFd(0, flags);
            return .{ .read_fd = fd, .write_fd = fd };
        }
        var fds: [2]i32 = .{ -1, -1 };
        const libc = struct {
            extern "c" fn pipe(f: *[2]i32) i32;
            extern "c" fn fcntl(fd: i32, cmd: i32, arg: i32) i32;
        };
        if (libc.pipe(&fds) != 0) return error.Unexpected;
        // Non-blocking both ends: a full pipe must never stall a producer, and
        // a spurious wake must never leave the scheduler blocked in read().
        const F_SETFL = 4;
        const O_NONBLOCK = 0x0004; // Darwin/BSD value
        _ = libc.fcntl(fds[0], F_SETFL, O_NONBLOCK);
        _ = libc.fcntl(fds[1], F_SETFL, O_NONBLOCK);
        return .{ .read_fd = fds[0], .write_fd = fds[1] };
    }

    pub fn close(self: *WakeFd) void {
        compat.closeFd(self.read_fd);
        if (self.write_fd != self.read_fd) compat.closeFd(self.write_fd);
    }
};

// Poll-based stand-in for IoUring. Blocking is the only behaviour the
// scheduler's idle path actually needs from the ring on a compute-only run.
pub const PollRing = struct {
    wake_fd: std.posix.fd_t = -1,
    pending_timeout_ns: u64 = 0,
    scratch: Sqe = .{},

    pub fn init(entries: u16, flags: u32) !PollRing {
        _ = entries;
        _ = flags;
        return .{};
    }

    pub fn deinit(self: *PollRing) void {
        self.* = .{};
    }

    // The scheduler registers its wake fd once, with a multishot poll.
    pub fn poll_add(self: *PollRing, user_data: u64, fd: std.posix.fd_t, mask: u32) !*Sqe {
        _ = user_data;
        _ = mask;
        self.wake_fd = fd;
        self.scratch = .{};
        return &self.scratch;
    }

    pub fn timeout(self: *PollRing, user_data: u64, ts: *const KernelTimespec, count: u32, flags: u32) !*Sqe {
        _ = user_data;
        _ = count;
        _ = flags;
        const secs: i128 = @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
        self.pending_timeout_ns = if (secs <= 0) 0 else @intCast(secs);
        self.scratch = .{};
        return &self.scratch;
    }

    pub fn submit(self: *PollRing) !u32 {
        _ = self;
        return 0;
    }

    // Returns 0 completions always: this backend never produces I/O results.
    // With wait_nr > 0 it blocks first, so the scheduler idles instead of
    // spinning, waking on the wake fd or when the queued timeout expires.
    pub fn copy_cqes(self: *PollRing, cqes: []Cqe, wait_nr: u32) !u32 {
        _ = cqes;
        const timeout_ns = self.pending_timeout_ns;
        self.pending_timeout_ns = 0;
        if (wait_nr == 0) return 0;

        // A 50ms ceiling keeps a missed wake from hanging the process, and a
        // 1ms floor keeps a sub-millisecond timeout from truncating to 0 and
        // turning this park into a busy spin.
        const ms: i32 = if (timeout_ns == 0) 50 else blk: {
            const want = (timeout_ns + 999_999) / 1_000_000;
            break :blk @intCast(@max(@as(u64, 1), @min(@as(u64, 50), want)));
        };
        if (self.wake_fd < 0) {
            // No wake fd registered yet: sleep the interval rather than spin.
            const libc_sleep = struct {
                extern "c" fn usleep(usec: u32) c_int;
            };
            _ = libc_sleep.usleep(@as(u32, @intCast(ms)) * 1000);
            return 0;
        }
        const libc = struct {
            extern "c" fn poll(fds: *Pollfd, nfds: c_ulong, timeout: c_int) c_int;
        };
        var pfd = Pollfd{ .fd = self.wake_fd, .events = POLL_IN, .revents = 0 };
        _ = libc.poll(&pfd, 1, ms);
        return 0;
    }

    pub fn read(self: *PollRing, user_data: u64, fd: std.posix.fd_t, buffer: anytype, offset: u64) !*Sqe {
        _ = .{ self, user_data, fd, buffer, offset };
        return error.AsyncIoUnsupported;
    }
    pub fn write(self: *PollRing, user_data: u64, fd: std.posix.fd_t, buffer: []const u8, offset: u64) !*Sqe {
        _ = .{ self, user_data, fd, buffer, offset };
        return error.AsyncIoUnsupported;
    }
    pub fn recv(self: *PollRing, user_data: u64, fd: std.posix.fd_t, buffer: anytype, flags: u32) !*Sqe {
        _ = .{ self, user_data, fd, buffer, flags };
        return error.AsyncIoUnsupported;
    }
    pub fn send(self: *PollRing, user_data: u64, fd: std.posix.fd_t, buffer: []const u8, flags: u32) !*Sqe {
        _ = .{ self, user_data, fd, buffer, flags };
        return error.AsyncIoUnsupported;
    }
    pub fn accept(self: *PollRing, user_data: u64, fd: std.posix.fd_t, addr: ?*anyopaque, addrlen: ?*anyopaque, flags: u32) !*Sqe {
        _ = .{ self, user_data, fd, addr, addrlen, flags };
        return error.AsyncIoUnsupported;
    }
    pub fn connect(self: *PollRing, user_data: u64, fd: std.posix.fd_t, addr: anytype, addr_len: anytype) !*Sqe {
        _ = .{ self, user_data, fd, addr, addr_len };
        return error.AsyncIoUnsupported;
    }
};

const Pollfd = extern struct {
    fd: i32,
    events: i16,
    revents: i16,
};

pub const DefaultRing = if (have_io_uring) std.os.linux.IoUring else PollRing;
