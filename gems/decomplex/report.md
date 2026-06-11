# Decomplex Report

> Decision-level duplication and neglected-condition analysis.
> Every entry is a ranked **candidate** (Engler's discipline),
> never a verdict -- *POSSIBLE* findings, triaged by a human.
> Sections are ordered by SIGNAL TIER (1 = lowest false
> positive), not by volume. Items within a section are
> frequency-ranked. Triage tier 1, top-of-list, first.

## Table of Contents
- [Project Prioritization](#project-prioritization)
- [Cross-Detector Convergence (1783)](#cross-detector-convergence-1783)
- [Root-Cause Clusters (479)](#root-cause-clusters-479)
- [Decision Pressure (275)](#decision-pressure-275)
- [Redundant Nil Guards (0)](#redundant-nil-guards-0)
- [State Heatmap (558)](#state-heatmap-558)
- [State-Based Branch Density (1611)](#statebased-branch-density-1611)
- [Temporal Ordering Pressure (14)](#temporal-ordering-pressure-14)
- [Missing Abstractions (174)](#missing-abstractions-174)
- [Reification Misses (6)](#reification-misses-6)
- [Semantic Predicate Aliases (5)](#semantic-predicate-aliases-5)
- [Exact Predicate Aliases (16)](#exact-predicate-aliases-16)
- [Inconsistent Rename Clones (71)](#inconsistent-rename-clones-71)
- [Flay Similarity (Type-2/3) (54)](#flay-similarity-type23-54)
- [Neglected Updates (649)](#neglected-updates-649)
- [Derived-State Staleness (137)](#derivedstate-staleness-137)
- [Neglected Conditions (9)](#neglected-conditions-9)
- [Neglected Path Conditions (1355)](#neglected-path-conditions-1355)
- [Oversized Predicates (15)](#oversized-predicates-15)
- [Broken Protocols (378)](#broken-protocols-378)
- [False Simplicity (1072)](#false-simplicity-1072)
- [Fat Unions (9)](#fat-unions-9)
- [Run Summary](#run-summary)

## Project Prioritization
_Ordered by signal tier (1 = highest signal / lowest FP), then by volume._

- **[tier 1]** [State-Based Branch Density (1611)](#statebased-branch-density-1611): branch decisions over mutable/object state -- state + control-flow pressure
- **[tier 1]** [State Heatmap (558)](#state-heatmap-558): state fields ranked by write/read/re-derivation scatter -- tangled mutable state should get one owner
- **[tier 1]** [Decision Pressure (275)](#decision-pressure-275): ELIMINABLE guard-pressure per loose contract (nil/is_a?/respond_to?/safe-nav/rescue-nil) -> tighten the contract once / nil-kill: DELETE. essential dispatch + pure c-uses are split out, NEVER summed (Rapps-Weyuker p-use; McCabe)
- **[tier 1]** [Missing Abstractions (174)](#missing-abstractions-174): guard tuple recomputed across >=2 decision units
- **[tier 1]** [Exact Predicate Aliases (16)](#exact-predicate-aliases-16): identical one-line predicate body under >=2 names
- **[tier 1]** [Temporal Ordering Pressure (14)](#temporal-ordering-pressure-14): public mutable lifecycle surfaces that create implicit state-machine ordering
- **[tier 1]** [Reification Misses (6)](#reification-misses-6): an existing predicate reinvented inline -- invariant #16
- **[tier 1]** [Semantic Predicate Aliases (5)](#semantic-predicate-aliases-5): one decision, multiple names (receiver/polarity folded)
- **[tier 2]** [Neglected Updates (649)](#neglected-updates-649): co-written state, one write missing -- *POSSIBLE* redundant-state desync
- **[tier 2]** [Derived-State Staleness (137)](#derivedstate-staleness-137): b = f(a); a later reassigned, b not recomputed -- *POSSIBLE* bug
- **[tier 2]** [Inconsistent Rename Clones (71)](#inconsistent-rename-clones-71): pasted block with inconsistent identifier mapping -- *POSSIBLE* missed rename bug
- **[tier 2]** [Flay Similarity (Type-2/3) (54)](#flay-similarity-type23-54): Flay structural clone pressure: Type-2 renamed clones and Type-3 fuzzy clones -- refactor pressure, not a verdict
- **[tier 2]** [Neglected Conditions (9)](#neglected-conditions-9): dispatch/conjunction minus one element -- *POSSIBLE* bug
- **[tier 3]** [Neglected Path Conditions (1355)](#neglected-path-conditions-1355): nested-if/&& guard set minus one atom -- *POSSIBLE* bug (noisy)
- **[tier 3]** [False Simplicity (1072)](#false-simplicity-1072): looks simple, behaves non-locally: hidden dispatch/mutation/IO/context/metaprogramming/monkeypatch -- *POSSIBLE* (noisy)
- **[tier 3]** [Broken Protocols (378)](#broken-protocols-378): co-called pair, one site does A without B -- *POSSIBLE* bug (noisy)
- **[tier 3]** [Oversized Predicates (15)](#oversized-predicates-15): predicate with >3 condition atoms -- use an existing helper or extract a named predicate
- **[tier 3]** [Fat Unions (9)](#fat-unions-9): case dispatch over class consts whose arms read mostly variant-invariant members -- product-vs-sum decomposition candidate (extraction -> nil-kill) -- *POSSIBLE*

## Cross-Detector Convergence (1783)
_(file, method) units flagged by >=2 INDEPENDENT detectors -- the strongest triage signal: agreement outranks any single detector's volume. Tier-weighted (1=3, 2=2, 3=1). **Start here.**_

- `src/tools/doctor.rb:171` (section_heap) -- **8 detectors** [score 16, 53 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Flay Similarity (Type-2/3), Missing Abstractions, Neglected Path Conditions, State-Based Branch Density
- `src/annotator/domains/variables.rb:279` (visit_BindExpr) -- **7 detectors** [score 14, 70 findings]: Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates, State-Based Branch Density
- `src/annotator/helpers/function_analysis.rb:399` (resolve_call) -- **6 detectors** [score 13, 122 findings]: Decision Pressure, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates, State-Based Branch Density
- `src/annotator/helpers/pipe_analysis.rb:1590` (analyze_concurrent_op) -- **6 detectors** [score 13, 69 findings]: Decision Pressure, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates, State-Based Branch Density
- `src/backends/pipeline_rewriter.rb:493` (build_recursive_body) -- **6 detectors** [score 13, 44 findings]: Derived-State Staleness, False Simplicity, Flay Similarity (Type-2/3), Missing Abstractions, Neglected Updates, State-Based Branch Density
- `src/ast/parser.rb:301` ((top-level)) -- **6 detectors** [score 13, 29 findings]: Decision Pressure, False Simplicity, Flay Similarity (Type-2/3), Missing Abstractions, Neglected Path Conditions, State-Based Branch Density
- `src/annotator/domains/variables.rb:13` (visit_VarDecl) -- **6 detectors** [score 13, 25 findings]: Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Neglected Updates, State-Based Branch Density
- `src/annotator/domains/variables.rb:554` (visit_Assignment) -- **6 detectors** [score 13, 21 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, State-Based Branch Density
- `src/annotator/domains/execution_boundaries.rb:358` (validate_lock_error_clause!) -- **6 detectors** [score 13, 19 findings]: Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Neglected Updates, State-Based Branch Density
- `src/annotator/helpers/pipe_analysis.rb:817` (analyze_pipe_to_named_function) -- **6 detectors** [score 13, 15 findings]: Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, State-Based Branch Density
- `src/mir/lowering/functions.rb:819` (build_post_outer_fn) -- **6 detectors** [score 13, 12 findings]: Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Neglected Updates, State-Based Branch Density
- `src/tools/formatter.rb:1294` (expand_if_while_for) -- **6 detectors** [score 12, 86 findings]: Derived-State Staleness, False Simplicity, Inconsistent Rename Clones, Missing Abstractions, Neglected Path Conditions, State-Based Branch Density
- `src/annotator/domains/member_access.rb:316` (visit_StructLit) -- **6 detectors** [score 12, 72 findings]: Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions, Neglected Updates, State-Based Branch Density
- `src/tools/formatter.rb:2413` (emit_record_type) -- **6 detectors** [score 12, 69 findings]: Derived-State Staleness, False Simplicity, Inconsistent Rename Clones, Missing Abstractions, Neglected Path Conditions, State-Based Branch Density
- `src/tools/formatter.rb:822` (emit_fn_block) -- **6 detectors** [score 12, 48 findings]: Derived-State Staleness, False Simplicity, Inconsistent Rename Clones, Missing Abstractions, Neglected Path Conditions, State-Based Branch Density
- `src/tools/formatter.rb:728` (emit_match_body) -- **6 detectors** [score 12, 48 findings]: Derived-State Staleness, False Simplicity, Inconsistent Rename Clones, Missing Abstractions, Neglected Path Conditions, State-Based Branch Density
- `src/tools/formatter.rb:2136` (emit_bg_do_wrapped) -- **6 detectors** [score 12, 44 findings]: Derived-State Staleness, False Simplicity, Inconsistent Rename Clones, Missing Abstractions, Neglected Path Conditions, State-Based Branch Density
- `src/tools/formatter.rb:581` (scan_match_arms) -- **6 detectors** [score 11, 27 findings]: Broken Protocols, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, State-Based Branch Density
- `src/annotator/helpers/pipe_analysis.rb:757` (analyze_pipe_to_func_call) -- **6 detectors** [score 11, 10 findings]: Broken Protocols, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, State-Based Branch Density
- `src/mir/mir_checker.rb:404` (check_fn!) -- **5 detectors** [score 13, 86 findings]: Decision Pressure, False Simplicity, Missing Abstractions, State-Based Branch Density, Temporal Ordering Pressure
- `src/backends/transpiler.rb:182` (transpile_as_module) -- **5 detectors** [score 13, 13 findings]: Decision Pressure, False Simplicity, Missing Abstractions, State-Based Branch Density, Temporal Ordering Pressure
- `src/annotator/domains/errors.rb:582` (visit_OrRescue) -- **5 detectors** [score 12, 52 findings]: Decision Pressure, False Simplicity, Flay Similarity (Type-2/3), Missing Abstractions, State-Based Branch Density
- `src/mir/lowering/functions.rb:1698` (lower_intrinsic) -- **5 detectors** [score 12, 30 findings]: Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, State-Based Branch Density
- `src/semantic/escape_analysis.rb:882` (function_facts) -- **5 detectors** [score 12, 26 findings]: Decision Pressure, False Simplicity, Missing Abstractions, Neglected Conditions, State-Based Branch Density
- `src/annotator/domains/lifetimes.rb:235` (visit_CloneNode) -- **5 detectors** [score 12, 25 findings]: Decision Pressure, False Simplicity, Missing Abstractions, Neglected Updates, State-Based Branch Density
- ...(+1758 more)

### By file
- `src/mir/mir_lowering.rb` -- 11 detectors across 94 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, Exact Predicate Aliases, False Simplicity, Fat Unions, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Semantic Predicate Aliases, State-Based Branch Density
- `src/ast/type.rb` -- 11 detectors across 47 method(s): Broken Protocols, Decision Pressure, Exact Predicate Aliases, False Simplicity, Flay Similarity (Type-2/3), Missing Abstractions, Neglected Path Conditions, Neglected Updates, Oversized Predicates, State-Based Branch Density, Temporal Ordering Pressure
- `src/tools/formatter.rb` -- 10 detectors across 74 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Flay Similarity (Type-2/3), Inconsistent Rename Clones, Missing Abstractions, Neglected Path Conditions, Oversized Predicates, State-Based Branch Density
- `src/annotator/helpers/pipe_analysis.rb` -- 10 detectors across 51 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Fat Unions, Flay Similarity (Type-2/3), Missing Abstractions, Neglected Path Conditions, Neglected Updates, State-Based Branch Density
- `src/ast/parser.rb` -- 10 detectors across 68 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Flay Similarity (Type-2/3), Missing Abstractions, Neglected Path Conditions, Neglected Updates, Reification Misses, State-Based Branch Density
- `src/ast/ast.rb` -- 10 detectors across 34 method(s): Decision Pressure, Derived-State Staleness, Exact Predicate Aliases, False Simplicity, Flay Similarity (Type-2/3), Missing Abstractions, Neglected Path Conditions, Neglected Updates, Semantic Predicate Aliases, State-Based Branch Density
- `src/mir/lowering/expressions.rb` -- 9 detectors across 54 method(s): Broken Protocols, Decision Pressure, False Simplicity, Flay Similarity (Type-2/3), Missing Abstractions, Neglected Path Conditions, Neglected Updates, Oversized Predicates, State-Based Branch Density
- `src/annotator/domains/control_flow.rb` -- 9 detectors across 29 method(s): Broken Protocols, Decision Pressure, False Simplicity, Flay Similarity (Type-2/3), Neglected Path Conditions, Neglected Updates, Oversized Predicates, Reification Misses, State-Based Branch Density
- `src/annotator/domains/execution_boundaries.rb` -- 9 detectors across 18 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Conditions, Neglected Path Conditions, Neglected Updates, State-Based Branch Density
- `src/backends/pipeline_rewriter.rb` -- 9 detectors across 16 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Flay Similarity (Type-2/3), Missing Abstractions, Neglected Path Conditions, Neglected Updates, State-Based Branch Density
- `src/mir/lower/pipeline/pipeline_range_lowerer.rb` -- 9 detectors across 20 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, Exact Predicate Aliases, False Simplicity, Flay Similarity (Type-2/3), Missing Abstractions, Semantic Predicate Aliases, State-Based Branch Density
- `src/mir/lowering/concurrency.rb` -- 9 detectors across 21 method(s): Broken Protocols, Decision Pressure, Exact Predicate Aliases, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Oversized Predicates, State-Based Branch Density
- `src/mir/fsm_transform/emit.rb` -- 9 detectors across 19 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, Exact Predicate Aliases, False Simplicity, Fat Unions, Missing Abstractions, Semantic Predicate Aliases, State-Based Branch Density
- `src/mir/mir_checker.rb` -- 8 detectors across 73 method(s): Broken Protocols, Decision Pressure, False Simplicity, Fat Unions, Missing Abstractions, Neglected Conditions, State-Based Branch Density, Temporal Ordering Pressure
- `src/semantic/escape_analysis.rb` -- 8 detectors across 53 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Conditions, Neglected Updates, State-Based Branch Density

## Root-Cause Clusters (479)
_Findings across >=2 INDEPENDENT detectors that name the SAME entity -- 'N findings are really one invariant'. Convergence says where to look; this says **what one fix collapses the cluster**. Ranked candidate, not a verdict._

- **[name]** `expr` -- **6 detectors** [score 14] across 60 unit(s), 56 findings: Decision Pressure, Exact Predicate Aliases, False Simplicity, Neglected Path Conditions, Semantic Predicate Aliases, State-Based Branch Density
  - FIX: reify ONE named predicate/decision and call it everywhere
  - `src/annotator/domains/control_flow.rb:151` (visit_IfBind) ; `src/annotator/domains/control_flow.rb:389` (consume_match_subject_if_takes!) ; `src/annotator/domains/execution_boundaries.rb:843` (visit_NextExpr) ; `src/annotator/domains/execution_boundaries.rb:846` (visit_NextExpr)
- **[name]** `line` -- **6 detectors** [score 12] across 28 unit(s), 34 findings: Decision Pressure, Derived-State Staleness, Neglected Path Conditions, Neglected Updates, Oversized Predicates, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/tools/doctor.rb:617` (task_site_metadata) ; `src/tools/doctor.rb:630` (source_line) ; `src/annotator/helpers/capabilities.rb:1343` (finalize_capability_audit!) ; `src/annotator/helpers/capabilities.rb:1347` (finalize_capability_audit!)
- **[name]** `value` -- **6 detectors** [score 11] across 136 unit(s), 104 findings: Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions, Oversized Predicates, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator/domains/control_flow.rb:427` (analyze_match_case!) ; `src/annotator/domains/errors.rb:375` (visit_ReturnNode) ; `src/annotator/domains/errors.rb:414` (visit_ReturnNode) ; `src/annotator/domains/errors.rb:417` (visit_ReturnNode)
- **[name]** `stmt` -- **5 detectors** [score 12] across 47 unit(s), 47 findings: Derived-State Staleness, Exact Predicate Aliases, Neglected Path Conditions, Semantic Predicate Aliases, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/mir/fsm_transform/segments.rb:226` (split_while_loop_next) ; `src/mir/fsm_transform/segments.rb:232` (split_while_loop_next) ; `src/mir/fsm_transform/segments.rb:240` (split_while_loop_next) ; `src/mir/fsm_transform/segments.rb:256` (split_while_loop_next)
- **[name]** `sync` -- **5 detectors** [score 11] across 26 unit(s), 14 findings: Decision Pressure, False Simplicity, Oversized Predicates, Reification Misses, State-Based Branch Density
  - FIX: reify ONE named predicate/decision and call it everywhere
  - `src/annotator/domains/errors.rb:530` (same_return_capabilities?) ; `src/annotator/domains/lifetimes.rb:1015` (bg_capture_independent?) ; `src/annotator/helpers/generic_analysis.rb:459` (generic_type_has_capabilities?) ; `src/annotator/helpers/pipe_analysis.rb:1247` (auto_detect_sharded_access)
- **[name]** `struct` -- **5 detectors** [score 11] across 20 unit(s), 20 findings: Exact Predicate Aliases, Neglected Path Conditions, Oversized Predicates, Semantic Predicate Aliases, State-Based Branch Density
  - FIX: reify ONE named predicate/decision and call it everywhere
  - `src/mir/lowering/functions.rb:290` (lower_function_def) ; `src/mir/lowering/functions.rb:301` (lower_function_def) ; `src/mir/lowering/functions.rb:344` (lower_function_def) ; `src/mir/lowering/functions.rb:360` (lower_function_def)
- **[name]** `union` -- **5 detectors** [score 11] across 20 unit(s), 23 findings: Broken Protocols, Exact Predicate Aliases, Neglected Path Conditions, Semantic Predicate Aliases, State-Based Branch Density
  - FIX: pair the protocol (RAII / ensure); the unpaired site is the deviant
  - `src/annotator/domains/control_flow.rb:644` (emit_missing_match_variants!) ; `src/annotator/domains/control_flow.rb:647` (emit_missing_match_variants!) ; `src/annotator/domains/control_flow.rb:649` (emit_missing_match_variants!) ; `src/annotator/domains/control_flow.rb:651` (emit_missing_match_variants!)
- **[name]** `current` -- **5 detectors** [score 10] across 28 unit(s), 30 findings: Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/ast/parser.rb:2499` (peek_generic_angle_params?) ; `src/ast/parser.rb:2495` (peek_generic_angle_params?) ; `src/ast/parser.rb:2500` (peek_generic_angle_params?) ; `src/ast/parser.rb:2502` (peek_generic_angle_params?)
- **[name]** `state` -- **5 detectors** [score 10] across 23 unit(s), 30 findings: False Simplicity, Neglected Path Conditions, Neglected Updates, Reification Misses, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/mir/control_flow.rb:1072` (collect_ownership_transfers) ; `src/mir/control_flow.rb:1083` (collect_ownership_transfers) ; `src/mir/control_flow.rb:1099` (collect_ownership_transfers) ; `src/mir/control_flow.rb:1116` (collect_ownership_transfers)
- **[name]** `emit` -- **5 detectors** [score 10] across 20 unit(s), 17 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Updates, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/mir/fsm_transform/suspend_resolvers.rb:65` (resolve_io) ; `src/mir/fsm_transform/suspend_resolvers.rb:66` (resolve_io) ; `src/mir/fsm_transform/suspend_resolvers.rb:67` (resolve_io) ; `src/mir/fsm_transform/suspend_resolvers.rb:68` (resolve_io)
- **[name]** `collection` -- **5 detectors** [score 9] across 15 unit(s), 18 findings: Decision Pressure, False Simplicity, Neglected Path Conditions, Oversized Predicates, State-Based Branch Density
  - FIX: tighten the contract once; the scattered defensive guards collapse (cross-proc -> nil-kill)
  - `src/mir/lowering/control_flow.rb:451` (for_each_loop_stmt) ; `src/mir/lowering/control_flow.rb:452` (for_each_loop_stmt) ; `src/annotator/helpers/pipe_analysis.rb:499` (analyze_join_op) ; `src/annotator/helpers/pipe_analysis.rb:509` (analyze_join_op)
- **[name]** `AST` -- **5 detectors** [score 8] across 123 unit(s), 203 findings: False Simplicity, Neglected Conditions, Neglected Path Conditions, Oversized Predicates, State-Based Branch Density
  - FIX: converging structural debt -- resolve once at the named entity
  - `src/mir/lowering/variables.rb:559` (lower_var_decl_init) ; `src/mir/lowering/variables.rb:564` (lower_var_decl_init) ; `src/mir/lowering/variables.rb:565` (lower_var_decl_init) ; `src/mir/lowering/variables.rb:570` (lower_var_decl_init)
- **[name]** `mir` -- **4 detectors** [score 12] across 23 unit(s), 15 findings: Decision Pressure, Exact Predicate Aliases, Semantic Predicate Aliases, State-Based Branch Density
  - FIX: reify ONE named predicate/decision and call it everywhere
  - `src/mir/mir_lowering.rb:1165` (append_lowered_statement_packet!) ; `src/mir/hoist.rb:647` (mir_alloc_mark_type_info) ; `src/mir/hoist.rb:661` (mir_alloc_mark_type_info) ; `src/mir/hoist.rb:663` (mir_alloc_mark_type_info)
- **[name]** `alloc` -- **4 detectors** [score 10] across 21 unit(s), 16 findings: Decision Pressure, False Simplicity, Reification Misses, State-Based Branch Density
  - FIX: reify ONE named predicate/decision and call it everywhere
  - `src/mir/lowering/expressions.rb:1567` (lower_struct_lit) ; `src/mir/lowering/expressions.rb:1655` (lower_union_variant_lit) ; `src/mir/mir_emitter.rb:2101` (emit_deep_copy) ; `src/mir/mir_emitter.rb:2105` (emit_deep_copy)
- **[name]** `enum` -- **4 detectors** [score 10] across 16 unit(s), 8 findings: Broken Protocols, Exact Predicate Aliases, Semantic Predicate Aliases, State-Based Branch Density
  - FIX: pair the protocol (RAII / ensure); the unpaired site is the deviant
  - `src/annotator/domains/control_flow.rb:644` (emit_missing_match_variants!) ; `src/annotator/domains/control_flow.rb:647` (emit_missing_match_variants!) ; `src/annotator/domains/control_flow.rb:649` (emit_missing_match_variants!) ; `src/annotator/domains/control_flow.rb:651` (emit_missing_match_variants!)
- **[name]** `zig_pattern` -- **4 detectors** [score 9] across 85 unit(s), 119 findings: Decision Pressure, False Simplicity, Neglected Updates, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/mir/lowering/functions.rb:1590` (lower_intrinsic) ; `src/mir/lowering/functions.rb:1591` (lower_intrinsic) ; `src/mir/lowering/functions.rb:1624` (lower_intrinsic) ; `src/mir/lowering/functions.rb:1626` (lower_intrinsic)
- **[name]** `capture_analysis` -- **4 detectors** [score 9] across 79 unit(s), 70 findings: Decision Pressure, False Simplicity, Neglected Updates, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/mir/control_flow.rb:1228` (collect_bg_body_gives) ; `src/mir/control_flow.rb:1366` (check_stmt_reads) ; `src/mir/control_flow.rb:1367` (check_stmt_reads) ; `src/mir/control_flow.rb:1899` (check_stmt)
- **[name]** `target` -- **4 detectors** [score 9] across 49 unit(s), 40 findings: Decision Pressure, Derived-State Staleness, Neglected Path Conditions, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator/domains/errors.rb:417` (visit_ReturnNode) ; `src/annotator/domains/errors.rb:419` (visit_ReturnNode) ; `src/annotator/domains/execution_boundaries.rb:421` (reject_bare_atomic_ptr_mutation!) ; `src/annotator/domains/execution_boundaries.rb:422` (reject_bare_atomic_ptr_mutation!)
- **[name]** `can_fail` -- **4 detectors** [score 9] across 30 unit(s), 148 findings: Decision Pressure, False Simplicity, Neglected Updates, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/mir/lowering/functions.rb:301` (lower_function_def) ; `src/mir/control_flow.rb:280` (stmt_can_fail?) ; `src/mir/control_flow.rb:281` (stmt_can_fail?) ; `src/mir/control_flow.rb:283` (stmt_can_fail?)
- **[name]** `kind` -- **4 detectors** [score 9] across 25 unit(s), 25 findings: Derived-State Staleness, False Simplicity, Reification Misses, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator/domains/lifetimes.rb:1225` (reject_borrowed_value!) ; `src/annotator/domains/lifetimes.rb:1230` (reject_borrowed_value!) ; `src/annotator/domains/lifetimes.rb:1231` (reject_borrowed_value!) ; `src/annotator/domains/lifetimes.rb:1233` (reject_borrowed_value!)
- ...(+459 more)

## Decision Pressure (275)
_ELIMINABLE guard-pressure per loose contract (nil/is_a?/respond_to?/safe-nav/rescue-nil) -> tighten the contract once / nil-kill: DELETE. essential dispatch + pure c-uses are split out, NEVER summed (Rapps-Weyuker p-use; McCabe)_

- `.value` -- ELIMINABLE guard-pressure **121** across 65 method(s) -> tighten contract / nil-kill: DELETE  (+15 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/domains/control_flow.rb:427` (analyze_match_case!) ; `src/annotator/domains/errors.rb:375` (visit_ReturnNode) ; `src/annotator/domains/errors.rb:414` (visit_ReturnNode) ; `src/annotator/domains/errors.rb:417` (visit_ReturnNode)
- `.symbol` -- ELIMINABLE guard-pressure **83** across 66 method(s) -> tighten contract / nil-kill: DELETE  (+12 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/domains/errors.rb:414` (visit_ReturnNode) ; `src/annotator/domains/errors.rb:417` (visit_ReturnNode) ; `src/annotator/domains/errors.rb:419` (visit_ReturnNode) ; `src/annotator/domains/execution_boundaries.rb:426` (reject_bare_atomic_ptr_mutation!)
- `.target` -- ELIMINABLE guard-pressure **62** across 36 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/domains/errors.rb:417` (visit_ReturnNode) ; `src/annotator/domains/errors.rb:419` (visit_ReturnNode) ; `src/annotator/domains/execution_boundaries.rb:421` (reject_bare_atomic_ptr_mutation!) ; `src/annotator/domains/execution_boundaries.rb:421` (reject_bare_atomic_ptr_mutation!)
- `.name` -- ELIMINABLE guard-pressure **45** across 34 method(s) -> tighten contract / nil-kill: DELETE  (+3 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/domains/lifetimes.rb:419` (handle_assignment_identifier_move!) ; `src/annotator/domains/lifetimes.rb:448` (handle_assign_borrow) ; `src/annotator/domains/variables.rb:554` (visit_Assignment) ; `src/annotator/domains/variables.rb:595` (visit_Assignment)
- `.current_fn_ctx` -- ELIMINABLE guard-pressure **42** across 39 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/annotator.rb:357` (current_loop_depth) ; `src/annotator/annotator.rb:362` (current_conditional_depth) ; `src/annotator/domains/errors.rb:309` (visit_Raise) ; `src/annotator/domains/errors.rb:732` (visit_OrExit)
- `.left` -- ELIMINABLE guard-pressure **33** across 16 method(s) -> tighten contract / nil-kill: DELETE  (+8 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/domains/errors.rb:582` (visit_OrRescue) ; `src/annotator/helpers/pipe_analysis.rb:118` (stamp_observable_terminal!) ; `src/annotator/helpers/pipe_analysis.rb:124` (stamp_observable_terminal!) ; `src/annotator/helpers/pipe_analysis.rb:288` (analyze_collect_op)
- `.right` -- ELIMINABLE guard-pressure **33** across 13 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/domains/errors.rb:567` (visit_OrRescue) ; `src/annotator/domains/errors.rb:568` (visit_OrRescue) ; `src/annotator/domains/errors.rb:569` (visit_OrRescue) ; `src/annotator/domains/errors.rb:570` (visit_OrRescue)
- `.expr` -- ELIMINABLE guard-pressure **29** across 20 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/domains/control_flow.rb:151` (visit_IfBind) ; `src/annotator/domains/control_flow.rb:389` (consume_match_subject_if_takes!) ; `src/annotator/domains/execution_boundaries.rb:843` (visit_NextExpr) ; `src/annotator/domains/execution_boundaries.rb:846` (visit_NextExpr)
- `.type` -- ELIMINABLE guard-pressure **25** across 22 method(s) -> tighten contract / nil-kill: DELETE  (+40 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/domains/control_flow.rb:911` (loop_value_copyable?) ; `src/annotator/domains/variables.rb:13` (visit_VarDecl) ; `src/annotator/domains/variables.rb:106` (finalize_decl_node!) ; `src/annotator/domains/variables.rb:129` (finalize_decl_node!)
- `.token` -- ELIMINABLE guard-pressure **23** across 20 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/helpers/capabilities.rb:1301` (record_capability_binding) ; `src/annotator/helpers/capabilities.rb:1302` (record_capability_binding) ; `src/ast/ast.rb:476` (borrowed_ownership_view?) ; `src/mir/control_flow.rb:1083` (collect_ownership_transfers)
- `.element_type` -- ELIMINABLE guard-pressure **18** across 15 method(s) -> tighten contract / nil-kill: DELETE  (+6 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/domains/member_access.rb:531` (infer_element_type) ; `src/annotator/domains/member_access.rb:542` (infer_optional_element_type) ; `src/annotator/helpers/function_analysis.rb:819` (any_element_collection_param?) ; `src/annotator/helpers/generic_analysis.rb:183` (validate_shape_annotation_capabilities!)
- `.object` -- ELIMINABLE guard-pressure **18** across 14 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/domains/control_flow.rb:841` (visit_WhileBindLoop) ; `src/annotator/helpers/auto_inference.rb:792` (record_method_call) ; `src/annotator/helpers/function_analysis.rb:506` (receiver_container_alloc) ; `src/annotator/helpers/method_analysis.rb:156` (narrow_receiver_collection!)
- `.body` -- ELIMINABLE guard-pressure **18** across 14 method(s) -> tighten contract / nil-kill: DELETE  (+5 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/backends/pipeline_rewriter.rb:65` (rewrite_children!) ; `src/backends/string_concat_rewriter.rb:55` (rewrite_children!) ; `src/mir/fsm_transform/recursive_splitter.rb:523` (emit_with_fragment) ; `src/mir/hoist.rb:700` (block_expr_result_type)
- `.type_params` -- ELIMINABLE guard-pressure **17** across 15 method(s) -> tighten contract / nil-kill: DELETE  (+1 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/domains/control_flow.rb:317` (literal_type_substitution!) ; `src/annotator/domains/control_flow.rb:324` (literal_type_substitution!) ; `src/annotator/domains/lifetimes.rb:1177` (move_if_not_copyable!) ; `src/annotator/domains/lifetimes.rb:1203` (move_if_takes_ownership!)
- `.sync` -- ELIMINABLE guard-pressure **15** across 14 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/domains/errors.rb:530` (same_return_capabilities?) ; `src/annotator/domains/lifetimes.rb:1015` (bg_capture_independent?) ; `src/annotator/helpers/generic_analysis.rb:459` (generic_type_has_capabilities?) ; `src/annotator/helpers/pipe_analysis.rb:1247` (auto_detect_sharded_access)
- `[name]` -- ELIMINABLE guard-pressure **13** across 13 method(s) -> tighten contract / nil-kill: DELETE  (+3 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/domains/control_flow.rb:901` (captured_move_consumed_by_loop?) ; `src/annotator/domains/lifetimes.rb:529` (finalize_scope) ; `src/annotator/function_registry.rb:78` (fnptr_call?) ; `src/annotator/function_registry.rb:83` (raises_directly?)
- `.current_function_context` -- ELIMINABLE guard-pressure **13** across 13 method(s) -> tighten contract / nil-kill: DELETE
  - `src/mir/mir_lowering.rb:325` (current_function_has_rt?) ; `src/mir/mir_lowering.rb:330` (current_function_has_catch?) ; `src/mir/mir_lowering.rb:335` (current_function_heap_carry_return?) ; `src/mir/mir_lowering.rb:340` (current_function_tail_call?)
- `.first` -- ELIMINABLE guard-pressure **12** across 12 method(s) -> tighten contract / nil-kill: DELETE  (+4 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/domains/lifetimes.rb:1071` (get_lifetime_path) ; `src/annotator/domains/member_access.rb:530` (infer_element_type) ; `src/annotator/domains/member_access.rb:541` (infer_optional_element_type) ; `src/annotator/helpers/lock_helper.rb:464` (report_lock_cycle!)
- `.reg` -- ELIMINABLE guard-pressure **12** across 8 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/domains/lifetimes.rb:559` (finalize_scope) ; `src/annotator/domains/lifetimes.rb:566` (finalize_scope) ; `src/annotator/domains/lifetimes.rb:576` (finalize_scope) ; `src/annotator/domains/lifetimes.rb:577` (finalize_scope)
- `.arms` -- ELIMINABLE guard-pressure **12** across 7 method(s) -> tighten contract / nil-kill: DELETE  (+2 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/domains/execution_boundaries.rb:42` (visit_WithBlock) ; `src/annotator/domains/execution_boundaries.rb:222` (with_block_has_versioned_arm?) ; `src/mir/lowering/control_flow.rb:234` (stamp_loop_frame_alloc_scopes!) ; `src/mir/lowering/control_flow.rb:240` (stamp_loop_frame_alloc_scopes!)
- `.tense_type` -- ELIMINABLE guard-pressure **11** across 11 method(s) -> tighten contract / nil-kill: DELETE  (+11 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/helpers/generic_analysis.rb:105` (type_annotation_facts) ; `src/annotator/helpers/pipe_analysis.rb:294` (analyze_collect_op) ; `src/ast/type.rb:2137` (list_requires_array_shape?) ; `src/ast/type.rb:2142` (observable_array_without_set?)
- `.resolved_type` -- ELIMINABLE guard-pressure **10** across 5 method(s) -> tighten contract / nil-kill: DELETE  (+2 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/helpers/capabilities.rb:206` (validate_capability_transition!) ; `src/annotator/helpers/capabilities.rb:219` (validate_capability_transition!) ; `src/mir/fsm_lowering.rb:412` (fsm_cap_metadata) ; `src/mir/fsm_lowering.rb:413` (fsm_cap_metadata)
- `.tail` -- ELIMINABLE guard-pressure **10** across 4 method(s) -> tighten contract / nil-kill: DELETE
  - `src/mir/fsm_transform/emit.rb:645` (build_dispatch_tail) ; `src/mir/fsm_transform/emit.rb:816` (build_recursive) ; `src/mir/fsm_transform/emit.rb:819` (build_recursive) ; `src/mir/fsm_transform/emit.rb:820` (build_recursive)
- `[node.name]` -- ELIMINABLE guard-pressure **9** across 8 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/domains/lifetimes.rb:1180` (move_if_not_copyable!) ; `src/annotator/domains/lifetimes.rb:1207` (move_if_takes_ownership!) ; `src/annotator/helpers/effects.rb:1133` (validate_tight_node!) ; `src/annotator/helpers/effects.rb:1144` (validate_tight_node!)
- `.ownership_consumption` -- ELIMINABLE guard-pressure **9** across 7 method(s) -> tighten contract / nil-kill: DELETE
  - `src/mir/hoist.rb:785` (consumes_owned_children?) ; `src/mir/hoist.rb:1082` (refresh_ownership_consumption_for_replaced_child!) ; `src/mir/mir_checker.rb:377` (check_fn!) ; `src/mir/mir_checker.rb:1353` (cleanup_source_owns_value?)
- ...(+250 more)

## Redundant Nil Guards (0)
_nil checks / safe-nav dominated by an earlier non-nil proof -- delete repeated control flow or tighten the type_

None.

## State Heatmap (558)
_state fields ranked by write/read/re-derivation scatter -- tangled mutable state should get one owner_

- `active_stubs` -- messiness **30.0** (writes=3, reads=7, re-derived=0, scatter=3, receiver patterns=1)
  - writers: `src/mir/test_lowering.rb:55` (lower_when_block) ; `src/mir/test_lowering.rb:103` (lower_when_block) ; `src/mir/test_lowering.rb:397` (lower_stub_decl)
  - readers: `src/mir/test_lowering.rb:54` (lower_when_block) ; `src/mir/test_lowering.rb:327` (stub_intercept_for) ; `src/mir/test_lowering.rb:397` (lower_stub_decl) ; `src/mir/test_lowering.rb:402` (lower_stub_decl)
- `after_all` -- messiness **25.0** (writes=2, reads=3, re-derived=0, scatter=5, receiver patterns=3)
  - writers: `src/ast/parser.rb:4029` (parse_test_block) ; `src/ast/parser.rb:4122` (parse_when_block)
  - readers: `src/annotator/helpers/test_annotation.rb:106` (visit_test_hook_bodies) ; `src/mir/test_lowering.rb:41` (lower_test_block) ; `src/mir/test_lowering.rb:101` (lower_when_block)
- `after_each` -- messiness **42.0** (writes=2, reads=5, re-derived=0, scatter=6, receiver patterns=6)
  - writers: `src/ast/parser.rb:4027` (parse_test_block) ; `src/ast/parser.rb:4120` (parse_when_block)
  - readers: `src/annotator/helpers/test_annotation.rb:104` (visit_test_hook_bodies) ; `src/mir/test_lowering.rb:69` (lower_when_block) ; `src/mir/test_lowering.rb:149` (lower_test_that) ; `src/mir/test_lowering.rb:150` (lower_test_that)
- `alias_overrides_for` -- messiness **9.0** (writes=1, reads=2, re-derived=0, scatter=3, receiver patterns=1)
  - writers: `src/mir/fsm_transform/recursive_splitter.rb:103` (initialize)
  - readers: `src/mir/fsm_transform/recursive_splitter.rb:125` (stamp_overrides) ; `src/mir/fsm_transform/recursive_splitter.rb:184` (finalize)
- `all` -- messiness **204.0** (writes=2, reads=14, re-derived=1, scatter=12, receiver patterns=6)
  - writers: `src/ast/diagnostic_examples.rb:64` (all) ; `src/ast/diagnostic_examples.rb:65` (all)
  - readers: `src/annotator/domains/execution_boundaries.rb:27` (visit_WithBlock) ; `src/annotator/domains/execution_boundaries.rb:180` (validate_with_match_source_shape!) ; `src/annotator/domains/execution_boundaries.rb:185` (validate_with_match_source_shape!) ; `src/annotator/domains/execution_boundaries.rb:187` (validate_with_match_source_shape!)
- `alloc` -- messiness **16837.0** (writes=7, reads=142, re-derived=0, scatter=113, receiver patterns=43)
  - writers: `src/annotator/domains/lifetimes.rb:82` (ensure_owned_value!) ; `src/annotator/domains/lifetimes.rb:99` (ensure_owned_value!) ; `src/annotator/helpers/function_analysis.rb:659` (verify_takes_argument!) ; `src/annotator/helpers/function_signature.rb:381` (with_intrinsic_override)
  - readers: `src/annotator/helpers/intrinsic_contract.rb:126` (from_emit) ; `src/ast/ast.rb:2225` (alloc) ; `src/ast/ast.rb:2225` (alloc) ; `src/ast/type.rb:1657` (provenance_alloc)
- `alloc_count` -- messiness **4.0** (writes=1, reads=1, re-derived=0, scatter=2, receiver patterns=2)
  - writers: `src/annotator/helpers/function_context.rb:91` (initialize)
  - readers: `src/annotator/helpers/function_analysis.rb:272` (visit_FunctionDef)
- `alloc_fault` -- messiness **35.0** (writes=5, reads=2, re-derived=0, scatter=5, receiver patterns=5)
  - writers: `src/annotator/helpers/effects.rb:612` (compute_can_fail!) ; `src/annotator/helpers/function_signature.rb:210` (sync_from_function_def!) ; `src/annotator/helpers/function_signature.rb:246` (initialize) ; `src/annotator/helpers/function_signature.rb:408` (dup)
  - readers: `src/annotator/helpers/function_signature.rb:210` (sync_from_function_def!) ; `src/annotator/helpers/function_signature.rb:408` (dup)
- `alloc_kinds` -- messiness **150.0** (writes=2, reads=13, re-derived=0, scatter=10, receiver patterns=6)
  - writers: `src/mir/mir_checker.rb:169` (initialize) ; `src/mir/mir_checker.rb:244` (initialize)
  - readers: `src/mir/mir_checker.rb:186` (copy) ; `src/mir/mir_checker.rb:186` (copy) ; `src/mir/mir_checker.rb:258` (from_state) ; `src/mir/mir_checker.rb:269` (alloc_kinds)
- `alloc_mark_entries` -- messiness **4.0** (writes=1, reads=1, re-derived=0, scatter=2, receiver patterns=2)
  - writers: `src/semantic/bg_capture_classifier.rb:107` (classify_one!)
  - readers: `src/annotator/helpers/capabilities.rb:1058` (merge_nested!)
- `alloc_mark_fact` -- messiness **4.0** (writes=1, reads=1, re-derived=0, scatter=2, receiver patterns=1)
  - writers: `src/mir/lower/pipeline/pipeline_materializer.rb:121` (initialize)
  - readers: `src/mir/lower/pipeline/pipeline_materializer.rb:151` (materializer_alloc_mark_fact)
- `alloc_scopes` -- messiness **35.0** (writes=1, reads=6, re-derived=0, scatter=5, receiver patterns=6)
  - writers: `src/mir/mir_checker.rb:170` (initialize)
  - readers: `src/mir/mir_checker.rb:187` (copy) ; `src/mir/mir_checker.rb:187` (copy) ; `src/mir/mir_checker.rb:736` (linear_alloc!) ; `src/mir/mir_checker.rb:943` (prune_scope_locals!)
- `allocs` -- messiness **56.0** (writes=1, reads=7, re-derived=0, scatter=7, receiver patterns=6)
  - writers: `src/mir/hoist.rb:1110` (stamp_allocating_result_target!)
  - readers: `src/mir/hoist.rb:1110` (stamp_allocating_result_target!) ; `src/mir/lower/pipeline/pipeline_materializer.rb:371` (inline_source_alloc) ; `src/mir/lowering/variables.rb:682` (owned_return_transfer_binding?) ; `src/mir/mir_checker.rb:1859` (allocator_metadata_for)
- `analyze_mutex` -- messiness **4.0** (writes=1, reads=1, re-derived=0, scatter=2, receiver patterns=1)
  - writers: `src/lsp/server.rb:38` (initialize)
  - readers: `src/lsp/server.rb:270` (analyze_and_publish)
- `annotator` -- messiness **4.0** (writes=1, reads=1, re-derived=0, scatter=2, receiver patterns=1)
  - writers: `src/backends/pipeline_rewriter.rb:23` (initialize)
  - readers: `src/backends/pipeline_rewriter.rb:734` (schema_lookup)
- `anyerror_union` -- messiness **9.0** (writes=1, reads=2, re-derived=0, scatter=3, receiver patterns=1)
  - writers: `src/backends/zig_type.rb:14` (initialize)
  - readers: `src/backends/zig_type.rb:49` (error_union?) ; `src/backends/zig_type.rb:66` (concrete_fallible_return_type)
- `arg_families` -- messiness **1.0** (writes=1, reads=0, re-derived=0, scatter=1, receiver patterns=1)
  - writers: `src/annotator/phases/expression_domains.rb:203` (record_named_call_site!)
  - readers:
- `arg_mirs` -- messiness **10.0** (writes=1, reads=4, re-derived=0, scatter=2, receiver patterns=1)
  - writers: `src/mir/fsm_ops.rb:287` (initialize)
  - readers: `src/mir/fsm_ops.rb:350` (lower_expr) ; `src/mir/fsm_ops.rb:350` (lower_expr) ; `src/mir/fsm_ops.rb:351` (lower_expr) ; `src/mir/fsm_ops.rb:353` (lower_expr)
- `arg_spec` -- messiness **63.0** (writes=3, reads=6, re-derived=0, scatter=7, receiver patterns=7)
  - writers: `src/annotator/helpers/function_signature.rb:255` (initialize) ; `src/annotator/helpers/function_signature.rb:417` (dup) ; `src/annotator/helpers/intrinsic_registry.rb:139` (convert_entry)
  - readers: `src/annotator/domains/lifetimes.rb:469` (resolve_borrow_source) ; `src/annotator/helpers/function_analysis.rb:464` (normalize_intrinsic_signature) ; `src/annotator/helpers/function_analysis.rb:466` (normalize_intrinsic_signature) ; `src/annotator/helpers/function_signature.rb:417` (dup)
- `arg_validator` -- messiness **24.0** (writes=3, reads=3, re-derived=0, scatter=4, receiver patterns=4)
  - writers: `src/annotator/helpers/function_signature.rb:254` (initialize) ; `src/annotator/helpers/function_signature.rb:416` (dup) ; `src/annotator/helpers/intrinsic_registry.rb:138` (convert_entry)
  - readers: `src/annotator/helpers/function_signature.rb:416` (dup) ; `src/annotator/helpers/method_analysis.rb:84` (resolve_typed_method) ; `src/annotator/helpers/method_analysis.rb:85` (resolve_typed_method)
- `arity` -- messiness **50.0** (writes=3, reads=7, re-derived=0, scatter=5, receiver patterns=4)
  - writers: `src/annotator/helpers/function_signature.rb:256` (initialize) ; `src/annotator/helpers/function_signature.rb:418` (dup) ; `src/annotator/helpers/intrinsic_registry.rb:140` (convert_entry)
  - readers: `src/annotator/helpers/function_signature.rb:418` (dup) ; `src/annotator/helpers/intrinsic_registry.rb:260` (collection_value_store_method?) ; `src/annotator/helpers/method_analysis.rb:74` (resolve_typed_method) ; `src/annotator/helpers/method_analysis.rb:74` (resolve_typed_method)
- `arms` -- messiness **805.0** (writes=3, reads=32, re-derived=0, scatter=23, receiver patterns=5)
  - writers: `src/ast/parser.rb:3301` (parse_with_capability) ; `src/ast/parser.rb:3374` (parse_snapshot_block) ; `src/mir/lower/pipeline/pipeline_context.rb:297` (substitute_with_block)
  - readers: `src/annotator/domains/execution_boundaries.rb:42` (visit_WithBlock) ; `src/annotator/domains/execution_boundaries.rb:80` (visit_WithBlock) ; `src/annotator/domains/execution_boundaries.rb:87` (visit_WithBlock) ; `src/annotator/domains/execution_boundaries.rb:178` (validate_with_match_source_shape!)
- `arrow_token` -- messiness **42.0** (writes=1, reads=6, re-derived=0, scatter=6, receiver patterns=2)
  - writers: `src/ast/parser.rb:1516` (parse_function_def)
  - readers: `src/annotator/helpers/capabilities.rb:553` (visit_pre_clauses!) ; `src/annotator/helpers/effects.rb:1177` (check_indirect_reentrancy!) ; `src/annotator/helpers/fixable_helpers.rb:684` (emit_reentrant_error!) ; `src/annotator/helpers/fixable_helpers.rb:727` (emit_ambiguous_return_error!)
- `as_type` -- messiness **54.0** (writes=3, reads=6, re-derived=0, scatter=6, receiver patterns=3)
  - writers: `src/ast/parser.rb:1139` (parse_extern_struct) ; `src/ast/schemas.rb:137` (initialize) ; `src/ast/schemas.rb:308` (initialize)
  - readers: `src/annotator/phases/import_resolution.rb:89` (clone_struct_schema) ; `src/annotator/phases/import_resolution.rb:102` (clone_resource_schema) ; `src/annotator/phases/type_registration.rb:43` (register_extern_struct_declaration) ; `src/annotator/phases/type_registration.rb:50` (register_extern_struct_declaration)
- `ast_stmts_use_placeholder` -- messiness **9.0** (writes=1, reads=2, re-derived=0, scatter=3, receiver patterns=1)
  - writers: `src/mir/lower/pipeline/pipeline_range_lowerer.rb:203` (initialize)
  - readers: `src/mir/lower/pipeline/pipeline_each_lowerer.rb:251` (lower_range_literal_each) ; `src/mir/lower/pipeline/pipeline_range_lowerer.rb:231` (range_ast_stmts_use_placeholder?)
- ...(+533 more)

## State-Based Branch Density (1611)
_branch decisions over mutable/object state -- state + control-flow pressure_

- `src/ast/ast.rb:196` (initialize) -- **21** state-based branch decision(s), refs=`rt.nil? | self[:bindings].nil? | self[:body].nil? | self[:borrowed].nil? | self[:capabilities].nil? | self[:cases].nil? | self[:extra_values].nil? | self[:fields].nil?` score=378
  - example predicate: `self[:body].nil?`
- `src/mir/cleanup_classifier.rb:750` (classify_binding) -- **13** state-based branch decision(s), refs=`facts.borrow_provenance | facts.container_borrow | facts.empty_initializer | facts.heap_storage | facts.mutable_binding_mutated | facts.resource_close_plan | facts.rodata_provenance | facts.sync` score=221
  - example predicate: `facts.container_borrow`
- `src/mir/fsm_transform/emit.rb:689` (build_recursive) -- **14** state-based branch decision(s), refs=`all_promoted.any? | ast_stmts.empty? | descriptor.nil? | lowered_mir.nil? | name.empty? | name.nil? | out.nil? | parts.empty?` score=196
  - example predicate: `segments.segments.empty?`
- `src/annotator/domains/execution_boundaries.rb:836` (visit_NextExpr) -- **15** state-based branch decision(s), refs=`async_shape.payload_type | async_shape.promise? | async_shape.shared_promise? | node.expr | promise_type.bounded_stream? | promise_type.dynamic_stream? | promise_type.future? | promise_type.inf_stream?` score=195
  - example predicate: `promise_type.future?`
- `src/tools/formatter.rb:2806` (needs_space?) -- **27** state-based branch decision(s), refs=`@generic_bracket_indices | @struct_lit_brace_indices | @struct_lit_brace_indices.empty? | a.raw | a.type | b.raw | b.type` score=189
  - example predicate: `b.type == :VAR_ID && b.raw.start_with?('@')`
- `src/annotator/domains/variables.rb:89` (finalize_decl_node!) -- **13** state-based branch decision(s), refs=`cap_tok.value | final_type.collection | fixes.any? | fixes.empty? | node.type | node.type.future? | node.type.observable? | node.value` score=182
  - example predicate: `node.type`
- `src/tools/formatter.rb:1294` (expand_if_while_for) -- **22** state-based branch decision(s), refs=`out.length | t.raw | t.type | tj.raw | tj.type | toks[j].type | toks[k].raw | toks[k].type` score=176
  - example predicate: `t.type == :SYM && ['(', '['].include?(t.raw)`
- `src/annotator/domains/errors.rb:375` (visit_ReturnNode) -- **13** state-based branch decision(s), refs=`expected.heap_return_storage? | expected.plain_return_payload_type | inline_bg_sources.any? | node.value | node.value.full_type!(context: "return expression storage").requires_move? | node.value.nil? | val.symbol | val.symbol.non_escaping` score=169
  - example predicate: `node.value.nil?`
- `src/annotator/domains/lifetimes.rb:529` (finalize_scope) -- **15** state-based branch decision(s), refs=`branch.nil? | info.mutable | info.mutated | info.ownership_kind | info.read | info.reg | info.reg.var_mutated | info.reg.var_used` score=150
  - example predicate: `ownership_graph.live?(name) || (is_takes && ownership_graph[name]&.moved?)`
- `src/annotator/helpers/function_analysis.rb:191` (visit_FunctionDef) -- **14** state-based branch decision(s), refs=`candidate_snap_types.size | catch_body_scan.references_snapshot | fn_type_params.any? | node.name | node.reentrance_kind | node.reentrant | node.return_type | node.tail_call` score=140
  - example predicate: `has_mutable_param && !node.name.end_with?("!")`
- `src/annotator/domains/execution_boundaries.rb:738` (visit_BgBlock) -- **12** state-based branch decision(s), refs=`analysis.has_affine_locked | analysis.has_local | analysis.has_sharded | analysis_result.has_local | analysis_result.has_non_escaping_capture | analysis_result.has_outer_ref | analysis_result.has_rc | analysis_result.has_shared` score=132
  - example predicate: `node.arena_mode`
- `src/mir/mir_lowering.rb:2689` (mir_cast) -- **10** state-based branch decision(s), refs=`from_t.dynamic? | from_t.fixed? | from_t.float? | from_t.fn_type? | from_t.integer? | from_t.map? | to_t.dynamic? | to_t.empty_list?` score=130
  - example predicate: `from_t.fn_type? || to_t.fn_type?`
- `src/mir/lowering/variables.rb:559` (lower_var_decl_init) -- **12** state-based branch decision(s), refs=`ft.fixed_soa? | ft.list_collection? | ft.pool? | ft.set_collection? | node.value | node.value.was_moved | rhs.op | rhs.smooth?` score=120
  - example predicate: `node.value.is_a?(AST::NextExpr)`
- `src/ast/parser.rb:1321` (parse_function_def) -- **10** state-based branch decision(s), refs=`@gradual | @pos | @tokens | @tokens[@pos + 1].value | T.must(cap_tok).value | current.type | current.value | early_requires_clauses.empty?` score=120
  - example predicate: `!explicit_return && @gradual`
- `src/mir/lowering/functions.rb:1590` (lower_intrinsic) -- **11** state-based branch decision(s), refs=`alloc_metadata.empty? | consumed_operands.empty? | entry.intrinsic_bc? | node.args | node.args.first | node.object | node.zig_pattern | ownership_facts.takes_any?` score=110
  - example predicate: `node.zig_pattern.is_a?(Symbol)`
- `src/semantic/escape_analysis.rb:282` (propagate_caller_sync!) -- **11** state-based branch decision(s), refs=`call_site.fn_var_call | callee_fn.params | entry.storage | entry.sync | fn_nodes.empty? | s.rc_stored? | s.sync | sites.empty?` score=110
  - example predicate: `fn_nodes.empty?`
- `src/annotator/domains/expressions.rb:257` (visit_CapabilityWrap) -- **10** state-based branch decision(s), refs=`node.atomic? | node.atomic_ptr? | node.capability? | node.indirect? | node.layout | node.lock_rank | node.locked_sync? | node.multiowned?` score=110
  - example predicate: `ti.primitive? && node.atomic_ptr?`
- `src/annotator/domains/member_access.rb:250` (visit_StructLit) -- **10** state-based branch decision(s), refs=`field_names.empty? | missing.any? | node.fields | node.fields.empty? | node.fields.length | raw_expected.nil? | schema.borrowed_fields | schema.borrowed_fields.any?` score=110
  - example predicate: `schema.nil?`
- `src/mir/lowering/expressions.rb:1993` (lower_copy) -- **8** state-based branch decision(s), refs=`dst_ti.collection? | dst_ti.direct_indexable_collection? | dst_ti.string? | ti.any_rc? | ti.any_sync? | ti.collection? | ti.collection_value? | ti.direct_indexable_collection?` score=104
  - example predicate: `ti.any_rc?`
- `src/annotator/helpers/capabilities.rb:459` (predicate_impurity_reason) -- **10** state-based branch decision(s), refs=`call.can_fail | call.extern_call | call.matched_stdlib_def | effects.empty? | extern_effects.empty? | fn.can_fail | md.can_fail | md.emits_allocating?` score=100
  - example predicate: `call.extern_call`
- `src/mir/mir_checker.rb:1512` (check_fsm_structure!) -- **10** state-based branch decision(s), refs=`cap.cleanup_at | cap.name | cleanup_step.nil? | fact.move_guarded | fact.name | result_facts.any? | step.index | structure.ctx_id` score=100
  - example predicate: `cap.cleanup_at == :finalize`
- `src/annotator/helpers/function_analysis.rb:348` (resolve_call) -- **11** state-based branch decision(s), refs=`arg.full_type!(context: "extern argument").soa? | call_type.error_union? | comptime_type_args.any? | entry.storage | node.args | p.comptime | signature.extern | signature.module_alias` score=99
  - example predicate: `args.equal?(node.args)`
- `src/annotator/helpers/function_analysis.rb:1008` (declare_and_verify_params) -- **10** state-based branch decision(s), refs=`fams.empty? | field_names.empty? | missing.any? | param.default | param.sync | param.takes | param.type | param.type.any_sync?` score=90
  - example predicate: `param.default`
- `src/annotator/domains/member_access.rb:76` (visit_GetField) -- **8** state-based branch decision(s), refs=`check.empty? | field_type.indirect? | field_type.optional? | node.is_assignment_lhs | node.target | node.target.name | node.token | node.wildcard?` score=88
  - example predicate: `check.empty?`
- `src/mir/lowering/control_flow.rb:371` (for_each_loop_stmt) -- **8** state-based branch decision(s), refs=`ct.bounded_stream? | ct.dynamic_field_array? | ct.dynamic_stream? | ct.fixed_soa? | ct.inf_stream? | ct.list_collection? | ct.map? | ct.open_stream?` score=88
  - example predicate: `ct.map?`
- ...(+1586 more)

## Temporal Ordering Pressure (14)
_public mutable lifecycle surfaces that create implicit state-machine ordering_

- `FunctionSignature` (`src/annotator/helpers/function_signature.rb:36` (FunctionSignature)) -- implicit lifecycle score **5401** (public=43, state methods=9, writers=5, fields=29, shared=29, flows=9!, states=2^29)
  - shared fields: `@alloc_fault | @arg_spec | @arg_validator | @arity | @can_fail | @effects | @emit | @error_fallible`
  - surface: `src/annotator/helpers/function_signature.rb:36` (return_lifetime=) ; `src/annotator/helpers/function_signature.rb:52` (return_type=) ; `src/annotator/helpers/function_signature.rb:99` (emit=) ; `src/annotator/helpers/function_signature.rb:104` (intrinsic_contract) ; `src/annotator/helpers/function_signature.rb:115` (requires=) ; `src/annotator/helpers/function_signature.rb:223` (initialize)
- `Profile` (`src/tools/pprof.rb:65` (Profile)) -- implicit lifecycle score **4996** (public=12, state methods=10, writers=6, fields=15, shared=15, flows=10!, states=2^15)
  - shared fields: `@default_sample_type_idx | @duration_nanos | @functions | @locations | @mappings | @next_func_id | @next_loc_id | @next_mapping_id`
  - surface: `src/tools/pprof.rb:65` (initialize) ; `src/tools/pprof.rb:86` (intern) ; `src/tools/pprof.rb:94` (add_sample_type) ; `src/tools/pprof.rb:100` (set_period_type) ; `src/tools/pprof.rb:107` (default_sample_type=) ; `src/tools/pprof.rb:119` (add_mapping)
- `SymbolEntry` (`src/ast/symbol_entry.rb:147` (SymbolEntry)) -- implicit lifecycle score **4288** (public=52, state methods=16, writers=3, fields=13, shared=4, flows=16!, states=2^13)
  - shared fields: `@flow | @lifecycle | @lifetime | @reg`
  - surface: `src/ast/symbol_entry.rb:147` (lifetime=) ; `src/ast/symbol_entry.rb:367` (invalidate!) ; `src/ast/symbol_entry.rb:373` (mark_read!) ; `src/ast/symbol_entry.rb:379` (mark_mutated!) ; `src/ast/symbol_entry.rb:385` (mark_mutated_via_reference!) ; `src/ast/symbol_entry.rb:391` (mark_poly_borrow_target!)
- `Type` (`src/ast/type.rb:745` (Type)) -- implicit lifecycle score **1682** (public=242, state methods=26, writers=9, fields=9, shared=5, flows=26!, states=2^9)
  - shared fields: `@capabilities | @generic_payload_type_arg | @is_resource | @placement | @zig_type_cache`
  - surface: `src/ast/type.rb:745` (initialize) ; `src/ast/type.rb:843` (ownership) ; `src/ast/type.rb:854` (sync) ; `src/ast/type.rb:865` (layout) ; `src/ast/type.rb:876` (lock_rank) ; `src/ast/type.rb:887` (collection)
- `SemanticAnnotator` (`src/annotator/annotator.rb:159` (SemanticAnnotator)) -- implicit lifecycle score **792** (public=44, state methods=35, writers=2, fields=9, shared=4, flows=35!, states=2^9)
  - shared fields: `@function_registry | @program | @receiver_state | @semantic_index`
  - surface: `src/annotator/annotator.rb:159` (semantic_function_registry) ; `src/annotator/annotator.rb:169` (phase_receiver_state) ; `src/annotator/annotator.rb:175` (ownership_graph) ; `src/annotator/annotator.rb:191` (scope_stack) ; `src/annotator/annotator.rb:196` (semantic_root_scope) ; `src/annotator/annotator.rb:201` (semantic_program)
- `OwnershipGraph` (`src/semantic/ownership_graph.rb:131` (OwnershipGraph)) -- implicit lifecycle score **528** (public=23, state methods=16, writers=5, fields=7, shared=5, flows=16!, states=2^7)
  - shared fields: `@children | @completed_nodes | @edges | @nodes | @scope_depth`
  - surface: `src/semantic/ownership_graph.rb:131` (initialize) ; `src/semantic/ownership_graph.rb:142` (scope_depth) ; `src/semantic/ownership_graph.rb:147` (push_scope!) ; `src/semantic/ownership_graph.rb:153` (pop_scope!) ; `src/semantic/ownership_graph.rb:159` (nodes) ; `src/semantic/ownership_graph.rb:167` (clear_completed_snapshot!)
- `Scope` (`src/ast/scope.rb:106` (Scope)) -- implicit lifecycle score **394** (public=35, state methods=19, writers=2, fields=7, shared=7, flows=19!, states=2^7)
  - shared fields: `@bindings | @dependencies | @depth | @owned_names | @parent | @type_store | @types`
  - surface: `src/ast/scope.rb:106` (initialize) ; `src/ast/scope.rb:117` (declare) ; `src/ast/scope.rb:140` (install_entry) ; `src/ast/scope.rb:158` (initialize_copy) ; `src/ast/scope.rb:189` (install_type) ; `src/ast/scope.rb:200` (resolve_type_entry)
- `ZigTranspiler` (`src/backends/transpiler.rb:42` (ZigTranspiler)) -- implicit lifecycle score **304** (public=6, state methods=4, writers=3, fields=8, shared=4, flows=4!, states=2^8)
  - shared fields: `@default_stack_size | @importer | @source_dir | @test_mode`
  - surface: `src/backends/transpiler.rb:42` (initialize) ; `src/backends/transpiler.rb:56` (transpile) ; `src/backends/transpiler.rb:66` (transpile_mir) ; `src/backends/transpiler.rb:161` (transpile_as_module)
- `Builder` (`src/mir/fsm_transform/recursive_splitter.rb:99` (Builder)) -- implicit lifecycle score **152** (public=9, state methods=8, writers=3, fields=5, shared=5, flows=8!, states=2^5)
  - shared fields: `@alias_overrides_for | @current_alias_overrides | @next_lock_index | @segments | @synthetic_fields`
  - surface: `src/mir/fsm_transform/recursive_splitter.rb:99` (initialize) ; `src/mir/fsm_transform/recursive_splitter.rb:112` (with_alias_overrides) ; `src/mir/fsm_transform/recursive_splitter.rb:122` (stamp_overrides) ; `src/mir/fsm_transform/recursive_splitter.rb:132` (add_synthetic_field) ; `src/mir/fsm_transform/recursive_splitter.rb:142` (reserve_index) ; `src/mir/fsm_transform/recursive_splitter.rb:150` (reserve_lock_index)
- `MIRChecker` (`src/mir/mir_checker.rb:347` (MIRChecker)) -- implicit lifecycle score **116** (public=65, state methods=28, writers=2, fields=2, shared=2, flows=28!, states=2^2)
  - shared fields: `@errors | @fn_name`
  - surface: `src/mir/mir_checker.rb:347` (initialize) ; `src/mir/mir_checker.rb:356` (check_fn!) ; `src/mir/mir_checker.rb:450` (verify_return_transfers_heap!) ; `src/mir/mir_checker.rb:466` (verify_alloc_marks_typed!) ; `src/mir/mir_checker.rb:478` (verify_structural_ownership_contracts!) ; `src/mir/mir_checker.rb:509` (verify_ownership_consumption_operands!)
- `MIRLoweringSchemas` (`src/mir/lowering/schema_registry.rb:41` (MIRLoweringSchemas)) -- implicit lifecycle score **80** (public=8, state methods=8, writers=2, fields=4, shared=4, flows=8!, states=2^4)
  - shared fields: `@enum_schemas | @lookup_proc | @struct_schemas | @union_schemas`
  - surface: `src/mir/lowering/schema_registry.rb:41` (initialize) ; `src/mir/lowering/schema_registry.rb:49` (lookup_proc) ; `src/mir/lowering/schema_registry.rb:54` (lookup) ; `src/mir/lowering/schema_registry.rb:60` (replace_lookup_proc!) ; `src/mir/lowering/schema_registry.rb:65` (register_enum) ; `src/mir/lowering/schema_registry.rb:70` (register_struct)
- `StackVerifier` (`src/tools/stack_verifier.rb:34` (StackVerifier)) -- implicit lifecycle score **32** (public=13, state methods=4, writers=2, fields=3, shared=3, flows=4!, states=2^3)
  - shared fields: `@binary_path | @module_prefix | @objdump_output`
  - surface: `src/tools/stack_verifier.rb:34` (initialize) ; `src/tools/stack_verifier.rb:42` (objdump_output) ; `src/tools/stack_verifier.rb:62` (extract_frame_sizes) ; `src/tools/stack_verifier.rb:196` (verify_tail_calls)
- `EffectSet` (`src/semantic/effect_set.rb:44` (EffectSet)) -- implicit lifecycle score **20** (public=9, state methods=8, writers=2, fields=2, shared=1, flows=8!, states=2^2)
  - shared fields: `@effects`
  - surface: `src/semantic/effect_set.rb:44` (initialize) ; `src/semantic/effect_set.rb:55` (empty) ; `src/semantic/effect_set.rb:61` (include?) ; `src/semantic/effect_set.rb:66` (empty?) ; `src/semantic/effect_set.rb:71` (union) ; `src/semantic/effect_set.rb:76` (==)
- `Program` (`src/mir/mir.rb:898` (Program)) -- implicit lifecycle score **10** (public=3, state methods=3, writers=2, fields=2, shared=1, flows=3!, states=2^2)
  - shared fields: `@pass_state`
  - surface: `src/mir/mir.rb:898` (initialize) ; `src/mir/mir.rb:904` (mir_pass_state) ; `src/mir/mir.rb:909` (mir_pass_state=)

## Missing Abstractions (174)
_guard tuple recomputed across >=2 decision units_

- **[case_dispatch]** support=6 scatter=6 rank=36
  - tuple: `AST::AllOp | AST::AnyOp | AST::AverageOp | AST::CountOp | AST::FindOp | AST::MaxOp | AST::MinOp | AST::SumOp`
  - `src/ast/ast.rb:2125` (pipeline_range_fold?) ; `src/mir/lower/pipeline/pipeline_binding_chain_lowerer.rb:186` (fold_expression) ; `src/mir/lower/pipeline/pipeline_binding_chain_lowerer.rb:194` (lower_binding_fold) ; `src/mir/lower/pipeline/pipeline_host.rb:768` (build_soa_scalar_fold_block) ; `src/mir/lower/pipeline/pipeline_range_lowerer.rb:501` (scalar_fold_plan) ; `src/mir/lower/pipeline/pipeline_scalar_lowerer.rb:32` (lower)
- **[conjunction]** support=5 scatter=5 rank=25
  - tuple: `char <= "9" | char >= "0"`
  - `src/backends/zig_type.rb:25` (primitive_numeric_identifier?) ; `src/backends/zig_type.rb:34` (float_identifier?) ; `src/backends/zig_type.rb:44` (integer_identifier?) ; `src/mir/fsm_transform/emit.rb:553` (decimal_digits?) ; `src/mir/lower/pipeline/pipeline_batch_window_lowerer.rb:168` (decimal_literal?)
- **[case_dispatch]** support=5 scatter=5 rank=25
  - tuple: `'END' | END_BLOCK_OPENERS`
  - `src/tools/formatter.rb:534` (find_match_block_end) ; `src/tools/formatter.rb:598` (scan_match_arms) ; `src/tools/formatter.rb:638` (build_match_arm) ; `src/tools/formatter.rb:757` (emit_match_body) ; `src/tools/formatter.rb:1242` (matching_end)
- **[case_dispatch]** support=4 scatter=4 rank=16
  - tuple: `AST::GetField | AST::GetIndex | AST::Identifier`
  - `src/annotator/domains/variables.rb:578` (visit_Assignment) ; `src/annotator/helpers/capabilities.rb:140` (cap_var_label) ; `src/ast/ast.rb:433` (root_identifier) ; `src/ast/parser.rb:3977` (deep_clone_node)
- **[case_dispatch]** support=4 scatter=4 rank=16
  - tuple: `:parallel | :shared`
  - `src/mir/fsm_transform/emit.rb:1484` (profile_dispatch_id) ; `src/mir/lowering/concurrency.rb:673` (profile_dispatch_numeric_id) ; `src/mir/lowering/concurrency.rb:710` (profile_dispatch_symbol) ; `src/mir/mir_lowering.rb:3224` (profile_dispatch_id)
- **[conjunction]** support=4 scatter=4 rank=16
  - tuple: `!metadata.empty? | metadata`
  - `src/mir/mir_checker.rb:1937` (verify_allocator_closed_set!) ; `src/mir/mir_checker.rb:1954` (verify_allocator_metadata_targets!) ; `src/mir/mir_checker.rb:2100` (verify_cross_frame_param_alloc!) ; `src/mir/mir_checker.rb:2680` (expr_has_frame_alloc?)
- **[conjunction]** support=4 scatter=4 rank=16
  - tuple: `j < toks.length | toks[j].type == :NL`
  - `src/tools/formatter.rb:893` (skip_nls) ; `src/tools/formatter.rb:2306` (detect_recover_stages) ; `src/tools/formatter.rb:2448` (emit_record_type) ; `src/tools/formatter.rb:2491` (emit_stmt_terminator)
- **[conjunction]** support=4 scatter=3 rank=12
  - tuple: `cursor.is_a?(AST::BinaryOp) | cursor.smooth?`
  - `src/backends/pipeline_rewriter.rb:280` (collect_chain) ; `src/mir/lower/pipeline/pipeline_binding_chain_lowerer.rb:73` (unwrap_chain) ; `src/mir/lower/pipeline/pipeline_binding_chain_lowerer.rb:83` (unwrap_chain) ; `src/mir/lower/pipeline/pipeline_range_lowerer.rb:289` (unwrap_range_chain)
- **[case_dispatch]** support=4 scatter=3 rank=12
  - tuple: `AST::Assignment | AST::BindExpr | AST::VarDecl`
  - `src/mir/fsm_transform/liveness.rb:209` (collect_defs) ; `src/mir/mir_pass.rb:548` (collect_consumed_names) ; `src/mir/mir_pass.rb:566` (collect_consumed_names) ; `src/tools/migration_suggester_helpers.rb:88` (walk_recursive)
- **[conjunction]** support=4 scatter=3 rank=12
  - tuple: `!target.to_s.empty? | target`
  - `src/mir/mir_checker.rb:1879` (allocator_metadata_target) ; `src/mir/mir_checker.rb:1882` (allocator_metadata_target) ; `src/mir/mir_checker.rb:1956` (verify_allocator_metadata_targets!) ; `src/mir/mir_checker.rb:2036` (verify_allocator_metadata_contracts!)
- **[case_dispatch]** support=3 scatter=3 rank=9
  - tuple: `:ATOMIC | :LOCKED | :VERSIONED`
  - `src/annotator/annotator.rb:455` (with_match_family_effects) ; `src/mir/mir_emitter.rb:996` (emit_with_match_probe) ; `src/mir/mir_emitter.rb:1013` (emit_with_match_prelude)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `slot.respond_to?(:shape) | slot.shape`
  - `src/annotator/annotator.rb:665` (emit_auto_shape_resolved_findings!) ; `src/annotator/helpers/fixable_helpers.rb:1476` (emit_auto_resolved_finding!) ; `src/annotator/helpers/fixable_helpers.rb:1638` (auto_slot_label)
- **[case_dispatch]** support=3 scatter=3 rank=9
  - tuple: `:block | :exit`
  - `src/annotator/domains/errors.rb:189` (visit_SyncPolicyDecl) ; `src/annotator/domains/execution_boundaries.rb:539` (validate_snapshot_match_arms!) ; `src/mir/lowering/capabilities.rb:661` (build_fallible_clause_mir)
- **[case_dispatch]** support=3 scatter=3 rank=9
  - tuple: `:kind | :type`
  - `src/annotator/domains/execution_boundaries.rb:575` (resolve_error_selectors!) ; `src/annotator/helpers/lock_helper.rb:425` (verify_handler_reachability!) ; `src/annotator/helpers/with_match_check.rb:424` (handled_error_set)
- **[case_dispatch]** support=3 scatter=3 rank=9
  - tuple: `:local | :param | :return`
  - `src/annotator/helpers/auto_inference.rb:633` (stamp_slot!) ; `src/annotator/helpers/fixable_helpers.rb:1604` (slot_id_for) ; `src/annotator/helpers/fixable_helpers.rb:1647` (auto_slot_label)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `!direct | reachable_from_self?(name)`
  - `src/annotator/helpers/reentrance.rb:407` (validate_not_logical_recursion!) ; `src/annotator/helpers/reentrance.rb:436` (validate_max_depth_mutual_cycle!) ; `src/annotator/helpers/reentrance.rb:488` (validate_thunk_recursion!)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `!node.else_branch.empty? | node.else_branch`
  - `src/ast/ast.rb:622` (body_slots) ; `src/mir/lowering/control_flow.rb:137` (lower_if) ; `src/mir/lowering/control_flow.rb:157` (lower_if_bind)
- **[case_dispatch]** support=3 scatter=3 rank=9
  - tuple: `AST::LimitOp | AST::SelectOp | AST::SkipOp | AST::TakeWhileOp | AST::TapOp | AST::WhereOp`
  - `src/ast/ast.rb:2093` (pipeline_fusible_stage?) ; `src/backends/pipeline_rewriter.rb:500` (build_recursive_body) ; `src/mir/lower/pipeline/pipeline_range_lowerer.rb:317` (build_lazy_range_prefix)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `atomic? | indirect?`
  - `src/ast/ast.rb:2192` (atomic_ptr?) ; `src/ast/symbol_entry.rb:189` (atomic_ptr?) ; `src/ast/type.rb:1733` (atomic_ptr?)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `!source.empty? | source`
  - `src/ast/syntax_typo_scanner.rb:41` (scan!) ; `src/mir/lowering/capabilities.rb:842` (lower_pre_clauses) ; `src/mir/lowering/functions.rb:839` (build_post_outer_fn)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `!shard_count | source.shard_count`
  - `src/ast/type.rb:1252` (copy_collection_shape_from!) ; `src/ast/type.rb:1260` (copy_topology_from!) ; `src/ast/type.rb:1270` (copy_declared_collection_modifiers_from!)
- **[case_dispatch]** support=3 scatter=3 rank=9
  - tuple: `AST::EnumDef | AST::StructDef | AST::UnionDef`
  - `src/backends/compiler_frontend.rb:93` (compile) ; `src/backends/importer.rb:207` (compile_module_mir) ; `src/mir/mir_lowering.rb:3120` (visible_imported_type_names)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `node.is_a?(AST::BinaryOp) | node.smooth?`
  - `src/backends/pipeline_rewriter.rb:34` (rewrite!) ; `src/backends/pipeline_rewriter.rb:256` (binding_source?) ; `src/mir/lower/pipeline/pipeline_range_lowerer.rb:285` (unwrap_range_chain)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `!digits.empty? | !digits.nil? | digits.each_char.all? { |char| char >= "0" && char <= "9" }`
  - `src/backends/zig_type.rb:25` (primitive_numeric_identifier?) ; `src/backends/zig_type.rb:34` (float_identifier?) ; `src/backends/zig_type.rb:44` (integer_identifier?)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `node.is_a?(AST::BindExpr) | node.mode == :assign`
  - `src/mir/cleanup_classifier.rb:264` (stamp_binding_default_scope!) ; `src/mir/cleanup_classifier.rb:440` (classify_cleanup_binding_node) ; `src/semantic/escape_analysis.rb:772` (assigned_binding_name)
- ...(+149 more)

## Reification Misses (6)
_an existing predicate reinvented inline -- invariant #16_

- predicate `atomic?` reinvented inline at `src/ast/parser.rb:2871` (parse_type_annotation) (`sync == :atomic`)
- predicate `captured_value?` reinvented inline at `src/mir/fiber_ctx_builder.rb:153` (cleanup_mir_for) (`cleanup_plan.kind == CaptureCleanupKind::CapturedValue`)
- predicate `frame?` reinvented inline at `src/semantic/local_binding_facts.rb:100` (binding_frame_allocates?) (`alloc == :frame`)
- predicate `indirect?` reinvented inline at `src/ast/parser.rb:2871` (parse_type_annotation) (`layout == :indirect`)
- predicate `moved?` reinvented inline at `src/annotator/domains/control_flow.rb:78` (analyze_control_flow_branches) (`state == :moved`)
- predicate `uniform_value?` reinvented inline at `src/mir/fiber_ctx_builder.rb:154` (cleanup_mir_for) (`cleanup_plan.kind == CaptureCleanupKind::UniformValue`)

## Semantic Predicate Aliases (5)
_one decision, multiple names (receiver/polarity folded)_

- `enum? = resource? = union? = struct? = suspend? = mir? = stmt? = expr? = has_own_frame? = needs_capture_site_annotation?` == `true`
  - `src/ast/schemas.rb:34` (enum?) ; `src/ast/schemas.rb:146` (resource?) ; `src/ast/schemas.rb:273` (union?) ; `src/ast/schemas.rb:325` (struct?) ; `src/mir/fsm_transform/segments.rb:51` (suspend?) ; `src/mir/fsm_transform/segments.rb:69` (suspend?) ; `src/mir/mir.rb:382` (mir?) ; `src/mir/mir.rb:451` (stmt?) ; `src/mir/mir.rb:473` (expr?) ; `src/mir/mir.rb:935` (has_own_frame?) ; `src/mir/mir.rb:1624` (expr?) ; `src/mir/mir.rb:1651` (expr?) ; `src/mir/mir.rb:2027` (expr?) ; `src/mir/mir.rb:2038` (expr?) ; `src/mir/mir.rb:2055` (expr?) ; `src/mir/mir.rb:2086` (expr?) ; `src/mir/mir.rb:2546` (stmt?) ; `src/mir/mir.rb:2562` (stmt?) ; `src/mir/mir.rb:3117` (stmt?) ; `src/mir/mir.rb:3153` (stmt?) ; `src/mir/mir.rb:3187` (stmt?) ; `src/mir/mir.rb:3226` (stmt?) ; `src/mir/mir.rb:3239` (stmt?) ; `src/mir/mir.rb:3278` (stmt?) ; `src/mir/mir.rb:3307` (stmt?) ; `src/mir/mir.rb:3328` (stmt?) ; `src/mir/mir.rb:3340` (stmt?) ; `src/mir/mir.rb:3347` (stmt?) ; `src/mir/mir.rb:3354` (stmt?) ; `src/mir/mir.rb:3366` (stmt?) ; `src/mir/mir.rb:3373` (stmt?) ; `src/mir/mir.rb:3381` (stmt?) ; `src/mir/mir.rb:3397` (stmt?) ; `src/mir/mir.rb:3443` (stmt?) ; `src/mir/mir.rb:3456` (stmt?) ; `src/mir/mir.rb:4328` (expr?) ; `src/mir/mir.rb:4687` (expr?) ; `src/semantic/capture_strategy.rb:107` (needs_capture_site_annotation?) ; `src/semantic/capture_strategy.rb:127` (needs_capture_site_annotation?)
- `wildcard? = union? = struct? = resource? = enum? = blank? = stmt? = expr? = needs_capture_site_annotation?` == `false`
  - `src/ast/ast.rb:1654` (wildcard?) ; `src/ast/ast.rb:1815` (wildcard?) ; `src/ast/ast.rb:1830` (wildcard?) ; `src/ast/schemas.rb:36` (union?) ; `src/ast/schemas.rb:38` (struct?) ; `src/ast/schemas.rb:40` (resource?) ; `src/ast/schemas.rb:148` (union?) ; `src/ast/schemas.rb:150` (enum?) ; `src/ast/schemas.rb:152` (struct?) ; `src/ast/schemas.rb:275` (enum?) ; `src/ast/schemas.rb:277` (struct?) ; `src/ast/schemas.rb:279` (resource?) ; `src/ast/schemas.rb:327` (union?) ; `src/ast/schemas.rb:329` (enum?) ; `src/ast/schemas.rb:331` (resource?) ; `src/mir/fsm_transform/emit.rb:84` (blank?) ; `src/mir/mir.rb:384` (stmt?) ; `src/mir/mir.rb:386` (expr?) ; `src/semantic/capture_strategy.rb:70` (needs_capture_site_annotation?) ; `src/semantic/capture_strategy.rb:86` (needs_capture_site_annotation?) ; `src/semantic/capture_strategy.rb:143` (needs_capture_site_annotation?)
- `locked_sync? = lock_sync?` == `locked? || write_locked?`
  - `src/ast/ast.rb:2204` (locked_sync?) ; `src/ast/symbol_entry.rb:220` (lock_sync?)
- `materializer_bc_target? = range_bc_target?` == `bc_target.call`
  - `src/mir/lower/pipeline/pipeline_materializer.rb:160` (materializer_bc_target?) ; `src/mir/lower/pipeline/pipeline_range_lowerer.rb:235` (range_bc_target?)
- `semicolon_required? = zig_statement_semicolon_required?` == `stmt.expr? && !stripped.end_with?(";") && !stripped.end_with?("}") && !stripped.end_with?("{")`
  - `src/mir/mir_emitter.rb:2662` (semicolon_required?) ; `src/mir/mir_lowering.rb:3407` (zig_statement_semicolon_required?)

## Exact Predicate Aliases (16)
_identical one-line predicate body under >=2 names_

- `enum? = resource? = union? = struct? = suspend? = mir? = stmt? = expr? = has_own_frame? = needs_capture_site_annotation?` == `true`
  - `src/ast/schemas.rb:34` (enum?) ; `src/ast/schemas.rb:146` (resource?) ; `src/ast/schemas.rb:273` (union?) ; `src/ast/schemas.rb:325` (struct?) ; `src/mir/fsm_transform/segments.rb:51` (suspend?) ; `src/mir/fsm_transform/segments.rb:69` (suspend?) ; `src/mir/mir.rb:382` (mir?) ; `src/mir/mir.rb:451` (stmt?) ; `src/mir/mir.rb:473` (expr?) ; `src/mir/mir.rb:935` (has_own_frame?) ; `src/mir/mir.rb:1624` (expr?) ; `src/mir/mir.rb:1651` (expr?) ; `src/mir/mir.rb:2027` (expr?) ; `src/mir/mir.rb:2038` (expr?) ; `src/mir/mir.rb:2055` (expr?) ; `src/mir/mir.rb:2086` (expr?) ; `src/mir/mir.rb:2546` (stmt?) ; `src/mir/mir.rb:2562` (stmt?) ; `src/mir/mir.rb:3117` (stmt?) ; `src/mir/mir.rb:3153` (stmt?) ; `src/mir/mir.rb:3187` (stmt?) ; `src/mir/mir.rb:3226` (stmt?) ; `src/mir/mir.rb:3239` (stmt?) ; `src/mir/mir.rb:3278` (stmt?) ; `src/mir/mir.rb:3307` (stmt?) ; `src/mir/mir.rb:3328` (stmt?) ; `src/mir/mir.rb:3340` (stmt?) ; `src/mir/mir.rb:3347` (stmt?) ; `src/mir/mir.rb:3354` (stmt?) ; `src/mir/mir.rb:3366` (stmt?) ; `src/mir/mir.rb:3373` (stmt?) ; `src/mir/mir.rb:3381` (stmt?) ; `src/mir/mir.rb:3397` (stmt?) ; `src/mir/mir.rb:3443` (stmt?) ; `src/mir/mir.rb:3456` (stmt?) ; `src/mir/mir.rb:4328` (expr?) ; `src/mir/mir.rb:4687` (expr?) ; `src/semantic/capture_strategy.rb:107` (needs_capture_site_annotation?) ; `src/semantic/capture_strategy.rb:127` (needs_capture_site_annotation?)
- `wildcard? = union? = struct? = resource? = enum? = blank? = stmt? = expr? = needs_capture_site_annotation?` == `false`
  - `src/ast/ast.rb:1654` (wildcard?) ; `src/ast/ast.rb:1815` (wildcard?) ; `src/ast/ast.rb:1830` (wildcard?) ; `src/ast/schemas.rb:36` (union?) ; `src/ast/schemas.rb:38` (struct?) ; `src/ast/schemas.rb:40` (resource?) ; `src/ast/schemas.rb:148` (union?) ; `src/ast/schemas.rb:150` (enum?) ; `src/ast/schemas.rb:152` (struct?) ; `src/ast/schemas.rb:275` (enum?) ; `src/ast/schemas.rb:277` (struct?) ; `src/ast/schemas.rb:279` (resource?) ; `src/ast/schemas.rb:327` (union?) ; `src/ast/schemas.rb:329` (enum?) ; `src/ast/schemas.rb:331` (resource?) ; `src/mir/fsm_transform/emit.rb:84` (blank?) ; `src/mir/mir.rb:384` (stmt?) ; `src/mir/mir.rb:386` (expr?) ; `src/semantic/capture_strategy.rb:70` (needs_capture_site_annotation?) ; `src/semantic/capture_strategy.rb:86` (needs_capture_site_annotation?) ; `src/semantic/capture_strategy.rb:143` (needs_capture_site_annotation?)
- `child_bodies = ownership_source_exprs = pre_terminator_transfer_marks = marker_plan` == `[]`
  - `src/ast/ast.rb:869` (child_bodies) ; `src/mir/mir.rb:3861` (ownership_source_exprs) ; `src/mir/mir_lowering.rb:1876` (pre_terminator_transfer_marks) ; `src/semantic/capture_strategy.rb:68` (marker_plan) ; `src/semantic/capture_strategy.rb:84` (marker_plan) ; `src/semantic/capture_strategy.rb:141` (marker_plan)
- `pin_heap_for_sync_wrapper! = pin_heap_for_indirect! = pin_heap_for_collection!` == `mark_heap_allocated!`
  - `src/ast/type.rb:1092` (pin_heap_for_sync_wrapper!) ; `src/ast/type.rb:1097` (pin_heap_for_indirect!) ; `src/ast/type.rb:1102` (pin_heap_for_collection!)
- `child_exprs = ownership_source_exprs = owned_position_source_exprs` == `EMPTY_CHILD_EXPRS`
  - `src/mir/mir.rb:390` (child_exprs) ; `src/mir/mir.rb:392` (ownership_source_exprs) ; `src/mir/mir.rb:394` (owned_position_source_exprs)
- `emit_rc_retain = emit_rc_downgrade = emit_weak_upgrade` == `"CheatLib.#{node.func}(#{node.zig_base}, #{emit(node.source)})"`
  - `src/mir/mir_emitter.rb:2186` (emit_rc_retain) ; `src/mir/mir_emitter.rb:2196` (emit_rc_downgrade) ; `src/mir/mir_emitter.rb:2201` (emit_weak_upgrade)
- `locked_sync? = lock_sync?` == `locked? || write_locked?`
  - `src/ast/ast.rb:2204` (locked_sync?) ; `src/ast/symbol_entry.rb:220` (lock_sync?)
- `stream_allocating_args = stream_each_args` == `[ apply_ident, is_inf, MIR::AllocatorRef.new(alloc), MIR::Ident.new("rt"), source_pointer, worker_count, capacity, batch_size, parallel, task_config, context_arg, ]`
  - `src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb:129` (stream_allocating_args) ; `src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb:146` (stream_each_args)
- `materializer_visit_mir = range_visit_mir` == `@visit_mir.call(node)`
  - `src/mir/lower/pipeline/pipeline_materializer.rb:131` (materializer_visit_mir) ; `src/mir/lower/pipeline/pipeline_range_lowerer.rb:215` (range_visit_mir)
- `materializer_bc_target? = range_bc_target?` == `@bc_target.call`
  - `src/mir/lower/pipeline/pipeline_materializer.rb:160` (materializer_bc_target?) ; `src/mir/lower/pipeline/pipeline_range_lowerer.rb:235` (range_bc_target?)
- `materializer_schema_lookup = range_schema_lookup` == `@schema_lookup.call`
  - `src/mir/lower/pipeline/pipeline_materializer.rb:165` (materializer_schema_lookup) ; `src/mir/lower/pipeline/pipeline_range_lowerer.rb:250` (range_schema_lookup)
- `materializer_next_label = range_next_label` == `@next_label.call`
  - `src/mir/lower/pipeline/pipeline_materializer.rb:170` (materializer_next_label) ; `src/mir/lower/pipeline/pipeline_range_lowerer.rb:240` (range_next_label)
- `profile_dispatch_numeric_id = profile_dispatch_id` == `case dispatch when :parallel then 2 when :shared then 3 else 1 end`
  - `src/mir/lowering/concurrency.rb:672` (profile_dispatch_numeric_id) ; `src/mir/mir_lowering.rb:3223` (profile_dispatch_id)
- `ownership_source_exprs = owned_position_source_exprs` == `child_exprs`
  - `src/mir/mir.rb:1282` (ownership_source_exprs) ; `src/mir/mir.rb:1284` (owned_position_source_exprs) ; `src/mir/mir.rb:2711` (ownership_source_exprs) ; `src/mir/mir.rb:2933` (ownership_source_exprs) ; `src/mir/mir.rb:2954` (ownership_source_exprs) ; `src/mir/mir.rb:3029` (ownership_source_exprs) ; `src/mir/mir.rb:3052` (ownership_source_exprs) ; `src/mir/mir.rb:3822` (ownership_source_exprs) ; `src/mir/mir.rb:3838` (ownership_source_exprs) ; `src/mir/mir.rb:3940` (ownership_source_exprs) ; `src/mir/mir.rb:3942` (owned_position_source_exprs) ; `src/mir/mir.rb:3962` (ownership_source_exprs) ; `src/mir/mir.rb:3964` (owned_position_source_exprs) ; `src/mir/mir.rb:3990` (ownership_source_exprs) ; `src/mir/mir.rb:3992` (owned_position_source_exprs) ; `src/mir/mir.rb:4022` (ownership_source_exprs) ; `src/mir/mir.rb:4024` (owned_position_source_exprs) ; `src/mir/mir.rb:4087` (ownership_source_exprs) ; `src/mir/mir.rb:4089` (owned_position_source_exprs) ; `src/mir/mir.rb:4233` (ownership_source_exprs) ; `src/mir/mir.rb:4235` (owned_position_source_exprs) ; `src/mir/mir.rb:4279` (ownership_source_exprs) ; `src/mir/mir.rb:4295` (ownership_source_exprs) ; `src/mir/mir.rb:4333` (ownership_source_exprs) ; `src/mir/mir.rb:4335` (owned_position_source_exprs)
- `emit_thunk_return_or_pop = emit_test_preamble` == `<<~ZIG.chomp`
  - `src/mir/mir_emitter.rb:1828` (emit_thunk_return_or_pop) ; `src/mir/mir_emitter.rb:2295` (emit_test_preamble)
- `semicolon_required? = zig_statement_semicolon_required?` == `stmt.expr? && !stripped.end_with?(";") && !stripped.end_with?("}") && !stripped.end_with?("{")`
  - `src/mir/mir_emitter.rb:2662` (semicolon_required?) ; `src/mir/mir_lowering.rb:3407` (zig_statement_semicolon_required?)

## Inconsistent Rename Clones (71)
_pasted block with inconsistent identifier mapping -- *POSSIBLE* missed rename bug_

- *POSSIBLE* `src/tools/formatter.rb:2163` (emit_bg_do_wrapped) clone of `src/tools/formatter.rb:739` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2163` (emit_bg_do_wrapped) clone of `src/tools/formatter.rb:836` (emit_fn_block): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2163` (emit_bg_do_wrapped) clone of `src/tools/formatter.rb:849` (emit_fn_block): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2163` (emit_bg_do_wrapped) clone of `src/tools/formatter.rb:954` (emit_fn_signature_wrapped): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2163` (emit_bg_do_wrapped) clone of `src/tools/formatter.rb:1069` (emit_fn_params_only_wrapped): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2163` (emit_bg_do_wrapped) clone of `src/tools/formatter.rb:1328` (expand_if_while_for): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2163` (emit_bg_do_wrapped) clone of `src/tools/formatter.rb:1330` (expand_if_while_for): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2163` (emit_bg_do_wrapped) clone of `src/tools/formatter.rb:1332` (expand_if_while_for): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2163` (emit_bg_do_wrapped) clone of `src/tools/formatter.rb:1982` (emit_wrapped_args): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:843` (emit_fn_block) clone of `src/tools/formatter.rb:739` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:855` (emit_fn_block) clone of `src/tools/formatter.rb:739` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:1074` (emit_fn_params_only_wrapped) clone of `src/tools/formatter.rb:739` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:1074` (emit_fn_params_only_wrapped) clone of `src/tools/formatter.rb:836` (emit_fn_block): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:1074` (emit_fn_params_only_wrapped) clone of `src/tools/formatter.rb:849` (emit_fn_block): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:1074` (emit_fn_params_only_wrapped) clone of `src/tools/formatter.rb:954` (emit_fn_signature_wrapped): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:959` (emit_fn_signature_wrapped) clone of `src/tools/formatter.rb:739` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:959` (emit_fn_signature_wrapped) clone of `src/tools/formatter.rb:836` (emit_fn_block): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:959` (emit_fn_signature_wrapped) clone of `src/tools/formatter.rb:849` (emit_fn_block): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2438` (emit_record_type) clone of `src/tools/formatter.rb:739` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2438` (emit_record_type) clone of `src/tools/formatter.rb:836` (emit_fn_block): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2438` (emit_record_type) clone of `src/tools/formatter.rb:849` (emit_fn_block): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2438` (emit_record_type) clone of `src/tools/formatter.rb:954` (emit_fn_signature_wrapped): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2438` (emit_record_type) clone of `src/tools/formatter.rb:1069` (emit_fn_params_only_wrapped): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2438` (emit_record_type) clone of `src/tools/formatter.rb:1328` (expand_if_while_for): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2438` (emit_record_type) clone of `src/tools/formatter.rb:1330` (expand_if_while_for): ref var `+` spelled ["-", "+"] here
- ...(+46 more)

## Flay Similarity (Type-2/3) (54)
_Flay structural clone pressure: Type-2 renamed clones and Type-3 fuzzy clones -- refactor pressure, not a verdict_

- *POSSIBLE* [type2] mass=340 node=`when` `src/backends/pipeline_rewriter.rb:530` (build_recursive_body) ; `src/backends/pipeline_rewriter.rb:557` (build_recursive_body)
- *POSSIBLE* [type2] mass=252 node=`defn` `src/annotator/helpers/pipe_analysis.rb:938` (analyze_any_op) ; `src/annotator/helpers/pipe_analysis.rb:962` (analyze_all_op) ; `src/annotator/helpers/pipe_analysis.rb:986` (analyze_count_op)
- *POSSIBLE* [type2] mass=230 node=`defn` `src/mir/lower/pipeline/pipeline_scalar_lowerer.rb:111` (lower_min) ; `src/mir/lower/pipeline/pipeline_scalar_lowerer.rb:137` (lower_max)
- *POSSIBLE* [type2] mass=210 node=`iter` `src/ast/parser.rb:432` ((top-level)) ; `src/ast/parser.rb:439` ((top-level)) ; `src/ast/parser.rb:446` ((top-level)) ; `src/ast/parser.rb:453` ((top-level)) (+1 more)
- *POSSIBLE* [type2] mass=188 node=`iter` `src/ast/parser.rb:396` ((top-level)) ; `src/ast/parser.rb:405` ((top-level)) ; `src/ast/parser.rb:414` ((top-level)) ; `src/ast/parser.rb:423` ((top-level))
- *POSSIBLE* [type2] mass=180 node=`defn` `src/annotator/helpers/pipe_analysis.rb:1067` (analyze_min_op) ; `src/annotator/helpers/pipe_analysis.rb:1092` (analyze_max_op)
- *POSSIBLE* [type2] mass=170 node=`when` `src/mir/lower/pipeline/pipeline_binding_chain_lowerer.rb:224` (lower_binding_fold) ; `src/mir/lower/pipeline/pipeline_binding_chain_lowerer.rb:235` (lower_binding_fold)
- *POSSIBLE* [type2] mass=170 node=`when` `src/mir/lower/pipeline/pipeline_host.rb:788` (build_soa_scalar_fold_block) ; `src/mir/lower/pipeline/pipeline_host.rb:795` (build_soa_scalar_fold_block)
- *POSSIBLE* [type2] mass=168 node=`defn` `src/mir/mir.rb:1187` (body_slots) ; `src/mir/mir.rb:1216` (body_slots) ; `src/mir/mir.rb:1244` (body_slots) ; `src/mir/mir.rb:2615` (body_slots)
- *POSSIBLE* [type2] mass=148 node=`or` `src/ast/ast.rb:536` (statement_result_void?) ; `src/mir/control_flow.rb:1754` (statement_like_expression_container?)
- *POSSIBLE* [type2] mass=144 node=`defn` `src/mir/fsm_wrapper_emitter.rb:58` (render_io_body) ; `src/mir/fsm_wrapper_emitter.rb:75` (render_b1_body) ; `src/mir/fsm_wrapper_emitter.rb:252` (render_generic_body)
- *POSSIBLE* [type2] mass=134 node=`cdecl` `src/mir/mir.rb:1396` ((top-level)) ; `src/mir/mir.rb:1415` ((top-level))
- *POSSIBLE* [type2] mass=134 node=`defn` `src/mir/thunk_transform/recursive_splitter.rb:172` (match_mutual_base_case) ; `src/mir/thunk_transform/recursive_splitter.rb:216` (match_base_case)
- *POSSIBLE* [type2] mass=132 node=`if` `src/annotator/helpers/fixable_helpers.rb:112` (emit_registry_mismatch!) ; `src/annotator/helpers/fixable_helpers.rb:151` (emit_typo_suggestion!) ; `src/annotator/helpers/fixable_helpers.rb:219` (emit_variant_typo!)
- *POSSIBLE* [type2] mass=122 node=`defn` `src/mir/lower/pipeline/pipeline_range_lowerer.rb:1038` (replace_zig_identifier) ; `src/mir/mir_emitter.rb:684` (replace_emit_identifier)
- *POSSIBLE* [type2] mass=114 node=`iter` `src/ast/std_lib.rb:1238` ((top-level)) ; `src/ast/std_lib.rb:1256` ((top-level)) ; `src/ast/std_lib.rb:1273` ((top-level))
- *POSSIBLE* [type2] mass=114 node=`hash` `src/tools/doctor.rb:677` (section_locks) ; `src/tools/pprof_converter.rb:203` (convert_locks)
- *POSSIBLE* [type2] mass=108 node=`cdecl` `src/mir/mir.rb:3113` ((top-level)) ; `src/mir/mir.rb:3220` ((top-level))
- *POSSIBLE* [type2] mass=100 node=`if` `src/annotator/helpers/capabilities.rb:554` (visit_pre_clauses!) ; `src/annotator/helpers/effects.rb:693` (enforce_fallible_returns!)
- *POSSIBLE* [type2] mass=99 node=`defn` `src/mir/mir.rb:1105` (body_slots) ; `src/mir/mir.rb:1125` (body_slots) ; `src/mir/mir.rb:3243` (body_slots)
- *POSSIBLE* [type2] mass=88 node=`if` `src/ast/parser.rb:3718` (parse_branch_prefix) ; `src/ast/parser.rb:3798` (parse_bg_prefix)
- *POSSIBLE* [type2] mass=86 node=`if` `src/annotator/domains/control_flow.rb:213` (annotate_struct_pattern!) ; `src/annotator/domains/control_flow.rb:600` (emit_unknown_destructure_field!)
- *POSSIBLE* [type2] mass=86 node=`block` `src/ast/ast.rb:1747` ((top-level)) ; `src/ast/ast.rb:2238` ((top-level))
- *POSSIBLE* [type2] mass=86 node=`cdecl` `src/mir/mir.rb:4081` ((top-level)) ; `src/mir/mir.rb:4227` ((top-level))
- *POSSIBLE* [type2] mass=84 node=`defn` `src/annotator/helpers/fixable_helpers.rb:644` (emit_immutable_index_assignment_error!) ; `src/annotator/helpers/fixable_helpers.rb:708` (emit_capture_immutable_as_mutable_error!)
- ...(+29 more)

## Neglected Updates (649)
_co-written state, one write missing -- *POSSIBLE* redundant-state desync_

- *POSSIBLE* (support=5) `src/annotator/domains/control_flow.rb:102` (visit_BlockExpr) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/domains/control_flow.rb:543` (borrow_match_payload_binding!) writes `.storage` but NOT `.capture_analysis` (recv `current_scope.entry_for_write!(binding)`)
- *POSSIBLE* (support=5) `src/annotator/domains/errors.rb:454` (visit_ReturnNode) writes `.storage` but NOT `.capture_analysis` (recv `node.value`)
- *POSSIBLE* (support=5) `src/annotator/domains/execution_boundaries.rb:630` (visit_DoBlock) writes `.capture_analysis` but NOT `.storage` (recv `branch`)
- *POSSIBLE* (support=5) `src/annotator/domains/execution_boundaries.rb:679` (visit_BgStreamBlock) writes `.capture_analysis` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/domains/execution_boundaries.rb:745` (visit_BgBlock) writes `.capture_analysis` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/domains/execution_boundaries.rb:850` (visit_NextExpr) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/domains/expressions.rb:102` (visit_Literal) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/domains/expressions.rb:166` (visit_BinaryOp) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/domains/lifetimes.rb:37` (visit_MoveNode) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/domains/lifetimes.rb:81` (ensure_owned_value!) writes `.storage` but NOT `.capture_analysis` (recv `copy`)
- *POSSIBLE* (support=5) `src/annotator/domains/lifetimes.rb:133` (visit_CopyNode) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/domains/lifetimes.rb:167` (visit_Copy) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/domains/lifetimes.rb:224` (visit_FreezeNode) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/domains/lifetimes.rb:244` (visit_CloneNode) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/domains/lifetimes.rb:262` (visit_ShareNode) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/domains/lifetimes.rb:1111` (set_cleanup_alloc!) writes `.storage` but NOT `.capture_analysis` (recv `val`)
- *POSSIBLE* (support=5) `src/annotator/domains/member_access.rb:223` (visit_HashLit) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/domains/member_access.rb:423` (visit_ListLit) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/domains/member_access.rb:481` (visit_DefaultArrayLit) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/domains/variables.rb:14` (visit_VarDecl) writes `.storage` but NOT `.capture_analysis` (recv `node.value`)
- *POSSIBLE* (support=5) `src/annotator/domains/variables.rb:280` (visit_BindExpr) writes `.storage` but NOT `.capture_analysis` (recv `node.value`)
- *POSSIBLE* (support=5) `src/annotator/helpers/function_analysis.rb:1131` (verify_captures!) writes `.storage` but NOT `.capture_analysis` (recv `cap`)
- *POSSIBLE* (support=5) `src/annotator/helpers/generic_analysis.rb:600` (register_container_borrow!) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/helpers/pipe_analysis.rb:297` (analyze_collect_op) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- ...(+624 more)

## Derived-State Staleness (137)
_b = f(a); a later reassigned, b not recomputed -- *POSSIBLE* bug_

- *POSSIBLE* `src/mir/lowering/control_flow.rb:374` (for_each_loop_stmt): `key_ptr` derived from `for_id` (line 374); `for_id` reassigned line 439, `key_ptr` not recomputed
- *POSSIBLE* `src/tools/doctor.rb:165` (section_heap): `addrs` derived from `sites` (line 165); `sites` reassigned line 225, `addrs` not recomputed
- *POSSIBLE* `src/annotator/domains/errors.rb:379` (visit_ReturnNode): `expected_void_compatible` derived from `expected` (line 379); `expected` reassigned line 431, `expected_void_compatible` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:2817` (needs_space?): `a_is_struct_open` derived from `a_idx` (line 2817); `a_idx` reassigned line 2861, `a_is_struct_open` not recomputed
- *POSSIBLE* `src/mir/lowering/literals.rb:106` (lower_list_lit): `promise_zig` derived from `elem_zig` (line 106); `elem_zig` reassigned line 136, `promise_zig` not recomputed
- *POSSIBLE* `src/backends/pipeline_rewriter.rb:552` (build_recursive_body): `skip_if` derived from `cond` (line 552); `cond` reassigned line 577, `skip_if` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:2268` (find_s_chains): `s_idxs` derived from `i` (line 2268); `i` reassigned line 2292, `s_idxs` not recomputed
- *POSSIBLE* `src/ast/ast.rb:1096` (finalize_storage!): `value_sync` derived from `vt` (line 1096); `vt` reassigned line 1119, `value_sync` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:1189` (branch_end_for_inline_expansion): `t` derived from `j` (line 1189); `j` reassigned line 1212, `t` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:2270` (find_s_chains): `j` derived from `i` (line 2270); `i` reassigned line 2292, `j` not recomputed
- *POSSIBLE* `src/annotator/domains/variables.rb:557` (visit_Assignment): `tname` derived from `target` (line 557); `target` reassigned line 577, `tname` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:1640` (expand_concurrent_drops): `t` derived from `i` (line 1640); `i` reassigned line 1659, `t` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:2933` (capability_chain_colon?): `t` derived from `j` (line 2933); `j` reassigned line 2952, `t` not recomputed
- *POSSIBLE* `src/tools/clear_fix_support.rb:213` (extract_clear_heredocs): `body_start_idx` derived from `i` (line 213); `i` reassigned line 231, `body_start_idx` not recomputed
- *POSSIBLE* `src/mir/lowering/functions.rb:994` (cross_boundary_arg): `moved_arg` derived from `arg` (line 994); `arg` reassigned line 1011, `moved_arg` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:1124` (find_fn_arrow): `t` derived from `j` (line 1124); `j` reassigned line 1141, `t` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:1642` (expand_concurrent_drops): `paren_open` derived from `i` (line 1642); `i` reassigned line 1659, `paren_open` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:2935` (capability_chain_colon?): `k` derived from `j` (line 2935); `j` reassigned line 2952, `k` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:498` (match_block_start?): `t` derived from `j` (line 498); `j` reassigned line 514, `t` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:1234` (matching_end): `t` derived from `j` (line 1234); `j` reassigned line 1250, `t` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:1263` (one_liner_end): `t` derived from `j` (line 1263); `j` reassigned line 1279, `t` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:2272` (find_s_chains): `t` derived from `j` (line 2272); `j` reassigned line 2288, `t` not recomputed
- *POSSIBLE* `src/ast/diagnostic_examples.rb:96` (scan_file): `fix_scan` derived from `i` (line 96); `i` reassigned line 111, `fix_scan` not recomputed
- *POSSIBLE* `src/mir/fsm_transform/emit.rb:972` (build_recursive): `next_extra_idx` derived from `segment_specs` (line 972); `segment_specs` reassigned line 987, `next_extra_idx` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:1877` (process_call_arg_range): `t` derived from `i` (line 1877); `i` reassigned line 1892, `t` not recomputed
- ...(+112 more)

## Neglected Conditions (9)
_dispatch/conjunction minus one element -- *POSSIBLE* bug_

- *POSSIBLE* (support=4) `src/mir/lowering/capabilities.rb:153` (build_field_path_zig) -- MISSING `AST::GetIndex` from `AST::GetField | AST::GetIndex | AST::Identifier`
- *POSSIBLE* (support=4) `src/semantic/escape_analysis.rb:903` (function_facts) -- MISSING `AST::Assignment` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- *POSSIBLE* (support=4) `src/semantic/local_binding_facts.rb:75` (binding_decl_name) -- MISSING `AST::Assignment` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- *POSSIBLE* (support=4) `src/semantic/local_binding_facts.rb:87` (binding_entry) -- MISSING `AST::Assignment` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- *POSSIBLE* (support=4) `src/tools/atomic_migration_suggester.rb:133` (stmt_eligible?) -- MISSING `AST::VarDecl` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- *POSSIBLE* (support=4) `src/tools/atomic_ptr_migration_suggester.rb:125` (stmt_eligible?) -- MISSING `AST::VarDecl` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- *POSSIBLE* (support=3) `src/annotator/domains/execution_boundaries.rb:517` (validate_snapshot_match_arms!) -- MISSING `:LOCKED` from `:ATOMIC | :LOCKED | :VERSIONED`
- *POSSIBLE* (support=3) `src/mir/fsm_transform/recursive_splitter.rb:411` (emit_pivot) -- MISSING `AST::CatchBlock` from `AST::CatchBlock | AST::ForEach | AST::ForRange | AST::IfStatement | AST::WhileBindLoop | AST::WhileLoop | AST::WithBlock`
- *POSSIBLE* (support=3) `src/mir/mir_checker.rb:2558` (ownership_node_name) -- MISSING `MIR::ShardedMapGet` from `MIR::IndexedStore | MIR::RegistryCall | MIR::ShardedMapGet | MIR::ShardedMapPut`

## Neglected Path Conditions (1355)
_nested-if/&& guard set minus one atom -- *POSSIBLE* bug (noisy)_

- *POSSIBLE* (support=36) `src/tools/formatter.rb:506` (match_block_start?) -- MISSING `!bracket_open?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:532` (find_match_block_end) -- MISSING `!bracket_open?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:584` (scan_match_arms) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:584` (scan_match_arms) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:743` (emit_match_body) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:743` (emit_match_body) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:958` (emit_fn_signature_wrapped) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:958` (emit_fn_signature_wrapped) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:1073` (emit_fn_params_only_wrapped) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:1073` (emit_fn_params_only_wrapped) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:1193` (branch_end_for_inline_expansion) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:1193` (branch_end_for_inline_expansion) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:1238` (matching_end) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:1238` (matching_end) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:1611` (consume_on_segment) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:1611` (consume_on_segment) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:1986` (emit_wrapped_args) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:1986` (emit_wrapped_args) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:2061` (body_has_top_level_block?) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:2061` (body_has_top_level_block?) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:2162` (emit_bg_do_wrapped) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:2162` (emit_bg_do_wrapped) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:2212` (bg_body_has_strategy_arrow?) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:2212` (bg_body_has_strategy_arrow?) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=27) `src/mir/fsm_lowering.rb:111` (lower_step_stmts) -- MISSING `!last_is_assign || is_step_void` from `!last_is_assign || is_step_void | !no_result | last_mir | last_step`
- ...(+1330 more)

## Oversized Predicates (15)
_predicate with >3 condition atoms -- use an existing helper or extract a named predicate_

- *POSSIBLE* `src/annotator/domains/control_flow.rb:774` (visit_WhileLoop) -- 4 condition atoms in `(node.condition.is_a?(AST::Identifier) && node.condition.name == "TRUE") || (node.condition.is_a?(AST::Literal) && node.condition.value == true)`
  - atoms: `node.condition.is_a?(AST::Identifier) | node.condition.name == "TRUE" | node.condition.is_a?(AST::Literal) | node.condition.value == true`
- *POSSIBLE* `src/annotator/helpers/effects.rb:1006` (compute_stack_tiers!) -- 4 condition atoms in `effs.include?(HEAP) || effs.include?(BLOCKING) || effs.include?(EXTERN) || fn_node.runtime_stack_required?(recursion_yield_needed?(fn_node), declared_runtime_return)`
  - atoms: `effs.include?(HEAP) | effs.include?(BLOCKING) | effs.include?(EXTERN) | fn_node.runtime_stack_required?(recursion_yield_needed?(fn_node), declared_runtime_return)`
- *POSSIBLE* `src/ast/type.rb:769` (initialize) -- 7 condition atoms in `ownership || sync || layout || collection || shard_count || observable || observable_terminal`
  - atoms: `ownership | sync | layout | collection | shard_count | observable | observable_terminal`
- *POSSIBLE* `src/ast/type.rb:1243` (apply_bg_capture_symbol!) -- 4 condition atoms in `(storage == :multiowned || storage == :shared) && (!ownership || ownership == :affine)`
  - atoms: `storage == :multiowned | storage == :shared | !ownership | ownership == :affine`
- *POSSIBLE* `src/ast/type.rb:1325` (merge_capabilities_from!) -- 4 condition atoms in `source_ownership && !(preserve_existing && existing_concrete_ownership) && (include_affine_ownership || source_ownership != :affine)`
  - atoms: `source_ownership | !(preserve_existing && existing_concrete_ownership) | include_affine_ownership | source_ownership != :affine`
- *POSSIBLE* `src/mir/lowering/concurrency.rb:619` (bg_capture_materialization) -- 4 condition atoms in `s.requires_setup? || promoted_names[s.name] || outer_ref.nil? || pointer_captures.include?(s.name)`
  - atoms: `s.requires_setup? | promoted_names[s.name] | outer_ref.nil? | pointer_captures.include?(s.name)`
- *POSSIBLE* `src/mir/lowering/expressions.rb:2008` (lower_copy) -- 5 condition atoms in `ti.any_sync? || ti.collection_value? || ti.collection? || (ti.struct? && ti.needs_promotion?(mir_schema_lookup))`
  - atoms: `ti.any_sync? | ti.collection_value? | ti.collection? | ti.struct? | ti.needs_promotion?(mir_schema_lookup)`
- *POSSIBLE* `src/tools/formatter.rb:412` (canonicalize_numeric) -- 4 condition atoms in `(suffix == '_i64' && !has_decimal) || (suffix == '_f64' && has_decimal)`
  - atoms: `suffix == '_i64' | !has_decimal | suffix == '_f64' | has_decimal`
- *POSSIBLE* `src/tools/lint_fix_rewriter.rb:312` (locate_type_annotation_span) -- 6 condition atoms in `c == '=' && depth == 0 && source[i + 1] != '=' && source[i - 1] != '!' && source[i - 1] != '<' && source[i - 1] != '>'`
  - atoms: `c == '=' | depth == 0 | source[i + 1] != '=' | source[i - 1] != '!' | source[i - 1] != '<' | source[i - 1] != '>'`
- *POSSIBLE* `src/tools/method_rewriter.rb:152` (walk_collect_edits) -- 6 condition atoms in `node.is_a?(AST::FuncCall) && methods.include?(node.name) && node.args.is_a?(Array) && !node.args.empty? && !node.fn_var_call && !node.extern_call`
  - atoms: `node.is_a?(AST::FuncCall) | methods.include?(node.name) | node.args.is_a?(Array) | !node.args.empty? | !node.fn_var_call | !node.extern_call`
- *POSSIBLE* `src/tools/predicate_rewriter.rb:281` (expand_paren_wrap) -- 4 condition atoms in `lhs_start > 0 && lhs_end < source.length && source[lhs_start - 1] == '(' && source[lhs_end] == ')'`
  - atoms: `lhs_start > 0 | lhs_end < source.length | source[lhs_start - 1] == '(' | source[lhs_end] == ')'`
- *POSSIBLE* `src/tools/predicate_rewriter.rb:389` (walk_to_expr_end) -- 4 condition atoms in `depth == 0 && (c == ',' || c == ';' || c == "\n")`
  - atoms: `depth == 0 | c == ',' | c == ';' | c == "\n"`
- *POSSIBLE* `src/tools/stack_verifier.rb:85` (extract_frame_sizes) -- 4 condition atoms in `current_fn && pending_mov && line =~ /sub\s+%(r\d+),%rsp/ && Regexp.last_match(1) == pending_mov[:reg]`
  - atoms: `current_fn | pending_mov | line =~ /sub\s+%(r\d+),%rsp/ | Regexp.last_match(1) == pending_mov[:reg]`
- *POSSIBLE* `src/tools/stack_verifier.rb:290` (extract_full_call_graph) -- 4 condition atoms in `!saw_frame && pending_mov && line =~ /sub\s+%(r\d+),%rsp/ && Regexp.last_match(1) == pending_mov[:reg]`
  - atoms: `!saw_frame | pending_mov | line =~ /sub\s+%(r\d+),%rsp/ | Regexp.last_match(1) == pending_mov[:reg]`
- *POSSIBLE* `src/tools/stack_verifier.rb:351` (deepest_path_cost) -- 4 condition atoms in `fn && fn.respond_to?(:reentrance_kind) && fn.reentrance_kind == :reentrant_max_depth && fn.max_depth_n`
  - atoms: `fn | fn.respond_to?(:reentrance_kind) | fn.reentrance_kind == :reentrant_max_depth | fn.max_depth_n`

## Broken Protocols (378)
_co-called pair, one site does A without B -- *POSSIBLE* bug (noisy)_

- *POSSIBLE* conf=0.98 support=44 `src/ast/parser.rb:1814` (parse_binary_op) does `parse_expression` without `consume`
- *POSSIBLE* conf=0.97 support=34 `src/mir/mir_lowering.rb:3527` (bare_zig_type) does `transpile_type` without `new`
- *POSSIBLE* conf=0.96 support=43 `src/ast/parser.rb:527` (run_action) does `parse_expression` without `new`
- *POSSIBLE* conf=0.96 support=43 `src/ast/parser.rb:720` (parse_statement) does `parse_expression` without `new`
- *POSSIBLE* conf=0.95 support=35 `src/ast/parser.rb:547` (match_literal!) does `match!` without `consume`
- *POSSIBLE* conf=0.95 support=35 `src/ast/parser.rb:3549` (parse_error_selectors) does `match!` without `consume`
- *POSSIBLE* conf=0.95 support=21 `src/annotator/helpers/intrinsic_emit.rb:22` ((top-level)) does `prop` without `returns`
- *POSSIBLE* conf=0.94 support=17 `src/mir/lowering/variables.rb:155` (lower_var_decl) does `with_decl_alloc` without `lower`
- *POSSIBLE* conf=0.94 support=17 `src/mir/lowering/variables.rb:1331` (auto_lock_assignment_value) does `with_decl_alloc` without `new`
- *POSSIBLE* conf=0.93 support=27 `src/mir/lowering/control_flow.rb:118` (lower_control_condition) does `hoist_alloc` without `new`
- *POSSIBLE* conf=0.93 support=27 `src/mir/lowering/variables.rb:1336` (auto_lock_assignment_value) does `hoist_alloc` without `new`
- *POSSIBLE* conf=0.93 support=14 `src/mir/lower/pipeline/pipeline_context.rb:276` (substitute_assignment_target) does `substitute` without `new`
- *POSSIBLE* conf=0.93 support=13 `src/semantic/escape_analysis.rb:787` (assignment_value_is_owned?) does `unwrap_value` without `is_a?`
- *POSSIBLE* conf=0.92 support=71 `src/ast/async_result_shape.rb:8` ((top-level)) does `const` without `[]`
- *POSSIBLE* conf=0.92 support=71 `src/mir/lower/pipeline/pipeline_plan.rb:52` ((top-level)) does `const` without `[]`
- *POSSIBLE* conf=0.92 support=71 `src/mir/lower/pipeline/pipeline_records.rb:14` ((top-level)) does `const` without `[]`
- *POSSIBLE* conf=0.92 support=71 `src/mir/lowering/literals.rb:13` ((top-level)) does `const` without `[]`
- *POSSIBLE* conf=0.92 support=71 `src/mir/placement.rb:12` ((top-level)) does `const` without `[]`
- *POSSIBLE* conf=0.92 support=71 `src/semantic/ownership_identity.rb:12` ((top-level)) does `const` without `[]`
- *POSSIBLE* conf=0.92 support=48 `src/ast/lexer.rb:278` (extract_balanced_brace_content) does `-` without `[]`
- *POSSIBLE* conf=0.92 support=48 `src/ast/parser.rb:2503` (peek_generic_angle_params?) does `-` without `[]`
- *POSSIBLE* conf=0.92 support=48 `src/tools/formatter.rb:228` (consume_string) does `-` without `[]`
- *POSSIBLE* conf=0.92 support=48 `src/tools/formatter.rb:2567` (split_indent_markers) does `-` without `[]`
- *POSSIBLE* conf=0.92 support=34 `src/mir/lower/pipeline/pipeline_host.rb:526` (visit) does `visit_mir` without `new`
- *POSSIBLE* conf=0.92 support=34 `src/mir/lower/pipeline/pipeline_host.rb:699` (visit_pipeline_expr_mir) does `visit_mir` without `new`
- ...(+353 more)

## False Simplicity (1072)
_looks simple, behaves non-locally: hidden dispatch/mutation/IO/context/metaprogramming/monkeypatch -- *POSSIBLE* (noisy)_

- *POSSIBLE* [hidden_mutation] scatter=508 support=1268 `<<` -- `src/annotator/annotator.rb:240` (push_function_context!) (+1261 more)
- *POSSIBLE* [hidden_mutation] scatter=274 support=378 `full_type!` -- `src/annotator/annotator.rb:262` (stamp_type!) (+375 more)
- *POSSIBLE* [hidden_mutation] scatter=262 support=497 `[]=` -- `src/annotator/annotator.rb:667` (emit_auto_shape_resolved_findings!) (+495 more)
- *POSSIBLE* [hidden_mutation] scatter=241 support=401 `error!` -- `src/annotator/annotator.rb:507` (with_snapshot_transaction_body) (+400 more)
- *POSSIBLE* [hidden_mutation] scatter=137 support=212 `stamp_type!` -- `src/annotator/domains/control_flow.rb:101` (visit_BlockExpr) (+211 more)
- *POSSIBLE* [hidden_mutation] scatter=91 support=98 `from_node!` -- `src/annotator/domains/lifetimes.rb:147` (visit_CopyNode) (+97 more)
- *POSSIBLE* [hidden_mutation] scatter=67 support=121 `op-assign` -- `src/annotator/annotator.rb:295` (with_conditional_context) (+120 more)
- *POSSIBLE* [hidden_mutation] scatter=66 support=94 `storage=` -- `src/annotator/domains/control_flow.rb:102` (visit_BlockExpr) (+93 more)
- *POSSIBLE* [hidden_mutation] scatter=48 support=50 `fixable!` -- `src/annotator/domains/lifetimes.rb:691` (verify_tied_assignment!) (+49 more)
- *POSSIBLE* [hidden_io] scatter=44 support=50 `File.exist?` -- `src/ast/diagnostic_examples.rb:77` (load!) (+49 more)
- *POSSIBLE* [dynamic_dispatch] scatter=42 support=43 `blk.call` -- `src/annotator/annotator.rb:297` (with_conditional_context) (+42 more)
- *POSSIBLE* [hidden_mutation] scatter=37 support=89 `match!` -- `src/ast/parser.rb:187` ((top-level)) (+88 more)
- *POSSIBLE* [hidden_io] scatter=37 support=50 `File.join` -- `src/backends/importer.rb:65` (resolve_stdlib_package) (+49 more)
- *POSSIBLE* [dynamic_dispatch] scatter=36 support=41 `yield` -- `src/annotator/helpers/auto_inference.rb:745` (walk_for_shape_decls) (+40 more)
- *POSSIBLE* [hidden_mutation] scatter=36 support=36 `apply_capabilities!` -- `src/ast/type.rb:770` (initialize) (+35 more)
- *POSSIBLE* [dynamic_dispatch] scatter=34 support=38 `instance_variable_get` -- `src/annotator/domains/errors.rb:688` (coerce_empty_collection_fallback!) (+37 more)
- *POSSIBLE* [callback_inversion] scatter=33 support=36 `with_new_scope` -- `src/annotator/domains/control_flow.rb:52` (analyze_control_flow_branches) (+35 more)
- *POSSIBLE* [metaprogramming] scatter=27 support=40 `instance_variable_set` -- `src/annotator/domains/member_access.rb:401` (visit_StructLit) (+39 more)
- *POSSIBLE* [hidden_mutation] scatter=24 support=33 `result_type=` -- `src/mir/fsm_transform/suspend_resolvers.rb:220` (resolve_next) (+32 more)
- *POSSIBLE* [hidden_io] scatter=22 support=267 `puts` -- `src/backends/transpiler.rb:322` ((top-level)) (+266 more)
- *POSSIBLE* [hidden_mutation] scatter=19 support=25 `emit_typo_suggestion!` -- `src/annotator/domains/control_flow.rb:215` (annotate_struct_pattern!) (+24 more)
- *POSSIBLE* [hidden_io] scatter=18 support=25 `File.expand_path` -- `src/annotator/annotator.rb:525` (initialize) (+24 more)
- *POSSIBLE* [hidden_io] scatter=18 support=22 `File.readlines` -- `src/ast/diagnostic_examples.rb:87` (scan_file) (+21 more)
- *POSSIBLE* [context_dependency] scatter=18 support=21 `$stderr` -- `src/annotator/domains/lifetimes.rb:567` (finalize_scope) (+20 more)
- *POSSIBLE* [hidden_mutation] scatter=18 support=21 `mark_moved_guard!` -- `src/mir/cleanup_classifier.rb:546` (walk_takes_params) (+20 more)
- ...(+1047 more)

## Fat Unions (9)
_case dispatch over class consts whose arms read mostly variant-invariant members -- product-vs-sum decomposition candidate (extraction -> nil-kill) -- *POSSIBLE*_

- *POSSIBLE* [DEGENERATE: no variance] union `AST::Assignment | AST::BindExpr | AST::VarDecl` -- **3 common** vs 0 variant member(s), scatter=3 -- `src/mir/fsm_transform/liveness.rb:209` (collect_defs)
  - common: `is_a?, name, value` -> hoist to a struct, keep a SMALL union for `` (-> nil-kill)
- *POSSIBLE* [DEGENERATE: no variance] union `MIR::IndexedStore | MIR::RegistryCall | MIR::ShardedMapPut` -- **8 common** vs 0 variant member(s), scatter=1 -- `src/mir/mir_checker.rb:2558` (ownership_node_name)
  - common: `callee, class, expr, is_a?, method, reason, spec, target_var` -> hoist to a struct, keep a SMALL union for `` (-> nil-kill)
- *POSSIBLE* [DEGENERATE: no variance] union `MIR::FsmTailDone | MIR::FsmTailJump | MIR::FsmTailLockTry | MIR::FsmTailRetryOrError | MIR::FsmTailWokenCheck` -- **7 common** vs 0 variant member(s), scatter=1 -- `src/mir/fsm_transform/emit.rb:619` (build_dispatch_tail)
  - common: `class, cond_ast, else_index, next_index, respond_to?, target_index, then_index` -> hoist to a struct, keep a SMALL union for `` (-> nil-kill)
- *POSSIBLE* [DEGENERATE: no variance] union `MIR::OwnedBorrow | MIR::OwnedCreate | MIR::OwnedDestroy | MIR::OwnedReturn | MIR::OwnedStore | MIR::OwnedTransfer` -- **2 common** vs 0 variant member(s), scatter=2 -- `src/mir/mir_checker.rb:2483` (ownership_fact_source)
  - common: `name, source` -> hoist to a struct, keep a SMALL union for `` (-> nil-kill)
- *POSSIBLE* [DEGENERATE: no variance] union `AST::IndexOp | AST::OrderByOp | AST::SelectOp | AST::WhereOp` -- **2 common** vs 0 variant member(s), scatter=1 -- `src/annotator/helpers/pipe_analysis.rb:335` (analyze_select_family_op)
  - common: `expression, is_a?` -> hoist to a struct, keep a SMALL union for `` (-> nil-kill)
- *POSSIBLE* [DEGENERATE: no variance] union `MIR::AllocSlice | MIR::CapWrap | MIR::ConcatStr | MIR::ContainerInit | MIR::DeepCopy | MIR::DupeSlice | MIR::HeapCreate | MIR::MakeList` -- **2 common** vs 0 variant member(s), scatter=1 -- `src/mir/mir_checker.rb:2686` (expr_has_frame_alloc?)
  - common: `alloc, respond_to?` -> hoist to a struct, keep a SMALL union for `` (-> nil-kill)
- *POSSIBLE* [DEGENERATE: no variance] union `AST::GetField | AST::GetIndex | AST::OptionalUnwrap | AST::Slice` -- **2 common** vs 0 variant member(s), scatter=1 -- `src/mir/mir_lowering.rb:2655` (root_receiver_node)
  - common: `is_a?, target` -> hoist to a struct, keep a SMALL union for `` (-> nil-kill)
- *POSSIBLE* union `MIR::AllocMark | MIR::BreakStmt | MIR::Cleanup | MIR::ErrCleanup | MIR::FieldCleanupMark | MIR::MoveMark | MIR::OwnedBorrow | MIR::OwnedCreate | MIR::OwnedDestroy | MIR::OwnedReturn | MIR::OwnedStore | MIR::OwnedTransfer | MIR::Panic | MIR::ReassignMark | MIR::ReturnMark | MIR::ReturnStmt | MIR::TransferMark` -- **19 common** vs 3 variant member(s), scatter=1 -- `src/mir/mir_checker.rb:587` (check_linear_stmt!)
  - common: `arms, bindings, body, branch_bodies, branches, class, clause_bodies, cond` -> hoist to a struct, keep a SMALL union for `cleanup_entry, target, target_alloc` (-> nil-kill)
- *POSSIBLE* union `AST::EnumDef | AST::StructDef | AST::UnionDef` -- **4 common** vs 2 variant member(s), scatter=3 -- `src/backends/compiler_frontend.rb:93` (compile)
  - common: `is_a?, name, variants, visibility` -> hoist to a struct, keep a SMALL union for `field_decls, type_params` (-> nil-kill)

## Run Summary
- Files analyzed: 160
- Detectors: 19 (all shipped, self-tested)
- Convergence: 1783 unit(s) flagged by >=2 independent detectors
- Root-cause clusters: 479 (one fix collapses each)
- Total candidates: 6408
- Method: stdlib AST only, intra-procedural, zero deps, no CFG / no points-to; Flay similarity is an optional external signal consumed read-only (see docs/agents/design.md)
