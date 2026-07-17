# SQLite C FFI

This self-checking example talks directly to SQLite through CLEAR `EXTERN`
declarations. It has no Zig adapter: opaque handles, mutable out parameters,
NUL-terminated `String@c` values, target-sized C integers, native linking, and
free-function `CLOSE` cleanup all cross the C ABI directly.

```bash
./clear test examples/sqlite/main.clear
```

It creates an in-memory database, runs prepared statements, validates returned
data and a constraint error, and prints two `PASS` lines. `Database` and
`Statement` are finalized automatically in reverse lexical order.
