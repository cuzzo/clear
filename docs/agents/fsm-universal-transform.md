# FSM Universal Transform — Design Spec

## Status

Proposed. Locked in by `CLAUDE.md` Invariant 13 (no per-shape FSM
emitters). Replaces the five existing snowflake emit functions
(`emit_fsm_bg_code`, `emit_fsm_io_bg_code`, `emit_fsm_with_bg_code`,
`emit_fsm_loop_bg_code`, `emit_fsm_next_chain_bg_code`) with one
general transform.

## Why

We had five emitters because each was added when a benchmark or test
needed it. The cross-product of body shapes (multi-IO, IO inside
loop, try around IO, nested WITH, mixed IO+NEXT, accept loop, ...)
blows up combinatorially. Tokio, async Rust, JavaScript async,
Python coroutines — every async language compiles `await`/suspend
points uniformly through one transform that doesn't care about
surrounding shape. That's the model.

## Architecture

### Inputs

- BG body: `[AST::Stmt]`
- Captures, capture metadata, pin mode, runtime context, etc. (all
  the existing `emit_fsm_io_bg_code` parameters).

### Output

- One `MIR::FsmGenericBody` containing:
  - `FsmGenericCtxStruct` with state fields = (captures + per-suspend
    stash fields + variables-live-across-suspends)
  - One `FsmMemberFn` per segment in the segment graph
  - One `resume_fn_zig` rendering the dispatch (labeled while-true
    switch on `step`)
  - `FsmSpawnSetup` for ctx alloc / spawn / break

### Three pieces

#### 1. Segment splitter (`fsm_transform/segments.rb`)

Walks the BG body AST and produces a segment graph:

```
Segment = {
  index: Integer,
  stmts: [AST::Stmt],         # MIR-lowerable straight-line stmts
                              #  (no embedded suspends)
  tail: SegmentTail,          # how this segment ends
}

SegmentTail = oneof:
  Done                                         # final segment
  IoSuspend(stdlib_def, args, result_var?)     # tcp/file/sleep call
  NextSuspend(promise_ast, result_var?)        # NEXT on a promise
  LockSuspend(lock_ast, method, error_clause)  # WITH lock acquire
  LoopBack(target_segment_index)               # while back-edge
  Goto(target_segment_index)                   # unconditional fall-through
  CondBranch(cond_ast, then_seg, else_seg)     # if/while head
```

Visitor rules (these are the ENTIRETY of shape handling — no other
form-specific logic exists):

- **Linear stmt without suspend:** appended to current segment's
  `stmts`.
- **Linear stmt with suspend at top level (e.g.
  `x = read(p)`, `NEXT q`):** seal current segment with the matching
  Suspend tail, start new segment for what follows.
- **WHILE loop containing a suspend:** seal current segment with
  `Goto(loop_head)`. Emit `loop_head` segment with `CondBranch(cond,
  loop_body_first_seg, post_loop_seg)`. Recurse into loop body.
  Last segment of loop body gets `LoopBack(loop_head)` if it doesn't
  otherwise terminate.
- **WHILE loop with no suspend inside:** the whole loop is just one
  AST stmt; emits as part of the surrounding segment (no states).
- **WITH block:** seal current segment with `LockSuspend(lock,
  method, error_clause)`. CS body becomes one or more segments
  (recursing — CS body can itself contain suspends or loops).
  Last CS segment auto-emits the unlock + falls through to the
  post-WITH segment via `Goto`.
- **IF with suspend in some branch:** seal with `CondBranch`,
  recurse into both branches; both converge via `Goto(post_if_seg)`.
- **IF with no suspends:** emits as part of surrounding segment.
- **try/catch with suspend in body:** out of scope for v1; classifier
  rejects FSM eligibility for now.

#### 2. Liveness (`fsm_transform/liveness.rb`)

Standard live-variable analysis on the segment graph:

```
def cross_segment_vars(segments):
  # For each var:
  #   first_def_seg = lowest segment index where var is defined
  #   last_use_seg  = highest segment index where var is used
  # If last_use_seg > first_def_seg, var must live in ctx.
  #
  # "Defined" = AST::VarDecl or assignment LHS.
  # "Used"    = AST::Identifier read in an expression.
  # Recurse into nested control flow (if/while bodies count as
  # part of their containing segment's def/use set unless they
  # contain their own suspend, in which case the body splits into
  # its own segments and we track per-segment uses).
```

Promotion plan: every cross-segment variable becomes a state field
on the FSM ctx struct. The segment that defines it stops emitting
`const X = ...;` and instead emits `__ctx.X = ...;`. Reads in later
segments read `__ctx.X`.

#### 3. State machine emitter (`fsm_transform/emit.rb`)

Given segments + cross-segment vars, build the `FsmGenericBody`:

```
ctx_struct.state_fields = [
  "step: u8 = 0,"
  for var in cross_segment_vars: "{var.name}: {var.type} = undefined,"
  for suspend in suspends_needing_stash: "{suspend.stash_name}: {stash_type} = undefined,"
]

ctx_struct.member_fns = [
  for seg in segments:
    FsmMemberFn(
      name = "runSeg{seg.index}",
      body = lower_step_stmts(seg.stmts) + tail_emit(seg.tail)
    )
]

ctx_struct.resume_fn_zig =
  "fn resumeFn(...) { __sw: while (true) switch (step) {
      0 => { dispatch_arm(seg_0) },
      1 => { dispatch_arm(seg_1) },
      ...
   } }"
```

Each `tail_emit` is a small fixed pattern per `SegmentTail` kind:

- **`Done`**: `wg.done(); destroy(ctx); return Done;`
- **`IoSuspend`**: setup ops via FsmOps lowerer; `ctx.step = next; return WaitForIO(waiter);`
- **`NextSuspend`**: `if registerFsmWaiter(promise.wg) { step = next; return WaitForLock; } step = next; continue :__sw;`
- **`LockSuspend`**: try-lock loop; on Acquired falls through; on Registered yields WaitForLock with retry-on-timeout.
- **`LoopBack` / `Goto`**: `step = target; continue :__sw;`
- **`CondBranch`**: `if (cond) { step = then_seg; } else { step = else_seg; } continue :__sw;`

Each tail kind is ~10 lines of fixed Zig. New suspend kinds
(channel send, parking_lot park, etc.) become entries in the tail
emit table — not new emit functions.

## Integration

`mir_lowering.rb#lower_bg_block`:

```ruby
if node.spawn_form == :fsm && pin_mode != :shared
  body = FsmTransform.transform(node.body, ctx)
  return MIR::BgBlock.new(FsmWrapperEmitter.render(body), captured, [], ...)
end
# fall through to stackful spawn
```

The classifier (`spawn_form == :fsm`) is the ONLY shape question. No
`use_fsm_io / use_fsm_with / use_fsm_loop / use_fsm_next_chain` —
all of those go away.

## What this deletes

| File | Before | After |
|---|---|---|
| `fsm_lowering.rb#emit_fsm_bg_code` (B1) | ~70 lines | gone |
| `fsm_lowering.rb#emit_fsm_io_bg_code` (B2-IO) | ~250 lines | gone |
| `fsm_lowering.rb#emit_fsm_with_bg_code` (B2-WITH) | ~280 lines | gone |
| `fsm_lowering.rb#emit_fsm_loop_bg_code` (B2-LOOP) | ~180 lines | gone |
| `fsm_lowering.rb#emit_fsm_next_chain_bg_code` (B2-NEXT-CHAIN) | ~220 lines | gone |
| `find_fsm_io_split` / `find_fsm_with_split` / `find_fsm_next_chain` / `find_fsm_loop_split` (shape detectors) | ~250 lines | gone |
| `mir_lowering.rb` use_fsm_* branches | ~80 lines | gone |
| | **~1330 lines deleted** | |

## What this adds

| File | Lines |
|---|---|
| `src/mir/fsm_transform/segments.rb` | ~200 |
| `src/mir/fsm_transform/liveness.rb` | ~150 |
| `src/mir/fsm_transform/emit.rb` | ~250 |
| `src/mir/fsm_transform.rb` (entry point + helpers) | ~50 |
| Updates to `mir_lowering.rb` | ~30 |
| | **~680 lines added** |

Net: ~650 lines deleted, complexity collapsed to one algorithm.

## Migration plan (incremental)

The transform can be written and validated in stages without
breaking any existing test:

1. **Stage 1 — Skeleton + linear bodies.** Write the transform with
   support for: linear stmts, IoSuspend, NextSuspend, Done. This
   subsumes B1, B2-IO, and B2-NEXT-CHAIN. Wire the lowering to call
   the new transform for those classifier outcomes; keep B2-WITH /
   B2-LOOP on the old emitters until the next stage.

2. **Stage 2 — Loops.** Add WHILE handling: LoopBack, CondBranch,
   loop-head segment construction. Subsumes B2-LOOP and unlocks
   IO-in-loop, accept-loop, mixed loops.

3. **Stage 3 — WITH blocks.** Add LockSuspend handler with retry +
   error-arm logic. Subsumes B2-WITH and unlocks
   nested-WITH, multi-WITH, WITH-in-loop, etc.

4. **Stage 4 — Delete the old emitters.** Once every existing FSM
   transpile-test passes through the universal transform, delete
   `emit_fsm_*_bg_code` and the shape detectors. Update the
   classifier to ask only "is this BG FSM-eligible?"

Each stage is testable in isolation (existing tests for the
covered cases pass; the cases not yet covered keep using the old
emitters). After Stage 4, the FSM lowering invariant is fully
realized.

## Future suspend kinds (free with the transform)

Any new suspend op is a new entry in the SegmentTail enum + a new
tail-emit arm. The shape of the surrounding code is irrelevant.
Already-known candidates:

- `tcpRead`, `tcpWrite`, `accept`, `connect`: same as IoSuspend.
- channel `send` / `recv` on a bounded channel: a new `ChannelSuspend`
  tail with park-on-channel-waiter.
- `parking_lot.park()`: directly maps to `WaitForLock` with a
  user-provided waiter.
- generic `suspend N times` (testing/synth): trivial.

None of these require a new emitter; they require one new tail enum
value each.

## Open questions

- **Try/catch with suspends in the body.** Stage 4 doesn't cover
  this. Likely needs a dedicated try-frame state (errdefer
  semantics) attached to a segment. Defer until a real benchmark
  needs it; reject with a clear error message in the classifier
  meanwhile.
- **Nested BG (FSM spawning FSM).** Already works as long as the
  inner BG goes through the same transform. The only complication
  is captures of the inner BG — these flow through normal capture
  analysis.
- **Liveness false positives from string captures and pointer
  captures.** Cross-segment liveness correctly flags these; they
  end up as ctx fields, which is what the existing emitters do
  too. No semantic change.
