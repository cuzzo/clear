# Decomplex Audit and Tech Debt Epic

This document provides a summary of the complexity hotspots, architectural debt, and encountered bugs across all analyzed repositories: `espalier`, `nil-kill`, `slopcop`, `boobytrap`, and the parent `clear` compiler (source files in `src/` and Zig runtime in `zig/`).

## 1. Audit Summary Matrix

| Repository / Module | Language | Files | Major Signal Hotspots | Top Complexity Signals |
|---|---|---|---|---|
| **espalier** | Ruby | 16 | `static_evidence.rb`, `type_profile.rb` | State-Based Branch Density, State Heatmap, Decision Pressure |
| **nil-kill** | Ruby | 24 | `infer.rb`, `report.rb`, `source_index/` | State-Based Branch Density, Derived-State Staleness, Weighted Inlined Cognitive Complexity |
| **slopcop** | Ruby | 8 | `classifier.rb`, `report.rb` | State-Based Branch Density, Decision Pressure |
| **boobytrap** | Ruby | 6 | `coverage_data.rb`, `risk.rb` | State-Based Branch Density, False Simplicity |
| **clear (compiler)** | Ruby | 56 | `mir/mir_lowering.rb`, `mir/mir_checker.rb` | State-Based Branch Density, Weighted Inlined Cognitive Complexity |
| **clear (runtime)** | Zig | 48 | `runtime/` | State-Based Branch Density, Locality Drag |

---

## 2. Major Complexity Hotspots & Architectural Debt

### A. Espalier
- **Hotspot**: `gems/espalier/lib/espalier/static_evidence.rb` (`build_from_rust_facts`)
  - **Issue**: High decision pressure and derived-state staleness. It processes raw JSON facts from Rust and constructs RBI definitions, which has high cognitive complexity.
- **Hotspot**: `gems/espalier/lib/espalier/tree_sitter.rb` (`parser_for`)
  - **Issue**: High Locality Drag. Initialization of `roots` happens far before its actual usage, with several unrelated RbConfig checks in between.

### B. Nil-Kill
- **Hotspot**: `gems/nil-kill/lib/nil_kill/infer.rb` (`hash_record_expand_row_from_return_origins`)
  - **Issue**: This method converges on **9 independent detectors** (e.g. Decision Pressure, Derived-State Staleness, Locality Drag, Missing Abstractions, Oversized Predicates). It is the single highest complexity hotspot in the codebase.
- **Hotspot**: `gems/nil-kill/lib/nil_kill/report.rb`
  - **Issue**: Massive file size with 198 methods. Contains high branch density and temporal ordering pressure, showing that report generation has too many internal lifecycle stages.

### C. SlopCop & BoobyTrap
- **Hotspot**: `gems/slopcop/lib/slopcop/classifier.rb`
  - **Issue**: High decision pressure on coverage class detection.
- **Hotspot**: `gems/boobytrap/lib/boobytrap/coverage_data.rb`
  - **Issue**: High state-based branch density due to mapping line hits to branch spans when native branch-level coverage data is absent.

### D. Clear (Compiler & Runtime)
- **Hotspot**: `src/mir/mir_lowering.rb`
  - **Issue**: High decision pressure due to lowering AST to MIR nodes with numerous complex state transitions.
- **Hotspot**: `zig/runtime/`
  - **Issue**: Locality Drag and state-based branch density in concurrent scheduling code.

---

## 3. Tech Debt Epic Task List

### Epic 1: Local Refactoring of High-Pressure Methods
- [ ] **Task 1.1**: Refactor `infer.rb` (`hash_record_expand_row_from_return_origins`) in `nil-kill` to decompose it into small, coherent helper methods to reduce decision pressure.
- [ ] **Task 1.2**: Refactor `static_evidence.rb` (`build_from_rust_facts`) in `espalier` to separate RBI generation concerns from fact ingestion.
- [ ] **Task 1.3**: Reduce Locality Drag in `tree_sitter.rb` (`parser_for`) by moving RbConfig path resolutions directly to where they are consumed.

### Epic 2: Module Partitioning & Cleanup
- [ ] **Task 2.1**: Partition `gems/nil-kill/lib/nil_kill/report.rb` into smaller reporter modules (e.g. `evidence_reporter.rb`, `cause_reporter.rb`).
- [ ] **Task 2.2**: Audit and unify type profile construction inside `gems/espalier/lib/espalier/type_profile.rb` to resolve the Function LCOM issues.

---

## 4. Log of Encountered Bugs & Fixes

5. **Espalier CLI Integration Crash (Ruby)**
   - *Symptom*: Running `espalier` crashed with `TypeError: no implicit conversion of Symbol into Integer` in `nil_kill_evidence.rb:35`.
   - *Fix*: Created a `StaticEvidence.project_modules` helper to group flat Rust facts into the structured modules representation expected by Espalier's aggregator and nil-kill evidence apply.

---

## 5. Decomplex & Espalier Metrics Audit on Decomplex & Fact-Mine

We ran both tools on the `decomplex` and `fact-mine` codebases and spot-checked their findings:

1. **Verify it Works**:
   - Both tools execute successfully. The Espalier CLI crash has been fully resolved and unit-tested.
2. **Execution Time**:
   - `decomplex-rust` on Decomplex (~1.3k LoC): ~0.3s.
   - `decomplex-rust` on Fact-Mine (~1.7k LoC): ~1.0s.
   - `espalier` on both directories runs in ~1.5s.
3. **Spot-Checking Findings**:
   - **Fact-Mine Rust Top Hotspot (`gems/fact-mine/rust/src/profile.rs:814` - `extract_type_definitions`)**: Flagged by 6 detectors with score 14. Highly complex. Signature parsing, alias resolution, and definition ingestion are tangled.
   - **Fact-Mine Rust AST Normalizer Hotspot (`gems/fact-mine/rust/src/ast/normalizer.rs:2129` - `normalize_call_without_block`)**: Flagged by 5 detectors with score 11. Large branch depth matching and mapping call configurations across multi-lingual tree-sitter AST nodes.
   - **Decomplex Rust Top Hotspot (`gems/decomplex/rust/src/decomplex/sarif.rs:169` - `compact_object`)**: Flagged by 4 detectors with score 10. Large recursive matching and formatting of JSON objects.
   - **Expected Low-Tier Noise**: Tier 2/3 metrics like `False Simplicity` and `Derived-State Staleness` are somewhat noisy due to standard Rust variable shadowing and struct mutations, which is expected.

---

## 6. Ruby Codebase Coverage Table (Decomplex & Fact-Mine)

Below is the line and branch coverage breakdown compiled from `coverage/.resultset.json` for the Ruby components of `decomplex` and `fact-mine`:

| File | Line Coverage % | Branch Coverage % | Executable Lines | Total Branch Arms |
| --- | --- | --- | --- | --- |
| `gems/decomplex/lib/decomplex.rb` | 100.0% (3/3) | 100.0% (0/0) | 3 | 0 |
| `gems/decomplex/lib/decomplex/ast.rb` | 89.29% (25/28) | 75.0% (3/4) | 28 | 4 |
| `gems/decomplex/lib/decomplex/co_update.rb` | 98.41% (62/63) | 90.0% (18/20) | 63 | 20 |
| `gems/decomplex/lib/decomplex/convergence.rb` | 100.0% (45/45) | 95.0% (19/20) | 45 | 20 |
| `gems/decomplex/lib/decomplex/decision_pressure.rb` | 100.0% (45/45) | 100.0% (6/6) | 45 | 6 |
| `gems/decomplex/lib/decomplex/delta.rb` | 86.84% (33/38) | 62.5% (5/8) | 38 | 8 |
| `gems/decomplex/lib/decomplex/derived_state.rb` | 100.0% (36/36) | 91.67% (11/12) | 36 | 12 |
| `gems/decomplex/lib/decomplex/detector_runner.rb` | 77.27% (17/22) | 50.0% (3/6) | 22 | 6 |
| `gems/decomplex/lib/decomplex/false_simplicity.rb` | 96.55% (28/29) | 75.0% (3/4) | 29 | 4 |
| `gems/decomplex/lib/decomplex/fat_union.rb` | 100.0% (23/23) | 83.33% (5/6) | 23 | 6 |
| `gems/decomplex/lib/decomplex/flay_similarity.rb` | 94.74% (18/19) | 75.0% (3/4) | 19 | 4 |
| `gems/decomplex/lib/decomplex/function_lcom.rb` | 96.43% (54/56) | 87.5% (7/8) | 56 | 8 |
| `gems/decomplex/lib/decomplex/inconsistent_rename_clone.rb` | 96.97% (32/33) | 83.33% (5/6) | 33 | 6 |
| `gems/decomplex/lib/decomplex/local_flow.rb` | 100.0% (78/78) | 95.0% (19/20) | 78 | 20 |
| `gems/decomplex/lib/decomplex/locality_drag.rb` | 94.74% (36/38) | 75.0% (6/8) | 38 | 8 |
| `gems/decomplex/lib/decomplex/miner.rb` | 98.28% (57/58) | 90.0% (18/20) | 58 | 20 |
| `gems/decomplex/lib/decomplex/mutability_pressure.rb` | 0.0% (0/44) | 100.0% (0/0) | 44 | 0 |
| `gems/decomplex/lib/decomplex/native/co_update.rb` | 100.0% (10/10) | 100.0% (0/0) | 10 | 0 |
| `gems/decomplex/lib/decomplex/native/command.rb` | 100.0% (10/10) | 100.0% (0/0) | 10 | 0 |
| `gems/decomplex/lib/decomplex/native/decision_pressure.rb` | 100.0% (10/10) | 100.0% (0/0) | 10 | 0 |
| `gems/decomplex/lib/decomplex/native/derived_state.rb` | 100.0% (10/10) | 100.0% (0/0) | 10 | 0 |
| `gems/decomplex/lib/decomplex/native/false_simplicity.rb` | 100.0% (10/10) | 100.0% (0/0) | 10 | 0 |
| `gems/decomplex/lib/decomplex/native/fat_union.rb` | 100.0% (10/10) | 100.0% (0/0) | 10 | 0 |
| `gems/decomplex/lib/decomplex/native/flay_similarity.rb` | 100.0% (10/10) | 100.0% (0/0) | 10 | 0 |
| `gems/decomplex/lib/decomplex/native/function_lcom.rb` | 100.0% (10/10) | 100.0% (0/0) | 10 | 0 |
| `gems/decomplex/lib/decomplex/native/implicit_control_flow.rb` | 100.0% (10/10) | 100.0% (0/0) | 10 | 0 |
| `gems/decomplex/lib/decomplex/native/inconsistent_rename_clone.rb` | 100.0% (10/10) | 100.0% (0/0) | 10 | 0 |
| `gems/decomplex/lib/decomplex/native/locality_drag.rb` | 100.0% (10/10) | 100.0% (0/0) | 10 | 0 |
| `gems/decomplex/lib/decomplex/native/miner.rb` | 100.0% (10/10) | 100.0% (0/0) | 10 | 0 |
| `gems/decomplex/lib/decomplex/native/operational_discontinuity.rb` | 100.0% (10/10) | 100.0% (0/0) | 10 | 0 |
| `gems/decomplex/lib/decomplex/native/oversized_predicate.rb` | 100.0% (10/10) | 100.0% (0/0) | 10 | 0 |
| `gems/decomplex/lib/decomplex/native/path_condition.rb` | 100.0% (10/10) | 100.0% (0/0) | 10 | 0 |
| `gems/decomplex/lib/decomplex/native/predicate_aliases.rb` | 100.0% (10/10) | 100.0% (0/0) | 10 | 0 |
| `gems/decomplex/lib/decomplex/native/redundant_nil_guard.rb` | 100.0% (10/10) | 100.0% (0/0) | 10 | 0 |
| `gems/decomplex/lib/decomplex/native/report_facts.rb` | 100.0% (10/10) | 100.0% (0/0) | 10 | 0 |
| `gems/decomplex/lib/decomplex/native/semantic_aliases.rb` | 100.0% (10/10) | 100.0% (0/0) | 10 | 0 |
| `gems/decomplex/lib/decomplex/native/sequence_mine.rb` | 100.0% (10/10) | 100.0% (0/0) | 10 | 0 |
| `gems/decomplex/lib/decomplex/native/state_branch_density.rb` | 100.0% (10/10) | 100.0% (0/0) | 10 | 0 |
| `gems/decomplex/lib/decomplex/native/state_mesh.rb` | 100.0% (10/10) | 100.0% (0/0) | 10 | 0 |
| `gems/decomplex/lib/decomplex/native/state_writes.rb` | 0.0% (0/28) | 100.0% (0/0) | 28 | 0 |
| `gems/decomplex/lib/decomplex/native/structural_topology.rb` | 100.0% (10/10) | 100.0% (0/0) | 10 | 0 |
| `gems/decomplex/lib/decomplex/native/temporal_ordering_pressure.rb` | 100.0% (10/10) | 100.0% (0/0) | 10 | 0 |
| `gems/decomplex/lib/decomplex/native/weighted_inlined_complexity.rb` | 100.0% (10/10) | 100.0% (0/0) | 10 | 0 |
| `gems/decomplex/lib/decomplex/operational_discontinuity.rb` | 98.63% (72/73) | 96.67% (29/30) | 73 | 30 |
| `gems/decomplex/lib/decomplex/ordered_protocol_mine.rb` | 98.8% (164/166) | 83.33% (40/48) | 166 | 48 |
| `gems/decomplex/lib/decomplex/oversized_predicate.rb` | 100.0% (33/33) | 100.0% (4/4) | 33 | 4 |
| `gems/decomplex/lib/decomplex/path_condition.rb` | 95.0% (38/40) | 60.0% (6/10) | 40 | 10 |
| `gems/decomplex/lib/decomplex/predicate_alias.rb` | 100.0% (30/30) | 83.33% (5/6) | 30 | 6 |
| `gems/decomplex/lib/decomplex/redundant_nil_guard.rb` | 100.0% (12/12) | 100.0% (0/0) | 12 | 0 |
| `gems/decomplex/lib/decomplex/report.rb` | 90.09% (291/323) | 67.33% (101/150) | 323 | 150 |
| `gems/decomplex/lib/decomplex/report_facts.rb` | 80.95% (68/84) | 80.95% (17/21) | 84 | 21 |
| `gems/decomplex/lib/decomplex/root_cause.rb` | 100.0% (67/67) | 91.67% (22/24) | 67 | 24 |
| `gems/decomplex/lib/decomplex/sarif.rb` | 98.15% (53/54) | 77.27% (17/22) | 54 | 22 |
| `gems/decomplex/lib/decomplex/semantic_alias.rb` | 100.0% (51/51) | 91.67% (11/12) | 51 | 12 |
| `gems/decomplex/lib/decomplex/sequence_mine.rb` | 94.32% (83/88) | 86.67% (26/30) | 88 | 30 |
| `gems/decomplex/lib/decomplex/site_extractor.rb` | 100.0% (7/7) | 100.0% (0/0) | 7 | 0 |
| `gems/decomplex/lib/decomplex/source_filter.rb` | 91.07% (51/56) | 62.5% (15/24) | 56 | 24 |
| `gems/decomplex/lib/decomplex/state_branch_density.rb` | 84.21% (48/57) | 0.0% (0/8) | 57 | 8 |
| `gems/decomplex/lib/decomplex/state_mesh.rb` | 97.01% (162/167) | 75.0% (15/20) | 167 | 20 |
| `gems/decomplex/lib/decomplex/structural_topology.rb` | 92.5% (111/120) | 84.38% (27/32) | 120 | 32 |
| `gems/decomplex/lib/decomplex/superfluous_state.rb` | 0.0% (0/144) | 100.0% (0/0) | 144 | 0 |
| `gems/decomplex/lib/decomplex/syntax.rb` | 60.0% (3/5) | 50.0% (1/2) | 5 | 2 |
| `gems/decomplex/lib/decomplex/syntax_oracle.rb` | 60.0% (3/5) | 50.0% (1/2) | 5 | 2 |
| `gems/decomplex/lib/decomplex/temporal_ordering_pressure.rb` | 100.0% (45/45) | 100.0% (6/6) | 45 | 6 |
| `gems/decomplex/lib/decomplex/weighted_inlined_cognitive_complexity.rb` | 100.0% (91/91) | 95.0% (19/20) | 91 | 20 |
| `gems/fact-mine/lib/fact_mine.rb` | 0.0% (0/4) | 100.0% (0/0) | 4 | 0 |
| `gems/fact-mine/lib/fact_mine/ast.rb` | 63.41% (26/41) | 11.76% (2/17) | 41 | 17 |
| `gems/fact-mine/lib/fact_mine/ast/adapters.rb` | 100.0% (27/27) | 86.67% (13/15) | 27 | 15 |
| `gems/fact-mine/lib/fact_mine/ast/adapters/base.rb` | 83.09% (398/479) | 80.83% (156/193) | 479 | 193 |
| `gems/fact-mine/lib/fact_mine/ast/adapters/c.rb` | 74.42% (32/43) | 53.57% (15/28) | 43 | 28 |
| `gems/fact-mine/lib/fact_mine/ast/adapters/go.rb` | 40.0% (20/50) | 12.5% (3/24) | 50 | 24 |
| `gems/fact-mine/lib/fact_mine/ast/adapters/kotlin.rb` | 44.0% (11/25) | 12.5% (1/8) | 25 | 8 |
| `gems/fact-mine/lib/fact_mine/ast/adapters/lua.rb` | 88.62% (109/123) | 77.03% (57/74) | 123 | 74 |
| `gems/fact-mine/lib/fact_mine/ast/adapters/python.rb` | 86.47% (147/170) | 79.73% (59/74) | 170 | 74 |
| `gems/fact-mine/lib/fact_mine/ast/adapters/ruby.rb` | 86.64% (227/262) | 76.39% (110/144) | 262 | 144 |
| `gems/fact-mine/lib/fact_mine/ast/adapters/rust.rb` | 100.0% (4/4) | 100.0% (0/0) | 4 | 0 |
| `gems/fact-mine/lib/fact_mine/ast/adapters/typescript.rb` | 81.25% (65/80) | 81.82% (18/22) | 80 | 22 |
| `gems/fact-mine/lib/fact_mine/ast/adapters/zig.rb` | 81.82% (9/11) | 50.0% (1/2) | 11 | 2 |
| `gems/fact-mine/lib/fact_mine/ast/cache.rb` | 100.0% (5/5) | 100.0% (0/0) | 5 | 0 |
| `gems/fact-mine/lib/fact_mine/ast/legacy_normalizer.rb` | 0.0% (0/1) | 100.0% (0/0) | 1 | 0 |
| `gems/fact-mine/lib/fact_mine/ast/node.rb` | 100.0% (6/6) | 100.0% (0/0) | 6 | 0 |
| `gems/fact-mine/lib/fact_mine/ast/normalizer.rb` | 86.25% (1361/1578) | 70.61% (663/939) | 1578 | 939 |
| `gems/fact-mine/lib/fact_mine/ast/semantic_node.rb` | 71.43% (10/14) | 0.0% (0/4) | 14 | 4 |
| `gems/fact-mine/lib/fact_mine/ast/semantic_normalizer.rb` | 76.47% (39/51) | 40.91% (9/22) | 51 | 22 |
| `gems/fact-mine/lib/fact_mine/ast/source_map.rb` | 71.43% (5/7) | 0.0% (0/2) | 7 | 2 |
| `gems/fact-mine/lib/fact_mine/espalier_profile.rb` | 42.7% (459/1075) | 22.3% (130/583) | 1075 | 583 |
| `gems/fact-mine/lib/fact_mine/native/command.rb` | 77.14% (27/35) | 33.33% (6/18) | 35 | 18 |
| `gems/fact-mine/lib/fact_mine/syntax.rb` | 50.42% (908/1801) | 22.5% (214/951) | 1801 | 951 |
| `gems/fact-mine/lib/fact_mine/syntax/adapters.rb` | 26.67% (8/30) | 0.0% (0/24) | 30 | 24 |
| `gems/fact-mine/lib/fact_mine/syntax/c.rb` | 92.48% (123/133) | 53.85% (21/39) | 133 | 39 |
| `gems/fact-mine/lib/fact_mine/syntax/clone_similarity.rb` | 97.02% (163/168) | 84.42% (65/77) | 168 | 77 |
| `gems/fact-mine/lib/fact_mine/syntax/complexity.rb` | 28.71% (29/101) | 0.0% (0/48) | 101 | 48 |
| `gems/fact-mine/lib/fact_mine/syntax/contracts.rb` | 47.62% (10/21) | 0.0% (0/6) | 21 | 6 |
| `gems/fact-mine/lib/fact_mine/syntax/cpp.rb` | 74.38% (119/160) | 34.43% (21/61) | 160 | 61 |
| `gems/fact-mine/lib/fact_mine/syntax/csharp.rb` | 77.87% (95/122) | 31.11% (14/45) | 122 | 45 |
| `gems/fact-mine/lib/fact_mine/syntax/dispatch.rb` | 78.48% (62/79) | 57.14% (8/14) | 79 | 14 |
| `gems/fact-mine/lib/fact_mine/syntax/dynamic_language.rb` | 100.0% (3/3) | 100.0% (0/0) | 3 | 0 |
| `gems/fact-mine/lib/fact_mine/syntax/effects.rb` | 93.27% (97/104) | 90.91% (60/66) | 104 | 66 |
| `gems/fact-mine/lib/fact_mine/syntax/fact_document.rb` | 96.08% (196/204) | 76.39% (55/72) | 204 | 72 |
| `gems/fact-mine/lib/fact_mine/syntax/go.rb` | 72.07% (160/222) | 34.41% (32/93) | 222 | 93 |
| `gems/fact-mine/lib/fact_mine/syntax/java.rb` | 76.61% (95/124) | 37.78% (17/45) | 124 | 45 |
| `gems/fact-mine/lib/fact_mine/syntax/javascript.rb` | 93.15% (68/73) | 44.44% (4/9) | 73 | 9 |
| `gems/fact-mine/lib/fact_mine/syntax/kotlin.rb` | 80.0% (92/115) | 28.57% (10/35) | 115 | 35 |
| `gems/fact-mine/lib/fact_mine/syntax/lua.rb` | 58.6% (109/186) | 18.45% (19/103) | 186 | 103 |
| `gems/fact-mine/lib/fact_mine/syntax/nil_guards.rb` | 96.28% (207/215) | 86.61% (97/112) | 215 | 112 |
| `gems/fact-mine/lib/fact_mine/syntax/normalized_extraction_behavior.rb` | 95.53% (171/179) | 81.58% (31/38) | 179 | 38 |
| `gems/fact-mine/lib/fact_mine/syntax/normalized_extractor.rb` | 95.14% (822/864) | 78.34% (387/494) | 864 | 494 |
| `gems/fact-mine/lib/fact_mine/syntax/normalized_local_facts.rb` | 99.33% (298/300) | 88.06% (118/134) | 300 | 134 |
| `gems/fact-mine/lib/fact_mine/syntax/passes.rb` | 91.89% (204/222) | 58.82% (20/34) | 222 | 34 |
| `gems/fact-mine/lib/fact_mine/syntax/php.rb` | 36.33% (113/311) | 0.0% (0/149) | 311 | 149 |
| `gems/fact-mine/lib/fact_mine/syntax/protocols.rb` | 93.55% (58/62) | 90.0% (9/10) | 62 | 10 |
| `gems/fact-mine/lib/fact_mine/syntax/python.rb` | 59.95% (220/367) | 34.3% (71/207) | 367 | 207 |
| `gems/fact-mine/lib/fact_mine/syntax/ruby.rb` | 63.1% (554/878) | 30.99% (198/639) | 878 | 639 |
| `gems/fact-mine/lib/fact_mine/syntax/rust.rb` | 86.61% (97/112) | 54.05% (20/37) | 112 | 37 |
| `gems/fact-mine/lib/fact_mine/syntax/swift.rb` | 87.63% (85/97) | 47.62% (10/21) | 97 | 21 |
| `gems/fact-mine/lib/fact_mine/syntax/type_metadata_facts.rb` | 88.73% (63/71) | 61.29% (19/31) | 71 | 31 |
| `gems/fact-mine/lib/fact_mine/syntax/type_profile.rb` | 94.09% (191/203) | 70.11% (61/87) | 203 | 87 |
| `gems/fact-mine/lib/fact_mine/syntax/typescript.rb` | 97.0% (97/100) | 65.22% (30/46) | 100 | 46 |
| `gems/fact-mine/lib/fact_mine/syntax/zig.rb` | 91.41% (117/128) | 67.44% (29/43) | 128 | 43 |
| `gems/fact-mine/lib/fact_mine/syntax_oracle.rb` | 81.72% (76/93) | 45.0% (9/20) | 93 | 20 |

