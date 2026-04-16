# Benchmark 22: Pool vs List

Insert 5M `Entity{x, y, health}` structs then sum the `health` field. Compares dense contiguous allocation against individual-allocation patterns across three languages.

`BENCH_RESULT` = the dense (list/slice/array) path — the fast path in each language.

## Cross-language: dense array path

| Language | Strategy | Time |
|----------|----------|------|
| C | `malloc(N * sizeof)` once, fill sequentially | ~62ms |
| Go | `make([]Entity, 0, N)`, append | ~57ms |
| CLEAR | `Entity[5000000]@list` (pre-allocated), append | ~65ms |

CLEAR is within 5% of C and 14% of Go for dense sequential insert + read.

## CLEAR internal: list vs pool overhead

```
List (dense):   66 ms   — pre-allocated contiguous array, bump-pointer appends
Pool (handles): 213 ms  — generational handles, alive+generation check per get()
Pool overhead:  +147 ms (+222%)
```

The pool overhead comes from three sources:
- `pool.insert()` writes alive+generation fields alongside each slot
- A separate `Id<Entity>[]@list` is needed to store handles for later access (pool has no iteration API)
- `pool.get(id)` checks alive flag + generation + computes slot address

The same pattern holds in C (N mallocs ~3x slower than one contiguous malloc) and Go (`new(Entity)` ~3x slower than slice append).

## When to use each

- `@list`: read-all, append-only collections. Dense memory, O(1) append, O(N) sum.
- `@pool`: when you need ABA-safe handle semantics (stable IDs after removal, generational safety). Pay the ~3x overhead when correctness requires it.
