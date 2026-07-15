# AtomicPtr in CLEAR — design discussion (v0.3, M3)

Status: **DRAFT**. Settled in conversation; this doc is the spec
the implementation tranches at the bottom will hit.

`@boxed:atomic` is the v0.3 follow-up to v0.2's
`@shared:atomic`. Where `@shared:atomic` gives lock-free CAS on a
free-standing primitive (Int64/Float64/Bool, scope-bounded), this
adds **lock-free atomic pointer publish** for whole structs —
the workload Rust's `arc-swap` and Go's `sync/atomic.Pointer[T]`
target. Producers atomically swap the published value; consumers
load a stable snapshot for the duration of a `WITH SNAPSHOT`
scope.

## 1. Goal

Make this work, lock-free, with the same WITH-block uniformity
as the rest of the sync family:

```clear
-- ILLUSTRATIVE
config: Config = Config{ host: "localhost", port: 8080 } @boxed:atomic;

-- Reader (any number, parallel, no contention)
WITH SNAPSHOT config AS c {
    print(c.host);
    print(c.port.toString());
}

-- Writer
WITH SNAPSHOT config AS MUTABLE x {
    x.port = x.port + 1;
};
```

No `compareAndSwap`, `load`, `store`, or `rcu` exposed at the
surface — the WITH block IS the API. Everything underneath is the
compiler's job.

## 2. Reference: Rust and Go

CLEAR follows **Rust's `arc-swap`** because the Rust community
has already worked through the design space. Go's
`sync/atomic.Pointer[T]` is the same shape with GC instead of
Arc; it's a useful sanity check but doesn't add design info we
don't have.

| Concept | Rust `arc-swap`              | Go `atomic.Pointer[T]` | CLEAR M3                    |
|---|---|---|---|
| Read     | `cfg.load() -> Guard<Arc<T>>` | `p.Load() -> *T`        | `WITH SNAPSHOT cfg AS c { ... }` |
| Mutate   | `cfg.rcu(\|old\| new)`        | hand-rolled CAS loop    | `WITH SNAPSHOT cfg AS MUTABLE x { ... };` |
| Lifetime | `Arc<T>` refcount            | GC                      | `Arc<T>` refcount (existing `@shared` machinery) |
| CAS retry | unbounded (rcu loops)       | user-loop               | unbounded (matches Rust rcu) |
| Conflict | none — rcu always succeeds   | none — caller's loop   | none — `ON Conflict` is **forbidden** |

## 3. Capability — `@boxed:atomic`

Three sigils on three orthogonal axes:

| Sigil | Axis | Meaning |
|---|---|---|
| `@boxed` | layout/storage | heap-pinned cell, stable address (so atomic-ptr ops are well-defined) |
| `@atomic`   | sync           | atomic ops on the cell (load/store/CAS at the pointer level) |
| (`@shared` is implicit) | sharing | published values are Arc-refcounted so loaded snapshots can outlive the producer's iteration |

The user writes `@boxed:atomic`. The compiler infers `:shared`
because escaping the declaring scope is the whole point of
atomic-ptr — without Arc semantics on the published values, a
loaded snapshot could become invalid mid-read when the producer
swaps. (This is the lifetime divergence from primitive
`@shared:atomic`, which is scope-bounded.)

### Why not just `@atomic` on a struct?

`@atomic` on a primitive fits in one CAS-able machine word
(8 bytes on x86_64; 4 on 32-bit). Most structs do not. Atomic
operations on a non-word-sized payload need either:
- a multi-word CAS protocol (DCAS/MCAS — slow, complex), or
- pointer indirection — atomic CAS on the pointer to an
  immutable heap-allocated `T`.

CLEAR picks the second path. `@boxed` makes the indirection
explicit at the binding site so the user knows they're paying
for one heap allocation per published value (not per field).

### Disallowed combinations

| Form | Status |
|---|---|
| `@atomic` (alone) on a struct  | disallowed — use `@boxed:atomic` |
| `@local:boxed:atomic`       | disallowed — atomic without cross-thread is pointless |
| `@multiowned:boxed:atomic`  | disallowed — Rc isn't thread-safe |
| `@boxed:atomic` on a primitive (Int64/Float64/Bool) | disallowed — use `@shared:atomic` (already exists; v0.2) |
| `@boxed:atomic` on slices/lists/maps | disallowed for v0.3 — separate work item |

## 4. Surface — WITH SNAPSHOT

`@boxed:atomic` reuses the existing `WITH SNAPSHOT` shape
introduced for `@shared:versioned`. The two families are
**source-uniform** for read and **MATCH-dispatched** for mutate.

### 4.1. Read

```clear
WITH SNAPSHOT config AS c {
    print(c.host);
    print(c.port.toString());
}
-- c is dropped at scope exit; Arc--
```

Single body works for both `@shared:versioned` and
`@boxed:atomic`. No `MATCH` needed. No `ON Conflict` valid
(read paths can't fail).

### 4.2. Mutate (single-family)

```clear
-- VERSIONED only — bounded retries, ON Conflict required
WITH SNAPSHOT config AS MUTABLE x { x.port = x.port + 1; } ON Conflict RAISE;

-- ATOMIC only — unbounded retries (Rust rcu), ON Conflict forbidden
WITH SNAPSHOT config AS MUTABLE x { x.port = x.port + 1; };
```

Lowering for the ATOMIC arm: load current Arc → clone payload →
run user body on the clone → atomic CAS-publish the clone → if
CAS failed (concurrent producer beat us), retry with the new
loaded Arc. Loop until success. The user's body MUST be pure
(same purity contract as VERSIONED MUTABLE — no IO, no yield,
no allocations beyond the clone) because it can be called
multiple times.

### 4.3. Mutate (polymorphic VERSIONED | ATOMIC)

The two families differ in whether `ON Conflict` is required, so
polymorphic mutation MUST use `MATCH`:

```clear
FN bumpPort(MUTABLE c: Config) REQUIRES c: VERSIONED | ATOMIC ->
  WITH SNAPSHOT c AS MUTABLE x MATCH
    WHEN VERSIONED -> { x.port = x.port + 1; } ON Conflict RAISE
    WHEN ATOMIC    -> { x.port = x.port + 1; }
  END
END
```

`SNAPSHOT`, `AS`, `MUTABLE`, alias, and the cell list live
OUTSIDE the MATCH; per-arm bodies and per-arm `ON Conflict`
clauses live inside. Mirrors the existing generic `WITH MATCH`
shape (parser.rb:2882-2896, parse_with_match_arms at 3037).

### 4.4. Multi-cell

**Multi-cell `WITH SNAPSHOT` is forbidden when any cell is
`@boxed:atomic`** (single-arm or any ATOMIC arm in a MATCH):

```clear
-- REJECTED at compile time
WITH SNAPSHOT a AS MUTABLE va, SNAPSHOT b AS MUTABLE vb { ... };
```

Error message:

> *"`@boxed:atomic` cannot guarantee multi-object consistency.
> If you need multi-object consistency use `@shared:versioned` or
> `@shared:locked`."*

Reason: there's no portable hardware multi-pointer CAS, and
software MCAS protocols are out of scope for v0.3. MVCC's
`Shared.updateMulti` works because it uses sorted-pointer
locking + commit-or-rollback — that machinery does not exist
for atomic-ptr. Per-cell atomic CAS gives no atomicity across
cells.

## 5. Lifetime model

`@boxed:atomic` is Arc-refcounted internally. Published values
have refcount lifetime; a `WITH SNAPSHOT` `AS x` binding bumps
the refcount on entry, decrements on exit. Loaded snapshots can
therefore outlive the producer's iteration.

This is **different from primitive `@shared:atomic`**, which is
scope-bounded (M2.6 lifetime audit rejects escapes). The
divergence is structural:

- `@shared:atomic` (primitive): bare `*Atomic(T)`, no refcount,
  scope-bounded. Cheap. Cannot escape.
- `@boxed:atomic`: `Atomic(Arc<T>)`-shaped, refcounted, can
  escape. One heap allocation per publish.

Storing an `@boxed:atomic` cell in a long-lived struct field,
returning it from a function, capturing it into a long-lived BG
handle — all fine. The Arc keeps the live published value alive;
the cell keeps the atomic-pointer alive.

## 6. Errors

### 6.1. Bare mutation on `@boxed:atomic`

Direct field assignment on an `@boxed:atomic` binding is
rejected with a message that **explicitly distinguishes from
primitive `@atomic`**:

```clear
config.port = 9090;        -- REJECTED
```

> *"`@boxed:atomic` requires `WITH SNAPSHOT cfg AS MUTABLE x { x.port = 9090; }` for mutation. Atomic pointer swap publishes a new whole-T snapshot, not a per-field write — the `WITH SNAPSHOT` block clones the snapshot, mutates the clone, and CAS-publishes it. (This is different from primitive `@shared:atomic` Int64/Float64/Bool, which use direct ops like `c += 1` because they fit in a single CAS-able machine word.)"*

### 6.2. `ON Conflict` on `@boxed:atomic`

```clear
WITH SNAPSHOT config AS MUTABLE x { ... } ON Conflict RAISE;  -- REJECTED
```

> *"`ON Conflict` isn't valid on `@boxed:atomic`. Atomic CAS retries until success (matches Rust `rcu` semantics); there's no conflict path. Drop the trailing `ON Conflict`."*

### 6.3. Multi-cell `@boxed:atomic`

Per §4.4:

> *"`@boxed:atomic` cannot guarantee multi-object consistency. If you need multi-object consistency use `@shared:versioned` or `@shared:locked`."*

### 6.4. Polymorphic mutate without MATCH

```clear
FN f(MUTABLE c: Config) REQUIRES c: VERSIONED | ATOMIC ->
  WITH SNAPSHOT c AS MUTABLE x { x.port = x.port + 1; } ON Conflict RAISE;  -- REJECTED
END
```

> *"Mutate surface differs by family: `@shared:versioned` bounds retries and requires `ON Conflict`; `@boxed:atomic` retries unbounded and forbids it. Dispatch per family with `WITH SNAPSHOT c AS MUTABLE x MATCH ...`."*

## 7. What's NOT in M3

- `@boxed:atomic` on slices / lists / maps. Separate work item.
- Memory-ordering surface (acquire/release etc.). v0.2 atomics
  are seq_cst only; M3 inherits.
- `compareAndSwap` / `exchange` / `load` / `store` as user-callable
  primitives. The WITH block IS the API.
- Sharded variant (per-CPU atomic-ptrs summarized on read).
  Future work if benchmarks show it matters.
- DCAS / MCAS / multi-cell atomic publish. See §4.4.

## 8. Implementation tranches

Numbered M3.* to mirror the M1.* / M2.* atomics organisation.

### M3.1 — Type axis: `@boxed:atomic` on a struct

Extend `Type` so the combination `(ownership: :indirect, sync: :atomic)`
parses, has well-defined `zig_type` lowering (`*CheatLib.AtomicPtr(T)`
or similar), and survives `bare_data_type` stripping. Mirrors what
M1.3 did for primitive `:atomic`. Reject `@boxed:atomic` on
primitives and on `@local`/`@multiowned` storage.

### M3.2 — Parser: capability sigil

`@boxed:atomic` recognised as a valid sigil chain at the
declaration site. Order-independent (`@atomic:boxed` accepted
too). Composes with `@shared` (which is implicit anyway). Mirrors
M1.2.

### M3.3 — Runtime: `AtomicPtr(T)` primitive

`zig/runtime/lib/atomic_ptr.zig` (new file): a CAS-able pointer
cell wrapping `Arc(T)`. API:
- `init(allocator, value: T) !*Self`
- `loadShared(self) Arc(T)` — Arc-bumped snapshot
- `compareAndPublish(self, expected: Arc(T), new: Arc(T)) bool` —
  the building block for the WITH MUTABLE CAS loop
- `cleanup(self, allocator)` — drops the published Arc, frees self

Standard `seq_cst` ordering throughout.

**Testing must be bulletproof before any compiler integration**
(M3.4 onward DO NOT start until M3.3 is green). Three modalities,
matching the existing runtime test infrastructure:

1. **Loom** — `zig/atomic-ptr-loom-test.zig`. Exhaustive
   interleaving search via `SimAtomic`. Proves the safety
   invariants (no torn reads, no use-after-free, no double-free,
   no leaked Arcs) hold across every reachable producer/consumer
   permutation. Patterns: `zig/parking-lot-loom-test.zig`,
   `zig/fsm-loom-test.zig`. **Required.**

2. **Hammer** — `zig/atomic-ptr-hammer-test.zig`. High-stress
   N-producer / M-consumer test running for seconds with sustained
   publish + load load, asserting end-state refcount invariants
   and zero leaks. Patterns: `zig/parking-lot-hammer-test.zig`,
   `zig/runtime/steal-hammer-test.zig`. **Required if the
   primitive has any contention path beyond a single CAS.**

3. **VOPR** — `zig/runtime/atomic-ptr-vopr-test.zig`. Property-
   based chaos test if a non-trivial state machine emerges
   (epoch/retire/reclaim races, multi-step publish protocols).
   Pattern: `zig/runtime/versioned-vopr-test.zig`. **Required if
   loom reveals state-machine complexity beyond pure CAS-publish.**

The reasoning is structural: lock-free primitives are notoriously
hard to debug once they're wired through the annotator + MIR +
transpiler. Catching a torn-read or double-free at the runtime
unit-test layer is seconds; catching it through the full pipeline
is days.

### M3.4 — Annotator: capability validation

- Allow `@boxed:atomic` only on struct types (not primitives,
  slices, collections — see §3 disallowed table).
- REQUIRES family `ATOMIC` covers BOTH primitive `@shared:atomic`
  AND `@boxed:atomic` (single family, two layouts; the WHEN
  ATOMIC arm dispatches via `@hasField` / `@hasDecl` in the
  comptime body — same pattern as M1.6).
- Plain `:shared` is ALLOWED (implicit) on `@boxed:atomic`;
  conflicts errored at parse for `@local` / `@multiowned`.

### M3.5 — WITH SNAPSHOT: read mode

`WITH SNAPSHOT cell AS x { ... }` on an `@boxed:atomic`
binding lowers to `cell.loadShared() => x` with cleanup at scope
exit. No `ON Conflict` at this surface, same as the existing
VERSIONED read path.

### M3.6 — WITH SNAPSHOT: MUTABLE (atomic CAS loop)

`WITH SNAPSHOT cell AS MUTABLE x { ... };` on `@boxed:atomic`
lowers to:
```
loop:
  let snapshot = cell.loadShared();
  let mut clone = snapshot.deepClone();    // user-body operates on the clone
  user_body(&mut clone);
  if cell.compareAndPublish(snapshot, Arc::new(clone)):
    break
```
Body purity check: same restrictions as VERSIONED MUTABLE (no IO,
no yield, no heap effects beyond the clone). Reuses the existing
`@inside_snapshot_txn` flag and impurity-violation set
(annotator.rb:3981-3993).

### M3.7 — Parser: SNAPSHOT MATCH

Extend `parse_snapshot_block` (parser.rb:2936) to accept a
trailing `MATCH ... END` after the cell list. Per-arm bodies +
per-arm trailing `ON Conflict` clauses, mirroring the generic
`parse_with_match_arms` (parser.rb:3037). `SNAPSHOT`, `AS`,
`MUTABLE`, alias, and the cell list stay outside the MATCH.

### M3.8 — Annotator: per-arm conflict-clause validation

Replace the `is_snapshot_txn && clause.nil?` check in
`validate_lock_error_clause!` (annotator.rb:4062) with per-arm
dispatch when arms exist:
- VERSIONED arm + MUTABLE: `ON Conflict` required (existing
  contract).
- ATOMIC arm + MUTABLE: `ON Conflict` forbidden — new error per §6.2.
- Single-arm bare body keeps current behaviour.

### M3.9 — Multi-cell rejection

Inside `parse_snapshot_block` (and arm validation in the new
MATCH path): when `capabilities.size > 1` AND any cell resolves
to `@boxed:atomic` (or any `WHEN ATOMIC` arm exists in a
multi-cell MATCH), error per §6.3 with the exact message:
> "`@boxed:atomic` cannot guarantee multi-object consistency.
>  If you need multi-object consistency use `@shared:versioned`
>  or `@shared:locked`."

### M3.10 — Bare-mutation rejection

When the annotator sees an assignment whose target's root binding
is `@boxed:atomic` AND the assignment is not inside a
`WITH SNAPSHOT ... AS MUTABLE` block whose alias rooted at this
binding — error per §6.1. Wording must explicitly distinguish
primitive `@shared:atomic` (which uses direct ops) from
`@boxed:atomic` (which requires WITH SNAPSHOT).

### M3.11 — Polymorphic mutate without MATCH

When a fn declares `REQUIRES c: VERSIONED | ATOMIC` and the body
contains `WITH SNAPSHOT c AS MUTABLE x { ... }` (single body, no
MATCH) — error per §6.4 directing the user to MATCH-dispatch.

### M3.12 — Lifetime: Arc-escape allowed

Update `bg_lifetime_sources` (annotator.rb:5063) and the M2.6
escape audit so `@boxed:atomic` bindings DO NOT contribute to
a tied lifetime — they're Arc-refcounted, free to escape. Mirror
the existing `@shared`-without-sync exemption. Verify with
positive (escape allowed) AND negative (primitive
`@shared:atomic` still rejected) cases per the M2.6 audit shape.

### M3.13 — Transpile-tests

Coverage matrix:
- single-cell read (positive)
- single-cell mutate (positive)
- multi-cell read/mutate (negative — error per §6.3)
- bare mutation (negative — error per §6.1)
- ON Conflict on ATOMIC (negative — error per §6.2)
- polymorphic VERSIONED|ATOMIC read (positive — uniform body)
- polymorphic VERSIONED|ATOMIC mutate without MATCH (negative)
- polymorphic VERSIONED|ATOMIC mutate with MATCH (positive)
- escape patterns (RETURN, struct-field-store, BG capture) all
  positive — Arc-refcounted, no lifetime audit fires.

### M3.14 — Benchmarks

`benchmarks/concurrent/atomic_ptr/`: producer-consumer config swap.
- Single producer, N consumers, fixed publish rate, measure
  consumer read latency.
- Compare CLEAR `@boxed:atomic` vs:
  - Rust `arc-swap` (same workload)
  - Go `atomic.Pointer[T]` (same workload)
  - CLEAR `@shared:writeLocked` (RwLock baseline)
  - CLEAR `@shared:versioned` (MVCC baseline)
  Expected: parity-or-better with arc-swap on read latency under
  contention; significantly better than RwLock on consumer-side
  scaling.

### M3.15 — `clear fix` migrations

Two patterns from real code:
1. `STRUCT C { ... } @shared:writeLocked` with read-mostly
   workload + whole-struct commits (no field-level mutation) →
   suggest `@boxed:atomic`.
2. `@boxed:shared:locked` with read-mostly workload → same.

Static eligibility check (similar to `AtomicMigrationSuggester`
from M1.9): WITH-EXCLUSIVE bodies that only do `alias = NewT{...}`
(whole-struct replace, no field mutation) qualify.

### M3.16 — Doctor diagnostic

Two surfaces:
1. **Lock-profile signal:** when `@shared:writeLocked` /
   `@shared:locked` shows read-mostly contention AND M3.15's
   static check fits → recommend the migration.
2. **Atomic-fit upgrade signal:** when an existing
   `@shared:versioned` cell sees only single-cell whole-struct
   commits (never multi-cell, never field-level mutation), the
   doctor notes that `@boxed:atomic` would skip the bounded-
   retry and EBR-pin overhead.
