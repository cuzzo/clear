# Pipeline result placement: full extent report

Status: IMPLEMENTATION IN PROGRESS (2026-07-24).
- DONE 82a9e5fb2: B1/B2 stream selector ownership (the accepted segfault) —
  push is an ownership transfer; downstream cell N2 removed, positive
  coverage in transpile-tests/649 + stream_selector_matrix fuzz cells.
- DONE (this commit): A2 loop-scope stamping parity — the stamper now walks
  exactly the checker traversal, so value-position pipeline BlockExprs inside
  loops are stamped; 106 matrix cells flipped and were RUNTIME-VERIFIED clean
  by a full sweep of every transpile-clean cell against a pre-fix baseline
  (60 runtime failures exist in BOTH: pre-existing; 3 current-only are
  unmaskings of the pre-existing unnest-literal invalid-Zig bug; 3 baseline
  failures were FIXED by the stream commit).
- NEW INSTRUMENT (this commit): the matrix RUNTIME register (integration
  lane) — every transpile-clean cell is leak-checked; 63 accepted-but-broken
  cells registered, incl. `RETURN <borrowed-element pipeline>` invalid frees
  and broad if_cond/terminal_join leaks. Remaining fixes: A1 double-copy
  (perf, runtime-safe), A3/A4 placement fact (covers the ret invalid frees),
  A5 unnest lifecycle, B3-B10.

## Instruments (checked in, both bidirectionally strict)

1. `compiler/spec/pipeline_position_matrix_spec.rb` — 389 generated cells:
   every pipeline op x every consuming position x element ownership (Int64 /
   owned String / composite struct) x source kind (borrowed param / owned call
   result) x context (top, IF, FOR, WHILE, MATCH-in-FOR) + stream cells +
   scalar (REDUCE/SUM/JOIN) cells. In-process MIR-check, ~36s. KNOWN_FAILURES
   register: 158 entries; a fixed cell still listed FAILS, a new broken cell
   FAILS. Re-map: `MATRIX_REPORT=1 bundle exec rspec <file>`.
2. `compiler/spec/pipeline_downstream_register_spec.rb` (:integration) — the 6
   ACCEPTED-but-broken shapes (clean transpile, then invalid Zig or runtime
   crash) that no compile-level check can see. Same two-way strictness.

## Failure classes — complete map (158 matrix + 6 downstream cells)

### A. One architectural root: pipeline result placement + element transfer
   is decided piecemeal by surrounding context, not once by the pipeline.

| Class | Cells | Evidence |
|---|---|---|
| A1 FRAME_NO_REWIND, owned elements | ~55 | `SELECT dup(_)` (or composite / nested-pipe element) fails in EVERY frame-result position; passes at heap terminals (join) and streaming EACH. With a frame destination the owned element is owned-sink-materialized (heap->frame) BEFORE lower_select sees it, then deep-copied AGAIN (two copies per element); transients unrewound. At heap terminals the pre-wrap doesn't fire and the MOVE path is clean |
| A2 FRAME_NO_REWIND, pipeline-in-loop | ~47 | ANY list pipeline bound to a local inside FOR / WHILE / MATCH-arm-in-FOR — even Int64. Emission verified SAFE (loop mark present, per-iter cleanup); the loop-scope stamping pass does not descend pipeline BlockExprs, so their AllocMarks keep non-:iteration scope and the checker (correctly, per its contract) rejects. Same descend-value-BlockExpr family as the fixed REDUCE bug (7c86bfbc4) |
| A3 FRAME_ALLOC_ESCAPES | 19 | Borrowed-element pipeline (frame result) into TAKES param / struct field. Fail-closed correct; the result needed heap placement at declaration (INV-5) |
| A4 OWNED_RESULT_ALLOC_MISMATCH | 8 | RETURN of owned-element pipeline: return hoist says :frame, pipeline marks :heap — two deciders, no shared fact |
| A5 CLEANUP_REQUIRED / ALLOC_WITHOUT_CLEANUP / OWNERSHIP_UNVERIFIED | 11 | Owned UNNEST inner list `unn_inner` (and nested-pipe variants) is a per-element transient no cleanup pass owns (original self-host G3 error) |

ORDER_BY is the existence proof for the fix: it heap-allocates its result and
passes every position including in-loop and TAKES/field.

### B. Independent frontend/codegen bugs (each its own fix)

| Class | Cells | Severity |
|---|---|---|
| B1 stream SELECT owned selector, unfused NEXT consumer | downstream N2 | **ACCEPTED + SEGFAULT (invalid free)** — memory-unsafe program passes the verifier. Highest severity in the entire map |
| B2 stream SELECT owned selector, fused EACH | 1 (matrix) | OWNED_RETURN_WITHOUT_ALLOC — fail-closed sibling of B1: same missing owned-selector lifecycle, caught only in the fused shape |
| B3 WINDOW with heap-returning per-window fn | downstream N3 | accepted -> invalid Zig (`__bw_batch` undeclared; owned call hoisted above batch scope). Same hoist-scoping family as fixed cb64c7bed |
| B4 pipeline inside lambda body | downstream N4 | accepted -> invalid Zig (source prelude hoisted outside the lambda; param `ys` undeclared) |
| B5 BG STREAM inside TEST THAT | downstream N6 | accepted -> invalid Zig (`gen` undeclared in test body) |
| B6 any fiber spawn (BG/CONCURRENT) inside TEST THAT | downstream N7 | runtime GPF (`scheduler.zig` ensureChannel — test-runner thread has no scheduler) |
| B7 SKIP/LIMIT (+chains) `\|> EACH` | 5 (matrix) | compiler CRASH (`undefined method 'token' for nil`) — EACH desugar hands lowering a BlockExpr with nil result; even the error path crashes |
| B8 ORDER_BY `\|> EACH` | 2 (matrix) | `lower_smooth: unsupported EachOp` raise |
| B9 `SELECT COPY _ \|> <op>` | 3 (matrix) | parse precedence: COPY swallows the pipe (parenthesized form works). Fail-closed wart |
| B10 materializing binding chains | downstream N8 | unsupported, but diagnosed with the misleading "Undefined pipeline binding" instead of the intended "not supported in AS $v chains" |

## Verified SOLID (green everywhere — the negatives that bound the extent)

- Scalar pipelines: REDUCE (incl. owned String acc, incl. in FOR/WHILE), SUM,
  JOIN — all 20 positions.
- Plain FOR/WHILE loops with owned call temps (`t = dup(e)`), incl. EACH-block
  bodies: correct rewind, leak-free.
- ORDER_BY and DISTINCT list/set results in all their positions.
- CONCURRENT with owned String results, incl. bound inside loops: transpile +
  leak-checked runtime PASS.
- BG bodies: the in-loop pipeline hole does NOT reproduce inside BG (CPS/FSM
  path frames correctly).
- Owned call results as pipeline SOURCES (`mk() |> ...`): source cleanup is
  correct in every position.

## The architecturally sound solution (determined, not yet implemented)

**Core (fixes all of A):** make the pipeline the single decider of its result
placement and element transfer, as one fact computed at lowering start:

1. `PipelineHost` computes a `PipelineResultPlacement` fact = {result_alloc,
   element_transfer} ONCE per pipeline site, from (a) the destination stamped
   by escape analysis (return / TAKES arg / field store / container store ->
   heap; provably-local -> frame) and (b) element ownership (owned-producing
   selector vs borrow). This kills the expression-level owned-sink pre-wrap
   that causes the double copy (A1): with the fact in hand, the element is
   transferred exactly once — MOVE when same-allocator, one deep-copy when
   crossing. ORDER_BY's behavior generalized, but destination-aware instead of
   always-heap.
2. Per-element transients (freed heap originals, `unn_inner` inner lists,
   fallback temps) get the pipeline's OWN loop mark + per-iteration rewind and
   a cleanup owned by the pipeline loop (A5).
3. The loop-scope stamping pass descends pipeline BlockExprs (and MATCH arms)
   so their AllocMarks carry :iteration scope relative to the enclosing loop
   (A2) — checker unchanged; its rejections are all correct today.
4. Escape analysis treats a pipeline fed to TAKES/field/return as an escaping
   declaration site (A3/A4), setting the destination the placement fact reads.

**B-class fixes, priority order:**
- B1/B2 first (soundness): the stream owned-selector lifecycle — the fused
  checker rejection and the unfused SEGFAULT share the missing "selector
  result is owned by the consumer" transfer; fixing the lifecycle closes both.
- B6 (test-runner scheduler init) — unblocks using BG/CONCURRENT in TEST
  blocks at all; B5 rides the same TEST-lowering surface.
- B3/B4 (hoist scoping at batch/lambda boundaries — extend the cb64c7bed
  head-capture approach to WINDOW batches and lambda bodies).
- B7 (nil-result EACH desugar: emit a diagnostic, or support the fusion), B8,
  B10 (diagnostics), B9 (parser precedence decision — likely document + keep).

**Checker: zero changes.** Every checker rejection in the map was verified
correct (fail-closed) or the stamping's fault; the two accepted-unsafe cases
(B1, B3/B4/B5's zig failures) need new FACTS (stream selector lifecycle;
hoist boundaries), not weaker checks.

## Sequencing (each a standalone commit, each deleting register entries)

1. B1/B2 stream owned-selector lifecycle (soundness first).
2. A2+A5 stamping/descend + unnest transient lifecycle (biggest register cut,
   lowest risk — no placement change).
3. A1/A3/A4 placement fact + single element transfer (the core).
4. B6/B5, then B3/B4, then B7/B8/B10/B9.

Every step: delete the fixed cells from the registers (the specs force this),
add runtime fuzz cells for newly-green owned-element positions
(tools/fuzz/templates/), full validation per CLAUDE.md.

## Full-space exploration verdict (2026-07-24, second sweep)

Instruments now in the tree (all bidirectionally strict, all green):
1. Pipeline position matrix — 389 cells x compile + runtime lanes.
2. Ownership-surface matrix — 133 cells, EXACT-VALUE oracles, compile +
   runtime lanes: kinds (owned/concat String, built list, struct, nested
   struct, union w/ String variant, {String}String, @multiowned, @shared) x
   ops (decl+read, reassign, GIVE->TAKES, COPY independence, return, element/
   field store) x contexts (top/IF/FOR/WHILE/CONTINUE/BREAK).
3. Differential lane — 9 pipeline-vs-hand-loop pairs, identical exact asserts.
4. Downstream register — 5 accepted-but-broken codegen cells.
5. 44 targeted probes (error paths, RAISE-mid-loop, BREAK/CONTINUE, unions,
   optionals, maps w/ owned keys, nested lists, sets, pools, COPY deep-ness,
   FREEZE, sharded/locked handles, 100-element stress) -> 10 uncovered-but-
   passing shapes installed as transpile-tests 650-659.

RESULT: zero new runtime bugs outside the already-registered pipeline
classes. The core ownership model (annotate -> escape -> classify -> lower ->
check) is SOUND under exact-value adversarial testing. Two by-design
conservative rejections documented (GIVE out of an optional capture; GIVE of
a borrowed map read — COPY is the sanctioned escape). One type-level wart
(element-index optionality is position-dependent).

## The architectural solution, refined by the full map

Every remaining defect (31 compile + 64 runtime + 5 downstream cells) lives in
ONE seam: SYNTHETIC VALUE PRODUCERS that bypass the declaration-centric
ownership pipeline the invariants were built around. The rewriter's
accumulators, the hoister's temps, the pipeline lowerers' res_lists, and the
codegen-boundary hoists each hand-stamp a SUBSET of the binding facts a real
declaration gets — and every bug in the map is one forgotten fact: a missing
storage stamp, an unshared SymbolEntry, a dropped was_moved, an unstamped
scope, an absent lifecycle, a rodata provenance lost. Every fix landed this
session was exactly "thread the missing fact".

Therefore the solution is NOT more per-site patches but ONE protocol:

1. A single synthetic-binding constructor (used by PipelineRewriter, Hoist,
   and the pipeline lowerers) that takes {name, type, destination, init} and
   produces decl + SymbolEntry + storage/provenance + lifecycle + scope stamps
   COHERENTLY — the same facts a real declaration carries, so every downstream
   pass (escape, classify, finalize, check) sees a first-class binding.
   Registered classes it retires: A3 stragglers, A5 unnest transients, the
   rodata-literal-arg cleanup (ret runtime class), if_cond/terminal_join leaks.
2. Boundary-aware hoisting: pending statements must never cross a scope the
   hoister cannot see (lambda body, WINDOW batch block, TEST THAT body) —
   extend the cb64c7bed head-capture discipline to those three boundaries
   (retires B3, B4, B5).
3. EACH desugar completeness: SKIP/LIMIT/ORDER_BY |> EACH routes through the
   materializing path or emits a diagnostic — never a nil-result BlockExpr
   (retires B7 crash, B8).
4. Runtime: scheduler init for the Zig test-runner thread (retires B6, the
   TEST-block GPF).
5. Diagnostics: B9 parse precedence + B10 binding-chain message.

The registers gate the work: each step must delete its cells or it hasn't
fixed the class.

## Status (2026-07-24): matrix burn-down COMPLETE

Both matrix registers are EMPTY: all 389 cells transpile clean AND run
leak/crash-free under the testing allocator (compile lane + runtime lane both
green; full sweep 389/389). The fixes landed where the facts live, not at the
symptoms:

- rt/needs-runtime: `ProgramMIRFinalizer.ast_node_lowers_through_runtime?`
  recognizes materializing smooth pipelines; visit_Smooth records effects at
  dispatch level.
- ORDER_BY string keys: `MIR::Sort#string_keys` stamp (INV-7: emitter reads
  the stamp, no type inspection) -> `std.mem.order(u8, a, b) == .lt`.
- Cross-allocator element transfer (INV-10): `append_owned_value_stmt` copies
  an owned value into the destination allocator and frees the source when
  the value's allocator differs from the receiver's.
- DISTINCT ownership: `Set.insert` OWNS its value (frees duplicates); borrowed
  keys are now copied into the set's allocator with the full owned-transfer
  shape; the set's allocator comes from placement (was hardcoded :heap).
- Returned-pipeline escape facts: identifier collection for escape sinks
  descends a value-block through its RESULT only; a materializing pipeline's
  sources never escape; parameters are never heap-marked by a return (the
  cascade fabricated heap cleanups on caller literal-argument hoists).
- Composite-field destinations: StructLit fields thread `@dest_storage=:heap`
  (sound now that element transfer is allocator-coherent).
- UNNEST literal sources: loop sources are lowered outside coercion position;
  the pipeline placeholder rewriter substitutes inside ListLit items.
- Value-wrapper parse precedence: COPY/MOVE/... operands parse at the ambient
  minimum precedence, so a wrapper inside a stage stops before `|>` while the
  statement-level `COPY xs |> ...` meaning is unchanged.
- Per-iteration rewind (FRAME_OVERFLOW): pipelines whose SELECT element
  allocates frame transients per iteration are stamped :heap by the annotator;
  pipeline_alloc/sink_alloc READ the stamp (INV-16); lower_select emits
  explicit AllocMark + block-result transfer facts plus
  saveLoopMark/restoreLoopMark — rewind is emitted ONLY when the result is
  heap (rewind around frame-moved elements would be a UAF; the checker's
  FRAME_NO_REWIND rejection remains the fail-closed guard).

Remaining tracked work lives in the downstream register spec (WINDOW batch
hoist, lambda hoist, BG STREAM in TEST, BG/CONCURRENT TEST GPF, binding-chain
diagnostic) and the self-host G4 `__tmp_445` hoist-boundary blocker.
