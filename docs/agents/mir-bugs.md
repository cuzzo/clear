# MIR System Potential Bugs

The following is a list of potential memory leaks, use-after-free, or double-free issues identified in the current compiler architecture (up to MIRPass and StaticLeakChecker).

## 1. Unhoisted Heap Literals (Memory Leak)
`MIRPass.hoist_heap_temps!` currently only scans for `FuncCall` and `MethodCall` with heap provenance. It misses `StructLit`, `ListLit`, and `HashLit` that are explicitly marked with `@heap` storage or have a type requiring heap allocation.
- **Impact**: Any heap-allocated literal used as a sub-expression (e.g., an argument to a function) will allocate memory but will not be hoisted to a `VarDecl`. Consequently, no `MIR::Alloc` or `MIR::Drop` nodes are inserted, leading to a silent memory leak.
- **Example**: `print(User@{heap}{id: 1})`
- **Checker Gap**: `StaticLeakChecker.scan_expr_for_unhoisted_heap!` also only looks for `FuncCall`/`MethodCall`, so it doesn't catch these leaks.

## 2. MATCH TAKES Variant Payload Leak (Memory Leak)
When performing a `MATCH TAKES` on a union, the subject union's ownership is consumed. If a branch matches a variant with a non-Copy payload (e.g., a `List` or `StringMap`) but does not use an `AS` binding to extract it, the payload is leaked.
- **Impact**: The union's moved guard is set to `true`, preventing the union-level `Drop` from firing. However, since the payload wasn't bound to a variable, nothing cleans it up.
- **Example**: `MATCH TAKES u CASE .Some -> {}` (where `u` is `Option<List>`).
- **Resolution**: `MATCH TAKES` branches without `AS` bindings must still emit cleanup for non-Copy variant payloads.

## 3. Use-After-Free via `with RESTRICT` Reassignment (UAF)
The annotator and MIR system do not currently prevent the reassignment of a variable that is aliased by a `with RESTRICT` block.
- **Impact**: If a heap-allocated variable is aliased as `r` and then reassigned, the pre-cleanup for the reassignment frees the old value. The restricted alias `r` now points to freed memory.
- **Example**:
  ```clear
  WITH RESTRICT x AS r
    x = new_value # x is freed here
    print(r)      # UAF
  ```

## 4. On-the-fly Allocator Choices in Transpiler (Architecture Violation)
The transpiler still contains logic in `resolve_alloc_for_intrinsic` and `resolve_alloc_for_container` to decide between `:heap` and `:frame` allocators at code-generation time.
- **Impact**: This violates the "dumb transpiler" principle. These decisions should be made in `MIRPass` (or `CleanupClassifier`) and encoded into `MIR::Alloc` and `MIR::Drop` nodes.
- **Risks**: Divergence between `MIRPass`'s assumptions and the transpiler's actual emission leads to `ALLOC_MISMATCH` or leaks that the checker cannot reliably verify if the transpiler "goes rogue."

## 5. Manual Arena Management (Architecture Violation / Potential Leak)
The transpiler still manually handles `rt.saveFrameMark()` / `rt.restoreFrameMark()` and `rt.preserveAndRewind()` based on function return types and `uses_frame` flags.
- **Impact**: This "on-the-fly" cleanup logic is not represented in the MIR. `StaticLeakChecker` has `check_frame_overflow!`, but it doesn't see the actual save/restore points as MIR nodes.
- **Resolution**: Introduce `MIR::FrameMark` and `MIR::FrameRewind` nodes to make arena management explicit and verifiable.

## 6. Implicit Allocations in VarDecl/Assignment (Potential Leak)
Certain constructs like `List[10]` (pre-allocation) or `Pool` initialization trigger allocations directly in the transpiler's `visit_VarDecl` or `transpile_container_set`.
- **Impact**: These are not always explicitly represented as `MIR::Alloc` nodes if they are considered "part of the type initialization."
- **Risk**: If the initialization allocates but the `MIRPass` doesn't flag the variable as `needs_cleanup`, it leaks.

## 7. `OrRescue` Fallback Dupe Fragility (Potential Leak/UAF)
The transpiler uses a `@pending_or_fallback_dupe` state flag set by `MIR::Promote(:or_fallback_dupe)`.
- **Impact**: State flags in the transpiler are fragile. If the MIR sequence is interrupted or if nodes are visited out of order, the flag might remain set or be missed.
- **Resolution**: `OrRescue` nodes should be stamped with the dupe requirement directly.

## 8. `TRANSPILE_CAST` Ownership Gaps (Potential Leak)
`ZigTranspiler.visit_node` automatically applies `transpile_cast` if a `coerced_type` is present.
- **Impact**: If a cast requires an allocation (e.g., coercing a non-Copy type that requires a deep copy/dupe), it is not tracked by the MIR system.
- **Risk**: Most casts are currently just slice reinterpretation or pointer casts, but if any allocate, they leak.
