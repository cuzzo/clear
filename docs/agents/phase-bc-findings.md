# Phase B + C Findings — Honest Assessment

After Phase A (3 wins), I attempted Phases B and C and learned the original
strategic plan understated several dependencies. This document records what
actually happened and lays out the realistic path.

## What's landed (Phase A + B + partial C)

| Task | Status | LOC | Architectural gain |
|---|---|---|---|
| SIMP-01 | ✅ | +25/-7 | Stamp extended to Identifier/CopyNode/Cast/IfStatement/MatchStatement |
| SIMP-03 | ✅ | -39+33 | 6→4 DeepCopy strategies (:string + :union → :full_value) |
| SIMP-05 | ✅ | -14+7 | Type#sync= side-effect on provenance deleted; 17 callers audited |
| SIMP-07 | ✅ | -36+62 | One predicate (`EscapeGraph.local_fn_returns_heap?`) consumed by annotator + EscapeGraph |
| SIMP-09 | ✅ | -11 | Dead code: `is_pointer = heap? \|\| (frame? && struct?)` rule was unreachable |
| SIMP-12 (partial) | ✅ | -2 | Deleted 2 shadowing `attr_accessor :storage` on BinaryOp/StringConcat |
| SIMP-15 | ✅ | doc | Catalogued all 32 storage writes in pipe_analysis.rb |

## What's blocked and WHY (the honest part)

### SIMP-08 (Delete Type#layout): blocked on SIMP-13

The original plan claimed Type#layout was a "side-channel with 5
propagation sites." Audit reveals:
- Type#layout has **one writer per fact**: parser for explicit `@boxed`,
  function_analysis.rb:790 for "atomic struct → indirect" inference.
- 8+ readers (capabilities, generic_analysis, annotator, MIR) ask "is
  this @boxed?" in contexts where a Symbol may not exist (generic merge,
  field types, inner types of generic instantiations).
- The "side-channel" complaint was about how layout was read in
  Type#zig_type to emit `*T` — **that path was removed in SIMP-09**.
- The remaining propagation sites are normal type-system field-tracking,
  not duplicate decisions.

To actually delete Type#layout requires routing the @boxed bit through
a different mechanism. Options:
- Move to Symbol#layout only (SIMP-13's approach for provenance) — works
  for binding nodes but not for field/generic types that have no Symbol.
- MIR-level explicit `MIR::HeapPtr` wrapper at every AtomicPtr construction
  site — requires touching every construction site.

Either path is a multi-day refactor. **Defer until SIMP-13 establishes the
infrastructure.**

### SIMP-10 (Delete CopyNode provenance stamp): blocked on a replacement signal

The plan claimed SIMP-9 would orphan the `ti.provenance = :heap` stamp set
by `visit_CopyNode`. Investigation shows it's **actively used by escape
analysis**:
- `PromotionClassifier` reads field types' `heap_provenance?` at lines
  72, 91 to skip promotion for fields already heap-allocated (the COPY case).
- Deleting the stamp breaks the "COPY already owns this string, don't
  re-promote" optimization.
- Replacement requires either AST-type dispatch (`is_a?(AST::CopyNode)`) —
  exactly what the user warned against — or a stamp on the field-source
  binding analogous to SIMP-01's `init_contents_heap`.

**Defer until the field-source heap signal is designed.**

### SIMP-11 (EscapeGraph as sole writer): scope was overstated

The plan claimed 75 writer sites of storage/provenance were duplicates.
Audit reveals:
- 32 are in `pipe_analysis.rb` (legitimate single-writer-for-synthesized-node,
  catalogued in SIMP-15).
- Most other writes are similar: per-AST-node-type initial classification by
  annotator, pipeline_rewriter, MIR lowering. Each is a single-writer for a
  distinct decision (HashLit always heap, BinaryOp concat carries heap flag).
- The genuine "duplicate" pattern is the **three-fields-in-lockstep** write:
  `Locatable#storage_override`, `Symbol#storage`, `Type#provenance` all
  written together for the same fact.

The lockstep is the duplicate. Collapsing those three fields into one
binding-level field (SIMP-12+13) eliminates the lockstep automatically.
**Defer SIMP-11 until SIMP-12+13 land.**

### SIMP-12 (Consolidate Locatable#storage + Symbol#storage): blocked on SIMP-13

Attempted: make `Locatable#storage` reader prefer `sym.storage` when a
symbol is attached. **Broke `loop_frame_analysis` and
`nested_field_append_allocator` specs** with `[INLINE_ALLOC_MISMATCH]`.

Root cause: operations stamp their `storage_override` at one point in the
pipeline (pre-EscapeGraph). EscapeGraph later upgrades `sym.storage = :heap`
without updating those earlier overrides. Operations read their own
override (stale :frame) while the binding's symbol says :heap. The
consolidated reader exposes this disagreement as a hard error.

The two-source pattern IS the bug the user wants eliminated. But the fix
isn't in the getter — it's in either:
1. **Synchronize**: every site that upgrades `sym.storage` also walks all
   AST nodes referencing the symbol and updates their `storage_override`.
2. **Eliminate**: delete `@storage_override` entirely; readers always go
   through `sym.storage`; the "shared Type mutation" concern (which is
   why the override exists) goes away when Type#provenance moves off Type
   (SIMP-13).

Option 2 is cleaner. **Defer until SIMP-13.**

### SIMP-13 (Move Type#provenance off Type): genuinely multi-day work

Inventory: **99 provenance touches across 20 files**:
- `mir/`: alloc.rb, promotion_plan.rb, mir_emitter.rb, escape_graph.rb,
  mir_pass.rb, mir.rb, mir_checker.rb, mir_lowering.rb, control_flow.rb
- `annotator-helpers/`: method_analysis, function_analysis, effects,
  function_signature, generic_analysis
- `ast/`: scope.rb, ast.rb, type.rb, std_lib.rb, symbol_entry.rb
- Plus annotator.rb itself

The move is genuinely a multi-day, multi-commit effort:
- **Day 1**: Add `Symbol#storage` getter that returns the canonical answer.
  Add `Type#provenance` deprecation warning. No behavior change.
- **Day 2**: Migrate the readers that already have a Symbol available
  (~30 sites). Each: read sym.storage instead of type.provenance.
- **Day 3**: For readers that operate on Types without Symbols (generic
  merge, field types, std_lib type expressions), establish a route — either
  carry storage on the parent binding's symbol, or use a per-context lookup.
- **Day 4**: Remove `Type#provenance` field. Verify no readers remain.
  Update tests.

Each day is a self-contained commit with full gate runs (specs + transpile +
fuzz + byte-identical-zig).

## What other items remain (not blocked, just multi-step)

### SIMP-02 (Delete promoteDeep)

Blocked on HPT-independence semantics. Real fix: per-binding "source about
to be cleaned up?" stamp during MIR lowering. Independent of SIMP-13.

### SIMP-04 (Collapse hoist_cleanup_entry 10→1)

Requires runtime arms for `:heap_struct_plain` (plain *T heap pointer
destroy) and unifying `:rc`/`:locked`/`:write_locked` through `CheatLib.cleanup`
(runtime already has the arms). Multi-step but independent of SIMP-13.

### SIMP-06 (Inline dupe* helpers)

Three helpers with mutually-recursive distinct semantics (deep vs shallow
for struct pointee fields). Per-callsite audit + test expansion. Independent
of SIMP-13.

### SIMP-14 (Delete cleanupAlloc vtable)

Depends on SIMP-13 + SIMP-12 (per-binding static allocator means no
runtime per-pointer arena dispatch needed).

## Realistic next-step recommendation

The honest path forward isn't "Phase C in stated order". The work is:

1. **Independent of SIMP-13 (can land now)**:
   - SIMP-04 (cleanup-kind collapse) — multi-step but clear path
   - SIMP-06 (dupe* helper consolidation) — multi-step Zig refactor
   - SIMP-02 (delete promoteDeep) — needs source-cleanup stamp design first

2. **SIMP-13 itself**: 4-day budget, biggest unblocker. Order:
   - Day 1: Symbol#storage canonical getter, no behavior change
   - Day 2: Migrate readers with Symbol available
   - Day 3: Type-only readers route through binding context
   - Day 4: Remove Type#provenance field

3. **After SIMP-13** (cascade unblocks):
   - SIMP-08 (Type#layout) — analogous move for layout
   - SIMP-10 (CopyNode stamp) — replace with field-source binding stamp
   - SIMP-12 (storage consolidation) — `@storage_override` mechanism deletable
   - SIMP-11 (EscapeGraph sole writer) — most "duplicates" become single-writer
     naturally after the field consolidation
   - SIMP-14 (cleanupAlloc) — runtime arena dispatch deletable

## What this session DID accomplish

Phase A: 3 clean wins (SIMP-01, -05, -07).
Phase B: 1 win (SIMP-09 — dead code removal), 2 blocked-by-SIMP-13 (SIMP-08, -10).
Phase C: 1 partial win (SIMP-12 shadowing accessors), 2 blocked-by-SIMP-13 (SIMP-11, -13).

**Total commits**: 8 in this multi-session arc.
**Total LOC delta**: roughly net-neutral on production (additions for
consolidated logic ≈ deletions of duplicates).
**Architectural progress**: real but the big-ticket consolidations need
SIMP-13 as their foundation. The original plan's "small independent wins"
mostly came from areas adjacent to (not requiring) the big refactor.

The remaining work, done correctly, requires committing to SIMP-13 as
the next multi-session arc.
