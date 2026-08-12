# Aliasing Hazard Analysis

## Status and Decision

This document assesses the proposed **Project Janus** design against the
current FactMine, Decomplex, SlopCop, Lineage, and Ruby-to-CLEAR
implementations.

**Decision:** pursue the useful hazard families, but do not create a separate
Janus analysis engine and do not adopt the proposed phases or estimates as
written.

The correct product boundary is:

```text
language syntax adapter
        |
        v
FactMine normalized effects, CFG, DFG, alias/escape facts,
and eventually lifecycle/concurrency facts
        |
        +------------------------+-----------------------+
        |                        |                       |
        v                        v                       v
Decomplex findings       Ruby-to-CLEAR          Espalier architecture
and local metrics        ownership planning     pressure/escape paths
        |
        v
SlopCop evidence policy  <---->  Lineage history and evidence anchoring
```

FactMine owns semantic analysis and evidence-bearing public facts. Decomplex
owns static findings, confidence tiers, scoring, and reporting over those
facts. SlopCop owns the policy question, “did this changed hazard receive the
required dynamic/systems evidence?” Lineage owns persistence, rename-stable
history, and correlation. Ruby-to-CLEAR consumes conservative facts for
compiler decisions; it must not consume Decomplex scores as ownership truth.

This is an expansion of the existing FactMine alias work, not a replacement
for it. The current allocation, may/must-alias, and escape facts are the first
layer needed by every high-value detector in the proposal.

## Executive Assessment of the Proposal

The proposal is directionally right about three things:

1. alias hazards need both control-flow ordering and identity/dataflow facts;
2. language-specific semantics must decorate a shared graph model; and
3. local, evidence-bearing hazards should precede whole-program claims.

It is materially wrong or incomplete in five ways:

1. **The market claims are overstated.** Iterator-mutation checks, static race
   analysis, and UAF/double-free analysis already exist in mature tools.
2. **A standard CFG plus DFG is not sufficient.** Each proposed module needs
   additional semantic contracts; race analysis additionally needs a
   concurrency/event graph and happens-before reasoning.
3. **The proposed LoC estimates count detector predicates, not the fact
   substrate, language adapters, completeness tracking, tests, or evidence
   projection.** They are low by roughly 3-10x for a credible cross-language
   implementation.
4. **“Accessor” versus “Mutator” is too weak a function model.** The analysis
   needs receiver/argument-specific read, write, retain, escape, invalidate,
   free, spawn, join, acquire, and release effects.
5. **The proposed phase order does not match this repository's leverage.** The
   first return should be completing the Ruby alias/escape vertical slice for
   Ruby-to-CLEAR and Decomplex, not starting five-language cursor analysis or
   a static race engine.

“Project Janus” can remain a product/workstream name if useful. It should not
be a new parser, graph store, analysis runtime, or source of facts.

## What Exists Today

FactMine currently supports fifteen language front ends: Ruby, Python,
JavaScript, TypeScript, Java, Kotlin, Swift, Go, Rust, Zig, Lua, C, C++, C#,
and PHP. Support for parsing and CFG production does not mean every language
already emits complete alias semantics.

### Implemented shared graph foundation

- a language-neutral per-function CFG with explicit control-flow nodes and
  edges;
- shared places and normalized node effects;
- reachability and immediate dominance;
- reaching definitions, def-use chains, and liveness;
- flow-type facts;
- allocation-site identities;
- may/must alias propagation through CFG joins;
- escape facts with sink and evidence node identities; and
- completeness/unknown state on effects and alias facts.

The generic alias fixed point is in
`gems/fact-mine/src/syntax/cfg/aliasing.rs`. It contains no Ruby vocabulary.
The first concrete alias normalizer is in
`gems/fact-mine/src/syntax/ruby_alias.rs`; it recognizes Ruby allocations,
identity-preserving assignments, transparent Sorbet wrappers, returns,
non-local stores, aggregate stores, and conservative unknown-call escapes.

### Recorded implementation scale

These are repository measurements, not estimates:

| Landed increment | Production/core change | Whole commit change |
| --- | ---: | ---: |
| Recovered language-neutral CFG | 4,902 lines in `syntax/cfg` | 5,356 insertions |
| Cross-language CFG proof | mostly fixtures/oracles | 9,696 insertions |
| Shared DFG/dataflow increment | 826 lines in shared CFG modules | 1,247 insertions |
| Allocation/alias/escape increment | 642 lines in shared CFG modules plus 336 Ruby adapter lines | 1,182 insertions |
| Current `syntax/cfg/*.rs` plus Ruby alias adapter | **6,705 lines** | n/a |

The initial Janus estimates of 150-900 LoC are therefore plausible only for a
final detector predicate after its inputs already exist. They are not credible
end-to-end module estimates.

### Important missing substrate

The current alias vertical slice deliberately does not yet provide:

- field-, index-, and dereference-sensitive place projections;
- iterator/cursor derivation or invalidation facts;
- complete receiver/argument mutation effects;
- exact interprocedural effect summaries;
- closure capture identity and escape timing;
- retain/borrow/move/free/reallocation lifecycle events;
- component/package boundary identities;
- concurrency task identities, spawn/join relations, locksets, channels, or
  happens-before edges; or
- a labeled precision/recall corpus for detector admission.

These gaps are additions to the current work. They do not make the current CFG,
DFG, or alias fixed point redundant.

## Competitive and Technical Claim Review

### Cursor and iterator invalidation is not one cross-language rule

The proposal groups Go, Java, TypeScript, Python, and C++ under one
“invalidation” rule. That is too broad:

- Java has fail-fast iterators, but `ConcurrentModificationException` is only
  best-effort according to the JDK. Error Prone already ships a
  `ModifyCollectionInEnhancedForLoop` checker.
- C++ invalidation depends on the container, operation, capacity change, and
  whether the held handle is an iterator, pointer, or reference. Even Clang's
  loop-conversion safety logic reasons about container mutation and documents
  alias-based blind spots.
- Go range behavior is construct-specific. The Go specification explicitly
  defines map deletion/insertion behavior during iteration; it is not a
  universal invalid-iterator panic.
- Python and JavaScript commonly have defined execution with surprising
  logical results rather than memory invalidation. Those should be reported as
  mutation-during-traversal semantics, not mislabeled as UAF-like cursor
  invalidation.

The opportunity is therefore not an “open market.” It is a common evidence
model with language/container-specific invalidation contracts and alias-aware
matching that catches indirect mutation missed by syntax-only checks.

Primary references:

- [JDK `ConcurrentModificationException`](https://docs.oracle.com/javase/8/docs/api/java/util/ConcurrentModificationException.html)
- [Error Prone collection-mutation checker](https://errorprone.info/bugpattern/ModifyCollectionInEnhancedForLoop)
- [Clang loop-conversion mutation and alias analysis](https://clang.llvm.org/extra/clang-tidy/checks/modernize/loop-convert.html)
- [Go range semantics](https://go.dev/ref/spec#For_statements)

### Static race analysis is not unique to Rust

Safe Rust prevents data races through its ownership/type system, but Rust does
not prevent all race conditions, and `unsafe` or incorrectly modeled external
code remains relevant. More importantly, static race detectors already exist
outside Rust:

- Clang Thread Safety Analysis is compile-time and models capability/lockset
  requirements.
- Infer RacerD statically analyzes Java, C/C++/Objective-C, and C#/.NET for
  race candidates. Its documented limitations—aliases, escaping locals, lock
  identity, and deep ownership—are especially relevant to FactMine's possible
  differentiation.
- CodeQL ships Java and C# concurrency queries, including thread-safety and
  time-of-check/time-of-use findings.
- Go includes a strong runtime race detector, although it observes only
  executed paths.

The valuable claim is narrower: FactMine's explicit alias and escape evidence
could address some false negatives documented by existing fast static race
analyses. It cannot responsibly claim general static race detection from a DFG
fork alone.

Primary references:

- [Rust data-race guarantees and race-condition limits](https://doc.rust-lang.org/nomicon/races.html)
- [Clang Thread Safety Analysis](https://clang.llvm.org/docs/ThreadSafetyAnalysis.html)
- [Infer RacerD and its alias/escape limitations](https://fbinfer.com/docs/next/checker-racerd/)
- [CodeQL Java thread-safety query](https://codeql.github.com/codeql-query-help/java/java-not-threadsafe/)
- [Go race detector](https://go.dev/doc/articles/race_detector)

### UAF and double-free are commodity classes, but not trivial analyses

The proposal is right to deprioritize these as differentiators. CodeQL and
Clang-based analyzers already cover these families. It is wrong to describe a
same-identifier downstream scan as deterministic with near-zero false
positives. Useful analysis must account for aliases, reallocations, path
feasibility, ownership transfer, wrapper allocators/deallocators, nulling, and
destructor behavior. Those are exactly the expensive parts.

Primary references:

- [CodeQL C/C++ query inventory](https://codeql.github.com/codeql-query-help/cpp/)
- [CodeQL double-free query](https://codeql.github.com/codeql-query-help/cpp/cpp-double-free/)

### Optimization records are available, but ingestion still needs tests

LLVM already emits structured optimization records and supplies parsing and
reporting tools. A repository feature that normalizes compiler remarks and
maps them to Lineage units could be useful UX, but it is compiler telemetry,
not a FactMine alias calculation. “Zero unit tests” is not an acceptable
implementation strategy: format compatibility, build invocation, path
remapping, inlining locations, deduplication, and stale-source admission all
need fixtures and integration tests.

Primary reference:

- [LLVM optimization remarks](https://llvm.org/docs/Remarks.html)

### “Action at a distance” is valuable but underspecified

A call crossing a package boundary does not prove that the callee retains the
reference. A subsequent local mutation does not prove a bug. A credible
finding needs an exact retain/escape summary, a component boundary, mutable
identity continuity, and an observable read or invariant dependency at the
remote destination. Unknown external code can create architecture pressure,
but it cannot create a Tier 1 finding.

This family may be novel in how the repository presents evidence and
aggregates architectural pressure. The proposal provides no evidence for the
claim that it is categorically unsolved in all imperative/OO languages.

## Correct Ownership of the Detectors

### FactMine owns producers, not verdicts

FactMine should produce reusable facts:

- places and identity/projection relations;
- allocation, alias, escape, mutation, invalidation, retain, and lifetime
  events;
- exact call targets and receiver/argument effect summaries where known;
- cursor derivation and container invalidation contracts;
- task, synchronization, and lifecycle events;
- feasible ordering/evidence paths; and
- explicit completeness and unknown reasons.

FactMine must not emit “this is a race,” “this is an encapsulation breach,” or
a Decomplex score. It also must not use raw Tree-sitter queries as a parallel
semantic extractor. Concrete adapters translate grammar into normalized
concepts; shared passes derive facts.

### Decomplex should own most source-static detectors

Decomplex is the correct owner for:

- local alias-mutation collisions;
- mutable internal-state escape/encapsulation breaches;
- cursor invalidation or traversal-mutation findings;
- local exact UAF/double-free findings when FactMine supplies lifecycle facts;
- heuristic shared-mutation/race candidates when FactMine eventually supplies
  concurrency facts; and
- aggregate alias-tangle/locality metrics.

Its detectors already consume grouped FactMine `Document` values and run as
independent report tasks. Adding detectors there preserves the established
fact-consumer boundary.

The existing Decomplex `semantic_alias` detector is unrelated: it detects
equivalent predicate expressions, not object or pointer identity. New detector
names must make that distinction explicit.

The older
`gems/decomplex/docs/agents/aliasing-complexity-metrics.md` plan is stale where
it asks Decomplex to implement a two-pass semantic analyzer and drive compiler
ownership synthesis. Producer analysis belongs in FactMine; Ruby-to-CLEAR owns
compiler planning. That document should eventually point here.

## Build Versus Import Decision

**Use mature external analyzers first for defect findings. Do not attempt to
match their quality across all fifteen FactMine languages. Continue only the
FactMine semantic substrate that has a distinct internal consumer or enables a
demonstrably missing finding.**

FactMine has enough to prove local Ruby allocation/alias/escape flow. It does
not have enough to match established analyzers across all languages:

- only Ruby currently has a concrete alias normalizer;
- places are not yet projection-sensitive;
- exact call/effect summaries and library models are absent;
- no language has cursor invalidation contracts or lifecycle summaries; and
- no language has the task/happens-before model needed for static race
  analysis.

Cross-language CFG availability must not be mistaken for cross-language
semantic-analysis parity. Reaching definitions and liveness are reusable
infrastructure, but the quality of these hazards is determined mainly by type,
library, ownership, lifetime, and concurrency models.

### Recommended hybrid

1. **Import CodeQL SARIF as the broad semantic baseline.** Current CodeQL
   support covers twelve of FactMine's fifteen languages: C, C++, C#, Go, Java,
   Kotlin, JavaScript, TypeScript, Python, Ruby, Rust, and Swift. Query coverage
   differs by language, so “supported” does not imply that every proposed
   hazard has a stock query. The CLI can emit pinned SARIF 2.1.0 directly.
2. **Import stronger ecosystem-specific results where appropriate.** Examples
   include Clang/Infer and sanitizer evidence for C/C++, Error Prone/Infer for
   Java, Go's race detector plus gosec, Roslyn analyzers for C#, Ruff for Python
   lint, Brakeman for Ruby/Rails, and Psalm for PHP. Many are complements to
   CodeQL rather than replacements.
3. **Keep SlopCop/Lineage's existing systems-evidence path.** Static SARIF does
   not replace TSan, ASan, LSan, UBSan, Go race, Loom, or Miri evidence.
4. **Use FactMine for the net-new/internal surface.** Ruby-to-CLEAR needs
   conservative alias/ownership facts, not external warnings. Decomplex can
   add a detector only when a labeled comparison shows useful findings not
   already supplied by imported tools.
5. **Treat Lua and Zig as explicit gaps.** PHP has mature analysis through
   Psalm even though CodeQL does not cover it. Lua and Zig lack a comparable
   off-the-shelf semantic SARIF baseline for these hazard families. Do not hide
   that gap behind syntax-only parity claims.

GitHub documents CodeQL's current compiled-language set, including Rust, and
its standard packs cover the interpreted languages in the matrix. The CodeQL
CLI supports `sarifv2.1.0` output, which Lineage already accepts without a new
provider-specific parser:

- [CodeQL compiled language support](https://docs.github.com/en/code-security/concepts/code-scanning/codeql/codeql-for-compiled-languages)
- [CodeQL query packs](https://docs.github.com/en/code-security/concepts/code-scanning/codeql/query-packs)
- [CodeQL SARIF output](https://docs.github.com/en/code-security/reference/code-scanning/codeql/codeql-cli/sarif-output)

### Why external SARIF does not replace FactMine aliases

SARIF normally contains verdicts, locations, paths, rule metadata, and
fingerprints. It does not expose a stable, complete points-to lattice suitable
for deciding `Move`, `Borrow`, or `Copy` inside Ruby-to-CLEAR. It also cannot
be assumed to contain negative proof: absence of a finding is not proof of
uniqueness or safe ownership.

Accordingly:

- external findings should inform humans, Decomplex convergence, SlopCop
  policy, and Lineage history;
- FactMine facts should inform compiler admission and ownership planning; and
- imported findings may become a differential oracle for FactMine detector
  development, but never the compiler's semantic IR.

### Cost comparison

Broad external-tool enablement is approximately 2-6 focused weeks for a first
useful pass: document CodeQL creation/analysis, add a few JSON-to-SARIF adapters
for high-value non-SARIF tools, validate path normalization, and establish
per-tool source buckets and CI fixtures. Repository-specific build setup is
additional.

Attempting similar-quality native analysis for all proposed hazards across all
fifteen languages is at least a multi-quarter program. The concurrency slice
alone was estimated above at 12-24 weeks for two languages. Adding library
models, build semantics, labeled corpora, and twelve more concrete adapters is
closer to 12-24 engineer-months than to the proposal's combined LoC budget,
with no assurance of matching CodeQL, Infer, Clang, or language compilers.

The companion ingestion guide is
`gems/lineage/docs/agents/ecosystem-sarif/README.md`.

### Espalier should own cross-component aggregation

Decomplex can emit a local or exact boundary-escape finding. Espalier is the
better owner for repository-architecture questions such as alias fan-out
across packages, component entanglement, and long escape paths. It should
aggregate FactMine/Decomplex evidence, never reconstruct aliases from source.

### Existing systems hazard detection must not be duplicated

SlopCop already has C, C++, C#, Go, Rust, and Zig providers. They tag changed
sites involving threads, goroutines, atomics, locks, channels, unsafe/raw
memory, allocation, and deallocation, then require evidence such as Go race,
TSan, ASan, LSan, UBSan, Loom, or Miri coverage. Lineage has corresponding
Tree-sitter hazard queries and persists/presents the evidence history.

Those checks answer:

> A dangerous primitive changed; was it exercised by the appropriate
> specialized verifier?

They do **not** answer:

> Do these two aliases reach conflicting unsynchronized accesses, or does this
> use follow a free on a feasible path?

FactMine plus Decomplex may answer the second question. SlopCop should then
join a semantic finding or semantic hazard site with runtime evidence rather
than acquiring another static race/UAF engine. Lineage should retain both the
semantic finding and its verification history.

The existing `systems-test-coverage-detection.md` architecture text says
Decomplex identifies dangerous primitives, while current implementation also
scans them directly in SlopCop and Lineage. That is harmless as a transitional
syntax tagger, but semantic hazard identity should eventually come from
FactMine facts so the three products do not drift.

## Required Fact Model Beyond Current CFG/DFG

### Rich places and identities

Add projections without putting language names in the shared engine:

```text
Place
  root: local | parameter | self | field | global | allocation | unknown
  projection*: field(name) | index(constant) | index(unknown) | dereference

Identity
  allocation site or declared external identity
  may/must points-to relation
  completeness and unknown reason
```

### Effect summaries, not accessor/mutator labels

```text
FunctionEffectSummary
  reads(receiver/argument/projection)
  writes(receiver/argument/projection)
  mutates(receiver/argument/projection)
  retains_or_escapes(receiver/argument, sink)
  returns_alias_of(receiver/argument) | returns_fresh
  invalidates(cursor_family, receiver/argument, condition)
  allocates | reallocates | frees
  spawns | joins | acquires | releases | sends | receives
  complete: bool
  unknown_reasons[]
```

Summaries should be derived for exact project calls and supplied as
language/library descriptors for known external APIs. Unknown calls widen
compiler may-alias state but cannot independently create a Tier 1 detector
finding.

### Cursor and invalidation facts

```text
CursorFact
  cursor_place
  container_identity
  handle_kind: iterator | index | element_reference | snapshot_value
  derivation_node
  validity_contract

InvalidationFact
  container_identity
  operation_node
  invalidated_handle_kinds
  condition: always | capacity_change | erased_element | implementation_defined
```

The language adapter supplies syntax and known library descriptors. The shared
engine joins identity, liveness, and ordering.

### Escape and component facts

Cross-boundary analysis needs exact function summaries plus a stable component
model:

```text
BoundaryEscape
  identity
  source_component
  destination_component
  sink: return | field | global | aggregate | callback | unknown_external
  retained: yes | no | unknown
  mutable_access: yes | no | unknown
  evidence_path
```

An unknown external call is useful pressure, not proof of retention.

### Lifetime facts

```text
LifetimeEvent
  identity
  event: allocate | reallocate | transfer | free | destroy | null
  node
  path/completeness evidence
```

Direct name reuse is insufficient; lifetime events attach to identities.

### Concurrency facts require more than a CFG

A goroutine, thread, task, or async callback is not an ordinary branch whose
two arms later join. Race analysis needs at least:

```text
TaskEvent
  task identity
  spawn/start/join/await/end
  captured/shared identities

SynchronizationEvent
  lock/capability/channel/atomic identity
  acquire/release/send/receive/fence
  memory-order metadata where applicable

ConcurrencyRelation
  may_happen_in_parallel
  happens_before
  lockset/capability environment at access
  completeness and unknown reason
```

Without this layer, “two DFG forks” will report sequential callbacks, joined
tasks, message-passing code, immutable sharing, and synchronized access as
races.

## Revised Detector Specifications

### A. Alias-mutation collision — first priority

This is already aligned with Ruby-to-CLEAR.

Tier 1 requires a must-alias relation, resolved mutation effect, overlapping
liveness, feasible CFG ordering, and a later counterpart read/use. Tier 2 may
use may-alias or incomplete call effects but must name the uncertainty.

This detector proves the full producer/consumer boundary with Ruby first while
keeping the shared engine language neutral.

### B. Mutable internal-state escape — first priority

Tier 1 requires a `self`/`this`-rooted mutable projection, exact escape sink,
and no explicit copy/read-only wrapper. Unknown calls or unresolved getters
remain Tier 2. This is the precise, local form of the proposed cross-boundary
leak and is immediately useful to Decomplex and Ruby-to-CLEAR.

### C. Cursor invalidation/traversal mutation — second priority

Split findings by semantic family:

1. invalid iterator/reference used after a proven invalidating operation;
2. fail-fast collection modification during active iteration; and
3. logically unstable traversal where mutation changes which elements are
   visited.

Each language/container descriptor declares which family applies. A mutation
through an alias should resolve to the same container identity. Tier 1 requires
a known cursor/container relation and known invalidation contract.

### D. Cross-component mutable escape — third priority

Begin with explicit, exact project calls and retained field/global/aggregate
stores. Decomplex reports exact local escape findings; Espalier aggregates
component fan-out and path length. Do not claim a bug solely because mutable
state crossed a boundary.

### E. Local UAF/double-free — optional systems increment

Support only explicit allocators/deallocators and must-alias identities first.
Require path-sensitive evidence and recognize reinitialization/nulling. This
can provide a consistent repository UX, but novelty is low and SlopCop already
requires sanitizer evidence at relevant sites.

### F. Shared-mutation/race candidates — later research increment

Start only after task and synchronization facts exist. A candidate needs two
may-happen-in-parallel accesses to the same identity, at least one write, and
no proven happens-before or common protecting capability. Initial findings are
Tier 2 even when evidence is strong. Dynamic evidence remains required.

### G. Optimization barrier mapping — separate telemetry track

Do not place compiler invocation or optimization-record parsing in FactMine's
source fact pipeline. Normalize records through an external evidence provider,
anchor them in Lineage, and optionally let Decomplex aggregate performance
pressure. This track should not block alias work.

## Effort Assessment from the Current Repository

The following estimates start from the implementation currently present. They
include production facts, adapters, public projection, detector work, and
tests/fixtures. They are not delivery promises. Language semantics and labeled
negative fixtures are a larger uncertainty than the fixed-point algorithms.

| Increment | Remaining production LoC | Tests/fixtures LoC | Language-specific work | Focused schedule |
| --- | ---: | ---: | ---: | ---: |
| Complete Ruby alias vertical slice: projections, mutation effects, captures, exact summaries, two Decomplex detectors | 1,400-2,600 | 1,200-2,200 | 350-750 Ruby | 3-6 weeks |
| Cursor/traversal module across Java, C++, Go, Python, TS | 2,400-4,800 | 2,500-5,000 | 250-700 per language plus library contracts | 6-12 weeks |
| Exact cross-component escape and aggregation | 2,200-4,200 | 2,000-4,000 | 200-600 per language | 6-12 weeks |
| Alias-aware local UAF/double-free for C/C++/Zig | 1,500-3,000 | 1,500-3,000 | 300-800 per language/toolchain | 5-10 weeks |
| Static shared-mutation/race candidates for two languages | 4,000-7,500 | 4,000-8,000 | 500-1,200 per language/concurrency model | 12-24 weeks |
| LLVM/GCC optimization-record ingestion and source anchoring | 900-1,800 | 800-1,600 | 200-500 per compiler format/build system | 3-6 weeks |

These ranges overlap where modules reuse projections and call summaries. They
should not all be summed mechanically. Conversely, adding more languages is
not just a fixed number of syntax lines: library contracts and negative
fixtures dominate iterator and concurrency support.

### Why the Janus numbers are low

| Proposed module | Proposal | Plausible detector body after all facts exist | End-to-end assessment |
| --- | ---: | ---: | ---: |
| Iterator invalidation | 350-500 | 250-500 | 2,400-4,800 production for five semantic models |
| Cross-boundary leak | 600-900 | 300-700 | 2,200-4,200 production plus component/call summaries |
| Race detection | 400-600 | 400-900 | 4,000-7,500 production for a two-language first slice |
| Optimization mapping | 200-300 | 200-400 for one happy-path parser | 900-1,800 production with build/source integration |
| UAF/double-free | 150-250 | 250-500 for direct local cases | 1,500-3,000 production for alias-aware C/C++/Zig |

The proposal estimates are not useless; they approximate the small Decomplex
consumer once FactMine already emits perfect inputs. They should not be used
for staffing, sequencing, or deciding that a module is “simple.”

## Recommended Delivery Plan

### Phase 0: Preserve the architecture boundary

1. Treat the current shared may/must-alias fixed point as the base.
2. Keep all concrete Ruby rules in the Ruby alias/effect adapter.
3. Add architecture tests preventing concrete-language vocabulary in shared
   graph modules and preventing Decomplex source parsing.
4. Mark the older Decomplex aliasing design as superseded where it assigns
   producer or compiler responsibilities to Decomplex.

Exit gate: the existing cross-language CFG/DFG suite remains green and no
consumer re-mines source.

### Phase 1: Finish the Ruby proof needed by Ruby-to-CLEAR

1. Add field, constant-index, unknown-index, and dereference projections.
2. Add receiver/argument-specific mutation and escape effects.
3. Add closure capture/escape facts and exact local call summaries.
4. Implement Decomplex alias-mutation collision and mutable-state escape
   detectors over public facts.
5. Consume the same facts in Ruby-to-CLEAR typed IR for ownership eligibility.

Exit gate: labeled Tier 1 fixtures meet the precision gate, at least one real
finding is useful, and Ruby-to-CLEAR improves raw G3 without G2/G3 regression.

### Phase 2: Prove a real cursor semantic family

First import and measure Error Prone/CodeQL/Clang findings for the target
fixtures and real repositories. Implement Java fail-fast iteration and C++
container invalidation in FactMine/Decomplex only if alias-aware indirect
mutation or cross-product evidence produces a material gap. These languages
exercise distinct and well-defined contracts. Add Go/Python/TypeScript only
under their actual traversal semantics; do not force them into the C++ model.

Exit gate: each claimed container/operation pair has positive and adversarial
negative fixtures, including mutation through an alias.

### Phase 3: Add exact interprocedural escape summaries

1. derive summaries for exact project calls;
2. add descriptors for a bounded set of standard-library/framework calls;
3. publish component boundary escapes; and
4. split Decomplex exact findings from Espalier pressure metrics.

Exit gate: unresolved external calls never become Tier 1 and evidence paths
survive public serialization.

### Phase 4: Choose systems work from measured yield

Compare semantic alias findings with existing SlopCop/Lineage hazard sites. If
direct lifetime findings add useful signal, implement the scoped UAF slice. If
alias blind spots dominate concurrency review, write a separate concurrency
fact design before implementing race findings. Do not infer concurrency from
ordinary CFG branch edges.

### Independent telemetry phase

Prototype optimization-record ingestion separately. Its success criterion is
stable mapping and useful aggregation, not alias-analysis coverage.

## Verification and Admission Gates

### Producer correctness

- fixed-point output is deterministic and independent of traversal order;
- every fact names source span, CFG node, identity/place, and proof class;
- unknown calls/projections widen may state and destroy must certainty;
- unsupported syntax records an unknown reason rather than silently omitting
  effects;
- joins, loops, exceptions/finally, callbacks, and early exits have fixtures;
- exact call summaries are invalidated when target resolution is incomplete;
  and
- language rules reside only in language-owned adapters/descriptors.

### Detector quality

- Tier 1 requires must-alias or equally direct identity proof, complete effects,
  and a feasible evidence path;
- may-alias and unknown-boundary findings are Tier 2 at most;
- each claimed language/container/API has labeled positive and adversarial
  negative fixtures;
- Tier 1 requires at least 95% precision on the declared in-scope corpus and
  100% precision for auto-fixable/compiler-actionable fixtures;
- recall is measured separately and limited scope is stated explicitly; and
- every report explains the alias origin, hazard event, downstream use/escape,
  and uncertainty.

### Cross-product non-duplication

- FactMine produces facts, not policy verdicts;
- Decomplex does not parse source to recover missing semantic facts;
- SlopCop does not reimplement semantic alias/race/UAF analysis;
- Lineage stores and correlates results without becoming an analyzer;
- Espalier aggregates architectural paths without inventing identity edges;
  and
- Ruby-to-CLEAR consumes conservative facts directly and makes ownership
  decisions before CLEAR emission.

## Final Recommendation

Course-correct the Janus proposal before implementation:

1. rename it from a separate engine to an alias-hazard workstream over
   FactMine facts;
2. make external SARIF the default defect baseline and use it as a differential
   oracle for any proposed first-party detector;
3. keep Decomplex as the detector/report owner, with Espalier handling
   cross-component aggregation;
4. finish the Ruby projection/mutation/capture/call-summary slice first because
   it serves both Ruby-to-CLEAR and the first credible detectors;
5. treat iterator behavior as language/container contracts rather than a
   universal rule;
6. defer static race analysis until a concurrency/event and happens-before
   design exists;
7. keep UAF and optimization telemetry as lower-novelty, evidence-integrated
   tracks; and
8. replace “near-zero false positives,” “unsolved,” and detector-only LoC
   claims with measured precision and end-to-end estimates.

The core idea is worth pursuing. Its competitive advantage would come from
FactMine's reusable evidence, alias-aware cross-product integration, and
honest confidence boundaries—not from claiming that established hazard
classes have no existing tools.
