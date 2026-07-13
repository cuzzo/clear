# SQL-COV Implementation Phases

## Current implementation status

| Phase | Status | Evidence |
| --- | --- | --- |
| 1 — parser/source map | Implemented | Nested expression span tests; SQLite, PostgreSQL, and MySQL/MariaDB parser selection |
| 2 — instrumentation | Implemented for top-level `SELECT ... WHERE` in all three launch dialects | TRUE/FALSE/UNKNOWN fixture oracle and compiled live-driver suites |
| 3 — reports | Implemented | `sql-cov/v1` JSON, LCOV `BRDA`, standalone highlighted HTML |
| 4 — real-query harness | Implemented for Lineage's architecture subsystem | All 15 files independently parse, prepare, and execute through SQL-COV |
| 5 — cross-dialect execution | Driver complete; live CI environments required | PostgreSQL and MySQL/MariaDB pools, setup, typed parameters, schema loaders, telemetry, and environment-gated live tests |
| SQL hazard analysis | Implemented for the initial UNKNOWN catalog | Three-dialect schema validation, exhaustive quantified-comparison tests, and SARIF 2.1.0 output |

JOIN and HAVING expressions are discovered and source-mapped, but marked
unmeasurable and excluded from branch percentages. This avoids claiming a
false test miss while their semantics-preserving instrumentation remains open.

## Phase 1: Parse and locate expressions

- Build the Rust crate and CLI.
- Support SQLite and PostgreSQL parser dialect selection.
- Discover boolean expressions in `WHERE`, `HAVING`, and `JOIN ... ON` clauses.
- Assign deterministic IDs and byte/line/column spans.
- Emit a machine-readable expression manifest.

Acceptance: repeated and nested expressions retain distinct source spans.

## Phase 2: Instrument SQLite execution

- Generate a telemetry query for supported `SELECT` statements.
- Evaluate every tracked expression over the pre-filter row domain.
- Count TRUE, FALSE, and UNKNOWN independently.
- Preserve the original query as the behavior-under-test.
- Reject unsupported rewrites explicitly instead of silently changing semantics.

Acceptance: nullable predicates and compound predicates produce correct ternary counts.

## Phase 3: Coverage formats and UI

- Define versioned `sql-cov/v1` JSON.
- Emit LCOV branch records, using three branches per nullable SQL expression.
- Render standalone HTML with expression-level source highlighting.
- Mark complete, partial, uncovered, and UNKNOWN-observed states.

Acceptance: LCOV is accepted by standard LCOV consumers and HTML maps metrics to source spans.

## Phase 4: Test harness and real queries

- Add fixture databases and expected coverage oracles.
- Test nested predicates, NULL, `BETWEEN`, `IN`, outer joins, and empty inputs.
- Extract Lineage SQL into standalone embedded files.
- Run the same files directly in SQLite contract tests and through SQL-COV.
- Record unsupported query shapes as explicit coverage gaps.

Acceptance: Lineage uses the exact `.sql` files tested independently, and SQL-COV reports partial/branch coverage for representative Lineage queries.

## Phase 5: Cross-dialect expansion

- Add PostgreSQL execution through `sqlx` without weakening SQLite tests.
- Add dialect-specific instrumentation strategies.
- Integrate the SQL hazard and semantic-witness model described in Lineage's SQL design.
- Add mutation testing for NULL and join-cardinality hazards.

PostgreSQL and MySQL/MariaDB driver code is implemented. Live tests require
`SQL_COV_POSTGRES_URL`, `SQL_COV_MYSQL_URL`, or `SQL_COV_MARIADB_URL`; this
workspace has no corresponding server, so database-backed execution was not
run locally. Mutation testing and additional dialect-specific JOIN/HAVING
strategies remain future work.
