# Static Nil Pressure for Go, C, and C++

Status: Proposed design

Scope: extend FactMine's existing normalized analysis and let NilKill consume
the resulting causal facts

## Executive decision

NilKill can provide useful static nil-pressure analysis for Go, C, C++, and
other languages that do not enforce `Option<T>`/`?T`. The implementation must
build on FactMine's existing normalization-first architecture.

It must **not** re-extract ordinary program semantics through `.scm` hazard
queries.

FactMine already does the important language-neutral work:

1. Tree-sitter parses concrete source.
2. language AST adapters normalize concrete syntax into a shared AST;
3. the stateless normalized extractor records functions, calls, assignments,
   comparisons, branches, cases, state reads/writes, and effects;
4. stateful enrichment builds local-flow statements, CFG nodes/edges, places,
   reaching definitions, def-use, dominators, liveness, and flow types;
5. normalized nil-guard analysis already understands `NIL`, comparisons,
   predicate hooks, safe navigation, branch polarity, and invalidation.

The `.scm` files have a separate job: they populate `hazard_sites` for narrow
syntax-defined hazards and their evidence policies. They are not FactMine's
general extraction layer.

The target architecture is therefore:

```text
concrete Tree-sitter AST
          |
          v
language AST normalization adapter
          |
          v
shared normalized AST
          |
          +--> stateless normalized facts
          |
          +--> existing CFG/DFG/type-hint/nil-guard enrichments
          |
          +--> NEW nullable-flow and primitive-domain enrichments
                          |
                          v
                 stable public FactMine facts
                          |
                          v
              NilKill causal pressure report
```

Language-specific work should remain limited to:

- normalization adapters when a concrete construct is not yet represented
  correctly in the normalized AST;
- small `NormalizedLanguageBehavior` descriptors for semantics that differ
  after normalization;
- reviewed declarative API/type contracts where source syntax alone cannot
  supply the fact.

No Go compiler API or Clang integration belongs in the initial design. Those
would improve completeness in hard semantic cases, but do not justify their
deployment and maintenance cost until real false-negative evidence proves a
need.

Do not build a general Go/C/C++ runtime tracer. Runtime artifacts may later
confirm or prioritize a static finding, but they should not participate in
the static null-state proof.

Hidden-enum discovery should extend FactMine's existing normalized hidden-enum
observations. It should not be reimplemented with `.scm` queries.

## Existing FactMine capabilities to reuse

### Normalized AST

The current normalized vocabulary already represents the core constructs this
analysis needs:

- `NIL` for null/nil literals;
- `LASGN`, `DASGN`, `IASGN`, `GASGN`, `MASGN`, and attribute assignments;
- `LVAR`, `DVAR`, `IVAR`, `GVAR`, and receiver/member projections;
- `CALL`, `QCALL`, `FCALL`, `VCALL`, and `OPCALL`;
- `IF`, `UNLESS`, `AND`, `OR`, `CASE`, `WHEN`, loops, and returns;
- normalized argument and collection nodes.

If Go, C, or C++ syntax fails to produce the appropriate normalized shape,
the fix belongs in `ast/adapters/<language>` or the shared normalizer. A hazard
query would create a second representation that cannot naturally participate
in the CFG and def-use analysis.

### Stateless normalized facts

`normalized_extractor` already emits:

- function and owner identities;
- calls and receiver projections;
- state declarations, reads, and writes;
- decisions, branch arms, dispatch sites, and comparisons;
- nil-comparison `eliminable_guard` effects;
- language-owned semantic effects.

These should be reused. Nullable analysis does not need its own call,
comparison, switch, or field scanner.

### CFG and dataflow

The current CFG enrichment already exposes:

- stable places;
- node effects with reads, writes, and mutations;
- exact `write_value_hints`, including `nil`;
- `write_type_hints` from normalized literals and explicit declarations;
- direct assignment flow through `write_sources`;
- direct call-result producers through `write_call_sources`;
- unknown-call and completeness information;
- reachability, dominators, reaching definitions, def-use, and liveness;
- propagated local flow types with completeness.

This is almost the entire substrate needed for local nullable provenance. The
new work should extend this dataflow rather than build a parallel flow graph.

### Existing nil guards

`redundant_nil_guard` already consumes normalized AST and language-owned guard
descriptors. It understands:

- `x == nil` and `x != nil`;
- nil predicate methods exposed through `nil_guard_fact`;
- negation and branch polarity;
- conjunctions;
- safe-navigation receiver facts;
- truthy branches where appropriate;
- early branch flow and reassignment invalidation;
- stable local/receiver field subject keys.

The new nullable-flow engine should not duplicate this interpretation. First
extract a reusable normalized refinement stream from that logic, then let both
redundant-guard detection and nullable propagation consume it.

This is a worthwhile architectural cleanup: nil semantics have one normalized
owner instead of being rediscovered separately by each detector.

### Existing hidden-enum observations

FactMine's type-inference visitor already walks normalized AST for hidden-enum
evidence from:

- cases/switches;
- equality and inequality comparisons;
- membership operations;
- parameter, field, and other stable slot origins.

The cross-language work should extract/generalize that existing normalized
pass and combine it with already-produced `comparison_uses`, `dispatch_sites`,
state identities, CFG places, and literal `write_value_hints`.

It should not add a second hidden-enum collector in `.scm` files.

## What `.scm` files should and should not do

The current hazard queries are appropriate for facts such as:

- raw-memory APIs;
- concurrency primitives;
- dynamic loading;
- reflection;
- sanitizer-relevant syntax;
- function-pointer invocation shapes that are unambiguous in a language.

Those are independent site classifications with an evidence policy. They do
not require the query to become the canonical representation of assignments,
branches, or value flow.

For this design, `.scm` should be used only if a new nil-related hazard is:

1. a stand-alone syntax-defined site;
2. not already represented by normalized AST/facts;
3. not needed by the nullable dataflow engine;
4. more appropriately a `hazard_site` than a value-flow fact.

The expected initial number of new nil-pressure `.scm` captures is zero.

## Product goal

A normal nil checker asks:

> Can this operation receive null?

NilKill should additionally answer:

> Which producer introduced nil, which downstream guards and nullable
> contracts exist because of it, and what complexity would disappear if that
> producer became total or represented absence explicitly?

For example:

```text
cacheLookup is the nullable root for 11 resolved consumers.

- 7 distinct guard/recovery sites
- 2 propagated nullable returns
- 1 unchecked dereference
- 1 repeated guard after invalidation
- local analysis complete for 9/11 consumers
- 2 consumers terminate at unresolved boundaries and are not scored beyond it
```

The causal explanation is NilKill's differentiator. Counting every pointer or
repeating compiler warnings would add little value.

## Normalized nullable analysis

### State lattice

Add one null-state lattice to FactMine's CFG/dataflow layer:

```text
unreachable
definitely_null
definitely_non_null
maybe_null
unknown
```

`unknown` must remain distinct from `maybe_null`:

- `maybe_null` means FactMine proved both null and non-null definitions can
  reach the use.
- `unknown` means the analysis does not have enough information.

Unknown state lowers completeness and stops unsafe propagation. It must not
create a finding or increase pressure.

### Sources

Derive sources from existing normalized facts wherever possible:

- a `NodeEffect.write_value_hints` value of `nil`;
- a `write_type_hints`/declared type that explicitly permits nil;
- a direct call-result source whose exact reviewed contract permits nil;
- an explicit nullable parameter or field declaration;
- a language construct normalized into an absence-producing operation;
- an unresolved producer, represented as unknown rather than maybe-null.

API contracts should live in a reviewed, versioned declarative registry at the
FactMine language boundary. Do not infer contracts from names such as `find`,
`get`, `lookup`, `err`, `ptr`, or `optional`.

### Transfers and joins

Reuse:

- `write_sources` for direct assignment;
- reaching definitions for branch/loop joins;
- `write_call_sources` for call-result origins;
- def-use facts for consumers;
- existing receiver/state identities for bounded field flow;
- callable summaries over resolved FactMine call edges.

The intended scope is intraprocedural fixed-point analysis plus conservative
call summaries. It is not a new whole-program points-to engine.

### Refinements

Create a reusable normalized refinement fact from existing nil-guard logic:

```text
place_id
condition_node_id
edge/polarity
state_on_edge
proof_kind
source_span
complete
```

Inputs include:

- normalized equality/inequality with `NIL`;
- language-owned nil/non-nil predicates;
- early exit from the opposite branch;
- safe navigation where its semantics establish receiver presence;
- explicit presence correlations;
- reviewed assertion contracts.

Both the existing redundant-guard detector and the new nullable-flow analysis
should consume these facts.

### Invalidations

Use existing writes/mutations and CFG order to invalidate refinements after:

- direct reassignment;
- a locally visible write through an alias;
- receiver/field mutation affecting the place;
- passing a place across an unresolved mutating call boundary;
- shared/concurrent mutation whose stability cannot be proved.

When alias impact is unclear, transition to `unknown`. Do not preserve a
non-null proof optimistically.

### Sinks

Add a normalized nullable-operation classification keyed to existing call,
receiver, index, and member facts:

```text
operation_span
subject_place
operation_kind
nil_behavior
complete
```

Example behavior values:

- `safe`;
- `panic`;
- `undefined_behavior`;
- `blocks`;
- `contract_violation`;
- `unknown`.

Generic extraction identifies the normalized operation. A small
`NormalizedLanguageBehavior` descriptor supplies only behavior that truly
differs by language. It must not traverse the source tree or implement
dataflow.

Relevant sinks include:

- pointer/receiver dereference;
- invoking a callback/function value;
- indexing or mutation requiring usable backing storage;
- passing to an explicitly non-null contract;
- returning/storing through an explicitly non-null contract.

Nil-like values are not uniformly unsafe, so the operation behavior must be
preserved rather than reduced to a boolean.

## Proposed FactMine public facts

### `nullable_refinements`

Branch-local proof facts extracted once from normalized nil-guard semantics.

### `nullable_states`

For each relevant CFG node/place:

```text
node_id
place_id
state
source_definition_ids
complete
unknown_reasons
```

### `nullable_operations`

For each safe, unsafe, or unresolved nil-sensitive operation:

```text
node_id/span
place_id
operation_kind
nil_behavior
state_at_operation
complete
```

### `nullable_summaries`

For each callable, only where proven:

- return null state and contributing origins;
- nullable parameter accepted;
- parameter dereferenced, returned, or stored;
- parameter/receiver/field-to-return flow;
- visible mutations invalidating caller facts;
- unresolved boundaries.

### `presence_correlations`

Presence and nullability must remain distinct:

```text
group_id
value_place_id
presence_place_id
semantics
branch refinement
complete
```

For example, Go's `value, ok := m[key]` establishes key presence. It does not
prove that a present map value is non-nil.

## Language-specific additions

### Go

Most Go syntax already normalizes through the shared AST. Necessary work should
be narrowly scoped to semantic descriptors and any missing normalized shape.

Nil-capable representations behave differently:

| Representation/operation | Nil behavior |
| --- | --- |
| Pointer dereference/selector | Panics |
| Calling a function value | Panics |
| Map read/range | Safe |
| Map write | Panics |
| Slice append/range | Safe |
| Slice indexing | Requires an element; nil is not a separate index rule |
| Channel send/receive | Blocks |
| Channel close | Panics |
| Interface comparison | Non-nil interface may contain typed-nil payload |

Use explicit declared types and proven normalized flow when available. When
the kind is inferred through an unresolved external producer, use unknown.

Add normalized presence semantics for:

- comma-`ok` map lookups;
- comma-`ok` type assertions;
- channel receives, preserving their actual closed-channel semantics.

This likely requires ensuring those multiple assignments normalize cleanly,
then emitting a small presence descriptor from the normalized shape. It does
not require a `.scm` query or a second Go AST walk.

Do not infer `(value, err)` correlations from naming. `err == nil` proves a
value non-null only when an exact reviewed callable contract states that
relationship.

Typed-nil interfaces should remain an explicit limitation. Without a proven
payload assignment, an interface non-nil guard must not be treated as proof
that a pointer payload is non-null.

### C and C++

The useful lightweight scope is explicit normalized evidence:

- null literals and direct pointer flow;
- explicit nullable/non-null annotations already captured as declared types;
- null comparisons and early exits;
- normalized dereference/member/callback operations;
- high-value exact contracts such as allocators;
- reassignment and locally visible alias mutation;
- unknown boundaries around unresolved macro/typedef/template/overload
  semantics.

Special cases:

- ordinary throwing C++ `new` is not a nullable source;
- `new (std::nothrow)` and `dynamic_cast<T*>` are nullable sources when
  normalization preserves those constructs;
- smart pointers and `std::optional` are not raw pointers;
- `realloc` needs an exact contract because failure returns null while
  preserving the original allocation;
- names containing `ptr`, `optional`, or `handle` prove nothing.

If the normalized AST loses one of these constructs, add the minimum
language-adapter metadata or normalized node required by the generic pass.
Do not bypass normalization with detector-specific raw traversal.

The result will intentionally miss behavior hidden behind macros, typedef
chains, templates, and overload resolution. Reports must expose those as
completeness boundaries rather than claim semantic completeness.

## Nil-pressure calculation in NilKill

NilKill should consume public FactMine facts only. It should not inspect source
AST or rebuild CFG/DFG.

For each nullable root, retain an evidence vector:

- distinct downstream guard/recovery clusters;
- propagated nullable returns;
- resolved callable boundaries reached;
- unchecked unsafe operations;
- redundant guards after an established proof;
- invalidations forcing repeated guards;
- confirmed runtime failures, if later imported;
- analysis completeness and unknown boundaries.

Pressure is the counterfactual number of independently necessary obligations
that would disappear if the producer became total or represented absence
explicitly. It is not:

- pointer count;
- raw path count;
- call count;
- runtime execution count;
- a universal safety score.

Equivalent guards and paths must be deduplicated. An unknown boundary must not
increase confidence or pressure.

## Runtime evidence

### Difference from Ruby collection

Ruby runtime collection supplies semantic information that cannot reliably be
derived from syntax:

- actual parameter and return classes;
- observed nil at parameters, returns, fields, and collections;
- dynamic call edges;
- runtime shapes and exceptions;
- coverage supporting later inference.

That evidence is a primary input to Ruby type/pressure inference.

Go/C/C++ source already declares much more representation information. Runtime
execution supplies only sampled paths and failures; it cannot prove that nil
is impossible. Therefore it should not reproduce Ruby's normal-execution value
tracer.

### Potential optional artifacts

| Artifact | Fact supplied | Possible benefit | Limitation |
| --- | --- | --- | --- |
| Coverage | Executed source spans/branches | Rank an already-static finding or expose untested paths | Cannot prove non-nullness |
| Panic/crash | Failure kind, sink span, stack | Confirms that an unsafe operation failed | Does not identify the root unless static flow does |
| Fuzz failure | Repro input plus crash | Makes a confirmed failure reproducible | Adds no distinct semantic fact |
| ASan/UBSan | Concrete invalid operation and stack | Confirms a C/C++ sink | Says nothing about unexecuted paths |

Race-detector evidence should not enter nil-pressure scoring. Relating a race
to invalidated nullness requires alias/happens-before reasoning that this
lightweight analysis deliberately does not implement.

Runtime import is not part of the initial plan. Consider it only if Lineage or
FactMine already has a generic artifact-ingestion path and real users show
that confirmation materially improves prioritization.

If later added:

- ingest existing artifacts rather than rewrite source;
- execute only on user/CI infrastructure;
- retain run/test provenance and staleness;
- store `observed_nil` or `confirmed_failure`, never `proven_non_null`;
- keep frequency separate from causal pressure;
- collect no pointed-to contents or arbitrary raw values.

## Primitive-domain pressure: hidden enums

This should be an extraction/generalization of existing FactMine behavior, not
a new detector architecture.

### Reuse

Build candidates from:

- existing hidden-enum normalized observations;
- `comparison_uses`;
- `dispatch_sites` and branch arms;
- state identities and CFG places;
- literal `write_value_hints`;
- reaching definitions and def-use;
- callable/field identities already emitted by FactMine.

Move the reusable candidate observations out of Ruby-oriented type-inference
report construction if necessary, but retain one normalized implementation.

### High-signal candidate rules

Report only when:

- all evidence connects to one stable field/parameter/return/local place;
- the representation is a raw string/integer/character-like primitive rather
  than an existing enum/closed type;
- the domain contains 2 through 10 values;
- there are at least two decision sites, or one strong switch plus a closed
  set of literal producers;
- no open-world producer introduces arbitrary values;
- joins follow FactMine identities and flow, not source spelling.

Open-world blockers include:

- network, database, file, environment, CLI, or deserialization input;
- public/external callers without a closed contract;
- FFI values;
- string construction/interpolation/parsing;
- unresolved calls or writes.

Suppress or downgrade:

- Go named primitive types with deliberate `const` domains;
- C/C++ enums;
- well-formed named constants/macros already expressing the domain;
- wire/protocol status codes whose primitive representation is intentional;
- external library status/error codes.

Start with string domains. Integer candidates are noisier because flags,
sizes, sentinel values, and protocol constants resemble enums. Gate them on a
separate precision corpus.

Repeated `if` conditions strengthen a candidate only when FactMine place and
flow facts show that they inspect the same semantic slot. Never group by:

- variable-name similarity;
- token/text similarity;
- common literal sets alone;
- repository-wide condition resemblance.

Do not collect raw runtime strings/integers for this feature. Do not autofix
enum candidates until report quality and API/serialization consequences have
separate designs.

## Implementation phases

### Phase 0: verify and expose existing facts

- Add focused public-fact fixtures for `NIL`, direct nil assignment,
  comparisons, `QCALL`, CFG places, reaching definitions, and flow hints in
  Go/C/C++.
- Identify missing normalized shapes rather than assuming they are absent.
- Document current completeness behavior at unresolved calls.

Acceptance:

- no new detector exists yet;
- every planned input is mapped to an existing FactMine fact or a precisely
  identified missing normalized fact;
- `.scm` hazard output is not used as a substitute.

### Phase 1: shared nullable refinements

- Extract reusable branch-refinement facts from existing nil-guard logic.
- Refactor redundant-nil-guard analysis to consume them.
- Preserve behavior and fact output for existing languages.

Acceptance:

- nil comparison/predicate/safe-navigation semantics have one owner;
- redundant-guard results remain stable;
- no language branches appear in the generic refinement engine.

### Phase 2: nullable CFG state

- Extend existing CFG dataflow with the null lattice.
- Seed it from existing value/type/call-source facts.
- Propagate through reaching definitions and direct flow.
- add invalidation and completeness handling;
- emit nullable states and local summaries.

Acceptance:

- no parallel CFG or assignment scanner is introduced;
- unknown never becomes maybe-null;
- geometric scaling stays near-linear;
- output is deterministic across parallel parsing.

### Phase 3: language operation/presence descriptors

- Add minimal Go nil-operation behavior and presence-pair semantics.
- Add minimal C/C++ explicit-pointer operation behavior.
- Fix normalization only where concrete syntax does not reach a usable shared
  shape.
- add reviewed exact contracts through declarative language configuration.

Acceptance:

- Go safe nil-map/slice operations do not become false positives;
- presence is not conflated with non-null payload;
- throwing `new`, smart pointers, and `std::optional` are not mislabeled;
- unresolved constructs lower completeness.

### Phase 4: NilKill causal pressure

- Consume nullable public facts.
- Group source-to-obligation paths by root.
- Deduplicate guards and paths.
- Report unsafe operations, propagation, repeated/redundant guards, and
  completeness.

Acceptance:

- NilKill does not parse source or inspect normalized AST;
- making a fixture source total removes exactly the expected obligations;
- unknown boundaries do not increase confidence or score.

### Phase 5: generalize primitive domains

- Extract/reuse current hidden-enum observations as a stable FactMine section.
- join them with existing comparison, dispatch, literal, and flow facts;
- start with string domains and report-only output;
- gate integer candidates independently.

Acceptance:

- no second normalized AST traversal duplicates existing observations unless
  profiling proves consolidation would be worse;
- same-spelled unrelated locals never join;
- open-world and existing-enum cases are suppressed.

Runtime artifact import and compiler-native semantic integrations are not
implementation phases. Both require measured evidence of a material residual
gap.

## Test matrix

### Existing-fact contract tests

- nil literal normalization;
- direct assignment value/type hints;
- nil comparisons and branch polarity;
- safe navigation;
- state/local place identity;
- reaching definitions and def-use;
- call-result source spans;
- unknown-call completeness.

### Shared nullable engine

- direct flow and branch joins;
- early-exit and nested guards;
- loops/fixed-point convergence;
- reassignment after proof;
- local alias invalidation;
- parameter/field-to-return flow;
- unresolved call boundary;
- safe versus unsafe operation;
- presence flag not proving non-null payload.

### Go

- pointer dereference and nil function call;
- safe map read/range and unsafe map write;
- safe slice append/range;
- comma-`ok` lookup/type assertion;
- present map value containing nil;
- typed-nil interface limitation;
- nil channel block/panic behavior;
- `(value, err)` with and without an exact contract.

### C/C++

- checked and unchecked allocator results;
- `realloc` contract;
- direct nullable/non-null annotation;
- pointer/function-pointer operations;
- local alias mutation;
- throwing versus nothrow `new`;
- `dynamic_cast<T*>`;
- raw versus smart pointer and `std::optional`;
- macro/typedef/template/overload completeness loss.

### Hidden enums

- one field compared across several functions;
- same-spelled locals that must not join;
- switch plus closed literal producers;
- open-world producer blockers;
- existing Go const domain and C/C++ enum;
- integer flag/sentinel negatives;
- one genuine hidden state enum.

### Performance and architecture

- golden normalized/public facts;
- deterministic output across worker ordering;
- geometric file/callable growth;
- no repeated whole-function scan per candidate/source/sink;
- architecture test forbidding NilKill source parsing;
- architecture test preventing nil-pressure use of `hazard_sites` as its
  assignment/branch/value-flow source;
- manual precision audit on real repositories.

## Estimated production code

Excluding tests and fixtures:

| Work | Estimated LoC |
| --- | ---: |
| Reusable nullable refinement facts/refactor | 180–320 |
| Nullable state over existing CFG/dataflow | 350–650 |
| Go/C/C++ behavior descriptors and normalization gaps | 150–350 |
| Public fact projection/hydration | 100–180 |
| NilKill causal pressure consumer | 250–450 |
| Hidden-enum fact extraction/generalization | 180–350 |

The static nil-pressure slice is approximately 1,030–1,950 production lines
plus tests. It is smaller than a query-first redesign because FactMine already
owns most of the necessary representation and algorithms.

The estimate should fall further after Phase 0 establishes exactly which facts
already cover each case. If implementation starts adding duplicate AST scans,
CFGs, assignment extraction, or language branches in NilKill, stop and correct
the architecture.

## Explicitly do not build

- `.scm` replacements for normalized assignments, calls, branches,
  comparisons, cases, guards, or hidden-enum observations.
- A parser, normalized AST, or dataflow engine inside NilKill.
- A second CFG/DFG for nullable analysis.
- A whole-program points-to implementation per language.
- Native Go/Clang integration in the initial design.
- A general Go/C/C++ value tracer.
- Contract inference from variable/API/type names.
- Pointer-count or nullable-type-count risk scores.
- Race-detector findings in nil-pressure scoring without a proven null path.
- Raw runtime value collection for hidden enums.
- Hidden-enum grouping by spelling or condition similarity.
- Automatic enum rewrites before report quality is proven.

## Recommended first deliverable

Complete Phase 0 before adding production analysis. It should produce a small
mapping such as:

```text
required concept              existing owner/fact                 gap
nil literal                   normalized NIL/write_value_hints    none
direct assignment             write_sources/reaching definitions none
branch guard                  redundant_nil_guard semantics       reusable public refinement
call-result producer          write_call_sources                  return contract/state
unsafe operation              normalized call/member/index facts behavior descriptor
presence pair                 normalized MASGN/index/assertion    correlation fact
hidden enum decision          existing normalized observations    stable public projection
```

Then implement the shared refinement and nullable-state facts for Go first.
This proves the value of causal nil pressure while reusing FactMine's actual
architecture and adding no new parser/query subsystem.
