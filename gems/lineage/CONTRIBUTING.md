# Contributing To Lineage

Start with the repository-level [../../CONTRIBUTING.md](../../CONTRIBUTING.md).
This file only covers Lineage-specific architecture and contribution
rules.

## Architecture

Lineage is a Rust history and evidence engine with deliberately separate
boundaries:

- `src/vcs.rs` and `src/git.rs` own repository traversal.
- `src/extract.rs` owns logical-unit extraction.
- `src/storage.rs` owns the SQLite schema and writes.
- `src/engine.rs` compares commit snapshots and records history events.
- `src/quality.rs`, `src/test_exposure.rs`, `src/mutant.rs`,
  `src/hazard.rs`, and `src/stack_trace.rs` ingest verification
  evidence.
- `src/ui.rs` renders the local source-review UI.
- `src/lsp.rs` exposes editor diagnostics and CodeLens data.

Keep these boundaries intact. Provider-specific parsing should not write
directly to the database; Lineage core should verify commits, paths, and
logical-unit identity before recording evidence.

## Adding Evidence

Add a new evidence source when it helps explain why a code unit is risky,
stale, undertested, or historically bug-prone.

Required pieces:

- a parser or adapter for the provider payload;
- verification against repository paths and commits;
- storage through an existing first-class table or a clearly documented
  new schema path;
- tests for parsing, verification, idempotent ingestion, and skipped
  records;
- README updates if the ingestion path is user-facing.

Prefer a stable JSON envelope for provider data. Do not give plugins or
provider adapters direct database authority.

## Logical Units

Logical-unit identity is the core contract. Changes to extraction should
be conservative and tested against renames, moves, and refactors.

The current extractor is heuristic. Planned Tree-sitter-backed profiles
should replace extraction internals without changing the storage and
history contracts.

## UI And LSP

The UI and LSP should render evidence that Lineage has already ingested.
They should not run source analyzers, coverage tools, mutation tools, or
quality gates themselves.

When adding UI or LSP data, prefer extending structured storage/query
APIs first, then rendering those facts. Keep the UI usable without a
client-side application stack.

## Testing

Use `cargo test --manifest-path gems/lineage/Cargo.toml` for Lineage
changes. Tests should cover both the parser/adapter and the resulting
stored evidence whenever possible.
