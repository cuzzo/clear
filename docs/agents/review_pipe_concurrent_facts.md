# Review: Pipe Concurrent Facts

## Scope

Targets:

- `PipeAnalysis#analyze_concurrent_op`
- related bounded/stream select-family helpers

Primary file:

- `src/annotator/helpers/pipe_analysis.rb`

## Evidence

Current report overlap:

- Decomplex ranks `analyze_concurrent_op` near the top of convergence.
- Espalier ranks it as a conditional delegation hub.
- Decomplex Missing Abstractions finds the repeated
  `AST::SelectOp | AST::WhereOp` operation family across concurrent pipe
  helpers.

## /plan

1. Snapshot Decomplex and SlopCop for `pipe_analysis.rb`.
2. Identify the facts emitted by `analyze_concurrent_op` and where downstream
   helpers recompute operation-family decisions.
3. Introduce a strongly typed concurrent pipe fact only if it replaces repeated
   case dispatch in all relevant helpers.
4. Delete the old inline family tests in the same change.
5. Run pipe/concurrent annotator specs and `bundle exec srb tc`.
6. Regenerate metrics. Keep only if Decomplex and SlopCop improve or a real bug
   was fixed.

## No-Partial Rule

No parallel fact object beside old local hashes or repeated case dispatch. The
new fact must be the only representation for the operation-family decision it
owns.

## Expected Payoff

Moderate. The item is smaller than Type or MIR ownership work, but the repeated
operation-family decision looks concrete enough to attempt.

