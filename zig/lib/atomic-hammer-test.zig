//! Multi-writer hammer tests for AtomicInt(T) / AtomicFloat(T).
//!
//! Each test spawns N OS threads each performing K ops on the shared
//! atomic, then asserts the result is exactly what serial execution
//! would produce. Catches:
//!   - lost updates (non-atomic increment / non-CAS pattern)
//!   - cache-line false-sharing-induced reordering surprises
//!   - bit-pattern bugs in AtomicFloat's CAS loop
//!
//! Iteration counts are tuned to run in ~1s under ReleaseFast on a
//! modern multi-core box. For deeper coverage use the VOPR / Loom
//! tests once they're wired (task #138 part 2).

const std = @import("std");
const atomic = @import("atomic.zig");

const N_WRITERS: usize = 4;
const ITERS_PER_WRITER: usize = 250_000;

// ============================================================
// AtomicInt(i64): fetchAdd hammer.  N writers, K += each, total
// must equal N*K.
// ============================================================

const AddCtxI = struct {
    counter: *atomic.AtomicInt64,
    iters: usize,
};
fn addWriterI(ctx: AddCtxI) void {
    var i: usize = 0;
    while (i < ctx.iters) : (i += 1) _ = ctx.counter.fetchAdd(1);
}

test "AtomicInt64.fetchAdd hammer: N writers, sum == N*K" {
    var counter = atomic.AtomicInt64.init(0);
    var threads: [N_WRITERS]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, addWriterI, .{AddCtxI{
            .counter = &counter,
            .iters = ITERS_PER_WRITER,
        }});
    }
    for (&threads) |*t| t.join();
    try std.testing.expectEqual(
        @as(i64, @intCast(N_WRITERS * ITERS_PER_WRITER)),
        counter.load(),
    );
}

// ============================================================
// AtomicUint64: same hammer, unsigned.
// ============================================================

const AddCtxU = struct {
    counter: *atomic.AtomicUint64,
    iters: usize,
};
fn addWriterU(ctx: AddCtxU) void {
    var i: usize = 0;
    while (i < ctx.iters) : (i += 1) _ = ctx.counter.fetchAdd(1);
}

test "AtomicUint64.fetchAdd hammer: N writers, sum == N*K" {
    var counter = atomic.AtomicUint64.init(0);
    var threads: [N_WRITERS]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, addWriterU, .{AddCtxU{
            .counter = &counter,
            .iters = ITERS_PER_WRITER,
        }});
    }
    for (&threads) |*t| t.join();
    try std.testing.expectEqual(
        @as(u64, N_WRITERS * ITERS_PER_WRITER),
        counter.load(),
    );
}

// ============================================================
// AtomicInt64: fetchOr hammer. Each writer ORs in its bit; final
// value must have all bits set.
// ============================================================

const OrCtx = struct {
    counter: *atomic.AtomicInt64,
    bit: i64,
    iters: usize,
};
fn orWriter(ctx: OrCtx) void {
    var i: usize = 0;
    while (i < ctx.iters) : (i += 1) _ = ctx.counter.fetchOr(ctx.bit);
}

test "AtomicInt64.fetchOr hammer: N writers, all bits set" {
    var counter = atomic.AtomicInt64.init(0);
    var threads: [N_WRITERS]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, orWriter, .{OrCtx{
            .counter = &counter,
            .bit = @as(i64, 1) << @as(u6, @intCast(i)),
            .iters = 10_000,
        }});
    }
    for (&threads) |*t| t.join();
    const expected: i64 = (@as(i64, 1) << N_WRITERS) - 1;
    try std.testing.expectEqual(expected, counter.load());
}

// ============================================================
// AtomicInt64: fetchMax hammer. N writers each submit increasing
// sequences; final value must equal the max ever submitted.
// ============================================================

const MaxCtx = struct {
    counter: *atomic.AtomicInt64,
    base: i64,
    iters: usize,
};
fn maxWriter(ctx: MaxCtx) void {
    var i: i64 = 0;
    while (i < @as(i64, @intCast(ctx.iters))) : (i += 1) {
        ctx.counter.fetchMax(ctx.base + i);
    }
}

test "AtomicInt64.fetchMax hammer: N writers, final == max submitted" {
    var counter = atomic.AtomicInt64.init(std.math.minInt(i64));
    var threads: [N_WRITERS]std.Thread = undefined;
    var max_submitted: i64 = std.math.minInt(i64);
    for (&threads, 0..) |*t, i| {
        const base: i64 = @intCast(i * 1_000_000);
        const submitted_max: i64 = base + @as(i64, @intCast(ITERS_PER_WRITER)) - 1;
        if (submitted_max > max_submitted) max_submitted = submitted_max;
        t.* = try std.Thread.spawn(.{}, maxWriter, .{MaxCtx{
            .counter = &counter,
            .base = base,
            .iters = ITERS_PER_WRITER,
        }});
    }
    for (&threads) |*t| t.join();
    try std.testing.expectEqual(max_submitted, counter.load());
}

// ============================================================
// AtomicFloat64: CAS-loop fetchAdd hammer. N writers add 1.0,
// final must equal N*K (within float precision -- exact for small
// integer sums).
// ============================================================

const AddCtxF = struct {
    counter: *atomic.AtomicFloat64,
    iters: usize,
};
fn addWriterF(ctx: AddCtxF) void {
    var i: usize = 0;
    while (i < ctx.iters) : (i += 1) _ = ctx.counter.fetchAdd(1.0);
}

test "AtomicFloat64.fetchAdd hammer: 4 writers, exact sum" {
    var counter = atomic.AtomicFloat64.init(0.0);
    var threads: [N_WRITERS]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, addWriterF, .{AddCtxF{
            .counter = &counter,
            .iters = ITERS_PER_WRITER,
        }});
    }
    for (&threads) |*t| t.join();
    const expected: f64 = @floatFromInt(N_WRITERS * ITERS_PER_WRITER);
    try std.testing.expectEqual(expected, counter.load());
}

// ============================================================
// AtomicFloat64: fetchMax CAS-loop hammer. Mirrors AtomicInt64's.
// ============================================================

const MaxCtxF = struct {
    counter: *atomic.AtomicFloat64,
    base: f64,
    iters: usize,
};
fn maxWriterF(ctx: MaxCtxF) void {
    var i: usize = 0;
    while (i < ctx.iters) : (i += 1) {
        ctx.counter.fetchMax(ctx.base + @as(f64, @floatFromInt(i)));
    }
}

test "AtomicFloat64.fetchMax hammer: N writers, final == max submitted" {
    var counter = atomic.AtomicFloat64.init(-std.math.inf(f64));
    var threads: [N_WRITERS]std.Thread = undefined;
    var max_submitted: f64 = -std.math.inf(f64);
    for (&threads, 0..) |*t, i| {
        const base: f64 = @floatFromInt(i * 1_000);
        const submitted_max: f64 = base + @as(f64, @floatFromInt(ITERS_PER_WRITER - 1));
        if (submitted_max > max_submitted) max_submitted = submitted_max;
        t.* = try std.Thread.spawn(.{}, maxWriterF, .{MaxCtxF{
            .counter = &counter,
            .base = base,
            .iters = ITERS_PER_WRITER,
        }});
    }
    for (&threads) |*t| t.join();
    try std.testing.expectEqual(max_submitted, counter.load());
}

// ============================================================
// Concurrent-reader monotonicity: 1 writer hammers fetchAdd, 1
// reader observes -- value must never decrease.
// ============================================================

const MonoWriterCtx = struct {
    counter: *atomic.AtomicInt64,
    iters: usize,
    reader_ready: *std.atomic.Value(u8),
    stop: *std.atomic.Value(u8),
};
fn monoWriter(ctx: MonoWriterCtx) void {
    while (ctx.reader_ready.load(.acquire) == 0) std.atomic.spinLoopHint();

    var i: usize = 0;
    while (i < ctx.iters) : (i += 1) _ = ctx.counter.fetchAdd(1);
    ctx.stop.store(1, .release);
}

const MonoReaderResult = struct {
    last: i64 = 0,
    decreases: u32 = 0,
    n_reads: usize = 0,
};
const MonoReaderCtx = struct {
    counter: *atomic.AtomicInt64,
    reader_ready: *std.atomic.Value(u8),
    stop: *std.atomic.Value(u8),
    out: *MonoReaderResult,
};
fn monoReader(ctx: MonoReaderCtx) void {
    var prev = ctx.counter.load();
    var dec: u32 = 0;
    var n: usize = 1;

    ctx.reader_ready.store(1, .release);

    while (ctx.stop.load(.acquire) == 0) : (n += 1) {
        const v = ctx.counter.load();
        if (v < prev) dec += 1;
        prev = v;
    }
    ctx.out.last = prev;
    ctx.out.decreases = dec;
    ctx.out.n_reads = n;
}

test "AtomicInt64: writer monotonic; reader never sees a decrease" {
    var counter = atomic.AtomicInt64.init(0);
    var reader_ready = std.atomic.Value(u8).init(0);
    var stop = std.atomic.Value(u8).init(0);
    var rr = MonoReaderResult{};

    const reader = try std.Thread.spawn(.{}, monoReader, .{MonoReaderCtx{
        .counter = &counter,
        .reader_ready = &reader_ready,
        .stop = &stop,
        .out = &rr,
    }});
    const writer = try std.Thread.spawn(.{}, monoWriter, .{MonoWriterCtx{
        .counter = &counter,
        .iters = 1_000_000,
        .reader_ready = &reader_ready,
        .stop = &stop,
    }});
    writer.join();
    reader.join();

    try std.testing.expectEqual(@as(u32, 0), rr.decreases);
    try std.testing.expectEqual(@as(i64, 1_000_000), counter.load());
    try std.testing.expect(rr.n_reads > 0);
}

// Ordering tests to catch memory ordering weakening mutants under TSan

const OrderCtxInt64_cmpxchgStrong = struct {
    flag: *atomic.AtomicInt64,
    payload: *usize,
};
fn writerInt64_cmpxchgStrong(ctx: OrderCtxInt64_cmpxchgStrong) void {
    ctx.payload.* = 42;
    while (ctx.flag.cmpxchgStrong(0, 1) != null) std.atomic.spinLoopHint();
}
fn readerInt64_cmpxchgStrong(ctx: OrderCtxInt64_cmpxchgStrong) void {
    while (ctx.flag.load() < 1) std.atomic.spinLoopHint();
    if (ctx.payload.* != 42) @panic("memory ordering violation!");
}
test "AtomicInt64 ordering cmpxchgStrong" {
    var flag = atomic.AtomicInt64.init(0);
    var payload: usize = 0;
    const ctx = OrderCtxInt64_cmpxchgStrong{ .flag = &flag, .payload = &payload };
    const r = try std.Thread.spawn(.{}, readerInt64_cmpxchgStrong, .{ctx});
    const w = try std.Thread.spawn(.{}, writerInt64_cmpxchgStrong, .{ctx});
    w.join();
    r.join();
}

const OrderCtxInt64_cmpxchgWeak = struct {
    flag: *atomic.AtomicInt64,
    payload: *usize,
};
fn writerInt64_cmpxchgWeak(ctx: OrderCtxInt64_cmpxchgWeak) void {
    ctx.payload.* = 42;
    while (ctx.flag.cmpxchgWeak(0, 1) != null) std.atomic.spinLoopHint();
}
fn readerInt64_cmpxchgWeak(ctx: OrderCtxInt64_cmpxchgWeak) void {
    while (ctx.flag.load() < 1) std.atomic.spinLoopHint();
    if (ctx.payload.* != 42) @panic("memory ordering violation!");
}
test "AtomicInt64 ordering cmpxchgWeak" {
    var flag = atomic.AtomicInt64.init(0);
    var payload: usize = 0;
    const ctx = OrderCtxInt64_cmpxchgWeak{ .flag = &flag, .payload = &payload };
    const r = try std.Thread.spawn(.{}, readerInt64_cmpxchgWeak, .{ctx});
    const w = try std.Thread.spawn(.{}, writerInt64_cmpxchgWeak, .{ctx});
    w.join();
    r.join();
}

const OrderCtxInt64_fetchMax = struct {
    flag: *atomic.AtomicInt64,
    payload: *usize,
};
fn writerInt64_fetchMax(ctx: OrderCtxInt64_fetchMax) void {
    ctx.payload.* = 42;
    ctx.flag.fetchMax(1);
}
fn readerInt64_fetchMax(ctx: OrderCtxInt64_fetchMax) void {
    while (ctx.flag.load() < 1) std.atomic.spinLoopHint();
    if (ctx.payload.* != 42) @panic("memory ordering violation!");
}
test "AtomicInt64 ordering fetchMax" {
    var flag = atomic.AtomicInt64.init(0);
    var payload: usize = 0;
    const ctx = OrderCtxInt64_fetchMax{ .flag = &flag, .payload = &payload };
    const r = try std.Thread.spawn(.{}, readerInt64_fetchMax, .{ctx});
    const w = try std.Thread.spawn(.{}, writerInt64_fetchMax, .{ctx});
    w.join();
    r.join();
}

const OrderCtxInt64_fetchMin = struct {
    flag: *atomic.AtomicInt64,
    payload: *usize,
};
fn writerInt64_fetchMin(ctx: OrderCtxInt64_fetchMin) void {
    ctx.payload.* = 42;
    ctx.flag.fetchMin(-1);
}
fn readerInt64_fetchMin(ctx: OrderCtxInt64_fetchMin) void {
    while (ctx.flag.load() > -1) std.atomic.spinLoopHint();
    if (ctx.payload.* != 42) @panic("memory ordering violation!");
}
test "AtomicInt64 ordering fetchMin" {
    var flag = atomic.AtomicInt64.init(0);
    var payload: usize = 0;
    const ctx = OrderCtxInt64_fetchMin{ .flag = &flag, .payload = &payload };
    const r = try std.Thread.spawn(.{}, readerInt64_fetchMin, .{ctx});
    const w = try std.Thread.spawn(.{}, writerInt64_fetchMin, .{ctx});
    w.join();
    r.join();
}

const OrderCtxInt64_exchange = struct {
    flag: *atomic.AtomicInt64,
    payload: *usize,
};
fn writerInt64_exchange(ctx: OrderCtxInt64_exchange) void {
    ctx.payload.* = 42;
    _ = ctx.flag.exchange(1);
}
fn readerInt64_exchange(ctx: OrderCtxInt64_exchange) void {
    while (ctx.flag.load() < 1) std.atomic.spinLoopHint();
    if (ctx.payload.* != 42) @panic("memory ordering violation!");
}
test "AtomicInt64 ordering exchange" {
    var flag = atomic.AtomicInt64.init(0);
    var payload: usize = 0;
    const ctx = OrderCtxInt64_exchange{ .flag = &flag, .payload = &payload };
    const r = try std.Thread.spawn(.{}, readerInt64_exchange, .{ctx});
    const w = try std.Thread.spawn(.{}, writerInt64_exchange, .{ctx});
    w.join();
    r.join();
}

const OrderCtxFloat64_cmpxchgStrong = struct {
    flag: *atomic.AtomicFloat64,
    payload: *usize,
};
fn writerFloat64_cmpxchgStrong(ctx: OrderCtxFloat64_cmpxchgStrong) void {
    ctx.payload.* = 42;
    while (ctx.flag.cmpxchgStrong(0.0, 1.0) != null) std.atomic.spinLoopHint();
}
fn readerFloat64_cmpxchgStrong(ctx: OrderCtxFloat64_cmpxchgStrong) void {
    while (ctx.flag.load() < 1.0) std.atomic.spinLoopHint();
    if (ctx.payload.* != 42) @panic("memory ordering violation!");
}
test "AtomicFloat64 ordering cmpxchgStrong" {
    var flag = atomic.AtomicFloat64.init(0.0);
    var payload: usize = 0;
    const ctx = OrderCtxFloat64_cmpxchgStrong{ .flag = &flag, .payload = &payload };
    const r = try std.Thread.spawn(.{}, readerFloat64_cmpxchgStrong, .{ctx});
    const w = try std.Thread.spawn(.{}, writerFloat64_cmpxchgStrong, .{ctx});
    w.join();
    r.join();
}

const OrderCtxFloat64_cmpxchgWeak = struct {
    flag: *atomic.AtomicFloat64,
    payload: *usize,
};
fn writerFloat64_cmpxchgWeak(ctx: OrderCtxFloat64_cmpxchgWeak) void {
    ctx.payload.* = 42;
    while (ctx.flag.cmpxchgWeak(0.0, 1.0) != null) std.atomic.spinLoopHint();
}
fn readerFloat64_cmpxchgWeak(ctx: OrderCtxFloat64_cmpxchgWeak) void {
    while (ctx.flag.load() < 1.0) std.atomic.spinLoopHint();
    if (ctx.payload.* != 42) @panic("memory ordering violation!");
}
test "AtomicFloat64 ordering cmpxchgWeak" {
    var flag = atomic.AtomicFloat64.init(0.0);
    var payload: usize = 0;
    const ctx = OrderCtxFloat64_cmpxchgWeak{ .flag = &flag, .payload = &payload };
    const r = try std.Thread.spawn(.{}, readerFloat64_cmpxchgWeak, .{ctx});
    const w = try std.Thread.spawn(.{}, writerFloat64_cmpxchgWeak, .{ctx});
    w.join();
    r.join();
}

const OrderCtxFloat64_fetchMax = struct {
    flag: *atomic.AtomicFloat64,
    payload: *usize,
};
fn writerFloat64_fetchMax(ctx: OrderCtxFloat64_fetchMax) void {
    ctx.payload.* = 42;
    ctx.flag.fetchMax(1.0);
}
fn readerFloat64_fetchMax(ctx: OrderCtxFloat64_fetchMax) void {
    while (ctx.flag.load() < 1.0) std.atomic.spinLoopHint();
    if (ctx.payload.* != 42) @panic("memory ordering violation!");
}
test "AtomicFloat64 ordering fetchMax" {
    var flag = atomic.AtomicFloat64.init(0.0);
    var payload: usize = 0;
    const ctx = OrderCtxFloat64_fetchMax{ .flag = &flag, .payload = &payload };
    const r = try std.Thread.spawn(.{}, readerFloat64_fetchMax, .{ctx});
    const w = try std.Thread.spawn(.{}, writerFloat64_fetchMax, .{ctx});
    w.join();
    r.join();
}

const OrderCtxFloat64_fetchMin = struct {
    flag: *atomic.AtomicFloat64,
    payload: *usize,
};
fn writerFloat64_fetchMin(ctx: OrderCtxFloat64_fetchMin) void {
    ctx.payload.* = 42;
    ctx.flag.fetchMin(-1.0);
}
fn readerFloat64_fetchMin(ctx: OrderCtxFloat64_fetchMin) void {
    while (ctx.flag.load() > -1.0) std.atomic.spinLoopHint();
    if (ctx.payload.* != 42) @panic("memory ordering violation!");
}
test "AtomicFloat64 ordering fetchMin" {
    var flag = atomic.AtomicFloat64.init(0.0);
    var payload: usize = 0;
    const ctx = OrderCtxFloat64_fetchMin{ .flag = &flag, .payload = &payload };
    const r = try std.Thread.spawn(.{}, readerFloat64_fetchMin, .{ctx});
    const w = try std.Thread.spawn(.{}, writerFloat64_fetchMin, .{ctx});
    w.join();
    r.join();
}

const OrderCtxFloat64_exchange = struct {
    flag: *atomic.AtomicFloat64,
    payload: *usize,
};
fn writerFloat64_exchange(ctx: OrderCtxFloat64_exchange) void {
    ctx.payload.* = 42;
    _ = ctx.flag.exchange(1.0);
}
fn readerFloat64_exchange(ctx: OrderCtxFloat64_exchange) void {
    while (ctx.flag.load() < 1.0) std.atomic.spinLoopHint();
    if (ctx.payload.* != 42) @panic("memory ordering violation!");
}
test "AtomicFloat64 ordering exchange" {
    var flag = atomic.AtomicFloat64.init(0.0);
    var payload: usize = 0;
    const ctx = OrderCtxFloat64_exchange{ .flag = &flag, .payload = &payload };
    const r = try std.Thread.spawn(.{}, readerFloat64_exchange, .{ctx});
    const w = try std.Thread.spawn(.{}, writerFloat64_exchange, .{ctx});
    w.join();
    r.join();
}

const OrderCtxFloat64_fetchAdd = struct {
    flag: *atomic.AtomicFloat64,
    payload: *usize,
};
fn writerFloat64_fetchAdd(ctx: OrderCtxFloat64_fetchAdd) void {
    ctx.payload.* = 42;
    _ = ctx.flag.fetchAdd(1.0);
}
fn readerFloat64_fetchAdd(ctx: OrderCtxFloat64_fetchAdd) void {
    while (ctx.flag.load() < 1.0) std.atomic.spinLoopHint();
    if (ctx.payload.* != 42) @panic("memory ordering violation!");
}
test "AtomicFloat64 ordering fetchAdd" {
    var flag = atomic.AtomicFloat64.init(0.0);
    var payload: usize = 0;
    const ctx = OrderCtxFloat64_fetchAdd{ .flag = &flag, .payload = &payload };
    const r = try std.Thread.spawn(.{}, readerFloat64_fetchAdd, .{ctx});
    const w = try std.Thread.spawn(.{}, writerFloat64_fetchAdd, .{ctx});
    w.join();
    r.join();
}

const OrderCtxBool_cmpxchgStrong = struct {
    flag: *atomic.AtomicBool,
    payload: *usize,
};
fn writerBool_cmpxchgStrong(ctx: OrderCtxBool_cmpxchgStrong) void {
    ctx.payload.* = 42;
    while (ctx.flag.cmpxchgStrong(false, true) != null) std.atomic.spinLoopHint();
}
fn readerBool_cmpxchgStrong(ctx: OrderCtxBool_cmpxchgStrong) void {
    while (ctx.flag.load() == false) std.atomic.spinLoopHint();
    if (ctx.payload.* != 42) @panic("memory ordering violation!");
}
test "AtomicBool ordering cmpxchgStrong" {
    var flag = atomic.AtomicBool.init(false);
    var payload: usize = 0;
    const ctx = OrderCtxBool_cmpxchgStrong{ .flag = &flag, .payload = &payload };
    const r = try std.Thread.spawn(.{}, readerBool_cmpxchgStrong, .{ctx});
    const w = try std.Thread.spawn(.{}, writerBool_cmpxchgStrong, .{ctx});
    w.join();
    r.join();
}

const OrderCtxBool_cmpxchgWeak = struct {
    flag: *atomic.AtomicBool,
    payload: *usize,
};
fn writerBool_cmpxchgWeak(ctx: OrderCtxBool_cmpxchgWeak) void {
    ctx.payload.* = 42;
    while (ctx.flag.cmpxchgWeak(false, true) != null) std.atomic.spinLoopHint();
}
fn readerBool_cmpxchgWeak(ctx: OrderCtxBool_cmpxchgWeak) void {
    while (ctx.flag.load() == false) std.atomic.spinLoopHint();
    if (ctx.payload.* != 42) @panic("memory ordering violation!");
}
test "AtomicBool ordering cmpxchgWeak" {
    var flag = atomic.AtomicBool.init(false);
    var payload: usize = 0;
    const ctx = OrderCtxBool_cmpxchgWeak{ .flag = &flag, .payload = &payload };
    const r = try std.Thread.spawn(.{}, readerBool_cmpxchgWeak, .{ctx});
    const w = try std.Thread.spawn(.{}, writerBool_cmpxchgWeak, .{ctx});
    w.join();
    r.join();
}

const OrderCtxBool_exchange = struct {
    flag: *atomic.AtomicBool,
    payload: *usize,
};
fn writerBool_exchange(ctx: OrderCtxBool_exchange) void {
    ctx.payload.* = 42;
    _ = ctx.flag.exchange(true);
}
fn readerBool_exchange(ctx: OrderCtxBool_exchange) void {
    while (ctx.flag.load() == false) std.atomic.spinLoopHint();
    if (ctx.payload.* != 42) @panic("memory ordering violation!");
}
test "AtomicBool ordering exchange" {
    var flag = atomic.AtomicBool.init(false);
    var payload: usize = 0;
    const ctx = OrderCtxBool_exchange{ .flag = &flag, .payload = &payload };
    const r = try std.Thread.spawn(.{}, readerBool_exchange, .{ctx});
    const w = try std.Thread.spawn(.{}, writerBool_exchange, .{ctx});
    w.join();
    r.join();
}
