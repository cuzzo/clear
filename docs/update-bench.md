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

### 1. Epoll fd corruption on fiber migration (partially fixed)

When a fiber moves between schedulers (via work-stealing), its TCP fd
was registered with the old scheduler's epoll. Fixed in commit 62926ee2:
registerFd now tracks epoll_fd/epoll_io_fd on the Task and unregisters
from the old scheduler before registering with the new one.

- **Status**: Basic migration works (verified by test_tcp_charAt_stall.zig:
  32 clients x 1000 msgs across 8 schedulers). The `spawnPinned`
  workaround may no longer be necessary for most cases.
- **Remaining risk**: Double-push race (task pushed to ready queue while
  already in it) documented in tcp-fairness-test.zig. Guard: skip push
  if task is already Ready (in_inbox flag partially addresses this).

### 2. ~~String@raw charAt causes stall under concurrent TCP load~~ RESOLVED

Was caused by epoll fd corruption on fiber migration (Bug #1), fixed
in commit 62926ee2 (registerFd unregisters from old scheduler's epoll).
Verified with test_tcp_charAt_stall.zig: 32 clients x 1000 msgs with
charAt fast-path across 8 schedulers, 5/5 passes in both Debug and
ReleaseFast modes. String@raw is safe for TCP servers.

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

### 1. ~~onRootStack overhead (~500us per call)~~ DEBUNKED

The 500us figure was wrong by 100x. Measured via test_onRootStack.zig:
- Trampoline cost: 5 ns (ReleaseFast), 17 ns (debug)
- readFile I/O: 2.2 us (open + fstat + read + close syscalls)
- readFile on g0: 2.3 us (virtually identical to direct call)

The bench 24 GET bottleneck at 4 cores is filesystem I/O, not the
trampoline. At 16+ cores all three languages (CLEAR/Rust/Go) converge
to within 1% on bench 24.

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
