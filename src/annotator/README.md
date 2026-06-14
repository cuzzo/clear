# Annotator Architecture

The top-level compiler overview in [`src/README.md`](../README.md) shows how
CLEAR moves from source text to Zig. The MIR overview in
[`src/mir/README.md`](../mir/README.md) starts after annotation.

This document zooms into the annotator: the pass that turns parsed AST into
semantic AST. After this pass, later compiler stages should be able to read
names, types, storage candidates, effect facts, capability facts, and function
metadata without re-interpreting source syntax.

The examples below are schematic. Real AST nodes also carry tokens, source
locations, fix-it metadata, ownership graph facts, and lowering hints.

We will use this small CLEAR program:

```ruby clear illustrative
FN inc(x: Int64) RETURNS Int64 ->
  RETURN x + 1;
END

FN demo(flag: Bool) RETURNS Int64 ->
  value = 41;
  IF flag ->
    RETURN inc(value);
  END

  RETURN value;
END
```

At a high level, annotation is:

```text
parsed AST
  -> initialize global scope and builtins
  -> process imports
  -> register type declarations
  -> hoist function signatures into the global scope
  -> analyze function bodies and expression types
  -> resolve Auto slots, if any
  -> run shared semantic analyses
  -> classify source-level BG / execution-boundary facts
  -> infer effects and validate capability-sensitive calls
  -> run deferred WITH / lock / reentrancy / stack metadata checks
  -> stamp Program as :annotated for MIR
```

## Annotator Jobs

The annotator has five core jobs:

1. Resolve names to `SymbolEntry` objects in lexical scopes.
2. Stamp every evaluatable AST node with a concrete `full_type`.
3. Validate declarations, calls, generics, capabilities, effects, and returns.
4. Attach semantic metadata that later passes consume.
5. Report user-facing compiler errors while the source syntax is still visible.

The important boundary is that MIR should receive typed semantic AST, not a
tree that still needs type inference or user-level capability validation.
Annotation decides whether source-level operations are valid; MIR decides how
valid operations become runtime state, cleanup, FSMs, thunks, and Zig-shaped
control flow.

## Facts and Work Products Strategy

Annotation is a fact-producing pass. It should resolve source-language
semantics once, attach the result to stable AST, symbol, type, or function
objects, and leave MIR with explicit facts instead of syntax to reinterpret.
The names in this area are less uniform than MIR's plan/fact vocabulary, so the
useful distinction is lifetime:

* A **fact** survives the local visitor that produced it. It is attached to an
  AST node, `SymbolEntry`, `Type`, `FunctionSignature`, schema registry, or
  shared semantic analysis object for later phases to consume.
* A **work product** is local to one phase or visitor shape. It gathers inputs,
  validates a source construct, and is immediately turned into facts or errors.

The target shape is simple: local visitors stamp local facts, whole-program
phase objects compute transitive facts, and later compiler stages consume those
facts mechanically. If MIR, the emitter, or a lint fixer has to rediscover
source-level intent by walking raw syntax or rendered Zig text, the boundary has
leaked.

### Persistent Facts

| Fact object | Created by | Used by | Problem solved |
| --- | --- | --- | --- |
| `full_type` stamps on AST nodes | Visitor/domain methods through `stamp_type!` | Every annotator post-pass, `PreMirTypeCheck`, MIR lowering, diagnostics | Gives every expression-like node one authoritative type and rejects `:Untyped` before MIR. |
| `Scope` and `SymbolEntry` | Builtin setup, declaration visitors, parameter/capture registration | Name resolution, ownership/lifetime checks, escape analysis, MIR cleanup/storage decisions | Records binding identity, type, mutability, storage, sync, ownership, lifetime, and flow facts. |
| Type/schema registries | Type declaration and builtin phases | Expression visitors, generic validation, union/member access, MIR lowering | Makes structs, unions, resources, aliases, and extern/native shapes available before bodies are analyzed. |
| `FunctionSignature`, `FunctionRegistry`, and `SemanticIndex` | Signature registration and function body analysis | Call resolution, Auto inference, effects/fallibility, reentrance checks, MIR call lowering, MIR pass preparation | Lets calls resolve before bodies run and carries final return/effect/capability metadata through a typed registry/index instead of loose annotator receiver fields. |
| `FunctionContext` | Routine analysis | Return checking, loop/control-flow validation, stack/runtime metadata | Keeps per-routine state out of global variables while a body is being visited. |
| `BodyScanSummary` / `FunctionBodySummary` | Body visitor fact frame | Reentrance, caller sync, strict-test IO, effects/fallibility, FSM suspend setup, MIR preparation | Records calls, locals, returns, bindings, assignments, WITH scopes, snapshot reads, and suspend points during the same traversal that stamps types. |
| `AST::ReturnFact` | Return visitors | Function return finalization, fallibility checks, diagnostics | Preserves return type/value evidence for later declared/inferred return validation. |
| Auto slot/evidence maps | `AutoConstraintCollector`, shape/operator collectors, `AutoUnifier` | Auto finalization and fix generation | Defers `Auto` decisions until enough initializer, call, shape, return, and operator evidence exists. |
| Capability and held-lock facts | `WITH`/capability visitors, lock helpers, deferred validation | Whole-program lock checks, call-site requirement checks, MIR capability lowering | Separates source-level permission validation from runtime lock/snapshot emission. |
| BG capture and execution-boundary facts | Annotation visitors plus `BgCaptureClassifier` and shared semantic analyses | MIR concurrency lowering, diagnostics, scheduler/runtime decisions | Records what source-level capture forms are legal and what strategy each boundary should use. |
| Effect, fallibility, stack, and reentrance facts | Whole-program semantic phases | Call-site validation, MIR function metadata, thunk/FSM eligibility | Computes transitive metadata once from the call graph instead of re-checking at every call. |
| Lifetime and ownership-flow facts | Lifetime domain and `OwnershipGraph` | Use-after-move checks, cleanup classification, MIR ownership facts | Gives move/borrow/resource behavior one semantic source before lowering. |
| `MIRPassState` mark `:annotated` | Annotation boundary phase | MIR pass ordering checks | Prevents downstream passes from consuming AST before annotation facts are complete. |

### Short-Lived Work Products

| Work product | Created by | Consumed by | Problem solved |
| --- | --- | --- | --- |
| `BranchAnalysisResult` | Control-flow branch analysis | Immediate branch merge logic | Keeps branch scope, ownership graph, return status, and result type together while merging. |
| Declaration metadata helpers | Variable/generic analysis | Declaration visitors | Copies shape, capabilities, placement, async result, storage, and resource cleanup facts from value/type evidence to the binding. |
| Auto collection/unification results | Auto inference helper classes | Auto finalization | Turns many weak evidence sources into one concrete type per slot or a fixable diagnostic. |
| `DeferredWithValidation` | `WITH` visitors | Deferred validation phase | Delays parameter/caller-sensitive capability checks until sync propagation is complete. |
| Lock graph records (`LockEdge`, `LockHeldCallSite`, `LockClauseSite`) | Lock helper | Whole-program deadlock checks | Builds a structural lock-order graph instead of inferring lock hazards from nested syntax later. |
| Capability request/audit records | Capability helpers | Immediate validation and final audit | Keeps `WITH`, `REQUIRES`, predicate, snapshot, and alias decisions explicit while stamping types. |
| Scoped execution frames (`AsyncBodyFact`, `StreamYieldFrame`, snapshot transaction frame) | Execution-boundary visitors | Async finalization, yield typing, snapshot purity validation | Keeps async body facts and temporary execution context paired with the visitor scope that created them. |
| Pipeline aggregation descriptors and source/terminal typing facts | Pipeline helper | Pipeline expression visitors and MIR `PipelinePlanBuilder` | Centralizes aggregate typing and pipeline-specific validation before MIR turns a pipeline into a typed operation plan. |
| Intrinsic registry entries | Intrinsic registry setup | Call validation and intrinsic emission helpers | Gives intrinsic calls one typed contract for argument checks, return type, and lowering metadata. |
| Reentrance/thunk candidates | Reentrance helper | Whole-program reentrance validation and MIR thunk transform | Records recognized recursion shapes without making MIR rediscover them from source syntax. |

### Rules of Thumb

* If a decision is needed after the current visitor returns, attach it as a
  typed fact to the AST, `SymbolEntry`, `Type`, `FunctionSignature`, or a
  shared semantic result object.
* If a decision only helps lower or validate one source shape, keep it as a
  short-lived work product and immediately materialize facts or diagnostics.
* `stamp_type!` is the only normal way to finalize expression type facts.
  Direct `full_type=` writes should be rare and justified by low-level AST
  construction or test setup.
* Capability, ownership, and lifetime decisions should have one writer. If a
  later phase needs to modify them, prefer a named semantic operation over
  open-coded field mutation.
* Raw hashes are acceptable only at integration edges or while replacing legacy
  code. New cross-phase data should be a typed struct, class, or existing
  semantic object.

## Phase Flow

### 0. Annotator Construction

Files:

* [`annotator.rb`](annotator.rb)
* [`phases/builtin_environment.rb`](phases/builtin_environment.rb)

`SemanticAnnotator#initialize` creates the mutable analysis state used during
the pass:

```ruby
@receiver_state = ReceiverState.new
@function_registry = Annotator::FunctionRegistry.new
@semantic_index = nil
```

It also calls `setup_builtins`, which registers stdlib functions, built-in
types, resources, and schemas into the root scope.

The current implementation is organized into phase, domain, and helper modules
included into `SemanticAnnotator`. That is materially easier to navigate than a
single large visitor, and the highest-pressure receiver fields now sit behind
a typed `ReceiverState` owner for scope, function context, control-flow depth,
held locks, body fact frames, async facts, stream yield frames, snapshot
transaction frames, pipeline field tracking, lock-analysis state, effect state,
the ownership graph, and capability predicate/deferred-validation/audit state.
`OwnershipGraph` owns its own lexical graph scope depth so graph pruning and
declaration depth cannot diverge.
Function registry and semantic index are separate typed objects because they
are exported phase products. `@branch_terminated` remains a narrow
control-flow visitor flag because it is not a cross-phase fact and moving it
behind the receiver state worsened complexity metrics without improving the
memory-safety boundary. Shared analyses that are consumed by both annotation
and MIR live in [`../semantic`](../semantic) rather than under MIR.

### 1. Entry Point

Files:

* [`annotator.rb`](annotator.rb)
* [`phases/annotation_boundary.rb`](phases/annotation_boundary.rb)
* [`phases/auto_finalization.rb`](phases/auto_finalization.rb)
* [`phases/whole_program_semantics.rb`](phases/whole_program_semantics.rb)
* [`phases/deferred_validation.rb`](phases/deferred_validation.rb)
* [`phases/program_finalization.rb`](phases/program_finalization.rb)

`annotate!(program)` is the public entry point. It resets user-defined types,
walks the program, runs whole-program post-passes, and marks the MIR pass state:

```text
SemanticAnnotator#annotate!
  -> visit(program)
  -> run Auto inference if needed
  -> propagate caller sync
  -> classify BG captures
  -> infer effects
  -> validate WITH MATCH / call-site requirements
  -> validate concurrency and locks
  -> flush deferred WITH validations
  -> finalize capability audit
  -> mark :annotated
```

Most AST-local typing happens during `visit(program)`. Most facts that require
the complete function set happen after the body walk.

### 2. Program-Level Declaration Order

Files:

* [`annotator.rb`](annotator.rb), `visit_Program`
* [`phases/type_registration.rb`](phases/type_registration.rb)
* [`phases/signature_registration.rb`](phases/signature_registration.rb)
* [`phases/declaration_index.rb`](phases/declaration_index.rb)

The program walk is deliberately multi-pass:

```text
imports
  -> type declarations
  -> function and extern signatures
  -> union default method validation / synthesis
  -> legacy reentrance bridge and error-type seeding
  -> sync policy resolution
  -> executable statements and function bodies
  -> whole-program metadata finalization
```

For the example, before `demo` is analyzed the root scope already contains the
signature for `inc`:

```ruby
inc: FunctionSignature(
  params: [Param("x", Int64)],
  return_type: Int64
)
```

That is why `demo` can call functions declared later in the file and why
recursive functions can resolve their own names.

### 3. Scopes and Symbols

Files:

* [`../ast/scope.rb`](../ast/scope.rb)
* [`../ast/symbol_entry.rb`](../ast/symbol_entry.rb)
* [`domains/variables.rb`](domains/variables.rb)

Scopes map names to `SymbolEntry` objects. A symbol carries the binding's type,
mutability, storage, sync/layout facts, ownership flags, and analysis metadata.

For `demo`, parameter and local declarations become:

```ruby
flag:  SymbolEntry(type: Bool,  mutable: false, storage: :stack)
value: SymbolEntry(type: Int64, mutable: false, storage: :stack)
```

Identifiers are resolved by `visit_Identifier`. The identifier node receives:

```ruby
AST::Identifier(
  name: "value",
  symbol: <SymbolEntry value>,
  full_type: Int64,
  storage: :stack
)
```

`Scope#dup` creates a composed child scope with a parent link and no eager
local binding copies. Reads resolve through the parent chain. Branch-local
mutations must go through `Scope#entry_for_write`, which materializes a local
`SymbolEntry` copy only for the binding being mutated. Function parameter
entries remain canonical on `AST::Param#symbol`; post-body consumers that may
hold older capture maps refresh through helpers such as `Scope.live_param_syms`.
This keeps branch-flow state isolated while preserving stable parameter
identity.

### 4. Function Signatures

Files:

* [`phases/signature_registration.rb`](phases/signature_registration.rb)
* [`phases/signature_registry.rb`](phases/signature_registry.rb)
* [`phases/body_analysis.rb`](phases/body_analysis.rb)
* [`helpers/function_signature.rb`](helpers/function_signature.rb)
* [`helpers/function_analysis.rb`](helpers/function_analysis.rb)

Function signatures are registered before function bodies are visited. During
`visit_FunctionDef`, the annotator:

```text
validates declared type annotations
  -> registers a FunctionSignature in the root scope
  -> records the FunctionDef in FunctionRegistry
  -> analyzes params, captures, body, and returns
  -> records typed body summaries, call graph, and fallibility edges
```

For the example:

```ruby
demo.full_type = FunctionSignature(
  params: [Param("flag", Bool)],
  return_type: Int64,
  can_fail: false,
  effects: []
)
```

Function bodies are handled by `analyze_routine`, which enters a new scope,
declares parameters and captures, visits statements, finalizes the scope, and
then verifies or infers the return type.

### 5. Expression Type Stamping

Files:

* [`phases/expression_domains.rb`](phases/expression_domains.rb)
* [`domains/expressions.rb`](domains/expressions.rb)
* [`domains/member_access.rb`](domains/member_access.rb)
* [`helpers/method_analysis.rb`](helpers/method_analysis.rb)
* [`helpers/union.rb`](helpers/union.rb)

Every expression visitor is responsible for stamping `full_type` through
`stamp_type!`. The stamp helper rejects missing and `:Untyped` types, making it
the main local invariant for annotation.

For the expression `value + 1`:

```text
visit_Identifier(value) -> full_type Int64
visit_Literal(1)        -> full_type Int64
visit_BinaryOp          -> validates numeric operator, stamps Int64
```

For `inc(value)`:

```text
visit_FuncCall
  -> visit each argument
  -> resolve_call
  -> verify_function_signature!
  -> stamp call with copied return Type
```

Type errors are raised as soon as enough local information exists: undefined
names in `visit_Identifier`, argument mismatches in `verify_function_signature!`,
invalid operators in expression visitors, and invalid declarations in
declaration finalization.

### 6. Declarations and Assignment

Files:

* [`domains/variables.rb`](domains/variables.rb)
* [`helpers/generic_analysis.rb`](helpers/generic_analysis.rb)

`visit_BindExpr` handles keywordless declarations and assignments:

```text
if name is new:
  visit initializer
  finalize declaration
  stamp node type
  declare symbol
  record ownership/capability facts
else if name is immutable:
  raise immutable assignment error
else:
  validate assignment
  stamp assignment type
  update move/borrow/mutation facts
```

Declared type metadata is propagated through helpers so collection topology,
storage, and capabilities survive coercion and fallback inference. This is a
common source of bugs: if a helper creates a fresh `Type` and forgets to copy
the relevant `shape`, `capabilities`, or `placement`, later MIR stages see a
semantically weaker type.

### 7. Auto Type Inference

File: [`helpers/auto_inference.rb`](helpers/auto_inference.rb)

`Auto` is resolved after the initial body walk, not during parsing and not
while registering signatures.

```text
typed Auto-bearing node scan
  -> AutoConstraintCollector
  -> ShapeEvidenceCollector
  -> OperatorEvidenceCollector
  -> AutoUnifier
  -> stamp resolved slots or emit fixable findings
```

This means `Auto` slots are first annotated with enough source evidence to
decide them later. They become final concrete types before downstream whole
program analyses such as BG capture classification and MIR preparation.

For example:

```ruby clear illustrative
x: Auto = 1;
y = x + 2;
```

The body walk records the initializer and operator evidence. The unifier later
chooses `Int64`, stamps the declaration, and emits an optional fix replacing
`Auto` with `Int64`.

### 8. Capabilities, WITH Blocks, and Execution Boundaries

Files:

* [`domains/execution_boundaries.rb`](domains/execution_boundaries.rb)
* [`helpers/capabilities.rb`](helpers/capabilities.rb)
* [`helpers/lock_helper.rb`](helpers/lock_helper.rb)
* [`helpers/with_match_check.rb`](helpers/with_match_check.rb)

Capabilities are checked in several layers:

1. Type annotation validation rejects invalid capability combinations.
2. `visit_WithBlock` resolves requested capabilities and declares aliases.
3. Deferred validations handle facts that only become final after call-site
   propagation, especially parameter sync.
4. Whole-program checks validate held-lock calls, lock ordering, and WITH MATCH
   requirements.

Schematic `WITH` flow:

```text
visit_WithBlock
  -> acquire_capability! for each requested capability
  -> validate typed transition actions and sync/storage requirements
  -> declare aliases in a child scope
  -> visit guard predicates and body
  -> validate no guarded mutation invalidates predicates
  -> record lock/effect/capability audit facts
```

For `BG` and `WITH`, annotation handles source-level safety:

```text
WITH target AS alias -> body END
  annotator: target type, alias capability, locks, purity, call requirements

BG { body }
  annotator: capture legality, spawn form, effects, fallibility, stack tier
```

It does not decide the runtime execution shape. FSM context structs, thunk
frames, suspend points, runtime aliases, cleanup guards, and Zig emission are
MIR responsibilities. Keeping this split matters: if annotation starts
predicting MIR runtime layout, it becomes another lowering pass instead of the
source semantic boundary.

Errors are raised at the earliest reliable point:

* impossible local targets fail during `acquire_capability!`;
* missing local locks fail immediately;
* parameter locks can be deferred until caller sync propagation;
* cross-function lock cycles fail after the call graph is complete.

This area has improved, but it is still one of the densest parts of annotation.
The main cleanup opportunity is to keep replacing record-shaped hashes with
typed request/result structs and to move each capability transition behind a
named operation instead of open-coded field updates.

### 9. Control Flow and Branch State

Files:

* [`domains/control_flow.rb`](domains/control_flow.rb)
* [`domains/lifetimes.rb`](domains/lifetimes.rb)

`analyze_control_flow_branches` snapshots the ownership graph, visits each
branch in an isolated scope, then merges non-terminating branch state.

For the example:

```text
before IF: value is live
then:      value is read by inc(value), branch returns
else:      no explicit else
after IF:  value remains live because the returning branch cannot poison merge
```

The annotator also records branch result types so expression-style `IF` and
`MATCH` forms can be promoted and typed.

This boundary is partially architectural and partially semantic. The
`OwnershipGraph` is an important attempt to centralize move/borrow state, but
some older logic still reads or writes symbol flags directly. The cleaner end
state is one ownership-flow authority and a smaller set of AST stamps that MIR
can trust.

### 10. Effects, Fallibility, Reentrancy, and Runtime Metadata

Files:

* [`helpers/effects.rb`](helpers/effects.rb)
* [`helpers/reentrance.rb`](helpers/reentrance.rb)
* [`domains/errors.rb`](domains/errors.rb)
* [`../semantic/effect_inference.rb`](../semantic/effect_inference.rb)
* [`../semantic/concurrency_checks.rb`](../semantic/concurrency_checks.rb)
* [`../semantic/bg_capture_classifier.rb`](../semantic/bg_capture_classifier.rb)
* [`../semantic/escape_analysis.rb`](../semantic/escape_analysis.rb)

After all functions have been visited, the annotator has the complete call
graph and can compute transitive metadata:

```text
compute_needs_rt!
compute_can_fail!
enforce_fallible_returns!
compute_effects!
validate_predicate_purity!
compute_fsm_eligibility!
check_lock_cycles!
compute_stack_tiers!
finalize_async_execution_shapes!
```

The final `FunctionSignature` objects are updated with `can_fail`, `effects`,
and `stack_tier` so later callers and MIR passes consume the typed
`FunctionRegistry` / `SemanticIndex` boundary instead of inspecting annotator
receiver state directly.

`compute_needs_rt!` records annotation-visible runtime pressure from the
call graph and source-level effects. It is not the final allocator/runtime
threading decision. `MIRPass#finalize_needs_rt!` remains the final authority
after escape analysis, cleanup classification, and placement facts reveal which
functions actually need runtime allocator plumbing.

Fallibility is resolved late because it depends on the transitive call graph
and on whether error channels are absorbed locally. Error-union return
declarations are enforced after this propagation.

### 11. MIR Boundary

The annotator finishes by marking the program as `:annotated`:

```ruby
MIRPassState.for!(program).mark!(:annotated)
```

`MIRPassState` itself lives in [`../semantic/pass_state.rb`](../semantic/pass_state.rb)
because it records the shared compiler phase contract from annotation through
MIR checking.

At this boundary, MIR expects:

* every expression-like AST node has a concrete `full_type`;
* identifiers have resolved symbols;
* function signatures are registered and updated;
* `Auto` slots have either resolved or produced findings;
* capability and WITH validations have run;
* BG capture strategy has been classified;
* effects, can-fail, runtime, stack, lock, and FSM metadata are stamped.

If MIR finds `:Untyped` or has to guess capability/fallibility intent, that is
usually an annotator bug.

## When Types Become Final

The annotator has several type states:

| State | Where | Meaning |
| --- | --- | --- |
| Parsed annotation | Parser / AST | User wrote a type annotation, but it may still contain `Auto`, generics, or capability syntax that must be validated. |
| Local expression type | Visitor methods | An expression has enough local evidence to receive `full_type`. |
| Declaration type | `finalize_decl_node!` and helpers | A binding has a scope entry, storage candidate, and final declared/inferred type for local analysis. |
| Auto-resolved type | `run_auto_inference!` | `Auto` slots are unified from call, return, initializer, shape, and operator evidence. |
| Function metadata type | whole-program post-passes | Function signatures now carry final `can_fail`, `effects`, and stack/runtime metadata. |
| MIR-ready type | end of `annotate!` | Downstream passes may treat AST type facts as authoritative. |

The most important practical rule: a node's `full_type` should not be
`Type::UNTYPED` after annotation. `PreMirTypeCheck` exists to enforce that
boundary before MIR lowering.

## File Map

The annotator directory is split by concern, though some older logic still
lives in the large main file:

* [`annotator.rb`](annotator.rb): main visitor and top-level phase
  orchestration. It should stay thin; node-family logic belongs in domains,
  phase modules, or helpers.
* [`phases/`](phases): annotator phase modules for builtin setup, declaration
  indexing, type registration, signature registration, body analysis, `Auto`
  finalization, whole-program semantics, deferred validation, and boundary
  finalization.
* [`domains/`](domains): visitor domains for control flow, variables,
  expressions, member access, execution boundaries, lifetimes, and errors.
* [`helpers/function_analysis.rb`](helpers/function_analysis.rb): routine
  analysis, call resolution, parameter checks, lifetime checks, and function
  metadata collection.
* [`helpers/function_signature.rb`](helpers/function_signature.rb): typed
  function signature representation and unwrapping.
* [`helpers/auto_inference.rb`](helpers/auto_inference.rb): `Auto` constraint
  collection, shape evidence, operator evidence, and unification.
* [`helpers/generic_analysis.rb`](helpers/generic_analysis.rb): generic type
  validation, substitution, capability propagation, and declaration metadata.
* [`helpers/capabilities.rb`](helpers/capabilities.rb): capability validation,
  WITH acquisition, alias declaration, predicate call-site tracking, and audit.
* [`helpers/lock_helper.rb`](helpers/lock_helper.rb): lock rank and held-lock
  graph checks.
* [`helpers/effects.rb`](helpers/effects.rb): direct/transitive effects,
  fallibility, runtime needs, FSM eligibility, and stack tier helpers.
* [`helpers/reentrance.rb`](helpers/reentrance.rb): recursion and reentrancy
  validation.
* [`helpers/pipe_analysis.rb`](helpers/pipe_analysis.rb): pipeline expression
  typing, one-pass source fact classification, terminal validation,
  concurrent operation checks, and aggregate facts that MIR pipeline plans
  consume.
* [`helpers/method_analysis.rb`](helpers/method_analysis.rb): collection,
  stdlib, extern, and receiver method resolution.
* [`helpers/union.rb`](helpers/union.rb): union schema validation and variant
  access.
* [`helpers/test_annotation.rb`](helpers/test_annotation.rb): test DSL nodes
  and strict-test validation.
* [`helpers/fixable_helpers.rb`](helpers/fixable_helpers.rb): user-facing
  diagnostics and fix generation.
* [`../semantic`](../semantic): shared semantic analyses such as ownership graph,
  caller sync propagation, BG capture classification, effect projection,
  concurrency checks, and compiler pass-state tracking.

## Current Messy Areas

The annotator is doing real compiler work, but several boundaries remain too
wide for v0.1 comfort:

* `SemanticAnnotator` still exposes a large include surface. Most mutable
  phase state now has typed owners, but explicit phase objects would make the
  ownership of visitor methods clearer.
* Scopes use composed parent-linked bindings with copy-on-write branch entries.
  Function parameter entries stay canonical on `AST::Param#symbol`, and
  capture consumers refresh through `Scope.live_param_syms` before reading
  storage-axis fields.
* Capability handling now stores predicate/deferred/audit state explicitly.
  Sync-family/deferred-param decisions live on typed `CapabilityTransition`
  actions, while `SymbolEntry` owns declared sync-contract facts. A future
  validator/executor split would mainly package the remaining visitor work; it
  is no longer a hidden phase-state dependency.
* Legacy reentrance source syntax has been removed. Parser,
  fix, and annotation code should accept only `EFFECTS REENTRANT[:VARIANT]` and
  `REQUIRES <param>: NON_REENTRANT`. Downstream MIR, thunk, and FSM consumers
  rely on normalized effect/reentrance facts, not legacy syntax.
* Some MIR-facing facts are stamped directly on AST nodes from scattered helper
  code. The desired shape is a small number of authoritative outputs from
  `src/semantic` that lowering reads.
* The include chain makes many methods look local to one class even when they
  are implemented in phase/domain modules. This is organized but not isolated.
  Explicit phase contexts would make state ownership clearer.

## Cleanup Direction

The highest-value cleanup is not a new grammar or a second type system. It is
to keep making existing phase boundaries explicit:

1. Keep annotation state behind typed owners and introduce explicit phase
   objects only where they delete real protocol surface.
2. Replace remaining record-shaped hashes with typed structs.
3. Keep capability transition decisions on `CapabilityTransition` actions and
   `Type` / `SymbolEntry` facts rather than open-coded field checks in visitor
   helpers.
4. Keep branch ownership and graph scope state centralized in
   `OwnershipGraph`, and reduce direct symbol flag mutation.
5. Keep MIR-facing stamps small, documented, and produced by one authority.

The target architecture is simple: visitors resolve local syntax and stamp
local types; whole-program phase objects compute global facts; MIR consumes a
fully annotated AST without re-checking source-language semantics.
