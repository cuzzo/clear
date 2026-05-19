# State-Drift Audit (EPIC-66 follow-on)

Branch: `epic-66-decomplex-r2`. Goal: determine whether **state drift** (a fact
with >1 source of truth that can disagree) is a real remaining problem, fix any
genuine instance, and record why the decomplex state-drift *detectors* are or
aren't a useful guide here. Method: invariant-grounded (CLAUDE.md INV-1/5/16),
NOT decomplex-count-driven. Read-only audit; a fix only where a genuine
consumed-stale / dangerous-dual-writer is proven.

## Verdicts

### S1 -- storage/provenance single-writer (INV-5, INV-16) -- HOLDS, 0 fixes
Every writer of a declaration's `storage` / `Type#provenance` stamp is one of:
- **Pass-1 annotator declaration seam** (`finalize_storage!`,
  `finalize_decl_storage!`, `downgrade_frame_to_stack` in `alloc.rb`): sets the
  *initial* tier. The only downgrade is `:frame -> :stack`, narrowly gated
  (`storage == :frame && loop_depth > 0 && node.value.is_a?(StructLit)`); it
  **provably never touches `:heap`** and runs *before* EscapeAnalysis.
- **EscapeAnalysis (Pass 2) + its `promote_*` helpers in `control_flow.rb`**:
  the single *escalation* writer. Monotone (`frame/stack -> :heap` only),
  idempotent (`return if ti.heap_provenance?`). Never downgrades `:heap`.
- **Copy-from-canonical-stamp** onto freshly-synthesized nodes
  (`mir_lowering` pipe/proxy desugaring `synthetic.storage = node.storage`) or
  onto a *new* derived `Type` object (`payload = Type.new(ti); payload.
  provenance = nil`). Propagation, not re-decision.

No writer sets a declaration's stamp to a *less-safe* value after
EscapeAnalysis. The contract holds by a property stronger than "one writer":
**all writes are monotone toward the conservative (`:heap`) value, and the only
downgrade is phase-ordered + narrowly-gated + EscapeAnalysis-overridable.**
Multiple physical write-sites therefore cannot produce *dangerous* drift.

### S2 -- sync / ownership axis agreement -- HOLDS, 0 fixes
No site reads `SymbolEntry#sync` and `Type#sync` together expecting equality.
Sync has one designed priority-resolve seam (`escape_analysis.rb:741
entry.sync = unified` -- REQUIRES seed > caller propagation > storage-axis
fallback, producing a single resolved value). `storage`(:shared/:multiowned),
`ownership`, and `Type#any_rc?` are **legitimately distinct axes** (established
by EPIC-66 P3u1 `SymbolEntry#rc_stored?`); no site conflates them.

### S3 -- cleanup alloc vs AllocMark alloc (INV-1/3) -- HOLDS (checker-enforced), 0 fixes
`lower_var_decl` writes the Cleanup's `drop_entry[:alloc] = node_alloc` and the
AllocMark's `mir_alloc = resolve_decl_stdlib_alloc(node) || node_alloc`
separately. This is *redundant state* -- but it is **verifier-guarded**:
`MIRChecker` `ALLOC_CLEANUP_MISMATCH` / `verify_alloc_cleanup_match!` raises a
hard compile-time error on any AllocMark/Cleanup allocator disagreement. This
is the codebase's intended architecture (lowering decides, checker verifies):
checked redundancy is not silent drift.

### S4 -- genuine `b = f(a); a mutated; stale b consumed` -- 0 genuine, detector is FP-heavy
Triaged every distinct in-scope decomplex Derived-State-Staleness shape. **All
are detector false-positives.** The `b = f(a); a reassigned; b not recomputed`
heuristic is intra-procedural with no control-flow / object-identity model and
misfires systematically on this codebase's idioms:

| misfire pattern | example | why it's not drift |
|---|---|---|
| Ruby `x = if/case…end` assignment | `lower_var_decl` `init`/`is_move` (6218/6264) | `is_move` is a branch-local computed *before* `init`'s value; "reassign" is the heuristic mis-reading the expression-assignment |
| branch-disjoint arms | `lower_return` `stmts`/`value` (7353/7421) | `stmts` and the `value=` are mutually-exclusive `if/elsif/else` arms; never both run |
| sibling-block re-read of a stable stamp | `lower_binary_op` `left_is_comptime`/`left_ti` (4986/5024) | `left_ti` re-read in a separate `if EQ/NEQ` block; same non-nil stamp, no mutation |
| deterministic-getter re-fetch | `finalize_storage!` `value_sync`/`vt` (738/814) | `vt = value.type_object` re-fetched -- same object, no mutation |
| multiple independent bindings in a large visitor | `visit_ReturnNode` `expected` (2128/2181) | distinct `expected = …` in disjoint paths of a huge method |

EPIC-66 Unit 1 (`ft` redundant identical recompute in `lower_var_decl`) remains
the **only genuine instance found in the entire epic**. Sweeping the ~241 DSS /
~6.8k Neglected-Updates findings would discover ~0 real bugs -- it is
metric-gaming on a false-positive-heavy detector and is explicitly rejected.

## Bottom line (honest)
**0 fixes. The compiler's single-source-of-truth contracts genuinely hold** --
storage/provenance by monotone+phased writes, sync by a single priority-resolve
seam, alloc by checker enforcement. State drift is **not** a real remaining
problem here; the prior epics' reifications (`atomic?`/`rc_stored?`/
`root_identifier`/`CleanupEntry`/`ft`/…) already eliminated the *structural*
re-derivation form. The decomplex Derived-State-Staleness / Neglected-Updates
detectors are **false-positive-heavy on this codebase** and must not be chased
as a metric. This document is the permanent record so they are not re-attempted
as a sweep.

No code changed; reports unchanged (regenerating them is not the success
metric and would only confirm no delta).
