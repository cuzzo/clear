# Provenance Touches — SIMP-13a Audit

119 total references to `.provenance` / `heap_provenance?` / `*_provenance?` across
13 production files. Classified for migration.

## Totals

- **41 WRITER sites** (`.provenance = X`)
- **58 READER sites** (`.provenance`, `heap_provenance?`, `rodata_provenance?`, etc.)
- **20 internal sites in type.rb** (field declaration, predicates, alias methods)

## Per-file inventory

| File | Total | Writers | Readers |
|---|---|---|---|
| `ast/type.rb` | 26 | 7 (constructor + derivation) | 19 (predicates + self-uses) |
| `mir/promotion_plan.rb` | 20 | 0 | 20 (read-only) |
| `mir/mir_lowering.rb` | 14 | 2 (cleanup-classification) | 12 |
| `annotator.rb` | 14 | 5 (CopyNode, hoisted-ret, etc.) | 9 |
| `mir/control_flow.rb` | 12 | 7 (escape promotion at MIR pass) | 5 |
| `mir/escape_graph.rb` | 10 | 4 (stamp_*_heap! helpers) | 6 |
| `annotator-helpers/function_analysis.rb` | 6 | 4 (param propagation) | 2 |
| `ast/ast.rb` | 5 | 3 (finalize_storage!) | 2 (Locatable.storage) |
| `annotator-helpers/generic_analysis.rb` | 4 | 3 (generic merge) | 1 |
| `ast/scope.rb` | 3 | 3 (resolve_full_type) | 0 |
| `annotator-helpers/method_analysis.rb` | 2 | 2 (method return) | 0 |
| `mir/mir_pass.rb` | 2 | 0 | 2 |
| `mir/alloc.rb` | 1 | 1 (nil-reset) | 0 |

## Writer categories

### Cat 1: Initial classification at construction (~13 writes)

Where: Type constructor, scope.rb, ast.rb finalize_storage!

These derive provenance from STATIC inputs (parser sigils, declared storage,
ownership wrappers). SymbolEntry is NOT YET created when Type constructor
runs — these can't migrate to Symbol#storage at the same site.

**Migration plan:** AFTER SymbolEntry is created, mirror Type's initial
provenance onto Symbol. Type constructor can then stop tracking it (or
keep field-internal but ensure single read-point is sym.storage).

### Cat 2: Escape-driven promotion (~11 writes)

Where: escape_graph.rb (`stamp_node_heap!`), control_flow.rb

These write `:heap` when a binding escapes. Symbol IS available at these
sites (the helpers already write `sym.storage = :heap` alongside).

**Migration plan:** Drop the `type.provenance = :heap` line; keep only the
`sym.storage = :heap` write. **Direct deletion.**

### Cat 3: Copy/propagation (~9 writes)

Where: function_analysis.rb, method_analysis.rb, generic_analysis.rb

These copy `outer.provenance` to `inner.provenance` during param resolution,
method-return derivation, or generic merge. Symbol may or may not be
available.

**Migration plan:** Examine each — if migrating to sym.storage works
(the inner has a binding), do that. Otherwise, recognize this as a
Type-only context (Cat 6 below).

### Cat 4: CopyNode/explicit decision (~5 writes)

Where: annotator.rb (visit_CopyNode, etc.)

These stamp the COPY expression's resulting Type with `:heap`. The COPY
expression is rarely bound directly; it's usually consumed by a parent
node. Whether a Symbol is available depends on the context.

**Migration plan:** Re-frame as the field-source heap signal (SIMP-10's
blocker). Likely: the OUTPUT of COPY needs a provenance hint, and the
parent binding/struct field can ask "is this value heap?" via AST-type
dispatch (`is_a?(AST::CopyNode)`) once Type#provenance is gone.

### Cat 5: Cleanup-classification (~2 writes)

Where: mir_lowering.rb `hoist_cleanup_entry`

Calls `bare.provenance = :stack` on a CLONED Type to compute clean
zig_type. After SIMP-09 removed `is_pointer` rule from compute_zig_type,
these clones may be unnecessary. Audit individually.

### Cat 6: Type-only contexts

Where: generic_analysis.rb (merge), method_analysis.rb (return types)

The Type instances being written to are TEMPLATES — used for type-matching
across generic instantiations, not bound to a specific Symbol. Setting
provenance on these is meaningless after SIMP-13 (the Type doesn't BELONG
to a binding).

**Migration plan:** Delete these writes (no-op after SIMP-13). The
consumers must look up provenance from the parent binding's Symbol.

## Reader categories

### Cat A: Reader with Symbol available (~30 sites estimated)

Sites where a `node.symbol` or `entry` is in scope and `type.provenance`
can be replaced with `sym.storage`. Includes annotator, MIR lowering,
control_flow, promotion_plan. **Easy migration.**

### Cat B: Reader with no Symbol (~15 sites)

Sites operating on field types, generic merge, std_lib templates, or
nested types inside other Types. **Need design** — see SIMP-13d.

### Cat C: Self-reference in Type.rb (~13 sites)

`heap_provenance?` and predicates called on `self` within Type methods.
These can remain (they're predicates on the Type's own derived state).
If Type#provenance is removed entirely, these predicates need a new
backing — either delegate to a passed-in binding context, or be deleted
in favor of binding-level queries.

## Recommended order

1. **13a (this doc)** — done.
2. **13b**: Add `Symbol#provenance` accessor returning `sym.storage`
   filtered to {:heap, :frame, :rodata, :borrow}.
3. **13c Cat A**: Migrate the easy readers — ~30 sites of `ti.provenance`
   / `ti.heap_provenance?` to `sym.provenance` / `sym.storage == :heap`.
   Per-subsystem commits.
4. **13e Cat 2**: Delete the escape-graph + control_flow Type.provenance
   writes (Symbol already updated alongside).
5. **13e Cat 6**: Delete generic_merge / method_return writes (template
   Types).
6. **13d Cat B + 13c Cat C**: The harder structural migration of Type-only
   readers. May require new mechanisms or deletion of consumers.
7. **13e Cat 1**: After all readers go through Symbol, the construction-
   time writes become field-internal-only. Either keep as Type-internal
   bookkeeping or remove if no reader remains.
8. **13f**: Once zero readers remain, delete `@provenance`, the predicates,
   the alias methods, the copy-ctor line. Type becomes immutable w.r.t.
   storage.

## Estimated risk per stage

| Stage | Risk | Reason |
|---|---|---|
| 13b | LOW | Pure addition, no behavior change |
| 13c Cat A | LOW-MED | Mechanical migration with full test gate per commit |
| 13e Cat 2 | LOW | Companion `sym.storage = :heap` already writes the truth |
| 13e Cat 6 | LOW | Removes ineffective writes on templates |
| 13c Cat C | MED | Type-internal predicates need restructuring |
| 13d Cat B | HIGH | Design work — how do field types get provenance? |
| 13f | LOW after rest | If 0 readers remain, deletion is mechanical |
