# ANY/ALL Coverage and Hazard Contract

SQL-COV treats `ANY`, its synonym `SOME`, and `ALL` as quantified strict
comparisons. The mandatory test matrix covers:

- `=`, `<>`, `!=` where supported, `<`, `<=`, `>`, and `>=`;
- nullable and required left operands;
- nullable and required subquery projections;
- PostgreSQL arrays with required, mixed, NULL-only, and NULL array inputs;
- empty sets, decisive true/false values, NULL-only sets, and mixed sets;
- PostgreSQL syntax and MySQL/MariaDB scalar column-subquery syntax.

The strict truth-table suite evaluates 288 combinations. `ANY` is false for an
empty set and becomes UNKNOWN only when no comparison is true and at least one
is UNKNOWN. `ALL` is true for an empty set and becomes UNKNOWN only when no
comparison is false and at least one is UNKNOWN. These rules follow the
[PostgreSQL quantified-array documentation](https://www.postgresql.org/docs/current/functions-comparisons.html)
and the
[MySQL quantified-subquery documentation](https://dev.mysql.com/doc/refman/8.0/en/any-in-some-subqueries.html).

## Known limits

1. PostgreSQL user-defined non-strict comparison operators can return a
   non-NULL result for NULL inputs. SQL-COV does not inspect operator catalog
   functions yet, so its schema rule assumes the standard strict comparison
   operators.
2. Static analysis cannot prove whether an arbitrary subquery is empty at
   runtime. Empty-set behavior is tested, but a nullable projected column is
   still reported as a potential UNKNOWN source when the subquery can return
   rows.
3. Derived-table and CTE output nullability is unresolved unless it maps back
   to a modeled base-table expression. Unresolved facts remain in JSON/SARIF
   run metadata and do not become warnings.
4. Flow-sensitive predicates inside a subquery, such as a prior `IS NOT NULL`
   filter proving its output non-null, are not yet used to refine projection
   nullability.
5. PostgreSQL arrays are supported; MySQL/MariaDB only allow scalar operands
   against one-column subqueries for `ANY`/`ALL`, matching their documented
   dialect restriction.

Environment-gated live tests execute against PostgreSQL and MySQL/MariaDB when
their database URLs are supplied. This repository environment has no live
servers, so those tests are compiled and discoverable but skip their database
body locally.
