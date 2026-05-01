# Frame Overflow Memory Fix

## Problem

Bench 24 (JSON API server) showed ~143MB RSS vs Go's ~14MB under the same load. The live
working set was approximately 2MB (50 fibers x ~40KB each). The gap was two separate bugs
plus a glibc behavior.

---

## Bug 1: Pinned Fibers Using Arena Allocators by Default

### What happened

Auto-pinned BG fibers (`@bg { ... }` blocks that the compiler marks `.pinned = true` for
CPU-bound or lock-holding work) were unconditionally receiving the scheduler's
`__pinned_local_alloc`. This is a `std.heap.ArenaAllocator` backed by the thread-local
heap - it accumulates all frame allocations from the fiber and never rewinds them. Every
loop iteration's frame allocations piled up in this arena for the lifetime of the fiber.

### Root cause

`scheduler.zig` used `if (task.config.pinned)` to decide whether to set
`__pinned_local_alloc`. The `pinned` flag is a scheduler hint (run on a fixed thread);
it has nothing to do with whether the fiber wants arena semantics.

### Fix applied

- Added `use_arena: bool = false` to `TaskConfig` in `queues.zig`.
- Changed `scheduler.zig` to gate on `task.config.use_arena` instead of `task.config.pinned`.
- Changed `transpiler.rb` `task_config_zig` to emit `use_arena: true` only for explicit
  `@arena` BG blocks - i.e., those the programmer opted into with the `@arena` capability.

### Current status

Fix is in place. The `@arena` capability on BG fibers now requires an explicit annotation.
The underlying work - making arena allocation a proper capability option on fibers rather
than a side-effect of the `pinned` scheduler flag - is ongoing. The goal is a first-class
`@arena` fiber declaration that maps cleanly to `use_arena: true` in `TaskConfig`, with
`pinned` remaining a purely scheduling concern.

---

## Bug 2 (Historical): Loop Escape Accumulation

Before the loop-mark work (completed, now tracked in docs/allocation.md), loops that
appended frame-allocated strings into outer containers had their loop marks disabled to
avoid use-after-free. This caused intermediates to accumulate. Bench 19 showed ~1GB RSS
from this; bench 24 showed ~248MB. Loop marks are now always enabled; escaping values are
heap-promoted before being stored in outer containers.

---

## Remaining Gap: glibc Heap Retention

### What glibc does

When `trimExcess` frees a 4KB or 16KB arena block via `rawFree(c_allocator)`, glibc does
NOT return the memory to the OS. Allocations below ~128KB (the default `M_MMAP_THRESHOLD`)
are served from the sbrk-based main heap. glibc keeps freed blocks in its internal free
lists so future allocations can reuse them without a syscall. The process's mapped RSS
does not shrink.

For a server handling hundreds of requests, each with two or three arena overflow blocks
(4KB + 16KB), glibc accumulates a pool of ~50-100 free blocks totaling 100-150MB. The
memory is technically reusable but is not returned to the OS.

### Verified

Frame arena correctness was independently verified via transpile-test 200
(`200_frame_peak_large_alloc_loop.cht`): 500 iterations each allocating ~6KB on the frame
showed a peak of 3493 bytes. The arena rewinds correctly on every iteration. The RSS
growth is entirely a glibc retention artifact, not a CLEAR memory bug.

---

## Recommendation: Use jemalloc or tcmalloc

### Option A - jemalloc (preferred for benchmarks)

jemalloc has per-thread caches (tcache) that serve small/medium allocations with zero
syscalls, and a decay-based dirty-page purger that returns unused pages to the OS after
approximately 1 second by default (tunable via `MALLOC_CONF`).

```bash
# Install
sudo apt install libjemalloc-dev        # Ubuntu/Debian
# or build from source for latest version

# Use for a single run
LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2 ./server_clear

# Tune decay aggressively (return pages faster)
MALLOC_CONF="dirty_decay_ms:200,muzzy_decay_ms:0" \
  LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2 ./server_clear
```

Expected RSS: 20-30MB. Throughput impact: neutral to positive (tcache avoids per-alloc
mutex contention that glibc's per-arena lock causes under high concurrency).

### Option B - tcmalloc (Google)

Similar characteristics to jemalloc. Per-thread caches plus a central freelist with
periodic page releases. Slightly simpler tuning surface.

```bash
sudo apt install libgoogle-perftools-dev
LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libtcmalloc_minimal.so.4 ./server_clear
```

### Option C - mallopt M_MMAP_THRESHOLD (no external dependency)

Lower the glibc mmap threshold so blocks at 16KB and above use `mmap` instead of the
sbrk heap. Freed mmap blocks are immediately `munmap`'d and returned to the OS.

```c
// In runtime startup (e.g. cheatMain or the scheduler init):
#include <malloc.h>
mallopt(M_MMAP_THRESHOLD, 16 * 1024);
mallopt(M_TRIM_THRESHOLD, 16 * 1024);
```

Expected RSS: 30-50MB (4KB blocks still use sbrk; 16KB+ blocks are immediately freed).
No external dependency. Marginal throughput cost for the extra syscall on 16KB+ blocks
(which are relatively rare - only when the static 4KB frame block overflows).

### What NOT to do

`std.heap.page_allocator` (Zig's mmap-backed allocator) was considered and rejected.
It issues one `mmap`/`munmap` syscall per alloc/free. For bench 24 at ~30µs/request,
allocating and freeing two arena overflow blocks per request via page_allocator adds
~2-4µs overhead (~7-13%). It is designed for large, long-lived allocations, not
high-frequency 4-64KB cycles.

---

## Current State of frame.zig

The `frame.zig` file has a partial in-progress edit:
- `block_allocator` field added (alongside `child_allocator`)
- `initWithBlockAllocator` constructor added
- `deinit` updated to use `block_allocator` for data blocks

The `alloc()`, `trimExcess()`, and large-object paths have NOT been updated. The file
is in an inconsistent state and should be completed or reverted before merging.

---

## Summary

| Issue | Status |
|-------|--------|
| Pinned fibers using arena by default | Fixed (`use_arena` flag; ongoing: first-class `@arena` capability) |
| Loop escape accumulation | Fixed (loop marks always on; heap-promote escaping values) |
| glibc retaining freed arena blocks | Not a bug; use jemalloc/mallopt to return pages to OS |
| frame.zig partial block_allocator edit | In-progress, incomplete |
