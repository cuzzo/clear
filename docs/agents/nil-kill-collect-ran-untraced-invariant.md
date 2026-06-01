# NilKill collect_ran_untraced Invariant

## Problem

`tools/nil-kill report --allow-stale-runtime` produced a hard
`collect_ran_untraced` failure for `src` targets. The report showed hundreds of
methods that were seen by coverage but missing NilKill trace observations.

## Diagnosis

This was a stale runtime/evidence problem, not evidence that the wrapper itself
was silently failing.

The runtime metadata pointed at an older commit, while current source line
numbers had moved. NilKill's instrumentation plan keys methods by file and line,
so stale line numbers meant methods could run under coverage while no longer
matching the wrapper plan.

Concrete example from the stale data:

- runtime trace plan still located `SemanticAnnotator#visit` at an older line
- current source had moved the method to a later line
- coverage could still see the current method, but the stale wrapper plan could
  not attach evidence to it

## Resolution

Regenerated the NilKill data without the stale-runtime override:

1. `NIL_KILL_TARGETS=src NK_JOBS=8 bundle exec tools/nil-kill collect -- bash tools/clear-nil-kill-runtime.sh`
2. `NIL_KILL_TARGETS=src bundle exec tools/nil-kill infer`
3. `NIL_KILL_TARGETS=src bundle exec tools/nil-kill report --output-path=gems/nil-kill/report.md`

The fresh report rendered cleanly and did not reproduce the
`collect_ran_untraced` hard failure.

## Follow-up

The invariant is useful and should stay hard. The operational lesson is that
`--allow-stale-runtime` should not be used for authoritative burndown reports
after source-moving refactors.

Potential tooling improvement:

- when `collect_ran_untraced` fires under `--allow-stale-runtime`, include the
  runtime commit, current commit, and a short explanation that file/line drift is
  the first thing to check.
