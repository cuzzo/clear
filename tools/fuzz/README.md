# tools/fuzz — Combinatorial Fuzz Harness

Template-based program generator that stresses MIR ownership invariants and
escape-analysis cross-products. Runs `.cht` programs through the existing
`./clear test` pipeline, which catches MIR violations (statically) and leaks /
UAF / double-free (at runtime via `std.testing.allocator`).

## Usage

    # Generate + run the full matrix (every parameter combination)
    ruby tools/fuzz/run.rb --matrix

    # Sample N tuples from the matrix with a fixed seed
    ruby tools/fuzz/run.rb --count 50 --seed 42

    # Generate only — useful for inspecting outputs before running them
    ruby tools/fuzz/run.rb --matrix --generate-only

    # Custom output dir + clean previous run
    ruby tools/fuzz/run.rb --matrix --out /tmp/fuzz --clean

Exit code is 0 only if every program parses, type-checks, transpiles, runs,
and reports zero leaks.

## Mutant Harness

`tools/fuzz/mutants/run.rb` is a manual-only safety check for the fuzz suite
itself. It deliberately applies a small patch that disables one ownership rule,
runs the relevant fuzz templates before and after the patch, then reports
whether the mutated compiler produced new failures relative to baseline.

This is intentionally not a default CI job: it is slower than normal fuzz
generation and mutates the working tree while it runs. The runner checks that
the patch applies, refuses to touch target files that already have local edits,
and reverses the patch before exiting. Use `--allow-dirty` only when you
intentionally want to test a mutant against WIP.

    # List available mutants
    ruby tools/fuzz/mutants/run.rb --list

    # Check patch applicability without running fuzz
    ruby tools/fuzz/mutants/run.rb --mutant allow_with_alias_return --dry-run

    # Run a single mutant
    ruby tools/fuzz/mutants/run.rb --mutant allow_with_alias_return --out /tmp/clear-fuzz-mutants

    # Run against WIP that touches mutant target files
    ruby tools/fuzz/mutants/run.rb --mutant allow_with_alias_return --allow-dirty

Each run writes baseline and mutated fuzz logs under the chosen output
directory. A mutant is useful when it is "killed": the mutated run produces the
configured failure delta over the baseline run.

## Layout

    tools/fuzz/
      run.rb            # driver
      generator.rb      # template registry + tuple iteration
      surface_registry.rb
      coverage.rb
      mutants/          # manual targeted safety mutants
      templates/*.rb    # one file per template
    transpile-tests/fuzz/
      fuzz_<name>_<hash>.cht   # generated programs (gitignored)

Each template registers itself with `FuzzGenerator.register(name, cells:) { |params| ... }`,
declaring its parameter cells (the matrix it owns) and a renderer that turns a
cell into a complete .cht source string with embedded `ASSERT` oracles.

## Current templates

| Template                    | Active cells | Stresses |
|-----------------------------|--------------|----------|
| `escape_via_return`         | 18           | E2 :always_returned, :heap_ptr_return |
| `loop_carry_collection`     | 8            | E2 :loop_carry_string + frame-rewind invariant |
| `mutable_collection_param`  | 8            | E2 :mutable_list_param_escape, INV-CROSS-FRAME-PARAM-ALLOC |
| `nested_loop_escape`        | 12           | Loop-local list/map escape -> outer container (commit 9fa21926). `wrap_kind` axis (`:bare` / `:struct_field`) per docs/agents/bug9-forensic.md: struct-wrapped escapes fail today as designed, pass once escape-analysis walkers are unified. |
| `collection_shape_smoke`    | 12           | Shape/admission smoke coverage for every collection form named in the surface registry. |
| `ownership_surface_smoke`   | 34           | Global smoke coverage for cleanup shapes, escape sinks, and MIR ownership contracts. |
| `takes_move_modality`       | 35 (+13 in_dev) | EVERY :cleanup_value_shapes member passed to a TAKES param via GIVE / bare(implicit) / COPY. Registry-driven (no hand-picked shapes). 16 shapes x 3 modalities = 48 cells. in_dev cells gated by #43 (union variant store), #51 (struct/rt-missing), #52 (sharded/soa-list cleanup .len), #53 (sharded hash_map COPY segfault); flipping them is those bugs' acceptance test. |
| `return_value_modality`     | 8 (+8 in_dev)   | EVERY :cleanup_value_shapes member returned from `FN producer() RETURNS T -> ... END`. Breadth axis complementing heap_ownership_transfer's depth on list/string. in_dev cells gated by #43 (union return), #52 (sharded/soa cleanup), #54 (set/pool return loses contents at runtime). |
| `struct_field_store_modality` | ~30 (+24 in_dev) | EVERY :cleanup_value_shapes member stored into `STRUCT Box { f: T }` via GIVE / COPY / bare. Registry-driven (18 shapes including frame_*). in_dev cells gated by #55 (COPY broken across most shapes), #56 (GIVE/bare type mismatches), #57 (String bare annotator quirk). |
| `heap_ownership_transfer`   | 89              | ret_form (ident/literal/call/give/or_rescue) x bind_form (bare/or_raise/or_fallback/discard/discard_or_raise/onward) x decl (T/!T) -- the depth axis for :heap_list and :string returns (ported from origin/register-machine #13 manifest). |
| `bg_capture_typing`         | small           | Type-inference cells for BG-block captures. |
| `bg_copy_param_reentrant`   | 6               | COPY of @list param into BG calling reentrant function. |
| `infallible_signature`      | small           | Cells exercising infallible (non-`!T`) function signature lowering. |
| `binary_op_matrix`         | 30           | Binary operator lowering/admission combinations. |
| `capability_wrap_matrix`   | 7            | Capability wrapper construction/admission cells. |
| `catch_allocator_matrix`   | 10           | Error/catch paths that preserve allocator identity. |
| `catch_reassign_matrix`    | 8            | Catch/fallback reassignment ownership cells. |
| `indexed_assignment_matrix`| 20           | Indexed assignment into lists/maps across value shapes. |
| `indirect_recursive_union` | 12           | Recursive union payloads through indirect storage. |
| `match_matrix`             | 6            | MATCH lowering over union and scalar shapes. |
| `stream_into_boundary`      | 48 (+18 in_dev) | NEXT value passed across BG / DO / BG STREAM boundary, all sync wrappers |
| `lifetimed_return`          | 18           | BG handle escape rejection — exercises bg_lifetime_sources stamping |
| `access_gate`               | 50              | WITH-alias escape rules — 5 alias-perm tuples × 10 patterns |
| `polymorphic_sync_admission`| 36              | Which (callee × caller binding) tuples are admitted |
| `execution_boundary`        | 27              | What can / can't cross BG / DO / BG STREAM × @parallel / @pinned |
| `promise_handle_capture`    | 3               | Plain `~T` promise handles moved into BG consumers and rejected on outer reuse |
| `loop_cleanup`              | 40              | INV-2 / INV-6: alloc-cleanup pairing under loop disruptors (break, continue, return, raise) |
| `error_cleanup`             | 24              | INV-9: alloc-cleanup pairing on error paths (OR PASS / RAISE / DEFAULT) |
| `branch_cleanup`            | 48              | INV-2: alloc-cleanup pairing across IF/ELSE branches with optional early-return |
| `or_positional`             | 60              | `expr OR <action>` in every syntactic position × action × inner outcome |
| `cond_or_fallback`          | 8               | `(maybe(...) OR fallback) <cmp> baseline` inside IF / WHILE conditions. Surfaces bug #1 (lower_if hoist ordering) per docs/agents/clear-bug123-forensic.md — `:heap_string` cells fail today, pass once lower_if isolates cond `@pending_stmts`. |
| `loop_local_method_temp`    | 12              | Method-call result bound as a per-iteration temp inside WHILE / FOR. Surfaces bug #2 (FRAME_NO_REWIND lowering-synthesis gap) per docs/agents/clear-bug123-forensic.md — `:split` cells fail today, pass once `LoopFrameAnalysis.local_frame_decls` recognises stdlib-method frame returns. |

### `stream_into_boundary` matrix

Combinatoric set for "STREAM nexts passed in DO / BG / BG STREAM blocks".
Per-cell parameters:

- `consumer` ∈ {bg, do, bg_stream}
- `ownership` ∈ {local, shared}                 (per spec — @multiowned/@indirect cannot cross)
- `sync` ∈ {none, locked, write_locked, atomic, versioned}
- `move` ∈ {borrow, copy, give, clone, lend}    (CLONE only for @shared/@split)
- `value` ∈ {int, string, struct}               (struct used for non-atomic @shared cells)

**Phase A** (12 active): `@local` × {borrow, copy} × {int, string} × 3 consumers. DO+@local
cells expected `:compile_error` (DO branches don't capture outer @local locals).

**Phase B** (36 active, was 90 :in_dev): `@shared` with each of 4 sync wrappers ×
{borrow, copy, clone} × 3 consumers. Per-sync value: `@atomic` uses Int64 (bare
Atomic, no Arc); `@locked` / `@writeLocked` / `@versioned` use a Counter struct.
Access dispatch: WITH EXCLUSIVE for locked/writeLocked, WITH SNAPSHOT for versioned,
direct read for atomic primitives.

Findings encoded as `:compile_error` (matrix runs cleanly today):
- DO + @shared (any move): DO branches don't capture outer @shared bindings.
- CLONE + (atomic | locked | writeLocked | versioned): "CLONE only supported on
  @split streams, @shared promises, owned shared handles". Bare Atomic primitives
  and sync-wrapped structs aren't recognized as Arc'd by CLONE.

Outstanding `:pass` failures (real findings the matrix surfaces):
- (BG | BG STREAM) + atomic + (borrow | copy) + Int64: BG body capture yields
  `*AtomicInt(i64)` instead of auto-loading. Workaround in test corpus (test 339)
  is to call a helper fn with `REQUIRES c: ATOMIC` rather than read directly.
- (BG, versioned, copy, struct): single edge case currently MIR-fails.

**Phase C** (18 :in_dev): LEND keyword (TODO.md:41 — not yet parsed). The
LEND escape-poisoning rules will become negative-test cells (`expected:
:compile_error`) when LEND lands.

### `access_gate` matrix

Verifies CLAUDE.md's non-escaping rule: aliases bound by `WITH (EXCLUSIVE |
BORROWED | RESTRICT | SNAPSHOT)` cannot escape their block. The legal
exception is `RETURN COPY alias`.

5 alias-perm tuples (alias kind forces the permission):

| Alias | Permission | Notes |
|---|---|---|
| `EXCLUSIVE` | `@locked`, `@writeLocked` | mutable, exclusive |
| `BORROWED`  | plain (no perm)            | read-only borrow |
| `RESTRICT`  | plain (no perm)            | mutable borrow on a MUTABLE source |
| `SNAPSHOT`  | `@versioned`               | read-only snapshot |

× 10 patterns per cell (2 baselines + 8 escape attempts) = **50 cells**.

Patterns:

- `baseline_use` — `WITH ... { x = ref.value }` (no escape) — `:pass`
- `baseline_copy_return` — `WITH ... { RETURN COPY ref }` — `:pass`
- `return_alias` — `RETURN ref` — must reject
- `return_field` — `RETURN ref.value` — must reject (CLAUDE.md: any
  GetField/GetIndex chain rooted at non-escaping symbol)
- `bg_capture` — `RETURN BG { ref.value }` — must reject
- `do_capture` — `append(handles, BG { ref.value })` inside WITH — must reject
- `bg_stream_capture` — `RETURN BG STREAM { YIELD ref.value }` — must reject
- `takes_consume` — `consume!(GIVE ref)` — must reject
- `store_field` — `outer.field = ref` — must reject
- `list_append` — `list.append(ref)` — must reject

**Findings on the current tree** (4 cells `:pass`-marked but currently fail):

The escape-rule rejection is solid — all 40 negative cells properly
reject with the right diagnostic ("Cannot RETURN 'ref' from inside a WITH
block. WITH aliases are borrows..."). The bugs surfaced are in the LEGAL
path:

- `(exclusive, locked, baseline_copy_return)` — Zig codegen error
  "expected error_union, found *T". `RETURN COPY ref` lowers to a `*T`
  pointer instead of a Counter value.
- `(exclusive, write_locked, baseline_copy_return)` — same
- `(restrict,  plain,        baseline_copy_return)` — same
- `(snapshot,  versioned,    baseline_copy_return)` — same
- `(borrowed,  plain,        baseline_copy_return)` — **passes** (the
  one alias kind where COPY return is correctly lowered)

The unit test `spec/with_alias_escape_spec.rb` "allows RETURN COPY of an
EXCLUSIVE alias" stops at annotation and never observes the codegen-
level type mismatch. The matrix end-to-end run does. This is exactly
the gap the harness was added for.

### Cleanup-correctness matrices (B1: three focused templates)

`loop_cleanup`, `error_cleanup`, and `branch_cleanup` share a common
dimensions module (`templates/_cleanup_dimensions.rb`) so adding a new
allocation kind propagates to all three. Each template owns its
control-flow dimension (loop disruptors, error patterns, branch shapes)
since those are template-specific.

The shared module exposes `ALLOC_KINDS` (`:heap_list`, `:heap_string`,
`:frame_string_concat`, `:frame_list`), `VALUE_DESTS`, and helpers for
emitting allocation declarations and use statements.

Together these stress INV-2 (every alloc has a cleanup on every path),
INV-6 (loop bodies that frame-allocate have per-iteration mark/rewind),
and INV-9 (error paths preserve allocator identity). The matrix surfaces
many findings — see `docs/agents/formal-verification-bugs.md` for the
catalogue.

### `execution_boundary` matrix

Verifies the modifier × ownership rules from `src/ast/diagnostic_registry.rb`.
Cross-product:

- `boundary` ∈ {bg, do, bg_stream}
- `modifier` ∈ {none, @parallel, @pinned}
- `ownership` ∈ {@local, @shared:locked, @multiowned}

= **27 cells**.

Expected (per docs/sharing-capabilities.md + diagnostic registry):

- `(any boundary, @parallel, @local)` → reject ("@local variable cannot
  be used in @parallel block")
- `(any boundary, @parallel, @multiowned)` → reject ("@multiowned (Rc)
  variable cannot be used in @parallel block")
- `(any boundary, @parallel, @shared:locked)` → accept
- All `(none | @pinned)` cells → accept

**Findings on the current tree** (8 cells fail end-to-end):

- `DO + @local` and `DO + @multiowned` (modifier none or @pinned, 4 cells):
  DO branches lower to inner Zig fns that don't close over outer @local /
  @multiowned bindings. Existing test corpus only uses DO with
  `@shared:locked` state. Either DO should learn to capture these, or the
  docs should clarify that DO requires @shared.
- `BG STREAM + @parallel` and `BG STREAM + @pinned` (4 cells): the BG
  STREAM parser has no equivalent of `parse_bg_prefix` — modifier sigils
  inside the stream body don't parse. Inconsistent with BG which does
  accept them. Either BG STREAM should accept modifiers OR the
  diagnostic registry should document the limitation.

The @parallel-with-@local and @parallel-with-@multiowned rejections fire
correctly across all 3 boundaries — diagnostic enforcement is solid for
those rules.

### `polymorphic_sync_admission` matrix

Verifies which (callee signature × caller binding) combinations the
annotator admits. Cross-references the `LOCAL` family viralization
concern: should `LOCAL` stay admissible alongside `LOCKED` in the same
REQUIRES clause?

6 callee forms × 6 caller bindings = **36 cells**.

Callee forms:

- `:concrete` — `FN tick!(MUTABLE c: Counter) RETURNS Void`
- `:shared_param` — `FN tick!(MUTABLE c: SHARED Counter) RETURNS Void`
- `:req_locked` — `REQUIRES c: LOCKED`, body `WITH POLYMORPHIC EXCLUSIVE`
- `:req_versioned` — `REQUIRES c: VERSIONED`, body `WITH SNAPSHOT ... ON MvccConflict RAISE`
- `:req_local` — `REQUIRES c: LOCAL`, body `WITH POLYMORPHIC c`
- `:req_locked_or_local` — `REQUIRES c: LOCKED | LOCAL`, body `WITH MATCH`

Caller bindings: `@locked`, `@writeLocked`, `@versioned`, `@local`,
`@multiowned`, plain.

Expected admissions per docs/sharing-capabilities.md:

| Callee | Admits |
|---|---|
| `:concrete` | plain only |
| `:shared_param` | locked, writeLocked, versioned (any `@shared:*`) |
| `:req_locked` | locked, writeLocked |
| `:req_versioned` | versioned |
| `:req_local` | local, multiowned, plain |
| `:req_locked_or_local` | union of LOCKED + LOCAL |

**Findings on the current tree** (1 UNEXPECTED-PASS + 12 MIR-FAILs):

- `(concrete, @local)` UNEXPECTED-PASS — concrete callee accepts `@local`.
  Per docs it should only accept plain `T`. Either documentation gap or
  admission too lax. This is the canonical viralization-risk surface from
  the language design discussion.
- `SHARED T` rejects `@locked` / `@writeLocked` / `@versioned` short
  forms (3 cells) — short forms don't coerce to `@shared:*` at call sites.
  Test 349 uses the explicit `@shared:locked` form which works.
- `WITH MATCH` syntax not parsed — "Unknown WITH capability 'MATCH'"
  (5 cells, all `:req_locked_or_local`). CLAUDE.md describes this; parser
  doesn't accept it yet.
- Codegen issues for some legitimately-admitted cells (`req_locked +
  @locked`, `req_versioned + @versioned`, `req_local + @local`) —
  pointer-deref / error-union-ignored Zig errors. These are the same
  patterns test 349 uses successfully with `@shared:locked` full form;
  short forms (`@locked`) trip a different lowering path.

The unit specs (`spec/sync_polymorphism_integration_spec.rb`,
`polymorphic_transaction_acceptance_spec.rb`) verify dispatch path
selection via Zig string-grep. They don't observe these end-to-end
codegen failures because they stop at annotation or at string-grep
of the emitted Zig.

### `lifetimed_return` matrix

Verifies `bg_lifetime_sources` stamping (`src/annotator.rb:6449`) translates
into ENFORCEMENT — i.e., a BG handle that captures a lifetime-bound source
(@local / @shared:atomic-primitive / @multiowned / @locked) is rejected on
escape attempts.

Cell parameters: `consumer` ∈ {bg, bg_stream} × `ownership` ∈ {local,
atomic_int, locked} × `escape` ∈ {await_in_scope, return_handle,
store_in_field}.

All 18 cells are active. `await_in_scope` is the positive baseline; both
`return_handle` and `store_in_field` must compile-error because the returned
BG handle, or a struct containing it, would outlive the captured source.

### `fsm_lowering` matrix

Stresses CLAUDE.md invariant #13 — "FSM emission is ONE general transform"
— by exhausting cross-products of suspend kinds × control-flow wrappers ×
placements. The 23 named transpile-tests (273-295) cover specific shapes
one-at-a-time; this matrix exercises their cross-products.

Cell parameters:
- `suspend` ∈ `{pure, next, sleep, lock}` — pure (no suspend), NEXT promise,
  IoSuspend (sleep), LockSuspend (WITH EXCLUSIVE on @locked)
- `control_flow` ∈ `{linear, if_branch, while_body, for_range, with_block,
  nested}` — wrap the suspend in each control-flow shape
- `placement` ∈ `{only, two_suspends}` — single suspend or two in sequence
  (cross-segment liveness)

= 4 × 6 × 2 = **48 cells; 6 pruned** (`:pure + :two_suspends` is meaningless
since pure has no suspend) → **42 active cells**, all currently passing.

FSM lowering verified per-cell by checking the emitted Zig contains
`FsmTask` / `submitFsmSpawn` / `spawnFsm` / `tryLockForFsm` markers (vs
the stackful-fiber `submitSpawn` path).

### Cell expectations

Each cell carries an `expected:` annotation:

- `:pass` (default) — must compile, run, and not leak.
- `:compile_error` — must fail compilation (CLEAR-level or Zig-level codegen). Used for
  documented capability boundaries (e.g., `(DO + @local)` — DO branches lower to inner
  Zig fns that don't close over enclosing locals; DO is meant for @shared state).
- `:in_dev` — emitted as a comment, NOT run. Reserves matrix space for unlanded features
  (LEND, the @shared sync phases). The matrix count stays stable as features land — flip
  the cell expectation, no schema churn.

The runner reports `UNEXPECTED-PASS` when a `:compile_error` cell compiles successfully —
that's the signal a feature has landed and the cell should be flipped to `:pass`.

Adding a new template = drop a new file under `templates/`. The generator
auto-loads everything in that directory at startup.

## When a fuzz run finds a bug

1. The failing `.cht` is named by content hash, so it's reproducible across
   runs given the same seed and template.
2. Move the failing file from `transpile-tests/fuzz/` into `transpile-tests/`
   with a descriptive name (e.g. `382_loop_local_map_escape.cht`). It becomes
   a permanent regression test caught by `./clear test transpile-tests/`.
3. Fix the underlying bug in `src/`.
4. Re-run the fuzz suite. The newly added permanent test runs as part of the
   main suite; the fuzz suite confirms no other shapes regressed.

## Verification

The system was validated by reverting commit `9fa21926` (loop frame promotion
fix for lists/maps/arrays) in the working tree: `nested_loop_escape` immediately
reported 8/8 failures with `[FRAME_NO_REWIND]` MIR errors. With the fix in
place, the full matrix passes 36/36.

## Design notes

- **Template-based, not grammar-based.** Random AST generation produces 90%
  trivial syntax that doesn't reach MIR. Templates target the bug shapes that
  actually slip through hand-written tests.
- **Per-file `clear test` invocation.** Each generated `.cht` is run through
  `./clear test <file>` which uses `gen.rb --single`. Slower than batching but
  trivial to integrate; switch to a bundled runner if matrix size grows past
  ~200 programs.
- **Static + dynamic oracles.** The MIR checker (9 invariants) catches most
  bugs before codegen; `std.testing.allocator` catches anything that survives
  to runtime as a leak.
- **No formal verification.** The MIR checker already encodes a quasi-formal
  proof of 9 invariants. Going further would cost months for marginal gain
  over randomized stress testing of those same invariants.
