# Decomplex Report

> Decision-level duplication and neglected-condition analysis.
> Every entry is a ranked **candidate** (Engler's discipline),
> never a verdict -- *POSSIBLE* findings, triaged by a human.
> Sections are ordered by SIGNAL TIER (1 = lowest false
> positive), not by volume. Items within a section are
> frequency-ranked. Triage tier 1, top-of-list, first.

## Table of Contents
- [Project Prioritization](#project-prioritization)
- [Cross-Detector Convergence (1162)](#cross-detector-convergence-1162)
- [Root-Cause Clusters (323)](#root-cause-clusters-323)
- [Decision Pressure (256)](#decision-pressure-256)
- [Missing Abstractions (204)](#missing-abstractions-204)
- [Reification Misses (83)](#reification-misses-83)
- [Semantic Predicate Aliases (3)](#semantic-predicate-aliases-3)
- [Exact Predicate Aliases (6)](#exact-predicate-aliases-6)
- [Type-3 Clones (missed rename) (14)](#type3-clones-missed-rename-14)
- [Neglected Updates (6820)](#neglected-updates-6820)
- [Derived-State Staleness (241)](#derivedstate-staleness-241)
- [Neglected Conditions (47)](#neglected-conditions-47)
- [Neglected Path Conditions (2095)](#neglected-path-conditions-2095)
- [Broken Protocols (1800)](#broken-protocols-1800)
- [False Simplicity (616)](#false-simplicity-616)
- [Fat Unions (9)](#fat-unions-9)
- [Run Summary](#run-summary)

## Project Prioritization
_Ordered by signal tier (1 = highest signal / lowest FP), then by volume._

- **[tier 1]** [Decision Pressure (256)](#decision-pressure-256): ELIMINABLE guard-pressure per loose contract (nil/is_a?/respond_to?/safe-nav/rescue-nil) -> tighten the contract once / nil-kill: DELETE. essential dispatch + pure c-uses are split out, NEVER summed (Rapps-Weyuker p-use; McCabe)
- **[tier 1]** [Missing Abstractions (204)](#missing-abstractions-204): guard tuple recomputed across >=2 decision units
- **[tier 1]** [Reification Misses (83)](#reification-misses-83): an existing predicate reinvented inline -- invariant #16
- **[tier 1]** [Exact Predicate Aliases (6)](#exact-predicate-aliases-6): identical one-line predicate body under >=2 names
- **[tier 1]** [Semantic Predicate Aliases (3)](#semantic-predicate-aliases-3): one decision, multiple names (receiver/polarity folded)
- **[tier 2]** [Neglected Updates (6820)](#neglected-updates-6820): co-written state, one write missing -- *POSSIBLE* redundant-state desync
- **[tier 2]** [Derived-State Staleness (241)](#derivedstate-staleness-241): b = f(a); a later reassigned, b not recomputed -- *POSSIBLE* bug
- **[tier 2]** [Neglected Conditions (47)](#neglected-conditions-47): dispatch/conjunction minus one element -- *POSSIBLE* bug
- **[tier 2]** [Type-3 Clones (missed rename) (14)](#type3-clones-missed-rename-14): pasted block, one identifier inconsistently renamed -- *POSSIBLE* bug
- **[tier 3]** [Neglected Path Conditions (2095)](#neglected-path-conditions-2095): nested-if/&& guard set minus one atom -- *POSSIBLE* bug (noisy)
- **[tier 3]** [Broken Protocols (1800)](#broken-protocols-1800): co-called pair, one site does A without B -- *POSSIBLE* bug (noisy)
- **[tier 3]** [False Simplicity (616)](#false-simplicity-616): looks simple, behaves non-locally: hidden dispatch/mutation/IO/context/metaprogramming/monkeypatch -- *POSSIBLE* (noisy)
- **[tier 3]** [Fat Unions (9)](#fat-unions-9): case dispatch over class consts whose arms read mostly variant-invariant members -- product-vs-sum decomposition candidate (extraction -> nil-kill) -- *POSSIBLE*

## Cross-Detector Convergence (1162)
_(file, method) units flagged by >=2 INDEPENDENT detectors -- the strongest triage signal: agreement outranks any single detector's volume. Tier-weighted (1=3, 2=2, 3=1). **Start here.**_

- `src/ast/type.rb:2030` (compute_zig_type) -- **8 detectors** [score 16, 69 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Reification Misses
- `src/mir/mir_lowering.rb:6173` (lower_var_decl) -- **8 detectors** [score 15, 66 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Conditions, Neglected Path Conditions, Neglected Updates
- `src/annotator-helpers/capabilities.rb:1073` (_unified_capture_walk) -- **7 detectors** [score 14, 178 findings]: Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Reification Misses
- `src/annotator-helpers/function_analysis.rb:187` (resolve_call) -- **7 detectors** [score 13, 183 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/annotator.rb:2896` (visit_BindExpr) -- **7 detectors** [score 13, 81 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/annotator.rb:3412` (visit_GetField) -- **7 detectors** [score 13, 77 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions, Neglected Updates, Reification Misses
- `src/tools/doctor.rb:164` (section_heap) -- **7 detectors** [score 13, 54 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/annotator-helpers/generic_analysis.rb:579` (propagate_collection_metadata!) -- **7 detectors** [score 13, 52 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions, Neglected Updates, Reification Misses
- `src/backends/pipeline_host.rb:3407` (lower_concurrent) -- **7 detectors** [score 13, 52 findings]: Broken Protocols, Decision Pressure, False Simplicity, Fat Unions, Missing Abstractions, Neglected Path Conditions, Reification Misses
- `src/annotator.rb:5552` (handle_assign_move) -- **7 detectors** [score 13, 44 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/annotator-helpers/pipe_analysis.rb:796` (analyze_pipe_to_named_function) -- **7 detectors** [score 13, 39 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/mir/control_flow.rb:649` (transfer_stmt) -- **7 detectors** [score 13, 36 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Fat Unions, Missing Abstractions, Neglected Updates
- `src/annotator-helpers/pipe_analysis.rb:1453` (analyze_concurrent_op) -- **7 detectors** [score 12, 89 findings]: Broken Protocols, Decision Pressure, False Simplicity, Fat Unions, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/annotator.rb:4027` (visit_OrRescue) -- **6 detectors** [score 13, 56 findings]: Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Updates, Type-3 Clones (missed rename)
- `src/ast/parser.rb:2839` (parse_type_annotation) -- **6 detectors** [score 12, 73 findings]: Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions, Neglected Updates, Reification Misses
- `src/mir/mir_lowering.rb:4378` (lower_next_expr) -- **6 detectors** [score 12, 17 findings]: Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/annotator.rb:1438` (visit_MatchStatement) -- **6 detectors** [score 11, 280 findings]: Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/annotator.rb:681` (visit_FunctionDef) -- **6 detectors** [score 11, 131 findings]: Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/annotator.rb:4765` (visit_WithBlock) -- **6 detectors** [score 11, 127 findings]: Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/annotator-helpers/capabilities.rb:782` (declare_capability_scope!) -- **6 detectors** [score 11, 109 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions, Reification Misses
- `src/annotator.rb:5484` (visit_NextExpr) -- **6 detectors** [score 11, 81 findings]: Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/annotator.rb:1964` (visit_WhileBindLoop) -- **6 detectors** [score 11, 59 findings]: Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/annotator.rb:4316` (visit_CopyNode) -- **6 detectors** [score 11, 57 findings]: Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/annotator.rb:1931` (visit_WhileLoop) -- **6 detectors** [score 11, 52 findings]: Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/tools/formatter.rb:1289` (expand_if_while_for) -- **6 detectors** [score 11, 52 findings]: Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Conditions, Neglected Path Conditions, Type-3 Clones (missed rename)
- ...(+1137 more)

### By file
- `src/annotator.rb` -- 12 detectors across 148 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, Exact Predicate Aliases, False Simplicity, Fat Unions, Missing Abstractions, Neglected Conditions, Neglected Path Conditions, Neglected Updates, Reification Misses, Type-3 Clones (missed rename)
- `src/mir/mir_lowering.rb` -- 10 detectors across 119 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Fat Unions, Missing Abstractions, Neglected Conditions, Neglected Path Conditions, Neglected Updates, Reification Misses
- `src/backends/pipeline_host.rb` -- 10 detectors across 56 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Fat Unions, Missing Abstractions, Neglected Conditions, Neglected Path Conditions, Neglected Updates, Reification Misses
- `src/tools/formatter.rb` -- 9 detectors across 63 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Conditions, Neglected Path Conditions, Neglected Updates, Type-3 Clones (missed rename)
- `src/mir/control_flow.rb` -- 9 detectors across 44 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Fat Unions, Missing Abstractions, Neglected Conditions, Neglected Path Conditions, Neglected Updates
- `src/ast/type.rb` -- 9 detectors across 30 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Conditions, Neglected Path Conditions, Neglected Updates, Reification Misses
- `src/ast/ast.rb` -- 9 detectors across 33 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, Exact Predicate Aliases, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Semantic Predicate Aliases
- `src/mir/escape_analysis.rb` -- 9 detectors across 20 method(s): Broken Protocols, Decision Pressure, False Simplicity, Fat Unions, Missing Abstractions, Neglected Conditions, Neglected Path Conditions, Neglected Updates, Reification Misses
- `src/annotator-helpers/pipe_analysis.rb` -- 8 detectors across 52 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Fat Unions, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/ast/parser.rb` -- 8 detectors across 69 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Reification Misses
- `src/mir/mir_pass.rb` -- 8 detectors across 28 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Fat Unions, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/mir/promotion_plan.rb` -- 8 detectors across 24 method(s): Broken Protocols, Decision Pressure, False Simplicity, Fat Unions, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Reification Misses
- `src/annotator-helpers/generic_analysis.rb` -- 8 detectors across 21 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Reification Misses
- `src/annotator-helpers/capabilities.rb` -- 8 detectors across 19 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Reification Misses
- `src/annotator-helpers/auto_inference.rb` -- 8 detectors across 21 method(s): Broken Protocols, Decision Pressure, Exact Predicate Aliases, False Simplicity, Fat Unions, Missing Abstractions, Neglected Updates, Semantic Predicate Aliases

## Root-Cause Clusters (323)
_Findings across >=2 INDEPENDENT detectors that name the SAME entity -- 'N findings are really one invariant'. Convergence says where to look; this says **what one fix collapses the cluster**. Ranked candidate, not a verdict._

- **[name]** `expr` -- **6 detectors** [score 13] across 27 unit(s), 64 findings: Decision Pressure, Derived-State Staleness, Exact Predicate Aliases, False Simplicity, Neglected Path Conditions, Semantic Predicate Aliases
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator.rb:1313` (visit_IfBind) ; `src/annotator.rb:1453` (visit_MatchStatement) ; `src/annotator.rb:1516` (visit_MatchStatement) ; `src/annotator.rb:5417` (visit_NextExpr)
- **[name]** `sync` -- **6 detectors** [score 11] across 197 unit(s), 297 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Path Conditions, Neglected Updates, Reification Misses
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator-helpers/function_analysis.rb:210` (resolve_call) ; `src/annotator-helpers/generic_analysis.rb:453` (generic_type_has_capabilities?) ; `src/annotator-helpers/pipe_analysis.rb:1156` (collect_sharded_names) ; `src/annotator-helpers/pipe_analysis.rb:1177` (pre_scan_node_for_sharded)
- **[name]** `layout` -- **5 detectors** [score 10] across 358 unit(s), 402 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Updates, Reification Misses
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator-helpers/function_analysis.rb:215` (resolve_call) ; `src/annotator-helpers/generic_analysis.rb:454` (generic_type_has_capabilities?) ; `src/ast/type.rb:2089` (compute_zig_type) ; `src/annotator-helpers/lock_helper.rb:400` (verify_handler_reachability!)
- **[name]** `symbol` -- **5 detectors** [score 10] across 176 unit(s), 171 findings: Decision Pressure, False Simplicity, Neglected Path Conditions, Neglected Updates, Reification Misses
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator-helpers/capabilities.rb:93` (cap_var_sync) ; `src/annotator-helpers/capabilities.rb:118` (cap_var_layout) ; `src/annotator-helpers/capabilities.rb:142` (validate_capability) ; `src/annotator-helpers/capabilities.rb:164` (validate_capability)
- **[name]** `ownership` -- **5 detectors** [score 10] across 173 unit(s), 229 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Updates, Reification Misses
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator-helpers/function_analysis.rb:201` (resolve_call) ; `src/ast/type.rb:2081` (compute_zig_type) ; `src/ast/type.rb:2107` (compute_zig_type) ; `src/annotator.rb:4187` (visit_CapabilityWrap)
- **[name]** `resolved` -- **5 detectors** [score 10] across 44 unit(s), 60 findings: Broken Protocols, Decision Pressure, Derived-State Staleness, Neglected Path Conditions, Reification Misses
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator-helpers/pipe_analysis.rb:796` (analyze_pipe_to_named_function) ; `src/annotator-helpers/pipe_analysis.rb:1377` (analyze_shard_op) ; `src/mir/mir_lowering.rb:5417` (lower_get_field) ; `src/ast/type.rb:1404` (copyable?)
- **[name]** `target` -- **5 detectors** [score 10] across 44 unit(s), 109 findings: Broken Protocols, Decision Pressure, Derived-State Staleness, Neglected Path Conditions, Reification Misses
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator-helpers/auto_inference.rb:655` (record_index_assign) ; `src/annotator-helpers/capabilities.rb:764` (cap_var_name) ; `src/annotator-helpers/function_analysis.rb:915` (verify_return) ; `src/annotator-helpers/generic_analysis.rb:645` (find_container_source)
- **[name]** `collection` -- **5 detectors** [score 9] across 12 unit(s), 20 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Path Conditions, Reification Misses
  - FIX: pair the protocol (RAII / ensure); the unpaired site is the deviant
  - `src/mir/fsm_transform.rb:178` (collect_body_locals) ; `src/mir/mir_lowering.rb:7077` (lower_for_each) ; `src/mir/mir_lowering.rb:7078` (lower_for_each) ; `src/annotator-helpers/generic_analysis.rb:577` (propagate_collection_metadata!)
- **[name]** `line` -- **5 detectors** [score 9] across 10 unit(s), 19 findings: Broken Protocols, Decision Pressure, Derived-State Staleness, Neglected Path Conditions, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/tools/doctor.rb:607` (task_site_metadata) ; `src/tools/doctor.rb:620` (source_line) ; `src/ast/lexer.rb:40` (initialize) ; `src/ast/lexer.rb:311` (advance_pos)
- **[name]** `full_type` -- **5 detectors** [score 8] across 437 unit(s), 3967 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Path Conditions, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator-helpers/capabilities.rb:186` (validate_capability) ; `src/annotator-helpers/capabilities.rb:193` (validate_capability) ; `src/annotator-helpers/capabilities.rb:742` (acquire_capability!) ; `src/annotator-helpers/function_analysis.rb:187` (resolve_call)
- **[name]** `body` -- **5 detectors** [score 8] across 215 unit(s), 245 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Path Conditions, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator-helpers/capabilities.rb:1236` (_unified_capture_walk) ; `src/backends/pipeline_rewriter.rb:75` (rewrite_children!) ; `src/backends/string_concat_rewriter.rb:59` (rewrite_children!) ; `src/mir/fsm_transform/recursive_splitter.rb:498` (emit_for_range_fragment)
- **[name]** `type_params` -- **5 detectors** [score 8] across 199 unit(s), 211 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Path Conditions, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator-helpers/function_analysis.rb:155` (resolve_call) ; `src/annotator-helpers/generic_analysis.rb:235` (validate_type_annotation!) ; `src/annotator-helpers/generic_analysis.rb:246` (validate_type_annotation!) ; `src/annotator.rb:1108` (visit_StructDef)
- **[name]** `type` -- **5 detectors** [score 8] across 177 unit(s), 234 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Path Conditions, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator-helpers/auto_inference.rb:210` (record_local) ; `src/annotator-helpers/auto_inference.rb:504` (stamp_map_pairs!) ; `src/annotator-helpers/auto_inference.rb:505` (stamp_map_pairs!) ; `src/annotator-helpers/auto_inference.rb:572` (walk_for_shape_decls)
- **[name]** `mark_per_iter` -- **5 detectors** [score 7] across 146 unit(s), 153 findings: Broken Protocols, False Simplicity, Neglected Conditions, Neglected Path Conditions, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator-helpers/effects.rb:151` (current_loop_depth) ; `src/annotator-helpers/function_analysis.rb:146` (resolve_call) ; `src/annotator-helpers/function_analysis.rb:747` (declare_and_verify_params) ; `src/annotator-helpers/function_context.rb:38` (initialize)
- **[name]** `union` -- **4 detectors** [score 8] across 30 unit(s), 45 findings: Broken Protocols, Exact Predicate Aliases, Neglected Path Conditions, Semantic Predicate Aliases
  - FIX: pair the protocol (RAII / ensure); the unpaired site is the deviant
  - `src/ast/schemas.rb:34` (enum?) ; `src/ast/schemas.rb:67` (resource?) ; `src/ast/schemas.rb:123` (union?) ; `src/ast/schemas.rb:169` (struct?)
- **[name]** `struct` -- **4 detectors** [score 8] across 21 unit(s), 25 findings: Broken Protocols, Exact Predicate Aliases, Neglected Path Conditions, Semantic Predicate Aliases
  - FIX: pair the protocol (RAII / ensure); the unpaired site is the deviant
  - `src/ast/schemas.rb:34` (enum?) ; `src/ast/schemas.rb:67` (resource?) ; `src/ast/schemas.rb:123` (union?) ; `src/ast/schemas.rb:169` (struct?)
- **[name]** `storage` -- **4 detectors** [score 7] across 350 unit(s), 735 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator-helpers/with_match_check.rb:305` (family_of_arg) ; `src/annotator-helpers/function_analysis.rb:146` (resolve_call) ; `src/annotator-helpers/function_analysis.rb:747` (declare_and_verify_params) ; `src/annotator-helpers/function_analysis.rb:855` (verify_captures!)
- **[name]** `stdlib_def` -- **4 detectors** [score 7] across 210 unit(s), 234 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/mir/mir_checker.rb:218` (stdlib_owned_return?) ; `src/mir/mir_checker.rb:793` (expr_has_frame_alloc?) ; `src/mir/mir_lowering.rb:212` (mir_allocates?) ; `src/mir/mir_lowering.rb:6386` (owned_return_transfer_binding?)
- **[name]** `provenance` -- **4 detectors** [score 7] across 175 unit(s), 366 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator-helpers/function_analysis.rb:205` (resolve_call) ; `src/annotator-helpers/function_analysis.rb:207` (resolve_call) ; `src/annotator-helpers/function_analysis.rb:855` (verify_captures!) ; `src/annotator-helpers/generic_analysis.rb:420` (generic_shared_payload_binding)
- **[name]** `shard_count` -- **4 detectors** [score 7] across 171 unit(s), 190 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/ast/type.rb:983` (sharded?) ; `src/annotator-helpers/function_analysis.rb:207` (resolve_call) ; `src/annotator-helpers/generic_analysis.rb:420` (generic_shared_payload_binding) ; `src/annotator-helpers/generic_analysis.rb:554` (propagate_declared_type_to_value!)
- ...(+303 more)

## Decision Pressure (256)
_ELIMINABLE guard-pressure per loose contract (nil/is_a?/respond_to?/safe-nav/rescue-nil) -> tighten the contract once / nil-kill: DELETE. essential dispatch + pure c-uses are split out, NEVER summed (Rapps-Weyuker p-use; McCabe)_

- `.full_type` -- ELIMINABLE guard-pressure **234** across 85 method(s) -> tighten contract / nil-kill: DELETE  (+163 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator-helpers/capabilities.rb:186` (validate_capability) ; `src/annotator-helpers/capabilities.rb:193` (validate_capability) ; `src/annotator-helpers/capabilities.rb:742` (acquire_capability!) ; `src/annotator-helpers/function_analysis.rb:187` (resolve_call)
- `.value` -- ELIMINABLE guard-pressure **110** across 54 method(s) -> tighten contract / nil-kill: DELETE  (+11 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator-helpers/auto_inference.rb:760` (walk_binops) ; `src/annotator-helpers/capabilities.rb:1073` (_unified_capture_walk) ; `src/annotator-helpers/capabilities.rb:1077` (_unified_capture_walk) ; `src/annotator-helpers/capabilities.rb:1085` (_unified_capture_walk)
- `.emit` -- ELIMINABLE guard-pressure **81** across 29 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator-helpers/capabilities.rb:412` (predicate_impurity_reason) ; `src/annotator-helpers/capabilities.rb:414` (predicate_impurity_reason) ; `src/annotator-helpers/capabilities.rb:415` (predicate_impurity_reason) ; `src/annotator-helpers/effects.rb:691` (scan_suspend_points)
- `.symbol` -- ELIMINABLE guard-pressure **66** across 45 method(s) -> tighten contract / nil-kill: DELETE  (+8 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator-helpers/capabilities.rb:93` (cap_var_sync) ; `src/annotator-helpers/capabilities.rb:118` (cap_var_layout) ; `src/annotator-helpers/capabilities.rb:142` (validate_capability) ; `src/annotator-helpers/capabilities.rb:164` (validate_capability)
- `.target` -- ELIMINABLE guard-pressure **60** across 35 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator-helpers/auto_inference.rb:655` (record_index_assign) ; `src/annotator-helpers/capabilities.rb:764` (cap_var_name) ; `src/annotator-helpers/function_analysis.rb:915` (verify_return) ; `src/annotator-helpers/generic_analysis.rb:645` (find_container_source)
- `.name` -- ELIMINABLE guard-pressure **55** across 38 method(s) -> tighten contract / nil-kill: DELETE  (+4 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator-helpers/auto_inference.rb:653` (record_index_assign) ; `src/annotator-helpers/capabilities.rb:1058` (_unified_capture_walk) ; `src/annotator-helpers/capabilities.rb:1310` (_bg_walk) ; `src/annotator-helpers/generic_analysis.rb:630` (register_container_borrow!)
- `.right` -- ELIMINABLE guard-pressure **53** across 17 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator-helpers/pipe_analysis.rb:24` (visit_Smooth) ; `src/annotator-helpers/pipe_analysis.rb:26` (visit_Smooth) ; `src/annotator-helpers/pipe_analysis.rb:270` (analyze_select_family_op) ; `src/annotator-helpers/pipe_analysis.rb:270` (analyze_select_family_op)
- `.current_fn_ctx` -- ELIMINABLE guard-pressure **32** across 22 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator-helpers/capabilities.rb:1166` (_unified_capture_walk) ; `src/annotator-helpers/capabilities.rb:1203` (_unified_capture_walk) ; `src/annotator-helpers/capabilities.rb:1347` (record_capability_binding) ; `src/annotator-helpers/capabilities.rb:1355` (record_capability_binding)
- `.left` -- ELIMINABLE guard-pressure **29** across 18 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator-helpers/pipe_analysis.rb:63` (stamp_observable_terminal!) ; `src/annotator-helpers/pipe_analysis.rb:247` (analyze_collect_op) ; `src/annotator-helpers/pipe_analysis.rb:599` (analyze_limit_op) ; `src/annotator-helpers/pipe_analysis.rb:1342` (analyze_shard_op)
- `.type` -- ELIMINABLE guard-pressure **27** across 21 method(s) -> tighten contract / nil-kill: DELETE  (+25 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator-helpers/auto_inference.rb:210` (record_local) ; `src/annotator-helpers/auto_inference.rb:504` (stamp_map_pairs!) ; `src/annotator-helpers/auto_inference.rb:505` (stamp_map_pairs!) ; `src/annotator-helpers/auto_inference.rb:572` (walk_for_shape_decls)
- `.last` -- ELIMINABLE guard-pressure **25** across 6 method(s) -> tighten contract / nil-kill: DELETE  (+2 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator.rb:5695` (expr_result_type) ; `src/annotator.rb:5697` (expr_result_type) ; `src/annotator.rb:5704` (expr_result_type) ; `src/annotator.rb:5704` (expr_result_type)
- `.token` -- ELIMINABLE guard-pressure **24** across 19 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator-helpers/capabilities.rb:1359` (record_capability_binding) ; `src/annotator-helpers/capabilities.rb:1360` (record_capability_binding) ; `src/mir/concurrency_checks.rb:73` (check_hold_across_yield!) ; `src/mir/concurrency_checks.rb:171` (check_reentrant!)
- `[name]` -- ELIMINABLE guard-pressure **22** across 21 method(s) -> tighten contract / nil-kill: DELETE  (+3 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator-helpers/effects.rb:980` (max_tier_for_calls) ; `src/annotator-helpers/fixable_helpers.rb:310` (emit_use_of_moved_error!) ; `src/annotator-helpers/fixable_helpers.rb:997` (emit_with_materialized_needs_tense!) ; `src/annotator-helpers/fixable_helpers.rb:1200` (build_decl_cap_insert_fix)
- `.element_type` -- ELIMINABLE guard-pressure **22** across 18 method(s) -> tighten contract / nil-kill: DELETE  (+6 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator-helpers/function_return.rb:76` (resolve) ; `src/annotator-helpers/generic_analysis.rb:182` (validate_type_annotation!) ; `src/annotator-helpers/method_analysis.rb:43` (narrow_collection_type!) ; `src/annotator-helpers/method_analysis.rb:127` (resolve_typed_method)
- `.capture_analysis` -- ELIMINABLE guard-pressure **21** across 15 method(s) -> tighten contract / nil-kill: DELETE
  - `src/mir/control_flow.rb:611` (resource_captures) ; `src/mir/control_flow.rb:881` (collect_bg_body_gives) ; `src/mir/control_flow.rb:1118` (check_stmt_reads) ; `src/mir/control_flow.rb:1119` (check_stmt_reads)
- `.tail` -- ELIMINABLE guard-pressure **21** across 6 method(s) -> tighten contract / nil-kill: DELETE
  - `src/mir/fsm_transform/emit.rb:341` (build_recursive) ; `src/mir/fsm_transform/emit.rb:375` (build_recursive) ; `src/mir/fsm_transform/emit.rb:376` (build_recursive) ; `src/mir/fsm_transform/emit.rb:444` (build_recursive)
- `[:var_node]` -- ELIMINABLE guard-pressure **18** across 12 method(s) -> tighten contract / nil-kill: DELETE  (+2 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator-helpers/capabilities.rb:668` (acquire_capability!) ; `src/annotator-helpers/capabilities.rb:679` (acquire_capability!) ; `src/annotator-helpers/capabilities.rb:709` (acquire_capability!) ; `src/annotator-helpers/capabilities.rb:714` (acquire_capability!)
- `.return_type` -- ELIMINABLE guard-pressure **18** across 11 method(s) -> tighten contract / nil-kill: DELETE  (+13 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator-helpers/capabilities.rb:566` (visit_post_clauses!) ; `src/annotator-helpers/function_analysis.rb:176` (resolve_call) ; `src/annotator-helpers/reentrance.rb:162` (validate_not_logical_return!) ; `src/annotator-helpers/reentrance.rb:164` (validate_not_logical_return!)
- `.type_params` -- ELIMINABLE guard-pressure **17** across 10 method(s) -> tighten contract / nil-kill: DELETE  (+2 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator-helpers/function_analysis.rb:155` (resolve_call) ; `src/annotator-helpers/generic_analysis.rb:235` (validate_type_annotation!) ; `src/annotator-helpers/generic_analysis.rb:246` (validate_type_annotation!) ; `src/annotator.rb:1108` (visit_StructDef)
- `.payload_type` -- ELIMINABLE guard-pressure **17** across 5 method(s) -> tighten contract / nil-kill: DELETE  (+6 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator-helpers/function_analysis.rb:198` (resolve_call) ; `src/annotator-helpers/function_analysis.rb:201` (resolve_call) ; `src/annotator-helpers/function_analysis.rb:205` (resolve_call) ; `src/annotator-helpers/function_analysis.rb:206` (resolve_call)
- `.reg` -- ELIMINABLE guard-pressure **16** across 12 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator-helpers/fixable_helpers.rb:1000` (emit_with_materialized_needs_tense!) ; `src/annotator-helpers/fixable_helpers.rb:1201` (build_decl_cap_insert_fix) ; `src/annotator-helpers/fixable_helpers.rb:1229` (build_decl_cap_replace_fix) ; `src/annotator-helpers/function_analysis.rb:976` (return_is_borrow?)
- `@union_schemas` -- ELIMINABLE guard-pressure **14** across 12 method(s) -> tighten contract / nil-kill: DELETE
  - `src/mir/mir_lowering.rb:54` (initialize) ; `src/mir/mir_lowering.rb:271` (owned_value_temp_needs_cleanup?) ; `src/mir/mir_lowering.rb:298` (copy_container_borrow_if_needed) ; `src/mir/mir_lowering.rb:1339` (lower_function_def)
- `.expr` -- ELIMINABLE guard-pressure **14** across 9 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator.rb:1313` (visit_IfBind) ; `src/annotator.rb:1453` (visit_MatchStatement) ; `src/annotator.rb:1516` (visit_MatchStatement) ; `src/annotator.rb:5417` (visit_NextExpr)
- `.arms` -- ELIMINABLE guard-pressure **14** across 8 method(s) -> tighten contract / nil-kill: DELETE  (+2 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator-helpers/capabilities.rb:1239` (_unified_capture_walk) ; `src/annotator-helpers/effects.rb:1177` (scan_for_raises) ; `src/annotator.rb:4592` (visit_WithBlock) ; `src/annotator.rb:4751` (visit_WithBlock)
- `@og` -- ELIMINABLE guard-pressure **14** across 6 method(s) -> tighten contract / nil-kill: DELETE  (+6 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator.rb:1204` (analyze_control_flow_branches) ; `src/annotator.rb:1211` (analyze_control_flow_branches) ; `src/annotator.rb:1217` (analyze_control_flow_branches) ; `src/annotator.rb:1228` (analyze_control_flow_branches)
- ...(+231 more)

## Missing Abstractions (204)
_guard tuple recomputed across >=2 decision units_

- **[case_dispatch]** support=7 scatter=7 rank=49
  - tuple: `'(' | ')' | ';' | '[' | ']' | '{' | '}'`
  - `src/tools/formatter.rb:477` (match_block_start?) ; `src/tools/formatter.rb:603` (build_match_arm) ; `src/tools/formatter.rb:703` (emit_match_body) ; `src/tools/formatter.rb:1070` (find_fn_arrow) ; `src/tools/formatter.rb:1654` (find_concurrent_stage_end) ; `src/tools/formatter.rb:2039` (count_statements_in_block)
- **[case_dispatch]** support=7 scatter=7 rank=49
  - tuple: `'(' | ')' | '[' | ']' | '{' | '}'`
  - `src/tools/formatter.rb:503` (find_match_block_end) ; `src/tools/formatter.rb:1135` (branch_end_for_inline_expansion) ; `src/tools/formatter.rb:1179` (matching_end) ; `src/tools/formatter.rb:1553` (consume_on_segment) ; `src/tools/formatter.rb:1701` (expand_method_chains) ; `src/tools/formatter.rb:1994` (body_has_top_level_block?)
- **[case_dispatch]** support=7 scatter=6 rank=42
  - tuple: `AST::FuncCall | AST::MethodCall`
  - `src/mir/control_flow.rb:1433` (escapes_to_outer?) ; `src/mir/control_flow.rb:1485` (promote_outer_mutations!) ; `src/mir/control_flow.rb:1718` (key_allocates_frame?) ; `src/mir/escape_analysis.rb:127` (return_expr_is_heap?) ; `src/mir/escape_analysis.rb:139` (return_expr_is_heap?) ; `src/mir/escape_analysis.rb:232` (per_fn_scan!)
- **[conjunction]** support=6 scatter=6 rank=36
  - tuple: `bdepth.zero? | t.type == :KEYWORD`
  - `src/tools/formatter.rb:507` (find_match_block_end) ; `src/tools/formatter.rb:570` (scan_match_arms) ; `src/tools/formatter.rb:609` (build_match_arm) ; `src/tools/formatter.rb:714` (emit_match_body) ; `src/tools/formatter.rb:1139` (branch_end_for_inline_expansion) ; `src/tools/formatter.rb:1183` (matching_end)
- **[conjunction]** support=6 scatter=6 rank=36
  - tuple: `out.last | out.last.type == :NL`
  - `src/tools/formatter.rb:649` (emit_match_arm) ; `src/tools/formatter.rb:698` (emit_match_body) ; `src/tools/formatter.rb:1289` (expand_if_while_for) ; `src/tools/formatter.rb:1462` (emit_with_block) ; `src/tools/formatter.rb:1940` (emit_wrapped_args) ; `src/tools/formatter.rb:2396` (insert_nl)
- **[case_dispatch]** support=10 scatter=3 rank=30
  - tuple: `AST::GetField | AST::MethodCall`
  - `src/annotator.rb:1459` (visit_MatchStatement) ; `src/annotator.rb:1577` (visit_MatchStatement) ; `src/annotator.rb:1598` (visit_MatchStatement) ; `src/annotator.rb:1655` (visit_MatchStatement) ; `src/annotator.rb:1670` (visit_MatchStatement) ; `src/annotator.rb:1747` (visit_MatchStatement)
- **[case_dispatch]** support=5 scatter=5 rank=25
  - tuple: `:multiowned | :shared`
  - `src/annotator-helpers/capabilities.rb:105` (cap_var_storage) ; `src/mir/bg_capture_classifier.rb:142` (resolve_capture_type) ; `src/mir/mir_lowering.rb:2574` (with_cap_sync_storage) ; `src/mir/mir_lowering.rb:6003` (lower_cap_wrap) ; `src/mir/mir_lowering.rb:6139` (compose_capability_wrap)
- **[conjunction]** support=5 scatter=5 rank=25
  - tuple: `node.is_a?(AST::BinaryOp) | node.op == :SMOOTH`
  - `src/annotator.rb:1067` (collect_pipe_input_types) ; `src/backends/pipeline_host.rb:2145` (unwrap_range_chain) ; `src/backends/pipeline_host.rb:2173` (unwrap_binding_unnest_chain) ; `src/backends/pipeline_rewriter.rb:40` (rewrite!) ; `src/backends/pipeline_rewriter.rb:267` (binding_source?)
- **[case_dispatch]** support=5 scatter=5 rank=25
  - tuple: `AST::ForEach | AST::ForRange | AST::IfStatement | AST::WhileBindLoop | AST::WhileLoop | AST::WithBlock`
  - `src/mir/fsm_transform/recursive_splitter.rb:275` (stmt_introduces_split?) ; `src/mir/fsm_transform/recursive_splitter.rb:298` (contains_suspend_anywhere?) ; `src/mir/fsm_transform/recursive_splitter.rb:398` (emit_pivot) ; `src/mir/fsm_transform.rb:215` (body_needs_conservative?) ; `src/mir/fsm_transform.rb:238` (contains_suspend_anywhere?)
- **[conjunction]** support=5 scatter=5 rank=25
  - tuple: `entry | entry.needs_cleanup?`
  - `src/mir/mir_pass.rb:180` (transform_function!) ; `src/mir/mir_pass.rb:235` (walk_for_bg_captures) ; `src/mir/mir_pass.rb:430` (insert_bg_give_suppress!) ; `src/mir/mir_pass.rb:852` (stamp_while_bind_cleanup!) ; `src/mir/mir_pass.rb:866` (stamp_if_bind_cleanup!)
- **[case_dispatch]** support=5 scatter=5 rank=25
  - tuple: `'END' | 'FN' | 'FOR' | 'IF' | 'START' | 'TEST' | 'WHEN' | 'WHILE'`
  - `src/tools/formatter.rb:508` (find_match_block_end) ; `src/tools/formatter.rb:571` (scan_match_arms) ; `src/tools/formatter.rb:610` (build_match_arm) ; `src/tools/formatter.rb:715` (emit_match_body) ; `src/tools/formatter.rb:1184` (matching_end)
- **[case_dispatch]** support=5 scatter=5 rank=25
  - tuple: `'(' | ')' | ',' | '[' | ']' | '{' | '}'`
  - `src/tools/formatter.rb:556` (scan_match_arms) ; `src/tools/formatter.rb:911` (emit_fn_signature_wrapped) ; `src/tools/formatter.rb:1019` (emit_fn_params_only_wrapped) ; `src/tools/formatter.rb:1630` (count_depth0_commas) ; `src/tools/formatter.rb:1923` (emit_wrapped_args)
- **[case_dispatch]** support=5 scatter=4 rank=20
  - tuple: `AST::Assignment | AST::BindExpr | AST::VarDecl`
  - `src/mir/escape_analysis.rb:672` (tag_transitive_provenance!) ; `src/mir/fsm_transform/liveness.rb:197` (collect_defs) ; `src/mir/mir_pass.rb:693` (collect_consumed_names) ; `src/mir/mir_pass.rb:721` (collect_consumed_names) ; `src/tools/migration_suggester_helpers.rb:88` (walk_recursive)
- **[case_dispatch]** support=4 scatter=4 rank=16
  - tuple: `AST::GetField | AST::GetIndex | AST::Identifier`
  - `src/annotator-helpers/capabilities.rb:761` (cap_var_name) ; `src/ast/ast.rb:325` (root_identifier) ; `src/ast/parser.rb:3954` (deep_clone_node) ; `src/mir/mir_lowering.rb:796` (root_receiver_node)
- **[case_dispatch]** support=4 scatter=4 rank=16
  - tuple: `:always_mutable | :atomic | :local | :locked | :versioned | :write_locked`
  - `src/annotator-helpers/generic_analysis.rb:474` (generic_binding_source) ; `src/annotator-helpers/generic_analysis.rb:493` (shared_call_capability_display) ; `src/annotator.rb:2303` (type_display) ; `src/ast/parser.rb:2971` (type_annotation_source)
- **[conjunction]** support=4 scatter=4 rank=16
  - tuple: `%w[true TRUE].include?(node.right.options["parallel"].name) | node.right.options["parallel"].is_a?(AST::Identifier)`
  - `src/annotator-helpers/pipe_analysis.rb:1637` (analyze_concurrent_bounded_select_family_op) ; `src/annotator-helpers/pipe_analysis.rb:1670` (analyze_concurrent_bounded_each_op) ; `src/annotator-helpers/pipe_analysis.rb:1700` (analyze_concurrent_stream_select_family_op) ; `src/annotator-helpers/pipe_analysis.rb:1736` (analyze_concurrent_stream_each_op)
- **[case_dispatch]** support=4 scatter=4 rank=16
  - tuple: `AST::BindExpr | AST::VarDecl`
  - `src/mir/control_flow.rb:1369` (collect_local_names) ; `src/mir/control_flow.rb:1408` (local_frame_decls) ; `src/mir/control_flow.rb:1474` (promote_outer_mutations!) ; `src/mir/escape_analysis.rb:882` (e3_find_decl)
- **[conjunction]** support=4 scatter=4 rank=16
  - tuple: `Type.new(expr_type).zig_type == "void" | expr_type.respond_to?(:to_s)`
  - `src/mir/fsm_lowering.rb:124` (lower_step_stmts) ; `src/mir/fsm_lowering.rb:203` (wrap_step_as_stmt) ; `src/mir/mir_lowering.rb:3791` (lower_do_block) ; `src/mir/mir_lowering.rb:3967` (lower_bg_block)
- **[conjunction]** support=4 scatter=4 rank=16
  - tuple: `!ti.string? | ti.array?`
  - `src/mir/mir_lowering.rb:282` (container_borrow_expr?) ; `src/mir/mir_lowering.rb:7588` (direct_indexable_collection_type?) ; `src/mir/mir_lowering.rb:7628` (lower_direct_length) ; `src/mir/promotion_plan.rb:512` (takes_param_base_entry)
- **[conjunction]** support=4 scatter=4 rank=16
  - tuple: `out.last | out.last.type == :NL | out.length > body_start`
  - `src/tools/formatter.rb:839` (emit_fn_block) ; `src/tools/formatter.rb:1338` (expand_if_while_for) ; `src/tools/formatter.rb:2117` (emit_bg_do_wrapped) ; `src/tools/formatter.rb:2382` (emit_record_type)
- **[conjunction]** support=4 scatter=4 rank=16
  - tuple: `j < toks.length | toks[j].type == :NL`
  - `src/tools/formatter.rb:851` (skip_nls) ; `src/tools/formatter.rb:2232` (detect_recover_stages) ; `src/tools/formatter.rb:2374` (emit_record_type) ; `src/tools/formatter.rb:2417` (emit_stmt_terminator)
- **[conjunction]** support=4 scatter=3 rank=12
  - tuple: `cursor.is_a?(AST::BinaryOp) | cursor.op == :SMOOTH`
  - `src/backends/pipeline_host.rb:2149` (unwrap_range_chain) ; `src/backends/pipeline_host.rb:2183` (unwrap_binding_unnest_chain) ; `src/backends/pipeline_host.rb:2194` (unwrap_binding_unnest_chain) ; `src/backends/pipeline_rewriter.rb:294` (collect_chain)
- **[conjunction]** support=4 scatter=3 rank=12
  - tuple: `bdepth.zero? | kdepth.zero?`
  - `src/tools/formatter.rb:560` (scan_match_arms) ; `src/tools/formatter.rb:601` (build_match_arm) ; `src/tools/formatter.rb:607` (build_match_arm) ; `src/tools/formatter.rb:707` (emit_match_body)
- **[case_dispatch]** support=3 scatter=3 rank=9
  - tuple: `:local | :param | :return`
  - `src/annotator-helpers/auto_inference.rb:473` (stamp_slot!) ; `src/annotator-helpers/fixable_helpers.rb:1587` (slot_id_for) ; `src/annotator-helpers/fixable_helpers.rb:1625` (auto_slot_label)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `slot.respond_to?(:shape) | slot.shape`
  - `src/annotator-helpers/fixable_helpers.rb:1461` (emit_auto_resolved_finding!) ; `src/annotator-helpers/fixable_helpers.rb:1616` (auto_slot_label) ; `src/annotator.rb:240` (emit_auto_shape_resolved_findings!)
- ...(+179 more)

## Reification Misses (83)
_an existing predicate reinvented inline -- invariant #16_

- predicate `atomic?` reinvented inline at `src/annotator.rb:3153` (visit_Assignment) (`sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/annotator.rb:3430` (visit_GetField) (`sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/ast/parser.rb:2936` (parse_type_annotation) (`sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/mir/escape_analysis.rb:821` (param_accepts_caller_sync?) (`sync == :atomic`)
- predicate `bc_target?` reinvented inline at `src/backends/pipeline_host.rb:481` (build_pipe_items_mir) (`@lowering.instance_variable_get(:@target) == :bc`)
- predicate `bc_target?` reinvented inline at `src/backends/pipeline_host.rb:1996` (lower_each) (`@lowering.instance_variable_get(:@target) == :bc`)
- predicate `bc_target?` reinvented inline at `src/backends/pipeline_host.rb:3327` (lower_concurrent) (`@lowering.instance_variable_get(:@target) == :bc`)
- predicate `fixed_return?` reinvented inline at `src/annotator-helpers/intrinsic_registry.rb:78` (to_return_type) (`rdef.kind == FunctionReturn::Kind::Fixed`)
- predicate `indirect?` reinvented inline at `src/annotator-helpers/lock_helper.rb:400` (verify_handler_reachability!) (`sym.layout == :indirect`)
- predicate `indirect?` reinvented inline at `src/annotator.rb:2281` (same_return_capabilities?) (`expected_t.layout == :indirect`)
- predicate `indirect?` reinvented inline at `src/annotator.rb:3153` (visit_Assignment) (`layout == :indirect`)
- predicate `indirect?` reinvented inline at `src/annotator.rb:3430` (visit_GetField) (`layout == :indirect`)
- predicate `indirect?` reinvented inline at `src/annotator.rb:4203` (visit_CapabilityWrap) (`node.layout == :indirect`)
- predicate `indirect?` reinvented inline at `src/annotator.rb:4893` (validate_lock_error_clause!) (`sym.layout == :indirect`)
- predicate `indirect?` reinvented inline at `src/annotator.rb:4968` (reject_bare_atomic_ptr_mutation!) (`sym.layout == :indirect`)
- predicate `indirect?` reinvented inline at `src/ast/parser.rb:2936` (parse_type_annotation) (`layout == :indirect`)
- predicate `indirect?` reinvented inline at `src/ast/type.rb:289` (initialize) (`@layout == :indirect`)
- predicate `indirect?` reinvented inline at `src/ast/type.rb:2170` (compute_zig_type) (`@layout == :indirect`)
- predicate `indirect?` reinvented inline at `src/mir/mir_lowering.rb:3432` (emit_snapshot_mutable_call) (`sym.layout == :indirect`)
- predicate `indirect?` reinvented inline at `src/mir/mir_lowering.rb:6008` (lower_cap_wrap) (`node.layout == :indirect`)
- predicate `indirect?` reinvented inline at `src/mir/mir_lowering.rb:6069` (rc_payload_zig_type) (`payload.layout == :indirect`)
- predicate `local?` reinvented inline at `src/annotator-helpers/capabilities.rb:1140` (_unified_capture_walk) (`info.sync == :local`)
- predicate `local?` reinvented inline at `src/annotator-helpers/capabilities.rb:1153` (_unified_capture_walk) (`info.sync == :local`)
- predicate `local?` reinvented inline at `src/annotator-helpers/capabilities.rb:1196` (_unified_capture_walk) (`info.sync == :local`)
- predicate `local?` reinvented inline at `src/annotator-helpers/capabilities.rb:1197` (_unified_capture_walk) (`info.sync == :local`)
- ...(+58 more)

## Semantic Predicate Aliases (3)
_one decision, multiple names (receiver/polarity folded)_

- `enum? = resource? = union? = struct? = needs_capture_site_annotation? = mir? = stmt? = expr? = has_own_frame?` == `true`
  - `src/ast/schemas.rb:34` (enum?) ; `src/ast/schemas.rb:67` (resource?) ; `src/ast/schemas.rb:123` (union?) ; `src/ast/schemas.rb:169` (struct?) ; `src/mir/capture_strategy.rb:79` (needs_capture_site_annotation?) ; `src/mir/capture_strategy.rb:95` (needs_capture_site_annotation?) ; `src/mir/mir.rb:28` (mir?) ; `src/mir/mir.rb:40` (stmt?) ; `src/mir/mir.rb:62` (expr?) ; `src/mir/mir.rb:90` (has_own_frame?) ; `src/mir/mir.rb:364` (expr?) ; `src/mir/mir.rb:417` (expr?) ; `src/mir/mir.rb:431` (expr?) ; `src/mir/mir.rb:547` (expr?) ; `src/mir/mir.rb:558` (expr?) ; `src/mir/mir.rb:573` (expr?) ; `src/mir/mir.rb:609` (expr?) ; `src/mir/mir.rb:1259` (stmt?) ; `src/mir/mir.rb:1291` (stmt?) ; `src/mir/mir.rb:1313` (stmt?) ; `src/mir/mir.rb:1340` (stmt?) ; `src/mir/mir.rb:1349` (stmt?) ; `src/mir/mir.rb:1363` (stmt?) ; `src/mir/mir.rb:1375` (stmt?) ; `src/mir/mir.rb:1389` (stmt?) ; `src/mir/mir.rb:1398` (stmt?) ; `src/mir/mir.rb:1406` (stmt?) ; `src/mir/mir.rb:1414` (stmt?) ; `src/mir/mir.rb:1686` (expr?) ; `src/mir/mir.rb:1766` (expr?) ; `src/mir/mir.rb:1810` (expr?)
- `wildcard? = union? = struct? = resource? = enum? = needs_capture_site_annotation? = stmt? = expr?` == `false`
  - `src/ast/ast.rb:1154` (wildcard?) ; `src/ast/ast.rb:1297` (wildcard?) ; `src/ast/ast.rb:1312` (wildcard?) ; `src/ast/schemas.rb:36` (union?) ; `src/ast/schemas.rb:38` (struct?) ; `src/ast/schemas.rb:40` (resource?) ; `src/ast/schemas.rb:69` (union?) ; `src/ast/schemas.rb:71` (enum?) ; `src/ast/schemas.rb:73` (struct?) ; `src/ast/schemas.rb:125` (enum?) ; `src/ast/schemas.rb:127` (struct?) ; `src/ast/schemas.rb:129` (resource?) ; `src/ast/schemas.rb:171` (union?) ; `src/ast/schemas.rb:173` (enum?) ; `src/ast/schemas.rb:175` (resource?) ; `src/mir/capture_strategy.rb:51` (needs_capture_site_annotation?) ; `src/mir/capture_strategy.rb:64` (needs_capture_site_annotation?) ; `src/mir/capture_strategy.rb:108` (needs_capture_site_annotation?) ; `src/mir/mir.rb:30` (stmt?) ; `src/mir/mir.rb:32` (expr?)
- `auto? = auto_type?` == `t.is_a?(Type) && t.auto?`
  - `src/annotator-helpers/auto_inference.rb:98` (auto?) ; `src/annotator-helpers/auto_inference.rb:787` (auto?) ; `src/backends/importer.rb:163` (auto_type?)

## Exact Predicate Aliases (6)
_identical one-line predicate body under >=2 names_

- `needs_cleanup = enum? = resource? = union? = struct? = needs_capture_site_annotation? = mir? = stmt? = expr? = has_own_frame?` == `true`
  - `src/ast/ast.rb:2011` (needs_cleanup) ; `src/ast/schemas.rb:34` (enum?) ; `src/ast/schemas.rb:67` (resource?) ; `src/ast/schemas.rb:123` (union?) ; `src/ast/schemas.rb:169` (struct?) ; `src/mir/capture_strategy.rb:79` (needs_capture_site_annotation?) ; `src/mir/capture_strategy.rb:95` (needs_capture_site_annotation?) ; `src/mir/mir.rb:28` (mir?) ; `src/mir/mir.rb:40` (stmt?) ; `src/mir/mir.rb:62` (expr?) ; `src/mir/mir.rb:90` (has_own_frame?) ; `src/mir/mir.rb:364` (expr?) ; `src/mir/mir.rb:417` (expr?) ; `src/mir/mir.rb:431` (expr?) ; `src/mir/mir.rb:547` (expr?) ; `src/mir/mir.rb:558` (expr?) ; `src/mir/mir.rb:573` (expr?) ; `src/mir/mir.rb:609` (expr?) ; `src/mir/mir.rb:1259` (stmt?) ; `src/mir/mir.rb:1291` (stmt?) ; `src/mir/mir.rb:1313` (stmt?) ; `src/mir/mir.rb:1340` (stmt?) ; `src/mir/mir.rb:1349` (stmt?) ; `src/mir/mir.rb:1363` (stmt?) ; `src/mir/mir.rb:1375` (stmt?) ; `src/mir/mir.rb:1389` (stmt?) ; `src/mir/mir.rb:1398` (stmt?) ; `src/mir/mir.rb:1406` (stmt?) ; `src/mir/mir.rb:1414` (stmt?) ; `src/mir/mir.rb:1686` (expr?) ; `src/mir/mir.rb:1766` (expr?) ; `src/mir/mir.rb:1810` (expr?)
- `wildcard? = union? = struct? = resource? = enum? = needs_capture_site_annotation? = stmt? = expr?` == `false`
  - `src/ast/ast.rb:1154` (wildcard?) ; `src/ast/ast.rb:1297` (wildcard?) ; `src/ast/ast.rb:1312` (wildcard?) ; `src/ast/schemas.rb:36` (union?) ; `src/ast/schemas.rb:38` (struct?) ; `src/ast/schemas.rb:40` (resource?) ; `src/ast/schemas.rb:69` (union?) ; `src/ast/schemas.rb:71` (enum?) ; `src/ast/schemas.rb:73` (struct?) ; `src/ast/schemas.rb:125` (enum?) ; `src/ast/schemas.rb:127` (struct?) ; `src/ast/schemas.rb:129` (resource?) ; `src/ast/schemas.rb:171` (union?) ; `src/ast/schemas.rb:173` (enum?) ; `src/ast/schemas.rb:175` (resource?) ; `src/mir/capture_strategy.rb:51` (needs_capture_site_annotation?) ; `src/mir/capture_strategy.rb:64` (needs_capture_site_annotation?) ; `src/mir/capture_strategy.rb:108` (needs_capture_site_annotation?) ; `src/mir/mir.rb:30` (stmt?) ; `src/mir/mir.rb:32` (expr?)
- `visit_PassStmt = visit_OrRaise = visit_OrBreak = visit_OrPass = visit_OrPrune` == `node.full_type = :Void`
  - `src/annotator.rb:1419` (visit_PassStmt) ; `src/annotator.rb:4116` (visit_OrRaise) ; `src/annotator.rb:4121` (visit_OrBreak) ; `src/annotator.rb:4126` (visit_OrPass) ; `src/annotator.rb:4133` (visit_OrPrune)
- `emit_rc_retain = emit_rc_downgrade = emit_weak_upgrade` == `"CheatLib.#{node.func}(#{node.zig_base}, #{emit(node.source)})"`
  - `src/mir/mir_emitter.rb:1262` (emit_rc_retain) ; `src/mir/mir_emitter.rb:1267` (emit_rc_downgrade) ; `src/mir/mir_emitter.rb:1272` (emit_weak_upgrade)
- `auto? = auto_type?` == `t.is_a?(Type) && t.auto?`
  - `src/annotator-helpers/auto_inference.rb:98` (auto?) ; `src/annotator-helpers/auto_inference.rb:787` (auto?) ; `src/backends/importer.rb:163` (auto_type?)
- `child_bodies = marker_plan` == `[]`
  - `src/ast/ast.rb:509` (child_bodies) ; `src/mir/capture_strategy.rb:49` (marker_plan) ; `src/mir/capture_strategy.rb:62` (marker_plan) ; `src/mir/capture_strategy.rb:106` (marker_plan)

## Type-3 Clones (missed rename) (14)
_pasted block, one identifier inconsistently renamed -- *POSSIBLE* bug_

- *POSSIBLE* `src/tools/formatter.rb:705` (emit_match_body) clone of `src/tools/formatter.rb:704` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:801` (emit_fn_block) clone of `src/tools/formatter.rb:704` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:813` (emit_fn_block) clone of `src/tools/formatter.rb:704` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:913` (emit_fn_signature_wrapped) clone of `src/tools/formatter.rb:704` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:1021` (emit_fn_params_only_wrapped) clone of `src/tools/formatter.rb:704` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:1273` (expand_if_while_for) clone of `src/tools/formatter.rb:704` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:1275` (expand_if_while_for) clone of `src/tools/formatter.rb:704` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:1277` (expand_if_while_for) clone of `src/tools/formatter.rb:704` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:1925` (emit_wrapped_args) clone of `src/tools/formatter.rb:704` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2093` (emit_bg_do_wrapped) clone of `src/tools/formatter.rb:704` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2364` (emit_record_type) clone of `src/tools/formatter.rb:704` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2368` (emit_record_type) clone of `src/tools/formatter.rb:704` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2370` (emit_record_type) clone of `src/tools/formatter.rb:704` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/annotator.rb:4099` (visit_OrRescue) clone of `src/annotator.rb:4085` (visit_OrRescue): ref var `payload_type` spelled ["wrapped", "wrapped_type"] here

## Neglected Updates (6820)
_co-written state, one write missing -- *POSSIBLE* redundant-state desync_

- *POSSIBLE* (support=52) `src/annotator-helpers/function_analysis.rb:146` (resolve_call) writes `.full_type` but NOT `.storage` (recv `args[i]`)
- *POSSIBLE* (support=52) `src/annotator-helpers/function_analysis.rb:747` (declare_and_verify_params) writes `.full_type` but NOT `.storage` (recv `param.default`)
- *POSSIBLE* (support=52) `src/annotator-helpers/function_analysis.rb:855` (verify_captures!) writes `.storage` but NOT `.full_type` (recv `cap`)
- *POSSIBLE* (support=52) `src/annotator-helpers/generic_analysis.rb:544` (propagate_declared_type_to_value!) writes `.full_type` but NOT `.storage` (recv `node.value`)
- *POSSIBLE* (support=52) `src/annotator-helpers/method_analysis.rb:53` (narrow_collection_type!) writes `.full_type` but NOT `.storage` (recv `list_arg`)
- *POSSIBLE* (support=52) `src/annotator-helpers/method_analysis.rb:90` (resolve_typed_method) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=52) `src/annotator-helpers/pipe_analysis.rb:31` (visit_Smooth) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=52) `src/annotator-helpers/pipe_analysis.rb:87` (lift_to_observable_if_terminal!) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=52) `src/annotator-helpers/pipe_analysis.rb:229` (analyze_higher_order_op) writes `.full_type` but NOT `.storage` (recv `node.right`)
- *POSSIBLE* (support=52) `src/annotator-helpers/pipe_analysis.rb:737` (analyze_pipe_to_func_call) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=52) `src/annotator-helpers/pipe_analysis.rb:758` (analyze_pipe_to_identifier) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=52) `src/annotator-helpers/pipe_analysis.rb:799` (analyze_pipe_to_named_function) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=52) `src/annotator-helpers/pipe_analysis.rb:1264` (auto_detect_sharded_access) writes `.full_type` but NOT `.storage` (recv `map_ident`)
- *POSSIBLE* (support=52) `src/annotator-helpers/test_annotation.rb:37` (visit_TestBlock) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=52) `src/annotator-helpers/test_annotation.rb:63` (visit_WhenBlock) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=52) `src/annotator-helpers/test_annotation.rb:106` (visit_TestThat) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=52) `src/annotator-helpers/test_annotation.rb:113` (visit_AssertRaises) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=52) `src/annotator-helpers/test_annotation.rb:120` (visit_BenchmarkStmt) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=52) `src/annotator-helpers/test_annotation.rb:127` (visit_SmashStmt) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=52) `src/annotator-helpers/test_annotation.rb:134` (visit_ProfileStmt) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=52) `src/annotator-helpers/test_annotation.rb:151` (visit_StubDecl) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=52) `src/annotator-helpers/union.rb:115` (resolve_variant_access) writes `.full_type` but NOT `.storage` (recv `node.target`)
- *POSSIBLE* (support=52) `src/annotator.rb:475` (visit_Program) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=52) `src/annotator.rb:494` (visit_RequireNode) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=52) `src/annotator.rb:568` (visit_ExternFnDecl) writes `.full_type` but NOT `.storage` (recv `node`)
- ...(+6795 more)

## Derived-State Staleness (241)
_b = f(a); a later reassigned, b not recomputed -- *POSSIBLE* bug_

- *POSSIBLE* `src/backends/pipeline_rewriter.rb:609` (build_terminal_action): `actions` derived from `call` (line 609); `call` reassigned line 719, `actions` not recomputed
- *POSSIBLE* `src/backends/pipeline_rewriter.rb:609` (build_terminal_action): `actions` derived from `insert_call` (line 609); `insert_call` reassigned line 712, `actions` not recomputed
- *POSSIBLE* `src/backends/pipeline_rewriter.rb:609` (build_terminal_action): `actions` derived from `key_expr` (line 609); `key_expr` reassigned line 711, `actions` not recomputed
- *POSSIBLE* `src/backends/pipeline_rewriter.rb:609` (build_terminal_action): `actions` derived from `inner_foreach` (line 609); `inner_foreach` reassigned line 704, `actions` not recomputed
- *POSSIBLE* `src/backends/pipeline_rewriter.rb:609` (build_terminal_action): `actions` derived from `append` (line 609); `append` reassigned line 697, `actions` not recomputed
- *POSSIBLE* `src/backends/pipeline_rewriter.rb:609` (build_terminal_action): `actions` derived from `et` (line 609); `et` reassigned line 693, `actions` not recomputed
- *POSSIBLE* `src/backends/pipeline_rewriter.rb:609` (build_terminal_action): `actions` derived from `inner_it` (line 609); `inner_it` reassigned line 689, `actions` not recomputed
- *POSSIBLE* `src/backends/pipeline_rewriter.rb:609` (build_terminal_action): `actions` derived from `inner_it_var` (line 609); `inner_it_var` reassigned line 687, `actions` not recomputed
- *POSSIBLE* `src/backends/pipeline_rewriter.rb:609` (build_terminal_action): `actions` derived from `inner_expr` (line 609); `inner_expr` reassigned line 686, `actions` not recomputed
- *POSSIBLE* `src/ast/ast.rb:738` (finalize_storage!): `value_sync` derived from `vt` (line 738); `vt` reassigned line 814, `value_sync` not recomputed
- *POSSIBLE* `src/mir/mir_lowering.rb:7353` (lower_return): `stmts` derived from `value` (line 7353); `value` reassigned line 7421, `stmts` not recomputed
- *POSSIBLE* `src/backends/pipeline_rewriter.rb:609` (build_terminal_action): `actions` derived from `set_found` (line 609); `set_found` reassigned line 676, `actions` not recomputed
- *POSSIBLE* `src/backends/pipeline_rewriter.rb:609` (build_terminal_action): `actions` derived from `assign_val` (line 609); `assign_val` reassigned line 674, `actions` not recomputed
- *POSSIBLE* `src/backends/pipeline_rewriter.rb:609` (build_terminal_action): `actions` derived from `cond` (line 609); `cond` reassigned line 671, `actions` not recomputed
- *POSSIBLE* `src/backends/pipeline_rewriter.rb:609` (build_terminal_action): `actions` derived from `cmp` (line 609); `cmp` reassigned line 669, `actions` not recomputed
- *POSSIBLE* `src/tools/doctor.rb:158` (section_heap): `addrs` derived from `sites` (line 158); `sites` reassigned line 218, `addrs` not recomputed
- *POSSIBLE* `src/ast/type.rb:2144` (compute_zig_type): `inner_zig` derived from `base_zig` (line 2144); `base_zig` reassigned line 2202, `inner_zig` not recomputed
- *POSSIBLE* `src/backends/pipeline_rewriter.rb:609` (build_terminal_action): `actions` derived from `not_found` (line 609); `not_found` reassigned line 667, `actions` not recomputed
- *POSSIBLE* `src/backends/pipeline_rewriter.rb:609` (build_terminal_action): `actions` derived from `found_ident` (line 609); `found_ident` reassigned line 663, `actions` not recomputed
- *POSSIBLE* `src/annotator.rb:2128` (visit_ReturnNode): `expected_void_compatible` derived from `expected` (line 2128); `expected` reassigned line 2181, `expected_void_compatible` not recomputed
- *POSSIBLE* `src/backends/pipeline_rewriter.rb:609` (build_terminal_action): `actions` derived from `op` (line 609); `op` reassigned line 662, `actions` not recomputed
- *POSSIBLE* `src/mir/mir_lowering.rb:6218` (lower_var_decl): `init` derived from `is_move` (line 6218); `is_move` reassigned line 6264, `init` not recomputed
- *POSSIBLE* `src/annotator-helpers/capabilities.rb:204` (validate_capability): `atomic_ptr_ok` derived from `syn` (line 204); `syn` reassigned line 249, `atomic_ptr_ok` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:2747` (needs_space?): `a_is_struct_open` derived from `a_idx` (line 2747); `a_idx` reassigned line 2791, `a_is_struct_open` not recomputed
- *POSSIBLE* `src/mir/mir_lowering.rb:4986` (lower_binary_op): `left_is_comptime` derived from `left_ti` (line 4986); `left_ti` reassigned line 5024, `left_is_comptime` not recomputed
- ...(+216 more)

## Neglected Conditions (47)
_dispatch/conjunction minus one element -- *POSSIBLE* bug_

- *POSSIBLE* (support=7) `src/tools/formatter.rb:503` (find_match_block_end) -- MISSING `';'` from `'(' | ')' | ';' | '[' | ']' | '{' | '}'`
- *POSSIBLE* (support=7) `src/tools/formatter.rb:1135` (branch_end_for_inline_expansion) -- MISSING `';'` from `'(' | ')' | ';' | '[' | ']' | '{' | '}'`
- *POSSIBLE* (support=7) `src/tools/formatter.rb:1179` (matching_end) -- MISSING `';'` from `'(' | ')' | ';' | '[' | ']' | '{' | '}'`
- *POSSIBLE* (support=7) `src/tools/formatter.rb:1493` (find_with_open_brace) -- MISSING `'}'` from `'(' | ')' | '[' | ']' | '{' | '}'`
- *POSSIBLE* (support=7) `src/tools/formatter.rb:1553` (consume_on_segment) -- MISSING `';'` from `'(' | ')' | ';' | '[' | ']' | '{' | '}'`
- *POSSIBLE* (support=7) `src/tools/formatter.rb:1701` (expand_method_chains) -- MISSING `';'` from `'(' | ')' | ';' | '[' | ']' | '{' | '}'`
- *POSSIBLE* (support=7) `src/tools/formatter.rb:1994` (body_has_top_level_block?) -- MISSING `';'` from `'(' | ')' | ';' | '[' | ']' | '{' | '}'`
- *POSSIBLE* (support=7) `src/tools/formatter.rb:2137` (bg_body_has_strategy_arrow?) -- MISSING `';'` from `'(' | ')' | ';' | '[' | ']' | '{' | '}'`
- *POSSIBLE* (support=5) `src/mir/control_flow.rb:1369` (collect_local_names) -- MISSING `AST::Assignment` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- *POSSIBLE* (support=5) `src/mir/control_flow.rb:1408` (local_frame_decls) -- MISSING `AST::Assignment` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- *POSSIBLE* (support=5) `src/mir/control_flow.rb:1474` (promote_outer_mutations!) -- MISSING `AST::Assignment` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- *POSSIBLE* (support=5) `src/mir/escape_analysis.rb:882` (e3_find_decl) -- MISSING `AST::Assignment` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- *POSSIBLE* (support=5) `src/tools/atomic_migration_suggester.rb:129` (stmt_eligible?) -- MISSING `AST::VarDecl` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- *POSSIBLE* (support=5) `src/tools/atomic_ptr_migration_suggester.rb:120` (stmt_eligible?) -- MISSING `AST::VarDecl` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- *POSSIBLE* (support=5) `src/tools/formatter.rb:503` (find_match_block_end) -- MISSING `','` from `'(' | ')' | ',' | '[' | ']' | '{' | '}'`
- *POSSIBLE* (support=5) `src/tools/formatter.rb:1135` (branch_end_for_inline_expansion) -- MISSING `','` from `'(' | ')' | ',' | '[' | ']' | '{' | '}'`
- *POSSIBLE* (support=5) `src/tools/formatter.rb:1179` (matching_end) -- MISSING `','` from `'(' | ')' | ',' | '[' | ']' | '{' | '}'`
- *POSSIBLE* (support=5) `src/tools/formatter.rb:1208` (one_liner_end) -- MISSING `'START'` from `'END' | 'FN' | 'FOR' | 'IF' | 'START' | 'TEST' | 'WHEN' | 'WHILE'`
- *POSSIBLE* (support=5) `src/tools/formatter.rb:1280` (expand_if_while_for) -- MISSING `'START'` from `'END' | 'FN' | 'FOR' | 'IF' | 'START' | 'TEST' | 'WHEN' | 'WHILE'`
- *POSSIBLE* (support=5) `src/tools/formatter.rb:1553` (consume_on_segment) -- MISSING `','` from `'(' | ')' | ',' | '[' | ']' | '{' | '}'`
- *POSSIBLE* (support=5) `src/tools/formatter.rb:1701` (expand_method_chains) -- MISSING `','` from `'(' | ')' | ',' | '[' | ']' | '{' | '}'`
- *POSSIBLE* (support=5) `src/tools/formatter.rb:1994` (body_has_top_level_block?) -- MISSING `','` from `'(' | ')' | ',' | '[' | ']' | '{' | '}'`
- *POSSIBLE* (support=5) `src/tools/formatter.rb:2137` (bg_body_has_strategy_arrow?) -- MISSING `','` from `'(' | ')' | ',' | '[' | ']' | '{' | '}'`
- *POSSIBLE* (support=4) `src/mir/control_flow.rb:1550` (promote_outer_field_assigns!) -- MISSING `AST::Identifier` from `AST::GetField | AST::GetIndex | AST::Identifier`
- *POSSIBLE* (support=4) `src/mir/escape_analysis.rb:827` (param_accepts_caller_sync?) -- MISSING `:always_mutable` from `:always_mutable | :atomic | :local | :locked | :versioned | :write_locked`
- ...(+22 more)

## Neglected Path Conditions (2095)
_nested-if/&& guard set minus one atom -- *POSSIBLE* bug (noisy)_

- *POSSIBLE* (support=63) `src/backends/pipeline_host.rb:1110` (lower_limit) -- MISSING `list_node.is_a?(AST::Identifier)` from `bc_target? | list_node.full_type.inf_stream? | list_node.is_a?(AST::Identifier)`
- *POSSIBLE* (support=63) `src/backends/pipeline_host.rb:1110` (lower_limit) -- MISSING `list_node.is_a?(AST::Identifier)` from `bc_target? | list_node.full_type.inf_stream? | list_node.is_a?(AST::Identifier)`
- *POSSIBLE* (support=63) `src/backends/pipeline_host.rb:1111` (lower_limit) -- MISSING `list_node.is_a?(AST::Identifier)` from `bc_target? | list_node.full_type.inf_stream? | list_node.is_a?(AST::Identifier)`
- *POSSIBLE* (support=63) `src/backends/pipeline_host.rb:1111` (lower_limit) -- MISSING `list_node.is_a?(AST::Identifier)` from `bc_target? | list_node.full_type.inf_stream? | list_node.is_a?(AST::Identifier)`
- *POSSIBLE* (support=63) `src/backends/pipeline_host.rb:1112` (lower_limit) -- MISSING `list_node.is_a?(AST::Identifier)` from `bc_target? | list_node.full_type.inf_stream? | list_node.is_a?(AST::Identifier)`
- *POSSIBLE* (support=63) `src/backends/pipeline_host.rb:1113` (lower_limit) -- MISSING `list_node.is_a?(AST::Identifier)` from `bc_target? | list_node.full_type.inf_stream? | list_node.is_a?(AST::Identifier)`
- *POSSIBLE* (support=63) `src/backends/pipeline_host.rb:1114` (lower_limit) -- MISSING `list_node.is_a?(AST::Identifier)` from `bc_target? | list_node.full_type.inf_stream? | list_node.is_a?(AST::Identifier)`
- *POSSIBLE* (support=63) `src/backends/pipeline_host.rb:1115` (lower_limit) -- MISSING `list_node.is_a?(AST::Identifier)` from `bc_target? | list_node.full_type.inf_stream? | list_node.is_a?(AST::Identifier)`
- *POSSIBLE* (support=63) `src/backends/pipeline_host.rb:1116` (lower_limit) -- MISSING `list_node.is_a?(AST::Identifier)` from `bc_target? | list_node.full_type.inf_stream? | list_node.is_a?(AST::Identifier)`
- *POSSIBLE* (support=63) `src/backends/pipeline_host.rb:1117` (lower_limit) -- MISSING `list_node.is_a?(AST::Identifier)` from `bc_target? | list_node.full_type.inf_stream? | list_node.is_a?(AST::Identifier)`
- *POSSIBLE* (support=63) `src/backends/pipeline_host.rb:1118` (lower_limit) -- MISSING `list_node.is_a?(AST::Identifier)` from `bc_target? | list_node.full_type.inf_stream? | list_node.is_a?(AST::Identifier)`
- *POSSIBLE* (support=63) `src/backends/pipeline_host.rb:1118` (lower_limit) -- MISSING `list_node.is_a?(AST::Identifier)` from `bc_target? | list_node.full_type.inf_stream? | list_node.is_a?(AST::Identifier)`
- *POSSIBLE* (support=63) `src/backends/pipeline_host.rb:1119` (lower_limit) -- MISSING `list_node.is_a?(AST::Identifier)` from `bc_target? | list_node.full_type.inf_stream? | list_node.is_a?(AST::Identifier)`
- *POSSIBLE* (support=63) `src/backends/pipeline_host.rb:1119` (lower_limit) -- MISSING `list_node.is_a?(AST::Identifier)` from `bc_target? | list_node.full_type.inf_stream? | list_node.is_a?(AST::Identifier)`
- *POSSIBLE* (support=63) `src/backends/pipeline_host.rb:1120` (lower_limit) -- MISSING `list_node.is_a?(AST::Identifier)` from `bc_target? | list_node.full_type.inf_stream? | list_node.is_a?(AST::Identifier)`
- *POSSIBLE* (support=63) `src/backends/pipeline_host.rb:1121` (lower_limit) -- MISSING `list_node.is_a?(AST::Identifier)` from `bc_target? | list_node.full_type.inf_stream? | list_node.is_a?(AST::Identifier)`
- *POSSIBLE* (support=63) `src/backends/pipeline_host.rb:1121` (lower_limit) -- MISSING `list_node.is_a?(AST::Identifier)` from `bc_target? | list_node.full_type.inf_stream? | list_node.is_a?(AST::Identifier)`
- *POSSIBLE* (support=63) `src/backends/pipeline_host.rb:1121` (lower_limit) -- MISSING `list_node.is_a?(AST::Identifier)` from `bc_target? | list_node.full_type.inf_stream? | list_node.is_a?(AST::Identifier)`
- *POSSIBLE* (support=63) `src/backends/pipeline_host.rb:1122` (lower_limit) -- MISSING `list_node.is_a?(AST::Identifier)` from `bc_target? | list_node.full_type.inf_stream? | list_node.is_a?(AST::Identifier)`
- *POSSIBLE* (support=63) `src/backends/pipeline_host.rb:1123` (lower_limit) -- MISSING `list_node.is_a?(AST::Identifier)` from `bc_target? | list_node.full_type.inf_stream? | list_node.is_a?(AST::Identifier)`
- *POSSIBLE* (support=63) `src/backends/pipeline_host.rb:1123` (lower_limit) -- MISSING `list_node.is_a?(AST::Identifier)` from `bc_target? | list_node.full_type.inf_stream? | list_node.is_a?(AST::Identifier)`
- *POSSIBLE* (support=63) `src/backends/pipeline_host.rb:1124` (lower_limit) -- MISSING `list_node.is_a?(AST::Identifier)` from `bc_target? | list_node.full_type.inf_stream? | list_node.is_a?(AST::Identifier)`
- *POSSIBLE* (support=63) `src/backends/pipeline_host.rb:1125` (lower_limit) -- MISSING `list_node.is_a?(AST::Identifier)` from `bc_target? | list_node.full_type.inf_stream? | list_node.is_a?(AST::Identifier)`
- *POSSIBLE* (support=63) `src/backends/pipeline_host.rb:1126` (lower_limit) -- MISSING `list_node.is_a?(AST::Identifier)` from `bc_target? | list_node.full_type.inf_stream? | list_node.is_a?(AST::Identifier)`
- *POSSIBLE* (support=63) `src/backends/pipeline_host.rb:1126` (lower_limit) -- MISSING `list_node.is_a?(AST::Identifier)` from `bc_target? | list_node.full_type.inf_stream? | list_node.is_a?(AST::Identifier)`
- ...(+2070 more)

## Broken Protocols (1800)
_co-called pair, one site does A without B -- *POSSIBLE* bug (noisy)_

- *POSSIBLE* conf=0.99 support=83 `src/annotator.rb:2245` (visit_ReturnNode) does `returns` without `params`
- *POSSIBLE* conf=0.98 support=82 `src/annotator.rb:2245` (visit_ReturnNode) does `returns` without `extend`
- *POSSIBLE* conf=0.98 support=82 `src/annotator.rb:2245` (visit_ReturnNode) does `returns` without `sig`
- *POSSIBLE* conf=0.98 support=82 `src/mir/mir_lowering.rb:55` (initialize) does `returns` without `extend`
- *POSSIBLE* conf=0.98 support=82 `src/mir/mir_lowering.rb:55` (initialize) does `returns` without `sig`
- *POSSIBLE* conf=0.98 support=48 `src/ast/ast.rb:520` (column) does `column` without `line`
- *POSSIBLE* conf=0.98 support=44 `src/ast/parser.rb:1814` (parse_binary_op) does `parse_expression` without `consume`
- *POSSIBLE* conf=0.97 support=30 `src/annotator.rb:5721` (promote_to_expr_if!) does `else_branch` without `then_branch`
- *POSSIBLE* conf=0.97 support=30 `src/mir/mir_pass.rb:873` (stamp_if_bind_cleanup!) does `then_branch` without `else_branch`
- *POSSIBLE* conf=0.96 support=43 `src/backends/pipeline_host.rb:3033` (default_obs_alloc_zig) does `transpile_type` without `new`
- *POSSIBLE* conf=0.96 support=43 `src/mir/mir_lowering.rb:7582` (bare_zig_type) does `transpile_type` without `new`
- *POSSIBLE* conf=0.96 support=25 `src/mir/escape_analysis.rb:441` (e2_walk_calls) does `walk_body` without `is_a?`
- *POSSIBLE* conf=0.95 support=80 `src/annotator.rb:2245` (visit_ReturnNode) does `returns` without `untyped`
- *POSSIBLE* conf=0.95 support=80 `src/lsp/logger.rb:18` ((top-level)) does `returns` without `untyped`
- *POSSIBLE* conf=0.95 support=80 `src/tools/formatter.rb:92` ((top-level)) does `returns` without `untyped`
- *POSSIBLE* conf=0.95 support=80 `src/tools/method_rewriter.rb:29` ((top-level)) does `returns` without `untyped`
- *POSSIBLE* conf=0.95 support=41 `src/lsp/logger.rb:12` ((top-level)) does `void` without `untyped`
- *POSSIBLE* conf=0.95 support=41 `src/mir/concurrency_checks.rb:31` ((top-level)) does `void` without `require`
- *POSSIBLE* conf=0.95 support=41 `src/mir/fsm_transform/liveness.rb:174` ((top-level)) does `void` without `require`
- *POSSIBLE* conf=0.95 support=41 `src/tools/formatter.rb:97` ((top-level)) does `void` without `untyped`
- *POSSIBLE* conf=0.95 support=36 `src/ast/parser.rb:524` (match_literal!) does `match!` without `consume`
- *POSSIBLE* conf=0.95 support=36 `src/ast/parser.rb:3560` (parse_error_selectors) does `match!` without `consume`
- *POSSIBLE* conf=0.95 support=35 `src/backends/pipeline_host.rb:113` (visit) does `visit_mir` without `new`
- *POSSIBLE* conf=0.95 support=35 `src/backends/pipeline_host.rb:693` (visit_pipeline_expr_mir) does `visit_mir` without `new`
- *POSSIBLE* conf=0.95 support=21 `src/annotator.rb:881` (validate_and_resolve_sync_policy!) does `statements` without `each`
- ...(+1775 more)

## False Simplicity (616)
_looks simple, behaves non-locally: hidden dispatch/mutation/IO/context/metaprogramming/monkeypatch -- *POSSIBLE* (noisy)_

- *POSSIBLE* [hidden_mutation] scatter=364 support=1077 `<<` -- `src/annotator-helpers/auto_inference.rb:157` (record_call_site) (+1071 more)
- *POSSIBLE* [hidden_mutation] scatter=208 support=408 `error!` -- `src/annotator-helpers/capabilities.rb:133` (validate_capability) (+407 more)
- *POSSIBLE* [hidden_mutation] scatter=190 support=401 `[]=` -- `src/annotator-helpers/auto_inference.rb:81` (register_signature_slots) (+399 more)
- *POSSIBLE* [hidden_mutation] scatter=141 support=295 `full_type=` -- `src/annotator-helpers/function_analysis.rb:146` (resolve_call) (+294 more)
- *POSSIBLE* [hidden_mutation] scatter=69 support=125 `op-assign` -- `src/annotator-helpers/auto_inference.rb:202` (record_local) (+124 more)
- *POSSIBLE* [hidden_mutation] scatter=65 support=103 `storage=` -- `src/annotator-helpers/function_analysis.rb:855` (verify_captures!) (+102 more)
- *POSSIBLE* [hidden_mutation] scatter=48 support=50 `fixable!` -- `src/annotator-helpers/capabilities.rb:300` (emit_view_not_observable_finding!) (+49 more)
- *POSSIBLE* [hidden_mutation] scatter=38 support=99 `match!` -- `src/ast/parser.rb:159` ((top-level)) (+98 more)
- *POSSIBLE* [hidden_io] scatter=35 support=41 `File.exist?` -- `src/ast/diagnostic_examples.rb:72` (load!) (+40 more)
- *POSSIBLE* [callback_inversion] scatter=34 support=37 `with_new_scope` -- `src/annotator-helpers/capabilities.rb:573` (visit_post_clauses!) (+36 more)
- *POSSIBLE* [dynamic_dispatch] scatter=32 support=63 `instance_variable_get` -- `src/annotator-helpers/auto_inference.rb:269` (empty_list_lit?) (+62 more)
- *POSSIBLE* [hidden_mutation] scatter=31 support=54 `provenance=` -- `src/annotator-helpers/function_analysis.rb:207` (resolve_call) (+53 more)
- *POSSIBLE* [hidden_io] scatter=31 support=39 `File.join` -- `src/backends/importer.rb:64` (resolve_stdlib_package) (+38 more)
- *POSSIBLE* [dynamic_dispatch] scatter=30 support=41 `send` -- `src/annotator-helpers/function_return.rb:88` (resolve) (+40 more)
- *POSSIBLE* [dynamic_dispatch] scatter=26 support=71 `yield` -- `src/annotator-helpers/auto_inference.rb:572` (walk_for_shape_decls) (+70 more)
- *POSSIBLE* [callback_inversion] scatter=23 support=39 `with_pipeline_context` -- `src/backends/pipeline_host.rb:180` (visit_pipeline_body_mir) (+38 more)
- *POSSIBLE* [hidden_io] scatter=22 support=267 `puts` -- `src/backends/transpiler.rb:328` ((top-level)) (+266 more)
- *POSSIBLE* [metaprogramming] scatter=22 support=52 `instance_variable_set` -- `src/annotator-helpers/auto_inference.rb:469` (stamp_slot!) (+51 more)
- *POSSIBLE* [hidden_mutation] scatter=19 support=29 `ownership=` -- `src/annotator-helpers/function_analysis.rb:202` (resolve_call) (+28 more)
- *POSSIBLE* [hidden_mutation] scatter=19 support=25 `emit_typo_suggestion!` -- `src/annotator-helpers/capabilities.rb:329` (predicate_identifier_allowed!) (+24 more)
- *POSSIBLE* [hidden_mutation] scatter=18 support=23 `stdlib_def=` -- `src/backends/pipeline_host.rb:2689` (lower_range_fold_observable) (+22 more)
- *POSSIBLE* [hidden_io] scatter=18 support=22 `File.readlines` -- `src/ast/diagnostic_examples.rb:82` (scan_file) (+21 more)
- *POSSIBLE* [dynamic_dispatch] scatter=18 support=21 `schema_lookup.call` -- `src/ast/type.rb:951` (resolve_resource_close) (+20 more)
- *POSSIBLE* [hidden_mutation] scatter=17 support=17 `require_array_input!` -- `src/annotator-helpers/pipe_analysis.rb:274` (analyze_select_family_op) (+16 more)
- *POSSIBLE* [context_dependency] scatter=15 support=18 `$stderr` -- `src/annotator-helpers/capabilities.rb:1396` (finalize_capability_audit!) (+17 more)
- ...(+591 more)

## Fat Unions (9)
_case dispatch over class consts whose arms read mostly variant-invariant members -- product-vs-sum decomposition candidate (extraction -> nil-kill) -- *POSSIBLE*_

- *POSSIBLE* [DEGENERATE: no variance] union `AST::Assignment | AST::BindExpr | AST::VarDecl` -- **3 common** vs 0 variant member(s), scatter=4 -- `src/mir/escape_analysis.rb:672` (tag_transitive_provenance!)
  - common: `is_a?, name, value` -> hoist to a struct, keep a SMALL union for `` (-> nil-kill)
- *POSSIBLE* [DEGENERATE: no variance] union `AST::Assignment | AST::BindExpr | AST::FuncCall | AST::MethodCall | AST::VarDecl` -- **7 common** vs 0 variant member(s), scatter=2 -- `src/mir/mir_pass.rb:368` (recurse_branches!)
  - common: `body, branches, cases, default_case, do_branch, else_branch, then_branch` -> hoist to a struct, keep a SMALL union for `` (-> nil-kill)
- *POSSIBLE* [DEGENERATE: no variance] union `AST::AllOp | AST::AnyOp | AST::AverageOp | AST::CountOp | AST::FindOp | AST::MaxOp | AST::MinOp | AST::SumOp` -- **2 common** vs 0 variant member(s), scatter=3 -- `src/backends/pipeline_host.rb:793` (build_soa_scalar_fold_block)
  - common: `class, expression` -> hoist to a struct, keep a SMALL union for `` (-> nil-kill)
- *POSSIBLE* [DEGENERATE: no variance] union `AST::IndexOp | AST::OrderByOp | AST::SelectOp | AST::WhereOp` -- **2 common** vs 0 variant member(s), scatter=1 -- `src/annotator-helpers/pipe_analysis.rb:301` (analyze_select_family_op)
  - common: `expression, is_a?` -> hoist to a struct, keep a SMALL union for `` (-> nil-kill)
- *POSSIBLE* [DEGENERATE: no variance] union `AST::GetField | AST::GetIndex | AST::Identifier | String` -- **2 common** vs 0 variant member(s), scatter=1 -- `src/annotator.rb:3167` (visit_Assignment)
  - common: `is_a?, target` -> hoist to a struct, keep a SMALL union for `` (-> nil-kill)
- *POSSIBLE* union `Array | FalseClass | Hash | Numeric | String | Symbol | TrueClass | Type` -- **6 common** vs 4 variant member(s), scatter=2 -- `src/annotator-helpers/auto_inference.rb:110` (walk)
  - common: `each_pair, nil?, params, respond_to?, return_type, type` -> hoist to a struct, keep a SMALL union for `any?, auto?, each, each_value` (-> nil-kill)
- *POSSIBLE* union `AST::EnumDef | AST::StructDef | AST::UnionDef` -- **4 common** vs 1 variant member(s), scatter=3 -- `src/backends/compiler_frontend.rb:78` (compile)
  - common: `is_a?, name, variants, visibility` -> hoist to a struct, keep a SMALL union for `field_decls` (-> nil-kill)
- *POSSIBLE* union `AST::ForEach | AST::ForRange | AST::IfStatement | AST::MatchStatement | AST::WhileLoop` -- **5 common** vs 2 variant member(s), scatter=1 -- `src/mir/control_flow.rb:662` (transfer_stmt)
  - common: `is_a?, mode, name, value, var_name` -> hoist to a struct, keep a SMALL union for `collection, expr` (-> nil-kill)
- *POSSIBLE* union `AST::AverageOp | AST::CountOp | AST::EachOp | AST::MaxOp | AST::MinOp | AST::SelectOp | AST::SumOp | AST::WhereOp` -- **2 common** vs 1 variant member(s), scatter=2 -- `src/annotator-helpers/pipe_analysis.rb:1521` (analyze_concurrent_op)
  - common: `expression, is_a?` -> hoist to a struct, keep a SMALL union for `body` (-> nil-kill)

## Run Summary
- Files analyzed: 98
- Detectors: 13 (all shipped, self-tested)
- Convergence: 1162 unit(s) flagged by >=2 independent detectors
- Root-cause clusters: 323 (one fix collapses each)
- Total candidates: 12194
- Method: stdlib AST only, intra-procedural, zero deps, no CFG / no points-to (see docs/agents/design.md)
