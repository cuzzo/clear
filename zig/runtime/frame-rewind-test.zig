// ═══════════════════════════════════════════════════════════════════════════
// Frame Rewind Test — ArrayList corruption from loop mark rewind
//
// Reproduces bench 24 crash: an ArrayList allocated on the frame allocator
// grows inside a loop. Each loop iteration's saveLoopMark/restoreLoopMark
// rewinds the arena, freeing the ArrayList's backing memory from prior
// iterations. The ArrayList then reads freed/overwritten memory.
//
// Build: zig build-exe frame-rewind-test.zig switch.S onRoot.S -lc -OReleaseFast
// ═══════════════════════════════════════════════════════════════════════════

const std = @import("std");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = CheatHeader.Runtime;
const EbrContext = CheatHeader.EbrContext;
const fc = @import("fiber-core.zig");
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const qs = @import("queues.zig");
const CheatArena = @import("frame.zig").CheatArena;

// Simulate generateJson: build an ArrayList inside a loop with
// saveLoopMark/restoreLoopMark per iteration (what CLEAR emits).
fn testLoopRewind(rt: *Runtime) !void {
    var parts = std.ArrayListUnmanaged([]const u8){};
    defer parts.deinit(rt.frameAlloc());

    // Simulate: FOR i IN (1 ..= 100) -> parts.append(i.toString());
    var i: i64 = 1;
    while (i <= 100) : (i += 1) {
        // saveLoopMark (what CLEAR emits at the top of every loop body)
        const mark = rt.saveLoopMark();

        // Append to ArrayList using frameAlloc
        const s = try CheatLib.intToString(rt.frameAlloc(), i);
        try parts.append(rt.frameAlloc(), s);

        // restoreLoopMark (what CLEAR emits via defer at end of each iteration)
        // THIS IS THE BUG: it rewinds the arena, freeing the ArrayList's
        // backing memory and the intToString result from THIS and PRIOR iterations.
        rt.restoreLoopMark(mark);
    }

    // By here, parts.items points to freed/overwritten memory.
    // join() reads from it and crashes or produces garbage.
    const result = try std.mem.join(rt.frameAlloc(), ",", parts.items);

    // Verify the result has the right length
    if (result.len == 0) return error.EmptyResult;

    // Verify content: should be "1,2,3,...,100"
    if (result[0] != '1') return error.BadContent;
    std.mem.doNotOptimizeAway(result.len);
}

fn workerFn(raw_rt: *anyopaque, _: ?*anyopaque) anyerror!void {
    const rt: *Runtime = @ptrCast(@alignCast(raw_rt));
    // Run the test multiple times to increase chance of catching corruption
    for (0..10) |_| {
        try testLoopRewind(rt);
    }
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    var global_ctx = EbrContext{};
    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();
    const shutdown = std.atomic.Value(bool).init(false);
    _ = shutdown;

    var sched = fp.Scheduler.init(allocator, &global_ctx, &stack_pool) catch return;
    defer sched.deinit();
    sched.shutdown_on_idle = true;
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;

    // Spawn test fiber
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&workerFn)),
        null,
        .{ .stack_size = .Large },
    );

    sched.run();

    // The fiber returns an error if corruption is detected.
    // The scheduler prints "Task Crashed" and continues.
    // We can't easily detect this from main, so just print completion.
    // The test is considered PASS only if NO "Task Crashed" appears in output.
    std.debug.print("DONE: check output for 'Task Crashed' — indicates frame rewind corruption.\n", .{});
}
