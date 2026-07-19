//! Deterministic retry-exhaustion and lost-update check for Versioned(T).
//!
//! This is a standalone executable so its root-level retry override is
//! visible to runtime/versioned.zig. A Zig test runner supplies a different
//! root module and would silently leave the production retry budget active.

pub const CLEAR_MVCC_MAX_UPDATE_RETRIES: usize = 1;

const std = @import("std");
const ebr_mod = @import("lib/ebr.zig");
const versioned = @import("runtime/versioned.zig");
const Runtime = @import("runtime/runtime.zig").Runtime;

const EbrContext = ebr_mod.EbrContext;

fn drain(ctx: *EbrContext, rt: *Runtime, allocator: std.mem.Allocator) void {
    for (0..4) |_| {
        ctx.reclaim(allocator);
        rt.ebr.reclaimLocal(allocator);
    }
}

const Args = struct {
    ctx: *EbrContext,
    cell: *versioned.Versioned(i64),
    allocator: std.mem.Allocator,
    ready: *std.atomic.Value(usize),
    attempted: *std.atomic.Value(usize),
    exhausted: *std.atomic.Value(usize),
    writer_count: usize,
    iterations: usize,
};

fn writer(args: *Args) void {
    var frame: [4096]u8 = undefined;
    var rt = Runtime.initFromSlice(&frame, args.ctx, args.allocator, 0) catch return;
    defer rt.deinit();
    args.ctx.register(args.allocator, rt.ebr) catch return;
    defer args.ctx.unregister(rt.ebr);

    _ = args.ready.fetchAdd(1, .seq_cst);
    while (args.ready.load(.acquire) < args.writer_count) {
        std.atomic.spinLoopHint();
    }

    for (0..args.iterations) |i| {
        _ = args.attempted.fetchAdd(1, .monotonic);
        args.cell.update(&rt, args.allocator, struct {
            fn increment(value: *i64, _: usize) void {
                // Widen load-to-CAS so simultaneous writers reliably collide.
                for (0..256) |_| std.atomic.spinLoopHint();
                value.* += 1;
            }
        }.increment, .{i}) catch |err| {
            std.debug.assert(err == error.UpdateRetriesExhausted);
            _ = args.exhausted.fetchAdd(1, .seq_cst);
        };
        if ((i & 0x1f) == 0x1f) rt.ebr.reclaimLocal(args.allocator);
    }
}

fn run(allocator: std.mem.Allocator) !void {
    if (versioned.MAX_UPDATE_RETRIES != CLEAR_MVCC_MAX_UPDATE_RETRIES) {
        std.debug.print("retry override inactive: expected {d}, got {d}\n", .{
            CLEAR_MVCC_MAX_UPDATE_RETRIES,
            versioned.MAX_UPDATE_RETRIES,
        });
        return error.OverrideNotActive;
    }

    var ctx = EbrContext{};
    defer ctx.deinit(allocator);

    var main_frame: [4096]u8 = undefined;
    var main_rt = try Runtime.initFromSlice(&main_frame, &ctx, allocator, 0);
    defer main_rt.deinit();
    try ctx.register(allocator, main_rt.ebr);
    defer ctx.unregister(main_rt.ebr);

    var cell = try versioned.Versioned(i64).init(allocator, 0);
    defer {
        cell.deinit(&main_rt, allocator) catch unreachable;
        drain(&ctx, &main_rt, allocator);
    }

    var ready = std.atomic.Value(usize).init(0);
    var attempted = std.atomic.Value(usize).init(0);
    var exhausted = std.atomic.Value(usize).init(0);

    const writer_count = 8;
    const iterations = 100;
    var args: [writer_count]Args = undefined;
    var threads: [writer_count]std.Thread = undefined;
    for (0..writer_count) |i| {
        args[i] = .{
            .ctx = &ctx,
            .cell = &cell,
            .allocator = allocator,
            .ready = &ready,
            .attempted = &attempted,
            .exhausted = &exhausted,
            .writer_count = writer_count,
            .iterations = iterations,
        };
        threads[i] = try std.Thread.spawn(.{}, writer, .{&args[i]});
    }
    for (&threads) |thread| thread.join();

    const attempted_count = attempted.load(.seq_cst);
    const exhausted_count = exhausted.load(.seq_cst);
    if (attempted_count != writer_count * iterations) return error.AttemptCountWrong;
    if (exhausted_count == 0) return error.ExhaustionDidNotFire;

    var guard = cell.read(&main_rt);
    defer guard.release();
    const final_value: usize = @intCast(guard.get().*);
    if (final_value != attempted_count - exhausted_count) {
        std.debug.print("lost update: value={d}, successes={d}\n", .{
            final_value,
            attempted_count - exhausted_count,
        });
        return error.CellValueWrong;
    }

    std.debug.print("versioned exhaustion: {d}/{d} exhausted, no lost updates\n", .{
        exhausted_count,
        attempted_count,
    });
}

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}){};
    defer {
        if (debug_allocator.deinit() == .leak) @panic("versioned exhaustion leaked memory");
    }
    try run(debug_allocator.allocator());
}
