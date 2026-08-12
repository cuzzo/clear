# Typed IR Course Correction for Ruby-to-CLEAR

Status: accepted direction; implementation must follow the gates in this document

Date: 2026-07-13

Supersedes the source-workaround strategy in
`g2-g3-readiness-design.md`. That document remains the definition of the
verification gates and historical measurements, but its implementation order
is no longer current.

## Decision

Stop adapting compiler Ruby source to individual failures in generated CLEAR.
Build a single typed, ownership-aware Ruby-to-CLEAR intermediate representation
and make CLEAR emission mechanical.

The current direct AST-to-text pipeline spreads semantic decisions across
metadata collection, local analysis, call lowering, method registries, and
emission. Information is repeatedly inferred and then discarded. A local fix
can therefore make one generated call compile while changing unrelated G2 or
G3 behavior. The stalled G3 result and recent G2 regression are evidence that
this is now the limiting architecture, not a long tail of unusual Ruby syntax.

Until the typed IR reaches the migration gate below:

1. Do not add source-level helper methods solely to reveal a receiver type,
   union variant, ownership category, or emitted function name.
2. Do not loosen a Ruby/Sorbet type to `T.untyped` solely to make generated
   CLEAR compile.
3. Do not suppress a semantic method or dependency solely to avoid generated
   analysis.
4. Do not add `dup`, casts, or alternate control flow solely to induce `COPY`,
   narrowing, or static dispatch in emitted text.
5. Continue to accept genuine Ruby normalization when it is independently
   desirable and behavior-tested, but record why it is not a transpiler
   workaround.

## Evidence for the Change

The current failure sequence has repeatedly exposed the same lost facts:

- Optional values narrow in emitted `IF ... AS`, but the narrowed binding does
  not reliably carry its concrete type into method resolution.
- `T.cast`, `T.let`, Sorbet signatures, and `is_a?` constraints are interpreted
  by separate code paths and do not produce one durable type fact.
- Instance and class methods collide only after both have been flattened into
  global CLEAR functions.
- Qualified constants are recovered by suffix matching during call lowering
  instead of being resolved to symbols before lowering.
- Collection blocks and lambdas reconstruct element types, captures, and
  mutation independently from ordinary local analysis.
- `COPY` is selected during text generation, after getter, argument, and return
  categories have already been lowered.
- Ruby source helpers are being introduced to force a concrete union variant or
  method target that earlier analysis already knew.
- Sorbet struct fields can be mistaken for flattened instance methods, yielding
  calls to accessors that do not exist in CLEAR.

These are cross-cutting semantic failures. Fixing them at their individual
emission sites is expected to be slow and regression-prone.

## Target Pipeline

```text
Ruby AST + Sorbet declarations + dependency metadata
                         |
                         v
              Symbol and declaration graph
                         |
                         v
                Ruby normalization IR
                         |
                         v
              Typed Ruby-to-CLEAR IR
                         |
                         v
       flow narrowing + closure + ownership analysis
                         |
                         v
               validated lowered CLEAR IR
                         |
                         v
                 mechanical emission
```

The emitter must not perform symbol lookup, overload selection, constant suffix
recovery, receiver-type inference, union narrowing, capture discovery, or
ownership selection. If any required fact is missing, IR validation fails with
a source-located G1 diagnostic.

## Core Model

The implementation may use Ruby structs or classes initially; a large class
hierarchy is not required. The important constraint is that semantic identity
is explicit and stable.

### Symbols and declarations

Every declaration receives a globally unique `SymbolId`, independent of its
eventual CLEAR spelling. A declaration records:

- Ruby qualified name and source location;
- declaration kind: type, field, instance method, class/module method, local,
  parameter, constant, or generated helper;
- owner symbol and dependency unit;
- Sorbet signature and normalized CLEAR signature;
- mutability and visibility;
- a globally unique emitted name assigned once by the naming pass.

Calls and field accesses refer to `SymbolId`, never to a string that must be
looked up again. Instance and class methods with the same Ruby name are distinct
before naming, so flattening cannot create a late collision.

### Types

Use one canonical type algebra throughout normalization, analysis, and
lowering. At minimum it must represent:

- concrete nominal types;
- optionals;
- unions with explicit variants;
- arrays, hashes, tuples, and procs;
- type parameters where statically useful;
- `Any` only for a deliberate dynamic boundary;
- `Unknown` as an analysis error state, never an emitted type.

Type facts carry provenance: signature, constructor shape, literal, field,
flow constraint, cast, or fallback. A `T.cast` changes the typed IR operand;
it is not merely an emitter hint. Optional and union narrowing produce scoped
bindings with concrete types.

### Values and ownership

Every expression has a `ValueInfo`:

- canonical type;
- value category: place or value;
- access: borrowed, mutable borrowed, or owned;
- copyability and move state;
- source location;
- optional constant value.

Every call argument and return edge has a required ownership mode. The
ownership pass inserts explicit IR operations such as `Borrow`, `BorrowMut`,
`Copy`, and `Move`. Emission prints those decisions; it does not make them.

### Calls and fields

A resolved call contains:

- concrete target `SymbolId` and emitted name;
- dispatch kind: free, instance, class/module, intrinsic, native, or explicitly
  dynamic;
- typed receiver, if any;
- typed positional and keyword arguments;
- normalized block/closure argument;
- parameter-to-argument mapping;
- return type and effects;
- ownership requirements for receiver, arguments, and result.

A field read or write is a distinct IR operation with a resolved field
`SymbolId`; it is never represented as a zero-argument method call. Sorbet
`const` and `prop`, `Struct.new` fields, and ordinary instance fields therefore
share one field representation.

### Control flow and narrowing

Build a control-flow graph per function. Each basic block has an input type
environment, and branch edges carry constraints. The merge operation must be
explicit and tested.

Required constraints include:

- non-`nil` checks and optional binding;
- `is_a?` and supported predicate helpers;
- `T.cast` and `T.must`;
- enum and union variant tests;
- truthiness where it narrows an optional;
- early `return`, `next`, `break`, and raising edges.

The narrowed value is a new SSA-like binding or equivalent versioned local.
Downstream call resolution consumes that binding's concrete type directly.

### Closures and blocks

Normalize literal blocks, lambdas, and supported block forwarding into one
closure representation. A closure records typed parameters, result type,
nonlocal control-flow behavior, captures, and capture mode. Capture and
mutation analysis runs once after normalization and before ownership analysis.

Collection operations may lower to intrinsics or explicit loops, but both must
consume the same analyzed closure. Method-specific emitters must not rediscover
block parameter types or mutation.

## Passes and Invariants

### 1. Declaration collection

Collect declarations and dependency edges for the complete compilation closure.
Resolve aliases and constructors without lowering executable bodies.

Invariant: every statically declared type, method, field, constant, and
constructor has one `SymbolId`; duplicate Ruby names remain distinct by owner
and declaration kind.

### 2. Ruby normalization

Convert Prism-specific shapes into a smaller semantic vocabulary. Normalize
safe navigation, modifier conditionals, supported rescue forms, keyword
arguments, collection blocks, and Sorbet constructs while preserving source
locations.

Invariant: later passes do not branch on Prism node classes except through an
explicit escape hatch that fails validation.

### 3. Resolution and initial typing

Resolve constants, fields, constructors, and method candidates against the
declaration graph. Apply signatures and parameter mapping.

Invariant: every static call and field access has a concrete target. Ambiguous
or dynamic operations are explicit IR nodes with a documented policy; they are
not guessed during emission.

### 4. Flow typing and narrowing

Build control flow, apply constraints, version locals, and compute block input
and output environments.

Invariant: a use has one canonical type at its program point. `Unknown` cannot
leave this pass.

### 5. Closure analysis

Compute captures, mutation, escape behavior, and nonlocal control flow for all
closures.

Invariant: each capture has exactly one mode and its enclosing local has a
consistent mutability decision.

### 6. Ownership analysis

Apply receiver/parameter/return contracts and insert explicit borrow, copy, and
move operations. Validate use-after-move and mutable aliasing before emission.

Invariant: every value edge satisfies its destination ownership requirement;
the emitter never inserts an unplanned `COPY`.

### 7. Naming and lowered-IR validation

Assign deterministic globally unique names, finalize dependencies, and validate
that all referenced symbols and types are reachable.

Invariant: emitted names are collision-free, every referenced declaration is
local or imported, and no naming lookup remains for the emitter.

### 8. CLEAR emission

Render validated IR to CLEAR. This pass may choose whitespace and parentheses,
but not semantics.

Invariant: emission is deterministic and side-effect free. Re-emitting the same
IR produces identical bytes.

## Repository Boundaries

The current components should migrate as follows:

| Current component | New responsibility |
| --- | --- |
| `metadata_collector.rb` | Populate declarations and dependency metadata. |
| `type_env.rb` | Become or feed the canonical type environment; remove parallel ad hoc type stores. |
| `local_analyzer.rb` | Feed CFG and closure analysis; stop independently deciding emission details. |
| `method_registry.rb` | Describe normalization/intrinsic semantics, not emit final CLEAR strings. |
| `call_lowerer.rb` | Resolve calls into typed call IR; no suffix recovery or text-level dispatch guessing. |
| `transpiler.rb` | Orchestrate passes and emit validated IR; shrink as logic moves to explicit passes. |

Compatibility adapters are acceptable during migration, but an adapter must
produce or consume typed IR. New semantic decisions must not be added to the
legacy string-emission path.

## Migration Plan

### Phase 0: Freeze and classify recent changes

Before more coverage work, classify each uncommitted/recent change as:

1. infrastructure needed by the typed pipeline;
2. independently valid Ruby normalization with behavior tests;
3. source workaround for lost type, target, narrowing, capture, naming, or
   ownership information;
4. unrelated user change.

Revert category 3 in coherent batches after the corresponding typed-IR fixture
exists. Preserve category 4. Do not perform a blanket reset of the dirty tree.

### Phase 1: Vertical slice

Implement a narrow end-to-end slice for functions, locals, Sorbet struct
fields, optionals, direct calls, and returns. It must handle these regression
fixtures before broad migration:

- optional `FailureAction?` narrowed to `FailureAction`, followed by a resolved
  instance call;
- `T.cast` inside a collection block preserving the element's concrete type;
- a Sorbet `prop` read/write emitted as field access, not a flattened function;
- same-named instance and class methods receiving distinct emitted names;
- qualified constants resolved without suffix matching;
- an owned parameter receiving an explicit `Copy` selected by ownership
  analysis;
- a lambda that mutates a capture and an instance field.

The legacy path may remain for nodes outside the slice, but a function is
lowered wholly by one path. Do not interleave typed and string lowering inside
one function.

### Phase 2: Blocks, unions, and constructors

Add arrays/hashes/tuples, collection blocks, union variants, constructor shapes,
and module functions. Port the compiler closures with the highest dependency
fan-out first.

### Phase 3: Ownership-complete calls and control flow

Add full parameter ownership contracts, branch merges, loops, early exits, and
supported rescue/cleanup forms. Remove emitter-time `COPY` heuristics as their
typed equivalents land.

### Phase 4: Retire legacy inference

Delete suffix-based constant recovery, late global-name collision recovery,
parallel block mutation discovery, and receiver-type rediscovery only after
equivalent typed-IR tests and corpus results pass.

## Verification Strategy

Use three layers:

1. IR unit tests assert resolved symbols, canonical types, narrowed bindings,
   captures, and ownership operations without comparing emitted text.
2. Golden emission tests assert mechanical CLEAR output for validated IR.
3. The existing 169-file verifier measures raw G1/G2/G3/G4 behavior on fresh
   artifacts.

Each implementation batch must include:

- a minimized regression fixture for the semantic fact being preserved;
- IR assertions and raw generated-CLEAR compilation;
- a clean full verifier report when the change can affect shared lowering;
- a report diff listing improved and regressed units by gate and source LoC.

No batch is accepted if G2 or G3 source LoC decreases without an explicit,
reviewed reason. Autofix-assisted output remains diagnostic only.

## Milestones and Exit Gates

### M1: Typed vertical slice

- All seven vertical-slice fixtures pass IR validation and raw G3.
- The emitter performs no call-target, narrowing, field/method, capture, or
  ownership inference for migrated functions.
- No compiler Ruby source helper is needed for those fixtures.

### M2: Dominant closure migrated

- One high-fan-out compiler dependency closure is wholly lowered through typed
  IR and passes raw G3.
- The closure contains optionals, Sorbet structs, blocks, unions, and ownership
  transfers.
- Legacy lowering is not invoked within migrated functions.

### M3: G3 above 50% source LoC

- A fresh 169-file run reports raw G3 source LoC strictly greater than 50%.
- G2 is not below the pinned pre-course-correction baseline.
- No systemic fingerprint affects more than five units in the migrated subset.
- The report and immutable artifacts are retained.

M3 is the immediate coverage objective. Work is prioritized by dependency
fan-out and shared semantic failure, not by the next textual compiler error.

### M4: Readiness threshold

Resume the readiness gates from `g2-g3-readiness-design.md`: at least 90% G2
source LoC/85% files and 75% G3 source LoC/70% files, with missing dependency
closures and systemic fingerprints bounded as specified there.

## Review Checklist

Reject a proposed fix when any answer below is "yes":

- Does it change compiler Ruby solely to influence generated CLEAR typing or
  ownership?
- Does the emitter need to look up a receiver, constant, method, or field by
  string?
- Does a call lack a concrete target before emission?
- Is a cast or narrowing fact represented only in generated syntax?
- Is closure mutation recomputed by a method-specific lowering?
- Is `COPY` chosen without a recorded ownership requirement?
- Can a naming collision be discovered only after emission begins?
- Does `T.untyped` conceal an `Unknown` analysis result?

If so, put the missing fact in the typed IR or the appropriate analysis pass.

## Immediate Next Actions

1. Stop the current `mir.rb` first-error compile loop.
2. Preserve the current dirty tree and classify changes; do not overwrite user
   work or verifier baselines.
3. Add the typed IR core records and validator behind an opt-in function-level
   path.
4. Implement the M1 fixtures, beginning with narrowed optional dispatch and
   Sorbet struct field access.
5. Migrate one high-fan-out dependency closure and run a fresh verifier.
6. Continue by blast radius until raw G3 source LoC exceeds 50%.
