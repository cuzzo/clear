# Tech Debt Cleanup Plan

This document outlines the plans to address the top complexity hotspots and architectural debt identified by Decomplex and Espalier reports.

---

## 1. Hotspot Refactoring Plans

### A. Fact-Mine: `profile.rs` (`extract_type_definitions` / Line 814)
* **Problem**: Convergence score of 14 (flagged by 6 detectors). Signature parsing, alias resolution, and definition ingestion are tightly coupled within one method.
* **Refactoring Plan**:
  - Extract the Sorbet/Python/TypeScript typed signature parsing out of the main loop into a dedicated `SignatureParser` struct/module.
  - Extract the type alias resolution logic (e.g. namespace resolution via `rfind("::")`) into an `AliasResolver` component.
  - Make `extract_type_definitions` a clean coordinator function that calls these isolated helpers to map facts into `TypeDefinition` instances.

### B. Fact-Mine: `ast/normalizer.rs` (`normalize_call_without_block` / Line 2129)
* **Problem**: Flagged by 5 detectors with score 11. High branch density trying to match diverse multilingual call AST configurations.
* **Refactoring Plan**:
  - Introduce an abstract syntax pattern matcher (e.g., matching common patterns like receiver/method/arguments) instead of deeply nested language-specific `if let` blocks.
  - Decompose the method by language/adapters (e.g., delegate to language-specific normalization helpers under `ast/adapters/` such as `RubyAstAdapter` and `PythonAstAdapter`).

### C. Decomplex: `decomplex/sarif.rs` (`compact_object` / Line 169)
* **Problem**: Flagged by 4 detectors with score 10. Heavy recursion formatting complex JSON structures.
* **Refactoring Plan**:
  - Refactor the recursion to use an explicit loop with a stack (stack-based traversal) to avoid deep recursive calls.
  - Break down structural formatting rules for different JSON node types (e.g., Arrays vs. Objects) into smaller, distinct helper functions.

### D. Taming Low-Tier Metrics Noise
* **Problem**: Standard Rust shadowing, variable reassignment, and struct mutations cause false positives in `False Simplicity` and `Derived-State Staleness` detectors.
* **Tuning Plan**:
  - Filter out local variables from `Derived-State Staleness` analysis if they are reassigned within standard loop contexts or standard builders.
  - Exclude standard library builder patterns and standard struct update syntax (`Struct { ..other }`) from triggering `False Simplicity`.

---

## 2. Architectural Sweeps (Espalier Report Clues)

### A. Fact-Mine: `TreeSitterNormalizer` Coordination Overload
* **Espalier Clue**: `TreeSitterNormalizer<'source>` (in `ruby.rs`) has a State Owner Pressure of **1401.75** and Encapsulation Pressure of **948.60**, with `normalize_node` coordinating 129 separate method calls.
* **Refactoring Plan**:
  - Separate coordination from mechanism helpers. Move individual syntax node traversers out of the normalizer class into dedicated visitor/reducer components.
  - Extract a decision table or named policy helpers for `normalize_node` to delegate actions based on node kinds dynamically, removing the monolithic switch/match structure.

### B. Decomplex: `Report` Low Cohesion
* **Espalier Clue**: `Report` (in `co_update.rs` / `report.rb`) has a low cohesion score of **85.80** with 5 fragmented state components.
* **Refactoring Plan**:
  - Split state clusters into smaller context/owner objects. Separate formatting concerns (SARIF, markdown rendering, prioritization) into dedicated formatters/reporter classes rather than keeping them inside the monolithic `Report` class.
