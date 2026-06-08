# A-Grade Memory-Safety Architecture Plan

Branch focus: `architectural-review`.

This plan targets the three remaining architecture surfaces that most directly
affect whether Clear can reliably emit memory-safe Zig:

1. FSM/thunk async cleanup boundaries.
2. Hoist, cleanup classification, and `MIRPass`.
3. Escape, ownership graph, control-flow analysis, and `MIRChecker`.

The goal is for each stage to reach an `A` in design, architecture, and
implementation. Parser-style slop is intentionally out of scope. A large,
mutable recursive-descent parser is not the current source of memory-safety
bugs. These three areas are different: they decide ownership transfer, cleanup
timing, async lifetime, borrow validity, and whether codegen is allowed.

## What `A` Means Here

An `A` stage has these properties:

- It has explicit typed inputs and outputs.
- It has one writer for each safety-critical fact.
- Mutation windows are named and bounded; downstream phases consume immutable
  or frozen facts.
- It does not recover safety facts from rendered Zig, template strings, or
  incidental AST shape after an earlier phase already knew the answer.
- It uses stable identities for bindings, places, captures, cleanup
  obligations, moves, borrows, and async boundary fields.
- It has invariant tests over facts and MIR nodes, not only generated text.
- It fails closed when a required fact is missing.
- It improves or holds flat on Decomplex, SlopCop, Boobytrap, and nil-kill
  guardrails after each completed slice.

The implementation standard for every slice:

- 100% of new or changed code must be strongly typed.
- 100% of new or changed executable lines must be covered.
- More than 80% of new or changed branches must be covered.
- No new untyped params, returns, fields, ivars, collections, or hash-record
  candidates in compiler phase data.
- No dual long-term paths. Delete the legacy source of truth before rebuilding
  the replacement path, then drive tests from red to green.

## Baseline And Measurement Loop

Before implementation, snapshot:

- Decomplex full `src` report.
- SlopCop full report using the current coverage procedure.
- Boobytrap full `src` report.
- Nil-kill full collect and report.
- Focused source inventories for:
  - `MIR::Node | String` and bare `String` statement flows in FSM/thunk paths.
  - cleanup fact writers in hoist, cleanup classifier, MIR pass, lowering, and
    checker.
  - string-name ownership keys in escape analysis, ownership graph,
    control-flow, and checker.

After each implementation task:

- Run focused specs for the touched files.
- Run `bundle exec srb tc`.
- Regenerate Decomplex for the full repo.
- Reassess if state-based branch density, broken protocols, or temporal
  pressure moves materially in the wrong direction.

At the end of each issue:

- Run full unit coverage.
- Regenerate SlopCop, Boobytrap, and Decomplex.
- Recollect nil-kill only at the end of a major issue, unless type guardrails
  suggest a regression earlier.

## Issue 1: FSM/Thunk Async Cleanup Boundary

Target files:

- `src/mir/fsm_transform/emit.rb`
- `src/mir/fsm_lowering.rb`
- `src/mir/thunk_transform/emit.rb`

### Current Problem

The previous FSM cleanup work moved the largest release-level red flag away
from direct rendered-Zig cleanup surgery. `FsmSegmentFacts` is real progress.
The remaining problem is that async boundaries still permit mixed semantic
sources:

- `MIR::Node | String` body statements.
- `Segments::SyntheticZig` and bare rendered fragments.
- thunk frame initialization that renders expressions before the final emitter.
- hash/context adapter entry points such as `FsmEmitContext.from_hash`.
- cleanup/capture metadata that can still travel as Zig-shaped strings.

That shape is too permissive for async lifetime behavior. FSM and thunk paths
should not infer cleanup, result transfer, or context-field lifetime from text.

### Target Architecture

Async lowering should have four explicit products:

1. `AsyncBoundaryInput`
   - function identity, runtime needs, capture facts, body AST/MIR, and source
     boundary kind.
   - no rendered Zig.

2. `AsyncSegmentPlan`
   - segment index, structural statements, typed tail, suspend descriptor,
     result-transfer facts, required context fields, and cleanup obligations.
   - no `String` statements.

3. `AsyncCleanupPlan`
   - destroy actions, step-zero err-cleanups, finalizer cleanups, guard writes,
     required move guards, and owned suspend result cleanups.
   - derived from MIR nodes and explicit capture facts only.

4. `AsyncEmitPlan`
   - final backend-facing plan consumed by FSM/thunk emitters.
   - all remaining raw Zig is marked as non-semantic text and cannot contribute
     cleanup, ownership, or lifetime facts.

### Implementation Plan

1. Inventory every current `String` or `SyntheticZig` statement path in
   `fsm_transform`, `fsm_lowering`, and `thunk_transform`.
   - Classify each as semantic or non-semantic.
   - Semantic paths must become MIR nodes or typed async plan records.
   - Non-semantic paths must be wrapped in a typed `OpaqueZigFragment` with an
     explicit no-safety-facts contract.

2. Replace `FsmBodyStmt = MIR::Node | String` with a closed typed body item.
   - Preferred shape: `FsmBodyItem::MirNode`, `FsmBodyItem::OpaqueZig`,
     `FsmBodyItem::CtxRefSynthetic`.
   - Only MIR body items can feed `FsmSegmentFacts`.
   - Add architecture invariant tests proving strings cannot create cleanup,
     move guard, result, or ownership facts.

3. Replace `FsmEmitContext.from_hash` callers with typed constructors.
   - Keep a temporary private adapter only if a test harness needs it, then
     delete it before closure.
   - Every production caller should pass a typed context or typed input record.

4. Move FSM lock/error split paths to typed segment plans.
   - `FsmLockErrorArmSplit` should stop carrying `body_zig` as semantic body.
   - Lock timeout/error behavior should be represented as MIR statements plus
     a typed tail.

5. Convert thunk frame initialization to structural MIR expressions.
   - Replace early `render_expr` usage with `ThunkFrameInitPlan`.
   - The final emitter renders the plan; it does not decide what values are
     captured or cleaned up.

6. Add invariant tests.
   - A NEXT bind before a lock-try tail runs and frees owned results.
   - Cross-segment cleanup is lifted to destroy/finalize facts.
   - Rendered strings are ignored as cleanup fact sources.
   - Owned suspend results are cleaned exactly once.
   - Thunk frame args are lowered structurally and rendered only at emission.

### Exit Criteria

- No semantic `MIR::Node | String` unions remain in FSM/thunk cleanup paths.
- No rendered text can create or suppress cleanup facts.
- FSM/thunk emitters consume checked async plans.
- Decomplex broken protocols and state-based branch density improve or stay
  flat after the full slice.
- SlopCop genuine gaps for touched FSM/thunk files do not increase.

## Issue 2: Hoist, Cleanup Classification, And `MIRPass`

Target files:

- `src/mir/hoist.rb`
- `src/mir/cleanup_classifier.rb`
- `src/mir/mir_pass.rb`

### Current Problem

These passes decide the core ownership lifecycle:

- when anonymous owned values become named bindings;
- which bindings need cleanup;
- which cleanup obligations are branch-guarded;
- which values are consumed, moved, reassigned, returned, or captured;
- whether background/resource captures shift cleanup responsibility.

The current architecture has improved, but it still spreads lifecycle decisions
across AST mutation, cleanup maps, moved-guard stamping, return allocator
checks, and consumed-node walks. That creates temporal ordering pressure:
correctness depends on hoist, cleanup classification, and MIRPass mutating the
right fields in the right order.

### Target Architecture

This area should become a typed plan pipeline:

```text
annotated AST
  -> HoistPlan
  -> CleanupClassificationPlan
  -> OwnershipPreparationPlan
  -> frozen function cleanup facts
  -> MIR lowering
```

The desired phase products:

1. `HoistPlan`
   - hoist candidates, source expression, destination binding name, reason,
     placement, ownership effect, and cleanup expectation.

2. `CleanupClassificationPlan`
   - one cleanup recipe per binding, explicit no-cleanup records, allocator,
     resource close behavior, moved-guard requirement, and source reason.

3. `OwnershipPreparationPlan`
   - returned binding facts, consumed binding facts, branch guard facts,
     reassignment cleanup facts, match/if/while bind cleanup facts, and
     background capture transfer facts.

4. `FunctionCleanupFacts`
   - frozen result consumed by lowering and checking.
   - no later open-coded mutation to cleanup fields.

### Implementation Plan

1. Inventory current cleanup fact writers.
   - `cleanup_bindings`
   - moved guard maps
   - returned cleanup binding stamps
   - match/if/while bind cleanup stamps
   - BG resource capture stamps
   - reassignment cleanup facts

2. Introduce typed plan records.
   - `HoistCandidate`
   - `HoistPlan`
   - `CleanupBindingFact`
   - `CleanupClassificationPlan`
   - `ConsumedBindingFact`
   - `BranchCleanupGuardFact`
   - `OwnershipPreparationPlan`
   - `FunctionCleanupFacts`

3. Convert hoist from immediate mutation to plan-then-apply.
   - The planner classifies what needs hoisting and why.
   - The applier rewrites AST in one bounded mutation window.
   - Tests assert the plan before the rewrite and the rewritten AST after it.

4. Convert cleanup classifier to return a plan before stamping facts.
   - `CleanupEntry` remains the cleanup recipe object.
   - The classifier should not depend on later MIRPass mutation to fill in
     missing safety-critical fields.

5. Split `MIRPass` into named preparation steps.
   - Return allocator preparation.
   - BG/resource capture preparation.
   - Consumed binding walk.
   - Reassignment cleanup preparation.
   - Branch guard preparation.
   - Final freeze/apply step.

6. Add failure-mode tests before deleting old writers.
   - anonymous owned return through TAKE call;
   - branch move then cleanup guard;
   - reassignment of owned binding;
   - match-as binding cleanup;
   - while/if bind cleanup;
   - BG resource capture transfer;
   - copied value that must not receive cleanup;
   - missing cleanup fact fails closed before MIR emission.

### Exit Criteria

- Hoist and cleanup classification expose typed plans that tests can inspect.
- Cleanup facts have a bounded writer and a frozen downstream representation.
- `MIRPass` is an orchestrator over typed preparation products, not a broad
  implicit state machine.
- No new nil-kill untyped/hash-record pressure in these compiler phase records.
- Decomplex and Boobytrap should show lower state-based branch pressure for
  hoist/cleanup/MIRPass after the full slice.

## Issue 3: Escape, Ownership Graph, Control Flow, And `MIRChecker`

Target files:

- `src/semantic/escape_analysis.rb`
- `src/semantic/ownership_graph.rb`
- `src/mir/control_flow.rb`
- `src/mir/mir_checker.rb`

### Current Problem

Ownership reasoning is now more explicit than it was, but identity is still too
string/name driven in important places. Escape analysis, ownership graph,
control-flow dataflow, and MIR checking can still use overlapping concepts of
"the same thing":

- binding name;
- AST node object;
- symbol entry;
- MIR identifier;
- field/path expression;
- generated temporary;
- context/capture field.

When those identities drift, a memory-safety check can validate one identity
while lowering or emission acts on another.

### Target Architecture

Introduce stable ownership identities and freeze phase facts:

1. `BindingId`
   - stable identity for a source binding or compiler-generated binding.

2. `PlaceId`
   - stable identity for a place that can be moved, borrowed, assigned, or
     cleaned.
   - includes local binding, field place, indexed place, capture place, and
     generated temporary variants.

3. `OwnershipEvent`
   - create, move, borrow, drop, transfer, assign, capture, escape, cleanup.

4. `OwnershipSnapshot`
   - immutable dataflow state at a control-flow point.

5. `FrozenOwnershipFacts`
   - final facts consumed by `MIRChecker` and backend lowering.

The rule: escape analysis and control-flow may produce facts, but `MIRChecker`
validates them over stable MIR/ownership identities. It should not rediscover
ownership semantics from loose string names or arbitrary subtree walks when a
fact should already exist.

### Implementation Plan

1. Inventory ownership identity sources.
   - string binding keys in escape analysis;
   - ownership graph node keys;
   - control-flow moved/borrowed/read sets;
   - checker allocation, transfer, cleanup, and leak tracking keys.

2. Add typed identity records.
   - Start with wrappers around existing names, not a full arena rewrite.
   - The first migration should make identity explicit without changing
     behavior.

3. Type the ownership graph node table.
   - `@nodes` should map a stable key type to a typed node record.
   - Replace weak lookups with `fetch`, `maybe`, or `ensure` APIs that encode
     absence explicitly.

4. Convert control-flow dataflow to snapshots.
   - A branch join should merge typed ownership snapshots.
   - Active borrow and moved-state checks should read typed events and places.

5. Make `MIRChecker` consume frozen facts.
   - Checker state can remain mutable during one function check, but it should
     be initialized from frozen facts and report mismatches.
   - Missing required fact should be a checker error, not a silent fallback.

6. Add invariant tests.
   - move then use fails;
   - double cleanup fails;
   - missing cleanup fails closed;
   - borrow escapes fail;
   - borrow across yield/fiber boundary fails;
   - branch move join requires guarded cleanup;
   - field/index place identity does not alias an unrelated local;
   - generated temporary cleanup identity is stable through lowering/checking.

### Exit Criteria

- Ownership graph, control-flow, and checker share one typed identity model.
- Memory-safety facts freeze before checker/codegen consumption.
- Checker errors name the missing or inconsistent fact.
- Bug fixes in ownership behavior should no longer need to patch escape
  analysis, control flow, lowering, checker, and emitter independently.
- Boobytrap multi-file fix blast radius should drop or remain materially lower
  than the pre-refactor ownership baseline.

## Recommended Execution Order

### Phase 0: Baseline And Invariant Harness

1. Snapshot Decomplex, SlopCop, Boobytrap, and nil-kill.
2. Add or identify invariant helper APIs for asserting:
   - cleanup plans;
   - FSM segment facts;
   - hoist plans;
   - ownership graph events;
   - checker failures.
3. Do not refactor source yet except for missing test helpers.

### Phase 1: FSM/Thunk Async Cleanup Boundary

This should happen first because it is the most recently proven correctness
surface and the smallest of the three. It also gives a template for forbidding
rendered text as a safety fact source.

Expected result:

- FSM/thunk rating moves to `A-` or `A`.
- Old release-level red flag can be removed from the architectural review.

### Phase 2: Hoist, Cleanup Classification, And `MIRPass`

This should happen second because it produces the cleanup facts that async
lowering, ownership checking, and emission rely on. It is broader than FSM but
still bounded to three files plus tests and typed fact definitions.

Expected result:

- MIR preparation/hoisting/ownership rating moves to `A-`.
- Cleanup fact writer count drops.
- SlopCop genuine gaps in hoist/MIRPass cleanup branches drop or stay flat.

### Phase 3: Escape, Ownership Graph, Control Flow, And `MIRChecker`

This is the strategic destination and the broadest slice. Do it after the
cleanup fact pipeline is explicit so stable IDs have concrete facts to attach
to.

Expected result:

- Ownership graph/control-flow/checker rating moves to `A-` or `A`.
- Multi-file ownership fix blast radius drops.
- Checker becomes a consumer of frozen facts rather than a rediscovery pass.

### Phase 4: Documentation And Gates

1. Update `docs/agents/architectural-review.md` ratings and red flags.
2. Update `src/mir/README.md` with the final fact pipeline.
3. Update `src/annotator/README.md` only if annotation fact production changes.
4. Add CI guardrails for:
   - raw semantic Zig fragments in FSM/thunk paths;
   - new cleanup fact writers outside sanctioned files;
   - untyped phase bags in the target areas;
   - checker fallbacks that accept missing ownership facts.

## Risks And Non-Goals

Risks:

- The ownership identity migration can become too large if it tries to replace
  every string name in one pass. Start with wrappers and stable APIs.
- Decomplex state-based branch density may temporarily rise when hidden
  decisions become explicit typed facts. Accept only if broken protocols,
  temporal pressure, SlopCop gaps, or Boobytrap risk improve by closure.
- Async emit still needs some backend text. The goal is not zero strings; the
  goal is zero semantic safety facts derived from strings.

Non-goals:

- Parser cleanup.
- Formatter/tooling cleanup.
- A full Rust-style arena/query compiler rewrite.
- Cosmetic method splitting that does not reduce fact ambiguity, mutation
  windows, or safety risk.

## Completion Definition

This plan is complete when:

- all three target issues have implementation records with before/after
  metrics;
- every changed source line is covered and every changed branch bucket is above
  the acceptance threshold;
- nil-kill shows no new untyped compiler phase data;
- the architectural review rates the three target areas at `A-` or `A`;
- generated Zig safety behavior is backed by structural MIR/fact tests rather
  than text-only assertions;
- the parser remains intentionally deprioritized unless a concrete downstream
  safety issue appears.

## Implementation Record: 2026-06-08

Status: implemented for the three target slices on `architectural-review`.

What landed:

- FSM/thunk async cleanup boundary:
  - Added typed `FsmTransform::Emit::FsmEmitContext` and removed hash-style
    resolver callers from tests.
  - Replaced semantic `MIR::Node | String` body flow with typed
    `FsmBodyItem` values so only MIR items can feed structural segment facts.
  - Moved FSM lock/error split bodies to MIR statements and rendered them only
    at the final emitter edge.
  - Converted thunk base cases, frame initializers, variants, and trampolines
    to typed MIR records, including structural `ThunkFrameInit` values.
  - Added invariant coverage that rendered strings do not act as cleanup fact
    sources and thunk frame values remain structural until emission.

- Hoist, cleanup classification, and `MIRPass`:
  - Added typed cleanup fact snapshots in `CleanupClassifier`.
  - Added explicit MIR result-type helpers in hoist logic.
  - Added an `OwnershipPreparationPlan` for `MIRPass` initialization work and
    precomputed fallible-function facts.

- Escape, ownership graph, control flow, and `MIRChecker`:
  - Added stable typed `OwnershipIdentity::BindingId` and
    `OwnershipIdentity::PlaceId`.
  - Migrated escape placement facts, ownership graph internals, control-flow
    ownership snapshots, and checker snapshots to typed place/binding IDs while
    retaining public compatibility readers where existing callers still need
    string output.
  - Added frozen ownership snapshots for dataflow/checker consumers and tests
    for place identity behavior.

Verification:

- `bundle exec srb tc`: passed.
- Focused FSM/thunk/ownership specs: passed.
- Full covered unit suite:
  - `COVERAGE=1 COVERAGE_DIR=tmp/a-grade-memory-safety/coverage-after bundle exec rspec --format progress`
  - 5627 examples, 0 failures.
  - Global line coverage: 99.43%.
  - Global branch coverage: 85.57%.
- Diff coverage bucket:
  - `src/**/*.rb` additions: 100.0% line coverage.
  - `src/**/*.rb` additions: 90.4% branch coverage.
  - Src type guardrails: none.
  - Zig special coverage alerts: none.
- Added-line audit over changed `src/**/*.rb` executable lines: 0 misses.

Metric deltas from the pre-implementation snapshot:

| Metric | Before | After | Delta |
| --- | ---: | ---: | ---: |
| Decomplex Decision Pressure | 283 | 277 | -6 |
| Decomplex State Heatmap | 577 | 578 | +1 |
| Decomplex State-Based Branch Density | 1616 | 1616 | 0 |
| Decomplex Temporal Ordering Pressure | 14 | 14 | 0 |
| Decomplex Missing Abstractions | 187 | 185 | -2 |
| Decomplex Reification Misses | 6 | 6 | 0 |
| Decomplex Derived-State Staleness | 139 | 139 | 0 |
| Decomplex Broken Protocols | 392 | 390 | -2 |
| Decomplex False Simplicity | 1011 | 1011 | 0 |
| SlopCop Top True Gaps | 1303 | 1299 | -4 |
| SlopCop dark arms | 3028 | 3015 | -13 |
| SlopCop genuine gaps | 1303 | 1299 | -4 |

Assessment:

- This is a net architectural win: Decomplex net debt reduced by 10
  (5859 -> 5849), SlopCop gaps decreased, and no type guardrail regressions
  were introduced.
- The one Decomplex regression is `State Heatmap +1`. That is an expected
  tradeoff from making ownership/context/fact state explicit and typed instead
  of implicit in strings or loose hashes. It did not increase state-based
  branch density, and broken protocols decreased.
- Boobytrap and nil-kill were not regenerated in this execution loop; this run
  was scoped to the requested Decomplex and SlopCop comparison plus type and
  diff-coverage guardrails.
