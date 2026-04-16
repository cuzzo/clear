# Benchmark 19: Parallel Aggregation (Histogram)

1M events bucketed into 1,000 categories via deterministic LCG. Two phases:

1. Build histogram (parallel, shared-nothing)
2. Compute sum/max/min/avg over histogram values (parallel reduce)

All three use the same LCG with the same seed => identical results.

## Implementations

- **CLEAR**: `@sharded(32)` map + `SHARD()` routing (zero locks). Stats via `CONCURRENT SUM/MAX/MIN/AVERAGE`.
- **Go**: Per-goroutine local maps + merge (~40 lines). Stats via goroutine partial reduce (~30 lines).
- **Rust**: Rayon `par_iter().fold().reduce()` for histogram. Rayon `par_iter().sum()/reduce()` for stats (~20 lines).

## Results

```
Rust (rayon)    0.018 s   RSS: 16 MB
Go (goroutines) 0.014 s   RSS: 12 MB
CLEAR (fibers)  0.081 s   RSS: 46 MB

CLEAR vs Go:   +493%
CLEAR vs Rust: +342%
```

Previous result before switching to integer keys: CLEAR 0.111 s (+745% vs Go).
Integer keys eliminate ~1M string allocations per run, saving ~30ms.

## Why CLEAR is slower

Same fiber runtime overhead documented in benchmark 18 (SHARD vs locked).
The SHARD routing pipeline (hash key, send to owning fiber via SPSC channel,
receive + process) costs ~60ns per item. With 1M items and trivially cheap
per-item work (one map increment, ~10ns), routing dominates.

Go and Rust avoid routing entirely: goroutines/rayon threads each own a
local slice of work and write their local map without coordination. The
merge is a single sequential pass over 1,000 entries.

SHARD amortizes well when per-item work is expensive (parsing,
transformation, I/O). For simple counting it is over-engineered.

## Ergonomics comparison

The parallel histogram pattern requires explicit plumbing in Go/Rust:

| Task | CLEAR | Go | Rust |
|------|-------|----|------|
| Parallel histogram | 3 lines (SHARD pipeline) | ~40 lines | ~15 lines |
| Stats reduce | 4 lines (CONCURRENT SUM/MAX/MIN/AVG) | ~35 lines | ~10 lines |
