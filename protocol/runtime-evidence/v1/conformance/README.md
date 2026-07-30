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
