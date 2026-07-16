const std = @import("std");
const rt_mod = @import("runtime.zig");
const fp = @import("scheduler.zig");
const qs = @import("queues.zig");
const fm = @import("fiber-memory.zig");
const fsm = @import("fsm.zig");
const ebr = @import("../lib/ebr.zig");
const header = @import("runtime-header.zig");
const compat = @import("../lib/compat.zig");
const alloc_profile = @import("alloc-profile.zig");

// Import the C library
const c = @cImport({
    @cInclude("time.h");
    @cInclude("unistd.h");
});

const CheatLib = header.CheatLib;
const Runtime = rt_mod.Runtime;
const alloc = std.heap.c_allocator;

test "makeListCapacity honors a minimum above the initial item count" {
    const allocator = std.testing.allocator;
    const items = [_]u64{ 3, 5 };
    var list = try CheatLib.makeListCapacity(u64, allocator, &items, 16);
    defer list.deinit(allocator);

    try std.testing.expectEqualSlices(u64, &items, list.items);
    try std.testing.expect(list.capacity >= 16);
}

test "Grid is empty by default and rankGet uses checked row-major offsets" {
    var grid: CheatLib.Grid(u64, 2) = .empty;
    defer grid.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), grid.items.len);
    try std.testing.expectEqual([2]usize{ 0, 0 }, grid.shape);

    var values = [6]u64{ 10, 11, 12, 20, 21, 22 };
    try std.testing.expectEqual(@as(u64, 22), CheatLib.rankGet(values, [2]usize{ 2, 3 }, [2]usize{ 1, 2 }));
    CheatLib.rankSet(&values, [2]usize{ 2, 3 }, [2]usize{ 0, 1 }, 99);
    try std.testing.expectEqual(@as(u64, 99), values[1]);
}

test "AtomicPtr fiber retains keep the cell and managed payload alive until the final release" {
    const allocator = std.testing.allocator;
    const Payload = struct { text: []const u8 };
    const owned = try allocator.dupe(u8, "retained");
    const cell = try CheatLib.atomicPtrCreate(Payload, allocator, .{ .text = owned });
    const Cell = @TypeOf(cell.*);

    const captured = CheatLib.atomicPtrRetain(Cell, cell);
    try std.testing.expectEqual(@as(usize, 2), cell.refs.load(.acquire));
    CheatLib.atomicPtrRelease(Cell, allocator, cell);
    try std.testing.expectEqualStrings("retained", captured.ptr.load(.acquire).?.text);
    CheatLib.atomicPtrRelease(Cell, allocator, captured);
}

const ArcTeardownGate = struct {
    deinit_entered: std.atomic.Value(bool) = .init(false),
    may_finish: std.atomic.Value(bool) = .init(false),
};

const BlockingArcPayload = struct {
    gate: *ArcTeardownGate,

    pub fn deinit(self: *@This(), _: std.mem.Allocator) void {
        self.gate.deinit_entered.store(true, .release);
        while (!self.gate.may_finish.load(.acquire)) std.atomic.spinLoopHint();
    }
};

fn releaseBlockingArc(arc: CheatLib.Arc(BlockingArcPayload)) void {
    CheatLib.arcRelease(BlockingArcPayload, std.testing.allocator, arc);
}

test "dupeValue promotes a fixed array into an owned ArrayList" {
    const allocator = std.testing.allocator;
    const source = [3]i64{ 4, 5, 6 };
    var copied = try CheatLib.dupeValue(std.ArrayListUnmanaged(i64), source, allocator);
    defer copied.deinit(allocator);

    try std.testing.expectEqualSlices(i64, source[0..], copied.items);
}

test "dupeValue retains Rc Arc and Weak handles instead of cloning control blocks" {
    const allocator = std.testing.allocator;

    const rc = try CheatLib.rcCreate(u64, allocator, 7);
    const rc_copy = try CheatLib.dupeValue(CheatLib.Rc(u64), rc, allocator);
    try std.testing.expectEqual(rc.ctrl, rc_copy.ctrl);
    try std.testing.expectEqual(@as(usize, 2), rc.ctrl.strong);
    CheatLib.rcRelease(u64, allocator, rc_copy);

    const weak = CheatLib.rcDowngrade(u64, rc);
    const weak_copy = try CheatLib.dupeValue(CheatLib.WeakRc(u64), weak, allocator);
    try std.testing.expectEqual(weak.ctrl, weak_copy.ctrl);
    CheatLib.weakRcRelease(u64, allocator, weak_copy);
    CheatLib.weakRcRelease(u64, allocator, weak);
    CheatLib.rcRelease(u64, allocator, rc);

    const arc = try CheatLib.arcCreate(u64, allocator, 9);
    const arc_copy = try CheatLib.dupeValue(CheatLib.Arc(u64), arc, allocator);
    try std.testing.expectEqual(arc.ctrl, arc_copy.ctrl);
    try std.testing.expectEqual(@as(usize, 2), arc.ctrl.strong.load(.acquire));
    CheatLib.arcRelease(u64, allocator, arc_copy);
    CheatLib.arcRelease(u64, allocator, arc);
}

test "Arc recursively destroys managed fields in ordinary payload structs" {
    const allocator = std.testing.allocator;
    const Managed = struct { text: []u8 };
    const text = try allocator.dupe(u8, "owned by Arc");
    const arc = try CheatLib.arcCreate(Managed, allocator, .{ .text = text });

    CheatLib.arcRelease(Managed, allocator, arc);
}

test "arcCreate rolls back every partial allocation on OOM" {
    var fail_index: usize = 0;
    while (fail_index < 2) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        try std.testing.expectError(
            error.OutOfMemory,
            CheatLib.arcCreate(u64, failing.allocator(), 42),
        );
    }
}

test "Arc cleanup covers managed optional list union and nested struct payloads" {
    const allocator = std.testing.allocator;
    const Choice = union(enum) { text: []u8, none: void };
    const Nested = struct { text: []u8 };
    const Managed = struct {
        direct: []u8,
        optional: ?[]u8,
        list: std.ArrayListUnmanaged([]u8),
        choice: Choice,
        nested: Nested,
    };

    var list: std.ArrayListUnmanaged([]u8) = .empty;
    try list.append(allocator, try allocator.dupe(u8, "list item"));
    const arc = try CheatLib.arcCreate(Managed, allocator, .{
        .direct = try allocator.dupe(u8, "direct"),
        .optional = try allocator.dupe(u8, "optional"),
        .list = list,
        .choice = .{ .text = try allocator.dupe(u8, "union") },
        .nested = .{ .text = try allocator.dupe(u8, "nested") },
    });
    CheatLib.arcRelease(Managed, allocator, arc);
}

test "last strong and last explicit WeakArc may be released during payload destruction" {
    var gate = ArcTeardownGate{};
    const arc = try CheatLib.arcCreate(
        BlockingArcPayload,
        std.testing.allocator,
        .{ .gate = &gate },
    );
    const weak = CheatLib.arcDowngrade(BlockingArcPayload, arc);
    const release_thread = try std.Thread.spawn(.{}, releaseBlockingArc, .{arc});

    while (!gate.deinit_entered.load(.acquire)) std.atomic.spinLoopHint();

    // The strong count is already zero, but strong teardown still owns an
    // implicit weak reference until payload destruction is complete.
    CheatLib.weakArcRelease(BlockingArcPayload, weak);

    gate.may_finish.store(true, .release);
    release_thread.join();
}

test "dupeValue retains Rc Arc through optional struct union and list shapes" {
    const allocator = std.testing.allocator;
    const RcU64 = CheatLib.Rc(u64);
    const ArcU64 = CheatLib.Arc(u64);
    const Holder = struct {
        optional: ?RcU64,
        shared: ArcU64,
        refs: std.ArrayListUnmanaged(RcU64),
    };
    const Choice = union(enum) { item: RcU64, none: void };

    const rc = try CheatLib.rcCreate(u64, allocator, 11);
    const arc = try CheatLib.arcCreate(u64, allocator, 13);
    var refs: std.ArrayListUnmanaged(RcU64) = .empty;
    try refs.append(allocator, CheatLib.rcRetain(u64, rc));
    var holder = Holder{ .optional = rc, .shared = arc, .refs = refs };

    var holder_copy = try CheatLib.dupeValue(Holder, holder, allocator);
    try std.testing.expectEqual(@as(usize, 4), rc.ctrl.strong);
    try std.testing.expectEqual(@as(usize, 2), arc.ctrl.strong.load(.acquire));
    CheatLib.cleanup(Holder, allocator, &holder_copy);
    try std.testing.expectEqual(@as(usize, 2), rc.ctrl.strong);
    try std.testing.expectEqual(@as(usize, 1), arc.ctrl.strong.load(.acquire));

    var choice = Choice{ .item = CheatLib.rcRetain(u64, rc) };
    var choice_copy = try CheatLib.dupeValue(Choice, choice, allocator);
    try std.testing.expectEqual(@as(usize, 4), rc.ctrl.strong);
    CheatLib.cleanup(Choice, allocator, &choice_copy);
    CheatLib.cleanup(Choice, allocator, &choice);
    CheatLib.cleanup(Holder, allocator, &holder);
}

var global_ebr_ctx: ebr.EbrContext = .{};
var global_stack_pool: fm.StackPool = undefined;
var global_shutdown = std.atomic.Value(bool).init(false);
var node_store_drop_count: usize = 0;
var arc_payload_drop_count: usize = 0;

const CountedArcPayload = struct {
    text: []u8,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        arc_payload_drop_count += 1;
        allocator.free(self.text);
    }
};

test "Arc payload destructor runs exactly once at the final strong release" {
    const allocator = std.testing.allocator;
    arc_payload_drop_count = 0;
    const arc = try CheatLib.arcCreate(CountedArcPayload, allocator, .{
        .text = try allocator.dupe(u8, "counted"),
    });
    const retained = CheatLib.arcRetain(CountedArcPayload, arc);
    const weak = CheatLib.arcDowngrade(CountedArcPayload, arc);

    CheatLib.arcRelease(CountedArcPayload, allocator, retained);
    try std.testing.expectEqual(@as(usize, 0), arc_payload_drop_count);
    CheatLib.arcRelease(CountedArcPayload, allocator, arc);
    try std.testing.expectEqual(@as(usize, 1), arc_payload_drop_count);
    try std.testing.expect(CheatLib.weakArcUpgrade(CountedArcPayload, weak) == null);
    CheatLib.weakArcRelease(CountedArcPayload, weak);
    try std.testing.expectEqual(@as(usize, 1), arc_payload_drop_count);
}

test "Arc lock-wrapper payload cleanup ignores non-owning lock internals" {
    const allocator = std.testing.allocator;
    const Payload = struct { text: []u8 };

    const locked = try CheatLib.arcCreate(
        CheatLib.Locked(Payload),
        allocator,
        CheatLib.Locked(Payload).init(.{ .text = try allocator.dupe(u8, "locked") }),
    );
    CheatLib.arcRelease(CheatLib.Locked(Payload), allocator, locked);

    const rw_locked = try CheatLib.arcCreate(
        CheatLib.RwLocked(Payload),
        allocator,
        CheatLib.RwLocked(Payload).init(.{ .text = try allocator.dupe(u8, "rw-locked") }),
    );
    CheatLib.arcRelease(CheatLib.RwLocked(Payload), allocator, rw_locked);
}

test "dupeValue rolls back every initialized managed field under allocator failure" {
    const Managed = struct {
        direct: []u8,
        optional: ?[]u8,
        list: std.ArrayListUnmanaged([]u8),
    };
    const allocator = std.testing.allocator;
    var source_list: std.ArrayListUnmanaged([]u8) = .empty;
    try source_list.append(allocator, try allocator.dupe(u8, "list"));
    var source = Managed{
        .direct = try allocator.dupe(u8, "direct"),
        .optional = try allocator.dupe(u8, "optional"),
        .list = source_list,
    };
    defer CheatLib.cleanup(Managed, allocator, &source);

    var fail_index: usize = 0;
    var failures: usize = 0;
    while (fail_index < 16) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(
            allocator,
            .{ .fail_index = fail_index },
        );
        var copied = CheatLib.dupeValue(Managed, source, failing.allocator()) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            failures += 1;
            continue;
        };
        CheatLib.cleanup(Managed, failing.allocator(), &copied);
        break;
    }
    try std.testing.expect(failures >= 4);
    try std.testing.expect(fail_index < 16);
}

test "dupeValue copies recursive indirect structs and rolls back every allocation failure" {
    const Node = struct {
        name: []u8,
        next: ?*@This(),
    };
    const allocator = std.testing.allocator;
    const leaf = try allocator.create(Node);
    leaf.* = .{
        .name = try allocator.dupe(u8, "leaf"),
        .next = null,
    };
    var source = Node{
        .name = try allocator.dupe(u8, "root"),
        .next = leaf,
    };
    defer CheatLib.cleanup(Node, allocator, &source);

    var fail_index: usize = 0;
    var failures: usize = 0;
    while (fail_index < 16) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(
            allocator,
            .{ .fail_index = fail_index },
        );
        var copied = CheatLib.dupeValue(Node, source, failing.allocator()) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            failures += 1;
            continue;
        };
        try std.testing.expect(copied.next != null);
        try std.testing.expect(copied.next.? != source.next.?);
        try std.testing.expectEqualStrings("leaf", copied.next.?.name);
        CheatLib.cleanup(Node, failing.allocator(), &copied);
        break;
    }
    try std.testing.expect(failures >= 3);
    try std.testing.expect(fail_index < 16);
}

test "dupeValue rolls back managed numeric-map values under allocator failure" {
    const Map = std.AutoHashMapUnmanaged(i64, []u8);
    const allocator = std.testing.allocator;
    var source: Map = .empty;
    try source.put(allocator, 1, try allocator.dupe(u8, "one"));
    try source.put(allocator, 2, try allocator.dupe(u8, "two"));
    try source.put(allocator, 3, try allocator.dupe(u8, "three"));
    defer CheatLib.cleanup(Map, allocator, &source);

    var fail_index: usize = 0;
    var failures: usize = 0;
    while (fail_index < 16) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(
            allocator,
            .{ .fail_index = fail_index },
        );
        var copied = CheatLib.dupeValue(Map, source, failing.allocator()) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            failures += 1;
            continue;
        };
        CheatLib.cleanup(Map, failing.allocator(), &copied);
        break;
    }
    try std.testing.expect(failures >= 4);
    try std.testing.expect(fail_index < 16);
}

const NodeStorePayload = struct {
    value: u64,

    pub fn deinit(_: *@This(), _: std.mem.Allocator) void {
        node_store_drop_count += 1;
    }
};

test "NodeStore uses compact nullable handles, rejects stale handles, and finalizes payloads" {
    const allocator = std.testing.allocator;
    var context = ebr.EbrContext{};
    defer context.deinit(allocator);

    var rt = try Runtime.init(allocator, 64 * 1024, &context);
    node_store_drop_count = 0;

    const Ref = CheatLib.NodeRef(NodeStorePayload);
    const Store = CheatLib.NodeStore(NodeStorePayload);
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Ref));
    try std.testing.expect((Ref{}).isNil());

    const first = try Store.create(&rt, .{ .value = 11 });
    const second = try Store.create(&rt, .{ .value = 22 });
    try std.testing.expectEqual(@as(u64, 11), Store.get(&rt, first).?.value);
    try std.testing.expectEqual(@as(usize, 2), Store.count(&rt));

    try std.testing.expect(Store.remove(&rt, first));
    try std.testing.expect(Store.get(&rt, first) == null);
    try std.testing.expectEqual(@as(usize, 1), node_store_drop_count);
    try std.testing.expectEqual(@as(u64, 22), Store.get(&rt, second).?.value);

    // Cross the 4,096-slot initial capacity. Growth must preserve all compact
    // handles and must not drop bitwise-moved payloads.
    var i: usize = 0;
    while (i < 4096) : (i += 1) {
        _ = try Store.create(&rt, .{ .value = @intCast(100 + i) });
    }
    try std.testing.expectEqual(@as(usize, 4097), Store.count(&rt));
    try std.testing.expectEqual(@as(u64, 22), Store.get(&rt, second).?.value);
    try std.testing.expectEqual(@as(usize, 1), node_store_drop_count);

    rt.deinit();
    try std.testing.expectEqual(@as(usize, 4098), node_store_drop_count);
    try std.testing.expect(Store.get(&rt, second) == null);
}

test "NodeStore releases every payload at the outermost lexical binding" {
    const allocator = std.testing.allocator;
    var context = ebr.EbrContext{};
    defer context.deinit(allocator);

    var rt = try Runtime.init(allocator, 64 * 1024, &context);
    defer rt.deinit();
    node_store_drop_count = 0;

    const Store = CheatLib.NodeStore(NodeStorePayload);
    const outer = try Store.bind(&rt);
    const inner = try Store.bind(&rt);
    try std.testing.expectEqual(outer, inner);

    const first = try Store.createBound(outer, .{ .value = 1 });
    _ = try Store.createBound(inner, .{ .value = 2 });
    Store.releaseBound(inner);
    try std.testing.expectEqual(@as(usize, 0), node_store_drop_count);
    try std.testing.expectEqual(@as(u64, 1), Store.getBound(outer, first).?.value);

    Store.releaseBound(outer);
    try std.testing.expectEqual(@as(usize, 2), node_store_drop_count);
    try std.testing.expect(Store.getBound(outer, first) == null);
}

test "bounds-safe list access returns optionals, mutable aliases, and compact node NIL" {
    const allocator = std.testing.allocator;
    var values: std.ArrayListUnmanaged(u64) = .empty;
    defer values.deinit(allocator);
    try values.append(allocator, 10);

    try std.testing.expectEqual(@as(?u64, 10), CheatLib.getAtOpt(values, 0));
    try std.testing.expectEqual(@as(?u64, null), CheatLib.getAtOpt(values, 1));
    const ptr = CheatLib.getAtPtrOpt(&values, 0).?;
    ptr.* = 25;
    try std.testing.expectEqual(@as(u64, 25), values.items[0]);
    try std.testing.expect(CheatLib.getAtPtrOpt(&values, 1) == null);
    const values_ptr = &values;
    const forwarded_ptr = &values_ptr;
    const forwarded = CheatLib.getAtPtrOpt(forwarded_ptr, 0).?;
    forwarded.* = 30;
    try std.testing.expectEqual(@as(u64, 30), values.items[0]);

    const Ref = CheatLib.NodeRef(NodeStorePayload);
    var refs: std.ArrayListUnmanaged(Ref) = .empty;
    defer refs.deinit(allocator);
    try refs.append(allocator, Ref.fromHandle(7));
    try std.testing.expectEqual(@as(u32, 8), CheatLib.getNodeAt(refs, 0).encoded);
    try std.testing.expect(CheatLib.getNodeAt(refs, 1).isNil());
}

test "getAtOpt flattens optional list elements" {
    const values = [_]?u64{ 10, null };

    try std.testing.expectEqual(@as(?u64, 10), CheatLib.getAtOpt(values[0..], 0));
    try std.testing.expectEqual(@as(?u64, null), CheatLib.getAtOpt(values[0..], 1));
    try std.testing.expectEqual(@as(?u64, null), CheatLib.getAtOpt(values[0..], 2));
}

test "optional payload access returns a mutable alias" {
    const Payload = struct { value: u64 };
    var present: ?Payload = .{ .value = 4 };
    const ptr = CheatLib.getOptionalPtr(&present).?;
    ptr.value = 9;
    try std.testing.expectEqual(@as(u64, 9), present.?.value);

    var absent: ?Payload = null;
    try std.testing.expect(CheatLib.getOptionalPtr(&absent) == null);
}

test "Rc and WeakRc share one allocation while preserving the ctrl.data ABI" {
    const allocator = std.testing.allocator;
    const profile_allocs_before = alloc_profile.totalAllocs();
    const rc = try CheatLib.rcCreate(u64, allocator, 42);
    const weak = CheatLib.rcDowngrade(u64, rc);

    try std.testing.expectEqual(3 * @sizeOf(usize), @sizeOf(CheatLib.RcControlBlock(u64)));
    try std.testing.expectEqual(@as(u64, 42), rc.ctrl.data.*);
    const ctrl_addr = @intFromPtr(rc.ctrl);
    const data_addr = @intFromPtr(rc.ctrl.data);
    try std.testing.expect(data_addr > ctrl_addr);
    try std.testing.expect(data_addr - ctrl_addr <= @sizeOf(CheatLib.RcControlBlock(u64)) + @alignOf(u64));

    CheatLib.rcRelease(u64, allocator, rc);
    try std.testing.expect(CheatLib.weakRcUpgrade(u64, weak) == null);
    CheatLib.weakRcRelease(u64, allocator, weak);
    try std.testing.expectEqual(profile_allocs_before, alloc_profile.totalAllocs());
}

test "last Rc strong release keeps the control block alive through self-WeakRc cleanup" {
    const SelfLinked = struct {
        self: CheatLib.WeakRc(@This()),
    };
    const allocator = std.testing.allocator;
    const rc = try CheatLib.rcCreate(SelfLinked, allocator, undefined);
    rc.ctrl.data.self = CheatLib.rcDowngrade(SelfLinked, rc);

    // The payload's WeakRc release runs inside this last-strong release. The
    // implicit weak must prevent an inner free followed by an outer double-free.
    CheatLib.rcRelease(SelfLinked, allocator, rc);
}

test "CheatLib.read returns immediately when fd already has bytes" {
    var fds: [2]i32 = undefined;
    switch (std.posix.errno(std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds))) {
        .SUCCESS => {},
        else => return error.Unexpected,
    }
    defer compat.closeFd(fds[0]);
    defer compat.closeFd(fds[1]);

    const msg = "ready";
    const written = std.c.write(fds[1], msg.ptr, msg.len);
    try std.testing.expect(written >= 0);
    try std.testing.expectEqual(msg.len, @as(usize, @intCast(written)));

    var buf: [16]u8 = undefined;
    const n = try CheatLib.read(fds[0], &buf);
    try std.testing.expectEqual(msg.len, n);
    try std.testing.expectEqualSlices(u8, msg, buf[0..n]);
}

fn dummyFsmResume(_: *fsm.FsmTask) fsm.YieldReason {
    return .{ .Done = {} };
}

fn initWorkerGlobals() void {
    global_stack_pool = fm.StackPool.init(alloc);
}

fn deinitWorkerGlobals() void {
    global_stack_pool.deinit();
}

fn schedulerThread(a: std.mem.Allocator) void {
    var sched = fp.Scheduler.init(a, &global_ebr_ctx, &global_stack_pool) catch return;
    defer sched.deinit();
    sched.global_shutdown = &global_shutdown;
    sched.shutdown_on_idle = false;
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;
    sched.run();
    fp.scheduler_running = false;
}

var global_spawned_workers: usize = 0;

fn startWorkers(threads: []std.Thread, n: usize) void {
    global_spawned_workers = 0;
    for (threads[0..n]) |*t| {
        t.* = std.Thread.spawn(.{}, schedulerThread, .{alloc}) catch continue;
        global_spawned_workers += 1;
    }
    var wait_ms: usize = 0;
    while (fp.global_registry.count() < global_spawned_workers) : (wait_ms += 1) {
        if (wait_ms >= 300_000) @panic("Worker registration timed out");
        compat.sleepNs(1 * std.time.ns_per_ms);
    }
}

fn stopWorkers(threads: []std.Thread, n: usize) void {
    _ = n;
    global_shutdown.store(true, .release);
    fp.global_registry.notifyAll();
    for (threads[0..global_spawned_workers]) |*t| t.join();
    fp.global_registry.deinit(alloc);
    fp.global_registry = .{};
    global_shutdown.store(false, .release);
    global_spawned_workers = 0;
}

test "FSM ctx allocation routes 64B, 128B, 256B, and oversized contexts" {
    const allocator = std.testing.allocator;

    var global_ctx = ebr.EbrContext{};
    defer global_ctx.deinit(allocator);

    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();

    var sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer sched.deinit();
    defer fp.global_registry.deinit(allocator);

    const SmallCtx = extern struct { bytes: [64]u8 };
    const MediumCtx = extern struct { bytes: [128]u8 };
    const LargeCtx = extern struct { bytes: [256]u8 };
    const OversizedCtx = extern struct { bytes: [257]u8 };

    const small_task = try sched.allocFsmTask(&dummyFsmResume);
    defer sched.fsm_task_slab.destroy(small_task);
    const small = try sched.allocFsmCtx(SmallCtx, small_task);
    try std.testing.expectEqual(fsm.FsmCtxAllocClass.slab64, small_task.ctx_alloc_class);
    sched.freeFsmCtx(SmallCtx, small_task, small);
    try std.testing.expectEqual(fsm.FsmCtxAllocClass.none, small_task.ctx_alloc_class);

    const medium_task = try sched.allocFsmTask(&dummyFsmResume);
    defer sched.fsm_task_slab.destroy(medium_task);
    const medium = try sched.allocFsmCtx(MediumCtx, medium_task);
    try std.testing.expectEqual(fsm.FsmCtxAllocClass.slab128, medium_task.ctx_alloc_class);
    sched.freeFsmCtx(MediumCtx, medium_task, medium);
    try std.testing.expectEqual(fsm.FsmCtxAllocClass.none, medium_task.ctx_alloc_class);

    const large_task = try sched.allocFsmTask(&dummyFsmResume);
    defer sched.fsm_task_slab.destroy(large_task);
    const large = try sched.allocFsmCtx(LargeCtx, large_task);
    try std.testing.expectEqual(fsm.FsmCtxAllocClass.slab256, large_task.ctx_alloc_class);
    sched.freeFsmCtx(LargeCtx, large_task, large);
    try std.testing.expectEqual(fsm.FsmCtxAllocClass.none, large_task.ctx_alloc_class);

    const oversized_task = try sched.allocFsmTask(&dummyFsmResume);
    defer sched.fsm_task_slab.destroy(oversized_task);
    const oversized = try sched.allocFsmCtx(OversizedCtx, oversized_task);
    try std.testing.expectEqual(fsm.FsmCtxAllocClass.heap, oversized_task.ctx_alloc_class);
    sched.freeFsmCtx(OversizedCtx, oversized_task, oversized);
    try std.testing.expectEqual(fsm.FsmCtxAllocClass.none, oversized_task.ctx_alloc_class);
}

test "FSM ctx slab free routes back to owner scheduler" {
    const allocator = std.testing.allocator;

    var global_ctx = ebr.EbrContext{};
    defer global_ctx.deinit(allocator);

    var pool_a = fm.StackPool.init(allocator);
    defer pool_a.deinit();
    var pool_b = fm.StackPool.init(allocator);
    defer pool_b.deinit();

    var owner = try fp.Scheduler.init(allocator, &global_ctx, &pool_a);
    defer owner.deinit();
    var current = try fp.Scheduler.init(allocator, &global_ctx, &pool_b);
    defer current.deinit();
    defer fp.global_registry.deinit(allocator);
    owner.index = 0;
    current.index = 1;

    const SmallCtx = extern struct { bytes: [256]u8 };
    const task = try owner.allocFsmTask(&dummyFsmResume);
    defer owner.fsm_task_slab.destroy(task);
    const ctx = try owner.allocFsmCtx(SmallCtx, task);
    task.ctx = ctx;
    try std.testing.expectEqual(fsm.FsmCtxAllocClass.slab256, task.ctx_alloc_class);

    fp.active_scheduler = &current;
    fp.scheduler_running = true;
    current.freeFsmCtx(SmallCtx, task, ctx);
    fp.scheduler_running = false;

    try std.testing.expectEqual(fsm.FsmCtxAllocClass.none, task.ctx_alloc_class);
    owner.drainChannels();
}

// This is the function the Fiber will run
fn fiberFfiTask(rt: *Runtime, _: ?*anyopaque) anyerror!void {
    std.debug.print("\n[Fiber] Entering FFI Task. Current PID: {d}", .{c.getpid()});

    // 1. Prepare the C struct (on the Fiber stack)
    var req = c.struct_timespec{
        .tv_sec = 0,
        .tv_nsec = 50_000_000, // 50ms
    };
    var rem: c.struct_timespec = undefined;

    std.debug.print("\n[Fiber] Calling nanosleep via Root Stack Trampoline...", .{});

    // 2. USE THE TRAMPOLINE
    // This calls nanosleep(req, rem) on the Root Stack.
    // CheatLib.ffi(runtime, function, args_tuple)
    _ = CheatLib.ffi(rt, c.nanosleep, .{ &req, &rem });

    std.debug.print("\n[Fiber] Successfully returned from C! No stack corruption detected.", .{});

    // 3. Simple verification
    const val = c.getpid();
    CheatLib.assert(val > 0, "PID should be positive");
}

test "Root Stack Trampoline: C Standard Library Integration" {
    const allocator = std.testing.allocator;

    // --- Standard Boilerplate ---
    var global_ctx = ebr.EbrContext{};
    defer global_ctx.deinit(allocator);

    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();

    var sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer sched.deinit();

    fp.active_scheduler = &sched;

    defer fp.global_registry.deinit(allocator);

    // ----------------------------

    std.debug.print("\n\n--- Start FFI Trampoline Test ---", .{});

    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(qs.TaskFn, @ptrCast(&fiberFfiTask)), null, .{});

    // This will run until the fiber finishes.
    sched.run();

    std.debug.print("\n--- End FFI Trampoline Test ---\n", .{});
}

// ---------------------------------------------------------------------------
// Promise(T) tests
// ---------------------------------------------------------------------------
// BG-pattern integration tests
// ---------------------------------------------------------------------------
//
// These tests simulate the exact Zig code that the CLEAR transpiler generates
// for BG blocks: a heap-allocated context struct with by-value captures, a
// fiber that writes to Promise.Inner and signals done, and a caller fiber that
// calls promise.next() to block until the result is ready.
//
// Running them here (rather than only through all-tests.zig) gives us direct
// visibility into the runtime behaviour at the Zig level, independent of the
// Ruby compiler pipeline.
// ---------------------------------------------------------------------------

// Shared result state for BG integration tests.
// Lives on the test stack for the duration of sched.run().
const BgResult = struct {
    value: f64 = 0.0,
};

// Simulates the cheatMain fiber for:
//   x: Number = 10.0;
//   p: ~Number = BG { x + 5.0; };
//   result: Number = NEXT p;
fn bgCheatMain(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    const out = @as(*BgResult, @ptrCast(@alignCast(raw_args.?)));
    const x: f64 = 10.0;

    // --- Transpiler output for: p: ~Number = BG { x + 5.0; } ---
    const BgCtx = struct {
        inner: *CheatLib.Promise(f64).Inner,
        alloc: std.mem.Allocator,
        x: f64, // captured by value

        fn run(raw_rt: *anyopaque, raw_args_inner: ?*anyopaque) anyerror!void {
            const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
            _ = &__rt;
            const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args_inner.?)));
            defer ctx.alloc.destroy(ctx);
            defer ctx.inner.wg.done();
            ctx.inner.result = ctx.x + 5.0;
        }
    };
    const p = try CheatLib.Promise(f64).spawn(alloc, rt.getSched());
    const bg_ctx = try alloc.create(BgCtx);
    bg_ctx.* = .{ .inner = p.inner, .alloc = alloc, .x = x };
    try rt.getSched().submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&BgCtx.run)),
        bg_ctx,
        .{},
    );
    // --- Transpiler output for: result: Number = NEXT p ---
    out.value = try p.next();
}

test "BG pattern: cheatMain-fiber spawns BG-fiber with by-value capture, NEXTs result" {
    const allocator = std.testing.allocator;

    var global_ctx = ebr.EbrContext{};
    defer global_ctx.deinit(allocator);

    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();

    var sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer sched.deinit();
    defer fp.global_registry.deinit(allocator);

    fp.active_scheduler = &sched;

    var result = BgResult{};
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&bgCheatMain)),
        &result,
        .{},
    );
    sched.run();

    // 10.0 + 5.0 = 15.0
    try std.testing.expectEqual(@as(f64, 15.0), result.value);
}

// ---------------------------------------------------------------------------
// Shared state for the 3-concurrent-BG test.

const BgConcurrentResult = struct {
    a: f64 = 0.0,
    b: f64 = 0.0,
    c: f64 = 0.0,
};

// Simulates:
//   a: ~Number = BG { 10.0 };
//   b: ~Number = BG { 20.0 };
//   c: ~Number = BG { 30.0 };
//   rc = NEXT c; rb = NEXT b; ra = NEXT a;
fn bgConcurrentMain(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    const out = @as(*BgConcurrentResult, @ptrCast(@alignCast(raw_args.?)));

    // Generic BG context carrying a constant f64 result.
    const BgFixed = struct {
        inner: *CheatLib.Promise(f64).Inner,
        alloc: std.mem.Allocator,
        value: f64,

        fn run(raw_rt: *anyopaque, raw_args_inner: ?*anyopaque) anyerror!void {
            const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
            _ = &__rt;
            const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args_inner.?)));
            defer ctx.alloc.destroy(ctx);
            defer ctx.inner.wg.done();
            ctx.inner.result = ctx.value;
        }
    };

    const sched_alloc = rt.getSched().allocator;

    // Spawn three concurrent BG fibers.
    const pa = try CheatLib.Promise(f64).spawn(sched_alloc, rt.getSched());
    const ctx_a = try sched_alloc.create(BgFixed);
    ctx_a.* = .{ .inner = pa.inner, .alloc = sched_alloc, .value = 10.0 };
    try rt.getSched().submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(qs.TaskFn, @ptrCast(&BgFixed.run)), ctx_a, .{});

    const pb = try CheatLib.Promise(f64).spawn(sched_alloc, rt.getSched());
    const ctx_b = try sched_alloc.create(BgFixed);
    ctx_b.* = .{ .inner = pb.inner, .alloc = sched_alloc, .value = 20.0 };
    try rt.getSched().submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(qs.TaskFn, @ptrCast(&BgFixed.run)), ctx_b, .{});

    const pc = try CheatLib.Promise(f64).spawn(sched_alloc, rt.getSched());
    const ctx_c = try sched_alloc.create(BgFixed);
    ctx_c.* = .{ .inner = pc.inner, .alloc = sched_alloc, .value = 30.0 };
    try rt.getSched().submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(qs.TaskFn, @ptrCast(&BgFixed.run)), ctx_c, .{});

    // NEXT in reverse order — tests both slow-path (yield) and fast-path (already done).
    out.c = try pc.next();
    out.b = try pb.next();
    out.a = try pa.next();
}

test "BG pattern: 3 concurrent fibers, NEXT in reverse-spawn order" {
    const allocator = std.testing.allocator;

    var global_ctx = ebr.EbrContext{};
    defer global_ctx.deinit(allocator);

    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();

    var sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer sched.deinit();
    defer fp.global_registry.deinit(allocator);

    fp.active_scheduler = &sched;

    var result = BgConcurrentResult{};
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&bgConcurrentMain)),
        &result,
        .{},
    );
    sched.run();

    try std.testing.expectEqual(@as(f64, 10.0), result.a);
    try std.testing.expectEqual(@as(f64, 20.0), result.b);
    try std.testing.expectEqual(@as(f64, 30.0), result.c);
}

// ---------------------------------------------------------------------------
// Value-isolation test: mutating the outer variable after spawning a BG fiber
// must not affect the fiber's result (since BG captures by VALUE, not pointer).

const BgIsolationResult = struct {
    value: f64 = 0.0,
};

fn bgIsolationMain(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    const out = @as(*BgIsolationResult, @ptrCast(@alignCast(raw_args.?)));

    const BgCapture = struct {
        inner: *CheatLib.Promise(f64).Inner,
        alloc: std.mem.Allocator,
        captured: f64, // by-value copy of the outer variable

        fn run(raw_rt: *anyopaque, raw_args_inner: ?*anyopaque) anyerror!void {
            const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
            _ = &__rt;
            const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args_inner.?)));
            defer ctx.alloc.destroy(ctx);
            defer ctx.inner.wg.done();
            // The fiber uses the snapshotted value, not whatever `base` is now.
            ctx.inner.result = ctx.captured * 2.0;
        }
    };

    const sched_alloc = rt.getSched().allocator;
    var base: f64 = 5.0;

    // Spawn BG fiber — captures base=5.0 by value.
    const p = try CheatLib.Promise(f64).spawn(sched_alloc, rt.getSched());
    const bg_ctx = try sched_alloc.create(BgCapture);
    bg_ctx.* = .{ .inner = p.inner, .alloc = sched_alloc, .captured = base };
    try rt.getSched().submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(qs.TaskFn, @ptrCast(&BgCapture.run)), bg_ctx, .{});

    // Mutate base AFTER spawning — should not affect the fiber's captured copy.
    base = 99.0;
    _ = &base; // keep base alive to show mutation doesn't affect fiber

    // NEXT — fiber must return 5.0 * 2.0 = 10.0, not 99.0 * 2.0 = 198.0.
    out.value = try p.next();
}

test "BG pattern: by-value capture is isolated from post-spawn mutation of outer variable" {
    const allocator = std.testing.allocator;

    var global_ctx = ebr.EbrContext{};
    defer global_ctx.deinit(allocator);

    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();

    var sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer sched.deinit();
    defer fp.global_registry.deinit(allocator);

    fp.active_scheduler = &sched;

    var result = BgIsolationResult{};
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&bgIsolationMain)),
        &result,
        .{},
    );
    sched.run();

    // Must be 5.0 * 2.0 = 10.0 (snapshot at spawn), NOT 99.0 * 2.0.
    try std.testing.expectEqual(@as(f64, 10.0), result.value);
}
