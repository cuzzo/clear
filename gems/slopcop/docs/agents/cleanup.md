# SlopCop Cleanup Roadmap

This document captures prioritized architectural cleanups, hotspots, and code issues identified by Decomplex and Espalier within the SlopCop gem.

## 1. High Priority: Dependency and Load Path Hygiene (Resolved)

- **Issue**: Requiring the sibling decomplex gem's SARIF component fallback using `require "slopcop/sarif"` in `dark_arm_overlay.rb` and `report.rb` resulted in bootstrap failures when the gem's lib directory was not explicitly in the `$LOAD_PATH`.
- **Action Taken**: Replaced fallback loader requires with `require_relative "sarif"`.

## 2. High Priority: External Process Decoupling (Resolved)

- **Issue**: On-the-fly execution of `decomplex-rust` and full `git log` calculations in `Rollup.run` introduce execution latency and tight coupling.
- **Action Taken**:
  - Implemented `--decomplex-facts` option to feed static pre-computed decomplex findings JSON via `ENV["DECOMPLEX_FACTS_FILE"]`.
  - Implemented `--boobytrap-churn` option to feed static pre-computed boobytrap churn JSON via `ENV["BOOBYTRAP_CHURN_FILE"]`.

## 3. Medium Priority: Predicate Complexity (Resolved)

- **Issue**: Oversized predicate in `decomplex_verdict.rb` at line 122:
  ```ruby
  next unless file && !file.empty? && meth && !meth.empty?
  ```
- **Action Taken**: Simplified to:
  ```ruby
  next if file.to_s.empty? || meth.to_s.empty?
  ```
  This reduces the number of conjunction atoms and cleans up the control flow.

## 4. Medium Priority: Decomplex Indexing & Flattening

- **Issue**: `DecomplexVerdict.flatten_detectors` contains high branching density and nested conditional type checks to extract site names.
- **Recommendation**: Refactor detector flattening into separate traversal components.
