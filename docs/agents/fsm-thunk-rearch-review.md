# FSM Thunk Rearch Review

Generated: 2026-06-03 UTC

Base: `ca4260a` (`WIP speed up escape analysis and fix MIR ownership`)

Current branch/head: `fsm-thunk-rearch` at `a262c80a5`; worktree has additional uncommitted WIP.

Coverage artifact for the original inventory: `coverage/.resultset.json`, mtime `2026-06-03T13:08:08Z`. `ruby tools/diff_bucket_summary.rb --format text` reported source diff coverage as `N/A (stale)` and `Src type guardrails: none`, so the changed-function inventory below is the original local risk map. Cleanup metrics were refreshed after full unit plus transpile coverage; see "Cleanup Pass" below. The before SlopCop/Boobytrap runs used the same resultset with absolute paths rebased onto `/tmp/cheat-ca4260-review`.

## Scope

Review base is every file changed by `git diff ca4260a`, including committed branch work and current WIP. Production/function inventory covers changed Ruby files under `src/`, `tools/`, and `examples/minivm/`; specs, RBI, docs, testdata, and dependency files are counted in scope but do not produce function rows.

| area | changed files |
|---|---:|
| `src/` | 56 |
| `tools/` | 10 |
| `examples/` | 2 |
| `spec/` | 21 |
| `docs/` | 1 |
| `sorbet/` | 1 |
| `testdata/` | 1 |
| `other` | 3 |
| **total** | **95** |

Branch commits since the base:

- `a262c80a5 Add exclusive pass work profiling details`
- `b839fbc95 Enforce MIR type metadata invariants`
- `b4930c845 WIP performance profiling and compiler changes before pruning`
- `e4690de45 WIP profile minivm compile performance`
- `de3ac1a29 Compact fixed-array default initialization`
- `e2c0a4c36 Reduce MIR checker repeated traversal`
- `df86de683 Speed up MIR ownership lowering`

## Aggregate Metrics

### Typed Slots (`tools/typing_baseline.rb src`)

| slot | before | after | delta |
|---|---:|---:|---:|
| files | 131 | 132 | +1 |
| `TOTAL.nilable` | 1739 | 1860 | +121 |
| `TOTAL.untyped` | 2722 | 2397 | -325 |
| `collections.nilable` | 10 | 11 | +1 |
| `collections.untyped` | 695 | 559 | -136 |
| `params.nilable` | 846 | 876 | +30 |
| `params.untyped` | 1799 | 1578 | -221 |
| `returns.nilable` | 663 | 705 | +42 |
| `returns.untyped` | 589 | 518 | -71 |
| `structs_ivars.let` | 285 | 266 | -19 |
| `structs_ivars.nilable` | 191 | 188 | -3 |
| `structs_ivars.untyped` | 27 | 19 | -8 |

### SlopCop (`gems/slopcop`)

| metric | before | after | delta |
|---|---:|---:|---:|
| files | 93 | 93 | 0 |
| dark arms | 6023 | 8014 | +1991 |
| genuine gaps | 1388 | 1929 | +541 |
| type_norm | 1716 | 2197 | +481 |
| dead | 1526 | 2416 | +890 |
| defensive | 136 | 78 | -58 |
| spurious | 70 | 88 | +18 |
| ffi | 0 | 0 | 0 |
| diagnostic | 1187 | 1306 | +119 |

### Decomplex (`gems/decomplex`)

| detector | before | after | delta |
|---|---:|---:|---:|
| **total** | 5913 | 5964 | +51 |
| Broken Protocols | 1333 | 1338 | +5 |
| Decision Pressure | 2212 | 2188 | -24 |
| Derived-State Staleness | 143 | 142 | -1 |
| Exact Predicate Aliases | 40 | 42 | +2 |
| False Simplicity | 3587 | 3738 | +151 |
| Fat Unions | 19 | 21 | +2 |
| Inconsistent Rename Clones | 142 | 142 | 0 |
| Missing Abstractions | 469 | 474 | +5 |
| Neglected Conditions | 11 | 11 | 0 |
| Neglected Path Conditions | 1685 | 1695 | +10 |
| Neglected Updates | 1256 | 1273 | +17 |
| Oversized Predicates | 12 | 15 | +3 |
| Reification Misses | 25 | 25 | 0 |
| Semantic Predicate Aliases | 24 | 24 | 0 |

Detector rows are non-exclusive site-finding sums; the `total` row is the report total.

### Boobytrap (`gems/boobytrap`)

| metric | before | after | delta |
|---|---:|---:|---:|
| fix commits matched | 95 | 96 | +1 |
| hotspots | 63 | 64 | +1 |
| mostly uncovered methods | 259 | 356 | +97 |
| fixed but unmeasured | 31 | 31 | 0 |
| top hotspot file | `src/mir/fsm_lowering.rb` | `src/mir/mir_lowering.rb` | shifted |

### Cleanup Pass (`2026-06-03T15:42Z` coverage)

Coverage was regenerated with:

- `rm -rf coverage && COVERAGE=1 bundle exec prspec spec`
- `COVERAGE=1 bundle exec ruby transpile-tests/gen.rb`
- `bundle exec ruby spec/collate_coverage.rb`

Verification result: `5155 examples, 0 failures`; transpile generation processed 470 files. Collated coverage is 96.12% line coverage and 79.80% branch coverage.

| SlopCop scope | files | dark arms | genuine gaps | delta vs WIP `1929` | delta vs base `1388` |
|---|---:|---:|---:|---:|---:|
| base snapshot | 93 | 6023 | 1388 | -541 | 0 |
| WIP before cleanup | 93 | 8014 | 1929 | 0 | +541 |
| cleanup, normalized old `src` scope | 88 | 3614 | 1230 | -699 | -158 |
| cleanup, full current `src` scope | 111 | 4149 | 1532 | -397 | +144 |

The normalized scope is the fair comparison for the user's `1388 -> 1929 (+541)` goalpost. It uses the original rebased coverage file's `src/**/*.rb` file list against the refreshed current coverage. The file count drops to 88 because some original covered files are no longer SlopCop report files under the current source/resultset pairing. On that comparable scope, the cleanup closes more than 90% of the regression and lands below the original baseline. The full current `src` run is still useful for future cleanup, but it includes 111 files and is not directly comparable to the 93-file base/WIP reports.

Removed as low-value performance complexity:

- `AST.each_locatable` member caches and specialized generated walker branches; one structural traversal path remains.
- `TypeShape.from_core` and `Type.strip_capability_suffix_from` branch-level caches.
- `TypeCapabilities#with` and `TypePlacement#with` return-self fast exits; copying now returns an independent typed value.
- `UseAfterMoveChecker#block_exit_cleanup_summaries` memoization; cleanup summaries are computed directly.
- `SemanticAnnotator::VISITOR_METHOD_CACHE`; visitor dispatch has one direct path again.
- Branch-added VM emitter comments that described structural handling as fast/slow paths.

Kept as correctness/architecture work:

- Stronger Type and MIR metadata signatures, especially MIR annotations requiring `Type` instead of strings.
- Scope and ownership state changes that prevent duplicated ownership facts and repeated MIR ownership finalization.
- Existing semantic caches that predate this cleanup and are not alternate fast/slow implementations, such as `Type#zig_type` invalidation and `ModuleImporter#module_cache`.

Remaining SlopCop queue after cleanup is concentrated in real compiler behavior, not deleted micro-optimizations. Priority order:

1. MIR ownership finalization: `append_transfer_marks_to_body!`, `implicit_allocating_result_fact`, `append_ownership_transfer_targets_for_surface_node!`, `ownership_operands_for_sink_value`, `collect_moved_arg_roots`, `walk_ast_for_moved_args`, `transfer_binding_name`, and `lower_body_with_break`.
2. MIR hoisting and allocation metadata: `collect_stmt_hoists!`, `mir_alloc_mark_type_info`, `normalize_allocating_used_expr`, and `stamp_allocating_result_target!`.
3. Capability lowering and annotator capability scopes: `emit_sorted_lock_acquires_fallible`, `declare_capability_scope!`, `with_capability_alias_maps`, `ast_contains_return?`, `lower_pre_clauses`, and sorted acquire entry construction.

Testing strategy for the remaining queue should exercise the real compiler path: minivm-style switch/match programs, same-size no-match control files, and focused MIR ownership integration specs that assert emitted ownership facts and cleanups. Do not add tests for removed caches or duplicated old paths.

## Changed Function Findings

Flagging rule: a changed function is listed if the changed lines intersect a function that has at least one of: no coverage data or uncovered executable lines in the current resultset, `T.untyped`, bare `Object`, Decomplex site findings, SlopCop genuine gaps, or Boobytrap mostly-uncovered method risk (`line_gap >= 0.80`). This intentionally includes functions that were already bad before the branch if this branch touched them.

| finding class | functions | extra count |
|---|---:|---:|
| no coverage data | 202 | - |
| uncovered executable lines | 190 | 1966 lines |
| `T.untyped` | 144 | 345 slots in changed function/sig regions |
| bare `Object` | 24 | 33 slots in changed function/sig regions |
| Decomplex site findings | 384 | 2225 findings |
| SlopCop genuine gaps | 117 | 382 gap arms |
| Boobytrap mostly-dark methods | 9 | `line_gap >= 0.80` |
| **total flagged changed functions** | **594** | - |

Top files by flagged changed functions:

| file | flagged functions |
|---|---:|
| `tools/profile_pass_work.rb` | 62 |
| `src/mir/mir_lowering.rb` | 60 |
| `src/ast/ast.rb` | 43 |
| `src/semantic/pass_work_profiler.rb` | 43 |
| `src/ast/scope.rb` | 34 |
| `src/mir/control_flow.rb` | 24 |
| `src/backends/pipeline_host.rb` | 23 |
| `src/mir/mir.rb` | 19 |
| `tools/profile_structural_multipliers.rb` | 19 |
| `src/mir/mir_checker.rb` | 17 |
| `src/semantic/escape_analysis.rb` | 16 |
| `tools/trace_method_times.rb` | 14 |
| `examples/minivm/register_bc_emitter.rb` | 12 |
| `src/mir/fsm_transform/emit.rb` | 12 |
| `examples/minivm/bc_emitter.rb` | 10 |
| `src/mir/cleanup_classifier.rb` | 9 |
| `src/mir/lowering/variables.rb` | 9 |
| `tools/sample_compile_stacks.rb` | 9 |
| `src/ast/type.rb` | 8 |
| `tools/dump_mir_tree.rb` | 8 |

Highest-risk changed functions by the combined inventory ordering:

| function | issues | coverage | typing | decomplex | slopcop | boobytrap |
|---|---|---|---|---|---|---|
| [src/annotator/helpers/fixable_helpers.rb:1202](../../src/annotator/helpers/fixable_helpers.rb#L1202) `build_decl_cap_insert_fix` | uncovered, untyped, decomplex, boobytrap | 13/14 uncovered: 1203-1210,1213-1217 | T=2; Object=0 | 3: Decision Pressure=2, Missing Abstractions=1 | - | risk=28.07; gap=92.9%; missed=13/14 |
| [src/annotator/helpers/fixable_helpers.rb:1230](../../src/annotator/helpers/fixable_helpers.rb#L1230) `build_decl_cap_replace_fix` | uncovered, untyped, decomplex, boobytrap | 11/12 uncovered: 1231-1241 | T=3; Object=0 | 3: Decision Pressure=2, Missing Abstractions=1 | - | risk=25.08; gap=91.7%; missed=11/12 |
| [src/mir/cleanup_classifier.rb:855](../../src/mir/cleanup_classifier.rb#L855) `self.classify_owned_string` | uncovered, decomplex, slopcop, boobytrap | 10/12 uncovered: 857-859,861-862,866-870 | - | 2: Decision Pressure=1, False Simplicity=1 | 1 gaps lines 856 | risk=24.83; gap=83.3%; missed=10/12 |
| [src/ast/ast.rb:1654](../../src/ast/ast.rb#L1654) `coerce!` | uncovered, decomplex | 3/5 uncovered: 1655-1656,1658 | - | 8: Decision Pressure=2, False Simplicity=2, Neglected Path Conditions=3, Neglected Updates=1 | - | risk=14.30; gap=60.0%; missed=3/5 |
| [src/annotator/helpers/method_analysis.rb:33](../../src/annotator/helpers/method_analysis.rb#L33) `narrow_collection_type!` | uncovered, untyped, decomplex, slopcop | 8/19 uncovered: 46-53 | T=1; Object=0 | 10: Decision Pressure=5, False Simplicity=5 | 1 gaps lines 43 | risk=12.87; gap=42.1%; missed=8/19 |
| [src/annotator/domains/member_access.rb:464](../../src/annotator/domains/member_access.rb#L464) `visit_DefaultArrayLit` | uncovered, decomplex, boobytrap | 5/6 uncovered: 465-469 | - | 8: False Simplicity=2, Neglected Updates=6 | - | risk=8.67; gap=83.3%; missed=5/6 |
| [src/mir/cleanup_classifier.rb:751](../../src/mir/cleanup_classifier.rb#L751) `self.classify_array_struct_strings` | uncovered, untyped, decomplex, slopcop | 3/8 uncovered: 757-759 | T=1; Object=0 | 2: Broken Protocols=1, Decision Pressure=1 | 1 gaps lines 756 | risk=8.62; gap=37.5%; missed=3/8 |
| [src/mir/fsm_transform/recursive_splitter.rb:100](../../src/mir/fsm_transform/recursive_splitter.rb#L100) `initialize` | uncovered, untyped | 5/7 uncovered: 101-105 | T=1; Object=0 | - | - | risk=8.57; gap=71.4%; missed=5/7 |
| [src/backends/pipeline_host.rb:4579](../../src/backends/pipeline_host.rb#L4579) `lower_concurrent_list_count` | uncovered, untyped, decomplex | 6/8 uncovered: 4581-4583,4585,4597-4598 | T=1; Object=0 | 3: Broken Protocols=2, False Simplicity=1 | - | risk=8.50; gap=75.0%; missed=6/8 |
| [src/backends/pipeline_host.rb:4552](../../src/backends/pipeline_host.rb#L4552) `lower_concurrent_list_where` | uncovered, untyped, decomplex | 6/8 uncovered: 4554-4556,4558,4571-4572 | T=2; Object=0 | 2: Broken Protocols=1, False Simplicity=1 | - | risk=8.50; gap=75.0%; missed=6/8 |
| [src/mir/fsm_lowering.rb:344](../../src/mir/fsm_lowering.rb#L344) `lower_finalized_fsm_step_mir` | uncovered, decomplex, boobytrap | 6/7 uncovered: 345-350 | - | 2: False Simplicity=2 | - | risk=8.14; gap=85.7%; missed=6/7 |
| [src/backends/pipeline_host.rb:4523](../../src/backends/pipeline_host.rb#L4523) `lower_concurrent_list_select` | uncovered, untyped, decomplex | 7/9 uncovered: 4525-4528,4530,4544-4545 | T=1; Object=0 | 2: False Simplicity=2 | - | risk=7.94; gap=77.8%; missed=7/9 |
| [src/mir/mir_lowering.rb:1023](../../src/mir/mir_lowering.rb#L1023) `append_already_finalized_node!` | uncovered, decomplex | 2/5 uncovered: 1026-1027 | - | 3: Decision Pressure=1, False Simplicity=2 | - | risk=7.80; gap=40.0%; missed=2/5 |
| [src/mir/mir_lowering.rb:1137](../../src/mir/mir_lowering.rb#L1137) `materialize_statement_discard` | uncovered, untyped, decomplex, slopcop | 1/17 uncovered: 1148 | T=3; Object=0 | 5: Broken Protocols=1, False Simplicity=2, Neglected Updates=2 | 1 gaps lines 1142 | risk=7.56; gap=5.9%; missed=1/17 |
| [src/ast/scope.rb:131](../../src/ast/scope.rb#L131) `install_entry` | uncovered, decomplex, boobytrap | 4/5 uncovered: 132-135 | - | 3: False Simplicity=3 | - | risk=6.70; gap=80.0%; missed=4/5 |
| [src/mir/fsm_transform/segments.rb:77](../../src/mir/fsm_transform/segments.rb#L77) `result_type` | uncovered, decomplex, boobytrap | 4/5 uncovered: 78-79,81-82 | - | 1: False Simplicity=1 | - | risk=6.70; gap=80.0%; missed=4/5 |
| [src/ast/scope.rb:375](../../src/ast/scope.rb#L375) `declare_with_new_capability` | uncovered, decomplex | 1/11 uncovered: 386 | - | 5: Decision Pressure=1, False Simplicity=4 | - | risk=6.59; gap=9.1%; missed=1/11 |
| [src/mir/fsm_transform/suspend_resolvers.rb:250](../../src/mir/fsm_transform/suspend_resolvers.rb#L250) `ownership_bearing_result_type?` | uncovered, untyped, decomplex, boobytrap | 4/5 uncovered: 251-253,256 | T=1; Object=0 | 1: False Simplicity=1 | - | risk=5.70; gap=80.0%; missed=4/5 |
| [src/annotator/helpers/capabilities.rb:668](../../src/annotator/helpers/capabilities.rb#L668) `alias_mutated?` | uncovered, boobytrap | 4/5 uncovered: 669-672 | - | - | - | risk=5.20; gap=80.0%; missed=4/5 |
| [src/mir/mir_lowering.rb:1568](../../src/mir/mir_lowering.rb#L1568) `ownership_transfer_contract_relevant?` | uncovered, decomplex | 1/7 uncovered: 1571 | - | 2: Decision Pressure=2 | - | risk=5.14; gap=14.3%; missed=1/7 |
| [src/ast/scope.rb:290](../../src/ast/scope.rb#L290) `visible_names` | uncovered, decomplex | 3/6 uncovered: 291-292,295 | - | 1: False Simplicity=1 | - | risk=4.00; gap=50.0%; missed=3/6 |
| [src/ast/scope.rb:108](../../src/ast/scope.rb#L108) `declare` | uncovered, untyped, decomplex | 1/9 uncovered: 128 | T=4; Object=0 | 3: False Simplicity=3 | - | risk=3.61; gap=11.1%; missed=1/9 |
| [src/mir/mir_lowering.rb:1401](../../src/mir/mir_lowering.rb#L1401) `append_implicit_alloc_fact!` | uncovered, decomplex | 1/10 uncovered: 1411 | - | 4: Broken Protocols=1, False Simplicity=3 | - | risk=3.60; gap=10.0%; missed=1/10 |
| [src/mir/control_flow.rb:1715](../../src/mir/control_flow.rb#L1715) `check_explicit_moves` | uncovered, decomplex | 2/5 uncovered: 1717-1718 | - | 1: False Simplicity=1 | - | risk=3.30; gap=40.0%; missed=2/5 |
| [src/ast/scope.rb:249](../../src/ast/scope.rb#L249) `clone_entry_for_scope` | uncovered, decomplex | 1/6 uncovered: 254 | - | 3: Broken Protocols=1, False Simplicity=2 | - | risk=1.67; gap=16.7%; missed=1/6 |

## Review Notes

The branch improves the source typing baseline substantially (`TOTAL.untyped` drops by 325), but the changed surface is still not clean: 164 flagged changed functions still contain `T.untyped` or `Object` in the function or attached sig region. The original WIP expanded SlopCop genuine gaps by 541 and Boobytrap mostly-uncovered methods by 97 in the available resultset. After the cleanup pass, the normalized SlopCop count is 1230, which is below the 1388 base count; the full current `src` run is 1532 because it includes additional source files.

The largest local cleanup concentration is not a single file: `src/mir/mir_lowering.rb`, `src/ast/ast.rb`, `src/semantic/pass_work_profiler.rb`, `src/ast/scope.rb`, `src/mir/control_flow.rb`, and `src/backends/pipeline_host.rb` all have substantial changed-function issue counts. The newly added profiling tools under `tools/` dominate the inventory by function count, but they are outside `src` and the current coverage resultset does not measure them. If those tools stay, they need either dedicated coverage expectations or should be explicitly excluded from production quality gates; otherwise they are permanent dark code.

The highest-risk source rows are mostly MIR/annotator functions with both uncovered paths and structural warnings. The worst recurring patterns are large visitor/lowering functions with `Decision Pressure`, `False Simplicity`, `Broken Protocols`, and `Neglected Path Conditions`; these are exactly the areas where small local tweaks are least trustworthy. Cleanup should continue by reducing those method-level responsibilities and adding focused tests around the dark branches in the real compiler path, not by adding alternate fast/slow paths.

## Complete Changed Function Inventory

Columns: `changed` is the current-line range touched by the branch inside that function. `coverage` is based on the original current resultset used to build this inventory; the refreshed aggregate metrics above supersede its SlopCop totals. `typing` counts `T.untyped` and bare `Object` in the function body plus attached sig window. `decomplex` is joined by `file#method` because Decomplex does not carry method ranges in this report; duplicate method names may therefore be coarse. `slopcop` is joined by uncovered-arm line containment inside the method range. `boobytrap` is joined by exact method range.

| # | function | changed | issues | coverage | typing | decomplex | slopcop | boobytrap |
|---:|---|---|---|---|---|---|---|---|
| 1 | [src/annotator/helpers/fixable_helpers.rb:1202](../../src/annotator/helpers/fixable_helpers.rb#L1202) `build_decl_cap_insert_fix` | 1206 | uncovered, untyped, decomplex, boobytrap | 13/14 uncovered: 1203-1210,1213-1217 | T=2; Object=0 | 3: Decision Pressure=2, Missing Abstractions=1 | - | risk=28.07; gap=92.9%; missed=13/14 |
| 2 | [src/annotator/helpers/fixable_helpers.rb:1230](../../src/annotator/helpers/fixable_helpers.rb#L1230) `build_decl_cap_replace_fix` | 1234 | uncovered, untyped, decomplex, boobytrap | 11/12 uncovered: 1231-1241 | T=3; Object=0 | 3: Decision Pressure=2, Missing Abstractions=1 | - | risk=25.08; gap=91.7%; missed=11/12 |
| 3 | [src/mir/cleanup_classifier.rb:855](../../src/mir/cleanup_classifier.rb#L855) `self.classify_owned_string` | 855,857,861 | uncovered, decomplex, slopcop, boobytrap | 10/12 uncovered: 857-859,861-862,866-870 | - | 2: Decision Pressure=1, False Simplicity=1 | 1 gaps lines 856 | risk=24.83; gap=83.3%; missed=10/12 |
| 4 | [src/ast/ast.rb:1654](../../src/ast/ast.rb#L1654) `coerce!` | 1654-1659 | uncovered, decomplex | 3/5 uncovered: 1655-1656,1658 | - | 8: Decision Pressure=2, False Simplicity=2, Neglected Path Conditions=3, Neglected Updates=1 | - | risk=14.30; gap=60.0%; missed=3/5 |
| 5 | [src/annotator/helpers/method_analysis.rb:33](../../src/annotator/helpers/method_analysis.rb#L33) `narrow_collection_type!` | 43 | uncovered, untyped, decomplex, slopcop | 8/19 uncovered: 46-53 | T=1; Object=0 | 10: Decision Pressure=5, False Simplicity=5 | 1 gaps lines 43 | risk=12.87; gap=42.1%; missed=8/19 |
| 6 | [src/annotator/domains/member_access.rb:464](../../src/annotator/domains/member_access.rb#L464) `visit_DefaultArrayLit` | 464-470 | uncovered, decomplex, boobytrap | 5/6 uncovered: 465-469 | - | 8: False Simplicity=2, Neglected Updates=6 | - | risk=8.67; gap=83.3%; missed=5/6 |
| 7 | [src/mir/cleanup_classifier.rb:751](../../src/mir/cleanup_classifier.rb#L751) `self.classify_array_struct_strings` | 753-754 | uncovered, untyped, decomplex, slopcop | 3/8 uncovered: 757-759 | T=1; Object=0 | 2: Broken Protocols=1, Decision Pressure=1 | 1 gaps lines 756 | risk=8.62; gap=37.5%; missed=3/8 |
| 8 | [src/mir/fsm_transform/recursive_splitter.rb:100](../../src/mir/fsm_transform/recursive_splitter.rb#L100) `initialize` | 102-105 | uncovered, untyped | 5/7 uncovered: 101-105 | T=1; Object=0 | - | - | risk=8.57; gap=71.4%; missed=5/7 |
| 9 | [src/backends/pipeline_host.rb:4579](../../src/backends/pipeline_host.rb#L4579) `lower_concurrent_list_count` | 4597,4601 | uncovered, untyped, decomplex | 6/8 uncovered: 4581-4583,4585,4597-4598 | T=1; Object=0 | 3: Broken Protocols=2, False Simplicity=1 | - | risk=8.50; gap=75.0%; missed=6/8 |
| 10 | [src/backends/pipeline_host.rb:4552](../../src/backends/pipeline_host.rb#L4552) `lower_concurrent_list_where` | 4571,4575 | uncovered, untyped, decomplex | 6/8 uncovered: 4554-4556,4558,4571-4572 | T=2; Object=0 | 2: Broken Protocols=1, False Simplicity=1 | - | risk=8.50; gap=75.0%; missed=6/8 |
| 11 | [src/mir/fsm_lowering.rb:344](../../src/mir/fsm_lowering.rb#L344) `lower_finalized_fsm_step_mir` | 346 | uncovered, decomplex, boobytrap | 6/7 uncovered: 345-350 | - | 2: False Simplicity=2 | - | risk=8.14; gap=85.7%; missed=6/7 |
| 12 | [src/backends/pipeline_host.rb:4523](../../src/backends/pipeline_host.rb#L4523) `lower_concurrent_list_select` | 4544,4548 | uncovered, untyped, decomplex | 7/9 uncovered: 4525-4528,4530,4544-4545 | T=1; Object=0 | 2: False Simplicity=2 | - | risk=7.94; gap=77.8%; missed=7/9 |
| 13 | [src/mir/mir_lowering.rb:1023](../../src/mir/mir_lowering.rb#L1023) `append_already_finalized_node!` | 1023-1027 | uncovered, decomplex | 2/5 uncovered: 1026-1027 | - | 3: Decision Pressure=1, False Simplicity=2 | - | risk=7.80; gap=40.0%; missed=2/5 |
| 14 | [src/mir/mir_lowering.rb:1137](../../src/mir/mir_lowering.rb#L1137) `materialize_statement_discard` | 1153 | uncovered, untyped, decomplex, slopcop | 1/17 uncovered: 1148 | T=3; Object=0 | 5: Broken Protocols=1, False Simplicity=2, Neglected Updates=2 | 1 gaps lines 1142 | risk=7.56; gap=5.9%; missed=1/17 |
| 15 | [src/ast/scope.rb:131](../../src/ast/scope.rb#L131) `install_entry` | 131-136 | uncovered, decomplex, boobytrap | 4/5 uncovered: 132-135 | - | 3: False Simplicity=3 | - | risk=6.70; gap=80.0%; missed=4/5 |
| 16 | [src/mir/fsm_transform/segments.rb:77](../../src/mir/fsm_transform/segments.rb#L77) `result_type` | 82 | uncovered, decomplex, boobytrap | 4/5 uncovered: 78-79,81-82 | - | 1: False Simplicity=1 | - | risk=6.70; gap=80.0%; missed=4/5 |
| 17 | [src/ast/scope.rb:375](../../src/ast/scope.rb#L375) `declare_with_new_capability` | 377,380,384-385 | uncovered, decomplex | 1/11 uncovered: 386 | - | 5: Decision Pressure=1, False Simplicity=4 | - | risk=6.59; gap=9.1%; missed=1/11 |
| 18 | [src/mir/fsm_transform/suspend_resolvers.rb:250](../../src/mir/fsm_transform/suspend_resolvers.rb#L250) `ownership_bearing_result_type?` | 253-254 | uncovered, untyped, decomplex, boobytrap | 4/5 uncovered: 251-253,256 | T=1; Object=0 | 1: False Simplicity=1 | - | risk=5.70; gap=80.0%; missed=4/5 |
| 19 | [src/annotator/helpers/capabilities.rb:668](../../src/annotator/helpers/capabilities.rb#L668) `alias_mutated?` | 672 | uncovered, boobytrap | 4/5 uncovered: 669-672 | - | - | - | risk=5.20; gap=80.0%; missed=4/5 |
| 20 | [src/mir/mir_lowering.rb:1568](../../src/mir/mir_lowering.rb#L1568) `ownership_transfer_contract_relevant?` | 1568-1574 | uncovered, decomplex | 1/7 uncovered: 1571 | - | 2: Decision Pressure=2 | - | risk=5.14; gap=14.3%; missed=1/7 |
| 21 | [src/ast/scope.rb:290](../../src/ast/scope.rb#L290) `visible_names` | 290-295 | uncovered, decomplex | 3/6 uncovered: 291-292,295 | - | 1: False Simplicity=1 | - | risk=4.00; gap=50.0%; missed=3/6 |
| 22 | [src/ast/scope.rb:108](../../src/ast/scope.rb#L108) `declare` | 127 | uncovered, untyped, decomplex | 1/9 uncovered: 128 | T=4; Object=0 | 3: False Simplicity=3 | - | risk=3.61; gap=11.1%; missed=1/9 |
| 23 | [src/mir/mir_lowering.rb:1401](../../src/mir/mir_lowering.rb#L1401) `append_implicit_alloc_fact!` | 1402,1406-1410 | uncovered, decomplex | 1/10 uncovered: 1411 | - | 4: Broken Protocols=1, False Simplicity=3 | - | risk=3.60; gap=10.0%; missed=1/10 |
| 24 | [src/mir/control_flow.rb:1715](../../src/mir/control_flow.rb#L1715) `check_explicit_moves` | 1715-1719 | uncovered, decomplex | 2/5 uncovered: 1717-1718 | - | 1: False Simplicity=1 | - | risk=3.30; gap=40.0%; missed=2/5 |
| 25 | [src/ast/scope.rb:249](../../src/ast/scope.rb#L249) `clone_entry_for_scope` | 249-254 | uncovered, decomplex | 1/6 uncovered: 254 | - | 3: Broken Protocols=1, False Simplicity=2 | - | risk=1.67; gap=16.7%; missed=1/6 |
| 26 | [src/ast/ast.rb:355](../../src/ast/ast.rb#L355) `self.each_locatable` | 356,370-442,445-447 | untyped, decomplex, slopcop | covered | T=1; Object=0 | 7: Broken Protocols=2, Decision Pressure=2, False Simplicity=3 | 50 gaps lines 376,378-379,384,388,390-391,393,397,399,401-402,404,407,409,413-427,429,431-438 | - |
| 27 | [src/mir/mir_emitter.rb:47](../../src/mir/mir_emitter.rb#L47) `emit` | 147 | uncovered, untyped, decomplex, slopcop | 49/119 uncovered: 49-50,53,58-60,70,72,78-85,89,94-95,98,104,112-113,115-118,124-127,135,138,144,146-148,154,156,159,164,166-170,173,176,181 | T=1; Object=0 | 1: Broken Protocols=1 | 48 gaps lines 49-50,53,58-60,70,72,78-85,89,94-95,98,104,112-113,115-118,124-127,135,138,144,146-148,154,156,159,164,166-170,173,176 | - |
| 28 | [src/mir/mir_lowering.rb:793](../../src/mir/mir_lowering.rb#L793) `lower` | 805,852 | uncovered, untyped, decomplex, slopcop | 15/117 uncovered: 795-798,807,813,854-855,857,872,884-886,888,899 | T=3; Object=0 | 6: Decision Pressure=1, Neglected Updates=5 | 15 gaps lines 797,810,852,857,872-873,879,884,899-903,905,912 | - |
| 29 | [src/annotator/domains/control_flow.rb:330](../../src/annotator/domains/control_flow.rb#L330) `visit_MatchStatement` | 428,436,442,448 | uncovered, decomplex, slopcop | 17/131 uncovered: 365,380,398,410,423,483-486,493,535,550-551,558,564,577-578 | - | 97: Broken Protocols=1, Decision Pressure=4, False Simplicity=25, Neglected Path Conditions=62, Neglected Updates=5 | 11 gaps lines 354,365,398,410,481,483,535,550,558,564,577 | - |
| 30 | [src/ast/type.rb:3150](../../src/ast/type.rb#L3150) `self.strip_capability_suffix_from` | 3151-3160,3181-3183 | uncovered, decomplex, slopcop | 6/31 uncovered: 3153,3155,3169-3171,3176 | - | 2: Broken Protocols=1, False Simplicity=1 | 11 gaps lines 3167-3177 | - |
| 31 | [src/annotator/annotator.rb:573](../../src/annotator/annotator.rb#L573) `visit_RequireNode` | 591 | uncovered, untyped, decomplex, slopcop | 1/36 uncovered: 575 | T=1; Object=0 | 9: Broken Protocols=6, False Simplicity=3 | 9 gaps lines 574-575,579,597-598,606,617-619 | - |
| 32 | [src/annotator/helpers/union.rb:14](../../src/annotator/helpers/union.rb#L14) `validate_union_methods!` | 33,50 | uncovered, untyped, decomplex, slopcop | 12/47 uncovered: 22,49-50,56-57,62-65,71,81,90 | T=2; Object=0 | 4: Decision Pressure=1, False Simplicity=3 | 9 gaps lines 22,49,56,62,71,78,81,86,90 | - |
| 33 | [src/annotator/helpers/function_analysis.rb:735](../../src/annotator/helpers/function_analysis.rb#L735) `declare_and_verify_params` | 804,813-814 | uncovered, decomplex, slopcop | 5/50 uncovered: 746,754,763,772,774 | - | 32: Broken Protocols=4, Decision Pressure=3, False Simplicity=10, Neglected Path Conditions=15 | 7 gaps lines 744,746,750,754,763,772,788 | - |
| 34 | [src/annotator/helpers/capabilities.rb:808](../../src/annotator/helpers/capabilities.rb#L808) `declare_capability_scope!` | 812,833,852,879,897,928,936,955 | uncovered, untyped, decomplex, slopcop | 18/91 uncovered: 826-828,830-836,855,860,941-944,946,948 | T=1; Object=0 | 88: Broken Protocols=10, Decision Pressure=5, Derived-State Staleness=1, False Simplicity=6, Neglected Path Conditions=66 | 6 gaps lines 851,855,860,937,941,954 | - |
| 35 | [src/semantic/escape_analysis.rb:94](../../src/semantic/escape_analysis.rb#L94) `self.apply!` | 122,124 | decomplex, slopcop | covered | - | 13: False Simplicity=13 | 6 gaps lines 102,104,112-114,118 | - |
| 36 | [src/annotator/helpers/capabilities.rb:138](../../src/annotator/helpers/capabilities.rb#L138) `validate_capability` | 180 | uncovered, decomplex, slopcop | 38/60 uncovered: 142,154-156,171-172,174-175,181,193-194,196-197,206-207,217-224,226,228,241-242,251-252,261-264,266-269,278 | - | 12: Decision Pressure=2, Derived-State Staleness=1, False Simplicity=8, Neglected Path Conditions=1 | 6 gaps lines 142,206,217,241,251,278 | - |
| 37 | [src/annotator/domains/errors.rb:207](../../src/annotator/domains/errors.rb#L207) `resolve_catch_clause!` | 252-254 | uncovered, decomplex, slopcop | 3/29 uncovered: 216,226,246 | - | 10: Broken Protocols=3, False Simplicity=7 | 6 gaps lines 216,222,226,233,242,246 | - |
| 38 | [src/backends/pipeline_host.rb:2141](../../src/backends/pipeline_host.rb#L2141) `lower_join` | 2206 | uncovered, decomplex, slopcop | 4/39 uncovered: 2166-2168,2187 | - | 3: Decision Pressure=1, False Simplicity=2 | 6 gaps lines 2166,2175,2178,2187,2207,2214 | - |
| 39 | [src/annotator/domains/variables.rb:290](../../src/annotator/domains/variables.rb#L290) `visit_BindExpr` | 302,309-311,335 | uncovered, decomplex, slopcop | 12/57 uncovered: 309-310,315,317,341-343,345-349 | - | 44: Decision Pressure=2, False Simplicity=15, Missing Abstractions=1, Neglected Path Conditions=20, Neglected Updates=6 | 5 gaps lines 309,317,342,347,350 | - |
| 40 | [src/mir/cleanup_classifier.rb:496](../../src/mir/cleanup_classifier.rb#L496) `self.capture_expr_heap?` | 496 | uncovered, decomplex, slopcop | 6/12 uncovered: 499,503,507-509,511 | - | 3: Decision Pressure=3 | 5 gaps lines 499,501,505-506,511 | - |
| 41 | [src/annotator/domains/variables.rb:97](../../src/annotator/domains/variables.rb#L97) `finalize_decl_node!` | 219-221,228,242,270 | uncovered, decomplex, slopcop | 11/80 uncovered: 125,143-145,149-150,160-161,173,266-267 | - | 58: Broken Protocols=6, Decision Pressure=5, False Simplicity=28, Neglected Path Conditions=19 | 4 gaps lines 167,173,249,267 | - |
| 42 | [src/annotator/domains/control_flow.rb:591](../../src/annotator/domains/control_flow.rb#L591) `visit_ForRange` | 608-609 | decomplex, slopcop | covered | - | 20: Broken Protocols=11, Decision Pressure=1, False Simplicity=8 | 4 gaps lines 599-600,603,615 | - |
| 43 | [src/annotator/helpers/capabilities.rb:579](../../src/annotator/helpers/capabilities.rb#L579) `visit_post_clauses!` | 596 | uncovered, decomplex, slopcop | 3/32 uncovered: 591,598,635 | - | 13: Broken Protocols=3, Decision Pressure=4, False Simplicity=3, Missing Abstractions=3 | 4 gaps lines 591,597,610,635 | - |
| 44 | [src/mir/hoist.rb:1147](../../src/mir/hoist.rb#L1147) `hoist_cleanup_entry` | 1181 | uncovered, untyped, decomplex, slopcop | 12/24 uncovered: 1153-1155,1166-1171,1174,1178,1186 | T=2; Object=0 | 5: Broken Protocols=4, False Simplicity=1 | 4 gaps lines 1153,1166,1174,1178 | - |
| 45 | [src/mir/mir_lowering.rb:1216](../../src/mir/mir_lowering.rb#L1216) `scan_ownership_surface!` | 1216-1218,1220-1222,1224-1228 | decomplex, slopcop | covered | - | 4: False Simplicity=3, Neglected Updates=1 | 4 gaps lines 1221-1222,1226-1227 | - |
| 46 | [src/mir/cleanup_classifier.rb:471](../../src/mir/cleanup_classifier.rb#L471) `self.walk_capture_bindings` | 471,477,481 | uncovered, decomplex, slopcop | 1/15 uncovered: 484 | - | 3: False Simplicity=3 | 4 gaps lines 476,478,481,484 | - |
| 47 | [src/mir/mir_lowering.rb:1190](../../src/mir/mir_lowering.rb#L1190) `record_ownership_finalization_surface_node!` | 1190-1204 | decomplex, slopcop | covered | - | 2: False Simplicity=2 | 4 gaps lines 1193-1194,1198-1199 | - |
| 48 | [src/annotator/helpers/function_analysis.rb:96](../../src/annotator/helpers/function_analysis.rb#L96) `resolve_call` | 113 | uncovered, untyped, decomplex, slopcop | 8/69 uncovered: 102-104,109,146,217-218,221 | T=2; Object=0 | 77: Decision Pressure=5, False Simplicity=15, Missing Abstractions=1, Neglected Path Conditions=48, Neglected Updates=8 | 3 gaps lines 102,146,171 | - |
| 49 | [src/mir/lowering/control_flow.rb:534](../../src/mir/lowering/control_flow.rb#L534) `lower_match` | 552 | uncovered, untyped, decomplex, slopcop | 19/67 uncovered: 549-559,562,577,579,584,600-601,625,629 | T=1; Object=0 | 66: Broken Protocols=2, Decision Pressure=1, False Simplicity=3, Missing Abstractions=3, Neglected Path Conditions=57 | 3 gaps lines 600,604,625 | - |
| 50 | [src/mir/lowering/control_flow.rb:341](../../src/mir/lowering/control_flow.rb#L341) `for_each_loop_stmt` | 406 | uncovered, untyped, decomplex, slopcop | 10/69 uncovered: 388-389,400,404-407,414-416 | T=4; Object=0 | 34: Decision Pressure=2, Neglected Path Conditions=29, Neglected Updates=3 | 3 gaps lines 388,400,404 | - |
| 51 | [src/mir/lowering/functions.rb:1590](../../src/mir/lowering/functions.rb#L1590) `lower_intrinsic` | 1610,1660-1662 | uncovered, untyped, decomplex, slopcop | 7/88 uncovered: 1601,1603,1629,1719-1720,1740,1752 | T=1; Object=0 | 28: Decision Pressure=9, Derived-State Staleness=2, False Simplicity=9, Neglected Updates=8 | 3 gaps lines 1715,1738-1739 | - |
| 52 | [src/annotator/domains/control_flow.rb:669](../../src/annotator/domains/control_flow.rb#L669) `visit_WhileLoop` | 707-708,716 | uncovered, decomplex, slopcop | 9/35 uncovered: 676,681,698,715-720 | - | 27: Broken Protocols=2, Decision Pressure=10, False Simplicity=5, Missing Abstractions=2, Neglected Path Conditions=8 | 3 gaps lines 676,687,728 | - |
| 53 | [src/annotator/helpers/effects.rb:427](../../src/annotator/helpers/effects.rb#L427) `compute_can_fail!` | 466,548 | uncovered, untyped, decomplex, slopcop | 5/65 uncovered: 451,486-487,536,539 | T=2; Object=0 | 19: Broken Protocols=1, Decision Pressure=2, False Simplicity=4, Neglected Updates=12 | 3 gaps lines 465,486,547 | - |
| 54 | [src/annotator/domains/lifetimes.rb:520](../../src/annotator/domains/lifetimes.rb#L520) `finalize_scope` | 524-526,555-557,572-574,593 | uncovered, decomplex, slopcop | 1/42 uncovered: 540 | - | 12: Decision Pressure=3, False Simplicity=8, Missing Abstractions=1 | 3 gaps lines 526,557,574 | - |
| 55 | [src/mir/mir_lowering.rb:1038](../../src/mir/mir_lowering.rb#L1038) `append_ownership_finalized_node!` | 1039-1043,1049-1057,1060 | uncovered, decomplex, slopcop | 1/23 uncovered: 1040 | - | 9: False Simplicity=9 | 3 gaps lines 1040,1057,1063 | - |
| 56 | [src/mir/lowering/concurrency.rb:239](../../src/mir/lowering/concurrency.rb#L239) `lower_do_block` | 258 | untyped, decomplex, slopcop | covered | T=2; Object=0 | 8: Broken Protocols=2, Decision Pressure=1, False Simplicity=5 | 3 gaps lines 255,257 | - |
| 57 | [src/mir/hoist.rb:605](../../src/mir/hoist.rb#L605) `mir_alloc_mark_type_info` | 641,643 | uncovered, untyped, decomplex, slopcop | 14/42 uncovered: 616,647,649,653-654,656,659,661,666-668,671,673,675 | T=2; Object=0 | 5: Broken Protocols=1, Decision Pressure=2, False Simplicity=1, Missing Abstractions=1 | 3 gaps lines 606,616,665 | - |
| 58 | [src/ast/type.rb:3123](../../src/ast/type.rb#L3123) `parse_raw_input` | 3126,3130-3138,3141-3146 | uncovered, untyped, decomplex, slopcop | 6/23 uncovered: 3134,3142-3144,3146-3147 | T=0; Object=1 | 3: Decision Pressure=1, False Simplicity=1, Neglected Updates=1 | 3 gaps lines 3134-3135,3142 | - |
| 59 | [src/mir/mir_lowering.rb:937](../../src/mir/mir_lowering.rb#L937) `lower_body` | 945-950,953 | untyped, decomplex, slopcop | covered | T=2; Object=0 | 3: False Simplicity=3 | 3 gaps lines 938,954,959 | - |
| 60 | [src/annotator/domains/variables.rb:500](../../src/annotator/domains/variables.rb#L500) `mark_var_mutated` | 505 | decomplex, slopcop | covered | - | 1: False Simplicity=1 | 3 gaps lines 504,506 | - |
| 61 | [src/annotator/domains/variables.rb:522](../../src/annotator/domains/variables.rb#L522) `mark_var_mutated_via_call` | 527 | decomplex, slopcop | covered | - | 1: False Simplicity=1 | 3 gaps lines 526,528 | - |
| 62 | [src/mir/control_flow.rb:744](../../src/mir/control_flow.rb#L744) `join_predecessors` | 745,747-748,750,752-754 | decomplex, slopcop | covered | - | 1: False Simplicity=1 | 3 gaps lines 748,750-751 | - |
| 63 | [src/annotator/phases/expression_domains.rb:133](../../src/annotator/phases/expression_domains.rb#L133) `visit_IntrinsicFunc` | 133,139 | uncovered, decomplex, slopcop | 8/36 uncovered: 142-145,157-158,160-161 | - | 24: Decision Pressure=4, False Simplicity=13, Missing Abstractions=1, Neglected Updates=6 | 2 gaps lines 142,180 | - |
| 64 | [src/ast/type.rb:689](../../src/ast/type.rb#L689) `initialize` | 690-692,694-695,699-701,707-710,712-722 | untyped, decomplex, slopcop | covered | T=0; Object=1 | 10: Broken Protocols=2, Decision Pressure=1, False Simplicity=6, Oversized Predicates=1 | 2 gaps lines 698-699 | - |
| 65 | [src/annotator/domains/member_access.rb:10](../../src/annotator/domains/member_access.rb#L10) `visit_GetIndex` | 56-57 | uncovered, decomplex, slopcop | 7/26 uncovered: 26,47-49,51-52,54 | - | 9: Decision Pressure=2, False Simplicity=4, Neglected Path Conditions=3 | 2 gaps lines 29,47 | - |
| 66 | [src/mir/lowering/variables.rb:352](../../src/mir/lowering/variables.rb#L352) `var_decl_safe_name` | 387 | untyped, decomplex, slopcop | covered | T=4; Object=0 | 9: Decision Pressure=1, Derived-State Staleness=1, False Simplicity=1, Neglected Updates=6 | 2 gaps lines 376,384 | - |
| 67 | [src/mir/lowering/functions.rb:690](../../src/mir/lowering/functions.rb#L690) `takes_param_ownership_mir` | 704 | decomplex, slopcop | covered | - | 8: False Simplicity=2, Missing Abstractions=1, Neglected Updates=4, Reification Misses=1 | 2 gaps lines 699-700 | - |
| 68 | [src/mir/mir_lowering.rb:1068](../../src/mir/mir_lowering.rb#L1068) `append_transfer_marks_to_body!` | 1070-1074,1077-1081 | decomplex, slopcop | covered | - | 8: Decision Pressure=1, False Simplicity=7 | 2 gaps lines 1071-1072 | - |
| 69 | [src/semantic/escape_analysis.rb:781](../../src/semantic/escape_analysis.rb#L781) `self.function_facts` | 784-785,793-794,800-806 | decomplex, slopcop | covered | - | 7: Decision Pressure=1, False Simplicity=3, Missing Abstractions=3 | 2 gaps lines 782,788 | - |
| 70 | [src/annotator/domains/lifetimes.rb:703](../../src/annotator/domains/lifetimes.rb#L703) `verify_tied_return!` | 728-729 | uncovered, untyped, decomplex, slopcop | 25/33 uncovered: 715,717-720,722-724,727,730,733-734,736,738,741,749-755,759-760,763 | T=1; Object=0 | 6: Decision Pressure=4, False Simplicity=2 | 2 gaps lines 709,711 | - |
| 71 | [src/backends/pipeline_host.rb:3899](../../src/backends/pipeline_host.rb#L3899) `lower_shard_concurrent_each` | 3940 | uncovered, untyped, decomplex, slopcop | 1/36 uncovered: 3945 | T=2; Object=0 | 6: Decision Pressure=1, False Simplicity=5 | 2 gaps lines 3902,3953 | - |
| 72 | [src/mir/mir_lowering.rb:1435](../../src/mir/mir_lowering.rb#L1435) `append_transfer_marks!` | 1437-1441,1443-1447 | decomplex, slopcop | covered | - | 6: False Simplicity=6 | 2 gaps lines 1438-1439 | - |
| 73 | [src/annotator/annotator.rb:513](../../src/annotator/annotator.rb#L513) `visit` | 526-527 | uncovered, untyped, decomplex, slopcop | 4/14 uncovered: 518,520-522 | T=1; Object=0 | 5: Broken Protocols=1, Decision Pressure=1, False Simplicity=2, Fat Unions=1 | 2 gaps lines 514,521 | - |
| 74 | [src/annotator/helpers/capabilities.rb:1055](../../src/annotator/helpers/capabilities.rb#L1055) `record_capture_identifier!` | 1061 | decomplex, slopcop | covered | - | 4: False Simplicity=4 | 2 gaps lines 1063,1067 | - |
| 75 | [src/backends/pipeline_host.rb:1691](../../src/backends/pipeline_host.rb#L1691) `lower_batch_window` | 1747,1752,1758-1759,1770,1799,1804,1813-1814,1825 | uncovered, decomplex, slopcop | 1/28 uncovered: 1703 | - | 4: Decision Pressure=2, False Simplicity=2 | 2 gaps lines 1699,1719 | - |
| 76 | [src/mir/mir_lowering.rb:1821](../../src/mir/mir_lowering.rb#L1821) `ownership_transfers_for_stmt` | 1824 | decomplex, slopcop | covered | - | 4: Broken Protocols=2, Decision Pressure=2 | 2 gaps lines 1826,1829 | - |
| 77 | [src/mir/control_flow.rb:819](../../src/mir/control_flow.rb#L819) `make_owner_entry` | 821-823 | decomplex, slopcop | covered | - | 3: Decision Pressure=2, False Simplicity=1 | 2 gaps lines 824-825 | - |
| 78 | [src/mir/control_flow.rb:1618](../../src/mir/control_flow.rb#L1618) `check_stmt` | 1618-1621,1623-1625,1627-1629,1631-1633,1635-1640,1643-1656 | uncovered, decomplex, slopcop | 8/33 uncovered: 1620,1622,1627,1633,1639-1640,1645,1650 | - | 3: Decision Pressure=3 | 2 gaps lines 1632,1644 | - |
| 79 | [src/mir/lowering/control_flow.rb:745](../../src/mir/lowering/control_flow.rb#L745) `union_match_payload_bindings` | 746 | untyped, decomplex, slopcop | covered | T=2; Object=0 | 3: Broken Protocols=1, Decision Pressure=1, False Simplicity=1 | 2 gaps lines 754-755 | - |
| 80 | [src/mir/mir_lowering.rb:1795](../../src/mir/mir_lowering.rb#L1795) `implicit_allocating_result_fact` | 1795,1802,1811 | decomplex, slopcop | covered | - | 3: Decision Pressure=2, False Simplicity=1 | 2 gaps lines 1799,1814 | - |
| 81 | [src/mir/mir_lowering.rb:1874](../../src/mir/mir_lowering.rb#L1874) `append_ownership_transfer_targets_for_surface_node!` | 1874-1883,1885-1894,1896-1904,1907 | uncovered, decomplex, slopcop | 1/21 uncovered: 1888 | - | 3: Decision Pressure=2, False Simplicity=1 | 2 gaps lines 1887,1889 | - |
| 82 | [src/mir/mir_lowering.rb:2725](../../src/mir/mir_lowering.rb#L2725) `lower_union_def` | 2732,2734,2741 | uncovered, untyped, decomplex, slopcop | 7/65 uncovered: 2757,2780-2782,2784-2785,2787 | T=1; Object=0 | 3: Broken Protocols=1, Decision Pressure=1, False Simplicity=1 | 2 gaps lines 2780,2812 | - |
| 83 | [src/annotator/helpers/function_analysis.rb:1030](../../src/annotator/helpers/function_analysis.rb#L1030) `find_matching_intrinsic` | 1046-1047,1054-1055 | untyped, decomplex, slopcop | covered | T=3; Object=0 | 2: Decision Pressure=1, False Simplicity=1 | 2 gaps lines 1036,1047 | - |
| 84 | [src/annotator/phases/expression_domains.rb:268](../../src/annotator/phases/expression_domains.rb#L268) `resolve_intrinsic_method_call!` | 279-280,282 | decomplex, slopcop | covered | - | 2: Decision Pressure=1, False Simplicity=1 | 2 gaps lines 276,280 | - |
| 85 | [src/ast/ast.rb:685](../../src/ast/ast.rb#L685) `self.expression_children` | 709-710 | untyped, decomplex, slopcop | covered | T=2; Object=0 | 2: Decision Pressure=2 | 2 gaps lines 686,714 | - |
| 86 | [src/mir/cleanup_classifier.rb:808](../../src/mir/cleanup_classifier.rb#L808) `self.classify_optional` | 817 | untyped, decomplex, slopcop | covered | T=1; Object=0 | 2: Decision Pressure=1, False Simplicity=1 | 2 gaps lines 811,818 | - |
| 87 | [src/mir/control_flow.rb:729](../../src/mir/control_flow.rb#L729) `init_entry_state` | 735 | decomplex, slopcop | covered | - | 1: False Simplicity=1 | 2 gaps lines 735-736 | - |
| 88 | [src/mir/mir_lowering.rb:1111](../../src/mir/mir_lowering.rb#L1111) `lowered_stmt_packet` | 1111,1119-1125,1127,1129-1130 | uncovered, decomplex, slopcop | 1/17 uncovered: 1122 | - | 1: Decision Pressure=1 | 2 gaps lines 1113,1122 | - |
| 89 | [src/mir/mir_lowering.rb:1637](../../src/mir/mir_lowering.rb#L1637) `append_ownership_facts_for_structural_node!` | 1637,1640,1642,1644,1646 | decomplex, slopcop | covered | - | 1: False Simplicity=1 | 2 gaps lines 1641,1643 | - |
| 90 | [src/mir/mir_lowering.rb:1849](../../src/mir/mir_lowering.rb#L1849) `ownership_transfers_for_targets` | 1849-1852,1855,1859 | uncovered, decomplex, slopcop | 1/12 uncovered: 1860 | - | 1: False Simplicity=1 | 2 gaps lines 1854,1859 | - |
| 91 | [src/mir/control_flow.rb:1706](../../src/mir/control_flow.rb#L1706) `check_binding_moves` | 1706-1711 | slopcop | covered | - | - | 2 gaps lines 1707-1708 | - |
| 92 | [src/mir/lowering/control_flow.rb:289](../../src/mir/lowering/control_flow.rb#L289) `for_each_plan` | 292 | untyped, decomplex, slopcop | covered | T=3; Object=0 | 21: Broken Protocols=1, Decision Pressure=2, Derived-State Staleness=1, False Simplicity=4, Neglected Path Conditions=8, Neglected Updates=5 | 1 gaps lines 318 | - |
| 93 | [src/mir/lowering/concurrency.rb:799](../../src/mir/lowering/concurrency.rb#L799) `lower_bg_stream_block` | 849 | uncovered, untyped, decomplex, slopcop | 49/90 uncovered: 861-864,868-870,876-880,882-889,891-904,907-908,911-916,918-919,945-949 | T=6; Object=0 | 17: Decision Pressure=2, False Simplicity=8, Neglected Updates=7 | 1 gaps lines 812 | - |
| 94 | [src/annotator/domains/variables.rb:357](../../src/annotator/domains/variables.rb#L357) `visit_Identifier` | 409 | uncovered, decomplex, slopcop | 8/41 uncovered: 367,373,376,378,387-388,401,403 | - | 15: Broken Protocols=4, Decision Pressure=3, False Simplicity=8 | 1 gaps lines 369 | - |
| 95 | [src/annotator/domains/control_flow.rb:20](../../src/annotator/domains/control_flow.rb#L20) `analyze_control_flow_branches` | 53,59-61 | decomplex, slopcop | covered | - | 14: Broken Protocols=4, Decision Pressure=1, False Simplicity=7, Neglected Path Conditions=1, Reification Misses=1 | 1 gaps lines 51 | - |
| 96 | [src/annotator/domains/control_flow.rb:115](../../src/annotator/domains/control_flow.rb#L115) `visit_IfBind` | 143 | uncovered, decomplex, slopcop | 1/29 uncovered: 123 | - | 14: Broken Protocols=3, Decision Pressure=1, False Simplicity=10 | 1 gaps lines 123 | - |
| 97 | [src/annotator/helpers/function_analysis.rb:828](../../src/annotator/helpers/function_analysis.rb#L828) `verify_captures!` | 840,852 | uncovered, decomplex, slopcop | 6/20 uncovered: 837,842-845,855 | - | 14: Broken Protocols=1, Decision Pressure=2, False Simplicity=5, Neglected Updates=6 | 1 gaps lines 837 | - |
| 98 | [src/mir/lowering/concurrency.rb:1039](../../src/mir/lowering/concurrency.rb#L1039) `lower_next_expr` | 1124,1130-1131 | uncovered, untyped, decomplex, slopcop | 24/63 uncovered: 1052,1060,1066-1073,1079-1083,1108,1114,1121-1124,1129-1131 | T=4; Object=0 | 14: Decision Pressure=1, False Simplicity=3, Neglected Updates=10 | 1 gaps lines 1061 | - |
| 99 | [src/annotator/domains/control_flow.rb:630](../../src/annotator/domains/control_flow.rb#L630) `visit_ForEach` | 656-657 | uncovered, decomplex, slopcop | 1/22 uncovered: 645 | - | 13: Broken Protocols=4, Decision Pressure=2, False Simplicity=7 | 1 gaps lines 645 | - |
| 100 | [src/mir/mir_lowering.rb:1314](../../src/mir/mir_lowering.rb#L1314) `finalize_ownership_for_mir_node!` | 1315-1319,1324,1327-1342,1345 | uncovered, decomplex, slopcop | 1/31 uncovered: 1338 | - | 12: Decision Pressure=1, False Simplicity=11 | 1 gaps lines 1345 | - |
| 101 | [src/backends/pipeline_host.rb:3044](../../src/backends/pipeline_host.rb#L3044) `lower_range_fold_observable` | 3097,3100 | untyped, decomplex, slopcop | covered | T=3; Object=0 | 11: Decision Pressure=1, False Simplicity=8, Neglected Updates=2 | 1 gaps lines 3156 | - |
| 102 | [src/backends/pipeline_host.rb:2064](../../src/backends/pipeline_host.rb#L2064) `lower_stream_index` | 2106,2125 | uncovered, untyped, decomplex, slopcop | 10/28 uncovered: 2091-2093,2095,2099,2121-2122,2126,2136-2137 | T=3; Object=0 | 10: Decision Pressure=2, False Simplicity=3, Neglected Updates=5 | 1 gaps lines 2101 | - |
| 103 | [src/backends/pipeline_host.rb:3463](../../src/backends/pipeline_host.rb#L3463) `lower_range_fold` | 3518,3528,3535-3536,3552,3569,3605 | uncovered, untyped, decomplex, slopcop | 23/84 uncovered: 3489,3504,3548-3551,3553-3555,3559,3562,3565-3568,3570-3572,3576,3579,3645-3647 | T=3; Object=0 | 10: Decision Pressure=3, False Simplicity=3, Fat Unions=1, Missing Abstractions=3 | 1 gaps lines 3488 | - |
| 104 | [src/mir/cleanup_classifier.rb:252](../../src/mir/cleanup_classifier.rb#L252) `self.walk_bindings` | 252,260 | decomplex, slopcop | covered | - | 9: Broken Protocols=1, Decision Pressure=3, False Simplicity=4, Missing Abstractions=1 | 1 gaps lines 286 | - |
| 105 | [src/mir/lowering/variables.rb:435](../../src/mir/lowering/variables.rb#L435) `classified_cleanup_var_decl_plan` | 446 | decomplex, slopcop | covered | - | 9: Broken Protocols=3, Decision Pressure=1, Derived-State Staleness=1, False Simplicity=4 | 1 gaps lines 443 | - |
| 106 | [src/annotator/helpers/effects.rb:362](../../src/annotator/helpers/effects.rb#L362) `compute_needs_rt!` | 398 | decomplex, slopcop | covered | - | 8: Broken Protocols=1, Decision Pressure=4, False Simplicity=2, Neglected Updates=1 | 1 gaps lines 397 | - |
| 107 | [src/mir/cleanup_classifier.rb:563](../../src/mir/cleanup_classifier.rb#L563) `self.classify_binding` | 563,565,614 | uncovered, decomplex, slopcop | 2/43 uncovered: 594,610 | - | 6: Decision Pressure=1, False Simplicity=3, Missing Abstractions=2 | 1 gaps lines 610 | - |
| 108 | [src/mir/lowering/expressions.rb:529](../../src/mir/lowering/expressions.rb#L529) `smooth_collect_block` | 537-538,541,545 | decomplex, slopcop | covered | - | 6: Broken Protocols=2, Decision Pressure=1, Neglected Updates=3 | 1 gaps lines 537 | - |
| 109 | [src/mir/mir_lowering.rb:1353](../../src/mir/mir_lowering.rb#L1353) `append_move_guard_for_transfer_mark!` | 1373,1383-1384 | decomplex, slopcop | covered | - | 6: Decision Pressure=3, False Simplicity=3 | 1 gaps lines 1373 | - |
| 110 | [src/mir/control_flow.rb:851](../../src/mir/control_flow.rb#L851) `transfer_stmt` | 856,860,895 | uncovered, untyped, decomplex, slopcop | 6/44 uncovered: 853-854,873,892,898,915 | T=2; Object=0 | 5: Decision Pressure=2, False Simplicity=2, Fat Unions=1 | 1 gaps lines 884 | - |
| 111 | [src/mir/mir_lowering.rb:1002](../../src/mir/mir_lowering.rb#L1002) `append_lowered_statement_packet!` | 1003-1004,1008-1011,1015,1017 | uncovered, decomplex, slopcop | 1/15 uncovered: 1005 | - | 5: Decision Pressure=1, False Simplicity=4 | 1 gaps lines 1004 | - |
| 112 | [src/annotator/phases/whole_program_semantics.rb:72](../../src/annotator/phases/whole_program_semantics.rb#L72) `restamp_requires_on_signatures!` | 77 | decomplex, slopcop | covered | - | 4: Broken Protocols=2, False Simplicity=1, Neglected Updates=1 | 1 gaps lines 78 | - |
| 113 | [src/mir/control_flow.rb:1457](../../src/mir/control_flow.rb#L1457) `self.outer_frame_receiver_alloc?` | 1467-1469 | decomplex, slopcop | covered | - | 4: Broken Protocols=1, Decision Pressure=1, Missing Abstractions=2 | 1 gaps lines 1470 | - |
| 114 | [src/mir/control_flow.rb:468](../../src/mir/control_flow.rb#L468) `insert_ordered_worklist!` | 468-477 | decomplex, slopcop | covered | - | 3: Broken Protocols=1, False Simplicity=2 | 1 gaps lines 473 | - |
| 115 | [src/mir/control_flow.rb:519](../../src/mir/control_flow.rb#L519) `cleanup_decisions!` | 522,544,546 | decomplex, slopcop | covered | - | 3: Broken Protocols=1, False Simplicity=2 | 1 gaps lines 531 | - |
| 116 | [src/mir/control_flow.rb:638](../../src/mir/control_flow.rb#L638) `block_exit_cleanup_summaries` | 638-658,661-668 | decomplex, slopcop | covered | - | 3: Decision Pressure=1, False Simplicity=2 | 1 gaps lines 644 | - |
| 117 | [src/ast/scope.rb:232](../../src/ast/scope.rb#L232) `entry_for_write` | 232-241 | decomplex, slopcop | covered | - | 2: Decision Pressure=1, False Simplicity=1 | 1 gaps lines 237 | - |
| 118 | [src/ast/type.rb:65](../../src/ast/type.rb#L65) `with` | 81-125,127-140 | untyped, decomplex, slopcop | covered | T=0; Object=1 | 2: Oversized Predicates=2 | 1 gaps lines 109 | - |
| 119 | [src/ast/type.rb:233](../../src/ast/type.rb#L233) `self.from_core` | 234-237,239,245,250-252,314,317,335-337 | uncovered, decomplex, slopcop | 1/64 uncovered: 285 | - | 2: Broken Protocols=1, False Simplicity=1 | 1 gaps lines 285 | - |
| 120 | [src/backends/importer.rb:246](../../src/backends/importer.rb#L246) `sync_global_scope_function_signatures!` | 249 | untyped, decomplex, slopcop | covered | T=2; Object=0 | 2: Decision Pressure=1, False Simplicity=1 | 1 gaps lines 251 | - |
| 121 | [src/mir/control_flow.rb:488](../../src/mir/control_flow.rb#L488) `cleanup_summary` | 489,494,496,498 | decomplex, slopcop | covered | - | 2: Decision Pressure=1, False Simplicity=1 | 1 gaps lines 492 | - |
| 122 | [src/mir/control_flow.rb:806](../../src/mir/control_flow.rb#L806) `mark_moved!` | 809-810 | decomplex, slopcop | covered | - | 2: Decision Pressure=1, False Simplicity=1 | 1 gaps lines 809 | - |
| 123 | [src/semantic/escape_analysis.rb:583](../../src/semantic/escape_analysis.rb#L583) `self.mark_receiver_for_owned_sink!` | 583,591,593 | decomplex, slopcop | covered | - | 2: Decision Pressure=1, False Simplicity=1 | 1 gaps lines 586 | - |
| 124 | [src/semantic/local_binding_facts.rb:47](../../src/semantic/local_binding_facts.rb#L47) `self.each_direct_loop_node` | 48-49 | uncovered, untyped, decomplex, slopcop | 2/14 uncovered: 65-66 | T=2; Object=0 | 2: Decision Pressure=1, False Simplicity=1 | 1 gaps lines 65 | - |
| 125 | [src/annotator/annotator.rb:835](../../src/annotator/annotator.rb#L835) `visit_stmts` | 836,838-839 | decomplex, slopcop | covered | - | 1: Broken Protocols=1 | 1 gaps lines 836 | - |
| 126 | [src/ast/ast.rb:666](../../src/ast/ast.rb#L666) `self.wrapped_children` | 672-673 | uncovered, untyped, decomplex, slopcop | 1/8 uncovered: 673 | T=2; Object=0 | 1: Decision Pressure=1 | 1 gaps lines 674 | - |
| 127 | [src/ast/scope.rb:366](../../src/ast/scope.rb#L366) `mark_read` | 367 | untyped, decomplex, slopcop | covered | T=1; Object=0 | 1: False Simplicity=1 | 1 gaps lines 368 | - |
| 128 | [src/mir/cleanup_classifier.rb:40](../../src/mir/cleanup_classifier.rb#L40) `self.classify` | 40,46,59 | decomplex, slopcop | covered | - | 1: False Simplicity=1 | 1 gaps lines 41 | - |
| 129 | [src/mir/lowering/variables.rb:488](../../src/mir/lowering/variables.rb#L488) `inline_alloc_var_decl_plan` | 491 | decomplex, slopcop | covered | - | 1: Broken Protocols=1 | 1 gaps lines 489 | - |
| 130 | [src/mir/mir_lowering.rb:728](../../src/mir/mir_lowering.rb#L728) `return_destination_alloc` | 733-737 | uncovered, decomplex, slopcop | 4/14 uncovered: 730,736-737,741 | - | 1: False Simplicity=1 | 1 gaps lines 740 | - |
| 131 | [src/mir/mir_lowering.rb:1463](../../src/mir/mir_lowering.rb#L1463) `dedupe_ownership_facts` | 1463-1471 | uncovered, decomplex, slopcop | 1/9 uncovered: 1469 | - | 1: False Simplicity=1 | 1 gaps lines 1467 | - |
| 132 | [src/mir/mir_lowering.rb:1516](../../src/mir/mir_lowering.rb#L1516) `ownership_fact_targets_for_node` | 1519,1521,1527,1529,1533 | decomplex, slopcop | covered | - | 1: Broken Protocols=1 | 1 gaps lines 1533 | - |
| 133 | [src/mir/mir_lowering.rb:1538](../../src/mir/mir_lowering.rb#L1538) `ownership_fact_target_for_expr` | 1538-1553 | decomplex, slopcop | covered | - | 1: Decision Pressure=1 | 1 gaps lines 1542 | - |
| 134 | [src/mir/mir_lowering.rb:1582](../../src/mir/mir_lowering.rb#L1582) `if_bind_ownership_fact_targets` | 1583,1590,1592 | decomplex, slopcop | covered | - | 1: Decision Pressure=1 | 1 gaps lines 1588 | - |
| 135 | [src/ast/scope.rb:284](../../src/ast/scope.rb#L284) `visible_entries` | 284-287 | uncovered, slopcop | 1/4 uncovered: 287 | - | - | 1 gaps lines 285 | - |
| 136 | [src/ast/scope.rb:405](../../src/ast/scope.rb#L405) `check_validity!` | 406 | uncovered, slopcop | 1/5 uncovered: 410 | - | - | 1 gaps lines 407 | - |
| 137 | [src/backends/pipeline_host.rb:750](../../src/backends/pipeline_host.rb#L750) `owning_pipeline_temp_stmts` | 755 | untyped, slopcop | covered | T=2; Object=0 | - | 1 gaps lines 751 | - |
| 138 | [src/mir/mir.rb:3219](../../src/mir/mir.rb#L3219) `result_type` | 3219-3222 | slopcop | covered | - | - | 1 gaps lines 3220 | - |
| 139 | [src/mir/fsm_lowering.rb:74](../../src/mir/fsm_lowering.rb#L74) `lower_step_stmts` | 138-143 | uncovered, untyped, decomplex | 81/84 uncovered: 75-79,81,85-86,89-97,99-112,114-123,125-131,135-138,140-147,149-161,164-171 | T=2; Object=0 | 122: Broken Protocols=1, Decision Pressure=3, False Simplicity=6, Neglected Path Conditions=112 | - | - |
| 140 | [src/mir/mir_checker.rb:232](../../src/mir/mir_checker.rb#L232) `check_fn!` | 235,248-249,251,253,286-290,296-300,305-309,312,314-318,321-324,343,348,351-352,356 | uncovered, decomplex | 94/95 uncovered: 233-235,237-251,253-254,256,259,261-264,267,269-270,272-274,278-279,282-286,288-290,293-296,298-300,303-305,307-309,312-314,316-318,321-323,326-328,333-358,360 | - | 37: Decision Pressure=6, False Simplicity=30, Missing Abstractions=1 | - | - |
| 141 | [src/annotator/domains/control_flow.rb:746](../../src/annotator/domains/control_flow.rb#L746) `visit_WhileBindLoop` | 779,787,789,797 | uncovered, decomplex | 10/42 uncovered: 752,771,792,794,796-801 | - | 31: Broken Protocols=2, Decision Pressure=10, False Simplicity=9, Missing Abstractions=2, Neglected Path Conditions=8 | - | - |
| 142 | [src/mir/fsm_lowering.rb:213](../../src/mir/fsm_lowering.rb#L213) `fsm_result_transfer_facts` | 218,233,250 | uncovered, untyped, decomplex | 35/40 uncovered: 214-215,218-220,223-231,233-244,247-253,256-257 | T=7; Object=0 | 25: Decision Pressure=4, False Simplicity=3, Neglected Path Conditions=12, Neglected Updates=6 | - | - |
| 143 | [src/mir/fsm_transform/emit.rb:576](../../src/mir/fsm_transform/emit.rb#L576) `build_recursive` | 578-591,594,620,622,648,677,681,687-691,700-701,709,713,726,737-738,757,763,766,770,774,786,793-794,893-894,910 | uncovered, untyped, decomplex | 236/245 uncovered: 577-578,580-591,593-597,599-600,602-607,609,614-615,620-621,624,626,628-636,638,644-656,658,673-691,693-703,705-709,711,713,715-719,723,726-743,745-755,757-760,763-764,766-770,774,776-790,792-796,798,800-801,804,811,816,821,824-829,831-83... | T=1; Object=3 | 20: Decision Pressure=6, Derived-State Staleness=2, False Simplicity=11, Missing Abstractions=1 | - | - |
| 144 | [src/annotator/helpers/fixable_helpers.rb:245](../../src/annotator/helpers/fixable_helpers.rb#L245) `emit_use_of_moved_error!` | 310 | uncovered, untyped, decomplex | 44/45 uncovered: 246-251,260-264,266-267,271-272,286-288,297-305,309-314,321-325,338-341,343,346 | T=1; Object=0 | 18: Decision Pressure=3, False Simplicity=3, Neglected Path Conditions=12 | - | - |
| 145 | [src/mir/mir.rb:2848](../../src/mir/mir.rb#L2848) `ownership_effect` | 2848-2850 | decomplex | covered | - | 15: Broken Protocols=3, Decision Pressure=11, False Simplicity=1 | - | - |
| 146 | [src/mir/mir.rb:3517](../../src/mir/mir.rb#L3517) `ownership_effect` | 3517-3524 | decomplex | covered | - | 15: Broken Protocols=3, Decision Pressure=11, False Simplicity=1 | - | - |
| 147 | [src/backends/compiler_frontend.rb:42](../../src/backends/compiler_frontend.rb#L42) `self.compile` | 107 | decomplex | covered | - | 13: Decision Pressure=2, False Simplicity=9, Fat Unions=1, Missing Abstractions=1 | - | - |
| 148 | [src/mir/fsm_transform/suspend_resolvers.rb:148](../../src/mir/fsm_transform/suspend_resolvers.rb#L148) `resolve_next` | 178-179,181,206 | uncovered, untyped, decomplex | 40/41 uncovered: 149-153,156,158-163,173-174,176-179,181-183,185,187,189,195-196,201,203-204,206,209-210,216,218,221-225,228 | T=5; Object=0 | 13: False Simplicity=3, Neglected Path Conditions=5, Neglected Updates=5 | - | - |
| 149 | [src/mir/mir.rb:317](../../src/mir/mir.rb#L317) `body_slots` | 317 | decomplex | covered | - | 13: Decision Pressure=5, False Simplicity=8 | - | - |
| 150 | [src/annotator/phases/whole_program_semantics.rb:19](../../src/annotator/phases/whole_program_semantics.rb#L19) `run_whole_program_semantics!` | 46 | uncovered, decomplex | 1/19 uncovered: 36 | - | 12: Broken Protocols=2, Decision Pressure=1, False Simplicity=9 | - | - |
| 151 | [src/mir/control_flow.rb:403](../../src/mir/control_flow.rb#L403) `analyze!` | 407,413-414,428,435-436,440 | decomplex | covered | - | 12: Broken Protocols=2, False Simplicity=4, Neglected Path Conditions=6 | - | - |
| 152 | [src/mir/mir_pass.rb:74](../../src/mir/mir_pass.rb#L74) `transform!` | 93 | untyped, decomplex | covered | T=3; Object=0 | 12: Decision Pressure=1, False Simplicity=10, Missing Abstractions=1 | - | - |
| 153 | [src/mir/fsm_transform/emit.rb:149](../../src/mir/fsm_transform/emit.rb#L149) `build_fsm_unified` | 254,256 | uncovered, untyped, decomplex | 90/93 uncovered: 150-151,153-154,160-165,167-171,173,175,177-199,207-215,218,220-222,224-227,230-238,240-242,244-246,249-250,252-255,257-262,267-271,273 | T=5; Object=0 | 11: Decision Pressure=4, False Simplicity=6, Missing Abstractions=1 | - | - |
| 154 | [src/mir/lowering/expressions.rb:1515](../../src/mir/lowering/expressions.rb#L1515) `lower_block_expr` | 1530 | untyped, decomplex | covered | T=3; Object=0 | 11: Decision Pressure=3, False Simplicity=2, Neglected Updates=6 | - | - |
| 155 | [src/mir/lowering/variables.rb:227](../../src/mir/lowering/variables.rb#L227) `var_decl_facts` | 278 | untyped, decomplex | covered | T=1; Object=0 | 11: Broken Protocols=3, Decision Pressure=3, False Simplicity=2, Neglected Updates=3 | - | - |
| 156 | [src/annotator/domains/variables.rb:553](../../src/annotator/domains/variables.rb#L553) `visit_Assignment` | 570 | uncovered, decomplex | 3/39 uncovered: 587,594,596 | - | 9: Broken Protocols=1, Decision Pressure=3, Derived-State Staleness=1, False Simplicity=3, Missing Abstractions=1 | - | - |
| 157 | [src/ast/ast.rb:913](../../src/ast/ast.rb#L913) `matched_stdlib_def=` | 915 | decomplex | covered | - | 9: False Simplicity=2, Neglected Updates=7 | - | - |
| 158 | [src/backends/importer.rb:85](../../src/backends/importer.rb#L85) `compile_file` | 119 | uncovered, decomplex | 2/22 uncovered: 91-92 | - | 9: False Simplicity=9 | - | - |
| 159 | [src/backends/pipeline_host.rb:1962](../../src/backends/pipeline_host.rb#L1962) `lower_index` | 1994 | uncovered, untyped, decomplex | 1/21 uncovered: 1971 | T=1; Object=0 | 9: Decision Pressure=1, False Simplicity=2, Neglected Path Conditions=6 | - | - |
| 160 | [src/mir/lowering/expressions.rb:1549](../../src/mir/lowering/expressions.rb#L1549) `lower_range_lit` | 1554,1559-1560 | uncovered, decomplex | 1/9 uncovered: 1554 | - | 9: Decision Pressure=2, False Simplicity=2, Neglected Updates=5 | - | - |
| 161 | [src/mir/mir.rb:311](../../src/mir/mir.rb#L311) `child_exprs` | 311 | decomplex | covered | - | 9: Broken Protocols=2, Decision Pressure=5, Exact Predicate Aliases=1, False Simplicity=1 | - | - |
| 162 | [src/mir/mir.rb:2844](../../src/mir/mir.rb#L2844) `child_exprs` | 2844 | decomplex | covered | - | 9: Broken Protocols=2, Decision Pressure=5, Exact Predicate Aliases=1, False Simplicity=1 | - | - |
| 163 | [src/mir/mir.rb:3514](../../src/mir/mir.rb#L3514) `child_exprs` | 3514 | decomplex | covered | - | 9: Broken Protocols=2, Decision Pressure=5, Exact Predicate Aliases=1, False Simplicity=1 | - | - |
| 164 | [src/mir/mir.rb:3549](../../src/mir/mir.rb#L3549) `child_exprs` | 3549 | decomplex | covered | - | 9: Broken Protocols=2, Decision Pressure=5, Exact Predicate Aliases=1, False Simplicity=1 | - | - |
| 165 | [src/annotator/helpers/fixable_helpers.rb:996](../../src/annotator/helpers/fixable_helpers.rb#L996) `emit_with_materialized_needs_tense!` | 1000 | uncovered, untyped, decomplex | 18/19 uncovered: 997-1007,1010-1013,1025-1027 | T=3; Object=0 | 8: Decision Pressure=2, False Simplicity=2, Neglected Path Conditions=4 | - | - |
| 166 | [src/annotator/helpers/pipe_analysis.rb:1223](../../src/annotator/helpers/pipe_analysis.rb#L1223) `auto_detect_sharded_access` | 1241 | uncovered, untyped, decomplex | 24/25 uncovered: 1224-1226,1229-1230,1232,1235-1237,1239-1244,1247-1250,1254,1257-1258,1260-1261 | T=3; Object=0 | 8: Decision Pressure=5, False Simplicity=3 | - | - |
| 167 | [src/mir/mir.rb:281](../../src/mir/mir.rb#L281) `initialize` | 282-284 | decomplex | covered | - | 8: Broken Protocols=1, False Simplicity=2, Neglected Updates=5 | - | - |
| 168 | [src/mir/mir.rb:741](../../src/mir/mir.rb#L741) `initialize` | 741-743 | decomplex | covered | - | 8: Broken Protocols=1, False Simplicity=2, Neglected Updates=5 | - | - |
| 169 | [src/mir/mir.rb:2833](../../src/mir/mir.rb#L2833) `initialize` | 2833-2836 | uncovered, decomplex | 1/4 uncovered: 2834 | - | 8: Broken Protocols=1, False Simplicity=2, Neglected Updates=5 | - | - |
| 170 | [src/mir/mir.rb:3544](../../src/mir/mir.rb#L3544) `initialize` | 3544-3546 | decomplex | covered | - | 8: Broken Protocols=1, False Simplicity=2, Neglected Updates=5 | - | - |
| 171 | [src/mir/mir_lowering.rb:2887](../../src/mir/mir_lowering.rb#L2887) `lower_static_call` | 2894-2895,2898 | uncovered, untyped, decomplex | 3/15 uncovered: 2891,2899-2900 | T=1; Object=0 | 8: Decision Pressure=2, False Simplicity=1, Neglected Updates=5 | - | - |
| 172 | [src/mir/thunk_transform/emit.rb:160](../../src/mir/thunk_transform/emit.rb#L160) `render_expr` | 161,163-165,168,170 | uncovered, untyped, decomplex | 2/10 uncovered: 167-168 | T=0; Object=1 | 8: Broken Protocols=5, Decision Pressure=1, False Simplicity=2 | - | - |
| 173 | [src/annotator/domains/lifetimes.rb:399](../../src/annotator/domains/lifetimes.rb#L399) `handle_assignment_identifier_move!` | 405 | uncovered, decomplex | 1/16 uncovered: 420 | - | 7: Decision Pressure=4, False Simplicity=2, Neglected Updates=1 | - | - |
| 174 | [src/mir/lowering/control_flow.rb:488](../../src/mir/lowering/control_flow.rb#L488) `lower_for_range` | 494,502 | untyped, decomplex | covered | T=2; Object=0 | 7: False Simplicity=1, Neglected Updates=6 | - | - |
| 175 | [src/mir/lowering/control_flow.rb:508](../../src/mir/lowering/control_flow.rb#L508) `for_range_plan` | 513 | untyped, decomplex | covered | T=1; Object=0 | 7: Broken Protocols=4, False Simplicity=1, Neglected Updates=2 | - | - |
| 176 | [src/mir/mir_lowering.rb:370](../../src/mir/mir_lowering.rb#L370) `initialize` | 385,399-400,406,409-411,416-417,434-435 | untyped, decomplex | covered | T=10; Object=0 | 7: Decision Pressure=3, Neglected Updates=4 | - | - |
| 177 | [src/mir/mir_lowering.rb:1503](../../src/mir/mir_lowering.rb#L1503) `append_ownership_facts_for_mir_node!` | 1503-1506,1508-1509,1512 | decomplex | covered | - | 7: Decision Pressure=1, False Simplicity=6 | - | - |
| 178 | [src/mir/test_lowering.rb:363](../../src/mir/test_lowering.rb#L363) `stub_intercept_for` | 396 | untyped, decomplex | covered | T=4; Object=0 | 7: Missing Abstractions=1, Neglected Updates=6 | - | - |
| 179 | [src/annotator/helpers/capabilities.rb:1204](../../src/annotator/helpers/capabilities.rb#L1204) `record_capability_binding` | 1208 | decomplex | covered | - | 6: Decision Pressure=3, Derived-State Staleness=1, False Simplicity=1, Neglected Updates=1 | - | - |
| 180 | [src/annotator/phases/expression_domains.rb:198](../../src/annotator/phases/expression_domains.rb#L198) `record_named_call_site!` | 209 | decomplex | covered | - | 6: Broken Protocols=1, Decision Pressure=2, False Simplicity=2, Missing Abstractions=1 | - | - |
| 181 | [src/backends/pipeline_host.rb:455](../../src/backends/pipeline_host.rb#L455) `typed_block_expr` | 455-459 | decomplex | covered | - | 6: False Simplicity=1, Neglected Updates=5 | - | - |
| 182 | [src/backends/pipeline_host.rb:3659](../../src/backends/pipeline_host.rb#L3659) `lower_range_reduce` | 3685,3694,3703 | uncovered, untyped, decomplex | 3/22 uncovered: 3701-3702,3704 | T=2; Object=0 | 6: Decision Pressure=2, False Simplicity=2, Missing Abstractions=2 | - | - |
| 183 | [src/semantic/ownership_graph.rb:280](../../src/semantic/ownership_graph.rb#L280) `restore_lightweight` | 281,285-288 | uncovered, decomplex | 3/13 uncovered: 292-294 | - | 6: Decision Pressure=2, False Simplicity=4 | - | - |
| 184 | [src/annotator/annotator.rb:461](../../src/annotator/annotator.rb#L461) `setup_builtins` | 509 | decomplex | covered | - | 5: Broken Protocols=5 | - | - |
| 185 | [src/annotator/domains/variables.rb:607](../../src/annotator/domains/variables.rb#L607) `visit_assignment_variable` | 612 | uncovered, decomplex | 20/22 uncovered: 608-619,623,625,627-632 | - | 5: Broken Protocols=2, False Simplicity=3 | - | - |
| 186 | [src/annotator/helpers/effects.rb:1142](../../src/annotator/helpers/effects.rb#L1142) `validate_tight_node!` | 1142,1148,1161,1172-1173,1175 | uncovered, untyped, decomplex | 4/19 uncovered: 1153,1159,1164,1170 | T=0; Object=1 | 5: Decision Pressure=2, False Simplicity=2, Missing Abstractions=1 | - | - |
| 187 | [src/mir/fsm_transform/emit.rb:484](../../src/mir/fsm_transform/emit.rb#L484) `build_dispatch_tail` | 486-489,532-533,536-537,539,542,546,550 | uncovered, untyped, decomplex | 42/45 uncovered: 485-489,493,496-498,500,502,509-516,518,525-526,528-542,544-545,547,549,552 | T=1; Object=0 | 5: Decision Pressure=2, Fat Unions=1, Neglected Path Conditions=2 | - | - |
| 188 | [src/mir/fsm_transform/emit.rb:1122](../../src/mir/fsm_transform/emit.rb#L1122) `expand_lock_segment` | 1240-1241,1245 | uncovered, untyped, decomplex | 77/82 uncovered: 1123-1131,1133-1141,1145-1146,1148-1151,1154-1157,1161,1167,1169,1174-1175,1178-1181,1183,1187-1188,1190,1194,1198,1202,1205-1215,1219-1220,1222-1224,1231,1235-1249,1251 | T=8; Object=0 | 5: Decision Pressure=3, False Simplicity=2 | - | - |
| 189 | [src/mir/fsm_transform/recursive_splitter.rb:198](../../src/mir/fsm_transform/recursive_splitter.rb#L198) `split` | 233-237 | uncovered, untyped, decomplex | 26/29 uncovered: 199-200,203-204,206,208,210,213,216-221,223,225-228,231-233,235-237,239 | T=1; Object=2 | 5: Broken Protocols=1, Decision Pressure=1, False Simplicity=3 | - | - |
| 190 | [src/mir/lowering/expressions.rb:1794](../../src/mir/lowering/expressions.rb#L1794) `copy_source_type_info` | 1806 | uncovered, untyped, decomplex | 8/10 uncovered: 1798-1801,1804-1805,1807,1809 | T=1; Object=0 | 5: Decision Pressure=3, False Simplicity=2 | - | - |
| 191 | [src/mir/mir_checker.rb:2054](../../src/mir/mir_checker.rb#L2054) `verify_execution_boundary_facts!` | 2054-2055 | uncovered, decomplex | 16/17 uncovered: 2055-2056,2058-2060,2063,2065,2067-2069,2071,2073-2075,2078-2079 | - | 5: Decision Pressure=2, False Simplicity=3 | - | - |
| 192 | [src/mir/mir_lowering.rb:1415](../../src/mir/mir_lowering.rb#L1415) `append_block_result_transfer!` | 1419-1420,1422-1425 | decomplex | covered | - | 5: Broken Protocols=1, Decision Pressure=2, False Simplicity=2 | - | - |
| 193 | [src/semantic/escape_analysis.rb:570](../../src/semantic/escape_analysis.rb#L570) `self.mark_method_takes_heap!` | 570,578 | decomplex | covered | - | 5: Decision Pressure=1, False Simplicity=4 | - | - |
| 194 | [src/annotator/domains/lifetimes.rb:597](../../src/annotator/domains/lifetimes.rb#L597) `collect_scope_drops` | 601 | uncovered, decomplex | 3/15 uncovered: 606-607,611 | - | 4: False Simplicity=3, Missing Abstractions=1 | - | - |
| 195 | [src/annotator/domains/lifetimes.rb:1140](../../src/annotator/domains/lifetimes.rb#L1140) `og_declare` | 1143 | decomplex | covered | - | 4: Broken Protocols=3, Decision Pressure=1 | - | - |
| 196 | [src/annotator/helpers/fixable_helpers.rb:1275](../../src/annotator/helpers/fixable_helpers.rb#L1275) `build_declare_mutable_fix` | 1277 | uncovered, decomplex | 12/13 uncovered: 1276-1278,1283-1288,1290-1291,1293 | - | 4: Broken Protocols=2, Neglected Path Conditions=2 | - | - |
| 197 | [src/ast/scope.rb:180](../../src/ast/scope.rb#L180) `declare_type` | 181 | decomplex | covered | - | 4: Broken Protocols=4 | - | - |
| 198 | [src/backends/pipeline_host.rb:1030](../../src/backends/pipeline_host.rb#L1030) `build_soa_scalar_fold_block` | 1068,1074,1078,1088,1095,1116 | uncovered, untyped, decomplex | 51/52 uncovered: 1031-1033,1035,1038,1042,1044,1048-1050,1054-1055,1061-1064,1066,1068-1069,1072,1074-1076,1078-1081,1087-1090,1092,1094-1097,1099,1101-1102,1106,1108-1109,1113,1115-1119,1124,1129,1132 | T=3; Object=0 | 4: False Simplicity=2, Fat Unions=1, Missing Abstractions=1 | - | - |
| 199 | [src/backends/pipeline_host.rb:1619](../../src/backends/pipeline_host.rb#L1619) `lower_window` | 1641 | decomplex | covered | - | 4: Broken Protocols=2, False Simplicity=2 | - | - |
| 200 | [src/backends/pipeline_host.rb:2688](../../src/backends/pipeline_host.rb#L2688) `lower_binding_fold` | 2693-2698,2702,2709,2717-2718,2732,2742,2770 | uncovered, untyped, decomplex | 1/48 uncovered: 2786 | T=3; Object=0 | 4: False Simplicity=2, Fat Unions=1, Missing Abstractions=1 | - | - |
| 201 | [src/mir/fsm_ops.rb:586](../../src/mir/fsm_ops.rb#L586) `self.alloc_state_fields` | 586 | uncovered, decomplex | 6/9 uncovered: 587,590-594 | - | 4: Broken Protocols=1, Decision Pressure=2, False Simplicity=1 | - | - |
| 202 | [src/mir/fsm_transform/emit.rb:276](../../src/mir/fsm_transform/emit.rb#L276) `build_fsm_structure` | 282-283,306-307 | uncovered, untyped, decomplex | 29/41 uncovered: 278-280,284-290,294,299-309,313-316,319,322-323 | T=1; Object=1 | 4: Decision Pressure=1, False Simplicity=3 | - | - |
| 203 | [src/mir/hoist.rb:1219](../../src/mir/hoist.rb#L1219) `typed_cleanup_entry_for_mir_result` | 1224 | uncovered, untyped, decomplex | 2/12 uncovered: 1223,1225 | T=1; Object=0 | 4: Decision Pressure=3, Missing Abstractions=1 | - | - |
| 204 | [src/mir/lowering/functions.rb:386](../../src/mir/lowering/functions.rb#L386) `function_lowering_context` | 420 | decomplex | covered | - | 4: Decision Pressure=1, False Simplicity=3 | - | - |
| 205 | [src/mir/lowering/variables.rb:453](../../src/mir/lowering/variables.rb#L453) `owned_return_call_var_decl_plan` | 461 | decomplex | covered | - | 4: False Simplicity=4 | - | - |
| 206 | [src/mir/lowering/variables.rb:535](../../src/mir/lowering/variables.rb#L535) `allocating_init_var_decl_plan` | 538 | decomplex | covered | - | 4: Broken Protocols=1, False Simplicity=3 | - | - |
| 207 | [src/mir/mir_checker.rb:781](../../src/mir/mir_checker.rb#L781) `linear_merge_branch_states!` | 791,794 | uncovered, decomplex | 11/12 uncovered: 782-786,788-792,796 | - | 4: False Simplicity=4 | - | - |
| 208 | [src/mir/mir_checker.rb:1167](../../src/mir/mir_checker.rb#L1167) `ownership_registry_errors` | 1174 | uncovered, decomplex | 21/22 uncovered: 1168-1174,1176-1178,1180-1181,1183-1184,1186,1188-1190,1194-1195,1198 | - | 4: Broken Protocols=1, Decision Pressure=1, False Simplicity=2 | - | - |
| 209 | [src/mir/mir_lowering.rb:1603](../../src/mir/mir_lowering.rb#L1603) `append_ownership_store_facts_for_consumption!` | 1603,1605,1607-1609 | decomplex | covered | - | 4: Broken Protocols=3, False Simplicity=1 | - | - |
| 210 | [src/semantic/pass_work_profiler.rb:202](../../src/semantic/pass_work_profiler.rb#L202) `measure` | 202-220 | uncovered, untyped, decomplex | no data | T=0; Object=4 | 4: Broken Protocols=1, False Simplicity=3 | - | - |
| 211 | [src/semantic/pass_work_profiler.rb:233](../../src/semantic/pass_work_profiler.rb#L233) `measure_work` | 233-251 | uncovered, untyped, decomplex | no data | T=0; Object=2 | 4: Broken Protocols=1, False Simplicity=3 | - | - |
| 212 | [src/semantic/pass_work_profiler.rb:477](../../src/semantic/pass_work_profiler.rb#L477) `self.count_nodes` | 477-492 | uncovered, untyped, decomplex | no data | T=0; Object=1 | 4: Broken Protocols=2, Decision Pressure=1, False Simplicity=1 | - | - |
| 213 | [src/annotator/helpers/capabilities.rb:423](../../src/annotator/helpers/capabilities.rb#L423) `predicate_impurity_reason` | 429 | uncovered, decomplex | 19/20 uncovered: 424-434,437-444 | - | 3: Decision Pressure=2, Neglected Updates=1 | - | - |
| 214 | [src/annotator/helpers/effects.rb:1132](../../src/annotator/helpers/effects.rb#L1132) `validate_tight_body!` | 1136-1138 | untyped, decomplex | covered | T=3; Object=0 | 3: Decision Pressure=1, False Simplicity=1, Neglected Updates=1 | - | - |
| 215 | [src/annotator/helpers/function_analysis.rb:984](../../src/annotator/helpers/function_analysis.rb#L984) `return_is_borrow?` | 992 | untyped, decomplex | covered | T=1; Object=0 | 3: Decision Pressure=3 | - | - |
| 216 | [src/ast/parser.rb:938](../../src/ast/parser.rb#L938) `synthesize_default_for_type` | 944-947 | uncovered, untyped, decomplex | 7/8 uncovered: 939-940,942-945,947 | T=1; Object=0 | 3: Decision Pressure=2, False Simplicity=1 | - | - |
| 217 | [src/ast/scope.rb:77](../../src/ast/scope.rb#L77) `declare` | 77-79 | decomplex | covered | - | 3: False Simplicity=3 | - | - |
| 218 | [src/ast/scope.rb:272](../../src/ast/scope.rb#L272) `count_visible_entries!` | 272-281 | uncovered, decomplex | 6/10 uncovered: 273-278 | - | 3: Broken Protocols=1, Decision Pressure=1, False Simplicity=1 | - | - |
| 219 | [src/ast/scope.rb:298](../../src/ast/scope.rb#L298) `append_visible_names!` | 298-307 | uncovered, decomplex | 5/9 uncovered: 299-301,303-304 | - | 3: Broken Protocols=1, Decision Pressure=1, False Simplicity=1 | - | - |
| 220 | [src/backends/pipeline_host.rb:4605](../../src/backends/pipeline_host.rb#L4605) `lower_concurrent_list_reduce` | 4645,4649 | uncovered, untyped, decomplex | 19/21 uncovered: 4607,4609-4616,4618-4620,4622,4624,4627-4628,4630,4645-4646 | T=2; Object=0 | 3: Broken Protocols=2, False Simplicity=1 | - | - |
| 221 | [src/mir/cleanup_classifier.rb:623](../../src/mir/cleanup_classifier.rb#L623) `self.binding_container_borrow?` | 626 | untyped, decomplex | covered | T=1; Object=0 | 3: Decision Pressure=2, Missing Abstractions=1 | - | - |
| 222 | [src/mir/control_flow.rb:684](../../src/mir/control_flow.rb#L684) `cleanup_decision_facts` | 684-705,708-712 | decomplex | covered | - | 3: Decision Pressure=2, False Simplicity=1 | - | - |
| 223 | [src/mir/fsm_transform/emit.rb:936](../../src/mir/fsm_transform/emit.rb#L936) `rewrite_promoted_fsm_node` | 942 | uncovered, decomplex | 16/19 uncovered: 937-944,947,949-951,954,956-958 | - | 3: Decision Pressure=1, False Simplicity=2 | - | - |
| 224 | [src/mir/fsm_transform/emit.rb:1005](../../src/mir/fsm_transform/emit.rb#L1005) `lift_ctx_cleanups_to_destroy!` | 1006,1011-1012,1014,1018 | uncovered, untyped, decomplex | 12/15 uncovered: 1006-1012,1014,1019,1022-1024 | T=0; Object=1 | 3: Decision Pressure=1, False Simplicity=2 | - | - |
| 225 | [src/mir/lowering/variables.rb:505](../../src/mir/lowering/variables.rb#L505) `mutated_owned_var_decl_plan` | 512 | decomplex | covered | - | 3: False Simplicity=3 | - | - |
| 226 | [src/mir/lowering/variables.rb:519](../../src/mir/lowering/variables.rb#L519) `binding_metadata_var_decl_plan` | 526 | decomplex | covered | - | 3: Broken Protocols=2, False Simplicity=1 | - | - |
| 227 | [src/mir/mir.rb:313](../../src/mir/mir.rb#L313) `ownership_source_exprs` | 313 | decomplex | covered | - | 3: Exact Predicate Aliases=3 | - | - |
| 228 | [src/mir/mir.rb:2846](../../src/mir/mir.rb#L2846) `ownership_source_exprs` | 2846 | decomplex | covered | - | 3: Exact Predicate Aliases=3 | - | - |
| 229 | [src/mir/mir_checker.rb:1136](../../src/mir/mir_checker.rb#L1136) `verify_heap_create_single_indirection!` | 1136-1137 | uncovered, decomplex | 4/5 uncovered: 1137-1140 | - | 3: Broken Protocols=1, Decision Pressure=1, False Simplicity=1 | - | - |
| 230 | [src/mir/mir_checker.rb:2004](../../src/mir/mir_checker.rb#L2004) `verify_ownership_surfaces_finalized!` | 2004,2006-2011,2015,2022,2029,2037,2043 | uncovered, decomplex | 22/23 uncovered: 2005-2009,2011-2012,2014-2015,2017,2021-2022,2024,2028-2029,2031,2035-2037,2039,2043,2045 | - | 3: Broken Protocols=2, False Simplicity=1 | - | - |
| 231 | [src/mir/mir_checker.rb:2229](../../src/mir/mir_checker.rb#L2229) `ownership_fact_covers_node?` | 2229,2235-2236 | uncovered, decomplex | 3/4 uncovered: 2230,2232,2235 | - | 3: Decision Pressure=2, Missing Abstractions=1 | - | - |
| 232 | [src/mir/mir_lowering.rb:779](../../src/mir/mir_lowering.rb#L779) `heap_owned_result?` | 788 | decomplex | covered | - | 3: Decision Pressure=3 | - | - |
| 233 | [src/mir/mir_lowering.rb:1181](../../src/mir/mir_lowering.rb#L1181) `record_ownership_finalization_node!` | 1181,1183 | decomplex | covered | - | 3: Broken Protocols=1, False Simplicity=1, Neglected Updates=1 | - | - |
| 234 | [src/mir/mir_lowering.rb:1620](../../src/mir/mir_lowering.rb#L1620) `append_ownership_transfer_facts_for_consumption!` | 1620,1622,1624-1626 | decomplex | covered | - | 3: Broken Protocols=2, False Simplicity=1 | - | - |
| 235 | [src/mir/mir_lowering.rb:1662](../../src/mir/mir_lowering.rb#L1662) `append_ownership_facts_for_owned_result!` | 1662,1665-1666,1671,1673-1674,1677-1678 | decomplex | covered | - | 3: Decision Pressure=2, False Simplicity=1 | - | - |
| 236 | [src/mir/test_lowering.rb:434](../../src/mir/test_lowering.rb#L434) `lower_stub_decl` | 448,466 | uncovered, untyped, decomplex | 2/22 uncovered: 454,474 | T=3; Object=0 | 3: Decision Pressure=1, False Simplicity=1, Missing Abstractions=1 | - | - |
| 237 | [src/semantic/bg_capture_classifier.rb:40](../../src/semantic/bg_capture_classifier.rb#L40) `self.classify_all!` | 54 | decomplex | covered | - | 3: Decision Pressure=1, False Simplicity=2 | - | - |
| 238 | [src/semantic/escape_analysis.rb:1077](../../src/semantic/escape_analysis.rb#L1077) `self.function_facts_for_body` | 1077-1088 | decomplex | covered | - | 3: Decision Pressure=1, False Simplicity=1, Missing Abstractions=1 | - | - |
| 239 | [src/semantic/pass_work_profiler.rb:448](../../src/semantic/pass_work_profiler.rb#L448) `current=` | 448-450 | uncovered, decomplex | no data | - | 3: Broken Protocols=1, False Simplicity=2 | - | - |
| 240 | [src/annotator/domains/lifetimes.rb:832](../../src/annotator/domains/lifetimes.rb#L832) `dest_scope_depth_for_target` | 837 | uncovered, decomplex | 7/8 uncovered: 833,835-838,840-841 | - | 2: Decision Pressure=2 | - | - |
| 241 | [src/annotator/helpers/function_analysis.rb:582](../../src/annotator/helpers/function_analysis.rb#L582) `atomic_cell_arg?` | 586 | decomplex | covered | - | 2: Decision Pressure=2 | - | - |
| 242 | [src/annotator/helpers/function_analysis.rb:1064](../../src/annotator/helpers/function_analysis.rb#L1064) `any_array_intrinsic_arg?` | 1064-1076 | untyped, decomplex | covered | T=0; Object=1 | 2: Decision Pressure=1, False Simplicity=1 | - | - |
| 243 | [src/annotator/helpers/pipe_analysis.rb:1151](../../src/annotator/helpers/pipe_analysis.rb#L1151) `emit_multi_map_warning` | 1154 | uncovered, untyped, decomplex | 9/10 uncovered: 1152-1156,1158-1160,1164 | T=2; Object=0 | 2: Decision Pressure=1, False Simplicity=1 | - | - |
| 244 | [src/ast/ast.rb:997](../../src/ast/ast.rb#L997) `symbol=` | 997 | decomplex | covered | - | 2: False Simplicity=2 | - | - |
| 245 | [src/ast/scope.rb:319](../../src/ast/scope.rb#L319) `resolve_full_type` | 320 | decomplex | covered | - | 2: Decision Pressure=1, False Simplicity=1 | - | - |
| 246 | [src/ast/scope.rb:436](../../src/ast/scope.rb#L436) `lookup_scope_for` | 439 | decomplex | covered | - | 2: Broken Protocols=2 | - | - |
| 247 | [src/ast/type.rb:168](../../src/ast/type.rb#L168) `with` | 169-171,173 | decomplex | covered | - | 2: Oversized Predicates=2 | - | - |
| 248 | [src/backends/pipeline_host.rb:1600](../../src/backends/pipeline_host.rb#L1600) `lower_reduce` | 1609 | decomplex | covered | - | 2: False Simplicity=2 | - | - |
| 249 | [src/backends/pipeline_host.rb:4232](../../src/backends/pipeline_host.rb#L4232) `lower_concurrent_bounded_select` | 4255,4260 | decomplex | covered | - | 2: False Simplicity=2 | - | - |
| 250 | [src/backends/pipeline_host.rb:4264](../../src/backends/pipeline_host.rb#L4264) `lower_concurrent_bounded_where` | 4285,4290 | decomplex | covered | - | 2: False Simplicity=2 | - | - |
| 251 | [src/backends/pipeline_host.rb:4364](../../src/backends/pipeline_host.rb#L4364) `lower_concurrent_stream_select` | 4393,4397 | decomplex | covered | - | 2: False Simplicity=2 | - | - |
| 252 | [src/backends/pipeline_host.rb:4401](../../src/backends/pipeline_host.rb#L4401) `lower_concurrent_stream_where` | 4428,4432 | decomplex | covered | - | 2: False Simplicity=2 | - | - |
| 253 | [src/mir/control_flow.rb:451](../../src/mir/control_flow.rb#L451) `reverse_postorder_index` | 451-465 | untyped, decomplex | covered | T=1; Object=0 | 2: False Simplicity=2 | - | - |
| 254 | [src/mir/control_flow.rb:762](../../src/mir/control_flow.rb#L762) `join_entry` | 775-776,779-780 | uncovered, decomplex | 3/21 uncovered: 765,778-779 | - | 2: Broken Protocols=1, Decision Pressure=1 | - | - |
| 255 | [src/mir/control_flow.rb:1182](../../src/mir/control_flow.rb#L1182) `check!` | 1183-1184,1186-1189 | uncovered, decomplex | 2/11 uncovered: 1183-1184 | - | 2: False Simplicity=2 | - | - |
| 256 | [src/mir/control_flow.rb:1433](../../src/mir/control_flow.rb#L1433) `self.walk_stmt!` | 1435-1436 | decomplex | covered | - | 2: False Simplicity=2 | - | - |
| 257 | [src/mir/fsm_ops.rb:577](../../src/mir/fsm_ops.rb#L577) `self.referenced_state_fields` | 577 | uncovered, decomplex | 4/6 uncovered: 579-582 | - | 2: Decision Pressure=1, False Simplicity=1 | - | - |
| 258 | [src/mir/fsm_ops.rb:597](../../src/mir/fsm_ops.rb#L597) `self.free_state_fields` | 597 | uncovered, decomplex | 6/9 uncovered: 598-599,602-605 | - | 2: Broken Protocols=1, False Simplicity=1 | - | - |
| 259 | [src/mir/fsm_transform/emit.rb:1043](../../src/mir/fsm_transform/emit.rb#L1043) `register_owned_suspend_result_cleanups!` | 1052-1053,1057 | uncovered, untyped, decomplex | 10/11 uncovered: 1044-1053 | T=3; Object=0 | 2: False Simplicity=2 | - | - |
| 260 | [src/mir/lowering/literals.rb:167](../../src/mir/lowering/literals.rb#L167) `lower_default_array_lit` | 167-177 | uncovered, decomplex | 8/9 uncovered: 168-174,176 | - | 2: Decision Pressure=1, False Simplicity=1 | - | - |
| 261 | [src/mir/lowering/variables.rb:473](../../src/mir/lowering/variables.rb#L473) `transfer_only_var_decl_plan` | 477 | uncovered, decomplex | 3/4 uncovered: 474-476 | - | 2: Broken Protocols=2 | - | - |
| 262 | [src/mir/mir.rb:315](../../src/mir/mir.rb#L315) `owned_position_source_exprs` | 315 | decomplex | covered | - | 2: Exact Predicate Aliases=2 | - | - |
| 263 | [src/mir/mir.rb:335](../../src/mir/mir.rb#L335) `append_child_expr` | 335-342 | untyped, decomplex | covered | T=0; Object=1 | 2: Decision Pressure=1, False Simplicity=1 | - | - |
| 264 | [src/mir/mir_checker.rb:829](../../src/mir/mir_checker.rb#L829) `linear_exit_scope!` | 831-834 | uncovered, decomplex | 3/4 uncovered: 830-832 | - | 2: False Simplicity=2 | - | - |
| 265 | [src/mir/mir_checker.rb:1021](../../src/mir/mir_checker.rb#L1021) `verify_allocating_lets_marked!` | 1021-1022 | uncovered, decomplex | 5/6 uncovered: 1022-1026 | - | 2: Decision Pressure=1, False Simplicity=1 | - | - |
| 266 | [src/mir/mir_checker.rb:1147](../../src/mir/mir_checker.rb#L1147) `each_heap_create` | 1147-1148 | uncovered, decomplex | 2/3 uncovered: 1148-1149 | - | 2: Decision Pressure=1, False Simplicity=1 | - | - |
| 267 | [src/mir/mir_checker.rb:1860](../../src/mir/mir_checker.rb#L1860) `verify_call_contracts!` | 1860-1861 | uncovered, decomplex | 5/6 uncovered: 1861-1862,1864,1866,1868 | - | 2: Broken Protocols=1, False Simplicity=1 | - | - |
| 268 | [src/mir/mir_checker.rb:2239](../../src/mir/mir_checker.rb#L2239) `ownership_fact_source` | 2239-2245 | uncovered, decomplex | 2/3 uncovered: 2240,2243 | - | 2: Fat Unions=1, Missing Abstractions=1 | - | - |
| 269 | [src/mir/mir_emitter.rb:609](../../src/mir/mir_emitter.rb#L609) `emit_let` | 617 | uncovered, decomplex | 4/11 uncovered: 611-614 | - | 2: Broken Protocols=1, Decision Pressure=1 | - | - |
| 270 | [src/mir/mir_lowering.rb:982](../../src/mir/mir_lowering.rb#L982) `mark_ownership_finalized_node!` | 982-985 | decomplex | covered | - | 2: Decision Pressure=1, False Simplicity=1 | - | - |
| 271 | [src/mir/mir_lowering.rb:988](../../src/mir/mir_lowering.rb#L988) `mark_ownership_finalized_nodes!` | 988-991 | decomplex | covered | - | 2: Broken Protocols=1, False Simplicity=1 | - | - |
| 272 | [src/mir/mir_lowering.rb:1169](../../src/mir/mir_lowering.rb#L1169) `register_body_visible_names!` | 1170-1172 | uncovered, decomplex | 1/3 uncovered: 1170 | - | 2: Broken Protocols=1, False Simplicity=1 | - | - |
| 273 | [src/mir/mir_lowering.rb:1175](../../src/mir/mir_lowering.rb#L1175) `register_ownership_finalization_visible_names!` | 1175-1178 | uncovered, decomplex | 1/2 uncovered: 1176 | - | 2: Broken Protocols=1, False Simplicity=1 | - | - |
| 274 | [src/mir/mir_lowering.rb:1239](../../src/mir/mir_lowering.rb#L1239) `body_alloc_mark_names_in_body` | 1239-1245 | decomplex | covered | - | 2: Decision Pressure=1, False Simplicity=1 | - | - |
| 275 | [src/mir/mir_lowering.rb:1248](../../src/mir/mir_lowering.rb#L1248) `body_transfer_mark_names_in_body` | 1248-1253 | decomplex | covered | - | 2: Decision Pressure=1, False Simplicity=1 | - | - |
| 276 | [src/mir/mir_lowering.rb:1263](../../src/mir/mir_lowering.rb#L1263) `append_ownership_transfers_for_mir_body` | 1270-1275 | decomplex | covered | - | 2: False Simplicity=2 | - | - |
| 277 | [src/mir/mir_lowering.rb:1291](../../src/mir/mir_lowering.rb#L1291) `append_nested_ownership_transfers_for_mir_body` | 1292,1300-1305 | decomplex | covered | - | 2: False Simplicity=2 | - | - |
| 278 | [src/mir/mir_lowering.rb:1476](../../src/mir/mir_lowering.rb#L1476) `ownership_fact_dedupe_key` | 1476-1493 | uncovered, decomplex | 1/14 uncovered: 1485 | - | 2: Fat Unions=1, Missing Abstractions=1 | - | - |
| 279 | [src/mir/mir_lowering.rb:1557](../../src/mir/mir_lowering.rb#L1557) `ownership_owned_result_fact_relevant?` | 1557-1565 | decomplex | covered | - | 2: Decision Pressure=2 | - | - |
| 280 | [src/mir/mir_pass.rb:293](../../src/mir/mir_pass.rb#L293) `collect_callees` | 295-298 | untyped, decomplex | covered | T=1; Object=0 | 2: False Simplicity=1, Missing Abstractions=1 | - | - |
| 281 | [src/semantic/escape_analysis.rb:297](../../src/semantic/escape_analysis.rb#L297) `self.mark_body_escapes!` | 297-298 | decomplex | covered | - | 2: Broken Protocols=1, False Simplicity=1 | - | - |
| 282 | [src/semantic/escape_analysis.rb:328](../../src/semantic/escape_analysis.rb#L328) `self.apply_binding_escape_sink!` | 331 | decomplex | covered | - | 2: False Simplicity=2 | - | - |
| 283 | [src/semantic/escape_analysis.rb:683](../../src/semantic/escape_analysis.rb#L683) `self.assigned_binding_name` | 689 | decomplex | covered | - | 2: Decision Pressure=1, Missing Abstractions=1 | - | - |
| 284 | [src/semantic/escape_analysis.rb:695](../../src/semantic/escape_analysis.rb#L695) `self.assignment_value_is_owned?` | 695,701 | decomplex | covered | - | 2: Broken Protocols=1, Decision Pressure=1 | - | - |
| 285 | [src/semantic/escape_analysis.rb:969](../../src/semantic/escape_analysis.rb#L969) `self.call_result_is_heap?` | 969,973,976-977 | decomplex | covered | - | 2: Decision Pressure=1, Missing Abstractions=1 | - | - |
| 286 | [src/semantic/pass_work_profiler.rb:93](../../src/semantic/pass_work_profiler.rb#L93) `self.ratio` | 93-97 | uncovered, decomplex | no data | - | 2: Broken Protocols=2 | - | - |
| 287 | [src/semantic/pass_work_profiler.rb:443](../../src/semantic/pass_work_profiler.rb#L443) `current` | 443-445 | uncovered, decomplex | no data | - | 2: Broken Protocols=1, False Simplicity=1 | - | - |
| 288 | [src/semantic/pass_work_profiler.rb:508](../../src/semantic/pass_work_profiler.rb#L508) `self.profiler_node?` | 508-511 | uncovered, untyped, decomplex | no data | T=0; Object=1 | 2: Decision Pressure=2 | - | - |
| 289 | [src/annotator/domains/lifetimes.rb:770](../../src/annotator/domains/lifetimes.rb#L770) `lookup_source_name` | 775 | uncovered, decomplex | 9/10 uncovered: 771,773-776,780-783 | - | 1: Decision Pressure=1 | - | - |
| 290 | [src/annotator/phases/auto_finalization.rb:12](../../src/annotator/phases/auto_finalization.rb#L12) `finalize_auto_types!` | 15-16 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 291 | [src/ast/ast.rb:901](../../src/ast/ast.rb#L901) `coerced_type_object` | 901 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 292 | [src/ast/ast.rb:903](../../src/ast/ast.rb#L903) `type_object` | 903 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 293 | [src/ast/ast.rb:906](../../src/ast/ast.rb#L906) `zig_pattern` | 906 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 294 | [src/ast/ast.rb:908](../../src/ast/ast.rb#L908) `zig_pattern=` | 908 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 295 | [src/ast/ast.rb:911](../../src/ast/ast.rb#L911) `matched_stdlib_def` | 911 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 296 | [src/ast/ast.rb:920](../../src/ast/ast.rb#L920) `matched_signature` | 920 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 297 | [src/ast/ast.rb:922](../../src/ast/ast.rb#L922) `matched_signature=` | 922 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 298 | [src/ast/ast.rb:925](../../src/ast/ast.rb#L925) `stdlib_allocates` | 925 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 299 | [src/ast/ast.rb:927](../../src/ast/ast.rb#L927) `stdlib_allocates=` | 927 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 300 | [src/ast/ast.rb:930](../../src/ast/ast.rb#L930) `mutates_receiver` | 930 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 301 | [src/ast/ast.rb:932](../../src/ast/ast.rb#L932) `mutates_receiver=` | 932 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 302 | [src/ast/ast.rb:935](../../src/ast/ast.rb#L935) `was_moved` | 935 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 303 | [src/ast/ast.rb:937](../../src/ast/ast.rb#L937) `was_moved=` | 937 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 304 | [src/ast/ast.rb:940](../../src/ast/ast.rb#L940) `container_borrow` | 940 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 305 | [src/ast/ast.rb:942](../../src/ast/ast.rb#L942) `container_borrow=` | 942 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 306 | [src/ast/ast.rb:945](../../src/ast/ast.rb#L945) `needs_mut_ref` | 945 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 307 | [src/ast/ast.rb:947](../../src/ast/ast.rb#L947) `needs_mut_ref=` | 947 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 308 | [src/ast/ast.rb:950](../../src/ast/ast.rb#L950) `needs_heap_create` | 950 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 309 | [src/ast/ast.rb:952](../../src/ast/ast.rb#L952) `needs_heap_create=` | 952 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 310 | [src/ast/ast.rb:955](../../src/ast/ast.rb#L955) `collection_return` | 955 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 311 | [src/ast/ast.rb:957](../../src/ast/ast.rb#L957) `collection_return=` | 957 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 312 | [src/ast/ast.rb:960](../../src/ast/ast.rb#L960) `slot_size` | 960 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 313 | [src/ast/ast.rb:962](../../src/ast/ast.rb#L962) `slot_size=` | 962 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 314 | [src/ast/ast.rb:965](../../src/ast/ast.rb#L965) `resource_close_zig` | 965 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 315 | [src/ast/ast.rb:967](../../src/ast/ast.rb#L967) `resource_close_zig=` | 967 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 316 | [src/ast/ast.rb:970](../../src/ast/ast.rb#L970) `can_fail` | 970 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 317 | [src/ast/ast.rb:972](../../src/ast/ast.rb#L972) `can_fail=` | 972 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 318 | [src/ast/ast.rb:975](../../src/ast/ast.rb#L975) `error_kind` | 975 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 319 | [src/ast/ast.rb:977](../../src/ast/ast.rb#L977) `error_kind=` | 977 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 320 | [src/ast/ast.rb:980](../../src/ast/ast.rb#L980) `error_type` | 980 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 321 | [src/ast/ast.rb:982](../../src/ast/ast.rb#L982) `error_type=` | 982 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 322 | [src/ast/ast.rb:985](../../src/ast/ast.rb#L985) `var_used` | 985 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 323 | [src/ast/ast.rb:987](../../src/ast/ast.rb#L987) `var_used=` | 987 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 324 | [src/ast/ast.rb:990](../../src/ast/ast.rb#L990) `var_mutated` | 990 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 325 | [src/ast/ast.rb:992](../../src/ast/ast.rb#L992) `var_mutated=` | 992 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 326 | [src/ast/ast.rb:995](../../src/ast/ast.rb#L995) `symbol` | 995 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 327 | [src/ast/scope.rb:34](../../src/ast/scope.rb#L34) `[]=` | 34-36 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 328 | [src/ast/scope.rb:44](../../src/ast/scope.rb#L44) `keys` | 44-46 | uncovered, decomplex | 1/3 uncovered: 46 | - | 1: Broken Protocols=1 | - | - |
| 329 | [src/ast/scope.rb:59](../../src/ast/scope.rb#L59) `each` | 59-62 | uncovered, decomplex | 1/4 uncovered: 60 | - | 1: False Simplicity=1 | - | - |
| 330 | [src/ast/scope.rb:87](../../src/ast/scope.rb#L87) `keys` | 87-89 | decomplex | covered | - | 1: Broken Protocols=1 | - | - |
| 331 | [src/ast/scope.rb:185](../../src/ast/scope.rb#L185) `resolve_type_definition` | 186 | untyped, decomplex | covered | T=1; Object=0 | 1: Decision Pressure=1 | - | - |
| 332 | [src/ast/scope.rb:191](../../src/ast/scope.rb#L191) `resolve_type_entry` | 191-193 | uncovered, decomplex | 1/3 uncovered: 193 | - | 1: Decision Pressure=1 | - | - |
| 333 | [src/ast/scope.rb:212](../../src/ast/scope.rb#L212) `resolve_entry` | 212-214 | uncovered, decomplex | 1/3 uncovered: 214 | - | 1: Decision Pressure=1 | - | - |
| 334 | [src/ast/scope.rb:227](../../src/ast/scope.rb#L227) `entry?` | 227-229 | decomplex | covered | - | 1: Decision Pressure=1 | - | - |
| 335 | [src/ast/scope.rb:267](../../src/ast/scope.rb#L267) `visible_entry_count` | 267-269 | uncovered, decomplex | 1/3 uncovered: 269 | - | 1: False Simplicity=1 | - | - |
| 336 | [src/ast/scope.rb:360](../../src/ast/scope.rb#L360) `is_restricted?` | 361 | decomplex | covered | - | 1: Decision Pressure=1 | - | - |
| 337 | [src/ast/scope.rb:449](../../src/ast/scope.rb#L449) `resolve_variable_scope` | 451 | decomplex | covered | - | 1: Broken Protocols=1 | - | - |
| 338 | [src/ast/symbol_entry.rb:420](../../src/ast/symbol_entry.rb#L420) `initialize_copy` | 422-423 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 339 | [src/ast/type.rb:43](../../src/ast/type.rb#L43) `copy` | 44 | uncovered, decomplex | 1/2 uncovered: 44 | - | 1: Exact Predicate Aliases=1 | - | - |
| 340 | [src/ast/type.rb:341](../../src/ast/type.rb#L341) `copy` | 342 | uncovered, decomplex | 1/2 uncovered: 342 | - | 1: Exact Predicate Aliases=1 | - | - |
| 341 | [src/backends/pipeline_host.rb:1287](../../src/backends/pipeline_host.rb#L1287) `lower_find` | 1294 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 342 | [src/mir/control_flow.rb:606](../../src/mir/control_flow.rb#L606) `linear_scope_decl_always_moves?` | 612 | uncovered, decomplex | 6/10 uncovered: 609-613,615 | - | 1: Broken Protocols=1 | - | - |
| 343 | [src/mir/control_flow.rb:830](../../src/mir/control_flow.rb#L830) `ownership_tracked_type?` | 830-835 | decomplex | covered | - | 1: Missing Abstractions=1 | - | - |
| 344 | [src/mir/control_flow.rb:844](../../src/mir/control_flow.rb#L844) `resource_captures` | 845-846 | decomplex | covered | - | 1: Decision Pressure=1 | - | - |
| 345 | [src/mir/control_flow.rb:923](../../src/mir/control_flow.rb#L923) `update_declared_owner!` | 923-931 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 346 | [src/mir/fsm_ops.rb:428](../../src/mir/fsm_ops.rb#L428) `lower_stmt` | 433 | uncovered, untyped, decomplex | 26/29 uncovered: 429,431,433,435-436,439-444,448,450-453,456,458-459,461,463,466,469,471-473 | T=0; Object=1 | 1: Missing Abstractions=1 | - | - |
| 347 | [src/mir/fsm_transform/emit.rb:65](../../src/mir/fsm_transform/emit.rb#L65) `[]` | 65-73 | uncovered, decomplex | 5/6 uncovered: 66-69,71 | - | 1: Broken Protocols=1 | - | - |
| 348 | [src/mir/fsm_transform/emit.rb:1073](../../src/mir/fsm_transform/emit.rb#L1073) `check_fsm_cleanup_invariant!` | 1076,1087-1088 | uncovered, untyped, decomplex | 19/20 uncovered: 1074-1089,1093,1095-1096 | T=1; Object=1 | 1: Decision Pressure=1 | - | - |
| 349 | [src/mir/fsm_transform/recursive_splitter.rb:142](../../src/mir/fsm_transform/recursive_splitter.rb#L142) `add_synthetic_field` | 145 | uncovered, untyped, decomplex | 1/3 uncovered: 143 | T=1; Object=0 | 1: False Simplicity=1 | - | - |
| 350 | [src/mir/mir.rb:245](../../src/mir/mir.rb#L245) `marks` | 245-252 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 351 | [src/mir/mir_checker.rb:774](../../src/mir/mir_checker.rb#L774) `linear_project_branch_state` | 775-776 | uncovered, decomplex | 3/4 uncovered: 775-777 | - | 1: False Simplicity=1 | - | - |
| 352 | [src/mir/mir_checker.rb:819](../../src/mir/mir_checker.rb#L819) `linear_require_same_state!` | 820,824 | uncovered, decomplex | 2/3 uncovered: 820,822 | - | 1: False Simplicity=1 | - | - |
| 353 | [src/mir/mir_checker.rb:837](../../src/mir/mir_checker.rb#L837) `prune_scope_locals!` | 837 | uncovered, decomplex | 14/15 uncovered: 838-840,844,847-856 | - | 1: False Simplicity=1 | - | - |
| 354 | [src/mir/mir_lowering.rb:975](../../src/mir/mir_lowering.rb#L975) `ownership_finalized_node?` | 975-979 | decomplex | covered | - | 1: Decision Pressure=1 | - | - |
| 355 | [src/mir/mir_lowering.rb:1100](../../src/mir/mir_lowering.rb#L1100) `dedupe_transfer_marks` | 1101-1107 | decomplex | covered | - | 1: Decision Pressure=1 | - | - |
| 356 | [src/mir/mir_lowering.rb:1162](../../src/mir/mir_lowering.rb#L1162) `discard_expr_stmt?` | 1165 | decomplex | covered | - | 1: Decision Pressure=1 | - | - |
| 357 | [src/mir/mir_lowering.rb:1389](../../src/mir/mir_lowering.rb#L1389) `owner_cleanup_for_transfer` | 1392-1393 | decomplex | covered | - | 1: Derived-State Staleness=1 | - | - |
| 358 | [src/mir/mir_lowering.rb:1454](../../src/mir/mir_lowering.rb#L1454) `ownership_facts_for_mir_surface` | 1455-1460 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 359 | [src/mir/mir_lowering.rb:1496](../../src/mir/mir_lowering.rb#L1496) `ownership_facts_for_mir_node` | 1497-1500 | uncovered, decomplex | 1/4 uncovered: 1498 | - | 1: False Simplicity=1 | - | - |
| 360 | [src/mir/mir_lowering.rb:1596](../../src/mir/mir_lowering.rb#L1596) `ownership_store_facts_for_consumption` | 1597-1600 | uncovered, decomplex | 2/4 uncovered: 1598-1599 | - | 1: False Simplicity=1 | - | - |
| 361 | [src/mir/mir_lowering.rb:1613](../../src/mir/mir_lowering.rb#L1613) `ownership_transfer_facts_for_consumption` | 1614-1617 | uncovered, decomplex | 1/4 uncovered: 1615 | - | 1: False Simplicity=1 | - | - |
| 362 | [src/mir/mir_lowering.rb:1630](../../src/mir/mir_lowering.rb#L1630) `ownership_facts_for_structural_node` | 1631-1634 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 363 | [src/mir/mir_lowering.rb:1655](../../src/mir/mir_lowering.rb#L1655) `ownership_facts_for_owned_result` | 1656-1659 | uncovered, decomplex | 3/4 uncovered: 1656-1658 | - | 1: False Simplicity=1 | - | - |
| 364 | [src/mir/mir_lowering.rb:1682](../../src/mir/mir_lowering.rb#L1682) `ownership_transfer_facts_for_contract` | 1683-1686 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 365 | [src/mir/mir_lowering.rb:1689](../../src/mir/mir_lowering.rb#L1689) `append_ownership_transfer_facts_for_contract!` | 1689,1691,1694-1695 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 366 | [src/mir/mir_lowering.rb:1789](../../src/mir/mir_lowering.rb#L1789) `implicit_alloc_mark_for_mir_node` | 1789-1790 | decomplex | covered | - | 1: Decision Pressure=1 | - | - |
| 367 | [src/mir/mir_lowering.rb:1842](../../src/mir/mir_lowering.rb#L1842) `ownership_transfers_for_node` | 1842,1845-1846 | decomplex | covered | - | 1: Decision Pressure=1 | - | - |
| 368 | [src/mir/mir_lowering.rb:1865](../../src/mir/mir_lowering.rb#L1865) `ownership_transfer_operands_for_node` | 1865,1867-1871 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 369 | [src/semantic/escape_analysis.rb:319](../../src/semantic/escape_analysis.rb#L319) `self.apply_assignment_escape_sink!` | 320-324 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 370 | [src/semantic/escape_analysis.rb:353](../../src/semantic/escape_analysis.rb#L353) `self.apply_method_call_escape_sink!` | 354 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 371 | [src/semantic/escape_analysis.rb:667](../../src/semantic/escape_analysis.rb#L667) `self.propagate_assignment_ownership!` | 667,671,676 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 372 | [src/semantic/escape_analysis.rb:991](../../src/semantic/escape_analysis.rb#L991) `self.call_result_is_heap_for_callee?` | 991,995,997-998 | decomplex | covered | - | 1: Decision Pressure=1 | - | - |
| 373 | [src/semantic/ownership_graph.rb:51](../../src/semantic/ownership_graph.rb#L51) `each_state` | 51-54 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 374 | [src/semantic/ownership_graph.rb:257](../../src/semantic/ownership_graph.rb#L257) `fork_lightweight` | 258-261,263-267,269-275 | decomplex | covered | - | 1: False Simplicity=1 | - | - |
| 375 | [src/semantic/pass_work_profiler.rb:38](../../src/semantic/pass_work_profiler.rb#L38) `add_walk` | 38-42 | uncovered, decomplex | no data | - | 1: False Simplicity=1 | - | - |
| 376 | [src/semantic/pass_work_profiler.rb:45](../../src/semantic/pass_work_profiler.rb#L45) `add_work` | 45-50 | uncovered, decomplex | no data | - | 1: False Simplicity=1 | - | - |
| 377 | [src/semantic/pass_work_profiler.rb:110](../../src/semantic/pass_work_profiler.rb#L110) `walk_yields_per_input` | 110-114 | uncovered, decomplex | no data | - | 1: Broken Protocols=1 | - | - |
| 378 | [src/semantic/pass_work_profiler.rb:117](../../src/semantic/pass_work_profiler.rb#L117) `top_walkers` | 117-123 | uncovered, decomplex | no data | - | 1: Broken Protocols=1 | - | - |
| 379 | [src/semantic/pass_work_profiler.rb:126](../../src/semantic/pass_work_profiler.rb#L126) `top_walk_times` | 126-132 | uncovered, decomplex | no data | - | 1: Broken Protocols=1 | - | - |
| 380 | [src/semantic/pass_work_profiler.rb:135](../../src/semantic/pass_work_profiler.rb#L135) `top_work` | 135-141 | uncovered, decomplex | no data | - | 1: Broken Protocols=1 | - | - |
| 381 | [src/semantic/pass_work_profiler.rb:144](../../src/semantic/pass_work_profiler.rb#L144) `top_work_times` | 144-150 | uncovered, decomplex | no data | - | 1: Broken Protocols=1 | - | - |
| 382 | [src/semantic/pass_work_profiler.rb:153](../../src/semantic/pass_work_profiler.rb#L153) `top_work_exclusive_times` | 153-159 | uncovered, decomplex | no data | - | 1: Broken Protocols=1 | - | - |
| 383 | [src/semantic/pass_work_profiler.rb:162](../../src/semantic/pass_work_profiler.rb#L162) `work_summaries` | 162-173 | uncovered, decomplex | no data | - | 1: Broken Protocols=1 | - | - |
| 384 | [src/semantic/pass_work_profiler.rb:254](../../src/semantic/pass_work_profiler.rb#L254) `records` | 254-256 | uncovered, decomplex | no data | - | 1: Broken Protocols=1 | - | - |
| 385 | [src/semantic/pass_work_profiler.rb:259](../../src/semantic/pass_work_profiler.rb#L259) `work_summaries` | 259-261 | uncovered, decomplex | no data | - | 1: Broken Protocols=1 | - | - |
| 386 | [src/semantic/pass_work_profiler.rb:264](../../src/semantic/pass_work_profiler.rb#L264) `to_csv` | 264-317 | uncovered, decomplex | no data | - | 1: False Simplicity=1 | - | - |
| 387 | [src/semantic/pass_work_profiler.rb:320](../../src/semantic/pass_work_profiler.rb#L320) `work_details_to_csv` | 320-334 | uncovered, decomplex | no data | - | 1: False Simplicity=1 | - | - |
| 388 | [src/semantic/pass_work_profiler.rb:337](../../src/semantic/pass_work_profiler.rb#L337) `to_table` | 337-390 | uncovered, decomplex | no data | - | 1: False Simplicity=1 | - | - |
| 389 | [src/semantic/pass_work_profiler.rb:393](../../src/semantic/pass_work_profiler.rb#L393) `work_details_to_table` | 393-418 | uncovered, decomplex | no data | - | 1: False Simplicity=1 | - | - |
| 390 | [src/semantic/pass_work_profiler.rb:428](../../src/semantic/pass_work_profiler.rb#L428) `record_for` | 428-436 | uncovered, decomplex | no data | - | 1: False Simplicity=1 | - | - |
| 391 | [src/semantic/pass_work_profiler.rb:515](../../src/semantic/pass_work_profiler.rb#L515) `self.scalar?` | 515-517 | uncovered, untyped, decomplex | no data | T=0; Object=1 | 1: Decision Pressure=1 | - | - |
| 392 | [examples/minivm/bc_emitter.rb:884](../../examples/minivm/bc_emitter.rb#L884) `bc_mir_node_role` | 895-897 | uncovered | no data | - | - | - | - |
| 393 | [examples/minivm/bc_emitter.rb:922](../../examples/minivm/bc_emitter.rb#L922) `compile_stmt` | 992-993 | uncovered | no data | - | - | - | - |
| 394 | [examples/minivm/bc_emitter.rb:1593](../../examples/minivm/bc_emitter.rb#L1593) `annotation_to_vm_type` | 1595-1606 | uncovered | no data | - | - | - | - |
| 395 | [examples/minivm/bc_emitter.rb:2479](../../examples/minivm/bc_emitter.rb#L2479) `compile_expr` | 2777-2778 | uncovered | no data | - | - | - | - |
| 396 | [examples/minivm/bc_emitter.rb:4698](../../examples/minivm/bc_emitter.rb#L4698) `compile_catch_wrapper` | 4753-4756 | uncovered | no data | - | - | - | - |
| 397 | [examples/minivm/bc_emitter.rb:4852](../../examples/minivm/bc_emitter.rb#L4852) `compile_or_exit_bc_rewrite` | 4852-4856 | uncovered | no data | - | - | - | - |
| 398 | [examples/minivm/bc_emitter.rb:4858](../../examples/minivm/bc_emitter.rb#L4858) `emit_or_exit_rewrite_fields` | 4858-4876 | uncovered | no data | - | - | - | - |
| 399 | [examples/minivm/bc_emitter.rb:4878](../../examples/minivm/bc_emitter.rb#L4878) `error_name_for_id` | 4878-4883 | uncovered | no data | - | - | - | - |
| 400 | [examples/minivm/bc_emitter.rb:4885](../../examples/minivm/bc_emitter.rb#L4885) `string_lit_text` | 4885-4890 | uncovered | no data | - | - | - | - |
| 401 | [examples/minivm/bc_emitter.rb:4894](../../examples/minivm/bc_emitter.rb#L4894) `compile_or_exit_catch_body` | 4901-4911,4916 | uncovered | no data | - | - | - | - |
| 402 | [examples/minivm/register_bc_emitter.rb:625](../../examples/minivm/register_bc_emitter.rb#L625) `compile_stmt_inner` | 661-662 | uncovered | no data | - | - | - | - |
| 403 | [examples/minivm/register_bc_emitter.rb:939](../../examples/minivm/register_bc_emitter.rb#L939) `compile_expr_stmt` | 1067 | uncovered | no data | - | - | - | - |
| 404 | [examples/minivm/register_bc_emitter.rb:1203](../../examples/minivm/register_bc_emitter.rb#L1203) `compile_let` | 1204 | uncovered | no data | - | - | - | - |
| 405 | [examples/minivm/register_bc_emitter.rb:1757](../../examples/minivm/register_bc_emitter.rb#L1757) `compile_inline_bc_stmt` | 1759 | uncovered | no data | - | - | - | - |
| 406 | [examples/minivm/register_bc_emitter.rb:3135](../../examples/minivm/register_bc_emitter.rb#L3135) `propagating_catch?` | 3140 | uncovered | no data | - | - | - | - |
| 407 | [examples/minivm/register_bc_emitter.rb:3286](../../examples/minivm/register_bc_emitter.rb#L3286) `compile_or_exit` | 3291-3292,3295-3296,3298,3302-3303,3310 | uncovered | no data | - | - | - | - |
| 408 | [examples/minivm/register_bc_emitter.rb:3366](../../examples/minivm/register_bc_emitter.rb#L3366) `compile_catch_wrapper` | 3379,3396-3399 | uncovered | no data | - | - | - | - |
| 409 | [examples/minivm/register_bc_emitter.rb:4946](../../examples/minivm/register_bc_emitter.rb#L4946) `value_block_expr?` | 4966 | uncovered | no data | - | - | - | - |
| 410 | [examples/minivm/register_bc_emitter.rb:7405](../../examples/minivm/register_bc_emitter.rb#L7405) `binding_type` | 7406-7407 | uncovered | no data | - | - | - | - |
| 411 | [examples/minivm/register_bc_emitter.rb:7413](../../examples/minivm/register_bc_emitter.rb#L7413) `enum_binding_type` | 7414-7415 | uncovered | no data | - | - | - | - |
| 412 | [examples/minivm/register_bc_emitter.rb:7449](../../examples/minivm/register_bc_emitter.rb#L7449) `inferred_expr_type` | 7515-7516 | uncovered | no data | - | - | - | - |
| 413 | [examples/minivm/register_bc_emitter.rb:7565](../../examples/minivm/register_bc_emitter.rb#L7565) `annotation_zig_type` | 7565-7570 | uncovered | no data | - | - | - | - |
| 414 | [src/annotator/annotator.rb:533](../../src/annotator/annotator.rb#L533) `outer_scope_vars` | 534 | uncovered | 1/2 uncovered: 534 | - | - | - | - |
| 415 | [src/ast/ast.rb:1649](../../src/ast/ast.rb#L1649) `full_type` | 1649-1651 | uncovered | 1/3 uncovered: 1650 | - | - | - | - |
| 416 | [src/ast/scope.rb:39](../../src/ast/scope.rb#L39) `key?` | 39-41 | uncovered | 1/3 uncovered: 41 | - | - | - | - |
| 417 | [src/ast/scope.rb:49](../../src/ast/scope.rb#L49) `length` | 49-51 | uncovered | 1/3 uncovered: 51 | - | - | - | - |
| 418 | [src/ast/scope.rb:54](../../src/ast/scope.rb#L54) `pairs` | 54-56 | uncovered | 1/3 uncovered: 56 | - | - | - | - |
| 419 | [src/ast/scope.rb:82](../../src/ast/scope.rb#L82) `[]` | 82-84 | uncovered | 1/3 uncovered: 84 | - | - | - | - |
| 420 | [src/ast/scope.rb:97](../../src/ast/scope.rb#L97) `initialize` | 98-99,101-103 | untyped | covered | T=2; Object=0 | - | - | - |
| 421 | [src/ast/scope.rb:257](../../src/ast/scope.rb#L257) `local_entries` | 257-259 | uncovered | 1/3 uncovered: 259 | - | - | - | - |
| 422 | [src/ast/scope.rb:262](../../src/ast/scope.rb#L262) `local_entry_count` | 262-264 | uncovered | 1/3 uncovered: 264 | - | - | - | - |
| 423 | [src/ast/scope.rb:349](../../src/ast/scope.rb#L349) `is_mutable?` | 350 | untyped | covered | T=1; Object=0 | - | - | - |
| 424 | [src/mir/control_flow.rb:379](../../src/mir/control_flow.rb#L379) `[]` | 379-386 | uncovered | 1/7 uncovered: 384 | - | - | - | - |
| 425 | [src/mir/fsm_transform/emit.rb:347](../../src/mir/fsm_transform/emit.rb#L347) `fsm_structure_sources_for_spec` | 349,351-352 | uncovered | 6/11 uncovered: 348-350,353-355 | - | - | - | - |
| 426 | [src/mir/fsm_transform/emit.rb:929](../../src/mir/fsm_transform/emit.rb#L929) `promote_fsm_mir_to_ctx_fields` | 931 | uncovered | 4/5 uncovered: 930-933 | - | - | - | - |
| 427 | [src/mir/fsm_transform/recursive_splitter.rb:65](../../src/mir/fsm_transform/recursive_splitter.rb#L65) `each` | 65-68 | uncovered, untyped | 1/3 uncovered: 66 | T=1; Object=0 | - | - | - |
| 428 | [src/mir/fsm_transform/recursive_splitter.rb:71](../../src/mir/fsm_transform/recursive_splitter.rb#L71) `alias_overrides_for` | 71-73 | uncovered | 1/2 uncovered: 72 | - | - | - | - |
| 429 | [src/mir/fsm_transform/recursive_splitter.rb:81](../../src/mir/fsm_transform/recursive_splitter.rb#L81) `[]` | 81-83 | uncovered | 1/2 uncovered: 82 | - | - | - | - |
| 430 | [src/mir/fsm_transform/recursive_splitter.rb:178](../../src/mir/fsm_transform/recursive_splitter.rb#L178) `finalize` | 185 | uncovered, untyped | 7/8 uncovered: 179-185 | T=1; Object=0 | - | - | - |
| 431 | [src/mir/lowering/literals.rb:180](../../src/mir/lowering/literals.rb#L180) `default_array_value` | 180-189 | uncovered | 6/7 uncovered: 181-185,187 | - | - | - | - |
| 432 | [src/mir/mir.rb:328](../../src/mir/mir.rb#L328) `compact_child_exprs` | 330 | untyped | covered | T=0; Object=1 | - | - | - |
| 433 | [src/mir/mir.rb:2839](../../src/mir/mir.rb#L2839) `result_type` | 2839-2841 | uncovered | 1/2 uncovered: 2840 | - | - | - | - |
| 434 | [src/mir/mir_checker.rb:188](../../src/mir/mir_checker.rb#L188) `same_state?` | 188-198 | uncovered | 1/2 uncovered: 189 | - | - | - | - |
| 435 | [src/mir/mir_checker.rb:201](../../src/mir/mir_checker.rb#L201) `summary` | 201,212 | uncovered | 2/3 uncovered: 203,211 | - | - | - | - |
| 436 | [src/mir/mir_emitter.rb:1318](../../src/mir/mir_emitter.rb#L1318) `emit_array_default_init` | 1318-1320 | uncovered | 1/2 uncovered: 1319 | - | - | - | - |
| 437 | [src/semantic/escape_analysis.rb:1060](../../src/semantic/escape_analysis.rb#L1060) `self.function_has_owned_return_value?` | 1061-1062 | uncovered | 1/3 uncovered: 1062 | - | - | - | - |
| 438 | [src/semantic/escape_analysis.rb:1065](../../src/semantic/escape_analysis.rb#L1065) `self.function_facts_have_owned_return_value?` | 1065-1067,1069 | uncovered | 1/1 uncovered: 1066 | - | - | - | - |
| 439 | [src/semantic/pass_work_profiler.rb:53](../../src/semantic/pass_work_profiler.rb#L53) `ast_walk_calls` | 53-55 | uncovered | no data | - | - | - | - |
| 440 | [src/semantic/pass_work_profiler.rb:58](../../src/semantic/pass_work_profiler.rb#L58) `ast_walk_yields` | 58-60 | uncovered | no data | - | - | - | - |
| 441 | [src/semantic/pass_work_profiler.rb:63](../../src/semantic/pass_work_profiler.rb#L63) `mir_walk_calls` | 63-65 | uncovered | no data | - | - | - | - |
| 442 | [src/semantic/pass_work_profiler.rb:68](../../src/semantic/pass_work_profiler.rb#L68) `mir_walk_yields` | 68-70 | uncovered | no data | - | - | - | - |
| 443 | [src/semantic/pass_work_profiler.rb:73](../../src/semantic/pass_work_profiler.rb#L73) `total_walk_calls` | 73-75 | uncovered | no data | - | - | - | - |
| 444 | [src/semantic/pass_work_profiler.rb:78](../../src/semantic/pass_work_profiler.rb#L78) `total_walk_yields` | 78-80 | uncovered | no data | - | - | - | - |
| 445 | [src/semantic/pass_work_profiler.rb:83](../../src/semantic/pass_work_profiler.rb#L83) `total_work_calls` | 83-85 | uncovered | no data | - | - | - | - |
| 446 | [src/semantic/pass_work_profiler.rb:88](../../src/semantic/pass_work_profiler.rb#L88) `total_work_units` | 88-90 | uncovered | no data | - | - | - | - |
| 447 | [src/semantic/pass_work_profiler.rb:100](../../src/semantic/pass_work_profiler.rb#L100) `ast_yields_per_input_node` | 100-102 | uncovered | no data | - | - | - | - |
| 448 | [src/semantic/pass_work_profiler.rb:105](../../src/semantic/pass_work_profiler.rb#L105) `mir_yields_per_input_node` | 105-107 | uncovered | no data | - | - | - | - |
| 449 | [src/semantic/pass_work_profiler.rb:186](../../src/semantic/pass_work_profiler.rb#L186) `initialize` | 186-191 | uncovered | no data | - | - | - | - |
| 450 | [src/semantic/pass_work_profiler.rb:223](../../src/semantic/pass_work_profiler.rb#L223) `record_walk` | 223-225 | uncovered | no data | - | - | - | - |
| 451 | [src/semantic/pass_work_profiler.rb:228](../../src/semantic/pass_work_profiler.rb#L228) `record_work` | 228-230 | uncovered | no data | - | - | - | - |
| 452 | [src/semantic/pass_work_profiler.rb:423](../../src/semantic/pass_work_profiler.rb#L423) `current_label` | 423-425 | uncovered | no data | - | - | - | - |
| 453 | [src/semantic/pass_work_profiler.rb:459](../../src/semantic/pass_work_profiler.rb#L459) `self.count_ast_nodes` | 459-461 | uncovered, untyped | no data | T=0; Object=1 | - | - | - |
| 454 | [src/semantic/pass_work_profiler.rb:464](../../src/semantic/pass_work_profiler.rb#L464) `self.count_mir_nodes` | 464-466 | uncovered, untyped | no data | T=0; Object=1 | - | - | - |
| 455 | [src/semantic/pass_work_profiler.rb:469](../../src/semantic/pass_work_profiler.rb#L469) `self.format_count` | 469-474 | uncovered | no data | - | - | - | - |
| 456 | [src/semantic/pass_work_profiler.rb:496](../../src/semantic/pass_work_profiler.rb#L496) `self.count_array_nodes` | 496-498 | uncovered, untyped | no data | T=0; Object=1 | - | - | - |
| 457 | [src/semantic/pass_work_profiler.rb:502](../../src/semantic/pass_work_profiler.rb#L502) `self.count_hash_nodes` | 502-504 | uncovered, untyped | no data | T=0; Object=2 | - | - | - |
| 458 | [tools/dump_mir_tree.rb:42](../../tools/dump_mir_tree.rb#L42) `primitive_json_value?` | 42-45 | uncovered | no data | - | - | - | - |
| 459 | [tools/dump_mir_tree.rb:50](../../tools/dump_mir_tree.rb#L50) `initialize` | 50-53 | uncovered | no data | - | - | - | - |
| 460 | [tools/dump_mir_tree.rb:55](../../tools/dump_mir_tree.rb#L55) `dump` | 55-80 | uncovered | no data | - | - | - | - |
| 461 | [tools/dump_mir_tree.rb:84](../../tools/dump_mir_tree.rb#L84) `dump_mir_node` | 84-123 | uncovered | no data | - | - | - | - |
| 462 | [tools/dump_mir_tree.rb:125](../../tools/dump_mir_tree.rb#L125) `collect_child_ids` | 125-140 | uncovered | no data | - | - | - | - |
| 463 | [tools/dump_mir_tree.rb:142](../../tools/dump_mir_tree.rb#L142) `source_line` | 142-146 | uncovered | no data | - | - | - | - |
| 464 | [tools/dump_mir_tree.rb:148](../../tools/dump_mir_tree.rb#L148) `source_column` | 148-152 | uncovered | no data | - | - | - | - |
| 465 | [tools/dump_mir_tree.rb:154](../../tools/dump_mir_tree.rb#L154) `opaque` | 154-162 | uncovered | no data | - | - | - | - |
| 466 | [tools/profile_compile_hotspots.rb:48](../../tools/profile_compile_hotspots.rb#L48) `reset!` | 48-51 | uncovered | no data | - | - | - | - |
| 467 | [tools/profile_compile_hotspots.rb:53](../../tools/profile_compile_hotspots.rb#L53) `instrument!` | 53-59 | uncovered | no data | - | - | - | - |
| 468 | [tools/profile_compile_hotspots.rb:61](../../tools/profile_compile_hotspots.rb#L61) `report` | 61-73 | uncovered | no data | - | - | - | - |
| 469 | [tools/profile_compile_hotspots.rb:75](../../tools/profile_compile_hotspots.rb#L75) `print_row` | 75-79 | uncovered | no data | - | - | - | - |
| 470 | [tools/profile_compile_hotspots.rb:81](../../tools/profile_compile_hotspots.rb#L81) `track` | 81-96 | uncovered | no data | - | - | - | - |
| 471 | [tools/profile_compile_hotspots.rb:100](../../tools/profile_compile_hotspots.rb#L100) `wrap_instance_methods!` | 100-103 | uncovered | no data | - | - | - | - |
| 472 | [tools/profile_compile_hotspots.rb:105](../../tools/profile_compile_hotspots.rb#L105) `wrap_singleton_methods!` | 105-109 | uncovered | no data | - | - | - | - |
| 473 | [tools/profile_compile_hotspots.rb:111](../../tools/profile_compile_hotspots.rb#L111) `wrap_methods!` | 111-138 | uncovered | no data | - | - | - | - |
| 474 | [tools/profile_function_work.rb:27](../../tools/profile_function_work.rb#L27) `ast_count` | 27-31 | uncovered | no data | - | - | - | - |
| 475 | [tools/profile_function_work.rb:33](../../tools/profile_function_work.rb#L33) `mir_count` | 33-37 | uncovered | no data | - | - | - | - |
| 476 | [tools/profile_function_work.rb:39](../../tools/profile_function_work.rb#L39) `recursive_mir_count` | 39-41 | uncovered | no data | - | - | - | - |
| 477 | [tools/profile_function_work.rb:43](../../tools/profile_function_work.rb#L43) `direct_mir_count` | 43-46 | uncovered | no data | - | - | - | - |
| 478 | [tools/profile_pass_work.rb:51](../../tools/profile_pass_work.rb#L51) `self.measure_work` | 51-56 | uncovered, untyped | no data | T=0; Object=2 | - | - | - |
| 479 | [tools/profile_pass_work.rb:62](../../tools/profile_pass_work.rb#L62) `each_locatable` | 62-75 | uncovered, untyped | no data | T=3; Object=0 | - | - | - |
| 480 | [tools/profile_pass_work.rb:78](../../tools/profile_pass_work.rb#L78) `walk_body` | 78-91 | uncovered, untyped | no data | T=3; Object=0 | - | - | - |
| 481 | [tools/profile_pass_work.rb:94](../../tools/profile_pass_work.rb#L94) `each_bg_block` | 94-107 | uncovered, untyped | no data | T=3; Object=0 | - | - | - |
| 482 | [tools/profile_pass_work.rb:114](../../tools/profile_pass_work.rb#L114) `each_node` | 114-127 | uncovered, untyped | no data | T=3; Object=0 | - | - | - |
| 483 | [tools/profile_pass_work.rb:130](../../tools/profile_pass_work.rb#L130) `each_surface_node` | 130-143 | uncovered, untyped | no data | T=3; Object=0 | - | - | - |
| 484 | [tools/profile_pass_work.rb:146](../../tools/profile_pass_work.rb#L146) `nodes` | 146-156 | uncovered, untyped | no data | T=3; Object=0 | - | - | - |
| 485 | [tools/profile_pass_work.rb:159](../../tools/profile_pass_work.rb#L159) `surface_nodes` | 159-169 | uncovered, untyped | no data | T=3; Object=0 | - | - | - |
| 486 | [tools/profile_pass_work.rb:176](../../tools/profile_pass_work.rb#L176) `with_new_scope` | 176-189 | uncovered, untyped | no data | T=4; Object=0 | - | - | - |
| 487 | [tools/profile_pass_work.rb:192](../../tools/profile_pass_work.rb#L192) `visit` | 192-204 | uncovered, untyped | no data | T=2; Object=0 | - | - | - |
| 488 | [tools/profile_pass_work.rb:207](../../tools/profile_pass_work.rb#L207) `analyze_control_flow_branches` | 207-214 | uncovered | no data | - | - | - | - |
| 489 | [tools/profile_pass_work.rb:217](../../tools/profile_pass_work.rb#L217) `visit_MatchStatement` | 217-224 | uncovered | no data | - | - | - | - |
| 490 | [tools/profile_pass_work.rb:227](../../tools/profile_pass_work.rb#L227) `visit_Program` | 227-229 | uncovered, untyped | no data | T=2; Object=0 | - | - | - |
| 491 | [tools/profile_pass_work.rb:232](../../tools/profile_pass_work.rb#L232) `register_type_declarations` | 232-234 | uncovered, untyped | no data | T=2; Object=0 | - | - | - |
| 492 | [tools/profile_pass_work.rb:237](../../tools/profile_pass_work.rb#L237) `register_program_signatures` | 237-239 | uncovered, untyped | no data | T=2; Object=0 | - | - | - |
| 493 | [tools/profile_pass_work.rb:242](../../tools/profile_pass_work.rb#L242) `bridge_reentrance!` | 242-244 | uncovered, untyped | no data | T=2; Object=0 | - | - | - |
| 494 | [tools/profile_pass_work.rb:247](../../tools/profile_pass_work.rb#L247) `seed_error_types_from_raises!` | 247-249 | uncovered, untyped | no data | T=2; Object=0 | - | - | - |
| 495 | [tools/profile_pass_work.rb:252](../../tools/profile_pass_work.rb#L252) `validate_and_resolve_sync_policy!` | 252-254 | uncovered, untyped | no data | T=2; Object=0 | - | - | - |
| 496 | [tools/profile_pass_work.rb:257](../../tools/profile_pass_work.rb#L257) `analyze_program_bodies!` | 257-259 | uncovered, untyped | no data | T=3; Object=0 | - | - | - |
| 497 | [tools/profile_pass_work.rb:262](../../tools/profile_pass_work.rb#L262) `finalize_program_semantics!` | 262-264 | uncovered, untyped | no data | T=2; Object=0 | - | - | - |
| 498 | [tools/profile_pass_work.rb:267](../../tools/profile_pass_work.rb#L267) `finalize_auto_types!` | 267-269 | uncovered, untyped | no data | T=2; Object=0 | - | - | - |
| 499 | [tools/profile_pass_work.rb:272](../../tools/profile_pass_work.rb#L272) `run_whole_program_semantics!` | 272-274 | uncovered, untyped | no data | T=1; Object=0 | - | - | - |
| 500 | [tools/profile_pass_work.rb:277](../../tools/profile_pass_work.rb#L277) `run_deferred_validations!` | 277-279 | uncovered, untyped | no data | T=1; Object=0 | - | - | - |
| 501 | [tools/profile_pass_work.rb:282](../../tools/profile_pass_work.rb#L282) `mark_annotation_complete!` | 282-284 | uncovered, untyped | no data | T=2; Object=0 | - | - | - |
| 502 | [tools/profile_pass_work.rb:291](../../tools/profile_pass_work.rb#L291) `visible_entries` | 291-300 | uncovered, untyped | no data | T=2; Object=0 | - | - | - |
| 503 | [tools/profile_pass_work.rb:303](../../tools/profile_pass_work.rb#L303) `visible_names` | 303-312 | uncovered, untyped | no data | T=2; Object=0 | - | - | - |
| 504 | [tools/profile_pass_work.rb:315](../../tools/profile_pass_work.rb#L315) `entry_for_write` | 315-327 | uncovered, untyped | no data | T=2; Object=0 | - | - | - |
| 505 | [tools/profile_pass_work.rb:330](../../tools/profile_pass_work.rb#L330) `clone_entry_for_scope` | 330-339 | uncovered | no data | - | - | - | - |
| 506 | [tools/profile_pass_work.rb:346](../../tools/profile_pass_work.rb#L346) `fork_lightweight` | 346-354 | uncovered, untyped | no data | T=2; Object=0 | - | - | - |
| 507 | [tools/profile_pass_work.rb:357](../../tools/profile_pass_work.rb#L357) `restore_lightweight` | 357-362 | uncovered | no data | - | - | - | - |
| 508 | [tools/profile_pass_work.rb:369](../../tools/profile_pass_work.rb#L369) `apply!` | 369-371 | uncovered, untyped | no data | T=3; Object=0 | - | - | - |
| 509 | [tools/profile_pass_work.rb:374](../../tools/profile_pass_work.rb#L374) `propagate_caller_sync!` | 374-379 | uncovered, untyped | no data | T=2; Object=0 | - | - | - |
| 510 | [tools/profile_pass_work.rb:386](../../tools/profile_pass_work.rb#L386) `classify_all!` | 386-391 | uncovered, untyped | no data | T=3; Object=0 | - | - | - |
| 511 | [tools/profile_pass_work.rb:398](../../tools/profile_pass_work.rb#L398) `analyze!` | 398-400 | uncovered, untyped | no data | T=2; Object=0 | - | - | - |
| 512 | [tools/profile_pass_work.rb:407](../../tools/profile_pass_work.rb#L407) `check_function!` | 407-409 | uncovered, untyped | no data | T=5; Object=0 | - | - | - |
| 513 | [tools/profile_pass_work.rb:412](../../tools/profile_pass_work.rb#L412) `check_call_sites!` | 412-414 | uncovered, untyped | no data | T=4; Object=0 | - | - | - |
| 514 | [tools/profile_pass_work.rb:421](../../tools/profile_pass_work.rb#L421) `check_all!` | 421-423 | uncovered, untyped | no data | T=5; Object=0 | - | - | - |
| 515 | [tools/profile_pass_work.rb:430](../../tools/profile_pass_work.rb#L430) `classify` | 430-432 | uncovered, untyped | no data | T=3; Object=0 | - | - | - |
| 516 | [tools/profile_pass_work.rb:439](../../tools/profile_pass_work.rb#L439) `analyze!` | 439-441 | uncovered, untyped | no data | T=3; Object=0 | - | - | - |
| 517 | [tools/profile_pass_work.rb:448](../../tools/profile_pass_work.rb#L448) `finalize_needs_rt!` | 448-450 | uncovered, untyped | no data | T=1; Object=0 | - | - | - |
| 518 | [tools/profile_pass_work.rb:453](../../tools/profile_pass_work.rb#L453) `transform_function!` | 453-455 | uncovered, untyped | no data | T=2; Object=0 | - | - | - |
| 519 | [tools/profile_pass_work.rb:462](../../tools/profile_pass_work.rb#L462) `analyze` | 462-464 | uncovered, untyped | no data | T=4; Object=0 | - | - | - |
| 520 | [tools/profile_pass_work.rb:471](../../tools/profile_pass_work.rb#L471) `build` | 471-473 | uncovered, untyped | no data | T=3; Object=0 | - | - | - |
| 521 | [tools/profile_pass_work.rb:480](../../tools/profile_pass_work.rb#L480) `analyze!` | 480-482 | uncovered, untyped | no data | T=1; Object=0 | - | - | - |
| 522 | [tools/profile_pass_work.rb:485](../../tools/profile_pass_work.rb#L485) `apply_transfer` | 485-495 | uncovered, untyped | no data | T=3; Object=0 | - | - | - |
| 523 | [tools/profile_pass_work.rb:498](../../tools/profile_pass_work.rb#L498) `join_predecessors` | 498-508 | uncovered, untyped | no data | T=2; Object=0 | - | - | - |
| 524 | [tools/profile_pass_work.rb:511](../../tools/profile_pass_work.rb#L511) `dup_state` | 511-520 | uncovered, untyped | no data | T=2; Object=0 | - | - | - |
| 525 | [tools/profile_pass_work.rb:527](../../tools/profile_pass_work.rb#L527) `lower` | 527-532 | uncovered, untyped | no data | T=2; Object=0 | - | - | - |
| 526 | [tools/profile_pass_work.rb:535](../../tools/profile_pass_work.rb#L535) `lower_body` | 535-540 | uncovered, untyped | no data | T=2; Object=0 | - | - | - |
| 527 | [tools/profile_pass_work.rb:543](../../tools/profile_pass_work.rb#L543) `lower_match` | 543-548 | uncovered, untyped | no data | T=2; Object=0 | - | - | - |
| 528 | [tools/profile_pass_work.rb:551](../../tools/profile_pass_work.rb#L551) `lower_switch_match` | 551-556 | uncovered, untyped | no data | T=3; Object=0 | - | - | - |
| 529 | [tools/profile_pass_work.rb:559](../../tools/profile_pass_work.rb#L559) `lower_union_match` | 559-564 | uncovered, untyped | no data | T=3; Object=0 | - | - | - |
| 530 | [tools/profile_pass_work.rb:567](../../tools/profile_pass_work.rb#L567) `lower_match_branch` | 567-572 | uncovered, untyped | no data | T=3; Object=0 | - | - | - |
| 531 | [tools/profile_pass_work.rb:575](../../tools/profile_pass_work.rb#L575) `union_match_arm_plans` | 575-579 | uncovered, untyped | no data | T=4; Object=0 | - | - | - |
| 532 | [tools/profile_pass_work.rb:582](../../tools/profile_pass_work.rb#L582) `append_ownership_transfers_for_mir_body` | 582-587 | uncovered, untyped | no data | T=4; Object=0 | - | - | - |
| 533 | [tools/profile_pass_work.rb:590](../../tools/profile_pass_work.rb#L590) `append_nested_ownership_transfers_for_mir_body` | 590-595 | uncovered, untyped | no data | T=5; Object=0 | - | - | - |
| 534 | [tools/profile_pass_work.rb:598](../../tools/profile_pass_work.rb#L598) `finalize_ownership_for_mir_node!` | 598-602 | uncovered, untyped | no data | T=4; Object=0 | - | - | - |
| 535 | [tools/profile_pass_work.rb:606](../../tools/profile_pass_work.rb#L606) `self.lower_node_label` | 606-611 | uncovered, untyped | no data | T=1; Object=0 | - | - | - |
| 536 | [tools/profile_pass_work.rb:614](../../tools/profile_pass_work.rb#L614) `self.install!` | 614-632 | uncovered | no data | - | - | - | - |
| 537 | [tools/profile_pass_work.rb:635](../../tools/profile_pass_work.rb#L635) `self.current_stage_label` | 635-640 | uncovered | no data | - | - | - | - |
| 538 | [tools/profile_pass_work.rb:646](../../tools/profile_pass_work.rb#L646) `initialize` | 646-651 | uncovered | no data | - | - | - | - |
| 539 | [tools/profile_pass_work.rb:657](../../tools/profile_pass_work.rb#L657) `run` | 657-766 | uncovered, untyped | no data | T=9; Object=0 | - | - | - |
| 540 | [tools/profile_structural_multipliers.rb:31](../../tools/profile_structural_multipliers.rb#L31) `now` | 31-33 | uncovered | no data | - | - | - | - |
| 541 | [tools/profile_structural_multipliers.rb:35](../../tools/profile_structural_multipliers.rb#L35) `src_caller` | 35-49 | uncovered | no data | - | - | - | - |
| 542 | [tools/profile_structural_multipliers.rb:51](../../tools/profile_structural_multipliers.rb#L51) `add_count` | 51-56 | uncovered | no data | - | - | - | - |
| 543 | [tools/profile_structural_multipliers.rb:61](../../tools/profile_structural_multipliers.rb#L61) `initialize_copy` | 61-67 | uncovered | no data | - | - | - | - |
| 544 | [tools/profile_structural_multipliers.rb:69](../../tools/profile_structural_multipliers.rb#L69) `resolve_entry` | 69-84 | uncovered | no data | - | - | - | - |
| 545 | [tools/profile_structural_multipliers.rb:86](../../tools/profile_structural_multipliers.rb#L86) `entry?` | 86-103 | uncovered | no data | - | - | - | - |
| 546 | [tools/profile_structural_multipliers.rb:109](../../tools/profile_structural_multipliers.rb#L109) `initialize_copy` | 109-114 | uncovered | no data | - | - | - | - |
| 547 | [tools/profile_structural_multipliers.rb:121](../../tools/profile_structural_multipliers.rb#L121) `fork_lightweight` | 121-126 | uncovered | no data | - | - | - | - |
| 548 | [tools/profile_structural_multipliers.rb:128](../../tools/profile_structural_multipliers.rb#L128) `restore_lightweight` | 128-133 | uncovered | no data | - | - | - | - |
| 549 | [tools/profile_structural_multipliers.rb:139](../../tools/profile_structural_multipliers.rb#L139) `analyze_control_flow_branches` | 139-145 | uncovered | no data | - | - | - | - |
| 550 | [tools/profile_structural_multipliers.rb:153](../../tools/profile_structural_multipliers.rb#L153) `lookup_scope_for` | 153-159 | uncovered | no data | - | - | - | - |
| 551 | [tools/profile_structural_multipliers.rb:161](../../tools/profile_structural_multipliers.rb#L161) `resolve_variable_scope` | 161-167 | uncovered | no data | - | - | - | - |
| 552 | [tools/profile_structural_multipliers.rb:169](../../tools/profile_structural_multipliers.rb#L169) `with_new_scope` | 169-177 | uncovered | no data | - | - | - | - |
| 553 | [tools/profile_structural_multipliers.rb:184](../../tools/profile_structural_multipliers.rb#L184) `each_locatable` | 184-193 | uncovered | no data | - | - | - | - |
| 554 | [tools/profile_structural_multipliers.rb:195](../../tools/profile_structural_multipliers.rb#L195) `walk_body` | 195-204 | uncovered | no data | - | - | - | - |
| 555 | [tools/profile_structural_multipliers.rb:214](../../tools/profile_structural_multipliers.rb#L214) `each_node` | 214-223 | uncovered | no data | - | - | - | - |
| 556 | [tools/profile_structural_multipliers.rb:225](../../tools/profile_structural_multipliers.rb#L225) `each_surface_node` | 225-234 | uncovered | no data | - | - | - | - |
| 557 | [tools/profile_structural_multipliers.rb:236](../../tools/profile_structural_multipliers.rb#L236) `nodes` | 236-241 | uncovered | no data | - | - | - | - |
| 558 | [tools/profile_structural_multipliers.rb:243](../../tools/profile_structural_multipliers.rb#L243) `surface_nodes` | 243-248 | uncovered | no data | - | - | - | - |
| 559 | [tools/profile_walk_counts.rb:29](../../tools/profile_walk_counts.rb#L29) `caller_key` | 29-38 | uncovered | no data | - | - | - | - |
| 560 | [tools/profile_walk_counts.rb:45](../../tools/profile_walk_counts.rb#L45) `each_locatable` | 45-58 | uncovered | no data | - | - | - | - |
| 561 | [tools/profile_walk_counts.rb:60](../../tools/profile_walk_counts.rb#L60) `walk_body` | 60-73 | uncovered | no data | - | - | - | - |
| 562 | [tools/profile_walk_counts.rb:75](../../tools/profile_walk_counts.rb#L75) `each_bg_block` | 75-88 | uncovered | no data | - | - | - | - |
| 563 | [tools/profile_walk_counts.rb:98](../../tools/profile_walk_counts.rb#L98) `each_node` | 98-111 | uncovered | no data | - | - | - | - |
| 564 | [tools/profile_walk_counts.rb:113](../../tools/profile_walk_counts.rb#L113) `each_surface_node` | 113-126 | uncovered | no data | - | - | - | - |
| 565 | [tools/profile_walk_counts.rb:128](../../tools/profile_walk_counts.rb#L128) `nodes` | 128-137 | uncovered | no data | - | - | - | - |
| 566 | [tools/profile_walk_counts.rb:139](../../tools/profile_walk_counts.rb#L139) `surface_nodes` | 139-148 | uncovered | no data | - | - | - | - |
| 567 | [tools/sample_compile_stacks.rb:62](../../tools/sample_compile_stacks.rb#L62) `initialize` | 62-71 | uncovered | no data | - | - | - | - |
| 568 | [tools/sample_compile_stacks.rb:76](../../tools/sample_compile_stacks.rb#L76) `start` | 76-84 | uncovered | no data | - | - | - | - |
| 569 | [tools/sample_compile_stacks.rb:86](../../tools/sample_compile_stacks.rb#L86) `stop` | 86-89 | uncovered | no data | - | - | - | - |
| 570 | [tools/sample_compile_stacks.rb:91](../../tools/sample_compile_stacks.rb#L91) `sample` | 91-103 | uncovered | no data | - | - | - | - |
| 571 | [tools/sample_compile_stacks.rb:105](../../tools/sample_compile_stacks.rb#L105) `frame_label` | 105-109 | uncovered | no data | - | - | - | - |
| 572 | [tools/sample_compile_stacks.rb:112](../../tools/sample_compile_stacks.rb#L112) `timed_phase` | 112-126 | uncovered | no data | - | - | - | - |
| 573 | [tools/sample_compile_stacks.rb:130](../../tools/sample_compile_stacks.rb#L130) `compile_file` | 130-137 | uncovered | no data | - | - | - | - |
| 574 | [tools/sample_compile_stacks.rb:139](../../tools/sample_compile_stacks.rb#L139) `compile_module_mir` | 139-146 | uncovered | no data | - | - | - | - |
| 575 | [tools/sample_compile_stacks.rb:236](../../tools/sample_compile_stacks.rb#L236) `top_counts` | 236-242 | uncovered | no data | - | - | - | - |
| 576 | [tools/stackprof_compile.rb:55](../../tools/stackprof_compile.rb#L55) `compile_frontend` | 55-58 | uncovered | no data | - | - | - | - |
| 577 | [tools/stackprof_compile.rb:60](../../tools/stackprof_compile.rb#L60) `build_lowering` | 60-70 | uncovered | no data | - | - | - | - |
| 578 | [tools/stackprof_compile.rb:72](../../tools/stackprof_compile.rb#L72) `compile_mir` | 72-76 | uncovered | no data | - | - | - | - |
| 579 | [tools/trace_compile_hotspots.rb:36](../../tools/trace_compile_hotspots.rb#L36) `selected_event?` | 36-59 | uncovered | no data | - | - | - | - |
| 580 | [tools/trace_compile_hotspots.rb:61](../../tools/trace_compile_hotspots.rb#L61) `run_phase` | 61-116 | uncovered | no data | - | - | - | - |
| 581 | [tools/trace_method_times.rb:61](../../tools/trace_method_times.rb#L61) `initialize` | 61-76 | uncovered | no data | - | - | - | - |
| 582 | [tools/trace_method_times.rb:80](../../tools/trace_method_times.rb#L80) `run` | 80-93 | uncovered | no data | - | - | - | - |
| 583 | [tools/trace_method_times.rb:95](../../tools/trace_method_times.rb#L95) `write_csv` | 95-112 | uncovered | no data | - | - | - | - |
| 584 | [tools/trace_method_times.rb:114](../../tools/trace_method_times.rb#L114) `print_report` | 114-121 | uncovered | no data | - | - | - | - |
| 585 | [tools/trace_method_times.rb:125](../../tools/trace_method_times.rb#L125) `sorted_records` | 125-127 | uncovered | no data | - | - | - | - |
| 586 | [tools/trace_method_times.rb:129](../../tools/trace_method_times.rb#L129) `print_record` | 129-133 | uncovered | no data | - | - | - | - |
| 587 | [tools/trace_method_times.rb:135](../../tools/trace_method_times.rb#L135) `on_call` | 135-141 | uncovered | no data | - | - | - | - |
| 588 | [tools/trace_method_times.rb:143](../../tools/trace_method_times.rb#L143) `on_return` | 143-160 | uncovered | no data | - | - | - | - |
| 589 | [tools/trace_method_times.rb:162](../../tools/trace_method_times.rb#L162) `target_path?` | 162-164 | uncovered | no data | - | - | - | - |
| 590 | [tools/trace_method_times.rb:166](../../tools/trace_method_times.rb#L166) `owner_name` | 166-168 | uncovered | no data | - | - | - | - |
| 591 | [tools/trace_method_times.rb:170](../../tools/trace_method_times.rb#L170) `now` | 170-172 | uncovered | no data | - | - | - | - |
| 592 | [tools/trace_method_times.rb:175](../../tools/trace_method_times.rb#L175) `compile_frontend` | 175-178 | uncovered | no data | - | - | - | - |
| 593 | [tools/trace_method_times.rb:180](../../tools/trace_method_times.rb#L180) `build_lowering` | 180-190 | uncovered | no data | - | - | - | - |
| 594 | [tools/trace_method_times.rb:192](../../tools/trace_method_times.rb#L192) `compile_to_mir` | 192-196 | uncovered | no data | - | - | - | - |
