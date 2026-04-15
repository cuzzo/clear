const std = @import("std");
const rt_mod = @import("runtime.zig");
const fp = @import("scheduler.zig");
const ebr = @import("../lib/ebr.zig");

const Runtime = rt_mod.Runtime;
const alloc = std.testing.allocator;

test "Runtime.initFromSlice sets non-owning frame memory and timeout deadline" {
    var global_ebr: ebr.EbrContext = .{};
    defer global_ebr.deinit(alloc);

    var buf: [4096]u8 = undefined;
    var rt = try Runtime.initFromSlice(buf[0..], &global_ebr, alloc, 10);
    defer rt.deinit();

    try std.testing.expect(!rt.owns_frame_memory);
    try std.testing.expect(rt.deadline > 0);
}

test "Runtime.saveFrameMark and restoreFrameMark rewind frame allocations" {
    var global_ebr: ebr.EbrContext = .{};
    defer global_ebr.deinit(alloc);

    var buf: [4096]u8 = undefined;
    var rt = try Runtime.initFromSlice(buf[0..], &global_ebr, alloc, 0);
    defer rt.deinit();
    rt.wireAllocator();

    const mark = rt.saveFrameMark();
    _ = try rt.frameAlloc().alloc(u8, 128);
    _ = try rt.frameAlloc().alloc(u8, 64);
    try std.testing.expect(rt.overflow_arena.currentBytes() > 0);

    rt.restoreFrameMark(mark);

    try std.testing.expectEqual(@as(usize, 0), rt.overflow_arena.currentBytes());
}

test "Runtime.arena_mode disables restoreFrameMark rewind" {
    var global_ebr: ebr.EbrContext = .{};
    defer global_ebr.deinit(alloc);

    var buf: [4096]u8 = undefined;
    var rt = try Runtime.initFromSlice(buf[0..], &global_ebr, alloc, 0);
    defer rt.deinit();
    rt.wireAllocator();
    rt.arena_mode = true;

    const mark = rt.saveFrameMark();
    _ = try rt.frameAlloc().alloc(u8, 96);
    const before = rt.overflow_arena.currentBytes();
    rt.restoreFrameMark(mark);

    try std.testing.expectEqual(before, rt.overflow_arena.currentBytes());
}

test "Runtime.frameAlloc and heapAlloc use pinned local allocator when present" {
    var global_ebr: ebr.EbrContext = .{};
    defer global_ebr.deinit(alloc);

    var buf: [4096]u8 = undefined;
    var rt = try Runtime.initFromSlice(buf[0..], &global_ebr, alloc, 0);
    defer rt.deinit();
    rt.wireAllocator();

    const frame_before = rt.frameAlloc();
    const heap_before = rt.heapAlloc();
    try std.testing.expectEqual(rt.frame_allocator.ptr, frame_before.ptr);
    try std.testing.expectEqual(alloc.ptr, heap_before.ptr);

    fp.__pinned_local_alloc = alloc;
    defer fp.__pinned_local_alloc = null;

    try std.testing.expectEqual(alloc.ptr, rt.frameAlloc().ptr);
    try std.testing.expectEqual(alloc.ptr, rt.heapAlloc().ptr);
}

test "Runtime.getSched returns active scheduler" {
    var fake_sched: fp.Scheduler = undefined;
    fp.active_scheduler = &fake_sched;
    defer fp.active_scheduler = undefined;

    try std.testing.expectEqual(&fake_sched, Runtime.getSched(undefined));
}
