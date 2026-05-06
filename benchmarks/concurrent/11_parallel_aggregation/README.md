# Benchmark 19: Parallel Aggregation (Histogram)

10M events bucketed into 1,000 categories via deterministic LCG. Two phases:

1. Build histogram (parallel, shared-nothing)
2. Compute sum/max/min/avg over histogram values (parallel reduce)

All three use the same LCG with the same seed => identical results.

## Implementations

- **CLEAR**: `@sharded(32)` map + `SHARD()` routing (zero locks). Stats via `CONCURRENT SUM/MAX/MIN/AVERAGE`.
- **Go**: Per-goroutine local maps + merge (~40 lines). Stats via goroutine partial reduce (~30 lines).
- **Rust**: Rayon `par_iter().fold().reduce()` for histogram. Rayon `par_iter().sum()/reduce()` for stats (~20 lines).

This is intentionally documented as **not apples-to-apples** for the histogram
phase. Go and Rust use local fold/reduce: each worker owns a private local
histogram over a contiguous slice, then the program merges the 1,000 bucket
counts at the end. CLEAR currently uses `SHARD`, which routes every item to
the owning shard worker before mutating the map. That measures the general
shared-nothing routing primitive, not the ideal histogram algorithm.

## Results

```
Rust (rayon)    0.027 s   RSS: 91 MB
Go (goroutines) 0.017 s   RSS: 80 MB
CLEAR (fibers)  0.107 s   RSS: 357 MB

CLEAR vs Go:   +529%
CLEAR vs Rust: +296%
```

Previous result before switching to integer keys: CLEAR 0.111 s at 1M events
(+745% vs Go). Integer keys eliminated ~1M string allocations per run at that
size. Later SHARD transport batching reduced routing overhead substantially,
but it does not change the algorithmic mismatch.

## Why CLEAR is slower

The SHARD routing pipeline computes a key, hashes it, sends it to the owning
shard fiber, receives it, and then performs a tiny map increment. Even with
transport batching, every event still pays routing overhead that local
fold/reduce avoids.

Go and Rust avoid routing entirely: goroutines/rayon threads each own a
local slice of work and write their local map without coordination. The
merge is a single sequential pass over 1,000 entries.

SHARD amortizes well when per-item work is expensive or when long-lived
per-key ownership matters (request routing, actor-like state, sharded services).
For simple counting over a fixed input, it is over-engineered.

## Current profile note

`SHARD(...) s> CONCURRENT EACH` now runs as real shard-parallel work: one
producer routes keys into per-shard bounded queues, and one worker fiber drains
each shard. `clear profile` shows the shard workers distributed across
schedulers, so the old failure mode (a single serial SHARD loop) is no longer
the limiting factor.

The remaining cost is structural. SHARD is doing correct shared-nothing
routing, but the benchmark wants local worker-private aggregation. Batching
helps the SHARD path, but it cannot make per-item routing equivalent to no
routing.

## TODO: PARALLEL FOLD / GROUP_BY primitive

The benchmark should ultimately use a CLEAR primitive that matches the Go/Rust
algorithm: each worker gets a private local accumulator, then a merge combines
partials after the barrier. If/when `GROUP_BY` exists, this benchmark should
prefer that over `SHARD` for the primary comparison. Until then, the SHARD
version is useful as a routing benchmark but should not be interpreted as
CLEAR's best possible histogram implementation.

A future `PARALLEL FOLD ... MERGE` pipeline stage would close this gap:

```clear
counts = (0..<n) s> PARALLEL FOLD HashMap<Int64, Int64> {
    k = absInt(seeds[_]) MOD buckets;
    _acc[k] = (_acc[k] OR 0_i64) + 1_i64;
} MERGE {
    _acc[k] = (_acc[k] OR 0_i64) + _partial[k];
};
```

Each worker owns a private `_acc`; a sequential merge combines partials after
`WaitGroup.wait()`. SHARD remains correct and preferable when ownership/routing
semantics matter; local fold/reduce is the right tool for pure aggregation.

## Ergonomics comparison

The parallel histogram pattern requires explicit plumbing in Go/Rust:

| Task | CLEAR | Go | Rust |
|------|-------|----|------|
| Parallel histogram | 3 lines (SHARD pipeline) | ~40 lines | ~15 lines |
| Stats reduce | 4 lines (CONCURRENT SUM/MAX/MIN/AVG) | ~35 lines | ~10 lines |
