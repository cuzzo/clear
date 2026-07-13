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
| Go | `https://github.com/junegunn/fzf` | `/tmp/lineage-one-line-repos/fzf` | `/tmp/lineage-one-line-repos/fzf/lineage.db` | `18103` | Complete, partial Go coverage |
| Lua | `https://github.com/luarocks/luarocks` | `/tmp/lineage-one-line-repos/luarocks` | `/tmp/lineage-one-line-repos/luarocks/lineage.db` | `18104` | Complete, no coverage artifact |
| C | `https://github.com/libuv/libuv` | `/tmp/lineage-one-line-repos/libuv` | `/tmp/lineage-one-line-repos/libuv/lineage.db` | `18105` | Complete, no coverage artifact |
| C++ | `https://github.com/fmtlib/fmt` | `/tmp/lineage-one-line-repos/fmt` | `/tmp/lineage-one-line-repos/fmt/lineage.db` | `18106` | Complete, no coverage artifact |
| C# | `https://github.com/serilog/serilog` | `/tmp/lineage-one-line-repos/serilog` | `/tmp/lineage-one-line-repos/serilog/lineage.db` | `18107` | Complete, no coverage artifact |
| Java | `https://github.com/google/gson` | `/tmp/lineage-one-line-repos/gson` | `/tmp/lineage-one-line-repos/gson/lineage.db` | `18108` | Complete, no coverage artifact |
| Swift | `https://github.com/apple/swift-argument-parser` | `/tmp/lineage-one-line-repos/swift-argument-parser` | `/tmp/lineage-one-line-repos/swift-argument-parser/lineage.db` | `18109` | Complete, no coverage artifact |
| Kotlin | `https://github.com/square/okio` | `/tmp/lineage-one-line-repos/okio` | `/tmp/lineage-one-line-repos/okio/lineage.db` | `18110` | Complete, no coverage artifact |

All UI servers were restarted with detached sessions and smoke checked through `curl` on ports `18101` through `18110`.

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
