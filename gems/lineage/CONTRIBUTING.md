# Contributing To Lineage

Start with the repository-level [../../CONTRIBUTING.md](../../CONTRIBUTING.md).
This file only covers Lineage-specific architecture and contribution
rules.

## Local Development Setup

See [Get Started](README.md#getting-started).

Common checks:

```sh
cargo test --manifest-path gems/lineage/Cargo.toml
cargo build --manifest-path gems/lineage/Cargo.toml --release
```

## Architecture

Lineage is a Rust history and evidence engine with deliberately separate
boundaries:

- `src/vcs.rs` and `src/git.rs` own repository traversal.
- `src/extract.rs` owns logical-unit extraction behind the
  `BoundaryExtractor` trait.
- `src/storage.rs` owns the SQLite schema and writes.
- `src/engine.rs` compares commit snapshots and records history events.
- `src/quality.rs`, `src/test_exposure.rs`, `src/mutant.rs`,
  `src/hazard.rs`, `src/stack_trace.rs`, and `src/sarif.rs` ingest
  verification evidence.
- `src/ui.rs` renders the local source-review UI.
- `src/lsp.rs` exposes editor diagnostics and CodeLens data.

Keep these boundaries intact. Provider-specific parsing should not write
directly to the database; Lineage core should verify commits, paths, and
logical-unit identity before recording evidence.

## Boundaries

Lineage should track evidence over time and make that evidence easy to
query. It should not become a replacement for mature tools that already
solve their own domain.

- Linting and smells are solved problems. Import them as SARIF or another
  normalized artifact format instead of building custom lint or smell
  engines in Lineage.
- Static risk tools such as Decomplex, SlopCop, Boobytrap, Nil-Kill, and
  Espalier should publish SARIF or normalized artifacts. Lineage should
  preserve, scope, and display those findings.
- Coverage, test exposure, mutant evidence, hazards, and crash data should
  be commit-scoped and idempotent on re-ingest.
- Language-specific parsing should stay behind extractor/provider
  boundaries. Do not special-case Ruby, Zig, or another language in the
  storage, UI, or LSP layers.

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

## Change Standards

- Schema changes need tests that prove both new databases and migrated
  databases work.
- Ingestion changes need fixture coverage for idempotency and `--replace`
  behavior when applicable.
- UI changes should keep the source viewer usable without requiring
  client-side JavaScript for core navigation and inspection.
- Performance changes should include a before/after command or fixture
  that exercises a large file or large history.

## Testing

Use `cargo test --manifest-path gems/lineage/Cargo.toml` for Lineage
changes. Tests should cover both the parser/adapter and the resulting
stored evidence whenever possible.
