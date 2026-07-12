const std = @import("std");
const rt_mod = @import("runtime.zig");
const ebr = @import("../lib/ebr.zig");
const CheatLib = @import("runtime-header.zig").CheatLib;

const Runtime = rt_mod.Runtime;
const Payload = struct { left: u64, right: u64 };
const Store = CheatLib.SharedNodeStore(Payload);
const Ref = CheatLib.NodeRef(Payload);

const Context = struct {
    rt: *Runtime,
    root: Ref,
    failed: std.atomic.Value(bool) = .init(false),
};

fn reader(ctx: *Context) void {
    var iteration: usize = 0;
    while (iteration < 20_000) : (iteration += 1) {
        const state = Store.lockRead(ctx.rt) catch {
            ctx.failed.store(true, .release);
            return;
        };
        const value = Store.getBound(state, ctx.root) orelse {
            Store.unlockRead(state);
            ctx.failed.store(true, .release);
            return;
        };
        if (value.left != value.right) ctx.failed.store(true, .release);
        Store.unlockRead(state);
    }
}

fn writer(ctx: *Context) void {
    var iteration: usize = 0;
    while (iteration < 5_000) : (iteration += 1) {
        const state = Store.lockWrite(ctx.rt) catch {
            ctx.failed.store(true, .release);
            return;
        };
        const value = Store.getBound(state, ctx.root) orelse {
            Store.unlockWrite(state);
            ctx.failed.store(true, .release);
            return;
        };
        const next = value.left + 1;
        value.left = next;
        value.right = next;

        // Force dense relocation and repeated generation changes while readers
        // continuously resolve the surviving root handle.
        const temporary = Store.createBound(state, .{ .left = next, .right = next }) catch {
            Store.unlockWrite(state);
            ctx.failed.store(true, .release);
            return;
        };
        if (!Store.removeBound(state, temporary) or !Store.validateBound(state)) {
            ctx.failed.store(true, .release);
        }
        Store.unlockWrite(state);
    }
}

test "SharedNodeStore TSan hammer serializes pointer relocation and payload mutation" {
    const allocator = std.testing.allocator;
    var ebr_context = ebr.EbrContext{};
    defer ebr_context.deinit(allocator);

    var rt = try Runtime.init(allocator, 64 * 1024, &ebr_context);
    defer rt.deinit();

    const state = try Store.lockWrite(&rt);
    const root = try Store.createBound(state, .{ .left = 0, .right = 0 });
    Store.unlockWrite(state);

    var ctx = Context{ .rt = &rt, .root = root };
    var threads: [8]std.Thread = undefined;
    threads[0] = try std.Thread.spawn(.{}, writer, .{&ctx});
    threads[1] = try std.Thread.spawn(.{}, writer, .{&ctx});
    for (threads[2..]) |*thread| thread.* = try std.Thread.spawn(.{}, reader, .{&ctx});
    for (threads) |thread| thread.join();

    try std.testing.expect(!ctx.failed.load(.acquire));
    const final = try Store.lockRead(&rt);
    try std.testing.expectEqual(@as(u64, 10_000), Store.getBound(final, root).?.left);
    try std.testing.expectEqual(Store.getBound(final, root).?.left, Store.getBound(final, root).?.right);
    Store.unlockRead(final);
}
