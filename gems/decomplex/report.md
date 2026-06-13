# Decomplex Report

> Decision-level duplication and neglected-condition analysis.
> Every entry is a ranked **candidate** (Engler's discipline),
> never a verdict -- *POSSIBLE* findings, triaged by a human.
> Sections are ordered by SIGNAL TIER (1 = lowest false
> positive), not by volume. Items within a section are
> frequency-ranked. Triage tier 1, top-of-list, first.

## Table of Contents
- [Project Prioritization](#project-prioritization)
- [Cross-Detector Convergence (653)](#cross-detector-convergence-653)
- [Root-Cause Clusters (207)](#root-cause-clusters-207)
- [Decision Pressure (135)](#decision-pressure-135)
- [Redundant Nil Guards (0)](#redundant-nil-guards-0)
- [State Heatmap (250)](#state-heatmap-250)
- [State-Based Branch Density (539)](#statebased-branch-density-539)
- [Temporal Ordering Pressure (4)](#temporal-ordering-pressure-4)
- [Missing Abstractions (28)](#missing-abstractions-28)
- [Reification Misses (6)](#reification-misses-6)
- [Semantic Predicate Aliases (3)](#semantic-predicate-aliases-3)
- [Exact Predicate Aliases (4)](#exact-predicate-aliases-4)
- [Inconsistent Rename Clones (0)](#inconsistent-rename-clones-0)
- [Structural Similarity (Type-2/3) (0)](#structural-similarity-type23-0)
- [Neglected Updates (169)](#neglected-updates-169)
- [Derived-State Staleness (15)](#derivedstate-staleness-15)
- [Neglected Conditions (0)](#neglected-conditions-0)
- [Neglected Path Conditions (269)](#neglected-path-conditions-269)
- [Oversized Predicates (5)](#oversized-predicates-5)
- [Broken Protocols (106)](#broken-protocols-106)
- [Implicit Control Flow (26)](#implicit-control-flow-26)
- [Weighted Inlined Cognitive Complexity (88)](#weighted-inlined-cognitive-complexity-88)
- [Locality Drag (0)](#locality-drag-0)
- [Operational Discontinuity (High Confidence) (0)](#operational-discontinuity-high-confidence-0)
- [Function LCOM (1)](#function-lcom-1)
- [Operational Discontinuity (4)](#operational-discontinuity-4)
- [False Simplicity (603)](#false-simplicity-603)
- [Fat Unions (1)](#fat-unions-1)
- [Run Summary](#run-summary)

## Project Prioritization
_Ordered by signal tier (1 = highest signal / lowest FP), then by volume._

- **[tier 1]** [State-Based Branch Density (539)](#statebased-branch-density-539): branch decisions over mutable/object state -- state + control-flow pressure
- **[tier 1]** [State Heatmap (250)](#state-heatmap-250): state fields ranked by write/read/re-derivation scatter -- tangled mutable state should get one owner
- **[tier 1]** [Decision Pressure (135)](#decision-pressure-135): ELIMINABLE guard-pressure per loose contract (nil/is_a?/respond_to?/safe-nav/rescue-nil) -> tighten the contract once / nil-kill: DELETE. essential dispatch + pure c-uses are split out, NEVER summed (Rapps-Weyuker p-use; McCabe)
- **[tier 1]** [Missing Abstractions (28)](#missing-abstractions-28): guard tuple recomputed across >=2 decision units
- **[tier 1]** [Reification Misses (6)](#reification-misses-6): an existing predicate reinvented inline -- invariant #16
- **[tier 1]** [Temporal Ordering Pressure (4)](#temporal-ordering-pressure-4): public mutable lifecycle surfaces that create implicit state-machine ordering
- **[tier 1]** [Exact Predicate Aliases (4)](#exact-predicate-aliases-4): identical one-line predicate body under >=2 names
- **[tier 1]** [Semantic Predicate Aliases (3)](#semantic-predicate-aliases-3): one decision, multiple names (receiver/polarity folded)
- **[tier 2]** [Neglected Updates (169)](#neglected-updates-169): co-written state, one write missing -- *POSSIBLE* redundant-state desync
- **[tier 2]** [Weighted Inlined Cognitive Complexity (88)](#weighted-inlined-cognitive-complexity-88): same-owner helper chain hides cognitive load behind a low-looking orchestration method
- **[tier 2]** [Implicit Control Flow (26)](#implicit-control-flow-26): state-dependent internal call order exists -- hidden lifecycle/control-flow pressure
- **[tier 2]** [Derived-State Staleness (15)](#derivedstate-staleness-15): b = f(a); a later reassigned, b not recomputed -- *POSSIBLE* bug
- **[tier 3]** [False Simplicity (603)](#false-simplicity-603): looks simple, behaves non-locally: hidden dispatch/mutation/IO/context/metaprogramming/monkeypatch -- *POSSIBLE* (noisy)
- **[tier 3]** [Neglected Path Conditions (269)](#neglected-path-conditions-269): nested-if/&& guard set minus one atom -- *POSSIBLE* bug (noisy)
- **[tier 3]** [Broken Protocols (106)](#broken-protocols-106): co-called pair, one site does A without B -- *POSSIBLE* bug (noisy)
- **[tier 3]** [Oversized Predicates (5)](#oversized-predicates-5): predicate with >3 condition atoms -- use an existing helper or extract a named predicate
- **[tier 3]** [Operational Discontinuity (4)](#operational-discontinuity-4): blank/comment phase boundary where local variable lifetimes reset -- *POSSIBLE* implicit sub-function boundary
- **[tier 3]** [Function LCOM (1)](#function-lcom-1): independent local data-flow components inside one method -- *POSSIBLE* mixed concerns
- **[tier 3]** [Fat Unions (1)](#fat-unions-1): case dispatch over class consts whose arms read mostly variant-invariant members -- product-vs-sum decomposition candidate (extraction -> nil-kill) -- *POSSIBLE*

## Cross-Detector Convergence (653)
_(file, method) units flagged by >=2 INDEPENDENT detectors -- the strongest triage signal: agreement outranks any single detector's volume. Tier-weighted (1=3, 2=2, 3=1). **Start here.**_

- `src/annotator/helpers/function_analysis.rb:419` (resolve_call) -- **7 detectors** [score 15, 123 findings]: Decision Pressure, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/annotator/domains/variables.rb:607` (visit_Assignment) -- **7 detectors** [score 15, 22 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/annotator/domains/execution_boundaries.rb:40` (visit_WithBlock) -- **7 detectors** [score 13, 72 findings]: Broken Protocols, Decision Pressure, False Simplicity, Implicit Control Flow, Neglected Path Conditions, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/annotator/helpers/capabilities.rb:636` (visit_post_clauses!) -- **6 detectors** [score 13, 16 findings]: Broken Protocols, Decision Pressure, False Simplicity, Implicit Control Flow, Missing Abstractions, State-Based Branch Density
- `src/annotator/helpers/pipe_analysis.rb:817` (analyze_pipe_to_named_function) -- **6 detectors** [score 13, 15 findings]: Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, State-Based Branch Density
- `src/annotator/domains/variables.rb:156` (finalize_decl_node!) -- **6 detectors** [score 12, 77 findings]: Decision Pressure, False Simplicity, Implicit Control Flow, Neglected Path Conditions, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/annotator/helpers/pipe_analysis.rb:1490` (analyze_concurrent_op) -- **6 detectors** [score 12, 51 findings]: Decision Pressure, False Simplicity, Neglected Path Conditions, Neglected Updates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/annotator/helpers/pipe_analysis.rb:357` (analyze_select_family_op) -- **6 detectors** [score 12, 29 findings]: Decision Pressure, False Simplicity, Fat Unions, Implicit Control Flow, Neglected Updates, State-Based Branch Density
- `src/annotator/helpers/pipe_analysis.rb:549` (analyze_join_op) -- **6 detectors** [score 12, 25 findings]: Broken Protocols, Decision Pressure, False Simplicity, Implicit Control Flow, Neglected Updates, State-Based Branch Density
- `src/annotator/helpers/function_analysis.rb:102` (analyze_routine) -- **6 detectors** [score 12, 23 findings]: Broken Protocols, Decision Pressure, False Simplicity, Implicit Control Flow, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/annotator/helpers/pipe_analysis.rb:730` (analyze_distinct_op) -- **6 detectors** [score 12, 23 findings]: Broken Protocols, Decision Pressure, False Simplicity, Implicit Control Flow, Neglected Updates, State-Based Branch Density
- `src/annotator/helpers/generic_analysis.rb:596` (register_container_borrow!) -- **6 detectors** [score 12, 17 findings]: Broken Protocols, Decision Pressure, False Simplicity, Neglected Updates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/annotator/helpers/pipe_analysis.rb:666` (analyze_unnest_op) -- **6 detectors** [score 12, 17 findings]: Broken Protocols, Decision Pressure, False Simplicity, Implicit Control Flow, Neglected Updates, State-Based Branch Density
- `src/annotator/phases/expression_domains.rb:53` (visit_MethodCall) -- **6 detectors** [score 12, 13 findings]: Broken Protocols, Decision Pressure, False Simplicity, Implicit Control Flow, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/annotator/helpers/capabilities.rb:764` (acquire_capability!) -- **6 detectors** [score 11, 58 findings]: Broken Protocols, Decision Pressure, False Simplicity, Neglected Path Conditions, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/annotator/helpers/pipe_analysis.rb:607` (analyze_reduce_op) -- **6 detectors** [score 11, 17 findings]: Broken Protocols, False Simplicity, Implicit Control Flow, Neglected Updates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/annotator/domains/lifetimes.rb:253` (visit_CloneNode) -- **5 detectors** [score 12, 21 findings]: Decision Pressure, False Simplicity, Missing Abstractions, Neglected Updates, State-Based Branch Density
- `src/annotator/domains/lifetimes.rb:1162` (move_if_not_copyable!) -- **5 detectors** [score 12, 17 findings]: Decision Pressure, False Simplicity, Missing Abstractions, Neglected Updates, State-Based Branch Density
- `src/annotator/domains/lifetimes.rb:1188` (move_if_takes_ownership!) -- **5 detectors** [score 12, 16 findings]: Decision Pressure, False Simplicity, Missing Abstractions, Neglected Updates, State-Based Branch Density
- `src/annotator/domains/lifetimes.rb:280` (visit_ShareNode) -- **5 detectors** [score 12, 14 findings]: Decision Pressure, False Simplicity, Missing Abstractions, Neglected Updates, State-Based Branch Density
- `src/annotator/helpers/function_analysis.rb:228` (visit_FunctionDef) -- **5 detectors** [score 11, 81 findings]: Decision Pressure, False Simplicity, Implicit Control Flow, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/annotator/domains/errors.rb:375` (visit_ReturnNode) -- **5 detectors** [score 11, 59 findings]: Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Updates, State-Based Branch Density
- `src/annotator/helpers/pipe_analysis.rb:486` (analyze_batch_window_op) -- **5 detectors** [score 11, 30 findings]: Decision Pressure, False Simplicity, Implicit Control Flow, Neglected Updates, State-Based Branch Density
- `src/annotator/helpers/pipe_analysis.rb:1354` (analyze_shard_op) -- **5 detectors** [score 11, 26 findings]: Decision Pressure, False Simplicity, Implicit Control Flow, Neglected Updates, State-Based Branch Density
- `src/ast/ast.rb:1087` (finalize_storage!) -- **5 detectors** [score 11, 25 findings]: Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Updates, State-Based Branch Density
- ...(+628 more)

### By file
- `src/ast/type.rb` -- 14 detectors across 52 method(s): Broken Protocols, Decision Pressure, Exact Predicate Aliases, False Simplicity, Function LCOM, Implicit Control Flow, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Operational Discontinuity, Oversized Predicates, State-Based Branch Density, Temporal Ordering Pressure, Weighted Inlined Cognitive Complexity
- `src/annotator/helpers/pipe_analysis.rb` -- 11 detectors across 54 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Fat Unions, Implicit Control Flow, Missing Abstractions, Neglected Path Conditions, Neglected Updates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/annotator/domains/lifetimes.rb` -- 10 detectors across 36 method(s): Broken Protocols, Decision Pressure, False Simplicity, Implicit Control Flow, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Operational Discontinuity, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/ast/ast.rb` -- 10 detectors across 32 method(s): Decision Pressure, Derived-State Staleness, Exact Predicate Aliases, False Simplicity, Missing Abstractions, Neglected Path Conditions, Neglected Updates, Reification Misses, Semantic Predicate Aliases, State-Based Branch Density
- `src/annotator/domains/execution_boundaries.rb` -- 10 detectors across 19 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Implicit Control Flow, Missing Abstractions, Neglected Path Conditions, Neglected Updates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/annotator/domains/variables.rb` -- 10 detectors across 20 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Implicit Control Flow, Missing Abstractions, Neglected Path Conditions, Neglected Updates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/annotator/helpers/function_analysis.rb` -- 9 detectors across 40 method(s): Broken Protocols, Decision Pressure, False Simplicity, Implicit Control Flow, Missing Abstractions, Neglected Path Conditions, Neglected Updates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/annotator/helpers/capabilities.rb` -- 9 detectors across 30 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Implicit Control Flow, Missing Abstractions, Neglected Path Conditions, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/annotator/domains/control_flow.rb` -- 9 detectors across 30 method(s): Broken Protocols, Decision Pressure, False Simplicity, Implicit Control Flow, Neglected Path Conditions, Neglected Updates, Oversized Predicates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/annotator/helpers/fixable_helpers.rb` -- 8 detectors across 35 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Path Conditions, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/annotator/domains/errors.rb` -- 8 detectors across 16 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Updates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/annotator/phases/expression_domains.rb` -- 8 detectors across 10 method(s): Broken Protocols, Decision Pressure, False Simplicity, Implicit Control Flow, Missing Abstractions, Neglected Updates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/annotator/helpers/generic_analysis.rb` -- 7 detectors across 21 method(s): Broken Protocols, Decision Pressure, False Simplicity, Neglected Path Conditions, Neglected Updates, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/annotator/helpers/reentrance.rb` -- 7 detectors across 18 method(s): Broken Protocols, Decision Pressure, False Simplicity, Missing Abstractions, Reification Misses, State-Based Branch Density, Weighted Inlined Cognitive Complexity
- `src/ast/symbol_entry.rb` -- 7 detectors across 17 method(s): Decision Pressure, Exact Predicate Aliases, False Simplicity, Neglected Updates, Semantic Predicate Aliases, State-Based Branch Density, Temporal Ordering Pressure

## Root-Cause Clusters (207)
_Findings across >=2 INDEPENDENT detectors that name the SAME entity -- 'N findings are really one invariant'. Convergence says where to look; this says **what one fix collapses the cluster**. Ranked candidate, not a verdict._

- **[name]** `enum` -- **4 detectors** [score 10] across 10 unit(s), 9 findings: Broken Protocols, Exact Predicate Aliases, Semantic Predicate Aliases, State-Based Branch Density
  - FIX: pair the protocol (RAII / ensure); the unpaired site is the deviant
  - `src/annotator/domains/control_flow.rb:661` (emit_missing_match_variants!) ; `src/annotator/domains/control_flow.rb:664` (emit_missing_match_variants!) ; `src/annotator/domains/control_flow.rb:666` (emit_missing_match_variants!) ; `src/annotator/domains/control_flow.rb:668` (emit_missing_match_variants!)
- **[name]** `union` -- **4 detectors** [score 10] across 10 unit(s), 17 findings: Exact Predicate Aliases, Neglected Path Conditions, Semantic Predicate Aliases, State-Based Branch Density
  - FIX: reify ONE named predicate/decision and call it everywhere
  - `src/annotator/domains/control_flow.rb:661` (emit_missing_match_variants!) ; `src/annotator/domains/control_flow.rb:664` (emit_missing_match_variants!) ; `src/annotator/domains/control_flow.rb:666` (emit_missing_match_variants!) ; `src/annotator/domains/control_flow.rb:668` (emit_missing_match_variants!)
- **[name]** `target` -- **4 detectors** [score 9] across 21 unit(s), 15 findings: Decision Pressure, Derived-State Staleness, Neglected Path Conditions, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/ast/scope.rb:409` (get_path_to_root) ; `src/ast/scope.rb:410` (get_path_to_root) ; `src/ast/scope.rb:412` (get_path_to_root) ; `src/ast/ast.rb:578` (inline_union_constructor_target?)
- **[name]** `matched_stdlib_def` -- **4 detectors** [score 9] across 14 unit(s), 12 findings: Decision Pressure, False Simplicity, Neglected Updates, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator/helpers/effects.rb:858` (func_call_suspends?) ; `src/annotator/phases/body_analysis.rb:328` (record_body_fact_node!) ; `src/annotator/helpers/capabilities.rb:484` (matched_stdlib_impurity_reason) ; `src/annotator/helpers/capabilities.rb:487` (matched_stdlib_impurity_reason)
- **[name]** `capabilities` -- **4 detectors** [score 9] across 8 unit(s), 8 findings: Decision Pressure, False Simplicity, Neglected Updates, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/ast/scope.rb:378` (is_restricted?) ; `src/ast/scope.rb:262` (clone_entry_for_scope) ; `src/ast/symbol_entry.rb:490` (initialize) ; `src/ast/type.rb:1085` (clear_zig_type_cache!)
- **[name]** `node` -- **4 detectors** [score 8] across 123 unit(s), 170 findings: Decision Pressure, Neglected Path Conditions, Oversized Predicates, State-Based Branch Density
  - FIX: tighten the contract once; the scattered defensive guards collapse (cross-proc -> nil-kill)
  - `src/annotator/helpers/function_analysis.rb:1262` (return_is_borrow?) ; `src/annotator/helpers/effects.rb:1180` (validate_tight_node!) ; `src/annotator/helpers/effects.rb:1191` (validate_tight_node!) ; `src/annotator/domains/lifetimes.rb:1165` (move_if_not_copyable!)
- **[name]** `value` -- **4 detectors** [score 8] across 35 unit(s), 24 findings: Decision Pressure, False Simplicity, Oversized Predicates, State-Based Branch Density
  - FIX: tighten the contract once; the scattered defensive guards collapse (cross-proc -> nil-kill)
  - `src/ast/ast.rb:494` (empty_auto_collection_literal_decl?) ; `src/ast/ast.rb:496` (empty_auto_collection_literal_decl?) ; `src/ast/ast.rb:498` (empty_auto_collection_literal_decl?) ; `src/ast/ast.rb:513` (declaration_with_identifier_value?)
- **[name]** `sync` -- **4 detectors** [score 8] across 18 unit(s), 11 findings: Decision Pressure, False Simplicity, Oversized Predicates, State-Based Branch Density
  - FIX: tighten the contract once; the scattered defensive guards collapse (cross-proc -> nil-kill)
  - `src/ast/symbol_entry.rb:211` (declared_sync_contract?) ; `src/ast/symbol_entry.rb:245` (with_match_capability_family?) ; `src/ast/symbol_entry.rb:250` (plain_local_family?) ; `src/ast/type.rb:1813` (any_sync?)
- **[name]** `type_params` -- **4 detectors** [score 8] across 18 unit(s), 27 findings: Decision Pressure, False Simplicity, Neglected Path Conditions, State-Based Branch Density
  - FIX: tighten the contract once; the scattered defensive guards collapse (cross-proc -> nil-kill)
  - `src/annotator/helpers/function_analysis.rb:419` (resolve_call) ; `src/annotator/helpers/function_signature.rb:298` (from_function_def) ; `src/annotator/helpers/function_signature.rb:624` (replace_import_mutable_state!) ; `src/annotator/domains/control_flow.rb:334` (literal_type_substitution!)
- **[name]** `observable_terminal` -- **4 detectors** [score 8] across 5 unit(s), 6 findings: Decision Pressure, False Simplicity, Oversized Predicates, State-Based Branch Density
  - FIX: tighten the contract once; the scattered defensive guards collapse (cross-proc -> nil-kill)
  - `src/ast/type.rb:2501` (observable_wrapper_zig) ; `src/ast/type.rb:1353` (apply_finalized_value_shape!) ; `src/ast/type.rb:1355` (apply_finalized_value_shape!) ; `src/ast/type.rb:1362` (apply_finalized_value_shape!)
- **[name]** `storage` -- **4 detectors** [score 7] across 62 unit(s), 106 findings: False Simplicity, Neglected Updates, Oversized Predicates, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator/domains/lifetimes.rb:1000` (bg_capture_independent?) ; `src/annotator/domains/lifetimes.rb:1003` (bg_capture_independent?) ; `src/annotator/domains/lifetimes.rb:1009` (bg_capture_independent?) ; `src/annotator/domains/lifetimes.rb:1012` (bg_capture_independent?)
- **[name]** `is_a` -- **4 detectors** [score 6] across 57 unit(s), 97 findings: Broken Protocols, Neglected Path Conditions, Oversized Predicates, State-Based Branch Density
  - FIX: pair the protocol (RAII / ensure); the unpaired site is the deviant
  - `src/annotator/domains/member_access.rb:25` (visit_GetIndex) ; `src/annotator/domains/member_access.rb:32` (visit_GetIndex) ; `src/annotator/domains/member_access.rb:34` (visit_GetIndex) ; `src/annotator/domains/member_access.rb:35` (visit_GetIndex)
- **[name]** `AST` -- **4 detectors** [score 6] across 42 unit(s), 79 findings: False Simplicity, Neglected Path Conditions, Oversized Predicates, State-Based Branch Density
  - FIX: converging structural debt -- resolve once at the named entity
  - `src/annotator/domains/member_access.rb:25` (visit_GetIndex) ; `src/annotator/domains/member_access.rb:32` (visit_GetIndex) ; `src/annotator/domains/member_access.rb:34` (visit_GetIndex) ; `src/annotator/domains/member_access.rb:35` (visit_GetIndex)
- **[name]** `wildcard` -- **3 detectors** [score 9] across 8 unit(s), 5 findings: Exact Predicate Aliases, Semantic Predicate Aliases, State-Based Branch Density
  - FIX: reify ONE named predicate/decision and call it everywhere
  - `src/annotator/domains/member_access.rb:75` (visit_GetField) ; `src/annotator/domains/member_access.rb:101` (visit_GetField) ; `src/annotator/domains/member_access.rb:119` (visit_GetField) ; `src/annotator/domains/member_access.rb:126` (visit_GetField)
- **[name]** `resource` -- **3 detectors** [score 9] across 7 unit(s), 6 findings: Exact Predicate Aliases, Semantic Predicate Aliases, State-Based Branch Density
  - FIX: reify ONE named predicate/decision and call it everywhere
  - `src/annotator/phases/expression_domains.rb:75` (visit_StaticCall) ; `src/annotator/phases/expression_domains.rb:84` (visit_StaticCall) ; `src/annotator/phases/expression_domains.rb:104` (visit_StaticCall) ; `src/annotator/phases/expression_domains.rb:127` (visit_StaticCall)
- **[name]** `val_node` -- **3 detectors** [score 8] across 3 unit(s), 4 findings: Decision Pressure, Derived-State Staleness, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `src/annotator/domains/lifetimes.rb:1210` (reject_borrowed_value!) ; `src/annotator/domains/lifetimes.rb:64` (ensure_owned_value!) ; `src/annotator/domains/lifetimes.rb:72` (ensure_owned_value!) ; `src/annotator/domains/lifetimes.rb:77` (ensure_owned_value!)
- **[name]** `name` -- **3 detectors** [score 7] across 45 unit(s), 37 findings: Decision Pressure, Oversized Predicates, State-Based Branch Density
  - FIX: tighten the contract once; the scattered defensive guards collapse (cross-proc -> nil-kill)
  - `src/ast/source_error.rb:51` (error!) ; `src/ast/source_error.rb:153` (fixable!) ; `src/ast/source_error.rb:163` (fixable!) ; `src/annotator/helpers/generic_analysis.rb:596` (register_container_borrow!)
- **[name]** `type` -- **3 detectors** [score 7] across 44 unit(s), 27 findings: Decision Pressure, False Simplicity, State-Based Branch Density
  - FIX: tighten the contract once; the scattered defensive guards collapse (cross-proc -> nil-kill)
  - `src/ast/symbol_entry.rb:256` (capture_move_required?) ; `src/ast/ast.rb:492` (empty_auto_collection_literal_decl?) ; `src/annotator/helpers/generic_analysis.rb:509` (validate_stream_type!) ; `src/annotator/helpers/generic_analysis.rb:561` (propagate_collection_metadata!)
- **[name]** `op` -- **3 detectors** [score 7] across 42 unit(s), 9 findings: Decision Pressure, False Simplicity, State-Based Branch Density
  - FIX: tighten the contract once; the scattered defensive guards collapse (cross-proc -> nil-kill)
  - `src/annotator/helpers/pipe_analysis.rb:1216` (auto_detect_sharded_access) ; `src/annotator/helpers/pipe_analysis.rb:1726` (validate_concurrent_where_expression!) ; `src/annotator/helpers/pipe_analysis.rb:1735` (concurrent_select_family_result_type) ; `src/annotator/helpers/pipe_analysis.rb:1738` (concurrent_select_family_result_type)
- **[name]** `current_fn_ctx` -- **3 detectors** [score 7] across 39 unit(s), 4 findings: Decision Pressure, False Simplicity, State-Based Branch Density
  - FIX: tighten the contract once; the scattered defensive guards collapse (cross-proc -> nil-kill)
  - `src/annotator/annotator.rb:358` (current_loop_depth) ; `src/annotator/annotator.rb:363` (current_conditional_depth) ; `src/annotator/helpers/generic_analysis.rb:99` (type_annotation_facts) ; `src/annotator/helpers/function_analysis.rb:163` (collect_routine_returns)
- ...(+187 more)

## Decision Pressure (135)
_ELIMINABLE guard-pressure per loose contract (nil/is_a?/respond_to?/safe-nav/rescue-nil) -> tighten the contract once / nil-kill: DELETE. essential dispatch + pure c-uses are split out, NEVER summed (Rapps-Weyuker p-use; McCabe)_

- `.value` -- ELIMINABLE guard-pressure **52** across 24 method(s) -> tighten contract / nil-kill: DELETE  (+2 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/ast/ast.rb:494` (empty_auto_collection_literal_decl?) ; `src/ast/ast.rb:496` (empty_auto_collection_literal_decl?) ; `src/ast/ast.rb:498` (empty_auto_collection_literal_decl?) ; `src/ast/ast.rb:513` (declaration_with_identifier_value?)
- `.current_fn_ctx` -- ELIMINABLE guard-pressure **40** across 38 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/annotator.rb:358` (current_loop_depth) ; `src/annotator/annotator.rb:363` (current_conditional_depth) ; `src/annotator/helpers/generic_analysis.rb:99` (type_annotation_facts) ; `src/annotator/helpers/function_analysis.rb:163` (collect_routine_returns)
- `.symbol` -- ELIMINABLE guard-pressure **34** across 24 method(s) -> tighten contract / nil-kill: DELETE  (+7 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/ast/ast.rb:519` (declaration_with_heap_symbol?) ; `src/annotator/helpers/function_analysis.rb:835` (atomic_cell_to_bare_value_param?) ; `src/annotator/helpers/function_analysis.rb:838` (atomic_cell_to_bare_value_param?) ; `src/annotator/helpers/function_analysis.rb:850` (atomic_cell_to_atomic_param?)
- `.target` -- ELIMINABLE guard-pressure **33** across 20 method(s) -> tighten contract / nil-kill: DELETE
  - `src/ast/scope.rb:409` (get_path_to_root) ; `src/ast/scope.rb:409` (get_path_to_root) ; `src/ast/scope.rb:410` (get_path_to_root) ; `src/ast/scope.rb:412` (get_path_to_root)
- `.right` -- ELIMINABLE guard-pressure **19** across 7 method(s) -> tighten contract / nil-kill: DELETE
  - `src/ast/ast.rb:505` (negative_integer_literal?) ; `src/annotator/helpers/pipe_analysis.rb:75` (visit_Smooth) ; `src/annotator/helpers/pipe_analysis.rb:77` (visit_Smooth) ; `src/annotator/helpers/pipe_analysis.rb:313` (analyze_select_family_op)
- `.type` -- ELIMINABLE guard-pressure **17** across 15 method(s) -> tighten contract / nil-kill: DELETE  (+28 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/ast/symbol_entry.rb:256` (capture_move_required?) ; `src/ast/ast.rb:492` (empty_auto_collection_literal_decl?) ; `src/annotator/helpers/generic_analysis.rb:509` (validate_stream_type!) ; `src/annotator/helpers/generic_analysis.rb:561` (propagate_collection_metadata!)
- `.type_params` -- ELIMINABLE guard-pressure **15** across 13 method(s) -> tighten contract / nil-kill: DELETE  (+1 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/helpers/function_analysis.rb:419` (resolve_call) ; `src/annotator/helpers/function_signature.rb:298` (from_function_def) ; `src/annotator/helpers/function_signature.rb:624` (replace_import_mutable_state!) ; `src/annotator/domains/control_flow.rb:334` (literal_type_substitution!)
- `.sync` -- ELIMINABLE guard-pressure **12** across 12 method(s) -> tighten contract / nil-kill: DELETE
  - `src/ast/symbol_entry.rb:211` (declared_sync_contract?) ; `src/ast/symbol_entry.rb:245` (with_match_capability_family?) ; `src/ast/symbol_entry.rb:250` (plain_local_family?) ; `src/ast/type.rb:1813` (any_sync?)
- `.name` -- ELIMINABLE guard-pressure **12** across 10 method(s) -> tighten contract / nil-kill: DELETE  (+1 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/ast/source_error.rb:51` (error!) ; `src/ast/source_error.rb:153` (fixable!) ; `src/ast/source_error.rb:163` (fixable!) ; `src/annotator/helpers/generic_analysis.rb:596` (register_container_borrow!)
- `.element_type` -- ELIMINABLE guard-pressure **11** across 8 method(s) -> tighten contract / nil-kill: DELETE  (+3 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/ast/type.rb:1992` (fsm_foreach_descriptor) ; `src/ast/type.rb:2002` (fsm_foreach_descriptor) ; `src/ast/type.rb:2005` (fsm_foreach_descriptor) ; `src/ast/type.rb:2008` (fsm_foreach_descriptor)
- `.reg` -- ELIMINABLE guard-pressure **11** across 7 method(s) -> tighten contract / nil-kill: DELETE
  - `src/ast/ast.rb:443` (declaration_symbol) ; `src/annotator/helpers/function_analysis.rb:1268` (return_is_borrow?) ; `src/annotator/helpers/fixable_helpers.rb:1062` (emit_with_materialized_needs_tense!) ; `src/annotator/helpers/fixable_helpers.rb:1276` (build_decl_cap_insert_fix)
- `.left` -- ELIMINABLE guard-pressure **7** across 6 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/helpers/pipe_analysis.rb:118` (stamp_observable_terminal!) ; `src/annotator/helpers/pipe_analysis.rb:124` (stamp_observable_terminal!) ; `src/annotator/helpers/pipe_analysis.rb:288` (analyze_collect_op) ; `src/annotator/helpers/pipe_analysis.rb:1412` (queue_backed_concurrent_source?)
- `.raw` -- ELIMINABLE guard-pressure **7** across 5 method(s) -> tighten contract / nil-kill: DELETE
  - `src/ast/type.rb:336` (fn_type?) ; `src/ast/type.rb:1492` (generic_type_parameter?) ; `src/ast/type.rb:3205` (accepts_fn_type?) ; `src/annotator/helpers/pipe_analysis.rb:771` (analyze_pipe_to_identifier)
- `.expr` -- ELIMINABLE guard-pressure **7** across 3 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/domains/control_flow.rb:168` (visit_IfBind) ; `src/annotator/domains/control_flow.rb:406` (consume_match_subject_if_takes!) ; `src/annotator/domains/execution_boundaries.rb:855` (visit_NextExpr) ; `src/annotator/domains/execution_boundaries.rb:858` (visit_NextExpr)
- `@parent` -- ELIMINABLE guard-pressure **6** across 6 method(s) -> tighten contract / nil-kill: DELETE
  - `src/ast/scope.rb:201` (resolve_type_entry) ; `src/ast/scope.rb:222` (resolve_entry) ; `src/ast/scope.rb:237` (entry?) ; `src/ast/scope.rb:245` (entry_for_write)
- `.default` -- ELIMINABLE guard-pressure **6** across 6 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/helpers/function_analysis.rb:179` (build_lambda_signature) ; `src/annotator/helpers/function_analysis.rb:228` (visit_FunctionDef) ; `src/annotator/helpers/function_analysis.rb:576` (default_argument_for) ; `src/annotator/helpers/function_analysis.rb:1015` (declare_and_verify_params)
- `[name]` -- ELIMINABLE guard-pressure **5** across 5 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/helpers/test_annotation.rb:188` (validate_strict_io!) ; `src/annotator/function_registry.rb:73` (fnptr_call?) ; `src/annotator/function_registry.rb:78` (raises_directly?) ; `src/annotator/domains/control_flow.rb:918` (captured_move_consumed_by_loop?)
- `[node.name]` -- ELIMINABLE guard-pressure **5** across 4 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/helpers/function_analysis.rb:1262` (return_is_borrow?) ; `src/annotator/helpers/effects.rb:1180` (validate_tight_node!) ; `src/annotator/helpers/effects.rb:1191` (validate_tight_node!) ; `src/annotator/domains/lifetimes.rb:1165` (move_if_not_copyable!)
- `.arg_node` -- ELIMINABLE guard-pressure **5** across 3 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/helpers/function_analysis.rb:618` (verify_mutable_argument!) ; `src/annotator/helpers/function_analysis.rb:742` (verify_atomic_argument!) ; `src/annotator/helpers/function_analysis.rb:747` (verify_atomic_argument!) ; `src/annotator/helpers/function_analysis.rb:751` (verify_atomic_argument!)
- `.move_consumer_param_type` -- ELIMINABLE guard-pressure **5** across 3 method(s) -> tighten contract / nil-kill: DELETE  (+2 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/helpers/fixable_helpers.rb:312` (emit_use_of_moved_error!) ; `src/annotator/helpers/fixable_helpers.rb:313` (emit_use_of_moved_error!) ; `src/annotator/helpers/fixable_helpers.rb:314` (emit_use_of_moved_error!) ; `src/annotator/domains/lifetimes.rb:1172` (move_if_not_copyable!)
- `[variant_name]` -- ELIMINABLE guard-pressure **5** across 3 method(s) -> tighten contract / nil-kill: DELETE  (+1 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/domains/control_flow.rb:529` (declare_union_payload_binding!) ; `src/annotator/domains/control_flow.rb:590` (match_payload_struct_schema) ; `src/annotator/domains/member_access.rb:304` (visit_StructLit) ; `src/annotator/domains/member_access.rb:312` (visit_StructLit)
- `.payload_type` -- ELIMINABLE guard-pressure **5** across 2 method(s) -> tighten contract / nil-kill: DELETE  (+2 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/ast/type.rb:3696` (integer_range_target_type) ; `src/ast/type.rb:3697` (integer_range_target_type) ; `src/ast/type.rb:3701` (integer_range_target_type) ; `src/ast/type.rb:3702` (integer_range_target_type)
- `.tense_type` -- ELIMINABLE guard-pressure **4** across 4 method(s) -> tighten contract / nil-kill: DELETE  (+10 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/ast/type.rb:2200` (list_requires_array_shape?) ; `src/ast/type.rb:2205` (observable_array_without_set?) ; `src/annotator/helpers/generic_analysis.rb:105` (type_annotation_facts) ; `src/annotator/helpers/pipe_analysis.rb:294` (analyze_collect_op)
- `.object` -- ELIMINABLE guard-pressure **4** across 4 method(s) -> tighten contract / nil-kill: DELETE
  - `src/annotator/helpers/function_analysis.rb:491` (receiver_container_alloc) ; `src/annotator/helpers/auto_inference.rb:792` (record_method_call) ; `src/annotator/helpers/method_analysis.rb:158` (narrow_receiver_collection!) ; `src/annotator/domains/control_flow.rb:858` (visit_WhileBindLoop)
- `.first` -- ELIMINABLE guard-pressure **4** across 4 method(s) -> tighten contract / nil-kill: DELETE  (+4 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `src/annotator/helpers/lock_helper.rb:460` (report_lock_cycle!) ; `src/annotator/domains/lifetimes.rb:1056` (get_lifetime_path) ; `src/annotator/domains/member_access.rb:546` (infer_element_type) ; `src/annotator/domains/member_access.rb:557` (infer_optional_element_type)
- ...(+110 more)

## Redundant Nil Guards (0)
_nil checks / safe-nav dominated by an earlier non-nil proof -- delete repeated control flow or tighten the type_

None.

## State Heatmap (250)
_state fields ranked by write/read/re-derivation scatter -- tangled mutable state should get one owner_

- `all` -- messiness **150.0** (writes=2, reads=11, re-derived=2, scatter=10, receiver patterns=4)
  - writers: `src/ast/diagnostic_examples.rb:64` (all) ; `src/ast/diagnostic_examples.rb:65` (all)
  - readers: `src/ast/diagnostic_examples.rb:64` (all) ; `src/ast/diagnostic_examples.rb:65` (all) ; `src/annotator/helpers/with_match_check.rb:171` (collect_bound_param_names) ; `src/annotator/helpers/capabilities.rb:514` (validate_and_visit_with_guards!)
- `alloc` -- messiness **70.0** (writes=6, reads=4, re-derived=0, scatter=7, receiver patterns=6)
  - writers: `src/ast/ast.rb:2245` (alloc=) ; `src/ast/ast.rb:2247` (alloc) ; `src/annotator/helpers/function_analysis.rb:644` (verify_takes_argument!) ; `src/annotator/helpers/function_signature.rb:579` (with_intrinsic_override)
  - readers: `src/ast/type.rb:1716` (provenance_alloc) ; `src/ast/ast.rb:2247` (alloc) ; `src/ast/ast.rb:2247` (alloc) ; `src/annotator/helpers/intrinsic_contract.rb:126` (from_emit)
- `alloc_count` -- messiness **4.0** (writes=1, reads=1, re-derived=0, scatter=2, receiver patterns=2)
  - writers: `src/annotator/helpers/function_context.rb:94` (initialize)
  - readers: `src/annotator/helpers/function_analysis.rb:292` (visit_FunctionDef)
- `alloc_fault` -- messiness **20.0** (writes=3, reads=2, re-derived=0, scatter=4, receiver patterns=3)
  - writers: `src/annotator/helpers/function_signature.rb:456` (mark_faulting_allocation!) ; `src/annotator/helpers/function_signature.rb:675` (sync_from_function_def!) ; `src/annotator/helpers/effects.rb:645` (compute_can_fail!)
  - readers: `src/annotator/helpers/function_signature.rb:189` (alloc_fault) ; `src/annotator/helpers/function_signature.rb:675` (sync_from_function_def!)
- `arg_families` -- messiness **1.0** (writes=1, reads=0, re-derived=0, scatter=1, receiver patterns=1)
  - writers: `src/annotator/phases/expression_domains.rb:202` (record_named_call_site!)
- `as_type` -- messiness **24.0** (writes=2, reads=4, re-derived=0, scatter=4, receiver patterns=3)
  - writers: `src/ast/schemas.rb:137` (initialize) ; `src/ast/schemas.rb:308` (initialize)
  - readers: `src/annotator/phases/import_resolution.rb:89` (clone_struct_schema) ; `src/annotator/phases/import_resolution.rb:102` (clone_resource_schema) ; `src/annotator/phases/type_registration.rb:43` (register_extern_struct_declaration) ; `src/annotator/phases/type_registration.rb:50` (register_extern_struct_declaration)
- `async_result_shape` -- messiness **12.0** (writes=3, reads=1, re-derived=0, scatter=3, receiver patterns=4)
  - writers: `src/annotator/helpers/generic_analysis.rb:545` (propagate_declared_type_to_value!) ; `src/annotator/domains/execution_boundaries.rb:746` (visit_BgBlock) ; `src/annotator/domains/variables.rb:156` (finalize_decl_node!)
  - readers: `src/annotator/domains/variables.rb:156` (finalize_decl_node!)
- `atomic_borrow` -- messiness **2.0** (writes=2, reads=0, re-derived=0, scatter=1, receiver patterns=1)
  - writers: `src/annotator/helpers/function_analysis.rb:747` (verify_atomic_argument!) ; `src/annotator/helpers/function_analysis.rb:751` (verify_atomic_argument!)
- `auto_atomic_op` -- messiness **1.0** (writes=1, reads=0, re-derived=0, scatter=1, receiver patterns=1)
  - writers: `src/annotator/domains/variables.rb:373` (stamp_atomic_bind_assignment!)
- `auto_lock` -- messiness **1.0** (writes=1, reads=0, re-derived=0, scatter=1, receiver patterns=1)
  - writers: `src/annotator/domains/variables.rb:752` (visit_assignment_field)
- `auto_locked_assign_name` -- messiness **8.0** (writes=2, reads=2, re-derived=0, scatter=2, receiver patterns=1)
  - writers: `src/annotator/domains/variables.rb:618` (visit_Assignment) ; `src/annotator/domains/variables.rb:622` (visit_Assignment)
  - readers: `src/annotator/domains/member_access.rb:194` (emit_capability_field_access_error_if_needed!) ; `src/annotator/domains/variables.rb:604` (visit_Assignment)
- `auto_token` -- messiness **54.0** (writes=2, reads=7, re-derived=0, scatter=6, receiver patterns=6)
  - writers: `src/ast/type.rb:782` (initialize) ; `src/ast/type.rb:790` (initialize)
  - readers: `src/ast/type.rb:790` (initialize) ; `src/annotator/helpers/auto_inference.rb:190` (register_signature_slots) ; `src/annotator/helpers/auto_inference.rb:197` (register_signature_slots) ; `src/annotator/helpers/auto_inference.rb:312` (record_local)
- `binding_id` -- messiness **1.0** (writes=1, reads=0, re-derived=0, scatter=1, receiver patterns=1)
  - writers: `src/ast/symbol_entry.rb:473` (initialize)
- `bindings` -- messiness **288.0** (writes=2, reads=16, re-derived=0, scatter=16, receiver patterns=2)
  - writers: `src/ast/scope.rb:108` (initialize) ; `src/ast/scope.rb:162` (initialize_copy)
  - readers: `src/ast/scope.rb:136` (declare) ; `src/ast/scope.rb:144` (install_entry) ; `src/ast/scope.rb:212` (local_entry) ; `src/ast/scope.rb:222` (resolve_entry)
- `body` -- messiness **1872.0** (writes=5, reads=47, re-derived=0, scatter=36, receiver patterns=18)
  - writers: `src/ast/ast.rb:23` (initialize) ; `src/ast/ast.rb:29` (replace) ; `src/ast/ast.rb:626` (body_slots) ; `src/ast/ast.rb:628` (body_slots)
  - readers: `src/ast/ast.rb:626` (body_slots) ; `src/ast/ast.rb:626` (body_slots) ; `src/ast/ast.rb:628` (body_slots) ; `src/ast/ast.rb:628` (body_slots)
- `borrowed_alias` -- messiness **4.0** (writes=1, reads=1, re-derived=0, scatter=2, receiver patterns=1)
  - writers: `src/ast/symbol_entry.rb:423` (mark_borrowed_alias!)
  - readers: `src/ast/symbol_entry.rb:444` (flow_snapshot)
- `borrowed_field_names` -- messiness **1.0** (writes=1, reads=0, re-derived=0, scatter=1, receiver patterns=1)
  - writers: `src/annotator/domains/member_access.rb:416` (visit_StructLit)
- `branch_terminated` -- messiness **45.0** (writes=7, reads=2, re-derived=0, scatter=5, receiver patterns=1)
  - writers: `src/annotator/annotator.rb:534` (initialize) ; `src/annotator/annotator.rb:568` (reset_compilation_state!) ; `src/annotator/domains/control_flow.rb:88` (analyze_control_flow_branch) ; `src/annotator/domains/control_flow.rb:106` (analyze_control_flow_branch)
  - readers: `src/annotator/domains/control_flow.rb:87` (analyze_control_flow_branch) ; `src/annotator/domains/control_flow.rb:99` (analyze_control_flow_branch)
- `bubble_types` -- messiness **4.0** (writes=1, reads=1, re-derived=0, scatter=2, receiver patterns=1)
  - writers: `src/annotator/domains/execution_boundaries.rb:624` (resolve_error_selectors!)
  - readers: `src/annotator/phases/body_analysis.rb:425` (with_block_raises_directly?)
- `can_fail` -- messiness **299.0** (writes=8, reads=15, re-derived=0, scatter=13, receiver patterns=10)
  - writers: `src/annotator/helpers/function_signature.rb:455` (mark_faulting_allocation!) ; `src/annotator/helpers/function_signature.rb:674` (sync_from_function_def!) ; `src/annotator/helpers/effects.rb:646` (compute_can_fail!) ; `src/annotator/helpers/effects.rb:775` (mark_fn_value_references!)
  - readers: `src/annotator/helpers/function_signature.rb:186` (can_fail) ; `src/annotator/helpers/function_signature.rb:674` (sync_from_function_def!) ; `src/annotator/helpers/effects.rb:539` (compute_can_fail!) ; `src/annotator/helpers/capabilities.rb:474` (call_declared_impurity_reason)
- `capabilities` -- messiness **704.0** (writes=10, reads=22, re-derived=0, scatter=22, receiver patterns=6)
  - writers: `src/ast/symbol_entry.rb:490` (initialize) ; `src/ast/type.rb:779` (initialize) ; `src/ast/type.rb:788` (initialize) ; `src/ast/type.rb:1065` (apply_capabilities!)
  - readers: `src/ast/type.rb:788` (initialize) ; `src/ast/type.rb:880` (ownership) ; `src/ast/type.rb:891` (sync) ; `src/ast/type.rb:902` (layout)
- `capability_plan` -- messiness **1.0** (writes=1, reads=0, re-derived=0, scatter=1, receiver patterns=1)
  - writers: `src/annotator/domains/execution_boundaries.rb:26` (visit_WithBlock)
- `capture_analysis` -- messiness **165.0** (writes=8, reads=7, re-derived=0, scatter=11, receiver patterns=7)
  - writers: `src/annotator/helpers/pipe_analysis.rb:1457` (analyze_concurrent_op) ; `src/annotator/helpers/pipe_analysis.rb:1656` (analyze_concurrent_bounded_select_family_op) ; `src/annotator/helpers/pipe_analysis.rb:1684` (analyze_concurrent_bounded_each_op) ; `src/annotator/helpers/pipe_analysis.rb:1710` (analyze_concurrent_stream_select_family_op)
  - readers: `src/ast/ast.rb:825` (each_capture_analysis) ; `src/ast/ast.rb:825` (each_capture_analysis) ; `src/ast/ast.rb:830` (each_capture_analysis) ; `src/ast/ast.rb:830` (each_capture_analysis)
- `captured_bg` -- messiness **4.0** (writes=1, reads=1, re-derived=0, scatter=2, receiver patterns=2)
  - writers: `src/annotator/helpers/capabilities.rb:1320` (mark_captured!)
  - readers: `src/annotator/helpers/capabilities.rb:1411` (finalize_capability_audit!)
- `captured_parallel` -- messiness **4.0** (writes=1, reads=1, re-derived=0, scatter=2, receiver patterns=2)
  - writers: `src/annotator/helpers/capabilities.rb:1321` (mark_captured!)
  - readers: `src/annotator/helpers/capabilities.rb:1406` (finalize_capability_audit!)
- ...(+225 more)

## State-Based Branch Density (539)
_branch decisions over mutable/object state -- state + control-flow pressure_

- `src/ast/ast.rb:196` (initialize) -- **21** state-based branch decision(s), refs=`rt.nil? | self[:bindings].nil? | self[:body].nil? | self[:borrowed].nil? | self[:capabilities].nil? | self[:cases].nil? | self[:extra_values].nil? | self[:fields].nil?` score=378
  - example predicate: `self[:body].nil?`
- `src/annotator/domains/execution_boundaries.rb:848` (visit_NextExpr) -- **15** state-based branch decision(s), refs=`async_shape.payload_type | async_shape.promise? | async_shape.shared_promise? | node.expr | promise_type.bounded_stream? | promise_type.dynamic_stream? | promise_type.future? | promise_type.inf_stream?` score=195
  - example predicate: `promise_type.future?`
- `src/annotator/domains/errors.rb:375` (visit_ReturnNode) -- **13** state-based branch decision(s), refs=`expected.heap_return_storage? | expected.plain_return_payload_type | inline_bg_sources.any? | node.value | node.value.full_type!(context: "return expression storage").requires_move? | node.value.nil? | val.symbol | val.symbol.non_escaping` score=169
  - example predicate: `node.value.nil?`
- `src/annotator/domains/lifetimes.rb:536` (finalize_scope) -- **15** state-based branch decision(s), refs=`branch.nil? | info.mutable | info.mutated | info.ownership_kind | info.read | info.reg | info.reg.var_mutated | info.reg.var_used` score=150
  - example predicate: `ownership_graph.live?(name) || (is_takes && ownership_graph[name]&.moved?)`
- `src/annotator/domains/execution_boundaries.rb:750` (visit_BgBlock) -- **12** state-based branch decision(s), refs=`analysis.has_affine_locked | analysis.has_local | analysis.has_sharded | analysis_result.has_local | analysis_result.has_non_escaping_capture | analysis_result.has_outer_ref | analysis_result.has_rc | analysis_result.has_shared` score=132
  - example predicate: `node.arena_mode`
- `src/annotator/helpers/function_analysis.rb:216` (visit_FunctionDef) -- **13** state-based branch decision(s), refs=`candidate_snap_types.size | catch_body_scan.references_snapshot | fn_type_params.any? | node.name | node.reentrance_kind | node.return_type | node.tail_call | p.type` score=117
  - example predicate: `has_mutable_param && !node.name.end_with?("!")`
- `src/annotator/domains/expressions.rb:257` (visit_CapabilityWrap) -- **10** state-based branch decision(s), refs=`node.atomic? | node.atomic_ptr? | node.capability? | node.indirect? | node.layout | node.lock_rank | node.locked_sync? | node.multiowned?` score=110
  - example predicate: `ti.primitive? && node.atomic_ptr?`
- `src/annotator/domains/member_access.rb:266` (visit_StructLit) -- **10** state-based branch decision(s), refs=`field_names.empty? | missing.any? | node.fields | node.fields.empty? | node.fields.length | raw_expected.nil? | schema.borrowed_fields | schema.borrowed_fields.any?` score=110
  - example predicate: `schema.nil?`
- `src/annotator/domains/variables.rb:82` (finalize_decl_node!) -- **10** state-based branch decision(s), refs=`cap_tok.value | final_type.collection | fixes.any? | node.type | node.value | node_type.collection | node_type.observable? | node_type.ownership` score=110
  - example predicate: `node.type`
- `src/annotator/helpers/capabilities.rb:154` (validate_capability_transition!) -- **11** state-based branch decision(s), refs=`T.must(var_node.symbol).mutable | fact.capability | fact.deferred_sync_param? | fact.exclusive_validation_action | fact.storage | fact.write_locked_sync? | t.future? | t.observable?` score=99
  - example predicate: `valid_capability_target?(fact.capability, var_node)`
- `src/annotator/helpers/function_analysis.rb:368` (resolve_call) -- **11** state-based branch decision(s), refs=`arg.full_type!(context: "extern argument").soa? | call_type.error_union? | comptime_type_args.any? | entry.storage | node.args | p.comptime | signature.extern | signature.module_alias` score=99
  - example predicate: `args.equal?(node.args)`
- `src/annotator/helpers/function_analysis.rb:1014` (declare_and_verify_params) -- **10** state-based branch decision(s), refs=`fams.empty? | field_names.empty? | missing.any? | param.default | param.sync | param.takes | param.type | param.type.any_sync?` score=90
  - example predicate: `param.default`
- `src/annotator/domains/member_access.rb:25` (visit_GetIndex) -- **8** state-based branch decision(s), refs=`index_type_info.numeric? | index_type_info.string? | node.target | node.target.metatype | result_type.optional? | target_type_info.map? | target_type_info.numeric_map? | target_type_info.promise_list?` score=80
  - example predicate: `node.target.is_a?(AST::OptionalUnwrap) && !result_type.optional?`
- `src/ast/type.rb:1509` (accepts?) -- **8** state-based branch decision(s), refs=`other_type.any? | other_type.byte? | other_type.error_union? | other_type.map? | other_type.numeric? | other_type.optional? | other_type.resolved | other_type.string?` score=80
  - example predicate: `self == other_type || any? || other_type.any?`
- `src/ast/type.rb:3259` (accepts_array?) -- **7** state-based branch decision(s), refs=`T.must(element_type).any? | other_type.array? | other_type.bounded_stream? | other_type.dynamic_stream? | other_type.element_type | other_type.empty_list? | other_type.fixed? | other_type.future?` score=77
  - example predicate: `T.must(element_type).any? && other_type.future?`
- `src/ast/std_lib.rb:1032` ((top-level)) -- **11** state-based branch decision(s), refs=`arg_type.numeric? | arg_type.string? | elem.resolved | key_type.numeric? | key_type.string? | obj_type.numeric_map?` score=66
  - example predicate: `arg_type == :Any || arg_type == elem.resolved || Type.new(elem.resolved).accepts?(Type.new(arg_type))`
- `src/annotator/domains/errors.rb:583` (visit_OrRescue) -- **13** state-based branch decision(s), refs=`node.left | node.left.error_union_type | node.right | t_left_type.error_union? | t_left_type.optional?` score=65
  - example predicate: `node.left.respond_to?(:error_union_type) && node.left.error_union_type`
- `src/annotator/domains/member_access.rb:433` (visit_ListLit) -- **7** state-based branch decision(s), refs=`Type.new(i.resolved_type).future? | Type.new(i.resolved_type).string? | i.resolved_type | inner_types.size | item.resolved_type | node.items | node.items.all? | node.items.empty?` score=63
  - example predicate: `!node.items.empty? && node.items.all? { |i| Type.new(i.resolved_type).future? }`
- `src/annotator/domains/expressions.rb:364` (promote_to_expr_if!) -- **6** state-based branch decision(s), refs=`else_result.string? | if_node.else_branch | if_node.else_branch.empty? | if_node.else_branch.first | if_node.else_branch.length | if_node.else_branch.nil? | result_type.implicitly_copyable? | result_type.string?` score=60
  - example predicate: `if_node.else_branch&.length == 1 && (nested = if_node.else_branch.first).is_a?(AST::IfStatement)`
- `src/annotator/helpers/reentrance.rb:539` (emit_mutual_thunk_unsupported!) -- **8** state-based branch decision(s), refs=`cycle_thunk_fns.length | edits_plain.empty? | edits_plain.length | eff.empty? | fixes.empty? | rt.error_union? | rt_tok.nil?` score=56
  - example predicate: `edits_plain.length == cycle_thunk_fns.length && !edits_plain.empty?`
- `src/annotator/domains/variables.rb:34` (promote_pipe_to_observable_dest!) -- **7** state-based branch decision(s), refs=`node.type | node.value | pipe.observable_terminal | pipe.smooth? | pipe_type.observable_terminal | target.future? | target.observable? | target_t.observable_terminal` score=56
  - example predicate: `node.respond_to?(:type) && node.type`
- `src/annotator/phases/body_analysis.rb:323` (record_body_fact_node!) -- **7** state-based branch decision(s), refs=`frame.failure_absorbed | frame.record_call_sites | frames.empty? | node.fn_var_call | node.matched_stdlib_def | node.matched_stdlib_def.intrinsic_suspends? | node.mode | node.name` score=56
  - example predicate: `frames.empty?`
- `src/annotator/phases/expression_domains.rb:145` (visit_IntrinsicFunc) -- **7** state-based branch decision(s), refs=`args.first | matched_def.can_fail | matched_def.intrinsic_error_kind | matched_def.intrinsic_error_type | matched_def.intrinsic_suspends? | matched_def.intrinsic_varargs? | matched_def.mutates_receiver? | matched_def.needs_rt` score=56
  - example predicate: `matched_def.intrinsic_varargs?`
- `src/annotator/domains/member_access.rb:75` (visit_GetField) -- **6** state-based branch decision(s), refs=`field_type.indirect? | field_type.optional? | node.target | node.target.name | node.token | node.wildcard? | phase_receiver_state.pipeline_accessed_fields | struct_schema.type_params` score=54
  - example predicate: `node.wildcard?`
- `src/annotator/domains/variables.rb:468` (classify_ownership!) -- **6** state-based branch decision(s), refs=`entry.rc_stored? | entry.resource | entry.sync | entry.takes | type_obj.collection? | type_obj.fn_type? | type_obj.implicitly_copyable? | type_obj.multiowned?` score=54
  - example predicate: `type_obj.fn_type?`
- ...(+514 more)

## Temporal Ordering Pressure (4)
_public mutable lifecycle surfaces that create implicit state-machine ordering_

- `SymbolEntry` (`src/ast/symbol_entry.rb:147` (SymbolEntry)) -- implicit lifecycle score **4288** (public=50, state methods=16, writers=3, fields=13, shared=4, flows=16!, states=2^13)
  - shared fields: `@flow | @lifecycle | @lifetime | @reg`
  - surface: `src/ast/symbol_entry.rb:147` (lifetime=) ; `src/ast/symbol_entry.rb:375` (invalidate!) ; `src/ast/symbol_entry.rb:381` (mark_read!) ; `src/ast/symbol_entry.rb:387` (mark_mutated!) ; `src/ast/symbol_entry.rb:393` (mark_mutated_via_reference!) ; `src/ast/symbol_entry.rb:399` (mark_poly_borrow_target!)
- `Type` (`src/ast/type.rb:777` (Type)) -- implicit lifecycle score **1637** (public=235, state methods=25, writers=9, fields=9, shared=5, flows=25!, states=2^9)
  - shared fields: `@capabilities | @generic_payload_type_arg | @is_resource | @placement | @zig_type_cache`
  - surface: `src/ast/type.rb:777` (initialize) ; `src/ast/type.rb:879` (ownership) ; `src/ast/type.rb:890` (sync) ; `src/ast/type.rb:901` (layout) ; `src/ast/type.rb:912` (lock_rank) ; `src/ast/type.rb:923` (collection)
- `SemanticAnnotator` (`src/annotator/annotator.rb:159` (SemanticAnnotator)) -- implicit lifecycle score **792** (public=44, state methods=35, writers=2, fields=9, shared=4, flows=35!, states=2^9)
  - shared fields: `@function_registry | @program | @receiver_state | @semantic_index`
  - surface: `src/annotator/annotator.rb:159` (semantic_function_registry) ; `src/annotator/annotator.rb:169` (phase_receiver_state) ; `src/annotator/annotator.rb:175` (ownership_graph) ; `src/annotator/annotator.rb:191` (scope_stack) ; `src/annotator/annotator.rb:196` (semantic_root_scope) ; `src/annotator/annotator.rb:201` (semantic_program)
- `Scope` (`src/ast/scope.rb:106` (Scope)) -- implicit lifecycle score **394** (public=33, state methods=19, writers=2, fields=7, shared=7, flows=19!, states=2^7)
  - shared fields: `@bindings | @dependencies | @depth | @owned_names | @parent | @type_store | @types`
  - surface: `src/ast/scope.rb:106` (initialize) ; `src/ast/scope.rb:117` (declare) ; `src/ast/scope.rb:140` (install_entry) ; `src/ast/scope.rb:158` (initialize_copy) ; `src/ast/scope.rb:189` (install_type) ; `src/ast/scope.rb:200` (resolve_type_entry)

## Missing Abstractions (28)
_guard tuple recomputed across >=2 decision units_

- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `atomic? | indirect?`
  - `src/ast/symbol_entry.rb:189` (atomic_ptr?) ; `src/ast/type.rb:1792` (atomic_ptr?) ; `src/ast/ast.rb:2214` (atomic_ptr?)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `!shard_count | source.shard_count`
  - `src/ast/type.rb:1308` (copy_collection_shape_from!) ; `src/ast/type.rb:1316` (copy_topology_from!) ; `src/ast/type.rb:1326` (copy_declared_collection_modifiers_from!)
- **[case_dispatch]** support=3 scatter=3 rank=9
  - tuple: `AST::GetField | AST::GetIndex | AST::Identifier`
  - `src/ast/ast.rb:433` (root_identifier) ; `src/annotator/helpers/capabilities.rb:140` (cap_var_label) ; `src/annotator/domains/variables.rb:631` (visit_Assignment)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `slot.respond_to?(:shape) | slot.shape`
  - `src/annotator/annotator.rb:666` (emit_auto_shape_resolved_findings!) ; `src/annotator/helpers/fixable_helpers.rb:1574` (emit_auto_resolved_finding!) ; `src/annotator/helpers/fixable_helpers.rb:1742` (auto_slot_label)
- **[case_dispatch]** support=3 scatter=3 rank=9
  - tuple: `:kind | :type`
  - `src/annotator/helpers/with_match_check.rb:424` (handled_error_set) ; `src/annotator/helpers/lock_helper.rb:425` (verify_handler_reachability!) ; `src/annotator/domains/execution_boundaries.rb:587` (resolve_error_selectors!)
- **[case_dispatch]** support=3 scatter=3 rank=9
  - tuple: `:local | :param | :return`
  - `src/annotator/helpers/auto_inference.rb:633` (stamp_slot!) ; `src/annotator/helpers/fixable_helpers.rb:1708` (slot_id_for) ; `src/annotator/helpers/fixable_helpers.rb:1751` (auto_slot_label)
- **[conjunction]** support=3 scatter=3 rank=9
  - tuple: `!direct | reachable_from_self?(name)`
  - `src/annotator/helpers/reentrance.rb:369` (validate_not_logical_recursion!) ; `src/annotator/helpers/reentrance.rb:398` (validate_max_depth_mutual_cycle!) ; `src/annotator/helpers/reentrance.rb:438` (validate_thunk_recursion!)
- **[conjunction]** support=2 scatter=2 rank=4
  - tuple: `left_type.numeric? | right_type.numeric?`
  - `src/ast/type.rb:636` (scalar_comparable?) ; `src/ast/type.rb:686` (resolve_numeric_op)
- **[conjunction]** support=2 scatter=2 rank=4
  - tuple: `!soa? | source.soa?`
  - `src/ast/type.rb:1309` (copy_collection_shape_from!) ; `src/ast/type.rb:1317` (copy_topology_from!)
- **[conjunction]** support=2 scatter=2 rank=4
  - tuple: `generic_instance? | schema.nil?`
  - `src/ast/type.rb:2786` (bg_capture_is_value_copy?) ; `src/ast/type.rb:2814` (implicitly_copyable?)
- **[conjunction]** support=2 scatter=2 rank=4
  - tuple: `map? | striped?`
  - `src/ast/type.rb:3413` (capability_wrapped_zig_type) ; `src/ast/type.rb:3421` (capability_inner_zig_type)
- **[case_dispatch]** support=2 scatter=2 rank=4
  - tuple: `Array | Hash | Struct`
  - `src/ast/ast.rb:415` (each_locatable) ; `src/annotator/domains/lifetimes.rb:952` (collect_bg_sources_walk)
- **[case_dispatch]** support=2 scatter=2 rank=4
  - tuple: `BgBlock | BgStreamBlock | BinaryOp | FuncCall | HashLit | ListLit | MethodCall | StructLit | UnionVariantLit`
  - `src/ast/ast.rb:746` (_expr_each_bg_block_recursive) ; `src/ast/ast.rb:793` (_expr_each_bg_block_shallow)
- **[conjunction]** support=2 scatter=2 rank=4
  - tuple: `alloc_kind | fn_ctx`
  - `src/annotator/helpers/function_analysis.rb:388` (resolve_call) ; `src/annotator/phases/expression_domains.rb:253` (record_extern_method_alloc!)
- **[conjunction]** support=2 scatter=2 rank=4
  - tuple: `has_catch_blocks? | result_type`
  - `src/annotator/helpers/pipe_analysis.rb:755` (analyze_pipe_to_func_call) ; `src/annotator/helpers/pipe_analysis.rb:816` (analyze_pipe_to_named_function)
- **[case_dispatch]** support=2 scatter=2 rank=4
  - tuple: `:list_element | :map_key | :map_value`
  - `src/annotator/helpers/auto_inference.rb:620` (stamp_slot!) ; `src/annotator/helpers/fixable_helpers.rb:1744` (auto_slot_label)
- **[case_dispatch]** support=2 scatter=2 rank=4
  - tuple: `AST::BindExpr | AST::FunctionDef | AST::VarDecl | Array | Hash`
  - `src/annotator/helpers/auto_inference.rb:743` (walk_for_shape_decls) ; `src/annotator/helpers/auto_inference.rb:898` (walk_for_local_decls)
- **[conjunction]** support=2 scatter=2 rank=4
  - tuple: `slots.key | slots.value`
  - `src/annotator/helpers/auto_inference.rb:809` (record_map_pair_evidence) ; `src/annotator/helpers/auto_inference.rb:827` (record_index_assign)
- **[conjunction]** support=2 scatter=2 rank=4
  - tuple: `reg | reg.token`
  - `src/annotator/helpers/fixable_helpers.rb:36` (emit_mutable_unused_finding!) ; `src/annotator/helpers/fixable_helpers.rb:1425` (build_atomic_escape_migration_fix)
- **[conjunction]** support=2 scatter=2 rank=4
  - tuple: `decl | decl.respond_to?(:token) | decl.token`
  - `src/annotator/helpers/fixable_helpers.rb:1276` (build_decl_cap_insert_fix) ; `src/annotator/helpers/fixable_helpers.rb:1314` (build_decl_cap_replace_fix)
- **[conjunction]** support=2 scatter=2 rank=4
  - tuple: `pred_type | pred_type.resolved == :Bool`
  - `src/annotator/helpers/capabilities.rb:618` (visit_pre_clauses!) ; `src/annotator/helpers/capabilities.rb:687` (visit_post_clauses!)
- **[case_dispatch]** support=2 scatter=2 rank=4
  - tuple: `:block | :exit`
  - `src/annotator/domains/errors.rb:189` (visit_SyncPolicyDecl) ; `src/annotator/domains/execution_boundaries.rb:551` (validate_snapshot_match_arms!)
- **[conjunction]** support=2 scatter=2 rank=4
  - tuple: `root.is_a?(AST::Identifier) | root.symbol&.non_escaping`
  - `src/annotator/domains/lifetimes.rb:243` (visit_CloneNode) ; `src/annotator/domains/lifetimes.rb:264` (visit_ShareNode)
- **[case_dispatch]** support=2 scatter=2 rank=4
  - tuple: `:affine | :resource`
  - `src/annotator/domains/lifetimes.rb:539` (finalize_scope) ; `src/annotator/domains/lifetimes.rb:610` (collect_scope_drops)
- **[conjunction]** support=2 scatter=2 rank=4
  - tuple: `consumer_param_type | existing.move_consumer_param_type.nil?`
  - `src/annotator/domains/lifetimes.rb:1172` (move_if_not_copyable!) ; `src/annotator/domains/lifetimes.rb:1193` (move_if_takes_ownership!)
- ...(+3 more)

## Reification Misses (6)
_an existing predicate reinvented inline -- invariant #16_

- predicate `plain_reentrant?` reinvented inline at `src/ast/ast.rb:644` (recursion_yield_needed?) (`fn_node.reentrance_kind == :reentrant`)
- predicate `plain_reentrant?` reinvented inline at `src/ast/ast.rb:1479` (recursive_reentrance_declared?) (`reentrance_kind == :reentrant`)
- predicate `plain_reentrant?` reinvented inline at `src/annotator/helpers/reentrance.rb:92` (offer_plain_reentrant_variant_fix!) (`fn_node.reentrance_kind == :reentrant`)
- predicate `plain_reentrant?` reinvented inline at `src/annotator/helpers/reentrance.rb:257` (find_plain_reentrant_callee) (`fn.reentrance_kind == :reentrant`)
- predicate `tail_call_reentrant?` reinvented inline at `src/ast/ast.rb:645` (recursion_yield_needed?) (`fn_node.reentrance_kind == :reentrant_tail_call`)
- predicate `tail_call_reentrant?` reinvented inline at `src/ast/ast.rb:1481` (recursive_reentrance_declared?) (`reentrance_kind == :reentrant_tail_call`)

## Semantic Predicate Aliases (3)
_one decision, multiple names (receiver/polarity folded)_

- `wildcard? = union? = struct? = resource? = enum?` == `false`
  - `src/ast/ast.rb:1676` (wildcard?) ; `src/ast/ast.rb:1837` (wildcard?) ; `src/ast/ast.rb:1852` (wildcard?) ; `src/ast/schemas.rb:36` (union?) ; `src/ast/schemas.rb:38` (struct?) ; `src/ast/schemas.rb:40` (resource?) ; `src/ast/schemas.rb:148` (union?) ; `src/ast/schemas.rb:150` (enum?) ; `src/ast/schemas.rb:152` (struct?) ; `src/ast/schemas.rb:275` (enum?) ; `src/ast/schemas.rb:277` (struct?) ; `src/ast/schemas.rb:279` (resource?) ; `src/ast/schemas.rb:327` (union?) ; `src/ast/schemas.rb:329` (enum?) ; `src/ast/schemas.rb:331` (resource?)
- `enum? = resource? = union? = struct?` == `true`
  - `src/ast/schemas.rb:34` (enum?) ; `src/ast/schemas.rb:146` (resource?) ; `src/ast/schemas.rb:273` (union?) ; `src/ast/schemas.rb:325` (struct?)
- `lock_sync? = locked_sync?` == `locked? || write_locked?`
  - `src/ast/symbol_entry.rb:222` (lock_sync?) ; `src/ast/ast.rb:2226` (locked_sync?)

## Exact Predicate Aliases (4)
_identical one-line predicate body under >=2 names_

- `wildcard? = union? = struct? = resource? = enum?` == `false`
  - `src/ast/ast.rb:1676` (wildcard?) ; `src/ast/ast.rb:1837` (wildcard?) ; `src/ast/ast.rb:1852` (wildcard?) ; `src/ast/schemas.rb:36` (union?) ; `src/ast/schemas.rb:38` (struct?) ; `src/ast/schemas.rb:40` (resource?) ; `src/ast/schemas.rb:148` (union?) ; `src/ast/schemas.rb:150` (enum?) ; `src/ast/schemas.rb:152` (struct?) ; `src/ast/schemas.rb:275` (enum?) ; `src/ast/schemas.rb:277` (struct?) ; `src/ast/schemas.rb:279` (resource?) ; `src/ast/schemas.rb:327` (union?) ; `src/ast/schemas.rb:329` (enum?) ; `src/ast/schemas.rb:331` (resource?)
- `enum? = resource? = union? = struct?` == `true`
  - `src/ast/schemas.rb:34` (enum?) ; `src/ast/schemas.rb:146` (resource?) ; `src/ast/schemas.rb:273` (union?) ; `src/ast/schemas.rb:325` (struct?)
- `pin_heap_for_sync_wrapper! = pin_heap_for_indirect! = pin_heap_for_collection!` == `mark_heap_allocated!`
  - `src/ast/type.rb:1142` (pin_heap_for_sync_wrapper!) ; `src/ast/type.rb:1149` (pin_heap_for_indirect!) ; `src/ast/type.rb:1156` (pin_heap_for_collection!)
- `lock_sync? = locked_sync?` == `locked? || write_locked?`
  - `src/ast/symbol_entry.rb:222` (lock_sync?) ; `src/ast/ast.rb:2226` (locked_sync?)

## Inconsistent Rename Clones (0)
_pasted block with inconsistent identifier mapping -- *POSSIBLE* missed rename bug_

None.

## Structural Similarity (Type-2/3) (0)
_Tree-sitter structural clone pressure: Type-2 renamed clones and Type-3 fuzzy clones -- refactor pressure, not a verdict_

None.

## Neglected Updates (169)
_co-written state, one write missing -- *POSSIBLE* redundant-state desync_

- *POSSIBLE* (support=5) `src/ast/ast.rb:1087` (finalize_storage!) writes `.storage` but NOT `.capture_analysis` (recv `value`)
- *POSSIBLE* (support=5) `src/annotator/helpers/generic_analysis.rb:600` (register_container_borrow!) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/helpers/function_analysis.rb:1137` (verify_captures!) writes `.storage` but NOT `.capture_analysis` (recv `cap`)
- *POSSIBLE* (support=5) `src/annotator/helpers/pipe_analysis.rb:297` (analyze_collect_op) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/helpers/pipe_analysis.rb:352` (analyze_select_family_op) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/helpers/pipe_analysis.rb:380` (analyze_take_while_op) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/helpers/pipe_analysis.rb:407` (analyze_window_op) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/helpers/pipe_analysis.rb:485` (analyze_batch_window_op) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/helpers/pipe_analysis.rb:548` (analyze_join_op) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/helpers/pipe_analysis.rb:565` (analyze_recover_op) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/helpers/pipe_analysis.rb:597` (analyze_reduce_op) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/helpers/pipe_analysis.rb:651` (analyze_limit_op) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/helpers/pipe_analysis.rb:686` (analyze_unnest_op) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/helpers/pipe_analysis.rb:729` (analyze_distinct_op) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/helpers/pipe_analysis.rb:860` (analyze_each_op) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/helpers/pipe_analysis.rb:880` (analyze_skip_op) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/helpers/pipe_analysis.rb:906` (analyze_tap_op) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/helpers/pipe_analysis.rb:933` (analyze_find_op) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/helpers/pipe_analysis.rb:957` (analyze_any_op) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/helpers/pipe_analysis.rb:981` (analyze_all_op) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/helpers/pipe_analysis.rb:1005` (analyze_count_op) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/helpers/pipe_analysis.rb:1037` (analyze_sum_op) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/helpers/pipe_analysis.rb:1062` (analyze_average_op) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/helpers/pipe_analysis.rb:1087` (analyze_min_op) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- *POSSIBLE* (support=5) `src/annotator/helpers/pipe_analysis.rb:1112` (analyze_max_op) writes `.storage` but NOT `.capture_analysis` (recv `node`)
- ...(+144 more)

## Derived-State Staleness (15)
_b = f(a); a later reassigned, b not recomputed -- *POSSIBLE* bug_

- *POSSIBLE* `src/annotator/domains/errors.rb:379` (visit_ReturnNode): `expected_void_compatible` derived from `expected` (line 379); `expected` reassigned line 431, `expected_void_compatible` not recomputed
- *POSSIBLE* `src/ast/ast.rb:1096` (finalize_storage!): `value_sync` derived from `vt` (line 1096); `vt` reassigned line 1119, `value_sync` not recomputed
- *POSSIBLE* `src/annotator/domains/variables.rb:610` (visit_Assignment): `tname` derived from `target` (line 610); `target` reassigned line 630, `tname` not recomputed
- *POSSIBLE* `src/ast/diagnostic_examples.rb:96` (scan_file): `fix_scan` derived from `i` (line 96); `i` reassigned line 111, `fix_scan` not recomputed
- *POSSIBLE* `src/ast/diagnostic_examples.rb:145` (find_block_end): `l` derived from `k` (line 145); `k` reassigned line 155, `l` not recomputed
- *POSSIBLE* `src/ast/ast.rb:1101` (finalize_storage!): `t` derived from `val_ti` (line 1101); `val_ti` reassigned line 1110, `t` not recomputed
- *POSSIBLE* `src/annotator/helpers/capabilities.rb:1185` (record_capture_info!): `string_map_cleanup` derived from `close_plan` (line 1185); `close_plan` reassigned line 1194, `string_map_cleanup` not recomputed
- *POSSIBLE* `src/annotator/domains/member_access.rb:140` (visit_GetField): `psch` derived from `field_type` (line 140); `field_type` reassigned line 148, `psch` not recomputed
- *POSSIBLE* `src/ast/diagnostic_examples.rb:124` (scan_fix_lines): `line` derived from `idx` (line 124); `idx` reassigned line 127, `line` not recomputed
- *POSSIBLE* `src/annotator/domains/member_access.rb:325` (visit_StructLit): `owned` derived from `val_node` (line 325); `val_node` reassigned line 328, `owned` not recomputed
- *POSSIBLE* `src/ast/diagnostic_examples.rb:90` (scan_file): `m` derived from `i` (line 90); `i` reassigned line 92, `m` not recomputed
- *POSSIBLE* `src/annotator/helpers/fixable_helpers.rb:1211` (literal_source_length): `ch` derived from `i` (line 1211); `i` reassigned line 1213, `ch` not recomputed
- *POSSIBLE* `src/annotator/domains/execution_boundaries.rb:742` (visit_BgBlock): `last_type_str` derived from `last_type` (line 742); `last_type` reassigned line 744, `last_type_str` not recomputed
- *POSSIBLE* `src/annotator/helpers/pipe_analysis.rb:756` (analyze_pipe_to_func_call): `t` derived from `result_type` (line 756); `result_type` reassigned line 757, `t` not recomputed
- *POSSIBLE* `src/annotator/helpers/pipe_analysis.rb:817` (analyze_pipe_to_named_function): `t` derived from `result_type` (line 817); `result_type` reassigned line 818, `t` not recomputed

## Neglected Conditions (0)
_dispatch/conjunction minus one element -- *POSSIBLE* bug_

None.

## Neglected Path Conditions (269)
_nested-if/&& guard set minus one atom -- *POSSIBLE* bug (noisy)_

- *POSSIBLE* (support=20) `src/annotator/helpers/fixable_helpers.rb:583` (emit_local_never_shared_finding!) -- MISSING `idx` from `@source_code | idx | line`
- *POSSIBLE* (support=20) `src/annotator/helpers/fixable_helpers.rb:583` (emit_local_never_shared_finding!) -- MISSING `idx` from `@source_code | idx | line`
- *POSSIBLE* (support=20) `src/annotator/helpers/fixable_helpers.rb:583` (emit_local_never_shared_finding!) -- MISSING `idx` from `@source_code | idx | line`
- *POSSIBLE* (support=20) `src/annotator/helpers/fixable_helpers.rb:583` (emit_local_never_shared_finding!) -- MISSING `idx` from `@source_code | idx | line`
- *POSSIBLE* (support=20) `src/annotator/helpers/fixable_helpers.rb:586` (emit_local_never_shared_finding!) -- MISSING `idx` from `@source_code | idx | line`
- *POSSIBLE* (support=20) `src/annotator/helpers/fixable_helpers.rb:586` (emit_local_never_shared_finding!) -- MISSING `idx` from `@source_code | idx | line`
- *POSSIBLE* (support=20) `src/annotator/helpers/fixable_helpers.rb:586` (emit_local_never_shared_finding!) -- MISSING `idx` from `@source_code | idx | line`
- *POSSIBLE* (support=20) `src/annotator/helpers/fixable_helpers.rb:586` (emit_local_never_shared_finding!) -- MISSING `idx` from `@source_code | idx | line`
- *POSSIBLE* (support=12) `src/annotator/helpers/fixable_helpers.rb:1062` (emit_with_materialized_needs_tense!) -- MISSING `decl.token` from `decl | decl.token | src`
- *POSSIBLE* (support=12) `src/annotator/helpers/fixable_helpers.rb:1062` (emit_with_materialized_needs_tense!) -- MISSING `token` from `decl | src | token`
- *POSSIBLE* (support=12) `src/annotator/helpers/fixable_helpers.rb:1062` (emit_with_materialized_needs_tense!) -- MISSING `decl.token` from `decl | decl.token | src`
- *POSSIBLE* (support=12) `src/annotator/helpers/fixable_helpers.rb:1062` (emit_with_materialized_needs_tense!) -- MISSING `token` from `decl | src | token`
- *POSSIBLE* (support=12) `src/annotator/helpers/fixable_helpers.rb:1399` (build_declare_mutable_fix) -- MISSING `src` from `decl | decl.token | src`
- *POSSIBLE* (support=12) `src/annotator/helpers/fixable_helpers.rb:1399` (build_declare_mutable_fix) -- MISSING `src` from `decl | decl.token | src`
- *POSSIBLE* (support=11) `src/ast/diagnostic_examples.rb:100` (scan_file) -- MISSING `desc_end` from `desc_end | describe_idx < lines.length | dm = T.must(lines[describe_idx]).match(/^(\s*)describe\b/)`
- *POSSIBLE* (support=11) `src/ast/diagnostic_examples.rb:100` (scan_file) -- MISSING `desc_end` from `desc_end | describe_idx < lines.length | dm = T.must(lines[describe_idx]).match(/^(\s*)describe\b/)`
- *POSSIBLE* (support=11) `src/ast/diagnostic_examples.rb:100` (scan_file) -- MISSING `desc_end` from `desc_end | describe_idx < lines.length | dm = T.must(lines[describe_idx]).match(/^(\s*)describe\b/)`
- *POSSIBLE* (support=11) `src/ast/diagnostic_examples.rb:100` (scan_file) -- MISSING `desc_end` from `desc_end | describe_idx < lines.length | dm = T.must(lines[describe_idx]).match(/^(\s*)describe\b/)`
- *POSSIBLE* (support=11) `src/ast/diagnostic_examples.rb:101` (scan_file) -- MISSING `desc_end` from `desc_end | describe_idx < lines.length | dm = T.must(lines[describe_idx]).match(/^(\s*)describe\b/)`
- *POSSIBLE* (support=11) `src/ast/diagnostic_examples.rb:101` (scan_file) -- MISSING `desc_end` from `desc_end | describe_idx < lines.length | dm = T.must(lines[describe_idx]).match(/^(\s*)describe\b/)`
- *POSSIBLE* (support=11) `src/ast/type.rb:2987` (needs_explicit_cleanup?) -- MISSING `Schemas.struct?(schema)` from `!Schemas.union?(schema) | Schemas.struct?(schema) | schema_lookup`
- *POSSIBLE* (support=11) `src/ast/type.rb:3011` (elem_has_heap_internals?) -- MISSING `Schemas.struct?(schema)` from `!Schemas.union?(schema) | Schemas.struct?(schema) | schema_lookup`
- *POSSIBLE* (support=11) `src/ast/type.rb:3037` (cleanup_allocator) -- MISSING `!Schemas.union?(schema)` from `!Schemas.union?(schema) | Schemas.struct?(schema) | schema_lookup`
- *POSSIBLE* (support=11) `src/ast/type.rb:3037` (cleanup_allocator) -- MISSING `!Schemas.union?(schema)` from `!Schemas.union?(schema) | Schemas.struct?(schema) | schema_lookup`
- *POSSIBLE* (support=11) `src/ast/type.rb:3037` (cleanup_allocator) -- MISSING `!Schemas.union?(schema)` from `!Schemas.union?(schema) | Schemas.struct?(schema) | schema_lookup`
- ...(+244 more)

## Oversized Predicates (5)
_predicate with >3 condition atoms -- use an existing helper or extract a named predicate_

- *POSSIBLE* `src/ast/type.rb:801` (initialize) -- 7 condition atoms in `ownership || sync || layout || collection || shard_count || observable || observable_terminal`
  - atoms: `ownership | sync | layout | collection | shard_count | observable | observable_terminal`
- *POSSIBLE* `src/ast/type.rb:1299` (apply_bg_capture_symbol!) -- 4 condition atoms in `(storage == :multiowned || storage == :shared) && (!ownership || ownership == :affine)`
  - atoms: `storage == :multiowned | storage == :shared | !ownership | ownership == :affine`
- *POSSIBLE* `src/ast/type.rb:1387` (merge_capabilities_from!) -- 4 condition atoms in `source_ownership && !(preserve_existing && ownership && ownership != :affine) && (include_affine_ownership || source_ownership != :affine)`
  - atoms: `source_ownership | !(preserve_existing && ownership && ownership != :affine) | include_affine_ownership | source_ownership != :affine`
- *POSSIBLE* `src/annotator/helpers/effects.rb:1046` (assign_base_stack_tiers!) -- 4 condition atoms in `effs.include?(HEAP) || effs.include?(BLOCKING) || effs.include?(EXTERN) || fn_node.runtime_stack_required?(recursion_yield_needed?(fn_node), declared_runtime_return)`
  - atoms: `effs.include?(HEAP) | effs.include?(BLOCKING) | effs.include?(EXTERN) | fn_node.runtime_stack_required?(recursion_yield_needed?(fn_node), declared_runtime_return)`
- *POSSIBLE* `src/annotator/domains/control_flow.rb:791` (visit_WhileLoop) -- 4 condition atoms in `(node.condition.is_a?(AST::Identifier) && node.condition.name == "TRUE") || (node.condition.is_a?(AST::Literal) && node.condition.value == true)`
  - atoms: `node.condition.is_a?(AST::Identifier) | node.condition.name == "TRUE" | node.condition.is_a?(AST::Literal) | node.condition.value == true`

## Broken Protocols (106)
_co-called pair, one site does A without B -- *POSSIBLE* bug (noisy)_

- *POSSIBLE* conf=0.98 support=55 `src/ast/async_result_shape.rb:11` ((top-level)) does `returns` without `[]`
- *POSSIBLE* conf=0.97 support=36 `src/ast/source_error.rb:85` (fix_description) does `fix_description` without `new`
- *POSSIBLE* conf=0.95 support=21 `src/ast/async_result_shape.rb:8` ((top-level)) does `const` without `[]`
- *POSSIBLE* conf=0.92 support=11 `src/annotator/helpers/intrinsic_emit.rb:22` ((top-level)) does `prop` without `returns`
- *POSSIBLE* conf=0.92 support=11 `src/annotator/helpers/capabilities.rb:988` (declare_view_borrow_constraints!) does `local_entry!` without `declare`
- *POSSIBLE* conf=0.9 support=18 `src/annotator/helpers/pipe_analysis.rb:636` (analyze_limit_op) does `pipeline_source_fact` without `declare`
- *POSSIBLE* conf=0.9 support=18 `src/annotator/helpers/pipe_analysis.rb:868` (analyze_skip_op) does `pipeline_source_fact` without `declare`
- *POSSIBLE* conf=0.9 support=9 `src/annotator/helpers/capabilities.rb:1227` (record_capture_move!) does `classify_ownership!` without `error!`
- *POSSIBLE* conf=0.9 support=9 `src/annotator/domains/variables.rb:414` (visit_Identifier) does `emit_typo_suggestion!` without `error!`
- *POSSIBLE* conf=0.88 support=15 `src/annotator/helpers/pipe_analysis.rb:576` (analyze_reduce_op) does `require_array_input!` without `error!`
- *POSSIBLE* conf=0.88 support=15 `src/annotator/helpers/pipe_analysis.rb:638` (analyze_limit_op) does `require_array_input!` without `declare`
- *POSSIBLE* conf=0.88 support=15 `src/annotator/helpers/pipe_analysis.rb:705` (analyze_distinct_op) does `require_array_input!` without `error!`
- *POSSIBLE* conf=0.88 support=15 `src/annotator/helpers/pipe_analysis.rb:870` (analyze_skip_op) does `require_array_input!` without `declare`
- *POSSIBLE* conf=0.88 support=7 `src/annotator/domains/variables.rb:334` (mark_borrowed_field_bind_alias!) does `mark_non_escaping!` without `local_entry!`
- *POSSIBLE* conf=0.86 support=6 `src/ast/type.rb:3307` (semantic_shape_key) does `surface_name` without `new`
- *POSSIBLE* conf=0.86 support=6 `src/annotator/helpers/function_analysis.rb:145` (with_routine_analysis_scope) does `finalize_scope` without `stamp_type!`
- *POSSIBLE* conf=0.86 support=6 `src/annotator/helpers/function_analysis.rb:145` (with_routine_analysis_scope) does `finalize_scope` without `visit_stmts`
- *POSSIBLE* conf=0.86 support=6 `src/annotator/domains/execution_boundaries.rb:637` (visit_DoBlock) does `with_fiber_capture_analysis` without `full_type!`
- *POSSIBLE* conf=0.83 support=15 `src/annotator/helpers/union.rb:211` (validate_union_fields!) does `record_effect` without `stamp_type!`
- *POSSIBLE* conf=0.83 support=15 `src/annotator/helpers/capabilities.rb:797` (acquire_capability!) does `record_effect` without `stamp_type!`
- *POSSIBLE* conf=0.83 support=15 `src/annotator/domains/variables.rb:374` (stamp_atomic_bind_assignment!) does `record_effect` without `stamp_type!`
- *POSSIBLE* conf=0.83 support=5 `src/annotator/helpers/generic_analysis.rb:494` (substitute_type_params) does `apply_type_subst` without `is_a?`
- *POSSIBLE* conf=0.83 support=5 `src/annotator/helpers/generic_analysis.rb:598` (register_container_borrow!) does `mark_borrowed_alias!` without `mark_non_escaping!`
- *POSSIBLE* conf=0.83 support=5 `src/annotator/helpers/intrinsic_registry.rb:265` (overloads) does `lookup` without `unwrap`
- *POSSIBLE* conf=0.83 support=5 `src/annotator/helpers/capabilities.rb:952` (declare_restrict_capability!) does `mark_var_mutated` without `stamp_type!`
- ...(+81 more)

## Implicit Control Flow (26)
_state-dependent internal call order exists -- hidden lifecycle/control-flow pressure_

- *POSSIBLE* [protocol_pressure] support=31 `with_new_scope -> current_scope` (write_read state=`scope_stack`) -- `src/annotator/helpers/function_analysis.rb:200` (visit_FunctionDef)
  - sites: `src/annotator/helpers/function_analysis.rb:200` (visit_FunctionDef) ; `src/annotator/helpers/test_annotation.rb:44` (visit_WhenBlock) ; `src/annotator/helpers/pipe_analysis.rb:308` (analyze_select_family_op) ; `src/annotator/helpers/pipe_analysis.rb:362` (analyze_take_while_op) (+27 more)
- *POSSIBLE* [protocol_pressure] support=2 `apply_capabilities! -> ownership` (write_read state=`capabilities`) -- `src/ast/type.rb:1287` (apply_symbol_overlay!)
  - sites: `src/ast/type.rb:1287` (apply_symbol_overlay!) ; `src/ast/type.rb:1297` (apply_bg_capture_symbol!)
- *POSSIBLE* [protocol_pressure] support=2 `apply_capabilities! -> sync` (write_read state=`capabilities`) -- `src/ast/type.rb:1322` (copy_declared_collection_modifiers_from!)
  - sites: `src/ast/type.rb:1322` (copy_declared_collection_modifiers_from!) ; `src/ast/type.rb:1378` (merge_capabilities_from!)
- *POSSIBLE* [protocol_pressure] support=2 `current_scope -> with_new_scope` (read_write state=`scope_stack`) -- `src/annotator/helpers/pipe_analysis.rb:491` (analyze_join_op)
  - sites: `src/annotator/helpers/pipe_analysis.rb:491` (analyze_join_op) ; `src/annotator/helpers/capabilities.rb:634` (visit_post_clauses!)
- *POSSIBLE* [protocol_pressure] support=2 `provenance -> apply_placement!` (read_write state=`placement`) -- `src/ast/type.rb:1168` (copy_placement_from!)
  - sites: `src/ast/type.rb:1168` (copy_placement_from!) ; `src/ast/type.rb:1175` (apply_cleanup_placement!)
- *POSSIBLE* [protocol_pressure] support=1 `apply_capabilities! -> collection` (write_read state=`capabilities`) -- `src/ast/type.rb:1305` (copy_collection_shape_from!)
  - sites: `src/ast/type.rb:1305` (copy_collection_shape_from!)
- *POSSIBLE* [protocol_pressure] support=1 `apply_capabilities! -> shard_count` (write_read state=`capabilities`) -- `src/ast/type.rb:1314` (copy_topology_from!)
  - sites: `src/ast/type.rb:1314` (copy_topology_from!)
- *POSSIBLE* [protocol_pressure] support=1 `clear_synthetic_function_definitions! -> synthetic_function_definitions` (write_read state=`semantic_function_registry`) -- `src/annotator/phases/signature_registration.rb:16` (register_program_signatures)
  - sites: `src/annotator/phases/signature_registration.rb:16` (register_program_signatures)
- *POSSIBLE* [protocol_pressure] support=1 `declare_and_verify_params -> declare_captures` (read_write|write_read|write_write state=`current_scope`) -- `src/annotator/helpers/function_analysis.rb:89` (analyze_routine)
  - sites: `src/annotator/helpers/function_analysis.rb:89` (analyze_routine)
- *POSSIBLE* [protocol_pressure] support=1 `declare_assignment_graph_path! -> og_set_moved` (write_read state=`ownership_graph`) -- `src/annotator/domains/lifetimes.rb:362` (handle_assignment_path_move!)
  - sites: `src/annotator/domains/lifetimes.rb:362` (handle_assignment_path_move!)
- *POSSIBLE* [protocol_pressure] support=1 `declare_captures -> visit_post_clauses!` (read_write|write_read|write_write state=`current_scope`) -- `src/annotator/helpers/function_analysis.rb:89` (analyze_routine)
  - sites: `src/annotator/helpers/function_analysis.rb:89` (analyze_routine)
- *POSSIBLE* [protocol_pressure] support=1 `declare_unwrapped_capability_alias! -> declare_capability_binding_or_error!` (write_read state=`current_scope`) -- `src/annotator/helpers/capabilities.rb:896` (declare_capability_scope!)
  - sites: `src/annotator/helpers/capabilities.rb:896` (declare_capability_scope!)
- *POSSIBLE* [protocol_pressure] support=1 `declare_view_borrow_constraints! -> og_declare` (write_read state=`current_scope`) -- `src/annotator/helpers/capabilities.rb:970` (declare_view_capability!)
  - sites: `src/annotator/helpers/capabilities.rb:970` (declare_view_capability!)
- *POSSIBLE* [protocol_pressure] support=1 `og_declare -> analyze_control_flow_branches` (write_read state=`ownership_graph`) -- `src/annotator/domains/control_flow.rb:153` (visit_IfBind)
  - sites: `src/annotator/domains/control_flow.rb:153` (visit_IfBind)
- *POSSIBLE* [protocol_pressure] support=1 `og_declare -> finalize_scope` (write_read state=`ownership_graph`) -- `src/annotator/domains/control_flow.rb:836` (visit_WhileBindLoop)
  - sites: `src/annotator/domains/control_flow.rb:836` (visit_WhileBindLoop)
- *POSSIBLE* [protocol_pressure] support=1 `og_declare -> register_container_borrow!` (write_read state=`ownership_graph`) -- `src/annotator/domains/variables.rb:75` (finalize_decl_node!)
  - sites: `src/annotator/domains/variables.rb:75` (finalize_decl_node!)
- *POSSIBLE* [protocol_pressure] support=1 `og_push_scope -> finalize_scope` (write_read state=`ownership_graph`) -- `src/annotator/helpers/function_analysis.rb:138` (with_routine_analysis_scope)
  - sites: `src/annotator/helpers/function_analysis.rb:138` (with_routine_analysis_scope)
- *POSSIBLE* [protocol_pressure] support=1 `register_function_node! -> body_identity_for_function` (write_read state=`semantic_function_registry`) -- `src/annotator/helpers/function_analysis.rb:200` (visit_FunctionDef)
  - sites: `src/annotator/helpers/function_analysis.rb:200` (visit_FunctionDef)
- *POSSIBLE* [protocol_pressure] support=1 `register_function_signature -> register_extern_function_signature` (read_write|write_read|write_write state=`current_scope`) -- `src/annotator/phases/signature_registration.rb:16` (register_program_signatures)
  - sites: `src/annotator/phases/signature_registration.rb:16` (register_program_signatures)
- *POSSIBLE* [protocol_pressure] support=1 `visit_test_lets -> visit_WhenBlock` (write_read state=`current_scope`) -- `src/annotator/helpers/test_annotation.rb:32` (visit_TestBlock)
  - sites: `src/annotator/helpers/test_annotation.rb:32` (visit_TestBlock)
- *POSSIBLE* [protocol_pressure] support=1 `with_body_fact_frame -> with_body_fact_scopes_cleared` (write_read state=`body_fact_frames`) -- `src/annotator/phases/body_analysis.rb:311` (with_async_body_fact_frame)
  - sites: `src/annotator/phases/body_analysis.rb:311` (with_async_body_fact_frame)
- *POSSIBLE* [protocol_pressure] support=1 `propagate_declared_type_to_value! -> propagate_collection_metadata!` (write_write state=`value`) -- `src/annotator/domains/variables.rb:75` (finalize_decl_node!)
  - sites: `src/annotator/domains/variables.rb:75` (finalize_decl_node!)
- *POSSIBLE* [protocol_pressure] support=1 `resolve_collection_method -> resolve_extern_method_call!` (write_write state=`object`) -- `src/annotator/phases/expression_domains.rb:36` (visit_MethodCall)
  - sites: `src/annotator/phases/expression_domains.rb:36` (visit_MethodCall)
- *POSSIBLE* [protocol_pressure] support=1 `apply_storage_capability! -> apply_capabilities!` (read_write state=`capabilities`) -- `src/ast/type.rb:1287` (apply_symbol_overlay!)
  - sites: `src/ast/type.rb:1287` (apply_symbol_overlay!)
- *POSSIBLE* [protocol_pressure] support=1 `finalize_scope -> og_pop_scope` (read_write state=`ownership_graph`) -- `src/annotator/helpers/function_analysis.rb:138` (with_routine_analysis_scope)
  - sites: `src/annotator/helpers/function_analysis.rb:138` (with_routine_analysis_scope)
- ...(+1 more)

## Weighted Inlined Cognitive Complexity (88)
_same-owner helper chain hides cognitive load behind a low-looking orchestration method_

- *POSSIBLE* `src/annotator/helpers/pipe_analysis.rb:212` (analyze_higher_order_op) -- inlined=266.5 (local=3.5, hidden=263.0, depth=2)
  - chain: `analyze_higher_order_op -> analyze_concurrent_op`
  - single-caller helpers: `analyze_all_op | analyze_any_op | analyze_batch_window_op | analyze_collect_op | analyze_concurrent_op | analyze_distinct_op | analyze_find_op | analyze_join_op`
  - reason: 17 single-caller helper(s) add 263.0 weighted cognitive points
- *POSSIBLE* `src/annotator/helpers/pipe_analysis.rb:1422` (analyze_concurrent_op) -- inlined=194.3 (local=49.0, hidden=145.3, depth=2)
  - chain: `analyze_concurrent_op -> analyze_concurrent_bounded_each_op`
  - single-caller helpers: `analyze_auto_shard_each_op | analyze_concurrent_bounded_each_op | analyze_concurrent_bounded_select_family_op | analyze_concurrent_stream_each_op | analyze_concurrent_stream_select_family_op | analyze_shard_each_op | collect_sharded_names | concurrent_stream_source?`
  - reason: 12 single-caller helper(s) add 145.3 weighted cognitive points
- *POSSIBLE* `src/annotator/helpers/function_analysis.rb:89` (analyze_routine) -- inlined=167.1 (local=23.5, hidden=143.6, depth=1)
  - chain: `analyze_routine -> declare_and_verify_params`
  - single-caller helpers: `collect_routine_returns | declare_and_verify_params | declare_captures | verify_captures! | verify_returns | with_routine_analysis_scope`
  - reason: 6 single-caller helper(s) add 143.6 weighted cognitive points
- *POSSIBLE* `src/annotator/helpers/lock_helper.rb:340` (check_lock_cycles!) -- inlined=114.9 (local=7.0, hidden=107.9, depth=2)
  - chain: `check_lock_cycles! -> propagate_lock_acquires!`
  - single-caller helpers: `check_lock_handler_reachability! | propagate_lock_acquires! | report_lock_cycle! | resolve_held_calls! | scc_is_cyclic?`
  - reason: 5 single-caller helper(s) add 107.9 weighted cognitive points
- *POSSIBLE* `src/annotator/helpers/function_analysis.rb:500` (verify_function_signature!) -- inlined=102.4 (local=7.0, hidden=95.4, depth=2)
  - chain: `verify_function_signature! -> verify_param_lifetime!`
  - single-caller helpers: `call_argument_facts | call_arity_plan | call_signature_site | inject_default_arguments! | verify_argument_aliases! | verify_argument_type! | verify_call_arity! | verify_link_argument!`
  - reason: 12 single-caller helper(s) add 95.4 weighted cognitive points
- *POSSIBLE* `src/annotator/helpers/pipe_analysis.rb:63` (visit_Smooth) -- inlined=108.9 (local=15.0, hidden=93.9, depth=2)
  - chain: `visit_Smooth -> analyze_higher_order_op -> analyze_concurrent_op`
  - single-caller helpers: `analyze_higher_order_op | analyze_pipe_to_func_call | analyze_pipe_to_identifier | pipe_complex_op?`
  - reason: 4 single-caller helper(s) add 93.9 weighted cognitive points
- *POSSIBLE* `src/annotator/helpers/function_analysis.rb:200` (visit_FunctionDef) -- inlined=134.5 (local=57.3, hidden=77.2, depth=2)
  - chain: `visit_FunctionDef -> analyze_routine -> declare_and_verify_params`
  - single-caller helpers: `get_return_strategy | verify_lifetime!`
  - reason: 2 single-caller helper(s) add 77.2 weighted cognitive points
- *POSSIBLE* `src/annotator/domains/execution_boundaries.rb:12` (visit_WithBlock) -- inlined=160.3 (local=84.0, hidden=76.3, depth=2)
  - chain: `visit_WithBlock -> validate_lock_error_clause!`
  - single-caller helpers: `mark_with_runtime_requirements! | retryable_with_fallible_body_error! | retryable_with_fallible_sources | retryable_with_universal_poly_candidate? | validate_lock_error_clause! | validate_no_multi_object_atomic! | validate_with_match_source_shape!`
  - reason: 7 single-caller helper(s) add 76.3 weighted cognitive points
- *POSSIBLE* `src/ast/type.rb:2962` (needs_explicit_cleanup?) -- inlined=109.6 (local=36.3, hidden=73.3, depth=2)
  - chain: `needs_explicit_cleanup? -> implicitly_copyable?`
  - single-caller helpers: `elem_has_heap_internals? | implicitly_copyable?`
  - reason: 2 single-caller helper(s) add 73.3 weighted cognitive points
- *POSSIBLE* `src/annotator/helpers/effects.rb:250` (compute_effects!) -- inlined=99.9 (local=27.8, hidden=72.1, depth=2)
  - chain: `compute_effects! -> resolve_maybe_effects`
  - single-caller helpers: `inherit_effects_from_callee | resolve_maybe_effects`
  - reason: 2 single-caller helper(s) add 72.1 weighted cognitive points
- *POSSIBLE* `src/ast/type.rb:3101` (zig_type) -- inlined=70.8 (local=2.3, hidden=68.5, depth=2)
  - chain: `zig_type -> compute_zig_type`
  - single-caller helpers: `compute_zig_type`
  - reason: 1 single-caller helper(s) add 68.5 weighted cognitive points
- *POSSIBLE* `src/annotator/helpers/capabilities.rb:735` (acquire_capability!) -- inlined=85.5 (local=25.5, hidden=60.0, depth=2)
  - chain: `acquire_capability! -> validate_capability_transition!`
  - single-caller helpers: `validate_capability_transition! | with_capability_fact`
  - reason: 2 single-caller helper(s) add 60.0 weighted cognitive points
- *POSSIBLE* `src/annotator/domains/control_flow.rb:681` (visit_MatchStatement) -- inlined=60.1 (local=2.0, hidden=58.1, depth=2)
  - chain: `visit_MatchStatement -> match_branch_logic`
  - single-caller helpers: `check_match_exhaustiveness! | consume_match_subject_if_takes! | match_branch_logic | match_subject_plan | reject_duplicate_match_patterns!`
  - reason: 5 single-caller helper(s) add 58.1 weighted cognitive points
- *POSSIBLE* `src/annotator/domains/variables.rb:75` (finalize_decl_node!) -- inlined=81.6 (local=24.0, hidden=57.6, depth=2)
  - chain: `finalize_decl_node! -> classify_ownership!`
  - single-caller helpers: `accumulate_stack_bytes | classify_ownership! | promote_pipe_to_observable_dest! | track_union_alias | validate_observable_binding_initializer!`
  - reason: 5 single-caller helper(s) add 57.6 weighted cognitive points
- *POSSIBLE* `src/annotator/helpers/reentrance.rb:35` (bridge_reentrance!) -- inlined=65.6 (local=10.0, hidden=55.6, depth=1)
  - chain: `bridge_reentrance! -> offer_unconstrained_fn_param_fix!`
  - single-caller helpers: `canonical_reentrance_kind | offer_unconstrained_fn_param_fix! | validate_not_logical_return! | validate_requires_clauses!`
  - reason: 4 single-caller helper(s) add 55.6 weighted cognitive points
- *POSSIBLE* `src/annotator/helpers/generic_analysis.rb:287` (infer_generic_type_args!) -- inlined=64.8 (local=10.0, hidden=54.8, depth=2)
  - chain: `infer_generic_type_args! -> extract_type_bindings!`
  - single-caller helpers: `enforce_shared_family_call_sync! | extract_type_bindings!`
  - reason: 2 single-caller helper(s) add 54.8 weighted cognitive points
- *POSSIBLE* `src/annotator/helpers/test_annotation.rb:32` (visit_TestBlock) -- inlined=58.3 (local=8.0, hidden=50.3, depth=2)
  - chain: `visit_TestBlock -> visit_WhenBlock`
  - single-caller helpers: `visit_WhenBlock`
  - reason: 1 single-caller helper(s) add 50.3 weighted cognitive points
- *POSSIBLE* `src/annotator/helpers/effects.rb:986` (compute_stack_tiers!) -- inlined=52.9 (local=3.0, hidden=49.9, depth=2)
  - chain: `compute_stack_tiers! -> assign_base_stack_tiers!`
  - single-caller helpers: `assign_base_stack_tiers! | propagate_unbounded_stack_tiers!`
  - reason: 2 single-caller helper(s) add 49.9 weighted cognitive points
- *POSSIBLE* `src/annotator/helpers/function_analysis.rb:681` (verify_argument_type!) -- inlined=53.0 (local=3.8, hidden=49.2, depth=2)
  - chain: `verify_argument_type! -> verify_atomic_argument!`
  - single-caller helpers: `basic_argument_match? | fn_type_argument_match? | shared_argument_match? | verify_atomic_argument!`
  - reason: 4 single-caller helper(s) add 49.2 weighted cognitive points
- *POSSIBLE* `src/annotator/helpers/function_analysis.rb:190` (visit_LambdaLit) -- inlined=52.7 (local=4.0, hidden=48.7, depth=2)
  - chain: `visit_LambdaLit -> analyze_routine -> declare_and_verify_params`
  - single-caller helpers: `build_lambda_signature`
  - reason: 1 single-caller helper(s) add 48.7 weighted cognitive points
- *POSSIBLE* `src/ast/type.rb:1504` (accepts?) -- inlined=76.3 (local=28.3, hidden=48.0, depth=2)
  - chain: `accepts? -> accepts_future?`
  - single-caller helpers: `== | accepts_array? | accepts_fn_type? | accepts_future? | numeric?`
  - reason: 5 single-caller helper(s) add 48.0 weighted cognitive points
- *POSSIBLE* `src/annotator/helpers/generic_analysis.rb:83` (validate_type_annotation!) -- inlined=51.7 (local=4.8, hidden=46.9, depth=2)
  - chain: `validate_type_annotation! -> validate_observable_annotation_capabilities!`
  - single-caller helpers: `type_annotation_facts | validate_collection_annotation_capabilities! | validate_generic_annotation! | validate_observable_annotation_capabilities! | validate_param_annotation_capabilities! | validate_shape_annotation_capabilities!`
  - reason: 6 single-caller helper(s) add 46.9 weighted cognitive points
- *POSSIBLE* `src/ast/type.rb:3477` (compute_zig_type) -- inlined=92.7 (local=46.8, hidden=45.9, depth=2)
  - chain: `compute_zig_type -> tense_zig_type`
  - single-caller helpers: `capability_wrapped_zig_type | generic_instance_zig_type | map_zig_type | plain_indirect_value? | tense_zig_type`
  - reason: 5 single-caller helper(s) add 45.9 weighted cognitive points
- *POSSIBLE* `src/annotator/helpers/reentrance.rb:428` (validate_thunk_recursion!) -- inlined=73.9 (local=28.0, hidden=45.9, depth=2)
  - chain: `validate_thunk_recursion! -> emit_mutual_thunk_unsupported!`
  - single-caller helpers: `emit_mutual_thunk_unsupported! | try_stamp_mutual_thunk_plan!`
  - reason: 2 single-caller helper(s) add 45.9 weighted cognitive points
- *POSSIBLE* `src/annotator/helpers/lock_helper.rb:360` (check_lock_handler_reachability!) -- inlined=58.9 (local=14.8, hidden=44.1, depth=1)
  - chain: `check_lock_handler_reachability! -> verify_handler_reachability!`
  - single-caller helpers: `verify_handler_reachability!`
  - reason: 1 single-caller helper(s) add 44.1 weighted cognitive points
- ...(+63 more)

## Locality Drag (0)
_local initialized far before first use while unrelated work runs -- move setup closer or extract a private phase_

None.

## Operational Discontinuity (High Confidence) (0)
_strong blank/comment phase boundary where local variable lifetimes reset -- likely implicit sub-function boundary_

None.

## Function LCOM (1)
_independent local data-flow components inside one method -- *POSSIBLE* mixed concerns_

- *POSSIBLE* [late_join] `src/ast/type.rb:3660` (check_prefixed_int_range!) -- score=40 components=2, locals=6, statements=9
  - component 1: `node | val` (lines 3662-3663)
  - component 2: `effective_type | max | min | t` (lines 3665-3670)

## Operational Discontinuity (4)
_blank/comment phase boundary where local variable lifetimes reset -- *POSSIBLE* implicit sub-function boundary_

- *POSSIBLE* `src/ast/type.rb:777` (initialize) -- score=19 reset_boundaries=1, dead=3, new=8, confidence=review
  - line 796 # Capability fields — set after parse/copy so explicit constructor: dead `auto | other | raw_input` -> new `collection | layout | location | observable | observable_terminal | ownership`
- *POSSIBLE* `src/annotator/domains/lifetimes.rb:778` (lookup_source_name) -- score=12 reset_boundaries=1, dead=3, new=2, confidence=review
  - line 787 # Param symbols may have been refreshed via Scope.live_param_syms;: dead `entry | name | sc` -> new `fn | p` (continuing `sym`)
- *POSSIBLE* `src/annotator/phases/body_analysis.rb:429` (analyze_program_bodies!) -- score=12 reset_boundaries=1, dead=2, new=2, confidence=review
  - line 433 blank: dead `declarations | stmt` -> new `fn | program`
- *POSSIBLE* `src/ast/type.rb:314` (self.parse_generic_shape) -- score=12 reset_boundaries=1, dead=2, new=2, confidence=review
  - line 316 blank: dead `array | map` -> new `generic_match | shape_str`

## False Simplicity (603)
_looks simple, behaves non-locally: hidden dispatch/mutation/IO/context/metaprogramming/monkeypatch -- *POSSIBLE* (noisy)_

- *POSSIBLE* [hidden_mutation] scatter=210 support=350 `error!` -- `src/ast/type.rb:3676` (check_prefixed_int_range!) (+349 more)
- *POSSIBLE* [hidden_mutation] scatter=139 support=212 `stamp_type!` -- `src/annotator/helpers/generic_analysis.rb:529` (propagate_declared_type_to_value!) (+211 more)
- *POSSIBLE* [hidden_mutation] scatter=123 support=157 `full_type!` -- `src/ast/ast.rb:58` (stamp_synthetic_type!) (+156 more)
- *POSSIBLE* [hidden_mutation] scatter=121 support=254 `<<` -- `src/ast/lexer.rb:162` (tokenize) (+249 more)
- *POSSIBLE* [hidden_mutation] scatter=85 support=153 `[]=` -- `src/ast/diagnostic_examples.rb:104` (scan_file) (+151 more)
- *POSSIBLE* [hidden_mutation] scatter=51 support=64 `storage=` -- `src/ast/ast.rb:1087` (finalize_storage!) (+63 more)
- *POSSIBLE* [hidden_mutation] scatter=46 support=50 `fixable!` -- `src/annotator/helpers/fixable_helpers.rb:56` (emit_mutable_unused_finding!) (+49 more)
- *POSSIBLE* [hidden_mutation] scatter=36 support=36 `apply_capabilities!` -- `src/ast/type.rb:802` (initialize) (+35 more)
- *POSSIBLE* [hidden_mutation] scatter=33 support=55 `op-assign` -- `src/annotator/annotator.rb:295` (with_conditional_context) (+54 more)
- *POSSIBLE* [callback_inversion] scatter=33 support=36 `with_new_scope` -- `src/annotator/helpers/function_analysis.rb:141` (with_routine_analysis_scope) (+35 more)
- *POSSIBLE* [dynamic_dispatch] scatter=31 support=34 `instance_variable_get` -- `src/ast/source_error.rb:53` (error!) (+33 more)
- *POSSIBLE* [metaprogramming] scatter=21 support=21 `instance_variable_set` -- `src/ast/ast.rb:83` (copy_pipeline_metadata_ivars!) (+20 more)
- *POSSIBLE* [dynamic_dispatch] scatter=19 support=23 `yield` -- `src/ast/ast.rb:386` (walk_body) (+22 more)
- *POSSIBLE* [hidden_mutation] scatter=17 support=17 `require_array_input!` -- `src/annotator/helpers/pipe_analysis.rb:314` (analyze_select_family_op) (+16 more)
- *POSSIBLE* [dynamic_dispatch] scatter=15 support=15 `blk.call` -- `src/ast/type.rb:3182` (schema_struct_any?) (+14 more)
- *POSSIBLE* [hidden_mutation] scatter=12 support=15 `type=` -- `src/ast/symbol_entry.rb:486` (initialize) (+14 more)
- *POSSIBLE* [hidden_mutation] scatter=12 support=14 `local_entry!` -- `src/annotator/helpers/function_analysis.rb:1078` (declare_and_verify_params) (+13 more)
- *POSSIBLE* [hidden_mutation] scatter=10 support=14 `note!` -- `src/annotator/helpers/function_analysis.rb:927` (verify_lifetime!) (+13 more)
- *POSSIBLE* [hidden_mutation] scatter=10 support=13 `emit_typo_suggestion!` -- `src/annotator/helpers/generic_analysis.rb:249` (annotation_schema_for!) (+12 more)
- *POSSIBLE* [hidden_mutation] scatter=10 support=11 `classify_ownership!` -- `src/annotator/helpers/function_analysis.rb:1088` (declare_and_verify_params) (+10 more)
- *POSSIBLE* [hidden_mutation] scatter=10 support=11 `mark_observable_terminal!` -- `src/annotator/helpers/pipe_analysis.rb:609` (analyze_reduce_op) (+10 more)
- *POSSIBLE* [callback_inversion] scatter=10 support=10 `with_soa_tracking` -- `src/annotator/helpers/pipe_analysis.rb:323` (analyze_select_family_op) (+9 more)
- *POSSIBLE* [hidden_mutation] scatter=10 support=10 `record_capture_local!` -- `src/annotator/helpers/capabilities.rb:934` (declare_unwrapped_capability_alias!) (+9 more)
- *POSSIBLE* [hidden_mutation] scatter=9 support=14 `was_moved=` -- `src/annotator/helpers/function_analysis.rb:650` (verify_takes_argument!) (+13 more)
- *POSSIBLE* [hidden_mutation] scatter=8 support=11 `apply_reference_ownership!` -- `src/ast/type.rb:1258` (apply_storage_capability!) (+10 more)
- ...(+578 more)

## Fat Unions (1)
_case dispatch over class consts whose arms read mostly variant-invariant members -- product-vs-sum decomposition candidate (extraction -> nil-kill) -- *POSSIBLE*_

- *POSSIBLE* [DEGENERATE: no variance] union `AST::IndexOp | AST::OrderByOp | AST::SelectOp | AST::WhereOp` -- **2 common** vs 0 variant member(s), scatter=1 -- `src/annotator/helpers/pipe_analysis.rb:335` (analyze_select_family_op)
  - common: `expression, is_a?` -> hoist to a struct, keep a SMALL union for `` (-> nil-kill)

## Run Summary
- Files analyzed: 57
- Detectors: 25 (all shipped, self-tested)
- Convergence: 653 unit(s) flagged by >=2 independent detectors
- Root-cause clusters: 207 (one fix collapses each)
- Total candidates: 2256
- Method: stdlib AST only, intra-procedural, zero deps, no CFG / no points-to; Type-2/3 similarity uses Tree-sitter structural fingerprints (see docs/agents/design.md)
