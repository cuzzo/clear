# Review: Type Architecture Cleanup

## Scope

Targets:

- `Type#initialize`
- `Type#parse_raw_input`
- `Type#compute_zig_type`

Primary file:

- `src/ast/type.rb`

## Evidence

Current report overlap:

- Espalier ranks `Type#initialize` as the highest coordinator/mutator collision.
- Espalier ranks `Type#compute_zig_type` as a top conditional delegation hub.
- Espalier ranks `Type#parse_raw_input` as another high write-heavy collision.
- Decomplex flags `compute_zig_type` with 6 detectors and derived-state
  staleness.
- Decomplex flags `parse_raw_input` with derived-state staleness.
- SlopCop has `compute_zig_type` in the top true gaps for the target scope.
- NilKill still keeps `Type#initialize raw_input` as `T.untyped` because the API
  accepts a wide raw union.

## /plan

1. Snapshot Decomplex and SlopCop for `src/ast/type.rb`.
2. Identify whether there is a narrow replacement for raw constructor parsing.
3. If there is, introduce a strongly typed parser result and delete the old
   mutation path in the same commit.
4. If constructor input cannot be narrowed safely in this pass, do not create a
   compatibility parser. Instead, attack `compute_zig_type` by extracting a
   single authoritative renderer branch only if the old branch body is deleted.
5. Run `bundle exec srb tc` and focused type specs.
6. Regenerate Decomplex and SlopCop. Keep the change only if both move
   decidedly in the correct direction for this target or a real bug was fixed.

## No-Partial Rule

No dual constructor path is allowed. A new parser result must become the only
writer for the facts it owns. A new Zig renderer must own the branch it replaces,
not mirror it through a second path.

## Expected Payoff

High if raw parsing and Zig rendering are actually split from mutable `Type`
state. Low if the work is only helper extraction.

