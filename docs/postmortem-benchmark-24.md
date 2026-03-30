# Post-Mortem: Benchmark 24 — TCP JSON File Server

## Summary

Benchmark 24 was the first end-to-end server workload: accept → spawn fiber → read file → FFI JSON parse → respond → close → accept next. It exposed 3 real bugs and 3 design gaps. Previous benchmarks (compute-only, single-connection) never exercised these paths.

## Real Bugs (would affect users)

### 1. Resource fd leak in BG fibers — Transpiler

**Severity:** Critical. Every TCP server program was broken.

When a `TCPClient` was captured by a BG block, the transpiler set `client_moved = true` to suppress the outer `defer socketClose`, but emitted no replacement close in the fiber. The fd leaked. When the kernel recycled the fd number for a new connection, stale epoll registrations caused segfaults.

**Fix:** Transpiler now emits `defer CheatLib.socketClose(ctx.client)` for resource variables captured by BG blocks.

**Why it wasn't caught before:** The scheme interpreter and other examples don't use TCP. Benchmark 20 (TCP kvstore) uses `@pinned` fibers with `@sharded` maps — the auto-pin annotation triggers a different code path that happened to not exhibit the leak.

### 2. GPA vs c_allocator — jemalloc incompatibility — Runtime

**Severity:** Critical when jemalloc is used (all benchmarks via runner).

ReleaseFast defaulted to Zig's GPA (mmap-based allocator). The runner preloaded jemalloc which intercepts `malloc`/`free` but not `mmap`. Any allocation that crossed the boundary (e.g., GPA-allocated memory freed through a c_allocator path, or vice versa) caused silent corruption.

**Fix:** ReleaseFast/ReleaseSmall now default to `std.heap.c_allocator`. jemalloc intercepts all allocations consistently. Debug/ReleaseSafe still uses GPA for leak detection.

**Why it wasn't caught before:** Previous benchmarks ran in-process (no fiber IO), so the allocation patterns were simpler and the cross-allocator paths were never exercised.

### 3. Frame mark not triggered by `uses_alloc` — Transpiler

**Severity:** Moderate. Functions using only stdlib `{alloc}` calls (concat, split, intToString) never got frame marks. Their frame allocations accumulated unboundedly.

**Fix:** Frame mark emission now checks `uses_frame || uses_alloc`. Functions returning non-primitive types skip the mark so returned data survives on the caller's frame.

**Why it wasn't caught before:** Most functions either ran in `main()` (which always gets a frame mark) or were short-lived with few allocations.

## Design Gaps (not bugs, but exposed by server workloads)

### 4. socketRead 4 KB stack buffer

`var buf: [4096]u8 = undefined` in `socketRead` consumed 4.3 KB of the fiber's 12 KB usable stack. Previous benchmarks had simpler handlers with room to spare.

**Fix:** Read buffer moved to frame allocator. Stack frame: 4368 → 368 bytes.

### 5. EXTERN FN not trampolined to g0

EXTERN calls ran on the fiber's 16 KB stack. Native libraries (std.json recursive descent) overflow this easily.

**Fix:** All EXTERN FN calls now trampoline to g0 via `onRootStack`. The trampoline uses the scheduler's OS thread stack (same as Go's g0). Fast-path bypass when already on the OS stack (main thread, nested calls).

### 6. shell() forks the process

`shell("mkdir -p data")` calls `fork()` which duplicates the process memory map. On a fiber, the child process setup also uses significant stack. Replaced with FFI `ensureDir` using `std.fs.cwd().makePath`.

## Not Alarming

- **Stack smashing under ReleaseSafe:** Expected — safety checks inflate stack frames. Will be addressed by `__morestack` insertion.
- **O(N²) string concat performance:** Known characteristic, not a bug. `join` pattern is the correct solution.
- **Port TIME_WAIT between test runs:** Test infrastructure, not a language bug.

## Key Takeaway

The fd leak (#1) is the only bug that would have bitten a user writing a normal CLEAR program. The c_allocator default (#2) only matters with jemalloc preloading. The frame mark gap (#3) requires specific function patterns to trigger.

The architecture is sound. The holes were at the seams between subsystems (transpiler ↔ runtime, fiber ↔ OS, frame allocator ↔ heap allocator) that only show under real server workloads. Benchmark 24 was the right stress test to find them.
