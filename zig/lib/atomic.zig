//! Lock-free integer/float primitives — CLEAR's equivalent of Go's
//! `sync/atomic.Int64` and Rust's `core::sync::atomic::AtomicI64`.
//!
//! Each type wraps a single `std.atomic.Value(T)` aligned to a 64-byte
//! cache line. All operations are inlinable; on x86 the hot path is a
//! single `mov` (load), `mov` (store), or `lock xadd`/`lock cmpxchg`.
//!
//! These are the only atomic-scalar primitives in the runtime. The
//! observable accumulators (`ObservableSum`, `ObservableMax`,
//! `ObservableCount`, `ObservableAvg`, `ObservableReduce`,
//! `ObservableAny`, `ObservableAll`, `ObservableFind`) compose on top
//! of these by adding the producer-side completion handle and (where
//! relevant) a `seen` flag for `started()`. See `observable.zig`.

const std = @import("std");

/// Generic integer atomic. Cache-line aligned. The 64-bit aliases
/// `AtomicInt64` / `AtomicUint64` (declared below) match Go's
/// `atomic.Int64`/`atomic.Uint64` surface.
pub fn AtomicInt(comptime T: type) type {
    const ti = @typeInfo(T);
    if (ti != .int and ti != .comptime_int)
        @compileError("AtomicInt: T must be an integer type");
    return struct {
        value: std.atomic.Value(T) align(64) = .{ .raw = 0 },

        const Self = @This();

        pub inline fn load(self: *const Self) T {
            return self.value.load(.acquire);
        }
        pub inline fn loadRelaxed(self: *const Self) T {
            return self.value.load(.monotonic);
        }
        pub inline fn store(self: *Self, v: T) void {
            self.value.store(v, .release);
        }
        pub inline fn storeRelaxed(self: *Self, v: T) void {
            self.value.store(v, .monotonic);
        }
        pub inline fn fetchAdd(self: *Self, delta: T) T {
            return self.value.fetchAdd(delta, .monotonic);
        }
        pub inline fn fetchSub(self: *Self, delta: T) T {
            return self.value.fetchSub(delta, .monotonic);
        }
        pub inline fn fetchOr(self: *Self, mask: T) T {
            return self.value.fetchOr(mask, .monotonic);
        }
        pub inline fn fetchAnd(self: *Self, mask: T) T {
            return self.value.fetchAnd(mask, .monotonic);
        }
        pub inline fn fetchMax(self: *Self, v: T) void {
            var current = self.value.load(.acquire);
            while (true) {
                if (!(v > current)) return;
                if (self.value.cmpxchgWeak(current, v, .release, .acquire)) |actual| {
                    current = actual;
                } else return;
            }
        }
        pub inline fn fetchMin(self: *Self, v: T) void {
            var current = self.value.load(.acquire);
            while (true) {
                if (!(v < current)) return;
                if (self.value.cmpxchgWeak(current, v, .release, .acquire)) |actual| {
                    current = actual;
                } else return;
            }
        }
        pub inline fn cmpxchgStrong(self: *Self, expected: T, new: T) ?T {
            return self.value.cmpxchgStrong(expected, new, .release, .acquire);
        }
        pub inline fn cmpxchgWeak(self: *Self, expected: T, new: T) ?T {
            return self.value.cmpxchgWeak(expected, new, .release, .acquire);
        }
        pub inline fn init(initial: T) Self {
            return .{ .value = .{ .raw = initial } };
        }
    };
}

/// Generic float atomic. CAS-loop on the matching unsigned-int bit
/// pattern (Zig's atomic CAS doesn't accept floats directly).
pub fn AtomicFloat(comptime T: type) type {
    const ti = @typeInfo(T);
    if (ti != .float)
        @compileError("AtomicFloat: T must be a float type");
    const Backing = switch (@bitSizeOf(T)) {
        32 => u32,
        64 => u64,
        else => @compileError("AtomicFloat: only 32- and 64-bit floats supported"),
    };
    return struct {
        value: std.atomic.Value(Backing) align(64) = .{ .raw = 0 },

        const Self = @This();

        pub inline fn load(self: *const Self) T {
            return @bitCast(self.value.load(.acquire));
        }
        pub inline fn loadRelaxed(self: *const Self) T {
            return @bitCast(self.value.load(.monotonic));
        }
        pub inline fn store(self: *Self, v: T) void {
            self.value.store(@bitCast(v), .release);
        }
        pub inline fn fetchAdd(self: *Self, delta: T) T {
            var current_bits = self.value.load(.acquire);
            while (true) {
                const current: T = @bitCast(current_bits);
                const next: T = current + delta;
                const next_bits: Backing = @bitCast(next);
                if (self.value.cmpxchgWeak(current_bits, next_bits, .release, .acquire)) |actual| {
                    current_bits = actual;
                } else return current;
            }
        }
        pub inline fn fetchMax(self: *Self, v: T) void {
            var current_bits = self.value.load(.acquire);
            while (true) {
                const current: T = @bitCast(current_bits);
                if (!(v > current)) return;
                const v_bits: Backing = @bitCast(v);
                if (self.value.cmpxchgWeak(current_bits, v_bits, .release, .acquire)) |actual| {
                    current_bits = actual;
                } else return;
            }
        }
        pub inline fn fetchMin(self: *Self, v: T) void {
            var current_bits = self.value.load(.acquire);
            while (true) {
                const current: T = @bitCast(current_bits);
                if (!(v < current)) return;
                const v_bits: Backing = @bitCast(v);
                if (self.value.cmpxchgWeak(current_bits, v_bits, .release, .acquire)) |actual| {
                    current_bits = actual;
                } else return;
            }
        }
        /// CAS on the float bit-pattern. Returns null on success,
        /// the actual current value on failure (mirrors std).
        pub inline fn cmpxchgWeak(self: *Self, expected: T, new: T) ?T {
            const e_bits: Backing = @bitCast(expected);
            const n_bits: Backing = @bitCast(new);
            const result = self.value.cmpxchgWeak(e_bits, n_bits, .release, .acquire);
            if (result) |actual| return @as(T, @bitCast(actual));
            return null;
        }
        pub inline fn cmpxchgStrong(self: *Self, expected: T, new: T) ?T {
            const e_bits: Backing = @bitCast(expected);
            const n_bits: Backing = @bitCast(new);
            const result = self.value.cmpxchgStrong(e_bits, n_bits, .release, .acquire);
            if (result) |actual| return @as(T, @bitCast(actual));
            return null;
        }
        pub inline fn init(initial: T) Self {
            return .{ .value = .{ .raw = @bitCast(initial) } };
        }
    };
}

/// Go-style aliases.
pub const AtomicInt64 = AtomicInt(i64);
pub const AtomicUint64 = AtomicInt(u64);
pub const AtomicInt32 = AtomicInt(i32);
pub const AtomicUint32 = AtomicInt(u32);
pub const AtomicFloat64 = AtomicFloat(f64);
pub const AtomicFloat32 = AtomicFloat(f32);

// =============================================================
// Tests
// =============================================================

test "AtomicInt64: load + fetchAdd basic" {
    var a = AtomicInt64.init(0);
    try std.testing.expectEqual(@as(i64, 0), a.load());
    _ = a.fetchAdd(7);
    try std.testing.expectEqual(@as(i64, 7), a.load());
    _ = a.fetchAdd(-2);
    try std.testing.expectEqual(@as(i64, 5), a.load());
}

test "AtomicInt64: fetchMax / fetchMin" {
    var a = AtomicInt64.init(10);
    a.fetchMax(5);
    try std.testing.expectEqual(@as(i64, 10), a.load());
    a.fetchMax(20);
    try std.testing.expectEqual(@as(i64, 20), a.load());
    a.fetchMin(15);
    try std.testing.expectEqual(@as(i64, 15), a.load());
    a.fetchMin(100);
    try std.testing.expectEqual(@as(i64, 15), a.load());
}

test "AtomicInt64: fetchOr / fetchAnd" {
    var a = AtomicInt64.init(0b1100);
    _ = a.fetchOr(0b0011);
    try std.testing.expectEqual(@as(i64, 0b1111), a.load());
    _ = a.fetchAnd(0b0101);
    try std.testing.expectEqual(@as(i64, 0b0101), a.load());
}

test "AtomicUint64: fetchAdd" {
    var a = AtomicUint64.init(0);
    _ = a.fetchAdd(100);
    try std.testing.expectEqual(@as(u64, 100), a.load());
}

test "AtomicFloat64: load + fetchAdd basic" {
    var a = AtomicFloat64.init(0.0);
    try std.testing.expectEqual(@as(f64, 0.0), a.load());
    _ = a.fetchAdd(1.5);
    try std.testing.expectEqual(@as(f64, 1.5), a.load());
    _ = a.fetchAdd(-0.5);
    try std.testing.expectEqual(@as(f64, 1.0), a.load());
}

test "AtomicFloat64: fetchMax / fetchMin" {
    var a = AtomicFloat64.init(2.5);
    a.fetchMax(1.0);
    try std.testing.expectEqual(@as(f64, 2.5), a.load());
    a.fetchMax(3.0);
    try std.testing.expectEqual(@as(f64, 3.0), a.load());
    a.fetchMin(2.5);
    try std.testing.expectEqual(@as(f64, 2.5), a.load());
}

test "alignment: aliases are 64-byte aligned" {
    try std.testing.expectEqual(@as(usize, 64), @alignOf(AtomicInt64));
    try std.testing.expectEqual(@as(usize, 64), @alignOf(AtomicFloat64));
    try std.testing.expectEqual(@as(usize, 64), @alignOf(AtomicUint64));
}
