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

1. `BodyFacts` from the current body visitor.
2. `SemanticIndex` as the downstream boundary.
3. Whole-program semantic consumers rewritten to fact tables.
4. Hoist output upgraded to carry stable synthetic IDs and provenance.
5. Escape/cleanup/ownership moved from source AST to hoisted IR/MIR.
6. CI guardrail enforced.
7. Annotator receiver state collapsed.

The reason to start with `BodyFacts` is pragmatic: most forbidden late AST
walks exist because body typing did not publish enough information. Stable IDs
and `SemanticIndex` are necessary, but they pay off only once body facts replace
consumer-side rediscovery.

The largest correctness win is Stage 6, but it should not be first. Ownership,
escape, and cleanup need explicit hoisted places and synthetic IDs. Starting
there would force another weak adapter layer. The better sequence is to make
source facts complete, make hoist preserve identity, then move memory-safety
facts to the normalized representation.

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

Rejected during this milestone:

- A broader standalone call-site fact adapter was attempted and backed out
  because it added fact scaffolding without deleting enough old control flow.
  The retained implementation reuses the existing body scan instead.

Remaining major work:

- Stable IDs (`BodyId`, `LocalId`, `PlaceId`, `CallSiteId`, `PredicateId`) are
  still design work, not implemented in this milestone.
- `SemanticIndex` is a boundary wrapper over the current typed registries, not
  yet the full immutable sub-index store described above.
- Several source walkers remain in pre-registration, Auto inference, escape
  analysis, cleanup classification, MIR lowering, and MIR/control-flow passes.
  Some are currently allowed migration surfaces; memory-safety walkers should
  move only after hoist preserves stable places and synthetic provenance.
- The guardrail is report-only. It should become fail-on-new-violation after
  the remaining legitimate migration exceptions are explicitly classified.
