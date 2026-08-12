# Dataflow Facts and Derived Graph Plan

Status: implementation contract for the post-CFG workstream

Date: 2026-07-13

Related documents:

- `cfg.md`
- `typed-ir-course-correction.md`
- `g2-g3-readiness-design.md`
- `gems/fact-mine/docs/agents/architecture.md`

## Implementation Progress (2026-07-13)

The first useful increment now exists, but the full plan is not complete:

- Stage 1 is implemented. FactMine publishes the schema and source SHA-256;
  Ruby-to-CLEAR admits facts by digest, function identity, owner, and exact
  spans, and rejects stale, ambiguous, partially mapped, or incomplete input.
- Stage 2 has an initial shared implementation for local/parameter/state
  places and normalized reads, writes, mutations, literal type hints, and
  explicit unknown reasons. Field/index projections, closure captures, and
  escape effects still need the broader coverage described below.
- Stage 3's generic worklist, reachability, immediate dominators, reaching
  definitions, def-use, and liveness are implemented. They are derived from
  the shared CFG rather than rebuilt per language.
- Stage 4 now has three Ruby-to-CLEAR consumers: CFG liveness replaces textual
  “used later” offsets, reaching definitions select the concrete definition's
  type and ownership state, and complete flow-type facts fill otherwise
  unresolved locals. Nil-kill consumes Ruby/Python flow-local literal types.
  Ruby-to-CLEAR validates singular reaching definitions with dominance before
  using their types.
- Stage 5 now has a Ruby-proven vertical slice. FactMine publishes stable
  allocation identities (including explicit non-fresh origins), assignment
  alias transfers, may/must results at CFG nodes, and return/store/call escape
  evidence. The fixed point and public schema are language-neutral; all Ruby
  node kinds, transparent Sorbet calls, allocation messages, and boundary
  vocabulary live in the explicitly marked Ruby alias normalizer.
- Ruby-to-CLEAR admits those facts and distinguishes a borrowed
  `T.let(@field, ...)` alias from a fresh `@field.dup`. The former now emits a
  required `COPY` at the return boundary while the fresh copy does not. Mixed,
  missing, or incomplete identities remain conservative.
- Stage 5 is not complete: field/index projections, closure captures,
  interprocedural call summaries, mutation invalidation, and the labeled
  precision corpus remain.

Corpus telemetry established the consumer boundary. The first compiler run
admitted 2,440 of 5,321 analyzed functions (45.86%). Most rejections were not
FactMine incompleteness: Ruby-to-CLEAR expands methods from required modules
under a receiving class, while admission searched only the root document.
Selecting the FactMine document from each Prism node's source digest and
retaining the source CFG owner raised the representative annotator root from
74/847 admitted functions (8.7%) to 812/847 (95.9%). Its remaining 35
rejections are exact node-span mapping defects.

On that root, the admitted DFG was consumed 2,712 times for type selection,
4,607 times for ownership provenance, and 16 times for live-after-transfer
decisions. Generated CLEAR changed at ownership-bearing arguments, field
writes, and collection insertions rather than merely producing telemetry.

The next dominant failure is the planned Stage 5 boundary. After repairing
two unrelated modular visibility defects, the shared provider advances from
an amplified undefined-enum error to MIR ownership failures such as cleanup
for a borrowed value and an allocation with no cleanup/transfer. Liveness,
dominance, and reaching definitions identify which local definition reaches a
use, but they cannot prove whether two heap-bearing values share the same
allocation or whether a returned/stored projection escapes. More emitter-side
COPY/cleanup guesses at this point would recreate partial alias analysis in
Ruby-to-CLEAR.

The implementation is protected at both boundaries. FactMine's integration
suite requires every supported-language CFG fixture to publish exactly one
complete effect, reachability, dominator, and liveness record for every CFG
node. Ruby-to-CLEAR also invokes the real FactMine binary on every maintained
Ruby CFG fixture and proves exact admission, plus the ownership result for an
unreachable textual read. Synthetic consumer tests separately prove rejection
of missing effects, missing liveness, stale digests, unsupported schemas, and
unmappable spans.

These gates distinguish defects clearly: a missing or incomplete record in a
valid FactMine bundle is a FactMine producer defect; a complete record that
cannot be associated with the current Prism node is an identity/admission
defect; a stale or ambiguous bundle is expected rejection, not a producer bug.

## Decision

FactMine should add a language-neutral dataflow layer on top of its recovered
control-flow graph. It should not add a second source-of-truth graph that
independently reconstructs program order or control semantics.

In this document, “DFG” means the derived relations produced from:

```text
normalized executable IR
          |
          v
control-flow graph
          + node/edge identity
          + feasible successor structure
          |
          v
stable places and node effects
          + reads
          + definitions/writes
          + mutation
          + calls/captures/escapes
          |
          v
generic fixed-point analyses
          + reachability
          + dominance
          + reaching definitions
          + use-def / def-use relations
          + liveness
          + path-sensitive type state
          |
          v
public evidence-bearing dataflow facts
```

The use-def and def-use relations are graph-shaped and may be projected as a
DFG for visualization or consumer convenience. They remain derived facts. CFG
edges and normalized node effects remain the inputs from which they can be
recomputed and validated.

This distinction prevents three architectural failures:

1. Control order cannot disagree between a CFG builder and a DFG builder.
2. Language-specific syntax cannot leak into a second generic graph engine.
3. Consumers cannot silently treat source order as feasible execution order.

## Why the CFG Alone Is Not Enough

The CFG answers which node may execute after another node. It does not answer:

- which binding a read denotes;
- which definitions may reach that read;
- whether a definition is live after a transfer;
- whether a guard dominates a use;
- whether a write invalidates a prior narrowing fact;
- whether a value escapes through a field, return, collection, or closure; or
- which type state holds at a specific program point.

Those are dataflow questions. Answering them by AST ancestry, textual offsets,
or a method-wide map recreates fragments of a dataflow engine in every
consumer and loses precision at branches, loops, early exits, exceptions, and
callbacks.

## Ownership Boundary

FactMine owns language-neutral facts:

- stable place identities;
- normalized reads, definitions, mutations, captures, and escape boundaries;
- CFG-derived reachability, dominance, reaching-definition, and liveness
  facts;
- conservative unknown-call and incomplete-analysis states; and
- evidence paths connecting derived facts to source spans and CFG nodes.

FactMine does not decide:

- Ruby-to-CLEAR method targets or Sorbet types;
- CLEAR capabilities such as `@multiowned`;
- borrow, move, copy, retain, or allocation policy;
- whether a Nil-kill recommendation should edit a signature; or
- whether a detector finding is Tier 1.

Ruby-to-CLEAR attaches resolved types, targets, and ownership contracts to the
shared flow facts. Nil-kill attaches its type lattice and confidence policy.
Decomplex, SlopCop, and Espalier apply detector-specific thresholds without
reparsing source.

## Required Public Fact Model

### Stable places

A place is a function-scoped storage identity, not a display name:

```text
PlaceId
  id
  file / owner / function
  root_kind
    parameter / local / self / field / class_field / global /
    allocation / captured / unknown
  name
  declaration_span
  projections
    field(name)
    index(constant)
    index(unknown)
    dereference
  completeness
```

Two shadowed locals with the same spelling must have different IDs. Fields on
different receiver places must not collapse because their final field name is
the same. Dynamic receivers and unknown indices remain explicit unknown
projections.

### Node effects

Each CFG node may publish:

```text
NodeEffect
  node_id
  reads: PlaceId[]
  definitions: PlaceId[]
  mutations: PlaceId[]
  allocations: PlaceId[]
  captures: CaptureEffect[]
  escapes: EscapeEffect[]
  terminates: normal / return / raise / process-exit / unknown
  call_effect: known summary / unknown receiver / unknown target
  source_span
  completeness
```

Unknown calls conservatively affect compiler safety. They do not by themselves
justify a Tier 1 detector finding.

### Derived flow facts

The first public analyses are:

- reachable/unreachable node facts;
- immediate dominator and post-dominator facts;
- reaching definitions per place use;
- use-def and def-use edges;
- live-in and live-out sets;
- edge predicate facts for nil, truthiness, equality, and type guards;
- type-state facts where a consumer supplies or selects a type lattice; and
- completeness/unknown reasons for every function and derived row.

Every row includes participating node IDs and source spans so a consumer can
replay the proof.

## Benefit to Ruby-to-CLEAR

### Replace textual “used later” ownership guesses

The current typed-IR slice decides copy versus move by searching for a local
read with a greater source offset. That is wrong when a later textual read is:

- unreachable after `return`, `raise`, or another terminator;
- in a mutually exclusive branch;
- before the transfer on a loop backedge;
- inside a callback whose execution/escape class differs from ordinary
  fallthrough; or
- shadowed by another binding with the same name.

Backward liveness over stable places answers the real question: is this exact
value live on any feasible successor path after the transfer?

### Make narrowing a reusable typed-IR input

Dominance plus edge predicates identify where a truthiness, nil, `is_a?`, or
Sorbet guard applies. Reaching definitions prove that the guarded binding has
not been replaced before the use. Ruby-to-CLEAR still chooses the concrete
type using Sorbet and resolved symbols, but it no longer rediscovers flow scope
in call lowering.

This directly supports:

- optional receiver calls after early-return guards;
- union variant calls inside dominated arms;
- `T.cast` bindings and later reads;
- branch joins with different concrete definitions; and
- loop-carried optional and union state.

### Make closure ownership conservative and explicit

Capture effects plus liveness distinguish:

- read-only capture;
- mutation of a captured place;
- capture whose value is used after callback execution;
- non-escaping inline callback;
- escaping stored/returned callback; and
- unknown callback escape.

Ruby-to-CLEAR can then plan `Borrow`, `BorrowMut`, `Move`, or `Copy` in typed IR
and reject unknown overlap instead of guessing during emission.

### Boundaries and limitations

The first DFG slice can address source-level use-after-move and some MIR
ownership failures. It cannot repair an incorrect `@multiowned` function
contract, unresolved call target, missing Sorbet type, or MIR allocator/cleanup
bug. Those remain independent compiler workstreams.

## Benefit to Nil-kill

Nil-kill currently has useful expression and signature inference, but several
local decisions are stored in method-wide maps keyed by variable name. Branch
handling clones and merges those maps, and conditional assignment is often
represented by making a type nilable. This is necessarily imprecise for early
exits, nested branches, loops, rescue/ensure, callbacks, and repeated writes.

A CFG-backed type-state analysis can resolve a meaningful subset of current
unknowns without runtime evidence.

### Types at a particular read

Reaching definitions let Nil-kill infer the type of the definition that can
actually reach a local read rather than merging every assignment in the
method.

```ruby
value = nil
if ready?
  value = build_name
else
  return
end
consume(value)
```

The `nil` definition cannot reach `consume`. If `build_name` is known to return
`String`, the type at the use is `String`, not `T.nilable(String)`.

### Dominating non-nil and class guards

```ruby
return unless account
account.name
```

The true edge of the guard dominates the read. If no reaching definition or
relevant mutation invalidates it, Nil-kill can prove `account` non-nil at the
read and distinguish a redundant local guard from a genuinely nilable method
contract.

The same mechanism applies to `is_a?`, `kind_of?`, language-equivalent type
guards, and closed union/tag tests.

### Definite assignment

Nil-kill can distinguish:

- assigned on every path reaching the use;
- assigned only on some feasible paths;
- initialized only by an unreachable branch;
- assigned by all case arms including default; and
- assigned in a loop that may execute zero times.

This removes both false nilability and unsafe optimism.

### Guard invalidation

A guard is useful only while its subject still denotes the guarded value.
Reaching definitions and mutation effects can show that a local or projected
field was reassigned or mutated between the guard and use. Nil-kill can retain
valid guard proofs and reject stale ones.

### Loop fixed points

Loops require iteration until input/output type state stabilizes. This can
infer loop-carried unions and nilability without treating one source-order walk
as execution order.

### Return and fallibility precision

Reachability allows return inference to ignore expressions after terminal
nodes and to join only feasible return sites. Post-dominance and exceptional
edges can distinguish:

- guaranteed return values;
- implicit nil fallthrough;
- paths that always raise/exit;
- rescue recovery values; and
- ensure cleanup that does not change the returned value.

### Unknowns this will not solve

CFG/dataflow cannot invent facts absent from the program model. It does not by
itself resolve:

- unknown parameter types with no callsite, signature, or runtime evidence;
- unresolved method return signatures;
- unresolved constants or receiver classes;
- reflection, `eval`, monkey patching, or native boundaries;
- unknown dynamic dispatch targets; or
- instance/global state written outside the analyzed boundary.

These remain explicit unknown reasons rather than being guessed.

## Tier 1 Evidence Policy

“Tier 1” means the finding is supported by a replayable static proof under the
declared supported semantics. A may-analysis fact widened by an unknown call is
not a Tier 1 defect by itself.

Tier 1 DFG-backed findings require:

- a complete CFG for the function;
- stable places for all facts participating in the proof;
- no unknown call or projection on the relevant evidence path unless the
  finding remains valid under its conservative effect;
- source spans for each definition, guard, mutation, escape, and use;
- deterministic reproduction from public FactMine facts; and
- negative fixtures that differ by one invalidating edge or effect.

## Metrics and Findings Unlocked

The following are novel relative to the products' current syntax/local-flow
facts. Some are established compiler analyses generally; “novel” here means a
new evidence-grade metric or finding for this repository.

### Decomplex

#### Feasible Definition Fan-In

Measure the number and type diversity of definitions that may reach an
important read or return, excluding unreachable definitions. High fan-in at a
public result or mutation site identifies functions whose apparent local
simplicity hides path-dependent state convergence.

Tier 1 evidence: use node, reaching definition nodes, join nodes, and complete
path classes.

#### Live Mutable State Width

Measure the peak number of mutable places simultaneously live across a CFG
region. This distinguishes a long function with sequential simple work from a
function that requires the reader to track many interacting mutable values at
once.

Tier 1 evidence: node, live set, declaration spans, and mutation spans.

#### Guard-to-Use Distance Under Mutation

Measure the feasible control-flow distance from a proven guard to guarded uses,
including intervening writes/calls. This can rank fragile reasoning even when
the guard remains technically valid.

Tier 1 evidence: dominating guard, guarded use, intervening effect path, and
proof that no invalidation occurs.

#### Cleanup/Exit Obligation Dispersion

Count distinct feasible exits carrying a live cleanup or resource obligation.
This exposes complexity created by returns, raises, breaks, callbacks, and
ensure/finally behavior rather than raw branch count.

Tier 1 evidence: acquisition definition, live obligation, exit nodes, and
cleanup nodes.

### SlopCop

#### Proven Dead Store

Report a definition that reaches no feasible read before being overwritten or
the function terminates.

Tier 1 evidence: definition node, def-use result, overwrite/exit frontier, and
complete CFG.

#### Stale Derived Value

Report a derived local that is used after a source place is mutated when the
derivation is known and no refresh definition reaches the use.

Tier 1 evidence: source definition, derivation dependency, mutation, stale use,
and reaching-definition chain.

#### Invalidated Guard Use

Report code that relies on a nil/type/state guard after the guarded place or a
must-alias projection is changed.

Tier 1 evidence: guard edge, invalidating definition/mutation, later use, and
absence of a new dominating guard.

#### Path-Proven Redundant Assignment

Report identical definitions on all incoming paths when they can be hoisted or
collapsed without crossing an effectful operation.

Tier 1 evidence: predecessor definitions, join node, identical value proof,
and effect-free movement region.

### Nil-kill

#### Flow-Resolved Unknown Type

Count and surface unknown local-use types that become known from reaching
definitions and path type state.

Tier 1 evidence: use, reaching definitions, expression types, join operation,
and completeness state.

#### Proven Non-Nil Region

Identify the maximal CFG region in which a place is proven non-nil. This can
support guard removal, safe-navigation removal, and narrower local contracts.

Tier 1 evidence: establishing guard/definition, dominated nodes, invalidation
frontier, and uses.

#### Nil Introduction Frontier

Identify the smallest set of definitions or fallthrough edges introducing nil
into a downstream type. This improves prioritization over method-wide “nil
pressure.”

Tier 1 evidence: nil-producing definitions/edges, join, affected uses/returns,
and def-use paths.

#### Conditional Initialization Gap

Report a use reachable from both initialized and uninitialized definitions,
distinguishing zero-iteration loops and missing case defaults from impossible
paths.

Tier 1 evidence: use, initialized reaching definitions, uninitialized entry
fact, and feasible predecessor paths.

#### Redundant Nilable Contract by All Returns

Prove that every feasible return is non-nil and that there is no implicit
fallthrough, supporting removal of `T.nilable` from a return signature.

Tier 1 evidence: all reachable return nodes, inferred return types, exceptional
exits, and absence of nil fallthrough.

#### Guard Invalidation Pressure

Rank places repeatedly guarded because intervening definitions or mutations
invalidate earlier proofs. This can reveal unstable API/state design rather
than recommending isolated guard deletion.

Tier 1 evidence: guard regions, invalidations, and subsequent guards/uses.

### Espalier

#### Exact Mutable State Escape

Report a mutable allocation or parameter that crosses a return, field,
collection, global, or escaping-closure boundary.

Tier 1 evidence: allocation/parameter place, alias/assignment chain, escape
node, destination, and complete effect summary.

#### Boundary Alias-Mutation Collision

Report two boundary-visible places proven must-alias where one path mutates and
another consumer observes the shared value without an explicit ownership or
copy contract.

Tier 1 evidence: must-alias proof, mutation path, boundary path, and observed
use. May-alias alone is not Tier 1.

#### Constructor Invariant Bypass

Report state that reaches a public read/escape without passing through the
definitions required by all valid constructor paths.

Tier 1 evidence: constructor entry, required definitions, bypass path, and
public escape/read.

#### Escaping Closure State Surface

Measure and report the exact mutable places captured by escaping closures,
including whether each place is subsequently mutated or remains live in the
creator.

Tier 1 evidence: capture, escape, live-out fact, mutation nodes, and closure
destination.

#### Protocol State Escape Before Completion

Report a resource/state-machine value escaping while a required protocol
obligation remains live, such as a transaction or lock leaving scope before
commit/close/unlock.

Tier 1 evidence: acquisition, protocol summary, escape, missing completion on
the escape path, and complete call effects.

## Estimated Effort and Language Cost

The recovered CFG provides a useful baseline for this estimate. Its main
implementation commit added roughly 5,350 lines of production Rust, while the
cross-language proof commit added roughly 9,700 lines dominated by generated
JSON oracles. Those numbers are not a claim that lines are interchangeable;
they establish the scale of the graph builder and the unusually large fixture
surface already paid for by the CFG work.

The first useful dataflow increment -- stable places/effects, a deterministic
worklist, reachability, dominance, reaching definitions, def-use/use-def, and
liveness -- is estimated as follows:

| Work | Shared production LoC | Tests/fixtures LoC | Per-language LoC |
| --- | ---: | ---: | ---: |
| Place/effect schema and extraction | 700-1,100 | 400-700 | 20-80 |
| Generic worklist and classical analyses | 900-1,400 | 600-1,000 | 0 |
| Fact projection, validation, and identity | 300-500 | 250-450 | 0-20 |
| Ruby-to-CLEAR admission and liveness consumer | 350-650 | 300-550 | n/a |
| Nil-kill flow-type vertical slice | 500-900 | 400-750 | n/a |
| **First useful increment** | **2,750-4,550** | **1,950-3,450** | **20-100 per language** |

This makes the shared production work approximately 50-85% of the CFG
production implementation. Including tests, it is likely 35-60% of the total
hand-authored CFG effort. It should be substantially smaller than the CFG's
recorded total line growth because it can reuse the existing CFG fixtures and
should avoid duplicating full generated JSON oracles for every analysis.

The estimate deliberately separates the first useful increment from later
alias/escape work. Allocation identities, field-sensitive projections,
may/must alias sets, call summaries, closure escape, and evidence paths are an
additional 1,800-3,500 shared production lines plus 1,200-2,500 lines of tests.
That later increment is where dynamic-language conservatism and metric
qualification become the dominant cost.

### Expected per-language additions

The classical analyses are language agnostic. A language should not implement
its own worklist, liveness, reaching-definitions, dominance, alias, or escape
engine. Its only DFG-specific obligation is to normalize concrete syntax into
the shared effect vocabulary:

- declaration/binding roots and assignment targets;
- reads, writes, and mutations;
- field/index/dereference projections;
- parameter and closure captures;
- return/throw/yield/callback escape points; and
- call sites whose effects remain known or unknown.

For languages whose current normalized IR already distinguishes these forms,
the initial change should be about 20-100 lines per language, clearly marked
`CFG/DFG-SPECIFIC` in the existing syntax/adapter file, plus 50-150 lines of
fixtures. Languages with destructuring, implicit receiver rules, unusual
capture semantics, or weak assignment normalization may need 100-300 adapter
lines for full effect coverage. That remains translation code, not a
language-specific dataflow implementation.

Across the currently supported language set, a realistic first-pass budget is
roughly 700-1,800 adapter lines total. Full projection/capture/escape coverage
could grow that to 2,000-4,000 total, but it should arrive incrementally and be
measured by explicit completeness facts. Ruby is the first consumer proving
the schema; it must not gain privileged logic in FactMine's shared analysis
modules.

### Schedule estimate

For one engineer already familiar with the recovered CFG, the first useful
increment is approximately 2-4 focused weeks: one week for identity,
places/effects, and the worklist; one week for classical analyses and fixtures;
and one to two weeks for the Ruby-to-CLEAR and Nil-kill vertical slices plus
regression work. The later alias/escape increment is another 2-4 weeks and
should begin only after liveness and flow types demonstrate consumer value.

These are engineering estimates, not delivery promises. The largest
uncertainty is not the fixed-point algorithms; it is proving that every
adapter reports complete effects around closures, exceptions, destructuring,
and unknown calls without introducing unsound Tier 1 findings.

## Implementation Stages

### Stage 1: Consumer admission and identity

1. Publish CFG schema identity and source SHA-256 in FactMine output.
2. Reuse FactMine's existing multi-file `syntax-facts` command.
3. Load one batch in Ruby-to-CLEAR and match documents by digest.
4. Map CFG statement/control spans to Prism nodes.
5. Mark each function complete or ineligible with explicit reasons.

Exit gate: stale or ambiguously mapped facts are never consumed by typed IR.

### Stage 2: Places and effects

1. Add stable parameter/local/field place roots.
2. Add field/index projections and explicit unknown projections.
3. Attach normalized reads, definitions, mutations, calls, captures, escapes,
   and terminators to CFG nodes.
4. Add architecture gates keeping concrete syntax in language adapters.

Exit gate: every supported CFG fixture either has complete effects or names an
explicit unknown reason.

### Stage 3: Generic worklist and classical analyses

1. Implement deterministic forward and backward worklists.
2. Implement reachability and immediate dominators.
3. Implement reaching definitions and use-def/def-use relations.
4. Implement liveness.
5. Validate fixed-point convergence on loops and exceptional/callback edges.

Exit gate: public fixtures prove branches, early exits, loops, rescue/ensure,
and callbacks.

### Stage 4: Consumer vertical slices

1. Replace Ruby-to-CLEAR source-offset “used later” with place liveness.
2. Feed dominance/reaching definitions into typed-IR narrowing validation.
3. Add Nil-kill type-state transfer and joins over the shared worklist.
4. Publish flow-resolved type facts and unknown reasons.
5. Prove at least one raw G3 ownership improvement and one Nil-kill static type
   improvement without regression.

Exit gate: consumers use public facts, not CFG internals or AST re-analysis.

### Stage 5: Alias and escape (vertical slice implemented; expansion pending)

1. Add allocation identities and assignment aliases.
2. Add may/must alias fixed points.
3. Add known call summaries and conservative unknown calls.
4. Add escape evidence paths.
5. Admit Tier 1 alias/escape metrics only after labeled precision fixtures.

Exit gate: absence of a fact is never interpreted as proof of uniqueness.

## Verification Matrix

Required positive and negative fixtures include:

- linear overwrite and dead store;
- branch with one returning arm;
- branch with two reaching definitions;
- missing else/default and implicit nil;
- zero-iteration and multi-iteration loops;
- nested loop `break`/`next`;
- return/raise before textual later use;
- rescue/ensure definitions and cleanup;
- non-escaping and escaping callbacks;
- capture read versus capture mutation;
- guard, invalidating write, and re-guard;
- field projection versus same-named field on another receiver;
- constant versus unknown index projection; and
- known versus unknown call effects.

Every supported language must continue to emit the shared schema. Concrete
vocabulary additions remain in marked `CFG-SPECIFIC` sections of language
syntax/adapter files.

## Non-Goals

- Do not construct a separate DFG by walking source text.
- Do not put Sorbet or CLEAR ownership semantics into FactMine.
- Do not claim complete whole-program alias analysis for dynamic languages.
- Do not infer safety from absence of a may-alias edge.
- Do not turn unknown calls into Tier 1 defects.
- Do not expose a metric without source-linked evidence and completeness.
- Do not make emitters query or recompute dataflow.

## Immediate Recommendation

Stages 1-4 and the first Stage 5 compiler slice now justify expanding the
shared analysis. The next work should add field/index projections, closure
captures, mutation invalidation, and known-call summaries, then apply the facts
to constructor-field initialization and cleanup responsibility in
Ruby-to-CLEAR. The labeled precision corpus remains the gate before any Tier 1
alias metric.

Do not add a Ruby-only alias engine to FactMine. The initial Ruby-only adapter
work is deliberate proof of the cross-language boundary: concrete Ruby syntax
only normalizes allocations, assignments, projections, call boundaries,
returns, and closure captures into the shared effects vocabulary; the
alias/escape fixed point and evidence schema remain cross-language.
