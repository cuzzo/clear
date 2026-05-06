# Pipelines and Higher-Order Functions

CLEAR's pipeline system lets you transform, filter, aggregate, and iterate collections using the smooth operator (`|>`).

Every pipeline operator works on arrays, `@list`, `@pool`, sharded collections, `@pool:soa`, streams `~T[]`, etc - the same syntax regardless of the underlying storage.

`_` is the placeholder value for the value being iterated over.

```ruby clear illustrative
scores
  |> WHERE _ <= 50 
  |> SUM _;

users 
  |> SELECT _.name 
  |> DISTINCT _;
  
entities 
  |> EACH { _.health = _.health - 1.0; };
```

This document describes both the collection pipeline model and the stream/future pipeline surface. The full operator set is supported for finite streams (`~T[]`, `~T[N]`); infinite streams (`~T[INF]`) require `LIMIT` to bound them and then support all non-materialization operators.

## The Smooth Operator (`|>`)

`|>` pipes a value into a function or operator. It's CLEAR's equivalent of `|>` (Elixir) or `.` method chaining (Ruby), but it also works with collection operators.

```ruby clear illustrative
-- Pipe to a function: x |> f  →  f(x)
result = data 
  |> process 
  |> validate
  |> format;

-- Pipe to an operator: list |> WHERE predicate
alive = entities 
  |> WHERE _.health > 0;
```

Pipelines chain left to right. Each stage passes its result to the next.

## Named Pipeline Bindings (`AS $v`)

The `AS $v` syntax binds the current pipeline element to a named reference that persists across subsequent stages.

```ruby clear illustrative
bill = users AS $u
  |> UNNEST $u.orders
  |> SUM _.price * $u.discount;
```

### Why bindings exist

Without a binding, `_` always refers to the *current* element - the item being iterated at the innermost level. After `UNNEST`, `_` becomes each inner element (an Order), and the outer element (the User) is no longer reachable.

```ruby clear illustrative
-- Without AS $u: $u is not available inside the fold.
-- `_` after UNNEST is the Order, not the User.
bill = users
  |> UNNEST _.orders
  |> SUM _.price;         -- can access order.price, but NOT user.discount
```

`AS $u` captures the outer element before the `UNNEST` replaces `_`, keeping it accessible:

```ruby clear illustrative
bill = users AS $u
  |> UNNEST $u.orders     -- $u = the User; _ = each Order
  |> SUM _.price * $u.discount;  -- cross-reference: order.price * user.discount
```

The compiler fuses this into a single nested loop with no intermediate allocations.

### Scope of a binding

A binding created with `AS $v` is visible from the point of declaration to the end of the pipeline expression. It cannot be used after the pipeline terminates:

```ruby clear illustrative
bill = users AS $u
  |> UNNEST $u.orders   -- $u is in scope
  |> WHERE _.qty > 1    -- $u still in scope
  |> SUM _.price * $u.discount;  -- $u still in scope

-- $u is not accessible here (out of scope after the pipeline ends)
```

Multiple pipelines in the same function can each use their own `$u` - bindings are scoped to the pipeline expression, not the function.

### Naming the inner element (AS $o)

When you UNNEST and need a name for the inner element (instead of `_`), use a second binding after the UNNEST expression:

```ruby clear illustrative
bill = users AS $u
  |> UNNEST $u.orders AS $o    -- $u = User, $o = Order
  |> SUM $o.price * $u.discount;
```

`AS $o` after the UNNEST expression binds the inner element. Both `$u` and `$o` are available in the fold.

### Supported combinations

**UNNEST binding chains** - fold operators that work after `AS $u |> UNNEST`:

| Fold | Example |
|---|---|
| SUM | `|> SUM _.price * $u.discount` |
| COUNT | `|> COUNT TRUE` |
| AVERAGE | `|> AVERAGE _.price` |
| MIN | `|> MIN _.price` |
| MAX | `|> MAX _.price` |
| ANY | `|> ANY _.price > 50.0` |
| ALL | `|> ALL $u.discount > 0.0` |
| FIND | `|> FIND _.price > 10.0` (returns `?ElemType`) |

Intermediate `WHERE` stages filter the inner elements before the fold:

```ruby clear illustrative
total = users AS $u
  |> UNNEST $u.orders
  |> WHERE _.qty > 1        -- filter inner elements
  |> SUM _.price * $u.discount;
```

`SELECT` is not supported in UNNEST binding chains (the inner projection would lose the `$u` context). Use field access in the fold expression instead.

**CONCURRENT binding** - `$u` is also accessible inside `CONCURRENT` stages that operate directly on the bound list (without an intermediate UNNEST):

| Operator | Example |
|---|---|
| CONCURRENT SELECT | `AS $u |> CONCURRENT SELECT $u.val * 2.0` |
| CONCURRENT SUM | `AS $u |> CONCURRENT SUM $u.score` |
| CONCURRENT COUNT | `AS $u |> CONCURRENT COUNT $u.active` |
| CONCURRENT MIN | `AS $u |> CONCURRENT MIN $u.score` |
| CONCURRENT MAX | `AS $u |> CONCURRENT MAX $u.score` |
| CONCURRENT AVERAGE | `AS $u |> CONCURRENT AVERAGE $u.score` |
| CONCURRENT WHERE | `AS $u |> CONCURRENT WHERE $u.score > 50.0` |

In all concurrent cases, `$u` resolves to the item being processed by the current worker.

## The `_` Variable

Inside pipeline expressions, `_` refers to the current element. For struct elements, access fields with `_.fieldname`:

```ruby clear
-- _ is the element itself (for scalar collections)
nums: Float64[] = [1.0, 3.0, 7.0, 9.0];

big = nums 
  |> WHERE _ > 5.0;

ASSERT length(big) == 2, "WHERE filters by element value";

-- _.field for struct collections
users = [User{name: "alice"}, User{name: "bob"}];

names = users
  |> SELECT _.name;

scores = [Score{value: 10.0}, Score{value: 20.0}];

total = scores 
  |> SUM _.value;

ASSERT total == 30.0, "SUM aggregates field values";
```

In EACH blocks, `_` is mutable — you can assign to fields:

```ruby clear illustrative
pool 
  |> EACH { _.health = _.health - damage; };
```

## Operators

### Transform

| Operator | Syntax | Returns | Description |
|---|---|---|---|
| **SELECT** | `list |> SELECT expr` | `ExprType[]` | Project each element through an expression |
| **WHERE** | `list |> WHERE pred` | `ElemType[]` | Keep elements matching a boolean predicate |
| **ORDER_BY** | `list |> ORDER_BY key` | `ElemType[]` | Sort by key expression |
| **LIMIT** | `list |> LIMIT n` | `ElemType[]` | First N elements |
| **SKIP** | `list |> SKIP n` | `ElemType[]` | Drop first N elements, return rest |
| **DISTINCT** | `list |> DISTINCT key` | `ElemType[]` | Unique by key (first occurrence wins) |
| **UNNEST** | `list |> UNNEST expr` | `InnerType[]` | Flatten nested arrays (flatmap) |
| **INDEX** | `list |> INDEX key` | `HashMap<ElemType[]>` | Group into a hashmap by key |

SELECT accepts any expression, including struct literals. This lets you project into a different struct type in one step:

```ruby clear
STRUCT Raw     { id: Int64, score: Float64 }
STRUCT Summary { key: Int64, normalized: Float64 }

raws: Raw[] = [Raw{ id: 1, score: 100.0 }, Raw{ id: 2, score: 200.0 }];

summaries = raws |> SELECT Summary{ key: _.id, normalized: _.score / 100.0 };

ASSERT summaries[0].key == 1, "id preserved";
ASSERT summaries[1].normalized == 2.0, "score normalized";
```

The result type is inferred from the expression - `Summary[]` above, not `Raw[]`.

**Pipeline fusion with SELECT T{}:** SELECT composes with WHERE and aggregates in a single fused loop - no intermediate list allocation:

```ruby clear
-- WHERE before SELECT: filter on the raw element (efficient)
high = raws |> WHERE _.score > 75.0 |> SELECT Summary{ key: _.id, normalized: _.score / 100.0 };

-- SELECT before aggregate: project then sum/min/max a field
total = raws |> SELECT Summary{ key: _.id, normalized: _.score / 100.0 } |> SUM _.normalized;

-- SELECT before WHERE: build struct first, then filter on a struct field (less efficient)
norm_high = raws |> SELECT Summary{ key: _.id, normalized: _.score / 100.0 } |> WHERE _.normalized > 0.75;
```

When SELECT precedes a fold or WHERE, the compiler binds the projected value to a temp variable per iteration. This avoids the Zig restriction on struct literals in arithmetic/boolean expression positions, so the generated code is always valid without changing semantics.

### Aggregate

| Operator | Syntax | Returns | Empty list |
|---|---|---|---|
| **SUM** | `list |> SUM expr` | Int64 / UInt64 / Float32 / Float64 | 0 |
| **AVERAGE** | `list |> AVERAGE expr` | `Float64` | 0 |
| **MIN** | `list |> MIN expr` | matches expr type | panics |
| **MAX** | `list |> MAX expr` | matches expr type | panics |
| **REDUCE** | `list |> REDUCE(init) expr` | type of init | init |

The return type is driven by the expression type. SUM widens small integers to `Int64`/`UInt64`; floats stay at their original width (`Float32` stays `Float32`). AVERAGE always returns `Float64`. MIN and MAX preserve the exact expression type. REDUCE is the general fold - `acc` is the mutable accumulator, `_` is the current element:

```ruby clear
nums: Float64[] = [2.0, 3.0, 4.0];

product = nums 
  |> REDUCE(1.0) acc * _;

ASSERT product == 24.0, "REDUCE multiplies 2*3*4";
```

### Query

| Operator | Syntax | Returns | Description |
|---|---|---|---|
| **COUNT** | `list |> COUNT pred` | `Int64` | Number of matches |
| **ANY** | `list |> ANY pred` | `Bool` | True if any match (short-circuits) |
| **ALL** | `list |> ALL pred` | `Bool` | True if all match (short-circuits) |
| **FIND** | `list |> FIND pred` | `?ElemType` | First match or null |

### Side Effects

| Operator | Syntax | Returns | Description |
|---|---|---|---|
| **EACH** | `list |> EACH { body }` | `Void` | Iterate with mutable `_`; side-effect only |
| **TAP** | `list |> TAP { body }` | `ElemType[]` | Observe each element (read-only `_`), pass collection through |

EACH is the only operator where `_` is mutable. Use it for in-place updates:

```ruby clear illustrative
entities 
  |> EACH { _.x = _.x + _.vx; _.y = _.y + _.vy; };
```

### TAP (Debugging / Observation)

TAP runs a body for each element but passes the collection through unchanged. Unlike EACH, `_` is read-only and TAP returns the original collection:

```ruby clear illustrative
result = scores
    |> WHERE _.points > 100
    |> TAP { print("score: ${_.points.toString()}"); }
    |> SUM _.points;
```

### WINDOW (Sliding Window)

WINDOW produces a sliding window of size N over the collection. `_` inside the body is the sub-slice (a `Float64[]` or `ElemType[]` of length N). The result is an array of the body expression evaluated per window.

```ruby clear
data: Float64[] = [1.0, 2.0, 3.0, 4.0, 5.0];

-- Each window is a 3-element slice; body projects to window length
lengths = data |> WINDOW(3) _.length();
ASSERT lengths.length() == 3, "5 elements, window 3 -> 3 windows";

-- Access individual elements in the window
firsts = data |> WINDOW(2) _[0];
ASSERT firsts[0] == 1.0, "first element of first window";
```

Number of result windows = `max(0, len - size + 1)`. A window larger than the list produces an empty result.

### WINDOW (Batch / Tumbling Window)

`WINDOW(size: N)`, `WINDOW(time: 'Xms')`, or `WINDOW(size: N, time: 'Xms')` produces non-overlapping batches. `_` inside the body is a `T[]` batch. The result is a heap-allocated list of the body expression evaluated per batch.

Flush conditions (checked after every item):
- `size: N` - flush when the batch accumulates N items
- `time: 'Xms'` - flush when elapsed time since the first item in the batch >= timeout; time units: `ms`, `s`, `min`, `h`
- Both specified - flush on whichever fires first (first-of-either)

A partial batch at the end is always included. Works on all source types: arrays, `~T[]`, `~T[N]`, and `~T[INF]`.

```ruby clear
FN sumBatch(batch: Int64[]) RETURNS Int64 ->
    MUTABLE s: Int64 = 0;
    batch |> EACH { s = s + _; };
    RETURN s;
END

-- Array source, size-only: [1..7] -> [1,2,3], [4,5,6], [7]
arr: Int64[] = [1, 2, 3, 4, 5, 6, 7];
sums = arr |> WINDOW(size: 3) sumBatch(_);
ASSERT sums.length() == 3;   -- 3 batches
ASSERT sums[2] == 7;         -- partial final batch

-- Open stream, size + time (first-of-either)
gen: ~?Int64[] = BG STREAM { MUTABLE i: Int64 = 1; WHILE i <= 10 DO YIELD i; i = i + 1; END };
sums2 = gen |> WINDOW(size: 4, time: "500ms") sumBatch(_);
ASSERT sums2.length() == 3;  -- [1-4], [5-8], [9-10]

-- Time-only: entire array arrives fast, all items in one final batch
arr2: Int64[] = [100, 200, 300];
lens = arr2 |> WINDOW(time: "1s") _.length();
ASSERT lens[0] == 3;  -- one batch of 3
```

> **Note:** The sliding-window form `WINDOW(N)` (positional integer, no named params) is the existing collection-only operator above. The named-param form `WINDOW(size:, time:)` is the new batching operator and works on both collections and streams.

### JOIN (Left Outer Join)

JOIN performs a left outer join between two collections using a two-parameter lambda predicate. Every element of the left collection appears in the result exactly once; the right field is `NIL` when no right element matches.

```ruby clear illustrative
STRUCT User { id: Int64, name: String }
STRUCT Order { userId: Int64, amount: Float64 }

results = users |> JOIN(orders) %(u, o) -> u.id == o.userId;
-- results: JoinResult_User_Order[]
-- results[i].left  -- the User
-- results[i].right -- ?Order (NIL if no match)
```

The result element type is an anonymous struct `{ left: L, right: ?R }`. The lambda must take exactly two parameters (left element, right element) and return Bool.

## Stream and Future Compatibility

Pipelines over futures/streams are currently supported in a narrower subset than pipelines over collections.

### Stream kinds

| Type | Meaning | `NEXT` result | Pipeline support |
|---|---|---|---|
| `~T` | Single future value | `T` | Not a pipeline source |
| `~?T[]` | Open stream | `?T` | Not a pipeline source yet |
| `~T[]` | Finite dynamic stream | `?T` | Full non-concurrent operator set (see table) |
| `~T[N]` | Finite bounded stream | `?T` | Full non-concurrent operator set plus `CONCURRENT EACH/SELECT/WHERE` |
| `~T[INF]` | Infinite stream | `T` | Fusible stages + all terminals via `LIMIT` |

### Operator support matrix

The columns are the three pipeline-capable stream types. "Stage" operators filter or transform in a fused while loop without materializing; "terminal" operators consume the stream and produce a scalar or collection result.

#### Stages (fusible, zero intermediate allocations)

| Operator | `~T[]` | `~T[N]` | `~T[INF]` |
|---|---|---|---|
| `WHERE` | yes | yes | yes (LIMIT must appear in chain) |
| `SELECT` | yes | yes | yes (LIMIT must appear in chain) |
| `SKIP` | yes | yes | yes (LIMIT must appear in chain) |
| `TAKE_WHILE` | yes | yes | yes (LIMIT must appear in chain) |
| `LIMIT` | yes | yes | yes - converts stream to `T[]` |
| `TAP` | yes | yes | not yet |

`LIMIT` can appear anywhere in the chain relative to other fusible stages. The compiler fuses the entire chain into a single while loop - `counter |> WHERE _ > 0 |> LIMIT 5 |> EACH` and `counter |> LIMIT 5 |> WHERE _ > 0 |> EACH` both work; they differ only in whether LIMIT counts pre- or post-filter items.

#### Fold terminals (produce a scalar or optional value)

| Operator | `~T[]` | `~T[N]` | `~T[INF]` |
|---|---|---|---|
| `EACH` | yes | yes | via LIMIT |
| `SUM` | yes | yes | via LIMIT |
| `COUNT` | yes | yes | via LIMIT |
| `AVERAGE` | yes | yes | via LIMIT |
| `MIN` | yes | yes | via LIMIT |
| `MAX` | yes | yes | via LIMIT |
| `ANY` | yes | yes | via LIMIT |
| `ALL` | yes | yes | via LIMIT |
| `FIND` | yes | yes | via LIMIT |
| `REDUCE` | yes | yes | via LIMIT |

"via LIMIT" means LIMIT must appear earlier in the same pipeline chain. LIMIT converts `~T[INF]` to `T[]` (a regular list); the fold terminal then operates on that list. Example: `counter |> WHERE _ > 0 |> LIMIT 5 |> SUM _`.

#### Materialization terminals (produce a new collection)

These operators consume the stream and produce a new heap-allocated collection.
`DISTINCT` and `INDEX` are fully supported for all stream types; others require
materializing first with `.toList()`.

| Operator | `~T[]` | `~T[N]` | `~T[INF]` |
|---|---|---|---|
| `DISTINCT` | yes - returns `T[]@set` | yes - returns `T[]@set` | via LIMIT - returns `T[]@set` |
| `INDEX` | yes | yes | via LIMIT |
| `ORDER_BY` | not yet | not yet | not yet |
| `UNNEST` | not yet | not yet | not yet |
| `WINDOW(N)` (sliding) | not yet | not yet | not yet |
| `WINDOW(size:, time:)` (batch) | yes | yes | yes |
| `JOIN` | not yet | not yet | not yet |

"via LIMIT" means `LIMIT` must appear earlier in the chain (same rule as fold terminals).
`DISTINCT` returns `T[]@set` (a Set), supporting `.count()` and `.contains?()`.

If you need `ORDER_BY`, `UNNEST`, sliding `WINDOW(N)`, or `JOIN` on a stream, materialize first.
The batching `WINDOW(size:, time:)` operator works directly on streams without materialization.

```ruby clear illustrative
s: ~Int64[] = 0 ..< 10;
vals = s.toList();
total = vals 
  |> WHERE _ > 3 
  |> SUM _;
```

#### Concurrent operators

| Operator | `~T[]` | `~T[N]` | `~T[INF]` |
|---|---|---|---|
| `CONCURRENT EACH` | not yet | yes | not yet |
| `CONCURRENT SELECT` | not yet | yes | not yet |
| `CONCURRENT WHERE` | not yet | yes | not yet |

`~T[N]` concurrent pipelines are native: they consume promise slots directly without materializing through `.toList()`, and lower through MIR-visible builtin helpers. Example:

```ruby clear illustrative
nums: ~Float64[4] = [BG { 1.0; }, BG { 2.0; }, BG { 3.0; }, BG { 4.0; }];

doubled = nums 
  |> CONCURRENT(workers: 2) SELECT _ * 2.0;
```

Direct range expressions still use the non-concurrent path unless first bound as `~T[N]`.

### Open streams

Open streams (`~?T[]`) are still `NEXT`-driven only:

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
page = items 
  |> SKIP 20
  |> LIMIT 10;

-- Skip header row, process the rest
data = rows 
  |> SKIP 1 
  |> SELECT parseRow;
```

## Chaining

Operators compose naturally:

```ruby clear illustrative
-- Filter, sort, take top 3
leaderboard = scores
    |> WHERE _.points > 100
    |> ORDER_BY _.points
    |> LIMIT 3;

-- Count active users with high scores
n = users
    |> WHERE _.active == TRUE
    |> COUNT _.score > 1000;
```

## Collection Compatibility

Every operator works on every collection type:

```ruby clear illustrative
-- Array
nums: Float64[] = [1, 2, 3];
total = nums 
  |> SUM _;

-- List
MUTABLE data = List[];
avg = data 
  |> AVERAGE _.value;

-- Pool
MUTABLE pool: Entity[1000]@pool = [];
alive = pool 
  |> WHERE _.health > 0;

-- Pool with SOA (field-slice iteration — cache-optimal)
MUTABLE soa_pool: Entity[1000]@pool:soa = [];
total_hp = soa_pool 
  |> SUM _.health;  -- iterates only the health array

-- List with SOA
MUTABLE soa_list: Entity[]@list:soa = [];
avg = soa_list 
  |> AVERAGE _.health;   -- contiguous f64 slice

-- Sharded (parallel EACH via DO blocks)
MUTABLE sharded: Entity[10000]@pool:sharded(4) = [];
sharded 
  |> EACH { _.processed = TRUE; };
```

## Loop Fusion

The compiler automatically fuses chains of WHERE and SELECT stages ending in a fold (SUM, REDUCE, AVERAGE, MIN, MAX, COUNT, ANY, ALL, FIND) into a single loop with zero intermediate allocations.

```ruby clear illustrative
-- Written as 3 stages:
result = data 
  |> WHERE _ > 500.0 
  |> SELECT _ * _ 
  |> SUM _;

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
total = pool 
  |> SUM _.health;
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
results = data 
  |> CONCURRENT WHERE dbFetch(_.id).val > threshold;

-- Process in parallel
results = data 
  |> CONCURRENT(parallel: TRUE) SELECT dbFetch(_.id).name;
```

Options: 

  * `workers: N` (fiber worker size)
  * `pin: TRUE` (pin to cores)
  * `size: MICRO|STANDARD|LARGE|XL` (stack size).
  * `parallel`: TRUE` (run on multiple cores)

### `CONCURRENT` compatibility

| Source kind | `CONCURRENT SELECT` | `CONCURRENT WHERE` | `CONCURRENT EACH` |
|---|---|---|---|
| Arrays / `@list` / `@pool` / `@pool:soa` | Yes | Yes | Yes |
| `@sharded(...)` collections | Yes | Yes | Yes |
| Finite streams `~T[]` | Not yet | Not yet | Not yet |
| Bounded streams `~T[N]` | Yes | Yes | Yes |
| Open streams `~?T[]` | Not yet | Not yet | Not yet |
| Infinite streams `~T[INF]` | Not yet | Not yet | Not yet |

So today:

- `CONCURRENT` is for collection sources.
- finite streams can participate in non-concurrent fused pipelines for the supported operators above.
- stream `CONCURRENT` will come later once the MIR-safe native lowering is in place.
