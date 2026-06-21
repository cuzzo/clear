# Ruby Stateless/Stateful Syntax Pass Split

## Goal

Make the Ruby runtime syntax path explicit about pass ownership:

- Stateless syntax extraction walks syntax and emits structural facts.
- Stateful syntax enrichment consumes already-collected facts and language events.
- Ruby syntax files only provide grammar hooks and Ruby-specific events.

This is a structural cleanup, not a line-count reduction. The near-term result is expected to add code because it introduces named pass objects and removes an implicit adapter hook.

## Functionality To Move

- Move structural traversal out of `TreeSitterAdapter`.
  - From: direct `walk` loops in `lib/decomplex/syntax.rb`.
  - To: `Syntax::StatelessSyntaxPass`.
  - Facts covered: functions, owners, calls, state declarations, state param origins, state reads, state writes, decisions, branch arms, comparisons, predicate bodies, local methods, and path conditions.
  - Estimated LoC movement: remove 50-80 LoC from `syntax.rb`, add 80-120 LoC to `syntax/passes.rb`.

- Move implicit state access enrichment out of `after_structural_facts`.
  - From: base adapter hook in `TreeSitterLanguageAdapter`.
  - To: `Syntax::StatefulSyntaxPass`.
  - Languages affected: C++ and C# raw parser compatibility.
  - Estimated LoC movement: remove 2-6 LoC from `syntax.rb`, add 4-8 LoC to `syntax/passes.rb`.

- Move Ruby visibility application out of `RubySyntaxAdapter`.
  - From: `RubySyntaxAdapter#apply_ruby_visibility!`.
  - To: shared `Syntax::StatefulSyntaxPass#apply_visibility_events!`.
  - Ruby remains responsible for identifying Ruby visibility calls and normalizing target names.
  - Estimated LoC movement: remove 35-55 LoC from `syntax/ruby.rb`, add 45-70 LoC to `syntax/passes.rb`.

- Replace the `after_structural_facts` extension point with explicit event extraction.
  - From: language adapters overriding a broad post-fact mutation hook.
  - To: language adapters returning narrow events such as `VisibilityEvent`.
  - Enforcement: architecture invariant bans concrete syntax files from defining `after_structural_facts`.
  - Estimated LoC movement: add 3-8 LoC to `architecture_invariants_test.rb`.

## File Impact Estimate

| File | Expected Change | Reason |
| --- | ---: | --- |
| `lib/decomplex/syntax/passes.rb` | +160 to +210 LoC | New explicit stateless/stateful pass classes. |
| `lib/decomplex/syntax.rb` | -30 to -55 LoC | Replace direct adapter walk methods with pass delegation. |
| `lib/decomplex/syntax/ruby.rb` | -25 to -45 LoC | Remove visibility mutation; keep visibility event extraction. |
| `test/architecture_invariants_test.rb` | +3 to +8 LoC | Allow pass file and ban broad stateful adapter hook. |

Expected net code change: +90 to +140 LoC before documentation.

The net addition is acceptable for this step because it creates an enforceable pass boundary. Later extraction of call-target/state-ref/type-metadata machinery should produce the real Ruby-specific LoC reduction.

## Performance Expectations

- Native Ruby source facts are not expected to change because the normal Ruby runtime path uses `FactDocument` hydrated from native `syntax-facts`.
- Raw Ruby parser compatibility should remain close to current performance.
- Structural extraction remains cached per document.
- Stateful enrichment duplicates shallow fact structs once per document before mutation. This adds a small raw-parser memory/object cost.
- Branch-decision filtering still walks the syntax tree per call, as before. A later pass should split raw branch refs from immutable/type filtering so branch filtering consumes stored structural refs instead of walking syntax again.

## Implementation Plan

1. Add `Syntax::StatelessSyntaxPass`.
   - Own the cached raw syntax walk for structural facts.
   - Own decision, branch arm, comparison, predicate, local-flow, and path-condition entry points.
   - Keep language profiles as hook providers.

2. Add `Syntax::StatefulSyntaxPass`.
   - Consume stateless structural facts.
   - Apply implicit state access enrichment.
   - Apply visibility events to function facts.
   - Serve stateful metadata readers: immutable readers, immutable reader types, and type aliases.

3. Update `TreeSitterAdapter`.
   - Route public fact methods through the explicit passes.
   - Keep the adapter walker seam injectable so tests can verify language context seeding.

4. Update `RubySyntaxAdapter`.
   - Delete `apply_ruby_visibility!`.
   - Add `visibility_events`.
   - Keep only Ruby grammar-specific visibility call detection and argument name normalization.

5. Enforce the boundary.
   - Add `passes.rb` to the reviewed syntax-file allowlist.
   - Ban concrete syntax subfiles from defining `after_structural_facts`.

6. Verify behavior.
   - Run architecture invariant tests.
   - Run syntax tests.
   - Run full Ruby tests.
   - If native output changes, stop and investigate. It should not change.

## First Implementation Result

Actual line counts after implementation:

| File | Before | After | Delta |
| --- | ---: | ---: | ---: |
| `lib/decomplex/syntax.rb` | 3,518 | 3,490 | -28 |
| `lib/decomplex/syntax/ruby.rb` | 913 | 889 | -24 |
| `lib/decomplex/syntax/passes.rb` | 0 | 195 | +195 |
| `test/architecture_invariants_test.rb` | 287 | 290 | +3 |

Actual net code change for this pass split: +146 LoC before documentation.

Moved behavior:

- `TreeSitterAdapter` now delegates raw parser fact work to explicit pass objects.
- `StatefulSyntaxPass` owns Ruby visibility application.
- `RubySyntaxAdapter` now emits `VisibilityEvent` data instead of mutating function facts.
- `StatefulSyntaxPass` owns implicit state access enrichment for C++/C# raw compatibility.

Verification so far:

- `architecture_invariants_test.rb`: 11 runs, 22 assertions, 0 failures.
- `syntax_test.rb`: 37 runs, 280 assertions, 0 failures.
- Full Ruby test suite: 1,333 runs, 4,936 assertions, 0 failures.
