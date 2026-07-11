# SQL-COV

SQL-COV measures SQL predicate outcomes as branches. For nullable predicates it
tracks SQL's three logical states independently: `TRUE`, `FALSE`, and
`UNKNOWN` (`NULL`). It emits versioned JSON, LCOV branch records, or a
standalone HTML report.

SQL-COV supports SQLite, PostgreSQL, and MySQL/MariaDB parsing, schema
introspection, statement execution, predicate telemetry, and hazard SARIF. It
instruments predicates in a top-level `SELECT ... WHERE` over the query's
pre-filter row domain. `JOIN ... ON` and `HAVING` predicates are source mapped
and reported as instrumentation gaps, but are excluded from coverage
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

PostgreSQL and MySQL/MariaDB use the same commands with `--dialect` and a
database URL:

```sh
cargo run -- run --dialect postgres \
  --database postgres://localhost/app_test \
  --input query.sql --param int:42

cargo run -- hazards --dialect mariadb \
  --database mysql://localhost/app_test \
  --input query.sql --format sarif
```

CLI parameters are typed as `int:42`, `float:1.5`, `bool:true`, or
`text:value`. Typed NULLs use `null:int`, `null:float`, `null:bool`, and
`null:text`; bare values remain text for compatibility.

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

Live database tests run when `SQL_COV_POSTGRES_URL`, `SQL_COV_MYSQL_URL`, or
`SQL_COV_MARIADB_URL` is set. Without those variables, parser, instrumentation,
schema-model, and truth-table tests still run, while live tests return early.

The implementation plan is in
[`docs/agents/implementation-phases.md`](docs/agents/implementation-phases.md),
and the architectural blueprint is in
[`docs/agents/design.md`](docs/agents/design.md).
