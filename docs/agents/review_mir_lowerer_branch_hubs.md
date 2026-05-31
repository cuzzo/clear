# Review: MIR Lowerer Branch Hubs

## Scope

Targets:

- `MIRLoweringExpressions#lower_smooth`
- `MIRLoweringVariables#build_var_decl_nodes`
- `MIRLoweringConcurrency#lower_bg_block`
- `MIRLoweringCapabilities#lower_with_block`
- `MIRLoweringFunctions#lower_intrinsic`

## /plan

1. Snapshot Decomplex and SlopCop for the five lowerer files.
2. Identify the smallest shared protocol that deletes old branch surface.
3. Implement only if the new record/plan becomes the sole path for that method.
4. Regenerate metrics and keep only if both tools move in the right direction.

## Implementation Result

Abandoned.

Attempted:

- Removed reused mutable locals in `build_var_decl_nodes`.
- Removed reused `left` locals in `lower_smooth`.

Metrics:

- Decomplex derived-state staleness for the five lowerer files improved
  `9 -> 4`.
- SlopCop for the same files regressed `76 -> 84` genuine gaps.

Assessment:

Not worth keeping as implemented. This did remove a real Decomplex warning
class, but the SlopCop regression failed the per-item acceptance criteria. The
attempt was reverted fully. A future pass needs a larger semantic deletion,
probably a real var-decl materialization plan, not local variable hygiene.
