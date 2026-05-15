# Prick Report

> Not all coverage gaps are equal. Every dark branch arm
> categorized; the GENUINE arms x fix-churn = where bugs
> are highly likely. Owns categorization; consumes
> fix-cache (churn). type_norm = confirm with nil-kill.

## Table of Contents
- [Category Rollup](#category-rollup)
- [Bugs Highly Likely (3)](#bugs-highly-likely-3)
- [Per-File Breakdown](#per-file-breakdown)
- [Run Summary](#run-summary)

## Category Rollup
_935 dark arms across 3 file(s). Most are NOT test targets:_

| category | arms | % | action |
|---|---|---|---|
| **type_norm** | 229 | 24.5% | type/nil guard -> likely removable; CONFIRM with nil-kill (typed contract kills the cluster) |
| **dead** | 68 | 7.3% | decision never executes -> audit as dead code, delete (complexity down) |
| **defensive** | 14 | 1.5% | inert / invariant-pinned -> accept + annotate, drop from denominator |
| **ffi** | 46 | 4.9% | extern/require/module -> a few targeted .cht |
| **diagnostic** | 305 | 32.6% | raises -> one negative unit spec (fuzz cannot reach) |
| **genuine** | 273 | 29.2% | REAL reachable gap -> test it; if in churn-hot code, bug-likely |

## Bugs Highly Likely (3)
_genuine reachable gaps in fix-churn-hot code -- triage top-down; this is the actionable ~slice:_

| # | file | genuine arms | churn | score |
|---|---|---|---|---|
| 1 | `src/mir/mir_lowering.rb` | 187 | 1.0 | 187.0 |
| 2 | `src/mir/control_flow.rb` | 64 | 0.231 | 14.783 |
| 3 | `src/mir/escape_analysis.rb` | 22 | 0.142 | 3.128 |

  Top file's genuine sites:
  - /home/yahn/cheat/src/mir/mir_lowering.rb:hoist_alloc:226
  - /home/yahn/cheat/src/mir/mir_lowering.rb:hoist_owned_value_temp:244
  - /home/yahn/cheat/src/mir/mir_lowering.rb:owned_value_temp_needs_cleanup?:255
  - /home/yahn/cheat/src/mir/mir_lowering.rb:owned_value_temp_needs_cleanup?:260
  - /home/yahn/cheat/src/mir/mir_lowering.rb:owned_value_temp_needs_cleanup?:261
  - /home/yahn/cheat/src/mir/mir_lowering.rb:container_borrow_expr?:270
  - /home/yahn/cheat/src/mir/mir_lowering.rb:copy_container_borrow_if_needed:289
  - /home/yahn/cheat/src/mir/mir_lowering.rb:copy_container_borrow_if_needed:290

## Per-File Breakdown

| file | total | type_norm | dead | defensive | genuine | ffi | diag |
|---|---|---|---|---|---|---|---|
| `src/mir/mir_lowering.rb` | 653 | 20.5% | 6.3% | 2.0% | 28.6% | 7.0% | 35.5% |
| `src/mir/control_flow.rb` | 170 | 31.8% | 10.0% | 0.6% | 37.6% | 0.0% | 20.0% |
| `src/mir/escape_analysis.rb` | 112 | 36.6% | 8.9% | 0.0% | 19.6% | 0.0% | 34.8% |

## Run Summary
- Repo: `.`
- Files triaged: 3; dark arms: 935
- Owns categorization; consumes fix-cache churn. type_norm arms: confirm removable with nil-kill (see docs/agents/design.md)
