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
  -> classify BG capture strategy
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

## Phase Flow

### 0. Annotator Construction

File: [`annotator.rb`](annotator.rb)

`SemanticAnnotator#initialize` creates the mutable analysis state used during
the pass:

```ruby
@scope_stack = [Scope.new]
@function_context_stack = []
@fn_nodes = {}
@call_graph = {}
@deferred_with_validations = []
@og = OwnershipGraph.new
```

It also calls `setup_builtins`, which registers stdlib functions, built-in
types, resources, and schemas into the root scope.

This is already useful, but it is also one of the messier boundaries: several
independent analyses share instance variables on `SemanticAnnotator`. The
long-term shape should be smaller phase objects with explicit inputs and
outputs, especially for call graph, effects, capabilities, and lock analysis.
Shared analyses that are consumed by both annotation and MIR live in
[`../semantic`](../semantic) rather than under MIR.

### 1. Entry Point

File: [`annotator.rb`](annotator.rb)

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

File: [`annotator.rb`](annotator.rb), `visit_Program`

The program walk is deliberately multi-pass:

```text
imports
  -> type declarations
  -> function and extern signatures
  -> union default method validation / synthesis
  -> reentrance bridge and error-type seeding
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
* [`annotator.rb`](annotator.rb)

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

The current implementation still has a difficult scope-copy contract:
`Scope#dup` deep-copies `SymbolEntry` values for nested branches. That isolates
branch-local state, but post-pass updates can make old nested references stale.
The current mitigation is to refresh through helpers such as
`Scope.live_param_syms`. This is a real architectural smell. A cleaner model
would split stable binding identity from branch-local flow state.

### 4. Function Signatures

Files:

* [`annotator.rb`](annotator.rb)
* [`helpers/function_signature.rb`](helpers/function_signature.rb)
* [`helpers/function_analysis.rb`](helpers/function_analysis.rb)

Function signatures are registered before function bodies are visited. During
`visit_FunctionDef`, the annotator:

```text
validates declared type annotations
  -> registers a FunctionSignature in the root scope
  -> records the FunctionDef in @fn_nodes
  -> analyzes params, captures, body, and returns
  -> records call graph and fallibility edges
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

File: [`annotator.rb`](annotator.rb)

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

* [`annotator.rb`](annotator.rb)
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
program_has_auto?
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

### 8. Capabilities and WITH Blocks

Files:

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
  -> validate target shape and sync/storage requirements
  -> declare aliases in a child scope
  -> visit guard predicates and body
  -> validate no guarded mutation invalidates predicates
  -> record lock/effect/capability audit facts
```

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

File: [`annotator.rb`](annotator.rb)

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
classify_bg_spawn_form!
check_lock_cycles!
compute_stack_tiers!
assign_fiber_stack_tiers!
```

The final `FunctionSignature` objects are updated with `can_fail`, `effects`,
and `stack_tier` so later callers and MIR passes do not need to inspect
`@fn_nodes` directly.

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

* [`annotator.rb`](annotator.rb): main visitor, top-level phase orchestration,
  declaration/call/control-flow typing, and many legacy checks.
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
  typing and aggregate operation checks.
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

* `SemanticAnnotator` owns too much mutable cross-pass state. Phase-specific
  state should move into typed context/result objects.
* Scopes deep-copy `SymbolEntry` objects, while later passes mutate canonical
  function parameter entries. This works only because some consumers refresh
  through helper APIs.
* Capability handling still mixes validation, alias construction, effect
  recording, audit, and lock graph updates in the same visitor path.
* Some MIR-facing facts are stamped directly on AST nodes from scattered helper
  code. The desired shape is a small number of authoritative outputs from
  `src/semantic` that lowering reads.
* `annotator.rb` is still a large visitor with many unrelated policy checks.
  More node families should move into focused helper modules or phase objects.

## Cleanup Direction

The highest-value cleanup is not a new grammar or a second type system. It is
to keep making existing phase boundaries explicit:

1. Split annotation state into typed phase contexts.
2. Replace remaining record-shaped hashes with typed structs.
3. Make capability transitions named operations on `Type` / `SymbolEntry`
   rather than open-coded field updates.
4. Centralize branch ownership state in `OwnershipGraph` and reduce direct
   symbol flag mutation.
5. Keep MIR-facing stamps small, documented, and produced by one authority.

The target architecture is simple: visitors resolve local syntax and stamp
local types; whole-program phase objects compute global facts; MIR consumes a
fully annotated AST without re-checking source-language semantics.
