# RawZig / InlineZig Elimination Plan

This doc tracks the lowerings that still embed Zig source as an opaque
template (`MIR::RawZig` / `MIR::InlineZig`) instead of producing
structural MIR that both backends consume. Each one is a checker blind
spot per CLAUDE.md INV-12: the MIR checker cannot see inside raw/inline
Zig, so capture promotion, allocation/cleanup pairing, and ownership
transfer all sit outside its reach.

## Status

VM coverage as of 2026-04-30: **278 / 294 supportable passing (94%)**.
The remaining 7 UNIMPL + 1 FAIL trace to RawZig/InlineZig templates
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

### Cluster A: Sharded operations -- DONE

Tests passing: 108_shard_pipeline, 229_shard_numeric_keys,
64_sharded_collections, 109_shared_sharded_map. 

Replaced the InlineZig template-substitution path for sharded HashMap
put/get with two structural MIR nodes that both backends consume:

```ruby
MIR::ShardedMapPut.new(target, key, value, shard_idx, shard_key,
                        map_kind, stdlib_def, key_zig, val_zig,
                        resolved_allocs, template_kind)
MIR::ShardedMapGet.new(target, key, shard_idx, shard_key,
                        map_kind, stdlib_def, key_zig, val_zig,
                        resolved_allocs, template_kind)
```

Field semantics:
- `target`, `key`, `value`: MIR sub-expressions (not pre-emitted Zig
  strings). The checker can recurse into them for ownership analysis.
- `shard_idx`/`shard_key`: MIR Ident nodes for the shard index/key
  vars in scope when emitted inside a SHARD pipeline body. nil for
  routed dispatch.
- `template_kind`: `:zig | :sharded_zig | :shard_direct_zig` -- the
  template family the lowering chose based on the receiver type and
  shard context. Both backends consume this directly.
- `resolved_allocs`: pre-resolved allocator symbols (`:heap | :frame`)
  for the placeholders the chosen template uses. The lowering runs
  resolve_alloc_sym at lowering time so the emitter only does the
  symbol -> Zig string mapping.
- `stdlib_def`: full INDEX_OPS entry (templates + ownership flags).
  The checker reads this to validate ownership effects (key dupe,
  value transfer, container borrow).

Zig backend (mir_emitter.rb): `emit_sharded_map_put` /
`emit_sharded_map_get` pick the template by `template_kind` and
substitute `{target}`, `{index}`, `{value}`, `{shard_idx}`,
`{shard_key}`, `{key_zig}`, `{val_zig}`, `{key_alloc}`, `{val_alloc}`,
`{shard_alloc}` etc. Same Zig output as the previous InlineZig path.

BC backend (bc_emitter.rb): `compile_sharded_map_put` /
`compile_sharded_map_get` emit `MAP_PUT` / `MAP_GET`. The VM has no
shard routing; sharded maps share a single MapRef cell.

SHARD + CONCURRENT EACH is also structurally lowered. The original
`transpile_shard_concurrent_each` (~70 lines of RawZig in
pipeline_generator) was deleted -- its work moved to
`PipelineHost#lower_shard_concurrent_each` which produces a
ScopeBlock + WhileStmt (Zig) or ForStmt (BC) tree both backends
consume. Inside the loop body, `map[k] = v` routes through
ShardedMapPut/Get with `shard_idx` set, so the checker has full
visibility into the shard-direct ownership story (key dupe is
elided, value transfer is direct, container borrow is implicit).

Cluster A is genuinely complete: no RawZig remains for sharded ops,
both backends consume the same MIR for the entire pipeline (outer
loop + shard lookup + per-iteration put/get).

### Cluster B: File / TCP resources -- DONE for File RAII

Tests passing: 60_file_resource, 62_file_write, 63_resource_return.

Approach: instead of inventing a new `MIR::ResourceOpen` node, the
existing `MIR::InlineBc` carrier was extended. `File::open` /
`File::create` schemas now opt in via `bc: true, bc_op: :file_open`
(or `:file_create`); `fileReadAll` / `fileWrite` likewise. The
lower_static_call path produces `MIR::InlineBc(op, args, stdlib_def)`
when `stdlib_def[:bc]` is set so both backends consume the same
node:

- Zig emits via `emit_inline_bc_as_zig` from `stdlib_def[:zig]`
  ("try CheatLib.fileOpen({0})", etc.) -- byte-identical output to
  the previous InlineZig path.
- BC dispatches by op symbol in `compile_inline_bc`. The VM models
  files as path-as-handle (Value.Str(path) since fd lifecycle is
  irrelevant in single-fiber sequential execution); fileReadAll
  reroutes through the existing readFile native.

The auto-close (kind=:resource MIR::Cleanup) emitted by the
annotator's resource-tracking still pairs with the resource Let.
For Zig, the Cleanup emits `defer name.close()`. For BC, the
Cleanup is a no-op on Value.Str (no fd to close, GC reclaims).

What this gains the checker: resource constructors now go through
a registered stdlib_def with allocates / can_fail / borrows flags
visible at the MIR node. INV-2 (every alloc has a cleanup path)
fires when `lower_static_call`'s Let path doesn't pair the
ResourceOpen with a `MIR::Cleanup` -- the resource Let always
emits one in the existing path, so the invariant is enforced.

`lower_method_call` now picks `stdlib_def[:bc_op]` over the AST
method name when present, decoupling the BC dispatch key from
CLEAR's surface naming (e.g. `fileReadAll` -> `:file_read_all`).

TCP resources (TCPServer, TCPClient) follow the same pattern but
have no failing test today since their connect/listen requires
real socket setup the VM doesn't model. Schema entries can adopt
`bc:` flags + new VM natives later when needed.

### Cluster C: Stream-source CONCURRENT -- DONE for Zig backend

Tests passing on Zig: 240_concurrent_stream_pipelines,
241_open_stream_pipelines, 242_concurrent_capacity, 243_batch_window.

**What it does:** `~T[]` (dynamic stream) and `~T[INF]` (inf stream)
sources passed through `s> CONCURRENT SELECT/WHERE/EACH`.

**What changed:**

1. Added three runtime helpers in `zig/lib/streams.zig`:
   `concurrentStreamSelect`, `concurrentStreamWhere`,
   `concurrentStreamEach`. Each is a feeder fiber + N worker fibers
   wired through a `BoundedChannel(T)`. Comptime `is_inf` chooses
   `nextOrNull()` (inf stream) vs `next()` (bounded/open). `ChannelT`
   is a comptime parameter so streams.zig keeps no hard dependency
   on data-structures.zig.

2. Added thin CheatLib wrappers in `zig/runtime/runtime-header.zig`
   that pin WaitGroup, spawn fns, channel type, and per-T cleanup.

3. Replaced the inline RawZig blob in
   `pipeline_generator#transpile_concurrent_stream_*` with structural
   MIR in `pipeline_host#lower_concurrent_stream_select/where/each`.
   Each lowering reuses `build_bounded_concurrent_callback` to emit
   the worker as `MIR::FnDef` inside `MIR::StructDef`, then calls
   `emit_builtin :concurrentStreamSelect` (etc.). Three new helpers:
   `stream_concurrent_element_type`, `stream_concurrent_source_setup_mir`,
   `stream_concurrent_capacity_mir`.

4. `lower_concurrent` dispatch routes Zig-backend stream
   SELECT/WHERE/EACH through the structural path. BC continues
   falling through to the legacy RawZig fallback (still UNIMPL on
   BC -- see remaining work below).

**What this gains the checker:** the worker callback is now visible
as a normal MIR `FnDef` body; capture promotion, allocator pairing,
and ownership transfer are all visible to the standard MIR invariants.
The opaque RawZig blob for the Zig path is gone.

**Remaining BC work:** tests 240/241/242/243 stay UNIMPL on BC. The
VM has no fiber scheduler / channel runtime, so the structural call
to `concurrentStreamSelect` has no `bc: true` dispatch. A future
commit can either model `BC_FIBER_SPAWN` + a queue-style channel,
or sequentially simulate (feeder produces full list, workers
sequentially walk it).

### Cluster D: List-source CONCURRENT -- DONE for SELECT/WHERE (Zig)

Tests passing on Zig: 210_concurrent_pipeline, 211_concurrent_binding,
230_sharded_values_inline_no_leak, plus existing SELECT/WHERE list
tests. EACH on lists stays on the legacy path (see below).

**What changed:**

1. Added three runtime helpers in `zig/lib/streams.zig`:
   `concurrentListSelect`, `concurrentListWhere`, `concurrentListEach`.
   Each takes `items: []const T` directly (no feeder, no channel)
   and lets workers race on an atomic index. Mirrors the bounded
   helpers but without the `.next()` Promise indirection.

2. Added `CheatLib.concurrentListSelect/Where/Each` thin wrappers in
   `zig/runtime/runtime-header.zig` pinning WaitGroup, spawn fns,
   and per-T cleanup.

3. Replaced the inline RawZig blobs in
   `pipeline_generator#transpile_concurrent_select/where` with
   structural MIR in
   `pipeline_host#lower_concurrent_list_select/where`. The worker
   callback reuses `build_bounded_concurrent_callback` -- the shape
   is identical to bounded streams except the source type. The
   shape-adapting `pipe_items` materialization (sharded pool / SoA /
   pool / sharded list) still goes through `build_pipe_items_block`
   as an `MIR::InlineZig` prelude; only the worker-pool boilerplate
   was migrated structurally.

4. Dispatch in `lower_concurrent` routes Zig-backend list SELECT
   and WHERE (when not `BIND_VAR`) to the new lowering. EACH stays
   on the legacy path.

**EACH still on legacy:** Tests like 81_concurrent_each have bodies
that directly mutate items (`_.value = X`). The legacy template
emits `items: []T` (mutable slice) plus `@constCast(items)` and
substitutes `_` for `ctx.items[idx]` so the mutation lands on the
shared slice. The bounded-callback shape passes items by value
(`__item: T`), so direct mutation of `__item` doesn't compile. A
future commit can add a separate `concurrentListEachInPlace` helper
that takes `items: []T` and passes `*T` to the body, then the
dispatch picks it for mutating bodies.

**Remaining BIND_VAR path:** `list AS @u s> CONCURRENT SELECT @u.field`
still uses the legacy template. `@concurrent_outer_binding` rewrites
the binding name into Zig field-access fragments inside the worker;
porting that to structural MIR needs a small additional capture-rewrite
pass. Defer until needed.

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

### Cluster G: Bounded stream concurrent -- DONE

Test passing on both backends: 228_concurrent_bounded_stream.

**What it does:** `~T[N] s> CONCURRENT SELECT/WHERE/EACH`.

**What changed:** `bc_emitter.rb` now handles the structural shape
the lowering already produced:

- `collect_nested_fn_defs` walks `MIR::StructDef.methods` for
  `__BoundedConcurrentCtx<N>` and registers each `apply` method
  under the qualified name `<StructName>.apply`. Field names are
  registered in `@struct_fields` so `compile_field_get` resolves
  `ctx.<field>` indices via `find_field_index`.
- `compile_synthesized_helper_fn_mir` compiles the AST-less worker
  bodies; it filters `MIR::Suppress` / `MIR::FrameSave` etc. the
  same way `compile_main` does.
- `compile_concurrent_bounded` is the InlineBc dispatch site: it
  unwraps `AddressOf` / `FieldGet(_, "items")` to find the source,
  pre-stashes `ctx`, allocates the result list (SELECT/WHERE),
  then iterates items via FOR + BC_CALL of the worker.
- The `with_block_bindings` handler grew a captured-field prefetch
  pass: when the WITH source is rooted at `ctx.FIELD.*` (which
  happens when a `WITH EXCLUSIVE total AS t` lives inside the
  worker body and `total` was rewritten to `ctx.total.*`), load
  `ctx.FIELD` into a slot named after the borrows entry so
  `alias_to_source` resolves. The field holds the same Box as the
  original (AddressOf is identity in BC), so writes through the
  alias propagate.
- `compile_expr` `MIR::AddressOf` skips `BOX_LOAD` when the operand
  is a boxed slot ident; capturing into a struct field needs the
  underlying cell-id, not the dereferenced value.

The Zig path was already structural; this commit added the BC half.

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

DONE:
1. **#2 unification (pool[id] InlineBc)**
2. **Cluster A (Sharded ops)**
3. **Cluster B (File RAII)**
4. **Cluster G (bounded stream concurrent)**
5. **Cluster C (stream-source CONCURRENT)** -- Zig backend done; BC
   still UNIMPL pending fiber/channel runtime work.
6. **Cluster D (list-source CONCURRENT)** -- SELECT and WHERE done
   on Zig; EACH and BIND_VAR cases still on legacy.

Remaining:
7. **Cluster D EACH (in-place mutation)** -- add a
   `concurrentListEachInPlace` helper that passes `*T` to the body,
   plus dispatch logic that picks it when the body mutates `_`
   directly. Without this, tests like 81 stay on the legacy template.
8. **Cluster D BIND_VAR** -- `list AS @u s>` in CONCURRENT needs the
   `@u` capture rewrite to flow into the structural worker callback.
9. **Cluster C BC half** -- model fiber/channel runtime in BC, or
   sequentially simulate (feeder builds the full list first, workers
   walk it sequentially). Either path unblocks tests 240/241/242/243
   on BC.
10. **Clusters E, F** (thread pinning, promise list/range) --
    mechanical; do as cleanup.
