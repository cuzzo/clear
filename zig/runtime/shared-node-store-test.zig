const std = @import("std");
const rt_mod = @import("runtime.zig");
const ebr = @import("../lib/ebr.zig");
const CheatLib = @import("runtime-header.zig").CheatLib;

const Runtime = rt_mod.Runtime;

var drops: usize = 0;

const Payload = struct {
    value: u64,

    pub fn deinit(_: *@This(), _: std.mem.Allocator) void {
        drops += 1;
    }
};

test "SharedNodeStore guards growth removal stale handles and runtime RAII" {
    const allocator = std.testing.allocator;
    var context = ebr.EbrContext{};
    defer context.deinit(allocator);

    var rt = try Runtime.init(allocator, 64 * 1024, &context);
    drops = 0;

    const Store = CheatLib.SharedNodeStore(Payload);
    const Ref = CheatLib.NodeRef(Payload);
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Ref));

    const write = try Store.lockWrite(&rt);
    const first = try Store.createBound(write, .{ .value = 1 });
    const survivor = try Store.createBound(write, .{ .value = 2 });
    Store.unlockWrite(write);

    const read = try Store.lockRead(&rt);
    try std.testing.expectEqual(@as(u64, 1), Store.getBound(read, first).?.value);
    try std.testing.expectEqual(@as(u64, 2), Store.getBound(read, survivor).?.value);
    Store.unlockRead(read);

    const remove = try Store.lockWrite(&rt);
    try std.testing.expect(Store.removeBound(remove, first));
    try std.testing.expect(!Store.removeBound(remove, first));
    var i: usize = 0;
    while (i < 4096) : (i += 1) {
        _ = try Store.createBound(remove, .{ .value = @intCast(i + 10) });
    }
    try std.testing.expect(Store.validateBound(remove));
    try std.testing.expectEqual(@as(u64, 2), Store.getBound(remove, survivor).?.value);
    try std.testing.expect(Store.getBound(remove, first) == null);
    Store.unlockWrite(remove);

    try std.testing.expectEqual(@as(usize, 1), drops);
    rt.deinit();
    try std.testing.expectEqual(@as(usize, 4098), drops);
}

test "SharedNodeStore creation rolls back cleanly on allocator failure" {
    const backing = std.testing.allocator;
    var context = ebr.EbrContext{};
    defer context.deinit(backing);

    var rt = try Runtime.init(backing, 64 * 1024, &context);
    defer rt.deinit();

    var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = 0 });
    rt.heap_allocator = failing.allocator();

    const Store = CheatLib.SharedNodeStore(Payload);
    try std.testing.expectError(error.OutOfMemory, Store.lockWrite(&rt));

    // Restore the allocator used to allocate Runtime-owned memory before
    // teardown, then prove a later initialization is still valid.
    rt.heap_allocator = backing;
    const state = try Store.lockWrite(&rt);
    _ = try Store.createBound(state, .{ .value = 7 });
    try std.testing.expect(Store.validateBound(state));
    Store.unlockWrite(state);
}

const Interleaving = struct {
    rt: *Runtime,
    ref: CheatLib.NodeRef(Payload),
    attempted: std.atomic.Value(bool) = .init(false),
    removed: bool = false,
};

fn removeAfterReader(ctx: *Interleaving) void {
    ctx.attempted.store(true, .release);
    const state = StoreForInterleaving.lockWrite(ctx.rt) catch return;
    ctx.removed = StoreForInterleaving.removeBound(state, ctx.ref);
    StoreForInterleaving.unlockWrite(state);
}

const StoreForInterleaving = CheatLib.SharedNodeStore(Payload);

test "SharedNodeStore deterministic reader versus relocation interleaving" {
    const allocator = std.testing.allocator;
    var context = ebr.EbrContext{};
    defer context.deinit(allocator);

    var rt = try Runtime.init(allocator, 64 * 1024, &context);
    defer rt.deinit();

    const write = try StoreForInterleaving.lockWrite(&rt);
    const ref = try StoreForInterleaving.createBound(write, .{ .value = 91 });
    StoreForInterleaving.unlockWrite(write);

    const read = try StoreForInterleaving.lockRead(&rt);
    const ptr = StoreForInterleaving.getBound(read, ref).?;
    var interleaving = Interleaving{ .rt = &rt, .ref = ref };
    const thread = try std.Thread.spawn(.{}, removeAfterReader, .{&interleaving});
    while (!interleaving.attempted.load(.acquire)) std.atomic.spinLoopHint();

    // The writer has reached lockWrite but cannot remove or relocate this
    // payload while the reader's raw pointer is live.
    try std.testing.expectEqual(@as(u64, 91), ptr.value);
    try std.testing.expect(!interleaving.removed);
    StoreForInterleaving.unlockRead(read);
    thread.join();

    try std.testing.expect(interleaving.removed);
    const verify = try StoreForInterleaving.lockRead(&rt);
    try std.testing.expect(StoreForInterleaving.getBound(verify, ref) == null);
    StoreForInterleaving.unlockRead(verify);
}
