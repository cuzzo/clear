# Formal-Verification & Testing Coverage

What testing layers exist, what each covers, what they explicitly don't,
and what gaps still need covering. This is the source of truth for
"is this case tested?" questions and the TODO list for new tests.

The "formal-verification" in the title is aspirational. CLEAR has no
mechanized proof checker. What it has is:

1. A **9-invariant MIR static checker** (a quasi-formal verification of
   ownership) that fires on every `./clear build`.
2. A **borrow / move / non-escaping checker** in the annotator.
3. **Sorbet** static typing on the Ruby compiler itself.
4. **Combinatoric fuzz** templates that stress cross-products at the
   end-to-end layer.

That stack is what this doc inventories. An older draft of this doc
(in a sibling repo, `~/manual/clear/docs/agents/formal-verification-testing.md`)
sketched 7 TODO areas before the fuzz harness existed. This revision
folds in those TODOs that survived, drops the ones now closed, and
renames the two combinatoric sets per the language they belong in:

- **Access-gate combinatoric set** — escape attempts through WITH /
  alias / permission boundaries. (Was "WITH-block escape matrix" /
  "Escape × Permission × Alias-Kind matrix".)
- **Execution-boundary combinatoric set** — what can and can't cross
  DO / BG / CONCURRENT, with and without `@parallel`. (Was
  "Concurrency × Ownership matrix".)

## Testing layers

| # | Layer | Location | Granularity | Oracle |
|---|---|---|---|---|
| 1 | Parser unit specs | `spec/*_parser_spec.rb` (~140 files) | AST shape per source string | RSpec asserts on AST attrs |
| 2 | Annotator unit specs | `spec/*_annotator_spec.rb`, `spec/atomic_*_spec.rb`, etc. (~130 files) | symbol table / type info per source | RSpec asserts on `entry.sync`, `type_info`, etc. |
| 3 | MIR pass specs | `spec/mir_*_spec.rb`, `spec/affine_ownership_spec.rb`, etc. (~60 files) | MIR node shape, dataflow results | RSpec asserts on MIR node trees |
| 4 | MIR static checker | `src/mir/mir_checker.rb` (9 invariants) | every `./clear build` | raises on violation pre-codegen |
| 5 | Transpiler emit specs | `spec/*_emitter_spec.rb`, `spec/test_framework_spec.rb`, `spec/polymorphic_transaction_acceptance_spec.rb` | string-grep emitted Zig | RSpec `expect(zig).to include(...)` |
| 6 | transpile-tests | `transpile-tests/*.cht` (~447 files) | end-to-end per source | `zig test` + `std.testing.allocator` |
| 7 | Module integration | `transpile-tests/module-integration/` | cross-module compile + run | `zig build test` |
| 8 | FFI integration | `transpile-tests/ffi-integration/` | extern fn boundary | `zig build test` |
| 9 | Combinatoric fuzz | `tools/fuzz/` (5 templates, ~48 active cells) | end-to-end per cell | compile + run + leak |
| 10 | Concurrency stress (zig) | `zig/runtime/*_test.zig` and Loom/Hammer/VOPR per CLAUDE.md | runtime primitives | TSan, leak detector, deterministic VOPR |
| 11 | Sorbet | `# typed: true` files under `src/` | Ruby type signatures | `srb tc` |
| 12 | Benchmarks | `benchmarks/runner.rb` | wall-time, throughput | not regression-gated; reports only |

Effective coverage flow:

    .cht source
        │
        ├─ Parser ───── unit specs (1)
        ├─ Annotator ── unit specs (2) + borrow/move/non-escaping checker
        ├─ MIR lower ── unit specs (3) + MIR checker (4) (statically rules out 9 invariants)
        ├─ Transpiler ─ string-grep specs (5) (lowering choice)
        └─ Zig output ─ transpile-tests (6) + fuzz (9) (compiles + runs + no leak)

## What's well-tested (with confidence rating)

| Area | How tested | Confidence |
|---|---|---|
| Parser grammar | Unit specs + transpile-tests | High |
| Type inference | Unit specs | High |
| MIR leak / orphan / mismatch | MIRChecker (structural, 9 invariants) | High |
| WITH block lowering (per alias kind, in isolation) | transpile-tests + emit specs | Medium |
| Frame vs heap allocation | transpile-tests (Zig safety + leak detector) | Medium-High |
| Concurrency primitives (BG, DO, BG STREAM, CONCURRENT in isolation) | transpile-tests + zig runtime tests | Medium |
| Concurrency race-freedom (atomics) | Loom + Hammer + VOPR | Medium |
| Error propagation (TRY / CATCH / SMOOTH) | transpile-tests | Medium |
| Polymorphic-sync dispatch *path selection* | `polymorphic_transaction_acceptance_spec.rb` (string-grep emitted Zig) | Medium |
| **Loop-local collection escape** | `nested_loop_escape` fuzz template + `loop_frame_analysis_spec.rb` | High (after commit 9fa21926) |
| **Function-boundary escape** | `escape_via_return` fuzz template | Medium-High |

### What the 9 MIR invariants prove

If a program passes the checker, these structural properties hold:

1. Every `AllocMark` has a matching `Cleanup`/`ErrCleanup`/`TransferMark` (no leak).
2. Every cleanup has a matching `AllocMark` (no orphan cleanup).
3. AllocMark allocator (`:heap`/`:frame`) matches cleanup allocator.
4. Heap-returning call in statement position is bound (HPT_LEAK).
5. `InlineZig` / `RawZig` calling `CheatLib.*` declares `stdlib_def`.
6. InlineZig allocator symbols match container's AllocMark.
7. Loop bodies that frame-allocate carry per-iteration `restoreLoopMark` defer.
8. Cleanup for primitives / `Id<T>` (no heap ownership) is rejected as a compiler bug.
9. Pointer-passed mutable params cannot be frame-allocated (UAF defense, INV-CROSS-FRAME-PARAM-ALLOC).

The older draft cited 7 invariants; #8 and #9 were added later.

## What's NOT covered (intentionally)

These cases are deliberately outside this stack's scope, with reasons:

| Case | Where it lives instead | Why |
|---|---|---|
| AST node attribute correctness | RSpec unit specs | Need internal-state assertions (`with_node.lock_error_clause[:retries] == 2`); fuzz can't see internals |
| Specific dispatch path chosen | Transpiler string-grep specs | Same — fuzz only sees "compiles + runs"; can't tell `.acquire()` vs `Versioned.update` was emitted |
| Parser error message wording | RSpec unit specs | Diagnostic-text precision matters; fuzz oracle is too coarse |
| Wall-time performance | `benchmarks/runner.rb` | Not regression-gated; would be flaky in CI; uses statistical comparison |
| Race-condition correctness in runtime | Loom / VOPR / Hammer | Need TSan instrumentation + deterministic seeds; CLEAR program fuzzing won't shake them out |
| Stack-overflow detection | `clear --stack-check` (objdump) | Per-function stack tier verification; needs LLVM machine pass, separate from ownership |
| Stdlib (CheatLib) function semantics | Zig unit tests in `zig/runtime/` | Registry-driven; integration tests cover the CLEAR-side wiring; modeling Zig semantics formally is out of scope |

If a test belongs in one of these categories, **don't move it to the
fuzz harness** — the oracle granularity is wrong. See the
"Polymorphic-sync migration analysis" section below for one example.

## What's NOT covered, but should be (TODO)

Ranked by bang-for-buck. Each is a candidate for a new fuzz template
unless tagged otherwise.

### High priority

#### 1. Access-gate combinatoric set (WITH / alias / permission escape)

The CLAUDE.md non-escaping rule on WITH aliases is uniformly enforced
by one flag (`SymbolEntry#non_escaping`). One uniform check is good
design, but coverage is sparse — a normalization bug in any single
escape-form checker would slip through.

**Matrix**:
- 5 alias kinds (`EXCLUSIVE`, `VIEW`, `RESTRICT`, `BORROWED`, `SNAPSHOT`)
- × 5 permission types (`@locked`, `@writeLocked`, `@shared`, `@multiowned`, `@local`)
- × 6 escape forms (`RETURN alias`, `RETURN alias.field`, BG capture,
  TAKES consumption, store-into-heap-struct-field, list append)
- = **150 cells**, ~80% negative (must reject; `RETURN COPY alias`
  is the legal exception).

**Status**: not started. **Cross-references**: `docs/agents/mir-bugs.md` #3
(WITH RESTRICT reassignment UAF); CLAUDE.md "Key rule: WITH ... AS alias
aliases are non-escaping".

#### 2. Execution-boundary combinatoric set (DO / BG / CONCURRENT × @parallel)

What can and can't cross an execution boundary, with and without
`@parallel`. The `@parallel` modifier enforces stricter rules than
plain BG / DO:

- `@local` rejected (per-scheduler affinity broken by work-stealing)
- `@multiowned` rejected (non-atomic refcount unsafe across schedulers)
- `@arena` rejected (arena is per-scheduler)
- `@pinned` BG inside `@pinned` scope must itself be `@pinned`

The error catalog is in `src/ast/diagnostic_registry.rb`. Each
diagnostic should fire on at least one combinatoric cell.

**Matrix**:
- 4 boundary forms (`BG`, `DO`, `BG STREAM`, `CONCURRENT EACH`/`WHERE`/`SELECT`)
- × 3 modifiers (none, `@parallel`, `@pinned`)
- × 5 ownership (`@local`, `@shared`, `@multiowned`, `@arena`, `@indirect`)
- × 4 sync wrappers for `@shared` (`@locked`, `@writeLocked`, `@atomic`,
  `@versioned`)
- × 5 move modes (borrow, GIVE, COPY, CLONE, LEND-when-landed)
- × 3 value types (primitive, String, list)
- = **~700-900 cells** before pruning illegal combos. Realistic
  exhaustive after pruning: **~250-400 active**, ~30% negative.

The current `stream_into_boundary` template covers a depth-1 slice
(BG STREAM × {BG, DO, BG STREAM} × @local × {borrow, copy} × {int,
string} = 12 active cells, 90 reserved as `:in_dev`). This TODO is
its expansion to the full matrix.

**Status**: scaffolding done; `@shared` wrapping renderer + `@parallel`
+ CONCURRENT not yet emitted. **Cross-references**: TODO-7 in the older
doc (Concurrency × Ownership Interaction); CLAUDE.md "Concurrency
Model"; recent commits adding `@parallel` diagnostics.

#### 3. P3.3 / P3.4 / P3.5 lock-safety under nesting

The three concurrency-static checks are tested in isolation:

- **P3.3**: hold-lock-across-yield (forbid holding a lock across `:yield`)
- **P3.4**: naked nested-WITH (forbid unranked re-acquire)
- **P3.5**: compile-time reentrant lock (forbid recursive lock acquire
  on same binding without an explicit reentrance declaration)

Their interaction under nested permission combinations
(`EXCLUSIVE @writeLocked` inside `DO {}` inside `WITH EXCLUSIVE @locked`
etc.) is not systematically covered. A nested permission chain could
satisfy each check individually but compose into a violation.

**Matrix**: 3 checks × ~6 nesting depths × 5 permissions = ~90 cells.
**Status**: not started. **Cross-references**: TODO-2 in older doc.

#### 4. Error-path × allocator identity (INV-9)

Programs with `try/catch` / `OrRescue` fallbacks where the error path
returns data from a different allocator than the success path. INV-9
in CLAUDE.md says "error paths preserve allocator identity" — one of
the 11 memory-safety invariants. Listed in `docs/agents/mir-bugs.md` #7
as a known fragility (`@pending_or_fallback_dupe` flag).

**Matrix**: ~80 cells (collection × 4 error-handling forms × 5 cleanup
positions). **Status**: not started.

### Medium priority

#### 5. Polymorphic-sync end-to-end (complementary, not replacement)

Existing specs (`spec/sync_polymorphism_integration_spec.rb`,
`spec/polymorphic_transaction_acceptance_spec.rb`) verify *which*
dispatch was chosen via Zig string-grep. They don't verify the chosen
dispatch runs leak-free. A `polymorphic_sync_e2e` template
(~50-100 cells) would add the runtime oracle.

**Status**: not started. See "Polymorphic-sync migration analysis"
below for why this complements rather than replaces the existing specs.

#### 6. Cross-module ownership

Imported `RETURNS %T` functions called from another module. Bugs
`40d97b1e` and `5ffc1ed0` were both in this area (importer-side
provenance loss). `transpile-tests/module-integration/` covers happy
paths only.

**Status**: not started. Requires multi-file generation. Cross-references:
TODO-6 in older doc.

#### 7. EscapeAnalysis phase-composition fuzzer

`EscapeAnalysis` has three phases (E1: heap_return_fns, E2:
per-declaration scan, E3: call-site tagging) whose outputs feed each
other. There is no test that proves the E1 → E3 → E2 composition is
correct for all declaration kinds (local, param, field, BG capture).
A complex function body (nested BG, BG inside WITH, DO inside loop)
might leave a frame-allocated value un-upgraded → silent UAF in
emitted Zig (caught only by leak/UAF at runtime, not statically).

The current end-to-end fuzz harness catches *outcomes* (UAF / leak)
of phase-composition bugs but doesn't directly stress the phase
boundaries. A *unit-level* property fuzzer that generates random
function bodies and asserts `EscapeAnalysis` always stamps
`storage = :heap` on every transitively-escaping declaration would
catch these earlier and pinpoint the failing phase.

**Status**: not started. **Cross-references**: TODO-3 in older doc.
This is unit-level, so probably belongs in `spec/`, not `tools/fuzz/`.

#### 8. Frame-arena overflow stress

Large structs in deep loops, recursive call chains, nested `BG`
frames. Bugs `295d7b2b` and `b4b9da8a` came from this area.

**Status**: not started.

#### 9. MATCH TAKES variant payload

`docs/agents/mir-bugs.md` #2: matched variant without `AS` binding
leaks the payload. Not specifically templated.

**Matrix**: ~30 cells (union shape × variant-with-payload × MATCH form).
**Status**: not started.

### Low priority (or in_dev / blocked)

#### 10. LEND poisoning negative tests

Keyword unimplemented (`TODO.md:41`). Fuzz cells already reserved as
`:in_dev` in `stream_into_boundary`. When LEND lands, flip cells from
`:in_dev` to `:compile_error` for escape-attempt patterns.

**Status**: scaffolding ready; blocked on language feature.

#### 11. MIRChecker invariant completeness (mechanized proof)

The 9 invariants are enforced, but there is no written or mechanized
proof that they are *sufficient* — i.e., that a program satisfying
all 9 cannot have a UAF, double-free, or leak. The mapping from
failure mode → invariant(s)-preventing-it is implicit in CLAUDE.md.

**Approach**:
- Short-term: write the explicit failure-mode → invariant mapping.
  Makes gaps visible by inspection.
- Long-term (stretch): mechanize in Lean 4 / Coq for the subset of
  MIR that handles frame/heap alloc + drop + move. MIR is small
  enough that this is bounded work, not open-ended research.

**Status**: not started. Cross-references: TODO-4 in older doc.

#### 12. Sorbet nil-kill completion

Large portions of `annotator.rb`, `parser.rb`, `scope.rb` have
`T.untyped` returns or missing ivar `T.let` declarations. Type errors
in those paths are invisible to Sorbet. Already in progress on a
nil-kill branch.

**Status**: in progress (separate workstream). Cross-references:
TODO-5 in older doc. Not a fuzz concern.

#### 13. Stack-size verification combinatorics

The `clear --stack-check` flag verifies per-function stack stays
within tier limits via objdump. Combinatoric stress would catch
unintended frame growth.

**Status**: not started. Probably belongs in a separate harness, not
the fuzz harness — different oracle (objdump output, not run+leak).

## Polymorphic-sync migration analysis

Asked-and-answered: should the ~2,250 lines of polymorphic-sync specs
move to `tools/fuzz/`?

**No.** They assert at three layers the fuzz harness cannot see:

| Layer | Example | Fuzz can replace? |
|---|---|---|
| Parser AST | `ast.requires == {"c" => Set[:LOCKED]}` | No |
| Annotator state | `with_node.lock_error_clause[:retries] == 2` | No |
| Lowering choice | `zig.include?(".acquire()") && !include?("Versioned.update")` | **No — critical.** Both dispatch paths might run correctly under the wrong selection and leak no memory; the unit spec is the only place this is caught. |

Churn signal: 6 commits in 6 months across 11 files. Not a maintenance
burden. No complexity-reduction win available.

**Complementary move** (not migration): adding `polymorphic_sync_e2e`
(TODO #5 above) catches a different class of bug — runtime-contract
violations under specific sync wrappers — that the unit specs miss
because they stop at Zig string-grep.

## Workflow when adding a new fuzz template

1. Identify the invariant or escape case to stress (cite the source —
   a recent commit, a `mir-bugs.md` entry, a CLAUDE.md invariant, or
   a TODO above).
2. Drop a file under `tools/fuzz/templates/`. Auto-loaded.
3. Declare the parameter cells (the matrix). Cells get an `expected:`
   annotation: `:pass` (default), `:compile_error`, or `:in_dev`
   (reserved, not run — for unlanded features like LEND or
   capability-wrapping renderer).
4. Smoke: `ruby tools/fuzz/run.rb --templates <name> --count 5 --seed 1`.
5. Validate it would have caught a real bug: revert the relevant fix
   in the working tree, re-run, expect failures matching the bug
   shape, then `git checkout` to restore. (This was done for commit
   `9fa21926` and the `nested_loop_escape` template.)
6. If a real bug surfaces, the failing `.cht` is reproducible by
   filename. Move it to `transpile-tests/` with a descriptive name —
   it becomes a permanent regression test — and fix the bug.

See `tools/fuzz/README.md` for the harness mechanics.

## TODO summary

| # | Gap | Risk | Effort | Priority |
|---|---|---|---|---|
| 1 | **Access-gate combinatoric set** (WITH × alias × permission × escape) | Medium | Medium | High |
| 2 | **Execution-boundary combinatoric set** (DO/BG/CONCURRENT × @parallel × ownership × move) | High | Medium | High |
| 3 | P3.3/P3.4/P3.5 lock-safety nesting | Low | Low | High |
| 4 | Error-path × allocator identity (INV-9) | Medium | Medium | High |
| 5 | Polymorphic-sync e2e (complementary) | Medium | Low | Medium |
| 6 | Cross-module ownership | Medium | Low | Medium |
| 7 | EscapeAnalysis phase-composition (unit-level fuzzer) | High | High | Medium |
| 8 | Frame-arena overflow stress | Medium | Low | Medium |
| 9 | MATCH TAKES variant payload | Low | Low | Medium |
| 10 | LEND poisoning negative tests | Low | Medium | Blocked on feature |
| 11 | MIRChecker invariant completeness (proof / Lean) | Medium | High | Low |
| 12 | Sorbet nil-kill | Medium | Medium | In progress |
| 13 | Stack-size combinatorics | Low | Medium | Low |
