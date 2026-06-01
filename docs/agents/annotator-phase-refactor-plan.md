# Annotator Phase Refactor Plan

## Goal

Give `src/annotator` the same kind of explicit phase structure that MIR already
has: narrow phase responsibilities, typed fact handoff, and no hidden parallel
paths. The target is not seven full AST walks. The target is a sequence of
clear contracts where each phase either walks only the tree it owns or consumes
facts collected by an earlier phase.

MIR is already closer to this shape: it has pass-state boundaries for rewrite,
hoist, pre-MIR type verification, escape analysis, cleanup classification,
placement, lowering, and ownership verification. Annotator has similar
conceptual phases, but too many of them currently share mutable state through
`SemanticAnnotator`, `Scope`, and `SymbolEntry`.

## Correct High-Level Phases

### 0. Builtin Environment

Responsibility:

- Construct the root environment containing builtin types, builtin functions,
  stdlib methods, resources, schemas, and capability vocabulary.
- Own only compiler-internal declarations that exist before user code.
- Expose an immutable or append-only environment object to later phases.

Should not:

- Analyze user AST bodies.
- Mutate function-local flow state.
- Record call graph, effects, BG captures, or lock facts.

Expected output:

- `BuiltinEnvironment`
- root `Scope` or replacement declaration table seeded with builtins

### 1. Import and Declaration Index

Responsibility:

- Process imports.
- Collect top-level type declarations, function declarations, externs, schemas,
  resources, and executable top-level statements.
- Establish stable declaration identity before bodies are analyzed.
- Detect duplicate top-level names and invalid declaration shapes while source
  syntax is still local.

Walk shape:

- Top-level only.
- No deep expression typing except what import/declaration syntax requires.

Expected output:

- `DeclarationIndex`
- stable declaration IDs for user types and functions
- mapping from AST declaration nodes to declaration records

### 2. Type and Signature Registration

Responsibility:

- Resolve declared type annotations that can be resolved without function body
  inference.
- Register user-defined type shells before recursive references are needed.
- Register all function, extern, method, and resource signatures before any body
  walk.
- Seed generic declarations, union variants, default method requirements,
  reentrance metadata, and sync-policy metadata.

Walk shape:

- Top-level declarations plus type annotation subtrees.
- No function body typing.

Expected output:

- `TypeRegistry`
- `SignatureRegistry`
- updated declaration records with resolved declared types
- diagnostics for invalid declared signatures

### 3. Binding and Flow Model

Responsibility:

- Separate stable binding identity from branch-local facts.
- Keep declaration facts, type identity, and lexical identity stable.
- Keep mutable facts such as initialization, moved state, storage candidate,
  borrow state, lock state, and flow-sensitive capability state in a separate
  flow object.

This is the most important architectural seam. Today `Scope#dup` deep-copies
`SymbolEntry` values for branches. That works locally but makes later updates
fragile because old nested references can become stale. The replacement shape
should be:

```text
BindingSymbol
  stable: name, declaration site, declared type, mutability, visibility

FlowState
  local: initialized, moved, storage, borrow/capability facts, branch facts
```

Should not:

- Maintain a compatibility path where callers can freely mutate the old
  `SymbolEntry` fields and the new flow object. If this phase is introduced,
  each migrated fact must have one owner.

Expected output:

- `BindingTable`
- `FlowFrame` / `FlowState`
- branch join and scope enter/exit operations

### 4. Function Body and Expression Typing

Responsibility:

- Deep-walk function bodies and executable top-level statements.
- Resolve identifiers through the binding/flow model.
- Type expressions and stamp AST nodes with concrete `full_type`.
- Validate local declaration, assignment, call, operator, generic, match, block,
  and return rules that are knowable from local facts plus registered
  signatures.
- Record summary facts needed by whole-program phases instead of running those
  whole-program phases inline.

Walk shape:

- Main deep AST walk.
- This is the phase that should still contain most expression visitors.

Expected output:

- typed AST
- function-local `BodySummary` records:
  - call sites
  - return facts
  - BG capture sites
  - WITH/capability sites
  - lock/snapshot sites
  - effect-producing operations
  - Auto slots still requiring resolution

### 5. Auto and Type Finalization

Responsibility:

- Resolve `Auto` slots and other deferred type facts after enough body
  information exists.
- Re-stamp or finalize the small set of nodes whose type genuinely depends on
  deferred inference.
- Fail before MIR if any evaluatable AST node remains untyped.

Walk shape:

- Ideally summary-driven plus targeted node updates.
- Full tree scan is acceptable only as an invariant check, not as the main
  inference mechanism.

Expected output:

- finalized typed AST
- no `:Untyped` or unresolved `Auto` in MIR-visible positions

### 6. Whole-Program Semantic Summaries

Responsibility:

- Build the call graph from recorded call sites.
- Infer and propagate effects.
- Propagate caller sync requirements.
- Classify BG capture strategy.
- Finalize fallibility and requirement metadata that depends on multiple
  functions.

Walk shape:

- Summary graph, not AST-first.
- AST nodes may be updated by exact references captured in `BodySummary`.

Expected output:

- `CallGraph`
- `EffectSummary`
- `CaptureSummary`
- updated function signatures or metadata with whole-program facts

### 7. Capability, Lock, and Deferred Validation

Responsibility:

- Validate capability-sensitive call sites, WITH/MATCH sites, lock ordering,
  snapshot purity, reentrancy rules, stack restrictions, and other checks that
  require finalized type/effect/call facts.
- Consume typed site records rather than rediscovering source syntax.
- Raise user-facing diagnostics with source locations from recorded sites.

Walk shape:

- Queue/summary driven.
- No broad "peek back into the whole AST and reinterpret it" behavior.

Expected output:

- finalized semantic AST
- capability audit result
- no deferred validation queues left unflushed

### 8. Annotation Boundary Check

Responsibility:

- Verify the contract MIR depends on.
- Assert every MIR-visible node has a resolved type.
- Assert every function has finalized signature/effect/capability metadata.
- Assert no phase-owned queues or mutable temporary state remains live.
- Mark the program as `:annotated`.

Walk shape:

- Full-tree invariant scan is acceptable here.
- This phase should not repair facts. It should fail hard on compiler bugs.

Expected output:

- annotated program ready for MIR

## Recommended Implementation Order

## Implementation Tracker

- [x] `phase-declaration-index`: extract top-level import/type/function/extern
  declaration indexing into a typed phase record.
- [x] `phase-type-registration`: move top-level type shell registration behind
  an explicit phase entry point.
- [x] `phase-signature-registration`: move function, extern, and synthesized
  union method signature registration behind an explicit phase entry point.
- [x] `phase-auto-finalization`: isolate deferred `Auto` finalization from the
  main annotation entry point.
- [x] `phase-whole-program-semantics`: isolate caller-sync propagation, BG
  capture classification, effect inference, WITH/MATCH checks, and concurrency
  checks behind one whole-program semantic phase.
- [x] `phase-builtin-environment`: move builtin/root-scope setup behind an
  explicit typed builtin-environment phase. Done means annotator construction
  delegates builtin setup to one phase entry point and builtin setup no longer
  appears as anonymous constructor side effects.
- [x] `phase-body-analysis-wrapper`: move the existing function-body and
  synthesized-function walk behind a typed body-analysis phase entry point.
  This is not the full body-summary phase; it is the no-dual-path boundary
  extraction that makes the remaining summary work visible.
- [x] `phase-body-summary`: introduce typed body-summary facts for the records
  already produced during the existing body walk. Done means at least one old
  deferred queue or ad hoc record payload is fully replaced, with no consumer
  reading both the old and new source for the same decision.
- [x] `phase-body-summary-call-facts`: replace the old parallel call/failure
  hashes with one typed per-function `FunctionBodySummary`. Done means the call
  graph, propagating callees, fn-pointer-call bit, and direct-failure seed have
  one owner, and whole-program/effect/lock/reentrance consumers read the typed
  summary rather than legacy ivars.
- [x] `phase-body-summary-deferred-with`: replace the old
  `@deferred_with_validations` hash queue with a typed
  `DeferredWithValidation` fact consumed by the deferred-validation phase. This
  also fixed a real bug: deferred `:ATOMIC` validations were previously queued
  but never checked during flush.
- [x] `phase-binding-flow-model`: replace branch-local mutable `SymbolEntry`
  copying with stable binding identity plus explicit flow state. This is the
  large remaining architectural item. Done means migrated flow facts have one
  owner and direct writes to the old `SymbolEntry` fact fields are deleted.
- [x] `phase-binding-flow-moved-state`: migrate move/borrow flow facts that are
  currently mutated directly on `SymbolEntry` into an explicit flow owner. Done
  means moved-state readers/writers no longer mutate a copied `SymbolEntry`
  field and branch scopes merge/fork the flow fact directly.
- [ ] `phase-expression-domains`: after binding/flow ownership is explicit,
  split expression typing domains only where it removes real branch hubs.
- [x] `phase-expression-domain-calls`: extract call expression typing into a
  small typed domain object after call/body summaries are explicit. Done means
  `visit_FuncCall`/method-call callsite summary production and signature
  validation no longer rely on ambient annotator hashes, and no legacy helper
  path remains for the migrated call facts.
- [x] `phase-program-finalization`: move post-body metadata computation,
  call-graph checks, fallibility/effect propagation, FSM/stack metadata, and
  program result stamping behind one typed program-finalization phase.
- [x] `phase-deferred-validation`: move capability, lock, reentrancy, stack, and
  other post-body validations behind a final validation phase that consumes
  typed facts/queues and leaves no deferred work live.
- [x] `phase-annotation-boundary`: add a final boundary checker that verifies
  MIR-visible annotation invariants and marks `:annotated`. It must fail on
  compiler bugs and must not repair facts.

Current priority order:

1. `phase-expression-domains`

The remaining items are the actual state-ownership work. They should only be
implemented when the old fact owner can be deleted rather than preserved as a
compatibility path.

### Step 1: Introduce Phase Result Structs Without Moving Logic

Create typed records for facts that are already being produced:

- `DeclarationIndex`
- `SignatureRegistry`
- `BodySummary`
- `CallSiteFact`
- `CapabilitySiteFact`
- `WithSiteFact`
- `BgCaptureSiteFact`

This should be mostly additive at first, but not a dual semantic path. The
existing annotator can populate the new records while still owning behavior.
No caller should consult both old and new records for the same decision.

Why first:

- Low behavioral risk.
- Makes hidden fact flow visible.
- Gives later extractions a typed destination.

### Step 2: Extract Declaration and Signature Phases

Move the top-level declaration and signature registration logic out of
`visit_Program` into explicit phase objects.

Why second:

- These are naturally top-level only.
- They are already conceptually multi-pass.
- They should reduce `visit_Program` pressure without changing expression
  typing.

Done means:

- `visit_Program` delegates to declaration/signature phases.
- Function bodies are not analyzed until signatures are complete.
- No compatibility copy of signature registration remains in
  `SemanticAnnotator`.

### Step 3: Build the Body Summary During the Existing Body Walk

Keep expression typing in the current visitor initially, but make it emit
structured summaries for calls, BG captures, WITH sites, lock sites, and effect
sites.

Why third:

- This avoids a premature seven-walker rewrite.
- It lets whole-program phases stop spelunking through ambient annotator state.

Done means:

- Whole-program post-passes consume `BodySummary` records.
- At least one old deferred queue or ad hoc hash is fully deleted.

### Step 4: Extract Whole-Program Summary Phases

Move call graph, effect inference, caller sync propagation, BG capture
classification, and capability-sensitive validation to summary-driven phase
objects.

Why fourth:

- These phases are where the current architecture most often peeks forward and
  backward.
- They should not need full AST walks once body summaries are reliable.

Done means:

- The whole-program phases have typed inputs and outputs.
- `SemanticAnnotator` no longer owns their mutable working state except through
  a phase context object.

### Step 5: Replace Scope Copying With Binding Identity Plus Flow State

This is the largest and most valuable structural change. Do it only after the
summary facts are explicit enough to prevent accidental behavior drift.

Why fifth:

- It touches many local visitors.
- It is the root fix for stale `SymbolEntry` references, branch joins, and
  post-pass refresh logic.

Done means:

- Branches copy or fork `FlowState`, not stable binding declarations.
- A binding has one stable identity.
- A flow-sensitive fact has one owner.
- Direct mutation of migrated `SymbolEntry` flow fields is deleted, not kept as
  a compatibility path.

### Step 6: Extract Expression Typing Domains

After binding/flow is explicit, split the main body visitor by domain where it
actually reduces complexity:

- call typing
- match typing
- declaration/assignment typing
- capability syntax typing
- collection/pipeline typing

Why sixth:

- Extracting these before the data model is fixed risks creating many helpers
  that still share the same mutable state.

Done means:

- Each extracted domain owns a small typed context.
- Extracted helpers replace branch hubs instead of wrapping them.
- Decomplex and SlopCop improve or the extraction is reverted.

### Step 7: Add the Annotation Boundary Checker

Create a final invariant checker similar in spirit to MIR's pre-MIR and
ownership checks.

Why last:

- It should enforce the new contracts after the contracts exist.
- It should not become another repair pass.

Done means:

- Missing type, unresolved Auto, unflushed deferred validation, missing
  function metadata, and stale phase state are compiler errors.

## Acceptance Criteria

- No new `T.untyped` in `src/`.
- No new untyped hashes or arrays for record-shaped phase facts.
- No dual paths for migrated facts.
- Old mutable state is deleted once a phase owns that fact.
- `bundle exec srb tc` passes.
- Relevant unit/integration specs run with `prspec`.
- Decomplex and SlopCop move in the right direction for each completed
  extraction, or the extraction is driven further until it does.
- If metrics move the wrong direction and there is no clear path to finish the
  migration, revert the extraction.

## Expected Code Size Impact

The code may grow temporarily when typed phase records are introduced, but the
goal is not a permanent balloon. A correct refactor should trade one giant
mutable visitor for:

- fewer branches in `SemanticAnnotator`
- smaller functions
- fewer ambient instance variables
- fewer stale-scope repair helpers
- fewer deferred queues with untyped payloads
- more explicit data contracts

If the result is seven full AST walkers that all mutate the same old
`SymbolEntry` fields, the refactor failed. The value comes from explicit fact
ownership, not from multiplying passes.
