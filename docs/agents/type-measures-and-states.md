# Compile-Time Measures and Typestates for CLEAR

Status: revised proposal; implementation decisions identified, no compiler implementation yet

Date: 2026-07-20

Related design:

- [Detailed numeric-measure design](type-measures.md)
- [Tense operation planning](tense-monads.md)
- [Generic and protocol design](generics.md)
- [F# units of measure](https://learn.microsoft.com/en-us/dotnet/fsharp/language-reference/units-of-measure)
- [Rust `uom`](https://docs.rs/uom/latest/uom/)

## Executive Decision

CLEAR should pursue two erased compile-time semantic features with related
surface syntax:

1. **Numeric measures**, such as `Float64|m/s^2|`.
2. **Nominal typestates/refinements**, such as
   `User|:valid, :authenticated|`.

They may share the `|...|` visual boundary, parsing infrastructure, semantic
type keys, formatting, and generic substitution. They must remain distinct
semantic domains:

- measures use dimensional algebra and exact rational scales;
- typestates use nominal state identities and flow-sensitive set logic.

The compiler must not implement one untyped "semantic tag" bag. A shared bag
would make invalid combinations easy to represent, obscure which operations
are legal, and force every consumer to rediscover whether a tag is algebraic
or nominal.

Both features erase from the stored representation after their obligations
have been discharged. Erasure does **not** mean every operation is zero-cost:

- carrying an already-proven measure or state has no runtime representation;
- converting scaled measures can emit arithmetic;
- validating a runtime value into a constrained state can emit a check and
  return a fallible result.

## Corrections to the Original Proposal

The following claims in the initial draft were incorrect or materially
incomplete and must not guide implementation.

| Original claim | Assessment | Corrected design |
| --- | --- | --- |
| Typestates are "GADTs" | Incorrect. A set of refinements attached to a value is not a generalized algebraic data type. | Call these nominal typestates or refinements. A future GADT feature would require constructors that refine indexed type parameters and substantially different inference. |
| One universal semantic-tag model handles measures and states | Too weakly typed. The notation can be shared, but the semantics cannot. | Use separate measure and state syntax/semantic nodes behind shared type-expression traversal. |
| Tags solve "Generic Infection" | Overstated. They avoid wrapper types and changing the base `STRUCT`, but relationships still need generics. | `FN sum<M: Measure>` remains necessary when the same measure must flow through inputs and outputs. |
| Field dependency preservation provides "90% of formal verification" | Unsupported and misleading. | It is a useful, conservative mutation-summary optimization. It proves only the declared invariant under the mutations and aliases the analysis models. |
| `ASSUME` is an infallible compile-time assertion | Incorrect. It proves nothing and can violate safety. | `ASSUME` must be explicitly unsafe, auditable, and allowed only in an `UNSAFE` context (or spelled `UNSAFE ASSUME`). |
| `TRY raw|:age|` is an adequate validation syntax | Ambiguous. It makes a runtime check look like a zero-cost suffix attachment. | Use an explicit operation such as `TRY VALIDATE raw AS Int64|:age|`. |
| The parser can classify a universal tag only from its base type | Fragile for generic and unresolved bases. | `:` makes state syntax distinct at parse time. Measure syntax receives a measure-formula node. Semantic validation later checks the applicable base type. |
| Inspecting AST/MIR is sufficient to preserve states across mutation | Incomplete for imports, externs, protocols, callbacks, recursion, and separate compilation. | Introduce typed, declaration-visible mutation summaries. Infer and verify them for local bodies. Treat unknown mutation conservatively. |
| A state proven on shared mutable data remains valid normally | Unsound after unlocking, suspension, alias mutation, or concurrent writes. | Refinements on mutable shared data are guard/snapshot-scoped unless the capability and mutation contract prove longer validity. |
| All semantic tags are always zero-cost | Incorrect for conversions and validation. | Proven tags erase; scale conversion and runtime validation may emit code. |
| The whole design costs 2,600-4,500 production LoC | Too low for sound aliases, branch joins, mutation summaries, capabilities, and concurrency. | Expect approximately 5,700-9,000 production LoC across three staged deliverables, plus 6,000-10,000 test/oracle LoC. |

## Scope and Non-Goals

In scope:

- exact numeric dimensions and scaled units;
- generic measure parameters;
- nominal state declarations and optional validation predicates;
- state requirements on parameters, returns, locals, and collection elements;
- conservative flow-sensitive state tracking;
- explicit proof acquisition, forgetting, and unsafe assertion;
- state invalidation across mutation;
- later field-sensitive preservation using mutation summaries;
- correct composition with tenses, collections, capabilities, generics,
  ownership, aliases, and concurrency;
- zero-overhead representation after validation/conversion.

Not in the initial implementation:

- GADTs;
- arbitrary theorem proving;
- dependent types;
- higher-kinded types or a public monad protocol;
- affine units such as Celsius/Fahrenheit points;
- runtime unit reflection or automatic unit selection;
- state-set generic variables without a concrete motivating use case;
- silently trusting a state in EASY mode.

## Authoritative Internal Model

### Syntax nodes

The type-expression tree should gain separate immutable syntax nodes:

```text
MeasuredTypeExpression
  base: TypeExpression
  formula: MeasureFormulaSyntax

StateRequiredTypeExpression
  base: TypeExpression
  states: ordered source list of QualifiedStateName
```

State order is retained for source rendering but normalized to a set for
semantic identity. Measure formulas are normalized to canonical dimension and
scale signatures during semantic resolution.

Both nodes participate in:

- recursive traversal and substitution;
- semantic keys;
- formatter and source spans;
- MessagePack/frontend handoff;
- import qualification;
- incremental fingerprints;
- fuzz generation and shrinking.

They must not be stored as capabilities. Measures/states describe semantic
meaning, not ownership, layout, synchronization, or visibility.

### Required states versus proven states

The compiler must distinguish:

- `RequiredStateSet`: part of a type at an API or storage boundary;
- `ProvenStateSet`: a flow fact currently known for a concrete place.

For example, `FN save(u: User|:valid|)` declares a required state. A local `u`
becoming valid in one control-flow branch updates the refinement environment;
it does not mutate the nominal `User` type globally.

The refinement environment should be immutable/persistent and keyed by stable
place identity. It may reuse the compiler's stable `PlaceId`, but it must not be
folded into the ownership graph. Ownership, lifetime, and state validity are
related analyses with different meanings.

### Semantic planning

Follow the architecture established by tense and lifecycle planning:

- annotation owns semantic decisions;
- annotation publishes immutable typed plans/facts;
- MIR consumes those decisions;
- MIR may validate a fingerprint but may not re-derive measure or state
  semantics from strings and booleans.

Use domain-specific planners:

- `MeasureOperationPlanner`;
- `MeasureConversionPlanner`;
- `StateValidationPlanner`;
- `StateTransitionPlanner`.

Do not create a universal planner that knows arithmetic, validation, tenses,
ownership, concurrency, and backend lowering.

## Phase 1: Numeric Measures and Generic Kinds

The detailed measure semantics in [type-measures.md](type-measures.md) remain
normative. This section records the decisions needed for staging and for
composition with typestates.

### Surface syntax

```clear
MEASURE Time;
MEASURE Length;

UNIT s: Time;
UNIT ms: Time = s / 1000;
UNIT m: Length;

delay: Float64|ms| = 10|ms|;
distance: Float64|m| = 12.5|m|;
speed: Float64|m/s| = distance / 2.0|s|;
```

### Canonical model

A resolved measured type contains:

1. a numeric storage type;
2. a canonical dimension signature, represented as base dimensions with
   integer exponents;
3. an exact rational scale relative to the canonical unit;
4. a source-facing formula for diagnostics/formatting where useful.

Exact rational arithmetic is compile-time only and resource-budgeted. The
frontend must cap formula nodes, exponent magnitude, dependency depth, and
rational numerator/denominator growth.

### Arithmetic

| Operation | Requirement | Result |
| --- | --- | --- |
| `+`, `-` | compatible dimension; explicit scale policy | chosen operand/canonical unit according to the declared conversion rule |
| comparisons | compatible dimension; explicit scale policy | `Bool` |
| `*` | numeric measured operands | multiplied dimensions and scales |
| `/` | numeric measured operands | divided dimensions and scales |
| integer powers | compile-time integral exponent | exponents multiplied by the power |
| cancellation | canonical exponent becomes zero | unmeasured numeric type |

No implementation may silently use floating-point scale factors in semantic
identity. Integer conversions must diagnose non-exact conversion and overflow.

### Generic-kind prerequisite

The current generic model treats every generic parameter and bound as an
ordinary type. Measures require an explicit parameter kind:

```clear
FN sum<M: Measure>(left: Float64|M|, right: Float64|M|)
  RETURNS Float64|M| ->
  RETURN left + right;
END

FN elapsed<M: Time>(value: Float64|M|) RETURNS Float64|M| ->
  RETURN value;
END
```

The implementation should add:

- `GenericParameterKind` with at least `type` and `measure`;
- typed `TypeGenericBinding` and `MeasureGenericBinding` products;
- one recursive substitution service over type expressions and measure
  formulas;
- canonical semantic-key equality for bindings;
- diagnostics for using a measure parameter in a value-type position or a
  type parameter in a measure formula.

`M: Measure` and `M: Time` are kind/dimension restrictions, not protocol
conformance. This cleanup is part of Phase 1 because implementing measure
generics as a magic protocol would create lasting debt.

Do not include existential protocol values, higher-kinded generics, or generic
state sets in this cleanup.

### Standard-library modes

Standard-library contracts contain their real units in every mode:

```clear
sleep(duration: Int64|ms|) RETURNS Void
```

| Mode | Unmeasured `sleep(10)` |
| --- | --- |
| EASY | accept using the API's declared legacy/default unit; autofix may add `|ms|` |
| DEFAULT | accept using the declared default; optional migration diagnostic |
| STRICT | fixable error requiring `sleep(10|ms|)` |

Contextual defaults apply only where an API explicitly declares one. They do
not generally turn unmeasured variables into measured values.

### Phase 1 acceptance

- Equivalent formulas have identical semantic keys.
- Invalid dimensions never reach MIR.
- Scaled conversions are exact or diagnosed.
- Generic measure relationships substitute and infer correctly.
- Measures nest inside every collection/type constructor and every legal tense.
- Formatter, imports, FFI, MessagePack, and incremental fingerprints agree.
- New production lines are strongly typed and have 100% changed-line coverage.
- Independent algebra/property tests cross-check normalization and conversion.

Estimated production work: **2,200-3,500 LoC**.

## Phase 2: Nominal Typestates and Conservative Invalidation

This phase is deliberately not called GADTs. It provides GADT-like ergonomic
benefits for stateful APIs, but it is a nominal refinement system.

### State declarations

```clear
STATE :valid FOR User REQUIRES _.id > 0;
STATE :authenticated FOR User;
STATE :sanitized FOR String;
STATE :age FOR Int64 REQUIRES _ >= 0 AND _ <= 120;
```

State identities are nominal, qualified names. The design must define import
and declaration coherence:

- a module may declare states for its own nominal types;
- extending foreign or primitive types requires an explicitly qualified state
  owned by the declaring module;
- two same-spelled states from different modules remain distinct;
- importing a state cannot retroactively change an existing type's semantics.

`REQUIRES` expressions must be pure, total, resource-budgeted predicates. They
may read only the validated value and approved pure helpers. They may not
perform I/O, mutate, suspend, capture changing state, or invoke an unknown
callback.

The compiler derives and records the predicate's field dependencies from the
restricted resolved predicate tree. It must not guess dependencies from text.

### Acquiring proof

Runtime validation is explicit and fallible:

```clear
raw: Int64 = read_age();
age: Int64|:age| = TRY VALIDATE raw AS Int64|:age|;
```

A literal/struct constructor may directly produce a state only if the compiler
can prove every declared predicate from compile-time-known fields. Otherwise
the programmer must validate it.

A state without `REQUIRES` has no synthesized validator. It is acquired only
from a function/constructor whose declared return type guarantees that state.

Unsafe assertion is explicit:

```clear
UNSAFE {
  valid = ASSUME raw AS User|:valid|;
}
```

`ASSUME` emits no check, must be searchable/auditable, and is unavailable in
safe code. EASY mode never inserts it.

### Compatibility and forgetting

State requirements use set inclusion:

- `User|:valid, :authenticated|` satisfies `User|:valid|`;
- a refined value may be read as plain `User` by forgetting proof;
- plain `User` cannot satisfy a refined requirement;
- assignment to explicitly plain storage forgets the state for that stored
  value;
- incompatible/exclusive states require declaration support before they are
  introduced; Phase 2 may initially reject declaring exclusivity.

For control-flow joins, the guaranteed state set is the intersection of the
states proven on every reachable incoming edge. Loops use a conservative fixed
point. Unreachable paths do not erase proof.

### Coarse invalidation

Phase 2 must be sound before it is smart:

- read-only use preserves proof;
- move transfers proof;
- a proven deep copy preserves proof when it copies all predicate-observed
  fields;
- an opaque mutation of a place or alias strips all states on that place;
- alias escape strips states unless the callee contract proves read-only use;
- unknown callbacks and extern calls conservatively invalidate affected
  places;
- suspension strips refinements that may be invalidated concurrently.

Current mutation syntax must be used consistently:

```clear
FN update_email(MUTABLE u: User) ->
  u.email = "new@example.com";
END

u: User|:valid| = TRY validate_user(get_user());
&update_email(u);
# Phase 2: u is now conservatively plain User.
```

The call-site marker is `&`; `update_email(MUTABLE u)` is obsolete syntax.

### Collections

`[]User|:valid|` means a collection whose elements require `:valid`.

Opaque in-place mutation of an element is rejected if it would leave an
unrefined value in refined storage. The programmer may:

- map into a new plain collection;
- explicitly forget the collection's element refinement using a defined cast
  operation;
- call an operation whose declared result restores the required state.

The language must define syntax for a state on the collection itself before
supporting it. `[]User|:nonempty|` already naturally attaches to the pivot
`User`, not the list layer. Collection-level states are deferred unless a clear
parenthesized or inline-layer syntax is approved.

### Tenses

Tenses remain outside the refined payload:

```clear
?User|:valid|   # optional validated User
!User|:valid|   # fallible validated User
~User|:valid|   # future yielding validated User
```

The tense planner treats the refined type as an opaque payload. `TRY`,
`UNWRAP`, `NEXT`, safe navigation, `~.`, and `OR_ELSE` remove/map/join tense
layers as they do today; ordinary type compatibility then computes the
guaranteed state-set intersection. No tense operation may silently add proof.

### Phase 2 acceptance

- Validation is explicit, fallible, and produces stable diagnostics.
- State requirements use sound subset compatibility.
- Branch, match, recovery, loop, tense, and async joins are conservative.
- Moves, copies, borrows, aliases, and opaque calls cannot retain invalid proof.
- Refined collection element storage remains invariant under mutation.
- EASY mode may suggest/insert validation but never invent proof.
- State facts remain an annotation refinement environment, not mutable global
  `Type` state.
- New production lines are strongly typed and have 100% changed-line coverage.

Estimated production work: **1,600-2,600 LoC**.

## Phase 3: Selective State Preservation Across Mutation

Phase 3 improves usability and precision without changing Phase 2's safety
model. Until this phase lands, all uncertain mutation remains conservatively
invalidating.

### Mutation summaries

Every callable needs an immutable typed summary capable of representing:

- no mutation;
- whole-place mutation;
- exact field/index paths written;
- unknown/opaque mutation;
- alias escape;
- callback-induced mutation;
- mutation through generic/protocol dispatch;
- state transitions or states guaranteed on return.

Local bodies infer summaries. Public declarations expose a stable contract,
and annotation verifies local implementations do not understate it. Externs,
function pointers, callbacks, protocol requirements, and unavailable imported
bodies require declared summaries or use `unknown`.

Recursive call graphs require SCC/fixed-point propagation. The summary belongs
in frontend semantic products and incremental fingerprints; it must not be
re-derived independently by MIR.

### Dependency-sensitive preservation

Given:

```clear
STATE :valid FOR User REQUIRES _.id > 0;
```

and a verified summary that `update_email` writes only `_.email`, the compiler
may preserve `:valid`. It may do so only when:

- the predicate dependency set is complete;
- no alias can write `_.id` during the proof's lifetime;
- no unknown callback or FFI operation receives an alias;
- no relevant interior-mutable/shared field can change concurrently;
- every dynamic dispatch target satisfies the same mutation contract.

If any proof is missing, Phase 2's coarse invalidation remains the fallback.

### Capabilities and concurrency

Typestate validity must respect CLEAR's synchronization model:

- local immutable values may retain states normally;
- `@alwaysMutable` fields invalidate dependent states unless the state is
  explicitly designed around the cell/version semantics;
- states observed through `WITH SNAPSHOT`, `WITH VIEW`, or a lock are normally
  scoped to that guard/view;
- releasing a guard invalidates proofs that concurrent writers can falsify;
- MVCC snapshot refinements apply to that immutable snapshot/version, not the
  current live object;
- crossing `BG`, callback, `NEXT`, or other suspension boundaries invalidates
  proofs for concurrently mutable places;
- shared immutable values can preserve proof;
- move/copy/share operations transfer proof according to ownership and
  lifecycle plans rather than ad hoc type copying.

State analysis consumes capability, alias, ownership, and suspension facts.
It must not duplicate their rules or add runtime reference counting merely to
keep a refinement alive.

### Phase 3 acceptance

- A mutation of an unrelated field preserves the state when—and only when—the
  complete summary proves it safe.
- Mutation through every alias, protocol implementation, callback, FFI call,
  generic call, and recursive SCC is covered conservatively.
- Lock/snapshot/view-scoped refinements expire at the correct boundary.
- Mutation summaries are independently testable, incremental, serializable,
  and consumed rather than rediscovered by MIR.
- Deleting Phase 3 precision must degrade to Phase 2 rejection/invalidation,
  never unsound acceptance.
- New production lines are strongly typed and have 100% changed-line coverage.

Estimated production work: **1,900-2,900 LoC**.

## Are These Three Even Parts?

They are close enough to be three independently shippable workstreams, but not
perfectly equal:

| Deliverable | Production LoC | Primary risk |
| --- | ---: | --- |
| 1. Measures + generic kinds | 2,200-3,500 | algebra, conversions, broad type integration |
| 2. Nominal typestates + coarse invalidation | 1,600-2,600 | flow joins, validation, alias conservatism |
| 3. Selective invalidation + concurrency | 1,900-2,900 | interprocedural mutation and capability soundness |
| **Total after expected shared-infrastructure overlap** | **5,700-9,000** | |

This is a clean semantic split:

1. Phase 1 is useful without typestates.
2. Phase 2 is safe and useful without selective preservation, although it will
   reject or forget proof more often.
3. Phase 3 only makes Phase 2 less conservative; it does not introduce the
   basic safety model.

The split is preferable to trying to land a universal tag system at once. It
allows the algebraic feature to harden first, establishes a deliberately
conservative typestate baseline second, and makes the most proof-sensitive
optimization independently reviewable last.

If CLEAR later wants actual GADTs, that is a separate fourth design. The
typestate syntax in Phase 2 neither requires nor implements GADT constructor
refinement or GADT pattern-match inference.

## Cross-Cutting Test Strategy

Each phase requires:

- parser/formatter round trips and malformed syntax diagnostics;
- semantic-key and serialization stability;
- independent pure semantic oracles;
- pairwise/three-way generated composition with collections, tenses,
  capabilities, tuples, unions, generics, functions, and FFI;
- transpile tests proving emitted Zig behavior;
- fuzz mutation/shrinking with permanent minimized regressions;
- EASY/DEFAULT/STRICT diagnostic and autofix tests;
- clean-build versus incremental equivalence;
- architecture invariants preventing MIR from invoking semantic planners or
  reconstructing tags from rendered strings;
- 100% changed-line coverage and Sorbet `typed: strict` production additions.

Phase 1 additionally needs algebraic/property tests for normalization and exact
rational conversion. Phases 2/3 additionally need control-flow, alias,
ownership, mutation, suspension, and concurrency state-machine generators.

## Final Recommendation

Proceed in the three phases above.

Measures are the right first feature because their semantics are local,
algebraic, independently testable, and already substantially designed. Include
the bounded generic-kind cleanup in that phase.

Then implement nominal typestates—not GADTs—with explicit validation and
deliberately coarse invalidation. That produces a sound, useful checkpoint and
reveals how often conservative invalidation actually hurts real programs.

Finally implement smart/selective preservation using verified mutation
summaries and capability-aware proof lifetimes. Keeping this last prevents an
optimization from being mistaken for the foundation of safety and makes it
possible to stop after Phase 2 if real-world evidence does not justify the
complexity.
