# Boobytrap Cleanup Roadmap

This document captures prioritized architectural cleanups, hotspots, and code issues identified by Decomplex and Espalier within the Boobytrap gem.

## 1. High Priority: Redundant File and Extension Validations (Resolved)

- **Issue**: The rescue block in `report.rb:current_source_files` contained redundant checks:
  ```ruby
  in_scope?(rel) && ::File.file?(rel) && exts.include?(::File.extname(rel).downcase) && source_file?(rel)
  ```
  Both the extension check and `::File.file?(rel)` check are already performed inside the delegated `source_file?(rel)` method.
- **Action Taken**: Simplified to:
  ```ruby
  in_scope?(rel) && source_file?(rel)
  ```

## 2. Medium Priority: Stub Consolidation (Exact Predicate Aliases)

- **Issue**: Decomplex flagged exact predicate aliases between `load_decomplex_source_filter` / `excluded_path?` (both return `false`), and `load_decomplex_syntax` / `tree_sitter?` (both return `true`).
- **Recommendation**: Audit these stubs and consolidate them if they represent identical configuration axes, reducing API surface area.

## 3. Low Priority: Derived-State Variable Naming

- **Issue**: Variable names in `to_markdown` like `blast` and `state_branch` triggered derived-state warnings due to parsing heuristics (overlapping substring names like `branch`).
- **Recommendation**: Scope or prefix local variables in rendering/markdown blocks to differentiate them clearly.
