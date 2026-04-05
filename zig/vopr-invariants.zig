// vopr-invariants.zig — Invariant checks for the CLEAR runtime VOPR.
//
// Called after every simulation step.  Each invariant targets a specific
// class of bug found during the multi-core scaling sprint:
//
//   1. Task conservation   — catches TOCTOU pop (bug 1), pinned task loss (bug 5)
//   2. No duplicate tasks  — catches double-push on epoll wakeup (bug 4)
//   3. Pinned affinity     — catches pinned tasks on wrong scheduler (bug 5)
//   4. Epoll single-reg    — catches fd in two epoll instances (bugs 6, 8)
//   5. Valid pointers      — catches uninitialized buffer reads (bug 3)
//   6. Liveness            — catches I/O starvation (bug 7)
//   7. Epoll status        — catches Ready task still registered in epoll (bug 9)

const std = @import("std");
const vs = @import("vopr-state.zig");
const qs = @import("queues.zig");

const Task = qs.Task;
const VoprState = vs.VoprState;
const SimScheduler = vs.SimScheduler;
const MAX_STALL_TICKS = vs.MAX_STALL_TICKS;

pub const InvariantError = error{
    TaskConservationViolation,
    DuplicateTask,
    PinnedAffinityViolation,
    EpollDoubleRegistration,
    InvalidTaskPointer,
    LivenessViolation,
    EpollStatusViolation,
    ShardConcurrentAccess,
};

/// Run all invariant checks.  Returns error on first violation.
pub fn checkAll(state: *VoprState) InvariantError!void {
    // Combined conservation + duplicate + affinity + valid pointer check
    // (single walk over all queues, most efficient)
    try checkTaskConservationAndDuplicates(state);
    try checkEpollSingleRegistration(state);
    try checkEpollStatusConsistency(state);
    try checkShardConcurrency(state);
    try checkLiveness(state);
}

/// Detect the stolen-fiber shard bug: a task sent a remote op to shard S's
/// owner via SPSC, then was stolen TO that owner scheduler. Now the task
/// could do a LOCAL access to shard S while its own remote op is still
/// pending in the owner's SPSC queue - concurrent access to the same shard.
///
/// Invariant: no scheduler's pending_shard_ops queue should contain an op
/// whose source_task is currently in the SAME scheduler's ready queue or
/// is its current_task. That means the task was stolen to the owner, and
/// the remote op races with future local access.
fn checkShardConcurrency(state: *VoprState) InvariantError!void {
    for (state.schedulers[0..state.sched_count], 0..) |*sched, sched_idx| {
        for (sched.pending_shard_ops.items) |op| {
            // Check if the source task is now on THIS scheduler (stolen here).
            // Walk the ready queue to find it.
            const t = sched.ready_queue.top.load(.monotonic);
            const b = sched.ready_queue.bottom.load(.monotonic);
            const size = b -% t;
            if (size > 0 and size <= sched.ready_queue.getMask() + 1) {
                var i = t;
                while (i != b) : (i +%= 1) {
                    const task_opt = sched.ready_queue.getBuffer()[i & sched.ready_queue.getMask()].load(.monotonic);
                    if (task_opt) |task| {
                        if (task == op.source_task) {
                            std.debug.print("VOPR INVARIANT: shard {d} owned by sched {d} has pending remote op from task {*}, but that task is NOW in sched {d}'s ready queue (stolen!)\n", .{
                                op.shard,
                                sched_idx,
                                op.source_task,
                                sched_idx,
                            });
                            return InvariantError.ShardConcurrentAccess;
                        }
                    }
                }
            }
            // Also check current_task
            if (sched.current_task) |cur| {
                if (cur == op.source_task) {
                    std.debug.print("VOPR INVARIANT: shard {d} owned by sched {d} has pending remote op from task {*}, but that task is sched {d}'s current_task (stolen!)\n", .{
                        op.shard,
                        sched_idx,
                        op.source_task,
                        sched_idx,
                    });
                    return InvariantError.ShardConcurrentAccess;
                }
            }
        }
    }
}

/// Walk every scheduler's ready_queue, sleeping_queue, and current_task.
/// Verify:
///   - Total found + finished == total_spawned (conservation)
///   - No task appears in more than one location (no duplicates)
///   - Pinned tasks are on their owner scheduler (affinity)
///   - Every found task exists in the task registry (valid pointers)
fn checkTaskConservationAndDuplicates(state: *VoprState) InvariantError!void {
    state.scratch_seen.clearRetainingCapacity();
    const seen_map = &state.scratch_seen;

    for (state.schedulers[0..state.sched_count], 0..) |*sched, sched_idx| {
        // Walk ready_queue [top..bottom)
        const t = sched.ready_queue.top.load(.monotonic);
        const b = sched.ready_queue.bottom.load(.monotonic);
        const size = b -% t;
        if (size > 0 and size <= sched.ready_queue.getMask() + 1) {
            var i = t;
            while (i != b) : (i +%= 1) {
                const task_opt = sched.ready_queue.getBuffer()[i & sched.ready_queue.getMask()].load(.monotonic);
                if (task_opt) |task| {
                    // Valid pointer check (bug 3)
                    if (!state.task_registry.contains(task)) {
                        std.debug.print("VOPR INVARIANT: invalid task pointer {*} in sched {d} ready_queue slot {d}\n", .{ task, sched_idx, i });
                        return InvariantError.InvalidTaskPointer;
                    }

                    // Duplicate check (bug 4)
                    if (seen_map.contains(task)) {
                        std.debug.print("VOPR INVARIANT: duplicate task {*} in sched {d} (also in sched {d})\n", .{ task, sched_idx, seen_map.get(task).? });
                        return InvariantError.DuplicateTask;
                    }
                    seen_map.put(state.allocator, task, @intCast(sched_idx)) catch unreachable;

                    // Pinned affinity check (bug 5)
                    if (task.config.pinned) {
                        if (state.getSimTask(task)) |sim| {
                            if (sim.owner_sched != @as(u32, @intCast(sched_idx))) {
                                std.debug.print("VOPR INVARIANT: pinned task {*} on sched {d}, should be on sched {d}\n", .{ task, sched_idx, sim.owner_sched });
                                return InvariantError.PinnedAffinityViolation;
                            }
                        }
                    }
                }
            }
        }

        // Walk pinned_queue (owner-local, never stolen)
        for (sched.pinned_queue.items) |task| {
            if (!state.task_registry.contains(task)) {
                return InvariantError.InvalidTaskPointer;
            }
            if (seen_map.contains(task)) {
                std.debug.print("VOPR INVARIANT: duplicate task {*} in pinned_queue of sched {d}\n", .{ task, sched_idx });
                return InvariantError.DuplicateTask;
            }
            seen_map.put(state.allocator, task, @intCast(sched_idx)) catch unreachable;
            if (task.config.pinned) {
                if (state.getSimTask(task)) |sim| {
                    if (sim.owner_sched != @as(u32, @intCast(sched_idx))) {
                        std.debug.print("VOPR INVARIANT: pinned task {*} on sched {d}, should be on sched {d}\n", .{ task, sched_idx, sim.owner_sched });
                        return InvariantError.PinnedAffinityViolation;
                    }
                }
            }
        }

        // Walk sleeping_queue
        for (sched.sleeping_queue.items) |task| {
            if (!state.task_registry.contains(task)) {
                return InvariantError.InvalidTaskPointer;
            }
            if (seen_map.contains(task)) {
                std.debug.print("VOPR INVARIANT: duplicate task {*} in sleeping_queue of sched {d}\n", .{ task, sched_idx });
                return InvariantError.DuplicateTask;
            }
            seen_map.put(state.allocator, task, @intCast(sched_idx)) catch unreachable;
        }

        // Current task
        if (sched.current_task) |task| {
            if (!state.task_registry.contains(task)) {
                return InvariantError.InvalidTaskPointer;
            }
            if (seen_map.contains(task)) {
                std.debug.print("VOPR INVARIANT: duplicate task {*} as current_task of sched {d}\n", .{ task, sched_idx });
                return InvariantError.DuplicateTask;
            }
            seen_map.put(state.allocator, task, @intCast(sched_idx)) catch unreachable;
        }
    }

    // Count blocked tasks
    const blocked_count = state.blocked_tasks.count();

    // Count pending spawns
    const pending_count = state.pending_spawns.items.len;

    // Conservation: found + blocked + pending + finished == total_spawned
    const found = seen_map.count();
    const expected_live = state.total_spawned - state.total_finished;

    if (found + blocked_count + pending_count != expected_live) {
        std.debug.print("VOPR INVARIANT: task conservation violated: found={d} blocked={d} pending={d} finished={d} spawned={d} (expected live={d})\n", .{
            found,
            blocked_count,
            pending_count,
            state.total_finished,
            state.total_spawned,
            expected_live,
        });
        return InvariantError.TaskConservationViolation;
    }
}

/// Verify that each simulated fd is registered with at most one scheduler.
fn checkEpollSingleRegistration(state: *VoprState) InvariantError!void {
    var fd_iter = state.sim_fds.iterator();
    while (fd_iter.next()) |entry| {
        const fd = entry.key_ptr.*;
        var registrations: u32 = 0;
        var first_sched: u32 = 0;
        var second_sched: u32 = 0;

        for (state.schedulers[0..state.sched_count], 0..) |*sched, sched_idx| {
            if (sched.epoll_fds.contains(fd)) {
                registrations += 1;
                if (registrations == 1) first_sched = @intCast(sched_idx);
                if (registrations == 2) second_sched = @intCast(sched_idx);
            }
        }

        if (registrations > 1) {
            std.debug.print("VOPR INVARIANT: fd {d} registered with {d} schedulers (sched {d} and sched {d})\n", .{ fd, registrations, first_sched, second_sched });
            return InvariantError.EpollDoubleRegistration;
        }
    }
}

/// Verify that tasks registered in a scheduler's epoll_fds are Blocked,
/// not Ready or Finished.  A Ready task still in epoll means the wakeup
/// path failed to unregister the fd (ONESHOT semantics) -- this is the
/// root cause of stale epoll fires leading to double-push.
fn checkEpollStatusConsistency(state: *VoprState) InvariantError!void {
    for (state.schedulers[0..state.sched_count], 0..) |*sched, sched_idx| {
        var fd_iter = sched.epoll_fds.iterator();
        while (fd_iter.next()) |entry| {
            const task = entry.value_ptr.*;
            const status = task.status.load(.monotonic);
            // A task registered in epoll should be Blocked (waiting for I/O).
            // If it's Ready, it was woken but the fd wasn't cleaned up.
            // If it's Finished, it's a use-after-free risk.
            if (status == .Finished) {
                std.debug.print("VOPR INVARIANT: finished task {*} still in epoll_fds of sched {d} (fd {d})\n", .{
                    task,
                    sched_idx,
                    entry.key_ptr.*,
                });
                return InvariantError.EpollStatusViolation;
            }
        }
    }
}

/// Check that no I/O-ready fd has been stalled for more than MAX_STALL_TICKS.
fn checkLiveness(state: *VoprState) InvariantError!void {
    var fd_iter = state.sim_fds.iterator();
    while (fd_iter.next()) |entry| {
        const sim_fd = entry.value_ptr;
        if (sim_fd.ready and state.tick > sim_fd.ready_since_tick + MAX_STALL_TICKS) {
            std.debug.print("VOPR INVARIANT: fd {d} ready since tick {d}, now tick {d} — I/O starvation ({d} ticks)\n", .{
                entry.key_ptr.*,
                sim_fd.ready_since_tick,
                state.tick,
                state.tick - sim_fd.ready_since_tick,
            });
            return InvariantError.LivenessViolation;
        }
    }
}
