# Concurrency

CLEAR uses cooperative fibers for concurrency. Fibers are lightweight threads managed by the CLEAR runtime — each has its own stack (4-256KB) and runs until it yields. No OS threads are created per fiber; the scheduler multiplexes fibers onto a thread pool.

## BG — Background Fibers

Spawn a fiber that runs concurrently and returns a Promise:

```clear
-- ILLUSTRATIVE
p = BG { expensive_computation(data); };
-- ... do other work ...
result = NEXT p;  -- block until the fiber finishes
```

The last expression in the body becomes the promise's value. `NEXT` consumes the promise and returns the value.

### Modifiers

Modifiers go inside the braces, before a `->`:

```clear
-- ILLUSTRATIVE
BG { @large:@pinned -> heavy_work(); }
```

| Modifier | Effect |
|---|---|
| `@micro` | 4 KB stack |
| `@standard` | 16 KB stack (default) |
| `@large` | 64 KB stack |
| `@xl` | 256 KB stack |
| `@pinned` | Pin to local scheduler (no work stealing) |
| `@parallel` | Distribute to least-loaded scheduler |
| `@arena` | Thread-local arena allocation; implies @pinned |

Combine with `:` — `@large:@arena` gives a large stack with arena allocation.

### Captures

BG blocks capture outer variables **by value** (moved, not borrowed):

```clear
-- ILLUSTRATIVE
x = 42.0;
p = BG { x + 1.0; };  -- x is moved into the fiber
-- x is no longer usable here (affine ownership)
```

### THEN Chains

Chain sequential steps inside a single fiber:

```clear
-- ILLUSTRATIVE
result = BG {
    fetch("https://api.example.com/data")
    AS response THEN parse(response)
    AS parsed THEN transform(parsed);
};
```

Each `AS name` binds the result for subsequent steps. The last step's value becomes the promise result.

**Error handling:** use `OR` before the `AS` binding. If a step returns `!T`, handle it inline:

```clear
-- ILLUSTRATIVE
result = BG {
    fetch(url) OR RAISE           -- propagate error to caller
    AS response THEN parse(response) OR default_value
    AS parsed THEN transform(parsed);
};
```

- `OR RAISE` - propagate the error (caller sees it via `NEXT`)
- `OR value` - replace error with a fallback, chain continues

## DO — Fork-Join

Execute multiple branches concurrently, wait for all to complete:

```clear
-- ILLUSTRATIVE
DO {
    update_database(record),
    send_notification(user),
    log_event(event)
}
-- All three are done here.
```

Branches are separated by commas. Each runs in its own fiber. The DO block waits for all branches before continuing. Returns `Void`.

### Branch Modifiers

Each branch can have its own modifiers:

```clear
-- ILLUSTRATIVE
DO {
    @large -> heavy_computation(),
    @pinned -> cache_local_work()
}
```

## NEXT — Promise Resolution

Block until a promise resolves:

```clear
p: ~Float64 = BG { 42.0; };
result: Float64 = NEXT p;
```

| Promise Type | NEXT returns | Behavior |
|---|---|---|
| `~T` | `T` | Consumes the promise (one-shot) |
| `~T @shared` | `T` | Returns cached result (safe for multiple NEXT) |
| `~T[?]` | `?T` | Returns next value or nil (open stream) |
| `~T[INF]` | `T` | Returns next value, never nil (infinite stream) |

## BG STREAM — Generators

Spawn a fiber that yields values over time:

```clear
-- ILLUSTRATIVE
-- Open stream (finite)
s: ~Float64[?] = BG STREAM {
    YIELD 1.0;
    YIELD 4.0;
    YIELD 9.0;
};
v1 = NEXT s;  -- 1.0
v2 = NEXT s;  -- 4.0
v3 = NEXT s;  -- 9.0
v4 = NEXT s;  -- nil (exhausted)

-- Infinite stream
counter: ~Float64[INF] = BG STREAM {
    MUTABLE i = 0.0;
    WHILE TRUE DO
        YIELD i;
        i = i + 1.0;
    END
};
v1 = NEXT counter;  -- 0.0
v2 = NEXT counter;  -- 1.0 (blocks until generator yields)
-- ILLUSTRATIVE
```

## CONCURRENT — Parallel Pipelines

Apply pipeline operators in parallel with a persistent worker pool:

```clear
-- ILLUSTRATIVE
results = items s> CONCURRENT(workers: 8) SELECT transform(_);
filtered = items s> CONCURRENT(workers: 4) WHERE predicate(_);
items s> CONCURRENT(workers: 2) EACH { _.value = 0.0; };
```

### Options

| Option | Type | Default | Effect |
|---|---|---|---|
| `workers` | Number | 8 | Number of persistent worker fibers |
| `parallel` | Bool | FALSE | TRUE = distribute workers across schedulers (multi-core) |
| `size` | Identifier | STANDARD | Stack size: MICRO, STANDARD, LARGE, XL |

### Supported Operators

- **CONCURRENT SELECT** — parallel map. Returns transformed array (order preserved).
- **CONCURRENT WHERE** — parallel filter. Returns matching elements (order preserved).
- **CONCURRENT EACH** — parallel side effects. Returns Void.

### Error Handling

```clear
-- ILLUSTRATIVE
-- Skip failed items
results = items s> CONCURRENT(workers: 4) SELECT risky_fn(_) OR PRUNE;

-- Propagate first error
results = items s> CONCURRENT(workers: 4) SELECT risky_fn(_) OR RAISE;
```

### How It Works

CONCURRENT spawns N persistent worker fibers that pull items from a shared atomic index. Zero per-item allocation — workers reuse their stack and context across all items. This is fundamentally different from spawning one fiber per item (which is what BG does).

```
Default (workers on local scheduler):
  CONCURRENT(workers: 8) SELECT transform(_)
  → 8 fibers on one thread, cooperative scheduling

Multi-core (workers distributed):
  CONCURRENT(workers: 8, parallel: TRUE) SELECT transform(_)
  → 8 fibers spread across all schedulers
```

### Performance

| Pattern | Per-item cost | Use when |
|---|---|---|
| `CONCURRENT(workers: N)` | ~0 (atomic fetchAdd only) | Bulk processing, batch transforms |
| Individual `BG { }` | ~60μs (GPA alloc) | Dynamic spawning, I/O-bound tasks |

CONCURRENT is 30x faster than individual BG spawns for batch workloads. For I/O-bound tasks (network requests, file reads), the 60μs BG spawn cost is negligible compared to I/O latency.

## Multi-Threading

CLEAR defaults to single-threaded scheduling. Set `CLEAR_THREADS` to enable multi-core:

```bash
CLEAR_THREADS=0 ./my_program   # auto-detect CPU count
CLEAR_THREADS=4 ./my_program   # 4 scheduler threads
CLEAR_THREADS=1 ./my_program   # single-threaded (default)
```

Each scheduler thread runs its own event loop with work stealing. Idle schedulers steal tasks from busy ones. `@pinned` tasks are exempt from stealing.

## Safety Rules

The compiler enforces these at compile time:

| Rule | Reason |
|---|---|
| `@parallel` + `@local` = error | @local has no synchronization |
| `@parallel` + `@multiowned` = error | Rc is non-atomic; use @shared (Arc) |
| `@arena` + `@parallel` = error | Arena memory is thread-local |
| Non-@pinned BG capturing from @pinned scope = error | Thread-local memory would escape |
| `YIELD` outside BG STREAM = error | YIELD only valid in generators |
| `NEXT` on non-promise = error | Can only await promises and streams |

## When to Use What

| Goal | Construct |
|---|---|
| Process a batch of items | `s> CONCURRENT(workers: N) SELECT/WHERE/EACH` |
| Fire off a background task | `BG { work(); }` |
| Run independent tasks concurrently | `DO { task1(), task2(), task3() }` |
| Generate values lazily | `BG STREAM { YIELD ...; }` |
| Chain async steps | `BG { step1() AS r THEN step2(r) }` |
| Handle requests (server) | `BG { @pinned:@arena -> handle(conn); }` |

## Known Limitations (v0.1)

**Dynamic spawn overhead**: Individual BG blocks cost ~60μs each due to GPA allocation for Fiber/Task structs. This makes CLEAR ~30x slower than Go for spawn-heavy microbenchmarks. Workaround: use `CONCURRENT(workers: N)` for bulk workloads. Fix planned for v0.2 (object pooling).

**No bounded channels**: CLEAR has Promises (one-shot) and Streams (unbounded). There is no bounded producer/consumer channel. CONCURRENT provides backpressure for pipeline workloads. General bounded channels are planned for v0.2.
