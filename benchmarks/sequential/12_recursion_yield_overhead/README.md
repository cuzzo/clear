# Recursion co-op yield overhead

Measures the per-recursive-call cost of `rt.checkYield()`
injected at the entry of every non-TIGHT recursive function.

## What this measures

Two `:TAIL_CALL` variants of a variable-modulus accumulator
(`acc = ((acc + n) * 1103515245) MOD (n + 7)`, ~1B iterations).
Both produce the same hash (asserted).

| Variant | EFFECTS clause | Per-iter cost |
|---|---|---|
| `hash_default` | `EFFECTS REENTRANT:TAIL_CALL` | yield-check (counter wrap + AND + branch) on every entry |
| `hash_tight` | `EFFECTS REENTRANT:TIGHT:TAIL_CALL` | bare self-jmp loop, no yield |

## Why this workload (and what NOT to use)

LLVM's scalar-evolution / induction-variable analysis can
fold simple polynomial recurrences (`acc * 31 + n`) to a
closed form. An earlier draft of this bench used that pattern
and got UNFAIR numbers: TIGHT got folded to constant-time
(180 ms for 1B iters -- impossible for a real serial dep
chain), DEFAULT did not (the yield-check inhibits the
optimization). The 10x gap that produced was an artifact of
the optimizer, not the actual yield cost.

The variable-modulus form (`acc MOD (n + 7)`) cannot be
reduced by scalar evolution. Both variants run all N
iterations in a tight serial dependency chain, so the
DELTA reflects the actual yield-check cost.

## Run

```bash
./clear build benchmarks/sequential/12_recursion_yield_overhead/bench.cht --optimized -o /tmp/bench_yield
for i in 1 2 3 4 5; do /tmp/bench_yield; done
```

## Sample results (~1B iterations, optimized build)

```
default = 8127 ms (with yield-check)
tight   = 8070 ms (no yield-check)
```

DEFAULT vs TIGHT: ~57 ms over 1B iterations =
**~0.06 ns / iter** of yield-check overhead. Less than 1%
relative on this workload. Same protection model as `WHILE`:
counter wrap + AND + compare-zero-and-branch on a per-fiber
counter; only the counter arithmetic on the hot path, no
syscall, no context switch unless a peer fiber is ready.

## Why not zero?

The yield-check is 4 instructions (load counter, inc, AND
mask, store) plus a branch. With LLVM unable to hoist or
elide the memory ordering across the recursive tail call,
the load-store pair adds about 1 cycle of latency. Across
1B iterations this is ~57 ms. Still essentially free for
real workloads where per-call work dominates.

## When to opt out

- Tight inner loops where the caller's fiber yields at a
  coarser granularity. Use `EFFECTS REENTRANT:TIGHT:TAIL_CALL`
  (or `:TIGHT:THUNK`).
- Bounded recursion via `:MAX_DEPTH(N)` where `N <=
  YIELD_BUDGET (4096)` -- TIGHT is implied, no yield emitted.
- For `N > YIELD_BUDGET` the compiler auto-injects the yield
  (overriding the implied TIGHT); switch to `:TIGHT:THUNK`
  if the recursive depth is large but you've handled
  yielding externally.

## Regression watch

If the DELTA between DEFAULT and TIGHT in this bench grows
significantly (say, > 5x current), something regressed in
either `mir_lowering#needs_recursion_yield?`,
`Runtime.checkYield`, or the LLVM build flags. The TIGHT
baseline is also a sanity check that the codegen actually
elides the yield -- both numbers tracked separately.
