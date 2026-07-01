# VM Phase 2 / Concurrency — Compiler Bugs and Gap Analysis

Discovered while attempting to land real `rt.spawnFiber`-backed
concurrency in `examples/minivm/_bc_runner.clear`'s `BG_SPAWN` handler.
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

```clear
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

```clear
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

Inside `_bc_runner.clear`'s BG_SPAWN opcode handler:

```clear
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
for the `58_bg.clear` test).

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

```clear
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
affected tests correctly (`./clear run transpile-tests/66_list_loop_arena.clear`
exits 0). This is a `register_bc_emitter.rb` / `vm.clear` runner design
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
  real** `rt.frameAlloc()` arena (`vm.clear` dispatch).
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
register VM (BGSPAWN + EFFECTS REENTRANT in vm.clear).

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
(no ELSE) to `vm.clear`.

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

```clear
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

### Architecturally-correct fix (applied, NOT a band-aid, NOT vm.clear-side)

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

## Bug #8 (FIXED): bare `String[]@list` COPY'd into a BG fiber double-frees

**FIXED 2026-05-18** (architectural Step C -- make COPY-depth agree
with cleanup-depth via the canonical predicates). Root: a `COPY` of
a `String[]@list` lowered to `:list_shallow` (`@memcpy` of the
`[]const u8` element *handles*) because the depth was read from the
narrow annotator `node.deep_copy` flag (set only for
union-with-heap), NOT from whether the element owns heap. The
list's cleanup recipe deep-frees each element string, so the
shallow copy aliased the source's strings and both cleanups freed
them ("Second free"). Two coordinated canonical-isations:
1. `mir_lowering lower_copy`: depth decided by
   `!elem_type.implicitly_copyable?(schema_lookup)` -- the SAME
   canonical predicate the Copy/cleanup machinery uses everywhere
   (String/list/map/union-with-heap/struct-with-owned -> deep;
   Int64/... -> cheap shallow memcpy, no owned payload).
2. `mir_emitter emit_deep_copy` `:list_deep`: per-element copy via
   the canonical recursive `CheatLib.dupeValue` (which *delegates*
   to `dupeUnionValue` for unions -> regression-safe, but also
   correctly deep-copies string/list/struct elements that
   `dupeUnionValue` alone no-op'd).
The COPY now owns independent element payloads; its cleanup and the
source's target disjoint memory. Regression:
`transpile-tests/531_bgcopy_string_list_element_ownership.clear`
(leak-checked) + the re-enabled `:string` cells of
`tools/fuzz/templates/bg_capture_typing.rb`.

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

## Compiler: discard placeholder `_` emitted as a Zig identifier

Found 2026-05-18 while running the faithful post-Bug#7 reentrant
register-VM probe (`docs/agents/stack-vm-fiber-replication.md`).

### Symptom

`_ = <owned/cleanup-bearing expr>;` (an `AST::BindExpr` decl with
`name == "_"` -- e.g. `_ = makeList() OR RAISE;`, `_ = NEXT fut;`)
lowered to literal Zig:

```zig
const _ = try make(rt); _ = _;
defer CheatLib.cleanup(RegisterValue, rt.heapAlloc(), &_);
```

`error: '_' used as an identifier without @"_" syntax`. Zig forbids
`_` as a bindable name; the discarded owned value also still needs
its cleanup (no leak).

Second facet: two `_ = ...;` discards in one scope -- the annotator
saw the second as a *reassignment* of the first (immutable) `_` and
raised `Variable '_' is immutable`.

### Root cause

`_` is the discard sink, never a real binding, but it flowed
through as an ordinary name in two places:

1. `src/mir/mir_lowering.rb` `lower_var_decl`: `safe_name =
   zig_safe_name(node.name)` returned literal `_`, threaded into
   `MIR::Let`/`AllocMark`/`Cleanup`/suppression.
2. `src/annotator.rb` `visit_BindExpr`: `_` was registered as a
   scope local, so the next `_ =` hit the immutable-reassign branch.

### Fix (applied, single chokepoint each)

1. `lower_var_decl`: when `node.name == "_"`, emit a unique
   `__discard_<n>` (via the existing `@tmp_counter` convention)
   instead of `zig_safe_name`. `binding_entry` stays keyed by the
   original `_`, so the cleanup recipe (no-leak) is preserved -- only
   the emitted Zig name changes, consistently across decl + cleanup.
2. `visit_BindExpr`: `_` always takes the declaration path
   (`|| node.name == "_"`); every `_ =` is an independent discard,
   never a reassignment.

Type-agnostic (owned `@list`, struct-with-`@list`-field, `NEXT`
future all verified). Regression: `transpile-tests/527_discard_
owned_value.clear` (multi-discard, leak-checked). Verified: prspec
4802/0, transpile-tests 555/555 (0 leak), fuzz matrix 145/145
(0 fail/leak), register allowlist 245/245.

## Compiler: nested-@list-field append allocator not inherited from root container

Found 2026-05-18, faithfully reproduced from the register-VM
de-TIGHT P0 (`stack-vm-fiber-replication.md`). Minimal repro
(`transpile-tests/528_nested_list_loop_rewind.clear`):

```clear
STRUCT Handle { values: Int64[]@list }
FN run(n: Int64) RETURNS !Int64 ->
    MUTABLE handles: Handle[]@list = List[];
    MUTABLE i: Int64 = 0_i64;
    WHILE i < n DO                       # non-TIGHT
        MUTABLE scratch: Int64[]@list = List[];   # per-iter frame alloc
        scratch.append(i);
        handles.append(Handle{ values: [] });
        handles[i].values.append(scratch[0]);     # nested-field append
        i = i + 1_i64;
    END
    ...
```

`./clear build`: `[INLINE_ALLOC_MISMATCH] run::handles --
operation uses :frame but container 'handles' is :heap`.

### Trigger matrix (all verified)

| carrier | loop | frame-alloc body | result |
|---|---|---|---|
| plain `Int64[]@list` | non-tight | yes | OK |
| nested-`@list` struct `H[]@list` | **TIGHT** | yes | OK |
| nested-`@list` struct `H[]@list` | non-tight | **no** | OK |
| single struct `H` (not `@list`) nested-`@list` | non-tight | yes | OK |
| **`H[]@list` (nested `@list`)** | **non-tight** | **yes** | **MISMATCH** |
| same, FOR instead of WHILE | non-tight | yes | MISMATCH |

### Root cause (pinpointed via pipeline probe)

The non-tight loop's per-iteration `saveLoopMark/restoreLoopMark`
(mir_lowering `lower_while`/for) makes escape analysis promote the
loop-spanning container `handles` to `:heap` (decl `node.storage`
and `symbol.reg.storage` both `:heap` -- correct). The DIRECT
append `handles.append(...)` correctly resolves `:heap` (its
receiver is the Identifier `handles`, `symbol.reg.storage == :heap`).

The NESTED-field append `handles[i].values.append(x)` does NOT.
`mir_lowering.rb resolve_alloc_sym(:receiver_storage, ...)`
resolves the op allocator from the *immediate receiver*
`handles[i].values` -- a `GetField`/`GetIndex` chain whose
`type_info.provenance` is nil and which has no `symbol`/`reg` --
so every `needs_heap` signal misses and it resolves `:frame`. But
`mir_checker` attributes the op to the ROOT container via
`extract_root_var_name(node.object)` -> `handles` (AllocMark
`:heap`). Checker and resolver disagree on the subject: checker
walks to the root, resolver looks only at the leaf receiver. Plain
`Int64[]@list` (no nested field) never hits this because there is
no nested-field append. TIGHT / no-frame-alloc keep the root
`:frame` so leaf `:frame` coincidentally matches.

### Architecturally-correct fix (applied)

`resolve_alloc_sym` must resolve a nested-collection-field
mutation's allocator from the SAME root the checker attributes it
to. When the receiver is a `GetField`/`GetIndex` chain, descend to
the root Identifier (mirroring `extract_root_var_name`) and consult
ITS declaration storage. The root's storage is the single source of
truth (INV-16); a nested `@list` living inside a heap-allocated
container element is itself heap-backed, so `:heap` is correct.
This unifies the allocator-resolution root with the checker's
attribution root -- not a per-condition band-aid.

Regression: `transpile-tests/528_nested_list_loop_rewind.clear`;
fuzz axis added to `tools/fuzz/templates/loop_carry_collection.rb`
(see post-mortem).

## Language inconsistency: REENTRANT:THUNK / :TAIL_CALL blocked in TIGHT loops

**FIXED 2026-05-18** (architectural Step A -- collapse a divergent
proxy onto the canonical field). `effects.rb validate_tight_node!`
now keys on `fn.reentrance_kind == :reentrant` (the canonical
"UNBOUNDED native stack" property) instead of the coarse legacy
`fn.reentrant == :reentrant` proxy that reentrance.rb back-fills
for `:thunk`/`:tail_call` too. The gate no longer consults the
proxy; bounded-native-stack recursion (`:thunk`, `:tail_call`,
and the already-permitted `:max_depth`/`:not_logical`) is allowed
in TIGHT loops. Net complexity reduction: one fewer place that
re-derives "is this recursion bounded". Regression:
`transpile-tests/529_tailcall_reentrant_in_tight_loop.clear`
(compile+run) and `spec/error_emission_coverage_spec.rb`
":TIGHT_CALLS_REENTRANT_FN" (unit: plain :reentrant still blocked;
:TAIL_CALL/:THUNK permitted -- load-bearing, fails pre-fix).

Found 2026-05-18 while unblocking register-VM R3.

`effects.rb validate_tight_node!` blocks a call inside a TIGHT loop
iff `fn.reentrant == :reentrant`. `reentrance.rb` maps the reentrant
variants to `fn.reentrant` as:

| variant | fn.reentrant | TIGHT-loop call |
|---|---|---|
| `:reentrant` (plain) | `:reentrant` | blocked (correct: unbounded) |
| `:reentrant_thunk` | `:reentrant` | **blocked (inconsistent)** |
| `:reentrant_tail_call` | `:reentrant` | **blocked (inconsistent)** |
| `:reentrant_not_logical` | `:non_reentrant` | allowed |
| `:reentrant_max_depth` | `:non_reentrant` | allowed |

The TIGHT block's stated rationale is "unbounded depth"
(`TIGHT_CALLS_REENTRANT_FN` summary). But:

- `:THUNK` is a CPS + heap trampoline: the *native* stack is
  provably bounded (continuations are heap-resident). It is
  arguably the MOST TIGHT-safe recursion form -- strictly safer
  than `:MAX_DEPTH(N)`, which still consumes N real stack frames
  yet is allowed.
- `:TAIL_CALL` is a verified self-loop (constant native stack) --
  also bounded.
- TIGHT already permits heap allocation (it merely skips the
  per-iteration arena mark/restore; boundedness comes from the
  loop's termination proof) and permits nested TIGHT loops
  (`validate_tight_node!` just walks the subtree; bounded x bounded
  composes). By that same termination/bounded-stack logic, a
  bounded-stack recursion (`:THUNK`, `:TAIL_CALL`) has no reason to
  be blocked when `:MAX_DEPTH` is not.

Root cause: `reentrance.rb` lumps `:reentrant_thunk` /
`:reentrant_tail_call` under `fn_node.reentrant ||= :reentrant`
(legacy-compat bucket) together with unbounded plain `:reentrant`.
The TIGHT gate keys on that coarse field instead of on
"unbounded native stack". Architecturally-correct fix: the TIGHT
gate should block only *unbounded-native-stack* recursion -- i.e.
plain `:reentrant` (and `:reentrant` reached via mutual cycle) --
and permit `:reentrant_thunk` / `:reentrant_tail_call` exactly as
it permits `:reentrant_max_depth` / `:reentrant_not_logical`. Most
direct: gate on `reentrance_kind`/`tight_reentrance`, not on the
legacy `fn.reentrant == :reentrant` proxy.

Not blocking R3 (which uses `:MAX_DEPTH(N)`), so filed rather than
fixed inline; a standalone bug-fix should re-key the gate and add a
`:THUNK`/`:TAIL_CALL`-in-TIGHT-loop regression test.

## Compiler: COPY of an @list PARAM into a BG deep-copies via unguarded `.items`

**FIXED 2026-05-18** (architectural Step B -- collapse N divergent
backing accessors onto the one canonical resilient one). Root:
`mir_lowering lower_copy` built the list deep-copy source as
`MIR::ItemsAccess.new(source, false)` -- the UNGUARDED `.items`
variant, which assumes the source is statically an ArrayList. A
captured `@list` param is a slice `[]i64` in the BG ctx (and a
pointer-passed one is `*const ArrayList`), so bare `.items` was a
hard Zig error. Fix: `MIR::ItemsAccess.new(source, true)` -- the
ONE canonical comptime `@hasField(@TypeOf(x),"items")` dispatch
every other backing access already uses (ArrayList -> `.items`,
slice -> `[0..]`, `*const ArrayList` -> `.*.items`), zero runtime
cost. The deep-copy no longer re-derives "this is an ArrayList".
Regression: `transpile-tests/530_bgcopy_list_param_reentrant.clear`
(compile+run) + fuzz `tools/fuzz/templates/bg_copy_param_reentrant.rb`
(re-enabled: `CALLEES = [:reentrant]`). Unblocks register-VM R3
Step 3.

Found 2026-05-18 wiring register-VM R3 (the BGSPAWN dispatch arm
does `BG { runRegisterBytecode!(..., COPY sourceLines, ...) }`
where `sourceLines: Int64[]@list` is a parameter). Blocks R3 Step 3.

### Minimal reproduction (~18 lines, transpile-tests-shaped)

```clear
FN consume(xs: Int64[]@list) RETURNS Int64 -> RETURN xs.length(); END
FN worker!(sl: Int64[]@list, depth: Int64) RETURNS !Int64 EFFECTS REENTRANT:MAX_DEPTH(8) ->
    IF depth <= 0_i64 THEN RETURN consume(sl); END
    f: ~Int64 = BG { @service -> worker!(COPY sl, depth - 1_i64) OR RAISE; };
    RETURN NEXT f;
END
FN main() RETURNS !Void ->
    MUTABLE xs: Int64[]@list = List[];
    xs.append(1_i64); xs.append(2_i64); xs.append(3_i64);
    n: Int64 = worker!(GIVE xs, 2_i64) OR RAISE;
    ASSERT n == 3_i64, "reentrant BG COPY @list param";
END
```

`./clear build`: `error: no member named 'items' in '[]i64'`.

### Root cause (codegen sites, side by side)

For `sl: Int64[]@list` captured into the BG ctx, the ctx field is
a slice `[]i64`. Two generated sites:

- A NORMAL use (`consume(sl)`) emits the comptime-resilient form:
  `if (@hasField(@TypeOf(__x), "items")) __x.items else
  @constCast(__x[0..])` -- handles ArrayList AND slice.
- The COPY-into-BG deep-copy emits, UNGUARDED:
  `const __src = __ctx_0.sl.items;` -- assumes ArrayList; `[]i64`
  has no `.items` -> hard Zig error.

So the FreshHeapCopy / list-COPY deep-copy lowering hard-codes the
ArrayList `.items` shape instead of the `@hasField("items")`
comptime dispatch every other `@list` access uses. Distinct from
Bug #7 (ctx-field `*const T` vs `T` typing) and the
nested-@list-root bug: this is the COPY *body* assuming a
container shape the captured slice doesn't have.

### Architecturally-correct fix (direction)

The list-COPY-into-BG deep-copy must use the same comptime
`@hasField(@TypeOf(x), "items")` resilient access the normal
`@list` read path uses (one source of truth for "@list value ->
backing slice"), OR the captured-@list-param ctx field must carry
the owned ArrayList type so `.items` is valid (extend Bug #7's
CapturedValue/dupeCaptured to the slice-represented @list-param
case). Likely the former (single resilient accessor). Standalone
bug-fix: reproduce-test + root-cause in the FreshHeapCopy /
list-COPY lowering + post-mortem the coverage gap (the
bg_capture_typing fuzz template covers COPY @list param into BG
but its callee is non-reentrant and the param is consumed
directly, not deep-copied through the reentrant-call ctx -- the
exact axis combination here was unsampled).

R3 Step 3 (BGSPAWN/FNEXT runtime, saved /tmp/r3_step3.patch) is
structurally complete and reverted-pending this fix; not hacked
around in vm.clear.

## TODO (architectural debt, no open bug): collapse the FiberCtxBuilder parallel capture system

A/B/C collapsed three divergent re-derivations and killed Bug #7,
the `.items` codegen bug, and Bug #8 (all regression-locked). The
remaining "Step D" from the /plan is pure debt, not a live bug:

`FiberCtxBuilder` emits BG/DO/CONCURRENT captures as raw Zig string
fragments (`dupe_decl_zig` = `dupeCaptured` + `errdefer cleanup`;
`body_cleanup_zig` = in-body `defer cleanup`) spliced into
hand-written templates at 5 callsites (mir_lowering x2,
pipeline_host x3) + fsm_transform. MIRChecker (INV-12) cannot see
inside it. The capture cleanup is synthesized at the destination
instead of inherited from the source binding's CleanupClassifier
recipe (INV-14), and the ctx field type is `CapturedValue(@TypeOf
(source))` instead of the declaration's storage stamp (INV-16).

Collapse: convert `CaptureSpec` to carry MIR `Cleanup`/`ErrCleanup`
inherited from the source recipe and a declaration-stamped type;
migrate the 5 callsites string->MIR one at a time behind the green
gate; prove MIRChecker covers the dupe; then delete
`CheatLib.CapturedValue` / `dupeCaptured` (single caller) and the
FreshHeapCopy fork. No correctness fire forces this; own workstream.

## RESOLVED (R6): register VM lock contention is now genuine

Superseded. R6 made the register-VM lock real:
- R6.2/R6.3: single-i64-field @shared:locked structs are backed by
  shared store cells with a real per-cell spin-flag lock
  (LOCKACQ/LOCKREL, 100ms fallible timeout, RETRY) in vm.clear,
  ported verbatim from _bc_runner.clear's LOCK_ACQUIRE/LOCK_RELEASE.
- R6.4: a @shared:locked capture marshals its cell index (kind
  :cell); the BG runs as a REAL fiber (BGSPAWN) sharing the cell by
  id, for both scalar-return and void-payload bodies.

Consequence: 263_with_lock_contention now compiles to 2 real fibers
(holder + waiter); the waiter genuinely fails to acquire within
100ms while the holder holds the lock for 300ms, so its
`ON LockTimeout` action fires and `ASSERT timed_out == 1` is a real
contention assertion (it would FAIL, not pass vacuously, if the BGs
regressed to inline). 267/280/281 likewise run as real fibers
(BGSPAWN 2/4/6). 262/367 have no BG by design (single-threaded
selector-codegen / rt-threading regression tests) and are correct
as-is.

Regression lock: spec/register_shared_cell_spec.rb asserts
263_with_lock_contention emits >= 2 BGSPAWN, so a silent revert to
the inline (vacuous) path is caught at emit time, not just by the
runtime assertion. Concurrency battery rationale: see the R6.5
section above.

Register-VM lock/atomic/contention tests ARE now trustworthy as
concurrency coverage to the extent of the differential parity with
the stack VM (262/263/267/280/281/367 pass identically on both).

## R6 design (corrected): register-VM shared cap-wrapped store

Earlier note said R6 should "start by un-deferring Step D". That
is WRONG: Step D is the Zig-backend FiberCtxBuilder collapse,
orthogonal to the register VM. The register VM has its own capture
machinery (the :fiber emitter + vm.clear pendingCaps/captureSlots).

Real root: the register VM has NO shared cap-wrapped store. The
stack VM threads one `pool: Env[N]@pool:shared:locked` as an
exec! PARAMETER (passed by shared-Arc ref into every spawned
exec!, never copied) -- that single Arc<Locked<>> is where all
cross-fiber guest state lives. runRegisterBytecode!'s params
(ops..entryIp, initCaps) have no analogue; @shared:locked Counter
is field-decomposed to scalar regs (single-threaded fake).
Marshaling such a capture through the scalar pendingCaps COPY
would give each fiber its own copy -> no sharing -> the lock is
meaningless.

R6 first step = DESIGN the shared store, modeled on stack VM:
- Add a shared cap-wrapped store threaded through every recursive
  runRegisterBytecode! spawn by reference (analogue of `pool`):
  a real `T@shared:locked` (or an Arc<Locked<RegisterValue[]>>
  handle table) param, GIVEN/forwarded into BGSPAWN's recursive
  call alongside ops/initCaps -- NOT deep-copied.
- A @shared:locked guest value becomes a handle into that store;
  WITH EXCLUSIVE acquires the real Locked; captures pass the
  handle (shared), not a scalar copy.
- Then real lock-timeout + ON LockTimeout, atomics.
- MANDATORY (CLAUDE.md): hammer + loom + VOPR, TSan/ASan,
  std.testing.allocator green before integration.

This is a dedicated multi-commit workstream gated on that design;
no bounded slice meaningfully advances it. The :fiber scalar
fiber path (R5, landed) stays the foundation.

## Pre-existing: nested_field_append_allocator_spec flaky under prspec

`spec/nested_field_append_allocator_spec.rb:74` and `:89` fail under
`bundle exec prspec spec/` (parallel) but pass in isolation
(`bundle exec rspec spec/nested_field_append_allocator_spec.rb` -> 3/3).
Reproduces on a clean tree at the R6.2a commit (2f106c1d) with all
later changes stashed, so it is order/parallel-worker dependent and
predates R6.2b. Likely a shared-state leak between specs sharing a
MIRLowering/global registry under parallel workers. Not yet root-caused.

## R6.5 concurrency battery rationale (register-VM lock)

R6 added a guest-level per-cell spin-flag lock (LOCKACQ/LOCKREL +
SCELL store cells) implemented entirely in CLEAR in
`examples/minivm/vm.clear`, layered on top of the EXISTING, already-
loom/hammer/VOPR-validated host `CheatLib.Locked` and the existing
cooperative fiber scheduler (`BG { @service }` / `NEXT`). No new
`zig/runtime/` atomic, lock, thread, or FFI primitive was introduced
(only `vm.clear` CLEAR + the Ruby register emitter changed).

Battery decision:

- **Hammer (REQUIRED, delivered):** transpile-test 535 — 3 real BG
  fibers each RMW a shared `@shared:locked` counter, holding the
  per-cell lock across a yield (`napFor` inside `WITH EXCLUSIVE`), so
  contenders must spin-wait rather than interleave. A lost/torn
  update fails the `== 15` assert. Plus 534 (basic 2-fiber shared
  RMW). Both run under the standard transpile-test pipeline.
- **Loom (N/A):** the register VM runs cooperative fibers on a single
  OS thread; there is no instruction-reordering / multicore memory-
  visibility surface to exhaust. The only memory barrier is the host
  `CheatLib.Locked`, which already has its own loom coverage. R6
  introduced no new atomics or ordering.
- **VOPR (covered by deterministic differential):** the cooperative
  scheduler is deterministic given fixed sleeps; 535 was verified
  stable across repeated runs. Timeout/retry combinatorics are
  covered deterministically by 262/263/267 (fixed sleep vs fixed
  100ms lock timeout). No real-time/network/disk randomness exists
  in this path, so a seeded simulator adds nothing over the fixed-
  parameter deterministic tests.

Load-bearing correctness evidence: differential parity — the
contention/timeout/retry allowlist tests (262/263/267/280/281/367)
pass identically on the register VM and the stack VM, whose lock
mechanism R6.3 ports verbatim.
