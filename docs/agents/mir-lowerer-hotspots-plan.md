# MIR Lowerer Hotspots Plan

## Scope

Targets:

- `MIRLoweringExpressions#lower_smooth`
- `MIRLoweringConcurrency#lower_bg_block`
- `MIRLoweringCapabilities#lower_with_block`
- `MIRLoweringFunctions#lower_intrinsic`
- `MIRLoweringVariables#build_var_decl_nodes`

Primary files:

- `src/mir/lowering/expressions.rb`
- `src/mir/lowering/concurrency.rb`
- `src/mir/lowering/capabilities.rb`
- `src/mir/lowering/functions.rb`
- `src/mir/lowering/variables.rb`

## Signal

These methods keep appearing across Decomplex, SlopCop, Boobytrap, and Espalier.
The common shape is decision-heavy lowering code that reads semantic facts,
chooses an ownership/control-flow policy, builds MIR nodes, and mutates lowering
state in one method.

The previous function-context work was valuable because it deleted an implicit
state protocol instead of adding a parallel path. This pass should follow the
same rule: introduce an explicit lowering artifact only when every caller moves
to it and the old ad hoc state path disappears.

## Hypothesis

The likely simplification is not more local branch tests. The better target is
to reify lowering decisions that currently live as loose conditionals:

- smooth-call lowering plan
- background-block runtime/capture plan
- WITH capability lowering plan
- intrinsic operation descriptor
- variable declaration materialization plan

Each plan must be strongly typed and must replace branches in the target method.
If a plan object is only a named bag passed beside the old inputs, it is new
tech debt.

## /plan

1. Snapshot `decomplex`, `slopcop`, `boobytrap`, and `espalier` metrics for the
   five target methods.
2. Inspect each method independently and classify its branch pressure:
   - semantic classification
   - ownership/cleanup decision
   - MIR node construction
   - state mutation
   - diagnostics/runtime requirements
3. Start with the method where one typed plan can delete the most local
   branching. Current expectation: `build_var_decl_nodes` or `lower_smooth`.
4. Implement one method at a time. Do not introduce shared abstractions until at
   least two methods prove the same shape.
5. After each method, regenerate metrics and decide:
   - keep if Decomplex/SlopCop move down or a real bug was fixed
   - continue if only a partial deletion was made and the next deletion is clear
   - revert if complexity moved into new wrappers
6. Run targeted MIR lowering specs plus `bundle exec srb tc` after each
   retained change.
7. Update this doc with before/after numbers and the keep/revert decision for
   each method.

## Strong Type Rules

- No `T.untyped`.
- No compatibility readers for legacy ivars or loose hashes.
- Typed plan records must expose domain names, not generic `payload`,
  `metadata`, or `options` fields.
- If existing loose data cannot be typed, first reify that data at the source.

## Expected Payoff

Moderate to high. These functions are hot because they combine compiler phase
decisions with MIR construction. Removing one or two real mixed-responsibility
clusters should improve reports more than adding many line-coverage tests.

The highest value outcome is a shorter lowering method whose remaining branches
are actual language semantics, not plumbing around ownership, cleanup, or runtime
requirements.

## Scrap Criteria

Scrap a local extraction if:

- the target method keeps the same number of semantic decisions and just calls a
  helper for each one;
- a new plan object mirrors old local variables without deleting old state;
- SlopCop/Decomplex regress and there is no real bug fix;
- the change requires dual paths to preserve behavior.
