# 3-Pass Architecture: Type Checking / Ownership / Codegen

## Problem

Escape analysis, heap promotion, and cleanup generation are currently
spread across 4 layers at 3 different times:

| When | Where | What |
|------|-------|------|
| Type checking (Pass A) | annotator.rb | `handle_return_escape`, `handle_assign_escape`, `promote_to_heap` mutate storage during `visit_*` |
| Post-pass (Pass 5-6) | effects.rb, annotator.rb | `returns_promoted` computed via call graph, but `heap_promoted_call` set during type checking |
| Transpilation | ownership_generator.rb | `emit_cleanup` re-derives escape decisions from 8 scattered flags |
| Runtime | runtime-header.zig | `promoteFields`, `CheatLib.cleanup` do actual heap dupe / free |

Every new feature (CATCH wrappers, unions, snapshots) creates leaks because
escape decisions in Pass A depend on information not yet available (callee's
`returns_promoted`, aliasing, branch provenance).

## The 8 flags to eliminate

| Flag | Set by | Read by | Purpose |
|------|--------|---------|---------|
| `heap_promoted` on Type | annotator, generic_analysis | transpiler | "callee returned heap data" |
| `escaped_return` on Type | annotator | ownership_generator | "skip cleanup, transferred" |
| `heap_promoted_call` on FuncCall | function_analysis | generic_analysis, transpiler | "callee returns promoted" |
| `returns_promoted` on FunctionDef | annotator | function_analysis, annotator | "function promotes on return" |
| `emit_cleanup` branches | ownership_generator | transpiler | "what cleanup code" |
| `pending_heap_temps` | transpiler | transpiler | "temp needs defer" |
| `promote_to_heap` | annotator | annotator, scope | "change frame->heap" |
| `mark_escaped` | scope (deprecated) | scope | "storage promotion" |

## Target: 3 clean passes

### Pass A: Type Resolution (no mutations)

What it does:
- Resolve types, check signatures, validate semantics
- Build call graph, compute effects
- NO storage mutations. NO `promote_to_heap`. NO `escaped_return`.
- Variables start with the storage their declaration implies (:stack/:frame/:heap)

What changes:
- Remove `handle_return_escape` from `visit_ReturnNode`
- Remove `handle_assign_escape` from `visit_BindExpr`/`visit_Assignment`
- Remove `promote_to_heap` calls
- Remove `propagate_call_flags!` (heap_promoted_call propagation)
- These all move to Pass B

### Pass B: Ownership Analysis (graph-driven, post type resolution)

What it does:
- Walk the fully-typed AST with ALL type info available
- For each function: analyze ALL return paths, determine `returns_promoted`
- For each variable: determine escape, promotion, aliasing, cleanup kind
- Write everything to the OwnershipGraph

Concrete operations:
1. **Escape detection**: if a variable is returned from a function that
   expects heap return type, mark `graph_node.storage = :heap`
2. **Promotion propagation**: if function F calls function G which has
   `returns_promoted`, and F stores G's result, mark F's result variable
   as heap-promoted
3. **Alias detection**: if variable X is extracted from variable Y (same
   union type, getter pattern), mark X as aliased
4. **Cleanup classification**: for each variable, determine cleanup_kind
   and cleanup_alloc based on type + storage + ownership

Graph node after Pass B:
```ruby
{
  path: "r12",
  storage: :heap,          # promoted because parseValue! promotes
  cleanup_kind: :union,    # union with collection variants
  cleanup_alloc: :heap,    # use heapAlloc for cleanup
  aliased: false,          # owns its data
}
```

### Pass C: Codegen (reads graph, no decisions)

What it does:
- The transpiler reads `graph_node.cleanup_kind` for each variable
- Emits the appropriate Zig defer based on the kind
- No `emit_cleanup` with 15 branches
- No re-checking type flags
- No `pending_heap_temps`

```ruby
def emit_cleanup_from_graph(name, graph_node, type_info)
  case graph_node.cleanup_kind
  when :union     then "defer CheatLib.cleanup(#{zig_type}, #{alloc}, &#{name});"
  when :map       then "defer CheatLib.cleanup(#{zig_type}, #{alloc}, &#{name});"
  when :rc        then emit_rc_cleanup(name, type_info)
  when :resource  then "defer #{close_stmt};"
  when :heap_struct then "defer CheatLib.free(rt, #{name});"
  # ... each case is 1 line
  end
end
```

## Why this fixes the leaks

### CATCH wrapper string leak (tests 77, 78)

Currently: Pass A sets `returns_promoted` on `validateUser` during
visit_ReturnNode. The CATCH wrapper `processUser` is synthetic - Pass A
never sees a return path through it. `returns_promoted` doesn't propagate.

With 3-pass: Pass B walks ALL functions after type checking. It sees
`validateUser.returns_promoted = true`. It then checks `processUser`'s
body: the inner function returns `valid.name` (heap string from promoted
struct). The CATCH clause returns `snapshot.name` (static string). Pass B
detects the provenance mismatch and either:
- Deep-copies the snapshot's strings (so both paths return heap)
- Or marks processUser's return as "mixed provenance" requiring
  caller-side handling

### Union collection leak (json_parser, scheme)

Currently: `emit_cleanup` doesn't generate cleanup for union locals because
the type flags don't cover unions. The graph's `needs_cleanup?` works but
`emit_cleanup` is gated on `heap_promoted` which isn't set for unions.

With 3-pass: Pass B classifies every variable. Union locals from
`parseValue!()` get `cleanup_kind: :union`. Pass C reads the graph and
emits cleanup. No flag gating - the graph IS the authority.

## Implementation order

1. Move escape analysis from Pass A to Pass B (the big change)
2. Move `returns_promoted` computation to Pass B
3. Move `heap_promoted_call` propagation to Pass B
4. Replace `emit_cleanup` with graph-reading Pass C
5. Delete the 8 flags

Each step can be tested against existing behavior. The graph produces the
same answers as the flags - just computed in the right order.

## Effort estimate

- Step 1: ~200 lines moved (not new code, relocated)
- Step 2: ~50 lines (already partially done)
- Step 3: ~30 lines
- Step 4: ~100 lines (simplification, net negative)
- Step 5: ~-150 lines (deletion)

Net: roughly -100 lines and one clean system instead of 8 mechanisms.
