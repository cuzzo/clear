# Thunk vs plain reentrance

A `clear-only` benchmark for Thunk Phase 5b. Both variants run
`sum_n(N)` where `sum_n` is `IF n <= 0 -> RETURN 0; RETURN 1 +
sum_n(n - 1);` (simple-recurrence shape; splitter accepts).

| File | Lowering | Stack | Heap |
|---|---|---|---|
| `bench_thunk.cht` | `EFFECTS REENTRANT:THUNK` | regular fiber, depth = 1 | one Frame per recursion level |
| `bench_reentrant.cht` | plain `EFFECTS REENTRANT`, BG `@service` | OS thread, 2 MB pre-allocated | none |

`N` is sampled from `timestampMs() MOD 1000` so LLVM can't fold
the recursion to a closed form.

## Run

```bash
RUNS=5 bash compare.sh
```

## Results (depth ~99,000, optimized build)

```
=== THUNK (5 runs) ===
elapsed=0.00 rss_kb=7168
  avg_rss_kb=7168  avg_elapsed=0
=== REENTRANT (5 runs) ===
elapsed=0.00 rss_kb=2048
  avg_rss_kb=2048  avg_elapsed=0
```

Both finish under the wall-clock granularity (<10 ms). The
load-bearing observation is RSS:

- `:THUNK` lives on a regular fiber stack and grows the heap
  by the active Frame chain (~7 MB peak at this depth).
- Plain `:reentrant` requires `@service` -- a 2 MB OS thread.
  Linux commits stack pages lazily so the resident set stays
  small, but the address-space reservation is unconditional.

## What this validates (and what it doesn't)

- **Validates**: `:THUNK` no longer forces the call site onto
  `@service`. The default fiber tier handles the bench. (Phase 4g.)
- **Validates**: deep recursion under `:THUNK` runs to completion
  on a heap-bounded budget rather than a stack budget.
- **Doesn't validate** (yet): a hard-cap depth where plain
  `:reentrant` overflows but `:THUNK` survives. The 100K target
  fits both because LLVM's optimized frame is small (<20 bytes).
  A safety-build comparison would show the gap (~256 bytes/frame
  × 100K = 25 MB, overflows the 2 MB `@service` stack), but the
  default `clear test` path already crashes at depth 10K under
  safety mode.

## Caveats

- Wall-clock timing is below resolution at this workload size;
  use `--release` (optimized) and bump `N` further when timing
  becomes the focus. The RSS numbers are stable as shown.
- The `:reentrant` variant transitively requires `@service` per
  the explicit-OS-thread rule (Phase 4g) -- removing `@service`
  from the BG block fails compile. That IS the design.
