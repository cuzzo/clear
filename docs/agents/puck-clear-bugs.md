# Puck-on-CLEAR — Compiler Bugs and Friction

Bugs and rough edges discovered while building `examples/puck/vm.cht`
(a CLEAR-language port of `v10/vm.c`). Every entry below was reproduced
from a small piece of the VM during the same session, and every one is
worked around in `vm.cht` so the file compiles today.

Regression tests are deferred until the workarounds collapse into proper
fixes.

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

---

## 4. Ownership of struct-field stores requires explicit `COPY` from
`@list` index

Reading a String out of a `String[]@list` via `list[i]` and storing it
into a struct field on the same line fails:

```cht
strings.append(lines[pos]);
```

```
Cannot pass container index access to TAKES parameter. Index access
returns a borrow. Use .remove(i) to take ownership, or COPY to
deep-copy.
```

**Workaround**: write `strings.append(COPY lines[pos])`. Same issue
for `Value{ StrVal: lines[i] }` style struct literals (needs
`Value{ StrVal: COPY lines[i] }`).

**Note**: this is documented behaviour per CLAUDE.md ("Zero implicit
copies. All copies of non-Copy types must be explicit"), not a bug.
It's listed here because it's the friction a port from C hits first —
the same pattern in v10 is just `strings[strings_len++] = lines[pos]`
with no ceremony.

---

## 5. Two-step pop on `@list` rejects the borrow→move pattern

Stack-machine code naturally writes:

```cht
v = stack[stack.length() - 1];
stack.pop();
useThe(v);
```

This is rejected:

```
Cannot move borrowed value 'v'. Parameters are implicit borrows
unless TAKES.
```

`stack[stack.length() - 1]` is a borrow; storing it into `v` (which
then needs ownership semantics to feed something else) doesn't work.

**Workaround**: `stack.pop()` returns an `Optional` that *does*
transfer ownership, so use:

```cht
v = stack.pop() OR <default>;
useThe(v);
```

This is fine for `Int64` stacks (the default is `0_i64`) but forces a
sentinel for any user-defined type and changes the meaning of "empty
stack" from a controllable error into a silent fallback.

---

## 6. `vm.heap[id] = HeapEntry{ refs: ..., cells: cells }` rejected
when `cells` came from `vm.heap[id].cells`

The classic "mutate-and-write-back" pattern is forbidden across an
index access:

```cht
MUTABLE cells = vm.heap[id].cells;
cells[idx] = newVal;
vm.heap[id] = HeapEntry{ refs: vm.heap[id].refs, cells: cells };
```

```
Cannot store borrowed value 'cells' into HeapEntry.cells. Use COPY for
an explicit deep-copy.
```

Both `MUTABLE cells = vm.heap[id].cells` (borrow) and
`HeapEntry{ ..., cells: cells }` (move into owning field) are
individually fine; the combination is rejected.

The chained ArraySet that would side-step it
(`vm.heap[id].cells[idx] = newVal`) is also rejected — CLEAR's
ArraySet only accepts a bare identifier on the left, not a
`name.field` or `name[i]` prefix. (Same restriction holds in Puck
itself, which is fine, but in CLEAR it forces a copy-out / copy-back
of the whole cells list.)

**Workaround**: redesign the heap so cells are owned by a separate
mutable container the VM keeps a long-lived reference to. The
two-level-array shape v10/vm.c uses (HeapEntry → cells pointer) does
not translate cleanly.

---

## 7. Aliasing rejected for `f!(MUTABLE vm, vm.heap[id].cells[idx])`

```cht
stack.append(heapRetain!(vm, vm.heap[id].cells[idx]));
```

```
Aliasing Error: Argument 2 ('vm') conflicts with argument 1. Cannot
pass the same variable defined at 'vm' twice if one usage is MUTABLE.
This violates exclusive mutability.
```

Even though the second occurrence is a read-only borrow into `vm`,
having `MUTABLE vm` as one argument and any expression rooted at `vm`
as another is rejected.

**Workaround**: bind the inner expression to a local first.

```cht
inner = vm.heap[id].cells[idx];
stack.append(heapRetain!(vm, inner));
```

This is documented CLEAR behaviour for exclusive mutability, again not
a bug. Worth listing because it makes one-line ports from C two or
three lines.

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

## Summary

These bugs / friction points combined mean a faithful port of v10/vm.c
(stack-machine bytecode interpreter with refcounted heap and union
values) is several times the LOC of the C original, with the extra
weight coming entirely from CLEAR-imposed workarounds rather than from
the language's normal cost.

The pragmatic choice for `vm.cht` today is:

- Restrict the value type to bare `Int64` (drops bugs #4, #6, #7 by
  making the union and heap unnecessary).
- Hoist every loop-local out of the body (works around #2).
- Add `OR ""` / `OR 0` everywhere a string or int helper appears
  (works around #3 and #8).
- Use `.pop() OR default` for stack pops (works around #5).
- Bind every "`condition` over a fallible expression" to a named local
  (works around #1).

That subset runs an integer-only `.puckc` (e.g. `fib(35)` with no
`SYSCALL 1` on a string). Adding strings and arrays back is gated on
fixes for at least #1, #2, #4, and #6.
