# BG Fibers Postmortem: Compiler Status, Bug Patterns, Architectural Path Forward

This is a postmortem on the bugs surfaced (and the workarounds applied)
while turning on real concurrent BG fibers in the bytecode VM. The goal
is to honestly catalog the bugs, the patterns that let them slip
through, and the **architectural changes that would make this class of
bug impossible** — not by adding more checks, but by removing the
sources of complexity that produced them.

## Status

After the work in this branch, the BG fiber path through the BC VM
runs all 7 BG transpile-tests correctly:

| Test                          | Pattern                              |
|-------------------------------|--------------------------------------|
| 58_bg                         | literal + capture-by-value           |
| 59_bg_concurrent              | three-fiber spawn + reverse NEXT     |
| 65_bg_string_capture          | string concat in fiber body          |
| 172_bg_string_return          | fiber returns string                 |
| 173_nested_bg                 | BG inside BG                         |
| 253_bg_capture_locked_param | @shared:locked param captured by BG  |
| 54_writefile_bg               | side-effecting fiber                 |

Suite remains: 342/342 transpile-tests, 2583/0 specs, 0 leaks.

Four latent compiler/stdlib bugs remain, with disabled-test repros:

- `transpile-tests/255_union_equality.clear.disabled` — `IF s == Status.Active` on a payload-bearing union compiles to Zig that fails.
- `transpile-tests/256_sleep_int_literal.clear.disabled` — `sleep(1)` compiles to Zig that rejects `@bitCast` on `comptime_int`.
- ~~`transpile-tests/257_concurrent_capture_locked_param.clear.disabled`~~ FIXED. Three bugs combined here, all now closed: (1) pipeline_host's `*const T` + `&name` ctx pattern → migrated to `@TypeOf(name)`; (2) list-source CONCURRENT EACH didn't populate `conc_op.capture_analysis` (analyze_each_op was the non-concurrent analyzer) → now runs `analyze_fiber_captures` after the proxy dispatch; (3) the dual-SymbolEntry root cause: `Scope#initialize_copy` deep-copies SymbolEntries when entering child scopes, so the entry capture analysis sees inside a CONCURRENT body is a stale copy of the function-param entry that propagate_caller_sync! mutates. Fixed by `BgCaptureClassifier` re-resolving captures against `fn.params[i][:symbol]` (the live entry) before classification, and `with_fiber_capture_map` threading the live capture_symbols through to body lowerings so `WITH EXCLUSIVE`'s `with_cap_sync_storage` reads the live `:shared` storage instead of the deep-copy's stale `:stack`.
- `transpile-tests/258_bg_body_copy_capture.clear.disabled` — `BG { snapshot = COPY items; ... }` for a captured `@list`. CaptureStrategy returns FreshHeapCopy for this, but neither the strategy's `marker_plan` (`[:alloc_mark, ...] + [:cleanup, ...]`) nor the body-side COPY lowering is wired. The body's COPY currently crashes at MIREmitter (`unknown node type Array`); even once lowering succeeds, the heap copy still wouldn't be emitted, producing a silent UAF.

## Catalog of bugs fixed

### True compiler bugs (mostly invisible to user)

1. **BG capture field type mismatch** (commit `04062213`)
   `mir_lowering.lower_bg_block` computed the BG ctx struct's field type from the
   capture's nominal `Type` object. For an `anytype` parameter that received an
   `@shared:locked` value from the caller, the actual deduced Zig type included an
   `Arc(...)` wrapper that the nominal Type didn't reflect. Result: field declared
   `*Locked(T)`, init `&pool` typed `*const *Arc(Locked(T))`, Zig rejects.

2. **BG capture stale type** (commit `004fb459`)
   `analyze_fiber_captures` snapshotted `node.type_info` during Pass 1. `propagate_caller_sync!`
   ran in Pass 2a and stamped sync/storage on parameter `SymbolEntry`s. By Pass 4 the
   snapshot was stale. Fixed by also recording the live `SymbolEntry` and re-resolving
   at lowering time.

3. **BG escape analysis missed nested control flow** (in commit `1522e534`)
   `EscapeAnalysis.e2_each_bg` only descended into top-level `VarDecl`/`BindExpr`/
   `Assignment`/`FuncCall`/`MethodCall`. Any BG block nested in a `WHILE`/`FOR`/`IF`/
   `MATCH`/`WITH`/`DO` was invisible, so its captured `@list`/etc. wasn't promoted to
   heap, and the per-iteration frame rewind freed the spawned fiber's data.

4. **BG `was_moved` flag silently dropped by walkers** (commit `378036a0`)
   `function_analysis.rb`'s `ensure_owned_value!` wraps a user's `MoveNode` in a
   `CopyNode` (for type adaptation, e.g. `@list` arg passed to a slice param) and
   stamps `was_moved=true` on the wrapper. Two downstream walkers
   (`OwnershipDataflow.collect_bg_body_gives` and `MIRPass._walk_expr_for_give`)
   hard-skipped `CopyNode` without checking the flag, so the user's `GIVE` intent
   never reached the dataflow or the suppress-cleanup pass.

5. **AWAIT used `getStr` on a `Symbol`** (commit `1522e534`)
   `BG_SPAWN` constructs `Value.Pair { pairCar: Value{Symbol: "__future__"}, ... }`,
   but AWAIT checked the marker via `getStr(pcar)` which returns `""` for non-`Str`
   variants. The equality always failed and AWAIT silently returned the bgFid
   `Int64Val` instead of NEXTing the promise. Strictly a CLEAR-program bug in
   `_bc_runner.clear`, not a compiler bug — the compiler had no way to catch it
   because both `getStr` and `getSymName` are valid `Value -> String` functions.

### Compiler/stdlib bugs that I worked around but did not fix

6. **`Value == Value` on payload union** (worked around in commit `1bc679ec`, repro at `255_union_equality.clear.disabled`)
   The compiler emits Zig `==` between two values of a payload-bearing union. Zig
   rejects. The compiler should either (a) reject `==` on such unions at the CLEAR
   level with a clear diagnostic pointing at the source line, or (b) synthesize a
   per-union equality helper (compare active tag, then variant-specific equality).

7. **`sleep(1)` comptime_int** (worked around in commit `1bc679ec`, repro at `256_sleep_int_literal.clear.disabled`)
   The stdlib template `rt.sleep(@intCast(@as(u64, @bitCast({0}))))` substitutes the
   raw expression text. For `sleep(1)` it expands to `@bitCast(1)`, and Zig rejects
   `@bitCast` on `comptime_int`. The annotator knows the param is `:Int64` and the
   literal would be coerced — but that information doesn't reach template
   substitution. Either templates should know their declared param types and emit a
   coercion (`@as(i64, {0})`), or the call-site emitter should coerce literal
   numeric args before substitution.

### Process bug

8. **`bc_run.rb` swallowed build errors** (commit `7fe32919`)
   `system(...,[:out, :err] => File::NULL)` discarded stderr. When the cached
   `_bc_runner` binary already existed, a failing rebuild left the old binary in
   place, and tests ran the stale binary. This is what hid Phase A's broken
   real-fiber commit, Phase B's broken lock_acquire commit, and Phase C's broken
   sleep commit for *months* — every commit's tests passed, against a binary that
   didn't include the commit's changes.

### Performance bug

9. **`BC_RET` O(N²) pop** (commit `cc6e4b98`)
   `callSavedSlots.remove(savedBase)` 256 times per return. `.remove(idx)` is
   `orderedRemove` (O(N) shift). For fib(25) at depth 25, ~6400 list items × 256
   removes per return × 75k returns ≈ 120 billion memmove ops. Replaced with
   `.pop()` (O(1)) and added a per-call `caller_slot_count` operand so each call
   saves only what the caller actually uses, not a fixed 256.

### CLEAR-program bugs (compiler did its job, source had to be fixed)

10. **`WHILE NOT acquired`** — `NOT` is not a CLEAR keyword; CLEAR uses `!`. The
    parser correctly rejected the source. Fixed in commit `1bc679ec` by writing
    `WHILE !acquired`.

11. **`srcInts.append(...)` on `TypedI64Arr`** — the variant payload is `[]i64`
    (a slice), which has no `.append` method. The Zig compiler correctly rejected.
    Fixed in commit `1bc679ec` by reverting to the `build-new-list` pattern.

## How these bugs slipped through

Three failure modes did most of the work.

### Failure mode A: silent build pipeline

`bc_run.rb` discarded stderr from the bc_runner build. Combined with a file-mtime
cache that left a stale binary in place when the rebuild failed, this turned every
commit that broke `_bc_runner.clear` into a no-op:

> Test runs use the cached binary from before the commit ⇒ tests pass ⇒ commit
> looks green ⇒ commit lands ⇒ next commit inherits a stale-binary state ⇒
> repeats.

This let three multi-commit "phases" (real BG fibers, per-resource locks, real
sleep) each ship with source-level errors that nobody noticed for months. **Bugs
1, 5, 6, 7, 10, 11 were all directly enabled by this.**

The fix is small (commit `7fe32919`). The lesson is large: **any test infrastructure
that swallows stderr is a bug factory**. CI must surface all errors. There should be
a CI job that does a clean rebuild from a deleted-binary state.

### Failure mode B: parallel walkers diverging

The compiler has at least four walkers that collectively decide BG capture
ownership:

| Walker                                               | Purpose                                               |
|------------------------------------------------------|-------------------------------------------------------|
| `analyze_fiber_captures` (capabilities.rb)           | what is captured + per-capture metadata               |
| `EscapeAnalysis.e2_each_bg` (escape_analysis.rb)     | which captures need heap promotion                    |
| `OwnershipDataflow.collect_bg_body_gives` (control_flow.rb) | which outer bindings are consumed by `GIVE` |
| `MIRPass._walk_expr_for_give` (mir_pass.rb)          | which captures need `MIR::SuppressCleanup` emitted    |

Each walker has its own AST traversal logic. Each was missing different cases:
e2_each_bg missed control flow (#3); collect_bg_body_gives missed `was_moved`
CopyNode wrappers (#4 — first half); _walk_expr_for_give missed the same (#4 —
second half). All four had to be fixed in lockstep, and a future addition (e.g.
`ASYNC` blocks that share the same capture rules) would require updating all four
again.

The architectural fix is to **collapse the four walkers into one fact source**.
The annotator should compute capture facts ONCE, in a single AST walk, and store
them on the BG node. Every downstream consumer reads from that fact dictionary.
No walker re-derives. Concretely: extend `BgBlock.capture_analysis` so it includes
EVERY decision derived from the BG body, including:
- captures (already there)
- per-capture sync/storage (currently re-derived in mir_lowering)
- moved-by-GIVE names (currently re-derived in dataflow + mir_pass)
- consumed-by-resource names (currently in capture_analysis.resource_captures)
- needs-heap-promotion names (currently in escape_analysis.bg_capture_names)
- pointer-vs-value field decisions (currently in mir_lowering)

Then delete `collect_bg_body_gives`, `_walk_expr_for_give`, `e2_bg_capture_names`,
`insert_bg_give_suppress!`. They become reads from `bg.capture_analysis`.

### Failure mode C: AST flags as semantic side-channels

`was_moved` is a boolean flag the annotator stamps on `CopyNode` to say "this
wrapper was created from a user's `GIVE`; treat it as a move." Two walkers forgot
to read it. The compiler has many such flags (`container_borrow`, `was_moved`,
`extern_call`, `non_escaping`, `borrowed_alias`, `coerced_type`, `match_as`,
`reassign_cleanup`, `field_pre_cleanup`, `deep_copy`, `try_wrap`, `can_fail`,
`needs_rt`, `tail_call`, ...). Each flag is a contract between writer and readers
that's enforced only by code review. New readers don't know which flags to check.

The architectural fix is **explicit MIR markers, not AST flags**. The
`CaptureStrategy` machinery already exists (computes `MoveInto`, `FreshHeapCopy`,
`RcClone`, `ByValue`, `Refuse` per capture) and even has a `marker_plan` method
that returns the MIR markers each strategy needs (`[:move_mark, src_name]`,
`[:alloc_mark, ctx_name, alloc]`, etc.). It's just **never executed** —
`enforce_bg_capture_strategies!` only consumes it for the `Refuse` diagnostic.

Wiring `marker_plan` through `lower_bg_block` (emit `MIR::SuppressCleanup` /
`MIR::AllocMark` / `MIR::Cleanup` for each strategy) would:

- Delete `insert_bg_give_suppress!` (the strategy's `marker_plan` replaces it)
- Delete `insert_bg_resource_suppress!` (same)
- Delete the `was_moved` flag for BG captures (the `MoveInto` strategy is the
  source of truth)
- Eliminate the dataflow's need to walk BG bodies for `GIVE` — the strategy
  already classifies every capture

This is the single biggest complexity-reducing change available in this area.

## Other bug patterns worth naming

### Pass-ordering fragility (#2)

`Pass 1 (annotator)` snapshots type info onto AST nodes. `Pass 2a (escape analysis)`
mutates parameter `SymbolEntry`s after the snapshot is frozen. Pass 4 reads the
stale snapshot. The fix in commit `004fb459` records a *live reference* to the
SymbolEntry alongside the snapshot, but that's a band-aid: every consumer must
remember to re-resolve.

The architectural fix: **types should not be snapshotted on AST nodes at all**.
The AST should carry only what was *parsed* (no inferred types). Type info should
be queried from a separate annotated index (`AST node -> Type`), and the index
should be append-only-correct: if a later pass refines a type, the index updates
in place, and queries always see the latest. This eliminates the entire class of
"a pass remembered something stale".

This is a large refactor. A smaller incremental version: **freeze AST
`type_info` after Pass 2a**. No pass before Pass 2a may stamp `type_info`; passes
that need to record analysis facts use a side-table. After Pass 2a the freeze is
checked.

### Generated-code-can-fail (#6, #7)

The compiler emits Zig that the Zig compiler rejects. The user sees a Zig
diagnostic with line numbers in the *generated* file — useless for finding the
CLEAR source bug. Two patterns produced this:

- A stdlib template substitutes raw expression text (`{0}`) without coercion.
- An operator (`==`) is emitted on a type Zig doesn't accept it for.

The architectural fix: **a verification pass between MIR and emit that checks
"every operator/builtin we emit is valid for the operand types we'll emit it
on"**. The MIR has full type info; this is a static check. Operators that aren't
valid (union `==`) become CLEAR-level errors with proper source locations.

A weaker version: **stdlib templates declare their substitution typing**. Today
they look like `"rt.sleep(@intCast(@as(u64, @bitCast({0}))))", args: [:Int64]`.
The `{0}` substitution should know the declared arg type and emit `@as(i64, {0})`
when the arg is a literal that doesn't carry that type already. Or better:
**replace the template entirely**. CLEAR's `sleep` should map to a Zig function
whose parameter is `i64` — Zig handles the coercion at the call site. Templates
that thread `@bitCast`/`@intCast` chains are doing what Zig already does for
free, badly.

### Walker incompleteness through nested control flow (#3)

`e2_each_bg` was written to handle the simple case (BG block as the value of a
top-level VarDecl). Then someone added the WhileLoop case via `recurse_branches!`
elsewhere. Then control flow nesting deepened. The walker fell behind.

The architectural fix: **never write a walker that knows specific AST node
types**. Use the existing `AST.walk_body` (which already enumerates every
control-flow form) plus a node-type filter. `e2_each_bg`'s body becomes:

```ruby
AST.walk_body(fn.body) { |node| yield node if node.is_a?(AST::BgBlock) }
```

Three lines. Impossible to drift behind new control flow. The current 30-line
case-tree disappears.

This same pattern applies to many walkers in the codebase. They re-implement
`walk_body` poorly because the walker wants to carry extra state (a binding
context, a scope stack, etc.). The fix: separate the *traversal* (always
`walk_body`) from the *state* (passed via a stack the visitor manages).

## What the architecture should look like

If we held to the patterns above, here is what the compiler would look like for
the BG fiber subsystem:

1. **Single capture-analysis pass** runs in Pass 2b (after escape analysis). It
   does ONE walk of every BG body and stamps every fact on `BgBlock.capture_analysis`:
   captures, sync/storage per capture, GIVE/COPY classifications, capture
   strategies, marker plan, escape promotions. No re-walks downstream.

2. **`mir_lowering.lower_bg_block` is dumb**. It reads the capture_analysis,
   emits the MIR markers from the strategies' `marker_plan`, and produces the
   ctx struct. Zero new analysis. Zero per-case branches on `pointer_captures`,
   `string_captures`, `resource_captures` etc. — the strategy already
   classified each one.

3. **Field types in BG ctx struct use `@TypeOf(name)` always**. The compiler
   stops trying to compute Zig types from CLEAR types for capture sites; Zig is
   the type system at that boundary. (This generalizes commit `04062213`.)

4. **No `was_moved` flag on AST CopyNodes**. The capture strategy is
   `MoveInto` or it isn't; the marker_plan emits `MIR::MoveMark`; the dataflow
   reads MIR markers, not AST flags. Same for `container_borrow`, `non_escaping`,
   etc. — every semantic flag becomes an explicit MIR node.

5. **Stdlib template substitution is type-aware**. For `args: [:Int64]`, the
   `{0}` substitution wraps the arg in `@as(i64, {0})` if the arg is a literal
   numeric. Same for other types. Or the template engine is replaced with
   Zig-functions-with-typed-params (no string substitution at all).

6. **Pre-emit verification** rejects emitting Zig operators on types Zig won't
   accept (`==` on payload union, `@bitCast` on comptime_int, etc.). Each
   rejection becomes a CLEAR-level error with the original source location.

7. **No silent-stderr test runners**. CI does a clean rebuild from a
   deleted-binary state. Hooks fail loudly. Pre-commit and CI run the same
   commands.

This is mostly *deletion*. The commits in this branch added complexity to make
incomplete walkers more complete. The architectural direction is the opposite:
delete the walkers and the AST flags, route everything through the existing
strategy/marker machinery that was started but never finished.

## Concrete next steps in priority order

1. **Wire `CaptureStrategy.marker_plan` through `lower_bg_block`**. Delete
   `insert_bg_give_suppress!`, `insert_bg_resource_suppress!`, the `was_moved`
   handling I added in `378036a0`, and the four parallel walkers. This is the
   highest-leverage cleanup.

2. **Single capture-analysis pass after escape analysis**, replacing the
   pass-1 snapshot + Pass-4 refresh mechanism in `004fb459`. Removes the live-
   SymbolEntry indirection.

3. **Pre-emit verification of generated Zig operators** (catches `==` on
   payload union, comptime-int `@bitCast`, etc.). Makes 255 and 256 fail at
   the CLEAR level with proper source locations.

4. **Stdlib template type-aware substitution** OR replace templates with
   typed Zig functions. Removes the `sleep(1)` class entirely.

5. **`@shared:locked` Pool/HashMap cleanup leak** (still open from earlier
   investigation; independent of BG).

6. **Dual `SymbolEntry` for `pool` in bc_runner** (currently inert with the
   `@TypeOf` fix; investigate to confirm it doesn't bite elsewhere).

The combined effect of #1 and #2 would *delete* about as many lines as it
would add, eliminate two or three of the recurring failure modes, and make
adding new BG-like features (ASYNC, parallel DO branches, etc.) drop into
existing infrastructure instead of requiring N parallel walker updates.
