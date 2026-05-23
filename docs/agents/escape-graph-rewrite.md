# Escape Graph — single unified analysis (REQUIREMENTS)

## Mandate

There is exactly ONE escape analysis. It is a graph. It recognizes a small,
fixed set of escape methods, marks the relevant symbols as escaping, and a
single uniform stamping step sets `Symbol#storage = :heap` for escaping
symbols. Cleanup and allocation read `Symbol#storage`. Nothing else.

NO per-mechanism escape function. NO separate BG / loop / stream escape
system. NO type-shape branching (`if string` / `if struct` / `if union` /
`if collection`) anywhere in the escape decision. If a value escapes it is
heap; if it does not it stays at its annotation-derived placement.

This is not done — and the compiler does not work — until every transpile
test passes with zero leaks with this single graph in place and the
per-mechanism code DELETED.

## The escape methods (complete, fixed set)

A binding's value ESCAPES its declaring frame-scope iff it flows to one of:

1. **RETURN** — the value reaches a function `RETURN`.
2. **ENCLOSING-SCOPE STORE** — the value is stored into a binding or a
   field/element of a binding that is declared in an *enclosing* frame-scope.
   This single method covers: loop-carry (assign to a binding outside the
   loop), BG-yield (the fiber's result flows to the promise binding in the
   outer scope), and outer-field assignment.
3. **FIBER / CLOSURE CAPTURE** — the value is referenced from inside a
   BG / lambda body while declared outside it. (A fiber body is just a
   frame-scope; capturing = reading an enclosing-scope binding.)
4. **TAKES** — the value is passed as a TAKES argument to a callee.
5. **INHERENTLY-HEAP** — heap by construction: any sync/ownership wrapper
   (Locked, RwLocked, Versioned, AlwaysMutable, Arc, Rc, link), sharded /
   striped collections, `@set`, string/striped HashMaps, `@indirect`,
   and streams / promises / observables.

Frame-scopes (reclaim points) are: the function body, every loop body, and
every BG / lambda body. `if` / `match` / `with` branches are NOT
frame-scopes — they share the enclosing frame.

## Transitivity

Flow is transitive. If value `A` becomes part of aggregate `B` (struct
field, list element, container store) and `B` escapes, then `A` escapes.
One fixpoint over the flow edges.

A binding initialized from a value that is already heap (a heap-returning
call, `NEXT` of a heap-yielding fiber) inherits heap — its own data is
already heap-owned.

## Stamping

After the graph: escaping symbols get `Symbol#storage = :heap`. Non-escaping
keep the annotation-derived node storage. This happens in ONE place,
uniformly. Cleanup classification sets `CleanupEntry#alloc` from
`Symbol#storage`. Allocation sites read `Symbol#storage`.

## What gets deleted

`each_sink_expr`, `loop_carry_names`, `callarg_escape_names`,
`heap_arg_consumer_names`, `bg_capture_names`, `bg_yields_heap?`,
`decl_value_is_heap_call?`, `loop_field_escape_names`, `builds_fresh_alloc?`,
`constructs_indirect?`, `value_extracts_from_heap?`, `container_is_heap?`,
`promote_heapmut_concats!` / `promote_frame_concats!`, `LoopFrameAnalysis`
escape promotion, and the BG-specific escape passes in `mir_pass.rb`.

## Done criteria

`./clear test transpile-tests/` — all pass, 0 leaks. `bundle exec srb tc`
clean. `bundle exec prspec spec/` green. Fuzz matrix 0 fail. No exceptions.
