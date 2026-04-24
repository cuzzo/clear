// fsm-concurrent-test.zig — Multi-thread concurrent stress for FsmRunQueue.
//
// CONTEXT: FsmRunQueue is a Chase-Lev work-stealing deque. Its algorithm
// is identical to queues.zig:RunQueue, which has exhaustive Loom coverage
// in vopr-loom.zig (scenarios: pop-vs-steal, push-during-steal, etc.).
// The only difference between RunQueue and FsmRunQueue is the element
// type (*Task vs *FsmTask). Memory-ordering correctness therefore
// transfers — if the RunQueue algorithm is race-free under Loom, the
// FsmRunQueue clone is race-free too.
//
// This test is a practical safety net: real OS threads hammering the
// deque and asserting the correctness invariants that Loom already
// proves (no lost tasks, no duplicate tasks, conservation of count).
// It does not replace Loom; it catches duplication/typo bugs in the
// clone that Loom on RunQueue cannot see.
//
// Formal Loom integration for FsmRunQueue atomics can be added by
// extending vopr-loom.zig with FSM scenarios (planned — see
// docs/agents/finite-state-machines.md).

pub const CLEAR_FRAME_DEBUG = false;

const std = @import("std");
const fsm = @import("fsm.zig");

const alloc = std.testing.allocator;

// Dummy FsmTask we can identify by its index. We don't run these as
// real FSMs; we just use FsmTask as a typed handle to push/pop/steal.
const Marker = struct {
    task: fsm.FsmTask,
    id: u32,

    fn bind(self: *Marker, id: u32) void {
        self.id = id;
        self.task = fsm.FsmTask.init(&Marker.never, self);
    }

    fn never(_: *fsm.FsmTask) fsm.YieldReason {
        unreachable; // concurrent test doesn't dispatch
    }
};

// Invariant 1: owner-only push + pop preserves count. No thieves.
// This is a sanity check — if the owner-side algorithm were buggy in the
// clone, we'd see mismatched counts here.
test "concurrent: owner push then pop, all tasks accounted for" {
    var q = try fsm.FsmRunQueue.initWithAllocator(alloc);
    defer q.deinit();

    const N = 5_000;
    const markers = try alloc.alloc(Marker, N);
    defer alloc.free(markers);
    for (markers, 0..) |*m, i| m.bind(@intCast(i));

    for (markers) |*m| try q.push(alloc, &m.task);
    try std.testing.expectEqual(@as(usize, N), q.len());

    var seen = try alloc.alloc(bool, N);
    defer alloc.free(seen);
    @memset(seen, false);

    var popped: usize = 0;
    while (q.pop()) |t| {
        const mp: *Marker = @fieldParentPtr("task", t);
        try std.testing.expect(!seen[mp.id]);
        seen[mp.id] = true;
        popped += 1;
    }
    try std.testing.expectEqual(N, popped);
    for (seen) |s| try std.testing.expect(s);
}

// Invariant 2: owner push/pop concurrent with thief stealOne — NO duplicate
// tasks delivered. Each marker must be popped OR stolen exactly once.
test "concurrent: owner pop races with thief stealOne, no duplicates" {
    var q = try fsm.FsmRunQueue.initWithAllocator(alloc);
    defer q.deinit();

    const N = 10_000;
    const markers = try alloc.alloc(Marker, N);
    defer alloc.free(markers);
    for (markers, 0..) |*m, i| m.bind(@intCast(i));
    for (markers) |*m| try q.push(alloc, &m.task);

    const seen = try alloc.alloc(std.atomic.Value(u8), N);
    defer alloc.free(seen);
    for (seen) |*s| s.* = std.atomic.Value(u8).init(0);

    const owner_done = try alloc.create(std.atomic.Value(bool));
    defer alloc.destroy(owner_done);
    owner_done.* = std.atomic.Value(bool).init(false);

    const popped_count = try alloc.create(std.atomic.Value(u64));
    defer alloc.destroy(popped_count);
    popped_count.* = std.atomic.Value(u64).init(0);

    const stolen_count = try alloc.create(std.atomic.Value(u64));
    defer alloc.destroy(stolen_count);
    stolen_count.* = std.atomic.Value(u64).init(0);

    const Owner = struct {
        fn go(qp: *fsm.FsmRunQueue, seen_: []std.atomic.Value(u8), pc: *std.atomic.Value(u64), done: *std.atomic.Value(bool)) void {
            while (qp.pop()) |t| {
                const mp: *Marker = @fieldParentPtr("task", t);
                const prev = seen_[mp.id].fetchAdd(1, .acq_rel);
                if (prev != 0) @panic("duplicate task in owner pop");
                _ = pc.fetchAdd(1, .release);
            }
            done.store(true, .release);
        }
    };
    const Thief = struct {
        fn go(qp: *fsm.FsmRunQueue, seen_: []std.atomic.Value(u8), sc: *std.atomic.Value(u64), done: *std.atomic.Value(bool)) void {
            while (!done.load(.acquire)) {
                if (qp.stealOne()) |t| {
                    const mp: *Marker = @fieldParentPtr("task", t);
                    const prev = seen_[mp.id].fetchAdd(1, .acq_rel);
                    if (prev != 0) @panic("duplicate task in thief steal");
                    _ = sc.fetchAdd(1, .release);
                } else {
                    std.Thread.yield() catch {};
                }
            }
            // After owner signals done, drain any residual tasks that raced.
            while (qp.stealOne()) |t| {
                const mp: *Marker = @fieldParentPtr("task", t);
                const prev = seen_[mp.id].fetchAdd(1, .acq_rel);
                if (prev != 0) @panic("duplicate task in thief drain");
                _ = sc.fetchAdd(1, .release);
            }
        }
    };

    var owner_thread = try std.Thread.spawn(.{}, Owner.go, .{ &q, seen, popped_count, owner_done });
    var thief_a = try std.Thread.spawn(.{}, Thief.go, .{ &q, seen, stolen_count, owner_done });
    var thief_b = try std.Thread.spawn(.{}, Thief.go, .{ &q, seen, stolen_count, owner_done });
    owner_thread.join();
    thief_a.join();
    thief_b.join();

    const total = popped_count.load(.acquire) + stolen_count.load(.acquire);
    try std.testing.expectEqual(@as(u64, N), total);
    // Every marker saw exactly one observation.
    for (seen) |*s| try std.testing.expectEqual(@as(u8, 1), s.load(.acquire));
}

// Invariant 3: push-during-steal — owner continues pushing while a thief
// is stealing. No push or steal is lost. This mirrors vopr-loom's
// "push during steal" scenario but with real threads.
test "concurrent: owner interleaved push + pop races with thief" {
    var q = try fsm.FsmRunQueue.initWithAllocator(alloc);
    defer q.deinit();

    const N = 10_000;
    const markers = try alloc.alloc(Marker, N);
    defer alloc.free(markers);
    for (markers, 0..) |*m, i| m.bind(@intCast(i));

    const seen = try alloc.alloc(std.atomic.Value(u8), N);
    defer alloc.free(seen);
    for (seen) |*s| s.* = std.atomic.Value(u8).init(0);

    const producer_done = try alloc.create(std.atomic.Value(bool));
    defer alloc.destroy(producer_done);
    producer_done.* = std.atomic.Value(bool).init(false);

    const counter = try alloc.create(std.atomic.Value(u64));
    defer alloc.destroy(counter);
    counter.* = std.atomic.Value(u64).init(0);

    const Producer = struct {
        fn go(qp: *fsm.FsmRunQueue, ms: []Marker, seen_: []std.atomic.Value(u8), cnt: *std.atomic.Value(u64), done: *std.atomic.Value(bool)) void {
            var i: usize = 0;
            // Interleave push + pop: push 8, pop 1, repeat.
            while (i < ms.len) {
                const end = @min(i + 8, ms.len);
                while (i < end) : (i += 1) qp.push(alloc, &ms[i].task) catch unreachable;
                if (qp.pop()) |t| {
                    const mp: *Marker = @fieldParentPtr("task", t);
                    const prev = seen_[mp.id].fetchAdd(1, .acq_rel);
                    if (prev != 0) @panic("duplicate in producer pop");
                    _ = cnt.fetchAdd(1, .release);
                }
            }
            // Drain remaining (non-stolen) tasks.
            while (qp.pop()) |t| {
                const mp: *Marker = @fieldParentPtr("task", t);
                const prev = seen_[mp.id].fetchAdd(1, .acq_rel);
                if (prev != 0) @panic("duplicate in producer drain");
                _ = cnt.fetchAdd(1, .release);
            }
            done.store(true, .release);
        }
    };
    const Thief = struct {
        fn go(qp: *fsm.FsmRunQueue, seen_: []std.atomic.Value(u8), cnt: *std.atomic.Value(u64), done: *std.atomic.Value(bool)) void {
            while (!done.load(.acquire)) {
                if (qp.stealOne()) |t| {
                    const mp: *Marker = @fieldParentPtr("task", t);
                    const prev = seen_[mp.id].fetchAdd(1, .acq_rel);
                    if (prev != 0) @panic("duplicate in thief");
                    _ = cnt.fetchAdd(1, .release);
                } else {
                    std.Thread.yield() catch {};
                }
            }
            while (qp.stealOne()) |t| {
                const mp: *Marker = @fieldParentPtr("task", t);
                const prev = seen_[mp.id].fetchAdd(1, .acq_rel);
                if (prev != 0) @panic("duplicate in thief drain");
                _ = cnt.fetchAdd(1, .release);
            }
        }
    };

    var producer = try std.Thread.spawn(.{}, Producer.go, .{ &q, markers, seen, counter, producer_done });
    var thief = try std.Thread.spawn(.{}, Thief.go, .{ &q, seen, counter, producer_done });
    producer.join();
    thief.join();

    try std.testing.expectEqual(@as(u64, N), counter.load(.acquire));
    for (seen) |*s| try std.testing.expectEqual(@as(u8, 1), s.load(.acquire));
}
