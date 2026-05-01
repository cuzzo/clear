# BG Capture Consolidation Plan

## Goal

Replace the four parallel walkers that each re-derive BG capture
properties with a **single authority** that derives every fact once,
stamps it on `BgBlock.capture_analysis`, and is read (never re-derived)
by every downstream consumer.

Outcome:
- Net negative line count.
- Zero possibility of "walker A and walker B disagree about whether
  capture X is moved" (the divergence class of bug that bit us in
  commit `378036a0`).
- Adding a new BG-like construct (ASYNC, parallel DO, etc.) is one
  function added to `CaptureStrategy.classify`, not N walker updates.

## Authority model (post-refactor)

Every capture-related fact has exactly one writer. Every other pass is
a reader.

| Fact                              | Authority                              | Computed when           |
|-----------------------------------|----------------------------------------|-------------------------|
| **A.** Which names are captured   | `analyze_fiber_captures` (annotator)   | Pass 1 (single AST walk) |
| **B.** Per-capture user intent (GIVE/COPY/CLONE/bare) | `analyze_fiber_captures` | Pass 1 (same walk as A) |
| **C.** Per-capture **live** Type/sync/storage | `SymbolEntry` (live)           | Read at use time, never snapshotted |
| **D.** `CaptureStrategy` per name | `BgCaptureClassifier` (new pass)       | Pass 2a-end (after `propagate_caller_sync!`) |
| **E.** Heap-promotion names       | derived from D                         | Same                    |
| **F.** Move-mark names            | derived from D                         | Same                    |
| **G.** Alloc-mark entries         | derived from D                         | Same                    |
| **H.** MIR markers in `lower_bg_block` | each Strategy's `marker_plan`     | Pass 4 (read of D)      |

Critical invariants:

1. **No fact is computed twice.** If an analysis would re-derive a
   fact, it reads `bg.capture_analysis.<field>` instead.

2. **Type information lives on `SymbolEntry`, not on the AST.** Capture
   analysis stores name → entry, not name → type. Anyone needing the
   type calls a thin helper that does the entry → Type overlay (the
   same one `Scope#resolve_full_type` uses).

3. **Strategy classification depends only on inputs (A, B, C).** Same
   inputs → same strategy, every time. No per-callsite knobs in the
   classifier.

4. **AST walks of BG bodies happen exactly twice in the whole pipeline:**
   - Once in Pass 1 to populate A and B.
   - Once in Pass 2a-end to (re-walk if needed for) link verification.
   Every other "find GIVE in body" / "find resource captures in body"
   / "find heap-promote captures in body" walker is deleted.

## What gets deleted

| File                                   | Method/section                                                         | Reason                                                |
|----------------------------------------|------------------------------------------------------------------------|-------------------------------------------------------|
| `src/mir/escape_analysis.rb`           | `e2_bg_capture_names` + `e2_each_bg` + `e2_each_block` + `e2_walk_expr_bg` | Reads `bg.capture_analysis.heap_promote_names` instead. |
| `src/mir/control_flow.rb`              | `collect_bg_body_gives`                                                | Reads `bg.capture_analysis.move_mark_names` instead.  |
| `src/mir/mir_pass.rb`                  | `insert_bg_give_suppress!` + `collect_bg_body_give_names` + `_walk_expr_for_give` + `each_bg_in_stmt` + `_walk_expr_for_bg` | Reads `bg.capture_analysis.move_mark_names`; iteration uses `AST.each_bg_block`. |
| `src/mir/mir_lowering.rb`              | `collect_bg_capture_site_info` + `refreshed_capture_type` lambda + ad-hoc `pointer_captures`/`promoted_names` re-derivations | Reads pre-computed strategies. |
| `src/mir/control_flow.rb`              | `walk_expr_skip_copy` `was_moved` special-case (added 378036a0)        | Move/copy intent comes from strategies, not flag-on-AST. |

What remains: **one** AST walker for BG blocks (`AST.each_bg_block`,
new helper that just does `walk_body` + a type filter), and the
existing `analyze_fiber_captures` (extended to also collect site_info).

## New code

| File                                   | What                                                                                       |
|----------------------------------------|--------------------------------------------------------------------------------------------|
| `src/ast/ast.rb`                       | `AST.each_bg_block(body, &block)` — one helper, used everywhere.                            |
| `src/mir/bg_capture_classifier.rb`     | New pass. Walks `AST.each_bg_block` once per fn, calls `CaptureStrategy.classify` per capture, stamps strategies + derived sets on `BgBlock.capture_analysis`. |
| `src/annotator-helpers/capabilities.rb`| Extend `CaptureAnalysis` struct to hold strategies, derived sets, site_info. Move `collect_bg_capture_site_info` here as part of the single walk. |

## Migration phases

Each phase is independently committable, reversible, and leaves the
suite green. The whole plan is roughly 8 commits.

### Phase 1 — `AST.each_bg_block` helper (1 commit)

**What**: Add the one-line walker. Replace every `each_bg_in_stmt` /
`e2_each_bg` / hand-rolled "find BG" loop with calls to it.

**Why first**: zero behavior change, but eliminates ~80 lines of
parallel implementations and makes subsequent phases trivially correct
(every walker now finds the same set of BG blocks).

**Risk**: low. Pure refactor. Tests must stay green at 342/342.

### Phase 2 — Move site_info into `analyze_fiber_captures` (1 commit)

**What**: Extend the single AST walk in `analyze_fiber_captures` to
also collect GIVE/COPY/CLONE site_info (currently a separate walk in
`mir_lowering.collect_bg_capture_site_info`). Store on
`CaptureAnalysis.site_info`.

`mir_lowering.lower_bg_block` reads `analysis.site_info` instead of
re-walking. Delete `collect_bg_capture_site_info`.

**Why early**: site_info is an input to strategy classification. We
need it ready before phase 3.

**Risk**: low. The walk that the annotator already does over the BG
body picks up MoveNode/CopyNode/CloneNode — adding site_info to it is
a few lines.

### Phase 3 — `BgCaptureClassifier` pass (1 commit, new file)

**What**: New pass between `propagate_caller_sync!` and `EscapeAnalysis.analyze!`.
For each BG block, computes strategies + derived sets, stamps on node.

```ruby
module BgCaptureClassifier
  def self.classify_all!(fn_nodes)
    fn_nodes.each_value do |fn|
      next unless fn&.body
      AST.each_bg_block(fn.body) do |bg|
        classify_one!(bg)
      end
    end
  end

  def self.classify_one!(bg)
    a = bg.capture_analysis
    return unless a
    a.strategies = a.captures.each_with_object({}) do |(name, sym), h|
      t = resolve_type_from_entry(sym)
      h[name] = CaptureStrategy.classify(
        name: name, type: t,
        site_info: a.site_info,
        is_resource: a.resource_captures.include?(name)
      )
    end
    a.heap_promote_names = a.strategies.select { |_, s| heap_promote_for?(s) }.keys.to_set
    a.move_mark_names    = a.strategies.select { |_, s| s.is_a?(CaptureStrategy::MoveInto) }.keys.to_set
    a.alloc_mark_entries = a.strategies.select { |_, s| s.is_a?(CaptureStrategy::FreshHeapCopy) }
                                       .transform_values(&:alloc_sym)
  end
end
```

**Verification**: at this stage the new sets are computed but not yet
consumed. Add an assertion (gated by env var) that compares the new
sets against what the existing walkers produce. If they ever disagree,
fail the build.

**Risk**: medium. Strategy classification is delicate; the existing
behavior is encoded in `CaptureStrategy.classify` which already
returns the right classes — but the verification gate catches drift.

### Phase 4 — `MIRPass` reads `move_mark_names` (1 commit)

**What**: `insert_bg_give_suppress!` becomes:

```ruby
def insert_bg_give_suppress!(result, stmt, bindings)
  AST.each_bg_block_in_stmt(stmt) do |bg|
    bg.capture_analysis&.move_mark_names&.each do |name|
      entry = bindings&.dig(name)
      next if entry && !entry[:needs_cleanup]
      result << MIR::SuppressCleanup.new(stmt.token, name)
    end
  end
end
```

Delete `collect_bg_body_give_names`, `_walk_expr_for_give`,
`each_bg_in_stmt`, `_walk_expr_for_bg` — replaced by reads from
`bg.capture_analysis.move_mark_names` (and the unified
`AST.each_bg_block_in_stmt` helper).

**Risk**: low if Phase 3's verification gate held. The two
implementations should agree — the new one is just simpler.

### Phase 5 — `OwnershipDataflow` reads `move_mark_names` (1 commit)

**What**: `collect_bg_body_gives(bg)` becomes a one-liner:

```ruby
def collect_bg_body_gives(bg) = bg.capture_analysis&.move_mark_names&.to_a || []
```

Delete the AST walk in `collect_bg_body_gives`. Delete the `was_moved`
special case in `walk_expr_skip_copy` (added in commit `378036a0` as a
band-aid).

**Risk**: medium. The dataflow's view of "what's consumed" must match
what MIRPass marks. Phase 3's verification gate covers this.

### Phase 6 — `EscapeAnalysis` reads `heap_promote_names` (1 commit)

**What**: `e2_bg_capture_names(fn)` becomes:

```ruby
def self.e2_bg_capture_names(fn)
  names = Set.new
  AST.each_bg_block(fn.body) do |bg|
    names.merge(bg.capture_analysis&.heap_promote_names || [])
  end
  names
end
```

Delete `e2_each_bg`, `e2_each_block`, `e2_walk_expr_bg` — all the
control-flow recursion I added in commit `1522e534` is no longer
needed because `AST.each_bg_block` handles all control flow.

**Risk**: low. Same set, computed earlier and stored.

### Phase 7 — `mir_lowering` reads strategies directly (1 commit)

**What**: In `lower_bg_block`:
- Delete `node.capture_strategies = captured.each_with_object(...)`
  block (lines 2467-2474). Strategies are already on
  `node.capture_analysis.strategies`.
- Delete the `refreshed_capture_type` lambda (added in commit
  `004fb459`). Field types come from `@TypeOf(name)` (already in
  place from commit `04062213`); the strategy supplies any other
  needed Zig-type info.
- Iterate `node.capture_analysis.strategies` and emit each strategy's
  `marker_plan` as actual MIR nodes:

```ruby
node.capture_analysis.strategies.each do |name, strat|
  strat.marker_plan.each do |marker|
    case marker
    in [:move_mark, src]
      # already emitted by MIRPass.insert_bg_give_suppress! in the outer scope
    in [:alloc_mark, ctx_name, alloc_sym]
      @pending_stmts << MIR::AllocMark.new(ctx_name, alloc_sym, nil)
    in [:cleanup, ctx_name, alloc_sym]
      # ... emit MIR::Cleanup paired with the AllocMark above
    end
  end
end
```

This finally **wires marker_plan**, which has been dead code since the
docs/agents/vm-bugs.md migration was started.

**Risk**: high — this is the most semantically substantive change.
Mitigation: Phase 3's verification gate stays on through this phase,
so any divergence in strategy outputs surfaces immediately.

### Phase 8 — Remove the verification gate + final cleanup (1 commit)

**What**: After Phases 4-7 land, the verification gate from Phase 3 is
just overhead. Delete it. Run full suite (transpile-tests + rspec +
all 7 BG bc_runner tests + benchmarks) and confirm everything still
green.

Also delete the disabled-test `255` and `256` if pre-emit verification
landed alongside (separate plan). Otherwise, keep them disabled.

**Risk**: zero if Phases 1-7 held.

## Concrete invariant the refactor enforces

After Phase 7, this assertion is *structurally true* (no test needed
to check it):

> The set of names for which `MIR::SuppressCleanup` is emitted
> equals the set of names the dataflow treats as MOVED equals the set
> in `BgBlock.capture_analysis.move_mark_names`.

Equality holds **because all three read the same field**. There's no
walker to drift; deleting the walkers makes drift impossible.

The same applies to:
- heap_promote_names (read by EscapeAnalysis only)
- alloc_mark_entries (read by mir_lowering only)
- strategies (read by mir_lowering only)

Each derived fact has exactly one writer (`BgCaptureClassifier`) and
zero or one reader. No bidirectional coupling.

## What this does NOT solve

Out of scope for this plan, but should be tracked separately:

- **Latent compiler/stdlib bugs surfaced by the disabled tests**
  (`255_union_equality`, `256_sleep_int_literal`). These are about Zig
  emission validity, not capture analysis. They need pre-emit
  verification or stdlib template changes — see the postmortem
  document.

- **`@shared:locked` Pool/HashMap cleanup leak**. Pre-existing, in
  collection cleanup, not in BG capture. Independent.

- **Dual `SymbolEntry` for `pool` in bc_runner**. Currently inert
  thanks to the `@TypeOf` fix. Only worth investigating if it bites
  again.

- **DO blocks** (`AST::DoBlock`) have a parallel
  `branch[:capture_analysis]` mechanism with its own walker in
  `lower_do_block`. Same refactor pattern applies to DO. Save for a
  follow-up.

## Estimated impact

- **Lines deleted**: ~250 (walkers + their helpers + the band-aids)
- **Lines added**: ~120 (new `BgCaptureClassifier` + extended
  `CaptureAnalysis` struct + `AST.each_bg_block` helper)
- **Net**: -130 lines.

**Actual measured (after landing phases 1-7):**
- Phase 1-3 (infrastructure): +200 lines, -2 lines (net +198)
- Phase 4-7 (consumers + walker deletion): +156 lines, -320 lines (net -164)
- Combined: +356 lines, -322 lines (**net +34 lines**)
- The estimate was -130; actual was +34. The deviation is because
  the consolidated `AST.each_bg_block` plus its `each_bg_block_in_stmt`
  twin is ~70 lines (vs the ~30 estimated for "one helper") --
  the per-stmt vs recursive split required an explicit second method
  rather than a `recurse:` flag (the flag-version still descended
  into control flow, which broke SuppressCleanup callers).
- The win isn't in the line count -- it's in the structural invariant:
  every read of "is this name moved by a BG?" goes through
  `bg.capture_analysis.move_mark_names`. Walker drift is impossible.
- **Walker count over BG bodies**: 4 → 1 (`analyze_fiber_captures`).
- **Sources of "name X is moved" truth**: 3 → 1 (`move_mark_names`).
- **Failure modes eliminated**:
  - Parallel walkers diverging (the `378036a0` class).
  - Pass-ordering snapshot vs. mutated entry (the `004fb459` class).
  - AST flag silently ignored by some readers (the `was_moved` class).
- **New BG-like feature cost**: one new `CaptureStrategy::*` subclass
  + entry in `classify`, instead of N walker updates.

## Order of operations

The phases are deliberately ordered so each one leaves the suite green:

```
Phase 1 (each_bg_block)            ── pure refactor, no semantic change
Phase 2 (site_info into capture)   ── still no semantic change
Phase 3 (BgCaptureClassifier)      ── adds strategies field; verification gate
Phase 4 (MIRPass uses new field)   ── one consumer migrated
Phase 5 (OwnershipDataflow uses)   ── second consumer migrated
Phase 6 (EscapeAnalysis uses)      ── third consumer migrated
Phase 7 (lower_bg_block uses)      ── fourth consumer; marker_plan finally wired
Phase 8 (remove gate)              ── cleanup
```

If Phase N regresses, revert Phase N alone — earlier phases keep their
gains. The verification gate (Phase 3) ensures we catch regressions
during 4-7 immediately.
