# SQL as a First-Class Analyzable Artifact

## Status

Proposed architecture. This document does not require moving Gigasail's current
inline SQL immediately. New and materially changed queries should follow this
layout, and existing queries can migrate incrementally.

## Decision

Store production SQL in standalone `.sql` files, embed those files into Rust at
compile time, and test the same files directly against database fixtures.

Rust's built-in `include_str!` is the appropriate default:

```rust
const OWNER_INVENTORY_SQL: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/sql/queries/architecture/owner_inventory.sql"
));
```

This keeps deployment simple—the binary still contains the query—while making
the SQL independently readable, executable, lintable, explainable, and
testable. Rust owns parameter binding and decoding; the `.sql` file owns the
relational program.

Do not construct structural SQL with string concatenation. Dynamic identifiers
or optional clauses should use a small, reviewed query builder or a bounded set
of complete query files. Values remain bound parameters.

## Proposed Layout

```text
gems/gigasail/sql/
  schema/
    001_core.sql
    002_architecture.sql
  queries/
    architecture/
      owner_inventory.sql
      node_neighborhood.sql
      state_access.sql
      search.sql
    coverage/
    hazards/
    history/
  fixtures/
    minimal.sql
    null_semantics.sql
    join_cardinality.sql
    architecture.sql
  tests/
    architecture/
      owner_inventory.case.json
      state_access.case.json
  hazards/
    rules.json
    suppressions.json
  plans/
    sqlite/
```

Each query should begin with machine-readable comments:

```sql
-- query-id: architecture.owner_inventory.v1
-- dialect: sqlite
-- params: artifact_id:integer, owner_id:text
-- result: node_id:text!, kind:text!, score:real?
-- cardinality: many
-- invariants: one-row-per-analyzer-node
```

The metadata may later move to a sidecar manifest, but the query ID must remain
stable. Gigasail events, hazards, plans, and tests should refer to the ID rather
than a Rust function name.

## Independent Query Tests

Use three layers. They catch different failures and should not be collapsed
into one Rust integration test.

### 1. Engine-level SQL cases

Run schema, fixture, and query files directly through the target database
engine. For SQLite, the basic runner can use `sqlite3` or a small Rust test
binary backed by `rusqlite`. The query text must be read from the `.sql` file,
not copied into the test.

A case file supplies:

- query ID and dialect;
- fixture files;
- named parameter values;
- expected rows, unordered rows, scalar, or expected error;
- expected column names and nullability;
- required transaction mode;
- optional query-plan assertions.

Golden rows are appropriate for stable report queries. Property assertions are
better for large result sets: uniqueness, conservation of counts, endpoint
closure, monotonicity, or equivalence to a deliberately simple reference query.

### 2. Rust contract tests

Rust tests verify the boundary rather than SQL semantics:

- every embedded query ID exists exactly once;
- parameter names/types match the binder;
- result columns match the decoder;
- nullable SQL columns map to `Option<T>`;
- read queries do not mutate the database;
- replacement/import queries are atomic;
- the Rust wrapper executes the exact embedded file tested independently.

Prefer row structs with named-column decoding for durable APIs. Positional
decoding is acceptable only for very small private queries and should still
have a column-contract test.

### 3. Repository workflow tests

Exercise query results through the public Gigasail API and UI. These tests cover
scope, artifact freshness, logical-unit reconciliation, pagination, and HTML or
JSON presentation. They should not be the first place where NULL or JOIN
semantics are tested.

## Fixture Matrix

Every nontrivial query should be exercised against a small relational matrix:

- empty database;
- one matching row;
- multiple matching rows;
- duplicate relationship evidence;
- NULL on each nullable input independently;
- unmatched left and right join rows;
- one-to-one, one-to-many, and many-to-many joins;
- stale and current artifact versions;
- moved/renamed logical units;
- transaction rollback after an injected failure;
- boundary values for timestamps, line numbers, scores, and limits.

Fixtures should be composable and minimal. A test that needs one nullable join
should not load a production-sized dump.

## SQL Hazard Analyzer

The motivating hazard family is hidden control flow caused by three-valued
logic and join cardinality. The initial catalog should cover the cases described
in [An Ode to SQL](https://cuzzo.github.io/clear/blog/an-ode-to-sql/):

1. Nullable expressions compared with `!=` or `<>` without an explicit NULL
   policy.
2. `NOT IN` where the left expression or subquery/list may contain NULL.
3. `NOT BETWEEN` over nullable operands.
4. `NOT`, `ANY`, or `ALL` expressions whose UNKNOWN result can reject rows.
5. A `LEFT JOIN` followed by a null-rejecting `WHERE` predicate on the optional
   side, unintentionally turning it into an inner join.
6. A subsequent join or filter that consumes NULLs introduced by an outer join.
7. Nullable join keys without an explicit equality/null policy.
8. Join cardinality that can multiply rows when downstream code assumes one
   row per entity.
9. Aggregates whose NULL behavior changes the result, including `COUNT(column)`
   versus `COUNT(*)` and nullable arithmetic.
10. Anti-joins expressed with nullable `NOT IN` where `NOT EXISTS` or an
    explicit NULL-aware predicate would make the policy visible.

The analyzer must not blindly declare these constructs incorrect. It should
emit:

- the potentially nullable expression and how nullability was established;
- the hidden TRUE/FALSE/UNKNOWN branch;
- the join side and cardinality involved;
- a source span;
- confidence and unresolved schema facts;
- safe alternatives appropriate to the dialect, without rewriting
  automatically.

### Fact model

FactMine should eventually emit language-neutral SQL facts:

```text
query definitions and statement spans
tables, aliases, columns, and CTEs
schema-derived and expression-derived nullability
joins, join type, predicates, and key pairs
filters and predicate operators
subqueries and correlation
grouping and aggregates
projected columns and aliases
estimated relationship cardinality
parameters and host-language call sites
```

SQL embedded in Ruby, Rust, Go, Zig, configuration, migrations, or heredocs
should point back to both the SQL span and the host-language span.

## Determining Whether a Hazard Is Adequately Tested

Code coverage alone cannot show that UNKNOWN behavior was tested. The test
system needs semantic witnesses.

For every reported hazard, derive a required witness matrix. For example, a
nullable `LEFT JOIN` filter generally requires:

```text
matching right row satisfying predicate
matching right row failing predicate
no matching right row
matching right row with predicate column NULL
duplicate matching right rows when cardinality is not proven one-to-one
```

Test cases declare which fixture rows and expected outcomes they cover. The SQL
test runner records query ID, hazard ID, fixture witness IDs, and assertion
results. Gigasail can then distinguish:

- hazard not exercised;
- SQL statement executed but NULL witness absent;
- witness present but output not asserted;
- semantic witness asserted and passing;
- mutation proved the assertion detects the hazard.

The strongest check is SQL mutation testing. Generate constrained mutations
such as:

- `LEFT JOIN` ↔ `INNER JOIN`;
- move an optional-side predicate between `ON` and `WHERE`;
- `=` ↔ `<>`;
- `IN` ↔ `NOT IN`;
- remove `IS NULL`/`IS NOT NULL` branches;
- `COUNT(*)` ↔ `COUNT(column)`;
- remove `DISTINCT`;
- change a join key or drop one part of a composite key.

A test is mutation-adequate for a hazard only when the relevant mutation is
killed. Surviving mutations are evidence of a weak assertion or an equivalent
query and must be reviewed, not automatically counted as failure.

## Query Plan and Performance Tests

Correct results are necessary but insufficient for persistent analytical
queries. Record normalized `EXPLAIN QUERY PLAN` output for critical SQLite
queries and assert semantic properties rather than unstable plan text:

- expected index is available and selected for large endpoint lookups;
- no full scan of an unbounded event/edge table;
- correlated subqueries do not create an accidental per-row repository scan;
- sort and temporary B-tree use is intentional;
- result limits are applied after the correct semantic ordering.

Keep small correctness fixtures separate from generated scale fixtures. Plan
tests need realistic row distributions because optimizers make decisions from
cardinality and statistics.

## Cross-Tool Test Bed

The same SQL corpus can exercise the sibling tools without blurring ownership:

| Tool | Responsibility |
| --- | --- |
| FactMine | Parse SQL and emit normalized definitions, predicates, joins, nullability, aggregates, cardinality clues, and exact spans. |
| Decomplex | Score hidden control-flow/state pressure from ternary predicates, correlated subqueries, join meshes, aggregation stages, and procedural SQL. |
| Espalier | Project table/view/procedure dependencies, query-to-table effects, ownership boundaries, and architecture pressure. |
| SlopCop | Report actionable SQL hazards and policy violations from FactMine facts. |
| Boobytrap | Capture runtime query identity, observed parameter/null/cardinality shapes, latency, errors, and production witnesses without recording sensitive values. |
| Gigasail | Join query identity to history, tests, hazards, runtime evidence, mutations, ownership, and artifact freshness; present review queues and source navigation. |

The corpus should contain:

- one minimal positive and negative example per hazard;
- dialect variants where semantics differ;
- schema plus seed data;
- expected FactMine facts;
- expected SlopCop findings;
- expected Decomplex components;
- expected Espalier dependency edges;
- SQL test cases and mutations;
- sanitized Boobytrap observation fixtures;
- Gigasail import/API/UI expectations.

Each example needs a stable corpus ID so results from every tool can be joined
without parsing messages.

## Dialects

Start with SQLite because Gigasail already embeds it and can run fixtures without
external services. Keep the public fact schema dialect-neutral, but never assume
all SQL semantics are identical.

Add PostgreSQL, MySQL, or other dialect suites only with their actual engines in
CI. Parser acceptance is not evidence of runtime semantic parity. Query metadata
must declare its dialect, required extensions, and minimum engine capabilities.

## Migration Plan

1. Move the new architecture queries into `gems/gigasail/sql/queries` without
   changing behavior.
2. Add query IDs, parameter/result contracts, and direct fixture tests.
3. Move other high-risk multi-join and aggregation queries incrementally.
4. Add the NULL/join/cardinality fixture matrix.
5. Add a FactMine SQL fact schema and oracle corpus.
6. Implement conservative hazard rules with explicit confidence.
7. Record semantic witnesses and connect them to Gigasail test exposure.
8. Add constrained SQL mutation testing.
9. Expand to runtime observations and additional dialect engines.

## Acceptance Criteria

- Production Rust embeds the exact `.sql` files exercised by direct tests.
- Every migrated query has a stable ID and parameter/result contract.
- NULL, unmatched-row, and cardinality fixtures cover every relevant query.
- Critical queries have plan assertions and scale fixtures.
- SQL hazards include source spans, confidence, and required semantic witnesses.
- Test adequacy distinguishes execution coverage from asserted NULL/cardinality
  behavior and mutation evidence.
- Cross-tool fixtures join by stable IDs rather than human-readable messages.
