# Decomplex Report

> Decision-level duplication and neglected-condition analysis.
> Every entry is a ranked **candidate** (Engler's discipline),
> never a verdict -- *POSSIBLE* findings, triaged by a human.
> Sections are ordered by SIGNAL TIER (1 = lowest false
> positive), not by volume. Items within a section are
> frequency-ranked. Triage tier 1, top-of-list, first.

## Table of Contents
- [Project Prioritization](#project-prioritization)
- [Cross-Detector Convergence (1262)](#cross-detector-convergence-1262)
- [Root-Cause Clusters (327)](#root-cause-clusters-327)
- [Decision Pressure (279)](#decision-pressure-279)
- [Missing Abstractions (200)](#missing-abstractions-200)
- [Reification Misses (3)](#reification-misses-3)
- [Semantic Predicate Aliases (3)](#semantic-predicate-aliases-3)
- [Exact Predicate Aliases (6)](#exact-predicate-aliases-6)
- [Type-3 Clones (missed rename) (16)](#type3-clones-missed-rename-16)
- [Neglected Updates (5769)](#neglected-updates-5769)
- [Derived-State Staleness (150)](#derivedstate-staleness-150)
- [Neglected Conditions (11)](#neglected-conditions-11)
- [Neglected Path Conditions (2069)](#neglected-path-conditions-2069)
- [Broken Protocols (1534)](#broken-protocols-1534)
- [False Simplicity (696)](#false-simplicity-696)
- [Fat Unions (8)](#fat-unions-8)
- [Run Summary](#run-summary)

## Project Prioritization
_Ordered by signal tier (1 = highest signal / lowest FP), then by volume._

- **[tier 1]** [Decision Pressure (279)](#decision-pressure-279): ELIMINABLE guard-pressure per loose contract (nil/is_a?/respond_to?/safe-nav/rescue-nil) -> tighten the contract once / nil-kill: DELETE. essential dispatch + pure c-uses are split out, NEVER summed (Rapps-Weyuker p-use; McCabe)
- **[tier 1]** [Missing Abstractions (200)](#missing-abstractions-200): guard tuple recomputed across >=2 decision units
- **[tier 1]** [Exact Predicate Aliases (6)](#exact-predicate-aliases-6): identical one-line predicate body under >=2 names
- **[tier 1]** [Reification Misses (3)](#reification-misses-3): an existing predicate reinvented inline -- invariant #16
- **[tier 1]** [Semantic Predicate Aliases (3)](#semantic-predicate-aliases-3): one decision, multiple names (receiver/polarity folded)
- **[tier 2]** [Neglected Updates (5769)](#neglected-updates-5769): co-written state, one write missing -- *POSSIBLE* redundant-state desync
- **[tier 2]** [Derived-State Staleness (150)](#derivedstate-staleness-150): b = f(a); a later reassigned, b not recomputed -- *POSSIBLE* bug
- **[tier 2]** [Type-3 Clones (missed rename) (16)](#type3-clones-missed-rename-16): pasted block, one identifier inconsistently renamed -- *POSSIBLE* bug
- **[tier 2]** [Neglected Conditions (11)](#neglected-conditions-11): dispatch/conjunction minus one element -- *POSSIBLE* bug
- **[tier 3]** [Neglected Path Conditions (2069)](#neglected-path-conditions-2069): nested-if/&& guard set minus one atom -- *POSSIBLE* bug (noisy)
- **[tier 3]** [Broken Protocols (1534)](#broken-protocols-1534): co-called pair, one site does A without B -- *POSSIBLE* bug (noisy)
- **[tier 3]** [False Simplicity (696)](#false-simplicity-696): looks simple, behaves non-locally: hidden dispatch/mutation/IO/context/metaprogramming/monkeypatch -- *POSSIBLE* (noisy)
- **[tier 3]** [Fat Unions (8)](#fat-unions-8): case dispatch over class consts whose arms read mostly variant-invariant members -- product-vs-sum decomposition candidate (extraction -> nil-kill) -- *POSSIBLE*

## Cross-Detector Convergence (1262)
_(file, method) units flagged by >=2 INDEPENDENT detectors -- the strongest triage signal: agreement outranks any single detector's volume. Tier-weighted (1=3, 2=2, 3=1). **Start here.**_

- `src/annotator-helpers/function_analysis.rb:193` (resolve_call) -- **7 detectors** [score 13, 189 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/annotator.rb:5471` (handle_assign_move) -- **7 detectors** [score 13, 44 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/annotator-helpers/pipe_analysis.rb:805` (analyze_pipe_to_named_function) -- **7 detectors** [score 13, 41 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/ast/parser.rb:2839` (parse_type_annotation) -- **6 detectors** [score 12, 79 findings]: Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions, Neglected Updates, Reification Misses
- `src/annotator.rb:1459` (visit_MatchStatement) -- **6 detectors** [score 11, 219 findings]: Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/mir/lowering/functions.rb:261` (lower_function_def) -- **6 detectors** [score 11, 122 findings]: Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/annotator.rb:4739` (visit_WithBlock) -- **6 detectors** [score 11, 115 findings]: Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/annotator-helpers/pipe_analysis.rb:1462` (analyze_concurrent_op) -- **6 detectors** [score 11, 85 findings]: Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/annotator.rb:1907` (visit_WhileBindLoop) -- **6 detectors** [score 11, 62 findings]: Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/tools/formatter.rb:1358` (expand_if_while_for) -- **6 detectors** [score 11, 49 findings]: Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Conditions, Neglected Path Conditions, Type-3 Clones (missed rename)
- `src/annotator-helpers/generic_analysis.rb:227` (validate_type_annotation!) -- **6 detectors** [score 11, 47 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions
- `src/mir/lowering/control_flow.rb:803` (lower_return) -- **6 detectors** [score 11, 44 findings]: Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/tools/doctor.rb:164` (section_heap) -- **6 detectors** [score 11, 43 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions
- `src/annotator.rb:3602` (visit_StructLit) -- **6 detectors** [score 10, 122 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions, Neglected Updates
- `src/backends/pipeline_host.rb:287` (substitute_placeholders) -- **6 detectors** [score 10, 100 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions, Neglected Updates
- `src/annotator.rb:3357` (visit_GetField) -- **6 detectors** [score 10, 77 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions, Neglected Updates
- `src/ast/type.rb:2197` (compute_zig_type) -- **6 detectors** [score 10, 73 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions, Neglected Updates
- `src/mir/lowering/expressions.rb:359` (lower_smooth) -- **6 detectors** [score 10, 72 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions, Neglected Updates
- `src/mir/lowering/variables.rb:356` (build_var_decl_nodes) -- **6 detectors** [score 10, 72 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions, Neglected Updates
- `src/annotator-helpers/generic_analysis.rb:558` (propagate_collection_metadata!) -- **6 detectors** [score 10, 55 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions, Neglected Updates
- `src/annotator-helpers/pipe_analysis.rb:742` (analyze_pipe_to_func_call) -- **6 detectors** [score 10, 39 findings]: Broken Protocols, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/mir/lowering/literals.rb:161` (lower_hash_lit) -- **6 detectors** [score 10, 36 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions, Neglected Updates
- `src/ast/ast.rb:783` (finalize_storage!) -- **5 detectors** [score 11, 76 findings]: Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Updates
- `src/annotator.rb:3963` (visit_OrRescue) -- **5 detectors** [score 11, 60 findings]: Decision Pressure, False Simplicity, Missing Abstractions, Neglected Updates, Type-3 Clones (missed rename)
- `src/annotator.rb:2842` (visit_BindExpr) -- **5 detectors** [score 10, 80 findings]: Decision Pressure, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- ...(+1237 more)

### By file
- `src/annotator.rb` -- 12 detectors across 150 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, Exact Predicate Aliases, False Simplicity, Fat Unions, Missing Abstractions, Neglected Conditions, Neglected Path Conditions, Neglected Updates, Reification Misses, Type-3 Clones (missed rename)
- `src/ast/ast.rb` -- 10 detectors across 19 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, Exact Predicate Aliases, False Simplicity, Fat Unions, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Semantic Predicate Aliases
- `src/annotator-helpers/pipe_analysis.rb` -- 8 detectors across 51 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Fat Unions, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/mir/mir_lowering.rb` -- 8 detectors across 58 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Fat Unions, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/backends/pipeline_host.rb` -- 8 detectors across 57 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Fat Unions, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/tools/formatter.rb` -- 8 detectors across 59 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Conditions, Neglected Path Conditions, Type-3 Clones (missed rename)
- `src/mir/hoist.rb` -- 8 detectors across 36 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Type-3 Clones (missed rename)
- `src/ast/parser.rb` -- 8 detectors across 56 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Reification Misses
- `src/annotator-helpers/auto_inference.rb` -- 8 detectors across 18 method(s): Broken Protocols, Decision Pressure, Exact Predicate Aliases, False Simplicity, Fat Unions, Missing Abstractions, Neglected Updates, Semantic Predicate Aliases
- `src/mir/escape_analysis.rb` -- 7 detectors across 42 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/mir/lowering/expressions.rb` -- 7 detectors across 31 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/mir/lowering/control_flow.rb` -- 7 detectors across 29 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/mir/lowering/functions.rb` -- 7 detectors across 31 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/ast/type.rb` -- 7 detectors across 30 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/mir/control_flow.rb` -- 7 detectors across 30 method(s): Broken Protocols, Decision Pressure, False Simplicity, Fat Unions, Missing Abstractions, Neglected Path Conditions, Neglected Updates

## Root-Cause Clusters (327)
_Findings across >=2 INDEPENDENT detectors that name the SAME entity -- 'N findings are really one invariant'. Convergence says where to look; this says **what one fix collapses the cluster**. Ranked candidate, not a verdict._

- **[name]** `expr` -- **6 detectors** [score 12] across 33 unit(s), 78 findings: Broken Protocols, Decision Pressure, Exact Predicate Aliases, False Simplicity, Neglected Path Conditions, Semantic Predicate Aliases
  - FIX: pair the protocol (RAII / ensure); the unpaired site is the deviant
  - `src/annotator.rb:1325` (visit_IfBind) ; `src/annotator.rb:1459` (visit_MatchStatement) ; `src/annotator.rb:5350` (visit_NextExpr) ; `src/annotator.rb:5368` (visit_NextExpr)
- **[name]** `symbol` -- **6 detectors** [score 10] across 199 unit(s), 144 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Conditions, Neglected Path Conditions, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator-helpers/capabilities.rb:96` (cap_var_sync) ; `src/annotator-helpers/capabilities.rb:115` (cap_var_layout) ; `src/annotator-helpers/capabilities.rb:139` (validate_capability) ; `src/annotator-helpers/capabilities.rb:161` (validate_capability)
- **[name]** `sync` -- **5 detectors** [score 10] across 180 unit(s), 277 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Updates, Reification Misses
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator-helpers/function_analysis.rb:216` (resolve_call) ; `src/annotator-helpers/generic_analysis.rb:453` (generic_type_has_capabilities?) ; `src/annotator-helpers/pipe_analysis.rb:1165` (collect_sharded_names) ; `src/annotator-helpers/pipe_analysis.rb:1186` (pre_scan_node_for_sharded)
- **[name]** `layout` -- **5 detectors** [score 10] across 170 unit(s), 226 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Updates, Reification Misses
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator-helpers/function_analysis.rb:221` (resolve_call) ; `src/annotator-helpers/generic_analysis.rb:454` (generic_type_has_capabilities?) ; `src/ast/type.rb:2256` (compute_zig_type) ; `src/ast/parser.rb:2936` (parse_type_annotation)
- **[name]** `line` -- **5 detectors** [score 9] across 10 unit(s), 19 findings: Broken Protocols, Decision Pressure, Derived-State Staleness, Neglected Path Conditions, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/tools/doctor.rb:607` (task_site_metadata) ; `src/tools/doctor.rb:620` (source_line) ; `src/ast/lexer.rb:40` (initialize) ; `src/ast/lexer.rb:311` (advance_pos)
- **[name]** `full_type` -- **5 detectors** [score 8] across 241 unit(s), 4118 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Path Conditions, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator-helpers/capabilities.rb:107` (cap_var_storage) ; `src/annotator-helpers/capabilities.rb:183` (validate_capability) ; `src/annotator-helpers/capabilities.rb:190` (validate_capability) ; `src/annotator-helpers/capabilities.rb:740` (acquire_capability!)
- **[name]** `type` -- **5 detectors** [score 8] across 180 unit(s), 212 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Path Conditions, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator-helpers/auto_inference.rb:213` (record_local) ; `src/annotator-helpers/auto_inference.rb:507` (stamp_map_pairs!) ; `src/annotator-helpers/auto_inference.rb:508` (stamp_map_pairs!) ; `src/annotator-helpers/auto_inference.rb:575` (walk_for_shape_decls)
- **[name]** `value` -- **5 detectors** [score 8] across 94 unit(s), 57 findings: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator-helpers/auto_inference.rb:763` (walk_binops) ; `src/annotator-helpers/capabilities.rb:1070` (_unified_capture_walk) ; `src/annotator-helpers/capabilities.rb:1074` (_unified_capture_walk) ; `src/annotator-helpers/capabilities.rb:1082` (_unified_capture_walk)
- **[name]** `collection` -- **5 detectors** [score 8] across 44 unit(s), 85 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Path Conditions, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator-helpers/function_analysis.rb:226` (resolve_call) ; `src/mir/fsm_transform.rb:178` (collect_body_locals) ; `src/mir/lowering/control_flow.rb:463` (for_each_loop_stmt) ; `src/mir/lowering/control_flow.rb:464` (for_each_loop_stmt)
- **[name]** `state` -- **5 detectors** [score 8] across 10 unit(s), 19 findings: Broken Protocols, False Simplicity, Neglected Path Conditions, Neglected Updates, Reification Misses
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator.rb:1250` (analyze_control_flow_branches) ; `src/annotator.rb:6642` (og_set_live) ; `src/mir/ownership_graph.rb:164` (drop) ; `src/mir/ownership_graph.rb:330` (record_move_site)
- **[name]** `target` -- **4 detectors** [score 8] across 71 unit(s), 98 findings: Decision Pressure, Derived-State Staleness, Neglected Path Conditions, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator-helpers/auto_inference.rb:658` (record_index_assign) ; `src/annotator-helpers/capabilities.rb:762` (cap_var_name) ; `src/annotator-helpers/function_analysis.rb:931` (verify_return) ; `src/annotator-helpers/generic_analysis.rb:618` (find_container_source)
- **[name]** `union` -- **4 detectors** [score 8] across 25 unit(s), 31 findings: Broken Protocols, Exact Predicate Aliases, Neglected Path Conditions, Semantic Predicate Aliases
  - FIX: pair the protocol (RAII / ensure); the unpaired site is the deviant
  - `src/ast/schemas.rb:34` (enum?) ; `src/ast/schemas.rb:67` (resource?) ; `src/ast/schemas.rb:123` (union?) ; `src/ast/schemas.rb:169` (struct?)
- **[name]** `struct` -- **4 detectors** [score 8] across 21 unit(s), 25 findings: Broken Protocols, Exact Predicate Aliases, Neglected Path Conditions, Semantic Predicate Aliases
  - FIX: pair the protocol (RAII / ensure); the unpaired site is the deviant
  - `src/ast/schemas.rb:34` (enum?) ; `src/ast/schemas.rb:67` (resource?) ; `src/ast/schemas.rb:123` (union?) ; `src/ast/schemas.rb:169` (struct?)
- **[name]** `provenance` -- **4 detectors** [score 7] across 174 unit(s), 324 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator-helpers/function_analysis.rb:211` (resolve_call) ; `src/annotator-helpers/generic_analysis.rb:365` (apply_type_subst) ; `src/annotator-helpers/generic_analysis.rb:556` (propagate_collection_metadata!) ; `src/annotator-helpers/method_analysis.rb:49` (narrow_collection_type!)
- **[name]** `ownership` -- **4 detectors** [score 7] across 168 unit(s), 283 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator-helpers/function_analysis.rb:207` (resolve_call) ; `src/ast/type.rb:2248` (compute_zig_type) ; `src/ast/type.rb:2282` (compute_zig_type) ; `src/annotator-helpers/generic_analysis.rb:419` (generic_shared_payload_binding)
- **[name]** `shard_count` -- **4 detectors** [score 7] across 167 unit(s), 188 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/ast/type.rb:1054` (sharded?) ; `src/annotator-helpers/function_analysis.rb:213` (resolve_call) ; `src/annotator-helpers/generic_analysis.rb:420` (generic_shared_payload_binding) ; `src/annotator-helpers/generic_analysis.rb:533` (propagate_declared_type_to_value!)
- **[name]** `capture_analysis` -- **4 detectors** [score 7] across 164 unit(s), 201 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/mir/control_flow.rb:695` (resource_captures) ; `src/mir/control_flow.rb:967` (collect_bg_body_gives) ; `src/mir/control_flow.rb:1212` (check_stmt_reads) ; `src/mir/control_flow.rb:1213` (check_stmt_reads)
- **[name]** `coerced_type` -- **4 detectors** [score 7] across 156 unit(s), 208 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/mir/lowering/expressions.rb:799` (float_coercion?) ; `src/annotator-helpers/function_analysis.rb:150` (resolve_call) ; `src/annotator-helpers/function_analysis.rb:520` (verify_function_signature!) ; `src/annotator-helpers/function_analysis.rb:763` (declare_and_verify_params)
- **[name]** `zig_pattern` -- **4 detectors** [score 7] across 154 unit(s), 178 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/mir/lowering/functions.rb:1280` (lower_intrinsic) ; `src/annotator-helpers/function_analysis.rb:150` (resolve_call) ; `src/annotator-helpers/function_analysis.rb:763` (declare_and_verify_params) ; `src/annotator-helpers/generic_analysis.rb:523` (propagate_declared_type_to_value!)
- **[name]** `left` -- **4 detectors** [score 7] across 43 unit(s), 34 findings: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator-helpers/pipe_analysis.rb:66` (stamp_observable_terminal!) ; `src/annotator-helpers/pipe_analysis.rb:72` (stamp_observable_terminal!) ; `src/annotator-helpers/pipe_analysis.rb:257` (analyze_collect_op) ; `src/annotator-helpers/pipe_analysis.rb:608` (analyze_limit_op)
- ...(+307 more)

## Decision Pressure (279)
_ELIMINABLE guard-pressure per loose contract (nil/is_a?/respond_to?/safe-nav/rescue-nil) -> tighten the contract once / nil-kill: DELETE. essential dispatch + pure c-uses are split out, NEVER summed (Rapps-Weyuker p-use; McCabe)_

- `.full_type` -- ELIMINABLE guard-pressure **171** across 70 method(s) -> tighten contract / nil-kill: DELETE  (+125 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator-helpers/capabilities.rb:107` (cap_var_storage) ; `src/annotator-helpers/capabilities.rb:183` (validate_capability) ; `src/annotator-helpers/capabilities.rb:190` (validate_capability) ; `src/annotator-helpers/capabilities.rb:740` (acquire_capability!)
- `.value` -- ELIMINABLE guard-pressure **146** across 66 method(s) -> tighten contract / nil-kill: DELETE  (+12 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator-helpers/auto_inference.rb:763` (walk_binops) ; `src/annotator-helpers/capabilities.rb:1070` (_unified_capture_walk) ; `src/annotator-helpers/capabilities.rb:1074` (_unified_capture_walk) ; `src/annotator-helpers/capabilities.rb:1082` (_unified_capture_walk)
- `.symbol` -- ELIMINABLE guard-pressure **92** across 64 method(s) -> tighten contract / nil-kill: DELETE  (+16 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator-helpers/capabilities.rb:96` (cap_var_sync) ; `src/annotator-helpers/capabilities.rb:115` (cap_var_layout) ; `src/annotator-helpers/capabilities.rb:139` (validate_capability) ; `src/annotator-helpers/capabilities.rb:161` (validate_capability)
- `.emit` -- ELIMINABLE guard-pressure **71** across 22 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator-helpers/capabilities.rb:408` (predicate_impurity_reason) ; `src/annotator-helpers/capabilities.rb:410` (predicate_impurity_reason) ; `src/annotator-helpers/capabilities.rb:411` (predicate_impurity_reason) ; `src/annotator-helpers/effects.rb:830` (scan_suspend_points)
- `.target` -- ELIMINABLE guard-pressure **55** across 34 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator-helpers/auto_inference.rb:658` (record_index_assign) ; `src/annotator-helpers/capabilities.rb:762` (cap_var_name) ; `src/annotator-helpers/function_analysis.rb:931` (verify_return) ; `src/annotator-helpers/generic_analysis.rb:618` (find_container_source)
- `.name` -- ELIMINABLE guard-pressure **54** across 38 method(s) -> tighten contract / nil-kill: DELETE  (+3 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator-helpers/auto_inference.rb:656` (record_index_assign) ; `src/annotator-helpers/capabilities.rb:1055` (_unified_capture_walk) ; `src/annotator-helpers/capabilities.rb:1307` (_bg_walk) ; `src/annotator-helpers/generic_analysis.rb:603` (register_container_borrow!)
- `.left` -- ELIMINABLE guard-pressure **41** across 19 method(s) -> tighten contract / nil-kill: DELETE  (+3 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator-helpers/pipe_analysis.rb:66` (stamp_observable_terminal!) ; `src/annotator-helpers/pipe_analysis.rb:72` (stamp_observable_terminal!) ; `src/annotator-helpers/pipe_analysis.rb:257` (analyze_collect_op) ; `src/annotator-helpers/pipe_analysis.rb:608` (analyze_limit_op)
- `.right` -- ELIMINABLE guard-pressure **34** across 16 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator-helpers/effects.rb:1224` (scan_for_calls) ; `src/annotator-helpers/pipe_analysis.rb:27` (visit_Smooth) ; `src/annotator-helpers/pipe_analysis.rb:29` (visit_Smooth) ; `src/annotator-helpers/pipe_analysis.rb:282` (analyze_select_family_op)
- `.current_fn_ctx` -- ELIMINABLE guard-pressure **31** across 22 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator-helpers/capabilities.rb:1163` (_unified_capture_walk) ; `src/annotator-helpers/capabilities.rb:1200` (_unified_capture_walk) ; `src/annotator-helpers/capabilities.rb:1343` (record_capability_binding) ; `src/annotator-helpers/capabilities.rb:1351` (record_capability_binding)
- `.type` -- ELIMINABLE guard-pressure **30** across 24 method(s) -> tighten contract / nil-kill: DELETE  (+29 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator-helpers/auto_inference.rb:213` (record_local) ; `src/annotator-helpers/auto_inference.rb:507` (stamp_map_pairs!) ; `src/annotator-helpers/auto_inference.rb:508` (stamp_map_pairs!) ; `src/annotator-helpers/auto_inference.rb:575` (walk_for_shape_decls)
- `[name]` -- ELIMINABLE guard-pressure **28** across 26 method(s) -> tighten contract / nil-kill: DELETE  (+8 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator-helpers/fixable_helpers.rb:310` (emit_use_of_moved_error!) ; `src/annotator-helpers/fixable_helpers.rb:997` (emit_with_materialized_needs_tense!) ; `src/annotator-helpers/fixable_helpers.rb:1200` (build_decl_cap_insert_fix) ; `src/annotator-helpers/fixable_helpers.rb:1228` (build_decl_cap_replace_fix)
- `.last` -- ELIMINABLE guard-pressure **25** across 6 method(s) -> tighten contract / nil-kill: DELETE  (+2 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator.rb:5612` (expr_result_type) ; `src/annotator.rb:5614` (expr_result_type) ; `src/annotator.rb:5621` (expr_result_type) ; `src/annotator.rb:5621` (expr_result_type)
- `.token` -- ELIMINABLE guard-pressure **23** across 19 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator-helpers/capabilities.rb:1358` (record_capability_binding) ; `src/annotator-helpers/capabilities.rb:1359` (record_capability_binding) ; `src/mir/concurrency_checks.rb:80` (check_hold_across_yield!) ; `src/mir/concurrency_checks.rb:178` (check_reentrant!)
- `.element_type` -- ELIMINABLE guard-pressure **23** across 19 method(s) -> tighten contract / nil-kill: DELETE  (+5 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator-helpers/function_return.rb:83` (resolve) ; `src/annotator-helpers/generic_analysis.rb:182` (validate_type_annotation!) ; `src/annotator-helpers/method_analysis.rb:43` (narrow_collection_type!) ; `src/annotator-helpers/method_analysis.rb:128` (resolve_typed_method)
- `.expr` -- ELIMINABLE guard-pressure **23** across 13 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator.rb:1325` (visit_IfBind) ; `src/annotator.rb:1459` (visit_MatchStatement) ; `src/annotator.rb:5350` (visit_NextExpr) ; `src/annotator.rb:5368` (visit_NextExpr)
- `.arms` -- ELIMINABLE guard-pressure **21** across 13 method(s) -> tighten contract / nil-kill: DELETE  (+6 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator-helpers/capabilities.rb:1236` (_unified_capture_walk) ; `src/annotator-helpers/effects.rb:1356` (scan_for_raises) ; `src/annotator.rb:4566` (visit_WithBlock) ; `src/annotator.rb:4725` (visit_WithBlock)
- `.body` -- ELIMINABLE guard-pressure **19** across 16 method(s) -> tighten contract / nil-kill: DELETE  (+4 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator-helpers/capabilities.rb:1233` (_unified_capture_walk) ; `src/annotator.rb:6068` (init_value_contents_heap?) ; `src/annotator.rb:6070` (init_value_contents_heap?) ; `src/backends/pipeline_rewriter.rb:70` (rewrite_children!)
- `[:var_node]` -- ELIMINABLE guard-pressure **18** across 12 method(s) -> tighten contract / nil-kill: DELETE  (+2 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator-helpers/capabilities.rb:666` (acquire_capability!) ; `src/annotator-helpers/capabilities.rb:677` (acquire_capability!) ; `src/annotator-helpers/capabilities.rb:707` (acquire_capability!) ; `src/annotator-helpers/capabilities.rb:712` (acquire_capability!)
- `.type_params` -- ELIMINABLE guard-pressure **18** across 11 method(s) -> tighten contract / nil-kill: DELETE  (+2 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator-helpers/function_analysis.rb:159` (resolve_call) ; `src/annotator-helpers/generic_analysis.rb:235` (validate_type_annotation!) ; `src/annotator-helpers/generic_analysis.rb:246` (validate_type_annotation!) ; `src/annotator.rb:1120` (visit_StructDef)
- `.return_type` -- ELIMINABLE guard-pressure **17** across 10 method(s) -> tighten contract / nil-kill: DELETE  (+13 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator-helpers/capabilities.rb:564` (visit_post_clauses!) ; `src/annotator-helpers/function_analysis.rb:182` (resolve_call) ; `src/annotator-helpers/reentrance.rb:165` (validate_not_logical_return!) ; `src/annotator-helpers/reentrance.rb:167` (validate_not_logical_return!)
- `.capture_analysis` -- ELIMINABLE guard-pressure **16** across 11 method(s) -> tighten contract / nil-kill: DELETE
  - `src/mir/control_flow.rb:695` (resource_captures) ; `src/mir/control_flow.rb:967` (collect_bg_body_gives) ; `src/mir/control_flow.rb:1212` (check_stmt_reads) ; `src/mir/control_flow.rb:1213` (check_stmt_reads)
- `.stdlib_def` -- ELIMINABLE guard-pressure **15** across 8 method(s) -> tighten contract / nil-kill: DELETE  (+2 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/mir/lowering/variables.rb:542` (owned_return_transfer_binding?) ; `src/mir/lowering/variables.rb:543` (owned_return_transfer_binding?) ; `src/mir/mir.rb:2209` (ownership_effect) ; `src/mir/mir.rb:2210` (ownership_effect)
- `.payload_type` -- ELIMINABLE guard-pressure **15** across 3 method(s) -> tighten contract / nil-kill: DELETE  (+2 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator-helpers/function_analysis.rb:204` (resolve_call) ; `src/annotator-helpers/function_analysis.rb:207` (resolve_call) ; `src/annotator-helpers/function_analysis.rb:211` (resolve_call) ; `src/annotator-helpers/function_analysis.rb:212` (resolve_call)
- `@og` -- ELIMINABLE guard-pressure **14** across 6 method(s) -> tighten contract / nil-kill: DELETE  (+6 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator.rb:1216` (analyze_control_flow_branches) ; `src/annotator.rb:1223` (analyze_control_flow_branches) ; `src/annotator.rb:1229` (analyze_control_flow_branches) ; `src/annotator.rb:1240` (analyze_control_flow_branches)
- `.alloc` -- ELIMINABLE guard-pressure **14** across 6 method(s) -> tighten contract / nil-kill: DELETE
  - `src/mir/lowering/variables.rb:267` (owned_binding_source_alloc) ; `src/mir/mir.rb:1287` (ownership_effect) ; `src/mir/mir.rb:1301` (ownership_effect) ; `src/mir/mir.rb:1315` (ownership_effect)
- ...(+254 more)

## Missing Abstractions (200)
_guard tuple recomputed across >=2 decision units_

- **[case_dispatch]** support=9 scatter=3 rank=27
  - tuple: `AST::GetField | AST::MethodCall`
  - `src/annotator.rb:1519` (visit_MatchStatement) ; `src/annotator.rb:1540` (visit_MatchStatement) ; `src/annotator.rb:1598` (visit_MatchStatement) ; `src/annotator.rb:1613` (visit_MatchStatement) ; `src/annotator.rb:1690` (visit_MatchStatement) ; `src/annotator.rb:1734` (visit_MatchStatement)
- **[conjunction]** support=5 scatter=5 rank=25
  - tuple: `node.is_a?(AST::BinaryOp) | node.op == :SMOOTH`
  - `src/annotator.rb:1079` (collect_pipe_input_types) ; `src/backends/pipeline_host.rb:2360` (unwrap_range_chain) ; `src/backends/pipeline_host.rb:2386` (unwrap_binding_unnest_chain) ; `src/backends/pipeline_rewriter.rb:35` (rewrite!) ; `src/backends/pipeline_rewriter.rb:262` (binding_source?)
- **[case_dispatch]** support=5 scatter=5 rank=25
  - tuple: `'END' | 'FN' | 'FOR' | 'IF' | 'START' | 'TEST' | 'WHEN' | 'WHILE'`
  - `src/tools/formatter.rb:535` (find_match_block_end) ; `src/tools/formatter.rb:599` (scan_match_arms) ; `src/tools/formatter.rb:639` (build_match_arm) ; `src/tools/formatter.rb:751` (emit_match_body) ; `src/tools/formatter.rb:1236` (matching_end)
- **[conjunction]** support=4 scatter=4 rank=16
  - tuple: `%w[true TRUE].include?(node.right.options["parallel"].name) | node.right.options["parallel"].is_a?(AST::Identifier)`
  - `src/annotator-helpers/pipe_analysis.rb:1646` (analyze_concurrent_bounded_select_family_op) ; `src/annotator-helpers/pipe_analysis.rb:1679` (analyze_concurrent_bounded_each_op) ; `src/annotator-helpers/pipe_analysis.rb:1709` (analyze_concurrent_stream_select_family_op) ; `src/annotator-helpers/pipe_analysis.rb:1745` (analyze_concurrent_stream_each_op)
- **[case_dispatch]** support=4 scatter=4 rank=16
  - tuple: `AST::AllOp | AST::AnyOp | AST::AverageOp | AST::CountOp | AST::FindOp | AST::MaxOp | AST::MinOp | AST::SumOp`
  - `src/ast/ast.rb:1711` (pipeline_range_fold?) ; `src/backends/pipeline_host.rb:943` (build_soa_scalar_fold_block) ; `src/backends/pipeline_host.rb:2537` (lower_binding_fold) ; `src/backends/pipeline_host.rb:3332` (lower_range_fold)
- **[conjunction]** support=4 scatter=4 rank=16
  - tuple: `j < toks.length | toks[j].type == :NL`
  - `src/tools/formatter.rb:887` (skip_nls) ; `src/tools/formatter.rb:2302` (detect_recover_stages) ; `src/tools/formatter.rb:2444` (emit_record_type) ; `src/tools/formatter.rb:2487` (emit_stmt_terminator)
- **[conjunction]** support=4 scatter=3 rank=12
  - tuple: `cursor.is_a?(AST::BinaryOp) | cursor.op == :SMOOTH`
  - `src/backends/pipeline_host.rb:2364` (unwrap_range_chain) ; `src/backends/pipeline_host.rb:2396` (unwrap_binding_unnest_chain) ; `src/backends/pipeline_host.rb:2407` (unwrap_binding_unnest_chain) ; `src/backends/pipeline_rewriter.rb:289` (collect_chain)
- **[case_dispatch]** support=4 scatter=3 rank=12
  - tuple: `AST::Assignment | AST::BindExpr | AST::VarDecl`
  - `src/mir/fsm_transform/liveness.rb:196` (collect_defs) ; `src/mir/mir_pass.rb:558` (collect_consumed_names) ; `src/mir/mir_pass.rb:578` (collect_consumed_names) ; `src/tools/migration_suggester_helpers.rb:88` (walk_recursive)
- **[conjunction]** support=4 scatter=3 rank=12
  - tuple: `bdepth.zero? | kdepth.zero?`
  - `src/tools/formatter.rb:588` (scan_match_arms) ; `src/tools/formatter.rb:629` (build_match_arm) ; `src/tools/formatter.rb:636` (build_match_arm) ; `src/tools/formatter.rb:743` (emit_match_body)
- **[case_dispatch]** support=3 scatter=3 rank=9
  - tuple: `:local | :param | :return`
  - `src/annotator-helpers/auto_inference.rb:476` (stamp_slot!) ; `src/annotator-helpers/fixable_helpers.rb:1587` (slot_id_for) ; `src/annotator-helpers/fixable_helpers.rb:1625` (auto_slot_label)
- **[case_dispatch]** support=3 scatter=3 rank=9
  - tuple: `AST::GetField | AST::GetIndex | AST::Identifier`
  - `src/annotator-helpers/capabilities.rb:759` (cap_var_name) ; `src/ast/ast.rb:325` (root_identifier) ; `src/ast/parser.rb:3954` (deep_clone_node)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `slot.respond_to?(:shape) | slot.shape`
  - `src/annotator-helpers/fixable_helpers.rb:1461` (emit_auto_resolved_finding!) ; `src/annotator-helpers/fixable_helpers.rb:1616` (auto_slot_label) ; `src/annotator.rb:245` (emit_auto_shape_resolved_findings!)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `sym.indirect? | sym.respond_to?(:layout)`
  - `src/annotator-helpers/function_analysis.rb:561` (atomic_cell_to_bare_value_param?) ; `src/annotator-helpers/function_analysis.rb:591` (atomic_cell_arg?) ; `src/annotator.rb:4942` (reject_bare_atomic_ptr_mutation!)
- **[case_dispatch]** support=3 scatter=3 rank=9
  - tuple: `:kind | :type`
  - `src/annotator-helpers/lock_helper.rb:414` (verify_handler_reachability!) ; `src/annotator-helpers/with_match_check.rb:420` (handled_error_set) ; `src/annotator.rb:5089` (resolve_error_selectors!)
- **[case_dispatch]** support=3 scatter=3 rank=9
  - tuple: `AST::SelectOp | AST::WhereOp`
  - `src/annotator-helpers/pipe_analysis.rb:1594` (analyze_concurrent_op) ; `src/annotator-helpers/pipe_analysis.rb:1664` (analyze_concurrent_bounded_select_family_op) ; `src/annotator-helpers/pipe_analysis.rb:1727` (analyze_concurrent_stream_select_family_op)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `!direct | reachable_from_self?(name)`
  - `src/annotator-helpers/reentrance.rb:235` (validate_not_logical_recursion!) ; `src/annotator-helpers/reentrance.rb:266` (validate_max_depth_mutual_cycle!) ; `src/annotator-helpers/reentrance.rb:320` (validate_thunk_recursion!)
- **[case_dispatch]** support=3 scatter=3 rank=9
  - tuple: `:block | :exit`
  - `src/annotator.rb:999` (visit_SyncPolicyDecl) ; `src/annotator.rb:5061` (validate_snapshot_match_arms!) ; `src/mir/lowering/capabilities.rb:518` (build_fallible_clause_mir)
- **[case_dispatch]** support=3 scatter=3 rank=9
  - tuple: `:ATOMIC | :LOCKED | :VERSIONED`
  - `src/annotator.rb:4638` (visit_WithBlock) ; `src/mir/lowering/capabilities.rb:560` (with_match_probe_for_family) ; `src/mir/lowering/capabilities.rb:625` (with_match_arm_prelude)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `node.is_a?(AST::FuncCall) | node.name == fn_name`
  - `src/annotator.rb:6327` (contains_self_call?) ; `src/mir/thunk_transform/recursive_splitter.rb:259` (direct_self_call) ; `src/mir/thunk_transform/recursive_splitter.rb:269` (contains_self_call?)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `!ti.is_a?(Type) | ti`
  - `src/annotator.rb:6578` (share_consumes_source?) ; `src/mir/lowering/expressions.rb:600` (materialize_or_fallback_value) ; `src/mir/mir_lowering.rb:213` (place_value_for_destination)
- **[case_dispatch]** support=3 scatter=3 rank=9
  - tuple: `AST::LimitOp | AST::SelectOp | AST::SkipOp | AST::TakeWhileOp | AST::TapOp | AST::WhereOp`
  - `src/ast/ast.rb:1679` (pipeline_fusible_stage?) ; `src/backends/pipeline_host.rb:2692` (build_lazy_range_prefix) ; `src/backends/pipeline_rewriter.rb:511` (build_recursive_body)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `atomic? | indirect?`
  - `src/ast/ast.rb:1778` (atomic_ptr?) ; `src/ast/symbol_entry.rb:147` (atomic_ptr?) ; `src/ast/type.rb:705` (atomic_ptr?)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `!source.empty? | source`
  - `src/ast/syntax_typo_scanner.rb:41` (scan!) ; `src/mir/lowering/capabilities.rb:894` (lower_pre_clauses) ; `src/mir/lowering/functions.rb:663` (build_post_outer_fn)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `!string? | array?`
  - `src/ast/type.rb:375` (escape_class) ; `src/ast/type.rb:851` (non_string_array?) ; `src/ast/type.rb:915` (dispatch_key)
- **[case_dispatch]** support=3 scatter=3 rank=9
  - tuple: `AST::EnumDef | AST::StructDef | AST::UnionDef`
  - `src/backends/compiler_frontend.rb:87` (compile) ; `src/backends/importer.rb:201` (compile_module_mir) ; `src/mir/mir_lowering.rb:1941` (visible_type_defs)
- ...(+175 more)

## Reification Misses (3)
_an existing predicate reinvented inline -- invariant #16_

- predicate `atomic?` reinvented inline at `src/ast/parser.rb:2936` (parse_type_annotation) (`sync == :atomic`)
- predicate `indirect?` reinvented inline at `src/ast/parser.rb:2936` (parse_type_annotation) (`layout == :indirect`)
- predicate `moved?` reinvented inline at `src/annotator.rb:1250` (analyze_control_flow_branches) (`state == :moved`)

## Semantic Predicate Aliases (3)
_one decision, multiple names (receiver/polarity folded)_

- `enum? = resource? = union? = struct? = needs_capture_site_annotation? = suspend? = mir? = stmt? = expr? = has_own_frame?` == `true`
  - `src/ast/schemas.rb:34` (enum?) ; `src/ast/schemas.rb:67` (resource?) ; `src/ast/schemas.rb:123` (union?) ; `src/ast/schemas.rb:169` (struct?) ; `src/mir/capture_strategy.rb:79` (needs_capture_site_annotation?) ; `src/mir/capture_strategy.rb:95` (needs_capture_site_annotation?) ; `src/mir/fsm_transform/segments.rb:51` (suspend?) ; `src/mir/fsm_transform/segments.rb:69` (suspend?) ; `src/mir/mir.rb:183` (mir?) ; `src/mir/mir.rb:199` (stmt?) ; `src/mir/mir.rb:221` (expr?) ; `src/mir/mir.rb:277` (has_own_frame?) ; `src/mir/mir.rb:573` (expr?) ; `src/mir/mir.rb:642` (expr?) ; `src/mir/mir.rb:663` (expr?) ; `src/mir/mir.rb:779` (expr?) ; `src/mir/mir.rb:790` (expr?) ; `src/mir/mir.rb:805` (expr?) ; `src/mir/mir.rb:841` (expr?) ; `src/mir/mir.rb:1561` (stmt?) ; `src/mir/mir.rb:1593` (stmt?) ; `src/mir/mir.rb:1615` (stmt?) ; `src/mir/mir.rb:1642` (stmt?) ; `src/mir/mir.rb:1651` (stmt?) ; `src/mir/mir.rb:1665` (stmt?) ; `src/mir/mir.rb:1677` (stmt?) ; `src/mir/mir.rb:1693` (stmt?) ; `src/mir/mir.rb:1700` (stmt?) ; `src/mir/mir.rb:1707` (stmt?) ; `src/mir/mir.rb:1714` (stmt?) ; `src/mir/mir.rb:1721` (stmt?) ; `src/mir/mir.rb:1728` (stmt?) ; `src/mir/mir.rb:1736` (stmt?) ; `src/mir/mir.rb:1745` (stmt?) ; `src/mir/mir.rb:1753` (stmt?) ; `src/mir/mir.rb:1761` (stmt?) ; `src/mir/mir.rb:2142` (expr?) ; `src/mir/mir.rb:2288` (expr?) ; `src/mir/mir.rb:2332` (expr?)
- `wildcard? = union? = struct? = resource? = enum? = needs_capture_site_annotation? = stmt? = expr?` == `false`
  - `src/ast/ast.rb:1274` (wildcard?) ; `src/ast/ast.rb:1418` (wildcard?) ; `src/ast/ast.rb:1433` (wildcard?) ; `src/ast/schemas.rb:36` (union?) ; `src/ast/schemas.rb:38` (struct?) ; `src/ast/schemas.rb:40` (resource?) ; `src/ast/schemas.rb:69` (union?) ; `src/ast/schemas.rb:71` (enum?) ; `src/ast/schemas.rb:73` (struct?) ; `src/ast/schemas.rb:125` (enum?) ; `src/ast/schemas.rb:127` (struct?) ; `src/ast/schemas.rb:129` (resource?) ; `src/ast/schemas.rb:171` (union?) ; `src/ast/schemas.rb:173` (enum?) ; `src/ast/schemas.rb:175` (resource?) ; `src/mir/capture_strategy.rb:51` (needs_capture_site_annotation?) ; `src/mir/capture_strategy.rb:64` (needs_capture_site_annotation?) ; `src/mir/capture_strategy.rb:108` (needs_capture_site_annotation?) ; `src/mir/mir.rb:185` (stmt?) ; `src/mir/mir.rb:187` (expr?)
- `auto? = auto_type?` == `t.is_a?(Type) && t.auto?`
  - `src/annotator-helpers/auto_inference.rb:101` (auto?) ; `src/annotator-helpers/auto_inference.rb:790` (auto?) ; `src/backends/importer.rb:163` (auto_type?)

## Exact Predicate Aliases (6)
_identical one-line predicate body under >=2 names_

- `enum? = resource? = union? = struct? = needs_capture_site_annotation? = suspend? = mir? = stmt? = expr? = has_own_frame?` == `true`
  - `src/ast/schemas.rb:34` (enum?) ; `src/ast/schemas.rb:67` (resource?) ; `src/ast/schemas.rb:123` (union?) ; `src/ast/schemas.rb:169` (struct?) ; `src/mir/capture_strategy.rb:79` (needs_capture_site_annotation?) ; `src/mir/capture_strategy.rb:95` (needs_capture_site_annotation?) ; `src/mir/fsm_transform/segments.rb:51` (suspend?) ; `src/mir/fsm_transform/segments.rb:69` (suspend?) ; `src/mir/mir.rb:183` (mir?) ; `src/mir/mir.rb:199` (stmt?) ; `src/mir/mir.rb:221` (expr?) ; `src/mir/mir.rb:277` (has_own_frame?) ; `src/mir/mir.rb:573` (expr?) ; `src/mir/mir.rb:642` (expr?) ; `src/mir/mir.rb:663` (expr?) ; `src/mir/mir.rb:779` (expr?) ; `src/mir/mir.rb:790` (expr?) ; `src/mir/mir.rb:805` (expr?) ; `src/mir/mir.rb:841` (expr?) ; `src/mir/mir.rb:1561` (stmt?) ; `src/mir/mir.rb:1593` (stmt?) ; `src/mir/mir.rb:1615` (stmt?) ; `src/mir/mir.rb:1642` (stmt?) ; `src/mir/mir.rb:1651` (stmt?) ; `src/mir/mir.rb:1665` (stmt?) ; `src/mir/mir.rb:1677` (stmt?) ; `src/mir/mir.rb:1693` (stmt?) ; `src/mir/mir.rb:1700` (stmt?) ; `src/mir/mir.rb:1707` (stmt?) ; `src/mir/mir.rb:1714` (stmt?) ; `src/mir/mir.rb:1721` (stmt?) ; `src/mir/mir.rb:1728` (stmt?) ; `src/mir/mir.rb:1736` (stmt?) ; `src/mir/mir.rb:1745` (stmt?) ; `src/mir/mir.rb:1753` (stmt?) ; `src/mir/mir.rb:1761` (stmt?) ; `src/mir/mir.rb:2142` (expr?) ; `src/mir/mir.rb:2288` (expr?) ; `src/mir/mir.rb:2332` (expr?)
- `wildcard? = union? = struct? = resource? = enum? = needs_capture_site_annotation? = stmt? = expr?` == `false`
  - `src/ast/ast.rb:1274` (wildcard?) ; `src/ast/ast.rb:1418` (wildcard?) ; `src/ast/ast.rb:1433` (wildcard?) ; `src/ast/schemas.rb:36` (union?) ; `src/ast/schemas.rb:38` (struct?) ; `src/ast/schemas.rb:40` (resource?) ; `src/ast/schemas.rb:69` (union?) ; `src/ast/schemas.rb:71` (enum?) ; `src/ast/schemas.rb:73` (struct?) ; `src/ast/schemas.rb:125` (enum?) ; `src/ast/schemas.rb:127` (struct?) ; `src/ast/schemas.rb:129` (resource?) ; `src/ast/schemas.rb:171` (union?) ; `src/ast/schemas.rb:173` (enum?) ; `src/ast/schemas.rb:175` (resource?) ; `src/mir/capture_strategy.rb:51` (needs_capture_site_annotation?) ; `src/mir/capture_strategy.rb:64` (needs_capture_site_annotation?) ; `src/mir/capture_strategy.rb:108` (needs_capture_site_annotation?) ; `src/mir/mir.rb:185` (stmt?) ; `src/mir/mir.rb:187` (expr?)
- `visit_PassStmt = visit_OrRaise = visit_OrBreak = visit_OrPass = visit_OrPrune` == `node.full_type = :Void`
  - `src/annotator.rb:1434` (visit_PassStmt) ; `src/annotator.rb:4078` (visit_OrRaise) ; `src/annotator.rb:4083` (visit_OrBreak) ; `src/annotator.rb:4088` (visit_OrPass) ; `src/annotator.rb:4095` (visit_OrPrune)
- `child_bodies = marker_plan = with_alias_ownership_marks` == `[]`
  - `src/ast/ast.rb:561` (child_bodies) ; `src/mir/capture_strategy.rb:49` (marker_plan) ; `src/mir/capture_strategy.rb:62` (marker_plan) ; `src/mir/capture_strategy.rb:106` (marker_plan) ; `src/mir/lowering/capabilities.rb:88` (with_alias_ownership_marks)
- `emit_rc_retain = emit_rc_downgrade = emit_weak_upgrade` == `"CheatLib.#{node.func}(#{node.zig_base}, #{emit(node.source)})"`
  - `src/mir/mir_emitter.rb:1163` (emit_rc_retain) ; `src/mir/mir_emitter.rb:1168` (emit_rc_downgrade) ; `src/mir/mir_emitter.rb:1173` (emit_weak_upgrade)
- `auto? = auto_type?` == `t.is_a?(Type) && t.auto?`
  - `src/annotator-helpers/auto_inference.rb:101` (auto?) ; `src/annotator-helpers/auto_inference.rb:790` (auto?) ; `src/backends/importer.rb:163` (auto_type?)

## Type-3 Clones (missed rename) (16)
_pasted block, one identifier inconsistently renamed -- *POSSIBLE* bug_

- *POSSIBLE* `src/tools/formatter.rb:738` (emit_match_body) clone of `src/tools/formatter.rb:733` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:837` (emit_fn_block) clone of `src/tools/formatter.rb:733` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:849` (emit_fn_block) clone of `src/tools/formatter.rb:733` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:953` (emit_fn_signature_wrapped) clone of `src/tools/formatter.rb:733` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:1068` (emit_fn_params_only_wrapped) clone of `src/tools/formatter.rb:733` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:1325` (expand_if_while_for) clone of `src/tools/formatter.rb:733` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:1327` (expand_if_while_for) clone of `src/tools/formatter.rb:733` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:1329` (expand_if_while_for) clone of `src/tools/formatter.rb:733` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:1983` (emit_wrapped_args) clone of `src/tools/formatter.rb:733` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2159` (emit_bg_do_wrapped) clone of `src/tools/formatter.rb:733` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2434` (emit_record_type) clone of `src/tools/formatter.rb:733` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2438` (emit_record_type) clone of `src/tools/formatter.rb:733` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2440` (emit_record_type) clone of `src/tools/formatter.rb:733` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/mir/hoist.rb:741` (replace_mir_expr_child!) clone of `src/mir/hoist.rb:735` (replace_mir_expr_child!): ref var `parent` spelled ["value", "parent"] here
- *POSSIBLE* `src/mir/hoist.rb:748` (replace_mir_expr_child!) clone of `src/mir/hoist.rb:735` (replace_mir_expr_child!): ref var `parent` spelled ["value", "parent"] here
- *POSSIBLE* `src/annotator.rb:4045` (visit_OrRescue) clone of `src/annotator.rb:4030` (visit_OrRescue): ref var `payload_type` spelled ["wrapped", "wrapped_type"] here

## Neglected Updates (5769)
_co-written state, one write missing -- *POSSIBLE* redundant-state desync_

- *POSSIBLE* (support=55) `src/annotator-helpers/function_analysis.rb:150` (resolve_call) writes `.full_type` but NOT `.storage` (recv `args[i]`)
- *POSSIBLE* (support=55) `src/annotator-helpers/function_analysis.rb:763` (declare_and_verify_params) writes `.full_type` but NOT `.storage` (recv `param.default`)
- *POSSIBLE* (support=55) `src/annotator-helpers/function_analysis.rb:871` (verify_captures!) writes `.storage` but NOT `.full_type` (recv `cap`)
- *POSSIBLE* (support=55) `src/annotator-helpers/generic_analysis.rb:523` (propagate_declared_type_to_value!) writes `.full_type` but NOT `.storage` (recv `node.value`)
- *POSSIBLE* (support=55) `src/annotator-helpers/method_analysis.rb:53` (narrow_collection_type!) writes `.full_type` but NOT `.storage` (recv `list_arg`)
- *POSSIBLE* (support=55) `src/annotator-helpers/method_analysis.rb:90` (resolve_typed_method) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=55) `src/annotator-helpers/pipe_analysis.rb:34` (visit_Smooth) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=55) `src/annotator-helpers/pipe_analysis.rb:95` (lift_to_observable_if_terminal!) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=55) `src/annotator-helpers/pipe_analysis.rb:239` (analyze_higher_order_op) writes `.full_type` but NOT `.storage` (recv `node.right`)
- *POSSIBLE* (support=55) `src/annotator-helpers/pipe_analysis.rb:746` (analyze_pipe_to_func_call) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=55) `src/annotator-helpers/pipe_analysis.rb:767` (analyze_pipe_to_identifier) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=55) `src/annotator-helpers/pipe_analysis.rb:808` (analyze_pipe_to_named_function) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=55) `src/annotator-helpers/pipe_analysis.rb:1273` (auto_detect_sharded_access) writes `.full_type` but NOT `.storage` (recv `map_ident`)
- *POSSIBLE* (support=55) `src/annotator-helpers/test_annotation.rb:40` (visit_TestBlock) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=55) `src/annotator-helpers/test_annotation.rb:66` (visit_WhenBlock) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=55) `src/annotator-helpers/test_annotation.rb:109` (visit_TestThat) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=55) `src/annotator-helpers/test_annotation.rb:116` (visit_AssertRaises) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=55) `src/annotator-helpers/test_annotation.rb:123` (visit_BenchmarkStmt) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=55) `src/annotator-helpers/test_annotation.rb:130` (visit_SmashStmt) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=55) `src/annotator-helpers/test_annotation.rb:137` (visit_ProfileStmt) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=55) `src/annotator-helpers/test_annotation.rb:154` (visit_StubDecl) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=55) `src/annotator-helpers/union.rb:115` (resolve_variant_access) writes `.full_type` but NOT `.storage` (recv `node.target`)
- *POSSIBLE* (support=55) `src/annotator.rb:478` (visit_Program) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=55) `src/annotator.rb:497` (visit_RequireNode) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=55) `src/annotator.rb:571` (visit_ExternFnDecl) writes `.full_type` but NOT `.storage` (recv `node`)
- ...(+5744 more)

## Derived-State Staleness (150)
_b = f(a); a later reassigned, b not recomputed -- *POSSIBLE* bug_

- *POSSIBLE* `src/ast/ast.rb:792` (finalize_storage!): `value_sync` derived from `vt` (line 792); `vt` reassigned line 867, `value_sync` not recomputed
- *POSSIBLE* `src/tools/doctor.rb:158` (section_heap): `addrs` derived from `sites` (line 158); `sites` reassigned line 218, `addrs` not recomputed
- *POSSIBLE* `src/ast/type.rb:2319` (compute_zig_type): `inner_zig` derived from `base_zig` (line 2319); `base_zig` reassigned line 2373, `inner_zig` not recomputed
- *POSSIBLE* `src/annotator.rb:2072` (visit_ReturnNode): `expected_void_compatible` derived from `expected` (line 2072); `expected` reassigned line 2125, `expected_void_compatible` not recomputed
- *POSSIBLE* `src/annotator-helpers/capabilities.rb:201` (validate_capability): `atomic_ptr_ok` derived from `syn` (line 201); `syn` reassigned line 246, `atomic_ptr_ok` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:2817` (needs_space?): `a_is_struct_open` derived from `a_idx` (line 2817); `a_idx` reassigned line 2861, `a_is_struct_open` not recomputed
- *POSSIBLE* `src/ast/ast.rb:797` (finalize_storage!): `t` derived from `val_ti` (line 797); `val_ti` reassigned line 837, `t` not recomputed
- *POSSIBLE* `src/annotator-helpers/capabilities.rb:847` (declare_capability_scope!): `inner` derived from `st` (line 847); `st` reassigned line 875, `inner` not recomputed
- *POSSIBLE* `src/backends/pipeline_host.rb:326` (substitute_placeholders): `new_mc` derived from `new_target` (line 326); `new_target` reassigned line 353, `new_mc` not recomputed
- *POSSIBLE* `src/ast/diagnostic_examples.rb:92` (scan_file): `j` derived from `i` (line 92); `i` reassigned line 117, `j` not recomputed
- *POSSIBLE* `src/backends/pipeline_rewriter.rb:563` (build_recursive_body): `skip_if` derived from `cond` (line 563); `cond` reassigned line 588, `skip_if` not recomputed
- *POSSIBLE* `src/annotator-helpers/generic_analysis.rb:221` (validate_type_annotation!): `expected` derived from `schema` (line 221); `schema` reassigned line 245, `expected` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:2264` (find_s_chains): `s_idxs` derived from `i` (line 2264); `i` reassigned line 2288, `s_idxs` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:1183` (branch_end_for_inline_expansion): `t` derived from `j` (line 1183); `j` reassigned line 1206, `t` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:2266` (find_s_chains): `j` derived from `i` (line 2266); `i` reassigned line 2288, `j` not recomputed
- *POSSIBLE* `src/mir/lowering/literals.rb:39` (lower_list_lit): `promise_zig` derived from `elem_zig` (line 39); `elem_zig` reassigned line 60, `promise_zig` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:1636` (expand_concurrent_drops): `t` derived from `i` (line 1636); `i` reassigned line 1655, `t` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:2933` (capability_chain_colon?): `t` derived from `j` (line 2933); `j` reassigned line 2952, `t` not recomputed
- *POSSIBLE* `src/annotator-helpers/generic_analysis.rb:549` (propagate_collection_metadata!): `coll_src` derived from `decl_t` (line 549); `decl_t` reassigned line 567, `coll_src` not recomputed
- *POSSIBLE* `src/annotator.rb:3093` (visit_Assignment): `tname` derived from `target` (line 3093); `target` reassigned line 3111, `tname` not recomputed
- *POSSIBLE* `src/ast/type.rb:2102` (parse_raw_input): `inner` derived from `match` (line 2102); `match` reassigned line 2119, `inner` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:1118` (find_fn_arrow): `t` derived from `j` (line 1118); `j` reassigned line 1135, `t` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:1638` (expand_concurrent_drops): `paren_open` derived from `i` (line 1638); `i` reassigned line 1655, `paren_open` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:2935` (capability_chain_colon?): `k` derived from `j` (line 2935); `j` reassigned line 2952, `k` not recomputed
- *POSSIBLE* `src/ast/parser.rb:2844` (parse_type_annotation): `is_elem_cap` derived from `sync_tok` (line 2844); `sync_tok` reassigned line 2860, `is_elem_cap` not recomputed
- ...(+125 more)

## Neglected Conditions (11)
_dispatch/conjunction minus one element -- *POSSIBLE* bug_

- *POSSIBLE* (support=5) `src/tools/formatter.rb:1260` (one_liner_end) -- MISSING `'START'` from `'END' | 'FN' | 'FOR' | 'IF' | 'START' | 'TEST' | 'WHEN' | 'WHILE'`
- *POSSIBLE* (support=5) `src/tools/formatter.rb:1332` (expand_if_while_for) -- MISSING `'START'` from `'END' | 'FN' | 'FOR' | 'IF' | 'START' | 'TEST' | 'WHEN' | 'WHILE'`
- *POSSIBLE* (support=4) `src/mir/local_binding_facts.rb:78` (binding_decl_name) -- MISSING `AST::Assignment` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- *POSSIBLE* (support=4) `src/mir/local_binding_facts.rb:90` (binding_entry) -- MISSING `AST::Assignment` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- *POSSIBLE* (support=4) `src/tools/atomic_migration_suggester.rb:129` (stmt_eligible?) -- MISSING `AST::VarDecl` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- *POSSIBLE* (support=4) `src/tools/atomic_ptr_migration_suggester.rb:120` (stmt_eligible?) -- MISSING `AST::VarDecl` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- *POSSIBLE* (support=3) `src/annotator.rb:5039` (validate_snapshot_match_arms!) -- MISSING `:LOCKED` from `:ATOMIC | :LOCKED | :VERSIONED`
- *POSSIBLE* (support=3) `src/mir/cleanup_classifier.rb:668` (finalize_alloc_from_storage!) -- MISSING `decl.symbol` from `decl | decl.respond_to?(:symbol) | decl.symbol`
- *POSSIBLE* (support=3) `src/mir/cleanup_classifier.rb:808` (container_alloc_from) -- MISSING `decl.symbol` from `decl | decl.respond_to?(:symbol) | decl.symbol`
- *POSSIBLE* (support=3) `src/mir/fsm_transform/recursive_splitter.rb:373` (emit_pivot) -- MISSING `AST::CatchBlock` from `AST::CatchBlock | AST::ForEach | AST::ForRange | AST::IfStatement | AST::WhileBindLoop | AST::WhileLoop | AST::WithBlock`
- *POSSIBLE* (support=3) `src/mir/lowering/capabilities.rb:151` (build_field_path_zig) -- MISSING `AST::GetIndex` from `AST::GetField | AST::GetIndex | AST::Identifier`

## Neglected Path Conditions (2069)
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
- *POSSIBLE* (support=35) `src/annotator-helpers/function_analysis.rb:195` (resolve_call) -- MISSING `inner.is_a?(Type)` from `!func_type == :Intrinsic | !type_params&.any? | entry&.storage == :static | fsig | func_type = fsig | inner.is_a?(Type) | node.full_type.error_union? | node.full_type.respond_to?(:error_union?)`
- ...(+2044 more)

## Broken Protocols (1534)
_co-called pair, one site does A without B -- *POSSIBLE* bug (noisy)_

- *POSSIBLE* conf=0.98 support=48 `src/ast/ast.rb:572` (column) does `column` without `line`
- *POSSIBLE* conf=0.98 support=44 `src/ast/parser.rb:1814` (parse_binary_op) does `parse_expression` without `consume`
- *POSSIBLE* conf=0.96 support=45 `src/backends/pipeline_host.rb:3260` (default_obs_alloc_zig) does `transpile_type` without `new`
- *POSSIBLE* conf=0.96 support=45 `src/mir/mir_lowering.rb:2190` (bare_zig_type) does `transpile_type` without `new`
- *POSSIBLE* conf=0.96 support=23 `src/annotator.rb:5638` (promote_to_expr_if!) does `else_branch` without `then_branch`
- *POSSIBLE* conf=0.96 support=23 `src/mir/mir_pass.rb:774` (stamp_if_bind_cleanup!) does `then_branch` without `else_branch`
- *POSSIBLE* conf=0.96 support=22 `src/annotator.rb:893` (validate_and_resolve_sync_policy!) does `statements` without `each`
- *POSSIBLE* conf=0.96 support=22 `src/annotator.rb:1283` (visit_IfStatement) does `proc` without `[]`
- *POSSIBLE* conf=0.95 support=36 `src/ast/parser.rb:524` (match_literal!) does `match!` without `consume`
- *POSSIBLE* conf=0.95 support=36 `src/ast/parser.rb:3560` (parse_error_selectors) does `match!` without `consume`
- *POSSIBLE* conf=0.95 support=36 `src/backends/pipeline_host.rb:176` (visit) does `visit_mir` without `new`
- *POSSIBLE* conf=0.95 support=36 `src/backends/pipeline_host.rb:842` (visit_pipeline_expr_mir) does `visit_mir` without `new`
- *POSSIBLE* conf=0.95 support=21 `src/mir/lowering/variables.rb:1162` (auto_lock_assignment_value) does `hoist_alloc` without `new`
- *POSSIBLE* conf=0.95 support=21 `src/mir/mir_lowering.rb:861` (pre_terminator_transfer_marks) does `mir_ident_names` without `new`
- *POSSIBLE* conf=0.95 support=18 `src/annotator-helpers/pipe_analysis.rb:45` (finite_stream_source?) does `dynamic_stream?` without `inf_stream?`
- *POSSIBLE* conf=0.94 support=32 `src/annotator-helpers/function_analysis.rb:21` (analyze_routine) does `with_new_scope` without `current_scope`
- *POSSIBLE* conf=0.94 support=32 `src/annotator-helpers/test_annotation.rb:34` (visit_TestBlock) does `with_new_scope` without `current_scope`
- *POSSIBLE* conf=0.94 support=17 `src/annotator-helpers/pipe_analysis.rb:859` (analyze_skip_op) does `finite_stream_element_type` without `current_scope`
- *POSSIBLE* conf=0.94 support=17 `src/annotator-helpers/pipe_analysis.rb:859` (analyze_skip_op) does `finite_stream_element_type` without `declare`
- *POSSIBLE* conf=0.94 support=17 `src/annotator-helpers/pipe_analysis.rb:859` (analyze_skip_op) does `finite_stream_element_type` without `with_new_scope`
- *POSSIBLE* conf=0.94 support=17 `src/annotator-helpers/pipe_analysis.rb:1213` (analyze_auto_shard_each_op) does `finite_stream_element_type` without `right`
- *POSSIBLE* conf=0.94 support=17 `src/annotator-helpers/pipe_analysis.rb:1743` (analyze_concurrent_stream_each_op) does `finite_stream_element_type` without `resolved_type`
- *POSSIBLE* conf=0.94 support=16 `src/annotator-helpers/pipe_analysis.rb:536` (analyze_recover_op) does `payload_type` without `error_union?`
- *POSSIBLE* conf=0.94 support=16 `src/annotator-helpers/pipe_analysis.rb:1424` (numeric_literal_value) does `to_f` without `[]`
- *POSSIBLE* conf=0.94 support=16 `src/mir/lowering/variables.rb:129` (lower_var_decl) does `with_decl_alloc` without `lower`
- ...(+1509 more)

## False Simplicity (696)
_looks simple, behaves non-locally: hidden dispatch/mutation/IO/context/metaprogramming/monkeypatch -- *POSSIBLE* (noisy)_

- *POSSIBLE* [hidden_mutation] scatter=437 support=1262 `<<` -- `src/annotator-helpers/auto_inference.rb:160` (record_call_site) (+1256 more)
- *POSSIBLE* [hidden_mutation] scatter=228 support=476 `[]=` -- `src/annotator-helpers/auto_inference.rb:84` (register_signature_slots) (+474 more)
- *POSSIBLE* [hidden_mutation] scatter=208 support=409 `error!` -- `src/annotator-helpers/capabilities.rb:130` (validate_capability) (+408 more)
- *POSSIBLE* [hidden_mutation] scatter=144 support=302 `full_type=` -- `src/annotator-helpers/function_analysis.rb:150` (resolve_call) (+301 more)
- *POSSIBLE* [hidden_mutation] scatter=69 support=123 `op-assign` -- `src/annotator-helpers/auto_inference.rb:205` (record_local) (+122 more)
- *POSSIBLE* [hidden_mutation] scatter=62 support=90 `storage=` -- `src/annotator-helpers/function_analysis.rb:871` (verify_captures!) (+89 more)
- *POSSIBLE* [hidden_mutation] scatter=48 support=50 `fixable!` -- `src/annotator-helpers/capabilities.rb:297` (emit_view_not_observable_finding!) (+49 more)
- *POSSIBLE* [hidden_mutation] scatter=45 support=48 `from_node!` -- `src/annotator-helpers/generic_analysis.rb:619` (find_container_source) (+47 more)
- *POSSIBLE* [dynamic_dispatch] scatter=40 support=70 `instance_variable_get` -- `src/annotator-helpers/auto_inference.rb:272` (empty_list_lit?) (+69 more)
- *POSSIBLE* [hidden_mutation] scatter=38 support=99 `match!` -- `src/ast/parser.rb:159` ((top-level)) (+98 more)
- *POSSIBLE* [dynamic_dispatch] scatter=35 support=54 `send` -- `src/annotator-helpers/function_return.rb:95` (resolve) (+53 more)
- *POSSIBLE* [hidden_io] scatter=35 support=41 `File.exist?` -- `src/ast/diagnostic_examples.rb:72` (load!) (+40 more)
- *POSSIBLE* [callback_inversion] scatter=34 support=37 `with_new_scope` -- `src/annotator-helpers/capabilities.rb:571` (visit_post_clauses!) (+36 more)
- *POSSIBLE* [dynamic_dispatch] scatter=32 support=81 `yield` -- `src/annotator-helpers/auto_inference.rb:575` (walk_for_shape_decls) (+80 more)
- *POSSIBLE* [hidden_io] scatter=31 support=39 `File.join` -- `src/backends/importer.rb:64` (resolve_stdlib_package) (+38 more)
- *POSSIBLE* [metaprogramming] scatter=23 support=55 `instance_variable_set` -- `src/annotator-helpers/auto_inference.rb:472` (stamp_slot!) (+54 more)
- *POSSIBLE* [callback_inversion] scatter=23 support=39 `with_pipeline_context` -- `src/backends/pipeline_host.rb:243` (visit_pipeline_body_mir) (+38 more)
- *POSSIBLE* [hidden_mutation] scatter=23 support=23 `scope=` -- `src/ast/scope.rb:40` (declare) (+22 more)
- *POSSIBLE* [hidden_io] scatter=22 support=267 `puts` -- `src/backends/transpiler.rb:329` ((top-level)) (+266 more)
- *POSSIBLE* [hidden_mutation] scatter=21 support=31 `ownership=` -- `src/annotator-helpers/function_analysis.rb:208` (resolve_call) (+30 more)
- *POSSIBLE* [dynamic_dispatch] scatter=20 support=21 `blk.call` -- `src/annotator.rb:72` (with_conditional_context) (+20 more)
- *POSSIBLE* [hidden_mutation] scatter=19 support=25 `emit_typo_suggestion!` -- `src/annotator-helpers/capabilities.rb:326` (predicate_identifier_allowed!) (+24 more)
- *POSSIBLE* [dynamic_dispatch] scatter=19 support=21 `schema_lookup.call` -- `src/ast/type.rb:1022` (resolve_resource_close) (+20 more)
- *POSSIBLE* [hidden_mutation] scatter=18 support=24 `provenance=` -- `src/annotator-helpers/function_analysis.rb:213` (resolve_call) (+23 more)
- *POSSIBLE* [hidden_io] scatter=18 support=22 `File.readlines` -- `src/ast/diagnostic_examples.rb:82` (scan_file) (+21 more)
- ...(+671 more)

## Fat Unions (8)
_case dispatch over class consts whose arms read mostly variant-invariant members -- product-vs-sum decomposition candidate (extraction -> nil-kill) -- *POSSIBLE*_

- *POSSIBLE* [DEGENERATE: no variance] union `AST::Assignment | AST::BindExpr | AST::VarDecl` -- **3 common** vs 0 variant member(s), scatter=3 -- `src/mir/fsm_transform/liveness.rb:196` (collect_defs)
  - common: `is_a?, name, value` -> hoist to a struct, keep a SMALL union for `` (-> nil-kill)
- *POSSIBLE* [DEGENERATE: no variance] union `AST::AllOp | AST::AnyOp | AST::AverageOp | AST::CountOp | AST::FindOp | AST::MaxOp | AST::MinOp | AST::SumOp` -- **2 common** vs 0 variant member(s), scatter=4 -- `src/ast/ast.rb:1711` (pipeline_range_fold?)
  - common: `class, expression` -> hoist to a struct, keep a SMALL union for `` (-> nil-kill)
- *POSSIBLE* [DEGENERATE: no variance] union `AST::Assignment | AST::BindExpr | AST::FuncCall | AST::MethodCall | AST::VarDecl` -- **7 common** vs 0 variant member(s), scatter=1 -- `src/mir/mir_pass.rb:508` (recurse_branches!)
  - common: `body, branches, cases, default_case, do_branch, else_branch, then_branch` -> hoist to a struct, keep a SMALL union for `` (-> nil-kill)
- *POSSIBLE* [DEGENERATE: no variance] union `AST::IndexOp | AST::OrderByOp | AST::SelectOp | AST::WhereOp` -- **2 common** vs 0 variant member(s), scatter=1 -- `src/annotator-helpers/pipe_analysis.rb:310` (analyze_select_family_op)
  - common: `expression, is_a?` -> hoist to a struct, keep a SMALL union for `` (-> nil-kill)
- *POSSIBLE* [DEGENERATE: no variance] union `AST::GetField | AST::GetIndex | AST::Identifier | String` -- **2 common** vs 0 variant member(s), scatter=1 -- `src/annotator.rb:3112` (visit_Assignment)
  - common: `is_a?, target` -> hoist to a struct, keep a SMALL union for `` (-> nil-kill)
- *POSSIBLE* union `Array | FalseClass | Hash | Numeric | String | Symbol | TrueClass | Type` -- **6 common** vs 4 variant member(s), scatter=2 -- `src/annotator-helpers/auto_inference.rb:113` (walk)
  - common: `each_pair, nil?, params, respond_to?, return_type, type` -> hoist to a struct, keep a SMALL union for `any?, auto?, each, each_value` (-> nil-kill)
- *POSSIBLE* union `AST::EnumDef | AST::StructDef | AST::UnionDef` -- **4 common** vs 2 variant member(s), scatter=3 -- `src/backends/compiler_frontend.rb:87` (compile)
  - common: `is_a?, name, variants, visibility` -> hoist to a struct, keep a SMALL union for `field_decls, type_params` (-> nil-kill)
- *POSSIBLE* union `AST::ForEach | AST::ForRange | AST::IfStatement | AST::MatchStatement | AST::WhileLoop` -- **5 common** vs 2 variant member(s), scatter=1 -- `src/mir/control_flow.rb:733` (transfer_stmt)
  - common: `is_a?, mode, name, value, var_name` -> hoist to a struct, keep a SMALL union for `collection, expr` (-> nil-kill)

## Run Summary
- Files analyzed: 110
- Detectors: 13 (all shipped, self-tested)
- Convergence: 1262 unit(s) flagged by >=2 independent detectors
- Root-cause clusters: 327 (one fix collapses each)
- Total candidates: 10744
- Method: stdlib AST only, intra-procedural, zero deps, no CFG / no points-to (see docs/agents/design.md)
