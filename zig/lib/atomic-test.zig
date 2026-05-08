//! Tests extracted from lib/atomic.zig.
//!
//! Pre-V33 these tests lived inline at the bottom of atomic.zig.
//! Moving them here keeps production diffs free of test churn.

const std = @import("std");
const atomic = @import("atomic.zig");

const AtomicInt64 = atomic.AtomicInt64;
const AtomicUint64 = atomic.AtomicUint64;
const AtomicFloat64 = atomic.AtomicFloat64;
const AtomicBool = atomic.AtomicBool;

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
    try std.testing.expectEqual(@as(usize, 64), @alignOf(AtomicBool));
}

test "AtomicInt64: fetchXor" {
    var a = AtomicInt64.init(0b1100);
    _ = a.fetchXor(0b1010);
    try std.testing.expectEqual(@as(i64, 0b0110), a.load());
}

test "AtomicInt64: exchange returns old value" {
    var a = AtomicInt64.init(42);
    const old = a.exchange(100);
    try std.testing.expectEqual(@as(i64, 42), old);
    try std.testing.expectEqual(@as(i64, 100), a.load());
}

test "AtomicFloat64: exchange returns old value" {
    var a = AtomicFloat64.init(1.5);
    const old = a.exchange(7.25);
    try std.testing.expectEqual(@as(f64, 1.5), old);
    try std.testing.expectEqual(@as(f64, 7.25), a.load());
}

test "AtomicBool: load/store/exchange round trip" {
    var b = AtomicBool.init(false);
    try std.testing.expectEqual(false, b.load());
    b.store(true);
    try std.testing.expectEqual(true, b.load());
    const old = b.exchange(false);
    try std.testing.expectEqual(true, old);
    try std.testing.expectEqual(false, b.load());
}

test "AtomicBool: cmpxchg success and failure paths" {
    var b = AtomicBool.init(false);
    // success: expected matches
    try std.testing.expectEqual(@as(?bool, null), b.cmpxchgStrong(false, true));
    try std.testing.expectEqual(true, b.load());
    // failure: expected mismatches; returns the actual value
    try std.testing.expectEqual(@as(?bool, true), b.cmpxchgStrong(false, false));
    try std.testing.expectEqual(true, b.load());
}
