# Observables Design

## Motivation

Stream pipeline aggregates (SUM, MAX, DISTINCT, etc.) maintain a running accumulator
as items flow through. Two use cases require different access patterns:

- **Final value**: block until the stream is exhausted, return the scalar or collection.
  This is the current behavior for all fold terminals.
- **Live observation**: read the current accumulator state from another fiber while the
  stream is still running. This requires a new capability.

The naive approach - returning a live reference to the accumulator - recreates Rust-style
lifetime tracking and leaks viral complexity into every function signature. The solution
is to make observability a **type-level capability** (`@observable`) with two access
forms: `WITH VIEW` (cheap, borrow) and `WITH MATERIALIZED VIEW` (explicit copy).

---

## The `@observable` Capability

`@observable` is a capability qualifier on tense stream aggregate types. It signals that
the backing accumulator is structurally guaranteed to support cheap observation:

- **Atomic scalars**: a single atomic value, updated per item. Reads are lock-free.
- **Append-only linear structures**: a stable backing buffer that never moves existing
  elements. A VIEW is a slice into the buffer at the current length. Valid because
  elements are never modified or removed, only appended.

`@observable` is NOT a default property of `~T`. A regular `BG { foo() }` returns `~T`
(a Promise - one value resolved once). It has no accumulator to observe. `@observable`
is only produced by specific pipeline terminals that explicitly maintain running state.

---

## Phase 1: Pipeline Observables

### Terminals that produce `~T@observable`

| Terminal | Accumulator type | Backing |
|---|---|---|
| `SUM _` | `~Float64@observable` | atomic float |
| `MAX _` | `~Int64@observable` | atomic int |
| `MIN _` | `~Int64@observable` | atomic int |
| `COUNT _` | `~Int64@observable` | atomic int |
| `AVG _` | `~Float64@observable` | two atomics (sum + count) |
| `ANY _` | `~Bool@observable` | atomic bool |
| `ALL _` | `~Bool@observable` | atomic bool |
| `FIND _` | `~?T@observable` | atomic optional |
| `DISTINCT` | `~T[]@set@observable` | append-only array + lookup |
| `REDUCE (scalar acc)` | `~T@observable` | atomic value |

### Terminals that produce plain `~T` (no observable)

| Terminal | Reason |
|---|---|
| `INDEX _.key` | HashMap bucket array rehashes; per-key lists reallocate |
| `REDUCE (collection acc)` | Accumulator has moving internal structure |

### `BG {}` blocks

Never `@observable`. A Promise resolves once. There is no running state to observe.

---

## WITH VIEW (cheap, for @observable only)

`WITH VIEW v AS binding` borrows the current accumulator state without allocation.

```ruby clear
running_sum:      ~Float64@observable = orders s> SUM _.amount
running_distinct: ~String[]@set@observable = events s> DISTINCT _.category

-- Scalar: atomic read, binding is ?Float64 (copy)
WITH VIEW running_sum AS s ->
    print(s ?? "not started");
END

-- Collection: stable slice, binding is ?String[]@set (immutable borrow)
WITH VIEW running_distinct AS s ->
    print(s?.length() ?? 0);
    s?.insert("x");             -- COMPILE ERROR: immutable borrow
END
```

Rules:
- Only valid on `~T@observable`. Compiler error otherwise.
- Binding is always `?T` (NIL until the first item has been processed).
- Binding is immutable. No mutation through VIEW, ever.
- For slices: the binding does not escape the block (non-escaping, same as BORROWED).
- For scalars: the binding is a copy; the block is syntactic consistency, not a lifetime scope.

---

## WITH MATERIALIZED VIEW (explicit copy, for all ~T)

`WITH MATERIALIZED VIEW v AS binding` takes an owned snapshot. Always allocates.
Required for non-observable aggregates. Also valid on `@observable` when you need
a stable owned copy that outlives the stream.

```ruby clear
running_index: ~Item[]@map = events s> INDEX _.category

-- Non-observable: compiler requires MATERIALIZED
WITH VIEW running_index AS m ->          -- COMPILE ERROR: not @observable
    ...                                  -- "use WITH MATERIALIZED VIEW"
END

WITH MATERIALIZED VIEW running_index AS m ->
    print(m["fruit"]?.length() ?? 0);   -- m: ?Item[]@map, owned copy
END                                      -- freed here

-- Also valid on @observable when you need an owned copy
WITH MATERIALIZED VIEW running_distinct AS s ->
    results = s;    -- can store/return: it's owned, not a borrow
END
```

Rules:
- Valid on any running `~T` aggregate (observable or not).
- Binding is always `?T` (NIL until first item processed).
- Binding is owned. Caller is responsible for cleanup.
- Binding can escape the block (it's a value, not a borrow).
- Cost is O(n) for collections. The word MATERIALIZED in the syntax is intentional -
  it makes the allocation visible at the call site.

---

## Runtime Implementation

### Atomic scalars (`~Int64@observable`, `~Float64@observable`, etc.)

The stream aggregate struct holds an `std.atomic.Value(T)` alongside the stream state.
Each emitted value writes to the atomic. `WITH VIEW` is a single atomic load.

### Append-only sets (`~T[]@set@observable`)

The runtime guarantees `WITH VIEW` returns a real `[]const T` slice
(never an opaque iterator), so user code gets native `arr[i]` /
`arr s> ...` / stdlib-array-fn ergonomics without any conversion
step. This rules out segmented backing for the `view()` path.

For **bounded streams (`~T[N]`)**: a fixed `[N]T` buffer allocated
once. `contents.items.ptr` never moves. `WITH VIEW` returns
`contents[0..current_len]` -- zero-cost slice into the stable
buffer.

For **dynamic streams (`~T[]`)**: a single contiguous buffer with
**grow-on-fill** (geometric doubling). When the buffer fills, the
writer allocates a new buffer at 2x capacity, copies items, and
atomically swaps the head pointer. Each buffer carries a
refcount; readers who hold a `WITH VIEW` snapshot pin the buffer
they're looking at, so old buffers stay alive until the last
reader's scope exits, then are freed.

```zig
const StreamSet(T) = struct {
    head:    ?*Buffer(T),                 // current write buffer
    mtx:     SpinLock,                    // brief lock for head load+inc / swap+dec
    lookup:  std.AutoHashMapUnmanaged(T, void),
    alloc:   std.mem.Allocator,
};

const Buffer(T) = struct {
    data:     []T,
    count:    Atomic(usize),  // items in `data`; release-stored by writer
    refcount: Atomic(u32),    // head holds 1; each snapshot bumps + drops
};
```

Per-emit cost is amortized O(1) (geometric doubling); per-emit
cost during a grow is O(N) but happens log(N) times across the
stream's life. View cost is `O(1)` -- a refcount inc + count load.

### v0.3 plan: persistent data structures as a transparent runtime optimization

Persistent data structures (HAMT for maps, RRB-tree for lists)
will be considered as a **drop-in runtime optimization** for the
above. They reduce writer-side per-update cost from O(N) to
O(log N) and let concurrent snapshot versions share unchanged
subtrees (memory savings under high-fanout reader workloads).

**Critical constraint: zero impact on CLEAR.** All user-visible
surface is `WITH VIEW v AS s` and `WITH MATERIALIZED VIEW v AS s`,
both of which observe immutable data through method-call APIs that
present T's normal interface. Switching to persistent backing
changes the *implementation* under the hood; user code stays
identical.

The constraint that makes this transparent: `WITH VIEW` returning
a real `[]T` slice forces the runtime to materialize a contiguous
view at observation time. If we switch to persistent in v0.3, the
slice is built lazily on first VIEW (O(N), cached for the
snapshot's lifetime) -- same observable semantics, different
internal write/memory profile. The user's API surface,
performance contract at the keyword (`VIEW = cheap`,
`MATERIALIZED = O(N)`), and existing call sites are all preserved.

---

## Phase 2: Observables in Pipelines (full implementation)

Extends Phase 1 with:
- `WITH VIEW` and `WITH MATERIALIZED VIEW` fully wired into the annotator and transpiler.
- `@observable` inferred automatically by the pipeline type checker for all terminals
  in the Phase 1 table.
- Compiler error messages for `WITH VIEW` on non-observable types that direct the user
  to `WITH MATERIALIZED VIEW`.

---

## Phase 3: Observable Types Outside Pipelines

### Proposal

Introduce first-class observable types usable in regular CLEAR code, not just pipeline
terminals. These would be CLEAR-level wrappers with the same atomic/append-only backing
that pipeline aggregates use internally.

```ruby clear
-- Observable scalar (wraps an atomic)
counter: ObservableInt64 = ObservableInt64.new(0);
counter.update(|v| v + 1);                  -- atomic increment
WITH VIEW counter AS c -> print(c); END     -- atomic read

-- Observable set (wraps append-only StreamSet)
seen: ObservableSet(String) = ObservableSet.new();
seen.insert("hello");
WITH VIEW seen AS s -> print(s.length()); END

-- Observable list (append-only)
log: ObservableList(String) = ObservableList.new();
log.append("event 1");
WITH VIEW log AS l -> print(l.length()); END
```

These types could serve as REDUCE accumulators to produce `~T@observable`:

```ruby clear
-- REDUCE with observable accumulator -> @observable result
running: ~ObservableSet(String)@observable = stream s> REDUCE(ObservableSet.new()) acc.insert(_.tag)
```

### Pros

- **General observability**: reactive patterns without lifetime tracking, usable anywhere
  in the language, not just in pipeline terminals.
- **REDUCE gains full @observable support**: any REDUCE whose accumulator type is
  observable produces an `@observable` result. Closes the one remaining gap.
- **Consistent model**: `@observable` becomes a general capability on any type that
  supports cheap VIEW, not a special pipeline concept.
- **Useful outside streaming**: live counters, metrics, progress tracking, dashboards -
  all composable with the same `WITH VIEW` syntax.

### Cons

- **Parallel type hierarchy**: `ObservableSet` vs `Set`, `ObservableList` vs `List`.
  Users must choose the right type upfront. Adds API surface.
- **Observable strings are excluded**: string concatenation is not structurally
  append-only (each `++` produces a new allocation). A `StringBuilder`-style observable
  would work, but it is a distinct type from String and adds complexity.
  Recommendation: defer or exclude observable strings.
- **Observable maps are excluded**: HashMap structure moves on rehash. An
  `ObservableMap` would require either a stable indirect structure (complex) or
  downgrading to keys-only VIEW. Does not fit neatly into the append-only model.
  Observable map use cases are better served by `WITH MATERIALIZED VIEW` on INDEX.
- **Mutation semantics**: `ObservableInt64.update(|v| v + 1)` is a CAS loop. Under
  high contention (many fibers updating) this degrades. Users must understand the
  tradeoff vs `@locked Int64`.

### Cost

| Component | Effort |
|---|---|
| `ObservableInt64`, `ObservableFloat64`, `ObservableBool` | Low - thin wrappers over Zig atomics, already effectively exist for pipeline scalars |
| `ObservableList(T)` | Low-medium - append-only ArrayList with stable capacity |
| `ObservableSet(T)` | Medium - already designed for DISTINCT; expose as first-class type |
| `ObservableMap(K,V)` | High / not recommended - structure doesn't fit append-only model |
| Observable strings | High / not recommended - requires dedicated StringBuilder type |
| Annotator: REDUCE with observable acc -> @observable | Medium - type inference for accumulator capability |
| `WITH VIEW` on non-pipeline observables | Low - same mechanism as pipeline observables |

### Recommendation

Implement Phase 3 in two sub-phases:

**Phase 3a**: `ObservableInt64`, `ObservableFloat64`, `ObservableBool`, `ObservableList(T)`,
`ObservableSet(T)`. These are low-to-medium cost, cover the vast majority of reactive use
cases, and directly reuse the runtime infrastructure built for Phase 1.

**Phase 3b** (if needed): Evaluate based on actual usage. Observable maps and strings
are expensive to implement correctly and cover narrower use cases. The existing
`WITH MATERIALIZED VIEW` path handles those cases today.

---

## Alignment With CLEAR's Design Goals

CLEAR's central contract is: **all ramifications are visible at the decision point**. Memory costs,
ownership transfers, and mutation risks must be legible at the call site, not hidden inside
abstractions or deferred to a runtime.

### Why `WITH VIEW` fits

- The keyword block makes the observation scope structurally explicit. There is no way to
  accidentally use a stale reference: the binding ceases to exist when the block exits.
- The word `VIEW` signals read-only observation with no allocation. A developer unfamiliar with the
  codebase sees `WITH VIEW x AS s ->` and immediately knows: cheap, scoped, immutable.
- Compared to Rust's lifetime parameters (`&'a T`): lifetimes are viral - they infect every
  function signature that touches the borrow. `WITH VIEW` is locally scoped and never propagates.
- Compared to implicit copies (Go, Python): hidden allocation is the norm. CLEAR makes
  the cost explicit and zero by default for @observable types.

### Why `WITH MATERIALIZED VIEW` fits

- The word `MATERIALIZED` is intentional signal. It is a term developers already associate with
  "this creates a real, allocated copy." No documentation required.
- Placing allocation cost at the call site is consistent with how CLEAR handles all other heap
  allocation: it is always visible, never implicit.
- For INDEX and REDUCE(collection), there is no safe O(1) path. Forcing `WITH MATERIALIZED VIEW`
  means developers cannot accidentally take a cheap snapshot of a structure that will rehash or
  reallocate under them. The API makes the unsafe-cheap-path unavailable.

### The structural contrast

| Access model | Cost visible? | Scope visible? | Mutation risk? | Lifetime viral? |
|---|---|---|---|---|
| Implicit copy (Go/Python) | No | No | No | No |
| Rust `&'a T` | Yes | Yes | No | YES |
| `WITH VIEW` | Yes (zero) | Yes (block) | No | No |
| `WITH MATERIALIZED VIEW` | Yes (O(n)) | Yes (block) | No | No |

---

## BORROWED T - Current State and Lockdown Plan

### Current implementation

`BORROWED T` in CLEAR today is a **zero-copy const alias** with `non_escaping` enforcement:

```zig
const alias = source_expr;
_ = &alias;  // prevent optimizer elision
```

The annotator sets `non_escaping: true` on the binding, blocking moves at three sites:
function return, GIVE, and TAKES argument position. This is the entire guarantee.

### Gaps (what the documentation implies vs. what is true)

1. **@shared can be borrowed.** `BORROWED` is supposed to imply the data is stable for the
   borrow duration. But `@shared T` (Arc-wrapped) can be handed into a `BORROWED` binding without
   blocking concurrent writes to the inner value.
2. **BG blocks can capture BORROWED bindings.** A BG lambda closing over a `BORROWED T` variable
   escapes the non_escaping check. The fiber may outlive the borrow.
3. **non_escaping only blocks 3 sites.** Assignment into a heap container field, into a
   collection, or into another struct would not be caught.

### Why this matters for CLEAR

CLEAR's promise is: if it compiles, the memory model is correct. A BORROWED value that silently
becomes invalid violates this. The gap is especially dangerous in the concurrent fiber model -
a BORROWED binding captured by BG and outliving the original scope is a use-after-free.

### Lockdown plan

| Fix | File | Effort |
|---|---|---|
| Block `BORROWED` on `@shared T` (Arc), `@locked T`, `multiowned T` | `src/annotator.rb` | Low |
| Block BG lambda capture of `non_escaping` bindings | `src/annotator.rb` (BG block analysis) | Low-Medium |
| Block assignment of `non_escaping` into struct fields or collections | `src/annotator.rb` (escape analysis) | Medium |
| Document: BORROWED = frame-local only, no shared/mutable objects | `docs/` | Low |

**Recommendation**: implement the three annotator fixes before Phase 2 observables. The `WITH VIEW`
block for @observable collections uses the same non_escaping mechanism. If BORROWED has gaps,
WITH VIEW will inherit them. Fix the foundation first.

### BORROWED vs WITH VIEW

After the lockdown, the two concepts are complementary:

| Concept | What it borrows | Stability guarantee | Use case |
|---|---|---|---|
| `BORROWED T` | Any frame-local value | Frame lifetime (no @shared) | Function argument read-only aliasing |
| `WITH VIEW ~T AS s` | Live stream accumulator | Immutable slice of stable backing | Observe running stream state |

They use the same non_escaping mechanism but target different lifetimes. BORROWED is a
frame-level tool. WITH VIEW is a cross-fiber observation tool. Neither should be passable as a
typed value - both are scoped borrows.

---

## Effort Estimate: @observable Phase 1 + Phase 2

### Runtime (Zig, Phase 1)

| Component | Work | Estimate |
|---|---|---|
| Atomic scalar wrapper (SUM/MAX/MIN/COUNT/AVG/ANY/ALL) | Aggregates exist; replace local accumulator var with `std.atomic.Value(T)` | 1-2 days |
| FIND atomic optional | Same pattern; nullable atomic value | 0.5 days |
| REDUCE(scalar) atomic | Same pattern | 0.5 days |
| `StreamSet(T)` for DISTINCT - bounded (`~T[N]`) | `ensureTotalCapacity(N)`, ptr never moves, slice is free | 1-2 days |
| `StreamSet(T)` for DISTINCT - dynamic (`~T[]`) | SegmentedList or geometric over-allocation; more complex | 2-3 days |
| **Phase 1 runtime total** | | **5-8 days** |

### Compiler (Ruby, Phase 2)

| Component | Work | Estimate |
|---|---|---|
| `@observable` flag on type system (`src/ast/type.rb`) | One bool on StreamType; propagated by fold terminal inference | 0.5 days |
| Fold terminal inference: mark @observable for Phase 1 terminals | In annotator pipeline type checker | 1 day |
| `WITH VIEW v AS binding` parser + annotator | New syntax node; enforce @observable; immutable; non_escaping for slices | 2-3 days |
| `WITH MATERIALIZED VIEW v AS binding` parser + annotator | New syntax node; valid on any `~T`; owned; escapable | 1-2 days |
| Transpiler: scalar VIEW = atomic load | Mechanical emit | 0.5 days |
| Transpiler: set VIEW = SegmentedList.Slice | Mechanical emit | 1 day |
| Transpiler: MATERIALIZED VIEW = deep copy alloc | Calls existing cleanup/copy machinery | 1-2 days |
| Error messages (VIEW on non-@observable; direct to MATERIALIZED) | Annotator error path | 0.5 days |
| **Phase 2 compiler total** | | **7-10 days** |

### Summary

| Phase | Scope | Estimate |
|---|---|---|
| Phase 1: Runtime atomics + StreamSet | Zig runtime | 5-8 days |
| Phase 2: Compiler, syntax, transpiler | Ruby compiler | 7-10 days |
| BORROWED T lockdown (prerequisite) | Ruby annotator | 2-3 days |
| **Total Phase 1+2** | | **~3 weeks** |
| Phase 3a: ObservableInt64/Set/List as first-class types | Runtime + compiler | +1 week |

The phases are independent enough to parallelize: runtime work (Zig) and compiler parser/type work
(Ruby) can proceed concurrently. The transpiler emit work depends on both completing.

---

## Summary

| Access form | Applies to | Cost | Binding escapes? |
|---|---|---|---|
| `WITH VIEW v AS b` | `~T@observable` only | O(1) | no (slice) / yes (scalar copy) |
| `WITH MATERIALIZED VIEW v AS b` | any `~T` aggregate | O(n) | yes (owned) |
| `VIEW(v)` (scalar shorthand) | `~T@observable` scalar | O(1) | yes (copy) |
