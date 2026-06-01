# Annotator Match and Pipe Architecture Plan

## Scope

Targets:

- `SemanticAnnotator#visit_MatchStatement`
- `PipeAnalysis#analyze_concurrent_op`

Primary files:

- `src/annotator/annotator.rb`
- `src/annotator/helpers/pipe_analysis.rb`

## Signal

`visit_MatchStatement` remains one of the largest annotator decision hubs even
after the scoped-state cleanup. It combines subject classification, ownership
consumption, pattern validation, payload binding, destructuring, exhaustiveness,
and expression typing.

`PipeAnalysis#analyze_concurrent_op` is smaller, but it is suspicious because it
acts like a protocol hub for concurrency behavior. If pipe/concurrent operation
facts stay loosely represented, downstream MIR and backend phases inherit that
complexity.

## Hypothesis

The likely win is to reify facts that cross phase boundaries:

- match subject facts
- match arm facts
- payload binding facts
- pipe operation facts
- concurrent operation effect/runtime facts

The previous scoped-state cleanup was worth keeping because it deleted open-coded
state lifetime management. The next pass should only proceed if it can delete
inline semantic classification or loose hash/array facts, not if it merely moves
visitor branches into private methods.

## /plan

1. Snapshot `decomplex`, `slopcop`, `boobytrap`, `nil-kill`, and `espalier`
   metrics for the annotator and pipe-analysis files.
2. For `visit_MatchStatement`, inventory facts that are computed and then passed
   implicitly through local variables, mutated AST fields, or ambient annotator
   state.
3. For `PipeAnalysis#analyze_concurrent_op`, inventory every output fact and
   identify whether callers consume typed facts or infer behavior again.
4. Implement the smallest typed fact object that deletes a real loose protocol.
   Prefer one of:
   - `MatchSubjectFacts`
   - `MatchPayloadBindingPlan`
   - `PipeConcurrentOpFacts`
5. Migrate all consumers to the new typed fact in the same change. Delete the old
   local/raw protocol immediately.
6. Add focused tests only for behavior that could be wrong:
   - generic union payload substitution
   - MATCH TAKES ownership consumption
   - indirect payload binding/destructuring
   - concurrent pipe operation runtime/effect facts
7. Regenerate metrics after each retained change and record whether the work was
   worthwhile, needs another deletion to become worthwhile, or should be
   reverted.

## Strong Type Rules

- No added `T.untyped`.
- No untyped hashes for match arms, payload bindings, or pipe facts.
- No compatibility path between old local protocols and new fact records.
- Any new object must be the authoritative representation for the facts it owns.

## Expected Payoff

Moderate. `visit_MatchStatement` is compiler-critical and may not collapse
dramatically because real language semantics live there. The payoff is strongest
if the work exposes or fixes ownership/payload bugs and gives downstream phases
typed facts instead of forcing them to rediscover intent.

`PipeAnalysis#analyze_concurrent_op` may have a higher ratio of payoff to risk
if it can replace a loose operation protocol with one typed result used by MIR.

## Scrap Criteria

Scrap if:

- the change primarily adds test-only coverage without catching a real behavior
  risk;
- match analysis gains new wrapper methods but keeps the same loose locals;
- pipe facts are represented twice;
- metrics regress and no correctness bug was fixed.
