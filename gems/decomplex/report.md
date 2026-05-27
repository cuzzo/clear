# Decomplex Report

> Decision-level duplication and neglected-condition analysis.
> Every entry is a ranked **candidate** (Engler's discipline),
> never a verdict -- *POSSIBLE* findings, triaged by a human.
> Sections are ordered by SIGNAL TIER (1 = lowest false
> positive), not by volume. Items within a section are
> frequency-ranked. Triage tier 1, top-of-list, first.

## Table of Contents
- [Project Prioritization](#project-prioritization)
- [Cross-Detector Convergence (1304)](#cross-detector-convergence-1304)
- [Root-Cause Clusters (334)](#root-cause-clusters-334)
- [Decision Pressure (290)](#decision-pressure-290)
- [Missing Abstractions (192)](#missing-abstractions-192)
- [Reification Misses (37)](#reification-misses-37)
- [Semantic Predicate Aliases (3)](#semantic-predicate-aliases-3)
- [Exact Predicate Aliases (6)](#exact-predicate-aliases-6)
- [Type-3 Clones (missed rename) (16)](#type3-clones-missed-rename-16)
- [Neglected Updates (1772)](#neglected-updates-1772)
- [Derived-State Staleness (151)](#derivedstate-staleness-151)
- [Neglected Conditions (11)](#neglected-conditions-11)
- [Neglected Path Conditions (1969)](#neglected-path-conditions-1969)
- [Broken Protocols (1513)](#broken-protocols-1513)
- [False Simplicity (720)](#false-simplicity-720)
- [Fat Unions (8)](#fat-unions-8)
- [Run Summary](#run-summary)

## Project Prioritization
_Ordered by signal tier (1 = highest signal / lowest FP), then by volume._

- **[tier 1]** [Decision Pressure (290)](#decision-pressure-290): ELIMINABLE guard-pressure per loose contract (nil/is_a?/respond_to?/safe-nav/rescue-nil) -> tighten the contract once / nil-kill: DELETE. essential dispatch + pure c-uses are split out, NEVER summed (Rapps-Weyuker p-use; McCabe)
- **[tier 1]** [Missing Abstractions (192)](#missing-abstractions-192): guard tuple recomputed across >=2 decision units
- **[tier 1]** [Reification Misses (37)](#reification-misses-37): an existing predicate reinvented inline -- invariant #16
- **[tier 1]** [Exact Predicate Aliases (6)](#exact-predicate-aliases-6): identical one-line predicate body under >=2 names
- **[tier 1]** [Semantic Predicate Aliases (3)](#semantic-predicate-aliases-3): one decision, multiple names (receiver/polarity folded)
- **[tier 2]** [Neglected Updates (1772)](#neglected-updates-1772): co-written state, one write missing -- *POSSIBLE* redundant-state desync
- **[tier 2]** [Derived-State Staleness (151)](#derivedstate-staleness-151): b = f(a); a later reassigned, b not recomputed -- *POSSIBLE* bug
- **[tier 2]** [Type-3 Clones (missed rename) (16)](#type3-clones-missed-rename-16): pasted block, one identifier inconsistently renamed -- *POSSIBLE* bug
- **[tier 2]** [Neglected Conditions (11)](#neglected-conditions-11): dispatch/conjunction minus one element -- *POSSIBLE* bug
- **[tier 3]** [Neglected Path Conditions (1969)](#neglected-path-conditions-1969): nested-if/&& guard set minus one atom -- *POSSIBLE* bug (noisy)
- **[tier 3]** [Broken Protocols (1513)](#broken-protocols-1513): co-called pair, one site does A without B -- *POSSIBLE* bug (noisy)
- **[tier 3]** [False Simplicity (720)](#false-simplicity-720): looks simple, behaves non-locally: hidden dispatch/mutation/IO/context/metaprogramming/monkeypatch -- *POSSIBLE* (noisy)
- **[tier 3]** [Fat Unions (8)](#fat-unions-8): case dispatch over class consts whose arms read mostly variant-invariant members -- product-vs-sum decomposition candidate (extraction -> nil-kill) -- *POSSIBLE*

## Cross-Detector Convergence (1304)
_(file, method) units flagged by >=2 INDEPENDENT detectors -- the strongest triage signal: agreement outranks any single detector's volume. Tier-weighted (1=3, 2=2, 3=1). **Start here.**_

- `src/annotator/helpers/function_analysis.rb:159` (resolve_call) -- **7 detectors** [score 13, 155 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/mir/lowering/variables.rb:385` (build_var_decl_nodes) -- **7 detectors** [score 13, 84 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions, Neglected Updates, Reification Misses
- `src/annotator/annotator.rb:5470` (handle_assign_move) -- **7 detectors** [score 13, 54 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/mir/lowering/control_flow.rb:209` (stamp_loop_frame_allocs_iteration!) -- **6 detectors** [score 13, 25 findings]: Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Neglected Updates, Reification Misses
- `src/mir/hoist.rb:551` (hoist_alloc) -- **6 detectors** [score 13, 22 findings]: Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Neglected Updates, Reification Misses
- `src/ast/parser.rb:2839` (parse_type_annotation) -- **6 detectors** [score 12, 78 findings]: Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions, Neglected Updates, Reification Misses
- `src/annotator/annotator.rb:1476` (visit_MatchStatement) -- **6 detectors** [score 11, 194 findings]: Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/mir/lowering/functions.rb:261` (lower_function_def) -- **6 detectors** [score 11, 115 findings]: Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/annotator/annotator.rb:4761` (visit_WithBlock) -- **6 detectors** [score 11, 88 findings]: Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/annotator/helpers/pipe_analysis.rb:1535` (analyze_concurrent_op) -- **6 detectors** [score 11, 71 findings]: Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/tools/formatter.rb:1358` (expand_if_while_for) -- **6 detectors** [score 11, 49 findings]: Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Conditions, Neglected Path Conditions, Type-3 Clones (missed rename)
- `src/annotator/helpers/generic_analysis.rb:229` (validate_type_annotation!) -- **6 detectors** [score 11, 47 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions
- `src/tools/doctor.rb:164` (section_heap) -- **6 detectors** [score 11, 43 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions
- `src/annotator/annotator.rb:1966` (visit_WhileBindLoop) -- **6 detectors** [score 11, 38 findings]: Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/annotator/helpers/pipe_analysis.rb:805` (analyze_pipe_to_named_function) -- **6 detectors** [score 11, 12 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions
- `src/annotator/annotator.rb:3561` (visit_StructLit) -- **6 detectors** [score 10, 102 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions, Neglected Updates
- `src/backends/pipeline_host.rb:287` (substitute_placeholders) -- **6 detectors** [score 10, 78 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions, Neglected Updates
- `src/ast/type.rb:2197` (compute_zig_type) -- **6 detectors** [score 10, 68 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions, Neglected Updates
- `src/mir/lowering/expressions.rb:401` (lower_smooth) -- **6 detectors** [score 10, 60 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions, Neglected Updates
- `src/annotator/annotator.rb:3375` (visit_GetField) -- **6 detectors** [score 10, 49 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions, Neglected Updates
- `src/mir/lowering/literals.rb:164` (lower_hash_lit) -- **6 detectors** [score 10, 35 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions, Neglected Updates
- `src/mir/fsm_lowering.rb:224` (fsm_owned_transfer_identifier?) -- **5 detectors** [score 12, 8 findings]: Decision Pressure, False Simplicity, Missing Abstractions, Neglected Updates, Reification Misses
- `src/ast/ast.rb:818` (finalize_storage!) -- **5 detectors** [score 11, 55 findings]: Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Updates
- `src/mir/cleanup_classifier.rb:97` (stamp_binding_default_scope!) -- **5 detectors** [score 11, 10 findings]: Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Reification Misses
- `src/annotator/annotator.rb:2860` (visit_BindExpr) -- **5 detectors** [score 10, 54 findings]: Decision Pressure, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- ...(+1279 more)

### By file
- `src/annotator/annotator.rb` -- 12 detectors across 142 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, Exact Predicate Aliases, False Simplicity, Fat Unions, Missing Abstractions, Neglected Conditions, Neglected Path Conditions, Neglected Updates, Reification Misses, Type-3 Clones (missed rename)
- `src/ast/ast.rb` -- 10 detectors across 19 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, Exact Predicate Aliases, False Simplicity, Fat Unions, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Semantic Predicate Aliases
- `src/backends/pipeline_host.rb` -- 9 detectors across 63 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Fat Unions, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Reification Misses
- `src/mir/mir_lowering.rb` -- 9 detectors across 60 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Fat Unions, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Reification Misses
- `src/mir/hoist.rb` -- 9 detectors across 39 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Reification Misses, Type-3 Clones (missed rename)
- `src/annotator/helpers/pipe_analysis.rb` -- 8 detectors across 53 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Fat Unions, Missing Abstractions, Neglected Path Conditions, Neglected Updates
- `src/tools/formatter.rb` -- 8 detectors across 59 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Conditions, Neglected Path Conditions, Type-3 Clones (missed rename)
- `src/mir/lowering/control_flow.rb` -- 8 detectors across 34 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Reification Misses
- `src/ast/parser.rb` -- 8 detectors across 56 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Reification Misses
- `src/mir/lowering/functions.rb` -- 8 detectors across 31 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Reification Misses
- `src/mir/control_flow.rb` -- 8 detectors across 34 method(s): Broken Protocols, Decision Pressure, False Simplicity, Fat Unions, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Reification Misses
- `src/mir/lowering/variables.rb` -- 8 detectors across 25 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Reification Misses
- `src/mir/mir_pass.rb` -- 8 detectors across 22 method(s): Broken Protocols, Decision Pressure, False Simplicity, Fat Unions, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Reification Misses
- `src/annotator/helpers/auto_inference.rb` -- 8 detectors across 18 method(s): Broken Protocols, Decision Pressure, Exact Predicate Aliases, False Simplicity, Fat Unions, Missing Abstractions, Neglected Updates, Semantic Predicate Aliases
- `src/mir/escape_analysis.rb` -- 7 detectors across 43 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates

## Root-Cause Clusters (334)
_Findings across >=2 INDEPENDENT detectors that name the SAME entity -- 'N findings are really one invariant'. Convergence says where to look; this says **what one fix collapses the cluster**. Ranked candidate, not a verdict._

- **[name]** `expr` -- **6 detectors** [score 12] across 34 unit(s), 75 findings: Broken Protocols, Decision Pressure, Exact Predicate Aliases, False Simplicity, Neglected Path Conditions, Semantic Predicate Aliases
  - FIX: pair the protocol (RAII / ensure); the unpaired site is the deviant
  - `src/annotator/annotator.rb:1342` (visit_IfBind) ; `src/annotator/annotator.rb:1476` (visit_MatchStatement) ; `src/annotator/annotator.rb:5371` (visit_NextExpr) ; `src/annotator/annotator.rb:5389` (visit_NextExpr)
- **[name]** `sync` -- **5 detectors** [score 10] across 56 unit(s), 126 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Updates, Reification Misses
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator/annotator.rb:2240` (same_return_capabilities?) ; `src/annotator/annotator.rb:5024` (sync_constrained_cap?) ; `src/annotator/annotator.rb:6205` (bg_capture_independent?) ; `src/annotator/helpers/function_analysis.rb:217` (resolve_call)
- **[name]** `layout` -- **5 detectors** [score 10] across 44 unit(s), 83 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Updates, Reification Misses
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator/helpers/function_analysis.rb:222` (resolve_call) ; `src/annotator/helpers/generic_analysis.rb:448` (generic_type_has_capabilities?) ; `src/ast/type.rb:2256` (compute_zig_type) ; `src/ast/parser.rb:2936` (parse_type_annotation)
- **[name]** `line` -- **5 detectors** [score 9] across 10 unit(s), 19 findings: Broken Protocols, Decision Pressure, Derived-State Staleness, Neglected Path Conditions, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/tools/doctor.rb:607` (task_site_metadata) ; `src/tools/doctor.rb:620` (source_line) ; `src/ast/lexer.rb:40` (initialize) ; `src/ast/lexer.rb:311` (advance_pos)
- **[name]** `value` -- **5 detectors** [score 8] across 87 unit(s), 28 findings: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator/annotator.rb:2084` (visit_ReturnNode) ; `src/annotator/annotator.rb:2125` (visit_ReturnNode) ; `src/annotator/annotator.rb:2127` (visit_ReturnNode) ; `src/annotator/annotator.rb:2129` (visit_ReturnNode)
- **[name]** `symbol` -- **5 detectors** [score 8] across 73 unit(s), 6 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Conditions, Neglected Path Conditions
  - FIX: pair the protocol (RAII / ensure); the unpaired site is the deviant
  - `src/annotator/annotator.rb:305` (flush_deferred_with_validations!) ; `src/annotator/annotator.rb:309` (flush_deferred_with_validations!) ; `src/annotator/annotator.rb:1364` (visit_IfBind) ; `src/annotator/annotator.rb:2125` (visit_ReturnNode)
- **[name]** `right` -- **5 detectors** [score 8] across 48 unit(s), 40 findings: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Path Conditions
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator/annotator.rb:3994` (visit_OrRescue) ; `src/annotator/annotator.rb:4004` (visit_OrRescue) ; `src/annotator/annotator.rb:4016` (visit_OrRescue) ; `src/annotator/annotator.rb:4027` (visit_OrRescue)
- **[name]** `state` -- **5 detectors** [score 8] across 10 unit(s), 19 findings: Broken Protocols, False Simplicity, Neglected Path Conditions, Neglected Updates, Reification Misses
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator/annotator.rb:1267` (analyze_control_flow_branches) ; `src/annotator/annotator.rb:6663` (og_set_live) ; `src/mir/ownership_graph.rb:164` (drop) ; `src/mir/ownership_graph.rb:330` (record_move_site)
- **[name]** `target` -- **4 detectors** [score 8] across 71 unit(s), 78 findings: Decision Pressure, Derived-State Staleness, Neglected Path Conditions, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator/annotator.rb:2127` (visit_ReturnNode) ; `src/annotator/annotator.rb:2129` (visit_ReturnNode) ; `src/annotator/annotator.rb:3088` (chain_root_name) ; `src/annotator/annotator.rb:3091` (chain_root_name)
- **[name]** `alloc` -- **4 detectors** [score 8] across 52 unit(s), 42 findings: Broken Protocols, Decision Pressure, False Simplicity, Reification Misses
  - FIX: pair the protocol (RAII / ensure); the unpaired site is the deviant
  - `src/mir/lowering/variables.rb:296` (owned_binding_source_alloc) ; `src/mir/mir.rb:1676` (ownership_effect) ; `src/mir/mir.rb:1692` (ownership_effect) ; `src/mir/mir.rb:1708` (ownership_effect)
- **[name]** `union` -- **4 detectors** [score 8] across 25 unit(s), 31 findings: Broken Protocols, Exact Predicate Aliases, Neglected Path Conditions, Semantic Predicate Aliases
  - FIX: pair the protocol (RAII / ensure); the unpaired site is the deviant
  - `src/ast/schemas.rb:34` (enum?) ; `src/ast/schemas.rb:67` (resource?) ; `src/ast/schemas.rb:123` (union?) ; `src/ast/schemas.rb:169` (struct?)
- **[name]** `struct` -- **4 detectors** [score 8] across 21 unit(s), 25 findings: Broken Protocols, Exact Predicate Aliases, Neglected Path Conditions, Semantic Predicate Aliases
  - FIX: pair the protocol (RAII / ensure); the unpaired site is the deviant
  - `src/ast/schemas.rb:34` (enum?) ; `src/ast/schemas.rb:67` (resource?) ; `src/ast/schemas.rb:123` (union?) ; `src/ast/schemas.rb:169` (struct?)
- **[name]** `provenance` -- **4 detectors** [score 7] across 97 unit(s), 178 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator/helpers/function_analysis.rb:212` (resolve_call) ; `src/annotator/annotator.rb:1343` (visit_IfBind) ; `src/annotator/annotator.rb:1929` (visit_WhileBindLoop) ; `src/annotator/annotator.rb:3762` (visit_ListLit)
- **[name]** `capture_analysis` -- **4 detectors** [score 7] across 77 unit(s), 64 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/mir/control_flow.rb:695` (resource_captures) ; `src/mir/control_flow.rb:967` (collect_bg_body_gives) ; `src/mir/control_flow.rb:1211` (check_stmt_reads) ; `src/mir/control_flow.rb:1212` (check_stmt_reads)
- **[name]** `left` -- **4 detectors** [score 7] across 45 unit(s), 38 findings: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator/annotator.rb:3985` (visit_OrRescue) ; `src/annotator/helpers/pipe_analysis.rb:66` (stamp_observable_terminal!) ; `src/annotator/helpers/pipe_analysis.rb:72` (stamp_observable_terminal!) ; `src/annotator/helpers/pipe_analysis.rb:257` (analyze_collect_op)
- **[name]** `collection` -- **4 detectors** [score 7] across 44 unit(s), 78 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator/helpers/function_analysis.rb:227` (resolve_call) ; `src/mir/lowering/control_flow.rb:435` (for_each_loop_stmt) ; `src/mir/lowering/control_flow.rb:436` (for_each_loop_stmt) ; `src/annotator/annotator.rb:2778` (finalize_decl_node!)
- **[name]** `ownership` -- **4 detectors** [score 7] across 41 unit(s), 136 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator/helpers/function_analysis.rb:208` (resolve_call) ; `src/ast/type.rb:2248` (compute_zig_type) ; `src/ast/type.rb:2282` (compute_zig_type) ; `src/annotator/annotator.rb:1343` (visit_IfBind)
- **[name]** `emit` -- **4 detectors** [score 7] across 38 unit(s), 15 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator/annotator.rb:2351` (visit_StaticCall) ; `src/annotator/annotator.rb:2355` (visit_StaticCall) ; `src/annotator/annotator.rb:2356` (visit_StaticCall) ; `src/annotator/annotator.rb:2358` (visit_StaticCall)
- **[name]** `resolved` -- **4 detectors** [score 7] across 35 unit(s), 46 findings: Broken Protocols, Decision Pressure, Derived-State Staleness, Neglected Path Conditions
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator/helpers/pipe_analysis.rb:805` (analyze_pipe_to_named_function) ; `src/annotator/helpers/pipe_analysis.rb:1386` (analyze_shard_op) ; `src/mir/lowering/functions.rb:1029` (stdlib_coerce_type) ; `src/ast/type.rb:1518` (copyable?)
- **[name]** `elem_ownership` -- **4 detectors** [score 7] across 33 unit(s), 54 findings: Broken Protocols, Decision Pressure, False Simplicity, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator/helpers/generic_analysis.rb:449` (generic_type_has_capabilities?) ; `src/annotator/annotator.rb:1343` (visit_IfBind) ; `src/annotator/annotator.rb:1581` (visit_MatchStatement) ; `src/annotator/annotator.rb:1929` (visit_WhileBindLoop)
- ...(+314 more)

## Decision Pressure (290)
_ELIMINABLE guard-pressure per loose contract (nil/is_a?/respond_to?/safe-nav/rescue-nil) -> tighten the contract once / nil-kill: DELETE. essential dispatch + pure c-uses are split out, NEVER summed (Rapps-Weyuker p-use; McCabe)_

- `.value` -- ELIMINABLE guard-pressure **129** across 62 method(s) -> tighten contract / nil-kill: DELETE  (+11 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/annotator.rb:2084` (visit_ReturnNode) ; `src/annotator/annotator.rb:2125` (visit_ReturnNode) ; `src/annotator/annotator.rb:2127` (visit_ReturnNode) ; `src/annotator/annotator.rb:2129` (visit_ReturnNode)
- `.symbol` -- ELIMINABLE guard-pressure **90** across 64 method(s) -> tighten contract / nil-kill: DELETE  (+16 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/annotator.rb:305` (flush_deferred_with_validations!) ; `src/annotator/annotator.rb:309` (flush_deferred_with_validations!) ; `src/annotator/annotator.rb:1364` (visit_IfBind) ; `src/annotator/annotator.rb:2125` (visit_ReturnNode)
- `.emit` -- ELIMINABLE guard-pressure **71** across 22 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/annotator.rb:2351` (visit_StaticCall) ; `src/annotator/annotator.rb:2355` (visit_StaticCall) ; `src/annotator/annotator.rb:2356` (visit_StaticCall) ; `src/annotator/annotator.rb:2358` (visit_StaticCall)
- `.full_type!` -- ELIMINABLE guard-pressure **61** across 18 method(s) -> tighten contract / nil-kill: DELETE  (+53 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/backends/pipeline_host.rb:467` (lower_pipeline) ; `src/backends/pipeline_host.rb:467` (lower_pipeline) ; `src/backends/pipeline_host.rb:467` (lower_pipeline) ; `src/backends/pipeline_host.rb:467` (lower_pipeline)
- `.target` -- ELIMINABLE guard-pressure **55** across 35 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/annotator.rb:2127` (visit_ReturnNode) ; `src/annotator/annotator.rb:2129` (visit_ReturnNode) ; `src/annotator/annotator.rb:3088` (chain_root_name) ; `src/annotator/annotator.rb:3088` (chain_root_name)
- `.name` -- ELIMINABLE guard-pressure **54** across 38 method(s) -> tighten contract / nil-kill: DELETE  (+3 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/annotator.rb:2392` (visit_FuncCall) ; `src/annotator/annotator.rb:2396` (visit_FuncCall) ; `src/annotator/annotator.rb:2404` (visit_FuncCall) ; `src/annotator/annotator.rb:2488` (visit_MethodCall)
- `.left` -- ELIMINABLE guard-pressure **41** across 18 method(s) -> tighten contract / nil-kill: DELETE  (+3 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/annotator.rb:3985` (visit_OrRescue) ; `src/annotator/helpers/pipe_analysis.rb:66` (stamp_observable_terminal!) ; `src/annotator/helpers/pipe_analysis.rb:72` (stamp_observable_terminal!) ; `src/annotator/helpers/pipe_analysis.rb:257` (analyze_collect_op)
- `.right` -- ELIMINABLE guard-pressure **34** across 16 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/annotator.rb:3994` (visit_OrRescue) ; `src/annotator/annotator.rb:4004` (visit_OrRescue) ; `src/annotator/annotator.rb:4016` (visit_OrRescue) ; `src/annotator/annotator.rb:4027` (visit_OrRescue)
- `.current_fn_ctx` -- ELIMINABLE guard-pressure **31** across 22 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/annotator.rb:1990` (visit_BreakNode) ; `src/annotator/annotator.rb:1998` (visit_ContinueNode) ; `src/annotator/annotator.rb:2400` (visit_FuncCall) ; `src/annotator/annotator.rb:2416` (visit_FuncCall)
- `.type` -- ELIMINABLE guard-pressure **30** across 24 method(s) -> tighten contract / nil-kill: DELETE  (+29 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/annotator.rb:288` (program_has_auto?) ; `src/annotator/annotator.rb:291` (program_has_auto?) ; `src/annotator/annotator.rb:630` (pre_register_function) ; `src/annotator/annotator.rb:704` (visit_FunctionDef)
- `[name]` -- ELIMINABLE guard-pressure **28** across 26 method(s) -> tighten contract / nil-kill: DELETE  (+8 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/annotator.rb:192` (annotate!) ; `src/annotator/annotator.rb:204` (annotate!) ; `src/annotator/annotator.rb:1890` (visit_WhileLoop) ; `src/annotator/annotator.rb:1966` (visit_WhileBindLoop)
- `.last` -- ELIMINABLE guard-pressure **25** across 6 method(s) -> tighten contract / nil-kill: DELETE  (+2 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/annotator.rb:5635` (expr_result_type) ; `src/annotator/annotator.rb:5638` (expr_result_type) ; `src/annotator/annotator.rb:5642` (expr_result_type) ; `src/annotator/annotator.rb:5642` (expr_result_type)
- `.body` -- ELIMINABLE guard-pressure **24** across 18 method(s) -> tighten contract / nil-kill: DELETE  (+4 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/annotator.rb:6089` (init_value_contents_heap?) ; `src/annotator/annotator.rb:6091` (init_value_contents_heap?) ; `src/annotator/helpers/capabilities.rb:1226` (_unified_capture_walk) ; `src/backends/pipeline_rewriter.rb:70` (rewrite_children!)
- `.expr` -- ELIMINABLE guard-pressure **24** across 14 method(s) -> tighten contract / nil-kill: DELETE  (+2 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/annotator.rb:1342` (visit_IfBind) ; `src/annotator/annotator.rb:1476` (visit_MatchStatement) ; `src/annotator/annotator.rb:5371` (visit_NextExpr) ; `src/annotator/annotator.rb:5389` (visit_NextExpr)
- `.element_type` -- ELIMINABLE guard-pressure **23** across 19 method(s) -> tighten contract / nil-kill: DELETE  (+5 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/annotator.rb:4355` (infer_element_type) ; `src/annotator/annotator.rb:4363` (infer_optional_element_type) ; `src/annotator/helpers/function_return.rb:83` (resolve) ; `src/annotator/helpers/generic_analysis.rb:184` (validate_type_annotation!)
- `.token` -- ELIMINABLE guard-pressure **21** across 18 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/helpers/capabilities.rb:1351` (record_capability_binding) ; `src/annotator/helpers/capabilities.rb:1352` (record_capability_binding) ; `src/mir/concurrency_checks.rb:80` (check_hold_across_yield!) ; `src/mir/concurrency_checks.rb:178` (check_reentrant!)
- `.arms` -- ELIMINABLE guard-pressure **20** across 11 method(s) -> tighten contract / nil-kill: DELETE  (+6 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/annotator.rb:4588` (visit_WithBlock) ; `src/annotator/annotator.rb:4747` (visit_WithBlock) ; `src/annotator/helpers/capabilities.rb:1229` (_unified_capture_walk) ; `src/annotator/helpers/effects.rb:1355` (scan_for_raises)
- `[:var_node]` -- ELIMINABLE guard-pressure **18** across 12 method(s) -> tighten contract / nil-kill: DELETE  (+2 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/annotator.rb:4562` (visit_WithBlock) ; `src/annotator/annotator.rb:4566` (visit_WithBlock) ; `src/annotator/annotator.rb:4612` (visit_WithBlock) ; `src/annotator/annotator.rb:4759` (visit_WithBlock)
- `.type_params` -- ELIMINABLE guard-pressure **18** across 11 method(s) -> tighten contract / nil-kill: DELETE  (+2 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/annotator.rb:1137` (visit_StructDef) ; `src/annotator/annotator.rb:1153` (visit_StructDef) ; `src/annotator/annotator.rb:1173` (visit_UnionDef) ; `src/annotator/annotator.rb:1176` (visit_UnionDef)
- `.return_type` -- ELIMINABLE guard-pressure **17** across 10 method(s) -> tighten contract / nil-kill: DELETE  (+13 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/annotator.rb:289` (program_has_auto?) ; `src/annotator/annotator.rb:675` (visit_FunctionDef) ; `src/annotator/annotator.rb:2089` (visit_ReturnNode) ; `src/annotator/annotator.rb:2090` (visit_ReturnNode)
- `.capture_analysis` -- ELIMINABLE guard-pressure **16** across 11 method(s) -> tighten contract / nil-kill: DELETE
  - `src/mir/control_flow.rb:695` (resource_captures) ; `src/mir/control_flow.rb:967` (collect_bg_body_gives) ; `src/mir/control_flow.rb:1211` (check_stmt_reads) ; `src/mir/control_flow.rb:1212` (check_stmt_reads)
- `.stdlib_def` -- ELIMINABLE guard-pressure **15** across 8 method(s) -> tighten contract / nil-kill: DELETE  (+2 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/mir/lowering/variables.rb:569` (owned_return_transfer_binding?) ; `src/mir/lowering/variables.rb:570` (owned_return_transfer_binding?) ; `src/mir/mir.rb:2827` (ownership_effect) ; `src/mir/mir.rb:2828` (ownership_effect)
- `.alloc` -- ELIMINABLE guard-pressure **15** across 6 method(s) -> tighten contract / nil-kill: DELETE
  - `src/mir/lowering/variables.rb:296` (owned_binding_source_alloc) ; `src/mir/mir.rb:1676` (ownership_effect) ; `src/mir/mir.rb:1692` (ownership_effect) ; `src/mir/mir.rb:1708` (ownership_effect)
- `.payload_type` -- ELIMINABLE guard-pressure **15** across 3 method(s) -> tighten contract / nil-kill: DELETE  (+2 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/annotator.rb:2091` (visit_ReturnNode) ; `src/annotator/helpers/function_analysis.rb:205` (resolve_call) ; `src/annotator/helpers/function_analysis.rb:208` (resolve_call) ; `src/annotator/helpers/function_analysis.rb:212` (resolve_call)
- `@union_schemas` -- ELIMINABLE guard-pressure **14** across 12 method(s) -> tighten contract / nil-kill: DELETE
  - `src/mir/hoist.rb:925` (copy_container_borrow_if_needed) ; `src/mir/lowering/control_flow.rb:666` (match_lowering_facts) ; `src/mir/lowering/control_flow.rb:707` (union_match_default_body) ; `src/mir/lowering/control_flow.rb:1103` (call_union_return_needs_hoist?)
- ...(+265 more)

## Missing Abstractions (192)
_guard tuple recomputed across >=2 decision units_

- **[case_dispatch]** support=10 scatter=4 rank=40
  - tuple: `AST::GetField | AST::MethodCall`
  - `src/annotator/annotator.rb:1536` (visit_MatchStatement) ; `src/annotator/annotator.rb:1557` (visit_MatchStatement) ; `src/annotator/annotator.rb:1614` (visit_MatchStatement) ; `src/annotator/annotator.rb:1629` (visit_MatchStatement) ; `src/annotator/annotator.rb:1706` (visit_MatchStatement) ; `src/annotator/annotator.rb:1750` (visit_MatchStatement)
- **[conjunction]** support=5 scatter=5 rank=25
  - tuple: `node.is_a?(AST::BinaryOp) | node.op == :SMOOTH`
  - `src/annotator/annotator.rb:1099` (collect_pipe_input_types) ; `src/backends/pipeline_host.rb:2356` (unwrap_range_chain) ; `src/backends/pipeline_host.rb:2382` (unwrap_binding_unnest_chain) ; `src/backends/pipeline_rewriter.rb:35` (rewrite!) ; `src/backends/pipeline_rewriter.rb:262` (binding_source?)
- **[case_dispatch]** support=5 scatter=5 rank=25
  - tuple: `'END' | 'FN' | 'FOR' | 'IF' | 'START' | 'TEST' | 'WHEN' | 'WHILE'`
  - `src/tools/formatter.rb:535` (find_match_block_end) ; `src/tools/formatter.rb:599` (scan_match_arms) ; `src/tools/formatter.rb:639` (build_match_arm) ; `src/tools/formatter.rb:751` (emit_match_body) ; `src/tools/formatter.rb:1236` (matching_end)
- **[conjunction]** support=4 scatter=4 rank=16
  - tuple: `%w[true TRUE].include?(node.right.options["parallel"].name) | node.right.options["parallel"].is_a?(AST::Identifier)`
  - `src/annotator/helpers/pipe_analysis.rb:1646` (analyze_concurrent_bounded_select_family_op) ; `src/annotator/helpers/pipe_analysis.rb:1680` (analyze_concurrent_bounded_each_op) ; `src/annotator/helpers/pipe_analysis.rb:1710` (analyze_concurrent_stream_select_family_op) ; `src/annotator/helpers/pipe_analysis.rb:1747` (analyze_concurrent_stream_each_op)
- **[case_dispatch]** support=4 scatter=4 rank=16
  - tuple: `AST::AllOp | AST::AnyOp | AST::AverageOp | AST::CountOp | AST::FindOp | AST::MaxOp | AST::MinOp | AST::SumOp`
  - `src/ast/ast.rb:1746` (pipeline_range_fold?) ; `src/backends/pipeline_host.rb:939` (build_soa_scalar_fold_block) ; `src/backends/pipeline_host.rb:2533` (lower_binding_fold) ; `src/backends/pipeline_host.rb:3327` (lower_range_fold)
- **[conjunction]** support=4 scatter=4 rank=16
  - tuple: `node.is_a?(AST::ReturnNode) | node.value`
  - `src/mir/escape_analysis.rb:825` (mark_heap_return_facts!) ; `src/mir/escape_analysis.rb:960` (function_has_owned_return_value?) ; `src/mir/mir_pass.rb:312` (return_path_needs_allocator?) ; `src/mir/mir_pass.rb:807` (mark_returned_cleanup_bindings!)
- **[conjunction]** support=4 scatter=4 rank=16
  - tuple: `j < toks.length | toks[j].type == :NL`
  - `src/tools/formatter.rb:887` (skip_nls) ; `src/tools/formatter.rb:2302` (detect_recover_stages) ; `src/tools/formatter.rb:2444` (emit_record_type) ; `src/tools/formatter.rb:2487` (emit_stmt_terminator)
- **[conjunction]** support=4 scatter=3 rank=12
  - tuple: `t.auto? | t.is_a?(Type)`
  - `src/annotator/helpers/auto_inference.rb:206` (auto?) ; `src/annotator/helpers/auto_inference.rb:581` (collect_observed_types) ; `src/annotator/helpers/auto_inference.rb:964` (auto?) ; `src/backends/importer.rb:164` (auto_type?)
- **[conjunction]** support=4 scatter=3 rank=12
  - tuple: `cursor.is_a?(AST::BinaryOp) | cursor.op == :SMOOTH`
  - `src/backends/pipeline_host.rb:2360` (unwrap_range_chain) ; `src/backends/pipeline_host.rb:2392` (unwrap_binding_unnest_chain) ; `src/backends/pipeline_host.rb:2403` (unwrap_binding_unnest_chain) ; `src/backends/pipeline_rewriter.rb:289` (collect_chain)
- **[case_dispatch]** support=4 scatter=3 rank=12
  - tuple: `AST::Assignment | AST::BindExpr | AST::VarDecl`
  - `src/mir/fsm_transform/liveness.rb:196` (collect_defs) ; `src/mir/mir_pass.rb:562` (collect_consumed_names) ; `src/mir/mir_pass.rb:582` (collect_consumed_names) ; `src/tools/migration_suggester_helpers.rb:88` (walk_recursive)
- **[conjunction]** support=4 scatter=3 rank=12
  - tuple: `bdepth.zero? | kdepth.zero?`
  - `src/tools/formatter.rb:588` (scan_match_arms) ; `src/tools/formatter.rb:629` (build_match_arm) ; `src/tools/formatter.rb:636` (build_match_arm) ; `src/tools/formatter.rb:743` (emit_match_body)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `slot.respond_to?(:shape) | slot.shape`
  - `src/annotator/annotator.rb:265` (emit_auto_shape_resolved_findings!) ; `src/annotator/helpers/fixable_helpers.rb:1461` (emit_auto_resolved_finding!) ; `src/annotator/helpers/fixable_helpers.rb:1623` (auto_slot_label)
- **[case_dispatch]** support=3 scatter=3 rank=9
  - tuple: `:block | :exit`
  - `src/annotator/annotator.rb:1019` (visit_SyncPolicyDecl) ; `src/annotator/annotator.rb:5083` (validate_snapshot_match_arms!) ; `src/mir/lowering/capabilities.rb:518` (build_fallible_clause_mir)
- **[case_dispatch]** support=3 scatter=3 rank=9
  - tuple: `:ATOMIC | :LOCKED | :VERSIONED`
  - `src/annotator/annotator.rb:4660` (visit_WithBlock) ; `src/mir/lowering/capabilities.rb:560` (with_match_probe_for_family) ; `src/mir/lowering/capabilities.rb:625` (with_match_arm_prelude)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `sym.indirect? | sym.respond_to?(:layout)`
  - `src/annotator/annotator.rb:4964` (reject_bare_atomic_ptr_mutation!) ; `src/annotator/helpers/function_analysis.rb:562` (atomic_cell_to_bare_value_param?) ; `src/annotator/helpers/function_analysis.rb:592` (atomic_cell_arg?)
- **[case_dispatch]** support=3 scatter=3 rank=9
  - tuple: `:kind | :type`
  - `src/annotator/annotator.rb:5111` (resolve_error_selectors!) ; `src/annotator/helpers/lock_helper.rb:414` (verify_handler_reachability!) ; `src/annotator/helpers/with_match_check.rb:420` (handled_error_set)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `node.is_a?(AST::FuncCall) | node.name == fn_name`
  - `src/annotator/annotator.rb:6348` (contains_self_call?) ; `src/mir/thunk_transform/recursive_splitter.rb:259` (direct_self_call) ; `src/mir/thunk_transform/recursive_splitter.rb:269` (contains_self_call?)
- **[case_dispatch]** support=3 scatter=3 rank=9
  - tuple: `:local | :param | :return`
  - `src/annotator/helpers/auto_inference.rb:634` (stamp_slot!) ; `src/annotator/helpers/fixable_helpers.rb:1589` (slot_id_for) ; `src/annotator/helpers/fixable_helpers.rb:1632` (auto_slot_label)
- **[case_dispatch]** support=3 scatter=3 rank=9
  - tuple: `AST::GetField | AST::GetIndex | AST::Identifier`
  - `src/annotator/helpers/capabilities.rb:757` (cap_var_name) ; `src/ast/ast.rb:362` (root_identifier) ; `src/ast/parser.rb:3954` (deep_clone_node)
- **[case_dispatch]** support=3 scatter=3 rank=9
  - tuple: `AST::SelectOp | AST::WhereOp`
  - `src/annotator/helpers/pipe_analysis.rb:1594` (analyze_concurrent_op) ; `src/annotator/helpers/pipe_analysis.rb:1664` (analyze_concurrent_bounded_select_family_op) ; `src/annotator/helpers/pipe_analysis.rb:1728` (analyze_concurrent_stream_select_family_op)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `!direct | reachable_from_self?(name)`
  - `src/annotator/helpers/reentrance.rb:235` (validate_not_logical_recursion!) ; `src/annotator/helpers/reentrance.rb:266` (validate_max_depth_mutual_cycle!) ; `src/annotator/helpers/reentrance.rb:320` (validate_thunk_recursion!)
- **[case_dispatch]** support=3 scatter=3 rank=9
  - tuple: `AST::LimitOp | AST::SelectOp | AST::SkipOp | AST::TakeWhileOp | AST::TapOp | AST::WhereOp`
  - `src/ast/ast.rb:1714` (pipeline_fusible_stage?) ; `src/backends/pipeline_host.rb:2688` (build_lazy_range_prefix) ; `src/backends/pipeline_rewriter.rb:509` (build_recursive_body)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `atomic? | indirect?`
  - `src/ast/ast.rb:1813` (atomic_ptr?) ; `src/ast/symbol_entry.rb:147` (atomic_ptr?) ; `src/ast/type.rb:705` (atomic_ptr?)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `!source.empty? | source`
  - `src/ast/syntax_typo_scanner.rb:41` (scan!) ; `src/mir/lowering/capabilities.rb:902` (lower_pre_clauses) ; `src/mir/lowering/functions.rb:670` (build_post_outer_fn)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `!string? | array?`
  - `src/ast/type.rb:375` (escape_class) ; `src/ast/type.rb:851` (non_string_array?) ; `src/ast/type.rb:915` (dispatch_key)
- ...(+167 more)

## Reification Misses (37)
_an existing predicate reinvented inline -- invariant #16_

- predicate `atomic?` reinvented inline at `src/ast/parser.rb:2936` (parse_type_annotation) (`sync == :atomic`)
- predicate `frame?` reinvented inline at `src/mir/cleanup_classifier.rb:179` (mark_iteration_values_function!) (`entry.alloc == :frame`)
- predicate `frame?` reinvented inline at `src/mir/control_flow.rb:1395` (process_loop!) (`entry.alloc == :frame`)
- predicate `frame?` reinvented inline at `src/mir/local_binding_facts.rb:100` (binding_frame_allocates?) (`entry.alloc == :frame`)
- predicate `frame?` reinvented inline at `src/mir/lowering/control_flow.rb:173` (lowered_loop_body_has_frame_scope?) (`s.alloc == :frame`)
- predicate `frame?` reinvented inline at `src/mir/lowering/control_flow.rb:202` (stamp_loop_frame_allocs_iteration!) (`s.alloc == :frame`)
- predicate `frame?` reinvented inline at `src/mir/lowering/functions.rb:478` (runtime_frame_prologue) (`e.alloc == :frame`)
- predicate `frame?` reinvented inline at `src/mir/mir_checker.rb:1183` (verify_owned_return_alloc_marks!) (`m.alloc == :frame`)
- predicate `frame?` reinvented inline at `src/mir/mir_checker.rb:1621` (verify_alloc_cleanup_match!) (`m.alloc == :frame`)
- predicate `frame?` reinvented inline at `src/mir/mir_checker.rb:2099` (body_has_frame_alloc_scope?) (`s.alloc == :frame`)
- predicate `frame?` reinvented inline at `src/mir/mir_checker.rb:2139` (expr_has_frame_alloc?) (`expr.alloc == :frame`)
- predicate `heap?` reinvented inline at `src/backends/pipeline_host.rb:534` (lower_pipeline_block) (`alloc == :heap`)
- predicate `heap?` reinvented inline at `src/backends/pipeline_host.rb:624` (owning_pipeline_temp_stmts) (`alloc == :heap`)
- predicate `heap?` reinvented inline at `src/backends/pipeline_host.rb:4536` (list_concurrent_source_setup_stmts) (`alloc == :heap`)
- predicate `heap?` reinvented inline at `src/mir/cleanup_classifier.rb:101` (stamp_binding_default_scope!) (`entry.alloc == :heap`)
- predicate `heap?` reinvented inline at `src/mir/cleanup_classifier.rb:307` (no_cleanup_alloc_entry) (`alloc == :heap`)
- predicate `heap?` reinvented inline at `src/mir/cleanup_entry.rb:39` (build) (`alloc == :heap`)
- predicate `heap?` reinvented inline at `src/mir/cleanup_entry.rb:103` (with_alloc) (`alloc == :heap`)
- predicate `heap?` reinvented inline at `src/mir/fsm_lowering.rb:224` (fsm_owned_transfer_identifier?) (`entry.alloc == :heap`)
- predicate `heap?` reinvented inline at `src/mir/hoist.rb:431` (hoist_lazy_alloc_result) (`alloc == :heap`)
- predicate `heap?` reinvented inline at `src/mir/hoist.rb:549` (hoist_alloc) (`alloc == :heap`)
- predicate `heap?` reinvented inline at `src/mir/hoist.rb:631` (hoist_normalized_alloc_expr) (`alloc == :heap`)
- predicate `heap?` reinvented inline at `src/mir/lowering/control_flow.rb:981` (return_transfers_heap_binding?) (`entry.alloc == :heap`)
- predicate `heap?` reinvented inline at `src/mir/lowering/functions.rb:580` (takes_param_ownership_mir) (`entry.alloc == :heap`)
- predicate `heap?` reinvented inline at `src/mir/lowering/variables.rb:421` (build_var_decl_nodes) (`binding_entry.alloc == :heap`)
- ...(+12 more)

## Semantic Predicate Aliases (3)
_one decision, multiple names (receiver/polarity folded)_

- `enum? = resource? = union? = struct? = needs_capture_site_annotation? = suspend? = mir? = stmt? = expr? = has_own_frame?` == `true`
  - `src/ast/schemas.rb:34` (enum?) ; `src/ast/schemas.rb:67` (resource?) ; `src/ast/schemas.rb:123` (union?) ; `src/ast/schemas.rb:169` (struct?) ; `src/mir/capture_strategy.rb:79` (needs_capture_site_annotation?) ; `src/mir/capture_strategy.rb:95` (needs_capture_site_annotation?) ; `src/mir/fsm_transform/segments.rb:51` (suspend?) ; `src/mir/fsm_transform/segments.rb:69` (suspend?) ; `src/mir/mir.rb:208` (mir?) ; `src/mir/mir.rb:244` (stmt?) ; `src/mir/mir.rb:266` (expr?) ; `src/mir/mir.rb:497` (has_own_frame?) ; `src/mir/mir.rb:930` (expr?) ; `src/mir/mir.rb:1006` (expr?) ; `src/mir/mir.rb:1029` (expr?) ; `src/mir/mir.rb:1147` (expr?) ; `src/mir/mir.rb:1158` (expr?) ; `src/mir/mir.rb:1175` (expr?) ; `src/mir/mir.rb:1211` (expr?) ; `src/mir/mir.rb:1974` (stmt?) ; `src/mir/mir.rb:2008` (stmt?) ; `src/mir/mir.rb:2032` (stmt?) ; `src/mir/mir.rb:2061` (stmt?) ; `src/mir/mir.rb:2072` (stmt?) ; `src/mir/mir.rb:2092` (stmt?) ; `src/mir/mir.rb:2119` (stmt?) ; `src/mir/mir.rb:2135` (stmt?) ; `src/mir/mir.rb:2142` (stmt?) ; `src/mir/mir.rb:2149` (stmt?) ; `src/mir/mir.rb:2156` (stmt?) ; `src/mir/mir.rb:2163` (stmt?) ; `src/mir/mir.rb:2170` (stmt?) ; `src/mir/mir.rb:2178` (stmt?) ; `src/mir/mir.rb:2189` (stmt?) ; `src/mir/mir.rb:2230` (stmt?) ; `src/mir/mir.rb:2238` (stmt?) ; `src/mir/mir.rb:2749` (expr?) ; `src/mir/mir.rb:2905` (expr?) ; `src/mir/mir.rb:2949` (expr?)
- `wildcard? = union? = struct? = resource? = enum? = needs_capture_site_annotation? = stmt? = expr?` == `false`
  - `src/ast/ast.rb:1309` (wildcard?) ; `src/ast/ast.rb:1453` (wildcard?) ; `src/ast/ast.rb:1468` (wildcard?) ; `src/ast/schemas.rb:36` (union?) ; `src/ast/schemas.rb:38` (struct?) ; `src/ast/schemas.rb:40` (resource?) ; `src/ast/schemas.rb:69` (union?) ; `src/ast/schemas.rb:71` (enum?) ; `src/ast/schemas.rb:73` (struct?) ; `src/ast/schemas.rb:125` (enum?) ; `src/ast/schemas.rb:127` (struct?) ; `src/ast/schemas.rb:129` (resource?) ; `src/ast/schemas.rb:171` (union?) ; `src/ast/schemas.rb:173` (enum?) ; `src/ast/schemas.rb:175` (resource?) ; `src/mir/capture_strategy.rb:51` (needs_capture_site_annotation?) ; `src/mir/capture_strategy.rb:64` (needs_capture_site_annotation?) ; `src/mir/capture_strategy.rb:108` (needs_capture_site_annotation?) ; `src/mir/mir.rb:210` (stmt?) ; `src/mir/mir.rb:212` (expr?)
- `auto? = auto_type?` == `t.is_a?(Type) && t.auto?`
  - `src/annotator/helpers/auto_inference.rb:205` (auto?) ; `src/annotator/helpers/auto_inference.rb:963` (auto?) ; `src/backends/importer.rb:163` (auto_type?)

## Exact Predicate Aliases (6)
_identical one-line predicate body under >=2 names_

- `enum? = resource? = union? = struct? = needs_capture_site_annotation? = suspend? = mir? = stmt? = expr? = has_own_frame?` == `true`
  - `src/ast/schemas.rb:34` (enum?) ; `src/ast/schemas.rb:67` (resource?) ; `src/ast/schemas.rb:123` (union?) ; `src/ast/schemas.rb:169` (struct?) ; `src/mir/capture_strategy.rb:79` (needs_capture_site_annotation?) ; `src/mir/capture_strategy.rb:95` (needs_capture_site_annotation?) ; `src/mir/fsm_transform/segments.rb:51` (suspend?) ; `src/mir/fsm_transform/segments.rb:69` (suspend?) ; `src/mir/mir.rb:208` (mir?) ; `src/mir/mir.rb:244` (stmt?) ; `src/mir/mir.rb:266` (expr?) ; `src/mir/mir.rb:497` (has_own_frame?) ; `src/mir/mir.rb:930` (expr?) ; `src/mir/mir.rb:1006` (expr?) ; `src/mir/mir.rb:1029` (expr?) ; `src/mir/mir.rb:1147` (expr?) ; `src/mir/mir.rb:1158` (expr?) ; `src/mir/mir.rb:1175` (expr?) ; `src/mir/mir.rb:1211` (expr?) ; `src/mir/mir.rb:1974` (stmt?) ; `src/mir/mir.rb:2008` (stmt?) ; `src/mir/mir.rb:2032` (stmt?) ; `src/mir/mir.rb:2061` (stmt?) ; `src/mir/mir.rb:2072` (stmt?) ; `src/mir/mir.rb:2092` (stmt?) ; `src/mir/mir.rb:2119` (stmt?) ; `src/mir/mir.rb:2135` (stmt?) ; `src/mir/mir.rb:2142` (stmt?) ; `src/mir/mir.rb:2149` (stmt?) ; `src/mir/mir.rb:2156` (stmt?) ; `src/mir/mir.rb:2163` (stmt?) ; `src/mir/mir.rb:2170` (stmt?) ; `src/mir/mir.rb:2178` (stmt?) ; `src/mir/mir.rb:2189` (stmt?) ; `src/mir/mir.rb:2230` (stmt?) ; `src/mir/mir.rb:2238` (stmt?) ; `src/mir/mir.rb:2749` (expr?) ; `src/mir/mir.rb:2905` (expr?) ; `src/mir/mir.rb:2949` (expr?)
- `wildcard? = union? = struct? = resource? = enum? = needs_capture_site_annotation? = stmt? = expr?` == `false`
  - `src/ast/ast.rb:1309` (wildcard?) ; `src/ast/ast.rb:1453` (wildcard?) ; `src/ast/ast.rb:1468` (wildcard?) ; `src/ast/schemas.rb:36` (union?) ; `src/ast/schemas.rb:38` (struct?) ; `src/ast/schemas.rb:40` (resource?) ; `src/ast/schemas.rb:69` (union?) ; `src/ast/schemas.rb:71` (enum?) ; `src/ast/schemas.rb:73` (struct?) ; `src/ast/schemas.rb:125` (enum?) ; `src/ast/schemas.rb:127` (struct?) ; `src/ast/schemas.rb:129` (resource?) ; `src/ast/schemas.rb:171` (union?) ; `src/ast/schemas.rb:173` (enum?) ; `src/ast/schemas.rb:175` (resource?) ; `src/mir/capture_strategy.rb:51` (needs_capture_site_annotation?) ; `src/mir/capture_strategy.rb:64` (needs_capture_site_annotation?) ; `src/mir/capture_strategy.rb:108` (needs_capture_site_annotation?) ; `src/mir/mir.rb:210` (stmt?) ; `src/mir/mir.rb:212` (expr?)
- `visit_PassStmt = visit_OrRaise = visit_OrBreak = visit_OrPass = visit_OrPrune` == `stamp_type!(node, :Void)`
  - `src/annotator/annotator.rb:1451` (visit_PassStmt) ; `src/annotator/annotator.rb:4100` (visit_OrRaise) ; `src/annotator/annotator.rb:4105` (visit_OrBreak) ; `src/annotator/annotator.rb:4110` (visit_OrPass) ; `src/annotator/annotator.rb:4117` (visit_OrPrune)
- `child_bodies = marker_plan = with_alias_ownership_marks = child_exprs = body_slots` == `[]`
  - `src/ast/ast.rb:599` (child_bodies) ; `src/mir/capture_strategy.rb:49` (marker_plan) ; `src/mir/capture_strategy.rb:62` (marker_plan) ; `src/mir/capture_strategy.rb:106` (marker_plan) ; `src/mir/lowering/capabilities.rb:88` (with_alias_ownership_marks) ; `src/mir/mir.rb:216` (child_exprs) ; `src/mir/mir.rb:218` (body_slots)
- `emit_rc_retain = emit_rc_downgrade = emit_weak_upgrade` == `"CheatLib.#{node.func}(#{node.zig_base}, #{emit(node.source)})"`
  - `src/mir/mir_emitter.rb:1184` (emit_rc_retain) ; `src/mir/mir_emitter.rb:1189` (emit_rc_downgrade) ; `src/mir/mir_emitter.rb:1194` (emit_weak_upgrade)
- `auto? = auto_type?` == `t.is_a?(Type) && t.auto?`
  - `src/annotator/helpers/auto_inference.rb:205` (auto?) ; `src/annotator/helpers/auto_inference.rb:963` (auto?) ; `src/backends/importer.rb:163` (auto_type?)

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
- *POSSIBLE* `src/mir/hoist.rb:822` (replace_mir_expr_child!) clone of `src/mir/hoist.rb:816` (replace_mir_expr_child!): ref var `parent` spelled ["value", "parent"] here
- *POSSIBLE* `src/mir/hoist.rb:829` (replace_mir_expr_child!) clone of `src/mir/hoist.rb:816` (replace_mir_expr_child!): ref var `parent` spelled ["value", "parent"] here
- *POSSIBLE* `src/annotator/annotator.rb:4067` (visit_OrRescue) clone of `src/annotator/annotator.rb:4052` (visit_OrRescue): ref var `payload_type` spelled ["wrapped", "wrapped_type"] here

## Neglected Updates (1772)
_co-written state, one write missing -- *POSSIBLE* redundant-state desync_

- *POSSIBLE* (support=11) `src/annotator/annotator.rb:1343` (visit_IfBind) writes `.ownership` but NOT `.sync` (recv `unwrapped`)
- *POSSIBLE* (support=11) `src/annotator/annotator.rb:1929` (visit_WhileBindLoop) writes `.ownership` but NOT `.sync` (recv `unwrapped`)
- *POSSIBLE* (support=11) `src/annotator/annotator.rb:4397` (visit_LinkNode) writes `.ownership` but NOT `.sync` (recv `link_type`)
- *POSSIBLE* (support=11) `src/annotator/annotator.rb:4416` (visit_ResolveNode) writes `.ownership` but NOT `.sync` (recv `resolved_type`)
- *POSSIBLE* (support=11) `src/annotator/annotator.rb:4430` (visit_FreezeNode) writes `.ownership` but NOT `.sync` (recv `result_type`)
- *POSSIBLE* (support=11) `src/annotator/helpers/auto_inference.rb:155` (initialize) writes `.@fn_nodes` but NOT `.@call_graph` (recv `self`)
- *POSSIBLE* (support=11) `src/annotator/helpers/capabilities.rb:413` (predicate_impurity_reason) writes `.@fn_nodes` but NOT `.@call_graph` (recv `self`)
- *POSSIBLE* (support=11) `src/annotator/helpers/capabilities.rb:1345` (record_capability_binding) writes `.@fn_nodes` but NOT `.@call_graph` (recv `self`)
- *POSSIBLE* (support=11) `src/annotator/helpers/effects.rb:600` (enforce_fallible_returns!) writes `.@fn_nodes` but NOT `.@call_graph` (recv `self`)
- *POSSIBLE* (support=11) `src/annotator/helpers/effects.rb:708` (mark_fn_value_references!) writes `.@fn_nodes` but NOT `.@call_graph` (recv `self`)
- *POSSIBLE* (support=11) `src/annotator/helpers/effects.rb:762` (compute_fsm_eligibility!) writes `.@fn_nodes` but NOT `.@call_graph` (recv `self`)
- *POSSIBLE* (support=11) `src/annotator/helpers/effects.rb:796` (enumerate_fsm_suspend_points!) writes `.@fn_nodes` but NOT `.@call_graph` (recv `self`)
- *POSSIBLE* (support=11) `src/annotator/helpers/effects.rb:853` (func_call_suspends?) writes `.@fn_nodes` but NOT `.@call_graph` (recv `self`)
- *POSSIBLE* (support=11) `src/annotator/helpers/effects.rb:1079` (mutually_recursive_in_call_graph?) writes `.@call_graph` but NOT `.@fn_nodes` (recv `self`)
- *POSSIBLE* (support=11) `src/annotator/helpers/effects.rb:1089` (reachable_in_call_graph?) writes `.@call_graph` but NOT `.@fn_nodes` (recv `self`)
- *POSSIBLE* (support=11) `src/annotator/helpers/effects.rb:1147` (validate_tight_node!) writes `.@fn_nodes` but NOT `.@call_graph` (recv `self`)
- *POSSIBLE* (support=11) `src/annotator/helpers/function_analysis.rb:98` (resolve_call) writes `.@fn_nodes` but NOT `.@call_graph` (recv `self`)
- *POSSIBLE* (support=11) `src/annotator/helpers/generic_analysis.rb:413` (generic_shared_payload_binding) writes `.ownership` but NOT `.sync` (recv `t`)
- *POSSIBLE* (support=11) `src/annotator/helpers/generic_analysis.rb:572` (propagate_collection_metadata!) writes `.sync` but NOT `.ownership` (recv `node_type`)
- *POSSIBLE* (support=11) `src/annotator/helpers/lock_helper.rb:213` (propagate_lock_acquires!) writes `.@call_graph` but NOT `.@fn_nodes` (recv `self`)
- *POSSIBLE* (support=11) `src/annotator/helpers/pipe_analysis.rb:142` (has_catch_blocks?) writes `.@fn_nodes` but NOT `.@call_graph` (recv `self`)
- *POSSIBLE* (support=11) `src/annotator/helpers/reentrance.rb:224` (validate_not_logical_recursion!) writes `.@fn_nodes` but NOT `.@call_graph` (recv `self`)
- *POSSIBLE* (support=11) `src/annotator/helpers/reentrance.rb:259` (validate_max_depth_mutual_cycle!) writes `.@fn_nodes` but NOT `.@call_graph` (recv `self`)
- *POSSIBLE* (support=11) `src/annotator/helpers/reentrance.rb:354` (try_stamp_mutual_thunk_plan!) writes `.@fn_nodes` but NOT `.@call_graph` (recv `self`)
- *POSSIBLE* (support=11) `src/annotator/helpers/reentrance.rb:414` (emit_mutual_thunk_unsupported!) writes `.@fn_nodes` but NOT `.@call_graph` (recv `self`)
- ...(+1747 more)

## Derived-State Staleness (151)
_b = f(a); a later reassigned, b not recomputed -- *POSSIBLE* bug_

- *POSSIBLE* `src/ast/ast.rb:827` (finalize_storage!): `value_sync` derived from `vt` (line 827); `vt` reassigned line 902, `value_sync` not recomputed
- *POSSIBLE* `src/tools/doctor.rb:158` (section_heap): `addrs` derived from `sites` (line 158); `sites` reassigned line 218, `addrs` not recomputed
- *POSSIBLE* `src/ast/type.rb:2319` (compute_zig_type): `inner_zig` derived from `base_zig` (line 2319); `base_zig` reassigned line 2373, `inner_zig` not recomputed
- *POSSIBLE* `src/annotator/annotator.rb:2088` (visit_ReturnNode): `expected_void_compatible` derived from `expected` (line 2088); `expected` reassigned line 2141, `expected_void_compatible` not recomputed
- *POSSIBLE* `src/mir/lowering/expressions.rb:406` (lower_smooth): `call` derived from `left` (line 406); `left` reassigned line 454, `call` not recomputed
- *POSSIBLE* `src/annotator/helpers/capabilities.rb:199` (validate_capability): `atomic_ptr_ok` derived from `syn` (line 199); `syn` reassigned line 244, `atomic_ptr_ok` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:2817` (needs_space?): `a_is_struct_open` derived from `a_idx` (line 2817); `a_idx` reassigned line 2861, `a_is_struct_open` not recomputed
- *POSSIBLE* `src/ast/ast.rb:832` (finalize_storage!): `t` derived from `val_ti` (line 832); `val_ti` reassigned line 872, `t` not recomputed
- *POSSIBLE* `src/annotator/helpers/capabilities.rb:845` (declare_capability_scope!): `inner` derived from `st` (line 845); `st` reassigned line 873, `inner` not recomputed
- *POSSIBLE* `src/backends/pipeline_host.rb:326` (substitute_placeholders): `new_mc` derived from `new_target` (line 326); `new_target` reassigned line 353, `new_mc` not recomputed
- *POSSIBLE* `src/ast/diagnostic_examples.rb:92` (scan_file): `j` derived from `i` (line 92); `i` reassigned line 117, `j` not recomputed
- *POSSIBLE* `src/backends/pipeline_rewriter.rb:561` (build_recursive_body): `skip_if` derived from `cond` (line 561); `cond` reassigned line 586, `skip_if` not recomputed
- *POSSIBLE* `src/annotator/helpers/generic_analysis.rb:223` (validate_type_annotation!): `expected` derived from `schema` (line 223); `schema` reassigned line 247, `expected` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:2264` (find_s_chains): `s_idxs` derived from `i` (line 2264); `i` reassigned line 2288, `s_idxs` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:1183` (branch_end_for_inline_expansion): `t` derived from `j` (line 1183); `j` reassigned line 1206, `t` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:2266` (find_s_chains): `j` derived from `i` (line 2266); `i` reassigned line 2288, `j` not recomputed
- *POSSIBLE* `src/mir/lowering/literals.rb:40` (lower_list_lit): `promise_zig` derived from `elem_zig` (line 40); `elem_zig` reassigned line 61, `promise_zig` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:1636` (expand_concurrent_drops): `t` derived from `i` (line 1636); `i` reassigned line 1655, `t` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:2933` (capability_chain_colon?): `t` derived from `j` (line 2933); `j` reassigned line 2952, `t` not recomputed
- *POSSIBLE* `src/annotator/annotator.rb:3111` (visit_Assignment): `tname` derived from `target` (line 3111); `target` reassigned line 3129, `tname` not recomputed
- *POSSIBLE* `src/mir/lowering/functions.rb:875` (cross_boundary_arg): `moved_arg` derived from `arg` (line 875); `arg` reassigned line 893, `moved_arg` not recomputed
- *POSSIBLE* `src/ast/type.rb:2102` (parse_raw_input): `inner` derived from `match` (line 2102); `match` reassigned line 2119, `inner` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:1118` (find_fn_arrow): `t` derived from `j` (line 1118); `j` reassigned line 1135, `t` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:1638` (expand_concurrent_drops): `paren_open` derived from `i` (line 1638); `i` reassigned line 1655, `paren_open` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:2935` (capability_chain_colon?): `k` derived from `j` (line 2935); `j` reassigned line 2952, `k` not recomputed
- ...(+126 more)

## Neglected Conditions (11)
_dispatch/conjunction minus one element -- *POSSIBLE* bug_

- *POSSIBLE* (support=5) `src/tools/formatter.rb:1260` (one_liner_end) -- MISSING `'START'` from `'END' | 'FN' | 'FOR' | 'IF' | 'START' | 'TEST' | 'WHEN' | 'WHILE'`
- *POSSIBLE* (support=5) `src/tools/formatter.rb:1332` (expand_if_while_for) -- MISSING `'START'` from `'END' | 'FN' | 'FOR' | 'IF' | 'START' | 'TEST' | 'WHEN' | 'WHILE'`
- *POSSIBLE* (support=4) `src/mir/local_binding_facts.rb:78` (binding_decl_name) -- MISSING `AST::Assignment` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- *POSSIBLE* (support=4) `src/mir/local_binding_facts.rb:90` (binding_entry) -- MISSING `AST::Assignment` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- *POSSIBLE* (support=4) `src/tools/atomic_migration_suggester.rb:129` (stmt_eligible?) -- MISSING `AST::VarDecl` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- *POSSIBLE* (support=4) `src/tools/atomic_ptr_migration_suggester.rb:120` (stmt_eligible?) -- MISSING `AST::VarDecl` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- *POSSIBLE* (support=3) `src/annotator/annotator.rb:5061` (validate_snapshot_match_arms!) -- MISSING `:LOCKED` from `:ATOMIC | :LOCKED | :VERSIONED`
- *POSSIBLE* (support=3) `src/mir/cleanup_classifier.rb:627` (finalize_alloc_from_storage!) -- MISSING `decl.symbol` from `decl | decl.respond_to?(:symbol) | decl.symbol`
- *POSSIBLE* (support=3) `src/mir/cleanup_classifier.rb:754` (container_alloc_from) -- MISSING `decl.symbol` from `decl | decl.respond_to?(:symbol) | decl.symbol`
- *POSSIBLE* (support=3) `src/mir/fsm_transform/recursive_splitter.rb:373` (emit_pivot) -- MISSING `AST::CatchBlock` from `AST::CatchBlock | AST::ForEach | AST::ForRange | AST::IfStatement | AST::WhileBindLoop | AST::WhileLoop | AST::WithBlock`
- *POSSIBLE* (support=3) `src/mir/lowering/capabilities.rb:151` (build_field_path_zig) -- MISSING `AST::GetIndex` from `AST::GetField | AST::GetIndex | AST::Identifier`

## Neglected Path Conditions (1969)
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
- *POSSIBLE* (support=35) `src/annotator/helpers/function_analysis.rb:196` (resolve_call) -- MISSING `inner.is_a?(Type)` from `!func_type == :Intrinsic | !type_params&.any? | call_type.error_union? | call_type.respond_to?(:error_union?) | entry&.storage == :static | fsig | func_type = fsig | inner.is_a?(Type)`
- ...(+1944 more)

## Broken Protocols (1513)
_co-called pair, one site does A without B -- *POSSIBLE* bug (noisy)_

- *POSSIBLE* conf=0.98 support=48 `src/ast/ast.rb:610` (column) does `column` without `line`
- *POSSIBLE* conf=0.98 support=44 `src/ast/parser.rb:1814` (parse_binary_op) does `parse_expression` without `consume`
- *POSSIBLE* conf=0.96 support=46 `src/backends/pipeline_host.rb:3255` (default_obs_alloc_zig) does `transpile_type` without `new`
- *POSSIBLE* conf=0.96 support=46 `src/mir/mir_lowering.rb:2429` (bare_zig_type) does `transpile_type` without `new`
- *POSSIBLE* conf=0.96 support=25 `src/annotator/annotator.rb:1300` (visit_IfStatement) does `proc` without `[]`
- *POSSIBLE* conf=0.96 support=22 `src/annotator/annotator.rb:913` (validate_and_resolve_sync_policy!) does `statements` without `each`
- *POSSIBLE* conf=0.95 support=36 `src/ast/parser.rb:524` (match_literal!) does `match!` without `consume`
- *POSSIBLE* conf=0.95 support=36 `src/ast/parser.rb:3560` (parse_error_selectors) does `match!` without `consume`
- *POSSIBLE* conf=0.95 support=36 `src/backends/pipeline_host.rb:176` (visit) does `visit_mir` without `new`
- *POSSIBLE* conf=0.95 support=36 `src/backends/pipeline_host.rb:838` (visit_pipeline_expr_mir) does `visit_mir` without `new`
- *POSSIBLE* conf=0.95 support=21 `src/annotator/annotator.rb:5659` (promote_to_expr_if!) does `else_branch` without `then_branch`
- *POSSIBLE* conf=0.95 support=21 `src/mir/lowering/variables.rb:1184` (auto_lock_assignment_value) does `hoist_alloc` without `new`
- *POSSIBLE* conf=0.95 support=21 `src/mir/mir_pass.rb:787` (stamp_if_bind_cleanup!) does `then_branch` without `else_branch`
- *POSSIBLE* conf=0.95 support=18 `src/annotator/helpers/pipe_analysis.rb:45` (finite_stream_source?) does `dynamic_stream?` without `inf_stream?`
- *POSSIBLE* conf=0.94 support=32 `src/annotator/helpers/function_analysis.rb:21` (analyze_routine) does `with_new_scope` without `current_scope`
- *POSSIBLE* conf=0.94 support=32 `src/annotator/helpers/test_annotation.rb:34` (visit_TestBlock) does `with_new_scope` without `current_scope`
- *POSSIBLE* conf=0.94 support=17 `src/annotator/helpers/pipe_analysis.rb:859` (analyze_skip_op) does `finite_stream_element_type` without `current_scope`
- *POSSIBLE* conf=0.94 support=17 `src/annotator/helpers/pipe_analysis.rb:859` (analyze_skip_op) does `finite_stream_element_type` without `declare`
- *POSSIBLE* conf=0.94 support=17 `src/annotator/helpers/pipe_analysis.rb:859` (analyze_skip_op) does `finite_stream_element_type` without `with_new_scope`
- *POSSIBLE* conf=0.94 support=17 `src/annotator/helpers/pipe_analysis.rb:1213` (analyze_auto_shard_each_op) does `finite_stream_element_type` without `right`
- *POSSIBLE* conf=0.94 support=17 `src/annotator/helpers/pipe_analysis.rb:1745` (analyze_concurrent_stream_each_op) does `finite_stream_element_type` without `resolved_type`
- *POSSIBLE* conf=0.94 support=16 `src/annotator/helpers/pipe_analysis.rb:536` (analyze_recover_op) does `payload_type` without `error_union?`
- *POSSIBLE* conf=0.94 support=16 `src/annotator/helpers/pipe_analysis.rb:1424` (numeric_literal_value) does `to_f` without `[]`
- *POSSIBLE* conf=0.94 support=16 `src/mir/lowering/variables.rb:163` (lower_var_decl) does `with_decl_alloc` without `lower`
- *POSSIBLE* conf=0.94 support=16 `src/mir/lowering/variables.rb:1179` (auto_lock_assignment_value) does `with_decl_alloc` without `new`
- ...(+1488 more)

## False Simplicity (720)
_looks simple, behaves non-locally: hidden dispatch/mutation/IO/context/metaprogramming/monkeypatch -- *POSSIBLE* (noisy)_

- *POSSIBLE* [hidden_mutation] scatter=440 support=1233 `<<` -- `src/annotator/annotator.rb:80` (record_snapshot_txn_violation!) (+1227 more)
- *POSSIBLE* [hidden_mutation] scatter=253 support=438 `full_type!` -- `src/annotator/annotator.rb:73` (stamp_type!) (+427 more)
- *POSSIBLE* [hidden_mutation] scatter=232 support=479 `[]=` -- `src/annotator/annotator.rb:267` (emit_auto_shape_resolved_findings!) (+477 more)
- *POSSIBLE* [hidden_mutation] scatter=208 support=409 `error!` -- `src/annotator/annotator.rb:189` (annotate!) (+408 more)
- *POSSIBLE* [hidden_mutation] scatter=128 support=202 `stamp_type!` -- `src/annotator/annotator.rb:498` (visit_Program) (+201 more)
- *POSSIBLE* [hidden_mutation] scatter=72 support=126 `op-assign` -- `src/annotator/annotator.rb:90` (with_conditional_context) (+125 more)
- *POSSIBLE* [hidden_mutation] scatter=62 support=90 `storage=` -- `src/annotator/annotator.rb:1291` (visit_BlockExpr) (+89 more)
- *POSSIBLE* [hidden_mutation] scatter=61 support=65 `from_node!` -- `src/annotator/annotator.rb:4335` (visit_CopyNode) (+64 more)
- *POSSIBLE* [hidden_mutation] scatter=48 support=50 `fixable!` -- `src/annotator/annotator.rb:2728` (finalize_decl_node!) (+49 more)
- *POSSIBLE* [dynamic_dispatch] scatter=40 support=70 `instance_variable_get` -- `src/annotator/annotator.rb:2743` (finalize_decl_node!) (+69 more)
- *POSSIBLE* [hidden_mutation] scatter=38 support=99 `match!` -- `src/ast/parser.rb:159` ((top-level)) (+98 more)
- *POSSIBLE* [dynamic_dispatch] scatter=35 support=55 `send` -- `src/annotator/annotator.rb:377` (visit) (+54 more)
- *POSSIBLE* [hidden_io] scatter=35 support=41 `File.exist?` -- `src/ast/diagnostic_examples.rb:72` (load!) (+40 more)
- *POSSIBLE* [callback_inversion] scatter=34 support=37 `with_new_scope` -- `src/annotator/annotator.rb:844` (visit_FunctionDef) (+36 more)
- *POSSIBLE* [hidden_io] scatter=31 support=39 `File.join` -- `src/backends/importer.rb:64` (resolve_stdlib_package) (+38 more)
- *POSSIBLE* [dynamic_dispatch] scatter=31 support=36 `yield` -- `src/annotator/helpers/auto_inference.rb:746` (walk_for_shape_decls) (+35 more)
- *POSSIBLE* [callback_inversion] scatter=23 support=39 `with_pipeline_context` -- `src/backends/pipeline_host.rb:243` (visit_pipeline_body_mir) (+38 more)
- *POSSIBLE* [hidden_mutation] scatter=23 support=23 `scope=` -- `src/ast/scope.rb:40` (declare) (+22 more)
- *POSSIBLE* [hidden_io] scatter=22 support=267 `puts` -- `src/backends/transpiler.rb:329` ((top-level)) (+266 more)
- *POSSIBLE* [metaprogramming] scatter=22 support=52 `instance_variable_set` -- `src/annotator/annotator.rb:2374` (visit_FuncCall) (+51 more)
- *POSSIBLE* [hidden_mutation] scatter=21 support=31 `ownership=` -- `src/annotator/annotator.rb:1343` (visit_IfBind) (+30 more)
- *POSSIBLE* [hidden_mutation] scatter=19 support=25 `emit_typo_suggestion!` -- `src/annotator/annotator.rb:1407` (annotate_struct_pattern!) (+24 more)
- *POSSIBLE* [dynamic_dispatch] scatter=19 support=21 `schema_lookup.call` -- `src/ast/type.rb:1022` (resolve_resource_close) (+20 more)
- *POSSIBLE* [dynamic_dispatch] scatter=19 support=20 `blk.call` -- `src/annotator/annotator.rb:92` (with_conditional_context) (+19 more)
- *POSSIBLE* [hidden_mutation] scatter=18 support=24 `provenance=` -- `src/annotator/annotator.rb:3762` (visit_ListLit) (+23 more)
- ...(+695 more)

## Fat Unions (8)
_case dispatch over class consts whose arms read mostly variant-invariant members -- product-vs-sum decomposition candidate (extraction -> nil-kill) -- *POSSIBLE*_

- *POSSIBLE* [DEGENERATE: no variance] union `AST::Assignment | AST::BindExpr | AST::VarDecl` -- **3 common** vs 0 variant member(s), scatter=3 -- `src/mir/fsm_transform/liveness.rb:196` (collect_defs)
  - common: `is_a?, name, value` -> hoist to a struct, keep a SMALL union for `` (-> nil-kill)
- *POSSIBLE* [DEGENERATE: no variance] union `AST::AllOp | AST::AnyOp | AST::AverageOp | AST::CountOp | AST::FindOp | AST::MaxOp | AST::MinOp | AST::SumOp` -- **2 common** vs 0 variant member(s), scatter=4 -- `src/ast/ast.rb:1746` (pipeline_range_fold?)
  - common: `class, expression` -> hoist to a struct, keep a SMALL union for `` (-> nil-kill)
- *POSSIBLE* [DEGENERATE: no variance] union `AST::Assignment | AST::BindExpr | AST::FuncCall | AST::MethodCall | AST::VarDecl` -- **7 common** vs 0 variant member(s), scatter=1 -- `src/mir/mir_pass.rb:512` (recurse_branches!)
  - common: `body, branches, cases, default_case, do_branch, else_branch, then_branch` -> hoist to a struct, keep a SMALL union for `` (-> nil-kill)
- *POSSIBLE* [DEGENERATE: no variance] union `AST::GetField | AST::GetIndex | AST::Identifier | String` -- **2 common** vs 0 variant member(s), scatter=1 -- `src/annotator/annotator.rb:3130` (visit_Assignment)
  - common: `is_a?, target` -> hoist to a struct, keep a SMALL union for `` (-> nil-kill)
- *POSSIBLE* [DEGENERATE: no variance] union `AST::IndexOp | AST::OrderByOp | AST::SelectOp | AST::WhereOp` -- **2 common** vs 0 variant member(s), scatter=1 -- `src/annotator/helpers/pipe_analysis.rb:310` (analyze_select_family_op)
  - common: `expression, is_a?` -> hoist to a struct, keep a SMALL union for `` (-> nil-kill)
- *POSSIBLE* union `Array | FalseClass | Hash | Numeric | String | Symbol | TrueClass | Type` -- **6 common** vs 4 variant member(s), scatter=2 -- `src/annotator/annotator.rb:278` (program_has_auto?)
  - common: `each_pair, nil?, params, respond_to?, return_type, type` -> hoist to a struct, keep a SMALL union for `any?, auto?, each, each_value` (-> nil-kill)
- *POSSIBLE* union `AST::EnumDef | AST::StructDef | AST::UnionDef` -- **4 common** vs 2 variant member(s), scatter=3 -- `src/backends/compiler_frontend.rb:87` (compile)
  - common: `is_a?, name, variants, visibility` -> hoist to a struct, keep a SMALL union for `field_decls, type_params` (-> nil-kill)
- *POSSIBLE* union `AST::ForEach | AST::ForRange | AST::IfStatement | AST::MatchStatement | AST::WhileLoop` -- **5 common** vs 2 variant member(s), scatter=1 -- `src/mir/control_flow.rb:733` (transfer_stmt)
  - common: `is_a?, mode, name, value, var_name` -> hoist to a struct, keep a SMALL union for `collection, expr` (-> nil-kill)

## Run Summary
- Files analyzed: 110
- Detectors: 13 (all shipped, self-tested)
- Convergence: 1304 unit(s) flagged by >=2 independent detectors
- Root-cause clusters: 334 (one fix collapses each)
- Total candidates: 6688
- Method: stdlib AST only, intra-procedural, zero deps, no CFG / no points-to (see docs/agents/design.md)
