# SQL-COV

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

## Supported Dialects Roadmap

SQL-COV leverages dialect-specific frontends and live schema catalogs for exact type and nullability resolution.

- [x] **SQLite**: Fully supported (in-memory and file databases).
- [x] **PostgreSQL**: Fully supported (via connection string).
- [x] **MySQL / MariaDB**: Fully supported (via connection string).

## Boundaries

SQL-COV does not:
- Rewrite production queries;
- Prove that a query is optimal (e.g. index selection or CPU cost);
- Inject runtime instrumentation inside production application binaries;
- Execute without a mock/test database connection when running telemetry.

It resolves SQL branch correctness and maps condition domains.

## CI Integration

The recommended CI integration pattern is:
1. Extract `.sql` queries from ORM files or source code.
2. Spin up a temporary test database container during test suites.
3. Run `sql-cov run` passing the test database URL and parameter payloads.
4. Export the resulting LCOV/SARIF files into coverage dashboards or PR scanning tools.

## Links

- [CLEAR compiler](../../README.md)
- [Lineage](../lineage/README.md): CLEAR's verification and LLM review UI which ingests SQL-COV coverage records.
- [SlopCop](../slopcop/README.md): Categorizes uncovered branches and ranks true test gaps.
