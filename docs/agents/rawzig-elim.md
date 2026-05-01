# RawZig / InlineZig Elimination Plan

This doc tracks the lowerings that still embed Zig source as an opaque
template (`MIR::RawZig` / `MIR::InlineZig`) instead of producing
structural MIR that both backends consume. Each one is a checker blind
spot per CLAUDE.md INV-12: the MIR checker cannot see inside raw/inline
Zig, so capture promotion, allocation/cleanup pairing, and ownership
transfer all sit outside its reach.

## Status

VM coverage as of 2026-05-01: **282 / 294 supportable passing (95%)**.
The remaining 3 UNIMPL + 1 FAIL trace to RawZig/InlineZig templates
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

### Cluster C: Stream-source CONCURRENT -- DONE for both backends

Tests passing on Zig and BC: 240_concurrent_stream_pipelines,
241_open_stream_pipelines, 242_concurrent_capacity. (243_batch_window
still UNIMPL on BC via a separate batch_window RawZig.)

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

4. `lower_concurrent` dispatch routes stream SELECT/WHERE/EACH through
   the structural path on both backends.

5. BC: `bc: true` flags on concurrentStream\* + `compile_concurrent_stream`
   in bc_emitter sequentially simulates. Pulls items via
   LIST_POP_FRONT (or SPLIT_STREAM_NEXT for split-stream slots) and
   BC_CALLs the worker per item. workers/parallel/capacity/task_cfg/is_inf
   are all Zig-only knobs that BC ignores. The
   eager-materialization path for BG STREAM was also extended to cover
   ~T[INF] generators (line 2707 of mir_lowering.rb): truly infinite
   generators are still unsupportable, but most workloads use finite
   self-closing generators (`WHILE i <= 8 DO YIELD i; ...`).

**What this gains the checker:** the worker callback is now visible
as a normal MIR `FnDef` body; capture promotion, allocator pairing,
and ownership transfer are all visible to the standard MIR invariants.
The opaque RawZig blob for the Zig path is gone, and BC consumes the
same structural MIR.

### Cluster D: List-source CONCURRENT -- DONE on Zig

Tests passing on Zig: 81_concurrent_each, 210_concurrent_pipeline,
211_concurrent_binding, 230_sharded_values_inline_no_leak.

**What changed:**

1. Added four runtime helpers in `zig/lib/streams.zig`:
   `concurrentListSelect`, `concurrentListWhere`, `concurrentListEach`,
   `concurrentListEachInPlace`. The first three take `items: []const T`
   and pass `T` to the body. `concurrentListEachInPlace` takes
   `items: []T` (mutable) and passes `*T` so the body can update each
   element through the pointer. All four use a persistent worker pool
   racing on an atomic index against the slice length -- no feeder,
   no channel.

2. Added `CheatLib.concurrentListSelect/Where/Each/EachInPlace` thin
   wrappers in `zig/runtime/runtime-header.zig` pinning WaitGroup,
   spawn fns, and per-T cleanup.

3. Replaced the inline RawZig blobs in
   `pipeline_generator#transpile_concurrent_select/where/each` with
   structural MIR in `pipeline_host#lower_concurrent_list_select/where/each`
   (plus `lower_concurrent_list_each_in_place`). The worker callback
   reuses `build_bounded_concurrent_callback` (or
   `build_bounded_concurrent_callback_pointer` for the in-place
   variant) -- the shape is identical to bounded streams except the
   source type. The shape-adapting `pipe_items` materialization
   (sharded pool / SoA / pool / sharded list) still goes through
   `build_pipe_items_block` as an `MIR::InlineZig` prelude; only
   the worker-pool boilerplate was migrated structurally.

4. EACH dispatch picks the in-place helper when the body directly
   mutates `_` (e.g. `_.field = X` or `_[i] = X`). The detection walks
   the AST recursively for `AST::Assignment` whose target is rooted
   at `Identifier("_")`. Non-mutating bodies use the by-value helper.

5. `list AS @u s> CONCURRENT SELECT @u.field` is also structural: the
   dispatch unwraps the BIND_VAR(source, @u) shape and registers `@u`
   as a named pipeline binding resolving to `__item` for the duration
   of the callback body lowering. The existing `with_named_binding`
   machinery handles the substitution.

6. `transpile-tests/gen.rb` was updated to detect `concurrentList` /
   `concurrentStream` / `concurrentBounded` in the transpiled body
   (in addition to the existing WaitGroup string detection) so
   all-tests.zig boots the scheduler when needed. Without this,
   the structural calls would crash in submitSpawn at test runtime.

**What this gains the checker:** the worker callback is now visible
as a normal MIR `FnDef` body for SELECT/WHERE/EACH (both by-value and
in-place). Capture promotion, allocator pairing, and ownership
transfer for the worker body are all visible to the standard MIR
invariants. Only `pipe_items` materialization (which is shape adaptation,
not a worker-pool concern) still rides on InlineZig, and that's
gated by the existing checker rules for inline blocks.

### Cluster E: Thread pinning -- DONE on BC

Test passing: 67_thread_pinning.

**What it does:** Multiple things bundled in this test, despite the
"thread pinning" label:
- `DO { @pinned -> noop() }` — the `@pinned` DO branch hint.
- `pool s> SUM/COUNT/ANY/ALL/MIN/MAX/...` — pool pipeline operators.
- `slist: Float64[]@list:sharded(N) s> SUM/COUNT/EACH/...` — sharded
  list pipeline operators.

**What changed:** The actual blocker on BC wasn't `@pinned` itself
(DO branch dispatch already handled it via `lower_concurrent_bc`);
it was the sharded-list pipeline path. The legacy template emits
per-shard fibers (one fiber iterating each `pipe_src_list.shards[i].items`).
In BC the sharded structure is flattened to a Value.List at runtime,
so per-shard iteration is meaningless and the structural lowering
referenced `pipe_src_list.shards[i].items` against a slot whose
value is just a flat list.

`build_pipe_items_mir` now skips `build_mat_sharded_list` in BC mode
(falls through to the plain ItemsAccess path); `lower_each` no
longer bails with `nil` for sharded lists in BC mode. Both changes
let the regular ForStmt path iterate the flat list directly.

**What this gains the checker:** sharded list pipeline ops now go
through the structural ForStmt + per-item lowering path on BC, the
same as plain lists. The legacy per-shard fiber template stays on
the Zig path (where real fibers exist).

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
5. **Cluster C (stream-source CONCURRENT)** -- both backends.
6. **Cluster D (list-source CONCURRENT)** -- both backends. Includes
   SELECT, WHERE, EACH (by-value + in-place mutation), and the
   `list AS @u s>` BIND_VAR pattern.
7. **Cluster E (thread pinning + sharded list pipeline ops)** -- BC.

Remaining:
8. **Cluster F (promise list / range streams)** -- 219, 224 still
   UNIMPL via InlineZig in init position.
9. **batch_window (243)** -- separate RawZig in expression position.
