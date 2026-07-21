# Lineage

Lineage is a Rust history and evidence engine for reviewing code at
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
wrapper. It builds the required Lineage/analyzer binaries, builds the
Lineage database, discovers supported coverage artifacts, runs bundled
hazard providers, generates first-party SARIF, runs available Go/Rust/Ruby/Zig
lints, ingests extra SARIF inputs, refreshes UI summaries, and can start the
UI server:

```bash
gems/lineage/bin/lineage-import \
  --repo . \
  --db lineage.db \
  --out-dir tmp/lineage-import \
  --fresh \
  --serve \
  --daemon \
  --host 0.0.0.0 \
  --port 8080
```

Useful iteration flags:

```bash
gems/lineage/bin/lineage-import --repo . --db tmp/lineage.db --fresh --max-commits 100
gems/lineage/bin/lineage-import --repo . --db tmp/lineage.db --fresh --no-coverage --no-lints
gems/lineage/bin/lineage-import --repo . --db tmp/lineage.db --sarif-input tmp/vendor-sarif
```

Build a Lineage database for this repository:

```bash
cargo run --manifest-path gems/lineage/Cargo.toml -- build \
  --repo . \
  --db /tmp/lineage.db
```

To cap analysis while iterating:

```bash
cargo run --manifest-path gems/lineage/Cargo.toml -- build \
  --repo . \
  --db /tmp/lineage.db \
  --max-commits 100
```

Inspect the highest-risk logical units:

```bash
cargo run --manifest-path gems/lineage/Cargo.toml -- summary \
  --db /tmp/lineage.db \
  --top 20 \
  --only src/ \
  --only gems/ \
  --only zig/
```

Serve the local UI:

```bash
cargo run --manifest-path gems/lineage/Cargo.toml -- ui \
  --db /tmp/lineage.db \
  --repo . \
  --overlay tmp/slopcop-constraints.json \
  --port 8080
```

### Focused architecture view

Generate Espalier's structured graph, ingest it transactionally, and serve the
focused owner/function/state view:

```bash
FACT_MINE_RUST_BINARY="$PWD/gems/fact-mine/target/release/fact-mine-rust" \
  ruby -Igems/espalier/lib gems/espalier/exe/espalier \
  --format architecture \
  --output tmp/espalier-architecture.json \
  gems/espalier/lib gems/lineage/src

cargo run --manifest-path gems/lineage/Cargo.toml -- ingest-architecture \
  --db lineage.db \
  --input tmp/espalier-architecture.json

cargo run --manifest-path gems/lineage/Cargo.toml -- ui \
  --db lineage.db --repo . --port 8080
```

Architecture actions then appear beside matched symbols in the source outline.
The graph APIs are also available under `/api/architecture`.

## Outputs

Lineage can output a SQLite evidence database, text or JSON risk
summaries, a local source-review UI, and LSP diagnostics/CodeLens data
for editor integrations.

> [!NOTE]
> CLEAR uses Lineage as its experimental UI for reviewing
> LLM-assisted code at scale. Decomplex, SlopCop, Boobytrap, Nil-kill,
> and mutation evidence become much easier to interpret when they are
> rendered next to the source lines they describe.

### SQLite Database

The build command writes a portable SQLite database with logical code
units and history events:

```bash
cargo run --manifest-path gems/lineage/Cargo.toml -- build \
  --repo . \
  --db /tmp/lineage.db
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
cargo run --manifest-path gems/lineage/Cargo.toml -- summary \
  --db /tmp/lineage.db \
  --top 20 \
  --only src/ \
  --only gems/ \
  --only zig/
```

## Supported Data Sources

Lineage treats every uploaded artifact as data for a specific commit.
Use `--commit "$(git rev-parse HEAD)"` for current-run artifacts, and
use `--replace` when the uploaded artifact should replace previous rows
from the same source and commit.

| Source | Command | Current formats |
| --- | --- | --- |
| Git history | `build` | local Git repository |
| Coverage | `ingest-coverage` | Codecov JSON, SimpleCov JSON, Cobertura XML, kcov Cobertura XML, SQL-COV JSON (`--format sqlcov`) |
| Test exposure | `ingest-test-exposure` | Lineage `test-exposure` JSON |
| Mutation testing | `ingest-mutants` | Ruby `mutant-facts/v1` |
| Systems hazards | `ingest-hazards` | Zig, Go, Rust, C, C++, C# hazard providers |
| Stack traces | `ingest` | Sentry-style event JSON |
| Static analysis and risk findings | `ingest-sarif` | SARIF 2.1.0 files from Decomplex, SlopCop, Boobytrap, Nil-Kill, Espalier, SQL-COV, and third-party tools |

Standalone `.sql` files are indexed as query logical units. A leading
`-- query-id:` comment supplies the stable unit name, allowing SQL-COV branch
coverage, SQL hazard SARIF, and SQL-COV plan-complexity observations to attach to
the same source view. Lineage only stores and presents those observations; all
database/dialect analysis remains in SQL-COV.
| One-line repository import | `gems/lineage/bin/lineage-import` | Git history, coverage discovery, hazards, bundled first-party SARIF, Go/Rust/Ruby/Zig lint SARIF, extra SARIF |

### SARIF Findings

`ingest-sarif` recursively scans every `--input` path for `.sarif` and
`.json` files. JSON files that are not SARIF are skipped, which lets CI
upload a mixed artifact directory. Rows are keyed by
`commit/source/tool/path/span/rule/fingerprint`, so re-ingesting the
same findings is idempotent. `--replace` deletes prior SARIF rows for
the same `source` and `commit` before loading the new artifact set.

`gems/lineage/bin/lineage-import` generates and ingests the bundled
first-party SARIF set automatically: Decomplex, SlopCop, Boobytrap,
Nil-Kill, and Espalier. To generate that bundle without a full import,
run `tools/generate_generalized_gem_sarif.rb --repo . --out-dir tmp/lineage-sarif`.

Live plan analysis is opt-in because it requires an explicit test schema and
database connection. The importer delegates it to SQL-COV and ingests the SARIF:

```sh
gems/lineage/bin/lineage-import \
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
cargo run --manifest-path gems/lineage/Cargo.toml -- ingest-sarif \
  --db lineage.db \
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
cargo run --manifest-path gems/lineage/Cargo.toml -- summary \
  --db /tmp/lineage.db \
  --top 20 \
  --format json
```

The text format is useful in a terminal. The JSON format is meant for
tools, dashboards, and LLM review workflows.

### Local UI

`ui` serves a local source and verification browser:

```bash
cargo run --manifest-path gems/lineage/Cargo.toml -- ui \
  --db /tmp/lineage.db \
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
cargo run --manifest-path gems/lineage/Cargo.toml -- lsp \
  --db /tmp/lineage.db \
  --repo . \
  --overlay tmp/slopcop-constraints.json
```

The LSP publishes diagnostics for uncovered dark arms and open hazards,
hover text for logical-unit history and test evidence, CodeLens risk
summaries, and a custom gutter-update notification for editor wrappers.

## Evidence Ingestion

Lineage is most useful after loading verification artifacts for the
current commit.

### Coverage

Ingest line coverage:

```bash
cargo run --manifest-path gems/lineage/Cargo.toml -- ingest-coverage \
  --db /tmp/lineage.db \
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
> For `cobertura` format, Lineage automatically parses `<source>` tags to combine them with class filenames. This resolves path resolution ambiguity for common file names (such as `src/lib.rs` or `src/main.rs`) when ingesting coverage from monorepo sub-projects.

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
cargo run --manifest-path gems/lineage/Cargo.toml -- ingest-test-exposure \
  --db /tmp/lineage.db \
  --repo . \
  --commit "$(git rev-parse HEAD)" \
  --input gems/lineage/test/fixtures/test-exposure-clear.json
```

Each record maps a commit, logical unit, and test to optional line,
branch, test type, and mutation status fields.

### Mutants

Ingest `mutant-facts/v1` after running a converter under
`gems/lineage/tools/mutant-converters/`:

```bash
cargo run --manifest-path gems/lineage/Cargo.toml -- ingest-mutants \
  --db /tmp/lineage.db \
  --repo . \
  --commit "$(git rev-parse HEAD)" \
  --input /tmp/clear-ruby-mutants/mutant-facts.json \
  --test-type unit
```

The Ruby mutant converter and `zig-mutants` both emit the
`mutant-facts/v1` shape Lineage consumes.

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

cargo run --manifest-path gems/lineage/Cargo.toml -- ingest-test-exposure \
  --db /tmp/lineage.db \
  --repo . \
  --commit "$(git rev-parse HEAD)" \
  --input /tmp/clear-fuzz-mutants/test-exposure.json
```

After ingesting new coverage, SARIF, or test-exposure artifacts into a DB
that has UI summaries, refresh the read model:

```sh
cargo run --manifest-path gems/lineage/Cargo.toml -- refresh-ui \
  --db /tmp/lineage.db
```

### Hazards

Ingest current provider hazards:

```bash
cargo run --manifest-path gems/lineage/Cargo.toml -- ingest-hazards \
  --db /tmp/lineage.db \
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
cargo run --manifest-path gems/lineage/Cargo.toml -- ingest \
  --db /tmp/lineage.db \
  --repo . \
  --provider sentry \
  --input gems/lineage/test/fixtures/sentry-clear-event.json
```

Stack-trace ingestion is commit-scoped. Re-ingesting the same event is
idempotent; use `--replace` to reload the commits present in an input
file.

### Runtime profiling (pprof) hotness

Static Big-O tells you which functions *can* be expensive; a runtime
profile tells you which ones actually are. Lineage ingests
`profile-hotness/v1` documents and uses them to rank and badge critical
functions.

**1. Create the profile with your language's profiler.** Profile a
representative workload (production traffic or the `benchmarks/` suite;
unit-test runs are setup-dominated and unrepresentative):

```bash
# Go (or any pprof-protobuf producer: Rust pprof crate, C++ gperftools)
go test -bench=. -cpuprofile cpu.pb.gz
go tool pprof -top -lines cpu.pb.gz > pprof-top.txt

# Ruby
stackprof --json tmp/stackprof-cpu.dump > stackprof.json
```

**2. Convert to `profile-hotness/v1`.** The reference converter parses
`pprof -top -lines` text and stackprof JSON, computes each function's
cumulative share, and assigns a tier (`critical` >= 5% cumulative,
`warm` >= 0.5%, `cold` otherwise):

```bash
ruby gems/lineage/tools/pprof_to_hotness.rb \
  --pprof-top pprof-top.txt \
  --strip-prefix "$PWD" \
  --source pprof:cpu > hotness.json
```

Writing a converter for another profiler is a page of code: emit
`{"schema": "profile-hotness/v1", "source": ..., "entries": [{"function",
"path", "line", "flat_share", "cum_share", "tier"}]}`. Merge multiple
workloads by ingesting each under its own `--source`; consumers take the
maximum tier across sources, because hot in any real workload means hot.

**3. Ingest into Lineage:**

```bash
cargo run --manifest-path gems/lineage/Cargo.toml -- ingest-hotness \
  --db /tmp/lineage.db \
  --repo . \
  --input hotness.json
```

or as part of a full import: `bin/lineage-import --hotness=hotness.json`.
Re-ingesting the same `source` replaces its previous rows.

For this repository, `ruby tools/profile_hotness.rb` packages the whole
step-1-through-3 workflow with a per-subproject recipe: `--target compiler`
profiles real compiles of the `benchmarks/` and `examples/` corpus under
stackprof, `--target boobytrap` uses `go test -cpuprofile`, `--target
fact-mine` and `--target zig` use `perf record` around real workloads, and
each Ruby gem target profiles its test files (advisory). Add `--ingest
--db lineage.db` to ingest every generated profile in the same run;
`--list` shows all targets.

**4. What the UI does with it:**

- The dashboard "Expensive Operations" list ranks by Big-O first, then by
  profiled cumulative share within each Big-O tier - an `O(N^2)` function
  measured at 60% of runtime outranks an unprofiled `O(N^2)` one, and the
  entry's detail line gains `Profile: critical 60.0% (pprof:cpu)`.
- Critical functions get a Font Awesome flame icon
  (`fa-fire`) next to their name in the file-view outline, with the
  measured share in the tooltip.
- Lines attributed by the profile gain a `runtime profile: critical -
  60.0% cumulative (pprof:cpu)` row in the line's info popup
  (`fa-circle-info`).

## Supported Languages Roadmap

Lineage uses Tree-sitter-backed logical-unit extraction for the core
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

The `lineage` binary stores, joins, and renders evidence. The
`lineage-import` wrapper can orchestrate bundled producers and import
artifacts for a repository checkout. The core binary does not:

- run tests;
- collect coverage;
- perform mutation testing;
- compute Decomplex, SlopCop, Nil-kill, or Boobytrap findings;
- prove that a code unit is correct or incorrect;
- post GitHub comments or call the GitHub API;
- replace the source tools that generate quality evidence.

It stores, joins, and renders evidence. A good Lineage view should make a
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
