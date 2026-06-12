# Decomplex Report

> Decision-level duplication and neglected-condition analysis.
> Every entry is a ranked **candidate** (Engler's discipline),
> never a verdict -- *POSSIBLE* findings, triaged by a human.
> Sections are ordered by SIGNAL TIER (1 = lowest false
> positive), not by volume. Items within a section are
> frequency-ranked. Triage tier 1, top-of-list, first.

## Table of Contents
- [Project Prioritization](#project-prioritization)
- [Cross-Detector Convergence (1934)](#cross-detector-convergence-1934)
- [Root-Cause Clusters (479)](#root-cause-clusters-479)
- [Decision Pressure (275)](#decision-pressure-275)
- [Redundant Nil Guards (0)](#redundant-nil-guards-0)
- [State Heatmap (562)](#state-heatmap-562)
- [State-Based Branch Density (1620)](#statebased-branch-density-1620)
- [Temporal Ordering Pressure (16)](#temporal-ordering-pressure-16)
- [Missing Abstractions (174)](#missing-abstractions-174)
- [Reification Misses (6)](#reification-misses-6)
- [Semantic Predicate Aliases (5)](#semantic-predicate-aliases-5)
- [Exact Predicate Aliases (16)](#exact-predicate-aliases-16)
- [Inconsistent Rename Clones (71)](#inconsistent-rename-clones-71)
- [Flay Similarity (Type-2/3) (54)](#flay-similarity-type23-54)
- [Neglected Updates (651)](#neglected-updates-651)
- [Derived-State Staleness (137)](#derivedstate-staleness-137)
- [Neglected Conditions (9)](#neglected-conditions-9)
- [Neglected Path Conditions (1351)](#neglected-path-conditions-1351)
- [Oversized Predicates (15)](#oversized-predicates-15)
- [Broken Protocols (374)](#broken-protocols-374)
- [Implicit Control Flow (75)](#implicit-control-flow-75)
- [Weighted Inlined Cognitive Complexity (476)](#weighted-inlined-cognitive-complexity-476)
- [Operational Discontinuity (High Confidence) (13)](#operational-discontinuity-high-confidence-13)
- [Function LCOM (19)](#function-lcom-19)
- [Operational Discontinuity (27)](#operational-discontinuity-27)
- [False Simplicity (1084)](#false-simplicity-1084)
- [Fat Unions (9)](#fat-unions-9)
- [Run Summary](#run-summary)

## Project Prioritization
_Ordered by signal tier (1 = highest signal / lowest FP), then by volume._

- **[tier 1]** [State-Based Branch Density (1620)](#statebased-branch-density-1620): branch decisions over mutable/object state -- state + control-flow pressure
- **[tier 1]** [State Heatmap (562)](#state-heatmap-562): state fields ranked by write/read/re-derivation scatter -- tangled mutable state should get one owner
- **[tier 1]** [Decision Pressure (275)](#decision-pressure-275): ELIMINABLE guard-pressure per loose contract (nil/is_a?/respond_to?/safe-nav/rescue-nil) -> tighten the contract once / nil-kill: DELETE. essential dispatch + pure c-uses are split out, NEVER summed (Rapps-Weyuker p-use; McCabe)
- **[tier 1]** [Missing Abstractions (174)](#missing-abstractions-174): guard tuple recomputed across >=2 decision units
- **[tier 1]** [Temporal Ordering Pressure (16)](#temporal-ordering-pressure-16): public mutable lifecycle surfaces that create implicit state-machine ordering
- **[tier 1]** [Exact Predicate Aliases (16)](#exact-predicate-aliases-16): identical one-line predicate body under >=2 names
- **[tier 1]** [Reification Misses (6)](#reification-misses-6): an existing predicate reinvented inline -- invariant #16
- **[tier 1]** [Semantic Predicate Aliases (5)](#semantic-predicate-aliases-5): one decision, multiple names (receiver/polarity folded)
- **[tier 2]** [Neglected Updates (651)](#neglected-updates-651): co-written state, one write missing -- *POSSIBLE* redundant-state desync
- **[tier 2]** [Weighted Inlined Cognitive Complexity (476)](#weighted-inlined-cognitive-complexity-476): same-owner helper chain hides cognitive load behind a low-looking orchestration method
- **[tier 2]** [Derived-State Staleness (137)](#derivedstate-staleness-137): b = f(a); a later reassigned, b not recomputed -- *POSSIBLE* bug
- **[tier 2]** [Implicit Control Flow (75)](#implicit-control-flow-75): state-dependent internal call order exists -- hidden lifecycle/control-flow pressure
- **[tier 2]** [Inconsistent Rename Clones (71)](#inconsistent-rename-clones-71): pasted block with inconsistent identifier mapping -- *POSSIBLE* missed rename bug
- **[tier 2]** [Flay Similarity (Type-2/3) (54)](#flay-similarity-type23-54): Flay structural clone pressure: Type-2 renamed clones and Type-3 fuzzy clones -- refactor pressure, not a verdict
- **[tier 2]** [Operational Discontinuity (High Confidence) (13)](#operational-discontinuity-high-confidence-13): strong blank/comment phase boundary where local variable lifetimes reset -- likely implicit sub-function boundary
- **[tier 2]** [Neglected Conditions (9)](#neglected-conditions-9): dispatch/conjunction minus one element -- *POSSIBLE* bug
- **[tier 3]** [Neglected Path Conditions (1351)](#neglected-path-conditions-1351): nested-if/&& guard set minus one atom -- *POSSIBLE* bug (noisy)
- **[tier 3]** [False Simplicity (1084)](#false-simplicity-1084): looks simple, behaves non-locally: hidden dispatch/mutation/IO/context/metaprogramming/monkeypatch -- *POSSIBLE* (noisy)
- **[tier 3]** [Broken Protocols (374)](#broken-protocols-374): co-called pair, one site does A without B -- *POSSIBLE* bug (noisy)
- **[tier 3]** [Operational Discontinuity (27)](#operational-discontinuity-27): blank/comment phase boundary where local variable lifetimes reset -- *POSSIBLE* implicit sub-function boundary
- **[tier 3]** [Function LCOM (19)](#function-lcom-19): independent local data-flow components inside one method -- *POSSIBLE* mixed concerns
- **[tier 3]** [Oversized Predicates (15)](#oversized-predicates-15): predicate with >3 condition atoms -- use an existing helper or extract a named predicate
- **[tier 3]** [Fat Unions (9)](#fat-unions-9): case dispatch over class consts whose arms read mostly variant-invariant members -- product-vs-sum decomposition candidate (extraction -> nil-kill) -- *POSSIBLE*

## Cross-Detector Convergence (1934)
_(file, method) units flagged by >=2 INDEPENDENT detectors -- the strongest triage signal: agreement outranks any single detector's volume. Tier-weighted (1=3, 2=2, 3=1). **Start here.**_

- `src/annotator/domains/variables.rb:279` (visit_BindExpr) -- **8 detectors** [score 16, 71 findings]: Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/tools/doctor.rb:171` (section_heap) -- **8 detectors** [score 16, 53 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Flay Similarity (Type-2/3), Missing Abstractions, Neglected Path Conditions, State-Based Branch Density
- `src/mir/mir_checker.rb:404` (check_fn!) -- **7 detectors** [score 17, 125 findings]: Decision Pressure, False Simplicity, Implicit Control Flow, Missing Abstractions, State-Based Branch Density, Temporal Ordering Pressure, Weighted Inlined Cognitive Complexity
- `src/annotator/helpers/function_analysis.rb:424` (resolve_call) -- **7 detectors** [score 15, 123 findings]: Decision Pressure, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/mir/mir_checker.rb:684` (check_linear_stmt!) -- **7 detectors** [score 15, 114 findings]: Decision Pressure, False Simplicity, Fat Unions, Implicit Control Flow, State-Based Branch Density, Temporal Ordering Pressure, Weighted Inlined Cognitive Complexity
- `src/annotator/helpers/pipe_analysis.rb:1590` (analyze_concurrent_op) -- **7 detectors** [score 15, 70 findings]: Decision Pressure, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/ast/parser.rb:2871` (parse_type_annotation) -- **7 detectors** [score 15, 46 findings]: Decision Pressure, False Simplicity, Implicit Control Flow, Neglected Path Conditions, Reification Misses, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/backends/pipeline_rewriter.rb:493` (build_recursive_body) -- **7 detectors** [score 15, 45 findings]: Derived-State Staleness, False Simplicity, Flay Similarity (Type-2/3), Missing Abstractions, Neglected Updates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/annotator/domains/variables.rb:13` (visit_VarDecl) -- **7 detectors** [score 15, 26 findings]: Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Neglected Updates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/annotator/domains/variables.rb:554` (visit_Assignment) -- **7 detectors** [score 15, 22 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/annotator/domains/execution_boundaries.rb:370` (validate_lock_error_clause!) -- **7 detectors** [score 15, 20 findings]: Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Neglected Updates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/mir/thunk_transform/recursive_splitter.rb:96` (split) -- **7 detectors** [score 15, 15 findings]: Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Operational Discontinuity, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/ast/parser.rb:1382` (parse_function_def) -- **7 detectors** [score 14, 70 findings]: Decision Pressure, False Simplicity, Implicit Control Flow, Neglected Path Conditions, Neglected Updates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/tools/formatter.rb:822` (emit_fn_block) -- **7 detectors** [score 14, 49 findings]: Derived-State Staleness, False Simplicity, Inconsistent Rename Clones, Missing Abstractions, Neglected Path Conditions, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/tools/formatter.rb:728` (emit_match_body) -- **7 detectors** [score 14, 49 findings]: Derived-State Staleness, False Simplicity, Inconsistent Rename Clones, Missing Abstractions, Neglected Path Conditions, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/tools/formatter.rb:2136` (emit_bg_do_wrapped) -- **7 detectors** [score 14, 45 findings]: Derived-State Staleness, False Simplicity, Inconsistent Rename Clones, Missing Abstractions, Neglected Path Conditions, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/mir/fsm_lowering.rb:116` (lower_step_stmts) -- **7 detectors** [score 13, 126 findings]: Broken Protocols, Decision Pressure, False Simplicity, Neglected Path Conditions, Operational Discontinuity (High Confidence), State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/annotator/domains/execution_boundaries.rb:40` (visit_WithBlock) -- **7 detectors** [score 13, 72 findings]: Broken Protocols, Decision Pressure, False Simplicity, Implicit Control Flow, Neglected Path Conditions, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/tools/formatter.rb:581` (scan_match_arms) -- **7 detectors** [score 13, 28 findings]: Broken Protocols, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/backends/transpiler.rb:182` (transpile_as_module) -- **6 detectors** [score 15, 14 findings]: Decision Pressure, False Simplicity, Missing Abstractions, Operational Discontinuity (High Confidence), State-Based Branch Density, Temporal Ordering Pressure
- `src/mir/lowering/functions.rb:1702` (lower_intrinsic) -- **6 detectors** [score 14, 31 findings]: Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/mir/thunk_transform/recursive_splitter.rb:142` (split_mutual) -- **6 detectors** [score 14, 14 findings]: Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/mir/lowering/functions.rb:1270` (finalize_call_result) -- **6 detectors** [score 14, 13 findings]: Decision Pressure, False Simplicity, Missing Abstractions, Neglected Updates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/mir/mir_checker.rb:2293` (verify_explicit_ownership_contracts!) -- **6 detectors** [score 14, 12 findings]: Decision Pressure, False Simplicity, Implicit Control Flow, Missing Abstractions, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/mir/fsm_transform/emit.rb:816` (build_recursive) -- **6 detectors** [score 13, 61 findings]: Decision Pressure, Derived-State Staleness, False Simplicity, Implicit Control Flow, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- ...(+1909 more)

### By file
- `src/mir/mir_lowering.rb` -- 15 detectors across 103 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, Exact Predicate Aliases, False Simplicity, Fat Unions, Function LCOM, Implicit Control Flow, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Operational Discontinuity, Semantic Predicate Aliases, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/ast/parser.rb` -- 14 detectors across 80 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Flay Similarity (Type-2/3), Function LCOM, Implicit Control Flow, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Operational Discontinuity, Reification Misses, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/mir/lowering/expressions.rb` -- 14 detectors across 62 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Flay Similarity (Type-2/3), Function LCOM, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Operational Discontinuity, Operational Discontinuity (High Confidence), Oversized Predicates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/ast/type.rb` -- 14 detectors across 50 method(s): Broken Protocols, Decision Pressure, Exact Predicate Aliases, False Simplicity, Flay Similarity (Type-2/3), Implicit Control Flow, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Operational Discontinuity, Oversized Predicates, State-Based Branch Density, Temporal Ordering Pressure, Weighted Inlined Cognitive Complexity
- `src/mir/fsm_transform/emit.rb` -- 13 detectors across 20 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, Exact Predicate Aliases, False Simplicity, Fat Unions, Function LCOM, Implicit Control Flow, Missing Abstractions, Operational Discontinuity, Semantic Predicate Aliases, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/mir/mir_checker.rb` -- 12 detectors across 76 method(s): Broken Protocols, Decision Pressure, False Simplicity, Fat Unions, Implicit Control Flow, Missing Abstractions, Neglected Conditions, Operational Discontinuity, Operational Discontinuity (High Confidence), State-Based Branch Density, Temporal Ordering Pressure, Weighted Inlined Cognitive Complexity
- `src/annotator/helpers/pipe_analysis.rb` -- 12 detectors across 51 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Fat Unions, Flay Similarity (Type-2/3), Implicit Control Flow, Missing Abstractions, Neglected Path Conditions, Neglected Updates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/tools/doctor.rb` -- 12 detectors across 31 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Flay Similarity (Type-2/3), Function LCOM, Missing Abstractions, Neglected Path Conditions, Operational Discontinuity, Operational Discontinuity (High Confidence), State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/tools/formatter.rb` -- 11 detectors across 77 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Flay Similarity (Type-2/3), Inconsistent Rename Clones, Missing Abstractions, Neglected Path Conditions, Oversized Predicates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/mir/lowering/control_flow.rb` -- 11 detectors across 36 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Flay Similarity (Type-2/3), Function LCOM, Missing Abstractions, Neglected Path Conditions, Operational Discontinuity (High Confidence), State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/annotator/domains/control_flow.rb` -- 11 detectors across 31 method(s): Broken Protocols, Decision Pressure, False Simplicity, Flay Similarity (Type-2/3), Implicit Control Flow, Neglected Path Conditions, Neglected Updates, Oversized Predicates, Reification Misses, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/annotator/domains/execution_boundaries.rb` -- 11 detectors across 19 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Implicit Control Flow, Missing Abstractions, Neglected Conditions, Neglected Path Conditions, Neglected Updates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/mir/lowering/functions.rb` -- 10 detectors across 43 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Function LCOM, Missing Abstractions, Neglected Path Conditions, Neglected Updates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/annotator/domains/lifetimes.rb` -- 10 detectors across 37 method(s): Broken Protocols, Decision Pressure, False Simplicity, Implicit Control Flow, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Operational Discontinuity, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/ast/ast.rb` -- 10 detectors across 34 method(s): Decision Pressure, Derived-State Staleness, Exact Predicate Aliases, False Simplicity, Flay Similarity (Type-2/3), Missing Abstractions, Neglected Path Conditions, Neglected Updates, Semantic Predicate Aliases, State-Based Branch Density

## Root-Cause Clusters (479)
_Findings across >=2 INDEPENDENT detectors that name the SAME entity -- 'N findings are really one invariant'. Convergence says where to look; this says **what one fix collapses the cluster**. Ranked candidate, not a verdict._

- **[name]** `expr` -- **6 detectors** [score 14] across 61 unit(s), 57 findings: Decision Pressure, Exact Predicate Aliases, False Simplicity, Neglected Path Conditions, Semantic Predicate Aliases, State-Based Branch Density
  - FIX: reify ONE named predicate/decision and call it everywhere
  - `src/annotator/domains/control_flow.rb:168` (visit_IfBind) ; `src/annotator/domains/control_flow.rb:406` (consume_match_subject_if_takes!) ; `src/annotator/domains/execution_boundaries.rb:855` (visit_NextExpr) ; `src/annotator/domains/execution_boundaries.rb:858` (visit_NextExpr)
- **[name]** `line` -- **6 detectors** [score 12] across 28 unit(s), 34 findings: Decision Pressure, Derived-State Staleness, Neglected Path Conditions, Neglected Updates, Oversized Predicates, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/tools/doctor.rb:617` (task_site_metadata) ; `src/tools/doctor.rb:630` (source_line) ; `src/annotator/helpers/capabilities.rb:1398` (finalize_capability_audit!) ; `src/annotator/helpers/capabilities.rb:1402` (finalize_capability_audit!)
- **[name]** `value` -- **6 detectors** [score 11] across 136 unit(s), 104 findings: Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions, Oversized Predicates, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator/domains/control_flow.rb:444` (analyze_match_case!) ; `src/annotator/domains/errors.rb:375` (visit_ReturnNode) ; `src/annotator/domains/errors.rb:414` (visit_ReturnNode) ; `src/annotator/domains/errors.rb:417` (visit_ReturnNode)
- **[name]** `stmt` -- **5 detectors** [score 12] across 47 unit(s), 47 findings: Derived-State Staleness, Exact Predicate Aliases, Neglected Path Conditions, Semantic Predicate Aliases, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/mir/fsm_transform/segments.rb:226` (split_while_loop_next) ; `src/mir/fsm_transform/segments.rb:232` (split_while_loop_next) ; `src/mir/fsm_transform/segments.rb:240` (split_while_loop_next) ; `src/mir/fsm_transform/segments.rb:256` (split_while_loop_next)
- **[name]** `sync` -- **5 detectors** [score 11] across 26 unit(s), 14 findings: Decision Pressure, False Simplicity, Oversized Predicates, Reification Misses, State-Based Branch Density
  - FIX: reify ONE named predicate/decision and call it everywhere
  - `src/annotator/domains/errors.rb:531` (same_return_capabilities?) ; `src/annotator/domains/lifetimes.rb:1023` (bg_capture_independent?) ; `src/annotator/helpers/generic_analysis.rb:459` (generic_type_has_capabilities?) ; `src/annotator/helpers/pipe_analysis.rb:1247` (auto_detect_sharded_access)
- **[name]** `struct` -- **5 detectors** [score 11] across 20 unit(s), 20 findings: Exact Predicate Aliases, Neglected Path Conditions, Oversized Predicates, Semantic Predicate Aliases, State-Based Branch Density
  - FIX: reify ONE named predicate/decision and call it everywhere
  - `src/mir/lowering/functions.rb:294` (lower_function_def) ; `src/mir/lowering/functions.rb:305` (lower_function_def) ; `src/mir/lowering/functions.rb:348` (lower_function_def) ; `src/mir/lowering/functions.rb:364` (lower_function_def)
- **[name]** `union` -- **5 detectors** [score 11] across 19 unit(s), 19 findings: Broken Protocols, Exact Predicate Aliases, Neglected Path Conditions, Semantic Predicate Aliases, State-Based Branch Density
  - FIX: pair the protocol (RAII / ensure); the unpaired site is the deviant
  - `src/annotator/domains/control_flow.rb:661` (emit_missing_match_variants!) ; `src/annotator/domains/control_flow.rb:664` (emit_missing_match_variants!) ; `src/annotator/domains/control_flow.rb:666` (emit_missing_match_variants!) ; `src/annotator/domains/control_flow.rb:668` (emit_missing_match_variants!)
- **[name]** `current` -- **5 detectors** [score 10] across 28 unit(s), 30 findings: Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/ast/parser.rb:2499` (peek_generic_angle_params?) ; `src/ast/parser.rb:2495` (peek_generic_angle_params?) ; `src/ast/parser.rb:2500` (peek_generic_angle_params?) ; `src/ast/parser.rb:2502` (peek_generic_angle_params?)
- **[name]** `state` -- **5 detectors** [score 10] across 23 unit(s), 30 findings: False Simplicity, Neglected Path Conditions, Neglected Updates, Reification Misses, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/mir/control_flow.rb:1076` (collect_ownership_transfers) ; `src/mir/control_flow.rb:1087` (collect_ownership_transfers) ; `src/mir/control_flow.rb:1103` (collect_ownership_transfers) ; `src/mir/control_flow.rb:1120` (collect_ownership_transfers)
- **[name]** `emit` -- **5 detectors** [score 10] across 20 unit(s), 17 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Updates, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/mir/fsm_transform/suspend_resolvers.rb:65` (resolve_io) ; `src/mir/fsm_transform/suspend_resolvers.rb:66` (resolve_io) ; `src/mir/fsm_transform/suspend_resolvers.rb:67` (resolve_io) ; `src/mir/fsm_transform/suspend_resolvers.rb:68` (resolve_io)
- **[name]** `collection` -- **5 detectors** [score 9] across 15 unit(s), 18 findings: Decision Pressure, False Simplicity, Neglected Path Conditions, Oversized Predicates, State-Based Branch Density
  - FIX: tighten the contract once; the scattered defensive guards collapse (cross-proc -> nil-kill)
  - `src/mir/lowering/control_flow.rb:451` (for_each_loop_stmt) ; `src/mir/lowering/control_flow.rb:452` (for_each_loop_stmt) ; `src/annotator/helpers/pipe_analysis.rb:499` (analyze_join_op) ; `src/annotator/helpers/pipe_analysis.rb:509` (analyze_join_op)
- **[name]** `AST` -- **5 detectors** [score 8] across 125 unit(s), 205 findings: False Simplicity, Neglected Conditions, Neglected Path Conditions, Oversized Predicates, State-Based Branch Density
  - FIX: converging structural debt -- resolve once at the named entity
  - `src/mir/lowering/variables.rb:559` (lower_var_decl_init) ; `src/mir/lowering/variables.rb:564` (lower_var_decl_init) ; `src/mir/lowering/variables.rb:565` (lower_var_decl_init) ; `src/mir/lowering/variables.rb:570` (lower_var_decl_init)
- **[name]** `mir` -- **4 detectors** [score 12] across 23 unit(s), 15 findings: Decision Pressure, Exact Predicate Aliases, Semantic Predicate Aliases, State-Based Branch Density
  - FIX: reify ONE named predicate/decision and call it everywhere
  - `src/mir/mir_lowering.rb:1165` (append_lowered_statement_packet!) ; `src/mir/hoist.rb:689` (mir_alloc_mark_type_info) ; `src/mir/hoist.rb:703` (mir_alloc_mark_type_info) ; `src/mir/hoist.rb:705` (mir_alloc_mark_type_info)
- **[name]** `alloc` -- **4 detectors** [score 10] across 21 unit(s), 16 findings: Decision Pressure, False Simplicity, Reification Misses, State-Based Branch Density
  - FIX: reify ONE named predicate/decision and call it everywhere
  - `src/mir/lowering/expressions.rb:1576` (lower_struct_lit) ; `src/mir/lowering/expressions.rb:1664` (lower_union_variant_lit) ; `src/mir/mir_emitter.rb:2101` (emit_deep_copy) ; `src/mir/mir_emitter.rb:2105` (emit_deep_copy)
- **[name]** `enum` -- **4 detectors** [score 10] across 17 unit(s), 9 findings: Broken Protocols, Exact Predicate Aliases, Semantic Predicate Aliases, State-Based Branch Density
  - FIX: pair the protocol (RAII / ensure); the unpaired site is the deviant
  - `src/annotator/domains/control_flow.rb:661` (emit_missing_match_variants!) ; `src/annotator/domains/control_flow.rb:664` (emit_missing_match_variants!) ; `src/annotator/domains/control_flow.rb:666` (emit_missing_match_variants!) ; `src/annotator/domains/control_flow.rb:668` (emit_missing_match_variants!)
- **[name]** `zig_pattern` -- **4 detectors** [score 9] across 85 unit(s), 119 findings: Decision Pressure, False Simplicity, Neglected Updates, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/mir/lowering/functions.rb:1594` (lower_intrinsic) ; `src/mir/lowering/functions.rb:1595` (lower_intrinsic) ; `src/mir/lowering/functions.rb:1628` (lower_intrinsic) ; `src/mir/lowering/functions.rb:1630` (lower_intrinsic)
- **[name]** `capture_analysis` -- **4 detectors** [score 9] across 79 unit(s), 70 findings: Decision Pressure, False Simplicity, Neglected Updates, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/mir/control_flow.rb:1232` (collect_bg_body_gives) ; `src/mir/control_flow.rb:1380` (check_stmt_reads) ; `src/mir/control_flow.rb:1381` (check_stmt_reads) ; `src/mir/control_flow.rb:1913` (check_stmt)
- **[name]** `target` -- **4 detectors** [score 9] across 50 unit(s), 42 findings: Decision Pressure, Derived-State Staleness, Neglected Path Conditions, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator/domains/errors.rb:417` (visit_ReturnNode) ; `src/annotator/domains/errors.rb:419` (visit_ReturnNode) ; `src/annotator/domains/execution_boundaries.rb:433` (reject_bare_atomic_ptr_mutation!) ; `src/annotator/domains/execution_boundaries.rb:434` (reject_bare_atomic_ptr_mutation!)
- **[name]** `can_fail` -- **4 detectors** [score 9] across 32 unit(s), 150 findings: Decision Pressure, False Simplicity, Neglected Updates, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/mir/lowering/functions.rb:305` (lower_function_def) ; `src/mir/control_flow.rb:280` (stmt_can_fail?) ; `src/mir/control_flow.rb:281` (stmt_can_fail?) ; `src/mir/control_flow.rb:283` (stmt_can_fail?)
- **[name]** `matched_stdlib_def` -- **4 detectors** [score 9] across 26 unit(s), 32 findings: Decision Pressure, False Simplicity, Neglected Updates, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator/helpers/effects.rb:861` (func_call_suspends?) ; `src/annotator/phases/body_analysis.rb:334` (record_body_fact_node!) ; `src/mir/fsm_transform/segments.rb:374` (io_suspending_call?) ; `src/mir/fsm_transform.rb:322` (suspend_value?)
- ...(+459 more)

## Decision Pressure (275)
_ELIMINABLE guard-pressure per loose contract (nil/is_a?/respond_to?/safe-nav/rescue-nil) -> tighten the contract once / nil-kill: DELETE. essential dispatch + pure c-uses are split out, NEVER summed (Rapps-Weyuker p-use; McCabe)_

- `.value` -- ELIMINABLE guard-pressure **121** across 65 method(s) -> tighten contract / nil-kill: DELETE  (+15 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/domains/control_flow.rb:444` (analyze_match_case!) ; `src/annotator/domains/errors.rb:375` (visit_ReturnNode) ; `src/annotator/domains/errors.rb:414` (visit_ReturnNode) ; `src/annotator/domains/errors.rb:417` (visit_ReturnNode)
- `.symbol` -- ELIMINABLE guard-pressure **83** across 66 method(s) -> tighten contract / nil-kill: DELETE  (+12 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/domains/errors.rb:414` (visit_ReturnNode) ; `src/annotator/domains/errors.rb:417` (visit_ReturnNode) ; `src/annotator/domains/errors.rb:419` (visit_ReturnNode) ; `src/annotator/domains/execution_boundaries.rb:438` (reject_bare_atomic_ptr_mutation!)
- `.target` -- ELIMINABLE guard-pressure **62** across 37 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/domains/errors.rb:417` (visit_ReturnNode) ; `src/annotator/domains/errors.rb:419` (visit_ReturnNode) ; `src/annotator/domains/execution_boundaries.rb:433` (reject_bare_atomic_ptr_mutation!) ; `src/annotator/domains/execution_boundaries.rb:433` (reject_bare_atomic_ptr_mutation!)
- `.name` -- ELIMINABLE guard-pressure **45** across 34 method(s) -> tighten contract / nil-kill: DELETE  (+3 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/domains/lifetimes.rb:427` (handle_assignment_identifier_move!) ; `src/annotator/domains/lifetimes.rb:456` (handle_assign_borrow) ; `src/annotator/domains/variables.rb:554` (visit_Assignment) ; `src/annotator/domains/variables.rb:595` (visit_Assignment)
- `.current_fn_ctx` -- ELIMINABLE guard-pressure **42** across 39 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/annotator.rb:358` (current_loop_depth) ; `src/annotator/annotator.rb:363` (current_conditional_depth) ; `src/annotator/domains/errors.rb:309` (visit_Raise) ; `src/annotator/domains/errors.rb:733` (visit_OrExit)
- `.left` -- ELIMINABLE guard-pressure **33** across 16 method(s) -> tighten contract / nil-kill: DELETE  (+8 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/domains/errors.rb:583` (visit_OrRescue) ; `src/annotator/helpers/pipe_analysis.rb:118` (stamp_observable_terminal!) ; `src/annotator/helpers/pipe_analysis.rb:124` (stamp_observable_terminal!) ; `src/annotator/helpers/pipe_analysis.rb:288` (analyze_collect_op)
- `.right` -- ELIMINABLE guard-pressure **33** across 13 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/domains/errors.rb:568` (visit_OrRescue) ; `src/annotator/domains/errors.rb:569` (visit_OrRescue) ; `src/annotator/domains/errors.rb:570` (visit_OrRescue) ; `src/annotator/domains/errors.rb:571` (visit_OrRescue)
- `.expr` -- ELIMINABLE guard-pressure **29** across 20 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/domains/control_flow.rb:168` (visit_IfBind) ; `src/annotator/domains/control_flow.rb:406` (consume_match_subject_if_takes!) ; `src/annotator/domains/execution_boundaries.rb:855` (visit_NextExpr) ; `src/annotator/domains/execution_boundaries.rb:858` (visit_NextExpr)
- `.type` -- ELIMINABLE guard-pressure **25** across 22 method(s) -> tighten contract / nil-kill: DELETE  (+40 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/domains/control_flow.rb:928` (loop_value_copyable?) ; `src/annotator/domains/variables.rb:13` (visit_VarDecl) ; `src/annotator/domains/variables.rb:106` (finalize_decl_node!) ; `src/annotator/domains/variables.rb:129` (finalize_decl_node!)
- `.token` -- ELIMINABLE guard-pressure **23** across 20 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/helpers/capabilities.rb:1356` (record_capability_binding) ; `src/annotator/helpers/capabilities.rb:1357` (record_capability_binding) ; `src/ast/ast.rb:476` (borrowed_ownership_view?) ; `src/mir/control_flow.rb:1087` (collect_ownership_transfers)
- `.element_type` -- ELIMINABLE guard-pressure **18** across 15 method(s) -> tighten contract / nil-kill: DELETE  (+6 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/domains/member_access.rb:547` (infer_element_type) ; `src/annotator/domains/member_access.rb:558` (infer_optional_element_type) ; `src/annotator/helpers/function_analysis.rb:844` (any_element_collection_param?) ; `src/annotator/helpers/generic_analysis.rb:183` (validate_shape_annotation_capabilities!)
- `.object` -- ELIMINABLE guard-pressure **18** across 14 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/domains/control_flow.rb:858` (visit_WhileBindLoop) ; `src/annotator/helpers/auto_inference.rb:792` (record_method_call) ; `src/annotator/helpers/function_analysis.rb:531` (receiver_container_alloc) ; `src/annotator/helpers/method_analysis.rb:156` (narrow_receiver_collection!)
- `.body` -- ELIMINABLE guard-pressure **18** across 14 method(s) -> tighten contract / nil-kill: DELETE  (+5 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/backends/pipeline_rewriter.rb:65` (rewrite_children!) ; `src/backends/string_concat_rewriter.rb:55` (rewrite_children!) ; `src/mir/fsm_transform/recursive_splitter.rb:525` (emit_with_fragment) ; `src/mir/hoist.rb:742` (block_expr_result_type)
- `.type_params` -- ELIMINABLE guard-pressure **17** across 15 method(s) -> tighten contract / nil-kill: DELETE  (+1 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/domains/control_flow.rb:334` (literal_type_substitution!) ; `src/annotator/domains/control_flow.rb:341` (literal_type_substitution!) ; `src/annotator/domains/lifetimes.rb:1185` (move_if_not_copyable!) ; `src/annotator/domains/lifetimes.rb:1211` (move_if_takes_ownership!)
- `.sync` -- ELIMINABLE guard-pressure **15** across 14 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/domains/errors.rb:531` (same_return_capabilities?) ; `src/annotator/domains/lifetimes.rb:1023` (bg_capture_independent?) ; `src/annotator/helpers/generic_analysis.rb:459` (generic_type_has_capabilities?) ; `src/annotator/helpers/pipe_analysis.rb:1247` (auto_detect_sharded_access)
- `[name]` -- ELIMINABLE guard-pressure **13** across 13 method(s) -> tighten contract / nil-kill: DELETE  (+3 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/domains/control_flow.rb:918` (captured_move_consumed_by_loop?) ; `src/annotator/domains/lifetimes.rb:537` (finalize_scope) ; `src/annotator/function_registry.rb:78` (fnptr_call?) ; `src/annotator/function_registry.rb:83` (raises_directly?)
- `.current_function_context` -- ELIMINABLE guard-pressure **13** across 13 method(s) -> tighten contract / nil-kill: DELETE
  - `src/mir/mir_lowering.rb:325` (current_function_has_rt?) ; `src/mir/mir_lowering.rb:330` (current_function_has_catch?) ; `src/mir/mir_lowering.rb:335` (current_function_heap_carry_return?) ; `src/mir/mir_lowering.rb:340` (current_function_tail_call?)
- `.first` -- ELIMINABLE guard-pressure **12** across 12 method(s) -> tighten contract / nil-kill: DELETE  (+4 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/domains/lifetimes.rb:1079` (get_lifetime_path) ; `src/annotator/domains/member_access.rb:546` (infer_element_type) ; `src/annotator/domains/member_access.rb:557` (infer_optional_element_type) ; `src/annotator/helpers/lock_helper.rb:464` (report_lock_cycle!)
- `.reg` -- ELIMINABLE guard-pressure **12** across 8 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/domains/lifetimes.rb:567` (finalize_scope) ; `src/annotator/domains/lifetimes.rb:574` (finalize_scope) ; `src/annotator/domains/lifetimes.rb:584` (finalize_scope) ; `src/annotator/domains/lifetimes.rb:585` (finalize_scope)
- `.arms` -- ELIMINABLE guard-pressure **12** across 7 method(s) -> tighten contract / nil-kill: DELETE  (+2 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/domains/execution_boundaries.rb:42` (visit_WithBlock) ; `src/annotator/domains/execution_boundaries.rb:223` (with_block_has_versioned_arm?) ; `src/mir/lowering/control_flow.rb:234` (stamp_loop_frame_alloc_scopes!) ; `src/mir/lowering/control_flow.rb:240` (stamp_loop_frame_alloc_scopes!)
- `.tense_type` -- ELIMINABLE guard-pressure **11** across 11 method(s) -> tighten contract / nil-kill: DELETE  (+11 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/helpers/generic_analysis.rb:105` (type_annotation_facts) ; `src/annotator/helpers/pipe_analysis.rb:294` (analyze_collect_op) ; `src/ast/type.rb:2169` (list_requires_array_shape?) ; `src/ast/type.rb:2174` (observable_array_without_set?)
- `.resolved_type` -- ELIMINABLE guard-pressure **10** across 5 method(s) -> tighten contract / nil-kill: DELETE  (+2 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/helpers/capabilities.rb:206` (validate_capability_transition!) ; `src/annotator/helpers/capabilities.rb:219` (validate_capability_transition!) ; `src/mir/fsm_lowering.rb:412` (fsm_cap_metadata) ; `src/mir/fsm_lowering.rb:413` (fsm_cap_metadata)
- `.tail` -- ELIMINABLE guard-pressure **10** across 4 method(s) -> tighten contract / nil-kill: DELETE
  - `src/mir/fsm_transform/emit.rb:645` (build_dispatch_tail) ; `src/mir/fsm_transform/emit.rb:816` (build_recursive) ; `src/mir/fsm_transform/emit.rb:819` (build_recursive) ; `src/mir/fsm_transform/emit.rb:820` (build_recursive)
- `[node.name]` -- ELIMINABLE guard-pressure **9** across 8 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/domains/lifetimes.rb:1188` (move_if_not_copyable!) ; `src/annotator/domains/lifetimes.rb:1215` (move_if_takes_ownership!) ; `src/annotator/helpers/effects.rb:1183` (validate_tight_node!) ; `src/annotator/helpers/effects.rb:1194` (validate_tight_node!)
- `.return_type` -- ELIMINABLE guard-pressure **9** across 7 method(s) -> tighten contract / nil-kill: DELETE  (+20 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/domains/errors.rb:380` (visit_ReturnNode) ; `src/annotator/domains/errors.rb:381` (visit_ReturnNode) ; `src/annotator/helpers/effects.rb:434` (function_needs_runtime_directly?) ; `src/backends/pipeline_rewriter.rb:745` (callee_returns_error?)
- ...(+250 more)

## Redundant Nil Guards (0)
_nil checks / safe-nav dominated by an earlier non-nil proof -- delete repeated control flow or tighten the type_

None.

## State Heatmap (562)
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
  - writers: `src/annotator/domains/lifetimes.rb:82` (ensure_owned_value!) ; `src/annotator/domains/lifetimes.rb:99` (ensure_owned_value!) ; `src/annotator/helpers/function_analysis.rb:684` (verify_takes_argument!) ; `src/annotator/helpers/function_signature.rb:381` (with_intrinsic_override)
  - readers: `src/annotator/helpers/intrinsic_contract.rb:126` (from_emit) ; `src/ast/ast.rb:2225` (alloc) ; `src/ast/ast.rb:2225` (alloc) ; `src/ast/type.rb:1685` (provenance_alloc)
- `alloc_count` -- messiness **4.0** (writes=1, reads=1, re-derived=0, scatter=2, receiver patterns=2)
  - writers: `src/annotator/helpers/function_context.rb:91` (initialize)
  - readers: `src/annotator/helpers/function_analysis.rb:297` (visit_FunctionDef)
- `alloc_fault` -- messiness **35.0** (writes=5, reads=2, re-derived=0, scatter=5, receiver patterns=5)
  - writers: `src/annotator/helpers/effects.rb:645` (compute_can_fail!) ; `src/annotator/helpers/function_signature.rb:210` (sync_from_function_def!) ; `src/annotator/helpers/function_signature.rb:246` (initialize) ; `src/annotator/helpers/function_signature.rb:408` (dup)
  - readers: `src/annotator/helpers/function_signature.rb:210` (sync_from_function_def!) ; `src/annotator/helpers/function_signature.rb:408` (dup)
- `alloc_kinds` -- messiness **150.0** (writes=2, reads=13, re-derived=0, scatter=10, receiver patterns=6)
  - writers: `src/mir/mir_checker.rb:169` (initialize) ; `src/mir/mir_checker.rb:244` (initialize)
  - readers: `src/mir/mir_checker.rb:186` (copy) ; `src/mir/mir_checker.rb:186` (copy) ; `src/mir/mir_checker.rb:258` (from_state) ; `src/mir/mir_checker.rb:269` (alloc_kinds)
- `alloc_mark_entries` -- messiness **4.0** (writes=1, reads=1, re-derived=0, scatter=2, receiver patterns=2)
  - writers: `src/semantic/bg_capture_classifier.rb:107` (classify_one!)
  - readers: `src/annotator/helpers/capabilities.rb:1085` (merge_nested!)
- `alloc_mark_fact` -- messiness **4.0** (writes=1, reads=1, re-derived=0, scatter=2, receiver patterns=1)
  - writers: `src/mir/lower/pipeline/pipeline_materializer.rb:121` (initialize)
  - readers: `src/mir/lower/pipeline/pipeline_materializer.rb:151` (materializer_alloc_mark_fact)
- `alloc_scopes` -- messiness **35.0** (writes=1, reads=6, re-derived=0, scatter=5, receiver patterns=6)
  - writers: `src/mir/mir_checker.rb:170` (initialize)
  - readers: `src/mir/mir_checker.rb:187` (copy) ; `src/mir/mir_checker.rb:187` (copy) ; `src/mir/mir_checker.rb:736` (linear_alloc!) ; `src/mir/mir_checker.rb:943` (prune_scope_locals!)
- `allocs` -- messiness **56.0** (writes=1, reads=7, re-derived=0, scatter=7, receiver patterns=6)
  - writers: `src/mir/hoist.rb:1152` (stamp_allocating_result_target!)
  - readers: `src/mir/hoist.rb:1152` (stamp_allocating_result_target!) ; `src/mir/lower/pipeline/pipeline_materializer.rb:371` (inline_source_alloc) ; `src/mir/lowering/variables.rb:682` (owned_return_transfer_binding?) ; `src/mir/mir_checker.rb:1859` (allocator_metadata_for)
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
- `arg_mirs` -- messiness **10.0** (writes=1, reads=4, re-derived=0, scatter=2, receiver patterns=1)
  - writers: `src/mir/fsm_ops.rb:287` (initialize)
  - readers: `src/mir/fsm_ops.rb:350` (lower_expr) ; `src/mir/fsm_ops.rb:350` (lower_expr) ; `src/mir/fsm_ops.rb:351` (lower_expr) ; `src/mir/fsm_ops.rb:353` (lower_expr)
- `arg_spec` -- messiness **63.0** (writes=3, reads=6, re-derived=0, scatter=7, receiver patterns=7)
  - writers: `src/annotator/helpers/function_signature.rb:255` (initialize) ; `src/annotator/helpers/function_signature.rb:417` (dup) ; `src/annotator/helpers/intrinsic_registry.rb:139` (convert_entry)
  - readers: `src/annotator/domains/lifetimes.rb:477` (resolve_borrow_source) ; `src/annotator/helpers/function_analysis.rb:489` (normalize_intrinsic_signature) ; `src/annotator/helpers/function_analysis.rb:491` (normalize_intrinsic_signature) ; `src/annotator/helpers/function_signature.rb:417` (dup)
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
  - readers: `src/annotator/helpers/capabilities.rb:580` (visit_pre_clauses!) ; `src/annotator/helpers/effects.rb:1227` (check_indirect_reentrancy!) ; `src/annotator/helpers/fixable_helpers.rb:684` (emit_reentrant_error!) ; `src/annotator/helpers/fixable_helpers.rb:727` (emit_ambiguous_return_error!)
- `as_type` -- messiness **54.0** (writes=3, reads=6, re-derived=0, scatter=6, receiver patterns=3)
  - writers: `src/ast/parser.rb:1139` (parse_extern_struct) ; `src/ast/schemas.rb:137` (initialize) ; `src/ast/schemas.rb:308` (initialize)
  - readers: `src/annotator/phases/import_resolution.rb:89` (clone_struct_schema) ; `src/annotator/phases/import_resolution.rb:102` (clone_resource_schema) ; `src/annotator/phases/type_registration.rb:43` (register_extern_struct_declaration) ; `src/annotator/phases/type_registration.rb:50` (register_extern_struct_declaration)
- `ast_stmts_use_placeholder` -- messiness **9.0** (writes=1, reads=2, re-derived=0, scatter=3, receiver patterns=1)
  - writers: `src/mir/lower/pipeline/pipeline_range_lowerer.rb:206` (initialize)
  - readers: `src/mir/lower/pipeline/pipeline_each_lowerer.rb:251` (lower_range_literal_each) ; `src/mir/lower/pipeline/pipeline_range_lowerer.rb:234` (range_ast_stmts_use_placeholder?)
- ...(+537 more)

## State-Based Branch Density (1620)
_branch decisions over mutable/object state -- state + control-flow pressure_

- `src/ast/ast.rb:196` (initialize) -- **21** state-based branch decision(s), refs=`rt.nil? | self[:bindings].nil? | self[:body].nil? | self[:borrowed].nil? | self[:capabilities].nil? | self[:cases].nil? | self[:extra_values].nil? | self[:fields].nil?` score=378
  - example predicate: `self[:body].nil?`
- `src/mir/cleanup_classifier.rb:750` (classify_binding) -- **13** state-based branch decision(s), refs=`facts.borrow_provenance | facts.container_borrow | facts.empty_initializer | facts.heap_storage | facts.mutable_binding_mutated | facts.resource_close_plan | facts.rodata_provenance | facts.sync` score=221
  - example predicate: `facts.container_borrow`
- `src/mir/fsm_transform/emit.rb:689` (build_recursive) -- **14** state-based branch decision(s), refs=`all_promoted.any? | ast_stmts.empty? | descriptor.nil? | lowered_mir.nil? | name.empty? | name.nil? | out.nil? | parts.empty?` score=196
  - example predicate: `segments.segments.empty?`
- `src/annotator/domains/execution_boundaries.rb:848` (visit_NextExpr) -- **15** state-based branch decision(s), refs=`async_shape.payload_type | async_shape.promise? | async_shape.shared_promise? | node.expr | promise_type.bounded_stream? | promise_type.dynamic_stream? | promise_type.future? | promise_type.inf_stream?` score=195
  - example predicate: `promise_type.future?`
- `src/tools/formatter.rb:2806` (needs_space?) -- **27** state-based branch decision(s), refs=`@generic_bracket_indices | @struct_lit_brace_indices | @struct_lit_brace_indices.empty? | a.raw | a.type | b.raw | b.type` score=189
  - example predicate: `b.type == :VAR_ID && b.raw.start_with?('@')`
- `src/annotator/domains/variables.rb:89` (finalize_decl_node!) -- **13** state-based branch decision(s), refs=`cap_tok.value | final_type.collection | fixes.any? | fixes.empty? | node.type | node.type.future? | node.type.observable? | node.value` score=182
  - example predicate: `node.type`
- `src/tools/formatter.rb:1294` (expand_if_while_for) -- **22** state-based branch decision(s), refs=`out.length | t.raw | t.type | tj.raw | tj.type | toks[j].type | toks[k].raw | toks[k].type` score=176
  - example predicate: `t.type == :SYM && ['(', '['].include?(t.raw)`
- `src/annotator/domains/errors.rb:375` (visit_ReturnNode) -- **13** state-based branch decision(s), refs=`expected.heap_return_storage? | expected.plain_return_payload_type | inline_bg_sources.any? | node.value | node.value.full_type!(context: "return expression storage").requires_move? | node.value.nil? | val.symbol | val.symbol.non_escaping` score=169
  - example predicate: `node.value.nil?`
- `src/annotator/domains/lifetimes.rb:537` (finalize_scope) -- **15** state-based branch decision(s), refs=`branch.nil? | info.mutable | info.mutated | info.ownership_kind | info.read | info.reg | info.reg.var_mutated | info.reg.var_used` score=150
  - example predicate: `ownership_graph.live?(name) || (is_takes && ownership_graph[name]&.moved?)`
- `src/annotator/helpers/function_analysis.rb:216` (visit_FunctionDef) -- **14** state-based branch decision(s), refs=`candidate_snap_types.size | catch_body_scan.references_snapshot | fn_type_params.any? | node.name | node.reentrance_kind | node.reentrant | node.return_type | node.tail_call` score=140
  - example predicate: `has_mutable_param && !node.name.end_with?("!")`
- `src/annotator/domains/execution_boundaries.rb:750` (visit_BgBlock) -- **12** state-based branch decision(s), refs=`analysis.has_affine_locked | analysis.has_local | analysis.has_sharded | analysis_result.has_local | analysis_result.has_non_escaping_capture | analysis_result.has_outer_ref | analysis_result.has_rc | analysis_result.has_shared` score=132
  - example predicate: `node.arena_mode`
- `src/mir/mir_lowering.rb:2689` (mir_cast) -- **10** state-based branch decision(s), refs=`from_t.dynamic? | from_t.fixed? | from_t.float? | from_t.fn_type? | from_t.integer? | from_t.map? | to_t.dynamic? | to_t.empty_list?` score=130
  - example predicate: `from_t.fn_type? || to_t.fn_type?`
- `src/mir/lowering/variables.rb:559` (lower_var_decl_init) -- **12** state-based branch decision(s), refs=`ft.fixed_soa? | ft.list_collection? | ft.pool? | ft.set_collection? | node.value | node.value.was_moved | rhs.op | rhs.smooth?` score=120
  - example predicate: `node.value.is_a?(AST::NextExpr)`
- `src/ast/parser.rb:1321` (parse_function_def) -- **10** state-based branch decision(s), refs=`@gradual | @pos | @tokens | @tokens[@pos + 1].value | T.must(cap_tok).value | current.type | current.value | early_requires_clauses.empty?` score=120
  - example predicate: `!explicit_return && @gradual`
- `src/mir/lowering/functions.rb:1594` (lower_intrinsic) -- **11** state-based branch decision(s), refs=`alloc_metadata.empty? | consumed_operands.empty? | entry.intrinsic_bc? | node.args | node.args.first | node.object | node.zig_pattern | ownership_facts.takes_any?` score=110
  - example predicate: `node.zig_pattern.is_a?(Symbol)`
- `src/semantic/escape_analysis.rb:282` (propagate_caller_sync!) -- **11** state-based branch decision(s), refs=`call_site.fn_var_call | callee_fn.params | entry.storage | entry.sync | fn_nodes.empty? | s.rc_stored? | s.sync | sites.empty?` score=110
  - example predicate: `fn_nodes.empty?`
- `src/annotator/domains/expressions.rb:257` (visit_CapabilityWrap) -- **10** state-based branch decision(s), refs=`node.atomic? | node.atomic_ptr? | node.capability? | node.indirect? | node.layout | node.lock_rank | node.locked_sync? | node.multiowned?` score=110
  - example predicate: `ti.primitive? && node.atomic_ptr?`
- `src/annotator/domains/member_access.rb:266` (visit_StructLit) -- **10** state-based branch decision(s), refs=`field_names.empty? | missing.any? | node.fields | node.fields.empty? | node.fields.length | raw_expected.nil? | schema.borrowed_fields | schema.borrowed_fields.any?` score=110
  - example predicate: `schema.nil?`
- `src/mir/lowering/expressions.rb:2002` (lower_copy) -- **8** state-based branch decision(s), refs=`dst_ti.collection? | dst_ti.direct_indexable_collection? | dst_ti.string? | ti.any_rc? | ti.any_sync? | ti.collection? | ti.collection_value? | ti.direct_indexable_collection?` score=104
  - example predicate: `ti.any_rc?`
- `src/mir/mir_checker.rb:1512` (check_fsm_structure!) -- **10** state-based branch decision(s), refs=`cap.cleanup_at | cap.name | cleanup_step.nil? | fact.move_guarded | fact.name | result_facts.any? | step.index | structure.ctx_id` score=100
  - example predicate: `cap.cleanup_at == :finalize`
- `src/annotator/helpers/function_analysis.rb:373` (resolve_call) -- **11** state-based branch decision(s), refs=`arg.full_type!(context: "extern argument").soa? | call_type.error_union? | comptime_type_args.any? | entry.storage | node.args | p.comptime | signature.extern | signature.module_alias` score=99
  - example predicate: `args.equal?(node.args)`
- `src/annotator/helpers/function_analysis.rb:1033` (declare_and_verify_params) -- **10** state-based branch decision(s), refs=`fams.empty? | field_names.empty? | missing.any? | param.default | param.sync | param.takes | param.type | param.type.any_sync?` score=90
  - example predicate: `param.default`
- `src/mir/lowering/control_flow.rb:371` (for_each_loop_stmt) -- **8** state-based branch decision(s), refs=`ct.bounded_stream? | ct.dynamic_field_array? | ct.dynamic_stream? | ct.fixed_soa? | ct.inf_stream? | ct.list_collection? | ct.map? | ct.open_stream?` score=88
  - example predicate: `ct.map?`
- `src/annotator/domains/member_access.rb:25` (visit_GetIndex) -- **8** state-based branch decision(s), refs=`index_type_info.numeric? | index_type_info.string? | node.target | node.target.metatype | result_type.optional? | target_type_info.map? | target_type_info.numeric_map? | target_type_info.promise_list?` score=80
  - example predicate: `node.target.is_a?(AST::OptionalUnwrap) && !result_type.optional?`
- `src/ast/type.rb:1478` (accepts?) -- **8** state-based branch decision(s), refs=`other_type.any? | other_type.byte? | other_type.error_union? | other_type.map? | other_type.numeric? | other_type.optional? | other_type.resolved | other_type.string?` score=80
  - example predicate: `self == other_type || any? || other_type.any?`
- ...(+1595 more)

## Temporal Ordering Pressure (16)
_public mutable lifecycle surfaces that create implicit state-machine ordering_

- `FunctionSignature` (`src/annotator/helpers/function_signature.rb:36` (FunctionSignature)) -- implicit lifecycle score **5401** (public=43, state methods=9, writers=5, fields=29, shared=29, flows=9!, states=2^29)
  - shared fields: `@alloc_fault | @arg_spec | @arg_validator | @arity | @can_fail | @effects | @emit | @error_fallible`
  - surface: `src/annotator/helpers/function_signature.rb:36` (return_lifetime=) ; `src/annotator/helpers/function_signature.rb:52` (return_type=) ; `src/annotator/helpers/function_signature.rb:99` (emit=) ; `src/annotator/helpers/function_signature.rb:104` (intrinsic_contract) ; `src/annotator/helpers/function_signature.rb:115` (requires=) ; `src/annotator/helpers/function_signature.rb:223` (initialize)
- `Profile` (`src/tools/pprof.rb:65` (Profile)) -- implicit lifecycle score **4996** (public=12, state methods=10, writers=6, fields=15, shared=15, flows=10!, states=2^15)
  - shared fields: `@default_sample_type_idx | @duration_nanos | @functions | @locations | @mappings | @next_func_id | @next_loc_id | @next_mapping_id`
  - surface: `src/tools/pprof.rb:65` (initialize) ; `src/tools/pprof.rb:86` (intern) ; `src/tools/pprof.rb:94` (add_sample_type) ; `src/tools/pprof.rb:100` (set_period_type) ; `src/tools/pprof.rb:107` (default_sample_type=) ; `src/tools/pprof.rb:119` (add_mapping)
- `SymbolEntry` (`src/ast/symbol_entry.rb:147` (SymbolEntry)) -- implicit lifecycle score **4288** (public=50, state methods=16, writers=3, fields=13, shared=4, flows=16!, states=2^13)
  - shared fields: `@flow | @lifecycle | @lifetime | @reg`
  - surface: `src/ast/symbol_entry.rb:147` (lifetime=) ; `src/ast/symbol_entry.rb:375` (invalidate!) ; `src/ast/symbol_entry.rb:381` (mark_read!) ; `src/ast/symbol_entry.rb:387` (mark_mutated!) ; `src/ast/symbol_entry.rb:393` (mark_mutated_via_reference!) ; `src/ast/symbol_entry.rb:399` (mark_poly_borrow_target!)
- `Type` (`src/ast/type.rb:745` (Type)) -- implicit lifecycle score **1637** (public=235, state methods=25, writers=9, fields=9, shared=5, flows=25!, states=2^9)
  - shared fields: `@capabilities | @generic_payload_type_arg | @is_resource | @placement | @zig_type_cache`
  - surface: `src/ast/type.rb:745` (initialize) ; `src/ast/type.rb:847` (ownership) ; `src/ast/type.rb:858` (sync) ; `src/ast/type.rb:869` (layout) ; `src/ast/type.rb:880` (lock_rank) ; `src/ast/type.rb:891` (collection)
- `SemanticAnnotator` (`src/annotator/annotator.rb:159` (SemanticAnnotator)) -- implicit lifecycle score **792** (public=44, state methods=35, writers=2, fields=9, shared=4, flows=35!, states=2^9)
  - shared fields: `@function_registry | @program | @receiver_state | @semantic_index`
  - surface: `src/annotator/annotator.rb:159` (semantic_function_registry) ; `src/annotator/annotator.rb:169` (phase_receiver_state) ; `src/annotator/annotator.rb:175` (ownership_graph) ; `src/annotator/annotator.rb:191` (scope_stack) ; `src/annotator/annotator.rb:196` (semantic_root_scope) ; `src/annotator/annotator.rb:201` (semantic_program)
- `OwnershipGraph` (`src/semantic/ownership_graph.rb:135` (OwnershipGraph)) -- implicit lifecycle score **528** (public=23, state methods=16, writers=5, fields=7, shared=5, flows=16!, states=2^7)
  - shared fields: `@children | @completed_nodes | @edges | @nodes | @scope_depth`
  - surface: `src/semantic/ownership_graph.rb:135` (initialize) ; `src/semantic/ownership_graph.rb:146` (scope_depth) ; `src/semantic/ownership_graph.rb:151` (push_scope!) ; `src/semantic/ownership_graph.rb:157` (pop_scope!) ; `src/semantic/ownership_graph.rb:163` (nodes) ; `src/semantic/ownership_graph.rb:171` (clear_completed_snapshot!)
- `Scope` (`src/ast/scope.rb:106` (Scope)) -- implicit lifecycle score **394** (public=33, state methods=19, writers=2, fields=7, shared=7, flows=19!, states=2^7)
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
- `PipelineLabelState` (`src/mir/lower/pipeline/pipeline_records.rb:62` (PipelineLabelState)) -- implicit lifecycle score **28** (public=4, state methods=4, writers=3, fields=2, shared=2, flows=4!, states=2^2)
  - shared fields: `@counter | @current_label`
  - surface: `src/mir/lower/pipeline/pipeline_records.rb:62` (initialize) ; `src/mir/lower/pipeline/pipeline_records.rb:68` (next_label) ; `src/mir/lower/pipeline/pipeline_records.rb:74` (current_label=) ; `src/mir/lower/pipeline/pipeline_records.rb:79` (current_label)
- `EffectSet` (`src/semantic/effect_set.rb:44` (EffectSet)) -- implicit lifecycle score **20** (public=9, state methods=8, writers=2, fields=2, shared=1, flows=8!, states=2^2)
  - shared fields: `@effects`
  - surface: `src/semantic/effect_set.rb:44` (initialize) ; `src/semantic/effect_set.rb:55` (empty) ; `src/semantic/effect_set.rb:61` (include?) ; `src/semantic/effect_set.rb:66` (empty?) ; `src/semantic/effect_set.rb:71` (union) ; `src/semantic/effect_set.rb:76` (==)
- `RecordStore` (`src/semantic/pass_work_profiler.rb:186` (RecordStore)) -- implicit lifecycle score **16** (public=3, state methods=3, writers=2, fields=2, shared=2, flows=3!, states=2^2)
  - shared fields: `@next_sequence | @records`
  - surface: `src/semantic/pass_work_profiler.rb:186` (initialize) ; `src/semantic/pass_work_profiler.rb:192` (fetch) ; `src/semantic/pass_work_profiler.rb:203` (records)
- `Program` (`src/mir/mir.rb:903` (Program)) -- implicit lifecycle score **10** (public=3, state methods=3, writers=2, fields=2, shared=1, flows=3!, states=2^2)
  - shared fields: `@pass_state`
  - surface: `src/mir/mir.rb:903` (initialize) ; `src/mir/mir.rb:909` (mir_pass_state) ; `src/mir/mir.rb:914` (mir_pass_state=)

## Missing Abstractions (174)
_guard tuple recomputed across >=2 decision units_

- **[case_dispatch]** support=6 scatter=6 rank=36
  - tuple: `AST::AllOp | AST::AnyOp | AST::AverageOp | AST::CountOp | AST::FindOp | AST::MaxOp | AST::MinOp | AST::SumOp`
  - `src/ast/ast.rb:2125` (pipeline_range_fold?) ; `src/mir/lower/pipeline/pipeline_binding_chain_lowerer.rb:186` (fold_expression) ; `src/mir/lower/pipeline/pipeline_binding_chain_lowerer.rb:194` (lower_binding_fold) ; `src/mir/lower/pipeline/pipeline_host.rb:773` (build_soa_scalar_fold_block) ; `src/mir/lower/pipeline/pipeline_range_lowerer.rb:504` (scalar_fold_plan) ; `src/mir/lower/pipeline/pipeline_scalar_lowerer.rb:32` (lower)
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
  - `src/backends/pipeline_rewriter.rb:280` (collect_chain) ; `src/mir/lower/pipeline/pipeline_binding_chain_lowerer.rb:73` (unwrap_chain) ; `src/mir/lower/pipeline/pipeline_binding_chain_lowerer.rb:83` (unwrap_chain) ; `src/mir/lower/pipeline/pipeline_range_lowerer.rb:292` (unwrap_range_chain)
- **[case_dispatch]** support=4 scatter=3 rank=12
  - tuple: `AST::Assignment | AST::BindExpr | AST::VarDecl`
  - `src/mir/fsm_transform/liveness.rb:209` (collect_defs) ; `src/mir/mir_pass.rb:548` (collect_consumed_names) ; `src/mir/mir_pass.rb:566` (collect_consumed_names) ; `src/tools/migration_suggester_helpers.rb:88` (walk_recursive)
- **[conjunction]** support=4 scatter=3 rank=12
  - tuple: `!target.to_s.empty? | target`
  - `src/mir/mir_checker.rb:1879` (allocator_metadata_target) ; `src/mir/mir_checker.rb:1882` (allocator_metadata_target) ; `src/mir/mir_checker.rb:1956` (verify_allocator_metadata_targets!) ; `src/mir/mir_checker.rb:2036` (verify_allocator_metadata_contracts!)
- **[case_dispatch]** support=3 scatter=3 rank=9
  - tuple: `:ATOMIC | :LOCKED | :VERSIONED`
  - `src/annotator/annotator.rb:456` (with_match_family_effects) ; `src/mir/mir_emitter.rb:996` (emit_with_match_probe) ; `src/mir/mir_emitter.rb:1013` (emit_with_match_prelude)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `slot.respond_to?(:shape) | slot.shape`
  - `src/annotator/annotator.rb:666` (emit_auto_shape_resolved_findings!) ; `src/annotator/helpers/fixable_helpers.rb:1476` (emit_auto_resolved_finding!) ; `src/annotator/helpers/fixable_helpers.rb:1638` (auto_slot_label)
- **[case_dispatch]** support=3 scatter=3 rank=9
  - tuple: `:block | :exit`
  - `src/annotator/domains/errors.rb:189` (visit_SyncPolicyDecl) ; `src/annotator/domains/execution_boundaries.rb:551` (validate_snapshot_match_arms!) ; `src/mir/lowering/capabilities.rb:666` (build_fallible_clause_mir)
- **[case_dispatch]** support=3 scatter=3 rank=9
  - tuple: `:kind | :type`
  - `src/annotator/domains/execution_boundaries.rb:587` (resolve_error_selectors!) ; `src/annotator/helpers/lock_helper.rb:425` (verify_handler_reachability!) ; `src/annotator/helpers/with_match_check.rb:424` (handled_error_set)
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
  - `src/ast/ast.rb:2093` (pipeline_fusible_stage?) ; `src/backends/pipeline_rewriter.rb:500` (build_recursive_body) ; `src/mir/lower/pipeline/pipeline_range_lowerer.rb:320` (build_lazy_range_prefix)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `atomic? | indirect?`
  - `src/ast/ast.rb:2192` (atomic_ptr?) ; `src/ast/symbol_entry.rb:189` (atomic_ptr?) ; `src/ast/type.rb:1761` (atomic_ptr?)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `!source.empty? | source`
  - `src/ast/syntax_typo_scanner.rb:41` (scan!) ; `src/mir/lowering/capabilities.rb:847` (lower_pre_clauses) ; `src/mir/lowering/functions.rb:843` (build_post_outer_fn)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `!shard_count | source.shard_count`
  - `src/ast/type.rb:1276` (copy_collection_shape_from!) ; `src/ast/type.rb:1284` (copy_topology_from!) ; `src/ast/type.rb:1294` (copy_declared_collection_modifiers_from!)
- **[case_dispatch]** support=3 scatter=3 rank=9
  - tuple: `AST::EnumDef | AST::StructDef | AST::UnionDef`
  - `src/backends/compiler_frontend.rb:93` (compile) ; `src/backends/importer.rb:207` (compile_module_mir) ; `src/mir/mir_lowering.rb:3120` (visible_imported_type_names)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `node.is_a?(AST::BinaryOp) | node.smooth?`
  - `src/backends/pipeline_rewriter.rb:34` (rewrite!) ; `src/backends/pipeline_rewriter.rb:256` (binding_source?) ; `src/mir/lower/pipeline/pipeline_range_lowerer.rb:288` (unwrap_range_chain)
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
- predicate `captured_value?` reinvented inline at `src/mir/fiber_ctx_builder.rb:157` (cleanup_mir_for) (`cleanup_plan.kind == CaptureCleanupKind::CapturedValue`)
- predicate `frame?` reinvented inline at `src/semantic/local_binding_facts.rb:100` (binding_frame_allocates?) (`alloc == :frame`)
- predicate `indirect?` reinvented inline at `src/ast/parser.rb:2871` (parse_type_annotation) (`layout == :indirect`)
- predicate `moved?` reinvented inline at `src/annotator/domains/control_flow.rb:65` (analyze_control_flow_branches) (`state == :moved`)
- predicate `uniform_value?` reinvented inline at `src/mir/fiber_ctx_builder.rb:158` (cleanup_mir_for) (`cleanup_plan.kind == CaptureCleanupKind::UniformValue`)

## Semantic Predicate Aliases (5)
_one decision, multiple names (receiver/polarity folded)_

- `enum? = resource? = union? = struct? = suspend? = mir? = stmt? = expr? = has_own_frame? = needs_capture_site_annotation?` == `true`
  - `src/ast/schemas.rb:34` (enum?) ; `src/ast/schemas.rb:146` (resource?) ; `src/ast/schemas.rb:273` (union?) ; `src/ast/schemas.rb:325` (struct?) ; `src/mir/fsm_transform/segments.rb:51` (suspend?) ; `src/mir/fsm_transform/segments.rb:69` (suspend?) ; `src/mir/mir.rb:383` (mir?) ; `src/mir/mir.rb:452` (stmt?) ; `src/mir/mir.rb:474` (expr?) ; `src/mir/mir.rb:940` (has_own_frame?) ; `src/mir/mir.rb:1629` (expr?) ; `src/mir/mir.rb:1656` (expr?) ; `src/mir/mir.rb:2032` (expr?) ; `src/mir/mir.rb:2043` (expr?) ; `src/mir/mir.rb:2060` (expr?) ; `src/mir/mir.rb:2091` (expr?) ; `src/mir/mir.rb:2551` (stmt?) ; `src/mir/mir.rb:2567` (stmt?) ; `src/mir/mir.rb:3122` (stmt?) ; `src/mir/mir.rb:3158` (stmt?) ; `src/mir/mir.rb:3192` (stmt?) ; `src/mir/mir.rb:3231` (stmt?) ; `src/mir/mir.rb:3244` (stmt?) ; `src/mir/mir.rb:3283` (stmt?) ; `src/mir/mir.rb:3312` (stmt?) ; `src/mir/mir.rb:3333` (stmt?) ; `src/mir/mir.rb:3345` (stmt?) ; `src/mir/mir.rb:3352` (stmt?) ; `src/mir/mir.rb:3359` (stmt?) ; `src/mir/mir.rb:3371` (stmt?) ; `src/mir/mir.rb:3378` (stmt?) ; `src/mir/mir.rb:3386` (stmt?) ; `src/mir/mir.rb:3402` (stmt?) ; `src/mir/mir.rb:3448` (stmt?) ; `src/mir/mir.rb:3461` (stmt?) ; `src/mir/mir.rb:4333` (expr?) ; `src/mir/mir.rb:4692` (expr?) ; `src/semantic/capture_strategy.rb:107` (needs_capture_site_annotation?) ; `src/semantic/capture_strategy.rb:127` (needs_capture_site_annotation?)
- `wildcard? = union? = struct? = resource? = enum? = blank? = stmt? = expr? = needs_capture_site_annotation?` == `false`
  - `src/ast/ast.rb:1654` (wildcard?) ; `src/ast/ast.rb:1815` (wildcard?) ; `src/ast/ast.rb:1830` (wildcard?) ; `src/ast/schemas.rb:36` (union?) ; `src/ast/schemas.rb:38` (struct?) ; `src/ast/schemas.rb:40` (resource?) ; `src/ast/schemas.rb:148` (union?) ; `src/ast/schemas.rb:150` (enum?) ; `src/ast/schemas.rb:152` (struct?) ; `src/ast/schemas.rb:275` (enum?) ; `src/ast/schemas.rb:277` (struct?) ; `src/ast/schemas.rb:279` (resource?) ; `src/ast/schemas.rb:327` (union?) ; `src/ast/schemas.rb:329` (enum?) ; `src/ast/schemas.rb:331` (resource?) ; `src/mir/fsm_transform/emit.rb:84` (blank?) ; `src/mir/mir.rb:385` (stmt?) ; `src/mir/mir.rb:387` (expr?) ; `src/semantic/capture_strategy.rb:70` (needs_capture_site_annotation?) ; `src/semantic/capture_strategy.rb:86` (needs_capture_site_annotation?) ; `src/semantic/capture_strategy.rb:143` (needs_capture_site_annotation?)
- `locked_sync? = lock_sync?` == `locked? || write_locked?`
  - `src/ast/ast.rb:2204` (locked_sync?) ; `src/ast/symbol_entry.rb:222` (lock_sync?)
- `materializer_bc_target? = range_bc_target?` == `bc_target.call`
  - `src/mir/lower/pipeline/pipeline_materializer.rb:160` (materializer_bc_target?) ; `src/mir/lower/pipeline/pipeline_range_lowerer.rb:238` (range_bc_target?)
- `semicolon_required? = zig_statement_semicolon_required?` == `stmt.expr? && !stripped.end_with?(";") && !stripped.end_with?("}") && !stripped.end_with?("{")`
  - `src/mir/mir_emitter.rb:2662` (semicolon_required?) ; `src/mir/mir_lowering.rb:3407` (zig_statement_semicolon_required?)

## Exact Predicate Aliases (16)
_identical one-line predicate body under >=2 names_

- `enum? = resource? = union? = struct? = suspend? = mir? = stmt? = expr? = has_own_frame? = needs_capture_site_annotation?` == `true`
  - `src/ast/schemas.rb:34` (enum?) ; `src/ast/schemas.rb:146` (resource?) ; `src/ast/schemas.rb:273` (union?) ; `src/ast/schemas.rb:325` (struct?) ; `src/mir/fsm_transform/segments.rb:51` (suspend?) ; `src/mir/fsm_transform/segments.rb:69` (suspend?) ; `src/mir/mir.rb:383` (mir?) ; `src/mir/mir.rb:452` (stmt?) ; `src/mir/mir.rb:474` (expr?) ; `src/mir/mir.rb:940` (has_own_frame?) ; `src/mir/mir.rb:1629` (expr?) ; `src/mir/mir.rb:1656` (expr?) ; `src/mir/mir.rb:2032` (expr?) ; `src/mir/mir.rb:2043` (expr?) ; `src/mir/mir.rb:2060` (expr?) ; `src/mir/mir.rb:2091` (expr?) ; `src/mir/mir.rb:2551` (stmt?) ; `src/mir/mir.rb:2567` (stmt?) ; `src/mir/mir.rb:3122` (stmt?) ; `src/mir/mir.rb:3158` (stmt?) ; `src/mir/mir.rb:3192` (stmt?) ; `src/mir/mir.rb:3231` (stmt?) ; `src/mir/mir.rb:3244` (stmt?) ; `src/mir/mir.rb:3283` (stmt?) ; `src/mir/mir.rb:3312` (stmt?) ; `src/mir/mir.rb:3333` (stmt?) ; `src/mir/mir.rb:3345` (stmt?) ; `src/mir/mir.rb:3352` (stmt?) ; `src/mir/mir.rb:3359` (stmt?) ; `src/mir/mir.rb:3371` (stmt?) ; `src/mir/mir.rb:3378` (stmt?) ; `src/mir/mir.rb:3386` (stmt?) ; `src/mir/mir.rb:3402` (stmt?) ; `src/mir/mir.rb:3448` (stmt?) ; `src/mir/mir.rb:3461` (stmt?) ; `src/mir/mir.rb:4333` (expr?) ; `src/mir/mir.rb:4692` (expr?) ; `src/semantic/capture_strategy.rb:107` (needs_capture_site_annotation?) ; `src/semantic/capture_strategy.rb:127` (needs_capture_site_annotation?)
- `wildcard? = union? = struct? = resource? = enum? = blank? = stmt? = expr? = needs_capture_site_annotation?` == `false`
  - `src/ast/ast.rb:1654` (wildcard?) ; `src/ast/ast.rb:1815` (wildcard?) ; `src/ast/ast.rb:1830` (wildcard?) ; `src/ast/schemas.rb:36` (union?) ; `src/ast/schemas.rb:38` (struct?) ; `src/ast/schemas.rb:40` (resource?) ; `src/ast/schemas.rb:148` (union?) ; `src/ast/schemas.rb:150` (enum?) ; `src/ast/schemas.rb:152` (struct?) ; `src/ast/schemas.rb:275` (enum?) ; `src/ast/schemas.rb:277` (struct?) ; `src/ast/schemas.rb:279` (resource?) ; `src/ast/schemas.rb:327` (union?) ; `src/ast/schemas.rb:329` (enum?) ; `src/ast/schemas.rb:331` (resource?) ; `src/mir/fsm_transform/emit.rb:84` (blank?) ; `src/mir/mir.rb:385` (stmt?) ; `src/mir/mir.rb:387` (expr?) ; `src/semantic/capture_strategy.rb:70` (needs_capture_site_annotation?) ; `src/semantic/capture_strategy.rb:86` (needs_capture_site_annotation?) ; `src/semantic/capture_strategy.rb:143` (needs_capture_site_annotation?)
- `child_bodies = ownership_source_exprs = pre_terminator_transfer_marks = marker_plan` == `[]`
  - `src/ast/ast.rb:869` (child_bodies) ; `src/mir/mir.rb:3866` (ownership_source_exprs) ; `src/mir/mir_lowering.rb:1876` (pre_terminator_transfer_marks) ; `src/semantic/capture_strategy.rb:68` (marker_plan) ; `src/semantic/capture_strategy.rb:84` (marker_plan) ; `src/semantic/capture_strategy.rb:141` (marker_plan)
- `pin_heap_for_sync_wrapper! = pin_heap_for_indirect! = pin_heap_for_collection!` == `mark_heap_allocated!`
  - `src/ast/type.rb:1110` (pin_heap_for_sync_wrapper!) ; `src/ast/type.rb:1117` (pin_heap_for_indirect!) ; `src/ast/type.rb:1124` (pin_heap_for_collection!)
- `child_exprs = ownership_source_exprs = owned_position_source_exprs` == `EMPTY_CHILD_EXPRS`
  - `src/mir/mir.rb:391` (child_exprs) ; `src/mir/mir.rb:393` (ownership_source_exprs) ; `src/mir/mir.rb:395` (owned_position_source_exprs)
- `emit_rc_retain = emit_rc_downgrade = emit_weak_upgrade` == `"CheatLib.#{node.func}(#{node.zig_base}, #{emit(node.source)})"`
  - `src/mir/mir_emitter.rb:2186` (emit_rc_retain) ; `src/mir/mir_emitter.rb:2196` (emit_rc_downgrade) ; `src/mir/mir_emitter.rb:2201` (emit_weak_upgrade)
- `locked_sync? = lock_sync?` == `locked? || write_locked?`
  - `src/ast/ast.rb:2204` (locked_sync?) ; `src/ast/symbol_entry.rb:222` (lock_sync?)
- `stream_allocating_args = stream_each_args` == `[ apply_ident, is_inf, MIR::AllocatorRef.new(alloc), MIR::Ident.new("rt"), source_pointer, worker_count, capacity, batch_size, parallel, task_config, context_arg, ]`
  - `src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb:129` (stream_allocating_args) ; `src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb:146` (stream_each_args)
- `materializer_visit_mir = range_visit_mir` == `@visit_mir.call(node)`
  - `src/mir/lower/pipeline/pipeline_materializer.rb:131` (materializer_visit_mir) ; `src/mir/lower/pipeline/pipeline_range_lowerer.rb:218` (range_visit_mir)
- `materializer_bc_target? = range_bc_target?` == `@bc_target.call`
  - `src/mir/lower/pipeline/pipeline_materializer.rb:160` (materializer_bc_target?) ; `src/mir/lower/pipeline/pipeline_range_lowerer.rb:238` (range_bc_target?)
- `materializer_schema_lookup = range_schema_lookup` == `@schema_lookup.call`
  - `src/mir/lower/pipeline/pipeline_materializer.rb:165` (materializer_schema_lookup) ; `src/mir/lower/pipeline/pipeline_range_lowerer.rb:253` (range_schema_lookup)
- `materializer_next_label = range_next_label` == `@next_label.call`
  - `src/mir/lower/pipeline/pipeline_materializer.rb:170` (materializer_next_label) ; `src/mir/lower/pipeline/pipeline_range_lowerer.rb:243` (range_next_label)
- `profile_dispatch_numeric_id = profile_dispatch_id` == `case dispatch when :parallel then 2 when :shared then 3 else 1 end`
  - `src/mir/lowering/concurrency.rb:672` (profile_dispatch_numeric_id) ; `src/mir/mir_lowering.rb:3223` (profile_dispatch_id)
- `ownership_source_exprs = owned_position_source_exprs` == `child_exprs`
  - `src/mir/mir.rb:1287` (ownership_source_exprs) ; `src/mir/mir.rb:1289` (owned_position_source_exprs) ; `src/mir/mir.rb:2716` (ownership_source_exprs) ; `src/mir/mir.rb:2938` (ownership_source_exprs) ; `src/mir/mir.rb:2959` (ownership_source_exprs) ; `src/mir/mir.rb:3034` (ownership_source_exprs) ; `src/mir/mir.rb:3057` (ownership_source_exprs) ; `src/mir/mir.rb:3827` (ownership_source_exprs) ; `src/mir/mir.rb:3843` (ownership_source_exprs) ; `src/mir/mir.rb:3945` (ownership_source_exprs) ; `src/mir/mir.rb:3947` (owned_position_source_exprs) ; `src/mir/mir.rb:3967` (ownership_source_exprs) ; `src/mir/mir.rb:3969` (owned_position_source_exprs) ; `src/mir/mir.rb:3995` (ownership_source_exprs) ; `src/mir/mir.rb:3997` (owned_position_source_exprs) ; `src/mir/mir.rb:4027` (ownership_source_exprs) ; `src/mir/mir.rb:4029` (owned_position_source_exprs) ; `src/mir/mir.rb:4092` (ownership_source_exprs) ; `src/mir/mir.rb:4094` (owned_position_source_exprs) ; `src/mir/mir.rb:4238` (ownership_source_exprs) ; `src/mir/mir.rb:4240` (owned_position_source_exprs) ; `src/mir/mir.rb:4284` (ownership_source_exprs) ; `src/mir/mir.rb:4300` (ownership_source_exprs) ; `src/mir/mir.rb:4338` (ownership_source_exprs) ; `src/mir/mir.rb:4340` (owned_position_source_exprs)
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
- *POSSIBLE* [type2] mass=170 node=`when` `src/mir/lower/pipeline/pipeline_host.rb:793` (build_soa_scalar_fold_block) ; `src/mir/lower/pipeline/pipeline_host.rb:800` (build_soa_scalar_fold_block)
- *POSSIBLE* [type2] mass=168 node=`defn` `src/mir/mir.rb:1192` (body_slots) ; `src/mir/mir.rb:1221` (body_slots) ; `src/mir/mir.rb:1249` (body_slots) ; `src/mir/mir.rb:2620` (body_slots)
- *POSSIBLE* [type2] mass=148 node=`or` `src/ast/ast.rb:536` (statement_result_void?) ; `src/mir/control_flow.rb:1768` (statement_like_expression_container?)
- *POSSIBLE* [type2] mass=144 node=`defn` `src/mir/fsm_wrapper_emitter.rb:58` (render_io_body) ; `src/mir/fsm_wrapper_emitter.rb:75` (render_b1_body) ; `src/mir/fsm_wrapper_emitter.rb:252` (render_generic_body)
- *POSSIBLE* [type2] mass=134 node=`cdecl` `src/mir/mir.rb:1401` ((top-level)) ; `src/mir/mir.rb:1420` ((top-level))
- *POSSIBLE* [type2] mass=134 node=`defn` `src/mir/thunk_transform/recursive_splitter.rb:172` (match_mutual_base_case) ; `src/mir/thunk_transform/recursive_splitter.rb:216` (match_base_case)
- *POSSIBLE* [type2] mass=132 node=`if` `src/annotator/helpers/fixable_helpers.rb:112` (emit_registry_mismatch!) ; `src/annotator/helpers/fixable_helpers.rb:151` (emit_typo_suggestion!) ; `src/annotator/helpers/fixable_helpers.rb:219` (emit_variant_typo!)
- *POSSIBLE* [type2] mass=122 node=`defn` `src/mir/lower/pipeline/pipeline_range_lowerer.rb:1041` (replace_zig_identifier) ; `src/mir/mir_emitter.rb:684` (replace_emit_identifier)
- *POSSIBLE* [type2] mass=114 node=`iter` `src/ast/std_lib.rb:1238` ((top-level)) ; `src/ast/std_lib.rb:1256` ((top-level)) ; `src/ast/std_lib.rb:1273` ((top-level))
- *POSSIBLE* [type2] mass=114 node=`hash` `src/tools/doctor.rb:677` (section_locks) ; `src/tools/pprof_converter.rb:203` (convert_locks)
- *POSSIBLE* [type2] mass=108 node=`cdecl` `src/mir/mir.rb:3118` ((top-level)) ; `src/mir/mir.rb:3225` ((top-level))
- *POSSIBLE* [type2] mass=100 node=`if` `src/annotator/helpers/capabilities.rb:581` (visit_pre_clauses!) ; `src/annotator/helpers/effects.rb:726` (enforce_fallible_returns!)
- *POSSIBLE* [type2] mass=99 node=`defn` `src/mir/mir.rb:1110` (body_slots) ; `src/mir/mir.rb:1130` (body_slots) ; `src/mir/mir.rb:3248` (body_slots)
- *POSSIBLE* [type2] mass=88 node=`if` `src/ast/parser.rb:3718` (parse_branch_prefix) ; `src/ast/parser.rb:3798` (parse_bg_prefix)
- *POSSIBLE* [type2] mass=86 node=`if` `src/annotator/domains/control_flow.rb:230` (annotate_struct_pattern!) ; `src/annotator/domains/control_flow.rb:617` (emit_unknown_destructure_field!)
- *POSSIBLE* [type2] mass=86 node=`block` `src/ast/ast.rb:1747` ((top-level)) ; `src/ast/ast.rb:2238` ((top-level))
- *POSSIBLE* [type2] mass=86 node=`cdecl` `src/mir/mir.rb:4086` ((top-level)) ; `src/mir/mir.rb:4232` ((top-level))
- *POSSIBLE* [type2] mass=84 node=`defn` `src/annotator/helpers/fixable_helpers.rb:644` (emit_immutable_index_assignment_error!) ; `src/annotator/helpers/fixable_helpers.rb:708` (emit_capture_immutable_as_mutable_error!)
- ...(+29 more)

## Neglected Updates (651)
_co-written state, one write missing -- *POSSIBLE* redundant-state desync_

- *POSSIBLE* (support=5) `src/annotator/domains/control_flow.rb:119` (visit_BlockExpr) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/domains/control_flow.rb:560` (borrow_match_payload_binding!) writes `.storage` but NOT `.capture_analysis` (recv `current_scope.entry_for_write!(binding)`)
- *POSSIBLE* (support=5) `src/annotator/domains/errors.rb:454` (visit_ReturnNode) writes `.storage` but NOT `.capture_analysis` (recv `node.value`)
- *POSSIBLE* (support=5) `src/annotator/domains/execution_boundaries.rb:642` (visit_DoBlock) writes `.capture_analysis` but NOT `.storage` (recv `branch`)
- *POSSIBLE* (support=5) `src/annotator/domains/execution_boundaries.rb:691` (visit_BgStreamBlock) writes `.capture_analysis` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/domains/execution_boundaries.rb:757` (visit_BgBlock) writes `.capture_analysis` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/domains/execution_boundaries.rb:862` (visit_NextExpr) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/domains/expressions.rb:102` (visit_Literal) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/domains/expressions.rb:166` (visit_BinaryOp) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/domains/lifetimes.rb:37` (visit_MoveNode) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/domains/lifetimes.rb:81` (ensure_owned_value!) writes `.storage` but NOT `.capture_analysis` (recv `copy`)
- *POSSIBLE* (support=5) `src/annotator/domains/lifetimes.rb:133` (visit_CopyNode) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/domains/lifetimes.rb:175` (visit_Copy) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/domains/lifetimes.rb:232` (visit_FreezeNode) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/domains/lifetimes.rb:252` (visit_CloneNode) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/domains/lifetimes.rb:270` (visit_ShareNode) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/domains/lifetimes.rb:1119` (set_cleanup_alloc!) writes `.storage` but NOT `.capture_analysis` (recv `val`)
- *POSSIBLE* (support=5) `src/annotator/domains/member_access.rb:239` (visit_HashLit) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/domains/member_access.rb:439` (visit_ListLit) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/domains/member_access.rb:497` (visit_DefaultArrayLit) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/domains/variables.rb:14` (visit_VarDecl) writes `.storage` but NOT `.capture_analysis` (recv `node.value`)
- *POSSIBLE* (support=5) `src/annotator/domains/variables.rb:280` (visit_BindExpr) writes `.storage` but NOT `.capture_analysis` (recv `node.value`)
- *POSSIBLE* (support=5) `src/annotator/helpers/function_analysis.rb:1156` (verify_captures!) writes `.storage` but NOT `.capture_analysis` (recv `cap`)
- *POSSIBLE* (support=5) `src/annotator/helpers/generic_analysis.rb:600` (register_container_borrow!) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/helpers/pipe_analysis.rb:297` (analyze_collect_op) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- ...(+626 more)

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
- *POSSIBLE* `src/mir/lowering/functions.rb:998` (cross_boundary_arg): `moved_arg` derived from `arg` (line 998); `arg` reassigned line 1015, `moved_arg` not recomputed
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
- *POSSIBLE* (support=3) `src/annotator/domains/execution_boundaries.rb:529` (validate_snapshot_match_arms!) -- MISSING `:LOCKED` from `:ATOMIC | :LOCKED | :VERSIONED`
- *POSSIBLE* (support=3) `src/mir/fsm_transform/recursive_splitter.rb:413` (emit_pivot) -- MISSING `AST::CatchBlock` from `AST::CatchBlock | AST::ForEach | AST::ForRange | AST::IfStatement | AST::WhileBindLoop | AST::WhileLoop | AST::WithBlock`
- *POSSIBLE* (support=3) `src/mir/mir_checker.rb:2558` (ownership_node_name) -- MISSING `MIR::ShardedMapGet` from `MIR::IndexedStore | MIR::RegistryCall | MIR::ShardedMapGet | MIR::ShardedMapPut`

## Neglected Path Conditions (1351)
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
- ...(+1326 more)

## Oversized Predicates (15)
_predicate with >3 condition atoms -- use an existing helper or extract a named predicate_

- *POSSIBLE* `src/annotator/domains/control_flow.rb:791` (visit_WhileLoop) -- 4 condition atoms in `(node.condition.is_a?(AST::Identifier) && node.condition.name == "TRUE") || (node.condition.is_a?(AST::Literal) && node.condition.value == true)`
  - atoms: `node.condition.is_a?(AST::Identifier) | node.condition.name == "TRUE" | node.condition.is_a?(AST::Literal) | node.condition.value == true`
- *POSSIBLE* `src/annotator/helpers/effects.rb:1049` (assign_base_stack_tiers!) -- 4 condition atoms in `effs.include?(HEAP) || effs.include?(BLOCKING) || effs.include?(EXTERN) || fn_node.runtime_stack_required?(recursion_yield_needed?(fn_node), declared_runtime_return)`
  - atoms: `effs.include?(HEAP) | effs.include?(BLOCKING) | effs.include?(EXTERN) | fn_node.runtime_stack_required?(recursion_yield_needed?(fn_node), declared_runtime_return)`
- *POSSIBLE* `src/ast/type.rb:769` (initialize) -- 7 condition atoms in `ownership || sync || layout || collection || shard_count || observable || observable_terminal`
  - atoms: `ownership | sync | layout | collection | shard_count | observable | observable_terminal`
- *POSSIBLE* `src/ast/type.rb:1267` (apply_bg_capture_symbol!) -- 4 condition atoms in `(storage == :multiowned || storage == :shared) && (!ownership || ownership == :affine)`
  - atoms: `storage == :multiowned | storage == :shared | !ownership | ownership == :affine`
- *POSSIBLE* `src/ast/type.rb:1349` (merge_capabilities_from!) -- 4 condition atoms in `source_ownership && !(preserve_existing && existing_concrete_ownership) && (include_affine_ownership || source_ownership != :affine)`
  - atoms: `source_ownership | !(preserve_existing && existing_concrete_ownership) | include_affine_ownership | source_ownership != :affine`
- *POSSIBLE* `src/mir/lowering/concurrency.rb:619` (bg_capture_materialization) -- 4 condition atoms in `s.requires_setup? || promoted_names[s.name] || outer_ref.nil? || pointer_captures.include?(s.name)`
  - atoms: `s.requires_setup? | promoted_names[s.name] | outer_ref.nil? | pointer_captures.include?(s.name)`
- *POSSIBLE* `src/mir/lowering/expressions.rb:2017` (lower_copy) -- 5 condition atoms in `ti.any_sync? || ti.collection_value? || ti.collection? || (ti.struct? && ti.needs_promotion?(mir_schema_lookup))`
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

## Broken Protocols (374)
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
- *POSSIBLE* conf=0.92 support=34 `src/mir/lower/pipeline/pipeline_host.rb:529` (visit) does `visit_mir` without `new`
- *POSSIBLE* conf=0.92 support=34 `src/mir/lower/pipeline/pipeline_host.rb:704` (visit_pipeline_expr_mir) does `visit_mir` without `new`
- ...(+349 more)

## Implicit Control Flow (75)
_state-dependent internal call order exists -- hidden lifecycle/control-flow pressure_

- *POSSIBLE* [protocol_pressure] support=31 `with_new_scope -> current_scope` (write_read state=`scope_stack`) -- `src/annotator/domains/control_flow.rb:82` (analyze_control_flow_branch)
  - sites: `src/annotator/domains/control_flow.rb:82` (analyze_control_flow_branch) ; `src/annotator/domains/control_flow.rb:112` (visit_BlockExpr) ; `src/annotator/domains/execution_boundaries.rb:12` (visit_WithBlock) ; `src/annotator/helpers/capabilities.rb:635` (visit_post_clauses!) (+27 more)
- *POSSIBLE* [protocol_pressure] support=20 `current -> consume` (read_write state=`pos`) -- `src/ast/parser.rb:793` (parse_tight_stmt)
  - sites: `src/ast/parser.rb:793` (parse_tight_stmt) ; `src/ast/parser.rb:862` (parse_argument_list) ; `src/ast/parser.rb:1167` (parse_union_def) ; `src/ast/parser.rb:1269` (parse_function_def) (+16 more)
- *POSSIBLE* [protocol_pressure] support=9 `consume -> current` (write_read state=`pos`) -- `src/ast/parser.rb:1269` (parse_function_def)
  - sites: `src/ast/parser.rb:1269` (parse_function_def) ; `src/ast/parser.rb:1652` (parse_effects_decl) ; `src/ast/parser.rb:1916` (parse_unary) ; `src/ast/parser.rb:2290` (parse_struct_pattern) (+5 more)
- *POSSIBLE* [protocol_pressure] support=6 `consume_number -> consume` (read_write|write_read|write_write state=`pos`) -- `src/ast/parser.rb:1652` (parse_effects_decl)
  - sites: `src/ast/parser.rb:1652` (parse_effects_decl) ; `src/ast/parser.rb:1916` (parse_unary) ; `src/ast/parser.rb:2732` (parse_type_annotation) ; `src/ast/parser.rb:3143` (apply_capability!) (+2 more)
- *POSSIBLE* [protocol_pressure] support=3 `consume -> consume_number` (read_write|write_read|write_write state=`pos`) -- `src/ast/parser.rb:3143` (apply_capability!)
  - sites: `src/ast/parser.rb:3143` (apply_capability!) ; `src/ast/parser.rb:3530` (match_optional_retry!) ; `src/ast/parser.rb:3647` (parse_lock_rank_arg!)
- *POSSIBLE* [protocol_pressure] support=3 `with_context_state -> current_context` (write_read state=`pipeline_context`) -- `src/mir/lower/pipeline/pipeline_host.rb:435` (with_pipeline_context)
  - sites: `src/mir/lower/pipeline/pipeline_host.rb:435` (with_pipeline_context) ; `src/mir/lower/pipeline/pipeline_host.rb:444` (with_soa_rewrite) ; `src/mir/lower/pipeline/pipeline_host.rb:498` (with_named_binding)
- *POSSIBLE* [protocol_pressure] support=3 `peek -> consume` (read_write state=`pos`) -- `src/ast/parser.rb:1759` (parse_expression)
  - sites: `src/ast/parser.rb:1759` (parse_expression) ; `src/ast/parser.rb:2642` (parse_window_op) ; `src/ast/parser.rb:2699` (parse_fn_type_annotation)
- *POSSIBLE* [protocol_pressure] support=2 `apply_capabilities! -> ownership` (write_read state=`capabilities`) -- `src/ast/type.rb:1255` (apply_symbol_overlay!)
  - sites: `src/ast/type.rb:1255` (apply_symbol_overlay!) ; `src/ast/type.rb:1265` (apply_bg_capture_symbol!)
- *POSSIBLE* [protocol_pressure] support=2 `apply_capabilities! -> sync` (write_read state=`capabilities`) -- `src/ast/type.rb:1290` (copy_declared_collection_modifiers_from!)
  - sites: `src/ast/type.rb:1290` (copy_declared_collection_modifiers_from!) ; `src/ast/type.rb:1346` (merge_capabilities_from!)
- *POSSIBLE* [protocol_pressure] support=2 `try_parse_bind_or_assign -> current` (write_read state=`pos`) -- `src/ast/parser.rb:711` (parse_statement)
  - sites: `src/ast/parser.rb:711` (parse_statement) ; `src/ast/parser.rb:3870` (parse_bg_body_stmt)
- *POSSIBLE* [protocol_pressure] support=2 `verify_ownership_contract_operands! -> check_consumed_allocators_match_sink!` (read_write|write_read|write_write state=`errors`) -- `src/mir/mir_checker.rb:2204` (verify_callable_contract!)
  - sites: `src/mir/mir_checker.rb:2204` (verify_callable_contract!) ; `src/mir/mir_checker.rb:2291` (verify_explicit_ownership_contracts!)
- *POSSIBLE* [protocol_pressure] support=2 `current -> consume_number` (read_write state=`pos`) -- `src/ast/parser.rb:1652` (parse_effects_decl)
  - sites: `src/ast/parser.rb:1652` (parse_effects_decl) ; `src/ast/parser.rb:1916` (parse_unary)
- *POSSIBLE* [protocol_pressure] support=2 `current -> try_parse_bind_or_assign` (read_write state=`pos`) -- `src/ast/parser.rb:711` (parse_statement)
  - sites: `src/ast/parser.rb:711` (parse_statement) ; `src/ast/parser.rb:3870` (parse_bg_body_stmt)
- *POSSIBLE* [protocol_pressure] support=2 `peek_at -> consume` (read_write state=`pos`) -- `src/ast/parser.rb:862` (parse_argument_list)
  - sites: `src/ast/parser.rb:862` (parse_argument_list) ; `src/ast/parser.rb:1962` (parse_var_id)
- *POSSIBLE* [protocol_pressure] support=2 `provenance -> apply_placement!` (read_write state=`placement`) -- `src/ast/type.rb:1136` (copy_placement_from!)
  - sites: `src/ast/type.rb:1136` (copy_placement_from!) ; `src/ast/type.rb:1143` (apply_cleanup_placement!)
- *POSSIBLE* [protocol_pressure] support=2 `test_hook_match? -> consume` (read_write state=`pos`) -- `src/ast/parser.rb:3993` (parse_test_block)
  - sites: `src/ast/parser.rb:3993` (parse_test_block) ; `src/ast/parser.rb:4067` (parse_when_block)
- *POSSIBLE* [protocol_pressure] support=1 `apply_capabilities! -> collection` (write_read state=`capabilities`) -- `src/ast/type.rb:1273` (copy_collection_shape_from!)
  - sites: `src/ast/type.rb:1273` (copy_collection_shape_from!)
- *POSSIBLE* [protocol_pressure] support=1 `apply_capabilities! -> shard_count` (write_read state=`capabilities`) -- `src/ast/type.rb:1282` (copy_topology_from!)
  - sites: `src/ast/type.rb:1282` (copy_topology_from!)
- *POSSIBLE* [protocol_pressure] support=1 `check_linear_expr_uses! -> linear_merge_branch_states!` (read_write|write_read|write_write state=`errors`) -- `src/mir/mir_checker.rb:575` (check_linear_stmt!)
  - sites: `src/mir/mir_checker.rb:575` (check_linear_stmt!)
- *POSSIBLE* [protocol_pressure] support=1 `check_linear_expr_uses! -> linear_require_same_state!` (read_write|write_read|write_write state=`errors`) -- `src/mir/mir_checker.rb:575` (check_linear_stmt!)
  - sites: `src/mir/mir_checker.rb:575` (check_linear_stmt!)
- *POSSIBLE* [protocol_pressure] support=1 `check_reassign_cleanup_alloc! -> check_aggregate_expr!` (read_write|write_read|write_write state=`errors`) -- `src/mir/mir_checker.rb:1127` (check_aggregate_stmts!)
  - sites: `src/mir/mir_checker.rb:1127` (check_aggregate_stmts!)
- *POSSIBLE* [protocol_pressure] support=1 `clear_synthetic_function_definitions! -> synthetic_function_definitions` (write_read state=`semantic_function_registry`) -- `src/annotator/phases/signature_registration.rb:16` (register_program_signatures)
  - sites: `src/annotator/phases/signature_registration.rb:16` (register_program_signatures)
- *POSSIBLE* [protocol_pressure] support=1 `consume -> previous` (write_read state=`pos`) -- `src/ast/parser.rb:847` (parse_die)
  - sites: `src/ast/parser.rb:847` (parse_die)
- *POSSIBLE* [protocol_pressure] support=1 `declare_and_verify_params -> declare_captures` (read_write|write_read|write_write state=`current_scope`) -- `src/annotator/helpers/function_analysis.rb:89` (analyze_routine)
  - sites: `src/annotator/helpers/function_analysis.rb:89` (analyze_routine)
- *POSSIBLE* [protocol_pressure] support=1 `declare_assignment_graph_path! -> og_set_moved` (write_read state=`ownership_graph`) -- `src/annotator/domains/lifetimes.rb:362` (handle_assignment_path_move!)
  - sites: `src/annotator/domains/lifetimes.rb:362` (handle_assignment_path_move!)
- ...(+50 more)

## Weighted Inlined Cognitive Complexity (476)
_same-owner helper chain hides cognitive load behind a low-looking orchestration method_

- *POSSIBLE* `src/tools/doctor.rb:37` (run) -- inlined=552.4 (local=6.0, hidden=546.4, depth=2)
  - chain: `run -> section_locks`
  - single-caller helpers: `run_diff | run_peek | section_atomic_escape | section_channels | section_cpu | section_fibers | section_freeze | section_hardware`
  - reason: 11 single-caller helper(s) add 546.4 weighted cognitive points
- *POSSIBLE* `src/mir/mir_checker.rb:356` (check_fn!) -- inlined=475.9 (local=27.0, hidden=448.9, depth=2)
  - chain: `check_fn! -> verify_ownership_surfaces_finalized!`
  - single-caller helpers: `allocator_metadata_node? | scan_expr_for_hpt_leak! | verify_aggregate_owned_children! | verify_alloc_cleanup_match! | verify_alloc_marks_typed! | verify_allocating_lets_marked! | verify_allocator_closed_set! | verify_allocator_metadata_contracts!`
  - reason: 26 single-caller helper(s) add 448.9 weighted cognitive points
- *POSSIBLE* `src/tools/formatter.rb:321` (emit) -- inlined=393.6 (local=1.0, hidden=392.6, depth=2)
  - chain: `emit -> expand_method_chains`
  - single-caller helpers: `canonicalize_numerics | collapse_newlines | expand_bg_do_blocks | expand_call_args | expand_concurrent_drops | expand_fn_blocks | expand_method_chains | expand_pipelines`
  - reason: 12 single-caller helper(s) add 392.6 weighted cognitive points
- *POSSIBLE* `src/annotator/helpers/pipe_analysis.rb:212` (analyze_higher_order_op) -- inlined=280.1 (local=3.5, hidden=276.6, depth=2)
  - chain: `analyze_higher_order_op -> analyze_concurrent_op`
  - single-caller helpers: `analyze_all_op | analyze_any_op | analyze_batch_window_op | analyze_collect_op | analyze_concurrent_op | analyze_distinct_op | analyze_find_op | analyze_join_op`
  - reason: 17 single-caller helper(s) add 276.6 weighted cognitive points
- *POSSIBLE* `src/mir/mir_emitter.rb:53` (emit) -- inlined=216.5 (local=1.5, hidden=215.0, depth=2)
  - chain: `emit -> emit_extern_trampoline`
  - single-caller helpers: `emit_alloc_slice | emit_allocator_ref | emit_array_default_init | emit_array_init | emit_assert_raises_check | emit_assert_stmt | emit_batch_window_flush | emit_batch_window_push`
  - reason: 106 single-caller helper(s) add 215.0 weighted cognitive points
- *POSSIBLE* `src/mir/mir_checker.rb:1233` (check_program!) -- inlined=228.3 (local=16.3, hidden=212.0, depth=2)
  - chain: `check_program! -> ownership_registry_errors`
  - single-caller helpers: `check_fn! | ownership_registry_errors`
  - reason: 2 single-caller helper(s) add 212.0 weighted cognitive points
- *POSSIBLE* `src/mir/lowering/variables.rb:147` (lower_var_decl) -- inlined=208.9 (local=6.0, hidden=202.9, depth=2)
  - chain: `lower_var_decl -> lower_var_decl_init`
  - single-caller helpers: `ensure_cleanup_binding_owns_string_init | field_owner_move_marks | lower_var_decl_init | stamp_var_decl_init_target! | var_decl_facts | var_decl_materialization_plan | var_decl_safe_name | var_decl_source_transfer_required?`
  - reason: 9 single-caller helper(s) add 202.9 weighted cognitive points
- *POSSIBLE* `src/tools/method_rewriter.rb:168` (compute_edit) -- inlined=162.5 (local=15.8, hidden=146.7, depth=1)
  - chain: `compute_edit -> match_paren`
  - single-caller helpers: `match_paren | needs_parens? | next_non_ws | offset_for | split_args_by_comma`
  - reason: 5 single-caller helper(s) add 146.7 weighted cognitive points
- *POSSIBLE* `src/annotator/helpers/function_analysis.rb:89` (analyze_routine) -- inlined=167.1 (local=23.5, hidden=143.6, depth=1)
  - chain: `analyze_routine -> declare_and_verify_params`
  - single-caller helpers: `collect_routine_returns | declare_and_verify_params | declare_captures | verify_captures! | verify_returns | with_routine_analysis_scope`
  - reason: 6 single-caller helper(s) add 143.6 weighted cognitive points
- *POSSIBLE* `src/mir/fsm_transform/emit.rb:687` (build_recursive) -- inlined=243.8 (local=108.5, hidden=135.3, depth=2)
  - chain: `build_recursive -> build_fsm_unified`
  - single-caller helpers: `build_fsm_unified | build_segment_descriptor | check_fsm_cleanup_invariant! | compute_sp_indices | expand_lock_segment | fsm_destroy_finalizer_name | fsm_owned_result_guards | lift_ctx_cleanups_to_destroy!`
  - reason: 11 single-caller helper(s) add 135.3 weighted cognitive points
- *POSSIBLE* `src/ast/parser.rb:991` (parse_visibility_decl) -- inlined=149.3 (local=15.0, hidden=134.3, depth=2)
  - chain: `parse_visibility_decl -> parse_function_def`
  - single-caller helpers: `parse_enum_def | parse_function_def | parse_struct_def | parse_union_def`
  - reason: 4 single-caller helper(s) add 134.3 weighted cognitive points
- *POSSIBLE* `src/tools/formatter.rb:2631` (format_line_body) -- inlined=139.3 (local=12.0, hidden=127.3, depth=2)
  - chain: `format_line_body -> needs_space?`
  - single-caller helpers: `canonicalize_comment | compute_generic_bracket_indices | compute_struct_lit_brace_indices | needs_space?`
  - reason: 4 single-caller helper(s) add 127.3 weighted cognitive points
- *POSSIBLE* `src/annotator/helpers/pipe_analysis.rb:1445` (analyze_concurrent_op) -- inlined=197.2 (local=71.0, hidden=126.2, depth=2)
  - chain: `analyze_concurrent_op -> analyze_concurrent_bounded_each_op`
  - single-caller helpers: `analyze_auto_shard_each_op | analyze_concurrent_bounded_each_op | analyze_concurrent_bounded_select_family_op | analyze_concurrent_stream_each_op | analyze_concurrent_stream_select_family_op | analyze_shard_each_op | collect_sharded_names | concurrent_stream_source?`
  - reason: 11 single-caller helper(s) add 126.2 weighted cognitive points
- *POSSIBLE* `src/mir/lowering/functions.rb:291` (lower_function_def) -- inlined=177.2 (local=53.8, hidden=123.4, depth=2)
  - chain: `lower_function_def -> build_post_outer_fn`
  - single-caller helpers: `activate_function_context | body_has_faulting_alloc? | build_catch_clauses | build_post_inner_fn | build_post_outer_fn | collect_catch_reassigns | faulting_return_type_str | finalized_needs_rt!`
  - reason: 12 single-caller helper(s) add 123.4 weighted cognitive points
- *POSSIBLE* `src/tools/predicate_rewriter.rb:337` (rightmost_compact_offset) -- inlined=123.8 (local=1.8, hidden=122.0, depth=2)
  - chain: `rightmost_compact_offset -> walk_to_expr_end`
  - single-caller helpers: `walk_to_expr_end`
  - reason: 1 single-caller helper(s) add 122.0 weighted cognitive points
- *POSSIBLE* `src/tools/formatter.rb:1156` (expand_then_do_blocks) -- inlined=115.4 (local=6.8, hidden=108.6, depth=2)
  - chain: `expand_then_do_blocks -> expand_if_while_for`
  - single-caller helpers: `branch_end_for_inline_expansion | expand_if_while_for | one_liner_end`
  - reason: 3 single-caller helper(s) add 108.6 weighted cognitive points
- *POSSIBLE* `src/annotator/helpers/lock_helper.rb:340` (check_lock_cycles!) -- inlined=114.9 (local=7.0, hidden=107.9, depth=2)
  - chain: `check_lock_cycles! -> propagate_lock_acquires!`
  - single-caller helpers: `check_lock_handler_reachability! | propagate_lock_acquires! | report_lock_cycle! | resolve_held_calls! | scc_is_cyclic?`
  - reason: 5 single-caller helper(s) add 107.9 weighted cognitive points
- *POSSIBLE* `src/ast/parser.rb:1269` (parse_function_def) -- inlined=169.0 (local=65.0, hidden=104.0, depth=2)
  - chain: `parse_function_def -> parse_effects_decl`
  - single-caller helpers: `parse_catch_filter | parse_catch_item | parse_effects_decl | parse_requires_clause | parse_requires_clauses | source_slice_between`
  - reason: 6 single-caller helper(s) add 104.0 weighted cognitive points
- *POSSIBLE* `src/tools/formatter.rb:549` (emit_match_block) -- inlined=103.2 (local=1.0, hidden=102.2, depth=2)
  - chain: `emit_match_block -> scan_match_arms`
  - single-caller helpers: `emit_match_arm | scan_match_arms`
  - reason: 2 single-caller helper(s) add 102.2 weighted cognitive points
- *POSSIBLE* `src/tools/doctor.rb:1383` (run_diff) -- inlined=108.4 (local=6.5, hidden=101.9, depth=2)
  - chain: `run_diff -> diff_locks`
  - single-caller helpers: `diff_heap | diff_locks | diff_mvcc`
  - reason: 3 single-caller helper(s) add 101.9 weighted cognitive points
- *POSSIBLE* `src/annotator/helpers/pipe_analysis.rb:63` (visit_Smooth) -- inlined=116.3 (local=15.0, hidden=101.3, depth=2)
  - chain: `visit_Smooth -> analyze_higher_order_op -> analyze_concurrent_op`
  - single-caller helpers: `analyze_higher_order_op | analyze_pipe_to_func_call | analyze_pipe_to_identifier | pipe_complex_op?`
  - reason: 4 single-caller helper(s) add 101.3 weighted cognitive points
- *POSSIBLE* `src/semantic/concurrency_checks.rb:45` (check_all!) -- inlined=102.3 (local=4.0, hidden=98.3, depth=2)
  - chain: `check_all! -> check_reentrant!`
  - single-caller helpers: `check_hold_across_yield! | check_naked_nested_with! | check_reentrant!`
  - reason: 3 single-caller helper(s) add 98.3 weighted cognitive points
- *POSSIBLE* `src/mir/lowering/control_flow.rb:305` (lower_for_each) -- inlined=98.4 (local=4.0, hidden=94.4, depth=2)
  - chain: `lower_for_each -> for_each_loop_stmt`
  - single-caller helpers: `for_each_loop_stmt | for_each_plan`
  - reason: 2 single-caller helper(s) add 94.4 weighted cognitive points
- *POSSIBLE* `src/annotator/helpers/function_analysis.rb:540` (verify_function_signature!) -- inlined=101.3 (local=7.0, hidden=94.3, depth=2)
  - chain: `verify_function_signature! -> verify_param_lifetime!`
  - single-caller helpers: `call_argument_facts | call_arity_plan | call_signature_site | inject_default_arguments! | verify_argument_aliases! | verify_argument_type! | verify_call_arity! | verify_link_argument!`
  - reason: 12 single-caller helper(s) add 94.3 weighted cognitive points
- *POSSIBLE* `src/mir/mir_lowering.rb:877` (lower) -- inlined=99.3 (local=5.8, hidden=93.5, depth=2)
  - chain: `lower -> apply_lowered_coercion -> mir_cast`
  - single-caller helpers: `apply_lowered_coercion | lower_cast | lower_drop | lower_enum_def | lower_or_exit | lower_program | lower_static_call | lower_struct_def`
  - reason: 10 single-caller helper(s) add 93.5 weighted cognitive points
- ...(+451 more)

## Operational Discontinuity (High Confidence) (13)
_strong blank/comment phase boundary where local variable lifetimes reset -- likely implicit sub-function boundary_

- *POSSIBLE* `src/backends/transpiler.rb:66` (transpile_mir) -- score=101 reset_boundaries=3, dead=23, new=56, confidence=high (repeated_resets, high_score)
  - line 71 blank: dead `default_stack | pkg_paths | source_dir | test_mode` -> new `bg_nodes | body | cheat_code | checker | emitter | error_name_enum`
  - line 74 # Apply exact stack tier overrides (from post-build binary analysis).: dead `cheat_code | default_stack | pkg_paths | source_dir | strict_test | test_mode` -> new `bg_nodes | body | checker | emitter | error_name_enum | exact_tiers` (continuing `result`)
  - line 87 blank: dead `bg_nodes | cheat_code | default_stack | exact_tiers | idx | n` -> new `body | checker | emitter | error_name_enum | footer | lowering` (continuing `result`)
- *POSSIBLE* `src/backends/importer.rb:86` (compile_file) -- score=54 reset_boundaries=3, dead=12, new=21, confidence=high (repeated_resets, high_score)
  - line 95 blank: dead `caller_dir | cycle | p | path` -> new `annotator | ast | mod | saved_gradual | source | source_dir` (continuing `abs_path`)
  - line 97 blank: dead `caller_dir | cycle | p | path` -> new `annotator | ast | mod | saved_gradual | source | source_dir` (continuing `abs_path`)
  - line 99 blank: dead `caller_dir | cycle | p | path` -> new `annotator | ast | mod | saved_gradual | source | source_dir` (continuing `abs_path`)
- *POSSIBLE* `src/backends/transpiler.rb:161` (transpile_as_module) -- score=50 reset_boundaries=2, dead=5, new=30, confidence=high (repeated_resets, high_score)
  - line 164 blank: dead `pkg_paths | source_dir` -> new `all_items | body | cheat_code | checker | emitter | has_cheat_main`
  - line 166 blank: dead `cheat_code | pkg_paths | source_dir` -> new `all_items | body | checker | emitter | has_cheat_main | item` (continuing `result`)
- *POSSIBLE* `src/mir/lowering/expressions.rb:374` (classify_binary_operation) -- score=39 reset_boundaries=3, dead=9, new=9, confidence=high (repeated_resets, high_score)
  - line 385 blank: dead `optional_plan | string_plan` -> new `builtin | op_str | union_error_type | unit_plan` (continuing `facts`)
  - line 388 blank: dead `builtin | optional_plan | string_plan` -> new `op_str | union_error_type | unit_plan` (continuing `facts`)
  - line 391 blank: dead `builtin | optional_plan | string_plan | unit_plan` -> new `op_str | union_error_type` (continuing `facts`)
- *POSSIBLE* `src/mir/mir_checker.rb:1908` (verify_allocator_closed_set!) -- score=38 reset_boundaries=2, dead=12, new=12, confidence=high (repeated_resets, high_score)
  - line 1925 blank: dead `allocs | mark | marks | scope` -> new `alloc | alloc_key | cleanup | cleanups | metadata | metadata_nodes` (continuing `name`)
  - line 1934 blank: dead `allocs | cleanup | cleanups | mark | marks | name` -> new `alloc_key | metadata | metadata_nodes | node` (continuing `alloc`)
- *POSSIBLE* `src/mir/fsm_lowering.rb:79` (lower_step_stmts) -- score=35 reset_boundaries=1, dead=3, new=25, confidence=high (high_score)
  - line 89 blank: dead `s | stmt | stmts` -> new `chunk | ctx_id | ctx_ident | expr_t | expr_type | guard_map` (continuing `flat_steps`)
- *POSSIBLE* `src/mir/lowering/expressions.rb:227` (lower_identifier) -- score=32 reset_boundaries=2, dead=6, new=12, confidence=high (repeated_resets, high_score)
  - line 246 # Inside a WITH EXCLUSIVE block, rewrite original var name to the unwrapped inner alias: dead `line | rc_map` -> new `alias_name | capture_map | decl_node | ident | locked_map | symbol` (continuing `node`)
  - line 251 # Inside a DO block branch, access captured outer variables via ctx pointer: dead `alias_name | line | locked_map | rc_map` -> new `capture_map | decl_node | ident | symbol | zig_name` (continuing `node`)
- *POSSIBLE* `src/mir/lowering/control_flow.rb:1224` (universal_poly_arg_needs_addr?) -- score=28 reset_boundaries=2, dead=9, new=4, confidence=high (repeated_resets, high_score)
  - line 1232 # Universal poly: REQUIRES key present AND the family-set is empty.: dead `callee_sig | idx | param | pname` -> new `arg_node | sym` (continuing `fams`)
  - line 1234 # The arg must be a plain (no-sync, no-Arc, no-pointer) struct: dead `callee_sig | fams | idx | param | pname` -> new `arg_node | sym`
- *POSSIBLE* `src/mir/fsm_transform/liveness.rb:51` (analyze) -- score=25 reset_boundaries=1, dead=2, new=16, confidence=high (high_score)
  - line 54 blank: dead `captured | ctx` -> new `cross | cyclic_segs | def_seg | defs | defs_by_seg | first_def` (continuing `capture_names`)
- *POSSIBLE* `src/mir/control_flow.rb:1632` (self.expression_allocates_frame_value?) -- score=24 reset_boundaries=2, dead=5, new=5, confidence=high (repeated_resets, high_score)
  - line 1639 blank: dead `fn | fn_nodes` -> new `sig | storage | type_info` (continuing `node`)
  - line 1645 blank: dead `fn | fn_nodes | sig` -> new `storage | type_info` (continuing `node`)
- *POSSIBLE* `src/tools/doctor.rb:1160` (section_hardware) -- score=23 reset_boundaries=1, dead=4, new=12, confidence=high (high_score)
  - line 1177 # Derived metrics: dead `l | m | perf_stat_file | profile_dir` -> new `branch_miss | branch_miss_pct | branch_note | branches | cycles | instructions` (continuing `hw`)
- *POSSIBLE* `src/mir/lowering/expressions.rb:1868` (try_lower_equality_assert) -- score=22 reset_boundaries=1, dead=3, new=12, confidence=high (high_score)
  - line 1881 blank: dead `has_message | node | raw` -> new `arg | args_mir | contract | extra_args | helper | idx` (continuing `cond`)
- *POSSIBLE* `src/mir/lower/pipeline/pipeline_set_index_lowerer.rb:195` (lower_stream_index) -- score=21 reset_boundaries=1, dead=2, new=12, confidence=high (high_score)
  - line 204 blank: dead `elem_zig | var` -> new `defer_deinit | elem_type | expr_mir | expr_node | item_var | iter` (continuing `on_skip`)

## Function LCOM (19)
_independent local data-flow components inside one method -- *POSSIBLE* mixed concerns_

- *POSSIBLE* [late_join] `src/mir/lower/pipeline/pipeline_range_lowerer.rb:307` (build_lazy_range_prefix) -- score=64 components=2, locals=24, statements=15
  - component 1: `elem_t | elem_zig | is_var_stream | next_method | range_let | source_name | source_node | source_ti` (lines 308-380)
  - component 2: `cnt_mir | cnt_var | cvar | expr_mir | initial_capture | item_counter | item_var | next_item` (lines 312-319)
- *POSSIBLE* [late_join] `src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb:525` (build_bounded_concurrent_callback) -- score=58 components=2, locals=18, statements=15
  - component 1: `ctx_name | id` (lines 526-527)
  - component 2: `body | body_kind | caps | capture_map | capture_symbols | conc_op | fields | fn` (lines 528-553)
- *POSSIBLE* [disjoint] `src/tools/doctor.rb:1297` (run_peek) -- score=57 components=2, locals=19, statements=18
  - component 1: `binary | profile_dir` (lines 1298-1305)
  - component 2: `a | callee_func | callees | caller_func | callers | f | func | funcs` (lines 1305-1356)
- *POSSIBLE* [late_join] `src/tools/atomic_migration_suggester.rb:64` (candidate_decl_info) -- score=54 components=2, locals=11, statements=18
  - component 1: `annotator | fields | line | node | schema | ti | val` (lines 65-90)
  - component 2: `field_def | field_resolved | field_type` (lines 85-88)
- *POSSIBLE* [late_join] `src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb:1051` (build_bounded_concurrent_callback_pointer) -- score=53 components=2, locals=14, statements=14
  - component 1: `ctx_name | id` (lines 1052-1053)
  - component 2: `body | caps | capture_map | capture_symbols | conc_op | fields | fn | item_type` (lines 1054-1077)
- *POSSIBLE* [late_join] `src/mir/test_lowering.rb:325` (stub_intercept_for) -- score=53 components=2, locals=18, statements=10
  - component 1: `fn_name | stub_info` (lines 327-328)
  - component 2: `args | call_inputs | n | nm | receiver | suppress_names | suppress_stmts` (lines 330-332)
- *POSSIBLE* [late_join] `src/mir/lower/pipeline/pipeline_binding_chain_lowerer.rb:109` (lower) -- score=50 components=2, locals=15, statements=10
  - component 1: `bindings | chain | inner_name | inner_zig | outer_name | outer_zig` (lines 110-118)
  - component 2: `label | names` (lines 114-116)
- *POSSIBLE* [late_join] `src/mir/lowering/expressions.rb:772` (smooth_collect_block) -- score=49 components=2, locals=14, statements=10
  - component 1: `acc_zig | collect_cleanup | collect_source_alloc | ft | left | left_effect` (lines 774-781)
  - component 2: `block_id | collect_var | label | val_var` (lines 775-778)
- *POSSIBLE* [late_join] `src/mir/lowering/functions.rb:455` (function_lowering_context) -- score=49 components=2, locals=14, statements=10
  - component 1: `bindings | collection_params | fact | has_catch | mutable_scalar_params | name | node | param_facts` (lines 457-468)
  - component 2: `return_payload | return_type_info | return_type_node` (lines 469-470)
- *POSSIBLE* [disjoint] `src/mir/mir_lowering.rb:3498` (with_fiber_capture_map) -- score=49 components=3, locals=8, statements=11
  - component 1: `new_entries | prev_map` (lines 3499-3506)
  - component 2: `capture_symbols | prev_syms` (lines 3500-3507)
  - component 3: `blk | result` (lines 3505-3509)
- *POSSIBLE* [disjoint] `src/mir/mir_pass.rb:104` (transform!) -- score=45 components=2, locals=8, statements=17
  - component 1: `ast | pass_state | stmt` (lines 105-164)
  - component 2: `cleanup_plan | fn | name | sig` (lines 123-160)
- *POSSIBLE* [late_join] `src/mir/lowering/control_flow.rb:209` (prepend_loop_mark) -- score=44 components=2, locals=10, statements=9
  - component 1: `after_mark | body | mark_per_iter | needs_mark | suffix | tight` (lines 211-213)
  - component 2: `mark_var | restore | rt | save` (lines 214-217)
- *POSSIBLE* [late_join] `src/ast/parser.rb:2370` (parse_raise_stmt) -- score=43 components=2, locals=7, statements=11
  - component 1: `msg | tok` (lines 2371-2380)
  - component 2: `error_name | first_is_kind | first_tok | kind` (lines 2385-2392)
- *POSSIBLE* [late_join] `src/tools/clear_fix_support.rb:63` (self.parse_args) -- score=43 components=2, locals=8, statements=10
  - component 1: `dry_run | loop_until_clean` (lines 64-94)
  - component 2: `arg | args | paths` (lines 69-93)
- *POSSIBLE* [late_join] `src/ast/parser.rb:1988` (parse_if_chain) -- score=42 components=2, locals=8, statements=9
  - component 1: `bindings | condition | if_token | name_tok | stmt` (lines 1989-2014)
  - component 2: `else_branch | nested_if` (lines 2022-2023)
- *POSSIBLE* [late_join] `src/mir/lower/pipeline/pipeline_host.rb:714` (lower_soa_scalar_fold) -- score=42 components=2, locals=8, statements=9
  - component 1: `list_node | site | source_mir` (lines 715-717)
  - component 2: `expr_mir | fold_node | needs_whole_item` (lines 720-724)
- *POSSIBLE* [disjoint] `src/mir/lowering/control_flow.rb:1224` (universal_poly_arg_needs_addr?) -- score=41 components=2, locals=7, statements=14
  - component 1: `callee_sig | fams | idx | param | pname` (lines 1226-1233)
  - component 2: `arg_node | sym` (lines 1237-1246)
- *POSSIBLE* [disjoint] `src/mir/fsm_transform/emit.rb:609` (build_dispatch_tail) -- score=40 components=2, locals=12, statements=8
  - component 1: `_ | all_specs | k` (lines 610-611)
  - component 2: `condition | desc | desc_tail | explicit_next | index | next_step | spec | tail` (lines 612-624)
- *POSSIBLE* [late_join] `src/mir/lower/pipeline/pipeline_each_lowerer.rb:245` (lower_range_literal_each) -- score=40 components=2, locals=8, statements=7
  - component 1: `end_expr | end_mir | list_node | range | start_mir` (lines 246-249)
  - component 2: `capture_name | each_op | range_body_mir` (lines 250-251)

## Operational Discontinuity (27)
_blank/comment phase boundary where local variable lifetimes reset -- *POSSIBLE* implicit sub-function boundary_

- *POSSIBLE* `src/ast/parser.rb:3870` (parse_bg_body_stmt) -- score=28 reset_boundaries=2, dead=4, new=9, confidence=review
  - line 3880 blank: dead `result | rule` -> new `binding_name | expr | next_binding | next_expr | steps`
  - line 3883 # THEN chain: expr [AS name] THEN expr [AS name] THEN ...: dead `result | rule` -> new `binding_name | next_binding | next_expr | steps` (continuing `expr`)
- *POSSIBLE* `src/ast/type.rb:745` (initialize) -- score=19 reset_boundaries=1, dead=3, new=8, confidence=review
  - line 764 # Capability fields — set after parse/copy so explicit constructor: dead `auto | other | raw_input` -> new `collection | layout | location | observable | observable_terminal | ownership`
- *POSSIBLE* `src/mir/fsm_transform/emit.rb:1153` (check_fsm_cleanup_invariant!) -- score=19 reset_boundaries=1, dead=4, new=8, confidence=review
  - line 1161 blank: dead `captured | conservative_promoted | forbidden | liveness` -> new `code | i | name | node | seg_codes | seg_idx` (continuing `forbidden_set`)
- *POSSIBLE* `src/tools/doctor.rb:37` (run) -- score=18 reset_boundaries=1, dead=6, new=5, confidence=review
  - line 52 blank: dead `by | cumulative | diff | focus | ignore | peek` -> new `binary | llc_miss_rate | perf_data | resolved | sites` (continuing `profile_dir`)
- *POSSIBLE* `src/mir/thunk_transform/recursive_splitter.rb:94` (split) -- score=17 reset_boundaries=1, dead=2, new=8, confidence=review
  - line 98 # Walk top-level statements: zero or more IF base-cases: dead `_ | lowering` -> new `base_cases | bc | combine | final | fn_name | i` (continuing `body`)
- *POSSIBLE* `src/ast/parser.rb:1916` (parse_unary) -- score=16 reset_boundaries=1, dead=3, new=5, confidence=review
  - line 1924 # Call-site override syntax is reserved here; the annotator rejects it: dead `op_token | right | v` -> new `inner | n | n_lit | n_tok | sigil_tok`
- *POSSIBLE* `src/mir/mir_checker.rb:2087` (verify_cross_frame_param_alloc!) -- score=16 reset_boundaries=1, dead=3, new=6, confidence=review
  - line 2097 blank: dead `fn_def | p | set` -> new `alloc_key | alloc_sym | metadata | metadata_nodes | node | target` (continuing `pointer_passed`)
- *POSSIBLE* `src/ast/parser.rb:3596` (parse_cap_join) -- score=15 reset_boundaries=1, dead=2, new=6, confidence=review
  - line 3600 blank: dead `first_attrs | tok` -> new `attrs | candidates | has_at | k | next_tok | normalized` (continuing `dims`)
- *POSSIBLE* `src/mir/lower/pipeline/pipeline_host.rb:527` (visit) -- score=15 reset_boundaries=1, dead=6, new=2, confidence=review
  - line 555 # Before sending to MIRLowering, substitute _ placeholders and join: dead `assignment | context | field | replacement | target | value` -> new `mir_node | substituted` (continuing `node`)
- *POSSIBLE* `src/mir/lower/pipeline/pipeline_list_lowerer.rb:449` (join_predicate_mir) -- score=15 reset_boundaries=1, dead=5, new=3, confidence=review
  - line 458 blank: dead `join_node | join_params | left_param | params | right_param` -> new `left_key_mir | list_node | right_key_mir` (continuing `key_expr`)
- *POSSIBLE* `src/mir/lowering/variables.rb:637` (field_owner_move_marks) -- score=15 reset_boundaries=1, dead=2, new=6, confidence=review
  - line 646 blank: dead `node | value` -> new `entry | guarded | guarded_names | rename_map | safe | source_name` (continuing `root`)
- *POSSIBLE* `src/semantic/ownership_graph.rb:287` (prune_scope!) -- score=15 reset_boundaries=1, dead=2, new=6, confidence=review
  - line 290 blank: dead `node | scope_depth` -> new `archive | children | edge | parent | place | place_set` (continuing `places`)
- *POSSIBLE* `src/mir/mir_checker.rb:2806` (check_expr_sources_for_unhoisted) -- score=13 reset_boundaries=1, dead=2, new=4, confidence=review
  - line 2820 blank: dead `kind | owned_position` -> new `child | context | owned_sources | slot` (continuing `expr`)
- *POSSIBLE* `src/tools/clear_build_support.rb:198` (self.build_up_to_date?) -- score=13 reset_boundaries=1, dead=3, new=3, confidence=review
  - line 201 blank: dead `force | module_mode | profile` -> new `config | signature | source` (continuing `output`)
- *POSSIBLE* `src/annotator/domains/lifetimes.rb:777` (lookup_source_name) -- score=12 reset_boundaries=1, dead=3, new=2, confidence=review
  - line 786 # Param symbols may have been refreshed via Scope.live_param_syms;: dead `entry | name | sc` -> new `fn | p` (continuing `sym`)
- *POSSIBLE* `src/annotator/phases/body_analysis.rb:435` (analyze_program_bodies!) -- score=12 reset_boundaries=1, dead=2, new=2, confidence=review
  - line 439 blank: dead `declarations | stmt` -> new `fn | program`
- *POSSIBLE* `src/ast/parser.rb:2888` (type_annotation_source) -- score=12 reset_boundaries=1, dead=2, new=3, confidence=review
  - line 2896 blank: dead `inner | type` -> new `ownership | parts | sync` (continuing `t`)
- *POSSIBLE* `src/mir/lower/pipeline/pipeline_context.rb:217` (substitute_get_field) -- score=12 reset_boundaries=1, dead=3, new=2, confidence=review
  - line 228 blank: dead `new_gi | soa_field | soa_idx` -> new `new_gf | new_target` (continuing `node`)
- *POSSIBLE* `src/mir/lower/pipeline/pipeline_materializer.rb:455` (build_soa_pool) -- score=12 reset_boundaries=1, dead=2, new=3, confidence=review
  - line 458 blank: dead `elem_zig | lhs_type` -> new `alive_check | loop_node | value_expr` (continuing `buffer`)
- *POSSIBLE* `src/mir/lower/pipeline/pipeline_materializer.rb:494` (build_set) -- score=12 reset_boundaries=1, dead=2, new=3, confidence=review
  - line 497 blank: dead `elem_zig | lhs_type` -> new `deref | iter_let | loop_node` (continuing `buffer`)
- *POSSIBLE* `src/mir/lowering/expressions.rb:963` (or_fallback_expected_type) -- score=12 reset_boundaries=1, dead=2, new=3, confidence=review
  - line 969 blank: dead `left_type | success` -> new `error_union | eu_success | eu_type` (continuing `node`)
- *POSSIBLE* `src/mir/lowering/expressions.rb:1483` (aggregate_dynamic_slice_field_value) -- score=12 reset_boundaries=1, dead=2, new=3, confidence=review
  - line 1486 blank: dead `borrowed_field | ft` -> new `ast_node | sink_alloc | source` (continuing `val`)
- *POSSIBLE* `src/mir/mir_lowering.rb:628` (heap_indirect_destination?) -- score=12 reset_boundaries=1, dead=2, new=2, confidence=review
  - line 631 blank: dead `mir | ti` -> new `ast_node | source_t`
- *POSSIBLE* `src/mir/mir_lowering.rb:863` (heap_owned_result?) -- score=12 reset_boundaries=1, dead=2, new=2, confidence=review
  - line 866 blank: dead `effect | mir` -> new `ast_node | node`
- *POSSIBLE* `src/tools/doctor.rb:824` (emit_atomic_migration!) -- score=12 reset_boundaries=1, dead=2, new=3, confidence=review
  - line 831 blank: dead `profile_dir | src_path` -> new `c | loc | sigil` (continuing `candidates`)
- ...(+2 more)

## False Simplicity (1084)
_looks simple, behaves non-locally: hidden dispatch/mutation/IO/context/metaprogramming/monkeypatch -- *POSSIBLE* (noisy)_

- *POSSIBLE* [hidden_mutation] scatter=507 support=1268 `<<` -- `src/annotator/annotator.rb:240` (push_function_context!) (+1261 more)
- *POSSIBLE* [hidden_mutation] scatter=276 support=378 `full_type!` -- `src/annotator/annotator.rb:262` (stamp_type!) (+375 more)
- *POSSIBLE* [hidden_mutation] scatter=264 support=497 `[]=` -- `src/annotator/annotator.rb:668` (emit_auto_shape_resolved_findings!) (+495 more)
- *POSSIBLE* [hidden_mutation] scatter=241 support=401 `error!` -- `src/annotator/annotator.rb:508` (with_snapshot_transaction_body) (+400 more)
- *POSSIBLE* [hidden_mutation] scatter=137 support=212 `stamp_type!` -- `src/annotator/domains/control_flow.rb:118` (visit_BlockExpr) (+211 more)
- *POSSIBLE* [hidden_mutation] scatter=91 support=98 `from_node!` -- `src/annotator/domains/lifetimes.rb:155` (collection_copy_deep_copy_required) (+97 more)
- *POSSIBLE* [hidden_mutation] scatter=67 support=121 `op-assign` -- `src/annotator/annotator.rb:295` (with_conditional_context) (+120 more)
- *POSSIBLE* [hidden_mutation] scatter=66 support=94 `storage=` -- `src/annotator/domains/control_flow.rb:119` (visit_BlockExpr) (+93 more)
- *POSSIBLE* [hidden_mutation] scatter=48 support=50 `fixable!` -- `src/annotator/domains/lifetimes.rb:699` (verify_tied_assignment!) (+49 more)
- *POSSIBLE* [hidden_io] scatter=44 support=50 `File.exist?` -- `src/ast/diagnostic_examples.rb:77` (load!) (+49 more)
- *POSSIBLE* [dynamic_dispatch] scatter=44 support=45 `blk.call` -- `src/annotator/annotator.rb:297` (with_conditional_context) (+44 more)
- *POSSIBLE* [hidden_mutation] scatter=37 support=89 `match!` -- `src/ast/parser.rb:187` ((top-level)) (+88 more)
- *POSSIBLE* [hidden_io] scatter=37 support=50 `File.join` -- `src/backends/importer.rb:65` (resolve_stdlib_package) (+49 more)
- *POSSIBLE* [dynamic_dispatch] scatter=36 support=41 `yield` -- `src/annotator/helpers/auto_inference.rb:745` (walk_for_shape_decls) (+40 more)
- *POSSIBLE* [hidden_mutation] scatter=36 support=36 `apply_capabilities!` -- `src/ast/type.rb:770` (initialize) (+35 more)
- *POSSIBLE* [dynamic_dispatch] scatter=34 support=38 `instance_variable_get` -- `src/annotator/domains/errors.rb:689` (coerce_empty_collection_fallback!) (+37 more)
- *POSSIBLE* [callback_inversion] scatter=33 support=36 `with_new_scope` -- `src/annotator/domains/control_flow.rb:91` (analyze_control_flow_branch) (+35 more)
- *POSSIBLE* [metaprogramming] scatter=27 support=40 `instance_variable_set` -- `src/annotator/domains/member_access.rb:417` (visit_StructLit) (+39 more)
- *POSSIBLE* [hidden_mutation] scatter=24 support=33 `result_type=` -- `src/mir/fsm_transform/suspend_resolvers.rb:220` (resolve_next) (+32 more)
- *POSSIBLE* [hidden_io] scatter=22 support=267 `puts` -- `src/backends/transpiler.rb:327` ((top-level)) (+266 more)
- *POSSIBLE* [hidden_mutation] scatter=19 support=25 `emit_typo_suggestion!` -- `src/annotator/domains/control_flow.rb:232` (annotate_struct_pattern!) (+24 more)
- *POSSIBLE* [hidden_io] scatter=18 support=25 `File.expand_path` -- `src/annotator/annotator.rb:526` (initialize) (+24 more)
- *POSSIBLE* [hidden_io] scatter=18 support=22 `File.readlines` -- `src/ast/diagnostic_examples.rb:87` (scan_file) (+21 more)
- *POSSIBLE* [context_dependency] scatter=18 support=21 `$stderr` -- `src/annotator/domains/lifetimes.rb:575` (finalize_scope) (+20 more)
- *POSSIBLE* [hidden_mutation] scatter=18 support=21 `mark_moved_guard!` -- `src/mir/cleanup_classifier.rb:546` (walk_takes_params) (+20 more)
- ...(+1059 more)

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
- Detectors: 24 (all shipped, self-tested)
- Convergence: 1934 unit(s) flagged by >=2 independent detectors
- Root-cause clusters: 479 (one fix collapses each)
- Total candidates: 7039
- Method: stdlib AST only, intra-procedural, zero deps, no CFG / no points-to; Flay similarity is an optional external signal consumed read-only (see docs/agents/design.md)
