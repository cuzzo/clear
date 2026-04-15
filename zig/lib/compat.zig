const std = @import("std");

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

pub fn eventFd(initval: u32, flags: u32) !std.posix.fd_t {
    const fd = std.c.eventfd(initval, flags);
    if (fd < 0) return error.Unexpected;
    return fd;
}

pub fn closeFd(fd: std.posix.fd_t) void {
    _ = std.c.close(fd);
}

pub fn fileSizeFd(fd: std.posix.fd_t) !u64 {
    const io = std.Options.debug_io;
    const file: std.Io.File = .{
        .handle = fd,
        .flags = .{ .nonblocking = false },
    };
    const stat = try file.stat(io);
    return stat.size;
}
