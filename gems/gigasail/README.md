# Gigasail

Gigasail is a Rust history and evidence engine for reviewing code at
scale. It tracks logical code units across renames, moves, and
refactors, then overlays verification evidence such as coverage,
mutation results, systems hazards, and stack traces.

It is used by the CLEAR compiler and runtime to review LLM-assisted
code with enough context to know which lines are risky, stale,
undertested, or historically bug-prone.

- See [Plugin Notes](docs/agents/plugins.md) for the provider adapter
  boundary and future plugin architecture.
- See [Coverage History](docs/agents/coverage-history.md) for how
  coverage and test exposure evidence are modeled.

## Getting Started

If you want to contribute, see [CONTRIBUTING.md](CONTRIBUTING.md).

### Prerequisites

- Rust and Cargo
- A git repository
- Optional coverage, mutation, hazard, lint, SARIF, or stack-trace artifacts

For a fully populated local database from a repo checkout, use the import
wrapper. It builds the required Gigasail/analyzer binaries, builds the
Gigasail database, discovers supported coverage artifacts, runs bundled
hazard providers, generates first-party SARIF, runs available Go/Rust/Ruby/Zig
lints, ingests extra SARIF inputs, refreshes UI summaries, and can start the
UI server:

```bash
gems/gigasail/bin/gigasail-import \
  --repo . \
  --db gigasail.db \
  --out-dir tmp/gigasail-import \
  --fresh \
  --serve \
  --daemon \
  --host 0.0.0.0 \
  --port 8080
```

Useful iteration flags:

```bash
gems/gigasail/bin/gigasail-import --repo . --db tmp/gigasail.db --fresh --max-commits 100
gems/gigasail/bin/gigasail-import --repo . --db tmp/gigasail.db --fresh --no-coverage --no-lints
gems/gigasail/bin/gigasail-import --repo . --db tmp/gigasail.db --sarif-input tmp/vendor-sarif
```

Build a Gigasail database for this repository:

```bash
cargo run --manifest-path gems/gigasail/Cargo.toml -- build \
  --repo . \
  --db /tmp/gigasail.db
```

To cap analysis while iterating:

```bash
cargo run --manifest-path gems/gigasail/Cargo.toml -- build \
  --repo . \
  --db /tmp/gigasail.db \
  --max-commits 100
```

Inspect the highest-risk logical units:

```bash
cargo run --manifest-path gems/gigasail/Cargo.toml -- summary \
  --db /tmp/gigasail.db \
  --top 20 \
  --only src/ \
  --only gems/ \
  --only zig/
```

Serve the local UI:

```bash
cargo run --manifest-path gems/gigasail/Cargo.toml -- ui \
  --db /tmp/gigasail.db \
  --repo . \
  --overlay tmp/slopcop-constraints.json \
  --port 8080
```

Build the embedded React/Monaco diff view after changing its Rust API contract
or frontend source:

```bash
gems/gigasail/tools/build_diff_ui.sh
```

### Focused architecture view

Generate Espalier's structured graph, ingest it transactionally, and serve the
focused owner/function/state view:

```bash
FACT_MINE_RUST_BINARY="$PWD/gems/fact-mine/target/release/fact-mine-rust" \
  ruby -Igems/espalier/lib gems/espalier/exe/espalier \
  --format architecture \
  --output tmp/espalier-architecture.json \
  gems/espalier/lib gems/gigasail/src

cargo run --manifest-path gems/gigasail/Cargo.toml -- ingest-architecture \
  --db gigasail.db \
  --input tmp/espalier-architecture.json

cargo run --manifest-path gems/gigasail/Cargo.toml -- ui \
  --db gigasail.db --repo . --port 8080
```

Architecture actions then appear beside matched symbols in the source outline.
The graph APIs are also available under `/api/architecture`.

## Outputs

Gigasail can output a SQLite evidence database, text or JSON risk
summaries, a local source-review UI, and LSP diagnostics/CodeLens data
for editor integrations.

> [!NOTE]
> CLEAR uses Gigasail as its experimental UI for reviewing
> LLM-assisted code at scale. Decomplex, SlopCop, Boobytrap, Nil-kill,
> and mutation evidence become much easier to interpret when they are
> rendered next to the source lines they describe.

### SQLite Database

The build command writes a portable SQLite database with logical code
units and history events:

```bash
cargo run --manifest-path gems/gigasail/Cargo.toml -- build \
  --repo . \
  --db /tmp/gigasail.db
```

Core tables include:

- `logical_units`
- `events`
- `metadata`
- `quality_events`
- `crash_events`
- `test_exposure_events`
- `sarif_artifacts`
- `sarif_findings`
- `architecture_artifacts`
- `architecture_nodes`
- `architecture_edges`
- `architecture_edge_spans`
- `architecture_pressure`

Inspect the unit-level signal:

```sh
cargo run --manifest-path gems/gigasail/Cargo.toml -- summary \
  --db /tmp/gigasail.db \
  --top 20 \
  --only src/ \
  --only gems/ \
  --only zig/
```

## Supported Data Sources

Gigasail treats every uploaded artifact as data for a specific commit.
Use `--commit "$(git rev-parse HEAD)"` for current-run artifacts, and
use `--replace` when the uploaded artifact should replace previous rows
from the same source and commit.

| Source | Command | Current formats |
| --- | --- | --- |
| Git history | `build` | local Git repository |
| Coverage | `ingest-coverage` | Codecov JSON, SimpleCov JSON, Cobertura XML, kcov Cobertura XML, SQL-COV JSON (`--format sqlcov`) |
| Test exposure | `ingest-test-exposure` | Gigasail `test-exposure` JSON |
| Mutation testing | `ingest-mutants` | Ruby `mutant-facts/v1` |
| Systems hazards | `ingest-hazards` | Zig, Go, Rust, C, C++, C# hazard providers |
| Stack traces | `ingest` | Sentry-style event JSON |
| Static analysis and risk findings | `ingest-sarif` | SARIF 2.1.0 files from Decomplex, SlopCop, Boobytrap, Nil-Kill, Espalier, SQL-COV, and third-party tools |

Standalone `.sql` files are indexed as query logical units. A leading
`-- query-id:` comment supplies the stable unit name, allowing SQL-COV branch
coverage, SQL hazard SARIF, and SQL-COV plan-complexity observations to attach to
the same source view. Gigasail only stores and presents those observations; all
database/dialect analysis remains in SQL-COV.
| One-line repository import | `gems/gigasail/bin/gigasail-import` | Git history, coverage discovery, hazards, bundled first-party SARIF, Go/Rust/Ruby/Zig lint SARIF, extra SARIF |

### SARIF Findings

`ingest-sarif` recursively scans every `--input` path for `.sarif` and
`.json` files. JSON files that are not SARIF are skipped, which lets CI
upload a mixed artifact directory. Rows are keyed by
`commit/source/tool/path/span/rule/fingerprint`, so re-ingesting the
same findings is idempotent. `--replace` deletes prior SARIF rows for
the same `source` and `commit` before loading the new artifact set.

`gems/gigasail/bin/gigasail-import` generates and ingests the bundled
first-party SARIF set automatically: Decomplex, SlopCop, Boobytrap,
Nil-Kill, and Espalier. To generate that bundle without a full import,
run `tools/generate_generalized_gem_sarif.rb --repo . --out-dir tmp/gigasail-sarif`.

Live plan analysis is opt-in because it requires an explicit test schema and
database connection. The importer delegates it to SQL-COV and ingests the SARIF:

```sh
gems/gigasail/bin/gigasail-import \
  --sql-queries=queries/ \
  --sql-setup=test/schema.sql \
  --sql-dialect=postgres \
  --sql-database=postgres://localhost/app_test \
  --sql-param=int:42
```

For third-party lint, smell, or security tools, upload their SARIF into
a directory and use a source name that identifies the provider or CI
lane:

```sh
cargo run --manifest-path gems/gigasail/Cargo.toml -- ingest-sarif \
  --db gigasail.db \
  --repo . \
  --input tmp/vendor-sarif \
  --source rubocop \
  --commit "$(git rev-parse HEAD)" \
  --replace
```

Persisted SARIF findings appear in the dashboard counts, source line
detail popovers, API responses, and LSP diagnostics/gutter payloads.
Dark-arm SARIF from SlopCop/Boobytrap also feeds the same source-line
dark-arm rendering as transient UI overlays.

### Summary

`summary` ranks logical units by history and verification risk:

```bash
cargo run --manifest-path gems/gigasail/Cargo.toml -- summary \
  --db /tmp/gigasail.db \
  --top 20 \
  --format json
```

The text format is useful in a terminal. The JSON format is meant for
tools, dashboards, and LLM review workflows.

### Local UI

`ui` serves a local source and verification browser:

```bash
cargo run --manifest-path gems/gigasail/Cargo.toml -- ui \
  --db /tmp/gigasail.db \
  --repo . \
  --overlay tmp/slopcop-constraints.json \
  --port 8080
```

The UI renders tracked files, source, prior commit versions, coverage,
mutation evidence, dark-arm overlays, and systems hazards. It is
server-rendered and works without a client-side application stack.

The dashboard summary is also available as JSON:

```bash
curl http://127.0.0.1:8080/api/dashboard
```

### Language Server

`lsp` runs a stdio language server for editor integrations:

```bash
cargo run --manifest-path gems/gigasail/Cargo.toml -- lsp \
  --db /tmp/gigasail.db \
  --repo . \
  --overlay tmp/slopcop-constraints.json
```

The LSP publishes diagnostics for uncovered dark arms and open hazards,
hover text for logical-unit history and test evidence, CodeLens risk
summaries, and a custom gutter-update notification for editor wrappers.

## Evidence Ingestion

Gigasail is most useful after loading verification artifacts for the
current commit.

### Coverage

Ingest line coverage:

```bash
cargo run --manifest-path gems/gigasail/Cargo.toml -- ingest-coverage \
  --db /tmp/gigasail.db \
  --repo . \
  --format simplecov \
  --commit "$(git rev-parse HEAD)" \
  --input coverage/.resultset.json \
  --test-type unit
```

Supported formats include `simplecov`, `cobertura`, `codecov`,
`boobytrap`, and `generic`. Use `--replace` when an artifact is
authoritative for that commit and should replace prior rows for the
same source.

> [!NOTE]
> For `cobertura` format, Gigasail automatically parses `<source>` tags to combine them with class filenames. This resolves path resolution ambiguity for common file names (such as `src/lib.rs` or `src/main.rs`) when ingesting coverage from monorepo sub-projects.

Recommended CLEAR lanes:

- Ruby unit specs: `--format simplecov --test-type unit`
- Ruby transpile-tests/integration coverage:
  `--format simplecov --test-type integration`
- Ruby fuzz coverage: `--format simplecov --test-type fuzz`
- Zig kcov unit coverage: `--format cobertura --test-type unit`
- Zig systems evidence: `--test-type loom`, `--test-type vopr`, or
  `--test-type tsan`
- Rust systems evidence: `--test-type loom` for concurrency/atomic
  checks and `--test-type miri` for unsafe-code checks
- C/C++ systems evidence: `--test-type tsan`, `asan`, `lsan`, or
  `ubsan`
- C# systems evidence: `--test-type concurrency` or `unsafe`

### Test Exposure

Ingest named test exposure facts:

```bash
cargo run --manifest-path gems/gigasail/Cargo.toml -- ingest-test-exposure \
  --db /tmp/gigasail.db \
  --repo . \
  --commit "$(git rev-parse HEAD)" \
  --input gems/gigasail/test/fixtures/test-exposure-clear.json
```

Each record maps a commit, logical unit, and test to optional line,
branch, test type, and mutation status fields.

### Mutants

Ingest `mutant-facts/v1` after running a converter under
`gems/gigasail/tools/mutant-converters/`:

```bash
cargo run --manifest-path gems/gigasail/Cargo.toml -- ingest-mutants \
  --db /tmp/gigasail.db \
  --repo . \
  --commit "$(git rev-parse HEAD)" \
  --input /tmp/clear-ruby-mutants/mutant-facts.json \
  --test-type unit
```

The Ruby mutant converter and `zig-mutants` both emit the
`mutant-facts/v1` shape Gigasail consumes.

Targeted ratchet mutants use narrower semantics. The transpile-test and
fuzz mutant runners emit `test-exposure/v1` records for only the source
lines changed by each mutant patch. Those records use
`mutation_kind=invariant` because they prove a named contract or safety
rule at a specific mutation site; they do not mark every line executed by
the killing test.

```sh
ruby tools/mutants/transpile_tests.rb --all \
  --out /tmp/clear-transpile-mutants \
  --exposure /tmp/clear-transpile-mutants/test-exposure.json

ruby tools/fuzz/mutants/run.rb --all \
  --out /tmp/clear-fuzz-mutants \
  --exposure /tmp/clear-fuzz-mutants/test-exposure.json

cargo run --manifest-path gems/gigasail/Cargo.toml -- ingest-test-exposure \
  --db /tmp/gigasail.db \
  --repo . \
  --commit "$(git rev-parse HEAD)" \
  --input /tmp/clear-fuzz-mutants/test-exposure.json
```

After ingesting new coverage, SARIF, or test-exposure artifacts into a DB
that has UI summaries, refresh the read model:

```sh
cargo run --manifest-path gems/gigasail/Cargo.toml -- refresh-ui \
  --db /tmp/gigasail.db
```

### Hazards

Ingest current provider hazards:

```bash
cargo run --manifest-path gems/gigasail/Cargo.toml -- ingest-hazards \
  --db /tmp/gigasail.db \
  --repo . \
  --provider zig \
  --commit "$(git rev-parse HEAD)"
```

First-party providers currently support `zig`, `go`, `rust`, `c`,
`cpp`, and `csharp`. Zig scans the CLEAR runtime/lib Loom and VOPR
hazard sites. Rust scans Loom-relevant concurrency/atomic sites and
unsafe blocks/operations. C and C++ scan sanitizer-relevant concurrency,
raw-memory, lifetime, and UB hazards. C# scans concurrency and unsafe
native-memory hazards.

### Stack Traces

Ingest Sentry-style stack traces and anchor verified frames to logical
units:

```bash
cargo run --manifest-path gems/gigasail/Cargo.toml -- ingest \
  --db /tmp/gigasail.db \
  --repo . \
  --provider sentry \
  --input gems/gigasail/test/fixtures/sentry-clear-event.json
```

Stack-trace ingestion is commit-scoped. Re-ingesting the same event is
idempotent; use `--replace` to reload the commits present in an input
file.

### Runtime profiling (pprof) hotness

Static Big-O says which functions can be expensive; a profile says which
ones are. Gigasail ingests `profile-hotness/v1` and uses it to rank the
Expensive Operations view (Big-O first, then measured share), badge
critical functions with a flame icon in the file view, and annotate lines
in the info popup.

```bash
# capture with your language's profiler, e.g. Go:
go tool pprof -top -lines cpu.pb.gz > pprof-top.txt
# convert (also accepts stackprof JSON and perf script output):
ruby gems/gigasail/tools/pprof_to_hotness.rb --pprof-top pprof-top.txt > hotness.json
# ingest:
giga ingest-hotness --db gigasail.db --repo . --input hotness.json
```

For this repository, `ruby tools/profile_hotness.rb --target NAME --ingest
--db gigasail.db` packages the whole flow per sub-project. For perf-based
languages the binary must carry DWARF or frames arrive without file:line -
build Rust with `cargo build --profile profiling` and do not strip
Zig/C/C++ binaries. Frames without paths are resolved against the
logical-unit inventory at ingest time and never guessed.

See [profiling-data-integration.md](docs/agents/profiling-data-integration.md)
for per-language recipes, resolution tiers, and known gaps.

### MCP server

`giga mcp --db gigasail.db --repo .` exposes seven read-only,
workflow-shaped tools over stdio MCP - not one tool per table. Five are
context tools (file risk, unit context, verification gaps, change history,
find-definition); two are review tools (see below). `--db` is optional:
omitting it runs a DB-less mode serving live-disk structure and in-process
hazard scans only. See [mcp.md](docs/agents/mcp.md) for the context tools,
why 7 and not 17, the uncommitted-changes and DB-less designs, and known gaps.

### Review: verify before you ship

Two MCP tools give an agent (or CI) a machine-checked verdict instead of a
raw test log:

- **Setup.** `giga build`/`giga sync` first, then point the agent at
  `giga mcp`. `giga_precommit` reviews `HEAD~1..HEAD`; `giga_premerge`
  reviews `merge-base(HEAD, target)..HEAD` (whole branch, `target` defaults
  to `master`).
- **What it does.** Returns `verdict` (`pass` / `needs_review` / `critical`),
  the gates it triggered, and the ranked *new* findings by tier with each
  line's coverage - a compact JSON report, not test output. A `critical`
  verdict blocks.
- **Configure.** A `review:` block in `giga.yml` sets which findings matter
  (show / deprioritize / ignore), ranking weights, purity thresholds, and the
  gates. Absent config gates only on an uncovered T1. See
  [tuning-configs.md](docs/agents/tuning-configs.md).
- **Token impact.** The evaluator runs the checks and hands back a
  ~500-2k-token verdict, keeping the 5k-50k-token raw suite/coverage log out
  of the model's context. The one fixed cost is the two extra tool schemas in
  the tool list every turn; on any non-trivial change the verdict is far
  cheaper - and harder to misread - than piping a truncated log through the
  window. Rationale and the cost analysis: tuning-configs.md §9.

### `giga test`: run only the tests a change needs

`giga test` runs the test producers your `giga.yml` declares, chosen by what
changed and by review stage, then ingests coverage/mutation evidence. It
orchestrates plain commands - it is **not** a build system (delegate to Bazel by
putting `bazel test ...` in a producer's argv; see
[tuning-configs.md](docs/agents/tuning-configs.md) §12-§13).

```bash
giga test                 # precommit: affected packages' fast tests, no mutation
giga test --premerge      # premerge: + fuzz suites + mutation
giga test --mutants       # add mutation even at precommit
giga test --no-cov        # skip coverage-only producers
giga test --unit          # only producers tagged evidence_scope.test_set: unit
giga test --changed P...  # treat P... as the changed set (preview / bypass git)
giga test --checks        # run pre-test lint/format gates (--no-checks forces off)
giga test --dry-run       # print the resolved plan, run nothing
```

**Configure which files trigger which tests** with a project graph under
`review.packages`. Each package names its files (`paths` globs), the packages it
`depends_on`, the `producers` to run, and extra `premerge`-only producers (fuzz).
A change runs the **affected** packages - the ones whose files changed *plus*
every package that transitively depends on them:

```yaml
review:
  packages:
    compiler:  { paths: [compiler/ruby/**], producers: [compiler-spec, transpile], premerge: [fuzz-compiler] }
    zig:       { paths: [zig/**],           producers: [zig-test, transpile],       premerge: [fuzz-zig] }
    fact-mine: { paths: [gems/fact-mine/**], producers: [fact-mine-test] }
    decomplex: { paths: [gems/decomplex/**], depends_on: [fact-mine], producers: [decomplex-test] }
    boobytrap: { paths: [gems/boobytrap/**], producers: [boobytrap-test] }
    slopcop:   { paths: [gems/slopcop/**],   depends_on: [fact-mine, boobytrap], producers: [slopcop-test] }
```

So editing `gems/fact-mine/**` runs fact-mine's tests **and** decomplex's (it
depends on fact-mine) **and** slopcop's (depends on fact-mine); editing
`compiler/ruby/**` runs the spec + transpile suites (and fuzz at premerge);
`zig/**` runs zig + transpile. `precommit` runs each package's `producers`;
`premerge` adds its `premerge` producers and turns mutation on. With no
`packages` graph, `giga test` falls back to the `review.tests.<stage>` profiles.
This is the same affected-set idea as Nx/Turborepo, kept to a declarative graph
rather than a build system. `depends_on` edges must be your project's **real**
dependencies (gemspec/import) - a wrong edge over-runs (false dependent) or, worse,
under-runs (a missing dependent skips tests it should have run). Preview any
change with `giga test --dry-run --changed <path>`.

**Optional pre-test gates.** Set `checks_enabled: true` (or pass `--checks`) to
run lint/format gates *before* a package's tests, stopping early on failure. Each
package lists `checks`; a check is either `contrib:<cat>:<lang>` (a bundled
recommended script - `contrib:lint:ruby`, `contrib:lint:rust`, `contrib:fmt:zig`,
each scoped to the changed files and skipped if the tool is absent) or a
repo-relative script path. Every check gets `$GIGA_CHANGED`. This is a gate, not
CI - keep anything heavier in a producer's argv. See
[tuning-configs.md](docs/agents/tuning-configs.md) §13-§14.

```yaml
review:
  checks_enabled: false   # opt-in; or `giga test --checks`
  packages:
    compiler: { paths: [compiler/ruby/**], producers: [compiler-spec], checks: [contrib:lint:ruby] }
    zig:      { paths: [zig/**], producers: [zig-test], checks: [contrib:fmt:zig] }
```

### Dogfooding on CLEAR: is the overhead worth it?

The workflow: let the agent run `giga_precommit` on every commit (fast, keeps
each commit green), then `giga_premerge` once at the end (exhaustive - catches
the tech debt accrued along the way) before merging.

Measured on the CLEAR compiler (`~/clear`, ~2,800 commits of history, 255
source files, Ruby unit suite via `prspec`). The question is whether tracking
coverage/analysis on top of the tests you already run is a rounding error or a
tax:

| Step | Time | Notes |
|---|---|---|
| Unit suite, no coverage (know it *passes*) | **1m45s** | parallel `prspec` |
| Unit suite **with** branch coverage | **2m12s** | +26% - SimpleCov instrumentation |
| Ingest that coverage into giga | **+19s** | 255 files, 84k line events |
| **Precommit total** (tests + coverage of the delta) | **~2m31s** | +44% over bare tests |
| One-time history index (`giga build`) | 52s once | incremental after: **~0.07s/commit** |
| Static analysis (espalier graph + SARIF), premerge only | +23s analyze | see note |
| Ingest the architecture graph | +4s | was 59s; fixed by materializing the unit-reconcile join once |

**Takeaway.** Coverage *of the delta* costs ~26% on the test run plus a flat
~19s ingest - a clear win: you already ran the tests, and now you know which
*changed* lines are actually covered. The incremental cost per later commit is
near-zero (the history index is one-time; coverage re-ingests one file).

**Mutation (honest gap).** A project-wide mutant database for a whole compiler
is a multi-hour one-time build, and it is **not yet run here** (CLEAR's mutant
tooling is currently Go-only; the Ruby `mutant` runner for `compiler/ruby` is a
TODO). The design intent is what makes it viable: incremental mutation re-runs
only the *changed subjects*, so per-commit mutant time scales with the diff, not
the project - which is exactly why `giga_precommit` skips mutation by default and
`giga_premerge` runs it. The rule of thumb we are validating: if per-commit
mutant feedback (after the initial DB) stays within a small multiple of the test
run, it earns its place at premerge; if it is 10x, it will not get used. That
number will be filled in here once the Ruby mutant runner lands.

## Supported Languages Roadmap

Gigasail uses Tree-sitter-backed logical-unit extraction for the core
languages it aims to track as a ground-truth risk ledger. For those
languages, parse failures produce no units instead of falling back to
regex boundaries. Heuristic extraction remains only for secondary
experimental languages.

- [x] Ruby: Tree-sitter-backed; used for CLEAR compiler review.
- [x] Zig: Tree-sitter-backed; used for CLEAR runtime review and
  systems hazards.
- [x] Rust: Tree-sitter-backed.
- [x] Python: Tree-sitter-backed.
- [x] JavaScript / TypeScript: Tree-sitter-backed.
- [x] Go: Tree-sitter-backed, including concurrency hazards.
- [x] C / C++: Tree-sitter-backed, including sanitizer hazards.
- [x] C#: Tree-sitter-backed, including concurrency/unsafe hazards.
- [ ] Lua: experimental heuristic extraction.
- [ ] Assembly: experimental label extraction.

## Boundaries

The `gigasail` binary stores, joins, and renders evidence. The
`gigasail-import` wrapper can orchestrate bundled producers and import
artifacts for a repository checkout. The core binary does not:

- run tests;
- collect coverage;
- perform mutation testing;
- compute Decomplex, SlopCop, Nil-kill, or Boobytrap findings;
- prove that a code unit is correct or incorrect;
- post GitHub comments or call the GitHub API;
- replace the source tools that generate quality evidence.

It stores, joins, and renders evidence. A good Gigasail view should make a
human say: "this line is risky, and here is the history and verification
evidence explaining why."

## Links

- [CLEAR compiler](../../README.md)
- [Decomplex](../decomplex/README.md): identifies complex state and
  control-flow pressure.
- [SlopCop](../slopcop/README.md): categorizes uncovered branches and
  ranks the true test gaps.
- [Boobytrap](../boobytrap/README.md): provides churn and risk signals.
- [Nil-kill](../nil-kill/README.md): traces nil and type pressure back
  to its source.
