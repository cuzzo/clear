# Repository Big-O Audit

Audit date: 2026-07-12. Scope: every tracked supported-language file under
`gems/`, `compiler/ruby/`, and `zig/`.

The final whole-repository pass contains 11,671 functions. There are no O(N^3)
or higher polynomial results. The remaining high results are 60 O(N^2) and two
intentional O(2^N) Fibonacci benchmarks. Every item below was
checked against its normalized iteration, call-containment, argument-domain,
and recursion facts and then against the implementation.

## Accepted production findings

These functions perform genuine cross-products, repeated convergence scans,
graph/neighborhood comparisons, source-range scans, or bounded compiler-table
searches. Indexing would either change required ordering/diagnostics, add a
larger persistent index for a small bounded table, or not improve the dominant
work of the offline analysis/reporting path.

- Compiler: `resolve!`, `find_matching_intrinsic`,
  `guard_fsm_result_cleanup!`, `lower_match`, `lower_union_match`,
  `union_match_arm_plans`, and `scan_match_arms`.
- Decomplex/Espalier: `findings_for`, `inconsistent_renames`, and
  `each_wrapped_argument_source`.
- FactMine: `extract_state_protocols` and `structural_boundaries`.
- Lineage: `fallback_matching_unit_entries`, `ingest_mutant_facts_json`,
  `render_branch_context`, `render_dashboard`, and `render_source_view`.
- NilKill inference/reporting: both `propagate_return_usage!` implementations,
  `attach_related_hash_pressure_records`, `each_foreign_origin`,
  `evidence_target_files`, and `top_level_hash_keys`.
- Ruby-to-Clear: `constructor_from_arguments` and `keyword_constructor_pairs`.
- Semantha: `discover`, `detect`, and `top_k_neighbors`; the latter two compare
  neighborhoods/pairs by design.
- SlopCop: `branch_arm_coverage`, `dark_branch_misses_by_line`,
  `line_branch_arm_coverage`, and
  `tuple_branch_arm_coverage`.
- Zig tools/runtime: `writeFactsJson`, both
  `concurrentSharded*EachInPlace` functions, `findSlot`, both `tryStealFrom`
  implementations, `thiefWorker`, and `runAll`.

Three worthwhile repeated-lookups found during the audit were indexed without
changing behavior: MIR registry-call facts by argument index, compiler error
signature parameters by name, and NilKill parameter flows by source method.

## Intentional tests, stressors, and benchmarks

The following O(N^2)+ functions deliberately generate Cartesian schedules,
exhaustive interleavings, repeated samples, or oracle comparisons and must not
be optimized away:

- Espalier/FactMine/Lineage test helpers: `scan_files`,
  `test_generic_architecture_code_does_not_define_type_builtin_lists`,
  `test_ruby_sorbet_guard_lattice_lives_in_fact_mine_ruby_provider`,
  `dashboard_renders_collapsible_risks_hazards_first_and_stacked_bars`,
  and `source_view_collapses_long_comment_runs_with_persisted_controls`.
- Zig benchmarks/stress tests: both `timeFramePreserveN` and
  `timeHeapPreserveN` copies, `timeContiguousReads`, `timePointerReads`,
  `parking-lot-test.run`, `startWorkers`, `scheduler-benchmark-test.run`, both
  `slab-alloc-test.run` functions, `stressWorker`, `spsc-hammer-test.run`,
  `spsc-test.run`, and `runExhaustiveN`.
- `fibDepthGuard` and `fibNoGuard` intentionally implement the exponential
  Fibonacci recurrence. Their reported time is O(2^N) and auxiliary stack space
  is O(N).

## Explicit unknowns

The pass reports 2,546 unknown time bounds rather than inventing a polynomial.
Of these, 87 are specifically highlighted because a loop-contained unresolved
call receives a statically known collection parameter. NilKill runtime tracing
can refine these later. There are 2,775 unknown auxiliary-space bounds and 306
proven O(N) space bounds; unknown-sized materializations and unproven recursive
cycles remain unknown by design.
