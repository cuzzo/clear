# FSM Lowering

CLEAR has two lowerings for `BG { ... }` blocks:

- **Stackful** — the BG body runs in its own fiber with a real stack (16-64 KB depending on build mode). Fast to suspend (just `swapcontext`), but every BG pays the stack cost up front.
- **FSM** — the BG body is compiled to a state machine. The "stack" is a context struct sized to the live cross-segment vars only. Contexts use scheduler-local 64 B / 128 B / 256 B slabs for the common cases. Suspends become state transitions. Tens of thousands of in-flight FSM tasks fit in the memory of a few hundred fibers.

The annotator decides per-BG which lowering to use. Eligible bodies go FSM; the rest stay stackful. A BG annotated with explicit `@local` (stack-size directive) always stays stackful; that opt-out is preserved.

This document covers what FSM lowering supports today, what it doesn't, and why.

## Context allocation plan

**Now: slab-allocate small FSM contexts.** The runtime should provide scheduler-local slabs for 64 B, 128 B, and 256 B FSM context payloads, using the scheduler/runtime allocator passed into initialization. This is for the generated FSM context, not the shared fiber stack pool. The compiler should route contexts that fit into the smallest usable slab class and keep oversized contexts off the slab path.

**Now: add `@stack` for compiler-picked stackful fallback.** When the compiler knows an FSM context is too large for the small slab classes, the explicit escape hatch should be stackful `@stack`, with the compiler selecting the stack tier from compile-time frame analysis. This keeps short-lived large contexts from silently paying heap/FSM costs when a stack is the better model.

**Future: reuse FSM state slots.** Current liveness promotes by source variable name. It does not allocate reusable storage slots for disjoint live ranges. A future pass should build an interference graph over cross-segment values and map non-overlapping values to shared fields, so ten steps that each carry two dead-before-next-step values need two slots, not twenty.

**Future: add `@fsm:heap`.** Heap FSM contexts should be explicit. If a context does not fit the slab classes and the user still wants FSM semantics, `@fsm:heap` will opt into heap allocation. Until that exists, oversized short-lived work should prefer `@stack`.

## Current state-field allocation

The compiler does **not** reuse context slots today.

- `Liveness.analyze` returns `cross_segment_vars` keyed by variable name.
- `Emit.build_recursive` emits one context field per promoted variable name.
- `SuspendResolvers.resolve_next` emits a distinct `sp_N` field for each `NEXT` suspend and a distinct result field for each result variable.
- `Emit.compute_sp_indices` assigns monotonically increasing `sp_1`, `sp_2`, ... to reachable `NEXT`/IO suspend points.

That means reuse happens only when user code literally reuses the same variable name. Distinct variables with disjoint lifetimes still become distinct context fields. Distinct suspend points also get distinct `sp_N` fields.

## How a BG body becomes an FSM

The pipeline for an FSM-eligible BG body:

1. **Phase A (annotator, `effects.rb`)** classifies the function as `fsm_eligible` and enumerates its lexical suspend points.
2. **Phase B (`fsm_transform.rb`)** routes the BG body through the recursive splitter:
   - `RecursiveSplitter.split` — walks the AST top-down and produces a flat segment graph. Each `WhileLoop` / `ForRange` / `ForEach` / `IfStatement` / `WithBlock` whose subtree contains a suspend becomes a sub-graph (init / cond / body / incr or try / woken / retry / fail / held_set, etc.). Linear stmts accumulate into the surrounding segment.
   - `Liveness.analyze` — computes which body-local vars cross segment boundaries. Those become ctx struct fields.
   - `SuspendResolvers` — produces a `MIR::SuspendDescriptor` per IO/NEXT suspend (setup stmts before yield; bind stmts after resume; ctx field decls).
   - `Emit.build_recursive` — assembles per-segment Zig text + dispatch + `destroyTask` cleanup; wraps everything in a `MIR::FsmGenericCtxStruct`.
3. **Phase C (`FsmWrapperEmitter`)** renders the ctx struct as Zig: each segment becomes a `runSegN` fn; a single `resumeFn` switches on `step` and either calls a `runSegN` then transitions or yields a `YieldReason`; `destroyTask` runs cleanup hooks when the task ends (success or error).

The non-negotiable rules per `CLAUDE.md` Invariant 13:

- One general transform. No per-shape `emit_fsm_*_bg_code` snowflake emitters.
- Adding a new suspend kind = a new `Segments` tail variant + resolver. NEVER a new top-level emit fn.
- Adding a new control-flow form = one new `emit_<kind>_fragment` in the splitter.

## Supported today

### Suspend kinds

| Kind | Source | Tail variant | Notes |
|---|---|---|---|
| `IoSuspend` | stdlib calls flagged `:suspends` (`sleep`, `readFile`, `writeFile`, `tcpRead`, ...) | `Segments::IoSuspend` | Setup posts the IO request; resume reads `inner.result`. |
| `NextSuspend` | `NEXT promise` on a scalar `Promise(T)` | `Segments::NextSuspend` | Registers on `inner.wg`, yields `WaitForFsm`, resume reads `inner.result`. |
| `LockSuspend` | `WITH EXCLUSIVE` / `WITH (write_locked_read)` on `@locked` / `@writeLocked` resources | `Segments::LockSuspend` | One per-cap chain; `tryLockForFsm` switch (Acquired / Registered / Error); per-cap `__lock_held_<i>` flag drives `destroyTask` release. Multi-cap WITH is a chain of LockSuspends. Suspend-in-CS is supported. |

### Control-flow forms

| Form | Splitter handler | Notes |
|---|---|---|
| Linear stmts | (default) | Accumulated into one segment per pivot range. |
| `WhileLoop` (cond + body) | `emit_while_fragment` | cond / body / loop-back via `Segments::CondBranch`. |
| `WhileBindLoop` (`WHILE BIND v = expr DO body END`) | `emit_while_fragment` | Reuses the WhileLoop fragment (cond expression includes the bind). |
| `ForRange` (`FOR i IN (s ..< e) DO body END`) | `emit_for_range_fragment` | init / cond / body / incr; iter var + user var live in ctx. |
| `ForEach` (`FOR v IN coll DO body END`) | `emit_for_each_fragment` | Dispatches on `Type#fsm_foreach_descriptor` — see below. |
| `IfStatement` | `emit_if_fragment` | `CondBranch` to then / else; both join at `after_idx`. |
| `WithBlock` (single + multi-cap) | `emit_with_fragment` | Per-cap chain; recursively-split CS body; explicit-unlock release segment; `destroyTask` releases on err. |
| `try / catch` around a suspend | (rejected) | See "Not supported." |

### `ForEach` collection coverage

`Type#fsm_foreach_descriptor` is the registry — adding a collection means one new branch.

| Collection | Descriptor `:kind` | Notes |
|---|---|---|
| `T[]@list`, `T[N]@list` | `:indexed_slice` (`.items` slice suffix) | usize index walks `coll.items`. |
| `T[N]` (fixed array) | `:indexed_slice` (no slice suffix) | usize index walks `coll`. |
| `T[]` (dynamic array) | `:indexed_slice` (`.items` slice suffix) | Same as list. |
| `T[N]@pool` | `:pool_indexed` | usize index walks `coll.slots`; skip-dead branch on `slots[i].alive`. |
| `T[]@set` | `:iterator` (deref) | `keyIterator()` yields `?*T`; bound var is the deref. |
| `HashMap<V>` | `:iterator` (deref) | `keyIterator()` yields `?*K`; bound var is the key, not the value. |
| Streams (`~T[]`, `~?T[]`, `~T[N]`, `~T[INF]`) | nil — falls back to stackful | See "Not supported." |

### Annotator gates

`compute_fsm_eligibility!` rejects (kept stackful):

| Reason | Why |
|---|---|
| `REENTRANT` (plain `EFFECTS REENTRANT`) | Recursion needs a real stack. |
| `EXTERN` (calls native code) | Opaque to the scheduler. |
| `:fn_pointer` (BG calls through a fn-pointer) | Dynamic dispatch can't be lowered ahead of time. |
| `:explicit_stack_size` (`@local` / `@large` directive) | User opted out. |
| No `SUSPENDS_FAMILY` effect | Pure-compute body still gets FSM lowering today (a 1-state task that runs and signals `wg.done`); listed for completeness. |

### Cleanup pipeline (one rule, one place)

For an FSM-eligible BG body, every cleanup whose target outlives a single `runSegN` fn flows through `ctx[:fsm_destroy_actions]` and runs in `destroyTask`. The action list is structural MIR finalization data, not pre-rendered Zig text. Three categories converge:

| Action | Pushed by | Ordering |
|---|---|---|
| `MIR::FsmDestroyLockRelease` | `Emit.expand_lock_segment` (one per cap) | Reverse-acquisition (LIFO). |
| `MIR::FsmDestroyCleanup(source_kind: :capture/:fresh_heap)` | `Emit.build_recursive` | After locks. |
| `MIR::FsmDestroyCleanup(source_kind: :body/:owned_result)` | cleanup lifting / suspend-result registration | After captures. |

`destroyTask` runs on both success and error paths, so a captured collection / held lock / heap value never leaks even if a runSegN errors out.

The rule that closes the historical UAF hole:

> In any segment fn, `defer NAME.<method>(...)` may NEVER appear if `NAME` is a cross-segment ctx field (captured, recursively-promoted, or in `liveness.cross_segment_vars`). Such a defer would fire when its `runSegN` returns — before the BG body completes.

`Emit.check_fsm_cleanup_invariant!` enforces this by walking each segment's lowered MIR cleanup nodes. A violation raises with the segment index and var name and points at the fix (lift to `fsm_destroy_actions`). `MIRChecker.check_fsm_structure!` then verifies that every finalize cleanup has a structural destroy action with a ctx-field target and valid cleanup/lock shape.

## Not supported (and why)

### `try / catch` around a suspend

A `try` block that wraps a suspending call would need to catch errors that arrive across segment boundaries. The current dispatch shape stores `inner.result = err` and yields `Done` on error from any segment; surfacing that error back into the try's catch handler requires a new tail variant (`FsmTailErrCatch` or similar) and per-try error routing through the dispatch.

**Why uncommon:** CLEAR's stdlib functions that suspend rarely produce errors users want to catch — `sleep`, `tcpRead`, `readFile`, `NEXT promise` either succeed or kill the BG. Most CLEAR code that wraps suspending calls in `try` does so at outer (non-BG) scope. Falling back to stackful for the rare BG that needs it costs only the fiber stack.

### `NEXT` on a stream / promise-list

The current `NextSuspend` resolver assumes a scalar `Promise(T)` shape: register on `inner.wg`, yield, resume reads `inner.result`. Streams have a different shape:

- `~T[N]` (bounded stream) holds N inner promises; `next()` advances a head and pulls from `items[head]`.
- `~T[]` (dynamic) and `~?T[]` (open) are similar.
- `~T[INF]` (infinite stream) is producer-driven: a generator fiber pushes into a ring/queue; consumers park when empty.

The bounded / dynamic / open cases are tractable (~1-2 days): each inner item is a Promise, so a stream-aware `SuspendDescriptor` would just route through the existing Promise-NEXT FSM machinery, advancing the head per resume. The infinite case needs producer-side FSM-aware wakeups (the generator must know to wake an `FsmTask`, not just unpark a fiber) — substantial runtime work.

**Why uncommon:** the canonical stream consumer in CLEAR is a pipeline (`s>`, `CONCURRENT EACH`, `MAP`, `FILTER`). Pipelines have their own concurrency machinery and don't go through FSM lowering. Direct `NEXT stream` inside a BG body has zero hits across `examples/`, `benchmarks/`, and `transpile-tests/`. Stream-consuming BGs that need FSM economy are a hypothetical pattern; the few BGs that do consume streams pay the fiber stack cost without anyone noticing.

### `ForEach` over a stream

Same root cause as `NEXT stream`: each iteration's `coll.next()` blocks via `wg.wait()`, which would block the worker thread from inside a runSegN — defeating cooperative scheduling. The fix tracks with the previous gap.

**Why uncommon:** stream pipelines (`s>`) cover this idiomatically; `FOR x IN stream DO ... END` inside a BG body has zero hits in the corpus.

### Suspend nested inside a user fn call

Phase A enumerates lexical suspend points only — a call to a user fn whose body suspends doesn't count as a suspend at the call site. The enumerated count then mismatches what the splitter sees, so the body falls back to stackful.

**Why uncommon:** lifting this requires interprocedural FSM lowering — the called fn must itself be FSM-able and inlined or split at the call site. That's a much larger architectural step (and overlaps significantly with the thunks+trampolines design that handles recursion + fn-pointer dispatch). Skip until the trampoline path lands.

### Reentrant recursion that suspends

Recursion needs a real stack. There's no realistic way to FSM-lower a recursive descent parser whose recursion depth depends on input. This is the trampoline path's territory.

### `EXTERN` calls

Opaque to the scheduler. The trampoline path may eventually wrap EXTERN calls in suspend-aware shims, but nothing today does.

### `:fn_pointer` dispatch

A BG that calls through a fn-pointer table can't have its dispatch lowered ahead of time without devirtualization. Trampoline path territory.

## Adding a new collection to `ForEach`

Add one branch to `Type#fsm_foreach_descriptor`. The descriptor returns a hash with `:kind` (one of `:indexed_slice`, `:pool_indexed`, `:iterator`) plus shape-specific fields:

- `:indexed_slice` — `slice_suffix` (`""`, `".items"`, etc.), `var_zig_type`.
- `:pool_indexed` — `var_zig_type` (read from `slots[i].value`).
- `:iterator` — `init_method`, `advance_method`, `deref` (true if `next()` yields `?*T`), `var_zig_type`.

The splitter's `emit_for_each_fragment` dispatches on `:kind`; the splitter never inspects collection types directly. Adding a new shape (e.g. a tree iterator) is one new `emit_for_each_<kind>` in the splitter and one new branch on `fsm_foreach_descriptor` — no other code changes.

Cleanup for the new collection's captured form is automatic: if its `Type#resolve_resource_close` returns a `close_zig` template, the FSM transform routes it through `ctx[:fsm_destroy_actions]` and `destroyTask` releases on task end. Resource templates use `{0}` for the value and `{rt}` for runtime access; `MIRChecker` rejects legacy implicit `rt.` templates at the FSM finalizer boundary.

## Adding a new suspend kind

1. New `Segments` tail variant carrying whatever data the resolver needs.
2. `Segments.classify_suspend` recognizes the AST/MIR pattern and returns the variant.
3. `SuspendResolvers.resolve` produces a `MIR::SuspendDescriptor` with `setup_stmts`, `bind_stmts`, `tail`, `ctx_field_decls`.
4. If the suspend has fan-out shape (multiple states like LOCK does — try / woken / retry / fail / held_set), implement that fan-out in `Emit.expand_<kind>_segment` invoked from `build_recursive`.

No new top-level emit function. The unified emit (`Emit.build_recursive` -> `build_fsm_unified` -> `FsmWrapperEmitter`) handles it.

## Verification

Run after every change to FSM code:

```bash
bundle exec rspec spec/fsm_*.rb
./clear test transpile-tests/27{4,7}_fsm_*.clear  # core FSM coverage
./clear test transpile-tests/29{1,2,3,4,5}_fsm_*.clear  # ForEach + WITH redesign
./clear test transpile-tests/                       # full corpus
```

The `fsm_cleanup_invariant_spec.rb` covers the Pass-4 hole that previously allowed the capture UAF to compile. Any future change that re-introduces a `defer` in a runSegN whose target is a cross-segment ctx field will fail loudly at transpile time with the segment index and var name in the error.
