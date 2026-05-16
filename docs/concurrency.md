# Concurrency

CLEAR uses cooperative fibers for concurrency.

Fibers are lightweight threads managed by the CLEAR runtime — each has its own stack (4-256KB) and runs until it yields. No OS threads are created per fiber; the scheduler multiplexes fibers onto a thread pool.

> [!NOTE]
> CLEAR will support limited Finite State Machines in v0.2, and by v0.4 - full support for Finite State Machines is planned.

## BG — Background Fibers

Spawn a fiber that runs concurrently and returns a Promise:

```ruby clear illustrative
p = BG { expensive_computation(data); };
# ... do other work ...
result = NEXT p;  # block until the fiber finishes
```

The last expression in the body becomes the promise's value. `NEXT` consumes the promise and returns the value.

> [!NOTE]
> By v0.4 Finite State Machines will be the default, and you will opt-in to stack-based fibers for re-entrant tasks or tasks that use FFI.

### Modifiers

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

Combine with `:` — `@large:@arena` gives a large stack with arena allocation.

By v0.2 `@stateMachine` and `@stack` will be options.  The compiler will warn you when you should use a state machine, and block you from using it when it's not an option.  

### @service — OS Thread Spawning

`@service` spawns a **dedicated OS thread** instead of a green fiber. Use it for heavy-compute tasks that won't cooperatively yield - the OS handles preemption.

```ruby clear illustrative
p = BG { @service ->
    trainModel(dataset);  # runs on its own OS thread
};
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

```clear
# ILLUSTRATIVE
result = BG {
    fetch(url) OR RAISE           # propagate error to caller
      AS response THEN parse(response) OR default_value
      AS parsed THEN transform(parsed);
};
```

- `OR RAISE` - propagate the error (caller sees it via `NEXT`)
- `OR value` - replace error with a fallback, chain continues

## DO — Fork-Join

Execute multiple branches concurrently, wait for all to complete:

```clear
# ILLUSTRATIVE
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

```clear
# ILLUSTRATIVE
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

```ruby clear illustrative
# Open stream (finite)
s: ~Float64[?] = BG STREAM {
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

```clear
# ILLUSTRATIVE
results = items |> CONCURRENT(workers: 8) SELECT transform(_);
filtered = items |> CONCURRENT(workers: 4) WHERE predicate(_);
items |> CONCURRENT(workers: 2) EACH { _.value = 0.0; };
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

```ruby clear illustrative
# Skip failed items
results = items
  |> CONCURRENT(workers: 4) SELECT risky_fn(_) OR PRUNE;

# Propagate first error
results = items
  |> CONCURRENT(workers: 4) SELECT risky_fn(_) OR RAISE;
```

### How It Works

CONCURRENT spawns N persistent worker fibers that pull items from a shared atomic index. Zero per-item allocation — workers reuse their stack and context across all items. This is fundamentally different from spawning one fiber per item (which is what BG does).

```
results = items
  |> SELECT BG { risky_fn(_) OR RAISE };
# this is valid, but it would spawn N tasks, all at once.  It is NOT recommended.
```

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


 * CONCURRENT is 30x faster than individual BG spawns for batch workloads. 
 * For I/O-bound tasks (network requests, file reads), the 60μs BG spawn cost is negligible compared to I/O latency.
 * The big benefit is that `workers: N` handles backpressure to avoid spawning more tasks than you can handle.

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
| Process a batch of items | `|> CONCURRENT(workers: N) SELECT/WHERE/EACH` |
| Fire off a background task | `BG { work(); }` |
| Run independent tasks concurrently | `DO { task1(), task2(), task3() }` |
| Generate values lazily | `BG STREAM { YIELD ...; }` |
| Chain async steps | `BG { step1() AS r THEN step2(r) }` |
| Handle requests (server) | `BG { @pinned:@arena -> handle(conn); }` |

## Known Limitations (v0.1)

**Dynamic spawn overhead**: Individual BG blocks cost ~60μs each due to GPA allocation for Fiber/Task structs. This makes CLEAR ~30x slower than Go for spawn-heavy microbenchmarks. Workaround: use `CONCURRENT(workers: N)` for bulk workloads. Fix planned by the v0.1 release.

**No bounded channels**: CLEAR has Promises (one-shot) and Streams (unbounded). There is no bounded producer/consumer channel. CONCURRENT provides backpressure for pipeline workloads. General bounded channels are in progress, and will be available by v0.1 or v0.2 release.
