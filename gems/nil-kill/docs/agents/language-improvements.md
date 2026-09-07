# NilKill Cross-Language Static Analysis Improvements

Status: Design and implementation guidance  
Scope: NilKill, FactMine, optional semantic providers, and CodeQL integration

## Executive verdict

NilKill is currently a strong Ruby/Sorbet type-pressure analyzer with a
cross-language evidence framework. It is not yet a comparably capable
cross-language nullability analyzer.

The correct architecture is:

1. FactMine owns normalized nullable-flow facts and the portable local
   CFG/DFG analysis.
2. CodeQL is an optional semantic provider for deep interprocedural analysis
   in languages it supports.
3. Native compiler or language-server providers may emit the same normalized
   facts when they are cheaper or more precise than CodeQL.
4. NilKill owns runtime observations, causal pressure, prioritization, and
   action generation.
5. Auto-Type owns source rewriting.

NilKill should not be moved wholesale to CodeQL. FactMine should not attempt to
reimplement a whole-program points-to and interprocedural dataflow engine for
every language. FactMine should instead provide the stable fact boundary and
optionally import CodeQL results.

## Current capability asymmetry

The provider abstraction is language-neutral, but the implemented capability
depth is not.

| Capability | Ruby | Python | Other languages |
| --- | --- | --- | --- |
| Tree-sitter and FactMine facts | Yes | Yes | Yes |
| Real type-checker integration | Sorbet | No | No |
| Runtime parameter and return observations | Yes | Yes | No |
| Runtime exceptions | Yes | Yes | No |
| Runtime fields, collections, and hash shapes | Yes | Yes | No |
| Return and field contract index | Yes | No | No |
| Verified source rewriting | Ruby/Sorbet through Auto-Type | Not production-ready | No |
| Language-specific fallibility and enum analysis | Extensive | No equivalent | No equivalent |

The base provider defaults to syntax-only static analysis with no semantic
type system and no runtime collection. Ruby adds:

- Sorbet checker and RBI integration;
- return and field type indexes;
- parameter, return, exception, field, collection, hash-shape, call-edge, and
  coverage observations;
- in-place Ruby source instrumentation;
- Ruby-specific static-diff auditing;
- Ruby-specific hidden-enum, fallibility, struct, and signature processing;
- Z3 inference expressed largely in Ruby/Sorbet type terms.

Python has broad runtime collection, but no Python type-checker backend.
TypeScript and JSDoc declarations are parsed as syntax rather than verified by
their semantic compiler. Providers such as Go currently expose Tree-sitter
static evidence only.

The public capability description should therefore distinguish:

- portable syntax facts;
- local static proofs;
- semantic type/index support;
- interprocedural static proofs;
- runtime observations;
- rewrite support.

"Cross-language" is accurate for the schemas and basic facts, but should not
imply feature parity.

## Target: nullable provenance, not another null-dereference linter

The useful cross-language question is not merely whether a value's
representation can contain null. For languages without an enforced
`Option<T>`, treating every pointer or reference as a finding would create
intolerable noise.

NilKill should answer:

> Which producer introduced nullability, where can that value flow, which
> guards or recovery paths does it require, which unsafe sinks can it reach,
> and how much downstream complexity would disappear if the producer became
> total?

Example output should be able to say:

> `cache_lookup` is the nullable root for 14 callers. It causes nine distinct
> guard clusters, three nullable contracts, and two unchecked dereferences.
> Making the lookup result total, or separating absence from the value,
> removes those obligations.

That causal explanation is NilKill's differentiator from ordinary compiler,
lint, and CodeQL null-dereference diagnostics.

## Normalized null-state model

FactMine should use an edge-sensitive lattice with at least:

- `unreachable`;
- `definitely_null`;
- `definitely_non_null`;
- `maybe_null`;
- `unknown`.

`unknown` must remain distinct from `maybe_null`. Analysis incompleteness is
not evidence that null actually reaches a value.

Every conclusion must retain:

- source spans;
- stable value or place identity;
- semantic symbol identity where available;
- the contributing definitions and paths;
- confidence;
- completeness;
- explicit reasons for incompleteness.

### Source facts

Nullable sources include:

- null, nil, `None`, or `undefined` literals;
- nullable parameters and fields;
- calls whose return contracts allow null;
- allocators that may return null;
- collection lookup APIs with an absent result;
- FFI boundaries;
- deserialization and external input;
- weak references and nullable casts;
- unresolved calls, marked incomplete rather than guessed nullable.

### Transfer facts

The model must preserve flow through:

- direct assignment;
- branch and loop joins;
- parameter passing;
- explicit and implicit returns;
- field stores and reads;
- bounded field and index projections;
- aliases and dereferences;
- parameter-to-return and field-to-return summaries.

### Refinement facts

Branch-local refinements include:

- equality or inequality with null;
- language-appropriate truthiness;
- assertions such as `requireNonNull`;
- early return, throw, or raise guards;
- pattern and type tests;
- reviewed library predicates whose contracts prove nullness.

### Invalidation facts

A prior refinement must be invalidated by:

- direct reassignment;
- mutation through an alias;
- an unknown call that may modify the place or projection;
- mutation of a receiver-rooted field or collection element;
- shared or concurrent state changes where stability cannot be proven.

### Sink facts

Relevant sinks include:

- pointer dereference or member access;
- indexing;
- passing a value to a non-null parameter;
- returning it through a non-null contract;
- storing it in a non-null field;
- invoking a value that may itself be null.

### Interprocedural summaries

Each callable summary should be able to state:

- whether it may return null;
- the origins behind nullable returns;
- whether each parameter accepts null;
- whether each parameter is dereferenced, returned, or stored;
- parameter-to-return and receiver-to-return flow;
- field effects and invalidations;
- completeness and unresolved reasons.

## Language semantics must remain explicit

The normalized model is shared; source-language semantics are not guessed in
generic code.

- Ruby `hash[key]` can introduce `nil` through absence.
- Python `dict[key]` raises on absence, while `dict.get(key)` commonly returns
  `None`.
- Java `Map.get` may conflate absence and a stored null.
- A single-result Go map lookup produces the element type's zero value. It is a
  null source only when that element type is nil-capable. The separate `ok`
  result represents presence and should be modeled as presence state rather
  than generically as nullability.
- A C pointer can represent null, but the analysis should identify actual
  nullable producers rather than report every pointer.
- JavaScript property access commonly introduces `undefined`, which belongs to
  the nullable family without being literally `null`.
- Rust, Swift, Zig, Kotlin, and strict TypeScript already encode much of this in
  their type systems. NilKill's value there is primarily source pressure,
  redundant handling, and architectural prioritization rather than basic
  safety enforcement.

Library behavior should arrive through semantic providers or reviewed,
versioned contract manifests. NilKill report code must not accumulate lists of
language-specific API names.

## FactMine work

FactMine already supplies the correct local substrate:

- CFG nodes and edges;
- places;
- reads, writes, and mutations;
- unknown-call markers;
- reaching definitions and def-use;
- dominators and liveness;
- direct assignment sources;
- direct call-result spans.

Its current flow-type calculation is mainly a join over recognized literal
hints attached to reaching definitions. It does not yet provide the projection,
alias, edge-refinement, call-summary, and invalidation model required for sound
null provenance.

The next FactMine increment should add a versioned schema such as
`fact-mine.nullability.v1` with:

- `null_sources`;
- `null_sinks`;
- `null_flow_edges`;
- `null_refinements`;
- `null_invalidations`;
- `null_summaries`;
- `null_source_sink_paths`;
- per-record completeness and provenance.

The existing redundant-null-guard detector currently maintains its own local
branch walk. Its semantics should eventually consume the shared CFG and
null-state facts so FactMine has one authoritative branch refinement model.

FactMine should implement the cheap, portable local fixed point itself. It
should not grow a bespoke whole-program alias engine per language.

## CodeQL boundary

CodeQL is materially stronger for:

- semantic names and types;
- overload and interface dispatch;
- SSA and language-specific CFG/DFG representations;
- whole-program interprocedural dataflow;
- alias-aware source-to-sink paths;
- null guards and branch refinements;
- path explanations.

Official references:

- [Supported languages and frameworks](https://codeql.github.com/docs/codeql-overview/supported-languages-and-frameworks/)
- [Creating path queries](https://codeql.github.com/docs/writing-codeql-queries/creating-path-queries/)
- [C/C++ nullness dataflow](https://codeql.github.com/codeql-standard-libraries/cpp/semmle/code/cpp/controlflow/Dataflow.qll/module.Dataflow.html)
- [Java/Kotlin null guards](https://codeql.github.com/codeql-standard-libraries/java/semmle/code/java/dataflow/NullGuards.qll/module.NullGuards.html)
- [CodeQL library for Go](https://codeql.github.com/docs/codeql-language-guides/codeql-library-for-go/)
- [Compiled-language build modes](https://docs.github.com/en/code-security/concepts/code-scanning/codeql/codeql-for-compiled-languages)

CodeQL currently covers C/C++, C#, Go, Java/Kotlin,
JavaScript/TypeScript, Python, Ruby, Rust, and Swift. It does not replace
FactMine's portable support for languages such as Lua and Zig.

### Integration form

The intended flow is:

```text
Tree-sitter / native compiler / SCIP / CodeQL
                     |
                     v
             FactMine normalized facts
                     |
        +------------+-------------+
        |            |             |
        v            v             v
     NilKill      Espalier      Decomplex
```

A small, versioned CodeQL query pack should emit bounded nullable summaries and
source-to-sink paths. The results should be decoded into the FactMine schema and
merged using exact semantic symbols and source spans.

FactMine should not import CodeQL's entire internal graph. It should import only
the stable domain facts required by consumers. CodeQL execution should be an
optional, cacheable deep-analysis mode rather than a dependency of every fast
FactMine run.

This follows FactMine's existing SCIP and external-summary pattern. The
orchestrator invokes the provider, FactMine validates and normalizes its output,
and consumers remain independent of the provider's native representation.

Native compiler providers may emit the same schema when appropriate. FactMine
must resolve conflicts by evidence quality and completeness, not merely by
provider order.

## Pressure analysis changes

### Preserve type-dependency pressure

`FlowGraph#unlock_pressure` correctly computes an exact lower bound for what
one candidate unlocks and treats requirements as conjunctive. Keep this model.

A future extension may compute bounded minimal multi-root cut sets: pairs or
small sets of annotations that jointly unlock a region when no individual
candidate can. Z3 or a bounded hypergraph search is appropriate. Unbounded
combinatorial searches are not.

### Replace callsite-count nil pressure with causal impact

Current nil pressure largely combines attributed review actions, affected
slots, and observed calls. This is useful triage evidence, but it mixes runtime
hotness with architectural fanout.

The primary static pressure should be counterfactual:

> If this nullable source became total, which downstream nullable contracts,
> guard clusters, recovery branches, and unsafe sinks would disappear?

Pressure must count distinct semantic obligations rather than path occurrences.
Runtime frequency remains a separate dimension.

### Replace arbitrary fallibility weights with an evidence vector

The current fallibility score weights handlers, callers, direct sources, and
observed raises using unrelated scalar coefficients. Preserve the evidence but
report and sort by a vector:

- distinct causal sources;
- affected callers;
- exclusive handlers;
- shared handlers;
- unhandled paths;
- observed calls;
- observed failures and failure rate;
- confidence and completeness.

A configurable presentation sort may still produce a ranked list. The analyzer
should not imply that one handler has an intrinsically exact value relative to
one runtime failure.

### Preserve runtime shape pressure

Hash-record, tuple, union, collection, and hidden-enum observations are where
NilKill adds substantial value beyond CodeQL. Runtime evidence can reveal
emergent schemas in dynamic programs that static analysis cannot prove.

CodeQL may improve producer and consumer paths, but it does not replace runtime
shape evidence or observed frequency.

### Downgrade name pressure

Repeated untyped slot names and similar lexical correlations are triage
metadata, not proof. They must not gain high confidence solely from frequency.

## Implementation phases

### Phase 1: honest capability reporting

- Emit the detailed capability tiers listed above.
- Stop presenting syntax annotations as semantic checker integration.
- Add cross-language fixtures proving what each capability tier does and does
  not guarantee.

### Phase 2: portable local null-state

- Add the normalized nullability schema.
- Implement edge refinements and joins over existing CFG places.
- Model reassignment and conservative unknown-call invalidation.
- Emit complete local source-to-sink proofs.
- Make redundant-null-guard analysis consume the shared state.

### Phase 3: callable summaries

- Add nullable-return and parameter behavior summaries.
- Use exact SCIP/compiler symbols for joins.
- Propagate summaries only across closed, resolved targets.
- Preserve explicit unknown reasons for open dispatch and external code.

### Phase 4: optional CodeQL provider

- Build minimal language query adapters that emit the shared schema.
- Decode results outside NilKill.
- Import them through FactMine's semantic-provider boundary.
- Cache databases and results.
- Compare portable and CodeQL paths in oracle tests.
- Prefer semantic evidence without hiding disagreement or incompleteness.

### Phase 5: causal pressure

- Aggregate distinct source-to-obligation paths.
- Compute counterfactual single-root impact.
- Separate semantic fanout, unsafe sinks, removable guards, runtime hotness,
  and confidence.
- Add bounded multi-root cut sets only after single-root results are trusted.

## Acceptance criteria

The work is complete only when:

1. A language provider can add nullable semantics without modifying NilKill's
   generic report or pressure code.
2. Every finding explains the nullable origin, transfer path, refinement state,
   sink or obligation, and completeness.
3. `unknown` never silently becomes `maybe_null` or `non_null`.
4. Reassignment and alias-capable mutation invalidate refinements
   conservatively.
5. Local FactMine analysis works without CodeQL.
6. CodeQL enrichment is optional, cacheable, and produces the same normalized
   schema as other semantic providers.
7. Lua, Zig, and other non-CodeQL languages retain portable analysis.
8. Runtime shape and production-frequency evidence remain usable independently
   of CodeQL.
9. Pressure reports separate causal fanout from observed hotness.
10. Cross-language oracle fixtures cover positive, negative, incomplete,
    mutation-invalidated, and interprocedural paths.

## Explicit non-goals

- Do not move NilKill reporting, runtime analysis, or rewriting into CodeQL.
- Do not make CodeQL mandatory for fast or portable analysis.
- Do not implement a separate whole-program points-to engine for every
  language in FactMine.
- Do not treat all pointers or reference types as proven nullable sources.
- Do not infer language library behavior from method names in generic code.
- Do not conflate Go presence state, exceptions, error unions, and nullability.
- Do not rank pressure using graph centrality that lacks a causal interpretation.
- Do not award proof-level confidence to runtime samples or lexical name
  correlations.

## Final recommendation

NilKill's durable cross-language niche is not null-dereference detection. It is
identifying the nullable producer whose correction removes the most downstream
complexity, while combining static causality with runtime reality.

FactMine should become the authoritative normalized provenance layer. CodeQL
should be an optional deep semantic accelerator behind that layer. NilKill
should remain the analyzer that converts those facts into pressure,
prioritization, and actionable explanations.
