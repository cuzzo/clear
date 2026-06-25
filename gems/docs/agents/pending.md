# Pending and Skipped Tests

This document tracks the gems that still have skipped or pending tests as of the latest refactoring.

## Summary Table (Tree-Sitter properly installed)

| Gem | Testing Tool | Passed | Failed | Skipped / Pending |
| --- | --- | --- | --- | --- |
| `nil-kill` | RSpec | 389 | 0 | 4 |
| `slopcop` | Minitest | 93 | 0 | 0 |
| `boobytrap` | Minitest | 105 | 0 | 0 |
| `lineage` | Cargo Test | 127 | 0 | 0 |
| `fact-mine` | Cargo Test | 149 | 0 | 0 |
| `decomplex` | Cargo Test | 96 | 0 | 0 |

## Detailed Breakdown

### nil-kill (4 Pending)

1. `evidence-gap invariant NEGATIVE CONTROL: an uninstrumented collect makes infer/report RAISE (not silently zero)`
   * **Reason**: `infer pipeline pending in Rust FactMine (Phase 3)`
2. `nil-kill tracer capability matrix Struct field with NO strong static type: runtime-records field classes`
   * **Reason**: None specified
3. `nil-kill tracer capability matrix T.let with untyped type: records the runtime class (line-shift safe)`
   * **Reason**: None specified
4. `zero-gap end-to-end guarantee block/splat/kwsplat slots are arg_untraced, never a forbidden state`
   * **Reason**: None specified

### slopcop (0 Skipped)

* All 93 tests run and pass when `DECOMPLEX_TS_ZIG_PATH` and `DECOMPLEX_TS_PYTHON_PATH` are set.

### boobytrap (0 Skipped)

* All 105 tests run and pass when `DECOMPLEX_TS_ZIG_PATH` and `DECOMPLEX_TS_PYTHON_PATH` are set.

### decomplex

* **Rust Tests**: All 96 tests passed successfully.
* **Ruby Tests**: The Ruby tests cannot be run because `gems/decomplex/lib/decomplex.rb` has dependencies on files (e.g., `decomplex/source_filter.rb`) that do not exist in the index/files of the current `nil-kill-arch` branch.
