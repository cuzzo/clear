# Type Architecture Cleanup Plan

## Scope

Targets:

- `Type#initialize`
- `Type#parse_raw_input`
- `Type#compute_zig_type`

Primary file:

- `src/types.rb`

## Signal

The latest architecture and complexity reports keep ranking `Type` as a high
pressure object. The suspicious shape is not simply that `Type` has many
branches. It is that construction, normalization, derived representation, and
Zig emission are coupled through mutable instance state.

The riskiest pattern is a constructor that accepts broad raw input, stores
multiple derived facts, and then exposes methods that continue making semantic
decisions from the same mixed state. That makes `Type` hard for NilKill to prove,
hard for Decomplex to classify, and hard for callers to use without depending on
construction side effects.

## Hypothesis

The best payoff is to separate three responsibilities:

1. Parse external/raw input into one strongly typed normalized type descriptor.
2. Store only canonical semantic facts on `Type`.
3. Move Zig spelling decisions behind explicit typed variant emitters or a small
   Zig type renderer.

If a cleanup only moves branches from `Type#initialize` into helper methods while
keeping the same mutable fields and raw input protocol, it is not worth keeping.

## /plan

1. Snapshot `decomplex`, `slopcop`, `nil-kill`, and `espalier` metrics for
   `src/types.rb`.
2. Map every constructor input shape accepted by `Type#initialize` and
   `Type#parse_raw_input`.
3. Identify which shapes are real public API and which are legacy convenience
   forms that can be deleted safely.
4. Introduce strongly typed intermediate records only where they replace raw
   hash/array/string interpretation. Do not add `T.untyped`.
5. Collapse `parse_raw_input` so it returns a canonical descriptor instead of
   partially mutating `Type`.
6. Move `compute_zig_type` decisions to a typed rendering object or variant
   methods, but only if the old branch surface is deleted in the same change.
7. Regenerate metrics and compare:
   - Decomplex total findings and convergence for `Type`
   - SlopCop genuine gaps in `src/types.rb`
   - NilKill untyped, weak, and no-evidence counts for `Type`
   - Espalier mutation/call pressure for the three target methods
8. Keep the change only if it reduces real branch/state pressure or fixes a real
   bug. Revert if it merely creates wrapper methods around the same decisions.

## Strong Type Rules

- No added `T.untyped`.
- No added untyped hashes or arrays.
- New records must be concrete `T::Struct` classes or existing typed domain
  objects.
- Any constructor API that cannot be typed honestly should be deleted or isolated
  behind a narrow parser, not leaked into `Type`.

## Expected Payoff

High if raw-input parsing and Zig spelling are actually removed from the core
mutable object. Low if the work becomes a cosmetic method extraction.

This is a good v0.1 candidate because `Type` is foundational. A simpler type
core should improve the annotator, MIR lowering, backend emission, and the
static-analysis reports at the same time.

## Scrap Criteria

Scrap the branch if:

- `Type` gains a second compatibility path.
- `parse_raw_input` still accepts the same broad raw shapes and just delegates
  them elsewhere.
- `compute_zig_type` remains stateful but now crosses more helper boundaries.
- Metrics regress without a real bug fix or a clear follow-up deletion.
