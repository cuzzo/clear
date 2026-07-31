# Runtime evidence v1 executable conformance

This directory is the shared executable specification between FactMine and
runtime collectors.

The three required test layers consume the same capability catalog:

1. **FactMine oracle** overlays canonical evidence described by the catalog
   onto FactMine's normalized CFG/DFG and checks the exact joined result.
2. **Collector oracle** executes each fixture with a real collector and checks
   that every requested evidence kind is either present or has an explicit
   protocol status and reason.
3. **End-to-end oracle** generates the plan with FactMine, collects with the
   runtime provider, validates the wire bundle with FactMine, and consumes it
   as runtime SCIP.

Fixture expectations describe observations only. They never ask a collector
to derive source identities, control flow, data flow, or complexity. Those
remain FactMine responsibilities.

`capabilities.yml` is language-neutral. A language implementation supplies
the source and driver named by its `fixture` entry. The first implementation
is Ruby; Python, JavaScript/TypeScript, and PHP must reuse the same capability
IDs and expectation vocabulary.

The core invariant is:

> For every anchor executed in a modeled run, every requested evidence kind
> is present in every applicable execution bucket, or the capture is
> non-complete with a precise reason. `NOT_EXECUTED` is complete negative
> evidence only when the anchor did not execute in that run.

The suite includes negative controls, so an empty trace or a collector that
silently omits an executed anchor cannot pass.

## Ownership contract

FactMine owns all source semantics. It parses source, constructs normalized
CFG/DFG facts, selects exact anchors, supplies the complete executable range
for every call anchor, requests evidence kinds, and joins validated evidence.
An executable range must contain its selector and, for calls with attached
callbacks, the complete callback expression.

A collector may use those opaque anchors and ranges only to observe execution.
It records values, targets, results, provenance, exceptions, and counts. It
must not parse source to infer receivers, assignments, local ownership,
callbacks, control flow, data flow, or complexity.

Every anchor kind has a closed set of legal evidence kinds in
`wire_matrix.request_contracts`. FactMine rejects incompatible requests before
collection begins.

The wire enum deliberately reserves `STATE_READ` and `CALLBACK_ENTRY`, but the
v1 FactMine planner does not emit them: state values are requested at writes,
and callback parameter flow is derived by FactMine from call/collection
evidence. `wire_matrix.planner_anchor_kinds` is the executable planner surface;
`reserved_anchor_kinds` records the exact non-emission contract. A future
planner change must move a kind between those sets and add a real collector
fixture in the same commit. This prevents a protocol enum from being mistaken
for a silently unsupported collector request.

## Completeness semantics

- `COMPLETE_FOR_RUNS` means every requested kind is present in every
  applicable execution bucket and no execution was dropped.
- `NOT_EXECUTED` means the exact anchor did not execute in the declared runs.
  Its empty result is complete negative evidence; entering the enclosing
  function or covering the same line does not prove that the anchor executed.
- `PARTIAL` may name only the evidence kinds actually complete in every
  retained bucket. A call that raised after its receiver and target were
  observed, but before a requested result existed, is the canonical example.
- Every other non-complete status requires a precise reason and cannot silently
  publish missing fields as facts.
- A normal return of `nil` or `false` is an observed return. A function that
  raises before its return anchor is `NOT_EXECUTED` at that return anchor.
- Non-production replacements remain observable evidence but can never be
  published by FactMine as production call targets. Mixed production and test
  executions preserve the production target without allowing the replacement
  to poison or masquerade as it.

Exact anchor symbols participate in observation identity and deduplication.
Two calls to the same selector on the same source line remain distinct. A
collector correlation is accepted only when the provider genuinely cannot
produce exact identity; exact execution ranges remove that ambiguity for the
Ruby collector.
