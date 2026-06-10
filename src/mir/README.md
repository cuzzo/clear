# MIR Architecture

The top-level compiler overview in [`src/README.md`](../README.md) shows how
CLEAR transpiles CLEAR code to Zig.
The source semantic boundary before MIR is described in
[`src/annotator/README.md`](../annotator/README.md).

The MIR lowering portion is ~40% of the entire compiler code. This document zooms into 
how MIR works and why it exists.

## MIR has two jobs:

1. Make ownership and allocator choices explicit enough to check.
2. Turn the annotated AST into a Zig-shaped tree that the emitter can print
   without doing semantic work.

The examples below are schematic. Real MIR nodes carry source locations,
runtime plumbing, allocator details, and verification facts that are omitted
when they do not explain the stage.

We will use this small CLEAR program:

```ruby clear illustrative
UNION Data { Empty, Text: String }

FN makeData() RETURNS Data ->
  RETURN Data{ Text: "hello" };
END

FN consume(TAKES d: Data) RETURNS Int64 ->
  RETURN 1;
END

FN demo(flag: Bool) RETURNS Int64 ->
  IF flag -> RETURN consume(makeData());

  RETURN 0;
END
```

This is deliberately small but it exercises the important MIR machinery:

* `d` owns a `Data` value that may carry a heap-backed string payload.
* `consume(makeData())` transfers ownership on one path (via `TAKES`).
* This means the value of `makeData()` must be "hoisted".


If the code instead looked like so:

```ruby clear illustrative
FN demo(flag: Bool) RETURNS Int64 ->
  d = makeData();
  IF flag -> RETURN consume(d);

  RETURN 0;
END
```

* `d = makeData();` would already "hoist" the value.
* But, when `flag` if false, `consume(d)` does not `TAKE` ownership and cleanup `d`.
* So when the CFG branches, ownership is joined across control flow, and `d` is cleaned up.

At a high level, MIR is:

```text
annotated AST
  -> rewrite/desugar AST
  -> hoist anonymous owned values
  -> verify AST is fully typed
  -> consume shared semantic escape/storage/capture analyses
  -> classify cleanup
  -> analyze loop frame placement
  -> finalize runtime requirements
  -> stamp ownership facts onto the AST
  -> lower AST to MIR::Program
  -> check MIR ownership invariants (prevent Use After Free, Double Free, and Memory Leaks)
  -> emit Zig from MIR
```

The exact order is enforced by
[`../semantic/pass_state.rb`](../semantic/pass_state.rb).

## Facts and Plans Strategy

MIR is built around explicit facts and short-lived plans. The names are not
perfectly uniform in the codebase, so the important distinction is lifetime:

* A **fact** is evidence another pass may rely on. It is created by one stage,
  attached to the AST, a MIR node, or a function-level map, and then consumed
  later by lowering, checking, or emission.
* A **plan** is a local lowering recipe. It gathers related decisions for one
  syntactic shape, then is immediately turned into explicit MIR nodes and facts.

This is the core strategy: do semantic work once, preserve the result as typed
data, and make the checker validate the explicit surface. The emitter should
print the MIR shape it receives; it should not rediscover ownership, allocator,
capture, or type decisions.

### Persistent Facts

| Fact object | Created by | Used by | Problem solved |
| --- | --- | --- | --- |
| `MIRPassState` | Each compiler stage | Every downstream MIR consumer | Prevents passes from reading facts before their producer has run. |
| Type and symbol facts (`full_type`, `storage`, `sync`, capture analysis) | Annotation, escape analysis, `BgCaptureClassifier` | `CleanupClassifier`, `MIRPass`, `MIRLowering`, `FiberCtxBuilder` | Keeps type, placement, and capture decisions outside the emitter. |
| `CleanupEntry` plus `cleanup_bindings` | `CleanupClassifier`, refined by `MIRPass` for moved guards and special branch facts | `MIRLowering`, `MIRChecker`, `MIREmitter` | Gives each owned binding one cleanup recipe: kind, allocator, scope, guard requirement, and resource-specific cleanup data. |
| `moved_guard_info` | `MIRPass` from ownership dataflow and cleanup entries | `MIRLowering` | Preserves branch-sensitive move state so cleanup can be guarded instead of unconditional. |
| `MIR::OwnershipEffect` | MIR node classes and lowering helpers | Hoist/lowering ownership finalization | States whether an expression produces an owned result, which allocator owns it, whether it needs hoisting, and what target binding carries it. |
| `MIR::OwnershipOperandFact` and `MIR::OwnershipConsumptionFact` | Lowering at the consuming edge | `MIRLowering` ownership finalization and `MIRChecker` | Describes exactly which operands are owned, borrowed, or non-owning at a consuming operation. This avoids later tree/name inference. |
| `MIR::OwnershipContract` and `MIR::CallableContract` | Function/intrinsic lowering and callable MIR nodes | `MIRChecker` and ownership finalization | Makes calls declare their consuming parameters and checked arity without hiding ownership behavior in rendered Zig. |
| `MIR::AllocMark`, `Cleanup`, `ErrCleanup`, `TransferMark`, `MoveMark` | MIR lowering and ownership finalization | `MIRChecker`, then `MIREmitter` | Turns abstract ownership decisions into a visible lifecycle surface that can be checked for leaks, double frees, and use-after-move. |
| `MIR::BoundaryCaptureFact` and `MIR::ExecutionBoundaryFact` | Concurrency/BG lowering from capture analysis | `MIRChecker` and audit tooling | Records what crosses BG/DO/stream boundaries and whether dispatch is local, pinned, or parallel. |
| `MIR::FsmOwnershipFact` and `MIR::FsmResultTransferFact` | FSM lowering and transform helpers | FSM finalization/emission and checker paths | Carries ownership transfer evidence across suspend/resume segmentation. |
| `InlineAllocMetadata` and structural inline-bytecode metadata | Intrinsic/std-lib lowering | `MIRChecker` | Keeps allocator and opaque ownership behavior checker-visible for intrinsic calls while preserving the invariant that Zig text is produced only by the emitter. |

### Short-Lived Plans

Plans are useful when a decision needs several inputs but should not leak as
ambient state. Common examples:

| Plan object | Created by | Consumed by | Problem solved |
| --- | --- | --- | --- |
| `MIR::BindingMaterialization` and `MIR::MaterializationPacket` | Hoist and lowering helpers | Immediate lowering call sites | Emits `AllocMark`, `Let`, and optional cleanup in the correct order as one packet. |
| `DestinationPlacementPlan`, `OwnedSinkPlan`, `OwnedSinkSourceFact`, `DestinationSourceFact` | `MIRLowering` placement/ownership helpers | Value placement and owned-sink materialization | Chooses keep/copy/retain/promote/heap-create behavior when a value flows into a required allocator or ownership sink. |
| `ReturnOwnershipPlan` | `MIRLoweringControlFlow` | Return lowering | Computes which returned names need transfer marks, including converted cleanup names and guarded cleanup names. |
| `ForEachPlan`, `ForRangePlan`, `MatchLoweringFacts`, `UnionMatchArmPlan` | `MIRLoweringControlFlow` | Loop and match lowering | Keeps control-flow lowering structural while carrying iterator, arm, and payload details. |
| `ListLiteralPlan`, `HashLiteralPlan` | `MIRLoweringLiterals` | Literal lowering | Decides allocation, element type, ownership storage, and capability wrappers before building MIR nodes. |
| `NextExprPlan`, `BgLoweringNames`, `BgBodyMaterialization`, `BgCaptureMaterialization` | `MIRLoweringConcurrency` | BG/stream/observable lowering | Keeps async result shape, runtime names, captures, and body materialization explicit at the boundary. |
| `FiberCtxBuilder::CaptureSpec` and `FiberCtxBuilder::Result` | `FiberCtxBuilder` | BG, BG stream, DO, concurrent pipeline, and FSM-related lowering | Normalizes capture fields, initializers, body access rewrites, and FreshHeapCopy/RcClone cleanup wiring. |
| `PipelineOperationPlan`, `PipelineSourcePlan`, `PipelineTerminalPlan`, `PipelineSemanticFacts`, and `PipelineSourceShape` | `src/mir/lower/pipeline` | `PipelineHost` and its domain lowerers | Reifies source, terminal, execution mode, and target facts before a pipeline lowerer emits MIR. |
| `WithBindingMaterialization`, `LockBindingPlan`, `FallibleLockBindingPlan`, `MutableSnapshotPlan` | `MIRLoweringCapabilities` | `WITH` lowering | Separates lock acquisition, aliases, fallible clauses, sorted acquisition, and snapshot transactions from the body. |
| `OwnershipFinalizationContext`, `OwnershipFactTarget`, `OwnershipTransferTarget`, `OwnershipSurfaceScan` | `MIRLowering` ownership finalization | The finalization pass over lowered MIR bodies | Tracks already-emitted alloc/transfer/move/cleanup facts while inserting missing ownership markers. |
| `ThunkTransform::Plan`, `MutualPlan`, `MutualThunkPlan` | Thunk recursive splitters | Thunk emitters/lowering | Records recognized recursion shapes so trampoline emission does not infer them from text. |
| FSM segment/liveness/suspend resolver records | `fsm_transform/*` | FSM emit and wrapper emission | Carries segment boundaries, cross-segment locals, suspend descriptors, and per-arm cleanup data across FSM lowering. |

### Rules of Thumb

* If a decision crosses a pass boundary, make it a fact and attach it to the AST,
  a MIR node, or a function-level map.
* If a decision is only needed to lower one shape, keep it as a plan and
  immediately materialize it into MIR nodes/facts.
* Ownership consumption must be emitted at the consuming edge as operand facts or
  callable contracts. It should not be recovered later by walking arbitrary MIR
  subtrees or rendered Zig text.
* Allocator and cleanup facts have one writer. Architecture invariant specs
  enforce the sanctioned writers for storage and cleanup placement fields.
* Template or raw Zig escape hatches must carry explicit ownership contracts and
  allocation metadata until they are replaced with structural MIR.

### 0. Annotated AST Input

MIR starts after parsing and annotation. Names have been resolved, types are
known, `GIVE` sites have move semantics, and function signatures know which
parameters `TAKE`.

```ruby
AST::FunctionDef(
  name: "demo",
  params: [Param("flag", Bool)],
  return_type: Int64,
  body: [
    AST::IfStatement(
      cond: AST::Identifier("flag"),
      then_branch: [
        AST::ReturnNode(
          AST::FuncCall(
            name: "consume",
            args: [AST::MoveNode(...)]
          ))]),
    AST::ReturnNode(AST::Literal(0_i64))
  ])
```

Nothing is MIR yet. The tree is still an annotated AST.

### 1. Pipeline Rewrite (`src/backends/pipeline_rewriter.rb`)

The pipeline rewriter fuses or rewrites pipeline expressions before MIR sees
them. This example has no pipeline, so the tree does not change.

```text
demo body: unchanged
pass state: :pipeline_rewritten
```

This stage matters because MIR lowering should see the final execution shape,
not a high-level pipeline that still needs fusion decisions.

### 2. String Concatenation Rewrite (`src/backends/string_concat_rewriter.rb`)

String concatenation is normalized before MIR. This example has no string
concat in `demo`, so the `demo` tree does not change.

```text
demo body: unchanged
pass state: :string_concat_rewritten
```

When it does apply, later passes see an explicit allocation-producing string
operation instead of ambiguous `+` syntax.

### 3. Hoist (`hoist.rb`)

Hoist lifts anonymous allocation-producing expressions into named bindings when
they occur in escape positions such as `RETURN`, `YIELD`, field stores, or
container stores.

The helper `makeData` returns an anonymous ownership-bearing union payload, so
it is the kind of code Hoist may rewrite schematically as:

```ruby
# Before
RETURN consume(makeData())

# After
__hoist_1 = makeData()
RETURN consume(__hoist_1)
```

This needs to happen so ownership-sensitive cleanup can refer to a named
binding:

```text
before: anonymous owned value flows through a call argument
after:  named binding has cleanup, transfer, and moved-guard facts
```

The emitter may eventually print Zig `defer` code for that cleanup, but the
cleanup decision is made by MIR analysis and lowering, not by the emitter.

That makes every allocation that escape analysis cares about symbol-bearing:
escape decisions can be written to a binding instead of to a floating
expression node.

### 4. Pre-MIR Type Check (`pre_mir_type_check.rb`)

`PreMirTypeCheck.verify!` is a boundary invariant. Every evaluatable AST node
must have a resolved `full_type`.

It does not intentionally reshape the tree:

```text
AST shape: unchanged
required fact: every expression/statement node is typed
pass state: :premir_type_checked
```

If an untyped node reaches this point, that is a compiler bug in annotation,
not a user-level type error.

### 5. Escape Analysis and Capture Classification

Files:

* [`../semantic/escape_analysis.rb`](../semantic/escape_analysis.rb)
* [`../semantic/bg_capture_classifier.rb`](../semantic/bg_capture_classifier.rb)

Escape analysis decides where bindings live. It updates symbol/storage facts
that later passes read.

For `demo`, `__hoist_1` is a local union value returned from `makeData`. It does not
escape the function as a local binding, but it is transferred into a `TAKES`
call on one path. The important fact is that the binding is ownership-bearing
and has a concrete placement:

```ruby
__hoist_1:
  type: Data
  storage: :heap
  owns_value: true
```

Background capture classification runs here too. This example has no `BG`
block, so no capture facts are added. Architecturally, BG capture strategy is a
shared semantic fact: annotation validates the source-level boundary, and
MIRPass ensures the fact is available before lowering consumes it.

```text
pass state: :escape_analyzed
```

### 6. Cleanup Classification (`cleanup_classifier.rb`)

Cleanup classification decides which bindings might need cleanup and records
how cleanup should be emitted.

For `consume`, the `TAKES d` parameter is owned by the callee:

```ruby
consume.cleanup_bindings = {
  "d" => CleanupEntry(
    kind: :uniform,
    alloc: :heap,
    needs_cleanup: true,
    has_moved_guard: false
  )
}
```

For `demo`, `__hoist_1` is owned by the function until it is either cleaned up or
transferred:

```ruby
demo.cleanup_bindings = {
  "__hoist_1" => CleanupEntry(
    kind: :uniform,
    alloc: :heap,
    needs_cleanup: true,
    has_moved_guard: true   # may be moved on only the IF path
  )
}
```

The `has_moved_guard` flag is the key branch-sensitive fact: cleanup must be
guarded because the compiler cannot emit an unconditional cleanup after a path
that gave the owned value away.

```text
pass state: :cleanup_classified
```

### 7. Loop Frame Analysis (`placement.rb`)

`LoopFrameAnalysis` refines placement around loops, especially where frame
allocations created inside loops would otherwise outlive the iteration frame or
be cleaned up at the wrong level.

This example has no loop, so no tree-visible change occurs:

```text
demo body: unchanged
pass state: :loop_frame_analyzed
```

When it does apply, the later MIR tree gets frame-save/frame-restore structure
or heap/frame placement facts that make per-iteration lifetimes explicit.

### 8. Runtime Requirement Finalization (`mir_pass.rb`)

`MIRPass#finalize_needs_rt!` determines whether a function needs the runtime
pointer threaded through it.

For this example all three functions need `rt`:

```ruby
makeData.needs_rt = true  # may allocate the returned Data payload
consume.needs_rt  = true  # cleanup for TAKES parameter
demo.needs_rt     = true  # cleanup for local owned Data
```

This runs after escape and cleanup classification because those are the passes
that reveal whether allocator-backed cleanup is present.

```text
pass state: :needs_rt_finalized
```

### 9. MIR Pass AST Stamping and Ownership Dataflow

Files:

* [`mir_pass.rb`](mir_pass.rb)
* [`control_flow.rb`](control_flow.rb)

This is the final AST-side MIR pass. It builds a CFG, runs ownership dataflow,
checks use-after-move, and stamps cleanup/move facts onto the AST for lowering.

The CFG for `demo` is:

```text
entry
  |
  v
block0:
  __hoist_1 = makeData()
  IF flag
  |        \
  v         v
block1     block2
RETURN     RETURN 0
consume(__hoist_1)
  \         /
   v       v
     exit
```

Ownership state for `__hoist_1`:

```text
after declaration: owned
then branch:       moved by TAKES d
else/fallthrough:  owned until function exit
exit join:         maybe_moved
```

That join is why the cleanup entry is guarded.

The AST is stamped schematically like this:

```ruby
AST::FunctionDef("demo",
  cleanup_bindings: {
    "__hoist_1" => CleanupEntry(needs_cleanup: true, has_moved_guard: true)
  },
  moved_guard_info: { "__hoist_1" => true },
  body: [
    BindExpr("__hoist_1", FuncCall("makeData")),
    IfStatement(
      then_branch: [
        ReturnNode(FuncCall("consume", [MoveNode(Identifier("__hoist_1"))]))
      ]
    ),
    ReturnNode(Literal(0_i64))
  ])
```

The tree is still AST, but it now carries the cleanup and ownership facts that
MIR lowering will turn into explicit MIR nodes.

```text
pass state: :mir_pass_complete
```

### 10. MIR Lowering (`mir_lowering.rb`, `lowering/*`)

Lowering is where the AST becomes an actual MIR tree. The lowering pass makes
type, allocator, ownership, and runtime decisions. The emitter must not make
those decisions later.

For `consume`, lowering creates a normal function with a cleanup for the owned
parameter:

```ruby
MIR::FnDef(
  "consume",
  params: [MIR::Param("rt", "*Runtime"), MIR::Param("d", "Data")],
  ret_type: "i64",
  body: [
    MIR::Cleanup("d", alloc: :heap),
    MIR::ReturnStmt(MIR::Lit(1))
  ])
```

For `demo`, lowering turns the branch-sensitive ownership facts into explicit
guard and transfer structure:

```ruby
MIR::FnDef(
  "demo",
  params: [MIR::Param("rt", "*Runtime"), MIR::Param("flag", "bool")],
  ret_type: "i64",
  body: [
    MIR::Let("__hoist_1", MIR::Call("makeData", [MIR::Ident("rt")]), mutable: false),
    MIR::Let("__hoist_1_moved", MIR::Lit(false), mutable: true), # schematic guard
    MIR::Cleanup("__hoist_1", has_moved_guard: true, alloc: :heap),

    MIR::IfStmt(
      cond: MIR::Ident("flag"),
      then_body: [
        MIR::TransferMark("__hoist_1", :call_arg, :heap),
        MIR::MoveMark("__hoist_1"),
        MIR::ReturnStmt(
          MIR::Call("consume", [MIR::Ident("rt"), MIR::Ident("__hoist_1")])
        )
      ],
      else_body: nil
    ),

    MIR::ReturnStmt(MIR::Lit(0))
  ])
```

The exact generated tree may include extra temporaries, ownership fact nodes,
`ErrCleanup`, or allocator conversion nodes. The important shape is stable:

* allocation sites become `Let` plus ownership facts,
* cleanup becomes `Cleanup` or `ErrCleanup`,
* ownership transfer becomes `TransferMark` plus, when guarded, `MoveMark`,
* control flow becomes structured MIR (`IfStmt`, `WhileStmt`, `ReturnStmt`).

```text
pass state: :mir_lowered
```

#### BG, WITH, FSMs, and Thunks

Annotation validates source-level execution boundaries. MIR lowering owns the
runtime form:

```text
AST::BgBlock / async boundary
  -> capture materialization and cleanup facts
  -> FSM or thunk transform
  -> MIR::FsmGenericCtxStruct / MIR::FsmMemberFn / dispatch nodes
  -> MIR checker structure validation
```

`WITH` aliases and capability requirements are already validated by the
annotator. MIR consumes those facts to preserve safe access while lowering
captures, borrows, transfers, and cleanup guards around the runtime boundary.

FSM and thunk lowering must remain structural: it should create or inspect MIR
nodes, not recover intent from rendered Zig strings. Regex/text rewriting in
FSM or thunk lowering is an architectural blocker because it hides ownership
and capture facts from the checker.

#### Pipeline Lowering

Pipeline syntax is rewritten before MIR, but MIR owns the runtime shape. The
current pipeline lowering boundary is:

```text
typed AST pipeline expression
  -> PipelinePlanBuilder
  -> PipelineOperationPlan(source, terminal, execution, semantic facts)
  -> PipelineHost orchestration
  -> domain lowerer emits structural MIR
```

`PipelineHost` should remain a coordinator over typed plans. Source and
terminal recognition belongs in `PipelinePlanBuilder`; range, list, scalar,
batch-window, set-index, each, and concurrent emission belongs in the matching
domain lowerer. The narrow `PipelineLoweringBridge` is the sanctioned adapter
back to `MIRLowering`; direct dependence on broad lowerer lifecycle state should
not grow outside that bridge.

### 11. MIR Checker (`mir_checker.rb`)

The checker validates the lowered MIR ownership surface before Zig is emitted.
It is the last semantic safety gate.

For this example it verifies facts such as:

```text
__hoist_1 has an allocation/ownership creation fact
__hoist_1 has a cleanup on the local path
the TAKES path has a TransferMark
the guarded cleanup has a matching MoveMark
__hoist_1 is not used after the transfer path
d is cleaned up inside consume
```

The checker consumes explicit MIR nodes and ownership fact nodes; it should not
re-infer compiler intent from source syntax.

```text
pass state: :mir_checked
```

### 12. MIR Emission (`mir_emitter.rb`)

The emitter is a template engine. It maps MIR nodes to Zig text and does not
perform ownership analysis, allocator selection, type inference, or schema
lookup.

Schematic Zig for the example:

```zig
fn consume(rt: *Runtime, d: Data) i64 {
    _ = &rt;
    defer CheatLib.cleanup(@TypeOf(d), rt.heapAlloc(), &d);
    return 1;
}

fn demo(rt: *Runtime, flag: bool) !i64 {
    const d = try makeData(rt);
    var d_moved = false;
    defer if (!d_moved) {
        CheatLib.cleanup(@TypeOf(d), rt.heapAlloc(), &d);
    }

    if (flag) {
        const result = consume(rt, d);
        d_moved = true;
        return result;
    }

    return 0;
}
```

The real generated Zig may introduce temporaries for allocator conversion,
owned-slice conversion, or error-path cleanup. Those are products of lowering,
not decisions made by the emitter.

## Pass Order Summary

[`MIRPassState`](../semantic/pass_state.rb) records the facts each pass has made
available:

| Stage | Producer | Main effect |
| --- | --- | --- |
| `:annotated` | `SemanticAnnotator` | MIR input: names/types/storage candidates known. |
| `:pipeline_rewritten` | `PipelineRewriter` | Pipeline syntax is rewritten/fused. |
| `:string_concat_rewritten` | `StringConcatRewriter` | String `+` forms are normalized. |
| `:hoisted` | `Hoist` | Anonymous owned escape values get synthetic bindings. |
| `:premir_type_checked` | `PreMirTypeCheck` | Every evaluatable AST node has a resolved type. |
| `:escape_analyzed` | `MIRPass` using `src/semantic` analyses | Binding storage and BG capture facts are finalized. |
| `:cleanup_classified` | `MIRPass/CleanupClassifier` | Cleanup entries are attached to ownership-bearing bindings. |
| `:loop_frame_analyzed` | `LoopFrameAnalysis` | Loop-sensitive frame placement facts are available. |
| `:needs_rt_finalized` | `MIRPass#finalize_needs_rt!` | Runtime pointer threading is decided from final cleanup/placement facts. |
| `:mir_pass_complete` | `MIRPass` | AST is stamped with ownership, cleanup, and move-guard facts. |
| `:mir_lowered` | `MIRLowering` | AST becomes `MIR::Program`. |
| `:mir_checked` | `MIRChecker` | MIR ownership invariants have been verified. |

## File Map

The MIR directory is split by responsibility:

* [`mir.rb`](mir.rb): MIR node definitions and ownership fact structs.
* [`alloc.rb`](alloc.rb): annotation-side storage helpers mixed into the semantic annotator.
* [`hoist.rb`](hoist.rb): AST rewrite that creates bindings for anonymous owned values.
* [`pre_mir_type_check.rb`](pre_mir_type_check.rb): AST-to-MIR type invariant.
* [`cleanup_entry.rb`](cleanup_entry.rb): typed cleanup recipe object used by cleanup classification, lowering, checking, and emission.
* [`cleanup_classifier.rb`](cleanup_classifier.rb): cleanup plans for bindings.
* [`control_flow.rb`](control_flow.rb): CFG construction, ownership dataflow, and use-after-move checking.
* [`mir_pass.rb`](mir_pass.rb): coordinates MIR-side AST analysis and stamping.
* [`mir_lowering.rb`](mir_lowering.rb) and [`lowering/`](lowering/): AST-to-MIR lowering.
* [`lower/pipeline/`](lower/pipeline): typed pipeline operation plans, pipeline
  host orchestration, and domain lowerers for range, binding-chain, scalar,
  list, batch-window, set-index, each, and concurrent pipeline execution.
* [`materialization.rb`](materialization.rb): helper packets for emitting allocation marks, bindings, and cleanups together.
* [`fiber_ctx_builder.rb`](fiber_ctx_builder.rb): shared capture-context builder for BG, DO, stream, concurrent, and FSM-adjacent lowering.
* [`test_lowering.rb`](test_lowering.rb): TEST/WHEN/STUB/BENCHMARK lowering support.
* [`mir_checker.rb`](mir_checker.rb): ownership and lifecycle verification over MIR.
* [`mir_emitter.rb`](mir_emitter.rb): MIR-to-Zig emission.
* [`fsm_transform.rb`](fsm_transform.rb), [`fsm_transform/`](fsm_transform),
  [`fsm_lowering.rb`](fsm_lowering.rb), [`fsm_ops.rb`](fsm_ops.rb), and
  [`fsm_wrapper_emitter.rb`](fsm_wrapper_emitter.rb): async/background FSM
  lowering and emission support.
* [`thunk_transform.rb`](thunk_transform.rb) and
  [`thunk_transform/`](thunk_transform): recursion thunk/trampoline lowering
  support.

Shared semantic analyses live outside MIR in [`../semantic`](../semantic):

* [`../semantic/pass_state.rb`](../semantic/pass_state.rb): enforced compiler
  pass ordering from annotation through MIR checking.
* [`../semantic/escape_analysis.rb`](../semantic/escape_analysis.rb): AST-bound
  storage and escape decisions consumed by MIRPass.
* [`../semantic/bg_capture_classifier.rb`](../semantic/bg_capture_classifier.rb):
  one writer for BG capture strategy facts.
* [`../semantic/effect_inference.rb`](../semantic/effect_inference.rb) and
  [`../semantic/concurrency_checks.rb`](../semantic/concurrency_checks.rb):
  source-level whole-program semantic checks run by the annotator.
* [`../semantic/ownership_graph.rb`](../semantic/ownership_graph.rb): ownership
  and borrow graph used while annotating source-level movement.

The design boundary is intentional: analysis belongs before or during lowering,
verification belongs in the checker, and emission is mechanical.

The active MIR coverage/review burn-down checklist lives in
[`../../docs/agents/MIR_COVERAGE_AUDIT.md`](../../docs/agents/MIR_COVERAGE_AUDIT.md).
