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

During the migration and audit, the following bugs were identified and resolved:

1. **Sorbet Type Alias Owner Extraction (Rust)**
   - *Symptom*: Nested namespace aliases in Ruby (`Module::AliasName`) were extracted as `"owner": ""` and `"name": "Module::AliasName"`.
   - *Fix*: Parsed the qualified name via `rfind("::")` in `profile.rs`. Added oracle integration tests.
2. **Kcov Cobertura Line-Only Skip/Crash (Ruby)**
   - *Symptom*: Classifier fell back to static branch analysis (assuming no coverage) for files with line-only coverage (Kcov Cobertura).
   - *Fix*: Mapped line hits to branch spans inside `line_branch_arm_coverage`.
3. **Decomplex UTF-8 Scan Failure (Rust)**
   - *Symptom*: `decomplex-rust` crashed trying to read compiled Zig binary files or other binary assets as UTF-8 text during recursive folder scans.
   - *Fix*: Implemented `is_binary_file` helper in `report_facts.rs` to detect binary files (e.g. null bytes, ELF/PE signatures) and skip them.
4. **Obsolete Ruby Decomplex/Fact-Mine Spec (Ruby)**
   - *Symptom*: Spec `decomplex_architecture_invariants_spec.rb` failed due to the deletion of legacy Ruby Decomplex/Fact-Mine source files.
   - *Fix*: Deleted the obsolete spec since the corresponding Ruby code was deleted.
5. **Broken diff_bucket_summary Dependency (Ruby)**
   - *Symptom*: RSpec failed to load because `tools/diff_bucket_summary.rb` depended on deleted `decomplex/sarif.rb`.
   - *Fix*: Decoupled the script by changing the dependency to `slopcop/sarif.rb` and updating references to `SlopCop::Sarif`.
