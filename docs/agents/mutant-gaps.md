# Mutant Coverage Gap Analysis

This tracker focuses on CLEAR's memory-safety mutation coverage. The P1 goal was to harden the "memory brain" areas without gaming the score: `Type`, `CleanupClassifier`, `EscapeAnalysis`, and `BorrowChecker`.

## Current P1 Status

| Area | Gate strategy | Current result | Status |
| :--- | :--- | :--- | :--- |
| `BorrowChecker` | Broad class gate | 86.07%, 833 mutations, 717 killed, 11 timeouts | Hard-gated |
| `CleanupClassifier` | Exact safety-path and frozen-fact gates | `classify_plan` 94.92%; `binding_cleanup_facts` 86.45%; `stamp_field_pre_cleanups!` 86.98%; `walk_moved_source_guards` 100%; `FrozenCleanupFacts#entry_for` 100%; `#entry_for_node` 98%; `#without_names` 98.3% | Hard-gated |
| `EscapeAnalysis` | Exact public/heap-promotion and registry gates | `apply!` 100%; `apply_with_facts!` 98.96%; `propagate_caller_sync!` 91.48%; `mark_takes_args_heap!` 87.62%; `EscapeSink#matches?` 100%; registry validators 99-100% | Hard-gated |
| `Type` | Exact ownership/payload gates | `binary_op` 96.05%; `heap_ptr?` 98.33%; `needs_escape_promotion?` 100%; `collection=` 100%; `needs_pointer_passing?` 100%; `needs_heap_backing?` 100%; `success_type` 100%; `value_payload_type` 88.46% | Hard-gated |

## Real Bugs Found

- `BorrowChecker` did not treat `WITH BORROWED b.user` as an active borrow of root owner `b`, so moving `b` inside the borrow could slip through. This is fixed and covered.

## Current P2 Status

P2 is the targeted safety wall: compiler patch mutants that deliberately break one memory-safety invariant and prove the relevant fuzz/transpile surface catches it. The fuzz side is now the stronger P2 gate because it runs matrix templates instead of one hand-picked `.cht` file.

| Area | Gate strategy | Current result | Status |
| :--- | :--- | :--- | :--- |
| Fuzz safety mutants | 21 targeted compiler patch mutants | 21/21 killed; every baseline matrix clean | Complete for current P2 scope |
| Fuzz coverage registry | Registered/documented template coverage | 64/64 templates documented; no coverage gaps | Clean |
| MIR negative matrix | Direct malformed MIR cells | 45/45 baseline cells reject with expected diagnostics | Strengthened |
| Transpile patch mutants | 5 targeted `.cht` fixtures | 5/5 killed on the existing gate | Useful smoke, not the primary P2 wall |

New P2 mutants added:

- `or_rescue_catch_allocator_identity`: breaks OR/catch fallback allocator placement. `catch_allocator_matrix` kills it with a new failure.
- `escape_identifier_heap_placement`: disables the central escape-sink identifier heap-placement walker. `escape_mechanism_matrix` kills it with MIR errors.
- `ownership_surface_finalization`: disables MIRChecker enforcement that side-channel ownership metadata is finalized into `Owned*` facts. A new `mir_checker_negative_matrix` cell kills it with an unexpected pass.

The full fuzz mutant validation was:

```sh
bundle exec ruby tools/fuzz/mutants/run.rb --all --out /tmp/p2-fuzz-mutants-all
```

Result: all 21 mutants killed.

## Current P3 Status

P3 is the fuzz-suite coverage quality wall: the suite should explain what each template proves and fail closed when registry dimensions, README counts, or high-risk cross-products drift.

| Area | Gate strategy | Current result | Status |
| :--- | :--- | :--- | :--- |
| Template scope metadata | Every registered fuzz template has source kind, matrix strategy, failure meaning, exclusions, and high-risk flag where applicable | 64/64 templates covered | Complete |
| README/template drift | `tools/fuzz/coverage.rb` checks registered templates and numeric active-cell counts against `tools/fuzz/README.md` | 64/64 documented; counts match generator | Clean |
| Registry dimensions | Coverage report maps each template to declared ownership-safety dimensions | Report prints per-template cell counts, expectation mix, source kind, matrix strategy, and dimension counts | Complete |
| P0 sink/value cross-products | High-risk `escape_sinks x cleanup_value_shapes` requirements must be collectively covered | `takes_arg`, `give_arg`, `return_value`, `struct_field_store`, and `list_append` are fully covered | Clean |
| High-risk matrix expansion | High-risk templates cannot use smoke/curated/bounded strategies | Current high-risk templates are exhaustive | Clean |

The P3 validation gate is:

```sh
bundle exec ruby tools/fuzz/coverage.rb
bundle exec prspec spec/fuzz_coverage_model_spec.rb
```

The focused spec proves the gate catches stale README counts, missing template metadata, non-exhaustive high-risk templates, and missing high-risk sink/value-shape cross-products.

## Design Notes

Broad `Type`, `CleanupClassifier`, and `EscapeAnalysis` mutation subjects are still advisory. That is intentional for now:

- `Type` is a broad value-object facade with many delegation and formatting methods. A broad 85% gate would mostly force tests over non-safety surface area.
- `CleanupClassifier` broad runs are expensive and noisy. The hard gates now cover cleanup facts, field pre-cleanup stamping, moved-source guard walking, frozen cleanup fact lookups, and the existing plan classifier.
- `EscapeAnalysis` broad recursive walking remains advisory, but the major public entry points, heap-placement path for TAKES/heap-backed args, sink matching, and registry validator contracts are hard-gated.

The remaining final-boss broad subject is `FsmTransform::Emit*`. The broad module
gate is intentionally advisory because it includes a large amount of private
shape-specific emission and helper code. Stable exact gates now cover
`build_recursive`, `build_fsm_unified`, resume-target routing, context-field
deduplication, recursive capture-map construction, and recursive destroy-action
registration. Future work should add exact gates for newly stabilized helpers
instead of trying to promote the entire emit module at once.

Future work should add exact hard gates for newly discovered safety predicates rather than raising broad facade gates unless the subject is split into smaller cohesive units. Native CLEAR-source mutation for every `.cht` transpile-test is still separate from P2 patch mutants; patch mutants prove compiler invariants are load-bearing, while source mutants would prove individual corpus assertions are load-bearing.
