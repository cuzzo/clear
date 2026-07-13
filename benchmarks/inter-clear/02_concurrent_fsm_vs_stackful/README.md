# FSM vs stackful BG tasks

Compares two CLEAR-only variants of the same short-lived BG workload:

- `bench_fsm.clear`: default BG body, FSM-eligible.
- `bench_stackful.clear`: `@standard` BG body, forced stackful.

Both spawn and join 100,000 futures. The body does trivial arithmetic,
so this primarily measures task scheduling and pool overhead.

The stackful variant calls `touchCurrentFiberStack(16_384, seed)` inside
each worker. That faults the full standard stack allocation so RSS reflects
stack-pool residency. Both variants also print `BENCH_INFO` with current
RSS, peak RSS, and peak virtual memory from `/proc/self/status`.

Run manually:

```bash
./clear build --optimized benchmarks/inter-clear/02_concurrent_fsm_vs_stackful/bench_fsm.clear -o /tmp/bench_fsm
./clear build --optimized benchmarks/inter-clear/02_concurrent_fsm_vs_stackful/bench_stackful.clear -o /tmp/bench_stackful
/usr/bin/time -f 'fsm elapsed=%e rss=%M' env CLEAR_THREADS=32 /tmp/bench_fsm
/usr/bin/time -f 'stackful elapsed=%e rss=%M' env CLEAR_THREADS=32 /tmp/bench_stackful
```

Recent 100k sample:

```text
fsm      median 0.30s  RSS 38912 KB  VmPeak ~2609608 KB
stackful median 0.23s  RSS 58624 KB  VmPeak ~2660632 KB
```
