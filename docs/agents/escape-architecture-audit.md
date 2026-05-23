# Escape Architecture Audit

Current verdict: the branch has not reached the intended architecture.
It removed old promotion machinery, but placement is still re-decided in
multiple downstream passes. That is why fixes keep arriving as local
exceptions.

## Architectural Contract

There must be one authority for value placement:

- escape analysis writes `SymbolEntry#storage`
- lowering reads `SymbolEntry#storage`
- cleanup reads `SymbolEntry#storage`
- MIR checker verifies the emitted MIR agrees with `SymbolEntry#storage`

Every owned value that can escape must have a binding before escape
analysis needs to place it. Anonymous owned expressions must be hoisted
before placement, or represented by a synthetic binding that escape
analysis can stamp. No downstream pass may infer heap/frame from local
shape, callee name, return provenance, or receiver special cases.

## Non-Negotiable Mechanical Gates

This architecture is not considered implemented until the static
architecture invariant spec passes:

```sh
bundle exec rspec spec/architecture_invariants_spec.rb
```

That spec intentionally fails while any of these remain in downstream
placement-sensitive code:

- `return_provenance` or `heap_provenance` as placement data
- `node_is_heap?`, `heap_owned_value?`, `takes_arg_alloc`,
  `receiver_root_heap?`, `call_return_provenance`,
  `return_expr_provenance`
- recursive cleanup-shape checks used as allocator input in lowering or
  hoist
- `@decl_alloc` or `@current_fn_return_alloc` as allocator context
- `node.storage == :heap` as downstream allocator authority
- `expected: :in_dev` in escape fuzz templates

The spec is allowed to be red during the re-architecture. It is not
allowed to be weakened to make the branch pass.

## MIR Checker Contract

MIR checker must verify closed ownership facts. It must not infer them.

By MIR time:

- every allocating expression must be in a checker-visible binding
- allocator-bearing `InlineZig` must identify the target binding or
  receiver whose placement it consumes
- MIR `heap_provenance` / return-provenance side channels are illegal
- heap/frame agreement is verified only from MIR allocation/cleanup
  markers

If a value cannot be verified structurally, compilation must fail. The
fix belongs upstream in hoist or escape placement.

## Sources Still Violating The Contract

### `src/mir/escape_graph.rb`

This is the main architectural violation. It is named as a simple escape
pass, but it still contains graph/provenance/promotion logic:

- multi-round `apply!`
- `stamp_return_provenance!`
- `mark_return_receivers!`
- `call_return_provenance`
- `return_expr_provenance`
- heap/container propagation methods
- recursive cleanup shape checks
- explicit storage-to-alloc conversion

This should be deleted and replaced with a small AST placement walker.
The walker should only answer AST-bound escape mechanisms and write
`symbol.storage = :heap`.

### `src/mir/escape_analysis.rb`

This file no longer performs escape analysis. It propagates caller sync
and storage wrapper state. Keeping it under the escape-analysis name
blurs ownership and encourages placement decisions to share machinery
with capability propagation.

This should be renamed/split into a capability or caller-fact propagation
pass. It must not decide heap/frame placement.

### AST node storage fallback

`AST::Locatable#heap_provenance?`, `#rodata_provenance?`, and
`#borrow_provenance?` read `symbol.storage` when present, but fall back to
node storage overrides. That fallback is a second authority.

Expression-local storage may still be useful for literals or parser
decorators, but binding placement must come from the binding symbol only.
Any allocating expression that reaches MIR as an owned escaping value
without a symbol is a hoist failure.

### `src/ast/type.rb#finalize_storage`

`Type#finalize_storage` mixes layout/inherent storage facts with
escape-owned placement. Type shape can say that a value requires managed
storage, rc/arc, rodata, frozen, etc. It should not be the downstream
source of "this binding escaped, use heap".

The contract should distinguish type/layout requirements from escape
placement. Binding placement still resolves to the allocator.

### `src/mir/mir_lowering.rb`

Lowering still re-decides placement:

- `place_value_for_destination`
- `heap_owned_value?`
- `alloc_for_node`
- `takes_arg_alloc`
- `takes_param_needs_heap_cleanup?`
- `node_is_heap?`
- `resolve_alloc_sym`
- `receiver_root_heap?`
- `materialize_owned_sink_value`
- `owned_sink_value?`

These methods are the downstream exception engine. They inspect MIR
classes, stdlib metadata, receiver roots, recursive type shape, current
declaration allocator, and node storage. That means lowering is still
authoring ownership instead of consuming it.

The correct replacement is a tiny allocator read:

- binding symbol storage `:heap` -> heap allocator
- otherwise frame allocator
- no anonymous owned escape values

Stdlib `:receiver_storage` and `:node_storage` must resolve only through
the already-placed receiver/result binding, not by local inference.

### `src/mir/hoist.rb`

Hoist still contains allocation decisions:

- `mir_allocates?`
- `pick_node_alloc`
- `hoist_alloc`
- `hoist_owned_value_temp`
- cleanup-entry construction
- recursive cleanup shape allocator fallback

Hoist should create bindings. It should not decide heap/frame from MIR
shape. If a hoisted binding later escapes, escape analysis stamps its
symbol. If it does not escape, it remains frame unless type/layout says
otherwise.

### `src/mir/cleanup_classifier.rb`

Cleanup is closer to the target than lowering, but it still reclassifies
placement through mixed signals:

- type cleanup allocator
- node storage fallback
- `heap_provenance?`
- rodata/borrow checks
- fixed alloc overrides
- heap composite fallback

Cleanup should choose cleanup kind from type shape, and allocator from
binding placement. It should not be the pass that discovers a value was
heap placed.

### Function return provenance

`AST::FunctionDef#return_provenance`, MIR call `heap_provenance`, and
related propagation are still promotion by another name. Function returns
must be handled as escape sinks/sources through bindings:

- returned local binding escapes if the return crosses the frame boundary
- returned callee-owned value is bound at the call site by hoist/lowering
- the result binding's symbol is the allocator authority

Return provenance may exist only as a verified signature fact if needed
for ABI, not as a heap/frame decision engine.

### Stdlib allocation metadata

The stdlib still uses `:receiver_storage`, `:node_storage`, and
`return_alloc`. Those symbols are acceptable only as declarative links:

- receiver operation uses receiver binding placement
- value-producing operation uses destination/result binding placement
- explicit fixed allocator remains explicit

They are not acceptable if resolving them requires receiver-root
exceptions, collection-param lists, return provenance, or type-recursive
escape decisions in lowering.

## Required Re-Architecture

1. Run hoist before placement, or make hoist produce all synthetic
   bindings before any escape sink is analyzed.
2. Replace `escape_graph.rb` with an AST walker that stamps
   `SymbolEntry#storage = :heap`.
3. Limit escape mechanisms to explicit AST sinks:
   return/yield, enclosing-scope store, closure/fiber capture,
   TAKES/mutable boundary, and storing into an already escaping owner.
4. Make structural recursion an input-normalization step: find the
   bindings contained in a value shape. Do not make recursive allocator
   decisions downstream.
5. Delete lowering fallback placement logic. Lowering must resolve
   allocator from the already-known binding.
6. Make cleanup allocator selection consume binding placement only.
   Cleanup kind may still come from type shape.
7. Make MIR checker fatal on any owned escaping expression that has no
   binding placement fact.
8. Turn all escape fuzz cells into active acceptance tests. No `:in_dev`
   escape cells are allowed.

## Sustainable Architecture Test

If fixing a failing example requires adding a condition to lowering,
cleanup, hoist, or the checker to decide heap/frame, the architecture is
still wrong. The fix belongs upstream in hoisting or escape placement so
the downstream decision is a direct read.
