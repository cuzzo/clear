# Decomplex Report

> Decision-level duplication and neglected-condition analysis.
> Every entry is a ranked **candidate** (Engler's discipline),
> never a verdict -- *POSSIBLE* findings, triaged by a human.
> Sections are ordered by SIGNAL TIER (1 = lowest false
> positive), not by volume. Items within a section are
> frequency-ranked. Triage tier 1, top-of-list, first.

## Table of Contents
- [Project Prioritization](#project-prioritization)
- [Cross-Detector Convergence (2726)](#cross-detector-convergence-2726)
- [Root-Cause Clusters (620)](#root-cause-clusters-620)
- [Decision Pressure (321)](#decision-pressure-321)
- [Redundant Nil Guards (0)](#redundant-nil-guards-0)
- [State Heatmap (861)](#state-heatmap-861)
- [State-Based Branch Density (2294)](#statebased-branch-density-2294)
- [Temporal Ordering Pressure (26)](#temporal-ordering-pressure-26)
- [Missing Abstractions (254)](#missing-abstractions-254)
- [Reification Misses (18)](#reification-misses-18)
- [Semantic Predicate Aliases (5)](#semantic-predicate-aliases-5)
- [Exact Predicate Aliases (21)](#exact-predicate-aliases-21)
- [Inconsistent Rename Clones (72)](#inconsistent-rename-clones-72)
- [Flay Similarity (Type-2/3) (0)](#flay-similarity-type23-0)
- [Neglected Updates (721)](#neglected-updates-721)
- [Derived-State Staleness (151)](#derivedstate-staleness-151)
- [Neglected Conditions (18)](#neglected-conditions-18)
- [Neglected Path Conditions (1572)](#neglected-path-conditions-1572)
- [Oversized Predicates (35)](#oversized-predicates-35)
- [Broken Protocols (662)](#broken-protocols-662)
- [Implicit Control Flow (109)](#implicit-control-flow-109)
- [Weighted Inlined Cognitive Complexity (1055)](#weighted-inlined-cognitive-complexity-1055)
- [False Simplicity (1181)](#false-simplicity-1181)
- [Fat Unions (14)](#fat-unions-14)
- [Run Summary](#run-summary)

## Project Prioritization
_Ordered by signal tier (1 = highest signal / lowest FP), then by volume._

- **[tier 1]** [State-Based Branch Density (2294)](#statebased-branch-density-2294): branch decisions over mutable/object state -- state + control-flow pressure
- **[tier 1]** [State Heatmap (861)](#state-heatmap-861): state fields ranked by write/read/re-derivation scatter -- tangled mutable state should get one owner
- **[tier 1]** [Decision Pressure (321)](#decision-pressure-321): ELIMINABLE guard-pressure per loose contract (nil/is_a?/respond_to?/safe-nav/rescue-nil) -> tighten the contract once / nil-kill: DELETE. essential dispatch + pure c-uses are split out, NEVER summed (Rapps-Weyuker p-use; McCabe)
- **[tier 1]** [Missing Abstractions (254)](#missing-abstractions-254): guard tuple recomputed across >=2 decision units
- **[tier 1]** [Temporal Ordering Pressure (26)](#temporal-ordering-pressure-26): public mutable lifecycle surfaces that create implicit state-machine ordering
- **[tier 1]** [Exact Predicate Aliases (21)](#exact-predicate-aliases-21): identical one-line predicate body under >=2 names
- **[tier 1]** [Reification Misses (18)](#reification-misses-18): an existing predicate reinvented inline -- invariant #16
- **[tier 1]** [Semantic Predicate Aliases (5)](#semantic-predicate-aliases-5): one decision, multiple names (receiver/polarity folded)
- **[tier 2]** [Weighted Inlined Cognitive Complexity (1055)](#weighted-inlined-cognitive-complexity-1055): same-owner helper chain hides cognitive load behind a low-looking orchestration method
- **[tier 2]** [Neglected Updates (721)](#neglected-updates-721): co-written state, one write missing -- *POSSIBLE* redundant-state desync
- **[tier 2]** [Derived-State Staleness (151)](#derivedstate-staleness-151): b = f(a); a later reassigned, b not recomputed -- *POSSIBLE* bug
- **[tier 2]** [Implicit Control Flow (109)](#implicit-control-flow-109): state-dependent internal call order exists -- hidden lifecycle/control-flow pressure
- **[tier 2]** [Inconsistent Rename Clones (72)](#inconsistent-rename-clones-72): pasted block with inconsistent identifier mapping -- *POSSIBLE* missed rename bug
- **[tier 2]** [Neglected Conditions (18)](#neglected-conditions-18): dispatch/conjunction minus one element -- *POSSIBLE* bug
- **[tier 3]** [Neglected Path Conditions (1572)](#neglected-path-conditions-1572): nested-if/&& guard set minus one atom -- *POSSIBLE* bug (noisy)
- **[tier 3]** [False Simplicity (1181)](#false-simplicity-1181): looks simple, behaves non-locally: hidden dispatch/mutation/IO/context/metaprogramming/monkeypatch -- *POSSIBLE* (noisy)
- **[tier 3]** [Broken Protocols (662)](#broken-protocols-662): co-called pair, one site does A without B -- *POSSIBLE* bug (noisy)
- **[tier 3]** [Oversized Predicates (35)](#oversized-predicates-35): predicate with >3 condition atoms -- use an existing helper or extract a named predicate
- **[tier 3]** [Fat Unions (14)](#fat-unions-14): case dispatch over class consts whose arms read mostly variant-invariant members -- product-vs-sum decomposition candidate (extraction -> nil-kill) -- *POSSIBLE*

## Cross-Detector Convergence (2726)
_(file, method) units flagged by >=2 INDEPENDENT detectors -- the strongest triage signal: agreement outranks any single detector's volume. Tier-weighted (1=3, 2=2, 3=1). **Start here.**_

- `gems/nil-kill/lib/nil_kill/source_index.rb:535` (collect_prescan) -- **9 detectors** [score 17, 51 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Fat Unions, Neglected Path Conditions, State-Based Branch Density, Temporal Ordering Pressure, Weighted Inlined Cognitive Complexity
- `gems/nil-kill/lib/nil_kill/source_index.rb:1502` (return_sources_for) -- **8 detectors** [score 17, 47 findings]: Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Oversized Predicates, State-Based Branch Density, Temporal Ordering Pressure, Weighted Inlined Cognitive Complexity
- `src/annotator/domains/variables.rb:279` (visit_BindExpr) -- **8 detectors** [score 16, 71 findings]: Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/mir/mir_checker.rb:404` (check_fn!) -- **7 detectors** [score 17, 125 findings]: Decision Pressure, False Simplicity, Implicit Control Flow, Missing Abstractions, State-Based Branch Density, Temporal Ordering Pressure, Weighted Inlined Cognitive Complexity
- `gems/nil-kill/lib/nil_kill/source_index.rb:2428` (hash_shape_for_block_return) -- **7 detectors** [score 17, 15 findings]: Decision Pressure, False Simplicity, Missing Abstractions, Neglected Updates, State-Based Branch Density, Temporal Ordering Pressure, Weighted Inlined Cognitive Complexity
- `gems/nil-kill/lib/nil_kill/source_index.rb:423` (refill_struct_constructor_types) -- **7 detectors** [score 16, 29 findings]: Decision Pressure, False Simplicity, Missing Abstractions, Neglected Path Conditions, State-Based Branch Density, Temporal Ordering Pressure, Weighted Inlined Cognitive Complexity
- `gems/nil-kill/lib/nil_kill/source_index.rb:2358` (hash_shape_for_value) -- **7 detectors** [score 16, 26 findings]: Decision Pressure, False Simplicity, Missing Abstractions, Neglected Path Conditions, State-Based Branch Density, Temporal Ordering Pressure, Weighted Inlined Cognitive Complexity
- `gems/nil-kill/lib/nil_kill/infer.rb:508` (hash_record_expand_row_from_return_origins) -- **7 detectors** [score 16, 17 findings]: Decision Pressure, False Simplicity, Missing Abstractions, Oversized Predicates, Reification Misses, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/annotator/helpers/function_analysis.rb:399` (resolve_call) -- **7 detectors** [score 15, 123 findings]: Decision Pressure, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/mir/mir_checker.rb:684` (check_linear_stmt!) -- **7 detectors** [score 15, 114 findings]: Decision Pressure, False Simplicity, Fat Unions, Implicit Control Flow, State-Based Branch Density, Temporal Ordering Pressure, Weighted Inlined Cognitive Complexity
- `src/annotator/helpers/pipe_analysis.rb:1590` (analyze_concurrent_op) -- **7 detectors** [score 15, 70 findings]: Decision Pressure, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/tools/doctor.rb:171` (section_heap) -- **7 detectors** [score 15, 50 findings]: Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/ast/parser.rb:2871` (parse_type_annotation) -- **7 detectors** [score 15, 46 findings]: Decision Pressure, False Simplicity, Implicit Control Flow, Neglected Path Conditions, Reification Misses, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/annotator/domains/variables.rb:13` (visit_VarDecl) -- **7 detectors** [score 15, 26 findings]: Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Neglected Updates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/annotator/domains/variables.rb:554` (visit_Assignment) -- **7 detectors** [score 15, 22 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/annotator/domains/execution_boundaries.rb:358` (validate_lock_error_clause!) -- **7 detectors** [score 15, 21 findings]: Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Neglected Updates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/mir/lowering/functions.rb:819` (build_post_outer_fn) -- **7 detectors** [score 15, 13 findings]: Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Neglected Updates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/ast/parser.rb:1382` (parse_function_def) -- **7 detectors** [score 14, 70 findings]: Decision Pressure, False Simplicity, Implicit Control Flow, Neglected Path Conditions, Neglected Updates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/tools/formatter.rb:822` (emit_fn_block) -- **7 detectors** [score 14, 49 findings]: Derived-State Staleness, False Simplicity, Inconsistent Rename Clones, Missing Abstractions, Neglected Path Conditions, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/tools/formatter.rb:728` (emit_match_body) -- **7 detectors** [score 14, 49 findings]: Derived-State Staleness, False Simplicity, Inconsistent Rename Clones, Missing Abstractions, Neglected Path Conditions, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/tools/formatter.rb:2136` (emit_bg_do_wrapped) -- **7 detectors** [score 14, 45 findings]: Derived-State Staleness, False Simplicity, Inconsistent Rename Clones, Missing Abstractions, Neglected Path Conditions, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/annotator/helpers/pipe_analysis.rb:357` (analyze_select_family_op) -- **7 detectors** [score 14, 34 findings]: Decision Pressure, False Simplicity, Fat Unions, Implicit Control Flow, Neglected Updates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/annotator/helpers/pipe_analysis.rb:730` (analyze_distinct_op) -- **7 detectors** [score 14, 28 findings]: Broken Protocols, Decision Pressure, False Simplicity, Implicit Control Flow, Neglected Updates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/annotator/domains/execution_boundaries.rb:40` (visit_WithBlock) -- **7 detectors** [score 13, 73 findings]: Broken Protocols, Decision Pressure, False Simplicity, Implicit Control Flow, Neglected Path Conditions, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/tools/formatter.rb:581` (scan_match_arms) -- **7 detectors** [score 13, 28 findings]: Broken Protocols, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- ...(+2701 more)

### By file
- `gems/nil-kill/lib/nil_kill/source_index.rb` -- 14 detectors across 139 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Fat Unions, Implicit Control Flow, Missing Abstractions, Neglected Conditions, Neglected Path Conditions, Neglected Updates, Oversized Predicates, State-Based Branch Density, Temporal Ordering Pressure, Weighted Inlined Cognitive Complexity
- `gems/nil-kill/lib/nil_kill/infer.rb` -- 14 detectors across 73 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, Exact Predicate Aliases, False Simplicity, Implicit Control Flow, Missing Abstractions, Neglected Conditions, Neglected Path Conditions, Oversized Predicates, Reification Misses, State-Based Branch Density, Temporal Ordering Pressure, Weighted Inlined Cognitive Complexity
- `src/mir/mir_lowering.rb` -- 13 detectors across 105 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, Exact Predicate Aliases, False Simplicity, Fat Unions, Implicit Control Flow, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Semantic Predicate Aliases, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/ast/type.rb` -- 12 detectors across 51 method(s): Broken Protocols, Decision Pressure, Exact Predicate Aliases, False Simplicity, Implicit Control Flow, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Oversized Predicates, State-Based Branch Density, Temporal Ordering Pressure, Weighted Inlined Cognitive Complexity
- `gems/nil-kill/lib/nil_kill/report.rb` -- 11 detectors across 126 method(s): Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Neglected Conditions, Neglected Path Conditions, Oversized Predicates, Reification Misses, State-Based Branch Density, Temporal Ordering Pressure, Weighted Inlined Cognitive Complexity
- `src/tools/formatter.rb` -- 11 detectors across 81 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Inconsistent Rename Clones, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Oversized Predicates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/ast/parser.rb` -- 11 detectors across 81 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Implicit Control Flow, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Reification Misses, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/annotator/helpers/pipe_analysis.rb` -- 11 detectors across 55 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Fat Unions, Implicit Control Flow, Missing Abstractions, Neglected Path Conditions, Neglected Updates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/annotator/domains/execution_boundaries.rb` -- 11 detectors across 19 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Implicit Control Flow, Missing Abstractions, Neglected Conditions, Neglected Path Conditions, Neglected Updates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/mir/fsm_transform/emit.rb` -- 11 detectors across 20 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, Exact Predicate Aliases, False Simplicity, Fat Unions, Implicit Control Flow, Missing Abstractions, Semantic Predicate Aliases, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/mir/mir_checker.rb` -- 10 detectors across 76 method(s): Broken Protocols, Decision Pressure, False Simplicity, Fat Unions, Implicit Control Flow, Missing Abstractions, Neglected Conditions, State-Based Branch Density, Temporal Ordering Pressure, Weighted Inlined Cognitive Complexity
- `src/mir/lowering/expressions.rb` -- 10 detectors across 61 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Oversized Predicates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/mir/hoist.rb` -- 10 detectors across 43 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Conditions, Neglected Path Conditions, Neglected Updates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `gems/nil-kill/lib/nil_kill/apply.rb` -- 10 detectors across 30 method(s): Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Neglected Conditions, Neglected Path Conditions, Oversized Predicates, State-Based Branch Density, Temporal Ordering Pressure, Weighted Inlined Cognitive Complexity
- `src/ast/ast.rb` -- 10 detectors across 31 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, Exact Predicate Aliases, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Semantic Predicate Aliases, State-Based Branch Density

## Root-Cause Clusters (620)
_Findings across >=2 INDEPENDENT detectors that name the SAME entity -- 'N findings are really one invariant'. Convergence says where to look; this says **what one fix collapses the cluster**. Ranked candidate, not a verdict._

- **[name]** `type` -- **7 detectors** [score 14] across 249 unit(s), 278 findings: Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions, Oversized Predicates, Reification Misses, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator/domains/control_flow.rb:911` (loop_value_copyable?) ; `src/annotator/domains/variables.rb:13` (visit_VarDecl) ; `src/annotator/domains/variables.rb:106` (finalize_decl_node!) ; `src/annotator/domains/variables.rb:129` (finalize_decl_node!)
- **[name]** `expr` -- **6 detectors** [score 14] across 63 unit(s), 59 findings: Decision Pressure, Exact Predicate Aliases, False Simplicity, Neglected Path Conditions, Semantic Predicate Aliases, State-Based Branch Density
  - FIX: reify ONE named predicate/decision and call it everywhere
  - `src/annotator/domains/control_flow.rb:151` (visit_IfBind) ; `src/annotator/domains/control_flow.rb:389` (consume_match_subject_if_takes!) ; `src/annotator/domains/execution_boundaries.rb:843` (visit_NextExpr) ; `src/annotator/domains/execution_boundaries.rb:846` (visit_NextExpr)
- **[name]** `line` -- **6 detectors** [score 12] across 42 unit(s), 61 findings: Decision Pressure, Derived-State Staleness, Neglected Path Conditions, Neglected Updates, Oversized Predicates, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/tools/doctor.rb:617` (task_site_metadata) ; `src/tools/doctor.rb:630` (source_line) ; `gems/nil-kill/lib/nil_kill/report.rb:1203` (source_line) ; `gems/nil-kill/lib/nil_kill/report.rb:3553` (hash_shape_site_key)
- **[name]** `value` -- **6 detectors** [score 11] across 160 unit(s), 128 findings: Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions, Oversized Predicates, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator/domains/control_flow.rb:427` (analyze_match_case!) ; `src/annotator/domains/errors.rb:375` (visit_ReturnNode) ; `src/annotator/domains/errors.rb:414` (visit_ReturnNode) ; `src/annotator/domains/errors.rb:417` (visit_ReturnNode)
- **[name]** `stmt` -- **5 detectors** [score 12] across 49 unit(s), 49 findings: Derived-State Staleness, Exact Predicate Aliases, Neglected Path Conditions, Semantic Predicate Aliases, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/mir/fsm_transform/segments.rb:226` (split_while_loop_next) ; `src/mir/fsm_transform/segments.rb:232` (split_while_loop_next) ; `src/mir/fsm_transform/segments.rb:240` (split_while_loop_next) ; `src/mir/fsm_transform/segments.rb:256` (split_while_loop_next)
- **[name]** `file` -- **5 detectors** [score 11] across 55 unit(s), 27 findings: Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Updates, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `gems/boobytrap/lib/boobytrap/report.rb:266` (build_state_branch_hotspots) ; `gems/decomplex/lib/decomplex/convergence.rb:33` (rollup) ; `gems/decomplex/lib/decomplex/convergence.rb:45` (rollup) ; `gems/decomplex/lib/decomplex/inconsistent_rename_clone.rb:99` (findings_for)
- **[name]** `sync` -- **5 detectors** [score 11] across 26 unit(s), 14 findings: Decision Pressure, False Simplicity, Oversized Predicates, Reification Misses, State-Based Branch Density
  - FIX: reify ONE named predicate/decision and call it everywhere
  - `src/annotator/domains/errors.rb:530` (same_return_capabilities?) ; `src/annotator/domains/lifetimes.rb:1015` (bg_capture_independent?) ; `src/annotator/helpers/generic_analysis.rb:459` (generic_type_has_capabilities?) ; `src/annotator/helpers/pipe_analysis.rb:1247` (auto_detect_sharded_access)
- **[name]** `struct` -- **5 detectors** [score 11] across 20 unit(s), 20 findings: Exact Predicate Aliases, Neglected Path Conditions, Oversized Predicates, Semantic Predicate Aliases, State-Based Branch Density
  - FIX: reify ONE named predicate/decision and call it everywhere
  - `src/mir/lowering/functions.rb:290` (lower_function_def) ; `src/mir/lowering/functions.rb:301` (lower_function_def) ; `src/mir/lowering/functions.rb:344` (lower_function_def) ; `src/mir/lowering/functions.rb:360` (lower_function_def)
- **[name]** `union` -- **5 detectors** [score 11] across 20 unit(s), 23 findings: Broken Protocols, Exact Predicate Aliases, Neglected Path Conditions, Semantic Predicate Aliases, State-Based Branch Density
  - FIX: pair the protocol (RAII / ensure); the unpaired site is the deviant
  - `src/annotator/domains/control_flow.rb:644` (emit_missing_match_variants!) ; `src/annotator/domains/control_flow.rb:647` (emit_missing_match_variants!) ; `src/annotator/domains/control_flow.rb:649` (emit_missing_match_variants!) ; `src/annotator/domains/control_flow.rb:651` (emit_missing_match_variants!)
- **[name]** `name` -- **5 detectors** [score 10] across 192 unit(s), 189 findings: Decision Pressure, Derived-State Staleness, Neglected Path Conditions, Oversized Predicates, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator/domains/lifetimes.rb:419` (handle_assignment_identifier_move!) ; `src/annotator/domains/lifetimes.rb:448` (handle_assign_borrow) ; `src/annotator/domains/variables.rb:554` (visit_Assignment) ; `src/annotator/domains/variables.rb:595` (visit_Assignment)
- **[name]** `current` -- **5 detectors** [score 10] across 37 unit(s), 37 findings: Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/ast/parser.rb:2499` (peek_generic_angle_params?) ; `src/ast/parser.rb:2495` (peek_generic_angle_params?) ; `src/ast/parser.rb:2500` (peek_generic_angle_params?) ; `src/ast/parser.rb:2502` (peek_generic_angle_params?)
- **[name]** `kind` -- **5 detectors** [score 10] across 36 unit(s), 36 findings: Derived-State Staleness, False Simplicity, Oversized Predicates, Reification Misses, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator/domains/lifetimes.rb:1225` (reject_borrowed_value!) ; `src/annotator/domains/lifetimes.rb:1230` (reject_borrowed_value!) ; `src/annotator/domains/lifetimes.rb:1231` (reject_borrowed_value!) ; `src/annotator/domains/lifetimes.rb:1233` (reject_borrowed_value!)
- **[name]** `state` -- **5 detectors** [score 10] across 24 unit(s), 31 findings: False Simplicity, Neglected Path Conditions, Neglected Updates, Reification Misses, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `gems/espalier/lib/espalier/formatter.rb:17` (to_markdown) ; `gems/espalier/lib/espalier/formatter.rb:22` (to_markdown) ; `gems/espalier/lib/espalier/formatter.rb:39` (to_markdown) ; `gems/espalier/lib/espalier/formatter.rb:40` (to_markdown)
- **[name]** `emit` -- **5 detectors** [score 10] across 20 unit(s), 17 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Updates, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/mir/fsm_transform/suspend_resolvers.rb:65` (resolve_io) ; `src/mir/fsm_transform/suspend_resolvers.rb:66` (resolve_io) ; `src/mir/fsm_transform/suspend_resolvers.rb:67` (resolve_io) ; `src/mir/fsm_transform/suspend_resolvers.rb:68` (resolve_io)
- **[name]** `methods` -- **5 detectors** [score 10] across 12 unit(s), 10 findings: Decision Pressure, False Simplicity, Neglected Updates, Oversized Predicates, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator/phases/declaration_index.rb:76` (union_methods?) ; `src/annotator/phases/expression_domains.rb:235` (resolve_extern_method_call!) ; `src/mir/mir_checker.rb:714` (check_linear_stmt!) ; `src/tools/method_rewriter.rb:34` (rewrite)
- **[name]** `size` -- **5 detectors** [score 9] across 91 unit(s), 94 findings: Decision Pressure, False Simplicity, Neglected Path Conditions, Oversized Predicates, State-Based Branch Density
  - FIX: tighten the contract once; the scattered defensive guards collapse (cross-proc -> nil-kill)
  - `src/annotator/helpers/pipe_analysis.rb:446` (analyze_batch_window_op) ; `src/annotator/helpers/pipe_analysis.rb:1493` (analyze_concurrent_op) ; `src/annotator/helpers/pipe_analysis.rb:1495` (analyze_concurrent_op) ; `gems/nil-kill/lib/nil_kill/report.rb:2047` (classify_param_untyped_cause)
- **[name]** `collection` -- **5 detectors** [score 9] across 15 unit(s), 18 findings: Decision Pressure, False Simplicity, Neglected Path Conditions, Oversized Predicates, State-Based Branch Density
  - FIX: tighten the contract once; the scattered defensive guards collapse (cross-proc -> nil-kill)
  - `src/mir/lowering/control_flow.rb:451` (for_each_loop_stmt) ; `src/mir/lowering/control_flow.rb:452` (for_each_loop_stmt) ; `src/annotator/helpers/pipe_analysis.rb:499` (analyze_join_op) ; `src/annotator/helpers/pipe_analysis.rb:509` (analyze_join_op)
- **[name]** `AST` -- **5 detectors** [score 8] across 123 unit(s), 203 findings: False Simplicity, Neglected Conditions, Neglected Path Conditions, Oversized Predicates, State-Based Branch Density
  - FIX: converging structural debt -- resolve once at the named entity
  - `src/mir/lowering/variables.rb:559` (lower_var_decl_init) ; `src/mir/lowering/variables.rb:564` (lower_var_decl_init) ; `src/mir/lowering/variables.rb:565` (lower_var_decl_init) ; `src/mir/lowering/variables.rb:570` (lower_var_decl_init)
- **[name]** `mir` -- **4 detectors** [score 12] across 23 unit(s), 15 findings: Decision Pressure, Exact Predicate Aliases, Semantic Predicate Aliases, State-Based Branch Density
  - FIX: reify ONE named predicate/decision and call it everywhere
  - `src/mir/mir_lowering.rb:1165` (append_lowered_statement_packet!) ; `src/mir/hoist.rb:647` (mir_alloc_mark_type_info) ; `src/mir/hoist.rb:661` (mir_alloc_mark_type_info) ; `src/mir/hoist.rb:663` (mir_alloc_mark_type_info)
- **[name]** `sites` -- **4 detectors** [score 10] across 27 unit(s), 41 findings: Decision Pressure, Derived-State Staleness, Neglected Updates, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `gems/decomplex/lib/decomplex/convergence.rb:73` (locations) ; `gems/decomplex/lib/decomplex/convergence.rb:76` (locations) ; `src/tools/doctor.rb:1220` (section_freeze) ; `src/tools/doctor.rb:1250` (section_freeze)
- ...(+600 more)

## Decision Pressure (321)
_ELIMINABLE guard-pressure per loose contract (nil/is_a?/respond_to?/safe-nav/rescue-nil) -> tighten the contract once / nil-kill: DELETE. essential dispatch + pure c-uses are split out, NEVER summed (Rapps-Weyuker p-use; McCabe)_

- `.value` -- ELIMINABLE guard-pressure **131** across 73 method(s) -> tighten contract / nil-kill: DELETE  (+18 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/domains/control_flow.rb:427` (analyze_match_case!) ; `src/annotator/domains/errors.rb:375` (visit_ReturnNode) ; `src/annotator/domains/errors.rb:414` (visit_ReturnNode) ; `src/annotator/domains/errors.rb:417` (visit_ReturnNode)
- `.symbol` -- ELIMINABLE guard-pressure **83** across 66 method(s) -> tighten contract / nil-kill: DELETE  (+12 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/domains/errors.rb:414` (visit_ReturnNode) ; `src/annotator/domains/errors.rb:417` (visit_ReturnNode) ; `src/annotator/domains/errors.rb:419` (visit_ReturnNode) ; `src/annotator/domains/execution_boundaries.rb:426` (reject_bare_atomic_ptr_mutation!)
- `.arguments` -- ELIMINABLE guard-pressure **63** across 44 method(s) -> tighten contract / nil-kill: DELETE
  - `gems/espalier/lib/espalier/ast_extractor.rb:190` (visit_instance_variable_write_node) ; `gems/espalier/lib/espalier/ast_extractor.rb:287` (handle_visibility_directive) ; `gems/nil-kill/lib/nil_kill/apply.rb:266` (apply_narrow_tlet_cst_rewrite) ; `gems/nil-kill/lib/nil_kill/apply.rb:266` (apply_narrow_tlet_cst_rewrite)
- `.target` -- ELIMINABLE guard-pressure **62** across 36 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/domains/errors.rb:417` (visit_ReturnNode) ; `src/annotator/domains/errors.rb:419` (visit_ReturnNode) ; `src/annotator/domains/execution_boundaries.rb:421` (reject_bare_atomic_ptr_mutation!) ; `src/annotator/domains/execution_boundaries.rb:421` (reject_bare_atomic_ptr_mutation!)
- `.name` -- ELIMINABLE guard-pressure **45** across 34 method(s) -> tighten contract / nil-kill: DELETE  (+4 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/domains/lifetimes.rb:419` (handle_assignment_identifier_move!) ; `src/annotator/domains/lifetimes.rb:448` (handle_assign_borrow) ; `src/annotator/domains/variables.rb:554` (visit_Assignment) ; `src/annotator/domains/variables.rb:595` (visit_Assignment)
- `.current_fn_ctx` -- ELIMINABLE guard-pressure **42** across 39 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/annotator.rb:357` (current_loop_depth) ; `src/annotator/annotator.rb:362` (current_conditional_depth) ; `src/annotator/domains/errors.rb:309` (visit_Raise) ; `src/annotator/domains/errors.rb:732` (visit_OrExit)
- `.left` -- ELIMINABLE guard-pressure **33** across 16 method(s) -> tighten contract / nil-kill: DELETE  (+8 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/domains/errors.rb:582` (visit_OrRescue) ; `src/annotator/helpers/pipe_analysis.rb:118` (stamp_observable_terminal!) ; `src/annotator/helpers/pipe_analysis.rb:124` (stamp_observable_terminal!) ; `src/annotator/helpers/pipe_analysis.rb:288` (analyze_collect_op)
- `.right` -- ELIMINABLE guard-pressure **33** across 13 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/domains/errors.rb:567` (visit_OrRescue) ; `src/annotator/domains/errors.rb:568` (visit_OrRescue) ; `src/annotator/domains/errors.rb:569` (visit_OrRescue) ; `src/annotator/domains/errors.rb:570` (visit_OrRescue)
- `.expr` -- ELIMINABLE guard-pressure **29** across 20 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/domains/control_flow.rb:151` (visit_IfBind) ; `src/annotator/domains/control_flow.rb:389` (consume_match_subject_if_takes!) ; `src/annotator/domains/execution_boundaries.rb:843` (visit_NextExpr) ; `src/annotator/domains/execution_boundaries.rb:846` (visit_NextExpr)
- `.receiver` -- ELIMINABLE guard-pressure **28** across 25 method(s) -> tighten contract / nil-kill: DELETE
  - `gems/espalier/lib/espalier/ast_extractor.rb:189` (visit_instance_variable_write_node) ; `gems/espalier/lib/espalier/ast_extractor.rb:282` (visibility_directive?) ; `gems/nil-kill/lib/nil_kill/apply.rb:265` (apply_narrow_tlet_cst_rewrite) ; `gems/nil-kill/lib/nil_kill/loop.rb:573` (apply_useless_tcast_feedback)
- `.type` -- ELIMINABLE guard-pressure **25** across 22 method(s) -> tighten contract / nil-kill: DELETE  (+40 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/domains/control_flow.rb:911` (loop_value_copyable?) ; `src/annotator/domains/variables.rb:13` (visit_VarDecl) ; `src/annotator/domains/variables.rb:106` (finalize_decl_node!) ; `src/annotator/domains/variables.rb:129` (finalize_decl_node!)
- `.token` -- ELIMINABLE guard-pressure **23** across 20 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/helpers/capabilities.rb:1301` (record_capability_binding) ; `src/annotator/helpers/capabilities.rb:1302` (record_capability_binding) ; `src/ast/ast.rb:476` (borrowed_ownership_view?) ; `src/mir/control_flow.rb:1083` (collect_ownership_transfers)
- `.first` -- ELIMINABLE guard-pressure **22** across 21 method(s) -> tighten contract / nil-kill: DELETE  (+14 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/domains/lifetimes.rb:1071` (get_lifetime_path) ; `src/annotator/domains/member_access.rb:530` (infer_element_type) ; `src/annotator/domains/member_access.rb:541` (infer_optional_element_type) ; `src/annotator/helpers/lock_helper.rb:464` (report_lock_cycle!)
- `.body` -- ELIMINABLE guard-pressure **20** across 16 method(s) -> tighten contract / nil-kill: DELETE  (+5 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/backends/pipeline_rewriter.rb:65` (rewrite_children!) ; `src/backends/string_concat_rewriter.rb:55` (rewrite_children!) ; `src/mir/fsm_transform/recursive_splitter.rb:523` (emit_with_fragment) ; `src/mir/hoist.rb:700` (block_expr_result_type)
- `.element_type` -- ELIMINABLE guard-pressure **18** across 15 method(s) -> tighten contract / nil-kill: DELETE  (+6 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/domains/member_access.rb:531` (infer_element_type) ; `src/annotator/domains/member_access.rb:542` (infer_optional_element_type) ; `src/annotator/helpers/function_analysis.rb:819` (any_element_collection_param?) ; `src/annotator/helpers/generic_analysis.rb:183` (validate_shape_annotation_capabilities!)
- `.object` -- ELIMINABLE guard-pressure **18** across 14 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/domains/control_flow.rb:841` (visit_WhileBindLoop) ; `src/annotator/helpers/auto_inference.rb:792` (record_method_call) ; `src/annotator/helpers/function_analysis.rb:506` (receiver_container_alloc) ; `src/annotator/helpers/method_analysis.rb:156` (narrow_receiver_collection!)
- `.type_params` -- ELIMINABLE guard-pressure **17** across 15 method(s) -> tighten contract / nil-kill: DELETE  (+1 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/domains/control_flow.rb:317` (literal_type_substitution!) ; `src/annotator/domains/control_flow.rb:324` (literal_type_substitution!) ; `src/annotator/domains/lifetimes.rb:1177` (move_if_not_copyable!) ; `src/annotator/domains/lifetimes.rb:1203` (move_if_takes_ownership!)
- `.sync` -- ELIMINABLE guard-pressure **15** across 14 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/domains/errors.rb:530` (same_return_capabilities?) ; `src/annotator/domains/lifetimes.rb:1015` (bg_capture_independent?) ; `src/annotator/helpers/generic_analysis.rb:459` (generic_type_has_capabilities?) ; `src/annotator/helpers/pipe_analysis.rb:1247` (auto_detect_sharded_access)
- `[name]` -- ELIMINABLE guard-pressure **13** across 13 method(s) -> tighten contract / nil-kill: DELETE  (+3 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/domains/control_flow.rb:901` (captured_move_consumed_by_loop?) ; `src/annotator/domains/lifetimes.rb:529` (finalize_scope) ; `src/annotator/function_registry.rb:78` (fnptr_call?) ; `src/annotator/function_registry.rb:83` (raises_directly?)
- `.current_function_context` -- ELIMINABLE guard-pressure **13** across 13 method(s) -> tighten contract / nil-kill: DELETE
  - `src/mir/mir_lowering.rb:325` (current_function_has_rt?) ; `src/mir/mir_lowering.rb:330` (current_function_has_catch?) ; `src/mir/mir_lowering.rb:335` (current_function_heap_carry_return?) ; `src/mir/mir_lowering.rb:340` (current_function_tail_call?)
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
- ...(+296 more)

## Redundant Nil Guards (0)
_nil checks / safe-nav dominated by an earlier non-nil proof -- delete repeated control flow or tighten the type_

None.

## State Heatmap (861)
_state fields ranked by write/read/re-derivation scatter -- tangled mutable state should get one owner_

- `a` -- messiness **35.0** (writes=1, reads=0, re-derived=6, scatter=5, receiver patterns=1)
  - writers: `gems/nil-kill/spec/fixtures/zero_gap_corpus/struct_collection_lib.rb:19` (build)
- `actions` -- messiness **3000.0** (writes=1, reads=99, re-derived=0, scatter=30, receiver patterns=6)
  - writers: `gems/nil-kill/lib/nil_kill/store.rb:20` (initialize)
  - readers: `src/annotator/phases/import_resolution.rb:170` (clone_resource_close_plan) ; `src/ast/type.rb:2096` (resolve_resource_close) ; `src/mir/mir_emitter.rb:2719` (render_resource_close_plan) ; `gems/nil-kill/lib/nil_kill/focus_hash_record.rb:55` (run)
- `active_stubs` -- messiness **30.0** (writes=3, reads=7, re-derived=0, scatter=3, receiver patterns=1)
  - writers: `src/mir/test_lowering.rb:55` (lower_when_block) ; `src/mir/test_lowering.rb:103` (lower_when_block) ; `src/mir/test_lowering.rb:397` (lower_stub_decl)
  - readers: `src/mir/test_lowering.rb:54` (lower_when_block) ; `src/mir/test_lowering.rb:327` (stub_intercept_for) ; `src/mir/test_lowering.rb:397` (lower_stub_decl) ; `src/mir/test_lowering.rb:402` (lower_stub_decl)
- `added_lines` -- messiness **1.0** (writes=1, reads=0, re-derived=0, scatter=1, receiver patterns=1)
  - writers: `gems/nil-kill/lib/nil_kill/static_diff_audit.rb:23` (initialize)
- `after_all` -- messiness **25.0** (writes=2, reads=3, re-derived=0, scatter=5, receiver patterns=3)
  - writers: `src/ast/parser.rb:4029` (parse_test_block) ; `src/ast/parser.rb:4122` (parse_when_block)
  - readers: `src/annotator/helpers/test_annotation.rb:106` (visit_test_hook_bodies) ; `src/mir/test_lowering.rb:41` (lower_test_block) ; `src/mir/test_lowering.rb:101` (lower_when_block)
- `after_each` -- messiness **42.0** (writes=2, reads=5, re-derived=0, scatter=6, receiver patterns=6)
  - writers: `src/ast/parser.rb:4027` (parse_test_block) ; `src/ast/parser.rb:4120` (parse_when_block)
  - readers: `src/annotator/helpers/test_annotation.rb:104` (visit_test_hook_bodies) ; `src/mir/test_lowering.rb:69` (lower_when_block) ; `src/mir/test_lowering.rb:149` (lower_test_that) ; `src/mir/test_lowering.rb:150` (lower_test_that)
- `alias_overrides_for` -- messiness **9.0** (writes=1, reads=2, re-derived=0, scatter=3, receiver patterns=1)
  - writers: `src/mir/fsm_transform/recursive_splitter.rb:103` (initialize)
  - readers: `src/mir/fsm_transform/recursive_splitter.rb:125` (stamp_overrides) ; `src/mir/fsm_transform/recursive_splitter.rb:184` (finalize)
- `all` -- messiness **247.0** (writes=3, reads=16, re-derived=0, scatter=13, receiver patterns=6)
  - writers: `src/ast/diagnostic_examples.rb:64` (all) ; `src/ast/diagnostic_examples.rb:65` (all) ; `gems/nil-kill/lib/nil_kill/apply.rb:8` (initialize)
  - readers: `src/annotator/domains/execution_boundaries.rb:27` (visit_WithBlock) ; `src/annotator/domains/execution_boundaries.rb:180` (validate_with_match_source_shape!) ; `src/annotator/domains/execution_boundaries.rb:185` (validate_with_match_source_shape!) ; `src/annotator/domains/execution_boundaries.rb:187` (validate_with_match_source_shape!)
- `all_methods` -- messiness **2.0** (writes=1, reads=1, re-derived=0, scatter=1, receiver patterns=1)
  - writers: `gems/espalier/lib/espalier/reporter.rb:257` (all_methods)
  - readers: `gems/espalier/lib/espalier/reporter.rb:257` (all_methods)
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
- `arg_mirs` -- messiness **10.0** (writes=1, reads=4, re-derived=0, scatter=2, receiver patterns=1)
  - writers: `src/mir/fsm_ops.rb:287` (initialize)
  - readers: `src/mir/fsm_ops.rb:350` (lower_expr) ; `src/mir/fsm_ops.rb:350` (lower_expr) ; `src/mir/fsm_ops.rb:351` (lower_expr) ; `src/mir/fsm_ops.rb:353` (lower_expr)
- `arg_spec` -- messiness **63.0** (writes=3, reads=6, re-derived=0, scatter=7, receiver patterns=7)
  - writers: `src/annotator/helpers/function_signature.rb:255` (initialize) ; `src/annotator/helpers/function_signature.rb:417` (dup) ; `src/annotator/helpers/intrinsic_registry.rb:139` (convert_entry)
  - readers: `src/annotator/domains/lifetimes.rb:469` (resolve_borrow_source) ; `src/annotator/helpers/function_analysis.rb:464` (normalize_intrinsic_signature) ; `src/annotator/helpers/function_analysis.rb:466` (normalize_intrinsic_signature) ; `src/annotator/helpers/function_signature.rb:417` (dup)
- `arg_validator` -- messiness **24.0** (writes=3, reads=3, re-derived=0, scatter=4, receiver patterns=4)
  - writers: `src/annotator/helpers/function_signature.rb:254` (initialize) ; `src/annotator/helpers/function_signature.rb:416` (dup) ; `src/annotator/helpers/intrinsic_registry.rb:138` (convert_entry)
  - readers: `src/annotator/helpers/function_signature.rb:416` (dup) ; `src/annotator/helpers/method_analysis.rb:84` (resolve_typed_method) ; `src/annotator/helpers/method_analysis.rb:85` (resolve_typed_method)
- `argv` -- messiness **238.0** (writes=2, reads=32, re-derived=0, scatter=7, receiver patterns=1)
  - writers: `gems/nil-kill/lib/nil_kill/cli.rb:7` (initialize) ; `gems/nil-kill/lib/nil_kill/report.rb:7` (initialize)
  - readers: `gems/nil-kill/lib/nil_kill/cli.rb:15` (run) ; `gems/nil-kill/lib/nil_kill/cli.rb:18` (run) ; `gems/nil-kill/lib/nil_kill/cli.rb:19` (run) ; `gems/nil-kill/lib/nil_kill/cli.rb:20` (run)
- ...(+836 more)

## State-Based Branch Density (2294)
_branch decisions over mutable/object state -- state + control-flow pressure_

- `src/ast/ast.rb:196` (initialize) -- **21** state-based branch decision(s), refs=`rt.nil? | self[:bindings].nil? | self[:body].nil? | self[:borrowed].nil? | self[:capabilities].nil? | self[:cases].nil? | self[:extra_values].nil? | self[:fields].nil?` score=378
  - example predicate: `self[:body].nil?`
- `gems/boobytrap/lib/boobytrap/report.rb:98` (to_markdown) -- **16** state-based branch decision(s), refs=`@blast_radius | @blast_radius.empty? | @blast_radius.first | @blast_radius.size | @have_cov | @method_gaps | @method_gaps.empty? | @only` score=320
  - example predicate: `@ranked.empty?`
- `gems/nil-kill/lib/nil_kill/loop.rb:59` (run) -- **15** state-based branch decision(s), refs=`@max_iters | @skipped | @try_hash_records | @try_levenshtein | @try_narrow_generic | @try_narrow_tlet | @try_return_backflow | @try_signature_backflow` score=225
  - example predicate: `@verify_cmd.empty? && !@verify_spec_subset`
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
- `gems/nil-kill/lib/nil_kill/source_index.rb:2608` (expression_type_uncached) -- **11** state-based branch decision(s), refs=`@current_array_element_shapes | @current_collection_builders | @current_hash_shapes | @current_local_types | node.class.name | node.else_clause | node.name | node.receiver` score=154
  - example predicate: `node.is_a?(Prism::CallNode) && node.name == :let && node.receiver&.slice == "T"`
- `src/annotator/domains/lifetimes.rb:529` (finalize_scope) -- **15** state-based branch decision(s), refs=`branch.nil? | info.mutable | info.mutated | info.ownership_kind | info.read | info.reg | info.reg.var_mutated | info.reg.var_used` score=150
  - example predicate: `ownership_graph.live?(name) || (is_takes && ownership_graph[name]&.moved?)`
- `src/annotator/helpers/function_analysis.rb:191` (visit_FunctionDef) -- **14** state-based branch decision(s), refs=`candidate_snap_types.size | catch_body_scan.references_snapshot | fn_type_params.any? | node.name | node.reentrance_kind | node.reentrant | node.return_type | node.tail_call` score=140
  - example predicate: `has_mutable_param && !node.name.end_with?("!")`
- `gems/nil-kill/lib/nil_kill/report.rb:2091` (classify_return_untyped_cause) -- **12** state-based branch decision(s), refs=`callees.empty? | method["method"].to_sym | non_nil.any? | non_nil.empty? | non_nil.size | non_nil.sort | per.all? | per.any?` score=132
  - example predicate: `unused.include?(method["method"].to_sym)`
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
- ...(+2269 more)

## Temporal Ordering Pressure (26)
_public mutable lifecycle surfaces that create implicit state-machine ordering_

- `SourceIndex` (`gems/nil-kill/lib/nil_kill/source_index.rb:131` (SourceIndex)) -- implicit lifecycle score **29940** (public=188, state methods=71, writers=7, fields=53, shared=52, flows=71!, states=2^53)
  - shared fields: `@class_like_constants | @collection_index_lookups | @current_array_element_shapes | @current_class_name | @current_collection_builders | @current_hash_shape_sources | @current_hash_shapes | @current_local_types`
  - surface: `gems/nil-kill/lib/nil_kill/source_index.rb:131` (initialize) ; `gems/nil-kill/lib/nil_kill/source_index.rb:199` (summary) ; `gems/nil-kill/lib/nil_kill/source_index.rb:210` (collect_type_normalizers!) ; `gems/nil-kill/lib/nil_kill/source_index.rb:272` (walk) ; `gems/nil-kill/lib/nil_kill/source_index.rb:342` (walk_call_children) ; `gems/nil-kill/lib/nil_kill/source_index.rb:360` (recompute_return_origins_with_inferred_shapes)
- `Report` (`gems/nil-kill/lib/nil_kill/report.rb:6` (Report)) -- implicit lifecycle score **5632** (public=253, state methods=16, writers=12, fields=19, shared=8, flows=16!, states=2^19)
  - shared fields: `@evidence | @evidence_override | @full | @hygiene_only | @program_noreturn_names | @program_return_index | @report_path | @with_links`
  - surface: `gems/nil-kill/lib/nil_kill/report.rb:6` (initialize) ; `gems/nil-kill/lib/nil_kill/report.rb:15` (run) ; `gems/nil-kill/lib/nil_kill/report.rb:106` (format_report_line) ; `gems/nil-kill/lib/nil_kill/report.rb:136` (link_target_for_path) ; `gems/nil-kill/lib/nil_kill/report.rb:443` (method_at) ; `gems/nil-kill/lib/nil_kill/report.rb:1613` (collect_coverage_index)
- `FunctionSignature` (`src/annotator/helpers/function_signature.rb:36` (FunctionSignature)) -- implicit lifecycle score **5401** (public=43, state methods=9, writers=5, fields=29, shared=29, flows=9!, states=2^29)
  - shared fields: `@alloc_fault | @arg_spec | @arg_validator | @arity | @can_fail | @effects | @emit | @error_fallible`
  - surface: `src/annotator/helpers/function_signature.rb:36` (return_lifetime=) ; `src/annotator/helpers/function_signature.rb:52` (return_type=) ; `src/annotator/helpers/function_signature.rb:99` (emit=) ; `src/annotator/helpers/function_signature.rb:104` (intrinsic_contract) ; `src/annotator/helpers/function_signature.rb:115` (requires=) ; `src/annotator/helpers/function_signature.rb:223` (initialize)
- `Loop` (`gems/nil-kill/lib/nil_kill/loop.rb:9` (Loop)) -- implicit lifecycle score **4996** (public=43, state methods=15, writers=3, fields=21, shared=20, flows=15!, states=2^21)
  - shared fields: `@hash_record_limit | @levenshtein_distance | @levenshtein_limit | @max_iters | @narrow_generic_limit | @narrow_tlet_limit | @permanent_skip | @return_backflow_limit`
  - surface: `gems/nil-kill/lib/nil_kill/loop.rb:9` (initialize) ; `gems/nil-kill/lib/nil_kill/loop.rb:50` (permanently_skipped?) ; `gems/nil-kill/lib/nil_kill/loop.rb:58` (run) ; `gems/nil-kill/lib/nil_kill/loop.rb:137` (z3_preflight_skip?) ; `gems/nil-kill/lib/nil_kill/loop.rb:152` (struct_rbi_review_actions) ; `gems/nil-kill/lib/nil_kill/loop.rb:164` (hash_record_review_actions)
- `Profile` (`src/tools/pprof.rb:65` (Profile)) -- implicit lifecycle score **4996** (public=12, state methods=10, writers=6, fields=15, shared=15, flows=10!, states=2^15)
  - shared fields: `@default_sample_type_idx | @duration_nanos | @functions | @locations | @mappings | @next_func_id | @next_loc_id | @next_mapping_id`
  - surface: `src/tools/pprof.rb:65` (initialize) ; `src/tools/pprof.rb:86` (intern) ; `src/tools/pprof.rb:94` (add_sample_type) ; `src/tools/pprof.rb:100` (set_period_type) ; `src/tools/pprof.rb:107` (default_sample_type=) ; `src/tools/pprof.rb:119` (add_mapping)
- `Infer` (`gems/nil-kill/lib/nil_kill/infer.rb:6` (Infer)) -- implicit lifecycle score **4888** (public=127, state methods=44, writers=9, fields=13, shared=2, flows=44!, states=2^13)
  - shared fields: `@run_sorbet | @store`
  - surface: `gems/nil-kill/lib/nil_kill/infer.rb:6` (initialize) ; `gems/nil-kill/lib/nil_kill/infer.rb:11` (run) ; `gems/nil-kill/lib/nil_kill/infer.rb:23` (load_runtime) ; `gems/nil-kill/lib/nil_kill/infer.rb:104` (index_sources) ; `gems/nil-kill/lib/nil_kill/infer.rb:160` (load_sorbet) ; `gems/nil-kill/lib/nil_kill/infer.rb:170` (build_actions)
- `SymbolEntry` (`src/ast/symbol_entry.rb:147` (SymbolEntry)) -- implicit lifecycle score **4288** (public=52, state methods=16, writers=3, fields=13, shared=4, flows=16!, states=2^13)
  - shared fields: `@flow | @lifecycle | @lifetime | @reg`
  - surface: `src/ast/symbol_entry.rb:147` (lifetime=) ; `src/ast/symbol_entry.rb:367` (invalidate!) ; `src/ast/symbol_entry.rb:373` (mark_read!) ; `src/ast/symbol_entry.rb:379` (mark_mutated!) ; `src/ast/symbol_entry.rb:385` (mark_mutated_via_reference!) ; `src/ast/symbol_entry.rb:391` (mark_poly_borrow_target!)
- `Report` (`gems/decomplex/lib/decomplex/report.rb:11` (Report)) -- implicit lifecycle score **4120** (public=7, state methods=4, writers=2, fields=26, shared=3, flows=4!, states=2^26)
  - shared fields: `@convergence | @files | @root`
  - surface: `gems/decomplex/lib/decomplex/report.rb:11` (initialize) ; `gems/decomplex/lib/decomplex/report.rb:16` (run) ; `gems/decomplex/lib/decomplex/report.rb:148` (root_clusters) ; `gems/decomplex/lib/decomplex/report.rb:167` (to_markdown)
- `Type` (`src/ast/type.rb:745` (Type)) -- implicit lifecycle score **1682** (public=242, state methods=26, writers=9, fields=9, shared=5, flows=26!, states=2^9)
  - shared fields: `@capabilities | @generic_payload_type_arg | @is_resource | @placement | @zig_type_cache`
  - surface: `src/ast/type.rb:745` (initialize) ; `src/ast/type.rb:843` (ownership) ; `src/ast/type.rb:854` (sync) ; `src/ast/type.rb:865` (layout) ; `src/ast/type.rb:876` (lock_rank) ; `src/ast/type.rb:887` (collection)
- `SemanticAnnotator` (`src/annotator/annotator.rb:159` (SemanticAnnotator)) -- implicit lifecycle score **792** (public=44, state methods=35, writers=2, fields=9, shared=4, flows=35!, states=2^9)
  - shared fields: `@function_registry | @program | @receiver_state | @semantic_index`
  - surface: `src/annotator/annotator.rb:159` (semantic_function_registry) ; `src/annotator/annotator.rb:169` (phase_receiver_state) ; `src/annotator/annotator.rb:175` (ownership_graph) ; `src/annotator/annotator.rb:191` (scope_stack) ; `src/annotator/annotator.rb:196` (semantic_root_scope) ; `src/annotator/annotator.rb:201` (semantic_program)
- `StructuralVisitor` (`gems/espalier/lib/espalier/ast_extractor.rb:29` (StructuralVisitor)) -- implicit lifecycle score **604** (public=17, state methods=17, writers=4, fields=7, shared=7, flows=17!, states=2^7)
  - shared fields: `@context_stack | @current_class | @current_method | @current_visibility | @file_path | @modules | @namespace_stack`
  - surface: `gems/espalier/lib/espalier/ast_extractor.rb:29` (initialize) ; `gems/espalier/lib/espalier/ast_extractor.rb:40` (visit_class_node) ; `gems/espalier/lib/espalier/ast_extractor.rb:65` (visit_module_node) ; `gems/espalier/lib/espalier/ast_extractor.rb:91` (visit_if_node) ; `gems/espalier/lib/espalier/ast_extractor.rb:106` (visit_block_node) ; `gems/espalier/lib/espalier/ast_extractor.rb:112` (visit_unless_node)
- `OwnershipGraph` (`src/semantic/ownership_graph.rb:131` (OwnershipGraph)) -- implicit lifecycle score **528** (public=23, state methods=16, writers=5, fields=7, shared=5, flows=16!, states=2^7)
  - shared fields: `@children | @completed_nodes | @edges | @nodes | @scope_depth`
  - surface: `src/semantic/ownership_graph.rb:131` (initialize) ; `src/semantic/ownership_graph.rb:142` (scope_depth) ; `src/semantic/ownership_graph.rb:147` (push_scope!) ; `src/semantic/ownership_graph.rb:153` (pop_scope!) ; `src/semantic/ownership_graph.rb:159` (nodes) ; `src/semantic/ownership_graph.rb:167` (clear_completed_snapshot!)
- `Scope` (`src/ast/scope.rb:106` (Scope)) -- implicit lifecycle score **394** (public=35, state methods=19, writers=2, fields=7, shared=7, flows=19!, states=2^7)
  - shared fields: `@bindings | @dependencies | @depth | @owned_names | @parent | @type_store | @types`
  - surface: `src/ast/scope.rb:106` (initialize) ; `src/ast/scope.rb:117` (declare) ; `src/ast/scope.rb:140` (install_entry) ; `src/ast/scope.rb:158` (initialize_copy) ; `src/ast/scope.rb:189` (install_type) ; `src/ast/scope.rb:200` (resolve_type_entry)
- `ZigTranspiler` (`src/backends/transpiler.rb:42` (ZigTranspiler)) -- implicit lifecycle score **304** (public=6, state methods=4, writers=3, fields=8, shared=4, flows=4!, states=2^8)
  - shared fields: `@default_stack_size | @importer | @source_dir | @test_mode`
  - surface: `src/backends/transpiler.rb:42` (initialize) ; `src/backends/transpiler.rb:56` (transpile) ; `src/backends/transpiler.rb:66` (transpile_mir) ; `src/backends/transpiler.rb:161` (transpile_as_module)
- `StructRBI` (`gems/nil-kill/lib/nil_kill/struct_rbi.rb:6` (StructRBI)) -- implicit lifecycle score **254** (public=10, state methods=6, writers=3, fields=7, shared=7, flows=6!, states=2^7)
  - shared fields: `@blocklist | @complete | @evidence | @include_existing | @max_validate_iterations | @output | @validate`
  - surface: `gems/nil-kill/lib/nil_kill/struct_rbi.rb:6` (initialize) ; `gems/nil-kill/lib/nil_kill/struct_rbi.rb:16` (run) ; `gems/nil-kill/lib/nil_kill/struct_rbi.rb:35` (run_with_validation) ; `gems/nil-kill/lib/nil_kill/struct_rbi.rb:94` (write_or_print) ; `gems/nil-kill/lib/nil_kill/struct_rbi.rb:105` (generate) ; `gems/nil-kill/lib/nil_kill/struct_rbi.rb:138` (generate_complete)
- `StateMesh` (`gems/decomplex/lib/decomplex/state_mesh.rb:43` (StateMesh)) -- implicit lifecycle score **248** (public=14, state methods=10, writers=2, fields=7, shared=6, flows=10!, states=2^7)
  - shared fields: `@custom_fields | @min_writes | @re_derivations | @reads | @src_map | @writes`
  - surface: `gems/decomplex/lib/decomplex/state_mesh.rb:43` (initialize) ; `gems/decomplex/lib/decomplex/state_mesh.rb:54` (discover_fields!) ; `gems/decomplex/lib/decomplex/state_mesh.rb:60` (walk_writes) ; `gems/decomplex/lib/decomplex/state_mesh.rb:97` (find_reads!) ; `gems/decomplex/lib/decomplex/state_mesh.rb:106` (walk_reads) ; `gems/decomplex/lib/decomplex/state_mesh.rb:149` (find_re_derivations!)
- `SourceInstrumenter` (`gems/nil-kill/lib/nil_kill/source_instrumenter.rb:6` (SourceInstrumenter)) -- implicit lifecycle score **160** (public=18, state methods=8, writers=4, fields=5, shared=4, flows=8!, states=2^5)
  - shared fields: `@line_offsets | @method_plans_by_file_line | @trace_plan | @tracepoint_methods`
  - surface: `gems/nil-kill/lib/nil_kill/source_instrumenter.rb:6` (initialize) ; `gems/nil-kill/lib/nil_kill/source_instrumenter.rb:50` (run_in_place) ; `gems/nil-kill/lib/nil_kill/source_instrumenter.rb:75` (instrument_file_with_map) ; `gems/nil-kill/lib/nil_kill/source_instrumenter.rb:113` (instrument_file) ; `gems/nil-kill/lib/nil_kill/source_instrumenter.rb:135` (collect_method_edits) ; `gems/nil-kill/lib/nil_kill/source_instrumenter.rb:245` (start_line_offset)
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
- `Apply` (`gems/nil-kill/lib/nil_kill/apply.rb:6` (Apply)) -- implicit lifecycle score **24** (public=49, state methods=4, writers=2, fields=3, shared=2, flows=4!, states=2^3)
  - shared fields: `@all | @dry_run`
  - surface: `gems/nil-kill/lib/nil_kill/apply.rb:6` (initialize) ; `gems/nil-kill/lib/nil_kill/apply.rb:14` (evidence) ; `gems/nil-kill/lib/nil_kill/apply.rb:18` (run) ; `gems/nil-kill/lib/nil_kill/apply.rb:26` (apply_actions)
- `EffectSet` (`src/semantic/effect_set.rb:44` (EffectSet)) -- implicit lifecycle score **20** (public=9, state methods=8, writers=2, fields=2, shared=1, flows=8!, states=2^2)
  - shared fields: `@effects`
  - surface: `src/semantic/effect_set.rb:44` (initialize) ; `src/semantic/effect_set.rb:55` (empty) ; `src/semantic/effect_set.rb:61` (include?) ; `src/semantic/effect_set.rb:66` (empty?) ; `src/semantic/effect_set.rb:71` (union) ; `src/semantic/effect_set.rb:76` (==)
- `CLI` (`gems/nil-kill/lib/nil_kill/cli.rb:6` (CLI)) -- implicit lifecycle score **18** (public=16, state methods=7, writers=2, fields=2, shared=1, flows=7!, states=2^2)
  - shared fields: `@argv`
  - surface: `gems/nil-kill/lib/nil_kill/cli.rb:6` (initialize) ; `gems/nil-kill/lib/nil_kill/cli.rb:10` (run) ; `gems/nil-kill/lib/nil_kill/cli.rb:97` (guard_fresh_runtime!) ; `gems/nil-kill/lib/nil_kill/cli.rb:123` (guard_fresh_evidence!) ; `gems/nil-kill/lib/nil_kill/cli.rb:146` (collect) ; `gems/nil-kill/lib/nil_kill/cli.rb:189` (acquire_inplace_lock!)
- `FalseSimplicityTest` (`gems/decomplex/test/false_simplicity_test.rb:12` (FalseSimplicityTest)) -- implicit lifecycle score **11** (public=21, state methods=3, writers=3, fields=1, shared=1, flows=3!, states=2^1)
  - shared fields: `@tmp`
  - surface: `gems/decomplex/test/false_simplicity_test.rb:12` (scan) ; `gems/decomplex/test/false_simplicity_test.rb:21` (scan2) ; `gems/decomplex/test/false_simplicity_test.rb:364` (test_report_renders_false_simplicity_section)
- ...(+1 more)

## Missing Abstractions (254)
_guard tuple recomputed across >=2 decision units_

- **[conjunction]** support=12 scatter=12 rank=144
  - tuple: `!shape["poisoned"] | shape`
  - `gems/nil-kill/lib/nil_kill/source_index.rb:1107` (seed_param_hash_shapes) ; `gems/nil-kill/lib/nil_kill/source_index.rb:1114` (seed_param_array_element_shapes) ; `gems/nil-kill/lib/nil_kill/source_index.rb:1312` (add_array_element_shape) ; `gems/nil-kill/lib/nil_kill/source_index.rb:1319` (add_array_element_shapes) ; `gems/nil-kill/lib/nil_kill/source_index.rb:1335` (merge_hash_shape_literal) ; `gems/nil-kill/lib/nil_kill/source_index.rb:1763` (record_callsite_hash_shape)
- **[conjunction]** support=11 scatter=11 rank=121
  - tuple: `assoc.respond_to?(:key) | assoc.respond_to?(:value)`
  - `gems/nil-kill/lib/nil_kill/apply.rb:395` (signature_param_type_node) ; `gems/nil-kill/lib/nil_kill/apply.rb:483` (hash_record_cast_constructor_fields) ; `gems/nil-kill/lib/nil_kill/apply.rb:502` (hash_record_nested_constructor_edits) ; `gems/nil-kill/lib/nil_kill/source_index.rb:608` (inspect_class_constructor_fields) ; `gems/nil-kill/lib/nil_kill/source_index.rb:636` (inspect_hash_literal) ; `gems/nil-kill/lib/nil_kill/source_index.rb:675` (container_origin_for_value)
- **[case_dispatch]** support=6 scatter=6 rank=36
  - tuple: `AST::AllOp | AST::AnyOp | AST::AverageOp | AST::CountOp | AST::FindOp | AST::MaxOp | AST::MinOp | AST::SumOp`
  - `src/ast/ast.rb:2125` (pipeline_range_fold?) ; `src/mir/lower/pipeline/pipeline_binding_chain_lowerer.rb:186` (fold_expression) ; `src/mir/lower/pipeline/pipeline_binding_chain_lowerer.rb:194` (lower_binding_fold) ; `src/mir/lower/pipeline/pipeline_host.rb:768` (build_soa_scalar_fold_block) ; `src/mir/lower/pipeline/pipeline_range_lowerer.rb:501` (scalar_fold_plan) ; `src/mir/lower/pipeline/pipeline_scalar_lowerer.rb:32` (lower)
- **[conjunction]** support=5 scatter=5 rank=25
  - tuple: `char <= "9" | char >= "0"`
  - `src/backends/zig_type.rb:25` (primitive_numeric_identifier?) ; `src/backends/zig_type.rb:34` (float_identifier?) ; `src/backends/zig_type.rb:44` (integer_identifier?) ; `src/mir/fsm_transform/emit.rb:553` (decimal_digits?) ; `src/mir/lower/pipeline/pipeline_batch_window_lowerer.rb:168` (decimal_literal?)
- **[case_dispatch]** support=5 scatter=5 rank=25
  - tuple: `'END' | END_BLOCK_OPENERS`
  - `src/tools/formatter.rb:534` (find_match_block_end) ; `src/tools/formatter.rb:598` (scan_match_arms) ; `src/tools/formatter.rb:638` (build_match_arm) ; `src/tools/formatter.rb:757` (emit_match_body) ; `src/tools/formatter.rb:1242` (matching_end)
- **[conjunction]** support=5 scatter=5 rank=25
  - tuple: `key | value`
  - `gems/nil-kill/lib/nil_kill/infer.rb:1622` (generic_candidate_type) ; `gems/nil-kill/lib/nil_kill/report.rb:3935` (collection_slot_candidate) ; `gems/nil-kill/lib/nil_kill/report.rb:4092` (append_runtime_collection_observations) ; `gems/nil-kill/lib/nil_kill/util.rb:367` (shape_type) ; `gems/nil-kill/lib/nil_kill/util.rb:391` (shape_union_type)
- **[conjunction]** support=5 scatter=5 rank=25
  - tuple: `line | path`
  - `gems/nil-kill/lib/nil_kill/report.rb:1188` (trace_origin) ; `gems/nil-kill/lib/nil_kill/report.rb:1202` (source_line) ; `gems/nil-kill/lib/nil_kill/runtime_trace.rb:618` (record_collection_observation_core) ; `gems/nil-kill/lib/nil_kill/runtime_trace.rb:1459` (attach_struct) ; `gems/nil-kill/lib/nil_kill/runtime_trace.rb:1561` (record_struct_field)
- **[conjunction]** support=5 scatter=4 rank=20
  - tuple: `Ast.node?(receiver) | receiver.type == :SELF`
  - `gems/decomplex/lib/decomplex/ordered_protocol_mine.rb:258` (internal_receiver?) ; `gems/decomplex/lib/decomplex/ruby_topology.rb:216` (method_name) ; `gems/decomplex/lib/decomplex/ruby_topology.rb:328` (internal_call_name) ; `gems/decomplex/lib/decomplex/ruby_topology.rb:360` (method_name) ; `gems/decomplex/lib/decomplex/weighted_inlined_cognitive_complexity.rb:156` (method_name)
- **[case_dispatch]** support=4 scatter=4 rank=16
  - tuple: `AST::GetField | AST::GetIndex | AST::Identifier`
  - `src/annotator/domains/variables.rb:578` (visit_Assignment) ; `src/annotator/helpers/capabilities.rb:140` (cap_var_label) ; `src/ast/ast.rb:433` (root_identifier) ; `src/ast/parser.rb:3977` (deep_clone_node)
- **[conjunction]** support=4 scatter=4 rank=16
  - tuple: `!source.empty? | source`
  - `src/ast/syntax_typo_scanner.rb:41` (scan!) ; `src/mir/lowering/capabilities.rb:842` (lower_pre_clauses) ; `src/mir/lowering/functions.rb:839` (build_post_outer_fn) ; `gems/nil-kill/lib/nil_kill/report.rb:1204` (source_line)
- **[case_dispatch]** support=4 scatter=4 rank=16
  - tuple: `:parallel | :shared`
  - `src/mir/fsm_transform/emit.rb:1484` (profile_dispatch_id) ; `src/mir/lowering/concurrency.rb:673` (profile_dispatch_numeric_id) ; `src/mir/lowering/concurrency.rb:710` (profile_dispatch_symbol) ; `src/mir/mir_lowering.rb:3224` (profile_dispatch_id)
- **[conjunction]** support=4 scatter=4 rank=16
  - tuple: `!metadata.empty? | metadata`
  - `src/mir/mir_checker.rb:1937` (verify_allocator_closed_set!) ; `src/mir/mir_checker.rb:1954` (verify_allocator_metadata_targets!) ; `src/mir/mir_checker.rb:2100` (verify_cross_frame_param_alloc!) ; `src/mir/mir_checker.rb:2680` (expr_has_frame_alloc?)
- **[conjunction]** support=4 scatter=4 rank=16
  - tuple: `j < toks.length | toks[j].type == :NL`
  - `src/tools/formatter.rb:893` (skip_nls) ; `src/tools/formatter.rb:2306` (detect_recover_stages) ; `src/tools/formatter.rb:2448` (emit_record_type) ; `src/tools/formatter.rb:2491` (emit_stmt_terminator)
- **[case_dispatch]** support=4 scatter=4 rank=16
  - tuple: `Prism::StringNode | Prism::SymbolNode`
  - `gems/nil-kill/lib/nil_kill/apply.rb:402` (signature_keyword_name) ; `gems/nil-kill/lib/nil_kill/apply.rb:529` (hash_record_constructor_key_name) ; `gems/nil-kill/lib/nil_kill/source_index.rb:255` (classify_origin) ; `gems/nil-kill/lib/nil_kill/source_index.rb:855` (hash_key_name)
- **[case_dispatch]** support=4 scatter=4 rank=16
  - tuple: `"(" | ")"`
  - `gems/nil-kill/lib/nil_kill/rbi_return_index.rb:171` (extract_call_args_at) ; `gems/nil-kill/lib/nil_kill/report.rb:4248` (extract_call_args) ; `gems/nil-kill/lib/nil_kill/util.rb:251` (extract_call_args) ; `gems/nil-kill/lib/nil_kill/util.rb:292` (broad_union_type?)
- **[conjunction]** support=4 scatter=4 rank=16
  - tuple: `rec | rec["calls"].to_i.positive?`
  - `gems/nil-kill/lib/nil_kill/report.rb:2046` (classify_param_untyped_cause) ; `gems/nil-kill/lib/nil_kill/report.rb:2097` (classify_return_untyped_cause) ; `gems/nil-kill/lib/nil_kill/report.rb:3918` (collection_slot_candidate) ; `gems/nil-kill/lib/nil_kill/report.rb:3945` (collection_slot_missing_candidate_reason)
- **[case_dispatch]** support=4 scatter=4 rank=16
  - tuple: `Array | Hash | Set`
  - `gems/nil-kill/lib/nil_kill/runtime_trace.rb:346` (collection_type_shape_key) ; `gems/nil-kill/lib/nil_kill/runtime_trace.rb:391` (collection_type_shape_key_full) ; `gems/nil-kill/lib/nil_kill/runtime_trace.rb:430` (container_shape) ; `gems/nil-kill/lib/nil_kill/runtime_trace.rb:491` (container_shape_full)
- **[conjunction]** support=4 scatter=4 rank=16
  - tuple: `block | block.respond_to?(:body)`
  - `gems/nil-kill/lib/nil_kill/source_index.rb:344` (walk_call_children) ; `gems/nil-kill/lib/nil_kill/source_index.rb:471` (collect_call_collection_index_facts) ; `gems/nil-kill/lib/nil_kill/source_index.rb:2428` (hash_shape_for_block_return) ; `gems/nil-kill/lib/nil_kill/source_index.rb:2785` (block_return_type)
- **[conjunction]** support=4 scatter=4 rank=16
  - tuple: `name | shape`
  - `gems/nil-kill/lib/nil_kill/source_index.rb:353` (walk_call_children) ; `gems/nil-kill/lib/nil_kill/source_index.rb:479` (collect_call_collection_index_facts) ; `gems/nil-kill/lib/nil_kill/source_index.rb:2433` (hash_shape_for_block_return) ; `gems/nil-kill/lib/nil_kill/source_index.rb:2794` (block_return_type)
- **[conjunction]** support=4 scatter=3 rank=12
  - tuple: `cursor.is_a?(AST::BinaryOp) | cursor.smooth?`
  - `src/backends/pipeline_rewriter.rb:280` (collect_chain) ; `src/mir/lower/pipeline/pipeline_binding_chain_lowerer.rb:73` (unwrap_chain) ; `src/mir/lower/pipeline/pipeline_binding_chain_lowerer.rb:83` (unwrap_chain) ; `src/mir/lower/pipeline/pipeline_range_lowerer.rb:289` (unwrap_range_chain)
- **[case_dispatch]** support=4 scatter=3 rank=12
  - tuple: `AST::Assignment | AST::BindExpr | AST::VarDecl`
  - `src/mir/fsm_transform/liveness.rb:209` (collect_defs) ; `src/mir/mir_pass.rb:548` (collect_consumed_names) ; `src/mir/mir_pass.rb:566` (collect_consumed_names) ; `src/tools/migration_suggester_helpers.rb:88` (walk_recursive)
- **[conjunction]** support=4 scatter=3 rank=12
  - tuple: `!target.to_s.empty? | target`
  - `src/mir/mir_checker.rb:1879` (allocator_metadata_target) ; `src/mir/mir_checker.rb:1882` (allocator_metadata_target) ; `src/mir/mir_checker.rb:1956` (verify_allocator_metadata_targets!) ; `src/mir/mir_checker.rb:2036` (verify_allocator_metadata_contracts!)
- **[conjunction]** support=4 scatter=3 rank=12
  - tuple: `Ast.node?(scope) | scope.type == :SCOPE`
  - `gems/decomplex/lib/decomplex/ruby_topology.rb:170` (owner_body) ; `gems/decomplex/lib/decomplex/ruby_topology.rb:344` (owner_body) ; `gems/decomplex/lib/decomplex/temporal_ordering_pressure.rb:73` (owner_body) ; `gems/decomplex/lib/decomplex/weighted_inlined_cognitive_complexity.rb:140` (owner_body)
- **[conjunction]** support=5 scatter=2 rank=10
  - tuple: `NilKill.acceptable_shape_candidate?(candidate) | candidate`
  - `gems/nil-kill/lib/nil_kill/infer.rb:1609` (generic_candidate_type) ; `gems/nil-kill/lib/nil_kill/infer.rb:1614` (generic_candidate_type) ; `gems/nil-kill/lib/nil_kill/infer.rb:1623` (generic_candidate_type) ; `gems/nil-kill/lib/nil_kill/report.rb:3927` (collection_slot_candidate) ; `gems/nil-kill/lib/nil_kill/report.rb:3936` (collection_slot_candidate)
- **[case_dispatch]** support=3 scatter=3 rank=9
  - tuple: `:ATOMIC | :LOCKED | :VERSIONED`
  - `src/annotator/annotator.rb:455` (with_match_family_effects) ; `src/mir/mir_emitter.rb:996` (emit_with_match_probe) ; `src/mir/mir_emitter.rb:1013` (emit_with_match_prelude)
- ...(+229 more)

## Reification Misses (18)
_an existing predicate reinvented inline -- invariant #16_

- predicate `atomic?` reinvented inline at `src/ast/parser.rb:2871` (parse_type_annotation) (`sync == :atomic`)
- predicate `captured_value?` reinvented inline at `src/mir/fiber_ctx_builder.rb:153` (cleanup_mir_for) (`cleanup_plan.kind == CaptureCleanupKind::CapturedValue`)
- predicate `frame?` reinvented inline at `src/semantic/local_binding_facts.rb:100` (binding_frame_allocates?) (`alloc == :frame`)
- predicate `indirect?` reinvented inline at `src/ast/parser.rb:2871` (parse_type_annotation) (`layout == :indirect`)
- predicate `moved?` reinvented inline at `src/annotator/domains/control_flow.rb:78` (analyze_control_flow_branches) (`state == :moved`)
- predicate `uniform_value?` reinvented inline at `src/mir/fiber_ctx_builder.rb:154` (cleanup_mir_for) (`cleanup_plan.kind == CaptureCleanupKind::UniformValue`)
- predicate `untyped_type?` reinvented inline at `gems/nil-kill/lib/nil_kill/infer.rb:230` (propose_struct_field_sig_actions) (`type == "T.untyped"`)
- predicate `untyped_type?` reinvented inline at `gems/nil-kill/lib/nil_kill/infer.rb:548` (hash_record_expand_row_from_return_origins) (`type == "T.untyped"`)
- predicate `untyped_type?` reinvented inline at `gems/nil-kill/lib/nil_kill/infer.rb:1511` (proposed_type_accepts?) (`type == "T.untyped"`)
- predicate `untyped_type?` reinvented inline at `gems/nil-kill/lib/nil_kill/infer.rb:1856` (resolve_callee) (`type == "T.untyped"`)
- predicate `untyped_type?` reinvented inline at `gems/nil-kill/lib/nil_kill/report.rb:717` (forwarded_return_status_index) (`type == "T.untyped"`)
- predicate `untyped_type?` reinvented inline at `gems/nil-kill/lib/nil_kill/report.rb:1547` (node_alias_candidate_rows) (`type == "T.untyped"`)
- predicate `untyped_type?` reinvented inline at `gems/nil-kill/lib/nil_kill/report.rb:2000` (untyped_cause_table) (`type == "T.untyped"`)
- predicate `untyped_type?` reinvented inline at `gems/nil-kill/lib/nil_kill/report.rb:2355` (append_untyped_breakdown) (`type == "T.untyped"`)
- predicate `untyped_type?` reinvented inline at `gems/nil-kill/lib/nil_kill/report.rb:2649` (append_untyped_param_source_categories) (`type == "T.untyped"`)
- predicate `untyped_type?` reinvented inline at `gems/nil-kill/lib/nil_kill/report.rb:2759` (untyped_param_slot_keys) (`type == "T.untyped"`)
- predicate `untyped_type?` reinvented inline at `gems/nil-kill/lib/nil_kill/report.rb:4343` (weak_untyped_type?) (`type == "T.untyped"`)
- predicate `untyped_type?` reinvented inline at `gems/nil-kill/lib/nil_kill/source_index.rb:2030` (non_nil_sig_params) (`type == "T.untyped"`)

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

## Exact Predicate Aliases (21)
_identical one-line predicate body under >=2 names_

- `enum? = resource? = union? = struct? = suspend? = mir? = stmt? = expr? = has_own_frame? = needs_capture_site_annotation?` == `true`
  - `src/ast/schemas.rb:34` (enum?) ; `src/ast/schemas.rb:146` (resource?) ; `src/ast/schemas.rb:273` (union?) ; `src/ast/schemas.rb:325` (struct?) ; `src/mir/fsm_transform/segments.rb:51` (suspend?) ; `src/mir/fsm_transform/segments.rb:69` (suspend?) ; `src/mir/mir.rb:382` (mir?) ; `src/mir/mir.rb:451` (stmt?) ; `src/mir/mir.rb:473` (expr?) ; `src/mir/mir.rb:935` (has_own_frame?) ; `src/mir/mir.rb:1624` (expr?) ; `src/mir/mir.rb:1651` (expr?) ; `src/mir/mir.rb:2027` (expr?) ; `src/mir/mir.rb:2038` (expr?) ; `src/mir/mir.rb:2055` (expr?) ; `src/mir/mir.rb:2086` (expr?) ; `src/mir/mir.rb:2546` (stmt?) ; `src/mir/mir.rb:2562` (stmt?) ; `src/mir/mir.rb:3117` (stmt?) ; `src/mir/mir.rb:3153` (stmt?) ; `src/mir/mir.rb:3187` (stmt?) ; `src/mir/mir.rb:3226` (stmt?) ; `src/mir/mir.rb:3239` (stmt?) ; `src/mir/mir.rb:3278` (stmt?) ; `src/mir/mir.rb:3307` (stmt?) ; `src/mir/mir.rb:3328` (stmt?) ; `src/mir/mir.rb:3340` (stmt?) ; `src/mir/mir.rb:3347` (stmt?) ; `src/mir/mir.rb:3354` (stmt?) ; `src/mir/mir.rb:3366` (stmt?) ; `src/mir/mir.rb:3373` (stmt?) ; `src/mir/mir.rb:3381` (stmt?) ; `src/mir/mir.rb:3397` (stmt?) ; `src/mir/mir.rb:3443` (stmt?) ; `src/mir/mir.rb:3456` (stmt?) ; `src/mir/mir.rb:4328` (expr?) ; `src/mir/mir.rb:4687` (expr?) ; `src/semantic/capture_strategy.rb:107` (needs_capture_site_annotation?) ; `src/semantic/capture_strategy.rb:127` (needs_capture_site_annotation?)
- `test_heterogeneous_union_is_not_flagged = test_two_variant_dispatch_is_not_a_union = test_symbol_and_int_dispatch_are_not_unions = test_predicate_less_case_is_skipped = test_safe_nav_guard_does_not_track_calls_with_arguments = test_safe_nav_guard_does_not_prove_receiver_on_false_branch = test_disjunction_truthy_branch_does_not_prove_each_local_non_nil = test_non_nil_proof_does_not_make_later_truthiness_guard_redundant = test_reassignment_invalidates_prior_non_nil_proof = test_non_terminating_nil_branch_does_not_dominate_following_code` == `assert_empty scan(<<~RB)`
  - `gems/decomplex/test/fat_union_test.rb:83` (test_heterogeneous_union_is_not_flagged) ; `gems/decomplex/test/fat_union_test.rb:97` (test_two_variant_dispatch_is_not_a_union) ; `gems/decomplex/test/fat_union_test.rb:108` (test_symbol_and_int_dispatch_are_not_unions) ; `gems/decomplex/test/fat_union_test.rb:127` (test_predicate_less_case_is_skipped) ; `gems/decomplex/test/redundant_nil_guard_test.rb:146` (test_safe_nav_guard_does_not_track_calls_with_arguments) ; `gems/decomplex/test/redundant_nil_guard_test.rb:167` (test_safe_nav_guard_does_not_prove_receiver_on_false_branch) ; `gems/decomplex/test/redundant_nil_guard_test.rb:177` (test_disjunction_truthy_branch_does_not_prove_each_local_non_nil) ; `gems/decomplex/test/redundant_nil_guard_test.rb:188` (test_non_nil_proof_does_not_make_later_truthiness_guard_redundant) ; `gems/decomplex/test/redundant_nil_guard_test.rb:197` (test_reassignment_invalidates_prior_non_nil_proof) ; `gems/decomplex/test/redundant_nil_guard_test.rb:207` (test_non_terminating_nil_branch_does_not_dominate_following_code)
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
- `sorbet_validate_fingerprint = fingerprint` == `JSON.generate([action["kind"], action["path"], action["line"], action["message"], action["data"]])`
  - `gems/nil-kill/lib/nil_kill/infer.rb:1484` (sorbet_validate_fingerprint) ; `gems/nil-kill/lib/nil_kill/loop.rb:606` (fingerprint)
- `format_origin = return_method_key` == `"#{origin["path"]}:#{origin["line"]} #{origin["class"]}##{origin["method"]}"`
  - `gems/nil-kill/lib/nil_kill/infer.rb:1870` (format_origin) ; `gems/nil-kill/lib/nil_kill/report.rb:770` (return_method_key)
- `params_for_typing = params_for_levenshtein` == `rec["params_ok"].empty? ? rec["params_by_name"] : rec["params_ok"]`
  - `gems/nil-kill/lib/nil_kill/infer.rb:2025` (params_for_typing) ; `gems/nil-kill/lib/nil_kill/loop.rb:313` (params_for_levenshtein)
- `param_sites_for_typing = param_sites_for_levenshtein` == `rec["param_sites_ok"].empty? ? rec["param_sites"] : rec["param_sites_ok"]`
  - `gems/nil-kill/lib/nil_kill/infer.rb:2108` (param_sites_for_typing) ; `gems/nil-kill/lib/nil_kill/loop.rb:317` (param_sites_for_levenshtein)

## Inconsistent Rename Clones (72)
_pasted block with inconsistent identifier mapping -- *POSSIBLE* missed rename bug_

- *POSSIBLE* `gems/decomplex/lib/decomplex/state_branch_density.rb:99` (state_refs) clone of `src/tools/lint_fix_rewriter.rb:194` (redundant_type_annotation_edits): ref var `edits` spelled ["refs", "defn"] here
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
- ...(+47 more)

## Flay Similarity (Type-2/3) (0)
_Flay structural clone pressure: Type-2 renamed clones and Type-3 fuzzy clones -- refactor pressure, not a verdict_

None.

## Neglected Updates (721)
_co-written state, one write missing -- *POSSIBLE* redundant-state desync_

- *POSSIBLE* (support=16) `src/ast/fixable_error.rb:32` (initialize) writes `.@file` but NOT `.@lines` (recv `self`)
- *POSSIBLE* (support=16) `gems/decomplex/lib/decomplex/inconsistent_rename_clone.rb:31` (initialize) writes `.@file` but NOT `.@lines` (recv `self`)
- *POSSIBLE* (support=16) `gems/decomplex/lib/decomplex/sequence_mine.rb:59` (initialize) writes `.@file` but NOT `.@lines` (recv `self`)
- *POSSIBLE* (support=16) `gems/nil-kill/lib/nil_kill/source_index.rb:134` (initialize) writes `.@lines` but NOT `.@file` (recv `self`)
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
- ...(+696 more)

## Derived-State Staleness (151)
_b = f(a); a later reassigned, b not recomputed -- *POSSIBLE* bug_

- *POSSIBLE* `src/mir/lowering/control_flow.rb:374` (for_each_loop_stmt): `key_ptr` derived from `for_id` (line 374); `for_id` reassigned line 439, `key_ptr` not recomputed
- *POSSIBLE* `src/tools/doctor.rb:165` (section_heap): `addrs` derived from `sites` (line 165); `sites` reassigned line 225, `addrs` not recomputed
- *POSSIBLE* `src/annotator/domains/errors.rb:379` (visit_ReturnNode): `expected_void_compatible` derived from `expected` (line 379); `expected` reassigned line 431, `expected_void_compatible` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:2817` (needs_space?): `a_is_struct_open` derived from `a_idx` (line 2817); `a_idx` reassigned line 2861, `a_is_struct_open` not recomputed
- *POSSIBLE* `src/mir/lowering/literals.rb:106` (lower_list_lit): `promise_zig` derived from `elem_zig` (line 106); `elem_zig` reassigned line 136, `promise_zig` not recomputed
- *POSSIBLE* `src/backends/pipeline_rewriter.rb:552` (build_recursive_body): `skip_if` derived from `cond` (line 552); `cond` reassigned line 577, `skip_if` not recomputed
- *POSSIBLE* `gems/nil-kill/lib/nil_kill/source_index.rb:503` (collect_prescan): `child_c` derived from `name` (line 503); `name` reassigned line 528, `child_c` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:2268` (find_s_chains): `s_idxs` derived from `i` (line 2268); `i` reassigned line 2292, `s_idxs` not recomputed
- *POSSIBLE* `src/ast/ast.rb:1096` (finalize_storage!): `value_sync` derived from `vt` (line 1096); `vt` reassigned line 1119, `value_sync` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:1189` (branch_end_for_inline_expansion): `t` derived from `j` (line 1189); `j` reassigned line 1212, `t` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:2270` (find_s_chains): `j` derived from `i` (line 2270); `i` reassigned line 2292, `j` not recomputed
- *POSSIBLE* `src/annotator/domains/variables.rb:557` (visit_Assignment): `tname` derived from `target` (line 557); `target` reassigned line 577, `tname` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:1640` (expand_concurrent_drops): `t` derived from `i` (line 1640); `i` reassigned line 1659, `t` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:2933` (capability_chain_colon?): `t` derived from `j` (line 2933); `j` reassigned line 2952, `t` not recomputed
- *POSSIBLE* `gems/nil-kill/lib/nil_kill/util.rb:287` (broad_union_type?): `start` derived from `idx` (line 287); `idx` reassigned line 306, `start` not recomputed
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
- ...(+126 more)

## Neglected Conditions (18)
_dispatch/conjunction minus one element -- *POSSIBLE* bug_

- *POSSIBLE* (support=4) `src/mir/hoist.rb:247` (each_call_like_child) -- MISSING `Set` from `Array | Hash | Set`
- *POSSIBLE* (support=4) `src/mir/hoist.rb:1056` (replace_mir_expr_in_value!) -- MISSING `Set` from `Array | Hash | Set`
- *POSSIBLE* (support=4) `src/mir/lowering/capabilities.rb:153` (build_field_path_zig) -- MISSING `AST::GetIndex` from `AST::GetField | AST::GetIndex | AST::Identifier`
- *POSSIBLE* (support=4) `src/semantic/escape_analysis.rb:903` (function_facts) -- MISSING `AST::Assignment` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- *POSSIBLE* (support=4) `src/semantic/local_binding_facts.rb:75` (binding_decl_name) -- MISSING `AST::Assignment` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- *POSSIBLE* (support=4) `src/semantic/local_binding_facts.rb:87` (binding_entry) -- MISSING `AST::Assignment` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- *POSSIBLE* (support=4) `src/tools/atomic_migration_suggester.rb:133` (stmt_eligible?) -- MISSING `AST::VarDecl` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- *POSSIBLE* (support=4) `src/tools/atomic_ptr_migration_suggester.rb:125` (stmt_eligible?) -- MISSING `AST::VarDecl` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- *POSSIBLE* (support=4) `gems/nil-kill/spec/fixtures/zero_gap_corpus/abs_require_lib.rb:16` (walk) -- MISSING `Set` from `Array | Hash | Set`
- *POSSIBLE* (support=3) `src/annotator/domains/execution_boundaries.rb:517` (validate_snapshot_match_arms!) -- MISSING `:LOCKED` from `:ATOMIC | :LOCKED | :VERSIONED`
- *POSSIBLE* (support=3) `src/mir/fsm_transform/recursive_splitter.rb:411` (emit_pivot) -- MISSING `AST::CatchBlock` from `AST::CatchBlock | AST::ForEach | AST::ForRange | AST::IfStatement | AST::WhileBindLoop | AST::WhileLoop | AST::WithBlock`
- *POSSIBLE* (support=3) `src/mir/mir_checker.rb:2558` (ownership_node_name) -- MISSING `MIR::ShardedMapGet` from `MIR::IndexedStore | MIR::RegistryCall | MIR::ShardedMapGet | MIR::ShardedMapPut`
- *POSSIBLE* (support=3) `gems/decomplex/lib/decomplex/false_simplicity.rb:224` (block_pass?) -- MISSING `:VCALL` from `:CALL | :FCALL | :OPCALL | :VCALL`
- *POSSIBLE* (support=3) `gems/decomplex/lib/decomplex/sequence_mine.rb:92` (passive_reader_call?) -- MISSING `:OPCALL` from `:CALL | :FCALL | :OPCALL | :VCALL`
- *POSSIBLE* (support=3) `gems/nil-kill/lib/nil_kill/apply.rb:508` (hash_record_nested_constructor_edits) -- MISSING `"set"` from `"array" | "hash" | "set"`
- *POSSIBLE* (support=3) `gems/nil-kill/lib/nil_kill/infer.rb:1499` (runtime_contradicts?) -- MISSING `:local` from `:local | :param | :return`
- *POSSIBLE* (support=3) `gems/nil-kill/lib/nil_kill/report.rb:4088` (append_runtime_collection_observations) -- MISSING `"array"` from `"array" | "hash" | "set"`
- *POSSIBLE* (support=3) `gems/nil-kill/lib/nil_kill/source_index.rb:2708` (collection_index_return_type) -- MISSING `"set"` from `"array" | "hash" | "set"`

## Neglected Path Conditions (1572)
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
- *POSSIBLE* (support=36) `gems/nil-kill/lib/nil_kill/source_index.rb:417` (refill_struct_constructor_types) -- MISSING `fields` from `fields | node.is_a?(Prism::CallNode) | node.name == :new | node.receiver`
- ...(+1547 more)

## Oversized Predicates (35)
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
- *POSSIBLE* `gems/decomplex/lib/decomplex/state_mesh.rb:119` (walk_reads) -- 4 condition atoms in `args.nil? || (Ast.node?(args) && args.type == :LIST && args.children.compact.empty?)`
  - atoms: `args.nil? | Ast.node?(args) | args.type == :LIST | args.children.compact.empty?`
- *POSSIBLE* `gems/nil-kill/lib/nil_kill/apply.rb:196` (apply_hash_record_cluster_promotion) -- 7 condition atoms in `struct_name.empty? || type_name.empty? || fields.empty? || (producers.empty? && consumers.empty? && signatures.empty? && !insert_only)`
  - atoms: `struct_name.empty? | type_name.empty? | fields.empty? | producers.empty? | consumers.empty? | signatures.empty? | !insert_only`
- *POSSIBLE* `gems/nil-kill/lib/nil_kill/apply.rb:420` (nodes_matching_source) -- 4 condition atoms in `loc && loc.start_line == line && node.respond_to?(:slice) && node.slice == code`
  - atoms: `loc | loc.start_line == line | node.respond_to?(:slice) | node.slice == code`
- *POSSIBLE* `gems/nil-kill/lib/nil_kill/guarded_autocorrect.rb:27` (run) -- 4 condition atoms in `previous_count && count >= previous_count && restored_safe_nav.zero? && restored_bogus.zero?`
  - atoms: `previous_count | count >= previous_count | restored_safe_nav.zero? | restored_bogus.zero?`
- *POSSIBLE* `gems/nil-kill/lib/nil_kill/infer.rb:254` (propose_hash_record_struct_actions) -- 4 condition atoms in `path.to_s.empty? || line <= 0 || name.to_s.empty? || code.to_s.empty?`
  - atoms: `path.to_s.empty? | line <= 0 | name.to_s.empty? | code.to_s.empty?`
- *POSSIBLE* `gems/nil-kill/lib/nil_kill/infer.rb:550` (hash_record_expand_row_from_return_origins) -- 4 condition atoms in `optional.include?(field) && type != "T.untyped" && type != "NilClass" && !type.start_with?("T.nilable(")`
  - atoms: `optional.include?(field) | type != "T.untyped" | type != "NilClass" | !type.start_with?("T.nilable(")`
- *POSSIBLE* `gems/nil-kill/lib/nil_kill/infer.rb:1415` (recompute_origin_candidate_and_confidence!) -- 4 condition atoms in `useful && !NilKill.weak_type?(candidate) && blockers.empty? && !has_call_untyped`
  - atoms: `useful | !NilKill.weak_type?(candidate) | blockers.empty? | !has_call_untyped`
- *POSSIBLE* `gems/nil-kill/lib/nil_kill/loop.rb:492` (nilable_param_fallback) -- 4 condition atoms in `original.empty? || name.empty? || original.start_with?("T.nilable(") || original == "T.untyped"`
  - atoms: `original.empty? | name.empty? | original.start_with?("T.nilable(") | original == "T.untyped"`
- *POSSIBLE* `gems/nil-kill/lib/nil_kill/report.rb:761` (return_unresolved_dependencies) -- 4 condition atoms in `blocker.include?("untyped callee") || blocker.include?("unknown return") || blocker.include?("safe navigation") || blocker.include?("setter assignment")`
  - atoms: `blocker.include?("untyped callee") | blocker.include?("unknown return") | blocker.include?("safe navigation") | blocker.include?("setter assignment")`
- *POSSIBLE* `gems/nil-kill/lib/nil_kill/report.rb:3574` (finalize_hash_record_struct_candidate) -- 4 condition atoms in `optional.include?(field) && type != "T.untyped" && type != "NilClass" && !type.start_with?("T.nilable(")`
  - atoms: `optional.include?(field) | type != "T.untyped" | type != "NilClass" | !type.start_with?("T.nilable(")`
- ...(+10 more)

## Broken Protocols (662)
_co-called pair, one site does A without B -- *POSSIBLE* bug (noisy)_

- *POSSIBLE* conf=0.98 support=44 `src/ast/parser.rb:1814` (parse_binary_op) does `parse_expression` without `consume`
- *POSSIBLE* conf=0.97 support=37 `src/lsp/server.rb:231` (handle_did_close) does `close` without `new`
- *POSSIBLE* conf=0.97 support=37 `src/lsp/server.rb:231` (handle_did_close) does `close` without `write`
- *POSSIBLE* conf=0.97 support=34 `src/mir/mir_lowering.rb:3527` (bare_zig_type) does `transpile_type` without `new`
- *POSSIBLE* conf=0.96 support=43 `src/ast/parser.rb:527` (run_action) does `parse_expression` without `new`
- *POSSIBLE* conf=0.96 support=43 `src/ast/parser.rb:720` (parse_statement) does `parse_expression` without `new`
- *POSSIBLE* conf=0.96 support=23 `gems/nil-kill/lib/nil_kill/cli.rb:258` (collect_commands) does `glob` without `join`
- *POSSIBLE* conf=0.95 support=35 `src/ast/parser.rb:547` (match_literal!) does `match!` without `consume`
- *POSSIBLE* conf=0.95 support=35 `src/ast/parser.rb:3549` (parse_error_selectors) does `match!` without `consume`
- *POSSIBLE* conf=0.95 support=35 `gems/decomplex/test/state_mesh_test.rb:192` (test_metrics_computed) does `refute_nil` without `[]`
- *POSSIBLE* conf=0.95 support=35 `gems/decomplex/test/state_mesh_test.rb:211` (test_multiple_fields_ranked) does `refute_nil` without `[]`
- *POSSIBLE* conf=0.95 support=21 `src/annotator/helpers/intrinsic_emit.rb:22` ((top-level)) does `prop` without `returns`
- *POSSIBLE* conf=0.95 support=20 `gems/decomplex/lib/decomplex/weighted_inlined_cognitive_complexity.rb:173` (score) does `round` without `[]`
- *POSSIBLE* conf=0.94 support=58 `src/ast/lexer.rb:278` (extract_balanced_brace_content) does `-` without `[]`
- *POSSIBLE* conf=0.94 support=58 `src/ast/parser.rb:2503` (peek_generic_angle_params?) does `-` without `[]`
- *POSSIBLE* conf=0.94 support=58 `src/tools/formatter.rb:228` (consume_string) does `-` without `[]`
- *POSSIBLE* conf=0.94 support=58 `src/tools/formatter.rb:2567` (split_indent_markers) does `-` without `[]`
- *POSSIBLE* conf=0.94 support=17 `src/mir/lowering/variables.rb:155` (lower_var_decl) does `with_decl_alloc` without `lower`
- *POSSIBLE* conf=0.94 support=17 `src/mir/lowering/variables.rb:1331` (auto_lock_assignment_value) does `with_decl_alloc` without `new`
- *POSSIBLE* conf=0.93 support=27 `src/mir/lowering/control_flow.rb:118` (lower_control_condition) does `hoist_alloc` without `new`
- *POSSIBLE* conf=0.93 support=27 `src/mir/lowering/variables.rb:1336` (auto_lock_assignment_value) does `hoist_alloc` without `new`
- *POSSIBLE* conf=0.93 support=14 `src/mir/lower/pipeline/pipeline_context.rb:276` (substitute_assignment_target) does `substitute` without `new`
- *POSSIBLE* conf=0.93 support=13 `src/semantic/escape_analysis.rb:787` (assignment_value_is_owned?) does `unwrap_value` without `is_a?`
- *POSSIBLE* conf=0.93 support=13 `gems/nil-kill/spec/support/mini_collect.rb:19` (in_tmp) does `mktmpdir` without `join`
- *POSSIBLE* conf=0.92 support=71 `src/ast/async_result_shape.rb:8` ((top-level)) does `const` without `[]`
- ...(+637 more)

## Implicit Control Flow (109)
_state-dependent internal call order exists -- hidden lifecycle/control-flow pressure_

- *POSSIBLE* [protocol_pressure] support=31 `with_new_scope -> current_scope` (write_read state=`scope_stack`) -- `src/annotator/domains/control_flow.rb:41` (analyze_control_flow_branches)
  - sites: `src/annotator/domains/control_flow.rb:41` (analyze_control_flow_branches) ; `src/annotator/domains/control_flow.rb:95` (visit_BlockExpr) ; `src/annotator/domains/execution_boundaries.rb:12` (visit_WithBlock) ; `src/annotator/helpers/capabilities.rb:608` (visit_post_clauses!) (+27 more)
- *POSSIBLE* [protocol_pressure] support=20 `current -> consume` (read_write state=`pos`) -- `src/ast/parser.rb:793` (parse_tight_stmt)
  - sites: `src/ast/parser.rb:793` (parse_tight_stmt) ; `src/ast/parser.rb:862` (parse_argument_list) ; `src/ast/parser.rb:1167` (parse_union_def) ; `src/ast/parser.rb:1269` (parse_function_def) (+16 more)
- *POSSIBLE* [protocol_pressure] support=9 `consume -> current` (write_read state=`pos`) -- `src/ast/parser.rb:1269` (parse_function_def)
  - sites: `src/ast/parser.rb:1269` (parse_function_def) ; `src/ast/parser.rb:1652` (parse_effects_decl) ; `src/ast/parser.rb:1916` (parse_unary) ; `src/ast/parser.rb:2290` (parse_struct_pattern) (+5 more)
- *POSSIBLE* [protocol_pressure] support=6 `consume_number -> consume` (read_write|write_read|write_write state=`pos`) -- `src/ast/parser.rb:1652` (parse_effects_decl)
  - sites: `src/ast/parser.rb:1652` (parse_effects_decl) ; `src/ast/parser.rb:1916` (parse_unary) ; `src/ast/parser.rb:2732` (parse_type_annotation) ; `src/ast/parser.rb:3143` (apply_capability!) (+2 more)
- *POSSIBLE* [protocol_pressure] support=3 `consume -> consume_number` (read_write|write_read|write_write state=`pos`) -- `src/ast/parser.rb:3143` (apply_capability!)
  - sites: `src/ast/parser.rb:3143` (apply_capability!) ; `src/ast/parser.rb:3530` (match_optional_retry!) ; `src/ast/parser.rb:3647` (parse_lock_rank_arg!)
- *POSSIBLE* [protocol_pressure] support=3 `with_context_state -> current_context` (write_read state=`pipeline_context`) -- `src/mir/lower/pipeline/pipeline_host.rb:436` (with_pipeline_context)
  - sites: `src/mir/lower/pipeline/pipeline_host.rb:436` (with_pipeline_context) ; `src/mir/lower/pipeline/pipeline_host.rb:445` (with_soa_rewrite) ; `src/mir/lower/pipeline/pipeline_host.rb:495` (with_named_binding)
- *POSSIBLE* [protocol_pressure] support=3 `peek -> consume` (read_write state=`pos`) -- `src/ast/parser.rb:1759` (parse_expression)
  - sites: `src/ast/parser.rb:1759` (parse_expression) ; `src/ast/parser.rb:2642` (parse_window_op) ; `src/ast/parser.rb:2699` (parse_fn_type_annotation)
- *POSSIBLE* [protocol_pressure] support=2 `apply_capabilities! -> ownership` (write_read state=`capabilities`) -- `src/ast/type.rb:1231` (apply_symbol_overlay!)
  - sites: `src/ast/type.rb:1231` (apply_symbol_overlay!) ; `src/ast/type.rb:1241` (apply_bg_capture_symbol!)
- *POSSIBLE* [protocol_pressure] support=2 `apply_capabilities! -> sync` (write_read state=`capabilities`) -- `src/ast/type.rb:1266` (copy_declared_collection_modifiers_from!)
  - sites: `src/ast/type.rb:1266` (copy_declared_collection_modifiers_from!) ; `src/ast/type.rb:1322` (merge_capabilities_from!)
- *POSSIBLE* [protocol_pressure] support=2 `collect_method_edits -> write_tracepoint_fallback_plan` (write_read state=`tracepoint_methods`) -- `gems/nil-kill/lib/nil_kill/source_instrumenter.rb:75` (instrument_file_with_map)
  - sites: `gems/nil-kill/lib/nil_kill/source_instrumenter.rb:75` (instrument_file_with_map) ; `gems/nil-kill/lib/nil_kill/source_instrumenter.rb:113` (instrument_file)
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
- *POSSIBLE* [protocol_pressure] support=2 `provenance -> apply_placement!` (read_write state=`placement`) -- `src/ast/type.rb:1112` (copy_placement_from!)
  - sites: `src/ast/type.rb:1112` (copy_placement_from!) ; `src/ast/type.rb:1119` (apply_cleanup_placement!)
- *POSSIBLE* [protocol_pressure] support=2 `test_hook_match? -> consume` (read_write state=`pos`) -- `src/ast/parser.rb:3993` (parse_test_block)
  - sites: `src/ast/parser.rb:3993` (parse_test_block) ; `src/ast/parser.rb:4067` (parse_when_block)
- *POSSIBLE* [protocol_pressure] support=1 `add_struct_decl -> add_struct_static` (read_write|write_read|write_write state=`struct_fields`) -- `gems/nil-kill/lib/nil_kill/trace_plan.rb:16` (write)
  - sites: `gems/nil-kill/lib/nil_kill/trace_plan.rb:16` (write)
- *POSSIBLE* [protocol_pressure] support=1 `analyze_return_origin -> scoped_facts` (read_write|write_read|write_write state=`current_array_element_shapes | current_collection_builders | current_hash_shapes | current_local_types | current_method_name | current_param_types`) -- `gems/nil-kill/lib/nil_kill/source_index.rb:272` (walk)
  - sites: `gems/nil-kill/lib/nil_kill/source_index.rb:272` (walk)
- *POSSIBLE* [protocol_pressure] support=1 `apply_capabilities! -> collection` (write_read state=`capabilities`) -- `src/ast/type.rb:1249` (copy_collection_shape_from!)
  - sites: `src/ast/type.rb:1249` (copy_collection_shape_from!)
- *POSSIBLE* [protocol_pressure] support=1 `apply_capabilities! -> shard_count` (write_read state=`capabilities`) -- `src/ast/type.rb:1258` (copy_topology_from!)
  - sites: `src/ast/type.rb:1258` (copy_topology_from!)
- *POSSIBLE* [protocol_pressure] support=1 `check_linear_expr_uses! -> linear_merge_branch_states!` (read_write|write_read|write_write state=`errors`) -- `src/mir/mir_checker.rb:575` (check_linear_stmt!)
  - sites: `src/mir/mir_checker.rb:575` (check_linear_stmt!)
- *POSSIBLE* [protocol_pressure] support=1 `check_linear_expr_uses! -> linear_require_same_state!` (read_write|write_read|write_write state=`errors`) -- `src/mir/mir_checker.rb:575` (check_linear_stmt!)
  - sites: `src/mir/mir_checker.rb:575` (check_linear_stmt!)
- *POSSIBLE* [protocol_pressure] support=1 `check_reassign_cleanup_alloc! -> check_aggregate_expr!` (read_write|write_read|write_write state=`errors`) -- `src/mir/mir_checker.rb:1127` (check_aggregate_stmts!)
  - sites: `src/mir/mir_checker.rb:1127` (check_aggregate_stmts!)
- *POSSIBLE* [protocol_pressure] support=1 `clear_synthetic_function_definitions! -> synthetic_function_definitions` (write_read state=`semantic_function_registry`) -- `src/annotator/phases/signature_registration.rb:16` (register_program_signatures)
  - sites: `src/annotator/phases/signature_registration.rb:16` (register_program_signatures)
- ...(+84 more)

## Weighted Inlined Cognitive Complexity (1055)
_same-owner helper chain hides cognitive load behind a low-looking orchestration method_

- *POSSIBLE* `gems/nil-kill/lib/nil_kill/report.rb:15` (run) -- inlined=550.0 (local=10.0, hidden=540.0, depth=2)
  - chain: `run -> append_return_origin_report`
  - single-caller helpers: `append_action_sections | append_callsite_pressure | append_collection_report | append_foreign_class_pressure | append_hygiene_overview | append_hygiene_overview_summary | append_param_origin_report | append_project_prioritization`
  - reason: 16 single-caller helper(s) add 540.0 weighted cognitive points
- *POSSIBLE* `src/tools/doctor.rb:37` (run) -- inlined=536.2 (local=6.0, hidden=530.2, depth=2)
  - chain: `run -> section_locks`
  - single-caller helpers: `run_diff | run_peek | section_atomic_escape | section_channels | section_cpu | section_fibers | section_freeze | section_hardware`
  - reason: 11 single-caller helper(s) add 530.2 weighted cognitive points
- *POSSIBLE* `gems/nil-kill/lib/nil_kill/infer.rb:170` (build_actions) -- inlined=551.7 (local=23.0, hidden=528.7, depth=2)
  - chain: `build_actions -> enrich_return_origins_with_callee_propagation!`
  - single-caller helpers: `enrich_return_origins_with_callee_propagation! | enrich_return_origins_with_receiver_inference! | propose_dispatcher_inference_actions | propose_forwarded_return_chain_actions | propose_hash_record_cluster_actions | propose_hash_record_struct_actions | propose_sig | propose_static_param_backflow_actions`
  - reason: 15 single-caller helper(s) add 528.7 weighted cognitive points
- *POSSIBLE* `src/mir/mir_checker.rb:356` (check_fn!) -- inlined=473.2 (local=27.0, hidden=446.2, depth=2)
  - chain: `check_fn! -> verify_ownership_surfaces_finalized!`
  - single-caller helpers: `allocator_metadata_node? | scan_expr_for_hpt_leak! | verify_aggregate_owned_children! | verify_alloc_cleanup_match! | verify_alloc_marks_typed! | verify_allocating_lets_marked! | verify_allocator_closed_set! | verify_allocator_metadata_contracts!`
  - reason: 26 single-caller helper(s) add 446.2 weighted cognitive points
- *POSSIBLE* `src/tools/formatter.rb:321` (emit) -- inlined=393.6 (local=1.0, hidden=392.6, depth=2)
  - chain: `emit -> expand_method_chains`
  - single-caller helpers: `canonicalize_numerics | collapse_newlines | expand_bg_do_blocks | expand_call_args | expand_concurrent_drops | expand_fn_blocks | expand_method_chains | expand_pipelines`
  - reason: 12 single-caller helper(s) add 392.6 weighted cognitive points
- *POSSIBLE* `gems/nil-kill/lib/nil_kill/infer.rb:11` (run) -- inlined=300.4 (local=2.0, hidden=298.4, depth=2)
  - chain: `run -> load_runtime`
  - single-caller helpers: `build_actions | build_flow_graph | index_sources | load_runtime | load_sorbet | sorbet_validate_high_actions!`
  - reason: 6 single-caller helper(s) add 298.4 weighted cognitive points
- *POSSIBLE* `src/annotator/helpers/pipe_analysis.rb:212` (analyze_higher_order_op) -- inlined=280.1 (local=3.5, hidden=276.6, depth=2)
  - chain: `analyze_higher_order_op -> analyze_concurrent_op`
  - single-caller helpers: `analyze_all_op | analyze_any_op | analyze_batch_window_op | analyze_collect_op | analyze_concurrent_op | analyze_distinct_op | analyze_find_op | analyze_join_op`
  - reason: 17 single-caller helper(s) add 276.6 weighted cognitive points
- *POSSIBLE* `gems/nil-kill/lib/nil_kill/report.rb:1240` (append_hygiene_overview) -- inlined=274.9 (local=0.0, hidden=274.9, depth=2)
  - chain: `append_hygiene_overview -> append_untyped_evidence_gaps -> untyped_evidence_gaps`
  - single-caller helpers: `append_deterministic_guard_collapse | append_node_alias_candidates | append_return_hygiene_report | append_signature_slot_evidence | append_union_decomplexity | append_untyped_evidence_gaps`
  - reason: 6 single-caller helper(s) add 274.9 weighted cognitive points
- *POSSIBLE* `gems/nil-kill/lib/nil_kill/runtime_trace.rb:1309` (self.install_collection_hook) -- inlined=218.6 (local=0.0, hidden=218.6, depth=1)
  - chain: `self.install_collection_hook -> self.install_hash_hook`
  - single-caller helpers: `self.install_array_hook | self.install_hash_hook | self.install_set_hook`
  - reason: 3 single-caller helper(s) add 218.6 weighted cognitive points
- *POSSIBLE* `src/mir/mir_emitter.rb:53` (emit) -- inlined=216.5 (local=1.5, hidden=215.0, depth=2)
  - chain: `emit -> emit_extern_trampoline`
  - single-caller helpers: `emit_alloc_slice | emit_allocator_ref | emit_array_default_init | emit_array_init | emit_assert_raises_check | emit_assert_stmt | emit_batch_window_flush | emit_batch_window_push`
  - reason: 106 single-caller helper(s) add 215.0 weighted cognitive points
- *POSSIBLE* `gems/nil-kill/lib/nil_kill/source_index.rb:272` (walk) -- inlined=237.9 (local=24.5, hidden=213.4, depth=2)
  - chain: `walk -> inspect_param_origins`
  - single-caller helpers: `inspect_array_literal | inspect_attribute_shape_write | inspect_branch_guard | inspect_call | inspect_class_constructor_fields | inspect_dispatcher | inspect_hash_literal | inspect_param_origins`
  - reason: 12 single-caller helper(s) add 213.4 weighted cognitive points
- *POSSIBLE* `src/mir/mir_checker.rb:1233` (check_program!) -- inlined=227.8 (local=16.3, hidden=211.5, depth=2)
  - chain: `check_program! -> ownership_registry_errors`
  - single-caller helpers: `check_fn! | ownership_registry_errors`
  - reason: 2 single-caller helper(s) add 211.5 weighted cognitive points
- *POSSIBLE* `src/mir/lowering/variables.rb:147` (lower_var_decl) -- inlined=208.7 (local=6.0, hidden=202.7, depth=2)
  - chain: `lower_var_decl -> lower_var_decl_init`
  - single-caller helpers: `ensure_cleanup_binding_owns_string_init | field_owner_move_marks | lower_var_decl_init | stamp_var_decl_init_target! | var_decl_facts | var_decl_materialization_plan | var_decl_safe_name | var_decl_source_transfer_required?`
  - reason: 9 single-caller helper(s) add 202.7 weighted cognitive points
- *POSSIBLE* `gems/nil-kill/lib/nil_kill/loop.rb:58` (run) -- inlined=265.6 (local=65.3, hidden=200.3, depth=2)
  - chain: `run -> levenshtein_actions`
  - single-caller helpers: `apply_verified | emit_z3_inferred_actions | hash_record_review_actions | init_z3_solver | levenshtein_actions | narrow_generic_review_actions | narrow_tlet_review_actions | return_backflow_review_actions`
  - reason: 10 single-caller helper(s) add 200.3 weighted cognitive points
- *POSSIBLE* `gems/nil-kill/lib/nil_kill/runtime_trace.rb:169` (self.install_targeted_method_traces) -- inlined=232.4 (local=37.0, hidden=195.4, depth=2)
  - chain: `self.install_targeted_method_traces -> self.record_call`
  - single-caller helpers: `self.record_call | self.record_return`
  - reason: 2 single-caller helper(s) add 195.4 weighted cognitive points
- *POSSIBLE* `gems/nil-kill/lib/nil_kill/infer.rb:475` (propose_hash_record_cluster_actions) -- inlined=182.4 (local=12.8, hidden=169.6, depth=2)
  - chain: `propose_hash_record_cluster_actions -> hash_record_expand_row_from_return_origins`
  - single-caller helpers: `hash_record_cluster_blockers | hash_record_cluster_signatures | hash_record_expand_row_from_return_origins`
  - reason: 3 single-caller helper(s) add 169.6 weighted cognitive points
- *POSSIBLE* `gems/nil-kill/lib/nil_kill/runtime_trace.rb:191` (self.install_targeted_definition_trace) -- inlined=154.3 (local=1.0, hidden=153.3, depth=2)
  - chain: `self.install_targeted_definition_trace -> self.install_targeted_method_traces -> self.record_call`
  - single-caller helpers: `self.install_targeted_method_traces`
  - reason: 1 single-caller helper(s) add 153.3 weighted cognitive points
- *POSSIBLE* `src/tools/method_rewriter.rb:168` (compute_edit) -- inlined=162.5 (local=15.8, hidden=146.7, depth=1)
  - chain: `compute_edit -> match_paren`
  - single-caller helpers: `match_paren | needs_parens? | next_non_ws | offset_for | split_args_by_comma`
  - reason: 5 single-caller helper(s) add 146.7 weighted cognitive points
- *POSSIBLE* `gems/nil-kill/lib/nil_kill/report.rb:3229` (append_collection_report) -- inlined=146.2 (local=0.0, hidden=146.2, depth=2)
  - chain: `append_collection_report -> append_hash_record_struct_candidates`
  - single-caller helpers: `append_collection_blocker_pressure | append_collection_index_lookup_report | append_collection_slot_candidates | append_collection_slot_coverage | append_hash_record_struct_candidates | append_runtime_collection_observations | collection_signature_slots`
  - reason: 7 single-caller helper(s) add 146.2 weighted cognitive points
- *POSSIBLE* `gems/nil-kill/lib/nil_kill/infer.rb:242` (propose_hash_record_struct_actions) -- inlined=162.6 (local=25.0, hidden=137.6, depth=2)
  - chain: `propose_hash_record_struct_actions -> propose_return_hash_record_struct_actions`
  - single-caller helpers: `hash_record_local_param_signatures | hash_record_param_read_rewrites | hash_record_param_signature_blockers | hash_record_struct_fields | propose_return_hash_record_struct_actions`
  - reason: 5 single-caller helper(s) add 137.6 weighted cognitive points
- *POSSIBLE* `gems/nil-kill/lib/nil_kill/source_index.rb:976` (analyze_return_origin) -- inlined=150.9 (local=15.5, hidden=135.4, depth=2)
  - chain: `analyze_return_origin -> return_sources_for`
  - single-caller helpers: `array_element_shape_for_return_expressions | explicit_return_expressions | hash_shape_for_return_expressions | return_control_shape | return_sources_for | return_syntax`
  - reason: 6 single-caller helper(s) add 135.4 weighted cognitive points
- *POSSIBLE* `src/mir/fsm_transform/emit.rb:687` (build_recursive) -- inlined=243.2 (local=108.5, hidden=134.7, depth=2)
  - chain: `build_recursive -> build_fsm_unified`
  - single-caller helpers: `build_fsm_unified | build_segment_descriptor | check_fsm_cleanup_invariant! | compute_sp_indices | expand_lock_segment | fsm_destroy_finalizer_name | fsm_owned_result_guards | lift_ctx_cleanups_to_destroy!`
  - reason: 11 single-caller helper(s) add 134.7 weighted cognitive points
- *POSSIBLE* `src/ast/parser.rb:991` (parse_visibility_decl) -- inlined=148.6 (local=15.0, hidden=133.6, depth=2)
  - chain: `parse_visibility_decl -> parse_function_def`
  - single-caller helpers: `parse_enum_def | parse_function_def | parse_struct_def | parse_union_def`
  - reason: 4 single-caller helper(s) add 133.6 weighted cognitive points
- *POSSIBLE* `src/annotator/helpers/function_analysis.rb:89` (analyze_routine) -- inlined=153.6 (local=21.3, hidden=132.3, depth=1)
  - chain: `analyze_routine -> declare_and_verify_params`
  - single-caller helpers: `declare_and_verify_params | declare_captures | verify_captures! | verify_returns`
  - reason: 4 single-caller helper(s) add 132.3 weighted cognitive points
- *POSSIBLE* `gems/nil-kill/lib/nil_kill/report.rb:521` (append_return_origin_report) -- inlined=168.4 (local=36.3, hidden=132.1, depth=2)
  - chain: `append_return_origin_report -> return_cascade_pressure`
  - single-caller helpers: `forwarded_return_blocker_pressure | return_cascade_pressure | return_root_pressure | untyped_return_origins`
  - reason: 4 single-caller helper(s) add 132.1 weighted cognitive points
- ...(+1030 more)

## False Simplicity (1181)
_looks simple, behaves non-locally: hidden dispatch/mutation/IO/context/metaprogramming/monkeypatch -- *POSSIBLE* (noisy)_

- *POSSIBLE* [hidden_mutation] scatter=845 support=2369 `<<` -- `src/annotator/annotator.rb:240` (push_function_context!) (+2361 more)
- *POSSIBLE* [hidden_mutation] scatter=499 support=1028 `[]=` -- `src/annotator/annotator.rb:667` (emit_auto_shape_resolved_findings!) (+1023 more)
- *POSSIBLE* [hidden_mutation] scatter=274 support=378 `full_type!` -- `src/annotator/annotator.rb:262` (stamp_type!) (+375 more)
- *POSSIBLE* [hidden_mutation] scatter=241 support=401 `error!` -- `src/annotator/annotator.rb:507` (with_snapshot_transaction_body) (+400 more)
- *POSSIBLE* [hidden_mutation] scatter=204 support=371 `op-assign` -- `src/annotator/annotator.rb:295` (with_conditional_context) (+366 more)
- *POSSIBLE* [hidden_mutation] scatter=137 support=212 `stamp_type!` -- `src/annotator/domains/control_flow.rb:101` (visit_BlockExpr) (+211 more)
- *POSSIBLE* [hidden_io] scatter=118 support=390 `File.join` -- `src/backends/importer.rb:65` (resolve_stdlib_package) (+387 more)
- *POSSIBLE* [hidden_mutation] scatter=91 support=98 `from_node!` -- `src/annotator/domains/lifetimes.rb:147` (visit_CopyNode) (+97 more)
- *POSSIBLE* [hidden_io] scatter=67 support=104 `File.expand_path` -- `src/annotator/annotator.rb:525` (initialize) (+103 more)
- *POSSIBLE* [hidden_mutation] scatter=66 support=94 `storage=` -- `src/annotator/domains/control_flow.rb:102` (visit_BlockExpr) (+93 more)
- *POSSIBLE* [metaprogramming] scatter=56 support=140 `instance_variable_set` -- `src/annotator/domains/member_access.rb:401` (visit_StructLit) (+139 more)
- *POSSIBLE* [dynamic_dispatch] scatter=55 support=62 `yield` -- `src/annotator/helpers/auto_inference.rb:745` (walk_for_shape_decls) (+61 more)
- *POSSIBLE* [hidden_io] scatter=53 support=60 `File.exist?` -- `src/ast/diagnostic_examples.rb:77` (load!) (+59 more)
- *POSSIBLE* [hidden_io] scatter=52 support=99 `File.read` -- `src/backends/importer.rb:100` (compile_file) (+98 more)
- *POSSIBLE* [hidden_io] scatter=51 support=199 `File.write` -- `src/tools/clear_build_support.rb:48` (write_if_changed) (+198 more)
- *POSSIBLE* [dynamic_dispatch] scatter=51 support=120 `instance_variable_get` -- `src/annotator/domains/errors.rb:688` (coerce_empty_collection_fallback!) (+119 more)
- *POSSIBLE* [hidden_mutation] scatter=48 support=50 `fixable!` -- `src/annotator/domains/lifetimes.rb:691` (verify_tied_assignment!) (+49 more)
- *POSSIBLE* [dynamic_dispatch] scatter=44 support=45 `blk.call` -- `src/annotator/annotator.rb:297` (with_conditional_context) (+44 more)
- *POSSIBLE* [hidden_io] scatter=43 support=59 `File.readlines` -- `src/ast/diagnostic_examples.rb:87` (scan_file) (+58 more)
- *POSSIBLE* [hidden_io] scatter=40 support=319 `puts` -- `src/backends/transpiler.rb:322` ((top-level)) (+318 more)
- *POSSIBLE* [hidden_mutation] scatter=37 support=89 `match!` -- `src/ast/parser.rb:187` ((top-level)) (+88 more)
- *POSSIBLE* [hidden_io] scatter=37 support=39 `Tempfile.new` -- `gems/boobytrap/test/coverage_gap_test.rb:10` (with_resultset) (+38 more)
- *POSSIBLE* [dynamic_dispatch] scatter=36 support=248 `send` -- `src/annotator/annotator.rb:686` (visit) (+247 more)
- *POSSIBLE* [hidden_mutation] scatter=36 support=36 `apply_capabilities!` -- `src/ast/type.rb:770` (initialize) (+35 more)
- *POSSIBLE* [hidden_io] scatter=34 support=61 `FileUtils.mkdir_p` -- `src/tools/clear_build_support.rb:45` (write_if_changed) (+60 more)
- ...(+1156 more)

## Fat Unions (14)
_case dispatch over class consts whose arms read mostly variant-invariant members -- product-vs-sum decomposition candidate (extraction -> nil-kill) -- *POSSIBLE*_

- *POSSIBLE* [DEGENERATE: no variance] union `AST::Assignment | AST::BindExpr | AST::VarDecl` -- **3 common** vs 0 variant member(s), scatter=3 -- `src/mir/fsm_transform/liveness.rb:209` (collect_defs)
  - common: `is_a?, name, value` -> hoist to a struct, keep a SMALL union for `` (-> nil-kill)
- *POSSIBLE* [DEGENERATE: no variance] union `MIR::IndexedStore | MIR::RegistryCall | MIR::ShardedMapPut` -- **8 common** vs 0 variant member(s), scatter=1 -- `src/mir/mir_checker.rb:2558` (ownership_node_name)
  - common: `callee, class, expr, is_a?, method, reason, spec, target_var` -> hoist to a struct, keep a SMALL union for `` (-> nil-kill)
- *POSSIBLE* [DEGENERATE: no variance] union `MIR::FsmTailDone | MIR::FsmTailJump | MIR::FsmTailLockTry | MIR::FsmTailRetryOrError | MIR::FsmTailWokenCheck` -- **7 common** vs 0 variant member(s), scatter=1 -- `src/mir/fsm_transform/emit.rb:619` (build_dispatch_tail)
  - common: `class, cond_ast, else_index, next_index, respond_to?, target_index, then_index` -> hoist to a struct, keep a SMALL union for `` (-> nil-kill)
- *POSSIBLE* [DEGENERATE: no variance] union `MIR::OwnedBorrow | MIR::OwnedCreate | MIR::OwnedDestroy | MIR::OwnedReturn | MIR::OwnedStore | MIR::OwnedTransfer` -- **2 common** vs 0 variant member(s), scatter=2 -- `src/mir/mir_checker.rb:2483` (ownership_fact_source)
  - common: `name, source` -> hoist to a struct, keep a SMALL union for `` (-> nil-kill)
- *POSSIBLE* [DEGENERATE: no variance] union `Prism::ClassVariableWriteNode | Prism::GlobalVariableWriteNode | Prism::InstanceVariableWriteNode` -- **4 common** vs 0 variant member(s), scatter=1 -- `gems/nil-kill/lib/nil_kill/source_instrumenter.rb:254` (collect_ivar_assignment_edits)
  - common: `child_nodes, name, respond_to?, value` -> hoist to a struct, keep a SMALL union for `` (-> nil-kill)
- *POSSIBLE* [DEGENERATE: no variance] union `Prism::BeginNode | Prism::ElseNode | Prism::NilNode | Prism::ParenthesesNode | Prism::StatementsNode` -- **3 common** vs 0 variant member(s), scatter=1 -- `gems/nil-kill/lib/nil_kill/source_index.rb:1236` (nil_return_expression?)
  - common: `=, arguments, respond_to?` -> hoist to a struct, keep a SMALL union for `` (-> nil-kill)
- *POSSIBLE* [DEGENERATE: no variance] union `AST::IndexOp | AST::OrderByOp | AST::SelectOp | AST::WhereOp` -- **2 common** vs 0 variant member(s), scatter=1 -- `src/annotator/helpers/pipe_analysis.rb:335` (analyze_select_family_op)
  - common: `expression, is_a?` -> hoist to a struct, keep a SMALL union for `` (-> nil-kill)
- *POSSIBLE* [DEGENERATE: no variance] union `MIR::AllocSlice | MIR::CapWrap | MIR::ConcatStr | MIR::ContainerInit | MIR::DeepCopy | MIR::DupeSlice | MIR::HeapCreate | MIR::MakeList` -- **2 common** vs 0 variant member(s), scatter=1 -- `src/mir/mir_checker.rb:2686` (expr_has_frame_alloc?)
  - common: `alloc, respond_to?` -> hoist to a struct, keep a SMALL union for `` (-> nil-kill)
- *POSSIBLE* [DEGENERATE: no variance] union `AST::GetField | AST::GetIndex | AST::OptionalUnwrap | AST::Slice` -- **2 common** vs 0 variant member(s), scatter=1 -- `src/mir/mir_lowering.rb:2655` (root_receiver_node)
  - common: `is_a?, target` -> hoist to a struct, keep a SMALL union for `` (-> nil-kill)
- *POSSIBLE* [DEGENERATE: no variance] union `Prism::ClassVariableWriteNode | Prism::GlobalVariableWriteNode | Prism::InstanceVariableWriteNode | Prism::LocalVariableWriteNode` -- **2 common** vs 0 variant member(s), scatter=1 -- `gems/nil-kill/lib/nil_kill/source_index.rb:441` (collect_local_container_origins)
  - common: `compact_child_nodes, respond_to?` -> hoist to a struct, keep a SMALL union for `` (-> nil-kill)
- *POSSIBLE* [DEGENERATE: no variance] union `Prism::ClassNode | Prism::ConstantWriteNode | Prism::DefNode | Prism::InstanceVariableWriteNode | Prism::ModuleNode` -- **2 common** vs 0 variant member(s), scatter=1 -- `gems/nil-kill/lib/nil_kill/source_index.rb:497` (collect_prescan)
  - common: `compact_child_nodes, respond_to?` -> hoist to a struct, keep a SMALL union for `` (-> nil-kill)
- *POSSIBLE* union `MIR::AllocMark | MIR::BreakStmt | MIR::Cleanup | MIR::ErrCleanup | MIR::FieldCleanupMark | MIR::MoveMark | MIR::OwnedBorrow | MIR::OwnedCreate | MIR::OwnedDestroy | MIR::OwnedReturn | MIR::OwnedStore | MIR::OwnedTransfer | MIR::Panic | MIR::ReassignMark | MIR::ReturnMark | MIR::ReturnStmt | MIR::TransferMark` -- **19 common** vs 3 variant member(s), scatter=1 -- `src/mir/mir_checker.rb:587` (check_linear_stmt!)
  - common: `arms, bindings, body, branch_bodies, branches, class, clause_bodies, cond` -> hoist to a struct, keep a SMALL union for `cleanup_entry, target, target_alloc` (-> nil-kill)
- *POSSIBLE* union `AST::EnumDef | AST::StructDef | AST::UnionDef` -- **4 common** vs 2 variant member(s), scatter=3 -- `src/backends/compiler_frontend.rb:93` (compile)
  - common: `is_a?, name, variants, visibility` -> hoist to a struct, keep a SMALL union for `field_decls, type_params` (-> nil-kill)
- *POSSIBLE* union `Prism::ClassNode | Prism::DefNode | Prism::LambdaNode | Prism::ModuleNode | Prism::ReturnNode` -- **5 common** vs 2 variant member(s), scatter=1 -- `gems/nil-kill/lib/nil_kill/source_instrumenter.rb:207` (collect_return_edits)
  - common: `block, child_nodes, is_a?, name, respond_to?` -> hoist to a struct, keep a SMALL union for `arguments, location` (-> nil-kill)

## Run Summary
- Files analyzed: 293
- Detectors: 21 (all shipped, self-tested)
- Convergence: 2726 unit(s) flagged by >=2 independent detectors
- Root-cause clusters: 620 (one fix collapses each)
- Total candidates: 9390
- Method: stdlib AST only, intra-procedural, zero deps, no CFG / no points-to; Flay similarity is an optional external signal consumed read-only (see docs/agents/design.md)
