// bounded-channel-test.zig
// Thorough unit tests for CheatLib.BoundedChannel(T).
//
// Tests are grouped into three tiers:
//   1. Structural (no scheduler) — verify Inner fields and compile-time shape.
//   2. Fast-path (fake sched)   — non-blocking push/pop, FIFO order, close/drain,
//                                 error propagation. The blocking paths are never
//                                 taken when a real scheduler is absent and items
//                                 are already available.
//   3. Scheduler-based          — back pressure, multi-consumer work-stealing,
//                                 close-wakes-blocked-consumers, error-wakes-consumers,
//                                 and full producer->consumers end-to-end.
//
// Run with:
//   zig test zig/runtime/bounded-channel-test.zig -lc zig/runtime/switch.S zig/runtime/onRoot.S
const std = @import("std");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = CheatHeader.Runtime;
const EbrContext = CheatHeader.EbrContext;
const fm = @import("fiber-memory.zig");
const fp = @import("scheduler.zig");
const qs = @import("queues.zig");

// ============================================================================
// Helpers
// ============================================================================

fn fakeSched() *fp.Scheduler {
    return @ptrFromInt(@as(usize, @alignOf(fp.Scheduler)));
}

fn makeInnerDirect(comptime T: type, buf: []T) CheatLib.BoundedChannel(T).Inner {
    return .{
        .buf = buf,
        .mask = buf.len - 1,
        .alloc = std.testing.allocator,
    };
}

// ============================================================================
// Tier 1: Structural tests (no scheduler required)
// ============================================================================

test "BoundedChannel(i64).Inner has expected fields" {
    const BC = CheatLib.BoundedChannel(i64);
    const Inner = BC.Inner;
    const fields = @typeInfo(Inner).@"struct".fields;
    var found_buf = false;
    var found_mask = false;
    var found_head = false;
    var found_tail = false;
    var found_closed = false;
    var found_err = false;
    inline for (fields) |f| {
        if (std.mem.eql(u8, f.name, "buf"))    found_buf    = true;
        if (std.mem.eql(u8, f.name, "mask"))   found_mask   = true;
        if (std.mem.eql(u8, f.name, "head"))   found_head   = true;
        if (std.mem.eql(u8, f.name, "tail"))   found_tail   = true;
        if (std.mem.eql(u8, f.name, "closed")) found_closed = true;
        if (std.mem.eql(u8, f.name, "err"))    found_err    = true;
    }
    try std.testing.expect(found_buf);
    try std.testing.expect(found_mask);
    try std.testing.expect(found_head);
    try std.testing.expect(found_tail);
    try std.testing.expect(found_closed);
    try std.testing.expect(found_err);
}

test "BoundedChannel has consumer_tasks and consumer_scheds parking fields" {
    const BC = CheatLib.BoundedChannel(i64);
    const Inner = BC.Inner;
    const fields = @typeInfo(Inner).@"struct".fields;
    var found_tasks = false;
    var found_scheds = false;
    inline for (fields) |f| {
        if (std.mem.eql(u8, f.name, "consumer_tasks"))  found_tasks  = true;
        if (std.mem.eql(u8, f.name, "consumer_scheds")) found_scheds = true;
    }
    try std.testing.expect(found_tasks);
    try std.testing.expect(found_scheds);
    // Verify MAX_CONSUMERS = 64 via the struct constant.
    try std.testing.expectEqual(@as(usize, 64), BC.MAX_CONSUMERS);
}

test "BoundedChannel(i64) and BoundedChannel(f64) are distinct types" {
    const BC_i = CheatLib.BoundedChannel(i64);
    const BC_f = CheatLib.BoundedChannel(f64);
    try std.testing.expect(BC_i != BC_f);
}

test "BoundedChannel.Inner defaults: head=0, tail=0, closed=false, err=null" {
    var buf = [4]i64{ 0, 0, 0, 0 };
    const inner = makeInnerDirect(i64, &buf);
    try std.testing.expectEqual(@as(usize, 0), inner.head);
    try std.testing.expectEqual(@as(usize, 0), inner.tail);
    try std.testing.expect(!inner.closed);
    try std.testing.expect(inner.err == null);
}

test "BoundedChannel.Inner capacity() returns mask+1" {
    var buf = [8]i64{ 0, 0, 0, 0, 0, 0, 0, 0 };
    var inner = makeInnerDirect(i64, &buf);
    try std.testing.expectEqual(@as(usize, 8), inner.capacity());
}

test "BoundedChannel.Inner used() returns head-tail" {
    var buf = [4]i64{ 0, 0, 0, 0 };
    var inner = makeInnerDirect(i64, &buf);
    inner.head = 3;
    inner.tail = 1;
    try std.testing.expectEqual(@as(usize, 2), inner.used());
}

// ============================================================================
// Tier 2: Fast-path tests (non-blocking — no live scheduler required)
//
// We construct Inner directly (bypassing init) and call push/pop without a
// live scheduler. The blocking branches are unreachable when there is space
// (push) or data (pop) and fp.scheduler_running is false (test harness).
// ============================================================================

test "BoundedChannel: push and pop deliver items FIFO" {
    const alloc = std.testing.allocator;
    var ch = try CheatLib.BoundedChannel(i64).init(alloc, 4);
    defer ch.deinit();

    try ch.push(10);
    try ch.push(20);
    try ch.push(30);

    ch.inner.closed = true; // prevent pop from blocking when ring empties

    try std.testing.expectEqual(@as(?i64, 10), try ch.pop());
    try std.testing.expectEqual(@as(?i64, 20), try ch.pop());
    try std.testing.expectEqual(@as(?i64, 30), try ch.pop());
    try std.testing.expectEqual(@as(?i64, null), try ch.pop()); // drained + closed
}

test "BoundedChannel: push up to capacity without blocking" {
    const alloc = std.testing.allocator;
    var ch = try CheatLib.BoundedChannel(i64).init(alloc, 8);
    defer ch.deinit();

    var i: i64 = 0;
    while (i < 8) : (i += 1) try ch.push(i);

    try std.testing.expectEqual(@as(usize, 8), ch.inner.used());
    try std.testing.expectEqual(@as(usize, 0), ch.inner.tail);
}

test "BoundedChannel: ring wraps around correctly (head/tail modulo mask)" {
    const alloc = std.testing.allocator;
    var ch = try CheatLib.BoundedChannel(i64).init(alloc, 4);
    defer ch.deinit();

    // Fill, drain twice — exercises the wrap-around at index 4.
    for (0..2) |round| {
        const base: i64 = @intCast(round * 4);
        try ch.push(base + 1);
        try ch.push(base + 2);
        try ch.push(base + 3);
        try ch.push(base + 4);

        ch.inner.closed = true; // temporary: allow pop when empty
        try std.testing.expectEqual(@as(?i64, base + 1), try ch.pop());
        try std.testing.expectEqual(@as(?i64, base + 2), try ch.pop());
        try std.testing.expectEqual(@as(?i64, base + 3), try ch.pop());
        try std.testing.expectEqual(@as(?i64, base + 4), try ch.pop());
        ch.inner.closed = false; // reset for next round
    }
    ch.inner.closed = true;
}

test "BoundedChannel: pop returns null immediately when closed and empty" {
    const alloc = std.testing.allocator;
    var ch = try CheatLib.BoundedChannel(i64).init(alloc, 4);
    defer ch.deinit();

    ch.inner.closed = true;
    try std.testing.expectEqual(@as(?i64, null), try ch.pop());
}

test "BoundedChannel: push returns StreamClosed after close()" {
    const alloc = std.testing.allocator;
    var ch = try CheatLib.BoundedChannel(i64).init(alloc, 4);
    defer ch.deinit();

    ch.close();
    try std.testing.expectError(error.StreamClosed, ch.push(42));
}

test "BoundedChannel: pop drains remaining items after close() before returning null" {
    const alloc = std.testing.allocator;
    var ch = try CheatLib.BoundedChannel(i64).init(alloc, 8);
    defer ch.deinit();

    try ch.push(100);
    try ch.push(200);
    ch.close(); // items still in ring

    try std.testing.expectEqual(@as(?i64, 100), try ch.pop());
    try std.testing.expectEqual(@as(?i64, 200), try ch.pop());
    try std.testing.expectEqual(@as(?i64, null), try ch.pop());
}

test "BoundedChannel: setError makes pop return error immediately (skips buffered items)" {
    const alloc = std.testing.allocator;
    var ch = try CheatLib.BoundedChannel(i64).init(alloc, 4);
    defer ch.deinit();

    // Push an item, then signal error. pop() must return the error before
    // delivering the buffered item (error priority over buffered data).
    try ch.push(1);
    ch.setError(error.SomeError);

    try std.testing.expectError(error.SomeError, ch.pop());
    try std.testing.expectError(error.SomeError, ch.pop()); // idempotent
}

test "BoundedChannel: setError makes push return StreamClosed" {
    const alloc = std.testing.allocator;
    var ch = try CheatLib.BoundedChannel(i64).init(alloc, 4);
    defer ch.deinit();

    ch.setError(error.BadInput);
    try std.testing.expectError(error.StreamClosed, ch.push(1));
}

// Note: wakeOneConsumer is an internal helper exercised by the scheduler-based
// multi-consumer test below. No separate unit test needed here.

// wakeAllConsumers and wakeProducer call sched.schedule() and require a real
// scheduler. These behaviors are verified by the scheduler-based tests below.

// ============================================================================
// Tier 3: Scheduler-based tests (live fibers, real blocking)
// ============================================================================

fn schedSetup(alloc: std.mem.Allocator) !struct {
    global: EbrContext,
    rt: Runtime,
    pool: fm.StackPool,
    sched: fp.Scheduler,
} {
    _ = alloc;
    // Return type is anonymous — caller must use var and defer each field.
    unreachable;
}

fn initSchedEnv(
    alloc: std.mem.Allocator,
    global_ctx: *EbrContext,
    stack_pool: *fm.StackPool,
    sched: *fp.Scheduler,
    rt: *Runtime,
) !void {
    global_ctx.* = EbrContext{};
    rt.* = try Runtime.init(alloc, 1024 * 1024, global_ctx);
    rt.wireAllocator();
    stack_pool.* = fm.StackPool.init(alloc);
    sched.* = try fp.Scheduler.init(alloc, global_ctx, stack_pool);
    fp.active_scheduler = sched;
    fp.scheduler_running = true;
}

fn deinitSchedEnv(
    global_ctx: *EbrContext,
    stack_pool: *fm.StackPool,
    sched: *fp.Scheduler,
    rt: *Runtime,
    alloc: std.mem.Allocator,
) void {
    fp.scheduler_running = false;
    sched.deinit();
    stack_pool.deinit();
    fp.global_registry.deinit(alloc);
    rt.deinit();
    global_ctx.deinit(alloc);
}

// ---------------------------------------------------------------------------
// Test: back pressure — producer parks when ring is full; consumer drains one
//       slot and wakes the producer, which completes its push.
// ---------------------------------------------------------------------------

test "BoundedChannel: producer blocks when full, unblocks when consumer pops" {
    const alloc = std.testing.allocator;
    var global_ctx: EbrContext = undefined;
    var stack_pool: fm.StackPool = undefined;
    var sched: fp.Scheduler = undefined;
    var rt: Runtime = undefined;
    try initSchedEnv(alloc, &global_ctx, &stack_pool, &sched, &rt);
    defer deinitSchedEnv(&global_ctx, &stack_pool, &sched, &rt, alloc);

    const Shared = struct {
        ch: CheatLib.BoundedChannel(i64),
        wg: CheatHeader.WaitGroup,
        producer_pushed_5th: bool = false, // set after push(5) completes
        consumer_got: [5]i64 = [_]i64{0} ** 5,
    };
    var shared = Shared{
        .ch = try CheatLib.BoundedChannel(i64).init(alloc, 4),
        .wg = CheatHeader.WaitGroup.init(&sched),
    };
    defer shared.ch.deinit();

    const Producer = struct {
        fn run(_: *Runtime, raw: ?*anyopaque) anyerror!void {
            const s = @as(*Shared, @ptrCast(@alignCast(raw.?)));
            defer s.wg.done();
            // Fill the ring (cap=4): these four pushes succeed immediately.
            try s.ch.push(1);
            try s.ch.push(2);
            try s.ch.push(3);
            try s.ch.push(4);
            // The 5th push should block until the consumer pops one slot.
            try s.ch.push(5);
            s.producer_pushed_5th = true;
            s.ch.close();
        }
    };

    const Consumer = struct {
        fn run(_: *Runtime, raw: ?*anyopaque) anyerror!void {
            const s = @as(*Shared, @ptrCast(@alignCast(raw.?)));
            defer s.wg.done();
            var i: usize = 0;
            while (try s.ch.pop()) |val| : (i += 1) {
                if (i < 5) s.consumer_got[i] = val;
            }
        }
    };

    const Main = struct {
        fn run(_: *Runtime, raw: ?*anyopaque) anyerror!void {
            const s = @as(*Shared, @ptrCast(@alignCast(raw.?)));
            s.wg.add(2);
            try fp.active_scheduler.submitSpawn(
                @intFromPtr(&Runtime.entryWrapper),
                @as(CheatHeader.TaskFn, @ptrCast(&Producer.run)),
                s, .{},
            );
            try fp.active_scheduler.submitSpawn(
                @intFromPtr(&Runtime.entryWrapper),
                @as(CheatHeader.TaskFn, @ptrCast(&Consumer.run)),
                s, .{},
            );
            s.wg.wait();
        }
    };

    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&Main.run)),
        &shared, .{},
    );
    sched.run();

    try std.testing.expect(shared.producer_pushed_5th);
    try std.testing.expectEqualSlices(i64, &[_]i64{1,2,3,4,5}, &shared.consumer_got);
}

// ---------------------------------------------------------------------------
// Test: multiple consumers — 3 workers share a channel of cap 4.
//       Producer pushes 12 items; each item must reach exactly one consumer.
// ---------------------------------------------------------------------------

test "BoundedChannel: 3 consumers share all 12 items with no duplicates" {
    const alloc = std.testing.allocator;
    var global_ctx: EbrContext = undefined;
    var stack_pool: fm.StackPool = undefined;
    var sched: fp.Scheduler = undefined;
    var rt: Runtime = undefined;
    try initSchedEnv(alloc, &global_ctx, &stack_pool, &sched, &rt);
    defer deinitSchedEnv(&global_ctx, &stack_pool, &sched, &rt, alloc);

    const N_ITEMS = 12;
    const N_WORKERS = 3;

    const Shared = struct {
        ch: CheatLib.BoundedChannel(i64),
        wg: CheatHeader.WaitGroup,
        sum: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
        count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    };
    var shared = Shared{
        .ch = try CheatLib.BoundedChannel(i64).init(alloc, 4),
        .wg = CheatHeader.WaitGroup.init(&sched),
    };
    defer shared.ch.deinit();

    const Producer = struct {
        fn run(_: *Runtime, raw: ?*anyopaque) anyerror!void {
            const s = @as(*Shared, @ptrCast(@alignCast(raw.?)));
            defer s.wg.done();
            var i: i64 = 1;
            while (i <= N_ITEMS) : (i += 1) try s.ch.push(i);
            s.ch.close();
        }
    };

    const Worker = struct {
        fn run(_: *Runtime, raw: ?*anyopaque) anyerror!void {
            const s = @as(*Shared, @ptrCast(@alignCast(raw.?)));
            defer s.wg.done();
            while (try s.ch.pop()) |val| {
                _ = s.sum.fetchAdd(val, .seq_cst);
                _ = s.count.fetchAdd(1, .seq_cst);
            }
        }
    };

    const Main = struct {
        fn run(_: *Runtime, raw: ?*anyopaque) anyerror!void {
            const s = @as(*Shared, @ptrCast(@alignCast(raw.?)));
            s.wg.add(1 + N_WORKERS);
            try fp.active_scheduler.submitSpawn(
                @intFromPtr(&Runtime.entryWrapper),
                @as(CheatHeader.TaskFn, @ptrCast(&Producer.run)),
                s, .{},
            );
            for (0..N_WORKERS) |_| {
                try fp.active_scheduler.submitSpawn(
                    @intFromPtr(&Runtime.entryWrapper),
                    @as(CheatHeader.TaskFn, @ptrCast(&Worker.run)),
                    s, .{},
                );
            }
            s.wg.wait();
        }
    };

    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&Main.run)),
        &shared, .{},
    );
    sched.run();

    // Sum 1..12 = 78, count = 12 — verifies each item went to exactly one consumer.
    try std.testing.expectEqual(@as(i64, 78), shared.sum.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 12), shared.count.load(.seq_cst));
}

// ---------------------------------------------------------------------------
// Test: close() wakes consumers blocked on an empty channel.
// ---------------------------------------------------------------------------

test "BoundedChannel: close() unblocks consumers waiting on empty channel" {
    const alloc = std.testing.allocator;
    var global_ctx: EbrContext = undefined;
    var stack_pool: fm.StackPool = undefined;
    var sched: fp.Scheduler = undefined;
    var rt: Runtime = undefined;
    try initSchedEnv(alloc, &global_ctx, &stack_pool, &sched, &rt);
    defer deinitSchedEnv(&global_ctx, &stack_pool, &sched, &rt, alloc);

    const N_CONSUMERS = 3;
    const Shared = struct {
        ch: CheatLib.BoundedChannel(i64),
        wg: CheatHeader.WaitGroup,
        got_null: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    };
    var shared = Shared{
        .ch = try CheatLib.BoundedChannel(i64).init(alloc, 4),
        .wg = CheatHeader.WaitGroup.init(&sched),
    };
    defer shared.ch.deinit();

    const Consumer = struct {
        fn run(_: *Runtime, raw: ?*anyopaque) anyerror!void {
            const s = @as(*Shared, @ptrCast(@alignCast(raw.?)));
            defer s.wg.done();
            // Channel is empty and open — pop must block until close().
            const val = try s.ch.pop();
            if (val == null) _ = s.got_null.fetchAdd(1, .seq_cst);
        }
    };

    const Closer = struct {
        fn run(_: *Runtime, raw: ?*anyopaque) anyerror!void {
            const s = @as(*Shared, @ptrCast(@alignCast(raw.?)));
            defer s.wg.done();
            // Yield to let consumers park first, then close.
            fp.active_scheduler.getCurrent().base.yield();
            s.ch.close();
        }
    };

    const Main = struct {
        fn run(_: *Runtime, raw: ?*anyopaque) anyerror!void {
            const s = @as(*Shared, @ptrCast(@alignCast(raw.?)));
            s.wg.add(N_CONSUMERS + 1);
            for (0..N_CONSUMERS) |_| {
                try fp.active_scheduler.submitSpawn(
                    @intFromPtr(&Runtime.entryWrapper),
                    @as(CheatHeader.TaskFn, @ptrCast(&Consumer.run)),
                    s, .{},
                );
            }
            try fp.active_scheduler.submitSpawn(
                @intFromPtr(&Runtime.entryWrapper),
                @as(CheatHeader.TaskFn, @ptrCast(&Closer.run)),
                s, .{},
            );
            s.wg.wait();
        }
    };

    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&Main.run)),
        &shared, .{},
    );
    sched.run();

    try std.testing.expectEqual(@as(usize, N_CONSUMERS), shared.got_null.load(.seq_cst));
}

// ---------------------------------------------------------------------------
// Test: setError() wakes blocked consumers with the error.
// ---------------------------------------------------------------------------

test "BoundedChannel: setError() unblocks consumers with the error" {
    const alloc = std.testing.allocator;
    var global_ctx: EbrContext = undefined;
    var stack_pool: fm.StackPool = undefined;
    var sched: fp.Scheduler = undefined;
    var rt: Runtime = undefined;
    try initSchedEnv(alloc, &global_ctx, &stack_pool, &sched, &rt);
    defer deinitSchedEnv(&global_ctx, &stack_pool, &sched, &rt, alloc);

    const Shared = struct {
        ch: CheatLib.BoundedChannel(i64),
        wg: CheatHeader.WaitGroup,
        got_error: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    };
    var shared = Shared{
        .ch = try CheatLib.BoundedChannel(i64).init(alloc, 4),
        .wg = CheatHeader.WaitGroup.init(&sched),
    };
    defer shared.ch.deinit();

    const Consumer = struct {
        fn run(_: *Runtime, raw: ?*anyopaque) anyerror!void {
            const s = @as(*Shared, @ptrCast(@alignCast(raw.?)));
            defer s.wg.done();
            if (s.ch.pop()) |_| {} else |err| {
                if (err == error.ProducerFailed) {
                    s.got_error.store(true, .seq_cst);
                }
            }
        }
    };

    const ErrorSignaler = struct {
        fn run(_: *Runtime, raw: ?*anyopaque) anyerror!void {
            const s = @as(*Shared, @ptrCast(@alignCast(raw.?)));
            defer s.wg.done();
            fp.active_scheduler.getCurrent().base.yield(); // let consumer park first
            s.ch.setError(error.ProducerFailed);
        }
    };

    const Main = struct {
        fn run(_: *Runtime, raw: ?*anyopaque) anyerror!void {
            const s = @as(*Shared, @ptrCast(@alignCast(raw.?)));
            s.wg.add(2);
            try fp.active_scheduler.submitSpawn(
                @intFromPtr(&Runtime.entryWrapper),
                @as(CheatHeader.TaskFn, @ptrCast(&Consumer.run)),
                s, .{},
            );
            try fp.active_scheduler.submitSpawn(
                @intFromPtr(&Runtime.entryWrapper),
                @as(CheatHeader.TaskFn, @ptrCast(&ErrorSignaler.run)),
                s, .{},
            );
            s.wg.wait();
        }
    };

    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&Main.run)),
        &shared, .{},
    );
    sched.run();

    try std.testing.expect(shared.got_error.load(.seq_cst));
}

test "BoundedChannel: setError() unblocks a producer waiting on full channel" {
    const alloc = std.testing.allocator;
    const Shared = struct {
        ch: CheatLib.BoundedChannel(i64),
        producer_filled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        producer_saw_closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    };
    var shared = Shared{
        .ch = try CheatLib.BoundedChannel(i64).init(alloc, 4),
    };
    defer shared.ch.deinit();

    const Producer = struct {
        fn run(s: *Shared) void {
            s.ch.push(1) catch return;
            s.ch.push(2) catch return;
            s.ch.push(3) catch return;
            s.ch.push(4) catch return;
            s.producer_filled.store(true, .release);
            s.ch.push(5) catch |err| {
                if (err == error.StreamClosed) s.producer_saw_closed.store(true, .seq_cst);
                return;
            };
        }
    };

    var th = try std.Thread.spawn(.{}, Producer.run, .{&shared});
    while (!shared.producer_filled.load(.acquire)) std.Thread.yield() catch {};
    shared.ch.setError(error.ProducerFailed);
    th.join();

    try std.testing.expect(shared.producer_saw_closed.load(.seq_cst));
}

test "BoundedChannel: independent channels drain concurrently without deadlock" {
    const alloc = std.testing.allocator;
    var global_ctx: EbrContext = undefined;
    var stack_pool: fm.StackPool = undefined;
    var sched: fp.Scheduler = undefined;
    var rt: Runtime = undefined;
    try initSchedEnv(alloc, &global_ctx, &stack_pool, &sched, &rt);
    defer deinitSchedEnv(&global_ctx, &stack_pool, &sched, &rt, alloc);

    const N_CHANS = 4;
    const N_ITEMS = 64;
    const Shared = struct {
        chans: [N_CHANS]CheatLib.BoundedChannel(i64),
        wg: CheatHeader.WaitGroup,
        delivered: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        sum: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    };
    var shared = Shared{
        .chans = undefined,
        .wg = CheatHeader.WaitGroup.init(&sched),
    };
    for (0..N_CHANS) |i| shared.chans[i] = try CheatLib.BoundedChannel(i64).init(alloc, 8);
    defer for (0..N_CHANS) |i| shared.chans[i].deinit();

    const PairCtx = struct { s: *Shared, idx: usize };
    const Bundle = struct {
        s: *Shared,
        producers: *[N_CHANS]PairCtx,
        consumers: *[N_CHANS]PairCtx,
    };

    const Producer = struct {
        fn run(_: *Runtime, raw: ?*anyopaque) anyerror!void {
            const ctx = @as(*PairCtx, @ptrCast(@alignCast(raw.?)));
            defer ctx.s.wg.done();
            var i: i64 = 0;
            while (i < N_ITEMS) : (i += 1) {
                try ctx.s.chans[ctx.idx].push(@as(i64, @intCast(ctx.idx * N_ITEMS)) + i);
            }
            ctx.s.chans[ctx.idx].close();
        }
    };

    const Consumer = struct {
        fn run(_: *Runtime, raw: ?*anyopaque) anyerror!void {
            const ctx = @as(*PairCtx, @ptrCast(@alignCast(raw.?)));
            defer ctx.s.wg.done();
            while (try ctx.s.chans[ctx.idx].pop()) |val| {
                _ = ctx.s.delivered.fetchAdd(1, .seq_cst);
                _ = ctx.s.sum.fetchAdd(val, .seq_cst);
            }
        }
    };

    var producer_ctxs: [N_CHANS]PairCtx = undefined;
    var consumer_ctxs: [N_CHANS]PairCtx = undefined;

    const Main = struct {
        fn run(_: *Runtime, raw: ?*anyopaque) anyerror!void {
            const bundle = @as(*Bundle, @ptrCast(@alignCast(raw.?)));
            bundle.s.wg.add(N_CHANS * 2);
            for (0..N_CHANS) |i| {
                bundle.producers[i] = .{ .s = bundle.s, .idx = i };
                bundle.consumers[i] = .{ .s = bundle.s, .idx = i };
                try fp.active_scheduler.submitSpawn(
                    @intFromPtr(&Runtime.entryWrapper),
                    @as(CheatHeader.TaskFn, @ptrCast(&Producer.run)),
                    &bundle.producers[i], .{},
                );
                try fp.active_scheduler.submitSpawn(
                    @intFromPtr(&Runtime.entryWrapper),
                    @as(CheatHeader.TaskFn, @ptrCast(&Consumer.run)),
                    &bundle.consumers[i], .{},
                );
            }
            bundle.s.wg.wait();
        }
    };

    var bundle = Bundle{ .s = &shared, .producers = &producer_ctxs, .consumers = &consumer_ctxs };
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&Main.run)),
        &bundle, .{},
    );
    sched.run();

    const expected_count = N_CHANS * N_ITEMS;
    const last: i64 = @intCast(expected_count - 1);
    try std.testing.expectEqual(@as(usize, expected_count), shared.delivered.load(.seq_cst));
    try std.testing.expectEqual(@divExact(last * (last + 1), 2), shared.sum.load(.seq_cst));
}

// ---------------------------------------------------------------------------
// Test: back pressure ordering — large item count with small ring; verify all
//       items arrive exactly once and in-order (single consumer).
// ---------------------------------------------------------------------------

test "BoundedChannel: 1000 items through cap=8 ring arrive in order" {
    const alloc = std.testing.allocator;
    var global_ctx: EbrContext = undefined;
    var stack_pool: fm.StackPool = undefined;
    var sched: fp.Scheduler = undefined;
    var rt: Runtime = undefined;
    try initSchedEnv(alloc, &global_ctx, &stack_pool, &sched, &rt);
    defer deinitSchedEnv(&global_ctx, &stack_pool, &sched, &rt, alloc);

    const N: i64 = 1000;
    const Shared = struct {
        ch: CheatLib.BoundedChannel(i64),
        wg: CheatHeader.WaitGroup,
        ok: bool = false,
    };
    var shared = Shared{
        .ch = try CheatLib.BoundedChannel(i64).init(alloc, 8),
        .wg = CheatHeader.WaitGroup.init(&sched),
    };
    defer shared.ch.deinit();

    const Producer = struct {
        fn run(_: *Runtime, raw: ?*anyopaque) anyerror!void {
            const s = @as(*Shared, @ptrCast(@alignCast(raw.?)));
            defer s.wg.done();
            var i: i64 = 0;
            while (i < N) : (i += 1) try s.ch.push(i);
            s.ch.close();
        }
    };

    const Consumer = struct {
        fn run(_: *Runtime, raw: ?*anyopaque) anyerror!void {
            const s = @as(*Shared, @ptrCast(@alignCast(raw.?)));
            defer s.wg.done();
            var expected: i64 = 0;
            while (try s.ch.pop()) |val| : (expected += 1) {
                if (val != expected) return;
            }
            if (expected == N) s.ok = true;
        }
    };

    const Main = struct {
        fn run(_: *Runtime, raw: ?*anyopaque) anyerror!void {
            const s = @as(*Shared, @ptrCast(@alignCast(raw.?)));
            s.wg.add(2);
            try fp.active_scheduler.submitSpawn(
                @intFromPtr(&Runtime.entryWrapper),
                @as(CheatHeader.TaskFn, @ptrCast(&Producer.run)),
                s, .{},
            );
            try fp.active_scheduler.submitSpawn(
                @intFromPtr(&Runtime.entryWrapper),
                @as(CheatHeader.TaskFn, @ptrCast(&Consumer.run)),
                s, .{},
            );
            s.wg.wait();
        }
    };

    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&Main.run)),
        &shared, .{},
    );
    sched.run();

    try std.testing.expect(shared.ok);
}

// ---------------------------------------------------------------------------
// Test: producer closes before any consumer pops — items still delivered.
// ---------------------------------------------------------------------------

test "BoundedChannel: items pushed before close() are delivered to late consumer" {
    const alloc = std.testing.allocator;
    var global_ctx: EbrContext = undefined;
    var stack_pool: fm.StackPool = undefined;
    var sched: fp.Scheduler = undefined;
    var rt: Runtime = undefined;
    try initSchedEnv(alloc, &global_ctx, &stack_pool, &sched, &rt);
    defer deinitSchedEnv(&global_ctx, &stack_pool, &sched, &rt, alloc);

    const Shared = struct {
        ch: CheatLib.BoundedChannel(i64),
        wg: CheatHeader.WaitGroup,
        total: i64 = 0,
    };
    var shared = Shared{
        .ch = try CheatLib.BoundedChannel(i64).init(alloc, 8),
        .wg = CheatHeader.WaitGroup.init(&sched),
    };
    defer shared.ch.deinit();

    const Producer = struct {
        fn run(_: *Runtime, raw: ?*anyopaque) anyerror!void {
            const s = @as(*Shared, @ptrCast(@alignCast(raw.?)));
            defer s.wg.done();
            try s.ch.push(10);
            try s.ch.push(20);
            try s.ch.push(30);
            s.ch.close();
        }
    };

    const Consumer = struct {
        fn run(_: *Runtime, raw: ?*anyopaque) anyerror!void {
            const s = @as(*Shared, @ptrCast(@alignCast(raw.?)));
            defer s.wg.done();
            while (try s.ch.pop()) |val| s.total += val;
        }
    };

    const Main = struct {
        fn run(_: *Runtime, raw: ?*anyopaque) anyerror!void {
            const s = @as(*Shared, @ptrCast(@alignCast(raw.?)));
            s.wg.add(2);
            try fp.active_scheduler.submitSpawn(
                @intFromPtr(&Runtime.entryWrapper),
                @as(CheatHeader.TaskFn, @ptrCast(&Producer.run)),
                s, .{},
            );
            try fp.active_scheduler.submitSpawn(
                @intFromPtr(&Runtime.entryWrapper),
                @as(CheatHeader.TaskFn, @ptrCast(&Consumer.run)),
                s, .{},
            );
            s.wg.wait();
        }
    };

    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&Main.run)),
        &shared, .{},
    );
    sched.run();

    try std.testing.expectEqual(@as(i64, 60), shared.total);
}
