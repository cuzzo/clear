const std = @import("std");
const rt = @import("runtime-header.zig");

// -------------------------------------------------------------------------
// Testing & Verification
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

//fn testWorker(trt: *rt.Runtime, loops: usize, shared_counter: *rt.Locked(i32)) !void {
//
//    var i: usize = 0;
//    while (i < loops) : (i += 1) {
//        // 1. Acquire Lock
//        var guard = shared_counter.acquire();
//        defer guard.release(); // Safe unlock
//
//        // 2. Mutate Shared Data
//        guard.get().* += 1;
//
//        // 3. Reset local stack for next iteration (Frame behavior)
//        trt.restoreStackMark(0);
//    }
//}

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

