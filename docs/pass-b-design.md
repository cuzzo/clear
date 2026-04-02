# Pass B: Ownership Analysis (Separated from Type Checking)

## Problem

The annotator currently interleaves type checking with ownership decisions.
This causes leaks because ownership decisions depend on information that isn't
available during the visit (callee's returns_promoted, aliasing relationships,
branch provenance). Every new feature creates new leaks because the ownership
logic must be threaded through type-checking code.

## Current mechanisms (to be replaced)

| Flag/Mechanism | Location | Purpose |
|---|---|---|
| `heap_promoted` on Type | generic_analysis.rb | "callee returned heap data" |
| `escaped_return` on Type | annotator.rb | "skip cleanup, ownership transferred" |
| `heap_promoted_call` on FuncCall | function_analysis.rb | "callee returns promoted data" |
| `returns_promoted` on FunctionDef | annotator.rb | "this function promotes on return" |
| `emit_cleanup` (15 branches) | ownership_generator.rb | "generate defer code" |
| `pending_heap_temps` | transpiler.rb | "temporary needs defer cleanup" |
| `finalize_scope` drop list | annotator.rb | "what to clean up at scope exit" |
| `promote_to_heap` | annotator.rb | "change storage from frame to heap" |

## New architecture

### Pass B: `compute_ownership!`

Runs after all types are resolved (after Pass 7 stack tiers, before the
transpiler). Walks the entire AST with complete type information.

For each variable declaration:
1. Record in graph: `graph.declare(name, kind, storage, type_info)`
2. If RHS is a function call with returns_promoted callee -> mark as `:heap_owned`
3. If RHS extracts from a union/collection (alias detection) -> mark as `:aliased`
4. If variable escapes via return -> mark as `:escaped`

For each function:
1. Analyze all return paths for heap promotion
2. Set `returns_promoted` based on complete analysis (not incremental)
3. Track whether CATCH wrappers pass through promoted data

For each scope exit:
1. Build drop list from graph (live + needs_cleanup + not aliased)
2. Store on AST node for transpiler

### Graph queries (used by transpiler)

```ruby
graph.needs_cleanup?(name)    # true if variable owns heap data
graph.aliased?(name)          # true if shares backing with another variable  
graph.allocator_for(name)     # :heap or :frame
graph.drop_list(scope_depth)  # variables needing cleanup at this depth
```

### Transpiler changes

Replace emit_cleanup with:
```ruby
drop_info = node.ownership_drops  # populated by Pass B
drop_info.each do |drop|
  zig_type = transpile_type(drop[:type])
  alloc = drop[:allocator] == :heap ? "rt.heapAlloc()" : "rt.frameAlloc()"
  emit "defer CheatLib.cleanup(#{zig_type}, #{alloc}, &#{drop[:name]});"
end
```

## Implementation order

1. Add `compute_ownership!` method that walks the AST post-annotation
2. Populate graph with complete ownership info (declare, alias, escape)
3. Build drop lists on AST nodes (replacing finalize_scope drops)
4. Add graph query methods
5. Update transpiler to read from graph instead of flags
6. Delete old flag propagation code

Each step can be tested independently against the existing behavior.
