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
3. **13c Cat A — annotator context (SAFE)**: Migrate readers inside
   `is_a?(AST::Identifier)` blocks in annotator subsystems and promotion
   plan. Per-subsystem commits.
4. **13c Cat A — MIR context (NOT SAFE, BUDGET FIRST)**: mir_lowering
   readers cannot blindly swap `ft.heap_provenance?` for
   `sym.heap_provenance?`. The MIR-time Type clone (`Type.new(node.full_type)`)
   captures the snapshot at lower-time and may carry an OLDER provenance
   than the post-EscapeGraph sym.storage. Concrete regression observed:
   test 179_hashmap_structlit_no_double_dupe panics with "Invalid free"
   if lower_var_decl uses sym.heap_provenance? where it previously used
   the clone's. Fixing this needs either:
   - EscapeGraph re-runs after lower-time clones are made, OR
   - mir_lowering stops cloning Types (uses sym as the source of truth
     for ALL reads, requires synchronizing all writers), OR
   - the clone propagates from sym at clone-time
   All three are non-trivial. Defer mir_lowering migrations.
5. **13e Cat 2**: Delete the escape-graph + control_flow Type.provenance
   writes (Symbol already updated alongside). REQUIRES mir_lowering
   migration first because mir_lowering currently READS type.provenance
   that escape-graph writes.
6. **13e Cat 6**: Delete generic_merge / method_return writes (template
   Types).
7. **13d Cat B + 13c Cat C**: The harder structural migration of Type-only
   readers. May require new mechanisms or deletion of consumers.
8. **13e Cat 1**: After all readers go through Symbol, the construction-
   time writes become field-internal-only. Either keep as Type-internal
   bookkeeping or remove if no reader remains.
9. **13f**: Once zero readers remain, delete `@provenance`, the predicates,
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

## Landed (as of SIMP-13e)

- **SIMP-13a**: this audit doc
- **SIMP-13b**: `Symbol#provenance`, `Symbol#heap_provenance?`, `#frame_provenance?`, `#rodata_provenance?`, `#borrow_provenance?` accessors (no behavior change)
- **SIMP-13c**: 24+ Cat A reader sites migrated through helpers, then helpers
  inlined as direct `sym&.X_provenance? || ti.X_provenance?` pattern at each
  callsite. Three `Locatable#value_X_provenance?` helpers added then deleted
  after inline.
- **SIMP-13d**: 2 Cat B sites resolved (call_heap_provenance_from_type? +
  borrow_return?), plus inlined helper-uses pattern across whole codebase.
- **SIMP-13e**: 4 lockstep `type.provenance = :heap` writes deleted in
  escape_graph.rb (stamp_node_heap! + stamp_return_symbol!). Required fix
  in lower_bind_expr to propagate node.symbol → proxy.symbol. Three
  control_flow.rb binding promotions (promote_to_heap!, promote_decl_to_heap!,
  promote_value_to_heap! Identifier branch) migrated from
  `ti.provenance = :heap` to `sym.storage = :heap`. Net: Symbol#storage
  is the canonical source for escape-driven heap promotion.

## Remaining for SIMP-13f

13 reader sites still use the inline OR fallback `|| ti.X_provenance?` for
non-binding expressions (literals, FuncCall returns, CopyNode results,
BinaryOp string_concat, etc.). To delete Type#provenance entirely:

1. Replace each ti-fallback with either:
   - An expression-storage stamp set at annotation time on the AST node, OR
   - AST-type dispatch (`is_a?(AST::Literal) ? ...`) for cases that are
     derivable from node shape
2. Migrate Cat 1 initial-classification writes (Type constructor sigils,
   ast.rb finalize_storage!, scope.rb resolve_full_type) — Symbol#storage
   needs an alternative initialization path that doesn't read Type#provenance
3. Delete `@provenance`, `heap?`/`frame?`/`rodata?`/`borrow_provenance?`,
   aliases, copy-ctor line, provenance_alloc dispatch in type.rb

Each step is gated: spec + transpile + fuzz must remain green; net LOC
delete preferred.

### SIMP-13f investigation findings (this session)

Attempted to eliminate the OR-fallback `|| ti.X_provenance?` at four classify_*
helpers in promotion_plan.rb that operate on binding-decl nodes. Reverted —
sym.storage is **not always canonical** for binding contexts. Concrete gaps
observed via debug output:

- `contents = fileReadAll(f)` — FuncCall returning heap String. After
  annotation: `node.full_type.provenance=:heap` but `sym.storage=:stack`.
  The :heap provenance is written by `set_cleanup_alloc!` AFTER the binding's
  symbol was already created with storage=:stack from `finalize_storage`.

- `f: ?String = names.first()` — Optional/borrow types. The :rodata/:borrow
  provenance on the optional Type comes from method_analysis return-type
  propagation, again after Symbol creation.

The root architectural gap: **late provenance writes on a binding's Type don't
propagate to Symbol**. Sites that write `node.full_type.provenance = :X` AFTER
the symbol exists:
- `annotator.rb:set_cleanup_alloc!` (FuncCall/MethodCall result classification)
- `annotator.rb:visit_VarDecl` (indirect/COPY)
- `function_analysis.rb` (call return propagation)
- `generic_analysis.rb` / `method_analysis.rb` (type widening)

Attempted `mirror_provenance_to_symbol!` helper to propagate from these
late-write sites to sym.storage — surfaced 1749 spec failures because the
helper over-wrote sym.storage in cases where the storage axis was something
other than the provenance axis (e.g., :shared / :multiowned wrappers carry
their own storage classification that doesn't follow the provenance set).

The correct path forward for SIMP-13f:

1. Find every site that writes `something.provenance = X` post-Symbol-creation
2. For each, determine if it should also update sym.storage (and if so, with
   what guard to avoid over-writing the storage axis)
3. Once all late writes propagate to sym, the OR-fallback in readers becomes
   purely defensive (no behavior change to remove)
4. Then remove ti.provenance writes systematically
5. Then delete the Type#provenance field

Each step needs full gate runs (4830 specs + 567 transpile-tests + fuzz).
Estimate 2-3 sessions of careful per-site work.
