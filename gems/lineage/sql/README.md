# Lineage SQL

Production queries are stored as standalone files and embedded into Rust with
`include_str!`. Architecture queries live under `architecture/`; 42 core
storage statements live under `storage/`; and 29 dashboard/source read-model
queries live under `ui/runtime/`.

Lineage prepares the storage and UI corpus against its real SQLite schema.
SQL-COV parses and analyzes the executable corpus independently, while the
focused architecture fixture also executes queries for statement and
expression coverage. Schema and PRAGMA scripts remain standalone but are not
counted as expression-coverable queries.

Every file begins with a stable `query-id`. Tests prepare and execute these exact
files; Rust must not carry a second copy of the query.

Dynamic identifier and variable-length list builders cannot be represented by
one static file. They should publish a small family of rendered `.sql` fixtures
covering each query shape instead.
