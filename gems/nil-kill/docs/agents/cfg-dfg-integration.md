# CFG/DFG Integration Assessment

Status: implementation assessment and recommendation  
Scope: Nil-Kill, FactMine, Decomplex, Espalier, and SlopCop  
Evaluated implementation: `/home/yahn/litedb`, branch `self-host-i`, through
`ac4174190`, including its uncommitted CFG/DFG follow-on work

## Executive verdict

FactMine's CFG and DFG are valuable to Nil-Kill, but they are not yet a general
replacement for runtime evidence. The best near-term use is as a
path-sensitive static precision layer *before* runtime collection:

1. prove some local reads and returns non-nil;
2. eliminate infeasible definitions after returns and raises;
3. identify conditional-initialization gaps;
4. reserve runtime instrumentation for facts that remain incomplete.

The existing implementation is a credible first vertical slice. It is not yet
production-ready and is materially less complete than the DFG design document
suggests. In particular, Nil-Kill does not currently ingest the emitted
`flow_local_types` facts, and those facts represent literal write hints rather
than a complete type-state analysis.

The recommendation is to harden and consume the narrow slice first. Do not
build a second Nil-Kill-specific control-flow walker. FactMine should remain
the source of language-neutral CFG/DFG facts, and every narrowing decision must
carry completeness and replayable evidence.

## What is implemented today

### CFG

The CFG implementation is substantial rather than a sketch. It contains a
shared graph model, language adapters, recovery behavior, validation, metrics,
and fixtures spanning the supported language set. It already models enough
structure to support:

- reachable nodes;
- branch and exit structure;
- immediate dominators;
- exceptional and recovered control-flow edges;
- per-function analysis boundaries.

This is a strong foundation for path-sensitive analyzers. The remaining work
is primarily semantic precision and hardening, not inventing a CFG system from
scratch.

### DFG

The current DFG computes:

- place and node-effect facts;
- reachability;
- dominators;
- reaching definitions;
- def-use relationships;
- liveness;
- flow-local literal type hints.

The important limitation is that `flow_local_types` is not yet a general type
lattice or a type-state fixed point. A write receives a hint when its right
hand side has a recognized literal form such as string, integer, array, hash,
boolean, symbol, or nil. A read joins the hints attached to its reaching
definitions. The result is marked complete only when every reaching definition
has such a hint.

That is useful, but it does not yet infer types through calls, parameters,
fields, collection elements, guards, or aliases.

### Gaps visible in the implementation

The effect and place model still lacks several facts Nil-Kill needs for broad
static resolution:

- stable identities for parameters and shadowed bindings;
- receiver-rooted field and index projections;
- allocation identities;
- captures and escapes;
- edge predicates for nil, truthiness, and type guards;
- invalidation of a guard after mutation;
- known call return/effect summaries;
- loop-carried type-state joins;
- post-dominators where an obligation depends on all exits.

Calls are presently classified as unknown rather than summarized. Direct
non-local assignments provide some mutation effects, but mutating calls do not
yet form a general mutation model.

There is also a documentation/implementation mismatch: the DFG design says
Nil-Kill consumes Ruby/Python flow-local literal types, but a repository search
found no Nil-Kill consumer. The Nil-Kill FactMine profile emits the table and a
FactMine test covers it; the Ruby analyzer does not read it.

### Current test state

The implementation must be made green before it becomes a dependency of a
Tier-1 finding:

- `cargo build` succeeds in the inspected LiteDB tree.
- `cargo test --lib syntax::cfg` does not compile because two CFG test helpers
  construct `ControlFlowFacts` without the fields recently added by the DFG.
  The same defects exist at the inspected committed `HEAD`, not only in the
  dirty follow-on work.
- Dataflow and effect extraction lack direct semantic unit-test matrices.
- The cross-language gate proves that fact rows exist and are marked complete;
  it does not yet prove that reads, writes, mutations, joins, and liveness are
  correct for each language.
- One early-return/literal-flow oracle is valuable, but diamonds, loops,
  shadowing, exception paths, callbacks, and negative completeness cases need
  explicit oracles.

## Measured value on the CLEAR Ruby compiler

Running the inspected FactMine Nil-Kill profile over the 170 files in
`compiler/ruby` produced:

- 45,936 `flow_local_types` read-site rows;
- 849 complete rows (1.85%);
- 349 distinct places across 250 functions and 69 files;
- 815 complete, useful non-nil rows;
- 34 complete nil-only rows;
- 16 complete rows with more than one possible literal type.

The run took about 150 seconds using the current debug/dirty LiteDB build. That
is a development measurement, not a production performance baseline.

The 815 non-nil facts are real near-term value: they can avoid some runtime
observation and improve local and return inference. The low completeness rate
also establishes the boundary. Literal propagation alone cannot resolve most
remaining types because real compiler values arrive through parameters,
method calls, instance state, and generic containers.

## Nil-Kill integration design

### Safe first increment

Add a consumer for `flow_local_types` to Nil-Kill's FactMine static-fact path:

1. map language-neutral literal hints into the Nil-Kill/Sorbet type lattice;
2. key facts by file, owner, function, stable place, read node, and span;
3. attach facts to local reads, return origins, and receiver inference;
4. use complete rows for narrowing and actionable inference;
5. use incomplete rows only for ranking or explanatory evidence;
6. record the reaching definitions and CFG nodes behind every conclusion.

A method-wide map keyed only by variable name would be unsound. Shadowing and
path-specific definitions require stable binding/place identity.

### Highest-value next increment

Add edge predicate facts and type-state transfer for:

- nil and non-nil branches;
- type tests;
- truthiness where the source language defines it precisely;
- early return/raise guards;
- invalidation when the guarded place or one of its projections is mutated.

This is where CFG/DFG becomes especially valuable to Nil-Kill. It permits a
fact such as “`x` is non-nil in this dominated region” without globally
declaring `x` non-nil and without retaining runtime instrumentation inside the
proven region.

### Runtime evidence remains necessary

Static completeness must be conservative. Unknown calls, reflective behavior,
dynamic dispatch without a closed target set, and unresolved container payloads
remain runtime-observed. The integration should reduce tracing locally rather
than treating the presence of a CFG as proof that a whole method is resolved.

## Estimated work

These are focused engineering estimates, not schedule commitments:

| Increment | Estimated focused effort | Result |
| --- | ---: | --- |
| Make the existing DFG green and add semantic diamond/loop/exception/negative tests | 1–3 days | A trustworthy literal-flow substrate |
| Consume complete literal-flow facts in Nil-Kill | 3–5 days | Hundreds of currently measured static non-nil/type facts |
| Add stable bindings, predicates, invalidation, and real type-state joins | 1–2 weeks | Material reduction in remaining local/return unknowns |
| Add projections and project-call summaries | 1–2 additional weeks | State/container and first alias-sensitive facts |

Each increment should be corpus-measured before starting the next. A high row
count is not success; resolved high-frequency instrumentation sites and
zero-false-positive Tier-1 findings are the useful metrics.

## Novel Tier-1 SARIF opportunities

Tier 1 means the analyzer has a complete proof for the reported surface. It
must not promote an incomplete or unknown-call path into a blocker.

### Available after hardening the current CFG/DFG

| Product | Finding | Why it is valuable |
| --- | --- | --- |
| SlopCop | Proven dead store | A reaching definition has no feasible def-use and is not needed for cleanup. High confidence and directly fixable. |
| Nil-Kill | Conditional initialization gap | A live read has at least one feasible path with no reaching definition. Finds real nil/uninitialized hazards. |
| Nil-Kill | Redundant nilable return contract | Every feasible return is proven non-nil and no implicit nil fallthrough is reachable. Narrows APIs safely. |
| Decomplex | Feasible definition fan-in | Counts only definitions that can actually reach a use, exposing state convergence that textual complexity misses. |
| Decomplex | Peak live mutable-state width | Measures how much mutable state a function requires simultaneously, a useful local-reasoning metric. |

The first three best candidates are proven dead store, conditional
initialization gap, and feasible definition fan-in. They need no alias engine.

### Available after predicates and mutation effects

| Product | Finding | Required proof |
| --- | --- | --- |
| Nil-Kill | Invalidated non-nil/type guard | A guard dominates a use, but a feasible intervening mutation invalidates the guarded place. |
| SlopCop | Stale derived value | A value derived from a mutable source remains live across a proven source mutation and is later consumed. |
| Decomplex | Guard-to-use mutation distance | Quantifies how much mutable work separates a safety proof from its dependent use. |
| Espalier | Constructor invariant bypass | A public escape or return is reachable before required fields are definitely assigned. |

### Available after the first alias/escape slice

| Product | Finding | Required proof |
| --- | --- | --- |
| FactMine/Espalier | Alias-mutation collision | A must-alias is created, one alias is mutated, and the counterpart is subsequently read on a feasible path. |
| FactMine/Espalier | Mutable state escape | A mutable local or receiver projection escapes to a longer-lived boundary while a local alias remains live. |
| SlopCop | Aliased resource double-use | Two must-aliases reach mutually exclusive consume/close obligations incorrectly. |
| Espalier | Escaping closure captures mutable state | A closure outlives the scope while retaining a mutable place that is also used locally. |

These findings are more novel than generic complexity scores because they
combine control-flow feasibility with data dependence and can point to the
exact proof-breaking edge.

## High-value alias hazards without an endless stdlib catalogue

Detecting *some* valuable alias hazards is substantially smaller than building
a whole-language points-to analyzer. A deliberately narrow Tier-1 surface can
start with syntax and project code that FactMine can prove:

```ruby
y = x          # creates a direct must-alias
x.field = 1    # direct mutation of a known projection
consume(y)     # counterpart is subsequently used
```

The initial analysis needs:

1. stable binding and allocation identities;
2. places with receiver/field/constant-index projections;
3. transfer and join rules for direct must- and may-alias assignments;
4. direct assignment, augmented-assignment, and index mutation effects;
5. the existing reachability and liveness facts to prove the
   alias-create → mutate → counterpart-use path;
6. replayable evidence, completeness reasons, and adversarial negative tests.

It does **not** require a hardcoded list of every mutating stdlib method.
Project methods can receive effect summaries inferred from their bodies:

- mutates receiver or argument projection;
- returns or escapes receiver/argument;
- consumes a resource or ownership token.

For unresolved external calls, the sound behavior is to mark the affected
surface unknown and withhold a Tier-1 finding. A small adapter-owned catalogue
for fundamental built-ins can improve recall, but correctness must not depend
on an endlessly maintained name list.

Estimated effort after the DFG is hardened:

- direct local must-alias plus direct mutation: roughly 4–7 focused days,
  approximately 600–1,000 production lines and 700–1,200 lines of proof and
  adversarial tests;
- field/index projections and inferred project-call summaries: another 1–2
  weeks;
- closure, escape, and cross-component aliasing: another 1–2 weeks.

This narrow slice is intentionally smaller than a full alias-analysis stage.
It sacrifices recall, not precision. Unknown behavior stays unknown, while the
direct cases become high-confidence SARIF findings without stdlib-name debt.

## Recommended order

1. Make LiteDB's existing CFG/DFG tests compile and add semantic dataflow
   matrices.
2. Integrate only complete literal-flow facts into Nil-Kill and measure how
   many hot trace sites disappear.
3. Add stable binding IDs, edge predicates, invalidation, and type-state joins.
4. Ship the first three CFG/DFG Tier-1 findings: dead store, conditional
   initialization gap, and feasible definition fan-in.
5. Add the narrow direct alias/mutation slice, withholding findings whenever a
   call or escape is incomplete.
6. Expand projections and inferred project-call effects only after the direct
   slice is green and its SARIF precision is demonstrated.

This sequence maximizes local reasoning and avoids parallel analyzers. It also
keeps the safety boundary explicit: FactMine owns the graph facts, consumers
own product-specific interpretation, and incompleteness can reduce recall but
can never manufacture certainty.
