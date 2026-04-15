# Pipelines and Higher-Order Functions

CLEAR's pipeline system lets you transform, filter, aggregate, and iterate collections using the smooth operator (`s>`). Every pipeline operator works on arrays, `@list`, `@pool`, sharded collections, and `@pool:soa` — the same syntax regardless of the underlying storage.

```ruby clear illustrative
scores s> WHERE _ > 50 s> SUM _;
entities s> EACH { _.health = _.health - 1.0; };
users s> SELECT _.name s> DISTINCT _;
```

This document describes both the collection pipeline model and the current stream/future pipeline surface. Stream support is intentionally narrower today than collection support.

## The Smooth Operator (`s>`)

`s>` pipes a value into a function or operator. It's CLEAR's equivalent of `|>` (Elixir) or `.` method chaining (Ruby), but it also works with collection operators.

```ruby clear illustrative
-- Pipe to a function: x s> f  →  f(x)
result = data s> process s> validate s> format;

-- Pipe to an operator: list s> WHERE predicate
alive = entities s> WHERE _.health > 0;
```

Pipelines chain left to right. Each stage passes its result to the next.

## The `_` Variable

Inside pipeline expressions, `_` refers to the current element. For struct elements, access fields with `_.fieldname`:

```ruby clear
-- _ is the element itself (for scalar collections)
nums: Float64[] = [1.0, 3.0, 7.0, 9.0];
big = nums s> WHERE _ > 5.0;
ASSERT length(big) == 2, "WHERE filters by element value";

-- _.field for struct collections
users = [User{name: "alice"}, User{name: "bob"}];
names = users s> SELECT _.name;

scores = [Score{value: 10.0}, Score{value: 20.0}];
total = scores s> SUM _.value;
ASSERT total == 30.0, "SUM aggregates field values";
```

In EACH blocks, `_` is mutable — you can assign to fields:

```ruby clear illustrative
pool s> EACH { _.health = _.health - damage; };
```

## Operators

### Transform

| Operator | Syntax | Returns | Description |
|---|---|---|---|
| **SELECT** | `list s> SELECT expr` | `ExprType[]` | Project each element through an expression |
| **WHERE** | `list s> WHERE pred` | `ElemType[]` | Keep elements matching a boolean predicate |
| **ORDER_BY** | `list s> ORDER_BY key` | `ElemType[]` | Sort by key expression |
| **LIMIT** | `list s> LIMIT n` | `ElemType[]` | First N elements |
| **SKIP** | `list s> SKIP n` | `ElemType[]` | Drop first N elements, return rest |
| **DISTINCT** | `list s> DISTINCT key` | `ElemType[]` | Unique by key (first occurrence wins) |
| **UNNEST** | `list s> UNNEST expr` | `InnerType[]` | Flatten nested arrays (flatmap) |
| **INDEX** | `list s> INDEX key` | `HashMap<ElemType[]>` | Group into a hashmap by key |

### Aggregate

| Operator | Syntax | Returns | Empty list |
|---|---|---|---|
| **SUM** | `list s> SUM expr` | `Float64` | 0 |
| **AVERAGE** | `list s> AVERAGE expr` | `Float64` | 0 |
| **MIN** | `list s> MIN expr` | `Float64` | panics |
| **MAX** | `list s> MAX expr` | `Float64` | panics |
| **REDUCE** | `list s> REDUCE(init) expr` | type of init | init |

Aggregate expressions must be numeric (Float64 or Int64). REDUCE is the general fold — `acc` is the mutable accumulator, `_` is the current element:

```ruby clear
nums: Float64[] = [2.0, 3.0, 4.0];
product = nums s> REDUCE(1.0) acc * _;
ASSERT product == 24.0, "REDUCE multiplies 2*3*4";
```

### Query

| Operator | Syntax | Returns | Description |
|---|---|---|---|
| **COUNT** | `list s> COUNT pred` | `Int64` | Number of matches |
| **ANY** | `list s> ANY pred` | `Bool` | True if any match (short-circuits) |
| **ALL** | `list s> ALL pred` | `Bool` | True if all match (short-circuits) |
| **FIND** | `list s> FIND pred` | `?ElemType` | First match or null |

### Side Effects

| Operator | Syntax | Returns | Description |
|---|---|---|---|
| **EACH** | `list s> EACH { body }` | `Void` | Iterate with mutable `_`; side-effect only |
| **TAP** | `list s> TAP { body }` | `ElemType[]` | Observe each element (read-only `_`), pass collection through |

EACH is the only operator where `_` is mutable. Use it for in-place updates:

```ruby clear illustrative
entities s> EACH { _.x = _.x + _.vx; _.y = _.y + _.vy; };
```

### TAP (Debugging / Observation)

TAP runs a body for each element but passes the collection through unchanged. Unlike EACH, `_` is read-only and TAP returns the original collection:

```ruby clear illustrative
result = scores
    s> WHERE _.points > 100
    s> TAP { print("score: ${_.points.toString()}"); }
    s> SUM _.points;
```

## Stream and Future Compatibility

Pipelines over futures/streams are currently supported in a narrower subset than pipelines over collections.

### Stream kinds

| Type | Meaning | `NEXT` result | Pipeline support |
|---|---|---|---|
| `~T` | Single future value | `T` | Not a pipeline source |
| `~?T[]` | Open stream | `?T` | Not a general pipeline source yet |
| `~T[INF]` | Infinite stream | `T` | Not a general pipeline source yet |
| `~T[]` | Finite stream (unbounded length) | `?T` | Supported for a subset of non-concurrent operators |
| `~T[N]` | Finite bounded stream | `?T` | Supported for the same non-concurrent subset, plus bounded `CONCURRENT EACH/SELECT/WHERE` |

### Finite stream operators

Finite streams currently support:

- `EACH`
- `SELECT`
- `WHERE`
- `SKIP`
- `TAKE_WHILE`
- `TAP`

Examples:

```ruby clear illustrative
s: ~Int64[] = 0 ..< 8;
s s> SELECT _ * 2 s> WHERE _ > 5 s> EACH { print(_); };

t: ~Int64[] = 0 ..< 10;
t s> SKIP 2 s> TAKE_WHILE _ < 6 s> EACH { print(_); };
```

Bounded finite streams (`~T[N]`) also support native concurrent pipelines for:

- `CONCURRENT EACH`
- `CONCURRENT SELECT`
- `CONCURRENT WHERE`

These paths are native stream pipelines:

- they consume bounded promise slots directly
- they do not materialize through `.toList()`
- they lower through MIR-visible builtin helper calls instead of raw pipeline Zig generation

Example:

```ruby clear illustrative
STRUCT Total {
    value: Float64
}

nums: ~Float64[4] = [BG { 1.0; }, BG { 2.0; }, BG { 3.0; }, BG { 4.0; }];
doubled = nums s> CONCURRENT(workers: 2) SELECT _ * 2.0;

total = Total{ value: 0.0 } @shared:locked;
nums s> CONCURRENT(workers: 2) EACH {
    WITH EXCLUSIVE total AS t {
        t.value = t.value + _;
    }
};
```

Current `CONCURRENT` limits for streams:

- only `~T[N]` is supported today
- direct range expressions still use the non-concurrent finite-stream path unless first bound as `~T[N]`
- `~T[]`, `~?T[]`, and `~T[INF]` do not yet support native `CONCURRENT`

Currently unsupported for finite streams:

- `SUM`
- `COUNT`
- `REDUCE`
- `LIMIT`
- `ORDER_BY`
- `DISTINCT`
- `UNNEST`
- `INDEX`
- `ANY`
- `ALL`
- `FIND`
- `AVERAGE`
- `MIN`
- `MAX`

Additionally unsupported for `~T[]` specifically:

- `CONCURRENT`

If you need the full collection operator surface, materialize explicitly first:

```ruby clear illustrative
s: ~Int64[] = 0 ..< 10;
vals = s.toList();
total = vals s> WHERE _ > 3 s> SUM _;
```

Open streams (`~?T[]`) and infinite streams (`~T[INF]`) are still `NEXT`-driven for now:

```ruby clear illustrative
gen: ~?Int64[] = BG STREAM {
    YIELD 1;
    YIELD 2;
};

v1 = NEXT gen;
v2 = NEXT gen;
v3 = NEXT gen;     -- NIL
```

### SKIP and LIMIT (Pagination)

SKIP and LIMIT are complementary: SKIP drops the first N elements, LIMIT takes the first N.

```ruby clear illustrative
-- Pagination: page 3, 10 items per page
page = items s> SKIP 20_i64 s> LIMIT 10_i64;

-- Skip header row, process the rest
data = rows s> SKIP 1_i64 s> SELECT parseRow(_);
```

## Chaining

Operators compose naturally:

```ruby clear illustrative
-- Filter, sort, take top 3
leaderboard = scores
    s> WHERE _.points > 100
    s> ORDER_BY _.points
    s> LIMIT 3;

-- Count active users with high scores
n = users
    s> WHERE _.active == TRUE
    s> COUNT _.score > 1000;
```

## Collection Compatibility

Every operator works on every collection type:

```ruby clear illustrative
-- Array
nums: Float64[] = [1, 2, 3];
total = nums s> SUM _;

-- List
MUTABLE data = List[];
avg = data s> AVERAGE _.value;

-- Pool
MUTABLE pool: Entity[1000]@pool = [];
alive = pool s> WHERE _.health > 0;

-- Pool with SOA (field-slice iteration — cache-optimal)
MUTABLE soa_pool: Entity[1000]@pool:soa = [];
total_hp = soa_pool s> SUM _.health;  -- iterates only the health array

-- List with SOA
MUTABLE soa_list: Entity[]@list:soa = [];
avg = soa_list s> AVERAGE _.health;   -- contiguous f64 slice

-- Sharded (parallel EACH via DO blocks)
MUTABLE sharded: Entity[10000]@pool:sharded(4) = [];
sharded s> EACH { _.processed = TRUE; };
```

## Loop Fusion

The compiler automatically fuses chains of WHERE and SELECT stages ending in a fold (SUM, REDUCE, AVERAGE, MIN, MAX, COUNT, ANY, ALL, FIND) into a single loop with zero intermediate allocations.

```ruby clear illustrative
-- Written as 3 stages:
result = data s> WHERE _ > 500.0 s> SELECT _ * _ s> SUM _;

-- Compiled as a single loop (no intermediate arrays):
-- for (data) |it| { if (it > 500) { sum += it * it; } }
```

This eliminates the allocation and iteration overhead of intermediate lists. Stages that require materialization (ORDER_BY, DISTINCT, INDEX) break the fusion chain - operations before them are fused separately.

## SOA Optimization

When a `@pool:soa` is used in a pipeline, the compiler rewrites field accesses to iterate directly over contiguous field arrays instead of striding over whole structs. This happens automatically for all operators — no syntax change needed.

```ruby clear
STRUCT Entity { x: Float64, y: Float64, vx: Float64, vy: Float64, health: Float64 }
MUTABLE pool: Entity[10000]@pool:soa = [];

-- SUM _.health iterates only the health array (contiguous f64[]).
-- Without :soa, it would load all 5 fields per element.
total = pool s> SUM _.health;
```

For WHERE and FIND, the predicate uses field-slice access (fast), and the struct is reassembled only for matching elements.

The compiler warns when SOA would help:

```
NOTE: Pipeline accesses 1 of 5 fields (health). Consider @soa
      for better cache performance on 'Entity'.
```

## Concurrency

The `CONCURRENT` modifier currently parallelizes collection pipelines for `SELECT`, `WHERE`, and `EACH`:

```ruby clear illustrative
MUTABLE data: Score[10000]@pool:sharded(4) = [];

-- Parallel WHERE: one fiber per shard
results = data s> CONCURRENT WHERE _.value > threshold;

-- With options
results = data s> CONCURRENT(size: LARGE) SELECT _.name;
```

Options: `pool_size: N` (fiber pool size), `pin: TRUE` (pin to cores), `size: MICRO|STANDARD|LARGE|XL` (stack size).

### `CONCURRENT` compatibility

| Source kind | `CONCURRENT SELECT` | `CONCURRENT WHERE` | `CONCURRENT EACH` |
|---|---|---|---|
| Arrays / `@list` / `@pool` / `@pool:soa` | Yes | Yes | Yes |
| `@sharded(...)` collections | Yes | Yes | Yes |
| Finite streams `~T[]` | Not yet | Not yet | Not yet |
| Bounded streams `~T[N]` | Runtime helpers landed; compiler integration in progress | Runtime helpers landed; compiler integration in progress | Runtime helpers landed; compiler integration in progress |
| Open streams `~?T[]` | Not yet | Not yet | Not yet |
| Infinite streams `~T[INF]` | Not yet | Not yet | Not yet |

So today:

- `CONCURRENT` is for collection sources.
- finite streams can participate in non-concurrent fused pipelines for the supported operators above.
- stream `CONCURRENT` will come later once the MIR-safe native lowering is in place.
