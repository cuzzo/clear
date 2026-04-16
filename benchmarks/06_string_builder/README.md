# Benchmark 06: String Builder

String concatenation via list+join vs C StringBuilder. 10,000 runs x 1,000 appends of `"hello"`.

- C: geometric-growth realloc buffer (amortized O(1) per append, O(N) total copies per run)
- CLEAR: `String[]@list` + `join(parts, "")` — bump-pointer list, O(N) total copies per run, arena rewinds each outer iteration

Both strategies do O(N) total work per run; the difference is allocator mechanism.

## Results

| Language | Time | vs C |
|----------|------|------|
| C (`gcc -O3`) | ~65ms | baseline |
| CLEAR (`--optimized`) | ~105ms | +62% |

The gap comes from two sources:
- CLEAR's frame arena is a bump pointer vs C's realloc (amortized but still touches the allocator)
- CLEAR RSS is ~16 MB vs C's ~1.5 MB — the bulk of that difference is fiber scheduler overhead, not string allocation

## Why no Rust baseline?

Rust's `String::push_str` + `String::with_capacity` would be the natural comparison, but it is essentially identical to the C realloc strategy. The benchmark is primarily documenting CLEAR's frame-arena cost vs the heap.
