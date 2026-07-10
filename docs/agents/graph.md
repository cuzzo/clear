# `@node`: object-style cyclic topology on compact slot-map storage

Status: **Implemented v1 surface; explicit deletion remains follow-up**

## Decision

CLEAR models a graph edge as a capability on the referenced value:

```clear
STRUCT Node {
  left: ?Node@node,
  right: ?Node@node,
  children: Node@node[]@list,
  id: Int64
}

FN main() RETURNS Void ->
  MUTABLE root: Node@node = Node{ id: 1 };
  root.left = Node{ id: 2 };
  root.children.append(Node{ id: 3 });

  ASSERT root.left?.id == 2;
  ASSERT root.children[0]?.id == 3;
END
```

The public model is an object reference, not a pool and not `GraphId<T>`.
Once a destination is declared `T@node`, assigning a plain `T` constructs a
vertex in the compiler-inferred store. Assigning an existing `T@node` copies
its compact handle. Field access and list indexing resolve handles
automatically.

This fits CLEAR's “decision at declaration time” rule: the field, parameter,
list element, or binding chooses the representation once; every assignment
inherits that choice.

`NODE STRUCT` is unnecessary. A struct may mix ordinary value fields,
`@node` edges, `@link`, or other capabilities. Plain `Node{...}` remains a
normal value until expected-type coercion places it at an `@node` destination.

## Goals

1. Ruby/Go-style construction and traversal for cyclic data.
2. Four-byte typed edges, including nullable edges.
3. Stable, stale-detecting handles while payloads move during swap-remove.
4. Dense payload iteration and tail-page reclamation.
5. No reference counts, weak upgrades, tracing, or write barriers on traversal.
6. Deterministic payload cleanup through the existing CLEAR cleanup authority.
7. Runtime and compiler overhead close to direct safe Zig PagedSlotMap use.

## Non-goals and v1 limits

- An edge does not own a vertex independently. The inferred store owns every
  payload.
- Replacing an edge does not delete the old target; other edges may still name
  it.
- Reachability collection is not performed.
- Payload addresses are unstable across insertion, growth, and removal.
- Handles are limited to 20 slot bits and 12 generation bits: at most
  1,048,575 slots and 4,095 reuse generations per slot. Exhausted slots retire
  instead of wrapping.
- The language surface for explicit early vertex deletion is not part of this
  patch. The runtime already supports exact-once `remove`; a later surface
  decision should add `DROP node` or an equivalent operation without exposing
  the store.

## Type and coercion rules

`T@node` is a copyable, non-owning reference to a `T` payload in the inferred
`(Runtime, T)` store. It is not layout-compatible with `T`.

Expected-type coercion applies at:

- typed declarations;
- field assignment;
- struct literal fields;
- function arguments;
- `@list` append/push/insert when its element type is `T@node`.

Given a destination `T@node` or `?T@node`:

- plain `T` becomes `NodeStore(T).create(payload)`;
- existing `T@node` copies directly;
- `NIL` becomes the zero handle for `?T@node`;
- any other payload type is a compile-time mismatch.

Optional node fields default to NIL. `@list` fields default to an empty list,
which permits the ergonomic `Node{ id: 2 }` form shown above. A non-optional
node reference still requires an explicit value.

## Physical representation

Both `T@node` and `?T@node` lower to:

```zig
packed struct(u32) {
    encoded: u32, // zero = NIL, otherwise PagedSlotMap handle + 1
}
```

Using an in-band NIL sentinel avoids Zig's optional tag, so nullable graph
edges remain four bytes. The maximum PagedSlotMap handle cannot be
`0xffffffff`, making wrapping addition safe for the sentinel encoding.

Payload storage is the existing `PagedSlotMap(T)`:

```text
handle(slot, generation)
        |
        v
slot_meta[slot] = (generation, dense_index)
        |
        v
dense_payload[dense_index]
```

The map also stores `dense_to_slot` and a logical free-slot stack. Removal
cleans one payload, swap-moves the dense tail into the hole, fixes one reverse
mapping, advances the removed slot generation, and decommits newly empty tail
regions. No topology walk or compaction sweep occurs.

The inferred store starts at 4,096 slots and doubles while preserving every
handle. This avoids an approximately 8 MiB metadata floor for tiny graphs.
Growth moves payload storage and is O(live nodes); callers may avoid growth in
a future capacity-hint surface. Steady-state insert, lookup, rewrite, and
remove remain O(1).

## Store ownership and Runtime isolation

There is one hidden store for each `(Runtime instance, payload type)`. A
process-global type registry finds it, keyed by a monotonic Runtime identity;
the registry is locked only on a cache miss or store creation. This avoids the
incorrect alternatives of:

- one process-global unsynchronized map for all programs/fibers; or
- one thread-local map, which breaks when a fiber migrates between workers.

Every store registers a type-erased finalizer with its owning Runtime as a
shutdown safety net. Runtime deinitialization runs finalizers in reverse
registration order before its allocators disappear.

Generated functions bind each used node type once:

```zig
const __node_store_Node = try CheatLib.NodeStore(Node).bind(rt);
defer CheatLib.NodeStore(Node).releaseBound(__node_store_Node);
```

`bind` acquires a lexical lease and the generated `defer` releases it. The
outermost release clears the store synchronously. All hot operations use the
local `*PagedSlotMap(Node)` through inline
`createBound`/`getBound` helpers. The registry/TLS lookup is therefore outside
loops and function-local performance approaches hand-written Zig.

Functions that accept or return node handles receive CLEAR's normal hidden
`rt` parameter. Calling code threads it automatically; users never pass a
store or Runtime.

## Cleanup and RAII

The handle is Copy and the store is the payload owner.

- Each node-using function holds a store lease. Releasing the outermost lease
  deterministically destroys all remaining live vertices before returning to
  its caller, including cycles.
- Runtime teardown remains a safety net for direct runtime users that create
  nodes without compiler-generated lexical bindings.
- Runtime `remove` destroys the selected payload synchronously and exactly
  once.
- Swap-moved payloads are not cleaned at the old dense tail position.
- Nested strings, lists, maps, resources, RC values, and compiler-known
  recursive cleanup use the existing cleanup machinery rather than a
  graph-specific destructor system.

Individual root handles do not own vertices and therefore do not run payload
cleanup. The graph is reclaimed as one store at the outermost lexical lifetime
boundary; this avoids both reference counting on edges and topology tracing.

## Safety

Lookup rejects:

1. NIL;
2. out-of-range slots;
3. dead slots;
4. generation mismatches;
5. dense indices outside the live prefix.

Safe navigation (`node.left?.id`) resolves the node and propagates NIL. One
guard covers a continuous chain of non-optional members; another `?.` is only
needed when a later member or an indexed `@list` read introduces a new
optional boundary.
Non-optional access unwraps the checked lookup; a stale handle on that path is
a failed program invariant, not memory corruption.

`@node` remains affine/local in v1. Sharing the same store concurrently would
need an explicit synchronization capability and benchmarked locking or shard
policy; the compiler must not silently treat node payload mutation as shared.

## End-to-end performance result

The acceptance benchmark lives in
`benchmarks/sequential/15_graph_slotmap_prototype/` and runs real idiomatic
CLEAR against equivalent safe hand-written Zig. It builds one million nodes,
forms a randomized edge topology, performs eight full read passes, and four
full edge-rewrite passes. Both variants use nullable-edge validation, checked
slot-map lookup, and checked checksum arithmetic.

Seven interleaved pinned ReleaseFast runs produced these medians:

| implementation | build | reads | rewrites | reads + rewrites |
|---|---:|---:|---:|---:|
| idiomatic CLEAR `@node` | 34 ms | 108 ms | 16 ms | 124 ms |
| manual safe Zig PagedSlotMap | 16 ms | 119 ms | 15 ms | 134 ms |

Checksums matched at `4000084000000`. The CLEAR steady-state trace was 7.5%
faster in this run; construction was slower because the automatic store grows
from 4,096 slots while manual Zig reserves maximum capacity immediately.
Including build, CLEAR was 158 ms versus 150 ms, or 1.05x manual Zig.

Peak RSS was 34,388 KiB for CLEAR and 33,024 KiB for manual Zig (+4.1%), which
is roughly similar memory at this scale and includes CLEAR's fixed Runtime.

These results supersede the speculative “1.15x C” table for the language
surface. The broader runtime matrix still compares PagedSlotMap, Pool,
LINK/RESOLVE, Rust Weak, Go GC, and unsafe C across cache sizes, churn,
collapse, and sparse-survivor workloads. The current language acceptance
benchmark covers construction, traversal, and rewrite; it must gain the same
churn/collapse phases when explicit node deletion is exposed.

## Why this is preferable to exposing Pool or SlotMap

PagedSlotMap is a better backend for movable graph payloads than the old Pool,
but it is not a better user model. Exposing `insert`, IDs, and `get` merely asks
users to write allocator plumbing in another form.

`@node` keeps the valuable representation and removes the incidental API:

- users create objects, not slots;
- fields state topology directly;
- cycles are ordinary assignments;
- the compiler owns store selection, coercion, resolution, and cleanup;
- the generated hot path is still the same dense generational slot map.

That combination—high-level graph syntax with a measured low-level
representation—is the part aligned with CLEAR's design goals.
