# PipelineHost Refactor Design

This is the working design and progress log for turning `PipelineHost` from a
large mutable backend coordinator into a typed pipeline lowering architecture.
Loop back to this document after each migration slice and each metrics run.

## Current Signals

Baseline inputs are the current reports plus the local before/after artifacts
from the previous narrow migration:

- Decomplex: `PipelineHost` remains the top temporal ordering owner with an
  implicit lifecycle score of `15534`.
- Espalier: `PipelineHost` is the #2 state owner pressure item, with 22 state
  slots, 131 methods, 114 state touches, and broad delegation.
- Espalier: `@lowering` in `PipelineHost` is the #2 lifecycle-pressure state
  slot. It exposes a wide protocol: `lower`, `lower_body`, `emit_expr`,
  `emit_builtin`, `pipeline_alloc_mark_fact`, `mir_schema_lookup`,
  `pipeline_index_insert_with_ownership`, `pipeline_owned_cleanup_entry`,
  `task_config_zig`, `with_fiber_capture_map`, and raw ivar access.
- SlopCop: `PipelineHost#lower_concurrent` is a top genuine coverage gap and
  structural deviance hotspot.
- Boobytrap: `src/mir/lower/pipeline/pipeline_host.rb` is the #3 defect-risk hotspot.
- Nil-kill: current report points at `PipelineHost` weak/untyped slots such as
  heterogeneous AST node params, weak hash chain records, and broad untyped
  forwarded returns. Final nil-kill recollection is expensive, so use static
  guardrails and source inspection during slices, then recollect at the end.

## Target Architecture

`PipelineHost` should become a small coordinator:

1. Decode the top-level pipeline operation into a typed plan.
2. Hold a typed context stack for placeholder, accumulator, named-binding,
   shard-direct, and SOA rewrite state.
3. Expose a narrow typed services object to lowerers.
4. Delegate whole pipeline domains to typed lowerer objects.
5. Consume typed pipeline/source/range/concurrency facts instead of
   rediscovering those facts in branch hubs.

The backend-facing lowerers should be domain objects, not mixed-in method piles:

- `PipelineServices`: the narrow API for MIR lowering, emission, allocation
  facts, cleanup facts, labels, type translation, and context scoping.
- `PipelineContextState`: typed stack-owned state for placeholder substitution
  and shard/SOA context.
- `PipelineMaterializer`: source evaluation and list/item materialization.
- `PipelineRangeLowerer`: range/stream chain detection, lazy range prefixes,
  range folds, range reduce, stream index, and each-range.
- `PipelineObservableLowerer`: observable terminal scaffolds and publish
  plans.
- `PipelineBatchWindowLowerer`: batch-window plans for Zig/BC/open/bounded
  stream shapes.
- `PipelineEachLowerer`: each/sharded/SoA/pool/list/set iteration plans.
- `PipelineConcurrentLowerer`: concurrent source classification and runtime
  call construction.
- `PipelineScalarLowerer`: count/sum/average/min/max/any/all/find and simple
  filter/transform list operators.

This is not an always-green compatibility migration. Each slice should delete
the old owner path first, observe failures, then rebuild the new typed path.

## Acceptance Criteria

- PipelineHost Decomplex temporal ordering pressure must materially drop.
- PipelineHost Espalier state owner pressure must materially drop.
- SlopCop PipelineHost genuine gaps must drop, especially around
  `lower_concurrent` and other branch hubs touched by the migration.
- Final nil-kill recollection must show no increase in untyped slots; strongly
  typed replacements should decrease weak hash records and untyped slots where
  this migration touches them.
- 100% of added/changed source lines are covered.
- 100% of added/changed branches are targeted for coverage; minimum accepted
  branch coverage is roughly 80%, but the goal is 100% for this migration.
- New code must be strongly typed. Do not add `T.untyped` signatures or weak
  hash records.
- If downstream or upstream signatures can be strengthened because a typed
  pipeline record exists, propagate the stronger type.

## Migration Slices

### Slice 1: Typed Context And Services

Replace the legacy ambient `PipelineGenerator#with_pipeline_context` mutation
with typed state owned by `PipelineHost`.

Expected effect:

- Fewer direct mutable state transitions in `PipelineHost`.
- Delete the untyped generator context API instead of migrating it forward.
- Clearer boundary for lowerers: context enters through `PipelineServices`.

### Slice 2: Materializer Extraction

Move source evaluation, source cleanup, pipe item materialization, allocator
selection, and append ownership transfer handling out of `PipelineHost`.

Expected effect:

- Lower `PipelineHost` method count and delegation count.
- Isolate `@lowering.pipeline_alloc_mark_fact` behind one services method.
- Strengthen materializer return types from arrays/hashes to typed structs.

### Slice 3: Range And Observable Plan Extraction

Move `RangeChain`, `LazyRangePrefix`, range fold/reduce, stream index,
each-range, and observable terminal scaffolding into typed lowerers.

Expected effect:

- Delete weak hash range-chain records.
- Remove many `PipelineHost` branch sites and temporal state reads.
- Move observable producer/consumer setup into explicit plan records.

### Slice 4: Batch Window Extraction

Move batch-window source classification, timeout parsing, setup, push, flush,
and BC/Zig source-specific branches into a dedicated lowerer.

Expected effect:

- Reduce branch pressure in `lower_batch_window`.
- Convert batch-window element/source decisions into typed plan variants.

### Slice 5: Each And Concurrent Extraction

Move each/sharded/SoA/pool/list/set iteration and concurrent source/op
classification into dedicated lowerers.

Expected effect:

- Attack SlopCop's `lower_concurrent` hotspot directly.
- Replace large `case`/`if` hub with typed dispatch plans.
- Narrow direct use of `@lowering` in worker callback construction.

### Slice 6: Final Boundary Tightening

Delete remaining weak helper signatures and cross-boundary untyped return paths
enabled by the extraction.

Expected effect:

- Nil-kill untyped slots stay flat or decrease.
- No new weak hash records.
- `PipelineHost` becomes mostly a dispatcher and services owner.

## Progress Log

- Baseline snapshot for expanded scope:
  - Decomplex report: `/tmp/pipeline-refactor-decomplex-before.md`
  - Decomplex JSON: `/tmp/pipeline-refactor-decomplex-before.json`
  - SlopCop focused report: `/tmp/pipeline-refactor-slopcop-before.md`
  - Decomplex total: `7458`
  - Decomplex `PipelineHost` temporal ordering score: `15534`
  - SlopCop focused `PipelineHost` genuine gaps: `58`
- Slice 1 complete: typed pipeline context replaces the legacy ambient
  generator state in `PipelineHost`.
  - Sorbet: `bundle exec srb tc` passed.
  - Focused specs: `bundle exec rspec spec/pipeline_backend_coverage_spec.rb`
    passed.
  - Decomplex owner pressure improved materially:
    - `PipelineHost` temporal ordering score: `15534 -> 9388`
    - state fields: `22 -> 12`
    - shared fields: `19 -> 9`
    - state methods: `43 -> 42`
  - SlopCop focused signal improved directionally:
    - genuine gaps: `58 -> 39`
    - dark arms: `471 -> 113`
    - caveat: this is directional until full coverage is regenerated because
      line shifts can make existing resultsets stale.
  - Decomplex line-insensitive total debt grew slightly: `7458 -> 7475`.
    New helper/accessor sites inside the same owner added small local findings
    even though temporal ordering pressure dropped. This is the key loop-back
    rule for the remaining work: future slices must remove whole
    responsibilities from `PipelineHost`, not merely make internal state safer.
- Slice 2 complete: source/item materialization moved to
  `PipelineMaterializer`, with a typed runtime host adapter and narrow private
  delegation methods in `PipelineHost`.
  - Sorbet: `bundle exec srb tc` passed.
  - Focused specs: `bundle exec rspec spec/pipeline_backend_coverage_spec.rb`
    passed.
  - Architecture guards: `bundle exec rspec spec/architecture_invariants_spec.rb`
    passed.
  - Decomplex owner pressure improved:
    - `PipelineHost` temporal ordering score: `9388 -> 8776` after extraction.
    - After narrowing the public helper surface, `PipelineHost` is no longer
      listed in the Temporal Ordering Pressure section.
    - `src/mir/lower/pipeline/pipeline_host.rb` detector spread dropped from 91 to 84
      method units.
  - SlopCop focused signal improved versus slice 1:
    - genuine gaps: `39 -> 27`
    - caveat: still directional until full coverage is regenerated.
  - Loop-back lesson: direct `@materializer` reads inside many operator methods
    initially increased temporal pressure. The correct shape is a private
    host boundary with only a few materializer-touching helpers.
- Slice 3 complete: placeholder/context state and AST placeholder rewriting moved
  to `PipelineContextState` / `PipelinePlaceholderRewriter`.
  - Sorbet: `bundle exec srb tc` passed.
  - Focused specs: `bundle exec rspec spec/pipeline_backend_coverage_spec.rb`
    passed.
  - Architecture guards: `bundle exec rspec spec/architecture_invariants_spec.rb`
    passed.
  - Decomplex global counts stayed flat after this slice:
    - total candidates: `8109 -> 8109`
    - convergence: `1888 -> 1888`
    - `src/mir/lower/pipeline/pipeline_host.rb` detector spread: `74 -> 59`
  - SlopCop focused signal moved sideways because stale branch coverage shifted
    uncovered arms into `visit`/range rows:
    - genuine gaps: `27 -> 29`
  - Loop-back lesson: extracting a pure state/rewriter owner is
    architecturally correct and shrinks PipelineHost, but it is not enough.
    SlopCop now points at the larger range/observable/concurrent clusters.
- Slice 4 partial: range chain detection, lazy range prefix construction,
  range `EACH`, and BC range iteration moved to `PipelineRangeLowerer`.
  Weak `{source:, stages:}` range-chain hashes were replaced with
  `PipelineRangeChain`.
  - Sorbet: `bundle exec srb tc` passed.
  - Focused specs: `bundle exec rspec spec/pipeline_backend_coverage_spec.rb`
    passed.
  - Host-level signal improved materially:
    - `src/mir/lower/pipeline/pipeline_host.rb` detector spread: `59 -> 55`
    - SlopCop focused genuine gaps: `29 -> 18`
  - Global Decomplex moved the wrong way:
    - total candidates: `8109 -> 8146`
    - convergence: `1888 -> 1894`
    - root-cause clusters: `585 -> 588`
  - Loop-back lesson: this was a good host boundary and nil-kill contract
    improvement, but `PipelineRangeLowerer` now owns branch-heavy policy. The
    next slice must structure observable/fold policy, not merely move more
    branch hubs into the new file.
- Active: Slice 4 continuation, observable/fold policy extraction inside the
  range lowerer.
- Slice 4 continuation checkpoint: observable terminal scaffolding moved from
  `PipelineHost` into `PipelineRangeLowerer`.
  - Sorbet: `bundle exec srb tc` passed.
  - Focused specs: `bundle exec rspec spec/pipeline_backend_coverage_spec.rb`
    passed.
  - Architecture guards: `bundle exec rspec spec/architecture_invariants_spec.rb`
    passed.
  - Host-local signal improved:
    - `src/mir/lower/pipeline/pipeline_host.rb` detector spread: `55 -> 53`
    - SlopCop focused genuine gaps: `18 -> 15`
  - Global Decomplex regressed:
    - total candidates: `8146 -> 8158`
    - convergence: `1894 -> 1900`
    - `src/mir/lower/pipeline/pipeline_range_lowerer.rb` spread: `9 detectors / 6 methods -> 10 detectors / 13 methods`
  - Loop-back decision: this is not complete. The observable code is in a
    better architectural owner, but the branch-heavy terminal policy is still
    encoded as lowerer control flow. Continue Slice 4 by extracting scalar
    fold/reduce plans into typed plan objects and small builder methods, then
    remeasure before touching concurrency.
- Slice 4 fold-plan checkpoint: range scalar fold/reduce moved from
  `PipelineHost` into typed `PipelineRangeFoldNames` /
  `PipelineRangeFoldPlan` builders inside `PipelineRangeLowerer`.
  - Sorbet: `bundle exec srb tc` passed.
  - Focused specs: `bundle exec rspec spec/pipeline_backend_coverage_spec.rb`
    passed, with direct tests for count/sum/average/min/max/any/all/find,
    observable dispatch, and BC suffixing.
  - Architecture guards: `bundle exec rspec spec/architecture_invariants_spec.rb`
    passed.
  - Host-local signal improved:
    - Decomplex no longer reports the host range fold body as the range-fold
      convergence site; that moved to `PipelineRangeLowerer#scalar_fold_plan`.
    - SlopCop focused dark arms: `75 -> 59`.
  - Mixed global signal:
    - total candidates improved from observable checkpoint: `8158 -> 8143`.
    - convergence worsened slightly: `1900 -> 1902`.
    - `PipelineRangeLowerer` now has `10 detectors / 20 methods`, so it is a
      better owner but still needs a later split between range prefix,
      fold-plan, and observable consumer policy.
  - Loop-back decision: proceed to Slice 5. The highest remaining PipelineHost
    risk is concurrent lowering: `lower_concurrent`, bounded callback builders,
    stream/list concurrent helpers, and BC concurrent simulation dominate
    SlopCop and Decomplex.
- Package boundary checkpoint: MIR pipeline lowering moved from `src/backends`
  to `src/mir/lower/pipeline`.
  - Moved MIR lowerers:
    - `pipeline_host.rb`
    - `pipeline_context.rb`
    - `pipeline_materializer.rb`
    - `pipeline_range_lowerer.rb`
    - `pipeline_batch_window_lowerer.rb`
    - `pipeline_concurrent_lowerer.rb`
    - `pipeline_set_index_lowerer.rb`
    - `pipeline_each_lowerer.rb`
  - Kept `src/backends/pipeline_rewriter.rb` in `backends` because it is the
    AST rewrite/fusion pass before MIR lowering, not a MIR lowerer.
  - Deleted legacy `src/backends/pipeline_generator.rb`; production had already
    stopped using it, and only the stale test harness kept it alive.
  - The move exposed old regex/text-rewrite sites to the MIR guardrail. Those
    are now typed helpers:
    - batch-window timeout parsing no longer uses a regex.
    - observable type-prefix normalization no longer uses regex substitution.
    - observable body identifier replacement now uses an identifier-boundary
      scanner rather than regex-based text rewriting.
  - Verification:
    - `bundle exec srb tc` passed.
    - `bundle exec rspec spec/pipeline_backend_coverage_spec.rb` passed.
    - `bundle exec rspec spec/architecture_invariants_spec.rb` passed.
    - `bundle exec rspec spec/observable_pipe_dest_spec.rb` passed.
    - `bundle exec rspec spec/mir_lowering_spec.rb:3743` passed.
  - Metrics:
    - Decomplex report: `/tmp/pipeline-refactor-decomplex-reorg.md`
    - Decomplex JSON: `/tmp/pipeline-refactor-decomplex-reorg.json`
    - Decomplex total: `7493`
    - Decision Pressure: `294`
    - State Heatmap: `592`
    - State-Based Branch Density: `1582`
    - Temporal Ordering Pressure: `14`
    - Cross-Detector Convergence: `1911`
    - Root-Cause Clusters: `576`
    - SlopCop focused report: `/tmp/pipeline-refactor-slopcop-reorg.md`
    - SlopCop focused result, with fresh targeted coverage for the moved path:
      `130` dark arms, `11` genuine gaps.
  - Loop-back decision: the package boundary is now correct. Continue attacking
    host-owned binding and service-builder gaps before starting the final
    nil-kill recollection.
- Full-repo Decomplex loop-back after the first reorg cleanup:
  - Decomplex report JSON: `/tmp/decomplex-after-pass5-repo.json`
  - Full-repo total is still `18372 -> 18398` (`+26`), so the reorg is not
    yet a metric win even though nil-kill dark arms improved.
  - The loss is not caused by the new package boundary itself. It is caused by
    moved code reappearing as many fresh small protocol sites:
    - `PipelineConcurrentLowerer#lower_sharded_each` repeats the bounded
      callback protocol (`ctx_name`, `ctx_var`, task config, batch/parallel,
      worker count, callback context statements).
    - `PipelineSetIndexLowerer#build_index_gop_body` mixes value ownership,
      allocation facts, cleanup registration, and insert ownership in one
      branch-heavy body.
    - `PipelineRangeLowerer#lower_each_range` and
      `#range_accumulating_block` rederive BC/runtime/range loop shape in
      separate sites.
    - `PipelineMaterializer#items_setup` still rechecks collection shape with
      repeated `Type` predicates instead of consuming one typed source-shape
      decision.
    - Coverage fixture adapters still expose a few fake mutable owners that
      Decomplex counts as protocol/temporal pressure.
  - Direction for the completion pass:
    1. Introduce typed plan records for concurrent callback invocation,
       index value preparation, and range loop shape.
    2. Move duplicated guard expressions into single typed predicates/builders
       on those records.
    3. Keep lowerers as the owner; do not move this code back into
       `PipelineHost`.
    4. Remeasure after each substantial slice; stop only when the full-repo
       Decomplex delta is decisively below the pre-refactor baseline.
- Completion pass checkpoints:
  - Concurrent invocation record:
    - `PipelineConcurrentLowerer#lower_sharded_each`: `20 -> 7` findings.
    - Full-repo Decomplex: `18398 -> 18387`.
    - Lesson: helper methods on the invocation record were worse than fields;
      precomputed typed data kept the call sites small without adding public
      mini-protocol methods.
  - Index prepared-value plan:
    - `PipelineSetIndexLowerer#build_index_gop_body`: `19 -> 1`.
    - Full-repo Decomplex: `18387 -> 18362`.
    - The important fix was separating value ownership preparation from map
      insertion ownership, which removed the large neglected-path tuple.
  - Shared BC range-loop iterator:
    - `PipelineRangeLowerer#lower_each_range`: `16 -> 3`.
    - Full-repo Decomplex: `18362 -> 18348`.
    - The range/fold lowerers now consume the same typed BC iterator decision
      instead of rederiving range literal vs runtime stream shape.
  - Materializer item kind:
    - `PipelineMaterializer#items_setup`: `9 -> 0`.
    - Full-repo Decomplex: `18348 -> 18342`.
    - Collection-shape policy now has an explicit item-kind classification.
  - Runtime stream storage element type:
    - `PipelineSetIndexLowerer#index_stream_element_type`: `6 -> 2`.
    - `PipelineBatchWindowLowerer#batch_element_type`: `3 -> 1`.
    - Full-repo Decomplex: `18342 -> 18328`.
    - This is a real Type abstraction, not a lowerer workaround. It preserves
      existing batch-window bounded-optional behavior by keeping
      `stream_element_type` on that path.
