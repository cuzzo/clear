# Review: Capability, WITH, and Concurrency Lowering

## Scope

This reviews the architecture pressure around capability lowering and
concurrency lowering, especially `lower_with_block`, `lower_bg_block`, and
`lower_bg_stream_block`.

Primary files:

- `src/mir/lowering/capabilities.rb`
- `src/mir/lowering/concurrency.rb`
- `src/annotator/annotator.rb`
- `src/annotator/helpers/capabilities.rb`

## Evidence

Espalier reports:

- `MIRLoweringCapabilities#lower_with_block`
  - writes: 7
  - always-called methods: 45
  - conditionally-called methods: 48
- `MIRLoweringConcurrency#lower_bg_block`
  - reads: 2
  - writes: 5
  - always-called methods: 60
  - conditionally-called methods: 51
- `MIRLoweringConcurrency#lower_bg_stream_block`
  - reads: 1
  - writes: 6
  - always-called methods: 38
  - conditionally-called methods: 21

`lower_with_block` mixes several concerns:

- capability family dispatch
- lock acquisition ordering
- fallible lock clauses
- alias maps
- RC unwrap maps
- guarded cleanup state
- snapshot/versioned/atomic family handling
- string-level Zig emission details
- MIR node construction

`lower_bg_block` is also large, but it already has better internal seams than
`lower_with_block`: capture analysis, `FiberCtxBuilder`, FSM transform fallback,
body lowering, boundary facts, and stackful fiber emission are distinguishable.

## /plan

1. Do not start with a broad rewrite of WITH or BG lowering.
2. Extract read-only plan/fact objects first:
   - `WithBlockLoweringPlan`
   - `WithCapabilityPlan`
   - `BgBoundaryPlan` or `FiberBoundaryPlan`
3. Build those plans from already-annotated AST facts. The plan objects should
   describe what must be emitted, not emit it themselves.
4. Move branchy classification code into plan builders while leaving final MIR
   and Zig emission in the existing lowering methods.
5. Add golden lowering tests for representative safety-sensitive cases:
   - exclusive lock with release,
   - fallible lock with ON/RETRY,
   - snapshot read,
   - snapshot mutable transaction,
   - atomic pointer snapshot,
   - BG capture by value,
   - BG promoted pointer capture,
   - BG stream eager and runtime paths.
6. Regenerate reports after each extraction. Keep only changes that lower
   complexity or make real coverage gaps cheaper to close.

## Easy Path Assessment

There is a partial easy path, but not a safe broad easy path.

The easy path is extracting plans/facts. That can reduce local branch density
and make the lowering contracts auditable. A full semantic rewrite would be
too risky because this area encodes synchronization, transactional mutation,
runtime threading, and fiber capture safety.

## Downstream Payoff

Expected payoff is substantial if the extraction stays fact-oriented:

- makes annotator-to-lowering contracts explicit
- reduces duplicated family checks across WITH handling
- makes lock/snapshot/atomic paths easier to test independently
- creates a stable place for future deadlock and transaction invariants
- makes BG lowering less dependent on mutable ambient state

This area can also produce real bug finds, because mismatches between
annotator facts and lowering behavior are high-impact.

## Risk

Risk is high for semantic rewrites and moderate for plan extraction.

The main failure mode is adding a parallel abstraction without deleting branch
surface from the old path. That would repeat the failed CodeQL lesson: more
code, more paths, little payoff.

## Recommendation

Do not try to fully fix this area in one pass before v0.1.

Do a narrow pre-v0.1 extraction only where it directly clarifies safety
contracts:

- WITH capability acquisition/alias facts
- BG boundary capture facts

If those plan objects do not let us delete branchy classification code from the
lowering methods, stop and cut the loss.

