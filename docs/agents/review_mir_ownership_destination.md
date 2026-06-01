# Review: MIR Ownership and Destination Helpers

## Scope

Targets:

- `MIRLowering#ownership_fact_source`
- `MIRLowering#collect_bg_capture_transfer_roots`
- `MIRLowering#return_destination_alloc`
- `MIRLowering#place_owned_try_catch_for_destination`
- `MIRLowering#place_owned_alloc_mismatch_for_destination`
- nearby ownership/destination fact helpers

Primary file:

- `src/mir/mir_lowering.rb`

## Evidence

Current report overlap:

- Boobytrap ranks `src/mir/mir_lowering.rb` as the highest-risk file.
- SlopCop top gaps in this scope are concentrated in ownership/destination
  helpers.
- NilKill shows broad `MirNode` unions for ownership helper parameters.
- Decomplex root causes name ownership, result type, alloc, and destination
  protocols around this file.

## /plan

1. Snapshot Decomplex and SlopCop for `src/mir/mir_lowering.rb`.
2. Inspect ownership/destination helpers as one protocol, not as isolated
   branches.
3. Reify an ownership/destination fact only if it lets callers delete repeated
   node introspection and allocation fallback logic.
4. Replace all call sites for the reified fact in one pass. Delete the old helper
   path immediately.
5. Run `bundle exec srb tc` and MIR lowering specs.
6. Regenerate metrics. Keep only if Decomplex and SlopCop both move down or a
   real bug was fixed.

## No-Partial Rule

No compatibility layer around old helpers. Any new fact object must be the
authoritative representation for the facts it owns.

## Expected Payoff

High if this collapses repeated ownership/destination introspection. Low if it
becomes another wrapper over the same MIR node case analysis.

