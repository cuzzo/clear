# Decomplex Report

> Decision-level duplication and neglected-condition analysis.
> Every entry is a ranked **candidate** (Engler's discipline),
> never a verdict -- *POSSIBLE* findings, triaged by a human.
> Sections are ordered by SIGNAL TIER (1 = lowest false
> positive), not by volume. Items within a section are
> frequency-ranked. Triage tier 1, top-of-list, first.

## Table of Contents
- [Project Prioritization](#project-prioritization)
- [Cross-Detector Convergence (1366)](#cross-detector-convergence-1366)
- [Root-Cause Clusters (330)](#root-cause-clusters-330)
- [Decision Pressure (297)](#decision-pressure-297)
- [Missing Abstractions (190)](#missing-abstractions-190)
- [Reification Misses (24)](#reification-misses-24)
- [Semantic Predicate Aliases (3)](#semantic-predicate-aliases-3)
- [Exact Predicate Aliases (7)](#exact-predicate-aliases-7)
- [Inconsistent Rename Clones (71)](#inconsistent-rename-clones-71)
- [Flay Similarity (Type-2/3) (47)](#flay-similarity-type23-47)
- [Neglected Updates (1988)](#neglected-updates-1988)
- [Derived-State Staleness (149)](#derivedstate-staleness-149)
- [Neglected Conditions (10)](#neglected-conditions-10)
- [Neglected Path Conditions (1858)](#neglected-path-conditions-1858)
- [Broken Protocols (1461)](#broken-protocols-1461)
- [False Simplicity (754)](#false-simplicity-754)
- [Fat Unions (8)](#fat-unions-8)
- [Run Summary](#run-summary)

## Project Prioritization
_Ordered by signal tier (1 = highest signal / lowest FP), then by volume._

- **[tier 1]** [Decision Pressure (297)](#decision-pressure-297): ELIMINABLE guard-pressure per loose contract (nil/is_a?/respond_to?/safe-nav/rescue-nil) -> tighten the contract once / nil-kill: DELETE. essential dispatch + pure c-uses are split out, NEVER summed (Rapps-Weyuker p-use; McCabe)
- **[tier 1]** [Missing Abstractions (190)](#missing-abstractions-190): guard tuple recomputed across >=2 decision units
- **[tier 1]** [Reification Misses (24)](#reification-misses-24): an existing predicate reinvented inline -- invariant #16
- **[tier 1]** [Exact Predicate Aliases (7)](#exact-predicate-aliases-7): identical one-line predicate body under >=2 names
- **[tier 1]** [Semantic Predicate Aliases (3)](#semantic-predicate-aliases-3): one decision, multiple names (receiver/polarity folded)
- **[tier 2]** [Neglected Updates (1988)](#neglected-updates-1988): co-written state, one write missing -- *POSSIBLE* redundant-state desync
- **[tier 2]** [Derived-State Staleness (149)](#derivedstate-staleness-149): b = f(a); a later reassigned, b not recomputed -- *POSSIBLE* bug
- **[tier 2]** [Inconsistent Rename Clones (71)](#inconsistent-rename-clones-71): pasted block with inconsistent identifier mapping -- *POSSIBLE* missed rename bug
- **[tier 2]** [Flay Similarity (Type-2/3) (47)](#flay-similarity-type23-47): Flay structural clone pressure: Type-2 renamed clones and Type-3 fuzzy clones -- refactor pressure, not a verdict
- **[tier 2]** [Neglected Conditions (10)](#neglected-conditions-10): dispatch/conjunction minus one element -- *POSSIBLE* bug
- **[tier 3]** [Neglected Path Conditions (1858)](#neglected-path-conditions-1858): nested-if/&& guard set minus one atom -- *POSSIBLE* bug (noisy)
- **[tier 3]** [Broken Protocols (1461)](#broken-protocols-1461): co-called pair, one site does A without B -- *POSSIBLE* bug (noisy)
- **[tier 3]** [False Simplicity (754)](#false-simplicity-754): looks simple, behaves non-locally: hidden dispatch/mutation/IO/context/metaprogramming/monkeypatch -- *POSSIBLE* (noisy)
- **[tier 3]** [Fat Unions (8)](#fat-unions-8): case dispatch over class consts whose arms read mostly variant-invariant members -- product-vs-sum decomposition candidate (extraction -> nil-kill) -- *POSSIBLE*

## Cross-Detector Convergence (1366)
_(file, method) units flagged by >=2 INDEPENDENT detectors -- the strongest triage signal: agreement outranks any single detector's volume. Tier-weighted (1=3, 2=2, 3=1). **Start here.**_

- `src/mir/lowering/variables.rb:437` (build_var_decl_nodes) -- **7 detectors** [score 13, 101 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions, Neglected Updates, Reification Misses
- `src/annotator/annotator.rb:5427` (handle_assign_move) -- **7 detectors** [score 13, 54 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/tools/doctor.rb:170` (section_heap) -- **7 detectors** [score 13, 46 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Flay Similarity (Type-2/3), Missing Abstractions, Neglected Path Conditions
- `src/annotator/annotator.rb:1978` (visit_WhileBindLoop) -- **7 detectors** [score 13, 39 findings]: Broken Protocols, Decision Pressure, False Simplicity, Flay Similarity (Type-2/3), Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/ast/type.rb:2259` (compute_zig_type) -- **7 detectors** [score 12, 47 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Flay Similarity (Type-2/3), Neglected Path Conditions, Neglected Updates
- `src/ast/parser.rb:2839` (parse_type_annotation) -- **6 detectors** [score 12, 78 findings]: Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions, Neglected Updates, Reification Misses
- `src/annotator/annotator.rb:4710` (visit_WithBlock) -- **6 detectors** [score 11, 88 findings]: Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/tools/formatter.rb:1358` (expand_if_while_for) -- **6 detectors** [score 11, 76 findings]: Derived-State Staleness, False Simplicity, Inconsistent Rename Clones, Missing Abstractions, Neglected Conditions, Neglected Path Conditions
- `src/annotator/helpers/pipe_analysis.rb:1527` (analyze_concurrent_op) -- **6 detectors** [score 11, 70 findings]: Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/backends/pipeline_host.rb:3534` (lower_range_fold) -- **6 detectors** [score 11, 51 findings]: Broken Protocols, Decision Pressure, False Simplicity, Fat Unions, Flay Similarity (Type-2/3), Missing Abstractions
- `src/annotator/helpers/generic_analysis.rb:229` (validate_type_annotation!) -- **6 detectors** [score 11, 47 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions
- `src/mir/lowering/variables.rb:848` (lower_assignment) -- **6 detectors** [score 11, 26 findings]: Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/annotator/helpers/capabilities.rb:478` (visit_pre_clauses!) -- **6 detectors** [score 11, 15 findings]: Broken Protocols, Decision Pressure, False Simplicity, Flay Similarity (Type-2/3), Missing Abstractions, Neglected Path Conditions
- `src/annotator/helpers/pipe_analysis.rb:811` (analyze_pipe_to_named_function) -- **6 detectors** [score 11, 12 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions
- `src/annotator/annotator.rb:1546` (visit_MatchStatement) -- **6 detectors** [score 10, 148 findings]: Broken Protocols, Decision Pressure, False Simplicity, Flay Similarity (Type-2/3), Neglected Path Conditions, Neglected Updates
- `src/backends/pipeline_host.rb:308` (substitute_placeholders) -- **6 detectors** [score 10, 78 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions, Neglected Updates
- `src/mir/lowering/expressions.rb:484` (lower_smooth) -- **6 detectors** [score 10, 71 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions, Neglected Updates
- `src/annotator/annotator.rb:3573` (visit_StructLit) -- **6 detectors** [score 10, 70 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions, Neglected Updates
- `src/annotator/annotator.rb:3386` (visit_GetField) -- **6 detectors** [score 10, 38 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions, Neglected Updates
- `src/mir/fsm_lowering.rb:327` (fsm_owned_transfer_identifier?) -- **5 detectors** [score 12, 11 findings]: Decision Pressure, False Simplicity, Missing Abstractions, Neglected Updates, Reification Misses
- `src/ast/ast.rb:906` (finalize_storage!) -- **5 detectors** [score 11, 55 findings]: Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Updates
- `src/annotator/helpers/effects.rb:629` (enforce_fallible_returns!) -- **5 detectors** [score 11, 15 findings]: Decision Pressure, False Simplicity, Flay Similarity (Type-2/3), Missing Abstractions, Neglected Updates
- `src/mir/cleanup_classifier.rb:109` (stamp_binding_default_scope!) -- **5 detectors** [score 11, 10 findings]: Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Reification Misses
- `src/mir/lowering/functions.rb:222` (lower_function_def) -- **5 detectors** [score 10, 132 findings]: Decision Pressure, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/annotator/helpers/function_analysis.rb:182` (resolve_call) -- **5 detectors** [score 10, 108 findings]: Decision Pressure, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- ...(+1341 more)

### By file
- `src/annotator/annotator.rb` -- 11 detectors across 144 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, Exact Predicate Aliases, False Simplicity, Fat Unions, Flay Similarity (Type-2/3), Missing Abstractions, Neglected Path Conditions, Neglected Updates, Reification Misses
- `src/ast/ast.rb` -- 11 detectors across 22 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, Exact Predicate Aliases, False Simplicity, Fat Unions, Flay Similarity (Type-2/3), Missing Abstractions, Neglected Path Conditions, Neglected Updates, Semantic Predicate Aliases
- `src/mir/mir_lowering.rb` -- 9 detectors across 74 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Fat Unions, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Reification Misses
- `src/backends/pipeline_host.rb` -- 9 detectors across 67 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Fat Unions, Flay Similarity (Type-2/3), Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/annotator/helpers/pipe_analysis.rb` -- 9 detectors across 54 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Fat Unions, Flay Similarity (Type-2/3), Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/tools/formatter.rb` -- 9 detectors across 59 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Flay Similarity (Type-2/3), Inconsistent Rename Clones, Missing Abstractions, Neglected Conditions, Neglected Path Conditions
- `src/ast/parser.rb` -- 9 detectors across 57 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Flay Similarity (Type-2/3), Missing Abstractions, Neglected Path Conditions, Neglected Updates, Reification Misses
- `src/mir/lowering/control_flow.rb` -- 8 detectors across 35 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Reification Misses
- `src/mir/lowering/functions.rb` -- 8 detectors across 37 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Reification Misses
- `src/mir/lowering/variables.rb` -- 8 detectors across 28 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Reification Misses
- `src/ast/type.rb` -- 8 detectors across 27 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Flay Similarity (Type-2/3), Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/mir/lowering/capabilities.rb` -- 8 detectors across 19 method(s): Broken Protocols, Decision Pressure, False Simplicity, Flay Similarity (Type-2/3), Missing Abstractions, Neglected Conditions, Neglected Path Conditions, Neglected Updates
- `src/mir/mir_pass.rb` -- 8 detectors across 22 method(s): Broken Protocols, Decision Pressure, False Simplicity, Fat Unions, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Reification Misses
- `src/annotator/helpers/capabilities.rb` -- 8 detectors across 19 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Flay Similarity (Type-2/3), Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/annotator/helpers/auto_inference.rb` -- 8 detectors across 18 method(s): Broken Protocols, Decision Pressure, Exact Predicate Aliases, False Simplicity, Fat Unions, Missing Abstractions, Neglected Updates, Semantic Predicate Aliases

## Root-Cause Clusters (330)
_Findings across >=2 INDEPENDENT detectors that name the SAME entity -- 'N findings are really one invariant'. Convergence says where to look; this says **what one fix collapses the cluster**. Ranked candidate, not a verdict._

- **[name]** `expr` -- **6 detectors** [score 12] across 40 unit(s), 93 findings: Broken Protocols, Decision Pressure, Exact Predicate Aliases, False Simplicity, Neglected Path Conditions, Semantic Predicate Aliases
  - FIX: pair the protocol (RAII / ensure); the unpaired site is the deviant
  - `src/annotator/annotator.rb:1342` (visit_IfBind) ; `src/annotator/annotator.rb:1546` (visit_MatchStatement) ; `src/annotator/annotator.rb:5310` (visit_NextExpr) ; `src/annotator/annotator.rb:5313` (visit_NextExpr)
- **[name]** `sync` -- **5 detectors** [score 10] across 50 unit(s), 107 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Updates, Reification Misses
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator/annotator.rb:2245` (same_return_capabilities?) ; `src/annotator/annotator.rb:4973` (sync_constrained_cap?) ; `src/annotator/annotator.rb:6161` (bg_capture_independent?) ; `src/annotator/helpers/generic_analysis.rb:447` (generic_type_has_capabilities?)
- **[name]** `layout` -- **5 detectors** [score 10] across 41 unit(s), 71 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Updates, Reification Misses
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator/helpers/generic_analysis.rb:448` (generic_type_has_capabilities?) ; `src/ast/parser.rb:2936` (parse_type_annotation) ; `src/annotator/annotator.rb:1626` (visit_MatchStatement) ; `src/annotator/annotator.rb:3436` (visit_GetField)
- **[name]** `line` -- **5 detectors** [score 9] across 9 unit(s), 18 findings: Broken Protocols, Decision Pressure, Derived-State Staleness, Neglected Path Conditions, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/tools/doctor.rb:616` (task_site_metadata) ; `src/tools/doctor.rb:629` (source_line) ; `src/ast/lexer.rb:40` (initialize) ; `src/ast/lexer.rb:311` (advance_pos)
- **[name]** `value` -- **5 detectors** [score 8] across 84 unit(s), 30 findings: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator/annotator.rb:2096` (visit_ReturnNode) ; `src/annotator/annotator.rb:2137` (visit_ReturnNode) ; `src/annotator/annotator.rb:2139` (visit_ReturnNode) ; `src/annotator/annotator.rb:2141` (visit_ReturnNode)
- **[name]** `current` -- **5 detectors** [score 8] across 12 unit(s), 15 findings: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/ast/parser.rb:2525` (peek_generic_angle_params?) ; `src/mir/mir_lowering.rb:1115` (owner_cleanup_for_transfer) ; `src/ast/parser.rb:1364` (parse_function_def) ; `src/ast/parser.rb:31` (stmt)
- **[name]** `state` -- **5 detectors** [score 8] across 9 unit(s), 16 findings: Broken Protocols, False Simplicity, Neglected Path Conditions, Neglected Updates, Reification Misses
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator/annotator.rb:1274` (analyze_control_flow_branches) ; `src/annotator/annotator.rb:6638` (og_set_live) ; `src/mir/ownership_graph.rb:164` (drop) ; `src/mir/ownership_graph.rb:330` (record_move_site)
- **[name]** `stmt` -- **4 detectors** [score 9] across 16 unit(s), 17 findings: Derived-State Staleness, Exact Predicate Aliases, Neglected Path Conditions, Semantic Predicate Aliases
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/ast/schemas.rb:34` (enum?) ; `src/ast/schemas.rb:67` (resource?) ; `src/ast/schemas.rb:123` (union?) ; `src/ast/schemas.rb:169` (struct?)
- **[name]** `result_type` -- **4 detectors** [score 8] across 104 unit(s), 268 findings: Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/mir/mir.rb:2822` (ownership_effect) ; `src/mir/mir.rb:2919` (ownership_effect) ; `src/mir/mir.rb:2955` (ownership_effect) ; `src/backends/pipeline_host.rb:2033` (lower_stream_index)
- **[name]** `target` -- **4 detectors** [score 8] across 90 unit(s), 100 findings: Decision Pressure, Derived-State Staleness, Neglected Path Conditions, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator/annotator.rb:2139` (visit_ReturnNode) ; `src/annotator/annotator.rb:2141` (visit_ReturnNode) ; `src/annotator/annotator.rb:3097` (chain_root_name) ; `src/annotator/annotator.rb:3100` (chain_root_name)
- **[name]** `alloc` -- **4 detectors** [score 8] across 33 unit(s), 27 findings: Broken Protocols, Decision Pressure, False Simplicity, Reification Misses
  - FIX: pair the protocol (RAII / ensure); the unpaired site is the deviant
  - `src/mir/lowering/expressions.rb:1282` (lower_struct_lit) ; `src/mir/lowering/expressions.rb:1369` (lower_union_variant_lit) ; `src/mir/mir_checker.rb:1061` (check_aggregate_expr!) ; `src/mir/cleanup_classifier.rb:191` (mark_iteration_values_function!)
- **[name]** `struct` -- **4 detectors** [score 8] across 21 unit(s), 25 findings: Broken Protocols, Exact Predicate Aliases, Neglected Path Conditions, Semantic Predicate Aliases
  - FIX: pair the protocol (RAII / ensure); the unpaired site is the deviant
  - `src/ast/schemas.rb:34` (enum?) ; `src/ast/schemas.rb:67` (resource?) ; `src/ast/schemas.rb:123` (union?) ; `src/ast/schemas.rb:169` (struct?)
- **[name]** `union` -- **4 detectors** [score 8] across 20 unit(s), 24 findings: Broken Protocols, Exact Predicate Aliases, Neglected Path Conditions, Semantic Predicate Aliases
  - FIX: pair the protocol (RAII / ensure); the unpaired site is the deviant
  - `src/ast/schemas.rb:34` (enum?) ; `src/ast/schemas.rb:67` (resource?) ; `src/ast/schemas.rb:123` (union?) ; `src/ast/schemas.rb:169` (struct?)
- **[name]** `symbol` -- **4 detectors** [score 7] across 80 unit(s), 5 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Conditions
  - FIX: pair the protocol (RAII / ensure); the unpaired site is the deviant
  - `src/annotator/annotator.rb:308` (flush_deferred_with_validations!) ; `src/annotator/annotator.rb:312` (flush_deferred_with_validations!) ; `src/annotator/annotator.rb:2137` (visit_ReturnNode) ; `src/annotator/annotator.rb:2139` (visit_ReturnNode)
- **[name]** `capture_analysis` -- **4 detectors** [score 7] across 77 unit(s), 64 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/mir/control_flow.rb:727` (resource_captures) ; `src/mir/control_flow.rb:987` (collect_bg_body_gives) ; `src/mir/control_flow.rb:1140` (check_stmt_reads) ; `src/mir/control_flow.rb:1141` (check_stmt_reads)
- **[name]** `coerced_type` -- **4 detectors** [score 7] across 70 unit(s), 68 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/mir/lowering/expressions.rb:941` (float_coercion?) ; `src/annotator/annotator.rb:1298` (visit_BlockExpr) ; `src/annotator/annotator.rb:1642` (visit_MatchStatement) ; `src/annotator/annotator.rb:2593` (visit_VarDecl)
- **[name]** `left` -- **4 detectors** [score 7] across 46 unit(s), 40 findings: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator/annotator.rb:3940` (visit_OrRescue) ; `src/annotator/helpers/pipe_analysis.rb:72` (stamp_observable_terminal!) ; `src/annotator/helpers/pipe_analysis.rb:78` (stamp_observable_terminal!) ; `src/annotator/helpers/pipe_analysis.rb:263` (analyze_collect_op)
- **[name]** `emit` -- **4 detectors** [score 7] across 39 unit(s), 16 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator/annotator.rb:2356` (visit_StaticCall) ; `src/annotator/annotator.rb:2360` (visit_StaticCall) ; `src/annotator/annotator.rb:2361` (visit_StaticCall) ; `src/annotator/annotator.rb:2363` (visit_StaticCall)
- **[name]** `ownership` -- **4 detectors** [score 7] across 38 unit(s), 104 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/ast/type.rb:2301` (compute_zig_type) ; `src/annotator/annotator.rb:1343` (visit_IfBind) ; `src/annotator/annotator.rb:1940` (visit_WhileBindLoop) ; `src/annotator/annotator.rb:4354` (visit_LinkNode)
- **[name]** `allocs` -- **4 detectors** [score 7] across 31 unit(s), 28 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/mir/lowering/variables.rb:652` (owned_return_transfer_binding?) ; `src/mir/mir.rb:3308` (ownership_effect) ; `src/mir/mir.rb:3326` (has_alloc_metadata?) ; `src/mir/mir_checker.rb:1265` (stdlib_owned_return?)
- ...(+310 more)

## Decision Pressure (297)
_ELIMINABLE guard-pressure per loose contract (nil/is_a?/respond_to?/safe-nav/rescue-nil) -> tighten the contract once / nil-kill: DELETE. essential dispatch + pure c-uses are split out, NEVER summed (Rapps-Weyuker p-use; McCabe)_

- `.value` -- ELIMINABLE guard-pressure **140** across 64 method(s) -> tighten contract / nil-kill: DELETE  (+11 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/annotator.rb:2096` (visit_ReturnNode) ; `src/annotator/annotator.rb:2137` (visit_ReturnNode) ; `src/annotator/annotator.rb:2139` (visit_ReturnNode) ; `src/annotator/annotator.rb:2141` (visit_ReturnNode)
- `.symbol` -- ELIMINABLE guard-pressure **94** across 70 method(s) -> tighten contract / nil-kill: DELETE  (+13 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/annotator.rb:308` (flush_deferred_with_validations!) ; `src/annotator/annotator.rb:312` (flush_deferred_with_validations!) ; `src/annotator/annotator.rb:2137` (visit_ReturnNode) ; `src/annotator/annotator.rb:2139` (visit_ReturnNode)
- `.target` -- ELIMINABLE guard-pressure **63** across 37 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/annotator.rb:2139` (visit_ReturnNode) ; `src/annotator/annotator.rb:2141` (visit_ReturnNode) ; `src/annotator/annotator.rb:3097` (chain_root_name) ; `src/annotator/annotator.rb:3097` (chain_root_name)
- `.emit` -- ELIMINABLE guard-pressure **57** across 21 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/annotator.rb:2356` (visit_StaticCall) ; `src/annotator/annotator.rb:2360` (visit_StaticCall) ; `src/annotator/annotator.rb:2361` (visit_StaticCall) ; `src/annotator/annotator.rb:2363` (visit_StaticCall)
- `.full_type!` -- ELIMINABLE guard-pressure **55** across 17 method(s) -> tighten contract / nil-kill: DELETE  (+44 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/backends/pipeline_host.rb:488` (lower_pipeline) ; `src/backends/pipeline_host.rb:488` (lower_pipeline) ; `src/backends/pipeline_host.rb:488` (lower_pipeline) ; `src/backends/pipeline_host.rb:488` (lower_pipeline)
- `.name` -- ELIMINABLE guard-pressure **53** across 36 method(s) -> tighten contract / nil-kill: DELETE  (+3 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/annotator.rb:2397` (visit_FuncCall) ; `src/annotator/annotator.rb:2401` (visit_FuncCall) ; `src/annotator/annotator.rb:2409` (visit_FuncCall) ; `src/annotator/annotator.rb:2493` (visit_MethodCall)
- `.left` -- ELIMINABLE guard-pressure **43** across 20 method(s) -> tighten contract / nil-kill: DELETE  (+3 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/annotator.rb:3940` (visit_OrRescue) ; `src/annotator/helpers/pipe_analysis.rb:72` (stamp_observable_terminal!) ; `src/annotator/helpers/pipe_analysis.rb:78` (stamp_observable_terminal!) ; `src/annotator/helpers/pipe_analysis.rb:263` (analyze_collect_op)
- `.expr` -- ELIMINABLE guard-pressure **38** across 21 method(s) -> tighten contract / nil-kill: DELETE  (+2 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/annotator.rb:1342` (visit_IfBind) ; `src/annotator/annotator.rb:1546` (visit_MatchStatement) ; `src/annotator/annotator.rb:5310` (visit_NextExpr) ; `src/annotator/annotator.rb:5313` (visit_NextExpr)
- `.right` -- ELIMINABLE guard-pressure **35** across 17 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/annotator.rb:3949` (visit_OrRescue) ; `src/annotator/annotator.rb:3959` (visit_OrRescue) ; `src/annotator/annotator.rb:3971` (visit_OrRescue) ; `src/annotator/annotator.rb:3982` (visit_OrRescue)
- `.type` -- ELIMINABLE guard-pressure **33** across 26 method(s) -> tighten contract / nil-kill: DELETE  (+32 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/annotator.rb:291` (program_has_auto?) ; `src/annotator/annotator.rb:294` (program_has_auto?) ; `src/annotator/annotator.rb:633` (pre_register_function) ; `src/annotator/annotator.rb:707` (visit_FunctionDef)
- `.current_fn_ctx` -- ELIMINABLE guard-pressure **31** across 23 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/annotator.rb:2002` (visit_BreakNode) ; `src/annotator/annotator.rb:2010` (visit_ContinueNode) ; `src/annotator/annotator.rb:2405` (visit_FuncCall) ; `src/annotator/annotator.rb:2421` (visit_FuncCall)
- `[name]` -- ELIMINABLE guard-pressure **29** across 27 method(s) -> tighten contract / nil-kill: DELETE  (+9 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/annotator.rb:195` (annotate!) ; `src/annotator/annotator.rb:207` (annotate!) ; `src/annotator/annotator.rb:1901` (visit_WhileLoop) ; `src/annotator/annotator.rb:1978` (visit_WhileBindLoop)
- `.body` -- ELIMINABLE guard-pressure **27** across 19 method(s) -> tighten contract / nil-kill: DELETE  (+4 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/backends/pipeline_rewriter.rb:70` (rewrite_children!) ; `src/backends/string_concat_rewriter.rb:59` (rewrite_children!) ; `src/mir/escape_analysis.rb:778` (mark_lambda_captures_heap!) ; `src/mir/fsm_transform/recursive_splitter.rb:462` (emit_for_range_fragment)
- `.last` -- ELIMINABLE guard-pressure **25** across 6 method(s) -> tighten contract / nil-kill: DELETE  (+2 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/annotator.rb:5592` (expr_result_type) ; `src/annotator/annotator.rb:5595` (expr_result_type) ; `src/annotator/annotator.rb:5599` (expr_result_type) ; `src/annotator/annotator.rb:5599` (expr_result_type)
- `.token` -- ELIMINABLE guard-pressure **22** across 19 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/helpers/capabilities.rb:1146` (record_capability_binding) ; `src/annotator/helpers/capabilities.rb:1147` (record_capability_binding) ; `src/annotator/helpers/function_analysis.rb:531` (borrowed_takes_argument?) ; `src/mir/concurrency_checks.rb:82` (check_hold_across_yield!)
- `.element_type` -- ELIMINABLE guard-pressure **21** across 17 method(s) -> tighten contract / nil-kill: DELETE  (+6 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/annotator.rb:4312` (infer_element_type) ; `src/annotator/annotator.rb:4320` (infer_optional_element_type) ; `src/annotator/helpers/function_return.rb:83` (resolve) ; `src/annotator/helpers/generic_analysis.rb:184` (validate_type_annotation!)
- `.return_type` -- ELIMINABLE guard-pressure **19** across 12 method(s) -> tighten contract / nil-kill: DELETE  (+13 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/annotator.rb:292` (program_has_auto?) ; `src/annotator/annotator.rb:678` (visit_FunctionDef) ; `src/annotator/annotator.rb:2101` (visit_ReturnNode) ; `src/annotator/annotator.rb:2102` (visit_ReturnNode)
- `.stdlib_def` -- ELIMINABLE guard-pressure **19** across 8 method(s) -> tighten contract / nil-kill: DELETE  (+2 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/mir/lowering/variables.rb:648` (owned_return_transfer_binding?) ; `src/mir/lowering/variables.rb:649` (owned_return_transfer_binding?) ; `src/mir/mir.rb:3299` (ownership_effect) ; `src/mir/mir.rb:3299` (ownership_effect)
- `.type_params` -- ELIMINABLE guard-pressure **17** across 12 method(s) -> tighten contract / nil-kill: DELETE  (+1 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/annotator.rb:1140` (visit_StructDef) ; `src/annotator/annotator.rb:1156` (visit_StructDef) ; `src/annotator/annotator.rb:1176` (visit_UnionDef) ; `src/annotator/annotator.rb:1179` (visit_UnionDef)
- `[:var_node]` -- ELIMINABLE guard-pressure **15** across 10 method(s) -> tighten contract / nil-kill: DELETE  (+2 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/annotator.rb:4520` (visit_WithBlock) ; `src/annotator/annotator.rb:4524` (visit_WithBlock) ; `src/annotator/annotator.rb:4570` (visit_WithBlock) ; `src/annotator/annotator.rb:4708` (visit_WithBlock)
- `.capture_analysis` -- ELIMINABLE guard-pressure **15** across 10 method(s) -> tighten contract / nil-kill: DELETE
  - `src/mir/control_flow.rb:727` (resource_captures) ; `src/mir/control_flow.rb:987` (collect_bg_body_gives) ; `src/mir/control_flow.rb:1140` (check_stmt_reads) ; `src/mir/control_flow.rb:1141` (check_stmt_reads)
- `@og` -- ELIMINABLE guard-pressure **15** across 7 method(s) -> tighten contract / nil-kill: DELETE  (+6 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/annotator.rb:1240` (analyze_control_flow_branches) ; `src/annotator/annotator.rb:1247` (analyze_control_flow_branches) ; `src/annotator/annotator.rb:1253` (analyze_control_flow_branches) ; `src/annotator/annotator.rb:1264` (analyze_control_flow_branches)
- `.locals` -- ELIMINABLE guard-pressure **14** across 13 method(s) -> tighten contract / nil-kill: DELETE  (+7 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/annotator.rb:2979` (visit_Identifier) ; `src/annotator/annotator.rb:3122` (visit_Assignment) ; `src/annotator/annotator.rb:5979` (dest_scope_depth_for_target) ; `src/annotator/helpers/capabilities.rb:762` (declare_capability_scope!)
- `.object` -- ELIMINABLE guard-pressure **13** across 11 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/annotator.rb:1954` (visit_WhileBindLoop) ; `src/annotator/helpers/auto_inference.rb:790` (record_method_call) ; `src/annotator/helpers/function_analysis.rb:269` (receiver_container_alloc) ; `src/annotator/helpers/method_analysis.rb:133` (resolve_typed_method)
- `.first` -- ELIMINABLE guard-pressure **13** across 9 method(s) -> tighten contract / nil-kill: DELETE  (+4 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/annotator.rb:4311` (infer_element_type) ; `src/annotator/annotator.rb:4319` (infer_optional_element_type) ; `src/annotator/helpers/lock_helper.rb:454` (report_lock_cycle!) ; `src/mir/escape_analysis.rb:536` (mark_method_takes_heap!)
- ...(+272 more)

## Missing Abstractions (190)
_guard tuple recomputed across >=2 decision units_

- **[conjunction]** support=5 scatter=5 rank=25
  - tuple: `node.is_a?(AST::BinaryOp) | node.op == :SMOOTH`
  - `src/annotator/annotator.rb:1104` (collect_pipe_input_types) ; `src/backends/pipeline_host.rb:2433` (unwrap_range_chain) ; `src/backends/pipeline_host.rb:2459` (unwrap_binding_unnest_chain) ; `src/backends/pipeline_rewriter.rb:35` (rewrite!) ; `src/backends/pipeline_rewriter.rb:262` (binding_source?)
- **[conjunction]** support=5 scatter=5 rank=25
  - tuple: `node.container_borrow | node.respond_to?(:container_borrow)`
  - `src/annotator/helpers/function_analysis.rb:526` (borrowed_takes_argument?) ; `src/mir/cleanup_classifier.rb:658` (binding_container_borrow?) ; `src/mir/lowering/functions.rb:1097` (borrowed_ownership_operand?) ; `src/mir/lowering/variables.rb:168` (lower_var_decl) ; `src/mir/mir_lowering.rb:1733` (borrowed_ownership_ast?)
- **[case_dispatch]** support=5 scatter=5 rank=25
  - tuple: `'END' | 'FN' | 'FOR' | 'IF' | 'START' | 'TEST' | 'WHEN' | 'WHILE'`
  - `src/tools/formatter.rb:535` (find_match_block_end) ; `src/tools/formatter.rb:599` (scan_match_arms) ; `src/tools/formatter.rb:639` (build_match_arm) ; `src/tools/formatter.rb:751` (emit_match_body) ; `src/tools/formatter.rb:1236` (matching_end)
- **[case_dispatch]** support=5 scatter=4 rank=20
  - tuple: `AST::GetField | AST::MethodCall`
  - `src/annotator/annotator.rb:1449` (match_variant_name) ; `src/mir/cleanup_classifier.rb:456` (walk_match_as_bindings) ; `src/mir/lowering/control_flow.rb:567` (lower_match) ; `src/mir/lowering/control_flow.rb:574` (lower_match) ; `src/mir/lowering/control_flow.rb:725` (union_match_case_variants)
- **[case_dispatch]** support=4 scatter=4 rank=16
  - tuple: `AST::GetField | AST::GetIndex | AST::Identifier`
  - `src/annotator/annotator.rb:3137` (visit_Assignment) ; `src/annotator/helpers/capabilities.rb:106` (cap_var_label) ; `src/ast/ast.rb:389` (root_identifier) ; `src/ast/parser.rb:3954` (deep_clone_node)
- **[case_dispatch]** support=4 scatter=4 rank=16
  - tuple: `AST::AllOp | AST::AnyOp | AST::AverageOp | AST::CountOp | AST::FindOp | AST::MaxOp | AST::MinOp | AST::SumOp`
  - `src/ast/ast.rb:1834` (pipeline_range_fold?) ; `src/backends/pipeline_host.rb:967` (build_soa_scalar_fold_block) ; `src/backends/pipeline_host.rb:2610` (lower_binding_fold) ; `src/backends/pipeline_host.rb:3428` (lower_range_fold)
- **[conjunction]** support=4 scatter=4 rank=16
  - tuple: `node.is_a?(AST::BinaryOp) | node.op == :OR_RESCUE`
  - `src/mir/escape_analysis.rb:859` (returned_call_result?) ; `src/mir/escape_analysis.rb:971` (expr_produces_heap?) ; `src/mir/lowering/functions.rb:1487` (ast_expr_produces_heap?) ; `src/mir/mir_pass.rb:339` (unwrap_return_expr)
- **[conjunction]** support=4 scatter=4 rank=16
  - tuple: `node.is_a?(AST::ReturnNode) | node.value`
  - `src/mir/escape_analysis.rb:875` (mark_heap_return_facts!) ; `src/mir/escape_analysis.rb:1006` (function_has_owned_return_value?) ; `src/mir/mir_pass.rb:306` (return_path_needs_allocator?) ; `src/mir/mir_pass.rb:757` (mark_returned_cleanup_bindings!)
- **[conjunction]** support=4 scatter=4 rank=16
  - tuple: `@decl_zig_name_map | @decl_zig_name_map[decl.object_id] | decl`
  - `src/mir/lowering/capabilities.rb:105` (with_cap_zig_target) ; `src/mir/lowering/control_flow.rb:1114` (collect_returned_binding_names) ; `src/mir/mir_lowering.rb:2162` (extract_root_var_name) ; `src/mir/test_lowering.rb:429` (stub_local_idents)
- **[conjunction]** support=4 scatter=4 rank=16
  - tuple: `j < toks.length | toks[j].type == :NL`
  - `src/tools/formatter.rb:887` (skip_nls) ; `src/tools/formatter.rb:2302` (detect_recover_stages) ; `src/tools/formatter.rb:2444` (emit_record_type) ; `src/tools/formatter.rb:2487` (emit_stmt_terminator)
- **[conjunction]** support=4 scatter=3 rank=12
  - tuple: `t.auto? | t.is_a?(Type)`
  - `src/annotator/helpers/auto_inference.rb:206` (auto?) ; `src/annotator/helpers/auto_inference.rb:580` (collect_observed_types) ; `src/annotator/helpers/auto_inference.rb:963` (auto?) ; `src/backends/importer.rb:164` (auto_type?)
- **[conjunction]** support=4 scatter=3 rank=12
  - tuple: `cursor.is_a?(AST::BinaryOp) | cursor.op == :SMOOTH`
  - `src/backends/pipeline_host.rb:2437` (unwrap_range_chain) ; `src/backends/pipeline_host.rb:2469` (unwrap_binding_unnest_chain) ; `src/backends/pipeline_host.rb:2480` (unwrap_binding_unnest_chain) ; `src/backends/pipeline_rewriter.rb:289` (collect_chain)
- **[case_dispatch]** support=4 scatter=3 rank=12
  - tuple: `AST::Assignment | AST::BindExpr | AST::VarDecl`
  - `src/mir/fsm_transform/liveness.rb:198` (collect_defs) ; `src/mir/mir_pass.rb:512` (collect_consumed_names) ; `src/mir/mir_pass.rb:532` (collect_consumed_names) ; `src/tools/migration_suggester_helpers.rb:88` (walk_recursive)
- **[conjunction]** support=4 scatter=3 rank=12
  - tuple: `bdepth.zero? | kdepth.zero?`
  - `src/tools/formatter.rb:588` (scan_match_arms) ; `src/tools/formatter.rb:629` (build_match_arm) ; `src/tools/formatter.rb:636` (build_match_arm) ; `src/tools/formatter.rb:743` (emit_match_body)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `slot.respond_to?(:shape) | slot.shape`
  - `src/annotator/annotator.rb:268` (emit_auto_shape_resolved_findings!) ; `src/annotator/helpers/fixable_helpers.rb:1461` (emit_auto_resolved_finding!) ; `src/annotator/helpers/fixable_helpers.rb:1623` (auto_slot_label)
- **[case_dispatch]** support=3 scatter=3 rank=9
  - tuple: `:block | :exit`
  - `src/annotator/annotator.rb:1024` (visit_SyncPolicyDecl) ; `src/annotator/annotator.rb:5032` (validate_snapshot_match_arms!) ; `src/mir/lowering/capabilities.rb:529` (build_fallible_clause_mir)
- **[case_dispatch]** support=3 scatter=3 rank=9
  - tuple: `:kind | :type`
  - `src/annotator/annotator.rb:5060` (resolve_error_selectors!) ; `src/annotator/helpers/lock_helper.rb:414` (verify_handler_reachability!) ; `src/annotator/helpers/with_match_check.rb:420` (handled_error_set)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `node.is_a?(AST::FuncCall) | node.name == fn_name`
  - `src/annotator/annotator.rb:6304` (contains_self_call?) ; `src/mir/thunk_transform/recursive_splitter.rb:259` (direct_self_call) ; `src/mir/thunk_transform/recursive_splitter.rb:269` (contains_self_call?)
- **[case_dispatch]** support=3 scatter=3 rank=9
  - tuple: `:local | :param | :return`
  - `src/annotator/helpers/auto_inference.rb:633` (stamp_slot!) ; `src/annotator/helpers/fixable_helpers.rb:1589` (slot_id_for) ; `src/annotator/helpers/fixable_helpers.rb:1632` (auto_slot_label)
- **[case_dispatch]** support=3 scatter=3 rank=9
  - tuple: `AST::SelectOp | AST::WhereOp`
  - `src/annotator/helpers/pipe_analysis.rb:1572` (analyze_concurrent_op) ; `src/annotator/helpers/pipe_analysis.rb:1642` (analyze_concurrent_bounded_select_family_op) ; `src/annotator/helpers/pipe_analysis.rb:1706` (analyze_concurrent_stream_select_family_op)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `!direct | reachable_from_self?(name)`
  - `src/annotator/helpers/reentrance.rb:235` (validate_not_logical_recursion!) ; `src/annotator/helpers/reentrance.rb:266` (validate_max_depth_mutual_cycle!) ; `src/annotator/helpers/reentrance.rb:320` (validate_thunk_recursion!)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `!node.else_branch.empty? | node.else_branch`
  - `src/ast/ast.rb:432` (body_slots) ; `src/mir/lowering/control_flow.rb:137` (lower_if) ; `src/mir/lowering/control_flow.rb:150` (lower_if_bind)
- **[case_dispatch]** support=3 scatter=3 rank=9
  - tuple: `AST::LimitOp | AST::SelectOp | AST::SkipOp | AST::TakeWhileOp | AST::TapOp | AST::WhereOp`
  - `src/ast/ast.rb:1802` (pipeline_fusible_stage?) ; `src/backends/pipeline_host.rb:2765` (build_lazy_range_prefix) ; `src/backends/pipeline_rewriter.rb:509` (build_recursive_body)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `atomic? | indirect?`
  - `src/ast/ast.rb:1901` (atomic_ptr?) ; `src/ast/symbol_entry.rb:153` (atomic_ptr?) ; `src/ast/type.rb:705` (atomic_ptr?)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `!source.empty? | source`
  - `src/ast/syntax_typo_scanner.rb:41` (scan!) ; `src/mir/lowering/capabilities.rb:913` (lower_pre_clauses) ; `src/mir/lowering/functions.rb:746` (build_post_outer_fn)
- ...(+165 more)

## Reification Misses (24)
_an existing predicate reinvented inline -- invariant #16_

- predicate `atomic?` reinvented inline at `src/ast/parser.rb:2936` (parse_type_annotation) (`sync == :atomic`)
- predicate `frame?` reinvented inline at `src/mir/cleanup_classifier.rb:191` (mark_iteration_values_function!) (`entry.alloc == :frame`)
- predicate `frame?` reinvented inline at `src/mir/control_flow.rb:1324` (process_loop!) (`entry.alloc == :frame`)
- predicate `frame?` reinvented inline at `src/mir/local_binding_facts.rb:100` (binding_frame_allocates?) (`entry.alloc == :frame`)
- predicate `frame?` reinvented inline at `src/mir/lowering/functions.rb:554` (runtime_frame_prologue) (`e.alloc == :frame`)
- predicate `frame?` reinvented inline at `src/mir/mir_checker.rb:1278` (verify_owned_return_alloc_marks!) (`m.alloc == :frame`)
- predicate `frame?` reinvented inline at `src/mir/mir_checker.rb:1767` (verify_alloc_cleanup_match!) (`m.alloc == :frame`)
- predicate `frame?` reinvented inline at `src/mir/mir_checker.rb:2259` (body_has_frame_alloc_scope?) (`node.alloc == :frame`)
- predicate `frame?` reinvented inline at `src/mir/mir_checker.rb:2293` (expr_has_frame_alloc?) (`expr.alloc == :frame`)
- predicate `heap?` reinvented inline at `src/mir/cleanup_classifier.rb:113` (stamp_binding_default_scope!) (`entry.alloc == :heap`)
- predicate `heap?` reinvented inline at `src/mir/cleanup_classifier.rb:329` (no_cleanup_alloc_entry) (`alloc == :heap`)
- predicate `heap?` reinvented inline at `src/mir/cleanup_entry.rb:39` (build) (`alloc == :heap`)
- predicate `heap?` reinvented inline at `src/mir/cleanup_entry.rb:103` (with_alloc) (`alloc == :heap`)
- predicate `heap?` reinvented inline at `src/mir/fsm_lowering.rb:327` (fsm_owned_transfer_identifier?) (`entry.alloc == :heap`)
- predicate `heap?` reinvented inline at `src/mir/lowering/control_flow.rb:1004` (return_transfers_heap_binding?) (`entry.alloc == :heap`)
- predicate `heap?` reinvented inline at `src/mir/lowering/functions.rb:656` (takes_param_ownership_mir) (`entry.alloc == :heap`)
- predicate `heap?` reinvented inline at `src/mir/lowering/variables.rb:473` (build_var_decl_nodes) (`binding_entry.alloc == :heap`)
- predicate `heap?` reinvented inline at `src/mir/lowering/variables.rb:516` (var_decl_alloc_mark) (`alloc == :heap`)
- predicate `heap?` reinvented inline at `src/mir/lowering/variables.rb:643` (owned_return_transfer_binding?) (`binding_entry.alloc == :heap`)
- predicate `heap?` reinvented inline at `src/mir/mir_checker.rb:337` (verify_return_transfers_heap!) (`mark.alloc == :heap`)
- predicate `heap?` reinvented inline at `src/mir/mir_lowering.rb:1826` (collect_moved_arg_roots) (`entry.alloc == :heap`)
- predicate `heap?` reinvented inline at `src/mir/mir_pass.rb:661` (stamp_reassign_cleanup!) (`entry.alloc == :heap`)
- predicate `indirect?` reinvented inline at `src/ast/parser.rb:2936` (parse_type_annotation) (`layout == :indirect`)
- predicate `moved?` reinvented inline at `src/annotator/annotator.rb:1274` (analyze_control_flow_branches) (`state == :moved`)

## Semantic Predicate Aliases (3)
_one decision, multiple names (receiver/polarity folded)_

- `enum? = resource? = union? = struct? = needs_capture_site_annotation? = suspend? = mir? = stmt? = expr? = has_own_frame?` == `true`
  - `src/ast/schemas.rb:34` (enum?) ; `src/ast/schemas.rb:67` (resource?) ; `src/ast/schemas.rb:123` (union?) ; `src/ast/schemas.rb:169` (struct?) ; `src/mir/capture_strategy.rb:79` (needs_capture_site_annotation?) ; `src/mir/capture_strategy.rb:95` (needs_capture_site_annotation?) ; `src/mir/fsm_transform/segments.rb:51` (suspend?) ; `src/mir/fsm_transform/segments.rb:69` (suspend?) ; `src/mir/mir.rb:264` (mir?) ; `src/mir/mir.rb:313` (stmt?) ; `src/mir/mir.rb:335` (expr?) ; `src/mir/mir.rb:591` (has_own_frame?) ; `src/mir/mir.rb:1050` (expr?) ; `src/mir/mir.rb:1136` (expr?) ; `src/mir/mir.rb:1163` (expr?) ; `src/mir/mir.rb:1338` (expr?) ; `src/mir/mir.rb:1349` (expr?) ; `src/mir/mir.rb:1366` (expr?) ; `src/mir/mir.rb:1402` (expr?) ; `src/mir/mir.rb:2221` (stmt?) ; `src/mir/mir.rb:2255` (stmt?) ; `src/mir/mir.rb:2279` (stmt?) ; `src/mir/mir.rb:2308` (stmt?) ; `src/mir/mir.rb:2319` (stmt?) ; `src/mir/mir.rb:2339` (stmt?) ; `src/mir/mir.rb:2366` (stmt?) ; `src/mir/mir.rb:2387` (stmt?) ; `src/mir/mir.rb:2399` (stmt?) ; `src/mir/mir.rb:2406` (stmt?) ; `src/mir/mir.rb:2413` (stmt?) ; `src/mir/mir.rb:2425` (stmt?) ; `src/mir/mir.rb:2432` (stmt?) ; `src/mir/mir.rb:2440` (stmt?) ; `src/mir/mir.rb:2456` (stmt?) ; `src/mir/mir.rb:2502` (stmt?) ; `src/mir/mir.rb:2515` (stmt?) ; `src/mir/mir.rb:3197` (expr?) ; `src/mir/mir.rb:3402` (expr?) ; `src/mir/mir.rb:3453` (expr?)
- `wildcard? = union? = struct? = resource? = enum? = needs_capture_site_annotation? = stmt? = expr?` == `false`
  - `src/ast/ast.rb:1397` (wildcard?) ; `src/ast/ast.rb:1541` (wildcard?) ; `src/ast/ast.rb:1556` (wildcard?) ; `src/ast/schemas.rb:36` (union?) ; `src/ast/schemas.rb:38` (struct?) ; `src/ast/schemas.rb:40` (resource?) ; `src/ast/schemas.rb:69` (union?) ; `src/ast/schemas.rb:71` (enum?) ; `src/ast/schemas.rb:73` (struct?) ; `src/ast/schemas.rb:125` (enum?) ; `src/ast/schemas.rb:127` (struct?) ; `src/ast/schemas.rb:129` (resource?) ; `src/ast/schemas.rb:171` (union?) ; `src/ast/schemas.rb:173` (enum?) ; `src/ast/schemas.rb:175` (resource?) ; `src/mir/capture_strategy.rb:51` (needs_capture_site_annotation?) ; `src/mir/capture_strategy.rb:64` (needs_capture_site_annotation?) ; `src/mir/capture_strategy.rb:108` (needs_capture_site_annotation?) ; `src/mir/mir.rb:266` (stmt?) ; `src/mir/mir.rb:268` (expr?)
- `auto? = auto_type?` == `t.is_a?(Type) && t.auto?`
  - `src/annotator/helpers/auto_inference.rb:205` (auto?) ; `src/annotator/helpers/auto_inference.rb:962` (auto?) ; `src/backends/importer.rb:163` (auto_type?)

## Exact Predicate Aliases (7)
_identical one-line predicate body under >=2 names_

- `enum? = resource? = union? = struct? = needs_capture_site_annotation? = suspend? = mir? = stmt? = expr? = has_own_frame?` == `true`
  - `src/ast/schemas.rb:34` (enum?) ; `src/ast/schemas.rb:67` (resource?) ; `src/ast/schemas.rb:123` (union?) ; `src/ast/schemas.rb:169` (struct?) ; `src/mir/capture_strategy.rb:79` (needs_capture_site_annotation?) ; `src/mir/capture_strategy.rb:95` (needs_capture_site_annotation?) ; `src/mir/fsm_transform/segments.rb:51` (suspend?) ; `src/mir/fsm_transform/segments.rb:69` (suspend?) ; `src/mir/mir.rb:264` (mir?) ; `src/mir/mir.rb:313` (stmt?) ; `src/mir/mir.rb:335` (expr?) ; `src/mir/mir.rb:591` (has_own_frame?) ; `src/mir/mir.rb:1050` (expr?) ; `src/mir/mir.rb:1136` (expr?) ; `src/mir/mir.rb:1163` (expr?) ; `src/mir/mir.rb:1338` (expr?) ; `src/mir/mir.rb:1349` (expr?) ; `src/mir/mir.rb:1366` (expr?) ; `src/mir/mir.rb:1402` (expr?) ; `src/mir/mir.rb:2221` (stmt?) ; `src/mir/mir.rb:2255` (stmt?) ; `src/mir/mir.rb:2279` (stmt?) ; `src/mir/mir.rb:2308` (stmt?) ; `src/mir/mir.rb:2319` (stmt?) ; `src/mir/mir.rb:2339` (stmt?) ; `src/mir/mir.rb:2366` (stmt?) ; `src/mir/mir.rb:2387` (stmt?) ; `src/mir/mir.rb:2399` (stmt?) ; `src/mir/mir.rb:2406` (stmt?) ; `src/mir/mir.rb:2413` (stmt?) ; `src/mir/mir.rb:2425` (stmt?) ; `src/mir/mir.rb:2432` (stmt?) ; `src/mir/mir.rb:2440` (stmt?) ; `src/mir/mir.rb:2456` (stmt?) ; `src/mir/mir.rb:2502` (stmt?) ; `src/mir/mir.rb:2515` (stmt?) ; `src/mir/mir.rb:3197` (expr?) ; `src/mir/mir.rb:3402` (expr?) ; `src/mir/mir.rb:3453` (expr?)
- `child_bodies = marker_plan = with_alias_ownership_marks = child_exprs = ownership_source_exprs = owned_position_source_exprs = body_slots = pre_terminator_transfer_marks` == `[]`
  - `src/ast/ast.rb:687` (child_bodies) ; `src/mir/capture_strategy.rb:49` (marker_plan) ; `src/mir/capture_strategy.rb:62` (marker_plan) ; `src/mir/capture_strategy.rb:106` (marker_plan) ; `src/mir/lowering/capabilities.rb:88` (with_alias_ownership_marks) ; `src/mir/mir.rb:272` (child_exprs) ; `src/mir/mir.rb:274` (ownership_source_exprs) ; `src/mir/mir.rb:276` (owned_position_source_exprs) ; `src/mir/mir.rb:278` (body_slots) ; `src/mir/mir_lowering.rb:1332` (pre_terminator_transfer_marks)
- `wildcard? = union? = struct? = resource? = enum? = needs_capture_site_annotation? = stmt? = expr?` == `false`
  - `src/ast/ast.rb:1397` (wildcard?) ; `src/ast/ast.rb:1541` (wildcard?) ; `src/ast/ast.rb:1556` (wildcard?) ; `src/ast/schemas.rb:36` (union?) ; `src/ast/schemas.rb:38` (struct?) ; `src/ast/schemas.rb:40` (resource?) ; `src/ast/schemas.rb:69` (union?) ; `src/ast/schemas.rb:71` (enum?) ; `src/ast/schemas.rb:73` (struct?) ; `src/ast/schemas.rb:125` (enum?) ; `src/ast/schemas.rb:127` (struct?) ; `src/ast/schemas.rb:129` (resource?) ; `src/ast/schemas.rb:171` (union?) ; `src/ast/schemas.rb:173` (enum?) ; `src/ast/schemas.rb:175` (resource?) ; `src/mir/capture_strategy.rb:51` (needs_capture_site_annotation?) ; `src/mir/capture_strategy.rb:64` (needs_capture_site_annotation?) ; `src/mir/capture_strategy.rb:108` (needs_capture_site_annotation?) ; `src/mir/mir.rb:266` (stmt?) ; `src/mir/mir.rb:268` (expr?)
- `visit_PassStmt = visit_OrRaise = visit_OrBreak = visit_OrPass = visit_OrPrune` == `stamp_type!(node, :Void)`
  - `src/annotator/annotator.rb:1521` (visit_PassStmt) ; `src/annotator/annotator.rb:4055` (visit_OrRaise) ; `src/annotator/annotator.rb:4060` (visit_OrBreak) ; `src/annotator/annotator.rb:4065` (visit_OrPass) ; `src/annotator/annotator.rb:4072` (visit_OrPrune)
- `emit_rc_retain = emit_rc_downgrade = emit_weak_upgrade` == `"CheatLib.#{node.func}(#{node.zig_base}, #{emit(node.source)})"`
  - `src/mir/mir_emitter.rb:1195` (emit_rc_retain) ; `src/mir/mir_emitter.rb:1200` (emit_rc_downgrade) ; `src/mir/mir_emitter.rb:1205` (emit_weak_upgrade)
- `auto? = auto_type?` == `t.is_a?(Type) && t.auto?`
  - `src/annotator/helpers/auto_inference.rb:205` (auto?) ; `src/annotator/helpers/auto_inference.rb:962` (auto?) ; `src/backends/importer.rb:163` (auto_type?)
- `ownership_source_exprs = owned_position_source_exprs` == `child_exprs`
  - `src/mir/mir.rb:863` (ownership_source_exprs) ; `src/mir/mir.rb:865` (owned_position_source_exprs) ; `src/mir/mir.rb:1870` (ownership_source_exprs) ; `src/mir/mir.rb:2068` (ownership_source_exprs) ; `src/mir/mir.rb:2089` (ownership_source_exprs) ; `src/mir/mir.rb:2142` (ownership_source_exprs) ; `src/mir/mir.rb:2163` (ownership_source_exprs) ; `src/mir/mir.rb:2735` (ownership_source_exprs) ; `src/mir/mir.rb:2756` (ownership_source_exprs) ; `src/mir/mir.rb:2858` (ownership_source_exprs) ; `src/mir/mir.rb:2860` (owned_position_source_exprs) ; `src/mir/mir.rb:2880` (ownership_source_exprs) ; `src/mir/mir.rb:2882` (owned_position_source_exprs) ; `src/mir/mir.rb:2908` (ownership_source_exprs) ; `src/mir/mir.rb:2910` (owned_position_source_exprs) ; `src/mir/mir.rb:2944` (ownership_source_exprs) ; `src/mir/mir.rb:2946` (owned_position_source_exprs) ; `src/mir/mir.rb:3014` (ownership_source_exprs) ; `src/mir/mir.rb:3016` (owned_position_source_exprs) ; `src/mir/mir.rb:3114` (ownership_source_exprs) ; `src/mir/mir.rb:3116` (owned_position_source_exprs) ; `src/mir/mir.rb:3164` (ownership_source_exprs) ; `src/mir/mir.rb:3202` (ownership_source_exprs) ; `src/mir/mir.rb:3204` (owned_position_source_exprs)

## Inconsistent Rename Clones (71)
_pasted block with inconsistent identifier mapping -- *POSSIBLE* missed rename bug_

- *POSSIBLE* `src/tools/formatter.rb:2159` (emit_bg_do_wrapped) clone of `src/tools/formatter.rb:733` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2159` (emit_bg_do_wrapped) clone of `src/tools/formatter.rb:830` (emit_fn_block): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2159` (emit_bg_do_wrapped) clone of `src/tools/formatter.rb:843` (emit_fn_block): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2159` (emit_bg_do_wrapped) clone of `src/tools/formatter.rb:948` (emit_fn_signature_wrapped): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2159` (emit_bg_do_wrapped) clone of `src/tools/formatter.rb:1063` (emit_fn_params_only_wrapped): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2159` (emit_bg_do_wrapped) clone of `src/tools/formatter.rb:1324` (expand_if_while_for): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2159` (emit_bg_do_wrapped) clone of `src/tools/formatter.rb:1326` (expand_if_while_for): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2159` (emit_bg_do_wrapped) clone of `src/tools/formatter.rb:1328` (expand_if_while_for): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2159` (emit_bg_do_wrapped) clone of `src/tools/formatter.rb:1978` (emit_wrapped_args): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:837` (emit_fn_block) clone of `src/tools/formatter.rb:733` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:849` (emit_fn_block) clone of `src/tools/formatter.rb:733` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:1068` (emit_fn_params_only_wrapped) clone of `src/tools/formatter.rb:733` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:1068` (emit_fn_params_only_wrapped) clone of `src/tools/formatter.rb:830` (emit_fn_block): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:1068` (emit_fn_params_only_wrapped) clone of `src/tools/formatter.rb:843` (emit_fn_block): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:1068` (emit_fn_params_only_wrapped) clone of `src/tools/formatter.rb:948` (emit_fn_signature_wrapped): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:953` (emit_fn_signature_wrapped) clone of `src/tools/formatter.rb:733` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:953` (emit_fn_signature_wrapped) clone of `src/tools/formatter.rb:830` (emit_fn_block): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:953` (emit_fn_signature_wrapped) clone of `src/tools/formatter.rb:843` (emit_fn_block): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2434` (emit_record_type) clone of `src/tools/formatter.rb:733` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2434` (emit_record_type) clone of `src/tools/formatter.rb:830` (emit_fn_block): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2434` (emit_record_type) clone of `src/tools/formatter.rb:843` (emit_fn_block): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2434` (emit_record_type) clone of `src/tools/formatter.rb:948` (emit_fn_signature_wrapped): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2434` (emit_record_type) clone of `src/tools/formatter.rb:1063` (emit_fn_params_only_wrapped): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2434` (emit_record_type) clone of `src/tools/formatter.rb:1324` (expand_if_while_for): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2434` (emit_record_type) clone of `src/tools/formatter.rb:1326` (expand_if_while_for): ref var `+` spelled ["-", "+"] here
- ...(+46 more)

## Flay Similarity (Type-2/3) (47)
_Flay structural clone pressure: Type-2 renamed clones and Type-3 fuzzy clones -- refactor pressure, not a verdict_

- *POSSIBLE* [type2] mass=340 node=`when` `src/backends/pipeline_rewriter.rb:539` (build_recursive_body) ; `src/backends/pipeline_rewriter.rb:566` (build_recursive_body)
- *POSSIBLE* [type2] mass=252 node=`defn` `src/annotator/helpers/pipe_analysis.rb:943` (analyze_any_op) ; `src/annotator/helpers/pipe_analysis.rb:965` (analyze_all_op) ; `src/annotator/helpers/pipe_analysis.rb:987` (analyze_count_op)
- *POSSIBLE* [type2] mass=242 node=`when` `src/backends/pipeline_host.rb:3460` (lower_range_fold) ; `src/backends/pipeline_host.rb:3477` (lower_range_fold)
- *POSSIBLE* [type2] mass=212 node=`defn` `src/backends/pipeline_host.rb:1100` (lower_min) ; `src/backends/pipeline_host.rb:1126` (lower_max)
- *POSSIBLE* [type2] mass=210 node=`iter` `src/ast/parser.rb:408` ((top-level)) ; `src/ast/parser.rb:415` ((top-level)) ; `src/ast/parser.rb:422` ((top-level)) ; `src/ast/parser.rb:429` ((top-level)) (+1 more)
- *POSSIBLE* [type3] mass=192 node=`defn` `src/backends/pipeline_host.rb:280` (ast_node_uses_placeholder?) ; `src/backends/pipeline_host.rb:871` (ast_uses_bare_placeholder?)
- *POSSIBLE* [type2] mass=188 node=`iter` `src/ast/parser.rb:372` ((top-level)) ; `src/ast/parser.rb:381` ((top-level)) ; `src/ast/parser.rb:390` ((top-level)) ; `src/ast/parser.rb:399` ((top-level))
- *POSSIBLE* [type2] mass=180 node=`defn` `src/annotator/helpers/pipe_analysis.rb:1062` (analyze_min_op) ; `src/annotator/helpers/pipe_analysis.rb:1085` (analyze_max_op)
- *POSSIBLE* [type2] mass=166 node=`when` `src/backends/pipeline_host.rb:987` (build_soa_scalar_fold_block) ; `src/backends/pipeline_host.rb:994` (build_soa_scalar_fold_block)
- *POSSIBLE* [type2] mass=158 node=`or` `src/annotator/annotator.rb:5599` (expr_result_type) ; `src/annotator/helpers/pipe_analysis.rb:157` (higher_order_list_op?)
- *POSSIBLE* [type2] mass=152 node=`when` `src/backends/pipeline_host.rb:2640` (lower_binding_fold) ; `src/backends/pipeline_host.rb:2650` (lower_binding_fold)
- *POSSIBLE* [type2] mass=152 node=`cdecl` `src/mir/mir.rb:776` ((top-level)) ; `src/mir/mir.rb:797` ((top-level))
- *POSSIBLE* [type2] mass=148 node=`defn` `src/mir/thunk_transform/recursive_splitter.rb:168` (match_mutual_base_case) ; `src/mir/thunk_transform/recursive_splitter.rb:214` (match_base_case)
- *POSSIBLE* [type2] mass=144 node=`defn` `src/mir/fsm_wrapper_emitter.rb:58` (render_io_body) ; `src/mir/fsm_wrapper_emitter.rb:75` (render_b1_body) ; `src/mir/fsm_wrapper_emitter.rb:255` (render_generic_body)
- *POSSIBLE* [type2] mass=132 node=`if` `src/annotator/helpers/fixable_helpers.rb:105` (emit_registry_mismatch!) ; `src/annotator/helpers/fixable_helpers.rb:144` (emit_typo_suggestion!) ; `src/annotator/helpers/fixable_helpers.rb:212` (emit_variant_typo!)
- *POSSIBLE* [type3] mass=130 node=`block` `src/annotator/annotator.rb:1896` (visit_WhileLoop) ; `src/annotator/annotator.rb:1972` (visit_WhileBindLoop)
- *POSSIBLE* [type2] mass=114 node=`iter` `src/ast/std_lib.rb:1162` ((top-level)) ; `src/ast/std_lib.rb:1180` ((top-level)) ; `src/ast/std_lib.rb:1197` ((top-level))
- *POSSIBLE* [type2] mass=114 node=`hash` `src/tools/doctor.rb:676` (section_locks) ; `src/tools/pprof_converter.rb:203` (convert_locks)
- *POSSIBLE* [type2] mass=106 node=`if` `src/annotator/annotator.rb:1400` (annotate_struct_pattern!) ; `src/annotator/annotator.rb:1676` (visit_MatchStatement)
- *POSSIBLE* [type2] mass=104 node=`cdecl` `src/mir/mir.rb:959` ((top-level)) ; `src/mir/mir.rb:973` ((top-level))
- *POSSIBLE* [type2] mass=102 node=`lasgn` `src/backends/pipeline_host.rb:4556` (lower_concurrent_stream_where) ; `src/backends/pipeline_host.rb:4591` (lower_concurrent_stream_each)
- *POSSIBLE* [type2] mass=100 node=`if` `src/annotator/helpers/capabilities.rb:488` (visit_pre_clauses!) ; `src/annotator/helpers/effects.rb:663` (enforce_fallible_returns!)
- *POSSIBLE* [type2] mass=99 node=`defn` `src/mir/mir.rb:716` (body_slots) ; `src/mir/mir.rb:736` (body_slots) ; `src/mir/mir.rb:2321` (body_slots)
- *POSSIBLE* [type2] mass=94 node=`if` `src/ast/type.rb:2105` (parse_raw_input) ; `src/ast/type.rb:2117` (parse_raw_input)
- *POSSIBLE* [type2] mass=90 node=`lasgn` `src/backends/pipeline_host.rb:4731` (lower_concurrent_list_count) ; `src/backends/pipeline_host.rb:4805` (lower_concurrent_list_each)
- ...(+22 more)

## Neglected Updates (1988)
_co-written state, one write missing -- *POSSIBLE* redundant-state desync_

- *POSSIBLE* (support=11) `src/annotator/helpers/auto_inference.rb:155` (initialize) writes `.@fn_nodes` but NOT `.@call_graph` (recv `self`)
- *POSSIBLE* (support=11) `src/annotator/helpers/capabilities.rb:410` (predicate_impurity_reason) writes `.@fn_nodes` but NOT `.@call_graph` (recv `self`)
- *POSSIBLE* (support=11) `src/annotator/helpers/capabilities.rb:1140` (record_capability_binding) writes `.@fn_nodes` but NOT `.@call_graph` (recv `self`)
- *POSSIBLE* (support=11) `src/annotator/helpers/effects.rb:600` (enforce_fallible_returns!) writes `.@fn_nodes` but NOT `.@call_graph` (recv `self`)
- *POSSIBLE* (support=11) `src/annotator/helpers/effects.rb:708` (mark_fn_value_references!) writes `.@fn_nodes` but NOT `.@call_graph` (recv `self`)
- *POSSIBLE* (support=11) `src/annotator/helpers/effects.rb:770` (compute_fsm_eligibility!) writes `.@fn_nodes` but NOT `.@call_graph` (recv `self`)
- *POSSIBLE* (support=11) `src/annotator/helpers/effects.rb:804` (enumerate_fsm_suspend_points!) writes `.@fn_nodes` but NOT `.@call_graph` (recv `self`)
- *POSSIBLE* (support=11) `src/annotator/helpers/effects.rb:861` (func_call_suspends?) writes `.@fn_nodes` but NOT `.@call_graph` (recv `self`)
- *POSSIBLE* (support=11) `src/annotator/helpers/effects.rb:1087` (mutually_recursive_in_call_graph?) writes `.@call_graph` but NOT `.@fn_nodes` (recv `self`)
- *POSSIBLE* (support=11) `src/annotator/helpers/effects.rb:1097` (reachable_in_call_graph?) writes `.@call_graph` but NOT `.@fn_nodes` (recv `self`)
- *POSSIBLE* (support=11) `src/annotator/helpers/effects.rb:1155` (validate_tight_node!) writes `.@fn_nodes` but NOT `.@call_graph` (recv `self`)
- *POSSIBLE* (support=11) `src/annotator/helpers/function_analysis.rb:98` (resolve_call) writes `.@fn_nodes` but NOT `.@call_graph` (recv `self`)
- *POSSIBLE* (support=11) `src/annotator/helpers/lock_helper.rb:213` (propagate_lock_acquires!) writes `.@call_graph` but NOT `.@fn_nodes` (recv `self`)
- *POSSIBLE* (support=11) `src/annotator/helpers/pipe_analysis.rb:148` (has_catch_blocks?) writes `.@fn_nodes` but NOT `.@call_graph` (recv `self`)
- *POSSIBLE* (support=11) `src/annotator/helpers/reentrance.rb:224` (validate_not_logical_recursion!) writes `.@fn_nodes` but NOT `.@call_graph` (recv `self`)
- *POSSIBLE* (support=11) `src/annotator/helpers/reentrance.rb:259` (validate_max_depth_mutual_cycle!) writes `.@fn_nodes` but NOT `.@call_graph` (recv `self`)
- *POSSIBLE* (support=11) `src/annotator/helpers/reentrance.rb:354` (try_stamp_mutual_thunk_plan!) writes `.@fn_nodes` but NOT `.@call_graph` (recv `self`)
- *POSSIBLE* (support=11) `src/annotator/helpers/reentrance.rb:414` (emit_mutual_thunk_unsupported!) writes `.@fn_nodes` but NOT `.@call_graph` (recv `self`)
- *POSSIBLE* (support=11) `src/mir/lowering/functions.rb:1408` (call_never_returns_success?) writes `.@fn_nodes` but NOT `.@call_graph` (recv `self`)
- *POSSIBLE* (support=11) `src/mir/mir_lowering.rb:1954` (lower_program) writes `.@fn_nodes` but NOT `.@call_graph` (recv `self`)
- *POSSIBLE* (support=11) `src/mir/mir_pass.rb:52` (initialize) writes `.@fn_nodes` but NOT `.@call_graph` (recv `self`)
- *POSSIBLE* (support=10) `src/ast/scope.rb:40` (declare) writes `.scope` but NOT `.@tmp_counter` (recv `entry`)
- *POSSIBLE* (support=10) `src/ast/scope.rb:88` (initialize_copy) writes `.scope` but NOT `.@tmp_counter` (recv `new_entry`)
- *POSSIBLE* (support=10) `src/backends/pipeline_host.rb:555` (lower_pipeline_block) writes `.scope` but NOT `.@tmp_counter` (recv `mark`)
- *POSSIBLE* (support=10) `src/backends/pipeline_host.rb:647` (owning_pipeline_temp_stmts) writes `.scope` but NOT `.@tmp_counter` (recv `mark`)
- ...(+1963 more)

## Derived-State Staleness (149)
_b = f(a); a later reassigned, b not recomputed -- *POSSIBLE* bug_

- *POSSIBLE* `src/ast/ast.rb:915` (finalize_storage!): `value_sync` derived from `vt` (line 915); `vt` reassigned line 990, `value_sync` not recomputed
- *POSSIBLE* `src/tools/doctor.rb:164` (section_heap): `addrs` derived from `sites` (line 164); `sites` reassigned line 224, `addrs` not recomputed
- *POSSIBLE* `src/ast/type.rb:2338` (compute_zig_type): `inner_zig` derived from `base_zig` (line 2338); `base_zig` reassigned line 2392, `inner_zig` not recomputed
- *POSSIBLE* `src/annotator/annotator.rb:2100` (visit_ReturnNode): `expected_void_compatible` derived from `expected` (line 2100); `expected` reassigned line 2153, `expected_void_compatible` not recomputed
- *POSSIBLE* `src/annotator/helpers/capabilities.rb:194` (validate_capability): `atomic_ptr_ok` derived from `syn` (line 194); `syn` reassigned line 240, `atomic_ptr_ok` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:2817` (needs_space?): `a_is_struct_open` derived from `a_idx` (line 2817); `a_idx` reassigned line 2861, `a_is_struct_open` not recomputed
- *POSSIBLE* `src/mir/lowering/expressions.rb:489` (lower_smooth): `call` derived from `left` (line 489); `left` reassigned line 532, `call` not recomputed
- *POSSIBLE* `src/ast/ast.rb:920` (finalize_storage!): `t` derived from `val_ti` (line 920); `val_ti` reassigned line 960, `t` not recomputed
- *POSSIBLE* `src/mir/lowering/literals.rb:77` (lower_list_lit): `promise_zig` derived from `elem_zig` (line 77); `elem_zig` reassigned line 107, `promise_zig` not recomputed
- *POSSIBLE* `src/annotator/helpers/capabilities.rb:839` (declare_capability_scope!): `inner` derived from `st` (line 839); `st` reassigned line 867, `inner` not recomputed
- *POSSIBLE* `src/backends/pipeline_host.rb:347` (substitute_placeholders): `new_mc` derived from `new_target` (line 347); `new_target` reassigned line 374, `new_mc` not recomputed
- *POSSIBLE* `src/mir/lowering/expressions.rb:505` (lower_smooth): `left_effect` derived from `left` (line 505); `left` reassigned line 532, `left_effect` not recomputed
- *POSSIBLE* `src/ast/diagnostic_examples.rb:92` (scan_file): `j` derived from `i` (line 92); `i` reassigned line 117, `j` not recomputed
- *POSSIBLE* `src/backends/pipeline_rewriter.rb:561` (build_recursive_body): `skip_if` derived from `cond` (line 561); `cond` reassigned line 586, `skip_if` not recomputed
- *POSSIBLE* `src/annotator/helpers/generic_analysis.rb:223` (validate_type_annotation!): `expected` derived from `schema` (line 223); `schema` reassigned line 247, `expected` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:2264` (find_s_chains): `s_idxs` derived from `i` (line 2264); `i` reassigned line 2288, `s_idxs` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:1183` (branch_end_for_inline_expansion): `t` derived from `j` (line 1183); `j` reassigned line 1206, `t` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:2266` (find_s_chains): `j` derived from `i` (line 2266); `i` reassigned line 2288, `j` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:1636` (expand_concurrent_drops): `t` derived from `i` (line 1636); `i` reassigned line 1655, `t` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:2933` (capability_chain_colon?): `t` derived from `j` (line 2933); `j` reassigned line 2952, `t` not recomputed
- *POSSIBLE* `src/mir/lowering/functions.rb:951` (cross_boundary_arg): `moved_arg` derived from `arg` (line 951); `arg` reassigned line 969, `moved_arg` not recomputed
- *POSSIBLE* `src/ast/type.rb:2164` (parse_raw_input): `inner` derived from `match` (line 2164); `match` reassigned line 2181, `inner` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:1118` (find_fn_arrow): `t` derived from `j` (line 1118); `j` reassigned line 1135, `t` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:1638` (expand_concurrent_drops): `paren_open` derived from `i` (line 1638); `i` reassigned line 1655, `paren_open` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:2935` (capability_chain_colon?): `k` derived from `j` (line 2935); `j` reassigned line 2952, `k` not recomputed
- ...(+124 more)

## Neglected Conditions (10)
_dispatch/conjunction minus one element -- *POSSIBLE* bug_

- *POSSIBLE* (support=5) `src/tools/formatter.rb:1260` (one_liner_end) -- MISSING `'START'` from `'END' | 'FN' | 'FOR' | 'IF' | 'START' | 'TEST' | 'WHEN' | 'WHILE'`
- *POSSIBLE* (support=5) `src/tools/formatter.rb:1332` (expand_if_while_for) -- MISSING `'START'` from `'END' | 'FN' | 'FOR' | 'IF' | 'START' | 'TEST' | 'WHEN' | 'WHILE'`
- *POSSIBLE* (support=4) `src/mir/local_binding_facts.rb:78` (binding_decl_name) -- MISSING `AST::Assignment` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- *POSSIBLE* (support=4) `src/mir/local_binding_facts.rb:90` (binding_entry) -- MISSING `AST::Assignment` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- *POSSIBLE* (support=4) `src/mir/lowering/capabilities.rb:154` (build_field_path_zig) -- MISSING `AST::GetIndex` from `AST::GetField | AST::GetIndex | AST::Identifier`
- *POSSIBLE* (support=4) `src/tools/atomic_migration_suggester.rb:133` (stmt_eligible?) -- MISSING `AST::VarDecl` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- *POSSIBLE* (support=4) `src/tools/atomic_ptr_migration_suggester.rb:120` (stmt_eligible?) -- MISSING `AST::VarDecl` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- *POSSIBLE* (support=3) `src/mir/cleanup_classifier.rb:675` (finalize_alloc_from_storage!) -- MISSING `decl.symbol` from `decl | decl.respond_to?(:symbol) | decl.symbol`
- *POSSIBLE* (support=3) `src/mir/cleanup_classifier.rb:802` (container_alloc_from) -- MISSING `decl.symbol` from `decl | decl.respond_to?(:symbol) | decl.symbol`
- *POSSIBLE* (support=3) `src/mir/fsm_transform/recursive_splitter.rb:373` (emit_pivot) -- MISSING `AST::CatchBlock` from `AST::CatchBlock | AST::ForEach | AST::ForRange | AST::IfStatement | AST::WhileBindLoop | AST::WhileLoop | AST::WithBlock`

## Neglected Path Conditions (1858)
_nested-if/&& guard set minus one atom -- *POSSIBLE* bug (noisy)_

- *POSSIBLE* (support=36) `src/tools/formatter.rb:507` (match_block_start?) -- MISSING `!bracket_open?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:533` (find_match_block_end) -- MISSING `!bracket_open?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:585` (scan_match_arms) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:585` (scan_match_arms) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:737` (emit_match_body) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:737` (emit_match_body) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:952` (emit_fn_signature_wrapped) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:952` (emit_fn_signature_wrapped) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:1067` (emit_fn_params_only_wrapped) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:1067` (emit_fn_params_only_wrapped) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:1187` (branch_end_for_inline_expansion) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:1187` (branch_end_for_inline_expansion) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:1232` (matching_end) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:1232` (matching_end) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:1607` (consume_on_segment) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:1607` (consume_on_segment) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:1982` (emit_wrapped_args) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:1982` (emit_wrapped_args) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:2057` (body_has_top_level_block?) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:2057` (body_has_top_level_block?) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:2158` (emit_bg_do_wrapped) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:2158` (emit_bg_do_wrapped) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:2208` (bg_body_has_strategy_arrow?) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=36) `src/tools/formatter.rb:2208` (bg_body_has_strategy_arrow?) -- MISSING `bracket_close?(t.raw)` from `!bracket_open?(t.raw) | bracket_close?(t.raw) | t.type == :SYM`
- *POSSIBLE* (support=25) `src/mir/fsm_lowering.rb:141` (lower_step_stmts) -- MISSING `!last_is_assign || is_step_void` from `!last_is_assign || is_step_void | !no_result | last_mir | last_step`
- ...(+1833 more)

## Broken Protocols (1461)
_co-called pair, one site does A without B -- *POSSIBLE* bug (noisy)_

- *POSSIBLE* conf=0.98 support=48 `src/ast/ast.rb:698` (column) does `column` without `line`
- *POSSIBLE* conf=0.98 support=44 `src/ast/parser.rb:1814` (parse_binary_op) does `parse_expression` without `consume`
- *POSSIBLE* conf=0.96 support=48 `src/backends/pipeline_host.rb:3356` (default_obs_alloc_zig) does `transpile_type` without `new`
- *POSSIBLE* conf=0.96 support=48 `src/mir/mir_lowering.rb:2855` (bare_zig_type) does `transpile_type` without `new`
- *POSSIBLE* conf=0.96 support=27 `src/annotator/annotator.rb:1307` (visit_IfStatement) does `proc` without `[]`
- *POSSIBLE* conf=0.96 support=22 `src/annotator/annotator.rb:918` (validate_and_resolve_sync_policy!) does `statements` without `each`
- *POSSIBLE* conf=0.95 support=36 `src/ast/parser.rb:524` (match_literal!) does `match!` without `consume`
- *POSSIBLE* conf=0.95 support=36 `src/ast/parser.rb:3560` (parse_error_selectors) does `match!` without `consume`
- *POSSIBLE* conf=0.95 support=36 `src/backends/pipeline_host.rb:197` (visit) does `visit_mir` without `new`
- *POSSIBLE* conf=0.95 support=36 `src/backends/pipeline_host.rb:866` (visit_pipeline_expr_mir) does `visit_mir` without `new`
- *POSSIBLE* conf=0.95 support=20 `src/annotator/annotator.rb:5616` (promote_to_expr_if!) does `else_branch` without `then_branch`
- *POSSIBLE* conf=0.95 support=20 `src/mir/mir_pass.rb:737` (stamp_if_bind_cleanup!) does `then_branch` without `else_branch`
- *POSSIBLE* conf=0.95 support=19 `src/annotator/helpers/pipe_analysis.rb:45` (finite_stream_source?) does `dynamic_stream?` without `inf_stream?`
- *POSSIBLE* conf=0.94 support=31 `src/annotator/helpers/function_analysis.rb:21` (analyze_routine) does `with_new_scope` without `current_scope`
- *POSSIBLE* conf=0.94 support=31 `src/annotator/helpers/test_annotation.rb:34` (visit_TestBlock) does `with_new_scope` without `current_scope`
- *POSSIBLE* conf=0.94 support=17 `src/annotator/helpers/pipe_analysis.rb:865` (analyze_skip_op) does `finite_stream_element_type` without `current_scope`
- *POSSIBLE* conf=0.94 support=17 `src/annotator/helpers/pipe_analysis.rb:865` (analyze_skip_op) does `finite_stream_element_type` without `declare`
- *POSSIBLE* conf=0.94 support=17 `src/annotator/helpers/pipe_analysis.rb:865` (analyze_skip_op) does `finite_stream_element_type` without `with_new_scope`
- *POSSIBLE* conf=0.94 support=17 `src/annotator/helpers/pipe_analysis.rb:1198` (analyze_auto_shard_each_op) does `finite_stream_element_type` without `right`
- *POSSIBLE* conf=0.94 support=17 `src/annotator/helpers/pipe_analysis.rb:1723` (analyze_concurrent_stream_each_op) does `finite_stream_element_type` without `resolved_type`
- *POSSIBLE* conf=0.94 support=17 `src/mir/lowering/variables.rb:150` (lower_var_decl) does `with_decl_alloc` without `lower`
- *POSSIBLE* conf=0.94 support=17 `src/mir/lowering/variables.rb:1295` (auto_lock_assignment_value) does `with_decl_alloc` without `new`
- *POSSIBLE* conf=0.94 support=16 `src/annotator/helpers/intrinsic_emit.rb:21` ((top-level)) does `type_alias` without `returns`
- *POSSIBLE* conf=0.94 support=16 `src/annotator/helpers/pipe_analysis.rb:1416` (numeric_literal_value) does `to_f` without `[]`
- *POSSIBLE* conf=0.94 support=16 `src/tools/formatter.rb:552` (emit_match_block) does `insert_nl` without `type`
- ...(+1436 more)

## False Simplicity (754)
_looks simple, behaves non-locally: hidden dispatch/mutation/IO/context/metaprogramming/monkeypatch -- *POSSIBLE* (noisy)_

- *POSSIBLE* [hidden_mutation] scatter=447 support=1252 `<<` -- `src/annotator/annotator.rb:82` (record_snapshot_txn_violation!) (+1245 more)
- *POSSIBLE* [hidden_mutation] scatter=254 support=431 `full_type!` -- `src/annotator/annotator.rb:75` (stamp_type!) (+421 more)
- *POSSIBLE* [hidden_mutation] scatter=246 support=500 `[]=` -- `src/annotator/annotator.rb:270` (emit_auto_shape_resolved_findings!) (+498 more)
- *POSSIBLE* [hidden_mutation] scatter=210 support=406 `error!` -- `src/annotator/annotator.rb:192` (annotate!) (+405 more)
- *POSSIBLE* [hidden_mutation] scatter=128 support=203 `stamp_type!` -- `src/annotator/annotator.rb:501` (visit_Program) (+202 more)
- *POSSIBLE* [hidden_mutation] scatter=78 support=88 `from_node!` -- `src/annotator/annotator.rb:4292` (visit_CopyNode) (+87 more)
- *POSSIBLE* [hidden_mutation] scatter=73 support=124 `op-assign` -- `src/annotator/annotator.rb:92` (with_conditional_context) (+123 more)
- *POSSIBLE* [hidden_mutation] scatter=64 support=93 `storage=` -- `src/annotator/annotator.rb:1298` (visit_BlockExpr) (+92 more)
- *POSSIBLE* [hidden_mutation] scatter=48 support=50 `fixable!` -- `src/annotator/annotator.rb:2733` (finalize_decl_node!) (+49 more)
- *POSSIBLE* [dynamic_dispatch] scatter=44 support=79 `instance_variable_get` -- `src/annotator/annotator.rb:2748` (finalize_decl_node!) (+78 more)
- *POSSIBLE* [dynamic_dispatch] scatter=39 support=65 `send` -- `src/annotator/annotator.rb:380` (visit) (+64 more)
- *POSSIBLE* [hidden_mutation] scatter=38 support=99 `match!` -- `src/ast/parser.rb:159` ((top-level)) (+98 more)
- *POSSIBLE* [hidden_io] scatter=35 support=41 `File.exist?` -- `src/ast/diagnostic_examples.rb:72` (load!) (+40 more)
- *POSSIBLE* [callback_inversion] scatter=33 support=36 `with_new_scope` -- `src/annotator/annotator.rb:849` (visit_FunctionDef) (+35 more)
- *POSSIBLE* [hidden_io] scatter=31 support=39 `File.join` -- `src/backends/importer.rb:64` (resolve_stdlib_package) (+38 more)
- *POSSIBLE* [dynamic_dispatch] scatter=29 support=34 `yield` -- `src/annotator/helpers/auto_inference.rb:745` (walk_for_shape_decls) (+33 more)
- *POSSIBLE* [hidden_mutation] scatter=28 support=30 `scope=` -- `src/ast/scope.rb:40` (declare) (+29 more)
- *POSSIBLE* [metaprogramming] scatter=24 support=66 `instance_variable_set` -- `src/annotator/annotator.rb:2379` (visit_FuncCall) (+65 more)
- *POSSIBLE* [callback_inversion] scatter=23 support=39 `with_pipeline_context` -- `src/backends/pipeline_host.rb:264` (visit_pipeline_body_mir) (+38 more)
- *POSSIBLE* [hidden_io] scatter=22 support=267 `puts` -- `src/backends/transpiler.rb:329` ((top-level)) (+266 more)
- *POSSIBLE* [hidden_mutation] scatter=22 support=34 `result_type=` -- `src/backends/pipeline_host.rb:2033` (lower_stream_index) (+33 more)
- *POSSIBLE* [dynamic_dispatch] scatter=22 support=23 `blk.call` -- `src/annotator/annotator.rb:94` (with_conditional_context) (+22 more)
- *POSSIBLE* [hidden_mutation] scatter=19 support=25 `emit_typo_suggestion!` -- `src/annotator/annotator.rb:1404` (annotate_struct_pattern!) (+24 more)
- *POSSIBLE* [hidden_mutation] scatter=18 support=28 `ownership=` -- `src/annotator/annotator.rb:1343` (visit_IfBind) (+27 more)
- *POSSIBLE* [hidden_mutation] scatter=18 support=23 `provenance=` -- `src/annotator/annotator.rb:3717` (visit_ListLit) (+22 more)
- ...(+729 more)

## Fat Unions (8)
_case dispatch over class consts whose arms read mostly variant-invariant members -- product-vs-sum decomposition candidate (extraction -> nil-kill) -- *POSSIBLE*_

- *POSSIBLE* [DEGENERATE: no variance] union `AST::Assignment | AST::BindExpr | AST::VarDecl` -- **3 common** vs 0 variant member(s), scatter=3 -- `src/mir/fsm_transform/liveness.rb:198` (collect_defs)
  - common: `is_a?, name, value` -> hoist to a struct, keep a SMALL union for `` (-> nil-kill)
- *POSSIBLE* [DEGENERATE: no variance] union `AST::AllOp | AST::AnyOp | AST::AverageOp | AST::CountOp | AST::FindOp | AST::MaxOp | AST::MinOp | AST::SumOp` -- **2 common** vs 0 variant member(s), scatter=4 -- `src/ast/ast.rb:1834` (pipeline_range_fold?)
  - common: `class, expression` -> hoist to a struct, keep a SMALL union for `` (-> nil-kill)
- *POSSIBLE* [DEGENERATE: no variance] union `AST::IndexOp | AST::OrderByOp | AST::SelectOp | AST::WhereOp` -- **2 common** vs 0 variant member(s), scatter=1 -- `src/annotator/helpers/pipe_analysis.rb:316` (analyze_select_family_op)
  - common: `expression, is_a?` -> hoist to a struct, keep a SMALL union for `` (-> nil-kill)
- *POSSIBLE* union `MIR::AllocMark | MIR::BreakStmt | MIR::Cleanup | MIR::ErrCleanup | MIR::FieldCleanupMark | MIR::MoveMark | MIR::OwnedBorrow | MIR::OwnedCreate | MIR::OwnedDestroy | MIR::OwnedReturn | MIR::OwnedStore | MIR::OwnedTransfer | MIR::Panic | MIR::ReassignMark | MIR::ReturnMark | MIR::ReturnStmt | MIR::TransferMark` -- **19 common** vs 3 variant member(s), scatter=1 -- `src/mir/mir_checker.rb:467` (check_linear_stmt!)
  - common: `arms, bindings, body, branch_bodies, branches, class, clause_bodies, cond` -> hoist to a struct, keep a SMALL union for `cleanup_entry, target, target_alloc` (-> nil-kill)
- *POSSIBLE* union `Array | FalseClass | Hash | Numeric | String | Symbol | TrueClass | Type` -- **6 common** vs 4 variant member(s), scatter=2 -- `src/annotator/annotator.rb:281` (program_has_auto?)
  - common: `each_pair, nil?, params, respond_to?, return_type, type` -> hoist to a struct, keep a SMALL union for `any?, auto?, each, each_value` (-> nil-kill)
- *POSSIBLE* union `AST::EnumDef | AST::StructDef | AST::UnionDef` -- **4 common** vs 2 variant member(s), scatter=3 -- `src/backends/compiler_frontend.rb:87` (compile)
  - common: `is_a?, name, variants, visibility` -> hoist to a struct, keep a SMALL union for `field_decls, type_params` (-> nil-kill)
- *POSSIBLE* union `AST::ForEach | AST::ForRange | AST::IfStatement | AST::MatchStatement | AST::WhileLoop` -- **5 common** vs 2 variant member(s), scatter=1 -- `src/mir/control_flow.rb:765` (transfer_stmt)
  - common: `is_a?, mode, name, value, var_name` -> hoist to a struct, keep a SMALL union for `collection, expr` (-> nil-kill)
- *POSSIBLE* union `MIR::BlockExpr | MIR::Ident | MIR::InlineZig | MIR::RawZig` -- **2 common** vs 1 variant member(s), scatter=1 -- `src/mir/mir_checker.rb:902` (collect_linear_expr_ident_names)
  - common: `child_exprs, is_a?` -> hoist to a struct, keep a SMALL union for `name` (-> nil-kill)

## Run Summary
- Files analyzed: 111
- Detectors: 14 (all shipped, self-tested)
- Convergence: 1366 unit(s) flagged by >=2 independent detectors
- Root-cause clusters: 330 (one fix collapses each)
- Total candidates: 6867
- Method: stdlib AST only, intra-procedural, zero deps, no CFG / no points-to; Flay similarity is an optional external signal consumed read-only (see docs/agents/design.md)
