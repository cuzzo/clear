# Type, Symbol, Scope, And MIR Fact Completion

Owner: Codex

Branch: `architectural-review`

Date: 2026-06-09

## Objective

Finish the remaining lifecycle work around `Type`, `SymbolEntry`, `Scope`, and
MIR cleanup/ownership facts without adding compatibility paths.

The concrete end state for this branch:

- branch-local `SymbolEntry` copies share canonical declaration/lifecycle facts
  and copy only branch-local flow facts;
- `Scope` exposes typed stores for bindings, type declarations, and dependency
  metadata instead of loose hashes;
- MIR cleanup fact lookup is total and non-nil: absent cleanup is
  `CleanupEntry::NONE`, not `nil`;
- cleanup entry updates go through typed methods, not open `entry[:field] =`
  protocols outside the classifier object;
- ownership/cleanup consumers use `PlaceId`/`CleanupEntry` facts as the
  authority and leave string keys only as final compatibility output for AST
  `cleanup_bindings`.

## Baseline

Snapshot directory:

`tmp/type-symbol-scope-mir-facts`

Captured before implementation:

- Decomplex: `decomplex-before.md` / `decomplex-before.json`
- SlopCop: `slopcop-before.md`
- Boobytrap: `boobytrap-before.md`
- Full coverage input: `coverage-before/.resultset.json`

Baseline top-line metrics:

| Metric | Before |
| --- | ---: |
| Decomplex cross-detector convergence | 1779 |
| Decomplex root-cause clusters | 484 |
| Decomplex decision pressure | 277 |
| Decomplex state heatmap | 569 |
| Decomplex state-based branch density | 1609 |
| Decomplex temporal ordering pressure | 14 |
| Decomplex broken protocols | 389 |
| SlopCop dark arms | 2887 |
| SlopCop genuine gaps | 1276 |
| Boobytrap hotspots | 95 |
| Boobytrap state-based branch hotspots | 1609 |

## Scope

Primary files:

- `src/ast/symbol_entry.rb`
- `src/ast/scope.rb`
- `src/mir/cleanup_entry.rb`
- `src/mir/cleanup_classifier.rb`
- `src/mir/mir_pass.rb`
- selected direct consumers in `src/mir/control_flow.rb`,
  `src/mir/mir_lowering.rb`, `src/mir/hoist.rb`, and lowering helpers

Non-goals:

- Do not redesign the parser.
- Do not split the entire `Type` object again in this branch.
- Do not add dual APIs that keep old nil/string cleanup fact protocols alive.
- Do not convert diagnostic-only AST `cleanup_bindings` output away from string
  keys unless a correctness consumer still reads it as authority.

## Design

### 1. Shared Binding Lifecycle Facts

`SymbolEntry#dup` is supposed to make branch-local flow state independent, but
type/storage/sync/layout are not branch-local. They are declaration lifecycle
facts. Today they are mutable fields on every copied entry, so a branch-local
copy can stale after escape analysis or capability propagation updates the
canonical entry.

Add a typed `BindingLifecycleFacts` object owned by `SymbolEntry`.

Shared lifecycle facts:

- `type`
- `storage`
- `sync`
- `layout`
- `resource`
- `close_plan`
- `ownership_kind`
- `takes`
- `is_param`
- `link_source`
- `async_result_shape`

Copied branch-local facts:

- `BindingFlowFacts`
- `lifetime`
- `capabilities` overlays
- declaration ownership in `Scope#owned_names`

The important invariant: `SymbolEntry#dup` shares lifecycle facts and duplicates
flow facts. A branch copy can mark itself read/mutated/invalid without changing
the parent, but escape analysis updating storage on the canonical param is
visible through every existing branch copy.

### 2. Typed Scope Stores

`ScopeBindings` and `ScopeTypes` already exist. Finish the seam by replacing
remaining loose dependency/type return signatures with typed objects and
guardrails:

- `Scope#dependencies` stores dependency metadata as `T::Hash[String, String]`
  instead of `T::Hash[T.untyped, T.untyped]`;
- `resolve_type_definition` returns a concrete schema union;
- `Scope#initialize_copy` duplicates dependency store intentionally;
- specs assert no direct `scope.locals` access and that dependency/type stores
  stay typed.

### 3. Total Cleanup Facts

`CleanupEntry::NONE` already exists, but `FrozenCleanupFacts#entry_for`,
`#entry_for_node`, `#live_entry_for`, and `MIRPass#live_cleanup_entry` still
return `nil`. This keeps nil checks and legacy string fallbacks alive.

Make lookup total:

- `entry_for(...) -> CleanupEntry`
- `entry_for_node(...) -> CleanupEntry`
- `live_entry_for(...) -> CleanupEntry`
- `live_entry_for_node(...) -> CleanupEntry`

`live_*` returns `CleanupEntry::NONE` when the binding is absent or does not
need cleanup. Callers ask `.present?` / `.needs_cleanup?`.

### 4. Cleanup Entry Mutators

`CleanupEntry` is still a hash subclass for AST compatibility, but
memory-safety updates should not open-code hash writes. Add typed mutators:

- `mark_moved_guard!`
- `clear_moved_guard!`
- `suppress_cleanup!`
- `promote_to_cleanup!`
- `set_cleanup_scope!`
- `set_alloc!`

Then migrate ownership/cleanup phases away from direct `entry[:has_moved_guard]
=`, `entry[:needs_cleanup] =`, `entry[:alloc] =`, and `entry[:scope] =` where
they are updating a `CleanupEntry`.

### 5. Guardrails

Extend architecture specs so future changes cannot silently reintroduce:

- `Scope#locals`;
- cleanup fact lookup returning `nil`;
- MIR cleanup/ownership code mutating cleanup-entry fields with raw hash writes
  outside `CleanupEntry` and `CleanupClassifier`.

## Work Loop

For each slice:

1. Implement the slice.
2. Add focused tests for the new invariant and representative consumers.
3. Run focused specs and Sorbet.
4. Run Decomplex over `src`.
5. If state/control-flow metrics move the wrong way for no clear deletion
   payoff, adjust before continuing.

## Acceptance Criteria

- [x] 100% of changed/new source lines covered.
- [x] Greater than 80% of changed/new branches covered.
- [x] All new/changed functions have Sorbet signatures and concrete inputs /
  returns.
- [x] No new primitive tuple arrays or hashes-as-structs in compiler source.
- [x] Decomplex and SlopCop materially improve or stay flat on secondary
  metrics while primary lifecycle metrics improve.
- [x] Boobytrap hotspots do not worsen for touched files.

## Implementation Checklist

- [x] Shared `SymbolEntry::BindingLifecycleFacts` and branch-copy semantics.
- [x] Typed scope dependency/type stores and tightened type-definition API.
- [x] Total `FrozenCleanupFacts` lookup API using `CleanupEntry::NONE`.
- [x] CleanupEntry typed mutators and direct-hash writer burn-down.
- [x] Architecture guardrails for lifecycle and cleanup fact protocols.
- [x] Final Decomplex, SlopCop, and Boobytrap comparison.

## Final Results

Final snapshots:

- Decomplex: `decomplex-after.md` / `decomplex-after.json`
- SlopCop: `slopcop-after.md`
- Boobytrap: `boobytrap-after.md`
- Full coverage input: `coverage-after/.resultset.json`

Top-line metric delta:

| Metric | Before | After | Delta |
| --- | ---: | ---: | ---: |
| Decomplex net debt | 5867 | 5865 | -2 |
| Decomplex cross-detector convergence | 1779 | 1771 | -8 |
| Decomplex root-cause clusters | 484 | 483 | -1 |
| Decomplex decision pressure | 277 | 274 | -3 |
| Decomplex state heatmap | 569 | 568 | -1 |
| Decomplex state-based branch density | 1609 | 1610 | +1 |
| Decomplex temporal ordering pressure count | 14 | 14 | 0 |
| Decomplex broken protocols | 389 | 389 | 0 |
| SlopCop dark arms | 2887 | 2876 | -11 |
| SlopCop genuine gaps | 1276 | 1274 | -2 |
| Boobytrap hotspots | 95 | 95 | 0 |
| Boobytrap state-based branch hotspots | 1609 | 1610 | +1 |

Lifecycle owner score delta:

| Owner | Before | After | Delta |
| --- | ---: | ---: | ---: |
| `SymbolEntry` | 5188 | 4288 | -900 |
| `Type` | 5112 | 1682 | -3430 |
| `Scope` | 408 | 394 | -14 |

The one Decomplex loss is one additional state-based branch density finding
from the total cleanup-fact API and live-entry helpers. The tradeoff is accepted:
the work removes nil-return cleanup protocols, removes direct lifecycle writes
from ownership phases, collapses the `entry` root-cause cluster entirely, and
shrinks the lifecycle-owner scores that motivated this task.

Coverage and type checks:

- Full suite: 5677 examples, 0 failures.
- Full suite coverage: 99.34% line, 85.96% branch.
- Current working-tree `src/**/*.rb` additions: 100.0% line, 92.3% branch.
- Sorbet: `bundle exec srb tc` passed.
