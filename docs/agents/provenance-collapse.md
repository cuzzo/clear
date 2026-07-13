# Provenance Side-Channel Collapse

**Goal:** delete the duplicate-decision pattern that is the direct source of frame/heap/rodata bugs. Replace 7 parallel side-channels and 6+ layers of redundant "where does this value live?" computation with ONE answer per binding, read everywhere.

## The pattern this exists to delete

For `xs: Holder = Holder{ name: COPY "hello" }; RETURN xs;`, the system runs "make this heap" TWICE on the same value:

1. Compile-time: `visit_CopyNode` sets `provenance=:heap`; COPY emits `heapAlloc().dupe(u8, ...)`. Value is now heap.
2. Runtime: `promoteDeep` walks the value again at return time and re-runs `heapAlloc().dupe(u8, ...)`. Creates a SECOND allocation. Orphans the first.

Neither layer knows the other did it. Every bug in this class — leaks of duped heap pointers, invalid-frees of rodata, alignment mismatches between frame source and heap free — is a symptom of duplicate decisions disagreeing.

## The seven side-channels and where they're read

| Channel | Type | Set | Read |
|---|---|---|---|
| `Type#provenance` | `:heap`/`:frame`/`:rodata`/`:borrow` | `visit_CopyNode`, `EscapeGraph#stamp_node_heap!`, `Type#sync=` setter side-effect, schema resolution | `Type#zig_type` (computes `*T`), `cleanup_classifier`, `dupeValue` arms |
| `Type#layout` | `:indirect`/nil | `parse_type_annotation` for `@indirect`, `function_analysis.rb:790` for atomic struct params, `scope.rb:172` propagation | `Type#zig_type` (computes `*T`), `cleanup_classifier` |
| `Type#sync` | `:locked`/`:write_locked`/etc. | parser, annotator | sets `provenance=:heap` as setter side-effect |
| `Type#ownership` | `:affine`/`:shared`/`:multiowned`/`:link` | parser | `inherently_heap?` |
| `AST::Locatable#storage` | `:stack`/`:frame`/`:heap` | `finalize_storage!`, `EscapeGraph#stamp_node_heap!`, parser | `lower_var_decl` cleanup-alloc decision |
| `SymbolEntry#storage` | same | `scope.declare`, `EscapeGraph#stamp_node_heap!` | `lower_var_decl`, escape graph |
| `SymbolEntry#type.provenance` | same as `Type#provenance` | back-propagated by `EscapeGraph` | downstream consumers |

## The five runtime "make heap" helpers

| Function | When called | Always dupes? | Leaks already-heap? |
|---|---|---|---|
| `promote` | per-field, return-time | no (frame check) | no |
| `promoteDeep` | whole-struct, return-time | **yes** | **yes** ← bug source |
| `dupeValue` | COPY of struct/list/etc. | yes | n/a (caller takes ownership) |
| `dupeUnionValue` | COPY of union | yes | n/a |
| `dupeStructSlices` | union @indirect field | yes | n/a |

## What the simplified architecture says

```
At each allocation site:
  1. Will this value's outermost binding escape its declaring scope?  (EscapeGraph)
  2. If yes → allocate from heapAlloc.
  3. If no  → allocate from frameAlloc.

At each cleanup site:
  Use the SAME allocator the source recorded.  (One field on the binding.)
```

One decision per allocation, recorded in one place, read everywhere. No re-derivation.

## Deletion sequence

Each step is a self-contained commit, gated by:
- `bundle exec prspec spec/` — green
- `./clear test transpile-tests/` — 568/568 with 0 leaks
- `ruby tools/fuzz/run.rb --matrix --templates takes_move_modality,return_value_modality,struct_field_store_modality,list_append_modality` — failure count strictly **decreases**, never increases

Estimated net LOC at each step. The order is intentional: late steps depend on earlier deletions being in place.

### Step 1: Delete `promoteDeep`

Migrate callers to `promote` (frame-aware, no-op if already heap). `promote` already handles every shape `promoteDeep` does. Remove the always-dupe variant.

- **Touches:** `zig/runtime/runtime-header.zig` (delete `promoteDeep`), `src/mir/mir_lowering.rb` (`:generic_deep` strategy → `:generic`), `src/mir/mir_emitter.rb` (delete `:generic_deep` emit arm)
- **Closes:** the residual `return_value_modality:struct_owned_fields` fuzz fail (leaked heap-COPY'd string at return-time double-allocation)
- **Net:** ~−30 LOC Zig, ~−10 LOC Ruby

### Step 2: Delete `PromotionClassifier.fn_has_escapable_return?` and route through EscapeGraph

The classifier's schema-based "does the return need promotion?" check disagrees with EscapeGraph's escape-set computation. EscapeGraph already decides what escapes. Make the promotion-plan READ EscapeGraph's output instead of re-deriving from schema.

- **Touches:** `src/mir/promotion_plan.rb` (delete `fn_has_escapable_return?`, `struct_has_promotable_fields?`, `compute_struct_promote` schema logic), `src/mir/mir_pass.rb` (call EscapeGraph result directly)
- **Net:** ~−80 LOC Ruby

### Step 3: Delete `Type#layout` and its propagation

`*T` should be one explicit MIR wrapper (`MIR::HeapPtr` or similar) for AtomicPtr cells. Not a Type-level side-channel that 5 propagation sites have to mirror.

- **Touches:** `src/ast/type.rb` (delete `@layout`, `indirect?` (or repurpose), `layout` keyword args), `src/ast/scope.rb:172`, `src/annotator-helpers/generic_analysis.rb:367, :433, :444`, `src/annotator-helpers/function_analysis.rb:214-217, :790`, `src/ast/symbol_entry.rb` (delete `layout` field), `src/ast/ast.rb` (`CapabilityWrap.layout`)
- **Net:** ~−60 LOC Ruby

### Step 4: Delete `is_pointer = heap? || (frame? && struct?)` from `Type#compute_zig_type`

Line 2191 `compute_zig_type` rule conflates "data on heap" with "Zig type is `*T`". Two distinct concerns. Sites that need `*T` should construct that form explicitly (MIR wrapper from Step 3); the Type's zig_type should be the bare value type.

- **Touches:** `src/ast/type.rb` (delete the `is_pointer` rule, the `*T` paths at lines 2173, 2185, 2248, 2291, 2298), every site that previously got `*T` from this side-channel now requests it explicitly via MIR
- **Net:** ~−40 LOC Ruby

### Step 5: Delete the `provenance = :heap` setter side-effect in `Type#sync=`

`sync=` setting `provenance` is non-local action-at-a-distance. The few callers that need both should set both explicitly.

- **Touches:** `src/ast/type.rb` (delete the side-effect on `sync=`), audit all callers of `sync=` to set `provenance` where genuinely needed
- **Net:** ~−5 LOC Ruby + minor audit changes

### Step 6: Collapse 5 `dupe*` runtime helpers into one `dupeValue` with `@hasDecl(T, "dupe")` hook

Already partially done this session (Step B3 added the hook + `PartitionedStringMap.dupe`). Finish by migrating `dupeUnionValue`, `dupeStructSlices`, `dupeCaptured` callers to `dupeValue` and adding type-specific `dupe` methods where shape-specific logic is genuinely needed.

- **Touches:** `zig/runtime/runtime-header.zig`, individual type definitions
- **Net:** ~−100 LOC Zig (mostly deletion of duplicated walks)

### Step 7: Delete the COPY auto-set-`provenance=:heap` in `visit_CopyNode`

Once Step 4 lands (zig_type doesn't read provenance for `*T`), the COPY's provenance stamp is no longer the trigger for ANYTHING the compiler cares about — the actual allocator decision is at the COPY emission point and at the binding's escape decision. The provenance stamp is then a redundant rumor.

- **Touches:** `src/annotator.rb` `visit_CopyNode`, audit downstream readers
- **Net:** ~−10 LOC Ruby

## Final state

After all steps:

- **One field per binding**: the source allocator, set once by EscapeGraph or by explicit user intent, read uniformly by cleanup, deinit, and dupe sites.
- **No `*T` from provenance**: pointer-indirection is an explicit MIR concept, not a Type side-effect.
- **No `Type#layout`**: AtomicPtr cells use the MIR pointer wrapper.
- **One `dupeValue` runtime helper** with comptime arms (existing pattern) plus `@hasDecl(T, "dupe")` for shape-specific clones.
- **No `promoteDeep`**: `promote` is the only return-time helper, and it's a no-op if the value is already heap.

Bugs in the class "duplicate decisions disagreeing on where data lives" become structurally impossible — there's only one decision to disagree with.

## Order rationale

Steps 1, 2, 3 are independent in scope and can land in any order. Step 4 depends on Step 3 (the MIR pointer wrapper must exist before deleting the side-channel). Step 5 is independent. Step 6 has been partially done; the remainder is incremental. Step 7 is last because it depends on Steps 4, 5, 6 to confirm `provenance=:heap` is no longer read anywhere material.

Recommended landing order: **1 → 2 → 6 → 3 → 4 → 5 → 7**.

## Pattern: single-writer stamp + many-reader consumers

Each step below follows the same pattern (demonstrated by `SymbolEntry#init_contents_heap` in the partial PC1+PC2 work):

1. **Identify the duplicate-decision**: multiple sites computing the same answer.
2. **Add a stamp on the binding**: a single-writer field that holds the decided answer.
3. **Single writer at the natural decision point** (usually annotator at bind-time).
4. **Convert all readers** to consume the stamp instead of re-deriving.
5. **Delete the re-derivation logic** once readers all consume the stamp.

The pattern collapses N read-sites + N decision implementations into 1 writer + N reads. Apply to every duplicate decision; the codebase moves toward "one writer, many readers" everywhere.

## Session-progress shape (what's landed)

**Committed:**
- `SymbolEntry#init_contents_heap` — single-writer per-binding stamp at bind-time. Annotator computes from init expression's per-field provenance.
- Stamp coverage extended (SIMP-01): Identifier (chained), CopyNode/CloneNode, Cast, IfStatement, MatchStatement. StructLit/UnionVariantLit/FuncCall/MethodCall already covered.
- `PromotionClassifier` reads stamp; one re-derivation deleted.
- `mir_pass#insert_promotion!` parallel decision layer deleted (~25 LOC).
- Closes the `return_value_modality:struct_owned_fields` leak via no spurious copy.
- DeepCopy strategy collapse (SIMP-03): `:string` and `:union` → `:full_value`. lower_copy 6 → 4 strategies. emit_deep_copy: 6 → 4 case-arms. hoist_cleanup_entry: 4 → 2 DeepCopy branches. `node.zig_type` overrides `@TypeOf(src)` to preserve named union types and explicit `[]const u8` for strings.

**Attempted and reverted:**
- SIMP-02 (delete promoteDeep): blocked. `promote()` is frame-aware and skips already-heap data; `promoteDeep()` always dupes. The whole-struct return path needs promoteDeep semantics for HPT-independence: when the source binding is about to be freed, the return value must own its data regardless of allocator. Swap caused "Invalid free" in 77_error_snapshot.clear. Real fix needs a per-binding "source about to be cleaned up?" stamp at lowering time.

**Why each remaining PC needs more than one session:**
- **PC-A (Type#layout deletion)**: Type#layout is read by `indirect?` which is called in 8+ files via `ti.indirect?`. Symbol#layout is also independently read in 4+ files. Deleting Type#layout while keeping AtomicPtr semantics requires replacing every `*T` emission with an explicit MIR wrapper at every construction site. Audit-heavy and risk-prone.
- **PC-B (sync= side-effect)**: 17 callers of `Type#sync=` writes. Each that depends on the implicit `provenance=:heap` set must explicitly do so. Per-call-site audit.
- **PC-C (dupe* consolidation)**: `dupeUnionValue` and `dupeStructSlices` have DIFFERENT semantics for struct pointee fields (shallow vs deep). Migrating callers would change behavior; needs corner-case audit.
- **PC-D (zig_type is_pointer)**: 60+ readers of `heap_provenance?`. Many call `ti.zig_type` expecting implicit `*T` for heap structs. Each callsite needs explicit pointer-wrapping.
- **PC-E (PromotionClassifier schema fallback)**: NOT a duplicate-decision target. The schema fallback (`struct_has_promotable_fields?`) answers the *static type property* question "does this struct type contain heap-bearing fields?" — orthogonal to the stamp's *per-binding* question "are this binding's contents already heap?". Deletion requires moving the schema query onto Type as `has_promotable_struct_fields?(schema_lookup)`, then dual-condition logic stays but becomes single-source.
- **PC-F (CopyNode provenance stamp)**: depends on PC-D landing (zig_type must stop reading provenance for *T).

Each is a focused multi-day effort with the gating discipline (568 transpile-tests + 4830 specs + fuzz monotonically improving). The pattern is established and can be applied incrementally without losing the demonstrated single-writer-stamp design.

## Acceptance for each step

| | spec | transpile | fuzz | LOC |
|---|---|---|---|---|
| pre | 4830/0 | 568/0 leaks | 39 ok, 1 fail, 0 leak | baseline |
| step N | must hold or improve | must hold | failure count must NOT increase | must net-delete |

Steps that don't net-delete OR don't improve gate counts should be reassessed before landing.
