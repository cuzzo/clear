# Composed Scope Migration

Date: 2026-06-02

## Problem

`Scope#dup` currently deep-copies the whole visible locals hash for every
branch-like scope. That was correct enough for branch-local mutation, but it
creates two bad properties:

- Performance scales with `branch scopes * visible locals`, even when a branch
  declares or touches only a few names.
- Correctness depends on stale copied `SymbolEntry` objects. Post-annotation
  mutations on canonical function-level entries can drift from nested copies.

The `examples/minivm/vm.clear` profile exposed the performance side clearly:
`runRegisterBytecode!` is a huge dispatch loop with hundreds of branches. The
structural profile measured `1,839` branch scopes and `106,233` copied locals.

This is not a micro-optimization target. The goal is to remove the state model
that makes eager deep-copying the default.

## Design

`Scope` becomes a facade over typed components:

- `ScopeBindings`: immutable-ish declaration table for entries declared in this
  exact scope.
- `ScopeFacts`: per-scope mutable overlays for branch-local flow facts that are
  allowed to diverge from parent state.
- `ScopeTypes`: type declarations visible through the scope chain.
- `owned_names`: names declared in this exact scope, used for finalization,
  drops, and warnings.

Lookup remains ergonomic through `Scope`, but callers must state intent:

- `resolve_entry(name)` reads a visible binding through the scope chain.
- `local_entry(name)` reads a binding declared in this exact scope only.
- `entry_for_write(name)` materializes a branch-local flow view only when a
  consumer really needs to mutate branch-local state.
- `declare(...)` creates a local binding and records ownership.
- `owned_entries` iterates only exact-scope declarations.
- `visible_entries` is explicit and rare. Diagnostics/import/export code may use
  it; hot branch finalization must not.

The old `locals` hash is not the public model. It may exist only as a red-phase
compatibility scaffold. The migration is complete only when production code has
no direct `scope.locals` calls.

## Non-Goals

- Do not preserve a transparent lazy hash forever. That was tested and moved
  cost into enumeration/read paths.
- Do not make all `SymbolEntry` fields immutable in one step. This migration
  introduces typed access seams first; later work can split `SymbolEntry` into
  declaration metadata plus flow facts more aggressively.
- Do not optimize unrelated MIR lowering/checker code under this epic.

## Red/Green Migration

### Red 1: Lock In Current Semantics

Add focused specs for:

- nested scope lookup sees parent declarations;
- branch scope mutations do not mutate parent flow facts;
- branch scope declaration finalization iterates only owned declarations;
- function/global signature export uses explicit visible/global APIs;
- direct production use of `scope.locals` is forbidden.

The red test for direct use is intentional. It prevents a permanent dual path.

### Green 1: Add Typed Scope APIs

Introduce strongly typed methods on `Scope`:

- `resolve_entry`
- `local_entry`
- `entry_for_write`
- `declare_entry`
- `owned_entries`
- `visible_entries`
- `visible_names`
- `function_signature_entry`

Every new ivar and method gets Sorbet sigs. Return types are concrete:
`T.nilable(SymbolEntry)`, `T::Hash[String, SymbolEntry]`,
`T::Array[[String, SymbolEntry]]`, etc.

### Red 2: Migrate Hot Consumers First

Replace direct local-hash reads in:

- `annotator/domains/lifetimes.rb`
- `annotator/domains/control_flow.rb`
- `annotator/domains/variables.rb`
- `annotator/helpers/function_analysis.rb`
- `annotator/helpers/capabilities.rb`

Branch finalization and loop checks must use `owned_entries` or explicit body
identifier sets, never `visible_entries`.

### Green 2: Migrate Boundary Consumers

Replace direct local-hash access in:

- importer/frontend signature export;
- whole-program semantic phases;
- fixable helpers;
- expression-domain lookup;
- tests.

Boundary code may use `visible_entries` or root-scope APIs when it genuinely
needs a full view.

### Red 3: Delete Compatibility

After production consumers are migrated:

- remove `attr_accessor :locals`;
- remove hash-like direct mutation in production;
- keep tests that grep production files for `.locals`;
- remove `.locals` from specs and tools too.

This is the deletion gate. The migration is not done while both APIs exist.

## Coverage Bar

New scope-composition code must be covered at:

- 100% line coverage;
- greater than 80% branch coverage.

Coverage is measured with:

```sh
COVERAGE=1 bundle exec rspec spec/scope_composition_spec.rb
```

The resulting SimpleCov branch data must include `src/ast/scope.rb`.

## Decomplex Metrics

Baseline snapshot command:

```sh
bundle exec ruby gems/decomplex/exe/decomplex \
  src/ast/scope.rb \
  src/annotator/domains/lifetimes.rb \
  src/annotator/domains/control_flow.rb \
  src/annotator/domains/variables.rb \
  src/annotator/domains/execution_boundaries.rb \
  > /tmp/scope-migration-decomplex-before.txt
```

After migration, run the same command to
`/tmp/scope-migration-decomplex-after.txt` and report:

- missing abstraction count delta;
- neglected update count delta;
- any new root-cause clusters introduced by the migration.

## Performance Gate

Run the structural profiler before and after:

```sh
bundle exec ruby tools/profile_structural_multipliers.rb examples/minivm/vm.clear
```

The migration should reduce the branch-scope copied-local work. If wall time
does not move, the design is incomplete and the next target is splitting
`SymbolEntry` declaration metadata from flow facts so `entry_for_write` copies
only the mutated flow payload.
