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

Inspect the unit-level signal:

```sh
cargo run --manifest-path gems/lineage/Cargo.toml -- summary \
  --db /tmp/lineage.db \
  --top 20 \
  --only src/ \
  --only gems/ \
  --only zig/
```

The extractor boundary is deliberately separate from storage and VCS
traversal so Tree-sitter-backed language profiles can replace the
bootstrap extractor without changing Boobytrap's database contract.
