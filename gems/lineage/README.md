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

If you want to contribute, see the repository-level
[CONTRIBUTING.md](../../CONTRIBUTING.md).

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

## CI Integration

The current CI-ready path is:

1. build or restore a Lineage database for the repository history;
2. ingest coverage, mutation, hazard, and crash artifacts for the PR
   commit;
3. ingest SlopCop/constraints overlays when available;
4. run `refresh-ui` if cached UI summaries are needed;
5. publish the database or serve the UI as an internal review artifact.

> [!NOTE]
> Lineage is not itself the CI gate. Decomplex, SlopCop, mutant tests,
> fuzz tests, and systems tests produce the verdicts; Lineage makes that
> evidence reviewable next to source.

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

Lineage does not detect lint issues or code smells, as packages for that
already exist in every language.

## Links

- [CLEAR compiler](../../README.md)
- [Decomplex](../decomplex/README.md): identifies complex state and
  control-flow pressure.
- [SlopCop](../slopcop/README.md): categorizes uncovered branches and
  ranks the true test gaps.
- [Boobytrap](../boobytrap/README.md): provides churn and risk signals.
- [Nil-kill](../nil-kill/README.md): traces nil and type pressure back
  to its source.
