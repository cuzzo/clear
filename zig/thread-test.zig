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

    var global_ctx = rt.EbrContext{};
    defer global_ctx.deinit(allocator);

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
            allocator,
            &global_ctx,
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
    var i: usize = 0;
    while (i < loops) : (i += 1) {

        // MVCC UPDATE
        // Notice: No Lock. No Blocking.
        // We pass the allocator because we might need to create a new version.
        try shared_user.update(
            trt,
            allocator,       // Use the global/arena allocator for persistent data
            increaseScore,   // The logic to run
            .{ 1 }           // Arguments (increase by 1)
        );

        // THE CLEANUP: Run GC occasionally (e.g., every 50 loops)
        if (i % 50 == 0) {
             trt.ebr.context.reclaim(allocator);
        }

        // Simulate work
        std.Thread.yield() catch {};
    }
}

test "MVCC Implementation" {
    // 1. Use a GPA so we can SEE the leaks at the end
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // Note: We intentionally DO NOT defer deinit() here if we want to suppress the error,
    // but usually you want to see it to prove the leak happened.
    const allocator = gpa.allocator();

    // Start a scope
    // This ensures all defers inside execute BEFORE we reach the leak check below.
    {
        var global_ctx = rt.EbrContext{};
        defer global_ctx.deinit(allocator);

        // 2. Create Shared User (Gen 0)
        // We allocate the 'Shared' container itself on the heap
        const shared_container = try allocator.create(rt.Shared(User));
        shared_container.* = try rt.Shared(User).init(allocator, User{
            .id = 1,
            .score = 0,
            .name = "Original",
        });

        defer {
            shared_container.deinit(allocator); // Frees the 'User' struct (Gen 500)
            allocator.destroy(shared_container); // Frees the 'Shared' wrapper
        }

        // 3. Spawn Threads
        const thread_count = 5;
        const loops = 100;

        var threads = std.ArrayListUnmanaged(std.Thread){};
        defer threads.deinit(allocator);

        var i: usize = 0;
        while (i < thread_count) : (i += 1) {
            const t = try rt.Runtime.spawnThread(
                allocator,
                &global_ctx,
                64*1024,
                mvccWorker,
                .{ allocator, loops, shared_container }
            );
            try threads.append(allocator, t);
        }

        for (threads.items) |t| {
            t.join();
        }

        // 4. Verify Read works with new Guard API
        // We need a dummy runtime to read from the main thread (since we aren't inside spawnThread)
        // In a real app, main thread would also be an "EBR Thread".
        const main_ebr = rt.ThreadLocalEbr{ .context = &global_ctx };
        var main_rt = rt.Runtime{
            .ebr = main_ebr,
            .stack_backing = undefined,
            .stack_fba = undefined,
            .heap_arena = undefined
        };

        var guard = shared_container.read(&main_rt);
        defer guard.release();

        const final_user = guard.get();
        std.debug.print("\nFinal Score: {d}\n", .{final_user.score});

        // 500 total updates
        try std.testing.expectEqual(@as(i32, 500), final_user.score);

    } // <--- End the scope. All 'defer' statements above run now.

    // THE LEAK CHECK
    const check = gpa.deinit();
    if (check == .leak) @panic("Memory leaks detected");
}

test "EBR Step 1: Storage & Automatic Cleanup" {
    // 1. Setup GPA (General Purpose Allocator) to strictly track memory leaks.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const check = gpa.deinit();
        if (check == .leak) @panic("Memory Leak Detected! The 'limbo' logic failed.");
    }
    const allocator = gpa.allocator();

    // Setup a Dummy Context (Needed for compilation now)
    var dummy_ctx = rt.EbrContext{};
    defer dummy_ctx.deinit(allocator);

    // 2. Initialize our EBR Storage
    var ebr = rt.ThreadLocalEbr{ .context = &dummy_ctx, .limbo_list =.{} };
    // Note: We do NOT defer ebr.deinit() yet. We need to manually empty it first
    // to prove we can access and free the pointers correctly.

    // 3. Create "Garbage" of different types

    // Type A: A simple Integer
    const num_ptr = try allocator.create(i32);
    num_ptr.* = 12345;

    // Type B: A Complex Struct
    const Player = struct { score: i32, health: f32 };
    const player_ptr = try allocator.create(Player);
    player_ptr.* = .{ .score = 100, .health = 99.9 };

    // 4. "Retire" them (Throw them into the generic limbo list)
    try ebr.retire(allocator, num_ptr);
    try ebr.retire(allocator, player_ptr);

    // Verify they are actually in the list
    try std.testing.expectEqual(@as(usize, 2), ebr.limbo_list.items.len);

    // 5. Cleanup the container
    ebr.deinit(allocator);

    // 6. Success!
    // When the test ends, 'gpa.deinit()' will run.
    // If we failed to free the objects properly in step 5, the test will crash.
}

test "EBR Step 2: Signaling" {
    const allocator = std.testing.allocator;

    // 1. Create the GLOBAL Context
    var global_ctx = rt.EbrContext{};
    defer global_ctx.deinit(allocator);

    // 2. Create the LOCAL Thread State
    // Notice we must now link it to the global context
    var local_ebr = rt.ThreadLocalEbr{ .context = &global_ctx, .limbo_list = .{} };
    defer local_ebr.deinit(allocator);

    // Register it (Simulating thread startup)
    try global_ctx.register(allocator, &local_ebr);

    // 3. Verify Initial State
    try std.testing.expectEqual(false, local_ebr.is_active.load(.seq_cst));
    try std.testing.expectEqual(@as(u32, 0), local_ebr.local_epoch.load(.seq_cst));

    // 4. Simulate: Global Time Advances to Epoch 5
    global_ctx.global_epoch.store(5, .seq_cst);

    // 5. Simulate: Thread enters critical section
    local_ebr.enter();

    // VERIFY: Thread should be active and synced to Epoch 5
    try std.testing.expectEqual(true, local_ebr.is_active.load(.seq_cst));
    try std.testing.expectEqual(@as(u32, 5), local_ebr.local_epoch.load(.seq_cst));

    // 6. Simulate: Thread exits
    local_ebr.exit();

    // VERIFY: Thread is inactive
    try std.testing.expectEqual(false, local_ebr.is_active.load(.seq_cst));
}

// Use-after-Free / Thread Death
const AtomicFlag = std.atomic.Value(bool);

fn scavengerWorker(trt: *rt.Runtime, allocator: std.mem.Allocator, stop_flag: *AtomicFlag) !void {
    _ = trt;
    // furious allocation loop to overwrite freed memory
    var trash_bag = std.ArrayListUnmanaged(*i32){};
    defer trash_bag.deinit(allocator);

    while (!stop_flag.load(.monotonic)) {
        // Allocate a new integer (hopefully reusing the spot the Writer just freed)
        const ptr = try allocator.create(i32);

        // POISON THE MEMORY
        // If the Reader is looking at this address, it will now see this garbage
        ptr.* = -999999;

        // Keep it for a microsecond so we hold the slot
        try trash_bag.append(allocator, ptr);

        if (trash_bag.items.len > 100) {
            // Free half to keep churning memory
            for (0..50) |_| {
                const p = trash_bag.pop().?;
                allocator.destroy(p);
            }
        }

        std.Thread.yield() catch {};
    }

    // Cleanup remainder
    for (trash_bag.items) |p| allocator.destroy(p);
}

fn uafWriter(trt: *rt.Runtime, allocator: std.mem.Allocator, shared_int: *rt.Shared(i32), reader_ready: *AtomicFlag) !void {
    // 1. Wait for reader to grab the pointer
    while (!reader_ready.load(.seq_cst)) {
        std.Thread.yield() catch {};
    }

    // 2. Update (This retires the old pointer '42')
    try shared_int.update(trt, allocator, struct{
        fn f(ptr: *i32) void { ptr.* = 100; }
    }.f, .{});

    // 3. DIE IMMEDIATELY
    // Buggy behavior: rt.deinit() -> ebr.deinit() -> frees '42' immediately.
    // The Scavenger thread is waiting to snatch this memory address!
}

fn uafReader(trt: *rt.Runtime, shared_int: *rt.Shared(i32), reader_ready: *AtomicFlag, writer_dead: *AtomicFlag) !void {
    // 1. Grab Read Lock
    var guard = shared_int.read(trt);
    defer guard.release();

    // 2. Tell Writer we are ready
    reader_ready.store(true, .seq_cst);

    // 3. Wait for Writer to die (and free the memory)
    while (!writer_dead.load(.seq_cst)) {
        std.Thread.yield() catch {};
    }

    // 4. Wait a bit for the Scavenger to overwrite the memory
    // (Busy wait to be portable)
    var k: usize = 0;
    while (k < 50_000_000) : (k += 1) {
        std.mem.doNotOptimizeAway(k);
    }

    // 5. READ THE VALUE
    const val = guard.get().*;

    // If the bug exists, 'val' will be -999999 (from scavenger) or crash.
    // If the fix works, 'val' will be 42 (safe).
    std.debug.print("\n[Reader] Value at address {*}: {d}\n", .{guard.get(), val});

    if (val != 42) {
        @panic("CRITICAL ERROR: Data corruption detected! Read garbage instead of 42.");
    }
}

test "PROOF: No Use-After-Free with Scavenger" {
    // We use the GPA because it is good at reusing slots quickly
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // We wrap everything in a block so defers run BEFORE the leak check
    {
        var global_ctx = rt.EbrContext{};
        defer global_ctx.deinit(allocator);

        // Shared Int starts at 42
        const shared_int = try allocator.create(rt.Shared(i32));
        shared_int.* = try rt.Shared(i32).init(allocator, 42);
        // Cleanup manually since we haven't implemented the graveyard yet
        defer {
            shared_int.deinit(allocator);
            allocator.destroy(shared_int);
        }

        var reader_ready = AtomicFlag.init(false);
        var writer_dead = AtomicFlag.init(false);
        var scavenger_stop = AtomicFlag.init(false);

        // 1. Spawn Scavenger (The "Chaos Monkey")
        const t_scav = try rt.Runtime.spawnThread(allocator, &global_ctx, 64*1024, scavengerWorker, .{ allocator, &scavenger_stop });

        // 2. Spawn Reader
        const t_read = try rt.Runtime.spawnThread(allocator, &global_ctx, 64*1024, uafReader, .{ shared_int, &reader_ready, &writer_dead });

        // 3. Spawn Writer
        const t_write = try rt.Runtime.spawnThread(allocator, &global_ctx, 64*1024, uafWriter, .{ allocator, shared_int, &reader_ready });

        // 4. Wait for Writer to die
        t_write.join();
        writer_dead.store(true, .seq_cst); // Tell reader the writer is gone

        // 5. Wait for Reader (This triggers the check)
        t_read.join();

        // 6. Stop Scavenger
        scavenger_stop.store(true, .seq_cst);
        t_scav.join();
    }
    // --- SCOPE END ---
    // All 'defers' above (global_ctx, shared_int) have now executed.

    // NOW we check for leaks
    const check = gpa.deinit();
    if (check == .leak) @panic("Memory leaks detected");
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

    var global_ctx = rt.EbrContext{};
    defer global_ctx.deinit(allocator);

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
            allocator,
            &global_ctx,
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

// IO Test, i.e., this is starting to get useful

// Helper to set a socket to Non-Blocking mode
// We MUST do this, otherwise the OS will block the thread before our Runtime can yield.
fn setNonBlocking(fd: i32) !void {
    const flags = try std.posix.fcntl(fd, std.posix.F_GETFL, 0);
    _ = try std.posix.fcntl(fd, std.posix.F_SETFL, flags | std.posix.O_NONBLOCK);
}

// Global sockets for the test
var read_fd: i32 = undefined;
var write_fd: i32 = undefined;

// Task A: Tries to read. It should BLOCK (Yield) initially because there is no data.
fn readerTask(rt: *rt_header.Runtime) !void {
    std.debug.print("\n[Reader] Starting. Trying to read...", .{});

    var buf: [128]u8 = undefined;

    // This call will:
    // 1. See no data (EAGAIN)
    // 2. Register FD with Epoll
    // 3. Yield to Scheduler
    // ... Time Passes ...
    // 4. Wake up when WriterTask writes data
    const n = try rt.read(read_fd, &buf);

    std.debug.print("\n[Reader] Woke up! Received: {s}", .{buf[0..n]});
}

// Task B: Sleeps, then writes data.
fn writerTask(rt: *rt_header.Runtime) !void {
    std.debug.print("\n[Writer] Sleeping 100ms...", .{});
    rt.sleep(100);

    std.debug.print("\n[Writer] Waking up and writing 'Hello'...", .{});
    _ = try std.posix.write(write_fd, "Hello Fiber!");
}

test "Async I/O with Epoll" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var global_ctx = rt_header.EbrContext{};
    defer global_ctx.deinit(allocator);

    var sched = rt_header.Scheduler.init(allocator, &global_ctx);
    defer sched.deinit();
    rt_header.active_scheduler = &sched;

    // 1. Setup Socket Pair (Simulates Client/Server connection)
    var fds: [2]i32 = undefined;
    try std.posix.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    read_fd = fds[0];
    write_fd = fds[1];

    // CRITICAL: Set Non-Blocking!
    try setNonBlocking(read_fd);
    try setNonBlocking(write_fd);

    defer std.posix.close(read_fd);
    defer std.posix.close(write_fd);

    std.debug.print("\n\n--- Start I/O Test ---", .{});

    // 2. Spawn Tasks
    try sched.spawn(.{}, readerTask);
    try sched.spawn(.{}, writerTask);

    sched.run();

    std.debug.print("\n--- End I/O Test ---\n", .{});
}

