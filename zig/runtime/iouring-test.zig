// io_uring readFile integration tests.
//
// These tests exercise CheatLib.readFile when a scheduler (and therefore
// io_uring ring) is active, proving that:
//   1. A single fiber can read a file via io_uring and get correct contents.
//   2. Multiple concurrent fibers can each read different files and all
//      receive the correct data (no cross-talk, no corruption).
//
// Run: zig test zig/iouring-test.zig -lc zig/switch.S zig/onRoot.S

const std = @import("std");
const header = @import("runtime-header.zig");
const CheatLib = header.CheatLib;
const Runtime = header.Runtime;
const TaskFn = header.TaskFn;
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const EbrContext = @import("ebr").EbrContext;

const TEST_DIR = "/tmp/clear_iouring_test";

// ---------------------------------------------------------------------------
// Boot helper: run a function inside the scheduler (mirrors runtime-footer).
// ---------------------------------------------------------------------------
fn runInScheduler(comptime userFn: fn (*Runtime) anyerror!void) !void {
    const allocator = std.heap.page_allocator;

    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);

    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();

    var sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer {
        sched.deinit();
        fp.global_registry.deinit(allocator);
    }
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;
    defer {
        fp.scheduler_running = false;
    }

    var rt = try Runtime.init(allocator, 4 * 1024 * 1024, &global_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    const Runner = struct {
        outer_rt: *Runtime,
        fn run(_: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw_args.?));
            try userFn(self.outer_rt);
        }
    };
    var runner = Runner{ .outer_rt = &rt };

    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(TaskFn, @ptrCast(&Runner.run)),
        @as(?*anyopaque, @ptrCast(&runner)),
        .{ .stack_size = .Large },
    );
    sched.run();
}

// ---------------------------------------------------------------------------
// Helpers: create / cleanup test files.
// ---------------------------------------------------------------------------
fn ensureTestFiles() !void {
    std.fs.cwd().makePath(TEST_DIR) catch {};

    for (0..4) |i| {
        var path_buf: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, TEST_DIR ++ "/file{d}.txt", .{i}) catch unreachable;

        var content_buf: [256]u8 = undefined;
        const content = std.fmt.bufPrint(&content_buf, "hello from file {d}\n", .{i}) catch unreachable;

        const f = try std.fs.cwd().createFile(path, .{});
        defer f.close();
        try f.writeAll(content);
    }
}

fn cleanupTestFiles() void {
    std.fs.cwd().deleteTree(TEST_DIR) catch {};
}

// ---------------------------------------------------------------------------
// Test 1: Single-fiber readFile via io_uring returns correct content.
// ---------------------------------------------------------------------------
fn singleFileReadBody(rt: *Runtime) !void {
    const data = try CheatLib.readFile(rt.heapAlloc(), TEST_DIR ++ "/file0.txt");
    try std.testing.expectEqualStrings("hello from file 0\n", data);
}

test "io_uring single-fiber readFile" {
    try ensureTestFiles();
    defer cleanupTestFiles();
    try runInScheduler(singleFileReadBody);
}

// ---------------------------------------------------------------------------
// Test 2: Read all 4 files sequentially within one fiber, via io_uring.
//         Each read yields to the scheduler and resumes on CQE.
// ---------------------------------------------------------------------------
fn sequentialMultiReadBody(rt: *Runtime) !void {
    for (0..4) |i| {
        var path_buf: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, TEST_DIR ++ "/file{d}.txt", .{i}) catch unreachable;

        const data = try CheatLib.readFile(rt.heapAlloc(), path);

        var expected_buf: [256]u8 = undefined;
        const expected = std.fmt.bufPrint(&expected_buf, "hello from file {d}\n", .{i}) catch unreachable;

        try std.testing.expectEqualStrings(expected, data);
    }
}

test "io_uring sequential multi-read within one fiber" {
    try ensureTestFiles();
    defer cleanupTestFiles();
    try runInScheduler(sequentialMultiReadBody);
}

// ---------------------------------------------------------------------------
// Test 3: Two concurrent fibers each read two files; results are correct.
//         Uses Promise(i64) to synchronise — exercises CQE dispatch to the
//         right fiber when multiple SQEs are in-flight simultaneously.
// ---------------------------------------------------------------------------
const SharedResults = struct {
    data: [4]i64 = .{ -1, -1, -1, -1 },
};

fn concurrentReadBody(rt: *Runtime) !void {
    const alloc = rt.heapAlloc();
    const sched = fp.active_scheduler;

    // Two promises: fiber A reads files 0,1; fiber B reads files 2,3.
    var promise_a = try CheatLib.Promise(i64).spawn(alloc, sched);
    var promise_b = try CheatLib.Promise(i64).spawn(alloc, sched);

    const FiberA = struct {
        alloc: std.mem.Allocator,
        inner: *CheatLib.Promise(i64).Inner,

        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            var ok: i64 = 1;
            for (0..2) |i| {
                var path_buf: [128]u8 = undefined;
                const path = std.fmt.bufPrint(&path_buf, TEST_DIR ++ "/file{d}.txt", .{i}) catch unreachable;
                const data = try CheatLib.readFile(self.alloc, path);

                var exp_buf: [256]u8 = undefined;
                const exp = std.fmt.bufPrint(&exp_buf, "hello from file {d}\n", .{i}) catch unreachable;
                if (!std.mem.eql(u8, data, exp)) ok = 0;
            }
            self.inner.result = ok;
            self.inner.wg.done();
        }
    };

    const FiberB = struct {
        alloc: std.mem.Allocator,
        inner: *CheatLib.Promise(i64).Inner,

        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            var ok: i64 = 1;
            for (2..4) |i| {
                var path_buf: [128]u8 = undefined;
                const path = std.fmt.bufPrint(&path_buf, TEST_DIR ++ "/file{d}.txt", .{i}) catch unreachable;
                const data = try CheatLib.readFile(self.alloc, path);

                var exp_buf: [256]u8 = undefined;
                const exp = std.fmt.bufPrint(&exp_buf, "hello from file {d}\n", .{i}) catch unreachable;
                if (!std.mem.eql(u8, data, exp)) ok = 0;
            }
            self.inner.result = ok;
            self.inner.wg.done();
        }
    };

    const ctx_a = try alloc.create(FiberA);
    ctx_a.* = .{ .alloc = alloc, .inner = promise_a.inner };
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(TaskFn, @ptrCast(&FiberA.run)),
        @as(?*anyopaque, @ptrCast(ctx_a)),
        .{ .stack_size = .Large },
    );

    const ctx_b = try alloc.create(FiberB);
    ctx_b.* = .{ .alloc = alloc, .inner = promise_b.inner };
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(TaskFn, @ptrCast(&FiberB.run)),
        @as(?*anyopaque, @ptrCast(ctx_b)),
        .{ .stack_size = .Large },
    );

    // Wait for both fibers.
    const result_a = promise_a.next();
    const result_b = promise_b.next();

    try std.testing.expectEqual(@as(i64, 1), result_a);
    try std.testing.expectEqual(@as(i64, 1), result_b);
}

test "io_uring concurrent two-fiber readFile" {
    try ensureTestFiles();
    defer cleanupTestFiles();
    try runInScheduler(concurrentReadBody);
}

// ---------------------------------------------------------------------------
// Test 4: Repeated read/yield pressure on a live scheduler.
//         This specifically exercises the run() loop pattern of:
//           io_uring drain -> fiber switch -> fiber yield -> io_uring drain
//         many times in succession.
// ---------------------------------------------------------------------------
fn repeatedReadYieldBody(rt: *Runtime) !void {
    var checksum: usize = 0;

    for (0..200) |_| {
        for (0..4) |i| {
            var path_buf: [128]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, TEST_DIR ++ "/file{d}.txt", .{i}) catch unreachable;

            const data = try CheatLib.readFile(rt.heapAlloc(), path);

            var expected_buf: [256]u8 = undefined;
            const expected = std.fmt.bufPrint(&expected_buf, "hello from file {d}\n", .{i}) catch unreachable;

            try std.testing.expectEqualStrings(expected, data);
            checksum +%= data.len;
            rt.checkYield();
        }
    }

    try std.testing.expect(checksum > 0);
}

test "io_uring repeated read/yield pressure" {
    try ensureTestFiles();
    defer cleanupTestFiles();
    try runInScheduler(repeatedReadYieldBody);
}
