# Review: PipelineHost Boundary

## Scope

This reviews the architecture pressure around `PipelineHost`, especially
`substitute_placeholders` and the dynamic backchannel from the backend pipeline
host into MIR lowering internals.

Primary files:

- `src/backends/pipeline_host.rb`
- `src/backends/pipeline_rewriter.rb`
- `src/mir/mir_lowering.rb`

## Evidence

Espalier reports `PipelineHost` with:

- state slots: 22
- functions: 136
- delegation edges: 2130
- `substitute_placeholders` reads: 7
- `substitute_placeholders` always-called methods: 15
- `substitute_placeholders` conditionally-called methods: 64

`PipelineHost#substitute_placeholders` is a recursive AST clone/rewrite engine.
It reads host state such as:

- `@placeholder_name`
- `@acc_placeholder`
- `@join_param_map`
- `@named_bindings`
- `@soa_each_mode`
- `@soa_needed_fields`
- `@soa_rewrite_active`

The same host also reaches into `@lowering` through dynamic protocol calls such
as `send`, `instance_variable_get`, and `instance_variable_set`. Examples
include guarded cleanup names, runtime names, low-level emit helpers, and
shard/context state.

This makes `PipelineHost` both a backend rewrite coordinator and an internal
MIR lowering peer. That boundary is a likely source of unnecessary complexity.

## /plan

1. Extract `substitute_placeholders` into a dedicated
   `PipelinePlaceholderRewriter`.
2. Pass a small immutable context object into that rewriter:
   placeholder names, accumulator placeholder, join param map, named bindings,
   SOA mode, and needed SOA fields.
3. Keep `PipelineHost#substitute_placeholders` as a one-line delegate during
   migration so behavior stays identical.
4. Add focused tests for placeholder substitution covering:
   - identifier replacement,
   - join param replacement,
   - named binding replacement,
   - SOA field rewrite behavior,
   - metadata/type copying on cloned AST nodes.
5. Add a `PipelineLoweringAdapter` or explicit public lowering API for the
   MIR-lowering operations that `PipelineHost` currently reaches through with
   `send` and ivar access.
6. Replace dynamic `@lowering.send` / `instance_variable_get` /
   `instance_variable_set` calls one cluster at a time.
7. Regenerate Decomplex, NilKill, SlopCop, and Boobytrap after the rewriter
   extraction and after each adapter cluster.

## Easy Path Assessment

Yes. This is the clearest substantial simplification path in the reviewed set.

The placeholder rewriter extraction is localized. It does not require
redesigning pipeline semantics; it mostly moves an existing recursive transform
behind a narrower object with explicit inputs.

The lowering adapter is also incremental. The goal is not to rewrite
`PipelineHost`, but to replace dynamic backchannels with named protocol
methods.

## Downstream Payoff

Expected payoff is high:

- removes a large recursive branch cluster from `PipelineHost`
- makes placeholder substitution testable without constructing a whole host
- reduces dynamic calls that Sorbet, NilKill, and architecture analysis cannot
  reason about
- gives pipeline lowering a real API boundary
- should improve Boobytrap and SlopCop pressure around one of the persistent
  top uncovered hotspots

This is likely better ROI than adding many coverage tests directly against
`PipelineHost`.

## Risk

Risk is low to moderate for the placeholder rewriter and moderate for the
lowering adapter.

The rewriter must preserve AST metadata exactly. The adapter must avoid
inventing a broad facade that just mirrors all of `MIRLowering`; it should only
name the operations that `PipelineHost` actually needs.

## Recommendation

Do this before v0.1 if pipeline support is part of the v0.1 stability story.
Start with `PipelinePlaceholderRewriter`; it is the obvious easy win.

## Implementation Progress

Implemented in this pass:

- Extracted placeholder substitution into `PipelinePlaceholderContext` and
  `PipelinePlaceholderRewriter`.
- Replaced the `PipelineHost#substitute_placeholders` body with a typed
  delegate.
- Replaced added placeholder state types with concrete aliases:
  `PlaceholderMap` and `SoaFieldSet`.
- Removed `PipelineHost` calls to `@lowering.send(...)` and
  `T.unsafe(@lowering)` for the pipeline/MIR bridge. `MIRLowering` now
  explicitly publishes the existing lowering bridge methods with `public`.

Validation:

- `bundle exec srb tc`
- `bundle exec prspec spec/pipeline_backend_coverage_spec.rb`
- `bundle exec prspec spec/mir_lowering_spec.rb`

Metric evaluation:

- SlopCop moved in the right direction for the measured files:
  genuine gaps `221 -> 212`, dark arms `786 -> 714`.
- Decomplex is mixed:
  total `1550 -> 1552`, site findings `2045 -> 2030`,
  missing abstractions `34 -> 33`, neglected updates `429 -> 426`,
  broken protocols `421 -> 428`.
- The old `send` root-cause cluster disappeared, which is real architectural
  progress. The cost is that direct public bridge calls now show up as named
  protocol calls, especially around `stamp_allocating_result_target!`.

Assessment:

Worth keeping, but not complete. The placeholder extraction is clearly
worthwhile. The lowering bridge replacement is directionally correct because it
deletes dynamic dispatch, but decomplex shows it is only a boundary step; the
next worthwhile increment is to collapse the repeated allocation-mark protocol
behind one typed helper instead of repeatedly calling
`mir_allocates?` / `mir_owned_alloc` / `stamp_allocating_result_target!` /
`mir_alloc_mark_type_info` from `PipelineHost`.

## Follow-up Progress

Implemented after the broken-protocol review:

- Added `MIRLowering::PipelineAllocMarkFact` and
  `pipeline_alloc_mark_fact` so pipeline lowering requests a single allocation
  mark fact instead of spelling out the ownership/marking protocol at each
  site.
- Added coarse pipeline operations for owned cleanup entries and index-insert
  ownership consumption. `PipelineHost` no longer calls `mir_allocates?`,
  `mir_owned_alloc`, `hoist_cleanup_entry`, `mir_ident_names`, or
  `with_ownership_consumption` directly.
- Replaced two-step `MIR::AllocMark.new(...); mark.scope = ...` construction in
  the measured MIR/pipeline files with complete construction through the
  existing fourth constructor argument.
- Kept the implementation strongly typed; no added `T.untyped`.

Final measured snapshot for this increment:

- SlopCop genuine gaps: `221 -> 133`.
- SlopCop type/nil guard gaps: `255 -> 139`.
- Decomplex total candidates: `1550 -> 1374`.
- Decomplex site findings: `2045 -> 1842`.
- Cross-detector convergence: `305 -> 299`.
- Root-cause clusters: `91 -> 87`.
- Neglected updates: `429 -> 241`.
- Broken protocols did not close yet: `421 -> 440`.

Assessment:

This was still worth keeping because total candidates, convergence, site
findings, SlopCop genuine gaps, and the explicit `scope=` mutation protocol all
moved in the right direction. It did not reduce the raw broken-protocol count.
The remaining increase is from explicit helper operations such as
`pipeline_index_insert_with_ownership` and `pipeline_owned_cleanup_entry`.

Do not reintroduce direct primitive calls to improve the detector count. The
next legitimate cleanup would be deleting or merging those helper operations if
their semantics can be folded into one real pipeline materialization operation.
