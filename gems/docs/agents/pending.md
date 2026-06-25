# Pending and Skipped Tests

This document tracks the gems that still have skipped or pending tests as of the latest refactoring.

## Summary Table

| Gem | Testing Tool | Passed | Failed | Skipped / Pending |
| --- | --- | --- | --- | --- |
| `nil-kill` | RSpec | 388 | 0 | 5 |
| `slopcop` | Minitest | 89 | 0 | 4 |
| `boobytrap` | Minitest | 98 | 0 | 7 |
| `lineage` | Cargo Test | 127 | 0 | 0 |
| `fact-mine` | Cargo Test | 149 | 0 | 0 |
| `decomplex` | Cargo Test | 96 | 0 | 0 |

## Detailed Breakdown

### nil-kill (5 Pending)

1. `evidence-gap invariant NEGATIVE CONTROL: an uninstrumented collect makes infer/report RAISE (not silently zero)`
   * **Reason**: `infer pipeline pending in Rust FactMine (Phase 3)`
2. `nil-kill multi-language runtime pipeline keeps Go name-type struct fields typed in static evidence`
   * **Reason**: `set DECOMPLEX_TS_GO_PATH to run Go Tree-sitter static evidence test`
3. `nil-kill tracer capability matrix Struct field with NO strong static type: runtime-records field classes`
   * **Reason**: None specified
4. `nil-kill tracer capability matrix T.let with untyped type: records the runtime class (line-shift safe)`
   * **Reason**: None specified
5. `zero-gap end-to-end guarantee block/splat/kwsplat slots are arg_untraced, never a forbidden state`
   * **Reason**: None specified

### slopcop (4 Skipped)

1. `ClassifierTest#test_tree_sitter_static_zig_classification_when_coverage_is_absent`
   * **Reason**: `set DECOMPLEX_TS_ZIG_PATH to run Zig Tree-sitter static test`
2. `ClassifierTest#test_kcov_covered_zig_file_does_not_fall_back_to_static`
   * **Reason**: `set DECOMPLEX_TS_ZIG_PATH to run Zig Tree-sitter kcov test`
3. `ClassifierTest#test_coverage_py_json_python_classification_uses_branch_arcs`
   * **Reason**: `set DECOMPLEX_TS_PYTHON_PATH to run Python branch coverage test`
4. `ClassifierTest#test_nil_kill_branch_coverage_zig_classification_uses_native_dark_arms`
   * **Reason**: `set DECOMPLEX_TS_ZIG_PATH to run Zig native branch coverage test`

### boobytrap (7 Skipped)

1. `CoverageDataTest#test_builds_zig_branch_catalog_when_tree_sitter_grammar_is_available`
   * **Reason**: `set DECOMPLEX_TS_ZIG_PATH to run Zig branch catalog test`
2. `CoverageDataTest#test_loads_coverage_py_json_with_branch_arcs_when_tree_sitter_grammar_is_available`
   * **Reason**: `set DECOMPLEX_TS_PYTHON_PATH to run Python branch coverage test`
3. `MethodGapTest#test_coverage_py_json_python_method_dark_branches`
   * **Reason**: `set DECOMPLEX_TS_PYTHON_PATH to run Python branch coverage test`
4. `MethodGapTest#test_nil_kill_branch_coverage_zig_method_dark_branches`
   * **Reason**: `set DECOMPLEX_TS_ZIG_PATH to run Zig native branch coverage test`
5. `MethodGapTest#test_tree_sitter_static_zig_method_gaps_when_coverage_is_absent`
   * **Reason**: `set DECOMPLEX_TS_ZIG_PATH to run Zig Tree-sitter static test`
6. `CoverageGapTest#test_coverage_py_json_uses_python_branch_arcs`
   * **Reason**: `set DECOMPLEX_TS_PYTHON_PATH to run Python branch coverage test`
7. `CoverageGapTest#test_nil_kill_branch_coverage_uses_native_zig_arm_hits`
   * **Reason**: `set DECOMPLEX_TS_ZIG_PATH to run Zig native branch coverage test`

### decomplex

* **Rust Tests**: All 96 tests passed successfully.
* **Ruby Tests**: The Ruby tests cannot be run because `gems/decomplex/lib/decomplex.rb` has dependencies on files (e.g., `decomplex/source_filter.rb`) that do not exist in the index/files of the current `nil-kill-arch` branch.
