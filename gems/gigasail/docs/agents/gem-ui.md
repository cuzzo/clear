# Gigasail UI: SARIF-Aware Refactoring Cockpit

This document defines how the Gigasail UI should aggregate first-party gem
findings and later ecosystem analysis artifacts. The goal is not to make every
tool depend on Gigasail. The goal is to make Gigasail the durable place where
findings from many tools are normalized, attached to source, and displayed with
history, coverage, hazards, and test evidence.

## Goals

- Treat SARIF as the shared interchange format for first-party and third-party
  analysis results.
- Persist SARIF findings in the Gigasail SQLite database so UI, LSP, and future
  risk ranking use the same source of truth.
- Keep the existing `--overlay` UI/LSP option as a lightweight preview/debug
  mode for local artifacts.
- Support first-party SARIF from Decomplex, SlopCop, Nil-Kill static analysis,
  and Espalier.
- Allow users or CI to drop SARIF artifacts into a directory and ingest them
  without writing a provider-specific adapter.
- Do not design lint/smell/Flay semantics yet. The only requirement for those
  tools in this phase is that their artifacts can use the same SARIF ingest path
  later.

## Current State

Gigasail already accepts repeated `--overlay` paths for the UI and LSP. The
overlay loader can read SARIF 2.1.0 and JSON-like dark-arm payloads, but it is
intentionally transient: the artifacts are parsed at server startup, attached to
line annotations in memory, and not recorded in SQLite.

That is useful for spot checks, but it is not enough for the full product:

- findings cannot be queried historically;
- findings cannot be counted on directory cards or dashboards;
- LSP and UI do not share a durable artifact inventory;
- multiple tools cannot be deduplicated or compared by run/source;
- CI-uploaded artifacts disappear unless the server is launched with the right
  overlay arguments.

## Target Model

Gigasail has two SARIF intake modes.

### 1. Ephemeral Overlay Mode

Command shape:

```sh
giga ui --db gigasail.db --repo . --overlay tmp/slopcop.sarif --overlay tmp/decomplex.sarif
giga lsp --db gigasail.db --repo . --overlay tmp/slopcop.sarif
```

Use this for local experiments and debugging. It should remain fast and
forgiving. It does not update the database.

### 2. Persistent Ingestion Mode

Command shape:

```sh
giga ingest-sarif \
  --db gigasail.db \
  --repo . \
  --input tmp/gigasail-sarif \
  --source first-party \
  --commit "$(git rev-parse HEAD)" \
  --replace
```

The input may be a file or directory. Directory ingest recursively discovers
`.sarif` and `.json` files, parses SARIF documents, and ignores unsupported JSON.
`--replace` deletes previous findings for the same `source` and `commit` before
inserting the new run, making CI reruns idempotent.

## Normalized Storage Contract

Gigasail stores two levels of data.

### `sarif_artifacts`

One row per ingested file/run group.

Required fields:

- `source`: caller-supplied source bucket, e.g. `decomplex`, `slopcop`,
  `nil-kill-static`, `espalier`, `first-party`, `ruff`, `clippy`.
- `tool_name`: SARIF `runs[].tool.driver.name`.
- `run_format`: SARIF run property such as `decomplex.report.sarif.v1`.
- `artifact_path`: repo-relative or local artifact path used for traceability.
- `artifact_sha256`: content digest for dedupe/debugging.
- `commit_hash`, `timestamp`.
- `payload_json`: the raw SARIF document for later reprocessing.

### `sarif_findings`

One row per SARIF result location. A SARIF result with multiple locations becomes
multiple normalized findings.

Required fields:

- `source`, `tool_name`, `run_format`, `commit_hash`, `timestamp`.
- `rule_id`, `level`, `message`.
- `path`, `start_line`, `start_column`, `end_line`, `end_column`.
- `category`: best-effort category from SARIF properties or rule id.
- `is_dark_arm`: true when the result represents a dark branch arm.
- `unit_id`: nullable link to the current logical unit containing the line.
- `fingerprint`: SARIF partial fingerprint or Gigasail-computed natural key.
- `properties_json`, `raw_json`.

This model is intentionally generic. First-party gems may put richer structured
data in `properties`; Gigasail stores it without needing custom columns for every
detector.

## First-Party Source Roles

### Decomplex

Decomplex emits structural complexity and similarity findings as SARIF. Gigasail
should ingest it directly. UI display belongs in the Structural or Audit tab, and
line popups should show the rule, level, and message.

### SlopCop

SlopCop currently acts as a near-term aggregator for Boobytrap and Decomplex
coverage-risk signals. That is acceptable for now because it owns dark-arm
classification and PR annotations. Gigasail should ingest SlopCop SARIF directly
and preserve `dark_arm` properties so exact spans can render in the source
viewer.

Long term, Gigasail should become the top-level aggregator and SlopCop should be
one source among many. That migration should not block current ingestion.

### Nil-Kill

For this phase, ingest only Nil-Kill static analysis SARIF. Do not ingest full
runtime trace bundles into SARIF tables. Runtime traces remain under Nil-Kill
evidence or Gigasail test-exposure/coverage tables.

Nil-Kill static SARIF can populate the Evidence tab and line popups with
type-system or nullability findings.

### Espalier

Espalier emits architecture SARIF. Gigasail should ingest it directly and render
findings in an Architecture tab or generic line detail panel until the dedicated
architecture panel exists.

## Artifact Directory Convention

CI and local scripts should be able to write first-party artifacts to one
directory:

```text
tmp/gigasail-sarif/
  decomplex.sarif
  slopcop.sarif
  nil-kill-static.sarif
  espalier.sarif
```

The same directory convention should work later for external SARIF:

```text
tmp/gigasail-sarif/ecosystem/
  ruff.sarif
  eslint.sarif
  clippy.sarif
```

No special file naming is required for parsing. Naming only helps humans. Tool
identity comes from SARIF `tool.driver.name`; source bucket comes from
`--source`.

## UI Behavior

### Source Viewer

For each line, the annotation payload should include:

- coverage and mutation status;
- dark-arm spans;
- systems hazards;
- bug/fix history;
- persisted SARIF findings grouped by source/tool/rule.

Dark-arm SARIF should keep special rendering: exact dark spans in the code should
be shaded dark gray. Other SARIF findings should appear in the line `i` popup and
be exposed to the LSP as diagnostics or hover text.

### Directory and File Cards

Cards should include a compact SARIF finding count once persistent SARIF exists.
The initial version can show a single count. Later versions can split by
severity, provider, and category.

### Deep Dive Panels

Near-term tabs:

- Coverage and hazards: Gigasail, Boobytrap, SlopCop.
- Structural: Decomplex.
- Evidence: Nil-Kill static findings.
- Architecture: Espalier.
- Ecosystem: generic SARIF sources.

The implementation may initially render these through generic line popups and
JSON payloads. The storage contract should not require the final tab UI to exist
before ingestion is useful.

## LSP Behavior

The LSP should publish diagnostics for persisted SARIF findings with a severity
derived from SARIF `level`:

- `error` -> error;
- `warning` -> warning;
- `note` -> information;
- anything else -> hint.

Dark-arm findings should continue to appear as dark-arm gutter items.

## Idempotency

Persistent SARIF ingestion must be safe to run repeatedly in CI.

- `--replace` deletes prior rows for the same `source` and `commit` before
  inserting.
- Without `--replace`, insertion uses a deterministic finding key so duplicate
  artifacts do not double-count findings.
- The finding key is based on source, commit, tool, rule, path, region,
  fingerprint, and message.

## Non-Goals For This Phase

- Do not build custom linter/smell/flay adapters.
- Do not re-score every SARIF provider into Boobytrap risk.
- Do not move all SlopCop aggregation into Gigasail yet.
- Do not store Nil-Kill runtime trace event streams as SARIF.

## Acceptance Criteria

- `giga ingest-sarif` accepts a file or directory of SARIF artifacts.
- Decomplex, SlopCop, Nil-Kill static analysis, and Espalier SARIF can be
  ingested for the current commit.
- Re-running ingest with `--replace` does not double-count findings.
- Source API payloads include persisted SARIF findings at matching lines.
- Dark-arm SARIF still renders exact dark spans.
- Directory/file cards expose at least a total SARIF finding count.
- The same DB-backed findings are visible to UI and LSP code paths.
