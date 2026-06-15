# Boobytrap Report

> Defect-risk hotspots: recurring bug-fix locality (bugspots, time-decayed) x branch-coverage gap.
> A ranking to triage **top-down**, never a verdict. A
> hotspot is "the code most likely to be a bug source,"
> not "a bug."

## Table of Contents
- [Project Prioritization](#project-prioritization)
- [Hotspots (78)](#hotspots-78)
- [Mostly Uncovered Methods (1931)](#mostly-uncovered-methods-1931)
- [State-Based Branch Hotspots (509)](#statebased-branch-hotspots-509)
- [Multi-File Fix Blast Radius (83)](#multifile-fix-blast-radius-83)
- [Fixed But Unmeasured (5)](#fixed-but-unmeasured-5)
- [Run Summary](#run-summary)

## Project Prioritization
- The single highest-risk file is **`src/mir/lowering/variables.rb`** (hotspot=0.6878: fix_norm=0.688, branch gap=100.0%).
- 11 file(s) are within 50% of the top score (hotspot >= 0.3439); triage those first.
- Highest state-based branch hotspot: `src/ast/ast.rb:initialize` (score=1009.78, state branches=21, fix_norm=0.746, branch gap=27.5%).
- Highest multi-file fix blast radius: `src/mir/mir_lowering.rb` (score=43.359, avg files/fix=10.42, max=78).
- Highest empirical method risk: `src/backends/mir_emitter.rb:55` `emit` (risk=649.68, fix_norm=0.513, verification=100.0% killed / advisory).

## Hotspots (78)
_normalized fix-churn x branch-gap; highest = most likely defect source._

| # | file | hotspot | fix_norm | branch gap | uncovered/total |
|---|------|---------|----------|-----------|-----------------|
| 1 | `src/mir/lowering/variables.rb` | 0.6878 | 0.688 | 100.0% | 152/152 |
| 2 | `src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb` | 0.5499 | 0.55 | 100.0% | 101/101 |
| 3 | `src/mir/lowering/functions.rb` | 0.5206 | 0.521 | 100.0% | 214/214 |
| 4 | `src/backends/mir_emitter.rb` | 0.5127 | 0.513 | 100.0% | 344/344 |
| 5 | `src/mir/lowering/capabilities.rb` | 0.5004 | 0.5 | 100.0% | 100/100 |
| 6 | `src/mir/hoist.rb` | 0.4599 | 0.46 | 100.0% | 241/241 |
| 7 | `src/mir/lowering/concurrency.rb` | 0.4449 | 0.445 | 100.0% | 81/81 |
| 8 | `src/mir/cleanup_classifier.rb` | 0.4381 | 0.438 | 100.0% | 220/220 |
| 9 | `src/semantic/escape_analysis.rb` | 0.433 | 0.433 | 100.0% | 231/231 |
| 10 | `src/annotator/annotator.rb` | 0.3612 | 0.361 | 100.0% | 25/25 |
| 11 | `src/mir/lowering/expressions.rb` | 0.3482 | 0.348 | 100.0% | 242/242 |
| 12 | `src/annotator/helpers/effects.rb` | 0.3228 | 0.323 | 100.0% | 129/129 |
| 13 | `src/mir/lower/pipeline/pipeline_materializer.rb` | 0.265 | 0.265 | 100.0% | 22/22 |
| 14 | `src/mir/mir_lowering.rb` | 0.2637 | 1.0 | 26.4% | 725/2749 |
| 15 | `src/mir/lower/pipeline/pipeline_host.rb` | 0.26 | 0.26 | 100.0% | 33/33 |
| 16 | `src/mir/lower/pipeline/pipeline_lowering_bridge.rb` | 0.26 | 0.26 | 100.0% | 1/1 |
| 17 | `src/mir/lower/pipeline/pipeline_records.rb` | 0.26 | 0.26 | 100.0% | 1/1 |
| 18 | `src/semantic/bg_capture_classifier.rb` | 0.26 | 0.26 | 100.0% | 9/9 |
| 19 | `src/semantic/capture_strategy.rb` | 0.26 | 0.26 | 100.0% | 28/28 |
| 20 | `src/ast/ast.rb` | 0.2051 | 0.746 | 27.5% | 77/280 |
| 21 | `src/mir/mir_checker.rb` | 0.1999 | 0.684 | 29.2% | 132/452 |
| 22 | `src/annotator/domains/errors.rb` | 0.1724 | 0.172 | 100.0% | 83/83 |
| 23 | `src/annotator/phases/declaration_index.rb` | 0.1724 | 0.172 | 100.0% | 8/8 |
| 24 | `src/annotator/helpers/with_match_check.rb` | 0.171 | 0.171 | 100.0% | 48/48 |
| 25 | `src/annotator/phases/body_analysis.rb` | 0.1504 | 0.15 | 100.0% | 31/31 |
| 26 | `src/semantic/concurrency_checks.rb` | 0.1504 | 0.15 | 100.0% | 21/21 |
| 27 | `src/mir/lowering/control_flow.rb` | 0.1436 | 0.144 | 100.0% | 126/126 |
| 28 | `src/mir/fsm_transform/segments.rb` | 0.1433 | 0.172 | 83.1% | 69/83 |
| 29 | `src/ast/std_lib.rb` | 0.1249 | 0.275 | 45.5% | 10/22 |
| 30 | `src/mir/lower/pipeline/pipeline_range_lowerer.rb` | 0.1176 | 0.118 | 100.0% | 63/63 |
| 31 | `src/mir/lowering/literals.rb` | 0.1123 | 0.112 | 100.0% | 26/26 |
| 32 | `src/annotator/domains/control_flow.rb` | 0.1072 | 0.107 | 100.0% | 106/106 |
| 33 | `src/mir/fsm_transform/suspend_resolvers.rb` | 0.1021 | 0.306 | 33.3% | 11/33 |
| 34 | `src/mir/fiber_ctx_builder.rb` | 0.0813 | 0.596 | 13.6% | 3/22 |
| 35 | `src/mir/fsm_ops.rb` | 0.0808 | 0.26 | 31.1% | 23/74 |
| 36 | `src/mir/mir_pass.rb` | 0.0806 | 0.359 | 22.5% | 89/396 |
| 37 | `src/mir/fsm_transform/emit.rb` | 0.0696 | 0.346 | 20.1% | 38/189 |
| 38 | `src/mir/test_lowering.rb` | 0.0648 | 0.254 | 25.5% | 12/47 |
| 39 | `src/ast/diagnostic_registry.rb` | 0.0636 | 0.178 | 35.7% | 5/14 |
| 40 | `src/mir/fsm_transform/recursive_splitter.rb` | 0.0599 | 0.172 | 34.7% | 50/144 |
| 41 | `src/annotator/helpers/function_analysis.rb` | 0.0501 | 0.05 | 100.0% | 200/200 |
| 42 | `src/annotator/helpers/intrinsic_registry.rb` | 0.0412 | 0.041 | 100.0% | 41/41 |
| 43 | `src/annotator/helpers/capabilities.rb` | 0.0387 | 0.039 | 100.0% | 166/166 |
| 44 | `src/semantic/ownership_graph.rb` | 0.0385 | 0.039 | 100.0% | 33/33 |
| 45 | `src/mir/control_flow.rb` | 0.0369 | 0.149 | 24.8% | 167/673 |
| 46 | `src/annotator/domains/variables.rb` | 0.0367 | 0.037 | 100.0% | 91/91 |
| 47 | `src/tools/clear_build_support.rb` | 0.0367 | 0.037 | 100.0% | 23/23 |
| 48 | `src/mir/fsm_lowering.rb` | 0.0353 | 0.121 | 29.3% | 24/82 |
| 49 | `src/tools/clear_fix_support.rb` | 0.0294 | 0.029 | 100.0% | 43/43 |
| 50 | `src/annotator/domains/member_access.rb` | 0.023 | 0.023 | 100.0% | 88/88 |
| 51 | `src/tools/formatter.rb` | 0.021 | 0.021 | 100.0% | 530/530 |
| 52 | `src/semantic/effect_set.rb` | 0.018 | 0.018 | 100.0% | 1/1 |
| 53 | `src/ast/fixable_error.rb` | 0.0168 | 0.029 | 57.1% | 8/14 |
| 54 | `src/annotator/helpers/lock_helper.rb` | 0.0139 | 0.014 | 100.0% | 45/45 |
| 55 | `src/annotator/helpers/pipe_analysis.rb` | 0.0139 | 0.014 | 100.0% | 186/186 |
| 56 | `src/annotator/helpers/method_analysis.rb` | 0.0086 | 0.009 | 100.0% | 24/24 |
| 57 | `src/annotator/helpers/generic_analysis.rb` | 0.0051 | 0.005 | 100.0% | 100/100 |
| 58 | `src/ast/parser.rb` | 0.004 | 0.023 | 17.2% | 184/1069 |
| 59 | `src/ast/symbol_entry.rb` | 0.0029 | 0.019 | 15.8% | 3/19 |
| 60 | `src/ast/type.rb` | 0.0017 | 0.01 | 17.6% | 132/750 |
| 61 | `src/annotator.rb` | 0.0014 | 0.006 | 24.0% | 607/2526 |
| 62 | `src/mir/pre_mir_type_check.rb` | 0.0004 | 0.001 | 41.7% | 10/24 |
| 63 | `src/mir/mir.rb` | 0.0 | 0.957 | 0.0% | 0/9 |
| 64 | `src/ast/schemas.rb` | 0.0 | 0.118 | 0.0% | 0/4 |
| 65 | `src/backends/transpiler.rb` | 0.0 | 0.0 | 55.0% | 22/40 |
| 66 | `src/lsp/server.rb` | 0.0 | 0.0 | 3.0% | 1/33 |
| 67 | `src/ast/scope.rb` | 0.0 | 0.0 | 25.4% | 16/63 |
| 68 | `src/tools/doctor.rb` | 0.0 | 0.0 | 70.5% | 351/498 |
| 69 | `src/tools/pprof.rb` | 0.0 | 0.0 | 100.0% | 20/20 |
| 70 | `src/tools/stack_verifier.rb` | 0.0 | 0.0 | 100.0% | 42/42 |
| 71 | `src/tools/lint_fix_rewriter.rb` | 0.0 | 0.0 | 100.0% | 61/61 |
| 72 | `src/ast/diagnostic_buckets.rb` | 0.0 | 0.0 | 100.0% | 8/8 |
| 73 | `src/ast/diagnostic_examples.rb` | 0.0 | 0.0 | 25.7% | 9/35 |
| 74 | `src/lsp/diagnostics.rb` | 0.0 | 0.0 | 26.2% | 11/42 |
| 75 | `src/tools/pprof_converter.rb` | 0.0 | 0.0 | 100.0% | 39/39 |

- ...(+3 more)

## Mostly Uncovered Methods (1931)
_non-trivial methods (`>=5` executable lines) with very low line coverage; risk = missed lines x gap, Decomplex detector score, instance-state writes, dark branches, fix history, and mutation verification when supplied._

- Completely uncovered: 1912
- <=10% covered: 1924
- <=20% covered: 1931
- <=50% covered: 1945

| # | method | risk | covered | missed | fix_norm | decomplex | verification | profile | writes | dark branches |
|---|--------|------|---------|--------|----------|-----------|--------------|---------|--------|---------------|
| 1 | `src/backends/mir_emitter.rb:55` `emit` | 649.68 | 0/148 | 148 | 0.513 | 5 | 100.0% killed / advisory | lurking disaster | 0 | 141 |
| 2 | `src/mir/lowering/functions.rb:291` `lower_function_def` | 355.46 | 0/91 | 91 | 0.521 | 14 | no mutation / missing | lurking disaster | 3 | 16 |
| 3 | `src/backends/mir_emitter.rb:659` `emit_shard_concurrent_each` | 344.96 | 0/112 | 112 | 0.513 | 4 | 100.0% killed / advisory | lurking disaster | 0 | 4 |
| 4 | `src/mir/lowering/functions.rb:1590` `lower_intrinsic` | 342.45 | 0/85 | 85 | 0.521 | 16 | no mutation / missing | lurking disaster | 1 | 17 |
| 5 | `src/mir/lowering/variables.rb:210` `var_decl_facts` | 274.22 | 0/64 | 64 | 0.688 | 11 | no mutation / missing | lurking disaster | 2 | 6 |
| 6 | `src/mir/lowering/concurrency.rb:1000` `lower_bg_stream_block` | 242.0 | 0/92 | 92 | 0.445 | 11 | no mutation / missing | weak verification | 5 | 4 |
| 7 | `src/mir/lowering/variables.rb:1078` `lower_template_indexed_assignment` | 235.73 | 0/59 | 59 | 0.688 | 7 | no mutation / missing | lurking disaster | 1 | 6 |
| 8 | `src/annotator/helpers/capabilities.rb:150` `validate_capability_transition!` | 234.27 | 0/127 | 127 | 0.039 | 8 | no mutation / missing | weak verification | 2 | 29 |
| 9 | `src/annotator/helpers/function_analysis.rb:200` `visit_FunctionDef` | 233.7 | 0/115 | 115 | 0.05 | 11 | no mutation / missing | weak verification | 13 | 18 |
| 10 | `src/mir/lowering/variables.rb:558` `lower_var_decl_init` | 213.28 | 0/42 | 42 | 0.688 | 9 | no mutation / missing | lurking disaster | 2 | 18 |
| 11 | `src/annotator/phases/body_analysis.rb:328` `record_body_fact_node!` | 206.77 | 0/77 | 77 | 0.15 | 8 | no mutation / missing | weak verification | 23 | 24 |
| 12 | `src/mir/lowering/variables.rb:1254` `lower_auto_lock_assignment` | 205.26 | 0/49 | 49 | 0.688 | 7 | no mutation / missing | lurking disaster | 2 | 5 |
| 13 | `src/mir/lower/pipeline/pipeline_host.rb:276` `build_concurrent_lowerer` | 203.71 | 0/104 | 104 | 0.26 | 1 | no mutation / missing | weak verification | 6 | 0 |
| 14 | `src/mir/lower/pipeline/pipeline_host.rb:746` `build_soa_scalar_fold_block` | 203.71 | 0/93 | 93 | 0.26 | 9 | no mutation / missing | weak verification | 0 | 10 |
| 15 | `src/annotator/domains/member_access.rb:264` `visit_StructLit` | 203.22 | 0/99 | 99 | 0.023 | 14 | no mutation / missing | weak verification | 3 | 28 |
| 16 | `src/backends/mir_emitter.rb:560` `emit_extern_trampoline` | 198.35 | 0/43 | 43 | 0.513 | 11 | 100.0% killed / advisory | lurking disaster | 4 | 11 |
| 17 | `src/annotator/helpers/effects.rb:499` `compute_can_fail!` | 193.75 | 0/73 | 73 | 0.323 | 9 | no mutation / missing | weak verification | 6 | 17 |
| 18 | `src/backends/mir_emitter.rb:1427` `emit_sorted_lock_acquire_fallible` | 191.17 | 0/59 | 59 | 0.513 | 5 | 100.0% killed / advisory | lurking disaster | 0 | 0 |
| 19 | `src/mir/lowering/functions.rb:798` `build_post_outer_fn` | 190.73 | 0/40 | 40 | 0.521 | 15 | no mutation / missing | lurking disaster | 1 | 5 |
| 20 | `src/annotator/helpers/function_analysis.rb:350` `resolve_call` | 189.55 | 0/80 | 80 | 0.05 | 15 | no mutation / missing | weak verification | 10 | 24 |
| 21 | `src/mir/hoist.rb:822` `normalize_allocating_mir_stmt!` | 187.35 | 0/60 | 60 | 0.46 | 9 | no mutation / missing | weak verification | 4 | 22 |
| 22 | `src/mir/lowering/control_flow.rb:361` `for_each_loop_stmt` | 183.3 | 0/94 | 94 | 0.144 | 9 | no mutation / missing | weak verification | 0 | 6 |
| 23 | `src/mir/rewriters/pipeline_rewriter.rb:393` `build_init` | 180.53 | 0/86 | 86 | 0.0 | 6 | 100.0% killed / advisory | weak verification | 26 | 7 |
| 24 | `src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb:433` `lower_shard_concurrent_each_zig` | 178.17 | 0/53 | 53 | 0.55 | 4 | no mutation / missing | lurking disaster | 0 | 3 |
| 25 | `src/annotator/domains/execution_boundaries.rb:12` `visit_WithBlock` | 172.55 | 0/89 | 89 | 0.0 | 13 | no mutation / missing | weak verification | 5 | 11 |
| 26 | `src/tools/formatter.rb:1289` `expand_if_while_for` | 170.25 | 0/67 | 67 | 0.021 | 14 | no mutation / missing | weak verification | 15 | 24 |
| 27 | `src/mir/lowering/concurrency.rb:1222` `lower_next_expr` | 168.67 | 0/56 | 56 | 0.445 | 11 | no mutation / missing | weak verification | 5 | 6 |
| 28 | `src/annotator/domains/errors.rb:369` `visit_ReturnNode` | 167.39 | 0/69 | 69 | 0.172 | 9 | no mutation / missing | weak verification | 7 | 18 |
| 29 | `src/mir/lowering/variables.rb:1017` `lower_map_indexed_assignment` | 166.77 | 0/34 | 34 | 0.688 | 10 | no mutation / missing | lurking disaster | 0 | 6 |
| 30 | `src/mir/rewriters/pipeline_rewriter.rb:489` `build_recursive_body` | 166.75 | 0/83 | 83 | 0.0 | 13 | 100.0% killed / advisory | weak verification | 8 | 9 |
| 31 | `src/tools/formatter.rb:2803` `needs_space?` | 166.55 | 0/56 | 56 | 0.021 | 10 | no mutation / missing | weak verification | 25 | 33 |
| 32 | `src/annotator/domains/variables.rb:75` `finalize_decl_node!` | 163.9 | 0/76 | 76 | 0.037 | 12 | no mutation / missing | weak verification | 7 | 16 |
| 33 | `src/mir/lowering/functions.rb:1388` `lower_method_call` | 163.28 | 0/32 | 32 | 0.521 | 14 | no mutation / missing | lurking disaster | 0 | 7 |
| 34 | `src/mir/lowering/concurrency.rb:383` `lower_do_block` | 159.24 | 0/68 | 68 | 0.445 | 4 | no mutation / missing | weak verification | 1 | 2 |
| 35 | `src/mir/lowering/functions.rb:1331` `lower_func_call` | 158.94 | 0/32 | 32 | 0.521 | 13 | no mutation / missing | lurking disaster | 0 | 7 |
| 36 | `src/mir/lower/pipeline/pipeline_range_lowerer.rb:307` `build_lazy_range_prefix` | 158.87 | 0/67 | 67 | 0.118 | 13 | no mutation / missing | weak verification | 7 | 9 |
| 37 | `src/annotator/helpers/pipe_analysis.rb:1423` `analyze_concurrent_op` | 158.79 | 0/68 | 68 | 0.014 | 18 | no mutation / missing | weak verification | 4 | 18 |
| 38 | `src/mir/rewriters/pipeline_rewriter.rb:94` `rewrite_pipeline` | 158.05 | 0/73 | 73 | 0.0 | 14 | 100.0% killed / advisory | weak verification | 5 | 20 |
| 39 | `src/mir/lowering/functions.rb:1753` `materialize_stdlib_arguments` | 157.5 | 0/39 | 39 | 0.521 | 8 | no mutation / missing | lurking disaster | 1 | 5 |
| 40 | `src/mir/rewriters/pipeline_rewriter.rb:587` `build_terminal_action` | 157.33 | 0/93 | 93 | 0.0 | 6 | 100.0% killed / advisory | weak verification | 0 | 13 |
| 41 | `src/mir/hoist.rb:646` `mir_alloc_mark_type_info` | 154.54 | 0/54 | 54 | 0.46 | 4 | no mutation / missing | weak verification | 1 | 24 |
| 42 | `src/mir/lowering/literals.rb:81` `lower_list_lit` | 153.18 | 0/74 | 74 | 0.112 | 9 | no mutation / missing | weak verification | 3 | 9 |
| 43 | `src/mir/lower/pipeline/pipeline_binding_chain_lowerer.rb:193` `lower_binding_fold` | 152.98 | 0/88 | 88 | 0.0 | 9 | no mutation / missing | weak verification | 0 | 8 |
| 44 | `src/tools/formatter.rb:1439` `emit_with_block` | 151.75 | 0/71 | 71 | 0.021 | 11 | no mutation / missing | weak verification | 5 | 20 |
| 45 | `src/tools/formatter.rb:792` `emit_fn_block` | 151.75 | 0/63 | 63 | 0.021 | 16 | no mutation / missing | weak verification | 8 | 15 |
| 46 | `src/annotator/domains/errors.rb:563` `visit_OrRescue` | 151.25 | 0/63 | 63 | 0.172 | 10 | no mutation / missing | weak verification | 0 | 22 |
| 47 | `src/mir/lowering/variables.rb:147` `lower_var_decl` | 150.74 | 0/35 | 35 | 0.688 | 7 | no mutation / missing | lurking disaster | 1 | 1 |
| 48 | `src/annotator/helpers/capabilities.rb:735` `acquire_capability!` | 149.15 | 0/69 | 69 | 0.039 | 13 | no mutation / missing | weak verification | 1 | 19 |
| 49 | `src/mir/lowering/functions.rb:454` `function_lowering_context` | 147.38 | 0/36 | 36 | 0.521 | 8 | no mutation / missing | lurking disaster | 2 | 2 |
| 50 | `src/mir/rewriters/pipeline_rewriter.rb:291` `fuse_pipeline` | 145.73 | 0/70 | 70 | 0.0 | 14 | 100.0% killed / advisory | weak verification | 5 | 9 |
| 51 | `src/mir/hoist.rb:930` `normalize_allocating_result_expr!` | 143.96 | 0/45 | 45 | 0.46 | 12 | no mutation / missing | weak verification | 0 | 10 |
| 52 | `src/mir/lowering/capabilities.rb:610` `with_capability_alias_maps` | 142.5 | 0/34 | 34 | 0.5 | 4 | no mutation / missing | lurking disaster | 8 | 4 |
| 53 | `src/mir/lowering/concurrency.rb:578` `bg_capture_materialization` | 140.38 | 0/54 | 54 | 0.445 | 7 | no mutation / missing | weak verification | 0 | 5 |
| 54 | `src/mir/lowering/capabilities.rb:790` `guard_fail_flow_body` | 138.23 | 0/31 | 31 | 0.5 | 10 | no mutation / missing | lurking disaster | 0 | 5 |
| 55 | `src/mir/lowering/expressions.rb:874` `lower_or_rescue` | 137.8 | 0/43 | 43 | 0.348 | 12 | no mutation / missing | weak verification | 2 | 15 |
| 56 | `src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb:370` `lower_shard_concurrent_each` | 136.94 | 0/38 | 38 | 0.55 | 4 | no mutation / missing | lurking disaster | 0 | 5 |
| 57 | `src/backends/fsm_wrapper_emitter.rb:401` `self.render_tail` | 134.85 | 0/87 | 87 | 0.0 | 0 | 49.1% killed / advisory | weak verification | 1 | 10 |
| 58 | `src/mir/lowering/functions.rb:1913` `build_extern_trampoline_call` | 132.94 | 0/30 | 30 | 0.521 | 9 | no mutation / missing | lurking disaster | 0 | 5 |
| 59 | `src/annotator/helpers/reentrance.rb:529` `emit_mutual_thunk_unsupported!` | 132.68 | 0/71 | 71 | 0.0 | 9 | no mutation / missing | weak verification | 2 | 10 |
| 60 | `src/mir/lowering/capabilities.rb:924` `error_action_stmts` | 132.53 | 0/35 | 35 | 0.5 | 6 | no mutation / missing | lurking disaster | 0 | 5 |
| 61 | `src/annotator/helpers/function_analysis.rb:1011` `declare_and_verify_params` | 129.41 | 0/59 | 59 | 0.05 | 8 | no mutation / missing | weak verification | 4 | 20 |
| 62 | `src/annotator/helpers/fixable_helpers.rb:257` `emit_use_of_moved_error!` | 127.6 | 0/69 | 69 | 0.0 | 8 | no mutation / missing | weak verification | 2 | 10 |
| 63 | `src/mir/lowering/expressions.rb:1255` `index_access_value` | 127.05 | 0/43 | 43 | 0.348 | 10 | no mutation / missing | weak verification | 3 | 8 |
| 64 | `src/annotator/helpers/with_match_check.rb:54` `self.check_function!` | 124.8 | 0/59 | 59 | 0.171 | 2 | no mutation / missing | weak verification | 5 | 13 |
| 65 | `src/annotator/helpers/method_analysis.rb:60` `resolve_typed_method` | 121.43 | 0/53 | 53 | 0.009 | 10 | no mutation / missing | weak verification | 9 | 12 |
| 66 | `src/mir/lowering/functions.rb:993` `cross_boundary_arg` | 119.93 | 0/24 | 24 | 0.521 | 10 | no mutation / missing | lurking disaster | 0 | 5 |
| 67 | `src/compiler/module_importer.rb:171` `compile_module_mir` | 119.63 | 0/64 | 64 | 0.0 | 11 | no mutation / missing | weak verification | 0 | 4 |
| 68 | `src/semantic/escape_analysis.rb:909` `self.function_facts` | 119.48 | 0/44 | 44 | 0.433 | 5 | 100.0% killed / advisory | weak verification | 1 | 10 |
| 69 | `src/backends/mir_emitter.rb:1019` `emit_polymorphic_mutate_flow` | 119.3 | 0/31 | 31 | 0.513 | 5 | 100.0% killed / advisory | lurking disaster | 2 | 2 |
| 70 | `src/mir/lowering/expressions.rb:1390` `substitute_mir_type` | 118.25 | 0/45 | 45 | 0.348 | 6 | no mutation / missing | weak verification | 0 | 13 |
| 71 | `src/backends/mir_emitter.rb:228` `emit_bg_stackful_plan` | 116.43 | 0/31 | 31 | 0.513 | 5 | 100.0% killed / advisory | lurking disaster | 2 | 0 |
| 72 | `src/mir/lowering/variables.rb:709` `lower_bind_expr` | 115.46 | 0/45 | 45 | 0.688 | 11 | 100.0% killed / hard | hardened veteran | 8 | 13 |
| 73 | `src/mir/lowering/variables.rb:934` `lower_indexed_assignment` | 115.46 | 0/20 | 20 | 0.688 | 9 | no mutation / missing | lurking disaster | 0 | 5 |
| 74 | `src/mir/rewriters/pipeline_rewriter.rb:48` `rewrite_children!` | 113.83 | 0/41 | 41 | 0.0 | 7 | 100.0% killed / advisory | weak verification | 11 | 32 |
| 75 | `src/annotator/domains/member_access.rb:61` `visit_GetField` | 113.48 | 0/53 | 53 | 0.023 | 9 | no mutation / missing | weak verification | 2 | 16 |

- ...(+1856 more)

## State-Based Branch Hotspots (509)
_Decomplex state-based branch density joined with fix-cache and branch coverage. These are branches over mutable/object state that are uncovered and/or historically fixed._

| # | method | risk | state branches | refs | fix_norm | branch gap | line gap | dark branches |
|---|--------|------|----------------|------|----------|------------|----------|---------------|
| 1 | `src/ast/ast.rb:initialize` | 1009.78 | 21 | `rt.nil? | self[:bindings].nil? | self[:body].nil? | self[:borrowed].nil? | self[:capabilities].nil?` | 0.746 | 27.5% | 20.0% | 0 |
| 2 | `src/mir/mir_lowering.rb:mir_cast` | 359.86 | 10 | `from_t.dynamic? | from_t.fixed? | from_t.float? | from_t.fn_type? | from_t.integer?` | 1.0 | 26.4% | 8.0% | 5 |
| 3 | `src/mir/fsm_transform/emit.rb:build_recursive` | 232.79 | 12 | `all_promoted.any? | ast_stmts.empty? | descriptor.nil? | lowered_mir.nil? | out.nil?` | 0.346 | 20.1% | 0.0% | 0 |
| 4 | `src/mir/mir_checker.rb:check_fsm_structure!` | 217.58 | 10 | `cap.cleanup_at | cap.name | cleanup_step.nil? | fact.move_guarded | fact.name` | 0.684 | 29.2% | 0.0% | 0 |
| 5 | `src/mir/mir_checker.rb:check_fn!` | 150.72 | 8 | `node.body | node.body.ptr | node.fn_def | node.init | node.object_id` | 0.684 | 29.2% | 8.9% | 18 |
| 6 | `src/mir/mir_lowering.rb:owned_sink_plan` | 141.54 | 7 | `source.borrowed_union_sink | source.existing_owned_source | source.satisfies_rc_sink? | ti.any_rc? | ti.collection_value?` | 1.0 | 26.4% | 0.0% | 0 |
| 7 | `src/mir/mir_checker.rb:cleanup_source_owns_value?` | 130.55 | 5 | `MIR::OwnershipEffect.of(init).produces_owned | cleanup.cleanup_entry | cleanup.cleanup_entry.match_as? | init.ownership_consumption | init.ownership_consumption.names` | 0.684 | 29.2% | 0.0% | 0 |
| 8 | `src/ast/std_lib.rb:(top-level)` | 122.4 | 11 | `arg_type.numeric? | arg_type.string? | elem.resolved | key_type.numeric? | key_type.string?` | 0.275 | 45.5% | 0.0% | 0 |
| 9 | `src/mir/fiber_ctx_builder.rb:rc_payload_zig_type` | 114.26 | 7 | `payload.any_sync? | payload.atomic? | payload.indirect? | payload.locked? | payload.map?` | 0.596 | 13.6% | 0.0% | 0 |
| 10 | `src/tools/doctor.rb:diff_locks` | 107.4 | 7 | `after.empty? | before.empty? | d[:after_wait].positive? | d[:after_wait].zero? | d[:before_wait].positive?` | 0.0 | 70.5% | 0.0% | 0 |
| 11 | `src/tools/doctor.rb:diff_mvcc` | 107.4 | 7 | `after.empty? | before.empty? | d[:after_retries].positive? | d[:after_retries].zero? | d[:before_retries].positive?` | 0.0 | 70.5% | 0.0% | 0 |
| 12 | `src/mir/mir_checker.rb:check_fsm_destroy_cleanup_action!` | 106.61 | 7 | `action.name | action.source_kind | action.target | close_plan.empty? | entry.alloc` | 0.684 | 29.2% | 0.0% | 0 |
| 13 | `src/ast/ast.rb:finalize_storage!` | 99.96 | 7 | `final_type.fn_type? | type_obj.any_sync? | type_obj.heap? | type_obj.list_collection? | val_ti.link?` | 0.746 | 27.5% | 2.6% | 4 |
| 14 | `src/mir/mir_lowering.rb:lower_union_def` | 98.46 | 6 | `de.kind | deinit_stmts.any? | fact.inline_struct | helper_structs.any? | node.type_params` | 1.0 | 26.4% | 1.6% | 6 |
| 15 | `src/ast/type.rb:accepts?` | 95.02 | 8 | `other_type.any? | other_type.byte? | other_type.error_union? | other_type.map? | other_type.numeric?` | 0.01 | 17.6% | 0.0% | 0 |
| 16 | `src/ast/ast.rb:body_slots` | 93.5 | 6 | `match_case.body | node.body | node.default_case | node.do_branch | node.else_branch` | 0.746 | 27.5% | 0.0% | 0 |
| 17 | `src/ast/type.rb:accepts_array?` | 91.46 | 7 | `T.must(element_type).any? | other_type.array? | other_type.bounded_stream? | other_type.dynamic_stream? | other_type.element_type` | 0.01 | 17.6% | 0.0% | 0 |
| 18 | `src/mir/mir_pass.rb:finalize_needs_rt!` | 79.9 | 7 | `@fn_nodes | @fn_nodes[c].needs_rt | callees[name].any? | fn.body | fn.needs_rt` | 0.359 | 22.5% | 10.0% | 3 |
| 19 | `src/mir/fsm_transform/segments.rb:split_while_loop_next` | 77.27 | 6 | `cond_node.nil? | loop_idx.nil? | loop_node.do_branch | stmt.do_branch | sus.nil?` | 0.172 | 83.1% | 0.0% | 0 |
| 20 | `src/ast/parser.rb:apply_capability!` | 76.11 | 7 | `result.collection | result.is_indirect | result.is_soa | result.observable | result.ownership` | 0.023 | 17.2% | 5.7% | 14 |
| 21 | `src/tools/doctor.rb:section_locks` | 71.6 | 7 | `atomic_candidates.any? | atomic_ptr_candidates.any? | f.size | locks.empty? | mvcc_candidates.any?` | 0.0 | 70.5% | 0.0% | 0 |
| 22 | `src/tools/doctor.rb:section_mvcc` | 71.6 | 7 | `atomic_ptr_upgrade.any? | cells.empty? | cow_thrash.any? | f.size | misuse.any?` | 0.0 | 70.5% | 0.0% | 0 |
| 23 | `src/mir/control_flow.rb:cleanup_decisions!` | 67.74 | 6 | `block_entry.needs_cleanup | checker.errors | checker.errors.empty? | df_entry.has_moved_guard | df_entry.needs_cleanup` | 0.149 | 24.8% | 4.2% | 5 |
| 24 | `src/mir/mir_lowering.rb:lower_require` | 63.19 | 5 | `T.must(mod).ast | helper_fns.any? | node.kind | program_state.emitted_require_modules | stmt.name` | 1.0 | 26.4% | 0.0% | 0 |
| 25 | `src/ast/ast.rb:metatype` | 62.22 | 5 | `t.array? | t.map? | t.primitive? | t.resolved | t.void?` | 0.746 | 27.5% | 10.0% | 1 |
| 26 | `src/ast/type.rb:resolve_numeric_op` | 57.01 | 6 | `left_type.any? | left_type.float? | left_type.integer? | left_type.numeric? | right_type.any?` | 0.01 | 17.6% | 0.0% | 0 |
| 27 | `src/mir/mir_lowering.rb:zig_format_for_type` | 53.08 | 3 | `flux_type.array? | flux_type.byte? | flux_type.element_type | flux_type.element_type.byte? | flux_type.resolved` | 1.0 | 26.4% | 0.0% | 0 |
| 28 | `src/mir/mir_checker.rb:verify_cross_frame_param_alloc!` | 52.22 | 4 | `fn_def.params | fn_def.params.empty? | fn_def.params.nil? | metadata.empty? | p.pointer_passed` | 0.684 | 29.2% | 0.0% | 0 |
| 29 | `src/mir/mir_checker.rb:verify_ownership_contract_operands!` | 52.22 | 4 | `contract.operands | contract.operands.empty? | name.empty? | name.nil? | operand.borrowed` | 0.684 | 29.2% | 0.0% | 0 |
| 30 | `src/ast/lexer.rb:read_interpolated_string` | 51.42 | 8 | `@s | @s.eos? | T.must(sub_tokens.last).type | sub_tokens.last` | 0.0 | 18.4% | 6.7% | 11 |
| 31 | `src/tools/doctor.rb:diff_heap` | 51.14 | 5 | `after.empty? | before.empty? | d[:delta_bytes].positive? | deltas.empty? | gone_funcs.any?` | 0.0 | 70.5% | 0.0% | 0 |
| 32 | `src/ast/type.rb:accepts_future?` | 49.89 | 6 | `other_type.dynamic_stream? | other_type.empty_list? | other_type.future? | other_type.inf_stream? | other_type.open_stream?` | 0.01 | 17.6% | 0.0% | 0 |
| 33 | `src/ast/type.rb:accepts_fn_type?` | 47.51 | 5 | `other_params.length | other_raw.reentrant | other_raw.return_type | other_type.any? | other_type.fn_type?` | 0.01 | 17.6% | 0.0% | 0 |
| 34 | `src/mir/mir_checker.rb:normalize_guarded_conditional_releases!` | 46.61 | 3 | `state.guarded_finalizers | states.all? | states.empty? | states.length` | 0.684 | 29.2% | 55.6% | 6 |
| 35 | `src/mir/mir_lowering.rb:append_ownership_facts_for_mir_node!` | 45.96 | 3 | `target.expr | target.include_owned_result | target.include_transfer_contract` | 1.0 | 26.4% | 62.5% | 9 |
| 36 | `src/ast/parser.rb:parse_function_def` | 45.92 | 6 | `@gradual | current.type | early_requires_clauses.empty? | post_clauses.empty? | pre_clauses.empty?` | 0.023 | 17.2% | 1.7% | 2 |
| 37 | `src/mir/mir_lowering.rb:owned_binding_visible?` | 45.49 | 3 | `capture_state.current_fsm_inherited_alloc_names | function_state.bindings | function_state.bindings[name] || CleanupEntry::NONE.present? | function_state.pending_stmts | function_state.pending_stmts.any?` | 1.0 | 26.4% | 0.0% | 0 |
| 38 | `src/mir/fsm_transform/emit.rb:compute_sp_indices` | 45.27 | 7 | `seg.index | seg.tail | seg.tail.next_index | stack.pop` | 0.346 | 20.1% | 0.0% | 0 |
| 39 | `src/mir/fiber_ctx_builder.rb:needs_fresh_heap_capture_cleanup?` | 43.53 | 3 | `ti.any? | ti.any_rc? | ti.any_sync? | ti.collection_value? | ti.heap_ptr?` | 0.596 | 13.6% | 0.0% | 0 |
| 40 | `src/mir/mir_checker.rb:verify_execution_boundary_facts!` | 43.52 | 4 | `facts.all? | facts.length | node.fsm_structure | node.run_body | node.run_body.empty?` | 0.684 | 29.2% | 0.0% | 0 |
| 41 | `src/mir/fsm_transform/emit.rb:expand_lock_segment` | 40.42 | 5 | `err.exit_kind | err.nil? | m.nil? | meta.nil? | with_node.lock_error_clause` | 0.346 | 20.1% | 0.0% | 0 |
| 42 | `src/mir/mir_pass.rb:return_expr_needs_allocator?` | 39.95 | 3 | `fn.params | fn.params.any? | node.name | node.string_concat | param.name` | 0.359 | 22.5% | 0.0% | 0 |
| 43 | `src/mir/mir_checker.rb:verify_alloc_cleanup_match!` | 39.16 | 3 | `alloc_marks.all? | alloc_marks.first | alloc_marks.first.full_type | m.alloc | ti.id_handle?` | 0.684 | 29.2% | 0.0% | 0 |
| 44 | `src/mir/mir_pass.rb:stamp_match_as_cleanup!` | 36.87 | 4 | `c.binding | c.destructure | stmt.expr | stmt.expr.was_moved | stmt.takes` | 0.359 | 22.5% | 4.8% | 2 |
| 45 | `src/mir/control_flow.rb:expression_allocates_frame_value?` | 35.85 | 5 | `fn.uses_frame | sig.emits_allocating? | sig.mutates_receiver? | sig.return_alloc | type_info.frame?` | 0.149 | 24.8% | 0.0% | 0 |
| 46 | `src/ast/type.rb:merge_capabilities_from!` | 35.55 | 5 | `source.observable? | source.observable_terminal | source.observable_token | source.polymorphic_shared? | source.soa?` | 0.01 | 17.6% | 6.3% | 4 |
| 47 | `src/mir/mir_checker.rb:linear_release!` | 34.81 | 4 | `state.alloc_kinds | state.owned | state.released | target_alloc.nil?` | 0.684 | 29.2% | 0.0% | 0 |
| 48 | `src/mir/mir_lowering.rb:append_move_guard_for_transfer_mark!` | 34.66 | 3 | `entry.needs_cleanup? | function_state.bindings | node.name | node.target` | 1.0 | 26.4% | 7.7% | 2 |
| 49 | `src/mir/mir_pass.rb:add_if_consumed` | 34.18 | 4 | `entry.has_moved_guard? | entry.needs_cleanup? | entry.present? | ti.any_rc?` | 0.359 | 22.5% | 13.3% | 4 |
| 50 | `src/tools/doctor.rb:section_fibers` | 34.1 | 5 | `f.size | s.empty? | sched_rows.any? | sched_rows.length` | 0.0 | 70.5% | 0.0% | 0 |
| 51 | `src/mir/control_flow.rb:collect_ownership_transfers` | 33.74 | 5 | `node.object | node.object.token | node.object.token.type | step.state` | 0.149 | 24.8% | 3.7% | 4 |
| 52 | `src/mir/mir_checker.rb:check_stmt_for_unhoisted` | 32.64 | 3 | `node.body | node.capture | node.cond | node.then_body | node.update` | 0.684 | 29.2% | 0.0% | 0 |
| 53 | `src/mir/mir_checker.rb:verify_ownership_surfaces_finalized!` | 32.64 | 3 | `node.callable_contract | node.owned_result_alloc | node.owned_return? | node.spec | node.spec.callable_contract` | 0.684 | 29.2% | 0.0% | 0 |
| 54 | `src/mir/fsm_transform/emit.rb:build_fsm_unified` | 32.33 | 4 | `d.bind_stmts | d.bind_stmts.empty? | fn_name.nil? | segment_specs.empty? | spec.descriptor` | 0.346 | 20.1% | 0.0% | 0 |
| 55 | `src/mir/mir_checker.rb:check_linear_stmt!` | 31.12 | 2 | `stmt.body | stmt.body_slots | stmt.body_slots.empty?` | 0.684 | 29.2% | 8.2% | 17 |
| 56 | `src/tools/doctor.rb:section_heap` | 30.69 | 6 | `@opts | parts.size | zig_lines_cache.size` | 0.0 | 70.5% | 0.0% | 0 |
| 57 | `src/mir/mir_lowering.rb:append_ownership_transfer_targets_for_surface_node!` | 30.33 | 3 | `operand.borrowed | operand.name | operand.name.nil? | state.body_alloc_mark_names` | 1.0 | 26.4% | 0.0% | 0 |
| 58 | `src/mir/mir_lowering.rb:ownership_fact_source` | 30.22 | 2 | `source_node.reason | source_node.target_var` | 1.0 | 26.4% | 100.0% | 10 |
| 59 | `src/lsp/rpc.rb:read_message` | 30.0 | 5 | `body.bytesize | body.nil? | headers.nil? | length.negative? | length.nil?` | 0.0 | 0.0% | 0.0% | 0 |
| 60 | `src/mir/thunk_transform/recursive_splitter.rb:match_base_case` | 29.88 | 5 | `ret.value | stmt.condition | stmt.else_branch | stmt.else_branch.empty? | then_b.length` | 0.0 | 19.5% | 0.0% | 0 |
| 61 | `src/mir/thunk_transform/recursive_splitter.rb:match_mutual_base_case` | 29.88 | 5 | `ret.value | stmt.condition | stmt.else_branch | stmt.else_branch.empty? | then_b.length` | 0.0 | 19.5% | 0.0% | 0 |
| 62 | `src/mir/thunk_transform/recursive_splitter.rb:split` | 29.88 | 5 | `bc.nil? | body.empty? | combine.nil? | final.value | stmts.length` | 0.0 | 19.5% | 0.0% | 0 |
| 63 | `src/mir/thunk_transform/recursive_splitter.rb:split_mutual` | 29.88 | 5 | `bc.nil? | body.empty? | final.value | stmts.length | target.nil?` | 0.0 | 19.5% | 0.0% | 0 |
| 64 | `src/ast/type.rb:surface_name` | 29.69 | 5 | `t.array? | t.error_union? | t.generic_instance? | t.optional? | t.tense?` | 0.01 | 17.6% | 0.0% | 0 |
| 65 | `src/mir/mir_lowering.rb:lower_struct_def` | 28.8 | 3 | `fd.default | node.type_params | node.type_params.any?` | 1.0 | 26.4% | 22.2% | 1 |
| 66 | `src/ast/parser.rb:extract_paren_bindings` | 28.78 | 6 | `left_binds.empty? | node.op | node.paren_bind | right_binds.empty?` | 0.023 | 17.2% | 0.0% | 0 |
| 67 | `src/mir/control_flow.rb:analyze!` | 28.68 | 4 | `@cfg | @cfg.entry | fn.body | succ.id | worklist.empty?` | 0.149 | 24.8% | 0.0% | 0 |
| 68 | `src/mir/control_flow.rb:outer_frame_receiver_alloc?` | 28.68 | 4 | `root.name | root.symbol | sig.emits_allocating? | sig.mutates_receiver? | sym.heap_storage?` | 0.149 | 24.8% | 0.0% | 0 |
| 69 | `src/mir/mir_lowering.rb:place_owned_branch_value_for_destination` | 28.3 | 3 | `dst_ti.any_rc? | dst_ti.shared? | dst_ti.string?` | 1.0 | 26.4% | 20.0% | 1 |
| 70 | `src/tools/doctor.rb:section_freeze` | 27.28 | 4 | `candidates.empty? | r[:func].empty? | rc_clear_lines.any? | sites.any?` | 0.0 | 70.5% | 0.0% | 0 |
| 71 | `src/ast/ast.rb:coerce!` | 26.71 | 3 | `@type_object | @type_object.fn_type? | declared_type.nil? | items.any?` | 0.746 | 27.5% | 0.0% | 0 |
| 72 | `src/mir/mir_checker.rb:verify_execution_boundary_fact!` | 26.11 | 4 | `capture.parallel_safe | fact.dispatch | fact.kind` | 0.684 | 29.2% | 0.0% | 0 |
| 73 | `src/mir/mir_checker.rb:verify_ownership_consumption_operands!` | 26.11 | 3 | `fact.operands | fact.operands.empty? | operand.borrowed | operand.kind` | 0.684 | 29.2% | 0.0% | 0 |
| 74 | `src/ast/type.rb:array_overflow?` | 25.94 | 3 | `other_type.array? | other_type.base_type | other_type.fixed? | self.array? | self.base_type` | 0.01 | 17.6% | 16.7% | 1 |
| 75 | `src/mir/fsm_transform/recursive_splitter.rb:emit_with_fragment` | 25.26 | 4 | `caps.empty? | caps.length | m.nil? | with_stmt.body` | 0.172 | 34.7% | 0.0% | 0 |

- ...(+434 more)

## Multi-File Fix Blast Radius (83)
_Time-decayed fix commits where a file repeatedly changes with many other files. High rows are bug fixes whose blast radius is cross-module, not local._

| # | file | score | fixes | avg files/fix | max files | top co-touched files |
|---|------|-------|-------|---------------|-----------|----------------------|
| 1 | `src/mir/mir_lowering.rb` | 43.359 | 57 | 10.42 | 78 | spec/mir_gap_burn_spec.rb (1.618); src/mir/mir.rb (1.346); src/mir/lowering/variables.rb (1.298); src/mir/mir_checker.rb (1.291); src/mir/fiber_ctx_builder.rb (1.125) |
| 2 | `src/mir/mir.rb` | 37.811 | 14 | 20.57 | 78 | src/mir/mir_lowering.rb (1.346); src/mir/mir_checker.rb (1.291); src/mir/lowering/variables.rb (1.291); spec/mir_gap_burn_spec.rb (1.282); zig/runtime/runtime-header.zig (1.001) |
| 3 | `src/mir/lowering/variables.rb` | 32.842 | 6 | 27.83 | 36 | src/mir/mir_lowering.rb (1.298); src/mir/mir.rb (1.291); src/mir/mir_checker.rb (1.291); spec/mir_gap_burn_spec.rb (1.282); spec/transpiler_spec.rb (1.007) |
| 4 | `src/mir/mir_checker.rb` | 32.642 | 10 | 17.4 | 36 | src/mir/mir_lowering.rb (1.291); src/mir/mir.rb (1.291); src/mir/lowering/variables.rb (1.291); spec/mir_gap_burn_spec.rb (1.282); spec/transpiler_spec.rb (1.0) |
| 5 | `src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb` | 28.122 | 3 | 27.67 | 30 | spec/mir_gap_burn_spec.rb (1.038); src/mir/mir_lowering.rb (1.038); src/ast/ast.rb (0.816); src/mir/lowering/variables.rb (0.712); src/mir/mir.rb (0.712) |
| 6 | `src/ast/ast.rb` | 26.589 | 15 | 16.93 | 78 | src/mir/mir_lowering.rb (0.931); spec/mir_gap_burn_spec.rb (0.885); src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb (0.816); src/mir/mir.rb (0.603); sorbet/rbi/clear-attr-accessors.rbi (0.593) |
| 7 | `src/mir/fiber_ctx_builder.rb` | 25.99 | 6 | 17.17 | 27 | src/mir/mir_lowering.rb (1.125); spec/mir_gap_burn_spec.rb (1.047); spec/pipeline_backend_coverage_spec.rb (1.047); src/mir/lowering/functions.rb (0.825); src/mir/lowering/variables.rb (0.722) |
| 8 | `src/mir/lowering/functions.rb` | 21.669 | 7 | 22.29 | 36 | src/mir/mir_lowering.rb (0.911); spec/mir_gap_burn_spec.rb (0.894); spec/pipeline_backend_coverage_spec.rb (0.825); src/mir/fiber_ctx_builder.rb (0.825); src/mir/lowering/variables.rb (0.585) |
| 9 | `src/semantic/escape_analysis.rb` | 18.894 | 3 | 17.0 | 30 | spec/annotator_gap_burndown_spec.rb (0.774); spec/mir_gap_burn_spec.rb (0.774); src/mir/mir.rb (0.533); benchmarks/clear-only/tail_call_loop/README.md (0.491); benchmarks/clear-only/tail_call_loop/bench_tail_call.cht (0.491) |
| 10 | `src/mir/lowering/concurrency.rb` | 16.811 | 7 | 20.71 | 36 | src/mir/mir_lowering.rb (0.671); spec/mir_lowering_spec.rb (0.634); src/mir/fiber_ctx_builder.rb (0.625); spec/concurrency_spec.rb (0.557); examples/minivm/bc_emitter.rb (0.547) |
| 11 | `src/backends/mir_emitter.rb` | 16.132 | 2 | 17.5 | 30 | benchmarks/clear-only/tail_call_loop/README.md (0.491); benchmarks/clear-only/tail_call_loop/bench_tail_call.cht (0.491); benchmarks/concurrent/10_shard_vs_locked/TIMEOUT (0.491); spec/allocation_strategy_spec.rb (0.491); spec/annotator_gap_burndown_spec.rb (0.491) |
| 12 | `src/mir/fsm_transform/suspend_resolvers.rb` | 15.649 | 4 | 33.5 | 53 | src/mir/mir_lowering.rb (0.578); spec/fsm_suspend_resolvers_spec.rb (0.568); spec/transpiler_spec.rb (0.5); spec/vm_bg_capture_bugs_spec.rb (0.5); src/mir/lowering/variables.rb (0.5) |
| 13 | `src/mir/fsm_ops.rb` | 14.225 | 1 | 30.0 | 30 | benchmarks/clear-only/tail_call_loop/README.md (0.491); benchmarks/clear-only/tail_call_loop/bench_tail_call.cht (0.491); benchmarks/concurrent/10_shard_vs_locked/TIMEOUT (0.491); spec/allocation_strategy_spec.rb (0.491); spec/annotator_gap_burndown_spec.rb (0.491) |
| 14 | `src/mir/lower/pipeline/pipeline_host.rb` | 14.225 | 1 | 30.0 | 30 | benchmarks/clear-only/tail_call_loop/README.md (0.491); benchmarks/clear-only/tail_call_loop/bench_tail_call.cht (0.491); benchmarks/concurrent/10_shard_vs_locked/TIMEOUT (0.491); spec/allocation_strategy_spec.rb (0.491); spec/annotator_gap_burndown_spec.rb (0.491) |
| 15 | `src/mir/lower/pipeline/pipeline_lowering_bridge.rb` | 14.225 | 1 | 30.0 | 30 | benchmarks/clear-only/tail_call_loop/README.md (0.491); benchmarks/clear-only/tail_call_loop/bench_tail_call.cht (0.491); benchmarks/concurrent/10_shard_vs_locked/TIMEOUT (0.491); spec/allocation_strategy_spec.rb (0.491); spec/annotator_gap_burndown_spec.rb (0.491) |
| 16 | `src/mir/lower/pipeline/pipeline_records.rb` | 14.225 | 1 | 30.0 | 30 | benchmarks/clear-only/tail_call_loop/README.md (0.491); benchmarks/clear-only/tail_call_loop/bench_tail_call.cht (0.491); benchmarks/concurrent/10_shard_vs_locked/TIMEOUT (0.491); spec/allocation_strategy_spec.rb (0.491); spec/annotator_gap_burndown_spec.rb (0.491) |
| 17 | `src/semantic/bg_capture_classifier.rb` | 14.225 | 1 | 30.0 | 30 | benchmarks/clear-only/tail_call_loop/README.md (0.491); benchmarks/clear-only/tail_call_loop/bench_tail_call.cht (0.491); benchmarks/concurrent/10_shard_vs_locked/TIMEOUT (0.491); spec/allocation_strategy_spec.rb (0.491); spec/annotator_gap_burndown_spec.rb (0.491) |
| 18 | `src/semantic/capture_strategy.rb` | 14.225 | 1 | 30.0 | 30 | benchmarks/clear-only/tail_call_loop/README.md (0.491); benchmarks/clear-only/tail_call_loop/bench_tail_call.cht (0.491); benchmarks/concurrent/10_shard_vs_locked/TIMEOUT (0.491); spec/allocation_strategy_spec.rb (0.491); spec/annotator_gap_burndown_spec.rb (0.491) |
| 19 | `src/annotator/annotator.rb` | 13.962 | 5 | 22.0 | 31 | examples/minivm/register_bc_emitter.rb (0.649); sorbet/rbi/clear-attr-accessors.rbi (0.609); spec/mir_gap_burn_spec.rb (0.609); src/annotator/helpers/effects.rb (0.609); examples/minivm/bc_emitter.rb (0.371) |
| 20 | `src/mir/hoist.rb` | 13.936 | 12 | 17.17 | 36 | spec/mir_gap_burn_spec.rb (0.575); examples/minivm/register_bc_emitter.rb (0.545); src/mir/lowering/concurrency.rb (0.41); src/mir/mir_pass.rb (0.373); src/mir/mir.rb (0.354) |
| 21 | `src/mir/cleanup_classifier.rb` | 12.993 | 5 | 21.0 | 36 | src/mir/mir_lowering.rb (0.56); src/mir/mir.rb (0.553); spec/transpiler_spec.rb (0.516); src/ast/std_lib.rb (0.516); src/mir/lowering/functions.rb (0.516) |
| 22 | `src/mir/lowering/capabilities.rb` | 12.955 | 9 | 15.78 | 36 | src/mir/mir.rb (0.65); spec/mir_lowering_spec.rb (0.639); gems/decomplex/report.md (0.434); gems/espalier/report.md (0.434); gems/nil-kill/report.md (0.434) |
| 23 | `src/annotator/helpers/effects.rb` | 12.671 | 2 | 21.5 | 26 | examples/minivm/register_bc_emitter.rb (0.609); sorbet/rbi/clear-attr-accessors.rbi (0.609); spec/mir_gap_burn_spec.rb (0.609); src/annotator/annotator.rb (0.609); examples/minivm/bc_emitter.rb (0.325) |
| 24 | `src/ast/std_lib.rb` | 11.563 | 11 | 29.82 | 78 | src/mir/mir_lowering.rb (0.518); spec/transpiler_spec.rb (0.516); src/mir/cleanup_classifier.rb (0.516); src/mir/lowering/functions.rb (0.516); src/mir/lowering/variables.rb (0.516) |
| 25 | `src/mir/lower/pipeline/pipeline_materializer.rb` | 11.0 | 1 | 23.0 | 23 | benchmarks/concurrent/02_concurrent_search/bench.cht (0.5); benchmarks/concurrent/18_atomic_counter/bench.cht (0.5); benchmarks/runner.rb (0.5); examples/minivm/vm-tests/values/string_eq.stack.bc (0.5); examples/minivm/vm-tests/values/string_loop_temp.stack.bc (0.5) |
| 26 | `src/mir/fsm_transform/emit.rb` | 10.077 | 10 | 29.6 | 78 | src/mir/mir_lowering.rb (0.413); spec/mir_lowering_spec.rb (0.413); src/mir/lowering/concurrency.rb (0.413); src/mir/fiber_ctx_builder.rb (0.403); sorbet/rbi/clear-attr-accessors.rbi (0.364) |
| 27 | `src/ast/diagnostic_registry.rb` | 8.466 | 7 | 17.14 | 36 | src/mir/mir_lowering.rb (0.335); spec/concurrency_spec.rb (0.335); spec/mir_lowering_spec.rb (0.335); src/mir/fsm_transform/emit.rb (0.335); src/mir/lowering/concurrency.rb (0.335) |
| 28 | `src/annotator/domains/errors.rb` | 8.13 | 1 | 26.0 | 26 | examples/minivm/bc_emitter.rb (0.325); examples/minivm/register_bc_emitter.rb (0.325); sorbet/rbi/clear-attr-accessors.rbi (0.325); spec/concurrency_spec.rb (0.325); spec/fsm_classifier_spec.rb (0.325) |
| 29 | `src/annotator/phases/declaration_index.rb` | 8.13 | 1 | 26.0 | 26 | examples/minivm/bc_emitter.rb (0.325); examples/minivm/register_bc_emitter.rb (0.325); sorbet/rbi/clear-attr-accessors.rbi (0.325); spec/concurrency_spec.rb (0.325); spec/fsm_classifier_spec.rb (0.325) |
| 30 | `src/mir/fsm_transform/segments.rb` | 8.13 | 1 | 26.0 | 26 | examples/minivm/bc_emitter.rb (0.325); examples/minivm/register_bc_emitter.rb (0.325); sorbet/rbi/clear-attr-accessors.rbi (0.325); spec/concurrency_spec.rb (0.325); spec/fsm_classifier_spec.rb (0.325) |
| 31 | `src/mir/fsm_transform/recursive_splitter.rb` | 8.13 | 2 | 18.0 | 26 | examples/minivm/bc_emitter.rb (0.325); examples/minivm/register_bc_emitter.rb (0.325); sorbet/rbi/clear-attr-accessors.rbi (0.325); spec/concurrency_spec.rb (0.325); spec/fsm_classifier_spec.rb (0.325) |
| 32 | `src/mir/mir_pass.rb` | 7.669 | 17 | 17.76 | 78 | sorbet/rbi/clear-attr-accessors.rbi (0.553); src/mir/hoist.rb (0.373); spec/mir_gap_burn_spec.rb (0.353); src/ast/ast.rb (0.338); src/annotator/annotator.rb (0.29) |
| 33 | `src/mir/lowering/control_flow.rb` | 6.694 | 3 | 26.33 | 36 | src/mir/hoist.rb (0.271); src/mir/lowering/capabilities.rb (0.271); examples/minivm/bc_emitter.rb (0.261); examples/minivm/register_bc_emitter.rb (0.261); spec/concurrency_spec.rb (0.231) |
| 34 | `src/ast/schemas.rb` | 5.767 | 1 | 27.0 | 27 | examples/minivm/bc_emitter.rb (0.222); examples/minivm/register_bc_emitter.rb (0.222); spec/capabilities_spec.rb (0.222); spec/concurrency_spec.rb (0.222); spec/fsm_classifier_spec.rb (0.222) |
| 35 | `src/mir/lower/pipeline/pipeline_range_lowerer.rb` | 5.767 | 1 | 27.0 | 27 | examples/minivm/bc_emitter.rb (0.222); examples/minivm/register_bc_emitter.rb (0.222); spec/capabilities_spec.rb (0.222); spec/concurrency_spec.rb (0.222); spec/fsm_classifier_spec.rb (0.222) |
| 36 | `src/annotator/helpers/with_match_check.rb` | 4.851 | 2 | 13.0 | 17 | sorbet/rbi/clear-attr-accessors.rbi (0.323); examples/minivm/register_bc_emitter.rb (0.284); spec/annotator_gap_burndown_spec.rb (0.284); spec/gen_attr_rbi_spec.rb (0.284); spec/mir_gap_burn_spec.rb (0.284) |
| 37 | `src/annotator/phases/body_analysis.rb` | 4.541 | 1 | 17.0 | 17 | examples/minivm/register_bc_emitter.rb (0.284); sorbet/rbi/clear-attr-accessors.rbi (0.284); spec/annotator_gap_burndown_spec.rb (0.284); spec/gen_attr_rbi_spec.rb (0.284); spec/mir_gap_burn_spec.rb (0.284) |
| 38 | `src/semantic/concurrency_checks.rb` | 4.541 | 1 | 17.0 | 17 | examples/minivm/register_bc_emitter.rb (0.284); sorbet/rbi/clear-attr-accessors.rbi (0.284); spec/annotator_gap_burndown_spec.rb (0.284); spec/gen_attr_rbi_spec.rb (0.284); spec/mir_gap_burn_spec.rb (0.284) |
| 39 | `src/mir/lowering/expressions.rb` | 3.824 | 6 | 16.33 | 36 | .github/workflows/ci.yml (0.385); zig/lib/partitioned-map-test.zig (0.385); zig/partitioned-map-test.zig (0.385); src/mir/lowering/capabilities.rb (0.173); sorbet/rbi/clear-attr-accessors.rbi (0.164) |
| 40 | `src/README.md` | 2.306 | 1 | 8.0 | 8 | spec/higher_order_spec.rb (0.329); src/annotator/README.md (0.329); src/mir/README.md (0.329); tools/fuzz/templates/mir_checker_negative_matrix.rb (0.329); zig/lib/data-structures.zig (0.329) |
| 41 | `src/annotator/README.md` | 2.306 | 1 | 8.0 | 8 | spec/higher_order_spec.rb (0.329); src/README.md (0.329); src/mir/README.md (0.329); tools/fuzz/templates/mir_checker_negative_matrix.rb (0.329); zig/lib/data-structures.zig (0.329) |
| 42 | `src/mir/README.md` | 2.306 | 1 | 8.0 | 8 | spec/higher_order_spec.rb (0.329); src/README.md (0.329); src/annotator/README.md (0.329); tools/fuzz/templates/mir_checker_negative_matrix.rb (0.329); zig/lib/data-structures.zig (0.329) |
| 43 | `src/mir/test_lowering.rb` | 1.924 | 3 | 7.0 | 11 | sorbet/rbi/clear-attr-accessors.rbi (0.477); clear (0.477); src/backends/mir_emitter.rb (0.477); tools/fuzz/templates/mir_checker_negative_matrix.rb (0.477); src/mir/mir_lowering.rb (0.002) |
| 44 | `src/mir/lowering/literals.rb` | 1.815 | 4 | 15.5 | 36 | src/mir/mir_lowering.rb (0.131); spec/mir_lowering_spec.rb (0.087); src/mir/fsm_transform/emit.rb (0.087); src/mir/fsm_transform/suspend_resolvers.rb (0.087); src/mir/lowering/concurrency.rb (0.087) |
| 45 | `src/mir/fsm_lowering.rb` | 1.646 | 6 | 14.83 | 36 | src/mir/hoist.rb (0.188); src/mir/lowering/concurrency.rb (0.188); gems/nil-kill/lib/nil_kill/static_diff_audit.rb (0.168); gems/nil-kill/spec/static_diff_audit_spec.rb (0.168); src/ast/ast.rb (0.168) |
| 46 | `src/mir/control_flow.rb` | 1.442 | 12 | 7.58 | 36 | src/mir/mir_pass.rb (0.278); src/mir/cleanup_classifier.rb (0.276); sorbet/rbi/clear-attr-accessors.rbi (0.269); src/ast/ast.rb (0.267); src/backends/pipeline_host.rb (0.011) |
| 47 | `src/annotator/helpers/function_analysis.rb` | 1.438 | 4 | 23.0 | 36 | src/mir/lowering/capabilities.rb (0.088); src/mir/hoist.rb (0.056); src/mir/lowering/functions.rb (0.056); src/mir/lowering/control_flow.rb (0.049); src/mir/fsm_lowering.rb (0.048) |
| 48 | `src/annotator/domains/variables.rb` | 1.315 | 1 | 20.0 | 20 | clear (0.069); examples/minivm/vm-tests/values/list_append_count.cht (0.069); examples/puck/vm.cht (0.069); examples/web_crawler/src/main.cht (0.069); spec/clear_build_support_spec.rb (0.069) |
| 49 | `src/tools/clear_build_support.rb` | 1.315 | 1 | 20.0 | 20 | clear (0.069); examples/minivm/vm-tests/values/list_append_count.cht (0.069); examples/puck/vm.cht (0.069); examples/web_crawler/src/main.cht (0.069); spec/clear_build_support_spec.rb (0.069) |
| 50 | `src/annotator/domains/control_flow.rb` | 1.128 | 2 | 7.5 | 9 | sorbet/rbi/clear-attr-accessors.rbi (0.202); src/mir/lowering/capabilities.rb (0.202); spec/coverage_tools_spec.rb (0.164); src/mir/lowering/expressions.rb (0.164); tools/zig_coverage_support.rb (0.164) |
| 51 | `src/annotator/helpers/intrinsic_emit.rb` | 1.09 | 1 | 15.0 | 15 | benchmarks/24_json_api/server.cht (0.078); gems/nil-kill/lib/nil_kill/runtime_trace.rb (0.078); gems/nil-kill/spec/collect_evidence_guard_spec.rb (0.078); gems/nil-kill/spec/runtime_trace_spec.rb (0.078); spec/fsm_suspend_resolvers_spec.rb (0.078) |
| 52 | `src/annotator/helpers/intrinsic_registry.rb` | 1.09 | 1 | 15.0 | 15 | benchmarks/24_json_api/server.cht (0.078); gems/nil-kill/lib/nil_kill/runtime_trace.rb (0.078); gems/nil-kill/spec/collect_evidence_guard_spec.rb (0.078); gems/nil-kill/spec/runtime_trace_spec.rb (0.078); spec/fsm_suspend_resolvers_spec.rb (0.078) |
| 53 | `src/tools/formatter.rb` | 0.594 | 8 | 7.0 | 24 | examples/minivm/bc_emitter.rb (0.04); examples/minivm/register_bc_emitter.rb (0.04); spec/annotator_spec.rb (0.04); spec/polymorphic_warning_spec.rb (0.04); src/annotator/annotator.rb (0.04) |
| 54 | `src/ast/type.rb` | 0.556 | 10 | 10.7 | 36 | src/mir/mir_pass.rb (0.018); src/mir/mir_lowering.rb (0.018); src/ast/std_lib.rb (0.018); src/mir/hoist.rb (0.018); spec/generics_spec.rb (0.016) |
| 55 | `src/annotator/helpers/method_analysis.rb` | 0.535 | 2 | 33.5 | 36 | spec/generics_spec.rb (0.016); spec/mir_lowering_spec.rb (0.016); spec/transpiler_spec.rb (0.016); src/annotator/helpers/function_analysis.rb (0.016); src/ast/std_lib.rb (0.016) |
| 56 | `src/annotator/helpers/lock_helper.rb` | 0.498 | 1 | 20.0 | 20 | docs/agents/annotator-match-pipe-architecture-plan.md (0.026); docs/agents/mir-lowerer-hotspots-plan.md (0.026); docs/agents/nil-kill-collect-ran-untraced-invariant.md (0.026); docs/agents/review_mir_lowerer_branch_hubs.md (0.026); docs/agents/review_mir_ownership_destination.md (0.026) |
| 57 | `src/annotator/helpers/pipe_analysis.rb` | 0.498 | 1 | 20.0 | 20 | docs/agents/annotator-match-pipe-architecture-plan.md (0.026); docs/agents/mir-lowerer-hotspots-plan.md (0.026); docs/agents/nil-kill-collect-ran-untraced-invariant.md (0.026); docs/agents/review_mir_lowerer_branch_hubs.md (0.026); docs/agents/review_mir_ownership_destination.md (0.026) |
| 58 | `src/ast/parser.rb` | 0.397 | 10 | 13.1 | 78 | src/mir/mir.rb (0.044); src/mir/mir_lowering.rb (0.044); src/ast/ast.rb (0.043); spec/mir_emitter_spec.rb (0.043); src/mir/mir_emitter.rb (0.043) |
| 59 | `src/annotator/domains/member_access.rb` | 0.391 | 1 | 10.0 | 10 | spec/mir_emitter_spec.rb (0.043); spec/parser_mutable_default_spec.rb (0.043); src/ast/ast.rb (0.043); src/ast/parser.rb (0.043); src/mir/cleanup_classifier.rb (0.043) |
| 60 | `src/annotator/helpers/capabilities.rb` | 0.368 | 3 | 12.67 | 31 | src/mir/mir_lowering.rb (0.041); src/mir/mir_pass.rb (0.041); spec/lifetime_unified_spec.rb (0.034); src/ast/symbol_entry.rb (0.034); spec/vm_bg_capture_bugs_spec.rb (0.032) |
| 61 | `src/semantic/ownership_graph.rb` | 0.344 | 2 | 5.5 | 9 | sorbet/rbi/clear-attr-accessors.rbi (0.039); spec/ownership_graph_spec.rb (0.039); src/annotator/domains/control_flow.rb (0.039); src/annotator/helpers/function_analysis.rb (0.039); src/annotator/helpers/with_match_check.rb (0.039) |
| 62 | `src/annotator/helpers/generic_analysis.rb` | 0.334 | 1 | 36.0 | 36 | spec/architecture_invariants_spec.rb (0.01); spec/concurrency_spec.rb (0.01); spec/generics_spec.rb (0.01); spec/mir_lowering_spec.rb (0.01); spec/resource_raii_spec.rb (0.01) |
| 63 | `src/ast/fixable_error.rb` | 0.222 | 1 | 5.0 | 5 | clear (0.055); spec/clear_fix_spec.rb (0.055); spec/clear_fix_support_spec.rb (0.055); src/tools/clear_fix_support.rb (0.055) |
| 64 | `src/tools/clear_fix_support.rb` | 0.222 | 1 | 5.0 | 5 | clear (0.055); spec/clear_fix_spec.rb (0.055); spec/clear_fix_support_spec.rb (0.055); src/ast/fixable_error.rb (0.055) |
| 65 | `src/ast/symbol_entry.rb` | 0.144 | 4 | 6.0 | 7 | src/mir/mir_lowering.rb (0.035); spec/lifetime_unified_spec.rb (0.034); src/annotator/helpers/capabilities.rb (0.034); src/mir/mir_pass.rb (0.034); sorbet/rbi/clear-attr-accessors.rbi (0.001) |
| 66 | `src/annotator.rb` | 0.05 | 32 | 7.69 | 78 | src/mir/mir_lowering.rb (0.004); src/annotator-helpers/effects.rb (0.004); src/mir/escape_graph.rb (0.003); src/ast/type.rb (0.002); src/mir/mir_pass.rb (0.002) |
| 67 | `src/mir/pre_mir_type_check.rb` | 0.036 | 1 | 21.0 | 21 | benchmarks/24_json_api/server.cht (0.002); benchmarks/concurrent/09_kvstore/bench.profile/alloc.txt (0.002); benchmarks/concurrent/09_kvstore/bench.profile/perf-stat.txt (0.002); benchmarks/concurrent/09_kvstore/bench.profile/perf.data (0.002); benchmarks/concurrent/09_kvstore/bench.profile/perf.data.old (0.002) |
| 68 | `src/semantic/effect_set.rb` | 0.034 | 1 | 2.0 | 2 | src/semantic/ownership_graph.rb (0.034) |
| 69 | `src/mir/cleanup_entry.rb` | 0.008 | 1 | 7.0 | 7 | sorbet/rbi/clear-attr-accessors.rbi (0.001); src/ast/ast.rb (0.001); src/ast/symbol_entry.rb (0.001); src/mir/escape_graph.rb (0.001); src/mir/mir_emitter.rb (0.001) |
| 70 | `src/backends/transpiler.rb` | 0.002 | 3 | 46.33 | 78 | clear (0.0); src/annotator-helpers/fixable_helpers.rb (0.0); src/lsp/server.rb (0.0); benchmarks/concurrent/11_parallel_aggregation/README.md (0.0); benchmarks/inter-clear/02_concurrent_fsm_vs_stackful/bench_fsm.cht (0.0) |
| 71 | `src/mir/fsm_transform/liveness.rb` | 0.001 | 1 | 57.0 | 57 | benchmarks/concurrent/06_dynamic_spawn/TIMEOUT (0.0); benchmarks/concurrent/11_parallel_aggregation/README.md (0.0); benchmarks/concurrent/12_false_sharing/README.md (0.0); benchmarks/concurrent/12_false_sharing/bench (0.0); benchmarks/concurrent/12_false_sharing/bench.cht (0.0) |
| 72 | `src/ast/diagnostic_buckets.rb` | 0.001 | 1 | 31.0 | 31 | .rubocop_todo.yml (0.0); clear (0.0); sorbet/rbi/ast-struct-fields.rbi (0.0); spec/annotator_spec.rb (0.0); spec/atomic_escape_fix_spec.rb (0.0) |
| 73 | `src/ast/diagnostic_examples.rb` | 0.001 | 1 | 31.0 | 31 | .rubocop_todo.yml (0.0); clear (0.0); sorbet/rbi/ast-struct-fields.rbi (0.0); spec/annotator_spec.rb (0.0); spec/atomic_escape_fix_spec.rb (0.0) |
| 74 | `src/lsp/diagnostics.rb` | 0.001 | 1 | 31.0 | 31 | .rubocop_todo.yml (0.0); clear (0.0); sorbet/rbi/ast-struct-fields.rbi (0.0); spec/annotator_spec.rb (0.0); spec/atomic_escape_fix_spec.rb (0.0) |
| 75 | `src/tools/doctor.rb` | 0.001 | 3 | 29.67 | 78 | spec/mir_lowering_spec.rb (0.0); spec/generics_spec.rb (0.0); src/annotator-helpers/effects.rb (0.0); src/tools/pprof.rb (0.0); clear (0.0) |

- ...(+8 more)

## Fixed But Unmeasured (5)
_files with recurring fixes but NO branch-coverage data -- recurring-fix code the corpus does not measure at all; itself a risk._

- `src/README.md` (fix_norm=0.175)
- `src/annotator/README.md` (fix_norm=0.175)
- `src/mir/README.md` (fix_norm=0.175)
- `src/annotator/helpers/intrinsic_emit.rb` (fix_norm=0.041)
- `src/mir/cleanup_entry.rb` (fix_norm=0.001)

## Run Summary
- Repo: `/home/yahn/litedb`
- Scope: `src/`
- Fix commits matched: 236 (time span over whole history, unfiltered)
- Files ranked: 78; fixed-but-unmeasured: 5
- State-based branch hotspots: 509; multi-file fix blast rows: 83
- Branch-coverage resultset: SimpleCov + tree-sitter static fallback
- Mutation facts: litedb-mutant-facts.json
- Method: vendored bugspots ([Google ICSE'13 time-decay](docs/agents/design.md#prior-art)) x normalized coverage branch gap; method gaps use Decomplex detector scores, fix history, and mutation verification when supplied (see [docs/agents/design.md](docs/agents/design.md))
