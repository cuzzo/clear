# MIR Placement Architecture

This file is the contract for escape, placement, cleanup, lowering, and MIR verification. If code disagrees with this order, the code is wrong.

## Single Writers

- `node.storage` is expression-shape metadata. Annotation owns it. Rewriters and lowering adapters may only copy already-known storage onto synthetic nodes.
- `symbol.storage` is placement metadata. `src/mir/escape_analysis.rb` is the only writer.
- `CleanupEntry#alloc` is cleanup metadata. `src/mir/cleanup_classifier.rb` is the only writer.
- `CleanupEntry#scope` is frame-lifetime metadata. `src/mir/cleanup_classifier.rb` is the only writer. Valid values are `:iteration`, `:scope`, `:function`, and `:heap`.
- MIR lowering does not decide heap versus frame. It reads `SymbolEntry#storage` and `CleanupEntry#alloc`, emits `MIR::AllocMark`, `MIR::Cleanup`, `MIR::ErrCleanup`, and `MIR::TransferMark`, and leaves verification to `MIRChecker`.
- `MIR::Call#owned_return` is a structural ownership fact from lowering. If true, the call result must be bound with an `AllocMark` and cleanup/transfer, or the checker reports a leak.

## Required Pass Order

Top-level compilation and imported-module compilation must use the same ordering:

1. Parse.
2. Annotate. Types, symbols, call signatures, capture analysis, and expression storage are set here. Escape placement is not set here.
3. Rewrite annotated AST forms (`PipelineRewriter`, `StringConcatRewriter`). Rewrites must preserve types and expression storage on synthetic nodes.
4. Build `schema_lookup` from annotation and pass it into Hoist.
5. Hoist anonymous allocating expressions to named bindings. Hoist may ask only annotation-derived type questions (`Type.from_node`, `Type#heap_ptr?`, `Type#needs_explicit_cleanup?`) to decide whether an expression needs a binding. It does not choose heap versus frame.
6. `PreMirTypeCheck.verify!`. Every MIR-consumed node must have a non-nil type.
7. `MIRPass.transform!`.
8. Inside `MIRPass`, `EscapeAnalysis.apply!` runs first and writes `symbol.storage = :heap` for escaping bindings.
9. `CleanupClassifier.classify` runs after escape placement and writes cleanup entries.
10. `LoopFrameAnalysis.analyze!` runs after cleanup classification and uses finalized cleanup lifetime facts to mark loop rewinds.
11. MIR lowering reads finalized facts and emits checker-visible MIR markers.
12. `MIRChecker` verifies the lowered MIR. Any error aborts compilation.

## Escape Analysis

Escape analysis is an AST-bound sink walker. It does not build a value-flow graph and does not perform promotion. It marks the binding symbol heap when a binding reaches one of the language escape sinks:

- returned by an owning return;
- stored into an enclosing-scope or heap-owned destination;
- captured by a closure, fiber, or background block;
- passed to a `TAKES` or mutable parameter.

Every callable source must present the same typed signature contract before MIR:
`FunctionSignature` plus `AST::Param` entries for receiver mutability and argument
ownership. Escape analysis reads only that contract. MIR phases may not branch on
where a callable came from.

Hoist exists so escape analysis can mark bindings instead of recursively special-casing anonymous expressions. It must hoist anonymous allocating values in escape positions and in call arguments before escape analysis runs, preserving the existing ownership-consumption stamp (`was_moved`) on the replacement identifier.

## Frame Lifetime And Loop Rewind

Loop analysis is not an escape analysis. A loop is one repeated lexical scope boundary, only slightly different from an `IF`, `MATCH`, `WITH`, function body, closure, or background body: it may reuse the same frame arena across iterations if every frame allocation in that repeated scope dies before the next iteration begins.

The authoritative fact is per-binding cleanup lifetime:

- `:heap` means the value is heap-owned and loop rewind is irrelevant.
- `:iteration` means a frame value is born and dies inside one loop iteration.
- `:scope` means a frame value is born and dies at the current lexical scope exit.
- `:function` means a frame value must survive until function exit.

Cleanup classification writes this lifetime after escape placement. Loop analysis may only read this fact. It must not inspect method names, collection kinds, receiver roots, return shapes, or destination node classes to decide whether an allocation survives an iteration. Any code that asks "is this append/put/push?", "is this a map/list/set?", or "is this stored into an outer collection?" while deciding loop rewind is architecturally wrong.

The rule is deliberately mechanical:

- emit a loop save/restore when the loop contains direct frame cleanup entries whose scope is `:iteration`;
- do not emit a loop save/restore for direct frame cleanup entries whose scope is `:function`;
- fail in `MIRChecker` if a loop restore encloses any frame allocation whose cleanup scope is not `:iteration`;
- fail in `MIRChecker` if an iteration-scoped frame allocation appears in a loop body without a restore.

This makes every lifetime extension flow through the same upstream sink facts that escape analysis uses. Loops do not get a parallel exception system.

## MIR Checker

`MIRChecker` verifies structural facts only. It must fail compilation when:

- an allocation has no cleanup, errcleanup, destroy, or transfer marker;
- a cleanup or transfer has no allocation marker;
- an allocator-bearing operation has no target binding;
- an allocator-bearing operation targets a binding with no `AllocMark`;
- an owned-return function call is discarded, nested anonymously, or bound without a matching heap `AllocMark`;
- allocators disagree between operation, allocation, and cleanup;
- an allocating expression survives outside a direct `MIR::Let` init;
- opaque Zig calls hide ownership effects.
- a loop restore contains frame allocations not proven iteration-local;
- an iteration-local frame allocation appears in a loop with no restore.

The checker is not a placement decider. Any new checker rule must verify a finalized fact that earlier passes were required to emit.
