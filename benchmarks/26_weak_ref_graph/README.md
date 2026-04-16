# Benchmark 26: Weak Reference Graph

Builds a binary tree of N=200K nodes. Each child stores a back-pointer to its parent.

- **CLEAR**: nodes are `@multiowned` (Rc), parent back-pointers are `@link` (WeakRc)
- **C**: nodes are individual `malloc`, parent back-pointers are raw `Node*`

Two timed phases:
- **BUILD**: allocate N nodes + wire N-1 parent back-pointers (one LINK/rcDowngrade per non-root)
- **WALK**: linear scan resolving every parent back-pointer (one RESOLVE/weakRcUpgrade per node)

`BENCH_RESULT` = total (build + walk + cleanup)

## Results (200K nodes)

| Implementation | Total | Build | Walk | Peak RSS |
|----------------|-------|-------|------|----------|
| C (raw pointers) | ~10ms | - | - | 12032 KB |
| CLEAR (Rc + WeakRc) | ~14ms | - | - | 40448 KB |

CLEAR is ~40% slower than C. Cost breakdown:
- **rcCreate**: one heap alloc per node (same as C's per-node malloc)
- **rcDowngrade** (LINK): increments weak refcount (C: pointer assignment)
- **weakRcUpgrade** (RESOLVE): checks strong > 0, increments strong (C: dereference)
- **rcRelease**: list deinit decrements and frees all Rc nodes (C: separate free loop)

## Why the RSS is 3x

CLEAR's 32-thread scheduler allocates runtime state (epoll, io_uring, run queues, EBR)
at startup. This is the same ~25MB fixed cost seen in all CLEAR benchmarks. The actual
data (200K nodes at ~32 bytes each) is ~6MB in both C and CLEAR.

## Grade

The +40% overhead is the actual cost of Rc + WeakRc vs raw pointers.
This is an honest measurement of the reference-counting abstraction tax.
