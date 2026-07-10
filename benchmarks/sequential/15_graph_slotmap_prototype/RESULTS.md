# Graph representation benchmark results

These are median-of-five results from 2026-07-10 on one pinned core of an
Intel Xeon Gold 6548N. The core has 32 KiB L1D and 4 MiB private L2. Binaries
were built with Zig 0.16.0 `ReleaseFast`, GCC 13.3 `-O3 -march=native`, Rust
1.96 `-C opt-level=3`, and Go 1.22.2. Checksums matched for every size and
implementation.

## What “perfect C” means

There are two idealized unsafe lower bounds:

- `c-perfect-u32-index` stores 24-byte nodes contiguously and follows unchecked
  direct 32-bit indices. Tail churn overwrites nodes in place and collapse only
  changes the logical length. It has no stable identity, generation checks, or
  per-node destruction.
- `c-perfect-raw-pointers` stores 40-byte nodes contiguously with four raw
  64-bit pointer edges. It has the same missing safety properties and a larger
  cache footprint.

`c-unsafe-slotmap` is a third C baseline with the proposed handle-to-dense
mapping but no generations. The previous benchmark called this “C”; doing so
made the proposed slotmap look much closer to perfect C than it was.

Each run builds all edges, performs approximately 36 million local edge reads,
at least 4 million edge assignments, approximately 36 million random edge
reads, approximately 1 million vertex replacements with four initialized
edges, collapses to 1% roots, and repeats full sparse iteration enough times to
check 100 million original-capacity positions. Sparse dense representations
visit about 1 million live nodes; tombstone/root-array representations must
also check the dead positions.

## Combined time across cache sizes

Sparse scanning is reported separately and is not included in combined time.
Parentheses are ratios to unchecked direct-index C at the same size.

| Capacity | C u32 index | C raw pointers | C unsafe slotmap | Proposed safe slotmap | CLEAR pool | CLEAR LINK/RESOLVE | Rust Rc/Weak | Go GC |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 4,096 | 34.49 ms | 38.53 (1.12x) | 50.36 (1.46x) | 53.97 (1.56x) | 41.38 (1.20x) | 100.11 (2.90x) | 130.34 (3.78x) | 147.78 (4.28x) |
| 16,384 | 37.62 ms | 41.33 (1.10x) | 53.78 (1.43x) | 57.66 (1.53x) | 45.61 (1.21x) | 108.05 (2.87x) | 136.97 (3.64x) | 165.42 (4.40x) |
| 65,536 | 45.00 ms | 52.55 (1.17x) | 70.16 (1.56x) | 73.96 (1.64x) | 66.20 (1.47x) | 184.56 (4.10x) | 215.65 (4.79x) | 222.08 (4.94x) |
| 262,144 | 91.07 ms | 115.49 (1.27x) | 119.81 (1.32x) | 133.95 (1.47x) | 162.76 (1.79x) | 430.02 (4.72x) | 450.41 (4.95x) | 392.55 (4.31x) |
| 1,000,000 | 307.27 ms | 390.26 (1.27x) | 374.86 (1.22x) | 365.83 (1.19x) | 427.06 (1.39x) | 1,073.37 (3.49x) | 1,085.26 (3.53x) | 1,027.34 (3.34x) |

At DRAM scale the paged slotmap is 1.19x ideal direct-index C, slightly faster
than C's unsafe slotmap, and 6% faster than raw-pointer C. While compact C is
cache-resident it remains 1.47x–1.64x overall; the 1.15x expectation therefore
only describes the large memory-bound case, not a universal ratio.

## All scenarios at one million nodes

| Scenario | C u32 index | C raw pointers | C unsafe slotmap | Proposed safe slotmap | CLEAR pool | CLEAR LINK/RESOLVE | Rust Rc/Weak | Go GC |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Build | 18.91 ms | 26.23 | 22.86 | 21.35 | 52.69 | 66.24 | 64.90 | 86.41 |
| Local reads | 17.31 ms | 31.98 | 20.67 | 22.80 | 47.81 | 103.95 | 103.17 | 67.63 |
| Edge writes | 32.71 ms | 35.17 | 32.70 | 29.08 | 31.27 | 235.28 | 240.80 | 82.46 |
| Random reads | 229.83 ms | 289.22 | 284.92 | 270.43 | 280.69 | 475.79 | 479.81 | 268.92 |
| Vertex churn | 7.32 ms | 7.68 | 9.80 | 9.74 | 8.81 | 122.33 | 131.35 | 352.49 |
| Collapse to 1% | <0.001 ms | <0.001 | 3.98 | 9.84 | 4.81 | 69.58 | 68.05 | 157.16 |
| Sparse full scans | 0.078 ms | 0.086 | 0.331 | 0.314 | 308.92 | 73.19 | 48.98 | 61.03 |

Ratios for the proposed slotmap versus direct-index C are 1.13x build, 1.32x
local reads, 0.89x edge writes, 1.18x random reads, 1.33x churn, and 4.03x
sparse dense iteration. Collapse cannot have a meaningful ratio because ideal
C does no deletion work at all.

Random-read overhead is most severe while the compact C payload is cache
resident: the proposed slotmap is 2.08x C at 4K, 1.89x at 16K, 2.06x at 64K,
1.55x at 256K, and 1.18x at 1M. At large sizes both representations become
memory-latency bound, narrowing the ratio.

## Memory at one million capacity

| Implementation | Peak representation/requested bytes per capacity | Retained observation after collapse |
|---|---:|---:|
| C unchecked u32 index | 24 | 22.89 MiB (preallocated) |
| C raw pointers | 40 | 38.15 MiB (preallocated) |
| C unsafe slotmap | 36 | 34.33 MiB (preallocated) |
| Proposed paged safe slotmap | 36 | 34.33 MiB peak committed; 7.96 MiB retained committed estimate |
| CLEAR pool | 52 | 49.59 MiB (preallocated) |
| CLEAR LINK/RESOLVE | 80 | 18.28 MiB requested |
| Rust Rc/Weak | 72 estimated | retained figure is only a lower bound |
| Go tracing GC | allocator-reported | 96.52 MiB peak heap, 41.99 MiB retained heap |

The paged dense segment keeps contiguous virtual addressing but decommits empty
4,096-node tail regions with `madvise(DONTNEED)` after swap-removal. `mincore`
measured payload residency falling from 26.71 MiB to 0.33 MiB after deleting
99%, so 98.8% of resident payload pages were returned. The 7.96 MiB retained
estimate includes fixed generation/free-slot metadata; 34.33 MiB of virtual
address space remains reserved. Collapse time rises from 3.98 ms for C's
non-reclaiming slotmap to 9.84 ms because reclamation now performs real kernel
work.

## Interpretation

The paged dense slotmap remains much faster than LINK/RESOLVE and Rust Rc/Weak,
and its sparse survivor iteration is dramatically better than a tombstone pool.
At 1M it is 14% faster than CLEAR's pool overall, 4% faster on random reads,
within 1% of Go's random reads, and 5% faster than C's unsafe slotmap on random
reads. Its remaining cache-resident penalty versus ideal direct-index C is the
unavoidable checked `logical slot -> dense position -> payload` chain.

After removing the redundant 16-byte allocator value from every non-atomic Rc
control block, CLEAR LINK/RESOLVE matches Rust phase by phase and is 1% faster
overall at 1M. CLEAR still scans sparse optional root arrays more slowly because
Zig represents `?Rc` as 16 bytes while Rust niche-optimizes `Option<Rc>` to 8;
that wrapper ABI is separate from edge traversal.

These numbers do not yet cover cleanup-bearing payloads, 99.9% collapse,
natural versus forced Go GC, or p99 operation latency. They are required by the
design acceptance gate and should not be inferred from this throughput matrix.
