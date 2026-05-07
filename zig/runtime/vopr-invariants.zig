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
    /// A *Task that was already destroyed (slab slot returned by
    /// run()'s .Finished branch in scheduler.zig) is still reachable
    /// from some scheduler queue, inbox, or current_task field.
    /// Dereferencing it in production reads slab free-list metadata
    /// (often a `0x7fff…` next-pointer) and SEGVs at e.g. the
    /// `destroy(task.base)` line in run(). Bug shape: a wakeNext /
    /// wg.done / stream-wake captures `*Task` and calls
    /// `sched.submitResume(task)` after the task was finished+
    /// destroyed by its owner -- submitResume has no generation
    /// check, so it pushes the dangling pointer into the target
    /// scheduler's ring or ready_queue.
    DestroyedTaskReferenced,
};

/// Run all invariant checks.  Returns error on first violation.
/// DestroyedTaskReferenced runs first because it gives the most-specific
/// diagnosis for the cross-scheduler-submitResume-after-Finished bug
/// class; the conservation check would otherwise fire for the same
/// state with a less actionable message.
pub fn checkAll(state: *VoprState) InvariantError!void {
    try checkNoDestroyedReferences(state, true);
    // Combined conservation + duplicate + affinity + valid pointer check
    // (single walk over all queues, most efficient)
    try checkTaskConservationAndDuplicates(state);
    try checkEpollSingleRegistration(state);
    try checkEpollStatusConsistency(state);
    try checkShardConcurrencyImpl(state, true);
    try checkLiveness(state);
}

/// Silent variant for negative tests that intentionally construct an invalid
/// state and only need the returned error, not the invariant diagnostic.
pub fn checkAllSilent(state: *VoprState) InvariantError!void {
    try checkNoDestroyedReferences(state, false);
    try checkTaskConservationAndDuplicates(state);
    try checkEpollSingleRegistration(state);
    try checkEpollStatusConsistency(state);
    try checkShardConcurrencyImpl(state, false);
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
fn checkShardConcurrencyImpl(state: *VoprState, print_diagnostic: bool) InvariantError!void {
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
                            if (print_diagnostic) {
                                std.debug.print("VOPR INVARIANT: shard {d} owned by sched {d} has pending remote op from task {*}, but that task is NOW in sched {d}'s ready queue (stolen!)\n", .{
                                    op.shard,
                                    sched_idx,
                                    op.source_task,
                                    sched_idx,
                                });
                            }
                            return InvariantError.ShardConcurrentAccess;
                        }
                    }
                }
            }
            // Also check current_task
            if (sched.current_task) |cur| {
                if (cur == op.source_task) {
                    if (print_diagnostic) {
                        std.debug.print("VOPR INVARIANT: shard {d} owned by sched {d} has pending remote op from task {*}, but that task is sched {d}'s current_task (stolen!)\n", .{
                            op.shard,
                            sched_idx,
                            op.source_task,
                            sched_idx,
                        });
                    }
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

                    // Pinned affinity check (bug 5).
                    // Skip for temporarily-pinned tasks (pinned_for_remote) --
                    // they're pinned to prevent stealing, not for scheduler affinity.
                    if (task.config.pinned) {
                        if (state.getSimTask(task)) |sim| {
                            if (sim.pending_remote_count == 0 and sim.owner_sched != @as(u32, @intCast(sched_idx))) {
                                std.debug.print("VOPR INVARIANT: pinned task {*} on sched {d}, should be on sched {d}\n", .{ task, sched_idx, sim.owner_sched });
                                return InvariantError.PinnedAffinityViolation;
                            }
                        }
                    }
                }
            }
        }

        // Walk pinned_queue (owner-local for permanent pins; may contain
        // temporarily-pinned tasks from sendAndWait steal guard)
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
                    if (sim.pending_remote_count == 0 and sim.owner_sched != @as(u32, @intCast(sched_idx))) {
                        std.debug.print("VOPR INVARIANT: pinned task {*} on sched {d}, should be on sched {d}\n", .{ task, sched_idx, sim.owner_sched });
                        return InvariantError.PinnedAffinityViolation;
                    }
                }
            }
        }

        // Walk resume_inbox (cross-scheduler submitResume model;
        // mirrors production SPSC ring + same-scheduler fast path).
        for (sched.resume_inbox.items) |task| {
            if (!state.task_registry.contains(task)) {
                std.debug.print("VOPR INVARIANT: invalid task pointer {*} in resume_inbox of sched {d}\n", .{ task, sched_idx });
                return InvariantError.InvalidTaskPointer;
            }
            if (seen_map.contains(task)) {
                std.debug.print("VOPR INVARIANT: duplicate task {*} in resume_inbox of sched {d}\n", .{ task, sched_idx });
                return InvariantError.DuplicateTask;
            }
            seen_map.put(state.allocator, task, @intCast(sched_idx)) catch unreachable;
        }

        // Walk yield_queue (cooperative-yield FIFO; mirrors production
        // Scheduler.yield_queue). Tasks here are owner-local and never
        // stolen, so they can't appear in any other scheduler's queues.
        for (sched.yield_queue.items) |task| {
            if (!state.task_registry.contains(task)) {
                std.debug.print("VOPR INVARIANT: invalid task pointer {*} in yield_queue of sched {d}\n", .{ task, sched_idx });
                return InvariantError.InvalidTaskPointer;
            }
            if (seen_map.contains(task)) {
                std.debug.print("VOPR INVARIANT: duplicate task {*} in yield_queue of sched {d}\n", .{ task, sched_idx });
                return InvariantError.DuplicateTask;
            }
            seen_map.put(state.allocator, task, @intCast(sched_idx)) catch unreachable;
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
            if (sched.poll_fds.contains(fd)) {
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
        var fd_iter = sched.poll_fds.iterator();
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
/// Walk every queue, inbox, and current_task field. Any *Task whose
/// SimTask.destroyed=true represents a dangling pointer in production —
/// dereferencing it in the .Finished destroy sequence (or in
/// drainChannels' Resume tag) reads slab free-list metadata and SEGVs.
/// This catches the cross-scheduler submitResume-after-Finished class
/// of UAF that the SplitStream pubsub hammer surfaces statistically.
fn checkNoDestroyedReferences(state: *VoprState, print_diagnostic: bool) InvariantError!void {
    for (state.schedulers[0..state.sched_count], 0..) |*sched, sched_idx| {
        // ready_queue (Chase-Lev) — walk [top..bottom)
        const t = sched.ready_queue.top.load(.monotonic);
        const b = sched.ready_queue.bottom.load(.monotonic);
        const size = b -% t;
        if (size > 0 and size <= sched.ready_queue.getMask() + 1) {
            var i = t;
            while (i != b) : (i +%= 1) {
                if (sched.ready_queue.getBuffer()[i & sched.ready_queue.getMask()].load(.monotonic)) |task| {
                    if (state.getSimTask(task)) |sim| if (sim.destroyed) {
                        if (print_diagnostic) std.debug.print(
                            "VOPR INVARIANT: destroyed task {*} still in sched {d} ready_queue slot {d}\n",
                            .{ task, sched_idx, i },
                        );
                        return InvariantError.DestroyedTaskReferenced;
                    };
                }
            }
        }
        // pinned_queue
        for (sched.pinned_queue.items) |task| {
            if (state.getSimTask(task)) |sim| if (sim.destroyed) {
                if (print_diagnostic) std.debug.print(
                    "VOPR INVARIANT: destroyed task {*} still in sched {d} pinned_queue\n",
                    .{ task, sched_idx },
                );
                return InvariantError.DestroyedTaskReferenced;
            };
        }
        // yield_queue (cooperative-yield FIFO)
        for (sched.yield_queue.items) |task| {
            if (state.getSimTask(task)) |sim| if (sim.destroyed) {
                if (print_diagnostic) std.debug.print(
                    "VOPR INVARIANT: destroyed task {*} still in sched {d} yield_queue\n",
                    .{ task, sched_idx },
                );
                return InvariantError.DestroyedTaskReferenced;
            };
        }
        // resume_inbox (cross-scheduler submitResume model)
        for (sched.resume_inbox.items) |task| {
            if (state.getSimTask(task)) |sim| if (sim.destroyed) {
                if (print_diagnostic) std.debug.print(
                    "VOPR INVARIANT: destroyed task {*} still in sched {d} resume_inbox -- submitResume captured a stale *Task across the .Finished destroy\n",
                    .{ task, sched_idx },
                );
                return InvariantError.DestroyedTaskReferenced;
            };
        }
        // sleeping_queue
        for (sched.sleeping_queue.items) |task| {
            if (state.getSimTask(task)) |sim| if (sim.destroyed) {
                if (print_diagnostic) std.debug.print(
                    "VOPR INVARIANT: destroyed task {*} still in sched {d} sleeping_queue\n",
                    .{ task, sched_idx },
                );
                return InvariantError.DestroyedTaskReferenced;
            };
        }
        // current_task
        if (sched.current_task) |task| {
            if (state.getSimTask(task)) |sim| if (sim.destroyed) {
                if (print_diagnostic) std.debug.print(
                    "VOPR INVARIANT: destroyed task {*} is sched {d} current_task\n",
                    .{ task, sched_idx },
                );
                return InvariantError.DestroyedTaskReferenced;
            };
        }
    }
}

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
