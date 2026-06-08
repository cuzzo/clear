# Architectural Upgrade Plan

Branch focus: `architectural-review`.

Status: design plan only.

Owner: Codex.

Date: 2026-06-08.

## Goal

Move the remaining major compiler systems from the current `B` / `B+` shape to
an `A-` or `A` shape in architecture, design, and implementation.

This plan treats the four upgrade areas independently:

1. Typed intrinsic, std-lib, and Zig-template contract data.
2. Annotator phase state and shared mutable receiver state.
3. MIR ownership/control-flow facts with frozen stable identities.
4. Emission boundaries that keep raw Zig fragments at final rendering edges.

Each track should be implementable as its own branch. The tracks reinforce each
other, but none should require an always-green dual-path migration. For each
track, delete or narrow the old source of truth first, drive focused tests red,
then rebuild the typed path until the suite is green.

## What `A-` / `A` Means Here

An `A-` implementation has:

- explicit typed phase inputs and outputs;
- one writer for every safety-critical fact;
- no semantic decisions recovered from rendered Zig or incidental syntax;
- no new `T.untyped` params, returns, fields, ivars, hash records, or untyped
  collections in compiler phase data;
- strong invariant tests at the fact/MIR boundary, not only generated-text
  tests;
- Decomplex, SlopCop, Boobytrap, and nil-kill metrics flat or improved after
  each completed slice.

An `A` implementation additionally has:

- frozen cross-phase fact stores;
- stable IDs instead of string-name identity in ownership/control-flow data;
- very small public phase APIs;
- no raw string carrier that can hide allocation, cleanup, borrowing, transfer,
  async lifetime, or concurrency semantics from `MIRChecker`.

## Current Raw Zig / Inline Zig Assessment

The current code does not appear to have production `RawZig` left under `src`.

Verification command:

```sh
rg -n "\bRawZig\b|MIR::RawZig|RawZig\.new" src --glob '*.rb' -S
```

Current result: no matches.

There are also no direct production `MIR::InlineZig.new` or `InlineZig.new`
constructor sites under `src`.

Verification command:

```sh
rg -n "MIR::InlineZig\.new|InlineZig\.new" src --glob '*.rb' -S
```

Current result: no direct production constructor sites.

However, that is not sufficient. The hard invariant for the compiler is:

> No phase before final emission may write, render, splice, or transport Zig
> source text as MIR.

There are no exceptions for registry-backed templates, async helpers, cleanup
helpers, or "small" expression fragments. If a construct has semantics before
emission, it must be represented as typed MIR nodes, typed facts, typed runtime
call specs, or typed cleanup actions. The emitter is the only subsystem allowed
to render Zig source.

`MIR::ZigTemplate` violated this invariant and must not exist. Replacing
`InlineZig` with `ZigTemplate` was not an architectural win; it moved the same
text carrier into a narrower wrapper. The correct replacement is structural MIR:

- registry calls lower to `MIR::RegistryCall`;
- indexed mutations lower to `MIR::IndexedStore` / map-specific structural
  nodes;
- extern trampolines lower to `MIR::ExternTrampoline`;
- observable consumer spawns lower to `MIR::ObservableConsumerSpawn`;
- cleanup behavior lowers to typed cleanup actions;
- async FSM/thunk behavior lowers to structural FSM/thunk plans consumed by the
  emitter.

The remaining risk surfaces to eliminate are:

- `MIR::InlineZig` legacy support and tests;
- lowerer calls to `emit_expr`, `emit_stmts_zig`, `task_config_zig`, and
  `fiber_spawn_call_zig`;
- `FsmTransform::Emit::FsmBodyItem.opaque_zig`, `FsmTransform::Segments::
  SyntheticZig`, `pre_body_zig`, and `extra_prologue_zig`;
- `resource_close_zig` / `close_zig` cleanup templates;
- std-lib registry records that still mix rendered Zig patterns with ownership
  and effect metadata.

## Track 1: Typed Intrinsic, Std-Lib, And Emitter-Only Contract Data

### Target Rating

- Architecture: `A-` after typed registries and template specs.
- Design: `A-` after emit templates are separated from ownership/effect
  contracts.
- Implementation: `A` only after pre-emission templates are gone and high-risk
  operations are structural MIR nodes or typed runtime bridge nodes.

### Current Problem

The std-lib and intrinsic layer has better contracts than before, but the
source of truth is still too string/hash-heavy:

- `STD_LIB`, `BUILTIN_OPS`, and index operation records carry Zig template
  strings plus semantic metadata in broad registry records.
- `FunctionSignature.unwrap` and coercion help, but consumers still need to
  trust that registry metadata is complete.
- `MIR::ZigTemplate` carried template text through MIR and is deleted.
- Resource cleanup still travels through `close_zig` / `resource_close_zig`
  templates.

The failure mode is not only that hidden template semantics can allocate,
cleanup, transfer, mutate, borrow, or encode concurrency behavior without a
typed fact that `MIRChecker` can verify. The broader failure mode is that any
pre-emission Zig text lets an earlier phase make emitter decisions and hide
structure from checker passes.

### Target Architecture

Create a typed registry model:

```text
IntrinsicDefinition
  -> CallableSignature
  -> OwnershipContract
  -> EffectSet
  -> AllocationContract
  -> EmitSpec
```

`EmitSpec` should be a closed union:

- `RuntimeCallSpec`
- `PureZigExprTemplateSpec`
- `StructuralMirLoweringSpec`
- `ResourceCleanupSpec`
- `UnsupportedBackendSpec`

Template strings should be data only in emitter-owned specs, and only when the
spec declares:

- typed placeholders;
- expression-only output;
- no hidden allocator/cleanup tokens;
- explicit fallibility;
- explicit ownership neutrality or a typed ownership contract.

Resource cleanup should move from string templates to a closed
`ResourceCleanupAction` union:

- `MethodClose(name)`
- `RuntimeClose(function_name)`
- `DeinitWithAllocator(allocator_kind)`
- `NoCleanup`

The emitter may render these actions, but no earlier phase should perform
`gsub`, interpolate a Zig string, or infer cleanup semantics from text.

### Implementation Plan

1. Add typed registry structs.
   - Introduce `IntrinsicDefinition`, `IntrinsicEmitSpec`,
     `PlaceholderSpec`, `AllocationContract`, and `ResourceCleanupAction`.
   - Keep the old registry shape only as input to a builder during the first
     slice; consumers should receive typed records.
   - Add constructor validation that rejects hidden allocator/cleanup tokens in
     pure expression templates.

2. Convert `FunctionSignature` and intrinsic lookup consumers.
   - Make all MIR/annotator consumers accept typed records instead of raw hash
     entries where possible.
   - Remove `T.untyped` or `Object` registry slots at call boundaries.
   - Add tests for signature coercion, ownership contracts, allocator metadata,
     fallibility, and method/static dispatch.

3. Delete pre-emission template carriers.
   - Remove `MIR::ZigTemplate` entirely.
   - Remove production `MIR::InlineZig` construction and then remove legacy
     `InlineZig` support once checker tests are structural.
   - Keep template lookup and substitution inside `MIREmitter` only.
   - A template lacking an audited emitter-side `EmitSpec` should fail at
     emission.

4. Structuralize high-risk remaining templates.
   - First targets:
     - observable consumer spawn scaffolds;
     - extern callback trampolines;
     - `WITH` binding preludes;
     - indexed assignment mutation templates;
     - resource cleanup templates.
   - Convert each to a dedicated MIR node or typed runtime bridge node when the
     template controls lifetime, cleanup, async transfer, or concurrency.

5. Add architecture invariants.
   - No production `RawZig`.
   - No direct production `InlineZig.new`.
   - No `MIR::ZigTemplate` constant or constructor.
   - No lowerer-owned `MIREmitter.new`, `emit_expr`, or `emit_stmts_zig`.
   - Pure expression templates must reject allocator/cleanup/concurrency tokens.
   - Resource cleanup must use `ResourceCleanupAction`, not string `gsub`.

### Exit Criteria

- No raw hash registry records cross into annotator, MIR lowering, checker, or
  emitter consumers.
- `ZigTemplate` is absent.
- `InlineZig` is absent from production MIR and then removed as a legacy class.
- Resource cleanup strings are replaced by typed cleanup actions.
- The checker can prove every ownership-affecting intrinsic/template operation
  from typed facts.

## Track 2: Annotation Shared Phase State

### Target Rating

- Architecture: `A-` when `SemanticAnnotator` is a coordinator over explicit
  phase inputs/results.
- Design: `A-` when shared receiver state is reduced to a small typed run
  context.
- Implementation: `A` when phase objects own their mutation windows and publish
  immutable facts.

### Current Problem

The annotator phases are conceptually present, and `src/annotator/README.md`
documents the intended flow. The remaining issue is that many phases still run
as mixins on one `SemanticAnnotator` receiver with broad shared state:

- `@scope_stack`
- `@function_context_stack`
- loop/conditional/smooth depth fields
- held lock and capability state
- deferred validation queues
- effect state
- ownership graph state
- current program/source/importer context

This creates implicit temporal coupling. A phase can read state that another
phase initialized by convention, and tests can validate final behavior while
missing a broken phase protocol.

### Target Architecture

Keep `SemanticAnnotator#annotate!` as the public API, but make it a thin
coordinator:

```text
AnnotationInput
  -> BuiltinEnvironmentPhase
  -> DeclarationIndexPhase
  -> TypeRegistrationPhase
  -> SignatureRegistrationPhase
  -> BodyAnalysisPhase
  -> AutoFinalizationPhase
  -> WholeProgramSemanticsPhase
  -> DeferredValidationPhase
  -> AnnotationResult
```

Each phase receives typed inputs and returns typed outputs. Mutable state is
allowed inside a phase while it runs, but cross-phase products should be typed
and stable.

Introduce these state/result surfaces:

- `AnnotationRunContext`: importer, source dir, source code, strict-test mode,
  diagnostics context.
- `ScopeContext`: typed stack with block-scoped push/pop.
- `FunctionAnalysisContext`: current function stack, return facts, loop/smooth
  depth, branch status.
- `CapabilityPhaseState`: held locks, capability audit, predicate context,
  deferred capability validations.
- `OwnershipPhaseState`: ownership graph, scope depth, move/borrow facts.
- `AnnotationFacts`: final immutable object consumed by MIR-facing code.

The zero-ivar goal remains directional. The practical A-tier goal is not "no
fields anywhere"; it is "no unrelated phase can mutate another phase's state by
accident."

### Implementation Plan

1. Add `AnnotationInput`, `AnnotationRunContext`, and `AnnotationResult`.
   - `SemanticAnnotator#annotate!` should construct input/context and return or
     attach a typed result.
   - Existing callers can keep receiving the annotated AST.

2. Extract scope and function context stacks.
   - Replace open-coded push/pop with typed block APIs.
   - Add restoration tests for normal exit and exception/diagnostic paths.
   - Remove `T::Array[T.untyped]` from the scope stack.

3. Extract capability/deferred validation state.
   - Move held-lock maps, predicate call sites, audit store, and deferred WITH
     validations behind a typed state object.
   - Add tests proving state cannot leak across functions, branches, and nested
     `WITH` blocks.

4. Extract ownership graph state.
   - Give ownership graph operations typed entry points through
     `OwnershipPhaseState`.
   - Remove open-coded receiver writes where possible.
   - Preserve the existing `OwnershipGraph` implementation until Track 3
     freezes downstream IDs.

5. Convert post-body phases to explicit phase objects.
   - Auto finalization, whole-program semantics, deferred validation, and
     program finalization should each receive typed phase inputs.
   - Shared data should be read from `AnnotationResult` / `AnnotationFacts`, not
     from broad receiver fields.

6. Add phase-order invariants.
   - A phase cannot read facts before its prerequisite result exists.
   - A phase cannot mutate a result published by an earlier phase.
   - MIR boundary checks consume `AnnotationFacts`, not ambient annotator state.

### Exit Criteria

- `SemanticAnnotator` retains only public configuration plus a typed run
  context while a run is active.
- Scope/function/capability/ownership state mutations are behind named APIs.
- Whole-program phases consume typed results, not implicit receiver fields.
- State heatmap, state-based branch density, and temporal ordering pressure for
  annotator files fall materially.

## Track 3: MIR Ownership / Control-Flow Facts With Stable IDs

### Target Rating

- Architecture: `A-` when ownership/control-flow consumers use stable IDs for
  the important facts.
- Design: `A` when all safety-critical facts are frozen before lowering/checker
  consumption.
- Implementation: `A` when string-name fallbacks are renderer-only and not part
  of semantic identity.

### Current Problem

The compiler now has `OwnershipIdentity::BindingId` and `PlaceId`, which is the
right direction. But the broader ownership/control-flow surface still contains
mixed identity sources:

- string binding names in cleanup maps and checker paths;
- AST-local mutation of ownership facts before MIR lowering;
- branch/move/cleanup facts spread across control-flow analysis, cleanup
  classification, MIR pass, MIR lowering, and checker;
- re-derivation of ownership-sensitive answers from MIR shape or names.

The risk is that two phases can silently disagree about "the same binding" or
"the same place", especially around shadowing, captures, branch joins, and
async boundaries.

### Target Architecture

Create frozen MIR fact stores:

```text
OwnershipIdentity
  -> BindingId
  -> PlaceId
  -> RegionId
  -> CleanupObligationId
  -> MoveId
  -> BorrowId

FunctionOwnershipFacts
  -> bindings
  -> places
  -> moves
  -> borrows
  -> escapes
  -> cleanups
  -> transfers
  -> branch joins

FunctionControlFlowFacts
  -> blocks
  -> branch edges
  -> loop regions
  -> join points
  -> dominance/exit facts needed by cleanup checking
```

The intended data flow:

```text
annotated AST
  -> escape / ownership analysis by stable IDs
  -> cleanup classification by stable IDs
  -> control-flow facts by stable IDs
  -> frozen FunctionOwnershipFacts
  -> MIR lowering materializes facts as MIR nodes
  -> MIRChecker verifies MIR nodes against frozen facts
  -> emitter renders names only
```

### Implementation Plan

1. Inventory string-name ownership/control-flow keys.
   - Target files:
     - `src/semantic/escape_analysis.rb`
     - `src/semantic/ownership_graph.rb`
     - `src/mir/control_flow.rb`
     - `src/mir/cleanup_classifier.rb`
     - `src/mir/mir_pass.rb`
     - `src/mir/mir_lowering.rb`
     - `src/mir/mir_checker.rb`
   - Classify each string use as semantic identity or render/display name.

2. Add frozen fact-store structs.
   - `FunctionOwnershipFacts`
   - `FunctionControlFlowFacts`
   - `CleanupObligation`
   - `MoveFact`
   - `BorrowFact`
   - `EscapeFact`
   - `BranchJoinFact`
   - Every fact should carry stable IDs plus source location/display names for
     diagnostics only.

3. Move escape and ownership graph outputs to IDs.
   - Preserve display names for diagnostics.
   - Remove string-name equality as the primary identity for moves, borrows,
     captures, and escapes.

4. Move cleanup classification to IDs.
   - Cleanup entries should be keyed by `CleanupObligationId` / `BindingId`.
   - Resource cleanup should use Track 1's `ResourceCleanupAction` when that
     track is complete; until then, isolate the string as render metadata.

5. Move control-flow branch facts to IDs.
   - Branch guards, move guards, join facts, loop frame facts, and branch-owned
     cleanup facts should be represented as stable fact records.
   - `MIRPass` should consume a fact store rather than mutating many AST fields.

6. Make MIR lowering/checker fact-driven.
   - Lowering should materialize `AllocMark`, `Cleanup`, `MoveMark`,
     `TransferMark`, and operand facts from the frozen store.
   - `MIRChecker` should verify visible MIR against the frozen store instead of
     rediscovering ownership obligations from names.

7. Add invariant tests.
   - Shadowed names produce different `BindingId`s.
   - Captured bindings preserve identity across async/FSM lowering.
   - Branch joins preserve move/cleanup facts by ID.
   - Diagnostics still print user-facing names.
   - Checker fails when MIR facts disagree with the frozen store.

### Exit Criteria

- Safety-critical ownership/control-flow maps are keyed by stable IDs, not raw
  names.
- Cross-phase ownership facts are frozen before MIR lowering consumes them.
- `MIRChecker` validates against explicit facts and emits useful diagnostics.
- Decomplex broken protocols and state-based branch density improve in the MIR
  ownership/control-flow files.

## Track 4: Emission Boundaries And Raw Fragment Isolation

### Target Rating

- Architecture: `A-` when raw fragments are confined to typed emit plans.
- Design: `A` when the emitter is a pure renderer over MIR/emit-plan nodes.
- Implementation: `A` when no semantic phase can create a string fragment that
  affects ownership, cleanup, async lifetime, or concurrency.

### Current Problem

The emitter is much closer to the correct boundary than before, but there are
still Zig-shaped string carriers outside the final renderer:

- `MIR::ZigTemplate`
- `FsmBodyItem.opaque_zig`
- `Segments::SyntheticZig`
- `pre_body_zig` / `extra_prologue_zig`
- `resource_close_zig`
- helper parameters named `*_zig` that may be final render text or semantic
  code depending on call site

Some of these are harmless final formatting. Some are transitional debt. The
architecture needs a hard distinction.

### Target Architecture

Introduce a closed final-emission fragment model:

```text
ZigEmitPlan
  -> ZigExprFragment
  -> ZigStmtFragment
  -> ZigBlockFragment
  -> ZigTemplateRef
```

Rules:

- MIR and semantic phases may carry typed facts, typed MIR nodes, or typed
  template references.
- Only the emitter may turn those into `String`.
- Any fragment created before `MIRChecker` must be explicitly
  `NonSemanticFragment` and must fail if it contains allocator, cleanup,
  transfer, lock, async, or runtime ownership tokens.
- Multi-statement fragments are forbidden before the final emitter unless they
  are represented by a dedicated MIR node or typed emit-plan node.

### Implementation Plan

1. Add a fragment taxonomy.
   - `ZigExprFragment`
   - `ZigStmtFragment`
   - `ZigBlockFragment`
   - `NonSemanticZigFragment`
   - `ZigTemplateRef`
   - Constructors validate whether the fragment may contain ownership-sensitive
     tokens.

2. Replace `resource_close_zig`.
   - Use Track 1's `ResourceCleanupAction`.
   - `MIREmitter#resource_close_body` should dispatch on typed cleanup action
     variants, not perform string substitution.

3. Replace FSM synthetic strings.
   - `Segments::SyntheticZig` should become either structural segment data or a
     `NonSemanticZigFragment` created after segment facts are finalized.
   - `FsmBodyItem.opaque_zig` should not be allowed to feed segment facts.
   - Existing tests should assert that opaque fragments are ignored by cleanup
     fact collection.

4. Replace `pre_body_zig` and `extra_prologue_zig`.
   - Convert to typed `FsmPreBodyPlan` / `FsmProloguePlan` records.
   - Plans may contain MIR statements, resource cleanup actions, lock actions,
     or non-semantic fragments.
   - The wrapper emitter renders the plan after checker-visible facts exist.

5. Rename and isolate render-text parameters.
   - Parameters that are already-rendered text should use `ZigExprFragment` or
     `ZigStmtFragment`, not plain `String`.
   - Parameters that are semantic values should be MIR nodes, types, IDs, or
     typed facts.
   - Add local lint/invariant checks for newly added `*_zig: String` in
     non-emitter files.

6. Add architecture gates.
   - No `RawZig` in `src`.
   - No direct production `InlineZig.new`.
   - No new `resource_close_zig`.
   - No new `MIR::Node | String` semantic body unions.
   - No ownership-sensitive tokens in `NonSemanticZigFragment`.

### Exit Criteria

- The only broad string rendering surface is the emitter.
- Async/FSM/thunk plans cannot derive facts from strings.
- Resource cleanup is typed.
- New raw fragment creation fails closed unless it is final-edge and
  non-semantic.

## Suggested Execution Order

The tracks are independent, but the best risk/reward order is:

1. Track 4 resource cleanup and raw-fragment isolation.
   - This directly answers the remaining RawZig/InlineZig-class risk and should
     improve architectural confidence quickly.
2. Track 1 typed intrinsic/std-lib contracts.
   - This removes the broadest source of implicit metadata and makes
     `ZigTemplate` harder to misuse.
3. Track 3 frozen ownership/control-flow facts.
   - This is the largest safety payoff, but it benefits from typed cleanup and
     template contracts landing first.
4. Track 2 annotation phase state.
   - This is important, but it is less immediately tied to hidden ownership in
     emitted Zig. It should be implemented in slices to avoid a large
     receiver-state migration with unclear metric movement.

## Measurement Loop For Each Track

Before each track:

- snapshot Decomplex for full `src`;
- snapshot SlopCop for full project with current coverage artifacts;
- snapshot Boobytrap;
- run nil-kill collect only if the track changes broad type surfaces or at the
  end of the combined upgrade cycle.

After each subtask:

- run focused specs for touched files;
- run `bundle exec srb tc`;
- run Decomplex full `src`;
- inspect state-based branch density, state heatmap, broken protocols, and
  false simplicity before continuing.

At track completion:

- run full covered specs;
- run diff coverage buckets;
- run Src Type Guardrails;
- regenerate Decomplex and SlopCop;
- regenerate Boobytrap;
- run nil-kill for tracks that changed type signatures, phase state, or
  registry records.
