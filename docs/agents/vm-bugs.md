# VM Phase 2 / Concurrency — Compiler Bugs and Gap Analysis

Discovered while attempting to land real `rt.spawnFiber`-backed
concurrency in `examples/minivm/_bc_runner.cht`'s `BG_SPAWN` handler.
Every bug observed in the VM's compiled code is, by definition, a bug
in the compiler that compiled it — this doc tracks each.

Regression tests: `spec/vm_bg_capture_bugs_spec.rb`.

---

## The dangling-pointer family (Bugs #2, #3, #6)

The original doc enumerated these as separate bugs. After careful
reproduction, **all three are the same root bug**: a borrow / shared
heap-pointer from a local scope escapes into an async `BG` fiber
without ownership transfer, and the outer scope's auto-generated
`defer` frees the backing before the fiber reads it.

### Reproducer #1 — direct slice borrow

```cht
FN work(xs: Int64[]) RETURNS Int64 -> RETURN xs.length(); END

FN runit() RETURNS Int64 ->
    MUTABLE lst: Int64[]@list = List[];
    lst.append(1_i64); lst.append(2_i64); lst.append(3_i64);
    slice: Int64[] = lst;         -- slice borrows lst's backing
    p: ~Int64 = BG {
        work(slice);               -- captured into async fiber
    };
    RETURN NEXT p;                 -- lst dies on scope exit
END
```

Observed: compiles clean; runtime assertion fails (fiber reads 0, not 3).

### Reproducer #2 — same pattern through a union variant

```cht
UNION V { Nil, IntV: Int64 }

FN consumeSlice(xs: V[]) RETURNS Int64 ->
    IF xs.length() > 0 THEN
        MATCH xs[0] START
            V.IntV AS i -> RETURN i;,
            DEFAULT -> RETURN 0_i64;
        END
    END
    RETURN 0_i64;
END

FN runit() RETURNS Int64 ->
    MUTABLE xsList: V[]@list = List[];
    xsList.append(V{ IntV: 42 });
    xsSlice: V[] = xsList;          -- borrow
    p: ~Int64 = BG {
        consumeSlice(xsSlice);
    };
    RETURN NEXT p;
END
```

Observed: compiles clean; `ASSERTION FAILED` at runtime (reads 0, not 42).

### Reproducer #3 — the VM's Phase 2 attempt

Inside `_bc_runner.cht`'s BG_SPAWN opcode handler:

```cht
MUTABLE bgCapsList: Value[]@list = List[];
FOR bi IN (0_i64 ..< bgArgc) DO
    bgCapsList.append(COPY stack[sp - bgArgc + bi]);
END
bgCaps: Value[] = bgCapsList;       -- slice borrow from @list
append(futures, BG {
    vmFiberRun!(ops, consts, bgEntry, bgCaps);   -- escapes
});
```

Observed: compiles clean; fiber reads empty captures (zero-length
slice → `slot[0] = Nil` → `0 + 1.0 = 1.0` instead of `7.0 + 1.0 = 8.0`
for the `58_bg.cht` test).

### Why all three are the same bug

Each emits the same MIR shape:
- An `AllocMark` + `Cleanup` for the owning `@list` local.
- An assignment creating a slice that shares the owner's heap buffer —
  **no marker node**.
- A `BgBlock` whose captures include that slice — **no marker node**
  pinning the borrow's lifetime to the fiber.

MIRChecker sees:
- AllocMark matched to Cleanup → INV #1, #2 satisfied.
- AllocMark matched to AllocMark → INV #3 satisfied.
- No other markers. Program accepted.

The slice borrow is invisible to MIRChecker. See the gap analysis
below for why.

---

## Bug #4: `COPY` at BG capture site → cryptic Zig error

**Status**: reproducible with the right context. Not an independent
root bug — it surfaces when `COPY` is applied to a union literal whose
field owns a heap container, and the result is captured into BG.

### Reproducer

```cht
UNION V { Nil, IntV: Int64, Vec: V[] }

FN consumeVec(v: V) RETURNS Int64 ->
    MATCH v START
        V.Vec AS items -> RETURN items.length();,
        DEFAULT -> RETURN 0_i64;
    END
    RETURN 0_i64;
END

FN runit() RETURNS Int64 ->
    MUTABLE xs: V[]@list = List[];
    xs.append(V{ IntV: 1 });
    vec: V = COPY V{ Vec: xs };     -- COPY of union literal with list field
    p: ~Int64 = BG { consumeVec(vec); };
    RETURN NEXT p;
END

FN main() RETURNS Void ->
    n: Int64 = runit();
    ASSERT n == 1, "COPY'd Value.Vec captured into BG";
END
```

Observed error at compile time:
```
._clear_tmp_bug4_vm.zig:89:81: error: expected type '*T', found 'T'
```

The diagnostic is a Zig-level type error with no CLEAR-level context.
The user sees a codegen-internal message, not a diagnostic pointing at
their source line.

### Why this matters

`COPY` in expression position should either:
- Produce a deep-copy of the expression result (the "natural" semantic),
  OR
- Be rejected at the CLEAR level with a clear message: "COPY requires
  an l-value binding; use `x: T = COPY source` or `x: T = source` and
  COPY at the point of use."

Currently it compiles the wrong Zig. This is a **lowering bug** — the
MIR lowering for `COPY E` doesn't correctly produce the deep-copy
shape when `E` is a union literal containing heap-owned fields. The
checker doesn't catch it because, again, the MIR looks internally
consistent — it just produces Zig that doesn't type-check.

---

## Gap analysis — Why MIRChecker doesn't catch the dangling-pointer family

This is the central question the rest of this doc needs to answer
cleanly. The claim from CLAUDE.md is that MIRChecker's seven invariants
should be sufficient. If a bug slips through, the gap is upstream (in
the lowering), not in the checker.

### What the checker can see

The checker operates on a stream of MIR marker nodes:
- `AllocMark(name, alloc)` — something got allocated.
- `Cleanup(name, entry)` / `ErrCleanup(name, entry)` — something
  should be freed on normal / error paths.
- `MoveMark(name)` — ownership transferred out; suppress the
  corresponding guarded `Cleanup`.
- `FrameSave` / `FrameRestore` — loop-iteration arena rewind points.
- `AllocMark` allocator symbols (`:heap` / `:frame` / `:cleanup`).

The seven invariants are relationships **between these markers**:
1. Every AllocMark ↔ Cleanup (or ErrCleanup).
2. Every Cleanup ↔ AllocMark.
3. Allocator symbols agree between paired marks.
4. Heap-returning calls in statement position must bind to a var.
5. InlineZig/RawZig with ownership effects must declare `stdlib_def`.
6. InlineZig allocator symbols match container's AllocMark.
7. Loop bodies with frame allocs must have `FrameRestore`.

### What the checker CANNOT see

**Anything the lowering doesn't emit a marker for.**

For reproducer #1 (slice borrow), the lowering emits:

```
AllocMark(lst, :heap)
Cleanup(lst, entry=...)        -- fires when runit() returns
-- slice = lst: no marker emitted (it's a borrow, no allocation)
BgBlock(captures={slice}, body=[...])    -- captures list is data,
                                          -- not a marker the checker audits
```

Walk the seven invariants:
- INV #1: AllocMark(lst) has Cleanup(lst). ✓
- INV #2: Cleanup(lst) has AllocMark(lst). ✓
- INV #3: allocators match. ✓
- INV #4–7: N/A.

**Every invariant passes.** The program is accepted.

### Can an existing invariant be made to fire?

Answer: **not without the lowering emitting additional markers**. The
checker's invariants are about marker relationships — it literally has
nothing to look at for the unsafe borrow escape, because the lowering
never generates a marker node pertaining to it.

This is the correct design: the checker should be *simple*. Its job is
to verify that markers agree with each other, not to re-do the
lowering's job of deciding what to mark.

### Two valid fixes — both in lowering

**Fix A — lowering refuses, no markers needed.**

`lower_bg_block` inspects each capture at lowering time:

```
for each capture (name, type) in node.captures:
    if type is borrow_like (slice of owned, @indirect, field-of-owner):
        if !explicitly_moved(source_owner) and !explicitly_copied(name):
            raise lowering_error:
              "Capture '{name}' borrows from '{owner}'; cannot escape
               into async BG fiber. Transfer ownership with `GIVE` at
               the BG site, or deep-copy with `COPY`."
```

This never produces MIR for the unsafe case. The checker never sees
it. No new invariant needed.

**Fix B — lowering emits markers, existing invariants fire.**

If the user writes `GIVE slice` at the BG site:
- Lowering emits `MoveMark(slice)` at the BG point, which implies
  `MoveMark(lst)` (the underlying owner).
- The outer `Cleanup(lst)` now has no live allocation to clean
  (`MoveMark` consumed it) → INV #2 (**orphan cleanup**) fires if the
  lowering emitted a `Cleanup` without recognizing the move.
- Properly: lowering marks the outer Cleanup as guarded by
  `lst_moved` so INV #1/#2 can verify the guarded path.

If the user writes `COPY slice` at the BG site:
- Lowering emits a fresh `AllocMark` inside the BG body (the deep
  copy is a new allocation owned by the fiber).
- A `Cleanup` inside the BG body closes the pair → INV #1/#2 satisfied.
- The original `slice`'s owner is untouched → outer `AllocMark/Cleanup`
  pair also intact.

If the user writes **neither**:
- Fix A above: lowering refuses with a CLEAR-level diagnostic.

Both paths keep the checker on seven invariants. The lowering bends.

### Why not a new invariant?

The user's directive: **MIRChecker stays simple; everything bends to
it**. Adding a "no-borrow-escapes-BG" invariant to the checker would:
- Require the checker to inspect `BgBlock.captures` and cross-reference
  with ownership info — a brand-new class of analysis.
- Conflate "emit correct markers" (lowering's job) with "verify markers
  are consistent" (checker's job).
- Set a precedent for adding invariants every time the lowering grows
  a new construct (concurrent, streaming, ffi, …).

Keeping the checker fixed forces discipline in the lowering: any
operation that has ownership implications must either emit markers
the existing seven can act on, or refuse at lowering time.

---

## Current bug list

| # | Status | Root cause |
|---|---|---|
| Bug #1 | **FIXED** (`6de9a874`) — regression test | BG ctx field type wrong for slice fn-params |
| Dangling-pointer family (#2/#3/#6) | **OPEN** | Borrow escapes async BG; lowering emits no markers; checker has nothing to fire on |
| Bug #4 | **OPEN** | `COPY` in expression position on union literals with heap-owned fields generates bad Zig |

## Fix priorities (for the VM specifically)

1. **Dangling-pointer family** — Fix A (lowering refuses at BG
   capture): unblocks safety. Phase 2 VM concurrency is still blocked
   without Fix B, but at least the silent UAF stops.

2. **`COPY` expr-position lowering** — bug in how COPY rewrites union
   literals with heap fields. Either implement deep-copy codegen
   correctly, or refuse the pattern at CLEAR level.

3. **Phase 2 design completion** — give users a way to say "move this
   heap-owned capture into the BG fiber". Options:
   - Capture-site `GIVE x` syntax: `append(futures, BG (GIVE x) { ... })`.
   - `@multiowned` / `@shared` containers passed into BG directly
     (already works, but not what the VM needs for short-lived captures).
   - Implicit move for captures (violates "zero implicit copies").

## Regression spec structure

`spec/vm_bg_capture_bugs_spec.rb` currently holds:
- Positive regression for Bug #1 (verifies `6de9a874` stays in).
- Negative regression for the dangling-pointer family (asserts the
  current broken behavior; flip when Fix A lands).

When fixes land, the specs flip from "assert broken" to "assert
diagnostic" or "assert correct runtime result".

---

## Register VM: guest frame-arena lifetime not modeled (frame_peak / loop-arena cluster)

Discovered 2026-05-16 during Phase 0 gate stabilization on the
`register-machine` branch.

**Not a CLEAR compiler bug.** Native CLEAR compiles and runs all
affected tests correctly (`./clear run transpile-tests/66_list_loop_arena.cht`
exits 0). This is a `register_bc_emitter.rb` / `vm.cht` runner design
gap.

### Symptom

6 allowlist tests ERROR (silent corruption, not honest PENDING):

| Test | Panic |
|------|-------|
| `66_list_loop_arena` | `index out of bounds: index 0xAAAA..., len 358` in `flist0.append` -> `ensureTotalCapacityPrecise` |
| `189_string_concat_loop_growth` | General protection exception (no address) |
| `190_frame_peak_string_loop` | (arena accounting) |
| `197_frame_peak_nested_while_server` | `integer does not fit in destination type` |
| `200_frame_peak_large_alloc_loop` | `integer overflow` |
| `205_frame_peak_list_build_in_fn` | General protection exception (no address) |

### Root cause

- The guest's per-iteration frame rewind ops are **no-ops** in the
  register emitter:
  - `MIR::FrameSave` / `MIR::FrameRestore` -> `nil`
    (`register_bc_emitter.rb:628-630`).
  - `rt.saveLoopMark` / `rt.restoreLoopMark` detected by
    `runtime_loop_mark?` / `runtime_loop_mark_restore?` and skipped
    (`register_bc_emitter.rb:533-534`).
- But guest frame-allocated collections (`vals: Float64[]@list`) are
  still emitted as LFNEW/LFAPPEND that allocate on the **runner's
  real** `rt.frameAlloc()` arena (`vm.cht` dispatch).
- A guest loop that frame-allocates per iteration therefore
  **accumulates unbounded memory in the runner's arena** instead of
  being rewound each iteration. The runner's arena overflows; the
  ArrayList struct (`flist0`) is corrupted (`items.len` reads the
  `0xAAAA...` Zig undefined poison) and faults.
- `framePeakBytes()` (native id 16) returns the **runner's** arena
  peak, not the guest's simulated arena, so the `frame_peak`
  assertions are measuring the wrong thing even when they don't
  crash.

### Invariant violated

README "Core Design Principle" / `register-vm.md` "Semantic
Invariants": *"Any operation not yet supported in the bytecode path
should error NOT_SUPPORTED, not fall back to a shadow
implementation."* No-oping the guest's frame-rewind contract while
still frame-allocating is a semantically-different shortcut that
silently corrupts.

### Fix options (not yet done — acked, deferred)

1. **Faithful (correct, large):** model a guest frame arena distinct
   from the runner's. Guest LNEW/LFAPPEND allocate from a
   VM-maintained guest arena; `saveLoopMark`/`restoreLoopMark` and
   `FrameSave`/`FrameRestore` actually save/rewind that guest arena;
   `framePeakBytes()` reports the guest arena's peak.
2. **Honest (small, invariant-aligned):** detect guest programs that
   depend on per-iteration frame rewind (loop body frame-allocates a
   collection while runtime loop marks are present) or call
   `framePeakBytes()`, and raise `Unsupported` -> PENDING instead of
   emitting silently-corrupting code. Risk: must be scoped precisely
   so it does not flip currently-passing tests to PENDING.

Status: **OPEN (root cause), symptom currently MASKED.** As of the
error-union VM foundation commit, the 6 tests pass: adding error-state
locals to `runRegisterBytecode` enlarged its frame, `--stack-check`
rebuilt at a larger stack tier, and the arena corruption no longer
manifests within these tests' iteration counts. This is incidental,
not a fix -- the guest frame arena is still unmodeled, so a heavier
guest loop (more iterations / larger per-iteration alloc) would still
corrupt, and the masking can regress if the function frame shrinks.
The faithful fix (option 1: model a guest arena distinct from the
runner's) remains the correct resolution. Do not treat the green
state as closure.

---

## Compiler: control_flow.scan_direct sig rejects nil sub-bodies

Found 2026-05-18 while replicating the stack VM's fibers into the
register VM (BGSPAWN + EFFECTS REENTRANT in vm.cht).

### Symptom

Compiler crash (not a user diagnostic):
`Parameter 'body': Expected type T::Array[T.untyped], got type
NilClass (TypeError)` at `src/mir/control_flow.rb:1641`
(`ControlFlow.scan_direct`), reached via `collect_local_names`.

### Root cause

`scan_direct(body)` recurses into `s.else_branch` (IfStatement),
`s.default_case` (MatchStatement), `s.body` (WithBlock), `b[:body]`
(DoBlock) — all of which are **legitimately nil** (an IF without
ELSE, a MATCH without DEFAULT, etc.). The method body's first line
is `return unless body.is_a?(Array)` — i.e. it is *designed* to
tolerate nil. But the Sorbet `sig` declared
`params(body: T::Array[T.untyped], ...)`, which Sorbet validates at
the call boundary **before** the method runs, so it aborts on the
nil recursion before the intended guard executes.

Latent: only fires on code paths where `collect_local_names` /
`scan_direct` traverses an IF-without-ELSE (or MATCH-without-DEFAULT)
under the effect/reentrancy analysis — exposed here by adding
`EFFECTS REENTRANT` + a BG block containing an `IF ... THEN ... END`
(no ELSE) to `vm.cht`.

### Fix (applied)

`src/mir/control_flow.rb`: sig changed to
`params(body: T.nilable(T::Array[T.untyped]), ...)`. The existing
`return unless body.is_a?(Array)` guard is the intended handling;
the sig now matches the method's real contract. Minimal,
architecturally-correct (no new logic — aligns the type with
existing behavior). Status: **FIXED**.

---

## Bug #7 (FIXED 2026-05-18): COPY of an `@list` fn-param captured into BG

Found 2026-05-18 while faithfully re-reproducing the R2 fiber
blocker (post the scan_direct/pipeline_rewriter compiler fix). The
direct `@list`-parameter sibling of Bug #1 (which fixed only the
slice-param case).

### Minimal reproduction

```cht
FN consume(xs: Int64[]@list) RETURNS Int64 -> RETURN xs.length(); END
FN runit(ops: Int64[]@list) RETURNS !Int64 ->
    p: ~Int64 = BG { consume(COPY ops); };
    RETURN NEXT p;
END
```

Generated Zig: `error: expected type '*T', found '*const T'`,
`note: T = array_list.Aligned(i64,null)`.

### Isolation matrix (all verified)

| capture                         | result |
|---------------------------------|--------|
| COPY local @list  -> in BG      | OK     |
| COPY slice param  -> in BG      | OK (Bug #1 fix) |
| COPY @list param  -> NO BG      | OK     |
| **COPY @list param -> in BG**   | **FAILS** |

### Root cause (pinpointed, one line)

`src/mir/fiber_ctx_builder.rb` ~L127, the `FreshHeapCopy` (COPY)
branch:

```ruby
dupe_decl = "const #{dupe_var} = try CheatLib.dupeValue(@TypeOf(#{source_ref}), #{source_ref}, ...)"
CaptureSpec.new(name, "@TypeOf(#{source_ref})", dupe_var, ...)
                       # ^^ ctx FIELD TYPE = type of the SOURCE
                       #    but the field STORES `dupe_var` (the
                       #    deep-copied owned value).
```

For a *local* @list or a *slice* param, `@TypeOf(source_ref) ~=
@TypeOf(dupe_var)`, so it works (that is why Bug #1's slice-param
fix appeared complete). For an `@list` **parameter**, `source_ref`
is a borrowed `*const ArrayList(T)`, so the ctx field is declared
`*const ArrayList` while it actually holds an owned dupe ->
`*T` vs `*const T` mismatch in the fiber body / forwarded call.

### Architecturally-correct fix (applied, NOT a band-aid, NOT vm.cht-side)

The ctx field type must describe **the value the field holds** (the
deep-copied owned value), not the borrowed source it was copied
from. Single-source-of-truth fix so the field type and the dupe's
return type can never diverge:

1. **`zig/runtime/runtime-header.zig`** -- new comptime
   `CheatLib.CapturedValue(S)` and `CheatLib.dupeCaptured(S, src,
   alloc)`. `CapturedValue(S)` returns the OWNED value the fiber
   holds; `dupeCaptured` is `dupeValue` that derefs-then-deep-copies
   for that case. The strip is scoped to a **`*const T` single-item
   pointer ONLY** -- that is precisely a CLEAR *borrow* (an immutable
   param passed by pointer). A NON-const `*T` is an owned heap box
   (`*Locked(T)` from `lockedCreate`, Arc, Box) whose pointer shape
   the body+cleanup pipeline (`dupeValue` + `lockedDestroy(...,c)`)
   relies on -- it must pass through unchanged. (The `is_const`
   guard was added after the broader-strip first cut regressed the
   `stream_into_boundary` `@locked`-local cell:
   `lockedDestroy` got `Locked(T)` instead of `*Locked(T)`.)
2. **`src/mir/fiber_ctx_builder.rb`** FreshHeapCopy branch -- ctx
   `field_type_zig` and the dupe both go through
   `CheatLib.CapturedValue(@TypeOf(src))` / `dupeCaptured` (the
   owned type, not a `*const` alias of the source).
3. **`src/mir/mir_pass.rb`** `insert_bg_escape_promote!` -- skip the
   in-place `promoteList(&x)` for *parameters* (borrowed/caller-owned;
   the COPY strategy already deep-copies them, and an in-place
   promote of a `*const` param is itself a `*T`/`*const T` error).

Verified EXHAUSTIVELY: prspec 4802/0, transpile-tests 554/554 (0
leak), fuzz matrix incl `bg_capture_typing` 145/145 (0 fail/leak),
register allowlist 245/245, `zig build test` 0-fail (incl new
`cleanup-test.zig` CapturedValue/dupeCaptured unit tests).
Regression-locked by `tools/fuzz/templates/bg_capture_typing.rb`
(`:int` x {local,param} x {bare_list,struct_field}).

Unblocks the stack-VM fiber replication (R2-R6):
`runRegisterBytecode!`'s `@list` params (`sourceLines` etc.) are
exactly this shape.

Regression: `spec/vm_bg_capture_bugs_spec.rb` "Bug #7 (FIXED)" --
now asserts `ok == true` (compiles AND runs).

## Bug #8 (OPEN): bare `String[]@list` COPY'd into a BG fiber double-frees

Found 2026-05-18, exposed only once Bug #7's compile error was
removed (before that, the program never built far enough to run).
Distinct from Bug #7: that was ctx-field *typing*; this is a
cleanup-*ownership* double-free of the element strings.

### Symptom

A bare `String[]@list` (NOT int-element, NOT struct-wrapped)
captured by `COPY` into a `BG { ... }` -- for BOTH a local and a
fn-param origin -- double-frees its element strings under the
leak-detecting allocator (`./clear test`). With int elements or a
struct-with-`@list`-field wrapper the same shapes are clean, so the
fault is specific to the duped list's owned `[]const u8` payloads
being freed by both the in-fiber `defer cleanup` and the
pre-spawn `errdefer`/outer recipe.

### Why not asserted in the spec

`spec/vm_bg_capture_bugs_spec.rb`'s `compile_and_run` helper uses
the C allocator (no double-free detection). It reproduces under
`./clear test` (std.testing.allocator). Documented there as a
comment block, no assertion.

### Scope / fix-forward

`tools/fuzz/templates/bg_capture_typing.rb` is currently scoped to
`elem = :int` for exactly this reason. When Bug #8 is fixed (its
own standalone bug-fix commit), re-enable the `:string` cells in
that template -- they become the regression lock.
