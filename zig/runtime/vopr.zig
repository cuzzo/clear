// vopr.zig — VOPR (Viewstamped Operation Replicator) for CLEAR runtime.
//
// Deterministic simulation testing inspired by TigerBeetle's VOPR.
// Single-threaded simulation of N schedulers exercising the REAL RunQueue
// (Chase-Lev deque) from queues.zig.  All nondeterminism driven by a
// seeded PRNG.  Invariants checked after every step.
//
// Usage:
//   zig build vopr                                        # 100K seeds (default)
//   zig build-exe vopr.zig -lc -OReleaseFast && ./vopr    # direct build
//   ./vopr --seeds 1000000                                # 1M seeds
//   ./vopr --start 42 --seeds 1                           # reproduce a single seed

const std = @import("std");
const vs = @import("vopr-state.zig");
const vi = @import("vopr-invariants.zig");
const qs = @import("queues.zig");

const VoprState = vs.VoprState;
const SimScheduler = vs.SimScheduler;
const Task = qs.Task;

const StepKind = enum {
    PopAndRun,
    TrySteal,
    PollEpoll,
    DrainSpawns,
    WakeSleepers,
    InjectFault,
    ShardAccess,
    DrainShardOps,
};

const FaultKind = enum {
    EpollDoubleFire,
    StealFromSingleElement,
    MakeFdReady,
    SpawnPinned,
};

/// Pick a weighted step type.
fn pickStep(random: std.Random) StepKind {
    const roll = random.intRangeAtMost(u8, 0, 99);
    if (roll < 35) return .PopAndRun;
    if (roll < 50) return .TrySteal;
    if (roll < 60) return .PollEpoll;
    if (roll < 70) return .DrainSpawns;
    if (roll < 75) return .WakeSleepers;
    if (roll < 85) return .ShardAccess;
    if (roll < 93) return .DrainShardOps;
    return .InjectFault;
}

fn pickFault(random: std.Random) FaultKind {
    const roll = random.intRangeAtMost(u8, 0, 3);
    return @enumFromInt(roll);
}

/// Execute one simulation step on a given scheduler.
fn executeStep(state: *VoprState, sched_idx: usize, step: StepKind) void {
    const sched = &state.schedulers[sched_idx];

    switch (step) {
        .PopAndRun => executePopAndRun(state, sched, sched_idx),
        .TrySteal => executeTrySteal(state, sched, sched_idx),
        .PollEpoll => executePollEpoll(state, sched, @intCast(sched_idx)),
        .DrainSpawns => executeDrainSpawns(state),
        .WakeSleepers => executeWakeSleepers(state, sched),
        .InjectFault => executeInjectFault(state, sched_idx),
        .ShardAccess => executeShardAccess(state, sched, @intCast(sched_idx)),
        .DrainShardOps => executeDrainShardOps(state, sched, @intCast(sched_idx)),
    }
}

fn executePopAndRun(state: *VoprState, sched: *SimScheduler, sched_idx: usize) void {
    // Pinned queue first (matches production scheduler's run loop),
    // then ready queue. Pinned tasks include both permanently-pinned
    // tasks and temporarily-pinned tasks from sendAndWait's steal guard.
    const task = if (sched.pinned_queue.items.len > 0)
        sched.pinned_queue.swapRemove(0)
    else blk: {
        if (sched.ready_queue.len() == 0) return;
        // This exercises the real pop() — the TOCTOU fix (bug 1) means
        // pop() can return null even after len() > 0.
        break :blk sched.ready_queue.pop() orelse return;
    };

    // Validate the pointer is in our registry
    if (!state.task_registry.contains(task)) {
        std.debug.print("VOPR: pop() returned unregistered pointer {*}\n", .{task});
        @panic("VOPR: invalid pointer from pop()");
    }

    sched.current_task = task;
    state.task_registry.put(state.allocator, task, .Running) catch unreachable;

    // Simulate task execution using PRNG
    const sim = state.getSimTask(task) orelse {
        std.debug.print("VOPR: task {*} not found in SimTask pool\n", .{task});
        @panic("VOPR: orphaned task pointer");
    };

    if (sim.steps_remaining > 0) {
        sim.steps_remaining -= 1;
    }

    if (sim.steps_remaining == 0) {
        if (sim.will_do_io and sim.io_fd == -1) {
            // Block on I/O — first time
            const fd = state.allocFd(task, sim.owner_sched);
            sim.io_fd = fd;
            task.status.store(.Blocked, .release);
            state.blocked_tasks.put(state.allocator, task, fd) catch unreachable;
            state.task_registry.put(state.allocator, task, .Blocked) catch unreachable;
            // Give it more steps for when it resumes
            sim.steps_remaining = state.random.intRangeAtMost(u16, 1, 10);
            sim.will_do_io = false; // Don't block again
        } else {
            // Task finished
            task.status.store(.Finished, .release);
            sched.active_tasks -|= 1;
            state.total_finished += 1;
            state.task_registry.put(state.allocator, task, .Finished) catch unreachable;
            sim.alive = false;
        }
    } else {
        // Simulate shard access (30% chance). Both pinned and unpinned tasks
        // can access shards. The sendAndWait fix (temporary pin during yield)
        // prevents unpinned tasks from being stolen while a remote op is pending.
        if (state.shard_count > 0 and state.random.intRangeAtMost(u8, 0, 2) == 0) {
            const shard_idx = state.random.intRangeLessThan(usize, 0, state.shard_count);
            const shard = &state.shards[shard_idx];
            if (shard.owner_sched == @as(u32, @intCast(sched_idx))) {
                // LOCAL path: task is on the owner scheduler.
                // Record access (for invariant checking).
                shard.last_access_tick = state.tick;
                shard.last_access_sched = @intCast(sched_idx);
            } else {
                // REMOTE path: queue a pending op on the owner's inbox.
                // Temporarily pin the task (models sendAndWait's steal guard).
                const owner = &state.schedulers[shard.owner_sched];
                owner.pending_shard_ops.append(state.allocator, .{
                    .shard = @intCast(shard_idx),
                    .source_task = task,
                }) catch {};
                sim.pending_remote_count += 1;
                if (!task.config.pinned) {
                    task.config.pinned = true;
                }
            }
        }

        // Yield — push back to ready queue
        task.status.store(.Ready, .release);
        sched.enqueueTask(state.allocator, task);
        state.task_registry.put(state.allocator, task, .InQueue) catch unreachable;
    }

    sched.current_task = null;
    sched.ticks_since_poll += 1;
}

fn executeTrySteal(state: *VoprState, sched: *SimScheduler, sched_idx: usize) void {
    if (state.sched_count < 2) return;

    // Pick a victim (not ourselves)
    var victim_idx = state.random.intRangeLessThan(usize, 0, state.sched_count);
    if (victim_idx == sched_idx) {
        victim_idx = (victim_idx + 1) % state.sched_count;
    }

    const victim = &state.schedulers[victim_idx];

    // Call the REAL tryStealFrom — this exercises stealOne() and the
    // pinned task handling (bug 5 fix: push back instead of drop).
    const stolen = sched.ready_queue.tryStealFrom(victim.ready_queue, state.allocator);

    if (stolen > 0) {
        sched.active_tasks += stolen;
        victim.active_tasks -|= stolen;
    }
}

fn executePollEpoll(state: *VoprState, sched: *SimScheduler, sched_idx: u32) void {
    sched.ticks_since_poll = 0;

    // Check our registered fds for readiness
    var to_wake = std.ArrayListUnmanaged(*Task){};
    defer to_wake.deinit(state.allocator);

    var fd_iter = sched.poll_fds.iterator();
    while (fd_iter.next()) |entry| {
        const fd = entry.key_ptr.*;
        if (state.sim_fds.getPtr(fd)) |sim_fd| {
            if (sim_fd.ready) {
                const task = entry.value_ptr.*;

                // Bug 4 fix: skip if already Ready (the double-push guard)
                if (task.status.load(.acquire) != .Ready) {
                    to_wake.append(state.allocator, task) catch unreachable;
                }

                // Clear readiness (edge-triggered semantics)
                sim_fd.ready = false;
            }
        }
    }

    // Wake the tasks
    for (to_wake.items) |task| {
        task.status.store(.Ready, .release);
        sched.enqueueTask(state.allocator, task);
        state.task_registry.put(state.allocator, task, .InQueue) catch unreachable;
        _ = state.blocked_tasks.remove(task);

        // Clean up fd registration
        if (state.getSimTask(task)) |sim| {
            if (sim.io_fd >= 0) {
                _ = sched.poll_fds.remove(sim.io_fd);
                if (state.sim_fds.getPtr(sim.io_fd)) |sfd| {
                    sfd.registered_sched = null;
                }
            }
        }
    }
    _ = sched_idx;
}

/// Simulate a task on this scheduler accessing a shard.
/// If the shard is owned by this scheduler (LOCAL), access directly.
/// If owned by another scheduler (REMOTE), queue a pending op.
/// This models sendAndWait: LOCAL calls func directly, REMOTE sends via SPSC.
fn executeShardAccess(state: *VoprState, sched: *SimScheduler, sched_idx: u32) void {
    if (state.shard_count == 0) return;
    if (sched.ready_queue.len() == 0) return;

    // Pick a random shard
    const shard_idx = state.random.intRangeLessThan(usize, 0, state.shard_count);
    const shard = &state.shards[shard_idx];

    if (shard.owner_sched == sched_idx) {
        // LOCAL access: record the access on this scheduler/tick.
        shard.last_access_tick = state.tick;
        shard.last_access_sched = sched_idx;
    } else {
        // REMOTE access: queue a pending op on the OWNER scheduler's inbox.
        // In the real system, this goes via SPSC and is processed by drainChannels.
        const owner = &state.schedulers[shard.owner_sched];
        // Grab a task pointer for the pending op (any running/ready task on this sched)
        const task = sched.current_task orelse return;
        owner.pending_shard_ops.append(state.allocator, .{
            .shard = @intCast(shard_idx),
            .source_task = task,
        }) catch return;
    }
}

/// Simulate drainChannels: process pending remote shard ops.
/// Each processed op accesses the shard (records tick + sched).
/// Restores the temporary pin set by sendAndWait's steal guard.
fn executeDrainShardOps(state: *VoprState, sched: *SimScheduler, sched_idx: u32) void {
    while (sched.pending_shard_ops.items.len > 0) {
        const op = sched.pending_shard_ops.orderedRemove(0);
        const shard = &state.shards[op.shard];
        // The drain happens on the OWNER scheduler's thread.
        shard.last_access_tick = state.tick;
        shard.last_access_sched = sched_idx;
        // Decrement pending count; restore unpinned when all ops drained
        // (only for originally-unpinned tasks -- permanent pins never clear).
        if (state.getSimTask(op.source_task)) |sim| {
            if (sim.pending_remote_count > 0) {
                sim.pending_remote_count -= 1;
                if (sim.pending_remote_count == 0 and !sim.originally_pinned) {
                    op.source_task.config.pinned = false;
                }
            }
        }
    }
}

fn executeDrainSpawns(state: *VoprState) void {
    while (state.pending_spawns.items.len > 0) {
        const spawn = state.pending_spawns.orderedRemove(0);
        const target = &state.schedulers[spawn.target_sched];
        target.enqueueTask(state.allocator, spawn.task);
        target.active_tasks += 1;
        state.task_registry.put(state.allocator, spawn.task, .InQueue) catch unreachable;
    }
}

fn executeWakeSleepers(state: *VoprState, sched: *SimScheduler) void {
    state.sim_time_ms += state.random.intRangeAtMost(i64, 1, 50);

    var i: usize = 0;
    while (i < sched.sleeping_queue.items.len) {
        const task = sched.sleeping_queue.items[i];
        if (state.sim_time_ms >= task.wake_time) {
            _ = sched.sleeping_queue.swapRemove(i);
            task.status.store(.Ready, .release);
            sched.enqueueTask(state.allocator, task);
            state.task_registry.put(state.allocator, task, .InQueue) catch unreachable;
        } else {
            i += 1;
        }
    }
}

fn executeInjectFault(state: *VoprState, sched_idx: usize) void {
    const fault = pickFault(state.random);
    const sched = &state.schedulers[sched_idx];

    switch (fault) {
        .EpollDoubleFire => {
            // Bug 4: try to push a task that's already Ready in the queue.
            // The production code guards with `if (task.status.load(.acquire) != .Ready)`.
            // We simulate what happens if epoll fires for an already-ready task.
            var fd_iter = sched.poll_fds.iterator();
            while (fd_iter.next()) |entry| {
                const task = entry.value_ptr.*;
                if (task.status.load(.acquire) == .Ready) {
                    // In buggy code, this would double-push.
                    // The fix skips the push.  We don't push here either —
                    // the invariant checker verifies no duplicates exist.
                    break;
                }
            }
        },

        .StealFromSingleElement => {
            // Bug 1: try to steal when victim has exactly 1 element.
            // This is the TOCTOU scenario: len()==1, then steal races with pop().
            if (state.sched_count < 2) return;

            var victim_idx = (sched_idx + 1) % state.sched_count;
            // Find a victim with exactly 1 task
            for (0..state.sched_count) |offset| {
                const candidate = (sched_idx + 1 + offset) % state.sched_count;
                if (candidate == sched_idx) continue;
                if (state.schedulers[candidate].ready_queue.len() == 1) {
                    victim_idx = candidate;
                    break;
                }
            }

            const victim = &state.schedulers[victim_idx];
            if (victim.ready_queue.len() > 0) {
                // Steal — exercises the CAS race path in stealOne
                const stolen = sched.ready_queue.tryStealFrom(victim.ready_queue, state.allocator);
                if (stolen > 0) {
                    sched.active_tasks += stolen;
                    victim.active_tasks -|= stolen;
                }
            }
        },

        .MakeFdReady => {
            // Bug 7: make a blocked fd ready, then check if it gets polled.
            var fd_iter = state.sim_fds.iterator();
            while (fd_iter.next()) |entry| {
                const sim_fd = entry.value_ptr;
                if (!sim_fd.ready and sim_fd.registered_sched != null) {
                    sim_fd.ready = true;
                    sim_fd.ready_since_tick = state.tick;
                    break;
                }
            }
        },

        .SpawnPinned => {
            // Bug 5: spawn a pinned task and let steals exercise the pinned guard.
            if (state.task_count < vs.MAX_TASKS) {
                state.spawnTask(@intCast(sched_idx), true) catch {};
            }
        },
    }
}

/// Run the VOPR for a single seed.
pub fn runVopr(seed: u64, max_ticks: u64) !void {
    return runVoprAlloc(seed, max_ticks, std.heap.c_allocator);
}

fn runVoprAlloc(seed: u64, max_ticks: u64, allocator: std.mem.Allocator) !void {
    var state = VoprState.init(seed, allocator);
    // Re-bind random interface after move — the pointer inside random()
    // captures &state.rng which was on the stack during init().
    state.random = state.rng.random();
    defer state.deinit();

    // Create 2-6 schedulers (PRNG)
    const n_schedulers = 2 + state.random.intRangeAtMost(usize, 0, 4);
    state.initSchedulers(n_schedulers);

    // Initialize shards (simulates PartitionedStringMap ownership)
    const n_shards = 2 + state.random.intRangeAtMost(usize, 0, vs.MAX_SHARDS - 2);
    state.initShards(n_shards);

    // Spawn 8-32 initial tasks, mix of pinned and unpinned
    const n_tasks = 8 + state.random.intRangeAtMost(usize, 0, 24);
    for (0..n_tasks) |_| {
        const target = state.random.intRangeLessThan(usize, 0, n_schedulers);
        const pinned = state.random.intRangeAtMost(u8, 0, 3) == 0;
        state.spawnTask(@intCast(target), pinned) catch break;
    }

    // Check initial state
    vi.checkAll(&state) catch |err| {
        std.debug.print("VOPR FAILED at seed={d} tick=0 (initial state): {}\n", .{ seed, err });
        return err;
    };

    // Main simulation loop
    var tick: u64 = 0;
    while (tick < max_ticks) : (tick += 1) {
        state.tick = tick;

        if (state.allTasksFinished()) break;

        // Pick scheduler and step
        const sched_idx = state.random.intRangeLessThan(usize, 0, n_schedulers);
        const step = pickStep(state.random);

        // Execute
        executeStep(&state, sched_idx, step);

        // Check invariants periodically (every 4 ticks for speed,
        // and always after steals/faults which are the high-risk ops)
        const check_invariants = (tick & 3 == 0) or step == .TrySteal or step == .InjectFault or step == .ShardAccess or step == .DrainShardOps;
        if (check_invariants) {
            vi.checkAll(&state) catch |err| {
                std.debug.print("VOPR FAILED at seed={d} tick={d} sched={d} step={s}: {}\n", .{
                    seed,
                    tick,
                    sched_idx,
                    @tagName(step),
                    err,
                });
                return err;
            };
        }

        // Occasionally spawn more tasks (5% chance)
        if (state.random.intRangeAtMost(u8, 0, 19) == 0) {
            const target = state.random.intRangeLessThan(usize, 0, n_schedulers);
            const pinned = state.random.intRangeAtMost(u8, 0, 4) == 0;
            state.queueSpawn(@intCast(target), pinned) catch {};
        }

        // Occasionally make I/O fds ready (10% chance)
        if (state.random.intRangeAtMost(u8, 0, 9) == 0) {
            var fd_iter = state.sim_fds.iterator();
            while (fd_iter.next()) |entry| {
                const sim_fd = entry.value_ptr;
                if (!sim_fd.ready and sim_fd.registered_sched != null) {
                    sim_fd.ready = true;
                    sim_fd.ready_since_tick = state.tick;
                    break;
                }
            }
        }
    }
}

pub fn main() !void {
    var seed_start: u64 = 0;
    var seed_count: u64 = 100_000;
    const max_ticks: u64 = 2_000;

    // Parse CLI args
    var args = std.process.args();
    _ = args.skip(); // program name
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--seeds")) {
            if (args.next()) |val| {
                seed_count = std.fmt.parseInt(u64, val, 10) catch 1_000_000;
            }
        } else if (std.mem.eql(u8, arg, "--start")) {
            if (args.next()) |val| {
                seed_start = std.fmt.parseInt(u64, val, 10) catch 0;
            }
        }
    }

    std.debug.print("VOPR: {d} seeds starting at {d}, {d} ticks/seed\n", .{ seed_count, seed_start, max_ticks });

    var failures: u64 = 0;
    for (seed_start..seed_start + seed_count) |seed| {
        runVopr(seed, max_ticks) catch {
            failures += 1;
            if (failures >= 10) {
                std.debug.print("VOPR: {d} failures, stopping early\n", .{failures});
                std.process.exit(1);
            }
        };
        if (seed % 100_000 == 0 and seed > seed_start) {
            std.debug.print("VOPR: {d}/{d} seeds OK\n", .{ seed - seed_start, seed_count });
        }
    }

    if (failures > 0) {
        std.debug.print("VOPR: FAILED — {d}/{d} seeds failed\n", .{ failures, seed_count });
        std.process.exit(1);
    }

    std.debug.print("VOPR: PASSED — all {d} seeds OK\n", .{seed_count});
}

// -----------------------------------------------------------------------
// Unit tests -- 100 seeds, ~200 ticks each. Catches task conservation
// and pinned affinity bugs on the first steal. Complements the Loom
// tests which catch interleaving bugs but can't detect uninitialized
// memory (SimAtomic uses plain values, not raw memory).
// -----------------------------------------------------------------------

test "vopr: task conservation and pinned affinity" {
    for (0..100) |seed| {
        try runVoprAlloc(seed, 200, std.testing.allocator);
    }
}

test "vopr: stolen task with pending remote shard op triggers ShardConcurrentAccess" {
    // Deterministic reproduction: verifies the invariant checker catches the
    // scenario that sendAndWait's temporary pin prevents in the real runtime.
    //   1. Unpinned task on sched 1 (no shards yet, so no temporary pin)
    //   2. Manually inject a pending remote shard op (bypass the pin guard)
    //   3. Steal the task to sched 0
    //   4. Invariant fires: task is in sched 0's queue AND sched 0 has a pending
    //      remote op from that same task.
    const allocator = std.testing.allocator;
    var state = VoprState.init(42, allocator);
    state.random = state.rng.random();
    defer state.deinit();

    // Init schedulers first, shards AFTER pop-and-run to avoid the
    // temporary pin from shard access during executePopAndRun.
    state.initSchedulers(2);

    // Spawn an unpinned task on sched 1
    try state.spawnTask(1, false);
    const task = &state.tasks[0].?.task;

    // Step 1: Pop the task on sched 1 (no shards, so no shard access).
    executePopAndRun(&state, &state.schedulers[1], 1);
    // After PopAndRun, the task yielded back to sched 1's ready queue.

    // Now init shards for the invariant checker.
    state.initShards(2);

    // Step 2: Simulate the task sending a REMOTE shard op to sched 0.
    // This is what happens inside sendAndWait when the task accesses shard 0
    // from sched 1 (not the owner).
    state.schedulers[0].pending_shard_ops.append(allocator, .{
        .shard = 0,
        .source_task = task,
    }) catch unreachable;

    // Step 3: Steal the task from sched 1 to sched 0.
    const stolen = state.schedulers[0].ready_queue.tryStealFrom(
        state.schedulers[1].ready_queue, allocator,
    );
    try std.testing.expect(stolen > 0);

    // Step 4: Check invariant — should fire ShardConcurrentAccess.
    // The task is now in sched 0's ready queue, AND sched 0 has a pending
    // remote op from that task. If sched 0 pops the task and it does a
    // LOCAL access to shard 0, that races with drainChannels processing
    // the pending remote op.
    const result = vi.checkAll(&state);
    try std.testing.expectError(error.ShardConcurrentAccess, result);
}
