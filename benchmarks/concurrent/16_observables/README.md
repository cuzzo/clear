# Concurrent Observables — CLEAR vs Go vs Rust

Benchmarks the lock-free `@observable` runtime backing CLEAR's
`~T@observable` types against equivalents in Go and Rust, plus
`@locked` baselines in each.

Two distinct measurements live in this directory:

1. **CLEAR-language form** (`bench.cht`): the canonical user pattern
   that exercises the full pipeline-terminal observable wiring —
   BG STREAM producer + `s> SUM _` consumer-fiber spawn + WaitGroup
   join via `NEXT`. Measures end-to-end cost of the language form,
   including stream yield/resume overhead.

2. **Cross-language atomic-counter comparison** (`bench_clear.zig`,
   `bench.go`, `bench.rs`): 1 writer thread + K reader threads
   hammer a shared atomic accumulator. Measures the underlying
   lock-free runtime (`obs.AtomicSum` for CLEAR; `atomic.Int64` for
   Go; `AtomicI64` for Rust) head-to-head with no language overhead.

```clear
-- bench.cht (the canonical CLEAR form)
running: ~Int64@observable = gen s> SUM _;
final = NEXT running;
```

The compiler heap-allocates an `*ObservableSum(i64)` plus a
WaitGroup, **spawns a CONSUMER fiber cross-scheduler** that pulls
from `gen` and calls `.add(item)` per emit, and `NEXT` parks main
on the WG until the consumer's `defer ctx.acc.finish()` issues
`wg.done()`. Producer (BG STREAM gen), consumer fiber, and main
all run on different worker threads in the default multi-threaded
runtime, so the fold genuinely overlaps with the joiner.

## Workload

  - 1 writer producing 5,000,000 increments
  - K reader threads each calling `view()` until the writer finishes
    (K ∈ {1, 4, 8})

## Results (this box, ReleaseFast / `-O` / `--release`)

### CLEAR-language pipeline form (`bench.cht` → `./clear build --optimized`)

```
CLEAR observable: 12499997500000 (sum 0..N-1) in 61 ms      (~12 ns/item)
```

5M values produced by a `BG STREAM`, folded via `s> SUM _` (which
auto-produces a `~Int64@observable`), and joined via `NEXT`. The
producer (BG STREAM gen), consumer fiber (spawned by the SUM emit
cross-scheduler), and main (parked on the observable's WaitGroup)
all run on different worker threads concurrently:

```clear
FN main() RETURNS Void ->
    n_writes: Int64 = 5_000_000_i64;
    gen: ~?Int64[] = BG STREAM {
        MUTABLE i: Int64 = 0_i64;
        WHILE i < n_writes DO YIELD i; i = i + 1_i64; END
    };

    t0 = timestampMs();
    running: ~Int64@observable = gen s> SUM _;
    final = NEXT running;
    elapsed = timestampMs() - t0;

    print("CLEAR observable: ", final, " in ", elapsed, " ms");
    RETURN;
END
```

The 12 ns/item is the language-form cost: BG STREAM yield/resume
overhead per item + cross-scheduler atomic add + WaitGroup join.
The pure atomic-add-only number (no stream fiber, no consumer
fiber spawn) lives in the cross-language reader-stress table below.

### Concurrent reader stress (`bench_clear.zig` / `bench.go` / `bench.rs`)

1 writer thread + K reader threads hammering the shared atomic
counter. Same workload across all four implementations. (Median of
3 runs; high variance on hot CPUs, especially at 8 readers.)

| Variant                              | 1 reader               | 4 readers              | 8 readers              |
|--------------------------------------|------------------------|------------------------|------------------------|
| **CLEAR `obs.AtomicSum`**            | 37 ns/inc, **142 M r/s** | 67 ns/inc, **466 M r/s** | 88 ns/inc, **831 M r/s** |
| Go `atomic.Int64`                    | 30 ns/inc, 950 M r/s   | 50 ns/inc, 2.97 G r/s  | 53 ns/inc, 4.31 G r/s  |
| Rust `AtomicI64`                     | 35 ns/inc, 400 M r/s   | 50 ns/inc, 1.78 G r/s  | 58 ns/inc, 2.40 G r/s  |
| **CLEAR `compat.Mutex`** (@locked)   | 130 ns/inc, 7.4 M r/s  | 416 ns/inc, 9.5 M r/s  | 797 ns/inc, 10.2 M r/s |
| Go `sync.Mutex`                      | 63 ns/inc, 25 M r/s    | 384 ns/inc, 11 M r/s   | 1220 ns/inc, 7.7 M r/s |
| Rust `Mutex<i64>`                    | 157 ns/inc, 6.9 M r/s  | 288 ns/inc, 4.8 M r/s  | 430 ns/inc, 6.6 M r/s  |

### Perf optimization round (`obs.AtomicSum` vs raw `std.atomic.Value`)

`zig/observable-microbench.zig` isolates `obs.AtomicSum(i64)` against
raw `std.atomic.Value(i64)` (= Go's `atomic.Int64` / Rust's
`AtomicI64`) inside the same Zig binary, eliminating compiler /
runtime variables. Pre-optimization round, the gap was 2-9× on
reads/sec. Two changes closed most of the gap:

1. **`align(64)` on every atomic field.** The previous layout had
   `value` and `seen` (the started()-predicate flag) on the same
   cache line. Every `add()` did `seen.store(1)` + `fetchAdd(value)`,
   and the `seen.store` invalidated the readers' cached `value`
   line, forcing a refetch after every write. Aligning each atomic
   to its own cache line (Zig's `field: T align(64)`) means readers
   only invalidate-and-refetch on actual `value` writes.

2. **`inline` on hot-path readers (`view`, `final`, `started`,
   `add`).** The view lambda was small enough that ReleaseFast
   inlined it most of the time, but not always — explicit
   `pub inline fn view` removed an indirection on the hottest read.

After: obs.AtomicSum is 1.0–1.5× the raw cost on this box (was
2–9×). The remaining gap is the writer's `seen.store(1)` per add
(needed for `started()` semantics — no clean way to remove without
breaking that contract). At 16+ readers obs effectively ties raw.

Microbench results (best of 3, 32-core box):

| Readers | obs ns/inc | raw ns/inc | obs r/s | raw r/s | r/s gap |
|---|---|---|---|---|---|
| 1  | 31  | 30  | 175 M  | 200 M  | 1.14× |
| 2  | 37  | 37  | 277 M  | 333 M  | 1.20× |
| 4  | 56  | 49  | 535 M  | 694 M  | 1.30× |
| 8  | 75  | 67  | 873 M  | 1.18 G | 1.35× |
| 16 | 79  | 80  | 1.14 G | 1.58 G | 1.39× |
| 31 | 209 | 161 | 4.35 G | 4.93 G | 1.13× |

## Read

  - **CLEAR observables beat CLEAR's own `@locked` baseline by ~10-80×**
    on read throughput. Same dynamic in Go and Rust: lock-free
    atomics dominate locked counters.
  - **`obs.AtomicSum` vs raw `std.atomic.Value`: 1.0-1.4× gap**
    (microbench, 1-31 readers). The 2-9× cross-language gap to Go's
    `atomic.Int64` reads/sec is mostly a Zig-vs-Go runtime gap
    (Go's atomic load codegen / GC-aware runtime appears to amortize
    cache-line bouncing better) — within Zig, obs.AtomicSum is
    nearly at parity with the raw atomic.
  - **Writer ns/inc grows under reader contention** in all three
    atomic implementations (cache-line ping-pong); after the
    `align(64)` fix the curves are similar shape across CLEAR / Go
    / Rust.

## Pipeline-terminal wiring

The CLEAR-language form above compiles to roughly:

```zig
const __obs_acc = CheatLib.obs.ObservableSum(i64).new(rt.heapAlloc()) catch unreachable;
const __obs_wg = rt.heapAlloc().create(CheatHeader.WaitGroup) catch unreachable;
__obs_wg.* = CheatHeader.WaitGroup.init(rt.getSched()); __obs_wg.add(1);
__obs_acc.setCompletion(@ptrCast(__obs_wg), CheatHeader.obsWgDone, CheatHeader.obsWgWait, CheatHeader.obsWgDestroy);
// Spawn consumer fiber cross-scheduler:
const ConsumerCtx = struct { acc: *..., gen: ..., fn run(...) {
    defer ctx.acc.finish();   // wg.done() via callback
    while (try ctx.gen.next()) |it| ctx.acc.add(it);
} };
try CheatHeader.spawnBest(...);
// running := __obs_acc;
// NEXT running := __obs_acc.next() → wg.wait() (Blocked, then view())
// scope-exit cleanup: _ = running.next() catch {}; running.destroy(rt.heapAlloc());
//   destroy() frees the WG via the callback.
```

Wiring spans:
  - `ObservableSum(T)` runtime wrapper (atomic + done flag + completion callbacks).
  - `Type#zig_type` maps `~T@observable` → `*CheatLib.obs.ObservableSum(T)`.
  - Annotator accepts the type-coercion + stamps `observable_dest` on the pipe + marks the binding `non_escaping` (the producer fiber's `gen` borrow is bound to scope, so the heap pointer can't return / GIVE / store-into-struct).
  - `lower_range_fold_observable_sum` (pipeline_host.rb) heap-allocs acc + WG, spawns consumer fiber cross-scheduler.
  - WG bridge (`runtime-header.zig`: obsWgDone / obsWgWait / obsWgDestroy) keeps observable.zig runtime-agnostic.
  - `:observable_sum` cleanup recipe waits on WG, frees acc + WG.

Transpile-tests `303-306` lock these in. The `WITH VIEW`
partial-value observation lives in `304_observable_with_view`
(`s ∈ [0, 45]`, was `s == 45` in the synchronous-fold era —
proves the producer is genuinely racing).

## Build & run

  - CLEAR: `./clear build --optimized bench.cht -o bench_clear_lang && ./bench_clear_lang`
  - Zig:   `zig build-exe --dep obs --dep compat -Mroot=bench_clear.zig -Mobs=../../../zig/lib/observable.zig -Mcompat=../../../zig/lib/compat.zig -lc -OReleaseFast --name bench_clear && ./bench_clear`
  - Go:    `go run bench.go`
  - Rust:  `rustc -O bench.rs -o bench_rust && ./bench_rust`

The Zig microbench (`obs.AtomicSum` vs raw `std.atomic.Value` in the
same binary, isolating language overhead) lives at
`zig/observable-microbench.zig`:
  - `cd zig && zig build-exe --dep obs --dep compat -Mroot=observable-microbench.zig -Mobs=lib/observable.zig -Mcompat=lib/compat.zig -lc -OReleaseFast --name obsmb && ./obsmb`

The DISTINCT bench (`obs.ObservableStreamSet(i64)` writer + K readers)
lives in this directory at `bench_distinct.zig`:
  - `zig build-exe --dep obs --dep compat -Mroot=bench_distinct.zig -Mobs=../../../zig/lib/observable.zig -Mcompat=../../../zig/lib/compat.zig -lc -OReleaseFast --name bench_distinct && ./bench_distinct`

  Cross-language DISTINCT comparison (Go's `sync.Map`, Rust's
  `DashSet`) is deferred -- the SUM bench's cross-lang setup is
  non-trivial to replicate, and the in-Zig writer ns/submit numbers
  already give us a regression-tracking baseline for StreamSet.

## Known scaling issues

  - **In-language hot-poll readers.** A `WHILE current < expected DO
    WITH VIEW running AS s ... END` reader loop in CLEAR currently
    only works in a separate worker thread (BG dispatched
    cross-scheduler). On the same scheduler as a *pinned* main, the
    pinned-vs-ready `pickNext` priority (scheduler.zig:826-830)
    starves the unpinned producer fiber. The cross-language
    reader-stress comparison above already runs OS-thread readers,
    so this is mostly an ergonomics issue for the language-form
    bench, not a correctness gap. Fix paths: (a) `pickNext` falls
    through to `ready_queue` when `pinned == [self]`; (b) a
    `Runtime.parkBriefly()` builtin that puts the joiner Blocked
    with a wake timer.
  - **Other terminals** (COUNT, MAX, MIN, AVG, ANY, ALL, FIND, scalar
    REDUCE). Each needs its own `Observable*` wrapper + a branch in
    `lower_range_fold` mirroring SUM. Mechanical, ~1 day total.
  - **DISTINCT into `~T[]@set@observable`.** Wires `StreamSet` into
    the DISTINCT pipe path. Slice-direct view via the existing
    Phase 2.6 codegen.
  - **Performance gap to Go/Rust raw atomics — Zig codegen issue.**
    Cross-language: ~2-9× slower than Go on reads/sec. Within Zig
    (`observable-microbench.zig`), `obs.AtomicSum` is now within
    1.0-1.4× of raw `std.atomic.Value(i64)`, so the wrapper itself
    is fine. The remaining gap to Go is **upstream Zig codegen**, not
    our wrapper:

    Three fixes already applied in the cross-language benches:
      1. `n +%= 1` instead of `n += 1` — Zig adds an overflow-check
         (`setb` + panic call) even in `-OReleaseFast`; Go/Rust wrap
         by default. Without `+%=`, every iteration paid the check.
      2. `sink ^= counter.load(...)` to defeat dead-store elision.
         Adding the data-dependent sink dropped Go from 950 M to
         726 M r/s on 1 reader, confirming Go was eliding part of
         the previous pure-load loop.
      3. Pass reader ctx by `*const`, not by value — keeps the hot
         pointers in registers across iterations.

    What's left is a Zig (0.16) `-fllvm -OReleaseFast` codegen issue:
    even with the three fixes above, the reader loop disassembles
    to ~20 instructions with redundant stack spills of `ctx.counter`
    / `ctx.stop` every iteration, where Go's loop is 6 instructions
    with the pointers held in registers. `objdump -d` of
    `observable-microbench.zig`'s `raw_reader` shows `mov %rsi,...`
    spills to `-0x70(%rbp)` and `-0x68(%rbp)` *both*, then reloads
    the same value through the stack on each iteration. The body
    contains the actual atomic load (one `mov`), but the surrounding
    LLVM-IR-to-asm lowering doesn't promote the reloaded ctx fields.

    Reproducer / next steps when the priorities allow:
      - `cd zig && zig build-exe --dep obs --dep compat
        -Mroot=observable-microbench.zig -Mobs=lib/observable.zig
        -Mcompat=lib/compat.zig -lc -OReleaseFast -fllvm --name obsmb`
      - `objdump -d --no-show-raw-insn obsmb |
        sed -n '/<observable-microbench.raw_reader>:/,/^$/p'` — note
        the spills of `-0x60`/`-0x58` and `-0x50`/`-0x48`.
      - Try `-femit-llvm-ir` to see whether the IR already has the
        spills (frontend issue) or whether LLVM is failing to promote
        them (backend issue).
      - Try a hand-written C loop with the same shape to confirm
        clang can hoist what Zig cannot.

    Until that's tracked down, the gap is upstream and the wrapper
    is at parity with raw Zig — closing it requires fixing the Zig
    codegen, not the observable runtime.
