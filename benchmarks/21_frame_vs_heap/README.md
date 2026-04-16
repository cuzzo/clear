# Benchmark 21: Frame vs Heap Escape

Measures the cost of arena frame allocation vs heap-promoted strings. 1M iterations of building `"item-N-value"` for N in [0, 1M).

`BENCH_RESULT` = the no-malloc path for each language (frame / stack / GC).

| Language | No-malloc path | Strategy | Time |
|----------|---------------|----------|------|
| CLEAR | Frame arena (bump pointer, rewound per iteration) | `benchFrame` | ~18ms |
| C | Stack buffer (`char buf[64]`, `snprintf`) | `bench_stack` | ~36ms |
| Go | GC-managed (`fmt.Sprintf`) | `benchGC` | ~89ms |

CLEAR's frame arena is ~2x faster than C's stack snprintf and ~5x faster than Go's GC path.

## CLEAR internal comparison (shown in binary output)

The CLEAR binary also runs `benchHeap` (heap-promoted strings via `makeString` return) to show the escape overhead:

```
Frame (no escape):  18 ms
Heap  (promoted):   ~120 ms
Heap overhead:      ~102 ms  (~560% slower)
```

Each heap iteration pays `GPA.alloc` + `GPA.free` per string. The frame path pays zero allocator calls — the arena bumps and rewinds.

## Why CLEAR beats C here

C's `snprintf` does format parsing and integer conversion on every iteration with a runtime call. CLEAR's string interpolation compiles to direct writes into the frame arena buffer, with `intToString` inlined by LLVM. The arena's sequential writes stay cache-warm across iterations.

## RSS note

CLEAR's RSS (~16 MB) reflects the scheduler (32 worker threads at ~500 KB each), not string data. The actual string allocations are zero-cost frame memory, invisible to RSS after each iteration rewind.
