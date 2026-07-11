# Lineage SQL

Production queries are stored as standalone files and embedded into Rust with
`include_str!`. The architecture subsystem is the first completed migration
slice. Its storage and UI queries have schema-backed prepare tests and a real
SQL-COV execution fixture. Remaining production SQL should migrate by
subsystem: storage core, quality, test exposure, SARIF, hazards, LSP, then the
general UI read model.

Every file begins with a stable `query-id`. Tests prepare and execute these exact
files; Rust must not carry a second copy of the query.

Dynamic identifier and variable-length list builders cannot be represented by
one static file. They should publish a small family of rendered `.sql` fixtures
covering each query shape instead.
