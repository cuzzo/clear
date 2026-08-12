# CFG and Dataflow Plan for Ruby-to-CLEAR and FactMine

Status: course correction active; language-neutral CFG recovery, the first
classical dataflow slice, and Ruby-to-CLEAR admission are implemented on this
branch. A first language-neutral alias/escape fixed point with Ruby-only syntax
normalization and a Ruby-to-CLEAR ownership consumer is also implemented;
dominance-driven narrowing expansion, projections, captures, call summaries,
and the precision corpus remain gated by the milestones below

Date: 2026-07-13

Related documents:

- `typed-ir-course-correction.md`
- `g2-g3-readiness-design.md`
- `gems/decomplex/docs/agents/aliasing-complexity-metrics.md`
- `gems/fact-mine/docs/agents/architecture.md`
- `~/cheat/docs/agents/auto-copy-clone.md`
- `~/cheat/docs/agents/auto-box.md`

## Decision

### Cross-language requirement

FactMine's CFG is a cross-language subsystem. No Ruby-only CFG builder,
Ruby-only dataflow engine, or concrete-language branch is permitted in generic
FactMine code. Ruby-to-CLEAR is an early consumer, not the owner of FactMine's
control-flow model.

The required boundary is:

```text
Tree-sitter concrete syntax
          |
          v
syntax/<language> and ast/adapters/<language>
  normalize control constructs and provide CFG vocabulary
          |
          v
language-neutral normalized executable IR
          |
          v
syntax/cfg/*
  graph construction, validation, projection, metrics, dataflow
```

Any language-specific CFG addition must live in that language's existing
`syntax/<language>.rs` or `ast/adapters/<language>.rs` file. It must be enclosed
by explicit `CFG-SPECIFIC START` / `CFG-SPECIFIC END` comments. This makes the
per-language cost auditable and prevents CFG vocabulary from leaking into
generic modules.

Generic `syntax/cfg/*` files must not contain:

- a concrete `Language` branch;
- concrete Tree-sitter node names;
- language-specific iterator, callback, terminator, mutator, or exception
  lexicons;
- source spellings such as Ruby `do ... end` artifacts; or
- special cases justified by only one language fixture.

The recovered historical implementation is not accepted unchanged. Its core
graph algorithms consume normalized nodes and are reusable, but its generic
callback module owns a mixed Ruby/Rust/JavaScript iterator lexicon and a
Ruby-specific empty-body rule. Those rules must move behind language-owned CFG
profiles during recovery.

## Implementation Status (2026-07-13)

Phases 0 and 1 are implemented and considered recovered:

- `syntax/cfg/*` contains the recovered graph facts, builder, control-construct
  decomposition, validation, projection, and metrics. Historical test
  provenance was deliberately not recovered because it is a Test Miser
  consumer, not CFG infrastructure.
- The builder consumes current normalized `MethodSummary` facts and the
  normalized executable node schema. It does not branch on `Language` or read
  concrete Tree-sitter node kinds.
- The historical mixed-language callback lexicon and Ruby `do end` special
  case were removed from generic CFG code. Concrete callback vocabulary now
  enters through `ControlFlowProfile`, implemented in marked sections of each
  `syntax/<language>.rs` file.
- CFG nodes, edges, and metrics are emitted on `Document` and in syntax-fact
  projections.
- Recovered branch/case/loop/return/exception/callback/metric fixtures are
  restored. Explicit CFG fixtures now cover all 15 supported languages, and an
  integration gate requires every supported language to emit nodes, edges,
  and per-method metrics.
- Architecture gates reject concrete language names and representative
  iterator/source lexicons in `syntax/cfg/*`, require balanced CFG markers in
  language files, and reject unmarked profile implementations.

The adapter footprint is mechanically auditable with:

```bash
cargo test --manifest-path gems/fact-mine/Cargo.toml \
  --lib architecture_test::language_cfg_additions_are_explicitly_demarcated \
  -- --nocapture
```

The first consumer integration is now also a producer test. FactMine requires
complete effects, reachability, dominators, and liveness for exactly every CFG
node across the supported-language fixtures. Ruby-to-CLEAR invokes the real
FactMine binary over every maintained Ruby CFG fixture and admits every Prism
function by digest, owner, and source identity. This gate exposed and fixed a
FactMine defect where Ruby loop/ensure body wrappers leaked trailing `end`
tokens into executable statement spans. The Ruby-only `do` spelling is kept in
a marked `CFG-SPECIFIC` adapter hook; executable-body normalization remains
shared.

The same test distinguished two non-producer cases. Exception-region CFG nodes
are synthetic routing nodes with no single Prism expression, and an ensure
cleanup statement may be expanded once per incoming CFG path. Ruby-to-CLEAR
therefore does not demand an expression identity for exception routing nodes
and preserves one Prism node to multiple CFG-node identities, combining their
liveness conservatively. Missing/incomplete node effects or liveness remain
FactMine defects; stale digests, ambiguous files, and unsupported schemas
remain expected admission failures.

At recovery time this reports 120 marked adapter lines and 99 concrete
vocabulary entries across 15 languages. Ruby accounts for 8 marked lines and
28 entries; the generic CFG directory contains none of those entries. The
marked-line count stays intentionally small because each language exports the
same profile-shaped adapter contract; vocabulary-entry count exposes the real
language-specific surface.

Not yet implemented by this recovery: source-digest admission in the
ruby-to-clear consumer, classical dataflow, stable places, alias/escape facts,
or ownership planning. Those remain Phases 1B through 4 and must not be
described as completed CFG work.

Recovering a control-flow graph in FactMine is feasible and useful. It should
be treated as existing work that needs extraction and hardening, not as a new
research project. The abandoned `origin/test-miser` branch contains a real
statement-level CFG implementation in commits `c4102ccf1` through
`6ab92e06c`. It covers straight-line flow, branches, short-circuit expressions,
loops, backedges, case/match, abrupt exits, rescue/ensure, callbacks, graph
validation, metrics, and public projection.

Adding a generic dataflow engine on top of that CFG is also feasible. Standard
analyses such as reachability, dominators, reaching definitions, use-def
chains, and liveness are bounded monotone fixed-point problems. FactMine's
current `MethodSummary` already records statement spans, reads, writes,
dependencies, and co-uses, so the missing foundation is graph-aware place
identity and a reusable worklist/lattice API.

Alias analysis must be scoped more carefully:

- A useful, high-precision intra-procedural analysis is realistic.
- Explicit interprocedural escape and boundary facts are realistic when call
  targets and effect summaries are known.
- Sound, precise whole-program alias analysis for arbitrary Ruby, Python, or
  JavaScript is not realistic because reflection, dynamic dispatch, native
  calls, monkey patching, `eval`, and framework callbacks can hide targets and
  mutation.
- The useful target is not "solve all aliasing." It is to prove enough common
  local and explicit-boundary hazards with high precision, and to represent
  everything else conservatively as unknown.

This is enough to help ruby-to-clear materially and to enable several novel
Tier 1 findings in Decomplex, SlopCop, Nil-kill, and Espalier. It is not enough
by itself to take G3 above 50%; type/capability, call-resolution, syntax, and
unsupported-Ruby blockers remain separate workstreams.

## Evidence Already in the Repository

### FactMine CFG branch

The following commits exist on `origin/test-miser` and are not ancestors of
the current ruby-to-clear branch:

| Commit | Capability |
| --- | --- |
| `c4102ccf1` | CFG fact model, builder foundation, projection, linear Ruby fixture |
| `ff50c3d90` | Branches, joins, and boolean short-circuit flow |
| `3cacade18` | Loops, cases, returns, exceptions, callbacks, validation, broader fixtures |
| `061ed89b7` | CFG-derived metrics |
| `c11d6ce64` | Test-interaction value provenance |
| `6ab92e06c` | Architecture and coverage gates |

The branch exposes stable `ControlFlowNode` and `ControlFlowEdge` rows with
file, function, owner, role, source span, and edge kind. Its implementation
notes report 97.74% oracle-fixture coverage and 99.06% combined coverage over
2,121 production CFG lines after excluding inline test code.

This evidence proves feasibility. It does not prove that the branch is ready
for compiler use. The current public nodes do not carry resolved values,
versioned bindings, types, mutation effects, or ownership state. The builder
also targets an older FactMine normalized/local-flow implementation and must be
rebased against the current architecture rather than merged blindly.

### Existing FactMine local flow

Current FactMine `MethodSummary` statements already contain:

- stable source spans and source text;
- local reads and writes;
- dependency pairs;
- co-use pairs; and
- structural boundaries.

Those are useful seeds, but they are not dataflow. A flat source-order list
cannot answer whether a definition reaches a use, whether two events can occur
on the same path, whether a value is live across a loop backedge, or whether a
guard dominates a later use.

### CLEAR ownership transport in `~/cheat`

Commit `fbc64bad3` in `~/cheat` implements automatic ownership
transport. Its semantic visitor records resolved binding IDs, reads,
mutations, escapes, aliases, and owning transfers, then produces an immutable
`OwnershipTransportPlan` selecting:

- `move` when the source is dead;
- `borrow` for a local non-escaping, mutation-safe alias; or
- `materialize` when an owning/escaping destination needs an independent value.

It also retains values that are already declared `@multiowned` or `@shared`.
It does **not** silently upgrade a plain affine value to Rc or Arc. Such an
upgrade chooses shared identity instead of snapshot semantics and remains an
explicit fix.

The implementation currently approximates structured control flow using
event ordinals, ancestor stacks, explicit mutually-exclusive-branch checks,
and loop-backedge checks. A real CFG would replace those special cases with
ordinary dataflow and is therefore directly relevant to ruby-to-clear's typed
IR.

The constrained auto-box work in commit `6ac301676` is separate. It elaborates
an omitted box only when an explicit destination contract has already fixed
the indirect representation. Auto-boxing is not a general alias or ownership
solver and has little overlap with the dominant current G3 failures.

## Current G3 Impact

The fresh report at revision `e8667fa331a5` records raw G3 at 7/169 files and
313/97,066 source LoC, or 0.32%.

The primary first-failure groups most relevant to this proposal are:

| Primary failure | Files | Source LoC | Corpus LoC | Expected help |
| --- | ---: | ---: | ---: | --- |
| Use after move | 10 | 7,342 | 7.56% | Direct strong overlap with liveness and ownership transport |
| MIR ownership verification | 33 | 19,856 | 20.46% | Partial-to-strong overlap; some failures require separate MIR hoist/allocator/cleanup repairs |
| `FunctionSignature @multiowned` return mismatch | 43 | 26,944 | 27.76% | CFG/dataflow does not choose or repair the capability contract |
| Capability-transition arity mismatch | 16 | 8,976 | 9.25% | No help |

The current first-failure ceiling for the two ownership groups is about 28.02
percentage points of source LoC. That is an addressable surface, not a forecast:
fail-fast reporting hides later failures, and not every MIR ownership invariant
is caused by missing source liveness.

The most plausible immediate gain is:

1. direct elimination of the ten repeated use-after-move roots;
2. correct borrow-versus-owner cleanup for many of the 33 MIR-verifier roots;
3. correct path-aware `COPY`/move selection at calls, returns, fields, and
   collection stores; and
4. fewer late emitter ownership guesses and fewer regressions caused by those
   guesses.

CFG/dataflow alone is unlikely to reach 50% G3. The independent 43-root
`FunctionSignature @multiowned` provider blocker must also be repaired by
preserving the correct return capability or emitting the required explicit
construction. If that 27.76% blocker and a substantial part of the 28.02%
ownership surface are both removed, the first-failure arithmetic presents a
credible route past 50%, but a fresh corpus run is the only acceptable proof.

## Required Architecture

The shared pipeline should be:

```text
concrete source
      |
      v
language adapter -> normalized executable IR
      |
      v
statement/expression CFG
      |
      v
stable places + effects
      |
      v
generic dataflow
  reachability / dominance / reaching-defs / liveness
      |
      v
may-alias + must-alias + escape summaries
      |
      +-----------------------------+
      |                             |
      v                             v
compiler safety consumers       detector/report consumers
conservative may facts          precise must/proven facts
```

FactMine owns language-neutral control/dataflow facts. Language adapters own
concrete grammar, mutator/terminator/callback vocabulary, and type-metadata
syntax. Decomplex, SlopCop, Nil-kill, and Espalier consume public facts and do
not reparse source.

Ruby-to-clear remains responsible for compiler semantics:

- Prism/Sorbet symbol and type resolution;
- concrete method/field/constructor targets;
- optional/union narrowing;
- ownership requirements from resolved signatures; and
- final typed Ruby-to-CLEAR IR.

It may consume FactMine graph and place facts, but it must attach its own typed
facts before deciding ownership. FactMine must not become another string-based
method/type lookup service.

FactMine language adapters are responsible only for projecting concrete syntax
into the shared control-flow vocabulary and for declaring unavoidable
language-specific CFG behavior. They do not make Ruby-to-CLEAR type or
ownership decisions.

## Public Fact Model

### CFG facts

Retain and harden the abandoned branch's core model:

```text
ControlFlowNode
  id
  file / owner / function
  role
  span
  source display

ControlFlowEdge
  from / to
  kind
  predicate or arm identity when applicable
  normal / exceptional / deferred execution class
```

Required edge kinds include entry, fallthrough, branch true/false, case arm,
case default, loop body/exit/backedge, short circuit, return, raise/throw,
break, continue, ensure/finally, and callback.

### Place facts

Names are insufficient for aliasing. Add stable function-scoped places:

```text
PlaceId
  binding identity
  root kind: local / parameter / self / field / global / allocation / unknown
  root declaration span
  projections:
    field(name)
    index(constant)
    index(unknown)
    dereference
```

`user.profile.name` and `other.profile.name` must not collapse merely because
they share a final field name. Shadowed locals must receive distinct binding
identities. Unknown/dynamic projections remain explicit instead of being
guessed.

### Effect facts

Each CFG node may carry normalized effects:

- read place;
- define/write place;
- mutate through place;
- create allocation identity;
- copy/clone/retain/move/borrow when explicit in the source language;
- return/throw/terminate;
- store into field, collection, global, or captured environment;
- capture by value/reference and callback escape class;
- known call target and callee effect summary; or
- unknown call effect.

Unknown calls are important. Compiler consumers must assume an unknown call
may mutate or escape its mutable receiver/arguments. Tier 1 detectors must not
turn that conservative assumption into a finding; they either lower confidence
or omit the finding.

### Dataflow facts

Expose derived facts separately from CFG shape:

- reachable and unreachable nodes;
- immediate dominator and post-dominator where defined;
- reaching definitions for each use;
- use-def and def-use chains;
- live-in/live-out place sets;
- path predicate identifiers;
- may-alias sets;
- must-alias pairs/sets;
- escape destinations and evidence paths;
- function effect summaries; and
- analysis completeness/unknown reasons.

Every public derived row must carry evidence: source spans, participating node
IDs, proof class, and an explanation of any unknown boundary.

## Why Both May-Alias and Must-Alias Are Required

The compiler and analysis products have opposite error budgets.

Ruby-to-clear must be conservative. If two places may alias, it cannot assume
they are independent when choosing mutation, borrow, cleanup, or move behavior.
An unknown call or projection therefore widens a may-set. Safety may require a
copy, shorter borrow, explicit ownership, or rejecting the typed-IR slice.

Tier 1 detector findings must be precise. A report should not accuse code of an
alias hazard merely because aliasing is possible under an unknown dynamic
target. Tier 1 requires a must-alias or otherwise direct proof on a feasible
path. May-alias-only findings are Tier 2 review pressure, not Tier 1 verdicts.

One analysis can serve both users if its lattice preserves both relations:

- may points-to joins by union;
- must points-to survives a join only when the same singleton identity is
  present on every incoming path;
- unknown expands may information and destroys must certainty; and
- detector confidence is derived from proof, not from optimistic absence of an
  edge.

## Feasibility Assessment

### 1. CFG recovery

Verdict: **high feasibility, high immediate value**.

The graph builder, public model, fixtures, validation, and coverage gates
already exist. Required work is:

1. extract the CFG commits without merging unrelated Test Miser history;
2. rebase the builder onto the current normalized/local-flow architecture;
3. split or retain modules according to current FactMine architecture rules;
4. restore public projections and fixtures;
5. validate every supported construct conservatively; and
6. add graph/source digest identity so stale facts cannot be consumed.

The main risk is normalized-AST drift, not algorithmic novelty.

### 2. Generic dataflow

Verdict: **high feasibility for classical local analyses; high value**.

Implement a generic deterministic worklist engine over per-function CFGs. The
first analyses are conventional and should not contain language branches:

- reachability;
- dominators/post-dominators;
- reaching definitions;
- use-def/def-use;
- backward liveness; and
- definite assignment.

These analyses are realistic to hold to a compiler-grade standard within the
supported normalized constructs. They immediately improve redundant-guard,
stale-state, protocol-order, and ownership decisions.

### 3. Local alias and escape analysis

Verdict: **medium feasibility, high value when tightly scoped**.

Start with allocation-site and binding identities inside one function:

- direct assignment and destructuring;
- parameter aliases;
- field/index projections;
- local containers with constant or unknown index classes;
- captured locals;
- return/global/field/collection escape; and
- calls with known effect summaries.

Do not begin with context-sensitive whole-program points-to analysis. Add
interprocedural summaries only for exact call targets and explicit boundaries.
Dynamic/reflective behavior becomes unknown.

### 4. Whole-program alias synthesis

Verdict: **not feasible as a universal precise proof for dynamic languages;
useful as tiered evidence**.

FactMine can aggregate explicit escape paths and resolved call summaries across
functions/components. Espalier can turn those into architectural pressure. It
must not claim that absence of a path proves uniqueness when dynamic dispatch
or reflection is unresolved.

Cross-component must-alias findings can be Tier 1 only when every edge is
explicit and resolved. Broader alias fan-out, entanglement, and inferred shared
identity remain Tier 2/3 prioritization metrics.

## High-Value Novel Metrics

CFG-only work already enables valuable findings. Dataflow and alias facts make
several of them strong enough for Tier 1.

### Decomplex

#### Tier 1: Alias-Mutation Collision

Report a direct alias, a mutation through either name while both aliases are
live, and a later read through the counterpart on the same feasible path.

This is the exact case where CLEAR must not guess snapshot versus shared
identity. Evidence includes alias creation, mutation, last use, and the CFG
path. Only must-alias and resolved mutators qualify for Tier 1.

#### Tier 1: Mutable State Escape / Encapsulation Breach

Report a mutable field or collection derived from `self`/`this` that is
returned, stored globally, or passed into a known escaping boundary without a
copy/read-only wrapper. This operationalizes the existing proposed
Encapsulation Breach metric with evidence instead of getter-name heuristics.

#### Tier 1: Guard Invalidation Before Use

Report a type/nil/state guard that dominates a use but whose guarded place is
definitely mutated through an alias between the guard and use. This finds
TOCTOU-like reasoning errors that syntax-only guard metrics cannot see.

#### Tier 1: Aliased Resource Protocol Violation

For known linear/resource protocols, report close/release/consume through one
must-alias followed by use or a second close through another on a feasible
path.

#### Tier 1 upgrade: Path-Feasible Derived-State Staleness

The current Derived-State Staleness detector is Tier 2 partly because flat
source order confuses mutually exclusive branches and loops. Requiring a
reaching definition, source mutation, and stale use on one CFG path can produce
a narrower Tier 1 form while retaining broad candidates as Tier 2.

### Nil-kill

#### Tier 1: Flow-Safe Guard Collapse

Dominance and reaching definitions can prove that a repeated nil/type guard is
redundant only when no intervening definition or alias mutation invalidates the
first proof. This both creates new safe removals and prevents unsafe current
ones.

#### Tier 1: Narrowing Invalidated by Alias Mutation

Report when `x` is narrowed by a nil/type guard, a must-alias mutates or
replaces the underlying place, and the code continues using `x` under the old
assumption. This is directly relevant to Ruby optional/union normalization.

#### Higher-yield type-origin propagation

Reaching definitions and branch joins can replace the current flat/fixed-point
return-origin heuristics for locals. This should improve the documented
receiver-inference funnel while assigning explicit `unknown` at ambiguous
joins. This is primarily inference infrastructure rather than a standalone
metric.

### SlopCop

#### Tier 1: Statically Unreachable Coverage Arm

CFG reachability plus proven terminal/constant conditions can separate a truly
unreachable arm from an uncovered-but-reachable arm. This reduces false "dead"
or "genuine" classifications without treating missing runtime coverage as
proof.

#### Tier 1 ranking: Uncovered Alias Hazard

Raise the priority of a reachable uncovered arm containing a proven
alias-mutation collision, ownership transfer, cleanup obligation, or guard
invalidation. SlopCop should consume the published hazard span and evidence;
it must not implement alias analysis itself.

#### Tier 1: Uncovered Cleanup/Transfer Outcome

When a branch has a statically explicit ownership/resource acquisition and one
reachable exit lacks the matching cleanup/transfer effect, identify that arm
as a high-priority behavioral gap. This requires exact protocol facts; unknown
calls make it review-only.

### Espalier

#### Tier 1: Explicit Mutable Alias Crossing an Architecture Boundary

Report an object or mutable state view that crosses from one component to
another through an exact resolved return/argument/field-store chain and remains
mutable in both. Evidence must show the explicit path and resolved endpoints.

#### Tier 1: Invariant Bypass Path

Report an internal mutable field that escapes its owner and is later mutated
outside the owner's public mutation methods. This combines the local
Encapsulation Breach fact with Espalier's component/owner graph.

#### Tier 2: Alias Fan-out and Entanglement Density

Aggregate may-alias/escape edges to rank objects shared across many components.
This is valuable architecture pressure but is not Tier 1 unless all paths are
resolved must-alias paths.

## Reliability Standard for Alias Hazards

Detecting "enough" aliasing hazards is worthwhile if scope and proof classes
are explicit. The initial supported high-confidence surface should include:

- local assignment aliases;
- parameter/local aliases with stable binding IDs;
- aliases of fields and constant-index elements;
- mutation through direct assignment or a resolved mutating call;
- aliases that escape by return, field/global store, collection insertion, or
  closure capture;
- loop backedges and mutually exclusive branch arms;
- early return and exception/ensure flow; and
- exact call summaries for known project/stdlib methods.

The initial non-goals are:

- arbitrary reflection or `eval`;
- unknown dynamic dispatch;
- native/FFI mutation without an effect declaration;
- precise identity for unknown collection indices;
- framework callback timing without a callback descriptor;
- lock-free/concurrent happens-before proof; and
- universal whole-program uniqueness proof.

For compiler use, an unsupported construct widens may-alias/escape state or
makes the function ineligible for typed-IR ownership migration. It must never
be treated as evidence of independence.

For Tier 1 findings, an unsupported construct destroys the required proof or
lowers the finding to Tier 2. It must never create a warning merely because the
analyzer is uncertain.

This asymmetry makes a shared engine realistic: conservative for safety,
selective for reporting.

## Quality Gates

### CFG correctness

- Every analyzed function has deterministic entry and exit nodes.
- Every supported executable statement maps to exactly one primary CFG node.
- Every edge target exists and every terminal has the correct exit/cleanup
  behavior.
- Joins, backedges, short-circuit flow, abrupt exits, and ensure/finally edges
  pass graph validators.
- Observed instrumented execution traces for fixtures are legal paths through
  the static CFG.
- Unsupported constructs add conservative unknown edges or make completeness
  false; they do not silently omit flow.
- Public facts include source digest and schema version.

### Dataflow correctness

- Worklist results are independent of traversal/insertion order.
- Golden tests cover diamonds, nested branches, loops, irreducible-looking
  normalized shapes, returns, exceptions, and callbacks.
- Mutation tests prove each transfer/join rule is necessary.
- Differential tests compare small graphs against a simple reference solver.
- The analysis always terminates under explicit lattice-height/iteration
  bounds and reports widening/unknown when a bound is reached.

### Cross-language coverage

- Ruby-to-CLEAR may be the first compiler consumer, but CFG/dataflow algorithms
  contain no Ruby branches and are not landed as a Ruby-only vertical slice.
- Every language-specific CFG rule is located in a marked CFG section in its
  language file; a repository gate reports the per-language CFG-only line
  count.
- Fixtures cover every supported flow construct for Ruby, Python,
  JavaScript/TypeScript, Go, Rust, Zig, Java/C#/Kotlin/Swift, and C/C++ as their
  adapters claim support.
- Language adapters own concrete mutator, terminator, callback, and metadata
  descriptors.
- Oracle fixtures retain at least the abandoned branch's 85% integration and
  approximately 99% combined production-line coverage gates.

### Tier 1 precision

- Create a labeled corpus of positive and adversarial negative alias cases for
  every claimed Tier 1 metric.
- Require at least 95% precision on the labeled in-scope corpus before naming a
  metric Tier 1.
- Require 100% precision on direct fixtures shipped as auto-fixable or
  compiler-actionable.
- Measure recall separately over the declared supported surface. Low recall is
  acceptable initially; hidden uncertainty is not.
- Every finding includes a replayable evidence path rather than only a score.

### Compiler admission

- Ruby-to-clear consumes only facts whose source digest matches the Prism
  source.
- Every migrated Prism executable node maps to a graph node or the whole
  function remains on the legacy path.
- Unknown may-alias/call effects cannot be interpreted as borrow or uniqueness.
- Ownership decisions are present in typed IR before CLEAR emission.
- The seven typed-IR vertical-slice fixtures pass raw G3, not merely IR/text
  assertions.
- No accepted batch lowers raw G2 or G3 source LoC without an explicit reviewed
  reason.

## Implementation Plan

### Phase 0: Recover the language-neutral core without broad merge

1. Extract the graph fact records, construction algorithms, validation,
   projection, metrics, fixtures, and coverage gates from
   `origin/test-miser`.
2. Do not merge unrelated Test Miser or older FactMine refactors.
3. Rebase the builder onto current normalized `MethodSummary` facts.
4. Remove every concrete-language lexicon and source special case from the
   recovered generic files before calling recovery complete.
5. Record behavior differences and regenerate only CFG-specific oracles when
   the current normalized schema changes an historical projection.
6. Restore deterministic graph validation. Source-digest admission belongs at
   the ruby-to-clear consumer boundary in Phase 1B.

Exit gate: current FactMine tests remain green; recovered CFG fixtures and
coverage gates pass; architecture tests prove `syntax/cfg/*` has no concrete
language dependency; no detector consumes the CFG yet.

### Phase 1: Cross-language adapter contract and auditable CFG sections

1. Add a language-owned CFG profile/hook to the normalized behavior contract.
2. Move callback, iterator, empty-body, and any future concrete control-flow
   vocabulary into marked `CFG-SPECIFIC` sections in the appropriate language
   files. Terminators and exceptions already arrive as normalized executable
   nodes and need no concrete-language CFG rule.
3. Add an architecture audit that rejects those lexicons in generic CFG files
   and reports CFG-specific lines by language.
4. Exercise the same graph builder through fixtures from structurally distinct
   languages, including Ruby, Python, JavaScript/TypeScript, Rust, and Zig.
5. Require every supported language adapter either to provide its CFG-specific
   profile or explicitly use the language-neutral default; implicit fallback
   by language name is forbidden.

Exit gate: the recovered CFG is demonstrably cross-language, all concrete
rules are auditable in language files, and the generic builder has no language
branches or concrete vocabulary.

### Phase 1B: Ruby-to-CLEAR consumer admission

1. Add a batch JSON interface so ruby-to-clear does not spawn one process per
   function.
2. Map FactMine functions/statements to Prism nodes by exact source spans and
   source digest in ruby-to-clear, not FactMine.
3. Mark functions incomplete if any executable Prism node lacks a mapping.
4. Complete compiler-consumer fixtures for modifier branches, short circuit,
   case, loops, block callbacks, lambdas, rescue/ensure, early return, `next`,
   and `break`.

Exit gate: all ruby-to-clear typed-IR vertical-slice functions have complete,
validated mappings to the same cross-language FactMine CFG used by other
adapters.

### Phase 2: Classical dataflow

1. Add stable `PlaceId` roots and projections.
2. Implement reachability and dominators.
3. Implement reaching definitions and use-def chains.
4. Implement backward liveness.
5. Expose evidence-bearing public facts and unknown/completeness state.

Exit gate: branch/loop/return fixtures prove path-aware last-use and narrowing
inputs; no ownership decision is implemented yet.

### Phase 3: Ownership transport vertical slice

1. Port the semantic plan from `~/cheat`, not its parser/emitter details:
   `Move`, `Borrow`, `DeepCopy`, and retain of already-declared Rc/Arc.
2. Attach Sorbet-resolved types, call targets, and ownership contracts in
   ruby-to-clear typed IR.
3. Reject mutation-overlap ambiguity; do not infer Rc/Arc identity.
4. Emit ownership operations mechanically from the plan.
5. Keep auto-boxing out of this phase except for destinations whose explicit
   type already forces indirection.

Exit gate: the ten current use-after-move roots no longer fail for that
fingerprint, all vertical-slice fixtures pass raw G3, and G2 does not regress.

### Phase 4: May/must alias and escape facts

1. Add allocation-site identities and assignment aliases.
2. Propagate may/must sets through CFG joins.
3. Add field/index projections and conservative unknown-index behavior.
4. Add return, store, capture, and known-call escape facts.
5. Add exact function effect summaries, bounded fixed-point propagation, and
   explicit unknown summaries.

Exit gate: the labeled alias corpus meets the precision gate and ruby-to-clear
passes the supported ownership/closure fixtures without emitter inference.

### Phase 5: Consumer metrics

Land consumers independently so one detector cannot pressure FactMine into a
detector-specific fact shape:

1. Decomplex local Tier 1 metrics.
2. Nil-kill guard validity and return-origin improvements.
3. SlopCop reachability and hazard ranking.
4. Espalier exact boundary escape paths, followed by Tier 2 aggregation.

Exit gate: each metric publishes measured precision, yield, known blind spots,
and at least one real repository finding that was not available from existing
syntax-only facts.

### Phase 6: G3 and platform decision

Run the complete 169-file verifier after each shared lowering batch. Compare:

- raw G2/G3 files and LoC;
- primary and latent failure clusters;
- ownership-specific root changes;
- CFG mapping completeness; and
- unknown analysis rates.

Continue compiler integration only when it produces measurable G3 progress or
removes a systemic ownership cluster without regression. Continue broader
FactMine alias work only when the Tier 1 precision/yield gates demonstrate
novel value.

## Explicit Non-Decisions

- Do not make ruby-to-clear shell out to FactMine during CLEAR emission.
- Do not let the emitter query CFG or rediscover ownership.
- Do not infer Rc/Arc merely because a value has more than one name.
- Do not use auto-boxing to hide aliasing or mutation collisions.
- Do not report may-alias uncertainty as a Tier 1 hazard.
- Do not claim absence of a FactMine alias edge proves uniqueness.
- Do not revive the old CFG by merging the entire historical branch.
- Do not broaden the G3 effort into whole-program dynamic-language points-to
  research before the local vertical slice passes.

## Final Assessment

1. **Is CFG feasible?** Yes. A substantial implementation and test strategy
   already exist. Recovery and hardening are bounded engineering work.
2. **Is CFG helpful?** Yes. It directly replaces source-offset and
   ancestor-special-case reasoning for narrowing, liveness, closures, and
   ownership. It also improves path precision for all four analysis products.
3. **Is dataflow feasible?** Classical local dataflow is highly feasible.
   Local may/must alias and escape analysis is feasible with a narrower
   supported contract. Universal precise dynamic-language alias analysis is
   not.
4. **Can this produce multiple novel Tier 1 metrics?** Yes, if Tier 1 is
   restricted to feasible paths with must-alias/resolved-effect evidence.
   Alias-Mutation Collision, Mutable State Escape, Guard Invalidation,
   Aliased Resource Protocol Violation, flow-safe guard collapse, and exact
   boundary invariant bypass are realistic candidates.
5. **Can it detect enough aliasing hazards to be worthwhile?** Yes for local
   aliases, explicit escapes, closures, fields, collections, and resolved
   boundaries—the shapes most relevant to ruby-to-clear ownership. Broader
   action-at-a-distance analysis remains a ranked may-alias signal rather than
   a proof.

The immediate recommendation is therefore to recover the cross-language CFG,
move all concrete behavior into auditable adapter sections, add classical
dataflow and stable places, and then use that shared foundation for the bounded
ruby-to-clear ownership vertical slice. General alias metrics should build on
the same facts only after the compiler slice and precision gates demonstrate
that the graph is trustworthy.
