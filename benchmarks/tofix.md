# Benchmark Issues to Fix

## Segfaults

### ~~Benchmark 02: concurrent_search~~ — FIXED (2026-05-02 triage)

The 3 cited bugs were resolved by infrastructure changes since this
section was written:

1. ~~`insert_bg_escape_promote!` misses BG-in-MethodCall~~ — fixed.
   `AST.each_bg_block_in_stmt` (`src/ast/ast.rb:111-125`) now descends
   into `MethodCall` and `FuncCall` args.
2. ~~`string_captures` frees `.rodata` literals~~ — fixed (downstream
   consumer removed). The set itself is dead-but-harmless metadata in
   `capabilities.rb:501`.
3. ~~Frame-arena UAF from loop rewind~~ — fixed via
   `BgBlock.capture_string_dupes` (`mir_pass.rb:544-546` →
   `mir_lowering.rb:3357-3368`); the dupe runs at the spawn site
   BEFORE the loop frame restore.

**Verified:** 18+ runs across default / `--optimized` / `--safe` build
modes at `THREADS=2/8/$(nproc)`, all clean.

### ~~Benchmark 03: atomic_contention~~ — FIXED (2026-05-02 triage)

`spawnPinned`'s round-robin distribution is still in
`runtime-header.zig:3379-3398`, but BG blocks that capture `@local`
resources now lower to `rt.getSched().submitSpawn(...)` (current
scheduler) instead of `CheatHeader.spawnPinned(...)`
(`mir_lowering.rb:3349`). The compiler emits the user-visible note
`"BG block auto-pinned — captures @local resource (same-scheduler
affinity)"` for the auto-pin case.

**Verified:** 25+ runs at `THREADS=2/4/8/16/32`, Counter consistently
`10240000` (no torn writes, no crashes).

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

| Root Cause | Affected | Type | Status |
|-----------|----------|------|--------|
| ~~`insert_bg_escape_promote!` misses nested BG blocks~~ | 02 | segfault | FIXED — walker descends into MethodCall args |
| ~~`string_captures` frees .rodata literals~~ | 02 | segfault | FIXED — consumer removed |
| ~~`spawnPinned` round-robins `@local` fibers~~ | 03, possibly 16 | segfault | FIXED — `pin_mode :local` lowers to `rt.getSched().submitSpawn` |
| Frame arena ArrayList growth waste | 19 | memory | fundamental arena limitation |
| Two-phase SHARD pattern materializes all keys | 19 | memory | benchmark design |
| Shard `put()` vs `putDirect()` key leaks | 19 | memory | compiler codegen |

---

## 2026-05-01 leak/example sweep (paths use `benchmarks/concurrent/0X` layout)

`bundle exec ruby benchmarks/runner.rb --leak` plus a pass over `examples/`
turned up the following compile/runtime regressions. All confirmed to
reproduce on master (verified via `git stash` against the formatter WIP).
None are caused by the LOCKED rename or the MATCH/PARTIAL MATCH split.

### FIXED in 2026-05-01 sweep

- `concurrent/05_backpressure` -- 42d4ef64 (cast `i64` worker count to
  `usize` at the bounded-stream concurrent call sites; default-
  capacity expression keeps the raw form so comptime-int simplification
  isn't broken).
- `concurrent/06_dynamic_spawn` -- 1044f0ba (runner.rb's `@leak` text
  substitution used `sub!` which only replaced the first occurrence;
  the consumer loop's iter count stayed at the original size and
  indexed past the producer's reduced array. `gsub!` fixes it).
- `concurrent/08_pubsub` -- 49a9052c (BgCaptureClassifier now also
  heap-promotes `split_open_stream?` and `open_stream?` cursors when
  captured by a BG that runs asynchronously; the cursor would
  otherwise live on the spawning frame and dangle when the loop
  rewinds).
- `concurrent/14_nested_lock` (compile only) -- 9a77c1e0 (post-join
  verification was rewritten to snapshot per-account Arc handles
  before iterating, so the per-account WITH isn't lexically nested
  under WITH bank; the worker hot path was already lint-clean via
  the multi-resource WITH form). See "Remaining" below for the
  runtime-side issue still present at high concurrency.

### Remaining

#### `concurrent/09_kvstore` -- runtime slab allocator segfault under high concurrency

```
Segmentation fault at address 0x10000
runtime/slab-alloc.zig:167:38 in createFromDepot
                slab.free_head = node.next;
                                     ^
runtime/scheduler.zig:531:58 in drainChannels
                        const stack_mem = self.allocStack(effective_size) catch continue;
```

- Reproduces on the leak-mode build (`@leak: n = 1000000 -> n = 1000`)
  with `CLEAR_THREADS=$(nproc)`, fails in the SET workload's fiber
  spawn path.
- With `CLEAR_THREADS=1` the bench runs to completion (verified=yes),
  pointing at a slab/depot concurrency issue, not a logic bug.
- Under `--safe` (LLVM ReleaseSafe), the segfault is replaced by a
  CLEAR-level `ASSERTION FAILED: GET hits must equal key count` --
  some SETs aren't visible to the GET phase, suggesting a separate
  visibility/race issue on the sharded HashMap on top of the slab
  bug.
- Investigation belongs in the runtime
  (`zig/runtime/slab-alloc.zig` + `zig/runtime/fiber-memory.zig`),
  not in the compiler frontend.

#### `concurrent/14_nested_lock` -- runtime LockCycle false positive at high concurrency

After the lint fix, the bench compiles cleanly and runs cleanly with
1-2 workers (verifies balance 64000 = 64000). With `CLEAR_THREADS=$(nproc)`
the runtime parking-lot deadlock detector fires:

```
LOCK CYCLE: fiber waiting on lock transitively held by itself via 1 hop(s)
panic: Locked.acquire: error.LockCycle
```

The bench's worker hot path uses the multi-resource form
(`WITH EXCLUSIVE loAcct AS la, EXCLUSIVE hiAcct AS ha`) with index-
ordered acquisition, which is the documented deadlock-free pattern.
Likely either the runtime cycle detector is over-reporting under the
multi-resource acquire path, or the multi-resource lowering isn't
pinning the inner-acquire order. Triage in `zig/lib/parking-lot.zig`
(detectCycle) and the multi-resource WITH lowering.

#### `examples/testing/stub_ufcs.clear` -- unused local constant on stub helper

```
._clear_tmp_stub_ufcs.zig:62:7: error: unused local constant
const __stub_query = "mock result";
```

The stub-helper synthesized constant is captured in the stub fn but the
generated helper doesn't reference it. Likely a stub-generation bug in
`src/annotator-helpers/stub_helpers.rb` or wherever stub helpers are emitted.

### Example regressions

#### `examples/graphdb/graph.clear` — concurrent assertion fires

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
