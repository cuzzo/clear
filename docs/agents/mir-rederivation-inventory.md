# MIR Re-Derivation Inventory (vs. the annotation authority)

Goal: every place in `src/mir/` that RE-DERIVES a fact the annotation pass
(`src/annotator.rb`, `src/annotator-helpers/*`, `src/mir/escape_analysis.rb`,
`src/mir/ownership_graph.rb`) already stamped. CLAUDE.md single-source-of-truth:
downstream passes READ stamps; they do NOT re-derive. INV-13/14/15/16.

Method: 3 exploration sweeps, then **every candidate verified by reading the
code**. Agent severities discarded; reclassified against ground truth. The
decisive fact: `was_moved` is written ONLY in `src/annotator.rb` +
`src/annotator-helpers/` -- **zero writes in `src/mir/`**. So any `src/mir/`
site that branches on `is_a?(AST::CopyNode/MoveNode)` for a move/borrow/cleanup
decision is a confirmed second source of truth for ownership (INV-13).

## Tier A -- genuine, architecturally-named, correctness-bearing (the focus)

### A1. INV-14: destination-side cleanup synthesis  [FOCUS FIRST]
`mir_lowering.rb:6324-6337` (`lower_var_decl`) -- the textbook INV-14
violation: `drop_entry = binding_entry.dup IF present, ELSIF ft.string? ...
ELSE synthesize from ft.sync`. The classifier (`promotion_plan.rb`
`CleanupClassifier`) is the authoritative recipe producer; when it returns no
`binding_entry`, lowering *synthesizes a recipe at the destination* from
`ft.string?`/`ft.sync`. INV-14: "Cleanup contracts are inherited, never
synthesized at the destination."
Sibling synthesis sites: `mir_lowering.rb:254, 363, 7360, 7405`.
- **Fix (architectural, self-contained):** make `CleanupClassifier` total --
  it must always emit a `CleanupEntry` for a binding that `has_mir_drop`. Then
  the `elsif/else` fallback at 6324-6337 is provably dead and deletes cleanly.
- **Why first:** `lower_var_decl` is the #1 unit in *all three* tools
  (boobytrap #1 file fix_norm=1.0; decomplex convergence #1 8-detector;
  slopcop genuine gaps). Single fix in `promotion_plan.rb`, lowest blast
  radius, named by INV-14, collapses the worst convergence unit. A synthesized
  recipe that disagrees with the classifier IS the leak/UAF bug class
  boobytrap's fix-churn measures.

### A2. INV-13: ownership re-derived from CopyNode/MoveNode syntax
`was_moved` is the sole authority (annotator). These re-derive it from AST
node type -- a second source of truth for ownership. Genuine semantic-decision
sites (structural unwrap excluded):

| site | decision re-derived | authority to read |
|---|---|---|
| `mir_pass.rb:710,716,726` (`consumed_identifiers`) | move -> feeds `MoveMark`/`defer if(!moved)` (**INV-4 cleanup-guard critical**) | `rhs.was_moved` |
| `control_flow.rb:821,1135,1140,1217,1507,1978` (OwnershipDataflow / use-after-move checker -- a *consumer*, reads `was_moved` 40x yet also branches on syntax) | move/copy eligibility | `!expr.was_moved` |
| `mir_lowering.rb:1758,1879` | `takes = a.was_moved \|\| a.is_a?(MoveNode)` -- the `\|\|` IS the second source | `a.was_moved` only |
| `mir_lowering.rb:1798,1882` | array->slice borrow-vs-move | `was_moved`/`container_borrow` |
| `mir_lowering.rb:5534` | list `.items` borrow | `node.borrowed_field_names` (INV-15) |
| `mir_lowering.rb:6173` | `copy_decl_needs_drop` from COPY syntax | cleanup stamp |
| `mir_lowering.rb:6629,6709` | string deep-copy necessity | string provenance stamp |

- **Fix per site:** delete the syntax branch ONLY after proving the annotator
  always stamps `was_moved` for that syntactic form (per-site annotator-side
  proof). U7-class -- NOT a sweep; one proven removal at a time, EPIC-66
  method, `prspec` + `564/564 0-leak` gate each.
- **Start at `mir_pass.rb:710/716/726`** -- it feeds MoveMark/defer guards
  (INV-4); a wrong move decision here is a direct leak/UAF, the most dangerous
  to leave double-sourced.

## Tier B -- NOT violations; do NOT "fix" (agent false flags, verified)

- `mir_lowering.rb:6204-6208` `decl_alloc` -- reads `node.storage` (escape
  stamp) with precedence, then `binding_entry.alloc`. This IS the prescribed
  single-source read-order, not re-derivation.
- `promotion_plan.rb` `ti.provenance_alloc \|\| :heap` (730/739/781/912/922) --
  `CleanupClassifier` reading the EscapeAnalysis stamp is the prescribed Pass-2b
  data flow, not re-derivation. `|| :heap` is a defensive default.
- `escape_analysis.rb:321`, `mir_lowering.rb:6263` etc. MoveNode-unwrap
  (`x.is_a?(MoveNode) ? x.value : x`) -- structural unwrap to reach the inner
  node, not a semantic move decision.
- `alloc.rb:21` provenance mutation -- state-drift audit
  (`state-drift-audit.md`) already cleared: monotone-toward-`:heap`,
  phase-ordered.
- `*.symbol.is_param` reads (`fsm_lowering.rb:274`, `mir_lowering.rb:2607`,
  `mir_pass.rb:599`) -- reading a stamp, legitimate.
- `mir_pass.rb` `bindings: T.nilable` -- load-bearing (U7); not drift.

## Outcome (executed)
- **A1** (`6a72dcc7a`): INV-14 destination cleanup-synthesis + INV-13 site
  6173 were proven DEAD (classify_owned_string/classify_sync already total);
  deleted. 466/466 byte-identical, 564/0 leaks, 4819/0, srb green.
- **A2a** (`3c76e5382`): `mir_pass.rb` consumed_identifiers move decision now
  reads `was_moved` (verified equivalent at annotator producer: :5580 RC/sync
  guard + :4249 GIVE). Byte-identical, all gates green.
- **A2b batch 1** (`bc02bcccd`): `1758/1879` `|| is_a?(MoveNode)` was
  provably redundant (annotator :4249 stamps MoveNode.was_moved); `6262`
  is_move now reads was_moved. Byte-identical, all gates green.

## Verified boundary (NOT forced -- the honest stop)
The remaining `is_a?(CopyNode/CloneNode/FreezeNode)` checks (`1798/1882`,
`5534`, `6617/6697`, control_flow `821/1135/1140/1217/1507/1978`) are
**syntactic dispatch on operator-node identity**, NOT INV-13 re-derivation:
the annotator deliberately does not stamp `was_moved` for COPY ("COPY into a
borrow param is NOT a take"), so no annotator-derived fact is being
re-derived -- the COPY/CLONE/FREEZE node *is* the fact. CLAUDE.md's own
carve-out permits `is_a?` for syntactic dispatch; only semantic
re-derivation is forbidden. The original inventory over-counted these.

One genuine residual: the `&& !a.is_a?(AST::MoveNode)` clause in `1798/1882`.
`was_moved` is the authority for "moved" but is BROADER than MoveNode (also
TAKES), so the swap is behavior-changing for array-args-to-TAKES-params --
a potential latent bug, not a byte-identical refactor. Per CLAUDE.md it
requires prove-the-bug-first and is filed separately, not bundled here.

INV-13 genuine ownership-decision re-derivation (the move/takes decision
re-derived from MoveNode syntax where was_moved is the authority) is now
fully removed.
