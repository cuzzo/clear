# Pipelines and Higher-Order Functions

CLEAR's pipeline system lets you transform, filter, aggregate, and iterate collections using the smooth operator (`s>`). Every pipeline operator works on arrays, `@list`, `@pool`, sharded collections, and `@pool:soa` — the same syntax regardless of the underlying storage.

```clear
scores s> WHERE _ > 50 s> SUM _;
entities s> EACH { _.health = _.health - 1.0; };
users s> SELECT _.name s> DISTINCT _;
```

## The Smooth Operator (`s>`)

`s>` pipes a value into a function or operator. It's CLEAR's equivalent of `|>` (Elixir) or `.` method chaining (Ruby), but it also works with collection operators.

```clear
-- Pipe to a function: x s> f  →  f(x)
result = data s> process s> validate s> format;

-- Pipe to an operator: list s> WHERE predicate
alive = entities s> WHERE _.health > 0;
```

Pipelines chain left to right. Each stage passes its result to the next.

## The `_` Variable

Inside pipeline expressions, `_` refers to the current element. For struct elements, access fields with `_.fieldname`:

```clear
-- _ is the element itself (for scalar collections)
nums s> WHERE _ > 5;

-- _.field for struct collections
users s> SELECT _.name;
pool s> SUM _.score;
```

In EACH blocks, `_` is mutable — you can assign to fields:

```clear
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
| **DISTINCT** | `list s> DISTINCT key` | `ElemType[]` | Unique by key (first occurrence wins) |
| **UNNEST** | `list s> UNNEST expr` | `InnerType[]` | Flatten nested arrays (flatmap) |
| **INDEX** | `list s> INDEX key` | `HashMap<ElemType[]>` | Group into a hashmap by key |

### Aggregate

| Operator | Syntax | Returns | Empty list |
|---|---|---|---|
| **SUM** | `list s> SUM expr` | `Number` | 0 |
| **AVERAGE** | `list s> AVERAGE expr` | `Number` | 0 |
| **MIN** | `list s> MIN expr` | `Number` | panics |
| **MAX** | `list s> MAX expr` | `Number` | panics |
| **REDUCE** | `list s> REDUCE(init) expr` | type of init | init |

Aggregate expressions must be numeric (Number or Int64). REDUCE is the general fold — `acc` is the mutable accumulator, `_` is the current element:

```clear
product = nums s> REDUCE(1.0) acc * _;
csv = names s> REDUCE("") acc + ", " + _;
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

EACH is the only operator where `_` is mutable. Use it for in-place updates:

```clear
entities s> EACH { _.x = _.x + _.vx; _.y = _.y + _.vy; };
```

## Chaining

Operators compose naturally:

```clear
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

```clear
-- Array
nums: Number[] = [1, 2, 3];
total = nums s> SUM _;

-- List
MUTABLE data = List<Score>[];
avg = data s> AVERAGE _.value;

-- Pool
MUTABLE pool = Pool<Entity>[];
alive = pool s> WHERE _.health > 0;

-- Pool with SOA (field-slice iteration — cache-optimal)
MUTABLE soa_pool = Pool<Entity>[]@soa;
total_hp = soa_pool s> SUM _.health;  -- iterates only the health array

-- List with SOA
MUTABLE soa_list = List<Entity>[]@soa;
avg = soa_list s> AVERAGE _.health;   -- contiguous f64 slice

-- Sharded (parallel EACH via DO blocks)
MUTABLE sharded = Pool<Entity>[]@sharded(4);
sharded s> EACH { _.processed = TRUE; };
```

## SOA Optimization

When a `@pool:soa` is used in a pipeline, the compiler rewrites field accesses to iterate directly over contiguous field arrays instead of striding over whole structs. This happens automatically for all operators — no syntax change needed.

```clear
STRUCT Entity { x: Number, y: Number, vx: Number, vy: Number, health: Number }
MUTABLE pool: Entity[]@pool:soa = [];

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

The `CONCURRENT` modifier parallelizes SELECT, WHERE, and EACH across shards:

```clear
MUTABLE data: Score[]@pool:sharded(4) = [];

-- Parallel WHERE: one fiber per shard
results = data s> CONCURRENT WHERE _.value > threshold;

-- With options
results = data s> CONCURRENT(size: LARGE) SELECT _.name;
```

Options: `pool_size: N` (fiber pool size), `pin: TRUE` (pin to cores), `size: MICRO|STANDARD|LARGE|XL` (stack size).
