# Review: MIR Ownership and Destination Helpers

## Scope

Targets: `MIRLowering#ownership_fact_source`,
`MIRLowering#collect_bg_capture_transfer_roots`,
`MIRLowering#return_destination_alloc`,
`MIRLowering#place_owned_try_catch_for_destination`,
`MIRLowering#place_owned_alloc_mismatch_for_destination`, and nearby
ownership/destination helpers in `src/mir/mir_lowering.rb`.

## /plan

1. Snapshot Decomplex and SlopCop for `src/mir/mir_lowering.rb`.
2. Reify an ownership/destination fact only if it deletes repeated node
   introspection and allocation fallback logic.
3. Replace all call sites for any new fact in one pass and delete the old helper
   path immediately.
4. Regenerate metrics and keep only if Decomplex and SlopCop both improve.

## Implementation Result

Abandoned.

Attempted:

- Extracted a shared owned-placement cleanup block for
  `place_owned_try_catch_for_destination` and
  `place_owned_alloc_mismatch_for_destination`.
- Extracted background capture transfer-root collection helpers.

Metrics:

- SlopCop for `src/mir/mir_lowering.rb`: genuine gaps regressed `10 -> 19`.
- Decomplex Broken Protocols improved `30 -> 28`, but Neglected Updates
  regressed `4 -> 6`.

Assessment:

Not worth keeping. The shared helper looked like deduplication, but it created a
new protocol and made SlopCop worse. The attempt was reverted fully. No partial
ownership/destination helper remains.
