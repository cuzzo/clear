# Benchmark 16: Pub-Sub

## What this benchmark actually tests

64 parallel workers each independently process 100,000 messages with CPU-bound
work (2,000 LCG iterations per message). Each worker generates its own message
sequence -- there is no shared publisher, no channels, no fan-out.

This is fan-out/fan-in (benchmark 12) with an extra level of inner parallelism,
not pub/sub. The Go and Rust implementations make this explicit: they run 64
threads doing sequential per-worker loops with zero allocation.

The CLEAR implementation materializes a `Msg[]` list per subscriber and then
processes it with a CONCURRENT worker pool, using ~420 MB peak RSS vs ~2 MB for
Go and Rust. The excess memory comes from materializing 100K-element lists that
Go and Rust never create.

## What real pub/sub requires

Real pub/sub has three components that this benchmark lacks:

1. **One publisher** that produces a continuous stream of messages
2. **Fan-out** -- each message is delivered to every subscriber independently
3. **Backpressure** -- a slow subscriber exerts pressure back on the publisher
   rather than buffering unboundedly or dropping messages

The key invariant: subscriber N does not affect subscriber M. Each subscriber
has an independent cursor into the shared message stream.

## What CLEAR is missing

### 1. `~T@shared` (SharedTime) -- transpiler gap

The runtime (`CheatLib.SharedPromise`) is fully implemented. The compiler
recognizes the type and annotator supports it, but the transpiler never emits
`SharedPromise.spawn()` or `SharedPromise.retain()`. LINK on a tense type is
also unimplemented in the transpiler.

SharedTime is not directly needed for pub/sub streams, but it is the correct
primitive for "compute a value once, let N fibers observe the result" -- a
degenerate pub/sub where the stream has exactly one item.

### 2. `~T[INF]@shared` (broadcast InfStream) -- runtime and compiler both missing

`~T[INF]` (InfStream) is a lock-free SPSC ring buffer -- one producer, one
consumer. For broadcast pub/sub you need SPMC: one producer, N independent
consumers, each maintaining their own read cursor. The producer blocks only when
the slowest consumer has not yet read the next slot (true backpressure).

This does not exist in the runtime or the compiler. It is the core missing
primitive for idiomatic pub/sub.

### 3. Stream sources in pipelines -- analysis and lowering gap

Every pipeline stage (`SELECT`, `WHERE`, `SUM`, `EACH`, `COUNT`, `MIN`, `MAX`,
`REDUCE`, `LIMIT`, `FIND`, `ANY`, `ALL`, `DISTINCT`, `SKIP`, `WINDOW`,
`TAKE_WHILE`) calls `require_array_input!` which rejects anything that is not a
materialized array or collection. `~T[?]` (open stream) and `~T[INF]` are
rejected at analysis time.

Allowing streams as pipeline sources requires:
- `require_array_input!` accepting `open_stream?` and `inf_stream?`
- Element type extraction for streams in each `analyze_*_op` method
- Pull-loop codegen in `pipeline_host.rb` for every stage (currently emits a
  slice `pipe_src_list.items` which has no meaning for a stream)
- Enforcement that `~T[INF]` pipelines include a terminal bound (`LIMIT` or
  `TAKE_WHILE`), otherwise the pipeline is an infinite loop

### 4. Range sources in pipelines -- same gap

`(0..<n) |> SELECT ...` also fails `require_array_input!`. Ranges are only
accepted by `CONCURRENT EACH` and `SHARD`. All other pipeline stages reject
them. This is the same codegen gap as streams: need a pull-loop instead of a
slice.

### 5. `BG` as a `SELECT` expression

`list |> SELECT BG { f(_) }` would produce `Promise(T)[]` -- a list of futures.
This is not currently valid; SELECT does not permit BG as the body expression.
To make this useful, downstream stages (`SUM`, `EACH`, `REDUCE`) would also need
`NEXT`-aware variants that await each promise before folding:
`futures |> SUM NEXT _`.

## Ideal idiomatic CLEAR implementation

Once the above primitives exist, pub/sub would look like this:

```
FN processMessage(seed: Int64) RETURNS Int64 ->
    MUTABLE x: Int64 = seed;
    FOR i IN (0_i64 ..< 2000) -> x = x %* 6364136223846793005_i64 %+ 1442695040888963407_i64;
    RETURN x;
END

FN main() RETURNS Void ->
    t0 = timestampMs();

    -- One publisher: a broadcast infinite stream.
    -- YIELD blocks when the slowest subscriber has not consumed yet (backpressure).
    publisher: ~Int64[INF]@shared = BG STREAM {
        FOR i IN (0_i64 ..< 100000) -> YIELD i;
    };

    -- 64 subscribers: each gets an independent cursor via LINK.
    -- (0..<64) |> SELECT BG { ... } requires range pipeline + BG-in-SELECT support.
    MUTABLE futures: ~Int64[]@list = [];
    FOR i IN (0_i64 ..< 64) ->
        sub = LINK publisher;                    -- independent cursor, ref-counted
        futures.append(BG {
            sub |> SUM processMessage(_)         -- stream pipeline source support
        });
    END

    total = futures |> SUM NEXT _;               -- BG-in-SELECT / NEXT-fold support

    elapsed = timestampMs() - t0;
    print("Checksum:", total MOD 1000000000);
    print("Subscribers: 64");
    print("Messages: 100000");
    print("Time: ${elapsed.toString()} ms");
END
```

Properties of this implementation:
- One publisher fiber, zero message duplication
- Each subscriber processes every message exactly once
- `LINK publisher` clones the cursor (ref-counted, O(1))
- `sub |> SUM processMessage(_)` pulls lazily from the stream -- no intermediate
  list, O(ring_buffer_size) memory total (~4KB per subscriber at BUF_SIZE=64)
- Publisher blocks on the slowest subscriber -- true backpressure, no drops
- Total memory: O(64 * 64 * sizeof(Int64)) = ~32 KB, not ~420 MB

## Recommended implementation plan

### Phase 1: SharedTime transpiler (small, self-contained)

Close the existing compiler gap for `~T@shared`:
- Transpiler: emit `CheatLib.SharedPromise(T).spawn(alloc, sched)` for BG blocks
  whose result type is `shared_promise?`
- Transpiler: emit `.retain()` for LINK on a shared promise
- Transpiler: NEXT on shared promise emits `.next()` (same as regular promise --
  the runtime handles idempotency)
- Cleanup: shared promise `deinit` is the existing `.next()` drain path

Existing runtime is complete. This is a compiler-only change.

### Phase 2: Broadcast InfStream runtime (`~T[INF]@shared`)

New runtime type `CheatLib.BroadcastStream(T)` in `runtime-header.zig`:
- Multi-reader ring buffer: producer writes to `head`, each consumer has its own
  `tail_N` cursor
- Producer blocks (fiber yield) when `head - min(all_tails) >= BUF_SIZE`
- Consumer blocks (fiber yield) when its `tail_N == head`
- `subscribe()` returns a `BroadcastStream.Reader` handle with its own cursor
- Reader is ref-counted; producer unblocks when all readers have consumed

Compiler additions:
- Type annotation: `~T[INF]@shared`
- `BG STREAM { YIELD }` body whose result is `inf_stream? && shared?` spawns a
  `BroadcastStream` generator
- `LINK stream` on `inf_stream? && shared?` calls `.subscribe()`, returns a
  Reader handle
- NEXT on a Reader handle calls `.next()` -- blocks if no new item
- Cleanup: Reader calls `.unsubscribe()` which removes its cursor from the
  producer's min-tail calculation

### Phase 3: Stream and range sources in pipelines

Extend `require_array_input!` to accept `open_stream?`, `inf_stream?`, and
`RangeLit`. In `pipeline_host.rb`, add a pull-loop codegen path for each stage
alongside the existing slice path:

```zig
// Array source (existing):
const pipe_items = pipe_src_list.items;
for (pipe_items) |item| { ... }

// Stream source (new):
while (pipe_src_stream.next()) |item| { ... }   // ~T[?]: nil terminates
while (true) { const item = pipe_src_stream.next(); ... }  // ~T[INF]: needs LIMIT

// Range source (new):
for (@intCast(pipe_src_range.start)..@intCast(pipe_src_range.end)) |item| { ... }
```

Add a compile-time check: `~T[INF]` as a pipeline source without a `LIMIT` or
`TAKE_WHILE` stage is an error.

### Phase 4: `BG` in `SELECT`, `NEXT`-fold in terminal stages

Allow `BG { expr }` as a SELECT body expression. The SELECT result type becomes
`Promise(T)[]` instead of `T[]`. Downstream terminal stages (`SUM`, `REDUCE`,
`EACH`, `FIND`) gain `NEXT`-aware variants when the element type is `tense?`:
they await each promise before folding. This enables:

```
list |> SELECT BG { expensive(_) } |> SUM NEXT _
```

which is a bounded parallel map-reduce: up to `workers` BG fibers run
concurrently, results are awaited and folded in order.

### Phase 5: Rewrite this benchmark

Once Phases 1-4 are complete, rewrite `bench.clear` to use the idiomatic pattern
above. Expected outcome: memory drops from ~420 MB to ~32 KB, latency improves
due to reduced allocation pressure, and the benchmark actually tests pub/sub
semantics rather than parallel fan-out.
