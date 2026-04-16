# Benchmark 08: Pointer Chase

Pool-based linked traversal: 2M nodes, additive prime-step permutation (`step=999983`, coprime with N, visits all nodes exactly once).

- C: raw pointer chain (`Node *next`), 16-byte nodes
- CLEAR: `@pool` + `Id<Node>` handles, 32-byte pool slots (includes alive + generation fields for ABA safety)

Both benchmarks time the walk phase only (2M dereferences). Setup (build + wire) is excluded.

## Results

| Language | Walk time | vs C | RSS |
|----------|-----------|------|-----|
| C (`gcc -O3`) | ~214ms | baseline | ~32 MB |
| CLEAR (`--optimized`) | ~204ms | -5% | ~148 MB |

Walk throughput is on par in the memory-bound regime. The 64 MB working set (2M × 32-byte slots) far exceeds L2, so every access hits DRAM. The extra instructions in `pool.get()` (alive check, generation check, address arithmetic vs C's single pointer load) are absorbed into the DRAM stall latency.

## Memory gap

CLEAR uses ~4.5x the RSS: pool slots are 2x the size of raw C nodes, plus the `id_list` array and scheduler overhead. This is the real cost of `@pool` ABA-safe handle semantics.
