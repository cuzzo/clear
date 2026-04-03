# Escape Promotion & Cleanup Rearchitecture

## The Problem

Promotion logic (deciding what frame-allocated data to copy to heap when returning from functions) was scattered across 4 files with 3 layers making partial decisions. Bugs were unfindable because no single place owned the decision. Every fix in one layer broke another.

## What Changed

### New Architecture (Pass C)

- **PromotionPlan**: callee-side. Decides what to promote on return. 15 unit tests.
- **CleanupPlan**: caller-side. Decides which bindings need defer cleanup. 7 unit tests.
- **emit_return_from_plan**: transpiler reads plans mechanically. No decisions.
- Old `emit_return_with_promotion` (78 lines of per-type special cases) deleted.
- Old `collection_return` flag deleted.

### Borrow Checker Foundation

- **Use-after-move detection**: annotator raises compile error when non-Copy value is used after being moved. 12 unit tests.
- **Move points**: `v2 = v1`, `StructLit{ field: val }`, `list.append(val)`, `TAKES fn(val)`.
- **Copy types**: primitives, strings, enums, structs with all-Copy fields, Rc/Arc.
- **TAKES auto-move**: calling a TAKES function automatically consumes the argument. Works on both statement-level and RETURN-level calls. 5 unit tests.
- **GIVE on non-Copy types**: previously restricted to RC/resource. Now works on any non-Copy type.

### Zig Runtime

- `cleanup()` union handler frees non-string slice variants (`[]Value` inside `Value.List`).
- `freeUnionPayload` (HashMap) dupes all slice fields on put, not just strings.
- `needsCleanup` correctly reports unions with non-string slice variants (currently disabled - see below).

## What Was Fixed

| Metric | Before | After |
|---|---|---|
| json_parser leaks | 5 | 0 |
| scheme leaks | 51 | 29 |
| scheme tests | 21/21 | 21/21 |
| Ruby specs | 1500 | 1556 |
| Transpile tests | 198 | 201 |
| Zig unit tests | 13 | 17 |

## What Remains: 29 Scheme Leaks

All 29 leaks have ONE root cause: `needsCleanup(Value)` returns false for unions where the only heap variant is a non-string slice (`List: []Value`). This means ArrayList element cleanup doesn't recurse into union elements to free their inner slices.

### Why It's Difficult

Enabling `needsCleanup` for union slice variants is one line. It fixes the leaks. But it causes use-after-free in the scheme interpreter because:

1. `MATCH ast START Value.List AS items ->` extracts `items` from `ast.List`
2. In Zig, this is `const items = ast.List` - a bitwise copy of the slice pointer
3. Both `ast` and `items` now point to the same `[]Value` backing
4. `evalList!(items, ...)` uses `items` to build data structures (lambdas)
5. When `ast` is cleaned up, the shared `[]Value` is freed
6. The lambda now holds dangling pointers

### What Was Tried

1. **Enable needsCleanup + TAKES on eval!**: TAKES prevents caller cleanup of `ast`. But inside eval, MATCH extraction still creates shared pointers between `ast` and `items`. Result: test 4 passes, but 50 leaks (worse than 29).

2. **dupeUnionStrings for struct variant slices**: HashMap.put deep-copies Lambda's `params` and `body` slice fields. Fixes the env storage case but not the return case. The returned lambda still shares data with the AST.

3. **Return-arg move suppression**: `RETURN fn(TAKES arg)` sets `arg_moved = true` before return. Fixes the specific `runTest!` → `eval!` pattern but doesn't fix the general MATCH extraction sharing.

### Where The Problem Is

MATCH pattern extraction (`Value.List AS items`) is a shallow copy in Zig. In Rust, pattern matching MOVES data out of the source. After destructuring, the source is consumed.

CLEAR needs the same: after `MATCH ast START Value.List AS items ->`, `ast` is consumed. The `items` variable owns the `[]Value` slice. `ast`'s cleanup is suppressed.

This is one feature: **MATCH destructure as move**. Once implemented:
1. Enable `needsCleanup` for union slice variants (1 line in Zig)
2. The 29 leaks become 0
3. No double-frees because there's no sharing
