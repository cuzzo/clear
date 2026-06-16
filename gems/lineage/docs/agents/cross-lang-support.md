# Cross-Language Support Validation

This document tracks the first practical validation pass for building Lineage databases from non-CLEAR repositories and ingesting analyzer, lint, coverage, hazard, and runtime evidence.

`gems/lineage/docs/agents/plugins.md` describes the plugin architecture and broad language targets. It does not prescribe exact repositories, so this pass used representative active OSS projects with enough real code to exercise the adapters.

## Goal

Create one `lineage.db` per target repository, ingest the best available evidence, start a Lineage UI server for each on `0.0.0.0`, and spot check that the UI can review the project with cross-language data.

## Validation Matrix

| Language | Repository | Local Clone | Database | UI Port | Status |
| --- | --- | --- | --- | --- | --- |
| Python | `https://github.com/Textualize/rich` | `/tmp/lineage-rich` | `/tmp/lineage-rich/lineage.db` | `8081` | Complete |
| TypeScript | `https://github.com/colinhacks/zod` | `/tmp/lineage-zod` | `/tmp/lineage-zod/lineage.db` | `8082` | Complete |
| Go | `https://github.com/junegunn/fzf` | `/tmp/lineage-fzf` | `/tmp/lineage-fzf/lineage.db` | `8083` | Complete |
| Lua | `https://github.com/luarocks/luarocks` | `/tmp/lineage-lua-luarocks` | `/tmp/lineage-lua-luarocks/lineage.db` | `8084` | Complete, no coverage |
| C | `https://github.com/libuv/libuv` | `/tmp/lineage-c-libuv` | `/tmp/lineage-c-libuv/lineage.db` | `8085` | Complete, no coverage |
| C++ | `https://github.com/fmtlib/fmt` | `/tmp/lineage-cpp-fmt` | `/tmp/lineage-cpp-fmt/lineage.db` | `8086` | Complete, no coverage |
| C# | `https://github.com/serilog/serilog` | `/tmp/lineage-csharp-serilog` | `/tmp/lineage-csharp-serilog/lineage.db` | `8087` | Complete, no coverage |
| Java | `https://github.com/google/gson` | `/tmp/lineage-java-gson` | `/tmp/lineage-java-gson/lineage.db` | `8088` | Complete, no coverage |
| Swift | `https://github.com/apple/swift-argument-parser` | `/tmp/lineage-swift-argument-parser` | `/tmp/lineage-swift-argument-parser/lineage.db` | `8089` | Complete, no coverage |
| Kotlin | `https://github.com/square/okio` | `/tmp/lineage-kotlin-okio` | `/tmp/lineage-kotlin-okio/lineage.db` | `8090` | Complete, no coverage |

All UI servers were restarted with detached sessions and smoke checked through `curl` on ports `8081` through `8090`.

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

| Language | Logical Units | SARIF Artifacts | SARIF Findings | Quality Events | Coverage Line Events | Hazards | Runtime Events |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Python / Rich | 2,152 | 6 | 6,270 | 1,022 | 7,792 | 0 | 1 |
| TypeScript / Zod | 2,437 | 6 | 8,112 | 1,365 | 8,908 | 0 | 0 |
| Go / fzf | 1,421 | 7 | 13,316 | 608 | 16,422 | 312 | 0 |
| Lua / LuaRocks | 1,043 | 6 | 5,056 | 0 | 0 | 0 | 0 |
| C / libuv | 3,920 | 6 | 21,895 | 0 | 0 | 0 | 0 |
| C++ / fmt | 6,014 | 6 | 2,982 | 0 | 0 | 0 | 0 |
| C# / Serilog | 615 | 6 | 1,281 | 0 | 0 | 0 | 0 |
| Java / Gson | 4,921 | 6 | 2,624 | 0 | 0 | 0 | 0 |
| Swift / Argument Parser | 1,938 | 6 | 835 | 0 | 0 | 0 | 0 |
| Kotlin / Okio | 3,357 | 6 | 1,900 | 0 | 0 | 0 | 0 |

## Adapter Work Completed

- Replaced generic language placeholders with explicit Decomplex lexicons for Lua, C, C++, C#, Java, Swift, and Kotlin.
- Added real Tree-sitter syntax support and tests for C, C++, C#, Java, Swift, and Kotlin structural facts.
- Added Swift member access and `switch_entry` support.
- Added Kotlin `when_expression` and `when_entry` support.
- Added grammar candidate support for packages that ship `tree_sitter_*_binding.node`, needed by `tree-sitter-kotlin`.
- Added Go concurrency hazard detection through SlopCop/Lineage.
- Fixed Lineage source extraction and coverage ingestion issues found during TypeScript/Go validation.
- Fixed Nil-kill static-only normalization so non-Ruby languages do not accidentally depend on stale runtime traces.

## Environment Gaps

- Lua coverage/lint was limited by missing local LuaRocks/Busted tooling.
- C and C++ coverage was not generated in this pass; static analyzer, syntax lint, and SARIF ingestion were validated.
- C#, Java, Swift, and Kotlin native build/lint/coverage were limited by missing `dotnet`, Java, Swift, and Kotlin toolchains in this environment.
- TypeScript and Go runtime tracing are still out of scope for this pass.

These are environment/toolchain gaps, not Lineage ingestion blockers. The DBs and UIs exist for all requested languages.
