# Review: MIR Lowerer Branch Hubs

## Scope

Targets:

- `MIRLoweringExpressions#lower_smooth`
- `MIRLoweringVariables#build_var_decl_nodes`
- `MIRLoweringConcurrency#lower_bg_block`
- `MIRLoweringCapabilities#lower_with_block`
- `MIRLoweringFunctions#lower_intrinsic`

Primary files:

- `src/mir/lowering/expressions.rb`
- `src/mir/lowering/variables.rb`
- `src/mir/lowering/concurrency.rb`
- `src/mir/lowering/capabilities.rb`
- `src/mir/lowering/functions.rb`

## Evidence

Current report overlap:

- Decomplex ranks `lower_smooth`, `build_var_decl_nodes`, and
  `lower_intrinsic` high in cross-detector convergence.
- Espalier ranks `lower_bg_block`, `lower_with_block`, `lower_intrinsic`, and
  `lower_smooth` as coordinator/delegation hubs.
- SlopCop top gaps include `lower_smooth`, `build_var_decl_nodes`, and
  `lower_with_block`.

## /plan

1. Snapshot Decomplex and SlopCop for the five lowerer files.
2. Inspect the five methods together and identify the smallest shared protocol:
   allocation plan, cleanup plan, runtime/catch plan, or operation variant.
3. Implement one strongly typed plan only if it deletes old branch surface from
   at least one target method.
4. Migrate all consumers for that target method in the same change; do not leave
   old local branch paths.
5. Run `bundle exec srb tc` and focused MIR lowering specs.
6. Regenerate metrics after the item. Continue only if the next deletion is
   clear; otherwise keep or revert based on the metrics.

## No-Partial Rule

No broad plan objects that mirror locals. No `T.untyped`. No dual path between
old locals and new records.

## Expected Payoff

Moderate to high. The best outcome is deleting mixed semantic/lowering decisions
from one or two high-pressure methods, not making every method call a new helper.

