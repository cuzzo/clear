# High-Risk Fuzz Mutant Plan

Goal: every high-risk fuzz template has a direct CLI-visible mutant that breaks
one valuable compiler invariant and proves the template is load-bearing. These
are compiler patch mutants, not CLEAR-source mutants: each patch disables one
safety rule and the relevant template must produce a specific new failure delta.

## Plan

| Template | Mutant | Invariant under test | Required signal | Status |
|---|---|---|---|---|
| `bg_capture_transfer_matrix` | `bg_capture_transfer_move_guard` | BG/DO capture transfers emit move guards so moved roots are not cleaned twice or leaked. | `fail +1` | Killed: `fail +70` |
| `branch_cleanup` | `branch_cleanup_emits_finalizers` | Branch-local owned values emit finalizers on all exits. | `fail +1` | Killed: `fail +1` |
| `error_cleanup` | `error_cleanup_emits_finalizers` | OR, RAISE, and DEFAULT error paths emit cleanup or transfer finalizers. | `fail +1` | Killed: `fail +1` |
| `escape_via_return` | `escape_via_return_heap_placement` | Returned cleanup-bearing frame values are promoted or rejected before emission. | `mir-error +1` | Killed: `mir-error +6` |
| `execution_boundary` | `execution_boundary_parallel_policy` | Parallel execution boundaries reject captures that cannot safely cross. | `unexpected-pass +1` | Killed: `unexpected-pass +10` |
| `list_append_modality` | `list_append_move_guard` | Heap-list appends preserve move guards for cleanup-bearing elements. | `fail +1` | Killed: `fail +1` |
| `loop_carry_collection` | `loop_carry_frame_scope` | Loop-carried collections do not keep dangling frame-owned storage. | `mir-error +1` | Killed: `mir-error +8` |
| `loop_cleanup` | `loop_cleanup_emits_finalizers` | Loop disruptors finalize owned locals on break, continue, return, and raise. | `fail +1` | Killed: `fail +1` |
| `lowering_boundary_matrix` | `lowering_boundary_move_guard` | Lowering boundaries preserve transfer guards across WITH, BG/DO/NEXT, pipeline, and call shapes. | `fail +1` | Killed: `fail +4` |
| `mutable_collection_param` | `mutable_collection_param_pointer_passing` | Mutable collection arguments lower as pointer arguments so forwarded mutations remain visible. | `fail +1` | Killed: `fail +1` |
| `or_heap_destination_matrix` | `or_heap_destination_branch_placement` | Owned OR branch values are placed into the destination allocator coherently. | `mir-error +1` | Killed: `mir-error +54` |
| `or_positional` | `or_positional_branch_placement` | OR lowering preserves destination cleanup/allocator facts in every syntactic position. | `mir-error +1` | Killed: `mir-error +18` |
| `owned_sink_destination_matrix` | `owned_sink_destination_heap_placement` | Return, field, list, map, TAKES, and call sinks get coherent owned destination facts. | `mir-error +1` | Killed: `mir-error +4` |
| `return_value_modality` | `return_value_branch_placement` | Owned branch values feeding returns are promoted, cleaned, or rejected correctly. | `fail +1` | Killed: `fail +1` |
| `stream_into_boundary` | `stream_boundary_move_guard` | STREAM NEXT values crossing boundaries retain transfer guards. | `leak +1` | Killed: `leak +5` |
| `struct_field_store_modality` | `struct_field_store_heap_placement` | Cleanup-bearing values stored into heap struct fields preserve child ownership facts. | `mir-error +1` | Killed: `mir-error +8` |

## Guardrail

`spec/fuzz_coverage_model_spec.rb` now fails if any high-risk template lacks a
direct `FuzzMutants::REGISTRY` entry or if a registry entry references a missing
template or patch file. That keeps the CLI tracking list and the high-risk fuzz
coverage model in sync.

## Validation Command

```sh
bundle exec ruby tools/fuzz/mutants/run.rb --mutant <name> --out /tmp/fuzz-mutants-<name>
```

After all entries are individually killed, run:

```sh
bundle exec ruby tools/fuzz/mutants/run.rb --all --out /tmp/fuzz-mutants-high-risk-all
bundle exec ruby tools/fuzz/coverage.rb
bundle exec prspec spec/fuzz_coverage_model_spec.rb
```

Validated locally with all 37 fuzz mutants killed:

```sh
bundle exec ruby tools/fuzz/mutants/run.rb --all --out /tmp/fuzz-mutants-highrisk-all
```

Current coverage: 37 active fuzz mutants, 31 directly covered templates, and
27/27 high-risk templates with direct mutant coverage.
