# Minimal dependency graph feasibility for complete Big-O bounds

## Decision

Do **not** build a new dependency-graph subsystem in Fact-Mine as a route to
80% complete Big-O bounds. Fact-Mine already emits the essential graph facts,
and Espalier already projects cross-file targets and performs SCC/fixed-point
summary propagation. The missing information is predominantly native/project
call identity, receiver/type precision, callbacks, and dynamic dispatch—not a
missing graph traversal.

A compact Rust graph implementation may still be worthwhile later to replace
Espalier's object-heavy aggregation cost. It should be justified as a latency
optimization after a measured prototype, not as a completeness strategy.

## Compiler/ruby experiment

`compiler/ruby` is a useful closed-codebase stress case: it has very little
application FFI, so parsing the available source should expose nearly all
project declarations. It is not a literal universal upper bound: Ruby's
dynamic dispatch still leaves more calls ambiguous than a fully type-checked
closed Go/Java program, while a real application can add FFI, generated code,
reflection, plugins, and package-resolution ambiguity.

Fact-Mine's `espalier` profile over 170 compiler files produced:

| Fact | Count |
| --- | ---: |
| Methods | 5,932 |
| Calls | 88,355 |
| Existing direct targets | 7,289 |
| Known native call costs | 10,585 |
| Calls with an unresolved reason | 81,066 |
| Internal call records | 7,289 |
| External/delegated call records | 56,132 |
| Complexity call contexts | 60,767 |
| Contexts with unknown receiver type | 21,342 |
| Contexts with unknown call target | 18,549 |
| Typed but unmodelled operations | 13,989 |
| Callback dispatch | 389 |

I simulated the maximum *additional* unique target edges a global
name/type-based resolver could add using the currently emitted declarations,
static receiver types, and flow-local receiver types. Of the 81,066 unresolved
calls, only 2,393 (2.95%) were uniquely resolvable:

| New resolution rule | Calls |
| --- | ---: |
| Same-owner implicit method | 5 |
| Flow-local receiver type | 984 |
| Declared static receiver type | 1,404 |

There are 6,308 callers with unresolved calls; only 95 have *every* unresolved
call in that 2,393-call subset. Even under the impossible assumption that all
new callees have complete summaries, that can make at most 95 methods complete
(under 1.7 percentage points of the 5,893 observed functions). Therefore a
minimal graph cannot plausibly turn a roughly 20–30% known corpus into 80%.

## Existing architecture and timing

Fact-Mine already serializes `calls`, `call_graph_edges`, `flow_local_types`,
and `complexity_facts`. Espalier's `StaticEvidence.project_modules` resolves
same-owner, static-type, and local-flow targets; the aggregator then runs the
recursive SCC and summary fixed point. Re-implementing this in Fact-Mine today
would create two overlapping graph systems.

On the same compiler input:

| Stage | Wall time | Notes |
| --- | ---: | --- |
| Fact-Mine `espalier` profile | 4.41 s | Parse plus native fact extraction |
| Espalier evidence build, facts reused | 6.54 s | Ruby evidence normalization |
| Espalier target projection, facts reused | 0.70 s | Existing cross-file resolver |
| Espalier aggregation, facts reused | 75.94 s | Object-heavy fixed point |
| Espalier build + project + aggregate | 84.74 s | Excludes Fact-Mine subprocess |
| Full Espalier SARIF CLI | 103.84 s | Includes all report work |

This demonstrates why copying Espalier's current fixed point into Fact-Mine is
not acceptable. A compact interned-ID graph/SCC prototype might keep the graph
step below roughly 10–20% of the 4.41-second mining pass, but that is an
engineering estimate, not measured evidence. It should have a hard stop if it
cannot do so.

## Tree-sitter and the minimum graph

Tree-sitter makes syntax parsing efficient and supports incremental reparsing
when a long-lived client preserves and edits a prior tree. Fact-Mine currently
parses each supplied file afresh; it does not yet persist an incremental parse
cache. More importantly, Tree-sitter intentionally does **not** provide module
resolution, package/build rules, imports, overload selection, virtual dispatch,
macro expansion, FFI binding, or reflection semantics.

Once files have been parsed, indexing the already-emitted declarations and
calls is cheap `O(V + E)` work and does not require parsing dependencies again.
The hard part is soundly deciding which dependencies and targets are actually
selected. A real cross-language import/package resolver is substantially more
work than a Tree-sitter traversal.

## Cost and recommendation

| Option | Approximate implementation | Expected parsing/analysis cost | Expected completeness impact |
| --- | --- | --- | --- |
| Compact graph over current facts | 400–800 shared LoC plus 300–700 oracle tests | No extra parse; likely sub-second to low-second graph work if implemented with interned IDs | Under ~1.7pp on compiler/ruby; not an 80% path |
| Correct imports/packages/overloads per language | 3k–8k shared LoC plus roughly 300–1,500 LoC for each language/build ecosystem | Extra source discovery and dependency parsing; highly repository/language dependent | Valuable for static closed programs, but still bounded by callbacks, FFI, and dynamic dispatch |
| Exact native YAML plus adapter projection | Tens to low hundreds of mapping lines per language; small oracle fixtures | No measurable parse cost | Improves calls already proven native; 90 more complete functions in the 35-repo corpus below |

Prioritize the third option and receiver/direct-call projection. Add graph work
only after a small measured Rust prototype demonstrates a material latency win
without duplicating Espalier's resolution contract.

## Conservative registry expansion: measured differential

Compared `c247fd215` with this expansion over the same 35-repository
mini+large corpus (16,821 observed functions). The baseline already included
the first registry pass; this measures only the follow-up mappings and the C
free-function receiver correction.

| Language | Complete time before → after | Delta | Unknown operation/function pairs before → after |
| --- | ---: | ---: | ---: |
| C | 270 → 284 | +14 | 6,454 → 6,257 |
| C++ | 654 → 654 | 0 | 4,069 → 4,067 |
| C# | 623 → 624 | +1 | 2,581 → 2,535 |
| Go | 271 → 298 | +27 | 3,414 → 3,190 |
| Java | 680 → 718 | +38 | 4,601 → 4,461 |
| Kotlin | 1,324 → 1,324 | 0 | 10,353 → 10,353 |
| Lua | 88 → 88 | 0 | 2,646 → 2,646 |
| Python | 408 → 418 | +10 | 4,977 → 4,946 |
| Swift | 29 → 29 | 0 | 677 → 677 |
| TypeScript | 599 → 599 | 0 | 3,048 → 3,092 |
| **Total** | **4,946 → 5,036** | **+90** | **42,820 → 42,224** |

The known-time proportion rises from 29.40% to 29.94% (+0.54 percentage
points). This is a useful, essentially free improvement, but corroborates the
graph experiment: a much larger registry alone is not the route to 80%.

The expansion includes exact ISO C string/memory routines; Go `strings`,
`bytes`, `slices`, `maps`, selected `sort`/`errors`/`time`/atomic calls; Java
arrays/collections/math/null checks; C# arrays/math/path/string calls; and
proven Python string/bytes operations. C++/Kotlin/Swift received only
operations already expressible on concrete receivers. Their direct native
calls still need adapter type/direct-call projection before additional YAML can
make a material difference.

No generic JavaScript/TypeScript mappings were added. In fact, the pre-existing
`Object.keys`/`values`/`entries` rows were removed: global binding identity is
not yet proven, and proxies/getters can run user code. That deliberately adds
44 TypeScript unknown operation/function pairs without changing a complete
function count. `Object.assign`, JSON, promises, getters/setters, proxies,
callback-taking collection operations, reflection, IO, synchronization,
interfaces/protocols, and user hooks remain unknown by design.
