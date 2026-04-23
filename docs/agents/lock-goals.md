# Lock Safety Goals

Static analysis phases (Phase 1–3) already emit compile-time diagnostics for
nested-lock bugs. This document records the longer-term runtime goal: use the
same static data to prove portions of the runtime deadlock-detection machinery
dead, and elide them at those specific sites / for those specific tasks.

**Status:** not implemented. Benchmarks on current workloads show runtime
detection costs in the noise band, so elision is not yet justified. Revisit
when a measured workload makes it worthwhile.

---

## Runtime costs today

Every slow-path lock acquire currently does three things:

| Cost | Where | Magnitude | Who needs it |
|---|---|---|---|
| Re-entrancy self-check | `ParkingMutex.lockSlow` / `ParkingRwLock.lockSlow` | ~1 cycle (compare + branch) | The acquirer |
| Chain walk (`detectCycle`) | same | ~10–60ns; walks up to 64 hops of `task.waiting_for_lock_owner` | The acquirer |
| Park bookkeeping (set + clear `task.waiting_for_lock_owner`) | same | ~2ns (two stores) | EVERY parking task, so walkers anywhere in the program see a complete chain |

The fast (uncontended CAS) path touches none of this.

## Two independent elision axes

### Axis 1 — chain walk, per acquire site

The walk is a property of the SITE that runs it. A WITH block whose lock type
is provably not in a cycle in the global lock-order graph cannot start a
cycle. That site can emit slow-path code that skips `detectCycle` entirely.

Phase 2 already computes the per-type cycle information needed to decide this
per site.

**Precondition to safely elide at a site:**
- The WITH's lock type is not in any SCC in the full (including opted-out)
  lock-order graph.
- The site does not carry `POSSIBLE_DEADLOCK` / `POSSIBLE_LOCK_CYCLE`
  (opt-outs say "might cycle at runtime").

### Axis 2 — park bookkeeping, per task

The `waiting_for_lock_owner` field on a task is READ by other tasks' chain
walkers. A task's bookkeeping is dead iff the task can never appear as a
*middle link* in a cycle chain — i.e., the task never holds one lock while
parking on another.

This is per-fiber-entry-function analysis, equivalent to "does this
function, or any transitive callee, have a held-during-acquire site?" The
Phase 2 fixed-point already computes `nested_pairs` and `held_calls` per
function — one more propagated bit (`lock_chain_link_possible`) gives the
answer.

**Precondition to safely elide bookkeeping on a task:**
- The task's entry FN, transitively, has zero held-during-acquire sites
  (direct nested-WITH or `held_calls` into fns that themselves acquire).
- No opt-outs on any reachable path (opt-outs taint the entire reachable
  graph).
- No FFI / fn-pointer escapes (opaque edges force worst-case assumption).

**Correctness argument:** a walker reading a bookkeeping-off task's
`waiting_for_lock_owner` sees `null` (default), which terminates the walk.
That is the truthful answer because by construction the task cannot be a
middle link. No false negatives.

### What adding one risky site does

The axes have different blast radii for local edits:

| Change | Axis 1 impact (walk) | Axis 2 impact (bookkeeping) |
|---|---|---|
| Add `WITH EXCLUSIVE T { f() }` where `f` takes another lock `U` | This site now needs a walk; other sites on unrelated types unaffected. | Tasks whose entry fn reaches this site lose their bookkeeping elision. Tasks that don't reach it are unaffected. |
| Add a `POSSIBLE_DEADLOCK` | Same as above — scope confined to the sites that participate. | Tasks reaching the opt-out keep bookkeeping. Others don't. |
| Add an FFI call inside a held scope | Forces walk (worst-case). | Forces bookkeeping on the calling task. |

Per-task / per-site granularity is the right blast-radius story. Program-wide
elision is attractive until one `POSSIBLE_DEADLOCK` quietly flips the whole
binary's lock behavior — that's a non-local side effect and should be avoided.

## What already exists

- Phase 1 — lexical same-name nested-WITH rejection (`src/annotator-helpers/lock_helper.rb`, `check_nested_lock_reacquire!`).
- Phase 2 — per-fn `lock_direct_edges`, `lock_direct_acquires`, `lock_held_calls`; fixed-point `propagate_lock_acquires!`; Tarjan SCC in `check_lock_cycles!`. All the per-site data the elision analyses need is already collected.
- Phase 3 — `@locked(rank: N)` / `@writeLocked(rank: N)` with strict-ascending acquire rule; proves cycle-freedom by construction for fully-ranked subsystems.
- Handler reachability — `ON :LockCycle` / `ON :Deadlock` is rejected as dead code unless the lock graph (including opted-out edges) actually reaches the error type at this WITH.

## What's still to do

1. **`lock_chain_link_possible` propagation.** One more bit through the Phase 2 fixed-point; per-fn answer to "can this fn, or any callee, be a middle link?" Cheap to add; foundation for axis 2.
2. **`can_start_cycle_at(site)` flag.** Per-WITH derived from the non-opted lock-order graph after SCC. Foundation for axis 1.
3. **Runtime opt-in elision.**
   - Axis 1: codegen emits two slow-path variants per acquire site — with and without `detectCycle` — gated by the site flag.
   - Axis 2: Task field `track_lock_waits: bool` set at spawn from the entry fn's flag; `lockSlow` guards the `waiting_for_lock_owner` stores behind it.
4. **Measurement gate.** Only flip the switch if there's a workload where the savings are demonstrably out of noise.

## Why we haven't done it yet

Benchmark (`zig build bench-locks -Doptimize=ReleaseFast`) with the flag
toggled shows the total elision saves less than measurement noise (~0–1%)
across the contention matrix (Mutex + RwLock, uncontended / heavy /
realistic / long-held, 3 access patterns). The savings hide behind park /
yield / wake costs, which are microseconds, dominating the tens of
nanoseconds of detection code.

Per your rule: **any risk of missing a real deadlock outweighs noise-level
perf gains**. Keep detection unconditional until v0.2, then revisit with a
measured case in hand.
