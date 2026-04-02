# v0.1-pre: BENCHMARK, SMASH, PROFILE

## What makes CLEAR different

CLEAR's compiler and runtime have information that no other language exposes
to its profiling and testing tools:

1. **Full call graph with effects**: which functions allocate, block, are
   reentrant, can fail -- computed at compile time via fixed-point analysis
2. **Capability annotations**: which data is `@shared`, `@locked`,
   `@sharded(N)`, `@writeLocked`, `@pinned` -- the programmer's
   architectural intent, not just type info
3. **Arena vs heap distinction**: which allocations are frame-scoped (freed
   at function exit) vs heap (must be explicitly freed)
4. **Cooperative yield points**: every loop has `checkYield()` -- the
   runtime knows exactly when fibers yield and can measure yield latency
5. **Live control plane**: skew detection, auto-sizing, overflow tracking
   -- already built in `control-plane.zig`

These five properties allow CLEAR to build profiling and analysis tools
that understand the programmer's **intent**, not just raw numbers.

## Three keywords

### `BENCHMARK fn(args)`

Compile-time-aware microbenchmarking.

**What it does**: runs `fn` under controlled conditions, measures time,
allocations, and yields. Reports allocation count per call site using
`@returnAddress()` tracking.

**Why CLEAR is special**: the compiler knows the function's effects. If
`fn` has `EFFECTS :alloc`, the benchmark automatically reports allocation
breakdown. If it has `EFFECTS :blocking`, it reports lock wait time. No
user annotation needed -- the compiler sees the effects and instruments
accordingly.

**Output example**:

```
BENCHMARK process(data) x1000:
  Time:    12.3ms avg (11.8ms p50, 14.1ms p99)
  Allocs:  2,100 per call (98.4 KB total)
    intToString       1,000 calls   48.0 KB  (48 bytes avg)
    concat              800 calls   32.0 KB  (40 bytes avg)
    numericMapPut       300 calls   18.4 KB  (61 bytes avg)
  Yields:  3.2 per call (cooperative yield points hit)
  Arena:   64.0 KB high-water (frame allocator)
```

**Implementation**: ~130 lines of Zig + ~30 lines of transpiler.
- Zig: `CheatLib.benchmark(comptime fn, args, iterations)` function that
  wraps the call with `milliTimestamp()`, arena mark save/restore (for
  high-water measurement), and `@returnAddress()` allocation counters
- Transpiler: parse `BENCHMARK` keyword, emit the `CheatLib.benchmark()` call
- Runtime already has: `milliTimestamp()`, frame arena marks, `checkYield`
  counters

### `SMASH fn(args)`

Adversarial workload generator. Finds performance pathologies, not
correctness bugs.

**What it does**: runs `fn` with automatically generated adversarial inputs
based on parameter types and detected capabilities.

**Why CLEAR is special**: the compiler knows:

| Knowledge | Adversarial input |
|-----------|-------------------|
| Parameter is `String` | Empty, 1-char, 1MB, all same char, unicode edge cases |
| Parameter is `Int64` | 0, -1, max, min, powers of 2 |
| Parameter is `HashMap<K,V>` | Keys that hash-collide (same bucket) |
| Parameter uses `@sharded(N)` | Keys that all route to shard 0 (skew attack) |
| Function is `@reentrant` | Recursive call to test stack depth limit |
| Function has unbounded loops | Inputs that maximize iteration count |

**The killer feature -- shard skew attack**:

Given `@sharded(N)`, SMASH generates N keys where `hash(key) % N == 0`
for all keys. This concentrates all traffic on one shard, triggering the
worst-case contention. The runtime's `checkAndFixSkew` (already in
`control-plane.zig`) detects and auto-fixes this. SMASH reports:

```
SMASH process(data) — adversarial shard skew:
  Generated 10,000 keys routing to shard 0 (of 32)
  Skew detected: CV=5.2 (threshold=1.5)
  Runtime auto-fix engaged: locks enabled on shard 0
  Before fix:  890ms (all traffic serialized on shard 0)
  After fix:    32ms (auto-rebalanced)
  SUGGESTION: consider @sharded(128) to reduce collision probability
```

This is Go-like race detection, but for **performance** instead of
correctness. No other language can do this because no other language knows
the sharding topology at compile time.

**How often does SMASH find real problems?**

| Scenario | Detection rate | Why |
|----------|---------------|-----|
| `@sharded` maps | Always | Skew is inherent; SMASH constructs worst-case keys |
| Recursive functions | Always | Finds stack depth limit by construction |
| Hash maps (any) | Usually | Hash collision attacks are well-understood |
| String processing | Sometimes | Edge cases depend on the algorithm |
| Pure numeric code | Rarely | Numeric edge cases are less predictable |

For any program using `@sharded` maps, SMASH is a guaranteed value-add.
This covers most server-side CLEAR programs.

**Implementation**: ~300 lines.
- Type-based input generator (~100 lines): walks parameter types, produces
  edge-case values. Uses comptime `@typeInfo` to inspect struct fields.
- Shard skew generator (~80 lines): given `@sharded(N)`, generates keys
  with `wyhash(key) % N == target_shard`. Brute-force search over key
  space (fast for string keys -- typically finds collisions in <1ms).
- Harness (~120 lines): runs fn with adversarial inputs, collects timing
  + contention metrics, formats report.

### `PROFILE fn(args)`

Allocation + CPU + contention profiling with capability-aware suggestions.

**What it does**: runs `fn` with `@returnAddress()` allocation tracking
active, plus hardware counters (when available), and reports:
- Allocation hotspots by call site
- Cache miss rate (via `perf stat` when available)
- Lock contention time (via yield tracking)

**Why CLEAR is special**: the profiler knows **capability semantics**. It
doesn't just report "40% CPU in pthread_rwlock_unlock" -- it knows the
variable is declared `@writeLocked` and can suggest "switch to `@locked`
for write-heavy workloads."

**Output example**:

```
PROFILE process(data):
  CPU:
    38.2%  pthread_rwlock_unlock       — lock release overhead
    12.1%  hash_map.getIndex           — hashmap probing
     6.3%  memcpy                      — value copying
  Heap:
    82.0%  intToString                 — 2.1M allocs, 48 bytes avg
     9.3%  concat                     — 800K allocs, 40 bytes avg
  Hardware (perf stat):
    1.66 IPC, 52.9% LLC miss rate, 4.9% branch miss rate
  Suggestions:
    - 38% CPU in rwlock → data is @writeLocked → switch to @locked
      for write-heavy workloads (saves ~15% total CPU)
    - intToString is 82% of heap → consider buffered string building
    - 53% LLC miss rate is inherent to random-access hash probing
      (not fixable by resharding)
```

**Implementation**: ~200 lines.
- `@returnAddress()` alloc tracking (~80 lines in `alloc-profile.zig`):
  fixed-size hash table, records count + bytes per call site
- Profiling harness (~60 lines): wraps fn call with alloc tracking on/off,
  optionally runs `perf stat` subprocess
- Suggestion engine (~60 lines): pattern-matches profile data against
  variable capabilities. Rules like:
  - `>15% CPU in rwlock functions` + variable is `@writeLocked` ->
    "switch to @locked"
  - `>50% heap in one function` -> "allocation hotspot, consider arena"
  - `>20% LLC miss rate` + hashmap hot -> "inherent to random access"

## Foundation: `@returnAddress()` allocation tracking

All three keywords depend on allocation tracking built into the runtime
allocator VTable. See `docs/profiling-plan.md` for the full design.

Key points:
- The Zig allocator VTable already receives `ret_addr: usize` on every
  `alloc` and `free` call (see `runtime.zig:120`)
- Fixed-size hash table (1024 sites, ~24KB) -- no heap allocation inside
  the profiler
- Controlled by comptime flag: zero overhead when not profiling
- `addr2line` resolves addresses to source file:line for reporting

## Implementation order

### v0.1-pre (launch)

1. **`@returnAddress()` alloc tracking** (~150 lines of Zig)
   - `alloc-profile.zig`: site tracker with count, bytes, free tracking
   - Wire into `runtime.zig` `smartAlloc` / `smartFree`
   - Env var `CLEAR_ALLOC_PROFILE` controls output path

2. **`BENCHMARK` keyword** (~130 lines)
   - Parser: recognize `BENCHMARK expr;`
   - Transpiler: emit `CheatLib.benchmark(...)` wrapper
   - Runtime: timing + alloc count + arena high-water measurement

3. **`PROFILE` keyword** (~200 lines)
   - Reuses alloc tracking from step 1
   - Adds capability-aware suggestion engine
   - Optional `perf stat` integration

4. **`SMASH` keyword** (~300 lines)
   - Type-based adversarial input generation
   - Shard skew attack (the demo-worthy feature)
   - Contention detection via control plane integration

### v0.1 (follow-up release)

5. **`./clear doctor` integration**: reads profile output, maps addresses
   to CLEAR source lines, produces the formatted report
6. **Temporal alloc snapshots**: periodic dumps for leak detection (tier 3
   from profiling-plan.md)
7. **SMASH coverage reporting**: which adversarial paths were exercised,
   which were not

## Total effort

| Component | Lines | Priority |
|-----------|-------|----------|
| Alloc tracking (`alloc-profile.zig`) | ~150 | Foundation |
| `BENCHMARK` | ~130 | v0.1-pre |
| `PROFILE` | ~200 | v0.1-pre |
| `SMASH` | ~300 | v0.1-pre |
| `./clear doctor` | ~400 | v0.1 |
| **Total** | **~1180** | |

## The demo

```
-- ILLUSTRATIVE (v0.1-pre planned syntax)
FN process(data: HashMap<String>@sharded(32):writeLocked) RETURNS Void ->
    FOR key IN data.keys() ->
        data[key] = transform(data[key]);
    END
END

-- Step 1: How fast is it?
BENCHMARK process(sample_data);

-- Step 2: What breaks it?
SMASH process(sample_data);
-- "Generated 10,000 keys routing to shard 0. Skew detected. Runtime auto-fixed."

-- Step 3: Where is the time going?
PROFILE process(real_data);
-- "38% CPU in rwlock. Switch @writeLocked -> @locked for write-heavy workloads."
```

No other language can do this. The compiler's knowledge of capabilities,
effects, and call graph -- combined with the runtime's control plane --
makes these tools aware of the programmer's architectural intent. They
don't just report numbers; they tell you what to change and why.
