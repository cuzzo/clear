# Benchmark 19: Parallel Aggregation (Histogram)

10M events bucketed into 10K categories via deterministic LCG. Two phases:
1. SHARD pipeline builds histogram on @sharded(32) map
2. CONCURRENT SUM/MIN/MAX/AVERAGE over histogram values

## Results

```
cores     Go (sequential)     CLEAR (SHARD)
  1         680ms               1242ms
  2         680ms                884ms
  4         680ms                799ms
  8         680ms                747ms
 32         680ms                637ms
```

## Why CLEAR barely scales

The SHARD pipeline has three sequential steps per item:
1. Hash the key string
2. Route to the owning scheduler via SPSC channel
3. The owning scheduler processes the item (1 map increment)

Step 3 is trivially cheap (~10ns per increment). Steps 1-2 are the
routing overhead (~60ns per item). With 10M items, routing alone is
~600ms. The parallel computation saves almost nothing because the
per-item work (map increment) is cheaper than the routing cost.

SHARD is designed for workloads where per-item processing is expensive
enough to amortize the routing overhead — e.g., parsing, transformation,
I/O. For simple counting, a single-threaded hashmap (Go's approach) is
faster because it avoids routing entirely.

## Why Go is sequential

The Go implementation intentionally uses a single-threaded map to show
the baseline. Go's `sync.Map` or sharded approach would be comparable
to CLEAR's SHARD pipeline.

## Improving this benchmark

Options to make CLEAR competitive:
- Use `@shared:sharded(128):locked` instead of SHARD — direct concurrent
  access without routing, like the kvstore benchmark
- Use CONCURRENT EACH with thread-local histograms, then merge
- Increase per-item work so routing overhead is amortized
