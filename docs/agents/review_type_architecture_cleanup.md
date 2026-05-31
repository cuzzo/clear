# Review: Type Architecture Cleanup

## Scope

Targets: `Type#initialize`, `Type#parse_raw_input`, and
`Type#compute_zig_type` in `src/ast/type.rb`.

## /plan

1. Snapshot Decomplex and SlopCop for `src/ast/type.rb`.
2. Replace loose parsing/rendering protocols only if the old branch surface is
   deleted in the same change.
3. Keep no compatibility parser or parallel renderer.
4. Regenerate metrics and keep only if SlopCop and Decomplex move in the right
   direction or a real bug is fixed.

## Implementation Result

Kept.

Implemented:

- Replaced `strip_capability_suffix`'s loose array return with
  `TypeCapabilitySuffix`.
- Removed parser variable reassignments in `parse_raw_input` that produced
  stale-derived-state findings.
- Split tense, capability wrapping, capability inner type, and map Zig rendering
  out of `compute_zig_type` as authoritative helpers. The old inline branches
  were deleted.

Metrics:

- SlopCop for `src/ast/type.rb`: genuine gaps `60 -> 31`.
- Decomplex for `src/ast/type.rb`: derived-state staleness `2 -> 0`.
- `compute_zig_type`: from a 6-detector hotspot in the broad baseline to
  2 detectors / 5 findings locally.

Assessment:

Worth keeping. SlopCop moved decisively down, and the reported stale-state bug
shape in Type parsing/rendering was removed. Decomplex aggregate convergence in
the single file did not fall, but the high-risk `compute_zig_type` and
derived-state signals moved in the intended direction.
