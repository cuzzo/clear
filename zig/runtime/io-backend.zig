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
        if (!have_io_uring) return openPipe();
        const flags = std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK | std.os.linux.EFD.SEMAPHORE;
        const fd = try compat.eventFd(0, flags);
        return .{ .read_fd = fd, .write_fd = fd };
    }

    // The no-eventfd shape: a pipe, with both ends non-blocking so a full
    // pipe never stalls a producer and a spurious wake never leaves the
    // scheduler blocked in read().
    fn openPipe() !WakeFd {
        var fds: [2]i32 = .{ -1, -1 };
        const libc = struct {
            extern "c" fn pipe(f: *[2]i32) i32;
            extern "c" fn fcntl(fd: i32, cmd: i32, arg: i32) i32;
        };
        if (libc.pipe(&fds) != 0) return error.Unexpected;
        const F_SETFL = 4;
        const O_NONBLOCK = 0x0004; // Darwin/BSD value
        _ = libc.fcntl(fds[0], F_SETFL, O_NONBLOCK);
        _ = libc.fcntl(fds[1], F_SETFL, O_NONBLOCK);
        return .{ .read_fd = fds[0], .write_fd = fds[1] };
    }

    pub fn close(self: *WakeFd) void {
        if (self.read_fd < 0) return; // already closed
        compat.closeFd(self.read_fd);
        // Only when the two ends are DISTINCT: on Linux both fields hold the
        // one eventfd, and closing it twice would hand the second close a
        // descriptor number the kernel may already have reused.
        if (self.write_fd != self.read_fd) compat.closeFd(self.write_fd);
        // Invalidate, so a second close is a no-op rather than closing an
        // unrelated file that inherited these numbers.
        self.read_fd = -1;
        self.write_fd = -1;
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

    // The single owner of `scratch`. The IoUring interface hands back a *Sqe
    // that the caller may still write (the scheduler sets .len for multishot),
    // so every submission shim returns this one slot.
    //
    // Static analysis flags `scratch` as eliminable state, written and read
    // only here. It is NOT eliminable: this returns a POINTER that outlives
    // the call, so a local would dangle the moment sqeSlot returned.
    fn sqeSlot(self: *PollRing) *Sqe {
        self.scratch = .{};
        return &self.scratch;
    }

    // Take-and-clear: the queued timeout is read and consumed as ONE step, so
    // the local cannot be mistaken for a value that went stale.
    //
    // Staleness analysis reads this as "ns derived from pending_timeout_ns,
    // which is then reassigned without recomputing ns". That is the intent:
    // ns is deliberately the value from BEFORE the clear.
    fn takePendingTimeout(self: *PollRing) u64 {
        const ns = self.pending_timeout_ns;
        self.pending_timeout_ns = 0;
        return ns;
    }

    pub fn deinit(self: *PollRing) void {
        self.* = .{};
    }

    // The scheduler registers its wake fd once, with a multishot poll.
    pub fn poll_add(self: *PollRing, user_data: u64, fd: std.posix.fd_t, mask: u32) !*Sqe {
        _ = user_data;
        _ = mask;
        self.wake_fd = fd;
        return self.sqeSlot();
    }

    pub fn timeout(self: *PollRing, user_data: u64, ts: *const KernelTimespec, count: u32, flags: u32) !*Sqe {
        _ = user_data;
        _ = count;
        _ = flags;
        const secs: i128 = @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
        self.pending_timeout_ns = if (secs <= 0) 0 else @intCast(secs);
        return self.sqeSlot();
    }

    pub fn submit(self: *PollRing) !u32 {
        _ = self;
        return 0;
    }

    // Returns 0 completions always: this backend never produces I/O results.
    // With wait_nr > 0 it blocks first, so the scheduler idles instead of
    // spinning, waking on the wake fd or when the queued timeout expires.
    // How long one park may last, in milliseconds. A 50ms CEILING keeps a
    // missed wake from hanging the process; a 1ms FLOOR keeps a
    // sub-millisecond request from truncating to zero under integer division
    // and turning the scheduler's idle path into a busy spin. A zero request
    // means "no deadline", which parks for the ceiling.
    pub fn parkMillis(timeout_ns: u64) i32 {
        if (timeout_ns == 0) return 50;
        const want = (timeout_ns + 999_999) / 1_000_000;
        return @intCast(@max(@as(u64, 1), @min(@as(u64, 50), want)));
    }

    pub fn copy_cqes(self: *PollRing, cqes: []Cqe, wait_nr: u32) !u32 {
        _ = cqes;
        // Consume the queued timeout on EVERY path, including the
        // non-blocking one, or it leaks into the next park.
        const timeout_ns = self.takePendingTimeout();
        if (wait_nr == 0) return 0;
        self.park(parkMillis(timeout_ns));
        return 0;
    }

    // Block until the wake fd is readable or the interval elapses. Returns no
    // completions either way: this backend never produces I/O results.
    fn park(self: *PollRing, ms: i32) void {
        if (self.wake_fd < 0) {
            // No wake fd registered yet: sleep the interval rather than spin.
            const libc_sleep = struct {
                extern "c" fn usleep(usec: u32) c_int;
            };
            _ = libc_sleep.usleep(@as(u32, @intCast(ms)) * 1000);
            return;
        }
        const libc = struct {
            extern "c" fn poll(fds: *Pollfd, nfds: c_ulong, timeout: c_int) c_int;
        };
        var pfd = Pollfd{ .fd = self.wake_fd, .events = POLL_IN, .revents = 0 };
        _ = libc.poll(&pfd, 1, ms);
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
