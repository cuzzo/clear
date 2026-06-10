# FSM/Thunk Cleanup And Segment Facts Plan

## Baseline

Snapshot artifacts:

- `tmp/fsm-thunk-cleanup/decomplex-before.md`
- `tmp/fsm-thunk-cleanup/decomplex-before.json`
- `tmp/fsm-thunk-cleanup/slopcop-before.md`
- `tmp/fsm-thunk-cleanup/coverage-before/.resultset.json`

Baseline pulse:

- Decomplex state heatmap: 577
- Decomplex state-based branch density: 1616
- Decomplex broken protocols: 392
- Decomplex false simplicity: 1011
- SlopCop dark arms: 3029
- SlopCop genuine gaps: 1304

## Problem

The prior FSM cleanup rewrite moved the dangerous cleanup behavior out of rendered Zig string surgery and into MIR cleanup nodes. That closed the largest memory-safety hole. The remaining architectural debt is that FSM segment structure still carries a mixed body/source model: rendered strings, MIR nodes, descriptor nodes, and transfer facts are later reinterpreted to recover the facts needed for cleanup guards, result transfer, and context-field access.

That is too implicit for a memory-safety boundary. Cleanup and ownership facts should be computed structurally from MIR nodes at segment construction time, stored as an explicit typed segment record, and consumed by the FSM structure builder. Rendered strings should never be fact sources.

Thunk lowering no longer has the old regex/frame-binding cleanup issue, but it still has a small loose hash boundary for mutual-recursive arm plans. That should be tightened if the FSM work lands cleanly and metrics stay in the right direction.

## Acceptance Gates

- 100% of new/changed Ruby code is strongly typed.
- 100% of new/changed lines are covered.
- More than 80% of new/changed branches are covered.
- Decomplex and SlopCop should stay flat or improve overall. Local movement is acceptable only when it is clearly paid back by the completed slice.
- Cleanup facts must be derived from MIR nodes, not rendered strings.

## Implementation Tasks

1. Add explicit typed `FsmSegmentFacts`.
   - Compute context reads, move guard writes, required move guards, result names, and ownership transfer facts in one structural pass over MIR nodes.
   - Store facts on each `FsmSegmentSpec`.
   - Make `build_fsm_structure` consume facts only.
   - Delete the old mixed `FsmStructureSource` path.

2. Tighten tests around cleanup fact ownership.
   - Prove rendered strings are ignored as fact sources.
   - Prove MIR structure nodes and descriptor nodes produce cleanup facts.
   - Prove manually provided segment facts are the structure builder input.

3. Tighten thunk mutual-arm planning if scoped.
   - Replace the loose `T::Hash[Symbol, Object]` arm plan with typed records.
   - Keep the public MIR shape stable unless downstream consumers can be upgraded without metric regression.

4. Run gates after each task.
   - Focused specs for changed code.
   - Full RSpec coverage when a slice is complete.
   - Decomplex after each implementation task.
   - Final SlopCop and Decomplex comparison against the baseline snapshot.
