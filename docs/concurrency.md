# Concurrency

CLEAR uses cooperative fibers for concurrency.

Fibers are lightweight threads managed by the CLEAR runtime.

By default, Fibers are transformed to Finite State Machines.  By default, OS threads are not created per fiber.  The scheduler multiplexes fibers onto a thread pool.

You can override them to run on stacks if you like. Stacks can be sized between (4-256KB) and runs until it yields.  Stack fibers can also be set to run as true OS threads when you want them to.


## BG — Background Fibers

Spawn a fiber that runs concurrently and returns a Promise:

```ruby clear illustrative
p = BG { expensive_computation(data); };
# ... do other work ...
result = NEXT p;  # block until the fiber finishes
```

The last expression in the body becomes the promise's value (like an implicit return). `NEXT` consumes the promise and returns the value.

### Modifiers

You can override tasks with modifiers to run on stacks, to be true OS threads, or to have a particular allocation strategy.

Modifiers go inside the braces, before a `->`:

```ruby clear illustrative
BG { @large:pinned -> heavy_work(); }
```

| Modifier | Effect |
|---|---|
| `@micro` | 4 KB fiber stack |
| `@standard` | 16 KB fiber stack (default) |
| `@large` | 64 KB fiber stack |
| `@xl` | 256 KB fiber stack |
| `@service` | **OS thread** (not a fiber). Full OS stack. For heavy non-cooperative compute. |
| `@pinned` | Pin to local scheduler (no work stealing) |
| `@parallel` | Distribute to least-loaded scheduler |
| `@arena` | Thread-local arena allocation; only works with @pinned tasks |
| `@fsm` | Force to run as an Finite State Machine (the default) |

Combine with `:` — `@large:arena` gives a large stack with arena allocation.

### @service — OS Thread Spawning

`@service` spawns a **dedicated OS thread** instead of a green fiber. Use it for heavy-compute tasks that won't cooperatively yield - the OS handles preemption.

```ruby clear illustrative
# runs on its own OS thread due to @service
p = BG { @service -> trainModel(dataset); };
# fiber continues concurrently
result = NEXT p;  # blocks fiber until OS thread finishes
```

The OS thread gets its own Runtime with a 64 KB frame arena. No scheduler is involved - the thread runs independently until completion, then signals the Promise.

**When to use @service vs fibers:**
- Fibers (`@standard`/`@large`): I/O-bound, short compute bursts, cooperative yielding
- `@service`: CPU-bound, long-running, no yields, true OS-level parallelism

### Captures

BG blocks capture outer variables **by value** (moved, not borrowed):

```ruby clear illustrative
x = 42.0;
p = BG { x + 1.0; };  # x is moved into the fiber
# x is no longer usable here (affine ownership)
```

### THEN Chains

Chain sequential steps inside a single fiber:

```ruby clear illustrative
result = BG {
    fetch("https://api.example.com/data") AS response
      THEN parse(response) AS parsed
      THEN transform(parsed);
};
```

Each `AS name` binds the result for subsequent steps. The last step's value becomes the promise result.

This is equivalent to:

```ruby clear illustrative
result = BG {
    response = NEXT fetch("https://api.example.com/data");
    parsed = NEXT parse(response);
    transform(parsed);
};
```

`THEN` is mostly useful for short-chained tasks, especially in a complex pipeline:

```ruby clear illustrative
result = BG {
    fetch("https://api.example.com/data1") AS r THEN parse(r),
    fetch("https://api.example.com/data2") AS r THEN parse(r)
};
# result = ~T[] -> this is only valid when all T are the same.
```


**Error handling:** use `OR` before the `AS` binding. If a step returns `!T`, handle it inline:

```ruby clear illustrative
result = BG {
    fetch(url) OR_ELSE RAISE           # propagate error to caller
      AS response THEN parse(response) OR default_value
      AS parsed THEN transform(parsed);
};
```

- `OR_ELSE RAISE` - propagate the error (caller sees it via `NEXT`)
- `OR_ELSE value` - replace error with a fallback, chain continues

## DO — Fork-Join

Execute multiple branches concurrently, wait for all to complete:

```ruby clear illustrative
DO {
    update_database(record),
    send_notification(user),
    log_event(event)
}
# All three are done here.
```

Branches are separated by commas. Each runs in its own fiber. The DO block waits for all branches before continuing. Returns `Void`.

### Branch Modifiers

Each branch can have its own modifiers:

```ruby clear illustrative
BG {
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
| `~?T[]` | `?T` | Returns next value or nil (open stream) |
| `~T[INF]` | `T` | Returns next value, never nil (infinite stream) |

## BG STREAM — Generators

Spawn a fiber that yields values over time:

```ruby clear illustrative
# Open stream (finite)
s: ~?Float64[] = BG STREAM {
    YIELD 1.0;
    YIELD 4.0;
    YIELD 9.0;
};
v1 = NEXT s;  # 1.0
v2 = NEXT s;  # 4.0
v3 = NEXT s;  # 9.0
v4 = NEXT s;  # NIL (exhausted)

# Infinite stream
counter: ~Float64[INF] = BG STREAM {
    MUTABLE i = 0.0;
    WHILE TRUE DO
        YIELD i;
        i = i + 1.0;
    END
};
v1 = NEXT counter;  # 0.0
v2 = NEXT counter;  # 1.0 (blocks until generator yields)
```

## CONCURRENT — Parallel Pipelines

Apply pipeline operators in parallel with a persistent worker pool:

```ruby clear illustrative
results = items |> CONCURRENT(workers: 8) SELECT transform;
filtered = items |> CONCURRENT(workers: 4) WHERE predicate;
items |> CONCURRENT(workers: 2) EACH { _.value = 0.0; };
```

### Options

| Option | Type | Default | Effect |
|---|---|---|---|
| `workers` | Number | 8 | Number of persistent worker fibers |
| `batch` | Number | 1 | Items each worker pulls per fetch from the shared index (larger = less index contention) |
| `capacity` | Number | auto (worker count rounded up to a power of 2, clamped 4-64) | Bounded channel ring-buffer size; only valid with a streaming / `SHARD` / range source |
| `parallel` | Bool | FALSE | TRUE = distribute workers across schedulers (multi-core) |
| `size` | Identifier | STANDARD | Stack size: MICRO, STANDARD, LARGE, XL |

### Supported Operators

- **CONCURRENT SELECT** — parallel map. Returns transformed array (order preserved).
- **CONCURRENT WHERE** — parallel filter. Returns matching elements (order preserved).
- **CONCURRENT EACH** — parallel side effects. Returns Void.

### Error Handling

```ruby clear illustrative
# Skip failed items
results = items
  |> CONCURRENT(workers: 4) SELECT risky_fn OR_ELSE PRUNE;

# Propagate first error
results = items
  |> CONCURRENT(workers: 4) SELECT risky_fn OR_ELSE RAISE;
```

### How It Works

`CONCURRENT` spawns N persistent worker fibers that pull items from a shared atomic index. Zero per-item allocation.  Workers reuse their stack and context across all items.  This is fundamentally different from spawning one fiber per item (which is what BG does).

```ruby clear
results = items
  |> SELECT BG { risky_fn OR_ELSE RAISE };
# this is valid, but it would spawn N tasks, all at once.  It is NOT recommended.
```

```text
Default (workers on local scheduler):
  CONCURRENT(workers: 8) SELECT transform(_)
  → 8 fibers on one thread, cooperative scheduling

Multi-core (workers distributed):
  CONCURRENT(workers: 8, parallel: TRUE) SELECT transform(_)
  → 8 fibers spread across all schedulers
```

### Backpressure / Performance

| Pattern | Per-item cost | Use when |
|---|---|---|
| `CONCURRENT(workers: N, capacity: M)` | ~0 (atomic fetchAdd only) | Bulk processing, batch transforms |
| Individual `BG { }` | ~60μs (GPA alloc) | Dynamic spawning, I/O-bound tasks |


 * CONCURRENT is ~30x faster than individual BG spawns for batch workloads. 
 * For I/O-bound tasks (network requests, file reads), the 60μs BG spawn cost is negligible compared to I/O latency.
 * **The big benefit**: `capacity: M` handles **backpressure** to avoid spawning more tasks than you can handle.

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
| Process a batch of items | `\|> CONCURRENT(workers: N) SELECT/WHERE/EACH` |
| Fire off a background task | `BG { work(); }` |
| Run independent tasks concurrently | `DO { task1(), task2(), task3() }` |
| Generate values lazily | `BG STREAM { YIELD ...; }` |
| Chain async steps | `BG { step1() AS r THEN step2(r) }` |
| Handle requests (server) | `BG { @pinned:@arena -> handle(conn); }` |

## Known Limitations (v0.1)

**Dynamic spawn overhead**: spawning many individual `BG` tasks is competitive with Go at moderate thread counts (roughly parity at 8 threads on the 100K-spawn benchmark) but slower at high core counts — about 1.6x Go at small scale, up to ~3.5x at 32 threads. The remaining gap is idle schedulers spinning on the work-stealing deque instead of parking, not per-spawn allocation. Workaround: use `CONCURRENT(workers: N)` for bulk workloads. Scheduler parking (the fix) is tracked for post-v0.1.

**No general bounded channel**: CLEAR has Promises (one-shot) and Streams (unbounded). `CONCURRENT` streaming uses an internal bounded ring-buffer channel for backpressure (tunable via the `capacity:` option), but there is no general user-facing bounded producer/consumer channel primitive yet.
