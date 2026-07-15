# Atomics in CLEAR — design discussion

Status: **DRAFT**. Goal of this doc is to nail down the surface and
safety story before any compiler/runtime work starts. Once the
unknowns below are settled, this becomes the spec for an atomics
TODO entry similar in shape to the MVCC tranches.

The CLEAR runtime already uses atomic-scalar wrappers (AtomicInt,
AtomicFloat, AtomicBool, AtomicAny/All, AtomicReduce) under
`@observable`, but only inside fold-pipeline terminals. Users
cannot today declare a free-standing atomic counter and bump it
from a parallel BG block. That's the gap.

## 1. Where does `@atomic` sit on the capability axes?

### Re-frame: `@shared` is permission, not implementation

Adding atomics is the right moment to formalize a re-framing of
`@shared` that's been latent in the design: `@shared` describes
**what you want to do** (cross sync / scheduler boundaries),
not **how it's accomplished** (Arc).

| Form | Semantic (WHAT) | Implementation (HOW) |
|---|---|---|
| `T @shared`            | read-only sharing across boundaries | `Arc(T)` (refcount lifetime) |
| `T @shared:locked`     | mutex-protected mutation across boundaries | `Arc(Locked(T))` (refcount lifetime) |
| `T @shared:versioned`  | MVCC snapshot-read / CAS-write across boundaries | `Arc(Versioned(T))` (refcount lifetime) |
| `T @shared:atomic`     | lock-free single-cell mutation across boundaries | bare `Atomic(T)` (scoped-borrow lifetime — **no Arc**) |

The fact that three of these use Arc internally and the fourth
doesn't is an implementation detail. What the user sees is "I
declared this `@shared:X` so it's allowed to flow into
`@parallel` BG / DO / CONCURRENT blocks; the runtime picks the
right wrapper."

The existing `@shared:locked` / `@shared:versioned` meanings are
**unchanged**. Plain `@shared` is **unchanged**. The new form
`@shared:atomic` joins the family with one wrinkle:

### Lifetime divergence — documented, not surfaced

`@shared:atomic` has a different lifetime model than its three
sisters:

- `@shared`, `@shared:locked`, `@shared:versioned` — refcount
  lifetime via Arc. The cell can outlive its declaring scope by
  cloning the Arc into a struct field, returning it from a
  function, etc.
- `@shared:atomic` — scoped-borrow lifetime. The atomic cell
  lives where declared. BG / DO / CONCURRENT fibers that capture
  it run inside that scope; they must complete before the scope
  exits.

This divergence is real and we don't hide it. Documentation
calls it out; the borrow checker enforces it; `clear doctor`
explains it when relevant. We just don't burn syntactic surface
to encode it (no `@atomic` vs `@shared:atomic` split).

### Why no separate `@atomic`?

Earlier draft of this doc proposed bare `@atomic` (in-scope, no
Arc) and `@shared:atomic` (Arc-wrapped, escapable) as two
distinct forms. The motivation was the "save the Arc clone for
the in-scope case" optimization.

But: there's no genuine use case for `@shared:atomic` on a
free-standing primitive in the Arc-wrapped sense. Long-lived
atomics that need refcount-managed lifetime always live as a
field inside a long-lived struct, and the struct's own
ownership capability handles the lifetime. The Arc-wrapped
free-standing-atomic case is exactly equivalent to
`STRUCT C { v: Int64 @atomic } @shared` — it's sugar that
duplicates the struct-field path.

So: drop bare `@atomic` from the language. `@shared:atomic` is
the only form, and it does what bare `@atomic` would have done
(no Arc, scoped-borrow). The Arc-on-a-primitive shape we'd have
shipped as v0.2 sugar simply doesn't exist.

### Disallowed combinations

| Form | Status |
|---|---|
| `@local:atomic`      | **disallowed** — atomic without cross-thread is pointless; use plain `Int64` |
| `@multiowned:atomic` | **disallowed** — Rc isn't thread-safe; the atomic doesn't fix that |
| `@atomic` (alone)    | **disallowed** for v0.2 — see §6 for why; same effect via `@shared:atomic` |

## 2. Naming — is `:atomic` the right word?

`:atomic` is HOW (CPU instruction); the WHAT is "single-cell,
lock-free, cross-thread-safe mutation". You correctly note that
`:locked` and `:versioned` are also HOW labels, so the precedent
is set.

Alternatives considered:
- `:lockfree` — describes a property, but ambiguous (versioned is
  also lock-free on the read side)
- `:cell` — describes shape, but uninformative
- `:wait_free` — too technical, also stricter (atomic ops aren't
  wait-free under contention)

**Recommendation: keep `:atomic`.** It's universally understood,
matches the existing HOW-labelling pattern, and makes the
capability searchable for anyone coming from C/Rust/Go/Java.
Bikeshedding the name has zero leverage.

## 3. Surface syntax — examples

```clear
-- ILLUSTRATIVE
-- Free-standing atomic counter, captured by N parallel writers.
counter: Int64 = 0 @shared:atomic;

CONCURRENT (32) DO
    BG { @parallel ->
        counter += 1;     -- compiles to fetch_add (seq_cst)
    }
END

print(counter);            -- compiles to atomic_load (seq_cst)
```

For primitive types, `@shared:atomic` lifts the existing
"capabilities cannot be applied to primitive types" restriction —
the WHOLE POINT of atomic is the primitive-as-cell case. (For
struct cells, see deferred work in §6.)

Atomic operations (all seq_cst by default in v0.2):

| Surface | Lowers to |
|---|---|
| `c = 5;`           | `atomic_store(c, 5)` |
| `x = c;`           | `atomic_load(c)` |
| `c += n;`          | `atomic_fetch_add(c, n)` (returns old) |
| `c -= n;`          | `atomic_fetch_sub(c, n)` |
| `c &= mask;`       | `atomic_fetch_and(c, mask)` |
| `c \|= flag;`      | `atomic_fetch_or(c, flag)` |
| `c ^= bits;`       | `atomic_fetch_xor(c, bits)` |
| `c.exchange(new)`  | `atomic_exchange(c, new)` returns old |
| `c.compareAndSwap(expected, new)` | bool (true if swapped) |

For `Bool`: load/store/exchange/compareAndSwap (no arithmetic).
For `Float64`: load/store/exchange/compareAndSwap +
fetch_add/fetch_sub via CAS-loop wrapper (matches AtomicFloat
that already ships under @observable).

### Memory ordering

v0.2 ships **seq_cst only**. Rationale:
- Always correct, always safe.
- Most users don't have a justified reason for a weaker order.
- We don't have a profile-guided story for ordering yet.
- We can add `c.load(:acquire)` / `c.store(:release)` etc. in
  v0.3 once we have benchmarks proving the relaxation matters.

## 4. Safety story — scoped-borrow lifetime for `@shared:atomic`

`@shared:atomic` cells live where declared (no Arc), so when a
parallel BG / DO / CONCURRENT fiber captures one, the fiber must
not outlive that scope. CLEAR enforces this with a scoped-borrow
contract on the BG handle.

### The contract

When `c: Int64 @shared:atomic` is captured by `BG { @parallel -> ... }`,
the returned stream handle is **lifetime-bound to `c`**:

- The handle CANNOT be RETURNed from the function that owns `c`.
- The handle CANNOT be stored in a struct field, collection, or
  another binding that outlives `c`'s scope.
- The handle MUST be NEXT'd (awaited to completion) before `c`
  exits scope.

This is exactly how Rust's scoped threads
(`std::thread::scope`, `crossbeam::scope`) work, and it's how
CLEAR's existing BORROWED / non-escaping aliases already work
under WITH-blocks (see borrowed-lockdown.md). The non-escape
walker already audits WITH aliases — extending it to
BG-capture-of-`@shared:atomic` reuses the same machinery.

### The new type: `~Scoped<T>`

We introduce a new stream-handle type — `~Scoped<T>` — distinct
from the existing `~T`:

| Type | Escapable | NEXT semantics |
|---|---|---|
| `~T`        (regular future) | Yes — return, struct-store, collection-store all OK | block until ready |
| `~Scoped<T>` (new)            | **No** — non-escaping like a WITH alias | block until ready, **and** scope-exit forces NEXT |

A BG block that captures a `@shared:atomic` binding returns
`~Scoped<T>` instead of `~T`. The annotator's existing non-escape
checker (the same one used for WITH aliases and observables)
extends to `~Scoped<T>`.

### Why this is the v0.2 design (not deferred)

Earlier draft of this doc proposed deferring `~Scoped<T>` to v0.3
and shipping `Arc<Atomic<T>>` for v0.2. We dropped that approach
(see §1) because it would have produced an Arc-wrapped form on
free-standing primitives that's redundant with `STRUCT @shared`
once struct-field atomics land. So `~Scoped<T>` is on the v0.2
critical path. The good news: most of its machinery already
exists.

### v0.2 scope bounding (recommended)

**v0.2: `@shared:atomic` on free-standing primitives only.** The
atomic cell lives in the declaring scope (no Arc). Capture by
parallel fibers requires those fibers to complete before scope
exits — enforced by `~Scoped<T>` and the non-escape walker.

**Restrictions in v0.2 that v0.3 will lift:**
- No atomic struct fields (`STRUCT C { v: Int64 @atomic }`). The
  field-level capability story is its own work item; in v0.2
  users wrap the atomic primitive directly.
- No nested-scope captures across multiple BG layers (the simple
  one-deep case is supported; deeper compositions might need
  borrow inference improvements first).
- No memory-ordering relaxation surface (seq_cst only).

## 5. Type interaction — fitting into the existing model

### Functions take Types

Per capabilities.md, `FN incr(c: Counter)` accepts every variant.
With atomic added:

```clear
-- ILLUSTRATIVE
FN incr!(MUTABLE c: Int64) ->
    c += 1;
END

a = 0 @shared:locked;       -- Arc<Mutex<i64>>
b = 0 @shared:versioned;    -- Arc<Versioned<i64>>
c = 0 @shared:atomic;       -- bare Atomic<i64>, scoped-borrow lifetime

incr(a);  -- auto WITH EXCLUSIVE
incr(b);  -- WITH SNAPSHOT (compile error today on primitives —
          --  see deferred §6: primitives via @shared:atomic are
          --  the trigger to lift this; @versioned on primitives
          --  is the same wave)
incr(c);  -- auto fetch_add (no Arc indirection)
```

Same function, three sync strategies. Caller picks.

### REQUIRES + WITH MATCH

`REQUIRES c: ATOMIC | LOCKABLE | VERSIONED` constraints follow
the existing pattern. WITH MATCH adds an `ATOMIC` arm:

```clear
-- ILLUSTRATIVE
FN bump!(MUTABLE c: Int64) REQUIRES c: ATOMIC | LOCKABLE ->
    WITH c AS x MATCH
        WHEN ATOMIC   -> { x += 1; }    -- fetch_add
        WHEN LOCKABLE -> { x += 1; }    -- mutex acquire + plain += + release
    END
END
```

Comptime dispatch via `@hasField` / `@hasDecl` (same pattern as
the MVCC L7.2 work).

### Doctor heuristic

Once telemetry exists for atomic ops (we have lock-profile and
mvcc-profile already), `clear doctor` can recommend:

- "@shared:locked counter with N writes/sec, no critical section
  beyond the increment — try @shared:atomic" (a profile-guided
  step similar to the existing locked → versioned heuristic)
- "@shared:atomic counter under high contention with no
  read-after-CAS dependency — consider sharded counters
  (per-thread + summarize-on-read)" (deferred; needs sharded
  capability first)

## 6. Scope: what's in v0.2 vs deferred

### v0.2 (target: ship alongside MVCC and observables)

- `@shared:atomic` for `Int64`, `Float64`, `Bool` on free-standing
  primitive declarations (the three the runtime already supports
  under @observable).
- Operations: load, store, fetch_add/sub/and/or/xor (where
  type-applicable), exchange, compareAndSwap.
- Memory ordering: seq_cst only, no surface for relaxation.
- `~Scoped<T>` stream-handle class + non-escape walker extension
  to enforce scoped-borrow lifetime on BG / DO / CONCURRENT
  captures of `@shared:atomic` bindings.
- WITH MATCH `WHEN ATOMIC` arm.
- REQUIRES `c: ATOMIC` and union constraints.
- `clear fix` migrations from common patterns (e.g., `@shared:locked`
  on a hot single-write counter → `@shared:atomic`).
- Doctor heuristic for the locked-to-atomic recommendation.

### Deferred to v0.3

- **Atomic struct fields** (`STRUCT Counter { value: Int64 @atomic }`).
  Field-level capabilities are their own work item — touches the
  layout + emit pipeline more deeply than the free-standing case.
  Until then, users with a struct that wants atomic fields use one
  `@shared:atomic` cell per field at the call-site rather than
  embedding inside the struct.
- **Memory-ordering surface** (`c.load(:acquire)` etc.). v0.2
  ships seq_cst only; we add the surface in v0.3 once benchmarks
  prove relaxation matters.
- **Atomic arrays / slices** (`Int64[]@atomic`).
- **`@boxed:atomic`** (heap-pinned atomic with stable address).
- **Sharded atomic counters** (per-CPU + summarize-on-read) as a
  capability sigil (`@sharded:atomic`?). Useful when an atomic
  hits sustained contention; doctor heuristic should suggest it
  once the sigil exists.
- **Cross-scope atomic captures** beyond simple one-deep BG
  bodies — nested fiber spawn graphs, atomic captured into a
  closure that's then passed around, etc. v0.2 supports the
  common case (one `BG @parallel` capturing one atomic); deeper
  patterns get a clearer error pointing at the workaround.

### Why this v0.2 cut is reasonable

Users get the actual capability — lock-free counters, flags,
gauges, monotonic clocks — accessible from `@parallel` fibers
with one-line declaration syntax and zero allocation per atomic.
The performance ceiling is the lock-free fetch_add on a hot
cache line; that's reached on day one. The restrictions (no
struct fields, no ordering control, no sharded form) are real
but not gating for the use cases atomics primarily address
(counters, gauges, flags).

The deferred items are real but additive: v0.3 closes them
without breaking v0.2 code. The framing of `@shared` as
"permission to cross sync boundaries" sets up a clean
capability story that scales as we add more strategies.

## 7. Open questions

1. **Surface for compareAndSwap.** Method-style
   `c.compareAndSwap(old, new)` matches the runtime's existing
   AtomicReduce path. But CLEAR doesn't have method syntax on
   primitives today. Two options:
   - Lift the no-methods-on-primitives restriction for
     `@atomic`-capable primitives (small special case).
   - Use a free function: `compareAndSwap(c, old, new)`.

2. **`+=` on `@shared:atomic`** — does it return the old value
   (matching atomic_fetch_add) or the new value (matching
   non-atomic CLEAR `+=`)? Proposal: it's a statement, not an
   expression, in v0.2 (same as `@locked` auto-mutex `+=`). v0.3
   adds expression form returning old.

3. **Cleanup contract.** Atomic primitives have no destructor;
   `Arc<Atomic<T>>` cleans up the Arc normally. Should be a
   no-op extension to the existing cleanup-by-MIR-node story.

4. **Cross-language naming alignment.** Rust uses `AtomicI64` /
   `Atomic::compare_exchange_weak`. Go uses
   `atomic.Int64.CompareAndSwap`. Java uses `AtomicLong`. The
   surface choices above lean Rust-y; final naming TBD with the
   broader stdlib alignment review.

5. **Float ordering semantics.** `Float64@atomic` with `+=` lowers
   to a CAS loop (no hardware atomic float-add on x86-64). Is
   that surprising? Should we error and force the user to write
   the CAS loop explicitly? Recommendation: lower silently and
   document — same convention as the existing AtomicFloat under
   @observable.

## 8. Lifetime-system audit (M2 phase, BLOCKING M2 release)

### One lifetime system, not two

CLEAR has two related-but-separately-implemented mechanisms today:

| Mechanism | Semantics | Used by |
|---|---|---|
| `non_escaping = true` flag on SymbolEntry | "cannot escape ANYWHERE" — blunt | WITH aliases, `@observable` bindings, BORROWED params |
| `RETURNS foo:T` lifetime annotation | "may escape to scopes ≤ foo's scope" — rich, allows propagation | Function returns of borrowed substructures (`spec/lifetimes_spec.rb`) |

The first is the degenerate case of the second
(`non_escaping = true` ≡ `lifetime = current scope, no inheritance`).
For atomic-captured BG handles we want the **rich** form: the
handle should be free to move into same-scope structs, lists,
queues, inner-BG captures — anywhere whose destination scope is
≤ the captured atomic's scope. Only escapes to *longer-lived*
destinations are errors.

**M2 collapses these into one mechanism** if they aren't already.
Existing call sites that set `non_escaping = true` get rewritten
to set the lifetime to the immediately-enclosing scope (which is
the same observable behavior, expressed in the unified system).
Atomic-captured BG handles get a lifetime pointing at the
captured atomic binding. `RETURNS foo:T` continues to work
unchanged. **One walker, one mental model.**

### What "valid escape" looks like for atomic BGs

```clear
-- ILLUSTRATIVE
counter = 0 @shared:atomic;   -- lifetime = enclosing fn scope
bg = BG { @parallel -> counter += 1; };   -- bg lifetime = counter

a = Foo{ field: bg };          -- a same-scope: legal
list.append(bg);               -- list same-scope: legal
inner = BG { @parallel -> NEXT bg; };  -- inner is same-or-shorter: legal
NEXT bg;                       -- always legal
RETURN bg;                     -- legal only with RETURNS counter:~Void

global.field = bg;             -- ERROR: global outlives counter
long_lived_queue.push(bg);     -- ERROR: queue outlives counter
RETURN bg;                     -- ERROR if fn doesn't declare RETURNS counter:~Void
```

The check is the same as `RETURNS foo:T`: trace the source, find
the lifetime, compare against the destination scope.

### Audit matrix — assert compile result for each path

The matrix runs in **both directions**: every entry has a
positive case (must compile) and a negative case (must error).
This catches both false negatives (missed escape paths in the
walker) AND false positives (the walker over-restricts valid
patterns). Atomic-captured BG handles are the test vehicle, but
**every cell validates the lifetime system in general**, so any
fix benefits observables and `RETURNS foo:T` too.

For each row below: `bg` is a BG handle whose lifetime is bound
to a `@shared:atomic` `counter`. POS = destination scope ≤
counter's scope (must compile). NEG = destination scope >
counter's scope (must error with a clear diagnostic).

### Direct assignment (POS + NEG each)

- `a.field = bg` where `a` is same-scope as counter (POS) / outlives counter (NEG)
- `a.field.nested = bg` (deeper field path; same axes)
- `arr[i] = bg` (indexed slot store)
- `map[k] = bg` (indexed map store)

### Collection store (POS + NEG each)

- `list.append(bg)`
- `list.insert(i, bg)`
- `set.add(bg)`
- `map.insert(k, bg)`
- `queue.push(bg)` (queue case from §6 — POS for same-scope queue, NEG for long-lived queue)

### Function escape

- POS: `RETURN bg` from a fn declared `RETURNS counter:~Void`
- NEG: `RETURN bg` from a fn with no `RETURNS x:T` lifetime
- NEG: `RETURN bg` from a fn with `RETURNS y:T` where `y` ≠ counter (or its source chain)
- POS: `RETURN bg.something` where `something` is a same-lifetime substructure
- POS: `consume_it(bg)` where `consume_it` is `TAKES` and the param has matching lifetime
- NEG: `consume_it(bg)` where `consume_it` would escape `bg` past counter
- POS/NEG: `GIVE bg` — POS into matching-or-shorter binding; NEG into longer

### Fiber spawn / capture

- POS: `BG { do(bg) }` where the new BG completes within counter's scope
- POS: `DO { do(bg) }` (DO is same-scope by construction)
- POS: `CONCURRENT { do(bg) }` (same)
- NEG: capturing into a BG that escapes counter's scope (e.g., spawn-and-forget)
- POS/NEG: `pipeline | EACH bg.consume` — depends on whether the pipeline outlives counter
- POS/NEG: Lambda `USE bg` capture when lambdas land — same axes

### Indirect propagation (lifetime flows through)

- `Foo { field: bg }` → struct's lifetime contracts to ≤ counter (POS within scope, NEG escape)
- `[bg, other]` → list's lifetime contracts to ≤ counter
- `Some(bg)` → optional's lifetime contracts
- `Union::Variant(bg)` → union's lifetime contracts
- `IF AS w = bg THEN ...` → w inherits bg's lifetime (existing visit_IfBind already)
- `WHEN AS w = bg THEN ...` → match-bind inherits lifetime
- `COPY bg` → COPY produces a value with the **same** lifetime as the source (a copy is still bound by the original lifetime — copying doesn't reset it)

### Multi-binding lifetimes

- BG captures TWO atomics → handle's lifetime is intersection `(a, b)` (must be ≤ both)
- BG captures atomic AND non-atomic → handle bound by atomic only (non-atomic has unrestricted lifetime, intersection drops it)
- POS: `RETURN bg` from a fn declared `RETURNS (a, b):~Void` matching both
- NEG: `RETURN bg` from a fn declared `RETURNS a:~Void` (missing `b`'s constraint)
- Nested BG (BG inside BG) capturing the outer atomic — inner handle inherits outer's lifetime, capped at outer atomic's scope

### Edge cases that have historically been gap candidates

- Atomic captured by reference into a fn that itself captures it into a BG (transitive lifetime through a borrowing fn signature)
- Lifetime escape through a struct method call: `wrapper.method(bg)` where `method` returns `bg` extracted from a field
- Lifetime escape through error path: `bg catch fallback` where `fallback` escapes
- Lifetime escape through pipeline terminal: `... | EACH x -> store(bg)` when pipeline is bounded vs unbounded

### Per gap found

Each test that initially fails to compile-error (gap in walker)
becomes a fix in `src/annotator.rb` or related. The fix usually
benefits observables too. Track gaps as their own tranche items;
don't silently extend the audit.

### Acceptance for M2

M2 ships only when **every cell in the matrix above** either:
- Compile-errors with a clear diagnostic naming the binding and
  the escape path, OR
- Is documented as intentionally allowed (with a passing
  positive-case test confirming the allowed path stays compiling).

No "TODO: enforce later" tags. M2 is the safety milestone; if
the walker has a hole, M2 doesn't ship.

## 9. Next steps (once this doc is approved)

### M1 — `@shared:atomic` works at all (Arc'd, no lifetimes)

Mirrors MVCC L1-L8. Roughly:

1. Lift `Atomic(T)` from `lib/observable.zig` (already
   AtomicInt/AtomicFloat/AtomicBool) into `lib/atomic.zig` or
   alias under a new generic name.
2. Parser: `@shared:atomic` capability sigil.
3. Type axis: `:atomic` shape attr on Type; `zig_type` lowers to
   `Arc(Atomic(T))`.
4. Annotator: capability validation + REQUIRES `c: ATOMIC`
   (single + union forms).
5. MIR + codegen: lowered atomic ops (load, store, fetch_*,
   exchange, compareAndSwap; all seq_cst).
6. WITH MATCH `WHEN ATOMIC` arm via comptime dispatch.
7. Tests: transpile-tests for the surface, runtime correctness
   tests against the existing Atomic* primitives.
8. Benchmark: atomic vs locked single-counter, expect ~5-10x on
   32 cores under contention.
9. `clear fix` migration: `@shared:locked` cell with only
   `+=`/`-=`/load/store ops → `@shared:atomic`.
10. Doctor heuristic on lock-profile data.

Ship target: ~2 weeks of focused work after design lands.

### M2 — drop the Arc, attach lifetimes (with lifetime-system unification)

1. **Unify `non_escaping` flag and `RETURNS foo:T` lifetime into
   one mechanism.** If they're separately implemented today,
   replace the flag with a lifetime field on SymbolEntry that
   defaults to "current scope only" for existing call sites
   (preserving observable behavior). One walker, one model.
2. Migrate `@shared:atomic` from `Arc(Atomic(T))` to bare
   `Atomic(T)` in declaring scope.
3. Tag BG handles that capture `@shared:atomic` bindings with
   their captured-atomic's scope as their lifetime — via the
   unified mechanism from step 1.
4. Extend `RETURNS foo:T` parser to accept multi-binding form
   `RETURNS (foo, bar):T`.
5. Extend lifetime checker for multi-binding lifetimes
   (intersection semantics).
6. **Run the §8 audit matrix in BOTH directions** — every escape
   path has both a positive case (must compile) and a negative
   case (must error). Fix gaps in the walker as found. Track
   each gap as its own tranche item; don't extend the audit
   silently.
7. Restrict mixed-cap REQUIRES with returned captured BG: error
   when `REQUIRES c: ATOMIC | <non-atomic>` and fn returns a
   future capturing `c`.
8. `clear fix` migration: M1-style code that escapes
   `@shared:atomic` past its scope (long-lived queue push,
   long-lived struct store, RETURN without lifetime) → suggest
   `@shared:locked` or wait-for-v0.3 atomic-struct-field
   workaround.
9. Doctor diagnostic: "this fn captures atomic into long-lived
   queue; M2 disallows this. Use @shared:locked or wait for
   v0.3 atomic struct fields."

Ship target: ~2 weeks after M1.

### Total scope

M1 + M2 together: ~4 weeks of focused work, similar to MVCC
v0.2. Both ship before v0.2 cuts.
