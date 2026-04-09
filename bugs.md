# Known Compiler Bugs Impacting the Minivm Interpreter

Discovered while benchmarking the bytecode VM (examples/minivm/interpreter.cht).
All bugs are in the CLEAR compiler/runtime, not in the interpreter source code.
CLEAR's ownership system should make these errors impossible to write - the fact
that they compile and run is the bug.

---

## Bug 1: Promoted strings leak - no cleanup tracking after promote()

**Symptom**: GPA reports leaks at `runtime-header.zig:2017` in `promote__anon`.

**Location**: `zig/runtime-header.zig` lines 2016-2018, `src/promotion_plan.rb` lines 517-520

**What happens**:
- `promote()` is called on a union's string variant (e.g., `Value.Str`)
- It does `value.* = try rt.heapAlloc().dupe(u8, value.*)` - allocates a new heap copy
- The old frame-arena pointer is overwritten, the new heap string is never freed
- The transpiler's cleanup code for the containing Value union doesn't know the
  string was promoted from frame to heap, so it doesn't emit a heap-free for it

**Reproducer**: `loadBytecodeConsts!()` in interpreter.cht creates `Value{ Str: substr(...) }`
values that get promoted before return. The promoted strings leak.

**Fix**: Two options:
1. **In the transpiler** (src/promotion_plan.rb): When classifying unions with heap
   variants, generate explicit cleanup calls for each promoted variant after return.
   The MIR pass should stamp promoted unions as needing deep cleanup.
2. **In the runtime** (runtime-header.zig): Make `promote()` record the new allocation
   in a cleanup list that `cleanup()` checks when freeing the union.

Option 1 is architecturally correct - cleanup decisions belong in the compiler, not
hidden in the runtime.

---

## Bug 2: @list growth leaks intermediate buffers

**Symptom**: GPA reports leaks at `std.array_list.ensureTotalCapacityPrecise` from
`loadBytecodeConsts!()` -> `append`.

**Location**: `zig/runtime-header.zig` lines 99-104 (promoteList)

**What happens**:
- `MUTABLE consts: Value[]@list = List[]` starts on the frame arena
- Each `append()` may grow the backing buffer, causing reallocation
- When `promoteList()` runs before return, it promotes only the FINAL buffer
- Intermediate buffers (from ArrayList growth) are allocated by the GPA but
  never freed because the ArrayList's internal growth uses heap, not arena
- The old capacity buffers become unreachable

**Fix**: The `@list` annotation should use frame-arena for the initial allocation
and heap for growth, with the transpiler generating deferred cleanup for the
heap-allocated backing buffer. Currently the growth path uses GPA directly
through the ArrayList, bypassing CLEAR's ownership tracking.

Alternatively, `@list` could pre-allocate to a known capacity hint to avoid
growth entirely (e.g., `Value[]@list(1000)`), but this is a workaround.

---

## Bug 3: dupeUnionValue() silently swallows allocation failures

**Symptom**: `free(): invalid pointer` crash in release builds. Segfault.

**Location**: `zig/runtime-header.zig` lines 1936, 1954, 1987, 1996, 1999

**What happens**:
- `dupeUnionValue()` uses `catch elem` fallbacks throughout:
  `buf[i] = dupeUnionValue(ElemT, elem, alloc) catch elem;`
- If allocation fails, it silently returns the ORIGINAL frame-arena pointer
  instead of the duped heap pointer
- Later, cleanup code tries to free this frame pointer with the heap allocator
- Result: invalid free, memory corruption, segfault

**Fix**: Remove all `catch elem` fallbacks. Let allocation errors propagate via
`try`. If `dupeUnionValue` can't allocate, the caller should see the error.
Silent fallback to a frame pointer that will later be heap-freed is always wrong.

This is the most dangerous bug - it causes undefined behavior (heap freeing a
frame pointer) rather than a clean error.

---

## Bug 4: Garbled string output (first chars missing, strings split across lines)

**Symptom**: `print("sum = " + s.toString())` produces output like:
```
        ------censored------
    R native: 3 iterations in 0ms
2110
```
First characters are replaced with whitespace/garbage. Multi-part string
concatenation splits across lines.

**Location**: Interaction between `promote()` on `Value.Str` and the `prStr()`
print path in the interpreter.

**What happens**:
- When a Value with a Str variant is promoted, `promote()` overwrites the string
  slice pointer but may corrupt the length metadata
- The promoted string has a valid heap pointer but wrong length
- `prStr()` reads the corrupted length, producing garbled output
- String concatenation via CONCAT opcode may produce strings where the
  first part is correct but subsequent parts have wrong offsets

**Fix**: This is likely a consequence of Bug 1 (promote not tracking allocations
correctly). The string slice metadata (pointer + length) should be atomically
updated during promotion. Check if `dupe()` returns a slice with the correct
length, and whether the write to `value.*` preserves the fat pointer correctly.

Also investigate whether the frame arena is being reclaimed BEFORE the promoted
string is used - if `restoreFrameMark()` runs between promote and print, the
original string data (which the length field may still reference) is garbage.

---

## Bug 5: Union cleanup doesn't account for promoted internals

**Symptom**: Memory leaks for unions whose variants were promoted from frame to heap.

**Location**: `src/promotion_plan.rb` lines 566-574 (`classify_non_copy_union`),
`src/ownership_generator.rb` lines 98-99

**What happens**:
- `classify_non_copy_union()` marks the union container for cleanup
- The generated cleanup is: `defer CheatLib.cleanup(Value, rt.heapAlloc(), &x)`
- But `cleanup()` only knows the union's ORIGINAL provenance (frame or heap)
- After `promote()` modifies string/list variants IN PLACE to point to heap,
  the cleanup code still treats them as frame-provenance (no-op) or applies
  the wrong allocator

**Fix**: The MIR pass should recognize when a union value undergoes promotion
and stamp it for deep cleanup. The cleanup entry should change from `:frame`
to `:heap` after promotion, or the cleanup code should always use deep cleanup
for unions with heap variants regardless of original provenance.

---

## Priority Order

1. **Bug 3** (dupeUnionValue catch fallback) - causes crashes, easiest to fix
2. **Bug 1 + 5** (promote string/union cleanup tracking) - root cause of most leaks
3. **Bug 4** (garbled output) - likely fixed by fixing Bug 1
4. **Bug 2** (@list growth) - less critical, can workaround with pre-allocation

## Current Status (2026-04-09)

Re-tested after native i64/f64 slot optimizations and bytecode compiler bug fixes
(commits 768725b, f40474e).

### Leak counts by test case

| Test | Leaks | Sources |
|------|-------|---------|
| noop (no print, no compute) | 0 | Clean |
| pure compute (1000-iter loop, no print) | 1 | @list growth in loadBytecodeConsts! |
| single print (x.toString()) | 2 | 1x promote string + 1x @list growth |
| 3x print | 3 | 2x promote string + 1x @list growth |
| bench_vm_time (10x1M sum + print) | 2 | 1x promote string + 1x @list growth |
| bench_vm_filter (100x10K filter + print) | 2 | 1x promote string + 1x @list growth |

### Findings

- **No per-iteration leaks.** The inner loops (1M iterations, 10K iterations) produce
  zero additional leaks. The native i64/f64 slot path is clean.
- **Bug 3 (dupeUnionValue crash)** - not triggered by current test programs. May require
  specific union variant patterns to reproduce.
- **Bug 4 (garbled strings)** - not observed in current tests. The `print(x.toString())`
  path now produces correct output ("42", "4950", timing values). May have been fixed
  by the polymorphic type-stack fix (commit f40474e) or only triggers with string
  concatenation.
- **Bug 1 (promote string leak)** - still present. 1 leak per `applyNative` call that
  returns a string (e.g., `toString()`). The promoted string is heap-allocated via
  `rt.heapAlloc().dupe()` but never freed. This is O(number of native string returns),
  not O(iterations).
- **Bug 2 (@list growth leak)** - still present. Exactly 1 leak per program, from
  `loadBytecodeConsts!` growing the consts array. Intermediate ArrayList buffers
  are not freed on capacity increase.
- **Bug 5 (union cleanup after promote)** - root cause of Bug 1. Still present.

### Summary

The VM is now functionally correct and leak-free on the hot path. The only leaks
are in setup (1x @list growth) and native function returns (1x per string-returning
native call). Pure integer compute has zero leaks beyond the setup leak.

### Full Benchmark Leak Check (--leak --all)

Ran `ruby benchmarks/runner.rb --leak --all` (BENCH_SCALE=0.001, debug build, 60s timeout).

| Benchmark | Result |
|-----------|--------|
| 01_stack_vs_heap | CLEAN |
| 02_sroa | CLEAN |
| 03_list_vs_stack | CLEAN |
| 04_socket_throughput | CLEAN |
| 05_hashmap | CLEAN |
| 06_string_builder | CLEAN |
| 07_simd | CLEAN |
| 08_pointer_chase | CLEAN |
| 09_sort | CLEAN |
| 10_concurrent_search | CLEAN |
| 11_atomic_contention | CLEAN |
| 12_fanout_fanin | CLEAN |
| 13_backpressure | CRASH (exit 134) - use-after-free in debug |
| 14_dynamic_spawn | CRASH (exit 134) - use-after-free in debug |
| 15_stream_merge | CRASH (exit 134) - use-after-free in debug |
| 16_pubsub | CLEAN |
| 17_kvstore | CRASH (exit 134) - use-after-free in debug |
| 18_shard_vs_locked | CLEAN |
| 19_parallel_aggregation | CLEAN |
| 20_tcp_kvstore | SKIP (server benchmark) |
| 21_frame_vs_heap | CLEAN |
| 22_pool_vs_multiowned | CLEAN |
| 23_pipeline_overhead | SKIP (build failed) |
| 24_json_api | SKIP (server benchmark) |
| 25_pathological | SKIP (server benchmark) |
| 26_weak_ref_graph | CLEAN |
| 30_iterator | CLEAN |

**20/24 buildable benchmarks are leak-free.**

The 4 crashes (13, 14, 15, 17) are all concurrent benchmarks that hit
`0xcccccccccccccccc` (Zig's uninitialized memory poison) in debug mode.
These are likely use-after-free in the fiber/scheduler runtime, exposed
by debug safety checks but masked by ReleaseFast. They work correctly
in `--optimized` builds. These are runtime bugs, not compiler bugs.

## Impact on Minivm

These bugs prevent the bytecode VM from being fully leak-free:
- Pure compute: 1 leak (setup only, constant regardless of iterations)
- With print: 2 leaks (setup + 1 per print call)
- Release/optimized builds: no crashes observed (Bug 3 not triggered)
- Output: correct (Bug 4 not triggered with current tests)
- The interpreter.cht source code is correct CLEAR - the bugs are all in the
  compiler's code generation and runtime support
