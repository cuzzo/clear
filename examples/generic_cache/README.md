# Generic O(1) LRU Cache

A self-checking exact LRU whose caller-selected `M: Map` supplies both
`M::Key` and `M::Value`. A hash-backed recency index plus a doubly-linked key
chain makes lookup, promotion, replacement, deletion, and eviction O(1).

One API body uses `WITH POLYMORPHIC` for plain, mutex, read/write-lock, and
MVCC-backed whole-cache bindings. Synchronizing the complete cache is
intentional: protecting only its value map would leave head, tail, and
recency metadata racy.

```bash
./clear test examples/generic_cache/cache.clear
```

The example instantiates String/Int64 and Int64/Bool maps, verifies hit
promotion and true least-recently-used eviction, runs concurrent writers
against the locked cache, and prints `PASS` only after all four capability
policies produce the expected result.
