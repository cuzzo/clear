# Cross-Language Support Validation

This document tracks the first practical validation pass for building Lineage databases from non-CLEAR repositories and ingesting analyzer, lint, coverage, hazard, and runtime evidence.

`gems/lineage/docs/agents/plugins.md` describes the plugin architecture and broad language targets. It does not prescribe exact repositories, so this pass used representative active OSS projects with enough real code to exercise the adapters.

## Goal

Create one `lineage.db` per target repository, ingest the best available evidence, start a Lineage UI server for each on `0.0.0.0`, and spot check that the UI can review the project with cross-language data.

## Standard Import Command

Use the same import wrapper for every checkout. The wrapper builds Lineage and
bundled analyzers, indexes the whole repository, discovers supported coverage
artifacts, ingests hazards, generates and ingests first-party SARIF
(Decomplex, SlopCop, Boobytrap, Nil-Kill, Espalier), generates Go/Rust/Ruby/Zig
lint SARIF where the repository has relevant code, ingests extra SARIF inputs,
refreshes summaries, and can start the UI:

```bash
/home/yahn/litedb/gems/lineage/bin/lineage-import \
  --repo /path/to/repo \
  --db /path/to/repo/lineage.db \
  --out-dir /path/to/repo/tmp/lineage-import \
  --fresh \
  --serve \
  --daemon \
  --host 0.0.0.0 \
  --port 8081
```

For faster adapter smoke checks, add `--max-commits 100`. For imported CI
artifacts, repeat `--coverage path/to/artifact` or `--sarif-input path/to/dir`.

## Validation Matrix

| Language | Repository | Local Clone | Database | UI Port | Status |
| --- | --- | --- | --- | --- | --- |
| Python | `https://github.com/Textualize/rich` | `/tmp/lineage-one-line-repos/rich` | `/tmp/lineage-one-line-repos/rich/lineage.db` | `18101` | Complete |
| TypeScript | `https://github.com/colinhacks/zod` | `/tmp/lineage-one-line-repos/zod` | `/tmp/lineage-one-line-repos/zod/lineage.db` | `18102` | Complete |
| JavaScript | `https://github.com/fastify/fastify` | `/tmp/fastify` | `/tmp/fastify/lineage.db` | `18111` | Added for analyzer validation |
| Go | `https://github.com/junegunn/fzf` | `/tmp/lineage-one-line-repos/fzf` | `/tmp/lineage-one-line-repos/fzf/lineage.db` | `18103` | Complete, partial Go coverage |
| Lua | `https://github.com/luarocks/luarocks` | `/tmp/lineage-one-line-repos/luarocks` | `/tmp/lineage-one-line-repos/luarocks/lineage.db` | `18104` | Complete, no coverage artifact |
| C | `https://github.com/libuv/libuv` | `/tmp/lineage-one-line-repos/libuv` | `/tmp/lineage-one-line-repos/libuv/lineage.db` | `18105` | Complete, no coverage artifact |
| C++ | `https://github.com/fmtlib/fmt` | `/tmp/lineage-one-line-repos/fmt` | `/tmp/lineage-one-line-repos/fmt/lineage.db` | `18106` | Complete, no coverage artifact |
| C# | `https://github.com/serilog/serilog` | `/tmp/lineage-one-line-repos/serilog` | `/tmp/lineage-one-line-repos/serilog/lineage.db` | `18107` | Complete, no coverage artifact |
| Java | `https://github.com/google/gson` | `/tmp/lineage-one-line-repos/gson` | `/tmp/lineage-one-line-repos/gson/lineage.db` | `18108` | Complete, no coverage artifact |
| Swift | `https://github.com/apple/swift-argument-parser` | `/tmp/lineage-one-line-repos/swift-argument-parser` | `/tmp/lineage-one-line-repos/swift-argument-parser/lineage.db` | `18109` | Complete, no coverage artifact |
| Kotlin | `https://github.com/square/okio` | `/tmp/lineage-one-line-repos/okio` | `/tmp/lineage-one-line-repos/okio/lineage.db` | `18110` | Complete, no coverage artifact |

All UI servers were restarted with detached sessions and smoke checked through `curl` on ports `18101` through `18110`.

## Mini-Corpus: Bounded Manual-Review Validation

The validation matrix above answers a different question from analyzer quality:
can Lineage ingest a large, realistic repository?  It cannot cheaply establish
whether a high-ranked finding is true, whether an important function was
missed, or which adapter is responsible when either happens.  Large projects
also combine too many unrelated language features to make a regression
actionable.

This companion corpus is intentionally small.  Every candidate has **3,000 to
5,000 production source lines** in the language under test, excluding tests,
examples, documentation, generated output, build directories, and vendored
dependencies.  That is small enough to establish a ground-truth ledger for
its real hotspots, while still containing several independent modules and
nontrivial state/control/data-flow.

This is a validation corpus, not a benchmark leaderboard.  A tool finding
little in a repository is not a success by itself: reviewers must also inspect
the deliberately chosen challenge surfaces below and record missed findings.

Current exact-target and unresolved-call measurements for this corpus are
recorded in [`call-resolution-mini-corpus.md`](call-resolution-mini-corpus.md).

### Sizing and Snapshot Rule

Counts below were measured on 2026-07-15 from shallow checkouts with:

```bash
cloc --json --quiet \
  --exclude-dir=.git,node_modules,vendor,third_party,dist,build,target,bin,obj,coverage,examples,docs,test,tests,spec,specs \
  REPOSITORY
```

The number is the `code` count for the target language.  For C++, it is the
sum of `C++` and `C/C++ Header`: header-only template code is production code,
not documentation.  The command deliberately does not count test code toward
the size budget, but tests remain essential manual evidence when validating a
finding.  Pin the listed revision for an evaluation run; re-measure on update,
and replace a project rather than silently allowing the corpus to drift outside
the 3–5k window.

### Priority and Review Order

Prioritize the corpus by common OSS application surface and expected analyzer
value, not by which adapter is easiest to make green:

1. Python, TypeScript, JavaScript, and Go: broadest current OSS/app use and
   the widest combination of dynamic shapes, async code, and collection state.
2. Java and C#: common typed-server ecosystems with generics, builders,
   reflection, nullability, and asynchronous APIs.
3. C++ and C: lower repository count in general OSS, but high value for parser,
   ownership, callback, preprocessor, and resource-lifetime correctness.

Within each repository, run Nil-Kill (static), Espalier, and Decomplex over
production source only first.  Then manually inspect the top findings and a
small set of known difficult functions which received no finding.  This avoids
letting test fixtures or generated code hide either false positives or false
negatives.

### Selected Repositories

The selection intentionally differs by *shape*, not merely by domain.  It
covers parsers, plugin/DI dispatch, recursive structures, mutable state
machines, generated/dynamic code, resource failure paths, generics/templates,
and concurrent work queues.  Those are the places where cross-language
analyzers most often make plausible but incorrect claims.

| Language | Repository (pinned revision) | Production LoC | Why it belongs in the corpus / mandatory manual audit |
| --- | --- | ---: | --- |
| Python | [`psf/requests`](https://github.com/psf/requests) `f361ead047be` | 3,611 | HTTP sessions, adapters, redirects, cookies, and exception paths. Verify that response/session state is neither merged across owners nor reported dead after mutation. |
| Python | [`lepture/mistune`](https://github.com/lepture/mistune) `060f73ac87e8` | 4,511 | Nested token parsing and renderer dispatch. Audit recursive/iterative parser costs and callback/data-flow attribution. |
| Python | [`pydantic/pydantic-settings`](https://github.com/pydantic/pydantic-settings) `5c702e535b08` | 4,335 | Typed configuration plus dynamic environment/CLI/secret sources. Stress Nil-Kill's precision around optional settings, aliases, and source-precedence state. |
| Python | [`pytest-dev/pluggy`](https://github.com/pytest-dev/pluggy) `c1a5f3ea743c` | 3,656 | Plugin registration, hook wrappers, and indirect dispatch. Verify callback/escape identity and ensure dynamic hooks do not become false architecture claims. |
| TypeScript | [`microsoft/tsyringe`](https://github.com/microsoft/tsyringe) `e033769d97cf` | 3,014 | Generic dependency-injection tokens, registries, lifetimes, and delayed resolution. Stress type-flow, state identity, and graph/cycle attribution. |
| TypeScript | [`egoist/tsup`](https://github.com/egoist/tsup) `b6bcae8504d0` | 3,246 | Build configuration, plugins, subprocesses, and asynchronous orchestration. Audit closure/module ownership and interprocedural complexity under Node-style async control flow. |
| JavaScript | [`fastify/fast-json-stringify`](https://github.com/fastify/fast-json-stringify) `6aa2ed4cc403` | 3,240 | Schema traversal and generated serializer code. Verify schema-walk complexity without analyzing generated strings as ordinary source or losing dynamic object-shape facts. |
| JavaScript | [`pinojs/pino`](https://github.com/pinojs/pino) `98d8fa4d95f1` | 3,681 | Logger children, serializers, transports, streams, and error paths. Audit owner-relative state and asynchronous/back-pressure control flow. |
| C | [`DaveGamble/cJSON`](https://github.com/DaveGamble/cJSON) `fb16e5cf3587` | 4,097 | Recursive JSON parser/printer with custom allocation, `realloc`, and failure cleanup. A direct resource-lifetime, invalidation, and recursive-complexity oracle. |
| C | [`orangeduck/mpc`](https://github.com/orangeduck/mpc) `1049534fc56b` | 3,071 | Parser combinators, recursive grammars, callbacks, and AST ownership. Check that combinator composition is not collapsed into false fixed-size or false-product complexity. |
| C | [`wg/wrk`](https://github.com/wg/wrk) `a211dd5a7050` | 4,049 | Event-loop callbacks, connection state, threading, and global configuration. Stress callback targets, shared-state identity, and systems-style control flow. |
| C++ | [`microsoft/proxy`](https://github.com/microsoft/proxy) `dc3d95c763ec` | 3,649 | Type erasure, concepts/templates, and RAII. Verify syntax extraction never creates pseudo-functions or attributes template members to the wrong owner. |
| C++ | [`SergiusTheBest/plog`](https://github.com/SergiusTheBest/plog) `6bee2eaa3b82` | 3,333 | Macro-heavy logging, singleton configuration, virtual interfaces, and platform conditionals. Audit macro/preprocessor boundaries and global-versus-instance state identity. |
| C++ | [`wqking/eventpp`](https://github.com/wqking/eventpp) `1224dd6c9bd4` | 4,053 | Header-only callback/event policies, templates, and optional threading. Stress listener escape/fan-out and ensure policy types do not contaminate one another's state. |
| C# | [`ardalis/SmartEnum`](https://github.com/ardalis/SmartEnum) `9bc3f7a43055` | 3,697 | Static enum instances, generic conversion, nullable APIs, and lookup state. Verify property/backing-field identities and static state are modeled safely. |
| C# | [`Fody/Costura`](https://github.com/Fody/Costura) `55874fe54f66` | 3,832 | Build-time weaving, resource streams, assembly resolution, and rewriting. A high-value test of source-role filtering, reflection-like paths, and resource cleanup. |
| C# | [`richardszalay/mockhttp`](https://github.com/richardszalay/mockhttp) `cfbc8266df93` | 3,237 | Fluent request matchers, expectation collections, asynchronous responses, and exceptions. Audit collection mutation/overwrite and nullable/async flow precision. |
| Java | [`apache/commons-cli`](https://github.com/apache/commons-cli) `8d56926d951f` | 3,708 | Stateful option parsing with mutable configuration and token scanning. Check parser loop bounds, builder state, and generic API attribution. |
| Java | [`davidmoten/rtree`](https://github.com/davidmoten/rtree) `364c739f2987` | 4,739 | Recursive spatial-tree insertion/search and persistent/functional paths. A direct oracle for nested traversal complexity, structural sharing, and space facts. |
| Java | [`square/javapoet`](https://github.com/square/javapoet) `b9017a9503b7` | 3,622 | Builder-heavy source generation, type graphs, and recursive rendering. Verify ownership of builder state and avoid mistaking generated text for source control flow. |
| Go | [`panjf2000/ants`](https://github.com/panjf2000/ants) `107e37678122` | 3,462 | Worker-pool goroutine lifecycle, queues, locks, and capacity transitions. Primary concurrency/hazard and synchronization audit target. |
| Go | [`hashicorp/go-immutable-radix`](https://github.com/hashicorp/go-immutable-radix) `65dce5bf5254` | 3,007 | Persistent radix tree and structural sharing. Verify alias/escape reasoning and recursive time/space complexity without treating immutable nodes as mutable global state. |
| Go | [`mitchellh/mapstructure`](https://github.com/mitchellh/mapstructure) `8508981c8b6c` | 4,982 | Reflection-based map/slice/pointer decoding and overwrite behavior. Stress map facts, typed/untyped aliases, and decoder error paths. |
| Go | [`golang-jwt/jwt`](https://github.com/golang-jwt/jwt) `1a11d3724e63` | 4,752 | Token parsing, claim maps, validation, and error propagation. Check interface/map identity, validation-state paths, and parser complexity. |

All selected projects have permissive licenses suitable for an external
validation corpus: MIT, Apache-2.0, BSD-3-Clause, MPL-2.0, or the repository's
BSD/modified-Apache notice.  The corpus only clones and analyzes them; it does
not vendor their sources.  `mpc` carries a BSD notice and `wrk` carries its
own modified-Apache notice, so keep those notices with any archived snapshots.

### Per-Repository Ground-Truth Protocol

For each pinned checkout:

1. Run all three analyzers on production paths only and preserve their JSON and
   SARIF output in an evaluation artifact.
2. Independently identify the three most complex/stateful functions before
   looking at rankings.  At least one must be a negative control: a function
   that *looks* suspicious but has a bounded/immutable explanation.
3. Review the top ten ranked functions/findings from each analyzer and label
   each as true positive, useful-but-low-confidence, false positive, or
   insufficient evidence.  A false positive must name the missing fact or
   mistaken identity, not merely say that the result feels noisy.
4. Compare the independent hotspot list with the ranked list.  Record every
   missed high-value case and whether the gap is shared CFG/DFG/complexity
   logic, a language adapter gap, or intentionally unsupported semantics.
5. Promote every discovered general defect to a minimal cross-language fixture
   (or to `fact-mine/syntax/adapter` when it is genuinely language-specific),
   then rerun the whole mini-corpus before claiming a fix.

The success criterion is not a finding count.  It is a compact, reviewable
ledger that can demonstrate both correct signal and known blind spots for each
language, and turn every repeatable blind spot into a regression.

## Evidence Targets

Each repository received as much of this evidence as the current tools could produce without repository-specific hacks:

- `lineage build`: Git history, logical units, churn, and ownership.
- Decomplex SARIF: structural complexity findings.
- SlopCop SARIF: coverage gaps and constraint findings.
- Boobytrap SARIF: bug-risk findings derived from churn, complexity, and coverage.
- Nil-kill SARIF: optionality, union, hidden enum, and primitive pressure findings where the language adapter supports them.
- Espalier SARIF: architectural pressure findings where the language adapter supports them.
- Lint SARIF: native lint output converted or emitted as SARIF where the repository already had a reasonable local toolchain.
- Coverage: native coverage output ingested through Lineage-supported formats when the toolchain was available.
- Runtime traces: Sentry-style stack trace ingestion for Python smoke coverage.
- Hazards: Go concurrency hazards for `fzf`.

## Current Counts

| Language | Logical Units | SARIF Artifacts | SARIF Findings | Coverage Line Events | Hazards | Covered Hazards | UI Port |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Python / Rich | 2,097 | 9 | 4,772 | 0 | 0 | 0 | 18101 |
| TypeScript / Zod | 2,308 | 9 | 6,508 | 0 | 0 | 0 | 18102 |
| Go / fzf | 1,541 | 9 | 9,937 | 16,734 | 387 | 73 | 18103 |
| Lua / LuaRocks | 366 | 9 | 6,004 | 0 | 0 | 0 | 18104 |
| C / libuv | 2,731 | 9 | 14,401 | 0 | 7,995 | 0 | 18105 |
| C++ / fmt | 308 | 9 | 3,813 | 0 | 993 | 0 | 18106 |
| C# / Serilog | 1,243 | 9 | 2,174 | 0 | 28 | 0 | 18107 |
| Java / Gson | 4,132 | 9 | 4,836 | 0 | 0 | 0 | 18108 |
| Swift / Argument Parser | 1,249 | 9 | 3,213 | 0 | 0 | 0 | 18109 |
| Kotlin / Okio | 4,335 | 9 | 3,794 | 0 | 0 | 0 | 18110 |

`fzf` was rerun after `go test ./... -coverprofile=coverage.out` to verify
partial Go coverage ingestion and covered hazard counts. The other fresh clones
did not contain coverage artifacts, so their coverage counts are zero unless a
CI/test artifact is passed with `--coverage`.

## Adapter Work Completed

- Replaced generic language placeholders with explicit Decomplex lexicons for Lua, C, C++, C#, Java, Swift, and Kotlin.
- Added real Tree-sitter syntax support and tests for C, C++, C#, Java, Swift, and Kotlin structural facts.
- Added Swift member access and `switch_entry` support.
- Added Kotlin `when_expression` and `when_entry` support.
- Added grammar candidate support for packages that ship `tree_sitter_*_binding.node`, needed by `tree-sitter-kotlin`.
- Added Go concurrency hazard detection through SlopCop/Lineage.
- Fixed Lineage source extraction and coverage ingestion issues found during TypeScript/Go validation.
- Fixed Nil-kill static-only normalization so non-Ruby languages do not accidentally depend on stale runtime traces.
- Replaced Lineage regex-first logical-unit extraction for Ruby, Python, JavaScript/TypeScript, Go, Rust, Zig, C/C++, and C# with Tree-sitter-backed extraction. The regex heuristic path is now only for secondary experimental languages.

## Environment Gaps

- Lua coverage/lint was limited by missing local LuaRocks/Busted tooling.
- C and C++ coverage was not generated in this pass; static analyzer, SARIF ingestion, and hazard ingestion were validated.
- C#, Java, Swift, and Kotlin native build/lint/coverage were limited by missing `dotnet`, Java, Swift, and Kotlin toolchains in this environment.
- TypeScript and Go runtime tracing are still out of scope for this pass.

These are environment/toolchain gaps, not Lineage ingestion blockers. The DBs and UIs exist for all requested languages.
