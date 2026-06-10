# Annotator A+ Architecture

This document describes the target annotator design before migration details.
The goal is not to copy Rust exactly. The goal is to keep the same core lesson:
source syntax is a poor substrate for ownership, cleanup, escape, and async
lifetime reasoning. Those checks should consume stable typed facts or a lowered
control-flow IR, not rediscover facts by walking source ASTs.

## A+ End State

The A+ compiler shape is:

```text
tokens
  -> syntax AST
  -> declaration and name indexes
  -> typed semantic bodies plus frozen semantic facts
  -> hoisted typed IR
  -> MIR
  -> MIR checker
  -> emitter
```

The annotator owns only the source-facing semantic work:

1. Build a complete declaration index.
2. Resolve every name to a stable definition, scope, local, or place ID.
3. Resolve type, function, std-lib, intrinsic, capability, ownership, effect,
   and allocation contracts into typed records.
4. Type-check each body once and collect local semantic facts.
5. Solve delayed constraints such as `Auto`, generic evidence, effect
   propagation, capability obligations, and sync/reentrance requirements.
6. Freeze an immutable `SemanticIndex` consumed by hoisting and later passes.

The annotator should not decide lowered cleanup mechanics, anonymous temporary
ownership, MIR move guards, FSM destruction paths, thunk cleanup, or Zig
rendering. Those belong after source syntax has been normalized.

The key invariant:

```text
After SemanticIndex.freeze!, no compiler stage may walk source AST to discover
semantic facts. A later stage may only use stable IDs, frozen semantic facts,
or its own current IR.
```

This does not mean "no traversals exist." A pass can traverse its own input to
produce a result. It does mean a downstream pass should not call
`AST.walk_body`, `AST.each_locatable`, or similar helpers to rediscover facts
that annotation or hoisting should have produced.

## Correct Number Of Passes

For annotation proper, the target is six passes. The surrounding pipeline has
more stages, but only these six should be considered annotator work.

| Pass | Name | Input | Output | What Happens |
| --- | --- | --- | --- | --- |
| 1 | Declaration Index | Syntax AST | `DeclarationIndex`, `BodyId`s, top-level item IDs | Imports, type declarations, function headers, externs, methods, union defaults, and source spans are indexed. Function bodies are identified but not semantically interpreted. |
| 2 | Definition And Scope Resolution | `DeclarationIndex` | `DefinitionIndex`, `ScopeIndex`, `LocalId`s, `PlaceId` seeds | Names are resolved once. Every binding, function, type, method, field, capture, and import gets a stable typed ID. This replaces late string/name lookups. |
| 3 | Contract Registration | Definition/scope indexes | `TypeIndex`, `SignatureIndex`, `CapabilityContractIndex`, `IntrinsicContractIndex` | Types, schemas, signatures, std-lib functions, intrinsic contracts, ownership contracts, allocation/fallibility contracts, and capability declarations are converted from source/table form into typed compiler records. |
| 4 | Body Typing And Local Fact Collection | Syntax bodies plus indexes | `TypedBody`, `BodyFacts`, diagnostics | Each body is traversed once. Expressions receive final types. Calls, returns, raises, BG blocks, WITH blocks, captures, predicates, lock/capability operations, branch predicates, and Auto evidence are recorded as facts keyed by stable IDs. |
| 5 | Constraint Finalization | Typed bodies and collected facts | solved type/capability/effect facts | `Auto`, generic evidence, return unification, capability obligations, fallibility, direct effects, sync policy, and local call obligations are solved. This may run fixpoint algorithms over fact tables, but not source AST. |
| 6 | Semantic Index Freeze | All annotation products | immutable `SemanticIndex` | The annotator publishes a read-only boundary object. Hoist and MIR cannot ask the annotator receiver questions or mutate semantic state. |

After these six passes:

| Stage | Owner | Input | Output | Rule |
| --- | --- | --- | --- | --- |
| 7. Hoist / Typed Normalization | Hoist | `SemanticIndex`, typed bodies | `HoistedBody` or THIR-like body | May traverse typed bodies once to normalize expression trees, introduce temporaries, make evaluation order explicit, and preserve or derive stable IDs for synthetic locals. |
| 8. Hoisted Fact Passes | Semantic/MIR boundary | Hoisted bodies | frozen ownership/escape/cleanup seeds | Must analyze hoisted IR or CFG, not source AST. This is where anonymous owned values, cleanup guards, escape facts, and branch-local ownership become reliable. |
| 9. MIR Lowering And MIR Checker | MIR | hoisted bodies plus facts | checked MIR | MIR checker verifies ownership, cleanup, effects, async cleanup, and control-flow invariants on MIR. |

So the answer is: six annotator passes, followed by hoist, hoisted-fact
analysis, and MIR. If a current "annotator" responsibility only becomes
correct after hoisting, it should not remain an annotator pass.

Current assessment after the receiver-state cleanup:

- The target pass count is still right. Adding more named passes is unlikely to
  help by itself.
- The current problem is that several pass boundaries are procedural rather
  than data-product boundaries. A phase may run at the right time but still
  leave later code without the facts it needs, forcing source-body scans or
  ambient receiver-state reads.
- The useful split is collect first, decide later:
  body typing should collect local facts once; constraint/finalization passes
  should make decisions after function-wide and program-wide facts exist.
- Decisions that depend on normalized temporaries, evaluation order, branch
  ownership, or cleanup regions should move after hoist, not become more
  source-AST annotation logic.

## Comparison To Rust

Rust's compiler separates syntax, high-level semantic IR, typed high-level IR,
MIR, and code generation. The rustc dev guide describes AST lowering as a
conversion from AST to HIR that removes syntax irrelevant to later analysis,
such as parenthesization and source-level loop sugar:
https://rustc-dev-guide.rust-lang.org/hir/lowering.html

Rust's HIR is still close to source syntax but compiler-friendly. It stores
items and bodies in maps, keyed by IDs, so later code can look up an item/body
without searching the whole tree:
https://rustc-dev-guide.rust-lang.org/hir.html

Rust then builds THIR after type checking. THIR is fully typed, more desugared,
and makes operations such as method calls, implicit dereferences, and
destruction scopes explicit:
https://rustc-dev-guide.rust-lang.org/thir.html

Rust's borrow checker runs on MIR. The dev guide explicitly says MIR borrow
checking is preferable because MIR is less complex than HIR and because regions
for non-lexical lifetimes are derived from the control-flow graph:
https://rustc-dev-guide.rust-lang.org/borrow-check.html

That is the important comparison for Cheat:

- Rust does not use source AST as the substrate for borrow checking.
- Rust uses stable IDs (`DefId`, `LocalDefId`, `HirId`, `BodyId`) to avoid
  searching syntax trees for facts.
- Rust makes destruction/control flow more explicit before memory-safety checks.
- Rust's borrow checker performs dataflow over MIR, then performs a final MIR
  walk to report errors using the computed facts.

Cheat differs because capabilities bind to variables/places, not only to
types. That means Cheat's semantic index must be richer than Rust's ordinary
type table. It needs capability facts keyed by `PlaceId`/`LocalId`, with
lexical extent, acquisition source, predicate guard, transfer/escape behavior,
and effect obligations. But that difference strengthens the case for stable
IDs and frozen fact tables. It does not justify late AST walks.

Swift reaches a similar shape. Swift parses to an AST, semantic analysis
produces a fully type-checked AST, SILGen lowers that to raw SIL, mandatory
SIL passes perform correctness-related dataflow diagnostics, and canonical SIL
is then optimized/lowered:
https://www.swift.org/documentation/swift-compiler/

Swift SIL is also an ownership-aware IR. Its SIL documentation describes OSSA
as an ownership SSA form that can statically validate use-after-free/leak
invariants and catch compiler bugs in SIL generation/optimization:
https://github.com/swiftlang/swift/blob/main/docs/SIL/SIL.md

The pattern is consistent:

```text
source syntax -> typed semantic representation -> normalized control-flow IR
              -> ownership/dataflow verification -> emission
```

## Current Architecture Gaps

The current code already has named phases in `src/annotator/phases`, and recent
work moved some state out of `SemanticAnnotator`. The remaining problem is not
that no phase names exist. The problem is that later facts are still recovered
from mutable AST and broad receiver state.

Current examples:

- `SemanticAnnotator#annotate!` visits the program, finalizes Auto, runs
  whole-program semantics, deferred validations, then marks `:annotated`.
- `run_whole_program_semantics!` calls `EscapeAnalysis`,
  `CapabilityPlan.refresh_function_plans!`, `BgCaptureClassifier`,
  `EffectInference`, `WithMatchCheck`, and `ConcurrencyChecks`.
- Several of those downstream systems still perform source AST walks.
- MIR-side systems still contain `AST.each_locatable`, `AST.walk_body`, and
  `AST.each_bg_block` calls for ownership, cleanup, thunk/FSM, and control-flow
  facts.

That means the phase boundary is named, but not fully real. The facts needed by
later phases are not always stored as typed, stable, frozen products.

## Annotator Completion Status

The A+ annotator work in this branch is now implemented for annotation proper.
The remaining architectural work is no longer "make annotation phases real";
it belongs to hoist, MIR ownership/control-flow facts, escape analysis, or
pipeline lowering.

Implemented in this branch:

- Typed semantic IDs now exist for definitions, bodies, scopes, locals, places,
  call sites, predicates, capabilities, suspend points, and synthetic locals.
- `FunctionBodySummary` and `BodyScanSummary` carry `DefId`, `BodyId`,
  `CallSiteFact`, `LocalFact`, and `SuspendPointFact` records.
- `SemanticIndex` publishes an immutable `SemanticIdIndex` for definition/body
  lookup at the annotation boundary.
- Caller-sync propagation, reentrance checks, tail-call validation,
  `WithMatchCheck`, FSM suspend enumeration, and strict-test IO checks consume
  typed body facts instead of raw call/suspend arrays.
- Body facts are recorded during the visitor traversal that stamps types.
  The old `scan_for_calls` post-body pass is gone.
- CATCH type resolution now runs after body traversal has registered raised
  error types. Declaration indexing no longer walks function bodies to seed
  error registrations.
- Async body summaries are stored as one typed `AsyncBodyFact` per async body
  instead of three parallel receiver arrays.
- Stream yields use a scoped `StreamYieldFrame`; WITH nesting, BG pinned state,
  snapshot transaction purity state, fiber capture state, and capture-move
  suppression state now have explicit scoped lifecycles.
- Pipeline SOA field tracking, auto-lock assignment context, effect state, and
  lock-analysis state now live behind the typed receiver-state owner rather
  than separate annotator ivars.
- `OwnershipGraph` is owned by receiver state, and graph scope depth now lives
  inside `OwnershipGraph` so pruning depth and declaration depth cannot drift.
- Transitive lock acquires are a local lock-cycle phase product, not receiver
  state.
- Loop move validation now reads a typed `OwnershipGraph::Node` once and emits
  diagnostics from that node instead of mixing hidden graph lookups through the
  validation body.
- Auto-lock assignment context now restores on exception and is receiver-owned.

Rejected during the loop:

- Moving branch termination into receiver state made Decomplex worse and did
  not reduce risk, so `@branch_terminated` remains a narrow control-flow
  visitor flag.
- Extracting CATCH body analysis into another helper increased state-based
  density and broken protocols. The final design keeps CATCH body typing in
  the function visitor, but moves CATCH type resolution after body traversal.
- A wrapper-method API for auto-lock assignment and pipeline field tracking
  fixed the protocol but increased root clusters and false simplicity. The
  final design uses direct receiver-state fields with explicit `ensure`
  restoration instead of adding public lifecycle methods.

Current remaining work, deliberately outside this annotator phase-state
completion pass:

1. Capability validation can still become a standalone validator over frozen
   fact tables. That should be a dedicated capability-validator rewrite, not a
   cosmetic move of `WITH` helper code.
2. Ownership, escape, cleanup, and branch-local memory-safety dataflow should
   continue moving after hoist/MIR, where evaluation order and synthetic
   temporaries are explicit.
3. Pipeline annotation and MIR lowering already share typed plan objects in the
   MIR pipeline path, but pipeline source typing is still a large helper. Any
   further work should reduce duplicated assumptions between annotation and
   MIR without creating a second planner.
4. Guardrails for new forbidden AST semantic walkers should become CI-enforced
   once the remaining hoist/MIR migration exceptions are classified.

Completion-pass metric result versus the starting snapshot for this loop:

| Decomplex metric | Before | After | Delta |
| --- | ---: | ---: | ---: |
| Cross-Detector Convergence | 1754 | 1753 | -1 |
| Root-Cause Clusters | 481 | 478 | -3 |
| Decision Pressure | 274 | 271 | -3 |
| State Heatmap | 567 | 564 | -3 |
| State-Based Branch Density | 1598 | 1599 | +1 |
| Temporal Ordering Pressure | 14 | 14 | 0 |
| Missing Abstractions | 175 | 173 | -2 |
| Neglected Path Conditions | 1378 | 1359 | -19 |
| Broken Protocols | 401 | 399 | -2 |
| False Simplicity | 1049 | 1053 | +4 |
| Fat Unions | 10 | 10 | 0 |

Final receiver/ownership-state cleanup delta from the continuation snapshot:

| Decomplex metric | Before | After | Delta |
| --- | ---: | ---: | ---: |
| Cross-Detector Convergence | 1753 | 1753 | 0 |
| Root-Cause Clusters | 478 | 478 | 0 |
| Decision Pressure | 271 | 270 | -1 |
| State Heatmap | 564 | 556 | -8 |
| State-Based Branch Density | 1599 | 1599 | 0 |
| Temporal Ordering Pressure | 14 | 14 | 0 |
| Missing Abstractions | 173 | 173 | 0 |
| Neglected Path Conditions | 1359 | 1359 | 0 |
| Broken Protocols | 401 | 399 | -2 |
| False Simplicity | 1049 | 1053 | +4 |
| Fat Unions | 10 | 10 | 0 |

The remaining `False Simplicity` increase is explicit typed state surface:
`LockAnalysisState` top-level struct/fact ownership and graph-owned scope
depth. The attempted receiver-state move for `branch_terminated` was rejected
because it added three more false-simplicity findings with no correctness win.

## Walk Policy

Allowed source AST traversals:

1. Parser construction and syntax validation.
2. Declaration indexing over top-level forms.
3. One body traversal in body typing/fact collection.
4. Diagnostic span mapping, as long as it does not infer semantic facts.
5. Temporary migration code behind an explicit TODO and a metric gate.

Forbidden after `SemanticIndex.freeze!`:

1. Re-walking a function body to find calls, captures, raises, BG blocks,
   WITH blocks, predicate contexts, cleanup candidates, or branch ownership.
2. Recomputing type, capability, ownership, escape, cleanup, or fallibility
   from source node shape.
3. Looking up source names instead of stable IDs, except for diagnostics.
4. Asking `SemanticAnnotator` mutable receiver state questions from later
   stages.

This should eventually be enforceable with a guardrail:

```text
No AST walker APIs are allowed outside parser, declaration indexing, body
typing, hoist lowering, and explicit test helpers.
```

Hoist may still traverse typed bodies because hoist is the phase that replaces
source shape with normalized body shape. After hoist, analyses must traverse
hoisted bodies, CFGs, MIR, or frozen fact tables.

## Target Data Products

The A+ annotator should publish one primary product:

```ruby
SemanticIndex
```

It should be immutable and composed of typed sub-indexes:

| Product | Purpose |
| --- | --- |
| `DefinitionIndex` | Function/type/method/import/field definitions keyed by stable IDs. |
| `ScopeIndex` | Lexical scopes, visibility, shadowing, and owner relationships. |
| `TypeIndex` | Resolved types, schemas, aliases, resource metadata, and nominal definitions. |
| `SignatureIndex` | Function/method/extern/std-lib signatures and call conventions. |
| `IntrinsicContractIndex` | Typed std-lib/intrinsic contracts after table ingestion. |
| `BodyIndex` | Mapping from function IDs to typed body IDs and source spans. |
| `TypedBodyStore` | Per-body typed nodes or typed body IR, keyed by body IDs. |
| `LocalFactTable` | Locals, params, captures, mutability, allocation family, storage class. |
| `PlaceFactTable` | Places derived from locals, fields, indexes, derefs, captures, and synthetic temps. |
| `CapabilityFactTable` | Capability acquisition, guard, transfer, lexical extent, and requirements keyed by place/local IDs. |
| `EffectFactTable` | Direct and propagated effects, fallibility, sync, reentrance, stack constraints. |
| `CallSiteFactTable` | Calls keyed by call-site ID: callee, args, required effects/capabilities, fallibility. |
| `ControlSeedFactTable` | Branch predicates, loop boundaries, return/raise/yield sites, and source-level CFG seeds. |
| `DiagnosticIndex` | Source spans and user-facing notes; diagnostics can retain syntax context without feeding semantics. |

The annotator receiver should become a small orchestrator:

```text
SemanticAnnotator
  -> AnnotationInput
  -> DeclarationIndexPass
  -> DefinitionResolutionPass
  -> ContractRegistrationPass
  -> BodyTypingPass
  -> ConstraintFinalizationPass
  -> SemanticIndexFreeze
```

Each pass receives a typed input object and returns a typed result object. No
pass should depend on arbitrary ivars from another pass.

## Capability Model

Capabilities are not ordinary type facts. They bind to variables, places, and
control-flow regions.

The target representation should look more like:

```text
CapabilityFact(
  capability_id,
  place_id,
  capability_kind,
  acquisition_site_id,
  guard_predicate_id,
  lexical_region_id,
  transfer_policy,
  escape_policy,
  required_effects,
  provenance
)
```

Important implications:

- A capability can be held by a local even when the local's type is unchanged.
- A field/index/deref place may inherit or restrict a capability from a base
  place.
- A branch may prove a capability under a predicate, but that proof must be
  keyed to the predicate and branch region.
- Hoist must preserve capability-bearing place IDs or derive new synthetic
  place IDs with explicit provenance.
- MIR checker should verify that capability requirements are satisfied at use
  sites. It should not search the source AST for a matching WITH/predicate.

This makes Cheat more demanding than Rust at annotation time, but the answer is
still typed fact tables plus normalized control flow, not repeated source walks.

## What Should Move Earlier

These belong in annotation:

- Binding and name resolution.
- Type resolution.
- Function/std-lib/intrinsic contract normalization.
- Capability declarations and local source-level capability requirements.
- Call-site facts.
- Return/raise/fallibility seeds.
- BG/WITH/source boundary facts as source facts.
- Diagnostics that require source syntax.

## What Should Move Later

These should not be finalized on source AST:

- Anonymous owned-value cleanup.
- Branch-local cleanup ownership.
- Move guard placement.
- Escape facts that depend on normalized temporaries.
- FSM/thunk cleanup paths.
- Async lifetime state.
- MIR ownership/control-flow verification.

Those facts become correct after hoist or MIR because evaluation order,
temporary names, and control-flow edges are explicit.

## Proposed Final Pipeline

```text
Parse
  Input: tokens
  Output: AST
  Rule: no semantic state

DeclarationIndexPass
  Input: AST
  Output: DeclarationIndex
  Rule: top-level only; no body semantic decisions

DefinitionResolutionPass
  Input: AST + DeclarationIndex
  Output: DefinitionIndex + ScopeIndex + stable IDs
  Rule: all names get IDs; later stages do not resolve by string

ContractRegistrationPass
  Input: DefinitionIndex + ScopeIndex
  Output: TypeIndex + SignatureIndex + CapabilityContractIndex
  Rule: std-lib/intrinsics become typed contracts here

BodyTypingPass
  Input: function body + indexes
  Output: TypedBody + BodyFacts + constraints
  Rule: one traversal per body; collect, do not solve global facts here

ConstraintFinalizationPass
  Input: typed bodies + constraints
  Output: solved semantic facts
  Rule: fixpoint over fact tables; no AST walk

SemanticIndexFreeze
  Input: all annotation products
  Output: immutable SemanticIndex
  Rule: no downstream mutable annotation state

Hoist
  Input: SemanticIndex + typed bodies
  Output: HoistedBodyStore
  Rule: introduce temps, explicit evaluation order, stable synthetic IDs

HoistedFactPass
  Input: HoistedBodyStore + SemanticIndex
  Output: OwnershipFacts + EscapeFacts + CleanupFacts
  Rule: dataflow over hoisted IR/CFG

MIRLowering
  Input: hoisted bodies + facts
  Output: MIR
  Rule: no source AST facts are rediscovered

MIRChecker
  Input: MIR + facts
  Output: checked MIR
  Rule: authoritative memory-safety, cleanup, move, borrow, capability verification

Emitter
  Input: checked MIR
  Output: Zig
  Rule: the only place Zig text is produced
```

## Best Migration Path

The best migration is not to build a full parallel compiler. That would create
two semantic paths and guarantee drift. The best path is to introduce the
missing boundary objects, move one fact family at a time behind those objects,
then delete each old AST-walk consumer as soon as its replacement is green.

The migration should be measured after every step with Decomplex and targeted
coverage. The expected local signal is fewer AST walkers, fewer state-heavy
annotator ivars, fewer source-shape branches in semantic/MIR boundary files,
and fewer broken protocols around pass ordering.

### Order Of Operations To Avoid Rework

The efficient order is:

1. Inventory and classify every remaining source-AST semantic walker.
2. Add the stable ID spine (`BodyId`, `LocalId`, `PlaceId`, `CallSiteId`,
   `PredicateId`, plus provenance for synthetic IDs). Do this before rewriting
   capability, control-flow, ownership, or pipe logic; otherwise those rewrites
   will key their facts by names or AST object identity and need to be rewritten
   again.
3. Build the `SemanticIndex` skeleton around existing registries and the new
   IDs. It can begin as a typed boundary over current data, but it must become
   the only downstream semantic product.
4. Extend the single body typing traversal to emit complete `BodyFacts` keyed
   by those IDs. This removes second-pass body scans without creating a second
   identity scheme.
5. Rewrite whole-program semantic consumers to fact tables: effects,
   fallibility, caller sync, WITH/call requirements, lock checks, and
   concurrency checks.
6. Extract capability validation into an explicit validator over fact tables.
   This should happen after IDs and `BodyFacts`, because capability correctness
   is place/region/predicate-sensitive.
7. Upgrade hoist to preserve IDs, create synthetic IDs, and publish provenance.
   Hoist should become the last source-shaped consumer.
8. Move ownership, escape, cleanup, and control-flow dataflow to hoisted bodies
   or MIR facts. This is the largest memory-safety win, but it should wait
   until hoist exposes stable places and evaluation order.
9. Convert pipe analysis into a typed `PipelinePlan` consumed by annotation,
   rewriting, and MIR lowering. This can run after the ID/index foundation so
   pipeline facts do not need another migration.
10. Turn the AST-walk guardrail from report-only to fail-on-new-violation.
11. Collapse remaining `SemanticAnnotator` mutable state into phase-local
    inputs/results once consumers no longer depend on receiver internals.

The critical dependency is stable identity before validator/planner rewrites.
Without that, each cleanup can look locally better while still baking in the
wrong identity model.

### Stage 0. Inventory And Guardrail In Report-Only Mode

Goal:

- Make the remaining source-AST walks visible and categorized before changing
  behavior.

Work:

1. Inventory every `AST.walk_body`, `AST.each_locatable`, `AST.each_bg_block`,
   and source-body scanner in `src/annotator`, `src/semantic`, and `src/mir`.
2. Classify each walker as one of:
   - allowed parser/syntax/declaration traversal,
   - allowed body-typing traversal,
   - allowed hoist traversal,
   - diagnostic-only traversal,
   - forbidden semantic fact rediscovery.
3. Add a report-only guardrail that prints forbidden walkers but does not fail
   CI yet.
4. Snapshot Decomplex, SlopCop, Boobytrap, and Nil-Kill before implementation.

Exit criteria:

- There is a complete list of forbidden walkers and the fact family each one is
  rediscovering.
- The guardrail can distinguish allowed source traversals from semantic
  rediscovery.
- No behavior has changed yet.

### Stage 1. Stable ID Spine

Goal:

- Stop using source names, AST object identity, and mutable receiver state as
  cross-phase identifiers.

Work:

1. Add typed ID records: `DefId`, `BodyId`, `ScopeId`, `LocalId`, `PlaceId`,
   `CallSiteId`, `PredicateId`, `CapabilityId`, and `SyntheticLocalId`.
2. Generate top-level IDs in declaration indexing.
3. Generate local/place/call/predicate IDs during body typing.
4. Store IDs on typed facts and, temporarily, on AST nodes only as compatibility
   back-references.
5. Update current registries to key by IDs where possible while keeping
   diagnostic names as payload, not identity.

Exit criteria:

- New facts can refer to definitions, bodies, locals, places, calls, predicates,
  and capabilities without source-name lookup.
- Existing behavior still works, but consumers have an ID path available.
- No new untyped slots or primitive tuple arrays are introduced.

### Stage 2. SemanticIndex Boundary

Goal:

- Give annotation one explicit product and prevent later stages from asking the
  `SemanticAnnotator` receiver for mutable state.

Work:

1. Add `SemanticIndex` as a typed, frozen boundary object.
2. Compose it from typed sub-indexes:
   `DefinitionIndex`, `ScopeIndex`, `TypeIndex`, `SignatureIndex`,
   `IntrinsicContractIndex`, `BodyIndex`, and initial fact tables.
3. Initially populate the indexes from existing data structures where needed.
   These adapters are migration scaffolding, not long-term dual paths.
4. Change hoist/MIR entry points to accept `SemanticIndex` instead of reaching
   through annotator helpers or mutable AST metadata where practical.
5. Add pass-state enforcement: no consumer may run after annotation without a
   frozen `SemanticIndex`.

Exit criteria:

- `SemanticAnnotator#annotate!` can return/publish `SemanticIndex`.
- Downstream phases have a single semantic boundary object.
- Existing annotator ivars that only expose data to later phases are marked for
  deletion and no new phase-facing ivars are added.

### Stage 3. BodyFacts From The Single Body Typing Walk

Goal:

- Convert body typing from "stamp nodes and let later passes search again" into
  "stamp nodes and produce complete local facts once."

Work:

1. Add `BodyFacts` keyed by `BodyId`.
2. During the existing body visitor, record:
   calls, call arguments, returns, raises, yields, BG blocks, WITH blocks,
   captures, lock sites, capability acquisition/use sites, branch predicates,
   match arms, loop regions, Auto evidence, and fallibility seeds.
3. Split facts into source facts and lowered facts:
   - source facts: what the user wrote and what source diagnostics need,
   - lowered facts: only placeholders/seeds for hoist/MIR work.
4. Update tests to assert facts directly, not only final diagnostics.

Exit criteria:

- No whole-program semantic pass needs to scan a body just to find calls,
  returns, raises, BG blocks, WITH blocks, captures, or predicate sites.
- Body typing has one source traversal per body.
- Later analyses can start consuming fact tables.

### Stage 4. Rewrite Whole-Program Semantic Consumers

Goal:

- Remove AST walking from source-level semantic analyses while keeping those
  analyses before hoist where they still belong.

Work:

1. Rewrite `CapabilityPlan` to consume `CapabilityFactTable`,
   `CallSiteFactTable`, and `ControlSeedFactTable`.
2. Rewrite `WithMatchCheck` to consume WITH/call/capability facts instead of
   walking function bodies.
3. Rewrite `EffectInference` to consume direct effect and call-site facts.
4. Rewrite caller-sync propagation to operate over call graph and call-site
   facts.
5. Rewrite `ConcurrencyChecks` to consume lock/call/WITH facts.
6. Delete each old AST-walk path immediately after its fact-table replacement
   passes tests. Do not keep both paths.

Exit criteria:

- `run_whole_program_semantics!` is a pipeline over fact tables.
- `CapabilityPlan`, `WithMatchCheck`, `EffectInference`, caller-sync, and
  `ConcurrencyChecks` do not walk source AST for facts.
- Diagnostics are unchanged or improved.

### Stage 5. Hoist Becomes The Last Source-Shaped Consumer

Goal:

- Make hoist the only stage after annotation that can inspect typed body shape.

Work:

1. Make hoist consume `SemanticIndex` plus typed bodies.
2. Make hoist produce `HoistedBodyStore`, preserving original IDs where
   possible and creating explicit `SyntheticLocalId`s where it introduces
   temporaries.
3. Record provenance for every synthetic local/place.
4. Ensure branch regions, evaluation order, temporary ownership, and source span
   mapping are explicit in hoisted bodies.
5. Remove MIR-side assumptions that inspect source AST because hoist failed to
   preserve enough information.

Exit criteria:

- Hoist output is sufficient input for ownership, escape, cleanup, and MIR
  lowering.
- Post-hoist passes can operate without source AST access.
- Synthetic values have stable IDs and provenance.

### Stage 6. Move Ownership, Escape, And Cleanup To Hoisted IR/MIR

Goal:

- Stop computing memory-safety facts from source syntax.

Work:

1. Rewrite `EscapeAnalysis` to operate on hoisted bodies or MIR facts, not
   source AST.
2. Rewrite cleanup classification to operate on hoisted locals/places/regions.
3. Move anonymous owned-value cleanup, branch-local cleanup ownership, move
   guard placement, and async cleanup facts out of source AST analysis.
4. Make MIR lowering consume the hoisted ownership/escape/cleanup facts.
5. Make `MIRChecker` verify these facts authoritatively.
6. Delete old source-AST cleanup/escape scanners as each replacement lands.

Exit criteria:

- Escape, ownership, and cleanup facts are derived from explicit evaluation
  order and explicit control-flow regions.
- MIR checker can reject stale/missing facts.
- Source AST is no longer a memory-safety substrate.

### Stage 7. Enforce The No Late AST Walk Rule

Goal:

- Turn the architecture into a CI invariant.

Work:

1. Convert the Stage 0 guardrail from report-only to fail-on-new-violation.
2. Allow source walkers only in parser/syntax, declaration indexing, body
   typing, hoist, diagnostics, and tests.
3. Require an explicit waiver record for any temporary migration exception.
4. Add Decomplex/Boobytrap visibility for forbidden AST walks and late fact
   rediscovery.

Exit criteria:

- New semantic AST walkers cannot enter `src/semantic` or post-hoist `src/mir`
  unnoticed.
- CI fails if a later phase starts rediscovering facts from source syntax.

### Stage 8. Collapse SemanticAnnotator Into An Orchestrator

Goal:

- Remove the broad mutable annotator receiver as a hidden state machine.

Work:

1. Replace remaining annotator ivars with phase-local typed input/result
   objects.
2. Move persistent facts into `SemanticIndex`.
3. Move temporary state into pass-local contexts.
4. Remove mixins whose only purpose was to share implicit receiver state.
5. Keep `SemanticAnnotator` as an orchestration facade for compatibility and
   diagnostics.

Exit criteria:

- `SemanticAnnotator` has little or no semantic mutable state.
- Each phase has explicit inputs and outputs.
- No later phase depends on annotator internals.

### Stage 9. Final Hardening

Goal:

- Prove the migration is a complexity and correctness win.

Work:

1. Run full focused compiler tests and coverage.
2. Run Decomplex, SlopCop, Boobytrap, and Nil-Kill against the Stage 0
   snapshot.
3. Investigate every metric regression in:
   - state heatmap,
   - state-based branch density,
   - temporal ordering pressure,
   - broken protocols,
   - SlopCop dark arms,
   - SlopCop genuine gaps,
   - untyped/nilable slot pressure.
4. Keep working until regressions are explained and either fixed or explicitly
   accepted with a reason.

Exit criteria:

- Decomplex and SlopCop show a decisive win.
- Boobytrap no longer identifies the old source-walk surfaces as uncovered
  state-based branch hotspots.
- Nil-Kill untyped slots stay flat or drop.
- New/changed code is strongly typed and covered.

## Migration Stack Rank

The highest-impact path is:

1. Stable ID spine.
2. `SemanticIndex` boundary.
3. Complete `BodyFacts` from the existing body typing traversal.
4. Whole-program semantic consumers rewritten to fact tables.
5. Capability validator over fact tables.
6. Hoist output upgraded to carry stable synthetic IDs and provenance.
7. Escape/control-flow/cleanup/ownership moved from source AST to hoisted IR/MIR.
8. Typed `PipelinePlan` shared by annotation, rewriting, and MIR lowering.
9. CI guardrail enforced.
10. Remaining annotator receiver state collapsed into phase-local inputs/results.

The reason to start with stable IDs is pragmatic: capability, ownership,
control-flow, escape, and pipeline facts are all facts about definitions,
bodies, locals, places, calls, predicates, and regions. If those rewrites land
before stable IDs, they will key their new facts by strings or AST object
identity and need a second migration later.

`BodyFacts` should be early, but not first. Most forbidden late AST walks exist
because body typing did not publish enough information, but those facts should
be keyed by the final identity model from the start.

The largest correctness win is moving ownership, escape, cleanup, and
control-flow dataflow off source AST. It should not be first. Those analyses
need explicit hoisted places, synthetic IDs, and evaluation order. Starting
there would force another weak adapter layer. The better sequence is to build
stable identity, make source facts complete, make hoist preserve identity, then
move memory-safety facts to the normalized representation.

## Success Criteria

The target architecture is reached when:

- `SemanticAnnotator` is an orchestrator, not a stateful semantic database.
- Every downstream consumer reads `SemanticIndex`, hoisted IR, MIR, or typed
  fact tables.
- No post-freeze stage walks source AST to compute semantic facts.
- Hoist is the last stage allowed to read source-shaped bodies.
- Ownership, escape, cleanup, and capability verification happen on explicit
  places/control flow, not source syntax.
- Std-lib and intrinsic behavior is normalized into typed contracts before body
  analysis, so std-lib calls are handled like ordinary function calls wherever
  possible.
- MIR checker is the authoritative verifier before emission.

## Expected Metric Movement

If implemented correctly, this should materially reduce:

- Decomplex state heatmap.
- Decomplex state-based branch density.
- Decomplex temporal ordering pressure.
- Decomplex broken protocols caused by phase coupling.
- SlopCop dark arms from repeated defensive source-shape checks.
- Boobytrap uncovered state-based branch hotspots in semantic/MIR boundary
  files.

Some line count may rise while stable IDs and typed indexes are introduced, but
branch count and state pressure should drop as late AST searches and defensive
dual paths disappear.

## Implementation Ledger

### 2026-06-09 Milestone

Implemented:

- Added a typed `SemanticIndex` boundary that the annotator publishes after
  whole-program semantic validation and before annotation completion.
- Added a report-only `Src Type Guardrails` check for newly-added late source
  AST walkers in semantic and post-annotation compiler phases.
- Promoted `WITH` blocks from rediscovered syntax to `FunctionBodySummary`
  facts recorded during the existing function body analysis path.
- Rewired `CapabilityPlan`, `WithMatchCheck`, and `ConcurrencyChecks` to
  consume `WITH` facts instead of walking each function body to rediscover
  those blocks.
- Promoted function call sites from the existing call-graph scan into
  `FunctionBodySummary` facts and removed `WithMatchCheck.deep_funcalls`.
  `WithMatchCheck.check_call_sites!` now consumes call-site facts directly.
- Centralized `FunctionDef` pre/catch/default-catch predicates so multiple
  annotator helpers stop repeating defensive field-shape checks.

### 2026-06-10 Completion Milestone

Implemented:

- Expanded the body-analysis product from call/return facts into a broader
  typed `BodyScanSummary` / `FunctionBodySummary` contract:
  binding nodes, assignment nodes, escape nodes, pipe snapshot payload types,
  suspend points, and per-`WITH` scope nodes.
- Rewired caller-sync propagation, reentrance/tail-call validation, catch
  snapshot detection, function-level FSM suspend enumeration, escape placement,
  and concurrency checks to consume recorded body facts instead of
  rediscovering calls, returns, raises, suspend points, or `WITH` scopes with
  late source-body walkers where those consumers have been migrated.
- Threaded function body summaries through `SemanticIndex` and into `MIRPass`
  so post-annotation escape placement can consume the annotator boundary
  product on normal compile/import/profile paths.
- Removed the old source rediscovery helpers:
  `scan_for_raises`, `scan_suspend_points`, `collect_bg_suspend_points`,
  `collect_self_calls`, `collect_returns`, `contains_self_call?`,
  `collect_pipe_input_types`, `catch_bodies_reference_snapshot?`,
  `collect_callsites_deep`, `function_facts_for_body`, and the concurrency
  `walk_scope_*` helpers.
- Added typed fact tests for the new body summaries, `WITH` scope boundaries,
  escape placement via recorded body facts, caller-sync propagation, and the
  total boolean contract for call suspension.

Metric result versus the 2026-06-10 loop baseline:

| Tool | Before | After | Delta |
| --- | ---: | ---: | ---: |
| Decomplex net debt | 5783 | 5771 | -12 |
| SlopCop dark arms | 2453 | 2417 | -36 |
| SlopCop genuine gaps | 1007 | 1000 | -7 |
| Boobytrap state-based branch hotspots | 1609 | 1599 | -10 |

Remaining work is no longer annotator phase separation proper. The remaining
source-body walkers in `EscapeAnalysis` are post-hoist ownership/escape
placement surfaces and should be handled by the hoisted-IR/stable-place-ID
work, not by adding more source facts to annotation.

Rejected during the 2026-06-09 milestone:

- A broader standalone call-site fact adapter was attempted and backed out
  because it added fact scaffolding without deleting enough old control flow.
  The retained implementation reuses the existing body scan instead.

Remaining major work after this milestone:

- `SemanticIndex` is a boundary wrapper over the current typed registries and
  semantic ID index, not yet the full immutable sub-index store described
  above.
- Several source walkers remain in pre-registration, Auto inference, escape
  analysis, cleanup classification, MIR lowering, and MIR/control-flow passes.
  The annotator whole-program consumers covered by this plan now consume body
  facts; the remaining memory-safety walkers should move only after hoist
  preserves stable places and synthetic provenance.
- The guardrail is report-only. It should become fail-on-new-violation after
  the remaining legitimate migration exceptions are explicitly classified.

### 2026-06-10 Receiver-State Completion Pass

Current status:

- Complete: function/body facts no longer live in `@fn_nodes`,
  `@body_summaries`, or repeated late source-body scans. `FunctionRegistry`,
  `FunctionBodySummary`, and `SemanticIndex` are the current fact boundary.
- Complete: whole-program consumers covered by the earlier plan consume body
  summaries for calls, returns, raises, suspend points, escape seeds, and
  `WITH` scopes.
- Complete in this pass: scope/context stacks, loop/conditional/smooth depths,
  held-lock state, capability predicate context, deferred validations,
  predicate call sites, and capability audit storage now sit behind the typed
  `SemanticAnnotator::ReceiverState` owner. Compatibility accessors remain for
  existing callers, but direct readers/writers no longer reach separate
  untyped receiver ivars.
- Still open but deferred from this pass: ownership graph extraction. Direct
  `@og` use is memory-safety-critical and spread through lifetime/control-flow
  logic; it needs a dedicated typed ownership-domain facade, not a generic
  state bag.

Implementation notes for this pass:

1. `ReceiverState` is a typed record rather than five separate lifecycle helper
   classes. The first implementation used separate state wrappers, but
   Decomplex correctly treated those as extra public protocol/state-machine
   surface. Collapsing them kept the single-owner invariant while avoiding a
   new cloud of wrapper methods.
2. Scope, function context, control-flow depth, held-lock, predicate context,
   deferred-validation, predicate-call-site, and audit access now route through
   the receiver-state owner.
3. `ScopeHelper#with_new_scope` now restores scopes in `ensure`; this fixes a
   real exceptional-exit protocol hole.
4. Focused tests cover scope restoration, function/loop/conditional/smooth
   restoration, held-lock restoration, and predicate-context restoration with
   predicate call-site persistence.
5. Ownership graph extraction remains intentionally outside this pass because
   it controls memory-safety facts and should become a dedicated ownership
   facade with stable place IDs rather than another state bag.

Exit criteria:

- New/changed source code is strongly typed.
- Changed lines are fully covered and changed branches are above 80%.
- Decomplex moves down overall, especially state heatmap / broken protocols /
  temporal ordering pressure, or any exception is documented with a concrete
  reason and rejected follow-up.
- `src/annotator/README.md` and this document match the implemented state
  boundary.

Final metric note for this pass:

- Decomplex total stayed flat at `5794`.
- State heatmap improved `572 -> 567` (`-5`).
- State-based branch density improved `1600 -> 1598` (`-2`).
- Broken protocols improved `410 -> 406` (`-4`).
- Temporal ordering pressure stayed flat at `14`.
- Exact predicate aliases stayed flat at `16`.
- False simplicity increased `1026 -> 1032` (`+6`). The added findings are the
  explicit scoped state APIs (`with_predicate_context`, `with_smooth_context`,
  `with_loop_context`, and receiver-state field access), not new business-rule
  branches. The first implementation with five helper state classes made this
  worse; the final `ReceiverState` record keeps one owner while avoiding most
  wrapper-method noise.

### 2026-06-10 Stable ID And Typed Fact Completion Pass

Implemented:

- Added `Semantic::DefId`, `BodyId`, `ScopeId`, `LocalId`, `PlaceId`,
  `CallSiteId`, `SuspendPointId`, `PredicateId`, `CapabilityId`, and
  `SyntheticLocalId`.
- Added deterministic `Semantic::BodyIdentity` assignment from function
  registry order. A mutable ID allocator was rejected because the intermediate
  implementation increased Decomplex state pressure.
- Added `Semantic::SemanticIdIndex` and published it through `SemanticIndex`.
- Added typed `CallSiteFact`, `LocalFact`, and `SuspendPointFact` records to
  `BodyScanSummary` and `FunctionBodySummary`.
- Removed `FunctionBodySummary#func_calls` and `BodyScanSummary#call_sites`.
  Reentrance, tail-call validation, caller-sync propagation, and
  `WithMatchCheck` now consume `CallSiteFact`.
- Removed raw suspend-point hashes from body summaries. FSM phase A now stores
  `SuspendPointFact` records and tests assert `.kind` / `.id.value`.
- Replaced the broad reflective Auto search with a typed source-AST traversal
  that only checks nodes that can carry Auto annotations.
- Replaced a test-only untyped `OpenStruct` symbol slot with the real
  `SymbolEntry`/node-storage path so the coverage spec matches the typed
  cleanup-classifier contract.
- Removed one cleanup-classifier second source walk by carrying place-indexed
  cleanup entries out of the existing binding classification traversal.
- Replaced cleanup-classifier moved-source guard discovery with a typed
  structural child walk and tightened the added cleanup-classifier signatures
  that still tripped the source type guardrails.
- Replaced the thunk mutual-recursion helper's broad `AST.each_locatable`
  search with local structural recursion for the small expression shape it
  actually needs.

Metric result versus the stable-fact pass baseline:

| Decomplex metric | Before | After | Delta |
| --- | ---: | ---: | ---: |
| Cross-Detector Convergence | 1756 | 1753 | -3 |
| Root-Cause Clusters | 482 | 481 | -1 |
| Decision Pressure | 274 | 274 | 0 |
| State Heatmap | 567 | 567 | 0 |
| State-Based Branch Density | 1598 | 1597 | -1 |
| Temporal Ordering Pressure | 14 | 14 | 0 |
| Missing Abstractions | 177 | 175 | -2 |
| Broken Protocols | 406 | 401 | -5 |
| False Simplicity | 1032 | 1032 | 0 |
| Fat Unions | 11 | 10 | -1 |

Follow-up after this pass:

- Body fact collection has moved into the type-stamping visitor path; no
  post-body `scan_for_calls` pass remains.
- Capability validation now consumes typed `CapabilityTransition` actions
  for sync-family and deferred-param decisions instead of reopening
  `source_entry`/`sync` state in the visitor helper. `SymbolEntry` owns the
  declared sync-contract predicate because it owns `sync`/`sync_families`.
  A future
  `CapabilityValidationInput`/`CapabilityValidationResult` object would be a
  packaging cleanup, not missing annotator phase separation.
- Ownership graph, escape placement, cleanup classification, and control-flow
  memory-safety facts still need the hoisted-place/CFG boundary described in
  the MIR/ownership architecture work.
- Pipeline source typing now resolves collection/range/stream/inf-stream
  source facts through one typed `PipelineSourceFact` contract. The MIR
  pipeline path already has typed plan records; any further cleanup should
  delete duplicated assumptions between annotation and MIR, not add a second
  planning path.
- The AST-walk guardrail remains report-only for classified migration
  exceptions.

### 2026-06-10 Annotator-Local Final Cleanup

Implemented:

- Replaced the split pipeline protocol of `finite_stream_source?`,
  `finite_stream_element_type`, `inf_stream_element_type`, and nullable
  iterable facts with one typed `PipelineSourceFact`.
- Converted SELECT/WHERE/INDEX, TAKE_WHILE, REDUCE, LIMIT, DISTINCT, EACH,
  SKIP, TAP, FIND/ANY/ALL/COUNT, SUM/AVERAGE/MIN/MAX, SHARD, and concurrent
  stream EACH/SELECT-family typing to consume that source fact.
- Removed compatibility test stubs for the deleted pipeline helpers so tests
  exercise the real source-fact contract.
- Moved EXCLUSIVE/write-locked/atomic deferred-param sync decisions onto
  `CapabilityPlan::CapabilityTransition` with `exclusive_validation_action`,
  `exclusive_sync?`, and `deferred_sync_param?`; the WITH validator now
  consumes the typed action instead of branching over raw sync state.
- Kept `PipelineSourceFact` and capability fix candidates as `T::Struct`
  records because that was the best Decomplex profile in this codebase:
  state heatmap stayed flat while broken protocols dropped.

Metric result versus the final cleanup baseline:

| Decomplex metric | Before | After | Delta |
| --- | ---: | ---: | ---: |
| Cross-Detector Convergence | 1753 | 1749 | -4 |
| Root-Cause Clusters | 478 | 478 | 0 |
| Decision Pressure | 270 | 270 | 0 |
| State Heatmap | 556 | 556 | 0 |
| State-Based Branch Density | 1599 | 1596 | -3 |
| Temporal Ordering Pressure | 14 | 14 | 0 |
| Missing Abstractions | 173 | 172 | -1 |
| Neglected Path Conditions | 1359 | 1359 | 0 |
| Broken Protocols | 399 | 377 | -22 |
| False Simplicity | 1053 | 1053 | 0 |
| Fat Unions | 10 | 10 | 0 |
