# Cross-Detector Convergence triage (task #30)

decomplex names Convergence its #1 entry point ("agreement outranks volume.
Start here"). It was never triaged. Doing that now -- with an honest verdict,
not an open-ended grind.

## What the top in-scope convergence units actually are

Every top in-scope unit (`lower_var_decl:6173`, `compute_zig_type:2030`,
`visit_BindExpr:2896`, `resolve_call:187`, `handle_assign_move:5552`,
`transfer_stmt:649`) carries the **identical detector set**: Broken Protocols,
Decision Pressure, Derived-State Staleness, False Simplicity, Missing
Abstractions, Neglected Path Conditions, Neglected Updates. Decomposed by the
tool's own signal tiers:

| component | tier | status |
|---|---|---|
| Reification Misses | 1 | **driven to floor 83->18**, residual justified (reification-floor.md) |
| Missing Abstractions | 1 | object-receiver cases reified (AST.call?/root_identifier/rc_stored?/…); residue is the same no-receiver class as the reification floor |
| Decision Pressure | 1 | concentrated in annotator-helpers `.full_type`/`.value`; out of byte-identical scope, ~163/234 tool-marked "essential dispatch -- legitimate" (#31) |
| Derived-State Staleness | 2 *POSSIBLE* | **unquantified** -- 2% sampled, FP-heavy patterns real but coverage unknown; trustworthy only after decomplex CFG hardening (#28, #29) |
| Broken Protocols, False Simplicity, Neglected Path/Updates | 3 **"(noisy)"** | the tool labels these noisy; they are the bulk of each unit's high "N findings" count |

## Verdict

The convergence "start here" list does **not** reveal new byte-identical
actionable work. Its high per-unit finding counts are dominated by tier-3
detectors decomplex itself marks noisy, plus tier-2 DSS that cannot be trusted
without the #29 hardening. The genuine tier-1 content (Reification, the
object-receiver Missing-Abstractions) has been driven to its documented floor.
The remaining tier-1 Decision-Pressure is the tracked out-of-scope
annotator-helpers backlog (#31).

So: convergence is triaged, conclusion recorded. There is no honest
"next reification/abstraction epic" hiding here -- the actionable surface is
exactly the tracked items (#24 floor, #28/#29 DSS-trust, #31 DP backlog). Any
further movement requires either the decomplex hardening (#29, makes tier-2
trustworthy) or deliberate API refactors (out of the byte-identical contract),
**not** chasing the tool-acknowledged-noisy tier-3 volume.

Cumulative across the whole effort: decomplex Total candidates 12257 -> 12114;
Reification-Misses 133 -> 18; convergence ~1167 -> 1161. Every code change
byte-identical (564/564 transpile, 0 leaks, srb GREEN, 4819 specs 0 failures).
