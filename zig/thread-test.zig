const std = @import("std");
const rt = @import("runtime-header.zig");

// -------------------------------------------------------------------------
// Locked<T> Testing
// -------------------------------------------------------------------------

fn testWorker(trt: *rt.Runtime, id: usize, loops: usize, shared_counter: *rt.Locked(i32)) !void {
    // Prove we have a working local runtime by using the stack
    // This would crash if the helper didn't bootstrap the stack correctly.
    const msg = try rt.Runtime.makeString(trt.stackAlloc(), "I am alive");

    // Print start (outside lock)
    std.debug.print("{s} -> Thread {d} started\n", .{msg, id});

    var i: usize = 0;
    while (i < loops) : (i += 1) {

        // 1. SIMULATE WORK (Frame Logic)
        // Sleep for 1ms. This forces the OS to switch to other threads.
        std.Thread.yield() catch {};

        // 2. CRITICAL SECTION
        {
            var guard = shared_counter.acquire();
            defer guard.release();

            // Mutate Shared Data
            guard.get().* += 1;

            // Uncomment this if you want to see the lock fighting (VERY noisy)
            // std.debug.print("  [Thread {d}] incremented to {d}\n", .{id, guard.get().*});
        } // Lock releases HERE (scope end)

        // 3. Reset stack
        trt.restoreStackMark(0);
    }
    std.debug.print("<- Thread {d} done\n", .{id});
}

test "Runtime Spawn & Mutex Verify" {
    // 1. Setup Test Allocator (Global Heap)
    const allocator = std.testing.allocator;

    // 2. Create Shared State (Locked<i32>)
    // Must be on the heap so all threads can see it safely.
    const shared_state = try allocator.create(rt.Locked(i32));
    shared_state.* = rt.Locked(i32).init(0);
    defer allocator.destroy(shared_state);

    // 3. Spawn Threads
    const thread_count = 10;
    const loops_per_thread = 1000;

    // We store thread handles here to join them later
    var threads = std.ArrayListUnmanaged(std.Thread){};
    defer threads.deinit(allocator);

    var i: usize = 0;
    while (i < thread_count) : (i += 1) {
        // MAGIC HAPPENS HERE:
        // Runtime.spawnThread automatically:
        //  1. Creates a new OS thread
        //  2. Allocates a 64KB stack for it
        //  3. Initializes a new Runtime instance
        //  4. Passes &rt + your args to the function
        const t = try rt.Runtime.spawnThread(
            64 * 1024,           // Stack Size
            testWorker,          // Function
            .{ i, loops_per_thread, shared_state } // Args (Tuple)
        );
        try threads.append(allocator, t);
    }

    // 4. Join (Wait)
    for (threads.items) |t| {
        t.join();
    }

    // 5. Verify
    {
        var guard = shared_state.acquire();
        defer guard.release();

        const expected = thread_count * loops_per_thread;
        const actual = guard.get().*;

        std.debug.print("\nExpected: {d}, Actual: {d}\n", .{ expected, actual });
        try std.testing.expectEqual(@as(i32, expected), actual);
    }
}

// -------------------------------------------------------------------------
// Shared<T> Testing
// -------------------------------------------------------------------------
const User = struct {
    id: i64,
    score: i32,
    // Native String! []const u8 is a struct { ptr: [*]u8, len: usize }
    // It fits in registers (16 bytes). No custom struct needed.
    name: []const u8,
};

// Helper for the update logic
fn increaseScore(user: *User, amount: i32) void {
    user.score += amount;
}

fn mvccWorker(trt: *rt.Runtime, allocator: std.mem.Allocator, loops: usize, shared_user: *rt.Shared(User)) !void {
    _ = trt;

    var i: usize = 0;
    while (i < loops) : (i += 1) {

        // MVCC UPDATE
        // Notice: No Lock. No Blocking.
        // We pass the allocator because we might need to create a new version.
        try shared_user.update(
            allocator,       // Use the global/arena allocator for persistent data
            increaseScore,   // The logic to run
            .{ 1 }           // Arguments (increase by 1)
        );

        // Simulate work
        std.Thread.yield() catch {};
    }
}

test "MVCC Leaky Implementation" {
    // 1. Use a GPA so we can SEE the leaks at the end
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // Note: We intentionally DO NOT defer deinit() here if we want to suppress the error,
    // but usually you want to see it to prove the leak happened.
    const allocator = gpa.allocator();

    // 2. Create Shared User (Gen 0)
    // We allocate the 'Shared' container itself on the heap
    const shared_container = try allocator.create(rt.Shared(User));
    shared_container.* = try rt.Shared(User).init(allocator, User{
        .id = 1,
        .score = 0,
        .name = "Original",
    });

    // 3. Spawn Threads
    const thread_count = 5;
    const loops = 100;

    var threads = std.ArrayListUnmanaged(std.Thread){};
    defer threads.deinit(allocator);

    var i: usize = 0;
    while (i < thread_count) : (i += 1) {
        const t = try rt.Runtime.spawnThread(
            64*1024,
            mvccWorker,
            .{ allocator, loops, shared_container }
        );
        try threads.append(allocator, t);
    }

    for (threads.items) |t| {
        t.join();
    }

    // 4. Verify
    const final_user = shared_container.read();
    std.debug.print("\nFinal Score: {d}\n", .{final_user.score});

    // 500 total updates
    try std.testing.expectEqual(@as(i32, 500), final_user.score);

    // THE LEAK CHECK
    // If you uncomment this, the test will FAIL with "Memory leaks detected".
    // This proves that all the intermediate versions (score=1, score=2...) are still in RAM.
    // _ = gpa.deinit();
}

// -------------------------------------------------------------------------
// RwLock<T> Testing
// -------------------------------------------------------------------------

const GameConfig = struct {
    difficulty: f32,
    server_name: []const u8,
};

fn rwWorker(trt: *rt.Runtime, id: usize, loops: usize, shared_config: *rt.RwLock(GameConfig)) !void {
    _ = trt; // Unused in this specific logic

    var i: usize = 0;
    while (i < loops) : (i += 1) {

        // MIXED WORKLOAD:
        // Readers (High Freq): 90% of the time, we just read.
        // Writers (Low Freq): 10% of the time, we update.

        if (i % 10 == 0) {
            // --- WRITE LOCK (Exclusive) ---
            var guard = shared_config.write();
            defer guard.release();

            // We can mutate here!
            guard.get().difficulty += 0.1;
            const new_diff = guard.get().difficulty;

            if (i + 10 >= loops) {
              std.debug.print("[Thread {d}] Final update to {d:.1}\n", .{ id, new_diff });
            }

            // Simulate heavy write work
            std.Thread.yield() catch {};
        } else {
            // --- READ LOCK (Shared) ---
            // Multiple threads can be here AT THE SAME TIME.
            var guard = shared_config.read();
            defer guard.release();

            // guard.get().difficulty += 1; // <--- ERROR: Cannot assign to constant
            const val = guard.get().difficulty;
            _ = val; // Just proving we can read it
        }
    }
    std.debug.print("Thread {d} finished.\n", .{id});
}

test "RwLock Many Readers One Writer" {
    const allocator = std.testing.allocator;

    // 1. Create on Heap
    const shared_state = try allocator.create(rt.RwLock(GameConfig));
    shared_state.* = rt.RwLock(GameConfig).init(.{
        .difficulty = 1.0,
        .server_name = "Flux Server",
    });
    defer allocator.destroy(shared_state);

    // 2. Spawn Threads
    const thread_count = 10;
    const loops = 1000;

    var threads = std.ArrayListUnmanaged(std.Thread){};
    defer threads.deinit(allocator);

    var i: usize = 0;
    while (i < thread_count) : (i += 1) {
        const t = try rt.Runtime.spawnThread(
            64*1024,
            rwWorker,
            .{ i, loops, shared_state }
        );
        try threads.append(allocator, t);
    }

    // 3. Join
    for (threads.items) |t| {
        t.join();
    }

    // 4. Verify Final State
    {
        var guard = shared_state.read();
        defer guard.release();

        // Calculate expected:
        // 10 threads * 1000 loops = 10,000 ops
        // 10% are writes = 1,000 writes.
        // Start 1.0 + (1000 * 0.1) = 101.0

        // Note: Floating point math is fuzzy, using epsilon check
        const expected: f32 = 101.0;
        const actual = guard.get().difficulty;

        std.debug.print("\nFinal Difficulty: {d:.2} (Expected ~{d:.2})\n", .{ actual, expected });
        try std.testing.expectApproxEqAbs(expected, actual, 0.01);
    }
}

