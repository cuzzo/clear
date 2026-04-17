const std = @import("std");
const builtin = @import("builtin");

pub const Mutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(self: *Mutex) void {
        std.debug.assert(std.c.pthread_mutex_lock(&self.inner) == .SUCCESS);
    }

    pub fn unlock(self: *Mutex) void {
        std.debug.assert(std.c.pthread_mutex_unlock(&self.inner) == .SUCCESS);
    }

    pub fn tryLock(self: *Mutex) bool {
        return std.c.pthread_mutex_trylock(&self.inner) == .SUCCESS;
    }
};

pub const RwLock = struct {
    inner: std.c.pthread_rwlock_t = .{},

    const PREFER_WRITER_NONRECURSIVE_NP: c_int = 2;

    const pthread_rwlockattr_t = extern struct {
        data: [8]u8 align(@alignOf(c_long)) = [_]u8{0} ** 8,
    };

    extern "c" fn pthread_rwlock_init(rwl: *std.c.pthread_rwlock_t, attr: ?*const pthread_rwlockattr_t) callconv(.c) std.c.E;
    extern "c" fn pthread_rwlockattr_init(attr: *pthread_rwlockattr_t) callconv(.c) std.c.E;
    extern "c" fn pthread_rwlockattr_destroy(attr: *pthread_rwlockattr_t) callconv(.c) std.c.E;
    extern "c" fn pthread_rwlockattr_setkind_np(attr: *pthread_rwlockattr_t, kind: c_int) callconv(.c) std.c.E;

    pub fn init() RwLock {
        var self = RwLock{};
        var attr: pthread_rwlockattr_t = .{};
        var rc = pthread_rwlockattr_init(&attr);
        std.debug.assert(rc == .SUCCESS);
        rc = pthread_rwlockattr_setkind_np(&attr, PREFER_WRITER_NONRECURSIVE_NP);
        std.debug.assert(rc == .SUCCESS);
        rc = pthread_rwlock_init(&self.inner, &attr);
        std.debug.assert(rc == .SUCCESS);
        rc = pthread_rwlockattr_destroy(&attr);
        std.debug.assert(rc == .SUCCESS);
        return self;
    }

    pub fn lock(self: *RwLock) void {
        std.debug.assert(std.c.pthread_rwlock_wrlock(&self.inner) == .SUCCESS);
    }

    pub fn unlock(self: *RwLock) void {
        std.debug.assert(std.c.pthread_rwlock_unlock(&self.inner) == .SUCCESS);
    }

    pub fn lockShared(self: *RwLock) void {
        std.debug.assert(std.c.pthread_rwlock_rdlock(&self.inner) == .SUCCESS);
    }

    pub fn unlockShared(self: *RwLock) void {
        std.debug.assert(std.c.pthread_rwlock_unlock(&self.inner) == .SUCCESS);
    }
};

pub fn RwLocked(comptime T: type) type {
    return struct {
        lock: RwLock = undefined,
        data: T,

        const Self = @This();

        pub fn init(val: T) Self {
            return .{
                .lock = RwLock.init(),
                .data = val,
            };
        }

        pub fn read(self: *Self) ReadGuard {
            self.lock.lockShared();
            return .{ .parent = self };
        }

        pub fn write(self: *Self) WriteGuard {
            self.lock.lock();
            return .{ .parent = self };
        }

        pub const ReadGuard = struct {
            parent: *Self,

            pub fn get(self: *ReadGuard) *const T {
                return &self.parent.data;
            }

            pub fn release(self: *ReadGuard) void {
                self.parent.lock.unlockShared();
            }
        };

        pub const WriteGuard = struct {
            parent: *Self,

            pub fn get(self: *WriteGuard) *T {
                return &self.parent.data;
            }

            pub fn getConst(self: *WriteGuard) *const T {
                return &self.parent.data;
            }

            pub fn release(self: *WriteGuard) void {
                self.parent.lock.unlock();
            }
        };
    };
}

pub fn getenv(name: [*:0]const u8) ?[]const u8 {
    const val = std.c.getenv(name) orelse return null;
    return std.mem.span(val);
}

pub fn sleepNs(ns: u64) void {
    var req = std.c.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    var rem: std.c.timespec = undefined;
    while (std.c.nanosleep(&req, &rem) != 0) {
        req = rem;
    }
}

pub fn milliTimestamp() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @intCast(ts.sec * 1000 + @divFloor(ts.nsec, 1_000_000));
}

pub fn nanoTimestamp() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

/// Drop-in replacement for the removed std.time.Timer.
/// Usage: var t = try Timer.start(); ... const ns = t.read();
pub const Timer = struct {
    start_ns: u64,

    pub fn start() error{}!Timer {
        return .{ .start_ns = nanoTimestamp() };
    }

    pub fn read(self: *Timer) u64 {
        return nanoTimestamp() - self.start_ns;
    }

    pub fn reset(self: *Timer) void {
        self.start_ns = nanoTimestamp();
    }
};

pub fn randomBytes(buf: []u8) !void {
    var filled: usize = 0;
    while (filled < buf.len) {
        const rc = std.c.getrandom(buf[filled..].ptr, buf.len - filled, 0);
        if (rc < 0) return error.Unexpected;
        if (rc == 0) return error.Unexpected;
        filled += @intCast(rc);
    }
}

pub fn eventFd(initval: u32, flags: u32) !std.posix.fd_t {
    const fd = std.c.eventfd(initval, flags);
    if (fd < 0) return error.Unexpected;
    return fd;
}

pub fn socket(domain: c_uint, sock_type: c_uint, protocol: c_uint) !std.posix.fd_t {
    const fd = std.c.socket(domain, sock_type, protocol);
    if (fd < 0) return error.Unexpected;
    return fd;
}

pub fn bind(fd: std.posix.fd_t, addr: *const anyopaque, len: std.posix.socklen_t) !void {
    if (std.c.bind(fd, @ptrCast(@alignCast(addr)), len) != 0) return error.Unexpected;
}

pub fn listen(fd: std.posix.fd_t, backlog: c_uint) !void {
    if (std.c.listen(fd, backlog) != 0) return error.Unexpected;
}

pub fn closeFd(fd: std.posix.fd_t) void {
    _ = std.c.close(fd);
}

pub fn writeFd(fd: std.posix.fd_t, buf: []const u8) !usize {
    const rc = std.c.write(fd, buf.ptr, buf.len);
    if (rc < 0) return error.Unexpected;
    return @intCast(rc);
}

pub fn writeAllFd(fd: std.posix.fd_t, buf: []const u8) !void {
    var written: usize = 0;
    while (written < buf.len) {
        const rc = std.c.write(fd, buf.ptr + written, buf.len - written);
        if (rc < 0) return error.Unexpected;
        written += @intCast(rc);
    }
}

pub fn createFileTruncate(path: [*:0]const u8) !std.posix.fd_t {
    const flags = std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
    const fd = std.c.open(path, @bitCast(flags), @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.Unexpected;
    return fd;
}

pub fn fileSizeFd(fd: std.posix.fd_t) !u64 {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var statx = std.mem.zeroes(linux.Statx);
        switch (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .SIZE = true }, &statx))) {
            .SUCCESS => return statx.size,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }

    const fstat_sym = comptime if (@hasDecl(std.c, "fstat")) std.c.fstat else null;
    if (fstat_sym) |fstat_fn| {
        var stat: std.c.Stat = undefined;
        if (fstat_fn(fd, &stat) != 0) return error.Unexpected;
        return @intCast(stat.size);
    }
    return error.Unexpected;
}
