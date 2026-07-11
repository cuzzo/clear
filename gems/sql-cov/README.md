# SQL-COV

SQL-COV measures SQL predicate outcomes as branches. For nullable predicates it
tracks SQL's three logical states independently: `TRUE`, `FALSE`, and
`UNKNOWN` (`NULL`). It emits versioned JSON, LCOV branch records, or a
standalone HTML report.

The first implementation supports SQLite execution and SQLite/PostgreSQL AST
analysis. It instruments predicates in a top-level `SELECT ... WHERE` over the
query's pre-filter row domain. `JOIN ... ON` and `HAVING` predicates are source
mapped and reported as instrumentation gaps, but are excluded from coverage
percentages until their telemetry can preserve query semantics.

SQL-COV also owns SQL-specific static hazards. The analyzer consults the live
SQLite schema before reporting nullable inequality, `NOT IN`, `NOT BETWEEN`,
`NOT`, `ANY`/`ALL`, nullable join keys, and outer-join null rejection. Proven
hazards are emitted separately as SARIF 2.1.0; unresolved schema facts remain
in the JSON report and do not become warnings.

## Run it

```sh
cargo run -- analyze \
  --input tests/fixtures/users_query.sql \
  --format json

cargo run -- run \
  --input tests/fixtures/users_query.sql \
  --setup tests/fixtures/users.sql \
  --format lcov
```

Run SQL-COV against the extracted Lineage architecture query:

```sh
cargo run -- run \
  --input ../lineage/sql/architecture/owner_inventory.sql \
  --setup tests/fixtures/lineage_architecture.sql \
  --param 1 \
  --param owner:1 \
  --format html \
  --output coverage/lineage-owner-inventory.html
```

Analyze schema-proven UNKNOWN hazards:

```sh
cargo run -- hazards \
  --input ../lineage/sql/architecture/owner_inventory.sql \
  --database /path/to/lineage.db \
  --format sarif \
  --output coverage/lineage-owner-inventory.sarif
```

LCOV output uses `BRDA` records for expression states. JSON retains
byte/line/column spans and raw counts for SQL-aware consumers.

The ownership boundary is intentional: SQL-COV derives SQL semantics and
produces coverage/SARIF artifacts. SlopCop may consume those artifacts for CI
policy, while Lineage ingests them as historical evidence; neither needs to
reimplement SQL parsing or schema nullability.

## Development

```sh
cargo test
```

The implementation plan is in
[`docs/agents/implementation-phases.md`](docs/agents/implementation-phases.md),
and the architectural blueprint is in
[`docs/agents/design.md`](docs/agents/design.md).
