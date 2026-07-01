# FSM concurrency benchmark

A `clear-only` benchmark measuring the per-concurrent-fiber RAM cost
of CLEAR's stackless FSM lowering vs the legacy stackful fiber path.
Both variants run identical workloads (spawn N fibers, each suspending
once on `sleep`, then await all). The only difference is whether the
BG body lowers to a stackless `FsmTask` or a `spawnBest` with a real
per-fiber stack.

## Variants

| File | BG body | Lowering | Per-fiber stack |
|---|---|---|---|
| `bench_fsm.clear` | `BG { sleep(50); }` | FSM (`FsmTask` + `runStep0/runStep1`) | none -- ctx struct on heap |
| `bench_stackful.clear` | `BG { @standard -> napFor(50); }` | stackful (`spawnBest`) | 16 KB tier (4 KB body + 12 KB safety+arena) |

`@standard` is the smallest tier the stack-safety analyzer accepts
for code that calls `sleep`. `@micro` (4 KB) is rejected by
call-graph analysis without `:canSmash`. This is the realistic
baseline a stackful path would actually use.

The stackful variant routes `sleep` through `napFor()` because the
stackful BG path's transpiler currently mis-rewrites bare
`sleep(...)` inside an annotated BG (emits `rt.sleep(...)` instead of
`__rt_bg0.sleep(...)`). Wrapping in a user fn dodges the bug;
functionally identical.

## Results

### n = 5,000 concurrent suspended fibers

```
=== FSM ===
elapsed=0.05  rss_kb=4096
=== Stackful @standard ===
elapsed=0.07  rss_kb=46592
```

| Metric | FSM | Stackful @standard | Delta |
|---|---|---|---|
| Peak RSS | 4.0 MB | 46.6 MB | **-91% (~12x less)** |
| Per-fiber overhead | ~0.7 KB | ~9.3 KB | -92% |
| Wall time | 50 ms | 70-80 ms | -29% to -38% |

### n = 20,000 concurrent suspended fibers

```
=== FSM ===
elapsed=0.05  rss_kb=8960
=== Stackful @standard ===
elapsed=0.16  rss_kb=179456
```

| Metric | FSM | Stackful @standard | Delta |
|---|---|---|---|
| Peak RSS | 8.9 MB | 179.5 MB | **-95% (~20x less)** |
| Per-fiber overhead | ~0.5 KB | ~9 KB | -94% |
| Wall time | 50 ms | 160 ms | -69% (3x faster) |

The FSM win compounds with concurrency: at n=5000 it's 12x less
memory; at n=20,000 it's 20x. Stackful's per-fiber cost is constant
(committed pages of the 16 KB tier); FSM's is tiny (ctx struct + waiter).

## Why FSM wins on memory

A stackful fiber gets a 16 KB `mmap`'d stack. Linux commits pages
on touch — for the work involved here, ~9 KB get committed per
fiber. At 20,000 fibers that's ~180 MB of resident memory just for
stacks.

An FSM task allocates only its `BgCtx` struct (task / rt / inner /
alloc + bound captures, ~96 B for this body) plus its `FsmIoWaiter`.
No fiber stack — the dispatch runs on the scheduler thread's stack.
At 20,000 fibers that's ~3 MB of structural overhead, plus the
io_uring rings, executable, runtime — total ~9 MB.

## Why FSM wins on wall time at scale

Stackful spawn cost = mmap a stack, page-fault as touched, run
context switch via `switch.S` to enter the body. Each spawn
also touches its own stack pages, generating a minor page fault
per fiber. At 20,000 fibers that's tens of thousands of minor
page faults the kernel has to service.

FSM spawn cost = heap-allocate a small ctx struct, call resumeFn
inline. No mmap, no context switch, no per-fiber page faults
beyond what the heap allocator triggers (which amortizes across
chunked allocations).

## Running

```bash
./clear build benchmarks/clear-only/fsm_concurrency/bench_fsm.clear --optimized \
    -o benchmarks/clear-only/fsm_concurrency/bench_fsm
./clear build benchmarks/clear-only/fsm_concurrency/bench_stackful.clear --optimized \
    -o benchmarks/clear-only/fsm_concurrency/bench_stackful

/usr/bin/time -f "elapsed=%e rss_kb=%M" \
    ./benchmarks/clear-only/fsm_concurrency/bench_fsm
/usr/bin/time -f "elapsed=%e rss_kb=%M" \
    ./benchmarks/clear-only/fsm_concurrency/bench_stackful
```

Or use `compare.sh` for a side-by-side 5-run comparison.

## History

Earlier versions of this benchmark capped at n=400 due to a runtime
use-after-free in `dispatchOnce` where the resumeFn destroyed `ctx`
(containing `task`) before `dispatchOnce` wrote `task.status =
.Finished`. The fix moved destruction to `FsmTask.destroy_fn`,
invoked by the scheduler AFTER `dispatchOnce` returns. The benchmark
now scales to 100,000+ FSMs cleanly.
