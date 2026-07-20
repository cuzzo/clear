# Tense Algebra and Authoritative Operation Planning

Status: implemented and validated; Decisions A and B are resolved below

Date: 2026-07-19

Scope: `?`, `!`, and `~` type semantics; annotation-to-MIR handoff; optional,
fallible, and asynchronous composition; tense-preserving navigation (`?.`,
`!.`, and `~.`)

## Executive Decision

CLEAR should not add a public `Monad` protocol, higher-kinded generic
machinery, or nominal `Option`/`Result`/`Future` replacements now.

The existing tense syntax and direct Zig representations are a good fit for
CLEAR. They provide the useful parts of monadic programming--construction,
mapping, propagation, recovery, and explicit composition--while preserving
the ownership, synchronization, suspension, and diagnostic facts that matter
to CLEAR. A generic monad abstraction would not improve generated code and
would make those facts harder to see.

The worthwhile change is internal: make the existing tense algebra explicit
and give every tense-changing operation one semantic authority. Annotation
should produce a strongly typed `TenseOperationPlan`; MIR should consume that
plan instead of independently inspecting `optional?`, `error_union?`, and
`future?` and reconstructing what the source operation meant.

Implementation resolved the two language questions as follows:

1. whether failure produced inside `BG` is represented as `~!T`, so `NEXT`
   produces `!T`, or is an implicit property of resolving every `~T`; and
2. whether `TRY ?T` intentionally converts absence into a propagated error, or
   whether `TRY` removes only `!` and optionality is handled by `UNWRAP`, safe
   navigation, predicates, or `OR_ELSE`.

CLEAR now preserves explicit `~!T` for a fallible asynchronous computation.
`NEXT ~!T` produces `!T`, so completion failure is neither hidden nor moved to
task construction. For compatibility with the deliberately accepted language
algebra, `TRY ?T` remains valid and converts absence into a propagated
`error.TryOptional`; `UNWRAP` remains the operation that removes optionality
without changing its meaning. Both decisions are executable specifications,
not backend accidents.

This revision also proposes tense-preserving navigation. Just as:

```clear
name = maybeFoo()?.name       # ?String
```

maps member access over an optional value, CLEAR should support:

```clear
name = streamFoo()~.name      # ~String, when streamFoo() returns ~Foo
```

`~.` does not perform `NEXT`. It constructs a derived future that maps the
member access over the eventual payload. The spelling is intentionally
visible because it preserves asynchronous execution rather than suspending the
current flow. Ordered combinations preserve every layer:

```clear
name = futureResult()~!.name  # ~!String from ~!Foo
name = startTask()!~.name     # !~String from !~Foo
name = futureMaybe()~?.name   # ~?String from ~?Foo
```

The order is semantic. `!~T` means that producing the future can fail now;
`~!T` means that the future can complete with failure later. The planner must
therefore preserve ordered layers rather than reducing tense to three boolean
flags.

## Why This Is Not a Monad Project

A conventional monad supplies a type constructor `M<T>`, an injection such as
`pure(T) -> M<T>`, and a composition operation equivalent to:

```text
bind: M<T>, (T -> M<U>) -> M<U>
```

It must be possible to discuss `M<M<T>>`, and the operations must satisfy
identity and associativity laws.

CLEAR deliberately has different semantics:

- `??T`, adjacent `!!T`, and `~~T` are rejected rather than retained as
  observably nested states;
- optionality and fallibility widen as idempotent facts over one payload;
- asynchronous state is never implicitly introduced or crossed;
- `OR_ELSE` may recover both layers of `!?T` with one fallback;
- `TRY ?T` currently changes absence into failure rather than staying within
  the optional effect;
- `SELECT:!`, `SELECT:?`, and `SELECT:!?` retain effects on individual
  collection elements;
- `NEXT` may consume an affine handle, may preserve a shared handle, and always
  represents a suspension boundary; and
- capabilities can attach independently to a tense layer, collection layer,
  or payload.

Failure on both sides of one future is not an adjacent duplicate. `!~!T` has
two observable failure boundaries: construction can fail before a future
exists, and the future can later resolve to a failure. Collapsing those layers
would change when and where `TRY` or `OR_ELSE` runs.

This is more accurately a small, ordered effect algebra. Inference already
uses a commutative, associative, idempotent join for the allowed absence and
failure states:

| Inputs over the same payload | Joined result |
| --- | --- |
| `T`, `T` | `T` |
| `T`, `?T` or `T`, `NIL` | `?T` |
| `T`, `!T` | `!T` |
| `?T`, `!T` | `!?T` |

Future state is intentionally not a widening bit. `T` and `~T` do not join,
and the compiler must not insert an implicit `BG` or `NEXT`.

The algebra should be designed and tested deliberately, but calling it a
monad would imply general nesting and generic composition that CLEAR neither
implements nor presently wants.

## Current Representation

The structural foundation is already suitable. `TypeExpression` has distinct
immutable nodes for:

```text
Optional(inner, capabilities)
Fallible(inner, error_set, capabilities)
Future(inner, capabilities)
Stream(cardinality, item, capabilities)
```

The tree can represent ordered wrappers, and that order must remain semantic:

```text
Fallible(Future(payload))             # !~T: start can fail now
Future(Fallible(payload))             # ~!T: completion can fail later
Fallible(Future(Fallible(payload)))   # !~!T: both boundaries can fail
```

The supported scalar surface is deliberately constrained rather than an
arbitrary wrapper language:

```text
without a future: T, ?T, !T, !?T
with a future:    ~T, ~!T, ~?T, ~!?T,
                  !~T, !~!T, !~?T, !~!?T
```

Optionality remains innermost, a future appears at most once, and fallibility
may appear once on either side of the future. Thus `?~T`, `!?~T`, `~?!T`,
`~~T`, and adjacent `!!T` remain invalid. This is a 12-state ordered algebra,
not the previous eight-state canonical envelope.

Streams are collection nodes and stay outside this planner's scalar temporal
model. Their item type may contain `?` or `!`, but completion is represented by
`StreamStep<T>` rather than by silently adding another optional layer.

The problem is not primarily representation. It is that consumers repeatedly
decode the representation:

- 22 annotator files directly query at least one tense predicate;
- 15 MIR files directly query at least one tense predicate;
- annotation contains 47 `.optional?`, 49 `.error_union?`, 23 `.future?`, and
  11 `recoverable_result_type` references; and
- MIR contains 40 `.optional?`, 26 `.error_union?`, and 6 `.future?`
  references.

Many of those uses are legitimate representation, ownership, or cleanup
queries. The problematic subset makes semantic decisions a second time--for
example, deciding which layer `TRY` removes, whether an `OR_ELSE` is an error
catch or optional fallback, or what `NEXT` returns. That subset should have one
owner.

## Relationship to `easy-vm-testing/fv`

The `fv` branch was audited at commit `3a0e2afd8` on 2026-07-19. Its committed
work does not make this design unnecessary, but it changes the required model
and provides useful executable specifications.

| `fv` work | Relationship to this design | Required treatment |
| --- | --- | --- |
| Exact `SELECT` modifier order, including `!~`, `~!`, and `!~!` | Conflicts with the old canonical eight-state envelope; confirms that wrapper order is observable | Adopt the ordered 12-state algebra in this document |
| `SelectTenseSemantics` independent oracle and the 56-cell SELECT matrix | Strong, reusable characterization | Retain/adapt these tests as planner oracles |
| `declared_async_payload` and `retain_error_channel` preserve `~!T` through `BG` and lowering | Aligns with explicit asynchronous failure, but communicates it through mutable AST flags | Treat as migration evidence; replace flags with a typed operation plan |
| Parser and pipeline code split and reconstruct modifier strings | Conflicts with the single-authority goal | Replace with parsed tense layers and planner output rather than copying this technique |
| Stream cardinality and SELECT lowering tests | Align with keeping streams separate from scalar futures | Retain and extend |

There is also a concrete inconsistency on `fv`: the specialized SELECT parser
accepts ordered forms such as `!~T`, while `Type#from_core` and existing
type-expression tests still reject `!~T` in favor of `~!T`. Pipeline analysis
and MIR inspect or split `modifier_order` strings to recover semantics. That is
exactly the kind of cross-phase re-derivation this planner is intended to
remove. The branch is therefore a valuable source of semantics and tests, not
the final architecture for tense composition.

The audit excludes uncommitted files in the `easy-vm-testing` checkout. Before
implementation, either rebase onto the committed `fv` work or transplant its
oracles first. Do not independently implement a competing SELECT matrix, and
do not preserve its temporary AST flags merely for compatibility.

## Existing Semantics and Divergences

### Optional `?T`

Monad-like behavior already present:

- a definite `T` can widen to `?T`;
- safe navigation maps an operation over the present payload;
- `OR_ELSE` supplies a default;
- `EXISTS AS` refines and binds the payload; and
- optionality composes with fallibility, futures, collections, tuples, and
  capabilities.

Non-monadic behavior:

- `??T` is forbidden, so `Some(None)` and `None` cannot be distinct states;
- optionality participates in a widening lattice;
- one `OR_ELSE` over `!?T` recovers absence and failure together; and
- `TRY ?T` currently emits `orelse return error.TryOptional`, converting one
  effect into another.

### Fallible `!T`

Monad-like behavior already present:

- errors are returned by value with no stack unwinding;
- `TRY` propagates failure and produces the success payload;
- `OR_ELSE` recovers or propagates;
- `IS_OK` tests the outer failure state; and
- `T` can widen to `!T` where an expected fallible contract exists.

Non-monadic behavior:

- `!T` is not generally `Result<T, E>` with a visible arbitrary `E`;
- the `error_set` syntax-tree field is not yet the complete source of runtime
  error identity and kind;
- compiler/runtime allocation failure can be recoverable at an `OR_ELSE`
  boundary without making the expression's source type `!T`;
- `can_fail` is an operational effect and is intentionally broader than a
  source-level error-union value; and
- `!!T` is forbidden.

### Future `~T`

Monad-like behavior already present:

- `BG` constructs an asynchronous computation;
- `NEXT` resolves it;
- pipelines map, filter, collect, and traverse async sources; and
- `~!T` and `~?T` are structurally representable.

Non-monadic behavior:

- plain promises are affine and `NEXT` consumes them exactly once;
- `~T@shared` changes resolution into a memoized, non-linear operation;
- resolving is a scheduler suspension point, not a value-only transformation;
- cancellation and task lifetime are not expressible by a generic `bind`;
- streams have cardinality and completion semantics beyond `Future<T>`; and
- `~~T` is forbidden.

Most importantly, the runtime `Promise(T)` always stores an `anyerror!T`, while
current `BG` annotation strips a leading `!` from the body's final value and
stamps the source result as `~T`. Thus a surface `~T` can have a failing
resolution path. `~!T` has parser, type, and Zig-rendering coverage, but it
does not yet have equivalent end-to-end coverage proving construction,
resolution, propagation, ownership, and recovery together.

## Resolved Language Decisions

### Decision A: failure inside `BG`

#### Option A1: explicit asynchronous outcome--accepted

```text
BG body returns T    -> ~T
BG body returns !T   -> ~!T
NEXT ~T              -> T
NEXT ~!T             -> !T
TRY NEXT future      -> T, propagating failure
```

This preserves every effect layer and makes the failure visible before a
caller chooses to resolve the task. It agrees with the principle that an
inferred binding must not silently retain a fallible value.

There are two distinct failure times and they must not be conflated:

1. failure to construct/schedule the task; and
2. failure of the computation after the task exists.

The first remains an operational effect of the `BG` expression under CLEAR's
existing allocation-fault policy. The second belongs in the future payload as
`~!T`. If the allocation-fault policy later becomes source-visible, it needs a
separate design; it must not be smuggled into or out of the payload tense.

This does not forbid a declared `!~T`. A function may perform fallible
validation or resource acquisition before it successfully returns a future;
that source-level outer `!` is distinct from an undeclared scheduler allocation
fault. `TRY startTask()` consumes the outer failure and returns `~T`. A
subsequent `NEXT` crosses the temporal boundary. For `!~!T`, those operations
expose the inner failure only after resolution.

The Zig runtime may continue storing `anyerror!T` internally for a plain
promise. Backend representation is not source semantics. The operation plan
must distinguish an expected source failure from an impossible/internal
runtime failure and ensure only declared failure reaches normal source-level
recovery.

#### Option A2: every resolution is implicitly fallible--rejected

Under this model `NEXT ~T` is operationally fallible even though it is stamped
as `T`, and `~!T` represents a second payload-level failure.

This reflects the current runtime more closely but is not recommended. It
creates two failure authorities, weakens inferred-binding rules, complicates
function effect reporting, and makes `~!T` difficult to explain. It would also
make a generic future combinator appear type-preserving while quietly adding a
failure edge.

#### Decision-A acceptance tests

- an infallible `BG` resolved by `NEXT` returns `T`;
- a fallible body infers or requires `~!T` according to the language's normal
  explicit-contract rules;
- `NEXT ~!T` returns `!T`, not `T` and not `!?T`;
- inferred assignment of that result produces the normal fixable fallible
  binding error;
- `TRY NEXT`, `NEXT ... OR_ELSE`, and retained `value:! = NEXT ...` all work;
- affine, shared, FSM, stackful, and bytecode paths agree;
- cancellation has a declared placement in the model; and
- generated Zig does not acquire a nested accidental
  `anyerror!anyerror!T` contract.

### Decision B: whether `TRY` crosses optionality

#### Option B1: one operator removes one layer--not selected

```text
TRY !T       -> T, propagating failure
TRY !?T      -> ?T, propagating failure
UNWRAP ?T    -> T under the separately defined absence policy
OR_ELSE      -> local recovery
?.           -> optional mapping
```

`TRY ?T` would be a fixable error explaining that the operand is optional, not
fallible. This gives every operator one meaning and makes stacked operations
read outside-in.

The exact runtime meaning of `UNWRAP` must be documented before this option is
implemented. In a safety-focused language it should not be an unexplained
panic. Viable policies are:

- require proof/refinement that the value is present;
- convert absence into a declared failure that can be retained or propagated;
  or
- reserve a visibly unsafe/asserting spelling for a trapping unwrap.

That decision is adjacent to this design but must not be hidden inside the
planner migration.

#### Option B2: preserve `TRY ?T -> T`--accepted

This keeps existing `TRY values[index]` behavior and translates absence to the
synthetic `TryOptional` error. If retained, the language must say explicitly
that `TRY` means "propagate the outer recoverable state," not "remove the
fallible layer." The planner must then model the effect conversion:

```text
input presence: optional
output presence: definite
propagation: raise TryOptional
enclosing function requirement: fallible
```

This is the implemented rule. It is coherent, but it is not ordinary monadic
composition and is not described as such. `TRY` means “propagate the outer
recoverable state”; `UNWRAP` remains the explicit optional-removal operation.

#### Decision-B acceptance tests

- the selected meaning of `TRY ?T` has one diagnostic and one lowering path;
- `TRY !?T` leaves `?T`;
- `TRY UNWRAP !?T` has a documented outside-in interpretation;
- safe navigation never becomes a propagating unwrap;
- optional list/map indexing follows the same rule as any other `?T`;
- ownership and borrow provenance survive either operation; and
- no MIR node chooses between `TryExpr` and `TryOptional` by inspecting the
  type again.

## Implemented Semantic Model

### Tense envelope view

Do not add a second type representation. Add a typed, immutable view over the
existing `TypeExpression` tree:

```text
TenseEnvelope
  layers: Array<TenseLayer>  # exact outer-to-inner order
  payload: TypeExpression

TenseLayer
  Future(capabilities)
  Fallible(error_set, capabilities)
  Optional(capabilities)
```

Construction must validate the constrained grammar and reject repeated or
misplaced layers. It must retain the original child expressions and per-node
capabilities; it must never round-trip through `Type#to_s`, a legacy Symbol,
SELECT modifier strings, or Zig rendering. Convenience predicates may be
derived from `layers`, but they are not stored as independent booleans.

The validator permits `!~!T` because the two failure layers belong to distinct
temporal boundaries. It rejects arbitrary nominal nesting and never flattens
ordered failures merely because both happen to lower to Zig error unions.

`StreamTypeExpression` is not converted into `temporal: future`. The planner
may inspect a stream operation through a separate `StreamOperationContext`,
but cardinality and completion remain collection semantics.

### Operation enum

Use a closed, strongly typed operation set:

```text
try
unwrap
next
or_else_value
or_else_raise
or_else_exit
or_else_pass
or_else_break
or_else_prune
is_ok
exists
tense_navigation(navigation_layers)
select_definite
select_fallible
select_optional
select_fallible_optional
async_join
```

Special `OR_ELSE` actions stay explicit because they have different control
flow, result, and loop/function requirements. They should not be encoded as a
nullable `fallback_kind` plus booleans.

### Planner input

```text
TensePlanner.plan(
  operation,
  input_type,
  fallback_type?,
  expected_type?,
  source_kind?,
  capability_context?,
  control_flow_context?
) -> TenseOperationPlan | diagnostic
```

The planner owns semantic classification. It does not own name lookup,
function-effect fixed points, ownership graph mutation, scheduler selection,
or backend emission. Callers must resolve those inputs before invoking it.

### Operation plan

The result should be a strongly typed immutable product, conceptually:

```text
TenseOperationPlan
  operation
  input_type
  result_type
  consumed_layers
  preserved_layers
  navigation_layers
  propagation: none | failure | absence_as_failure | task_failure
  recovery: none | fallback | propagate | exit | pass | break | prune
  handle_use: none | consume | shared_read | stream_advance
  suspends: Bool
  may_terminate_current_flow: Bool
  fallback_conversion?
  backend_form
```

`backend_form` is a closed semantic tag such as `zig_try`, `zig_orelse`,
`promise_next`, `future_map`, `shared_future_map`, or `stream_next_step`. It
must not contain source fragments or rendered Zig. Backend-specific allocation
names, temporary identifiers, continuations, and cleanup statements remain
MIR-lowering concerns.

The plan must expose facts needed by ownership and effect analysis rather than
causing those phases to rediscover the input shape:

- whether an affine handle is consumed;
- whether the result retains source borrow/storage provenance;
- whether execution suspends;
- whether control can propagate out of the current function;
- whether a fallback handles failure, absence, or both; and
- which tense layers remain on the resulting value.

### Plan storage and handoff

Annotation should store plans in a typed `TensePlanTable` keyed by stable AST
node identity, or in an equivalent typed phase product already passed to MIR.
Do not add an untyped hash and do not make MIR call the planner again.

MIR receives the exact annotation plan. It may validate that the current
node/type fingerprint still matches the plan, but it may not select behavior by
calling `optional?`, `error_union?`, or `future?` again. A mismatch is an
internal compiler error, not a compatibility fallback.

This follows the same single-authority rule used by lifecycle planning:
semantic lowering consumes a plan; it does not reconstruct one from partial
facts after context has been lost.

## Operation Semantics

### `TRY`

The plan determines:

- the exact outer recoverable layer consumed;
- the result type after that layer is removed;
- whether failure propagates from the current function;
- whether storage/borrow provenance remains transparent; and
- whether lowering uses `TryExpr` or the explicitly approved
  absence-to-failure operation.

The annotator must not stamp one result while MIR independently decides
between `TryExpr` and `TryOptional`.

### `UNWRAP`

The plan removes only the optional layer selected by the language decision. It
preserves an outer failure layer and the payload's capabilities and placement.
It records the chosen absence behavior explicitly: proven, propagated,
recovered, or trapping. MIR must never infer that behavior from token shape.

### `NEXT`

The plan distinguishes:

- affine promise consumption;
- shared-promise resolution;
- promise-list collection;
- observable materialization;
- bounded/open/infinite stream advancement; and
- canonical `StreamStep<T>` completion.

It returns both the source-level result type and the handle-use/suspension
facts. Allocation placement and concrete runtime calls remain in concurrency
lowering.

### `OR_ELSE`

The planner receives both operand types and the explicit recovery form. It
validates that the left side is recoverable, identifies whether failure,
absence, or both are handled, checks fallback compatibility, and returns the
post-recovery type.

Operational allocation faults must enter through an explicit input fact. They
must not be confused with source-level `!T` merely because both lower to a Zig
`catch`.

### `IS_OK` and `EXISTS`

Both return `Bool` but refine different layers:

- `IS_OK` observes failure and may bind the success value with optionality
  preserved;
- `EXISTS` observes optionality or `StreamStep` item state and may bind the
  present payload with fallibility preserved.

The plan should describe the refinement binding type so predicate analysis
does not peel the stack independently.

### Tense-preserving navigation: `?.`, `!.`, and `~.`

All three operators are mapping operations, not layer removal:

| Operator | Receiver boundary | Result behavior |
| --- | --- | --- |
| `?.` | optional | Access only when present; preserve `?` |
| `!.` | fallible | Access only on success; preserve that `!` and its error set |
| `~.` | scalar future | Create a derived future; access after resolution; preserve `~` |

The marker sequence must exactly match every tense layer between the receiver
expression and its payload. It is parsed and validated as one ordered postfix
operator, even if the lexer represents it as several punctuation tokens:

```clear
plain.name                  # T -> Field
maybe?.name                 # ?T -> ?Field
fallible!.name              # !T -> !Field
future~.name                # ~T -> ~Field
futureResult~!.name         # ~!T -> ~!Field
startResult!~.name          # !~T -> !~Field
futureMaybe~?.name          # ~?T -> ~?Field
startFutureMaybe!~?.name    # !~?T -> !~?Field
bothFailures!~!.name        # !~!T -> !~!Field
allLayers!~!?.name          # !~!?T -> !~!?Field
```

The complete valid navigation-marker set is:

```text
?., !., !?.,
~., ~!., ~?., ~!?.,
!~., !~!., !~?., !~!?.
```

Ordinary `.` covers the definite case. Invalid type orders have matching
invalid navigation orders: `?!.`, `?~.`, `!?~.`, `~?!.`, `~~.`, and adjacent
`!!.` are rejected. A marker that skips an intervening layer is also rejected;
for example, `~!Foo` requires `~!.name`, not `~.name`, because member access
cannot be performed directly on an unresolved fallible payload.

`!~.` and `~!.` are intentionally different:

- `value!~.name`: if constructing `value` failed, propagate that failure and
  create no continuation; otherwise return a future that maps `.name`.
- `value~!.name`: create a derived future; when the original resolves, retain
  an asynchronous failure unchanged and map `.name` only over success.
- `value!~!.name`: preserve both failure sites. `TRY value` consumes the outer
  failure; `NEXT` then exposes the inner failure, which requires its own
  `TRY`, retention, or recovery.

Safe navigation remains non-suspending. Future navigation does not suspend the
current function and does not behave like `NEXT`; it constructs a derived
future with the same affine/shared ownership character as the source. For a
plain affine future, mapping consumes the source handle into the derived
future. For a shared future, mapping retains or borrows it according to the
existing sharing plan. Cleanup and cancellation of the derived operation must
use the lifecycle plan.

The first implementation should lower `~.` to the existing asynchronous/FSM
machinery through a `future_map` plan rather than introduce a second scheduler
primitive. Conceptually it is equivalent to a compiler-generated asynchronous
continuation containing `NEXT`, but it must not be implemented as textual AST
rewriting. A later runtime fusion optimization may avoid a separate task or
allocation; that optimization is not required for semantic correctness.

`~.` applies to scalar `~T`, including the user's `streamFoo()` example when
that function's actual return type is a scalar future. A source of type
`[~]T` is a stream with cardinality, backpressure, and completion semantics;
`stream~.name` is rejected with a fix directing the user to pipeline
`SELECT`. This avoids giving the same surface operation two materially
different cardinality meanings.

Member fields or calls may add a different inner tense where the resulting
ordered type is valid. Identical wrappers are not silently nested. Optional
and failure mapping join the same boundary using the existing optional/error
join rules. A mapped operation that would produce `~~T` is rejected rather
than implicitly awaiting or flattening it; the user must compose that future
explicitly with `NEXT` in an asynchronous body. This preserves the rule that
crossing a temporal boundary is never implicit.

Effects produced by a member invoked inside `~.` occur after the future
resolves and are therefore placed inside that future. For example, mapping a
method returning `!K` over `~T` yields `~!K`; mapping it over `!~T` yields
`!~!K`. It must never be reconstructed as `!~K`, because that would move a
later failure to the task-construction boundary. The same rule places a newly
introduced optional as the innermost `?` layer. These placement rules belong
to the planner and are part of its exhaustive operation table.

The same operator applies uniformly to the postfix targets already supported
by safe navigation--field access and method calls initially, and indexing only
if the postfix grammar already provides an unambiguous form. Assignment or
mutation through `~.` is out of scope for the first implementation: users must
`NEXT` in a `BG`/async body and make the mutation explicit.

The plan describes the exact navigation layers, mapped payload/result,
receiver refinement, error sets, handle consumption, sharing, and suspension
behavior. MIR remains responsible for temporaries, continuation blocks, and
lifecycle materialization; it may not reconstruct these facts from punctuation
or result types.

### `SELECT` effect modes

The planner determines the selector's normalized envelope and required mode:

```text
T   -> SELECT
!T  -> SELECT:!
?T  -> SELECT:?
!?T -> SELECT:!?
```

An asynchronous selector remains a separate fact. The planner must not
silently await it or treat it as one of the three value modes. The resulting
collection topology is provided by pipeline analysis; the planner supplies the
item effect and validates the declared selector mode.

### Inferred async-result joins

Move the current controlled join behind the same semantic boundary. The join
must remain:

- limited to identical semantic payloads;
- commutative, associative, and idempotent;
- monotonic only in optionality and fallibility;
- exact about capabilities, topology, generic arguments, and error sets; and
- rejecting of mixed future/non-future inputs and unrelated payloads.

This is an effect-lattice join, not `flatMap` and not union inference.

## Architecture Boundaries

### Planner owns

- extraction and validation of the supported tense envelope;
- layer consumption and preservation;
- result-type calculation;
- recovery/fallback compatibility;
- source-level propagation classification;
- affine/shared/stream handle-use classification; and
- suspension classification intrinsic to the operation.

### Annotator owns

- name, call, member, protocol, and expected-type resolution;
- function and block control-flow context;
- recording effects and ownership operations from the plan;
- issuing source diagnostics and fixes from planner failures; and
- publishing the immutable plan table.

### MIR owns

- translating the plan's semantic backend form into MIR nodes;
- allocator and temporary selection;
- cleanup and transfer materialization through the lifecycle plan;
- FSM versus stackful suspension mechanics; and
- target-specific bytecode or Zig realization.

### Runtime owns

- optional/error/promise representations;
- scheduler waiting and wakeup;
- stream completion protocol;
- shared-promise synchronization and reference counts; and
- concrete destruction after the compiler-selected lifecycle operation.

No layer may reinterpret a plan because its current runtime representation
looks convenient.

## Diagnostics

Planner errors should be semantic values which the annotator renders with
source context. Required categories include:

- operation requires a specific outer tense;
- operation would cross a tense layer implicitly;
- fallback type does not match the recovered payload;
- future/non-future join mismatch;
- payload mismatch during controlled widening;
- selector effect annotation absent or incorrect;
- tense-navigation markers do not match the receiver's ordered layers;
- future navigation would implicitly flatten a nested future;
- affine future already consumed;
- stream operation used on a scalar future, or the reverse; and
- invalid or unsupported tense-layer order.

Fixes must use the normalized result type and operation table. Examples:

- suggest `TRY expression` only when the plan proves that doing so removes the
  intended `!` layer;
- suggest `UNWRAP`, `?.`, or `OR_ELSE` for optionality according to the chosen
  Decision B;
- suggest `NEXT` for a future without silently adding it;
- suggest the exact ordered navigation spelling (`~!.`, `!~?.`, and so on)
  when the intended operation is payload mapping rather than layer removal;
- suggest `SELECT:!`, `SELECT:?`, or `SELECT:!?` from the computed selector
  envelope; and
- print `~!T` when a fallible asynchronous computation is the actual result.

## Verification Strategy

### Exhaustive operation table

The scalar tense space is deliberately small and ordered:

```text
T, ?T, !T, !?T,
~T, ~!T, ~?T, ~!?T,
!~T, !~!T, !~?T, !~!?T
```

For every operation, unit-test every meaningful input state and every rejected
state. These tests should instantiate real `TypeExpression` trees with
capabilities at each legal layer and compare the complete plan, not only the
printed result type.

### Integration-style compiler tests

Prefer CLEAR source strings through parser and annotation for:

- legal and illegal `TRY`/`UNWRAP` orderings;
- `NEXT` over affine/shared futures and every stream cardinality;
- all `OR_ELSE` recovery forms;
- predicate refinement bindings;
- safe-navigation chains;
- every valid ordered tense-navigation operator and representative invalid,
  skipped-layer, and duplicated-layer forms;
- all selector effect modes; and
- fixable diagnostics.

Run all Ruby specs with `bundle exec prspec`.

### Transpile and runtime tests

Add or expand transpile tests for:

- a real `~!T` task from creation through `NEXT`, retention, propagation,
  fallback, and cleanup;
- `~!?T` with `TRY`, optional handling, and `OR_ELSE`;
- `~.`, `!~.`, `~!.`, `~?.`, and the remaining valid combinations over
  fields and methods, including both success and short-circuit paths;
- shared versus affine future consumption;
- stackful and FSM suspension paths;
- bytecode and Zig parity where both support the operation; and
- ownership-bearing payloads to detect leaks, double frees, or lost borrows.

### Fuzz matrices

Expand the existing tense and pipeline matrices rather than creating an
unconstrained generator. Cross:

- all 12 scalar envelopes;
- operation;
- exact navigation-marker order;
- collection position;
- capability placement;
- payload ownership shape;
- affine/shared future mode;
- expected success or diagnostic; and
- stackful/FSM lowering where applicable.

The oracle includes compilation result, diagnostic identity, leak result,
MIR-checker result, and expected runtime output.

### Algebraic properties

Property tests should verify the laws CLEAR actually claims:

- extraction followed by reconstruction preserves the semantic type key;
- reconstruction preserves exact ordered layers, including distinct `!~T`,
  `~!T`, and `!~!T`;
- normalization is idempotent;
- controlled async joins are commutative, associative, and idempotent;
- joins never invent a future or unrelated union;
- consuming one layer preserves all untouched layers and capabilities;
- plan generation is deterministic;
- a valid plan's result type matches annotation's stamped type; and
- MIR's emitted operation agrees with the plan's backend form.

Do not assert generic monad laws that the language intentionally does not
implement.

### Architecture invariant

After migration, add a guardrail analogous to the lifecycle-plan invariant:

> MIR lowering may not select tense-operation semantics without consuming the
> annotation-produced `TenseOperationPlan`.

The allowlist should be narrow. Representation-only queries used by cleanup or
rendering may remain, but semantic decisions for the covered operations must
not call tense predicates directly.

## Migration Plan and Commit Boundaries (completed)

### Phase 0: decide and characterize

- Resolve Decisions A and B.
- Reconcile with the committed `easy-vm-testing/fv` SELECT work: retain its
  independent oracle and matrix tests, document the 12-state ordered type
  grammar, and characterize the current parser/`Type` disagreement.
- Add end-to-end characterization for current `~!T`, `TRY ?T`, and `!?T`
  behavior before changing it.
- Record the intended semantic table in executable tests.
- Snapshot Decomplex, Espalier, NilKill, production LoC, and focused coverage.

No refactor starts while either language decision is being inferred from
current backend accidents.

### Phase 1: envelope and pure planner

- Add immutable ordered `TenseEnvelope`, operation enums, result plan, and
  diagnostic result types.
- Implement pure planning over existing `TypeExpression` nodes.
- Move `join_async_results` behind the planner without changing behavior.
- Reach 100% branch and LoC coverage on the new pure subsystem.

At this phase existing consumers may remain, but the new plan cannot duplicate
or cache a second mutable type representation.

### Phase 2: `TRY`, `UNWRAP`, predicates, and optional/fallible navigation

- Make annotation publish plans for the non-suspending operations.
- Make MIR consume those plans.
- Delete local semantic reconstruction and `TryExpr` versus `TryOptional`
  inference from MIR.
- Preserve provenance and lifecycle facts exactly.

### Phase 3: future navigation

- Parse `~.` and every valid ordered combination as one semantic postfix
  operation with a precise source span.
- Add pure navigation plans for all 12 receiver states, with exact skipped-
  layer and invalid-order diagnostics.
- Lower `future_map` through existing asynchronous/FSM and lifecycle planning;
  do not textually desugar or add a parallel scheduler.
- Prove affine consumption, shared-future behavior, synchronous and
  asynchronous failure propagation, optional short circuiting, cancellation,
  and cleanup in transpile and fuzz matrices.
- Reject stream cardinalities with a fix directing users to `SELECT`.

### Phase 4: `OR_ELSE`

- Move recoverable-left classification, handled-layer selection, fallback
  checking, and result-type calculation into the planner.
- Retain specialized MIR materialization for `RAISE`, `EXIT`, `PASS`, `BREAK`,
  and `PRUNE`, driven by the plan.
- Keep allocation-fault recoverability explicit and separate from `!T`.

### Phase 5: `BG`, `NEXT`, and streams

- Implement Decision A.
- Publish plans for promise, shared-promise, promise-list, observable, and
  stream resolution.
- Reuse existing scheduler, FSM, ownership, and materialization code; change
  only its semantic input authority.
- Add the missing end-to-end `~!T` matrix.

### Phase 6: pipeline selector modes and joins

- Replace `fv`'s selector string splitting and envelope reconstruction with
  planner output while preserving its semantic oracle.
- Make diagnostics and fixes consume the same result.
- Expand pipeline fuzz coverage across tenses and capabilities.

### Phase 7: deletion and enforcement

- Delete compatibility helpers and duplicate semantic branches.
- Add the MIR plan-consumption architecture invariant.
- Re-run full unit, integration, transpile, fuzz, example, benchmark, Sorbet,
  and leak gates.
- Re-run Decomplex, Espalier, and NilKill and explain any metric that fails to
  recognize the removal of duplicated semantic authority.

Each phase is a separate commit. A phase is not committed with failing tests,
lower branch coverage, new untyped state, or an annotation/MIR semantic
fallback.

## Expected Code Delta

### Code that cannot be eliminated

The planner does not remove the real mechanics of:

- Zig `try`, `catch`, and optional lowering;
- `OR_ELSE EXIT/PASS/BREAK/PRUNE` control flow;
- promise and stream runtime calls;
- affine/shared ownership handling;
- observable materialization;
- FSM suspension/resumption;
- allocator selection; or
- cleanup and transfer planning.

Claiming all existing tense-related code as deletable would be metric gaming
and would create an over-centralized planner that knows backend details.

### Revised estimate including ordered layers and navigation

The directly relevant semantic decision blocks currently occupy roughly
700-1,100 production lines across `Type`, annotation, pipeline analysis, and
MIR lowering. The committed `fv` SELECT work adds useful coverage but also
adds parser-to-MIR order preservation and reconstruction that the final
planner should collapse. After excluding backend mechanics and legitimate
representation queries, approximately 450-800 lines are credible duplicate
classification, result-type construction, wrapper-string manipulation, and
cross-phase reconstruction.

The original 410-700-line estimate assumed one canonical eight-state envelope
and did not include public navigation syntax or asynchronous mapping. It is no
longer credible. The revised production estimate is:

| Component | Production LoC |
| --- | ---: |
| Ordered envelope extraction and 12-state validation | 110-190 |
| Operation/layer/result product types | 110-180 |
| Pure planner, joins, and operation table | 230-380 |
| Navigation lexer/parser/AST and diagnostics | 140-250 |
| `future_map` MIR/FSM/ownership integration | 180-340 |
| Plan-table handoff and architecture invariants | 70-130 |
| Total new production code | **840-1,470** |

The `future_map` estimate assumes reuse of existing `BG`/`NEXT`, FSM,
scheduler, and lifecycle primitives. A new general continuation runtime would
add roughly 150-300 Zig LoC and should require a separate performance case; it
is not part of the recommended first implementation.

Expected deletion during complete migration:

| Removed or collapsed code | Production LoC |
| --- | ---: |
| Duplicate annotator classification/result construction | 180-320 |
| Duplicate MIR classification and backend-form selection | 130-240 |
| SELECT modifier/string reconstruction and compatibility helpers | 100-190 |
| Pipeline/join/recovery helpers and temporary AST flags | 80-160 |
| Total deleted production code | **490-910** |

The likely net production change is therefore approximately **+200 to +800
LoC**. The low end requires fully deleting the `fv` compatibility paths and
lowering future mapping through existing async machinery. The high end is
acceptable only if it closes the distinct synchronous/asynchronous failure,
ownership, and diagnostic gaps described here; it is not acceptable merely to
wrap existing helpers.

Tests and independent oracles are expected to add another **700-1,400 LoC**.
That is intentional: the 12 receiver states, 11 navigation spellings,
field/method paths, affine/shared modes, and success/short-circuit/error paths
need pairwise coverage without multiplying into an unreadable Cartesian test
suite. Reuse the `fv` SELECT oracle pattern rather than hardcoding expected
compiler implementation details.

Expected effort for one engineer is approximately **5-9 weeks**:

| Work | Estimate |
| --- | ---: |
| Reconcile `fv`, settle decisions, and establish oracles | 3-5 days |
| Ordered planner and annotation/MIR handoff | 2-3 weeks |
| Navigation syntax, diagnostics, and non-future mapping | 3-5 days |
| Future mapping, ownership, FSM/stackful parity, and cleanup | 1.5-3 weeks |
| Fuzz/transpile matrices, full gates, deletion, and metrics | 1-2 weeks |

Stop and reassess if the implementation exceeds about 1,500 new production
lines, retains both string-based SELECT reconstruction and the planner, adds a
second scheduler, or cannot delete the mutable `declared_async_payload` /
`retain_error_channel` protocol after migration. Any of those outcomes would
indicate a parallel framework rather than consolidation.

## Expected Architectural and Correctness Gain

### Architectural gain: high

The strongest improvement is not raw LoC. It is reducing semantic authorities
from at least three to one:

```text
today:
Type helpers -> annotator decision -> MIR re-derivation -> backend behavior

target:
TypeExpression -> annotator TenseOperationPlan -> MIR realization
```

This gives the compiler:

- one definition of which layer an operation consumes;
- one result type used by annotation and lowering;
- one classification of propagation versus recovery;
- one source of consumption and suspension facts;
- fewer temporal protocols requiring helper calls in the correct order;
- a smaller public semantic surface between annotation and MIR; and
- an independently testable pure core suitable for self-hosting.

This is a substantial architectural win even if net LoC is nearly neutral.
It removes re-derivation after context loss, which is precisely the class of
architecture that has previously caused ownership and lowering bugs.

### Correctness gain: very high for tense composition

The planner closes several high-risk drift opportunities:

- annotation accepting a combination that MIR lowers differently;
- losing `?` while consuming `!`, or vice versa;
- future failure being hidden by payload stripping;
- safe navigation accidentally becoming force unwrap or propagation;
- selector diagnostics disagreeing with retained element type;
- `OR_ELSE` checking source wrappers differently from emitted `catch`/`orelse`;
- capability or placement loss while rebuilding wrapper types through strings;
- affine futures being resolved without recording consumption; and
- canonical streams confusing item optionality with completion.

The confidence in this gain is high because those decisions currently span
the type model, 22 annotator files, and 15 MIR files, and because the current
`~!T` runtime story is materially less tested than its surface representation.

### Performance impact

This is not primarily a compile-time optimization. A pure plan cached at the
annotation boundary should remove some repeated shape traversal and string
reconstruction, but the expected effect on total compilation time is small.
Generated program performance should remain byte-for-byte or behaviorally
identical for existing syntax except for approved language-decision fixes.

`~.` is new behavior and can have a runtime cost: the baseline lowering creates
a derived asynchronous continuation and may allocate/schedule one additional
task. The operator makes that temporal mapping visible, so this is not hidden
overhead on existing code. Before declaring the feature complete, benchmark it
against the explicit `BG { value = NEXT source; RETURN value.name; }`
equivalent. A later fused `future_map` runtime path is worthwhile only if it
materially removes overhead without adding a second semantic authority.

### Diagnostic gain: high

Today diagnostics are produced by operation-specific code after slightly
different type decomposition. A plan failure can identify the exact present
layers and the one operation needed next. This should make fixes for stacked
tenses deterministic and prevent suggestions such as `TRY` where `UNWRAP` or
`NEXT` is actually required.

### Self-hosting gain: medium to high

The pure planner and immutable products translate cleanly to CLEAR. More
importantly, the self-hosted MIR will not need to reproduce implicit Ruby
calling order and mutable AST conventions. This does not unblock self-hosting
by itself, but it removes a broad class of semantic re-derivation from one of
the language's most distinctive type features.

## Analyzer Expectations

The refactor should improve, rather than game, architecture metrics:

- Decomplex should see fewer missing abstractions, less duplicated branching,
  less implicit helper ordering, and reduced decision pressure in
  `visit_OrElse`, `visit_NextExpr`, selector analysis, and MIR lowering.
- Espalier should see fewer semantic fan-out edges from MIR into `Type`
  predicates and a smaller public operation surface. The planner itself may
  have substantial fan-in; that is desirable single authority, not a god
  object, provided it is pure and stateless.
- NilKill should remain neutral or improve as nullable intermediate facts are
  replaced by exhaustive result variants. A plan full of nullable fields would
  be a failed design.

Aggregate function/class counts may rise slightly because explicit result
types replace boolean combinations. The meaningful success criteria are fewer
stateful authorities, fewer semantic re-derivations, fewer nullable control
flags, and lower call-order dependence.

## Stop Conditions

Stop or redesign if the implementation:

- introduces higher-kinded types or a public `Monad` protocol;
- creates a second mutable representation of the type stack;
- treats streams as ordinary futures and loses cardinality/completion;
- converts capabilities into generic monad metadata;
- lets MIR invoke the planner independently;
- places Zig strings, allocator choices, or FSM nodes in semantic plans;
- requires pervasive cache checks inside existing visitors;
- adds runtime boxing, virtual dispatch, closures, or allocation to existing
  tense operations; `~.` may create the documented derived-future task until a
  proven fusion optimization replaces it;
- cannot state `BG`/`NEXT` failure behavior unambiguously; or
- grows production code materially without deleting the old decision paths.

## Acceptance Criteria

- Decisions A and B are documented and executable as tests.
- One immutable planner owns the semantics of every operation in scope.
- Annotation publishes a typed plan table consumed directly by MIR.
- MIR does not re-derive covered tense semantics from type predicates.
- The existing `TypeExpression` tree remains the only structural type truth.
- Streams remain distinct from scalar futures.
- Per-layer capabilities and placement survive every operation.
- `~!T` has complete parser-to-runtime coverage across affine/shared and
  stackful/FSM paths.
- The 12-state ordered tense matrix has complete positive and negative
  coverage.
- `?.`, `!.`, `~.`, and all valid ordered combinations preserve the exact
  receiver layers; malformed, mismatched, and skipped-layer forms have stable
  fixable diagnostics.
- `~.` lowers through lifecycle and existing async planning with affine/shared,
  stackful/FSM, failure, cancellation, and cleanup coverage.
- Controlled async joins satisfy their declared algebraic properties.
- New and changed production lines have 100% LoC coverage.
- Unit tests run through `bundle exec prspec`; transpile and fuzz matrices pass
  with leak checking.
- Sorbet passes with no untyped plan state.
- Decomplex, Espalier, and NilKill are recorded before and after each migration
  phase.
- No runtime overhead or public syntax is added merely to resemble a monad.

## Implementation Record

The workstream is complete as of 2026-07-20. The implementation keeps CLEAR's
specialized tense syntax and introduces no public monad protocol, higher-kinded
type machinery, runtime boxing for existing operations, or second mutable type
representation.

### Implemented semantic boundary

- `TenseEnvelope` is the ordered view over the existing immutable
  `TypeExpression` tree. It preserves the distinction between `!~T`, `~!T`,
  and `!~!T` and validates the supported 12-state scalar algebra.
- `TenseOperationPlanner` is the semantic authority for `TRY`, `UNWRAP`,
  `NEXT`, `OR_ELSE`, `IS_OK`, `EXISTS`, controlled async joins, `SELECT`
  effect modes, and ordered tense-preserving navigation.
- Annotation creates immutable `TenseOperationPlan`, `TenseJoinPlan`, or
  `TenseSelectorPlan` values and stores them on the analyzed AST. MIR consumes
  those plans. An architecture spec rejects planner invocation from MIR or
  backend code.
- MIR retains target-specific materialization, cleanup, ownership transfer,
  FSM/stackful suspension, and Zig emission. It no longer chooses the covered
  source semantics by independently inspecting tense predicates.
- `AsyncResultShape` owns the transport distinction between the source-level
  payload and the promise representation. A declared `~!T` uses
  `AsyncFallible(T)` at the Zig storage boundary because Zig cannot directly
  nest its inferred error-union representation inside every promise context.
  `NEXT` converts that transport form back to source-level `!T`.

### Navigation and async realization

All valid exact navigation spellings are implemented:

```text
?., !., !?.,
~., ~!., ~?., ~!?.,
!~., !~!., !~?., !~!?.
```

The parser records one `TenseNavigation` operation and its exact marker order.
Annotation validates the marker against the receiver envelope, resolves the
payload member, and plans the resulting layers. Direct optional/fallible
mapping lowers to `DirectTenseMap`; temporal mapping lowers to the existing
background-task and lifecycle machinery through a typed `FutureMapPlan`.
There is no textual desugaring and MIR never reparses punctuation.

Scalar futures and `[~]T` deliberately share semantic effect and lifecycle
authorities but do not share one physical MIR node. A scalar future maps one
eventual payload and can be represented by a derived task. A stream additionally
owns iteration, cardinality, backpressure, partial materialization, and close
state. Forcing those mechanics through `FutureMapPlan` would erase real
topology; `[~]T` therefore retains its aggregate MIR while consuming the same
`AsyncResultShape`, type-expression envelope, and lifecycle plan. This is a
separation of mechanisms, not duplicated tense semantics.

The implementation also fixed two correctness defects found by the new
end-to-end paths:

- assignment compatibility could inspect through `!collection` and silently
  accept it as a definite collection; a definite destination now rejects
  erasure of the fallible layer; and
- shared promises returned aliases of an owned cached payload; each successful
  `NEXT` now returns an independent owned copy while the cached value is cleaned
  exactly once.

### Actual code delta

The pre-planner comparison point is `e17bf8731`. The final tracked production
delta is:

| Area | Additions | Deletions | Net |
| --- | ---: | ---: | ---: |
| Ruby compiler production | 1,542 | 305 | +1,237 |
| Zig runtime production | 28 | 8 | +20 |
| Total production | **1,570** | **313** | **+1,257** |

The validation delta is larger than the implementation delta:

| Area | Additions | Deletions |
| --- | ---: | ---: |
| Ruby specs, including the new materialization invariant | 725 | 36 |
| Transpile/runtime CLEAR tests | 163 | 1 |
| Fuzz and semantic-matrix code | 149 | 3 |
| Zig runtime tests | 19 | 0 |
| Total test/oracle code | **1,056** | **40** |

Approximately 515 Ruby additions and 231 deletions established the planner and
removed the old decision paths. Approximately 1,030 additions and 77 deletions
implemented the subsequently approved `~.` family, async transport correctness,
and its physical lowering. Thus most net growth is attributable to the new
language feature and its ownership-safe runtime realization, not to the
original semantic-centralization refactor.

The 1,570 production additions are slightly above the design's 1,500-line stop
signal. The overage was reviewed rather than waived silently: it includes the
28-line runtime correction and the complete `~.` feature, stays within about
7% of the estimate's upper bound, deletes the former semantic decision paths,
adds no second scheduler, and improves the state/encapsulation metrics below.
Removing the specialized stream or lifecycle mechanisms merely to cross the
numeric threshold would be metric gaming and a worse architecture.

### Validation results

- `bundle exec prspec compiler/spec/`: **7,193 examples, 0 failures**.
- transpile generation: **500 CLEAR sources** accepted.
- generated Zig corpus: **616 tests, 0 failures**.
- shared-promise ownership suite: **9 tests, 0 failures**.
- tense fuzz matrix: **34/34**, including positive, diagnostic, ownership, and
  leak oracles.
- the `SemanticAdvanced` registry now includes the independent tense-plan
  handoff cell in its 201-cell contract.
- Sorbet signature enforcement: **213 files, 0 offenses**. Full Sorbet has no
  tracked compiler errors; the local checkout's remaining 15 errors are solely
  unrelated untracked scratch scripts.
- merged clean unit and transpile coverage exercises **783/783 changed
  executable Ruby production lines (100.0%)**. Whole-compiler unit coverage is
  93.53%; transpile coverage independently reaches 86.51%.

GitHub's authoritative diff-coverage and generalized analyzer jobs already
download every `ruby-coverage-*` artifact: unit, integration, transpile,
examples/benchmarks, fuzz, bytecode lowering, and gem coverage. The apparent
local coverage collapse was caused by rerunning a subset into a previously
collated result directory. Fresh isolated result directories reproduce the
expected coverage, so no CI workflow expansion was required.

### Analyzer deltas

All analyzers used the same focused corpus:
`compiler/ruby/annotator`, `compiler/ruby/mir`,
`compiler/ruby/ast/type.rb`, and `compiler/ruby/semantic`.

| Metric | Before | Planner stage | Final | Assessment |
| --- | ---: | ---: | ---: | --- |
| Espalier `Type` owner pressure | 1,578.0 | 1,560.0 | **1,560.7** | material win |
| Espalier MIR coordinator/mutator collision | 212.6 | **197.3** | **197.3** | material win retained |
| Espalier `Type` encapsulation pressure | 912.5 | **910.7** | **910.7** | public backend leakage removed |
| Espalier state slots | 353 | 353 | **352** | one less state authority |
| Espalier read/write effects | 1,654/654 | 1,654/654 | **1,653/653** | both reduced |
| Decomplex implicit control flow | 28 | 28 | **28** | no new call-order protocol |
| Decomplex temporal ordering pressure | 23 | 23 | **23** | no new mutable lifecycle |
| Decomplex missing abstractions | 164 | 164 | **164** | unchanged despite new syntax |
| Decomplex state heatmap/superfluous state | 71/3 | 71/3 | **71/3** | unchanged |
| NilKill fields/state accesses | 367/1,386 | 367/1,386 | **366/1,384** | reduced |
| NilKill dead nil checks | 28 | 28 | **28** | no nullable protocol added |

Decomplex's raw convergence, root-cluster, branch-density, WICC, and false-
simplicity counts finish at 793, 734, 1,788, 280, and 1,394 versus 792, 723,
1,771, 278, and 1,393. Those absolute counts are not architectural wins, but
they are largely denominator growth from 36 additional analyzed methods and
the real branching required by a new ordered operator family. The stronger
guardrails--implicit control flow, temporal order, missing abstraction,
mutable state, and superfluous state--remain flat, while Espalier's normalized
owner/encapsulation measures improve. `lower_future_tense_map` remains a
high-complexity physical lowering operation; splitting it into private helpers
would not reduce its inlined complexity and would hide rather than remove the
task, ownership, and cleanup sequence. It is intentionally kept as one
reviewable boundary until a genuinely reusable async materialization product
exists.

NilKill's owner/method counts rise from 878/4,885 to 886/4,921 because the
planner replaces boolean combinations with explicit typed products and
queries. `T.let` sites rise by four and call-resolution coverage moves from
21.41% to 21.34%; neither represents new nilability. The meaningful NilKill
signals--fields, state accesses, and dead nil guards--improve or remain flat.

## Baseline Validation

Before this design was written, the focused suites covering type expressions,
TRY behavior, and concurrency were run with:

```text
bundle exec prspec compiler/spec/try_expression_spec.rb \
  compiler/spec/type_expression_spec.rb \
  compiler/spec/concurrency_spec.rb
```

Result: **218 examples, 0 failures**.

That proves the characterized paths are currently green. It does not close the
identified `~!T` end-to-end coverage gap or decide whether current
`TRY ?T` behavior is the desired language.
