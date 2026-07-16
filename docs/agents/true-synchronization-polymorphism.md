# True Synchronization Polymorphism

**Status**: in progress (branch `thunks-cleanup`). Step 1 of 11 landed (parser + AST). See "Implementation plan" below for current task.

## Goals

CLEAR should make synchronization strategy a checked capability, not an
API shape that infects every function signature.

A user should be able to write ordinary data-shaped code:

```clear
FN incAndReturn(MUTABLE x: Counter) REQUIRES x: SNAPSHOTTED RETURNS Int64 ->
    WITH POLYMORPHIC x AS c {
        c.value = c.value + 1;
        RETURN c.value;
    }
END
```

…and have the compiler:

- accept any synchronization family that can faithfully implement the body;
- project the per-family error set at each call site (the caller only sees
  errors that can actually fire for the binding it passed);
- apply a program-wide error policy (with a system default) so most
  contention is handled without inline boilerplate;
- still force the user to handle errors that *can't* be defaulted
  (`Deadlock`, `LockCycle`).

This is the concurrency equivalent of "functions take Types, not
Capabilities": the function describes the work; declaration-site
capabilities choose the implementation; the compiler proves the body
fits and projects the right error set per use.

## Final taxonomy

### REQUIRES families (call-site contract)

Four families. The parser keeps them as a closed set. Alternation across
families is allowed (`REQUIRES x: LOCKED | SNAPSHOTTED`).

| Family | Admits | Mono/Poly | IO allowed in body? |
|---|---|---|---|
| `LOCKED` | `@locked`, `@writeLocked` | poly (2 axes) | yes |
| `SNAPSHOTTED` | `@versioned`, `@atomic`, `@boxed:atomic` | poly (2 axes) | **no** |
| `VERSIONED` | `@versioned` only | mono (1 axis) | **no** |
| `ATOMIC` | `@atomic`, `@boxed:atomic` | mono (1 axis) | **no** |

`SNAPSHOTTED` is the recommended umbrella for retry-style sync.
`VERSIONED` and `ATOMIC` are escape hatches when memory or behavior
must be pinned (e.g., `ATOMIC` to forbid MVCC's higher version-retention
memory cost; `VERSIONED` if the body specifically needs multi-cell
transactions). A future doctor lint will flag `REQUIRES VERSIONED` as
typically overly restrictive — out of scope for this milestone.

### Storage sigils (binding declaration site)

| Sigil | Storage axis |
|---|---|
| `:locked` | mutex |
| `:write_locked` | reader/writer lock |
| `:versioned` | MVCC / multi-version snapshot transaction |
| `:atomic` | atomic primitive (Int64 / Float64 / Bool) |
| `:boxed:atomic` | atomic pointer (struct via `*AtomicPtr(T)`) |

`@local` (compiler-proven confinement, no synchronization) is supported
elsewhere but does not participate in the polymorphism work; bindings
under `@local` cannot satisfy any REQUIRES family that admits a
synchronized axis.

`@buffered`, `@actor`, `@distributed:actor` are out of scope for this
milestone (no ring-buffer / actor runtime yet).

### Error registry

`Conflict` is split into two distinct errors. They surface different
internal sources and may carry different SYNC POLICY retry budgets in
the future.

| Error | Source | Internal cap | Default policy | In SYNC POLICY? |
|---|---|---|---|---|
| `LockTimeout` | mutex acquire timeout | runtime | `RETRY(3) THEN RAISE` | yes |
| `Deadlock` | static graph + runtime cycle | n/a | inline-only — never defaulted | **no** |
| `LockCycle` | static graph + runtime cycle | n/a | inline-only — never defaulted | **no** |
| `MvccConflict` | versioned commit retry exhausted | 64 | `RAISE` | yes |
| `AtomicConflict` | atomic CAS retry exhausted | 256 | `RAISE` | yes |

## Syntax

### Top-level `SYNC POLICY START ... END`

```clear
SYNC POLICY START
    ON LockTimeout RETRY(3) THEN RAISE
    ON MvccConflict RAISE
    ON AtomicConflict RAISE
END
```

Validation rules:

- **Single-instance**. More than one `SYNC POLICY` anywhere in the program → error.
- **Main-file-only**. `SYNC POLICY` in any module that does not contain `FN main` → error.
- **Completeness**. The block must handle exactly `LockTimeout`, `MvccConflict`, `AtomicConflict`. Missing any → error (with a per-missing-handler message).
- **Inline-only error guard**. `ON Deadlock` or `ON LockCycle` inside `SYNC POLICY` → error: `"<Error> must be handled in-line — SYNC POLICY defaults are not allowed for this error"`.
- Absent → the baked-in system default (below) applies.

The block name was dropped (no `Default`) since only one is permitted.

### `WITH` variants

```clear
WITH x AS y { ... }                                         -- monomorphic
WITH POLYMORPHIC x AS y { ... }                             -- polymorphic
WITH POLYMORPHIC POSSIBLE_DEADLOCK x AS y { ... }           -- + opt out static cycle check (Deadlock)
WITH POLYMORPHIC POSSIBLE_LOCK_CYCLE x AS y { ... }         -- + opt out static cycle check (LockCycle)
```

Polymorphic-iff rule:

- `WITH POLYMORPHIC` is **required** when the binding's admissible-axis count is >1 (e.g., `LOCKED` or `SNAPSHOTTED`).
- `WITH POLYMORPHIC` is **rejected** when the admissible-axis count is 1 (`VERSIONED` or `ATOMIC`). Error: `"Only one family admissible — either be specific (use WITH directly) or broaden REQUIRES to a polymorphic family."`
- Plain `WITH` on a polymorphic param → error (force polymorphism to be visible at use sites).

`WITH MATCH WHEN` is removed entirely; `WITH POLYMORPHIC` replaces it with one body that lowers via comptime `@hasDecl` dispatch across all admissible families. Removal happens in task #332 after the new lowering is in place to avoid breaking transpile-tests in a single commit.

### Per-WITH `ON` handlers (existing syntax, unchanged)

```clear
WITH POLYMORPHIC x AS y { ... } ON MvccConflict RETRY(2) THEN RAISE
```

Per-WITH `ON` clauses still work. They take precedence over the program SYNC POLICY and the system default.

### Inline-only error handling (Deadlock, LockCycle)

These are never defaulted. Any block where the static cycle detector proves a cycle is possible must opt out via `POSSIBLE_DEADLOCK` / `POSSIBLE_LOCK_CYCLE` AND handle the runtime error inline:

```clear
WITH POLYMORPHIC POSSIBLE_DEADLOCK a AS x, b AS y {
    x.value = y.value;
} ON Deadlock RAISE
```

If the SYNC POLICY tries to handle either error, the compiler refuses with the inline-only message above.

## Semantics

### Admission

The annotator (#326) checks two things at every WITH site:

1. The binding's storage sigil is in the admissible-axis set of the function's REQUIRES family.
2. `WITH` vs `WITH POLYMORPHIC` matches the polymorphic-iff rule.

### IO restriction

Inside any retry-prone family body — concrete `@versioned` / `@atomic` / `@boxed:atomic` WITH, or any WITH POLYMORPHIC where one of those axes is admissible — the body must not have the `:io` effect. The runtime re-executes the body on internal commit retry; IO would be silently re-issued. (Allocation is allowed; it is wasteful on retry but correct.)

`@locked` / `@writeLocked` bodies are *not* subject to this restriction; once the lock is held, the body runs once.

For this pass: `print()` is allowed inside retry-prone bodies (follow-up: ban once the broader `:io` propagation pipeline is more complete). Any tests that already use IO inside snapshot bodies will need to be migrated when the check goes live (task #326).

### Polymorphic warning surface

For each `WITH POLYMORPHIC` block:

1. Compute the admissible-family set from the binding's REQUIRES.
2. Project the per-family error sets (table below).
3. Subtract per-WITH `ON` handlers and program SYNC POLICY handlers.
4. Remainder → compile-time `[Warning]`: `"Polymorphic error <Name> may fire under <Family> but no handler is in scope"`.

Monomorphic blocks keep today's hard-error semantics: REQUIRES committed → user must handle every reachable error inline (or rely on policy where allowed).

A future `--strict-sync` flag (out of scope; task only stubbed) promotes the warning to a hard error.

### Per-family error projection

| Storage axis | Errors that can fire |
|---|---|
| `@locked` / `@writeLocked` | `LockTimeout`, `Deadlock`, `LockCycle` |
| `@versioned` | `MvccConflict` |
| `@atomic` / `@boxed:atomic` | `AtomicConflict` |

REQUIRES family error union (the function's signature `!T`):

| REQUIRES | `!T` |
|---|---|
| `LOCKED` | `!{LockTimeout, Deadlock, LockCycle}` |
| `SNAPSHOTTED` | `!{MvccConflict, AtomicConflict}` |
| `VERSIONED` | `!{MvccConflict}` |
| `ATOMIC` | `!{AtomicConflict}` |
| `LOCKED \| SNAPSHOTTED` | union of both rows |

### Call-site error collapsing

At each call site of a polymorphic function, the caller's effective `!T` collapses to *only* the errors the actually-passed binding's storage axis can raise. The compiler does the projection per-call.

```clear
FN tick(MUTABLE x: Counter) REQUIRES x: SNAPSHOTTED RETURNS Int64 ->
    WITH POLYMORPHIC x AS c { c.value = c.value + 1; RETURN c.value; }
END
-- signature: !{MvccConflict, AtomicConflict}

tick(myVersioned)   -- caller sees !{MvccConflict}
tick(myAtomic)      -- caller sees !{AtomicConflict}
tick(myIndirect)    -- caller sees !{AtomicConflict}
```

The handle-or-propagate requirement at the caller is computed against the *collapsed* set, so `tick(myVersioned)` requires the caller to handle `MvccConflict` only — never `AtomicConflict`.

### Effects

Existing lattice: `yield, alloc_heap, io, fail, contention, blocking`.
This milestone adds two:

- `contends_maybe` — the function calls into a polymorphic site whose admissible family includes a retry-prone axis.
- `blocks_maybe` — the function calls into a polymorphic site whose admissible family includes a lock-style axis.

Concrete-family bodies still emit the concrete `contention` / `blocking` effects.

`clear doctor` does not yet surface effects to the user (out of scope). The effects are inferred and stored on the function so future tooling and the call-site error projection can consume them.

### Unreachable handler errors

A monomorphic WITH that names an unreachable error is rejected:

| Concrete WITH | Unreachable handler examples |
|---|---|
| `WITH x AS y` where x is `@locked` | `ON MvccConflict`, `ON AtomicConflict` |
| `WITH x AS y` where x is `@versioned` | `ON LockTimeout`, `ON Deadlock`, `ON LockCycle`, `ON AtomicConflict` |
| `WITH x AS y` where x is `@atomic` | `ON LockTimeout`, `ON Deadlock`, `ON LockCycle`, `ON MvccConflict` |
| `WITH POLYMORPHIC x AS y` REQUIRES `SNAPSHOTTED` | `ON LockTimeout`, `ON Deadlock`, `ON LockCycle` |

This is the existing `verify_handler_reachability!` check, generalized for the new error names and POLYMORPHIC bindings.

## Defaults

### Baked-in system default policy

```clear
SYNC POLICY START
    ON LockTimeout RETRY(3) THEN RAISE
    ON MvccConflict RAISE
    ON AtomicConflict RAISE
END
```

Rationale: the runtime already retries internally (256 for atomic, 64 for versioned), so the closure has had its best shot before it surfaces a `*Conflict`. Auto-retrying the whole WITH block by default would mostly burn CPU; raising surfaces the contention to the application.

The user can opt into outer retry per-error in their own SYNC POLICY:

```clear
SYNC POLICY START
    ON LockTimeout RETRY(3) THEN RAISE
    ON MvccConflict RETRY(2) THEN RAISE
    ON AtomicConflict RETRY(4) THEN RAISE
END
```

### Internal runtime caps

| Family | Internal retry cap | On exhaustion |
|---|---|---|
| `:atomic` (`compareAndPublish` / `update` loops) | **256** | `error.AtomicConflict` |
| `:versioned` (commit retry) | **64** (down from 10000) | `error.MvccConflict` |

Bridged to the CLEAR error registry. AtomicPtr previously retried unboundedly (Rust arc-swap-style); bounded for predictability and to make outer retries explicit. `Versioned`'s 10000 was always defensive; 64 reflects the realistic budget.

`AtomicConflict` allows more internal retries than `MvccConflict` because atomic retry is cheap (re-load + re-apply closure), whereas versioned retry re-runs the whole transaction body.

### Handler precedence

For every WITH block, the compiler resolves each error this way:

1. Per-WITH `ON` clause → use it.
2. Program `SYNC POLICY` (user-written, validated) → use it.
3. Baked-in system default → use it.

If no level handles a given error and the WITH is polymorphic, emit a warning. If monomorphic, error.

## Implementation plan

11 tasks total. Critical-path dependencies are wired in the TaskList.

| # | Task | Status |
|---|---|---|
| 322 | Parser: `SYNC POLICY` + `WITH POLYMORPHIC` syntax | done (5d574009) |
| 323 | AST: `SyncPolicyDecl` + `WithBlock#polymorphic` | done (folded into 322) |
| 324 | Error registry: split `Conflict` → `MvccConflict` + `AtomicConflict` | done (86e5f4a8) |
| 325 | Annotator: SYNC POLICY validation + completeness | done (2a189cc8) |
| 326 | Annotator: REQUIRES grammar + WITH/POLYMORPHIC dispatch | done (dedc7f49) |
| 327 | Effect inference: `contends_maybe` / `blocks_maybe` + per-WITH error projection | done (b51942b3) |
| 328 | Lowering: SNAPSHOT MUTABLE policy chain | done (a742e370) |
| 329 | Call-site error collapsing | done (653edf2c) |
| 330 | Runtime: bound atomic_ptr 256 + versioned 64 + bridge errors | done (3f09aeac) |
| 331 | Specs: precedence + family rejection + unreachable handler | done (bad67266) |
| 332 | Migration: M3.11 rule removed + doctor advice + read-only SNAPSHOT MATCH collapse | partial (7b0f105f) |
| 333 | Multi-object WITH cannot admit ATOMIC (folds M3.9) | done (d1831fe9) |
| 334 | **Acceptance close** — see "Pending milestone gates" below | pending |

## Pending milestone gates (#334)

Three concrete deliverables close the milestone. Each is a substantive
language-design step on top of the polymorphic-error infrastructure
the prior 12 commits put in place. The 5 pending specs in
`spec/polymorphic_transaction_acceptance_spec.rb` are the executable
form of these gates — when they pass without `pending`, the milestone
is complete.

### Gate 1 — non-sync bindings as no-op WITH

Today, `WITH c AS x { x.v = ... }` on a `@local` / `@multiowned` /
plain-`T` binding doesn't compile: the cap-inference rejects it
("cannot infer capability"), and `WITH RESTRICT` produces
borrow-lifetime errors when the body mutates. To close, the language
needs a real "borrow + maybe-mutate" semantic for non-sync bindings,
mirroring the sync families' Guard model. Concretely:

- `WITH c AS MUTABLE x { x.v = ... }` on `@local` / `@multiowned` /
  plain `T` lowers to a direct `*T` alias and the body uses field
  access (no `acquire`, no `update`, no Arc unwrap).
- The borrow-checker recognizes that `x` and `c` co-alias and the
  body's writes through `x` reach `c`.

### Gate 2 — `LOCAL` REQUIRES family

Once Gate 1 lands, add a REQUIRES family that admits non-sync
bindings: `LOCAL` (admits `@local`, `@multiowned`, plain `T`).
Combined with `LOCKED` and `SNAPSHOTTED`, this lets a fn declare
`REQUIRES c: LOCAL | LOCKED | SNAPSHOTTED` and accept every supported
sync strategy, including non-sync ones. (Or introduce `ANY` as the
umbrella — naming choice deferred.)

#### Revised function-boundary rule: `T@shared` is strict

The older "capabilities flow through ordinary function boundaries"
draft treated `T@shared`-style parameters as a polymorphic acceptance
surface: callers could pass bare `T`, `@multiowned`, or concrete
`@shared:*` bindings, and the callee body would decide whether it
needed a `WITH`, `CLONE`, or execution-boundary-safe capture.

That plan is now deliberately narrowed for v0.1:

- A parameter declared as `T@shared` accepts only a real shared handle.
  Bare `T`, `@local`, and `@multiowned` do not satisfy it implicitly.
- Callers with an owned value must write `SHARE x`. `SHARE` promotes the
  value into the shared function-boundary representation and consumes
  the source unless the caller writes `SHARE COPY x`.
- Callers with `@multiowned` must also opt in with `SHARE x` if they
  want to cross a `T@shared` API boundary. For v0.1 this may wrap in
  the contending Arc/shared representation; the non-contending
  `@multiowned` effect is not preserved silently.
- `WITH POLYMORPHIC` remains the access-polymorphic mechanism for
  functions that explicitly admit several synchronization families via
  `REQUIRES`. It is not a hidden conversion from bare `T` to
  `T@shared`.

This keeps the effect model honest. The old implicit plan only works
without semantic surprises for narrow transaction-style helpers that do
not cross execution boundaries and do not retain the value. If such a
helper later captures into `BG`, `DO`, or `CONCURRENT`, an implicit
bare/`@multiowned` acceptance path would have to silently upgrade to
`T@shared` and add contention/effects at the call site. v0.1 avoids
that by making the upgrade explicit.

Future optimization: once the compiler has callee-behavior summaries,
`SHARE x` can be elided or downgraded when proven safe:

- If the callee does not cross an execution boundary and does not
  retain/clone the handle, `SHARE x` can lower to a no-op/direct borrow.
- If the callee stays on one scheduler and only needs retain semantics,
  `SHARE x` may lower to `@multiowned`/Rc instead of Arc, avoiding the
  `contends` effect.
- If the callee crosses `BG`, `DO`, or `CONCURRENT`, stores the handle
  beyond the call, or otherwise needs scheduler-safe sharing, `SHARE x`
  must remain the shared/Arc representation and surface the relevant
  effects.

Acceptance coverage for this revised boundary should extend the existing
polymorphic-sync suite with three representative callee shapes:

1. A `T@shared` function that only retains the handle (`CLONE x`) and
   never opens an access gate. This verifies that `T@shared` signatures
   may rely on retain semantics, and bare callers must write `SHARE x`.
2. A `T@shared` function that crosses an execution boundary by capturing
   the handle into one representative `BG` / `DO` / `CONCURRENT` body.
   We only need one boundary form for this acceptance target; the point
   is proving that implicit bare/`@multiowned` admission would have
   needed a hidden upgrade and effect change.
3. The existing transaction/access-gate case: a function that crosses
   `WITH POLYMORPHIC x AS y { ... }`. This remains the intended surface
   for true synchronization polymorphism rather than `T@shared`
   accepting arbitrary non-shared callers.

### Gate 3 — multi-family `WITH POLYMORPHIC` lowering

Today's `WITH POLYMORPHIC` lowering doesn't yet handle multi-family
preludes (`Versioned.read` vs `Locked.acquire`) for cases like
`REQUIRES x: VERSIONED | LOCKED`. Each arm in the legacy
`WITH MATCH WHEN` form had its own per-family Guard-acquisition
prelude; `WITH POLYMORPHIC` needs the same machinery, but with ONE
shared body. The lowering becomes a comptime `if (@hasDecl(...))` /
`else if (@hasField(...))` chain that picks the prelude per actual
cell type, then runs the uniform body inside.

This unblocks:

- The 5 transpile-tests still using `WITH MATCH WHEN` (#333, #334,
  #335, #341, #345 in `transpile-tests/`) — they migrate to plain
  `WITH POLYMORPHIC` once the lowering covers their cases.
- Full removal of the `WITH MATCH WHEN` grammar (parser, annotator
  arm-handling, lowering arm-emit). Tracked as #332b in the design
  doc and folded into this gate.
- The SNAPSHOT MUTABLE catch-handler's Zig error name needs to be
  comptime-dispatched per actual cell type (today the lowering picks
  one error name based on the REQUIRES-seed; for `REQUIRES x:
  VERSIONED | ATOMIC` passed an `@boxed:atomic` cell, the emitted
  Zig has the wrong error name in the catch arm).

## Acceptance criteria

Use this list to verify completion at the end of the milestone. Each item maps to one or more tasks above.

### Syntax

- [x] Parser accepts `SYNC POLICY START ... END` at top level.
- [x] Parser accepts `WITH POLYMORPHIC x AS y { ... }` and the two `POSSIBLE_*` modifiers.
- [x] AST carries `SyncPolicyDecl` and `WithBlock#polymorphic`.
- [ ] `WITH MATCH WHEN` is removed entirely. **Partial**: the
  `validate_polymorphic_mutate_uses_match!` rule (which forced MATCH
  whenever REQUIRES admitted both VERSIONED and ATOMIC, because of
  the now-defunct ON Conflict family-difference) is removed in
  #332. The grammar removal itself is deferred — `WITH POLYMORPHIC`
  lowering doesn't yet handle multi-family preludes (Versioned.read
  vs Locked.acquire) for cases like REQUIRES `VERSIONED | LOCKED`,
  and the SNAPSHOT MUTABLE catch-handler isn't yet comptime-dispatched
  per actual cell type. Both are tracked under #334 (acceptance close).

### Annotator

- [x] `SYNC POLICY` in a non-main file → compile error.
- [x] More than one `SYNC POLICY` in the program → compile error.
- [x] `SYNC POLICY` with a missing handler in `{LockTimeout, MvccConflict, AtomicConflict}` → compile error (per-missing-handler message).
- [x] `SYNC POLICY` with `ON Deadlock` or `ON LockCycle` → compile error: "must be handled in-line".
- [x] REQUIRES grammar accepts `LOCKED | SNAPSHOTTED | VERSIONED | ATOMIC` and alternations.
- [x] Admission table enforced: `SNAPSHOTTED` rejects `@locked`; `VERSIONED` rejects `@atomic`; `ATOMIC` rejects `@versioned`; `LOCKED` rejects all retry-prone axes.
- [x] `WITH POLYMORPHIC` required for poly REQUIRES; rejected for mono REQUIRES (with both error messages).
- [x] Plain `WITH` on a polymorphic param → error.
- [ ] `:io` effect inside any retry-prone WITH body → compile error. **Deferred** to follow-up #1 (existing `:io` effect propagation is patchy; needs an audit pass before this becomes a hard check).
- [x] Unreachable `ON` handler → error for every {concrete-family × wrong-error} pair.

### Errors

- [x] `Conflict` is removed from the error registry.
- [x] `MvccConflict` and `AtomicConflict` are registered.
- [x] Every existing `ON Conflict` reference in transpile-tests / specs / examples migrated to the right split.
- [x] Zig runtime returns `error.MvccConflict` (versioned, via `error.UpdateRetriesExhausted` bridge) and `error.AtomicConflict` (atomic) on internal cap exhaustion.

### Effects

- [x] `contends_maybe` and `blocks_maybe` participate in the lattice and propagate through call chains.
- [x] Per-WITH error projection produces correct sets for every {REQUIRES × admissible-family} cell.

### Lowering

- [ ] `WITH POLYMORPHIC` lowers to comptime `@hasDecl` dispatch covering all admissible families (incl. primitive `@shared:atomic` special case). **Partial**: works for SNAPSHOT MUTABLE on @versioned and @boxed:atomic via the existing comptime arc-unwrap; the multi-family case (`REQUIRES x: VERSIONED | LOCKED`) needs Gate 3 above.
- [x] Per-WITH `ON` clauses precede program SYNC POLICY precede system default at every WITH site (verified by spec).

### Call-site error collapsing

- [x] Caller of a polymorphic function sees a `!T` projected against the actual passed binding's family — not the full union.
- [x] Spec coverage for every {actual-family × REQUIRES-family} cell.

### Runtime

- [x] `zig/lib/atomic_ptr.zig` `update()` bounded at 256; on cap raises `error.AtomicConflict`.
- [x] `zig/runtime/versioned.zig` `MAX_UPDATE_RETRIES` = 64; on cap raises `error.MvccConflict`.
- [x] Loom + hammer + VOPR all pass at the new caps.

### Defaults

- [x] Baked-in system default applied when no user `SYNC POLICY` is present.
- [x] Behavior identical when user writes the same policy explicitly.

### Migration

- [x] `clear doctor` advice (M1.9 / M3.15 / M3.16) recommends `SNAPSHOTTED`.
- [x] All transpile-tests and specs pass.
- [x] Follow-up doc captures: ban `print()` inside retry-prone bodies, audit `:io` effect propagation completeness, future `--strict-sync` flag, mandatory `RETURNS !T` discipline.

## Out-of-scope

- `@buffered`, `@actor`, `@distributed:actor` (no runtime yet).
- `clear doctor` / IDE surfacing of the new effects.
- `--strict-sync` flag (warnings → errors).
- Banning `print()` inside retry-prone bodies (logged as a follow-up).
- A user-tunable knob for the internal retry caps (256 / 64). Profile-driven tuning later.

## Open follow-ups

These are written down here so they don't get lost; none block the current milestone.

1. Ban `print()` (and any other `:io`-tagged stdlib call) inside retry-prone WITH bodies once the `:io` effect inference is comprehensive.
2. Audit `:io` effect propagation in `src/mir/effect_inference.rb` for transitive completeness.
3. Add `--strict-sync` build flag to promote polymorphic warnings to errors.
4. Add `clear doctor` lint that flags `REQUIRES VERSIONED` / `REQUIRES ATOMIC` as typically overly restrictive (with a "consider SNAPSHOTTED" suggestion).
5. Surface `contends_maybe` / `blocks_maybe` in IDE/`clear doctor` output so users can see them per-function.
6. **Force `RETURNS !T` for fallible functions** (Zig-style discipline). Today `can_fail` is INFERRED at signature time (`compute_can_fail!` in `src/annotator-helpers/effects.rb:382`) — a function that calls a fallible callee or has a RAISE statement is silently flagged fallible without the signature having to declare it. The right end-state is to require the user to write `RETURNS !T` (or `RETURNS T !{Error1, Error2}` once call-site error collapsing from #329 surfaces narrowed sets) on every fallible signature. Caller code that drops the error union without a CATCH would then be a compile error, mirroring Zig's `try` discipline.

   **Status**: implementation scaffolding landed in #335 — `FunctionDef#explicit_return_type` is stamped at parse time, `enforce_fallible_returns!` runs as a NO-OP gated behind `FALLIBLE_RETURNS_ENFORCE = false` in `src/annotator-helpers/effects.rb`, and `fallibility_hint_for` produces a helpful diagnostic. Flipping the flag to `true` turns every fn that can fail (anything that allocates, RAISEs, or transitively calls a fallible callee) without declaring `!T` into a hard compile error — currently ~600 spec fixtures and an unknown count of transpile-tests / examples / benchmarks. Migration is mechanical (`RETURNS T ->` → `RETURNS !T ->` on every fallible signature) but too big for one commit; bulk regex over-migrates and produces more breakage than the baseline. The right approach is per-test-suite migration in dedicated passes, then flip the flag.

## Original vision (preserved for context)

Earlier draft of this design (before the iteration that produced the locked spec above) lived in this section. It introduced the high-level idea of polymorphic synchronization, the WITH MATCH WHEN escape hatch, BUFFERED / ACTOR semantics, and effect surfacing. The current spec keeps the core idea (declaration-site choice; body-stable signatures; effects) and refines or supersedes the rest:

- WITH MATCH WHEN → replaced by `WITH POLYMORPHIC` + comptime dispatch.
- BUFFERED / ACTOR semantics → out of scope for this milestone; revisit when the runtimes exist.
- "Default error handling … must not silently choose semantic mode" → preserved literally: `Deadlock` and `LockCycle` are inline-only and cannot have defaults.
- Failure-policy `Default` block → renamed to `SYNC POLICY START ... END`, single-instance, main-file-only, completeness-checked.
- Effects "may block / may retry / may allocate / may queue" — partially adopted as `blocks_maybe` / `contends_maybe`; the rest stay implicit until the runtimes for buffered / actor land.
