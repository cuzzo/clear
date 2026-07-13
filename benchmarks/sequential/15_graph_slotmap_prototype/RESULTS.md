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
| 4,096 | 35.47 ms | 39.02 (1.10x) | 50.43 (1.42x) | 54.71 (1.54x) | 39.92 (1.13x) | 101.60 (2.86x) | 141.63 (3.99x) | 147.09 (4.15x) |
| 16,384 | 37.53 ms | 41.51 (1.11x) | 53.18 (1.42x) | 58.94 (1.57x) | 42.97 (1.15x) | 105.69 (2.82x) | 145.48 (3.88x) | 165.70 (4.42x) |
| 65,536 | 44.02 ms | 51.91 (1.18x) | 68.98 (1.57x) | 75.97 (1.73x) | 53.64 (1.22x) | 178.55 (4.06x) | 210.67 (4.79x) | 220.63 (5.01x) |
| 262,144 | 91.52 ms | 115.40 (1.26x) | 121.50 (1.33x) | 130.99 (1.43x) | 114.73 (1.25x) | 433.01 (4.73x) | 453.31 (4.95x) | 393.20 (4.30x) |
| 1,000,000 | 299.55 ms | 378.65 (1.26x) | 366.22 (1.22x) | 362.76 (1.21x) | 373.88 (1.25x) | 1,008.46 (3.37x) | 1,023.40 (3.42x) | 977.03 (3.26x) |

At DRAM scale the paged slotmap is 1.21x ideal direct-index C, slightly faster
than C's unsafe slotmap, and 4% faster than raw-pointer C. While compact C is
cache-resident it remains 1.43x–1.73x overall; the 1.15x expectation therefore
only describes the large memory-bound case, not a universal ratio.

## All scenarios at one million nodes

| Scenario | C u32 index | C raw pointers | C unsafe slotmap | Proposed safe slotmap | CLEAR pool | CLEAR LINK/RESOLVE | Rust Rc/Weak | Go GC |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Build | 18.57 ms | 25.60 | 22.45 | 21.08 | 26.57 | 63.41 | 63.11 | 85.83 |
| Local reads | 15.57 ms | 24.43 | 19.94 | 22.28 | 32.68 | 91.32 | 94.12 | 60.20 |
| Edge writes | 32.30 ms | 33.88 | 32.50 | 28.95 | 30.19 | 226.98 | 224.31 | 82.26 |
| Random reads | 226.79 ms | 287.43 | 277.78 | 267.68 | 273.19 | 435.16 | 450.53 | 257.54 |
| Vertex churn | 7.24 ms | 7.81 | 9.41 | 9.59 | 9.16 | 118.72 | 123.34 | 330.35 |
| Collapse to 1% | <0.001 ms | <0.001 | 3.84 | 9.42 | 1.56 | 65.09 | 66.75 | 152.35 |
| Sparse full scans | 0.076 ms | 0.088 | 0.335 | 0.310 | 45.53 | 68.75 | 45.54 | 59.91 |

Ratios for the proposed slotmap versus direct-index C are 1.14x build, 1.43x
local reads, 0.90x edge writes, 1.18x random reads, 1.32x churn, and 4.08x
sparse dense iteration. Collapse cannot have a meaningful ratio because ideal
C does no deletion work at all.

Random-read overhead is most severe while the compact C payload is cache
resident: the proposed slotmap is 2.11x C at 4K, 2.02x at 16K, 2.24x at 64K,
1.51x at 256K, and 1.18x at 1M. At large sizes both representations become
memory-latency bound, narrowing the ratio.

## Memory at one million capacity

| Implementation | Peak representation/requested bytes per capacity | Retained observation after collapse |
|---|---:|---:|
| C unchecked u32 index | 24 | 22.89 MiB (preallocated) |
| C raw pointers | 40 | 38.15 MiB (preallocated) |
| C unsafe slotmap | 36 | 34.33 MiB (preallocated) |
| Proposed paged safe slotmap | 36 | 34.33 MiB peak committed; 7.96 MiB retained committed estimate |
| CLEAR pool | 48 | 45.78 MiB (preallocated) |
| CLEAR LINK/RESOLVE | 80 | 18.28 MiB requested |
| Rust Rc/Weak | 72 estimated | retained figure is only a lower bound |
| Go tracing GC | allocator-reported | 96.52 MiB peak heap, 41.99 MiB retained heap |

The corrected direct Pool stores payloads, packed liveness/generation state,
and its free stack in separate arrays. This removes four bytes per capacity and
reduces a normalized sparse scan from 308.92 ms to 45.53 ms by scanning the
four-byte state sidecar instead of 48-byte tombstoned slots. It still retains
all 45.78 MiB after collapse because live values never move.

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
and its sparse survivor iteration remains dramatically better than the
corrected direct Pool. At 1M it is 3% faster than Pool overall and 2% faster on
random reads, while Pool is 12% faster overall at 262K and 29% faster at 65K.
The SlotMap's remaining cache-resident penalty versus direct Pool is the
checked `logical slot -> dense position -> payload` chain; its large-scale
crossover comes from four-byte edges, denser payloads, and reduced memory
traffic.

After removing the redundant 16-byte allocator value from every non-atomic Rc
control block, CLEAR LINK/RESOLVE matches Rust phase by phase and is 1% faster
overall at 1M. CLEAR still scans sparse optional root arrays more slowly because
Zig represents `?Rc` as 16 bytes while Rust niche-optimizes `Option<Rc>` to 8;
that wrapper ABI is separate from edge traversal.

These numbers do not yet cover cleanup-bearing payloads, 99.9% collapse,
natural versus forced Go GC, or p99 operation latency. They are required by the
design acceptance gate and should not be inferred from this throughput matrix.
