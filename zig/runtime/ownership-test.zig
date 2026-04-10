const std = @import("std");

const CheatLib = @import("runtime-header.zig").CheatLib;
const rt_mod = @import("runtime.zig");
const own = @import("ownership");

const Runtime = rt_mod.Runtime;
const EbrContext = @import("ebr").EbrContext;
const Rc = own.Rc;
const Arc = own.Arc;
const Weak = own.Weak;

// -------------------------------------------------------------------------
// Rc<T> Tests (Single-Threaded)
// -------------------------------------------------------------------------

test "Rc: Basic creation and access" {
    const allocator = std.testing.allocator;

    var rc = try Rc(i32).init(allocator, 42);
    defer rc.deinit();

    try std.testing.expectEqual(@as(i32, 42), rc.get().*);
    try std.testing.expectEqual(@as(usize, 1), rc.refCount());
}

test "Rc: Clone increments refcount" {
    const allocator = std.testing.allocator;

    var rc1 = try Rc(i32).init(allocator, 100);
    var rc2 = rc1.clone();
    var rc3 = rc1.clone();

    try std.testing.expectEqual(@as(usize, 3), rc1.refCount());
    try std.testing.expectEqual(@as(usize, 3), rc2.refCount());
    try std.testing.expectEqual(@as(usize, 3), rc3.refCount());

    // All point to the same data
    try std.testing.expectEqual(rc1.get(), rc2.get());
    try std.testing.expectEqual(rc2.get(), rc3.get());

    rc3.deinit();
    try std.testing.expectEqual(@as(usize, 2), rc1.refCount());

    rc2.deinit();
    try std.testing.expectEqual(@as(usize, 1), rc1.refCount());

    rc1.deinit();
    // Memory freed, no leak
}

test "Rc: Mutation through shared reference" {
    const allocator = std.testing.allocator;

    var rc1 = try Rc(i32).init(allocator, 0);
    var rc2 = rc1.clone();

    // Mutate through rc1
    rc1.get().* = 999;

    // Visible through rc2
    try std.testing.expectEqual(@as(i32, 999), rc2.get().*);

    rc2.deinit();
    rc1.deinit();
}

test "Rc: Complex struct" {
    const allocator = std.testing.allocator;

    const Player = struct {
        name: []const u8,
        score: i32,
        health: f32,
    };

    var rc = try Rc(Player).init(allocator, .{
        .name = "TestPlayer",
        .score = 100,
        .health = 100.0,
    });
    defer rc.deinit();

    try std.testing.expectEqualStrings("TestPlayer", rc.get().name);
    try std.testing.expectEqual(@as(i32, 100), rc.get().score);

    // Mutate
    rc.get().score += 50;
    rc.get().health -= 10.5;

    try std.testing.expectEqual(@as(i32, 150), rc.get().score);
    try std.testing.expectApproxEqAbs(@as(f32, 89.5), rc.get().health, 0.001);
}

// -------------------------------------------------------------------------
// Arc<T> Tests (Thread-Safe)
// -------------------------------------------------------------------------

test "Arc: Basic creation and access" {
    const allocator = std.testing.allocator;

    var arc = try Arc(i32).init(allocator, 42);
    defer arc.deinit();

    try std.testing.expectEqual(@as(i32, 42), arc.get().*);
    try std.testing.expectEqual(@as(usize, 1), arc.refCount());
}

test "Arc: Clone increments refcount atomically" {
    const allocator = std.testing.allocator;

    var arc1 = try Arc(i32).init(allocator, 100);
    var arc2 = arc1.clone();
    var arc3 = arc1.clone();

    try std.testing.expectEqual(@as(usize, 3), arc1.refCount());

    arc3.deinit();
    try std.testing.expectEqual(@as(usize, 2), arc1.refCount());

    arc2.deinit();
    try std.testing.expectEqual(@as(usize, 1), arc1.refCount());

    arc1.deinit();
}

test "Arc: Multi-threaded clone and deinit" {
    const allocator = std.testing.allocator;

    // Use GPA to detect leaks
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const test_alloc = gpa.allocator();

    {
        var global_ctx = EbrContext{};
        defer global_ctx.deinit(allocator);

        const Counter = struct { value: std.atomic.Value(i32) };

        // Create shared Arc on heap so threads can access it
        const shared_arc = try test_alloc.create(Arc(Counter));
        shared_arc.* = try Arc(Counter).init(test_alloc, .{
            .value = std.atomic.Value(i32).init(0),
        });

        defer {
            shared_arc.deinit();
            test_alloc.destroy(shared_arc);
        }

        const thread_count = 10;
        const ops_per_thread = 1000;

        const Worker = struct {
            fn run(_: *Runtime, arc_ptr: *Arc(Counter), ops: usize) !void {
                var i: usize = 0;
                while (i < ops) : (i += 1) {
                    // Clone the arc (atomic increment)
                    var local = arc_ptr.clone();

                    // Do some work with it
                    _ = local.get().value.fetchAdd(1, .monotonic);

                    // Release our clone
                    local.deinit();

                    std.Thread.yield() catch {};
                }
            }
        };

        var threads = std.ArrayListUnmanaged(std.Thread){};
        defer threads.deinit(allocator);

        var i: usize = 0;
        while (i < thread_count) : (i += 1) {
            const t = try CheatLib.spawnThread(
                allocator,
                64 * 1024,
                &global_ctx,
                Worker.run,
                .{ shared_arc, ops_per_thread },
            );
            try threads.append(allocator, t);
        }

        for (threads.items) |t| {
            t.join();
        }

        // Verify the counter
        const expected = thread_count * ops_per_thread;
        const actual = shared_arc.get().value.load(.seq_cst);

        std.debug.print("\nArc counter: Expected {d}, Got {d}\n", .{ expected, actual });
        try std.testing.expectEqual(@as(i32, @intCast(expected)), actual);

        // Ref count should be back to 1
        try std.testing.expectEqual(@as(usize, 1), shared_arc.refCount());
    }

    // Check for leaks
    const check = gpa.deinit();
    if (check == .leak) @panic("Memory leaks detected in Arc test");
}

test "Arc: Stress test clone/deinit racing" {
    const allocator = std.testing.allocator;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const test_alloc = gpa.allocator();

    {
        var global_ctx = EbrContext{};
        defer global_ctx.deinit(allocator);

        // Simple data that we can verify wasn't corrupted
        const Data = struct { magic: u64 };
        const MAGIC: u64 = 0xDEADBEEFCAFEBABE;

        const shared_arc = try test_alloc.create(Arc(Data));
        shared_arc.* = try Arc(Data).init(test_alloc, .{ .magic = MAGIC });

        defer {
            shared_arc.deinit();
            test_alloc.destroy(shared_arc);
        }

        const thread_count = 8;
        const iterations = 500;

        const Racer = struct {
            fn run(_: *Runtime, arc_ptr: *Arc(Data), iters: usize) !void {
                var clones = std.ArrayListUnmanaged(Arc(Data)){};
                defer clones.deinit(std.heap.page_allocator);

                var i: usize = 0;
                while (i < iters) : (i += 1) {
                    // Clone a few times
                    var j: usize = 0;
                    while (j < 5) : (j += 1) {
                        const c = arc_ptr.clone();
                        // Verify data integrity
                        if (c.get().magic != 0xDEADBEEFCAFEBABE) {
                            @panic("Data corruption detected!");
                        }
                        try clones.append(std.heap.page_allocator, c);
                    }

                    // Release them
                    while (clones.items.len > 0) {
                        var c = clones.pop().?;
                        c.deinit();
                    }

                    std.Thread.yield() catch {};
                }
            }
        };

        var threads = std.ArrayListUnmanaged(std.Thread){};
        defer threads.deinit(allocator);

        var i: usize = 0;
        while (i < thread_count) : (i += 1) {
            const t = try CheatLib.spawnThread(
                allocator,
                64 * 1024,
                &global_ctx,
                Racer.run,
                .{ shared_arc, iterations },
            );
            try threads.append(allocator, t);
        }

        for (threads.items) |t| {
            t.join();
        }

        std.debug.print("\nArc stress test passed. Final refcount: {d}\n", .{shared_arc.refCount()});
        try std.testing.expectEqual(@as(usize, 1), shared_arc.refCount());
    }

    const check = gpa.deinit();
    if (check == .leak) @panic("Memory leaks in Arc stress test");
}

// -------------------------------------------------------------------------
// Weak<T> Tests
// -------------------------------------------------------------------------

test "Weak: Basic upgrade when alive" {
    const allocator = std.testing.allocator;

    var arc = try Arc(i32).init(allocator, 42);
    var weak = Weak(i32).fromArc(arc);

    // weak_count should be 2 (1 implicit from strong refs + 1 explicit from weak)
    try std.testing.expectEqual(@as(usize, 2), arc.weakCount());
    try std.testing.expect(weak.isAlive());

    // Upgrade should succeed
    if (weak.upgrade()) |upgraded| {
        var up = upgraded;
        try std.testing.expectEqual(@as(i32, 42), up.get().*);
        try std.testing.expectEqual(@as(usize, 2), arc.refCount());
        up.deinit();
    } else {
        return error.UpgradeFailed;
    }

    weak.deinit();
    arc.deinit();
}

test "Weak: Upgrade fails after Arc deallocated" {
    const allocator = std.testing.allocator;

    var arc = try Arc(i32).init(allocator, 42);
    var weak = Weak(i32).fromArc(arc);

    try std.testing.expect(weak.isAlive());
    try std.testing.expectEqual(@as(usize, 1), arc.refCount());
    try std.testing.expectEqual(@as(usize, 2), arc.weakCount()); // 1 implicit + 1 explicit

    // Deallocate the Arc (last strong reference)
    arc.deinit();

    // The control block is kept alive by the weak reference!
    // This is safe because we now have a split strong/weak count:
    // - strong_count is 0 (data is "dead")
    // - weak_count is 1 (our explicit weak ref keeps control block alive)

    // isAlive should return false (no strong refs)
    try std.testing.expect(!weak.isAlive());

    // Upgrade should fail since strong_count is 0
    try std.testing.expectEqual(@as(?Arc(i32), null), weak.upgrade());

    // This is safe - weak_count goes from 1 to 0, freeing the control block
    weak.deinit();
}

test "Weak: Multiple weak references" {
    const allocator = std.testing.allocator;

    var arc = try Arc(i32).init(allocator, 100);

    var weak1 = Weak(i32).fromArc(arc);
    var weak2 = Weak(i32).fromArc(arc);

    // weak_count: 1 implicit + 2 explicit = 3
    try std.testing.expectEqual(@as(usize, 3), arc.weakCount());

    // Both should be alive
    try std.testing.expect(weak1.isAlive());
    try std.testing.expect(weak2.isAlive());

    // Upgrade both
    if (weak1.upgrade()) |up1| {
        var upgraded1 = up1;
        defer upgraded1.deinit();
        if (weak2.upgrade()) |up2| {
            var upgraded2 = up2;
            defer upgraded2.deinit();
            try std.testing.expectEqual(@as(usize, 3), arc.refCount());
        } else {
            return error.UpgradeFailed;
        }
    } else {
        return error.UpgradeFailed;
    }

    try std.testing.expectEqual(@as(usize, 1), arc.refCount());

    // Test: drop all strong refs, then check weaks still work
    arc.deinit();

    // Control block still alive (weak_count is 2)
    try std.testing.expect(!weak1.isAlive());
    try std.testing.expect(!weak2.isAlive());
    try std.testing.expectEqual(@as(?Arc(i32), null), weak1.upgrade());
    try std.testing.expectEqual(@as(?Arc(i32), null), weak2.upgrade());

    // Clean up weak refs (frees control block when last one drops)
    weak1.deinit();
    weak2.deinit();
}

// -------------------------------------------------------------------------
// Edge Cases and Integration Tests
// -------------------------------------------------------------------------

test "Arc with nested struct containing allocations" {
    const allocator = std.testing.allocator;

    // A struct that owns heap memory
    const Config = struct {
        buffer: []u8,
        size: usize,
    };

    // Create buffer separately so we can control cleanup
    const buf = try allocator.alloc(u8, 100);
    @memset(buf, 0xAB);

    var arc = try Arc(Config).init(allocator, .{
        .buffer = buf,
        .size = 100,
    });

    // Clone it
    var arc2 = arc.clone();

    // Both see the same buffer
    try std.testing.expectEqual(arc.get().buffer.ptr, arc2.get().buffer.ptr);
    try std.testing.expectEqual(@as(u8, 0xAB), arc.get().buffer[0]);

    arc2.deinit();
    arc.deinit();

    // Clean up the buffer (Arc doesn't manage nested allocations)
    allocator.free(buf);
}

test "Rc: Zero-sized type" {
    const allocator = std.testing.allocator;

    const Empty = struct {};

    var rc = try Rc(Empty).init(allocator, .{});
    var rc2 = rc.clone();

    try std.testing.expectEqual(@as(usize, 2), rc.refCount());

    rc2.deinit();
    rc.deinit();
}

test "Arc: Zero-sized type" {
    const allocator = std.testing.allocator;

    const Empty = struct {};

    var arc = try Arc(Empty).init(allocator, .{});
    var arc2 = arc.clone();

    try std.testing.expectEqual(@as(usize, 2), arc.refCount());

    arc2.deinit();
    arc.deinit();
}

test "Arc: downgrade creates weak reference" {
    const allocator = std.testing.allocator;

    var arc = try Arc(i32).init(allocator, 42);

    // weak_count starts at 1 (implicit weak from strong refs)
    try std.testing.expectEqual(@as(usize, 1), arc.weakCount());

    // Create weak via downgrade
    var weak = arc.downgrade();

    // weak_count is now 2
    try std.testing.expectEqual(@as(usize, 2), arc.weakCount());
    try std.testing.expect(weak.isAlive());

    // Upgrade works
    if (weak.upgrade()) |upgraded| {
        var up = upgraded;
        try std.testing.expectEqual(@as(i32, 42), up.get().*);
        try std.testing.expectEqual(@as(usize, 2), arc.refCount());
        up.deinit();
    } else {
        return error.UpgradeFailed;
    }

    weak.deinit();
    arc.deinit();
}

test "Weak: clone increments weak count" {
    const allocator = std.testing.allocator;

    var arc = try Arc(i32).init(allocator, 123);
    var weak1 = arc.downgrade();
    var weak2 = weak1.clone();

    // 1 implicit + 2 explicit = 3
    try std.testing.expectEqual(@as(usize, 3), arc.weakCount());

    arc.deinit();

    // Both still valid (control block alive)
    try std.testing.expect(!weak1.isAlive());
    try std.testing.expect(!weak2.isAlive());

    weak1.deinit();
    // weak_count is now 1
    weak2.deinit();
    // weak_count is 0, control block freed
}

test "Weak: UAF fix - control block survives after strong refs drop" {
    // This test validates the fix for the Use-After-Free bug.
    // Previously, when the last Arc was dropped, the entire control block
    // was freed, making any Weak pointer access a UAF.
    // Now, the control block stays alive as long as any Weak exists.

    const allocator = std.testing.allocator;

    var arc = try Arc(i32).init(allocator, 999);
    var weak = arc.downgrade();

    // Verify initial state
    try std.testing.expectEqual(@as(usize, 1), arc.refCount());
    try std.testing.expectEqual(@as(usize, 2), arc.weakCount());

    // Drop the last strong reference
    arc.deinit();

    // CRITICAL: This is where the UAF would occur in the old implementation!
    // The old code would have freed the control block here, making the
    // following calls access freed memory.

    // With the fix, these are all safe:
    try std.testing.expect(!weak.isAlive()); // strong_count check is safe
    try std.testing.expectEqual(@as(usize, 0), weak.strongCount()); // safe to read
    try std.testing.expectEqual(@as(usize, 1), weak.weakCount()); // safe to read
    try std.testing.expectEqual(@as(?Arc(i32), null), weak.upgrade()); // safe to call

    // This frees the control block since weak_count goes to 0
    weak.deinit();
}

// -------------------------------------------------------------------------
// Tests for T.deinit being called (memory leak prevention)
// -------------------------------------------------------------------------

test "Arc: deinit calls T.deinit (StructWithDeinit)" {
    // This test proves that when Arc wraps a type with its own deinit method,
    // that deinit is called when the last Arc is dropped, preventing memory leaks.
    const allocator = std.testing.allocator;

    // A struct that manages its own memory and tracks deinit calls
    const ManagedResource = struct {
        buffer: []u8,
        allocator: std.mem.Allocator,
        deinit_called: *bool,

        const Self = @This();

        pub fn init(alloc: std.mem.Allocator, deinit_flag: *bool) !Self {
            return Self{
                .buffer = try alloc.alloc(u8, 1024),
                .allocator = alloc,
                .deinit_called = deinit_flag,
            };
        }

        pub fn deinit(self: *Self) void {
            self.deinit_called.* = true;
            self.allocator.free(self.buffer);
        }
    };

    var deinit_was_called: bool = false;

    {
        const resource = try ManagedResource.init(allocator, &deinit_was_called);
        var arc = try Arc(ManagedResource).init(allocator, resource);

        // Clone it to verify deinit is only called once
        var arc2 = arc.clone();

        try std.testing.expect(!deinit_was_called);

        arc2.deinit();
        // deinit should NOT have been called yet (still one strong ref)
        try std.testing.expect(!deinit_was_called);

        arc.deinit();
        // NOW deinit should have been called
        try std.testing.expect(deinit_was_called);
    }
}

test "Rc: deinit calls T.deinit (StructWithDeinit)" {
    // Same test for Rc (single-threaded variant)
    const allocator = std.testing.allocator;

    const ManagedResource = struct {
        buffer: []u8,
        allocator: std.mem.Allocator,
        deinit_called: *bool,

        const Self = @This();

        pub fn init(alloc: std.mem.Allocator, deinit_flag: *bool) !Self {
            return Self{
                .buffer = try alloc.alloc(u8, 512),
                .allocator = alloc,
                .deinit_called = deinit_flag,
            };
        }

        pub fn deinit(self: *Self) void {
            self.deinit_called.* = true;
            self.allocator.free(self.buffer);
        }
    };

    var deinit_was_called: bool = false;

    {
        const resource = try ManagedResource.init(allocator, &deinit_was_called);
        var rc = try Rc(ManagedResource).init(allocator, resource);

        var rc2 = rc.clone();
        var rc3 = rc.clone();

        try std.testing.expect(!deinit_was_called);

        rc3.deinit();
        try std.testing.expect(!deinit_was_called);

        rc2.deinit();
        try std.testing.expect(!deinit_was_called);

        rc.deinit();
        // Now deinit should have been called
        try std.testing.expect(deinit_was_called);
    }
}

test "Arc: deinit calls T.deinit with allocator param (ArrayListUnmanaged pattern)" {
    // Test the pattern where deinit takes (self, allocator) as params
    const allocator = std.testing.allocator;

    // Track if deinit was called via a side effect
    var deinit_call_count: usize = 0;

    const UnmanagedStyle = struct {
        data: std.ArrayListUnmanaged(u8),
        counter: *usize,

        const Self = @This();

        pub fn init(alloc: std.mem.Allocator, counter_ptr: *usize) !Self {
            var list = std.ArrayListUnmanaged(u8){};
            try list.appendSlice(alloc, "test data for leak detection");
            return Self{
                .data = list,
                .counter = counter_ptr,
            };
        }

        // This is the ArrayListUnmanaged-style deinit signature
        pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            self.counter.* += 1;
            self.data.deinit(alloc);
        }
    };

    {
        const resource = try UnmanagedStyle.init(allocator, &deinit_call_count);
        var arc = try Arc(UnmanagedStyle).init(allocator, resource);

        try std.testing.expectEqual(@as(usize, 0), deinit_call_count);

        arc.deinit();
        try std.testing.expectEqual(@as(usize, 1), deinit_call_count);
    }
}

test "Rc: deinit calls T.deinit with allocator param (ArrayListUnmanaged pattern)" {
    const allocator = std.testing.allocator;

    var deinit_call_count: usize = 0;

    const UnmanagedStyle = struct {
        data: std.ArrayListUnmanaged(i32),
        counter: *usize,

        const Self = @This();

        pub fn init(alloc: std.mem.Allocator, counter_ptr: *usize) !Self {
            var list = std.ArrayListUnmanaged(i32){};
            try list.append(alloc, 42);
            try list.append(alloc, 100);
            return Self{
                .data = list,
                .counter = counter_ptr,
            };
        }

        pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            self.counter.* += 1;
            self.data.deinit(alloc);
        }
    };

    {
        const resource = try UnmanagedStyle.init(allocator, &deinit_call_count);
        var rc = try Rc(UnmanagedStyle).init(allocator, resource);

        try std.testing.expectEqual(@as(usize, 0), deinit_call_count);

        rc.deinit();
        try std.testing.expectEqual(@as(usize, 1), deinit_call_count);
    }
}
