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
- Optional coverage, mutation, hazard, or stack-trace artifacts

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
| Coverage | `ingest-coverage` | Codecov JSON, SimpleCov JSON, Cobertura XML, kcov Cobertura XML |
| Test exposure | `ingest-test-exposure` | Lineage `test-exposure` JSON |
| Mutation testing | `ingest-mutants` | Ruby `mutant-facts/v1` |
| Systems hazards | `ingest-hazards` | Zig hazard provider |
| Stack traces | `ingest` | Sentry-style event JSON |
| Static analysis and risk findings | `ingest-sarif` | SARIF 2.1.0 files from Decomplex, SlopCop, Boobytrap, Nil-Kill, Espalier, and third-party tools |

### SARIF Findings

`ingest-sarif` recursively scans every `--input` path for `.sarif` and
`.json` files. JSON files that are not SARIF are skipped, which lets CI
upload a mixed artifact directory. Rows are keyed by
`commit/source/tool/path/span/rule/fingerprint`, so re-ingesting the
same findings is idempotent. `--replace` deletes prior SARIF rows for
the same `source` and `commit` before loading the new artifact set.

```sh
mkdir -p tmp/lineage-sarif

bundle exec ruby gems/decomplex/exe/decomplex report \
  --emit-json=tmp/lineage-sarif/decomplex.sarif \
  --output=tmp/lineage-sarif/decomplex.md \
  src

bundle exec ruby gems/slopcop/exe/slopcop report \
  --repo=. \
  --coverage=coverage/.resultset.json \
  --json=tmp/lineage-sarif/slopcop.sarif \
  --output=tmp/lineage-sarif/slopcop.md

bundle exec ruby tools/nil-kill static \
  --root . \
  --output tmp/lineage-sarif/nil-kill-static.json \
  src

mkdir -p tmp/lineage-sarif/no-runtime
bundle exec ruby tools/nil-kill normalize \
  --root . \
  --static tmp/lineage-sarif/nil-kill-static.json \
  --traces tmp/lineage-sarif/no-runtime \
  --output tmp/lineage-sarif/nil-kill-static-evidence.json \
  --no-analyze

bundle exec ruby tools/nil-kill report \
  --evidence tmp/lineage-sarif/nil-kill-static-evidence.json \
  --format sarif \
  --sarif tmp/lineage-sarif/nil-kill-static.sarif

bundle exec ruby gems/espalier/exe/espalier \
  --format sarif \
  --output tmp/lineage-sarif/espalier.sarif \
  --nil-kill tmp/lineage-sarif/nil-kill-static.json \
  src

cargo run --manifest-path gems/lineage/Cargo.toml -- ingest-sarif \
  --db lineage.db \
  --repo . \
  --input tmp/lineage-sarif \
  --source first-party \
  --commit "$(git rev-parse HEAD)" \
  --replace
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

Recommended CLEAR lanes:

- Ruby unit specs: `--format simplecov --test-type unit`
- Ruby transpile-tests/integration coverage:
  `--format simplecov --test-type integration`
- Ruby fuzz coverage: `--format simplecov --test-type fuzz`
- Zig kcov unit coverage: `--format cobertura --test-type unit`
- Zig systems evidence: `--test-type loom`, `--test-type vopr`, or
  `--test-type tsan`

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

The current first-party provider scans Zig runtime/lib hazard sites used
by CLEAR's Loom and VOPR coverage work.

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

## Supported Languages Roadmap

Lineage currently uses a heuristic logical-unit extractor. Ruby and Zig
are the most exercised paths because CLEAR uses them for compiler and
runtime review. Other language extraction is experimental until the
planned Tree-sitter-backed profiles replace the bootstrap extractor.

- [x] Ruby: used for CLEAR compiler review.
- [x] Zig: used for CLEAR runtime review and systems hazards.
- [ ] Python: experimentally supported.
- [ ] JavaScript: experimentally supported.
- [ ] Lua: experimentally supported.
- [ ] C: experimentally supported.
- [ ] Go: experimentally supported.
- [ ] Assembly: experimentally supported.

## Boundaries

Lineage does not:

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

Support to ingest lint data and code smell data into Lineage is not yet
available. Though, it is planned for the first release.

## Links

- [CLEAR compiler](../../README.md)
- [Decomplex](../decomplex/README.md): identifies complex state and
  control-flow pressure.
- [SlopCop](../slopcop/README.md): categorizes uncovered branches and
  ranks the true test gaps.
- [Boobytrap](../boobytrap/README.md): provides churn and risk signals.
- [Nil-kill](../nil-kill/README.md): traces nil and type pressure back
  to its source.
