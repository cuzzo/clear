# Lineage SQL-COV Test Bed

## Implemented slice

Lineage's architecture subsystem now embeds 15 standalone `.sql` files from
`gems/lineage/sql`. Lineage tests prepare those exact files against its real
SQLite schema. SQL-COV separately parses all 15 and executes
`architecture.owner_inventory.v1` against a focused fixture.

The generated reports live under `gems/sql-cov/coverage` (which is ignored as
build output):

- `lineage-owner-inventory.html`
- `lineage-owner-inventory.info`
- `lineage-owner-inventory.json`

## Result

The owner-inventory query produces:

- 7 top-level predicates discovered;
- 3 `WHERE` predicates measured;
- 4 `JOIN ... ON` predicates source-mapped but excluded as unsupported;
- 8 of 9 measurable branch states observed (88.9%).

The missing state is `UNKNOWN` for `n.artifact_id = ?1`. In the real Lineage
schema `artifact_id` is non-null, so that branch is unreachable. SQL-COV is
currently conservative and treats comparisons as nullable without consulting
schema metadata. This trial therefore validates telemetry counting while also
showing why schema-aware nullability is required before enforcing a strict
100% gate.

## Gaps exposed by the trial

1. Infer expression nullability from the database schema and operator rules.
2. Recurse into scalar subqueries and CTE query bodies; the current analyzer
   focuses on the outer `SELECT`.
3. Instrument `JOIN ... ON` over a semantics-preserving candidate-pair domain.
4. Instrument `HAVING` over the pre-filter aggregate-group domain.
5. Add typed CLI parameters instead of binding every `--param` as text.
6. Add PostgreSQL execution after the SQLite rewrite contract stabilizes.

These are reported as capability gaps, not as uncovered application branches.
