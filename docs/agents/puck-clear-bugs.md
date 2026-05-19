# Puck-on-CLEAR — Compiler Bugs and Friction

Bugs and rough edges discovered while building `examples/puck/vm.cht`
(a CLEAR-language port of `v10/vm.c`). Every entry below was reproduced
from a small piece of the VM during the same session, and every one is
worked around in `vm.cht` so the file compiles today.

Minimal reproducers live in
[`transpile-tests/known-failing/`](../../transpile-tests/known-failing/).
They are deliberately kept out of `transpile-tests/gen.rb`'s glob so the
standard CI run isn't blocked; when a bug is fixed, move its reproducer
up into `transpile-tests/<NNN>_<name>.cht` to make the fix gate.

See also [`puck-clear-retrospective.md`](puck-clear-retrospective.md) for
the post-mortem on how these slipped through to this stage.

## Status

| # | Bug | State |
| --- | --- | --- |
| 1 | Lifted temp emitted after its use site | ✅ FIXED (promoted) |
| 2 | FRAME_NO_REWIND on plain WHILE loops that allocate | ✅ FIXED (promoted) |
| 3 | Effect inference: `charAt(i) OR ""` makes caller fallible (alloc⇄fail conflation) | ✅ FIXED (promoted) |
| 4–7 | — | removed (working as designed) |
| 8 | `splitOnce` flagged fallible because it touches `parts[1]` | ⬜ open |
| 9 | `ByteCode[]@list` field in struct in `@list` clobbered across iters | ✅ FIXED (promoted) |
| 10 | Error-union return over `@list` mis-lowers (`*const anyerror!T`) | ⬜ open (naive fix leaks → reverted; needs #13) |
| 11 | `expr OR <fallback>` over a *user* callee doesn't reset `can_fail` | ✅ FIXED (channel-termination authority) |
| 12 | Bare arena op (`split`/concat/`makeList`/`append`) in plain fn emits `try` | ⬜ open (found via #3 gate; runtime-side) |
| 13 | `@list` returned across an error-union boundary leaks at caller | ⬜ open (found via #3 gate) |

Bugs #11, #12, #13 were discovered this session by the exhaustive
`tools/fuzz/templates/infallible_signature.rb` gate — latent defects the
#3 over-rejection had been masking. #10 was found earlier by the same
gate. None are regressions; each is a distinct root cause.

---

## 1. Lifted temp emitted AFTER its use site (hoisting bug)

Affects `cht` source of the shape:

```cht
IF (someFallible(args) OR fallback) != "literal" THEN
  RAISE "...";
END
```

CLEAR's hoisting pass lifts the `OR fallback` expression into an anonymous
local (`__tmp_N`), but emits the `const __tmp_N = ...` line **inside** the
`if` body — after the `if` condition has already referenced the name:

```zig
// CLR:151
if (!CheatLib.eql(__tmp_2, "STRINGS")) {      // uses __tmp_2 here
const __tmp_2 = (firstToken(rt, CheatLib.getAt(lines, 1)) catch "");
defer rt.heapAlloc().free(__tmp_2);
```

Zig rejects this:

```
._clear_tmp_vm.zig:476:19: error: use of undeclared identifier '__tmp_2'
```

**Workaround**: bind the lifted expression to a named local first.

```cht
strHeader = firstToken(lines[1]) OR "";
IF strHeader != "STRINGS" THEN RAISE "vm: missing STRINGS header"; END
```

**Suspected root cause**: `MIRPass.hoist_heap_temps!` placing the
`MIR::Alloc` / `Let` in the inner block's scope when the temp is only
*referenced* by the condition expression that introduces the inner block.
The hoist target should be the parent block, not the body.

---

## 2. FRAME_NO_REWIND on plain WHILE loops that allocate

A `WHILE` loop whose body computes any String- or struct-shaped temporary
(via `.split(" ")`, struct literal, or a method call returning an owning
container) trips:

```
MIR ownership verification failed (post-lowering):
[FRAME_NO_REWIND] loadProgram::loadProgram --
  loop body frame-allocates but has no restoreLoopMark defer
```

The MIR rule (CLAUDE.md, invariant #6) is documented and correct in
spirit, but the per-iteration `restoreLoopMark` defer is not auto-inserted
for the common loop-with-temps shape. `examples/minivm/_bc_runner.cht`
sidesteps this by allocating every transient into a long-lived
`Env[N]@pool` rather than the frame; ordinary user code without that
infrastructure is stuck.

**Workaround**: hoist every transient out of the loop body into a
`MUTABLE` declared above the loop, so the loop body only ever
**re-assigns**, never **allocates**:

```cht
MUTABLE head: String = "";
MUTABLE tail: String = "";
WHILE i < codesLen DO
  head = firstToken(lines[pos]) OR "";
  tail = tailAfterFirstSpace(lines[pos]) OR "";
  ...
END
```

This shifts the (re)allocation cost outside the iteration mark window.
It also forces the user to enumerate every transient up front, which
defeats the readability win of locally-scoped names.

**Suggested fix**: `EscapeAnalysis` could detect the
"local-to-iteration, no use after `END`" pattern and synthesise an
implicit `restoreLoopMark` defer for it. The MIR check currently only
runs the verification, never the synthesis.

---

## 3. Effect inference treats `foo.charAt(i) OR ""` as making the
caller fallible

A `String.charAt(i) OR fallback` expression is *not* fallible — the `OR`
swallows the option. But CLEAR's effect inference still propagates a
`can_fail` to the enclosing function, forcing every caller up the chain
to add `OR <action>` or change its return type to `!T`.

Concrete reproducer (this should compile with `RETURNS Int64`):

```cht
FN codepointOf(c: String) RETURNS Int64 ->
  ascii = " ABC";
  MUTABLE i = 0;
  WHILE i < ascii.length() DO
    ch = ascii.charAt(i) OR "";          # OR consumed the failure
    IF ch == c THEN RETURN 32 + i; END
    i += 1;
  END
  RETURN 63;
END
```

Error:

```
Function 'codepointOf' can fail (raises directly via RAISE) but its
return type doesn't declare it. Change `RETURNS Int64` to `RETURNS !Int64`
```

**Workaround**: change every such function's return type to `!T` and
add `OR <fallback>` at every call site. The cascade is invasive — a
single `charAt` deep in the call stack forces ~half the file's
signatures to flip.

**Suspected root cause**: `effects.rb`'s `can_fail` propagation
treating any `OR <expr>` over a fallible expression as still fallible
when it should be reset to "infallible" by the `OR` consumer.

**FIXED** (register-machine branch). Real root cause was narrower and
different from the suspicion: `annotator.rb:779` conflated "genuinely
raises" with "allocates / needs the runtime" in the single
`@fn_raises_directly` flag (`uses_frame || uses_heap || uses_alloc ||
heap_ret || ...`). Every string-touching function was therefore seeded
`can_fail`. Fix = de-conflate: `@fn_raises_directly` is now genuine
failure only (`scan_for_raises` + PRE + `@nonReentrant` + fn-pointer);
the alloc terms were redundant for their real consumer `needs_rt`
(which already ORs them independently). `scan_for_raises` also now
recognizes `BgBlock`/`BgStreamBlock` (they emit a real `try
spawnNew`), and `compute_can_fail!` gained an explicit
declared-`RETURNS !T` axis (the most authoritative failure signal,
previously masked by the alloc proxy). Regression-gated by
`tools/fuzz/templates/infallible_signature.rb` and promoted to
`transpile-tests/or_fallback_doesnt_propagate_fallibility.cht`.

The exhaustive gate surfaced three residual latent defects the
over-rejection had been masking — see #11, #12, #13. The canonical
reproducer (charAt OR-absorbed, no bare arena op) is fully fixed; the
residuals are distinct bugs with their own root causes.

---

> **Entries #4–#7 removed.** They were CLEAR working as designed
> (zero-implicit-copy on container-index → struct-field stores, the
> borrow→move restriction on two-step `@list` pop, the mutate-and-
> write-back-across-index rule, and exclusive-mutability aliasing).
> Friction for a C-port author, but not compiler bugs and nothing is
> owed back. Numbering of the remaining real bugs (#8, #9) is left
> unchanged so existing references (forensics, mutants, fuzz READMEs,
> `transpile-tests/known-failing/bug{8,9}_*`) stay valid.

---


## 8. `splitOnce` flagged as fallible because it touches `parts[1]`

A pure function that does `parts = line.split(" "); parts[1]` is
inferred as `can_fail`, requiring `!T` and `OR <action>` at every
call site:

```cht
FN splitOnce(line: String) RETURNS String[] ->     # rejected
  parts = line.split(" ");
  ...
  RETURN [parts[0], parts[1]];
END
```

```
Function 'splitOnce' can fail (raises directly via RAISE) but its
return type doesn't declare it.
```

The function does not `RAISE` anywhere. The inferred fallibility comes
from indexed access on a List being implicitly fallible at the type
level. Same root cause as #3.

---

## 9. `ByteCode[]@list` field inside a struct stored in another `@list`
gets clobbered across outer-loop iterations

Reproducer — the canonical "load a Program out of a binary file" loop:

```cht
STRUCT Procedure { params: Int64, codes: ByteCode[]@list }
STRUCT Program   { procs: Procedure[]@list }

WHILE p < procCount DO
  ...
  MUTABLE codes: ByteCode[]@list = [];
  WHILE i < codesLen DO
    codes.append(ByteCode{ op: ..., arg: ... });
    i += 1;
  END
  procs.append(Procedure{ params: params, codes: codes });
  # ↑ procs[p].codes[0] is the right value here
  p += 1;
END
# ↓ but here, procs[0].codes[0] is garbage (uninitialised memory pattern,
#   e.g. op=0, arg=-6148914691236517206)
```

Tracing with `print()` calls shows the right values immediately after
each `procs.append(...)`, but by the time the outer loop finishes the
first proc's `codes` list has been overwritten — presumably because
the inner `MUTABLE codes: ByteCode[]@list = [];` re-declaration shares
storage across iterations rather than producing a fresh list.

**Workaround**: don't put a `@list` inside a struct that itself lives
in a `@list`. Replace the per-proc `codes` field with
`(opStart, opCount)` indices into a single program-wide flat
`ByteCode[]@list`. Then the only `@list` in the picture is the flat
one, owned by `Program`, and no nested-list aliasing can happen.

```cht
STRUCT Procedure { params: Int64, opStart: Int64, opCount: Int64 }
STRUCT Program   {
  procs:  Procedure[]@list,
  allOps: ByteCode[]@list
}
```

This is what `vm.cht` does today. The C/Go/Rust ports won't have to.

---

## 10. Error-union return over a `@list` mis-lowers (`*const anyerror!T`)

A function that *correctly* declares an error union over a list return
type fails Zig codegen:

```cht
FN build(a: String) RETURNS !Int64[]@list ->
  RETURN [1_i64];
END
```

```
error: expected type '*const T', found '*const anyerror!T'
note: pointer type child 'anyerror!array_list.Aligned(i64,null)'
      cannot cast into pointer type child 'array_list.Aligned(i64,null)'
```

The list return temp keeps its `anyerror!array_list...` wrapper instead
of being unwrapped before the heap-promotion/return path takes its
address. Only the `error-union + @list-return` combination is affected;
`!Int64`, `!String`, and a plain `Int64[]@list` return all lower fine.

This is independent of #3 (which is the *annotator* wrongly forcing
`!T`); #10 is the *codegen* path for a return type the author declared
on purpose. The `infallible_signature` fuzz template marks every
`heap_list + error_union` cell `:in_dev` so it reserves matrix space
without masking the #3 signal; flip those cells to `:pass` once #10 is
fixed.

**Workaround**: return the list through an out-param or a wrapping
struct, or make the function infallible (no error union) when it
returns a `@list`.

**STILL OPEN.** An attempted fix (stamp the return value's
`coerced_type` with the payload type instead of the error union)
*does* make it compile, but the returned `@list` then LEAKS at the
caller (DebugAllocator catches it) — trading a compile error for an
INV-2 violation, which is strictly worse. The naive coerce-strip was
reverted. A correct fix must also pair caller-side cleanup for a
`@list` returned across an error-union boundary — see #13.

---

## 11. `expr OR <fallback>` over a user callee doesn't reset can_fail

The residual half of #3. With the alloc-conflation fixed, a function
whose ONLY fallibility is a user callee absorbed by `OR <value>` is
still forced to `!T`:

```cht
FN flaky(s: String) RETURNS !String -> ... END
FN sub(a: String) RETURNS String ->
  h = flaky(a) OR "fallback";   # error consumed -> sub is infallible
  RETURN COPY h;
END
```

`compute_can_fail!`'s transitive propagation walks `@call_graph`, a
callee-NAME set, and cannot see that the callsite is OR-absorbed, so
`flaky.can_fail` flows into `sub`. The builtin variant (`charAt(i) OR
""`) is unaffected because stdlib callees aren't in `@call_graph` —
that is why #3's canonical reproducer passes while this doesn't.

**Root cause**: per-callsite absorption is known only at the annotator
OR-RESCUE site; the shared `@call_graph` (also feeding `needs_rt` /
reentrance, which need every callee regardless of absorption) can't
carry it.

**FIXED.** `scan_for_calls` now returns a third set, `unabsorbed` —
the callees whose error channel is NOT locally terminated. Threading
an `absorbed` flag through the AST walk, the `.left` of an
`OR_RESCUE` whose rhs does not re-propagate (anything but
`OrRaise`/`OrExit`/`OR RETURN`/`OR EXIT`-expr) is marked absorbed.
`@fn_propagating_callees` stores this per fn and is the SINGLE
authority `compute_can_fail!` propagates over; `@call_graph` is
unchanged (reentrancy/needs_rt still see every callee). This is the
"channel terminates here" fact owned in one place and read, not
re-derived from the callee-name proxy. Conservative: an unrecognized
rhs counts as propagating, so the fix never wrongly marks a fallible
fn infallible. The `fallible_callee_absorbed` gate cells are live
again (scalar/heap_string pass; heap_list still `:in_dev` under #12,
the orthogonal arena-op `try`).

---

## 12. Bare arena-allocating op in a plain (non-error) fn emits `try`

Exposed by #3's de-conflation (was masked because #3 rejected these at
the annotator before codegen):

```cht
FN f(a: String) RETURNS Int64 ->
  parts = a.split(" ");   # -> `const __tmp = try CheatLib.split(...)`
  RETURN 7_i64;
END
```

`CheatLib.split` / `std.mem.concat` / `CheatLib.makeList` / list
`append` are declared fallible (`error{OutOfMemory}`), so a bare
unabsorbed use lowers to `try CheatLib.<op>` — illegal in a plain
non-error fn (`error: expected type 'i64', found 'error{OutOfMemory}'`).
Per the #3 thesis these arena ops bump-allocate and panic on OOM, so
they should be infallible (no `try`); the real fix is runtime-side
(drop the error union from the arena CheatLib op signatures), not in
the annotator. The #3 alloc-conflation was effectively a band-aid for
exactly this codegen reality ("it allocates, so force `!T` so the
`try` is legal").

Gated `:in_dev` in `infallible_signature.rb`
(`alloc_concat`/`alloc_split`/`alloc_list_build` + plain, and any
heap-`@list` return).

---

## 13. `@list` returned across an error-union boundary leaks at the caller

Found while attempting #10. `FN f() RETURNS !Int64[]@list -> RETURN
[1_i64]; END` with `r = f() OR RAISE;` compiles (under the attempted
#10 coerce-strip) and asserts correctly, but the returned list is
never freed at the caller — `[DebugAllocator] memory ... leaked`
(array_list backing buffer). The success-path ownership of a `@list`
handed back through an error union isn't paired with a caller-side
`Cleanup`. This is why the #10 coerce-strip is not a safe fix on its
own. Distinct from #10 (codegen cast) and #12 (`try` in plain fn).

**Root cause identified (verified by tracing):** the same channel-vs-
value conflation, this time at the `Type` layer. The parser stamps
`@collection`/storage on the OUTER error-union type; `Type#payload_type`
rebuilds the payload from the bare raw symbol (`@payload_type_raw`) and
DROPS those stamps (`!Int64[]@list` → payload `Int64[]`, collection
lost). Three derived sites then fail to see the heap collection:
  1. `EscapeAnalysis.return_expr_is_heap?` keys off AST shape
     (FuncCall/Identifier/GetField) and misses literal returns
     (`RETURN [1_i64]`), so the fn never enters `heap_fns`.
  2. `EscapeAnalysis.tag_transitive_provenance!` (E3a) matches only
     `val.is_a?(FuncCall)`, so `r = f() OR RAISE` (an OR_RESCUE) never
     gets heap provenance → no caller cleanup.
  3. A contract-level check on `fn.return_type` also fails because
     `payload_type` lost `@collection`.

An attempted multi-point fix (look through OR_RESCUE in E3a; key E1
off the declared contract reading collection-ness from the OUTER type;
payload-strip coerced_type for #10) made b13/b10b pass with zero leak,
BUT broadening `heap_fns` introduced a **double-free + allocator-
alignment mismatch** in `527_discard_owned_value` (`_ = mkList() OR
RAISE` — the new caller cleanup collides with the existing
discard/GIVE-move cleanup path). Reverted: a double-free is strictly
worse than the original leak.

**The correct single-source fix is `Type#payload_type` itself
carrying the outer `@collection`/storage/sync stamps** (the annotator
already hand-carries them at one site, annotator.rb ~186 — proof the
loss is known). That removes the root for all three derived sites at
once, but it is high-blast-radius (every `payload_type` caller) and
must be its own dedicated, fully-validated change with the cleanup-
machinery double-free interaction worked out — NOT bundled with #3/#11.

---

## Summary

These bugs / friction points combined mean a faithful port of v10/vm.c
(stack-machine bytecode interpreter with refcounted heap and union
values) is several times the LOC of the C original, with the extra
weight coming entirely from CLEAR-imposed workarounds rather than from
the language's normal cost.

The pragmatic choice for `vm.cht` today is:

- Restrict the value type to bare `Int64` (sidesteps the now-removed
  by-design friction around unions/heap entirely).
- Hoist every loop-local out of the body (works around #2).
- Add `OR ""` / `OR 0` everywhere a string or int helper appears
  (works around #3 and #8).
- Bind every "`condition` over a fallible expression" to a named local
  (works around #1).

That subset runs an integer-only `.puckc` (e.g. `fib(35)` with no
`SYSCALL 1` on a string). Adding strings and arrays back is gated on
fixes for #1, #2, and #3/#8 (the real bugs); the rest was by-design.
