# LiteDB: Compiler Stress Test

LiteDB is a concurrent B-Link tree key-value store built in CLEAR. It targets the least-tested compiler paths: `@shared` (6 tests), `@locked` (5 tests), `@indirect` (3 tests), `@multiowned` (7 tests), DO blocks (2 tests), enums (2 tests), lambdas (2-9 tests), and generic+capability combinations (0 tests).

## 1. Core Architecture

B-Link tree index with `@shared:locked` nodes. No WAL - verification is in-memory.

```ruby
ENUM Op { Get, Put, Delete, Scan }

STRUCT Node {
    keys: Int64[]@list,
    vals: String[]@list,
    children: Node@shared:locked[]@list,
    next: Node@shared:locked?,
    isLeaf: Bool
}

STRUCT LiteDB {
    root: Node@shared:locked,
    config: { maxKeys: Int64 }
}
```

### Query Expressions

Recursive union with `@indirect` for filter predicates:

```ruby
UNION QueryExpr {
    All,
    Eq { key: Int64 },
    Range { lo: Int64, hi: Int64 },
    And { left: QueryExpr @indirect, right: QueryExpr @indirect },
    Or { left: QueryExpr @indirect, right: QueryExpr @indirect }
}
```

## 2. Language Features Under Stress

| Feature | Tests | Stress Case | Bug Target |
| :--- | :--- | :--- | :--- |
| `@shared` (Arc) | 6 | Node refs passed between fibers during traversal | Atomic ref-count races |
| `@locked` (RwLock) | 5 | Latch-coupling: hold child lock, release parent | Premature release in WITH blocks |
| `@indirect` (Box) | 3 | Recursive QueryExpr union | Incorrect box alloc/free in unions |
| `@multiowned` (Rc) | 7 | Shared query result sets across consumers | Rc cleanup on multiple drop paths |
| DO blocks | 2 | Batch insert with join barrier | Join semantics / fiber sync |
| ENUM types | 2 | Op dispatch (Get/Put/Delete/Scan) | Exhaustive match, enum in structs |
| Lambda callbacks | 2-9 | `scan(filter_fn)` predicates | Closure capture/escape bugs |
| Generics + caps | 0 | `ResultSet<T>@multiowned` | Capability wrapping on generic instantiation |
| Nested BG | 0 | Range scan spawns sub-fibers per subtree | Stack corruption in nested fiber spawning |
| REDUCE | 3 | Aggregation over scan results | Pipeline fusion with iterator |
| GIVE/TAKES | 7 | Ownership transfer of query results | Move semantics across fiber boundaries |

## 3. Query Layer

No SQL. CLEAR pipelines + lambda callbacks:

```ruby
-- Lambda scan with filter
results = db.scan(QueryExpr{ Range: { lo: 10, hi: 50 } })
    s> WHERE fn(kv) -> kv.key % 2 == 0; END
    s> SELECT _.val
    s> REDUCE("") acc + _ + ",";

-- Aggregation
count = db.scan(QueryExpr{ All })
    s> REDUCE(0_i64) acc + 1;
```

## 4. Verification Strategy

### A. Sum-of-Integers (Concurrency)
1. Spawn 8 BG fibers.
2. Each inserts keys 1..N with value = `toString(key)`.
3. After join, scan all keys and REDUCE to compute sum.
4. ASSERT sum == N*(N+1)/2. Any deviation = memory visibility or lock bug.

### B. Leak Check (Ownership)
Run under `./clear test` with leak detection.
- Tree splits create/destroy `@shared` nodes. Missed ref-count = leak detector fires.
- `@multiowned` result sets must be fully cleaned up after use.

### C. DO Block Barrier (Concurrency)
1. DO block with 4 branches, each inserting a known key.
2. After DO, all 4 keys must be present. Missing key = broken join barrier.

## 5. Implementation Plan (6 Commits)

### Commit 1: Core types + single-threaded insert/search
- ENUM Op, STRUCT Node, STRUCT LiteDB
- `insert!()` into leaf (no splits yet, fixed small tree)
- `search()` by key
- 10+ assertions in main()
- **Exercises:** enums, structs with list fields, basic control flow

### Commit 2: Node splitting + tree growth
- `splitChild!()` when node exceeds maxKeys
- Root splits create new root (tree grows upward)
- Test with enough inserts to trigger multiple splits
- **Exercises:** complex mutation, list manipulation, struct creation in loops

### Commit 3: @shared:locked + concurrent reads/writes
- Wrap nodes in `@shared:locked`
- WITH EXCLUSIVE / WITH blocks for access
- BG fibers doing concurrent inserts
- DO block for batch insert barrier
- **Exercises:** @shared, @locked, WITH blocks, BG, DO, latch-coupling

### Commit 4: Query layer with @indirect union + lambdas
- UNION QueryExpr with @indirect recursive variants
- `scan()` function that traverses tree with QueryExpr filter
- Lambda callback support for custom predicates
- Pipeline operators (WHERE, SELECT, REDUCE) on scan results
- **Exercises:** @indirect, lambdas/closures, pipelines, REDUCE, GIVE/TAKES

### Commit 5: @multiowned results + nested BG + generics
- `ResultSet<T>@multiowned` for shared query results
- Range scan spawns sub-fibers per subtree (nested BG)
- Multiple consumers read same result set
- **Exercises:** @multiowned, generics+capabilities, nested BG, TAKES

### Commit 6: Verification harness
- Sum-of-integers concurrent test (8 fibers, N=1000)
- DO block barrier test (4 branches)
- Leak check via `./clear test`
- Print pass/fail summary
- **Exercises:** full integration stress test
