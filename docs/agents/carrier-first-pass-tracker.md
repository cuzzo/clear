# Carrier Polymorphism — First-Pass Implementation Tracker

Design: `docs/agents/keep_or_clone.md` §0 (UNIQUE / MONOMORPHIC / SHARED;
the non-monomorphic tag path is deferred). Legend: `todo` | `in-progress` |
`done`.

## Per-commit gates (every task)

- `bundle exec srb tc` clean; **new Ruby code 100% strongly typed**.
- `bundle exec prspec compiler/spec/` green.
- **100% LoC coverage on new lines** (SimpleCov via `COVERAGE=1`).
- `./clear test transpile-tests/` 618+/N passing, **0 leaks** (when lowering
  touched).
- New features get **transpile-tests** (integration-like CLEAR programs).
- Targeted specs — prefer CLEAR-code integration-like; pure unit only as a
  fallback where it makes sense.
- Expand the **two fuzz suites** (semantic family + `carrier_ownership_matrix`)
  where relevant; negative cells pin diagnostic codes.
- **Zig runtime changes**: 100% LoC coverage (except `~/dwarf-bug`); run
  slopcop `dark-arms` for hazards; **Loom** (atomics) / **VOPR** (random,
  timing, wait loops, retries) / **TSan** (threaded) as applicable.

## Naming resolution

The carrier-polymorphic fan-out operator is **`KEEP`** (already implemented;
copy-for-plain, retain-for-Rc/Arc = the design's `COPY_OR_KEEP` semantics).
`MONOMORPHIC` specialization resolves `KEEP` per concrete carrier. If the
`COPY_OR_KEEP` spelling is preferred it is a mechanical rename; not blocking.

## Tasks

| ID | Task | Status |
| --- | --- | --- |
| C-0 | Tracker + naming resolution (this file) | done |
| C-1 | DONE. UNIQUE_NEEDS_EXCLUSIVE: a bare retained (@multiowned/@shared) arg to a UNIQUE param is rejected (live multi-owned handle); COPY detaches -> accepted; plain owned -> move accepted. verify_unique_argument! in the arg walk. Spec 4/4, transpile 635 leak-free (624/624). | done |
| C-2 | DONE (verified). SHARED resolves to concrete @shared (Arc): accepts @shared, rejects plain in DEFAULT+STRICT (ARG_NEEDS_SHARED, fixable), rejects @multiowned so it never spans both carriers; auto-retains multiple uses. Covered by shared_contract_spec (5 specs, V5-3c) + transpile 634. Design correction recorded in keep_or_clone.md §0.1. The @multiowned-sugar variant + EASY auto-box are optional enhancements, not required (use @multiowned/@shared sigils directly). | done |
| C-3a | DONE. `MONOMORPHIC` lexes + parses to `carrier_contract == :monomorphic`. Commit 5877c4dd6. | done |
| OWN-1 | DONE. `OWN COPY x` (the sole handle->owned-RawT detach) + `OWN` keyword; bare `OWN x` deferred (OWN_ALONE_UNSUPPORTED). Commit b0c7ca401. | done |
| OWN-2 | DONE. Silent retained->plain-slot detach gated: bare/GIVE handle into a plain user param -> RETAINED_NEEDS_OWN_COPY. Commit 4288c9817. | done |
| OWN-3 | DONE. Bare COPY of a retained handle illegal everywhere (COPY = memcpy); OWN COPY is the detach; UNIQUE requires OWN COPY. Commit 57b71b12c. | done |
| C-3b | DONE. MONOMORPHIC param emitted `anytype`; carrier_contract flows onto the signature (single-source fix); call site threads the handle (no detach); field access comptime-unwraps (MIR::ComptimeCarrierPayload); forced universal comptime cleanup releases per carrier. Core example threads plain/@multiowned/@shared leak-free. Commit 28a7cd2b9. | done |
| C-3c | DONE. KEEP in a MONOMORPHIC variant -> MIR::MonomorphicKeep (comptime retain-or-copy); the deferred_specialization fail-closed raise now fires ONLY for the unconstrained/tag path (still deferred, maybe never), which MONOMORPHIC does not claim to cover. Commit 28a7cd2b9. | done |
| C-3d | DONE. [Note] warns when a fn has >=3 MONOMORPHIC params (up to 3^N variants); synthetic needs-drop cleanup plan so MONOMORPHIC compiles without an @multiowned local present. Commit 206a59519. | done |
| C-3c | `KEEP` in a `MONOMORPHIC` variant resolves per carrier (plain->structural copy, @multiowned->non-atomic retain, @shared->atomic retain); final use MOVES; `KEEP` required only at a NON-final fan-out. Plain instantiation FAILS without a valid structural CopyPlan (rule 7/8 per variant). | todo |
| C-3d | Variant-count warning past a threshold (combinatoric-explosion visibility; counts GC-shape-merged variants). | todo |
| C-4 | DONE. Transpile-tests: 636 OWN COPY detach, 637 MONOMORPHIC thread (plain/@multiowned/@shared leak-free), 638 MONOMORPHIC KEEP (per-carrier). UNIQUE (635) + SHARED (634) already covered; 632 shared->unique now OWN COPY. Commits b0c7ca401, 28a7cd2b9. | done |
| C-5 | DONE. carrier_ownership_matrix 10->15: +own_copy_detach, +monomorphic_thread, +monomorphic_keep (positives, leak-checked); +bare_retained_plain (RETAINED_NEEDS_OWN_COPY), +own_alone (OWN_ALONE_UNSUPPORTED). Mutant retained_needs_own_copy KILLED. Commit f4ac47311. | done |
| C-6 | DONE (none needed). No new Zig: MONOMORPHIC reuses the existing comptime primitives (retainOne/releaseOne/cleanup/isAtomicRef/@hasField). No atomics/threads/timing added -> no Loom/VOPR/TSan required. | done |
| C-7 | DONE (2026-07-24 re-verification at 3bad73941). sorbet clean, prspec 7846/0, transpile 659/659 0 leaks. lexer_compat smoke 13/13 and full corpus 801/801: 0 feature-related mismatches (3 pre-existing unrelated mismatches from DEFER/module CONST keyword additions, commits 856aeaf29/3fa951e75, need a lexer.clear regen orthogonal to this feature). Fuzz: found + fixed rc_generic_collection_matrix's pre-OWN-3 `COPY item` on a live @shared handle (now `KEEP item` - same fix independently landed as 114b369ca). Every fuzz template this feature owns (kept_identity_matrix, carrier_ownership_matrix, rc_generic_collection_matrix, rc_generic_value_matrix) verified clean: 194/194 cells, 0 fail/leak/mir-error/unexpected-pass. | done |
| RV-1 | DONE. Review round: fixed heap-field KEEP double-free (dupeValue), method receiver on MONOMORPHIC (comptime project), OWN COPY on MONOMORPHIC (comptime project+deepcopy), RETURN-position consuming-call ordering (bind to temp), forward-mono-to-concrete clean error; restricted comptime projection to :monomorphic; 100% new-line coverage. Tests 639/640/641 + specs. Commits 5e4ca9473, 016ea8dff. | done |

## Progress log

### C-3a (done, 5877c4dd6)

`MONOMORPHIC` added to the lexer keyword set and to `parse_carrier_contract`
(returns `:monomorphic`, mirroring `UNIQUE`). Propagates to `SymbolEntry`
through the existing single writer in `function_analysis.rb` (no new plumbing).
Specs: `parser_carrier_contract_spec` (lex + parse), `carrier_contract_symbol_spec`
(SymbolEntry). Gates: prspec 7300/0, sorbet clean.

### C-3b -- mechanism DECIDED, cross-cutting impl SURFACED for go-ahead

Investigation this session (probes, since reverted, on the core example
`consume(TAKES u: MONOMORPHIC User)` called with plain/@multiowned/@shared):

**Mechanism decision: Zig-comptime `anytype` monomorphization (NOT Ruby-side
AST instantiation).** Evidence:
- CLEAR's ENTIRE generics story is already Zig-comptime `anytype` (a user-struct
  param is emitted `anytype`, `mir_emitter` uses `comptime T: type`); there is
  ZERO Ruby-side function-instantiation infra, so the Ruby path would be a
  net-new subsystem across the memory-safety-critical passes.
- The runtime ALREADY has general comptime carrier-dispatch primitives that
  handle Rc/Arc/plain uniformly at zero runtime cost, requiring NO new Zig and
  NO atomics (so no Loom/TSan burden): `retainOne`/`releaseOne`/`cleanup`/
  `isAtomicRef`/`refInnerType` (runtime-header.zig ~3410-3513), plus the
  existing `@hasField(@TypeOf(x),"ctrl")` comptime unwrap used by
  `emit_capability_unwrap`.
- Zig's comptime engine performs per-carrier instantiation, dedup, and
  emit-only-carriers-used for free.

**Why MONOMORPHIC is genuinely the crux (distinct from BOTH existing paths):**
- A concrete-typed param (`TAKES u: User`) FIXES the carrier: a retained arg is
  auto-COPYed (payload-detached, `dupeValue(User, m.ctrl.data.*)`) into a plain
  owned `User` at the call boundary -- carrier identity DESTROYED. Verified this
  is inserted UPSTREAM of MIR lowering (an auto-`COPY m` during ownership
  transport), so it cannot be suppressed at the lowering sites alone.
- A generic-`T` param (`consume<T>(TAKES u: T)`) threads the carrier but the
  payload is OPAQUE: `u.id` fails with `ILLEGAL_FIELD_LOOKUP` (T has no known
  fields), and KEEP has no CopyPlan.
- MONOMORPHIC needs the payload TYPE known (fields, KEEP copy-plan) AND the
  carrier polymorphic/threaded. Neither existing path does both.

**Implementation plan (the change requiring go-ahead -- it rewires the
ownership-transport core, INV-1..10 critical):**
1. Suppress the auto-COPY-into-plain for a `:monomorphic` dest at the ownership-
   transport planner (annotation) so the source carrier is MOVED/threaded, not
   payload-detached. (This is the load-bearing change; the lowering-site guards
   in `cross_boundary_arg`/`managed_handle_materialized_for_plain_takes?` are
   downstream and also need the `:monomorphic` exclusion.)
2. Field access / method receiver on a monomorphic param comptime-unwraps the
   carrier -- REUSE the existing `@hasField(...,"ctrl")` `ctrl.data` pattern
   (`emit_capability_unwrap`), so `u.id` becomes `(if ctrl -> u.ctrl.data.id
   else u.id)`, pruned per monomorphization.
3. KEEP on a monomorphic param lowers to a comptime-guarded op (new
   `:monomorphic_keep` carrier_op): `if (comptime @hasField(@TypeOf(u),"ctrl"))
   CheatLib.retainOne(@TypeOf(u), u) else <structural COPY of the User payload>`
   -- replacing the current `:deferred_specialization` fail-closed raise for the
   monomorphic case only.
4. Cleanup: already handled -- the universal `CheatLib.cleanup(@TypeOf(u),
   alloc, &u)` releases plain/Rc/Arc uniformly (verified emitted for anytype
   params).

Move-only (no KEEP, no field access) already builds+runs leak-free for all
three carriers TODAY, but only because it payload-COPYs -- that is NOT the
retained-identity semantics the design requires, so it is not a valid slice to
land as-is (would encode wrong semantics in a test).

Risk: steps 1-2 touch the memory-safety core (INV-1 single allocator, INV-2
cleanup-on-every-path, INV-5 frame-escape). Recommend proceeding with the
Zig-comptime plan above, landing step-by-step with `./clear test
transpile-tests/` 0-leaks gated after each step and reverting anything that
leaks.
