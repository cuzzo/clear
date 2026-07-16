# Mini-Corpus Call-Resolution Coverage

Measured 2026-07-16 on the 24 pinned repositories in
`cross-lang-support.md`. Every checkout was at the documented revision.
Production files used the same exclusion policy as the corpus sizing rule:
tests, examples, documentation, generated/build output, coverage, and vendored
dependencies were excluded.

The source of truth is FactMine's final merged `calls` collection. The coverage
reducer does not resolve calls. It only validates and counts the exact target
IDs already emitted by normalization and project merge.

## Metric Contract

- **Total**: every normalized static call site.
- **Eligible**: calls whose source ID is an emitted executable method.
- **Outside executable function**: owner-body, module-body, and top-level calls;
  retained in total but excluded from the resolver-failure denominator.
- **Exact**: target ID exists and names an emitted project method.
- **Modeled without project target**: no project target, but FactMine has a
  documented time or space model for the operation.
- **Unresolved**: neither an exact project target nor a modeled operation.
- **Accounted**: exact plus modeled. This is useful for complexity coverage but
  must not be presented as project-target resolution.

Run the report with:

```bash
gems/fact-mine/target/release/fact-mine-rust \
  call-resolution --format=json SOURCE_FILES...
```

The production manifest additionally excludes language-native test filenames
(`*_test.go`, `test_*.py`, `*_test.py`, `*.test.js`, `*.test.ts`, `*Test.java`,
`*Tests.java`, `*Test.cs`, and `*Tests.cs`), Python `testing/`, and documentation
`site/` trees, plus `generated/` source trees. Directory-only filtering is
insufficient: it previously counted Go tests, a Commons CLI documentation
script, and 16 generated RTree FlatBuffers files as production.

### Local Zig production corpus

The repository-local Zig portability corpus uses
[`zig-production-sources.txt`](zig-production-sources.txt), the transitive
relative-import closure of the production roots declared by `zig/build.zig`:
`runtime/runtime.zig`, `lib/safety.zig`, `lib/ebr.zig`,
`lib/ownership.zig`, `lib/compat.zig`, and `runtime/freeze.zig`. This excludes
test, benchmark, hammer, fuzz, `zig-old`, experimental, generated coverage,
and duplicate runtime sources.

The previous recursive `*.zig` scan mixed 290 files and reported 1,463 exact
targets from 33,391 eligible calls (4.38%), with 4.55% accounted. The fixed
32-file production manifest reports 715 exact targets from 4,707 eligible
calls (15.19%), with 15.87% accounted. Corpus contamination therefore
explained a large part of the apparent failure, but 3,960 production calls
remain unresolved and still require semantic-index and normalization work.
The subsequent [Zig semantic-index spike](zig-semantic-index-spike.md) found
ZLS definitions for 3,612 of those unresolved calls and supports funding a
thin Zig semantic producer.

## Weighted Corpus Result

| Metric | Count | Eligible rate |
| --- | ---: | ---: |
| Total static call sites | 18,787 | — |
| Eligible executable call sites | 17,499 | 100.00% |
| Outside executable functions | 1,288 | excluded |
| Exact project targets | 4,158 | 23.76% |
| Modeled without project target | 1,053 | 6.02% |
| Accounted calls | 5,211 | 29.78% |
| Unresolved calls | 12,288 | 70.22% |
| Unresolved calls with a project candidate set | 423 | 2.42% |
| Functions containing unresolved calls | 3,020 | — |

The denominator partitions exactly: `4,158 + 1,053 + 12,288 = 17,499`.
Candidate sets remain a subset of unresolved calls and are not added to that
partition.

The parser/normalizer audit observes 19,036 adapter-recognized raw call nodes,
18,787 normalized calls, 1,037 raw-only exact spans, and 788 normalized-only
exact spans. The net parser-call surplus is 249 (1.31% of raw calls). Raw-only
and normalized-only spans include span reshaping and synthetic/operator calls,
so 1,037 is a deliberately pessimistic omission ceiling rather than a count of
proven lost calls.

## Expected-versus-measured experiments

Every resolver experiment was added behind an exact semantic oracle and then
measured before the next experiment began. The historical experiment deltas
below used an input list later found to contain test, benchmark, and sample
paths; retain them as directional engineering measurements, not authoritative
production-only benchmark deltas. `Modeled` is deliberately not counted as an
exact target gain.

The 2026-07-16 follow-up used one fixed production manifest and reassessed the
engineering sequence after every measurement:

| Intervention | Expected impact | Measured impact | Assessment |
| --- | ---: | ---: | --- |
| C++ declaration namespace/linkage identity | +120–280 exact | +34 exact | Keep the fact; scoped free calls were a smaller slice than forecast, so demote further C++ specialization |
| Python package/module/import identity | +90–220 exact | +256 exact | Exceeded forecast; module identity was a major upstream defect |
| Header/dependency declaration surfaces | +650–1,500 declaration targets; +0–150 exact bodies | 0 safely measurable from current artifacts | No compilation databases or dependency signatures exist in the corpus checkout; add an external-declaration metric before ingestion |
| Stable Java local and loop-header types | +250–550 exact | +139 exact, +31 modeled | Keep; the classifier over-attributed many free/builtin/expression calls to missing receiver types |
| Additional reaching-definition propagation | +20–80 exact | 0 | Existing resolver already iterates to a fixpoint; missing producer targets and return declarations are upstream blockers |
| Explicit project candidate sets | 400–570 candidate-accounted | 451 candidate sets, 0 exact | Met forecast; preserve ambiguity instead of selecting by order |

On the intervention manifest, exact targets moved from 3,882 of 17,986 calls
(21.58%) to 4,311 (23.97%): +429 calls and +2.39 percentage points. A subsequent
filter audit found that this manifest still contained 16 generated RTree
FlatBuffers files. Removing their bodies removed 360 eligible calls, including
187 calls whose source or exact target was generated. The current safe resolver
also gained 34 exact calls elsewhere, yielding the authoritative 4,158 of
17,499 (23.76%) above. This is a corpus-contract correction, not a resolver
regression. Calls from retained RTree code into generated declarations remain
visible as excluded declaration surfaces.

| Experiment | Expected gain | Measured gain | Cumulative exact | Decision |
| --- | ---: | ---: | ---: | --- |
| Owner-scoped declared field/state type | about 111 exact | +21 exact | 2,975 | Keep: small, correct, and fixed false state classification |
| Declared local/parameter types through CFG normalization | +80–200 exact | +43 exact | 3,018 | Keep: reusable normalized facts |
| Canonical Java imports and same-package types | +100–250 exact | +176 exact | 3,194 | Keep: met forecast |
| Minimal nominal generic/type-alias normalization | +20–80 exact | +49 exact | 3,243 | Keep: met forecast |
| Immediate declared call-result projection | +20–70 exact | +14 exact | 3,257 | Keep: sound but below forecast |
| Assigned call results through reaching definitions | +40–120 exact | +1 exact | 3,258 | Keep generic plumbing; stop expanding this slice |
| Proven native receiver to reviewed API model | +150–400 modeled | +298 modeled | 3,258 | Keep: best accounted-rate return |
| Canonical Go directory/package lexical symbols | +80–220 exact | +29 exact | 3,287 | Keep: safe boundary, below forecast |
| Canonical Java owner normalization | +60–120 exact | +86 exact | 3,373 | Keep: fixed malformed owner identities |
| Java same-package static type binding | +80–110 exact | +116 exact | 3,489 | Keep: exceeded forecast with shadowing oracle |
| Canonical C# namespace identity | +30–60 exact | +19 exact | 3,508 | Keep the fact; do not add speculative static dispatch |
| Conservative inherited dispatch | +88 direct exact | +81 exact | 3,589 | Keep: 78 direct plus 3 downstream; ambiguity remains unknown |
| Annotation/multiline parameter declaration slicing | +120–220 exact | +260 exact, +37 modeled | 3,849 | Keep: largest normalization win; no regressions after fallback correction |
| Java exact-arity overload selection | +150–300 exact | +52 exact | 3,901 | Keep narrow rule; stop before full overload typing |
| Java stable declared-local fallback | +120–250 exact | +9 exact, +8 modeled | 3,910 | Keep narrow rule; missing binding facts are upstream |
| Control-binding reorder experiment | +60–150 exact | 0 | 3,910 | Discard: normalized loop nodes lack the native declaration surface |

The C external-linkage proposal was assessed but not implemented. FactMine can
distinguish `static` definitions, but a repository-wide unique-name join still
cannot prove that a caller and definition belong to the same linked target.
Header/include and build-target identity must come first.

Delivered exact-target value, relative to implementation cost, ranks as:

1. Canonical Java import/package symbols.
2. Minimal generic/alias normalization.
3. Declared local and parameter types.
4. Canonical Go package-local symbols.
5. Declared field/state projection.
6. Immediate call-result projection.
7. Reaching-definition call-result projection.

Proof-gated external API models rank first for complexity-accounting value, but
they do not resolve a project target and must remain a separate metric.

Unresolved reasons:

| Reason | Calls | Share of unresolved |
| --- | ---: | ---: |
| `receiver_requires_corpus_resolution` | 6,839 | 54.07% |
| `target_not_defined_in_document` | 5,068 | 40.07% |
| `state_receiver_requires_corpus_resolution` | 741 | 5.86% |

No dangling target IDs or unclassified failure reasons were observed.

The merge-time first-missing-proof classifier gives a more actionable,
mutually exclusive partition of the 12,288 unresolved calls:

| First missing proof | Calls | Share of unresolved |
| --- | ---: | ---: |
| Declaration not analyzed or call is dynamic | 2,212 | 18.00% |
| Receiver identity missing, no project name candidate | 1,728 | 14.06% |
| Producer call target missing | 1,642 | 13.36% |
| Declaration not in analyzed project | 1,379 | 11.22% |
| Receiver type known, declaration unavailable | 1,127 | 9.17% |
| Project name candidate exists, receiver type missing | 882 | 7.18% |
| Project binding/implicit receiver type missing | 789 | 6.42% |
| Imported binding known, declaration unavailable | 731 | 5.95% |
| Overload/override ambiguous | 460 | 3.74% |
| Proven reflection/dynamic dispatch | 321 | 2.61% |
| All other first proofs | 1,017 | 8.28% |

Only 154 calls have a resolved producer but lack a direct return-type fact.
The 1,642 producer-target misses therefore do not demonstrate missing CFG/DFG;
they are downstream of unresolved inner calls. Proven reflection/dynamic
dispatch is only 2.61% of unresolved calls.

The useful architectural grouping is:

| Required capability | Calls | What it means |
| --- | ---: | --- |
| Declaration surface absent from current index | 7,413 | No solver candidate exists: dependency/stdlib/header/macro declaration unavailable, receiver identity points outside the project, or normalization lost the callee identity |
| Project binding/dispatch proof missing | 2,758 | Project declarations exist, but receiver type, import/linkage identity, hierarchy selection, or overload proof is incomplete |
| Producer call unresolved | 1,642 | Outer call is blocked by an unresolved inner call |
| Direct return fact missing | 154 | Producer is known; declared/inferred return type is genuinely missing |
| Proven reflection/dynamic dispatch | 321 | Exact static target is not justified |

These rows partition all 12,288 unresolved calls. An SMT solver cannot help the
7,413 calls whose candidate domain is empty. It may help a subset of the 2,758
project-proof calls after normalization supplies candidate declarations and
type constraints.

### Empty declaration-domain forensic split

Every one of the 7,413 calls now retains an `empty_domain_cause`, and coverage
aggregates those causes without recomputing resolution. The requested binary
split is not semantically exhaustive: macros and genuine dynamic callables are
neither external function declarations nor normalization loss. The proven
partition is:

| Root cause | Calls | Share of empty domain | Assessment |
| --- | ---: | ---: | --- |
| External stdlib/runtime declaration | 2,663 | 35.92% | External identity is proven; declaration/model surface is absent |
| Imported declaration outside analyzed set | 312 | 4.21% | Forensic path/identity audit splits this into 179 dependencies and 133 deliberately excluded generated RTree declarations |
| Normalization: receiver/module identity missing | 1,692 | 22.82% | Definite normalization/binding loss |
| Normalization: import/type-symbol binding missing | 815 | 10.99% | A declared type exists but its canonical symbol was not recovered |
| Normalization: known project declaration surface missing | 326 | 4.40% | Project owner/namespace exists but the member surface was lost |
| Normalization: non-call construct emitted as call | 134 | 1.81% | Cast/conversion or other syntax normalization defect |
| Macro/preprocessor surface | 361 | 4.87% | Requires macro/header preprocessing facts, not ordinary dispatch |
| Dynamic global or function-parameter callable | 401 | 5.41% | Requires function-value flow or remains genuinely dynamic |
| External/excluded receiver declaration indeterminate | 278 | 3.75% | Receiver type exists, but current evidence cannot prove project vs dependency ownership |
| Static lexical surface indeterminate | 431 | 5.81% | No analyzed declaration exists; header API, macro, callback, and parser-loss cases remain mixed |

Thus the defensible lower bounds are **2,842 true external declarations
(38.34%)**, **133 excluded generated declarations (1.79%)**, and **2,967 proven
normalization losses (40.02%)**. Macro and dynamic/function-value cases account
for 762 (10.28%). Only 709 (9.56%) remain genuinely indeterminate. Treating all
imports as dependencies would have overstated external dependencies by 133;
treating macros or dynamic calls as normalization failures would be equally
misleading.

The largest single actionable fact is therefore not “dependencies”: at least
40.02% of the empty-domain bucket is already proven to be our normalization or
binding loss. The 709-call residual also visibly contains normalization defects
(for example Java/C# receiver types containing whole source expressions and
C++ qualified calls represented through a synthetic `self`), so 40.02% is a
floor, not a ceiling.

The audit also found a concrete C++ normalization defect: scoped/template free
calls were emitted as message `call` with the actual callee stored as a
receiver. The adapter now retains names such as `plog::init` and
`util::toWide`, while the C++ adapter emits per-declaration namespace identity.
That closed 34 calls. Remaining linkage misses require header/include and build
target identity and must not fall back to short-name matching.

## Java SCIP prototype

Java was selected for the first compiler-index prototype because it has the
largest exact-target opportunity in the corpus: 4,315 eligible calls, of which
2,527 were unresolved before the experiment. It is also statically typed and
all three Java repositories have Maven builds, so a compiler-backed result can
test whether missing compiler semantics, rather than CFG/DFG capacity, is the
dominant problem.

The isolated prototype used `scip-java` 0.13.1 with Temurin JDK 21 and Maven
3.9.11. It indexed fresh copies of Commons CLI, JavaPoet, and RTree, matched
each FactMine call span to the callable SCIP occurrence at that span, and
mapped project definition occurrences back to the innermost emitted FactMine
method ID. It did not use short-name or owner guessing. This is a deliberately
read-only comparison; SCIP did not participate in FactMine resolution.

| Result | Calls | Eligible rate |
| --- | ---: | ---: |
| Current exact project target | 1,382 | 32.03% |
| SCIP exact production-project definition | 2,407 | 55.78% |
| SCIP JDK symbol | 1,656 | 38.38% |
| SCIP dependency symbol | 84 | 1.95% |
| SCIP definition in excluded/generated source | 158 | 3.66% |
| No callable SCIP occurrence | 10 | 0.23% |

SCIP therefore adds **1,025 exact project targets** and **23.75 percentage
points** for Java. Substituting only this Java result into the weighted corpus
would move exact project coverage from 4,158/17,499 (23.76%) to 5,183/17,499
(29.62%), a **5.86-point corpus gain** before prototyping any other language.

The project-target result by repository is:

| Repository | Eligible | Current exact | SCIP exact | Exact gain |
| --- | ---: | ---: | ---: | ---: |
| Commons CLI | 1,390 | 514 (36.98%) | 757 (54.46%) | +243 / +17.48 points |
| JavaPoet | 1,375 | 257 (18.69%) | 759 (55.20%) | +502 / +36.51 points |
| RTree | 1,550 | 611 (39.42%) | 891 (57.48%) | +280 / +18.06 points |

SCIP supplied a semantic symbol for 4,305/4,315 calls (99.77%). Manual review
of all ten unmatched sites found no real invocation: they are field projections
such as `name`, `type`, and `componentType`, `this`/`System.err` receiver
fragments, and text from a comment. After removing these normalization false
positives, the compiler index bound every genuine call site in this Java slice.
The 44.22% not mapped to a production project body is therefore overwhelmingly
external or deliberately excluded code, not unresolved Java dispatch.

The comparison also found 20 calls for which both systems emitted an exact
project target but disagreed. All 20 were inspected against the source and SCIP
was correct: one is a Commons CLI `parse` overload, and 19 are RTree owner or
overload errors involving `intersects`, `ptSegDist`, `read`,
`calculateDepth`, and `searchWithoutBackpressure`. Thus the current 1,382 Java
targets include at least 20 known false exacts. The prototype provides 1,025
new targets and corrects 20 unsafe existing targets; it does not merely improve
the count.

The 1,025 new project targets split by the old first-missing-proof classifier:

| Old first missing proof | Calls |
| --- | ---: |
| Overload or override ambiguous | 356 |
| Project candidate exists, receiver type missing | 135 |
| Project binding or implicit receiver type missing | 131 |
| Producer call target missing | 86 |
| Canonical project receiver binding missing | 65 |
| Implicit dispatch semantics missing | 50 |
| Receiver type known, declaration unavailable | 42 |
| Direct call-result type missing | 42 |
| Receiver identity known, declaration unavailable | 35 |
| Hierarchy dispatch ambiguous | 27 |
| Project lexical binding missing | 20 |
| Declared field type missing | 12 |
| Hierarchy edge missing a unique target | 12 |
| Other | 12 |

This is strong evidence to stop expanding a handwritten Java resolver. The
compiler already has the import, overload, generic, inferred-type, hierarchy,
and expression-typing proofs that the shared resolver is attempting to
reconstruct. CFG/DFG and normalized declared facts remain useful for complexity
propagation, data flow, dynamic/function-value analysis, languages without a
usable SCIP indexer, and operation modeling. They should consume compiler
identity where available, not compete with it.

### Production SCIP-to-Big-O integration

The target-only prototype below has now been replaced by a production import
path. FactMine accepts either a binary `.scip` file (converted with `scip
print --json`) or a JSON export through repeatable `--scip-index` arguments.
Espalier exposes the same option and consumes the resulting canonical call
records; it contains no Java symbol parser.

The production implementation additionally fixes the consumer defects exposed
by the prototype:

- method summaries, resolved call sites, and recursion SCC edges retain exact
  method IDs instead of collapsing overloads by owner/name;
- a SCIP-complete method call graph can disprove syntactic same-name recursion;
- same-named overload calls are removed from syntax-only recursion facts only
  when every candidate call has an exact SCIP target and none targets the
  caller;
- occurrence selection requires one semantic symbol identity, not one textual
  occurrence, so a parameter named `format` cannot mask `String.format` and a
  repeated same-symbol fluent chain is not falsely ambiguous;
- state protocol evidence is joined to an existing call at the same line and
  message instead of becoming a duplicate targetless delegation, including
  proven state receivers spelled as `this.field` or `self.field`;
- an empty exact fact set never falls back to a different overload's facts;
- external SCIP symbols use only language-owned reviewed cost models.

The Java model pass added bounds only for concrete, implementation-independent
APIs (`Optional`, string comparisons/queries, primitive wrapper comparisons,
and constant `Collections.unmodifiable*` wrappers). `List`, `Map`, `Iterator`,
callbacks, and other interface-dependent calls remain unknown.

The final comparison used the same 120 production Java files and 1,385
executable functions in Commons CLI, JavaPoet, and RTree for both profiles.

| Call metric | Without SCIP | With SCIP | Delta |
| --- | ---: | ---: | ---: |
| Exact project targets | 1,382/4,315 (32.03%) | 2,402/4,315 (55.67%) | +1,020 / +23.64 points |
| Modeled external/non-project calls | 472/4,315 (10.94%) | 701/4,315 (16.25%) | +229 / +5.31 points |
| Accounted calls | 1,854/4,315 (42.97%) | 3,103/4,315 (71.91%) | +1,249 / +28.95 points |
| Unresolved calls | 2,461/4,315 (57.03%) | 1,212/4,315 (28.09%) | -1,249 / -28.95 points |

SCIP selected a unique semantic symbol for 4,283 of 4,315 eligible calls
(99.26%). The importer accepts repeated textual occurrences only when they
collapse to one semantic identity; distinct overload symbols remain ambiguous.
The remaining compiler-identified but unmodeled external surface is 939 JDK
calls and 242 dependency or excluded-declaration calls. These are cost/model
gaps, not lost call identity. Only 31 eligible calls lack semantic identity.

| Complete function bound | Without SCIP | With SCIP | Delta |
| --- | ---: | ---: | ---: |
| All three repositories | 555/1,385 (40.07%) | 701/1,385 (50.61%) | +146 / +10.54 points |
| Commons CLI | 224/471 (47.56%) | 277/471 (58.81%) | +53 / +11.25 points |
| JavaPoet | 50/385 (12.99%) | 75/385 (19.48%) | +25 / +6.49 points |
| RTree | 281/529 (53.12%) | 349/529 (65.97%) | +68 / +12.85 points |

Time and space completeness have the same counts in this corpus. There are 150
unknown-to-known transitions and four known-to-unknown transitions, for the
net gain of 146. The four losses are soundness corrections: SCIP exposes the
real incomplete callee behind `CommandLine#getOptionValue`,
`CodeBlock::Builder#addStatement`, and two `JavaFile#writeTo` overloads, all of
which the baseline had incorrectly left at `O(1)`.

Reproduce the method-level comparison with:

```bash
gems/espalier/script/compare_scip_big_o.rb \
  --source-root /path/to/mini-repos \
  baseline-profile.json scip-profile.json
```

Diagnose the first missing semantic or cost proof, both directly and after
propagation through incomplete project callees, with:

```bash
gems/espalier/script/diagnose_big_o_gaps.rb \
  --source-root /path/to/mini-repos \
  --repository javapoet scip-profile.json
```

The report partitions exact project targets, modeled calls, JDK interface,
concrete, callback and I/O costs, dependency surfaces, and missing semantic
identity. It also reports direct blockers, transitive root causes, exact missing
identity reasons, top SCIP symbols, normalized unknown operations, and example
method IDs and source locations.

#### Why JavaPoet remains low

JavaPoet has 1,375 eligible production calls. SCIP now gives 754 exact project
targets and 172 modeled non-project calls. Of the remainder, 437 have exact JDK
identity but no proven cost and only 12 lack semantic identity. The 437 JDK
calls divide into 245 collection-interface calls, 62 `javax.lang.model` calls,
and 130 other concrete, callback, or I/O calls. There are no unmodeled
third-party dependency calls in JavaPoet, so dependency parsing cannot improve
this repository directly.

The direct Big-O blockers touch 122 functions through interface/abstract JDK
calls, 55 through concrete JDK calls, three through I/O, one through a callback,
and seven through missing semantic identity. Propagation amplifies these small
direct sets: the primary root partition of 310 incomplete functions is 157 JDK
interface/abstract, 109 missing semantic identity, 40 concrete JDK, and four
unclassified project-summary gaps. One unresolved leaf can therefore keep a
large caller subtree incomplete even though most calls in that subtree resolve.

Collection interfaces do not specify implementation complexity. SCIP proves
`List#add` or `Map#get`, but not whether the runtime object is an `ArrayList`,
`LinkedList`, immutable wrapper, or caller-provided implementation. A sound
next stage must join SCIP's declaration identity to FactMine allocation,
constructor, field-initializer, and reaching-definition facts. This is where a
SCIP plus Tree-sitter/CFG/DFG design has leverage. It should recover many of the
126 interface calls on proven state receivers, while interface-typed parameters
and `javax.lang.model` values may legitimately remain implementation-dependent.

#### Measured cost ceilings

The following counterfactuals attach an `O(1)` placeholder only to isolate the
effect of obtaining a correct cost. They are sensitivity ceilings, not bounds
that may be shipped; real models must retain argument cardinality, callback,
I/O, and implementation dependence.

| Added cost knowledge | All repositories | JavaPoet | Gain over current |
| --- | ---: | ---: | ---: |
| Current production result | 701/1,385 (50.61%) | 75/385 (19.48%) | — |
| Collection/interface and `javax.lang.model` calls | 849/1,385 (61.30%) | 139/385 (36.10%) | +148 overall |
| Every semantically identified JDK call | 1,057/1,385 (76.32%) | 226/385 (58.70%) | +356 overall |
| Every semantically identified dependency call | 741/1,385 (53.50%) | 75/385 (19.48%) | +40 overall |
| Every semantically identified external call | 1,115/1,385 (80.51%) | 226/385 (58.70%) | +414 overall |
| Every unresolved call as well | 1,160/1,385 (83.75%) | 258/385 (67.01%) | +459 overall |

This makes an approximately 80% aggregate result reasonable, but not by adding
blanket stdlib constants. JDK identity and costs are the dominant opportunity;
dependency source/metadata analysis contributes a measured ceiling of 40
functions, all outside JavaPoet. JavaPoet itself cannot reach 80% from call
costs alone: even the deliberately optimistic every-call oracle reaches 67.01%.
Its remaining gap is in normalized fluent/field projections, exact call-context
joins, and recursive/structural progress evidence.

The complete FactMine suite (301 unit tests, 75 integration/oracle tests) and
every Espalier test file passed before this corpus run. A direct binary-index
smoke test imported semantic identity for 1,372/1,390 eligible Commons CLI
calls. Its exact targets, symbols, provenance, and costs were byte-for-byte
identical to the JSON-export run, so the measured path and the user-facing
`.scip` path exercise the same importer.

SCIP does not remove the need for stdlib models. In the final production
profile, 939 JDK calls are semantically identified yet still unmodeled.
Dependency symbols likewise name
the owning artifact but do not provide body complexity. SCIP supplies identity;
stdlib/dependency models supply cost, effects, and collection semantics.

### Earlier target-only Big-O differential

The following numbers are retained as the pre-integration diagnostic. They are
superseded by the production result above.

The 1,025 new targets and 20 corrected targets were injected into an in-memory
copy of the same profile and passed through Espalier's actual SCC/fixed-point
aggregator. No local complexity facts or stdlib models were changed.

| Function-bound result | Baseline | With SCIP targets | Delta |
| --- | ---: | ---: | ---: |
| Complete time bound | 519/1,385 (37.47%) | 532/1,385 (38.41%) | +13 / +0.94 points |
| Incomplete time bound | 866/1,385 (62.53%) | 853/1,385 (61.59%) | -13 / -0.94 points |
| Complete space bound | 519/1,385 (37.47%) | 532/1,385 (38.41%) | +13 / +0.94 points |
| Incomplete space bound | 866/1,385 (62.53%) | 853/1,385 (61.59%) | -13 / -0.94 points |

There were 19 unknown-to-known and six known-to-unknown transitions. The
latter are useful corrections: resolving a real internal call can expose an
incomplete callee and invalidate a previously unjustified `O(1)` result. With
only the 1,025 added targets there were 20 gains and six losses (net +14); the
20 corrected existing targets have no effect alone but change one result when
composed with the additions, producing the final net +13.

The net result is concentrated in RTree (+16 complete), while Commons CLI is
flat and JavaPoet loses three falsely complete results. Although only 25 final
known/unknown labels change, 256 function summaries (18.48%) change in some
way; 250 change their unknown-operation list and 180 change their evidence-gap
list. This target-only differential is not a fair ceiling for SCIP's Big-O
value because the current Big-O consumer does not consistently consume the
canonical call records.

The forensic follow-up found four independent cost-pipeline defects:

- 4,315 eligible Java calls coexist with 5,963 complexity call contexts. Of
  those contexts, 1,711 have no exact call-span match, predominantly operators
  and field/constant projections; 63 real calls have no exact context match.
- Espalier converts 658 Java `state_protocol_records` touching 277 functions
  into additional targetless call delegations. These effect/protocol facts
  duplicate real calls and independently make bounds unknown.
- FactMine marked 209 methods with unresolved recursion. Of 201 that map
  uniquely to emitted methods, only 21 are recursive in SCIP's exact call
  graph; at least 180 are overload calls falsely treated as recursion.
- Espalier's fixed-point maps method summaries by owner and short method name,
  not exact method ID. Java overload identity is therefore discarded after
  SCIP has proved it.

Counterfactual completeness runs isolate the missing-cost categories. An
“oracle cost” below is an `O(1)` placeholder used only to ask whether a method
would become complete if the correct cost were available. It is not a proposed
bound and must not be shipped as one.

| Counterfactual | Complete bounds | Gain from baseline |
| --- | ---: | ---: |
| Current baseline | 519/1,385 (37.47%) | — |
| SCIP exact project targets only | 532/1,385 (38.41%) | +13 / +0.94 points |
| SCIP + costs for 1,250 currently unmodeled JDK calls | 703/1,385 (50.76%) | +184 / +13.29 points |
| SCIP + costs for 84 dependency calls | 551/1,385 (39.78%) | +32 / +2.31 points |
| SCIP + JDK and dependency costs | 727/1,385 (52.49%) | +208 / +15.02 points |
| SCIP + all non-project costs | 740/1,385 (53.43%) | +221 / +15.96 points |
| SCIP + JDK costs + no duplicate protocol delegations | 886/1,385 (63.97%) | +367 / +26.50 points |
| SCIP + all non-project costs + no duplicate protocol delegations | 945/1,385 (68.23%) | +426 / +30.76 points |
| Previous row + compiler-proven recursion identity | 947/1,385 (68.38%) | +428 / +30.90 points |

The primary missing cost surface is therefore the JDK, amplified by a consumer
bug. The 1,250 unmodeled JDK call sites represent 275 unique SCIP symbols. The
dependency surface is only 84 calls and 29 unique symbols, all in RTree; it is
worth modeling on demand but is not the dominant corpus blocker. Correct JDK
models cannot be a blanket `O(1)` registry: operations such as `List#get`,
`toArray`, streams, sorting, formatting, callbacks, and output require concrete
receiver/implementation identity, cardinality substitution, callback
composition, or an explicit opaque term.

The JDK surface is strongly concentrated: the top 10 exact symbols cover 497
calls (39.76%), the top 25 cover 746 (59.68%), and the top 50 cover 904
(72.32%). A reviewed symbol-first model pass can therefore measure substantial
value before attempting all 275 symbols.

The correct recovery order for Big-O is now:

1. Make normalized `CallRecord` plus exact call-site ID/span the only call
   identity consumed by complexity analysis.
2. Stop converting state protocol/effect summaries into independent call
   delegations; join them to the canonical call when relevant.
3. Key fixed-point summaries and recursion SCCs by exact method ID. Use SCIP's
   target IDs for Java rather than owner/name reconstruction.
4. Attach versioned JDK cost/effect contracts to exact SCIP symbols and retain
   symbolic receiver/argument cardinality.
5. Ingest the 29 observed dependency symbols on demand; callback/I/O contracts
   may legitimately remain opaque.

This path does not require analyzing every dependency before Big-O becomes
useful. The measured Java ceiling exceeds 63% with JDK costs and the duplicate
consumer path fixed, before dependency analysis. The current low result is
primarily our integration and stdlib-modeling failure, not an inherent limit of
static Big-O analysis.

### Aliasing consequence

SCIP is a substantial prerequisite for interprocedural alias/effect analysis,
but is not itself an alias analysis. The 1,025 new project edges connect 484
distinct callers (34.95% of the 1,385 Java functions) to 366 callees. Of those
edges, 835 carry at least one argument, 841 point to a parameterized callee,
174 reach a callee with an already-recorded state access, and 51 reach a callee
with an already-recorded state write. This is a material new surface on which
receiver/argument mutation and escape summaries can be applied.

SCIP does not provide heap-object identity, allocation sites, must-/may-alias
sets, parameter-to-field or parameter-to-return flow, mutation/escape effects,
or CFG feasibility. Consequently it adds no alias finding by itself. Its value
is that it selects the correct callee summary at cross-file and overloaded call
sites. The existing CFG/DFG, stable places, reaching definitions, and planned
alias transfer/join rules remain necessary. The right composition is:

1. SCIP owns compiler-proven symbol and call identity where an index exists.
2. FactMine owns local values/places, CFG/DFG, allocation and assignment alias
   edges, and inferred receiver/argument/return/escape summaries.
3. External stdlib/dependency effect models close only reviewed semantic gaps;
   an unmodeled external call makes affected alias state unknown.

For the narrow first slice (`y = x`, direct mutation, later use), SCIP adds
little because the proof is intraprocedural. For the planned cross-method
projection and inferred project-call-summary slice, the measured 1,025 edges
make it substantially useful and remove what would otherwise be a hard
one-third-of-functions ceiling in this Java corpus.

The production integration boundary should remain small:

1. A shared SCIP protobuf importer maps source occurrences and definition
   ranges to FactMine IDs and retains external symbols and provenance.
2. FactMine must retain the exact callee-token span, instead of making the
   importer infer it from the larger invocation span.
3. A thin per-language/build adapter invokes an available indexer. Java-specific
   code should orchestrate Maven/Gradle only; it should not reconstruct Java
   type or dispatch semantics.
4. SCIP and the current resolver run side by side initially. Disagreements are
   correctness regressions to audit, and a heuristic target must never override
   a compiler target.
5. Missing index, build failure, external symbol, excluded definition, and true
   missing occurrence remain distinct outcomes.

Build orchestration is the material operational risk. RTree indexed unchanged.
Commons CLI required its existing compiler-fork property to be enabled for the
compiler plugin. JavaPoet's POM selected an obsolete Error Prone compiler
wrapper that cannot run on JDK 21, so the isolated copy used the standard
`javac` compiler ID. A production integration must apply such overrides in a
temporary build view and never rewrite the analyzed checkout.

The generated indexes are useful for occurrence bindings, but `scip lint`
rejects all three because `scip-java` references JDK, dependency, and hierarchy
symbols without embedding matching external `SymbolInformation`. Every lint
diagnostic was of this missing-external-information form (2,490 for Commons
CLI, 8,104 for JavaPoet, and 27,148 for RTree). This does not invalidate the
source occurrence-to-symbol mappings measured above, but it means external
declaration metadata must be obtained from dependency indexes or models rather
than assumed to be embedded in these index files.

## Inheritance Assessment

Adapters normalize only native direct base/interface/promotion clauses. Shared
merge logic performs the project index walk and resolves only one proven target;
unknown edges and multiple branch candidates stay unresolved.

| Language | Owners with edges | Direct edges | Initial unique opportunities | Measured exact gain | Current unique/ambiguous |
| --- | ---: | ---: | ---: | ---: | ---: |
| Java | 103 | 109 | 31 | +33 | 11 / 27 |
| Python | 107 | 124 | 53 | +46 | 7 / 2 |
| Go | 10 | 10 | 2 | +2 | 0 / 0 |
| C# | 71 | 81 | 2 | 0 | 2 / 0 |
| C++ | 23 | 37 | 0 | not enabled | 0 / 0 |
| TypeScript | 7 | 7 | 0 unique | not enabled | 0 / 6 |
| JavaScript | 0 | 0 | 0 | not enabled | 0 / 0 |

The stage forecast 88 direct exact targets and measured +81 total: 78 direct
targets plus three downstream call-result targets. It is worth keeping, but its
0.43-point gain proves inheritance was not the principal coverage gap. C++ and
TypeScript dispatch remain measurement-only until access/template/structural
semantics have exact language oracles.

## By Language

These are weighted by eligible call sites, not averages of repository rates.

| Language | Eligible | Exact | Exact rate | Modeled | Accounted rate | Candidate sets | Unresolved rate |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| C | 3,051 | 1,242 | 40.71% | 246 | 48.77% | 0 | 51.23% |
| C++ | 1,696 | 187 | 11.03% | 34 | 13.03% | 51 | 86.97% |
| C# | 1,495 | 186 | 12.44% | 63 | 16.66% | 36 | 83.34% |
| Go | 1,479 | 168 | 11.36% | 86 | 17.17% | 0 | 82.83% |
| Java | 4,315 | 1,382 | 32.03% | 406 | 41.44% | 313 | 58.56% |
| JavaScript | 787 | 159 | 20.20% | 31 | 24.14% | 0 | 75.86% |
| Python | 3,871 | 758 | 19.58% | 168 | 23.92% | 17 | 76.08% |
| TypeScript | 805 | 76 | 9.44% | 19 | 11.80% | 6 | 88.20% |

## By Repository

| Repository | Eligible | Exact rate | Accounted rate | Candidate-set rate | Unresolved rate | Outside executable |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| ants | 317 | 14.83% | 25.55% | 0.00% | 74.45% | 15 |
| cJSON | 667 | 40.63% | 48.28% | 0.00% | 51.72% | 0 |
| Commons CLI | 1,390 | 36.98% | 52.45% | 6.47% | 47.55% | 92 |
| Costura | 618 | 16.34% | 23.46% | 3.56% | 76.54% | 1 |
| eventpp | 754 | 11.54% | 14.99% | 2.39% | 85.01% | 33 |
| fast-json-stringify | 375 | 26.67% | 32.53% | 0.00% | 67.47% | 128 |
| go-immutable-radix | 248 | 16.94% | 25.81% | 0.00% | 74.19% | 0 |
| JavaPoet | 1,375 | 18.69% | 26.11% | 12.07% | 73.89% | 143 |
| jwt | 336 | 13.69% | 18.15% | 0.00% | 81.85% | 38 |
| mapstructure | 578 | 5.71% | 8.30% | 0.00% | 91.70% | 0 |
| Mistune | 1,399 | 24.95% | 30.38% | 0.00% | 69.62% | 50 |
| MockHttp | 308 | 13.31% | 15.26% | 1.95% | 84.74% | 0 |
| mpc | 1,500 | 57.53% | 68.20% | 0.00% | 31.80% | 6 |
| Pino | 412 | 14.32% | 16.50% | 0.00% | 83.50% | 183 |
| plog | 467 | 9.64% | 10.71% | 4.71% | 89.29% | 113 |
| Pluggy | 335 | 16.42% | 16.72% | 0.00% | 83.28% | 26 |
| proxy | 494 | 11.34% | 11.94% | 2.23% | 88.06% | 80 |
| pydantic-settings | 1,224 | 15.28% | 20.02% | 0.25% | 79.98% | 14 |
| Requests | 892 | 18.61% | 22.31% | 1.57% | 77.69% | 45 |
| RTree | 1,550 | 39.42% | 45.16% | 3.68% | 54.84% | 54 |
| SmartEnum | 571 | 7.71% | 9.98% | 1.40% | 90.02% | 24 |
| tsup | 594 | 4.71% | 7.41% | 0.00% | 92.59% | 174 |
| tsyringe | 211 | 22.75% | 24.17% | 2.84% | 75.83% | 0 |
| wrk | 884 | 12.22% | 16.18% | 0.00% | 83.82% | 69 |

## Interpretation

The current exact project-target rate is **23.76%**, the accounted rate is
**29.78%**, and the unresolved rate is **70.22%**. In addition, **423 calls
(2.42%)** retain explicit project candidate sets without being mislabeled as
exact. This remains inadequate as
broad call-graph coverage. The largest confirmed implementation gains came
from restoring declaration facts that existing CFG/DFG could already carry;
the largest remaining project-addressable buckets are receiver/binding
identity, declared control bindings, canonical module/linkage identity, and
overload proof. Dependency and stdlib declarations require a separate external
target metric: they cannot become exact *project* targets. Any improvement must
reduce a named first-proof bucket while preserving exact target IDs and the
semantic oracle suite; aggregate movement alone is not evidence of correctness.

Reaching 50% on the present exact-project-target contract requires 8,750 exact
calls, or **4,592 more** than today. The entire project-proof, unresolved
producer, and direct-return groups contain 4,554 calls. In other words, 50%
would require resolving essentially every currently visible internal candidate
chain, plus recovering project declarations from the nominally absent-surface
group. That is not a credible near-term forecast. Dependency, standard-library,
and header declarations need a separate exact-external-declaration metric;
counting them as project method bodies would falsify the existing metric.

A compiler comparison is valid only after matching its inputs and output
contract. A compiler has the selected build target, include paths, dependency
versions, conditional defines, and complete declaration surfaces. FactMine's
mini-corpus invocation has source paths only. Compilers also generally resolve a
virtual/interface call to a declaration plus a candidate implementation set,
not one guaranteed runtime implementation; Python and JavaScript do not promise
compile-time nominal dispatch at all. The current 70.22% unresolved rate is
still unacceptable, but the measured failure is primarily missing semantic
inputs and normalized identities—not a constraint-solving failure.
