# Benchmark 05: HashMap

HashMap insert + lookup. 1M `i64 -> f64` entries. All three languages
use integer keys and float values for a direct comparison.

- C: custom open-addressing, Murmur-mixed i64 hash, single `calloc` for buckets
- Rust: `std::collections::HashMap<i64, f64>`, SipHash-1-3, `with_capacity(N)`
- CLEAR: `HashMap<Int64, Float64>`, bucket array in frame arena (zero GPA calls)

## Results

| Language | Insert | Lookup | Total | vs C |
|----------|--------|--------|-------|------|
| C (`gcc -O3`) | ~55ms | ~25ms | ~80ms | baseline |
| Rust (`--release`) | ~65ms | ~29ms | ~94ms | +18% |
| CLEAR (`--optimized`) | ~70ms | ~31ms | ~101ms | +26% |

CLEAR's frame arena eliminates malloc/free overhead for the bucket array,
but CLEAR's HashMap still uses the GPA for per-key bookkeeping.
The +26% gap vs C is primarily the cost of Zig's AutoHashMap overhead
vs a hand-tuned open-addressing table.
