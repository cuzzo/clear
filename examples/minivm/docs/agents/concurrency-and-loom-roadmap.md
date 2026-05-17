# Register VM: Concurrency Benchmarks + Automatic Interleaving Roadmap

Goal: take the register VM from "single-threaded, BG/CONCURRENT/DO
inlined synchronously" to a state where we can (A) **compare the VM
on `benchmarks/concurrent/*`** against the sibling languages, and (B)
**automatically interleave threaded workloads for debugging** — the
README's stated primary purpose ("auto-generating loom tests from
CLEAR programs").

This is a NEW doc tree (`examples/minivm/docs/agents/`). Cross-refs:
`docs/agents/bc-fibers.md` (synchronous-BG simplification + Phase A),
`docs/agents/register-vm.md` (VM design), `docs/agents/vm-bugs.md`
(OPEN frame-arena bug), `docs/agents/parking-lot-loom-coverage.md`
(loom coverage model), `docs/agents/register-error-union.md`
(error-union arc), `CLAUDE.md` (Concurrency Review Requirements).

## Where we are (verified 2026-05-17)

- Register allowlist 245/245 green; error-union / cap-param /
  WITH POLYMORPHIC / OR PASS all landed.
- `register_bc_emitter.rb`: `@bg_mode = :inline` (BG bodies inlined
  synchronously; FSM transform skipped for `:bc`); `NEXT` is a
  pass-through; `@bg_dispatch_points` is recorded but **no scheduler
  consumes it**. Faithful only for order-independent pure compute.
- `vm.cht`: time-travel trace infra exists — `recordingActive`,
  `TraceEvent[]` with kind 1=ireg / 2=freg / 3=sreg / 4=container
  alloc, consumed by `register_debugger.cht`'s `registerDebugPause!`
  (step/reverse). It records ONE linear single-fiber stream.
- Benchmarks: `benchmarks/vm/*` (20 sequential micro-benchmarks,
  `register-benchmark-allowlist.txt`, `./clear bench --vm=register`
  via `bench_vm.rb`). `benchmarks/concurrent/01..10` exist
  (socket_throughput, concurrent_search, atomic_contention,
  fanout_fanin, backpressure, dynamic_spawn, stream_merge, pubsub,
  kvstore, shard_vs_locked) — **not runnable** on the register VM.
- The runner (`vm.cht`) itself runs on real Zig fibers / `Locked<T>`
  / `sleep`, so the gap is the BC's deliberate synchronous-BG choice,
  not runtime capability (per `bc-fibers.md`).

## Hard prerequisite

**P0. Land the faithful guest frame-arena fix** (OPEN in
`docs/agents/vm-bugs.md`). Concurrent benchmarks allocate heavily and
per-fiber; the `--stack-check` tier coincidence that currently masks
the bug WILL flip under multi-fiber frames and produce corruption
(`0xAAAA` / integer-overflow panics). Trustworthy concurrent numbers
and reproducible interleavings are impossible while this is open.
Model a guest arena distinct from the runner's, with per-fiber
save/restore. No concurrent work below is sound until P0 lands.

## Invariants (apply to every item)

- Runtime-faithful: guest `Locked`/`Arc`/atomic/`BG`/`NEXT`/streams
  must execute through the **real** Zig runtime constructs the
  compiled CLEAR uses (README core principle). No shadow scheduler
  that bypasses the runtime contract being measured.
- Structured MIR only; never parse Zig (`CLAUDE.md`). The FSM/CPS
  lowering is ONE general transform — never a per-shape emitter
  (`CLAUDE.md` FSM rule; `docs/agents/fsm-universal-transform.md`).
- Any atomics/locks/threads added → Loom + Hammer tests; retries/
  timeouts → VOPR; all green before integration (`CLAUDE.md`
  Concurrency Review Requirements; memory:
  feedback-concurrent-runtime-testing).
- Every step is one commit, verified against the full register
  allowlist at zero regressions before the next.

---

## Phase 1 — Real BG fibers + scheduler (items 1-6)

Replaces synchronous inline BG with an actual cooperative scheduler.
Foundation for BOTH goals.

1. **Multi-fiber trace model.** Extend `TraceEvent` with `fiber_id`
   and a global monotonic `seq` (keep per-fiber `step`). Update the
   recording arms and `register_debugger.cht` to key on `(fiber_id,
   step)`. Pure data-model change; single-fiber behavior unchanged
   (fiber_id=0). Unblocks every later item.

2. **Suspendable BG lowering for `:bc`.** Stop skipping the FSM
   transform for the BG/stream path; lower BG bodies through the ONE
   universal CPS transform (segment-split at suspend points:
   spawn, NEXT/join, lock acquire, yield, sleep). Emit a structured
   `MIR`-level fiber-segment table — no per-shape emitter, no Zig
   text. Gate behind `@bg_mode = :fiber` (keep `:inline` default
   until item 5 is solid).

3. **Fiber/Future value-kind + real spawn.** `BG { body }` →
   allocate a fiber on the real runtime (`rt.spawnFiber`-backed, the
   `BG_SPAWN` site in `bc-fibers.md` Phase A) returning a Future
   value-kind. The body runs as a scheduled segment, not inline.

4. **Joining `NEXT`.** Replace pass-through `NEXT` with a real join:
   block the caller fiber until the awaited Future/segment completes;
   yield to the scheduler meanwhile. Faithful FIFO spawn-order
   semantics (matches compiled CLEAR).

5. **Cooperative scheduler loop in `vm.cht`.** Ready-queue of fiber
   states (ip, iBase/fBase, frame stacks, regs view); run-to-next-
   suspend; resume. Suspend points: spawn, join, lock acquire/
   release, yield, sleep. Default policy = deterministic FIFO so
   existing inline-equivalent tests still pass. Loom + Hammer +
   VOPR tests for the scheduler itself (CLAUDE.md).

6. **Real `Locked`/`Arc`/atomic on the concurrent path.** Route
   guest cap-wrapped lock acquire/release and atomics through the
   actual runtime `Locked<T>` / atomics (the runner has them), not
   the single-threaded no-op, whenever `@bg_mode = :fiber`. Keep the
   no-op only for the inline path. This is what makes contention
   benchmarks and races real. Unblocks `263_with_lock_contention`
   (the one test `bc-fibers.md` flags).

## Phase 2 — Concurrent benchmark comparability (items 7-10)

7. **`register-concurrent-benchmark-allowlist.txt` + runner wiring.**
   Teach `bench_vm.rb` / `./clear bench --vm=register` to run
   `benchmarks/concurrent/*` with sibling-language timings (the
   `benchmarks/runner.rb --concurrent` corpus already has Rust/Go/
   etc. siblings). Pending cases recorded, not crashed.

8. **Land the tractable concurrent benchmarks.** Target the
   compute/sync-bound ones first: `03_atomic_contention`,
   `09_kvstore`, `10_shard_vs_locked`, `04_fanout_fanin`,
   `02_concurrent_search`. Classify network/socket ones
   (`01_socket_throughput`, `05_backpressure`, `08_pubsub`) as
   out-of-scope or stub the IO boundary; document which.

9. **Deterministic bench mode.** A fixed scheduler policy + seed for
   benchmark runs so wall-time and `BENCH_RESULT` numbers are stable
   and comparable run-to-run. Record contention metrics (lock
   acquire count, wait time, fiber switches) alongside timing.

10. **Concurrent-bench correctness + CI gate.** Assert each
    benchmark's invariant result (e.g. kvstore final state, atomic
    counter total) under `--vm=register`; ratchet a
    `--min-pass`-style gate over the concurrent allowlist, same
    pattern as the transpile allowlist.

## Phase 3 — Automatic interleaving for debugging (items 11-16)

The README's primary purpose: auto-generate loom tests from CLEAR
programs by exploring schedules.

11. **Scheduling-point instrumentation.** Promote
    `@bg_dispatch_points` (and every shared-memory access / lock op
    / atomic / spawn/join boundary) to real per-op scheduling points
    recorded in the multi-fiber trace. This is the set of points the
    explorer may preempt at.

12. **Pluggable scheduler policy.** Interface with three policies:
    `sequential` (default, = today's behavior), `random(seed)`
    (seeded fuzzing), `dpor` (dynamic partial-order reduction for
    bounded exhaustive enumeration). Selected via env / `--loom`.

13. **Happens-before graph + race detection.** Per-fiber event
    streams with vector clocks; HB edges from lock acquire/release
    and spawn/join. Flag a data race when two events on the same
    slot/container from different fibers are HB-unordered. Builds on
    item 1's trace model.

14. **Deterministic interleaving replay + DPOR enumeration.** Given
    a schedule (seed or explicit), replay exactly one interleaving
    deterministically (reuse the time-travel infra in
    `register_debugger.cht`). DPOR enumerates distinct interleavings
    while pruning equivalent ones; depth/iteration budget caps the
    explosion.

15. **Divergence / assertion oracle.** Detect when distinct
    interleavings of the same program produce different observable
    output, hit a data race, or fail an `ASSERT`. That tuple
    (program, schedule, divergence) is the bug witness.

16. **Auto-generate the loom test.** Emit a minimized, replayable
    loom test (the project's loom harness shape; see
    `docs/agents/parking-lot-loom-coverage.md`) capturing the
    racing schedule + expected vs actual, so the discovered race
    becomes a permanent regression. This closes the README's
    "auto-generating loom tests from CLEAR programs" loop.

## Phase 4 — Hardening + integration (items 17-20)

17. **Scheduler self-verification.** Loom + Hammer + VOPR over the
    scheduler/explorer itself (it IS new concurrency machinery —
    CLAUDE.md mandate). TSan/ASan on the runner.

18. **State-space bounding + coverage report.** `--loom-budget`
    (max interleavings / depth); coverage output in the
    `parking-lot-loom-coverage.md` style (schedules explored,
    points covered, races found).

19. **`run_tests.rb --loom` + allowlist + CI smoke.** A
    register-loom allowlist of small concurrent CLEAR programs with
    known race/no-race expectations; CI smoke at a small budget so
    regressions in the explorer are caught.

20. **Worked example + docs.** Take one `benchmarks/concurrent`
    case (e.g. `10_shard_vs_locked`), inject a known race, show the
    explorer finding it and emitting the loom test; document the
    end-to-end flow here and in `register-vm.md`.

## Sequencing notes

- **P0 (frame-arena) is non-negotiable and first.** Everything
  below allocates per-fiber.
- Items 1-6 are strictly ordered (each depends on the prior).
- Phase 2 (benchmarks) and Phase 3 (interleaving) both sit on the
  Phase 1 scheduler and can proceed in parallel after item 6, but
  item 1's multi-fiber trace is shared infrastructure for both —
  do it first.
- Keep `@bg_mode = :inline` as the default and fully working until
  item 5's scheduler passes the full allowlist at zero regressions;
  flip the default only then. The inline path stays as the fast
  faithful-for-pure-compute mode.
- Risk: items 2-5 are the largest (real scheduler + CPS lowering).
  Land each behind the `:fiber` mode flag, verify the allowlist
  stays 245/245 under `:inline`, and grow a separate `:fiber`
  allowlist tranche so a half-built scheduler never gates CI.
