# Annotator Fact-Flow Burndown Postmortem

## What Happened

The fact-flow burndown round used `tools/fact_flow_audit.rb` to identify repeated state checks in `src/annotator`, then attempted to simplify several clusters at once:

- repeated `emit&.` checks
- repeated capability symbol/type normalization
- duplicated reentrance return-type edit logic
- repeated pipe-analysis type/shape checks
- repeated `WITH` block function/arm facts

The batch removed several local fact-flow clusters, but the first regenerated SlopCop result moved the primary acceptance metric in the wrong direction:

- genuine gaps increased
- type_norm increased
- annotator fact-flow genuine increased

That is not acceptable for this task.

## Root Cause

The work optimized for a proxy signal instead of the acceptance metric.

`fact_flow_audit` is useful for finding repeated fact checks, but removing repeated checks does not automatically reduce uncovered branch arms. Several changes converted compact safe-navigation or inline type checks into explicit `if`/helper control flow. That can improve local readability while increasing measurable branch surface.

Example bad trade:

```ruby
method_def.emit&.zig
method_def.emit&.allocates
```

became explicit state:

```ruby
emit = method_def.emit
if emit
  ...
end
```

That adds an explicit branch. If coverage does not hit both paths, SlopCop can classify the new uncovered arm as genuine or type_norm. This is the opposite of the goal unless the branch is already covered, deleted, or cheaply covered.

## Process Failure

The plan said to work one item at a time and measure after each. Instead, multiple source changes were batched before full metrics were regenerated. That made attribution difficult after the metrics regressed.

The first post-revert comparison was also invalid because the regenerated coverage corpus omitted fuzz coverage. The saved snapshot had a much larger resultset. After running the five fuzz coverage shards, the regenerated reports became comparable again.

## Final Disposition

The metric-negative annotator source changes were reverted.

The retained source change is only the independent Sorbet fix:

```ruby
@capture_move_suppressed = T.must(@capture_move_suppressed) - 1
```

The new tool is still useful as an audit lens, but it must not be treated as the success metric. SlopCop genuine/type_norm counts remain the acceptance gate.

## Rules Going Forward

1. Pick one candidate.
2. Snapshot reports and coverage resultset metadata.
3. Make the smallest source or test change.
4. Regenerate the full coverage corpus, including fuzz coverage.
5. Regenerate SlopCop, Decomplex, and Boobytrap.
6. Keep the change only if genuine/type_norm improve or source branch count clearly drops without creating new uncovered arms.
7. Revert immediately if the primary metrics regress.

## Lesson

Fact normalization is not automatically simplification. For this project, a change is only simplification if it reduces source branch surface or makes existing real branches cheaper to cover without creating new uncovered arms.
