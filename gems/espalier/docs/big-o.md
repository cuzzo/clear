# Big-O Confidence and Language Quality

Espalier reports symbolic upper bounds for time and auxiliary space. A printed
expression such as `O(N log N)` is only half of the result: the proof status
records why that expression is usable and which assumptions remain. Call
resolution coverage is an input to this analysis, not a substitute for it. A
call can have an exact target while its cost, callback behavior, recursion
progress, or input-cardinality relationship remains unknown.

This document describes the confidence contract and gives an approximate
function-level quality snapshot for every language FactMine currently accepts.
The architecture contract remains in
[agents/big-o-design.md](agents/big-o-design.md).

## Confidence levels

### 1. Analyzer-proven, no assumptions

The time bound and every transitive cost needed by it are complete, with no
manual/model qualification and no unresolved assumption. Structural facts come
from normalized Tree-sitter evidence and Espalier's language-neutral complexity
algebra.

Examples include a fixed loop, a loop over a known input domain, or a project
call graph whose callees all have analyzer-proven bounds.

This is the strongest result. In `BigOProofMetrics` it is
`known_provably`, backed by the `analyzer_result` bucket.

### 2. Trusted, model-derived, or explicitly conditional

The function has a complete symbolic upper bound, but at least one step relies
on an explicit contract or retained assumption. This is not a guessed `O(1)`.
The qualifying evidence is serialized with the result.

The underlying buckets are:

- `exact_or_declared`: a reviewed standard-library, dependency, intrinsic, or
  declared-operation cost;
- `modeled_world`: an upper bound within the explicitly modeled implementation
  world;
- `parametric`: a callback or reflective cost retained symbolically, such as
  `O(N * C)` time and `O(N + S)` space;
- `recursive_progress`: a complete conditional SCC bound whose progress or
  acyclicity proof is still an assumption;
- `external_latency`: computational work is bounded, but filesystem, network,
  process, device, scheduler, stream, or terminal latency is explicitly
  excluded.

Consumers may use these bounds when their assumptions match the question being
asked. They must not relabel them as assumption-free proofs.

### 3. Maximum over a closed candidate set

Semantic indexing proved a finite, closed set of possible project targets and
every candidate has a complete cost. Espalier reports the largest candidate
bound. This is a sound upper bound for the closed world, but it can overstate
the runtime cost because a cheaper implementation may be selected.

This is `known_candidate_max`, backed by `closed_candidate_max`. It is kept
separate from ordinary trusted models because the uncertainty is dispatch
choice, not missing cost knowledge.

### 4. Further analysis or proof required

At least one required proof is absent, so the result remains `unknown`. Common
causes are an unresolved receiver or callback, an unmodeled external symbol, an
incomplete project callee, unknown cardinality, or unproved recursive progress.

This is an honest implementation gap or an unresolved program property. It
does not mean the function is theoretically unknowable, and an unknown term is
never silently treated as constant.

### 5. Demonstrated unknowable

The analyzer has evidence that no single static bound exists under the stated
contract—for example, behavior is selected by unrestricted runtime code and no
closed implementation or callback set is available. This is recorded as
`demonstrated_unknowable`, not merely inferred from analysis failure.

No function in the measured corpora below is currently in this category. All
current unknowns are therefore work remaining, missing contracts, or properties
that have not yet been proved—not demonstrated impossibilities.

## Approximate quality by language

The table classifies complete function-level time bounds using the production
[`BigOProofMetrics`](../lib/espalier/big_o_proof_metrics.rb) reducer. Percentages
use emitted executable functions as the denominator and are rounded to one
decimal place. The categories are mutually exclusive and each row sums to its
function count.

For an enforceable production-only measurement, run:

```sh
gems/espalier/script/check_big_o_coverage.rb \
  --source-root /path/to/corpus \
  --repository project \
  --minimum 85 \
  profile.json
```

The JSON result records the source-role and lambda policies, keeps analyzer,
declared, modeled-world, closed-candidate, parametric, and recursive proof
buckets separate, and exits unsuccessfully below the requested threshold. It
also fails closed when FactMine reports an executable raw call that did not
reach normalized call facts; otherwise an omitted call could make a function
look complete.

Measured 2026-07-17 at `18a2d4cbd`. These are quality samples, not language
benchmarks: repository structure, dependency surface, callback density, and the
share of trivial accessors all affect the result.

| Language | Functions | Analyzer-proven | Trusted / conditional | Closed-set maximum | Further proof | Unknowable |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| C | 619 | 94 (15.2%) | 1 (0.2%) | 0 (0.0%) | 524 (84.7%) | 0 (0.0%) |
| C++ | 643 | 194 (30.2%) | 1 (0.2%) | 2 (0.3%) | 446 (69.4%) | 0 (0.0%) |
| C# | 569 | 223 (39.2%) | 0 (0.0%) | 0 (0.0%) | 346 (60.8%) | 0 (0.0%) |
| Go | 353 | 99 (28.0%) | 0 (0.0%) | 0 (0.0%) | 254 (72.0%) | 0 (0.0%) |
| Java | 1,385 | 667 (48.2%) | 570 (41.2%) | 0 (0.0%) | 148 (10.7%) | 0 (0.0%) |
| JavaScript | 172 | 56 (32.6%) | 1 (0.6%) | 0 (0.0%) | 115 (66.9%) | 0 (0.0%) |
| Kotlin | 238 | 161 (67.6%) | 34 (14.3%) | 2 (0.8%) | 41 (17.2%) | 0 (0.0%) |
| Lua | 734 | 81 (11.0%) | 96 (13.1%) | 0 (0.0%) | 557 (75.9%) | 0 (0.0%) |
| PHP | 489 | 173 (35.4%) | 48 (9.8%) | 0 (0.0%) | 268 (54.8%) | 0 (0.0%) |
| Python | 965 | 228 (23.6%) | 0 (0.0%) | 0 (0.0%) | 737 (76.4%) | 0 (0.0%) |
| Ruby | 6,185 | 694 (11.2%) | 767 (12.4%) | 0 (0.0%) | 4,724 (76.4%) | 0 (0.0%) |
| Rust | 3,167 | 664 (21.0%) | 38 (1.2%) | 0 (0.0%) | 2,465 (77.8%) | 0 (0.0%) |
| Swift | 301 | 34 (11.3%) | 3 (1.0%) | 0 (0.0%) | 264 (87.7%) | 0 (0.0%) |
| TypeScript | 229 | 57 (24.9%) | 49 (21.4%) | 0 (0.0%) | 123 (53.7%) | 0 (0.0%) |
| Zig | 1,387 | 314 (22.6%) | 5 (0.4%) | 0 (0.0%) | 1,068 (77.0%) | 0 (0.0%) |

### Measurement basis

The current semantic-index path was included where a reproducible index was
available:

- Java: Commons CLI, JavaPoet, and RTree using `scip-java`;
- C++: eventpp, plog, and proxy using the current C++ SCIP profiles;
- Kotlin: Picnic and kotlinx-benchmark using `scip-java`/Kotlin;
- Lua: LuaRocks using FactMine's LuaLS-to-SCIP producer;
- PHP: FastRoute and UUID using `scip-php`;
- Ruby: all 192 indexed files under `compiler/ruby` using `scip-ruby`;
- TypeScript: tsup and tsyringe using `scip-typescript`.

The C, C#, Go, JavaScript, and Python rows use the pinned mini-repository
profiles without their later compiler-index artifacts. They are conservative
syntax-only lower bounds, not ceilings for current SCIP ingestion. The Rust row
uses FactMine's 83 non-test Rust source files without a current rust-analyzer
index. The Zig row uses the fixed 32-file production import closure without
promoting the ZLS feasibility results to trusted targets. Swift uses
swift-argument-parser and swift-tagged without a trustworthy standard SCIP
producer. These lower-bound rows should be remeasured when reproducible indexes
are checked into or generated by the quality harness.

## How to interpret the table

The strongest single number is `Analyzer-proven`. Adding `Trusted /
conditional` gives the usable modeled-world rate, provided the consumer accepts
every recorded assumption. Adding `Closed-set maximum` gives the conservative
closed-world upper-bound rate.

For example:

- Java is 48.2% assumption-free and 89.3% usable with explicit models and
  conditions. The difference is real value, but it must remain visibly
  qualified.
- Kotlin is 67.6% assumption-free and 82.8% usable after trusted and closed-set
  bounds.
- Lua is 11.0% assumption-free and 24.1% usable. LuaLS substantially improves
  identity, but unresolved receiver/table shape and incomplete callees still
  prevent function-level closure.
- Ruby's 23.6% usable result is measured across a much larger, highly
  interconnected compiler corpus than the two- or three-repository samples;
  it should not be compared as though corpus difficulty were equal.

A high call-accounting percentage can coexist with low analyzer-proven Big-O.
Semantic indexing may identify nearly every call while a small number of
unmodeled interfaces, callbacks, recursive SCCs, or incomplete leaf functions
propagate uncertainty through many callers.

## Accuracy contract

- The table classifies time completeness. Space has its own
  `big_o_space_complete` bit and must be checked independently; the measured
  comparison profiles had matching time/space completeness counts. Neither
  result predicts wall-clock latency.
- Manual registry entries must be reviewed upper bounds tied to the operation
  identity. Placeholder costs are never quality evidence.
- Parametric results retain callback time `C` and space `S`; they do not assume
  callbacks are constant.
- Closed candidate sets take the maximum candidate cost and retain the
  possibly-overstated qualification.
- Open interfaces, reflection, FFI, runtime dependency injection, and dynamic
  callbacks remain unknown unless the analysis proves a closed domain or emits
  an explicit symbolic term.
- Resolving a target can correctly turn a formerly known result into unknown by
  exposing an incomplete callee. Quality is proof correctness, not monotonic
  percentage growth.

## Reproducing the report

Generate an Espalier profile, optionally with one or more semantic indexes:

```bash
gems/fact-mine/target/release/fact-mine-rust \
  profile espalier \
  --language LANGUAGE \
  --scip-index index.scip \
  --output profile.json \
  SOURCE_FILES...
```

Then classify the emitted function results:

```bash
gems/espalier/script/report_big_o_proof_metrics.rb \
  --source-root /path/to/corpus \
  --json \
  profile.json
```

The reporter and this document use the same language-neutral proof classifier.
New confidence states belong in that classifier and its tests, not in
language-specific adapters.

To measure the compiler index itself, generate the same FactMine profile once
without and once with `--scip-index`, then run:

```bash
gems/espalier/script/compare_scip_big_o.rb \
  --source-root /path/to/corpus \
  --repository project \
  source-only.json indexed.json
```

The comparison uses production files only, reports exact proof buckets and call
resolution counts, and preserves executable raw-call normalization gaps. Use
`check_big_o_coverage.rb` for the enforcing 85% gate.

Current indexed smoke corpora are pinned by source commit and indexer version:

| Language | Corpus commit | Indexer | Production complete, source → SCIP | Exact project targets, source → SCIP |
| --- | --- | --- | ---: | ---: |
| Java | Apache Commons CLI `afb0fd148517b1bf8316ebbc44ec9ec8b201452a` | scip-java 0.12.3 | 271/524 (51.72%) → 330/524 (62.98%) | 557 → 784 |
| C | cJSON `fb16e5cf358798aabb049655975cde8427101056` | scip-clang 0.4.0 | 29/116 (25.00%) → 29/116 (25.00%) | 188 → 188 |

The cJSON index still contributes 323 compiler-proven call symbols. Its flat
function coverage is therefore a useful regression: identity ingestion works,
while the remaining C header, macro, builtin, and external-cost layer is
measured separately instead of being credited as complete.

### Reusing analyzed dependency and standard-library bodies

Analyze a pinned source release with its SCIP index, then export only complete
time-and-space results under the exact declaration symbols:

```bash
gems/fact-mine/target/release/fact-mine-rust \
  profile espalier \
  --language go \
  --scip-index go-stdlib.scip \
  --output go-stdlib.profile.json \
  GO_STDLIB_SOURCE_FILES...

gems/espalier/script/export_complexity_summary.rb \
  --corpus go-stdlib \
  --source-revision go1.25.0 \
  --indexer scip-go@0.1.18 \
  go-stdlib.profile.json go-stdlib.go1.25.0.json.gz
```

The v2 summary records the SHA-256 of the complete input profile, producer
version, source release, indexer version, language set, and exported symbol
count. Gzip output has a zero timestamp, so rebuilding identical inputs is
byte-for-byte reproducible. Apply it to user code alongside that code's index:

```bash
gems/espalier/exe/espalier \
  --scip-index user-code.scip \
  --complexity-summary go-stdlib.go1.25.0.json.gz \
  --format json \
  USER_SOURCE_FILES...
```

Summary joins require the exact compiler symbol already attached by SCIP. They
never guess from an owner or method name. Unknown schema versions, malformed
metadata, empty bounds, and contradictory files fail closed. The v1 reader
remains available for previously generated artifacts, but new exports are v2.
