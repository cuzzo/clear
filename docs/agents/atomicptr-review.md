# Atomics + AtomicPtr code review (post-squash)

Review pass after squashing M1+M2+M3 into a single commit. Calls out
tech debt, parallel-systems vs integrating, test gaps, and concrete
fix proposals.

**Status:**
- ✓ B, C, D, E, F, H, I, J — landed (round 1 + round 2 of cleanups)
- ✓ Pending test fixed: lifetime_audit_spec.rb's "POS: COPY breaks
  the tied lifetime" was a speculative pending entry from an "M2.7+"
  era where COPY-of-Promise semantics weren't designed. Premise is
  flawed — COPY heap-dupes the BG handle struct, but the spawned
  fiber that captured `counter` is the same fiber regardless. The
  fiber's borrow still outlives the local. Converted to a NEG test
  asserting the existing reject (Promise-must-be-consumed OR
  Lifetime Error).
- ✓ SNAPSHOT MATCH false-probe-match fixed: in SNAPSHOT MATCH
  context, the VERSIONED probe is tightened to
  `@hasDecl(..., "Inner") and !@hasDecl(..., "compareAndPublish")`
  (excludes AtomicPtr) and the ATOMIC probe is
  `@hasDecl(..., "compareAndPublish")` (matches AtomicPtr). The
  ATOMIC arm prelude branches on `node.snapshot_mode` to use
  Guard.read for SNAPSHOT cells (matching VERSIONED) and cell-
  direct for non-SNAPSHOT primitive cells (M1.6 path). Test 344's
  emitted Zig now correctly fires the ATOMIC arm for AtomicPtr
  cells (was firing VERSIONED arm via the false probe match);
  test 345 too.
- ✗ A — **investigated and reverted**: AtomicPtr.read's `anytype` /
  `extractEbr` duck-typing is **load-bearing for polymorphic SNAPSHOT
  MATCH**. Versioned and AtomicPtr both expose `pub const Inner = T`,
  so the WHEN VERSIONED probe (`@hasDecl(..., "Inner")`) falsely
  matches AtomicPtr cells in MATCH dispatch. The dead branch still
  comptime-instantiates against the AtomicPtr type, so the
  `cell.read(rt)` call site MUST accept both `*Runtime` and
  `*ThreadLocalEbr` to keep the polymorphic compile working. The
  duck-typing is the load-bearing piece.

  Surfaced a related gap: the M3.13 transpile-test 344 was
  technically passing because the VERSIONED arm was instantiating
  for AtomicPtr cells (the false probe match) and the body
  happened to compile because AtomicPtr.read accepted `*Runtime`
  via duck-typing. The CORRECT arm for AtomicPtr is ATOMIC, and
  fixing that requires either (1) making the VERSIONED probe
  exclude AtomicPtr (`@hasDecl(..., "Inner") and !@hasDecl(...,
  "compareAndPublish")`) AND extending the ATOMIC arm's prelude
  to comptime-branch between primitive/AtomicPtr forms, or (2)
  introducing a dedicated `INDIRECT_ATOMIC` family. Neither is
  trivial; tracked as a follow-up below.
- pending: C (consolidate suggesters), G (no-action), K (no-action)

Updated test totals: 3248 ruby specs / 414 transpile-tests / all
zig tests green; 0 leaks across the full suite.

Sorted high-to-low by impact-per-effort.

## A. `extractEbr` duck-typing in `zig/lib/atomic_ptr.zig`

**Signal:** `extractEbr` (atomic_ptr.zig:60-66) accepts either
`*ThreadLocalEbr` OR `*Runtime` via `@hasField`. Versioned takes
`*Runtime` directly (versioned.zig:204) without this hack.

**Why it's there:** AtomicPtr lives in `zig/lib/`, which can't import
`zig/runtime/runtime.zig` (cyclic dep concern). Versioned lives in
`zig/runtime/`.

**Fix:** Move `zig/lib/atomic_ptr.zig` → `zig/runtime/atomic_ptr.zig`,
matching Versioned. Drop `extractEbr` and the comptime branching;
take `*Runtime` directly. Tests in `zig/runtime/atomic-ptr-*-test.zig`
already construct `ThreadLocalEbr` directly — they'd switch to
`Runtime.initFromSlice(...)` like versioned-stress-test does.

**Risk:** Low. Mechanical move + signature change. Loom + stress tests
verify no regressions.

**Effort:** ~1 hour. **Impact:** Drops ~20 LOC of duck-typing,
makes the ebr/runtime contract symmetric with Versioned.

---

## B. `:layout` plumbing on SymbolEntry — post-hoc set vs declare kwarg

**Signal:** `annotator.rb:2349-2353`:
```ruby
current_scope.declare(node.name, ..., sync: node_sync, ...)
node.symbol = current_scope.locals[node.name]
node.symbol.layout = node_layout if node_layout
```

`sync:` is a `declare(...)` kwarg; `layout:` is a post-hoc set. Two
patterns for one concept.

**Fix:** Add `layout:` to `Scope#declare(...)` kwargs (scope.rb:17),
plumb through to `SymbolEntry.new(layout: layout)`, drop the post-hoc
assignment. Same change in `function_analysis.rb:656-660` (param
declare also sets `param[:symbol].layout = :indirect` post-hoc for
the M3.11 ATOMIC-on-struct seed — the kwarg cleans that up too).

**Risk:** Low. Both call sites are tested.

**Effort:** ~30 min. **Impact:** One pattern for axis-on-SymbolEntry
declaration; matches `sync`.

---

## C. Two parallel migration suggesters

**Signal:** `src/tools/atomic_migration_suggester.rb` (290 LOC, M1.9)
and `src/tools/atomic_ptr_migration_suggester.rb` (261 LOC, M3.15).
~150 LOC of nearly-duplicate AST walking + use classification.

Shared shape:
- `analyze(source)` — parse + annotate, walk fns, collect/disqualify
- `walk_recursive` — descends into BG/BgStreamBlock bodies (identical)
- `classify_uses!` — disqualifies on Identifier, FuncCall arg, ReturnNode
- `references_alias?` — recursive AST walk detecting alias refs
- `control_flow_stmt?` — class-name check for IF/WHILE/FOR/...

Differences:
- Eligibility predicate (single-primitive-field vs struct)
- Body-eligibility (compound-arith desugar vs whole-struct-replace)
- Sigil-name reporting

**Fix options:**
1. **Extract a `MigrationSuggesterBase` mixin** with `walk_recursive`,
   `classify_uses!`, `references_alias?`, `control_flow_stmt?`. The
   two suggesters become thin specializations.
2. **Single `MigrationSuggester`** with multiple `EligibilityPolicy`
   strategies (atomic-primitive policy, atomic-ptr policy). Cleaner
   but bigger refactor.

**Risk:** Medium — touches well-tested code. Spec coverage on both
sides should catch regressions (12 + 9 examples).

**Effort:** Option 1: ~2 hours. Option 2: ~4 hours.
**Impact:** Drop ~150 LOC; new migration types (e.g., MVCC-upgrade-to-
AtomicPtr from the M3.16 deferred surface) become 30-line additions
instead of 250-line copies.

---

## D. SNAPSHOT alias inner_type misses @indirect:atomic strip

**Signal:** `capabilities.rb:482`:
```ruby
inner_type = st.versioned? ? st.bare_data_type : st
```

For `@indirect:atomic`, `st.versioned?` is false, so `inner_type = st`
(carries sync=:atomic, layout=:indirect). The alias's `SymbolEntry`
doesn't actually CARRY those flags (sym.sync/layout default nil
because the declare call passes neither), but the alias's
`.type` field IS the full @indirect:atomic Type.

**Why it works today:** The M3.10 reject (`reject_bare_atomic_ptr_mutation!`)
checks `sym.sync == :atomic && sym.layout == :indirect` — NOT the
type. So the alias falls through (its sym has nil for both).

**Risk if missed:** Future code that reads `alias.type.sync` (instead
of `alias.sym.sync`) would see :atomic on the alias and apply
@indirect:atomic semantics where the alias is actually a bare *T
pointer. Land-mine for downstream work.

**Fix:** Extend the strip:
```ruby
inner_type = if st.versioned? || (st.atomic? && st.indirect?)
  st.bare_data_type
else
  st
end
```

**Risk:** Low. Tests M3.5/M3.6/M3.13 already pass; this just
preserves that behavior under future code that reads alias.type.

**Effort:** 5 min. **Impact:** Removes a future-bug land-mine.

---

## E. Test gap: escape via RETURN of @indirect:atomic

**Signal:** `docs/agents/atomicptr.md` §5 commits to "Storing an
@indirect:atomic cell in a long-lived struct field, returning it
from a function, capturing it into a long-lived BG handle — all
fine." M3.12 verified the BG-handle case. The RETURN case was
deferred during M3.13 (transpile-tests):

> The escape-via-RETURN case is a separate concern: Arc-managed
> cleanup of an @indirect:atomic returned through a fn signature
> needs additional cleanup-classification work the bare M3 design
> contract doesn't yet specify (M3.12 only exempted the BG-capture
> lifetime audit, not the caller-side cleanup of a returned cell).

**Surfaced:** Calling `make() RETURNS Cfg@indirect:atomic` produces
a heap-allocated cell; the caller's `cfg = make()` binding takes
ownership. The cleanup classifier needs to recognize the returned
type as :rc-shaped (heap pointer to AtomicPtr cell) so the
cleanup() shim's @hasDecl(child, "compareAndPublish") branch fires.
Ad-hoc test produced a leak.

**Fix:** Two parts:
1. **Test:** `transpile-tests/346_atomic_ptr_escape_return.clear`
   demonstrating the escape pattern (small fn returning an
   @indirect:atomic cell; caller reads it).
2. **Investigate:** the actual leak when I tried the test. Likely
   classify_rc_or_link in promotion_plan.rb needs to handle the
   atomic-ptr case specifically (currently bindings DECLARED as
   @indirect:atomic auto-promote to ownership=:shared and hit the
   :rc path; bindings RECEIVED as `cfg = make()` with
   `RETURNS Cfg@indirect:atomic` may not get the same classification).

**Risk:** Medium — could surface a real bug. If it does, fix is
worth it.

**Effort:** ~2 hours (test + investigate + fix if needed).
**Impact:** Closes a known gap in the documented contract.

---

## F. Numbering collision: `benchmarks/concurrent/18_*`

**Signal:**
```
benchmarks/concurrent/18_atomic_counter   (M1.8 — primitive @shared:atomic)
benchmarks/concurrent/18_atomic_ptr       (M3.14 — @indirect:atomic)
```

Both numbered 18 because each milestone created independently against
a then-empty number-space.

**Fix:** Renumber `18_atomic_ptr` → `19_atomic_ptr`. Two-line change.

**Risk:** None. Just a path rename.

**Effort:** 5 min. **Impact:** Numerical sequence stays unique;
matches the existing benchmark indexing convention (where 17a/17b/17c
are deliberate sub-numbers).

---

## G. Test gap: VOPR for AtomicPtr (deferred per M3.3 contract)

**Signal:** Per the M3.3 testing contract recorded at
`/home/yahn/.claude/projects/-home-yahn-litedb/memory/feedback_concurrent_runtime_testing.md`,
VOPR is "required IF the loom test reveals state-machine complexity
beyond pure CAS-publish." AtomicPtr is pure CAS-publish + EBR retire,
so VOPR was deferred — correctly.

**Re-evaluate:** is there state-machine complexity hiding? Reviewing
atomic_ptr.zig:
- `init` — heap-alloc + initial publish.
- `read` — EBR enter + load + Guard.
- `update` — load + clone + user-fn + cmpxchg + retire.
- `compareAndPublish` — single cmpxchg + retire-on-success.
- `deinit` — swap-null + retire.

No multi-step state machine. Loom + stress is sufficient. **No action.**

---

## H. Test gap: doctor M3.16 MVCC-upgrade signal (design surface 2)

**Signal:** `docs/agents/atomicptr.md` M3.16 lists two surfaces; only
surface 1 (lock-profile → atomic-ptr) is implemented. Surface 2
(`@shared:versioned` → `@indirect:atomic` upgrade when the cell only
does single-cell whole-struct commits) is deferred.

**What's needed:**
1. `mvcc.txt` profile data (zig/runtime/mvcc-profile.zig) currently
   doesn't distinguish single-cell `Versioned.update` from multi-cell
   `Shared.updateMulti`. Add a counter.
2. Extend `AtomicPtrMigrationSuggester` to recognize
   `@shared:versioned` sources whose WITH SNAPSHOT MUTABLE bodies
   are whole-struct replace.
3. New `emit_atomic_ptr_upgrade_from_mvcc!` in `src/tools/doctor.rb`.

**Risk:** Medium — touches mvcc-profile + the suggester. Not a
correctness concern; a feature gap.

**Effort:** ~3 hours. **Impact:** Closes a documented design
contract surface.

---

## I. Stale gitignore: `transpile-tests/337_atomic_basic_ops`

**Signal:** Test runner builds binaries into `transpile-tests/337_*`
(no extension) as a build artifact. They show up as untracked in
`git status` after every test run. Other tests have the same pattern
(`transpile-tests/<NNN>_<name>` binary alongside the `.clear` source).

**Fix:** Add `transpile-tests/[0-9][0-9][0-9]_*` (with no extension)
to `.gitignore`, OR make the test runner build into a temp dir.

**Risk:** None. Quality-of-life cleanup.

**Effort:** 5 min. **Impact:** Cleaner `git status`.

---

## J. Cleanup classification: @indirect:atomic via `:rc` path is roundabout

**Signal:** In `promotion_plan.rb classify_binding`, an
`@indirect:atomic` binding flows through `classify_rc_or_link`
because the M3.5 auto-promotion sets ownership=:shared, which makes
`ti.any_rc?` true. The result is a `:rc` cleanup entry whose
`zig_type` is `*CheatLib.AtomicPtr(T)` (correct), and the
cleanup() Zig shim then comptime-detects AtomicPtr via
`@hasDecl(child, "compareAndPublish")`.

**Why it works:** ti.zig_type for @indirect:atomic returns the right
zig type (M3.1), so the rc path's `ti.zig_type` substitution lands
on the right cleanup-arg type.

**Why it's roundabout:** the binding ISN'T really an Rc cell — it's
an atomic-ptr cell with internally-managed Arc. The classification
fires :rc, but the actual cleanup path is the dedicated AtomicPtr
branch in cleanup(). The :rc kind is a misnomer for this case.

**Fix:** Add a `classify_atomic_ptr` to promotion_plan.rb that fires
when `ti.atomic? && ti.indirect?`, returning a dedicated `:atomic_ptr`
kind. The emitter's `case entry[:kind]` then routes to a clean
emission path. Two new lines plus a small emitter case.

**Risk:** Low. The current path works; this is a clarity refactor.
Loom + stress tests + the M3.13 transpile-tests catch any regression.

**Effort:** ~1 hour. **Impact:** Removes the "an @indirect:atomic
binding is classified as :rc" surprise. Self-documenting.

---

## K. Two doctor candidate lists — `atomic_candidates` and `atomic_ptr_candidates`

**Signal:** `doctor.rb section_locks` builds both lists and emits
them via separate `emit_atomic_migration!` and
`emit_atomic_ptr_migration!`. Three paths (mvcc / atomic-primitive /
atomic-ptr) all gated on overlapping conditions.

**Why it's there:** Different suggesters, different surfaces.

**Why it's fine:** The two emit methods produce different per-binding
text; consolidation would be artificial. The candidate-list
duplication is two lines.

**No action.** This is a parallel-systems shape but the parallelism
is intentional — different migration targets.

---

## Summary

| Fix | Priority | Effort | Files |
|---|---|---|---|
| A. Move atomic_ptr.zig → runtime/, drop extractEbr | High  | 1h  | atomic_ptr.zig, *-test.zig |
| B. `:layout` declare kwarg (consistency w/ `sync`)| High  | 30m | scope.rb, symbol_entry.rb, annotator.rb |
| F. Renumber `18_atomic_ptr` → `19_atomic_ptr`     | High  | 5m  | benchmarks/concurrent/ |
| D. SNAPSHOT alias inner_type strip @indirect:atomic | High | 5m | capabilities.rb |
| I. Gitignore transpile-tests/<NNN>_* binaries     | Low   | 5m  | .gitignore |
| C. Consolidate two migration suggesters           | Medium | 2-4h | src/tools/ |
| J. Dedicated `:atomic_ptr` cleanup kind           | Medium | 1h  | promotion_plan.rb, mir_emitter.rb |
| E. Escape-via-RETURN test + investigate          | Medium | 2h  | transpile-tests/, possibly promotion_plan.rb |
| H. Doctor MVCC→AtomicPtr upgrade signal           | Medium | 3h  | mvcc-profile.zig, suggester, src/tools/doctor.rb |
| G. VOPR test for AtomicPtr                        | n/a   | n/a | (no action — deferred correctly) |
| K. Consolidate doctor candidate lists             | n/a   | n/a | (no action — intentional parallelism) |

**Recommended order:** F → I → D → B → A → C → J → E → H. The first
four are quick wins (~50 min total) that reduce the parallel-system
surface without touching well-tested logic. A is the biggest single
cleanup. C and J reduce ~250 LOC combined and are good follow-ups
once the surface is settled. E and H close design-contract gaps.
