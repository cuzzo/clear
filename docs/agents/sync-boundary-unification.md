# Sync-Boundary Unification: One Path For BG / BG STREAM / DO / CONCURRENT

## The problem in concrete form

Every value that crosses from outer-scope into a fiber-like body
(BG / BG STREAM / DO branch / CONCURRENT EACH/SELECT/WHERE callback)
needs a *boundary contract* answering five questions:

1. **What's captured?** (which outer names the body references)
2. **What's the live type at the call site?** (post-monomorphization,
   post-`propagate_caller_sync!`)
3. **How does each capture cross?** (move / clone / refcount / fresh
   heap copy / by-value / refuse)
4. **What MIR markers fire?** (SuppressCleanup, AllocMark, Cleanup,
   MoveMark)
5. **What does the body see?** (rewritten identifier → ctx field;
   live storage/sync info for downstream lowerings like WITH EXCLUSIVE)

Today, after the consolidation work in this branch:

- Question 1 is answered by ONE walker (`analyze_fiber_captures`).
  ✓ unified.
- Question 2 was answered by FOUR places before; after Layer 3 of the
  Bug 257 fix it's answered by ONE place (`BgCaptureClassifier`
  refreshes capture_symbols against `fn.params[i][:symbol]`). ✓ unified.
- Question 3 is answered by ONE classifier (`BgCaptureClassifier`
  computes strategies + derived sets). ✓ unified.
- Question 4 is *partially* answered by ONE place (`MIRPass.insert_bg_give_suppress!`
  reads `move_mark_names`). ✗ FreshHeapCopy markers still unwired.
- Question 5 is now answered by ONE channel (`with_fiber_capture_map`
  carries both the rewrite map and `capture_symbols`; `with_cap_sync_storage`
  reads the latter). ✓ unified.

That leaves THREE structural gaps:

**Gap A — FreshHeapCopy emission.** `CaptureStrategy.classify` returns
`FreshHeapCopy` for `COPY x` at a BG capture site, but its
`marker_plan` (`[:alloc_mark, …] + [:cleanup, …]`) is never executed.
Combined with the underlying `COPY @list` bug, any user code that
takes this path is unsafe.

**Gap B — Four ctx-struct emitters.** The capture *analysis* is
unified, but the *emit-the-ctx-struct-and-spawn-the-fiber* step still
lives in four functions:

- `lower_bg_block` (BG)
- `lower_bg_stream_block` (BG STREAM)
- `lower_do_block` (DO)
- `pipeline_host.build_bounded_concurrent_callback{,_pointer}` (CONCURRENT)

The fields, init pattern, and body access are now identical across
all four (`@TypeOf(name)` field, `.name = name` init, `ctx.name`
access). The control fields differ (Promise.inner+alloc vs. WaitGroup
vs. nothing) and the spawn API differs (spawnBest+Promise vs.
spawnBest+WaitGroup vs. concurrentBoundedSelect/Where/Each), but the
*capture handling* is duplicated four ways.

**Gap C — `Scope#initialize_copy` deep-copies entries.** This is the
root of the dual-SymbolEntry class. We worked around it for the
fiber-capture path (Layer 3 of the Bug 257 fix) but the general
problem remains: any pass that mutates a function-param SymbolEntry
needs to remember that nested-scope copies exist and won't see the
mutation.

## What "one bullet-proof path" means

Concretely: **a single `FiberCtxBuilder` API** that all four
lowering sites call. The builder takes:

- The CaptureAnalysis (already populated by BgCaptureClassifier)
- The body MIR
- The site-specific control fields (Promise.inner / WaitGroup / nothing)
- A `body_decoration` callback for site-specific run-fn signatures

And returns:

- The ctx struct definition (fields + init)
- The body MIR with capture rewrites applied
- The MIR markers (SuppressCleanup, AllocMark, Cleanup) for FreshHeapCopy
  and MoveInto strategies
- The capture_symbols map for `with_fiber_capture_map`

Every fiber-like lowering becomes:

```ruby
def lower_bg_block(node)
  spec = FiberCtxBuilder.build(
    analysis: node.capture_analysis,
    body: node.body,
    extra_fields: ["inner: *Promise(T).Inner", "alloc: std.mem.Allocator"],
    extra_inits: [".inner = promise.inner", ".alloc = alloc"],
    rt_override: bg_rt,
    run_fn_signature: bg_run_signature,
  )
  # Wrap with BG-specific spawn:
  # `try CheatHeader.spawnBest(@intFromPtr(...), spec.run_fn_ptr, &spec.ctx_var, task_cfg)`
  emit_bg_wrapper(spec)
end
```

`lower_do_block`, `lower_bg_stream_block`, and the pipeline_host
callbacks become equally thin. The 4 ctx emitters → 1 builder.

## Implementation plan

### Phase 1: Extract `FiberCtxBuilder` (1 commit)

New file `src/mir/fiber_ctx_builder.rb`. Takes the inputs above, returns
a struct with `ctx_def`, `ctx_var`, `body_mir_with_rewrites`, and
`marker_plan_emissions` (a list of MIR nodes to insert at the BG
boundary).

The four current emitters call into it with their site-specific
extras. The body is identical to today's pattern (`@TypeOf` fields,
`.name = name` init, `ctx.name` rewrite) — just centralized.

Risk: low. Pure refactor; the field/init/access pattern is the same.

Testing: 343/343 must hold. If any single fiber-like lowering changes
shape, the builder is wrong.

### Phase 2: Wire `FreshHeapCopy.marker_plan` (1 commit)

`FiberCtxBuilder` walks each capture's strategy and emits its
`marker_plan` markers:

- `MoveInto` → MIR::SuppressCleanup at the outer scope (already
  emitted by MIRPass.insert_bg_give_suppress!; either delete that
  duplication OR delete the marker_plan entry — single source).
- `FreshHeapCopy` → MIR::AllocMark + MIR::Cleanup paired around the
  ctx field. The init becomes `.name = try CheatLib.dupeXXX(name, alloc)`
  instead of `.name = name`.
- `RcClone`, `ByValue`, `Refuse` → no markers (current behavior).

Closes Gap A.

Risk: medium. Needs the underlying `COPY @list` (bug 258) fix first,
or the FreshHeapCopy path will still produce empty lists. Or scope
this commit to FreshHeapCopy-of-struct (which works today via
`dupeStruct`).

### Phase 3: Reconsider `Scope#initialize_copy` deep-copy semantics (1 commit, optional)

The deep-copy is intentional — it isolates per-scope mutation of
SymbolEntry state (e.g. `live`, `moved`, `borrowed_alias`). But it
also breaks any cross-scope-mutating analysis (propagate_caller_sync,
escape promotion stamping). Today every such analysis has to remember
to look up the function-level entry, not the local-scope copy.

Options:
- **Option A**: keep the deep-copy, document the rule "to mutate a
  param's storage/sync, mutate `fn.params[i][:symbol]` directly."
  Provide a helper that propagates to all known scope copies.
  Cheapest option; minimal risk. The Bug 257 Layer 3 fix is the
  pattern.
- **Option B**: make storage/sync entries shared (boxed) so child
  scopes see parent mutations. Massive blast radius.
- **Option C**: mark which entry fields are "scope-local" (live,
  moved, borrowed_alias) vs "global" (storage, sync, type). Only
  scope-local fields get deep-copied. Medium risk.

Recommend (A) for now; revisit only if more dual-SymbolEntry bugs
appear.

### Phase 4: Document the boundary contract (this doc + cross-refs)

Update `docs/agents/bg-fibers-postmortem.md` to point at this doc.
Add `docs/agents/sync-boundary-contract.md` (this file's eventual
title) listing the 5 questions and the single answer-source for each.

## What the builder ELIMINATES

- 4 places that each compute "field type for this capture" → 1.
- 4 places that each emit "init the ctx field" → 1.
- 4 places that each set up "body access rewrites" → 1.
- N+1 places that each forget to thread capture_symbols → 1.
- The opportunity for any future "Phase E" / new fiber-like construct
  (CHANNEL, ASYNC, future @parallel WHERE) to add a 5th divergent
  emitter. New constructs become two arguments to FiberCtxBuilder
  instead of a new emitter.

## What the builder LEAVES OPEN

- Site-specific spawn machinery (Promise.spawn vs. WaitGroup.add vs.
  CheatLib.concurrentBounded*). These are inherently different
  runtime APIs and should stay separate.
- Body lowering itself — each construct still drives its own MIR
  generation. The builder is about the *boundary*, not the body.

## Status today (after Phases 1 + 2 + 3)

- ✓ Capture analysis unified (BgCaptureClassifier)
- ✓ Live storage/sync threading unified (with_fiber_capture_map +
  capture_symbols + with_cap_sync_storage)
- ✓ Field/init/access pattern unified (`@TypeOf`/`.name = name`/`ctx.name`)
- ✓ Ctx-struct capture emission unified (`FiberCtxBuilder.build`):
  one builder feeds `lower_bg_block`, `lower_bg_stream_block`,
  `lower_do_block`, and pipeline_host's
  `build_bounded_concurrent_callback{,_pointer}`. The four sites still
  own their site-specific control fields (Promise.inner+alloc /
  WaitGroup / stream_inner+alloc / nothing) and their runtime spawn
  APIs; the *capture* concern is one function.
- ✓ FreshHeapCopy wiring (Phase 2 / Gap A): when a capture's strategy
  is `CaptureStrategy::FreshHeapCopy` (user wrote `COPY x` inside
  the body), `FiberCtxBuilder` returns a `dupe_decl_zig` (pre-spawn
  `try CheatLib.dupeValue` + errdefer cleanup) and a
  `body_cleanup_zig` (`defer CheatLib.cleanup` on the duped ctx
  field). `lower_bg_block` injects both into the emitted Zig.
  Works today for plain structs / strings; collections-with-deinit
  (ArrayList / HashMap / Pool) still fall through `dupeValue`'s
  shallow path -- that is the language-level COPY @list bug 258
  and is out of scope for this builder. Test:
  `transpile-tests/281_bg_body_copy_struct.cht`.
- ✓ `Scope#initialize_copy` deep-copy contract documented + helper
  extracted (Phase 3 / Option A): `Scope.live_param_syms(fn)` is the
  canonical way to refresh a SymbolEntry cache against the live
  function-level entries that `propagate_caller_sync!` mutates.
  `Scope#initialize_copy` and `SymbolEntry` carry the contract in
  doc-form so a future pass that mutates storage / sync sees the rule
  before adding a new dual-SymbolEntry bug.

The most critical gap is now CLOSED: a value crossing a sync
boundary uses one capture analysis, one strategy classifier, one
storage-resolution channel. The remaining work is structural cleanup
to prevent FUTURE divergence — the *current* bugs are fixed.
