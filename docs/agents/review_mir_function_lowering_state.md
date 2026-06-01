# Review: MIR Function Lowering State

## Scope

This reviews the architecture pressure around `MIRLoweringFunctions#lower_function_def`
and the downstream state it shares with the rest of MIR lowering.

Primary files:

- `src/mir/lowering/functions.rb`
- `src/mir/mir_lowering.rb`
- `src/mir/lowering/control_flow.rb`
- `src/mir/lowering/expressions.rb`
- `src/mir/lowering/variables.rb`
- `src/mir/lowering/capabilities.rb`
- `src/mir/lowering/fsm_lowering.rb`

## Evidence

Espalier ranks `MIRLoweringFunctions#lower_function_def` as one of the highest
cross-tool overlap findings:

- function writes: 25
- always-called methods: 38
- conditionally-called methods: 44
- owner state slots in `MIRLoweringFunctions`: 36

The method initializes and restores a large set of per-function lowering facts:

- current binding facts: `@current_bindings`, `@current_binding_types`
- function facts: `@current_fn_zig_name`, `@current_fn_return_type`,
  `@current_fn_return_payload_zig`, `@current_fn_tail_call`,
  `@current_fn_has_catch`, `@current_fn_has_rt`,
  `@current_fn_param_names`, `@current_fn_collection_params`,
  `@current_fn_mutable_scalar_params`, `@current_fn_takes_param_names`,
  `@current_fn_snapshot_types`, `@current_fn_returned_names`,
  `@current_fn_heap_carry_return`, `@current_fn_heap_carry_return_vars`
- allocation and cleanup maps: `@decl_zig_name_map`,
  `@fn_alloc_marked_names`, `@fn_name_rename_map`,
  `@guarded_cleanup_names`, `@lowered_alloc_names`,
  `@lowered_guarded_cleanup_names`

Those facts are read outside `functions.rb` by expression, control-flow,
variable, capability, FSM, hoist, and test-lowering code. That means the
problem is not just a long method. It is implicit phase state shared across
lowering submodules.

## /plan

1. Introduce a `MIR::FunctionLoweringContext` or
   `MIR::FunctionLoweringState` object containing the per-function facts now
   spread across `@current_fn_*`, allocation maps, rename maps, and cleanup
   maps.
2. Move existing helper modules directly to the new context API. Do not keep
   compatibility ivars or dual read paths.
3. Move `lower_function_def` setup/restore into a small lifecycle API:
   `push_function_context(fn_node)`, `with_function_context`, and
   `current_function_context`.
4. Migrate helper modules in low-risk batches:
   - first reads only,
   - then local writes,
   - then state snapshot/restore paths,
   - then delete the old ivars.
5. Add focused tests around nested lowering-sensitive cases: tail calls,
   catches, runtime threading, guarded cleanup, renamed params, and heap carry
   returns.
6. After each migration batch, regenerate Decomplex, NilKill, SlopCop, and
   Boobytrap to confirm that the change actually reduces pressure instead of
   adding wrapper branches.

## Easy Path Assessment

There is an obvious path, but it must be completed in one branch: grouping the
state without deleting the old reads creates a worse architecture. The useful
unit of work is "context plus all readers migrated."

## Downstream Payoff

Expected payoff is high:

- makes per-function state lifecycle visible and testable
- reduces accidental state leakage between functions
- gives NilKill a better boundary for currently nullable phase facts
- gives Decomplex and Espalier a real owner for state instead of many peer ivars
- makes future MIR bugs easier to isolate because function-scoped state can be
  snapshotted as one object

This is more valuable than adding branch tests around the current shape,
because tests would mostly freeze an implicit state protocol that should become
explicit.

## Risk

Risk is moderate. The dangerous part is not creating the context object; it is
changing all readers/writers at once. The migration should be deliberately
staged and measured after each batch.

## Recommendation

Worth doing before v0.1 only if the direct-ivar deletion is part of the same
change. A compatibility-backed context by itself should not be committed.

## Implementation Progress

Implemented in this pass:

- Added typed aliases for function-scoped MIR lowering state:
  `NameSet`, `CleanupBindingMap`, `BindingTypeMap`, `BoolNameMap`, and
  `DeclNameMap`.
- Added `FunctionLoweringContext` as the single context object for the
  per-function facts initialized by `lower_function_def`.
- Moved setup of bindings, param-name sets, cleanup maps, return metadata,
  catch metadata, and allocation tracking maps into
  `function_lowering_context`.
- Added `activate_function_context` only as the context installer for shared
  maps that still have one authoritative storage location.
- Deleted the `@current_fn_*` compatibility ivars and migrated readers in
  `control_flow`, `expressions`, `variables`, `functions`, `capabilities`, and
  `mir_lowering` to `current_function_context` accessors.
- Narrowed `lower_function_def` from an erased return type to
  `T.any(MIR::FnDef, T::Array[MIR::FnDef])`.

Validation:

- `bundle exec srb tc`
- `bundle exec prspec spec/mir_lowering_spec.rb`
- `bundle exec prspec spec/pipeline_backend_coverage_spec.rb`

Metric evaluation:

- The context extraction removed `lower_function_def` from the top decomplex
  convergence list.
- In the context-only snapshot, decomplex moved down overall:
  total `1550 -> 1545`, findings `1174 -> 1171`.
- After the PipelineHost bridge step, final decomplex is mixed:
  total `1550 -> 1552`, site findings `2045 -> 2030`,
  missing abstractions `34 -> 33`, neglected updates `429 -> 426`.
- SlopCop moved down in the final snapshot:
  genuine gaps `221 -> 212`, dark arms `786 -> 714`.

Assessment:

Worth keeping now that the dual path is gone. The context object is the single
source for function-scoped facts; tests that used to set `@current_fn_*` now
install a real `FunctionLoweringContext`.

## Follow-up Assessment

Completed in the follow-up:

- Removed all `@current_fn_*` source reads/writes from MIR lowering.
- Moved context accessors onto `MIRLowering`, so every lowering mixin uses the
  same typed API.
- Updated tests to install `FunctionLoweringContext` instead of setting legacy
  ivars.

Final measured snapshot across the tracked files:

- SlopCop genuine gaps: `221 -> 133`.
- Decomplex total candidates: `1550 -> 1374`.
- Decomplex site findings: `2045 -> 1842`.
- Cross-detector convergence: `305 -> 299`.
- Root-cause clusters: `91 -> 87`.
- Neglected updates: `429 -> 241`.
- Broken protocols still increased: `421 -> 440`.

The broken-protocol count is now mostly from the new explicit helper protocols,
not from duplicated function state. Chasing that count further should be done
only by deleting real helper call-pair protocols, not by reintroducing ivars or
compatibility paths.
