# Benchmark Issues to Fix

## Segfaults

### Benchmark 10: concurrent_search (crashes every run)

Three compiler bugs, all in the compiler:

1. **`insert_bg_escape_promote!` misses BG blocks inside MethodCalls** (`src/control_flow.rb:987-1005`)
   - Only recognizes BG at bare statement or direct assignment positions
   - Misses BG nested in `futures.append(BG { ... })` - never inserts `MIR::Promote(:bg_string)`
   - Result: `filepath` (frame-allocated string interpolation) is stored into BG context without dupe
   - Frame arena rewinds at loop end, fiber holds dangling pointer

2. **`string_captures` frees comptime string literals** (`src/capabilities.rb:338`)
   - `result.string_captures << name if t&.string?` marks ALL string captures for `defer alloc.free()`
   - Includes `needle = "the"` which lives in `.rodata` - never allocated by any allocator
   - Direct crash: `alloc.free()` on a `.rodata` address triggers "Invalid free" in GPA

3. **Frame-arena use-after-free from loop rewind** (`src/alloc.rb`)
   - Loop body allocates `filepath` via `rt.frameAlloc()` (string interpolation)
   - `restoreLoopMark` rewinds at iteration end, but BG context already holds the raw slice
   - Even if Bug 1 were fixed, the dupe must happen BEFORE the loop mark restore

Generated Zig showing all three bugs:
```zig
// filepath on frame arena (Bug 3: rewound at loop end)
const filepath = try std.mem.concat(rt.frameAlloc(), u8, &.{ data_dir, "/", file, "" });
// stored into BG context WITHOUT dupe (Bug 1: no bg_string promote)
__bg0_ctx.* = .{ .filepath = filepath, .needle = needle };
// freed even though it's .rodata (Bug 2: string literal freed)
defer __ctx_0.alloc.free(__ctx_0.needle);
```

### Benchmark 11: atomic_contention (intermittent, ~60% crash rate at THREADS=2)

**`spawnPinned` distributes `@local` fibers across multiple OS threads** (`zig/runtime-header.zig:4078-4093`)

- Benchmark uses `@local` on a Counter struct (bare pointer, no Mutex)
- Compiler correctly auto-pins the BG blocks
- But `spawnPinned` round-robins fibers across ALL schedulers:
  ```zig
  const idx = fp.global_registry.next.fetchAdd(1, .monotonic) % n;
  ```
- With THREADS=2: half the fibers go to scheduler 0, half to scheduler 1
- Both sets do non-atomic read-modify-write on the same `*Counter` - undefined behavior
- "Pinned" only prevents work-stealing, does NOT constrain to same scheduler

Evidence:
- THREADS=1: 20/20 correct, zero crashes
- THREADS=2: ~26/30 crashes (segfault, GPE, use-after-free sentinel 0xaa)
- Safe build: GPA detects double-free from corrupted pointers

Fix: `spawnPinned` for `@local` must submit to the CALLER's scheduler, not round-robin:
```zig
try fp.active_scheduler.submitSpawn(...);  // not global round-robin
```

### Benchmark 16: pubsub (intermittent, ~20% crash rate)

Investigation interrupted before completion. Likely related to the same `spawnPinned` / `@local` issue as benchmark 11, or the BG string capture bug from benchmark 10. Needs further investigation.

---

## Memory Bloat

### Benchmark 16: pubsub (545 MB vs 2 MB Rust/Go)

Investigation interrupted. Needs profiling. Likely fiber stack overhead (64KB x many fibers) plus frame arena string accumulation.

### Benchmark 19: parallel_aggregation (1,018 MB vs 3 MB Rust/7 MB Go)

Three sources totaling ~1,094 MB (1.1x overhead from malloc metadata = 1,220 MB measured):

| Source | Amount | Cause |
|--------|--------|-------|
| Frame arena: abandoned ArrayList backings | 256 MB | `keys.append()` doubles ~24 times; old arrays never freed (frame `smartFree` is no-op) |
| Frame arena: final ArrayList backing | 256 MB | 16M capacity x 16 bytes per slice |
| Frame arena: dead `intToString` temps | 35 MB | 10M temp strings, no loop rewind |
| Frame arena: concat results (the keys) | 54 MB | 10M strings alive in `keys` list |
| Routing arena: duped keys | 54 MB | `alloc.dupe(u8, key)` for all 10M keys |
| Routing queues: slice headers + hashes | 384 MB | 32 queues x 524K capacity x 24 bytes |
| Shard `put()` key dupes (leaked) | 54 MB | `remote_alloc.dupe` in put(); old keys leaked on replace |

Root causes:
1. **No loop rewind** in FOR loop building 10M keys - `intToString` temps and abandoned ArrayList backings accumulate
2. **Benchmark design**: two-phase pattern (build all keys, then SHARD) materializes 10M keys simultaneously. Rust/Go generate-and-insert one at a time (streaming). A streaming SHARD would eliminate ~1,040 MB.
3. **Shard `put()` instead of `putDirect()`**: re-hashes, re-dupes, and leaks 9.99M replaced keys (only 10K unique buckets)

### Benchmark 13: backpressure (34 MB vs 2-3 MB Rust/Go)

Not investigated yet. Likely fiber stack overhead (32 workers x 64KB = 2MB minimum) plus channel/queue buffers. Lower priority since CLEAR is 58-60% faster here.

---

## Summary by Root Cause

| Root Cause | Affected | Type | Fix Location |
|-----------|----------|------|-------------|
| `insert_bg_escape_promote!` misses nested BG blocks | 10 | segfault | `src/control_flow.rb` |
| `string_captures` frees .rodata literals | 10 | segfault | `src/capabilities.rb` |
| `spawnPinned` round-robins `@local` fibers | 11, possibly 16 | segfault | `zig/runtime-header.zig` |
| Frame arena ArrayList growth waste | 19 | memory | fundamental arena limitation |
| Two-phase SHARD pattern materializes all keys | 19 | memory | benchmark design |
| Shard `put()` vs `putDirect()` key leaks | 19 | memory | compiler codegen |

---

## 2026-05-01 leak/example sweep (paths use `benchmarks/concurrent/0X` layout)

`bundle exec ruby benchmarks/runner.rb --leak` plus a pass over `examples/`
turned up the following compile/runtime regressions. All confirmed to
reproduce on master (verified via `git stash` against the formatter WIP).
None are caused by the LOCKED rename or the MATCH/PARTIAL MATCH split.

### Compile/transpile failures

#### `concurrent/05_backpressure` — `concurrentStreamEach` worker count: i64 vs usize

```
._clear_tmp_bench.zig:122:124: error: expected type 'usize', found 'i64'
try CheatLib.concurrentStreamEach(i64, ..., CheatLib.threadCount(), @intCast(64), false, ..., &__bounded_conc_ctx_1);
```

`CheatLib.threadCount()` returns `i64` from CLEAR's number type but the
`workers: usize` parameter on `concurrentStreamEach` (runtime-header.zig:243)
needs an unsigned cast. The other numeric arg in the same call already gets
`@intCast(...)`, so this is a missing intCast on `threadCount()` in the
stdlib lowering.

#### `concurrent/08_pubsub` — FRAME_NO_REWIND in clearMain

```
[FRAME_NO_REWIND] clearMain::clearMain -- loop body frame-allocates but has no restoreLoopMark defer
```

MIR validation rejects the lowered body. Either the loop body's per-iteration
mark/rewind insertion is missed, or the loop is being incorrectly classified
as not needing rewind. Fix candidate: `src/mir/mir_lowering.rb` loop-body
rewind insertion path.

#### `concurrent/14_nested_lock` — false-positive "naked nested WITH" deadlock lint

```
[Compiler Error] Naked nested WITH on a different binding (acct) while bank is held -- symmetric callers may deadlock.
Use the multi-resource form for safe ordering:
    WITH EXCLUSIVE bank, acct AS (i_bank, i_acct) { ... } (Line 68)
```

Either the bench is intentionally exercising the lint (in which case it
needs an `@allow_naked_nested_with` annotation or similar opt-in), or the
detector is too aggressive for this access pattern. `concurrency_checks.rb:87`
in `check_naked_nested_with!`.

#### `examples/testing/stub_ufcs.cht` — unused local constant on stub helper

```
._clear_tmp_stub_ufcs.zig:62:7: error: unused local constant
const __stub_query = "mock result";
```

The stub-helper synthesized constant is captured in the stub fn but the
generated helper doesn't reference it. Likely a stub-generation bug in
`src/annotator-helpers/stub_helpers.rb` or wherever stub helpers are emitted.

### Runtime crashes (build clean, abort during execution)

#### `concurrent/06_dynamic_spawn` — exit 134

Builds cleanly under `./clear build --debug-allocator` but aborts at
runtime. No leaks reported before abort. Likely a `@local` / pin / spawn
bug in the same family as benchmark 11 (`atomic_contention`).

#### `concurrent/09_kvstore` — exit 134

Same shape as 06: clean build, runtime abort, no leaks. Worth checking
whether shared-pool capture or cross-scheduler `@local` access is the
trigger.

### Example regressions

#### `examples/graphdb/graph.cht` — concurrent assertion fires

```
graphdb: sequential tests PASSED
ASSERTION FAILED: concurrent: x is Xena
```

Reproducible across runs (different `--seed` values). Sequential tests
pass, so something in the BG/sharded-locked codegen is dropping or
re-ordering the write to the named node. First place to look:
`b8368c12 feat: graphdb concurrent access with sharded+writeLocked HashMap`.

### Slow but not bugs

- `concurrent/01_socket_throughput` — 60s timeout in debug-leak mode.
  Expected: socket benches saturate the kernel slowly without optimizer.
  Not a bug; bumps the leak-mode budget would silence it.
