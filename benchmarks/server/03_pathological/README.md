# Benchmark 25: Pathological Workloads

Tests scheduler fairness under mixed compute loads. Pure integer math (no I/O),
50 concurrent connections, 100K requests, three phases:

- **Phase 1: Uniform** - all requests do equal work (100 iterations)
- **Phase 2: Skewed** - 0.5% of requests do 1000x more work (10K vs 10 iterations)
- **Phase 3: Adversarial** - one connection does all heavy work (10K iters), rest do 10

## Results (100K requests, 50 concurrent)

| Server | Uniform (r/s) | Skewed (r/s) | Adversarial (r/s) | Peak RSS |
|--------|--------------|-------------|------------------|----------|
| CLEAR (fibers) | 474,933 | 507,668 | 403,787 | 38680 KB |
| Go (goroutines) | 335,961 | 322,227 | 300,750 | 12700 KB |
| Rust (tokio) | 307,915 | 293,725 | 270,094 | 4756 KB |

CLEAR is ~40-60% faster than Go and Rust across all phases.

## Why CLEAR wins on pure compute

This is a CPU-bound benchmark with no disk I/O, no parsing, no allocation.
The fiber scheduler's dispatch overhead is the only variable.

CLEAR's fiber scheduler uses a work-stealing run queue with cooperative
scheduling. For pure compute tasks that yield only at scheduling points
(fiber_yield on tcpRead/tcpWrite), the scheduler has very low overhead:
each request is dispatched and completed without contention on the epoll fd.

Go's goroutines and Rust's tokio use preemptive/async scheduling with
heavier runtime overhead per task switch.

## Why CLEAR uses more memory

Each of 32 schedulers maintains a fiber stack cache. After 50 concurrent
connections, each scheduler holds ~50 cached 16KB stacks = ~25MB.
See bench 24 Memory Analysis for full breakdown.

## Scheduler fairness

The Adversarial phase (one slow connection) shows CLEAR's scheduler handles
heavy/light mix well: 403K r/s vs 335K for Go and 270K for Rust. The heavy
connection does not starve the other 49.
