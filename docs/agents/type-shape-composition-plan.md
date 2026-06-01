# TypeShape Composition Plan

## Goal

Move `Type` structural state into a dedicated `TypeShape` composition object,
the same way recent work moved capability state into `TypeCapabilities` and
placement/provenance state into `TypePlacement`.

This is only worth doing if `TypeShape` becomes the single owner of structural
truth. A partial version that adds `type.shape` while keeping the old shape ivars
as a parallel source of truth should be scrapped.

## Current Shape State

`Type` still directly owns structural classification, child type references, and
raw parse results:

- `@is_array`, `@capacity`, `@element_type_raw`
- `@is_map`, `@key_type_raw`, `@value_type_raw`
- `@is_optional`, `@wrapped_type_raw`
- `@is_error_union`, `@payload_type_raw`
- `@is_tense`, `@tense_type_raw`
- `@is_auto`
- `@is_generic_instance`, `@generic_base_raw`, `@generic_args_raw`,
  `@generic_args_obj`
- `@resolved_cache`
- `@zig_type_cache` depends on the shape facts above

This leaves `Type` responsible for too many things:

- parsing string/symbol surface syntax,
- storing canonical structural facts,
- lazily constructing child `Type` objects,
- answering structural predicates,
- feeding Zig rendering,
- coordinating capabilities and placement overlays.

That is the remaining architecture problem after the capability and placement
composition passes.

## Desired Shape

`Type` should eventually look conceptually like this:

```ruby
type.shape          # structural identity and child type facts
type.capabilities   # ownership, sync, collection, observable, layout facts
type.placement      # provenance / storage / cleanup location
type.zig            # rendering policy, or a renderer over the three objects
```

`TypeShape` should own structural queries:

```ruby
type.shape.array?
type.shape.capacity
type.shape.element_type
type.shape.map?
type.shape.key_type
type.shape.value_type
type.shape.optional?
type.shape.wrapped_type
type.shape.error_union?
type.shape.payload_type
type.shape.future?
type.shape.tense_type
type.shape.generic_instance?
type.shape.generic_base
type.shape.generic_args
```

`Type` may keep public delegating methods such as `type.array?` and
`type.element_type`, but those methods must delegate to `shape`; they must not
read old parallel ivars.

## /plan: Complete Migration

1. Inventory every shape reader and writer.
   - Search `src/` for all old structural fields and methods:
     `@is_array`, `@capacity`, `@element_type_raw`, `@is_map`,
     `@key_type_raw`, `@value_type_raw`, `@is_optional`, `@wrapped_type_raw`,
     `@is_error_union`, `@payload_type_raw`, `@is_tense`, `@tense_type_raw`,
     `@is_auto`, `@is_generic_instance`, `@generic_base_raw`,
     `@generic_args_raw`, `@generic_args_obj`, and `@resolved_cache`.
   - Classify each usage as parse, copy, predicate, child accessor, Zig
     rendering, generic substitution, capability interaction, or test setup.

2. Design `TypeShape` before editing.
   - Use concrete `T::Struct` or strongly typed immutable value objects.
   - Do not use `T.untyped`, untyped arrays, or record-shaped hashes.
   - Provide named constructors for each shape variant:
     scalar, auto, array, map, optional, error union, tense, generic instance.
   - Provide a single parser entry point that accepts the existing normalized
     string/symbol input and returns `TypeShape`.
   - Provide copy/with operations for the cases that currently mutate shape.

3. Red phase: delete old Type shape storage first.
   - Remove old shape ivar initialization from `Type#initialize`.
   - Remove old copy assignments from `Type.new(other)`.
   - Remove old parse writes from `parse_raw_input`.
   - Remove direct reads of old shape ivars from `Type` methods.
   - Let Sorbet/spec failures reveal every callsite still depending on old
     storage.

4. Green phase: implement `TypeShape` as the only storage.
   - Add `attr_reader :shape` to `Type`.
   - Build `@shape` in `Type#initialize` and `parse_raw_input`.
   - Make public `Type` shape methods delegate to `shape`.
   - Move lazy child construction into `TypeShape` or into typed `Type` wrapper
     methods that read only from `shape`.
   - Ensure cache invalidation for `@zig_type_cache` happens only when shape,
     capabilities, or placement actually changes.

5. Migrate all callsites without compatibility shims.
   - Internal code should use either the existing public `Type` methods or
     explicit `type.shape` methods.
   - No caller should reach into old ivars.
   - No old ivar should remain as a backup or mirror.
   - Any test setup that currently mutates shape directly must use a constructor
     or a named shape transition.

6. Re-run static guardrails before metrics.
   - `bundle exec srb tc`
   - `Src Type Guardrails`
   - focused Type specs
   - focused annotator/MIR specs affected by shape parsing and child accessors

7. Re-run full correctness and coverage.
   - Full RSpec.
   - Branch-added coverage check for this branch.
   - Any existing fuzz/compile coverage shard that exercises type syntax if the
   touched code affects parser-facing syntax.

## Tracking Items

- [x] Add `TypeShape` as the only owner of structural facts.
- [x] Move raw/canonical type identity into `TypeShape`.
- [x] Move array shape into `TypeShape`: element raw type and capacity.
- [x] Move map shape into `TypeShape`: key raw type, value raw type, and
  numeric-map predicate.
- [x] Move optional/error-union/tense wrapper shape into `TypeShape`.
- [x] Move generic-instance shape into `TypeShape`.
- [x] Delete direct `Type` shape ivars and copy-constructor `instance_variable_get`
  reads.
- [x] Make public `Type` shape readers delegate to `shape`.
- [x] Remove shape-derived caches from `Type` unless they are clearly necessary
  and owned behind `shape`.
- [x] Regenerate Sorbet RBI if `Type#shape` or other accessors are exposed.
  No RBI regeneration was needed for this repo layout.
- [x] Run Sorbet, focused Type specs, full unit specs, Decomplex, and SlopCop.

## Acceptance Criteria

- `src/ast/type.rb` has no direct writes or reads of the old structural ivars:
  `@raw`, `@name`, `@generic_args`, `@capacity`, `@is_array`,
  `@element_type_raw`, `@is_map`, `@key_type_raw`, `@value_type_raw`,
  `@is_optional`, `@wrapped_type_raw`, `@is_error_union`,
  `@payload_type_raw`, `@is_tense`, `@tense_type_raw`, `@is_auto`,
  `@is_generic_instance`, `@generic_base_raw`, `@generic_args_raw`,
  `@generic_args_obj`, and `@resolved_cache`.
- The only structural storage slot on `Type` is `@shape`.
- `Type.new(other)` copies `other.shape`, not private ivars.
- `parse_raw_input` is replaced by a complete shape parse/build path; no old
  mutable shape dimensions remain as a fallback.
- No new `T.untyped`, untyped hashes, or untyped arrays are introduced.
- `bundle exec srb tc` passes.
- Focused Type specs and full unit specs pass.
- SlopCop and Decomplex are regenerated before and after, with the delta
  recorded in the session report.

## Measurement Plan

Snapshot before the refactor:

- Decomplex report.
- SlopCop report.
- NilKill report if shape changes affect typed evidence or nil proof.
- `Src Type Guardrails`.
- Full `prspec`/coverage baseline.

Measure after the refactor:

- Decomplex totals and the `src/ast/type.rb` hotspots:
  - Broken Protocols
  - Neglected Updates
  - Neglected Path Conditions
  - Derived-State Staleness
  - False Simplicity
  - Decision Pressure
  - any `Type#initialize`, `Type#parse_raw_input`, `Type#compute_zig_type`
    ranked entries
- SlopCop true gaps in `src/ast/type.rb` and downstream files.
- NilKill weak/untyped/no-evidence changes for Type construction and Type
  accessors.
- Guardrail findings for untyped functions, untyped arrays/hashes, and untyped
  ivars.
- Added-line coverage for this branch.

Success is not "new object exists." Success is that structural state is no
longer spread across `Type` ivars and downstream metrics move in the right
direction or expose a real bug that we fix.

## Done Criteria

The refactor is done only when all of these are true:

- `Type` has one structural storage slot: `@shape`.
- Old structural ivars are deleted, not mirrored:
  `@is_array`, `@element_type_raw`, `@capacity`, `@is_map`, `@key_type_raw`,
  `@value_type_raw`, `@is_optional`, `@wrapped_type_raw`, `@is_error_union`,
  `@payload_type_raw`, `@is_tense`, `@tense_type_raw`, `@is_auto`,
  `@is_generic_instance`, `@generic_base_raw`, `@generic_args_raw`,
  `@generic_args_obj`.
- `parse_raw_input` returns or assigns one complete `TypeShape`; it does not
  partially mutate shape dimensions.
- `Type.new(other)` copies shape through `other.shape.copy` or an equivalent
  typed value operation.
- Public `Type` predicates and child accessors delegate to shape.
- No code in `src/` uses old shape ivars.
- No new `T.untyped`, untyped hashes, or untyped arrays are introduced.
- Sorbet passes.
- Full RSpec passes.
- Added executable lines in this branch remain 100% covered.
- Decomplex and SlopCop are compared against the pre-refactor snapshot.

## Scrap Criteria

Scrap or revert if any of these happen and cannot be resolved by completing the
migration:

- `TypeShape` is added while old shape ivars remain as compatibility storage.
- Shape parsing becomes a second path instead of replacing `parse_raw_input`
  writes.
- Metrics regress broadly and the change did not fix a real bug.
- The implementation mostly moves branches from `Type` into a larger helper
  without deleting state or simplifying callsites.
- The change requires weak typing to land.

## Expected Payoff

This should be higher payoff than another small branch-coverage pass because it
attacks the remaining source of `Type` state coupling. If successful, it should
reduce derived-state staleness and neglected-update pressure in `Type`, make
shape-dependent Zig rendering easier to audit, and make future work on a
dedicated Zig renderer less risky.
