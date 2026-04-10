// ═══════════════════════════════════════════════════════════════════════════
// I/O Pressure Cooker — Scheduler Stress Test
//
// Creates 1000 pipes. Spawns 1000 fibers, each blocking on read().
// Writes 1 byte to all 1000 pipes rapidly, then verifies all 1000
// fibers wake up and read successfully.
//
// Tests:
//   - Epoll registration under load (1000 concurrent FDs)
//   - EventFD notification correctness (no lost wakeups)
//   - Ready queue handling of mass simultaneous unblocks
//   - Scheduler stability under I/O pressure
//
// Known limitations (v0.1-pre):
//   - No io_uring batching (each read is a separate epoll registration)
//   - No backpressure on pipe writes (assumes kernel buffer absorbs)
//   - Single scheduler only (multi-scheduler I/O not yet tested)
//
// Build: zig build-exe zig/io-pressure-test.zig -lc zig/switch.S zig/onRoot.S --name io-pressure-test -O ReleaseFast
// Run:   ./io-pressure-test
// ═══════════════════════════════════════════════════════════════════════════

const std = @import("std");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = CheatHeader.Runtime;
const EbrContext = CheatHeader.EbrContext;
const fc = @import("fiber-core.zig");
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");

const NUM_PIPES = 1000;
const ROUNDS = 5;

const PipeSet = struct {
    read_fds: [NUM_PIPES]i32,
    write_fds: [NUM_PIPES]i32,
};

// Reader fiber: blocks on CheatLib.read(), writes result to done flag
const ReaderCtx = struct {
    pipe_fd: i32,
    result: std.atomic.Value(u8),
    round: *std.atomic.Value(usize),

    fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
        const rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
        _ = rt;
        const ctx = @as(*ReaderCtx, @ptrCast(@alignCast(raw_args.?)));
        var buf: [1]u8 = undefined;
        for (0..ROUNDS) |_| {
            const n = try CheatLib.read(ctx.pipe_fd, &buf);
            if (n == 1) {
                _ = ctx.round.fetchAdd(1, .release);
                ctx.result.store(buf[0], .release);
            }
        }
    }
};

fn cheatMain(rt: *Runtime) !void {
    const allocator = std.heap.c_allocator;

    // Create pipes (set read end to non-blocking for epoll)
    var pipes: PipeSet = undefined;
    for (0..NUM_PIPES) |i| {
        const fds = try std.posix.pipe2(.{ .NONBLOCK = true });
        pipes.read_fds[i] = fds[0];
        pipes.write_fds[i] = fds[1];
    }
    defer for (0..NUM_PIPES) |i| {
        std.posix.close(pipes.read_fds[i]);
        std.posix.close(pipes.write_fds[i]);
    };

    // Track completion
    var completed = std.atomic.Value(usize).init(0);

    // Spawn reader fibers
    var ctxs: []ReaderCtx = try allocator.alloc(ReaderCtx, NUM_PIPES);
    defer allocator.free(ctxs);

    var wg = CheatHeader.WaitGroup.init(rt.getSched());
    wg.add(NUM_PIPES);

    const WgWrapper = struct {
        inner: *ReaderCtx,
        wg: *CheatHeader.WaitGroup,
        fn run(raw_rt2: *anyopaque, raw_args2: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw_args2.?)));
            defer self.wg.done();
            try ReaderCtx.run(raw_rt2, @ptrCast(self.inner));
        }
    };

    var wrappers: []WgWrapper = try allocator.alloc(WgWrapper, NUM_PIPES);
    defer allocator.free(wrappers);

    for (0..NUM_PIPES) |i| {
        ctxs[i] = .{
            .pipe_fd = pipes.read_fds[i],
            .result = std.atomic.Value(u8).init(0),
            .round = &completed,
        };
        wrappers[i] = .{ .inner = &ctxs[i], .wg = &wg };
        try fp.active_scheduler.submitSpawn(
            @intFromPtr(&Runtime.entryWrapper),
            @as(CheatHeader.TaskFn, @ptrCast(&WgWrapper.run)),
            &wrappers[i],
            .{},
        );
    }

    // Give fibers time to register with epoll
    // (yield a few times so the scheduler runs them)
    for (0..100) |_| {
        const task = fp.active_scheduler.getCurrent();
        task.status.store(.Ready, .release);
        task.base.yield();
    }

    // Fire: write 1 byte to each pipe per round
    for (0..ROUNDS) |round| {
        const byte: [1]u8 = .{@intCast(round + 1)};
        for (0..NUM_PIPES) |i| {
            _ = std.posix.write(pipes.write_fds[i], &byte) catch {};
        }

        // Yield to let readers process
        for (0..200) |_| {
            const task = fp.active_scheduler.getCurrent();
            task.status.store(.Ready, .release);
            task.base.yield();
        }
    }

    // Wait for all readers to finish
    wg.wait();

    const total_reads = completed.load(.acquire);
    const expected = NUM_PIPES * ROUNDS;

    std.debug.print("Pipes: {d}  Rounds: {d}\n", .{ NUM_PIPES, ROUNDS });
    std.debug.print("Total reads: {d}/{d}\n", .{ total_reads, expected });

    if (total_reads == expected) {
        std.debug.print("PASSED: All {d} I/O operations completed — zero lost wakeups\n", .{expected});
    } else {
        std.debug.print("FAILED: {d} wakeups lost!\n", .{ expected - total_reads });
        std.posix.exit(1);
    }
}

// ── Minimal runtime bootstrap (single scheduler) ──
pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);

    var rt = try Runtime.init(allocator, 4 * 1024 * 1024, &global_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();

    var shutdown = std.atomic.Value(bool).init(false);

    var sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer {
        sched.deinit();
        fp.global_registry.deinit(allocator);
    }
    sched.global_shutdown = &shutdown;
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;

    const MainRunner = struct {
        outer_rt: *Runtime,
        fn run(_: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw_args.?));
            try cheatMain(self.outer_rt);
        }
    };
    var main_runner = MainRunner{ .outer_rt = &rt };
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&MainRunner.run)),
        &main_runner,
        .{ .stack_size = .Large },
    );
    sched.run();
    shutdown.store(true, .release);
}
