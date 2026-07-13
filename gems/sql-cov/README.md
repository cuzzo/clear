# SQL-COV
[![CI Status](https://github.com/cuzzo/clear/actions/workflows/ci.yml/badge.svg)](https://github.com/cuzzo/clear/actions/workflows/ci.yml)

SQL-COV measures SQL predicate outcomes as branches. For nullable predicates it tracks SQL's three logical states independently: `TRUE`, `FALSE`, and `UNKNOWN` (`NULL`). It emits versioned JSON, LCOV branch records, or a standalone HTML report.

Linters and static analyzers help you find syntactic errors. SQL-COV performs dynamic and schema-aware analysis to map the exact branch coverage of query conditions and join constraints.

- See [design.md](docs/agents/design.md) for the architectural blueprint.
- See [implementation-phases.md](docs/agents/implementation-phases.md) for the development roadmap.

## Getting Started

If you want to contribute, see [CONTRIBUTING.md](../../CONTRIBUTING.md).

### Prerequisites

- **Rust / Cargo** (for building/running)
- **SQLite** (for local/in-memory SQLite queries)
- **PostgreSQL** or **MySQL/MariaDB** (optional, for live database tests and telemetry runs)

### Installation

From this repository:

```bash
cargo build --release
```

## Run It

### Basic AST analysis
Analyze the query syntax and map its potential coverage branches without executing:

```bash
cargo run -- analyze \
  --input tests/fixtures/users_query.sql \
  --format json
```

### In-Memory SQLite Coverage
Run a query and record coverage against a local SQLite database setup:

```bash
cargo run -- run \
  --input tests/fixtures/users_query.sql \
  --setup tests/fixtures/users.sql \
  --format lcov
```

### Live Database Coverage (PostgreSQL / MySQL)
Run coverage against external databases using connection strings and typed CLI parameters:

```bash
cargo run -- run --dialect postgres \
  --database postgres://localhost/app_test \
  --input query.sql \
  --param int:42 \
  --param text:admin
```

### Analyze Static Hazards
Inspect SQL code for implicit nullability traps and output SARIF:

```bash
cargo run -- hazards --dialect postgres \
  --database postgres://localhost/app_test \
  --input query.sql \
  --format sarif \
  --output coverage/query-hazards.sarif
```

### Analyze Query-Plan Complexity

SQL-COV owns database-specific plan analysis. The `plan` command asks the selected
database for a structured `EXPLAIN`, composes nested operator costs, and emits one
provider-neutral `complexity.observation` per query plus operator warnings:

```bash
cargo run -- plan --dialect postgres \
  --database postgres://localhost/app_test \
  --input queries/ \
  --setup tests/schema.sql \
  --param int:42 \
  --output coverage/query-plans.sarif
```

SQLite, PostgreSQL, and MySQL use their native plan formats rather than parsing a
shared text approximation. `--param` values are bound with their declared types;
SQL-COV does not replace parameters with `NULL`. A leading
`-- query-id: stable.name` comment supplies the observation identity.

### Looker/LookML & Schema-Inferred JOIN Hazards
You can detect double-counting (fan-out) hazards caused by joining one-to-many relationships and aggregating one-side columns without deduplication. SQL-COV does this in two ways:

1. **Schema-Inferred (Automatic)**: If a query joins two tables where one table is joined on its **Primary Key** and the other is not, SQL-COV automatically infers a one-to-many join relationship. No additional configuration is required.
2. **LookML Integration**: If you are using Looker, pass the path to a LookML model file using the `--looker-hazards` flag to evaluate explicitly defined `one_to_many` relationships:

```bash
cargo run -- hazards --dialect postgres \
  --database postgres://localhost/app_test \
  --input query.sql \
  --looker-hazards path/to/model.lkml \
  --format sarif \
  --output coverage/query-hazards.sarif
```

LookML relationships defined as `one_to_many` are evaluated. For example, if a LookML file contains:

```lkml
explore: companies {
  join: employees {
    relationship: one_to_many
    sql_on: ${companies.company_id} = ${employees.company_id} ;;
  }
}
```

And your query is:

```sql
SELECT SUM(companies.annual_revenue)
FROM companies
JOIN employees ON companies.company_id = employees.company_id
```

SQL-COV will flag this as a `LookerJoinHazard` because `annual_revenue` (from the one-side table `companies`) is aggregated using `SUM` without a `DISTINCT` modifier, causing values to be double-counted.

To resolve the hazard, use a `DISTINCT` modifier or pre-aggregate in an inline subquery:

```sql
SELECT SUM(DISTINCT companies.annual_revenue)
FROM companies
JOIN employees ON companies.company_id = employees.company_id
```

### Generate Check Queries for Hazards
For any finding identified during the static hazard analysis, you can generate check queries to verify if `NULL` values actually exist in the table, and receive DDL suggestions to safely update the column to `NOT NULL` if the table is free of nulls:

```bash
cargo run -- generate-check --dialect postgres \
  --database postgres://localhost/app_test \
  --input query.sql \
  --id <FINDING_ID>
```

> [!NOTE]
> If the query check return count is `0`, you can safely apply a schema migration to enforce `NOT NULL` on the target column, permanently resolving the hazard:
> - **PostgreSQL**: `ALTER TABLE <table> ALTER COLUMN <column> SET NOT NULL;`
> - **MySQL / MariaDB**: `ALTER TABLE <table> MODIFY <column> <datatype> NOT NULL;`
> - **SQLite**: SQLite does not support direct column alteration; you must rebuild the table structure or use a temporary table rename sequence.

## CLI Parameters

Parameters passed to `--param` must be typed to ensure correct query binding:
- Primitives: `int:42`, `float:1.5`, `bool:true`, `text:value`
- Nulls: `null:int`, `null:float`, `null:bool`, `null:text`
- Bare values are treated as text by default for backwards compatibility.

## Outputs

SQL-COV generates outputs matching standard coverage and static analysis specifications:

- **JSON**: Comprehensive report containing byte/line/column spans, raw hit counts, and nullability profiles for downstream ingestion.
- **LCOV**: Emits standard `BRDA` branch records, enabling integration with visualization tools like Codecov, Coveralls, or local HTML frontends.
- **HTML**: Self-contained, premium interactive report highlighting SQL syntax, branch outcomes (True/False/Unknown), and coverage warnings.
- **SARIF**: Emits SARIF 2.1.0 records representing static hazard findings for GitHub Code Scanning and IDE gutter integrations.
- **Plan SARIF**: Emits `sql-cov.plan.sarif.v1`; Lineage stores and presents its
  canonical time/auxiliary-space observations without re-analyzing SQL.

## Supported Dialects Roadmap

SQL-COV leverages dialect-specific frontends and live schema catalogs for exact type and nullability resolution.

- [x] **SQLite**: Fully supported (in-memory and file databases).
- [x] **PostgreSQL**: Fully supported (via connection string).
- [x] **MySQL / MariaDB**: Fully supported (via connection string).

## Boundaries

SQL-COV does not:
- Rewrite production queries;
- Prove that a query is globally optimal or predict constant-factor CPU/IO cost;
- Inject runtime instrumentation inside production application binaries;
- Execute without a mock/test database connection when running telemetry.

It resolves SQL branch correctness, maps condition domains, and derives
asymptotic estimates from the database-selected plan.

## CI Integration

SQL-COV is fully integrated into this project's GitHub Actions workflow to scan for SQL hazards and three-valued logic bugs automatically.

### Workflow Configuration

The scan is executed in the `generalized-gems-sarif` job within [.github/workflows/ci.yml](../../.github/workflows/ci.yml):

```yaml
      - name: Build Rust binaries
        run: |
          cargo build --release --manifest-path gems/sql-cov/Cargo.toml
          
      - name: Generate sql-cov SARIF
        run: |
          ./tools/generate_sql_cov_sarif.rb \
            --repo=. \
            --out-dir=tmp/generalized-gems-sarif \
            --setup=gems/lineage/sql/storage/init_schema.sql \
            --sql-cov-bin=./gems/sql-cov/target/release/sql-cov

      - name: Upload SQL-cov SARIF
        uses: github/codeql-action/upload-sarif@v4
        with:
          sarif_file: tmp/generalized-gems-sarif/sql-cov.sarif
          category: sql-cov
```

The resulting SARIF report is uploaded directly to GitHub Code Scanning to present alerts on PRs.

## Links

- [CLEAR compiler](../../README.md)
- [Lineage](../lineage/README.md): CLEAR's verification and LLM review UI which ingests SQL-COV coverage records.
- [SlopCop](../slopcop/README.md): Categorizes uncovered branches and ranks true test gaps.
