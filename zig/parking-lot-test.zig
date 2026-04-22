pub const CLEAR_FRAME_DEBUG = false;

const std = @import("std");
const fm = @import("runtime/fiber-memory.zig");
const fp = @import("runtime/scheduler.zig");
const ebr_mod = @import("lib/ebr.zig");
const CheatHeader = @import("runtime/runtime-header.zig");
const pl = @import("lib/parking-lot.zig");

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
            wc.s.mu.lock();
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
            wc.s.mu.lock();
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
            rc.s.rw.lockShared();
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
            wc.s.rw.lock();
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
                wc.s.rw.lock();
                wc.s.write_count += 1;
                wc.s.rw.unlock();
            } else {
                wc.s.rw.lockShared();
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
            var wg = c.l.write();
            wg.get().* = 42;
            wg.release();
            // Read back
            var rg = c.l.read();
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
                wc.s.mu.lock();
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
                wc.s.rw.lock();
                wc.s.write_count += 1;
                wc.s.rw.unlock();
            } else {
                wc.s.rw.lockShared();
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

// Note: AB/BA cycle detection is tested manually — Zig 0.16 has no
// std.testing.expectPanic. To reproduce: run the binary with two fibers
// where A holds mu_a and waits for mu_b while B holds mu_b and waits for
// mu_a. The second lock attempt will print "DEADLOCK: lock cycle detected"
// and @panic before either fiber parks.
