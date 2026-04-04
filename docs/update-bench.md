# Benchmark Status & Known Issues (2026-04-04)

## Benchmark Results Summary

### Fiber Runtime (non-HTTP, 32 cores)

| # | Benchmark | vs Go | vs Rust | Status |
|---|-----------|-------|---------|--------|
| 11 | atomic_contention | **-78%** | n/a | Good |
| 12 | fanout_fanin | **-42%** | +145% | Good (Rust faster: stackless tasks) |
| 13 | backpressure | **-49%** | **-37%** | Good |
| 14 | dynamic_spawn | +253% | +130% | Known: idle scheduler spinning |
| 15 | stream_merge | **-61%** | **-67%** | Fixed this session (buffered SPSC) |
| 16 | pubsub | **-84%** | **-96%** | Good (near-linear scaling) |
| 17 | kvstore | **-89%** | **-17%** | Fixed this session (BG capture bug) |
| 18 | shard_vs_locked | n/a | n/a | CLEAR-only, scales to 16c |
| 19 | parallel_aggregation | +8% | +63% | Slower than both |

### TCP Servers

| # | Benchmark | CLEAR (1c) | Rust (1c) | Go (1c) | Status |
|---|-----------|-----------|-----------|---------|--------|
| 20 | tcp_kvstore (P=16, 2c) | 361K SET, 526K GET | n/a | n/a | Working (vs Dragonfly below) |
| 24 | json_api | SET 419ms, GET 5191ms | SET 63ms, GET 129ms | SET 58ms, GET 739ms | onRootStack bottleneck |
| 25 | pathological | 125K rps | 159K rps | 79K rps | Good at 1c (+58% vs Go) |

### CLEAR vs DragonflyDB (benchmark 20, 2 cores, P=16)

| Op | CLEAR | Dragonfly | Ratio |
|----|-------|-----------|-------|
| SET | 361K | 1.27M | 28% |
| GET | 526K | 1.33M | 40% |
| INCR | 465K | 1.32M | 35% |

## Known Bugs

### 1. Epoll fd corruption on fiber migration (pre-existing)

When a fiber moves between schedulers (via work-stealing), its TCP fd
is registered with the old scheduler's epoll. The new scheduler
re-registers it, causing two epoll instances to watch the same fd.
Result: double-push to ready queue, use-after-free.

- **Workaround**: `spawnPinned` with `@sharded` map capture auto-pins
  fibers. BG blocks that capture resources use `submitSpawn` on the
  accepting scheduler.
- **Proper fix**: unregister fds from old scheduler's epoll on steal,
  or track fd-to-scheduler affinity in the runtime.
- **Impact**: TCP servers limited to single-scheduler I/O throughput.

### 2. String@raw charAt causes stall under concurrent TCP load

`CheatLib.charAt` (O(1) byte access) works correctly in isolation and
passes all tests (50 workers x 10K rounds). But under concurrent TCP
connections (2+), the server stalls after processing the first batch.

- **Root cause**: Not yet confirmed. Suspected scheduler starvation -
  the fast non-allocating charAt path completes so quickly that
  cooperative yield points don't trigger effectively. With
  `charAtCodepoint` (which allocates per call), the slower pace gives
  other fibers time to be scheduled.
- **Workaround**: Don't use `String@raw` on TCP server data. The
  `charAtCodepoint` path works reliably under all loads.
- **Impact**: TCP RESP parsers use O(n) UTF-8 charAt instead of O(1)
  byte access. ~3x slower parsing per command.

### 3. EXTERN zero-arg function trampoline broken

`EXTERN FN cwd() RETURNS Dir FROM "std.fs"` generates a trampoline
struct with an empty field list, producing a stray comma in Zig output.
EXTERN method calls (`cwd().makePath("data")`) are also broken.

- **Workaround**: Use a native Zig shim (e.g. `json_native.zig`) for
  functions that need method calls on EXTERN return values.
- **Fix**: Fix trampoline struct field generation for zero-arg functions
  in `src/transpiler.rb` (partially fixed - comma issue resolved, but
  method call chaining still broken).

## Known Performance Issues

### 1. onRootStack overhead (~500us per call)

Every `readFile`, `writeFile`, and non-`:safe` EXTERN FFI call goes
through `onRootStack`, which switches from the fiber stack to the
scheduler's OS stack and back. Cost: ~500us per round-trip.

- **Impact**: Benchmark 24 GET is 83x slower than Rust (10000 GETs x
  500us = 5000ms). Benchmark 24 SET is 7x slower (writeFile per SET).
- **Fix options**:
  - `:safe` EFFECTS annotation (runs on fiber stack directly) - but
    crashes under concurrent load due to std.json's stack usage
  - Async file I/O via io_uring (avoids stack switch entirely)
  - Larger fiber stacks for `:safe` handlers (`@service` annotation)

### 2. Idle scheduler spinning (benchmarks 12, 14)

At 32 cores, idle schedulers spin on work-stealing CAS operations,
wasting CPU. Benchmark 14 is 3.5x slower at 32 cores than at 8 cores.
Benchmark 12 regresses from -83% vs Go at 16c to -42% at 32c.

- **Fix**: Scheduler parking (idle schedulers sleep instead of spin).
  Post-v0.1.

### 3. Frame arena growth in pipelined command loops

Functions returning reference types (String) can't use frame mark
save/restore (returned data must survive). When called in loops
(e.g. `generateJson` inside a WHILE parsing pipelined commands), frame
arena allocations accumulate without being reclaimed.

- **Impact**: Benchmark 24 SET uses string concat for JSON generation,
  causing frame arena growth per pipelined command.
- **Fix**: Functions returning references should save mark, do work,
  copy result past mark, then restore. Requires compiler support.

### 4. charAtCodepoint O(n) per call

`charAt` on regular `String` iterates UTF-8 codepoints from the start
to reach index i. For RESP parsing (byte-by-byte), this is O(n^2).
Also allocates a new string per call via `alloc.dupe`.

- **Impact**: TCP servers spend significant CPU on charAt. Benchmark 25
  went from 19K to 125K rps when switched to `String@raw` (at 1
  connection).
- **Fix**: `String@raw` capability dispatch is implemented and working.
  Blocked by bug #2 (concurrent stall) for TCP servers.

### 5. Single-scheduler TCP I/O

Due to bug #1 (epoll fd corruption), all TCP handler fibers run on one
scheduler. Rust/Go distribute across all cores.

- **Impact**: Benchmark 25 at 32c: CLEAR 101K vs Go 313K vs Rust 303K.
  At 1 core (fair comparison): CLEAR 125K vs Go 79K vs Rust 159K.
- **Fix**: Proper epoll fd migration in the runtime. Post-v0.1.

## Session Changes (2026-04-04)

### Fixes
- Buffered SPSC ring in InfStream (50x throughput, stream_merge beats Go/Rust)
- Same-scheduler fast path in submitResume (skip SPSC for local resumes)
- BG block capture excludes loop-local variables (fixes kvstore compile)
- EXTERN trampoline empty-field comma fix
- Capability-aware STD_LIB dispatch (String@raw charAt O(1))
- BG blocks with TCP resources spawn on accepting scheduler
- Skip fiber stack memset in release mode
- Stack cache limit 16 -> 128
- Benchmark 25 heavyCompute sign fix + toNumber fallback fix

### New Tests
- infstream-bench.zig: InfStream throughput micro-benchmark
- infstream-hammer-test.zig: 4M values across 8 concurrent streams
- test_charAt_raw.zig: 50-worker concurrent charAt stress test
- 2 annotator specs for charAt capability dispatch
