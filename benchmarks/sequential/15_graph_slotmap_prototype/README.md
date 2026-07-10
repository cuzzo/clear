# Graph slot-map prototype

This directory contains both the runtime-design matrix and the end-to-end
CLEAR `@node` acceptance benchmark. It compares:

- `bench.zig`: the proposed safe core — dense payload storage, a logical-slot to dense-index table, compact bounded-generation handles, checked lookup, and O(1) swap-remove;
- `bench_clear_runtime.zig`: CLEAR's actual `CheatLib.Pool(T)` and the actual `Rc`/`WeakRc` primitives used by `@multiowned`, `LINK`, and `RESOLVE`;
- `bench.rs`: idiomatic safe Rust `Rc<RefCell<Node>>` plus `Weak<RefCell<Node>>` edges;
- `bench.go`: ordinary Go pointer topology under the tracing GC; a forced post-collapse GC is included in the timed region;
- `bench.c`: three unsafe C lower bounds — unchecked direct `u32` indices,
  raw pointers, and the same dense slotmap without generations. Only the last
  preserves its logical handle mapping; none provides equivalent stale-ID
  safety.
- `bench_node.clear`: idiomatic object-style CLEAR using `@node`; this goes
  through the real parser, annotator, MIR verifier, and Zig backend;
- `bench_node_manual.zig`: the equivalent safe workload written directly
  against `PagedSlotMap`, including nullable-edge checks and checked checksum
  arithmetic.

The workload initializes four edges on every node, performs normalized local
and random traversal, rewrites edges, churns the unreferenced quarter, collapses
to 1% live, and scans sparse survivors. Keeping churn nodes out of the traversed
core avoids giving unsafe stale-handle aliasing different logical results.

Run it with:

```bash
benchmarks/sequential/15_graph_slotmap_prototype/run.sh
BENCH_SCALE=0.25 RUNS=3 benchmarks/sequential/15_graph_slotmap_prototype/run.sh
RUNS=5 benchmarks/sequential/15_graph_slotmap_prototype/run_matrix.sh
RUNS=7 benchmarks/sequential/15_graph_slotmap_prototype/run_node.sh
```

## End-to-end `@node` result

On the pinned one-million-node acceptance workload (five interleaved
ReleaseFast runs), medians were:

| implementation | build | reads | rewrites | timed reads+writes |
|---|---:|---:|---:|---:|
| idiomatic CLEAR `@node` | 33 ms | 137 ms | 17 ms | 154 ms |
| manual safe Zig `PagedSlotMap` | 16 ms | 118 ms | 14 ms | 132 ms |

Both produced checksum `4000084000000`. With bounds-safe `@list` reads enabled,
idiomatic CLEAR is 1.17x the manual Zig time in the steady-state phases and
1.26x when construction is included (187 ms versus 148 ms). Peak RSS in a
separate run was 34,376 KiB for CLEAR and 33,024 KiB for manual Zig (+4.1%,
primarily fixed Runtime overhead). The comparison now charges CLEAR for the
language-level optional checks at every `@list` index; the manual version uses
its known-in-range sidecar array directly before each slot-map lookup.

The CLEAR build cost is higher because the implicit store begins at 4,096
slots and grows to the compact-handle maximum while preserving handles; the
manual benchmark reserves maximum capacity immediately. This avoids charging
small graphs roughly 8 MiB of metadata just for using `@node`.

Every program prints internal phase times, capacity/virtual-memory estimates,
and checksums. The Zig prototype reserves contiguous dense arrays, swap-removes
survivors into their prefix, and decommits empty 4,096-node tail regions. On
Linux the benchmark uses `madvise(DONTNEED)` and verifies actual payload-page
residency with `mincore`; production needs equivalent Windows and macOS paths.

The current prototype uses a 32-bit compact generational ID: 20 logical-slot
bits and 12 generation bits. A slot is retired rather than wrapped after 4,095
reuse cycles. The dead dense-index sentinel caps the prototype at 1,048,575
logical slots and makes
bounded reuse an explicit cost of the compact representation. C uses a plain
unsafe 32-bit slot with no stale-handle protection.

## Preliminary results

The corrected phase-separated, cache-scale results are in [RESULTS.md](RESULTS.md).
At one million nodes the paged safe slotmap takes 362.76 ms versus 299.55 ms for
ideal unchecked direct-index C: 1.21x overall. Random traversal is 1.18x ideal
C and 2% faster than the corrected CLEAR Pool. Cache-resident random reads
remain 1.51x–2.24x ideal C because checked stable IDs require the
handle-to-dense dependency.

The corrected Pool now uses separate payload, packed state, and free-stack
arrays; removal performs exact-once cleanup and generations retire instead of
wrapping. It drops from 52 to 48 bytes per capacity in this workload and its
sparse scan improves from 308.92 ms to 45.53 ms. Pool wins the combined trace
through 262K nodes; SlotMap crosses over at 1M and wins there by 3%, while
retaining 7.96 MiB after collapse versus Pool's 45.78 MiB.

The corrected CLEAR Rc implementation now matches idiomatic Rust phase by
phase and is about 1% faster overall at 1M. The prior 1,526 ms LINK number was invalid because
`rcCreate` accidentally captured a stack trace and took a global profiling
lock in non-profile builds. That runtime bug is fixed by a comptime profile
gate; Rc now also uses one combined allocation, an implicit weak count for safe
self-link destruction, and allocator-threaded cleanup instead of a 16-byte
allocator value in every control block.

These runs use real CLEAR `Pool`, `Rc`, `WeakRc`, downgrade, upgrade, and
release helpers. Rust uses safe `Rc<RefCell<Node>>` and `Weak`; Go uses strong
pointers and includes an explicit `runtime.GC()` after collapse. Requested
memory remains allocator-specific. The paged dense segment now returns empty
tail pages while retaining contiguous addressing: measured payload residency
falls from 26.71 MiB to 0.33 MiB after deleting 99% at one million capacity.

## Required next matrix

This prototype is not the feature acceptance benchmark. The next revision must
separate local reads, random reads, edge rewrites, vertex churn, 99%/99.9%
burst collapse, sparse survivors, and cleanup-bearing payloads. Each operation
stream must run against:

1. the real CLEAR `@pool` runtime;
2. real CLEAR `@multiowned` + `@link`/`RESOLVE`;
3. the paged/decommitting dense slot map;
4. idiomatic safe Rust `Rc<RefCell>` / `Weak`;
5. Go tracing GC with natural and forced-collection variants;
6. the unsafe C lower bound.

See `docs/agents/graph.md` for sizes, metrics, and provisional go/no-go
thresholds. Until that matrix exists, these numbers establish only that the
basic representation works and that cache size materially changes the answer.
