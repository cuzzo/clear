# Benchmark 27: False Sharing

N threads each increment their own counter M times (40M total work).
Tests whether CLEAR's `@shared:locked` eliminates false sharing by construction.

## What each implementation does

| Implementation | Sync | Layout |
|----------------|------|--------|
| C packed | none (racy) | adjacent int64s (false sharing) |
| C padded | none (racy) | 64-byte aligned (no false sharing) |
| Go heap-alloc | none (racy) | separate `*int64` per goroutine |
| Rust Arc<Mutex> | mutex | separate heap alloc per thread |
| CLEAR @shared:locked | mutex | separate heap alloc per fiber |

`BENCH_RESULT` per language: C=padded, Go=heap-alloc, Rust=Arc<Mutex>, CLEAR=elapsed.

## Results (32 threads, 40M total increments)

| Implementation | ms | vs CLEAR |
|----------------|-----|---------|
| CLEAR @shared:locked | ~56ms | baseline |
| Rust Arc<Mutex> | ~116ms | CLEAR -52% |
| Go heap-alloc (racy) | ~3ms | n/a - no mutex |
| C padded (racy) | ~3ms | n/a - no mutex |

## Interpretation

**CLEAR vs Rust Arc<Mutex>**: same mechanism (heap alloc + mutex), CLEAR is ~2x faster.
This reflects CLEAR's lighter-weight mutex implementation.

**CLEAR vs C padded / Go heap-alloc**: NOT a fair comparison. C and Go have no mutex -
they are racy writes that happen to be cache-isolated. The 18x gap is the cost of
mutex acquisition, not false sharing.

**False sharing penalty (from C packed vs C padded)**:
On 32 cores, packed counters cause 5-10x slowdown due to cache line bouncing.
CLEAR `@shared:locked` sidesteps this entirely: each `@shared` is a separate heap
allocation with its own control block, so no manual padding is needed.

## Key finding

CLEAR eliminates false sharing by construction. The programmer gets automatic cache
isolation without manual `__attribute__((aligned(64)))` or padding structs.
The cost is mutex overhead, which is expected and present in all safe concurrent
counter implementations. Rust's Arc<Mutex> pays the same cost; CLEAR pays ~half.
