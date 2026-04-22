pub const CLEAR_FRAME_DEBUG = false;

const std = @import("std");
const fm = @import("runtime/fiber-memory.zig");
const fp = @import("runtime/scheduler.zig");
const ebr_mod = @import("lib/ebr.zig");
const CheatHeader = @import("runtime/runtime-header.zig");
const pl = @import("lib/parking-lot.zig");

const compat = @import("lib/compat.zig");
const Runtime = CheatHeader.Runtime;
const EbrContext = CheatHeader.EbrContext;
const ParkingMutex = pl.ParkingMutex;
const ParkingRwLock = pl.ParkingRwLock;
const ParkingRwLocked = pl.ParkingRwLocked;

fn initSched(t_alloc: std.mem.Allocator, ebr: *EbrContext, sp: *fm.StackPool) !fp.Scheduler {
    return fp.Scheduler.init(t_alloc, ebr, sp);
}

// ─────────────────────────────────────────────────────────────────────────────
// ParkingMutex tests
// ─────────────────────────────────────────────────────────────────────────────

test "ParkingMutex: tryLock/unlock fast path" {
    const t_alloc = std.testing.allocator;
    var ebr = EbrContext{};
    defer ebr.deinit(t_alloc);
    var rt = try Runtime.init(t_alloc, 512 * 1024, &ebr);
    defer rt.deinit();
    rt.wireAllocator();
    var sp = fm.StackPool.init(t_alloc);
    defer sp.deinit();
    var sched = try initSched(t_alloc, &ebr, &sp);
    defer { sched.deinit(); fp.global_registry.deinit(t_alloc); }
    fp.active_scheduler = &sched;

    var mu = ParkingMutex{};
    const Ctx = struct { mu: *ParkingMutex, ok: bool = false };
    var ctx = Ctx{ .mu = &mu };

    const Task = struct {
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const c = @as(*Ctx, @ptrCast(@alignCast(raw.?)));
            const got = c.mu.tryLock();
            if (!got) return;
            c.ok = true;
            c.mu.unlock();
            // After unlock, tryLock should succeed again
            const got2 = c.mu.tryLock();
            c.ok = c.ok and got2;
            if (got2) c.mu.unlock();
        }
    };
    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&Task.run)), &ctx, .{});
    sched.run();
    try std.testing.expect(ctx.ok);
}

test "ParkingMutex: N fibers increment shared counter" {
    const t_alloc = std.testing.allocator;
    var ebr = EbrContext{};
    defer ebr.deinit(t_alloc);
    var rt = try Runtime.init(t_alloc, 512 * 1024, &ebr);
    defer rt.deinit();
    rt.wireAllocator();
    var sp = fm.StackPool.init(t_alloc);
    defer sp.deinit();
    var sched = try initSched(t_alloc, &ebr, &sp);
    defer { sched.deinit(); fp.global_registry.deinit(t_alloc); }
    fp.active_scheduler = &sched;

    const N = 16;
    const Shared = struct {
        mu: ParkingMutex = .{},
        wg: CheatHeader.WaitGroup,
        counter: usize = 0,
    };
    var shared = Shared{ .wg = CheatHeader.WaitGroup.init(&sched) };

    const WorkCtx = struct { s: *Shared };
    var work_ctxs: [N]WorkCtx = undefined;
    for (&work_ctxs) |*wc| wc.* = .{ .s = &shared };

    const Worker = struct {
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const wc = @as(*WorkCtx, @ptrCast(@alignCast(raw.?)));
            defer wc.s.wg.done();
            try wc.s.mu.lock();
            wc.s.counter += 1;
            wc.s.mu.unlock();
        }
    };

    const Main = struct {
        s: *Shared,
        ctxs: []WorkCtx,
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            self.s.wg.add(N);
            for (self.ctxs) |*wc| {
                try fp.active_scheduler.submitSpawn(
                    @intFromPtr(&Runtime.entryWrapper),
                    @as(CheatHeader.TaskFn, @ptrCast(&Worker.run)),
                    wc, .{},
                );
            }
            self.s.wg.wait();
        }
    };
    var main_ctx = Main{ .s = &shared, .ctxs = &work_ctxs };
    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&Main.run)), &main_ctx, .{});
    sched.run();
    try std.testing.expectEqual(@as(usize, N), shared.counter);
}

test "ParkingMutex: lock contention transfers ownership correctly" {
    const t_alloc = std.testing.allocator;
    var ebr = EbrContext{};
    defer ebr.deinit(t_alloc);
    var rt = try Runtime.init(t_alloc, 512 * 1024, &ebr);
    defer rt.deinit();
    rt.wireAllocator();
    var sp = fm.StackPool.init(t_alloc);
    defer sp.deinit();
    var sched = try initSched(t_alloc, &ebr, &sp);
    defer { sched.deinit(); fp.global_registry.deinit(t_alloc); }
    fp.active_scheduler = &sched;

    // Two fibers both call lock(). One parks, the other completes, then the
    // parked fiber is resumed and completes. Final counter must be 2.
    const Shared = struct {
        mu: ParkingMutex = .{},
        wg: CheatHeader.WaitGroup,
        counter: usize = 0,
    };
    var shared = Shared{ .wg = CheatHeader.WaitGroup.init(&sched) };

    const WCtx = struct { s: *Shared };
    var wc0 = WCtx{ .s = &shared };
    var wc1 = WCtx{ .s = &shared };

    const Worker = struct {
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const wc = @as(*WCtx, @ptrCast(@alignCast(raw.?)));
            defer wc.s.wg.done();
            try wc.s.mu.lock();
            wc.s.counter += 1;
            wc.s.mu.unlock();
        }
    };

    const Main = struct {
        s: *Shared, w0: *WCtx, w1: *WCtx,
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            self.s.wg.add(2);
            try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&Worker.run)), self.w0, .{});
            try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&Worker.run)), self.w1, .{});
            self.s.wg.wait();
        }
    };
    var main_ctx = Main{ .s = &shared, .w0 = &wc0, .w1 = &wc1 };
    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&Main.run)), &main_ctx, .{});
    sched.run();
    try std.testing.expectEqual(@as(usize, 2), shared.counter);
}

// ─────────────────────────────────────────────────────────────────────────────
// ParkingRwLock tests
// ─────────────────────────────────────────────────────────────────────────────

test "ParkingRwLock: multiple concurrent readers" {
    const t_alloc = std.testing.allocator;
    var ebr = EbrContext{};
    defer ebr.deinit(t_alloc);
    var rt = try Runtime.init(t_alloc, 512 * 1024, &ebr);
    defer rt.deinit();
    rt.wireAllocator();
    var sp = fm.StackPool.init(t_alloc);
    defer sp.deinit();
    var sched = try initSched(t_alloc, &ebr, &sp);
    defer { sched.deinit(); fp.global_registry.deinit(t_alloc); }
    fp.active_scheduler = &sched;

    const N = 8;
    const Shared = struct {
        rw: ParkingRwLock = .{},
        wg: CheatHeader.WaitGroup,
        reads_completed: usize = 0,
    };
    var shared = Shared{ .wg = CheatHeader.WaitGroup.init(&sched) };

    const RCtx = struct { s: *Shared };
    var rctxs: [N]RCtx = undefined;
    for (&rctxs) |*rc| rc.* = .{ .s = &shared };

    const Reader = struct {
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const rc = @as(*RCtx, @ptrCast(@alignCast(raw.?)));
            defer rc.s.wg.done();
            try rc.s.rw.lockShared();
            rc.s.reads_completed += 1;
            rc.s.rw.unlockShared();
        }
    };

    const Main = struct {
        s: *Shared, ctxs: []RCtx,
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            self.s.wg.add(N);
            for (self.ctxs) |*rc| {
                try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&Reader.run)), rc, .{});
            }
            self.s.wg.wait();
        }
    };
    var main_ctx = Main{ .s = &shared, .ctxs = &rctxs };
    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&Main.run)), &main_ctx, .{});
    sched.run();
    try std.testing.expectEqual(@as(usize, N), shared.reads_completed);
}

test "ParkingRwLock: writer excludes readers and other writers" {
    const t_alloc = std.testing.allocator;
    var ebr = EbrContext{};
    defer ebr.deinit(t_alloc);
    var rt = try Runtime.init(t_alloc, 512 * 1024, &ebr);
    defer rt.deinit();
    rt.wireAllocator();
    var sp = fm.StackPool.init(t_alloc);
    defer sp.deinit();
    var sched = try initSched(t_alloc, &ebr, &sp);
    defer { sched.deinit(); fp.global_registry.deinit(t_alloc); }
    fp.active_scheduler = &sched;

    // 4 writers each increment a counter. Final must be 4 (no lost updates).
    const NW = 4;
    const Shared = struct {
        rw: ParkingRwLock = .{},
        wg: CheatHeader.WaitGroup,
        counter: usize = 0,
    };
    var shared = Shared{ .wg = CheatHeader.WaitGroup.init(&sched) };

    const WCtx = struct { s: *Shared };
    var wctxs: [NW]WCtx = undefined;
    for (&wctxs) |*wc| wc.* = .{ .s = &shared };

    const Writer = struct {
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const wc = @as(*WCtx, @ptrCast(@alignCast(raw.?)));
            defer wc.s.wg.done();
            try wc.s.rw.lock();
            wc.s.counter += 1;
            wc.s.rw.unlock();
        }
    };

    const Main = struct {
        s: *Shared, ctxs: []WCtx,
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            self.s.wg.add(NW);
            for (self.ctxs) |*wc| {
                try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&Writer.run)), wc, .{});
            }
            self.s.wg.wait();
        }
    };
    var main_ctx = Main{ .s = &shared, .ctxs = &wctxs };
    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&Main.run)), &main_ctx, .{});
    sched.run();
    try std.testing.expectEqual(@as(usize, NW), shared.counter);
}

test "ParkingRwLock: mixed readers and writers" {
    const t_alloc = std.testing.allocator;
    var ebr = EbrContext{};
    defer ebr.deinit(t_alloc);
    var rt = try Runtime.init(t_alloc, 512 * 1024, &ebr);
    defer rt.deinit();
    rt.wireAllocator();
    var sp = fm.StackPool.init(t_alloc);
    defer sp.deinit();
    var sched = try initSched(t_alloc, &ebr, &sp);
    defer { sched.deinit(); fp.global_registry.deinit(t_alloc); }
    fp.active_scheduler = &sched;

    // 4 readers + 4 writers on the same RwLock. Writers increment a counter,
    // readers just observe. All 8 must complete; final write_count == 4.
    const NR = 4;
    const NW = 4;
    const Shared = struct {
        rw: ParkingRwLock = .{},
        wg: CheatHeader.WaitGroup,
        write_count: usize = 0,
        read_count: usize = 0,
    };
    var shared = Shared{ .wg = CheatHeader.WaitGroup.init(&sched) };

    const WCtx = struct { s: *Shared, is_writer: bool };
    var ctxs: [NR + NW]WCtx = undefined;
    for (ctxs[0..NR]) |*c| c.* = .{ .s = &shared, .is_writer = false };
    for (ctxs[NR..]) |*c| c.* = .{ .s = &shared, .is_writer = true };

    const Worker = struct {
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const wc = @as(*WCtx, @ptrCast(@alignCast(raw.?)));
            defer wc.s.wg.done();
            if (wc.is_writer) {
                try wc.s.rw.lock();
                wc.s.write_count += 1;
                wc.s.rw.unlock();
            } else {
                try wc.s.rw.lockShared();
                wc.s.read_count += 1;
                wc.s.rw.unlockShared();
            }
        }
    };

    const Main = struct {
        s: *Shared, ctxs_slice: []WCtx,
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            self.s.wg.add(NR + NW);
            for (self.ctxs_slice) |*wc| {
                try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&Worker.run)), wc, .{});
            }
            self.s.wg.wait();
        }
    };
    var main_ctx = Main{ .s = &shared, .ctxs_slice = &ctxs };
    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&Main.run)), &main_ctx, .{});
    sched.run();
    try std.testing.expectEqual(@as(usize, NW), shared.write_count);
    try std.testing.expectEqual(@as(usize, NR), shared.read_count);
}

// ─────────────────────────────────────────────────────────────────────────────
// ParkingRwLocked<T> guard API
// ─────────────────────────────────────────────────────────────────────────────

test "ParkingRwLocked: read/write guard API" {
    const t_alloc = std.testing.allocator;
    var ebr = EbrContext{};
    defer ebr.deinit(t_alloc);
    var rt = try Runtime.init(t_alloc, 512 * 1024, &ebr);
    defer rt.deinit();
    rt.wireAllocator();
    var sp = fm.StackPool.init(t_alloc);
    defer sp.deinit();
    var sched = try initSched(t_alloc, &ebr, &sp);
    defer { sched.deinit(); fp.global_registry.deinit(t_alloc); }
    fp.active_scheduler = &sched;

    const Locked = ParkingRwLocked(usize);
    var locked = Locked.init(0);
    const Ctx = struct { l: *Locked, ok: bool = false };
    var ctx = Ctx{ .l = &locked };

    const Task = struct {
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const c = @as(*Ctx, @ptrCast(@alignCast(raw.?)));
            // Write
            var wg = try c.l.write();
            wg.get().* = 42;
            wg.release();
            // Read back
            var rg = try c.l.read();
            c.ok = rg.get().* == 42;
            rg.release();
        }
    };
    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&Task.run)), &ctx, .{});
    sched.run();
    try std.testing.expect(ctx.ok);
}

// ─────────────────────────────────────────────────────────────────────────────
// Stress: high contention with many fibers
// ─────────────────────────────────────────────────────────────────────────────

test "ParkingMutex: stress 32 fibers, 10 increments each" {
    const t_alloc = std.testing.allocator;
    var ebr = EbrContext{};
    defer ebr.deinit(t_alloc);
    var rt = try Runtime.init(t_alloc, 512 * 1024, &ebr);
    defer rt.deinit();
    rt.wireAllocator();
    var sp = fm.StackPool.init(t_alloc);
    defer sp.deinit();
    var sched = try initSched(t_alloc, &ebr, &sp);
    defer { sched.deinit(); fp.global_registry.deinit(t_alloc); }
    fp.active_scheduler = &sched;

    const N = 32;
    const INCREMENTS_PER = 10;
    const Shared = struct {
        mu: ParkingMutex = .{},
        wg: CheatHeader.WaitGroup,
        counter: usize = 0,
    };
    var shared = Shared{ .wg = CheatHeader.WaitGroup.init(&sched) };

    const WCtx = struct { s: *Shared };
    var wctxs: [N]WCtx = undefined;
    for (&wctxs) |*wc| wc.* = .{ .s = &shared };

    const Worker = struct {
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const wc = @as(*WCtx, @ptrCast(@alignCast(raw.?)));
            defer wc.s.wg.done();
            for (0..INCREMENTS_PER) |_| {
                try wc.s.mu.lock();
                wc.s.counter += 1;
                wc.s.mu.unlock();
            }
        }
    };

    const Main = struct {
        s: *Shared, ctxs: []WCtx,
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            self.s.wg.add(N);
            for (self.ctxs) |*wc| {
                try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&Worker.run)), wc, .{});
            }
            self.s.wg.wait();
        }
    };
    var main_ctx = Main{ .s = &shared, .ctxs = &wctxs };
    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&Main.run)), &main_ctx, .{});
    sched.run();
    try std.testing.expectEqual(@as(usize, N * INCREMENTS_PER), shared.counter);
}

test "ParkingRwLock: stress 8 writers 8 readers" {
    const t_alloc = std.testing.allocator;
    var ebr = EbrContext{};
    defer ebr.deinit(t_alloc);
    var rt = try Runtime.init(t_alloc, 512 * 1024, &ebr);
    defer rt.deinit();
    rt.wireAllocator();
    var sp = fm.StackPool.init(t_alloc);
    defer sp.deinit();
    var sched = try initSched(t_alloc, &ebr, &sp);
    defer { sched.deinit(); fp.global_registry.deinit(t_alloc); }
    fp.active_scheduler = &sched;

    const NW = 8;
    const NR = 8;
    const Shared = struct {
        rw: ParkingRwLock = .{},
        wg: CheatHeader.WaitGroup,
        write_count: usize = 0,
        read_count: usize = 0,
    };
    var shared = Shared{ .wg = CheatHeader.WaitGroup.init(&sched) };

    const WCtx = struct { s: *Shared, is_writer: bool };
    var ctxs: [NW + NR]WCtx = undefined;
    for (ctxs[0..NW]) |*c| c.* = .{ .s = &shared, .is_writer = true };
    for (ctxs[NW..]) |*c| c.* = .{ .s = &shared, .is_writer = false };

    const Worker = struct {
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const wc = @as(*WCtx, @ptrCast(@alignCast(raw.?)));
            defer wc.s.wg.done();
            if (wc.is_writer) {
                try wc.s.rw.lock();
                wc.s.write_count += 1;
                wc.s.rw.unlock();
            } else {
                try wc.s.rw.lockShared();
                wc.s.read_count += 1;
                wc.s.rw.unlockShared();
            }
        }
    };

    const Main = struct {
        s: *Shared, ctxs_slice: []WCtx,
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            self.s.wg.add(NW + NR);
            for (self.ctxs_slice) |*wc| {
                try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&Worker.run)), wc, .{});
            }
            self.s.wg.wait();
        }
    };
    var main_ctx = Main{ .s = &shared, .ctxs_slice = &ctxs };
    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&Main.run)), &main_ctx, .{});
    sched.run();
    try std.testing.expectEqual(@as(usize, NW), shared.write_count);
    try std.testing.expectEqual(@as(usize, NR), shared.read_count);
}

// ─────────────────────────────────────────────────────────────────────────────
// Error recovery tests
//
// Verify that after lock() returns an error, the lock state is consistent and
// other waiters proceed normally. Each test checks:
//   - The correct error is returned
//   - Defers fire and release the lock
//   - A waiting fiber gets the lock and completes
//   - Lock struct fields are zeroed afterward
// ─────────────────────────────────────────────────────────────────────────────

test "ParkingMutex: re-entrant lock returns error.Deadlock, lock remains usable" {
    // A locks mu, then tries to lock mu again (same owner -> immediate Deadlock).
    // A's defer fires mu.unlock(); B then acquires mu normally.
    const t_alloc = std.testing.allocator;
    var ebr = EbrContext{};
    defer ebr.deinit(t_alloc);
    var rt = try Runtime.init(t_alloc, 512 * 1024, &ebr);
    defer rt.deinit();
    rt.wireAllocator();
    var sp = fm.StackPool.init(t_alloc);
    defer sp.deinit();
    var sched = try initSched(t_alloc, &ebr, &sp);
    defer { sched.deinit(); fp.global_registry.deinit(t_alloc); }
    fp.active_scheduler = &sched;

    const Shared = struct {
        mu: ParkingMutex = .{},
        wg: CheatHeader.WaitGroup,
        a_got_deadlock: bool = false,
        b_counter: usize = 0,
    };
    var shared = Shared{ .wg = CheatHeader.WaitGroup.init(&sched) };
    const ACtx = struct { s: *Shared };
    const BCtx = struct { s: *Shared };
    var a_ctx = ACtx{ .s = &shared };
    var b_ctx = BCtx{ .s = &shared };

    const FiberA = struct {
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const c = @as(*ACtx, @ptrCast(@alignCast(raw.?)));
            defer c.s.wg.done();
            try c.s.mu.lock();
            defer c.s.mu.unlock();
            // Second lock on same mutex by same owner -> error.Deadlock immediately.
            c.s.mu.lock() catch |e| {
                c.s.a_got_deadlock = (e == error.Deadlock);
                return e; // defer above fires -> mu released
            };
        }
    };
    const FiberB = struct {
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const c = @as(*BCtx, @ptrCast(@alignCast(raw.?)));
            defer c.s.wg.done();
            try c.s.mu.lock();
            c.s.b_counter += 1;
            c.s.mu.unlock();
        }
    };
    const Main = struct {
        s: *Shared, ac: *ACtx, bc: *BCtx,
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            self.s.wg.add(2);
            try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&FiberA.run)), self.ac, .{});
            try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&FiberB.run)), self.bc, .{});
            self.s.wg.wait();
        }
    };
    var main_ctx = Main{ .s = &shared, .ac = &a_ctx, .bc = &b_ctx };
    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&Main.run)), &main_ctx, .{});
    sched.run();

    try std.testing.expect(shared.a_got_deadlock);
    try std.testing.expectEqual(@as(usize, 1), shared.b_counter);
    try std.testing.expectEqual(@as(u32, 0), shared.mu.locked.load(.monotonic));
}

test "ParkingMutex: AB/BA cycle returns error.Deadlock, blocked fiber unblocked" {
    // Scheduling design (LIFO ready queue):
    //   Spawn B first, then A. LIFO pops A first.
    //   A: locks mu_a, parks on rendezvous (pre-locked, no owner).
    //   B: locks mu_b, calls rendezvous.unlock() (wakes A into ready queue,
    //      B keeps running), tries mu_a (parks, B.waiting_for_lock_owner = A).
    //   A: resumes, tries mu_b -> detectCycle sees B->A chain -> error.Deadlock.
    //   A's defer releases mu_a -> B wakes, acquires mu_a, b_counter++.
    const t_alloc = std.testing.allocator;
    var ebr = EbrContext{};
    defer ebr.deinit(t_alloc);
    var rt = try Runtime.init(t_alloc, 512 * 1024, &ebr);
    defer rt.deinit();
    rt.wireAllocator();
    var sp = fm.StackPool.init(t_alloc);
    defer sp.deinit();
    var sched = try initSched(t_alloc, &ebr, &sp);
    defer { sched.deinit(); fp.global_registry.deinit(t_alloc); }
    fp.active_scheduler = &sched;

    const Shared = struct {
        mu_a: ParkingMutex = .{},
        mu_b: ParkingMutex = .{},
        // rendezvous: pre-locked before run(). A parks here; B unlocks it to
        // signal A. B then parks on mu_a before A resumes, establishing
        // B.waiting_for_lock_owner = A for cycle detection.
        rendezvous: ParkingMutex = .{},
        wg: CheatHeader.WaitGroup,
        a_got_deadlock: bool = false,
        b_counter: usize = 0,
    };
    var shared = Shared{ .wg = CheatHeader.WaitGroup.init(&sched) };
    // Pre-lock rendezvous with no owner so A will park on it.
    shared.rendezvous.locked.store(1, .monotonic);

    const ACtx = struct { s: *Shared };
    const BCtx = struct { s: *Shared };
    var a_ctx = ACtx{ .s = &shared };
    var b_ctx = BCtx{ .s = &shared };

    const FiberA = struct {
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const c = @as(*ACtx, @ptrCast(@alignCast(raw.?)));
            defer c.s.wg.done();
            try c.s.mu_a.lock();
            defer c.s.mu_a.unlock();
            // Park here. B will unlock rendezvous after locking mu_b,
            // then immediately try mu_a (parking with waiting_for_lock_owner=A).
            // A resumes only after B has already parked on mu_a.
            try c.s.rendezvous.lock();
            defer c.s.rendezvous.unlock();
            // B holds mu_b and B.waiting_for_lock_owner == A -> cycle.
            c.s.mu_b.lock() catch |e| {
                c.s.a_got_deadlock = (e == error.Deadlock);
                return e; // defer mu_a.unlock() fires, waking B
            };
            c.s.mu_b.unlock();
        }
    };
    const FiberB = struct {
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const c = @as(*BCtx, @ptrCast(@alignCast(raw.?)));
            defer c.s.wg.done();
            try c.s.mu_b.lock();
            defer c.s.mu_b.unlock();
            // Wake A (pushes A to ready queue). B keeps running.
            c.s.rendezvous.unlock();
            // Try mu_a (held by A). Parks: B.waiting_for_lock_owner = A.
            // A runs next, finds the cycle.
            try c.s.mu_a.lock();
            defer c.s.mu_a.unlock();
            c.s.b_counter += 1;
        }
    };
    const Main = struct {
        s: *Shared, ac: *ACtx, bc: *BCtx,
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            self.s.wg.add(2);
            // Spawn B first so LIFO runs A first.
            try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&FiberB.run)), self.bc, .{});
            try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&FiberA.run)), self.ac, .{});
            self.s.wg.wait();
        }
    };
    var main_ctx = Main{ .s = &shared, .ac = &a_ctx, .bc = &b_ctx };
    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&Main.run)), &main_ctx, .{});
    sched.run();

    try std.testing.expect(shared.a_got_deadlock);
    try std.testing.expectEqual(@as(usize, 1), shared.b_counter);
    try std.testing.expectEqual(@as(u32, 0), shared.mu_a.locked.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), shared.mu_b.locked.load(.monotonic));
}

test "ParkingRwLock: re-entrant write lock returns error.Deadlock, lock remains usable" {
    // A holds write lock, tries to write-lock again -> cycle (A == write_owner) -> error.Deadlock.
    // A's defer releases it; B acquires normally.
    const t_alloc = std.testing.allocator;
    var ebr = EbrContext{};
    defer ebr.deinit(t_alloc);
    var rt = try Runtime.init(t_alloc, 512 * 1024, &ebr);
    defer rt.deinit();
    rt.wireAllocator();
    var sp = fm.StackPool.init(t_alloc);
    defer sp.deinit();
    var sched = try initSched(t_alloc, &ebr, &sp);
    defer { sched.deinit(); fp.global_registry.deinit(t_alloc); }
    fp.active_scheduler = &sched;

    const Shared = struct {
        rw: ParkingRwLock = .{},
        wg: CheatHeader.WaitGroup,
        a_got_deadlock: bool = false,
        b_counter: usize = 0,
    };
    var shared = Shared{ .wg = CheatHeader.WaitGroup.init(&sched) };
    const ACtx = struct { s: *Shared };
    const BCtx = struct { s: *Shared };
    var a_ctx = ACtx{ .s = &shared };
    var b_ctx = BCtx{ .s = &shared };

    const FiberA = struct {
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const c = @as(*ACtx, @ptrCast(@alignCast(raw.?)));
            defer c.s.wg.done();
            try c.s.rw.lock();
            defer c.s.rw.unlock();
            c.s.rw.lock() catch |e| {
                c.s.a_got_deadlock = (e == error.Deadlock);
                return e;
            };
        }
    };
    const FiberB = struct {
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const c = @as(*BCtx, @ptrCast(@alignCast(raw.?)));
            defer c.s.wg.done();
            try c.s.rw.lock();
            c.s.b_counter += 1;
            c.s.rw.unlock();
        }
    };
    const Main = struct {
        s: *Shared, ac: *ACtx, bc: *BCtx,
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            self.s.wg.add(2);
            try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&FiberA.run)), self.ac, .{});
            try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&FiberB.run)), self.bc, .{});
            self.s.wg.wait();
        }
    };
    var main_ctx = Main{ .s = &shared, .ac = &a_ctx, .bc = &b_ctx };
    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&Main.run)), &main_ctx, .{});
    sched.run();

    try std.testing.expect(shared.a_got_deadlock);
    try std.testing.expectEqual(@as(usize, 1), shared.b_counter);
    try std.testing.expect(!shared.rw.write_locked);
    try std.testing.expectEqual(@as(i32, 0), shared.rw.readers);
}

// ─────────────────────────────────────────────────────────────────────────────
// Timeout tests
//
// Set sched.lock_timeout_ms to a short value so the timeout path is exercised
// without real-time waits of 30s. The holder fiber sleeps 4x longer than the
// timeout so the waiter times out before the holder releases.
// ─────────────────────────────────────────────────────────────────────────────

// Fiber sleep helper: yield this fiber for `ms` milliseconds.
fn fiberSleepMs(ms: u64) void {
    const sched = fp.active_scheduler;
    const task = sched.current_task.?;
    sched.sleepTask(task, compat.milliTimestamp() + @as(i64, @intCast(ms)));
    task.base.yield();
}

test "ParkingMutex: lock timeout returns error.LockTimeout, lock remains usable" {
    const t_alloc = std.testing.allocator;
    var ebr = EbrContext{};
    defer ebr.deinit(t_alloc);
    var rt = try Runtime.init(t_alloc, 512 * 1024, &ebr);
    defer rt.deinit();
    rt.wireAllocator();
    var sp = fm.StackPool.init(t_alloc);
    defer sp.deinit();
    var sched = try initSched(t_alloc, &ebr, &sp);
    defer { sched.deinit(); fp.global_registry.deinit(t_alloc); }
    sched.lock_timeout_ms = 100;
    fp.active_scheduler = &sched;

    const Shared = struct {
        mu: ParkingMutex = .{},
        wg: CheatHeader.WaitGroup,
        b_got_timeout: bool = false,
        a_counter: usize = 0,
    };
    var shared = Shared{ .wg = CheatHeader.WaitGroup.init(&sched) };
    const ACtx = struct { s: *Shared };
    const BCtx = struct { s: *Shared };
    var a_ctx = ACtx{ .s = &shared };
    var b_ctx = BCtx{ .s = &shared };

    const FiberA = struct {
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const c = @as(*ACtx, @ptrCast(@alignCast(raw.?)));
            defer c.s.wg.done();
            try c.s.mu.lock();
            defer c.s.mu.unlock();
            fiberSleepMs(400);  // hold the lock 4x longer than timeout
            c.s.a_counter += 1;
        }
    };
    const FiberB = struct {
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const c = @as(*BCtx, @ptrCast(@alignCast(raw.?)));
            defer c.s.wg.done();
            c.s.mu.lock() catch |e| {
                c.s.b_got_timeout = (e == error.LockTimeout);
                return;
            };
            c.s.mu.unlock();
        }
    };
    const Main = struct {
        s: *Shared, ac: *ACtx, bc: *BCtx,
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            self.s.wg.add(2);
            try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&FiberB.run)), self.bc, .{ .stack_size = .Large });
            try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&FiberA.run)), self.ac, .{ .stack_size = .Large });
            self.s.wg.wait();
        }
    };
    var main_ctx = Main{ .s = &shared, .ac = &a_ctx, .bc = &b_ctx };
    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&Main.run)), &main_ctx, .{ .stack_size = .Large });
    sched.run();

    try std.testing.expect(shared.b_got_timeout);
    try std.testing.expectEqual(@as(usize, 1), shared.a_counter);
    try std.testing.expectEqual(@as(u32, 0), shared.mu.locked.load(.monotonic));
}

test "ParkingRwLock: write-lock timeout decrements writers_waiting, readers can proceed" {
    // Regression test for: writers_waiting not decremented on write-lock timeout,
    // permanently blocking future readers via the wakeNext writers_waiting == 0 guard.
    //
    // Coordination is event-driven except for a single wall-clock wait in Main
    // that is tied DIRECTLY to lock_timeout_ms. The cascaded 150/120/100ms
    // timings of the previous version are gone.
    //
    // Side note on the single remaining sleep: the scheduler's lock_waiters
    // timeout scan only runs when the scheduler wakes for some other reason
    // (a sleeping fiber's 1ms io_uring poll, a CQE, etc). If nothing is in
    // sleeping_queue and no I/O is pending, io_uring_enter blocks indefinitely
    // and the lock timeout never fires. Main's fiberSleepMs serves both as
    // "wait for B to time out" and as "keep scheduler awake so timeouts fire".
    // A purely event-driven design would require a scheduler-level change to
    // register a timer when registerLockWaiter is called.
    //
    //   1. Main spawns A (takes write lock) and B (queues for write lock).
    //   2. Main sleeps lock_timeout_ms + small margin -- by the time it wakes,
    //      B's timeout has fired (counter checks prove this below).
    //   3. Main snapshots rw.writers_waiting and confirms b_wg is drained.
    //      With the fix writers_waiting == 0; without it, stuck at 1.
    //   4. Main spawns C (queues for read lock) and releases A via release_wg.
    //   5. A unlocks. wakeNext wakes C iff writers_waiting == 0.
    //   6. Main waits on ac_wg for A and C.
    const t_alloc = std.testing.allocator;
    var ebr = EbrContext{};
    defer ebr.deinit(t_alloc);
    var rt = try Runtime.init(t_alloc, 512 * 1024, &ebr);
    defer rt.deinit();
    rt.wireAllocator();
    var sp = fm.StackPool.init(t_alloc);
    defer sp.deinit();
    var sched = try initSched(t_alloc, &ebr, &sp);
    defer { sched.deinit(); fp.global_registry.deinit(t_alloc); }
    sched.lock_timeout_ms = 100;
    fp.active_scheduler = &sched;

    const Shared = struct {
        rw: ParkingRwLock = .{},
        // b_wg drops to 0 when B finishes (times out). Main waits on this
        // before snapshotting writers_waiting.
        b_wg: CheatHeader.WaitGroup,
        // release_wg is pre-added(1). A waits on it after taking rw. Main
        // calls done() to release A only after snapshotting writers_waiting
        // and spawning C -- so A's unlock wakes C's read-lock wait.
        release_wg: CheatHeader.WaitGroup,
        // ac_wg drops to 0 when A and C both finish. Main waits on this last.
        ac_wg: CheatHeader.WaitGroup,
        b_got_timeout: bool = false,
        c_read_counter: usize = 0,
        // Snapshot captured by Main immediately after B times out.
        writers_waiting_after_b: u32 = std.math.maxInt(u32),
    };
    var shared = Shared{
        .b_wg = CheatHeader.WaitGroup.init(&sched),
        .release_wg = CheatHeader.WaitGroup.init(&sched),
        .ac_wg = CheatHeader.WaitGroup.init(&sched),
    };
    const ACtx = struct { s: *Shared };
    const BCtx = struct { s: *Shared };
    const CCtx = struct { s: *Shared };
    var a_ctx = ACtx{ .s = &shared };
    var b_ctx = BCtx{ .s = &shared };
    var c_ctx = CCtx{ .s = &shared };

    // A: take the write lock, park on release_wg until Main signals release,
    // then unlock. Uses WaitGroup (not another mutex) so A's park is not
    // itself subject to lock_timeout_ms.
    const FiberA = struct {
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const c = @as(*ACtx, @ptrCast(@alignCast(raw.?)));
            defer c.s.ac_wg.done();
            try c.s.rw.lock();
            defer c.s.rw.unlock();
            c.s.release_wg.wait();
        }
    };
    const FiberB = struct {
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const c = @as(*BCtx, @ptrCast(@alignCast(raw.?)));
            defer c.s.b_wg.done();
            c.s.rw.lock() catch |e| {
                c.s.b_got_timeout = (e == error.LockTimeout);
                return;
            };
            c.s.rw.unlock();
        }
    };
    const FiberC = struct {
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const c = @as(*CCtx, @ptrCast(@alignCast(raw.?)));
            defer c.s.ac_wg.done();
            try c.s.rw.lockShared();
            defer c.s.rw.unlockShared();
            c.s.c_read_counter += 1;
        }
    };
    const Main = struct {
        s: *Shared, ac: *ACtx, bc: *BCtx, cc: *CCtx,
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            self.s.b_wg.add(1);
            self.s.ac_wg.add(2);
            self.s.release_wg.add(1);
            // Spawn B first so LIFO runs A first (A gets the write lock).
            try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&FiberB.run)), self.bc, .{ .stack_size = .Large });
            try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&FiberA.run)), self.ac, .{ .stack_size = .Large });

            // Wait long enough for B's 100ms timeout to fire. Margin covers
            // scheduler wake latency (~1ms per poll). Since B is the only
            // fiber that can block on the rw lock, when this sleep returns
            // B is guaranteed to have timed out.
            fiberSleepMs(@as(u64, @intCast(fp.active_scheduler.lock_timeout_ms)) + 20);

            // Snapshot -- no further lock activity has happened.
            self.s.writers_waiting_after_b = self.s.rw.writers_waiting;

            // Now queue C and release A. C parks in read_waiters; A's unlock
            // calls wakeNext which wakes C iff writers_waiting == 0.
            try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&FiberC.run)), self.cc, .{ .stack_size = .Large });
            self.s.release_wg.done();

            self.s.ac_wg.wait();
        }
    };
    var main_ctx = Main{ .s = &shared, .ac = &a_ctx, .bc = &b_ctx, .cc = &c_ctx };
    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&Main.run)), &main_ctx, .{ .stack_size = .Large });
    sched.run();

    try std.testing.expect(shared.b_got_timeout);
    // The core invariant this test was written for: writers_waiting must be
    // back to 0 at the moment B finishes its timeout.
    try std.testing.expectEqual(@as(u32, 0), shared.writers_waiting_after_b);
    try std.testing.expectEqual(@as(usize, 1), shared.c_read_counter);
    try std.testing.expectEqual(@as(u32, 0), shared.rw.writers_waiting);
    try std.testing.expect(!shared.rw.write_locked);
    try std.testing.expectEqual(@as(i32, 0), shared.rw.readers);
}

test "ParkingRwLock: read-lock timeout returns error.LockTimeout" {
    const t_alloc = std.testing.allocator;
    var ebr = EbrContext{};
    defer ebr.deinit(t_alloc);
    var rt = try Runtime.init(t_alloc, 512 * 1024, &ebr);
    defer rt.deinit();
    rt.wireAllocator();
    var sp = fm.StackPool.init(t_alloc);
    defer sp.deinit();
    var sched = try initSched(t_alloc, &ebr, &sp);
    defer { sched.deinit(); fp.global_registry.deinit(t_alloc); }
    sched.lock_timeout_ms = 100;
    fp.active_scheduler = &sched;

    const Shared = struct {
        rw: ParkingRwLock = .{},
        wg: CheatHeader.WaitGroup,
        b_got_timeout: bool = false,
        a_counter: usize = 0,
    };
    var shared = Shared{ .wg = CheatHeader.WaitGroup.init(&sched) };
    const ACtx = struct { s: *Shared };
    const BCtx = struct { s: *Shared };
    var a_ctx = ACtx{ .s = &shared };
    var b_ctx = BCtx{ .s = &shared };

    const FiberA = struct {
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const c = @as(*ACtx, @ptrCast(@alignCast(raw.?)));
            defer c.s.wg.done();
            try c.s.rw.lock();
            defer c.s.rw.unlock();
            fiberSleepMs(400);
            c.s.a_counter += 1;
        }
    };
    const FiberB = struct {
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const c = @as(*BCtx, @ptrCast(@alignCast(raw.?)));
            defer c.s.wg.done();
            c.s.rw.lockShared() catch |e| {
                c.s.b_got_timeout = (e == error.LockTimeout);
                return;
            };
            c.s.rw.unlockShared();
        }
    };
    const Main = struct {
        s: *Shared, ac: *ACtx, bc: *BCtx,
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            self.s.wg.add(2);
            try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&FiberB.run)), self.bc, .{ .stack_size = .Large });
            try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&FiberA.run)), self.ac, .{ .stack_size = .Large });
            self.s.wg.wait();
        }
    };
    var main_ctx = Main{ .s = &shared, .ac = &a_ctx, .bc = &b_ctx };
    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&Main.run)), &main_ctx, .{ .stack_size = .Large });
    sched.run();

    try std.testing.expect(shared.b_got_timeout);
    try std.testing.expectEqual(@as(usize, 1), shared.a_counter);
    try std.testing.expect(!shared.rw.write_locked);
    try std.testing.expectEqual(@as(i32, 0), shared.rw.readers);
}

test "ParkingMutex: 3-way A->B->C->A cycle detected, all fibers recover" {
    // Cycle: A holds mu1 and waits for mu2 (owned by B).
    //        B holds mu2 and waits for mu3 (owned by C).
    //        C holds mu3 and waits for mu1 (owned by A, A waiting for B).
    //        B tries mu3: detectCycle(B,C) -> C.waiting=A -> A.waiting=B -> B found -> Deadlock.
    //
    // Rendezvous protocol (pre-locked rv1, rv2):
    //   A: lock mu1, park on rv1 (wait for B to lock mu2).
    //   B: lock mu2, unlock rv1 (wakes A), park on rv2 (wait for C to lock mu3).
    //   A: (LIFO) resumes from rv1, tries mu2 -> parks (A.waiting=B).
    //   C: lock mu3, unlock rv2 (wakes B), tries mu1 -> parks (C.waiting=A, no cycle yet).
    //   B: resumes from rv2, tries mu3 -> cycle detected (B.waiting=C, C.waiting=A, A.waiting=B).
    //   B gets Deadlock, releases mu2. A wakes, increments a_counter, releases mu1.
    //   C wakes, increments c_counter, releases mu3 and mu1.
    const t_alloc = std.testing.allocator;
    var ebr = EbrContext{};
    defer ebr.deinit(t_alloc);
    var rt = try Runtime.init(t_alloc, 512 * 1024, &ebr);
    defer rt.deinit();
    rt.wireAllocator();
    var sp = fm.StackPool.init(t_alloc);
    defer sp.deinit();
    var sched = try initSched(t_alloc, &ebr, &sp);
    defer { sched.deinit(); fp.global_registry.deinit(t_alloc); }
    fp.active_scheduler = &sched;

    const Shared = struct {
        mu1: ParkingMutex = .{},
        mu2: ParkingMutex = .{},
        mu3: ParkingMutex = .{},
        rv1: ParkingMutex = .{},
        rv2: ParkingMutex = .{},
        wg: CheatHeader.WaitGroup,
        b_got_deadlock: bool = false,
        a_counter: usize = 0,
        c_counter: usize = 0,
    };
    var shared = Shared{ .wg = CheatHeader.WaitGroup.init(&sched) };
    // Pre-lock rendezvous mutexes (owner=null so A and B park on them).
    shared.rv1.locked.store(1, .monotonic);
    shared.rv2.locked.store(1, .monotonic);

    const ACtx = struct { s: *Shared };
    const BCtx = struct { s: *Shared };
    const CCtx = struct { s: *Shared };
    var a_ctx = ACtx{ .s = &shared };
    var b_ctx = BCtx{ .s = &shared };
    var c_ctx = CCtx{ .s = &shared };

    const FiberA = struct {
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const c = @as(*ACtx, @ptrCast(@alignCast(raw.?)));
            defer c.s.wg.done();
            try c.s.mu1.lock();
            defer c.s.mu1.unlock();
            try c.s.rv1.lock();       // parks here; B unlocks rv1 after locking mu2
            defer c.s.rv1.unlock();
            try c.s.mu2.lock();       // parks here; A.waiting=B; B detects cycle later
            defer c.s.mu2.unlock();
            c.s.a_counter += 1;
        }
    };
    const FiberB = struct {
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const c = @as(*BCtx, @ptrCast(@alignCast(raw.?)));
            defer c.s.wg.done();
            try c.s.mu2.lock();
            defer c.s.mu2.unlock();
            c.s.rv1.unlock();         // wake A (A pushed to ready queue; B keeps running)
            try c.s.rv2.lock();       // parks here; C unlocks rv2 after locking mu3
            defer c.s.rv2.unlock();
            // At this point: C holds mu3, C is parked on mu1; A holds mu1 and waits for mu2.
            // Walking the chain: B.waiting=C -> C.waiting=A -> A.waiting=B -> cycle!
            c.s.mu3.lock() catch |e| {
                c.s.b_got_deadlock = (e == error.Deadlock);
                return e; // defer mu2.unlock() fires, A wakes and gets mu2
            };
            defer c.s.mu3.unlock();
        }
    };
    const FiberC = struct {
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const c = @as(*CCtx, @ptrCast(@alignCast(raw.?)));
            defer c.s.wg.done();
            try c.s.mu3.lock();
            defer c.s.mu3.unlock();
            c.s.rv2.unlock();         // wake B (B pushed to ready queue; C keeps running)
            try c.s.mu1.lock();       // parks; C.waiting=A (no cycle yet: B.waiting=null)
            defer c.s.mu1.unlock();
            c.s.c_counter += 1;
        }
    };
    const Main = struct {
        s: *Shared, ac: *ACtx, bc: *BCtx, cc: *CCtx,
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            self.s.wg.add(3);
            // Spawn C, B, A. LIFO pops A first.
            try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&FiberC.run)), self.cc, .{ .stack_size = .Large });
            try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&FiberB.run)), self.bc, .{ .stack_size = .Large });
            try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&FiberA.run)), self.ac, .{ .stack_size = .Large });
            self.s.wg.wait();
        }
    };
    var main_ctx = Main{ .s = &shared, .ac = &a_ctx, .bc = &b_ctx, .cc = &c_ctx };
    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&Main.run)), &main_ctx, .{ .stack_size = .Large });
    sched.run();

    try std.testing.expect(shared.b_got_deadlock);
    try std.testing.expectEqual(@as(usize, 1), shared.a_counter);
    try std.testing.expectEqual(@as(usize, 1), shared.c_counter);
    try std.testing.expectEqual(@as(u32, 0), shared.mu1.locked.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), shared.mu2.locked.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), shared.mu3.locked.load(.monotonic));
}

// ─────────────────────────────────────────────────────────────────────────────
// Defer-unwind safety test
//
// Proves the core safety claim of the error-return refactor: when a fiber
// returns error.Deadlock while holding multiple locks, unwind via defer
// releases every held lock in reverse order and wakes every parked waiter.
// Without this guarantee the ecosystem would silently leak held locks when
// a deadlock is detected.
// ─────────────────────────────────────────────────────────────────────────────
test "ParkingMutex: deadlock unwind releases multiple held locks and wakes waiters" {
    const t_alloc = std.testing.allocator;
    var ebr = EbrContext{};
    defer ebr.deinit(t_alloc);
    var rt = try Runtime.init(t_alloc, 512 * 1024, &ebr);
    defer rt.deinit();
    rt.wireAllocator();
    var sp = fm.StackPool.init(t_alloc);
    defer sp.deinit();
    var sched = try initSched(t_alloc, &ebr, &sp);
    defer { sched.deinit(); fp.global_registry.deinit(t_alloc); }
    fp.active_scheduler = &sched;

    const Shared = struct {
        mu1: ParkingMutex = .{},
        mu2: ParkingMutex = .{},
        wg: CheatHeader.WaitGroup,
        a_got_deadlock: bool = false,
        b_acquired_mu1: bool = false,
        c_acquired_mu2: bool = false,
        // Sequencing: A sets held_both when it owns mu1+mu2.
        // B and C block until held_both so they park on A's locks,
        // not before A has acquired them.
        held_both: ParkingMutex = .{},
    };
    var shared = Shared{ .wg = CheatHeader.WaitGroup.init(&sched) };
    // Pre-lock held_both. A unlocks it after grabbing mu1+mu2, releasing B and C.
    shared.held_both.locked.store(1, .monotonic);

    const ACtx = struct { s: *Shared };
    const BCtx = struct { s: *Shared };
    const CCtx = struct { s: *Shared };
    var a_ctx = ACtx{ .s = &shared };
    var b_ctx = BCtx{ .s = &shared };
    var c_ctx = CCtx{ .s = &shared };

    // A: lock mu1, lock mu2, release held_both to wake B and C, yield until
    // they park, re-lock mu1 -> Deadlock. Unwind must release mu2 then mu1.
    const FiberA = struct {
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const c = @as(*ACtx, @ptrCast(@alignCast(raw.?)));
            defer c.s.wg.done();
            try c.s.mu1.lock();
            defer c.s.mu1.unlock();
            try c.s.mu2.lock();
            defer c.s.mu2.unlock();
            // Release B and C so they park on mu1/mu2 before A errors.
            c.s.held_both.unlock();
            // Give B and C a chance to park. fiberSleepMs suspends this fiber
            // into sleeping_queue so the scheduler runs B and C to park state.
            fiberSleepMs(20);
            // Re-entrant: same owner -> immediate error.Deadlock (no parking).
            c.s.mu1.lock() catch |e| {
                c.s.a_got_deadlock = (e == error.Deadlock);
                return e; // defers fire: mu2.unlock(), mu1.unlock()
            };
        }
    };
    // B parks on mu1 once held_both is released. After A's unwind, B acquires.
    const FiberB = struct {
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const c = @as(*BCtx, @ptrCast(@alignCast(raw.?)));
            defer c.s.wg.done();
            try c.s.held_both.lock();
            c.s.held_both.unlock();
            try c.s.mu1.lock();
            c.s.b_acquired_mu1 = true;
            c.s.mu1.unlock();
        }
    };
    // C parks on mu2 once held_both is released. After A's unwind, C acquires.
    const FiberC = struct {
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const c = @as(*CCtx, @ptrCast(@alignCast(raw.?)));
            defer c.s.wg.done();
            try c.s.held_both.lock();
            c.s.held_both.unlock();
            try c.s.mu2.lock();
            c.s.c_acquired_mu2 = true;
            c.s.mu2.unlock();
        }
    };
    const Main = struct {
        s: *Shared, ac: *ACtx, bc: *BCtx, cc: *CCtx,
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            self.s.wg.add(3);
            // LIFO: spawn C, B, A -> A pops first.
            try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&FiberC.run)), self.cc, .{ .stack_size = .Large });
            try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&FiberB.run)), self.bc, .{ .stack_size = .Large });
            try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&FiberA.run)), self.ac, .{ .stack_size = .Large });
            self.s.wg.wait();
        }
    };
    var main_ctx = Main{ .s = &shared, .ac = &a_ctx, .bc = &b_ctx, .cc = &c_ctx };
    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&Main.run)), &main_ctx, .{ .stack_size = .Large });
    sched.run();

    try std.testing.expect(shared.a_got_deadlock);
    try std.testing.expect(shared.b_acquired_mu1);
    try std.testing.expect(shared.c_acquired_mu2);
    try std.testing.expectEqual(@as(u32, 0), shared.mu1.locked.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), shared.mu2.locked.load(.monotonic));
}

// ─────────────────────────────────────────────────────────────────────────────
// Multi-scheduler stress tests
//
// All preceding tests run on a single scheduler, so the cross-thread paths
// through atomic ops, spin-acquire, and memory ordering are never exercised.
// These tests drive the locks from real OS threads (non-fiber context)
// to shake out races in the tryLock / spin-based fallback paths that are
// used whenever a lock is touched outside the scheduler loop (startup,
// teardown, embedded callers).
// ─────────────────────────────────────────────────────────────────────────────
test "ParkingMutex: cross-thread contention hammer (8 threads, 10K ops)" {
    const N_THREADS: usize = 8;
    const OPS_PER_THREAD: usize = 10_000;
    var mu = ParkingMutex{};
    var counter: usize = 0;

    const Worker = struct {
        fn run(m: *ParkingMutex, c: *usize, iters: usize) void {
            var i: usize = 0;
            while (i < iters) : (i += 1) {
                // tryLock is non-blocking; fall through to spin if contended.
                while (!m.tryLock()) std.atomic.spinLoopHint();
                c.* += 1;
                m.unlock();
            }
        }
    };

    var threads: [N_THREADS]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ &mu, &counter, OPS_PER_THREAD });
    }
    for (&threads) |*t| t.join();

    try std.testing.expectEqual(N_THREADS * OPS_PER_THREAD, counter);
    try std.testing.expectEqual(@as(u32, 0), mu.locked.load(.monotonic));
}

test "ParkingRwLock: cross-thread writers and readers hammer" {
    const N_WRITERS: usize = 4;
    const N_READERS: usize = 4;
    const OPS_PER_WRITER: usize = 5_000;
    const OPS_PER_READER: usize = 5_000;
    var rw = ParkingRwLock{};
    // Single counter protected by rw. Writers increment; readers verify the
    // value is stable across a read-side spin (if it changes under us, the
    // lock is broken).
    var counter: usize = 0;
    var bad_reads: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

    const Writer = struct {
        fn run(l: *ParkingRwLock, c: *usize, iters: usize) void {
            var i: usize = 0;
            while (i < iters) : (i += 1) {
                l.lock() catch continue;
                c.* += 1;
                l.unlock();
            }
        }
    };
    const Reader = struct {
        fn run(l: *ParkingRwLock, c: *usize, br: *std.atomic.Value(usize), iters: usize) void {
            var i: usize = 0;
            while (i < iters) : (i += 1) {
                l.lockShared() catch continue;
                const first = c.*;
                // Spin briefly inside the read lock. If mutual exclusion is
                // broken, a concurrent writer will mutate `counter` here.
                var s: usize = 0;
                while (s < 8) : (s += 1) std.atomic.spinLoopHint();
                const second = c.*;
                if (first != second) _ = br.fetchAdd(1, .monotonic);
                l.unlockShared();
            }
        }
    };

    var threads: [N_WRITERS + N_READERS]std.Thread = undefined;
    for (threads[0..N_WRITERS]) |*t| {
        t.* = try std.Thread.spawn(.{}, Writer.run, .{ &rw, &counter, OPS_PER_WRITER });
    }
    for (threads[N_WRITERS..]) |*t| {
        t.* = try std.Thread.spawn(.{}, Reader.run, .{ &rw, &counter, &bad_reads, OPS_PER_READER });
    }
    for (&threads) |*t| t.join();

    try std.testing.expectEqual(@as(usize, 0), bad_reads.load(.monotonic));
    try std.testing.expectEqual(N_WRITERS * OPS_PER_WRITER, counter);
    try std.testing.expect(!rw.write_locked);
    try std.testing.expectEqual(@as(i32, 0), rw.readers);
}
