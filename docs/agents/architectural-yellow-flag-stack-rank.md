# Architectural Yellow Flag Stack Rank

Branch context: `architectural-review`.

Status: #4 and #3 implemented for this branch; #1, #2, and #6 remain
stack-ranked future work.

Owner: Codex.

Date: 2026-06-09.

## Purpose

This document expands the remaining yellow flags from
`docs/agents/architectural-review.md` into implementation-sized architectural
tracks. The goal is to decide what should be attacked next based on expected
correctness impact, latent bug discovery, fuzz-testability, complexity
reduction, and implementation effort.

This intentionally excludes parser cleanup. Parser style issues may still be
real, but they have not been the source of the memory-safety and generated-code
correctness problems this review is prioritizing.

## Scoring Model

Scores are 1-5. Higher impact scores are better. Higher effort score means more
expensive.

| Dimension | Meaning |
| --- | --- |
| Architectural correctness | How much the work moves compiler phases toward explicit ownership, phase, and fact boundaries. |
| Latent bug discovery | How likely the work is to expose real hidden bugs or impossible states while being implemented. |
| Fuzz-testability | How much the work makes fuzzing exercise correctness directly instead of only final generated behavior. |
| Branch/complexity reduction | Expected reduction in state-based branches, temporal ordering pressure, broken protocols, and ad hoc guards. |
| Effort | Estimated implementation cost, test cost, migration surface, and unknowns. Higher means harder. |
| Confidence | How confident we are that the work can land as a net architectural win without a large sideways move. |

The rough priority score is:

```text
(correctness + latent_bugs + fuzz_testability + complexity + confidence) - effort
```

This is not a substitute for engineering judgement. It is a way to make the
tradeoffs explicit before committing to a large refactor.

## Recommended Stack Rank

| Rank | Yellow flag | Correctness | Latent bugs | Fuzzability | Complexity | Effort | Confidence | Priority score | Recommendation |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 1 | #4 Hoist, cleanup classification, and `MIRPass` | 5 | 5 | 5 | 4 | 3 | 4 | 20 | Best next target: direct memory-safety payoff with bounded files and clear invariants. |
| 2 | #3 MIR ownership/control-flow stable facts | 5 | 4 | 5 | 4 | 4 | 4 | 18 | High payoff; should follow or overlap carefully with #4 because #4 consumes these facts. |
| 3 | #1 Typed std-lib/intrinsic emitter contracts | 4 | 4 | 4 | 3 | 4 | 4 | 15 | Important boundary cleanup; broad but source-of-truth is clear. |
| 4 | #2 Annotation shared phase state | 4 | 3 | 4 | 5 | 5 | 3 | 14 | Large architectural cleanup with real upside, but highest risk of broad churn. |
| 5 | #6 FSM/thunk splitter and liveness records | 3 | 3 | 4 | 3 | 3 | 4 | 14 | Useful follow-up, but the release-level cleanup risk is already closed. |

Recommended near-term order:

1. Do #4 first.
2. Extend into #3 where #4 reveals string-name or mutable fact compatibility
   readers.
3. Do #1 once ownership/cleanup fact consumers are stable enough to enforce
   stricter registry contracts.
4. Do #6 opportunistically when touching FSM/thunk async work.
5. Do #2 as a larger branch when we are ready for wider annotator churn, unless
   a concrete bug points there first.

## #4: Hoist, Cleanup Classification, And `MIRPass`

Current yellow flag:

> Hoist, cleanup classification, and `MIRPass` remain high-correctness
> surfaces. They now use more explicit facts, but regressions there still map
> directly to leaks, double cleanup, stale move guards, or missed ownership
> transfer checks.

Target files:

- `src/mir/hoist.rb`
- `src/mir/cleanup_classifier.rb`
- `src/mir/mir_pass.rb`
- likely consumers in `src/mir/mir_lowering.rb`, `src/mir/control_flow.rb`, and
  selected `src/mir/lowering/*` modules

### Why This Matters

This is the most direct remaining memory-safety yellow flag. These passes
decide:

- when an anonymous owned expression must become a named binding;
- which binding owns cleanup;
- whether cleanup is guarded by a move flag;
- whether branch-local ownership obligations survive into the merged function
  body;
- whether background/fiber/resource captures transfer or retain cleanup
  responsibility;
- whether return/consume/reassign flows suppress or preserve cleanup.

If this area is wrong, the compiler can emit code that leaks, double-frees,
uses stale move guards, or incorrectly assumes a value is still owned after a
transfer. That is exactly the class of bugs this architectural cleanup is meant
to prevent.

### Correct Target Architecture

Move this area toward a typed plan pipeline:

```text
annotated AST/MIR inputs
  -> HoistPlan
  -> CleanupClassificationPlan
  -> OwnershipPreparationPlan
  -> FrozenCleanupFacts
  -> lowering/emission
```

Important records:

- `HoistCandidate`
  - source expression;
  - destination binding;
  - ownership effect;
  - allocator;
  - cleanup expectation;
  - reason/source location.
- `CleanupClassification`
  - binding identity;
  - cleanup recipe or explicit no-cleanup reason;
  - allocator;
  - moved-guard requirement;
  - branch condition if guarded;
  - source phase.
- `OwnershipPreparationPlan`
  - return-owned facts;
  - consumed binding facts;
  - reassignment cleanup facts;
  - BG/FSM/thunk capture transfer facts;
  - branch merge facts.
- `FrozenCleanupFacts`
  - immutable output consumed by lowering/checking;
  - keyed by stable binding/place identity where available;
  - no consumers reading mutable pass internals.

The core rule: cleanup obligations should have exactly one writer and should be
read as frozen facts after classification. Later phases may render or validate
them, but should not rediscover them from AST shape or local guard heuristics.

### Latent Bugs This Should Surface

- Cleanup emitted for a binding that has already transferred ownership.
- Missing cleanup after anonymous owned values are hoisted.
- Move guard written by one pass and read under a different binding name.
- Branch cleanup decisions that disappear after `if`/`match`/loop merging.
- BG/FSM capture cleanup handled both by the caller and the async boundary.
- Reassignment cleanup that depends on pass ordering instead of an explicit
  fact.
- Error-path cleanup that works only because of incidental statement order.

### Fuzz-Testability Impact

Very high. Fuzzing can become more direct because the expected facts can be
checked before Zig emission:

- every owned allocation has exactly one cleanup or transfer fact;
- every moved binding has a matching guard or explicit no-cleanup reason;
- branch merges preserve cleanup obligations;
- return-owned values suppress local cleanup only through a typed return fact;
- BG/FSM/thunk capture transfers have a single cleanup owner.

This gives fuzzing structural invariants to assert even when generated Zig
happens to compile and run.

### Complexity Impact

Expected wins:

- lower broken protocols from explicit lifecycle products;
- lower temporal ordering pressure from replacing pass-order assumptions with
  named plan/fact handoffs;
- lower state-based branch density in `hoist.rb`, `cleanup_classifier.rb`, and
  `mir_pass.rb` after branch decisions move into closed records;
- fewer SlopCop genuine gaps because each plan variant can get focused tests.

Some metrics may temporarily rise while plan records are introduced. The work is
not done until obsolete conditionals and compatibility readers are deleted.

### Effort

Medium. The file set is bounded and the correctness invariants are clear, but
the blast radius is real because lowering and checking consume these facts.

Estimated size:

- 3-5 implementation slices;
- substantial focused specs;
- full unit, fuzz, and coverage verification at the end;
- nil-kill recollect only after the final slice unless guardrails move.

### Recommended First Slice

Start with `CleanupClassificationPlan` and `FrozenCleanupFacts`.

Acceptance for slice 1:

- classifier returns a typed plan instead of exposing mutable intermediate
  hashes;
- `MIRPass` consumes the plan, not classifier internals;
- tests cover cleanup, no-cleanup, moved-guard, branch-guard, return-owned, and
  capture-transfer cases;
- no new untyped slots;
- Decomplex broken protocols and temporal pressure flat or down.

### Implementation Plan For This Branch

Status: implemented.

Baseline snapshot directory: `tmp/yellow-flag-34`.

Baseline metrics:

| Metric | Before |
| --- | ---: |
| Decomplex broken protocols | 393 |
| Decomplex temporal ordering pressure | 14 |
| Decomplex state heatmap | 569 |
| Decomplex state-based branch density | 1609 |
| SlopCop dark arms | 3015 |
| SlopCop genuine gaps | 1296 |
| Boobytrap hotspots | 95 |
| Boobytrap state-based branch hotspots | 1609 |

Final metrics after implementing #4 and #3:

| Metric | Before | After | Delta |
| --- | ---: | ---: | ---: |
| Decomplex cross-detector convergence | 1770 | 1765 | -5 |
| Decomplex root-cause clusters | 475 | 474 | -1 |
| Decomplex decision pressure | 276 | 275 | -1 |
| Decomplex state heatmap | 569 | 569 | 0 |
| Decomplex state-based branch density | 1609 | 1609 | 0 |
| Decomplex temporal ordering pressure | 14 | 14 | 0 |
| Decomplex missing abstractions | 193 | 190 | -3 |
| Decomplex neglected conditions | 10 | 8 | -2 |
| Decomplex neglected path conditions | 1422 | 1414 | -8 |
| Decomplex broken protocols | 393 | 389 | -4 |
| Decomplex false simplicity | 1004 | 1006 | +2 |
| Decomplex fat unions | 11 | 10 | -1 |
| SlopCop dark arms | 3015 | 2764 | -251 |
| SlopCop genuine gaps | 1296 | 1132 | -164 |
| Boobytrap mostly uncovered methods | 5 | 2 | -3 |
| Boobytrap top hotspot score | 0.1901 | 0.1559 | -0.0342 |

Outcome:

- #4 now has a typed `CleanupClassificationPlan`, immutable
  `FrozenCleanupFacts`, a typed `OwnershipPreparationPlan` handoff, typed
  hoist counter state, and node-aware cleanup fact lookup.
- #3 now uses `PlaceId` as the mutable dataflow state key, exposes typed
  ownership snapshots and cleanup summaries, and keeps string output as a
  diagnostic/presentation adapter.
- Compatibility readers remain only where existing public/spec/reporting
  consumers still need string labels; correctness-significant ownership,
  cleanup, and transfer logic is now keyed by typed place identity.
- Coverage for the working-tree Ruby diff is 100.0% changed executable lines
  and 80.1% changed branches.

#### Slice 4A: Freeze Cleanup Classification

Replace the mutable classifier output as the phase product:

```text
CleanupClassifier.classify_plan(fn)
  -> CleanupClassificationPlan
  -> FrozenCleanupFacts
  -> MIRPass::OwnershipPreparationPlan
```

Concrete work:

- introduce `CleanupClassificationPlan`;
- introduce `FrozenCleanupFacts`;
- make `MIRPass` store and consume plans instead of directly reading
  classifier-produced mutable hashes;
- keep string-keyed `cleanup_bindings` only as a presentation/legacy reader for
  existing AST/lowering consumers while the plan is the authoritative product;
- update tests to assert the frozen `PlaceId` view, name compatibility view,
  and moved-guard mutation behavior.

Expected metric movement:

- broken protocols down or flat because the classifier now has an explicit
  produced/consumed lifecycle;
- temporal ordering pressure down or flat because `MIRPass` no longer depends
  on the incidental shape of `@cleanup_bindings`;
- state-based branch density likely flat in this slice because the decisions
  still exist, but they are localized behind a typed fact object.

#### Slice 4B: Replace Hoist Primitive State With Typed Plans

The top SlopCop gap source is `Hoist.collect_stmt_hoists!`, and the pass still
threads a primitive counter array plus untyped hoist arrays through the
candidate discovery path.

Concrete work:

- replace `ctr = [0]` with a typed `HoistCounter`;
- replace untyped hoist arrays in AST hoisting with typed `T::Array[AST::VarDecl]`;
- introduce a small `HoistRequest`/`HoistedBinding` record only if it removes
  real branching from `collect_stmt_hoists!`;
- keep all hoist decisions in the existing Hoist path; do not add a second
  hoist implementation;
- add focused tests for call-argument, return, yield, field-store, collection
  value-store, concat, and non-body expression traversal paths.

Expected metric movement:

- SlopCop genuine gaps down because uncovered dark arms in `hoist.rb` get
  targeted tests;
- Decomplex state heatmap down or flat because the mutable primitive counter is
  removed;
- branch density may only improve after the collector is split into named,
  typed helpers.

#### Slice 4C: Make Ownership Preparation A Real Phase Handoff

`OwnershipPreparationPlan` should be the only input to MIRPass cleanup mutation.
It should carry:

- the function;
- frozen cleanup facts;
- can-fail function facts;
- the mutable binding view used for intentional AST stamping;
- explicit helpers for BG-inner filtering and live cleanup lookup.

Concrete work:

- move lookup/filtering helpers onto the plan/fact view where possible;
- update `WalkCtx` to carry the fact view rather than a raw mutable hash when
  no mutation is needed;
- keep mutation of `CleanupEntry` guarded and localized to the pass steps that
  intentionally refine cleanup guards.

Expected metric movement:

- temporal ordering pressure down;
- broken protocols down;
- state-based branch density down in `mir_pass.rb` if the branch context and
  live-entry helpers replace repeated nil/hash guards.

## #3: MIR Ownership / Control-Flow Stable Facts

Current yellow flag:

> MIR ownership/control-flow facts are much better centralized, but a few
> compatibility readers still expose string-name identity. Continue moving
> callers to stable typed binding/place IDs and frozen fact snapshots.

Target files:

- `src/semantic/ownership_identity.rb`
- `src/semantic/ownership_graph.rb`
- `src/semantic/escape_analysis.rb`
- `src/mir/control_flow.rb`
- `src/mir/mir_checker.rb`
- selected consumers in `src/mir/lowering/*`

### Why This Matters

String names are not stable ownership identity. A binding can be renamed,
shadowed, hoisted, moved into a generated context, or represented through a
field/place path. If ownership/control-flow uses strings as the final identity,
then facts can accidentally attach to the wrong place or fail to attach at all.

The recent work added stable typed IDs. The remaining risk is compatibility
surfaces that still translate back to string names too early.

### Correct Target Architecture

Ownership and control-flow should converge on these products:

- `BindingId`
  - stable source binding identity;
  - survives rename/hoist when the semantic binding is the same;
  - distinct for shadowed same-name bindings.
- `PlaceId`
  - stable identity for paths such as binding fields, context fields, and
    generated slots;
  - comparable without reparsing string paths.
- `FrozenOwnershipSnapshot`
  - immutable state at control-flow boundaries;
  - keyed by `PlaceId`, not string names.
- `FrozenEscapeFacts`
  - function escape/capture/placement facts keyed by stable IDs;
  - consumed by MIR lowering and checker.
- `OwnershipFactView`
  - narrow compatibility API for diagnostics and legacy callers;
  - string output is presentation only, not fact identity.

The core rule: strings may be diagnostic labels, but not the source of truth for
move, borrow, escape, cleanup, or capture facts.

### Latent Bugs This Should Surface

- Shadowed variables sharing move/borrow state.
- Hoisted temporary cleanup applied to a display name rather than the actual
  binding.
- Capture facts lost when a binding moves into an FSM/thunk context field.
- Borrow state merged incorrectly across branches because two names look equal
  or one generated name changes.
- Diagnostics appearing correct while checker facts refer to stale names.

### Fuzz-Testability Impact

Very high. Stable IDs make structural fuzz assertions possible:

- every generated binding has a unique identity;
- shadowed same-name bindings do not share ownership state;
- branch snapshots merge by identity;
- capture/escape facts point at the same identity consumed by lowering;
- checker errors can include labels without using labels as identity.

This makes fuzzing more effective because generated programs can deliberately
stress shadowing, hoisting, captures, branch merges, and context promotion.

### Complexity Impact

Expected wins:

- fewer predicate aliases around "name", "path", "var", and "binding";
- lower broken protocols where callers currently convert between string forms;
- lower derived-state staleness from presentation labels diverging from facts;
- improved test locality because fact snapshots are frozen values.

Potential temporary loss:

- short-term additional adapter code while deleting compatibility readers.
  This work should not be considered complete until the adapters shrink.

### Effort

Medium-high. The conceptual model is already in place, but the consumer surface
is broad. This should not be started as a global rename. It should be driven by
fact consumers where string identity still creates correctness risk.

Estimated size:

- 4-6 slices;
- strong focused coverage around shadowing/hoisting/capture/branch cases;
- likely downstream updates in checker diagnostics and lowering inputs.

### Recommended First Slice

Inventory all remaining string-name ownership fact readers and classify them:

- diagnostic-only;
- compatibility-only;
- correctness-significant.

Then convert one correctness-significant path at a time. Best first target:
control-flow ownership snapshots consumed by cleanup/checker code.

### Implementation Plan For This Branch

Status: implemented with #4.

#### Slice 3A: Type The Dataflow Step And Place State

The dataflow already exposes `PlaceId` snapshots, but the core block state is
still `Hash[String, OwnerEntry]`. That makes the typed snapshot a derived view
instead of the source of truth.

Concrete work:

- introduce `OwnershipState` as the mutable dataflow map keyed by `PlaceId`;
- replace `DataflowStep = Struct.new(:state, :consumed)` with a typed
  `DataflowStep < T::Struct`;
- make transfer/collection helpers consume and produce `PlaceId` internally;
- leave string labels only at diagnostics and compatibility readers.

Expected metric movement:

- broken protocols down because block state and snapshot state share one
  lifecycle;
- derived-state staleness down because snapshots no longer re-key from strings;
- state heatmap down or flat.

#### Slice 3B: Convert Cleanup Decisions To Place Facts

Cleanup decisions are correctness-significant: they decide whether local cleanup
is omitted, guarded, or unconditional.

Concrete work:

- compute cleanup summaries keyed by `PlaceId`;
- make `block_exit_cleanup_summaries` aggregate `PlaceId` entries;
- preserve `cleanup_summary` string output as a presentation adapter for specs
  and old consumers;
- update cleanup decision tests around shadowing, hoists, moved fields, and
  branch merges.

Expected metric movement:

- state-based branch density down in cleanup decision code;
- broken protocols down because cleanup decisions consume the same identity as
  ownership state;
- Boobytrap state-based branch hotspots down or flat for
  `OwnershipDataflow#cleanup_decisions!`.

#### Slice 3C: Remove Correctness-Significant String Readers

After dataflow and cleanup decisions are PlaceId-backed, string readers should
remain only for diagnostics and external presentation.

Concrete work:

- inventory remaining `OwnershipDataflow`/`OwnershipSnapshot` string readers;
- delete or downgrade correctness-significant string readers;
- add tests proving shadowed same-name declarations do not share place facts
  when binding IDs are available;
- update MIR checker call sites that can consume snapshots/facts directly.

Expected metric movement:

- predicate aliases around `name`/`path`/`var` down;
- derived-state staleness down;
- broken protocols down;
- no increase in untyped slots.

## #1: Typed Std-Lib / Intrinsic Emitter Contracts

Current yellow flag:

> `src/ast/std_lib.rb` and the intrinsic registry still mix backend Zig
> emission patterns with callable, ownership, allocation, and fallibility
> metadata. The current path is contract-backed and no longer travels through
> opaque MIR text carriers, but the next architectural step is typed
> emitter-owned emit specs and typed std-lib records.

Target files:

- `src/ast/std_lib.rb`
- `src/annotator/helpers/intrinsic_registry.rb`
- `src/annotator/helpers/intrinsic_emit.rb`
- `src/annotator/helpers/function_signature.rb`
- `src/mir/lowering/functions.rb`
- `src/mir/lowering/expressions.rb`
- `src/mir/lowering/variables.rb`
- `src/mir/mir_emitter.rb`

### Why This Matters

The codebase no longer has production `RawZig`, `InlineZig`, `ZigTemplate`, or
`FsmOps::ZigLit` paths under `src`. That is a major win. The remaining risk is
more subtle: std-lib and intrinsic tables can still mix semantic contract data
with backend emit patterns in broad records.

If those records are wrong or incomplete, a call can look type-safe and
checker-visible while still carrying an incorrect allocation, fallibility,
cleanup, or ownership contract.

### Correct Target Architecture

Create typed registry records with closed emit specs:

```text
IntrinsicDefinition
  -> CallableSignature
  -> OwnershipContract
  -> AllocationContract
  -> EffectContract
  -> EmitSpec
```

Suggested closed emit spec union:

- `RuntimeCallSpec`
  - runtime function/module name;
  - typed argument placeholders;
  - fallibility;
  - ownership neutrality or explicit ownership effect.
- `PureExpressionSpec`
  - emitter-owned expression pattern;
  - typed placeholders;
  - rejects allocator/cleanup/concurrency tokens.
- `StructuralLoweringSpec`
  - directs lowering to a MIR node or lowerer method;
  - no template text crosses into MIR.
- `ResourceCleanupSpec`
  - typed cleanup action;
  - allocator requirement;
  - receiver/value ownership expectation.
- `UnsupportedBackendSpec`
  - explicit backend rejection reason.

The source table should stop being a broad hash of mixed concerns. Builders may
exist to keep declaration syntax concise, but all consumers should receive
typed records.

### Latent Bugs This Should Surface

- Intrinsics marked ownership-neutral that actually allocate, retain, release,
  cleanup, or transfer.
- Fallible runtime calls missing fallibility metadata.
- Resource cleanup entries with incorrect allocator assumptions.
- Backend emit patterns using placeholders with the wrong type or arity.
- Static/method call records that disagree between annotation and MIR lowering.

### Fuzz-Testability Impact

High. Typed contract records allow fuzzers to assert registry invariants before
program generation:

- every intrinsic has a complete typed signature;
- every allocation-producing intrinsic has an allocation contract;
- every cleanup-capable type has exactly one cleanup action;
- every fallible emit spec has a fallibility contract;
- pure expression specs contain no forbidden lifetime/concurrency tokens.

Fuzzing can also generate calls from the registry and assert that annotation,
MIR lowering, checker, and emitter agree on the same typed contract.

### Complexity Impact

Expected wins:

- fewer raw hash record candidates;
- fewer branch hubs around `FunctionSignature.unwrap` and registry coercion;
- fewer guard clauses that defend against missing metadata;
- cleaner separation between semantic facts and final emitter patterns.

This may not dramatically reduce total branches at first because typed records
add constructors and validation. The win is correctness and removal of loose
metadata, with branch reductions after consumers stop supporting old shapes.

### Effort

Medium-high. The source of truth is clear, but the table is broad and many
callers consume it. This is safer than annotation phase cleanup because the
work can be sliced by intrinsic category.

Estimated size:

- 4-7 slices;
- strong unit coverage for builder validation and major intrinsic categories;
- focused compiler/fuzz coverage for allocation/fallibility/cleanup intrinsics.

### Recommended First Slice

Define typed records and convert a small high-risk category first:

- allocation-producing intrinsics;
- resource cleanup records;
- indexed mutation records.

Do not start with a cosmetic full-table rewrite. The first slice should remove
real loose metadata from correctness-significant consumers.

## #2: Annotation Shared Phase State

Current yellow flag:

> Annotation still has more shared receiver state than ideal. The phase split is
> real, but `SemanticAnnotator`, capability validation, control-flow analysis,
> and pipe analysis still rely on broad mutable phase context.

Target files:

- `src/annotator/annotator.rb`
- `src/annotator/phases/*`
- `src/annotator/domains/control_flow.rb`
- `src/annotator/domains/execution_boundaries.rb`
- `src/annotator/helpers/capabilities.rb`
- `src/annotator/helpers/pipe_analysis.rb`
- `src/annotator/helpers/effects.rb`

### Why This Matters

The annotator is no longer an undifferentiated blob: phases and domain modules
exist, and prior cleanup moved a lot of state into typed records. The remaining
problem is that many phases still share one receiver and rely on ambient
instance variables being initialized and mutated in the correct order.

This is a correctness risk because annotation produces the facts that make MIR
lowering/checking possible. If phase state is stale or read before it is valid,
the compiler can accept a program under false assumptions.

### Correct Target Architecture

Keep `SemanticAnnotator` as the public entry point, but make it a coordinator:

```text
AnnotationInput
  -> BuiltinEnvironmentResult
  -> DeclarationIndex
  -> TypeRegistrationResult
  -> SignatureRegistrationResult
  -> BodyAnalysisResult
  -> WholeProgramSemanticFacts
  -> DeferredValidationResult
  -> AnnotationResult
```

Important boundaries:

- `AnnotationRunContext`
  - source/importer/options;
  - diagnostics;
  - immutable references to phase products.
- `FunctionRegistry`
  - function nodes;
  - synthetic functions;
  - body summaries;
  - lookup APIs.
- `ScopeContext`
  - block-scoped scope stack;
  - current function context;
  - loop/conditional/smooth depth.
- `CapabilityPhaseFacts`
  - held locks;
  - capability aliases;
  - lock order facts;
  - validation outcomes.
- `PipeAnalysisFacts`
  - pipeline access facts;
  - concurrent op facts;
  - stream/ownership expectations.

The core rule: a phase can have local mutable state while running, but published
phase products should be typed, narrow, and stable.

### Latent Bugs This Should Surface

- Deferred validations depending on facts that are not finalized yet.
- Capability checks reading stale held-lock or alias state.
- Pipeline analysis and execution-boundary annotation disagreeing about capture
  or ownership facts.
- Function body summaries missing synthetic functions or imported functions.
- Scope stack restoration bugs after diagnostics or early returns.
- Whole-program effects using partially registered signatures.

### Fuzz-Testability Impact

High, but indirect. Fuzzing becomes more useful when annotation can expose
phase products for invariant checks:

- every phase declares its input products;
- no phase reads a product before it exists;
- final annotation result can be checked without running MIR lowering;
- fuzzer-generated programs can assert annotation invariants for scopes,
  captures, effects, capabilities, and pipelines.

The downside is that this work may initially add phase objects without making
fuzzing better until enough phases publish explicit products.

### Complexity Impact

Potentially very high. This is the best candidate for reducing state heatmap
and state-based branch density across the annotator, especially around
control-flow and pipe analysis.

Expected wins:

- fewer annotator ivars;
- fewer temporal ordering protocols;
- fewer broad helper calls that use the entire annotator as ambient context;
- smaller phase APIs and easier focused tests.

Risk:

- high churn can temporarily increase branches and adapters;
- moving state into a generic bag would hide complexity rather than reduce it;
- a forced zero-ivar goal can make code worse if it causes parameter threading
  with no correctness boundary.

### Effort

High. This is a wide refactor with many consumers. It is worth doing, but the
unknowns are larger than #4/#3/#1.

Estimated size:

- 6-10 slices;
- meaningful risk of needing to pause and re-rank after early metrics;
- nil-kill recollect at the end because type slot movement is likely.

### Recommended First Slice

Choose the smallest phase boundary with high correctness value:

- `FunctionRegistry` if the goal is broad phase infrastructure;
- `CapabilityPhaseFacts` if the goal is immediate correctness pressure;
- `PipeAnalysisFacts` if the goal is fuzzing and pipeline correctness.

Avoid starting with a full `SemanticAnnotator` constructor rewrite. Start with
one phase product that deletes real receiver state.

## #6: FSM/Thunk Recursive Splitting And Liveness Records

Current yellow flag:

> FSM/thunk recursive splitting and liveness still have some loose walker shape.
> The critical cleanup/string relocation risk is closed, but follow-up work
> should keep moving splitter/liveness records toward typed segment-plan data.

Target files:

- `src/mir/fsm_transform/recursive_splitter.rb`
- `src/mir/fsm_transform/liveness.rb`
- `src/mir/fsm_transform/segments.rb`
- `src/mir/thunk_transform/recursive_splitter.rb`
- related consumers in `src/mir/fsm_transform/emit.rb` and
  `src/mir/thunk_transform/emit.rb`

### Why This Matters

The biggest FSM/thunk red flag is closed: cleanup and finalization are no longer
derived from rendered Zig strings. The remaining concern is lower priority but
still meaningful. Splitter and liveness code decide which values cross async
segment boundaries and which generated context fields must exist.

If this area is loose, it can misclassify values that should be promoted,
captured, restored, or considered live across a suspend/recursive boundary.

### Correct Target Architecture

Converge splitter and liveness on typed segment plans:

- `SegmentInput`
  - AST/MIR body;
  - function identity;
  - known capture facts;
  - known ownership facts.
- `SegmentPlan`
  - segment ID;
  - structural statements;
  - typed tail;
  - suspend kind;
  - required context fields;
  - outgoing liveness facts.
- `CrossSegmentLocal`
  - stable binding/place identity;
  - source name for diagnostics;
  - type;
  - ownership/copy/move expectation;
  - read/write segments.
- `ThunkSplitPlan`
  - base cases;
  - recursive calls;
  - frame fields;
  - trampoline variant facts.

The core rule: AST walking may discover candidates, but safety-significant
facts must be published as typed records before emission.

### Latent Bugs This Should Surface

- Local value used after suspend but not promoted into the FSM context.
- Value promoted unnecessarily, causing larger contexts and cleanup pressure.
- Context field written in one segment and read under a stale or generated name.
- Recursive thunk frame missing a field required after a trampoline step.
- Branch-specific liveness facts incorrectly merged into all segments.

### Fuzz-Testability Impact

Medium-high. Typed segment plans let fuzzing assert async invariants before
runtime execution:

- every cross-segment read has a declared context field;
- no dead local is promoted without a reason;
- every thunk frame read has a matching frame field;
- liveness facts are stable across branching and nested async shapes.

This is especially useful for generated BG/FSM/thunk programs that currently
need runtime behavior to reveal missing promotion.

### Complexity Impact

Moderate. The critical string cleanup complexity has already been removed, so
the remaining branch/complexity win is smaller than #4/#3/#2.

Expected wins:

- fewer loose walker returns;
- fewer untyped or hash-shaped liveness records;
- better localized tests for segment planning;
- less chance of future FSM/thunk work reintroducing text-shaped shortcuts.

### Effort

Medium. The file set is focused, and prior FSM/thunk work created good typed
boundaries. The main risk is touching subtle async test cases.

Estimated size:

- 3-5 slices;
- focused FSM/thunk specs plus fuzz shard coverage;
- no need for a full nil-kill recollect unless type guardrails move.

### Recommended First Slice

Convert liveness outputs into typed `CrossSegmentLocal` records consumed by the
splitter/emitter path. Then delete old loose record accessors.

This is a good follow-up when we are already working in FSM/thunk code, but it
is not the highest global priority.

## Final Recommendation

The best immediate target is #4 because it has the strongest combination of:

- direct memory-safety correctness impact;
- high latent bug discovery potential;
- better structural fuzz assertions;
- bounded files and known invariants;
- less broad churn than annotation phase cleanup.

#3 is the natural companion and should be pulled in when #4 hits string-name
ownership compatibility readers. #1 is important but should be framed as a
typed registry contract migration, not as another emitter-text cleanup. #2 is
probably the largest remaining complexity-reduction opportunity, but it should
wait until we are ready for a broad annotator branch. #6 is worthwhile and
focused, but its most dangerous predecessor issue has already been resolved.

## Measurement Plan For Any Chosen Track

Before implementation:

- snapshot Decomplex for full `src`;
- snapshot SlopCop;
- snapshot Boobytrap;
- collect nil-kill only if the chosen track is likely to move type slots
  materially;
- capture targeted inventories for untyped slots, hash records, primitive tuple
  arrays, and string-name compatibility readers.

After each slice:

- run focused specs;
- run `bundle exec srb tc`;
- run Decomplex full `src`;
- inspect guardrails via `tools/diff_bucket_summary.rb`;
- reassess if state-based branch density, broken protocols, or genuine gaps
  move materially in the wrong direction.

At completion:

- run full Ruby unit/integration gates;
- run relevant transpile/fuzz/coverage gates;
- regenerate Decomplex, SlopCop, Boobytrap, and nil-kill if the track touches
  type soundness;
- update `docs/agents/architectural-review.md` ratings and yellow flags.
