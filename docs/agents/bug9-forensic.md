# Bug #9 Forensic — 1.2 and 1.3

Bug under investigation: [`transpile-tests/known-failing/bug9_list_in_struct_in_list.clear`](../../transpile-tests/known-failing/bug9_list_in_struct_in_list.clear).
Symptom: `items[i].data[0]` returns the wrong value (or the 0xAAAA debug-fill
pattern) because the inner `@list`'s backing storage is freed by the loop's
`restoreLoopMark` while still referenced by the outer `items` list.

## 1.2 — Which invariant should have flagged it?

### The emitted Zig is the evidence

```zig
while ((p < 3)) {
    const __loop_mark_1 = rt.saveLoopMark();
    defer rt.restoreLoopMark(__loop_mark_1);             // ← frees inner list
    var data = @as(std.ArrayListUnmanaged(i64), .empty);
    defer if (!data_moved) CheatLib.cleanup(..., rt.frameAlloc(), &data);
    try data.append(rt.frameAlloc(), CheatLib.intMul(p, 10));   // ← frame
    try items.append(rt.heapAlloc(),  Item{ .data = data });    // ← heap
    data_moved = true;
    ...
}
```

`data` is **frame-allocated**, then *moved* into `Item{.data = data}` which is
*appended into the heap-allocated outer container*. The outer container
outlives the loop frame; the inner buffer doesn't. Classic UAF.

This violates:

- **INV-1 (single allocator per binding lifetime).** The buffer at
  `items[i].data` started life on the frame arena and is later read from a
  heap-arena perspective.
- **INV-5 (frame values never escape their scope).** `data` escapes via the
  `Item{}` initialiser into `items`, but escape analysis never promoted it to
  heap.

### Where escape analysis should have fired

Two functions are *each* responsible for catching this shape — and they each
have the same blind spot.

**Function 1 — `LoopFrameAnalysis.escapes_to_outer?`**
([`src/mir/control_flow.rb:1398`](../../src/mir/control_flow.rb)):

```ruby
when AST::MethodCall
  receiver = node.object
  next unless receiver.is_a?(AST::Identifier) && !local_names.include?(receiver.name)
  found = true if node.args.any? { |a| a.is_a?(AST::Identifier) && a.name == var_name }
```

It looks at each direct arg of an outer-container's mutator call (append /
insert / push). If the arg is **a bare Identifier** matching the candidate
escaper's name, it's flagged.

The bug-9 call site is `items.append(Item{ data: data })`. The direct arg is
the `Item{}` StructLit — not an Identifier. The walker does not recurse into
struct/union field initialisers. **`data` is invisible to this check.**

**Function 2 — `EscapeAnalysis.e2_promote_frame_concats!`**
([`src/mir/escape_analysis.rb:393`](../../src/mir/escape_analysis.rb)):

```ruby
case node
when AST::BinaryOp
  if node.op == :ADD && node.string_concat
    node.storage = :heap
    ti.provenance = :heap
    promoted = true
  end
  ...
when AST::StructLit, AST::UnionVariantLit
  node.fields&.each_value { |v| promoted |= e2_promote_frame_concats!(v) }
when AST::ListLit
  ...
```

This walker *does* recurse into `StructLit` / `UnionVariantLit` / `ListLit`
field values. But the leaf cases it handles are `BinaryOp :ADD
string_concat=true` and `StringConcat` — string concatenations. It does **not
handle a plain `Identifier` whose symbol resolves to a frame-allocated
collection**.

So Function 1 looks for the right thing (an Identifier referring to a frame
binding) but only at the top arg level. Function 2 looks in the right place
(inside struct field initialisers) but only for the wrong type of leaf
(string concat). **Bug #9 is the exact AST shape that falls between them.**

### The missing rule, stated precisely

> If an outer container's `append` / `insert` / `push` / `put` is passed an
> expression that — transitively, through `StructLit` / `UnionVariantLit`
> / `ListLit` field initialisers — references an `Identifier` whose symbol's
> storage is `:frame` and whose type is a collection, that source declaration
> must be promoted to `:heap`.

Both `escapes_to_outer?` and `e2_promote_frame_concats!` need the same
recursive walk; today they have disjoint partial implementations.

### Why the MIR Checker didn't fire either

INV-FRAME-REWIND (the `[FRAME_NO_REWIND]` check we saw on bug #2) verifies
**that a frame-allocating loop body has a `restoreLoopMark` defer**. In bug
#9 the loop body *does* have one — that's what frees the buffer too early.
The checker is verifying the synthesised plumbing, not the *escape decision*.

No existing checker invariant says "if a frame binding is captured into a
struct field which is then stored in a heap container's mutator, promote it
to heap." That decision lives in escape analysis (the lowering side), and
when it doesn't fire, nothing downstream catches it.

The bug therefore exists for two reasons, in different layers:

1. **EscapeAnalysis (lowering)** doesn't propagate "escapes-into-heap-container"
   through struct/union field initialisers when the leaf is an `Identifier`.
2. **MIRChecker (verification)** has no invariant that says "a binding whose
   storage is `:frame` may not appear as an Identifier inside a StructLit
   that is then mutator-appended into a heap container." Adding that
   invariant would catch lowering bugs in this class.

Per CLAUDE.md's pipeline contract (lowering decides → checker verifies →
emitter templates), fixing only #1 is enough for correctness; adding #2 is
defence-in-depth that catches lowering regressions.

## 1.3 — Which fuzz template should have generated it?

### `nested_loop_escape` is the template

Its [docstring](../../tools/fuzz/templates/nested_loop_escape.rb):

> Template: a loop-LOCAL collection escapes into an outer collection.
> Stresses the loop-frame promotion path.

That's exactly bug #9's shape. The template *exists* for this class.

### What's in its matrix today

```ruby
NESTED_LOOP_ESCAPE_CELLS = []
[:list, :array].each do |inner_kind|
  [:while, :for].each do |loop_kind|
    [1, 3].each do |outer_iters|
      NESTED_LOOP_ESCAPE_CELLS << { inner_kind: ..., loop_kind: ..., iters: ... }
    end
  end
end
```

Three dimensions: `inner_kind ∈ {list, array}`, `loop_kind ∈ {while, for}`,
`iters ∈ {1, 3}`. Eight cells total.

The body of every cell looks like:

```clear
MUTABLE inner: Int64[]@list = [];
inner.append(i);
inner.append(i + 1_i64);
outer.append(inner);          # ← direct identifier escape
```

**The escapee is always a bare Identifier passed directly to
`outer.append(...)`**. The matrix never produces:

```clear
outer.append(Item{ data: inner });    # struct-wrapped
outer.append(Wrapper.Some(inner));    # union-variant-wrapped
outer.append([inner, inner2]);        # list-literal-wrapped
```

Verified by spot-running the `outer.append(inner)` shape — the escape
analysis correctly emits `inner.append(rt.heapAlloc(), ...)` (heap, not
frame). The direct case is sound; the struct-wrap case is bug #9.

### The missing fuzz dimension

The template needs an additional cell axis describing **how the escapee is
wrapped at the append site**:

```ruby
wrap_kind ∈ { :bare, :struct_field, :union_variant_field, :list_literal_elem,
              :nested_struct_two_levels }
```

`:bare` is what we test today. Each new value would produce another `outer.append(...)` shape, all of which are memory-safety equivalent in
intent (the inner must promote to heap) but invisible to today's escape
analysis.

A natural fifth axis is **transitivity depth** — does the wrapping struct
itself live inside another struct, which is the actual append target? Bug
#9's reproducer goes one level deep; real codebases (the vm.clear loader
that triggered the discovery) go two or three.

### Why the existing cells didn't accidentally cover it

The eight existing cells are an outer product of (inner_kind × loop_kind ×
iters). Each cell renders the same body text — only the loop syntax and
inner element type change. There's no expansion of the AST shape *around*
the `outer.append(...)` line. The matrix is structurally one-shaped, and
that shape happens to be the safe one.

## Together: what these two findings say

The bug exists because two pieces of escape analysis that were *meant to
catch the same class* each implemented half of the recursive walk, and the
fuzz template that was *meant to exercise this class* has a matrix that
never produces the shape where their gap shows up. There is no single
moment where someone decided "skip the struct-wrapped escape case" — it's
a missing axis in both the implementation and the test, and each gap
silently camouflages the other.

The fix is mechanically small:

- **Code**: merge the recursive walk from `e2_promote_frame_concats!` into
  `escapes_to_outer?` (and into the matching promoter, so the binding gets
  upgraded to `:heap` at decl time). One function, one walker, every leaf
  type.
- **Test**: add a `wrap_kind` axis to `nested_loop_escape` and grow the
  cell count from 8 → 40. The first run will surface whatever the fixed
  walker still doesn't handle.
- **Defence**: add a MIRChecker invariant that walks struct/union/list
  initialisers passed to known heap-container mutators and asserts no
  Identifier inside resolves to a `:frame` binding. This catches the same
  bug at verification time, so future regressions in the lowering walker
  can't ship without the checker firing.

The mutation test (which would have proven these checks are load-bearing)
is the natural follow-up: introduce a mutant that turns off the new
walker recursion, watch the new fuzz cell + new checker invariant both
fire on the same input.
