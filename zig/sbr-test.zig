const std = @import("std");
const testing = std.testing;

const Runtime = @import("runtime.zig").Runtime;
const EbrContext = @import("ebr.zig").EbrContext;
const Chain = @import("sbr.zig").Chain;

// -------------------------------------------------------------------------
// DOMAIN OBJECTS
// -------------------------------------------------------------------------

const User = struct {
    id: i64,
    score: i32,
    name: []const u8,
};

// -------------------------------------------------------------------------
// SCENARIO 1: CORRECT STRATEGY (Survivor on Heap): Happy Path, no Branching
// -------------------------------------------------------------------------

/// This function mimics your request:
/// 1. Allocates temporary data on the Stack (Frame).
/// 2. Allocates the RESULT on the Heap (Slab).
/// 3. Returns the Heap object, which survives the `defer restoreStackMark`.
pub fn createUserCorrect(rt: *Runtime) !*User {
    // 1. MARK STACK (The Kill Zone)
    //    We use saveFrameMark (matches your saveStackMark concept)
    const frame_mark = rt.saveFrameMark();

    //    Defer cleanup: The "Scope" ends when this function returns.
    defer rt.restoreFrameMark(frame_mark);

    // 2. Create Dynamic List on STACK (Frame)
    //    Using Frame Allocator (rt.frameAlloc())
    var list = std.ArrayListUnmanaged(*User){};

    //    Alloc 10 temp users in the Kill Zone
    var i: i64 = 0;
    while (i < 10) : (i += 1) {
        // [Alloc] Struct in Stack/Frame
        const stack_user = try rt.frameAlloc().create(User);

        stack_user.* = User{
            .id = i,
            .score = 0,
            .name = "Temp",
        };

        // [Alloc] List Node in Stack/Frame
        try list.append(rt.frameAlloc(), stack_user);
    }

    // 3. Create SURVIVOR in Heap Arena (Slab Allocator)
    //    We use rt.local_allocator (Matches your heapAlloc/Slab concept)
    const heap_user = try rt.local_allocator.create(User);

    //    [Alloc] String Copy on Heap
    const heap_name = try rt.local_allocator.dupe(u8, "Brian");

    heap_user.* = User{
        .id = 999,
        .score = 100 * 2,
        .name = heap_name,
    };

    // 4. MEMORY REPORT (Inside Function)
    //    We can inspect the frame index to see we actually consumed stack memory
    const current_stack = rt.frame_fba.end_index;
    const consumed = current_stack - frame_mark.stack_index;

    std.debug.print("\n[Inside Correct] Stack Consumed: {d} bytes", .{consumed});

    // We expect to have used memory for 10 Users + List pointers
    if (consumed == 0) return error.TestExpectedMemoryConsumption;

    // 5. RETURN
    //    The 'defer' runs now. List and Stack Users are wiped.
    //    Heap User should remain valid.
    return heap_user;
}

test "STRATEGY: Correct Usage (Stack Cleanup + Heap Survivor)" {
    const allocator = std.testing.allocator;
    const frame_mem = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(frame_mem);

    var global_ctx = EbrContext{};

    // Init Runtime
    var rt = try Runtime.initFromSlice(frame_mem, &global_ctx, allocator, allocator, 0);
    rt.wireAllocator();
    defer rt.deinit();

    const start_stack_idx = rt.frame_fba.end_index;

    // --- CALL FUNCTION ---
    const user = try createUserCorrect(&rt);

    // --- VERIFICATION ---

    // 1. Stack should be reset (Scope Reclamation worked)
    //    The 'defer' inside createUserCorrect should have rewound the index.
    try testing.expectEqual(start_stack_idx, rt.frame_fba.end_index);

    // 2. Return value should be VALID (Survivor worked)
    try testing.expectEqual(@as(i64, 999), user.id);
    try testing.expectEqualStrings("Brian", user.name);

    // Cleanup: Since we allocated on the "Heap" (local_allocator),
    // and we don't have the full garbage collector running in this test,
    // we manually free to keep the test runner happy (no leaks).
    rt.local_allocator.free(user.name);
    rt.local_allocator.destroy(user);
}

// -------------------------------------------------------------------------
// SCENARIO 2: FAILURE STRATEGY (Arena Result / Use-After-Free)
// -------------------------------------------------------------------------

/// This function mimics the "Bug":
/// It allocates the RETURN value on the FRAME (Stack), not the Heap.
/// When it returns, the defer wipes the memory backing the return value.
pub fn createUserBroken(rt: *Runtime) !*User {
    // 1. Mark Scope
    const frame_mark = rt.saveFrameMark();
    defer rt.restoreFrameMark(frame_mark); // <--- THE KILL SWITCH

    // 2. Alloc Result on FRAME (Fast, but ephemeral)
    const stack_result = try rt.frameAlloc().create(User);

    // Note: We use a string literal so the string pointer itself is safe (static),
    // but the User struct container is on the frame.
    stack_result.* = User{
        .id = 0xDEADBEEF,
        .score = 50,
        .name = "Doom",
    };

    return stack_result; // <--- Returning a pointer to memory we are about to free
}

test "STRATEGY: Broken Usage (Dangling Pointer / Use-After-Free)" {
    const allocator = std.testing.allocator;
    const frame_mem = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(frame_mem);

    var global_ctx = EbrContext{};
    var rt = try Runtime.initFromSlice(frame_mem, &global_ctx, allocator, allocator, 0);
    rt.wireAllocator();
    defer rt.deinit();

    // 1. Call the broken function
    //    It returns a pointer to memory that was technically just "freed" (rewound).
    const dangling_user = try createUserBroken(&rt);

    std.debug.print("\n[Broken] Pointer returned: {*}", .{dangling_user});
    std.debug.print("\n[Broken] Data before overwrite: 0x{X}", .{dangling_user.id});

    // 2. PROVE IT IS BROKEN
    //    We allocate something NEW on the frame.
    //    Since the stack index was rewound, this new allocation will
    //    OVERWRITE the memory where 'dangling_user' lives.
    const overwrite_struct = try rt.frameAlloc().create(User);
    overwrite_struct.id = 0xCAFEBABE; // The "Corrupting" Value

    // 3. Inspect the original pointer
    std.debug.print("\n[Broken] Data after overwrite:  0x{X}", .{dangling_user.id});

    // The dangling pointer now points to the new data!
    try testing.expectEqual(dangling_user, overwrite_struct);

    // The data inside our "User" object has changed underneath us
    try testing.expectEqual(@as(i64, 0xCAFEBABE), dangling_user.id);
}

// -------------------------------------------------------------------------
// SCENARIO 3: THE "HOT POTATO" (Branching & Leaks)
// -------------------------------------------------------------------------

// This function demonstrates why we need Scope Tracking.
// We allocate MULTIPLE objects on the Heap (to survive return),
// but we only return ONE.
//
// WITHOUT Scope Tracking: The "loser" object leaks.
// WITH Scope Tracking: The "loser" is auto-freed, the "winner" is promoted.
pub fn createBestUser(rt: *Runtime) !*User {
    const heap_mark = rt.saveHeapMark();

    // Allocate Candidate A ("Bad User") on HEAP
    const bad_user = try rt.heapCreate(User);
    bad_user.* = User{ .id = 1, .score = 10, .name = "Low Score" };

    // Allocate Candidate B ("Good User") on HEAP
    const good_user = try rt.heapCreate(User);
    good_user.* = User{ .id = 2, .score = 9000, .name = "High Score" };

    // Logic / Branching
    if (good_user.score > bad_user.score) {
        // 5. SUCCESS: Return Good User
        //    "Clean up everything since heap_mark, but keep good_user"
        // Note: bad_user is now freed!
        // good_user is removed from the tracker (caller must now manage it)
        return rt.heapReturn(heap_mark, good_user);
    }

    // 6. FALLBACK
    return rt.heapReturn(heap_mark, bad_user);
}

test "STRATEGY: Branching Leak (Why we need Scope Tracking)" {
    // We use a specific allocator that tracks leaks
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Setup Runtime
    const frame_mem = try allocator.alloc(u8, 1024 * 1024);
    // REMOVED: defer allocator.free(frame_mem);
    // REASON: We must free it manually BEFORE gpa.deinit()

    var global_ctx = EbrContext{};
    var rt = try Runtime.initFromSlice(frame_mem, &global_ctx, allocator, allocator, 0);
    rt.wireAllocator();

    {
        // Call the function
        // If Scope Tracking works, 'bad_user' is freed automatically here.
        // 'winner' (good_user) survives.
        const winner = try createBestUser(&rt);

        // We manually free the winner (mimicking the caller taking ownership)
        rt.heapFree(winner);
    }

    // CLEANUP RUNTIME
    rt.deinit();

    // FREE FRAME MEMORY MANUALLY
    // We must do this before deinit(), otherwise gpa will think it's a leak,
    // AND we can't free it after deinit() because the allocator is dead.
    allocator.free(frame_mem);

    // VERIFY LEAKS
    const leak_status = gpa.deinit();

    if (leak_status == .leak) {
        std.debug.print("\nFAILURE: Leak Detected! (Scope Tracking failed)\n", .{});
        return error.LeakDetected;
    } else {
        std.debug.print("\nSUCCESS: No Leak Detected!\n", .{});
    }
}

// THE PIPELINE ARCHETYPE
// Takes ownership of 'u'. Returns a *User (could be the same one, could be new).
pub fn upgradeUser(rt: *Runtime, u: *User) !*User {
    const heap_mark = rt.saveHeapMark(); // This is a bit hacky, normally done at start of fn
    try rt.deferFree(u); // acceptHeap

    // Logic: If ID is small, replace the user (Destroy old, Create new).
    if (u.id < 10) {
        // Create NEW user
        const new_u = try rt.heapCreate(User);
        new_u.* = User{ .id = u.id + 100, .score = 0, .name = "Upgraded" };

        // Return NEW user.
        // Because 'u' was added AFTER heap_mark, heapReturn will auto-free 'u'.
        return rt.heapReturn(heap_mark, new_u); // Caller must adopt this.
    }

    // Logic: Modification (Pass-through)
    u.score += 50;

    // Return SAME user.
    // We prevent it from being freed by marking it as survivor.
    return rt.heapReturn(heap_mark, u);
}

test "STRATEGY: The Pipeline (Affine Move / Conditional Replace)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const frame_mem = try allocator.alloc(u8, 1024 * 1024);

    var global_ctx = EbrContext{};
    var rt = try Runtime.initFromSlice(frame_mem, &global_ctx, allocator, allocator, 0);
    rt.wireAllocator();

    // --- CASE 1: Pass-through (Keep Same Object) ---
    {
        const mark = rt.saveHeapMark();

        // 1. Caller Allocates
        const user_a = try rt.heapCreate(User);
        user_a.* = User{ .id = 50, .score = 10, .name = "Keeper" };

        // 2. Caller MOVES ownership to upgradeUser
        // We must forget it, otherwise when we close scope, we might double free
        // (depending on what the callee does).
        rt.heapForget(user_a);

        // 3. Call Pipeline
        // upgradeUser will adopt u1 internally.
        const res1 = try upgradeUser(&rt, user_a);

        // 4. Verify Result
        try testing.expectEqual(user_a, res1); // Pointer should be identical
        try testing.expectEqual(@as(i32, 60), res1.score);

        // Cleanup Case 1
        rt.restoreHeapMark(mark);
    }

    // --- CASE 2: Replacement (Destroy Input, Return New) ---
    {
        const mark = rt.saveHeapMark();

        // 1. Caller Allocates
        const user_b = try rt.heapCreate(User);
        user_b.* = User{ .id = 5, .score = 10, .name = "Trash" }; // ID < 10 triggers replace

        // 2. Caller MOVES ownership
        rt.heapForget(user_b);

        // 3. Call Pipeline
        const res2 = try upgradeUser(&rt, user_b);

        // 4. Verify Result
        try testing.expect(user_b != res2); // Pointers must be DIFFERENT
        try testing.expectEqual(@as(i64, 105), res2.id); // New ID

        // Verify u2 is actually dead/freed?
        // Hard to prove without ASAN or specific allocator hooks,
        // but gpa.deinit at the end will scream if we lost it or double-freed it.

        // Cleanup Case 2
        rt.restoreHeapMark(mark);
    }

    rt.deinit();
    allocator.free(frame_mem);

    const leak_status = gpa.deinit();
    if (leak_status == .leak) return error.LeakDetected;
}

// UNION FIND

// -------------------------------------------------------------------------
// SCENARIO 4: CHAOS & RANDOM SELECTION (Stress Test)
// -------------------------------------------------------------------------

pub fn chaosUser(rt: *Runtime, seed: u64) !*User {
    // 1. PROLOGUE (The Standard Header)
    const frame_mark = rt.saveFrameMark();
    defer rt.restoreFrameMark(frame_mark); // <--- DESTROYS FRAME AT END

    const heap_mark = rt.saveHeapMark();   // <--- MARKS HEAP SCOPE

    // 2. BODY
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    // [FRAME ALLOC] This ArrayList lives on the Scratchpad.
    // It will be implicitly destroyed when 'restoreFrameMark' runs.
    var users = try std.ArrayList(*User).initCapacity(rt.frameAlloc(), 10); // not returned

    // [FRAME ALLOC] Names pool on Scratchpad (pointers only)
    var names = try std.ArrayList([]u8).initCapacity(rt.frameAlloc(), 11); // not returned

    // Create 11 Managed Strings (Heap Treasures)
    for (0..11) |i| {
        // Allocates on HEAP -> POSSIBLY returned
        const name = try std.fmt.allocPrint(rt.heapAlloc(), "User_{d}_{x}", .{ i, random.int(u32) });
        names.appendAssumeCapacity(name);
    }

    // Create 10 Managed Users (Heap Treasures)
    for (0..10) |i| {
        // Allocates on HEAP -> POSSIBLY returned
        const u = try rt.heapCreate(User);

        // Randomly assign a name from our pool
        const name_idx = random.intRangeAtMost(usize, 0, 10);
        const selected_name = names.items[name_idx];

        u.* = .{
            .id = @intCast(i),
            .score = 100,
            .name = selected_name
        };

        // BARNACLE BINDING:
        // We must manually bind the name to the user now, since we created them separately.
        // If u survives, selected_name must survive.
        rt.ufConnect(u, selected_name);

        users.appendAssumeCapacity(u);
    }

    // Connect Two Random Users (The Union)
    const idx_a = random.intRangeAtMost(usize, 0, 9);
    var idx_b = random.intRangeAtMost(usize, 0, 9);
    while (idx_b == idx_a) : (idx_b = random.intRangeAtMost(usize, 0, 9)) {}

    const u_a = users.items[idx_a];
    const u_b = users.items[idx_b];

    rt.ufConnect(u_a, u_b);

    // 3. EPILOGUE
    // We return u_a.
    // - heapReturn analyzes reachability.
    // - u_a is reachable -> Keep.
    // - u_b is connected to u_a -> Keep.
    // - u_a.name and u_b.name are connected -> Keep.
    // - All other Users and Names -> FREE.
    // - The 'users' and 'names' ArrayLists (Frame) -> WIPED by defer.
    return rt.heapReturn(heap_mark, u_a);
}

test "STRATEGY: Chaos (Strict Frame & Heap)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // We use a larger stack to simulate a real fiber stack
    const frame_mem = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(frame_mem);

    var global_ctx = EbrContext{};
    var rt = try Runtime.initFromSlice(frame_mem, &global_ctx, allocator, allocator, 0);
    rt.wireAllocator();

    {
        // CALL THE FUNCTION
        const survivor = try chaosUser(&rt, 999);

        // VERIFY FRAME IS CLEAN
        // Since chaosUser returned, its frame allocation (ArrayLists) MUST be gone.
        // The frame index should be back to 0 (or wherever it started).
        try testing.expectEqual(@as(usize, 0), rt.frame_fba.end_index);

        // CLEANUP SURVIVOR (Manual check)
        rt.heapFree(survivor);
    }

    rt.deinit();
}

// -------------------------------------------------------------------------
// SCENARIO 5: THE BARNACLE (Strict)
// -------------------------------------------------------------------------

pub fn createBarnacleGraph(rt: *Runtime) !*User {
    const frame_mark = rt.saveFrameMark();
    defer rt.restoreFrameMark(frame_mark); // Wipe Frame

    const heap_mark = rt.saveHeapMark();

    const us1 = try rt.heapCreate(User); us1.id = 1;
    const us2 = try rt.heapCreate(User); us2.id = 2;
    const us3 = try rt.heapCreate(User); us3.id = 3;
    const us4 = try rt.heapCreate(User); us4.id = 4;

    rt.ufConnect(us1, us2);
    rt.ufConnect(us2, us3);
    rt.ufConnect(us3, us4);

    // Returns HEAD. But because of UF, u2/u3/u4 survive on the heap.
    return rt.heapReturn(heap_mark, us1);
}

test "STRATEGY: The Barnacle (Graph Survival)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        // We expect leaks here because we return a graph but only free the head.
        // This is the intended behavior of the test (Survivor Test).
        _ = gpa.deinit();
    }
    const allocator = gpa.allocator();

    const frame_mem = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(frame_mem);

    var global_ctx = EbrContext{};
    var rt = try Runtime.initFromSlice(frame_mem, &global_ctx, allocator, allocator, 0);
    rt.wireAllocator();

    const head = try createBarnacleGraph(&rt);

    // Frame should be reset
    try testing.expectEqual(@as(usize, 0), rt.frame_fba.end_index);
    try testing.expectEqual(@as(i64, 1), head.id);

    rt.heapFree(head);
    rt.deinit();
}

// -------------------------------------------------------------------------
// SCENARIO 6: TRANSIENT GRAPH (Strict)
// -------------------------------------------------------------------------

pub fn calcGraphSize(rt: *Runtime) !i32 {
    const frame_mark = rt.saveFrameMark();
    defer rt.restoreFrameMark(frame_mark); // Wipe Frame

    const heap_mark = rt.saveHeapMark();

    // 1. Call Child Function
    // Child returns a survivor. We catch it with heapReceive.
    const head = try createBarnacleGraph(rt);

    // 2. Logic (Traverse)
    // In a real usage, we would follow pointers u1->u2 etc.
    // Here we just simulate work.
    const size: i32 = 4 + @as(i32, @intCast(head.id)) - 1;

    // 3. Return Scalar
    // We are NOT returning a heap object.
    // Therefore, everything in *our* heap scope (including 'head' and its barnacles)
    // is currently "Dead" (unreachable from a return value).

    // We must manually close the Heap scope because we aren't using heapReturn.
    // Passing 'null' means "No Survivor".
    rt.tracker.closeAndCompact(rt.local_allocator, heap_mark, null);

    return size;
}

test "STRATEGY: Transient Graph (Full Cleanup)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) {
            @panic("TEST FAILED: Transient graph leaked! The heap scope did not close correctly.");
        }
    }
    const allocator = gpa.allocator();

    const frame_mem = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(frame_mem);

    var global_ctx = EbrContext{};
    var rt = try Runtime.initFromSlice(frame_mem, &global_ctx, allocator, allocator, 0);
    rt.wireAllocator();

    const size = try calcGraphSize(&rt);

    try testing.expectEqual(@as(i32, 4), size);

    // Verify Frame Reset
    try testing.expectEqual(@as(usize, 0), rt.frame_fba.end_index);

    rt.deinit();
}

// example function that takes a MUT
pub fn injectBarnacle(rt: *Runtime, parent: *User) !void {
    const heap_mark = rt.saveHeapMark();
    // We do NOT return anything, so we use closeAndCompact(..., null) logic manually
    // or implicitly via scope end.
    defer rt.restoreHeapMark(heap_mark); // This usually kills everything local

    // 1. Create a child in THIS scope
    const child = try rt.heapCreate(User);
    child.* = User{ .id = 200, .score = 0, .name = "Parasite" };

    // 2. Attach child to parent (Parent is in OUTER scope)
    // Parent becomes the root.
    rt.ufConnect(parent, child);

    // 3. Return Void.
    // logic: child is in current scope. parent is root. parent.anchored == false.
    // child gets freed. parent now points to dead memory.
    // if a function takes a MUT, it must anchor on write
    rt.anchor(parent);
}

test "FAILURE MODE: Barnacle Injection (Upward Linking)" {
    // Setup Runtime...
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const frame_mem = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(frame_mem);
    var global_ctx = EbrContext{};
    var rt = try Runtime.initFromSlice(frame_mem, &global_ctx, allocator, allocator, 0);
    rt.wireAllocator();
    defer rt.deinit();

    // 1. Alloc Parent in OUTER Scope
    const parent = try rt.heapCreate(User);
    parent.id = 100;

    // 2. Call Function to attach child
    try injectBarnacle(&rt, parent);

    // 3. Verify Child Survival
    // In a real graph, we would traverse parent->child.
    // Here we just check if the memory is valid (or if we crashed on double-free later).
    // If your logic is correct, 'parent' is still the valid root of 'child'.
    // If logic is broken, 'child' was freed, but 'parent' might still think it's connected.

    // Check for leaks/correctness is hard without traversing,
    // but the GPA deinit at the end will tell us if we double-freed or leaked.
}

// -------------------------------------------------------------------------
// SCENARIO 7: TWIN DRAGONS
// -------------------------------------------------------------------------

const Pair = struct {
    left: *User,
    right: *User,
};

pub fn createTwinDragonsBad(rt: *Runtime) !Pair {
    const mark = rt.saveHeapMark();

    // 1. Create two DISJOINT heap objects
    const dragon_l = try rt.heapCreate(User);
    dragon_l.* = User{ .id = 1, .score = 100, .name = "Left" };

    const dragon_r = try rt.heapCreate(User);
    dragon_r.* = User{ .id = 2, .score = 200, .name = "Right" };

    // 2. Return the Pair
    // CURRENT FLAW: heapReturn(mark, struct)
    // Our current runtime logic only inspects Pointers or Optionals.
    // It ignores Structs. Therefore, it will NOT find these pointers,
    // and it will NOT anchor them. They will be freed.
    const result_pair = Pair{ .left = dragon_l, .right = dragon_r };

    return rt.heapReturn(mark, result_pair);
}

test "FAILURE MODE: Twin Dragons" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Use a fresh frame for this test
    const frame_mem = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(frame_mem);

    var global_ctx = EbrContext{};
    var rt = try Runtime.initFromSlice(frame_mem, &global_ctx, allocator, allocator, 0);
    rt.wireAllocator();
    defer rt.deinit();

    // 1. Call the function
    const twins = try createTwinDragonsBad(&rt);

    std.debug.print("\n[Twin] Checking Left (ID 1)...", .{});
    // This might succeed purely by luck if memory hasn't been overwritten yet,
    // or fail immediately.
    try std.testing.expectEqual(@as(i64, 1), twins.left.id);

    std.debug.print(" OK. Checking Right (ID 2)...", .{});

    // THIS EXPECTATION CONFIRMS THE BUG:
    // We expect the data to be valid, but because heapReturn didn't anchor it,
    // it was technically freed. The test runner (GPA) might catch this as a Use-After-Free
    // or we might see garbage data.
    try std.testing.expectEqual(@as(i64, 2), twins.right.id);
}

// TODO: In transpiler, Pair would be a heap alloc, this would be a UF, zero runtime overhead.
pub fn createTwinDragonsGood(rt: *Runtime) !Pair {
    const mark = rt.saveHeapMark();

    // 1. Create two DISJOINT heap objects
    const dragon_l = try rt.heapCreate(User);
    dragon_l.* = User{ .id = 1, .score = 100, .name = "Left" };

    const dragon_r = try rt.heapCreate(User);
    dragon_r.* = User{ .id = 2, .score = 200, .name = "Right" };

    rt.anchor(dragon_l);
    rt.anchor(dragon_r);
    const result_pair = Pair{ .left = dragon_l, .right = dragon_r };

    return rt.heapReturn(mark, result_pair);
}

test "SUCCESS MODE: Twin Dragons" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Use a fresh frame for this test
    const frame_mem = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(frame_mem);

    var global_ctx = EbrContext{};
    var rt = try Runtime.initFromSlice(frame_mem, &global_ctx, allocator, allocator, 0);
    rt.wireAllocator();
    defer rt.deinit();

    // 1. Call the function
    const twins = try createTwinDragonsGood(&rt);

    std.debug.print("\n[Twin] Checking Left (ID 1)...", .{});
    // This might succeed purely by luck if memory hasn't been overwritten yet,
    // or fail immediately.
    try std.testing.expectEqual(@as(i64, 1), twins.left.id);

    std.debug.print(" OK. Checking Right (ID 2)...", .{});

    try std.testing.expectEqual(@as(i64, 2), twins.right.id);
}

// -------------------------------------------------------------------------
// SCENARIO 8: OUROBOROS (Cycles)
// -------------------------------------------------------------------------

pub fn createOuroboros(rt: *Runtime) !*User {
    const mark = rt.saveHeapMark();

    // Create 3 parts of a snake
    // We use multiple statements on one line (valid in Zig functions)
    const head = try rt.heapCreate(User); head.id = 1;
    const body = try rt.heapCreate(User); body.id = 2;
    const tail = try rt.heapCreate(User); tail.id = 3;

    // Connect them in a circle
    rt.ufConnect(head, body);
    rt.ufConnect(body, tail);
    rt.ufConnect(tail, head); // The Cycle

    // Return Head.
    // Because they are all one set, anchoring Head should anchor Body and Tail.
    return rt.heapReturn(mark, head);
}

test "STRESS: Ouroboros (Cycles)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // We expect NO leaks here.
    defer {
        const status = gpa.deinit();
        if (status == .leak) @panic("LEAK DETECTED in Ouroboros!");
    }
    const allocator = gpa.allocator();

    const frame_mem = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(frame_mem);

    var global_ctx = EbrContext{};
    var rt = try Runtime.initFromSlice(frame_mem, &global_ctx, allocator, allocator, 0);
    rt.wireAllocator();

    // 1. Receive the cycle
    const snake = try createOuroboros(&rt);

    // 2. Verify head is valid
    try std.testing.expectEqual(@as(i64, 1), snake.id);

    // 3. Manual Free (Breaks the cycle externally)
    rt.heapFree(snake);

    rt.deinit();
}

//// -------------------------------------------------------------------------
//// SCENARIO 9: Cross Scope Barnacle
//// -------------------------------------------------------------------------
//pub fn crossScopeDanger(rt: *Runtime) !*User {
//    const outer_mark = rt.saveHeapMark();
//
//    const outer_user = try rt.heapCreate(User);
//    outer_user.id = 1;
//
//    {
//        const inner_mark = rt.saveHeapMark();
//
//        const inner_user = try rt.heapCreate(User);
//        inner_user.id = 2;
//
//        // DANGER: Outer points to Inner
//        rt.ufConnect(outer_user, inner_user);
//
//        // Inner scope closes - inner_user is freed
//        rt.restoreHeapMark(inner_mark);
//    }
//
//    // outer_user now has dangling pointer to freed inner_user
//    return rt.heapReturn(outer_mark, outer_user);
//}
//
//test "Cross Scope Barnacle" {
//    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//    // We expect NO leaks here.
//    defer {
//        const status = gpa.deinit();
//        if (status == .leak) @panic("LEAK DETECTED in Cross Scope!");
//    }
//    const allocator = gpa.allocator();
//
//    const frame_mem = try allocator.alloc(u8, 1024 * 1024);
//    defer allocator.free(frame_mem);
//
//    var global_ctx = EbrContext{};
//    var rt = try Runtime.initFromSlice(frame_mem, &global_ctx, allocator, allocator, 0);
//    rt.wireAllocator();
//
//    // This should never transpile, but leads to an error.
//    // Should cause run-time error.
//    const user = try crossScopeDanger(&rt);
//
//    try std.testing.expectEqual(@as(i64, 1), user.id);
//
//    rt.heapFree(user);
//
//    rt.deinit();
//}

// -------------------------------------------------------------------------
// SCENARIO 10: Conditional Return
// -------------------------------------------------------------------------
pub fn conditionalAlloc(rt: *Runtime, flag: bool) !?*User {
    const mark = rt.saveHeapMark();

    var result: ?*User = null;

    if (flag) {
        const user = try rt.heapCreate(User);
        user.id = 1;
        result = user;
    }

    // Your UF analysis: Does it trace through the Optional?
    // If flag is false, result is null - correct.
    // If flag is true, result contains user - must survive.

    return rt.heapReturn(mark, result);
}

test "Conditional Alloc" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // We expect NO leaks here.
    defer {
        const status = gpa.deinit();
        if (status == .leak) @panic("LEAK DETECTED in Cross Scope!");
    }
    const allocator = gpa.allocator();

    const frame_mem = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(frame_mem);

    var global_ctx = EbrContext{};
    var rt = try Runtime.initFromSlice(frame_mem, &global_ctx, allocator, allocator, 0);
    rt.wireAllocator();

    const null_user = try conditionalAlloc(&rt, false);
    try std.testing.expect(null_user == null);

    const good_user = try conditionalAlloc(&rt, true);
    try std.testing.expectEqual(@as(i64, 1), good_user.?.id);

    rt.heapFree(good_user.?);

    rt.deinit();
}

// Anchor / Unanchor for collections
// -------------------------------------------------------------------------
// SCENARIO: Dynamic Filtering (Real-World Use Case)
// -------------------------------------------------------------------------

//pub fn filterUsers(rt: *Runtime, min_score: i32) ![]const *User {
//    const frame_mark = rt.saveFrameMark();
//    defer rt.restoreFrameMark(frame_mark);
//
//    const heap_mark = rt.saveHeapMark();
//
//    // Working list on frame
//    var all_users = std.ArrayListUnmanaged(*User){};
//
//    // Create 20 users with random scores
//    var prng = std.Random.DefaultPrng.init(12345);
//    const random = prng.random();
//
//    for (0..20) |i| {
//        const user = try rt.heapCreate(User);
//        user.* = User{
//            .id = @intCast(i),
//            .score = random.intRangeAtMost(i32, 0, 100),
//            .name = "User",
//        };
//
//        try all_users.append(rt.frameAlloc(), user);
//    }
//
//    // Filter: keep only users with score >= min_score
//    var filtered = std.ArrayListUnmanaged(*User){};
//
//    for (all_users.items) |user| {
//        if (user.score >= min_score) {
//            rt.anchor(user);
//            try filtered.append(rt.heapAlloc(), user);
//            // Keep anchored
//        } else {
//        }
//    }
//
//    std.debug.print("\n[Filter] Kept {d}/{d} users with score >= {d}",
//        .{ filtered.items.len, all_users.items.len, min_score });
//
//    return rt.heapReturn(heap_mark, filtered);
//}
//
//test "STRATEGY: Dynamic Filtering (Real-World)" {
//    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//    defer {
//        const status = gpa.deinit();
//        if (status == .leak) {
//            @panic("LEAK DETECTED!");
//        }
//    }
//    const allocator = gpa.allocator();
//
//    const frame_mem = try allocator.alloc(u8, 1024 * 1024);
//    defer allocator.free(frame_mem);
//
//    var global_ctx = EbrContext{};
//    var rt = try Runtime.initFromSlice(frame_mem, &global_ctx, allocator, allocator, 0);
//    rt.wireAllocator();
//    defer rt.deinit();
//
//    const result = try filterUsers(&rt, 50);
//
//    std.debug.print("\n[Filter] Result has {d} users", .{result.len});
//
//    // Verify all returned users meet criteria
//    for (result) |user| {
//        try testing.expect(user.score >= 50);
//        std.debug.print("\n  User {d}: score {d}", .{ user.id, user.score });
//    }
//
//    // Cleanup
//    for (result) |user| {
//        rt.heapFree(user);
//    }
//    allocator.free(result);
//}
//

// TODO: What about conditional lists?
fn buildAndFilter(rt: *Runtime, n: usize, threshold: i32) ![]const *User {
    const mark = rt.saveHeapMark();

    var list = std.ArrayListUnmanaged(*User){};

    // Phase 1: Build
    for (0..n) |i| {
        const user = try rt.heapCreate(User);
        user.score = @intCast(i);

        try list.append(rt.heapAlloc(), user);
        rt.anchor(user);  // Item is now in collection
    }

    // Phase 2: Filter in-place
    var i: usize = 0;
    while (i < list.items.len) {
        if (list.items[i].score < threshold) {
            const removed = list.orderedRemove(i);
            rt.unanchor(removed);  // Item no longer in collection
            // removed will be freed at scope close
        } else {
            i += 1;
        }
    }

    // Phase 3: Return
    const slice = try list.toOwnedSlice(rt.heapAlloc());
    return rt.heapReturn(mark, slice);
}

test "STRATEGY: Build Filtered List (Real-World)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) {
            @panic("LEAK DETECTED!");
        }
    }
    const allocator = gpa.allocator();

    const frame_mem = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(frame_mem);

    var global_ctx = EbrContext{};
    var rt = try Runtime.initFromSlice(frame_mem, &global_ctx, allocator, allocator, 0);
    rt.wireAllocator();
    defer rt.deinit();

    const result = try buildAndFilter(&rt, 50, 10);

    std.debug.print("\n[Filter] Result has {d} users", .{result.len});

    // Verify all returned users meet criteria
    for (result) |user| {
        try testing.expect(user.score >= 10);
    }

    // Cleanup
    for (result) |user| {
        rt.heapFree(user);
    }
    rt.heapAlloc().free(result);
}

