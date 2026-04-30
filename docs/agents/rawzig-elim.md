# RawZig / InlineZig Elimination Plan

This doc tracks the lowerings that still embed Zig source as an opaque
template (`MIR::RawZig` / `MIR::InlineZig`) instead of producing
structural MIR that both backends consume. Each one is a checker blind
spot per CLAUDE.md INV-12: the MIR checker cannot see inside raw/inline
Zig, so capture promotion, allocation/cleanup pairing, and ownership
transfer all sit outside its reach.

## Status

VM coverage as of 2026-04-30: **270 / 294 supportable passing (91%)**.
The remaining 14 UNIMPL + 2 FAIL trace to RawZig/InlineZig templates
or runtime features the VM doesn't implement.

## What we already did (BC short-circuits, not unifications)

Four `@target == :bc` short-circuits exist across the lowering. Three
add structural MIR but only on the BC side; the Zig backend keeps its
existing path. One adds no new MIR -- it redirects BC through existing
structural lowerings.

| # | Location | Shape | Unifiable? |
|---|---|---|---|
| 1 | `lower_binding_chain` -> suffix `__bc_acc` per pipeline label | VM-only slot-flatness fix | No -- VM model issue, not MIR shape |
| 2 | `lower_pipeline` pool branch -> `MIR::InlineBc(:get, ..., {tag: :pool_method})` for BC, `MIR::MethodCall(target, "get", ...)` for Zig | Two structural paths | **Yes -- small win, see below** |
| 3 | `lower_bg_stream_block` `@split` -> `MIR::InlineBc(:split_stream_new, ...)` for BC; Zig uses `MIR::RcRetain(splitRetain)` | Two structural paths | Possible but churny; both work |
| 4 | `lower_concurrent` -> BC redispatches to `lower_select` / `lower_where` / etc.; Zig keeps `MIR::RawZig` template | BC is structural via existing ops, Zig stays opaque | **No -- needs new structural MIR (FiberSpawn etc.); multi-commit** |

\#2 is the easy unification: have both backends consume the same
InlineBc, and add a Zig-side handler that emits `target.get(index)`.

\#4 is the real correctness work: the Zig template's parallelism is
implemented inside the RawZig blob. To make the checker see it, we'd
need `MIR::FiberSpawn { captures, body, allocator }`,
`MIR::ChannelSend` / `Recv`, and propagate cleanup contracts across
the fiber boundary.

## Remaining RawZig / InlineZig clusters

### Cluster A: Sharded operations (3 UNIMPL + 1 FAIL)

Tests: 108_shard_pipeline, 229_shard_numeric_keys, 64_sharded_collections,
109_shared_sharded_map (FAIL).

**What it does:** `@sharded` HashMap routing. A sharded map has N
underlying shards, each with its own mutex. Cross-shard puts route
through `put` (which computes shardIdx and dispatches), shard-direct
puts use `putDirect` (caller already knows the shard). Strings are
duped to the shard's allocator; values are TAKES'd.

**What it looks like now:** `MIR::RawZig` with `@shard_context`
discriminating direct vs routed. The lowering already differentiates
`shard_direct_zig` vs `zig` patterns in `INDEX_OPS[:string_map][:set]`,
but the templates themselves are opaque strings.

**Why this matters for correctness:** the most subtle ownership
story in the codebase. Cross-shard puts dupe keys to the shard
allocator; if the shard's lock-fail path drops the key, the dupe
must be freed. Direct puts skip the dupe (caller owns). A regression
in either template silently leaks or double-frees. The checker
currently can't fire.

**Structural MIR target:**
```ruby
MIR::ShardPut.new(target, shard_idx_or_nil, key, value,
                   key_alloc: :shard_or_caller,
                   val_alloc: :receiver_storage,
                   key_dupe: bool, value_dupe: bool)
MIR::ShardGet.new(target, shard_idx_or_nil, key)
MIR::ShardRoute.new(map, key)  # shardIdx computation
```

The checker validates: when `key_dupe == true`, an `AllocMark` for
the duped key must pair with a `Cleanup` (or `ErrCleanup` on the
lock-fail path). When `shard_idx` is non-nil, no routing -- skip the
dupe.

**Effort:** Medium. Three new MIR nodes, BC + Zig emitter handlers,
one structural lowering pass replacing the existing RawZig templates.

### Cluster B: File / TCP resources (3 UNIMPL)

Tests: 60_file_resource, 62_file_write, 63_resource_return.

**What it does:** `File.open(path)` returns a resource that
auto-closes on scope exit (RAII). Writes / reads happen through
the resource handle.

**What it looks like now:** `MIR::InlineZig` wraps `std.fs.cwd().openFile`
and friends; close-on-defer is part of the RawZig template.

**Why this matters for correctness:** RAII close on error path. If
`fileRead` errors, the file must still close. Currently the close
is hardcoded in the template; if the template forgets `errdefer`, a
file descriptor leaks.

**Structural MIR target:**
```ruby
MIR::ResourceOpen.new(kind: :file, args: [...], cleanup_method: "close")
# Pairs with automatic MIR::Cleanup at scope exit
```

The checker validates: every `ResourceOpen` has a matching
`MIR::Cleanup` on every path (success and error).

VM side needs file natives (`fopen`, `fread`, `fwrite`, `fclose`)
and `MIR::ResourceOpen` -> `RESOURCE_NEW` opcode.

**Effort:** Medium. Plus VM file natives.

### Cluster C: Stream-source CONCURRENT (4 UNIMPL)

Tests: 240_concurrent_stream_pipelines, 241_open_stream_pipelines,
242_concurrent_capacity, 243_batch_window.

**What it does:** `~T[]` (dynamic stream) and `~T[INF]` (inf stream)
sources passed through `s> CONCURRENT SELECT/WHERE/EACH`.

**What it looks like now:** Same `MIR::RawZig` template as
list-source CONCURRENT. The BC short-circuit (#4 above) explicitly
gates these out because `lower_select` / `lower_where` /
`lower_each` don't handle stream sources -- they expect array-like
inputs.

**Why this matters for correctness:** Same as Cluster D below. The
template is the SAME RawZig as list-source CONCURRENT, just consumed
on a stream lhs.

**Structural MIR target:** Same as Cluster D (concurrent pipeline).
Streams need `lower_select` / `lower_where` / `lower_each` to grow
a stream-materialization branch (NEXT loop -> append to result).

**Effort:** Small *if* Cluster D is done structurally; otherwise a
~1-day fix to teach lower_X to materialize streams.

### Cluster D: Concurrent pipeline (Zig-side) -- the big one

Tests: list-source ones already pass via BC short-circuit; Zig still
emits RawZig. No standalone test gating.

**What it does:** `s> CONCURRENT(workers: K) SELECT f(_)` spawns K
worker fibers, partitions the input, channels intermediate results
back, joins. Captures from outer scope flow through a context struct.

**What it looks like now:** `MIR::RawZig` blob in
`pipeline_generator.rb` (~5000 lines across `transpile_concurrent_*`
methods). Each variant builds: a context struct definition with
capture fields, a worker fn body that reads from an input channel,
the spawn loop, the result-collection loop.

**Why this matters for correctness:** the largest checker blind
spot in the codebase. Three latent bug classes:

1. **Capture UAF:** an outer `frame`-allocated value captured into
   a worker fiber that outlives the frame. The lowering is supposed
   to promote frame -> heap before BG, but the template carries the
   logic; checker doesn't validate.

2. **Allocation leaks:** the worker body allocates intermediate
   values. If the channel's drain path on early-exit folds (FIND /
   ANY / FIRST) doesn't free unconsumed entries, leak.

3. **Channel cleanup:** error paths must drain and free pending
   items. A regression in the template silently leaks per item.

**Structural MIR target:**
```ruby
MIR::FiberSpawn.new(
  captures:    [{name:, type:, alloc: :heap}],   # promotion list
  body_fn:     MIR::FnDef,                       # worker callback
  alloc:       :heap,
)
MIR::Channel.new(elem_type:, capacity:, alloc:)
MIR::ChannelSend.new(channel, value, takes: bool)
MIR::ChannelRecv.new(channel)                    # returns ?T
MIR::ChannelDrain.new(channel)                   # cleanup unconsumed
```

The checker validates per-call site:
- Every captured frame value has a `Promote` to heap before the
  spawn (INV-5).
- Every `Channel` has a paired `ChannelDrain` on every exit path
  (INV-2).
- Every `ChannelSend(takes: true)` has a corresponding `MoveMark`
  on the source (INV-4).

**Effort:** Large. ~1-2 weeks. Multiple commits. Replaces ~5000
lines of `transpile_concurrent_*` in pipeline_generator.rb. Both
backends consume the structural MIR; Zig emitter generates the
fiber-spawn boilerplate; BC emitter falls back to sequential
simulation.

This is the highest-correctness-payoff RawZig in the codebase,
because the bug surface is largest and the templates are most
brittle.

### Cluster E: Thread pinning (1 UNIMPL)

Test: 67_thread_pinning.

**What it does:** `pin` operator that hints worker affinity to a
specific thread.

**What it looks like now:** `MIR::RawZig` calling `rt.getSched().pin`.

**Why this matters for correctness:** Low. No ownership semantics,
purely a performance hint.

**Structural MIR target:**
```ruby
MIR::ThreadPin.new(target_fiber, cpu_idx)
```

Mechanical translation; no checker semantics.

**Effort:** Tiny.

### Cluster F: Promise list / range streams (2 UNIMPL)

Tests: 219_next_promise_list, 224_range_streams.

**What it does:** `NEXT promise.list` iterates a list of promises;
range streams produce numeric ranges as a stream type.

**What it looks like now:** `MIR::InlineZig` for each variant.

**Why this matters for correctness:** Low. Stream construction; no
ownership transfer beyond the standard list/iterator allocation.

**Structural MIR target:**
```ruby
MIR::PromiseListIter.new(list)
MIR::RangeStream.new(start, end, step, inclusive:)
```

**Effort:** Small. Mostly mechanical.

### Cluster G: Bounded stream concurrent (1 UNIMPL)

Test: 228_concurrent_bounded_stream.

**What it does:** `~T[N] s> CONCURRENT SELECT/WHERE/EACH`.

**What it looks like now:** Already structural! Uses
`build_bounded_concurrent_callback` which emits `MIR::FnDef`,
`MIR::StructDef`, and `MIR::Param` nodes. The blocker is purely
that `bc_emitter` doesn't handle `MIR::StructDef` yet.

**Effort:** Small. Add `MIR::StructDef` dispatch in bc_emitter.

### Cluster H: VM-only architectural (2 FAIL)

These require runtime infrastructure the VM doesn't have:

- **109_shared_sharded_map:** sharded HashMap runtime in VM. The
  VM uses one MapRef value type with no shard concept. Would
  need a `Value.ShardedMap { shards: [Id<Env>; N] }` variant
  and routing logic. Independent of the Cluster A correctness
  story (which is about the *compiler* lowering for sharded ops,
  not the runtime structure).

- **263_with_lock_contention:** real cooperative fiber scheduler
  with sleep queue and lock primitives. Days of work. See earlier
  discussion -- ROI is low for a single test, but the same
  scheduler unblocks the concurrent-pipeline cluster (D) at the
  runtime level.

## Priority order (correctness payoff vs effort)

1. **#2 unification (pool[id] InlineBc)** -- trivial, removes one
   asymmetry, makes pool indexing a registered stdlib op visible to
   the checker on both backends.
2. **Cluster A (Sharded ops)** -- highest concentrated correctness
   payoff. Cross-shard ownership transfer is the most subtle
   ownership story in the codebase.
3. **Cluster B (File RAII)** -- well-defined lifecycle; gives the
   checker visibility into close-on-error paths.
4. **Cluster G (bounded stream concurrent)** -- small effort,
   unblocks one test, exercises bc_emitter's MIR::StructDef path.
5. **Cluster D (Concurrent pipeline Zig-side)** -- largest payoff
   but largest effort. Worth doing once the smaller fish are off
   the plate.
6. **Cluster C (stream-source CONCURRENT)** -- subsumed by D
   structurally; alternatively a 1-day fix to teach `lower_select`
   etc. about streams.
7. **Clusters E, F** (thread pinning, promise list/range) --
   mechanical; do as cleanup.
