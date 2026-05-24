# MIR Placement Architecture

This file is the contract for escape, placement, cleanup, lowering, and MIR verification. If code disagrees with this order, the code is wrong.

## Major MIR Stages

MIR compilation is a sequence of authority handoffs. A later stage may verify or consume facts from an earlier stage, but it may not rediscover or silently repair them.

1. **AST Hoist**
   Runs before escape analysis. It turns anonymous allocating AST expressions in escape-relevant positions into named bindings so escape analysis can mark symbols, not expression nodes. It preserves annotation facts and does not choose heap versus frame.

2. **Escape Analysis**
   Runs on the annotated/hoisted AST. It is a simple sink walker and the only writer of `symbol.storage`. It marks a binding heap when the binding reaches a language escape sink: owning return, enclosing/heap store, closure/fiber/background capture, or `TAKES`/mutable parameter flow.

3. **Cleanup Classification**
   Runs after escape placement. It is the only writer of cleanup entries and cleanup lifetime scope. It reads placement and type facts, then records how a binding must be cleaned and how long its frame allocation must live.

4. **Loop Frame Analysis**
   Runs after cleanup classification. It reads cleanup lifetime facts and marks loop frame save/restore requirements. It does not inspect container kinds, method names, or storage destinations to infer lifetime.

5. **MIR Lowering**
   Converts finalized AST facts into MIR. It emits structural calls, `AllocMark`, `Cleanup` / `ErrCleanup`, `TransferMark`, and `MoveMark` from already-finalized placement and cleanup data. It does not decide heap versus frame.

6. **MIR Allocation Normalization**
   Runs inside lowering before ownership finalization for each lowered statement body. It recursively removes allocation-producing expressions from non-owning expression positions by hoisting them to named MIR bindings. Allocation-producing result chains are allowed only where a binding owns the result, such as a `Let` init that must preserve `try` / `catch` semantics. This is the only MIR stage allowed to walk expression trees to rewrite ownership shape.

7. **MIR Ownership Finalization**
   Emits ownership transfer events from normalized MIR. At this point decisions are mechanical: named owned values are either cleaned, transferred, or rejected later by the checker. This phase must not compensate for missing placement, missing cleanup entries, or unnormalized allocation shape.

8. **MIR Checker**
   Verifies the finalized MIR and aborts compilation on any fact it cannot prove memory safe. It never decides placement, invents cleanup, infers implicit ownership transfer, or accepts opaque allocator effects.

## Single Writers

- `node.storage` is expression-shape metadata. Annotation owns it. Rewriters and lowering adapters may only copy already-known storage onto synthetic nodes.
- `symbol.storage` is placement metadata. `src/mir/escape_analysis.rb` is the only writer.
- `CleanupEntry#alloc` is cleanup metadata. `src/mir/cleanup_classifier.rb` is the only writer.
- `CleanupEntry#scope` is frame-lifetime metadata. `src/mir/cleanup_classifier.rb` is the only writer. Valid values are `:iteration`, `:scope`, `:function`, and `:heap`.
- MIR lowering does not decide heap versus frame. It reads `SymbolEntry#storage` and `CleanupEntry#alloc`, emits `MIR::AllocMark`, `MIR::Cleanup`, `MIR::ErrCleanup`, and `MIR::TransferMark`, and leaves verification to `MIRChecker`.
- `MIR::Call#owned_return` is a structural ownership fact from lowering. If true, the call result must be bound with an `AllocMark` and cleanup/transfer, or the checker reports a leak.
- `MIR::CallableContract` is the only representation for structural call ownership effects. It carries the typed `FunctionSignature`, the checked user-level argument count, and a typed `MIR::OwnershipContract` with concrete consumed binding names for this callsite. `covers_consuming_params` must be true whenever a TAKES slot was examined, even if the actual argument is a value type and no owned binding is consumed. A structural call without it is invalid MIR.
- `MIR::OwnershipContract` is the only representation for opaque Zig ownership effects. It is a strongly typed, non-nil contract with frozen `consumes`, `produces`, and `borrows` arrays plus `covers_consuming_params`. Hashes, nils, and ad-hoc side channels are invalid MIR.
- `MIR::ErrCleanup` is legal only with a matching `MIR::TransferMark`. `ErrCleanup` means ownership transfers on success and cleanup runs only on failure; the transfer may never be implicit.
- `MIR::TransferMark` is a linear ownership event. After it fires, the binding may not be read again unless a new `AllocMark` for the same binding appears first.
- `MIR::MoveMark` may only follow an explicit `MIR::TransferMark` for the same binding. It is a runtime cleanup guard write, not an ownership decision.
- Aggregate construction is recursively placement-checked. A `MakeList`, `StructInit`, `ArrayInit`, or union payload may not contain an owned child whose allocator disagrees with the aggregate owner. Lowering must flow the destination allocator inward or mark the aggregate owner heap before MIR.

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
ownership. Escape analysis reads only that contract. MIR lowering copies that fact
into `MIR::CallableContract`, records how many user arguments the contract covers,
and adds the concrete consumed binding names for the callsite. MIR phases may not
branch on where a callable came from.

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
- an errcleanup has no explicit transfer marker;
- an aggregate contains an owned child whose allocation disagrees with the aggregate owner;
- an allocator-bearing operation has no target binding;
- an allocator-bearing operation targets a binding with no `AllocMark`;
- an owned-return function call is discarded, nested anonymously, or bound without a matching heap `AllocMark`;
- allocators disagree between operation, allocation, and cleanup;
- an allocating expression survives outside a direct `MIR::Let` init;
- opaque Zig calls hide ownership effects;
- any `MIR::RawZig` exists in compiler MIR;
- any `MIR::InlineZig` exists without a typed callable/effect contract (`stdlib_def` / `FunctionSignature`);
- any `MIR::InlineZig` performs allocator ownership (`alloc`, `dupe`, `create`, `destroy`, `free`, `deinit`) inside opaque code instead of exposing structural MIR ownership markers;
- any `MIR::Call`, `MIR::TailCall`, or `MIR::MethodCall` exists without a typed `MIR::CallableContract`;
- a `MIR::CallableContract` does not cover every user-level callsite argument;
- a `MIR::CallableContract` says the callee has `TAKES` params but does not name the concrete consumed bindings in `ownership_contract.consumes`;
- an opaque Zig node has a nil/hash/malformed ownership contract;
- a consuming opaque Zig node has no concrete `ownership_contract.consumes` entry and matching `MIR::TransferMark`;
- a binding is read after ownership transfer;
- a binding has multiple success-path releases or cleanup finalizers;
- a cleanup is suppressed by `MoveMark` without an explicit transfer;
- control-flow rejoins with different ownership states across branches or loops;
- a loop restore contains frame allocations not proven iteration-local;
- an iteration-local frame allocation appears in a loop with no restore.

The checker is not a placement decider. Any new checker rule must verify a finalized fact that earlier passes were required to emit.
