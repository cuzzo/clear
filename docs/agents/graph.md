# `@graph`: dense, handle-addressed cyclic storage

Status: **Draft / benchmark-gated**
Target: post-self-host baseline
Author: Language Architecture Team

## Executive decision

`@graph` should be a collection shape, not a new ownership mode on each node.
The viable surface is:

```clear
STRUCT WebNode {
    url: String,
    links: GraphId<WebNode>[]@list
}

FN main() RETURNS Void ->
    MUTABLE web: WebNode[100_000]@graph = [];

    home = web.insert(WebNode{ url: "https://clear.dev", links: [] });
    docs = web.insert(WebNode{ url: "https://clear.dev/docs", links: [] });

    IF web[home] AS node THEN
        node.links.append(docs);
    END
    IF web[docs] AS node THEN
        node.links.append(home); # a cycle is just two non-owning handles
    END

    web.remove(docs);             # destroys docs now
    ASSERT web[docs] == NIL, "stale handles resolve to NIL";
    RETURN;                       # destroys every remaining node, then the graph
END
```

This is intentionally close to the existing, working `@pool` surface. The
compiler already parses fixed-capacity collections, has generic handle types, annotates pool
methods through a registry, treats `get` as a container borrow, and lowers
collection initialization through structural MIR. `@graph` should extend those
paths rather than introduce pointer syntax or a second ownership system.

The feature does require a new Zig runtime container. The current
`CheatLib.Pool(T)` is not sufficient:

- it preallocates every payload slot;
- live payloads remain sparse after deletion;
- its `remove` does not destroy the removed payload;
- its handles directly encode the physical slot, so moving payloads would
  invalidate handles;
- it cannot return payload pages until the entire pool is destroyed.

The proposed runtime is a dense slot map: handles name stable logical slots;
logical slots map to movable dense payload positions. Removal destroys one
payload, swap-moves the last payload into the hole, updates one mapping entry,
and can decommit an empty tail region. There is no tracing and no graph walk.

This document does **not** accept the original performance table. Exact claims
such as “1.15x C,” “flat-line jitter,” or “lowest memory” are benchmark results,
not language semantics. The feature remains benchmark-gated by the matrix in
this document.

## Goals

1. Express cyclic topology without `@multiowned`, `@link`, `LINK`, or `RESOLVE`
   at every edge.
2. Make one affine graph container the lifetime owner of all vertices.
3. Destroy a removed vertex's owned payload exactly once, synchronously.
4. Destroy all remaining payloads deterministically when the graph leaves
   scope.
5. Keep insertion, checked lookup, edge assignment, and removal O(1).
6. Keep live payloads dense and decommit empty payload regions without an O(N)
   compaction pause.
7. Preserve CLEAR's existing allocator, ownership, borrow, MIR-checking, and
   backend invariants.
8. Approach an unsafe C slot map closely enough to beat `LINK`/`RESOLVE` by a
   meaningful margin on real graph workloads.

## Non-goals

- Reachability-based collection. A node remains alive until `graph.remove(id)`
  or destruction of the graph, even if no edge points to it.
- Owning edges. Adding or removing an edge never creates or destroys a vertex.
- Stable payload addresses. Handles are stable; pointers and borrowed aliases
  are not stable across graph mutation.
- Automatic maintenance of incoming edges. Removing a vertex may leave stale
  handles in other vertices; checked access returns `NIL`.
- Ordered iteration. Swap-remove changes dense iteration order.
- Lock-free parallel mutation in v1.
- Unbounded reuse from a compact 32-bit handle. Exhausted generations retire
  slots instead of wrapping.

## Why the outline's original surface does not fit CLEAR

This form is rejected:

```clear
links: WebNode@graph[]@list
```

Capabilities before `[]` describe each element's ownership/synchronization
wrapper. `@graph` instead describes the container that owns storage and the
namespace in which handles resolve. Edges therefore store `GraphId<WebNode>`, while
the root is `WebNode[N]@graph`.

This separation also prevents an accidental recursive representation. A
`WebNode` value is an ordinary payload; a graph edge is a small non-owning
handle, not another embedded or reference-counted `WebNode`.

## Semantics

### Ownership

An affine `T[N]@graph` owns:

- every live `T` payload;
- logical-slot metadata and generations;
- the logical free-slot stack;
- dense-to-logical reverse mappings;
- the committed dense payload prefix.

`GraphId<T>` does not own a node. It is freely copyable and may participate in
cycles. The graph container remains subject to CLEAR's ordinary move rules.

Initially, only affine `@graph` is required. A later
`T[N]@graph:shared:locked` composes with the existing ownership and
synchronization axes; operations occur under `WITH EXCLUSIVE`. It must not
invent graph-specific locking rules.

### Lookup and borrows

`graph.get(id)` and `graph[id]` return `?T`, matching `@pool`. A lookup checks:

1. the logical slot is in range;
2. the slot is live;
3. the handle generation equals the slot generation.

On success, lowering exposes a borrowed alias into dense storage. The existing
container-borrow rule must reject `insert`, `remove`, or any operation that can
move payloads while that alias is live. The alias cannot escape its binding
scope. No raw payload pointer is stored in user code.

`GraphId<T>` does not encode the identity of a particular graph. V1 may
retain that compatibility, but then passing an ID from graph A to graph B of
the same `T` is a logical misuse that is not detected. A container nonce or
compiler-tracked origin is a separate design decision and must be benchmarked:
adding an owner token makes a fully identified handle at least 64 bits and may
make it 16 bytes, materially changing graph memory and cache behavior. The
compact prototype must not claim cross-container identity safety.

### Removal and deterministic cleanup

Only `graph.remove(id)` removes a vertex. Rewriting an edge merely replaces an
integer handle.

For a valid handle, removal performs this sequence:

1. run the compiler-selected cleanup plan on the victim payload;
2. if the victim is not last, bitwise-move the last live payload into the
   victim's dense position;
3. update the moved payload's logical-slot metadata and reverse mapping;
4. decrement the live count;
5. mark the removed logical slot dead and increment its generation;
6. return the logical slot to the free stack;
7. decommit the now-empty tail payload region if a boundary was crossed.

The old tail position is left undefined and is **not** cleaned. Ownership was
moved, not copied. This is the critical exactly-once invariant.

Generation increment must not wrap. When a slot reaches the maximum generation,
the implementation retires that logical slot instead of making an ancient
handle valid again. This is stricter than the current pool's wrapping `u32` and
is required for an unqualified stale-handle safety claim.

Graph destruction walks the dense live payload sequence once, runs the same
cleanup plan on every payload, and then releases virtual segments and metadata. Scope exit
is therefore O(live nodes), not O(1). The destructors fire deterministically,
but claiming constant-time destruction of a non-empty owning container would be
false.

### Cleanup authority

The runtime's generic `cleanup(T, allocator, ptr)` handles many structural
types, but it is not sufficient authority for every compiler-known `CLOSE`
plan. `@graph` must not create a parallel cleanup classifier.

The annotator/cleanup classifier derives the element cleanup plan once from the
existing schema and ownership facts. MIR graph removal and graph destruction
carry that typed plan. Emission passes compiler-generated drop glue to the Zig
container, conceptually:

```zig
fn __clear_drop_WebNode(rt: *Runtime, alloc: Allocator, value: *WebNode) void {
    // Mechanical emission of the existing CleanupEntry/resource close plan.
}

graph.removeWith(rt, alloc, id, __clear_drop_WebNode);
graph.deinitWith(rt, alloc, __clear_drop_WebNode);
```

This keeps resource `CLOSE`, nested collection cleanup, RC release, and moved
guards under the same compiler authority used for locals and other containers.
The callback is compile-time-known and should inline for ordinary payloads.

## Runtime layout

Conceptually:

```zig
const GraphId = packed struct(u32) {
    slot: u20,
    generation: u12,
};

const Graph = struct {
    slot_meta: []u32,           // packed generation:12 + dense_index:20
    free_slots: []u32,
    dense_to_slot: []u32,
    dense_payload: []T,         // one contiguous reserved virtual range
    committed_dense_capacity: u32,
    live_count: u32,
    capacity: u32,
};
```

V1 reserves the all-ones dense index as the dead sentinel, so compact
`GraphId<T>` supports at most 2^20 - 1 logical slots and 2^12 - 1 reuse cycles
per slot. A slot is permanently retired at generation exhaustion; it never
wraps. Larger-capacity or effectively unbounded-churn graphs require a 64-bit
graph ID and must be benchmarked as a distinct representation.

Lookup is two dependent reads before the payload read: handle -> slot metadata
-> dense payload. The current pool performs handle -> physical slot. The new
indirection is the price of moving payloads without invalidating handles.

The runtime reserves one contiguous virtual range for payloads and one for the
reverse map. Insertion faults/commits pages as the dense tail enters them.
Removal swap-fills the dense prefix; whenever a 4,096-node tail region becomes
empty, the runtime decommits its payload and reverse-map pages without changing
their virtual addresses. The prototype uses Linux `madvise(DONTNEED)`;
production requires a platform abstraction with Windows decommit and the
appropriate macOS primitive. A fixed capacity remains part of v1
(`T[N]@graph`) because the parser and pool diagnostics already support it.

### Why there is no compaction sweep

The proposed dense representation is compact after every removal. Swap-remove
moves at most one payload and updates one mapping, so adversarial sparse
survivors cannot pin sparse payload pages. An O(N) threshold sweep would:

- add the exact latency spike the feature is meant to avoid;
- require an O(N) remap pass;
- duplicate a property maintained more cheaply by the dense invariant.

The trade-off is unstable iteration order. Applications requiring stable order
must maintain a separate order list or use another collection.

## Realistic performance and memory expectations

### Speed

There is no single graph slowdown factor.

- Dense linear iteration can approach a list and can beat a tombstoned pool.
- Handle traversal is expected to be slower than `@pool` lookup because of the
  additional logical-to-dense load.
- It should be substantially faster than `LINK`/`RESOLVE` when traversals would
  otherwise perform weak upgrades and strong releases at each edge.
- Random traversal at large sizes is dominated by cache misses. Wider handles
  and metadata can produce a sharp last-level-cache crossover.
- Mutation avoids RC balancing and is O(1), but cleanup-bearing payloads still
  pay their real destructor cost.

The corrected phase-separated 1M-capacity prototype, retaining 1% after
collapse, measured median-of-five combined times:

| Implementation | Combined time | Peak bytes/capacity |
|---|---:|---:|
| Ideal unchecked C `u32` indices | 307.3 ms | 24 |
| Proposed paged compact slot map | 365.8 ms | 36 |
| Unsafe C slot map | 374.9 ms | 36 |
| Ideal C raw pointers | 390.3 ms | 40 |
| CLEAR manual pool | 427.1 ms | 52 |
| Go pointers + forced GC | 1,027.3 ms | allocator-reported separately |
| CLEAR LINK/RESOLVE | 1,073.4 ms | 80 |
| Rust `Rc<RefCell>` / `Weak` | 1,085.3 ms | 72 estimated |

The CLEAR baselines call the real `Pool`, `Rc`, `WeakRc`, downgrade, upgrade,
and release runtime functions. Rust uses `Rc<RefCell<Node>>` and `Weak`. Go uses
ordinary strong pointers and includes a forced post-collapse `runtime.GC()` in
the timed region.

The original LINK result was invalid because `rcCreate` unconditionally ran
the allocation profiler in non-profile builds. That captured a stack trace and
took a global profiling lock for every node. Rc now uses one combined
allocation and an implicit weak reference during last-strong cleanup. A second
layout fix removed the redundant 16-byte allocator stored in every non-atomic
control block; cleanup already carries allocator provenance. In matched
median-of-five runs, CLEAR now tracks Rust phase by phase and is about 1% faster
overall. CLEAR uses 80 requested bytes per capacity versus Rust's estimated 72;
the remaining difference is primarily Zig's 16-byte `?Rc` wrapper versus
Rust's 8-byte niche-optimized `Option<Rc>`.

Against ideal unchecked direct-index C, the paged slot map is 1.19x overall at
1M. Random traversal is 1.18x ideal C, 5% faster than C's unsafe slot map, and
within 1% of Go. While compact C remains cache-resident, random traversal is
still 1.55x–2.08x ideal C; no universal 1.15x claim is supported.

Before deletion, random handle traversal is slower than pool because
`GraphId -> dense index -> payload` is a dependent two-load chain while pool
directly names its slot. Compact IDs reduce bandwidth but cannot remove that
latency. After 99% deletion, the normalized sparse scan takes 0.315 ms in the
slotmap versus 308.9 ms in pool: dense survivor iteration is about 981x faster.
It is still 4.04x ideal C's vectorized dense scan in absolute terms. The feature
is therefore compelling for sparse/churned graphs, not as a universal
replacement for a dense pool.

After 99% deletion at 1M capacity, `mincore` measured resident payload pages
falling from 26.71 MiB to 0.33 MiB: 98.8% returned. Fixed logical metadata keeps
the retained committed estimate at 7.96 MiB, and 34.33 MiB of virtual address
space remains reserved. Real reclamation increases collapse from 3.98 ms in
C's non-reclaiming slot map to 9.84 ms in the proposed implementation.

### Memory

A deleting graph cannot safely use a plain 32-bit offset: it needs generation
state to prevent slot-reuse ABA. V1 packs a bounded generation and slot into 32
bits, then retires exhausted slots. This preserves the compact four-byte edge
at the cost of a 1,048,575-node ceiling and 4,095 reuse cycles per slot. A
64-bit variant removes those practical bounds but materially enlarges the
working set and must be measured separately.

At peak, `@graph` is not guaranteed to use less memory than `@pool`. It adds a
reverse map; its advantage is dense payload iteration and the ability to
decommit empty dense-tail pages after deletions. Fixed-capacity logical
metadata remains allocated, so “free almost all memory” means most **payload**
memory, not literally every byte of the graph container.

Compared with `LINK`/`RESOLVE`, the graph should avoid per-node control blocks,
strong/weak counters, allocator headers, and individual allocations. That is a
plausible substantial memory win, but it must be measured with the real CLEAR
runtime allocator.

### Latency

No tracing or O(N) compaction occurs during mutation. Individual remove cost is
bounded by payload cleanup, one optional swap, and tail-page decommit syscalls.
Allocator decommit/free latency and arbitrary user resource destructors are not
constant-time. “Zero pause” and “perfect flat line” are therefore prohibited
claims. Benchmarks must report p50, p99, maximum operation/batch time, and page
faults rather than only total throughput.

## Benchmark acceptance gate

The feature is accepted only after one harness compares the same topology and
operation stream across:

1. current CLEAR `T[N]@pool` with explicit `Id<T>` edges;
2. current CLEAR `@multiowned` + `@link`, exercising real `LINK` and `RESOLVE`;
3. the proposed paged/decommitting dense graph runtime;
4. an unsafe C implementation with the minimum representation required by the
   same stable-ID operations;
5. idiomatic Go pointer topology under the tracing GC, reporting both natural
   collections and an explicit post-collapse `runtime.GC()` run.

Do not compare a deleting stable-ID graph to a C representation that silently
changes node identity after compaction. If C omits generation checks, label it
as an unsafe lower bound and report its smaller handle width.

### Sizes

Test at payload working sets bracketing cache levels, not only node counts:

- approximately 32 KiB;
- 256 KiB;
- 1 MiB;
- detected/shared LLC fractions (25%, 50%, 100%, 200%);
- at least one DRAM-scale case.

The checked-in default may use 4K, 16K, 64K, 256K, and 1M nodes, but the report
must also translate them into actual bytes for each representation.

### Workloads

1. **Local read-heavy:** fixed out-degree, neighboring targets, repeated edge
   traversal. Exposes best-case cache behavior.
2. **Random read-heavy:** fixed out-degree, deterministic random targets.
   Exposes lookup indirection and LLC/DRAM crossover.
3. **Edge write-heavy:** repeatedly replace edges. `LINK`/`RESOLVE` must perform
   real weak release/downgrade; integer-handle variants perform assignment.
4. **Vertex churn:** remove and reinsert an unreferenced subset. Exercises
   generation checks, free lists, payload moves, allocation, and RC teardown.
5. **Burst collapse:** grow to peak, then remove 99% and 99.9%. Record peak and
   retained requested bytes, RSS, and allocator/syscall behavior.
6. **Adversarial sparse survivors:** retain nodes selected uniformly across
   original allocation order. Verifies that payload pages still decommit
   under swap-remove and that no sparse page pinning remains.
7. **Cleanup-bearing nodes:** nested lists/strings plus a counted resource drop.
   Verify immediate exactly-once destruction separately from raw speed.
8. **Mixed service trace:** 90/9/1 read/edge-write/vertex-churn and a bursty
   phase. Report p99/max batch latency, not just mean throughput.

### Metrics and provisional thresholds

Report operations/second, ns/edge, build time, teardown time, p50/p99/max batch
latency, peak/current requested bytes, peak/current RSS, allocations, frees,
minor faults, LLC misses, and branch misses.

The initial go/no-go thresholds are deliberately explicit and revisable:

- `@graph` is at least 1.5x faster than real `LINK`/`RESOLVE` on random reads,
  edge writes, and the mixed trace once the working set reaches LLC;
- peak requested bytes are no more than 1.25x manual pool and materially below
  `LINK`/`RESOLVE` for the same topology;
- after 99% collapse, retained payload bytes are proportional to live payloads
  plus fixed logical metadata, with no sparse payload-page retention;
- local reads remain within 20% of manual pool unless the memory-reclamation
  win is large enough to justify a documented trade-off;
- no mutation contains an O(N) compaction path.

If those gates fail, `@graph` should remain library/runtime experimentation.
Ergonomics alone does not justify a second collection primitive.

The prototype lives in
`benchmarks/sequential/15_graph_slotmap_prototype/`. Its current Zig-vs-C
comparison validates the basic generational slot-map cost. The next benchmark
revision must implement this full matrix before the feature is approved.

## Ergonomics and fit with CLEAR

The proposal aligns well with CLEAR when the graph has one architectural owner:

- one capability at the storage boundary instead of ownership syntax on every
  edge;
- ordinary `GraphId<T>` values express topology and cycles;
- checked optional access makes deletion visible;
- deterministic cleanup follows lexical container ownership;
- changing storage from `@pool` to `@graph` is conceptually small;
- costs remain visible: `@graph` says handle lookup and movable dense storage,
  while `@shared:locked` still says synchronization.

It does not replace `@link`. `@link` remains appropriate when independently
owned objects have unrelated lifetimes, can escape the graph domain, or must
remain alive without one root container. `@graph` is appropriate for ECS-like
worlds, syntax/IR graphs, routing topologies, UI trees with back-pointers, and
request-scoped object networks whose vertices share a lifecycle domain.

The optional lookup is necessary and consistent with `@pool`; hiding it would
make deletion races and stale edges implicit. Ergonomics improve by removing
per-edge RC ceremony, not by pretending stale handles cannot exist.

### Representation choices and recommended default

No one representation wins every graph workload. CLEAR should expose one
topology abstraction while keeping its important lifecycle choice explicit:

| Representation | Wins when | Pays for |
|---|---|---|
| Dense slot map (this proposal) | deletion, churn, sparse survivors, full-node iteration | an extra dependent metadata load on handle traversal |
| Existing generational pool | graphs stay dense and traversal follows random handles | tombstone scans and retained sparse payload storage |
| Non-moving chunked slab | stable addresses and read-heavy random traversal dominate | fragmentation and poor sparse iteration/reclamation |
| Arena/bump graph | topology is built once and discarded as a unit | no individual deletion or stale-handle reuse |
| `LINK`/`RESOLVE` | nodes escape the container or have independent lifetimes | allocation, counters, upgrades, and larger working sets |

The dense slot map is the best **general default for a closed, mutable graph**
only if the paged prototype passes the acceptance gate. It is not a universal
replacement for `@pool`, `@arena`, or `@link`. In particular, a dense graph
whose dominant operation is random edge traversal should continue to be able
to use `@pool`; in the corrected 1M run the slot map is about 10% slower overall
and its random-traversal phase about 35% slower than the pool.

The direct-pool alternative is not an implementation of this `@graph`
contract. A physical-slot handle cannot survive arbitrary payload movement
unless the runtime rewrites all incoming edges or introduces a forwarding
mapping. The former creates an O(E) compaction pause and the latter recreates
the slot-map lookup. `@pool` may continue to expose that explicit fragmentation
trade-off, but `@graph` requires movable payloads and logical-to-physical
indirection.

V1 should not switch layouts automatically at runtime. Migrating between a
pool and dense slot map would invalidate performance assumptions, complicate
latency guarantees, and either rewrite every edge or preserve the same
indirection. Instead:

1. keep `@pool` available as the explicit dense/direct-lookup choice;
2. make `@graph` the dense-survivor/churn-optimized closed-topology choice;
3. keep `@link` for open lifetime domains;
4. use the existing arena model when whole-graph reset is sufficient.

After the full matrix, a later release may add an explicit `@graph` layout
modifier for a non-moving slab or arena-backed graph. It should be justified by
a common workload that cannot already be expressed cleanly with `@pool` or
`@arena`; adding policy syntax merely to hide a benchmark trade-off would work
against CLEAR's goal of visible, predictable costs.

## Compiler implementation plan

### G1: Characterize and fix pool cleanup first

Before adding a collection, add a regression proving that removing a
cleanup-bearing pool element destroys it exactly once. The current
`Pool.remove` only marks the slot dead. Fixing or explicitly documenting that
existing bug is prerequisite evidence for graph cleanup design.

### G2: Parse and type the collection shape

- Add `@graph` to `CAPABILITY_TOKENS` and
  `CAPABILITY_COLLECTION_VALUES` in `compiler/ruby/ast/parser.rb`.
- Store it as `TypeCapabilities.collection == :graph`.
- Add `Type#graph?` and include it in the centralized collection predicates,
  heap backing, pointer passing, dispatch key, and capability conflict table.
- Require a fixed positive capacity and reject `@graph:soa` initially.
- Lower bare Zig type to `CheatLib.Graph(T)`; do not model graph as ownership or
  layout.

### G3: Registry and semantic facts

- Add `GRAPH_METHODS` or generalize the pool registry into an explicitly named
  handle-collection registry. Do not hard-code graph method names in lowering.
- `insert` consumes `T` on success and returns `GraphId<T>`.
- `get`/index return a borrowed `?T` and stamp `container_borrow`.
- `remove` mutates the receiver and carries the compiler-derived element
  cleanup fact.
- Reuse current borrow diagnostics so graph mutation is rejected while a
  payload alias is live.

### G4: Structural MIR

- Add a `:graph` `ContainerInit` strategy or a dedicated structural graph init
  node with explicit allocator and capacity.
- Represent remove/destruction with typed cleanup operands. Do not emit an
  opaque `InlineZig` call that hides ownership effects.
- MIR lowering remains the only allocator/cleanup decision owner.
- MIRChecker verifies allocation/cleanup pairing and the element cleanup fact;
  it does not infer graph policy from names or Zig types.
- MIREmitter mechanically renders the already-decided runtime calls.

### G5: Zig runtime

- Implement the paged dense slot map in `zig/lib/data-structures.zig`.
- Re-export through `CheatLib` in `zig/runtime/runtime-header.zig`.
- Implement non-wrapping generations, checked get, insert, callback-driven
  remove, callback-driven deinit, dense iteration, and tail-page decommit.
- Add reserve/commit/decommit failure tests and platform-specific VM tests.
- Add stale-handle, repeated-remove, moved-payload cleanup, page-boundary,
  generation-retirement, and adversarial-survivor tests.

### G6: Pipelines, FSMs, and MiniVM

- Add `:graph_indexed` to the centralized `Type#fsm_foreach_descriptor`; do not
  teach the FSM splitter graph-specific semantics.
- Pipelines iterate the dense payload prefix and make no ordering guarantee.
- Add structural MiniVM graph operations. The MiniVM must never parse rendered
  Zig or `InlineZig` to recover graph behavior.
- If MiniVM support is staged, reject `@graph` with an explicit backend
  diagnostic rather than silently modeling it as a list.

### G7: Tests and documentation

- Parser/type/capability conflict specs.
- Annotator borrow and cross-container misuse characterization.
- MIR ownership/allocator/cleanup invariant specs.
- Runtime unit and fault-injection tests.
- End-to-end transpile tests with cycles, stale edges, nested owned fields,
  explicit resources, early return, error paths, and graph moves.
- The complete benchmark gate above, including `perf` counters and memory
  collapse.
- Update `docs/collections.md`, `docs/WALKTHROUGH.md`, formatter syntax, editor
  grammars, and the fuzz ownership-surface registry only after behavior lands.

## Open decisions

1. Is cross-container `GraphId<T>` misuse accepted for v1, rejected by
   compiler origin tracking, or prevented with a wider runtime owner token?
2. What decommit-region size wins across small and large `T`? This must be
   chosen by the benchmark matrix, not fixed at the prototype's 4,096 nodes.
3. Should metadata be decommittable after peak-collapse measurements, or is fixed
   logical metadata an acceptable bounded cost?
4. Does dense iteration expose a mutable alias, an immutable value, or both?
5. Is `@graph:shared:locked` part of v1 or a follow-up after affine semantics
   stabilize?
6. Should generation exhaustion retire a slot permanently or promote that
   graph instance to a wider handle representation?

## Final recommendation

Advance the paged segment into a tested Zig runtime component, but do not yet
commit to the language surface.

Architecturally, the dense slot-map design fits CLEAR better than pervasive
`LINK`/`RESOLVE` for closed-lifecycle graphs. It provides deterministic RAII and
excellent ergonomics without tracing or reference counts. The prototype now
demonstrates competitive DRAM-scale traversal and actual payload-page return.
Cache-resident checked traversal, cleanup-bearing payloads, decommit latency,
and non-Linux platform behavior remain acceptance risks. The feature is the
right choice only if the production runtime clears the remaining published
gates.
