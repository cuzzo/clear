# Multi-Language Support Quality Pass

This pass spot checked the validation DBs created for Python, TypeScript, Go, Lua, C, C++, C#, Java, Swift, and Kotlin. The goal was not to prove feature parity with Ruby, but to verify that Lineage can ingest and display useful SARIF/coverage/risk evidence for each language, and to fix clear cross-language false positives found during review.

## Quality Checklist

- Lineage DB exists and UI serves the repository.
- SARIF artifacts ingest into `sarif_findings` with stable paths and line anchors.
- Decomplex findings include enough detector-specific context to be actionable.
- Nil-kill static pressure findings do not flag obviously typed or non-null constructs as loose contracts.
- SlopCop and Boobytrap produce useful output when coverage/churn exists, and degrade clearly when coverage is absent.
- Espalier emits architecture facts where class/function ownership extraction is mature.
- Native lint SARIF is ingested when the local toolchain can produce it.
- Runtime or hazard evidence is present for languages where support currently exists.

## Fixes From This Pass

- Decomplex SARIF messages now include detector-specific payloads for the major findings. For example, Rich `console.py` now shows `Derived-State Staleness: max_height derived from size at line 995; size reassigned at line 996 but max_height is not recomputed` instead of only naming the method.
- Decomplex suppresses generated Lua/Teal `_tl_compat` compatibility prelude branches. LuaRocks no longer reports line-1 generated prelude missing-abstraction findings.
- Decomplex extracts Go `name type` struct field declarations, so fields like `I16 []int16` keep their type.
- Nil-kill no longer treats Python `-> None` as nullable pressure by itself. `str | None`, `None | str`, `Optional[...]`, `null`, and `undefined` still count.
- Nil-kill Go static evidence now preserves typed struct fields through to SARIF; fzf no longer reports `Slab#I16` as an untyped field.

Regression tests added:

- `gems/decomplex/test/syntax_test.rb`: Lua generated prelude suppression and Go name-type struct fields.
- `gems/decomplex/test/report_test.rb`: actionable SARIF messages for derived-state staleness and broken protocols.
- `gems/nil-kill/spec/multi_language_runtime_spec.rb`: Python `-> None` nullable handling and Go typed struct field evidence.

## Current Validation DBs

All UI servers responded with HTTP 200 on ports `8081` through `8090` after SARIF reingest and UI summary refresh.

| Language | Repo | Port | Logical Units | SARIF Artifacts | SARIF Findings | Coverage Lines | Quality Events |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Python | Rich | 8081 | 2,152 | 6 | 6,905 | 7,792 | 1,022 |
| TypeScript | Zod | 8082 | 2,437 | 6 | 8,246 | 8,908 | 1,365 |
| Go | fzf | 8083 | 1,421 | 7 | 13,219 | 16,422 | 608 |
| Lua | LuaRocks | 8084 | 1,043 | 6 | 5,731 | 0 | 0 |
| C | libuv | 8085 | 3,920 | 6 | 30,310 | 0 | 0 |
| C++ | fmt | 8086 | 6,014 | 6 | 5,120 | 0 | 0 |
| C# | Serilog | 8087 | 615 | 6 | 1,524 | 0 | 0 |
| Java | Gson | 8088 | 4,921 | 6 | 3,542 | 0 | 0 |
| Swift | Argument Parser | 8089 | 1,938 | 6 | 1,129 | 0 | 0 |
| Kotlin | Okio | 8090 | 3,357 | 6 | 2,243 | 0 | 0 |

Swift and Kotlin SARIF reingest skipped two non-SARIF JSON evidence files in each `tmp/lineage-sarif` directory. That is expected because the ingest command accepts directories and ignores JSON files that are not SARIF documents.

## Language Findings

### Python / Rich

Status: good.

The strongest path is covered: Lineage DB, Decomplex, Nil-kill, Espalier, SlopCop, Boobytrap, native lint, coverage, quality events, and one runtime stack-trace smoke event all ingest. Rich is the best multi-language validation target after CLEAR Ruby because it has meaningful Python type annotations and coverage.

Spot checks:

- Decomplex state-branch and derived-state findings now include state refs, predicates, and stale variable/source details.
- Nil-kill nullable signatures now avoid false positives for plain `-> None`, while still flagging real nullable params/returns.
- SlopCop and Boobytrap findings are anchored to real coverage/churn data.
- Native lint SARIF from Black is visible and path-anchored.

Remaining caveat: test/example files are included in the validation DB. That is useful for ingestion coverage, but production review should use source-role filtering in Lineage.

### TypeScript / Zod

Status: good, with test-file noise.

TypeScript SARIF ingestion, coverage, Decomplex, Nil-kill, Espalier, SlopCop, and Boobytrap all produce anchored findings. Decomplex points at real large schema/parser functions and TypeScript annotations feed Nil-kill static pressure.

Spot checks:

- Decomplex state-branch density on Zod parser paths includes concrete `_def`/schema refs and predicates.
- Nil-kill flags `unknown`/`any`-style slots without requiring runtime tracing.
- SlopCop and Boobytrap coverage/churn rows ingest correctly.

Remaining caveat: broken-protocol and Boobytrap rows in test suites are noisy. This is mostly a source-role/ranking issue, not a TypeScript parser failure.

### Go / fzf

Status: good.

Go has the best non-Ruby systems-language story in this pass. Lineage ingests coverage, SlopCop coverage gaps, Boobytrap risk, Decomplex, Nil-kill static facts, and Go concurrency hazard SARIF.

Spot checks:

- SlopCop Go constraint SARIF flags channel and lock/sync hazards lacking race coverage.
- Decomplex identifies large terminal/control-flow functions with convergence across several detectors.
- Nil-kill now preserves typed struct fields such as `Slab.I16 []int16`, removing a concrete false positive.

Remaining caveat: Go hazard support is currently concurrency-focused. Other safety categories need explicit language rules if we want broader Go systems checks.

### Lua / LuaRocks

Status: usable static ingestion, experimental analysis quality.

Lineage DB and SARIF ingestion work. Decomplex produces useful Lua findings after generated Teal prelude suppression. Nil-kill and Espalier are sparse, which matches the current maturity of Lua ownership/type extraction.

Spot checks:

- Generated `_tl_compat` prelude line-1 missing-abstraction findings are gone.
- Real Lua findings remain, e.g. repeated guard tuples and state-branch predicates.
- SlopCop/Boobytrap rows exist but are static/no-coverage quality because no Lua coverage was available.

Remaining caveat: Lua needs better function ownership and module/type conventions before Espalier and Nil-kill can be more than light static signals.

### C / libuv

Status: strong SARIF ingestion, experimental analysis quality.

Lineage handles the large libuv DB and ingests Decomplex, SlopCop, Boobytrap, Nil-kill, Espalier, and syntax-lint SARIF. Decomplex results are plentiful and anchored.

Spot checks:

- Decomplex state-branch density points at real C state/predicate-heavy files like `src/win/pipe.c`.
- SlopCop/Boobytrap can rank paths, but no coverage was generated in this environment.
- Native syntax lint catches environment/header availability issues. Those are useful as toolchain diagnostics, not code-quality verdicts.

Remaining caveat: C has no coverage here, and C header/platform conditionals create noisy lint results unless the native build environment is configured.

### C++ / fmt

Status: strong SARIF ingestion, experimental analysis quality.

Lineage ingests fmt SARIF and the UI handles template-heavy headers. Decomplex and Nil-kill produce anchored findings; Espalier has limited but nonzero ownership extraction.

Spot checks:

- Decomplex findings are anchored in headers and bundled tests.
- Nil-kill nullable findings around pointer/time APIs are plausible.
- Native C++ syntax lint found module/toolchain issues.

Remaining caveat: bundled third-party/test code is included, so production review needs source-role filtering. C++ templates and macros need more language-specific tuning before high confidence architecture claims.

### C# / Serilog

Status: usable static ingestion, moderate Decomplex signal.

SARIF ingestion works and Decomplex points at real branch-heavy formatting/parsing code. Nil-kill nullable signature findings map well to C# nullable-style APIs.

Spot checks:

- Decomplex state-branch findings include concrete property names and predicates.
- Nil-kill nullable signature findings are plausible in Serilog configuration APIs.
- SlopCop/Boobytrap are static/no-coverage quality because coverage was unavailable.

Remaining caveat: Espalier emitted no findings in this validation pass, so C# architecture extraction needs more work before it can be relied on.

### Java / Gson

Status: usable static ingestion, moderate Decomplex/Espalier signal.

Java SARIF ingestion works. Decomplex, Nil-kill, Espalier, SlopCop, and Boobytrap all produce anchored findings, with Decomplex pointing at real parser/adapter complexity.

Spot checks:

- Decomplex state-branch density in `TypeAdapters` and `JsonReader` has meaningful refs/predicates.
- Espalier emits read-only function facts for immutable-style value methods.
- Nil-kill untyped fields/methods are plausible where generic/reflection-heavy Java code defeats simple extraction.

Remaining caveat: no Java coverage or native lint was available in this environment, so risk ranking lacks coverage-backed confidence.

### Swift / Argument Parser

Status: usable static ingestion, experimental analysis quality.

Lineage DB and SARIF ingestion work. Decomplex and Espalier produce anchored Swift findings; Nil-kill static evidence ingests. SlopCop is empty because no coverage was generated.

Spot checks:

- Decomplex state-branch density in completion generation includes Swift option/subcommand predicates.
- Espalier has limited read-only function extraction.
- Nil-kill static untyped signatures are present where generic Swift inference is not yet mature.

Remaining caveat: Swift needs coverage ingestion and better function/owner extraction before architecture metrics should be treated as strong signal.

### Kotlin / Okio

Status: usable static ingestion, moderate Decomplex signal.

Kotlin DB and SARIF ingestion work. Decomplex has useful findings in buffer/filesystem code, and Espalier emits a small set of function facts. Nil-kill static findings are anchored.

Spot checks:

- Decomplex state-branch density in `Buffer.kt` includes concrete buffer/segment refs and predicates.
- Espalier identifies some read-only/impure functions.
- Nil-kill untyped signatures point at equality/select APIs where extraction needs stronger Kotlin typing rules.

Remaining caveat: no coverage was generated, SlopCop is empty, and Kotlin parser extraction needs more language-specific tuning before architecture metrics are high confidence.

## Cross-Cutting Assessment

The common ingestion path is solid: all ten DBs load, SARIF artifacts persist, UI summaries refresh, and servers respond. Decomplex is the most broadly useful analyzer across all languages because Tree-sitter extraction gives it enough syntax to anchor complexity findings.

The biggest quality divider is coverage. Python, TypeScript, and Go have coverage-backed SlopCop/Boobytrap signal; the other seven languages currently have static-only or churn-only risk, which should be presented as lower confidence.

Nil-kill is useful for Python, TypeScript, Go, C#, Java, Swift, and Kotlin static pressure, but language-specific type extraction determines signal quality. The Go struct-field and Python `-> None` fixes show the right pattern: false positives should be fixed in the shared syntax/provider layer with regression tests, not tuned per repository.

Espalier is useful where class/function ownership extraction is mature. It is sparse for Lua, C, C#, and Swift/Kotlin compared with Ruby/TypeScript/Go/Java. Treat missing Espalier signal in those languages as adapter immaturity, not proof of good architecture.

## Recommended Next Work

- Add source-role filtering in Lineage views and ranking so `src`/production findings can be reviewed separately from tests, examples, vendored code, and generated code.
- Add explicit generated/vendor detection to the shared source filter for common language artifacts.
- Improve C/C++ native build-aware lint/coverage collection; static parser output alone is not enough for high-confidence systems-language review.
- Add coverage ingestion recipes for Lua, C#, Java, Swift, and Kotlin validation repos.
- Continue adding language-specific ownership/type extraction only when a spot check finds a concrete false positive or missing high-value signal.
