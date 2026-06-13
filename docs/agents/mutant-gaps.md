# Mutant Coverage Gap Analysis

This tracker focuses on CLEAR's memory-safety mutation coverage. The P1 goal was to harden the "memory brain" areas without gaming the score: `Type`, `CleanupClassifier`, `EscapeAnalysis`, and `BorrowChecker`.

## Current P1 Status

| Area | Gate strategy | Current result | Status |
| :--- | :--- | :--- | :--- |
| `BorrowChecker` | Broad class gate | 86.07%, 833 mutations, 717 killed, 11 timeouts | Hard-gated |
| `CleanupClassifier` | Exact safety-path gates | `classify_plan` 94.92%; `binding_cleanup_facts` 86.45%; `stamp_field_pre_cleanups!` 86.98%; `walk_moved_source_guards` 100% | Hard-gated |
| `EscapeAnalysis` | Exact public/heap-promotion gates | `apply!` 100%; `apply_with_facts!` 98.96%; `propagate_caller_sync!` 91.48%; `mark_takes_args_heap!` 87.62% | Hard-gated |
| `Type` | Exact ownership/payload gates | `binary_op` 96.05%; `heap_ptr?` 98.33%; `needs_escape_promotion?` 100%; `success_type` 100%; `value_payload_type` 88.46% | Hard-gated |

## Real Bugs Found

- `BorrowChecker` did not treat `WITH BORROWED b.user` as an active borrow of root owner `b`, so moving `b` inside the borrow could slip through. This is fixed and covered.

## Design Notes

Broad `Type`, `CleanupClassifier`, and `EscapeAnalysis` mutation subjects are still advisory. That is intentional for now:

- `Type` is a broad value-object facade with many delegation and formatting methods. A broad 85% gate would mostly force tests over non-safety surface area.
- `CleanupClassifier` broad runs are expensive and noisy. The hard gates now cover cleanup facts, field pre-cleanup stamping, moved-source guard walking, and the existing plan classifier.
- `EscapeAnalysis` broad recursive walking remains advisory, but the major public entry points and heap-placement path for TAKES/heap-backed args are hard-gated.

Future work should add exact hard gates for newly discovered safety predicates rather than raising broad facade gates unless the subject is split into smaller cohesive units.
