const std = @import("std");

const CheatLib = @import("runtime-header.zig").CheatLib;
const rt_mod = @import("runtime.zig");
const sm = @import("shared-memory.zig");
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");

const Runtime = rt_mod.Runtime;
const EbrContext = @import("ebr.zig").EbrContext;
const ThreadLocalEbr = @import("ebr.zig").ThreadLocalEbr;
const Locked = sm.Locked;
const Shared = sm.Shared;
const RwLocked = sm.RwLocked;
const Scheduler = fp.Scheduler;
const StackPool = fm.StackPool;

// -------------------------------------------------------------------------
// Locked<T> Testing
// -------------------------------------------------------------------------

fn testWorker(rt: *Runtime, id: usize, loops: usize, shared_counter: *Locked(i32)) !void {
    // Prove we have a working local runtime by using the frame
    // This would crash if the helper didn't bootstrap the frame correctly.
    const msg = try CheatLib.makeString(rt.frameAlloc(), "I am alive");

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

        // 3. Reset frame
        const zero_mark = Runtime.FrameMark{
            .stack_index = 0,
            .overflow_mark = .{ .block_index = 0, .cursor = 0 },
        };
        rt.restoreFrameMark(zero_mark);
    }
    std.debug.print("<- Thread {d} done\n", .{id});
}

test "Runtime Spawn & Mutex Verify" {
    // 1. Setup Test Allocator (Global Heap)
    const allocator = std.testing.allocator;

    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);

    // 2. Create Shared State (Locked<i32>)
    // Must be on the heap so all threads can see it safely.
    const shared_state = try allocator.create(Locked(i32));
    shared_state.* = Locked(i32).init(0);
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
        //  2. Allocates a 64KB frame for it
        //  3. Initializes a new Runtime instance
        //  4. Passes &rt + your args to the function
        const t = try CheatLib.spawnThread(
            allocator,
            64 * 1024,           // Frame Size
            &global_ctx,
            allocator,
            allocator,
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

fn mvccWorker(rt: *Runtime, allocator: std.mem.Allocator, loops: usize, shared_user: *Shared(User)) !void {
    var i: usize = 0;
    while (i < loops) : (i += 1) {

        // MVCC UPDATE
        // Notice: No Lock. No Blocking.
        // We pass the allocator because we might need to create a new version.
        try shared_user.update(
            rt,
            allocator,       // Use the global/arena allocator for persistent data
            increaseScore,   // The logic to run
            .{ 1 }           // Arguments (increase by 1)
        );

        // THE CLEANUP: Run GC occasionally (e.g., every 50 loops)
        if (i % 50 == 0) {
             rt.ebr.context.reclaim(allocator);
             rt.ebr.reclaimLocal(allocator);
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
        var global_ctx = EbrContext{};
        defer global_ctx.deinit(allocator);

        // 2. Create Shared User (Gen 0)
        // We allocate the 'Shared' container itself on the heap
        const shared_container = try allocator.create(Shared(User));
        shared_container.* = try Shared(User).init(allocator, User{
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
            const t = try CheatLib.spawnThread(
                allocator,
                64*1024,
                &global_ctx,
                allocator,
                allocator,
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
        const slab = Runtime.Slab64.init(std.heap.page_allocator, 4 * 1024);
        const main_ebr = ThreadLocalEbr{ .context = &global_ctx };
        var main_rt = Runtime{
            .slab = slab,
            .ebr = main_ebr,
            .frame_backing = undefined,
            .backing_allocator = undefined,
            .heap_allocator = undefined,
            .frame_fba = undefined,
            .global_allocator = undefined,
            .owns_frame_memory = true,
            .deadline = 0,
            .local_allocator = undefined,
            .overflow_arena = undefined,
            .smart_allocator = undefined,
            .tracker = undefined,
        };
        main_rt.wireAllocator();

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
    var dummy_ctx = EbrContext{};
    defer dummy_ctx.deinit(allocator);

    // 2. Initialize our EBR Storage
    var ebr = ThreadLocalEbr{ .context = &dummy_ctx, .limbo_list =.{} };
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
    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);

    // 2. Create the LOCAL Thread State
    // Notice we must now link it to the global context
    var local_ebr = ThreadLocalEbr{ .context = &global_ctx, .limbo_list = .{} };
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

fn scavengerWorker(_: *Runtime, allocator: std.mem.Allocator, stop_flag: *AtomicFlag) !void {
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

fn uafWriter(rt: *Runtime, allocator: std.mem.Allocator, shared_int: *Shared(i32), reader_ready: *AtomicFlag) !void {
    // 1. Wait for reader to grab the pointer
    while (!reader_ready.load(.seq_cst)) {
        std.Thread.yield() catch {};
    }

    // 2. Update (This retires the old pointer '42')
    try shared_int.update(rt, allocator, struct{
        fn f(ptr: *i32) void { ptr.* = 100; }
    }.f, .{});

    // 3. DIE IMMEDIATELY
    // Buggy behavior: rt.deinit() -> ebr.deinit() -> frees '42' immediately.
    // The Scavenger thread is waiting to snatch this memory address!
}

fn uafReader(rt: *Runtime, shared_int: *Shared(i32), reader_ready: *AtomicFlag, writer_dead: *AtomicFlag) !void {
    // 1. Grab Read Lock
    var guard = shared_int.read(rt);
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
        var global_ctx = EbrContext{};
        defer global_ctx.deinit(allocator);

        // Shared Int starts at 42
        const shared_int = try allocator.create(Shared(i32));
        shared_int.* = try Shared(i32).init(allocator, 42);
        // Cleanup manually since we haven't implemented the graveyard yet
        defer {
            shared_int.deinit(allocator);
            allocator.destroy(shared_int);
        }

        var reader_ready = AtomicFlag.init(false);
        var writer_dead = AtomicFlag.init(false);
        var scavenger_stop = AtomicFlag.init(false);

        // 1. Spawn Scavenger (The "Chaos Monkey")
        const t_scav = try CheatLib.spawnThread(allocator, 64*1024, &global_ctx, allocator, allocator, scavengerWorker, .{ allocator, &scavenger_stop });

        // 2. Spawn Reader
        const t_read = try CheatLib.spawnThread(allocator, 64*1024, &global_ctx, allocator, allocator, uafReader, .{ shared_int, &reader_ready, &writer_dead });

        // 3. Spawn Writer
        const t_write = try CheatLib.spawnThread(allocator, 64*1024, &global_ctx, allocator, allocator, uafWriter, .{ allocator, shared_int, &reader_ready });

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
// RwLocked<T> Testing
// -------------------------------------------------------------------------

const GameConfig = struct {
    difficulty: f32,
    server_name: []const u8,
};

fn rwWorker(_: *Runtime, id: usize, loops: usize, shared_config: *RwLocked(GameConfig)) !void {
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

test "RwLocked Many Readers One Writer" {
    const allocator = std.testing.allocator;

    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);

    // 1. Create on Heap
    const shared_state = try allocator.create(RwLocked(GameConfig));
    shared_state.* = RwLocked(GameConfig).init(.{
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
        const t = try CheatLib.spawnThread(
            allocator,
            64*1024,
            &global_ctx,
            allocator,
            allocator,
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

// Cross Thread Communication

// The generic worker loop for the threads
fn workerLoop(r: *Runtime, id: u32, shutdown_signal: *std.atomic.Value(bool), stack_pool: *StackPool) !void {
    std.debug.print("[Worker {d}] Starting...\n", .{id});

    // 1. Initialize the Scheduler for this thread
    // We use the runtime's local allocator (which is the test allocator)
    // and the global EBR context linked in the runtime.
    const sched = try r.globalAlloc().create(Scheduler);
    sched.* = try Scheduler.init(r.globalAlloc(), r.ebr.context, stack_pool);

    defer {
        sched.deinit();
        r.globalAlloc().destroy(sched);
    }

    sched.shutdown_on_idle = false;
    sched.global_shutdown = shutdown_signal;

    // 2. Register it as the ACTIVE scheduler for this thread
    fp.active_scheduler = sched;

    std.debug.print("Worker {d} online (ID: {d})\n", .{id, std.Thread.getCurrentId()});

    // 3. Run the loop
    sched.run();
}

test "Cross-Thread Spawning & Load Balancing" {
    std.debug.print("Size of Scheduler: {d} bytes\n", .{@sizeOf(Scheduler)});

    const allocator = std.testing.allocator;

    // 1. Setup Registry & Context
    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);

    var stack_pool = StackPool.init(allocator);
    defer stack_pool.deinit();

    // Initialize Global Registry
    fp.global_registry.mutex = .{};
    fp.global_registry.map = .{};
    defer fp.global_registry.map.deinit(allocator);

    var shutdown_signal = std.atomic.Value(bool).init(false);

    var threads = std.ArrayListUnmanaged(std.Thread){};
    defer threads.deinit(allocator);

    // 2. Start Worker Threads
    // We'll use a WaitGroup to know when they are "ready" to accept work logic
    // But for this low-level test, we just start them.
    const t1 = try CheatLib.spawnThread(allocator, 16 * 1024, &global_ctx, allocator, allocator, workerLoop, .{1, &shutdown_signal, &stack_pool});
    const t2 = try CheatLib.spawnThread(allocator, 16 * 1024, &global_ctx, allocator, allocator, workerLoop, .{2, &shutdown_signal, &stack_pool});

    try threads.append(allocator, t1);
    try threads.append(allocator, t2);

    // Give them a moment to register themselves
    std.posix.nanosleep(0, 100 * std.time.ns_per_ms);

    // ---------------------------------------------------------
    // TEST 1: SpawnOn (Direct Communication)
    // ---------------------------------------------------------
    std.debug.print("\n=== Test 1: Remote Message ===\n", .{});

    var id1: std.Thread.Id = 0;

    // Retry for up to 1 sec
    var retries: usize = 0;
    while (retries < 100) : (retries += 1) {
        fp.global_registry.mutex.lock();

        const count = fp.global_registry.map.count();
        if (count > 0) {
            var it = fp.global_registry.map.keyIterator();
            id1 = it.next().?.*;
            fp.global_registry.mutex.unlock(); // unlock if found!
            break; // Found one!
        }

        if (retries % 10 == 0) {
            std.debug.print("Waiting for workers... (Count: {d})\n", .{count});
        }

        fp.global_registry.mutex.unlock(); // Unlock if not found!
        std.posix.nanosleep(0, 10 * std.time.ns_per_ms);
    }

    if (id1 == 0) {
        // If still empty after 1s, fail gracefully instead of crashing
        std.debug.print("Error: No workers registered. Map count: {d}\n", .{fp.global_registry.map.count()});
        return error.Timeout;
    }

    // A. Create Data on Global Heap
    const Msg = struct { text: []u8, processed: bool };
    const msg = try allocator.create(Msg);
    msg.text = try allocator.dupe(u8, "Hello from Main");
    msg.processed = false;

    // B. Define the Handler (must be generic signature)
    const Handler = struct {
        fn run(_: *Runtime, ctx: ?*anyopaque) anyerror!void {
            const m = @as(*Msg, @ptrCast(@alignCast(ctx)));

            // Print what we got
            std.debug.print("Thread {d} got message: {s}\n", .{std.Thread.getCurrentId(), m.text});

            // Modify it
            m.processed = true;

            // We DO NOT free 'm' here, we let the main thread verify it first.
            // In a real fire-and-forget, we would free it here.
        }
    };

    // C. Send to Thread 1 (We need its ID)
    // For test stability, we cheat and lookup the registry keys, or just use t1.getHandle().
    // But t1.getHandle() isn't the ID.
    // Let's iterate the registry to find IDs.
    {
        fp.global_registry.mutex.lock();
        defer fp.global_registry.mutex.unlock();
        var it2 = fp.global_registry.map.keyIterator();
        id1 = it2.next().?.*;
    }

    try Runtime.spawnOn(id1, Handler.run, msg);

    // D. Wait for it (Spin wait for test simplicity)
    while (!msg.processed) {
        std.posix.nanosleep(0, 100 * std.time.ns_per_ms);
    }
    std.debug.print("Main detected message processed!\n", .{});

    // Cleanup Message
    allocator.free(msg.text);
    allocator.destroy(msg);

    // ---------------------------------------------------------
    // TEST 2: SpawnBest (Load Balancing)
    // ---------------------------------------------------------
    std.debug.print("\n=== Test 2: Load Balancing (Flooding) ===\n", .{});

    // We will spawn 20 tasks using spawnBest.
    // Since both threads are empty, they should get roughly 10 each.

    const LoadTask = struct {
        fn run(_: *Runtime, _: ?*anyopaque) anyerror!void {
            // Just simulate work
            std.posix.nanosleep(0, 100 * std.time.ns_per_ms);
            // std.debug.print(".", .{});
        }
    };

    var i: usize = 0;
    while (i < 20) : (i += 1) {
        try Runtime.spawnBest(LoadTask.run, null);
    }

    // Let them finish
    std.posix.nanosleep(0, 500 * std.time.ns_per_ms);
    std.debug.print("\nDone.\n", .{});

    shutdown_signal.store(true, .seq_cst);

    {
        fp.global_registry.mutex.lock();
        defer fp.global_registry.mutex.unlock();
        var it = fp.global_registry.map.iterator();
        while (it.next()) |entry| {
            // Write to their event_fd to break the poll loop
            entry.value_ptr.*.event_fd.notify();
        }
    }

    for (threads.items) |t| {
        t.join();
    }
}

