# MIR Simplicity Completion Epic

Purpose: finish the simplification work instead of continuing partial cleanup rounds. This epic closes the remaining architectural gaps that materially increase branches, duplicated decisions, or checker uncertainty in escape, placement, cleanup, ownership, and MIR lowering.

This is expected to be a multi-commit epic, likely 30-60 focused commits. Commits should be small enough that each one either deletes a class of branches, reifies one implicit protocol into a typed fact, or hardens an invariant that prevents regression.

## Non-Negotiable Rules

- Do not move complexity to another file and call it done.
- Do not add compatibility or dual paths.
- Do not add special cases for individual stdlib functions, collection types, benchmark examples, fuzz cells, or transpile tests.
- New facts are typed objects or typed methods, not hashes, tuple arrays, nil sentinels, or positional protocols.
- MIR lowering consumes authoritative facts. It does not decide heap/frame, ownership transfer, cleanup shape, or escape.
- MIRChecker verifies finalized facts and hard-errors on anything it cannot prove memory safe.
- Branch coverage work starts only after branch-heavy code that should not exist has been deleted or converted into typed facts.

## Current Gap Summary

Fresh reports still show these material gaps:

- `src/mir/mir_lowering.rb` remains the top Boobytrap hotspot, with local decision pressure around placement, transfer, owned-sink materialization, and packet assembly.
- SlopCop still attributes a large dark-arm class to `type_norm`, which means loose post-annotation type contracts are still forcing nil/type guards.
- Pipeline host still feeds MIR through too many untyped hashes, tuple-like arrays, and `respond_to?` probes.
- `escape_analysis.rb` still has enough local shape logic that it must be audited against the closed-sink spec. Escape sinks are a closed language list, not ad hoc checks.
- FSM/thunk lowering still contains untyped AST walking. This is not automatically the next global cleanup target, but any FSM/thunk walk that feeds allocation, cleanup, capture, transfer, return, or checker-visible ownership facts is in scope and must be typed or moved behind an explicit fact boundary.
- Some traversal work is improved, but the final contract must be explicit: generic full-tree traversal, lexical-surface traversal, and AST traversal must be separate typed APIs with no pass-local walkers for ownership-significant logic.

## Completion Definition

This epic is complete only when all of the following are true:

- `mir_lowering.rb` no longer appears as a top architectural hotspot because of ownership/placement decision pressure. Remaining branches are structural AST dispatch or backend emission shape, not memory-safety decisions.
- Every storage, allocation, cleanup, ownership-transfer, and return-ownership decision has exactly one authoritative writer.
- Every consumer reads a typed fact whose constructor enforces required data.
- No MIR/backend code performs post-annotation optional type probing for facts that must exist.
- No production MIR path uses hashes or tuple arrays as ownership, allocation, cleanup, return, or pipeline contracts.
- `MIRChecker` hard-errors on any implicit ownership, allocator side channel, missing allocation type, missing cleanup/transfer, UAF, double release, or unverifiable leak.
- The architecture invariant specs enforce the rules above so regressions fail fast.
- All non-quarantined and formerly quarantined fuzz templates run with `in_dev=0`; skipped tests are explicit in output.
- `bundle exec srb tc`, full unit specs, Ruby integration specs, transpile tests, fuzz tests, Zig tests, and benchmark corpus are either passing or any remaining failure is documented as a broken test with evidence that the compiler behavior is correct.

## Workstream 1: Typed MIR Facts Before Lowering

Goal: remove decision branches from MIR lowering by making earlier stages produce facts that lowering can mechanically emit.

### 1.1 Placement Result Fact

Create or complete a typed placement fact that answers:

- binding name
- finalized storage
- allocator
- lifetime scope
- source type
- escape reason, if any

Then replace local `dest_alloc == :heap`, `heap_indirect_destination?`, `escaping_value_alloc`, and similar placement readers with this fact.

Done when lowering no longer computes heap/frame placement from AST/MIR shape.

### 1.2 Ownership Transfer Plan

Finish reifying ownership transfer into one typed plan:

- source owner name
- transfer target
- target allocator
- whether a move guard is required
- required emitted markers
- source of authority for the transfer

Then delete scattered logic that independently emits or infers `TransferMark` / `MoveMark`.

Done when every transfer marker comes from the same plan constructor and checker rejects any marker not backed by a plan-shaped fact.

### 1.3 Owned Sink Materialization Plan

Replace `owned_sink_plan` shape branches with a typed plan created from:

- source expression ownership effect
- destination allocator
- destination type
- source binding, if already named
- required materialization node, if any

Done when owned-sink handling is mechanical: keep existing owner, materialize to destination allocator, or hard-error.

### 1.4 Return Ownership Plan

Create one return ownership fact for:

- returned binding names
- consumed roots
- return allocator
- moved roots
- final transfer markers

Done when return lowering, block-result lowering, and checker return validation consume the same fact vocabulary.

## Workstream 2: Eliminate Post-Annotation Type Optionality

Goal: delete `type_norm` branches that exist only because post-annotation consumers do not trust the annotation contract.

### 2.1 Audit Remaining Type Probes

Inventory all MIR/backend `full_type`, `type_info`, `Type.from_node`, safe-nav, nil, `respond_to?`, and `is_a?(Type)` probes.

Classify each as:

- external boundary;
- impossible after annotation and should hard-error;
- legitimate sum-type dispatch;
- missing typed fact.

### 2.2 Hard-Fail Contract Violations

For every impossible post-annotation nil/malformed type path, replace fallback behavior with an invariant error at the earliest stage that has enough context.

Done when MIR/backend allocation and ownership code never silently manufactures fallback `Type` values.

### 2.3 Delete Defensive Branches

After the contract is enforced, delete the now-dead optional type branches. Do not replace them with equivalent guards elsewhere.

Done when SlopCop `type_norm` dark arms in MIR/backend materially drop and no memory-safety path depends on nil type checks.

## Workstream 3: Pipeline Host Fact Reification

Goal: stop feeding MIR ownership/allocator decisions from hashes and shape probes.

### 3.1 Pipeline Source Fact

Reify source shape:

- bounded collection
- stream
- infinite stream
- range
- identifier source
- pipeline-owned temporary

This replaces repeated `bc_target?`, `inf_stream?`, identifier checks, and source-chain hash protocols.

### 3.2 Pipeline Terminal Fact

Reify terminal behavior:

- terminal kind
- output ownership
- target binding
- allocator requirements
- whether source/result ownership is transferred

This replaces terminal-specific branch matrices where they feed ownership or allocation.

### 3.3 Pipeline Allocator Contract

Any pipeline operation that allocates must expose the same allocator metadata and ownership contract path as normal MIR calls. No string-specific or collection-specific allocator side channels.

Done when `PipelineHost` cannot emit an allocator-bearing node without a typed target and typed allocator contract.

## Workstream 4: Escape And Cleanup Closed Models

Goal: ensure escape analysis and cleanup classification are simple closed inventories, not expanding local case systems.

### 4.1 Escape Sink Registry Audit

Compare implementation against the language sink list:

- owning return;
- enclosing-scope or heap store;
- closure/fiber/background capture;
- `TAKES` / mutable param flow;
- receiver backing storage escaping current frame.

Every branch in escape analysis must map to one of these sinks or be deleted.

Done when adding a new escape sink requires extending the registry and architectural spec, and missing handlers fail.

### 4.1a Escape Local Shape Logic Burn-Down

Audit every local AST-shape predicate in `escape_analysis.rb`.

For each branch, classify it as:

- a closed escape sink handler;
- a pure traversal/body-boundary concern;
- a type/signature fact read;
- a duplicate or special-case sink that must be deleted.

No branch may survive because "this shape also escapes sometimes." The branch must either live under a registered sink handler or be represented by upstream typed data that the sink handler reads.

Done when the file can be explained as: traverse AST, dispatch registered sink handlers, write `symbol.storage = :heap`, and nothing else.

### 4.2 Cleanup Classifier Contract

Cleanup classifier should read only:

- finalized symbol placement;
- type cleanup facts;
- lexical lifetime facts;
- explicit ownership transfer requirements.

Delete or reify any code that infers cleanup from collection method names, backend snippets, or MIR node shape.

### 4.3 Loop Lifetime Contract

Loop frame analysis may only read cleanup lifetime facts. Audit and delete remaining branches that inspect collection/method/storage shape to infer loop behavior.

Done when loop analysis is mechanically "iteration cleanup exists => restore" and checker verifies illegal frame lifetime.

## Workstream 4b: FSM And Thunk Ownership Boundary Audit

Goal: prevent FSM/thunk untyped walking from becoming a hidden second ownership system while avoiding broad refactors that do not affect memory safety.

### 4b.1 Classify FSM/Thunk Walkers

Inventory untyped walking in:

- `src/mir/fsm_lowering.rb`;
- `src/mir/fsm_transform/**/*.rb`;
- `src/mir/thunk_transform/**/*.rb`;
- `src/mir/fsm_ops.rb`.

Classify each walker as:

- memory-safety significant: feeds allocation, cleanup, capture, transfer, return, frame lifetime, or checker-visible MIR facts;
- emission-only: formats already finalized facts;
- analysis-only but not ownership-significant.

### 4b.2 Fix Memory-Safety Significant Walkers

For every memory-safety significant walker, either:

- replace it with the shared typed AST/MIR traversal API; or
- make it consume a typed fact produced earlier; or
- create a typed FSM/thunk plan object that owns the walk result.

No memory-safety significant FSM/thunk path may depend on `T.untyped` hash/array results or open-ended `respond_to?` traversal.

### 4b.3 Fence Emission-Only Walkers

Emission-only walkers may remain temporarily if they cannot affect ownership, but they must be documented as such and architecture tests must prevent them from emitting allocation/cleanup/transfer markers directly.

Done when FSM/thunk lowering has no untyped walk that can silently create or suppress a memory-safety fact.

Current audit boundary:

- `src/mir/fsm_ops.rb` owns the typed FSM op tree. Its walkers are memory-safety significant only insofar as they derive structure from `FsmOps::*`; they must not emit MIR ownership markers directly.
- `src/mir/fsm_lowering.rb` may lower AST steps and emit FSM result ownership transfers only through `FsmResultTransferFact`.
- `src/mir/fsm_transform/emit.rb` still contains string rendering and cleanup-line lifting for segmented FSM code. Treat that as memory-safety significant until converted: it may construct destroy-task cleanup entries, but it must not instantiate `MIR::AllocMark`, `MIR::Cleanup`, `MIR::ErrCleanup`, `MIR::TransferMark`, or `MIR::MoveMark` directly.
- `src/mir/thunk_transform/**/*.rb` is still a generated-Zig trampoline path. It is fenced by an explicit fail-fast on error-union return types because those would leak the frame chain. Do not expand this path until the trampoline cleanup plan is represented as typed facts.

## Workstream 5: Traversal And Closed MIR Node Protocols

Goal: make it impossible for a new MIR node to bypass ownership checks or for passes to accidentally use the wrong traversal boundary.

### 5.1 Typed Traversal APIs

Finalize three APIs:

- full MIR tree traversal;
- lexical-surface MIR traversal;
- AST child traversal.

Each API must document whether it crosses statement bodies, block expressions, opaque Zig, and ownership boundaries.

### 5.2 Ban Pass-Local Ownership Walkers

Architecture tests should forbid new pass-local MIR walkers in ownership-significant passes. Exceptions require a documented traversal contract.

### 5.3 Closed Ownership Node Registration

Every ownership-significant MIR node must be registered in one place. A new node that allocates, frees, transfers, stores, borrows, returns, or hides opaque effects must fail checker registration until classified.

Done when `MIRChecker` cannot silently skip a new ownership-affecting node.

## Workstream 6: Checker Fail-Closed Hardening

Goal: make memory unsafety unrepresentable past MIRChecker.

### 6.1 Implicit Ownership Ban

Any owned allocation, transfer, cleanup suppression, opaque call consumption, or allocator-bearing operation without explicit typed facts is a compiler error.

### 6.2 Linear Ownership Completeness

The checker must verify:

- one allocation source;
- one success-path owner;
- cleanup or transfer on every path;
- no read after transfer;
- no double cleanup/finalizer/release;
- no frame allocation crossing escape boundaries;
- branch and loop rejoin ownership states agree.

### 6.3 Opaque Code Restrictions

`RawZig` is invalid in compiler MIR. `InlineZig` may only exist with typed callable/effect metadata and may not hide allocator effects.

Done when every MIR checker negative fuzz cell is blocked by a specific hard compiler error, not by backend failure or runtime corruption.

## Workstream 7: Metrics And Coverage Gates

Goal: measure only after reducing branches that should not exist.

### 7.1 Regenerate Baseline After Each Workstream

After each workstream:

```bash
bundle exec srb tc
bundle exec rspec
ruby tools/fuzz/run.rb --matrix
ruby gems/decomplex/exe/decomplex report src --output=gems/decomplex/report.md
ruby gems/slopcop/exe/slopcop report --output=gems/slopcop/report.md
ruby gems/boobytrap/exe/boobytrap report --output=gems/boobytrap/report.md
```

If the exact command differs, record the command in the commit message or update this file.

### 7.2 Branch Coverage Strategy

Only add fuzz/unit coverage for branches that remain after architectural reduction.

Prioritize:

- MIR checker negative guarantees;
- escape sink registry;
- cleanup lifetime classifier;
- ownership transfer/materialization plans;
- pipeline allocator contracts.

Do not add tests that merely preserve accidental branches.

## Suggested Commit Breakdown

1. Add failing architectural invariants for typed fact boundaries.
2. Add placement fact object and wire one reader.
3. Migrate all lowering placement readers.
4. Delete dead placement helpers.
5. Add ownership transfer plan invariant.
6. Migrate transfer emission path 1.
7. Migrate transfer emission path 2.
8. Delete direct `TransferMark` / `MoveMark` emission outside sanctioned helpers.
9. Add owned-sink materialization plan.
10. Migrate collection/store sinks.
11. Migrate call sinks.
12. Migrate return/block-result sinks.
13. Delete `owned_sink_plan` branch mass.
14. Add return ownership plan.
15. Migrate return lowering.
16. Migrate checker return validation.
17. Delete duplicate return ownership readers.
18. Type-probe audit commit with generated inventory.
19. Add hard errors for impossible post-annotation nil type.
20. Delete first tranche of optional type guards.
21. Delete second tranche of optional type guards.
22. Add pipeline source fact.
23. Migrate source-shape checks.
24. Add pipeline terminal fact.
25. Migrate terminal ownership/allocator decisions.
26. Delete pipeline hash protocols feeding MIR.
27. Escape sink registry audit and invariant tightening.
28. Escape local shape logic inventory.
29. Delete non-sink escape branches.
30. Cleanup classifier contract audit.
31. Delete cleanup inference branches not backed by placement/type/lifetime facts.
32. Loop lifetime audit.
33. Delete loop shape inference.
34. FSM/thunk walker inventory and memory-safety classification.
35. Convert memory-safety significant FSM/thunk walkers to typed facts or shared traversal.
36. Fence emission-only FSM/thunk walkers so they cannot emit ownership facts.
37. Finalize traversal API docs and tests.
38. Delete pass-local ownership walkers.
39. Harden closed MIR node registration.
40. Harden implicit ownership checker errors.
41. Expand checker negative fuzz matrix only for remaining guarantees.
42. Regenerate metrics and compare against master.
43. Address any regression that represents real complexity, not metric noise.
44. Full test, fuzz, transpile, benchmark, Zig verification.

The exact count may exceed 50 commits if any step has broad call-site migration. That is acceptable; the point is that each commit must delete a class of uncertainty or enforce a class of invariants.

## Stop Conditions

Stop and reassess if:

- a change requires a runtime workaround for a compiler ownership failure;
- a change adds a second path for typed and untyped facts;
- a branch is being added for one stdlib/container/test case;
- a metric improves only because code moved files;
- MIRChecker accepts a program whose ownership is implicit or unverifiable.

## Relationship To Existing Trackers

- `docs/agents/mir-architecture.md` is the normative architecture contract.
- `docs/agents/mir-lowering-cleanup-tracker.md` contains granular report-derived tasks.
- `docs/agents/type-norm-burndown.md` tracks the prior type contract effort.
- This file is the completion epic that decides when the work is actually finished.
