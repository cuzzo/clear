# Concurrency Architecture Plan

**Status:** Design proposal. Supersedes `Functions take Types, not Capabilities` (CLAUDE.md).
**Goal:** Deliver CLEAR's defining promise — *swap concurrency models without rewriting your code* — for real workloads, not just toys.

---

## Executive summary

CLEAR today places capabilities (sync, ownership) in the type system, then strips them at function boundaries. This delivers neither the local readability of Rust's explicit signatures nor the refactor stability of binding-driven flow. Real applications hit the wall: long-running functions with internal concurrency over shared state can't be expressed cleanly.

This plan moves capabilities from types to **binding metadata**, infers **effects** from function bodies, projects effects onto signatures via the **formatter**, and adds **call-site policies** (`@contends`, `@isolate`) for fine-grained sharing/isolation overrides. Most functions become capability-agnostic. Refactor cost drops to one binding declaration change. Effects stay visible at function boundaries.

The implementation surface is bounded (~3-5 weeks), built on infrastructure CLEAR already has (storage propagation, AST stamps, comptime polymorphism), and delivers genuine wins over Rust on refactorability without sacrificing correctness.

---

## Goals (priority-ordered)

1. **Correct.** Compiler enforces concurrency invariants by construction. Sound or refused, never silently wrong.
2. **Safe.** Deadlock, hold-lock-across-yield, reentrant-without-support — caught at compile time.
3. **Understandable.** Local reasoning preserved. Effects visible at function signatures.
4. **Refactorable.** Switching concurrency strategies is a one-line binding change. Signatures auto-update.

The fourth goal is what differentiates CLEAR from Rust. The first three are non-negotiable; without them, the fourth is worthless.

---

## Motivating problem: the bytecode VM's shared pool

This design didn't emerge from theory. It emerged from a real, concrete failure that exposed exactly where the current model breaks down. The case is small enough to walk through end-to-end and large enough to demonstrate every property the proposal must deliver.

### The shape of the problem

The bytecode VM (`examples/minivm/_bc_runner.cht`) stores environments in a pool, shared across the interpreter and any fibers it spawns:

```clear
FN exec!(ops: Int64[], consts: Value[], envId: Id<Env>,
         MUTABLE pool: Env[50000]@pool, ...) RETURNS Value EFFECTS REENTRANT ->
    -- ... interpreter loop ...
    -- BG_SPAWN handler: run the fiber's bytecode in a separate fiber
    bgResult = exec!(ops, consts, curEnv, pool, bgEntry, bgCaps);    -- (Phase 1: synchronous)
END

FN main() ->
    MUTABLE pool: Env[50000]@pool = [];
    bcResult = exec!(bcOps, bcConsts, rootId, pool, 0_i64, mainCaps);
END
```

Phase 1 ran the recursive `exec!` synchronously. Correct, but no real concurrency — fibers run serially. Phase 2's goal: wrap the recursive `exec!` in a real `BG { ... }` block so spawned fibers actually run on the scheduler.

### What we tried

The minimal change:

```clear
bgPromise: ~Value = BG {
    exec!(COPY ops, COPY consts, curEnv, pool, bgEntry, GIVE bgCaps);
};
bgResult = NEXT bgPromise;
```

### What the compiler said

```
BG block captures values that cannot safely cross the fiber boundary:
  - 'pool' is @pool/@map/HashMap — wrap in @shared:locked, or GIVE/COPY inside the BG body.
```

The diagnostic is correct. `pool` is a heap-cleanup type; the fiber outlives the spawning scope; bare capture is unsafe. The compiler refuses, exactly as it should.

### The natural fix — that doesn't work

Add the capability:

```clear
FN main() ->
    pool: Env[50000]@pool = [] @shared:locked;     -- now Arc-wrapped + locked
    exec!(...)
END
```

Now the BG capture would classify as `RcClone` (safe to share across fibers). Problem solved?

No. The capability immediately gets stripped at `exec!`'s function boundary. Inside `exec!`, parameter `pool` has `sync = nil`. The BG block sees `pool` as bare again. Same error.

The CLAUDE.md rule said this was the design: *"Functions take Types, not Capabilities. Capabilities are unwrapped at the call site using WITH blocks."* So we'd need to thread `WITH EXCLUSIVE pool` around every call into `exec!`, and inside `exec!` we'd lose the wrapper, so the BG inside `exec!` couldn't capture the @shared:locked form, so the original problem returns.

### The grep that confirmed the gap

A scan of `transpile-tests/`:

```bash
grep -rn ": .*@shared:locked\b" transpile-tests/ | grep "FN "
# zero hits. No test passes @shared:locked across a function boundary.
```

The pattern wasn't refused by mistake. It wasn't supported. **Every existing CLEAR test handles shared synchronized state at the same lexical level it's declared.** The moment you cross a function boundary, the sync capability is gone — and there's no escape hatch except restructuring the program to not cross.

### Why this is the right test case

The VM exposes the problem in its purest form because:

1. **`exec!` is long-running.** It can't just be inlined into `main` to keep the capability lexically attached.
2. **The fiber spawn is internal.** It happens inside the interpreter loop, far from `main`. The capability has to survive the function call to be capturable by the BG.
3. **`pool` is shared by design.** It can't be COPY'd (50,000 entries; expensive) or GIVE'd (caller still uses it). It genuinely needs to be shared with sync.
4. **The pattern is universal.** Any long-running coordinator that spawns workers over shared state has this shape: web servers, schedulers, parsers with backtracking, build systems, transactional engines. If the VM can't be expressed cleanly, none of these can.

### What Option I delivers for this case

After implementing the binding-metadata model:

```clear
FN exec!(ops: Int64[], consts: Value[], envId: Id<Env>,
         pool: Env[50000]@pool, ...) RETURNS Value
    ! yield                                              -- effect projected (BG / NEXT)
->
    -- ... interpreter loop ...
    bgPromise: ~Value = BG {
        exec!(COPY ops, COPY consts, curEnv, pool, bgEntry, GIVE bgCaps);
        -- pool's binding metadata flows from main → exec! → fiber.
        -- Fiber captures via RcClone (Arc retain on the @shared:locked wrapper).
    };
    bgResult = NEXT bgPromise;
END

FN main() ->
    pool: Env[50000]@pool @shared:locked = [];     -- one line changed
    bcResult = exec!(bcOps, bcConsts, rootId, pool, 0_i64, mainCaps);
END
```

`exec!` does not use a `WITH` block on `pool` — it accesses pool entries through atomic primitives that work for any binding capability. **No `REQUIRES` clause needed.** The capability metadata flows in transparently from `main`, threads through the recursive call, and reaches the BG capture which classifies as `RcClone` (Arc retain on the `@shared:locked` wrapper).

What the diff actually contains:

| Site | Lines changed |
|---|---|
| `main()`'s pool declaration | 1 (add `@shared:locked`) |
| `exec!`'s signature | 0 author-written; `! yield` is formatter-projected |
| `exec!`'s body | ~5 (the BG_SPAWN block now wraps `BG { ... }`) |
| 16 helper functions taking `pool` as parameter | 0 (no REQUIRES; capability flows through) |
| 42 pool access sites in `exec!` | 0 (atomic primitives auto-dispatch via comptime polymorphism) |

**Total: ~6 lines changed in a 3,000-line file.**

The same migration in Rust would touch every signature with `&mut Pool<Env>`, change every accessor, restructure the BG capture site, and probably require splitting `exec!` into multiple specialized variants. Conservatively: 200+ lines of mechanical edits.

### The compile-time guarantees that come for free

Once the binding-metadata flow exists, several invariants come along:

1. **No REQUIRES on `exec!` or its 16 helpers.** None of them use WITH on `pool`. Capability stays metadata; signatures stay clean. Adding a `REQUIRES pool: LOCKED` would be incorrect — there is no WITH boundary.

2. **`exec!`'s signature gains `! yield`** automatically (from the BG / NEXT). Readers see at a glance that calling exec! may suspend the fiber.

3. **Hold-lock-across-yield is detected** in any helper that *does* introduce a `WITH EXCLUSIVE pool[envId] AS env { ... }` block (e.g., a transactional environment-swap path). That helper would have `REQUIRES pool: LOCKED`; if its WITH spans a `NEXT`, the compiler errors with a precise diagnostic.

4. **Reentrant detection.** When a helper *with* REQUIRES is called from inside an outer WITH on the same pool, the aliasing analysis flags the reentrant acquisition before runtime. Without the new design, the bug surfaces as a deadlock under load.

5. **Multi-resource WITH for transactional pool ops.** When two pool entries need to be modified atomically (e.g., during a TCO call's environment swap), `WITH EXCLUSIVE pool[envA], pool[envB] AS (a, b) { ... }` handles it. The function performing this op has `REQUIRES pool: LOCKED`; the compiler enforces deadlock-safe shard ordering inside the arm.

6. **`@contends` for COPY → CLONE on the bytecode args.** `BG { exec!(COPY ops, ...) }` deep-copies a 100KB bytecode array into the fiber. With `@shared:locked` + `@contends`, the deep copy can become an Arc retain — the fiber shares the same bytecode, no copy. One annotation; major memory savings.

### What this single example demonstrates

Every claim in the proposal traces back to this case:

| Claim | Demonstrated by |
|---|---|
| Capabilities flow through function boundaries | `pool` retains `@shared:locked` inside `exec!`, no REQUIRES needed |
| REQUIRES is only at WITH boundaries | `exec!` has none; transactional helpers gain one line |
| Function signatures stay clean | `exec!`'s parameter list unchanged; `! yield` is formatter-projected |
| Refactor cost is one line | `pool` declaration in `main()` |
| Sync-agnostic functions stay agnostic | 16 helpers, 42 access sites: zero changes |
| WITH polymorphism over capability (in REQUIRES'd helpers) | Same WHEN-LOCKED arm works for `@locked` and `@shared:locked` |
| Compile-time correctness | Hold-across-yield + reentrant detection apply at REQUIRES'd helpers |
| Memory-vs-contention trade-off | `@contends` on bytecode args |

**This is the test case the design must satisfy.** If a proposal can't deliver this migration cleanly, it doesn't deliver CLEAR's core promise.

---

## Three-layer architecture

| Layer | What it describes | Authority | Lives on |
|---|---|---|---|
| **Type** | Shape of data | Programmer (declaration) | The value |
| **Capability** | Sync, ownership, sharing of binding | Programmer (declaration) | The binding (`SymbolEntry`) |
| **Effect** | What a function might do | Compiler (inferred) | The signature (projected by formatter) |

Each layer has a single source of truth. Types describe data shape. Capabilities describe binding access discipline. Effects describe function behavior. Compiler propagates capabilities through call graphs and infers effects on the way up.

### Why this works

CLEAR already does layer 2 for storage. `EscapeAnalysis.tag_transitive_propagation!` propagates `storage` and `provenance` through call graphs as binding metadata. We extend the same mechanism to `sync` and `ownership`. Not new infrastructure — a new use of existing infrastructure.

Layer 3 is computed mechanically from layer 2 plus body analysis. The formatter writes effects into source as a post-step. Authors don't write effects; readers see them in source after `clear fmt`.

---

## Capabilities are binding metadata

### Today's behavior (broken)

```clear
c = Counter{} @shared:locked          -- type: Counter@shared:locked
bumpIt(c)                              -- silently strips @shared:locked at call boundary
```

Inside `bumpIt`, parameter `c`'s binding has `sync = nil`. WITH EXCLUSIVE on it errors: *"requires a @locked or @writeLocked variable, got stack."*

### Proposed behavior

```clear
c = Counter{} @shared:locked          -- binding metadata: sync = :locked, ownership = :shared
bumpIt(c)                              -- caller's metadata flows to callee's parameter binding
```

Inside `bumpIt`, parameter `c`'s binding inherits `sync = :locked, ownership = :shared`. WITH EXCLUSIVE works. The function's source code is identical regardless.

### What this requires

1. Move `sync` and `ownership` from `Type` to `SymbolEntry`. Type keeps fields for parser back-compat; truth lives on the binding.
2. In `function_analysis.rb` parameter declaration (line 549), pass through caller's binding metadata.
3. Add a per-call propagation pass mirroring `tag_transitive_propagation!` but for sync/ownership.
4. WITH-block validation already reads from `SymbolEntry#sync` (line 85, capabilities.rb) — no change needed.

The infrastructure is mostly there. The propagation step is missing.

---

## Capability flow: seamless except at WITH boundaries

Binding capability flows through every function call by default. A function's source is identical regardless of whether its caller's binding is bare, `@locked`, `@shared:locked`, or `@sharded:locked(N)`. The compiler resolves the realization per call site via comptime polymorphism (Zig's `@hasField` dispatch, already used for shape).

```clear
FN incrementCounter(c: Counter) ->
    c.value += 1                        -- atomic; works under any binding capability
END

FN bumpAll(counters: Counter[]) ->
    FOR c IN counters DO incrementCounter(c) END
END
```

No annotations. No effect signatures. No `REQUIRES` clause. Capability is metadata on the binding; the function is polymorphic. **For ~80% of typical application code, this is the whole story.** Refactoring a binding's sync strategy doesn't touch any of these functions.

### The polymorphic stdlib

The atomic primitives are load-bearing. They must work correctly under any binding capability:

| Primitive | Bare | @locked | @shared:locked |
|---|---|---|---|
| `c.value` (read) | direct | lock-read-release | Arc-deref + lock-read-release |
| `c.value = x` (write) | direct | lock-write-release | Arc-deref + lock-write-release |
| `lst.append(x)` | direct | lock-append-release | Arc-deref + lock-append-release |
| `map.put(k, v)` | direct | lock-put-release | Arc-deref + lock-put-release |
| `c.atomicAdd(n)` | direct | lock-add-release | Arc-deref + lock-add-release |

The runtime helpers exist for shape (`getAt`, `len`, `ItemsAccess`). We add the same pattern for sync (`lockedAccess`, `lockedSet`, etc.). Comptime resolved; zero overhead in the unlocked path.

---

## The exception: functions with WITH blocks

A `WITH` block is the only place in CLEAR where the *strategy* of synchronization is an actual choice. Acquiring a mutex is structurally different from starting an MVCC transaction; the body inside the block runs different code with different failure modes. Different sync families cannot share a single body.

These functions — and *only* these functions — must constrain at the signature which sync families they accept. The constraint is `REQUIRES`:

```clear
FN bumpIt(c: Counter) RETURNS Void
  REQUIRES c: LOCKED
->
    WITH EXCLUSIVE c AS inner { inner.value += 1 }
END
```

`REQUIRES c: LOCKED` says: this function only accepts callers whose binding for `c` is in the LOCKED family (`@locked`, `@writeLocked`, `@shared:locked`, `@shared:writeLocked`, `@sharded:locked(N)`). Capability flow stops being free at this boundary; the compiler refuses any caller whose `c` is bare, ACTOR-bound, VERSIONED-bound, or in any other family.

Code *outside* the WITH block remains capability-agnostic — `parsed = parseData()`, `result = validate(input)`, helper calls — flow through transparently. **REQUIRES is a boundary marker for WITH-using functions, not a global function tag.** A 200-line function with a single 5-line WITH block needs one REQUIRES line.

---

## Multi-strategy WITH: REQUIRES + WHEN arms

Some operations admit more than one sync family. A money-transfer transaction can run as a multi-mutex critical section (LOCKED) or as an MVCC transaction (VERSIONED) — the implementations are genuinely different code with different failure modes, but the *contract* (atomic two-account transfer) is the same. The signature must accept both; the body must dispatch on which one was bound.

CLEAR expresses this with `WITH MATCH`, one `WHEN` arm per accepted family:

```clear
FN transact(x: Account, y: Account, amount: Int64) RETURNS Bool
  REQUIRES x, y: LOCKED | VERSIONED
->
    parsed = parseData()                          -- sync-agnostic
    validated = validateData(parsed)              -- sync-agnostic

    WITH x AS a, y AS b MATCH
        WHEN LOCKED
            -> {
                IF a.balance >= amount THEN
                    a.balance -= amount
                    b.balance += amount
                    RETURN TRUE
                END
                RETURN FALSE
            }
            ON LockTimeout EXIT
            ON Transient RETRY(3)
        WHEN VERSIONED
            -> {
                IF a.balance >= amount THEN
                    a.balance -= amount
                    b.balance += amount
                    RETURN TRUE
                END
                RETURN FALSE
            }
            ON Conflict RETRY(5)
    END
END
```

Two facts read off the signature: (1) `x` and `y` must be bound under LOCKED *or* VERSIONED; (2) the function uses WITH on these two parameters. Code outside the WITH MATCH block is independent of the family that was chosen.

### REQUIRES grammar

```
REQUIRES <param-list>: <family-disjunction>
       [, <param-list>: <family-disjunction>]*
```

- `<param-list>` is one or more parameter names. Group when constraints are shared: `REQUIRES x, y: LOCKED`.
- `<family-disjunction>` is a `|`-separated list from a closed set: `LOCKED | VERSIONED | ACTOR | LOCK_FREE`.
- Conjunction (`&`) is not supported. A parameter belongs to one family per call.
- Nested or computed families are not supported. The set is closed by language design.

Closed family set:

| Family | Includes | WHEN-arm primitives |
|---|---|---|
| `LOCKED` | `@locked`, `@writeLocked`, `@shared:locked`, `@shared:writeLocked`, `@sharded:locked(N)` | acquire / release; `LockTimeout`, `Transient`, `Reentrant` selectors |
| `VERSIONED` | MVCC wrappers (future) | snapshot / commit; `Conflict` selector |
| `ACTOR` | message-passing wrappers (future) | send / await; `MailboxFull`, `Timeout` selectors |
| `LOCK_FREE` | atomic-only wrappers (future) | direct atomic ops; no critical section |

LOCKED is implemented today. The other three are reserved family names so the grammar admits them without a syntax change.

### WITH MATCH grammar

```
WITH <binding-list> MATCH
    WHEN <FAMILY>
        -> { <body> }
        [ON <selector> <action>]*
    [WHEN <FAMILY> ...]*
END
```

- `<binding-list>` is one or more `<arg> AS <inner>` pairs. Multi-resource WITH is supported; ordering is compiler-determined within each arm.
- Each `WHEN` arm corresponds to exactly one family.
- Each arm has its own body and its own `ON` clauses. Failure modes differ per family — LOCKED has `LockTimeout`, VERSIONED has `Conflict`. Selectors are scoped per arm.
- **The compiler enforces that the set of WHEN arms exactly matches the family disjunction in REQUIRES.** Adding a family in REQUIRES requires adding a WHEN arm; removing a family removes its arm. There is no default arm.

### Single-family form (no MATCH)

When REQUIRES contains exactly one family, the MATCH wrapper is omitted:

```clear
FN bumpIt(c: Counter) RETURNS Void
  REQUIRES c: LOCKED
->
    WITH EXCLUSIVE c AS inner { inner.value += 1 }
END
```

Pure sugar; the compiler treats this as `WITH EXCLUSIVE c AS inner MATCH WHEN LOCKED -> { ... } END`.

### The closed set of WITH binding forms

Inside any WHEN arm (or single-family WITH), the binding form is one of:

```clear
WITH EXCLUSIVE x AS inner { ... }                       -- single, exclusive
WITH x AS inner { ... }                                  -- single, read (write-locked types)
WITH EXCLUSIVE a, b AS (ai, bi) { ... }                  -- multi, ordered acquire
WITH EXCLUSIVE pool[key] AS shard { ... }                -- sharded, single key
WITH EXCLUSIVE pool[k1], pool[k2] AS (s1, s2) { ... }    -- sharded, multi-key
WITH EXCLUSIVE pool[k1], a AS (s, ai) { ... }            -- mixed: shard + monolithic
```

Per-family realization is comptime-dispatched. For LOCKED the binding form maps to lock-acquire / lock-release; for VERSIONED it maps to snapshot / commit. The body inside each WHEN arm is the same for all binding capabilities *within that family* — `@locked`, `@writeLocked`, `@shared:locked` all run the LOCKED arm body unchanged.

### What's deliberately not in the design

- **Conditional WITH** ("lock only if locked") — was rejected as Option D; reintroducing it would silently change a function's locking behavior based on caller binding.
- **WITH on bare bindings** — no lock to acquire. Compile error.
- **WITH on `@multiowned` / `@shared` without sync** — Arc retain is not a lock. Compile error; use `CLONE` for explicit retain.
- **User-extensible families** — closed set keeps the language small. New families are language-level decisions.
- **Function-level markers** (`TRANSACTION FN`, etc.) — REQUIRES is the marker. A separate function-level tag would duplicate it.
- **Conjunctive REQUIRES** (`x: LOCKED & VERSIONED`) — a binding belongs to one family at a time.
- **Nested family expressions** — keeps the grammar context-free and the family check linear.

---

## What WITH delivers beyond syntax sugar

Honest accounting: for a single-family, single-mutex case, `WITH EXCLUSIVE c AS inner { ... }` is roughly equivalent to Rust's `let g = c.lock().unwrap(); ...`. CLEAR's value comes from cases that aren't single-mutex.

| Capability | Rust | CLEAR |
|---|---|---|
| Same body for `@locked` and `@shared:locked` | Different code per type | One arm; comptime dispatch |
| Same function for LOCKED and VERSIONED callers | Two functions or trait dance | One WHEN-arm pair |
| Multi-resource deadlock-safe acquire | Programmer-ordered | Compiler-ordered (per arm) |
| Compile-time deadlock detection (transitive) | Not language-level | Yes |
| Compile-time hold-lock-across-yield | Clippy advisory only | Language rule |
| Per-family failure modes (`LockTimeout` vs `Conflict`) | Mixed in error types | Scoped per WHEN arm |
| Effect projection onto signatures | Manual or absent | Formatter-projected (non-REQUIRES effects) |

What WITH gives up vs Rust's MutexGuard:

| Capability | Rust | CLEAR's WITH |
|---|---|---|
| Return a guard from a function | `fn get_guard<'a>(c: &'a Mutex<T>) -> MutexGuard<'a, T>` | Cannot. WITH scope is local. |
| Store a guard in a struct | `struct Holder<'a> { guard: MutexGuard<'a, T> }` | Cannot. No first-class guard type. |
| Release earlier than scope end | `drop(guard)` mid-scope | Cannot. Scope-bound. |
| Pass a guard across function boundary | Yes, with lifetime parameters | Cannot. Pass the wrapper; callee re-WITHs. |

These losses are real. CLEAR's WITH is *less flexible* than Rust's guard but *more polymorphic* (across binding capability and across family) and *more compile-time-checked*. For multi-strategy code — the entire point of CLEAR's pitch — this is the correct trade.

### Today vs after the plan

**Today** (basic WITH, locked family only):
- `WITH EXCLUSIVE x AS y { ... }` works on `@locked`, `@writeLocked`.
- Runtime deadlock / reentrant detection.
- `ON` clauses (`Transient PASS`, `LockTimeout EXIT`, etc.) and `RETRY(N)` sugar.
- Lock ranking via `@locked(rank: N)` for explicit ordering.
- No REQUIRES; no WITH MATCH; no cross-family.

**After the plan**:
- REQUIRES at function signatures gating sync families.
- WITH MATCH / WHEN arms (single-family elided) with per-arm ON clauses.
- Lock-kind polymorphism within LOCKED via comptime dispatch.
- Compile-time deadlock + hold-across-yield detection (transitive).
- Effect projection for non-REQUIRES effects (`yield`, `alloc`, `io`, `fail`).
- VERSIONED family enabled as the second concrete implementation.

The pitch *"swap concurrency models without rewriting your code"* lands once REQUIRES + WITH MATCH ship. Today the language enforces the constraint at runtime; after the plan, at compile time, with explicit per-family bodies.

---

## Call-site policies

For finer-grained per-call decisions, two markers exist. **Closed set; not user-extensible.**

### `@contends` — accept contention to save memory

Allows the compiler to use Arc-clone (CLONE) instead of deep copy (COPY) when sound:

```clear
shared = bigList @shared
process(COPY shared)          -- explicit deep copy: O(n) memory, no contention
process(shared @contends)      -- Arc clone: O(1) memory, contention possible
```

**Conditions for COPY → CLONE conversion (compiler verifies):**
1. The function is **write-isolated**: doesn't mutate the parameter visibly to caller. (Detected from body analysis: only reads, or only writes to its own derived state.)
2. The function is **sync-safe**: no compound ops without WITH on the parameter.
3. **Returns don't preserve aliasing** with the parameter (or are explicitly typed as shared).

If conditions aren't met, the marker errors at the call site with explanation:

```
ERROR: process mutates parameter `data` (line 14: data.append(x)). Cannot
       use @contends — would change observable behavior. Use explicit CLONE
       to acknowledge sharing semantics, or COPY for isolation.
```

### `@isolate` — force isolation when binding suggests sharing

Inverse of `@contends` — force a deep COPY even when the binding is shareable:

```clear
shared_state = makeState() @shared:locked
audit(shared_state @isolate)        -- audit gets its own snapshot; not affected by later writes
```

Used when isolation matters more than memory (audit, snapshots, "what was the state at time T").

### Why a closed set

`@contends` and `@isolate` cover the common policy decisions: "share more aggressively" and "isolate explicitly." Any future markers must be language-level decisions, not user extensions. This prevents annotation soup (Rust's failure mode).

---

## Effect inference and projection

REQUIRES is **authored** — the developer states which sync families the function admits. Effects are **inferred** — the compiler computes the rest of what the function does. The formatter projects inferred effects onto the signature so callers see them at the boundary.

### The effect lattice (closed set, fixed)

| Effect | Meaning | Authored or projected? |
|---|---|---|
| `REQUIRES x: F1 \| F2` | This function uses WITH on `x` under one of the listed families | **Authored** |
| `! yield` | May suspend the fiber | Projected |
| `! alloc(heap)` | May allocate on the heap | Projected |
| `! io` | May do I/O (file/network/system) | Projected |
| `! fail` | May return an error | Projected |
| `! fast_path` | Constraint: function may not have any blocking effect | Authored |

Lock acquisition is *not* a separate effect in this lattice — REQUIRES already captures it at the signature, and the WITH MATCH body makes the per-family acquire / release explicit. Effects cover the orthogonal axes (yield, alloc, io, fail).

### How effects are inferred

Compiler walks the function body, aggregating effects:

| Construct | Contributes |
|---|---|
| `BG { ... }` | `! yield` |
| `NEXT promise` | `! yield` |
| Heap allocation | `! alloc(heap)` |
| File/network/system call | `! io` |
| `try` or `?` | `! fail` |
| Compound op on a `LOCKED` binding without WITH | error: requires WITH (and REQUIRES) |
| Call to function with effect E | E (transitively) |

Effects propagate up the call graph as a simple union — no parameterization over arg bindings is needed because the per-arg sync information is carried by REQUIRES.

### Projection via formatter

**Author writes:**
```clear
FN bumpAndYield(c: Counter, p: ~Value) RETURNS Value
  REQUIRES c: LOCKED
->
    WITH EXCLUSIVE c AS inner { inner.value += 1 }
    RETURN NEXT p
END
```

**Formatter writes (after `clear fmt`):**
```clear
FN bumpAndYield(c: Counter, p: ~Value) RETURNS Value
  REQUIRES c: LOCKED
  ! yield
->
    WITH EXCLUSIVE c AS inner { inner.value += 1 }
    RETURN NEXT p
END
```

REQUIRES stays exactly as the author wrote it. The `! yield` line is appended/updated by the formatter. **REQUIRES is hand-authored intent; effects are mechanically projected.**

**Author-written constraints are respected:** `! fast_path` is a constraint verified against inferred effects. If inferred effects violate the constraint, error at compile time.

---

## Compile-time correctness invariants

The compiler refuses unsound patterns:

### 1. Hold-lock-across-yield

WITH cannot span NEXT, BG, or any MAY_YIELD call. Detected at the offending suspending operation.

```clear
FN bad() ->
    WITH EXCLUSIVE a AS ai {
        result = NEXT some_promise         -- ERROR
        ai.x = result
    }
END
```

```
ERROR: NEXT inside WITH EXCLUSIVE may deadlock.
  `a`'s lock is held while the fiber suspends at NEXT (line 4).
  Other fibers waiting on `a` cannot progress until this fiber resumes.
  Move NEXT outside the WITH or restructure the operation.
```

### 2. Naked nested WITH on different bindings

Multi-lock acquisition must use the multi-resource WITH form for safe ordering.

```clear
FN risky() ->
    WITH EXCLUSIVE a AS ai {
        WITH EXCLUSIVE b AS bi { ... }      -- ERROR
    }
END
```

```
ERROR: nested WITH EXCLUSIVE on `b` while `a` is held may deadlock under
       symmetric callers. Use multi-resource form for deadlock-safe ordering:
         WITH EXCLUSIVE a, b AS (ai, bi) { ... }
```

### 3. Compound op on locked binding without WITH

```clear
FN compound(c: Counter) ->
    c.value += 1            -- only ERROR if c's binding is locked at runtime
END                          -- (compound op atomicity requires WITH)
```

```
ERROR (at the operation): compound mutation on a locked binding requires WITH for atomicity.
  c at line 2 was passed from main:9 with @shared:locked binding.
  Wrap in WITH:
    WITH EXCLUSIVE c AS inner { inner.value += 1 }
  Or use the atomic primitive:
    c.atomicAdd(1)
```

### 4. Reentrant deadlock (compile-time detected)

When the compiler can prove a transitive call would re-acquire an already-held lock:

```clear
FN outer(state: State) ->
    WITH EXCLUSIVE state AS s {
        helper(state)                       -- transitively WITHs state — ERROR
    }
END

FN helper(s: State) ->
    WITH EXCLUSIVE s AS inner { ... }
END
```

```
ERROR: reentrant lock acquisition.
  outer (line 3) holds lock on `state`.
  helper (line 8) acquires lock on parameter `s`.
  At call from outer:4, `s` aliases `state` (held).
  This would error at runtime; caught at compile time.

  Fix: pass the unwrapped inner:
    WITH EXCLUSIVE state AS s {
        helper(s)        -- s is the unwrapped inner; no re-lock
    }
```

This is a **strict improvement** over runtime reentrant detection. Same correctness; earlier feedback; no false positives.

### 5. FAST_PATH violation

```clear
FN tightLoop() ! fast_path ->
    bumpIt(locked_c)                        -- ERROR: bumpIt has REQUIRES (blocking)
END
```

```
ERROR: ! fast_path violated by call to bumpIt(locked_c).
  bumpIt has REQUIRES c: LOCKED — implies blocking lock acquisition.
  ! fast_path forbids blocking effects.

  Either: drop locked_c's sync wrapper (if appropriate), or
          remove ! fast_path from tightLoop, or
          replace the call with a non-blocking equivalent.
```

### 6. Capability mismatch at call site (REQUIRES violation)

```clear
FN compute(c: Counter) RETURNS Void
  REQUIRES c: LOCKED
->
    WITH EXCLUSIVE c AS inner { ... }
END

FN main() ->
    bare = Counter{}
    compute(bare)                           -- ERROR
END
```

```
ERROR: compute requires `c: LOCKED` (line 2). `bare` is bound without sync at main:6.
  Resolutions:
    1. Add a LOCKED binding to `bare`:
         MUTABLE bare: Counter @locked = ...
    2. If WITH is unnecessary inside compute, drop the REQUIRES and use atomic ops.
    3. Call a different function intended for bare data.
```

A binding from a family not in REQUIRES (e.g., a future ACTOR-bound `c` against `REQUIRES c: LOCKED`) produces the same shape of error.

### 7. REQUIRES / WHEN exhaustiveness

The set of WHEN arms must exactly match the family disjunction in REQUIRES — same families, no extras, no missing.

```clear
FN transact(x: Account, y: Account) RETURNS Bool
  REQUIRES x, y: LOCKED | VERSIONED
->
    WITH x AS a, y AS b MATCH
        WHEN LOCKED -> { ... }
        -- missing WHEN VERSIONED arm                  -- ERROR
    END
END
```

```
ERROR: WITH MATCH at line 4 is missing a WHEN arm for VERSIONED (declared in REQUIRES at line 2).
  Add an arm:
    WHEN VERSIONED
        -> { <body for MVCC strategy> }
        ON Conflict RETRY(N)
```

The inverse error fires for an extra arm not declared in REQUIRES (`WHEN ACTOR` arm without `ACTOR` in the disjunction).

### 8. WITH on a parameter requires REQUIRES on that parameter

```clear
FN bumpIt(c: Counter) RETURNS Void ->        -- no REQUIRES
    WITH EXCLUSIVE c AS inner { inner.value += 1 }   -- ERROR
END
```

```
ERROR: WITH at line 2 uses parameter `c`, but `c` is not constrained by REQUIRES.
  Add a REQUIRES clause naming the families this function supports:
    REQUIRES c: LOCKED
  REQUIRES is mandatory whenever WITH is used on a parameter — capability flow stops here.
```

This is the architectural rule: capabilities flow seamlessly through every function *except* those that use WITH on a parameter, where REQUIRES is mandatory. No silent capability-stripping; no implicit constraint.

### Performance is best-effort, not enforced

Per-access locking on hot loops, suboptimal lock kind, missing WITH amortization — these are **warnings**, not errors. Discoverable through `clear suggest sync` (architectural lints below).

---

## Architectural lints (`clear suggest sync`)

A separate analysis pass detects structural patterns and suggests refactorings. Not blocking; advisory. Run on demand or in CI.

### Detected patterns

**1. Mixed-modality functions** — body has both pure regions and WITH blocks.

```
SUGGESTION (sync-mixing) at src/handler.cl:42:
  processRequest mixes pure (lines 2-3, 10) and transactional (lines 4-8) logic.
  
  Extract the transactional block:
    FN upsertRecord(db: Database, parsed: Parsed, validated: Validated) ->
        WITH EXCLUSIVE db AS d { ... }
    END
  
  After extraction:
    processRequest:  () [no REQUIRES, no effects]
    upsertRecord:    REQUIRES db: LOCKED; ! yield
  
  Apply: clear refactor extract-transaction processRequest:4-8
```

**2. Ballooning effect surface** — function picks up many effects from many bindings.

```
WARNING (effect-balloon) at src/orchestrator.cl:18:
  orchestrate has 6 effects across 3 locked bindings.
  Effects come from: lock(a)@line:12, lock(b)@line:23 (transitive), lock(c)@line:34,
    yield (b is @shared:locked), alloc(heap)@line:36, fail@line:19.
  Consider whether these belong in one function.
```

**3. Repeated WITH pattern** — same structure across multiple functions.

```
SUGGESTION (duplication) across src/handler.cl:7,15,23:
  handleA, handleB, handleC share the same transactional pattern.
  Consider extracting:
    FN bumpAndLog(state) -> WITH EXCLUSIVE state AS s { s.counter += 1; log(s.id) } END
```

**4. Hot-loop without WITH amortization** — repeated atomic ops on a locked binding inside a loop.

```
PERFORMANCE (hot-loop) at src/loop.cl:103:
  1,000,000 atomic ops on a @locked binding without WITH amortization.
  Each op acquires/releases independently (~25ns × 1M = ~25ms).
  
  Consider hoisting:
    WITH EXCLUSIVE counter AS c {
        FOR i IN 0..1000000 DO c.value += 1 END
    }
  
  Trade-off: holds the lock for the loop duration. Verify no other fibers need
  counter during this time.
```

**5. Effect propagation surprise** — function picks up effects from deep call chain.

```
NOTE (transitive-effect) at src/auth.cl:42:
  handleLogin has REQUIRES userDb, auditLog: LOCKED; ! yield alloc(heap) fail.
  Trace:
    handleLogin → lookupUser → ... → WITH on userDb at authdb.cl:47
    handleLogin → audit → ... → WITH on auditLog at audit.cl:12

  If unexpected, consider isolating the lock-using parts in lookupUser/audit so
  handleLogin's signature stays REQUIRES-free.
```

**6. Multi-lock transaction (3+ locks)** — flag for human review.

```
WARNING (multi-lock) at src/twoPhase.cl:55:
  WITH acquires 4 locks simultaneously. Multi-lock transactions are
  deadlock-prone and can serialize unrelated workloads. Consider:
    - Breaking into smaller transactions if operations don't need full atomicity
    - Using sharded data structures to reduce lock granularity
    - Documenting why this many locks are needed
```

### Auto-applicable refactorings

For structural patterns (mixed-modality, duplication, hot-loop), the lint produces a code action that can be applied via `clear refactor`. For semantic patterns (ballooning, propagation-surprise, multi-lock), the lint informs but human judgment decides.

### Why this matters

The strategy of "sync-agnostic by default; transactional functions isolated" risks **drift** — over time, sync logic creeps into functions that should stay pure. Without tooling, the codebase accumulates mixed-modality functions and the architectural win erodes.

The lint pass gives users a feedback loop: write code naturally → run `clear suggest sync` → see structural improvements → apply via tooling. **The compiler becomes a coach for sync architecture**, not just a verifier. This is what makes the architecture durable across team and time.

---

## Migration workflow: profile → bench → fix → done

The full developer experience for changing a sync strategy. This is the workflow CLEAR was designed to make possible — none of the steps are theoretical; each maps to existing or planned tooling.

### The shape

```
1. Write code naively (most fns sync-agnostic, few WITH blocks).
2. Tests pass (capability-agnostic; survive any future migration).
3. Ship.
4. Profile in production. Lock-wait time on `pool` is 30% of CPU.
5. Run: clear bench --parameterize pool over @locked, @writeLocked,
                                       @sharded:locked(4), @sharded:locked(8)
   Output: @sharded:locked(8) is 4x faster on this workload.
6. Run: clear fix --migrate pool:@locked-to-@sharded:locked(8)
   Tool walks through 3 suggested changes. Accept each.
7. Tests re-run automatically — all green (test source unchanged).
8. Re-profile: lock-wait is now 6%. Done.
```

**Lines of code touched: ~5.** Binding declaration plus a few WITH blocks the tool flagged. Test suite: zero changes. Helper functions: zero changes. Decision is *data-driven* (the benchmark) and *reversible* (one binding declaration line).

This is the artifact that makes CLEAR's pitch concrete: not "the language supports refactoring" in the abstract, but "here is the tool sequence; here is the line count; reproduce it yourself."

### Step 4: profile

Standard profiling tooling (`clear profile`, `clear doctor` per the existing CLAUDE.md). The output identifies bindings whose access patterns are dominating runtime cost — high lock-wait time, high allocation pressure, high cache miss rate.

The profiler isn't part of this proposal; it already exists. What's new is **the strategies the developer can switch to** as a result of the profile.

### Step 5: parameterized benchmarks

A dedicated benchmark grammar that runs the *same workload* across multiple sync strategies and produces comparable numbers.

```clear
BENCHMARK "counter throughput under contention"
PARAMETERIZE c.capability OVER:
  @locked
  @writeLocked
  @shared:locked
  @shared:writeLocked
  @sharded:locked(2)
  @sharded:locked(4)
  @sharded:locked(8)
{
    c = Counter{value: 0}
    fibers(8) { LOOP(1_000_000) { bumpIt(c) } }
}
```

Output:

```
BENCHMARK counter throughput under contention (8 fibers, 1M ops each)

  @locked                     312 ops/µs   ████████░░░░░░░░░░░░
  @writeLocked                289 ops/µs   ███████░░░░░░░░░░░░░
  @shared:locked              298 ops/µs   ███████░░░░░░░░░░░░░
  @shared:writeLocked         304 ops/µs   ████████░░░░░░░░░░░░
  @sharded:locked(2)          521 ops/µs   █████████████░░░░░░░
  @sharded:locked(4)          873 ops/µs   ██████████████████░░
  @sharded:locked(8)          941 ops/µs   ████████████████████
```

The developer sees the actual numbers for *their* workload across *all* the strategies, then picks. This is the flip of today's reality where Rust users research third-party crate benchmarks for workloads that may not match.

The grammar's key property: **the workload source is unchanged across all parameterizations.** `bumpIt(c)` is sync-agnostic; the runner re-binds `c` per parameterization and the comptime dispatch handles the rest.

### Step 6: `clear fix` — guided migration

Interactive walker. Like `git rebase -i` but for sync migrations.

```bash
$ clear fix --migrate pool:@locked-to-@sharded:locked(8)

Found 1 binding to migrate:
  pool: Env[50000]@pool  →  Env[50000]@pool @sharded:locked(8)
  declared at examples/minivm/_bc_runner.cht:2988

Analyzing impact...
  ✓ 15 functions take pool as a parameter — all sync-agnostic, no changes
  ✓ 42 atomic access sites (pool[id], pool.insert) — no changes (auto-dispatch)
  ⚠ 3 compound op sites need WITH wrapping (shard-aware)
  ⚠ 16 function signatures will gain effect annotations after format

  Estimated diff: 14 lines

Walk through changes? [Y/n/preview]
```

Per-site interaction:

```
[1/3] Compound op needs WITH wrapping:
  examples/minivm/_bc_runner.cht:1657
    IF pool[envId] AS env THEN env.vars[defName] = COPY val; END
                  ↑ compound: read-then-modify on a sharded binding

  Suggested fix:
    WITH EXCLUSIVE pool[envId] AS env { env.vars[defName] = COPY val; }

  [a]pply / [s]kip / [e]dit / [d]iff / [q]uit > a
  Applied. (commit pending)

[2/3] ...

After all sites:
  Run formatter to update effect signatures? [Y/n]
  Run test suite to verify? [Y/n]
  Stage changes? [Y/n]
```

What `clear fix` does, structurally:
- Reads the requested migration intent (binding capability change).
- Computes the impact set: which call sites change, which signatures change, which WITH blocks need attention.
- Walks the developer through each impact site with a suggested fix.
- Per-step checkpoints (undo individual applications).
- Optionally re-runs format, tests, and benchmarks at the end.
- Stages the result for review.

The compiler already has the analysis pieces (`clear suggest sync`, effect inference, capability propagation). `clear fix` is the *coordination layer* over them, providing the workflow.

### Why this composes

Each tool reuses prior infrastructure:

| Tool | Built on |
|---|---|
| `clear profile` / `clear doctor` | Existing (heap/CPU/syscalls/HW counters) |
| `clear bench --parameterize` | Standard benchmark runner + capability-polymorphism |
| `clear suggest sync` | Effect inference + capability flow |
| `clear fix` | `suggest sync` + interactive walker + git-like checkpointing |

There's no tool that requires *new* compiler analysis beyond what the design already provides. The tooling story is the *interface* over existing analysis, not a separate effort.

---

## Capability-agnostic tests and benchmarks

The deeper consequence of the design: **tests and benchmarks survive sync migrations.** This isn't a marketing claim — it's a structural property of capability-as-binding-metadata.

### Tests

A test asserts on behavior:

```clear
TEST "counter increments correctly" {
    c = Counter{value: 0}
    bumpIt(c)
    bumpIt(c)
    ASSERT c.value == 2
}
```

This test passes for any binding capability, because `bumpIt` is sync-agnostic. **Run the same test source under different sync strategies** by parameterizing the binding:

```clear
TEST "counter increments correctly"
PARAMETERIZE c.capability OVER: bare, @locked, @shared:locked, @sharded:locked(2)
{
    c = Counter{value: 0}
    bumpIt(c)
    bumpIt(c)
    ASSERT c.value == 2
}
```

Test runner produces:

```
TEST counter increments correctly
  bare                        ✓ PASS  (12µs)
  @locked                     ✓ PASS  (34µs)
  @shared:locked              ✓ PASS  (47µs)
  @sharded:locked(2)          ✓ PASS  (29µs)
```

Same source, four runs.

### Benchmarks

The same parameterization for benchmarks (shown in the migration workflow above). The framework runs the workload once per parameterization and produces a comparison table.

### Where this is uniquely valuable

- **Regression coverage for sync migrations.** Run the suite under the new strategy before merging. Catches behavioral differences the type system can't (e.g., a compound op whose `WITH` you forgot to add).

- **Authoring once.** No "test for the locked variant" + "test for the bare variant" — one test, parameterized.

- **Strategy choice as data.** The benchmark is the evidence; the strategy is the conclusion. Not "Reddit said RwLock is faster" but "for *my* workload, with *my* tests passing, here are the numbers."

- **Reversibility.** Changed strategy and now contention is worse? Switch back. Tests and benchmarks survive both directions.

### The exception: tests *of* the sync mechanism

Some tests target a specific strategy: "test deadlock detection on @locked," "test sharded fairness." These declare the binding capability concretely:

```clear
TEST "deadlock detected at compile time" {
    -- specifically @locked, no parameterization
    a = Counter{value: 0} @locked
    -- ...
}
```

The framework supports both: parameterized for behavioral tests, fixed for sync-mechanism tests.

---

## Why CLEAR can mechanize this — and Rust structurally can't

The migration workflow above is the developer experience. The reason it's possible in CLEAR is structural; Rust can't match it without a fundamental redesign.

### Four structural properties enabling mechanization

1. **Capability is binding metadata, not type.** Function signatures don't carry `Mutex<T>` or equivalent. Migration doesn't cascade type rewrites through the call graph.

2. **Operations are polymorphic at the comptime level.** `c.value`, `lst.append`, `WITH EXCLUSIVE c { ... }` work across capabilities via `@hasField`-style dispatch. No call-site rewrites for capability changes.

3. **Tests reference behavior, not strategy.** Tests don't import wrapper types. Capability-agnostic by default; explicitly parameterizable when desired.

4. **Effects are projected, not authored.** Signature updates after migration are mechanical; the formatter does them. Author never touches signatures during a migration.

These four together mean a migration tool walks you through the *genuinely changing parts* (compound ops where WITH wrapping is now needed) without manually editing the parts that *don't* change (the 89% of functions that are sync-agnostic).

### Rust's structural blockers

| Migration step | Rust | CLEAR |
|---|---|---|
| Profile | Same (`perf`, `flamegraph`) | Same (`clear profile`) |
| Compare strategies | Manual: write variants in branches; benchmark separately | `clear bench --parameterize` runs all on same source |
| Decide | Same | Same |
| Update binding | 1 line (`Mutex` → `RwLock`) | 1 line (`@locked` → `@writeLocked`) |
| Update fn signatures | **Every fn taking `&Mutex<T>` becomes `&RwLock<T>`** — cascades | **0 signatures** (binding metadata flows; formatter regenerates) |
| Update call sites | **Every `.lock()` → `.write()` or `.read()`** with human judgment | **0 call sites** (`WITH EXCLUSIVE` dispatches; `c.value` polymorphic) |
| Update tests | Often: tests reference wrapper types, must update | 0 (tests parameterized) |

For `Mutex` → `DashMap` in Rust, the difficulty is worse: DashMap has different access methods (`get`, `insert` vs `lock().get()`), no `Iterator` trait the same way, sometimes different return types. It's not a refactoring — it's a rewrite. CLEAR's `@locked` → `@sharded:locked` is one binding declaration plus possibly some `WITH EXCLUSIVE pool[key] AS shard { ... }` wrapping where compound ops live.

### Why the gap is structural, not tooling sophistication

You could in principle build sophisticated migration tooling for Rust. The fundamental problem isn't tool author effort; it's the language's design choice:

> **In Rust, the strategy is encoded in the type.** `Arc<Mutex<T>>` and `Arc<RwLock<T>>` and `DashMap<K,V>` are *different types* with *different APIs*. Migration is a type rewrite plus an API rewrite. The type system *fights* the migration tool, because the tool has to reason about whole-program type changes.

A migration between Rust sync wrappers requires:
1. Understanding which `Mutex<T>` instances are intended to migrate (could be many; not always wholesale).
2. Type rewriting all related signatures.
3. API rewriting all call sites (`.lock()` → `.read()`/`.write()`/`.get()`/`.insert()`...).
4. Reconciling Iterator trait availability, return type differences, error type differences.
5. Updating test code that references the type.

Even rust-analyzer's most advanced refactorings can't mechanize this end-to-end. They can rename, extract, and inline; they can't dispatch operations across types with different APIs. That's not a limitation of rust-analyzer — it's a limitation of *what's mechanizable* given Rust's design.

CLEAR's design choice — *capability is binding metadata, operations are polymorphic, effects are projected* — was made specifically so this *would* be mechanizable. The four structural properties aren't features bolted on; they're the architectural backbone.

### Other languages

| Language | Polymorphic WITH? | Mechanizable sync migration? |
|---|---|---|
| **Rust** | No (types fight; trait bounds verbose) | Partial — sweep-and-replace; not API-aware |
| **Go** | No (no type-level lock abstraction at all) | No (no type system to drive migration) |
| **Java** | No (`synchronized` is method-level; concurrent collections each different APIs) | No (same API-divergence problem as Rust) |
| **Erlang/Elixir** | N/A (actors fundamental; no "lock strategy" abstraction) | N/A (different problem) |
| **Pony / Verona** | No (reference caps are types; same as Rust) | No |
| **Haskell STM** | Sort of (within STM monad) | No (only one strategy: STM) |
| **Swift** (actors) | Partial (`actor` keyword) | No (actors aren't switchable to other strategies) |
| **CLEAR** | **Yes** (binding metadata + comptime dispatch) | **Yes** (the design supports it; tooling builds on existing analysis) |

This is the unique-positioning claim. It's structural, defensible, and demonstrable. Anyone can read CLEAR's design and Rust's `Arc<Mutex<T>>` plumbing and see the difference: in Rust the strategy is *baked into types*; in CLEAR it's *attached to bindings*.

That single design decision is the load-bearing one. Everything in this document — effect projection, compile-time correctness, capability-agnostic tests, parameterized benchmarks, `clear fix`, polymorphic `WITH` — flows from it.

---

## The vision and current state

This document describes the vision in full. Some parts exist today; some are partially realized; many are planned. To be honest about where we are:

### What exists today

- **`SymbolEntry#sync` field** — the storage location for binding-level capability metadata.
- **`tag_transitive_propagation!`** for storage and provenance — the propagation mechanism the design extends to sync.
- **WITH EXCLUSIVE / WITH (read) / multi-resource WITH** — the existing syntactic surface.
- **ON clauses with selectors and actions** — the failure-handling grammar (Transient, LockTimeout, RETRY(N), etc.).
- **CATCH at function boundary** — the function-level failure handler.
- **CaptureStrategy::Refuse** — refuses unsafe BG captures with diagnostics.
- **Comptime polymorphism for shape** — `getAt`, `len`, `ItemsAccess`, `CheatLib.cleanup` already use `@hasField` dispatch.
- **`clear profile` + `clear doctor`** — existing profiling + advice tooling.

### What's partially realized

- **Capability propagation across function boundaries** — works for storage; not yet for sync. Phase 1 of this proposal extends it.
- **Effect annotations on signatures** — implicit via the existing checker; not yet projected onto source.
- **Compile-time deadlock prevention** — runtime detection exists; compile-time detection (Phase 3) is partial.
- **Capability-agnostic `WITH`** — works for the locked family in some cases (the closed-set table in this doc lists which); not yet uniform.
- **Polymorphic stdlib primitives** — `getAt`, `len`, `ItemsAccess` exist; `lockedAccess`, `lockedSet`, etc. don't yet.

### What doesn't exist yet

- **`clear suggest sync`** — the architectural lints. Phase 6.
- **`clear fix`** — the migration walker. Phase 6+ (as a coordinator over `suggest sync`).
- **`clear bench --parameterize`** — capability-agnostic benchmarks. Phase 9 (added to plan).
- **`PARAMETERIZE` in tests** — capability-agnostic tests. Phase 8.
- **`REQUIRES` clause + `WITH MATCH / WHEN`** — Phase 2.
- **VERSIONED family** (MVCC) as the second concrete `WHEN` body — language extension. Future, after LOCKED ships.
- **Effect projection in formatter** — Phase 4.
- **Call-site `@contends` and `@isolate`** — Phase 5.
- **The structural Rust-comparison demo** — depends on all of the above.

### What this means for the proposal

The vision is clear and self-consistent. The implementation is well-scoped (~5-6 weeks of focused work, per the implementation plan). The pieces compose: each phase produces a demonstrable artifact.

But **the vision is not yet realized.** This document is a design proposal, not a description of shipping behavior. Anyone reading it should understand: the case study (the bytecode VM's shared pool) is the test case the design must satisfy; today the VM hits the documented compiler error and Phase 2 is blocked.

The honest framing: *this is what CLEAR can become, with the implementation plan executed end-to-end.* The pitch — refactor sync strategy with one line — is structurally deliverable. It is not yet operationally deliverable. The gap between vision and reality is the 5-6 weeks of work documented above.

That gap is worth closing. Not just because it unblocks the VM, but because it converts CLEAR from "interesting language design" into "the language where switching from Mutex to RwLock to DashMap is one line and twenty seconds." That's a category-defining capability. No other systems language has it. The structural reason CLEAR can have it is the four properties above, and they exist because the design made them load-bearing from the start.

This document is the road map for getting from here to there.

---

## Concrete value examples

### Example 1: switching lock kinds

**Today (Rust-style equivalent):**
```rust
fn handler(state: Arc<Mutex<State>>) { let s = state.lock().unwrap(); ... }
fn worker(state: Arc<Mutex<State>>) { let s = state.lock().unwrap(); ... }
fn coordinator(state: Arc<Mutex<State>>) { ... }
// 30 functions like this

// Switch to RwLock for read-heavy workload:
fn handler(state: Arc<RwLock<State>>) { let s = state.read().unwrap(); ... }
fn worker(state: Arc<RwLock<State>>) { let s = state.write().unwrap(); ... }
fn coordinator(state: Arc<RwLock<State>>) { ... }
// 30 signatures changed; 30 lock() calls changed to read()/write()
```

**CLEAR Option I:**
```clear
-- Before:
state = makeState() @shared:locked

-- After:
state = makeState() @shared:writeLocked

-- Run formatter: signatures auto-update (some show ! lockWrite, others ! lockRead).
-- Function bodies unchanged.
```

**Win:** 1 line changed vs ~30+ lines. Reviewable diff. Functions adapt automatically.

### Example 2: switching from copy-heavy to share-heavy

**Profiler shows:** too many deep copies of `config` (1.2GB/s allocation pressure).

**Rust:**
```rust
// Every fn signature touched: Config → Arc<Config>; every clone → Arc::clone
fn process(req: Request, config: Config) { ... }
fn validate(req: Request, config: Config) { ... }
// 50 signatures, 50 call sites changed
```

**CLEAR:**
```clear
- config = loadConfig()
+ config = loadConfig() @shared
-- One line changed.
-- Optionally mark hot call sites with @contends to allow COPY → CLONE.
-- Functions unchanged.
```

**Win:** 1 line + selective `@contends` markers vs 50+ signatures.

### Example 3: introducing lock-free structure

**Want to make `criticalLookup` lock-free.** Switch from HashMap behind Mutex to sharded HashMap.

**Rust:** every function signature changes type; many functions need internal restructuring.

**CLEAR:**
```clear
- registry = HashMap[]@shared:locked
+ registry = HashMap[]@sharded:locked(8)        -- 8 independent shards

-- Atomic ops on registry (`registry.get(k)`, `registry.put(k,v)`) work unchanged.
-- Transactional WITH on registry: `clear suggest sync` flags for shard-aware refactor.
-- 1-2 functions need attention; the other 30 don't.
```

**Win:** Compiler tells you exactly which functions need attention; the rest adapt automatically.

### Example 4: refactoring a sync-mixed function

```clear
FN handleRequest(req: Request, db: Database, cache: Cache) RETURNS Result
  REQUIRES db: LOCKED
->
    parsed = parseRequest(req)                   -- pure (capability-agnostic)
    cached = cache.lookup(parsed.id)             -- atomic (capability-agnostic)
    IF cached.exists THEN RETURN cached.value END

    WITH EXCLUSIVE db AS d {                     -- transactional
        result = d.query(parsed)
        d.audit(parsed, result)
    }
    cache.store(parsed.id, result)               -- atomic (capability-agnostic)
    RETURN result
END
```

**`clear suggest sync` reports:**
```
SUGGESTION (sync-mixing): handleRequest mixes pure and transactional logic.
  Extract:
    FN executeAndAudit(db: Database, parsed: Parsed) RETURNS Result
      REQUIRES db: LOCKED
    ->
        WITH EXCLUSIVE db AS d {
            result = d.query(parsed)
            d.audit(parsed, result)
            RETURN result
        }
    END

  After extraction:
    handleRequest:    no REQUIRES (capability-agnostic in the rest of its body)
    executeAndAudit:  REQUIRES db: LOCKED; ! yield
```

**Win:** REQUIRES leaves the wrapper function. Capability-agnostic body comes back. Codebase stays clean as it grows.

### Example 5: deadlock detected at compile time

```clear
FN outerCritical(a: Account, b: Account) RETURNS Void
  REQUIRES a, b: LOCKED
->
    WITH EXCLUSIVE a, b AS (ai, bi) {
        adjustBalance(ai)
    }
END

FN adjustBalance(account: Account) RETURNS Void
  REQUIRES account: LOCKED
->
    WITH EXCLUSIVE account AS inner { ... }     -- ERROR (compile-time)
END
```

```
ERROR (reentrant lock):
  outerCritical (line 3) holds locks on `a` and `b`.
  adjustBalance (line 9) acquires lock on `account` parameter.
  At call from outerCritical:5, `account` aliases `a` (held).
  This would deadlock at runtime; caught at compile time.

  Fix: pass the unwrapped inner to adjustBalance:
    WITH EXCLUSIVE a, b AS (ai, bi) {
        adjustBalance(ai)        -- ai is the unwrapped inner; no re-lock
    }
```

**Win:** Deadlock detected at compile time. Production never sees it.

### Example 6: COPY → CLONE via `@contends`

**Caller has a 100KB shared list. Wants to pass it to many readers.**

```clear
shared_list = loadCatalog() @shared            -- Arc-wrapped once
                                                 
-- Pure-reader function:
FN searchCatalog(catalog: List, query: String) RETURNS List ->
    catalog.filter(|item| item.matches(query)) -- read-only, no WITH
END

-- Without @contends:
result = searchCatalog(COPY shared_list, q)    -- 100KB deep copy
                                                 -- per call

-- With @contends:
result = searchCatalog(shared_list @contends, q)  -- Arc-clone (refcount++)
                                                    -- compiler verified searchCatalog is read-only
```

**Compiler verification:**
1. `searchCatalog` is write-isolated (only reads `catalog`) ✓
2. `searchCatalog` is sync-safe (no compound ops without WITH) ✓
3. Returns derived data (filtered list), not aliasing ✓

**Conversion granted:** call site uses CLONE instead of COPY. Memory: O(1) instead of O(n).

**If conditions fail:**
```clear
FN bad(catalog: List) -> catalog.append(x) END
result = bad(shared_list @contends)            -- ERROR
```

```
ERROR: bad mutates parameter `catalog` (line 2: catalog.append).
  Cannot use @contends — would change observable behavior.
  Use explicit CLONE to acknowledge sharing semantics, or COPY for isolation.
```

**Win:** Memory-vs-contention trade-off explicit at call sites. Default behavior (COPY) is safe. Opt-in (`@contends`) is verified before applying.

### Example 7: hold-lock-across-yield prevention

```clear
FN dangerousPattern(state: State) RETURNS Void
  REQUIRES state: LOCKED
->
    WITH EXCLUSIVE state AS s {
        result = NEXT some_promise         -- compiler error
        s.value = result
    }
END
```

```
ERROR: NEXT inside WITH EXCLUSIVE may deadlock.
  `state`'s lock is held while the fiber suspends at NEXT (line 4).
  Other fibers waiting for `state` cannot progress until this fiber resumes.
  
  Fix: separate the fetch from the update:
    promise = some_promise
    result = NEXT promise
    WITH EXCLUSIVE state AS s {
        s.value = result
    }
```

**Win:** A common deadlock-shape eliminated by language-level enforcement. Caught at compile time. Genuinely better than Rust/Tokio (which has clippy lints but not language-level enforcement).

---

## Implementation design

### Shape of the work

Eight phases, ~3-5 weeks of focused work for one engineer. Mostly extension of existing CLEAR infrastructure (storage propagation in `escape_analysis.rb`, AST stamps, comptime polymorphism in stdlib helpers, `CaptureStrategy` for BG safety) — not greenfield design.

Net code estimate: ~2000-3000 lines added, ~500-1000 lines removed (deletion of stripping logic). Primarily Ruby (compiler), with smaller Zig deltas (runtime polymorphic helpers).

**Critical-path dependencies:**

```
Phase 1 (binding metadata move)
    │
    ├──→ Phase 2 (REQUIRES + WITH MATCH parser/check)
    │            │
    │            └──→ Phase 3 (effects + correctness checks) ──→ Phase 4 (formatter projection)
    │                          │
    └──→ Phase 7 (stdlib polymorphism) ─────────────────────────┤
                                                                 │
                                                                 ↓
                                              Phase 5 (call-site policies)
                                                                 │
                                                                 ↓
                                              Phase 6 (architectural lints)
                                                                 │
                                                                 ↓
                                              Phase 8 (integration & VM migration)
```

Phase 7 (stdlib polymorphism) has the longest tail (audit unknowns) — start it early in parallel with Phase 2.

---

### Phase 1: Capability binding-metadata flow (3-5 days)

**Goal:** Move `sync` from being authoritative on `Type` to authoritative on `SymbolEntry` (binding). Type keeps the field for parser back-compat and literal-type queries; binding-level reads switch to the binding.

**Concrete tasks:**

| ID | Task | Files | Effort |
|---|---|---|---|
| 1.1 | Audit reads of `Type#locked?`, `Type#write_locked?`, `Type#any_sync?`, `Type#always_mutable?`. ~25 sites. Classify each as **type-level** (literal type, struct field type) or **binding-level** (the binding's actual capability). | `src/`, `src/mir/`, `src/annotator-helpers/`, `src/backends/` | 0.5d |
| 1.2 | For each binding-level read identified in 1.1, change to read from the binding's `SymbolEntry#sync` (via `node.symbol&.sync` or equivalent path). | Same files as 1.1 | 0.5d |
| 1.3 | Modify parameter binding declaration to accept caller's binding metadata. Currently `function_analysis.rb:549-551` passes `:stack` and no `sync:`. Extend to thread caller-binding-sync into the new param's `SymbolEntry`. | `src/annotator-helpers/function_analysis.rb` | 0.5d |
| 1.4 | Add transitive sync propagation pass mirroring `tag_transitive_propagation!`. For each fn, look at its callers' arg bindings; stamp the param's binding with the most general capability that satisfies all callers. | `src/mir/escape_analysis.rb` (new helper) | 1d |
| 1.5 | Cross-module case: extend `FunctionSignature` to carry binding-capability info per parameter. Module imports propagate from interface to caller's symbol table. | `src/annotator-helpers/function_signature.rb`, `src/backends/importer.rb` | 1d |
| 1.6 | Tests pinning the case-study patterns (Counter, VM-style pool). | `transpile-tests/`, `spec/` | 0.5d |

**Acceptance criteria:**
- Existing test suite (2549 specs, 340+ transpile-tests) still green.
- New transpile-test: `bumpIt(c: Counter)` with `WITH EXCLUSIVE c` inside, called from main with `@shared:locked` binding — compiles and runs.
- VM-style minimal repro: a function taking a `@pool` parameter, called from a context where the pool is `@shared:locked`, can `BG`-capture the pool successfully.

**Risks:**
- *Misclassification in audit (1.1).* A read intended to be type-level reading from binding causes silent regression. Mitigation: spec each site individually; cover with tests.
- *Cross-module signature representation.* Need to decide: binding info on function signatures only, or also on imported types? Defer to Open Question #2.

---

### Phase 2: REQUIRES + WITH MATCH parser and family check (3-4 days)

**Goal:** Add `REQUIRES` clauses and `WITH MATCH / WHEN` arms to the parser, AST, and annotator. Enforce REQUIRES↔WHEN exhaustiveness and the "WITH-uses-param ⇒ REQUIRES-names-param" rule structurally.

**Concrete tasks:**

| ID | Task | Files | Effort |
|---|---|---|---|
| 2.1 | Lex `REQUIRES`, `WHEN`, `MATCH` (in WITH context), and the family identifiers `LOCKED`, `VERSIONED`, `ACTOR`, `LOCK_FREE`. | `src/ast/lexer.rb` | 0.25d |
| 2.2 | Parse REQUIRES clause: `REQUIRES <param-list>: <family-disjunction> [, ...]`. Stamp on `FuncDecl.requires` as `{ param_name => Set[Family] }`. | `src/ast/parser.rb`, `src/ast/ast.rb` | 0.5d |
| 2.3 | Parse `WITH ... MATCH WHEN F -> { ... } [ON ...]* [WHEN F ...]* END`. AST node `WithMatch` carries arms keyed by family. Single-family `WITH` lowers to a one-arm WithMatch internally. | `src/ast/parser.rb`, `src/ast/ast.rb` | 1d |
| 2.4 | Annotator: REQUIRES↔WHEN exhaustiveness check. Set of WHEN-arm families must equal the union of family disjunctions in REQUIRES for the bound params. Diagnostic at the WithMatch site. | `src/annotator-helpers/with_match_check.rb` (new) | 0.5d |
| 2.5 | Annotator: "WITH-on-param ⇒ REQUIRES-names-param" rule. If a `WithMatch` binds a parameter, that parameter must appear in REQUIRES. Otherwise refuse. | `src/annotator-helpers/with_match_check.rb` | 0.5d |
| 2.6 | Call-site family check: at each call to a function with REQUIRES, verify the caller's binding for each constrained arg lies in the disjunction. Diagnostic with both the param and the binding declaration. | `src/annotator-helpers/function_analysis.rb` | 0.5d |
| 2.7 | Specs: positive cases (single-family REQUIRES, multi-family REQUIRES, grouped param-list `x, y: F`), negative cases (missing arm, extra arm, missing REQUIRES on WITH-using fn, family mismatch at call). | `spec/with_match_spec.rb` (new) | 0.5d |

**Acceptance criteria:**
- Parser accepts the canonical REQUIRES + WITH MATCH grammar.
- All four refusal patterns produce the documented diagnostic shape (see Compile-time invariants 7 + 8).
- Single-family `WITH EXCLUSIVE c AS inner { ... }` still parses (sugar; lowers internally to WithMatch with one arm).

**Risks:**
- *Family-name collision with user identifiers.* `LOCKED` etc. are uppercase TYPE_ID-shaped. Mitigation: contextual keywords (only inside REQUIRES / WHEN positions), not reserved globally.
- *Migration of existing WITH-using transpile-tests.* They lack REQUIRES today. Mitigation: pre-Phase-2 compatibility shim — when no REQUIRES is present, treat as `REQUIRES <every-WITH-bound-param>: LOCKED` for one release.

---

### Phase 3: Effect inference + compile-time correctness checks (4-5 days)

**Goal:** Compute the small projected-effect set (`yield`, `alloc`, `io`, `fail`, `fast_path`) and add the four refusal invariants that depend on REQUIRES + effect data.

**Concrete tasks:**

| ID | Task | Files | Effort |
|---|---|---|---|
| 3.1 | Define `EffectSet` data structure: `{ yield, alloc(heap), io, fail }` plus author-written constraint `fast_path`. Operations: `union`, `subtract`, `to_signature`. (No per-arg parameterization needed — REQUIRES carries that information.) | `src/mir/effect_set.rb` (new) | 0.5d |
| 3.2 | Per-function effect inference pass. Construct→effect mapping: `BG`/`NEXT` → `yield`; heap alloc → `alloc(heap)`; FFI/syscall → `io`; `try`/`?` → `fail`. Transitive union over callees. | `src/mir/effect_inference.rb` (new) | 1d |
| 3.3 | **Hold-lock-across-yield**. Walk each `WithMatch` arm body; flag any `yield`-effect node inside. Per-arm; per-family. | `src/mir/mir_checker.rb` | 0.5d |
| 3.4 | **Naked nested-WITH**. Inside any WithMatch arm, refuse another WithMatch on a different binding (different parameter). Suggest the multi-resource form. | `src/mir/mir_checker.rb` | 0.5d |
| 3.5 | **Compile-time reentrant lock detection.** For each WithMatch arm on binding `X`, traverse reachable calls; if a callee's REQUIRES names a parameter that aliases `X` at the call site, refuse. Aliasing analysis is intra-function. | `src/mir/mir_checker.rb` | 1d |
| 3.6 | **FAST_PATH constraint verification.** Functions annotated `! fast_path` — error if inferred effects include `yield` or any REQUIRES on a parameter (REQUIRES implies blocking acquire). | `src/mir/mir_checker.rb` | 0.5d |
| 3.7 | Diagnostics: each error points at the offending op AND the REQUIRES / binding declaration. Specs for each. | `src/mir/mir_checker.rb`, `spec/correctness_check_spec.rb` (new) | 0.5d |

**Acceptance criteria:**
- All four checks fire correctly on prepared violation cases.
- No false positives on the existing test suite.
- Diagnostics include both the violating op and the binding (or REQUIRES) declaration.
- Reentrant detection at compile time matches runtime detection (same cases caught).

**Risks:**
- *Reentrant aliasing precision.* Determining when two parameter bindings alias the same lock requires intra-procedural analysis. Conservative refusal on indeterminate cases; runtime fallback for the rest.
- *Compound-op detection precision.* Define the compound-op set explicitly via stdlib registry annotations; one source of truth.

---

### Phase 4: Effect projection in formatter (2-3 days)

**Goal:** The formatter writes inferred effect annotations into function signatures, alongside (but not replacing) the author-written REQUIRES clause. Author-written constraints (`! fast_path`) are preserved and verified.

**Concrete tasks:**

| ID | Task | Files | Effort |
|---|---|---|---|
| 4.1 | Locate or create the formatter pass that rewrites source. CLEAR may not have one today — if not, add `clear fmt` as a CLI subcommand backed by `src/backends/formatter.rb`. | `src/backends/formatter.rb` (new), `clear` (CLI) | 0.5-1d |
| 4.2 | After effect inference, append/update inferred-effect lines on the signature: `! yield`, `! alloc(heap)`, `! io`, `! fail`. REQUIRES is preserved verbatim from the author. | `src/backends/formatter.rb` | 0.5d |
| 4.3 | Author-written annotation handling: parse author-written `! fast_path`; verify inferred effects don't violate. If they do, error with diff. Idempotent: rewriting a file with up-to-date inferred effects produces no change. | `src/backends/formatter.rb` | 0.5d |
| 4.4 | Idempotency + round-trip property tests: parse → annotate → format → parse → annotate → format produces same source. | `spec/formatter_effect_spec.rb` | 0.5d |

**Acceptance criteria:**
- Running `clear fmt` on the test corpus produces stable output (idempotent).
- Author-written `REQUIRES` survives format passes unchanged.
- Author-written `! fast_path` survives; conflicts produce errors.
- Inferred effects appear in source after first format; remain after subsequent formats.

**Risks:**
- *Diff hygiene.* Refactor commits include both binding changes and formatter-generated effect updates. Mitigation: document workflow; make the formatter changes a separate commit before semantic changes.

---

### Phase 5: Call-site policies (2-3 days)

**Goal:** Implement `@contends` and `@isolate` call-site markers. `@contends` allows COPY → CLONE conversion when conditions are met; `@isolate` forces COPY even when CLONE would be cheaper.

**Concrete tasks:**

| ID | Task | Files | Effort |
|---|---|---|---|
| 5.1 | Parser support for `arg @contends` and `arg @isolate` syntax at call sites. | `src/ast/parser.rb`, `src/ast/lexer.rb` | 0.5d |
| 5.2 | AST representation: stamp `CallSitePolicy = :contends | :isolate | nil` on the arg node. | `src/ast/ast.rb` | 0.25d |
| 5.3 | Verify conditions for COPY → CLONE: walk the called function's body to determine **write-isolation** (does it mutate the param?), **sync-safety** (compound ops covered by WITH?), **return-aliasing** (does it return data that aliases the param?). Conservative refusal on indeterminacy. | `src/annotator-helpers/function_analysis.rb` (extend) | 1d |
| 5.4 | Lowering: for `@contends` args meeting conditions, emit CLONE instead of COPY MIR. For `@isolate` args, emit COPY even on shareable bindings. | `src/mir/mir_lowering.rb` | 0.5d |
| 5.5 | Diagnostics: when `@contends` conditions fail, error explains which condition (write-isolation / sync-safety / return-aliasing) and which line in the called function violated it. | `src/annotator-helpers/function_analysis.rb` | 0.5d |
| 5.6 | Specs and transpile-tests for each direction. | `spec/call_site_policy_spec.rb`, `transpile-tests/` | 0.5d |

**Acceptance criteria:**
- `@contends` works on safe targets: the call emits CLONE; semantics preserved.
- `@contends` errors on unsafe targets: diagnostic identifies the violating condition.
- `@isolate` forces COPY even when binding is shareable.
- Closed marker set documented; no other markers accepted.

**Risks:**
- *Condition-checking accuracy.* Verifying write-isolation requires data-flow analysis through the function body. Conservative refusal might block valid patterns. Mitigation: design test corpus first; spec each pattern explicitly.
- *Scope creep on markers.* Future requests for additional markers should be deferred to a language-level decision, not added on demand. Document "closed set" prominently in language reference.

---

### Phase 6: Architectural lints (`clear suggest sync`) (3-5 days)

**Goal:** Detect six structural patterns; suggest refactorings; auto-apply where mechanical.

**Concrete tasks:**

| ID | Task | Files | Effort |
|---|---|---|---|
| 6.1 | **Mixed-modality detection.** Walk function bodies; identify regions of pure ops vs. WITH blocks. If both present, flag for extraction. | `src/lints/sync_lints.rb` (new) | 0.5d |
| 6.2 | **Ballooning effect surface.** Count distinct effects on a function's signature; flag if ≥ 5. Provide trace from caller to source effect. | `src/lints/sync_lints.rb` | 0.5d |
| 6.3 | **Repeated WITH pattern.** Cross-function structural matching (same WITH structure in 2+ functions). | `src/lints/sync_lints.rb` | 0.5d |
| 6.4 | **Hot-loop without WITH amortization.** Detect repeated atomic ops on the same locked binding inside a loop body. | `src/lints/sync_lints.rb` | 0.5d |
| 6.5 | **Effect propagation surprise.** When a function's projected effects include effects whose source is ≥ 3 levels deep in the call graph, surface the trace. | `src/lints/sync_lints.rb` | 0.5d |
| 6.6 | **Multi-lock transaction.** Flag any `WITH EXCLUSIVE` with 3+ resources; require explicit human review or a comment justifying the lock count. | `src/lints/sync_lints.rb` | 0.25d |
| 6.7 | Auto-refactoring actions: AST transformations for *extract-transaction* (6.1) and *extract-helper* (6.3). Output as a unified diff or edit instructions. | `src/lints/refactor.rb` (new) | 1d |
| 6.8 | `clear suggest sync` CLI command. Reads source, runs lints, formats output. | `clear` (CLI) | 0.25d |
| 6.9 | Specs: positive cases (each pattern fires on intended target), negative cases (clean code doesn't trigger lints). | `spec/sync_lints_spec.rb` (new) | 0.5d |

**Acceptance criteria:**
- Lints fire on a curated test corpus of intentional patterns.
- Lints don't fire on clean reference programs (e.g., the migrated VM after Phase 8).
- Auto-refactor produces compilable output that preserves semantics; round-trip tests verify.

**Risks:**
- *False positives erode trust.* A noisy lint pass that fires on idiomatic code becomes background noise. Mitigation: validate against real-world corpus before shipping; tune thresholds (e.g., effect-balloon threshold) per code base.
- *Auto-refactor correctness.* Extract-transaction and extract-helper must preserve semantics under all binding capabilities. Mitigation: refactor pass produces output that re-runs effect inference; if effects change, refactor is rejected.

---

### Phase 7: Polymorphic stdlib primitives (5-7 days)

**Goal:** Audit existing stdlib helpers for capability-polymorphism gaps; add sync-aware variants; migrate compile sites to dispatch via the polymorphic helpers.

**Concrete tasks:**

| ID | Task | Files | Effort |
|---|---|---|---|
| 7.1 | Audit: enumerate all stdlib methods exposed via the registry (`STD_LIB`, `BUILTIN_OPS`, `INDEX_OPS`, `MAP_METHODS`, `SET_METHODS`, `POOL_METHODS`). For each, classify: **already polymorphic over capability** (e.g., `getAt` via `@hasField`), **needs polymorphism added**, or **inapplicable** (e.g., pure compute). | `src/ast/std_lib.rb` | 1d |
| 7.2 | For methods needing polymorphism, add Zig runtime helpers that dispatch via comptime `@hasField(@TypeOf(c), "lock")` etc. Naming: `lockedAccess`, `lockedSet`, `atomicAdd`, etc. | `zig/runtime/runtime-header.zig` | 2-3d |
| 7.3 | Update lowering to emit calls to the polymorphic helpers when the binding has sync metadata (rather than direct accesses). | `src/mir/mir_lowering.rb` | 1d |
| 7.4 | Verify each helper across 5 capability variants (bare, @locked, @writeLocked, @shared:locked, @shared:writeLocked) and 4 collection kinds (@list, @pool, @map, @set). 20 combinations per primitive × ~10 primitives = 200 verification points. | `transpile-tests/`, runtime tests | 1-2d |

**Acceptance criteria:**
- All atomic operations correct under all binding capabilities.
- Compiled benchmarks show no regression > 5% vs. hand-written specialized code (compile-time dispatch should produce identical machine code).
- 200-point verification matrix passes.

**Risks:**
- *Audit scope.* The audit may reveal more gaps than estimated. Mitigation: prioritize by usage frequency in existing transpile-tests; ship in waves.
- *Zig comptime complexity.* Some primitives may not cleanly fit `@hasField` dispatch (e.g., closures, callbacks). Mitigation: identify these in audit; escalate to per-primitive design.

---

### Phase 8: Integration and migration (3-5 days)

**Goal:** Update language documentation, migrate the VM as the load-bearing case study, run full test suite, run benchmarks.

**Concrete tasks:**

| ID | Task | Files | Effort |
|---|---|---|---|
| 8.1 | Update `CLAUDE.md`: replace "Functions take Types, not Capabilities" with the binding-metadata rule. Update authority boundaries section (Type / Annotator / EscapeAnalysis / CleanupClassifier / mir_lowering). | `CLAUDE.md` | 0.5d |
| 8.2 | VM migration: change `pool` declaration in `main()` of `_bc_runner.cht` to `@shared:locked`; wrap recursive `exec!` in `BG { ... }`; verify Phase 2 of the bytecode VM works. | `examples/minivm/_bc_runner.cht` | 1-2d |
| 8.3 | Verify full test suite: 2549+ specs, 340+ transpile-tests. Investigate any regressions. | All test files | 1d |
| 8.4 | Run benchmark suite. Compare against pre-migration baseline; verify no regression > 5% on any benchmark. Investigate outliers. | `benchmarks/` | 0.5-1d |
| 8.5 | VM historical suite improvement check. Goal: ≥ 32/58 passing (current: 28/58). | `examples/minivm/run_tests.rb --historical` | 0.5d |

**Acceptance criteria:**
- Full Ruby spec suite green.
- Full transpile-test suite green; zero memory leaks.
- VM runs under @shared:locked pool with real BG-spawned fibers.
- VM historical suite at or above current baseline.
- Benchmarks within 5% of pre-migration.

**Risks:**
- *Discovered limitations during VM migration.* The VM is the canonical hard case; if any escape hatch is needed that the design didn't anticipate, scope creeps. Mitigation: treat VM as the design's acceptance test; anything blocking is a design bug, not an implementation bug.
- *Benchmark regression > 5% in some specific case.* Likely sources: extra Arc deref on shared bindings, missed opportunities for direct access. Mitigation: profile case-by-case; the runtime helpers must compile down to identical code as today's specialized paths.

---

### Risk register summary

| Risk | Phase | Likelihood | Mitigation |
|---|---|---|---|
| Type#sync read site misclassification | 1 | Medium | Spec each site; fast feedback via existing tests |
| Cross-module effect interface design | 2, 5 | Medium | Defer details; treat as Open Question #2 until forced |
| Reentrant aliasing analysis precision | 3 | Medium-High | Conservative refusal + runtime fallback |
| Stdlib audit scope larger than estimated | 7 | Medium-High | Prioritize by usage; ship in waves |
| `@contends` condition-checking complexity | 5 | Medium | Test corpus first; explicit pattern spec |
| Auto-refactor correctness | 6 | Medium | Round-trip tests; refactor preserves effects |
| VM migration uncovers design limitation | 8 | Low-Medium | Treat as acceptance test; design bug, not implementation |
| Benchmark regression > 5% | 8 | Low | Comptime dispatch should match specialized code |

---

### Sequencing recommendations

**Week 1:** Phase 1 + start Phase 7 audit in parallel.
**Week 2:** Phase 2 (REQUIRES + WITH MATCH parser/check) + Phase 7 implementation.
**Week 3:** Phase 3 (effects + correctness checks).
**Week 4:** Phase 4 (formatter projection), Phase 5 (call-site policies).
**Week 5:** Phase 6 (architectural lints), Phase 8 (integration + VM migration + benchmarks).

**Checkpoint cadence:** End of each phase, run full test suite. Any regression blocks the next phase until resolved. The phases are designed so each leaves the system in a working state — partial progress is shippable.

**Demo milestones:**
- End of Phase 1: the case-study `bumpIt(c)` (no REQUIRES yet) accepts a `@shared:locked` caller.
- End of Phase 2: REQUIRES + WITH MATCH grammar accepted; multi-family `transact` parses and the WHEN-arm exhaustiveness check fires on intentional violations.
- End of Phase 3: a transpile-test demonstrating compile-time deadlock detection across REQUIRES boundaries.
- End of Phase 4: `clear fmt` projects effects (`! yield`, `! alloc`) without touching REQUIRES.
- End of Phase 8: VM Phase 2 demo (real concurrent fibers in the bytecode VM, before/after diff visible).

These give external visibility to the work as it progresses, not just at the end.

---

### Total: ~3-5 weeks (one engineer, focused)

Larger if the engineer is shared with other work. Smaller (~3 weeks) if Phases 4 and 6 can defer to a follow-up release (the core architecture is delivered through Phases 1, 2, 3, 5, 7, 8).

---

## Open questions

These need decisions but aren't blocking.

1. **Lock fairness model.** When multiple fibers contend for `@locked`, what's the queueing discipline? FIFO, priority, scheduler-default? Decision needed before implementation locks in semantics.

2. **Cross-module effect interface.** Compiled module interfaces need to carry effect signatures. How are they cached? How do they invalidate when a function's effects change?

3. **Deprecation path for type-level sync.** Existing code with `Counter@shared:locked` in type annotations: do we accept these as binding-metadata initialization, or migrate to value-level `@shared:locked` at declaration?

4. **Effect granularity for collections.** A function operating on `lst: Int64[]@list@shared:locked` — does its effect mention `lst` or `lst[i]`? Coarse or fine?

5. **`@contends` semantics for non-shareable types.** What happens when `@contends` is applied to a binding whose type can't be Arc-wrapped (e.g., a heap-allocated complex struct)? Error or fall through to COPY?

6. **Multi-lock with sharded data.** For `@sharded` collections, multi-lock acquisition is per-shard. How does this interact with the multi-resource WITH syntax?

7. **Effect signatures and library compatibility.** When a library function's inferred effects change (e.g., adds an internal `! yield`), is that a breaking change? How do tools (`clear sigdiff`) help library authors maintain compatibility?

---

## What this delivers

When complete:

- **Most functions have no capability or effect annotations.** They work for any binding capability.
- **Refactoring concurrency strategy is one declaration change.** Signatures auto-update via formatter.
- **Effects are visible at function boundaries.** Local reasoning preserved.
- **Compile-time guarantees** for deadlock, hold-across-yield, reentrancy, capability mismatch, FAST_PATH violations.
- **Architectural lints** keep the codebase clean as it grows.
- **Best-of-breed refactorability** — beats Rust without sacrificing correctness.

---

## Comparison to alternatives

| Property | Rust (Arc<Mutex<T>>) | Java (synchronized) | Go (mutex+defer) | **CLEAR Plan** |
|---|---|---|---|---|
| Author writes capability/effect | Always (in types) | Implicit | Manual | **Never (except optional constraints)** |
| Effects visible at signature | Yes | No | No | **Yes (formatter-projected)** |
| Refactor: switch lock kind | Rewrite signatures | Rewrite | Rewrite | **One binding declaration** |
| Refactor: switch sync model | Rewrite | Rewrite | Rewrite | **One binding declaration** |
| Compile-time deadlock check | No (runtime, partial) | No | No | **Yes (multi-WITH, reentrant, hold-across-yield)** |
| Compile-time FAST_PATH check | No | No | No | **Yes** |
| Most functions sync-agnostic | No (signatures leak) | Yes (but unsafe) | Yes (manual) | **Yes (compiler-verified)** |
| Architectural lints | Clippy (limited) | Limited | Limited | **`clear suggest sync` (6 patterns + auto-refactor)** |

CLEAR Plan delivers strong refactor stability AND strong correctness guarantees — a combination none of the existing systems offer.

---

## Why this matters for CLEAR's pitch

CLEAR's defining promise is *"swap memory and concurrency models without rewriting your code."* The plan above is what delivers that promise for real workloads, not just toys.

A program written under this plan:
- Starts with bare types, no concurrency complexity.
- Profiler shows allocation pressure → switch one binding to `@shared`. Done.
- Profiler shows lock contention → switch one binding from `@locked` to `@sharded:locked(N)`. Done.
- Compile-time errors when the architecture changes break invariants — pointing at exact lines, with suggested fixes.
- Architectural lints surface mixed-modality functions before they accumulate.
- Effects projected onto signatures keep local reasoning sharp.

This is the language CLEAR was meant to be. Without this plan, the pitch fails on real workloads. With it, the pitch is delivered as actual capability.
