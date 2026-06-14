# Lineage

Lineage is a Rust history engine for tracking logical code units across
renames, moves, and refactors. It is intended to become Boobytrap's
high-fidelity historical risk provider.

The current crate is the bootstrap implementation:

- `VcsProvider` defines the repository traversal boundary.
- `GitProvider` implements that boundary with `git2`.
- `BoundaryExtractor` defines the logical-unit extraction boundary.
- `SourceFilter` defaults to a code-only whitelist for this repo's MVP:
  `.rb`, `.zig`, `.py`, `.js`, `.lua`, `.c`, `.go`, and `.S`.
  It also skips generated/cache/vendor path components by default.
- `HeuristicExtractor` provides the first source-unit extractor behind
  the same trait Tree-sitter language profiles will use.
- `Storage` owns the portable SQLite schema from the design document.
- `LineageEngine` compares commit snapshots and emits `CHANGE`, `MOVE`,
  and `FIX` events.
  `MOVE` events are recorded for lineage continuity, but they do not
  contribute to summary risk.

## Usage

```sh
cargo run --manifest-path gems/lineage/Cargo.toml -- build \
  --repo . \
  --db lineage.db
```

To cap analysis while testing:

```sh
cargo run --manifest-path gems/lineage/Cargo.toml -- build \
  --repo . \
  --db /tmp/lineage.db \
  --max-commits 100
```

The CLI writes a SQLite database with:

- `logical_units`
- `events`
- `metadata`
- `quality_events`
- `crash_events`
- `test_exposure_events`

Inspect the unit-level signal:

```sh
cargo run --manifest-path gems/lineage/Cargo.toml -- summary \
  --db /tmp/lineage.db \
  --top 20 \
  --only src/ \
  --only gems/ \
  --only zig/
```

Ingest coverage history after a build. The Codecov parser accepts API
v2 `totals` responses and `report/tree` responses. Cobertura XML is
also supported and records exact per-line hit counts for the source UI:

```sh
cargo run --manifest-path gems/lineage/Cargo.toml -- ingest-coverage \
  --db /tmp/lineage.db \
  --format codecov \
  --commit "$(git rev-parse HEAD)" \
  --input gems/lineage/test/fixtures/codecov-clear-totals.json

cargo run --manifest-path gems/lineage/Cargo.toml -- ingest-coverage \
  --db /tmp/lineage.db \
  --format cobertura \
  --commit "$(git rev-parse HEAD)" \
  --input coverage/coverage.xml
```

Pass `--test-type` when a coverage artifact represents a specific
verification lane. Lineage still stores aggregate line coverage, and it
also writes suite-level `test_exposure_events` so the UI can distinguish
which kind of test hit a line. The generated `test_id` names the coverage
artifact, not an individual test case.

Recommended CLEAR lanes:

- Ruby unit specs: `--format simplecov --test-type unit`
- Ruby transpile-tests/integration coverage: `--format simplecov --test-type integration`
- Ruby tools/fuzz coverage: `--format simplecov --test-type fuzz`
- Zig kcov unit coverage: `--format cobertura --test-type unit`
- Zig systems evidence: use `--test-type loom`, `--test-type vopr`, or
  `--test-type tsan` for lane-specific artifacts. Loom/VOPR hazard facts
  can also be emitted with `tools/lineage_zig_system_exposure.rb`.

```sh
cargo run --manifest-path gems/lineage/Cargo.toml -- ingest-coverage \
  --db /tmp/lineage.db \
  --repo . \
  --format simplecov \
  --commit "$(git rev-parse HEAD)" \
  --input coverage/.resultset.json \
  --test-type unit

cargo run --manifest-path gems/lineage/Cargo.toml -- ingest-coverage \
  --db /tmp/lineage.db \
  --repo . \
  --format cobertura \
  --commit "$(git rev-parse HEAD)" \
  --input zig/zig-out/coverage/merged/kcov-merged/cobertura.xml \
  --test-type unit
```

Coverage ingestion is commit-scoped. Re-ingesting the same artifact for
the same commit updates existing rows instead of duplicating them. Use
`--replace` when an artifact is authoritative for that commit and should
delete prior coverage facts for that commit before loading the new file:

```sh
cargo run --manifest-path gems/lineage/Cargo.toml -- ingest-coverage \
  --db /tmp/lineage.db \
  --format cobertura \
  --commit "$(git rev-parse HEAD)" \
  --input coverage/coverage.xml \
  --replace
```

Ingest named test exposure history after a test run. This stores one
event per `(commit, logical unit, test)` hit, with optional line, branch,
test type, and mutation status fields:

```sh
cargo run --manifest-path gems/lineage/Cargo.toml -- ingest-test-exposure \
  --db /tmp/lineage.db \
  --repo . \
  --commit "$(git rev-parse HEAD)" \
  --input gems/lineage/test/fixtures/test-exposure-clear.json
```

Ingest Sentry-style stack traces and anchor verified frames to logical
units:

```sh
cargo run --manifest-path gems/lineage/Cargo.toml -- ingest \
  --db /tmp/lineage.db \
  --repo . \
  --provider sentry \
  --input gems/lineage/test/fixtures/sentry-clear-event.json
```

Stack-trace ingestion is also commit-scoped through each payload's commit
field. Re-ingesting the same Sentry event/frame is idempotent. Add
`--replace` to delete prior crash frames for the commits present in the
input before reloading them.

The extractor boundary is deliberately separate from storage and VCS
traversal so Tree-sitter-backed language profiles can replace the
bootstrap extractor without changing Boobytrap's database contract.

Serve the local source and verification UI:

```sh
cargo run --manifest-path gems/lineage/Cargo.toml -- ui \
  --db /tmp/lineage.db \
  --repo . \
  --overlay tmp/slopcop-constraints.json \
  --port 8080
```

The MVP UI lists tracked files, renders source, lets you inspect prior
commit versions, highlights covered lines, darkens mutation-tested
lines, and shows systems hazards with tooltip details. The HTML view is
server-rendered; filtering, file navigation, version history, and line
details use regular links, GET forms, and `<details>` controls rather
than client-side JavaScript.

The UI home page shows a Codecov-style current snapshot: exact line
coverage, active hazards with required evidence, covered-line share with
killed-mutant evidence, and covered-line share with multiple verified
test types. The same aggregate is available as JSON:

```sh
curl http://127.0.0.1:8080/api/dashboard
```

Run the language server over stdio for editor integrations:

```sh
cargo run --manifest-path gems/lineage/Cargo.toml -- lsp \
  --db /tmp/lineage.db \
  --repo . \
  --overlay tmp/slopcop-constraints.json
```

The LSP publishes standard diagnostics for uncovered dark arms and open
hazards, hover text for logical-unit history and test evidence, CodeLens
risk summaries above units, and a custom `lineage/gutterUpdate`
notification for VS Code/Vim gutter wrappers.
