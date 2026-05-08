# VOPR Coverage Audit

Single source of truth for the VOPR-coverage system: scanner, scoring,
build pipeline, retry markers, deterministic shims, regression gates,
and where the remaining gaps are. Loom and VOPR target orthogonal axes
(see "Loom vs VOPR" below) — this document is the VOPR side.

## Loom vs VOPR

- **Loom** exhausts atomic-op interleavings. SimAtomic forces a yield
  point at every atomic op; the harness drives every possible ordering.
  Atomics ARE Loom's job — VOPR should not duplicate that work.

- **VOPR** runs a single deterministic seed end-to-end against a
  simulator. It exists to make non-deterministic axes (clock, random,
  network IO, filesystem IO, retries) reproducible. A failure under
  seed N can be replayed exactly.

The two converge on retry-loop coverage: Loom wins ordering races, VOPR
drives bounded-retry exhaustion via fault injection. Today VOPR's retry
side is mostly entry-only — the loop body executes once and the outer
iteration count never advances unless something simulates a CAS miss.
That's open work (see "Open gaps" below).

## What gets scanned

`src/tools/vopr_coverage.rb` walks `zig/runtime` + `zig/lib` and
classifies every line into one of six categories via grep-style
patterns:

| Category     | Pattern source                                      |
|---           |---                                                  |
| `time`       | `std.time.{milli,nano}Timestamp`, `clock_gettime`, bare `milliTimestamp()` |
| `random`     | `std.crypto.random`, `std.Random`, `getrandom`      |
| `net_io`     | `posix.{recv,send,connect,accept,bind,listen,...}`, `std.net.*`, raw `IoUring.{recv,send,...}` |
| `fs_io`      | `posix.{open,read,write,close,fsync,...}`, `std.fs.*`, raw `IoUring.{read,write,fsync}` |
| `ring_io`    | `self.ring.{read,write,recv,send,accept,...}` — the RingType seam, SimRing-shimmed under VOPR |
| `retry`      | `// VOPR-START-RETRY: <desc>` ... `// VOPR-END-RETRY` block markers, OR `// VOPR-RETRY` single-line marker |
| `retry_body` | Every executable line INSIDE a `// VOPR-START-RETRY` ... `// VOPR-END-RETRY` block. Tracks whether the loop body executed (vs just the loop header). |

Test files are excluded (`*-test.zig`, `vopr*.zig`, `*-loom.zig`,
`*-vopr.zig`) — they're test infrastructure, not production runtime.

## How sites are scored

Sites cross-reference against the cobertura XML produced by
`zig build coverage-vopr -Dcoverage-vopr` (kcov-wrapped runs of every
VOPR executable). Each site falls into one of:

- **hit**: kcov reports >0 hits at this line.
- **0-hit**: line is instrumented but never executed under VOPR.
- **LINE MISSING**: file IS loaded into kcov but this line has no
  entry — usually the inliner elided it. Functions reached via inlined
  call sites count this way.
- **FILE NOT LOADED**: file is not loaded by ANY VOPR executable. The
  surface isn't even in scope of the current suite.

Retry markers (`// VOPR-START-RETRY: ...`) are comment lines that kcov
doesn't instrument; the scanner attributes them to the FIRST
instrumented line at-or-after the marker (the loop header).

Run the report:

```
bundle exec ruby src/tools/vopr_coverage.rb               # full per-site report
bundle exec ruby src/tools/vopr_coverage.rb --summary-only
bundle exec ruby src/tools/vopr_coverage.rb --category retry
```

## Build pipeline

`zig build coverage-vopr -Dcoverage-vopr` wraps each VOPR executable
under kcov. Output: `zig-out/coverage-vopr/<exe>/`, merged to
`zig-out/coverage-vopr/merged/kcov-merged/cobertura.xml`. The scanner
reads that file.

Six VOPR executables (all built as `b.addExecutable`, NOT `b.addTest`
— see "GAP-B" below):

| Executable                | Entry file                          | Impl file                                  | Scenarios |
|---                        |---                                  |---                                         |---        |
| `scheduler-timeout-vopr`  | `zig/scheduler-timeout-vopr-test.zig` | `zig/runtime/scheduler-timeout-vopr.zig` | 4 (+gate) |
| `atomic-ptr-vopr`         | `zig/atomic-ptr-vopr-test.zig`        | `zig/runtime/atomic-ptr-vopr.zig`        | 3 (+gate) |
| `versioned-vopr`          | `zig/versioned-vopr-test.zig`         | `zig/runtime/versioned-vopr.zig`         | 4 (+gate) |
| `fsm-lock-vopr`           | `zig/fsm-lock-vopr-test.zig`          | `zig/runtime/fsm-lock-vopr.zig`          | 2 (+gate) |
| `fsm-vopr`                | `zig/fsm-vopr-test.zig`               | `zig/runtime/fsm-vopr.zig`               | 4 (+gate) |
| `vopr-runqueue`           | `zig/vopr-test.zig`                   | `zig/runtime/vopr.zig`                   | 5 (+gate) |

Each entry file has the shape:

```zig
pub const CLEAR_FRAME_DEBUG = false;
pub const SimClock = @import("runtime/vopr-clock.zig").SimClock;
pub const SimRandom = @import("runtime/vopr-random.zig").SimRandom;

const impl = @import("runtime/<name>-vopr.zig");
const gate = @import("runtime/vopr-gate.zig");

const tests = [_]Test{
    .{ .name = "GAP-B gate: ...", .func = &gate.assertGapBActive },
    .{ .name = "...", .func = &impl.testX },
};

pub fn main() !void {
    for (tests) |t| {
        try t.func();
        try impl.checkLeaksAndReset();  // post-test, after defers
    }
}
```

Build wiring is in `zig/build.zig` under the `vopr_exes` array — adding
a new VOPR executable is one entry there plus the two source files.

## GAP-B: the executable shape

`@import("root")` from inside `lib/compat.zig` resolves to whatever
the build step set as the module root. Under `b.addTest`, that's Zig's
auto-generated test_runner module — NOT the test file. So:

```zig
const sim_clock_decl = blk: {
    const root = @import("root");
    break :blk if (@hasDecl(root, "SimClock")) root.SimClock else void;
};
```

silently resolves to `void` under `b.addTest` because test_runner
doesn't re-export `pub const SimClock = ...` from the test file. The
seam falls through to OS clock_gettime. "VOPR-deterministic" tests
become real-clock-dependent without any visible failure.

This is the same regression `parking-lot-loom` documented in 2026-05
(see `docs/agents/parking-lot-loom-coverage.md`). The fix is the same:
build VOPR tests as `b.addExecutable` so root resolves to the entry
file with the `pub const SimClock = ...` decls.

`runtime/vopr-gate.zig` exposes `assertGapBActive()`. Every VOPR
executable runs it as the FIRST scenario:

```
GAP-B gate: SimClock + SimRandom active under this executable ... OK
```

The gate verifies:
1. `SimClock.advanceMs(1234)` moves `compat.milliTimestamp()` by
   exactly 1234 (off by anything → SimClock seam fell through).
2. Same `SimRandom.seed()` produces identical bytes; different seeds
   diverge (OS getrandom would give random bytes regardless of seed).

If a future build refactor accidentally re-introduces `b.addTest` for
a VOPR target, the gate fails immediately on first run — not silently
producing theatre passes.

## Retry markers

Retry loops in production code are marked so the scanner can score
their entry-line hit count. Two conventions:

```zig
// VOPR-START-RETRY: <one-line description of what this retries on>
while (retries < MAX) : (retries += 1) {
    // ...
}
// VOPR-END-RETRY
```

```zig
while (lock.swap(1, .acquire) == 1) std.Thread.yield() catch {}; // VOPR-RETRY
```

29 markers across:

- `versioned.zig` (4) — MVCC update / updateFlow / updateMulti
- `atomic_ptr.zig` (2) — AtomicPtr update / updateFlow
- `scheduler.zig` (6) — WaitGroup.{done,registerFsmWaiter,wait},
  Semaphore.{acquire,release}
- `data-structures.zig` (15) — sharded inner-lock spins
- `observable.zig` (1) — SpinLock CAS acquire
- `queues.zig` (1) — WaiterList spinlock CAS acquire

`parking-lot.zig` retry loops are intentionally NOT marked — they're
covered structurally by Loom, and adding markers would clutter the
report with sites that already have a Loom-side coverage story.

## SimAtomic CAS fault injection

The `retry` markers count loop-header hits but the loop BODY (the
cmpxchg-loser branch with `continue`) needs an actual CAS failure to
execute. Single-thread VOPR can't lose a CAS to itself — there's no
contention. Without help the body lines stay 0-hit even though the
function is called.

`runtime/vopr-atomic.zig` has process-global knobs:

```zig
pub var inject_cas_fault: bool = false;
pub var inject_cas_fault_rate: u32 = 0;  // 0..10000

pub fn seedFault(seed: u64) void;        // seeds the fault PRNG
pub fn resetFault() void;                // called by checkLeaksAndReset
```

When `inject_cas_fault` is true, `cmpxchgStrong` / `cmpxchgWeak` in
SimAtomic check after the equality test: if the value matched, a
SimRandom-seeded PRNG roll converts the success into a synthetic
failure with probability `rate/10000`. The fault count (across all
CAS sites in the program) is exposed as
`sim_cmpxchg_synthetic_fault_count`.

Loom executables (parking-lot-loom, vopr-loom-runner) leave these
flags off, so loom's interleaving suite is unaffected. VOPR
executables that want to drive retry bodies set the flags before
calling the target function and reset them via `resetFault()` (the
checkLeaksAndReset path does this automatically).

VOPR executables that consume fault injection MUST also export
`pub const SimAtomic = ...` at module root so the comptime alias in
the target file (e.g. `lib/atomic_ptr.zig`'s
`Atomic = if (@hasDecl(root, "SimAtomic")) root.SimAtomic else
std.atomic.Value`) picks SimAtomic. Today this is wired for
`atomic-ptr-vopr` and `versioned-vopr`.

Two canonical scenario shapes per fault-injection-aware target:

```zig
// 50% rate, N sequential ops -- proves the retry path eventually
// succeeds and the fault PRNG actually fires.
sim_atomic.seedFault(seed);
sim_atomic.inject_cas_fault = true;
sim_atomic.inject_cas_fault_rate = 5000;
// drive 16 ops, expect total > 0 synthetic faults and final state
// reflects all 16

// 100% rate, single op -- proves the bounded-retry escape hatch.
sim_atomic.inject_cas_fault_rate = 10_000;
// expect MAX_UPDATE_RETRIES synthetic faults and the right error
```

## Deterministic shims

`zig/runtime/vopr-clock.zig` — `SimClock` with `virtual_ns` state and
`reset() / advanceMs() / advanceNs() / milliTimestamp() /
nanoTimestamp()`. Single-thread (matches the runtime's VOPR tests).

`zig/runtime/vopr-random.zig` — `SimRandom` backed by
`std.Random.DefaultPrng` with `seed() / fill()`.

Both wired into `lib/compat.zig` via comptime seams that resolve to
the simulator if root has the decl, else to the OS path:

```zig
const sim_clock_decl = blk: {
    const root = @import("root");
    break :blk if (@hasDecl(root, "SimClock")) root.SimClock else void;
};
pub fn milliTimestamp() i64 {
    if (sim_clock_decl != void) return sim_clock_decl.milliTimestamp();
    // ... clock_gettime fallback ...
}
```

Production builds (no SimClock decl on root) inline the OS path —
zero overhead. The seam check is dead-code-eliminated at the callsite.

## Adding a new VOPR scenario

1. Pick the executable that owns the surface (e.g. timeout work →
   scheduler-timeout-vopr; MVCC work → versioned-vopr).

2. Write `pub fn testX() !void` in the impl file (`runtime/<name>-vopr.zig`).
   Use `compat.milliTimestamp()` for time reads, `compat.randomBytes`
   for entropy. SimClock / SimRandom advance / seed at the top of the
   scenario:

   ```zig
   pub fn testTimeoutMultiTask() !void {
       SimClock.reset();
       SimRandom.seed(12345);
       // ... set up state, advance clock, observe behavior ...
   }
   ```

3. Register in the wrapper's `tests` array.

4. `zig build test-loom-vopr` — the new scenario runs immediately;
   GAP-B gate stays in place.

5. `zig build coverage-vopr -Dcoverage-vopr` to confirm coverage
   delta. The scanner shows which lines moved from 0-hit / FILE NOT
   LOADED to hit.

## Adding a new VOPR executable

If a new lib needs its own test surface:

1. Create `zig/runtime/<lib>-vopr.zig` with the impl pattern (gpa,
   `pub fn checkLeaksAndReset()`, `pub fn testX()` scenarios).
2. Create `zig/<lib>-vopr-test.zig` with the wrapper pattern (root
   decls, tests array, main()).
3. Add to `vopr_exes` in `zig/build.zig`.
4. Done — `coverage-vopr` picks it up automatically.

## Current coverage

As of commit `f255c10e`:

```
Time             16/34  ( 47.1%)
Random            0/4   (  0.0%)
Network IO (raw)  0/1   (  0.0%)
FS IO (raw)       0/25  (  0.0%)
Ring IO           1/10  ( 10.0%)
Retry markers     2/29  (  6.9%)
Retry body       22/164 ( 13.4%)
TOTAL            41/267 ( 15.4%)
```

## Open gaps (in priority order)

### 1. lib/data-structures.zig + lib/observable.zig FILE-NOT-LOADED

15 retry markers in data-structures.zig (sharded inner-lock spins) and
1 in observable.zig (SpinLock CAS) currently FILE-NOT-LOADED — no VOPR
test imports them. Even smoke tests that just file-load would shift
those 16 markers to instrumented status.

### 2. FS IO category 0/25

No VOPR test exercises any `posix.{open,read,write,...}` call. A test
that drives a small fs scenario via SimRing (or directly via posix
under VOPR-EXCLUDE) would unblock this category.

### 3. scheduler.zig run-loop time sites (L1374-1378)

Inside `run()`'s idle-arming code. Currently 0-hit because no VOPR
test enters the run loop. Adding a SimClock-driven scenario that
posts a single ready task and runs `run()` for one iteration would hit
these. Requires careful setup (the run loop is the production main path).

### 4. Extend fault injection to scheduler / parking-lot

V19+V20 wired SimAtomic fault injection into atomic-ptr-vopr and
versioned-vopr. The same pattern applies to:
- scheduler.zig WaitGroup.done / Semaphore.{acquire,release} spinlocks
- queues.zig WaiterList.spinAcquire
- observable.zig SpinLock.lock
Adding `pub const SimAtomic` to those VOPR test entries plus per-target
fault scenarios would push retry_body coverage well past 50%.

### 5. Loom side: scheduler.zig still has 5 nil + 30 0-hit sites

Out of scope for VOPR but listed for completeness. See
`docs/agents/parking-lot-loom-coverage.md` for the loom-side story.
The remaining sites need run-loop entry, real WaiterList state, or
real fiber stacks — much heavier than the loom seams already in place.

## Files

```
src/tools/vopr_coverage.rb         scanner + report
zig/runtime/vopr-clock.zig         SimClock
zig/runtime/vopr-random.zig        SimRandom
zig/runtime/vopr-gate.zig          GAP-B regression gate
zig/runtime/<name>-vopr.zig        per-executable scenarios
zig/<name>-vopr-test.zig           per-executable wrapper (main + tests array)
zig/build.zig                      vopr_exes table + coverage-vopr step
zig/lib/compat.zig                 SimClock / SimRandom comptime seams
```
## Production-code change audit (V31)

After V31 reverts the production changes are:

| File | New exec lines | Hit | Notes |
|---|---|---|---|
| `zig/lib/compat.zig` | 13 | 4 | 9 missing are comptime decls (SimClock/SimRandom seams, kcov-blind) |
| `zig/runtime/scheduler.zig` | 50 | 48 | 2 missing are `} else {` closing-brace artifacts |
| `zig/runtime/versioned.zig` | 4 | 0 | All 4 are comptime test-seam decls (kcov-blind) |
| `zig/runtime/vopr.zig` | 18 | 14 | 4 missing: 2 module-init vars, 2 `test "..."` blocks not on executable path |
| `zig/lib/atomic_ptr.zig` | 0 | n/a | comment markers only |
| `zig/lib/parking-lot.zig` | 0 | n/a | comment markers only |
| `zig/runtime/queues.zig` | 0 | n/a | comment markers + dead-code removal |

Effective production coverage: 100% (the kcov-blind lines are
comptime evaluations or closing-brace artifacts).

## TSan flake state

Master baseline (TSan 3/5 stream-test SplitStream pubsub hammer):
3/20 fail (15%) — pre-existing race, exists on master.

This branch HEAD after V31 reverts: 3/20 fail (15%) — matches
master baseline.

V22+V25+V27 in their original form pushed the rate to ~25% (V22
alone: 17%; combined with V25/V27: higher). V31 reverts all three
to bring the branch back to master's baseline.

## Architectural lesson

Routing widely-used production types through the comptime `Atomic`
alias amplifies TSan flake rates even when the alias resolves to
`std.atomic.Value` (semantic no-op). The amplification mechanism
appears to be timing perturbation from struct padding or compile-
cache hash differences — small enough that LLVM compiles slightly
different layouts, large enough to expose pre-existing races more
often.

Safe types to migrate (already on master before this branch):
- `lib/atomic_ptr.zig` Atomic
- `runtime/versioned.zig` Atomic
- `runtime/queues.zig` Task atomics + WaiterList.spin

Unsafe types to migrate (this branch tried, reverted):
- `runtime/scheduler.zig` WaitGroup/Semaphore counter+lock
- `lib/ownership.zig` Arc.Inner.{strong,weak}_count
- `lib/streams.zig` various
- `lib/data-structures.zig` Stream/InfStream Inner head/tail/lock
- `lib/observable.zig` SpinLock
- `runtime/profile-lock.zig` SpinLock

VOPR fault-injection on the unsafe types needs a different
mechanism (interceptor hooks rather than type-level alias).
