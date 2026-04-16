# MIR Checker Bug Tracker

These are confirmed cases where the MIR checker FAILED to detect a real memory leak.
Each entry documents the root cause and the checker gap that allowed it through.

---

## BUG-MIR-001: Incorrect MoveMark for map-indexed assignment (FIXED)

**Severity:** CRITICAL  
**Status:** Fixed in `src/control_flow.rb` and `src/mir_pass.rb` (map assignment ownership fix)  
**Reproducible:** `spec/transpiler_spec.rb` - "does not suppress val cleanup when map assignment deep-copies the value"

### What leaked

```clear
val = Value.Lambda{ body: Value{ Num: 42.0 }, id: 1 };
map["key"] = val;
RETURN someOtherValue;
```

Generated Zig (before fix):
```zig
const val = ...;
var val_moved = false;
defer if (!val_moved) CheatLib.cleanup(Value, rt.heapAlloc(), &val); // LEAK: never fires
...
try map.put(..., blk_prm: {
    var __prm = try CheatLib.dupeUnionValue(Value, val, rt.heapAlloc()); // map gets a COPY
    ...
});
val_moved = true; // BUG: suppresses val's cleanup even though map has a copy, not val
```

### How it got through the checker

The checker sees:
- `AllocMark(val)` -- present
- `Cleanup(val, has_moved_guard=true)` -- present

Both invariants 1 and 2 are structurally satisfied. The checker cannot verify that
`val_moved = true` is placed CORRECTLY -- it only verifies that a cleanup exists.

The ownership dataflow in `transfer_stmt` (control_flow.rb) treated `map[k] = val`
as a consumption of `val`, which eventually caused `MIR::SuppressCleanup` to be
inserted after the statement. That SuppressCleanup generates `val_moved = true`.

But the runtime's `blk_prm: { dupeUnionValue(val) }` transform deep-copies `val`
before `put`, so `val` is NOT moved -- the map holds a copy. The original `val`
needs its cleanup defer to fire.

### Checker gap

The checker trusts that `SuppressCleanup` nodes are placed correctly. It cannot
detect the case where a `SuppressCleanup` suppresses a value that was NOT actually
transferred to another owner.

### Fix

In `transfer_stmt` (control_flow.rb) and `collect_consumed_names` (mir_pass.rb):
for `AST::Assignment` where LHS is `GetIndex` on a map type, do NOT mark the RHS
identifier as consumed. The map's value transform (dupeUnionValue) makes a copy;
the original retains ownership and must be cleaned up by its defer.

---

## BUG-MIR-002: Heap-returning call in non-TAKES argument position (OPEN)

**Severity:** CRITICAL  
**Status:** OPEN -- not yet fixed  
**Reproducible:** `./clear test examples/minivm/interpreter_test.cht` -- 22 leaked allocations

### What leaked

```clear
FN evalIn!(...) RETURNS String ->
    RETURN prStr(runTest!(input, rootId, pool, penv), readable);
END
```

`runTest!` returns a heap-allocated `Value`. `prStr` takes `v: Value` (NOT `TAKES`) --
it borrows the value by-value copy. The temporary `Value` returned by `runTest!` is
passed directly to `prStr` as an argument, with no variable binding and no cleanup defer.

Generated Zig:
```zig
fn evalIn(...) ![]const u8 {
    return try types.prStr(rt, try interpreter.runTest(rt, input, rootId, pool, penv), readable);
    //                         ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    //                         Heap Value -- no variable, no defer, leaks
}
```

### How it got through the checker

MIR checker invariant 4: "Heap-returning call in STATEMENT position is bound to a variable (HPT_LEAK)."

The check is restricted to TOP-LEVEL STATEMENT EXPRESSIONS. In this case,
`runTest!(...)` is in ARGUMENT position of `prStr(...)`, which is the value in a
RETURN statement. The call is NOT at statement position -- it is nested inside another
call's argument list.

The HPT hoisting logic in `mir_lowering.rb` / `hoist_alloc` is called when processing
function call arguments. But the condition for hoisting requires the call to be in a
"borrow" argument position for a non-TAKES parameter AND the call is heap-returning.
Investigation needed: is this case being evaluated at all by `hoist_alloc`, or is it
being skipped because the outer call is a RETURN?

### Checker gap

Invariant 4's scope is too narrow. It only fires for:
  `statement = heap_returning_call(...)`

It does NOT fire for:
  `statement = f(heap_returning_call(...), other_args)`  -- nested in arg position
  `RETURN f(heap_returning_call(...), other_args)`       -- nested in return value

Any heap-returning call nested inside another call's non-TAKES argument list bypasses
HPT detection. The MIR checker cannot see inside call arguments at this level.

### Required fix

Two possible approaches:

**A. Fix in MIR lowering (preferred):** Extend `hoist_alloc` to hoist heap-returning
calls that appear in non-TAKES argument positions. When `runTest!(...)` is passed as
an argument to `prStr` (non-TAKES parameter), the lowering should emit:

```zig
const __tmp_runtest = try interpreter.runTest(rt, input, rootId, pool, penv);
defer CheatLib.cleanup(Value, rt.heapAlloc(), &__tmp_runtest);
return try types.prStr(rt, __tmp_runtest, readable);
```

**B. Fix in MIR checker (extend invariant 4):** Scan ALL call arguments (not just
top-level statements) for heap-returning calls passed to non-TAKES parameters.
This is harder because it requires type information at the checker level.

**Recommended:** Fix A (extend hoist_alloc). The lowering is the right place to make
this decision, consistent with the role boundaries in CLAUDE.md.

---

## Summary of Checker Gaps

| Gap | Description | Invariant that should cover it | Currently covered? |
|-----|-------------|-------------------------------|-------------------|
| Incorrect MoveMark | SuppressCleanup inserted for non-moves (map copy) | INV-4 (structural) | No -- checker can't detect incorrect placement |
| HPT in arg position | heap-returning call in non-TAKES arg, not hoisted | INV-4 (HPT_LEAK) | No -- only checks statement position |

### Architectural implication

The MIR checker's invariants are STRUCTURAL: they verify presence of AllocMark/Cleanup
pairs and their type/allocator consistency. They do NOT verify:
- That SuppressCleanup nodes are inserted for ACTUAL ownership transfers (not copies)
- That heap-returning calls in nested argument positions are hoisted

Fixing these requires the LOWERING to be correct (not just the checker to detect errors).
The checker cannot substitute for correct lowering decisions.
