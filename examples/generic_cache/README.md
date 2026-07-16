# Generic Cache

A self-checking example of CLEAR's bind-time synchronization. One generic
`put!<T>` body uses `WITH POLYMORPHIC` with local, mutex, read/write-lock, and
MVCC-backed `Cache<T>` bindings. A separate sharded map demonstrates that
sharding is a storage topology rather than another outer lock policy.

```bash
./clear test examples/generic_cache/cache.clear
```

The example also instantiates `Cache<T>` for both `Int64` and `Bool`, performs
concurrent writes against four shards, asserts every result, and prints two
`PASS` lines only after all checks succeed.
